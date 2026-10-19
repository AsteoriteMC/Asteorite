//! Deterministic region tick loop (20 TPS / 50ms budget).
//!
//! Folia-style: each 32x32-chunk region ticks independently; cross-region
//! entity moves go through the target region's MPSC inbox (see mpsc.zig).
//! P1 runs regions sequentially on one thread; P2 pins one OS thread per
//! region group with sched affinity. No global world lock.

const std = @import("std");
const mpsc = @import("mpsc.zig");

pub const tick_budget_ns: u64 = 50_000_000; // 20 TPS

pub const RegionId = struct {
    dim: u8,
    rx: i32,
    rz: i32,
};

/// Cross-region handoff message (fixed-size, no allocation on push).
pub const Transfer = struct {
    entity_id: u64,
    from_dim: u8,
    from_rx: i32,
    from_rz: i32,
    x: f64,
    y: f64,
    z: f64,
};

pub const Region = struct {
    id: RegionId,
    ticks: u64 = 0,
    overruns: u64 = 0,
    last_tick_ns: u64 = 0,
    inbox: mpsc.Queue(Transfer),

    pub fn init(allocator: std.mem.Allocator, id: RegionId) Region {
        return .{ .id = id, .inbox = mpsc.Queue(Transfer).init(allocator) };
    }

    pub fn deinit(self: *Region) void {
        self.inbox.deinit();
    }
};

pub const Stats = struct {
    regions: usize,
    total_ns: u64,
    overruns: usize,
};

/// Run one global tick over all regions. The handler owns per-region logic
/// (physics/AI/save) and must drain `region.inbox` for handoffs.
/// Overrun = single region exceeding the 50ms budget (counts, never blocks).
pub fn tickOnce(
    io: std.Io,
    regions: []*Region,
    tick_no: u64,
    handler: *const fn (*Region, u64) void,
) Stats {
    var s = Stats{ .regions = regions.len, .total_ns = 0, .overruns = 0 };
    for (regions) |r| {
        const t0 = std.Io.Timestamp.now(io, .awake);
        handler(r, tick_no);
        const dt_i96 = t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
        const dt: u64 = @intCast(@max(0, dt_i96));
        r.ticks += 1;
        r.last_tick_ns = dt;
        s.total_ns += dt;
        if (dt > tick_budget_ns) {
            r.overruns += 1;
            s.overruns += 1;
        }
    }
    return s;
}

test "tickOnce runs handler + counts ticks" {
    const a = std.testing.allocator;
    var r0 = Region.init(a, .{ .dim = 0, .rx = 0, .rz = 0 });
    defer r0.deinit();
    var r1 = Region.init(a, .{ .dim = 0, .rx = 1, .rz = 0 });
    defer r1.deinit();
    var regions = [_]*Region{ &r0, &r1 };
    const H = struct {
        fn h(r: *Region, n: u64) void {
            _ = n;
            // drain handoffs (none here)
            const msgs = r.inbox.drain() catch return;
            defer r.inbox.allocator.free(msgs);
        }
    };
    const s = tickOnce(std.testing.io, &regions, 1, H.h);
    try std.testing.expectEqual(@as(usize, 2), s.regions);
    try std.testing.expectEqual(@as(u64, 1), r0.ticks);
    try std.testing.expectEqual(@as(u64, 0), s.overruns);
}

test "cross-region transfer delivered on next tick" {
    const a = std.testing.allocator;
    var src = Region.init(a, .{ .dim = 0, .rx = 0, .rz = 0 });
    defer src.deinit();
    var dst = Region.init(a, .{ .dim = 0, .rx = 1, .rz = 0 });
    defer dst.deinit();
    try dst.inbox.push(.{
        .entity_id = 42,
        .from_dim = 0,
        .from_rx = 0,
        .from_rz = 0,
        .x = 33 * 16.0,
        .y = 64.0,
        .z = 0.0,
    });
    var regions = [_]*Region{ &src, &dst };
    var seen: u64 = 0;
    const H = struct {
        var out: *u64 = undefined;
        fn h(r: *Region, n: u64) void {
            _ = n;
            const msgs = r.inbox.drain() catch return;
            defer r.inbox.allocator.free(msgs);
            for (msgs) |m| out.* = m.entity_id;
        }
    };
    H.out = &seen;
    _ = tickOnce(std.testing.io, &regions, 2, H.h);
    try std.testing.expectEqual(@as(u64, 42), seen);
}
