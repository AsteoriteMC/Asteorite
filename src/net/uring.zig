//! Linux io_uring transport — Phase B ("async zero-copy").
//!
//! Shape (one ring per worker thread, never per connection):
//!
//!   acceptor thread  -- ring A -- multishot accept on the listener
//!         |
//!         +-- hands (conn_id, fd) to a worker's inbox and wakes it
//!
//!   worker thread 0  -- ring 0 -- multishot recv (provided buffers)
//!   worker thread 1  -- ring 1 -- multishot recv (provided buffers)
//!
//! Why provided buffers: a multishot recv keeps the kernel pointing at
//! user memory between CQEs ("the kernel can't borrow user memory between
//! multishot events"), so the buffers must be registered with the ring
//! (IORING_REGISTER_PBUF_RING, kernel 6.10+) or handed over with
//! IORING_OP_PROVIDE_BUFFERS. Buffers are recycled: every data CQE hands
//! its buffer back to the ring once the bytes have been copied into the
//! protocol layer.
//!
//! Sends: frames at or above `send_zc_threshold` go out with
//! IORING_OP_SEND_ZC (the kernel pins the pages and sends zero-copy; the
//! completion arrives in two steps — the data CQE and a later NOTIF that
//! releases the buffer). Smaller frames use a plain SEND: copying a few
//! hundred bytes is cheaper than the zerocopy notification round trip.
//!
//! Ordering: at most ONE send per connection is in flight. io_uring does
//! not guarantee that two sends on the same socket keep their order, and
//! TCP does. The next send is submitted when the previous data CQE lands.
//!
//! The protocol layer is reached through `transport.Handler`; this file
//! never imports the server.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const IoUring = linux.IoUring;
const transport = @import("transport.zig");

const posix = std.posix;

pub const supported = builtin.os.tag == .linux;

/// user_data layout: [60..64) kind, [32..60) sequence, [0..32) conn id.
const kind_shift = 60;
const seq_shift = 32;
const conn_mask: u64 = 0xFFFF_FFFF;

const KindRecv: u64 = 1;
const KindSend: u64 = 2;
const KindSendNotif: u64 = 3;
const KindAccept: u64 = 4;
/// The kernel posts eventfd notifications with user_data == 0.
const KindEventfd: u64 = 0;
/// A no-op SQE the acceptor submits to a worker's ring to wake it up
/// (the ring's SQ is shared between the worker and the acceptor, so the
/// submission queue needs a lock).
const KindWake: u64 = 6;

fn makeTag(kind: u64, conn_id: u32, seq: u32) u64 {
    return (kind << kind_shift) | (@as(u64, seq) << seq_shift) | conn_id;
}

fn tagKind(user_data: u64) u64 {
    return (user_data >> kind_shift) & 0xF;
}

fn tagSeq(user_data: u64) u32 {
    return @truncate((user_data >> seq_shift) & 0x0FFF_FFFF);
}

fn tagConn(user_data: u64) u32 {
    return @truncate(user_data & conn_mask);
}

/// A small test-and-set spinlock (the worker inbox is touched by the
/// acceptor thread and by the worker thread).
const SpinLock = struct {
    flag: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn lock(self: *SpinLock) void {
        while (self.flag.swap(1, .acquire) != 0) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinLock) void {
        self.flag.store(0, .release);
    }
};

/// A send in flight (or waiting for its zerocopy notification).
const SendState = struct {
    seq: u32 = 0,
    bytes: []u8 = &[_]u8{},
    zerocopy: bool = false,
};

