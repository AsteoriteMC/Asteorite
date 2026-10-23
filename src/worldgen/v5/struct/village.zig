//! Village (vanilla `avn` MapGen + `avo` start + `avp` piece factory +
//! `awd`/`awe`/`awf`/`awa` bases + pieces `avq avr avs avt avv avw avx
//! `avy avz awb awc`, jar-verified verbatim, including RNG order).
//!
//! Spacing 32, separation 8, salt 10387312 (`avn`). Start = well (`awf`
//! subclass `awa`) at `((sx<<4)+2, (sz<<4)+2)` + road/house expansion.
//! Every house levels itself to the averaged topY on first placement
//! (`awd.b`); roads stamp absolute columns with no leveling. Desert
//! villages (well biome desert/desertHills) swap wood/cobble/gravel for
//! sandstone via the `awd.b/c` map, applied to every placement.
//!
//! `avp` factory weights/limits (size 0 default; `qh.a` inclusive):
//!   hut/ViSH        w=4  lim=qh(2+s, 4+2s)
//!   church/ViST     w=20 lim=qh(0+s, 1+s)
//!   big house/ViBH  w=20 lim=qh(0+s, 2+s)
//!   smithy-small/ViSmH w=3 lim=qh(2+s, 5+3s)
//!   small house/ViPH w=15 lim=qh(0+s, 2+s)
//!   farm-large/ViDF w=3  lim=qh(1+s, 4+s)
//!   farm-small/ViF  w=3  lim=qh(2+s, 4+2s)
//!   smithy/ViS      w=15 lim=qh(0, 1+s)
//!   town-hall/ViTRH w=8  lim=qh(0+s, 3+2s)
//! Zero-limit entries are dropped before building. Lamp/ViL is the
//! fallback when 5 weighted picks fail (no weight entry).

const ids = @import("../../../ids.zig");
const bbox_mod = @import("bbox.zig");
const comp_mod = @import("comp.zig");
const loot_mod = @import("loot.zig");
const mapgen_mod = @import("mapgen.zig");
const placer_mod = @import("placer.zig");
const java_random = @import("../../rng/java_random.zig");

pub const BBox = bbox_mod.BBox;
pub const Component = comp_mod.Component;
pub const Facing = bbox_mod.Facing;
pub const Placer = placer_mod.Placer;
pub const JavaRandom = java_random.JavaRandom;
pub const BioCtx = mapgen_mod.BioCtx;

/// canSpawn for a start-chunk (`avn.a`): spaced cell + plains/desert/
/// savanna check at the center column.
pub fn canSpawn(bio: BioCtx, alloc: std.mem.Allocator, world_seed: i64, sx: i32, sz: i32) bool {
    return mapgen_mod.villageCanSpawn(bio, alloc, world_seed, sx, sz);
}

pub const Kind = enum {
    well,
    big_house,
    farm_large,
    farm_small,
    lamp,
    small_house,
    hut,
    smithy_small,
    church,
    smithy,
    town_hall,
    road,
};

const Piece = struct {
    kind: Kind,
    mode: Facing,
    box: BBox,
    depth: i32,
    k: i32 = -1,
    desert: bool,
    crops: [4]ids.Id = .{ .wheat_block, .wheat_block, .wheat_block, .wheat_block },
    terrace: bool = false,
    table: i32 = 0,
    chest: bool = false,
    road_len: i32 = 0,
};

const Weight = struct {
    kind: Kind,
    w: i32,
    n: i32,
    lim: i32,
};

const MAX_PIECES: usize = 1024;

const State = struct {
    pieces: [MAX_PIECES]Piece = undefined,
    n: usize = 0,
    weights: [9]Weight = undefined,
    nw: usize = 0,
    last: ?usize = null,
    pend_h: [MAX_PIECES]usize = undefined,
    nh: usize = 0,
    pend_r: [MAX_PIECES]usize = undefined,
    nr: usize = 0,
    well_x: i32 = 0,
    well_z: i32 = 0,
    desert: bool = false,
};

/// `qh.a(Random,int,int)`: min + nextInt(max-min+1), inclusive; min when
/// min >= max.
fn qh(rand: *JavaRandom, min: i32, max: i32) i32 {
    if (min >= max) return min;
    return min + (rand.nextIntBound(max - min + 1) catch unreachable);
}

/// Desert material map (`awd.b`): block swap. NOTE gravel is NOT mapped
/// (vanilla leaves it); iron ore maps to sandstone.
fn mapId(desert: bool, id: ids.Id) ids.Id {
    if (!desert) return id;
    return switch (id) {
        .log, .log2, .cobblestone => .sandstone,
        .iron_ore => .sandstone,
        .planks => .sandstone,
        .oak_stairs, .stone_stairs => .sandstone_stairs,
        else => id,
    };
}

/// Desert material map (`awd.c`): meta swap.
fn mapMeta(desert: bool, id: ids.Id, meta: u4) u4 {
    if (!desert) return meta;
    return switch (id) {
        .log, .log2, .cobblestone => 0,
        .planks => 2,
        else => meta,
    };
}

/// Raw single placement through the desert map (vanilla `awd.a`
/// single-block wrapper: no rotation; callers pre-rotate).
fn put(p: Placer, c: Component, clip: BBox, desert: bool, id: ids.Id, meta: u4, x: i32, y: i32, z: i32) void {
    comp_mod.placeAt(p, c, clip, mapId(desert, id), mapMeta(desert, id, meta), x, y, z);
}

/// Fill through the desert map (vanilla `awd.a` fill wrapper maps both
/// blocks and their metas, e.g. planks fill -> sandstone:2).
fn fill(p: Placer, c: Component, clip: BBox, desert: bool, x0: i32, y0: i32, z0: i32, x1: i32, y1: i32, z1: i32, edge: ids.Id, fill_id: ids.Id) void {
    comp_mod.fillBoxMeta(p, c, clip, x0, y0, z0, x1, y1, z1, mapId(desert, edge), mapMeta(desert, edge, 0), mapId(desert, fill_id), mapMeta(desert, fill_id, 0), false);
}

/// Stairs/ladder placement with vanilla-style pre-rotation
/// (`this.a(B, this.a(B, m), x, y, z, box)` call shape).
fn putRot(p: Placer, c: Component, clip: BBox, desert: bool, id: ids.Id, base: u4, x: i32, y: i32, z: i32) void {
    put(p, c, clip, desert, id, comp_mod.rotateMeta(id, base, c.mode), x, y, z);
}

/// Downward fill through the desert map (`awd.b` block wrapper).
fn fdn(p: Placer, c: Component, clip: BBox, desert: bool, id: ids.Id, meta: u4, x: i32, y: i32, z: i32) void {
    comp_mod.fillDownwards(p, c, clip, mapId(desert, id), mapMeta(desert, id, meta), x, y, z);
}

/// Upward clear (`avk.b` int overload).
fn cup(p: Placer, c: Component, clip: BBox, x: i32, y: i32, z: i32) void {
    comp_mod.clearUpwards(p, c, clip, x, y, z);
}

/// Wooden door (`this.a(world, box, rand, x, y, z, this.a(ao, 1))`).
fn door(p: Placer, c: Component, clip: BBox, desert: bool, x: i32, y: i32, z: i32) void {
    comp_mod.placeDoor(p, c, clip, x, y, z, 1, mapId(desert, .wooden_door_block));
}

/// Door-step cobble stair (`(x,0,-1)` iff air over non-air).
fn maybeStep(p: Placer, c: Component, clip: BBox, desert: bool, x: i32, z: i32) void {
    if (comp_mod.getAt(p, c, clip, x, 0, z).id == .air and
        comp_mod.getAt(p, c, clip, x, -1, z).id != .air)
    {
        putRot(p, c, clip, desert, .stone_stairs, 3, x, 0, z);
    }
}

/// Villager row (`awd.a(world, box, x, y, z, count)`): break on first
/// outside-clip spot; profession values are runtime-only (no RNG, hook
/// carries kind only).
fn spawnRow(p: Placer, c: Component, clip: BBox, x0: i32, y: i32, z0: i32, n: i32) void {
    var j: i32 = 0;
    while (j < n) : (j += 1) {
        const wx = c.xWithOffset(x0 + j, z0);
        const wy = c.yWithOffset(y);
        const wz = c.zWithOffset(x0 + j, z0);
        if (!clip.contains(wx, wy, wz)) break;
        p.spawn(.villager, @as(f64, @floatFromInt(wx)) + 0.5, @as(f64, @floatFromInt(wy)), @as(f64, @floatFromInt(wz)) + 0.5);
    }
}

