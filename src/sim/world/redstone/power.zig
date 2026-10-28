//! Redstone power model and world mutation (incl. piston actuation).

const ids = @import("../../../ids.zig");
const world_view = @import("../world_view.zig");
const block_mod = @import("../../../game/block.zig");
const rules_mod = @import("../../../game/rules.zig");
const common = @import("common.zig");
const components = @import("components.zig");
const schedule = @import("schedule.zig");

const Block = world_view.Block;
const at = common.at;
const dirs6 = common.dirs6;
const buttonOn = components.buttonOn;
const doorIsUpper = components.doorIsUpper;
const doorOpen = components.doorOpen;
const facingVec = components.facingVec;
const gateOpen = components.gateOpen;
const isButton = components.isButton;
const isDoor = components.isDoor;
const isLamp = components.isLamp;
const isLever = components.isLever;
const isPiston = components.isPiston;
const isPistonHead = components.isPistonHead;
const isPlate = components.isPlate;
const isRepeater = components.isRepeater;
const isTorch = components.isTorch;
const isTrapdoor = components.isTrapdoor;
const isWire = components.isWire;
const lampLit = components.lampLit;
const leverAnchor = components.leverAnchor;
const leverOn = components.leverOn;
const mountSupport = components.mountSupport;
const normalCube = components.normalCube;
const pistonExtended = components.pistonExtended;
const pistonFacing = components.pistonFacing;
const pistonVec = components.pistonVec;
const plateAnchor = components.plateAnchor;
const plateLevel = components.plateLevel;
const rep_in_side = components.rep_in_side;
const rep_out_side = components.rep_out_side;
const repeaterDelay = components.repeaterDelay;
const repeaterFacing = components.repeaterFacing;
const repeaterOn = components.repeaterOn;
const solidTop = components.solidTop;
const torchAnchor = components.torchAnchor;
const torchCheckSide = components.torchCheckSide;
const torchOn = components.torchOn;
const torchSupportPos = components.torchSupportPos;
const trapOpen = components.trapOpen;
const trapdoorSupport = components.trapdoorSupport;
const BurnoutMap = schedule.BurnoutMap;
const Change = schedule.Change;
const ChangeList = schedule.ChangeList;
const Scheduler = schedule.Scheduler;
const SoundList = schedule.SoundList;
const max_updates_per_edit = schedule.max_updates_per_edit;

/// `app.a(ahb,IIII)Z` (isIndirectlyPowered): weak power from the five faces
/// other than the front. Vanilla queries `isBlockProvidingPowerTo` (weak,
/// direct) — a block in front never powers its own piston.
pub fn pistonPowered(world: anytype, x: i32, y: i32, z: i32, facing: u3) bool {
    for (dirs6) |d| {
        if (d.side == facing) continue;
        if (weakAt(world, x + d.dx, y + d.dy, z + d.dz, d.side, true) > 0) return true;
    }
    return false;
}

/// Material mobility (`awt.i()`-style DESTROY set; `aji.h:()I`).
pub fn pistonMobility(blocks: *const block_mod.Table, id: ids.Id) block_mod.PistonMobility {
    return blocks.get(id).piston_mobility;
}

/// Unbreakable blocks (`aji.f(ahb,III)F == -1`): canPush rejects these.
fn pistonUnbreakable(blocks: *const block_mod.Table, id: ids.Id) bool {
    return blocks.get(id).piston_unbreakable;
}

/// Container blocks (`akw`, instanceof check in canPush): pistons never move
/// tile-entity blocks.
fn pistonContainer(blocks: *const block_mod.Table, id: ids.Id) bool {
    return blocks.get(id).piston_container;
}

/// `app.a(aji,ahb,III,Z)` (canPush), exact:
///   obsidian -> false; piston/sticky extended -> false (skips hardness);
///   hardness -1 -> false; mobility 2 -> false; mobility 1 needs destroy;
///   container blocks -> false.
pub fn pistonCanPush(world: anytype, x: i32, y: i32, z: i32, destroy: bool) bool {
    const b = at(world, x, y, z);
    if (isPiston(world.blocks, b)) {
        if (pistonExtended(b.meta)) return false;
        return true; // pistons are plain blocks (not containers)
    }
    if (pistonUnbreakable(world.blocks, b.id)) return false;
    const m = pistonMobility(world.blocks, b.id);
    if (m == .immovable) return false;
    if (m == .destroy and !destroy) return false;
    if (m != .destroy and pistonContainer(world.blocks, b.id)) return false;
    return true;
}

/// `app.h(ahb,IIII)Z` (canExtend): dry scan of the push line. Breakable
/// (destroy-mobility) blocks end the chain just like air; the profile push
/// limit applies; world-height bounds fail.
pub fn pistonCanExtend(world: anytype, x: i32, y: i32, z: i32, facing: u3) bool {
    const v = pistonVec(facing);
    const limit: usize = world.rules.piston_push_limit;
    var cx = x + v.dx;
    var cy = y + v.dy;
    var cz = z + v.dz;
    var count: usize = 0;
    while (count <= limit) : (count += 1) {
        if (cy <= 0 or cy >= 255) return false;
        const b = at(world, cx, cy, cz);
        if (b.id == ids.air) return true;
        if (!pistonCanPush(world, cx, cy, cz, true)) return false;
        if (pistonMobility(world.blocks, b.id) == .destroy) return true;
        if (count == limit) return false;
        cx += v.dx;
        cy += v.dy;
        cz += v.dz;
    }
    return true;
}

