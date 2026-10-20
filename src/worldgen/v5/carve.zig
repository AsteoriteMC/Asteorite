//! 1.7.10 cave + ravine carvers (MapGenCaves/MapGenRavine).
//!
//! Ports aqw/aqs/aqx from CFR decompiles of the official server jar.
//! Walks carve ellipsoids through the block array (stone/dirt/grass only;
//! lava below y=10, no carving through water). Goldens are live JVM outputs
//! (CarveDump harness with real walk/entry methods).

const std = @import("std");
const java_random = @import("../rng/java_random.zig");
const genlayer = @import("genlayer.zig");
const biome = @import("biome.zig");
const surface_mod = @import("surface.zig");
const ids = @import("../../ids.zig");

pub const RANGE: i32 = 8;
pub const LAVA_Y: i32 = 10;

/// qh trig table: (float)sin(i * 2π / 65536), built via f64 then narrowed.
/// Probed bit-exact against the live jar (Zig f32 @sin is NOT accurate
/// enough here — wrong by ~1e-7 at some indices; f64 path matches exactly).
pub fn buildTrigTable() [65536]f32 {
    var t: [65536]f32 = undefined;
    for (&t, 0..) |*v, i| {
        v.* = @floatCast(@sin(@as(f64, @floatFromInt(i)) * 2.0 * std.math.pi / 65536.0));
    }
    return t;
}

fn trigIdx(f: f32, add: f32) usize {
    // NOTE: (int) truncates toward zero; inputs are in-range by construction.
    const idx: i32 = @intFromFloat(f * 10430.378 + add);
    return @as(usize, @as(u32, @bitCast(idx)) & 0xFFFF);
}

pub fn qhSin(tbl: *const [65536]f32, f: f32) f32 {
    return tbl[trigIdx(f, 0.0)];
}

pub fn qhCos(tbl: *const [65536]f32, f: f32) f32 {
    return tbl[trigIdx(f, 16384.0)];
}

fn floorD(d: f64) i32 {
    const t: i32 = @intFromFloat(d);
    return if (d < @as(f64, @floatFromInt(t))) t - 1 else t;
}