/// Per-connection state owned by a worker.
const ConnSlot = struct {
    id: u32,
    fd: posix.fd_t,
    /// Set by `request_flush` (any thread), cleared by the worker.
    flush_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// True while a send is in flight (ordering guarantee).
    sending: bool = false,
    /// The in-flight send.
    inflight: SendState = .{},
    /// Zerocopy buffers waiting for their NOTIF.
    zc_pending: std.ArrayList(SendState) = .empty,
    /// Bytes queued for the next send.
    out: std.ArrayList(u8) = .empty,
    /// Sequence counter for send tags.
    next_seq: u32 = 1,
    /// The recv SQE is armed.
    recv_armed: bool = false,
    /// Retired by the close path (any thread): flush/send paths stop
    /// here. Retention (dead_slots) keeps the memory valid, so no path
    /// ever waits — the old refcount spin deadlocked when an
    /// overflow kick fired mid-flush (the flusher held the ref the
    /// closer spun on).
    dead: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// A worker: one ring, many connections.
const Worker = struct {
    backend: *Backend,
    index: usize,
    ring: IoUring,
    buffers: IoUring.BufferGroup,
    /// Wakeup fd registered with the ring (eventfd).
    wakeup_fd: posix.fd_t = -1,
    /// Accepted connections handed over by the acceptor thread.
    inbox: std.ArrayList(InboxItem) = .empty,
    inbox_lock: SpinLock = .{},
    /// Guards the submission queue: the worker and the acceptor both
    /// submit to this ring.
    sq_lock: SpinLock = .{},
    /// Live connections (id -> slot). Guarded by `conns_lock`: the
    /// owning worker and any thread that closes a connection touch it.
    conns: std.AutoHashMapUnmanaged(u32, *ConnSlot) = .empty,
    conns_lock: SpinLock = .{},
    /// Closed connections. Their memory is kept until the worker exits:
    /// a slot can still be referenced by an in-flight completion, and
    /// freeing it early meant a later close closed an unrelated fd (a
    /// ring fd -> the worker died with EBADR).
    dead_slots: std.ArrayListUnmanaged(*ConnSlot) = .empty,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    const InboxItem = struct { id: u32, fd: posix.fd_t };

    fn init(backend: *Backend, index: usize, opts: transport.Options) !Worker {
        var ring = try IoUring.init(opts.ring_entries, 0);
        errdefer ring.deinit();
        var buffers = try IoUring.BufferGroup.init(&ring, backend.allocator, 1, @intCast(opts.buf_size), opts.buf_ring_entries);
        errdefer buffers.deinit(backend.allocator);
        // Wakeup fd: the server signals it when it queues output for a
        // connection owned by this worker.
        const efd = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(efd) != .SUCCESS) return error.WakeupFailed;
        errdefer _ = linux.close(@intCast(efd));
        try ring.register_eventfd(@intCast(efd));
        return .{
            .backend = backend,
            .index = index,
            .ring = ring,
            .buffers = buffers,
            .wakeup_fd = @intCast(efd),
        };
    }

    fn deinit(self: *Worker) void {
        self.buffers.deinit(self.backend.allocator);
        self.ring.deinit();
        if (self.wakeup_fd >= 0) {
            _ = linux.close(self.wakeup_fd);
            self.wakeup_fd = -1;
        }
        var it = self.conns.valueIterator();
        while (it.next()) |slot| {
            self.backend.allocator.destroy(slot.*);
        }
        self.conns.deinit(self.backend.allocator);
        self.inbox.deinit(self.backend.allocator);
    }

    fn enqueue(self: *Worker, id: u32, fd: posix.fd_t) void {
        self.inbox_lock.lock();
        self.inbox.append(self.backend.allocator, .{ .id = id, .fd = fd }) catch {
            self.inbox_lock.unlock();
            _ = linux.close(fd);
            return;
        };
        self.inbox_lock.unlock();
        self.signal();
    }

    fn signal(self: *Worker) void {
        if (self.wakeup_fd < 0) return;
        const buf = [_]u8{0} ** 8;
        _ = linux.write(self.wakeup_fd, &buf, 8);
    }

    /// Wake the worker out of `io_uring_enter` so it notices the inbox.
    ///
    /// The registered eventfd only *signals* (it does not produce a CQE
    /// and does not interrupt the wait), so the wakeup is a real SQE: a
    /// NOP whose completion the worker sees on its next loop.
    fn wakeRing(self: *Worker) void {
        self.sq_lock.lock();
        defer self.sq_lock.unlock();
        const sqe = self.ring.nop(makeTag(KindWake, 0, 0)) catch return;
        _ = sqe;
        _ = self.ring.submit() catch {};
    }

    fn requestStop(self: *Worker) void {
        self.stop.store(true, .release);
        self.signal();
        self.wakeRing();
    }
};

