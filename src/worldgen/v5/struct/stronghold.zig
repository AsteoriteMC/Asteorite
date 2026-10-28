//! Stronghold generation (vanilla `aug` MapGen + `auh` start + `aui` piece
//! family: aum/aun/auo/aup/auq/aus/aut/auu/auv/ava/avb + abstract avc/auy
//! + start auz, jar-verified verbatim, including RNG order).
//!
//! Conventions (same as scattered.zig):
//! - `comp.placeAt` is RAW (jar: `placeBlockAtCurrentPosition` does NOT
//!   rotate); `comp.rotateMeta` is used ONLY where vanilla explicitly calls
//!   `getMetadataWithOffset` (door metas, button metas, stair/ladder metas).
//! - Fills (`fillBox`/`fillBoxMeta`/selector/random) never rotate.
//! - Selector fills replicate `avk` par9 semantics: par9=true replaces only
//!   non-air cells (RNG drawn only there); par9=false always replaces.
//!   (This is the INVERSE of `comp.fillBoxChoose`'s `replace_air_only`,
//!   hence the local `fillSelector` helper.)
//! - Chest loot contents are discarded but every RNG draw is replicated,
//!   including the enchanted-book `qx` appended at all four chest sites
//!   (`acm.a` is always level 30; `b(rand)` = `a(rand,1,1,1)`).

const std = @import("std");
const ids = @import("../../../ids.zig");
const bbox_mod = @import("bbox.zig");
const comp_mod = @import("comp.zig");
const loot_mod = @import("loot.zig");
const mapgen_mod = @import("mapgen.zig");
const placer_mod = @import("placer.zig");
const java_random = @import("../../rng/java_random.zig");

pub const BBox = bbox_mod.BBox;
pub const Component = comp_mod.Component;
pub const Placer = placer_mod.Placer;
pub const JavaRandom = java_random.JavaRandom;
pub const Facing = bbox_mod.Facing;

/// canSpawn for a start chunk: chunk must equal one of the three ring
/// positions (`aug.a` initial loop; positions come from
/// `mapgen.StrongholdPositions.compute`, jar-verified there).
pub fn canSpawn(pos: *const mapgen_mod.StrongholdPositions, sx: i32, sz: i32) bool {
    return pos.isStrongholdChunk(sx, sz);
}

// ---------------------------------------------------------------------------
// Entry door (`avd`: a=OPENING, b=WOOD_DOOR, c=GRATES, d=IRON_DOOR).
// ---------------------------------------------------------------------------

pub const Door = enum(u2) {
    opening = 0,
    wood = 1,
    grates = 2,
    iron = 3,
};

/// `avc.a(Random)`: nextInt(5): 0,1 -> opening; 2 -> wood; 3 -> grates;
/// 4 -> iron.
fn drawDoor(rand: *JavaRandom) Door {
    return switch (rand.nextIntBound(5) catch unreachable) {
        0, 1 => .opening,
        2 => .wood,
        3 => .grates,
        else => .iron,
    };
}

/// `avc.a(World,Random,Box,Door,x,y,z)` placeDoor. Rand is unused by vanilla.
/// All single placements are RAW; button metas are pre-rotated once via
/// `getMetadataWithOffset` (jar: inner `this.a(block,meta)` call).
fn placeDoor(p: Placer, c: Component, clip: BBox, door: Door, x: i32, y: i32, z: i32) void {
    switch (door) {
        .opening => {
            comp_mod.fillBox(p, c, clip, x, y, z, x + 2, y + 2, z, .air, .air, false);
        },
        .wood => {
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, x, y, z);
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, x, y + 1, z);
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, x, y + 2, z);
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, x + 1, y + 2, z);
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, x + 2, y + 2, z);
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, x + 2, y + 1, z);
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, x + 2, y, z);
            comp_mod.placeAt(p, c, clip, .wooden_door_block, 0, x + 1, y, z);
            comp_mod.placeAt(p, c, clip, .wooden_door_block, 8, x + 1, y + 1, z);
        },
        .grates => {
            comp_mod.placeAt(p, c, clip, .air, 0, x + 1, y, z);
            comp_mod.placeAt(p, c, clip, .air, 0, x + 1, y + 1, z);
            comp_mod.placeAt(p, c, clip, .iron_bars, 0, x, y, z);
            comp_mod.placeAt(p, c, clip, .iron_bars, 0, x, y + 1, z);
            comp_mod.placeAt(p, c, clip, .iron_bars, 0, x, y + 2, z);
            comp_mod.placeAt(p, c, clip, .iron_bars, 0, x + 1, y + 2, z);
            comp_mod.placeAt(p, c, clip, .iron_bars, 0, x + 2, y + 2, z);
            comp_mod.placeAt(p, c, clip, .iron_bars, 0, x + 2, y + 1, z);
            comp_mod.placeAt(p, c, clip, .iron_bars, 0, x + 2, y, z);
        },
        .iron => {
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, x, y, z);
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, x, y + 1, z);
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, x, y + 2, z);
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, x + 1, y + 2, z);
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, x + 2, y + 2, z);
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, x + 2, y + 1, z);
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, x + 2, y, z);
            comp_mod.placeAt(p, c, clip, .iron_door_block, 0, x + 1, y, z);
            comp_mod.placeAt(p, c, clip, .iron_door_block, 8, x + 1, y + 1, z);
            comp_mod.placeAt(p, c, clip, .stone_button, comp_mod.rotateMeta(.stone_button, 4, c.mode), x + 2, y + 1, z + 1);
            comp_mod.placeAt(p, c, clip, .stone_button, comp_mod.rotateMeta(.stone_button, 3, c.mode), x + 2, y + 1, z - 1);
        },
    }
}

// ---------------------------------------------------------------------------
// Stone-brick selector (`auw extends avl`, singleton `aui.e`).
// ---------------------------------------------------------------------------

/// Edge -> stonebrick variants (20% cracked/2, 30% mossy/1, 5% silverfish
/// block aU/2, else normal/0); interior -> air. One nextFloat per call.
fn strongholdChoose(rand: *JavaRandom, edge: bool) placer_mod.Block {
    if (!edge) return .{ .id = .air, .meta = 0 };
    const r = rand.nextFloat();
    if (r < 0.2) return .{ .id = .stonebrick, .meta = 2 };
    if (r < 0.5) return .{ .id = .stonebrick, .meta = 1 };
    if (r < 0.55) return .{ .id = .monster_egg, .meta = 2 };
    return .{ .id = .stonebrick, .meta = 0 };
}

/// `avk` randomized fill (`aui.c()` selector overload). `replace_non_air_only`
/// is vanilla par9 (true = skip air cells, no draw there).
fn fillSelector(
    p: Placer,
    c: Component,
    clip: BBox,
    rand: *JavaRandom,
    x0: i32,
    y0: i32,
    z0: i32,
    x1: i32,
    y1: i32,
    z1: i32,
    replace_non_air_only: bool,
) void {
    var y = y0;
    while (y <= y1) : (y += 1) {
        var x = x0;
        while (x <= x1) : (x += 1) {
            var z = z0;
            while (z <= z1) : (z += 1) {
                if (replace_non_air_only and comp_mod.getAt(p, c, clip, x, y, z).id == .air) continue;
                const edge = y == y0 or y == y1 or x == x0 or x == x1 or z == z0 or z == z1;
                const blk = strongholdChoose(rand, edge);
                // Rotation is identity for stonebrick/monster_egg.
                comp_mod.placeAt(p, c, clip, blk.id, blk.meta, x, y, z);
            }
        }
    }
}