pub const Carver = struct {
    rand: java_random.JavaRandom,
    trig: [65536]f32,
    chain: *genlayer.Chain,
    roots_voronoi: u32,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, chain: *genlayer.Chain, roots_voronoi: u32) Carver {
        return .{
            .rand = java_random.JavaRandom.init(0),
            .trig = buildTrigTable(),
            .chain = chain,
            .roots_voronoi = roots_voronoi,
            .alloc = alloc,
        };
    }

    /// Clamp-lerp qh.b (shared with shaper blend; duplicated: no import cycle).
    fn cle(a: f64, b: f64, t: f64) f64 {
        if (t < 0.0) return a;
        if (t > 1.0) return b;
        return a + (b - a) * t;
    }

    /// Base dispatcher (aqx.a): 17x17 neighbor chunks, each reseeded.
    /// scratch arena for voronoi lookups during grass-top replacement.
    pub fn carveChunk(self: *Carver, scratch: std.mem.Allocator, cx: i32, cz: i32, world_seed: i64, blocks: *[65536]u16) !void {
        self.rand.setSeed(worldSeed(world_seed));
        const l = self.rand.nextLong();
        const l2 = self.rand.nextLong();
        var di: i32 = cx - RANGE;
        while (di <= cx + RANGE) : (di += 1) {
            var dj: i32 = cz - RANGE;
            while (dj <= cz + RANGE) : (dj += 1) {
                const neighbor_seed = @as(i64, di) *% l ^ @as(i64, dj) *% l2 ^ worldSeed(world_seed);
                // NOTE: caves and ravines are separate objects in vanilla
                // (aqw vs aqs), each with its own Random reseeded per
                // neighbor. Single shared rand here must reseed before each.
                self.rand.setSeed(neighbor_seed);
                try self.cavesEntry(scratch, di, dj, cx, cz, blocks);
                // DEBUG: ravines disabled
                //self.rand.setSeed(neighbor_seed);
                //try self.ravineEntry(scratch, di, dj, cx, cz, blocks);
            }
        }
    }

    fn worldSeed(s: i64) i64 {
        return s;
    }

    // ------------------------------------------------------------ caves
    fn cavesEntry(self: *Carver, scratch: std.mem.Allocator, n: i32, n2: i32, n3: i32, n4: i32, blocks: *[65536]u16) !void {
        var n5 = try self.rand.nextIntBound(try self.rand.nextIntBound(try self.rand.nextIntBound(15) + 1) + 1);
        if (try self.rand.nextIntBound(7) != 0) n5 = 0;
        var i: i32 = 0;
        while (i < n5) : (i += 1) {
            const d: f64 = @as(f64, @floatFromInt(n * 16 + try self.rand.nextIntBound(16)));
            const d2: f64 = @floatFromInt(try self.rand.nextIntBound(try self.rand.nextIntBound(120) + 8));
            const d3: f64 = @as(f64, @floatFromInt(n2 * 16 + try self.rand.nextIntBound(16)));
            var n6: i32 = 1;
            if (try self.rand.nextIntBound(4) == 0) {
                try self.caveWalk(scratch, self.rand.nextLong(), n3, n4, blocks, d, d2, d3);
                n6 += try self.rand.nextIntBound(4);
            }
            var j: i32 = 0;
            while (j < n6) : (j += 1) {
                const f: f32 = self.rand.nextFloat() * 3.1415927 * 2.0;
                const f2: f32 = (self.rand.nextFloat() - 0.5) * 2.0 / 8.0;
                var f3: f32 = self.rand.nextFloat() * 2.0 + self.rand.nextFloat();
                if (try self.rand.nextIntBound(10) == 0) {
                    f3 *= self.rand.nextFloat() * self.rand.nextFloat() * 3.0 + 1.0;
                }
                try self.caveWalk13(scratch, self.rand.nextLong(), n3, n4, blocks, d, d2, d3, f3, f, f2, 0, 0, 1.0);
            }
        }
    }

    fn caveWalk(self: *Carver, scratch: std.mem.Allocator, seed: i64, n: i32, n2: i32, blocks: *[65536]u16, d: f64, d2: f64, d3: f64) !void {
        // NOTE: f comes from the dispatcher RNG (this.b), seed passes through
        // unchanged (CFR-verified: 7-arg overload uses this.b.nextFloat and
        // forwards l directly; the 13-arg method creates Random(l)).
        const f: f32 = 1.0 + self.rand.nextFloat() * 6.0;
        try self.caveWalk13(scratch, seed, n, n2, blocks, d, d2, d3, f, 0.0, 0.0, -1, -1, 0.5);
    }

    fn caveWalk13(self: *Carver, scratch: std.mem.Allocator, seed: i64, tx: i32, tz: i32, blocks: *[65536]u16, d_in: f64, d2_in: f64, d3_in: f64, f_in: f32, f2_in: f32, f3_in: f32, n3_in: i32, n4_in: i32, d4: f64) !void {
        var r = java_random.JavaRandom.init(seed);
        var dd = d_in;
        var dd2 = d2_in;
        var dd3 = d3_in;
        const ff = f_in;
        var ff2 = f2_in;
        var ff3 = f3_in;
        var nn3 = n3_in;
        var n4m = n4_in;
        const d5: f64 = @as(f64, @floatFromInt(tx * 16 + 8));
        const d6: f64 = @as(f64, @floatFromInt(tz * 16 + 8));
        var f4: f32 = 0.0;
        var f5: f32 = 0.0;
        if (n4m <= 0) {
            const lim: i32 = RANGE * 16 - 16;
            n4m = lim - try r.nextIntBound(@divFloor(lim, 4));
        }
        // NOTE: is_room==1 marks the initial big room (one segment, then stop).
        var is_room: i32 = 0;
        if (nn3 == -1) {
            nn3 = @divFloor(n4m, 2);
            is_room = 1;
        }
        const n6 = try r.nextIntBound(@divFloor(n4m, 2)) + @divFloor(n4m, 4);
        const fast = try r.nextIntBound(6) == 0;
        while (nn3 < n4m) : (nn3 += 1) {
            // NOTE: angle math in f32 exactly as vanilla (table sin/cos).
            const ang: f32 = @as(f32, @floatFromInt(nn3)) * 3.1415927 / @as(f32, @floatFromInt(n4m));
            const d7: f64 = 1.5 + @as(f64, qhSin(&self.trig, ang) * ff * 1.0);
            const d8: f64 = d7 * d4;
            const f6 = qhCos(&self.trig, ff3);
            const f7 = qhSin(&self.trig, ff3);
            dd += @as(f64, qhCos(&self.trig, ff2) * f6);
            dd2 += @as(f64, f7);
            dd3 += @as(f64, qhSin(&self.trig, ff2) * f6);
            ff3 = if (fast) ff3 * 0.92 else ff3 * 0.7;
            ff3 += f5 * 0.1;
            ff2 += f4 * 0.1;
            f5 *= 0.9;
            f4 *= 0.75;
            f5 += (r.nextFloat() - r.nextFloat()) * r.nextFloat() * 2.0;
            f4 += (r.nextFloat() - r.nextFloat()) * r.nextFloat() * 4.0;
            if (is_room == 0 and nn3 == n6 and ff > 1.0 and n4m > 0) {
                // NOTE: Java evaluates args left-to-right: seed (nextLong)
                // BEFORE width (nextFloat). Swapped order here once poisoned
                // every branched tunnel (proven by WalkAllLog seed diff).
                const seed1 = r.nextLong();
                const w1 = r.nextFloat() * 0.5 + 0.5;
                try self.caveWalk13(scratch, seed1, tx, tz, blocks, dd, dd2, dd3, w1, ff2 - 1.5707964, ff3 / 3.0, nn3, n4m, 1.0);
                const seed2 = r.nextLong();
                const w2 = r.nextFloat() * 0.5 + 0.5;
                try self.caveWalk13(scratch, seed2, tx, tz, blocks, dd, dd2, dd3, w2, ff2 + 1.5707964, ff3 / 3.0, nn3, n4m, 1.0);
                return;
            }
            if (is_room != 0 or try r.nextIntBound(4) != 0) {
                const d9 = dd - d5;
                const d10 = dd3 - d6;
                const d11: f64 = @floatFromInt(n4m - nn3);
                const d12: f64 = @as(f64, (ff + 2.0) + 16.0);
                if (d9 * d9 + d10 * d10 - d11 * d11 > d12 * d12) return;
                if (self.overlaps(dd, dd3, d5, d6, d7)) {
                    const stop = try self.carveCells(scratch, tx, tz, blocks, dd, dd2, dd3, d7, d8, is_room, .cave, null);
                    if (stop) break;
                }
            }
        }
    }

    fn overlaps(_: *Carver, d: f64, d3: f64, d5: f64, d6: f64, d7: f64) bool {
        return !(d < d5 - 16.0 - d7 * 2.0 or d3 < d6 - 16.0 - d7 * 2.0 or d > d5 + 16.0 + d7 * 2.0 or d3 > d6 + 16.0 + d7 * 2.0);
    }

    const CaveKind = enum { cave, ravine };

    /// Water check + ellipsoid carve for one segment. Returns true when the
    /// caller must stop after this segment (initial-room single pass that
    /// actually carved). Ravines pass their width table; caves pass null.
    fn carveCells(self: *Carver, scratch: std.mem.Allocator, tx: i32, tz: i32, blocks: *[65536]u16, d: f64, d2: f64, d3: f64, d7: f64, d8: f64, is_room: i32, kind: CaveKind, width: ?[256]f32) !bool {
        const n9: i32 = @max(0, floorD(d - d7) - tx * 16 - 1);
        const n10: i32 = @min(16, floorD(d + d7) - tx * 16 + 1);
        const n11: i32 = @max(1, floorD(d2 - d8) - 1);
        const n12: i32 = @min(248, floorD(d2 + d8) + 1);
        const n13: i32 = @max(0, floorD(d3 - d7) - tz * 16 - 1);
        const n14: i32 = @min(16, floorD(d3 + d7) - tz * 16 + 1);
        var bl3 = false;
        var nx = n9;
        while (!bl3 and nx < n10) : (nx += 1) {
            var nz = n13;
            while (!bl3 and nz < n14) : (nz += 1) {
                // NOTE: j starts one ABOVE the range; edge columns scan every
                // cell, interior columns check top+bottom only then jump.
                var jy = n12 + 1;
                while (!bl3 and jy >= n11 - 1) : (jy -= 1) {
                    if (jy < 0 or jy >= 256) continue;
                    const cell: usize = @as(usize, @intCast(nx * 16 + nz)) * 256 + @as(usize, @intCast(jy));
                    const id = blocks[cell];
                    if (id == ids.flowing_water or id == ids.water) bl3 = true;
                    if (jy == n11 - 1 or nx == n9 or nx == n10 - 1 or nz == n13 or nz == n14 - 1) continue;
                    jy = n11;
                }
            }
        }
        if (bl3) return false;
        nx = n9;
        while (nx < n10) : (nx += 1) {
            const d13: f64 = (@as(f64, @floatFromInt(nx + tx * 16)) + 0.5 - d) / d7;
            var nz = n13;
            while (nz < n14) : (nz += 1) {
                const d14: f64 = (@as(f64, @floatFromInt(nz + tz * 16)) + 0.5 - d3) / d7;
                // NOTE: index starts one ABOVE the y range; each iteration
                // reads/writes then steps down (deliberate vanilla off-by-one
                // between the tested y (i) and the touched cell (i+1)).
                var n15: i64 = @as(i64, nx * 16 + nz) * 256 + n12;
                var bl4 = false;
                if (!(d13 * d13 + d14 * d14 < 1.0)) continue;
                var iy = n12 - 1;
                while (iy >= n11) : (iy -= 1) {
                    const d15: f64 = (@as(f64, @floatFromInt(iy)) + 0.5 - d2) / d8;
                    const inside = switch (kind) {
                        .cave => d15 > -0.7 and d13 * d13 + d15 * d15 + d14 * d14 < 1.0,
                        .ravine => blk: {
                            const w = width.?[@as(usize, @intCast(iy))];
                            break :blk (d13 * d13 + d14 * d14) * @as(f64, w) + d15 * d15 / 6.0 < 1.0;
                        },
                    };
                    if (inside) {
                        const cell: usize = @intCast(n15);
                        const cur = blocks[cell];
                        if (cur == 2) bl4 = true;
                        if (cur == 1 or cur == 3 or cur == 2) {
                            if (iy < 10) {
                                // NOTE: caves place still lava (11), ravines
                                // place flowing lava (10) — CFR-verified.
                                blocks[cell] = if (kind == .cave) 11 else 10;
                            } else {
                                blocks[cell] = 0;
                                if (bl4 and blocks[@intCast(n15 - 1)] == 3) {
                                    blocks[@intCast(n15 - 1)] = self.topFor(scratch, nx + tx * 16, nz + tz * 16);
                                }
                            }
                        }
                    }
                    n15 -= 1;
                }
            }
        }
        return is_room != 0;
    }

    /// Top block for the grass-top replacement (voronoi biome -> TOP256).
    fn topFor(self: *Carver, scratch: std.mem.Allocator, wx: i32, wz: i32) u16 {
        var one: [1]i32 = undefined;
        self.chain.getInts(scratch, self.roots_voronoi, wx, wz, 1, 1, &one) catch return 2;
        const id: usize = @as(usize, @intCast(@as(u32, @bitCast(one[0])) & 255));
        return biome.TOP256[id];
    }

    fn ravineEntry(self: *Carver, scratch: std.mem.Allocator, n: i32, n2: i32, n3: i32, n4: i32, blocks: *[65536]u16) !void {
        if (try self.rand.nextIntBound(50) != 0) return;
        const d: f64 = @as(f64, @floatFromInt(n * 16 + try self.rand.nextIntBound(16)));
        const d2: f64 = @floatFromInt(try self.rand.nextIntBound(try self.rand.nextIntBound(40) + 8) + 20);
        const d3: f64 = @as(f64, @floatFromInt(n2 * 16 + try self.rand.nextIntBound(16)));
        // NOTE: n5 is const 1 in vanilla (single system per trigger).
        const f: f32 = self.rand.nextFloat() * 3.1415927 * 2.0;
        const f2: f32 = (self.rand.nextFloat() - 0.5) * 2.0 / 8.0;
        const f3: f32 = (self.rand.nextFloat() * 2.0 + self.rand.nextFloat()) * 2.0;
        try self.ravineWalk13(scratch, self.rand.nextLong(), n3, n4, blocks, d, d2, d3, f3, f, f2, 0, 0, 3.0);
    }

    fn ravineWalk13(self: *Carver, scratch: std.mem.Allocator, seed: i64, tx: i32, tz: i32, blocks: *[65536]u16, d_in: f64, d2_in: f64, d3_in: f64, f_in: f32, f2_in: f32, f3_in: f32, n3_in: i32, n4_in: i32, d4: f64) !void {
        var r = java_random.JavaRandom.init(seed);
        var dd = d_in;
        var dd2 = d2_in;
        var dd3 = d3_in;
        const ff = f_in;
        var ff2 = f2_in;
        var ff3 = f3_in;
        var nn3 = n3_in;
        var n4m = n4_in;
        const d5: f64 = @as(f64, @floatFromInt(tx * 16 + 8));
        const d6: f64 = @as(f64, @floatFromInt(tz * 16 + 8));
        var f4: f32 = 0.0;
        var f5: f32 = 0.0;
        if (n4m <= 0) {
            const lim: i32 = RANGE * 16 - 16;
            n4m = lim - try r.nextIntBound(@divFloor(lim, 4));
        }
        var is_room: i32 = 0;
        if (nn3 == -1) {
            nn3 = @divFloor(n4m, 2);
            is_room = 1;
        }
        // NOTE: ravine width table (256 entries, f32).
        var wtab: [256]f32 = undefined;
        {
            var f6: f32 = 1.0;
            for (&wtab, 0..) |*w, wi| {
                if (wi == 0 or try r.nextIntBound(3) == 0) {
                    f6 = 1.0 + r.nextFloat() * r.nextFloat() * 1.0;
                }
                w.* = f6 * f6;
            }
        }
        while (nn3 < n4m) : (nn3 += 1) {
            const ang: f32 = @as(f32, @floatFromInt(nn3)) * 3.1415927 / @as(f32, @floatFromInt(n4m));
            var d7: f64 = 1.5 + @as(f64, qhSin(&self.trig, ang) * ff * 1.0);
            var d8: f64 = d7 * d4;
            d7 *= @as(f64, r.nextFloat()) * 0.25 + 0.75;
            d8 *= @as(f64, r.nextFloat()) * 0.25 + 0.75;
            const f6 = qhCos(&self.trig, ff3);
            const f7 = qhSin(&self.trig, ff3);
            dd += @as(f64, qhCos(&self.trig, ff2) * f6);
            dd2 += @as(f64, f7);
            dd3 += @as(f64, qhSin(&self.trig, ff2) * f6);
            ff3 *= 0.7;
            ff3 += f5 * 0.05;
            ff2 += f4 * 0.05;
            f5 *= 0.8;
            f4 *= 0.5;
            f5 += (r.nextFloat() - r.nextFloat()) * r.nextFloat() * 2.0;
            f4 += (r.nextFloat() - r.nextFloat()) * r.nextFloat() * 4.0;
            if (is_room != 0 or try r.nextIntBound(4) != 0) {
                const d9 = dd - d5;
                const d10 = dd3 - d6;
                const d11: f64 = @floatFromInt(n4m - nn3);
                const d12: f64 = @as(f64, (ff + 2.0) + 16.0);
                if (d9 * d9 + d10 * d10 - d11 * d11 > d12 * d12) return;
                if (self.overlaps(dd, dd3, d5, d6, d7)) {
                    if (try self.carveCells(scratch, tx, tz, blocks, dd, dd2, dd3, d7, d8, is_room, .ravine, wtab)) break;
                }
            }
        }
    }
};