/// Atomic counters (several threads update them).
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

/// The io_uring backend: owns the acceptor thread and the worker threads.
pub const Backend = struct {
    allocator: std.mem.Allocator,
    opts: transport.Options,
    /// Io handle (used for the few sleeps the backend needs).
    io: std.Io,
    listener_fd: posix.fd_t,
    handler: transport.Handler,
    workers: []Worker = &[_]Worker{},
    acceptor: ?Acceptor = null,
    next_conn_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    next_worker: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    counters: Counters = .{},
    /// Set when the kernel refused io_uring (the caller falls back).
    failed: bool = false,

    const Acceptor = struct {
        backend: *Backend,
        ring: IoUring,
        thread: ?std.Thread = null,
        stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn init(backend: *Backend) !Acceptor {
            var ring = try IoUring.init(64, 0);
            errdefer ring.deinit();
            return .{ .backend = backend, .ring = ring };
        }

        fn deinit(self: *Acceptor) void {
            self.ring.deinit();
        }

        fn main(self: *Acceptor) void {
            const backend = self.backend;
            // Multishot accept: one SQE, many CQEs. The SQE stays armed
            // while the kernel reports IORING_CQE_F_MORE; when it does
            // not (an error cancelled it), it is re-armed — otherwise the
            // listener goes deaf after the first hiccup.
            const arm = struct {
                fn f(a: *Acceptor) bool {
                    _ = a.ring.accept_multishot(makeTag(KindAccept, 0, 0), a.backend.listener_fd, null, null, posix.SOCK.CLOEXEC) catch return false;
                    _ = a.ring.submit() catch return false;
                    return true;
                }
            }.f;
            if (!arm(self)) {
                backend.failed = true;
                return;
            }
            var cqes: [64]linux.io_uring_cqe = undefined;
            while (!self.stop.load(.acquire)) {
                const n = self.ring.copy_cqes(&cqes, 1) catch |err| switch (err) {
                    error.SignalInterrupt => continue,
                    else => break,
                };
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const cqe = cqes[i];
                    const more = (cqe.flags & linux.IORING_CQE_F_MORE) != 0;
                    if (cqe.res < 0) {
                        // Accept failed (EMFILE, ECONNABORTED, ...).
                        if (cqe.res == -@as(i32, @intCast(@intFromEnum(linux.E.MFILE))) or
                            cqe.res == -@as(i32, @intCast(@intFromEnum(linux.E.NFILE))))
                        {
                            sleepMs(self.backend.io, 2);
                        }
                        if (!more) _ = arm(self);
                        continue;
                    }
                    const fd: posix.fd_t = @intCast(cqe.res);
                    transport.applySocketOpts(fd, backend.opts);
                    const id = backend.next_conn_id.fetchAdd(1, .acq_rel);
                    const widx = backend.next_worker.fetchAdd(1, .acq_rel) % backend.workers.len;
                    backend.workers[widx].enqueue(id, fd);
                    backend.workers[widx].wakeRing();
                    _ = backend.counters.conns_accepted.fetchAdd(1, .acq_rel);
                    if (!more) _ = arm(self);
                }
            }
        }
    };

    /// Create the backend IN PLACE. `listener_fd` is an already-bound,
    /// listening socket (the server owns it and closes it).
    ///
    /// The backend MUST be initialized in place: the workers and the
    /// acceptor hold a pointer to it, so returning it by value would leave
    /// them pointing at a dead stack copy.
    pub fn init(
        self: *Backend,
        allocator: std.mem.Allocator,
        opts: transport.Options,
        io: std.Io,
        listener_fd: posix.fd_t,
        handler: transport.Handler,
    ) !void {
        const n_workers = opts.workerCount();
        const workers = try allocator.alloc(Worker, n_workers);
        errdefer allocator.free(workers);
        self.* = .{
            .allocator = allocator,
            .opts = opts,
            .io = io,
            .listener_fd = listener_fd,
            .handler = handler,
            .workers = workers,
        };
        var made: usize = 0;
        errdefer {
            for (workers[0..made]) |*w| w.deinit();
        }
        while (made < n_workers) : (made += 1) {
            workers[made] = try Worker.init(self, made, opts);
            // The buffer group keeps a pointer to its ring: the worker was
            // copied into the array, so re-point it at the copy that lives
            // there (the array never moves).
            workers[made].buffers.ring = &workers[made].ring;
        }
        // The acceptor gets its own ring: several rings accepting on the
        // same listening socket is not well defined, so accepting happens
        // in exactly one place and hands the fd to a worker.
        self.acceptor = try Acceptor.init(self);
    }

    pub fn deinit(self: *Backend) void {
        if (self.acceptor) |*a| a.deinit();
        for (self.workers) |*w| w.deinit();
        self.allocator.free(self.workers);
    }

    /// Start the threads and block until they stop.
    pub fn run(self: *Backend) !void {
        for (self.workers) |*w| {
            w.thread = try std.Thread.spawn(.{}, workerMain, .{w});
        }
        if (self.acceptor) |*a| {
            a.thread = try std.Thread.spawn(.{}, Acceptor.main, .{a});
        }
        if (self.acceptor) |*a| {
            if (a.thread) |t| t.join();
        }
    }

    /// Stop the backend (the rings are closed by `deinit`).
    pub fn stop(self: *Backend) void {
        for (self.workers) |*w| w.requestStop();
        if (self.acceptor) |*a| a.stop.store(true, .release);
    }

    /// Request a flush of a connection's queued output (any thread).
    ///
    /// The worker may be parked in `io_uring_enter`, so the request also
    /// submits a wakeup SQE: the registered eventfd only *signals* (it
    /// never interrupts the wait), so a real SQE is what makes the worker
    /// look at the outbox.
    pub fn requestFlush(self: *Backend, conn_id: u32) void {
        for (self.workers) |*w| {
            w.conns_lock.lock();
            const slot = w.conns.get(conn_id);
            w.conns_lock.unlock();
            if (slot) |sl| {
                _ = sl.flush_requested.swap(true, .acq_rel);
                w.signal();
                w.wakeRing();
                return;
            }
        }
    }

    /// Transport handle for the server (any-thread flush requests).
    pub fn handle(self: *Backend) transport.Handle {
        return .{
            .request_flush = struct {
                fn f(ctx: *anyopaque, conn_id: u32) void {
                    const b: *Backend = @ptrCast(@alignCast(ctx));
                    b.requestFlush(conn_id);
                }
            }.f,
            .close_conn = struct {
                fn f(ctx: *anyopaque, conn_id: u32) void {
                    const b: *Backend = @ptrCast(@alignCast(ctx));
                    b.closeConn(conn_id);
                }
            }.f,
            .ctx = self,
        };
    }

    /// Close a connection (the transport owns the socket).
    ///
    /// The slot is removed from the map BEFORE the close, so a concurrent
    /// close (the recv error path) cannot close the same connection
    /// twice: a double close freed the conn and then waited on its
    /// (freed) refcount.
    pub fn closeConn(self: *Backend, conn_id: u32) void {
        for (self.workers) |*w| {
            w.conns_lock.lock();
            const present = w.conns.contains(conn_id);
            w.conns_lock.unlock();
            if (!present) continue;
            workerCloseConn(w, conn_id);
            return;
        }
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

/// The worker main loop.
fn workerMain(w: *Worker) void {
    const backend = w.backend;
    var cqes: [128]linux.io_uring_cqe = undefined;
    while (!w.stop.load(.acquire)) {
        // 1. Take over freshly accepted connections.
        workerDrainInbox(w);
        // 2. Flush whatever the protocol layer queued.
        workerFlushAll(w);
        // 3. Submit and wait for completions.
        w.sq_lock.lock();
        _ = w.ring.submit() catch {
            w.sq_lock.unlock();
            break;
        };
        w.sq_lock.unlock();
        const n = w.ring.copy_cqes(&cqes, 1) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => break,
        };
        var i: usize = 0;
        while (i < n) : (i += 1) {
            workerHandleCqe(w, cqes[i]);
        }
    }
    // Tear the connections down.
    w.conns_lock.lock();
    var it = w.conns.valueIterator();
    while (it.next()) |slot| {
        backend.handler.on_close(backend.handler.ctx, slot.*.id);
    }
    w.conns_lock.unlock();
    for (w.dead_slots.items) |slot| {
        w.backend.allocator.destroy(slot);
    }
    w.dead_slots.deinit(w.backend.allocator);
}

