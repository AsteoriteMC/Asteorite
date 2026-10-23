//! macOS kqueue transport — Phase B ("per-OS backends behind one transport
//! interface").
//!
//! Same contract as the io_uring backend (`transport.Handler`), different
//! mechanism: kqueue is per-file-descriptor readiness, so the worker
//! registers every socket for EVFILT_READ and drains it fully on every
//! event (edge-triggered semantics: read until EAGAIN, write until EAGAIN,
//! then arm EVFILT_WRITE).
//!
//! The listening socket is registered in *every* worker's kqueue (kqueue
//! allows the same descriptor in several queues), so the kernel spreads
//! incoming connections over the workers.
//!
//! Coverage: cross-compilation plus audit. This box is Linux, so the
//! macOS path has no runtime coverage yet (documented gap in TODO.md).
//! What IS verified here: full lifecycle review (map-authority close,
//! retained slots, flush wakeups so ticker output never stalls, working
//! stop()), the op/event plumbing compiles for the Darwin target, and
//! the pure logic is unit-tested where separable.

const std = @import("std");
const builtin = @import("builtin");
const transport = @import("transport.zig");

const c = std.c;

pub const supported = builtin.os.tag.isDarwin();

/// Darwin's kqueue ABI (std.c.darwin).
const Kevent = c.kevent64_s;
const EVFILT_READ: i16 = 0;
const EVFILT_WRITE: i16 = 1;
const EVFILT_USER: i16 = -10;
const EV_ADD: u16 = 1;
const EV_DELETE: u16 = 2;
const EV_CLEAR: u16 = 0x20;
const EV_ERROR: u32 = 0x4000_0000;
/// Cross-thread wakeup for EVFILT_USER (lets stop() break a parked worker).
const NOTE_TRIGGER: u32 = 0x0100_0000;
/// udata marker for the stop/wakeup event (never a real fd).
const wake_ident: usize = 1;