/// `avk.a(World,Box)` liquid check: shell of the (piece box expanded by 1)
/// clamped to the populate box (`isLiquidInStructureBoundingBox`).
fn liquidInPiece(p: Placer, c: Component, clip: BBox) bool {
    const x0 = @max(c.box.min_x - 1, clip.min_x);
    const y0 = @max(c.box.min_y - 1, clip.min_y);
    const z0 = @max(c.box.min_z - 1, clip.min_z);
    const x1 = @min(c.box.max_x + 1, clip.max_x);
    const y1 = @min(c.box.max_y + 1, clip.max_y);
    const z1 = @min(c.box.max_z + 1, clip.max_z);
    var x = x0;
    while (x <= x1) : (x += 1) {
        var z = z0;
        while (z <= z1) : (z += 1) {
            if (placer_mod.isLiquidId(p.get(x, y0, z).id)) return true;
            if (placer_mod.isLiquidId(p.get(x, y1, z).id)) return true;
        }
    }
    var xx = x0;
    while (xx <= x1) : (xx += 1) {
        var y = y0;
        while (y <= y1) : (y += 1) {
            if (placer_mod.isLiquidId(p.get(xx, y, z0).id)) return true;
            if (placer_mod.isLiquidId(p.get(xx, y, z1).id)) return true;
        }
    }
    var zz = z0;
    while (zz <= z1) : (zz += 1) {
        var yy = y0;
        while (yy <= y1) : (yy += 1) {
            if (placer_mod.isLiquidId(p.get(x0, yy, zz).id)) return true;
            if (placer_mod.isLiquidId(p.get(x1, yy, zz).id)) return true;
        }
    }
    return false;
}

/// `asv.a(x,y,z,ox,oy,oz,w,h,d,facing)` oriented box with local offset.
fn offsetBox(x: i32, y: i32, z: i32, ox: i32, oy: i32, oz: i32, w: i32, h: i32, d: i32, mode: Facing) BBox {
    return switch (mode) {
        .south => BBox.init(x + ox, y + oy, z + oz, x + ox + w - 1, y + oy + h - 1, z + oz + d - 1),
        .west => BBox.init(x - d + 1 + oz, y + oy, z + ox, x + ox, y + oy + h - 1, z + ox + w - 1),
        .north => BBox.init(x + ox, y + oy, z - d + 1 + oz, x + ox + w - 1, y + oy + h - 1, z + oz),
        .east => BBox.init(x + oz, y + oy, z + ox, x + oz + d - 1, y + oy + h - 1, z + ox + w - 1),
    };
}

/// `avc.a(Box)`: candidate fits iff minY > 10.
fn fits(box: BBox) bool {
    return box.min_y > 10;
}

// ---------------------------------------------------------------------------
// Pieces + builder (start `auh` + `aui` weight state).
// ---------------------------------------------------------------------------

/// Behavioural piece kinds. NOTE: `auu` (SHRT) has no factory of its own —
/// `aui` calls the inherited `aup.a`, so SHRT entries spawn LeftTurn
/// behaviour; the factory maps them to `.left_turn` (jar-verified quirk).
pub const PieceKind = enum {
    spiral, // auy spiral staircase (+ auz start behaviour via .source)
    stairs, // ava SHS
    prison, // aut SHPH
    left_turn, // aup SHLT (also auu SHRT entries)
    room_crossing, // auv SHRC
    straight_stair, // avb SHSSD
    crossing, // auo SH5C
    chest_corridor, // aum SHCC
    library, // auq SHLi
    portal, // aus SHPR
    corridor, // aun SHFC fallback
};

pub const Piece = struct {
    kind: PieceKind,
    mode: Facing,
    box: BBox,
    depth: i32,
    door: Door = .opening,
    left: bool = false, // ava left opening
    right: bool = false, // ava right opening
    low_l: bool = false, // auo leftLow
    high_l: bool = false, // auo leftHigh
    low_r: bool = false, // auo rightLow
    high_r: bool = false, // auo rightHigh
    chest_done: bool = false, // aum hasMadeChest
    steps: i32 = 0, // aun segment count
    tall: bool = false, // auq two-floor flag
    mob_done: bool = false, // aus Mob flag
    room_type: i32 = 0, // auv Type
    source: bool = false, // auy Source (start stairs)
};

/// Factory tags: one per `aui.b` weight entry (order = jar static init).
const FactoryTag = enum {
    stairs,
    prison,
    left_turn,
    right_turn, // behaves as left_turn (see PieceKind note)
    room_crossing,
    straight_stair,
    spiral,
    crossing,
    chest_corridor,
    library,
    portal,
};

const Weight = struct {
    factory: FactoryTag,
    weight: i32,
    placed: i32 = 0,
    limit: i32,
    min_depth: i32 = 0, // auj needs depth>4, auk needs depth>5
    active: bool = true,

    fn canSpawnMore(w: *const Weight, depth: i32) bool {
        return (w.limit == 0 or w.placed < w.limit) and depth > w.min_depth;
    }
    fn canSpawnAgain(w: *const Weight) bool {
        return w.limit == 0 or w.placed < w.limit;
    }
};

pub const MAX_PIECES: usize = 512;

