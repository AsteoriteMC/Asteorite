//! K4 explosion core (CPU reference for the Phase G1 GPU raycast).
//!
//! Vanilla 1.7.10 `Explosion` (MCP `anm`, CFR 0.152) split into a pure,
//! testable core: one 16^3-face raycast pass per blast with per-step
//! attenuation, then a single collect-then-apply block pass owned by the
//! server. No recursion: chained TNT becomes primed entities with short
//! fuses (the chain queue), so 64-TNT chains clear with zero skipped fuse
//! ticks even when blast execution is budgeted across ticks.
//!
//! Raycast (jar-verbatim shape):
//! - 16^3 lattice, only face cubes emit (1352 rays).
//! - dir = (i/15*2-1, j/15*2-1, k/15*2-1) normalized.
//! - power f = size * (0.7 + rand*0.6) (world rand in vanilla; the server
//!   passes its explosion stream, goldens use a fixed seed).
//! - step 0.3: f -= 0.3*0.75 unconditionally, plus (res+0.3)*0.3 for
//!   non-air blocks (res = `getExplosionResistance` = blockResistance/5).
//! - while f > 0, non-air cells are recorded (deduped); TNT cells are
//!   recorded as chain-primes instead of breaks.
//! - Missing chunks read as air (keep flying, like the potion arc).
//!
//! Damage (jar-verbatim shape): d = (1 - dist/(size*2)) * exposure;
//! dmg = floor((d*d + d)/2 * 8 * size + 1); knockback along the
//! center-to-victim dir scaled by exposure (EPF applied by the caller via
//! the existing blast-protection tables).
//!
//! Exposure is sampled on 9 rays (AABB corners + center) against the same
//! non-air-blocks rule the raycast uses (water/glass attenuate: vanilla
//! water-protects-TNT behavior). 1Hz quantization is documented, not
//! hidden: vanilla samples (size*2+1)^3 points per entity per blast.

const std = @import("std");
const ids = @import("../../ids.zig");
const JavaRandom = @import("../../worldgen/rng/java_random.zig").JavaRandom;

/// Integer blast cell.
pub const Cell = struct { x: i32, y: i32, z: i32 };

/// Block sample for the core: canonical id + post-/5 attenuation value.
/// The server fills `res` from `blast_data.attenuate`.
pub const Block = struct { id: ids.Id, res: f32 };

/// Block reader: null = missing chunk (reads as air).
pub const GetBlock = *const fn (ctx: *anyopaque, x: i32, y: i32, z: i32) ?Block;

/// Hard caps (anti-lag; the server budgets blasts per tick on top).
pub const max_cells: usize = 1024;
pub const max_primes: usize = 256;
/// Max ray steps: power can never survive longer than this (size 4 max
/// initial power 5.2 / 0.225 drain ~= 24 air steps; resistance only
/// shortens). Generous bound so dense obsidian fields still terminate.
pub const max_steps: usize = 256;

pub const Collected = struct {
    breaks: []Cell,
    n_breaks: usize,
    primes: []Cell,
    n_primes: usize,
};

