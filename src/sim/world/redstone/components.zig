//! Redstone component predicates, orientation and piston geometry.

const ids = @import("../../../ids.zig");
const world_view = @import("../world_view.zig");
const block_mod = @import("../../../game/block.zig");
const rules_mod = @import("../../../game/rules.zig");
const common = @import("common.zig");
const power = @import("power.zig");

const Block = world_view.Block;
const at = common.at;
const pistonPlacementFacing = power.pistonPlacementFacing;

// ---------------------------------------------------------------------------
// predicates + state readers
// ---------------------------------------------------------------------------

fn defOf(world: anytype, b: Block) block_mod.BlockDef {
    return world.blocks.get(b.id);
}

/// The component class of a block (single home for the table lookup every
/// predicate below repeats).
fn kindOf(blocks: *const block_mod.Table, b: Block) block_mod.RedstoneKind {
    return blocks.get(b.id).redstone_kind;
}

/// True when the block's kind is one of `kinds`.
fn kindIsAny(blocks: *const block_mod.Table, b: Block, kinds: []const block_mod.RedstoneKind) bool {
    const k = kindOf(blocks, b);
    for (kinds) |want| if (k == want) return true;
    return false;
}

/// Latched-on bit shared by levers/buttons (meta bit 3).
pub const latch_bit: u4 = 8;
/// Open bit shared by doors/trapdoors/gates (meta bit 2).
pub const open_bit: u4 = 4;

/// True when the latch bit is set (lever/button on).
fn latched(meta: u4) bool {
    return (meta & latch_bit) != 0;
}

pub fn isWire(blocks: *const block_mod.Table, b: Block) bool {
    return kindOf(blocks, b) == .wire;
}

pub fn isLever(blocks: *const block_mod.Table, b: Block) bool {
    return kindOf(blocks, b) == .lever;
}

pub fn isButton(blocks: *const block_mod.Table, b: Block) bool {
    return kindIsAny(blocks, b, &.{ .button_stone, .button_wood });
}

pub fn isPlate(blocks: *const block_mod.Table, b: Block) bool {
    return kindIsAny(blocks, b, &.{ .plate_stone, .plate_wood, .plate_light, .plate_heavy });
}

pub fn isTorch(blocks: *const block_mod.Table, b: Block) bool {
    return kindIsAny(blocks, b, &.{ .torch_on, .torch_off });
}

pub fn torchOn(blocks: *const block_mod.Table, b: Block) bool {
    return kindOf(blocks, b) == .torch_on;
}

pub fn isRepeater(blocks: *const block_mod.Table, b: Block) bool {
    return kindIsAny(blocks, b, &.{ .repeater_on, .repeater_off });
}

pub fn repeaterOn(blocks: *const block_mod.Table, b: Block) bool {
    return kindOf(blocks, b) == .repeater_on;
}

pub fn isLamp(blocks: *const block_mod.Table, b: Block) bool {
    return kindIsAny(blocks, b, &.{ .lamp_on, .lamp_off });
}

pub fn lampLit(blocks: *const block_mod.Table, b: Block) bool {
    return kindOf(blocks, b) == .lamp_on;
}

pub fn isDoor(blocks: *const block_mod.Table, b: Block) bool {
    return kindIsAny(blocks, b, &.{ .door_wood, .door_iron });
}

pub fn isTrapdoor(blocks: *const block_mod.Table, b: Block) bool {
    return kindOf(blocks, b) == .trapdoor;
}

pub fn isGate(blocks: *const block_mod.Table, b: Block) bool {
    return kindOf(blocks, b) == .gate;
}

pub fn isOre(blocks: *const block_mod.Table, b: Block) bool {
    return kindIsAny(blocks, b, &.{ .ore, .ore_lit });
}

pub fn leverOn(blocks: *const block_mod.Table, b: Block) bool {
    return isLever(blocks, b) and latched(b.meta);
}

pub fn buttonOn(blocks: *const block_mod.Table, b: Block) bool {
    return isButton(blocks, b) and latched(b.meta);
}

