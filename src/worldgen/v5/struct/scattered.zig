//! Scattered features (vanilla `atx` MapGen + `aty` start + `aub`/`auc`/`auf`
//! pieces, jar-verified verbatim, including RNG order).
//!
//! Spacing 32, separation 8, salt 14357617 (`atx`). Kind from the center
//! voronoi biome: jungle (21/22) -> jungle pyramid, swamp (6) -> witch
//! hut, else desert pyramid. Desert pyramids skip ground leveling (fixed
//! y=64 box); jungle (`auc`) and witch (`auf`) level to the averaged top.

const ids = @import("../../../ids.zig");
const bbox_mod = @import("bbox.zig");
const comp_mod = @import("comp.zig");
const loot_mod = @import("loot.zig");
const mapgen_mod = @import("mapgen.zig");
const placer_mod = @import("placer.zig");
const java_random = @import("../../rng/java_random.zig");
const std = @import("std");

pub const BBox = bbox_mod.BBox;
pub const Component = comp_mod.Component;
pub const Placer = placer_mod.Placer;
pub const JavaRandom = java_random.JavaRandom;

pub const Kind = mapgen_mod.ScatteredKind;

/// canSpawn for a start-chunk (`atx.a`).
pub fn canSpawn(bio: mapgen_mod.BioCtx, alloc: std.mem.Allocator, world_seed: i64, sx: i32, sz: i32) bool {
    return mapgen_mod.scatteredCanSpawn(bio, alloc, world_seed, sx, sz);
}

/// Facing draw shared by all three pieces (`aue` constructor).
pub fn drawFacing(rand: *JavaRandom) u2 {
    return @truncate(@as(u2, @intCast(rand.nextIntBound(4) catch unreachable)));
}

/// Place one scattered start into the populate chunk (`ave.a` per-start
/// step): single piece with facing from the position rand, run when its
/// box touches clip. Returns true when anything could generate.
pub fn generate(
    p: Placer,
    bio_center: i32,
    sx: i32,
    sz: i32,
    build_rand: *JavaRandom,
    place_rand: *JavaRandom,
    clip: BBox,
) bool {
    const kind = mapgen_mod.scatteredKindFor(bio_center) orelse return false;
    const mode = comp_mod.Facing.fromInt(drawFacing(build_rand));
    switch (kind) {
        .desert => {
            const c = Component{ .mode = mode, .box = bbox_mod.sizedBox(sx * 16, 64, sz * 16, 21, 15, 21, mode) };
            if (!c.box.intersects(clip)) return false;
            desertPyramid(p, c, clip, place_rand);
            return true;
        },
        .jungle => {
            const c = Component{ .mode = mode, .box = bbox_mod.sizedBox(sx * 16, 64, sz * 16, 12, 10, 15, mode) };
            if (!c.box.intersects(clip)) return false;
            junglePyramid(p, c, clip, place_rand);
            return true;
        },
        .witch => {
            const c = Component{ .mode = mode, .box = bbox_mod.sizedBox(sx * 16, 64, sz * 16, 7, 5, 9, mode) };
            if (!c.box.intersects(clip)) return false;
            witchHut(p, c, clip, place_rand);
            return true;
        },
    }
}

/// Ground level: average topY over the box∩clip columns, maxed with the
/// provider average; null when no column is inside (`aue.a`). Shifts the
/// component by (avg - minY + yOff).
fn groundShift(p: Placer, c: *Component, clip: BBox, y_off: i32) bool {
    var sum: i64 = 0;
    var n: i64 = 0;
    var z = c.box.min_z;
    while (z <= c.box.max_z) : (z += 1) {
        var x = c.box.min_x;
        while (x <= c.box.max_x) : (x += 1) {
            if (!clip.contains(x, 64, z)) continue;
            sum += @max(p.topY(x, z), p.groundBase());
            n += 1;
        }
    }
    if (n == 0) return false;
    const avg: i32 = @intCast(@divTrunc(sum, n));
    c.box = c.box.offset(0, avg - c.box.min_y + y_off, 0);
    return true;
}

// ---------------------------------------------------------------------------
// Desert pyramid (`aub`, 21x15x21 at y=64, no ground leveling).
// ---------------------------------------------------------------------------

