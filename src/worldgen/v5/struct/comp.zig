//! Structure piece base (vanilla `avk`, jar-verified).
//!
//! A piece = facing + bounding box. All block access goes through the
//! placer and is clipped to BOTH the piece box and the populate chunk box
//! (vanilla `var5.b(...)` guard on every write). No RNG lives here except
//! the fill helpers that take it explicitly.

const ids = @import("../../../ids.zig");
const wire = @import("../../../proto/v5/wire_ids.zig");
const mc5_blocks = @import("../../../game/mc5/blocks.zig");
const bbox_mod = @import("bbox.zig");
const placer_mod = @import("placer.zig");
const loot_mod = @import("loot.zig");
const java_random = @import("../../rng/java_random.zig");

pub const BBox = bbox_mod.BBox;
pub const Facing = bbox_mod.Facing;
pub const Placer = placer_mod.Placer;
pub const JavaRandom = java_random.JavaRandom;

pub const Component = struct {
    mode: Facing,
    box: BBox,

    pub fn xWithOffset(c: Component, lx: i32, lz: i32) i32 {
        return switch (c.mode) {
            .south, .north => c.box.min_x + lx,
            .west => c.box.max_x - lz,
            .east => c.box.min_x + lz,
        };
    }

    pub fn yWithOffset(c: Component, y: i32) i32 {
        return y + c.box.min_y;
    }

    pub fn zWithOffset(c: Component, lx: i32, lz: i32) i32 {
        return switch (c.mode) {
            .south => c.box.min_z + lz,
            .north => c.box.max_z - lz,
            .west, .east => c.box.min_z + lx,
        };
    }

    pub fn centerX(c: Component) i32 {
        return c.box.centerX();
    }
    pub fn centerY(c: Component) i32 {
        return c.box.centerY();
    }
    pub fn centerZ(c: Component) i32 {
        return c.box.centerZ();
    }
};

/// Facing metadata rotation (`avk.a(Block,int)`, jar-verified verbatim).
/// Returns the rotated meta for a placement in `mode`.
pub fn rotateMeta(id: ids.Id, meta: u4, mode: Facing) u4 {
    const m: u8 = meta;
    // Rail (66).
    if (id == .rail) {
        if (mode == .west or mode == .east) {
            return if (m == 1) @as(u4, 0) else @as(u4, 1);
        }
        return meta;
    }
    const is_door = id == .wooden_door_block or id == .iron_door_block;
    if (!is_door) {
        if (id == .oak_stairs or id == .stone_stairs or id == .stone_brick_stairs or
            id == .nether_brick_stairs or id == .sandstone_stairs)
        {
            return rotateStairs(m, mode);
        }
        if (id == .ladder) {
            return switch (mode) {
                .south => if (m == 2) @as(u4, 3) else if (m == 3) @as(u4, 2) else meta,
                .west => switch (m) {
                    2 => 4,
                    3 => 5,
                    4 => 2,
                    5 => 3,
                    else => meta,
                },
                .east => switch (m) {
                    2 => 5,
                    3 => 4,
                    4 => 2,
                    5 => 3,
                    else => meta,
                },
                .north => meta,
            };
        }
        if (id == .stone_button) {
            return switch (mode) {
                .south => if (m == 3) @as(u4, 4) else if (m == 4) @as(u4, 3) else meta,
                .west => switch (m) {
                    3 => 1,
                    4 => 2,
                    2 => 3,
                    1 => 4,
                    else => meta,
                },
                .east => switch (m) {
                    3 => 2,
                    4 => 1,
                    2 => 3,
                    1 => 4,
                    else => meta,
                },
                .north => meta,
            };
        }
        // Tripwire hook + directional blocks route below.
        if (id != .tripwire_hook and !isDirectional(id)) {
            if (id == .piston or id == .sticky_piston or id == .lever or id == .dispenser) {
                return switch (mode) {
                    .south => if (m == 2 or m == 3) @as(u4, q_a(m)) else meta,
                    .west => switch (m) {
                        2 => 4,
                        3 => 5,
                        4 => 2,
                        5 => 3,
                        else => meta,
                    },
                    .east => switch (m) {
                        2 => 5,
                        3 => 4,
                        4 => 2,
                        5 => 3,
                        else => meta,
                    },
                    .north => meta,
                };
            }
        } else if (mode == .south) {
            if (m == 0 or m == 2) return @as(u4, p_f(m));
            return meta;
        } else if (mode == .west) {
            return switch (m) {
                2 => 1,
                0 => 3,
                1 => 2,
                3 => 0,
                else => meta,
            };
        } else if (mode == .east) {
            return switch (m) {
                2 => 3,
                0 => 1,
                1 => 2,
                3 => 0,
                else => meta,
            };
        }
        return meta;
    }
    // Doors (wooden/iron): 2-bit facing.
    if (mode == .south) {
        if (m == 0) return @as(u4, 2);
        if (m == 2) return @as(u4, 0);
        return meta;
    }
    if (mode == .west) return @as(u4, @truncate((m + 1) & 3));
    if (mode == .east) return @as(u4, @truncate((m + 3) & 3));
    return meta;
}

