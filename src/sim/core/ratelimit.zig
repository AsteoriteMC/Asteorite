//! Sliding-window rate limiters (login attempts, block placement).
//!
//! Fixed-size, no allocation: a ring of monotonic-ms timestamps, pruned on
//! every probe. Callers pass the window and budget so one type serves both
//! the per-conn placement gate and the per-IP login gate. Size `N` for the
//! largest burst you intend to allow (`allow` caps the budget at `N`).
//!
//! Time source must be monotonic (the server's awake clock); wall-clock
//! jumps would either forgive floods or false-kick legit bursts.

const std = @import("std");

pub fn Window(comptime N: usize) type {
    comptime if (N == 0) @compileError("ratelimit.Window needs N >= 1");
    return struct {
        const Self = @This();
        slots: [N]i64 = [_]i64{0} ** N,
        head: usize = 0, // next write slot
        count: usize = 0, // live entries within the window

        pub fn init() Self {
            return .{};
        }

        /// Prune entries older than the window.
        fn prune(self: *Self, cutoff: i64) void {
            while (self.count > 0) {
                const oldest = (self.head + N - self.count) % N;
                if (self.slots[oldest] > cutoff) break;
                self.count -= 1;
            }
        }

        /// Prune entries older than the window, then admit one event if the
        /// live count is below `max`. Returns true when admitted.
        pub fn allow(self: *Self, now_ms: i64, window_ms: i64, max: usize) bool {
            const budget = @min(max, N);
            self.prune(now_ms - window_ms);
            if (self.count >= budget) return false;
            self.slots[self.head] = now_ms;
            self.head = (self.head + 1) % N;
            self.count += 1;
            return true;
        }

        /// Live count after pruning (for tests/introspection).
        pub fn live(self: *Self, now_ms: i64, window_ms: i64) usize {
            self.prune(now_ms - window_ms);
            return self.count;
        }
    };
}

/// Per-IP login flood gate: bounded table of per-address sliding windows
/// (no allocation, no per-IP heap entry). Joins are the expensive path
/// (loadPlayer, chunk burst, gen, saves); the default 5 joins per 10s per
/// address is far above legit relogging and far below a join flood.
/// Budgets are admin-tunable (config file / CLI); capacities below size
/// the fixed arrays and cap the budgets. Callers with no attributable
/// address (empty IP, e.g. IOCP conns) must bypass the gate.
///
/// Default budgets (also the config defaults; see config.zig). Windows
/// are milliseconds, bursts are event counts within the window.
pub const default_login_window_ms: i64 = 10_000;
pub const default_login_burst: usize = 5;
pub const default_place_window_ms: i64 = 1_000;
pub const default_place_burst: usize = 32;
pub const default_dig_window_ms: i64 = 1_000;
pub const default_dig_burst: usize = 32;
pub const default_chat_window_ms: i64 = 750;
pub const default_chat_burst: usize = 3;

/// Hard capacities (NOT tunable: they size fixed arrays; larger budgets
/// are capped here and rejected by config validation).
pub const login_slots: usize = 64;
pub const login_window_capacity: usize = 16;
pub const place_window_capacity: usize = 64;
pub const dig_window_capacity: usize = 64;
/// Windows below this are noise (a single tick already spans more);
/// config validation rejects them.
pub const min_window_ms: i64 = 100;

