//! Persistent worker pool with a generation barrier — Phase C follow-up.
//!
//! Fork-join (spawn per tick) is correct and cheap at 1Hz, but thread
//! identities churn: affinity is re-pinned every tick and every tick
//! pays spawn latency (~10-50us/worker). A persistent pool parks stable
//! workers once and wakes them per tick; the join-equivalent is a
//! generation barrier. This is also the primitive a sub-second loop
//! (e.g. the 10Hz redstone drain, if it ever parallelizes) would use:
//! at 10Hz+ fork-join spawn churn stops being noise.
//!
//! Mechanism: Linux futex WAIT/WAKE on two words (generation + done
//! count). Off Linux there is no portable condvar in this Zig version,
//! so `create` returns `error.Unsupported` and callers fall back to
//! fork-join (same work, same merge — only the thread lifetime differs).
//! Pinning (affinity) happens once at spawn and sticks, which is the
//! steady-state win over fork-join beyond the saved spawn latency.
//!
//! Locking: none. The main thread writes job state before bumping the
//! generation (release); workers read it after observing the bump
//! (acquire). The `done` count is the only shared-mutable word and it
//! is atomic; missed wakeups are impossible (futex WAIT validates the
//! expected value, spurious wakeups re-check the condition).

const std = @import("std");
const builtin = @import("builtin");
const affinity = @import("affinity.zig");

pub const supported = builtin.os.tag == .linux;

/// Hard cap on persistent workers (callers slice more regions per worker).
pub const max_pool_threads: usize = 64;

/// Handler run by every worker each generation. `worker` is the
/// worker index (0..n-1, stable across generations); partitioning of
/// the actual work is the caller's job (contiguous ranges keep
/// neighbors on neighboring cores).
pub const Handler = *const fn (ctx: *anyopaque, worker: usize, n_workers: usize) void;

pub const Pool = struct {
    allocator: std.mem.Allocator,
    threads: []std.Thread,
    n: usize,
    /// Generation word (futex-waited by workers).
    wake: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Completions this generation (futex-waited by main).
    done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    handler: Handler = undefined,
    ctx: *anyopaque = undefined,

    /// Spawn `n_threads` parked workers (pinned per `cpus` when given).
    /// The pool must be heap-allocated by the caller... no: it is fully
    /// self-contained — create returns an owned pointer (destroy frees).
    pub fn create(allocator: std.mem.Allocator, n_threads: usize, cpus: ?[]const usize) !*Pool {
        if (comptime !supported) return error.Unsupported;
        const n = @max(1, @min(n_threads, max_pool_threads));
        const self = try allocator.create(Pool);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .threads = try allocator.alloc(std.Thread, n),
            .n = n,
        };
        errdefer allocator.free(self.threads);
        var spawned: usize = 0;
        errdefer {
            self.stop.store(true, .release);
            self.wakeAll();
            for (self.threads[0..spawned]) |t| t.join();
        }
        while (spawned < n) : (spawned += 1) {
            self.threads[spawned] = try std.Thread.spawn(.{}, workerMain, .{ self, spawned, pickCpu(cpus, spawned) });
        }
        return self;
    }

    /// Worker i pins to cpus[i] when the caller supplied that slot.
    fn pickCpu(cpus: ?[]const usize, i: usize) ?usize {
        const cs = cpus orelse return null;
        return if (i < cs.len) cs[i] else null;
    }

    pub fn destroy(self: *Pool) void {
        self.stop.store(true, .release);
        // Bump the generation so parked workers re-check (and see stop).
        _ = self.wake.fetchAdd(1, .acq_rel);
        self.wakeAll();
        for (self.threads) |t| t.join();
        self.allocator.free(self.threads);
        self.allocator.destroy(self);
    }

    /// Run one generation: every worker runs `handler(ctx, i, n)`, return
    /// when all are done (the barrier). May be called again immediately.
    /// Single caller only; destroy must not race an in-flight run.
    pub fn run(self: *Pool, ctx: *anyopaque, handler: Handler) void {
        self.handler = handler;
        self.ctx = ctx;
        self.done.store(0, .release);
        _ = self.wake.fetchAdd(1, .acq_rel);
        self.wakeAll();
        var last: u32 = 0;
        while (last < self.n) {
            last = self.done.load(.acquire);
            if (last >= self.n) break;
            futexWait(&self.done, last);
        }
    }

    fn wakeAll(self: *Pool) void {
        futexWake(&self.wake, @intCast(self.n));
    }
};