/// `app.a(ahb,IIILsv)I` (getPistonOrientation): close player + eye above ->
/// down(0)/up(1); else the yaw table: index 0->2(north), 1->5(east),
/// 2->3(south), 3->4(west). Piston faces TOWARD the player.
pub fn pistonPlacementFacing(px: f64, py: f64, pz: f64, yaw: f32, x: i32, y: i32, z: i32) u4 {
    // |player.posX - x| < 2.0 && |player.posZ - z| < 2.0 (floats in the jar).
    const dx = px - @as(f64, @floatFromInt(x));
    const dz = pz - @as(f64, @floatFromInt(z));
    if (@abs(dx) < 2.0 and @abs(dz) < 2.0) {
        // sv.t (posY) + 1.82 - sv.L (yOffset 1.62) = feet + 0.2 (eye).
        const eye = py + 0.2;
        if (eye - @as(f64, @floatFromInt(y)) > 2.0) return 1;
        return 0;
    }
    const idx: i32 = @mod(@as(i32, @intFromFloat(@floor(@as(f64, yaw) * 4.0 / 360.0 + 0.5))), 4);
    return switch (idx) {
        0 => 2,
        1 => 5,
        2 => 3,
        3 => 4,
        else => 0,
    };
}

/// Extend move (`app.i`): scan (destroyables drop + vacate + end the chain),
/// then shift every block one step along facing, cap 12, head at the front
/// cell. Writes are `silent` (the S24 block action animates the client).
/// Returns false when the line cannot extend (piston stays retracted).
pub fn pistonExtend(world: anytype, x: i32, y: i32, z: i32, facing: u3, changes: *ChangeList, sounds: *SoundList) bool {
    const v = pistonVec(facing);
    const sticky = world.blocks.get(at(world, x, y, z).id).redstone_kind == .piston_sticky;
    const limit: usize = world.rules.piston_push_limit;
    var cx = x + v.dx;
    var cy = y + v.dy;
    var cz = z + v.dz;
    var count: usize = 0;
    while (count <= limit) : (count += 1) {
        if (cy <= 0 or cy >= 255) return false;
        const b = at(world, cx, cy, cz);
        if (b.id == ids.air) break;
        if (!pistonCanPush(world, cx, cy, cz, true)) return false;
        if (pistonMobility(world.blocks, b.id) == .destroy) {
            // Destroy on push (`app.i` bytes 100-146): dropBlockAsItem +
            // setToAir, then the chain ends at the vacated cell.
            changes.append(.{ .x = cx, .y = cy, .z = cz, .id = ids.air, .meta = 0, .old_id = b.id, .old_meta = b.meta, .popped = true, .silent = true });
            world.set(cx, cy, cz, ids.air, 0);
            break;
        }
        if (count == limit) return false;
        cx += v.dx;
        cy += v.dy;
        cz += v.dz;
    }
    // Walk the chain back toward the piston (`app.i` bytes 209-447): each
    // block moves one step along facing; the head lands on the cell in
    // front of the base; every vacated cell clears.
    var fx = cx;
    var fy = cy;
    var fz = cz;
    while (fx != x or fy != y or fz != z) {
        const sx = fx - v.dx;
        const sy = fy - v.dy;
        const sz = fz - v.dz;
        if (sx == x and sy == y and sz == z) {
            // `apq` head, meta = facing | sticky-bit (`app.i` bytes 348-381).
            const head_meta: u4 = @as(u4, facing) | (if (sticky) @as(u4, 8) else 0);
            const hd_old = at(world, fx, fy, fz);
            world.set(fx, fy, fz, world.rules.piston_head, head_meta);
            changes.append(.{ .x = fx, .y = fy, .z = fz, .id = world.rules.piston_head, .meta = head_meta, .old_id = hd_old.id, .old_meta = hd_old.meta, .silent = true });
        } else {
            const src = at(world, sx, sy, sz);
            const dst_old = at(world, fx, fy, fz);
            world.set(fx, fy, fz, src.id, src.meta);
            changes.append(.{ .x = fx, .y = fy, .z = fz, .id = src.id, .meta = src.meta, .old_id = dst_old.id, .old_meta = dst_old.meta, .silent = true });
        }
        fx = sx;
        fy = sy;
        fz = sz;
        if (fx != x or fy != y or fz != z) {
            // Vacate the source cell (the next iteration refills it unless
            // it is the piston base position).
            const vac = at(world, fx, fy, fz);
            world.set(fx, fy, fz, ids.air, 0);
            changes.append(.{ .x = fx, .y = fy, .z = fz, .id = ids.air, .meta = 0, .old_id = vac.id, .old_meta = vac.meta, .silent = true });
        }
    }
    // Base goes extended (`app.a(ahb,IIIIII)` bytes 79-93).
    const base = at(world, x, y, z);
    world.set(x, y, z, base.id, @as(u4, facing) | 8);
    changes.append(.{ .x = x, .y = y, .z = z, .id = base.id, .meta = @as(u4, facing) | 8, .old_id = base.id, .old_meta = base.meta, .silent = true });
    sounds.append(.{ .kind = .piston_out, .x = x, .y = y, .z = z });
    return true;
}

/// Retract move (`app.a(ahb,IIIIII)` eventId 1): the head cell clears — or,
/// when sticky and the block two ahead is pullable (`canPush` with
/// destroy=false), it lands in the head cell — and the base un-extends.
pub fn pistonRetract(world: anytype, x: i32, y: i32, z: i32, facing: u3, changes: *ChangeList, sounds: *SoundList) void {
    const v = pistonVec(facing);
    const base = at(world, x, y, z);
    const sticky = world.blocks.get(base.id).redstone_kind == .piston_sticky;
    const hx = x + v.dx;
    const hy = y + v.dy;
    const hz = z + v.dz;
    const head = at(world, hx, hy, hz);
    const px = hx + v.dx;
    const py = hy + v.dy;
    const pz = hz + v.dz;
    const pull_src = at(world, px, py, pz);
    if (sticky and pull_src.id != ids.air and pistonCanPush(world, px, py, pz, false)) {
        // Sticky pull: block two ahead animates into the head cell; its old
        // cell clears (`app.a` bytes 376-538).
        world.set(hx, hy, hz, pull_src.id, pull_src.meta);
        changes.append(.{ .x = hx, .y = hy, .z = hz, .id = pull_src.id, .meta = pull_src.meta, .old_id = head.id, .old_meta = head.meta, .silent = true });
        world.set(px, py, pz, ids.air, 0);
        changes.append(.{ .x = px, .y = py, .z = pz, .id = ids.air, .meta = 0, .old_id = pull_src.id, .old_meta = pull_src.meta, .silent = true });
    } else {
        // Non-sticky (or unpullable): the head cell clears (bytes 542-571).
        world.set(hx, hy, hz, ids.air, 0);
        changes.append(.{ .x = hx, .y = hy, .z = hz, .id = ids.air, .meta = 0, .old_id = head.id, .old_meta = head.meta, .silent = true });
    }
    world.set(x, y, z, base.id, @as(u4, facing));
    changes.append(.{ .x = x, .y = y, .z = z, .id = base.id, .meta = @as(u4, facing), .old_id = base.id, .old_meta = base.meta, .silent = true });
    sounds.append(.{ .kind = .piston_in, .x = x, .y = y, .z = z });
}