pub const LoginGate = struct {
    const Slot = struct {
        ip_hash: u64 = 0,
        used: bool = false,
        win: Window(login_window_capacity) = .{},
    };
    lock: std.atomic.Mutex = .unlocked,
    slots: [login_slots]Slot = [_]Slot{.{}} ** login_slots,

    pub fn init() LoginGate {
        return .{};
    }

    /// Record one login attempt from `ip`; false means over budget.
    pub fn allow(self: *LoginGate, ip: []const u8, now_ms: i64, window_ms: i64, burst: usize) bool {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
        defer self.lock.unlock();
        const h = std.hash.Wyhash.hash(0, ip);
        var free_slot: ?*Slot = null;
        for (&self.slots) |*s| {
            if (!s.used) {
                if (free_slot == null) free_slot = s;
                continue;
            }
            if (s.ip_hash == h) return s.win.allow(now_ms, window_ms, burst);
        }
        if (free_slot) |s| {
            s.used = true;
            s.ip_hash = h;
            return s.win.allow(now_ms, window_ms, burst);
        }
        // Table full (64 distinct addresses inside one window): recycle by
        // hash so the gate stays bounded and lock-free of allocation.
        const s = &self.slots[h % self.slots.len];
        s.used = true;
        s.ip_hash = h;
        s.win = .{};
        return s.win.allow(now_ms, window_ms, burst);
    }
};

test "login gate: per-IP budget, independence, expiry" {
    var g = LoginGate.init();
    // Five rapid joins from one address: admitted.
    var i: usize = 0;
    while (i < default_login_burst) : (i += 1) {
        try std.testing.expect(g.allow("10.0.0.9", 5000, default_login_window_ms, default_login_burst));
    }
    // Sixth inside the window: rejected.
    try std.testing.expect(!g.allow("10.0.0.9", 5001, default_login_window_ms, default_login_burst));
    // Another address is unaffected.
    try std.testing.expect(g.allow("10.0.0.10", 5001, default_login_window_ms, default_login_burst));
    // Past the window: forgiven.
    try std.testing.expect(g.allow("10.0.0.9", 20000, default_login_window_ms, default_login_burst));
    // Custom budgets are honored (tighter than default here).
    try std.testing.expect(g.allow("10.0.0.11", 5001, 1000, 1));
    try std.testing.expect(!g.allow("10.0.0.11", 5002, 1000, 1));
}

test "burst admitted, flood rejected, window expiry forgives" {
    var w = Window(4).init();
    // Burst of 4 in-window: all admitted.
    try std.testing.expect(w.allow(1000, 1000, 4));
    try std.testing.expect(w.allow(1001, 1000, 4));
    try std.testing.expect(w.allow(1002, 1000, 4));
    try std.testing.expect(w.allow(1003, 1000, 4));
    // Fifth inside the window: rejected.
    try std.testing.expect(!w.allow(1004, 1000, 4));
    try std.testing.expectEqual(@as(usize, 4), w.live(1004, 1000));
    // Past the window edge the oldest entries fall off one by one.
    try std.testing.expect(w.allow(2001, 1000, 4));
    try std.testing.expect(w.allow(2001, 1000, 4));
    // Fourth live entry fills the window again: the next is rejected.
    try std.testing.expect(!w.allow(2001, 1000, 4));
    // Far future: fully forgiven.
    try std.testing.expectEqual(@as(usize, 0), w.live(9999, 1000));
    try std.testing.expect(w.allow(9999, 1000, 4));
}

test "budget caps at capacity and smaller budgets hold" {
    var w = Window(8).init();
    // Budget larger than capacity caps at N.
    try std.testing.expect(w.allow(0, 1000, 100));
    try std.testing.expect(w.allow(1, 1000, 100));
    try std.testing.expect(w.allow(2, 1000, 100));
    try std.testing.expect(w.allow(3, 1000, 100));
    try std.testing.expect(w.allow(4, 1000, 100));
    try std.testing.expect(w.allow(5, 1000, 100));
    try std.testing.expect(w.allow(6, 1000, 100));
    try std.testing.expect(w.allow(7, 1000, 100));
    try std.testing.expect(!w.allow(8, 1000, 100));
    // Smaller budget on a fresh window.
    var v = Window(8).init();
    try std.testing.expect(v.allow(0, 500, 2));
    try std.testing.expect(v.allow(10, 500, 2));
    try std.testing.expect(!v.allow(20, 500, 2));
    try std.testing.expect(v.allow(600, 500, 2));
}