fn rotateStairs(m: u8, mode: Facing) u4 {
    return switch (mode) {
        .south => if (m == 2) @as(u4, 3) else if (m == 3) @as(u4, 2) else @truncate(m),
        .west => switch (m) {
            0 => 2,
            1 => 3,
            2 => 0,
            3 => 1,
            else => @truncate(m),
        },
        .east => switch (m) {
            0 => 2,
            1 => 3,
            2 => 1,
            3 => 0,
            else => @truncate(m),
        },
        .north => @truncate(m),
    };
}

/// `BlockDirectional` subclasses placed by structures (bed, pumpkin, lit
/// pumpkin, fence gate, wooden button, diodes) — chest-style 2-bit rotation.
fn isDirectional(id: ids.Id) bool {
    return id == .bed_block or id == .pumpkin or id == .lit_pumpkin or
        id == .fence_gate or id == .wooden_button or
        id == .unpowered_repeater or id == .powered_repeater or
        id == .unpowered_comparator or id == .powered_comparator;
}

/// Dispenser facing table (`q.a = {1,0,3,2,5,4}`).
fn q_a(m: u8) u4 {
    return switch (m) {
        0 => 1,
        1 => 0,
        2 => 3,
        3 => 2,
        4 => 5,
        5 => 4,
        else => @truncate(m),
    };
}

/// Chest-style table (`p.f = {2,3,0,1}`).
fn p_f(m: u8) u4 {
    return switch (m) {
        0 => 2,
        1 => 3,
        2 => 0,
        3 => 1,
        else => @truncate(m),
    };
}

/// Raw oriented placement, clipped to the populate box (`avk.a(World,
/// Block, meta, x, y, z, box)`). NO metadata rotation — callers rotate
/// explicitly via `rotateMeta` exactly where vanilla calls
/// `getMetadataWithOffset` (see `placeOrientedAt`).
/// Oriented cell position (shared by placeAt/getAt).
const CellPos = struct { x: i32, y: i32, z: i32 };

fn cellPos(c: Component, lx: i32, y: i32, lz: i32) CellPos {
    return .{ .x = c.xWithOffset(lx, lz), .y = c.yWithOffset(y), .z = c.zWithOffset(lx, lz) };
}

pub fn placeAt(p: Placer, c: Component, clip: BBox, id: ids.Id, meta: u4, lx: i32, y: i32, lz: i32) void {
    const q = cellPos(c, lx, y, lz);
    if (clip.contains(q.x, q.y, q.z)) p.set(q.x, q.y, q.z, id, meta);
}