pub const Builder = struct {
    pieces: [MAX_PIECES]Piece = undefined,
    n: usize = 0,
    pending: [MAX_PIECES]u32 = undefined,
    m: usize = 0,
    weights: [11]Weight = undefined,
    forced: ?FactoryTag = null, // aui.d
    last_weight: ?usize = null, // auz.a
    start: u32 = 0,
    portal_idx: ?u32 = null, // auz.b
    portal: bool = false,
    union_box: BBox = BBox.empty(),

    pub fn reset(b: *Builder) void {
        // `aui.b()`: reset counts, re-add entries in static order, d = null.
        b.weights = .{
            .{ .factory = .stairs, .weight = 40, .limit = 0 },
            .{ .factory = .prison, .weight = 5, .limit = 5 },
            .{ .factory = .left_turn, .weight = 20, .limit = 0 },
            .{ .factory = .right_turn, .weight = 20, .limit = 0 },
            .{ .factory = .room_crossing, .weight = 10, .limit = 6 },
            .{ .factory = .straight_stair, .weight = 5, .limit = 5 },
            .{ .factory = .spiral, .weight = 5, .limit = 5 },
            .{ .factory = .crossing, .weight = 5, .limit = 4 },
            .{ .factory = .chest_corridor, .weight = 5, .limit = 4 },
            .{ .factory = .library, .weight = 10, .limit = 2, .min_depth = 4 },
            .{ .factory = .portal, .weight = 20, .limit = 1, .min_depth = 5 },
        };
        b.n = 0;
        b.m = 0;
        b.forced = null;
        b.last_weight = null;
        b.portal_idx = null;
        b.portal = false;
        b.union_box = BBox.empty();
    }

    fn insert(b: *Builder, pc: Piece) ?u32 {
        if (b.n >= MAX_PIECES) return null; // vanilla is unbounded; unreachable in practice
        b.pieces[b.n] = pc;
        const idx: u32 = @intCast(b.n);
        b.n += 1;
        return idx;
    }

    fn addPending(b: *Builder, idx: u32) void {
        if (b.m >= MAX_PIECES) return;
        b.pending[b.m] = idx;
        b.m += 1;
    }

    /// `avk.a(List,Box)` findIntersecting over built pieces.
    fn intersecting(b: *const Builder, box: BBox) bool {
        var i: usize = 0;
        while (i < b.n) : (i += 1) {
            if (b.pieces[i].box.intersects(box)) return true;
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// Finders (`aui.a` dispatch + per-class static `a`).
// ---------------------------------------------------------------------------

fn tryFind(b: *Builder, tag: FactoryTag, rand: *JavaRandom, x: i32, y: i32, z: i32, mode: Facing, depth: i32) ?Piece {
    switch (tag) {
        .stairs => {
            const box = offsetBox(x, y, z, -1, -1, 0, 5, 5, 7, mode);
            if (!fits(box) or b.intersecting(box)) return null;
            return .{
                .kind = .stairs,
                .mode = mode,
                .box = box,
                .depth = depth,
                .door = drawDoor(rand),
                .left = (rand.nextIntBound(2) catch unreachable) == 0,
                .right = (rand.nextIntBound(2) catch unreachable) == 0,
            };
        },
        .prison => {
            const box = offsetBox(x, y, z, -1, -1, 0, 9, 5, 11, mode);
            if (!fits(box) or b.intersecting(box)) return null;
            return .{ .kind = .prison, .mode = mode, .box = box, .depth = depth, .door = drawDoor(rand) };
        },
        .left_turn, .right_turn => {
            // auu inherits aup.a: same box, aup behaviour.
            const box = offsetBox(x, y, z, -1, -1, 0, 5, 5, 5, mode);
            if (!fits(box) or b.intersecting(box)) return null;
            return .{ .kind = .left_turn, .mode = mode, .box = box, .depth = depth, .door = drawDoor(rand) };
        },
        .room_crossing => {
            const box = offsetBox(x, y, z, -4, -1, 0, 11, 7, 11, mode);
            if (!fits(box) or b.intersecting(box)) return null;
            return .{
                .kind = .room_crossing,
                .mode = mode,
                .box = box,
                .depth = depth,
                .door = drawDoor(rand),
                .room_type = rand.nextIntBound(5) catch unreachable,
            };
        },
        .straight_stair => {
            const box = offsetBox(x, y, z, -1, -7, 0, 5, 11, 8, mode);
            if (!fits(box) or b.intersecting(box)) return null;
            return .{ .kind = .straight_stair, .mode = mode, .box = box, .depth = depth, .door = drawDoor(rand) };
        },
        .spiral => {
            const box = offsetBox(x, y, z, -1, -7, 0, 5, 11, 5, mode);
            if (!fits(box) or b.intersecting(box)) return null;
            return .{ .kind = .spiral, .mode = mode, .box = box, .depth = depth, .door = drawDoor(rand) };
        },
        .crossing => {
            const box = offsetBox(x, y, z, -4, -3, 0, 10, 9, 11, mode);
            if (!fits(box) or b.intersecting(box)) return null;
            return .{
                .kind = .crossing,
                .mode = mode,
                .box = box,
                .depth = depth,
                .door = drawDoor(rand),
                .low_l = rand.nextBoolean(),
                .high_l = rand.nextBoolean(),
                .low_r = rand.nextBoolean(),
                .high_r = (rand.nextIntBound(3) catch unreachable) > 0,
            };
        },
        .chest_corridor => {
            const box = offsetBox(x, y, z, -1, -1, 0, 5, 5, 7, mode);
            if (!fits(box) or b.intersecting(box)) return null;
            return .{ .kind = .chest_corridor, .mode = mode, .box = box, .depth = depth, .door = drawDoor(rand) };
        },
        .library => {
            var box = offsetBox(x, y, z, -4, -1, 0, 14, 11, 15, mode);
            if (!fits(box) or b.intersecting(box)) {
                box = offsetBox(x, y, z, -4, -1, 0, 14, 6, 15, mode);
                if (!fits(box) or b.intersecting(box)) return null;
            }
            return .{
                .kind = .library,
                .mode = mode,
                .box = box,
                .depth = depth,
                .door = drawDoor(rand),
                .tall = (box.max_y - box.min_y + 1) > 6,
            };
        },
        .portal => {
            const box = offsetBox(x, y, z, -4, -1, 0, 11, 8, 16, mode);
            if (!fits(box) or b.intersecting(box)) return null;
            return .{ .kind = .portal, .mode = mode, .box = box, .depth = depth };
        },
    }
}

/// `aun.a(List,Random,x,y,z,facing)`: corridor box only if it clips an
/// existing piece with equal minY; shrink-tested 3,2,1 (no RNG).
fn findCorridorBox(b: *Builder, x: i32, y: i32, z: i32, mode: Facing) ?BBox {
    const full = offsetBox(x, y, z, -1, -1, 0, 5, 5, 4, mode);
    var hit: ?BBox = null;
    var i: usize = 0;
    while (i < b.n) : (i += 1) {
        if (b.pieces[i].box.intersects(full)) {
            hit = b.pieces[i].box;
            break;
        }
    }
    const hb = hit orelse return null;
    if (hb.min_y != full.min_y) return null;
    var len: i32 = 3;
    while (len >= 1) : (len -= 1) {
        const test_box = offsetBox(x, y, z, -1, -1, 0, 5, 5, len - 1, mode);
        if (!hb.intersects(test_box)) {
            return offsetBox(x, y, z, -1, -1, 0, 5, 5, len, mode);
        }
    }
    return null;
}

/// `aui.b`: weighted pick with forced-class head, 5 tries, corridor fallback.
fn auiPick(b: *Builder, rand: *JavaRandom, x: i32, y: i32, z: i32, mode: Facing, depth: i32) ?Piece {
    var total: i32 = 0;
    var any = false;
    for (&b.weights) |*w| {
        if (!w.active) continue;
        if (w.limit > 0 and w.placed < w.limit) any = true;
        total += w.weight;
    }
    if (!any) return null;
    if (b.forced) |fk| {
        b.forced = null;
        if (tryFind(b, fk, rand, x, y, z, mode, depth)) |pc| return pc;
    }
    var tries: i32 = 0;
    while (tries < 5) : (tries += 1) {
        var roll = rand.nextIntBound(total) catch unreachable;
        for (&b.weights, 0..) |*w, wi| {
            if (!w.active) continue;
            roll -= w.weight;
            if (roll < 0) {
                if (!w.canSpawnMore(depth) or (b.last_weight != null and b.last_weight.? == wi)) break;
                if (tryFind(b, w.factory, rand, x, y, z, mode, depth)) |pc| {
                    w.placed += 1;
                    b.last_weight = wi;
                    if (!w.canSpawnAgain()) w.active = false;
                    return pc;
                }
            }
        }
    }
    const cb = findCorridorBox(b, x, y, z, mode) orelse return null;
    if (cb.min_y <= 1) return null;
    const steps: i32 = switch (mode) {
        .south, .north => cb.max_z - cb.min_z + 1,
        .west, .east => cb.max_x - cb.min_x + 1,
    };
    return .{ .kind = .corridor, .mode = mode, .box = cb, .depth = depth, .steps = steps };
}

/// `aui.c` (+ package `aui.a` delegate): depth/distance gate, add on success.
fn auiAdd(b: *Builder, rand: *JavaRandom, x: i32, y: i32, z: i32, mode: Facing, parent_depth: i32) ?u32 {
    if (parent_depth > 50) return null;
    const s = b.pieces[b.start].box;
    if (@abs(x - s.min_x) > 112 or @abs(z - s.min_z) > 112) return null;
    const pc = auiPick(b, rand, x, y, z, mode, parent_depth + 1) orelse return null;
    const idx = b.insert(pc) orelse return null;
    b.addPending(idx);
    return idx;
}

// ---------------------------------------------------------------------------
// Attach helpers (`avc.a/b/c`: forward/left/right from this piece).
// ---------------------------------------------------------------------------

fn attachForward(b: *Builder, idx: u32, rand: *JavaRandom, dx: i32, dy: i32) ?u32 {
    const pc = b.pieces[idx];
    return switch (pc.mode) {
        .south => auiAdd(b, rand, pc.box.min_x + dx, pc.box.min_y + dy, pc.box.max_z + 1, pc.mode, pc.depth),
        .west => auiAdd(b, rand, pc.box.min_x - 1, pc.box.min_y + dy, pc.box.min_z + dx, pc.mode, pc.depth),
        .north => auiAdd(b, rand, pc.box.min_x + dx, pc.box.min_y + dy, pc.box.min_z - 1, pc.mode, pc.depth),
        .east => auiAdd(b, rand, pc.box.max_x + 1, pc.box.min_y + dy, pc.box.min_z + dx, pc.mode, pc.depth),
    };
}

fn attachLeft(b: *Builder, idx: u32, rand: *JavaRandom, dx: i32, dy: i32) ?u32 {
    const pc = b.pieces[idx];
    return switch (pc.mode) {
        .south, .north => auiAdd(b, rand, pc.box.min_x - 1, pc.box.min_y + dx, pc.box.min_z + dy, .west, pc.depth),
        .west, .east => auiAdd(b, rand, pc.box.min_x + dy, pc.box.min_y + dx, pc.box.min_z - 1, .north, pc.depth),
    };
}

fn attachRight(b: *Builder, idx: u32, rand: *JavaRandom, dx: i32, dy: i32) ?u32 {
    const pc = b.pieces[idx];
    return switch (pc.mode) {
        .south, .north => auiAdd(b, rand, pc.box.max_x + 1, pc.box.min_y + dx, pc.box.min_z + dy, .east, pc.depth),
        .west, .east => auiAdd(b, rand, pc.box.min_x + dy, pc.box.min_y + dx, pc.box.max_z + 1, .south, pc.depth),
    };
}

/// buildComponent dispatch (`avk.a(avk,List,Random)` overrides).
fn buildComponent(b: *Builder, idx: u32, rand: *JavaRandom) void {
    const pc = b.pieces[idx];
    switch (pc.kind) {
        .spiral => {
            if (pc.source) b.forced = .crossing; // auy: aui.a(auo.class)
            _ = attachForward(b, idx, rand, 1, 1);
        },
        .stairs => {
            _ = attachForward(b, idx, rand, 1, 1);
            if (pc.left) _ = attachLeft(b, idx, rand, 1, 2);
            if (pc.right) _ = attachRight(b, idx, rand, 1, 2);
        },
        .prison => {
            _ = attachForward(b, idx, rand, 1, 1);
        },
        .left_turn => {
            if (pc.mode != .north and pc.mode != .east) {
                _ = attachRight(b, idx, rand, 1, 1);
            } else {
                _ = attachLeft(b, idx, rand, 1, 1);
            }
        },
        .room_crossing => {
            _ = attachForward(b, idx, rand, 4, 1);
            _ = attachLeft(b, idx, rand, 1, 4);
            _ = attachRight(b, idx, rand, 1, 4);
        },
        .straight_stair => {
            _ = attachForward(b, idx, rand, 1, 1);
        },
        .crossing => {
            var v4: i32 = 3;
            var v5: i32 = 5;
            if (pc.mode == .west or pc.mode == .north) {
                v4 = 8 - v4;
                v5 = 8 - v5;
            }
            _ = attachForward(b, idx, rand, 5, 1);
            if (pc.low_l) _ = attachLeft(b, idx, rand, v4, 1);
            if (pc.high_l) _ = attachLeft(b, idx, rand, v5, 7);
            if (pc.low_r) _ = attachRight(b, idx, rand, v4, 1);
            if (pc.high_r) _ = attachRight(b, idx, rand, v5, 7);
        },
        .chest_corridor => {
            _ = attachForward(b, idx, rand, 1, 1);
        },
        .library => {},
        .portal => {
            b.portal_idx = idx;
            b.portal = true;
        },
        .corridor => {},
    }
}

// ---------------------------------------------------------------------------
// Extended chest tables (base + appended enchanted-book `qx`).
// ---------------------------------------------------------------------------

/// aum book: `ade.bR.b(rand)` = weight 1, 1-1.
const crossing_chest_table = loot_mod.stronghold_crossing ++ [_]loot_mod.Entry{
    .{ .limit = 1, .weight = 1, .min = 1, .max = 1 },
};

/// auq book: `ade.bR.a(rand,1,5,2)` = weight 2, 1-5.
const library_chest_table = loot_mod.stronghold_library ++ [_]loot_mod.Entry{
    .{ .limit = 1, .weight = 2, .min = 1, .max = 5 },
};

/// auv book: `ade.bR.b(rand)` = weight 1, 1-1.
const corridor_chest_table = loot_mod.stronghold_corridor ++ [_]loot_mod.Entry{
    .{ .limit = 1, .weight = 1, .min = 1, .max = 1 },
};

// ---------------------------------------------------------------------------
// Placement (`avk.a(World,Random,Box)` overrides).
// ---------------------------------------------------------------------------

fn compOf(pc: *const Piece) Component {
    return .{ .mode = pc.mode, .box = pc.box };
}

fn genSpiral(p: Placer, pc: *Piece, rand: *JavaRandom, clip: BBox) bool {
    const c = compOf(pc);
    if (liquidInPiece(p, c, clip)) return false;
    fillSelector(p, c, clip, rand, 0, 0, 0, 4, 10, 4, true);
    placeDoor(p, c, clip, pc.door, 1, 7, 0);
    placeDoor(p, c, clip, .opening, 1, 1, 4);
    comp_mod.placeAt(p, c, clip, .stonebrick, 0, 2, 6, 1);
    comp_mod.placeAt(p, c, clip, .stonebrick, 0, 1, 5, 1);
    comp_mod.placeAt(p, c, clip, .stone_slab, 0, 1, 6, 1);
    comp_mod.placeAt(p, c, clip, .stonebrick, 0, 1, 5, 2);
    comp_mod.placeAt(p, c, clip, .stonebrick, 0, 1, 4, 3);
    comp_mod.placeAt(p, c, clip, .stone_slab, 0, 1, 5, 3);
    comp_mod.placeAt(p, c, clip, .stonebrick, 0, 2, 4, 3);
    comp_mod.placeAt(p, c, clip, .stonebrick, 0, 3, 3, 3);
    comp_mod.placeAt(p, c, clip, .stone_slab, 0, 3, 4, 3);
    comp_mod.placeAt(p, c, clip, .stonebrick, 0, 3, 3, 2);
    comp_mod.placeAt(p, c, clip, .stonebrick, 0, 3, 2, 1);
    comp_mod.placeAt(p, c, clip, .stone_slab, 0, 3, 3, 1);
    comp_mod.placeAt(p, c, clip, .stonebrick, 0, 2, 2, 1);
    comp_mod.placeAt(p, c, clip, .stonebrick, 0, 1, 1, 1);
    comp_mod.placeAt(p, c, clip, .stone_slab, 0, 1, 2, 1);
    comp_mod.placeAt(p, c, clip, .stonebrick, 0, 1, 1, 2);
    comp_mod.placeAt(p, c, clip, .stone_slab, 0, 1, 1, 3);
    return true;
}

fn genStairs(p: Placer, pc: *Piece, rand: *JavaRandom, clip: BBox) bool {
    const c = compOf(pc);
    if (liquidInPiece(p, c, clip)) return false;
    fillSelector(p, c, clip, rand, 0, 0, 0, 4, 4, 6, true);
    placeDoor(p, c, clip, pc.door, 1, 1, 0);
    placeDoor(p, c, clip, .opening, 1, 1, 6);
    comp_mod.placeRandom(p, c, clip, rand, 0.1, 1, 2, 1, .torch, 0);
    comp_mod.placeRandom(p, c, clip, rand, 0.1, 3, 2, 1, .torch, 0);
    comp_mod.placeRandom(p, c, clip, rand, 0.1, 1, 2, 5, .torch, 0);
    comp_mod.placeRandom(p, c, clip, rand, 0.1, 3, 2, 5, .torch, 0);
    if (pc.left) comp_mod.fillBox(p, c, clip, 0, 1, 2, 0, 3, 4, .air, .air, false);
    if (pc.right) comp_mod.fillBox(p, c, clip, 4, 1, 2, 4, 3, 4, .air, .air, false);
    return true;
}

fn genPrison(p: Placer, pc: *Piece, rand: *JavaRandom, clip: BBox) bool {
    const c = compOf(pc);
    if (liquidInPiece(p, c, clip)) return false;
    fillSelector(p, c, clip, rand, 0, 0, 0, 8, 4, 10, true);
    placeDoor(p, c, clip, pc.door, 1, 1, 0);
    comp_mod.fillBox(p, c, clip, 1, 1, 10, 3, 3, 10, .air, .air, false);
    fillSelector(p, c, clip, rand, 4, 1, 1, 4, 3, 1, false);
    fillSelector(p, c, clip, rand, 4, 1, 3, 4, 3, 3, false);
    fillSelector(p, c, clip, rand, 4, 1, 7, 4, 3, 7, false);
    fillSelector(p, c, clip, rand, 4, 1, 9, 4, 3, 9, false);
    comp_mod.fillBox(p, c, clip, 4, 1, 4, 4, 3, 6, .iron_bars, .iron_bars, false);
    comp_mod.fillBox(p, c, clip, 5, 1, 5, 7, 3, 5, .iron_bars, .iron_bars, false);
    comp_mod.placeAt(p, c, clip, .iron_bars, 0, 4, 3, 2);
    comp_mod.placeAt(p, c, clip, .iron_bars, 0, 4, 3, 8);
    const d3 = comp_mod.rotateMeta(.iron_door_block, 3, c.mode);
    comp_mod.placeAt(p, c, clip, .iron_door_block, d3, 4, 1, 2);
    comp_mod.placeAt(p, c, clip, .iron_door_block, d3 + 8, 4, 2, 2);
    comp_mod.placeAt(p, c, clip, .iron_door_block, d3, 4, 1, 8);
    comp_mod.placeAt(p, c, clip, .iron_door_block, d3 + 8, 4, 2, 8);
    return true;
}

fn genLeftTurn(p: Placer, pc: *Piece, rand: *JavaRandom, clip: BBox) bool {
    const c = compOf(pc);
    if (liquidInPiece(p, c, clip)) return false;
    fillSelector(p, c, clip, rand, 0, 0, 0, 4, 4, 4, true);
    placeDoor(p, c, clip, pc.door, 1, 1, 0);
    if (pc.mode != .north and pc.mode != .east) {
        comp_mod.fillBox(p, c, clip, 4, 1, 1, 4, 3, 3, .air, .air, false);
    } else {
        comp_mod.fillBox(p, c, clip, 0, 1, 1, 0, 3, 3, .air, .air, false);
    }
    return true;
}

fn genRoomCrossing(p: Placer, pc: *Piece, rand: *JavaRandom, clip: BBox) bool {
    const c = compOf(pc);
    if (liquidInPiece(p, c, clip)) return false;
    fillSelector(p, c, clip, rand, 0, 0, 0, 10, 6, 10, true);
    placeDoor(p, c, clip, pc.door, 4, 1, 0);
    comp_mod.fillBox(p, c, clip, 4, 1, 10, 6, 3, 10, .air, .air, false);
    comp_mod.fillBox(p, c, clip, 0, 1, 4, 0, 3, 6, .air, .air, false);
    comp_mod.fillBox(p, c, clip, 10, 1, 4, 10, 3, 6, .air, .air, false);
    switch (pc.room_type) {
        0 => {
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, 5, 1, 5);
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, 5, 2, 5);
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, 5, 3, 5);
            comp_mod.placeAt(p, c, clip, .torch, 0, 4, 3, 5);
            comp_mod.placeAt(p, c, clip, .torch, 0, 6, 3, 5);
            comp_mod.placeAt(p, c, clip, .torch, 0, 5, 3, 4);
            comp_mod.placeAt(p, c, clip, .torch, 0, 5, 3, 6);
            comp_mod.placeAt(p, c, clip, .stone_slab, 0, 4, 1, 4);
            comp_mod.placeAt(p, c, clip, .stone_slab, 0, 4, 1, 5);
            comp_mod.placeAt(p, c, clip, .stone_slab, 0, 4, 1, 6);
            comp_mod.placeAt(p, c, clip, .stone_slab, 0, 6, 1, 4);
            comp_mod.placeAt(p, c, clip, .stone_slab, 0, 6, 1, 5);
            comp_mod.placeAt(p, c, clip, .stone_slab, 0, 6, 1, 6);
            comp_mod.placeAt(p, c, clip, .stone_slab, 0, 5, 1, 4);
            comp_mod.placeAt(p, c, clip, .stone_slab, 0, 5, 1, 6);
        },
        1 => {
            var v: i32 = 0;
            while (v < 5) : (v += 1) {
                comp_mod.placeAt(p, c, clip, .stonebrick, 0, 3, 1, 3 + v);
                comp_mod.placeAt(p, c, clip, .stonebrick, 0, 7, 1, 3 + v);
                comp_mod.placeAt(p, c, clip, .stonebrick, 0, 3 + v, 1, 3);
                comp_mod.placeAt(p, c, clip, .stonebrick, 0, 3 + v, 1, 7);
            }
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, 5, 1, 5);
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, 5, 2, 5);
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, 5, 3, 5);
            comp_mod.placeAt(p, c, clip, .flowing_water, 0, 5, 4, 5);
        },
        2 => {
            var v: i32 = 1;
            while (v <= 9) : (v += 1) {
                comp_mod.placeAt(p, c, clip, .cobblestone, 0, 1, 3, v);
                comp_mod.placeAt(p, c, clip, .cobblestone, 0, 9, 3, v);
            }
            v = 1;
            while (v <= 9) : (v += 1) {
                comp_mod.placeAt(p, c, clip, .cobblestone, 0, v, 3, 1);
                comp_mod.placeAt(p, c, clip, .cobblestone, 0, v, 3, 9);
            }
            comp_mod.placeAt(p, c, clip, .cobblestone, 0, 5, 1, 4);
            comp_mod.placeAt(p, c, clip, .cobblestone, 0, 5, 1, 6);
            comp_mod.placeAt(p, c, clip, .cobblestone, 0, 5, 3, 4);
            comp_mod.placeAt(p, c, clip, .cobblestone, 0, 5, 3, 6);
            comp_mod.placeAt(p, c, clip, .cobblestone, 0, 4, 1, 5);
            comp_mod.placeAt(p, c, clip, .cobblestone, 0, 6, 1, 5);
            comp_mod.placeAt(p, c, clip, .cobblestone, 0, 4, 3, 5);
            comp_mod.placeAt(p, c, clip, .cobblestone, 0, 6, 3, 5);
            v = 1;
            while (v <= 3) : (v += 1) {
                comp_mod.placeAt(p, c, clip, .cobblestone, 0, 4, v, 4);
                comp_mod.placeAt(p, c, clip, .cobblestone, 0, 6, v, 4);
                comp_mod.placeAt(p, c, clip, .cobblestone, 0, 4, v, 6);
                comp_mod.placeAt(p, c, clip, .cobblestone, 0, 6, v, 6);
            }
            comp_mod.placeAt(p, c, clip, .torch, 0, 5, 3, 5);
            v = 2;
            while (v <= 8) : (v += 1) {
                comp_mod.placeAt(p, c, clip, .planks, 0, 2, 3, v);
                comp_mod.placeAt(p, c, clip, .planks, 0, 3, 3, v);
                if (v <= 3 or v >= 7) {
                    comp_mod.placeAt(p, c, clip, .planks, 0, 4, 3, v);
                    comp_mod.placeAt(p, c, clip, .planks, 0, 5, 3, v);
                    comp_mod.placeAt(p, c, clip, .planks, 0, 6, 3, v);
                }
                comp_mod.placeAt(p, c, clip, .planks, 0, 7, 3, v);
                comp_mod.placeAt(p, c, clip, .planks, 0, 8, 3, v);
            }
            const lad = comp_mod.rotateMeta(.ladder, 4, c.mode);
            comp_mod.placeAt(p, c, clip, .ladder, lad, 9, 1, 3);
            comp_mod.placeAt(p, c, clip, .ladder, lad, 9, 2, 3);
            comp_mod.placeAt(p, c, clip, .ladder, lad, 9, 3, 3);
            loot_mod.replicateBookDraws(rand);
            const nrolls: i32 = 1 + (rand.nextIntBound(4) catch unreachable);
            _ = comp_mod.placeChest(p, c, clip, rand, 3, 4, 8, &corridor_chest_table, nrolls);
        },
        else => {},
    }
    return true;
}

