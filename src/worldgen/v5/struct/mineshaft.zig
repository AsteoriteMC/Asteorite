//! Abandoned mineshafts (vanilla `asw` MapGen + `atc` start + `asy`/`asz`/
//! `ata`/`atb` pieces, jar-verified verbatim, including RNG order).
//!
//! Detection gate is `mapgen.mineshaftCanSpawn` (`asw.a`: nextDouble < 0.004
//! then nextInt(80) < max(|sx|,|sz|)). The start builds with the position
//! rand (room 3x nextInt(6), then recursive layout); block placement runs
//! with the populate rand, pieces in insertion order (`ave`/`avm`).
//! `generate` therefore takes both rands.

const ids = @import("../../../ids.zig");
const bbox_mod = @import("bbox.zig");
const comp_mod = @import("comp.zig");
const loot_mod = @import("loot.zig");
const mapgen_mod = @import("mapgen.zig");
const placer_mod = @import("placer.zig");
const mc5_blocks = @import("../../../game/mc5/blocks.zig");
const java_random = @import("../../rng/java_random.zig");

pub const BBox = bbox_mod.BBox;
pub const Component = comp_mod.Component;
pub const Facing = bbox_mod.Facing;
pub const Placer = placer_mod.Placer;
pub const JavaRandom = java_random.JavaRandom;

/// canSpawn for a start-chunk (`asw.a`).
pub fn canSpawn(rand: *JavaRandom, sx: i32, sz: i32) bool {
    return mapgen_mod.mineshaftCanSpawn(rand, sx, sz);
}

pub const PieceKind = enum { corridor, crossing, room, stairs };

pub const Piece = struct {
    kind: PieceKind,
    comp: Component,
    depth: i32 = 0,
    // Corridor (`asy`).
    sections: i32 = 0,
    rails: bool = false,
    spider: bool = false,
    spawner_done: bool = false,
    // Crossing (`asz`).
    dir: Facing = .south,
    two_level: bool = false,
};

/// Corridor chest-minecart table: base 13 + book append
/// (`qx.a(asx.b(), [book(rand)])`; book weight 1, limit 1, 1-1).
pub const mineshaft_chest = loot_mod.mineshaft_corridor ++ [_]loot_mod.Entry{
    .{ .limit = 1, .weight = 1, .min = 1, .max = 1 },
};

/// Defensive build cap (vanilla uses an unbounded list; real mineshafts
/// stay in the low hundreds).
pub const MAX_PIECES: usize = 2048;
/// Room side loops add at most 4 entrances per side (advance >= 4, size <= 13).
pub const MAX_ENTRANCES: usize = 16;

const Build = struct {
    pieces: []Piece,
    n: usize = 0,
    entrances: []BBox,
    ne: usize = 0,

    fn add(self: *Build, p: Piece) ?usize {
        if (self.n >= self.pieces.len) return null;
        self.pieces[self.n] = p;
        self.n += 1;
        return self.n - 1;
    }

    fn addEntrance(self: *Build, b: BBox) void {
        if (self.ne >= self.entrances.len) return;
        self.entrances[self.ne] = b;
        self.ne += 1;
    }

    fn hits(self: *Build, box: BBox) bool {
        for (self.pieces[0..self.n]) |q| {
            if (q.comp.box.intersects(box)) return true;
        }
        return false;
    }
};

/// Place one mineshaft start into the populate chunk (`ave.a` per-start
/// step): rebuilds the layout from the position rand, shifts it down, then
/// runs every intersecting piece with the populate rand. Returns true when
/// the (shifted) start union touches clip.
pub fn generate(
    p: Placer,
    sx: i32,
    sz: i32,
    build_rand: *JavaRandom,
    place_rand: *JavaRandom,
    clip: BBox,
) bool {
    var pbuf: [MAX_PIECES]Piece = undefined;
    var ebuf: [MAX_ENTRANCES]BBox = undefined;
    var b = Build{ .pieces = &pbuf, .entrances = &ebuf };
    const start_box = buildStart(sx, sz, build_rand, &b);
    if (!start_box.intersects(clip)) return false;
    for (b.pieces[0..b.n]) |*piece| {
        if (!piece.comp.box.intersects(clip)) continue;
        switch (piece.kind) {
            .corridor => placeCorridor(p, piece, clip, place_rand),
            .crossing => placeCrossing(p, piece.*, clip),
            .room => placeRoom(p, piece.*, clip, b.entrances[0..b.ne]),
            .stairs => placeStairs(p, piece.*, clip),
        }
    }
    return true;
}