/// Placement with vanilla-style pre-rotation (`this.a(B, this.a(B, m),
/// x, y, z, box)` call shape).
pub fn placeOrientedAt(p: Placer, c: Component, clip: BBox, id: ids.Id, meta: u4, lx: i32, y: i32, lz: i32) void {
    placeAt(p, c, clip, id, rotateMeta(id, meta, c.mode), lx, y, lz);
}

/// Read one oriented block, air outside the populate box.
pub fn getAt(p: Placer, c: Component, clip: BBox, lx: i32, y: i32, lz: i32) placer_mod.Block {
    const q = cellPos(c, lx, y, lz);
    if (!clip.contains(q.x, q.y, q.z)) return .{ .id = .air, .meta = 0 };
    return p.get(q.x, q.y, q.z);
}

/// Cuboid walk shared by the fillBox* family: per-cell air gate + edge
/// classification, then `doCell`. Each caller maps to one `avk.a`
/// overload — the skeleton below is shared, the cell action is the spec.
/// (fillBoxRandom keeps its own loop: its float gate draws on EVERY cell,
/// before the air gate — folding it in would shift the RNG stream.)
fn fillEach(
    p: Placer,
    c: Component,
    clip: BBox,
    x0: i32,
    y0: i32,
    z0: i32,
    x1: i32,
    y1: i32,
    z1: i32,
    replace_air_only: bool,
    ctx: anytype,
    comptime doCell: anytype,
) void {
    var y = y0;
    while (y <= y1) : (y += 1) {
        var x = x0;
        while (x <= x1) : (x += 1) {
            var z = z0;
            while (z <= z1) : (z += 1) {
                if (replace_air_only and getAt(p, c, clip, x, y, z).id != .air) continue;
                const edge_cell = y == y0 or y == y1 or x == x0 or x == x1 or z == z0 or z == z1;
                doCell(ctx, p, c, clip, edge_cell, x, y, z);
            }
        }
    }
}

/// Fill a cuboid with air (`avk.a(World, box, x0..z1)`).
pub fn fillAir(p: Placer, c: Component, clip: BBox, x0: i32, y0: i32, z0: i32, x1: i32, y1: i32, z1: i32) void {
    const doCell = struct {
        fn f(_: void, pp: Placer, cc: Component, cl: BBox, _: bool, x: i32, y: i32, z: i32) void {
            placeAt(pp, cc, cl, .air, 0, x, y, z);
        }
    }.f;
    fillEach(p, c, clip, x0, y0, z0, x1, y1, z1, false, {}, doCell);
}

/// Fill a cuboid: shell `edge`, interior `fill`, skipping non-air when
/// `replace_air_only` (`avk.a` meta-less overload; interior meta is 0).
pub fn fillBox(p: Placer, c: Component, clip: BBox, x0: i32, y0: i32, z0: i32, x1: i32, y1: i32, z1: i32, edge: ids.Id, fill: ids.Id, replace_air_only: bool) void {
    const Ctx = struct { edge: ids.Id, fill: ids.Id };
    const doCell = struct {
        fn f(ctx: Ctx, pp: Placer, cc: Component, cl: BBox, edge_cell: bool, x: i32, y: i32, z: i32) void {
            if (edge_cell) {
                placeAt(pp, cc, cl, ctx.edge, 0, x, y, z);
            } else {
                placeAt(pp, cc, cl, ctx.fill, 0, x, y, z);
            }
        }
    }.f;
    fillEach(p, c, clip, x0, y0, z0, x1, y1, z1, replace_air_only, Ctx{ .edge = edge, .fill = fill }, doCell);
}

