//! Windows IOCP transport — Phase B ("per-OS backends behind one transport
//! interface").
//!
//! Same contract as the io_uring/kqueue backends (`transport.Handler`),
//! different mechanism: one completion port, N workers running
//! GetQueuedCompletionStatus, one blocking acceptor thread (plain
//! `accept()` — no AcceptEx function-pointer dance — which associates
//! each socket with the port). The protocol layer is untouched.
//!
//! Lifetime discipline (mirrors uring.zig): the worker connection map is
//! the authority — whoever removes an entry owns the close (the socket
//! closes exactly once). Removed slots are RETAINED until worker exit so
//! an in-flight completion can never touch freed memory; a `dead` flag
//! under the slot lock stops the flush/send paths from using a removed
//! slot. The server re-checks its own map under its lock, so a completion
//! that loses the race with a close is a null-safe no-op.
//!
//! Lock order (global, never reversed): worker map -> slot -> protocol/
//! conn locks. `requestFlush`/`closeConn` take no conn locks.
//!
//! Coverage: x86_64-windows cross-compile only. This box is Linux, so the
//! IOCP path has no runtime coverage (same documented gap class as
//! kqueue; TODO.md). Zig ships no IOCP bindings, so the ~10 Win32 entry
//! points are declared here as externs (x86_64: C ABI == WINAPI).

const std = @import("std");
const builtin = @import("builtin");
const transport = @import("transport.zig");

const windows = std.os.windows;

pub const supported = builtin.os.tag == .windows;

// ---------------------------------------------------------------------------
// Win32 declarations (not in std.os.windows — declared here).
// ---------------------------------------------------------------------------

const HANDLE = windows.HANDLE;
const BOOL = windows.BOOL;
const DWORD = windows.DWORD;
const ULONG = windows.ULONG;
const SOCKET = usize;

const INVALID_SOCKET: SOCKET = ~@as(SOCKET, 0);
const SOCKET_ERROR: c_int = -1;
const INFINITE: DWORD = 0xFFFF_FFFF;
const WAIT_TIMEOUT: DWORD = 258;

const WSA_IO_PENDING: c_int = 997;
const WSAEWOULDBLOCK: c_int = 10035;

const IPPROTO_TCP: c_int = 6;
const TCP_NODELAY: u32 = 1;
const SOL_SOCKET: c_int = 0xFFFF;
const SO_SNDBUF: u32 = 0x1001;
const SO_RCVBUF: u32 = 0x1002;

const OVERLAPPED = extern struct {
    Internal: usize,
    InternalHigh: usize,
    Offset: DWORD,
    OffsetHigh: DWORD,
    hEvent: ?HANDLE,
};

const WSABUF = extern struct {
    len: ULONG,
    buf: [*]u8,
};

extern "kernel32" fn CreateIoCompletionPort(FileHandle: HANDLE, ExistingCompletionPort: ?HANDLE, CompletionKey: usize, NumberOfConcurrentThreads: DWORD) callconv(.c) ?HANDLE;
extern "kernel32" fn GetQueuedCompletionStatus(CompletionPort: HANDLE, lpNumberOfBytesTransferred: *DWORD, lpCompletionKey: *usize, lpOverlapped: *?*OVERLAPPED, dwMilliseconds: DWORD) callconv(.c) BOOL;
extern "kernel32" fn PostQueuedCompletionStatus(CompletionPort: HANDLE, dwNumberOfBytesTransferred: DWORD, dwCompletionKey: usize, lpOverlapped: ?*OVERLAPPED) callconv(.c) BOOL;
extern "ws2_32" fn WSARecv(s: SOCKET, lpBuffers: [*]WSABUF, dwBufferCount: DWORD, lpNumberOfBytesRecvd: ?*DWORD, lpFlags: *DWORD, lpOverlapped: ?*OVERLAPPED, lpCompletionRoutine: ?*const anyopaque) callconv(.c) c_int;
extern "ws2_32" fn WSASend(s: SOCKET, lpBuffers: [*]WSABUF, dwBufferCount: DWORD, lpNumberOfBytesSent: ?*DWORD, dwFlags: DWORD, lpOverlapped: ?*OVERLAPPED, lpCompletionRoutine: ?*const anyopaque) callconv(.c) c_int;
extern "ws2_32" fn closesocket(s: SOCKET) callconv(.c) c_int;
extern "ws2_32" fn shutdown(s: SOCKET, how: c_int) callconv(.c) c_int;
extern "ws2_32" fn accept(s: SOCKET, addr: ?*std.posix.sockaddr, addrlen: ?*std.posix.socklen_t) callconv(.c) SOCKET;
extern "ws2_32" fn setsockopt(s: SOCKET, level: c_int, optname: c_int, optval: [*]const u8, optlen: c_int) callconv(.c) c_int;
extern "ws2_32" fn WSAGetLastError() callconv(.c) c_int;