/// Start builder (`atc.<init>` + `avm.a(ahb, Random, 10)` shift).
/// Consumes ONLY build_rand.
fn buildStart(sx: i32, sz: i32, rand: *JavaRandom, b: *Build) BBox {
    const rx = (rand.nextIntBound(6) catch unreachable);
    const ry = (rand.nextIntBound(6) catch unreachable);
    const rz = (rand.nextIntBound(6) catch unreachable);
    const x = sx * 16 + 2;
    const z = sz * 16 + 2;
    const room_box = BBox.init(x, 50, z, x + 7 + rx, 54 + ry, z + 7 + rz);
    _ = b.add(.{
        .kind = .room,
        .comp = .{ .mode = .south, .box = room_box },
        .depth = 0,
    }) orelse return room_box;
    buildRoomChildren(b, room_box, 0, rand);
    // Union (`avm.c`).
    var u = BBox.empty();
    for (b.pieces[0..b.n]) |q| u = u.expandToInclude(q.comp.box);
    // Height shift (`avm.a(ahb, Random, 10)`): top lands in [h+1, 53].
    const top: i32 = mapgen_mod.availHeightTop(u.sizeY() + 1, rand);
    const dy = top - u.max_y;
    for (b.pieces[0..b.n]) |*q| q.comp.box = q.comp.box.offset(0, dy, 0);
    // NOTE: room entrances are stored pre-shift and never shifted (vanilla
    // quirk: `avm.a` shifts only piece boxes).
    return u.offset(0, dy, 0);
}

// ---------------------------------------------------------------------------
// Layout picker/linker (`asx`).
// ---------------------------------------------------------------------------

/// Piece picker (`asx` private pick): nextInt(100) >= 80 crossing, >= 70
/// stairs, else corridor. Finder failure yields null (no fallback).
fn pick(b: *Build, rand: *JavaRandom, x: i32, y: i32, z: i32, mode: Facing, depth: i32) ?Piece {
    const r = (rand.nextIntBound(100) catch unreachable);
    if (r >= 80) {
        const box = findCrossingBox(b, rand, x, y, z, mode) orelse return null;
        return Piece{
            .kind = .crossing,
            .comp = .{ .mode = .south, .box = box },
            .depth = depth,
            .dir = mode,
            .two_level = box.sizeY() > 3,
        };
    } else if (r >= 70) {
        const box = findStairsBox(b, x, y, z, mode) orelse return null;
        return Piece{
            .kind = .stairs,
            .comp = .{ .mode = mode, .box = box },
            .depth = depth,
        };
    } else {
        const box = findCorridorBox(b, rand, x, y, z, mode) orelse return null;
        const sections: i32 = if (mode == .west or mode == .east)
            @divTrunc(box.sizeX(), 5)
        else
            @divTrunc(box.sizeZ(), 5);
        return Piece{
            .kind = .corridor,
            .comp = .{ .mode = mode, .box = box },
            .depth = depth,
            .sections = sections,
            .rails = (rand.nextIntBound(3) catch unreachable) == 0,
            .spider = false,
        };
    }
}