/// Ground average (`awd.b`): max(topY, provider avg) over box columns
/// inside the clip; null when no column is inside.
fn groundAvg(p: Placer, box: BBox, clip: BBox) ?i32 {
    var sum: i64 = 0;
    var n: i64 = 0;
    var z = box.min_z;
    while (z <= box.max_z) : (z += 1) {
        var x = box.min_x;
        while (x <= box.max_x) : (x += 1) {
            if (!clip.contains(x, 64, z)) continue;
            sum += @max(p.topY(x, z), p.groundBase());
            n += 1;
        }
    }
    if (n == 0) return null;
    return @intCast(@divTrunc(sum, n));
}

/// Crop pick (`avr`/`avs` ctor): nextInt(5): 0 carrots, 1 potatoes, else
/// wheat (ajn.bM=carrots 141, ajn.bN=potatoes 142, ajn.aj=wheat 59).
fn pickCrop(rand: *JavaRandom) ids.Id {
    return switch (rand.nextIntBound(5) catch unreachable) {
        0 => .carrots,
        1 => .potatoes,
        else => .wheat_block,
    };
}

// ---------------------------------------------------------------------------
// Build phase.
// ---------------------------------------------------------------------------

fn findHit(st: *State, box: BBox) ?usize {
    var i: usize = 0;
    while (i < st.n) : (i += 1) {
        if (st.pieces[i].box.intersects(box)) return i;
    }
    return null;
}

fn appendPiece(st: *State, pc: Piece) usize {
    std.debug.assert(st.n < MAX_PIECES);
    st.pieces[st.n] = pc;
    const idx = st.n;
    st.n += 1;
    return idx;
}

const Dims = struct { w: i32, h: i32, d: i32 };

fn dimsOf(kind: Kind) Dims {
    return switch (kind) {
        .big_house => .{ .w = 9, .h = 9, .d = 6 },
        .farm_large => .{ .w = 13, .h = 4, .d = 9 },
        .farm_small => .{ .w = 7, .h = 4, .d = 9 },
        .lamp => .{ .w = 3, .h = 4, .d = 2 },
        .small_house => .{ .w = 9, .h = 7, .d = 11 },
        .hut => .{ .w = 5, .h = 6, .d = 5 },
        .smithy_small => .{ .w = 4, .h = 6, .d = 5 },
        .church => .{ .w = 5, .h = 12, .d = 9 },
        .smithy => .{ .w = 10, .h = 6, .d = 7 },
        .town_hall => .{ .w = 9, .h = 7, .d = 12 },
        .well, .road => unreachable,
    };
}

/// Factory (`avp.a(awa,avu,...)` per-class `a`): oriented box, height +
/// intersection checks, then construction draws (crops / terrace /
/// table), else null.
fn factory(st: *State, rand: *JavaRandom, kind: Kind, x: i32, y: i32, z: i32, facing: Facing, depth: i32) ?Piece {
    const dm = dimsOf(kind);
    const box = bbox_mod.orientedBox(x, y, z, dm.w, dm.h, dm.d, facing);
    if (kind != .lamp and kind != .hut) {
        if (!(box.max_y > 10)) return null;
    }
    if (findHit(st, box) != null) return null;
    var pc = Piece{ .kind = kind, .mode = facing, .box = box, .depth = depth, .desert = st.desert };
    switch (kind) {
        .farm_large => {
            pc.crops[0] = pickCrop(rand);
            pc.crops[1] = pickCrop(rand);
            pc.crops[2] = pickCrop(rand);
            pc.crops[3] = pickCrop(rand);
        },
        .farm_small => {
            pc.crops[0] = pickCrop(rand);
            pc.crops[1] = pickCrop(rand);
        },
        .hut => {
            pc.terrace = rand.nextBoolean();
        },
        .smithy_small => {
            pc.terrace = rand.nextBoolean();
            pc.table = rand.nextIntBound(3) catch unreachable;
        },
        else => {},
    }
    return pc;
}

/// Weighted 5-try house pick (`avp.c`); lamp fallback (`avt.a` + new).
/// Weight bookkeeping applies even if the caller later drops the piece
/// on the biome check.
fn housePick(st: *State, rand: *JavaRandom, x: i32, y: i32, z: i32, facing: Facing, depth: i32) ?Piece {
    var total: i32 = 0;
    var any = false;
    for (st.weights[0..st.nw]) |e| {
        if (e.lim > 0 and e.n < e.lim) any = true;
        total += e.w;
    }
    if (!any) return null;
    var tries: i32 = 0;
    while (tries < 5) : (tries += 1) {
        var roll = rand.nextIntBound(total) catch unreachable;
        for (st.weights[0..st.nw], 0..) |*e, wi| {
            roll -= e.w;
            if (roll < 0) {
                const avail = e.lim == 0 or e.n < e.lim;
                if (!avail or (st.last != null and st.last.? == e.kind and st.nw > 1)) break;
                if (factory(st, rand, e.kind, x, y, z, facing, depth)) |pc| {
                    e.n += 1;
                    st.last = e.kind;
                    if (!(e.lim == 0 or e.n < e.lim)) {
                        // `e.remove(avu)`: drop the exhausted entry; the
                        // stored last-piece no longer matches any entry.
                        var k: usize = wi + 1;
                        while (k < st.nw) : (k += 1) st.weights[k - 1] = st.weights[k];
                        st.nw -= 1;
                        st.last = null;
                    }
                    return pc;
                }
            }
        }
    }
    // Lamp fallback: no height gate beyond avt.a (intersect only).
    const box = bbox_mod.orientedBox(x, y, z, 3, 4, 2, facing);
    if (findHit(st, box) != null) return null;
    return Piece{ .kind = .lamp, .mode = facing, .box = box, .depth = depth, .desert = st.desert };
}

/// House branch (`avp.d`): depth + 112-range gates, pick, center/radius
/// biome gate, append to pieces + house pending.
fn housePath(st: *State, bio: BioCtx, alloc: std.mem.Allocator, rand: *JavaRandom, x: i32, y: i32, z: i32, facing: Facing, depth: i32) ?usize {
    if (depth > 50) return null;
    if (@abs(x - st.well_x) > 112 or @abs(z - st.well_z) > 112) return null;
    const pc = housePick(st, rand, x, y, z, facing, depth + 1) orelse return null;
    const cx = @divTrunc(pc.box.min_x + pc.box.max_x, 2);
    const cz = @divTrunc(pc.box.min_z + pc.box.max_z, 2);
    const spx = pc.box.max_x - pc.box.min_x;
    const spz = pc.box.max_z - pc.box.min_z;
    const rad = @divTrunc(@max(spx, spz), 2) + 4;
    if (!mapgen_mod.areBiomesViable(bio, alloc, cx, cz, rad, &mapgen_mod.village_biomes)) return null;
    const idx = appendPiece(st, pc);
    std.debug.assert(st.nh < MAX_PIECES);
    st.pend_h[st.nh] = idx;
    st.nh += 1;
    return idx;
}

/// Road box attempt (`awb.a`): lengths 7*qh(3,5) down to 7.
fn roadBox(st: *State, rand: *JavaRandom, x: i32, y: i32, z: i32, facing: Facing) ?BBox {
    var len: i32 = 7 * qh(rand, 3, 5);
    while (len >= 7) : (len -= 7) {
        const box = bbox_mod.orientedBox(x, y, z, 3, 3, len, facing);
        if (findHit(st, box) == null) return box;
    }
    return null;
}

/// Road branch (`avp.e`): depth + 112-range gates, longest fitting box,
/// minY gate, biome gate, append to pieces + road pending.
fn roadPath(st: *State, bio: BioCtx, alloc: std.mem.Allocator, rand: *JavaRandom, x: i32, y: i32, z: i32, facing: Facing, depth: i32) ?usize {
    if (depth > 3) return null; // 3 + size, size is always 0
    if (@abs(x - st.well_x) > 112 or @abs(z - st.well_z) > 112) return null;
    const box = roadBox(st, rand, x, y, z, facing) orelse return null;
    if (!(box.min_y > 10)) return null;
    const cx = @divTrunc(box.min_x + box.max_x, 2);
    const cz = @divTrunc(box.min_z + box.min_z, 2);
    const spx = box.max_x - box.min_x;
    const spz = box.max_z - box.min_z;
    const rad = @divTrunc(@max(spx, spz), 2) + 4;
    if (!mapgen_mod.areBiomesViable(bio, alloc, cx, cz, rad, &mapgen_mod.village_biomes)) return null;
    const idx = appendPiece(st, Piece{
        .kind = .road,
        .mode = facing,
        .box = box,
        .depth = depth,
        .desert = st.desert,
        .road_len = @max(box.max_x - box.min_x + 1, box.max_z - box.min_z + 1),
    });
    std.debug.assert(st.nr < MAX_PIECES);
    st.pend_r[st.nr] = idx;
    st.nr += 1;
    return idx;
}

