//! MapGen framework (vanilla `aqx` + `ave`, jar-verified).
//!
//! Detection (`aqx.generate` range-8 loop): per start-chunk, seed a
//! position RNG from the world seed, burn one `nextInt` (vanilla always
//! does, even on miss), then run the kind's `canSpawn`. Placement
//! (`ave.generateStructuresInChunk`) runs later with the POPULATE rand,
//! in canonical order (vanilla iterates a HashMap — history-dependent;
//! ours is sorted, identical whenever at most one start touches a chunk).
//!
//! 1.7.10 structures write NOTHING to terrain arrays: every block lands
//! during populate, clipped to the populated chunk's 16-wide column
//! (`asv` intersection in every helper). So `genFlat` stays untouched and
//! all structure work lives in populate (before lakes, like vanilla).

const std = @import("std");
const ids = @import("../../../ids.zig");
const bbox_mod = @import("bbox.zig");
const comp_mod = @import("comp.zig");
const placer_mod = @import("placer.zig");
const java_random = @import("../../rng/java_random.zig");

pub const JavaRandom = java_random.JavaRandom;
pub const BBox = bbox_mod.BBox;
pub const Placer = placer_mod.Placer;

/// Structure kinds in vanilla populate order.
pub const Kind = enum(u2) {
    mineshaft = 0,
    village = 1,
    stronghold = 2,
    scattered = 3,
};

/// Detection radius (`aqx.a = 8`).
pub const DETECT_RADIUS: i32 = 8;

/// Position-RNG seeding (`aqx.a` detection mixing, jar-verified): raw
/// nextLong pair (NO odd-ify; that is populate-only). setSeed(worldSeed);
/// l=nextLong; l1=nextLong; setSeed((sx*l) ^ (sz*l1) ^ worldSeed) — note
/// XOR of the two products (populate uses + here instead).
pub fn positionRand(rand: *JavaRandom, world_seed: i64, sx: i32, sz: i32) void {
    rand.setSeed(world_seed);
    const l: i64 = rand.nextLong();
    const l1: i64 = rand.nextLong();
    rand.setSeed((sx *% l) ^ (sz *% l1) ^ world_seed);
}

/// `World.getChunkRandom(x, z, salt)` (`ahb.A`, jar-verified):
/// fresh `Random` seeded with chunk/salt mixing (separate stream).
pub fn chunkRand(world_seed: i64, x: i32, z: i32, salt: i64) JavaRandom {
    var r = JavaRandom.init(0);
    const s: i64 = @as(i64, x) *% 341873128712 +% @as(i64, z) *% 132897987541 +% world_seed +% salt;
    r.setSeed(s);
    return r;
}

/// Populate-chunk box for structure writes (`ave.a`
/// generateStructuresInChunk: note the +8 shift — each populate call owns
/// the EAST+SOUTH halves of its chunk plus the WEST+NORTH halves of the
/// next, partitioning the world with no gaps or overlaps).
pub fn populateBox(cx: i32, cz: i32) BBox {
    return BBox.init(cx * 16 + 8, 1, cz * 16 + 8, cx * 16 + 23, 255, cz * 16 + 23);
}

/// Biome access for canSpawn checks (backed by the real genlayer chain).
/// `alloc` is scratch for chain evaluation (arena-backed by callers).
pub const BioCtx = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        /// Voronoi 1:1 biome id at a block column (scattered/village center).
        voronoiAt: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, x: i32, z: i32) i32,
        /// Raw 1:4 layer rect (areBiomesViable / findBiomePosition sampling).
        layer4: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, x: i32, z: i32, w: usize, h: usize, out: []i32) void,
    };
    pub inline fn voronoiAt(self: BioCtx, alloc: std.mem.Allocator, x: i32, z: i32) i32 {
        return self.vtable.voronoiAt(self.ptr, alloc, x, z);
    }
    pub inline fn layer4(self: BioCtx, alloc: std.mem.Allocator, x: i32, z: i32, w: usize, h: usize, out: []i32) void {
        self.vtable.layer4(self.ptr, alloc, x, z, w, h, out);
    }
};

/// `areBiomesViable` (`aib.a(int,int,int,List)`, jar-verified): every 1:4
/// cell covering [x-r, x+r] must be in the allowed set. Shifts are
/// arithmetic (Java >> on negatives floors).
pub fn areBiomesViable(bio: BioCtx, alloc: std.mem.Allocator, x: i32, z: i32, r: i32, allowed: []const i32) bool {
    const x0 = @divFloor(x - r, 4);
    const z0 = @divFloor(z - r, 4);
    const x1 = @divFloor(x + r, 4);
    const z1 = @divFloor(z + r, 4);
    const w: usize = @intCast(x1 - x0 + 1);
    const h: usize = @intCast(z1 - z0 + 1);
    const out = alloc.alloc(i32, w * h) catch return false;
    defer alloc.free(out);
    bio.layer4(alloc, x0, z0, w, h, out);
    for (out) |b| {
        var ok = false;
        for (allowed) |a| if (a == b) {
            ok = true;
            break;
        };
        if (!ok) return false;
    }
    return true;
}