// ---------------------------------------------------------------------------
// vanilla power model (`aji.b/c`, `ahb.e/f/g/u/v`)
// ---------------------------------------------------------------------------
//
// `side` is always the touching face ON THE REQUESTER, vanilla face indices:
// 0 down, 1 up, 2 north(-z), 3 south(+z), 4 west(-x), 5 east(+x). A block
// below a source queries with side 1 (its top face).

/// Direction (src - requester) to requesting face: down→1, up→0,
/// north→3, south→2, west→5, east→4.
pub fn reqSide(dx: i32, dy: i32, dz: i32) u3 {
    if (dy < 0) return 1;
    if (dy > 0) return 0;
    if (dz < 0) return 3;
    if (dz > 0) return 2;
    if (dx < 0) return 5;
    return 4;
}

/// Blocks that emit redstone power for connection purposes (`aji.f`,
/// canProvidePower). Doors count only while open; trapped chests and
/// daylight sensors are live sources too.
pub fn canProvidePower(blocks: *const block_mod.Table, b: Block) bool {
    const k = blocks.get(b.id).redstone_kind;
    if (k == .lever) return leverOn(blocks, b);
    if (k == .button_stone or k == .button_wood) return buttonOn(blocks, b);
    if (k == .plate_stone or k == .plate_wood or k == .plate_light or k == .plate_heavy) {
        return plateLevel(blocks, b) > 0;
    }
    if (k == .torch_on) return true;
    if (k == .repeater_on) return true;
    if (k == .door_wood or k == .door_iron) return doorOpen(b.meta);
    return blocks.get(b.id).always_power_source;
}

/// Diode facing-axis match for wire connection (`ana.f`: side==facing or
/// side==opposite). Sides are candidate labels: 1 = west, 3 = east,
/// 2 = north, 0 = south. A diode connects along its own axis.
fn diodeAxisMatch(side: i32, facing: u2) bool {
    const ew_face = facing == 1 or facing == 3;
    if (side == 1 or side == 3) return ew_face;
    if (side == 0 or side == 2) return !ew_face;
    return false;
}

/// Wire→candidate connection (`ana.f` canConnectTo): wire always, diode by
/// facing axis, other blocks iff they provide power. Side -1 (diagonals)
/// connects wire only.
fn connectsTo(world: anytype, x: i32, y: i32, z: i32, side: i32) bool {
    const b = at(world, x, y, z);
    if (isWire(world.blocks, b)) return true;
    if (isRepeater(world.blocks, b)) {
        if (side < 0) return false;
        return diodeAxisMatch(side, repeaterFacing(b.meta));
    }
    if (side < 0) return false;
    return canProvidePower(world.blocks, b);
}

/// One horizontal wire-connection rule (`ana.b` var7-10): direct connect,
/// non-cube with a wire diagonally below, or cube with a wire above.
fn wireConn(world: anytype, bl: *const block_mod.Table, x: i32, y: i32, z: i32, dx: i32, dz: i32, side: i32) bool {
    const c = at(world, x + dx, y, z + dz);
    return connectsTo(world, x + dx, y, z + dz, side) or
        (!normalCube(bl, c.id) and isWire(bl, at(world, x + dx, y - 1, z + dz))) or
        (normalCube(bl, c.id) and isWire(bl, at(world, x + dx, y + 1, z + dz)));
}

/// Wire connection flags in the four horizontal directions, with vanilla
/// down-steps and up-steps (`ana.b` var7-10): direct connect, non-cube
/// with a wire diagonally below, or cube with a wire diagonally above.
fn wireConns(world: anytype, x: i32, y: i32, z: i32) struct { w: bool, e: bool, n: bool, s: bool } {
    const bl = world.blocks;
    return .{
        .w = wireConn(world, bl, x, y, z, -1, 0, 1),
        .e = wireConn(world, bl, x, y, z, 1, 0, 3),
        .n = wireConn(world, bl, x, y, z, 0, -1, 2),
        .s = wireConn(world, bl, x, y, z, 0, 1, 0),
    };
}