fn workerMain(self: *Pool, index: usize, cpu: ?usize) void {
    if (cpu) |c| affinity.pinSelf(c);
    var seen: u32 = 0;
    while (true) {
        const g = self.wake.load(.acquire);
        if (g == seen) {
            futexWait(&self.wake, g);
            continue;
        }
        seen = g;
        if (self.stop.load(.acquire)) break;
        self.handler(self.ctx, index, self.n);
        _ = self.done.fetchAdd(1, .acq_rel);
        futexWake(&self.done, 1);
    }
}

fn futexWait(addr: *const std.atomic.Value(u32), expected: u32) void {
    if (comptime !supported) return;
    const linux = std.os.linux;
    while (addr.load(.acquire) == expected) {
        const rc = linux.futex_3arg(addr, .{ .cmd = .WAIT, .private = true }, expected);
        // EAGAIN (changed under us) and EINTR (signal) both just re-check.
        _ = rc;
    }
}

fn futexWake(addr: *const std.atomic.Value(u32), n: u32) void {
    if (comptime !supported) return;
    const linux = std.os.linux;
    _ = linux.futex_3arg(addr, .{ .cmd = .WAKE, .private = true }, n);
}

test "pool unsupported off Linux, functional on it" {
    if (comptime !supported) {
        try std.testing.expectError(error.Unsupported, Pool.create(std.testing.allocator, 4, null));
        return;
    }
    const pool = try Pool.create(std.heap.page_allocator, 1, null);
    defer pool.destroy();
    try std.testing.expectEqual(@as(usize, 1), pool.n);
}

test "pool barrier is exact (no lost wakeups)" {
    if (comptime !supported) return error.SkipZigTest;
    // Page allocator: workers share it (the test allocator is not for
    // concurrent use).
    const alloc = std.heap.page_allocator;
    var cpus: [4]usize = .{ 0, 1, 2, 3 };
    const pool = try Pool.create(alloc, 4, &cpus);
    defer pool.destroy();
    const Ctx = struct {
        hits: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        fn h(ctx: *anyopaque, worker: usize, n_workers: usize) void {
            _ = n_workers;
            const c: *@This() = @ptrCast(@alignCast(ctx));
            // Each worker contributes exactly once per generation.
            _ = c.hits.fetchAdd(1, .acq_rel);
            // Deterministic spin (no sleep): keeps the test fast.
            var x: u64 = worker;
            var k: u64 = 0;
            while (k < 500) : (k += 1) x +%= k *% 0x9E3779B97F4A7C15;
            std.mem.doNotOptimizeAway(&x);
        }
    };
    var ctx = Ctx{};
    var g: u64 = 0;
    while (g < 50) : (g += 1) {
        pool.run(&ctx, Ctx.h);
        try std.testing.expectEqual((g + 1) * 4, ctx.hits.load(.acquire));
    }
}

test "pool destroy terminates parked workers" {
    if (comptime !supported) return error.SkipZigTest;
    const alloc = std.heap.page_allocator;
    // Create, run once, destroy while idle: join must return (a parked
    // worker that never wakes would hang destroy forever).
    const pool = try Pool.create(alloc, 2, null);
    const Ctx = struct {
        fn h(ctx: *anyopaque, worker: usize, n_workers: usize) void {
            _ = ctx;
            _ = worker;
            _ = n_workers;
        }
    };
    var dummy: u8 = 0;
    pool.run(&dummy, Ctx.h);
    pool.destroy(); // must return promptly
}