fn workerDrainInbox(w: *Worker) void {
    w.inbox_lock.lock();
    if (w.inbox.items.len == 0) {
        w.inbox_lock.unlock();
        return;
    }
    var items = w.inbox;
    w.inbox = .empty;
    w.inbox_lock.unlock();
    for (items.items) |item| {
        const slot = w.backend.allocator.create(ConnSlot) catch {
            _ = linux.close(item.fd);
            continue;
        };
        slot.* = .{ .id = item.id, .fd = item.fd };
        w.conns_lock.lock();
        w.conns.put(w.backend.allocator, slot.id, slot) catch {
            w.conns_lock.unlock();
            w.backend.allocator.destroy(slot);
            _ = linux.close(item.fd);
            continue;
        };
        w.conns_lock.unlock();
        w.backend.handler.on_accept(w.backend.handler.ctx, slot.id, item.fd);
        workerArmRecv(w, slot);
    }
    items.deinit(w.backend.allocator);
}

fn workerArmRecv(w: *Worker, slot: *ConnSlot) void {
    if (slot.dead.load(.acquire)) return;
    if (slot.recv_armed) return;
    w.sq_lock.lock();
    defer w.sq_lock.unlock();
    _ = w.buffers.recv_multishot(makeTag(KindRecv, slot.id, 0), slot.fd, 0) catch {
        _ = w.backend.counters.recv_arm_failures.fetchAdd(1, .acq_rel);
        return;
    };
    slot.recv_armed = true;
}