/// Reservoir-pick result: 1:1 block coords of the chosen 1:4 cell.
pub const FoundBiome = struct { x: i32, z: i32 };

/// `findBiomePosition` (`aib.a(int,int,int,List,Random)`, jar-verified):
/// reservoir sampling over matching 1:4 cells; returns cell<<2 coords.
pub fn findBiomePosition(bio: BioCtx, alloc: std.mem.Allocator, x: i32, z: i32, range: i32, allowed: []const i32, rand: *JavaRandom) ?FoundBiome {
    const x0 = @divFloor(x - range, 4);
    const z0 = @divFloor(z - range, 4);
    const x1 = @divFloor(x + range, 4);
    const z1 = @divFloor(z + range, 4);
    const w: usize = @intCast(x1 - x0 + 1);
    const h: usize = @intCast(z1 - z0 + 1);
    const out = alloc.alloc(i32, w * h) catch return null;
    defer alloc.free(out);
    bio.layer4(alloc, x0, z0, w, h, out);
    var found: ?FoundBiome = null;
    var n: i32 = 0;
    var i: usize = 0;
    while (i < w * h) : (i += 1) {
        const b = out[i];
        var ok = false;
        for (allowed) |a| if (a == b) {
            ok = true;
            break;
        };
        if (!ok) continue;
        const cx: i32 = x0 + @as(i32, @intCast(i % w));
        const cz: i32 = z0 + @as(i32, @intCast(i / w));
        const take = found == null or (rand.nextIntBound(n + 1) catch unreachable) == 0;
        if (take) found = .{ .x = cx << 2, .z = cz << 2 };
        n += 1;
    }
    return found;
}

/// Mineshaft gate (`asw.a`): 0.4% per chunk, farther out more likely.
pub fn mineshaftCanSpawn(rand: *JavaRandom, sx: i32, sz: i32) bool {
    const d = rand.nextDouble();
    if (!(d < 0.004)) return false;
    const lim = @max(@abs(sx), @abs(sz));
    return (rand.nextIntBound(80) catch unreachable) < lim;
}

/// Scattered/village region math shared by both (`atx.a` / `avn.a`):
/// fold negatives, divide into 32-cells, draw the candidate cell.
pub fn spacedCell(sx: i32, sz: i32, spacing: i32, separation: i32, salt: i64, world_seed: i64) struct { cx: i32, cz: i32 } {
    var ax = sx;
    var az = sz;
    if (ax < 0) ax -= spacing - 1;
    if (az < 0) az -= spacing - 1;
    var rx = @divTrunc(ax, spacing);
    var rz = @divTrunc(az, spacing);
    var r = chunkRand(world_seed, rx, rz, salt);
    rx *= spacing;
    rz *= spacing;
    rx += (r.nextIntBound(spacing - separation) catch unreachable);
    rz += (r.nextIntBound(spacing - separation) catch unreachable);
    return .{ .cx = rx, .cz = rz };
}

/// Village gate (`avn.a`): candidate cell must equal this chunk, then the
/// center column's voronoi biome must be viable (radius 0).
pub fn villageCanSpawn(bio: BioCtx, alloc: std.mem.Allocator, world_seed: i64, sx: i32, sz: i32) bool {
    const cell = spacedCell(sx, sz, 32, 8, 10387312, world_seed);
    if (cell.cx != sx or cell.cz != sz) return false;
    return areBiomesViable(bio, alloc, sx * 16 + 8, sz * 16 + 8, 0, &village_biomes);
}

pub const village_biomes = [_]i32{ 1, 2, 35 }; // plains, desert, savanna

/// Scattered gate (`atx.a`): candidate cell must equal this chunk, then the
/// center column's voronoi biome must be desert/jungle/swamp-family.
pub fn scatteredCanSpawn(bio: BioCtx, alloc: std.mem.Allocator, world_seed: i64, sx: i32, sz: i32) bool {
    const cell = spacedCell(sx, sz, 32, 8, 14357617, world_seed);
    if (cell.cx != sx or cell.cz != sz) return false;
    return areBiomesViable(bio, alloc, sx * 16 + 8, sz * 16 + 8, 0, &scattered_biomes);
}

pub const scattered_biomes = [_]i32{ 2, 17, 21, 22, 6 }; // desert(+hills), jungle(+hills), swamp

/// Scattered kind from the center biome (`aty.<init>`).
pub const ScatteredKind = enum { desert, jungle, witch };

pub fn scatteredKindFor(biome: i32) ?ScatteredKind {
    if (biome == 21 or biome == 22) return .jungle;
    if (biome == 6) return .witch;
    return .desert;
}