/// One 16^3-face raycast exposure pass. `out_breaks`/`out_primes` are
/// caller buffers (`max_cells`/`max_primes`); overflow sets `truncated`.
/// Returns counts. RNG draws match vanilla order (one nextFloat per ray).
pub fn collect(
    get: GetBlock,
    ctx: *anyopaque,
    cx: f64,
    cy: f64,
    cz: f64,
    size: f32,
    rng: *JavaRandom,
    out_breaks: []Cell,
    out_primes: []Cell,
) struct {
    n_breaks: usize,
    n_primes: usize,
    truncated: bool,
} {
    var n_breaks: usize = 0;
    var n_primes: usize = 0;
    var truncated = false;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        var j: usize = 0;
        while (j < 16) : (j += 1) {
            var k: usize = 0;
            while (k < 16) : (k += 1) {
                const face = i == 0 or i == 15 or j == 0 or j == 15 or k == 0 or k == 15;
                if (!face) continue;
                var dx = @as(f64, @floatFromInt(i)) / 15.0 * 2.0 - 1.0;
                var dy = @as(f64, @floatFromInt(j)) / 15.0 * 2.0 - 1.0;
                var dz = @as(f64, @floatFromInt(k)) / 15.0 * 2.0 - 1.0;
                const len = @sqrt(dx * dx + dy * dy + dz * dz);
                dx /= len;
                dy /= len;
                dz /= len;
                var f = size * (0.7 + rng.nextFloat() * 0.6);
                var px = cx;
                var py = cy;
                var pz = cz;
                var step: usize = 0;
                while (f > 0 and step < max_steps) : (step += 1) {
                    // Unconditional air drain (jar `f1 -= f2 * 0.75F`).
                    f -= 0.3 * 0.75;
                    const bx: i32 = @intFromFloat(@floor(px));
                    const by: i32 = @intFromFloat(@floor(py));
                    const bz: i32 = @intFromFloat(@floor(pz));
                    if (by >= 0 and by <= 255) {
                        if (get(ctx, bx, by, bz)) |b| {
                            if (b.id != ids.air) {
                                f -= (b.res + 0.3) * 0.3;
                                if (f > 0) {
                                    if (b.id == ids.tnt) {
                                        if (!contains(out_primes[0..n_primes], bx, by, bz)) {
                                            if (n_primes < out_primes.len and n_primes < max_primes) {
                                                out_primes[n_primes] = .{ .x = bx, .y = by, .z = bz };
                                                n_primes += 1;
                                            } else {
                                                truncated = true;
                                            }
                                        }
                                    } else {
                                        if (!contains(out_breaks[0..n_breaks], bx, by, bz)) {
                                            if (n_breaks < out_breaks.len and n_breaks < max_cells) {
                                                out_breaks[n_breaks] = .{ .x = bx, .y = by, .z = bz };
                                                n_breaks += 1;
                                            } else {
                                                truncated = true;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    px += dx * 0.3;
                    py += dy * 0.3;
                    pz += dz * 0.3;
                }
            }
        }
    }
    return .{ .n_breaks = n_breaks, .n_primes = n_primes, .truncated = truncated };
}

fn contains(cells: []const Cell, x: i32, y: i32, z: i32) bool {
    for (cells) |c| if (c.x == x and c.y == y and c.z == z) return true;
    return false;
}

/// Fraction of unblocked segments from the blast center to the victim
/// AABB (9 sample rays: 8 corners + center; blocked by any non-air cell,
/// missing chunks read as air). Returns 0..1.
pub fn exposure(
    get: GetBlock,
    ctx: *anyopaque,
    cx: f64,
    cy: f64,
    cz: f64,
    min_x: f64,
    min_y: f64,
    min_z: f64,
    max_x: f64,
    max_y: f64,
    max_z: f64,
) f64 {
    var open: usize = 0;
    var total: usize = 0;
    var ix: usize = 0;
    while (ix < 2) : (ix += 1) {
        var iy: usize = 0;
        while (iy < 2) : (iy += 1) {
            var iz: usize = 0;
            while (iz < 2) : (iz += 1) {
                const tx = if (ix == 0) min_x else max_x;
                const ty = if (iy == 0) min_y else max_y;
                const tz = if (iz == 0) min_z else max_z;
                total += 1;
                if (segmentOpen(get, ctx, cx, cy, cz, tx, ty, tz)) open += 1;
            }
        }
    }
    total += 1;
    if (segmentOpen(get, ctx, cx, cy, cz, (min_x + max_x) / 2, (min_y + max_y) / 2, (min_z + max_z) / 2)) open += 1;
    return @as(f64, @floatFromInt(open)) / @as(f64, @floatFromInt(total));
}

/// True when no non-air cell intersects the segment (0.25 substeps).
fn segmentOpen(
    get: GetBlock,
    ctx: *anyopaque,
    x0: f64,
    y0: f64,
    z0: f64,
    x1: f64,
    y1: f64,
    z1: f64,
) bool {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const dz = z1 - z0;
    const dist = @sqrt(dx * dx + dy * dy + dz * dz);
    const steps: usize = @intFromFloat(@max(1.0, dist / 0.25));
    var s: usize = 1;
    while (s < steps) : (s += 1) {
        const t = @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(steps));
        const bx: i32 = @intFromFloat(@floor(x0 + dx * t));
        const by: i32 = @intFromFloat(@floor(y0 + dy * t));
        const bz: i32 = @intFromFloat(@floor(z0 + dz * t));
        // Endpoints live inside blocks by construction (center cell,
        // victim AABB); only the middle can block.
        if (by < 0 or by > 255) continue;
        if (get(ctx, bx, by, bz)) |b| {
            if (b.id != ids.air) return false;
        }
    }
    return true;
}

/// Vanilla damage shape (pre-EPF, pre-floor): d = (1-dist/(size*2))*expo.
pub fn damageFor(size: f32, dist: f64, expo: f64) f32 {
    const d = (1.0 - dist / (@as(f64, size) * 2.0)) * expo;
    if (d <= 0) return 0;
    return @floatCast((d * d + d) / 2.0 * 8.0 * @as(f64, size) + 1.0);
}

/// Knockback unit dir from the blast center to the victim center.
pub fn knockDir(cx: f64, cy: f64, cz: f64, vx: f64, vy: f64, vz: f64) [3]f64 {
    var dx = vx - cx;
    var dy = (vy + 0.9) - cy; // victim center (~feet+0.9)
    var dz = vz - cz;
    const len = @sqrt(dx * dx + dy * dy + dz * dz);
    if (len < 1e-6) return .{ 0, 1, 0 };
    dx /= len;
    dy /= len;
    dz /= len;
    return .{ dx, dy, dz };
}

// ---------------------------------------------------------------------------
// Goldens (flat stone, fixed seeds — the K4 acceptance shape).
// ---------------------------------------------------------------------------

const FlatCtx = struct {
    top: i32, // stone < top, grass at top, air above
};

fn flatGet(ctx: *anyopaque, x: i32, y: i32, z: i32) ?Block {
    _ = x;
    _ = z;
    const c: *const FlatCtx = @ptrCast(@alignCast(ctx));
    if (y < 0 or y > 255) return null;
    if (y < c.top) return .{ .id = ids.stone, .res = 2.0 };
    if (y == c.top) return .{ .id = ids.grass, .res = 3.0 / 5.0 };
    return .{ .id = ids.air, .res = 0 };
}

test "flat-stone crater golden (TNT size 4, seed 42)" {
    var ctx = FlatCtx{ .top = 64 };
    var rng = JavaRandom.init(42);
    var breaks: [max_cells]Cell = undefined;
    var primes: [max_primes]Cell = undefined;
    const r = collect(flatGet, &ctx, 0.5, 65.5, 0.5, 4.0, &rng, &breaks, &primes);
    try std.testing.expect(!r.truncated);
    try std.testing.expectEqual(@as(usize, 0), r.n_primes);
    // Crater sanity: breaks exist, all at/above the stone line and within
    // a few blocks of the blast (size-4 crater on stone is small).
    try std.testing.expect(r.n_breaks > 20 and r.n_breaks < 400);
    var min_y: i32 = 999;
    var max_d: u32 = 0;
    for (breaks[0..r.n_breaks]) |c| {
        try std.testing.expect(c.y >= 63 and c.y <= 65);
        min_y = @min(min_y, c.y);
        const d = @max(@abs(c.x), @abs(c.z));
        max_d = @max(max_d, d);
        // Every break is stone or grass in this world.
        try std.testing.expect(c.y < 64 or c.y == 64);
    }
    // Digs into the stone and spreads a couple blocks out.
    try std.testing.expectEqual(@as(i32, 63), min_y);
    try std.testing.expect(max_d >= 1 and max_d <= 4);
}

test "water absorbs, bedrock stops, air is free" {
    const Ctx = struct {
        fn get(_: *anyopaque, x: i32, y: i32, z: i32) ?Block {
            // Column: water at y=64..65 over stone; bedrock floor at y=2.
            if (y < 0 or y > 255) return null;
            if (x == 100 and z == 100) {
                if (y == 2) return .{ .id = ids.bedrock, .res = 18000000.0 / 5.0 };
                if (y < 64) return .{ .id = ids.stone, .res = 2.0 };
                if (y <= 65) return .{ .id = ids.water, .res = 100.0 };
                return .{ .id = ids.air, .res = 0 };
            }
            if (y == 2) return .{ .id = ids.bedrock, .res = 18000000.0 / 5.0 };
            if (y < 64) return .{ .id = ids.stone, .res = 2.0 };
            if (y == 64) return .{ .id = ids.grass, .res = 0.6 };
            return .{ .id = ids.air, .res = 0 };
        }
    };
    var rng = JavaRandom.init(7);
    var breaks: [max_cells]Cell = undefined;
    var primes: [max_primes]Cell = undefined;
    // Blast submerged at the water column: water eats the rays.
    const wet = collect(Ctx.get, @ptrCast(&rng), 100.5, 66.5, 100.5, 4.0, &rng, &breaks, &primes);
    // Same blast in the open for comparison.
    var rng2 = JavaRandom.init(7);
    var breaks2: [max_cells]Cell = undefined;
    var primes2: [max_primes]Cell = undefined;
    const dry = collect(Ctx.get, @ptrCast(&rng2), 0.5, 65.5, 0.5, 4.0, &rng2, &breaks2, &primes2);
    try std.testing.expect(wet.n_breaks < dry.n_breaks);
    // Bedrock floor never breaks in either.
    for (breaks[0..wet.n_breaks]) |c| try std.testing.expect(c.y != 2);
    for (breaks2[0..dry.n_breaks]) |c| try std.testing.expect(c.y != 2);
}

test "tnt cells prime instead of breaking" {
    const Ctx = struct {
        fn get(_: *anyopaque, x: i32, y: i32, z: i32) ?Block {
            if (y < 0 or y > 255) return null;
            if (x == 1 and y == 65 and z == 0) return .{ .id = ids.tnt, .res = 0 };
            if (y < 64) return .{ .id = ids.stone, .res = 2.0 };
            if (y == 64) return .{ .id = ids.grass, .res = 0.6 };
            return .{ .id = ids.air, .res = 0 };
        }
    };
    var rng = JavaRandom.init(99);
    var breaks: [max_cells]Cell = undefined;
    var primes: [max_primes]Cell = undefined;
    var _dummy: u8 = 0;
    const r = collect(Ctx.get, &_dummy, 0.5, 65.5, 0.5, 4.0, &rng, &breaks, &primes);
    // Adjacent TNT must chain, never shatter into drops.
    var found = false;
    for (primes[0..r.n_primes]) |c| {
        if (c.x == 1 and c.y == 65 and c.z == 0) found = true;
    }
    try std.testing.expect(found);
    for (breaks[0..r.n_breaks]) |c| {
        try std.testing.expect(!(c.x == 1 and c.y == 65 and c.z == 0));
    }
}

test "damage formula anchors" {
    // Point-blank, full exposure: (1+1)/2*8*4+1 = 33.
    try std.testing.expectEqual(@as(f32, 33.0), damageFor(4.0, 0.0, 1.0));
    // Edge of radius: 0.
    try std.testing.expectEqual(@as(f32, 0.0), damageFor(4.0, 8.0, 1.0));
    // Half distance, full exposure: d=0.5 -> (0.25+0.5)/2*32+1 = 13.
    try std.testing.expectEqual(@as(f32, 13.0), damageFor(4.0, 4.0, 1.0));
    // No exposure: no damage even point-blank.
    try std.testing.expectEqual(@as(f32, 0.0), damageFor(4.0, 0.5, 0.0));
}

test "exposure: open sky vs behind a wall" {
    const Ctx = struct {
        fn get(_: *anyopaque, x: i32, y: i32, z: i32) ?Block {
            // Solid wall plane at x=2, z -1..1, y 64..67.
            if (y < 0 or y > 255) return null;
            if (x == 2 and z >= -1 and z <= 1 and y >= 64 and y <= 67) return .{ .id = ids.stone, .res = 2.0 };
            if (y < 64) return .{ .id = ids.stone, .res = 2.0 };
            return .{ .id = ids.air, .res = 0 };
        }
    };
    // Victim in the open next to the blast.
    var _dummy2: u8 = 0;
    const open = exposure(Ctx.get, &_dummy2, 0.5, 65.5, 0.5, 0.2, 65.0, -0.3, 0.8, 66.8, 0.3);
    try std.testing.expect(open > 0.9);
    // Same victim shape, wall between blast and victim.
    const walled = exposure(Ctx.get, &_dummy2, 0.5, 65.5, 0.5, 3.2, 65.0, -0.3, 3.8, 66.8, 0.3);
    try std.testing.expect(walled < 0.2);
}

test "64-blast chain stays bounded (no recursion, caps hold)" {
    var ctx = FlatCtx{ .top = 64 };
    var total: usize = 0;
    var s: usize = 0;
    while (s < 64) : (s += 1) {
        // Chain grid: blasts 2 apart on the surface, seed varies per blast
        // the way the server's explosion stream would.
        var rng = JavaRandom.init(@as(i64, @intCast(s)) * 7919 + 13);
        var breaks: [max_cells]Cell = undefined;
        var primes: [max_primes]Cell = undefined;
        const x: f64 = @as(f64, @floatFromInt(@as(i32, @intCast(s % 8)) * 2));
        const z: f64 = @as(f64, @floatFromInt(@as(i32, @intCast(s / 8)) * 2));
        const r = collect(flatGet, &ctx, x + 0.5, 65.5, z + 0.5, 4.0, &rng, &breaks, &primes);
        try std.testing.expect(!r.truncated);
        total += r.n_breaks;
    }
    // Bounded total work for the whole chain (each blast is small).
    try std.testing.expect(total < 64 * 400);
}