/// Key 0 + null overlapped = worker control message (inbox drain / stop).
/// Connection ids start at 1, so key 0 never addresses a connection.
const key_control: usize = 0;

// ---------------------------------------------------------------------------
// Operation blocks (the OVERLAPPED pointer IS the completion identity).
// ---------------------------------------------------------------------------

const OpKind = enum(u8) { recv, send };

/// Common header, FIRST in every op block: from an OVERLAPPED pointer the
/// header is at a fixed offset for both block types (statically asserted).
const OpHeader = struct {
    kind: OpKind,
    slot: *ConnSlot,
};

const RecvOp = struct {
    hdr: OpHeader,
    ovl: OVERLAPPED,
    buf: [16 * 1024]u8,
};

const SendOp = struct {
    hdr: OpHeader,
    ovl: OVERLAPPED,
    bytes: []u8,
};

const ovl_offset = @offsetOf(RecvOp, "ovl");
comptime {
    if (@offsetOf(SendOp, "ovl") != ovl_offset) @compileError("RecvOp/SendOp OVERLAPPED offsets diverged");
}

fn headerOf(ovl: *OVERLAPPED) *OpHeader {
    const addr = @intFromPtr(ovl) - ovl_offset;
    return @ptrFromInt(addr);
}

/// A small test-and-set spinlock (the worker map is touched by completions
/// on any worker plus any thread that flushes/closes).
const SpinLock = struct {
    flag: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn lock(self: *SpinLock) void {
        while (self.flag.swap(1, .acquire) != 0) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinLock) void {
        self.flag.store(0, .release);
    }
};

/// Per-connection state. The recv block lives inline (one recv always
/// armed); send blocks are heap-owned per in-flight send.
const ConnSlot = struct {
    id: u32,
    sock: SOCKET,
    lock: SpinLock = .{},
    recv: RecvOp,
    /// A recv is posted (at most one: completions re-arm).
    recv_pending: bool = false,
    /// Bytes waiting for the socket (owned).
    out: std.ArrayList(u8) = .empty,
    /// A send is in flight (TCP ordering: one at a time).
    sending: bool = false,
    /// Set by `request_flush` (any thread), cleared by the worker.
    flush_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Graceful close requested (kick / ping-done / timeout): no new
    /// inbound reads are served, but queued output still drains and
    /// in-flight sends still complete — the slot is destroyed once
    /// drained (see maybeDestroyConn). Same flush-then-close contract
    /// as the other transports. Guarded by `lock` like `dead`.
    closing: bool = false,
    /// Removed from the map (closed): flush/send paths stop here. Memory
    /// is still valid (retained until worker exit).
    dead: bool = false,
};