fn workerHandleCqe(w: *Worker, cqe: linux.io_uring_cqe) void {
    switch (tagKind(cqe.user_data)) {
        KindRecv => workerHandleRecv(w, cqe),
        KindSend => workerHandleSend(w, cqe),
        KindSendNotif => workerHandleSendNotif(w, cqe),
        KindEventfd => workerDrainWakeup(w),
        KindWake => {},
        KindAccept => {},
        else => {},
    }
}

fn workerHandleRecv(w: *Worker, cqe: linux.io_uring_cqe) void {
    const id = tagConn(cqe.user_data);
    w.conns_lock.lock();
    const slot = w.conns.get(id);
    w.conns_lock.unlock();
    const sl = slot orelse return;
    const more = (cqe.flags & linux.IORING_CQE_F_MORE) != 0;
    if (cqe.res > 0) {
        const bytes = w.buffers.get(cqe) catch {
            sl.recv_armed = false;
            return;
        };
        const h = w.backend.handler;
        h.on_read(h.ctx, sl.id, bytes);
        _ = w.backend.counters.bytes_in.fetchAdd(bytes.len, .acq_rel);
        w.buffers.put(cqe) catch {};
        // The protocol layer queued its answer: drain it now.
        if (h.on_flush(h.ctx, sl.id)) |out| workerQueueBytes(w, sl, out);
    } else if (cqe.res == 0) {
        // Peer closed.
        sl.recv_armed = false;
        workerCloseConn(w, id);
        return;
    } else {
        // Error (or ENOBUFS: the buffer group ran dry).
        sl.recv_armed = false;
        if (cqe.res == -@as(i32, @intCast(@intFromEnum(linux.E.NOBUFS)))) {
            _ = w.backend.counters.buffer_starved.fetchAdd(1, .acq_rel);
            workerFlushAll(w);
            workerArmRecv(w, sl);
            return;
        }
        workerCloseConn(w, id);
        return;
    }
    if (!more) {
        // The multishot recv ended (error or cancellation): re-arm.
        sl.recv_armed = false;
        workerArmRecv(w, sl);
    }
}