test "trig table matches jar (spot checks)" {
    const t = buildTrigTable();
    try std.testing.expectEqual(@as(u32, 0x3F800000), @as(u32, @bitCast(t[16384])));
    try std.testing.expectEqual(@as(u32, 0xBF800000), @as(u32, @bitCast(t[49152])));
    try std.testing.expectEqual(@as(u32, 0x3DC40C83), @as(u32, @bitCast(t[1000])));
}


test "grass-top path matches JVM (synthetic dirt+grass, wide walk)" {
    const alloc = std.testing.allocator;
    var built = try genlayer.Chain.buildDefault(alloc, 42, false);
    defer built.chain.deinit();
    var carver = Carver.init(alloc, &built.chain, built.roots[1]);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var blocks: [65536]u16 = undefined;
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..256) |y| {
                blocks[x * 4096 + z * 256 + y] = if (y < 60) 1 else if (y < 68) 3 else if (y == 68) 2 else 0;
            }
        }
    }
    try carver.caveWalk13(arena.allocator(), 999, 0, 0, &blocks, 8.0, 68.0, 8.0, 10.0, 0.0, 0.0, 0, 100, 1.0);
    // JVM golden: col(8,8) dirt to 66, grass at 67 (was dirt), air above.
    for (60..67) |y| try std.testing.expectEqual(@as(u16, 3), blocks[8 * 4096 + 8 * 256 + y]);
    try std.testing.expectEqual(@as(u16, 2), blocks[8 * 4096 + 8 * 256 + 67]);
    for (68..76) |y| try std.testing.expectEqual(@as(u16, 0), blocks[8 * 4096 + 8 * 256 + y]);
    // Far corner untouched (walk is localized).
    for (60..68) |y| try std.testing.expectEqual(@as(u16, 3), blocks[0 * 4096 + 0 * 256 + y]);
    try std.testing.expectEqual(@as(u16, 2), blocks[0 * 4096 + 0 * 256 + 68]);
    // Full-array crc vs jvm_grass.txt.
    var crc: i64 = 0;
    for (blocks) |v| crc = crc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, -3331385501468235747), crc);
}