/// Weak power a block offers toward a requesting face (`aji.b` per type).
/// Wire output is connection-gated per `ana.b` (down always, dot wires
/// everywhere, otherwise direction && !perpendiculars).
pub fn weakAt(world: anytype, x: i32, y: i32, z: i32, side: u3, live: bool) u4 {
    const bl = world.blocks;
    const rs = world.rules;
    const b = at(world, x, y, z);
    const k = bl.get(b.id).redstone_kind;
    if (k == .wire) {
        if (!live) return 0;
        const meta = b.meta;
        if (meta == 0) return 0;
        if (side == 1) return meta;
        const c = wireConns(world, x, y, z);
        if (!c.n and !c.e and !c.w and !c.s) {
            if (side >= 2 and side <= 5) return meta;
            return 0;
        }
        return switch (side) {
            2 => if (c.n and !c.w and !c.e) meta else 0,
            3 => if (c.s and !c.w and !c.e) meta else 0,
            4 => if (c.w and !c.n and !c.s) meta else 0,
            5 => if (c.e and !c.n and !c.s) meta else 0,
            else => 0,
        };
    }
    if (k == .torch_on) {
        // anc.b: no power toward the facing direction (5→down? no: toward
        // the mount's opposite — the exact skip table).
        const m = b.meta & 7;
        const skip: ?u3 = switch (m) {
            5 => 1,
            3 => 3,
            4 => 2,
            1 => 5,
            2 => 4,
            else => null,
        };
        if (skip != null and skip.? == side) return 0;
        return 15;
    }
    if (k == .torch_off) return 0;
    if (k == .lever) return if (leverOn(bl, b)) 15 else 0;
    if (k == .button_stone or k == .button_wood) return if (buttonOn(bl, b)) 15 else 0;
    if (k == .plate_stone or k == .plate_wood or k == .plate_light or k == .plate_heavy) {
        return plateLevel(bl, b);
    }
    if (b.id == rs.redstone_block) return 15;
    if (k == .repeater_on) {
        const out = rep_out_side[repeaterFacing(b.meta)];
        return if (side == out) 15 else 0;
    }
    return 0;
}

/// Strong power (`aji.c` per type). Only the torch-down rule and the
/// lever/button mount rule differ from weak; plates are strong upward.
pub fn strongAt(world: anytype, x: i32, y: i32, z: i32, side: u3, live: bool) u4 {
    const bl = world.blocks;
    const rs = world.rules;
    const b = at(world, x, y, z);
    const k = bl.get(b.id).redstone_kind;
    if (k == .wire) return weakAt(world, x, y, z, side, live);
    if (k == .torch_on or k == .torch_off) {
        if (k == .torch_off) return 0;
        return if (side == 0) weakAt(world, x, y, z, side, live) else 0;
    }
    if (k == .lever or k == .button_stone or k == .button_wood) {
        const on = if (k == .lever) leverOn(bl, b) else buttonOn(bl, b);
        if (!on) return 0;
        const want: u3 = switch (b.meta & 7) {
            0 => 0,
            1 => 5,
            2 => 4,
            3 => 3,
            4 => 2,
            5, 6 => 1,
            else => 0,
        };
        return if (side == want) 15 else 0;
    }
    if (k == .plate_stone or k == .plate_wood or k == .plate_light or k == .plate_heavy) {
        return if (side == 1) plateLevel(bl, b) else 0;
    }
    if (k == .repeater_on or k == .repeater_off) return weakAt(world, x, y, z, side, live);
    if (b.id == rs.redstone_block) return 0; // ams: no strong override
    return 0;
}

/// Indirect power (`ahb.g`): normal cubes conduct the strongest neighbor
/// power; everything else offers its own weak output.
pub fn indirectAt(world: anytype, x: i32, y: i32, z: i32, side: u3, live: bool) u4 {
    if (normalCube(world.blocks, at(world, x, y, z).id)) return strongestAt(world, x, y, z, live);
    return weakAt(world, x, y, z, side, live);
}

/// Strongest indirect power (`ahb.u`): max weak output over the 6 neighbors.
pub fn strongestAt(world: anytype, x: i32, y: i32, z: i32, live: bool) u4 {
    var best: u4 = 0;
    for (dirs6) |d| {
        best = @max(best, weakAt(world, x + d.dx, y + d.dy, z + d.dz, d.side, live));
    }
    return best;
}

/// Max indirect power over the 6 neighbors (shared by gettingPowered and
/// the wire level's indirect term).
fn maxIndirect(world: anytype, x: i32, y: i32, z: i32, live: bool) u4 {
    var ind: u4 = 0;
    for (dirs6) |d| {
        ind = @max(ind, indirectAt(world, x + d.dx, y + d.dy, z + d.dz, d.side, live));
    }
    return ind;
}

/// Block receiving power from any neighbor (`ahb.v`, used by lamps/doors).
pub fn gettingPowered(world: anytype, x: i32, y: i32, z: i32) bool {
    return maxIndirect(world, x, y, z, true) > 0;
}

/// Wire level (`ana.calculateCurrentChanges`, exact): stored meta, indirect
/// non-wire sources (wires dead, like `wiresProvidePower=false`), linked-wire
/// max minus one, indirect restore. Converges to the same steady state the
/// vanilla multi-tick settle reaches.
/// Max linked-wire level around (x,y,z): same-level neighbors plus the
/// step-up link (cube beside, open above self, wire above the cube) and
/// the step-down link (non-cube beside, wire below it).
fn linkedWireMax(world: anytype, bl: *const block_mod.Table, x: i32, y: i32, z: i32) i64 {
    var loopBest: i64 = 0;
    for (dirs6) |d| {
        if (d.dy != 0) continue;
        const nb = at(world, x + d.dx, y, z + d.dz);
        if (isWire(bl, nb)) loopBest = @max(loopBest, @as(i64, nb.meta));
        if (normalCube(bl, nb.id) and !normalCube(bl, at(world, x, y + 1, z).id)) {
            const up = at(world, x + d.dx, y + 1, z + d.dz);
            if (isWire(bl, up)) loopBest = @max(loopBest, @as(i64, up.meta));
        }
        if (!normalCube(bl, nb.id)) {
            const dn = at(world, x + d.dx, y - 1, z + d.dz);
            if (isWire(bl, dn)) loopBest = @max(loopBest, @as(i64, dn.meta));
        }
    }
    return loopBest;
}