fn genStraightStair(p: Placer, pc: *Piece, rand: *JavaRandom, clip: BBox) bool {
    const c = compOf(pc);
    if (liquidInPiece(p, c, clip)) return false;
    fillSelector(p, c, clip, rand, 0, 0, 0, 4, 10, 7, true);
    placeDoor(p, c, clip, pc.door, 1, 7, 0);
    placeDoor(p, c, clip, .opening, 1, 1, 7);
    const st = comp_mod.rotateMeta(.stone_stairs, 2, c.mode);
    var v: i32 = 0;
    while (v < 6) : (v += 1) {
        comp_mod.placeAt(p, c, clip, .stone_stairs, st, 1, 6 - v, 1 + v);
        comp_mod.placeAt(p, c, clip, .stone_stairs, st, 2, 6 - v, 1 + v);
        comp_mod.placeAt(p, c, clip, .stone_stairs, st, 3, 6 - v, 1 + v);
        if (v < 5) {
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, 1, 5 - v, 1 + v);
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, 2, 5 - v, 1 + v);
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, 3, 5 - v, 1 + v);
        }
    }
    return true;
}

fn genCrossing(p: Placer, pc: *Piece, rand: *JavaRandom, clip: BBox) bool {
    const c = compOf(pc);
    if (liquidInPiece(p, c, clip)) return false;
    fillSelector(p, c, clip, rand, 0, 0, 0, 9, 8, 10, true);
    placeDoor(p, c, clip, pc.door, 4, 3, 0);
    if (pc.low_l) comp_mod.fillBox(p, c, clip, 0, 3, 1, 0, 5, 3, .air, .air, false);
    if (pc.low_r) comp_mod.fillBox(p, c, clip, 9, 3, 1, 9, 5, 3, .air, .air, false);
    if (pc.high_l) comp_mod.fillBox(p, c, clip, 0, 5, 7, 0, 7, 9, .air, .air, false);
    if (pc.high_r) comp_mod.fillBox(p, c, clip, 9, 5, 7, 9, 7, 9, .air, .air, false);
    comp_mod.fillBox(p, c, clip, 5, 1, 10, 7, 3, 10, .air, .air, false);
    fillSelector(p, c, clip, rand, 1, 2, 1, 8, 2, 6, false);
    fillSelector(p, c, clip, rand, 4, 1, 5, 4, 4, 9, false);
    fillSelector(p, c, clip, rand, 8, 1, 5, 8, 4, 9, false);
    fillSelector(p, c, clip, rand, 1, 4, 7, 3, 4, 9, false);
    fillSelector(p, c, clip, rand, 1, 3, 5, 3, 3, 6, false);
    comp_mod.fillBox(p, c, clip, 1, 3, 4, 3, 3, 4, .stone_slab, .stone_slab, false);
    comp_mod.fillBox(p, c, clip, 1, 4, 6, 3, 4, 6, .stone_slab, .stone_slab, false);
    fillSelector(p, c, clip, rand, 5, 1, 7, 7, 1, 8, false);
    comp_mod.fillBox(p, c, clip, 5, 1, 9, 7, 1, 9, .stone_slab, .stone_slab, false);
    comp_mod.fillBox(p, c, clip, 5, 2, 7, 7, 2, 7, .stone_slab, .stone_slab, false);
    comp_mod.fillBox(p, c, clip, 4, 5, 7, 4, 5, 9, .stone_slab, .stone_slab, false);
    comp_mod.fillBox(p, c, clip, 8, 5, 7, 8, 5, 9, .stone_slab, .stone_slab, false);
    comp_mod.fillBox(p, c, clip, 5, 5, 7, 7, 5, 9, .double_stone_slab, .double_stone_slab, false);
    comp_mod.placeAt(p, c, clip, .torch, 0, 6, 5, 6);
    return true;
}

