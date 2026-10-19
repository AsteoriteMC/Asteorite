//! Tiny test-and-set spinlock for short critical sections.
//!
//! Used where `std.Io.Mutex` is the wrong tool: Conn state shared between a
//! serve thread and the server ticker, and the connection registry. Critical
//! sections must stay short and never block on I/O (flushes take owned byte
//! slices and write to sockets AFTER releasing the lock).

const std = @import("std");

pub const SpinLock = struct {
    state: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn lock(self: *SpinLock) void {
        while (self.state.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
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