pub fn computeWire(world: anytype, x: i32, y: i32, z: i32) u4 {
    const cur: i64 = at(world, x, y, z).meta;
    var best: i64 = cur;
    const ind = maxIndirect(world, x, y, z, false);
    if (ind > 0 and @as(i64, ind) >= best) best = ind;
    const loopBest = linkedWireMax(world, world.blocks, x, y, z);
    if (loopBest > best) {
        best = loopBest - 1;
    } else if (best > 0) {
        best -= 1;
    }
    if (ind > 0 and @as(i64, ind) >= best) best = ind;
    return @truncate(@as(u64, @bitCast(best)));
}

/// Diode input (`akj.h` + wire max): indirect power of the behind cell plus
/// the wire level when the input cell itself is wire. `p.d` = {3,4,2,5}.
pub fn repeaterInputPowered(world: anytype, x: i32, y: i32, z: i32, meta: u4) bool {
    const f = repeaterFacing(meta);
    const v = facingVec(f);
    const ix = x - v.dx;
    const iz = z - v.dz;
    const in_side: u3 = rep_in_side[f];
    if (isWire(world.blocks, at(world, ix, y, iz))) {
        return at(world, ix, y, iz).meta > 0;
    }
    return indirectAt(world, ix, y, iz, in_side, true) > 0;
}

/// Diode side-lock (`akj.i`): a powered diode on either perpendicular
/// neighbor facing into this cell locks it.
pub fn repeaterLocked(world: anytype, x: i32, y: i32, z: i32, meta: u4) bool {
    const f = repeaterFacing(meta);
    const v = facingVec(f);
    // perpendicular offsets: left/right of the output direction
    const perps = [_]struct { dx: i32, dz: i32 }{
        .{ .dx = v.dz, .dz = -v.dx },
        .{ .dx = -v.dz, .dz = v.dx },
    };
    for (perps) |p| {
        const nb = at(world, x + p.dx, y, z + p.dz);
        if (!isRepeater(world.blocks, nb) or !repeaterOn(world.blocks, nb)) continue;
        const nv = facingVec(repeaterFacing(nb.meta));
        // neighbor output points back at us?
        if (x + p.dx + nv.dx == x and z + p.dz + nv.dz == z) return true;
    }
    return false;
}

/// Torch power check (`anc.m`): ONLY the support block, queried with the
/// mount side (5→0, 3→2, 4→3, 1→4, 2→5). Other metas never power off.
pub fn torchShouldBeOff(world: anytype, x: i32, y: i32, z: i32, meta: u4) bool {
    const s = torchCheckSide(meta) orelse return false;
    const sp = torchSupportPos(x, y, z, meta);
    return indirectAt(world, sp.x, sp.y, sp.z, s, true) > 0;
}

// ---------------------------------------------------------------------------
// staged writes (one final store write + broadcast per cell)
// ---------------------------------------------------------------------------
//
// Redstone converges stepwise: a lever OFF decays wires one level per
// recompute, re-enqueueing neighbors (vanilla does the same multi-round
// settle, but in memory inside one tick). Writing every intermediate to the
// chunk store costs ~7ms per edit, so a 30-cell OFF cascade took ~200ms+ of
// pure store traffic and flickered clients through every level. The stage
// intercepts get/set for one whole operation (interact/onEdit/drain/poll):
// reads see pending values, writes coalesce to the last value per cell, and
// commit() emits ONE change per touched cell (original -> final).

pub const stage_cap: usize = 512;

const StageCell = struct {
    x: i32,
    y: i32,
    z: i32,
    id: ids.Id,
    meta: u4,
    orig_id: ids.Id,
    orig_meta: u4,
    popped: bool,
    silent: bool,
};

pub fn Staged(comptime Inner: type) type {
    return struct {
        const Self = @This();
        inner: Inner,
        rules: *const rules_mod.RedstoneRules,
        blocks: *const block_mod.Table,
        cells: [stage_cap]StageCell = undefined,
        n: usize = 0,

        pub fn init(inner: Inner) Self {
            return .{ .inner = inner, .rules = inner.rules, .blocks = inner.blocks };
        }

        fn slot(self: *Self, x: i32, y: i32, z: i32) ?*StageCell {
            for (self.cells[0..self.n]) |*c| {
                if (c.x == x and c.y == y and c.z == z) return c;
            }
            return null;
        }

        fn capture(self: *Self, x: i32, y: i32, z: i32, id: ids.Id, meta: u4, popped: bool, silent: bool) void {
            if (self.slot(x, y, z)) |c| {
                c.id = id;
                c.meta = meta;
                c.popped = c.popped or popped;
                c.silent = c.silent and silent;
                return;
            }
            if (self.n >= self.cells.len) {
                // Overflow: write through (correct, just unbatched).
                self.inner.set(x, y, z, id, meta);
                return;
            }
            const orig_blk = self.inner.get(x, y, z) orelse Block{ .id = ids.air, .meta = 0 };
            self.cells[self.n] = .{
                .x = x,
                .y = y,
                .z = z,
                .id = id,
                .meta = meta,
                .orig_id = orig_blk.id,
                .orig_meta = orig_blk.meta,
                .popped = popped,
                .silent = silent,
            };
            self.n += 1;
        }

        pub fn get(self: *Self, x: i32, y: i32, z: i32) ?Block {
            if (self.slot(x, y, z)) |c| {
                return .{ .id = c.id, .meta = c.meta };
            }
            // Read memoization: the BFS re-reads the same neighbors dozens of
            // times per cascade (wire decay ping-pong ~600 reads); every one
            // was a full chunk-store read. First read creates a no-op entry
            // (commit skips unchanged cells), later reads hit the memo. The
            // inner world cannot change under the stage: one op owns the
            // world lock start to finish.
            if (self.n >= self.cells.len) return self.inner.get(x, y, z);
            const orig_blk = self.inner.get(x, y, z) orelse Block{ .id = ids.air, .meta = 0 };
            self.cells[self.n] = .{
                .x = x,
                .y = y,
                .z = z,
                .id = orig_blk.id,
                .meta = orig_blk.meta,
                .orig_id = orig_blk.id,
                .orig_meta = orig_blk.meta,
                .popped = false,
                .silent = false,
            };
            self.n += 1;
            return orig_blk;
        }

        pub fn set(self: *Self, x: i32, y: i32, z: i32, id: ids.Id, meta: u4) void {
            self.capture(x, y, z, id, meta, false, false);
        }

        pub fn pop(self: *Self, x: i32, y: i32, z: i32, old_id: ids.Id, old_meta: u4) void {
            _ = old_id;
            _ = old_meta;
            self.capture(x, y, z, ids.air, 0, true, false);
        }

        /// Push every final value through, recording one change per cell.
        pub fn commit(self: *Self, changes: *ChangeList) void {
            for (self.cells[0..self.n]) |*c| {
                if (!c.popped and c.id == c.orig_id and c.meta == c.orig_meta) continue;
                self.inner.set(c.x, c.y, c.z, c.id, c.meta);
                changes.append(.{
                    .x = c.x,
                    .y = c.y,
                    .z = c.z,
                    .id = c.id,
                    .meta = c.meta,
                    .old_id = c.orig_id,
                    .old_meta = c.orig_meta,
                    .popped = c.popped,
                    .silent = c.silent,
                });
            }
            self.n = 0;
        }
    };
}