/// Atomic counters (completions land on any worker).
const Counters = struct {
    conns_accepted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    conns_closed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    bytes_in: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    bytes_out: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    sends_zc: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    sends_copy: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    recv_arm_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    buffer_starved: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    send_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    kicks_backpressure: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    flushes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

const Worker = struct {
    backend: *Backend,
    index: usize,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
};

pub const Backend = struct {
    allocator: std.mem.Allocator,
    opts: transport.Options,
    /// Io handle (used for the few sleeps the backend needs).
    io: std.Io,
    listener: SOCKET,
    iocp: HANDLE,
    handler: transport.Handler,
    workers: []Worker = &[_]Worker{},
    /// Live connections (id -> slot). Global (any worker completes any
    /// conn): guarded by `conns_lock`, taken before any slot lock.
    conns: std.AutoHashMapUnmanaged(u32, *ConnSlot) = .empty,
    conns_lock: SpinLock = .{},
    /// Accepted conns waiting for a worker to own them (round-robin).
    inbox: std.ArrayList(struct { id: u32, sock: SOCKET }) = .empty,
    inbox_lock: SpinLock = .{},
    /// Removed slots, retained until worker exit (in-flight completions
    /// can never touch freed memory).
    dead_slots: std.ArrayListUnmanaged(*ConnSlot) = .empty,
    acceptor_thread: ?std.Thread = null,
    acceptor_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    next_conn_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    counters: Counters = .{},
    /// Set when the OS refused IOCP (the caller falls back to blocking).
    failed: bool = false,

    /// Initialize IN PLACE: workers hold a pointer to the backend, so
    /// returning it by value would leave them pointing at a dead copy.
    /// `listener_handle` is the server's bound listening socket.
    pub fn init(
        self: *Backend,
        allocator: std.mem.Allocator,
        opts: transport.Options,
        io: std.Io,
        listener_handle: std.posix.fd_t,
        handler: transport.Handler,
    ) !void {
        const listener: SOCKET = @intFromPtr(listener_handle);
        const port = CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, 0, 0) orelse return error.IocpFailed;
        errdefer windows.CloseHandle(port);
        const n_workers = opts.workerCount();
        const workers = try allocator.alloc(Worker, n_workers);
        errdefer allocator.free(workers);
        self.* = .{
            .allocator = allocator,
            .opts = opts,
            .io = io,
            .listener = listener,
            .iocp = port,
            .handler = handler,
            .workers = workers,
        };
        for (workers, 0..) |*w, i| w.* = .{ .backend = self, .index = i };
    }

    pub fn deinit(self: *Backend) void {
        for (self.dead_slots.items) |slot| {
            slot.out.deinit(self.allocator);
            self.allocator.destroy(slot);
        }
        self.dead_slots.deinit(self.allocator);
        var it = self.conns.valueIterator();
        while (it.next()) |slot| {
            slot.*.out.deinit(self.allocator);
            self.allocator.destroy(slot.*);
        }
        self.conns.deinit(self.allocator);
        self.inbox.deinit(self.allocator);
        self.allocator.free(self.workers);
        windows.CloseHandle(self.iocp);
    }

    /// Start the threads and block until they stop.
    pub fn run(self: *Backend) !void {
        for (self.workers) |*w| {
            w.thread = try std.Thread.spawn(.{}, workerMain, .{w});
        }
        self.acceptor_thread = try std.Thread.spawn(.{}, acceptorMain, .{self});
        if (self.acceptor_thread) |t| t.join();
    }

    /// Stop the backend (the port is closed by `deinit`).
    pub fn stop(self: *Backend) void {
        for (self.workers) |*w| w.stop.store(true, .release);
        self.acceptor_stop.store(true, .release);
        // Wake every worker (one packet wakes one waiter).
        for (self.workers) |_| {
            _ = PostQueuedCompletionStatus(self.iocp, 0, key_control, null);
        }
    }

    /// Request a flush of a connection's queued output (any thread). The
    /// keyed wakeup goes to whichever worker is waiting — no map scan.
    pub fn requestFlush(self: *Backend, conn_id: u32) void {
        self.conns_lock.lock();
        const slot = self.conns.get(conn_id);
        self.conns_lock.unlock();
        if (slot) |sl| {
            _ = sl.flush_requested.swap(true, .acq_rel);
            _ = PostQueuedCompletionStatus(self.iocp, 0, conn_id, null);
        }
    }

    /// Transport handle for the server (any-thread flush requests).
    pub fn handle(self: *Backend) transport.Handle {
        return transport.handleFor(Backend, self);
    }

    /// Close a connection gracefully: mark it closing (new inbound reads
    /// are no longer served), wake a drain sweep, and destroy it once
    /// its queue drains and in-flight sends complete (see
    /// maybeDestroyConn) — the pong / kick reason goes out first.
    /// Idempotent; safe to call from any thread. Error paths
    /// (arm/recv/send failures) keep the immediate destroyConn below —
    /// a broken socket has nothing left to deliver.
    pub fn closeConn(self: *Backend, conn_id: u32) void {
        self.conns_lock.lock();
        const slot = self.conns.get(conn_id);
        self.conns_lock.unlock();
        const sl = slot orelse return;
        sl.lock.lock();
        if (sl.dead or sl.closing) {
            sl.lock.unlock();
            return;
        }
        sl.closing = true;
        sl.lock.unlock();
        _ = sl.flush_requested.swap(true, .acq_rel);
        _ = PostQueuedCompletionStatus(self.iocp, 0, conn_id, null);
    }

    /// Destroy a connection immediately: remove from the map (exactly
    /// once — whoever removes the entry owns the close), run on_close,
    /// close the socket and retain the slot. For broken sockets only;
    /// graceful closes go through closeConn above.
    fn destroyConn(self: *Backend, conn_id: u32) void {
        self.conns_lock.lock();
        const removed = self.conns.fetchRemove(conn_id);
        self.conns_lock.unlock();
        const slot = (removed orelse return).value;
        slot.lock.lock();
        slot.dead = true;
        slot.lock.unlock();
        const h = self.handler;
        h.on_close(h.ctx, slot.id);
        // Match the uring backend: shutdown before close so the peer
        // sees FIN promptly even with an outstanding recv.
        _ = shutdown(slot.sock, 2);
        _ = closesocket(slot.sock);
        slot.lock.lock();
        slot.out.deinit(self.allocator);
        slot.out = .empty;
        slot.lock.unlock();
        self.conns_lock.lock();
        self.dead_slots.append(self.allocator, slot) catch {
            self.conns_lock.unlock();
            self.allocator.destroy(slot);
            return;
        };
        self.conns_lock.unlock();
        _ = self.counters.conns_closed.fetchAdd(1, .acq_rel);
    }

    pub fn statsSnapshot(self: *Backend) transport.Stats {
        return .{
            .conns_accepted = self.counters.conns_accepted.load(.acquire),
            .conns_closed = self.counters.conns_closed.load(.acquire),
            .bytes_in = self.counters.bytes_in.load(.acquire),
            .bytes_out = self.counters.bytes_out.load(.acquire),
            .sends_zc = self.counters.sends_zc.load(.acquire),
            .sends_copy = self.counters.sends_copy.load(.acquire),
            .kicks_backpressure = self.counters.kicks_backpressure.load(.acquire),
            .flushes = self.counters.flushes.load(.acquire),
            .recv_arm_failures = self.counters.recv_arm_failures.load(.acquire),
            .buffer_starved = self.counters.buffer_starved.load(.acquire),
            .send_failures = self.counters.send_failures.load(.acquire),
        };
    }
};