/// Fill a cuboid with explicit metas (`avk.a` meta overload).
pub fn fillBoxMeta(p: Placer, c: Component, clip: BBox, x0: i32, y0: i32, z0: i32, x1: i32, y1: i32, z1: i32, edge: ids.Id, edge_meta: u4, fill: ids.Id, fill_meta: u4, replace_air_only: bool) void {
    const Ctx = struct { edge: ids.Id, edge_meta: u4, fill: ids.Id, fill_meta: u4 };
    const doCell = struct {
        fn f(ctx: Ctx, pp: Placer, cc: Component, cl: BBox, edge_cell: bool, x: i32, y: i32, z: i32) void {
            if (edge_cell) {
                placeAt(pp, cc, cl, ctx.edge, ctx.edge_meta, x, y, z);
            } else {
                placeAt(pp, cc, cl, ctx.fill, ctx.fill_meta, x, y, z);
            }
        }
    }.f;
    fillEach(p, c, clip, x0, y0, z0, x1, y1, z1, replace_air_only, Ctx{ .edge = edge, .edge_meta = edge_meta, .fill = fill, .fill_meta = fill_meta }, doCell);
}

/// Fill with a per-cell block chooser (`avk.a` selector overload; used by
/// stronghold stone-brick variants).
pub fn fillBoxChoose(
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
    replace_air_only: bool,
    choose: *const fn (rand: *JavaRandom, edge: bool) placer_mod.Block,
) void {
    const Ctx = struct { rand: *JavaRandom, choose: *const fn (rand: *JavaRandom, edge: bool) placer_mod.Block };
    const doCell = struct {
        fn f(ctx: Ctx, pp: Placer, cc: Component, cl: BBox, edge_cell: bool, x: i32, y: i32, z: i32) void {
            const b = ctx.choose(ctx.rand, edge_cell);
            placeAt(pp, cc, cl, b.id, b.meta, x, y, z);
        }
    }.f;
    fillEach(p, c, clip, x0, y0, z0, x1, y1, z1, replace_air_only, Ctx{ .rand = rand, .choose = choose }, doCell);
}

/// Randomly fill a cuboid (`avk.a` float-gate overload).
pub fn fillBoxRandom(p: Placer, c: Component, clip: BBox, rand: *JavaRandom, gate: f32, x0: i32, y0: i32, z0: i32, x1: i32, y1: i32, z1: i32, edge: ids.Id, fill: ids.Id, replace_air_only: bool) void {
    var y = y0;
    while (y <= y1) : (y += 1) {
        var x = x0;
        while (x <= x1) : (x += 1) {
            var z = z0;
            while (z <= z1) : (z += 1) {
                if (!(rand.nextFloat() > gate) and (!replace_air_only or getAt(p, c, clip, x, y, z).id == .air)) {
                    const edge_cell = y == y0 or y == y1 or x == x0 or x == x1 or z == z0 or z == z1;
                    if (edge_cell) {
                        placeAt(p, c, clip, edge, 0, x, y, z);
                    } else {
                        placeAt(p, c, clip, fill, 0, x, y, z);
                    }
                }
            }
        }
    }
}

/// Random single placement (`avk.a` float-gate point overload).
pub fn placeRandom(p: Placer, c: Component, clip: BBox, rand: *JavaRandom, gate: f32, lx: i32, y: i32, lz: i32, id: ids.Id, meta: u4) void {
    if (rand.nextFloat() < gate) placeAt(p, c, clip, id, meta, lx, y, lz);
}