// ---------------------------------------------------------------------------
// recompute + neighbor fan-out
// ---------------------------------------------------------------------------

/// Blocks that can change via recompute (and so deserve fan-out). Air and
/// inert solids never change spontaneously; trapdoors/gates are hand-only
/// (no support pop in K1 — documented) and ore fades via scheduler.
pub fn needsRecompute(blocks: *const block_mod.Table, id: ids.Id) bool {
    return blocks.get(id).redstone_component;
}

const QPos = struct { x: i32, y: i32, z: i32 };

fn tryEnqueue(world: anytype, q: []QPos, tail: *usize, x: i32, y: i32, z: i32) void {
    if (tail.* >= q.len) return;
    if (y < 0 or y > 255) return;
    if (!needsRecompute(world.blocks, at(world, x, y, z).id)) return;
    q[tail.*] = .{ .x = x, .y = y, .z = z };
    tail.* += 1;
}

/// Recompute one position. Returns a Change when the block flips
/// immediately; repeater mismatches schedule a delayed eval instead.
/// Build a Change record for (x,y,z): new id/meta + popped flag.
fn mkChange(x0: i32, y0: i32, z0: i32, old: Block, nid: ids.Id, nmeta: u4, pop: bool) Change {
    return .{ .x = x0, .y = y0, .z = z0, .id = nid, .meta = nmeta, .old_id = old.id, .old_meta = old.meta, .popped = pop };
}

/// Pending BFS ring for notify (well above processed*fanout so the tail
/// cap never clips a cascade the processed budget would have allowed).
pub const notify_queue: usize = 4096;

/// Support-loss pops return a Change with popped=true (air).
/// Needs `sched` (repeater delay), `burn` (torch lockout), `sounds` (fizz).

pub fn recompute(
    world: anytype,
    sched: *Scheduler,
    burn: *BurnoutMap,
    sounds: *SoundList,
    x: i32,
    y: i32,
    z: i32,
    now: i64,
) ?Change {
    const bl = world.blocks;
    const b = at(world, x, y, z);
    if (isWire(bl, b)) return recomputeWire(world, x, y, z, b);
    if (isTorch(bl, b)) return recomputeTorch(world, burn, sounds, world.rules, x, y, z, b, now);
    if (isLever(bl, b)) {
        if (!leverAnchor(world, x, y, z, b.meta)) return mkChange(x, y, z, b, ids.air, 0, true);
        return null;
    }
    if (isButton(bl, b)) {
        const sp = torchSupportPos(x, y, z, b.meta & 7);
        if (!normalCube(bl, at(world, sp.x, sp.y, sp.z).id)) return mkChange(x, y, z, b, ids.air, 0, true);
        return null;
    }
    if (isPlate(bl, b)) {
        if (!plateAnchor(world, x, y, z)) return mkChange(x, y, z, b, ids.air, 0, true);
        return null; // plates poll; never recompute from neighbors
    }
    if (isRepeater(bl, b)) return recomputeRepeater(world, sched, x, y, z, b, now);
    if (isPiston(bl, b)) return recomputePiston(world, sched, x, y, z, b, now);
    if (isPistonHead(bl, b)) {
        // `apq.a(ahb,III,aji)`: the head survives only while an EXTENDED
        // piston base sits behind it; otherwise it pops (no drop).
        const v = pistonVec(pistonFacing(b.meta));
        const base = at(world, x - v.dx, y - v.dy, z - v.dz);
        if (isPiston(bl, base) and pistonExtended(base.meta)) return null;
        return mkChange(x, y, z, b, ids.air, 0, true);
    }
    if (isLamp(bl, b)) return recomputeLamp(world, world.rules, x, y, z, b);
    if (isDoor(bl, b)) return recomputeDoor(world, x, y, z, b);
    if (isTrapdoor(bl, b)) {
        const sp = trapdoorSupport(x, y, z, b.meta);
        if (!normalCube(bl, at(world, sp.x, sp.y, sp.z).id)) return mkChange(x, y, z, b, ids.air, 0, true);
        return null;
    }
    return null;
}

fn recomputeWire(world: anytype, x: i32, y: i32, z: i32, b: Block) ?Change {
    const bl = world.blocks;
    const below = at(world, x, y - 1, z).id;
    if (y <= 0 or !solidTop(bl, below)) return mkChange(x, y, z, b, ids.air, 0, true);
    const p = computeWire(world, x, y, z);
    if (p != b.meta) return mkChange(x, y, z, b, b.id, p, false);
    return null;
}