fn genChestCorridor(p: Placer, pc: *Piece, rand: *JavaRandom, clip: BBox) bool {
    const c = compOf(pc);
    if (liquidInPiece(p, c, clip)) return false;
    fillSelector(p, c, clip, rand, 0, 0, 0, 4, 4, 6, true);
    placeDoor(p, c, clip, pc.door, 1, 1, 0);
    placeDoor(p, c, clip, .opening, 1, 1, 6);
    comp_mod.fillBox(p, c, clip, 3, 1, 2, 3, 1, 4, .stonebrick, .stonebrick, false);
    comp_mod.placeAt(p, c, clip, .stone_slab, 5, 3, 1, 1);
    comp_mod.placeAt(p, c, clip, .stone_slab, 5, 3, 1, 5);
    comp_mod.placeAt(p, c, clip, .stone_slab, 5, 3, 2, 2);
    comp_mod.placeAt(p, c, clip, .stone_slab, 5, 3, 2, 4);
    var v: i32 = 2;
    while (v <= 4) : (v += 1) {
        comp_mod.placeAt(p, c, clip, .stone_slab, 5, 2, 1, v);
    }
    if (!pc.chest_done) {
        const wx = c.xWithOffset(3, 3);
        const wy = c.yWithOffset(2);
        const wz = c.zWithOffset(3, 3);
        if (clip.contains(wx, wy, wz)) {
            pc.chest_done = true;
            loot_mod.replicateBookDraws(rand);
            const nrolls: i32 = 2 + (rand.nextIntBound(2) catch unreachable);
            _ = comp_mod.placeChest(p, c, clip, rand, 3, 2, 3, &crossing_chest_table, nrolls);
        }
    }
    return true;
}