/// Child linker (`asx` package + private): depth/range gates, then pick,
/// append, and recurse into the child's own exits.
fn link(b: *Build, pmin_x: i32, pmin_z: i32, rand: *JavaRandom, x: i32, y: i32, z: i32, mode: Facing, depth: i32) ?usize {
    if (depth > 8) return null;
    if (@abs(x - pmin_x) > 80 or @abs(z - pmin_z) > 80) return null;
    var child = pick(b, rand, x, y, z, mode, depth + 1) orelse return null;
    // Corridor spider flag (`asy` ctor order: after the box, nextInt(3)
    // for rails was already drawn in pick; spider draws here).
    if (child.kind == .corridor and !child.rails) {
        child.spider = (rand.nextIntBound(23) catch unreachable) == 0;
    }
    const idx = b.add(child) orelse return null;
    buildChildren(b, idx, rand);
    return idx;
}

fn buildChildren(b: *Build, idx: usize, rand: *JavaRandom) void {
    const piece = b.pieces[idx];
    switch (piece.kind) {
        .corridor => buildCorridorChildren(b, idx, rand),
        .crossing => buildCrossingChildren(b, idx, rand),
        .room => buildRoomChildren(b, piece.comp.box, piece.depth, rand),
        .stairs => buildStairsChildren(b, idx, rand),
    }
}

// ---------------------------------------------------------------------------
// Corridor (`asy`, oriented, local coords).
// ---------------------------------------------------------------------------

fn findCorridorBox(b: *Build, rand: *JavaRandom, x: i32, y: i32, z: i32, mode: Facing) ?BBox {
    var segs = (rand.nextIntBound(3) catch unreachable) + 2;
    var box = BBox.init(x, y, z, x, y + 2, z);
    while (segs > 0) : (segs -= 1) {
        const len = segs * 5;
        box = switch (mode) {
            .south => BBox.init(x, y, z, x + 2, y + 2, z + len - 1),
            .west => BBox.init(x - len + 1, y, z, x, y + 2, z + 2),
            .north => BBox.init(x, y, z - len + 1, x + 2, y + 2, z),
            .east => BBox.init(x, y, z, x + len - 1, y + 2, z + 2),
        };
        if (!b.hits(box)) break;
    }
    return if (segs > 0) box else null;
}

fn buildCorridorChildren(b: *Build, idx: usize, rand: *JavaRandom) void {
    const c = b.pieces[idx].comp;
    const depth = b.pieces[idx].depth;
    const exit = (rand.nextIntBound(4) catch unreachable);
    const ey = c.box.min_y - 1 + (rand.nextIntBound(3) catch unreachable);
    switch (c.mode) {
        .south => {
            if (exit <= 1) {
                _ = link(b, c.box.min_x, c.box.min_z, rand, c.box.min_x, ey, c.box.max_z + 1, .south, depth);
            } else if (exit == 2) {
                _ = link(b, c.box.min_x, c.box.min_z, rand, c.box.min_x - 1, ey, c.box.max_z - 3, .west, depth);
            } else {
                _ = link(b, c.box.min_x, c.box.min_z, rand, c.box.max_x + 1, ey, c.box.max_z - 3, .east, depth);
            }
        },
        .west => {
            if (exit <= 1) {
                _ = link(b, c.box.min_x, c.box.min_z, rand, c.box.min_x - 1, ey, c.box.min_z, .west, depth);
            } else if (exit == 2) {
                _ = link(b, c.box.min_x, c.box.min_z, rand, c.box.min_x, ey, c.box.min_z - 1, .north, depth);
            } else {
                _ = link(b, c.box.min_x, c.box.min_z, rand, c.box.min_x, ey, c.box.max_z + 1, .south, depth);
            }
        },
        .north => {
            if (exit <= 1) {
                _ = link(b, c.box.min_x, c.box.min_z, rand, c.box.min_x, ey, c.box.min_z - 1, .north, depth);
            } else if (exit == 2) {
                _ = link(b, c.box.min_x, c.box.min_z, rand, c.box.min_x - 1, ey, c.box.min_z, .west, depth);
            } else {
                _ = link(b, c.box.min_x, c.box.min_z, rand, c.box.max_x + 1, ey, c.box.min_z, .east, depth);
            }
        },
        .east => {
            if (exit <= 1) {
                _ = link(b, c.box.min_x, c.box.min_z, rand, c.box.max_x + 1, ey, c.box.min_z, .east, depth);
            } else if (exit == 2) {
                _ = link(b, c.box.min_x, c.box.min_z, rand, c.box.max_x - 3, ey, c.box.min_z - 1, .north, depth);
            } else {
                _ = link(b, c.box.min_x, c.box.min_z, rand, c.box.max_x - 3, ey, c.box.max_z + 1, .south, depth);
            }
        },
    }
    if (depth < 8) {
        if (c.mode == .south or c.mode == .north) {
            var s: i32 = c.box.min_z + 3;
            while (s + 3 <= c.box.max_z) : (s += 5) {
                const r = (rand.nextIntBound(5) catch unreachable);
                if (r == 0) {
                    _ = link(b, c.box.min_x, c.box.min_z, rand, s, c.box.min_y, c.box.min_z - 1, .north, depth + 1);
                } else if (r == 1) {
                    _ = link(b, c.box.min_x, c.box.min_z, rand, s, c.box.min_y, c.box.max_z + 1, .south, depth + 1);
                }
            }
        } else {
            var s: i32 = c.box.min_x + 3;
            while (s + 3 <= c.box.max_x) : (s += 5) {
                const r = (rand.nextIntBound(5) catch unreachable);
                if (r == 0) {
                    _ = link(b, c.box.min_x, c.box.min_z, rand, c.box.min_x - 1, c.box.min_y, s, .west, depth + 1);
                } else if (r == 1) {
                    _ = link(b, c.box.min_x, c.box.min_z, rand, c.box.max_x + 1, c.box.min_y, s, .east, depth + 1);
                }
            }
        }
    }
}