/// Power level a plate currently outputs (amu.c / aol.e: stone/wood 0/15,
/// weighted 0-15 stored in meta).
pub fn plateLevel(blocks: *const block_mod.Table, b: Block) u4 {
    return switch (blocks.get(b.id).redstone_kind) {
        .plate_stone, .plate_wood => if (b.meta != 0) 15 else 0,
        .plate_light, .plate_heavy => @truncate(b.meta & 15),
        else => 0,
    };
}

pub fn doorOpen(meta: u4) bool {
    return (meta & open_bit) != 0;
}

pub fn doorIsUpper(meta: u4) bool {
    return (meta & 8) != 0;
}

/// Upper-half meta for a door block (vanilla: the upper half carries the
/// bit-3 "is upper half" flag). Null for blocks that have no upper half.
/// The hinge bit comes from `doorHingeBit` at placement (server side).
pub fn upperHalfFor(blocks: *const block_mod.Table, id: ids.Id) ?u4 {
    const k = blocks.get(id).redstone_kind;
    return if (k == .door_wood or k == .door_iron) 8 else null;
}

pub fn trapOpen(meta: u4) bool {
    return (meta & open_bit) != 0;
}

pub fn gateOpen(meta: u4) bool {
    return (meta & open_bit) != 0;
}

pub fn repeaterDelay(rules: *const rules_mod.RedstoneRules, meta: u4) i64 {
    return rules.repeater_delays[(meta >> 2) & 3];
}

pub fn repeaterFacing(meta: u4) u2 {
    return @truncate(meta & 3);
}

/// Requesting-face tables, indexed by diode facing (verified via akj
/// output/input/side tables): output side, input cell side, and the
/// perpendicular lock check derives from facingVec.
pub const rep_out_side = [_]u3{ 3, 4, 2, 5 };
pub const rep_in_side = [_]u3{ 3, 4, 2, 5 };

/// Diode facing vectors, compass order (vanilla `Direction`, verified via
/// akj output/input tables): 0 north (-Z), 1 east (+X), 2 south (+Z),
/// 3 west (-X). This is the OUTPUT direction; input is behind.
pub fn facingVec(f: u2) struct { dx: i32, dz: i32 } {
    return switch (f) {
        0 => .{ .dx = 0, .dz = -1 },
        1 => .{ .dx = 1, .dz = 0 },
        2 => .{ .dx = 0, .dz = 1 },
        3 => .{ .dx = -1, .dz = 0 },
    };
}

/// Placer-yaw quadrant index shared by the yaw-to-facing tables below
/// (`floor(yaw*4/360 + 0.5)`, vanilla convention: 0 = south/+Z).
/// f32 math throughout: vanilla computes this in Java floats, and the
/// boundary behavior (which side of a quadrant edge a yaw falls on) must
/// match the jar bit-for-bit — f64 rounds boundary yaws differently.
fn yawIndex(yaw: f32) i32 {
    return @as(i32, @intFromFloat(@floor(yaw * 4.0 / 360.0 + 0.5)));
}

/// Player yaw (degrees, vanilla convention: 0 = south/+Z) to diode facing.
/// Exact vanilla formula (`akj.a(ahb,x,y,z,sv,add)`):
/// `(floor(yaw*4/360 + 0.5) & 3 + 2) % 4` (output away from the player).
pub fn yawToFacing(yaw: f32) u2 {
    const m: i32 = @mod(yawIndex(yaw) + 2, 4);
    return @truncate(@as(u2, @intCast(m)));
}

/// Door placement facing, exact vanilla formula (`ach.onItemUse`):
/// `floor((yaw+180)*4/360 - 0.5) & 3` (front faces the player).
pub fn doorYawToFacing(yaw: f32) u2 {
    const m: i32 = @mod(@as(i32, @intFromFloat(@floor((yaw + 180.0) * 4.0 / 360.0 - 0.5))), 4);
    return @truncate(@as(u2, @intCast(m)));
}

