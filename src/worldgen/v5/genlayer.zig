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

/// One LCG step with additive salt (shared by every seed-mixing loop
/// below: init x3, initWorldGenSeed x3, initChunkSeed x2/cell, nextInt).
fn lcgStep(s: i64, salt: i64) i64 {
    var d = s *% (s *% LCG_MUL +% LCG_ADD);
    d +%= salt;
    return d;
}

pub const Base = struct {
    world_gen_seed: i64,
    base_seed: i64,
    chunk_seed: i64,

    pub fn init(world_gen_seed_raw: i64) Base {
        var b = world_gen_seed_raw;
        var i: usize = 0;
        while (i < 3) : (i += 1) b = lcgStep(b, world_gen_seed_raw);
        return .{ .world_gen_seed = b, .base_seed = 0, .chunk_seed = 0 };
    }

    pub fn initWorldGenSeed(self: *Base, seed: i64, parent: ?*Base) void {
        self.base_seed = seed;
        if (parent) |p| p.initWorldGenSeed(seed);
        var i: usize = 0;
        while (i < 3) : (i += 1) self.base_seed = lcgStep(self.base_seed, self.world_gen_seed);
    }

    pub fn initChunkSeed(self: *Base, x: i32, z: i32) void {
        var d: i64 = self.base_seed;
        const xs: i64 = x;
        const zs: i64 = z;
        var i: usize = 0;
        while (i < 2) : (i += 1) {
            d = lcgStep(d, xs);
            d = lcgStep(d, zs);
        }
        self.chunk_seed = d;
    }

    /// nextInt(n): (chunkSeed >> 24) % n with negative fixup, then advance.
    /// Arithmetic shift + truncated remainder, exactly like Java.
    pub fn nextInt(self: *Base, n: i32) i32 {
        std.debug.assert(n > 0);
        var r: i32 = @truncate(@rem(self.chunk_seed >> 24, @as(i64, n)));
        if (r < 0) r += n;
        self.chunk_seed = lcgStep(self.chunk_seed, self.base_seed);
        return r;
    }
};

// ---------------------------------------------------------------------------
// Shared predicates (axn statics).

pub fn areBiomesSimilar(a: i32, b: i32) bool {
    if (a == b) return true;
    const a_mp = a == mesa_plateau or a == mesa_plateau_f;
    const b_mp = b == mesa_plateau or b == mesa_plateau_f;
    if (a_mp or b_mp) return a_mp and b_mp;
    // NOTE: vanilla compares biome CLASSES (ahu.a = getClass equality),
    // NOT temperatures. Same-temp different-class pairs (forest vs hills)
    // are DISSIMILAR — a multi-hour bug caught by live JVM probing
    // (similar(21,3)=false). Groups from BiomeCls2 class dump.
    if (!validBiomeId(a) or !validBiomeId(b)) return false;
    const ca = biomeClass(a);
    const cb = biomeClass(b);
    if (ca == unknown_class or cb == unknown_class) return false;
    return ca == cb;
}

/// Mesa plateau pair (the only cross-id similarity vanilla checks first).
pub const mesa_plateau: i32 = 38;
pub const mesa_plateau_f: i32 = 39;
/// Highest registered 1.7.10 biome id (BiomeCls2 probe range 0..39).
pub const max_biome_id: i32 = 39;
/// biomeClass sentinel for unregistered ids.
pub const unknown_class: u8 = 255;