/// Rail + book chest for one corridor slot (`asy` inline; consumes populate
/// rand ONLY when the slot roll hits: book draws, count roll, then the
/// chest content draws).
fn corridorChest(p: Placer, c: Component, clip: BBox, rand: *JavaRandom, lx: i32, ly: i32, lz: i32) void {
    loot_mod.replicateBookDraws(rand);
    const n = 3 + (rand.nextIntBound(4) catch unreachable);
    const wx = c.xWithOffset(lx, lz);
    const wy = c.yWithOffset(ly);
    const wz = c.zWithOffset(lx, lz);
    if (!clip.contains(wx, wy, wz)) return;
    if (p.get(wx, wy, wz).id != .air) return;
    const base: u4 = if (rand.nextBoolean()) 1 else 0;
    comp_mod.placeAt(p, c, clip, .rail, comp_mod.rotateMeta(.rail, base, c.mode), lx, ly, lz);
    loot_mod.replicateChestDraws(rand, &mineshaft_chest, n, loot_mod.chest_slots);
}

fn placeCorridor(p: Placer, piece: *Piece, clip: BBox, rand: *JavaRandom) void {
    const c = piece.comp;
    if (comp_mod.liquidInBox(p, c, c.box, clip)) return;
    const l = piece.sections * 5 - 1;
    comp_mod.fillBox(p, c, clip, 0, 0, 0, 2, 1, l, .air, .air, false);
    comp_mod.fillBoxRandom(p, c, clip, rand, 0.8, 0, 2, 0, 2, 2, l, .air, .air, false);
    if (piece.spider) {
        comp_mod.fillBoxRandom(p, c, clip, rand, 0.6, 0, 0, 0, 2, 1, l, .web, .air, false);
    }
    var s: i32 = 0;
    while (s < piece.sections) : (s += 1) {
        const v = 2 + s * 5;
        comp_mod.placeAt(p, c, clip, .fence, 0, 0, 0, v);
        comp_mod.placeAt(p, c, clip, .fence, 0, 2, 0, v);
        if ((rand.nextIntBound(4) catch unreachable) == 0) {
            comp_mod.placeAt(p, c, clip, .planks, 0, 0, 2, v);
            comp_mod.placeAt(p, c, clip, .planks, 0, 2, 2, v);
        } else {
            comp_mod.fillBox(p, c, clip, 0, 2, v, 2, 2, v, .planks, .air, false);
        }
        comp_mod.placeRandom(p, c, clip, rand, 0.1, 0, 2, v - 1, .web, 0);
        comp_mod.placeRandom(p, c, clip, rand, 0.1, 2, 2, v - 1, .web, 0);
        comp_mod.placeRandom(p, c, clip, rand, 0.1, 0, 2, v + 1, .web, 0);
        comp_mod.placeRandom(p, c, clip, rand, 0.1, 2, 2, v + 1, .web, 0);
        comp_mod.placeRandom(p, c, clip, rand, 0.05, 0, 2, v - 2, .web, 0);
        comp_mod.placeRandom(p, c, clip, rand, 0.05, 2, 2, v - 2, .web, 0);
        comp_mod.placeRandom(p, c, clip, rand, 0.05, 0, 2, v + 2, .web, 0);
        comp_mod.placeRandom(p, c, clip, rand, 0.05, 2, 2, v + 2, .web, 0);
        comp_mod.placeRandom(p, c, clip, rand, 0.05, 1, 2, v - 1, .torch, 0);
        comp_mod.placeRandom(p, c, clip, rand, 0.05, 1, 2, v + 1, .torch, 0);
        if ((rand.nextIntBound(100) catch unreachable) == 0) {
            corridorChest(p, c, clip, rand, 2, 0, v - 1);
        }
        if ((rand.nextIntBound(100) catch unreachable) == 0) {
            corridorChest(p, c, clip, rand, 0, 0, v + 1);
        }
        if (piece.spider and !piece.spawner_done) {
            const zc = v - 1 + (rand.nextIntBound(3) catch unreachable);
            const wx = c.xWithOffset(1, zc);
            const wy = c.yWithOffset(0);
            const wz = c.zWithOffset(1, zc);
            if (clip.contains(wx, wy, wz)) {
                piece.spawner_done = true;
                comp_mod.placeSpawner(p, c, clip, 1, 0, zc);
            }
        }
    }
    var fx: i32 = 0;
    while (fx <= 2) : (fx += 1) {
        var fz: i32 = 0;
        while (fz <= l) : (fz += 1) {
            if (comp_mod.getAt(p, c, clip, fx, -1, fz).id == .air) {
                comp_mod.placeAt(p, c, clip, .planks, 0, fx, -1, fz);
            }
        }
    }
    if (piece.rails) {
        const rail_meta = comp_mod.rotateMeta(.rail, 0, c.mode);
        var rz: i32 = 0;
        while (rz <= l) : (rz += 1) {
            const below = comp_mod.getAt(p, c, clip, 1, -1, rz);
            if (below.id != .air and mc5_blocks.table.get(below.id).normal_cube) {
                if (rand.nextFloat() < 0.7) {
                    comp_mod.placeAt(p, c, clip, .rail, rail_meta, 1, 0, rz);
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Crossing (`asz`, unoriented: world coords via south component + min shift).
// ---------------------------------------------------------------------------

fn findCrossingBox(b: *Build, rand: *JavaRandom, x: i32, y: i32, z: i32, mode: Facing) ?BBox {
    var box = BBox.init(x, y, z, x, y + 2, z);
    if ((rand.nextIntBound(4) catch unreachable) == 0) box.max_y += 4;
    box = switch (mode) {
        .south => BBox.init(x - 1, box.min_y, z, x + 3, box.max_y, z + 4),
        .west => BBox.init(x - 4, box.min_y, z - 1, x, box.max_y, z + 3),
        .north => BBox.init(x - 1, box.min_y, z - 4, x + 3, box.max_y, z),
        .east => BBox.init(x, box.min_y, z - 1, x + 4, box.max_y, z + 3),
    };
    return if (b.hits(box)) null else box;
}

fn buildCrossingChildren(b: *Build, idx: usize, rand: *JavaRandom) void {
    const piece = b.pieces[idx];
    const w = piece.comp.box;
    const depth = piece.depth;
    switch (piece.dir) {
        .south => {
            _ = link(b, w.min_x, w.min_z, rand, w.min_x + 1, w.min_y, w.max_z + 1, .south, depth);
            _ = link(b, w.min_x, w.min_z, rand, w.min_x - 1, w.min_y, w.min_z + 1, .west, depth);
            _ = link(b, w.min_x, w.min_z, rand, w.max_x + 1, w.min_y, w.min_z + 1, .east, depth);
        },
        .west => {
            _ = link(b, w.min_x, w.min_z, rand, w.min_x + 1, w.min_y, w.min_z - 1, .north, depth);
            _ = link(b, w.min_x, w.min_z, rand, w.min_x + 1, w.min_y, w.max_z + 1, .south, depth);
            _ = link(b, w.min_x, w.min_z, rand, w.min_x - 1, w.min_y, w.min_z + 1, .west, depth);
        },
        .north => {
            _ = link(b, w.min_x, w.min_z, rand, w.min_x + 1, w.min_y, w.min_z - 1, .north, depth);
            _ = link(b, w.min_x, w.min_z, rand, w.min_x - 1, w.min_y, w.min_z + 1, .west, depth);
            _ = link(b, w.min_x, w.min_z, rand, w.max_x + 1, w.min_y, w.min_z + 1, .east, depth);
        },
        .east => {
            _ = link(b, w.min_x, w.min_z, rand, w.min_x + 1, w.min_y, w.min_z - 1, .north, depth);
            _ = link(b, w.min_x, w.min_z, rand, w.min_x + 1, w.min_y, w.max_z + 1, .south, depth);
            _ = link(b, w.min_x, w.min_z, rand, w.max_x + 1, w.min_y, w.min_z + 1, .east, depth);
        },
    }
    if (piece.two_level) {
        if (rand.nextBoolean()) {
            _ = link(b, w.min_x, w.min_z, rand, w.min_x + 1, w.min_y + 4, w.min_z - 1, .north, depth);
        }
        if (rand.nextBoolean()) {
            _ = link(b, w.min_x, w.min_z, rand, w.min_x - 1, w.min_y + 4, w.min_z + 1, .west, depth);
        }
        if (rand.nextBoolean()) {
            _ = link(b, w.min_x, w.min_z, rand, w.max_x + 1, w.min_y + 4, w.min_z + 1, .east, depth);
        }
        if (rand.nextBoolean()) {
            _ = link(b, w.min_x, w.min_z, rand, w.min_x + 1, w.min_y + 4, w.max_z + 1, .south, depth);
        }
    }
}

fn placeCrossing(p: Placer, piece: Piece, clip: BBox) void {
    const c = piece.comp;
    if (comp_mod.liquidInBox(p, c, c.box, clip)) return;
    const sx = c.box.sizeX();
    const sz = c.box.sizeZ();
    const h = c.box.sizeY() - 1;
    if (piece.two_level) {
        comp_mod.fillBox(p, c, clip, 1, 0, 0, sx - 2, 2, sz - 1, .air, .air, false);
        comp_mod.fillBox(p, c, clip, 0, 0, 1, sx - 1, 2, sz - 2, .air, .air, false);
        comp_mod.fillBox(p, c, clip, 1, h - 2, 0, sx - 2, h, sz - 1, .air, .air, false);
        comp_mod.fillBox(p, c, clip, 0, h - 2, 1, sx - 1, h, sz - 2, .air, .air, false);
        comp_mod.fillBox(p, c, clip, 1, 3, 1, sx - 2, 3, sz - 2, .air, .air, false);
    } else {
        comp_mod.fillBox(p, c, clip, 1, 0, 0, sx - 2, h, sz - 1, .air, .air, false);
        comp_mod.fillBox(p, c, clip, 0, 0, 1, sx - 1, h, sz - 2, .air, .air, false);
    }
    comp_mod.fillBox(p, c, clip, 1, 0, 1, 1, h, 1, .planks, .air, false);
    comp_mod.fillBox(p, c, clip, 1, 0, sz - 2, 1, h, sz - 2, .planks, .air, false);
    comp_mod.fillBox(p, c, clip, sx - 2, 0, 1, sx - 2, h, 1, .planks, .air, false);
    comp_mod.fillBox(p, c, clip, sx - 2, 0, sz - 2, sx - 2, h, sz - 2, .planks, .air, false);
    var fx: i32 = 0;
    while (fx < sx) : (fx += 1) {
        var fz: i32 = 0;
        while (fz < sz) : (fz += 1) {
            if (comp_mod.getAt(p, c, clip, fx, -1, fz).id == .air) {
                comp_mod.placeAt(p, c, clip, .planks, 0, fx, -1, fz);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Room (`ata`, unoriented).
// ---------------------------------------------------------------------------

fn buildRoomChildren(b: *Build, room: BBox, depth: i32, rand: *JavaRandom) void {
    var gap = room.sizeY() - 3 - 1;
    if (gap <= 0) gap = 1;
    // North side (facing north into minZ-1).
    var s: i32 = 0;
    while (s < room.sizeX()) {
        s += (rand.nextIntBound(room.sizeX()) catch unreachable);
        if (s + 3 > room.sizeX()) break;
        const cy = room.min_y + (rand.nextIntBound(gap) catch unreachable) + 1;
        const ci = link(b, room.min_x, room.min_z, rand, room.min_x + s, cy, room.min_z - 1, .north, depth);
        if (ci) |idx| {
            const cb = b.pieces[idx].comp.box;
            b.addEntrance(BBox.init(cb.min_x, cb.min_y, room.min_z, cb.max_x, cb.max_y, room.min_z + 1));
        }
        s += 4;
    }
    // South side.
    s = 0;
    while (s < room.sizeX()) {
        s += (rand.nextIntBound(room.sizeX()) catch unreachable);
        if (s + 3 > room.sizeX()) break;
        const cy = room.min_y + (rand.nextIntBound(gap) catch unreachable) + 1;
        const ci = link(b, room.min_x, room.min_z, rand, room.min_x + s, cy, room.max_z + 1, .south, depth);
        if (ci) |idx| {
            const cb = b.pieces[idx].comp.box;
            b.addEntrance(BBox.init(cb.min_x, cb.min_y, room.max_z - 1, cb.max_x, cb.max_y, room.max_z));
        }
        s += 4;
    }
    // West side.
    s = 0;
    while (s < room.sizeZ()) {
        s += (rand.nextIntBound(room.sizeZ()) catch unreachable);
        if (s + 3 > room.sizeZ()) break;
        const cy = room.min_y + (rand.nextIntBound(gap) catch unreachable) + 1;
        const ci = link(b, room.min_x, room.min_z, rand, room.min_x - 1, cy, room.min_z + s, .west, depth);
        if (ci) |idx| {
            const cb = b.pieces[idx].comp.box;
            b.addEntrance(BBox.init(room.min_x, cb.min_y, cb.min_z, room.min_x + 1, cb.max_y, cb.max_z));
        }
        s += 4;
    }
    // East side.
    s = 0;
    while (s < room.sizeZ()) {
        s += (rand.nextIntBound(room.sizeZ()) catch unreachable);
        if (s + 3 > room.sizeZ()) break;
        const cy = room.min_y + (rand.nextIntBound(gap) catch unreachable) + 1;
        const ci = link(b, room.min_x, room.min_z, rand, room.max_x + 1, cy, room.min_z + s, .east, depth);
        if (ci) |idx| {
            const cb = b.pieces[idx].comp.box;
            b.addEntrance(BBox.init(room.max_x - 1, cb.min_y, cb.min_z, room.max_x, cb.max_y, cb.max_z));
        }
        s += 4;
    }
}

fn placeRoom(p: Placer, piece: Piece, clip: BBox, entrances: []const BBox) void {
    const c = piece.comp;
    if (comp_mod.liquidInBox(p, c, c.box, clip)) return;
    const w = c.box;
    // Dirt floor shell / air interior, only where current is non-air.
    {
        var fx = w.min_x;
        while (fx <= w.max_x) : (fx += 1) {
            var fz = w.min_z;
            while (fz <= w.max_z) : (fz += 1) {
                if (!clip.contains(fx, w.min_y, fz)) continue;
                if (p.get(fx, w.min_y, fz).id == .air) continue;
                const edge = fx == w.min_x or fx == w.max_x or fz == w.min_z or fz == w.max_z;
                p.set(fx, w.min_y, fz, if (edge) .dirt else .air, 0);
            }
        }
    }
    const sx = w.sizeX();
    const sz = w.sizeZ();
    const h = w.sizeY() - 1;
    const clear_top = @min(3, h);
    comp_mod.fillBox(p, c, clip, 0, 1, 0, sx - 1, clear_top, sz - 1, .air, .air, false);
    // Entrance carves use PRE-SHIFT world boxes (vanilla quirk).
    for (entrances) |e| {
        const lx0 = e.min_x - w.min_x;
        const ly0 = e.max_y - 2 - w.min_y;
        const lz0 = e.min_z - w.min_z;
        const lx1 = e.max_x - w.min_x;
        const ly1 = e.max_y - w.min_y;
        const lz1 = e.max_z - w.min_z;
        comp_mod.fillBox(p, c, clip, lx0, ly0, lz0, lx1, ly1, lz1, .air, .air, false);
    }
    comp_mod.fillEllipsoid(p, c, clip, 0, 4, 0, sx - 1, h, sz - 1, .air, false);
}

// ---------------------------------------------------------------------------
// Stairs (`atb`, oriented, local coords).
// ---------------------------------------------------------------------------

fn findStairsBox(b: *Build, x: i32, y: i32, z: i32, mode: Facing) ?BBox {
    const box = switch (mode) {
        .south => BBox.init(x, y - 5, z, x + 2, y + 2, z + 8),
        .west => BBox.init(x - 8, y - 5, z, x, y + 2, z + 2),
        .north => BBox.init(x, y - 5, z - 8, x + 2, y + 2, z),
        .east => BBox.init(x, y - 5, z, x + 8, y + 2, z + 2),
    };
    return if (b.hits(box)) null else box;
}

fn buildStairsChildren(b: *Build, idx: usize, rand: *JavaRandom) void {
    const piece = b.pieces[idx];
    const w = piece.comp.box;
    const depth = piece.depth;
    switch (piece.comp.mode) {
        .south => _ = link(b, w.min_x, w.min_z, rand, w.min_x, w.min_y, w.max_z + 1, .south, depth),
        .west => _ = link(b, w.min_x, w.min_z, rand, w.min_x - 1, w.min_y, w.min_z, .west, depth),
        .north => _ = link(b, w.min_x, w.min_z, rand, w.min_x, w.min_y, w.min_z - 1, .north, depth),
        .east => _ = link(b, w.min_x, w.min_z, rand, w.max_x + 1, w.min_y, w.min_z, .east, depth),
    }
}

fn placeStairs(p: Placer, piece: Piece, clip: BBox) void {
    const c = piece.comp;
    if (comp_mod.liquidInBox(p, c, c.box, clip)) return;
    comp_mod.fillBox(p, c, clip, 0, 5, 0, 2, 7, 1, .air, .air, false);
    comp_mod.fillBox(p, c, clip, 0, 0, 7, 2, 2, 8, .air, .air, false);
    var v: i32 = 0;
    while (v < 5) : (v += 1) {
        const y0 = 5 - v - (if (v < 4) @as(i32, 1) else 0);
        comp_mod.fillBox(p, c, clip, 0, y0, 2 + v, 2, 7 - v, 2 + v, .air, .air, false);
    }
}
