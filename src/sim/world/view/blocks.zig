//! Single-block store access for gameplay: peek/ground/apply with lighting.

const std = @import("std");
const chunk_mod = @import("../../../world/chunk.zig");
const store_mod = @import("../../../world/store.zig");
const shard_mod = @import("../../../world/shard.zig");
const ids = @import("../../../ids.zig");
const light = @import("light.zig");
const bleedBorders = light.bleedBorders;
const skyColumn = light.skyColumn;
const snapBorder = light.snapBorder;

/// Apply one block edit to the LSM store (ZC1 roundtrip). Missing chunks
/// (holes) are ignored — generation is P-next. Callers hold the world lock.
pub const PeekBlock = struct { id: ids.Id, meta: u4 };

/// Store key for the chunk holding (x,z).
fn keyFor(x: i32, z: i32) store_mod.ChunkKey {
    return store_mod.encodeKey(0, @divFloor(x, 16), @divFloor(z, 16));
}

/// Load + decode one chunk (owned; caller destroys). Null on holes and
/// corrupt rows (callers treat both as absent). Pub for the redstone
/// adapter's MRU (per-edit neighbor reads would otherwise decode the same
/// chunk a dozen times per break).
pub fn loadChunk(pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, x: i32, z: i32) !?*chunk_mod.Chunk {
    const raw = try pool.get(allocator, keyFor(x, z)) orelse return null;
    defer allocator.free(raw);
    return chunk_mod.Chunk.decode(allocator, raw) catch null;
}

/// Local cell index for world (x, y, z) inside its chunk section.
fn cellIndex(x: i32, y: u8, z: i32) usize {
    return chunk_mod.Section.index(chunk_mod.Chunk.localCoord(x), @truncate(y & 15), chunk_mod.Chunk.localCoord(z));
}

/// Vanilla `isOpaqueCube` approximation for suffocation: full solid cubes
/// suffocate, everything else (air, fluids, glass, leaves, ice, slabs,
/// stairs, plants, torches, rails, snow, etc.) doesn't. Default is opaque
/// (stone/dirt/ores/planks/logs/wool/...). Fences/walls/panes are full
/// cubes here — slightly stricter than vanilla, documented.
pub fn isOpaqueCube(id: ids.Id) bool {
    return switch (id) {
        ids.air, ids.sapling, ids.flowing_water, ids.water, ids.flowing_lava, ids.lava, ids.leaves, ids.glass, ids.bed_block, ids.golden_rail, ids.detector_rail, ids.web, ids.tallgrass, ids.deadbush, ids.yellow_flower, ids.red_flower, ids.brown_mushroom, ids.red_mushroom, ids.stone_slab, ids.torch, ids.fire, ids.oak_stairs, ids.redstone_wire, ids.wheat_block, ids.standing_sign, ids.wooden_door_block, ids.ladder, ids.rail, ids.stone_stairs, ids.wall_sign, ids.lever, ids.stone_pressure_plate, ids.iron_door_block, ids.wooden_pressure_plate, ids.unlit_redstone_torch, ids.redstone_torch, ids.stone_button, ids.snow_layer, ids.ice, ids.reeds_block, ids.fence, ids.unpowered_repeater, ids.powered_repeater, ids.trapdoor, ids.pumpkin_stem, ids.melon_stem, ids.vine, ids.fence_gate, ids.brick_stairs, ids.stone_brick_stairs, ids.waterlily, ids.nether_brick_stairs, ids.nether_wart_block, ids.enchanting_table, ids.brewing_stand_block, ids.cauldron_block, ids.end_portal_frame, ids.wooden_slab, ids.sandstone_stairs, ids.tripwire_hook, ids.tripwire, ids.spruce_stairs, ids.birch_stairs, ids.jungle_stairs, ids.flower_pot_block, ids.carrots, ids.potatoes, ids.wooden_button, ids.skull_block, ids.light_weighted_pressure_plate, ids.heavy_weighted_pressure_plate, ids.unpowered_comparator, ids.powered_comparator, ids.daylight_detector, ids.quartz_stairs, ids.activator_rail, ids.stained_hardened_clay, ids.leaves2, ids.acacia_stairs, ids.dark_oak_stairs, ids.carpet, ids.double_plant, ids.cactus => false, // unassigned wire ids never become Ids: fromWire rejects them at the boundary
        else => true,
    };
}

/// Read one block without mutating. Null when the chunk/section is absent.
pub fn peekBlock(pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, x: i32, y: u8, z: i32) !?PeekBlock {
    const ch = try loadChunk(pool, allocator, x, z) orelse return null;
    defer ch.destroy(allocator);
    const s = ch.sections[@as(usize, y) >> 4] orelse return null;
    const li = cellIndex(x, y, z);
    return .{ .id = s.blocks[li], .meta = chunk_mod.Section.getNibble(&s.meta, li) };
}