/// Door hinge bit (`ach.placeDoorBlock`, exact): perpendicular offsets from
/// facing; hinge=1 iff (left door and no right door) or right solids win.
/// Left/right follow the jar's (dx,dz) tables.
/// Normal cubes at (x,y)/(x,y+1): hinge-side solidity vote.
fn solidColumn(world: anytype, x: i32, y: i32, z: i32) u2 {
    return @as(u2, @intFromBool(normalCube(world.blocks, at(world, x, y, z).id))) +
        @as(u2, @intFromBool(normalCube(world.blocks, at(world, x, y + 1, z).id)));
}

/// Door blocks at (x,y)/(x,y+1) matching `door_id`.
fn doorColumn(world: anytype, x: i32, y: i32, z: i32, door_id: ids.Id) bool {
    return at(world, x, y, z).id == door_id or at(world, x, y + 1, z).id == door_id;
}

pub fn doorHingeBit(world: anytype, x: i32, y: i32, z: i32, facing: u2, door_id: ids.Id) u4 {
    const fdx: i32, const fdz: i32 = switch (facing) {
        0 => .{ 0, 1 },
        1 => .{ -1, 0 },
        2 => .{ 0, -1 },
        else => .{ 1, 0 },
    };
    const leftCount = solidColumn(world, x - fdx, y, z - fdz);
    const rightCount = solidColumn(world, x + fdx, y, z + fdz);
    const leftDoor = doorColumn(world, x - fdx, y, z - fdz, door_id);
    const rightDoor = doorColumn(world, x + fdx, y, z + fdz, door_id);
    if ((leftDoor and !rightDoor) or (rightCount > leftCount)) return 1;
    return 0;
}

/// Mounted-component support offset for a meta value (lever 0-5, torch 1-5,
/// button 1-4 walls; matches `alv.b` / `aoc` / `ajs` tables — the offset
/// points from the component at its anchor block).
pub fn mountSupport(meta: u4) struct { dx: i32, dy: i32, dz: i32 } {
    return switch (meta & 7) {
        0 => .{ .dx = 0, .dy = 1, .dz = 0 },
        1 => .{ .dx = -1, .dy = 0, .dz = 0 },
        2 => .{ .dx = 1, .dy = 0, .dz = 0 },
        3 => .{ .dx = 0, .dy = 0, .dz = -1 },
        4 => .{ .dx = 0, .dy = 0, .dz = 1 },
        // Floor variants sit below; the ceiling variant (7, from the
        // onBlockPlacedBy yaw step) hangs from above like 0. (Torches
        // never carry 6/7; buttons never carry 0/5/6/7.)
        5, 6 => .{ .dx = 0, .dy = -1, .dz = 0 },
        else => .{ .dx = 0, .dy = 1, .dz = 0 },
    };
}

/// Torch support position: same table (`anc.m` checks exactly these cells).
pub fn torchSupportPos(x: i32, y: i32, z: i32, meta: u4) struct { x: i32, y: i32, z: i32 } {
    const s = mountSupport(meta);
    return .{ .x = x + s.dx, .y = y + s.dy, .z = z + s.dz };
}

/// Torch mount meta for the `anc.m` power check side: meta 5→0, 3→2, 4→3,
/// 1→4, 2→5 (other metas never power off).
pub fn torchCheckSide(meta: u4) ?u3 {
    return switch (meta & 7) {
        5 => 0,
        3 => 2,
        4 => 3,
        1 => 4,
        2 => 5,
        else => null,
    };
}