fn recomputeTorch(world: anytype, burn: *BurnoutMap, sounds: *SoundList, rs: *const rules_mod.RedstoneRules, x: i32, y: i32, z: i32, b: Block, now: i64) ?Change {
    if (!torchAnchor(world, x, y, z, b.meta)) return mkChange(x, y, z, b, ids.air, 0, true);
    const on = torchOn(world.blocks, b);
    const off = torchShouldBeOff(world, x, y, z, b.meta);
    if (on == !off) return null; // already matches power state
    if (!on or !off) {
        // OFF→ON flip, unless burnt out (burnt torches wake on the next
        // neighbor notify after entries age out — vanilla has no recheck).
        if (burn.isBurnt(x, y, z, now, rs)) return null;
        return mkChange(x, y, z, b, rs.torch_on, b.meta, false);
    }
    // ON→OFF flip: record (vanilla only counts power-offs) and burn
    // out with fizz when 8 land inside 60 ticks.
    if (burn.noteFlip(x, y, z, now, rs)) {
        sounds.append(.{ .kind = .fizz, .x = x, .y = y, .z = z });
    }
    return mkChange(x, y, z, b, rs.torch_off, b.meta, false);
}

fn recomputeRepeater(world: anytype, sched: *Scheduler, x: i32, y: i32, z: i32, b: Block, now: i64) ?Change {
    const bl = world.blocks;
    if (!solidTop(bl, at(world, x, y - 1, z).id)) return mkChange(x, y, z, b, ids.air, 0, true);
    if (repeaterLocked(world, x, y, z, b.meta)) return null;
    const in_pow = repeaterInputPowered(world, x, y, z, b.meta);
    if (in_pow != repeaterOn(bl, b) and !sched.pendingAt(x, y, z)) {
        sched.schedule(x, y, z, now + repeaterDelay(world.rules, b.meta), .repeater_eval);
    }
    return null;
}

fn recomputePiston(world: anytype, sched: *Scheduler, x: i32, y: i32, z: i32, b: Block, now: i64) ?Change {
    // `app.e` updatePistonState: fire a block event when the indirect
    // power on the five non-front faces disagrees with the extended bit.
    const facing = pistonFacing(b.meta);
    const powered = pistonPowered(world, x, y, z, facing);
    if (powered != pistonExtended(b.meta) and !sched.pendingAt(x, y, z)) {
        sched.schedule(x, y, z, now + 2, if (powered) .piston_extend else .piston_retract);
    }
    return null;
}

fn recomputeLamp(world: anytype, rs: *const rules_mod.RedstoneRules, x: i32, y: i32, z: i32, b: Block) ?Change {
    // anb: lit && !gettingPowered → unlit; !lit && gettingPowered → lit.
    const want_lit = gettingPowered(world, x, y, z);
    if (want_lit == lampLit(world.blocks, b)) return null;
    return mkChange(x, y, z, b, if (want_lit) rs.lamp_on else rs.lamp_off, 0, false);
}

fn recomputeDoor(world: anytype, x: i32, y: i32, z: i32, b: Block) ?Change {
    if (doorIsUpper(b.meta)) return null; // upper half follows the lower
    if (!solidTop(world.blocks, at(world, x, y - 1, z).id)) return mkChange(x, y, z, b, ids.air, 0, true);
    // akn: powered = gettingPowered(lower) || gettingPowered(upper).
    const want_open = gettingPowered(world, x, y, z) or gettingPowered(world, x, y + 1, z);
    if (want_open == doorOpen(b.meta)) return null;
    const nm: u4 = if (want_open) b.meta | 4 else b.meta & ~@as(u4, 4);
    return mkChange(x, y, z, b, b.id, nm, false);
}

/// Fan-out seed: the 6 neighbors plus the horizontal ring one above and
/// below (wire step-up/step-down links).
fn seedNotify(world: anytype, q: []QPos, tailp: *usize, px: i32, py: i32, pz: i32) void {
    for (dirs6) |d| tryEnqueue(world, q, tailp, px + d.dx, py + d.dy, pz + d.dz);
    for (dirs6) |d| {
        if (d.dy != 0) continue;
        tryEnqueue(world, q, tailp, px + d.dx, py + 1, pz + d.dz);
        tryEnqueue(world, q, tailp, px + d.dx, py - 1, pz + d.dz);
    }
}

/// Fan-out: recompute a position, apply + record, enqueue its neighbors.
/// Iterative BFS with a processed cap (storm protection).
pub fn notify(
    world: anytype,
    sched: *Scheduler,
    burn: *BurnoutMap,
    sounds: *SoundList,
    x: i32,
    y: i32,
    z: i32,
    now: i64,
) void {
    // Pending ring sized well above processed*fanout so the tail cap never
    // clips a cascade the processed budget would have allowed.
    var queue: [notify_queue]QPos = undefined;
    var head: usize = 0;
    var tail: usize = 0;
    var processed: usize = 0;

    seedNotify(world, &queue, &tail, x, y, z);

    while (head < tail and processed < max_updates_per_edit) {
        const p = queue[head];
        head += 1;
        processed += 1;
        const ch = recompute(world, sched, burn, sounds, p.x, p.y, p.z, now) orelse continue;
        if (ch.popped) {
            world.pop(p.x, p.y, p.z, ch.old_id, ch.old_meta);
        } else {
            world.set(p.x, p.y, p.z, ch.id, ch.meta);
        }
        seedNotify(world, &queue, &tail, p.x, p.y, p.z);
    }
    // Budget exhausted mid-cascade (huge decay networks): keep a wire-check
    // follow-up scheduled so convergence continues instead of stalling at an
    // intermediate level (vanilla keeps draining pending updates next tick).
    if (head < tail and !sched.pendingAt(queue[head].x, queue[head].y, queue[head].z)) {
        sched.schedule(queue[head].x, queue[head].y, queue[head].z, now + 2, .wire_check);
    }
}