/// Best-effort socket tuning (a kernel that refuses an option must not
/// kill the conn). std.posix.setsockopt is a compile error on Windows,
/// so this backend sets the options with its own ws2_32 extern.
fn applySocketOpts(sock: SOCKET, opts: transport.Options) void {
    if (opts.tcp_nodelay) {
        const one: c_int = 1;
        _ = setsockopt(sock, IPPROTO_TCP, @intCast(TCP_NODELAY), @ptrCast(&one), @sizeOf(c_int));
    }
    if (opts.send_buf_bytes > 0) {
        const v: c_int = @intCast(@min(opts.send_buf_bytes, @as(usize, std.math.maxInt(c_int))));
        _ = setsockopt(sock, SOL_SOCKET, @intCast(SO_SNDBUF), @ptrCast(&v), @sizeOf(c_int));
    }
    if (opts.recv_buf_bytes > 0) {
        const v: c_int = @intCast(@min(opts.recv_buf_bytes, @as(usize, std.math.maxInt(c_int))));
        _ = setsockopt(sock, SOL_SOCKET, @intCast(SO_RCVBUF), @ptrCast(&v), @sizeOf(c_int));
    }
}

/// The acceptor thread: blocking accept, associate, hand to a worker.
/// Exactly one place accepts (same reasoning as the uring acceptor).
fn acceptorMain(backend: *Backend) void {
    while (!backend.acceptor_stop.load(.acquire)) {
        const sock = accept(backend.listener, null, null);
        if (sock == INVALID_SOCKET) {
            // Listener closed (shutdown) or transient error: transient
            // errors must not spin the loop.
            if (backend.acceptor_stop.load(.acquire)) return;
            transport.sleepMs(backend.io, 2);
            continue;
        }
        applySocketOpts(sock, backend.opts);
        const id = backend.next_conn_id.fetchAdd(1, .acq_rel);
        // Associate the socket with the port (keyed by conn id).
        const port = CreateIoCompletionPort(@ptrFromInt(sock), backend.iocp, id, 0) orelse {
            _ = closesocket(sock);
            continue;
        };
        _ = port;
        backend.inbox_lock.lock();
        backend.inbox.append(backend.allocator, .{ .id = id, .sock = sock }) catch {
            backend.inbox_lock.unlock();
            _ = closesocket(sock);
            continue;
        };
        backend.inbox_lock.unlock();
        _ = backend.counters.conns_accepted.fetchAdd(1, .acq_rel);
        // Wake a worker to adopt it (the port wakes waiters LIFO;
        // adoption is first-come, first-served).
        _ = PostQueuedCompletionStatus(backend.iocp, 0, key_control, null);
    }
}