/// NN attach (`awd.a`): cases 0/2 and 1/3 identical (jar-verbatim).
fn attachNN(st: *State, bio: BioCtx, alloc: std.mem.Allocator, rand: *JavaRandom, parent: usize, yoff: i32, zoff: i32) ?usize {
    const b = st.pieces[parent].box;
    const m = st.pieces[parent].mode;
    const d = st.pieces[parent].depth;
    return switch (m) {
        .south, .north => housePath(st, bio, alloc, rand, b.min_x - 1, b.min_y + yoff, b.min_z + zoff, .west, d),
        .west, .east => housePath(st, bio, alloc, rand, b.min_x + zoff, b.min_y + yoff, b.min_z - 1, .north, d),
    };
}

/// PP attach (`awd.b`): cases 0/2 and 1/3 identical (jar-verbatim).
fn attachPP(st: *State, bio: BioCtx, alloc: std.mem.Allocator, rand: *JavaRandom, parent: usize, yoff: i32, zoff: i32) ?usize {
    const b = st.pieces[parent].box;
    const m = st.pieces[parent].mode;
    const d = st.pieces[parent].depth;
    return switch (m) {
        .south, .north => housePath(st, bio, alloc, rand, b.max_x + 1, b.min_y + yoff, b.min_z + zoff, .east, d),
        .west, .east => housePath(st, bio, alloc, rand, b.min_x + zoff, b.min_y + yoff, b.max_z + 1, .south, d),
    };
}

/// Well expansion (`awf.a`): four road branches at fixed offsets.
fn expandWell(st: *State, bio: BioCtx, alloc: std.mem.Allocator, rand: *JavaRandom) void {
    const b = st.pieces[0].box;
    const d = st.pieces[0].depth;
    _ = roadPath(st, bio, alloc, rand, b.min_x - 1, b.max_y - 4, b.min_z + 1, .west, d);
    _ = roadPath(st, bio, alloc, rand, b.max_x + 1, b.max_y - 4, b.min_z + 1, .east, d);
    _ = roadPath(st, bio, alloc, rand, b.min_x + 1, b.max_y - 4, b.min_z - 1, .north, d);
    _ = roadPath(st, bio, alloc, rand, b.min_x + 1, b.max_y - 4, b.max_z + 1, .south, d);
}

/// Road expansion (`awb.a`): side loops both directions, then up to two
/// onward branches gated by nextInt(3) > 0.
fn expandRoad(st: *State, bio: BioCtx, alloc: std.mem.Allocator, rand: *JavaRandom, idx: usize) void {
    var attached = false;
    var s: i32 = rand.nextIntBound(5) catch unreachable;
    const len = st.pieces[idx].road_len;
    while (s < len - 8) {
        if (attachNN(st, bio, alloc, rand, idx, 0, s)) |c| {
            const cb = st.pieces[c].box;
            s += @max(cb.max_x - cb.min_x + 1, cb.max_z - cb.min_z + 1);
            attached = true;
        }
        s += 2 + (rand.nextIntBound(5) catch unreachable);
    }
    var t: i32 = rand.nextIntBound(5) catch unreachable;
    while (t < len - 8) {
        if (attachPP(st, bio, alloc, rand, idx, 0, t)) |c| {
            const cb = st.pieces[c].box;
            t += @max(cb.max_x - cb.min_x + 1, cb.max_z - cb.min_z + 1);
            attached = true;
        }
        t += 2 + (rand.nextIntBound(5) catch unreachable);
    }
    const b = st.pieces[idx].box;
    const d = st.pieces[idx].depth;
    if (attached and (rand.nextIntBound(3) catch unreachable) > 0) {
        switch (st.pieces[idx].mode) {
            .south => _ = roadPath(st, bio, alloc, rand, b.min_x - 1, b.min_y, b.max_z - 2, .west, d),
            .west => _ = roadPath(st, bio, alloc, rand, b.min_x, b.min_y, b.min_z - 1, .north, d),
            .north => _ = roadPath(st, bio, alloc, rand, b.min_x - 1, b.min_y, b.min_z, .west, d),
            .east => _ = roadPath(st, bio, alloc, rand, b.max_x - 2, b.min_y, b.min_z - 1, .north, d),
        }
    }
    if (attached and (rand.nextIntBound(3) catch unreachable) > 0) {
        switch (st.pieces[idx].mode) {
            .south => _ = roadPath(st, bio, alloc, rand, b.max_x + 1, b.min_y, b.max_z - 2, .east, d),
            .west => _ = roadPath(st, bio, alloc, rand, b.min_x, b.min_y, b.max_z + 1, .south, d),
            .north => _ = roadPath(st, bio, alloc, rand, b.max_x + 1, b.min_y, b.min_z, .east, d),
            .east => _ = roadPath(st, bio, alloc, rand, b.max_x - 2, b.min_y, b.max_z + 1, .south, d),
        }
    }
}

// ---------------------------------------------------------------------------
// Placement phase (per-piece `a(world, rand, box)`).
// ---------------------------------------------------------------------------

fn placeWell(p: Placer, clip: BBox, pc: *Piece) void {
    if (pc.k < 0) {
        const avg = groundAvg(p, pc.box, clip) orelse return;
        pc.k = avg;
        pc.box = pc.box.offset(0, avg - pc.box.max_y + 3, 0);
    }
    const c = Component{ .mode = pc.mode, .box = pc.box };
    const ds = pc.desert;
    fill(p, c, clip, ds, 1, 0, 1, 4, 12, 4, .cobblestone, .flowing_water);
    put(p, c, clip, ds, .air, 0, 2, 12, 2);
    put(p, c, clip, ds, .air, 0, 3, 12, 2);
    put(p, c, clip, ds, .air, 0, 2, 12, 3);
    put(p, c, clip, ds, .air, 0, 3, 12, 3);
    put(p, c, clip, ds, .fence, 0, 1, 13, 1);
    put(p, c, clip, ds, .fence, 0, 1, 14, 1);
    put(p, c, clip, ds, .fence, 0, 4, 13, 1);
    put(p, c, clip, ds, .fence, 0, 4, 14, 1);
    put(p, c, clip, ds, .fence, 0, 1, 13, 4);
    put(p, c, clip, ds, .fence, 0, 1, 14, 4);
    put(p, c, clip, ds, .fence, 0, 4, 13, 4);
    put(p, c, clip, ds, .fence, 0, 4, 14, 4);
    fill(p, c, clip, ds, 1, 15, 1, 4, 15, 4, .cobblestone, .cobblestone);
    var x: i32 = 0;
    while (x <= 5) : (x += 1) {
        var z: i32 = 0;
        while (z <= 5) : (z += 1) {
            if (z == 0 or z == 5 or x == 0 or x == 5) {
                put(p, c, clip, ds, .gravel, 0, x, 11, z);
                cup(p, c, clip, x, 12, z);
            }
        }
    }
}