/// Ellipsoid fill (`avk.a` center/radii overload).
pub fn fillEllipsoid(p: Placer, c: Component, clip: BBox, x0: i32, y0: i32, z0: i32, x1: i32, y1: i32, z1: i32, id: ids.Id, replace_air_only: bool) void {
    const w: f32 = @floatFromInt(x1 - x0 + 1);
    const h: f32 = @floatFromInt(y1 - y0 + 1);
    const d: f32 = @floatFromInt(z1 - z0 + 1);
    const cx: f32 = @as(f32, @floatFromInt(x0)) + w / 2.0;
    const cz: f32 = @as(f32, @floatFromInt(z0)) + d / 2.0;
    var y = y0;
    while (y <= y1) : (y += 1) {
        const dy: f32 = (@as(f32, @floatFromInt(y)) - @as(f32, @floatFromInt(y0))) / h;
        var x = x0;
        while (x <= x1) : (x += 1) {
            const dx: f32 = (@as(f32, @floatFromInt(x)) - cx) / (w * 0.5);
            var z = z0;
            while (z <= z1) : (z += 1) {
                const dz: f32 = (@as(f32, @floatFromInt(z)) - cz) / (d * 0.5);
                if (!replace_air_only or getAt(p, c, clip, x, y, z).id == .air) {
                    if (dx * dx + dy * dy + dz * dz <= 1.05) {
                        placeAt(p, c, clip, id, 0, x, y, z);
                    }
                }
            }
        }
    }
}

/// Clear everything upward until air (`avk.b` upwards overload).
pub fn clearUpwards(p: Placer, c: Component, clip: BBox, lx: i32, y: i32, lz: i32) void {
    const x = c.xWithOffset(lx, lz);
    const z = c.zWithOffset(lx, lz);
    var yy = c.yWithOffset(y);
    while (yy < 255) {
        if (!clip.contains(x, yy, z)) return;
        if (p.get(x, yy, z).id == .air) return;
        p.set(x, yy, z, .air, 0);
        yy += 1;
        if (!clip.contains(x, yy, z)) return;
    }
}

/// Fill downward through air/liquid until solid (`avk.b` downwards).
pub fn fillDownwards(p: Placer, c: Component, clip: BBox, id: ids.Id, meta: u4, lx: i32, y: i32, lz: i32) void {
    const x = c.xWithOffset(lx, lz);
    const z = c.zWithOffset(lx, lz);
    var yy = c.yWithOffset(y);
    while (yy > 1) {
        if (!clip.contains(x, yy, z)) return;
        const cur = p.get(x, yy, z).id;
        if (cur != .air and !placer_mod.isLiquidId(cur)) return;
        p.set(x, yy, z, id, meta);
        yy -= 1;
        if (!clip.contains(x, yy, z)) return;
    }
}

/// True when liquid touches the piece (`avk.a` isLiquid check, jar-verified
/// verbatim): the expanded piece box (±1) is first CLAMPED to the populate
/// box, then the six faces of the clamped region are scanned for liquid.
/// Interior cells never count.
pub fn liquidInBox(p: Placer, c: Component, box: BBox, clip: BBox) bool {
    _ = c;
    const x0 = @max(box.min_x - 1, clip.min_x);
    const y0 = @max(box.min_y - 1, clip.min_y);
    const z0 = @max(box.min_z - 1, clip.min_z);
    const x1 = @min(box.max_x + 1, clip.max_x);
    const y1 = @min(box.max_y + 1, clip.max_y);
    const z1 = @min(box.max_z + 1, clip.max_z);
    // Top and bottom faces.
    {
        var x = x0;
        while (x <= x1) : (x += 1) {
            var z = z0;
            while (z <= z1) : (z += 1) {
                if (placer_mod.isLiquidId(p.get(x, y0, z).id)) return true;
                if (placer_mod.isLiquidId(p.get(x, y1, z).id)) return true;
            }
        }
    }
    // North and south faces.
    {
        var x = x0;
        while (x <= x1) : (x += 1) {
            var y = y0;
            while (y <= y1) : (y += 1) {
                if (placer_mod.isLiquidId(p.get(x, y, z0).id)) return true;
                if (placer_mod.isLiquidId(p.get(x, y, z1).id)) return true;
            }
        }
    }
    // West and east faces.
    {
        var z = z0;
        while (z <= z1) : (z += 1) {
            var y = y0;
            while (y <= y1) : (y += 1) {
                if (placer_mod.isLiquidId(p.get(x0, y, z).id)) return true;
                if (placer_mod.isLiquidId(p.get(x1, y, z).id)) return true;
            }
        }
    }
    return false;
}