/// Per-connection state owned by a worker.
const ConnSlot = struct {
    id: u32,
    fd: c.fd_t,
    /// Bytes waiting for the socket (owned; worker-only — the close path
    /// never touches it, so no lock is needed).
    out: std.ArrayList(u8) = .empty,
    /// True while EVFILT_WRITE is armed.
    write_armed: bool = false,
    /// Set by `request_flush` (any thread).
    flush_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set by the close path (any thread): the worker skips dead slots.
    /// Safety never depends on this flag (retained memory + the server's
    /// map re-lookup cover every race); it just avoids wasted work.
    dead: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// A small test-and-set spinlock (the worker map is touched by the owning
/// worker and by any thread that flushes/closes — same pattern as uring).
const SpinLock = struct {
    flag: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn lock(self: *SpinLock) void {
        while (self.flag.swap(1, .acquire) != 0) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinLock) void {
        self.flag.store(0, .release);
    }
};

const Worker = struct {
    backend: *Backend,
    index: usize,
    kq: c.fd_t = -1,
    /// Live connections (fd -> slot). Guarded by `lock`: the owning
    /// worker and any thread that flushes/closes touch it.
    conns: std.AutoHashMapUnmanaged(c.fd_t, *ConnSlot) = .empty,
    lock: SpinLock = .{},
    /// Retired slots, retained until worker exit (an in-flight event can
    /// never touch freed memory).
    dead_slots: std.ArrayListUnmanaged(*ConnSlot) = .empty,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    fn setup(self: *Worker) !void {
        const kq = c.kqueue();
        if (kq < 0) return error.KqueueFailed;
        self.kq = kq;
        // The listener is watched by every worker: kqueue allows the same
        // descriptor in several queues, so the kernel spreads the load.
        var ev = Kevent{
            .ident = @intCast(self.backend.listener_fd),
            .filter = EVFILT_READ,
            .flags = EV_ADD | EV_CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = 0,
            .ext = [_]u64{0} ** 2,
        };
        if (c.kevent64(self.kq, @ptrCast(&ev), 1, undefined, 0, c.KEVENT.FLAG.NONE, null) < 0) return error.KeventFailed;
        // Stop/wakeup channel: stop() triggers it so a worker parked in
        // kevent wakes up and sees the flag (without this, join hangs).
        var wv = Kevent{
            .ident = wake_ident,
            .filter = EVFILT_USER,
            .flags = EV_ADD | EV_CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = wake_ident,
            .ext = [_]u64{0} ** 2,
        };
        if (c.kevent64(self.kq, @ptrCast(&wv), 1, undefined, 0, c.KEVENT.FLAG.NONE, null) < 0) return error.KeventFailed;
    }

    /// Wake this worker's kevent loop (stop/shutdown path).
    fn wake(self: *Worker) void {
        var wv = Kevent{
            .ident = wake_ident,
            .filter = EVFILT_USER,
            .flags = EV_ADD,
            .fflags = NOTE_TRIGGER,
            .data = 0,
            .udata = wake_ident,
            .ext = [_]u64{0} ** 2,
        };
        _ = c.kevent64(self.kq, @ptrCast(&wv), 1, undefined, 0, c.KEVENT.FLAG.NONE, null);
    }

    fn deinit(self: *Worker) void {
        for (self.dead_slots.items) |slot| {
            slot.out.deinit(self.backend.allocator);
            self.backend.allocator.destroy(slot);
        }
        self.dead_slots.deinit(self.backend.allocator);
        var it = self.conns.valueIterator();
        while (it.next()) |slot| {
            slot.*.out.deinit(self.backend.allocator);
            self.backend.allocator.destroy(slot.*);
        }
        self.conns.deinit(self.backend.allocator);
        if (self.kq >= 0) {
            _ = c.close(self.kq);
            self.kq = -1;
        }
    }

    fn arm(self: *Worker, fd: c.fd_t, filter: i16, flags: u16) void {
        var ev = Kevent{
            .ident = @intCast(fd),
            .filter = filter,
            .flags = flags,
            .fflags = 0,
            .data = 0,
            .udata = 0,
            .ext = [_]u64{0} ** 2,
        };
        _ = c.kevent64(self.kq, @ptrCast(&ev), 1, undefined, 0, c.KEVENT.FLAG.NONE, null);
    }

    fn acceptReady(self: *Worker) void {
        while (true) {
            const fd = c.accept(self.backend.listener_fd, null, null);
            if (fd < 0) return; // EAGAIN: drained.
            // Non-blocking + close-on-exec (Darwin values: F_GETFL 3,
            // F_SETFL 4, F_SETFD 2, FD_CLOEXEC 1, O_NONBLOCK 0x4).
            const flags = c.fcntl(fd, 3, @as(c_int, 0));
            _ = c.fcntl(fd, 4, flags | 0x4);
            _ = c.fcntl(fd, 2, @as(c_int, 1));
            transport.applySocketOpts(fd, self.backend.opts);
            const id = self.backend.next_conn_id.fetchAdd(1, .acq_rel);
            const slot = self.backend.allocator.create(ConnSlot) catch {
                _ = c.close(fd);
                continue;
            };
            slot.* = .{ .id = id, .fd = fd };
            self.lock.lock();
            self.conns.put(self.backend.allocator, fd, slot) catch {
                self.lock.unlock();
                self.backend.allocator.destroy(slot);
                _ = c.close(fd);
                continue;
            };
            self.lock.unlock();
            self.arm(fd, EVFILT_READ, EV_ADD | EV_CLEAR);
            self.backend.handler.on_accept(self.backend.handler.ctx, id, fd);
        }
    }

    fn readReady(self: *Worker, slot: *ConnSlot) void {
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            if (slot.dead.load(.acquire)) return;
            const n = c.read(slot.fd, &buf, buf.len);
            if (n < 0) {
                const err = c._errno().*;
                if (err == @intFromEnum(c.E.AGAIN)) return;
                self.closeSlot(slot);
                return;
            }
            if (n == 0) {
                self.closeSlot(slot);
                return;
            }
            self.backend.handler.on_read(self.backend.handler.ctx, slot.id, buf[0..@intCast(n)]);
            self.drainOut(slot);
            if (n < buf.len) return;
        }
    }

    /// Pull the protocol layer's outbox into the socket buffer.
    fn drainOut(self: *Worker, slot: *ConnSlot) void {
        if (slot.dead.load(.acquire)) return;
        _ = slot.flush_requested.swap(false, .acq_rel);
        if (self.backend.handler.on_flush(self.backend.handler.ctx, slot.id)) |bytes| {
            slot.out.appendSlice(self.backend.allocator, bytes) catch {
                self.backend.allocator.free(bytes);
                return;
            };
            self.backend.allocator.free(bytes);
        }
        self.writeReady(slot);
    }

    fn writeReady(self: *Worker, slot: *ConnSlot) void {
        while (slot.out.items.len > 0) {
            if (slot.dead.load(.acquire)) return;
            const n = c.write(slot.fd, slot.out.items.ptr, slot.out.items.len);
            if (n < 0) {
                const err = c._errno().*;
                if (err == @intFromEnum(c.E.AGAIN)) {
                    self.arm(slot.fd, EVFILT_WRITE, EV_ADD | EV_CLEAR);
                    slot.write_armed = true;
                    return;
                }
                self.closeSlot(slot);
                return;
            }
            const written: usize = @intCast(n);
            const rest = slot.out.items[written..];
            std.mem.copyForwards(u8, slot.out.items[0..rest.len], rest);
            slot.out.items.len = rest.len;
        }
        if (slot.write_armed) {
            self.arm(slot.fd, EVFILT_WRITE, EV_DELETE);
            slot.write_armed = false;
        }
    }

    /// Sweep connections with queued output (wakeup path: ticker flushes
    /// must not wait for inbound traffic to trigger a send — without
    /// this, keepalives and time updates stall and idle clients time
    /// out). Map lock only for collection; protocol calls outside it.
    fn drainFlushes(self: *Worker) void {
        var pending: [64]*ConnSlot = undefined;
        var n_pending: usize = 0;
        self.lock.lock();
        var it = self.conns.valueIterator();
        while (it.next()) |slot| {
            if (slot.*.dead.load(.acquire)) continue;
            if (slot.*.flush_requested.swap(false, .acq_rel)) {
                if (n_pending < pending.len) {
                    pending[n_pending] = slot.*;
                    n_pending += 1;
                }
            }
        }
        self.lock.unlock();
        var i: usize = 0;
        while (i < n_pending) : (i += 1) {
            self.drainOut(pending[i]);
        }
    }

    fn closeSlot(self: *Worker, slot: *ConnSlot) void { // Map-authority: whoever removes the entry owns the close (the
        // socket closes exactly once). The slot is RETIRED, not freed: an
        // event already dequeued for it keeps valid memory, and its `out`
        // buffer is never touched here (worker-only) — it is freed with
        // the slot at worker exit. Server-side re-lookup makes late
        // protocol callbacks null-safe no-ops.
        self.lock.lock();
        const removed = self.conns.fetchRemove(slot.fd);
        self.lock.unlock();
        if (removed == null) return;
        slot.dead.store(true, .release);
        self.backend.handler.on_close(self.backend.handler.ctx, slot.id);
        _ = c.close(slot.fd);
        self.lock.lock();
        self.dead_slots.append(self.backend.allocator, slot) catch {
            self.lock.unlock();
            slot.out.deinit(self.backend.allocator);
            self.backend.allocator.destroy(slot);
            return;
        };
        self.lock.unlock();
    }
};