fn genCorridor(p: Placer, pc: *Piece, rand: *JavaRandom, clip: BBox) bool {
    _ = rand;
    const c = compOf(pc);
    // aun: no liquid check, always true.
    var s: i32 = 0;
    while (s < pc.steps) : (s += 1) {
        comp_mod.placeAt(p, c, clip, .stonebrick, 0, 0, 0, s);
        comp_mod.placeAt(p, c, clip, .stonebrick, 0, 1, 0, s);
        comp_mod.placeAt(p, c, clip, .stonebrick, 0, 2, 0, s);
        comp_mod.placeAt(p, c, clip, .stonebrick, 0, 3, 0, s);
        comp_mod.placeAt(p, c, clip, .stonebrick, 0, 4, 0, s);
        var w: i32 = 1;
        while (w <= 3) : (w += 1) {
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, 0, w, s);
            comp_mod.placeAt(p, c, clip, .air, 0, 1, w, s);
            comp_mod.placeAt(p, c, clip, .air, 0, 2, w, s);
            comp_mod.placeAt(p, c, clip, .air, 0, 3, w, s);
            comp_mod.placeAt(p, c, clip, .stonebrick, 0, 4, w, s);
        }
        comp_mod.placeAt(p, c, clip, .stonebrick, 0, 0, 4, s);
        comp_mod.placeAt(p, c, clip, .stonebrick, 0, 1, 4, s);
        comp_mod.placeAt(p, c, clip, .stonebrick, 0, 2, 4, s);
        comp_mod.placeAt(p, c, clip, .stonebrick, 0, 3, 4, s);
        comp_mod.placeAt(p, c, clip, .stonebrick, 0, 4, 4, s);
    }
    return true;
}