/// Chest with loot (`avk.a` chest overload): places the block; the tile
/// entity contents are dropped (no ZC1 tile entities — same precedent as
/// dungeons) but the loot RNG draws are replicated exactly so downstream
/// draws stay vanilla-identical.
pub fn placeChest(p: Placer, c: Component, clip: BBox, rand: *JavaRandom, lx: i32, y: i32, lz: i32, table: []const loot_mod.Entry, count: i32) bool {
    const x = c.xWithOffset(lx, lz);
    const yy = c.yWithOffset(y);
    const z = c.zWithOffset(lx, lz);
    if (!clip.contains(x, yy, z)) return false;
    if (p.get(x, yy, z).id == .chest) return false;
    p.set(x, yy, z, .chest, 0);
    loot_mod.replicateChestDraws(rand, table, count, loot_mod.chest_slots);
    return true;
}

/// Dispenser with loot (`avk.a` dispenser overload): facing is rotated
/// first, then the block is placed and loot draws replicated.
pub fn placeDispenser(p: Placer, c: Component, clip: BBox, rand: *JavaRandom, lx: i32, y: i32, lz: i32, facing: u4, table: []const loot_mod.Entry, count: i32) bool {
    const x = c.xWithOffset(lx, lz);
    const yy = c.yWithOffset(y);
    const z = c.zWithOffset(lx, lz);
    if (!clip.contains(x, yy, z)) return false;
    if (p.get(x, yy, z).id == .dispenser) return false;
    p.set(x, yy, z, .dispenser, rotateMeta(.dispenser, facing, c.mode));
    loot_mod.replicateChestDraws(rand, table, count, loot_mod.dispenser_slots);
    return true;
}

/// Mob spawner block (`ach`-style inline placement in pieces; the entity
/// type lives in the tile entity, dropped like chest loot — no RNG).
pub fn placeSpawner(p: Placer, c: Component, clip: BBox, lx: i32, y: i32, lz: i32) void {
    placeAt(p, c, clip, .mob_spawner, 0, lx, y, lz);
}

/// Two-block door (`ach.a` placeDoorBlock port): lower half with facing,
/// upper half with hinge bit; hinge follows the jar's (dx,dz) tables and
/// uses the canonical normal-cube table.
pub fn placeDoor(p: Placer, c: Component, clip: BBox, lx: i32, y: i32, lz: i32, facing: u2, id: ids.Id) void {
    const x = c.xWithOffset(lx, lz);
    const yy = c.yWithOffset(y);
    const z = c.zWithOffset(lx, lz);
    if (!clip.contains(x, yy, z)) return;
    const rot: u2 = @truncate(rotateMeta(id, @as(u4, facing), c.mode));
    const fdx: i32, const fdz: i32 = switch (rot) {
        0 => .{ 0, 1 },
        1 => .{ -1, 0 },
        2 => .{ 0, -1 },
        else => .{ 1, 0 },
    };
    const norm = struct {
        fn n(pl: Placer, sx: i32, sy: i32, sz: i32) bool {
            return mc5_blocks.table.get(pl.get(sx, sy, sz).id).normal_cube;
        }
    }.n;
    const left_count: u2 = @as(u2, @intFromBool(norm(p, x - fdx, yy, z - fdz))) +
        @as(u2, @intFromBool(norm(p, x - fdx, yy + 1, z - fdz)));
    const right_count: u2 = @as(u2, @intFromBool(norm(p, x + fdx, yy, z + fdz))) +
        @as(u2, @intFromBool(norm(p, x + fdx, yy + 1, z + fdz)));
    const left_door = p.get(x - fdx, yy, z - fdz).id == id or
        p.get(x - fdx, yy + 1, z - fdz).id == id;
    const right_door = p.get(x + fdx, yy, z + fdz).id == id or
        p.get(x + fdx, yy + 1, z + fdz).id == id;
    const hinge: u4 = if ((left_door and !right_door) or right_count > left_count) 1 else 0;
    placeAt(p, c, clip, id, rot, lx, y, lz);
    if (clip.contains(x, yy + 1, z)) p.set(x, yy + 1, z, id, 8 | hinge);
}