fn placeBigHouse(p: Placer, clip: BBox, pc: *Piece) void {
    if (pc.k < 0) {
        const avg = groundAvg(p, pc.box, clip) orelse return;
        pc.k = avg;
        pc.box = pc.box.offset(0, avg - pc.box.max_y + 9 - 1, 0);
    }
    const c = Component{ .mode = pc.mode, .box = pc.box };
    const ds = pc.desert;
    fill(p, c, clip, ds, 1, 1, 1, 7, 5, 4, .air, .air);
    fill(p, c, clip, ds, 0, 0, 0, 8, 0, 5, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 0, 5, 0, 8, 5, 5, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 0, 6, 1, 8, 6, 4, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 0, 7, 2, 8, 7, 3, .cobblestone, .cobblestone);
    const r3 = comp_mod.rotateMeta(.oak_stairs, 3, c.mode);
    const r2 = comp_mod.rotateMeta(.oak_stairs, 2, c.mode);
    var zo: i32 = -1;
    while (zo <= 2) : (zo += 1) {
        var x: i32 = 0;
        while (x <= 8) : (x += 1) {
            put(p, c, clip, ds, .oak_stairs, r3, x, 6 + zo, zo);
            put(p, c, clip, ds, .oak_stairs, r2, x, 6 + zo, 5 - zo);
        }
    }
    fill(p, c, clip, ds, 0, 1, 0, 0, 1, 5, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 1, 1, 5, 8, 1, 5, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 8, 1, 0, 8, 1, 4, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 2, 1, 0, 7, 1, 0, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 0, 2, 0, 0, 4, 0, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 0, 2, 5, 0, 4, 5, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 8, 2, 5, 8, 4, 5, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 8, 2, 0, 8, 4, 0, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 0, 2, 1, 0, 4, 4, .planks, .planks);
    fill(p, c, clip, ds, 1, 2, 5, 7, 4, 5, .planks, .planks);
    fill(p, c, clip, ds, 8, 2, 1, 8, 4, 4, .planks, .planks);
    fill(p, c, clip, ds, 1, 2, 0, 7, 4, 0, .planks, .planks);
    put(p, c, clip, ds, .glass_pane, 0, 4, 2, 0);
    put(p, c, clip, ds, .glass_pane, 0, 5, 2, 0);
    put(p, c, clip, ds, .glass_pane, 0, 6, 2, 0);
    put(p, c, clip, ds, .glass_pane, 0, 4, 3, 0);
    put(p, c, clip, ds, .glass_pane, 0, 5, 3, 0);
    put(p, c, clip, ds, .glass_pane, 0, 6, 3, 0);
    put(p, c, clip, ds, .glass_pane, 0, 0, 2, 2);
    put(p, c, clip, ds, .glass_pane, 0, 0, 2, 3);
    put(p, c, clip, ds, .glass_pane, 0, 0, 3, 2);
    put(p, c, clip, ds, .glass_pane, 0, 0, 3, 3);
    put(p, c, clip, ds, .glass_pane, 0, 8, 2, 2);
    put(p, c, clip, ds, .glass_pane, 0, 8, 2, 3);
    put(p, c, clip, ds, .glass_pane, 0, 8, 3, 2);
    put(p, c, clip, ds, .glass_pane, 0, 8, 3, 3);
    put(p, c, clip, ds, .glass_pane, 0, 2, 2, 5);
    put(p, c, clip, ds, .glass_pane, 0, 3, 2, 5);
    put(p, c, clip, ds, .glass_pane, 0, 5, 2, 5);
    put(p, c, clip, ds, .glass_pane, 0, 6, 2, 5);
    fill(p, c, clip, ds, 1, 4, 1, 7, 4, 1, .planks, .planks);
    fill(p, c, clip, ds, 1, 4, 4, 7, 4, 4, .planks, .planks);
    fill(p, c, clip, ds, 1, 3, 4, 7, 3, 4, .bookshelf, .bookshelf);
    put(p, c, clip, ds, .planks, 0, 7, 1, 4);
    putRot(p, c, clip, ds, .oak_stairs, 0, 7, 1, 3);
    putRot(p, c, clip, ds, .oak_stairs, 3, 6, 1, 4);
    putRot(p, c, clip, ds, .oak_stairs, 3, 5, 1, 4);
    putRot(p, c, clip, ds, .oak_stairs, 3, 4, 1, 4);
    putRot(p, c, clip, ds, .oak_stairs, 3, 3, 1, 4);
    put(p, c, clip, ds, .fence, 0, 6, 1, 3);
    put(p, c, clip, ds, .wooden_pressure_plate, 0, 6, 2, 3);
    put(p, c, clip, ds, .fence, 0, 4, 1, 3);
    put(p, c, clip, ds, .wooden_pressure_plate, 0, 4, 2, 3);
    put(p, c, clip, ds, .crafting_table, 0, 7, 1, 1);
    put(p, c, clip, ds, .air, 0, 1, 1, 0);
    put(p, c, clip, ds, .air, 0, 1, 2, 0);
    door(p, c, clip, ds, 1, 1, 0);
    maybeStep(p, c, clip, ds, 1, -1);
    var z: i32 = 0;
    while (z < 6) : (z += 1) {
        var x2: i32 = 0;
        while (x2 < 9) : (x2 += 1) {
            cup(p, c, clip, x2, 9, z);
            fdn(p, c, clip, ds, .cobblestone, 0, x2, -1, z);
        }
    }
    spawnRow(p, c, clip, 2, 1, 2, 1);
}

fn placeFarm(p: Placer, clip: BBox, rand: *JavaRandom, pc: *Piece) void {
    if (pc.k < 0) {
        const avg = groundAvg(p, pc.box, clip) orelse return;
        pc.k = avg;
        pc.box = pc.box.offset(0, avg - pc.box.max_y + 4 - 1, 0);
    }
    const c = Component{ .mode = pc.mode, .box = pc.box };
    const ds = pc.desert;
    const large = pc.kind == .farm_large;
    const x1: i32 = if (large) 12 else 6;
    fill(p, c, clip, ds, 0, 1, 0, x1, 4, 8, .air, .air);
    fill(p, c, clip, ds, 1, 0, 1, 2, 0, 7, .farmland, .farmland);
    fill(p, c, clip, ds, 4, 0, 1, 5, 0, 7, .farmland, .farmland);
    if (large) {
        fill(p, c, clip, ds, 7, 0, 1, 8, 0, 7, .farmland, .farmland);
        fill(p, c, clip, ds, 10, 0, 1, 11, 0, 7, .farmland, .farmland);
    }
    fill(p, c, clip, ds, 0, 0, 0, 0, 0, 8, .log, .log);
    fill(p, c, clip, ds, 6, 0, 0, 6, 0, 8, .log, .log);
    if (large) fill(p, c, clip, ds, 12, 0, 0, 12, 0, 8, .log, .log);
    if (large) {
        fill(p, c, clip, ds, 1, 0, 0, 11, 0, 0, .log, .log);
        fill(p, c, clip, ds, 1, 0, 8, 11, 0, 8, .log, .log);
    } else {
        fill(p, c, clip, ds, 1, 0, 0, 5, 0, 0, .log, .log);
        fill(p, c, clip, ds, 1, 0, 8, 5, 0, 8, .log, .log);
    }
    fill(p, c, clip, ds, 3, 0, 1, 3, 0, 7, .water, .water);
    if (large) fill(p, c, clip, ds, 9, 0, 1, 9, 0, 7, .water, .water);
    var z: i32 = 1;
    while (z <= 7) : (z += 1) {
        put(p, c, clip, ds, pc.crops[0], @intCast(qh(rand, 2, 7)), 1, 1, z);
        put(p, c, clip, ds, pc.crops[0], @intCast(qh(rand, 2, 7)), 2, 1, z);
        put(p, c, clip, ds, pc.crops[1], @intCast(qh(rand, 2, 7)), 4, 1, z);
        put(p, c, clip, ds, pc.crops[1], @intCast(qh(rand, 2, 7)), 5, 1, z);
        if (large) {
            put(p, c, clip, ds, pc.crops[2], @intCast(qh(rand, 2, 7)), 7, 1, z);
            put(p, c, clip, ds, pc.crops[2], @intCast(qh(rand, 2, 7)), 8, 1, z);
            put(p, c, clip, ds, pc.crops[3], @intCast(qh(rand, 2, 7)), 10, 1, z);
            put(p, c, clip, ds, pc.crops[3], @intCast(qh(rand, 2, 7)), 11, 1, z);
        }
    }
    var z2: i32 = 0;
    while (z2 < 9) : (z2 += 1) {
        var x2: i32 = 0;
        while (x2 <= x1) : (x2 += 1) {
            cup(p, c, clip, x2, 4, z2);
            fdn(p, c, clip, ds, .dirt, 0, x2, -1, z2);
        }
    }
}

fn placeLamp(p: Placer, clip: BBox, pc: *Piece) void {
    if (pc.k < 0) {
        const avg = groundAvg(p, pc.box, clip) orelse return;
        pc.k = avg;
        pc.box = pc.box.offset(0, avg - pc.box.max_y + 4 - 1, 0);
    }
    const c = Component{ .mode = pc.mode, .box = pc.box };
    const ds = pc.desert;
    fill(p, c, clip, ds, 0, 0, 0, 2, 3, 1, .air, .air);
    put(p, c, clip, ds, .fence, 0, 1, 0, 0);
    put(p, c, clip, ds, .fence, 0, 1, 1, 0);
    put(p, c, clip, ds, .fence, 0, 1, 2, 0);
    put(p, c, clip, ds, .wool, 15, 1, 3, 0);
    put(p, c, clip, ds, .torch, 0, 0, 3, 0);
    put(p, c, clip, ds, .torch, 0, 1, 3, 1);
    put(p, c, clip, ds, .torch, 0, 2, 3, 0);
    put(p, c, clip, ds, .torch, 0, 1, 3, -1);
}