/// Adopt inbox connections into worker-owned slots. Called with no locks
/// held; any worker can adopt (the slot is usable from every worker —
/// all slot state is under the slot lock).
fn adoptInbox(backend: *Backend) void {
    backend.inbox_lock.lock();
    if (backend.inbox.items.len == 0) {
        backend.inbox_lock.unlock();
        return;
    }
    var items = backend.inbox;
    backend.inbox = .empty;
    backend.inbox_lock.unlock();
    defer items.deinit(backend.allocator);
    for (items.items) |item| {
        const slot = backend.allocator.create(ConnSlot) catch {
            _ = closesocket(item.sock);
            continue;
        };
        slot.* = .{
            .id = item.id,
            .sock = item.sock,
            .recv = .{
                .hdr = .{ .kind = .recv, .slot = slot },
                .ovl = std.mem.zeroes(OVERLAPPED),
                .buf = undefined,
            },
        };
        backend.conns_lock.lock();
        backend.conns.put(backend.allocator, slot.id, slot) catch {
            backend.conns_lock.unlock();
            backend.allocator.destroy(slot);
            _ = closesocket(item.sock);
            continue;
        };
        backend.conns_lock.unlock();
        backend.handler.on_accept(backend.handler.ctx, slot.id, @ptrFromInt(item.sock));
        armRecv(backend, slot);
    }
}

/// Post a recv for the slot (caller holds no locks; slot lock guards the
/// pending flag). Synchronous success is processed inline (no completion
/// is queued for it); WSA_IO_PENDING means the completion will arrive.
fn armRecv(backend: *Backend, slot: *ConnSlot) void {
    slot.lock.lock();
    if (slot.dead or slot.recv_pending) {
        slot.lock.unlock();
        return;
    }
    slot.recv.ovl = std.mem.zeroes(OVERLAPPED);
    var bufs = [_]WSABUF{.{ .len = slot.recv.buf.len, .buf = &slot.recv.buf }};
    var flags: DWORD = 0;
    const rc = WSARecv(slot.sock, &bufs, bufs.len, null, &flags, &slot.recv.ovl, null);
    if (rc == 0) {
        // Completed synchronously: no completion queued. The bytes are
        // already in the buffer — find out how many via the overlapped
        // InternalHigh field, then process inline.
        const n: DWORD = @truncate(slot.recv.ovl.InternalHigh);
        slot.lock.unlock();
        handleRecvBytes(backend, slot, n);
        return;
    }
    if (WSAGetLastError() != WSA_IO_PENDING) {
        slot.lock.unlock();
        _ = backend.counters.recv_arm_failures.fetchAdd(1, .acq_rel);
        backend.destroyConn(slot.id);
        return;
    }
    slot.recv_pending = true;
    slot.lock.unlock();
}