fn workerHandleSend(w: *Worker, cqe: linux.io_uring_cqe) void {
    const id = tagConn(cqe.user_data);
    const seq = tagSeq(cqe.user_data);
    w.conns_lock.lock();
    const slot = w.conns.get(id);
    w.conns_lock.unlock();
    const sl = slot orelse return;
    if (sl.inflight.seq != seq) return;
    if (!sl.inflight.zerocopy) {
        w.backend.allocator.free(sl.inflight.bytes);
    }
    sl.inflight = .{};
    sl.sending = false;
    if (cqe.res < 0) {
        workerCloseConn(w, id);
        return;
    }
    workerFlushConn(w, sl);
}

fn workerHandleSendNotif(w: *Worker, cqe: linux.io_uring_cqe) void {
    const id = tagConn(cqe.user_data);
    const seq = tagSeq(cqe.user_data);
    w.conns_lock.lock();
    const slot = w.conns.get(id);
    w.conns_lock.unlock();
    const sl = slot orelse return;
    var i: usize = 0;
    while (i < sl.zc_pending.items.len) : (i += 1) {
        if (sl.zc_pending.items[i].seq == seq) {
            w.backend.allocator.free(sl.zc_pending.items[i].bytes);
            _ = sl.zc_pending.orderedRemove(i);
            return;
        }
    }
}

fn workerDrainWakeup(w: *Worker) void {
    var buf: [8]u8 = undefined;
    _ = linux.read(w.wakeup_fd, &buf, 8);
    workerFlushAll(w);
}

/// Queue bytes for sending (ownership moves to the slot).
fn workerQueueBytes(w: *Worker, slot: *ConnSlot, bytes: []u8) void {
    if (slot.dead.load(.acquire)) {
        w.backend.allocator.free(bytes);
        return;
    }
    slot.out.appendSlice(w.backend.allocator, bytes) catch {
        w.backend.allocator.free(bytes);
        return;
    };
    w.backend.allocator.free(bytes);
    workerFlushConn(w, slot);
}

/// Send what is queued (one send in flight at a time: TCP ordering).
fn workerFlushConn(w: *Worker, slot: *ConnSlot) void {
    if (slot.dead.load(.acquire)) return;
    if (slot.sending) return;
    if (slot.out.items.len == 0) return;
    const bytes = slot.out.toOwnedSlice(w.backend.allocator) catch return;
    slot.out = .empty;
    const seq = slot.next_seq;
    slot.next_seq +%= 1;
    const use_zc = transport.useZerocopy(bytes.len, w.backend.opts);
    const tag = makeTag(KindSend, slot.id, seq);
    w.sq_lock.lock();
    defer w.sq_lock.unlock();
    if (use_zc) {
        const sqe = w.ring.send_zc(tag, slot.fd, bytes, posix.MSG.NOSIGNAL, 0) catch {
            _ = w.backend.counters.send_failures.fetchAdd(1, .acq_rel);
            w.backend.allocator.free(bytes);
            return;
        };
        _ = sqe;
        slot.zc_pending.append(w.backend.allocator, .{ .seq = seq, .bytes = bytes, .zerocopy = true }) catch {
            w.backend.allocator.free(bytes);
            return;
        };
        slot.inflight = .{ .seq = seq, .bytes = bytes, .zerocopy = true };
        _ = w.backend.counters.sends_zc.fetchAdd(1, .acq_rel);
    } else {
        const sqe = w.ring.send(tag, slot.fd, bytes, posix.MSG.NOSIGNAL) catch {
            _ = w.backend.counters.send_failures.fetchAdd(1, .acq_rel);
            w.backend.allocator.free(bytes);
            return;
        };
        _ = sqe;
        slot.inflight = .{ .seq = seq, .bytes = bytes, .zerocopy = false };
        _ = w.backend.counters.sends_copy.fetchAdd(1, .acq_rel);
    }
    slot.sending = true;
    _ = w.backend.counters.bytes_out.fetchAdd(bytes.len, .acq_rel);
    _ = w.backend.counters.flushes.fetchAdd(1, .acq_rel);
}