fn genLibrary(p: Placer, pc: *Piece, rand: *JavaRandom, clip: BBox) bool {
    const c = compOf(pc);
    // auq: no liquid check, always true.
    const h: i32 = if (pc.tall) 11 else 6;
    fillSelector(p, c, clip, rand, 0, 0, 0, 13, h - 1, 14, true);
    placeDoor(p, c, clip, pc.door, 4, 1, 0);
    comp_mod.fillBoxRandom(p, c, clip, rand, 0.07, 2, 1, 1, 11, 4, 13, .web, .web, false);
    var z: i32 = 1;
    while (z <= 13) : (z += 1) {
        if ((z - 1) % 4 == 0) {
            comp_mod.fillBox(p, c, clip, 1, 1, z, 1, 4, z, .planks, .planks, false);
            comp_mod.fillBox(p, c, clip, 12, 1, z, 12, 4, z, .planks, .planks, false);
            comp_mod.placeAt(p, c, clip, .torch, 0, 2, 3, z);
            comp_mod.placeAt(p, c, clip, .torch, 0, 11, 3, z);
            if (pc.tall) {
                comp_mod.fillBox(p, c, clip, 1, 6, z, 1, 9, z, .planks, .planks, false);
                comp_mod.fillBox(p, c, clip, 12, 6, z, 12, 9, z, .planks, .planks, false);
            }
        } else {
            comp_mod.fillBox(p, c, clip, 1, 1, z, 1, 4, z, .bookshelf, .bookshelf, false);
            comp_mod.fillBox(p, c, clip, 12, 1, z, 12, 4, z, .bookshelf, .bookshelf, false);
            if (pc.tall) {
                comp_mod.fillBox(p, c, clip, 1, 6, z, 1, 9, z, .bookshelf, .bookshelf, false);
                comp_mod.fillBox(p, c, clip, 12, 6, z, 12, 9, z, .bookshelf, .bookshelf, false);
            }
        }
    }
    var sz2: i32 = 3;
    while (sz2 < 12) : (sz2 += 2) {
        comp_mod.fillBox(p, c, clip, 3, 1, sz2, 4, 3, sz2, .bookshelf, .bookshelf, false);
        comp_mod.fillBox(p, c, clip, 6, 1, sz2, 7, 3, sz2, .bookshelf, .bookshelf, false);
        comp_mod.fillBox(p, c, clip, 9, 1, sz2, 10, 3, sz2, .bookshelf, .bookshelf, false);
    }
    if (pc.tall) {
        comp_mod.fillBox(p, c, clip, 1, 5, 1, 3, 5, 13, .planks, .planks, false);
        comp_mod.fillBox(p, c, clip, 10, 5, 1, 12, 5, 13, .planks, .planks, false);
        comp_mod.fillBox(p, c, clip, 4, 5, 1, 9, 5, 2, .planks, .planks, false);
        comp_mod.fillBox(p, c, clip, 4, 5, 12, 9, 5, 13, .planks, .planks, false);
        comp_mod.placeAt(p, c, clip, .planks, 0, 9, 5, 11);
        comp_mod.placeAt(p, c, clip, .planks, 0, 8, 5, 11);
        comp_mod.placeAt(p, c, clip, .planks, 0, 9, 5, 10);
        comp_mod.fillBox(p, c, clip, 3, 6, 2, 3, 6, 12, .fence, .fence, false);
        comp_mod.fillBox(p, c, clip, 10, 6, 2, 10, 6, 10, .fence, .fence, false);
        comp_mod.fillBox(p, c, clip, 4, 6, 2, 9, 6, 2, .fence, .fence, false);
        comp_mod.fillBox(p, c, clip, 4, 6, 12, 8, 6, 12, .fence, .fence, false);
        comp_mod.placeAt(p, c, clip, .fence, 0, 9, 6, 11);
        comp_mod.placeAt(p, c, clip, .fence, 0, 8, 6, 11);
        comp_mod.placeAt(p, c, clip, .fence, 0, 9, 6, 10);
        const lad = comp_mod.rotateMeta(.ladder, 3, c.mode);
        var ly: i32 = 1;
        while (ly <= 7) : (ly += 1) {
            comp_mod.placeAt(p, c, clip, .ladder, lad, 10, ly, 13);
        }
        const bx: i32 = 7;
        const bz: i32 = 7;
        comp_mod.placeAt(p, c, clip, .fence, 0, bx - 1, 9, bz);
        comp_mod.placeAt(p, c, clip, .fence, 0, bx, 9, bz);
        comp_mod.placeAt(p, c, clip, .fence, 0, bx - 1, 8, bz);
        comp_mod.placeAt(p, c, clip, .fence, 0, bx, 8, bz);
        comp_mod.placeAt(p, c, clip, .fence, 0, bx - 1, 7, bz);
        comp_mod.placeAt(p, c, clip, .fence, 0, bx, 7, bz);
        comp_mod.placeAt(p, c, clip, .fence, 0, bx - 2, 7, bz);
        comp_mod.placeAt(p, c, clip, .fence, 0, bx + 1, 7, bz);
        comp_mod.placeAt(p, c, clip, .fence, 0, bx - 1, 7, bz - 1);
        comp_mod.placeAt(p, c, clip, .fence, 0, bx - 1, 7, bz + 1);
        comp_mod.placeAt(p, c, clip, .fence, 0, bx, 7, bz - 1);
        comp_mod.placeAt(p, c, clip, .fence, 0, bx, 7, bz + 1);
        comp_mod.placeAt(p, c, clip, .torch, 0, bx - 2, 8, bz);
        comp_mod.placeAt(p, c, clip, .torch, 0, bx + 1, 8, bz);
        comp_mod.placeAt(p, c, clip, .torch, 0, bx - 1, 8, bz - 1);
        comp_mod.placeAt(p, c, clip, .torch, 0, bx - 1, 8, bz + 1);
        comp_mod.placeAt(p, c, clip, .torch, 0, bx, 8, bz - 1);
        comp_mod.placeAt(p, c, clip, .torch, 0, bx, 8, bz + 1);
    }
    loot_mod.replicateBookDraws(rand);
    const n1: i32 = 1 + (rand.nextIntBound(4) catch unreachable);
    _ = comp_mod.placeChest(p, c, clip, rand, 3, 3, 5, &library_chest_table, n1);
    if (pc.tall) {
        comp_mod.placeAt(p, c, clip, .air, 0, 12, 9, 1);
        loot_mod.replicateBookDraws(rand);
        const n2: i32 = 1 + (rand.nextIntBound(4) catch unreachable);
        _ = comp_mod.placeChest(p, c, clip, rand, 12, 8, 1, &library_chest_table, n2);
    }
    return true;
}