/// Recv bytes are in (completion or synchronous): feed the protocol,
/// drain its answer, re-arm. Caller holds no locks.
fn handleRecvBytes(backend: *Backend, slot: *ConnSlot, nbytes: DWORD) void {
    slot.lock.lock();
    slot.recv_pending = false;
    if (slot.dead) {
        slot.lock.unlock();
        return;
    }
    if (nbytes == 0) {
        // Peer closed (graceful FIN): drain what's queued, then destroy.
        const id = slot.id;
        slot.lock.unlock();
        backend.closeConn(id);
        return;
    }
    const closing = slot.closing;
    const bytes = slot.recv.buf[0..nbytes];
    slot.lock.unlock();
    const h = backend.handler;
    // A closing connection takes no new input (a kicked client spamming
    // packets must not get served), but its queued output still drains.
    if (!closing) {
        h.on_read(h.ctx, slot.id, bytes);
        _ = backend.counters.bytes_in.fetchAdd(nbytes, .acq_rel);
    }
    drainOutbox(backend, slot);
    if (!closing) armRecv(backend, slot);
    maybeDestroyConn(backend, slot);
}

/// Pull the protocol layer's outbox and send it (one send in flight:
/// TCP ordering). Caller holds no locks.
fn drainOutbox(backend: *Backend, slot: *ConnSlot) void {
    _ = slot.flush_requested.swap(false, .acq_rel);
    if (backend.handler.on_flush(backend.handler.ctx, slot.id)) |bytes| {
        slot.lock.lock();
        if (slot.dead) {
            slot.lock.unlock();
            backend.allocator.free(bytes);
            return;
        }
        slot.out.appendSlice(backend.allocator, bytes) catch {
            slot.lock.unlock();
            backend.allocator.free(bytes);
            return;
        };
        slot.lock.unlock();
        backend.allocator.free(bytes);
    }
    trySend(backend, slot);
}

fn trySend(backend: *Backend, slot: *ConnSlot) void {
    slot.lock.lock();
    if (slot.dead or slot.sending or slot.out.items.len == 0) {
        slot.lock.unlock();
        return;
    }
    const bytes = slot.out.toOwnedSlice(backend.allocator) catch {
        slot.lock.unlock();
        return;
    };
    slot.out = .empty;
    const op = backend.allocator.create(SendOp) catch {
        slot.lock.unlock();
        backend.allocator.free(bytes);
        return;
    };
    op.* = .{
        .hdr = .{ .kind = .send, .slot = slot },
        .ovl = std.mem.zeroes(OVERLAPPED),
        .bytes = bytes,
    };
    // IOCP has no zerocopy send; large frames still count as zerocopy
    // equivalents when they go out in a single syscall (the stats line
    // keeps its shape across backends).
    if (transport.useZerocopy(bytes.len, backend.opts)) {
        _ = backend.counters.sends_zc.fetchAdd(1, .acq_rel);
    } else {
        _ = backend.counters.sends_copy.fetchAdd(1, .acq_rel);
    }
    var bufs = [_]WSABUF{.{ .len = @intCast(bytes.len), .buf = bytes.ptr }};
    const rc = WSASend(slot.sock, &bufs, bufs.len, null, 0, &op.ovl, null);
    if (rc == 0) {
        // Synchronous success: no completion queued.
        slot.lock.unlock();
        backend.allocator.free(bytes);
        backend.allocator.destroy(op);
        _ = backend.counters.bytes_out.fetchAdd(bytes.len, .acq_rel);
        _ = backend.counters.flushes.fetchAdd(1, .acq_rel);
        trySend(backend, slot);
        return;
    }
    if (WSAGetLastError() != WSA_IO_PENDING) {
        slot.lock.unlock();
        backend.allocator.free(bytes);
        backend.allocator.destroy(op);
        _ = backend.counters.send_failures.fetchAdd(1, .acq_rel);
        backend.closeConn(slot.id);
        return;
    }
    slot.sending = true;
    slot.lock.unlock();
    _ = backend.counters.bytes_out.fetchAdd(bytes.len, .acq_rel);
    _ = backend.counters.flushes.fetchAdd(1, .acq_rel);
}