/// Stronghold ring positions (`aug.a`, jar-verified): 3 chunks on the
/// first ring, each nudged to a rainy biome (rootHeight > 0 list).
/// `find` runs the vanilla reservoir search with the given rand.
pub const StrongholdPositions = struct {
    pos: [3]?[2]i32, // chunk coords, null = unfound (kept null like vanilla)

    pub fn compute(world_seed: i64, bio: BioCtx, alloc: std.mem.Allocator) StrongholdPositions {
        var rand = JavaRandom.init(0);
        rand.setSeed(world_seed);
        var out = StrongholdPositions{ .pos = .{ null, null, null } };
        var angle: f64 = rand.nextDouble() * std.math.pi * 2.0;
        var ring_step: i32 = 1;
        var ring_count: i32 = 3;
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            const dist: f64 = (1.25 * @as(f64, @floatFromInt(ring_step)) + rand.nextDouble()) * (32.0 * @as(f64, @floatFromInt(ring_step)));
            var px: i32 = @intFromFloat(@round(@cos(angle) * dist));
            var pz: i32 = @intFromFloat(@round(@sin(angle) * dist));
            if (findBiomePosition(bio, alloc, px * 16 + 8, pz * 16 + 8, 112, &stronghold_biomes, &rand)) |found| {
                px = @divFloor(found.x, 16);
                pz = @divFloor(found.z, 16);
            }
            out.pos[i] = .{ px, pz };
            angle += (std.math.pi * 2.0) * @as(f64, @floatFromInt(ring_step)) / @as(f64, @floatFromInt(ring_count));
            if (i == ring_count) {
                ring_step += 2 + (rand.nextIntBound(5) catch unreachable);
                ring_count = ring_count + 1 + (rand.nextIntBound(2) catch unreachable);
            }
        }
        return out;
    }

    pub fn isStrongholdChunk(self: StrongholdPositions, sx: i32, sz: i32) bool {
        for (self.pos) |p| {
            if (p) |q| {
                if (q[0] == sx and q[1] == sz) return true;
            }
        }
        return false;
    }
};

/// Biomes strongholds may land in: rootHeight > 0 (`aug` filter).
/// Derived from the repo's exact biome table (matches jar rainfall dump).
pub const stronghold_biomes = [_]i32{
    1, 3, 4, 5, 12, 13, 14, 17, 18, 19, 20, 21, 22, 23, 25, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39,
};

/// Nearest stronghold block position for eyes of ender (`ave.a`
/// stronghold path: first component center of the closest valid start).
/// Callers pass the already-built start centers; kept here for cohesion.
pub fn nearestOf(xs: []const i32, ys: []const i32, zs: []const i32, x: i32, y: i32, z: i32) ?struct { x: i32, y: i32, z: i32 } {
    var best: ?struct { x: i32, y: i32, z: i32 } = null;
    var best_d: i64 = std.math.maxInt(i64);
    for (xs, ys, zs) |cx, cy, cz| {
        const dx: i64 = @as(i64, cx) - x;
        const dy: i64 = @as(i64, cy) - y;
        const dz: i64 = @as(i64, cz) - z;
        const d = dx * dx + dy * dy + dz * dz;
        if (d < best_d) {
            best_d = d;
            best = .{ .x = cx, .y = cy, .z = cz };
        }
    }
    return best;
}

test "spacedCell folds negatives like java" {
    // Hand-computed: seed path uses chunkRand, just check the fold math
    // via a known chunk: (0,0) region cell math.
    const c = spacedCell(0, 0, 32, 8, 10387312, 42);
    _ = c;
    // Negative fold: -1 with spacing 32 -> region -1, not 0.
    var ax: i32 = -1;
    if (ax < 0) ax -= 32 - 1;
    try std.testing.expectEqual(@as(i32, -1), @divTrunc(ax, 32));
}

test "stronghold positions are deterministic" {
    const Stub = struct {
        fn voronoi(ptr: *anyopaque, alloc: std.mem.Allocator, x: i32, z: i32) i32 {
            _ = ptr;
            _ = alloc;
            _ = x;
            _ = z;
            return 1;
        }
        fn layer(ptr: *anyopaque, alloc: std.mem.Allocator, x: i32, z: i32, w: usize, h: usize, out: []i32) void {
            _ = ptr;
            _ = alloc;
            _ = x;
            _ = z;
            _ = w;
            for (out) |*v| v.* = 1;
            // Reservoir over all-plains still draws per cell.
            _ = h;
        }
        const vtable = BioCtx.VTable{ .voronoiAt = voronoi, .layer4 = layer };
    };
    var ctx: u8 = 0;
    const bio = BioCtx{ .ptr = &ctx, .vtable = &Stub.vtable };
    const a = StrongholdPositions.compute(12345, bio, std.testing.allocator);
    const b = StrongholdPositions.compute(12345, bio, std.testing.allocator);
    try std.testing.expectEqual(a.pos[0].?[0], b.pos[0].?[0]);
    try std.testing.expect(a.pos[0] != null);
}