fn placeSmallHouse(p: Placer, clip: BBox, pc: *Piece) void {
    if (pc.k < 0) {
        const avg = groundAvg(p, pc.box, clip) orelse return;
        pc.k = avg;
        pc.box = pc.box.offset(0, avg - pc.box.max_y + 7 - 1, 0);
    }
    const c = Component{ .mode = pc.mode, .box = pc.box };
    const ds = pc.desert;
    fill(p, c, clip, ds, 1, 1, 1, 7, 4, 4, .air, .air);
    fill(p, c, clip, ds, 2, 1, 6, 8, 4, 10, .air, .air);
    fill(p, c, clip, ds, 2, 0, 6, 8, 0, 10, .dirt, .dirt);
    put(p, c, clip, ds, .cobblestone, 0, 6, 0, 6);
    fill(p, c, clip, ds, 2, 1, 6, 2, 1, 10, .fence, .fence);
    fill(p, c, clip, ds, 8, 1, 6, 8, 1, 10, .fence, .fence);
    fill(p, c, clip, ds, 3, 1, 10, 7, 1, 10, .fence, .fence);
    fill(p, c, clip, ds, 1, 0, 1, 7, 0, 4, .planks, .planks);
    fill(p, c, clip, ds, 0, 0, 0, 0, 3, 5, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 8, 0, 0, 8, 3, 5, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 1, 0, 0, 7, 1, 0, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 1, 0, 5, 7, 1, 5, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 1, 2, 0, 7, 3, 0, .planks, .planks);
    fill(p, c, clip, ds, 1, 2, 5, 7, 3, 5, .planks, .planks);
    fill(p, c, clip, ds, 0, 4, 1, 8, 4, 1, .planks, .planks);
    fill(p, c, clip, ds, 0, 4, 4, 8, 4, 4, .planks, .planks);
    fill(p, c, clip, ds, 0, 5, 2, 8, 5, 3, .planks, .planks);
    put(p, c, clip, ds, .planks, 0, 0, 4, 2);
    put(p, c, clip, ds, .planks, 0, 0, 4, 3);
    put(p, c, clip, ds, .planks, 0, 8, 4, 2);
    put(p, c, clip, ds, .planks, 0, 8, 4, 3);
    const r3 = comp_mod.rotateMeta(.oak_stairs, 3, c.mode);
    const r2 = comp_mod.rotateMeta(.oak_stairs, 2, c.mode);
    var zo: i32 = -1;
    while (zo <= 2) : (zo += 1) {
        var x: i32 = 0;
        while (x <= 8) : (x += 1) {
            put(p, c, clip, ds, .oak_stairs, r3, x, 4 + zo, zo);
            put(p, c, clip, ds, .oak_stairs, r2, x, 4 + zo, 5 - zo);
        }
    }
    put(p, c, clip, ds, .log, 0, 0, 2, 1);
    put(p, c, clip, ds, .log, 0, 0, 2, 4);
    put(p, c, clip, ds, .log, 0, 8, 2, 1);
    put(p, c, clip, ds, .log, 0, 8, 2, 4);
    put(p, c, clip, ds, .glass_pane, 0, 0, 2, 2);
    put(p, c, clip, ds, .glass_pane, 0, 0, 2, 3);
    put(p, c, clip, ds, .glass_pane, 0, 8, 2, 2);
    put(p, c, clip, ds, .glass_pane, 0, 8, 2, 3);
    put(p, c, clip, ds, .glass_pane, 0, 2, 2, 5);
    put(p, c, clip, ds, .glass_pane, 0, 3, 2, 5);
    put(p, c, clip, ds, .glass_pane, 0, 5, 2, 0);
    put(p, c, clip, ds, .glass_pane, 0, 6, 2, 5);
    put(p, c, clip, ds, .fence, 0, 2, 1, 3);
    put(p, c, clip, ds, .wooden_pressure_plate, 0, 2, 2, 3);
    put(p, c, clip, ds, .planks, 0, 1, 1, 4);
    putRot(p, c, clip, ds, .oak_stairs, 3, 2, 1, 4);
    putRot(p, c, clip, ds, .oak_stairs, 1, 1, 1, 3);
    fill(p, c, clip, ds, 5, 0, 1, 7, 0, 3, .double_stone_slab, .double_stone_slab);
    put(p, c, clip, ds, .double_stone_slab, 0, 6, 1, 1);
    put(p, c, clip, ds, .double_stone_slab, 0, 6, 1, 2);
    put(p, c, clip, ds, .air, 0, 2, 1, 0);
    put(p, c, clip, ds, .air, 0, 2, 2, 0);
    put(p, c, clip, ds, .torch, 0, 2, 3, 1);
    door(p, c, clip, ds, 2, 1, 0);
    maybeStep(p, c, clip, ds, 2, -1);
    put(p, c, clip, ds, .air, 0, 6, 1, 5);
    put(p, c, clip, ds, .air, 0, 6, 2, 5);
    put(p, c, clip, ds, .torch, 0, 6, 3, 4);
    door(p, c, clip, ds, 6, 1, 5);
    var z: i32 = 0;
    while (z < 5) : (z += 1) {
        var x2: i32 = 0;
        while (x2 < 9) : (x2 += 1) {
            cup(p, c, clip, x2, 7, z);
            fdn(p, c, clip, ds, .cobblestone, 0, x2, -1, z);
        }
    }
    spawnRow(p, c, clip, 4, 1, 2, 2);
}

fn placeHut(p: Placer, clip: BBox, pc: *Piece) void {
    if (pc.k < 0) {
        const avg = groundAvg(p, pc.box, clip) orelse return;
        pc.k = avg;
        pc.box = pc.box.offset(0, avg - pc.box.max_y + 6 - 1, 0);
    }
    const c = Component{ .mode = pc.mode, .box = pc.box };
    const ds = pc.desert;
    fill(p, c, clip, ds, 0, 0, 0, 4, 0, 4, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 0, 4, 0, 4, 4, 4, .log, .log);
    fill(p, c, clip, ds, 1, 4, 1, 3, 4, 3, .planks, .planks);
    put(p, c, clip, ds, .cobblestone, 0, 0, 1, 0);
    put(p, c, clip, ds, .cobblestone, 0, 0, 2, 0);
    put(p, c, clip, ds, .cobblestone, 0, 0, 3, 0);
    put(p, c, clip, ds, .cobblestone, 0, 4, 1, 0);
    put(p, c, clip, ds, .cobblestone, 0, 4, 2, 0);
    put(p, c, clip, ds, .cobblestone, 0, 4, 3, 0);
    put(p, c, clip, ds, .cobblestone, 0, 0, 1, 4);
    put(p, c, clip, ds, .cobblestone, 0, 0, 2, 4);
    put(p, c, clip, ds, .cobblestone, 0, 0, 3, 4);
    put(p, c, clip, ds, .cobblestone, 0, 4, 1, 4);
    put(p, c, clip, ds, .cobblestone, 0, 4, 2, 4);
    put(p, c, clip, ds, .cobblestone, 0, 4, 3, 4);
    fill(p, c, clip, ds, 0, 1, 1, 0, 3, 3, .planks, .planks);
    fill(p, c, clip, ds, 4, 1, 1, 4, 3, 3, .planks, .planks);
    fill(p, c, clip, ds, 1, 1, 4, 3, 3, 4, .planks, .planks);
    put(p, c, clip, ds, .glass_pane, 0, 0, 2, 2);
    put(p, c, clip, ds, .glass_pane, 0, 2, 2, 4);
    put(p, c, clip, ds, .glass_pane, 0, 4, 2, 2);
    put(p, c, clip, ds, .planks, 0, 1, 1, 0);
    put(p, c, clip, ds, .planks, 0, 1, 2, 0);
    put(p, c, clip, ds, .planks, 0, 1, 3, 0);
    put(p, c, clip, ds, .planks, 0, 2, 3, 0);
    put(p, c, clip, ds, .planks, 0, 3, 3, 0);
    put(p, c, clip, ds, .planks, 0, 3, 2, 0);
    put(p, c, clip, ds, .planks, 0, 3, 1, 0);
    maybeStep(p, c, clip, ds, 2, -1);
    fill(p, c, clip, ds, 1, 1, 1, 3, 3, 3, .air, .air);
    if (pc.terrace) {
        var i: i32 = 0;
        while (i <= 4) : (i += 1) {
            put(p, c, clip, ds, .fence, 0, i, 5, 0);
            put(p, c, clip, ds, .fence, 0, i, 5, 4);
        }
        var j: i32 = 1;
        while (j <= 3) : (j += 1) {
            put(p, c, clip, ds, .fence, 0, 4, 5, j);
            put(p, c, clip, ds, .fence, 0, 0, 5, j);
        }
    }
    if (pc.terrace) {
        const lr = comp_mod.rotateMeta(.ladder, 4, c.mode);
        put(p, c, clip, ds, .ladder, lr, 3, 1, 3);
        put(p, c, clip, ds, .ladder, lr, 3, 2, 3);
        put(p, c, clip, ds, .ladder, lr, 3, 3, 3);
        put(p, c, clip, ds, .ladder, lr, 3, 4, 3);
    }
    put(p, c, clip, ds, .torch, 0, 2, 3, 1);
    var z: i32 = 0;
    while (z < 5) : (z += 1) {
        var x2: i32 = 0;
        while (x2 < 5) : (x2 += 1) {
            cup(p, c, clip, x2, 6, z);
            fdn(p, c, clip, ds, .cobblestone, 0, x2, -1, z);
        }
    }
    spawnRow(p, c, clip, 1, 1, 2, 1);
}