const std = @import("std");

test "offsets follow facing" {
    const b = BBox.init(10, 64, 20, 20, 70, 30);
    const south = Component{ .mode = .south, .box = b };
    try std.testing.expectEqual(@as(i32, 10), south.xWithOffset(0, 0));
    try std.testing.expectEqual(@as(i32, 20), south.zWithOffset(0, 0));
    try std.testing.expectEqual(@as(i32, 64), south.yWithOffset(0));
    const west = Component{ .mode = .west, .box = b };
    try std.testing.expectEqual(@as(i32, 20), west.xWithOffset(0, 0));
    try std.testing.expectEqual(@as(i32, 20), west.zWithOffset(0, 0));
    const north = Component{ .mode = .north, .box = b };
    try std.testing.expectEqual(@as(i32, 30), north.zWithOffset(0, 0));
    const east = Component{ .mode = .east, .box = b };
    try std.testing.expectEqual(@as(i32, 10), east.xWithOffset(0, 0));
}

test "rotateMeta matches jar tables" {
    // Rail swap on E/W facings.
    try std.testing.expectEqual(@as(u4, 0), rotateMeta(.rail, 1, .west));
    try std.testing.expectEqual(@as(u4, 1), rotateMeta(.rail, 0, .east));
    try std.testing.expectEqual(@as(u4, 0), rotateMeta(.rail, 0, .south));
    // Stairs.
    try std.testing.expectEqual(@as(u4, 3), rotateMeta(.oak_stairs, 2, .south));
    try std.testing.expectEqual(@as(u4, 0), rotateMeta(.oak_stairs, 2, .west));
    try std.testing.expectEqual(@as(u4, 1), rotateMeta(.oak_stairs, 2, .east));
    // Ladder.
    try std.testing.expectEqual(@as(u4, 3), rotateMeta(.ladder, 2, .south));
    try std.testing.expectEqual(@as(u4, 4), rotateMeta(.ladder, 2, .west));
    try std.testing.expectEqual(@as(u4, 5), rotateMeta(.ladder, 2, .east));
    // Dispenser/piston/lever 6-dir.
    try std.testing.expectEqual(@as(u4, 3), rotateMeta(.dispenser, 2, .south));
    try std.testing.expectEqual(@as(u4, 4), rotateMeta(.dispenser, 2, .west));
    try std.testing.expectEqual(@as(u4, 5), rotateMeta(.dispenser, 2, .east));
    // Chest-style directional (bed).
    try std.testing.expectEqual(@as(u4, 2), rotateMeta(.bed_block, 0, .south));
    try std.testing.expectEqual(@as(u4, 3), rotateMeta(.bed_block, 0, .west));
    try std.testing.expectEqual(@as(u4, 1), rotateMeta(.bed_block, 0, .east));
    // Doors: 2-bit cycle.
    try std.testing.expectEqual(@as(u4, 2), rotateMeta(.wooden_door_block, 0, .south));
    try std.testing.expectEqual(@as(u4, 1), rotateMeta(.wooden_door_block, 0, .west));
    try std.testing.expectEqual(@as(u4, 3), rotateMeta(.wooden_door_block, 0, .east));
    try std.testing.expectEqual(@as(u4, 0), rotateMeta(.wooden_door_block, 0, .north));
    // Untouched modes pass through.
    try std.testing.expectEqual(@as(u4, 2), rotateMeta(.oak_stairs, 2, .north));
    try std.testing.expectEqual(@as(u4, 5), rotateMeta(.ladder, 5, .north));
}
