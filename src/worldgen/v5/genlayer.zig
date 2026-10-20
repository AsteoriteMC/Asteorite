//! 1.7.10 GenLayer biome chain, ported from CFR decompiles of the official
//! server jar (method bodies verified line-by-line; goldens below are live
//! JVM outputs). Class names (axn..ayc, awx..ayc) noted for auditability.
//!
//! Coordinate convention: getInts(x, z, w, h) writes row-major w*h ints.
//! Layers sampling neighbors fetch the parent at (x-1, z-1, w+2, h+2).

const std = @import("std");
const biome = @import("biome.zig");

// ---------------------------------------------------------------------------
// Base layer state (axn): worldGenSeed (b), baseSeed (c), chunkSeed (d).
// Field letters mirror the obfuscated jar for auditability.

const LCG_MUL: i64 = 6364136223846793005;
const LCG_ADD: i64 = 1442695040888963407;

pub const Base = struct {
    world_gen_seed: i64,
    base_seed: i64,
    chunk_seed: i64,

    pub fn init(world_gen_seed_raw: i64) Base {
        var b = world_gen_seed_raw;
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            b = b *% (b *% LCG_MUL +% LCG_ADD);
            b +%= world_gen_seed_raw;
        }
        return .{ .world_gen_seed = b, .base_seed = 0, .chunk_seed = 0 };
    }

    pub fn initWorldGenSeed(self: *Base, seed: i64, parent: ?*Base) void {
        self.base_seed = seed;
        if (parent) |p| p.initWorldGenSeed(seed);
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            self.base_seed = self.base_seed *% (self.base_seed *% LCG_MUL +% LCG_ADD);
            self.base_seed +%= self.world_gen_seed;
        }
    }

    pub fn initChunkSeed(self: *Base, x: i32, z: i32) void {
        var d: i64 = self.base_seed;
        const xs: i64 = x;
        const zs: i64 = z;
        var i: usize = 0;
        while (i < 2) : (i += 1) {
            d = d *% (d *% LCG_MUL +% LCG_ADD);
            d +%= xs;
            d = d *% (d *% LCG_MUL +% LCG_ADD);
            d +%= zs;
        }
        self.chunk_seed = d;
    }

    /// nextInt(n): (chunkSeed >> 24) % n with negative fixup, then advance.
    /// Arithmetic shift + truncated remainder, exactly like Java.
    pub fn nextInt(self: *Base, n: i32) i32 {
        std.debug.assert(n > 0);
        var r: i32 = @truncate(@rem(self.chunk_seed >> 24, @as(i64, n)));
        if (r < 0) r += n;
        self.chunk_seed = self.chunk_seed *% (self.chunk_seed *% LCG_MUL +% LCG_ADD);
        self.chunk_seed +%= self.base_seed;
        return r;
    }
};

// ---------------------------------------------------------------------------
// Shared predicates (axn statics).

pub fn areBiomesSimilar(a: i32, b: i32) bool {
    if (a == b) return true;
    const a_mp = a == 38 or a == 39;
    const b_mp = b == 38 or b == 39;
    if (a_mp or b_mp) return a_mp and b_mp;
    // NOTE: vanilla compares biome CLASSES (ahu.a = getClass equality),
    // NOT temperatures. Same-temp different-class pairs (forest vs hills)
    // are DISSIMILAR — a multi-hour bug caught by live JVM probing
    // (similar(21,3)=false). Groups from BiomeCls2 class dump.
    if (a < 0 or a > 39 or b < 0 or b > 39) return false;
    const ca = biomeClass(a);
    const cb = biomeClass(b);
    if (ca == 255 or cb == 255) return false;
    return ca == cb;
}

/// getClass() group per biome id (BiomeCls2 probe: nearly every biome has
/// its own class; these are the shared ones).
fn biomeClass(id: i32) u8 {
    return switch (id) {
        0, 10, 24 => 0, // aio ocean trio
        1 => 1, // aip plains
        2, 17 => 2, // aic desert pair
        3, 20, 34 => 3, // aid hills trio
        4, 18, 27, 28, 29 => 4, // aif forest family
        5, 19, 30, 31, 32, 33 => 5, // aiw taiga family
        6 => 6, // aiv swampland
        7, 11 => 7, // air river pair
        8 => 8, // aii hell
        9 => 9, // aix sky
        12, 13 => 10, // aij ice pair
        14, 15 => 11, // aim mushroom pair
        16, 26 => 12, // aht beach pair
        21, 22, 23 => 13, // aik jungle trio
        25 => 14, // aiu stoneBeach
        35, 36 => 15, // ais savanna pair
        37, 38, 39 => 16, // ail mesa trio
        else => 255,
    };
}

pub fn isOceanic(id: i32) bool {
    // ocean(0), deepOcean(24), frozenOcean(10). NOT rivers/mushroom.
    return id == 0 or id == 24 or id == 10;
}

/// Zoom tie-breaking, exactly as disassembled (order matters).
pub fn selectModeOrRandom(st: *Base, a: i32, b: i32, c: i32, d: i32) i32 {
    if (b == c and c == d) return b;
    if (a == b and a == c) return a;
    if (a == b and a == d) return a;
    if (a == c and a == d) return a;
    if (a == b and c != d) return a;
    if (a == c and b != d) return a;
    if (a == d and b != c) return a;
    if (b == c and a != d) return b;
    if (b == d and a != c) return b;
    if (c == d and a != b) return c;
    return selectRandom(st, &[_]i32{ a, b, c, d });
}

pub fn selectRandom(st: *Base, choices: []const i32) i32 {
    return choices[@as(usize, @intCast(st.nextInt(@intCast(choices.len))))];
}

// ---------------------------------------------------------------------------
// Layer graph. Kinds mirror initializeAllBiomeGenerators construction order.

pub const Kind = enum {
    island, // axm(1)
    fuzzy_zoom, // axj(2000) — Zoom with pure random tie-break
    add_island, // axb
    zoom, // ayc
    remove_too_much_ocean, // axs(2)
    add_snow, // axd(2)
    edge_cool_warm, // awy(2, COOL_WARM)
    edge_heat_ice, // awy(2, HEAT_ICE)
    edge_special, // awy(3, SPECIAL)
    mushroom_island, // axc(5)
    deep_ocean, // awx(4)
    river_init, // axt(100)
    river, // axu(1)
    river_mix, // axr(1000, biome, river)
    biome, // axf(200) + WorldType
    biome_edge, // axe(1000)
    shore, // axw(1000)
    smooth, // axx(1000)
    rare_biome, // axq(1001)
    river_mix2, // axv(100, hills, river)
    voronoi_zoom, // ayb(10)
};

pub const Layer = struct {
    kind: Kind,
    seed: i64,
    parent: u32 = 0,
    parent_b: u32 = 0,
    has_parent_b: bool = false,
    warm: []const i32 = &.{},
    desert: []const i32 = &.{},
    cool: []const i32 = &.{},
    icy: []const i32 = &.{},
};