pub const Backend = struct {
    allocator: std.mem.Allocator,
    opts: transport.Options,
    listener_fd: c.fd_t,
    handler: transport.Handler,
    workers: []Worker = &[_]Worker{},
    next_conn_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    stats: transport.Stats = .{},

    /// Initialize IN PLACE: the workers hold a pointer to the backend, so
    /// returning it by value would leave them pointing at a dead copy.
    pub fn init(
        self: *Backend,
        allocator: std.mem.Allocator,
        opts: transport.Options,
        listener_fd: c.fd_t,
        handler: transport.Handler,
    ) !void {
        const n_workers = opts.workerCount();
        const workers = try allocator.alloc(Worker, n_workers);
        errdefer allocator.free(workers);
        self.* = .{
            .allocator = allocator,
            .opts = opts,
            .listener_fd = listener_fd,
            .handler = handler,
            .workers = workers,
        };
        var made: usize = 0;
        errdefer {
            for (workers[0..made]) |*w| w.deinit();
        }
        while (made < n_workers) : (made += 1) {
            workers[made] = .{ .backend = self, .index = made };
            try workers[made].setup();
        }
    }

    pub fn deinit(self: *Backend) void {
        for (self.workers) |*w| w.deinit();
        self.allocator.free(self.workers);
    }

    pub fn run(self: *Backend) !void {
        for (self.workers) |*w| {
            w.thread = try std.Thread.spawn(.{}, workerMain, .{w});
        }
        for (self.workers) |*w| {
            if (w.thread) |t| t.join();
        }
    }

    pub fn stop(self: *Backend) void {
        for (self.workers) |*w| {
            w.stop.store(true, .release);
            w.wake();
        }
    }

    pub fn requestFlush(self: *Backend, conn_id: u32) void {
        for (self.workers) |*w| {
            w.lock.lock();
            var found: ?*ConnSlot = null;
            var it = w.conns.valueIterator();
            while (it.next()) |slot| {
                if (slot.*.id == conn_id) {
                    found = slot.*;
                    break;
                }
            }
            w.lock.unlock();
            if (found) |sl| {
                _ = sl.flush_requested.swap(true, .acq_rel);
                w.wake();
                return;
            }
        }
    }

    fn closeConn(self: *Backend, conn_id: u32) void {
        for (self.workers) |*w| {
            w.lock.lock();
            var found: ?*ConnSlot = null;
            var it = w.conns.valueIterator();
            while (it.next()) |slot| {
                if (slot.*.id == conn_id) {
                    found = slot.*;
                    break;
                }
            }
            w.lock.unlock();
            if (found) |sl| {
                w.closeSlot(sl);
                return;
            }
        }
    }

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

    pub fn statsSnapshot(self: *Backend) transport.Stats {
        return self.stats;
    }
};