/// Clicked-face (0-5) to torch meta (`aoc.onBlockPlaced`): floor 5, walls
/// 1-4, ceiling 0. (Face 0 never occurs via vanilla placement — ceiling
/// torches self-pop through the support check.)
pub fn orientTorch(face: i8) u4 {
    return switch (face) {
        0 => 0,
        1 => 5,
        2 => 4,
        3 => 3,
        4 => 2,
        5 => 1,
        else => 5,
    };
}
/// Lever onBlockPlacedBy, exact jar port (`alv.a(ahb,III,sv,add)`): a fresh
/// floor lever (face 1 -> 5) becomes 5|6 and a fresh ceiling lever
/// (face 0 -> 0) becomes 7|0 by placer-yaw quadrant parity
/// (`floor(yaw*4/360 + 0.5) & 1`, Java two's-complement semantics, which
/// Zig's wrapping `&` on i32 reproduces exactly). Walls keep their face
/// meta; the on-bit is preserved. Without this the server pins every
/// floor lever to 5 while the client predicts 5|6, so E/W placements
/// visibly snap north on the server echo.
pub fn leverPlacedBy(meta: u4, yaw: f32) u4 {
    const on = meta & 8;
    const dir = meta & 7;
    const q = yawIndex(yaw);
    if (dir == 5) return (if ((q & 1) == 0) @as(u4, 5) else @as(u4, 6)) | on;
    if (dir == 0) return (if ((q & 1) == 0) @as(u4, 7) else @as(u4, 0)) | on;
    return meta;
}

/// Lever/button: same walls/floor/ceiling table as torches
/// (`alv.onBlockPlaced` / `ajs.onBlockPlaced`).
pub fn orientLever(face: i8) u4 {
    return orientTorch(face);
}

pub fn orientButton(face: i8) u4 {
    return orientLever(face);
}

/// Trapdoor orientation from clicked face (approximation: fixed hinge side,
/// matching 1.7.10's single-hinge doors).
pub fn orientTrapdoor(face: i8) u4 {
    return switch (face) {
        2 => 0,
        3 => 1,
        4 => 2,
        5 => 3,
        else => 0,
    };
}

/// Trapdoor support offset by orientation meta (mount block beside it).
/// Jar `aoe.d`: side 2 (meta 0) -> z+1, side 3 (meta 1) -> z-1,
/// side 4 (meta 2) -> x+1, side 5 (meta 3) -> x-1 (the clicked pillar).
pub fn trapdoorSupport(x: i32, y: i32, z: i32, meta: u4) struct { x: i32, y: i32, z: i32 } {
    return switch (meta & 3) {
        0 => .{ .x = x, .y = y, .z = z + 1 },
        1 => .{ .x = x, .y = y, .z = z - 1 },
        2 => .{ .x = x + 1, .y = y, .z = z },
        else => .{ .x = x - 1, .y = y, .z = z },
    };
}

/// Dispenser/dropper facing (`BlockDispenser.onBlockPlacedBy`, 1.7.10):
/// yaw-only, no up/down — `floor(yaw*4/360+0.5)&3` maps 0->2(north),
/// 1->5(east), 2->3(south), 3->4(west). Same yaw table as the piston
/// fallback; the dispenser faces TOWARD the placer.
pub fn dispenserYawToFacing(yaw: f32) u4 {
    return switch (@mod(yawIndex(yaw), 4)) {
        0 => 2,
        1 => 5,
        2 => 3,
        3 => 4,
        else => 2,
    };
}

/// Hopper output meta (`BlockHopper.onBlockPlaced`, 1.7.10): the opposite
/// of the clicked face (`Facing.oppositeSide` = 1,0,3,2,5,4). Face 1 (top)
/// is the common case and yields 0 (down). Kept verbatim including the
/// face-0 -> 1 mapping (vanilla allows the value; hoppers are inert here
/// so only the rendered facing matters).
pub fn hopperFaceToMeta(face: i8) u4 {
    return switch (face) {
        0 => 1,
        1 => 0,
        2 => 3,
        3 => 2,
        4 => 5,
        5 => 4,
        else => 0,
    };
}