fn placeSmithySmall(p: Placer, clip: BBox, pc: *Piece) void {
    if (pc.k < 0) {
        const avg = groundAvg(p, pc.box, clip) orelse return;
        pc.k = avg;
        pc.box = pc.box.offset(0, avg - pc.box.max_y + 6 - 1, 0);
    }
    const c = Component{ .mode = pc.mode, .box = pc.box };
    const ds = pc.desert;
    fill(p, c, clip, ds, 1, 1, 1, 3, 5, 4, .air, .air);
    fill(p, c, clip, ds, 0, 0, 0, 3, 0, 4, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 1, 0, 1, 2, 0, 3, .dirt, .dirt);
    if (pc.terrace) {
        fill(p, c, clip, ds, 1, 4, 1, 2, 4, 3, .log, .log);
    } else {
        fill(p, c, clip, ds, 1, 5, 1, 2, 5, 3, .log, .log);
    }
    put(p, c, clip, ds, .log, 0, 1, 4, 0);
    put(p, c, clip, ds, .log, 0, 2, 4, 0);
    put(p, c, clip, ds, .log, 0, 1, 4, 4);
    put(p, c, clip, ds, .log, 0, 2, 4, 4);
    put(p, c, clip, ds, .log, 0, 0, 4, 1);
    put(p, c, clip, ds, .log, 0, 0, 4, 2);
    put(p, c, clip, ds, .log, 0, 0, 4, 3);
    put(p, c, clip, ds, .log, 0, 3, 4, 1);
    put(p, c, clip, ds, .log, 0, 3, 4, 2);
    put(p, c, clip, ds, .log, 0, 3, 4, 3);
    fill(p, c, clip, ds, 0, 1, 0, 0, 3, 0, .log, .log);
    fill(p, c, clip, ds, 3, 1, 0, 3, 3, 0, .log, .log);
    fill(p, c, clip, ds, 0, 1, 4, 0, 3, 4, .log, .log);
    fill(p, c, clip, ds, 3, 1, 4, 3, 3, 4, .log, .log);
    fill(p, c, clip, ds, 0, 1, 1, 0, 3, 3, .planks, .planks);
    fill(p, c, clip, ds, 3, 1, 1, 3, 3, 3, .planks, .planks);
    fill(p, c, clip, ds, 1, 1, 0, 2, 3, 0, .planks, .planks);
    fill(p, c, clip, ds, 1, 1, 4, 2, 3, 4, .planks, .planks);
    put(p, c, clip, ds, .glass_pane, 0, 0, 2, 2);
    put(p, c, clip, ds, .glass_pane, 0, 3, 2, 2);
    if (pc.table > 0) {
        put(p, c, clip, ds, .fence, 0, pc.table, 1, 3);
        put(p, c, clip, ds, .glass_pane, 0, pc.table, 2, 3);
    }
    put(p, c, clip, ds, .air, 0, 1, 1, 0);
    put(p, c, clip, ds, .air, 0, 1, 2, 0);
    door(p, c, clip, ds, 1, 1, 0);
    maybeStep(p, c, clip, ds, 1, -1);
    var z: i32 = 0;
    while (z < 5) : (z += 1) {
        var x2: i32 = 0;
        while (x2 < 4) : (x2 += 1) {
            cup(p, c, clip, x2, 6, z);
            fdn(p, c, clip, ds, .cobblestone, 0, x2, -1, z);
        }
    }
    spawnRow(p, c, clip, 1, 1, 2, 1);
}

fn placeChurch(p: Placer, clip: BBox, pc: *Piece) void {
    if (pc.k < 0) {
        const avg = groundAvg(p, pc.box, clip) orelse return;
        pc.k = avg;
        pc.box = pc.box.offset(0, avg - pc.box.max_y + 12 - 1, 0);
    }
    const c = Component{ .mode = pc.mode, .box = pc.box };
    const ds = pc.desert;
    fill(p, c, clip, ds, 1, 1, 1, 3, 3, 7, .air, .air);
    fill(p, c, clip, ds, 1, 5, 1, 3, 9, 3, .air, .air);
    fill(p, c, clip, ds, 1, 0, 0, 3, 0, 8, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 1, 1, 0, 3, 10, 0, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 0, 1, 1, 0, 10, 3, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 4, 1, 1, 4, 10, 3, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 0, 0, 4, 0, 4, 7, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 4, 0, 4, 4, 4, 7, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 1, 1, 8, 3, 4, 8, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 1, 5, 4, 3, 10, 4, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 1, 5, 5, 3, 5, 7, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 0, 9, 0, 4, 9, 4, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 0, 4, 0, 4, 4, 4, .cobblestone, .cobblestone);
    put(p, c, clip, ds, .cobblestone, 0, 0, 11, 2);
    put(p, c, clip, ds, .cobblestone, 0, 4, 11, 2);
    put(p, c, clip, ds, .cobblestone, 0, 2, 11, 0);
    put(p, c, clip, ds, .cobblestone, 0, 2, 11, 4);
    put(p, c, clip, ds, .cobblestone, 0, 1, 1, 6);
    put(p, c, clip, ds, .cobblestone, 0, 1, 1, 7);
    put(p, c, clip, ds, .cobblestone, 0, 2, 1, 7);
    put(p, c, clip, ds, .cobblestone, 0, 3, 1, 6);
    put(p, c, clip, ds, .cobblestone, 0, 3, 1, 7);
    putRot(p, c, clip, ds, .stone_stairs, 3, 1, 1, 5);
    putRot(p, c, clip, ds, .stone_stairs, 3, 2, 1, 6);
    putRot(p, c, clip, ds, .stone_stairs, 3, 3, 1, 5);
    putRot(p, c, clip, ds, .stone_stairs, 1, 1, 2, 7);
    putRot(p, c, clip, ds, .stone_stairs, 0, 3, 2, 7);
    put(p, c, clip, ds, .glass_pane, 0, 0, 2, 2);
    put(p, c, clip, ds, .glass_pane, 0, 0, 3, 2);
    put(p, c, clip, ds, .glass_pane, 0, 4, 2, 2);
    put(p, c, clip, ds, .glass_pane, 0, 4, 3, 2);
    put(p, c, clip, ds, .glass_pane, 0, 0, 6, 2);
    put(p, c, clip, ds, .glass_pane, 0, 0, 7, 2);
    put(p, c, clip, ds, .glass_pane, 0, 4, 6, 2);
    put(p, c, clip, ds, .glass_pane, 0, 4, 7, 2);
    put(p, c, clip, ds, .glass_pane, 0, 2, 6, 0);
    put(p, c, clip, ds, .glass_pane, 0, 2, 7, 0);
    put(p, c, clip, ds, .glass_pane, 0, 2, 6, 4);
    put(p, c, clip, ds, .glass_pane, 0, 2, 7, 4);
    put(p, c, clip, ds, .glass_pane, 0, 0, 3, 6);
    put(p, c, clip, ds, .glass_pane, 0, 4, 3, 6);
    put(p, c, clip, ds, .glass_pane, 0, 2, 3, 8);
    put(p, c, clip, ds, .torch, 0, 2, 4, 7);
    put(p, c, clip, ds, .torch, 0, 1, 4, 6);
    put(p, c, clip, ds, .torch, 0, 3, 4, 6);
    put(p, c, clip, ds, .torch, 0, 2, 4, 5);
    const lr = comp_mod.rotateMeta(.ladder, 4, c.mode);
    var y: i32 = 1;
    while (y <= 9) : (y += 1) {
        put(p, c, clip, ds, .ladder, lr, 3, y, 3);
    }
    put(p, c, clip, ds, .air, 0, 2, 1, 0);
    put(p, c, clip, ds, .air, 0, 2, 2, 0);
    door(p, c, clip, ds, 2, 1, 0);
    maybeStep(p, c, clip, ds, 2, -1);
    var z: i32 = 0;
    while (z < 9) : (z += 1) {
        var x2: i32 = 0;
        while (x2 < 5) : (x2 += 1) {
            cup(p, c, clip, x2, 12, z);
            fdn(p, c, clip, ds, .cobblestone, 0, x2, -1, z);
        }
    }
    spawnRow(p, c, clip, 2, 1, 2, 1);
}