/// Highest solid block at (x,z) at or below from_y. Null when the column is
/// missing or entirely air (over-void spawns rest at y 0).
pub fn groundBlockY(pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, x: i32, z: i32, from_y: u8) !?u8 {
    const ch = try loadChunk(pool, allocator, x, z) orelse return null;
    defer ch.destroy(allocator);
    var y: i32 = from_y;
    while (y >= 0) : (y -= 1) {
        const yu: u8 = @intCast(y);
        if (ch.sections[@as(usize, yu) >> 4]) |s| {
            const li = cellIndex(x, yu, z);
            if (s.blocks[li] != ids.air) return yu;
        }
    }
    return null;
}

pub fn applyBlock(pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, x: i32, y: u8, z: i32, id: ids.Id, meta: u4) !u8 {
    const cx = @divFloor(x, 16);
    const cz = @divFloor(z, 16);
    const key = keyFor(x, z);
    const ch = try loadChunk(pool, allocator, x, z) orelse return 0;
    defer ch.destroy(allocator);
    const lx: usize = chunk_mod.Chunk.localCoord(x);
    const lz: usize = chunk_mod.Chunk.localCoord(z);
    const si: usize = @as(usize, y) >> 4;
    const section_created = ch.sections[si] == null;
    if (section_created) {
        if (id == ids.air) return 0; // breaking air in an empty section: no-op
        ch.sections[si] = chunk_mod.Section{};
    }
    const s = &ch.sections[si].?;
    const li: usize = chunk_mod.Section.index(@intCast(lx), @truncate(y & 15), @intCast(lz));
    const old_id = s.blocks[li];
    const old_light = chunk_mod.Section.getNibble(&s.light, li);
    // Cross-chunk border snapshots (both channels) BEFORE the mutation, so
    // edge deltas can be bled into neighbors afterwards. Only needed when
    // the edit can change light at all.
    const e_new = chunk_mod.emitLight(id);
    const e_old = chunk_mod.emitLight(old_id);
    const op_new = chunk_mod.lightOpacity(id);
    const op_old = chunk_mod.lightOpacity(old_id);
    const light_touched = e_new != e_old or op_new != op_old;
    var pre: [4][3][16][256]u8 = undefined;
    if (light_touched) {
        snapBorder(ch, .west, &pre[0][0], &pre[0][1], &pre[0][2]);
        snapBorder(ch, .east, &pre[1][0], &pre[1][1], &pre[1][2]);
        snapBorder(ch, .north, &pre[2][0], &pre[2][1], &pre[2][2]);
        snapBorder(ch, .south, &pre[3][0], &pre[3][1], &pre[3][2]);
    }
    s.blocks[li] = id;
    chunk_mod.Section.setNibble(&s.meta, li, meta);
    // Incremental relight (vanilla re-lights on block change; stale
    // nibbles would otherwise persist until the next full chunk resend).
    // Output-sensitive: a column snapshot + bounded BFS phases instead of
    // the old full-chunk re-flood per edit. Cross-chunk deltas bleed into
    // neighbors below (bleedBorders); diagonal lowering stays approximate.
    const q = try allocator.alloc(u32, 65536);
    defer allocator.free(q);
    relightEdit(ch, q, lx, y, lz, old_id, old_light, section_created);
    // Push border light deltas into adjacent chunks (vanilla floods across
    // borders; without this the neighbor keeps stale nibbles until resend).
    // Returns the touched-neighbor mask (bits 0-3: W,E,N,S; bits 4-7:
    // NW,NE,SW,SE) so callers can resend refreshed columns to trackers.
    var touched: u8 = 0;
    if (light_touched) {
        touched = bleedBorders(pool, allocator, q, ch, cx, cz, lx, lz, &pre) catch 0;
    }
    const enc = try ch.encode(allocator);
    defer allocator.free(enc);
    try pool.put(key, enc);
    return touched;
}

/// Transmissivity direction: true when going from `old` to `new` costs
/// strictly more (null = fully blocked). A cost RISE with a preserved
/// value is invisible to diffing but strands sideways dependents — it
/// forces maximal invalidation (see the sky/block paths below).
fn costRose(new: ?u4, old: ?u4) bool {
    const nc = new orelse return old != null;
    const oc = old orelse return false;
    return nc > oc;
}

/// Ensure `cell` is among the raise seeds (idempotent when idle).
fn ensureSeed(seeds: []u32, n: *usize, cell: u32) void {
    for (seeds[0..n.*]) |s| if (s == cell) return;
    if (n.* < seeds.len) {
        seeds[n.*] = cell;
        n.* += 1;
    }
}