pub fn desertPyramid(p: Placer, c: Component, clip: BBox, rand: *JavaRandom) void {
    comp_mod.fillBox(p, c, clip, 0, -4, 0, 20, 0, 20, .sandstone, .sandstone, false);
    var lvl: i32 = 1;
    while (lvl <= 9) : (lvl += 1) {
        comp_mod.fillBox(p, c, clip, lvl, lvl, lvl, 20 - lvl, lvl, 20 - lvl, .sandstone, .sandstone, false);
        comp_mod.fillBox(p, c, clip, lvl + 1, lvl, lvl + 1, 19 - lvl, lvl, 19 - lvl, .air, .air, false);
    }
    // Foundation pillars down from y=-5.
    var px: i32 = 0;
    while (px < 21) : (px += 1) {
        var pz: i32 = 0;
        while (pz < 21) : (pz += 1) {
            comp_mod.fillDownwards(p, c, clip, .sandstone, 0, px, -5, pz);
        }
    }
    const s3 = comp_mod.rotateMeta(.sandstone_stairs, 3, c.mode);
    const s2 = comp_mod.rotateMeta(.sandstone_stairs, 2, c.mode);
    const s0 = comp_mod.rotateMeta(.sandstone_stairs, 0, c.mode);
    const s1 = comp_mod.rotateMeta(.sandstone_stairs, 1, c.mode);
    const wool_orange: u4 = 1;
    const wool_blue: u4 = 11;
    comp_mod.fillBox(p, c, clip, 0, 0, 0, 4, 9, 4, .sandstone, .air, false);
    comp_mod.fillBox(p, c, clip, 1, 10, 1, 3, 10, 3, .sandstone, .sandstone, false);
    comp_mod.placeAt(p, c, clip, .sandstone_stairs, s3, 2, 10, 0);
    comp_mod.placeAt(p, c, clip, .sandstone_stairs, s2, 2, 10, 4);
    comp_mod.placeAt(p, c, clip, .sandstone_stairs, s0, 0, 10, 2);
    comp_mod.placeAt(p, c, clip, .sandstone_stairs, s1, 4, 10, 2);
    comp_mod.fillBox(p, c, clip, 16, 0, 0, 20, 9, 4, .sandstone, .air, false);
    comp_mod.fillBox(p, c, clip, 17, 10, 1, 19, 10, 3, .sandstone, .sandstone, false);
    comp_mod.placeAt(p, c, clip, .sandstone_stairs, s3, 18, 10, 0);
    comp_mod.placeAt(p, c, clip, .sandstone_stairs, s2, 18, 10, 4);
    comp_mod.placeAt(p, c, clip, .sandstone_stairs, s0, 16, 10, 2);
    comp_mod.placeAt(p, c, clip, .sandstone_stairs, s1, 20, 10, 2);
    comp_mod.fillBox(p, c, clip, 8, 0, 0, 12, 4, 4, .sandstone, .air, false);
    comp_mod.fillBox(p, c, clip, 9, 1, 0, 11, 3, 4, .air, .air, false);
    comp_mod.placeAt(p, c, clip, .sandstone, 2, 9, 1, 1);
    comp_mod.placeAt(p, c, clip, .sandstone, 2, 9, 2, 1);
    comp_mod.placeAt(p, c, clip, .sandstone, 2, 9, 3, 1);
    comp_mod.placeAt(p, c, clip, .sandstone, 2, 10, 3, 1);
    comp_mod.placeAt(p, c, clip, .sandstone, 2, 11, 3, 1);
    comp_mod.placeAt(p, c, clip, .sandstone, 2, 11, 2, 1);
    comp_mod.placeAt(p, c, clip, .sandstone, 2, 11, 1, 1);
    comp_mod.fillBox(p, c, clip, 4, 1, 1, 8, 3, 3, .sandstone, .air, false);
    comp_mod.fillBox(p, c, clip, 4, 1, 2, 8, 2, 2, .air, .air, false);
    comp_mod.fillBox(p, c, clip, 12, 1, 1, 16, 3, 3, .sandstone, .air, false);
    comp_mod.fillBox(p, c, clip, 12, 1, 2, 16, 2, 2, .air, .air, false);
    comp_mod.fillBox(p, c, clip, 5, 4, 5, 15, 4, 15, .sandstone, .sandstone, false);
    comp_mod.fillBox(p, c, clip, 9, 4, 9, 11, 4, 11, .air, .air, false);
    const pil = [_]struct { x: i32, z: i32 }{
        .{ .x = 8, .z = 8 }, .{ .x = 12, .z = 8 }, .{ .x = 8, .z = 12 }, .{ .x = 12, .z = 12 },
    };
    for (pil) |q| comp_mod.fillBoxMeta(p, c, clip, q.x, 1, q.z, q.x, 3, q.z, .sandstone, 2, .sandstone, 2, false);
    comp_mod.fillBox(p, c, clip, 1, 1, 5, 4, 4, 11, .sandstone, .sandstone, false);
    comp_mod.fillBox(p, c, clip, 16, 1, 5, 19, 4, 11, .sandstone, .sandstone, false);
    comp_mod.fillBox(p, c, clip, 6, 7, 9, 6, 7, 11, .sandstone, .sandstone, false);
    comp_mod.fillBox(p, c, clip, 14, 7, 9, 14, 7, 11, .sandstone, .sandstone, false);
    comp_mod.fillBoxMeta(p, c, clip, 5, 5, 9, 5, 7, 11, .sandstone, 2, .sandstone, 2, false);
    comp_mod.fillBoxMeta(p, c, clip, 15, 5, 9, 15, 7, 11, .sandstone, 2, .sandstone, 2, false);
    comp_mod.placeAt(p, c, clip, .air, 0, 5, 5, 10);
    comp_mod.placeAt(p, c, clip, .air, 0, 5, 6, 10);
    comp_mod.placeAt(p, c, clip, .air, 0, 6, 6, 10);
    comp_mod.placeAt(p, c, clip, .air, 0, 15, 5, 10);
    comp_mod.placeAt(p, c, clip, .air, 0, 15, 6, 10);
    comp_mod.placeAt(p, c, clip, .air, 0, 14, 6, 10);
    comp_mod.fillBox(p, c, clip, 2, 4, 4, 2, 6, 4, .air, .air, false);
    comp_mod.fillBox(p, c, clip, 18, 4, 4, 18, 6, 4, .air, .air, false);
    comp_mod.placeAt(p, c, clip, .sandstone_stairs, s3, 2, 4, 5);
    comp_mod.placeAt(p, c, clip, .sandstone_stairs, s3, 2, 3, 4);
    comp_mod.placeAt(p, c, clip, .sandstone_stairs, s3, 18, 4, 5);
    comp_mod.placeAt(p, c, clip, .sandstone_stairs, s3, 18, 3, 4);
    comp_mod.fillBox(p, c, clip, 1, 1, 3, 2, 2, 3, .sandstone, .sandstone, false);
    comp_mod.fillBox(p, c, clip, 18, 1, 3, 19, 2, 3, .sandstone, .sandstone, false);
    comp_mod.placeAt(p, c, clip, .sandstone_stairs, 0, 1, 1, 2);
    comp_mod.placeAt(p, c, clip, .sandstone_stairs, 0, 19, 1, 2);
    comp_mod.placeAt(p, c, clip, .stone_slab, 1, 1, 2, 2);
    comp_mod.placeAt(p, c, clip, .stone_slab, 1, 19, 2, 2);
    comp_mod.placeAt(p, c, clip, .sandstone_stairs, s1, 2, 1, 2);
    comp_mod.placeAt(p, c, clip, .sandstone_stairs, s0, 18, 1, 2);
    comp_mod.fillBox(p, c, clip, 4, 3, 5, 4, 3, 18, .sandstone, .sandstone, false);
    comp_mod.fillBox(p, c, clip, 16, 3, 5, 16, 3, 17, .sandstone, .sandstone, false);
    comp_mod.fillBox(p, c, clip, 3, 1, 5, 4, 2, 16, .air, .air, false);
    comp_mod.fillBox(p, c, clip, 15, 1, 5, 16, 2, 16, .air, .air, false);
    var rail: i32 = 5;
    while (rail <= 17) : (rail += 2) {
        comp_mod.placeAt(p, c, clip, .sandstone, 2, 4, 1, rail);
        comp_mod.placeAt(p, c, clip, .sandstone, 1, 4, 2, rail);
        comp_mod.placeAt(p, c, clip, .sandstone, 2, 16, 1, rail);
        comp_mod.placeAt(p, c, clip, .sandstone, 1, 16, 2, rail);
    }
    // Wool pit floor (orange ring, blue center).
    comp_mod.placeAt(p, c, clip, .wool, wool_orange, 10, 0, 7);
    comp_mod.placeAt(p, c, clip, .wool, wool_orange, 10, 0, 8);
    comp_mod.placeAt(p, c, clip, .wool, wool_orange, 9, 0, 9);
    comp_mod.placeAt(p, c, clip, .wool, wool_orange, 11, 0, 9);
    comp_mod.placeAt(p, c, clip, .wool, wool_orange, 8, 0, 10);
    comp_mod.placeAt(p, c, clip, .wool, wool_orange, 12, 0, 10);
    comp_mod.placeAt(p, c, clip, .wool, wool_orange, 7, 0, 10);
    comp_mod.placeAt(p, c, clip, .wool, wool_orange, 13, 0, 10);
    comp_mod.placeAt(p, c, clip, .wool, wool_orange, 9, 0, 11);
    comp_mod.placeAt(p, c, clip, .wool, wool_orange, 11, 0, 11);
    comp_mod.placeAt(p, c, clip, .wool, wool_orange, 10, 0, 12);
    comp_mod.placeAt(p, c, clip, .wool, wool_orange, 10, 0, 13);
    comp_mod.placeAt(p, c, clip, .wool, wool_blue, 10, 0, 10);
    // Corner towers.
    var t: i32 = 0;
    while (t <= 20) : (t += 20) {
        comp_mod.placeAt(p, c, clip, .sandstone, 2, t, 2, 1);
        comp_mod.placeAt(p, c, clip, .wool, wool_orange, t, 2, 2);
        comp_mod.placeAt(p, c, clip, .sandstone, 2, t, 2, 3);
        comp_mod.placeAt(p, c, clip, .sandstone, 2, t, 3, 1);
        comp_mod.placeAt(p, c, clip, .wool, wool_orange, t, 3, 2);
        comp_mod.placeAt(p, c, clip, .sandstone, 2, t, 3, 3);
        comp_mod.placeAt(p, c, clip, .wool, wool_orange, t, 4, 1);
        comp_mod.placeAt(p, c, clip, .sandstone, 1, t, 4, 2);
        comp_mod.placeAt(p, c, clip, .wool, wool_orange, t, 4, 3);
        comp_mod.placeAt(p, c, clip, .sandstone, 2, t, 5, 1);
        comp_mod.placeAt(p, c, clip, .wool, wool_orange, t, 5, 2);
        comp_mod.placeAt(p, c, clip, .sandstone, 2, t, 5, 3);
        comp_mod.placeAt(p, c, clip, .wool, wool_orange, t, 6, 1);
        comp_mod.placeAt(p, c, clip, .sandstone, 1, t, 6, 2);
        comp_mod.placeAt(p, c, clip, .wool, wool_orange, t, 6, 3);
        comp_mod.placeAt(p, c, clip, .wool, wool_orange, t, 7, 1);
        comp_mod.placeAt(p, c, clip, .wool, wool_orange, t, 7, 2);
        comp_mod.placeAt(p, c, clip, .wool, wool_orange, t, 7, 3);
        comp_mod.placeAt(p, c, clip, .sandstone, 2, t, 8, 1);
        comp_mod.placeAt(p, c, clip, .sandstone, 2, t, 8, 2);
        comp_mod.placeAt(p, c, clip, .sandstone, 2, t, 8, 3);
    }
    // Front/back trim.
    var e2: i32 = 2;
    while (e2 <= 18) : (e2 += 16) {
        comp_mod.placeAt(p, c, clip, .sandstone, 2, e2 - 1, 2, 0);
        comp_mod.placeAt(p, c, clip, .wool, wool_orange, e2, 2, 0);
        comp_mod.placeAt(p, c, clip, .sandstone, 2, e2 + 1, 2, 0);
        comp_mod.placeAt(p, c, clip, .sandstone, 2, e2 - 1, 3, 0);
        comp_mod.placeAt(p, c, clip, .wool, wool_orange, e2, 3, 0);
        comp_mod.placeAt(p, c, clip, .sandstone, 2, e2 + 1, 3, 0);
        comp_mod.placeAt(p, c, clip, .wool, wool_orange, e2 - 1, 4, 0);
        comp_mod.placeAt(p, c, clip, .sandstone, 1, e2, 4, 0);
        comp_mod.placeAt(p, c, clip, .wool, wool_orange, e2 + 1, 4, 0);
        comp_mod.placeAt(p, c, clip, .sandstone, 2, e2 - 1, 5, 0);
        comp_mod.placeAt(p, c, clip, .wool, wool_orange, e2, 5, 0);
        comp_mod.placeAt(p, c, clip, .sandstone, 2, e2 + 1, 5, 0);
        comp_mod.placeAt(p, c, clip, .wool, wool_orange, e2 - 1, 6, 0);
        comp_mod.placeAt(p, c, clip, .sandstone, 1, e2, 6, 0);
        comp_mod.placeAt(p, c, clip, .wool, wool_orange, e2 + 1, 6, 0);
        comp_mod.placeAt(p, c, clip, .wool, wool_orange, e2 - 1, 7, 0);
        comp_mod.placeAt(p, c, clip, .wool, wool_orange, e2, 7, 0);
        comp_mod.placeAt(p, c, clip, .wool, wool_orange, e2 + 1, 7, 0);
        comp_mod.placeAt(p, c, clip, .sandstone, 2, e2 - 1, 8, 0);
        comp_mod.placeAt(p, c, clip, .sandstone, 2, e2, 8, 0);
        comp_mod.placeAt(p, c, clip, .sandstone, 2, e2 + 1, 8, 0);
    }
    // Entrance arch + basement treasure room.
    comp_mod.fillBoxMeta(p, c, clip, 8, 4, 0, 12, 6, 0, .sandstone, 2, .sandstone, 2, false);
    comp_mod.placeAt(p, c, clip, .air, 0, 8, 6, 0);
    comp_mod.placeAt(p, c, clip, .air, 0, 12, 6, 0);
    comp_mod.placeAt(p, c, clip, .wool, wool_orange, 9, 5, 0);
    comp_mod.placeAt(p, c, clip, .sandstone, 1, 10, 5, 0);
    comp_mod.placeAt(p, c, clip, .wool, wool_orange, 11, 5, 0);
    comp_mod.fillBoxMeta(p, c, clip, 8, -14, 8, 12, -11, 12, .sandstone, 2, .sandstone, 2, false);
    comp_mod.fillBoxMeta(p, c, clip, 8, -10, 8, 12, -10, 12, .sandstone, 1, .sandstone, 1, false);
    comp_mod.fillBoxMeta(p, c, clip, 8, -9, 8, 12, -9, 12, .sandstone, 2, .sandstone, 2, false);
    comp_mod.fillBox(p, c, clip, 8, -8, 8, 12, -1, 12, .sandstone, .sandstone, false);
    comp_mod.fillBox(p, c, clip, 9, -11, 9, 11, -1, 11, .air, .air, false);
    comp_mod.placeAt(p, c, clip, .stone_pressure_plate, 0, 10, -11, 10);
    comp_mod.fillBox(p, c, clip, 9, -13, 9, 11, -13, 11, .tnt, .air, false);
    comp_mod.placeAt(p, c, clip, .air, 0, 8, -11, 10);
    comp_mod.placeAt(p, c, clip, .air, 0, 8, -10, 10);
    comp_mod.placeAt(p, c, clip, .sandstone, 1, 7, -10, 10);
    comp_mod.placeAt(p, c, clip, .sandstone, 2, 7, -11, 10);
    comp_mod.placeAt(p, c, clip, .air, 0, 12, -11, 10);
    comp_mod.placeAt(p, c, clip, .air, 0, 12, -10, 10);
    comp_mod.placeAt(p, c, clip, .sandstone, 1, 13, -10, 10);
    comp_mod.placeAt(p, c, clip, .sandstone, 2, 13, -11, 10);
    comp_mod.placeAt(p, c, clip, .air, 0, 10, -11, 8);
    comp_mod.placeAt(p, c, clip, .air, 0, 10, -10, 8);
    comp_mod.placeAt(p, c, clip, .sandstone, 1, 10, -10, 7);
    comp_mod.placeAt(p, c, clip, .sandstone, 2, 10, -11, 7);
    comp_mod.placeAt(p, c, clip, .air, 0, 10, -11, 12);
    comp_mod.placeAt(p, c, clip, .air, 0, 10, -10, 12);
    comp_mod.placeAt(p, c, clip, .sandstone, 1, 10, -10, 13);
    comp_mod.placeAt(p, c, clip, .sandstone, 2, 10, -11, 13);
    // Four trapped chests: book loot draws + 2-6 rolls each.
    var ci: i32 = 0;
    const offs = [_]struct { dx: i32, dz: i32 }{ .{ .dx = 0, .dz = 2 }, .{ .dx = -2, .dz = 0 }, .{ .dx = 0, .dz = -2 }, .{ .dx = 2, .dz = 0 } };
    while (ci < 4) : (ci += 1) {
        loot_mod.replicateBookDraws(rand);
        const nrolls = 2 + (rand.nextIntBound(5) catch unreachable);
        _ = comp_mod.placeChest(p, c, clip, rand, 10 + offs[@intCast(ci)].dx, -11, 10 + offs[@intCast(ci)].dz, &loot_mod.pyramid, nrolls);
    }
}