/// Anvil facing + damage (`ajb.onBlockPlacedBy`, jar-verified bytecode):
/// the yaw index rotated once (`l = (idx+1) & 3`), then the table
/// {0:2, 1:3, 2:0, 3:1} — i.e. net `(idx-1) & 3`, mirrored vs the naive
/// +1 (which faces every quadrant 180° off). The item damage (0 normal,
/// 1 slightly, 2 very) rides in bits 2-3.
pub fn anvilYawToMeta(yaw: f32, damage: u4) u4 {
    const dir: u4 = switch (@mod(yawIndex(yaw) + 1, 4)) {
        0 => 2,
        1 => 3,
        2 => 0,
        3 => 1,
        else => 2,
    };
    return dir | ((damage & 3) << 2);
}

/// Chest/furnace/ender-chest facing (`akv`/`ale`/`ajx.onBlockPlacedBy`,
/// jar-verified, all three share one table): yaw-only
/// {0:2, 1:5, 2:3, 3:4} — the front faces the placer. Numerically the
/// dispenser table, kept separate so chests never read as dispensers.
pub fn chestYawToFacing(yaw: f32) u4 {
    return switch (@mod(yawIndex(yaw), 4)) {
        0 => 2,
        1 => 5,
        2 => 3,
        3 => 4,
        else => 2,
    };
}

/// Orientation meta for a freshly placed redstone-family block, or null to
/// keep the legacy damage-nibble behavior for everything else.
pub fn orientOnPlace(
    blocks: *const block_mod.Table,
    block: ids.Id,
    face: i8,
    yaw: f32,
    cursor_y: u8,
    pos: ?[3]f64,
    bx: i32,
    by: i32,
    bz: i32,
    held_damage: u4,
) ?u4 {
    return switch (blocks.get(block).orientation) {
        .lever => leverPlacedBy(orientLever(face), yaw),
        .button => orientButton(face),
        .torch => orientTorch(face),
        .diode => @as(u4, yawToFacing(yaw)),
        .trapdoor => orientTrapdoor(face) | (if (cursor_y > 8) @as(u4, 8) else 0),
        .door => @as(u4, doorYawToFacing(yaw)),
        .gate => blk: {
            const f = doorYawToFacing(yaw);
            break :blk if (f == 0 or f == 2) 0 else 1;
        },
        // `app.a(ahb,IIILsv)`: close player -> up/down by eye height, else
        // the yaw table; the piston faces TOWARD the player.
        .piston => blk: {
            const pp = pos orelse return 0;
            break :blk pistonPlacementFacing(pp[0], pp[1], pp[2], yaw, bx, by, bz);
        },
        .directional => dispenserYawToFacing(yaw),
        .hopper => hopperFaceToMeta(face),
        .anvil => anvilYawToMeta(yaw, held_damage),
        .chest => chestYawToFacing(yaw),
        .none => null,
    };
}

/// Door upper-half meta for a fresh placement (`ach.placeDoorBlock`):
/// 8 plus the vanilla hinge bit (see `doorHingeBit`).
pub fn doorUpperMeta(world: anytype, x: i32, y: i32, z: i32, facing: u2, door_id: ids.Id) u4 {
    return 8 | doorHingeBit(world, x, y, z, facing, door_id);
}

pub fn isInteractable(blocks: *const block_mod.Table, id: ids.Id) bool {
    return blocks.get(id).redstone_interactable;
}

/// Vanilla normal cube (`aji.r`, approximated): full opaque cubes that carry
/// power and anchor levers/buttons. Glass/ice/leaves/slabs/stairs/plants
/// never qualify. (Curated to mirror `view.isOpaqueCube`'s false-list;
/// checked against jar behavior for the redstone set.)
pub fn normalCube(blocks: *const block_mod.Table, id: ids.Id) bool {
    return blocks.get(id).normal_cube;
}

/// Blocks with a solid top face for wire/repeater/door/plate support
/// (`ahb.a(Lahl)`): normal cubes plus glass/glowstone/slabs/hopper.
pub fn solidTop(blocks: *const block_mod.Table, id: ids.Id) bool {
    const d = blocks.get(id);
    return d.normal_cube or d.solid_top;
}