/// Incremental relight after a single-cell edit at local (lx,y,lz).
/// `old_id` / `old_light` (block channel) are pre-edit values at the
/// cell; the block itself is already overwritten. `section_created`
/// skips the column diff (a fresh section has no meaningful "before":
/// relight the whole section vertically, then flood outward).
fn relightEdit(ch: *chunk_mod.Chunk, q: []u32, lx: usize, y: u8, lz: usize, old_id: ids.Id, old_light: u4, section_created: bool) void {
    const new_id = ch.blockAt(lx, y, lz);
    const cell = chunk_mod.Chunk.packCell(lx, y, lz);
    const e_old = chunk_mod.emitLight(old_id);
    const e_new = chunk_mod.emitLight(new_id);
    const op_old = chunk_mod.lightOpacity(old_id);
    const op_new = chunk_mod.lightOpacity(new_id);
    // Transmissivity direction per channel (null cost = fully blocked).
    // A cost RISE with a preserved value is invisible to diffing but
    // strands sideways dependents — it forces maximal invalidation.
    const sc_old = chunk_mod.Chunk.skyCost(op_old);
    const sc_new = chunk_mod.Chunk.skyCost(op_new);
    const srose = costRose(sc_new, sc_old);
    const sdrop = costRose(sc_old, sc_new);
    // --- sky channel: snapshot the column, recompute it, diff ---
    var col_post: [256]u8 = undefined;
    if (section_created) {
        // Vertical exactness for the whole new section first (other
        // columns would otherwise keep the 0xFF default as stale light).
        for (0..16) |ez| {
            for (0..16) |ex| ch.relightColumn(ex, ez);
        }
        // Outflow into neighbors from the new section's bright cells.
        var seeds: [4096]u32 = undefined;
        var n_seeds: usize = 0;
        const s0: usize = (@as(usize, y) >> 4) * 16;
        for (0..16) |ly| {
            for (0..16) |ez| {
                for (0..16) |ex| {
                    const sec = ch.sections[(s0 + ly) >> 4] orelse continue;
                    const v = chunk_mod.Section.getNibble(&sec.sky, chunk_mod.Section.index(@intCast(ex), @intCast(ly), @intCast(ez)));
                    if (v > 1 and n_seeds < seeds.len) {
                        seeds[n_seeds] = chunk_mod.Chunk.packCell(ex, s0 + ly, ez);
                        n_seeds += 1;
                    }
                }
            }
        }
        ch.spreadLight(q, .sky, seeds[0..n_seeds]);
        // Block inflow: the new volume opens flood paths for existing
        // light (torch flood escaping upward through fresh air and back
        // down — without seeds here it stays dark while a full reflood
        // lights it). Seed the adjacent existing rows; creation is
        // monotone (light only rises through new space), so no
        // invalidation is needed, only raises.
        var bseeds: [512]u32 = undefined;
        var n_bseeds: usize = 0;
        for ([2]?usize{ if (s0 > 0) s0 - 1 else null, if (s0 + 16 < 256) s0 + 16 else null }) |maybe_y| {
            const yy = maybe_y orelse continue;
            for (0..256) |i| {
                bseeds[n_bseeds] = chunk_mod.Chunk.packCell(i & 15, yy, (i >> 4) & 15);
                n_bseeds += 1;
            }
        }
        ch.spreadLight(q, .block, bseeds[0..n_bseeds]);
    } else {
        var col_pre: [256]u8 = undefined;
        skyColumn(ch, lx, lz, &col_pre);
        ch.relightColumn(lx, lz);
        skyColumn(ch, lx, lz, &col_post);
        var raised: [256]u32 = undefined;
        var n_raised: usize = 0;
        var lowered: [256]chunk_mod.Chunk.CellValue = undefined;
        var n_lowered: usize = 0;
        var yy: usize = 0;
        while (yy < 256) : (yy += 1) {
            if (col_post[yy] > col_pre[yy]) {
                raised[n_raised] = chunk_mod.Chunk.packCell(lx, yy, lz);
                n_raised += 1;
            } else if (col_post[yy] < col_pre[yy]) {
                lowered[n_lowered] = .{ .cell = chunk_mod.Chunk.packCell(lx, yy, lz), .value = @truncate(col_pre[yy]) };
                n_lowered += 1;
            }
        }
        if (n_lowered > 0 or srose) {
            // Rewrite floors = the whole recomputed column (restores
            // anything phase A zeroes, then refloods sideways on top).
            var rewrite: [256]chunk_mod.Chunk.CellValue = undefined;
            for (0..256) |i| rewrite[i] = .{ .cell = chunk_mod.Chunk.packCell(lx, i, lz), .value = @truncate(col_post[i]) };
            var old_list: [257]chunk_mod.Chunk.CellValue = undefined;
            for (lowered[0..n_lowered], 0..) |lv, i| old_list[i] = lv;
            var n_old = n_lowered;
            if (srose) {
                // Transmissivity died at C (possibly with C's own value
                // preserved — invisible to value-diffing, fatal to skip:
                // sideways dependents would strand). Maximal flow seed.
                var upgraded = false;
                for (old_list[0..n_old]) |*lv| {
                    if (lv.cell == cell) {
                        lv.value = 15;
                        upgraded = true;
                    }
                }
                if (!upgraded) {
                    old_list[n_old] = .{ .cell = cell, .value = 15 };
                    n_old += 1;
                }
            }
            ch.unspreadLight(q, .sky, old_list[0..n_old], rewrite[0..]);
        }
        // Cheapened paths (cost dropped, values unchanged): C's outflow
        // reaches further — seed it (idempotent when idle).
        if (sdrop) ensureSeed(&raised, &n_raised, cell);
        if (n_raised > 0) {
            ch.spreadLight(q, .sky, raised[0..n_raised]);
        }
    }
    // --- block channel: emission/opacity driven, single cell + BFS ---
    const sec = &ch.sections[@as(usize, y) >> 4].?;
    if (e_new != e_old) {
        // Emission pins the cell (vanilla: light AT an emitter = emission).
        chunk_mod.Section.setNibble(&sec.light, chunk_mod.Section.index(@intCast(lx), @truncate(y & 15), @intCast(lz)), e_new);
        if (e_new > e_old) {
            const one = [_]u32{cell};
            ch.spreadLight(q, .block, &one);
        } else {
            const old = [_]chunk_mod.Chunk.CellValue{.{ .cell = cell, .value = old_light }};
            const rw = [_]chunk_mod.Chunk.CellValue{.{ .cell = cell, .value = e_new }};
            ch.unspreadLight(q, .block, &old, &rw);
        }
    } else if (op_new != op_old) {
        // Opacity-only change: recompute the cell from neighbors +
        // emission at the NEW costs (best-of; opaque forces 0), then
        // drive phases off the delta plus transmissivity direction (a
        // cost rise with a preserved value strands sideways dependents
        // invisibly — same hole as sky, same maximal-flow cure).
        var best: u4 = e_new;
        if (op_new != 255) {
            const drop = chunk_mod.Chunk.blockCost(op_new).?;
            for (chunk_mod.Chunk.light_dirs) |d| {
                const nx = @as(i32, @intCast(lx)) + d[0];
                const ny = @as(i32, y) + d[1];
                const nz = @as(i32, @intCast(lz)) + d[2];
                if (nx < 0 or nx > 15 or ny < 0 or ny > 255 or nz < 0 or nz > 15) continue;
                const nv: u4 = ch.getLightAt(@intCast(nx), @intCast(ny), @intCast(nz));
                if (nv > drop and nv - drop > best) best = nv - drop;
            }
        } else {
            best = 0;
        }
        const cur = chunk_mod.Section.getNibble(&sec.light, chunk_mod.Section.index(@intCast(lx), @truncate(y & 15), @intCast(lz)));
        const bc_old = chunk_mod.Chunk.blockCost(op_old);
        const bc_new = chunk_mod.Chunk.blockCost(op_new);
        const brose = costRose(bc_new, bc_old);
        const bdrop = costRose(bc_old, bc_new);
        if (best != cur) {
            chunk_mod.Section.setNibble(&sec.light, chunk_mod.Section.index(@intCast(lx), @truncate(y & 15), @intCast(lz)), best);
        }
        if (brose) {
            // Cost rose: maximal invalidation (value-preserving opacity
            // gains strand dependents invisibly — see sky path). Rewrite
            // restores the recomputed floor; reflood settles the rest.
            const old = [_]chunk_mod.Chunk.CellValue{.{ .cell = cell, .value = 15 }};
            const rw = [_]chunk_mod.Chunk.CellValue{.{ .cell = cell, .value = best }};
            ch.unspreadLight(q, .block, &old, &rw);
        } else if (best > cur) {
            const one = [_]u32{cell};
            ch.spreadLight(q, .block, &one);
        } else if (best < cur) {
            const old = [_]chunk_mod.Chunk.CellValue{.{ .cell = cell, .value = cur }};
            const rw = [_]chunk_mod.Chunk.CellValue{.{ .cell = cell, .value = best }};
            ch.unspreadLight(q, .block, &old, &rw);
        } else if (bdrop) {
            // Same value, cheaper paths: raise from the cell (explores
            // only strict increases — a handful of ops when idle).
            const one = [_]u32{cell};
            ch.spreadLight(q, .block, &one);
        }
    }
    // (No emission/opacity change: nothing to do. Column sky above already
    // handled the vertical; sideways flow is unchanged.)
}