/// True for registered 1.7.10 biome ids (shared range gate).
pub fn validBiomeId(id: i32) bool {
    return id >= 0 and id <= max_biome_id;
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
        else => unknown_class,
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
            .fuzzy_zoom => try self.evalZoom(st, lay.parent, x, z, w, h, out, alloc, true),
            .zoom => try self.evalZoom(st, lay.parent, x, z, w, h, out, alloc, false),
            .add_island => try self.evalAddIsland(st, lay.parent, x, z, w, h, out, alloc),
            .remove_too_much_ocean => try self.evalRemoveOcean(st, lay.parent, x, z, w, h, out, alloc),
            .add_snow => try self.evalAddSnow(st, lay.parent, x, z, w, h, out, alloc),
            .edge_cool_warm => try self.evalEdge(st, lay.parent, x, z, w, h, out, alloc, .cool_warm),
            .edge_heat_ice => try self.evalEdge(st, lay.parent, x, z, w, h, out, alloc, .heat_ice),
            .edge_special => try self.evalEdgeSpecial(st, lay.parent, x, z, w, h, out, alloc),
            .mushroom_island => try self.evalMushroom(st, lay.parent, x, z, w, h, out, alloc),
            .deep_ocean => try self.evalDeepOcean(st, lay.parent, x, z, w, h, out, alloc),
            .river_init => try self.evalRiverInit(st, lay.parent, x, z, w, h, out, alloc),
            .river => try self.evalRiver(st, lay.parent, x, z, w, h, out, alloc),
            .river_mix => try self.evalRiverMix(st, lay.parent, lay.parent_b, x, z, w, h, out, alloc),
            .biome => try self.evalBiome(st, lay, x, z, w, h, out, alloc),
            .biome_edge => try self.evalBiomeEdge(st, lay.parent, x, z, w, h, out, alloc),
            .shore => try self.evalShore(st, lay.parent, x, z, w, h, out, alloc),
            .smooth => try self.evalSmooth(st, lay.parent, x, z, w, h, out, alloc),
            .rare_biome => try self.evalRareBiome(st, lay.parent, x, z, w, h, out, alloc),
            .river_mix2 => try self.evalRiverMix2(lay.parent, lay.parent_b, x, z, w, h, out, alloc),
            .voronoi_zoom => try self.evalVoronoi(st, lay.parent, x, z, w, h, out, alloc),
        }
    }

    fn parentOut(self: *Chain, alloc: std.mem.Allocator, idx: u32, x: i32, z: i32, w: usize, h: usize) anyerror![]i32 {
        const buf = try alloc.alloc(i32, w * h);
        errdefer alloc.free(buf);
        try self.getInts(alloc, idx, x, z, w, h, buf);
        return buf;
    }

    /// Parent fetch with the standard 1-cell padding (neighbor-sampling
    /// layers read (x-1, z-1, w+2, h+2)). Caller frees the buffer.
    fn parentPadded(self: *Chain, alloc: std.mem.Allocator, parent: u32, x: i32, z: i32, w: usize, h: usize) anyerror!struct { buf: []i32, pw: usize } {
        const buf = try self.parentOut(alloc, parent, x - 1, z - 1, w + 2, h + 2);
        return .{ .buf = buf, .pw = w + 2 };
    }

    /// Seed one cell's RNG (every neighbor-sampling layer opens its cell
    /// body this way).
    fn seedCell(st: *Base, x: i32, z: i32, dx: usize, dz: usize) void {
        st.initChunkSeed(x + @as(i32, @intCast(dx)), z + @as(i32, @intCast(dz)));
    }

    fn growRoll(st: *Base, center: i32) i32 {
        if (st.nextInt(5) == 0) return if (center == 4) 4 else 0;
        return center;
    }

    /// Reservoir pick over one non-zero neighbor (add_island growth): with
    /// probability 1/count the neighbor wins. Caller threads count/pick
    /// through the four neighbors in order.
    fn reservoirPick(st: *Base, count: *i32, pick: *i32, v: i32) void {
        if (v == 0) return;
        if (st.nextInt(count.*) == 0) pick.* = v;
        count.* += 1;
    }

    /// Zoom seed coord: grid index + parent offset, doubled (multiply
    /// AFTER the add — vanilla order, load-bearing for downstream draws).
    fn zoomSeedCoord(g: usize, p: i32) i32 {
        return @as(i32, @intCast(@as(i64, @intCast(g)) + p)) * 2;
    }

    // --- zoom (ayc) / fuzzy_zoom (axj). Fuzzy = pure random tie-break.
    fn evalZoom(self: *Chain, st: *Base, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator, fuzzy: bool) anyerror!void {
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
                st.initChunkSeed(zoomSeedCoord(gx, px), zoomSeedCoord(gz, pz));
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

    fn evalAddIsland(self: *Chain, st: *Base, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
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
                        reservoirPick(st, &count, &pick, v13);
                        reservoirPick(st, &count, &pick, v14);
                        reservoirPick(st, &count, &pick, v15);
                        reservoirPick(st, &count, &pick, v16);
                        if (st.nextInt(3) == 0) break :blk pick;
                        break :blk if (pick == 4) @as(i32, 4) else 0;
                    }
                    if (v13 == 0 or v14 == 0 or v15 == 0 or v16 == 0) break :blk growRoll(st, v17);
                    break :blk v17;
                };
            }
        }
    }

    fn evalRemoveOcean(self: *Chain, st: *Base, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
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
    fn evalAddSnow(self: *Chain, st: *Base, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
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
    fn evalEdge(self: *Chain, st: *Base, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator, mode: EdgeMode) anyerror!void {
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
    fn evalEdgeSpecial(self: *Chain, st: *Base, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
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
    fn evalMushroom(self: *Chain, st: *Base, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
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
    fn evalDeepOcean(self: *Chain, _: *Base, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
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
    fn evalRiverInit(self: *Chain, st: *Base, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
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
    fn evalRiver(self: *Chain, _: *Base, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
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
    fn evalRiverMix(self: *Chain, st: *Base, b: u32, r: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
        const pb = try self.parentOut(alloc, b, x - 1, z - 1, w + 2, h + 2);
        defer alloc.free(pb);
        const pr = try self.parentOut(alloc, r, x - 1, z - 1, w + 2, h + 2);
        defer alloc.free(pr);
        const pw = w + 2;
        for (0..h) |dz| {
            for (0..w) |dx| {
                seedCell(st, x, z, dx, dz);
                const v10 = pb[dx + 1 + (dz + 1) * pw];
                const v11 = pr[dx + 1 + (dz + 1) * pw];
                const riverish = v11 >= 2 and @rem(v11 - 2, 29) == 1;
                // Lake marker (vanilla axr flag): (v11-2)%29==0 drives the
                // hills gate and the +128 mutated fallback (jar `axr`, not
                // the river marker — a live-parity find: jungle blobs stayed
                // jungle where the river flag upgraded them to jungleHills).
                const lakeish = @rem(v11 - 2, 29) == 0;
                var v13: i32 = v10;
                if (mixEarly(st, v10, riverish, lakeish, &v13)) |v| {
                    out[dz * w + dx] = v;
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

    /// Early river-mix claims (mutated variant + hills gate): returns the
    /// output when claimed, null to fall through to the similarity vote
    /// (writing the hills result to `v13_out` for the vote to reuse —
    /// recomputing it would draw RNG twice for plains/deepOcean).
    /// Draw order matches vanilla exactly (gate nextInt(3), then the
    /// hillsVariant draws for plains/deepOcean). Vanilla `axr` gate and
    /// mutated fallback both key on the LAKE marker ((v11-2)%29==0), never
    /// the river marker: lake cells upgrade unconditionally, then revert to
    /// the base biome when +128 has no registry entry (e.g. jungle 21 stays
    /// 21 because 150 is unassigned). The river claim draws no roll.
    fn mixEarly(st: *Base, v10: i32, riverish: bool, lakeish: bool, v13_out: *i32) ?i32 {
        // River claim (no roll drawn): mutated variant when it exists, else
        // the biome itself. Vanilla has no v10!=0 guard — ocean+river keeps
        // 0 because +128 has no registry entry.
        if (riverish and v10 < 128) {
            return if (biome.biomeExists(v10 + 128)) v10 + 128 else v10;
        }
        var v13 = v10;
        if (st.nextInt(3) == 0 or lakeish) {
            v13 = hillsVariant(v10, st);
            // Mutated fallback only on lake cells (vanilla axr 648-687);
            // a missing +128 reverts to the base biome, then vote/store below.
            if (lakeish and v13 != v10) {
                if (!biome.biomeExists(v13 + 128)) return v10;
                v13 += 128;
            }
        } else {
            return v10;
        }
        if (v13 == v10) return v10;
        v13_out.* = v13;
        return null;
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
    /// SPECIAL tag: low 8 bits kept, bits 8-11 cleared on read.
    const variant_keep_mask: u32 = 0xFFFFF0FF;
    /// SPECIAL tag extract: bits 8-11.
    const variant_tag_mask: i32 = 0xF00;
    const variant_tag_shift = 8;
    fn evalBiome(self: *Chain, st: *Base, lay: Layer, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
        const p = try self.parentOut(alloc, lay.parent, x, z, w, h);
        defer alloc.free(p);
        for (0..h) |dz| {
            for (0..w) |dx| {
                st.initChunkSeed(x + @as(i32, @intCast(dx)), z + @as(i32, @intCast(dz)));
                var v5 = p[dz * w + dx];
                const v6: i32 = (v5 & variant_tag_mask) >> variant_tag_shift;
                v5 &= @as(i32, @bitCast(variant_keep_mask));
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
    fn evalBiomeEdge(self: *Chain, st: *Base, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
        const p = try self.parentOut(alloc, parent, x - 1, z - 1, w + 2, h + 2);
        defer alloc.free(p);
        const pw = w + 2;
        for (0..h) |dz| {
            for (0..w) |dx| {
                st.initChunkSeed(x + @as(i32, @intCast(dx)), z + @as(i32, @intCast(dz)));
                const c = p[dx + 1 + (dz + 1) * pw];
                if (edgeClaim(p, out, dx, dz, w, c, 3, 20, false)) continue;
                if (edgeClaim(p, out, dx, dz, w, c, 38, 37, true)) continue;
                if (edgeClaim(p, out, dx, dz, w, c, 39, 37, true)) continue;
                if (edgeClaim(p, out, dx, dz, w, c, 32, 5, true)) continue;
                if (c == 2) {
                    const nb = edgeNeighbors(p, dx, dz, w + 2);
                    // NOTE: CFR order is N,E,W,S but any-of-4 is order-free.
                    if (nb[0] == 12 or nb[1] == 12 or nb[2] == 12 or nb[3] == 12) {
                        out[dz * w + dx] = 34; // extremeHillsPlus
                        continue;
                    }
                    out[dz * w + dx] = c;
                    continue;
                }
                if (c == 6) {
                    const nb = edgeNeighbors(p, dx, dz, w + 2);
                    const n = nb[0];
                    const e = nb[1];
                    const wv = nb[2];
                    const ss = nb[3];
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

    /// Orthogonal neighbors (N,E,W,S) of a padded-parent cell.
    fn edgeNeighbors(p: []i32, dx: usize, dz: usize, pw: usize) [4]i32 {
        return .{
            p[dx + 1 + dz * pw],
            p[dx + 2 + (dz + 1) * pw],
            p[dx + (dz + 1) * pw],
            p[dx + 1 + (dz + 2) * pw],
        };
    }

    /// Biome-edge claim helper (axe a/b): `strict` selects the == claim +
    /// areBiomesSimilar neighbor test (edgeB) vs the similarity claim +
    /// edgeSimilar neighbor test (edgeA). Writes out[idx] and returns true
    /// when the cell is claimed.
    fn edgeClaim(p: []i32, out: []i32, dx: usize, dz: usize, w: usize, c: i32, target: i32, repl: i32, strict: bool) bool {
        if (strict) {
            if (c != target) return false;
        } else {
            if (!areBiomesSimilar(c, target)) return false;
        }
        const nb = edgeNeighbors(p, dx, dz, w + 2);
        for (nb) |v| {
            const ok = if (strict) areBiomesSimilar(v, target) else edgeSimilar(v, target);
            if (!ok) {
                out[dz * w + dx] = repl;
                return true;
            }
        }
        out[dz * w + dx] = c;
        return true;
    }

    /// axe.b(int,int): similarity with temp-category fallback.
    /// areBiomesSimilar first; else both-registered and
    /// (temps equal OR either temp is MEDIUM — ahw.c wildcard, CFR-verified;
    /// this makes medium-target checks nearly always pass).
    fn edgeSimilar(a: i32, b: i32) bool {
        if (areBiomesSimilar(a, b)) return true;
        if (!validBiomeId(a) or !validBiomeId(b)) return false;
        const ba = biome.BIOMES[@as(usize, @intCast(a))] orelse return false;
        const bb = biome.BIOMES[@as(usize, @intCast(b))] orelse return false;
        return ba.temp == bb.temp or ba.temp == .medium or bb.temp == .medium;
    }
    // --- shore (axw).
    fn evalShore(self: *Chain, st: *Base, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
        const pad = try self.parentPadded(alloc, parent, x, z, w, h);
        const p = pad.buf;
        defer alloc.free(p);
        const pw = pad.pw;
        for (0..h) |dz| {
            for (0..w) |dx| {
                seedCell(st, x, z, dx, dz);
                const c = p[dx + 1 + (dz + 1) * pw];
                // Four orthogonal neighbors, fetched once per cell.
                const nb = edgeNeighbors(p, dx, dz, pw);
                if (c == 14) {
                    if (nb[0] == 0 or nb[1] == 0 or nb[2] == 0 or nb[3] == 0) {
                        out[dz * w + dx] = 15; // mushroomIslandShore
                        continue;
                    }
                    out[dz * w + dx] = c;
                    continue;
                }
                if (isJungle(c)) {
                    if (!(shoreC(nb[0]) and shoreC(nb[1]) and shoreC(nb[2]) and shoreC(nb[3]))) {
                        out[dz * w + dx] = 23; // jungleEdge
                        continue;
                    }
                    if (isOceanic(nb[0]) or isOceanic(nb[1]) or isOceanic(nb[2]) or isOceanic(nb[3])) {
                        out[dz * w + dx] = 16; // beach
                        continue;
                    }
                    out[dz * w + dx] = c;
                    continue;
                }
                if (c == 3 or c == 34 or c == 20) {
                    shoreA(p, out, dx, dz, w, c, 25); // stoneBeach
                    continue;
                }
                if (isSnowy(c)) {
                    shoreA(p, out, dx, dz, w, c, 26); // coldBeach
                    continue;
                }
                if (c == 37 or c == 38) {
                    if (isOceanic(nb[0]) or isOceanic(nb[1]) or isOceanic(nb[2]) or isOceanic(nb[3])) {
                        out[dz * w + dx] = c;
                        continue;
                    }
                    if (!(isMesa(nb[0]) and isMesa(nb[1]) and isMesa(nb[2]) and isMesa(nb[3]))) {
                        out[dz * w + dx] = 2; // desert
                        continue;
                    }
                    out[dz * w + dx] = c;
                    continue;
                }
                if (c != 0 and c != 24 and c != 7 and c != 6) {
                    if (isOceanic(nb[0]) or isOceanic(nb[1]) or isOceanic(nb[2]) or isOceanic(nb[3])) {
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

    fn shoreA(p: []i32, out: []i32, dx: usize, dz: usize, w: usize, c: i32, repl: i32) void {
        if (isOceanic(c)) {
            out[dz * w + dx] = c;
            return;
        }
        const nb = edgeNeighbors(p, dx, dz, w + 2);
        for (nb) |v| {
            if (isOceanic(v)) {
                out[dz * w + dx] = repl;
                return;
            }
        }
        out[dz * w + dx] = c;
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
        if (!validBiomeId(id)) return isOceanic(id);
        if (biome.BIOMES[@as(usize, @intCast(id))] == null) return isOceanic(id);
        return isJungle(id) or id == 4 or id == 5 or isOceanic(id);
    }
    // --- smooth (axx). NOTE: initChunkSeed ONLY in the both-equal branch.
    fn evalSmooth(self: *Chain, st: *Base, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
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
    fn evalRareBiome(self: *Chain, st: *Base, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
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
    fn evalRiverMix2(self: *Chain, hills: u32, river: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
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
                out[i] = 7; // pr[i] == 7 here (branch guard); &0xFF is a no-op
                continue;
            }
            out[i] = ph[i];
        }
    }
    /// Voronoi grid coord: grid index + parent offset, quadrupled (Java
    /// `<<` binds looser than `+`: (gx+px)<<2 — replicate exactly).
    fn gridCoord(g: usize, p: i32) i32 {
        return @as(i32, @intCast(@as(i64, @intCast(g)) + p)) << 2;
    }

    /// One voronoi jitter draw: two nextInt(1024) samples scaled to
    /// [-1.8, 1.8), plus 4.0 on the far axes (cells gx+1 / gz+1).
    fn voronoiJitter(st: *Base, gx: usize, px: i32, ox: i32, gz: usize, pz: i32, oz: i32) struct { jx: f64, jz: f64 } {
        st.initChunkSeed(gridCoord(gx, px + ox), gridCoord(gz, pz + oz));
        // /1024.0 is an exact power-of-two scale (samples < 1024 exactly
        // representable): multiply by the exact reciprocal instead.
        const jx = (@as(f64, @floatFromInt(st.nextInt(1024))) * 0.0009765625 - 0.5) * 3.6 + @as(f64, if (ox == 1) 4.0 else 0.0);
        const jz = (@as(f64, @floatFromInt(st.nextInt(1024))) * 0.0009765625 - 0.5) * 3.6 + @as(f64, if (oz == 1) 4.0 else 0.0);
        return .{ .jx = jx, .jz = jz };
    }

    /// Nearest of the four jittered corners (strict-< chain, vanilla order).
    fn nearestCorner(d10: f64, d11: f64, d12: f64, d13: f64, n12: i32, n14: i32, n13: i32, n15: i32) i32 {
        if (d10 < d11 and d10 < d12 and d10 < d13) return n12;
        if (d11 < d10 and d11 < d12 and d11 < d13) return n14;
        if (d12 < d10 and d12 < d11 and d12 < d13) return n13;
        return n15;
    }

    // --- voronoi_zoom (ayb). Nearest-cell pick over jittered 4x4 grid.
    // NOTE: the two middle candidates are masked &0xFF while the outer two
    // are raw (verified in bytecode + CFR). x-=2 / z-=2 prologue included.
    fn evalVoronoi(self: *Chain, st: *Base, parent: u32, x: i32, z: i32, w: usize, h: usize, out: []i32, alloc: std.mem.Allocator) anyerror!void {
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
                const j00 = voronoiJitter(st, gx, px, 0, gz, pz, 0);
                const j10 = voronoiJitter(st, gx, px, 1, gz, pz, 0);
                const j01 = voronoiJitter(st, gx, px, 0, gz, pz, 1);
                const j11 = voronoiJitter(st, gx, px, 1, gz, pz, 1);
                const n14: i32 = p[gx + 1 + gz * pw] & 0xFF;
                const n15: i32 = p[gx + 1 + (gz + 1) * pw] & 0xFF;
                for (0..4) |j| {
                    const jf: f64 = @floatFromInt(j);
                    const row_base = ((gz << 2) + j) * tw + (gx << 2);
                    for (0..4) |k| {
                        const kf: f64 = @floatFromInt(k);
                        const d10 = (jf - j00.jz) * (jf - j00.jz) + (kf - j00.jx) * (kf - j00.jx);
                        const d11 = (jf - j10.jz) * (jf - j10.jz) + (kf - j10.jx) * (kf - j10.jx);
                        const d12 = (jf - j01.jz) * (jf - j01.jz) + (kf - j01.jx) * (kf - j01.jx);
                        const d13 = (jf - j11.jz) * (jf - j11.jz) + (kf - j11.jx) * (kf - j11.jx);
                        tmp[row_base + k] = nearestCorner(d10, d11, d12, d13, n12, n14, n13, n15);
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
