//! 1.7.10 decorators: ores (WorldGenMinable) + trees.
//!
//! Ports `ase` (minable), `asq`/`are`/`asn`/`aso` (trees), and the
//! `aia` (BiomeDecorator) ore/tree loops with `aqz` populate seeding.
//! Shape goldens are live JVM outputs (OreShape/TreeShape harnesses using
//! the REAL jar classes); RNG call order is spec.
//!
//! Scope (documented approximations):
//! - Ores: the 8 universal veins (dirt/gravel/coal/iron/gold/redstone/
//!   diamond/lapis) with vanilla counts, sizes, y-ranges. Emerald (extreme
//!   hills) is skipped.
//! - Trees: oak (`asq`), birch (`are`), spruce (`asn`), tall-oak (`aso`
//!   for swamp, shape-exact). Big-oak (`ard`), acacia (`ask`), jungle
//!   giants (`asi`/`arp`/`arz`), mushrooms (`aru`) map to small-oak with
//!   the same RNG draws consumed (documented; shapes differ).
//! - Sand (`asj` sand) / clay (`arj`) / gravel (`asj` gravel) disks are
//!   implemented (they come before trees in RNG order).
//! - Structures, lakes, dungeons (which precede ores in `aqz.populate`)
//!   are NOT replicated: our decorator seed starts fresh per chunk via
//!   populate-style mixing, so positions differ from vanilla while
//!   shapes/counts/distributions match. Full populate-chain parity is
//!   future work (needs structures/lakes/dungeons).
//! - 3x3 neighbor loop: each of the 9 chunks runs its own populate in an
//!   ISOLATED copy of the terrain view, merged in fixed order (neighbors
//!   sorted, center wins ties). Isolation keeps trunk/canopy consistent:
//!   sharing one mutable view let place/abort checks diverge per run
//!   (canopy kept without its trunk). Vanilla order is exploration-
//!   dependent; ours is canonical (pure function of seed+chunk).

const std = @import("std");
const java_random = @import("../rng/java_random.zig");
const carve_mod = @import("carve.zig");
const genlayer_mod = @import("genlayer.zig");
const noise_mod = @import("noise.zig");
const ids = @import("../../ids.zig");
const wire = @import("../../proto/v5/wire_ids.zig");


// ---------------------------------------------------------------------------
// View: mutable block+meta window with world-coord access.
// ---------------------------------------------------------------------------

pub const View = struct {
    blocks: []ids.Id,
    metas: []u8,
    ox: i32, // world x of local (0,0)
    oz: i32,
    sx: usize,
    sz: usize,

    fn idx(self: *const View, wx: i32, y: i32, wz: i32) ?usize {
        if (y < 0 or y >= 256) return null;
        const lx = wx - self.ox;
        const lz = wz - self.oz;
        if (lx < 0 or lz < 0) return null;
        const ux: usize = @intCast(lx);
        const uz: usize = @intCast(lz);
        if (ux >= self.sx or uz >= self.sz) return null;
        return (ux * self.sz + uz) * 256 + @as(usize, @intCast(y));
    }

    pub fn get(self: *const View, wx: i32, y: i32, wz: i32) ids.Id {
        const i = self.idx(wx, y, wz) orelse return ids.air;
        return self.blocks[i];
    }

    pub fn getMeta(self: *const View, wx: i32, y: i32, wz: i32) u8 {
        const i = self.idx(wx, y, wz) orelse return 0;
        return self.metas[i];
    }

    pub fn set(self: *View, wx: i32, y: i32, wz: i32, id: ids.Id, meta: u8) void {
        const i = self.idx(wx, y, wz) orelse return;
        self.blocks[i] = id;
        self.metas[i] = meta;
    }

    /// Is-air for tree space checks (matches `ahb.c`: true when air).
    /// Out-of-bounds reads as solid (fail closed, unlike ores which skip).
    pub fn isAir(self: *const View, wx: i32, y: i32, wz: i32) bool {
        const i = self.idx(wx, y, wz) orelse return false;
        return self.blocks[i] == ids.air;
    }
};

// ---------------------------------------------------------------------------
// qh helpers (share carve's bit-exact trig table).
// ---------------------------------------------------------------------------

var trig: ?[65536]f32 = null;

fn table() *const [65536]f32 {
    if (trig == null) trig = carve_mod.buildTrigTable();
    return &trig.?;
}

fn qhSin(f: f32) f32 {
    return carve_mod.qhSin(table(), f);
}

fn qhCos(f: f32) f32 {
    return carve_mod.qhCos(table(), f);
}

fn floorD(d: f64) i32 {
    const t: i32 = @intFromFloat(d);
    return if (d < @as(f64, @floatFromInt(t))) t - 1 else t;
}

const PI_F: f32 = 3.1415927; // (float)Math.PI, matches `nextFloat()*PI` in ase

// ---------------------------------------------------------------------------
// WorldGenMinable (`ase`): ellipsoid vein walk replacing stone.
// ---------------------------------------------------------------------------