fn workerMain(w: *Worker) void {
    var events: [64]Kevent = undefined;
    while (!w.stop.load(.acquire)) {
        const n = c.kevent64(w.kq, undefined, 0, @ptrCast(&events), events.len, c.KEVENT.FLAG.NONE, null);
        if (n < 0) {
            const err = c._errno().*;
            if (err == @intFromEnum(c.E.INTR)) continue;
            break;
        }
        var i: usize = 0;
        while (i < @as(usize, @intCast(n))) : (i += 1) {
            const ev = events[i];
            if ((ev.flags & EV_ERROR) != 0) continue;
            // Wakeup channel first (ident 1 can collide with a real fd).
            if (ev.filter == EVFILT_USER) {
                if (w.stop.load(.acquire)) break;
                // A flush landed while processing: sweep the outboxes so
                // ticker-queued output never waits for inbound traffic.
                w.drainFlushes();
                continue;
            }
            const fd: c.fd_t = @intCast(ev.ident);
            if (fd == w.backend.listener_fd) {
                w.acceptReady();
                continue;
            }
            w.lock.lock();
            const slot = w.conns.get(fd);
            w.lock.unlock();
            const sl = slot orelse continue;
            if (sl.dead.load(.acquire)) continue;
            if (ev.filter == EVFILT_READ) {
                w.readReady(sl);
            } else if (ev.filter == EVFILT_WRITE) {
                w.writeReady(sl);
            }
        }
    }
}