/// Post-edit hook: recompute a freshly placed/broken cell itself, then fan
/// out to neighbors.
pub fn onEdit(
    world: anytype,
    sched: *Scheduler,
    burn: *BurnoutMap,
    changes: *ChangeList,
    sounds: *SoundList,
    x: i32,
    y: i32,
    z: i32,
    now: i64,
) void {
    var stage = Staged(@TypeOf(world)).init(world);
    const w = &stage;
    const b = at(w, x, y, z);
    if (needsRecompute(w.blocks, b.id)) {
        if (recompute(w, sched, burn, sounds, x, y, z, now)) |ch| {
            if (ch.popped) {
                w.pop(x, y, z, ch.old_id, ch.old_meta);
            } else {
                w.set(x, y, z, ch.id, ch.meta);
            }
        }
    }
    notify(w, sched, burn, sounds, x, y, z, now);
    stage.commit(changes);
}

// ---------------------------------------------------------------------------
// right-click interaction (lever/button/door/trapdoor/gate/repeater/ore)
// ---------------------------------------------------------------------------
//
// Vanilla `onBlockActivated` semantics: lever/button toggle preserving the
// orientation bits; wooden door toggles via the lower half (iron: consume
// without changing); trapdoor/gate flip bit 2; repeater right-click cycles
// delay (`anf`: delay = ((delay+1)*2)&12); ore lights with a 30-tick fade.

pub fn interact(
    world: anytype,
    sched: *Scheduler,
    burn: *BurnoutMap,
    changes: *ChangeList,
    sounds: *SoundList,
    x: i32,
    y: i32,
    z: i32,
    now: i64,
) void {
    var stage = Staged(@TypeOf(world)).init(world);
    interactStaged(&stage, sched, burn, changes, sounds, x, y, z, now);
    stage.commit(changes);
}

fn interactStaged(
    world: anytype,
    sched: *Scheduler,
    burn: *BurnoutMap,
    changes: *ChangeList,
    sounds: *SoundList,
    x: i32,
    y: i32,
    z: i32,
    now: i64,
) void {
    _ = changes;
    const bl = world.blocks;
    const rs = world.rules;
    const b = at(world, x, y, z);
    const k = bl.get(b.id).redstone_kind;
    if (k == .lever) {
        // alv: setBlockMetadata(facing + (unpressed ? 8 : 0)); click 0.6 on,
        // 0.5 off; notify self + support block.
        const was_on = leverOn(bl, b);
        const nm: u4 = if (was_on) b.meta & ~@as(u4, 8) else b.meta | 8;
        world.set(x, y, z, b.id, nm);
        sounds.append(.{ .kind = if (was_on) .click_off else .click_on, .x = x, .y = y, .z = z });
        notify(world, sched, burn, sounds, x, y, z, now);
        const sp = mountSupport(b.meta & 7);
        notify(world, sched, burn, sounds, x + sp.dx, y + sp.dy, z + sp.dz, now);
        return;
    }
    if (k == .button_stone or k == .button_wood) {
        if (buttonOn(bl, b)) return; // pressed: consume, hold the pulse
        const nm: u4 = b.meta | 8;
        world.set(x, y, z, b.id, nm);
        sounds.append(.{ .kind = .click_on, .x = x, .y = y, .z = z });
        const ticks = if (k == .button_stone) rs.button_ticks_stone else rs.button_ticks_wood;
        sched.schedule(x, y, z, now + ticks, .button_release);
        notify(world, sched, burn, sounds, x, y, z, now);
        const bsp = mountSupport(b.meta & 7);
        notify(world, sched, burn, sounds, x + bsp.dx, y + bsp.dy, z + bsp.dz, now);
        return;
    }
    if (k == .door_wood or k == .door_iron) {
        // Resolve to the lower half (upper carries bit 3).
        var ly = y;
        var lb = b;
        if (doorIsUpper(b.meta)) {
            if (y == 0) return;
            lb = at(world, x, y - 1, z);
            if (!isDoor(bl, lb) or lb.id != b.id) return;
            ly -= 1;
        }
        if (k == .door_iron) return; // iron: redstone only
        const was_open = doorOpen(lb.meta);
        const nm: u4 = if (was_open) lb.meta & ~@as(u4, 4) else lb.meta | 4;
        world.set(x, ly, z, lb.id, nm);
        sounds.append(.{ .kind = if (was_open) .door_close else .door_open, .x = x, .y = ly, .z = z });
        return;
    }
    if (k == .trapdoor) {
        const was_open = trapOpen(b.meta);
        const nm: u4 = if (was_open) b.meta & ~@as(u4, 4) else b.meta | 4;
        world.set(x, y, z, b.id, nm);
        sounds.append(.{ .kind = if (was_open) .door_close else .door_open, .x = x, .y = y, .z = z });
        return;
    }
    if (k == .gate) {
        const was_open = gateOpen(b.meta);
        const nm: u4 = if (was_open) b.meta & ~@as(u4, 4) else b.meta | 4;
        world.set(x, y, z, b.id, nm);
        sounds.append(.{ .kind = if (was_open) .door_close else .door_open, .x = x, .y = y, .z = z });
        return;
    }
    if (k == .repeater_on or k == .repeater_off) {
        const delay: u4 = @truncate(((@as(u8, (b.meta >> 2) & 3) + 1) & 3));
        const nm: u4 = (b.meta & 3) | (delay << 2);
        world.set(x, y, z, b.id, nm);
        sounds.append(.{ .kind = .click_on, .x = x, .y = y, .z = z });
        return;
    }
    if (k == .ore) {
        world.set(x, y, z, rs.ore_lit, b.meta);
        sched.schedule(x, y, z, now + rs.ore_fade_ticks, .ore_fade);
        return;
    }
    if (k == .ore_lit) {
        // Touch refreshes the glow timer (vanilla re-touches keep it lit).
        sched.schedule(x, y, z, now + rs.ore_fade_ticks, .ore_fade);
        return;
    }
}