fn placeSmithy(p: Placer, clip: BBox, rand: *JavaRandom, pc: *Piece) void {
    if (pc.k < 0) {
        const avg = groundAvg(p, pc.box, clip) orelse return;
        pc.k = avg;
        pc.box = pc.box.offset(0, avg - pc.box.max_y + 6 - 1, 0);
    }
    const c = Component{ .mode = pc.mode, .box = pc.box };
    const ds = pc.desert;
    fill(p, c, clip, ds, 0, 1, 0, 9, 4, 6, .air, .air);
    fill(p, c, clip, ds, 0, 0, 0, 9, 0, 6, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 0, 4, 0, 9, 4, 6, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 0, 5, 0, 9, 5, 6, .stone_slab, .stone_slab);
    fill(p, c, clip, ds, 1, 5, 1, 8, 5, 5, .air, .air);
    fill(p, c, clip, ds, 1, 1, 0, 2, 3, 0, .planks, .planks);
    fill(p, c, clip, ds, 0, 1, 0, 0, 4, 0, .log, .log);
    fill(p, c, clip, ds, 3, 1, 0, 3, 4, 0, .log, .log);
    fill(p, c, clip, ds, 0, 1, 6, 0, 4, 6, .log, .log);
    put(p, c, clip, ds, .planks, 0, 3, 3, 1);
    fill(p, c, clip, ds, 3, 1, 2, 3, 3, 2, .planks, .planks);
    fill(p, c, clip, ds, 4, 1, 3, 5, 3, 3, .planks, .planks);
    fill(p, c, clip, ds, 0, 1, 1, 0, 3, 5, .planks, .planks);
    fill(p, c, clip, ds, 1, 1, 6, 5, 3, 6, .planks, .planks);
    fill(p, c, clip, ds, 5, 1, 0, 5, 3, 0, .fence, .fence);
    fill(p, c, clip, ds, 9, 1, 0, 9, 3, 0, .fence, .fence);
    fill(p, c, clip, ds, 6, 1, 4, 9, 4, 6, .cobblestone, .cobblestone);
    put(p, c, clip, ds, .flowing_lava, 0, 7, 1, 5);
    put(p, c, clip, ds, .flowing_lava, 0, 8, 1, 5);
    put(p, c, clip, ds, .iron_bars, 0, 9, 2, 5);
    put(p, c, clip, ds, .iron_bars, 0, 9, 2, 4);
    fill(p, c, clip, ds, 7, 2, 4, 8, 2, 5, .air, .air);
    put(p, c, clip, ds, .cobblestone, 0, 6, 1, 3);
    put(p, c, clip, ds, .furnace, 0, 6, 2, 3);
    put(p, c, clip, ds, .furnace, 0, 6, 3, 3);
    put(p, c, clip, ds, .double_stone_slab, 0, 8, 1, 1);
    put(p, c, clip, ds, .glass_pane, 0, 0, 2, 2);
    put(p, c, clip, ds, .glass_pane, 0, 0, 2, 4);
    put(p, c, clip, ds, .glass_pane, 0, 2, 2, 6);
    put(p, c, clip, ds, .glass_pane, 0, 4, 2, 6);
    put(p, c, clip, ds, .fence, 0, 2, 1, 4);
    put(p, c, clip, ds, .wooden_pressure_plate, 0, 2, 2, 4);
    put(p, c, clip, ds, .planks, 0, 1, 1, 5);
    putRot(p, c, clip, ds, .oak_stairs, 3, 2, 1, 5);
    putRot(p, c, clip, ds, .oak_stairs, 1, 1, 1, 4);
    if (!pc.chest) {
        const wx = c.xWithOffset(5, 5);
        const wy = c.yWithOffset(1);
        const wz = c.zWithOffset(5, 5);
        if (clip.contains(wx, wy, wz)) {
            pc.chest = true;
            const n = 3 + (rand.nextIntBound(6) catch unreachable);
            _ = comp_mod.placeChest(p, c, clip, rand, 5, 1, 5, &loot_mod.village_blacksmith, n);
        }
    }
    var x: i32 = 6;
    while (x <= 8) : (x += 1) {
        if (comp_mod.getAt(p, c, clip, x, 0, -1).id == .air and
            comp_mod.getAt(p, c, clip, x, -1, -1).id != .air)
        {
            putRot(p, c, clip, ds, .stone_stairs, 3, x, 0, -1);
        }
    }
    var z: i32 = 0;
    while (z < 7) : (z += 1) {
        var x2: i32 = 0;
        while (x2 < 10) : (x2 += 1) {
            cup(p, c, clip, x2, 6, z);
            fdn(p, c, clip, ds, .cobblestone, 0, x2, -1, z);
        }
    }
    spawnRow(p, c, clip, 7, 1, 1, 1);
}

fn placeTownHall(p: Placer, clip: BBox, pc: *Piece) void {
    if (pc.k < 0) {
        const avg = groundAvg(p, pc.box, clip) orelse return;
        pc.k = avg;
        pc.box = pc.box.offset(0, avg - pc.box.max_y + 7 - 1, 0);
    }
    const c = Component{ .mode = pc.mode, .box = pc.box };
    const ds = pc.desert;
    fill(p, c, clip, ds, 1, 1, 1, 7, 4, 4, .air, .air);
    fill(p, c, clip, ds, 2, 1, 6, 8, 4, 10, .air, .air);
    fill(p, c, clip, ds, 2, 0, 5, 8, 0, 10, .planks, .planks);
    fill(p, c, clip, ds, 1, 0, 1, 7, 0, 4, .planks, .planks);
    fill(p, c, clip, ds, 0, 0, 0, 0, 3, 5, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 8, 0, 0, 8, 3, 10, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 1, 0, 0, 7, 2, 0, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 1, 0, 5, 2, 1, 5, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 2, 0, 6, 2, 3, 10, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 3, 0, 10, 7, 3, 10, .cobblestone, .cobblestone);
    fill(p, c, clip, ds, 1, 2, 0, 7, 3, 0, .planks, .planks);
    fill(p, c, clip, ds, 1, 2, 5, 2, 3, 5, .planks, .planks);
    fill(p, c, clip, ds, 0, 4, 1, 8, 4, 1, .planks, .planks);
    fill(p, c, clip, ds, 0, 4, 4, 3, 4, 4, .planks, .planks);
    fill(p, c, clip, ds, 0, 5, 2, 8, 5, 3, .planks, .planks);
    put(p, c, clip, ds, .planks, 0, 0, 4, 2);
    put(p, c, clip, ds, .planks, 0, 0, 4, 3);
    put(p, c, clip, ds, .planks, 0, 8, 4, 2);
    put(p, c, clip, ds, .planks, 0, 8, 4, 3);
    put(p, c, clip, ds, .planks, 0, 8, 4, 4);
    const r3 = comp_mod.rotateMeta(.oak_stairs, 3, c.mode);
    const r2 = comp_mod.rotateMeta(.oak_stairs, 2, c.mode);
    var zo: i32 = -1;
    while (zo <= 2) : (zo += 1) {
        var x: i32 = 0;
        while (x <= 8) : (x += 1) {
            put(p, c, clip, ds, .oak_stairs, r3, x, 4 + zo, zo);
            if ((zo > -1 or x <= 1) and (zo > 0 or x <= 3) and (zo > 1 or x <= 4 or x >= 6)) {
                put(p, c, clip, ds, .oak_stairs, r2, x, 4 + zo, 5 - zo);
            }
        }
    }
    fill(p, c, clip, ds, 3, 4, 5, 3, 4, 10, .planks, .planks);
    fill(p, c, clip, ds, 7, 4, 2, 7, 4, 10, .planks, .planks);
    fill(p, c, clip, ds, 4, 5, 4, 4, 5, 10, .planks, .planks);
    fill(p, c, clip, ds, 6, 5, 4, 6, 5, 10, .planks, .planks);
    fill(p, c, clip, ds, 5, 6, 3, 5, 6, 10, .planks, .planks);
    const r0 = comp_mod.rotateMeta(.oak_stairs, 0, c.mode);
    var yy: i32 = 4;
    while (yy >= 1) : (yy -= 1) {
        put(p, c, clip, ds, .planks, 0, yy, 2 + yy, 7 - yy);
        var z2: i32 = 8 - yy;
        while (z2 <= 10) : (z2 += 1) {
            put(p, c, clip, ds, .oak_stairs, r0, yy, 2 + yy, z2);
        }
    }
    const r1 = comp_mod.rotateMeta(.oak_stairs, 1, c.mode);
    put(p, c, clip, ds, .planks, 0, 6, 6, 3);
    put(p, c, clip, ds, .planks, 0, 7, 5, 4);
    put(p, c, clip, ds, .oak_stairs, r1, 6, 6, 4);
    var xx: i32 = 6;
    while (xx <= 8) : (xx += 1) {
        var z3: i32 = 5;
        while (z3 <= 10) : (z3 += 1) {
            put(p, c, clip, ds, .oak_stairs, r1, xx, 12 - xx, z3);
        }
    }
    put(p, c, clip, ds, .log, 0, 0, 2, 1);
    put(p, c, clip, ds, .log, 0, 0, 2, 4);
    put(p, c, clip, ds, .glass_pane, 0, 0, 2, 2);
    put(p, c, clip, ds, .glass_pane, 0, 0, 2, 3);
    put(p, c, clip, ds, .log, 0, 4, 2, 0);
    put(p, c, clip, ds, .glass_pane, 0, 5, 2, 0);
    put(p, c, clip, ds, .log, 0, 6, 2, 0);
    put(p, c, clip, ds, .log, 0, 8, 2, 1);
    put(p, c, clip, ds, .glass_pane, 0, 8, 2, 2);
    put(p, c, clip, ds, .glass_pane, 0, 8, 2, 3);
    put(p, c, clip, ds, .log, 0, 8, 2, 4);
    put(p, c, clip, ds, .planks, 0, 8, 2, 5);
    put(p, c, clip, ds, .log, 0, 8, 2, 6);
    put(p, c, clip, ds, .glass_pane, 0, 8, 2, 7);
    put(p, c, clip, ds, .glass_pane, 0, 8, 2, 8);
    put(p, c, clip, ds, .log, 0, 8, 2, 9);
    put(p, c, clip, ds, .log, 0, 2, 2, 6);
    put(p, c, clip, ds, .glass_pane, 0, 2, 2, 7);
    put(p, c, clip, ds, .glass_pane, 0, 2, 2, 8);
    put(p, c, clip, ds, .log, 0, 2, 2, 9);
    put(p, c, clip, ds, .log, 0, 4, 4, 10);
    put(p, c, clip, ds, .glass_pane, 0, 5, 4, 10);
    put(p, c, clip, ds, .log, 0, 6, 4, 10);
    put(p, c, clip, ds, .planks, 0, 5, 5, 10);
    put(p, c, clip, ds, .air, 0, 2, 1, 0);
    put(p, c, clip, ds, .air, 0, 2, 2, 0);
    put(p, c, clip, ds, .torch, 0, 2, 3, 1);
    door(p, c, clip, ds, 2, 1, 0);
    fill(p, c, clip, ds, 1, 0, -1, 3, 2, -1, .air, .air);
    maybeStep(p, c, clip, ds, 2, -1);
    var z4: i32 = 0;
    while (z4 < 5) : (z4 += 1) {
        var x3: i32 = 0;
        while (x3 < 9) : (x3 += 1) {
            cup(p, c, clip, x3, 7, z4);
            fdn(p, c, clip, ds, .cobblestone, 0, x3, -1, z4);
        }
    }
    var z5: i32 = 5;
    while (z5 < 11) : (z5 += 1) {
        var x4: i32 = 2;
        while (x4 < 9) : (x4 += 1) {
            cup(p, c, clip, x4, 7, z5);
            fdn(p, c, clip, ds, .cobblestone, 0, x4, -1, z5);
        }
    }
    spawnRow(p, c, clip, 4, 1, 2, 2);
}