fn genPortal(p: Placer, pc: *Piece, rand: *JavaRandom, clip: BBox) bool {
    const c = compOf(pc);
    // aus: no liquid check, always true. Ctor draws nothing.
    fillSelector(p, c, clip, rand, 0, 0, 0, 10, 7, 15, false);
    placeDoor(p, c, clip, .grates, 4, 1, 0);
    fillSelector(p, c, clip, rand, 1, 6, 1, 1, 6, 14, false);
    fillSelector(p, c, clip, rand, 9, 6, 1, 9, 6, 14, false);
    fillSelector(p, c, clip, rand, 2, 6, 1, 8, 6, 2, false);
    fillSelector(p, c, clip, rand, 2, 6, 14, 8, 6, 14, false);
    fillSelector(p, c, clip, rand, 1, 1, 1, 2, 1, 4, false);
    fillSelector(p, c, clip, rand, 8, 1, 1, 9, 1, 4, false);
    comp_mod.fillBox(p, c, clip, 1, 1, 1, 1, 1, 3, .flowing_lava, .flowing_lava, false);
    comp_mod.fillBox(p, c, clip, 9, 1, 1, 9, 1, 3, .flowing_lava, .flowing_lava, false);
    fillSelector(p, c, clip, rand, 3, 1, 8, 7, 1, 12, false);
    comp_mod.fillBox(p, c, clip, 4, 1, 9, 6, 1, 11, .flowing_lava, .flowing_lava, false);
    var v: i32 = 3;
    while (v < 14) : (v += 2) {
        comp_mod.fillBox(p, c, clip, 0, 3, v, 0, 4, v, .iron_bars, .iron_bars, false);
        comp_mod.fillBox(p, c, clip, 10, 3, v, 10, 4, v, .iron_bars, .iron_bars, false);
    }
    v = 2;
    while (v < 9) : (v += 2) {
        comp_mod.fillBox(p, c, clip, v, 3, 15, v, 4, 15, .iron_bars, .iron_bars, false);
    }
    const st = comp_mod.rotateMeta(.stone_brick_stairs, 3, c.mode);
    fillSelector(p, c, clip, rand, 4, 1, 5, 6, 1, 7, false);
    fillSelector(p, c, clip, rand, 4, 2, 6, 6, 2, 7, false);
    fillSelector(p, c, clip, rand, 4, 3, 7, 6, 3, 7, false);
    v = 4;
    while (v <= 6) : (v += 1) {
        comp_mod.placeAt(p, c, clip, .stone_brick_stairs, st, v, 1, 4);
        comp_mod.placeAt(p, c, clip, .stone_brick_stairs, st, v, 2, 5);
        comp_mod.placeAt(p, c, clip, .stone_brick_stairs, st, v, 3, 6);
    }
    // End portal frames: base meta per facing + eye iff nextFloat() > 0.9.
    const bn: u4, const bs: u4, const bw: u4, const be: u4 = switch (pc.mode) {
        .south => .{ 0, 2, 3, 1 },
        .west => .{ 1, 3, 0, 2 },
        .north => .{ 2, 0, 3, 1 },
        .east => .{ 3, 1, 0, 2 },
    };
    var fx: i32 = 4;
    while (fx <= 6) : (fx += 1) {
        const eye_n: u4 = if (rand.nextFloat() > 0.9) 4 else 0;
        comp_mod.placeAt(p, c, clip, .end_portal_frame, bn + eye_n, fx, 3, 8);
    }
    fx = 4;
    while (fx <= 6) : (fx += 1) {
        const eye_s: u4 = if (rand.nextFloat() > 0.9) 4 else 0;
        comp_mod.placeAt(p, c, clip, .end_portal_frame, bs + eye_s, fx, 3, 12);
    }
    var fz: i32 = 9;
    while (fz <= 11) : (fz += 1) {
        const eye_w: u4 = if (rand.nextFloat() > 0.9) 4 else 0;
        comp_mod.placeAt(p, c, clip, .end_portal_frame, bw + eye_w, 3, 3, fz);
    }
    fz = 9;
    while (fz <= 11) : (fz += 1) {
        const eye_e: u4 = if (rand.nextFloat() > 0.9) 4 else 0;
        comp_mod.placeAt(p, c, clip, .end_portal_frame, be + eye_e, 7, 3, fz);
    }
    if (!pc.mob_done) {
        const wx = c.xWithOffset(5, 6);
        const wy = c.yWithOffset(3);
        const wz = c.zWithOffset(5, 6);
        if (clip.contains(wx, wy, wz)) {
            pc.mob_done = true;
            comp_mod.placeSpawner(p, c, clip, 5, 3, 6);
        }
    }
    return true;
}

fn genPiece(p: Placer, b: *Builder, idx: u32, rand: *JavaRandom, clip: BBox) bool {
    const pc = &b.pieces[idx];
    return switch (pc.kind) {
        .spiral => genSpiral(p, pc, rand, clip),
        .stairs => genStairs(p, pc, rand, clip),
        .prison => genPrison(p, pc, rand, clip),
        .left_turn => genLeftTurn(p, pc, rand, clip),
        .room_crossing => genRoomCrossing(p, pc, rand, clip),
        .straight_stair => genStraightStair(p, pc, rand, clip),
        .crossing => genCrossing(p, pc, rand, clip),
        .chest_corridor => genChestCorridor(p, pc, rand, clip),
        .library => genLibrary(p, pc, rand, clip),
        .portal => genPortal(p, pc, rand, clip),
        .corridor => genCorridor(p, pc, rand, clip),
    };
}

// ---------------------------------------------------------------------------
// Start builder (`auh` ctor + `avm` union + markAvailableHeight).
// ---------------------------------------------------------------------------

/// Build one start (weights reset, start stairs, drain pending, union,
/// `markAvailableHeight(world,rand,10)`). Mirrors `auh.<init>`.
pub fn build(b: *Builder, sx: i32, sz: i32, rand: *JavaRandom) void {
    b.reset();
    const mode = Facing.fromInt(@truncate(@as(u2, @intCast(rand.nextIntBound(4) catch unreachable))));
    const bx = sx * 16 + 2;
    const bz = sz * 16 + 2;
    const si = b.insert(.{
        .kind = .spiral,
        .mode = mode,
        .box = BBox.init(bx, 64, bz, bx + 4, 74, bz + 4),
        .depth = 0,
        .door = .opening,
        .source = true,
    }) orelse return;
    b.start = si;
    buildComponent(b, si, rand);
    while (b.m > 0) {
        const at: usize = @intCast(rand.nextIntBound(@intCast(b.m)) catch unreachable);
        const idx = b.pending[at];
        var k = at + 1;
        while (k < b.m) : (k += 1) b.pending[k - 1] = b.pending[k];
        b.m -= 1;
        buildComponent(b, idx, rand);
    }
    var u = BBox.empty();
    var i: usize = 0;
    while (i < b.n) : (i += 1) u = u.expandToInclude(b.pieces[i].box);
    b.union_box = u;
    // markAvailableHeight(..., 10): shift so top lands at 53 + draw.
    const v: i32 = mapgen_mod.availHeightTop(u.max_y - u.min_y + 1 + 1, rand);
    const sh: i32 = v - u.max_y;
    i = 0;
    while (i < b.n) : (i += 1) b.pieces[i].box = b.pieces[i].box.offset(0, sh, 0);
    b.union_box = u.offset(0, sh, 0);
}

/// Eye-of-ender target (`auz.a`): portal room max corner, else start max
/// corner (`avk.a`).
pub fn eyeTarget(b: *const Builder) struct { x: i32, y: i32, z: i32 } {
    if (b.portal_idx) |pi| {
        const bx = b.pieces[pi].box;
        return .{ .x = bx.max_x, .y = bx.max_y, .z = bx.max_z };
    }
    const sx = b.pieces[b.start].box;
    return .{ .x = sx.max_x, .y = sx.max_y, .z = sx.max_z };
}

/// Place a built start into the populate chunk (`avm.a`): per piece, if the
/// piece box touches clip, run it; drop failures (they wrote nothing —
/// every `false` path precedes all writes).
pub fn place(b: *Builder, p: Placer, rand: *JavaRandom, clip: BBox) void {
    var i: usize = 0;
    while (i < b.n) {
        if (b.pieces[i].box.intersects(clip)) {
            if (!genPiece(p, b, @intCast(i), rand, clip)) {
                var k = i + 1;
                while (k < b.n) : (k += 1) b.pieces[k - 1] = b.pieces[k];
                b.n -= 1;
                continue;
            }
        }
        i += 1;
    }
}

/// Full stronghold step for one start chunk (`aug.b` retry + `ave.a`
/// per-start placement): rebuild with the same rand stream until a portal
/// room exists, then place what touches clip. Returns true when the start
/// union touches clip.
pub fn generate(p: Placer, sx: i32, sz: i32, build_rand: *JavaRandom, place_rand: *JavaRandom, clip: BBox) bool {
    var b: Builder = undefined;
    while (true) {
        build(&b, sx, sz, build_rand);
        if (b.n != 0 and b.portal) break;
    }
    if (!b.union_box.intersects(clip)) return false;
    place(&b, p, place_rand, clip);
    return true;
}

test "stronghold build is deterministic and yields a portal" {
    var r1 = JavaRandom.init(12345);
    var b1: Builder = undefined;
    build(&b1, 0, 0, &r1);
    var r2 = JavaRandom.init(12345);
    var b2: Builder = undefined;
    build(&b2, 0, 0, &r2);
    try std.testing.expect(b1.n == b2.n and b1.n > 0);
    try std.testing.expect(b1.portal and b2.portal);
    try std.testing.expectEqual(b1.union_box, b2.union_box);
}
