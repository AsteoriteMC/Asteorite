//! Tiny test-and-set spinlock for short critical sections.
//!
//! Used where `std.Io.Mutex` is the wrong tool: Conn state shared between a
//! serve thread and the server ticker, and the connection registry. Critical
//! sections must stay short and never block on I/O (flushes take owned byte
//! slices and write to sockets AFTER releasing the lock).

const std = @import("std");

pub const SpinLock = struct {
    state: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Spins between thread yields while contended.
    const yield_every: usize = 1024;

    pub fn lock(self: *SpinLock) void {
        var spins: usize = 0;
        while (self.state.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
            spins += 1;
            // A long wait means the holder is doing real work (or is
            // stuck): yield the CPU instead of burning it.
            if (spins % yield_every == 0) std.Thread.yield() catch {};
        }
    }

    /// Try to take the lock without waiting. False when it is held.
    ///
    /// Used where taking another connection's lock would nest locks
    /// (ABBA deadlock: two threads holding one conn's lock and waiting
    /// for the other's). The caller treats "not acquired" as "skip".
    pub fn tryLock(self: *SpinLock) bool {
        return self.state.cmpxchgWeak(false, true, .acquire, .monotonic) == null;
    }

    pub fn unlock(self: *SpinLock) void {
        self.state.store(false, .release);
    }
};

test "spinlock mutual exclusion across threads" {
    const Ctx = struct {
        var lock: SpinLock = .{};
        var count: usize = 0;
        fn run() void {
            var i: usize = 0;
            while (i < 5000) : (i += 1) {
                lock.lock();
                count += 1;
                lock.unlock();
            }
        }
    };
    const t0 = try std.Thread.spawn(.{}, Ctx.run, .{});
    const t1 = try std.Thread.spawn(.{}, Ctx.run, .{});
    t0.join();
    t1.join();
    try std.testing.expectEqual(@as(usize, 10000), Ctx.count);
}