/// Road stamp (`awb.a` place): absolute columns, gravel-mapped block at
/// topY-1, clipped on (x, 64, z).
fn placeRoad(p: Placer, clip: BBox, pc: *const Piece) void {
    const blk = mapId(pc.desert, .gravel);
    var x = pc.box.min_x;
    while (x <= pc.box.max_x) : (x += 1) {
        var z = pc.box.min_z;
        while (z <= pc.box.max_z) : (z += 1) {
            if (clip.contains(x, 64, z)) {
                const y = p.topY(x, z) - 1;
                p.set(x, y, z, blk, 0);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Entry point.
// ---------------------------------------------------------------------------

/// Place one village start into the populate chunk (`ave.a` per-start
/// step): build with the rand stream, then run every intersecting piece
/// in insertion order. Returns true when anything could generate.
pub fn generate(p: Placer, bio: BioCtx, alloc: std.mem.Allocator, sx: i32, sz: i32, build_rand: *JavaRandom, place_rand: *JavaRandom, clip: BBox) bool {
    var st = State{};
    // Weight table (`avp.a(Random,int)`, size 0).
    const lims = [_]i32{
        qh(build_rand, 2, 4),
        qh(build_rand, 0, 1),
        qh(build_rand, 0, 2),
        qh(build_rand, 2, 5),
        qh(build_rand, 0, 2),
        qh(build_rand, 1, 4),
        qh(build_rand, 2, 4),
        qh(build_rand, 0, 1),
        qh(build_rand, 0, 3),
    };
    const kinds = [_]Kind{ .hut, .church, .big_house, .smithy_small, .small_house, .farm_large, .farm_small, .smithy, .town_hall };
    const ws = [_]i32{ 4, 20, 20, 3, 15, 3, 3, 15, 8 };
    for (kinds, ws, lims) |k, w, l| {
        if (l == 0) continue;
        st.weights[st.nw] = .{ .kind = k, .w = w, .n = 0, .lim = l };
        st.nw += 1;
    }
    // Well + desert flag (`awa` ctor: biome at well pos).
    const wx = sx *% 16 +% 2;
    const wz = sz *% 16 +% 2;
    const wb = bio.voronoiAt(alloc, wx, wz);
    st.desert = wb == 2 or wb == 17;
    const wmode = Facing.fromInt(@truncate(@as(u2, @intCast(build_rand.nextIntBound(4) catch unreachable))));
    st.pieces[0] = .{
        .kind = .well,
        .mode = wmode,
        .box = BBox.init(wx, 64, wz, wx + 5, 78, wz + 5),
        .depth = 0,
        .desert = st.desert,
    };
    st.n = 1;
    st.well_x = wx;
    st.well_z = wz;
    expandWell(&st, bio, alloc, build_rand);
    // Pending loop: roads first (`avo` ctor).
    while (st.nh > 0 or st.nr > 0) {
        if (st.nr == 0) {
            const ri: usize = @intCast(build_rand.nextIntBound(@intCast(st.nh)) catch unreachable);
            const idx = st.pend_h[ri];
            st.pend_h[ri] = st.pend_h[st.nh - 1];
            st.nh -= 1;
            _ = idx; // houses/lamps are terminal (base `avk.a` no-op)
        } else {
            const ri: usize = @intCast(build_rand.nextIntBound(@intCast(st.nr)) catch unreachable);
            const idx = st.pend_r[ri];
            st.pend_r[ri] = st.pend_r[st.nr - 1];
            st.nr -= 1;
            expandRoad(&st, bio, alloc, build_rand, idx);
        }
    }
    // Validity: more than 2 non-road pieces (`avo.c`).
    var count: i32 = 0;
    for (st.pieces[0..st.n]) |pc| {
        if (pc.kind != .road) count += 1;
    }
    if (count <= 2) return false;
    // Placement in insertion order (`avm.a`).
    var placed = false;
    for (st.pieces[0..st.n]) |*pc| {
        if (!pc.box.intersects(clip)) continue;
        placed = true;
        switch (pc.kind) {
            .well => placeWell(p, clip, pc),
            .big_house => placeBigHouse(p, clip, pc),
            .farm_large, .farm_small => placeFarm(p, clip, place_rand, pc),
            .lamp => placeLamp(p, clip, pc),
            .small_house => placeSmallHouse(p, clip, pc),
            .hut => placeHut(p, clip, pc),
            .smithy_small => placeSmithySmall(p, clip, pc),
            .church => placeChurch(p, clip, pc),
            .smithy => placeSmithy(p, clip, place_rand, pc),
            .town_hall => placeTownHall(p, clip, pc),
            .road => placeRoad(p, clip, pc),
        }
    }
    return placed;
}

const std = @import("std");

// UNCERTAIN:
// - Door hinge side: comp.placeDoor replicates ach.a via the canonical
//   normal-cube table; hinge bit itself writes no RNG and doesn't shift
//   the stream, but exact hinge polarity vs the jar is trusted from the
//   scattered port, not re-verified here.
// - Step-block air-material checks use block id (.air) instead of
//   material (.o() == awt.a); equivalent for all blocks that can occur
//   at those spots (only air uses Material air in 1.7.10).
// - Villager profession values (this.b(int): houses 1/4/0/2/3) select the
//   spawned entity type but use no RNG; the Placer.spawn hook carries
//   kind+position only, so the value is dropped with no stream effect.
// - Road y uses topY-1 with no guard (vanilla setBlock has none either).
// - `qh.a` min>=max short-circuits with no draw (jar-verified); with
//   size 0 all village calls have min<max so every call draws.
// - Well/roads never re-level (no k logic in awf/awe); houses shift once
//   on first placement inside the populate clip (jar-verbatim).