/// Flush every connection that asked for it.
fn workerFlushAll(w: *Worker) void {
    // Collect under the map lock, but call the protocol handler OUTSIDE
    // it: the handler takes the conn's lock, and holding both locks at
    // once deadlocks against the tick path (conn lock -> map lock).
    var pending: [64]*ConnSlot = undefined;
    var n_pending: usize = 0;
    w.conns_lock.lock();
    var it = w.conns.valueIterator();
    while (it.next()) |slot| {
        if (slot.*.flush_requested.swap(false, .acq_rel)) {
            if (n_pending < pending.len) {
                pending[n_pending] = slot.*;
                n_pending += 1;
            }
        }
    }
    w.conns_lock.unlock();
    var i: usize = 0;
    while (i < n_pending) : (i += 1) {
        const slot = pending[i];
        if (slot.dead.load(.acquire)) continue;
        const h = w.backend.handler;
        if (h.on_flush(h.ctx, slot.id)) |out| workerQueueBytes(w, slot, out);
    }
}

/// Close a connection. The map is the authority: whoever removes the
/// entry owns the close (the socket is closed exactly once). The slot
/// memory is kept until the worker exits, so an in-flight completion can
/// never touch freed memory. No waiting: retention + the `dead` flag make
/// every concurrent path safe (a refcount spin here deadlocked when an
/// overflow kick fired mid-flush).
fn workerCloseConn(w: *Worker, conn_id: u32) void {
    w.conns_lock.lock();
    const removed = w.conns.fetchRemove(conn_id);
    w.conns_lock.unlock();
    const slot = (removed orelse return).value;
    slot.dead.store(true, .release);
    const h = w.backend.handler;
    h.on_close(h.ctx, slot.id);
    _ = linux.close(slot.fd);
    for (slot.zc_pending.items) |p| w.backend.allocator.free(p.bytes);
    slot.zc_pending.deinit(w.backend.allocator);
    slot.out.deinit(w.backend.allocator);
    w.dead_slots.append(w.backend.allocator, slot) catch {
        w.backend.allocator.destroy(slot);
    };
    _ = w.backend.counters.conns_closed.fetchAdd(1, .acq_rel);
}

/// Sleep helper (the backend has no Io of its own; the server passes one).
fn sleepMs(io: std.Io, ms: u64) void {
    const d = std.Io.Clock.Duration{ .raw = std.Io.Duration.fromNanoseconds(@intCast(ms * std.time.ns_per_ms)), .clock = .awake };
    std.Io.Timeout.sleep(.{ .duration = d }, io) catch {};
}

/// Can io_uring be used on this kernel? (ring setup probe)
pub fn probe() bool {
    if (!supported) return false;
    var ring = IoUring.init(8, 0) catch return false;
    defer ring.deinit();
    return true;
}

test "io_uring ring + provided buffer group come up" {
    if (!supported) return error.SkipZigTest;
    if (!probe()) return error.SkipZigTest;
    var ring = try IoUring.init(16, 0);
    defer ring.deinit();
    var group = try IoUring.BufferGroup.init(&ring, std.testing.allocator, 1, 4096, 16);
    defer group.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 1), group.group_id);
    try std.testing.expectEqual(@as(u16, 16), group.buffers_count);
}

test "send tags round-trip" {
    const t = makeTag(KindSend, 42, 7);
    try std.testing.expectEqual(KindSend, tagKind(t));
    try std.testing.expectEqual(@as(u32, 42), tagConn(t));
    try std.testing.expectEqual(@as(u32, 7), tagSeq(t));
    try std.testing.expectEqual(KindEventfd, tagKind(0));
}