/// Torch/plate special anchors (`aoc.m` / `akz.a`): fence, nether fence,
/// glass, cobblestone wall (on top of normal-cube support).
pub fn anchorPost(blocks: *const block_mod.Table, id: ids.Id) bool {
    return blocks.get(id).anchor_post;
}

/// Lever anchor (`alv.d` neighbor check, jar-verified): floor variants
/// (5/6) need a solid top below; ceiling variants (0/7) need a normal
/// cube above; walls anchor at the mount offset (normal cube).
pub fn leverAnchor(world: anytype, x: i32, y: i32, z: i32, meta: u4) bool {
    const m = meta & 7;
    if (m == 5 or m == 6) return solidTop(world.blocks, at(world, x, y - 1, z).id);
    if (m == 0 or m == 7) return normalCube(world.blocks, at(world, x, y + 1, z).id);
    const sp = torchSupportPos(x, y, z, meta);
    return normalCube(world.blocks, at(world, sp.x, sp.y, sp.z).id);
}

/// Torch anchor (`aoc.m`): normal cube, or post blocks below.
pub fn torchAnchor(world: anytype, x: i32, y: i32, z: i32, meta: u4) bool {
    const m = meta & 7;
    if (m == 5) {
        const below = at(world, x, y - 1, z).id;
        return normalCube(world.blocks, below) or anchorPost(world.blocks, below);
    }
    const sp = torchSupportPos(x, y, z, meta);
    return normalCube(world.blocks, at(world, sp.x, sp.y, sp.z).id);
}

/// Pressure-plate anchor (`ajd` neighbor check): solid top or fence below.
pub fn plateAnchor(world: anytype, x: i32, y: i32, z: i32) bool {
    const below = at(world, x, y - 1, z).id;
    return solidTop(world.blocks, below) or world.blocks.get(below).plate_anchor;
}

// ---------------------------------------------------------------------------
// pistons (jar-verbatim: `app` = BlockPistonBase, `apq` = head, `apr` = moving)
// ---------------------------------------------------------------------------
//
// Vanilla drives pistons through server block events: updatePistonState
// (on every neighbor change) checks indirect power on the five non-front
// faces and fires addBlockEvent(extend=0 / retract=1); onBlockEventReceived
// then runs doMove. The server-side doMove writes *moving* blocks with tile
// entities that finalize themselves; we have no TE ticker, so the event
// applies the FINAL state directly and marks those writes `silent` — the
// client gets the S24 Block Action packet (same one vanilla sends), runs the
// identical client-side doMove, animates, and lands on the same final blocks.
// Vanilla-side the TE finalize happens ~0.5s later; the observable outcome
// (final blocks, drops, pushes) is identical.

pub fn isPiston(blocks: *const block_mod.Table, b: Block) bool {
    const k = blocks.get(b.id).redstone_kind;
    return k == .piston or k == .piston_sticky;
}

pub fn isPistonHead(blocks: *const block_mod.Table, b: Block) bool {
    return blocks.get(b.id).redstone_kind == .piston_head;
}

/// Facing bits (`app.b`): meta & 7. 0=down 1=up 2=north(-z) 3=south(+z)
/// 4=west(-x) 5=east(+x).
pub fn pistonFacing(meta: u4) u3 {
    return @truncate(meta & 7);
}

/// Extended bit (`app.c`): meta & 8.
pub fn pistonExtended(meta: u4) bool {
    return (meta & 8) != 0;
}

pub fn pistonVec(f: u3) struct { dx: i32, dy: i32, dz: i32 } {
    return switch (f) {
        0 => .{ .dx = 0, .dy = -1, .dz = 0 },
        1 => .{ .dx = 0, .dy = 1, .dz = 0 },
        2 => .{ .dx = 0, .dy = 0, .dz = -1 },
        3 => .{ .dx = 0, .dy = 0, .dz = 1 },
        4 => .{ .dx = -1, .dy = 0, .dz = 0 },
        else => .{ .dx = 1, .dy = 0, .dz = 0 },
    };
}