// axf biome tables (ahu field ids; case-sensitive!).
const warm_default = [_]i32{ 2, 2, 2, 35, 35, 1 };
const warm_1_1 = [_]i32{ 2, 4, 3, 6, 1, 5 };
const desert_list = [_]i32{ 4, 29, 3, 1, 27, 6 };
const cool_list = [_]i32{ 4, 3, 5, 1 };
const icy_list = [_]i32{ 12, 12, 12, 30 };

pub const Chain = struct {
    layers: []Layer,
    states: []Base,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *Chain) void {
        self.alloc.free(self.layers);
        self.alloc.free(self.states);
    }

    fn addLayer(list: *std.ArrayList(Layer), alloc: std.mem.Allocator, kind: Kind, seed: i64, parent: ?u32, parent_b: ?u32) !u32 {
        const idx: u32 = @intCast(list.items.len);
        try list.append(alloc, .{
            .kind = kind,
            .seed = seed,
            .parent = parent orelse 0,
            .parent_b = parent_b orelse 0,
            .has_parent_b = parent_b != null,
        });
        return idx;
    }

    fn magnify(list: *std.ArrayList(Layer), alloc: std.mem.Allocator, base: u32, seed: i64, count: usize) !u32 {
        var cur = base;
        for (0..count) |i| {
            cur = try addLayer(list, alloc, .zoom, seed + @as(i64, @intCast(i)), cur, null);
        }
        return cur;
    }

    /// Full 1.7.10 DEFAULT chain (axn.a(seed, DEFAULT) equivalent).
    /// Returns indices; out[0]=biome layer, out[1]=voronoi, out[2]=biome.
    pub fn buildDefault(alloc: std.mem.Allocator, world_seed: i64, large_biomes: bool) !struct { chain: Chain, roots: [3]u32 } {
        var list: std.ArrayList(Layer) = .empty;
        errdefer list.deinit(alloc);

        var l = try addLayer(&list, alloc, .island, 1, null, null);
        l = try addLayer(&list, alloc, .fuzzy_zoom, 2000, l, null);
        l = try addLayer(&list, alloc, .add_island, 1, l, null);
        l = try addLayer(&list, alloc, .zoom, 2001, l, null);
        l = try addLayer(&list, alloc, .add_island, 2, l, null);
        l = try addLayer(&list, alloc, .add_island, 50, l, null);
        l = try addLayer(&list, alloc, .add_island, 70, l, null);
        l = try addLayer(&list, alloc, .remove_too_much_ocean, 2, l, null);
        l = try addLayer(&list, alloc, .add_snow, 2, l, null);
        l = try addLayer(&list, alloc, .add_island, 3, l, null);
        l = try addLayer(&list, alloc, .edge_cool_warm, 2, l, null);
        l = try addLayer(&list, alloc, .edge_heat_ice, 2, l, null);
        l = try addLayer(&list, alloc, .edge_special, 3, l, null);
        l = try addLayer(&list, alloc, .zoom, 2002, l, null);
        l = try addLayer(&list, alloc, .zoom, 2003, l, null);
        l = try addLayer(&list, alloc, .add_island, 4, l, null);
        l = try addLayer(&list, alloc, .mushroom_island, 5, l, null);
        const deep = try addLayer(&list, alloc, .deep_ocean, 4, l, null);

        // River branch. (magnify x0 = identity.)
        var river = try magnify(&list, alloc, deep, 1000, 0);
        river = try addLayer(&list, alloc, .river_init, 100, river, null);

        // Biome branch.
        var bio = try magnify(&list, alloc, deep, 1000, 0);
        {
            const bidx = try addLayer(&list, alloc, .biome, 200, bio, null);
            list.items[bidx].warm = if (large_biomes) &warm_1_1 else &warm_default;
            list.items[bidx].desert = &desert_list;
            list.items[bidx].cool = &cool_list;
            list.items[bidx].icy = &icy_list;
            bio = bidx;
        }
        bio = try magnify(&list, alloc, bio, 1000, 2);
        bio = try addLayer(&list, alloc, .biome_edge, 1000, bio, null);

        // Hills mix (river markers at 1:4).
        const river2 = try magnify(&list, alloc, river, 1000, 2);
        const mixed = try addLayer(&list, alloc, .river_mix, 1000, bio, river2);

        // Scaled river for the second mix.
        var r3 = try magnify(&list, alloc, river, 1000, 2);
        r3 = try magnify(&list, alloc, r3, 1000, if (large_biomes) 6 else 4);
        r3 = try addLayer(&list, alloc, .river, 1, r3, null);
        r3 = try addLayer(&list, alloc, .smooth, 1000, r3, null);

        // Hills: rare-biome on the mix, then zooms + shore.
        var hills = try addLayer(&list, alloc, .rare_biome, 1001, mixed, null);
        const zooms: usize = if (large_biomes) 6 else 4;
        for (0..zooms) |qi| {
            hills = try addLayer(&list, alloc, .zoom, 1000 + @as(i64, @intCast(qi)), hills, null);
            if (qi == 0) hills = try addLayer(&list, alloc, .add_island, 3, hills, null);
            if (qi == 1) hills = try addLayer(&list, alloc, .shore, 1000, hills, null);
        }
        hills = try addLayer(&list, alloc, .smooth, 1000, hills, null);
        const final_mix = try addLayer(&list, alloc, .river_mix2, 100, hills, r3);
        const voronoi = try addLayer(&list, alloc, .voronoi_zoom, 10, final_mix, null);

        const layers = try list.toOwnedSlice(alloc);
        errdefer alloc.free(layers);
        const states = try alloc.alloc(Base, layers.len);
        errdefer alloc.free(states);
        for (layers, 0..) |lay, i| states[i] = Base.init(lay.seed);
        var chain = Chain{ .layers = layers, .states = states, .alloc = alloc };
        // Single initWorldGenSeed from the voronoi root, exactly like vanilla
        // (axn.a ends with ret.initWorldGenSeed(seed)). Shared ancestry is
        // idempotent; the river_mix second parent is deliberately NOT visited
        // (axr has no initWorldGenSeed override — probe-verified: its 2 zoom
        // layers keep baseSeed 0). Replicating the quirk is load-bearing.
        chain.initVanilla(world_seed, voronoi);
        return .{ .chain = chain, .roots = .{ final_mix, voronoi, final_mix } };
    }

    /// initWorldGenSeed following parent links (axn.a(long) recursion).
    /// Vanilla-exact: set own seed, recurse, then mix. Only axv (river_mix2)
    /// visits both parents; axr (river_mix) visits ONLY the single parent
    /// (no override in the jar — its river-side zooms keep baseSeed 0).
    fn initVanilla(self: *Chain, world_seed: i64, idx: u32) void {
        const lay = self.layers[idx];
        self.states[idx].base_seed = world_seed;
        if (lay.kind == .river_mix2) {
            self.initVanilla(world_seed, lay.parent);
            self.initVanilla(world_seed, lay.parent_b);
        } else if (lay.kind != .island) {
            self.initVanilla(world_seed, lay.parent);
        }
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            self.states[idx].base_seed = self.states[idx].base_seed *% (self.states[idx].base_seed *% LCG_MUL +% LCG_ADD);
            self.states[idx].base_seed +%= self.states[idx].world_gen_seed;
        }
    }

    // ------------------------------------------------------------------
    // Evaluation. out must hold w*h i32s. Scratch via caller arena.

    pub fn getInts(self: *Chain, alloc: std.mem.Allocator, idx: u32, x: i32, z: i32, w: usize, h: usize, out: []i32) anyerror!void {
        std.debug.assert(out.len >= w * h);
        const lay = self.layers[idx];
        const st = &self.states[idx];
        switch (lay.kind) {
            .island => {
                for (0..h) |dz| {
                    for (0..w) |dx| {
                        st.initChunkSeed(x + @as(i32, @intCast(dx)), z + @as(i32, @intCast(dz)));
                        out[dz * w + dx] = if (st.nextInt(10) == 0) 1 else 0;
                    }
                }
                // Origin island: force land if the window covers (0,0).
                if (x <= 0 and x + @as(i32, @intCast(w)) > 0 and z <= 0 and z + @as(i32, @intCast(h)) > 0) {
                    out[@as(usize, @intCast(-x)) + @as(usize, @intCast(-z)) * w] = 1;
                }
            },
            .fuzzy_zoom => try self.evalZoom(st, idx, lay.parent, x, z, w, h, out, alloc, true),
            .zoom => try self.evalZoom(st, idx, lay.parent, x, z, w, h, out, alloc, false),
            .add_island => try self.evalAddIsland(st, idx, lay.parent, x, z, w, h, out, alloc),
            .remove_too_much_ocean => try self.evalRemoveOcean(st, idx, lay.parent, x, z, w, h, out, alloc),
            .add_snow => try self.evalAddSnow(st, idx, lay.parent, x, z, w, h, out, alloc),
            .edge_cool_warm => try self.evalEdge(st, idx, lay.parent, x, z, w, h, out, alloc, .cool_warm),
            .edge_heat_ice => try self.evalEdge(st, idx, lay.parent, x, z, w, h, out, alloc, .heat_ice),
            .edge_special => try self.evalEdgeSpecial(st, idx, lay.parent, x, z, w, h, out, alloc),
            .mushroom_island => try self.evalMushroom(st, idx, lay.parent, x, z, w, h, out, alloc),
            .deep_ocean => try self.evalDeepOcean(st, idx, lay.parent, x, z, w, h, out, alloc),
            .river_init => try self.evalRiverInit(st, idx, lay.parent, x, z, w, h, out, alloc),
            .river => try self.evalRiver(st, idx, lay.parent, x, z, w, h, out, alloc),
            .river_mix => try self.evalRiverMix(st, idx, lay.parent, lay.parent_b, x, z, w, h, out, alloc),
            .biome => try self.evalBiome(st, idx, lay, x, z, w, h, out, alloc),
            .biome_edge => try self.evalBiomeEdge(st, idx, lay.parent, x, z, w, h, out, alloc),
            .shore => try self.evalShore(st, idx, lay.parent, x, z, w, h, out, alloc),
            .smooth => try self.evalSmooth(st, idx, lay.parent, x, z, w, h, out, alloc),
            .rare_biome => try self.evalRareBiome(st, idx, lay.parent, x, z, w, h, out, alloc),
            .river_mix2 => try self.evalRiverMix2(st, idx, lay.parent, lay.parent_b, x, z, w, h, out, alloc),
            .voronoi_zoom => try self.evalVoronoi(st, idx, lay.parent, x, z, w, h, out, alloc),
        }
    }

    fn parentOut(self: *Chain, alloc: std.mem.Allocator, idx: u32, x: i32, z: i32, w: usize, h: usize) anyerror![]i32 {
        const buf = try alloc.alloc(i32, w * h);
        errdefer alloc.free(buf);
        try self.getInts(alloc, idx, x, z, w, h, buf);
        return buf;
    }

    fn growRoll(st: *Base, center: i32) i32 {
        if (st.nextInt(5) == 0) return if (center == 4) 4 else 0;
        return center;
    }

    // --- zoom (ayc) / fuzzy_zoom (axj). Fuzzy = pure random tie-break.
    fn evalZoom(self: *Chain, st: *Base, idx: u32, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator, fuzzy: bool) anyerror!void {
        _ = idx;
        const px: i32 = x >> 1;
        const pz: i32 = z >> 1;
        const pw: usize = (w >> 1) + 2;
        const ph: usize = (h >> 1) + 2;
        const p = try self.parentOut(alloc, parent, px, pz, pw, ph);
        defer alloc.free(p);
        const tw: usize = (pw - 1) * 2;
        const th: usize = (ph - 1) * 2;
        const tmp = try alloc.alloc(i32, tw * th);
        defer alloc.free(tmp);
        for (0..ph - 1) |gz| {
            // NOTE: seed uses ((x+px)*2, (z+pz)*2) -- multiply AFTER add.
            var v16: i32 = p[0 + gz * pw];
            var v17: i32 = p[0 + (gz + 1) * pw];
            var gx: usize = 0;
            while (gx < pw - 1) : (gx += 1) {
                st.initChunkSeed((@as(i32, @intCast(@as(i64, @intCast(gx)) + px))) * 2, (@as(i32, @intCast(@as(i64, @intCast(gz)) + pz))) * 2);
                const v18: i32 = p[gx + 1 + gz * pw];
                const v19: i32 = p[gx + 1 + (gz + 1) * pw];
                const ox = gx * 2;
                const oz = gz * 2;
                // NOTE: even-row-odd-col pairs with EAST, odd-row-even-col
                // with SOUTH (CFR-definitive; an earlier javap read had these
                // swapped and it poisoned every downstream layer).
                tmp[ox + oz * tw] = v16;
                // NOTE: draw ORDER is spec: south pick first, then east pick
                // (CFR assigns tmp[odd-row] before tmp[even-row-odd-col]).
                // Values land in the same cells either way, but each draw
                // advances chunkSeed, so swapped order shifts all downstream.
                const pick_south = selectRandom(st, &[_]i32{ v16, v17 });
                const pick_east = selectRandom(st, &[_]i32{ v16, v18 });
                tmp[ox + (oz + 1) * tw] = pick_south;
                tmp[ox + 1 + oz * tw] = pick_east;
                if (fuzzy) {
                    tmp[ox + 1 + (oz + 1) * tw] = selectRandom(st, &[_]i32{ v16, v18, v17, v19 });
                } else {
                    tmp[ox + 1 + (oz + 1) * tw] = selectModeOrRandom(st, v16, v18, v17, v19);
                }
                v16 = v18;
                v17 = v19;
            }
        }
        const oxo: usize = @intCast(@as(u32, @bitCast(x)) & 1);
        const ozo: usize = @intCast(@as(u32, @bitCast(z)) & 1);
        for (0..h) |dz| {
            @memcpy(out[dz * w ..][0..w], tmp[(dz + ozo) * tw + oxo ..][0..w]);
        }
    }

    fn evalAddIsland(self: *Chain, st: *Base, idx: u32, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
        _ = idx;
        const p = try self.parentOut(alloc, parent, x - 1, z - 1, w + 2, h + 2);
        defer alloc.free(p);
        const pw = w + 2;
        for (0..h) |dz| {
            for (0..w) |dx| {
                const v13 = p[dx + dz * pw];
                const v14 = p[dx + 2 + dz * pw];
                const v15 = p[dx + (dz + 2) * pw];
                const v16 = p[dx + 2 + (dz + 2) * pw];
                const v17 = p[dx + 1 + (dz + 1) * pw];
                st.initChunkSeed(x + @as(i32, @intCast(dx)), z + @as(i32, @intCast(dz)));
                out[dz * w + dx] = blk: {
                    if (v17 == 0) {
                        if (v13 == 0 and v14 == 0 and v15 == 0 and v16 == 0) break :blk 0;
                        var count: i32 = 1;
                        var pick: i32 = 1;
                        if (v13 != 0) {
                            if (st.nextInt(count) == 0) pick = v13;
                            count += 1;
                        }
                        if (v14 != 0) {
                            if (st.nextInt(count) == 0) pick = v14;
                            count += 1;
                        }
                        if (v15 != 0) {
                            if (st.nextInt(count) == 0) pick = v15;
                            count += 1;
                        }
                        if (v16 != 0) {
                            if (st.nextInt(count) == 0) pick = v16;
                            count += 1;
                        }
                        if (st.nextInt(3) == 0) break :blk pick;
                        break :blk if (pick == 4) @as(i32, 4) else 0;
                    }
                    if (v13 == 0 or v14 == 0 or v15 == 0 or v16 == 0) break :blk growRoll(st, v17);
                    break :blk v17;
                };
            }
        }
    }

    fn evalRemoveOcean(self: *Chain, st: *Base, idx: u32, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
        _ = idx;
        const p = try self.parentOut(alloc, parent, x - 1, z - 1, w + 2, h + 2);
        defer alloc.free(p);
        const pw = w + 2;
        for (0..h) |dz| {
            for (0..w) |dx| {
                // NOTE: orthogonal N,E,W,S neighbors (CFR-definitive).
                const n = p[dx + 1 + dz * pw];
                const e = p[dx + 2 + (dz + 1) * pw];
                const wv = p[dx + (dz + 1) * pw];
                const ss = p[dx + 1 + (dz + 2) * pw];
                const v17 = p[dx + 1 + (dz + 1) * pw];
                out[dz * w + dx] = v17;
                st.initChunkSeed(x + @as(i32, @intCast(dx)), z + @as(i32, @intCast(dz)));
                if (v17 == 0 and n == 0 and e == 0 and wv == 0 and ss == 0 and st.nextInt(2) == 0) {
                    out[dz * w + dx] = 1;
                }
            }
        }
    }
    fn evalAddSnow(self: *Chain, st: *Base, idx: u32, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
        _ = idx;
        const p = try self.parentOut(alloc, parent, x - 1, z - 1, w + 2, h + 2);
        defer alloc.free(p);
        const pw = w + 2;
        for (0..h) |dz| {
            for (0..w) |dx| {
                const v = p[dx + 1 + (dz + 1) * pw];
                st.initChunkSeed(x + @as(i32, @intCast(dx)), z + @as(i32, @intCast(dz)));
                if (v == 0) {
                    out[dz * w + dx] = 0;
                    continue;
                }
                const r = st.nextInt(6);
                out[dz * w + dx] = if (r == 0) 4 else if (r == 1) 3 else 1;
            }
        }
    }
    const EdgeMode = enum { cool_warm, heat_ice, special };
    fn evalEdge(self: *Chain, st: *Base, idx: u32, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator, mode: EdgeMode) anyerror!void {
        _ = idx;
        std.debug.assert(mode != .special);
        const p = try self.parentOut(alloc, parent, x - 1, z - 1, w + 2, h + 2);
        defer alloc.free(p);
        const pw = w + 2;
        for (0..h) |dz| {
            for (0..w) |dx| {
                const c = p[dx + 1 + (dz + 1) * pw];
                const n = p[dx + 1 + dz * pw];
                const e = p[dx + 2 + (dz + 1) * pw];
                const s_ = p[dx + 1 + (dz + 2) * pw];
                const wv = p[dx + (dz + 1) * pw];
                st.initChunkSeed(x + @as(i32, @intCast(dx)), z + @as(i32, @intCast(dz)));
                var v = c;
                if (mode == .cool_warm) {
                    // NOTE: ANY 3 or 4 neighbor converts (CFR: bl2||bl).
                    // An earlier read had this as !has3&&has4 — wrong.
                    if (c == 1) {
                        const has3 = n == 3 or e == 3 or s_ == 3 or wv == 3;
                        const has4 = n == 4 or e == 4 or s_ == 4 or wv == 4;
                        if (has3 or has4) v = 2;
                    }
                } else {
                    // NOTE: ANY 1 or 2 neighbor converts (CFR: bl||bl2).
                    if (c == 4) {
                        const has2 = n == 2 or e == 2 or s_ == 2 or wv == 2;
                        const has1 = n == 1 or e == 1 or s_ == 1 or wv == 1;
                        if (has1 or has2) v = 3;
                    }
                }
                out[dz * w + dx] = v;
            }
        }
    }
    fn evalEdgeSpecial(self: *Chain, st: *Base, idx: u32, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
        _ = idx;
        const p = try self.parentOut(alloc, parent, x, z, w, h);
        defer alloc.free(p);
        for (0..h) |dz| {
            for (0..w) |dx| {
                var v = p[dz * w + dx];
                st.initChunkSeed(x + @as(i32, @intCast(dx)), z + @as(i32, @intCast(dz)));
                // SPECIAL: tag ~1/13 of cells with variant bits 8-11.
                // NOTE: explicit parens — Java parses v|(x&0xF00) (& binds
                // tighter than |); do not rely on Zig precedence here.
                if (v != 0 and st.nextInt(13) == 0) {
                    v = v | (((@as(i32, 1 + st.nextInt(15)) << 8) & 3840));
                }
                out[dz * w + dx] = v;
            }
        }
    }
    fn evalMushroom(self: *Chain, st: *Base, idx: u32, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
        _ = idx;
        const p = try self.parentOut(alloc, parent, x - 1, z - 1, w + 2, h + 2);
        defer alloc.free(p);
        const pw = w + 2;
        for (0..h) |dz| {
            for (0..w) |dx| {
                const c = p[dx + 1 + (dz + 1) * pw];
                st.initChunkSeed(x + @as(i32, @intCast(dx)), z + @as(i32, @intCast(dz)));
                if (c != 0) {
                    out[dz * w + dx] = c;
                    continue;
                }
                const n = p[dx + 1 + dz * pw];
                const e = p[dx + 2 + (dz + 1) * pw];
                const s = p[dx + 1 + (dz + 2) * pw];
                const wv = p[dx + (dz + 1) * pw];
                if (n == 0 and e == 0 and s == 0 and wv == 0 and st.nextInt(100) == 0) {
                    out[dz * w + dx] = 14; // mushroomIsland
                } else {
                    out[dz * w + dx] = c;
                }
            }
        }
    }
    fn evalDeepOcean(self: *Chain, _: *Base, idx: u32, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
        _ = idx;
        const p = try self.parentOut(alloc, parent, x - 1, z - 1, w + 2, h + 2);
        defer alloc.free(p);
        const pw = w + 2;
        for (0..h) |dz| {
            for (0..w) |dx| {
                const c = p[dx + 1 + (dz + 1) * pw];
                // NOTE: no initChunkSeed/nextInt here (CFR shows no RNG use).
                if (c != 0) {
                    out[dz * w + dx] = c;
                    continue;
                }
                // NOTE: orthogonal N,E,W,S neighbors (CFR-definitive).
                var zeros: u32 = 0;
                if (p[dx + 1 + dz * pw] == 0) zeros += 1;
                if (p[dx + 2 + (dz + 1) * pw] == 0) zeros += 1;
                if (p[dx + (dz + 1) * pw] == 0) zeros += 1;
                if (p[dx + 1 + (dz + 2) * pw] == 0) zeros += 1;
                // NOTE: >3 means all four (max is 4). Transcribed as-is.
                out[dz * w + dx] = if (zeros > 3) 24 else 0;
            }
        }
    }
    fn evalRiverInit(self: *Chain, st: *Base, idx: u32, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
        _ = idx;
        const p = try self.parentOut(alloc, parent, x, z, w, h);
        defer alloc.free(p);
        for (0..h) |dz| {
            for (0..w) |dx| {
                st.initChunkSeed(x + @as(i32, @intCast(dx)), z + @as(i32, @intCast(dz)));
                out[dz * w + dx] = if (p[dz * w + dx] > 0) st.nextInt(299999) + 2 else 0;
            }
        }
    }
    fn riverC(v: i32) i32 {
        return if (v < 2) v else 2 + (v & 1);
    }

    // NOTE: no initChunkSeed here (verified: axu skips it entirely).
    fn evalRiver(self: *Chain, st: *Base, idx: u32, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
        _ = idx;
        _ = st;
        const p = try self.parentOut(alloc, parent, x - 1, z - 1, w + 2, h + 2);
        defer alloc.free(p);
        const pw = w + 2;
        for (0..h) |dz| {
            for (0..w) |dx| {
                const c = riverC(p[dx + 1 + (dz + 1) * pw]);
                const n = riverC(p[dx + 1 + dz * pw]);
                const e = riverC(p[dx + 2 + (dz + 1) * pw]);
                const s = riverC(p[dx + 1 + (dz + 2) * pw]);
                const wv = riverC(p[dx + (dz + 1) * pw]);
                out[dz * w + dx] = if (c == n and c == e and c == s and c == wv) -1 else 7;
            }
        }
    }
    // --- river_mix (axr). Hills upgrade + mutated (+128) variants.
    fn evalRiverMix(self: *Chain, st: *Base, idx: u32, b: u32, r: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
        _ = idx;
        const pb = try self.parentOut(alloc, b, x - 1, z - 1, w + 2, h + 2);
        defer alloc.free(pb);
        const pr = try self.parentOut(alloc, r, x - 1, z - 1, w + 2, h + 2);
        defer alloc.free(pr);
        const pw = w + 2;
        for (0..h) |dz| {
            for (0..w) |dx| {
                st.initChunkSeed(x + @as(i32, @intCast(dx)), z + @as(i32, @intCast(dz)));
                const v10 = pb[dx + 1 + (dz + 1) * pw];
                const v11 = pr[dx + 1 + (dz + 1) * pw];
                const riverish = v11 >= 2 and @rem(v11 - 2, 29) == 1;
                // Mutated (+128) variant in river areas.
                if (v10 != 0 and v11 >= 2 and @rem(v11 - 2, 29) == 1 and v10 < 128) {
                    if (biome.biomeExists(v10 + 128)) {
                        out[dz * w + dx] = v10 + 128;
                    } else {
                        out[dz * w + dx] = v10;
                    }
                    continue;
                }
                var v13 = v10;
                if (st.nextInt(3) == 0 or riverish) {
                    v13 = hillsVariant(v10, st);
                    if (riverish and v13 != v10) {
                        if (biome.biomeExists(v13 + 128)) {
                            out[dz * w + dx] = v13 + 128;
                        } else {
                            out[dz * w + dx] = v10;
                        }
                        continue;
                    }
                } else {
                    out[dz * w + dx] = v10;
                    continue;
                }
                if (v13 == v10) {
                    out[dz * w + dx] = v10;
                    continue;
                }
                const n = pb[dx + 1 + dz * pw];
                const e = pb[dx + 2 + (dz + 1) * pw];
                const ss = pb[dx + 1 + (dz + 2) * pw];
                const wv = pb[dx + (dz + 1) * pw];
                var similar: u32 = 0;
                if (areBiomesSimilar(n, v10)) similar += 1;
                if (areBiomesSimilar(e, v10)) similar += 1;
                if (areBiomesSimilar(ss, v10)) similar += 1;
                if (areBiomesSimilar(wv, v10)) similar += 1;
                out[dz * w + dx] = if (similar >= 3) v13 else v10;
            }
        }
    }

    fn hillsVariant(v10: i32, st: *Base) i32 {
        if (v10 == 2) return 17; // desert -> desertHills
        if (v10 == 4) return 18; // forest -> forestHills
        if (v10 == 27) return 28; // birchForest -> birchForestHills
        if (v10 == 29) return 1; // roofedForest -> plains
        if (v10 == 5) return 19; // taiga -> taigaHills
        if (v10 == 32) return 33; // megaTaiga -> megaTaigaHills
        if (v10 == 30) return 31; // coldTaiga -> coldTaigaHills
        if (v10 == 1) return if (st.nextInt(3) == 0) 18 else 4; // plains -> forestHills/forest
        if (v10 == 12) return 13; // icePlains -> iceMountains
        if (v10 == 21) return 22; // jungle -> jungleHills
        if (v10 == 0) return 24; // ocean -> deepOcean
        if (v10 == 3) return 34; // extremeHills -> extremeHillsPlus
        if (v10 == 35) return 36; // savanna -> savannaPlateau
        // NOTE: mesa check uses similarity (38 or 39) -> 37.
        if (areBiomesSimilar(v10, 38)) return 37;
        if (v10 == 24 and st.nextInt(3) == 0) {
            return if (st.nextInt(2) == 0) 1 else 4; // deepOcean -> plains/forest
        }
        return v10;
    }
    // --- biome (axf). 1:1 fetch. Bits 8-11 are the SPECIAL variant tag.
    fn evalBiome(self: *Chain, st: *Base, idx: u32, lay: Layer, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
        _ = idx;
        const p = try self.parentOut(alloc, lay.parent, x, z, w, h);
        defer alloc.free(p);
        for (0..h) |dz| {
            for (0..w) |dx| {
                st.initChunkSeed(x + @as(i32, @intCast(dx)), z + @as(i32, @intCast(dz)));
                var v5 = p[dz * w + dx];
                const v6: i32 = (v5 & 0xF00) >> 8;
                v5 &= @as(i32, @bitCast(@as(u32, 0xFFFFF0FF)));
                if (isOceanic(v5)) {
                    out[dz * w + dx] = v5;
                    continue;
                }
                if (v5 == 14) {
                    out[dz * w + dx] = v5;
                    continue;
                }
                if (v5 == 1) {
                    if (v6 > 0) {
                        if (st.nextInt(3) == 0) {
                            out[dz * w + dx] = 39; // mesaPlateauF
                            continue;
                        }
                        out[dz * w + dx] = 38; // mesaPlateau
                        continue;
                    }
                    out[dz * w + dx] = selectRandom(st, lay.warm);
                    continue;
                }
                if (v5 == 2) {
                    if (v6 > 0) {
                        out[dz * w + dx] = 21; // jungle
                        continue;
                    }
                    out[dz * w + dx] = selectRandom(st, lay.desert);
                    continue;
                }
                if (v5 == 3) {
                    if (v6 > 0) {
                        out[dz * w + dx] = 32; // megaTaiga
                        continue;
                    }
                    out[dz * w + dx] = selectRandom(st, lay.cool);
                    continue;
                }
                out[dz * w + dx] = if (v5 == 4) selectRandom(st, lay.icy) else 14;
            }
        }
    }
    // --- biome_edge (axe). Helpers a/b write out[idx] and return true
    // when they claim the cell.
    fn evalBiomeEdge(self: *Chain, st: *Base, idx: u32, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
        _ = idx;
        const p = try self.parentOut(alloc, parent, x - 1, z - 1, w + 2, h + 2);
        defer alloc.free(p);
        const pw = w + 2;
        for (0..h) |dz| {
            for (0..w) |dx| {
                st.initChunkSeed(x + @as(i32, @intCast(dx)), z + @as(i32, @intCast(dz)));
                const c = p[dx + 1 + (dz + 1) * pw];
                if (try self.edgeA(st, p, out, dx, dz, w, c, 3, 20)) continue;
                if (try self.edgeB(st, p, out, dx, dz, w, c, 38, 37)) continue;
                if (try self.edgeB(st, p, out, dx, dz, w, c, 39, 37)) continue;
                if (try self.edgeB(st, p, out, dx, dz, w, c, 32, 5)) continue;
                if (c == 2) {
                    const n = p[dx + 1 + dz * pw];
                    const e = p[dx + 2 + (dz + 1) * pw];
                    const ss = p[dx + (dz + 1) * pw];
                    const wv = p[dx + 1 + (dz + 2) * pw];
                    _ = ss;
                    _ = wv;
                    // NOTE: CFR order is N,E,W,S but any-of-4 is order-free.
                    if (n == 12 or e == 12 or p[dx + (dz + 1) * pw] == 12 or p[dx + 1 + (dz + 2) * pw] == 12) {
                        out[dz * w + dx] = 34; // extremeHillsPlus
                        continue;
                    }
                    out[dz * w + dx] = c;
                    continue;
                }
                if (c == 6) {
                    const n = p[dx + 1 + dz * pw];
                    const e = p[dx + 2 + (dz + 1) * pw];
                    const wv = p[dx + (dz + 1) * pw];
                    const ss = p[dx + 1 + (dz + 2) * pw];
                    if (n == 2 or e == 2 or wv == 2 or ss == 2 or n == 30 or e == 30 or wv == 30 or ss == 30 or n == 12 or e == 12 or wv == 12 or ss == 12) {
                        out[dz * w + dx] = 1; // plains
                        continue;
                    }
                    if (n == 21 or ss == 21 or e == 21 or wv == 21) {
                        out[dz * w + dx] = 23; // jungleEdge
                        continue;
                    }
                    out[dz * w + dx] = c;
                    continue;
                }
                out[dz * w + dx] = c;
            }
        }
    }

    fn edgeA(self: *Chain, st: *Base, p: []i32, out: []i32, dx: usize, dz: usize, w: usize, c: i32, target: i32, repl: i32) anyerror!bool {
        _ = self;
        if (!areBiomesSimilar(c, target)) return false;
        const pw = w + 2;
        const n = p[dx + 1 + dz * pw];
        const e = p[dx + 2 + (dz + 1) * pw];
        const wv = p[dx + (dz + 1) * pw];
        const ss = p[dx + 1 + (dz + 2) * pw];
        out[dz * w + dx] = if (!edgeSimilar(n, target) or !edgeSimilar(e, target) or !edgeSimilar(wv, target) or !edgeSimilar(ss, target)) repl else c;
        _ = st;
        return true;
    }

    fn edgeB(self: *Chain, st: *Base, p: []i32, out: []i32, dx: usize, dz: usize, w: usize, c: i32, target: i32, repl: i32) anyerror!bool {
        _ = self;
        if (c != target) return false;
        const pw = w + 2;
        const n = p[dx + 1 + dz * pw];
        const e = p[dx + 2 + (dz + 1) * pw];
        const wv = p[dx + (dz + 1) * pw];
        const ss = p[dx + 1 + (dz + 2) * pw];
        out[dz * w + dx] = if (!areBiomesSimilar(n, target) or !areBiomesSimilar(e, target) or !areBiomesSimilar(wv, target) or !areBiomesSimilar(ss, target)) repl else c;
        _ = st;
        return true;
    }

    /// axe.b(int,int): similarity with temp-category fallback.
    /// areBiomesSimilar first; else both-registered and
    /// (temps equal OR either temp is MEDIUM — ahw.c wildcard, CFR-verified;
    /// this makes medium-target checks nearly always pass).
    fn edgeSimilar(a: i32, b: i32) bool {
        if (areBiomesSimilar(a, b)) return true;
        if (a < 0 or a > 39 or b < 0 or b > 39) return false;
        const ba = biome.BIOMES[@as(usize, @intCast(a))] orelse return false;
        const bb = biome.BIOMES[@as(usize, @intCast(b))] orelse return false;
        return ba.temp == bb.temp or ba.temp == .medium or bb.temp == .medium;
    }
    // --- shore (axw).
    fn evalShore(self: *Chain, st: *Base, idx: u32, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
        _ = idx;
        const p = try self.parentOut(alloc, parent, x - 1, z - 1, w + 2, h + 2);
        defer alloc.free(p);
        const pw = w + 2;
        for (0..h) |dz| {
            for (0..w) |dx| {
                st.initChunkSeed(x + @as(i32, @intCast(dx)), z + @as(i32, @intCast(dz)));
                const c = p[dx + 1 + (dz + 1) * pw];
                if (c == 14) {
                    const n = p[dx + 1 + dz * pw];
                    const e = p[dx + 2 + (dz + 1) * pw];
                    const wv = p[dx + (dz + 1) * pw];
                    const ss = p[dx + 1 + (dz + 2) * pw];
                    if (n == 0 or e == 0 or wv == 0 or ss == 0) {
                        out[dz * w + dx] = 15; // mushroomIslandShore
                        continue;
                    }
                    out[dz * w + dx] = c;
                    continue;
                }
                if (isJungle(c)) {
                    const n = p[dx + 1 + dz * pw];
                    const e = p[dx + 2 + (dz + 1) * pw];
                    const wv = p[dx + (dz + 1) * pw];
                    const ss = p[dx + 1 + (dz + 2) * pw];
                    if (!(shoreC(n) and shoreC(e) and shoreC(wv) and shoreC(ss))) {
                        out[dz * w + dx] = 23; // jungleEdge
                        continue;
                    }
                    if (isOceanic(n) or isOceanic(e) or isOceanic(wv) or isOceanic(ss)) {
                        out[dz * w + dx] = 16; // beach
                        continue;
                    }
                    out[dz * w + dx] = c;
                    continue;
                }
                if (c == 3 or c == 34 or c == 20) {
                    self.shoreA(p, out, dx, dz, w, c, 25); // stoneBeach
                    continue;
                }
                if (isSnowy(c)) {
                    self.shoreA(p, out, dx, dz, w, c, 26); // coldBeach
                    continue;
                }
                if (c == 37 or c == 38) {
                    const n = p[dx + 1 + dz * pw];
                    const e = p[dx + 2 + (dz + 1) * pw];
                    const wv = p[dx + (dz + 1) * pw];
                    const ss = p[dx + 1 + (dz + 2) * pw];
                    if (isOceanic(n) or isOceanic(e) or isOceanic(wv) or isOceanic(ss)) {
                        out[dz * w + dx] = c;
                        continue;
                    }
                    if (!(isMesa(n) and isMesa(e) and isMesa(wv) and isMesa(ss))) {
                        out[dz * w + dx] = 2; // desert
                        continue;
                    }
                    out[dz * w + dx] = c;
                    continue;
                }
                if (c != 0 and c != 24 and c != 7 and c != 6) {
                    const n = p[dx + 1 + dz * pw];
                    const e = p[dx + 2 + (dz + 1) * pw];
                    const wv = p[dx + (dz + 1) * pw];
                    const ss = p[dx + 1 + (dz + 2) * pw];
                    if (isOceanic(n) or isOceanic(e) or isOceanic(wv) or isOceanic(ss)) {
                        out[dz * w + dx] = 16; // beach
                        continue;
                    }
                    out[dz * w + dx] = c;
                    continue;
                }
                out[dz * w + dx] = c;
            }
        }
    }

    fn shoreA(self: *Chain, p: []i32, out: []i32, dx: usize, dz: usize, w: usize, c: i32, repl: i32) void {
        _ = self;
        if (isOceanic(c)) {
            out[dz * w + dx] = c;
            return;
        }
        const pw = w + 2;
        const n = p[dx + 1 + dz * pw];
        const e = p[dx + 2 + (dz + 1) * pw];
        const wv = p[dx + (dz + 1) * pw];
        const ss = p[dx + 1 + (dz + 2) * pw];
        out[dz * w + dx] = if (isOceanic(n) or isOceanic(e) or isOceanic(wv) or isOceanic(ss)) repl else c;
    }

    fn isJungle(id: i32) bool {
        return id == 21 or id == 22 or id == 23;
    }

    fn isMesa(id: i32) bool {
        return id == 37 or id == 38 or id == 39;
    }

    /// Snowy biomes (ahu.j() probe): 10,11,12,13,26,30,31.
    fn isSnowy(id: i32) bool {
        return id == 10 or id == 11 or id == 12 or id == 13 or id == 26 or id == 30 or id == 31;
    }

    /// axw.c(int): jungle-class or shore-eligible.
    fn shoreC(id: i32) bool {
        if (id < 0 or id > 39) return isOceanic(id);
        if (biome.BIOMES[@as(usize, @intCast(id))] == null) return isOceanic(id);
        return isJungle(id) or id == 4 or id == 5 or isOceanic(id);
    }
    // --- smooth (axx). NOTE: initChunkSeed ONLY in the both-equal branch.
    fn evalSmooth(self: *Chain, st: *Base, idx: u32, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
        _ = idx;
        const p = try self.parentOut(alloc, parent, x - 1, z - 1, w + 2, h + 2);
        defer alloc.free(p);
        const pw = w + 2;
        for (0..h) |dz| {
            for (0..w) |dx| {
                const n9 = p[dx + (dz + 1) * pw];
                const n10 = p[dx + 2 + (dz + 1) * pw];
                const n11 = p[dx + 1 + dz * pw];
                const n12 = p[dx + 1 + (dz + 2) * pw];
                var n13 = p[dx + 1 + (dz + 1) * pw];
                if (n9 == n10 and n11 == n12) {
                    st.initChunkSeed(x + @as(i32, @intCast(dx)), z + @as(i32, @intCast(dz)));
                    n13 = if (st.nextInt(2) == 0) n9 else n11;
                } else {
                    if (n9 == n10) n13 = n9;
                    if (n11 == n12) n13 = n11;
                }
                out[dz * w + dx] = n13;
            }
        }
    }
    // --- rare_biome (axq). Plains -> plains+128 (mutated) at 1/57.
    fn evalRareBiome(self: *Chain, st: *Base, idx: u32, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
        _ = idx;
        const p = try self.parentOut(alloc, parent, x - 1, z - 1, w + 2, h + 2);
        defer alloc.free(p);
        const pw = w + 2;
        for (0..h) |dz| {
            for (0..w) |dx| {
                st.initChunkSeed(x + @as(i32, @intCast(dx)), z + @as(i32, @intCast(dz)));
                const c = p[dx + 1 + (dz + 1) * pw];
                if (st.nextInt(57) == 0) {
                    out[dz * w + dx] = if (c == 1) c + 128 else c;
                } else {
                    out[dz * w + dx] = c;
                }
            }
        }
    }
    // --- river_mix2 (axv). 1:1 fetch from both parents, no seeds.
    // initWorldGenSeed propagates to both parents (handled in initRec).
    fn evalRiverMix2(self: *Chain, st: *Base, idx: u32, hills: u32, river: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
        _ = idx;
        _ = st;
        const ph = try self.parentOut(alloc, hills, x, z, w, h);
        defer alloc.free(ph);
        const pr = try self.parentOut(alloc, river, x, z, w, h);
        defer alloc.free(pr);
        for (0..w * h) |i| {
            if (ph[i] == 0 or ph[i] == 24) {
                out[i] = ph[i];
                continue;
            }
            if (pr[i] == 7) {
                if (ph[i] == 12) {
                    out[i] = 11; // icePlains -> frozenRiver
                    continue;
                }
                if (ph[i] == 14 or ph[i] == 15) {
                    out[i] = 15; // mushroom -> mushroomShore
                    continue;
                }
                out[i] = pr[i] & 0xFF;
                continue;
            }
            out[i] = ph[i];
        }
    }
    // --- voronoi_zoom (ayb). Nearest-cell pick over jittered 4x4 grid.
    // NOTE: the two middle candidates are masked &0xFF while the outer two
    // are raw (verified in bytecode + CFR). x-=2 / z-=2 prologue included.
    fn evalVoronoi(self: *Chain, st: *Base, idx: u32, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
        _ = idx;
        const xx: i32 = x - 2;
        const zz: i32 = z - 2;
        const px: i32 = xx >> 2;
        const pz: i32 = zz >> 2;
        const pw: usize = @as(usize, @intCast(w >> 2)) + 2;
        const ph: usize = @as(usize, @intCast(h >> 2)) + 2;
        const p = try self.parentOut(alloc, parent, px, pz, pw, ph);
        defer alloc.free(p);
        const tw: usize = (pw - 1) << 2;
        const th: usize = (ph - 1) << 2;
        const tmp = try alloc.alloc(i32, tw * th);
        defer alloc.free(tmp);
        var n12: i32 = 0;
        var n13: i32 = 0;
        for (0..ph - 1) |gz| {
            n12 = p[0 + gz * pw];
            n13 = p[0 + (gz + 1) * pw];
            for (0..pw - 1) |gx| {
                // NOTE: << binds looser than + in Java: (gx+px)<<2.
                st.initChunkSeed((@as(i32, @intCast(@as(i64, @intCast(gx)) + px)) << 2), ((@as(i32, @intCast(@as(i64, @intCast(gz)) + pz)) << 2)));
                const d2: f64 = (@as(f64, @floatFromInt(st.nextInt(1024))) / 1024.0 - 0.5) * 3.6;
                const d3: f64 = (@as(f64, @floatFromInt(st.nextInt(1024))) / 1024.0 - 0.5) * 3.6;
                st.initChunkSeed(((@as(i32, @intCast(@as(i64, @intCast(gx)) + px + 1)) << 2)), (((@as(i32, @intCast(@as(i64, @intCast(gz)) + pz)) << 2))));
                const d4: f64 = (@as(f64, @floatFromInt(st.nextInt(1024))) / 1024.0 - 0.5) * 3.6 + 4.0;
                const d5: f64 = (@as(f64, @floatFromInt(st.nextInt(1024))) / 1024.0 - 0.5) * 3.6;
                st.initChunkSeed(((@as(i32, @intCast(@as(i64, @intCast(gx)) + px)) << 2)), (((@as(i32, @intCast(@as(i64, @intCast(gz)) + pz + 1)) << 2))));
                const d6: f64 = (@as(f64, @floatFromInt(st.nextInt(1024))) / 1024.0 - 0.5) * 3.6;
                const d7: f64 = (@as(f64, @floatFromInt(st.nextInt(1024))) / 1024.0 - 0.5) * 3.6 + 4.0;
                st.initChunkSeed(((@as(i32, @intCast(@as(i64, @intCast(gx)) + px + 1)) << 2)), (((@as(i32, @intCast(@as(i64, @intCast(gz)) + pz + 1)) << 2))));
                const d8: f64 = (@as(f64, @floatFromInt(st.nextInt(1024))) / 1024.0 - 0.5) * 3.6 + 4.0;
                const d9: f64 = (@as(f64, @floatFromInt(st.nextInt(1024))) / 1024.0 - 0.5) * 3.6 + 4.0;
                const n14: i32 = p[gx + 1 + gz * pw] & 0xFF;
                const n15: i32 = p[gx + 1 + (gz + 1) * pw] & 0xFF;
                for (0..4) |j| {
                    const jf: f64 = @floatFromInt(j);
                    const row_base = ((gz << 2) + j) * tw + (gx << 2);
                    for (0..4) |k| {
                        const kf: f64 = @floatFromInt(k);
                        const d10 = (jf - d3) * (jf - d3) + (kf - d2) * (kf - d2);
                        const d11 = (jf - d5) * (jf - d5) + (kf - d4) * (kf - d4);
                        const d12 = (jf - d7) * (jf - d7) + (kf - d6) * (kf - d6);
                        const d13 = (jf - d9) * (jf - d9) + (kf - d8) * (kf - d8);
                        tmp[row_base + k] = if (d10 < d11 and d10 < d12 and d10 < d13)
                            n12
                        else if (d11 < d10 and d11 < d12 and d11 < d13)
                            n14
                        else if (d12 < d10 and d12 < d11 and d12 < d13)
                            n13
                        else
                            n15;
                    }
                }
                n12 = n14;
                n13 = n15;
            }
        }
        const ox: usize = @as(usize, @intCast(@as(u32, @bitCast(xx)) & 3));
        const oz: usize = @as(usize, @intCast(@as(u32, @bitCast(zz)) & 3));
        for (0..h) |dz| {
            @memcpy(out[dz * w ..][0..w], tmp[(dz + oz) * tw + ox ..][0..w]);
        }
    }
};
test "genlayer matches JVM goldens (seed 1, 8x8 at origin)" {
    const alloc = std.testing.allocator;
    var built = try Chain.buildDefault(alloc, 1, false);
    defer built.chain.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();
    {
        const want = [_]i32{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,24,0,0,0,0,0,0,0,24,0,0,0,0,0,0,24,24,0,0,0,0,0,24,24,24,24,24,24,24,24,24,24,24};
        const buf = try scratch.alloc(i32, 64);
        try built.chain.getInts(scratch, built.roots[0], 0, 0, 8, 8, buf);
        try std.testing.expectEqualSlices(i32, &want, buf);
    }
    {
        const want = [_]i32{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
        const buf = try scratch.alloc(i32, 64);
        try built.chain.getInts(scratch, built.roots[1], 0, 0, 8, 8, buf);
        try std.testing.expectEqualSlices(i32, &want, buf);
    }
}
test "genlayer matches JVM goldens (seed 42, 8x8 at origin)" {
    const alloc = std.testing.allocator;
    var built = try Chain.buildDefault(alloc, 42, false);
    defer built.chain.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();
    {
        const want = [_]i32{12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12};
        const buf = try scratch.alloc(i32, 64);
        try built.chain.getInts(scratch, built.roots[0], 0, 0, 8, 8, buf);
        try std.testing.expectEqualSlices(i32, &want, buf);
    }
    {
        const want = [_]i32{12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12};
        const buf = try scratch.alloc(i32, 64);
        try built.chain.getInts(scratch, built.roots[1], 0, 0, 8, 8, buf);
        try std.testing.expectEqualSlices(i32, &want, buf);
    }
}
test "vanilla init quirk: hills river-mix zooms keep baseSeed 0" {
    const alloc = std.testing.allocator;
    var built = try Chain.buildDefault(alloc, 1, false);
    defer built.chain.deinit();
    // Layers 23,24 are magnify(river,1000,2) feeding river_mix.
    // axr has no initWorldGenSeed override (probe-verified), so vanilla
    // never initializes them. Replicating is load-bearing.
    try std.testing.expectEqual(@as(i64, 0), built.chain.states[23].base_seed);
    try std.testing.expectEqual(@as(i64, 0), built.chain.states[24].base_seed);
    // ...while the r3 copies with identical seeds ARE initialized.
    try std.testing.expect(built.chain.states[26].base_seed != 0);
    try std.testing.expect(built.chain.states[27].base_seed != 0);
}