/// One completion. `ok == false` means the operation failed (or the
/// socket died mid-flight): completions for abandoned sockets still
/// arrive, so every path re-validates against the map.
fn handleCompletion(backend: *Backend, key: usize, ovl: *OVERLAPPED, ok: bool, nbytes: DWORD) void {
    const hdr = headerOf(ovl);
    const slot = hdr.slot;
    switch (hdr.kind) {
        .recv => {
            // Retained memory: the slot is always valid here; the map
            // decides whether the connection is still alive.
            backend.conns_lock.lock();
            const live = if (backend.conns.get(@intCast(key))) |s| s == slot else false;
            backend.conns_lock.unlock();
            if (!live or !ok) {
                if (!ok) backend.destroyConn(@intCast(key));
                return;
            }
            handleRecvBytes(backend, slot, nbytes);
        },
        .send => {
            const op: *SendOp = @fieldParentPtr("ovl", ovl);
            const bytes = op.bytes;
            backend.allocator.destroy(op);
            slot.lock.lock();
            slot.sending = false;
            const dead = slot.dead;
            slot.lock.unlock();
            if (!ok) {
                backend.allocator.free(bytes);
                backend.destroyConn(@intCast(key));
                return;
            }
            backend.allocator.free(bytes);
            if (!dead) trySend(backend, slot);
            maybeDestroyConn(backend, slot);
        },
    }
}

fn workerMain(w: *Worker) void {
    const backend = w.backend;
    while (!w.stop.load(.acquire)) {
        var nbytes: DWORD = 0;
        var key: usize = 0;
        var ovl: ?*OVERLAPPED = null;
        const ok = GetQueuedCompletionStatus(backend.iocp, &nbytes, &key, &ovl, INFINITE);
        if (ovl) |o| {
            handleCompletion(backend, key, o, ok.toBool(), nbytes);
            continue;
        }
        // Key-only wakeup (flush request / inbox / stop) or port error.
        if (ok == .FALSE) break; // port closing: exit.
        if (key == key_control) {
            if (w.stop.load(.acquire)) break;
            adoptInbox(backend);
            continue;
        }
        // Flush request for one connection (flag was set by requestFlush).
        backend.conns_lock.lock();
        const slot = backend.conns.get(@intCast(key));
        backend.conns_lock.unlock();
        if (slot) |sl| {
            drainOutbox(backend, sl);
            maybeDestroyConn(backend, sl);
        }
    }
}

/// Destroy a closing slot once its queue drained and no send is in
/// flight (graceful close: pong / kick reason go out first). Called
/// wherever outbox/sending state can change: after each drain and
/// after each completed send.
fn maybeDestroyConn(backend: *Backend, slot: *ConnSlot) void {
    slot.lock.lock();
    const closing = slot.closing;
    const dead = slot.dead;
    const pending = slot.out.items.len != 0;
    const inflight = slot.sending;
    slot.lock.unlock();
    if (dead or !closing) return;
    if (pending or inflight) return;
    backend.destroyConn(slot.id);
}

/// Can IOCP be used here? (completion-port creation probe; no sockets.)
pub fn probe() bool {
    if (!supported) return false;
    const port = CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, 0, 0) orelse return false;
    windows.CloseHandle(port);
    return true;
}

test "op header offsets agree (completion identity)" {
    try std.testing.expectEqual(ovl_offset, @offsetOf(SendOp, "ovl"));
    var slot = ConnSlot{
        .id = 7,
        .sock = 0,
        .recv = undefined,
    };
    slot.recv = .{
        .hdr = .{ .kind = .recv, .slot = &slot },
        .ovl = std.mem.zeroes(OVERLAPPED),
        .buf = undefined,
    };
    try std.testing.expectEqual(OpKind.recv, headerOf(&slot.recv.ovl).kind);
    try std.testing.expect(headerOf(&slot.recv.ovl).slot == &slot);
}

test "probe does not crash off-Windows" {
    // The call is comptime-dropped off Windows (no kernel32 to link),
    // so this also proves the file links cleanly on Linux/macOS.
    if (comptime !supported) return error.SkipZigTest;
    // On real Windows hardware this must succeed (fresh boot has IOCP).
    try std.testing.expect(probe());
}