/// Mossy-brick selector for jungle temples (`aud`): 40% cobble.
pub fn jungleBrick(rand: *JavaRandom) placer_mod.Block {
    return if (rand.nextFloat() < 0.4) .{ .id = .cobblestone, .meta = 0 } else .{ .id = .mossy_cobblestone, .meta = 0 };
}

fn jungleChoose(rand: *JavaRandom, edge: bool) placer_mod.Block {
    _ = edge;
    return jungleBrick(rand);
}

/// Lever wall meta (`alv.b`).
pub fn leverWallMeta(rotated: u4) u4 {
    return switch (rotated) {
        0 => 0,
        1 => 5,
        2 => 4,
        3 => 3,
        4 => 2,
        5 => 1,
        else => 0,
    };
}

// ---------------------------------------------------------------------------
// Jungle pyramid (`auc`, 12x10x15).
// ---------------------------------------------------------------------------

pub fn junglePyramid(p: Placer, c: Component, clip: BBox, rand: *JavaRandom) void {
    var cc = c;
    if (!groundShift(p, &cc, clip, 0)) return;
    const c0 = cc;
    const st3 = comp_mod.rotateMeta(.stone_stairs, 3, c0.mode);
    const st2 = comp_mod.rotateMeta(.stone_stairs, 2, c0.mode);
    const st0 = comp_mod.rotateMeta(.stone_stairs, 0, c0.mode);
    const st1 = comp_mod.rotateMeta(.stone_stairs, 1, c0.mode);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 0, -4, 0, 11, 0, 14, false, jungleChoose);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 2, 1, 2, 9, 2, 2, false, jungleChoose);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 2, 1, 12, 9, 2, 12, false, jungleChoose);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 2, 1, 3, 2, 2, 11, false, jungleChoose);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 9, 1, 3, 9, 2, 11, false, jungleChoose);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 1, 3, 1, 10, 6, 1, false, jungleChoose);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 1, 3, 13, 10, 6, 13, false, jungleChoose);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 1, 3, 2, 1, 6, 12, false, jungleChoose);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 10, 3, 2, 10, 6, 12, false, jungleChoose);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 2, 3, 2, 9, 3, 12, false, jungleChoose);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 2, 6, 2, 9, 6, 12, false, jungleChoose);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 3, 7, 3, 8, 7, 11, false, jungleChoose);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 4, 8, 4, 7, 8, 10, false, jungleChoose);
    comp_mod.fillAir(p, c0, clip, 3, 1, 3, 8, 2, 11);
    comp_mod.fillAir(p, c0, clip, 4, 3, 6, 7, 3, 9);
    comp_mod.fillAir(p, c0, clip, 2, 4, 2, 9, 5, 12);
    comp_mod.fillAir(p, c0, clip, 4, 6, 5, 7, 6, 9);
    comp_mod.fillAir(p, c0, clip, 5, 7, 6, 6, 7, 8);
    comp_mod.fillAir(p, c0, clip, 5, 1, 2, 6, 2, 2);
    comp_mod.fillAir(p, c0, clip, 5, 2, 12, 6, 2, 12);
    comp_mod.fillAir(p, c0, clip, 5, 5, 1, 6, 5, 1);
    comp_mod.fillAir(p, c0, clip, 5, 5, 13, 6, 5, 13);
    comp_mod.placeAt(p, c0, clip, .air, 0, 1, 5, 5);
    comp_mod.placeAt(p, c0, clip, .air, 0, 10, 5, 5);
    comp_mod.placeAt(p, c0, clip, .air, 0, 1, 5, 9);
    comp_mod.placeAt(p, c0, clip, .air, 0, 10, 5, 9);
    var col: i32 = 0;
    while (col <= 14) : (col += 14) {
        comp_mod.fillBoxChoose(p, c0, clip, rand, 2, 4, col, 2, 5, col, false, jungleChoose);
        comp_mod.fillBoxChoose(p, c0, clip, rand, 4, 4, col, 4, 5, col, false, jungleChoose);
        comp_mod.fillBoxChoose(p, c0, clip, rand, 7, 4, col, 7, 5, col, false, jungleChoose);
        comp_mod.fillBoxChoose(p, c0, clip, rand, 9, 4, col, 9, 5, col, false, jungleChoose);
    }
    comp_mod.fillBoxChoose(p, c0, clip, rand, 5, 6, 0, 6, 6, 0, false, jungleChoose);
    var side: i32 = 0;
    while (side <= 11) : (side += 11) {
        var post: i32 = 2;
        while (post <= 12) : (post += 2) {
            comp_mod.fillBoxChoose(p, c0, clip, rand, side, 4, post, side, 5, post, false, jungleChoose);
        }
        comp_mod.fillBoxChoose(p, c0, clip, rand, side, 6, 5, side, 6, 5, false, jungleChoose);
        comp_mod.fillBoxChoose(p, c0, clip, rand, side, 6, 9, side, 6, 9, false, jungleChoose);
    }
    comp_mod.fillBoxChoose(p, c0, clip, rand, 2, 7, 2, 2, 9, 2, false, jungleChoose);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 9, 7, 2, 9, 9, 2, false, jungleChoose);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 2, 7, 12, 2, 9, 12, false, jungleChoose);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 9, 7, 12, 9, 9, 12, false, jungleChoose);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 5, 9, 7, 6, 9, 7, false, jungleChoose);
    comp_mod.placeAt(p, c0, clip, .stone_stairs, st3, 5, 9, 6);
    comp_mod.placeAt(p, c0, clip, .stone_stairs, st3, 6, 9, 6);
    comp_mod.placeAt(p, c0, clip, .stone_stairs, st2, 5, 9, 8);
    comp_mod.placeAt(p, c0, clip, .stone_stairs, st2, 6, 9, 8);
    comp_mod.placeAt(p, c0, clip, .stone_stairs, st3, 4, 0, 0);
    comp_mod.placeAt(p, c0, clip, .stone_stairs, st3, 5, 0, 0);
    comp_mod.placeAt(p, c0, clip, .stone_stairs, st3, 6, 0, 0);
    comp_mod.placeAt(p, c0, clip, .stone_stairs, st3, 7, 0, 0);
    comp_mod.placeAt(p, c0, clip, .stone_stairs, st3, 4, 1, 8);
    comp_mod.placeAt(p, c0, clip, .stone_stairs, st3, 4, 2, 9);
    comp_mod.placeAt(p, c0, clip, .stone_stairs, st3, 4, 3, 10);
    comp_mod.placeAt(p, c0, clip, .stone_stairs, st3, 7, 1, 8);
    comp_mod.placeAt(p, c0, clip, .stone_stairs, st3, 7, 2, 9);
    comp_mod.placeAt(p, c0, clip, .stone_stairs, st3, 7, 3, 10);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 4, 1, 9, 4, 1, 9, false, jungleChoose);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 7, 1, 9, 7, 1, 9, false, jungleChoose);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 4, 1, 10, 7, 2, 10, false, jungleChoose);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 5, 4, 5, 6, 4, 5, false, jungleChoose);
    comp_mod.placeAt(p, c0, clip, .stone_stairs, st0, 4, 4, 5);
    comp_mod.placeAt(p, c0, clip, .stone_stairs, st1, 7, 4, 5);
    var step: i32 = 0;
    while (step < 4) : (step += 1) {
        comp_mod.placeAt(p, c0, clip, .stone_stairs, st2, 5, 0 - step, 6 + step);
        comp_mod.placeAt(p, c0, clip, .stone_stairs, st2, 6, 0 - step, 6 + step);
        comp_mod.fillBox(p, c0, clip, 5, 0 - step, 7 + step, 6, 0 - step, 9 + step, .air, .air, false);
    }
    comp_mod.fillAir(p, c0, clip, 1, -3, 12, 10, -1, 13);
    comp_mod.fillAir(p, c0, clip, 1, -3, 1, 3, -1, 13);
    comp_mod.fillAir(p, c0, clip, 1, -3, 1, 9, -1, 5);
    var vcol: i32 = 1;
    while (vcol <= 13) : (vcol += 2) {
        comp_mod.fillBoxChoose(p, c0, clip, rand, 1, -3, vcol, 1, -2, vcol, false, jungleChoose);
    }
    var hrow: i32 = 2;
    while (hrow <= 12) : (hrow += 2) {
        comp_mod.fillBoxChoose(p, c0, clip, rand, 1, -1, hrow, 3, -1, hrow, false, jungleChoose);
    }
    comp_mod.fillBoxChoose(p, c0, clip, rand, 2, -2, 1, 5, -2, 1, false, jungleChoose);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 7, -2, 1, 9, -2, 1, false, jungleChoose);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 6, -3, 1, 6, -3, 1, false, jungleChoose);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 6, -1, 1, 6, -1, 1, false, jungleChoose);
    comp_mod.placeAt(p, c0, clip, .tripwire_hook, comp_mod.rotateMeta(.tripwire_hook, 3, c0.mode) | 4, 1, -3, 8);
    comp_mod.placeAt(p, c0, clip, .tripwire_hook, comp_mod.rotateMeta(.tripwire_hook, 1, c0.mode) | 4, 4, -3, 8);
    comp_mod.placeAt(p, c0, clip, .tripwire, 4, 2, -3, 8);
    comp_mod.placeAt(p, c0, clip, .tripwire, 4, 3, -3, 8);
    comp_mod.placeAt(p, c0, clip, .redstone_wire, 0, 5, -3, 7);
    comp_mod.placeAt(p, c0, clip, .redstone_wire, 0, 5, -3, 6);
    comp_mod.placeAt(p, c0, clip, .redstone_wire, 0, 5, -3, 5);
    comp_mod.placeAt(p, c0, clip, .redstone_wire, 0, 5, -3, 4);
    comp_mod.placeAt(p, c0, clip, .redstone_wire, 0, 5, -3, 3);
    comp_mod.placeAt(p, c0, clip, .redstone_wire, 0, 5, -3, 2);
    comp_mod.placeAt(p, c0, clip, .redstone_wire, 0, 5, -3, 1);
    comp_mod.placeAt(p, c0, clip, .redstone_wire, 0, 4, -3, 1);
    comp_mod.placeAt(p, c0, clip, .mossy_cobblestone, 0, 3, -3, 1);
    _ = comp_mod.placeDispenser(p, c0, clip, rand, 3, -2, 1, 2, &loot_mod.jungle_dispenser, 2);
    comp_mod.placeAt(p, c0, clip, .vine, 15, 3, -2, 2);
    comp_mod.placeAt(p, c0, clip, .tripwire_hook, comp_mod.rotateMeta(.tripwire_hook, 2, c0.mode) | 4, 7, -3, 1);
    comp_mod.placeAt(p, c0, clip, .tripwire_hook, comp_mod.rotateMeta(.tripwire_hook, 0, c0.mode) | 4, 7, -3, 5);
    comp_mod.placeAt(p, c0, clip, .tripwire, 4, 7, -3, 2);
    comp_mod.placeAt(p, c0, clip, .tripwire, 4, 7, -3, 3);
    comp_mod.placeAt(p, c0, clip, .tripwire, 4, 7, -3, 4);
    comp_mod.placeAt(p, c0, clip, .redstone_wire, 0, 8, -3, 6);
    comp_mod.placeAt(p, c0, clip, .redstone_wire, 0, 9, -3, 6);
    comp_mod.placeAt(p, c0, clip, .redstone_wire, 0, 9, -3, 5);
    comp_mod.placeAt(p, c0, clip, .mossy_cobblestone, 0, 9, -3, 4);
    comp_mod.placeAt(p, c0, clip, .redstone_wire, 0, 9, -2, 4);
    _ = comp_mod.placeDispenser(p, c0, clip, rand, 9, -2, 3, 4, &loot_mod.jungle_dispenser, 2);
    comp_mod.placeAt(p, c0, clip, .vine, 15, 8, -1, 3);
    comp_mod.placeAt(p, c0, clip, .vine, 15, 8, -2, 3);
    // Main chest with book append.
    loot_mod.replicateBookDraws(rand);
    const nmain = 2 + (rand.nextIntBound(5) catch unreachable);
    _ = comp_mod.placeChest(p, c0, clip, rand, 8, -3, 3, &loot_mod.pyramid, nmain);
    // Cobble/mossy patch row (plain mossy placements).
    comp_mod.placeAt(p, c0, clip, .mossy_cobblestone, 0, 8, -3, 1);
    comp_mod.placeAt(p, c0, clip, .mossy_cobblestone, 0, 4, -3, 5);
    comp_mod.placeAt(p, c0, clip, .mossy_cobblestone, 0, 5, -2, 5);
    comp_mod.placeAt(p, c0, clip, .mossy_cobblestone, 0, 5, -1, 5);
    comp_mod.placeAt(p, c0, clip, .mossy_cobblestone, 0, 6, -3, 5);
    comp_mod.placeAt(p, c0, clip, .mossy_cobblestone, 0, 7, -2, 5);
    comp_mod.placeAt(p, c0, clip, .mossy_cobblestone, 0, 7, -1, 5);
    comp_mod.placeAt(p, c0, clip, .mossy_cobblestone, 0, 8, -3, 5);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 9, -1, 1, 9, -1, 5, false, jungleChoose);
    comp_mod.fillAir(p, c0, clip, 8, -3, 8, 10, -1, 10);
    comp_mod.placeAt(p, c0, clip, .stonebrick, 3, 8, -2, 11);
    comp_mod.placeAt(p, c0, clip, .stonebrick, 3, 9, -2, 11);
    comp_mod.placeAt(p, c0, clip, .stonebrick, 3, 10, -2, 11);
    {
        const lm = leverWallMeta(comp_mod.rotateMeta(.lever, 2, c0.mode));
        comp_mod.placeAt(p, c0, clip, .lever, lm, 8, -2, 12);
        comp_mod.placeAt(p, c0, clip, .lever, lm, 9, -2, 12);
        comp_mod.placeAt(p, c0, clip, .lever, lm, 10, -2, 12);
    }
    comp_mod.fillBoxChoose(p, c0, clip, rand, 8, -3, 8, 8, -3, 10, false, jungleChoose);
    comp_mod.fillBoxChoose(p, c0, clip, rand, 10, -3, 8, 10, -3, 10, false, jungleChoose);
    comp_mod.placeAt(p, c0, clip, .mossy_cobblestone, 0, 10, -2, 9);
    comp_mod.placeAt(p, c0, clip, .redstone_wire, 0, 8, -2, 9);
    comp_mod.placeAt(p, c0, clip, .redstone_wire, 0, 8, -2, 10);
    comp_mod.placeAt(p, c0, clip, .redstone_wire, 0, 10, -1, 9);
    comp_mod.placeAt(p, c0, clip, .sticky_piston, 1, 9, -2, 8);
    comp_mod.placeAt(p, c0, clip, .sticky_piston, comp_mod.rotateMeta(.sticky_piston, 4, c0.mode), 10, -2, 8);
    comp_mod.placeAt(p, c0, clip, .sticky_piston, comp_mod.rotateMeta(.sticky_piston, 4, c0.mode), 10, -1, 8);
    comp_mod.placeAt(p, c0, clip, .unpowered_repeater, comp_mod.rotateMeta(.unpowered_repeater, 2, c0.mode), 10, -2, 10);
    // Hidden chest with book append.
    loot_mod.replicateBookDraws(rand);
    const nhid = 2 + (rand.nextIntBound(5) catch unreachable);
    _ = comp_mod.placeChest(p, c0, clip, rand, 9, -3, 10, &loot_mod.pyramid, nhid);
}