/// Single vein at world (wx,wy,wz). Replaces `target` (stone) with `ore`.
/// Mirrors `ase.a` exactly (float math, RNG order, floor, bounds).
pub fn minable(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32, ore: ids.Id, size: i32, target: ids.Id) !void {
    const f: f32 = rand.nextFloat() * PI_F;
    const sf = qhSin(f);
    const cf = qhCos(f);
    const half: f32 = @as(f32, @floatFromInt(size)) / 8.0;
    const d: f64 = @as(f64, @floatFromInt(wx + 8)) + @as(f64, sf * half);
    const d2: f64 = @as(f64, @floatFromInt(wx + 8)) - @as(f64, sf * half);
    const d3: f64 = @as(f64, @floatFromInt(wz + 8)) + @as(f64, cf * half);
    const d4: f64 = @as(f64, @floatFromInt(wz + 8)) - @as(f64, cf * half);
    const d5: f64 = @as(f64, wy + try rand.nextIntBound(3) - 2);
    const d6: f64 = @as(f64, wy + try rand.nextIntBound(3) - 2);
    var i: i32 = 0;
    while (i <= size) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const fs: f32 = @floatFromInt(size);
        const d7: f64 = d + (d2 - d) * @as(f64, fi) / @as(f64, fs);
        const d8: f64 = d5 + (d6 - d5) * @as(f64, fi) / @as(f64, fs);
        const d9: f64 = d3 + (d4 - d3) * @as(f64, fi) / @as(f64, fs);
        const d10: f64 = rand.nextDouble() * @as(f64, @floatFromInt(size)) / 16.0;
        // NOTE: `qh.a(i*PI/size)+1` in f32, then widened. Replicate exactly:
        // `d11 = (sin(i*PI/size)+1) * d10 + 1`.
        const ang: f32 = fi * PI_F / fs;
        const s1: f64 = @as(f64, qhSin(ang)) + 1.0;
        const d11: f64 = s1 * d10 + 1.0;
        const d12: f64 = s1 * d10 + 1.0;
        const n4: i32 = floorD(d7 - d11 / 2.0);
        const n5: i32 = floorD(d8 - d12 / 2.0);
        const n6: i32 = floorD(d9 - d11 / 2.0);
        const n7: i32 = floorD(d7 + d11 / 2.0);
        const n8: i32 = floorD(d8 + d12 / 2.0);
        const n9: i32 = floorD(d9 + d11 / 2.0);
        var jx: i32 = n4;
        while (jx <= n7) : (jx += 1) {
            const d13: f64 = (@as(f64, @floatFromInt(jx)) + 0.5 - d7) / (d11 / 2.0);
            if (!(d13 * d13 < 1.0)) continue;
            var jy: i32 = n5;
            while (jy <= n8) : (jy += 1) {
                const d14: f64 = (@as(f64, @floatFromInt(jy)) + 0.5 - d8) / (d12 / 2.0);
                if (!(d13 * d13 + d14 * d14 < 1.0)) continue;
                var jz: i32 = n6;
                while (jz <= n9) : (jz += 1) {
                    const d15: f64 = (@as(f64, @floatFromInt(jz)) + 0.5 - d9) / (d11 / 2.0);
                    if (!(d13 * d13 + d14 * d14 + d15 * d15 < 1.0)) continue;
                    if (view.get(jx, jy, jz) != target) continue;
                    view.set(jx, jy, jz, ore, 0);
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Shape tests vs JVM (OreShape harness, real `ase`).
// ---------------------------------------------------------------------------

test "minable coal matches JVM (seed 42)" {
    const alloc = std.testing.allocator;
    const S: usize = 64;
    const blocks = try alloc.alloc(ids.Id, S * 256 * S);
    defer alloc.free(blocks);
    const metas = try alloc.alloc(u8, S * 256 * S);
    defer alloc.free(metas);
    @memset(blocks, ids.air);
    @memset(metas, 0);
    // stone below y=70 (matches harness)
    for (0..S) |x| {
        for (0..S) |z| {
            for (0..70) |y| {
                blocks[(x * S + z) * 256 + y] = ids.stone;
            }
        }
    }
    var view = View{ .blocks = blocks, .metas = metas, .ox = -32, .oz = -32, .sx = S, .sz = S };
    var r = java_random.JavaRandom.init(42);
    try minable(&view, &r, 0, 50, 0, ids.coal_ore, 16, ids.stone);
    // JVM: changed=20, crc over 64x32x64 window around (0,50,0)
    var crc: i64 = 0;
    var changed: usize = 0;
    var coal: usize = 0;
    var wx: i32 = -32;
    while (wx < 32) : (wx += 1) {
        var wy: i32 = 34;
        while (wy < 66) : (wy += 1) {
            var wz: i32 = -32;
            while (wz < 32) : (wz += 1) {
                const id = view.get(wx, wy, wz);
                crc = crc *% 31 +% @as(i64, wire.toWire(id)); // JVM goldens are wire ids
                if (id == ids.coal_ore) coal += 1;
                if (id != ids.stone and id != ids.air) changed += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 20), coal);
    try std.testing.expectEqual(@as(usize, 20), changed);
    try std.testing.expectEqual(@as(i64, 6664539788273627968), crc);
}

test "minable iron/gold/redstone/diamond/lapis match JVM (seed 42)" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { ore: ids.Id, size: i32, want_n: usize, want_crc: i64 }{
        .{ .ore = ids.iron_ore, .size = 8, .want_n = 4, .want_crc = -4985998703837180800 },
        .{ .ore = ids.gold_ore, .size = 8, .want_n = 4, .want_crc = -1848336028041915200 },
        .{ .ore = ids.redstone_ore, .size = 7, .want_n = 4, .want_crc = -2502993162867069440 },
        .{ .ore = ids.diamond_ore, .size = 7, .want_n = 4, .want_crc = -4502959895476209088 },
        .{ .ore = ids.lapis_ore, .size = 6, .want_n = 4, .want_crc = -5365230684899222784 },
    };
    for (cases) |c| {
        const S: usize = 64;
        const blocks = try alloc.alloc(ids.Id, S * 256 * S);
        defer alloc.free(blocks);
        const metas = try alloc.alloc(u8, S * 256 * S);
        defer alloc.free(metas);
        @memset(blocks, ids.air);
        @memset(metas, 0);
        for (0..S) |x| {
            for (0..S) |z| {
                for (0..70) |y| {
                    blocks[(x * S + z) * 256 + y] = ids.stone;
                }
            }
        }
        var view = View{ .blocks = blocks, .metas = metas, .ox = -32, .oz = -32, .sx = S, .sz = S };
        var r = java_random.JavaRandom.init(42);
        try minable(&view, &r, 0, 50, 0, c.ore, c.size, ids.stone);
        var crc: i64 = 0;
        var n: usize = 0;
        var wx: i32 = -32;
        while (wx < 32) : (wx += 1) {
            var wy: i32 = 34;
            while (wy < 66) : (wy += 1) {
                var wz: i32 = -32;
                while (wz < 32) : (wz += 1) {
                    const id = view.get(wx, wy, wz);
                    crc = crc *% 31 +% @as(i64, wire.toWire(id)); // JVM goldens are wire ids
                    if (id == c.ore) n += 1;
                }
            }
        }
        try std.testing.expectEqual(c.want_crc, crc);
        try std.testing.expectEqual(c.want_n, n);
    }
}

test "minable dirt/gravel match JVM (seed 42)" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { ore: ids.Id, size: i32, want_n: usize, want_crc: i64 }{
        .{ .ore = ids.dirt, .size = 32, .want_n = 102, .want_crc = 3423075958434408956 },
        .{ .ore = ids.gravel, .size = 32, .want_n = 102, .want_crc = -8147241372490269720 },
    };
    for (cases) |c| {
        const S: usize = 64;
        const blocks = try alloc.alloc(ids.Id, S * 256 * S);
        defer alloc.free(blocks);
        const metas = try alloc.alloc(u8, S * 256 * S);
        defer alloc.free(metas);
        @memset(blocks, ids.air);
        @memset(metas, 0);
        for (0..S) |x| {
            for (0..S) |z| {
                for (0..70) |y| {
                    blocks[(x * S + z) * 256 + y] = ids.stone;
                }
            }
        }
        var view = View{ .blocks = blocks, .metas = metas, .ox = -32, .oz = -32, .sx = S, .sz = S };
        var r = java_random.JavaRandom.init(42);
        try minable(&view, &r, 0, 50, 0, c.ore, c.size, ids.stone);
        var crc: i64 = 0;
        var n: usize = 0;
        var wx: i32 = -32;
        while (wx < 32) : (wx += 1) {
            var wy: i32 = 34;
            while (wy < 66) : (wy += 1) {
                var wz: i32 = -32;
                while (wz < 32) : (wz += 1) {
                    const id = view.get(wx, wy, wz);
                    crc = crc *% 31 +% @as(i64, wire.toWire(id)); // JVM goldens are wire ids
                    if (id == c.ore) n += 1;
                }
            }
        }
        try std.testing.expectEqual(c.want_crc, crc);
        try std.testing.expectEqual(c.want_n, n);
    }
}

// ---------------------------------------------------------------------------
// Trees (`asq` oak, `are` birch, `asn` spruce, `aso` swamp oak).
// ---------------------------------------------------------------------------

/// Replaceable for tree space checks (`arc.a`): air, leaves, grass, dirt,
/// logs, saplings, vines. Everything else (stone, ores, sand...) fails.
fn replaceable(id: ids.Id) bool {
    return id == ids.air or id == ids.grass or id == ids.dirt or id == ids.log or id == ids.leaves or
        id == ids.log2 or id == ids.leaves2 or id == ids.sapling or id == ids.vine;
}

/// Opaque cube for leaf placement (`aji.j()`): leaves and air are NOT
/// opaque; everything else is. Pre-tree world has no other transparents.
fn isOpaque(id: ids.Id) bool {
    return id != ids.air and id != ids.leaves and id != ids.leaves2;
}

/// Oak (`asq`): height `h_min` + nextInt(3), log meta `lm`, leaves meta `em`,
/// vines when `do_vines`. Covers base oak (h=4, no vines) and jungle oak
/// (caller draws +nextInt(7) for h, vines + cocoa RNG).
/// Cocoa draws are consumed but placement is skipped (documented).
pub fn oakTree(
    view: *View,
    rand: *java_random.JavaRandom,
    wx: i32,
    wy: i32,
    wz: i32,
    h_min: i32,
    log_meta: u8,
    leaf_meta: u8,
    do_vines: bool,
    do_cocoa: bool,
) !bool {
    const n10: i32 = try rand.nextIntBound(3) + h_min;
    if (wy < 1 or wy + n10 + 1 > 256) return false;
    var y: i32 = wy;
    while (y <= wy + 1 + n10) : (y += 1) {
        var n9: i32 = 1;
        if (y == wy) n9 = 0;
        if (y >= wy + 1 + n10 - 2) n9 = 2;
        var x: i32 = wx - n9;
        while (x <= wx + n9) : (x += 1) {
            var z: i32 = wz - n9;
            while (z <= wz + n9) : (z += 1) {
                if (y < 0 or y >= 256) return false;
                if (!replaceable(view.get(x, y, z))) return false;
            }
        }
    }
    const soil = view.get(wx, wy - 1, wz);
    if (soil != ids.grass and soil != ids.dirt) return false;
    if (wy >= 256 - n10 - 1) return false;
    view.set(wx, wy - 1, wz, ids.dirt, 0);
    const n8: i32 = 0;
    y = wy - 3 + n10;
    while (y <= wy + n10) : (y += 1) {
        const n11: i32 = y - (wy + n10);
        const n6: i32 = n8 + 1 - @divTrunc(n11, 2);
        var x: i32 = wx - n6;
        while (x <= wx + n6) : (x += 1) {
            const n4: i32 = x - wx;
            var z: i32 = wz - n6;
            while (z <= wz + n6) : (z += 1) {
                const n12: i32 = z - wz;
                const corner = @abs(n4) == n6 and @abs(n12) == n6;
                if (corner and ((try rand.nextIntBound(2)) == 0 or n11 == 0)) continue;
                if (isOpaque(view.get(x, y, z))) continue;
                view.set(x, y, z, ids.leaves, leaf_meta);
            }
        }
    }
    var n7: i32 = 0;
    while (n7 < n10) : (n7 += 1) {
        const b = view.get(wx, wy + n7, wz);
        if (b != ids.air and b != ids.leaves and b != ids.leaves2) continue;
        view.set(wx, wy + n7, wz, ids.log, log_meta);
    }
    if (do_vines) {
        y = wy - 3 + n10;
        while (y <= wy + n10) : (y += 1) {
            const n13: i32 = y - (wy + n10);
            const n6: i32 = 2 - @divTrunc(n13, 2);
            var x: i32 = wx - n6;
            while (x <= wx + n6) : (x += 1) {
                var z: i32 = wz - n6;
                while (z <= wz + n6) : (z += 1) {
                    if (view.get(x, y, z) != ids.leaves and view.get(x, y, z) != ids.leaves2) continue;
                    if (try rand.nextIntBound(4) == 0 and view.get(x - 1, y, z) == ids.air) {
                        view.set(x - 1, y, z, ids.vine, 8);
                        hangVine(view, x - 1, y, z, 8);
                    }
                    if (try rand.nextIntBound(4) == 0 and view.get(x + 1, y, z) == ids.air) {
                        view.set(x + 1, y, z, ids.vine, 2);
                        hangVine(view, x + 1, y, z, 2);
                    }
                    if (try rand.nextIntBound(4) == 0 and view.get(x, y, z - 1) == ids.air) {
                        view.set(x, y, z - 1, ids.vine, 1);
                        hangVine(view, x, y, z - 1, 1);
                    }
                    if (try rand.nextIntBound(4) == 0 and view.get(x, y, z + 1) == ids.air) {
                        view.set(x, y, z + 1, ids.vine, 4);
                        hangVine(view, x, y, z + 1, 4);
                    }
                }
            }
        }
        if (do_cocoa and try rand.nextIntBound(5) == 0 and n10 > 5) {
            var n7c: i32 = 0;
            while (n7c < 2) : (n7c += 1) {
                var i: i32 = 0;
                while (i < 4) : (i += 1) {
                    if (try rand.nextIntBound(4 - n7c) != 0) continue;
                    _ = try rand.nextIntBound(3);
                }
            }
        }
    }
    return true;
}

fn hangVine(view: *View, wx: i32, wy: i32, wz: i32, meta: u8) void {
    var y = wy - 1;
    var left: i32 = 4;
    while (view.get(wx, y, wz) == ids.air and left > 0) : ({
        y -= 1;
        left -= 1;
    }) {
        view.set(wx, y, wz, ids.vine, meta);
    }
}

/// Birch (`are`): same shape as oak, height 5-7 (or +0-6 when tall),
/// log/leaves meta 2. Tall variant (`a` flag) adds `nextInt(7)`.
pub fn birchTree(
    view: *View,
    rand: *java_random.JavaRandom,
    wx: i32,
    wy: i32,
    wz: i32,
    tall: bool,
) !bool {
    var h_min: i32 = 5;
    if (tall) h_min += try rand.nextIntBound(7);
    return oakTree(view, rand, wx, wy, wz, h_min, 2, 2, false, false);
}

/// Swamp oak (`aso`): height nextInt(4)+5, WIDER canopy (radius 2-3 via
/// `2 - n6/2`), vines, no cocoa. Soil is grass/dirt (no farmland).
/// Down-shift loop (`while below material==h`) skipped: our views have no
/// tall-grass blocks, and the test/harness bases are always clear.
pub fn swampTree(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32) !bool {
    const n8: i32 = try rand.nextIntBound(4) + 5;
    if (wy < 1 or wy + n8 + 1 > 256) return false;
    var y: i32 = wy;
    while (y <= wy + 1 + n8) : (y += 1) {
        var n7: i32 = 1;
        if (y == wy) n7 = 0;
        if (y >= wy + 1 + n8 - 2) n7 = 3;
        var x: i32 = wx - n7;
        while (x <= wx + n7) : (x += 1) {
            var z: i32 = wz - n7;
            while (z <= wz + n7) : (z += 1) {
                if (y < 0 or y >= 256) return false;
                if (!replaceable(view.get(x, y, z))) return false;
            }
        }
    }
    const soil = view.get(wx, wy - 1, wz);
    if (soil != ids.grass and soil != ids.dirt) return false;
    if (wy >= 256 - n8 - 1) return false;
    view.set(wx, wy - 1, wz, ids.dirt, 0);
    y = wy - 3 + n8;
    while (y <= wy + n8) : (y += 1) {
        const n6: i32 = y - (wy + n8);
        const n5: i32 = 2 - @divTrunc(n6, 2);
        var x: i32 = wx - n5;
        while (x <= wx + n5) : (x += 1) {
            const n4: i32 = x - wx;
            var z: i32 = wz - n5;
            while (z <= wz + n5) : (z += 1) {
                const n9: i32 = z - wz;
                if (@abs(n4) == n5 and @abs(n9) == n5 and ((try rand.nextIntBound(2)) == 0 or n6 == 0)) continue;
                if (isOpaque(view.get(x, y, z))) continue;
                view.set(x, y, z, ids.leaves, 0);
            }
        }
    }
    var n7t: i32 = 0;
    while (n7t < n8) : (n7t += 1) {
        const b = view.get(wx, wy + n7t, wz);
        if (b != ids.air and b != ids.leaves and b != ids.leaves2) continue;
        view.set(wx, wy + n7t, wz, ids.log, 0);
    }
    y = wy - 3 + n8;
    while (y <= wy + n8) : (y += 1) {
        const n10: i32 = y - (wy + n8);
        const n5: i32 = 2 - @divTrunc(n10, 2);
        var x: i32 = wx - n5;
        while (x <= wx + n5) : (x += 1) {
            var z: i32 = wz - n5;
            while (z <= wz + n5) : (z += 1) {
                if (view.get(x, y, z) != ids.leaves and view.get(x, y, z) != ids.leaves2) continue;
                if (try rand.nextIntBound(4) == 0 and view.get(x - 1, y, z) == ids.air) {
                    view.set(x - 1, y, z, ids.vine, 8);
                    hangVine(view, x - 1, y, z, 8);
                }
                if (try rand.nextIntBound(4) == 0 and view.get(x + 1, y, z) == ids.air) {
                    view.set(x + 1, y, z, ids.vine, 2);
                    hangVine(view, x + 1, y, z, 2);
                }
                if (try rand.nextIntBound(4) == 0 and view.get(x, y, z - 1) == ids.air) {
                    view.set(x, y, z - 1, ids.vine, 1);
                    hangVine(view, x, y, z - 1, 1);
                }
                if (try rand.nextIntBound(4) == 0 and view.get(x, y, z + 1) == ids.air) {
                    view.set(x, y, z + 1, ids.vine, 4);
                    hangVine(view, x, y, z + 1, 4);
                }
            }
        }
    }
    return true;
}

/// Spruce (`asn`): tapered conifer, log/leaves meta 1.
/// Ports the CFR decompile exactly (space check shape, leaf layers,
// trunk height `n9 - nextInt(3)`).
pub fn spruceTree(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32) !bool {
    const n9: i32 = try rand.nextIntBound(4) + 6;
    const n10: i32 = 1 + try rand.nextIntBound(2);
    const n11: i32 = n9 - n10;
    const n12: i32 = 2 + try rand.nextIntBound(2);
    if (wy < 1 or wy + n9 + 1 > 256) return false;
    var y: i32 = wy;
    while (y <= wy + 1 + n9) : (y += 1) {
        var n8: i32 = 1;
        if (y - wy < n10) {
            n8 = 0;
        } else {
            n8 = n12;
        }
        var x: i32 = wx - n8;
        while (x <= wx + n8) : (x += 1) {
            var z: i32 = wz - n8;
            while (z <= wz + n8) : (z += 1) {
                if (y < 0 or y >= 256) return false;
                const b = view.get(x, y, z);
                if (b != ids.air and b != ids.leaves and b != ids.leaves2) return false;
            }
        }
    }
    const soil = view.get(wx, wy - 1, wz);
    if (soil != ids.grass and soil != ids.dirt) return false;
    if (wy >= 256 - n9 - 1) return false;
    view.set(wx, wy - 1, wz, ids.dirt, 0);
    var n8: i32 = try rand.nextIntBound(2);
    var n7: i32 = 1;
    var n6: i32 = 0;
    var n5: i32 = 0;
    while (n5 <= n11) : (n5 += 1) {
        const n4: i32 = wy + n9 - n5;
        var x: i32 = wx - n8;
        while (x <= wx + n8) : (x += 1) {
            const n13: i32 = x - wx;
            var z: i32 = wz - n8;
            while (z <= wz + n8) : (z += 1) {
                const n14: i32 = z - wz;
                if (@abs(n13) == n8 and @abs(n14) == n8 and n8 > 0) continue;
                if (isOpaque(view.get(x, n4, z))) continue;
                view.set(x, n4, z, ids.leaves, 1);
            }
        }
        if (n8 >= n7) {
            n8 = n6;
            n6 = 1;
            n7 += 1;
            if (n7 > n12) n7 = n12;
        } else {
            n8 += 1;
        }
    }
    const n5t: i32 = try rand.nextIntBound(3);
    var n4: i32 = 0;
    while (n4 < n9 - n5t) : (n4 += 1) {
        const b = view.get(wx, wy + n4, wz);
        if (b != ids.air and b != ids.leaves and b != ids.leaves2) continue;
        view.set(wx, wy + n4, wz, ids.log, 1);
    }
    return true;
}

test "oak tree matches JVM (seed 42)" {
    const alloc = std.testing.allocator;
    const S: usize = 32;
    const blocks = try alloc.alloc(ids.Id, S * 256 * S);
    defer alloc.free(blocks);
    const metas = try alloc.alloc(u8, S * 256 * S);
    defer alloc.free(metas);
    @memset(blocks, ids.air);
    @memset(metas, 0);
    for (0..S) |x| {
        for (0..S) |z| {
            for (0..70) |y| {
                blocks[(x * S + z) * 256 + y] = ids.stone;
            }
            blocks[(x * S + z) * 256 + 70] = ids.grass;
        }
    }
    var view = View{ .blocks = blocks, .metas = metas, .ox = -16, .oz = -16, .sx = S, .sz = S };
    var r = java_random.JavaRandom.init(42);
    try std.testing.expect(try oakTree(&view, &r, 0, 71, 0, 4, 0, 0, false, false));
    var crc: i64 = 0;
    var mcrc: i64 = 0;
    var logs: usize = 0;
    var leaves: usize = 0;
    var wx: i32 = -16;
    while (wx < 16) : (wx += 1) {
        var wy: i32 = 66;
        while (wy < 91) : (wy += 1) {
            var wz: i32 = -16;
            while (wz < 16) : (wz += 1) {
                const id = view.get(wx, wy, wz);
                const m = view.getMeta(wx, wy, wz);
                crc = crc *% 31 +% @as(i64, wire.toWire(id)); // JVM goldens are wire ids
                mcrc = mcrc *% 31 +% @as(i64, m);
                if (id == ids.log) logs += 1;
                if (id == ids.leaves) leaves += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 6), logs);
    try std.testing.expectEqual(@as(usize, 54), leaves);
    try std.testing.expectEqual(@as(i64, -1826668108914625103), crc);
    try std.testing.expectEqual(@as(i64, 0), mcrc);
}

test "birch/spruce/swamp trees match JVM (seed 42)" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { kind: u8, logs: usize, leaves: usize, vines: usize, crc: i64, mcrc: i64 }{
        .{ .kind = 0, .logs = 7, .leaves = 54, .vines = 0, .crc = -877977615031885440, .mcrc = 8117188618465272170 }, // birch
        .{ .kind = 1, .logs = 8, .leaves = 97, .vines = 0, .crc = -3696107158537190579, .mcrc = 3409266497238487387 }, // spruce
        .{ .kind = 2, .logs = 7, .leaves = 134, .vines = 60, .crc = 8230978779061728660, .mcrc = -8457845339367753324 }, // swamp
    };
    for (cases) |c| {
        const S: usize = 32;
        const blocks = try alloc.alloc(ids.Id, S * 256 * S);
        defer alloc.free(blocks);
        const metas = try alloc.alloc(u8, S * 256 * S);
        defer alloc.free(metas);
        @memset(blocks, ids.air);
        @memset(metas, 0);
        for (0..S) |x| {
            for (0..S) |z| {
                for (0..70) |y| blocks[(x * S + z) * 256 + y] = ids.stone;
                blocks[(x * S + z) * 256 + 70] = ids.grass;
            }
        }
        var view = View{ .blocks = blocks, .metas = metas, .ox = -16, .oz = -16, .sx = S, .sz = S };
        var r = java_random.JavaRandom.init(42);
        if (c.kind == 0) {
            try std.testing.expect(try birchTree(&view, &r, 0, 71, 0, false));
        } else if (c.kind == 1) {
            try std.testing.expect(try spruceTree(&view, &r, 0, 71, 0));
        } else {
            try std.testing.expect(try swampTree(&view, &r, 0, 71, 0));
        }
        var crc: i64 = 0;
        var mcrc: i64 = 0;
        var logs: usize = 0;
        var leaves: usize = 0;
        var vines: usize = 0;
        var wx: i32 = -16;
        while (wx < 16) : (wx += 1) {
            var wy: i32 = 66;
            while (wy < 91) : (wy += 1) {
                var wz: i32 = -16;
                while (wz < 16) : (wz += 1) {
                    const id = view.get(wx, wy, wz);
                    const m = view.getMeta(wx, wy, wz);
                    crc = crc *% 31 +% @as(i64, wire.toWire(id)); // JVM goldens are wire ids
                    mcrc = mcrc *% 31 +% @as(i64, m);
                    if (id == ids.log) logs += 1;
                    if (id == ids.leaves) leaves += 1;
                    if (id == ids.vine) vines += 1;
                }
            }
        }
        try std.testing.expectEqual(c.logs, logs);
        try std.testing.expectEqual(c.leaves, leaves);
        try std.testing.expectEqual(c.vines, vines);
        try std.testing.expectEqual(c.crc, crc);
        try std.testing.expectEqual(c.mcrc, mcrc);
    }
}

// ---------------------------------------------------------------------------
// Sand / clay / gravel disks (`asj` sand/gravel, `arj` clay).
// ---------------------------------------------------------------------------

/// Sand or gravel disk (`asj`): radius `nextInt(b-2)+2`, height 2 (n5=2).
/// Replaces dirt/grass with `mat`. Requires material-h at base (we check
/// grass/dirt, matching `o()==awt.h` for our block set).
pub fn sandDisk(
    view: *View,
    rand: *java_random.JavaRandom,
    wx: i32,
    wy: i32,
    wz: i32,
    mat: ids.Id,
    b: i32,
) !bool {
    // Vanilla requires water material (`awt.h`) at base: disks are
    // underwater patches. Land views correctly place nothing.
    const base = view.get(wx, wy, wz);
    if (base != ids.flowing_water and base != ids.water) return false;
    const n4: i32 = try rand.nextIntBound(b - 2) + 2;
    const n5: i32 = 2;
    var x: i32 = wx - n4;
    while (x <= wx + n4) : (x += 1) {
        var z: i32 = wz - n4;
        while (z <= wz + n4) : (z += 1) {
            const dx = x - wx;
            const dz = z - wz;
            if (dx * dx + dz * dz > n4 * n4) continue;
            var y: i32 = wy - n5;
            while (y <= wy + n5) : (y += 1) {
                const cur = view.get(x, y, z);
                if (cur != ids.dirt and cur != ids.grass) continue;
                view.set(x, y, z, mat, 0);
            }
        }
    }
    return true;
}

/// Clay disk (`arj`): radius `nextInt(2)+2` (b=4), height 1, replaces
/// dirt/clay with clay. Base must be grass/dirt (material-h check).
pub fn clayDisk(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32) !bool {
    const base = view.get(wx, wy, wz);
    if (base != ids.flowing_water and base != ids.water) return false;
    const n4: i32 = try rand.nextIntBound(2) + 2;
    const n5: i32 = 1;
    var x: i32 = wx - n4;
    while (x <= wx + n4) : (x += 1) {
        var z: i32 = wz - n4;
        while (z <= wz + n4) : (z += 1) {
            const dx = x - wx;
            const dz = z - wz;
            if (dx * dx + dz * dz > n4 * n4) continue;
            var y: i32 = wy - n5;
            while (y <= wy + n5) : (y += 1) {
                const cur = view.get(x, y, z);
                if (cur != ids.dirt and cur != ids.clay) continue;
                view.set(x, y, z, ids.clay, 0);
            }
        }
    }
    return true;
}

/// Underground spring (`asm`): needs stone above+below, center air-or-stone,
/// exactly 3 stone horizontals and 1 air among (down,east,north,south);
/// then sets the liquid. Water and lava share the shape.
pub fn springGen(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32, liquid: ids.Id) !bool {
    _ = rand;
    if (view.get(wx, wy + 1, wz) != ids.stone) return false;
    if (view.get(wx, wy - 1, wz) != ids.stone) return false;
    const c = view.get(wx, wy, wz);
    if (!view.isAir(wx, wy, wz) and c != ids.stone) return false;
    var stone_n: i32 = 0;
    if (view.get(wx - 1, wy, wz) == ids.stone) stone_n += 1;
    if (view.get(wx + 1, wy, wz) == ids.stone) stone_n += 1;
    if (view.get(wx, wy, wz - 1) == ids.stone) stone_n += 1;
    if (view.get(wx, wy, wz + 1) == ids.stone) stone_n += 1;
    var air_n: i32 = 0;
    if (view.isAir(wx, wy - 1, wz)) air_n += 1;
    if (view.isAir(wx + 1, wy, wz)) air_n += 1;
    if (view.isAir(wx, wy, wz - 1)) air_n += 1;
    if (view.isAir(wx, wy, wz + 1)) air_n += 1;
    if (stone_n != 3 or air_n != 1) return false;
    view.set(wx, wy, wz, liquid, 0);
    return true;
}

/// Surface lake (`arx`): ellipsoid hollow carved around (wx,wy,wz),
/// validated (shell must be liquid-free above / opaque below), filled with
/// liquid below y+4 and air above, grass dirt rim, and stone shell.
/// `frozen` is reserved: jar-verified vanilla `arx` has no snow/ice branch
/// (rim is always grass; surface ice comes from the populate snow/ice tail,
/// which already freezes top water per column). Kept so call sites don't
/// churn if a frozen-specific lake tweak is ever verified.
pub fn lakeGen(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32, liquid: ids.Id, frozen: bool) !bool {
    const x = wx - 8;
    var y = wy;
    const z = wz - 8;
    while (y > 5 and view.isAir(x, y, z)) y -= 1;
    if (y <= 4) return false;
    y -= 4;
    var hollow: [2048]bool = [_]bool{false} ** 2048;
    const layers: i32 = try rand.nextIntBound(4) + 4;
    var l: i32 = 0;
    while (l < layers) : (l += 1) {
        const rx = rand.nextDouble() * 6.0 + 3.0;
        const ry = rand.nextDouble() * 4.0 + 2.0;
        const rz = rand.nextDouble() * 6.0 + 3.0;
        const ox = rand.nextDouble() * (16.0 - rx - 2.0) + 1.0 + rx / 2.0;
        // NOTE: oy adds +2.0 (ldc 2.0 in bytecode), NOT +1.0 like ox/oz
        // (dconst_1). Misreading this as +1.0 shifts the whole bowl down
        // one block (224 lava vs vanilla's 131 for the seed-999 case).
        const oy = rand.nextDouble() * (8.0 - ry - 4.0) + 2.0 + ry / 2.0;
        const oz = rand.nextDouble() * (16.0 - rz - 2.0) + 1.0 + rz / 2.0;
        var i: i32 = 1;
        while (i < 15) : (i += 1) {
            var k: i32 = 1;
            while (k < 15) : (k += 1) {
                var j: i32 = 1;
                while (j < 7) : (j += 1) {
                    const dx = (@as(f64, @floatFromInt(i)) - ox) / (rx / 2.0);
                    const dy = (@as(f64, @floatFromInt(j)) - oy) / (ry / 2.0);
                    const dz = (@as(f64, @floatFromInt(k)) - oz) / (rz / 2.0);
                    if (dx * dx + dy * dy + dz * dz < 1.0) {
                        hollow[@as(usize, @intCast((i * 16 + k) * 8 + j))] = true;
                    }
                }
            }
        }
    }
    // Suitability: for each NON-hollow cell adjacent (6-neighborhood) to
    // hollow, the shell must be valid: upper half (j>=4) must hold no
    // liquid; lower half must be opaque or the lake liquid itself.
    // (Bytecode checks shell cells — h0||hn — not hollow interior.)
    var i: i32 = 0;
    while (i < 16) : (i += 1) {
        var k: i32 = 0;
        while (k < 16) : (k += 1) {
            var j: i32 = 0;
            while (j < 8) : (j += 1) {
                const h0: bool = hollow[@as(usize, @intCast((i * 16 + k) * 8 + j))];
                const hn: bool = (i < 15 and hollow[@as(usize, @intCast(((i + 1) * 16 + k) * 8 + j))]) or
                    (i > 0 and hollow[@as(usize, @intCast(((i - 1) * 16 + k) * 8 + j))]) or
                    (k < 15 and hollow[@as(usize, @intCast((i * 16 + (k + 1)) * 8 + j))]) or
                    (k > 0 and hollow[@as(usize, @intCast((i * 16 + (k - 1)) * 8 + j))]) or
                    (j < 7 and hollow[@as(usize, @intCast((i * 16 + k) * 8 + (j + 1)))]) or
                    (j > 0 and hollow[@as(usize, @intCast((i * 16 + k) * 8 + (j - 1)))]);
                if (!h0 and !hn) continue;
                if (h0) continue; // interior needs no validation
                const id = view.get(x + i, y + j, z + k);
                if (j >= 4) {
                    if (id == ids.water or id == ids.flowing_water or id == ids.lava or id == ids.flowing_lava) return false;
                } else {
                    if (!isSoilOpaque(id) and id != liquid) return false;
                }
            }
        }
    }
    // Fill: liquid below y+4, air above.
    i = 0;
    while (i < 16) : (i += 1) {
        var k: i32 = 0;
        while (k < 16) : (k += 1) {
            var j: i32 = 0;
            while (j < 8) : (j += 1) {
                if (!hollow[@as(usize, @intCast((i * 16 + k) * 8 + j))]) continue;
                if (j >= 4) {
                    view.set(x + i, y + j, z + k, ids.air, 0);
                } else {
                    view.set(x + i, y + j, z + k, liquid, 0);
                }
            }
        }
    }
    // Grass rim (jar-verified: always grass, even in frozen biomes — the
    // populate snow/ice tail lays snow_layer on top afterwards): for hollow
    // cells in the upper half, dirt directly below becomes grass when open
    // to the sky. Skylight in our engine is vertical-only (no horizontal
    // spread), so the light gate is approximated as always-pass (documented;
    // lakes generate near the surface where this holds).
    _ = frozen;
    i = 0;
    while (i < 16) : (i += 1) {
        var k: i32 = 0;
        while (k < 16) : (k += 1) {
            var j: i32 = 4;
            while (j < 8) : (j += 1) {
                if (!hollow[@as(usize, @intCast((i * 16 + k) * 8 + j))]) continue;
                if (view.get(x + i, y + j - 1, z + k) != ids.dirt) continue;
                view.set(x + i, y + j - 1, z + k, ids.grass, 0);
            }
        }
    }
    // Stone shell: shell cells (non-hollow adjacent to hollow) get a stone
    // casing. Lower half always; upper half proceeds on nextInt(2)!=0
    // (draws are load-bearing for everything downstream).
    i = 0;
    while (i < 16) : (i += 1) {
        var k: i32 = 0;
        while (k < 16) : (k += 1) {
            var j: i32 = 0;
            while (j < 8) : (j += 1) {
                const h0: bool = hollow[@as(usize, @intCast((i * 16 + k) * 8 + j))];
                const hn: bool = (i < 15 and hollow[@as(usize, @intCast(((i + 1) * 16 + k) * 8 + j))]) or
                    (i > 0 and hollow[@as(usize, @intCast(((i - 1) * 16 + k) * 8 + j))]) or
                    (k < 15 and hollow[@as(usize, @intCast((i * 16 + (k + 1)) * 8 + j))]) or
                    (k > 0 and hollow[@as(usize, @intCast((i * 16 + (k - 1)) * 8 + j))]) or
                    (j < 7 and hollow[@as(usize, @intCast((i * 16 + k) * 8 + (j + 1)))]) or
                    (j > 0 and hollow[@as(usize, @intCast((i * 16 + k) * 8 + (j - 1)))]);
                if (!h0 and !hn) continue;
                if (h0) continue; // shell only
                if (j >= 4 and try rand.nextIntBound(2) == 0) continue;
                if (!isSoilOpaque(view.get(x + i, y + j, z + k))) continue;
                view.set(x + i, y + j, z + k, ids.stone, 0);
            }
        }
    }
    // No freeze pass here (jar-verified `arx` ends at the stone shell;
    // surface ice in frozen biomes comes from the populate snow/ice tail,
    // which freezes each column's top water). The old y+3 ice cap iced
    // below the surface and left floating snow over ponds.
    return true;
}

/// Dungeon room (`asd`): floor/ceiling must be opaque; 1-5 wall openings;
/// carve with mossy/cobble floor (1/4 mossy) and cobble walls; 2 chest spots
/// (air + exactly 1 opaque horizontal neighbor) get plain chests — loot
/// needs tile-entity storage (follow-up; draws deferred with it); spawner
/// block placed, type drawn (Skeleton/Zombie/Zombie/Spider) but the entity
/// logic is a follow-up like all mob AI.
pub fn dungeonGen(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32) !bool {
    const iw: i32 = try rand.nextIntBound(2) + 2;
    const il: i32 = try rand.nextIntBound(2) + 2;
    // Suitability: floor (y-1) and ceiling (y+4) all opaque.
    var x: i32 = wx - iw - 1;
    while (x <= wx + iw + 1) : (x += 1) {
        var y: i32 = wy - 1;
        while (y <= wy + 3 + 1) : (y += 1) {
            var z: i32 = wz - il - 1;
            while (z <= wz + il + 1) : (z += 1) {
                if (y == wy - 1 and !isSoilOpaque(view.get(x, y, z))) return false;
                if (y == wy + 3 + 1 and !isSoilOpaque(view.get(x, y, z))) return false;
            }
        }
    }
    // Openings: border cells at floor level with 2 air above, 1..5 allowed.
    var openings: i32 = 0;
    x = wx - iw - 1;
    while (x <= wx + iw + 1) : (x += 1) {
        var y2: i32 = wy - 1;
        while (y2 <= wy + 3 + 1) : (y2 += 1) {
            var z: i32 = wz - il - 1;
            while (z <= wz + il + 1) : (z += 1) {
                const border = x == wx - iw - 1 or x == wx + iw + 1 or z == wz - il - 1 or z == wz + il + 1;
                if (!border or y2 != wy) continue;
                if (view.isAir(x, y2, z) and view.isAir(x, y2 + 1, z)) openings += 1;
            }
        }
    }
    if (openings < 1 or openings > 5) return false;
    // Carve: border -> mossy/cobble floor, cobble walls/ceiling (or air when
    // below is open); interior -> air.
    x = wx - iw - 1;
    while (x <= wx + iw + 1) : (x += 1) {
        var y3: i32 = wy + 3;
        while (y3 >= wy - 1) : (y3 -= 1) {
            var z: i32 = wz - il - 1;
            while (z <= wz + il + 1) : (z += 1) {
                const border = x == wx - iw - 1 or x == wx + iw + 1 or y3 == wy - 1 or y3 == wy + 3 + 1 or z == wz - il - 1 or z == wz + il + 1;
                if (!border) {
                    view.set(x, y3, z, ids.air, 0);
                    continue;
                }
                if (y3 < 0) {
                    view.set(x, y3, z, ids.air, 0);
                    continue;
                }
                if (!isSoilOpaque(view.get(x, y3 - 1, z))) {
                    view.set(x, y3, z, ids.air, 0);
                    continue;
                }
                if (y3 == wy - 1 and try rand.nextIntBound(4) == 0) {
                    view.set(x, y3, z, ids.mossy_cobblestone, 0);
                } else {
                    view.set(x, y3, z, ids.cobblestone, 0);
                }
            }
        }
    }
    // Chests: 2 spots, air + exactly 1 opaque horizontal neighbor.
    var c: i32 = 0;
    while (c < 2) : (c += 1) {
        const cx: i32 = wx + try rand.nextIntBound(iw * 2 + 1) - iw;
        const cz: i32 = wz + try rand.nextIntBound(il * 2 + 1) - il;
        if (!view.isAir(cx, wy, cz)) continue;
        var solid_n: i32 = 0;
        if (isSoilOpaque(view.get(cx - 1, wy, cz))) solid_n += 1;
        if (isSoilOpaque(view.get(cx + 1, wy, cz))) solid_n += 1;
        if (isSoilOpaque(view.get(cx, wy, cz - 1))) solid_n += 1;
        if (isSoilOpaque(view.get(cx, wy, cz + 1))) solid_n += 1;
        if (solid_n != 1) continue;
        view.set(cx, wy, cz, ids.chest, 0);
        // Loot rolls + spawner-entity logic need tile entities (follow-up);
        // the placement draws above are exact, loot draws are deferred with it.
    }
    // Spawner (type drawn exactly; block placed, entity logic follows mobs).
    view.set(wx, wy, wz, ids.mob_spawner, 0);
    _ = try rand.nextIntBound(4);
    return true;
}

/// Big mushroom (`aru`, type -1 = random): space check, dirt/grass/mycelium
/// soil, stem + cap with per-cell meta. Cap block id follows type
/// (brown/red); stem meta is 10. Red caps dome over 4 layers, brown is a
/// single wide layer; below-top red layers place rim cells only (corners get
/// pore metas 1/3/7/9). Center-column meta 5 becomes 0 below the top layer.
pub fn bigMushroom(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32) !bool {
    const mtype: i32 = try rand.nextIntBound(2);
    const h: i32 = try rand.nextIntBound(3) + 4;
    if (wy < 1 or wy + h + 1 > 256) return false;
    var y: i32 = wy;
    while (y <= wy + 1 + h) : (y += 1) {
        var rad: i32 = 1;
        if (y == wy) rad = 0;
        if (y >= wy + 1 + h - 2) rad = 2;
        var x: i32 = wx - rad;
        while (x <= wx + rad) : (x += 1) {
            var z: i32 = wz - rad;
            while (z <= wz + rad) : (z += 1) {
                if (y < 0 or y >= 256) return false;
                const id = view.get(x, y, z);
                if (id != ids.air and id != ids.leaves and id != ids.leaves2) return false;
            }
        }
    }
    const soil = view.get(wx, wy - 1, wz);
    if (soil != ids.dirt and soil != ids.grass and soil != ids.mycelium) return false;
    if (wy >= 256 - h - 1) return false;
    const cap: ids.Id = if (mtype == 0) ids.brown_mushroom_block else ids.red_mushroom_block;
    const cap_top: i32 = wy + h;
    const cap_bot: i32 = if (mtype == 1) wy + h - 3 else wy + h;
    var yy: i32 = cap_bot;
    while (yy <= cap_top) : (yy += 1) {
        var rad: i32 = 1;
        if (yy < wy + h) rad = 2;
        if (mtype == 0) rad = 3;
        var x: i32 = wx - rad;
        while (x <= wx + rad) : (x += 1) {
            var z: i32 = wz - rad;
            while (z <= wz + rad) : (z += 1) {
                if (mtype == 1 and yy < wy + h) {
                    // Below-top red layers: rim only, no corners.
                    const on_rim_x = x == wx - rad or x == wx + rad;
                    const on_rim_z = z == wz - rad or z == wz + rad;
                    if (!on_rim_x and !on_rim_z) continue;
                    if (on_rim_x and on_rim_z) continue;
                }
                var meta: u8 = 5;
                if (x == wx - rad) meta -= 1;
                if (x == wx + rad) meta += 1;
                if (z == wz - rad) meta -= 3;
                if (z == wz + rad) meta += 3;
                if (meta == 5 and yy < wy + h) meta = 0;
                if (!isOpaque(view.get(x, yy, z))) view.set(x, yy, z, cap, meta);
            }
        }
    }
    // Stem with meta 10.
    var sy: i32 = 0;
    while (sy < h) : (sy += 1) {
        if (!isOpaque(view.get(wx, wy + sy, wz))) view.set(wx, wy + sy, wz, cap, 10);
    }
    return true;
}

// ---------------------------------------------------------------------------
// Per-biome decorator params (from `aia` defaults + biome overrides).
// ---------------------------------------------------------------------------

/// Trees per chunk (`ar.x`). Mutated (+128) use base. Roofed forest (29)
// returns -999 (custom 4x4 grid skipped, documented).
/// Soil helpers for small-flora canStay checks (verified via Mats dump:
/// material h = water (ids 8,9), l = tallgrass/deadbush (31,32) + leaves2,
/// j = leaves (18,161), k = saplings/flowers/mushrooms/reeds/lily).
fn isWaterLike(id: ids.Id) bool {
    return id == ids.water or id == ids.flowing_water;
}

fn isSoilGrass(id: ids.Id) bool {
    return id == ids.grass or id == ids.dirt or id == ids.farmland;
}

fn isSoilOpaque(id: ids.Id) bool {
    return id != ids.air and id != ids.leaves and id != ids.leaves2 and !isWaterLike(id) and id != ids.flowing_lava and id != ids.lava;
}

fn isSoilDeadbush(id: ids.Id) bool {
    return id == ids.sand or id == ids.dirt or id == ids.hardened_clay or id == ids.stained_hardened_clay;
}

/// Per-biome decorate counts (vanilla `aia` fields, jar-verified via Dec):
/// trees=x, flowers=y, grass=z, deadbush=A, shrooms=B, reeds=C, cactus=D,
/// lilies=w, bigshroom=H. `ex_hills` runs the emerald+silverfish extra phase
/// (`aid`). Lake gate uses the RAW biome id (vanilla compares instances:
/// only exact desert/desert-hills skip; mutated desert does not).
pub const DecorParams = struct {
    trees: i32 = 0,
    flowers: i32 = 2,
    grass: i32 = 1,
    deadbush: i32 = 0,
    shrooms: i32 = 0,
    reeds: i32 = 0,
    cactus: i32 = 0,
    lilies: i32 = 0,
    bigshroom: i32 = 0,
    ex_hills: bool = false,
};

pub fn decorParams(biome_id: i32) DecorParams {
    const b: i32 = if (biome_id >= 128) biome_id - 128 else biome_id;
    return switch (b) {
        1 => .{ .trees = -999, .flowers = 4, .grass = 10 }, // plains
        2 => .{ .trees = -999, .flowers = 2, .grass = 1, .deadbush = 2, .reeds = 50, .cactus = 10 }, // desert
        3 => .{ .ex_hills = true }, // extreme hills (+emerald/silverfish below)
        4 => .{ .trees = 10, .flowers = 2, .grass = 2 }, // forest
        5 => .{ .trees = 10, .flowers = 2, .grass = 1, .shrooms = 1 }, // taiga
        6 => .{ .lilies = 4, .trees = 2, .flowers = 1, .grass = 5, .deadbush = 1, .shrooms = 8, .reeds = 10 }, // swamp
        14, 15 => .{ .trees = -100, .flowers = -100, .grass = -100, .shrooms = 1, .bigshroom = 1 }, // mushroom (trees/flowers/grass all off)
        16 => .{ .trees = -999, .flowers = 2, .grass = 1, .deadbush = 2, .reeds = 50, .cactus = 10 }, // beach
        17 => .{ .trees = -999, .flowers = 2, .grass = 1, .deadbush = 2, .reeds = 50, .cactus = 10 }, // desert hills
        18 => .{ .trees = 10, .flowers = 2, .grass = 2 }, // forest hills
        19 => .{ .trees = 10, .flowers = 2, .grass = 1, .shrooms = 1 }, // taiga hills
        20 => .{ .trees = 3, .flowers = 2, .grass = 1, .ex_hills = true }, // extreme hills edge
        21, 22 => .{ .trees = 50, .flowers = 4, .grass = 25 }, // jungle
        23 => .{ .trees = 2, .flowers = 4, .grass = 25 }, // jungle edge
        25 => .{ .trees = -999 }, // stone beach
        26 => .{ .trees = -999, .flowers = 2, .grass = 1, .deadbush = 2, .reeds = 50, .cactus = 10 }, // cold beach
        27, 28 => .{ .trees = 10, .flowers = 2, .grass = 2 }, // birch forest / hills
        29 => .{ .trees = -999, .flowers = 2, .grass = 2 }, // roofed forest
        30, 31 => .{ .trees = 10, .flowers = 2, .grass = 1, .shrooms = 1 }, // cold taiga
        32, 33 => .{ .trees = 10, .flowers = 2, .grass = 7, .deadbush = 1, .shrooms = 3 }, // mega taiga
        34 => .{ .trees = 3, .flowers = 2, .grass = 1, .ex_hills = true }, // extreme hills+
        35, 36 => .{ .trees = 1, .flowers = 4, .grass = 20 }, // savanna
        37 => .{ .trees = -999, .flowers = 0, .grass = 1, .deadbush = 20, .reeds = 3, .cactus = 5 }, // mesa
        38 => .{ .trees = 5, .flowers = 0, .grass = 1, .deadbush = 20, .reeds = 3, .cactus = 5 }, // mesa plateau F
        39 => .{ .trees = -999, .flowers = 0, .grass = 1, .deadbush = 20, .reeds = 3, .cactus = 5 }, // mesa plateau
        else => .{},
    };
}

/// Flower (y-loop) type for one attempt: (block, meta). Plains: tulip patch
/// (octave noise < -0.8) else poppy/houstonia/daisy/dandelion. Base: 1/3
/// dandelion, 2/3 poppy. (alc.a = red flowers, alc.b = [dandelion].)
fn flowerType(rand: *java_random.JavaRandom, biome_id: i32, wx: i32, wz: i32, flower_noise: *const noise_mod.SimplexOctaves) !struct { id: ids.Id, meta: u8 } {
    const b: i32 = if (biome_id >= 128) biome_id - 128 else biome_id;
    if (b == 1) {
        if (flower_noise.eval(@as(f64, @floatFromInt(wx)) / 200.0, @as(f64, @floatFromInt(wz)) / 200.0) < -0.8) {
            const k = try rand.nextIntBound(4);
            return .{ .id = ids.red_flower, .meta = @intCast(4 + k) }; // tulips 4..7
        }
        if (try rand.nextIntBound(3) > 0) {
            const k = try rand.nextIntBound(3);
            return switch (k) {
                0 => .{ .id = ids.red_flower, .meta = 0 }, // poppy
                1 => .{ .id = ids.red_flower, .meta = 3 }, // houstonia
                else => .{ .id = ids.red_flower, .meta = 8 }, // oxeye daisy
            };
        }
        return .{ .id = ids.yellow_flower, .meta = 0 }; // dandelion
    }
    if (try rand.nextIntBound(3) == 0) return .{ .id = ids.yellow_flower, .meta = 0 }; // dandelion (alc.b[0])
    return .{ .id = ids.red_flower, .meta = 0 }; // poppy (alc.a[0])
}

/// Grass (z-loop) tallgrass meta: base 1; taiga family 1/6 fern (2);
/// jungle family 1/4 fern.
fn grassMeta(rand: *java_random.JavaRandom, biome_id: i32) !u8 {
    const b: i32 = if (biome_id >= 128) biome_id - 128 else biome_id;
    switch (b) {
        5, 19, 30, 31, 32, 33 => if (try rand.nextIntBound(5) <= 0) return 2,
        21, 22, 23 => if (try rand.nextIntBound(4) == 0) return 2,
        else => {},
    }
    return 1;
}

/// Generic 64-try flora scatter (`aro` shape): random walk ±8/±4, needs air
/// (+ always-sky overworld short-circuits vanilla's hasNoSky check), soil
/// gate below, then set.
fn scatterFlora(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32, id: ids.Id, meta: u8, soil: enum { grass_dirt, solid, deadbush_soil }) !void {
    var i: i32 = 0;
    while (i < 64) : (i += 1) {
        const x = wx + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        const y = wy + try rand.nextIntBound(4) - try rand.nextIntBound(4);
        const z = wz + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        if (!view.isAir(x, y, z)) continue;
        const below = view.get(x, y - 1, z);
        const ok = switch (soil) {
            .grass_dirt => isSoilGrass(below),
            .solid => isSoilOpaque(below),
            .deadbush_soil => isSoilDeadbush(below),
        };
        if (!ok) continue;
        view.set(x, y, z, id, meta);
    }
}

/// Tall-grass scatter (`asp` shape): sink through air/leaves first (no
/// draws), then 128 tries, air + soil gate, set.
fn scatterTallGrass(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32, meta: u8) !void {
    var y = wy;
    while (y > 0) {
        const id = view.get(wx, y, wz);
        if (id != ids.air and id != ids.leaves and id != ids.leaves2) break;
        y -= 1;
    }
    var i: i32 = 0;
    while (i < 128) : (i += 1) {
        const x = wx + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        const yy = y + try rand.nextIntBound(4) - try rand.nextIntBound(4);
        const z = wz + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        if (!view.isAir(x, yy, z)) continue;
        if (!isSoilGrass(view.get(x, yy - 1, z))) continue;
        view.set(x, yy, z, ids.tallgrass, meta);
    }
}

/// Dead-bush scatter (`ark` shape): downscan past air/leaves, then 4 tries.
fn scatterDeadbush(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32) !void {
    var y = wy;
    while (y > 0) {
        const id = view.get(wx, y, wz);
        if (id != ids.air and id != ids.leaves and id != ids.leaves2) break;
        y -= 1;
    }
    if (y <= 0) return;
    var i: i32 = 0;
    while (i < 4) : (i += 1) {
        const x = wx + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        const yy = y + try rand.nextIntBound(4) - try rand.nextIntBound(4);
        const z = wz + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        if (!view.isAir(x, yy, z)) continue;
        if (!isSoilDeadbush(view.get(x, yy - 1, z))) continue;
        view.set(x, yy, z, ids.deadbush, 0);
    }
}

/// Reed clump (`ash` shape): 20 tries ±4 (y fixed), air + any-of-4-below is
/// water-like, height 2+nextInt(nextInt(3)+1), per-level canStay.
fn reedClump(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32) !void {
    var i: i32 = 0;
    while (i < 20) : (i += 1) {
        const x = wx + try rand.nextIntBound(4) - try rand.nextIntBound(4);
        const z = wz + try rand.nextIntBound(4) - try rand.nextIntBound(4);
        if (!view.isAir(x, wy, z)) continue;
        if (!isWaterLike(view.get(x - 1, wy - 1, z)) and !isWaterLike(view.get(x + 1, wy - 1, z)) and
            !isWaterLike(view.get(x, wy - 1, z - 1)) and !isWaterLike(view.get(x, wy - 1, z + 1))) continue;
        const h = 2 + try rand.nextIntBound(try rand.nextIntBound(3) + 1);
        var k: i32 = 0;
        while (k < h) : (k += 1) {
            if (reedCanStay(view, x, wy + k, z)) view.set(x, wy + k, z, ids.reeds_block, 0);
        }
    }
}

fn reedCanStay(view: *const View, x: i32, y: i32, z: i32) bool {
    const below = view.get(x, y - 1, z);
    if (below == ids.reeds_block) return true;
    if (below != ids.grass and below != ids.dirt and below != ids.sand) return false;
    return isWaterLike(view.get(x - 1, y, z)) or isWaterLike(view.get(x + 1, y, z)) or
        isWaterLike(view.get(x, y, z - 1)) or isWaterLike(view.get(x, y, z + 1));
}

/// Cactus clump (`arh` shape): 10 tries ±8/±4, air, height 1+nextInt(nextInt(3)+1),
/// per-level canStay (sand/cactus below + air neighbors).
fn cactusClump(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32) !void {
    var i: i32 = 0;
    while (i < 10) : (i += 1) {
        const x = wx + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        const y = wy + try rand.nextIntBound(4) - try rand.nextIntBound(4);
        const z = wz + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        if (!view.isAir(x, y, z)) continue;
        const h = 1 + try rand.nextIntBound(try rand.nextIntBound(3) + 1);
        var k: i32 = 0;
        while (k < h) : (k += 1) {
            if (cactusCanStay(view, x, y + k, z)) view.set(x, y + k, z, ids.cactus, 0);
        }
    }
}

fn cactusCanStay(view: *const View, x: i32, y: i32, z: i32) bool {
    const below = view.get(x, y - 1, z);
    if (below != ids.cactus and below != ids.sand) return false;
    if (!view.isAir(x - 1, y, z) or !view.isAir(x + 1, y, z) or
        !view.isAir(x, y, z - 1) or !view.isAir(x, y, z + 1)) return false;
    return true;
}

/// Pumpkin patch (`asg` shape): 64 tries ±8/±4, air + grass below +
/// canPlace, facing = nextInt(4).
fn pumpkinPatch(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32) !void {
    var i: i32 = 0;
    while (i < 64) : (i += 1) {
        const x = wx + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        const y = wy + try rand.nextIntBound(4) - try rand.nextIntBound(4);
        const z = wz + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        if (!view.isAir(x, y, z)) continue;
        if (view.get(x, y - 1, z) != ids.grass) continue;
        // canPlaceBlockAt (pumpkin): below solid-opaque; grass qualifies.
        view.set(x, y, z, ids.pumpkin, @intCast(try rand.nextIntBound(4)));
    }
}

/// Water-lily patch (`aiz` shape with the w-loop downscan done by caller):
/// 10 tries ±8/±4, air, below is water.
fn lilyPatch(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32) !void {
    var i: i32 = 0;
    while (i < 10) : (i += 1) {
        const x = wx + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        const y = wy + try rand.nextIntBound(4) - try rand.nextIntBound(4);
        const z = wz + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        if (!view.isAir(x, y, z)) continue;
        if (!isWaterLike(view.get(x, y - 1, z))) continue;
        view.set(x, y, z, ids.waterlily, 0);
    }
}

/// Downscan for the lily loop (`aia` w-loop): sink while the block below is
/// AIR (vanilla checks `ahb.c`, not opacity — water stops the scan).
fn lilyGroundY(view: *const View, wx: i32, wy: i32, wz: i32) i32 {
    var y = wy;
    while (y > 0 and view.isAir(wx, y - 1, wz)) y -= 1;
    return y;
}

/// Standard ore loop (`aia.a` helper): `count` veins, x/z = base+nextInt16
/// (no +8), y = nextInt(range)+min.
fn oreVein(view: *View, rand: *java_random.JavaRandom, base_x: i32, base_z: i32, count: i32, ore: ids.Id, size: i32, y_min: i32, y_max: i32) !void {
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const nx: i32 = base_x + try rand.nextIntBound(16);
        const ny: i32 = try rand.nextIntBound(y_max - y_min) + y_min;
        const nz: i32 = base_z + try rand.nextIntBound(16);
        try minable(view, rand, nx, ny, nz, ore, size, ids.stone);
    }
}

/// Frozen (snowy) base biomes for the populate snow/ice pass.
fn isFrozenBiome(b: i32) bool {
    return b == 10 or b == 11 or b == 12 or b == 13 or b == 30 or b == 31;
}

pub fn treesPerChunk(biome_id: i32) i32 {
    const b: i32 = if (biome_id >= 128) biome_id - 128 else biome_id;
    return switch (b) {
        1 => -999, // plains
        2 => -999, // desert
        3 => 0, // extreme hills
        4 => 10, // forest
        5 => 10, // taiga
        6 => 2, // swamp
        12 => 0, // ice plains (default 0; spikes are custom, no trees)
        14, 15 => -100, // mushroom
        16 => -999, // beach
        17 => -999, // desert hills
        18 => 10, // forest hills
        19 => 10, // taiga hills
        20 => 3, // extreme hills edge (bl=true)
        21, 22 => 50, // jungle / jungle hills
        23 => 2, // jungle edge
        25 => -999, // stone beach
        26 => -999, // cold beach
        27, 28 => 10, // birch forest / hills
        29 => -999, // roofed forest (custom grid skipped)
        30, 31 => 10, // cold taiga
        32, 33 => 10, // mega taiga
        34 => 3, // extreme hills+ (bl=true)
        35, 36 => 1, // savanna / plateau
        37 => -999, // mesa
        38 => 5, // mesa plateau F (bl2=true)
        39 => -999, // mesa plateau
        else => 0, // ocean, river, hell, sky, frozen, etc.
    };
}

/// Sand/clay/gravel disk counts (F/G/E). Only swamp differs from 3/1/1.
pub fn diskCounts(biome_id: i32) struct { sand: i32, clay: i32, gravel: i32 } {
    const b: i32 = if (biome_id >= 128) biome_id - 128 else biome_id;
    if (b == 6) return .{ .sand = 0, .clay = 1, .gravel = 0 }; // swamp
    return .{ .sand = 3, .clay = 1, .gravel = 1 };
}

pub const TreeKind = enum { oak, birch, spruce, swamp, jungle_oak };

/// Tree type selection per biome (replicates `ahu.a` draws; approximations
/// documented in module header). Returns kind; caller generates.
/// For jungle oak, caller must ALSO draw `nextInt(7)` for height (done in
/// `genJungleOak` wrapper to keep call sites clean).
pub fn selectTree(rand: *java_random.JavaRandom, biome_id: i32) !TreeKind {
    const b: i32 = if (biome_id >= 128) biome_id - 128 else biome_id;
    switch (b) {
        4, 18 => { // forest / hills: 20% birch
            if (try rand.nextIntBound(5) == 0) return .birch;
            return .oak;
        },
        27, 28 => return .birch, // birch forest: always birch, no draw
        5, 19, 30, 31 => { // taiga: nextInt3==0 -> pine else nextInt3 (pine/spruce); all spruce here
            if (try rand.nextIntBound(3) == 0) return .spruce;
            _ = try rand.nextIntBound(3);
            return .spruce;
        },
        32, 33 => { // mega taiga: same shape (aH==2/nextInt13 is dead in vanilla — aH is only 0/1)
            if (try rand.nextIntBound(3) == 0) return .spruce;
            _ = try rand.nextIntBound(3);
            return .spruce;
        },
        6 => return .swamp, // swamp: always aso, no draw
        21, 22, 23 => { // jungle: big/arp/arz/jungle-oak
            if (try rand.nextIntBound(10) == 0) return .oak; // big->oak approx
            if (try rand.nextIntBound(2) == 0) return .oak; // arp->oak approx
            if (b != 23) { // non-edge: 1/3 arz
                if (try rand.nextIntBound(3) == 0) return .oak; // arz->oak approx
            }
            return .jungle_oak;
        },
        35, 36 => { // savanna: 1/5 oak, 4/5 acacia->oak (one draw either way)
            _ = try rand.nextIntBound(5);
            return .oak;
        },
        3, 20, 34 => { // extreme hills: 1/3 spruce else base select (10% big->oak, 90% oak)
            if (try rand.nextIntBound(3) == 0) return .spruce;
            _ = try rand.nextIntBound(10);
            return .oak;
        },
        else => { // base: 10% big->oak, 90% oak (draw consumed)
            _ = try rand.nextIntBound(10);
            return .oak;
        },
    }
}

// ---------------------------------------------------------------------------
// Chunk populate (ores + disks + trees) with populate-style seeding.
// ---------------------------------------------------------------------------

/// Seed a chunk's decorator RNG (matches `aqz.populate` mixing; structures/
// lakes/dungeons that precede ores in vanilla are SKIPPED, so positions
/// differ from vanilla — documented in module header).
pub fn seedForChunk(rand: *java_random.JavaRandom, world_seed: i64, cx: i32, cz: i32) void {
    rand.setSeed(world_seed);
    const l: i64 = @divTrunc(rand.nextLong(), 2) * 2 + 1;
    const l1: i64 = @divTrunc(rand.nextLong(), 2) * 2 + 1;
    rand.setSeed(cx *% l +% cz *% l1 ^ world_seed);
}

/// Run one chunk's populate into `view` (48x48 or larger, covering base).
/// `heights` is a MUTABLE scratch (sx*sz): recomputed after lakes/dungeons
/// (vanilla decorate reads post-lake heights), then reused by every phase.
/// `biome_id` is the chunk's biome (at center+8, voronoi).
/// `win_bio` is the per-column voronoi biome over the populate window
/// (base+8..base+23, row-major `dx*16+dz`): the snow/ice tail gates each
/// column on its own biome (vanilla `World.r`/`World.e` check the column's
/// biome temperature < 0.15), NOT on the chunk-center biome. Gating the
/// whole window on one biome freezes ocean/beach columns whenever any
/// frozen biome sits in the window — an 8-wide ice square spilling across
/// the border (vanilla leaves those columns water).
/// `flower_noise` is the plains tulip-patch octave (seed 2345, 1 octave).
/// Writes outside `view` are dropped by View bounds checks.
///
/// Vanilla order (`aqz.populate` + `aia` decorate), jar-verified:
/// structures (detection only — placement is the next phase, zero populate
/// draws) → water lake → lava lake → dungeons → ores → disks → trees →
/// bigshroom → flora → grass → deadbush → lilies → shrooms → reeds →
/// pumpkin → cactus → springs → exHills extras → snow/ice.
pub fn populateOne(
    view: *View,
    heights: []i32, // sx*sz, same layout as blocks (x*sz+z)
    rand: *java_random.JavaRandom,
    flower_noise: *const noise_mod.SimplexOctaves,
    base_x: i32, // chunk base world x (cx*16)
    base_z: i32,
    biome_id: i32,
    win_bio: [256]i32,
) !void {
    const b: i32 = if (biome_id >= 128) biome_id - 128 else biome_id;
    const p = decorParams(b);
    // -- structures (MapGen): detection only for now (own ChunkRand streams,
    // zero populate draws). Full block placement is the next phase; chunks
    // with structures nearby will shift ore positions then (documented).
    // Vanilla also suppresses both lakes near strongholds; assumed absent
    // (no stronghold detection yet — same phase as placement).
    // -- surface lakes.
    if (biome_id != 2 and biome_id != 17 and try rand.nextIntBound(4) == 0) {
        const wx: i32 = base_x + try rand.nextIntBound(16) + 8;
        const wy: i32 = try rand.nextIntBound(256);
        const wz: i32 = base_z + try rand.nextIntBound(16) + 8;
        _ = try lakeGen(view, rand, wx, wy, wz, ids.water, isFrozenBiome(b));
    }
    if (try rand.nextIntBound(8) == 0) {
        const wx: i32 = base_x + try rand.nextIntBound(16) + 8;
        const wy: i32 = try rand.nextIntBound(try rand.nextIntBound(248) + 8);
        const wz: i32 = base_z + try rand.nextIntBound(16) + 8;
        if (wy < 63 or try rand.nextIntBound(10) == 0) {
            _ = try lakeGen(view, rand, wx, wy, wz, ids.lava, isFrozenBiome(b));
        }
    }
    // -- dungeons (8 attempts; loot draws deferred with placement — blocks only).
    {
        var i: i32 = 0;
        while (i < 8) : (i += 1) {
            const wx: i32 = base_x + try rand.nextIntBound(16) + 8;
            const wy: i32 = try rand.nextIntBound(256);
            const wz: i32 = base_z + try rand.nextIntBound(16) + 8;
            _ = try dungeonGen(view, rand, wx, wy, wz);
        }
    }
    // Post-lake/dungeon heights for everything below (vanilla reads live heights).
    computeHeights(view, heights);
    // Ores (universal, no +8 offset).
    try oreVein(view, rand, base_x, base_z, 20, ids.dirt, 32, 0, 256);
    try oreVein(view, rand, base_x, base_z, 10, ids.gravel, 32, 0, 256);
    try oreVein(view, rand, base_x, base_z, 20, ids.coal_ore, 16, 0, 128);
    try oreVein(view, rand, base_x, base_z, 20, ids.iron_ore, 8, 0, 64);
    try oreVein(view, rand, base_x, base_z, 2, ids.gold_ore, 8, 0, 32);
    try oreVein(view, rand, base_x, base_z, 8, ids.redstone_ore, 7, 0, 16);
    try oreVein(view, rand, base_x, base_z, 1, ids.diamond_ore, 7, 0, 16);
    // Lapis (triangular via b()).
    {
        var i: i32 = 0;
        while (i < 1) : (i += 1) {
            const nx: i32 = base_x + try rand.nextIntBound(16);
            const ny: i32 = try rand.nextIntBound(16) + try rand.nextIntBound(16);
            const nz: i32 = base_z + try rand.nextIntBound(16);
            // NOTE: no +8 offset (matches `a()` helper, unlike trees/disks).
            try minable(view, rand, nx, ny, nz, ids.lapis_ore, 6, ids.stone);
        }
    }
    // Sand / clay / gravel disks (+8 offset, wy ~= i() ~= top+1, documented).
    const disks = diskCounts(biome_id);
    var i: i32 = 0;
    while (i < disks.sand) : (i += 1) {
        const wx: i32 = base_x + try rand.nextIntBound(16) + 8;
        const wz: i32 = base_z + try rand.nextIntBound(16) + 8;
        const wy = heightAt(view, heights, wx, wz) + 1;
        _ = try sandDisk(view, rand, wx, wy, wz, ids.sand, 7);
    }
    i = 0;
    while (i < disks.clay) : (i += 1) {
        const wx: i32 = base_x + try rand.nextIntBound(16) + 8;
        const wz: i32 = base_z + try rand.nextIntBound(16) + 8;
        const wy = heightAt(view, heights, wx, wz) + 1;
        _ = try clayDisk(view, rand, wx, wy, wz);
    }
    i = 0;
    while (i < disks.gravel) : (i += 1) {
        const wx: i32 = base_x + try rand.nextIntBound(16) + 8;
        const wz: i32 = base_z + try rand.nextIntBound(16) + 8;
        const wy = heightAt(view, heights, wx, wz) + 1;
        _ = try sandDisk(view, rand, wx, wy, wz, ids.gravel, 6);
    }
    // Trees (+8 offset, base wy = f() = top+1, per-biome count + selection).
    var n5: i32 = p.trees;
    if (try rand.nextIntBound(10) == 0) n5 += 1;
    var t: i32 = 0;
    while (t < n5) : (t += 1) {
        const wx: i32 = base_x + try rand.nextIntBound(16) + 8;
        const wz: i32 = base_z + try rand.nextIntBound(16) + 8;
        const wy = heightAt(view, heights, wx, wz) + 1;
        const kind = try selectTree(rand, biome_id);
        switch (kind) {
            .oak => _ = try oakTree(view, rand, wx, wy, wz, 4, 0, 0, false, false),
            .birch => _ = try birchTree(view, rand, wx, wy, wz, false),
            .spruce => _ = try spruceTree(view, rand, wx, wy, wz),
            .swamp => _ = try swampTree(view, rand, wx, wy, wz),
            .jungle_oak => {
                const h_extra: i32 = try rand.nextIntBound(7);
                _ = try oakTree(view, rand, wx, wy, wz, 4 + h_extra, 3, 3, true, true);
            },
        }
    }
    // Big mushrooms (H; mushroom isles only in practice).
    i = 0;
    while (i < p.bigshroom) : (i += 1) {
        const wx: i32 = base_x + try rand.nextIntBound(16) + 8;
        const wz: i32 = base_z + try rand.nextIntBound(16) + 8;
        const wy = heightAt(view, heights, wx, wz) + 1;
        _ = try bigMushroom(view, rand, wx, wy, wz);
    }
    // Flowers (y): wy = nextInt(f + 32) with f = top + 1.
    i = 0;
    while (i < p.flowers) : (i += 1) {
        const wx: i32 = base_x + try rand.nextIntBound(16) + 8;
        const wz: i32 = base_z + try rand.nextIntBound(16) + 8;
        const f = heightAt(view, heights, wx, wz) + 1;
        const wy = try rand.nextIntBound(@intCast(f + 32));
        const ft = try flowerType(rand, biome_id, wx, wz, flower_noise);
        try scatterFlora(view, rand, wx, wy, wz, ft.id, ft.meta, .grass_dirt);
    }
    // Tall grass (z): wy = nextInt(f * 2), per-biome meta.
    i = 0;
    while (i < p.grass) : (i += 1) {
        const wx: i32 = base_x + try rand.nextIntBound(16) + 8;
        const wz: i32 = base_z + try rand.nextIntBound(16) + 8;
        const f = heightAt(view, heights, wx, wz) + 1;
        const wy = try rand.nextIntBound(@intCast(f * 2));
        const meta = try grassMeta(rand, biome_id);
        try scatterTallGrass(view, rand, wx, wy, wz, meta);
    }
    // Dead bushes (A): wy = nextInt(f * 2).
    i = 0;
    while (i < p.deadbush) : (i += 1) {
        const wx: i32 = base_x + try rand.nextIntBound(16) + 8;
        const wz: i32 = base_z + try rand.nextIntBound(16) + 8;
        const f = heightAt(view, heights, wx, wz) + 1;
        const wy = try rand.nextIntBound(@intCast(f * 2));
        try scatterDeadbush(view, rand, wx, wy, wz);
    }
    // Water lilies (w): wy = nextInt(f * 2), then sink through air only.
    i = 0;
    while (i < p.lilies) : (i += 1) {
        const wx: i32 = base_x + try rand.nextIntBound(16) + 8;
        const wz: i32 = base_z + try rand.nextIntBound(16) + 8;
        const f = heightAt(view, heights, wx, wz) + 1;
        const wy0 = try rand.nextIntBound(@intCast(f * 2));
        const wy = lilyGroundY(view, wx, wy0, wz);
        try lilyPatch(view, rand, wx, wy, wz);
    }
    // Mushrooms (B loop + two standalone patches; brown=q, red=r).
    // Every patch attempt draws wy = nextInt(f * 2).
    i = 0;
    while (i < p.shrooms) : (i += 1) {
        if (try rand.nextIntBound(4) == 0) {
            const wx: i32 = base_x + try rand.nextIntBound(16) + 8;
            const wz: i32 = base_z + try rand.nextIntBound(16) + 8;
            const f = heightAt(view, heights, wx, wz) + 1;
            try scatterFlora(view, rand, wx, try rand.nextIntBound(@intCast(f * 2)), wz, ids.brown_mushroom, 0, .solid);
        }
        if (try rand.nextIntBound(8) == 0) {
            const wx: i32 = base_x + try rand.nextIntBound(16) + 8;
            const wz: i32 = base_z + try rand.nextIntBound(16) + 8;
            const f = heightAt(view, heights, wx, wz) + 1;
            try scatterFlora(view, rand, wx, try rand.nextIntBound(@intCast(f * 2)), wz, ids.red_mushroom, 0, .solid);
        }
    }
    if (try rand.nextIntBound(4) == 0) {
        const wx: i32 = base_x + try rand.nextIntBound(16) + 8;
        const wz: i32 = base_z + try rand.nextIntBound(16) + 8;
        const f = heightAt(view, heights, wx, wz) + 1;
        try scatterFlora(view, rand, wx, try rand.nextIntBound(@intCast(f * 2)), wz, ids.brown_mushroom, 0, .solid);
    }
    if (try rand.nextIntBound(8) == 0) {
        const wx: i32 = base_x + try rand.nextIntBound(16) + 8;
        const wz: i32 = base_z + try rand.nextIntBound(16) + 8;
        const f = heightAt(view, heights, wx, wz) + 1;
        try scatterFlora(view, rand, wx, try rand.nextIntBound(@intCast(f * 2)), wz, ids.red_mushroom, 0, .solid);
    }
    // Reeds (C loop + unconditional 10 attempts; wy = nextInt(f * 2)).
    i = 0;
    while (i < p.reeds) : (i += 1) {
        const wx: i32 = base_x + try rand.nextIntBound(16) + 8;
        const wz: i32 = base_z + try rand.nextIntBound(16) + 8;
        const f = heightAt(view, heights, wx, wz) + 1;
        const wy = try rand.nextIntBound(@intCast(f * 2));
        try reedClump(view, rand, wx, wy, wz);
    }
    i = 0;
    while (i < 10) : (i += 1) {
        const wx: i32 = base_x + try rand.nextIntBound(16) + 8;
        const wz: i32 = base_z + try rand.nextIntBound(16) + 8;
        const f = heightAt(view, heights, wx, wz) + 1;
        const wy = try rand.nextIntBound(@intCast(f * 2));
        try reedClump(view, rand, wx, wy, wz);
    }
    // Pumpkin patch (1/32): wy = nextInt(f * 2).
    if (try rand.nextIntBound(32) == 0) {
        const wx: i32 = base_x + try rand.nextIntBound(16) + 8;
        const wz: i32 = base_z + try rand.nextIntBound(16) + 8;
        const f = heightAt(view, heights, wx, wz) + 1;
        const wy = try rand.nextIntBound(@intCast(f * 2));
        try pumpkinPatch(view, rand, wx, wy, wz);
    }
    // Cactus (D): wy = nextInt(f * 2).
    i = 0;
    while (i < p.cactus) : (i += 1) {
        const wx: i32 = base_x + try rand.nextIntBound(16) + 8;
        const wz: i32 = base_z + try rand.nextIntBound(16) + 8;
        const f = heightAt(view, heights, wx, wz) + 1;
        const wy = try rand.nextIntBound(@intCast(f * 2));
        try cactusClump(view, rand, wx, wy, wz);
    }
    // Underground springs (always on, gated by `I` which is always true in
    // vanilla biomes; water 50x then lava 20x).
    i = 0;
    while (i < 50) : (i += 1) {
        const wx: i32 = base_x + try rand.nextIntBound(16) + 8;
        const wy: i32 = try rand.nextIntBound(try rand.nextIntBound(248) + 8);
        const wz: i32 = base_z + try rand.nextIntBound(16) + 8;
        _ = try springGen(view, rand, wx, wy, wz, ids.flowing_water);
    }
    i = 0;
    while (i < 20) : (i += 1) {
        const wx: i32 = base_x + try rand.nextIntBound(16) + 8;
        const wy: i32 = try rand.nextIntBound(try rand.nextIntBound(try rand.nextIntBound(240) + 8) + 8);
        const wz: i32 = base_z + try rand.nextIntBound(16) + 8;
        _ = try springGen(view, rand, wx, wy, wz, ids.flowing_lava);
    }
    // Extreme-hills extras (after base decorate, like `aid`).
    if (p.ex_hills) {
        // Emerald singles: 3+nextInt(6), y=nextInt(28)+4, below must be stone.
        const n_em = 3 + try rand.nextIntBound(6);
        var e: i32 = 0;
        while (e < n_em) : (e += 1) {
            const nx: i32 = base_x + try rand.nextIntBound(16);
            const ny: i32 = try rand.nextIntBound(28) + 4;
            const nz: i32 = base_z + try rand.nextIntBound(16);
            if (view.get(nx, ny - 1, nz) == ids.stone) view.set(nx, ny, nz, ids.emerald_ore, 0);
        }
        // Silverfish veins: 7x minable(monster_egg, 8), y=nextInt(64).
        var ss: i32 = 0;
        while (ss < 7) : (ss += 1) {
            const nx: i32 = base_x + try rand.nextIntBound(16);
            const ny: i32 = try rand.nextIntBound(64);
            const nz: i32 = base_z + try rand.nextIntBound(16);
            try minable(view, rand, nx, ny, nz, ids.monster_egg, 8, ids.stone);
        }
    }
    // Snow + ice (behavioral port of the populate tail: per-column frozen
    // check, matching vanilla `World.r`/`World.e` which gate each column on
    // its own biome temperature < 0.15; light checks skipped — populate runs
    // before lighting, same as vanilla).
    {
        var dx: i32 = 0;
        while (dx < 16) : (dx += 1) {
            var dz: i32 = 0;
            while (dz < 16) : (dz += 1) {
                if (!isFrozenBiome(win_bio[@as(usize, @intCast(dx * 16 + dz))])) continue;
                const wx: i32 = base_x + 8 + dx;
                const wz: i32 = base_z + 8 + dz;
                const top = heightAt(view, heights, wx, wz);
                const tid = view.get(wx, top, wz);
                if (isWaterLike(tid)) {
                    view.set(wx, top, wz, ids.ice, 0);
                } else if (view.isAir(wx, top + 1, wz) and isSoilOpaque(tid)) {
                    view.set(wx, top + 1, wz, ids.snow_layer, 0);
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// 3x3 decorate: isolated per-chunk populates merged in fixed order.
// ---------------------------------------------------------------------------

/// Surface height lookup (world coords via view). Scans the column LIVE
/// (topmost non-air), matching vanilla `ahb.f` which reads the live world
/// per attempt — flowers/trees/grass placed earlier in the same populate
/// raise the surface for later attempts. (A stale snapshot reused across
/// phases shifts every downstream `nextInt` bound and breaks parity.)
fn heightAt(view: *const View, heights: []const i32, wx: i32, wz: i32) i32 {
    _ = heights;
    const lx = wx - view.ox;
    const lz = wz - view.oz;
    if (lx < 0 or lz < 0) return SEA_Y;
    const ux: usize = @intCast(lx);
    const uz: usize = @intCast(lz);
    if (ux >= view.sx or uz >= view.sz) return SEA_Y;
    var y: i32 = 255;
    while (y >= 0) : (y -= 1) {
        const i = (ux * view.sz + uz) * 256 + @as(usize, @intCast(y));
        if (view.blocks[i] != ids.air) return y;
    }
    return 0;
}

pub const SEA_Y: i32 = 63;

/// Compute surface heights (topmost non-air) for a view. Layout matches
/// blocks: heights[x*sz+z].
pub fn computeHeights(view: *const View, heights: []i32) void {
    var x: usize = 0;
    while (x < view.sx) : (x += 1) {
        var z: usize = 0;
        while (z < view.sz) : (z += 1) {
            var top: i32 = 0;
            var y: i32 = 255;
            while (y >= 0) : (y -= 1) {
                const i = (x * view.sz + z) * 256 + @as(usize, @intCast(y));
                if (view.blocks[i] != ids.air) {
                    top = y;
                    break;
                }
            }
            heights[x * view.sz + z] = top;
        }
    }
}

/// Decorate center chunk (cx,cz) in `view` (must cover (cx-1..cx+1) chunks,
/// i.e. 48x48 with ox=(cx-1)*16). `biomeAt` returns voronoi biome id at
/// world (x,z). Heights are recomputed per run after lakes/dungeons.
pub fn decorateCenter(
    view: *View,
    world_seed: i64,
    cx: i32,
    cz: i32,
    chain: *genlayer_mod.Chain,
    root_voronoi: u32,
    scratch: std.mem.Allocator,
) !void {
    const n = view.sx * 256 * view.sz;
    const base_blocks = try scratch.alloc(ids.Id, n);
    defer scratch.free(base_blocks);
    const base_metas = try scratch.alloc(u8, n);
    defer scratch.free(base_metas);
    @memcpy(base_blocks, view.blocks[0..n]);
    @memcpy(base_metas, view.metas[0..n]);
    const work_blocks = try scratch.alloc(ids.Id, n);
    defer scratch.free(work_blocks);
    const work_metas = try scratch.alloc(u8, n);
    defer scratch.free(work_metas);
    var work = View{ .blocks = work_blocks, .metas = work_metas, .ox = view.ox, .oz = view.oz, .sx = view.sx, .sz = view.sz };
    var rand = java_random.JavaRandom.init(0);
    // Plains tulip-patch octave (vanilla `new awl(new Random(2345), 1)`).
    var flower_rand = java_random.JavaRandom.init(2345);
    var flower_noise = try noise_mod.SimplexOctaves.init(scratch, &flower_rand, 1);
    defer flower_noise.deinit();
    const run_heights = try scratch.alloc(i32, view.sx * view.sz);
    defer scratch.free(run_heights);
    // Per-column voronoi for the snow/ice tail (one fetch for the whole
    // 48x48 view; each run slices its 16x16 populate window). The tail
    // gates every column on its own biome (vanilla `World.r`/`World.e`);
    // a single center biome per window would freeze warm columns.
    const bio48 = try scratch.alloc(i32, view.sx * view.sz);
    defer scratch.free(bio48);
    try chain.getInts(scratch, root_voronoi, view.ox, view.oz, view.sx, view.sz, bio48);
    // Fixed order: 8 neighbors (sorted dz,dx) then center last.
    var order: [9]struct { dx: i32, dz: i32 } = undefined;
    var k: usize = 0;
    var dz: i32 = -1;
    while (dz <= 1) : (dz += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            if (dx == 0 and dz == 0) continue;
            order[k] = .{ .dx = dx, .dz = dz };
            k += 1;
        }
    }
    order[8] = .{ .dx = 0, .dz = 0 };
    for (order) |o| {
        const nx = cx + o.dx;
        const nz = cz + o.dz;
        @memcpy(work_blocks, base_blocks);
        @memcpy(work_metas, base_metas);
        seedForChunk(&rand, world_seed, nx, nz);
        const biome = try biomeAt(chain, root_voronoi, scratch, nx * 16 + 8, nz * 16 + 8);
        // Populate window [nx*16+8, nx*16+23]^2 in view-local coords;
        // out-of-view cells fall back to the center biome (their writes
        // are dropped by View bounds checks anyway).
        var win_bio: [256]i32 = undefined;
        const lx0: i32 = nx * 16 + 8 - view.ox;
        const lz0: i32 = nz * 16 + 8 - view.oz;
        var wdx: usize = 0;
        while (wdx < 16) : (wdx += 1) {
            var wdz: usize = 0;
            while (wdz < 16) : (wdz += 1) {
                const lx: i32 = lx0 + @as(i32, @intCast(wdx));
                const lz: i32 = lz0 + @as(i32, @intCast(wdz));
                win_bio[wdx * 16 + wdz] = if (lx >= 0 and lz >= 0 and lx < @as(i32, @intCast(view.sx)) and lz < @as(i32, @intCast(view.sz)))
                    bio48[@as(usize, @intCast(lx)) * view.sz + @as(usize, @intCast(lz))]
                else
                    biome;
            }
        }
        try populateOne(&work, run_heights, &rand, &flower_noise, nx * 16, nz * 16, biome, win_bio);
        var ii: usize = 0;
        while (ii < n) : (ii += 1) {
            if (work_blocks[ii] != base_blocks[ii]) view.blocks[ii] = work_blocks[ii];
            if (work_metas[ii] != base_metas[ii]) view.metas[ii] = work_metas[ii];
        }
    }
    // Post-merge floater sweep: a later run's lake can undercut an earlier
    // run's flora (see sweepFloaters). Center chunk only; neighbors sweep
    // themselves in their own decorateCenter runs.
    sweepFloaters(view, cx, cz);
}

/// Post-merge floater sweep for soil-gated plants (counterpart to gen's
/// snow sweep): the 3x3 merge can undercut one run's flora when a later
/// run's lake carves water/air below it (vanilla runs on one live world,
/// so this never floats). Only removes what vanilla placement gates
/// forbid — every soil set below mirrors the scatter gate exactly, so
/// legitimate placements are never touched. Sweeps the center chunk only
/// (each chunk's own decorateCenter run sweeps itself).
pub fn sweepFloaters(view: *View, cx: i32, cz: i32) void {
    var lx: i32 = 0;
    while (lx < 16) : (lx += 1) {
        var lz: i32 = 0;
        while (lz < 16) : (lz += 1) {
            const wx = cx * 16 + lx;
            const wz = cz * 16 + lz;
            var y: i32 = 1;
            while (y < 256) : (y += 1) {
                const id = view.get(wx, y, wz);
                const keep = switch (id) {
                    .tallgrass, .yellow_flower, .red_flower => isSoilGrass(view.get(wx, y - 1, wz)),
                    .deadbush => isSoilDeadbush(view.get(wx, y - 1, wz)),
                    .brown_mushroom, .red_mushroom => isSoilOpaque(view.get(wx, y - 1, wz)),
                    .waterlily => isWaterLike(view.get(wx, y - 1, wz)),
                    .pumpkin => view.get(wx, y - 1, wz) == ids.grass,
                    .reeds_block => reedCanStay(view, wx, y, wz),
                    .cactus => cactusCanStay(view, wx, y, wz),
                    else => true,
                };
                if (!keep) view.set(wx, y, wz, ids.air, 0);
            }
        }
    }
}

fn biomeAt(chain: *genlayer_mod.Chain, root: u32, scratch: std.mem.Allocator, wx: i32, wz: i32) !i32 {
    var one: [1]i32 = undefined;
    try chain.getInts(scratch, root, wx, wz, 1, 1, &one);
    return one[0];
}

test "populateOne matches JVM (seed 42 chunk 0,0 forest)" {
    const alloc = std.testing.allocator;
    // 48x48 view, ox=-16 (matches harness). Terrain: stone<70, grass at 70.
    const S: usize = 48;
    const blocks = try alloc.alloc(ids.Id, S * 256 * S);
    defer alloc.free(blocks);
    const metas = try alloc.alloc(u8, S * 256 * S);
    defer alloc.free(metas);
    @memset(blocks, ids.air);
    @memset(metas, 0);
    for (0..S) |x| {
        for (0..S) |z| {
            for (0..70) |y| {
                blocks[(x * S + z) * 256 + y] = ids.stone;
            }
            blocks[(x * S + z) * 256 + 70] = ids.grass;
        }
    }
    var view = View{ .blocks = blocks, .metas = metas, .ox = -16, .oz = -16, .sx = S, .sz = S };
    const heights = try alloc.alloc(i32, S * S);
    defer alloc.free(heights);
    var frand = java_random.JavaRandom.init(2345);
    var fnoise = try noise_mod.SimplexOctaves.init(alloc, &frand, 1);
    defer fnoise.deinit();
    var rand = java_random.JavaRandom.init(0);
    seedForChunk(&rand, 42, 0, 0);
    // Forest biome id 4.
    try populateOne(&view, heights, &rand, &fnoise, 0, 0, 4, [_]i32{4} ** 256);
    var crc: i64 = 0;
    var counts: [256]usize = [_]usize{0} ** 256;
    var wx: i32 = 0;
    while (wx < 16) : (wx += 1) {
        var wy: i32 = 0;
        while (wy < 256) : (wy += 1) {
            var wz: i32 = 0;
            while (wz < 16) : (wz += 1) {
                const id = view.get(wx, wy, wz);
                crc = crc *% 31 +% @as(i64, wire.toWire(id)); // JVM goldens are wire ids
                counts[@intFromEnum(id)] += 1; // canonical block ids always < 256
            }
        }
    }
    // Full-populate JVM golden (VGold harness: real 1.7.10 populate +
    // decorate on identical synthetic terrain, seed 42 chunk (0,0)).
    try std.testing.expectEqual(@as(i64, 321941256375464097), crc);
    try std.testing.expectEqual(@as(usize, 47243), counts[@intFromEnum(ids.air)]);
    try std.testing.expectEqual(@as(usize, 17790), counts[@intFromEnum(ids.stone)]);
    try std.testing.expectEqual(@as(usize, 254), counts[@intFromEnum(ids.grass)]);
    try std.testing.expectEqual(@as(usize, 26), counts[@intFromEnum(ids.dirt)]);
    try std.testing.expectEqual(@as(usize, 0), counts[@intFromEnum(ids.gravel)]);
    try std.testing.expectEqual(@as(usize, 0), counts[@intFromEnum(ids.gold_ore)]);
    try std.testing.expectEqual(@as(usize, 51), counts[@intFromEnum(ids.iron_ore)]);
    try std.testing.expectEqual(@as(usize, 37), counts[@intFromEnum(ids.coal_ore)]);
    try std.testing.expectEqual(@as(usize, 0), counts[@intFromEnum(ids.diamond_ore)]);
    try std.testing.expectEqual(@as(usize, 4), counts[@intFromEnum(ids.lapis_ore)]);
    try std.testing.expectEqual(@as(usize, 14), counts[@intFromEnum(ids.redstone_ore)]);
    try std.testing.expectEqual(@as(usize, 10), counts[@intFromEnum(ids.log)]);
    try std.testing.expectEqual(@as(usize, 107), counts[@intFromEnum(ids.leaves)]);
    try std.testing.expectEqual(@as(usize, 0), counts[@intFromEnum(ids.red_flower)]);
}

test "populateOne plains matches JVM (seed 42, no trees)" {
    const alloc = std.testing.allocator;
    const S: usize = 48;
    const blocks = try alloc.alloc(ids.Id, S * 256 * S);
    defer alloc.free(blocks);
    const metas = try alloc.alloc(u8, S * 256 * S);
    defer alloc.free(metas);
    @memset(blocks, ids.air);
    @memset(metas, 0);
    for (0..S) |x| {
        for (0..S) |z| {
            for (0..70) |y| {
                blocks[(x * S + z) * 256 + y] = ids.stone;
            }
            blocks[(x * S + z) * 256 + 70] = ids.grass;
        }
    }
    var view = View{ .blocks = blocks, .metas = metas, .ox = -16, .oz = -16, .sx = S, .sz = S };
    const heights = try alloc.alloc(i32, S * S);
    defer alloc.free(heights);
    computeHeights(&view, heights);
    var frand2 = java_random.JavaRandom.init(2345);
    var fnoise2 = try noise_mod.SimplexOctaves.init(alloc, &frand2, 1);
    defer fnoise2.deinit();
    var rand = java_random.JavaRandom.init(0);
    seedForChunk(&rand, 42, 0, 0);
    // Plains biome id 1 (x=-999, no trees, but nextInt10 still drawn).
    try populateOne(&view, heights, &rand, &fnoise2, 0, 0, 1, [_]i32{1} ** 256);
    var crc: i64 = 0;
    var counts: [256]usize = [_]usize{0} ** 256;
    var wx: i32 = 0;
    while (wx < 16) : (wx += 1) {
        var wy: i32 = 0;
        while (wy < 256) : (wy += 1) {
            var wz: i32 = 0;
            while (wz < 16) : (wz += 1) {
                const id = view.get(wx, wy, wz);
                crc = crc *% 31 +% @as(i64, wire.toWire(id)); // JVM goldens are wire ids
                counts[@intFromEnum(id)] += 1; // canonical block ids always < 256
            }
        }
    }
    // Full-populate JVM golden (VGold harness: real 1.7.10 populate +
    // decorate on identical synthetic terrain, seed 42 chunk (0,0)).
    try std.testing.expectEqual(@as(i64, 3297028603511917183), crc);
    try std.testing.expectEqual(@as(usize, 47324), counts[@intFromEnum(ids.air)]);
    try std.testing.expectEqual(@as(usize, 17790), counts[@intFromEnum(ids.stone)]);
    try std.testing.expectEqual(@as(usize, 256), counts[@intFromEnum(ids.grass)]);
    try std.testing.expectEqual(@as(usize, 24), counts[@intFromEnum(ids.dirt)]);
    try std.testing.expectEqual(@as(usize, 0), counts[@intFromEnum(ids.gravel)]);
    try std.testing.expectEqual(@as(usize, 0), counts[@intFromEnum(ids.gold_ore)]);
    try std.testing.expectEqual(@as(usize, 51), counts[@intFromEnum(ids.iron_ore)]);
    try std.testing.expectEqual(@as(usize, 37), counts[@intFromEnum(ids.coal_ore)]);
    try std.testing.expectEqual(@as(usize, 0), counts[@intFromEnum(ids.diamond_ore)]);
    try std.testing.expectEqual(@as(usize, 4), counts[@intFromEnum(ids.lapis_ore)]);
    try std.testing.expectEqual(@as(usize, 36), counts[@intFromEnum(ids.tallgrass)]);
    try std.testing.expectEqual(@as(usize, 14), counts[@intFromEnum(ids.redstone_ore)]);
}

test "sweepFloaters removes only support-less plants" {
    const alloc = std.testing.allocator;
    const S: usize = 16;
    const blocks = try alloc.alloc(ids.Id, S * 256 * S);
    defer alloc.free(blocks);
    const metas = try alloc.alloc(u8, S * 256 * S);
    defer alloc.free(metas);
    @memset(blocks, ids.stone);
    @memset(metas, 0);
    var view = View{ .blocks = blocks, .metas = metas, .ox = 0, .oz = 0, .sx = S, .sz = S };
    const at = struct {
        fn f(v: *View, x: i32, y: i32, z: i32, below: ids.Id, plant: ids.Id) void {
            v.set(x, y - 1, z, below, 0);
            v.set(x, y, z, plant, 0);
        }
    }.f;
    at(&view, 0, 70, 0, .water, .tallgrass); // floating -> air
    at(&view, 1, 70, 0, .dirt, .tallgrass); // kept
    at(&view, 2, 70, 0, .air, .yellow_flower); // floating -> air
    at(&view, 3, 70, 0, .sand, .deadbush); // kept
    at(&view, 4, 70, 0, .grass, .red_mushroom); // kept (solid soil)
    at(&view, 5, 70, 0, .grass, .pumpkin); // kept
    at(&view, 6, 70, 0, .stone, .pumpkin); // no grass below -> air
    at(&view, 7, 70, 0, .water, .waterlily); // kept
    at(&view, 8, 70, 0, .dirt, .waterlily); // sinks -> air
    at(&view, 9, 70, 0, .dirt, .reeds_block); // no adjacent water -> air
    at(&view, 10, 70, 0, .grass, .cactus); // wrong soil -> air
    view.set(11, 70, 1, ids.water, 0); // adjacent water for the kept reed
    at(&view, 11, 70, 0, .dirt, .reeds_block); // kept
    view.set(12, 70, 2, ids.sand, 0);
    view.set(11, 71, 2, ids.air, 0);
    view.set(13, 71, 2, ids.air, 0);
    view.set(12, 71, 1, ids.air, 0);
    view.set(12, 71, 3, ids.air, 0);
    view.set(12, 71, 2, ids.cactus, 0); // kept (sand + air neighbors)

    sweepFloaters(&view, 0, 0);

    try std.testing.expectEqual(ids.air, view.get(0, 70, 0));
    try std.testing.expectEqual(ids.tallgrass, view.get(1, 70, 0));
    try std.testing.expectEqual(ids.air, view.get(2, 70, 0));
    try std.testing.expectEqual(ids.deadbush, view.get(3, 70, 0));
    try std.testing.expectEqual(ids.red_mushroom, view.get(4, 70, 0));
    try std.testing.expectEqual(ids.pumpkin, view.get(5, 70, 0));
    try std.testing.expectEqual(ids.air, view.get(6, 70, 0));
    try std.testing.expectEqual(ids.waterlily, view.get(7, 70, 0));
    try std.testing.expectEqual(ids.air, view.get(8, 70, 0));
    try std.testing.expectEqual(ids.air, view.get(9, 70, 0));
    try std.testing.expectEqual(ids.air, view.get(10, 70, 0));
    try std.testing.expectEqual(ids.reeds_block, view.get(11, 70, 0));
    try std.testing.expectEqual(ids.cactus, view.get(12, 71, 2));
}

test "snow/ice tail gates per column, not per window" {
    // Regression: the old code gated the whole 16x16 populate window on
    // the chunk-center biome, freezing ocean/beach water into an ice
    // square whenever a frozen biome sat in the window (vanilla checks
    // each column's own biome temperature < 0.15 via World.r/World.e).
    const alloc = std.testing.allocator;
    const S: usize = 48;
    const blocks = try alloc.alloc(ids.Id, S * 256 * S);
    defer alloc.free(blocks);
    const metas = try alloc.alloc(u8, S * 256 * S);
    defer alloc.free(metas);
    @memset(blocks, ids.air);
    @memset(metas, 0);
    // Ocean world: stone to 70 everywhere; water at 71 on the west half
    // of the window, bare stone at 71 on the east half.
    for (0..S) |x| {
        for (0..S) |z| {
            for (0..71) |y| blocks[(x * S + z) * 256 + y] = ids.stone;
        }
    }
    // Window for base (0,0) is wx 8..23, wz 8..23 (view ox=-16,oz=-16).
    var dx: i32 = 0;
    while (dx < 16) : (dx += 1) {
        var dz: i32 = 0;
        while (dz < 16) : (dz += 1) {
            const wx = 8 + dx;
            const wz = 8 + dz;
            const lx: usize = @intCast(wx + 16);
            const lz: usize = @intCast(wz + 16);
            if (dx < 8) {
                blocks[(lx * S + lz) * 256 + 71] = ids.water;
            } else {
                blocks[(lx * S + lz) * 256 + 71] = ids.stone;
            }
        }
    }
    var view = View{ .blocks = blocks, .metas = metas, .ox = -16, .oz = -16, .sx = S, .sz = S };
    const heights = try alloc.alloc(i32, S * S);
    defer alloc.free(heights);
    computeHeights(&view, heights);
    var frand = java_random.JavaRandom.init(2345);
    var fnoise = try noise_mod.SimplexOctaves.init(alloc, &frand, 1);
    defer fnoise.deinit();
    var rand = java_random.JavaRandom.init(0);
    seedForChunk(&rand, 42, 0, 0);
    // Window biomes: west half ocean (0, warm), east half ice plains
    // (12, frozen). Center biome is frozen on purpose: the old
    // whole-window gate would freeze the western water too.
    var win_bio: [256]i32 = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        win_bio[i] = if (i / 16 < 8) 0 else 12;
    }
    try populateOne(&view, heights, &rand, &fnoise, 0, 0, 12, win_bio);
    // Warm columns: water untouched, no snow anywhere above.
    dx = 0;
    while (dx < 8) : (dx += 1) {
        var dz: i32 = 0;
        while (dz < 16) : (dz += 1) {
            const wx = 8 + dx;
            const wz = 8 + dz;
            try std.testing.expectEqual(ids.water, view.get(wx, 71, wz));
            try std.testing.expectEqual(ids.air, view.get(wx, 72, wz));
        }
    }
    // Frozen stone columns: snow_layer on top (proves the tail ran).
    var snow_n: usize = 0;
    dx = 8;
    while (dx < 16) : (dx += 1) {
        var dz: i32 = 0;
        while (dz < 16) : (dz += 1) {
            const wx = 8 + dx;
            const wz = 8 + dz;
            if (view.get(wx, 72, wz) == ids.snow_layer) snow_n += 1;
            try std.testing.expect(view.get(wx, 71, wz) != ids.ice);
        }
    }
    try std.testing.expect(snow_n > 100);
}