// ---------------------------------------------------------------------------
// Witch hut (`auf`, 7x5x9).
// ---------------------------------------------------------------------------

pub fn witchHut(p: Placer, c: Component, clip: BBox, rand: *JavaRandom) void {
    var cc = c;
    if (!groundShift(p, &cc, clip, 0)) return;
    const c0 = cc;
    _ = rand;
    comp_mod.fillBoxMeta(p, c0, clip, 1, 1, 1, 5, 1, 7, .planks, 1, .planks, 1, false);
    comp_mod.fillBoxMeta(p, c0, clip, 1, 4, 2, 5, 4, 7, .planks, 1, .planks, 1, false);
    comp_mod.fillBoxMeta(p, c0, clip, 2, 1, 0, 4, 1, 0, .planks, 1, .planks, 1, false);
    comp_mod.fillBoxMeta(p, c0, clip, 2, 2, 2, 3, 3, 2, .planks, 1, .planks, 1, false);
    comp_mod.fillBoxMeta(p, c0, clip, 1, 2, 3, 1, 3, 6, .planks, 1, .planks, 1, false);
    comp_mod.fillBoxMeta(p, c0, clip, 5, 2, 3, 5, 3, 6, .planks, 1, .planks, 1, false);
    comp_mod.fillBoxMeta(p, c0, clip, 2, 2, 7, 4, 3, 7, .planks, 1, .planks, 1, false);
    comp_mod.fillBoxMeta(p, c0, clip, 1, 0, 2, 1, 3, 2, .log, 0, .log, 0, false);
    comp_mod.fillBoxMeta(p, c0, clip, 5, 0, 2, 5, 3, 2, .log, 0, .log, 0, false);
    comp_mod.fillBoxMeta(p, c0, clip, 1, 0, 7, 1, 3, 7, .log, 0, .log, 0, false);
    comp_mod.fillBoxMeta(p, c0, clip, 5, 0, 7, 5, 3, 7, .log, 0, .log, 0, false);
    comp_mod.placeAt(p, c0, clip, .fence, 0, 2, 3, 2);
    comp_mod.placeAt(p, c0, clip, .fence, 0, 3, 3, 7);
    comp_mod.placeAt(p, c0, clip, .air, 0, 1, 3, 4);
    comp_mod.placeAt(p, c0, clip, .air, 0, 5, 3, 4);
    comp_mod.placeAt(p, c0, clip, .air, 0, 5, 3, 5);
    comp_mod.placeAt(p, c0, clip, .flower_pot_block, 7, 1, 3, 5);
    comp_mod.placeAt(p, c0, clip, .crafting_table, 0, 3, 2, 6);
    comp_mod.placeAt(p, c0, clip, .cauldron_block, 0, 4, 2, 6);
    comp_mod.placeAt(p, c0, clip, .fence, 0, 1, 2, 1);
    comp_mod.placeAt(p, c0, clip, .fence, 0, 5, 2, 1);
    // NOTE vanilla rotates OAK metas then places SPRUCE with the result
    // (`this.a(ajn.ad,...)` fed into `ajn.bF` fills) — replicate exactly.
    const r3 = comp_mod.rotateMeta(.oak_stairs, 3, c0.mode);
    const r1 = comp_mod.rotateMeta(.oak_stairs, 1, c0.mode);
    const r0 = comp_mod.rotateMeta(.oak_stairs, 0, c0.mode);
    const r2 = comp_mod.rotateMeta(.oak_stairs, 2, c0.mode);
    comp_mod.fillBoxMeta(p, c0, clip, 0, 4, 1, 6, 4, 1, .spruce_stairs, r3, .spruce_stairs, r3, false);
    comp_mod.fillBoxMeta(p, c0, clip, 0, 4, 2, 0, 4, 7, .spruce_stairs, r0, .spruce_stairs, r0, false);
    comp_mod.fillBoxMeta(p, c0, clip, 6, 4, 2, 6, 4, 7, .spruce_stairs, r1, .spruce_stairs, r1, false);
    comp_mod.fillBoxMeta(p, c0, clip, 0, 4, 8, 6, 4, 8, .spruce_stairs, r2, .spruce_stairs, r2, false);
    // Log stilts down.
    var sx: i32 = 2;
    while (sx <= 7) : (sx += 5) {
        var sz: i32 = 1;
        while (sz <= 5) : (sz += 4) {
            comp_mod.fillDownwards(p, c0, clip, .log, 0, sz, -1, sx);
        }
    }
    // Witch (runtime entity; no RNG).
    {
        const wx = c0.xWithOffset(2, 5);
        const wy = c0.yWithOffset(2);
        const wz = c0.zWithOffset(2, 5);
        if (clip.contains(wx, wy, wz)) {
            p.spawn(.witch, @as(f64, @floatFromInt(wx)) + 0.5, @as(f64, @floatFromInt(wy)), @as(f64, @floatFromInt(wz)) + 0.5);
        }
    }
}
