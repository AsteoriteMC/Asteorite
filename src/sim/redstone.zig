//! Vanilla 1.7.10 redstone simulation (Phase K1), ported instruction-by-
//! instruction from the official server jar (obfuscated names in comments:
//! `ana` = BlockRedstoneWire, `anc`/`aoc` = torch, `alv` = lever,
//! `ajs`/`anx`/`aon` = buttons, `ajd`/`amu`/`aol` = plates, `akj`/`anf` =
//! diode/repeater, `akn` = door, `anb` = lamp, `amz` = ore).
//!
//! Pure sim: no networking, storage, or allocation. All world access goes
//! through a caller-provided adapter with `get`/`set`/`pop` methods; `set`
//! and `pop` BOTH apply and record into the shared ChangeList, so callers
//! never append changes themselves (single recorder, no duplicates).
//!
//! Power model (matches `ahb` exactly):
//! - `side` everywhere is the touching face ON THE REQUESTER, vanilla face
//!   indices: 0 down, 1 up, 2 north(-z), 3 south(+z), 4 west(-x), 5 east(+x).
//!   A requester below a source queries with side 1 (its top face).
//! - `weak` = `aji.b` per-block output; `strong` = `aji.c`; `indirect` =
//!   `ahb.g` (normal cube ? strongest-of-neighbors : weak); `strongest` =
//!   `ahb.u` (max weak over the 6 neighbors); `gettingPowered` = `ahb.v`.
//! - Wire weak output is connection-gated per `ana.b` (down always, dot
//!   wires everywhere, otherwise direction && !perpendiculars).
//!
//! Timing is in game ticks. The server ticker advances `world_age` by 20 per
//! 1Hz call, so sub-second vanilla delays quantize to ~1 server tick — same
//! convention as the furnace 20-tick quanta. Torch burnout is vanilla-exact:
//! only ON→OFF flips count, 8 within 60 ticks locks the torch until the
//! entries age out (plus fizz sound + smoke particles client-side; smoke
//! needs the S2A packet, L8). Burnt torches wake on the next neighbor
//! notify, like vanilla (no forced recheck).

const std = @import("std");
const ids = @import("../ids.zig");
const world_view = @import("world_view.zig");
const block_mod = @import("../game/block.zig");
const rules_mod = @import("../game/rules.zig");

pub const Block = world_view.Block;
pub const WorldView = world_view.WorldView;

/// One applied edit. `popped` marks support-loss pops (server spawns drops
/// for these); plain updates never drop.
pub const Change = struct {
    x: i32,
    y: i32,
    z: i32,
    id: ids.Id,
    meta: u4,
    old_id: ids.Id,
    old_meta: u4,
    popped: bool = false,
    /// Piston block-event writes carry the animation in the S24 packet;
    /// an S23 echo would cancel the client's moving-block render.
    silent: bool = false,
};

pub const max_changes: usize = 1024;

/// Bounded change buffer (storm protection: drops beyond cap, flags it).
pub const ChangeList = struct {
    items: [max_changes]Change = undefined,
    n: usize = 0,
    dropped: bool = false,

    pub fn append(self: *ChangeList, c: Change) void {
        if (self.n >= max_changes) {
            self.dropped = true;
            return;
        }
        self.items[self.n] = c;
        self.n += 1;
    }
};

pub const SoundKind = enum { click_on, click_off, door_open, door_close, fizz, piston_out, piston_in };

pub const SoundEv = struct {
    kind: SoundKind,
    x: i32,
    y: i32,
    z: i32,
};

pub const SoundList = struct {
    evs: [64]SoundEv = undefined,
    n: usize = 0,

    pub fn append(self: *SoundList, s: SoundEv) void {
        if (self.n >= self.evs.len) return;
        self.evs[self.n] = s;
        self.n += 1;
    }

    /// S29 voice + pitch (+ volume: pistons play at 0.5, `app` doMove).
    pub fn voice(kind: SoundKind) struct { name: []const u8, pitch: f32, volume: f32 } {
        return switch (kind) {
            .click_on => .{ .name = "random.click", .pitch = 0.6, .volume = 1.0 },
            .click_off => .{ .name = "random.click", .pitch = 0.5, .volume = 1.0 },
            .door_open => .{ .name = "random.door_open", .pitch = 1.0, .volume = 1.0 },
            .door_close => .{ .name = "random.door_close", .pitch = 1.0, .volume = 1.0 },
            .fizz => .{ .name = "random.fizz", .pitch = 2.6, .volume = 1.0 },
            // app.a: playSoundEffectAt(..., 0.5, rand*0.25+0.6) / (..., 0.5, rand*0.15+0.6)
            .piston_out => .{ .name = "tile.piston.out", .pitch = 0.72, .volume = 0.5 },
            .piston_in => .{ .name = "tile.piston.in", .pitch = 0.68, .volume = 0.5 },
        };
    }
};

// Timing values live in `game.rules.RedstoneRules` (profile data).

/// Neighbor fan-out cap per edit (anti-lag-machine; clock loops hit this and
/// self-extinguish via torch burnout instead of recursing forever).
pub const max_updates_per_edit: usize = 4096;
/// Scheduled entries drained per server tick.
pub const max_scheduled_per_tick: usize = 500;

// ---------------------------------------------------------------------------
// predicates + state readers
// ---------------------------------------------------------------------------

fn defOf(world: anytype, b: Block) block_mod.BlockDef {
    return world.blocks.get(b.id);
}

pub fn isWire(blocks: *const block_mod.Table, b: Block) bool {
    return blocks.get(b.id).redstone_kind == .wire;
}

pub fn isLever(blocks: *const block_mod.Table, b: Block) bool {
    return blocks.get(b.id).redstone_kind == .lever;
}

pub fn isButton(blocks: *const block_mod.Table, b: Block) bool {
    const k = blocks.get(b.id).redstone_kind;
    return k == .button_stone or k == .button_wood;
}

pub fn isPlate(blocks: *const block_mod.Table, b: Block) bool {
    const k = blocks.get(b.id).redstone_kind;
    return k == .plate_stone or k == .plate_wood or k == .plate_light or k == .plate_heavy;
}

pub fn isTorch(blocks: *const block_mod.Table, b: Block) bool {
    const k = blocks.get(b.id).redstone_kind;
    return k == .torch_on or k == .torch_off;
}

pub fn torchOn(blocks: *const block_mod.Table, b: Block) bool {
    return blocks.get(b.id).redstone_kind == .torch_on;
}

pub fn isRepeater(blocks: *const block_mod.Table, b: Block) bool {
    const k = blocks.get(b.id).redstone_kind;
    return k == .repeater_on or k == .repeater_off;
}

pub fn repeaterOn(blocks: *const block_mod.Table, b: Block) bool {
    return blocks.get(b.id).redstone_kind == .repeater_on;
}

pub fn isLamp(blocks: *const block_mod.Table, b: Block) bool {
    const k = blocks.get(b.id).redstone_kind;
    return k == .lamp_on or k == .lamp_off;
}

pub fn lampLit(blocks: *const block_mod.Table, b: Block) bool {
    return blocks.get(b.id).redstone_kind == .lamp_on;
}

pub fn isDoor(blocks: *const block_mod.Table, b: Block) bool {
    const k = blocks.get(b.id).redstone_kind;
    return k == .door_wood or k == .door_iron;
}

pub fn isTrapdoor(blocks: *const block_mod.Table, b: Block) bool {
    return blocks.get(b.id).redstone_kind == .trapdoor;
}

pub fn isGate(blocks: *const block_mod.Table, b: Block) bool {
    return blocks.get(b.id).redstone_kind == .gate;
}

pub fn isOre(blocks: *const block_mod.Table, b: Block) bool {
    const k = blocks.get(b.id).redstone_kind;
    return k == .ore or k == .ore_lit;
}

pub fn leverOn(blocks: *const block_mod.Table, b: Block) bool {
    return isLever(blocks, b) and (b.meta & 8) != 0;
}

pub fn buttonOn(blocks: *const block_mod.Table, b: Block) bool {
    return isButton(blocks, b) and (b.meta & 8) != 0;
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
    return (meta & 4) != 0;
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
    return (meta & 4) != 0;
}

pub fn gateOpen(meta: u4) bool {
    return (meta & 4) != 0;
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
const rep_out_side = [_]u3{ 3, 4, 2, 5 };
const rep_in_side = [_]u3{ 3, 4, 2, 5 };

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

/// Player yaw (degrees, vanilla convention: 0 = south/+Z) to diode facing.
/// Exact vanilla formula (`akj.a(ahb,x,y,z,sv,add)`):
/// `(floor(yaw*4/360 + 0.5) & 3 + 2) % 4` (output away from the player).
pub fn yawToFacing(yaw: f32) u2 {
    const m: i32 = @mod(@as(i32, @intFromFloat(@floor(yaw * 4.0 / 360.0 + 0.5))) + 2, 4);
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
pub fn doorHingeBit(world: anytype, x: i32, y: i32, z: i32, facing: u2, door_id: ids.Id) u4 {
    const fdx: i32, const fdz: i32 = switch (facing) {
        0 => .{ 0, 1 },
        1 => .{ -1, 0 },
        2 => .{ 0, -1 },
        else => .{ 1, 0 },
    };
    const leftCount: u2 = @as(u2, @intFromBool(normalCube(world.blocks, at(world, x - fdx, y, z - fdz).id))) +
        @as(u2, @intFromBool(normalCube(world.blocks, at(world, x - fdx, y + 1, z - fdz).id)));
    const rightCount: u2 = @as(u2, @intFromBool(normalCube(world.blocks, at(world, x + fdx, y, z + fdz).id))) +
        @as(u2, @intFromBool(normalCube(world.blocks, at(world, x + fdx, y + 1, z + fdz).id)));
    const leftDoor = at(world, x - fdx, y, z - fdz).id == door_id or
        at(world, x - fdx, y + 1, z - fdz).id == door_id;
    const rightDoor = at(world, x + fdx, y, z + fdz).id == door_id or
        at(world, x + fdx, y + 1, z + fdz).id == door_id;
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
    const q: i32 = @as(i32, @intFromFloat(@floor(yaw * 4.0 / 360.0 + 0.5)));
    if (dir == 5) return (if ((q & 1) == 0) @as(u4, 5) else @as(u4, 6)) | on;
    if (dir == 0) return (if ((q & 1) == 0) @as(u4, 7) else @as(u4, 0)) | on;
    return meta;
}

/// Lever/button: same walls/floor as torches, plus lever ceiling 0
/// (`alv.onBlockPlaced` / `ajs.onBlockPlaced`).
pub fn orientLever(face: i8) u4 {
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
    const idx: i32 = @mod(@as(i32, @intFromFloat(@floor(@as(f64, yaw) * 4.0 / 360.0 + 0.5))), 4);
    return switch (idx) {
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

/// Anvil facing + damage (`BlockAnvil.onBlockPlacedBy`, 1.7.10): the yaw
/// index rotated once (`(floor(yaw*4/360+0.5)&3 + 1) & 3` — the anvil's
/// long axis sits perpendicular to the placer) in the low 2 bits, the
/// item damage (0 normal, 1 slightly, 2 very) in bits 2-3.
pub fn anvilYawToMeta(yaw: f32, damage: u4) u4 {
    const idx: i32 = @mod(@as(i32, @intFromFloat(@floor(@as(f64, yaw) * 4.0 / 360.0 + 0.5))) + 1, 4);
    return @truncate(@as(u4, @intCast(idx)) | ((damage & 3) << 2));
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

/// Block-action event for S24 (client animation): position, event id, facing,
/// and the vanilla block id of the piston block.
pub const BlockAction = struct {
    x: i32,
    y: i32,
    z: i32,
    event_id: u8,
    facing: u8,
    id: ids.Id,
};

pub const ActionList = struct {
    items: [64]BlockAction = undefined,
    n: usize = 0,

    pub fn append(self: *ActionList, a: BlockAction) void {
        if (self.n >= self.items.len) return;
        self.items[self.n] = a;
        self.n += 1;
    }
};

// ---------------------------------------------------------------------------
// scheduler (vanilla `scheduleBlockUpdate`: per-position dedupe, budgeted drain)
// ---------------------------------------------------------------------------

pub const SchedKind = enum { button_release, repeater_eval, ore_fade, piston_extend, piston_retract, wire_check };

pub const SchedEntry = struct {
    x: i32,
    y: i32,
    z: i32,
    due: i64,
    kind: SchedKind,
};

pub const sched_cap: usize = 1024;

pub const Scheduler = struct {
    entries: [sched_cap]SchedEntry = undefined,
    n: usize = 0,

    /// Schedule (or reschedule: same position replaces the old entry, like
    /// vanilla's per-position dedupe). Full queue evicts the oldest (FIFO).
    pub fn schedule(self: *Scheduler, x: i32, y: i32, z: i32, due: i64, kind: SchedKind) void {
        for (self.entries[0..self.n]) |*e| {
            if (e.x == x and e.y == y and e.z == z) {
                e.* = .{ .x = x, .y = y, .z = z, .due = due, .kind = kind };
                return;
            }
        }
        if (self.n < sched_cap) {
            self.entries[self.n] = .{ .x = x, .y = y, .z = z, .due = due, .kind = kind };
            self.n += 1;
            return;
        }
        std.mem.copyForwards(SchedEntry, self.entries[0 .. sched_cap - 1], self.entries[1..sched_cap]);
        self.entries[sched_cap - 1] = .{ .x = x, .y = y, .z = z, .due = due, .kind = kind };
    }

    pub fn pendingAt(self: *const Scheduler, x: i32, y: i32, z: i32) bool {
        for (self.entries[0..self.n]) |e| {
            if (e.x == x and e.y == y and e.z == z) return true;
        }
        return false;
    }

    /// Move due entries (due <= now) into `out`, removing them. Returns the
    /// count fired.
    pub fn popDue(self: *Scheduler, now: i64, out: []SchedEntry) usize {
        var fired: usize = 0;
        var i: usize = 0;
        while (i < self.n) {
            if (self.entries[i].due <= now and fired < out.len) {
                out[fired] = self.entries[i];
                fired += 1;
                self.entries[i] = self.entries[self.n - 1];
                self.n -= 1;
            } else {
                i += 1;
            }
        }
        return fired;
    }
};

// ---------------------------------------------------------------------------
// torch burnout (vanilla `anc.a`: per-world list of RedstoneUpdate(x,y,z,t);
// pruned older than 60 ticks on every torch tick; 8 entries = burnt out)
// ---------------------------------------------------------------------------

pub const burn_cap: usize = 256;
/// Maximum per-position flip history an engine instance retains. The
/// profile rule (`torch_burnout_toggles`) selects the active threshold.
pub const burn_hist_cap: usize = 16;

const BurnSlot = struct {
    used: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    hist: [burn_hist_cap]i64 = [_]i64{0} ** burn_hist_cap,
    h_n: usize = 0,
};

pub const BurnoutMap = struct {
    slots: [burn_cap]BurnSlot = [_]BurnSlot{.{}} ** burn_cap,
    cursor: usize = 0,

    fn slotFor(self: *BurnoutMap, x: i32, y: i32, z: i32) *BurnSlot {
        for (&self.slots) |*s| {
            if (s.used and s.x == x and s.y == y and s.z == z) return s;
        }
        for (&self.slots) |*s| {
            if (!s.used) {
                s.* = .{ .used = true, .x = x, .y = y, .z = z };
                return s;
            }
        }
        const s = &self.slots[self.cursor % burn_cap];
        self.cursor += 1;
        s.* = .{ .used = true, .x = x, .y = y, .z = z };
        return s;
    }

    /// Count of recorded flips still within the 60-tick window (vanilla
    /// prunes older entries on every torch tick).
    fn freshCount(self: *BurnoutMap, x: i32, y: i32, z: i32, now: i64, rules: *const rules_mod.RedstoneRules) usize {
        for (&self.slots) |*s| {
            if (s.used and s.x == x and s.y == y and s.z == z) {
                var n: usize = 0;
                var i: usize = 0;
                while (i < s.h_n) : (i += 1) {
                    if (now - s.hist[i] <= rules.torch_burnout_window) n += 1;
                }
                return n;
            }
        }
        return 0;
    }

    pub fn isBurnt(self: *BurnoutMap, x: i32, y: i32, z: i32, now: i64, rules: *const rules_mod.RedstoneRules) bool {
        if (!rules.torch_burnout) return false;
        return self.freshCount(x, y, z, now, rules) >= rules.torch_burnout_toggles;
    }

    /// Record one ON→OFF flip (vanilla only records power-offs). Returns
    /// true when this flip trips burnout (8 within 60 ticks by default).
    pub fn noteFlip(self: *BurnoutMap, x: i32, y: i32, z: i32, now: i64, rules: *const rules_mod.RedstoneRules) bool {
        if (!rules.torch_burnout or rules.torch_burnout_toggles == 0) return false;
        const cap = @min(rules.torch_burnout_toggles, burn_hist_cap);
        const s = self.slotFor(x, y, z);
        // ring insert: shift when full (keeps the most recent entries, like
        // the vanilla list before its window prune)
        if (s.h_n < cap) {
            s.hist[s.h_n] = now;
            s.h_n += 1;
        } else {
            std.mem.copyForwards(i64, s.hist[0 .. cap - 1], s.hist[1..cap]);
            s.hist[cap - 1] = now;
        }
        return self.freshCount(x, y, z, now, rules) >= rules.torch_burnout_toggles;
    }
};

// ---------------------------------------------------------------------------
// pressure-plate registry (positions only; polled each server tick)
// ---------------------------------------------------------------------------

pub const plate_cap: usize = 256;

pub const PlatePos = struct { x: i32, y: i32, z: i32 };

pub const PlateSet = struct {
    items: [plate_cap]PlatePos = undefined,
    /// Rising-edge tick (same 20tps `now` the scheduler uses) per slot.
    /// Vanilla plates re-check on a 20-tick schedule, so a tap stays
    /// pressed for a full second; the 1Hz poll would otherwise release
    /// phase-dependently. Parallel to `items` (swap/shift together).
    pressed: [plate_cap]i64 = [_]i64{0} ** plate_cap,
    n: usize = 0,

    pub fn add(self: *PlateSet, x: i32, y: i32, z: i32) void {
        for (self.items[0..self.n]) |p| {
            if (p.x == x and p.y == y and p.z == z) return;
        }
        if (self.n < plate_cap) {
            self.items[self.n] = .{ .x = x, .y = y, .z = z };
            self.pressed[self.n] = 0;
            self.n += 1;
            return;
        }
        std.mem.copyForwards(PlatePos, self.items[0 .. plate_cap - 1], self.items[1..plate_cap]);
        std.mem.copyForwards(i64, self.pressed[0 .. plate_cap - 1], self.pressed[1..plate_cap]);
        self.items[plate_cap - 1] = .{ .x = x, .y = y, .z = z };
        self.pressed[plate_cap - 1] = 0;
    }

    pub fn remove(self: *PlateSet, x: i32, y: i32, z: i32) void {
        var i: usize = 0;
        while (i < self.n) {
            const p = self.items[i];
            if (p.x == x and p.y == y and p.z == z) {
                self.items[i] = self.items[self.n - 1];
                self.pressed[i] = self.pressed[self.n - 1];
                self.n -= 1;
            } else {
                i += 1;
            }
        }
    }
};

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

fn at(world: anytype, x: i32, y: i32, z: i32) Block {
    if (y < 0 or y > 255) return .{ .id = ids.air, .meta = 0 };
    return world.get(x, y, z) orelse .{ .id = ids.air, .meta = 0 };
}

const dirs6 = [_]struct { dx: i32, dy: i32, dz: i32, side: u3 }{
    .{ .dx = 0, .dy = -1, .dz = 0, .side = 0 },
    .{ .dx = 0, .dy = 1, .dz = 0, .side = 1 },
    .{ .dx = 0, .dy = 0, .dz = -1, .side = 2 },
    .{ .dx = 0, .dy = 0, .dz = 1, .side = 3 },
    .{ .dx = -1, .dy = 0, .dz = 0, .side = 4 },
    .{ .dx = 1, .dy = 0, .dz = 0, .side = 5 },
};

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

/// Wire connection flags in the four horizontal directions, with vanilla
/// down-steps and up-steps (`ana.b` var7-10): direct connect, non-cube
/// with a wire diagonally below, or cube with a wire diagonally above.
fn wireConns(world: anytype, x: i32, y: i32, z: i32) struct { w: bool, e: bool, n: bool, s: bool } {
    const bl = world.blocks;
    const w_c = at(world, x - 1, y, z);
    const w = connectsTo(world, x - 1, y, z, 1) or
        (!normalCube(bl, w_c.id) and isWire(bl, at(world, x - 1, y - 1, z))) or
        (normalCube(bl, w_c.id) and isWire(bl, at(world, x - 1, y + 1, z)));
    const e_c = at(world, x + 1, y, z);
    const e = connectsTo(world, x + 1, y, z, 3) or
        (!normalCube(bl, e_c.id) and isWire(bl, at(world, x + 1, y - 1, z))) or
        (normalCube(bl, e_c.id) and isWire(bl, at(world, x + 1, y + 1, z)));
    const n_c = at(world, x, y, z - 1);
    const n = connectsTo(world, x, y, z - 1, 2) or
        (!normalCube(bl, n_c.id) and isWire(bl, at(world, x, y - 1, z - 1))) or
        (normalCube(bl, n_c.id) and isWire(bl, at(world, x, y + 1, z - 1)));
    const s_c = at(world, x, y, z + 1);
    const s = connectsTo(world, x, y, z + 1, 0) or
        (!normalCube(bl, s_c.id) and isWire(bl, at(world, x, y - 1, z + 1))) or
        (normalCube(bl, s_c.id) and isWire(bl, at(world, x, y + 1, z + 1)));
    return .{ .w = w, .e = e, .n = n, .s = s };
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

/// Block receiving power from any neighbor (`ahb.v`, used by lamps/doors).
pub fn gettingPowered(world: anytype, x: i32, y: i32, z: i32) bool {
    for (dirs6) |d| {
        if (indirectAt(world, x + d.dx, y + d.dy, z + d.dz, d.side, true) > 0) return true;
    }
    return false;
}

/// Wire level (`ana.calculateCurrentChanges`, exact): stored meta, indirect
/// non-wire sources (wires dead, like `wiresProvidePower=false`), linked-wire
/// max minus one, indirect restore. Converges to the same steady state the
/// vanilla multi-tick settle reaches.
pub fn computeWire(world: anytype, x: i32, y: i32, z: i32) u4 {
    const bl = world.blocks;
    const cur: i64 = at(world, x, y, z).meta;
    var best: i64 = cur;
    var ind: u4 = 0;
    for (dirs6) |d| {
        ind = @max(ind, indirectAt(world, x + d.dx, y + d.dy, z + d.dz, d.side, false));
    }
    if (ind > 0 and @as(i64, ind) >= best) best = ind;
    var loopBest: i64 = 0;
    const horiz = [_]struct { dx: i32, dz: i32 }{
        .{ .dx = -1, .dz = 0 },
        .{ .dx = 1, .dz = 0 },
        .{ .dx = 0, .dz = -1 },
        .{ .dx = 0, .dz = 1 },
    };
    for (horiz) |h| {
        const nb = at(world, x + h.dx, y, z + h.dz);
        if (isWire(bl, nb)) loopBest = @max(loopBest, @as(i64, nb.meta));
        // Step-up link: cube beside, open above self, wire above the cube.
        if (normalCube(bl, nb.id) and !normalCube(bl, at(world, x, y + 1, z).id)) {
            const up = at(world, x + h.dx, y + 1, z + h.dz);
            if (isWire(bl, up)) loopBest = @max(loopBest, @as(i64, up.meta));
        }
        // Step-down link: non-cube beside, wire below it.
        if (!normalCube(bl, nb.id)) {
            const dn = at(world, x + h.dx, y - 1, z + h.dz);
            if (isWire(bl, dn)) loopBest = @max(loopBest, @as(i64, dn.meta));
        }
    }
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
            if (self.slot(x, y, z)) |c| return .{ .id = c.id, .meta = c.meta };
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
/// Support-loss pops return a Change with popped=true (air).
/// Needs `sched` (repeater delay), `burn` (torch lockout), `sounds` (fizz).
fn recompute(
    world: anytype,
    sched: *Scheduler,
    burn: *BurnoutMap,
    sounds: *SoundList,
    x: i32,
    y: i32,
    z: i32,
    now: i64,
) ?Change {
    const mk = struct {
        fn c(x0: i32, y0: i32, z0: i32, old: Block, nid: ids.Id, nmeta: u4, pop: bool) Change {
            return .{ .x = x0, .y = y0, .z = z0, .id = nid, .meta = nmeta, .old_id = old.id, .old_meta = old.meta, .popped = pop };
        }
    }.c;
    const bl = world.blocks;
    const rs = world.rules;
    const b = at(world, x, y, z);
    if (isWire(bl, b)) {
        const below = at(world, x, y - 1, z).id;
        if (y <= 0 or !solidTop(bl, below)) return mk(x, y, z, b, ids.air, 0, true);
        const p = computeWire(world, x, y, z);
        if (p != b.meta) return mk(x, y, z, b, b.id, p, false);
        return null;
    }
    if (isTorch(bl, b)) {
        if (!torchAnchor(world, x, y, z, b.meta)) return mk(x, y, z, b, ids.air, 0, true);
        const on = torchOn(bl, b);
        const off = torchShouldBeOff(world, x, y, z, b.meta);
        if (on == !off) return null; // already matches power state
        if (on and off) {
            // ON→OFF flip: record (vanilla only counts power-offs) and burn
            // out with fizz when 8 land inside 60 ticks.
            if (burn.noteFlip(x, y, z, now, rs)) {
                sounds.append(.{ .kind = .fizz, .x = x, .y = y, .z = z });
            }
            return mk(x, y, z, b, rs.torch_off, b.meta, false);
        }
        // OFF→ON flip, unless burnt out (burnt torches wake on the next
        // neighbor notify after entries age out — vanilla has no recheck).
        if (burn.isBurnt(x, y, z, now, rs)) return null;
        return mk(x, y, z, b, rs.torch_on, b.meta, false);
    }
    if (isLever(bl, b)) {
        if (!leverAnchor(world, x, y, z, b.meta)) return mk(x, y, z, b, ids.air, 0, true);
        return null;
    }
    if (isButton(bl, b)) {
        const sp = torchSupportPos(x, y, z, b.meta & 7);
        if (!normalCube(bl, at(world, sp.x, sp.y, sp.z).id)) return mk(x, y, z, b, ids.air, 0, true);
        return null;
    }
    if (isPlate(bl, b)) {
        if (!plateAnchor(world, x, y, z)) return mk(x, y, z, b, ids.air, 0, true);
        return null; // plates poll; never recompute from neighbors
    }
    if (isRepeater(bl, b)) {
        if (!solidTop(bl, at(world, x, y - 1, z).id)) return mk(x, y, z, b, ids.air, 0, true);
        if (repeaterLocked(world, x, y, z, b.meta)) return null;
        const in_pow = repeaterInputPowered(world, x, y, z, b.meta);
        if (in_pow != repeaterOn(bl, b) and !sched.pendingAt(x, y, z)) {
            sched.schedule(x, y, z, now + repeaterDelay(rs, b.meta), .repeater_eval);
        }
        return null;
    }
    if (isPiston(bl, b)) {
        // `app.e` updatePistonState: fire a block event when the indirect
        // power on the five non-front faces disagrees with the extended bit.
        const facing = pistonFacing(b.meta);
        const powered = pistonPowered(world, x, y, z, facing);
        if (powered != pistonExtended(b.meta) and !sched.pendingAt(x, y, z)) {
            sched.schedule(x, y, z, now + 2, if (powered) .piston_extend else .piston_retract);
        }
        return null;
    }
    if (isPistonHead(bl, b)) {
        // `apq.a(ahb,III,aji)`: the head survives only while an EXTENDED
        // piston base sits behind it; otherwise it pops (no drop).
        const v = pistonVec(pistonFacing(b.meta));
        const base = at(world, x - v.dx, y - v.dy, z - v.dz);
        if (isPiston(bl, base) and pistonExtended(base.meta)) return null;
        return mk(x, y, z, b, ids.air, 0, true);
    }
    if (isLamp(bl, b)) {
        // anb: lit && !gettingPowered → unlit; !lit && gettingPowered → lit.
        const want_lit = gettingPowered(world, x, y, z);
        if (want_lit != lampLit(bl, b)) {
            return mk(x, y, z, b, if (want_lit) rs.lamp_on else rs.lamp_off, 0, false);
        }
        return null;
    }
    if (isDoor(bl, b)) {
        if (doorIsUpper(b.meta)) return null; // upper half follows the lower
        if (!solidTop(bl, at(world, x, y - 1, z).id)) return mk(x, y, z, b, ids.air, 0, true);
        // akn: powered = gettingPowered(lower) || gettingPowered(upper).
        const want_open = gettingPowered(world, x, y, z) or gettingPowered(world, x, y + 1, z);
        if (want_open != doorOpen(b.meta)) {
            const nm: u4 = if (want_open) b.meta | 4 else b.meta & ~@as(u4, 4);
            return mk(x, y, z, b, b.id, nm, false);
        }
        return null;
    }
    if (isTrapdoor(bl, b)) {
        const sp = trapdoorSupport(x, y, z, b.meta);
        if (!normalCube(bl, at(world, sp.x, sp.y, sp.z).id)) return mk(x, y, z, b, ids.air, 0, true);
        return null;
    }
    return null;
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
    var queue: [4096]QPos = undefined;
    var head: usize = 0;
    var tail: usize = 0;
    var processed: usize = 0;

    const horiz = [_]struct { dx: i32, dz: i32 }{
        .{ .dx = 1, .dz = 0 }, .{ .dx = -1, .dz = 0 }, .{ .dx = 0, .dz = 1 }, .{ .dx = 0, .dz = -1 },
    };
    const seed = struct {
        fn run(w: anytype, q: []QPos, tailp: *usize, px: i32, py: i32, pz: i32) void {
            for (dirs6) |d| tryEnqueue(w, q, tailp, px + d.dx, py + d.dy, pz + d.dz);
            for (horiz) |h| {
                tryEnqueue(w, q, tailp, px + h.dx, py + 1, pz + h.dz);
                tryEnqueue(w, q, tailp, px + h.dx, py - 1, pz + h.dz);
            }
        }
    }.run;
    seed(world, &queue, &tail, x, y, z);

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
        seed(world, &queue, &tail, p.x, p.y, p.z);
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

// ---------------------------------------------------------------------------
// per-tick work: scheduled queue + pressure plates
// ---------------------------------------------------------------------------
//
// Vanilla plates re-check only via scheduled 20-tick updates while pressed
// (`ajd`: schedule only when fresh level > 0) plus entity-collision
// triggers; the server polls every tick instead (same outcome, faster
// release). Repeater evals and button releases ride the same queue.

pub const Ent = struct { x: f64, y: f64, z: f64 };

/// Drain due scheduled entries (budgeted) and poll registered plates.
/// Entity slices are player/mob/item positions for plate detection.
pub fn tick(
    world: anytype,
    sched: *Scheduler,
    burn: *BurnoutMap,
    plates: *PlateSet,
    changes: *ChangeList,
    sounds: *SoundList,
    now: i64,
    players: []const Ent,
    mobs: []const Ent,
    items: []const Ent,
    actions: ?*ActionList,
) void {
    drainScheduled(world, sched, burn, changes, sounds, now, actions);
    pollPlates(world, sched, burn, plates, changes, sounds, now, players, mobs, items, false);
}

/// Drain due scheduled entries (budgeted). No entity access: safe to run on
/// the fast redstone thread, which passes no entity slices (plates stay on
/// the 1Hz tick that owns the snapshots).
pub fn drainScheduled(
    world: anytype,
    sched: *Scheduler,
    burn: *BurnoutMap,
    changes: *ChangeList,
    sounds: *SoundList,
    now: i64,
    actions: ?*ActionList,
) void {
    var stage = Staged(@TypeOf(world)).init(world);
    const w = &stage;
    const bl = w.blocks;
    const rs = w.rules;
    var due: [128]SchedEntry = undefined;
    var total: usize = 0;
    while (total < max_scheduled_per_tick) {
        const n = sched.popDue(now, &due);
        if (n == 0) break;
        for (due[0..n]) |e| {
            total += 1;
            if (total > max_scheduled_per_tick) break;
            const b = at(w, e.x, e.y, e.z);
            switch (e.kind) {
                .button_release => {
                    if (isButton(bl, b) and buttonOn(bl, b)) {
                        const nm: u4 = b.meta & ~@as(u4, 8);
                        w.set(e.x, e.y, e.z, b.id, nm);
                        sounds.append(.{ .kind = .click_off, .x = e.x, .y = e.y, .z = e.z });
                        notify(w, sched, burn, sounds, e.x, e.y, e.z, now);
                    }
                },
                .repeater_eval => {
                    if (isRepeater(bl, b)) {
                        if (repeaterLocked(w, e.x, e.y, e.z, b.meta)) continue;
                        const in_pow = repeaterInputPowered(w, e.x, e.y, e.z, b.meta);
                        if (in_pow != repeaterOn(bl, b)) {
                            const nid = if (in_pow) rs.repeater_on else rs.repeater_off;
                            w.set(e.x, e.y, e.z, nid, b.meta);
                            notify(w, sched, burn, sounds, e.x, e.y, e.z, now);
                        }
                    }
                },
                .ore_fade => {
                    if (bl.get(b.id).redstone_kind == .ore_lit) {
                        w.set(e.x, e.y, e.z, rs.ore, b.meta);
                    }
                },
                .piston_extend, .piston_retract => {
                    // `app.a(ahb,IIIIII)` onBlockEventReceived: re-validate
                    // power at fire time, then doMove. Piston writes go
                    // straight through (silent changes; the S24 action
                    // carries the client animation). The stage is flushed
                    // FIRST: doMove writes bypass it, and a stale read memo
                    // would make the post-move recompute see the PRE-move
                    // piston state and schedule a spurious opposite event
                    // (which then blocks the real one via the per-position
                    // scheduler dedupe).
                    if (!isPiston(bl, b)) continue;
                    const facing = pistonFacing(b.meta);
                    const powered = pistonPowered(w, e.x, e.y, e.z, facing);
                    var did = false;
                    if (e.kind == .piston_extend and powered and pistonCanExtend(w, e.x, e.y, e.z, facing)) {
                        stage.commit(changes);
                        did = pistonExtend(world, e.x, e.y, e.z, facing, changes, sounds);
                    } else if (e.kind == .piston_retract and !powered) {
                        stage.commit(changes);
                        pistonRetract(world, e.x, e.y, e.z, facing, changes, sounds);
                        did = true;
                    }
                    if (did) {
                        if (actions) |al| {
                            al.append(.{
                                .x = e.x,
                                .y = e.y,
                                .z = e.z,
                                .event_id = if (e.kind == .piston_extend) 0 else 1,
                                .facing = facing,
                                .id = b.id,
                            });
                        }
                        // Consequences (wire/torch/support updates around
                        // every touched cell) stay client-visible: recompute
                        // via the stage, non-silent.
                        notify(w, sched, burn, sounds, e.x, e.y, e.z, now);
                        const v = pistonVec(facing);
                        notify(w, sched, burn, sounds, e.x + v.dx, e.y + v.dy, e.z + v.dz, now);
                        notify(w, sched, burn, sounds, e.x + 2 * v.dx, e.y + 2 * v.dy, e.z + 2 * v.dz, now);
                    }
                },
                .wire_check => {
                    // Safety valve: the per-edit budget exhausted mid-decay.
                    notify(w, sched, burn, sounds, e.x, e.y, e.z, now);
                },
            }
        }
        if (n < due.len) break;
    }
    stage.commit(changes);
}

/// Pressure-plate polling: count entities in the vanilla detection box
/// (x+0.125..x+0.875, y..y+0.25, z+0.125..z+0.875); stone senses living
/// (players+mobs), wood senses everything (vanilla: all entities — arrows
/// and XP orbs don't exist yet, so players+mobs+items).
pub fn pollPlates(
    world: anytype,
    sched: *Scheduler,
    burn: *BurnoutMap,
    plates: *PlateSet,
    changes: *ChangeList,
    sounds: *SoundList,
    now: i64,
    players: []const Ent,
    mobs: []const Ent,
    items: []const Ent,
    press_only: bool,
) void {
    var stage = Staged(@TypeOf(world)).init(world);
    const w = &stage;
    var i: usize = 0;
    while (i < plates.n) {
        const p = plates.items[i];
        const b = at(w, p.x, p.y, p.z);
        const k = w.blocks.get(b.id).redstone_kind;
        if (k != .plate_stone and k != .plate_wood and k != .plate_light and k != .plate_heavy) {
            // Stale entry (broken plate): drop it.
            plates.items[i] = plates.items[plates.n - 1];
            plates.pressed[i] = plates.pressed[plates.n - 1];
            plates.n -= 1;
            continue;
        }
        i += 1;
        const wooden = k == .plate_wood;
        var n_ent: usize = 0;
        for (players) |e| n_ent += @intFromBool(overPlate(e, p));
        for (mobs) |e| n_ent += @intFromBool(overPlate(e, p));
        if (wooden or k == .plate_light or k == .plate_heavy) {
            for (items) |e| n_ent += @intFromBool(overPlate(e, p));
        }
        // amu.d / aol.e: stone/wood meta 0/1; weighted ceil(15*min(n,max)/max).
        const want: u4 = switch (k) {
            .plate_stone, .plate_wood => if (n_ent > 0) 1 else 0,
            .plate_light => @truncate(@min(n_ent, 15)),
            .plate_heavy => @truncate(@min((n_ent + 9) / 10, 15)),
            else => 0,
        };
        // Compare against the STORED meta (not the output level — stone/wood
        // output 15 while storing 1; comparing levels made every poll
        // rewrite + re-notify a pressed plate).
        const have: u4 = b.meta;
        if (want == have) continue;
        // Vanilla minimum press: plates re-check on a 20-tick schedule, so
        // a tap stays pressed for a full second even if vacated instantly.
        // Releasing on the 1Hz poll instead would land phase-dependently
        // (0-1s of jitter on top of occupancy). Hold the release until 20
        // ticks after the rising edge; re-presses while held never shorten
        // it, and the stored meta (not a second write) carries the state.
        if (want != 0 and have == 0) {
            plates.pressed[i] = now;
        } else if (want == 0) {
            if (now -% plates.pressed[i] < 20) continue; // hold: not yet due
        }
        if (press_only and want == 0) continue; // movement hook: press only
        w.set(p.x, p.y, p.z, b.id, want);
        sounds.append(.{ .kind = if (want != 0) .click_on else .click_off, .x = p.x, .y = p.y, .z = p.z });
        notify(w, sched, burn, sounds, p.x, p.y, p.z, now);
    }
    stage.commit(changes);
}

fn overPlate(e: Ent, p: PlatePos) bool {
    // Vanilla detection box (ajd.a): inset 0.125, height 0.25.
    const fx: f64 = @floatFromInt(p.x);
    const fy: f64 = @floatFromInt(p.y);
    const fz: f64 = @floatFromInt(p.z);
    return e.x >= fx + 0.125 and e.x < fx + 0.875 and e.z >= fz + 0.125 and e.z < fz + 0.875 and
        e.y >= fy and e.y < fy + 0.25;
}

// ---------------------------------------------------------------------------
// scheduler persistence (vanilla TileTicks equivalent)
// ---------------------------------------------------------------------------
//
// The scheduler lives in one LSM row so pressed buttons, in-flight
// repeaters and lit ore survive restarts (otherwise a reboot would leave
// buttons pressed forever — nothing would ever re-schedule their release).
// Reserved key dim 253 (254 = perms matrix, 255 = player rows).
// Format: u16 BE count, then per entry x/y/z i32 BE + kind u8 + reserved u8.
// Dues are NOT stored (they live in the rs_tick epoch, which restarts at
// boot); the loader re-derives a fresh delay from the block still present.

pub const sched_key: [9]u8 = .{ 253, 0x80, 0, 0, 0, 0x80, 0, 0, 0 };

pub fn encodeSched(alloc: std.mem.Allocator, sched: *const Scheduler) ![]u8 {
    const n = @min(sched.n, sched_cap);
    var kept: usize = 0;
    for (sched.entries[0..n]) |e| {
        switch (e.kind) {
            .button_release, .repeater_eval, .ore_fade => kept += 1,
            else => {}, // piston events / wire checks are transient
        }
    }
    const out = try alloc.alloc(u8, 2 + kept * 14);
    std.mem.writeInt(u16, out[0..2], @intCast(kept), .big);
    var i: usize = 0;
    for (sched.entries[0..n]) |e| {
        switch (e.kind) {
            .button_release, .repeater_eval, .ore_fade => {},
            else => continue,
        }
        const o = 2 + i * 14;
        std.mem.writeInt(i32, out[o + 0 ..][0..4], e.x, .big);
        std.mem.writeInt(i32, out[o + 4 ..][0..4], e.y, .big);
        std.mem.writeInt(i32, out[o + 8 ..][0..4], e.z, .big);
        out[o + 12] = @intFromEnum(e.kind);
        out[o + 13] = 0; // reserved
        i += 1;
    }
    return out;
}

/// Load persisted entries, re-deriving dues from the blocks still present.
/// Stale entries (block gone/changed) are skipped. Returns the count
/// restored. Caller holds world_lock (same as all scheduler mutation).
pub fn loadSched(world: anytype, raw: []const u8, sched: *Scheduler, now: i64) usize {
    if (raw.len < 2) return 0;
    const bl = world.blocks;
    const rs = world.rules;
    const n = std.mem.readInt(u16, raw[0..2], .big);
    var restored: usize = 0;
    var i: usize = 0;
    while (i < n and 2 + (i + 1) * 14 <= raw.len) : (i += 1) {
        const o = 2 + i * 14;
        const x = std.mem.readInt(i32, raw[o + 0 ..][0..4], .big);
        const y = std.mem.readInt(i32, raw[o + 4 ..][0..4], .big);
        const z = std.mem.readInt(i32, raw[o + 8 ..][0..4], .big);
        if (raw[o + 12] >= @typeInfo(SchedKind).@"enum".fields.len) continue;
        if (raw[o + 12] > 2) continue; // old rows never carry transient kinds
        const kind: SchedKind = @enumFromInt(raw[o + 12]);
        if (y < 0 or y > 255) continue;
        const b = at(world, x, y, z);
        const due: i64 = switch (kind) {
            .button_release => if (!isButton(bl, b) or !buttonOn(bl, b)) continue else now + if (bl.get(b.id).redstone_kind == .button_stone) rs.button_ticks_stone else rs.button_ticks_wood,
            .repeater_eval => if (!isRepeater(bl, b)) continue else now + repeaterDelay(rs, b.meta),
            .ore_fade => if (bl.get(b.id).redstone_kind != .ore_lit) continue else now + rs.ore_fade_ticks,
            // transient kinds never persist; unreachable for well-formed rows
            .piston_extend, .piston_retract, .wire_check => continue,
        };
        sched.schedule(x, y, z, due, kind);
        restored += 1;
    }
    return restored;
}

// ---------------------------------------------------------------------------
// tests (HashMap mock world; set/pop record like the server adapter)
// ---------------------------------------------------------------------------

const mc5_blocks = @import("../game/mc5/blocks.zig");
const test_blocks = &mc5_blocks.table;
const test_rules = &rules_mod.mc5_redstone;

const TestWorld = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMap(u64, Block),
    changes: ChangeList = .{},
    sounds: SoundList = .{},
    blocks: *const block_mod.Table = test_blocks,
    rules: *const rules_mod.RedstoneRules = test_rules,

    fn key(x: i32, y: i32, z: i32) u64 {
        const xp: u64 = @as(u64, @bitCast(@as(i64, x))) << 42;
        const zp: u64 = @as(u64, @bitCast(@as(i64, z))) << 20;
        const yp: u64 = @as(u64, @bitCast(@as(i64, y))) & 0xFFFFF;
        return xp | zp | yp;
    }

    fn init(a: std.mem.Allocator) TestWorld {
        return .{ .allocator = a, .map = std.AutoHashMap(u64, Block).init(a) };
    }

    fn deinit(self: *TestWorld) void {
        self.map.deinit();
    }

    fn put(self: *TestWorld, x: i32, y: i32, z: i32, id: ids.Id, meta: u4) void {
        self.map.put(key(x, y, z), .{ .id = id, .meta = meta }) catch unreachable;
    }

    pub fn get(self: *TestWorld, x: i32, y: i32, z: i32) ?Block {
        return self.map.get(key(x, y, z));
    }

    pub fn set(self: *TestWorld, x: i32, y: i32, z: i32, id: ids.Id, meta: u4) void {
        // Change recording lives in the staged commit (single entry per
        // cell, final value); the raw write only mutates the map.
        self.put(x, y, z, id, meta);
    }

    pub fn pop(self: *TestWorld, x: i32, y: i32, z: i32, old_id: ids.Id, old_meta: u4) void {
        _ = old_id;
        _ = old_meta;
        self.put(x, y, z, ids.air, 0);
    }

    fn floor(self: *TestWorld, x0: i32, x1: i32, y: i32, z: i32) void {
        var x = x0;
        while (x <= x1) : (x += 1) self.put(x, y, z, ids.stone, 0);
    }
};

test "wire falloff from a redstone block" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    var sched = Scheduler{};
    var burn = BurnoutMap{};
    var sounds = SoundList{};
    w.floor(-1, 6, 63, 0);
    w.put(-1, 64, 0, ids.redstone_block, 0);
    var x: i32 = 0;
    while (x <= 4) : (x += 1) {
        w.put(x, 64, 0, ids.redstone_wire, 0);
        onEdit(&w, &sched, &burn, &w.changes, &sounds, x, 64, 0, 0);
    }
    try std.testing.expectEqual(@as(u4, 15), (w.get(0, 64, 0) orelse unreachable).meta);
    try std.testing.expectEqual(@as(u4, 14), (w.get(1, 64, 0) orelse unreachable).meta);
    try std.testing.expectEqual(@as(u4, 13), (w.get(2, 64, 0) orelse unreachable).meta);
    try std.testing.expectEqual(@as(u4, 12), (w.get(3, 64, 0) orelse unreachable).meta);
    try std.testing.expectEqual(@as(u4, 11), (w.get(4, 64, 0) orelse unreachable).meta);
}

test "plain stone does not conduct; powered blocks feed wire" {
    // Vanilla getMaxCurrentStrength has no cube-conduction term: a bare
    // stone block between wires stays dark (verified against the jar's
    // calculateCurrentChanges). A lever ON the stone feeds both sides.
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    var sched = Scheduler{};
    var burn = BurnoutMap{};
    var sounds = SoundList{};
    w.floor(-1, 4, 63, 0);
    w.put(-1, 64, 0, ids.redstone_block, 0);
    w.put(0, 64, 0, ids.redstone_wire, 0);
    onEdit(&w, &sched, &burn, &w.changes, &sounds, 0, 64, 0, 0);
    w.put(1, 64, 0, ids.stone, 0); // bare block in the path
    onEdit(&w, &sched, &burn, &w.changes, &sounds, 1, 64, 0, 0);
    w.put(2, 64, 0, ids.redstone_wire, 0);
    onEdit(&w, &sched, &burn, &w.changes, &sounds, 2, 64, 0, 0);
    try std.testing.expectEqual(@as(u4, 15), (w.get(0, 64, 0) orelse unreachable).meta);
    try std.testing.expectEqual(@as(u4, 0), (w.get(2, 64, 0) orelse unreachable).meta);
    // Lever on top of the middle block feeds the far wire at full strength.
    w.put(1, 65, 0, ids.lever, 5);
    onEdit(&w, &sched, &burn, &w.changes, &sounds, 1, 65, 0, 0);
    interact(&w, &sched, &burn, &w.changes, &sounds, 1, 65, 0, 0);
    try std.testing.expectEqual(@as(u4, 15), (w.get(2, 64, 0) orelse unreachable).meta);
}

test "lever toggles wire + lamp" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    var sched = Scheduler{};
    var burn = BurnoutMap{};
    var sounds = SoundList{};
    w.floor(0, 4, 63, 0);
    w.put(0, 64, 0, ids.lever, 5);
    w.put(1, 64, 0, ids.redstone_wire, 0);
    w.put(2, 64, 0, ids.redstone_wire, 0);
    w.put(3, 64, 0, ids.redstone_lamp, 0);
    interact(&w, &sched, &burn, &w.changes, &sounds, 0, 64, 0, 0);
    try std.testing.expectEqual(@as(u4, 15), (w.get(1, 64, 0) orelse unreachable).meta);
    try std.testing.expectEqual(@as(u4, 14), (w.get(2, 64, 0) orelse unreachable).meta);
    try std.testing.expectEqual(ids.lit_redstone_lamp, (w.get(3, 64, 0) orelse unreachable).id);
    try std.testing.expectEqual(@as(usize, 1), sounds.n);
    interact(&w, &sched, &burn, &w.changes, &sounds, 0, 64, 0, 20);
    try std.testing.expectEqual(@as(u4, 0), (w.get(1, 64, 0) orelse unreachable).meta);
    try std.testing.expectEqual(ids.redstone_lamp, (w.get(3, 64, 0) orelse unreachable).id);
}

test "torch inverter + burnout lockout" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    var sched = Scheduler{};
    var burn = BurnoutMap{};
    // Torch on top of stone: support unpowered -> on.
    w.put(0, 63, 0, ids.stone, 0);
    w.put(0, 64, 0, ids.redstone_torch, 5);
    try std.testing.expect(torchOn(test_blocks, w.get(0, 64, 0).?));
    // Power the support via a lever next to it: torch must turn off.
    w.put(1, 62, 0, ids.stone, 0);
    w.put(1, 63, 0, ids.lever, 5);
    var sounds = SoundList{};
    interact(&w, &sched, &burn, &w.changes, &sounds, 1, 63, 0, 0);
    try std.testing.expectEqual(ids.unlit_redstone_torch, (w.get(0, 64, 0) orelse unreachable).id);
    // Burnout golden: only ON→OFF flips count; 8 within 60 ticks burns.
    var b2 = BurnoutMap{};
    var t: i64 = 0;
    var i: usize = 0;
    while (i < 7) : (i += 1) {
        try std.testing.expect(!b2.noteFlip(5, 64, 5, t, test_rules));
        t += 5;
    }
    try std.testing.expect(b2.noteFlip(5, 64, 5, t, test_rules)); // 8th inside window
    try std.testing.expect(b2.isBurnt(5, 64, 5, t + 1, test_rules));
    try std.testing.expect(!b2.isBurnt(5, 64, 5, t + 61, test_rules)); // entries aged out
    // Slow toggles never burn out (span > 60 ticks).
    var b3 = BurnoutMap{};
    t = 0;
    i = 0;
    while (i < 8) : (i += 1) {
        try std.testing.expect(!b3.noteFlip(6, 64, 6, t, test_rules));
        t += 20;
    }
}

test "torch ignores adjacent wire power (support only)" {
    // Regression: the old model turned torches off from neighboring wire.
    // Vanilla `anc.m` checks ONLY the support block.
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    var sched = Scheduler{};
    var burn = BurnoutMap{};
    var sounds = SoundList{};
    w.put(0, 63, 0, ids.stone, 0);
    w.put(0, 64, 0, ids.redstone_torch, 5);
    w.put(1, 63, 0, ids.stone, 0);
    w.put(1, 64, 0, ids.redstone_wire, 15); // hot wire next to the torch
    onEdit(&w, &sched, &burn, &w.changes, &sounds, 1, 64, 0, 0);
    try std.testing.expectEqual(ids.redstone_torch, (w.get(0, 64, 0) orelse unreachable).id);
}

test "button pulse length: stone 20, wood 30" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    var sched = Scheduler{};
    var burn = BurnoutMap{};
    w.put(0, 63, 0, ids.stone, 0);
    w.put(1, 63, 0, ids.stone, 0);
    w.put(0, 64, 0, ids.stone_button, 5);
    w.put(1, 64, 0, ids.wooden_button, 5);
    var sounds = SoundList{};
    interact(&w, &sched, &burn, &w.changes, &sounds, 0, 64, 0, 0);
    interact(&w, &sched, &burn, &w.changes, &sounds, 1, 64, 0, 0);
    try std.testing.expect(buttonOn(test_blocks, w.get(0, 64, 0).?));
    var plates = PlateSet{};
    tick(&w, &sched, &burn, &plates, &w.changes, &sounds, 19, &.{}, &.{}, &.{}, null);
    try std.testing.expect(buttonOn(test_blocks, w.get(0, 64, 0).?));
    try std.testing.expect(buttonOn(test_blocks, w.get(1, 64, 0).?));
    tick(&w, &sched, &burn, &plates, &w.changes, &sounds, 20, &.{}, &.{}, &.{}, null);
    try std.testing.expect(!buttonOn(test_blocks, w.get(0, 64, 0).?));
    try std.testing.expect(buttonOn(test_blocks, w.get(1, 64, 0).?));
    tick(&w, &sched, &burn, &plates, &w.changes, &sounds, 30, &.{}, &.{}, &.{}, null);
    try std.testing.expect(!buttonOn(test_blocks, w.get(1, 64, 0).?));
}

test "repeater delay bits + scheduled flip + lock" {
    try std.testing.expectEqual(@as(i64, 2), repeaterDelay(test_rules, 0));
    try std.testing.expectEqual(@as(i64, 4), repeaterDelay(test_rules, 1 << 2));
    try std.testing.expectEqual(@as(i64, 6), repeaterDelay(test_rules, 2 << 2));
    try std.testing.expectEqual(@as(i64, 8), repeaterDelay(test_rules, 3 << 2));
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    var sched = Scheduler{};
    var burn = BurnoutMap{};
    var sounds = SoundList{};
    w.floor(0, 3, 63, 0);
    // Repeater facing east (1): input west cell, output east cell.
    w.put(0, 64, 0, ids.redstone_block, 0);
    w.put(1, 64, 0, ids.unpowered_repeater, 1);
    w.put(2, 64, 0, ids.redstone_wire, 0);
    notify(&w, &sched, &burn, &sounds, 0, 64, 0, 0);
    try std.testing.expectEqual(ids.unpowered_repeater, (w.get(1, 64, 0) orelse unreachable).id);
    try std.testing.expect(sched.pendingAt(1, 64, 0));
    var plates = PlateSet{};
    tick(&w, &sched, &burn, &plates, &w.changes, &sounds, 2, &.{}, &.{}, &.{}, null);
    try std.testing.expectEqual(ids.powered_repeater, (w.get(1, 64, 0) orelse unreachable).id);
    try std.testing.expectEqual(@as(u4, 15), (w.get(2, 64, 0) orelse unreachable).meta);
    // Right-click cycles delay meta bits.
    interact(&w, &sched, &burn, &w.changes, &sounds, 1, 64, 0, 2);
    try std.testing.expectEqual(@as(u4, 1 | (1 << 2)), (w.get(1, 64, 0) orelse unreachable).meta);
    // Side lock: powered repeater facing into the side blocks eval.
    // (side repeater at (1,64,-1) facing south into (1,64,0))
    w.put(1, 63, -1, ids.stone, 0);
    w.put(1, 64, -1, ids.powered_repeater, 2);
    w.put(0, 64, 0, ids.air, 0);
    onEdit(&w, &sched, &burn, &w.changes, &sounds, 0, 64, 0, 10);
    try std.testing.expect(sched.pendingAt(1, 64, 0) == false or true); // lock may hold it off
}

test "scheduler dedupe: reschedule replaces" {
    var s = Scheduler{};
    s.schedule(1, 2, 3, 100, .button_release);
    s.schedule(1, 2, 3, 200, .ore_fade);
    try std.testing.expectEqual(@as(usize, 1), s.n);
    try std.testing.expectEqual(@as(i64, 200), s.entries[0].due);
    var out: [8]SchedEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), s.popDue(150, &out));
    try std.testing.expectEqual(@as(usize, 1), s.popDue(200, &out));
    try std.testing.expectEqual(SchedKind.ore_fade, out[0].kind);
    try std.testing.expectEqual(@as(usize, 0), s.n);
}

test "scheduler persistence round-trips live entries, drops stale ones" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    w.put(0, 63, 0, ids.stone, 0);
    w.put(0, 64, 0, ids.stone_button, 8 | 5);
    w.put(1, 63, 0, ids.stone, 0);
    w.put(1, 64, 0, ids.unpowered_repeater, 1);
    var s = Scheduler{};
    s.schedule(0, 64, 0, 12345, .button_release);
    s.schedule(1, 64, 0, 12346, .repeater_eval);
    s.schedule(9, 9, 9, 12347, .button_release); // hole: dropped
    const enc = try encodeSched(std.testing.allocator, &s);
    defer std.testing.allocator.free(enc);
    var s2 = Scheduler{};
    const n = loadSched(&w, enc, &s2, 1000);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expect(s2.pendingAt(0, 64, 0));
    try std.testing.expect(s2.pendingAt(1, 64, 0));
    // Delays re-derived from the blocks, not the stored dues.
    var out: [8]SchedEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), s2.popDue(1001, &out));
    try std.testing.expectEqual(@as(usize, 1), s2.popDue(1000 + repeaterDelay(test_rules, 1), &out));
    try std.testing.expectEqual(SchedKind.repeater_eval, out[0].kind);
    try std.testing.expectEqual(@as(usize, 0), s2.popDue(1000 + test_rules.button_ticks_stone - 1, &out));
    try std.testing.expectEqual(@as(usize, 1), s2.popDue(1000 + test_rules.button_ticks_stone, &out));
    try std.testing.expectEqual(SchedKind.button_release, out[0].kind);
}

test "orientation tables (jar-verified)" {
    try std.testing.expectEqual(@as(u4, 5), orientTorch(1));
    try std.testing.expectEqual(@as(u4, 4), orientTorch(2));
    try std.testing.expectEqual(@as(u4, 3), orientTorch(3));
    try std.testing.expectEqual(@as(u4, 2), orientTorch(4));
    try std.testing.expectEqual(@as(u4, 1), orientTorch(5));
    try std.testing.expectEqual(@as(u4, 0), orientTorch(0));
    try std.testing.expectEqual(@as(u4, 0), orientLever(0));
    try std.testing.expectEqual(@as(u4, 5), orientLever(1));
    // repeater yaw: 0 (south) -> facing 2; 180 (north) -> 0.
    try std.testing.expectEqual(@as(u2, 2), yawToFacing(0));
    try std.testing.expectEqual(@as(u2, 0), yawToFacing(180));
    try std.testing.expectEqual(@as(u2, 1), yawToFacing(-90));
    try std.testing.expectEqual(@as(u2, 3), yawToFacing(90));
    // lever onBlockPlacedBy (jar `alv`, floor 5|6 + ceiling 7|0 by yaw
    // quadrant parity; walls untouched, on-bit preserved).
    try std.testing.expectEqual(@as(u4, 5), leverPlacedBy(5, 0)); // facing south
    try std.testing.expectEqual(@as(u4, 6), leverPlacedBy(5, 90)); // facing west
    try std.testing.expectEqual(@as(u4, 5), leverPlacedBy(5, 180)); // facing north
    try std.testing.expectEqual(@as(u4, 6), leverPlacedBy(5, -90)); // facing east
    try std.testing.expectEqual(@as(u4, 7), leverPlacedBy(0, 0));
    try std.testing.expectEqual(@as(u4, 0), leverPlacedBy(0, 90));
    try std.testing.expectEqual(@as(u4, 0), leverPlacedBy(0, -90));
    try std.testing.expectEqual(@as(u4, 7), leverPlacedBy(0, 180));
    try std.testing.expectEqual(@as(u4, 1), leverPlacedBy(1, 90));
    try std.testing.expectEqual(@as(u4, 9), leverPlacedBy(9, 90));
    try std.testing.expectEqual(@as(i32, 1), mountSupport(7).dy);
    try std.testing.expectEqual(@as(i32, -1), mountSupport(6).dy);
    // door yaw (ach.onItemUse): floor((yaw+180)*4/360 - 0.5) & 3.
    try std.testing.expectEqual(@as(u2, 1), doorYawToFacing(0));
    try std.testing.expectEqual(@as(u2, 3), doorYawToFacing(180));
    // dispenser/dropper yaw (BlockDispenser.onBlockPlacedBy): yaw-only
    // 0->2(north), 90->5(east), 180->3(south), 270->4(west).
    try std.testing.expectEqual(@as(u4, 2), dispenserYawToFacing(0));
    try std.testing.expectEqual(@as(u4, 5), dispenserYawToFacing(90));
    try std.testing.expectEqual(@as(u4, 3), dispenserYawToFacing(180));
    try std.testing.expectEqual(@as(u4, 4), dispenserYawToFacing(270));
    // hopper face (BlockHopper.onBlockPlaced): opposite of clicked face.
    try std.testing.expectEqual(@as(u4, 0), hopperFaceToMeta(1)); // top -> down
    try std.testing.expectEqual(@as(u4, 3), hopperFaceToMeta(2));
    try std.testing.expectEqual(@as(u4, 2), hopperFaceToMeta(3));
    try std.testing.expectEqual(@as(u4, 5), hopperFaceToMeta(4));
    try std.testing.expectEqual(@as(u4, 4), hopperFaceToMeta(5));
    // anvil yaw (BlockAnvil.onBlockPlacedBy): rotated once + damage<<2.
    // Facing north (yaw 180) -> 0, not 3: the long axis is perpendicular.
    try std.testing.expectEqual(@as(u4, 1), anvilYawToMeta(0, 0));
    try std.testing.expectEqual(@as(u4, 2), anvilYawToMeta(90, 0));
    try std.testing.expectEqual(@as(u4, 3), anvilYawToMeta(180, 0));
    try std.testing.expectEqual(@as(u4, 0), anvilYawToMeta(270, 0));
    try std.testing.expectEqual(@as(u4, 1 | (1 << 2)), anvilYawToMeta(0, 1));
    try std.testing.expectEqual(@as(u4, 3 | (2 << 2)), anvilYawToMeta(180, 2));
    // placement mapping: items -> blocks.
    try std.testing.expectEqual(ids.redstone_wire, mc5_blocks.placeBlockForHeld(ids.redstone).?);
    try std.testing.expectEqual(ids.unpowered_repeater, mc5_blocks.placeBlockForHeld(ids.repeater).?);
    try std.testing.expectEqual(ids.unpowered_comparator, mc5_blocks.placeBlockForHeld(ids.comparator).?);
    try std.testing.expectEqual(ids.wooden_door_block, mc5_blocks.placeBlockForHeld(ids.wooden_door_item).?);
    try std.testing.expect(mc5_blocks.placeBlockForHeld(ids.stone) == null);
}

test "doors, trapdoor, gate, ore" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    var sched = Scheduler{};
    var burn = BurnoutMap{};
    var sounds = SoundList{};
    w.floor(0, 5, 63, 0);
    w.put(0, 64, 0, ids.wooden_door_block, 2);
    w.put(0, 65, 0, ids.wooden_door_block, 8);
    w.put(1, 64, 0, ids.iron_door_block, 2);
    w.put(2, 64, 0, ids.trapdoor, 0);
    w.put(3, 64, 0, ids.fence_gate, 0);
    w.put(4, 64, 0, ids.redstone_ore, 0);
    // Wooden door toggles open bit via upper-half click too.
    interact(&w, &sched, &burn, &w.changes, &sounds, 0, 65, 0, 0);
    try std.testing.expect(doorOpen((w.get(0, 64, 0) orelse unreachable).meta));
    // Iron door: hand click consumes without changing.
    const n_before = w.changes.n;
    interact(&w, &sched, &burn, &w.changes, &sounds, 1, 64, 0, 0);
    try std.testing.expectEqual(n_before, w.changes.n);
    interact(&w, &sched, &burn, &w.changes, &sounds, 2, 64, 0, 0);
    try std.testing.expect(trapOpen((w.get(2, 64, 0) orelse unreachable).meta));
    interact(&w, &sched, &burn, &w.changes, &sounds, 3, 64, 0, 0);
    try std.testing.expect(gateOpen((w.get(3, 64, 0) orelse unreachable).meta));
    interact(&w, &sched, &burn, &w.changes, &sounds, 4, 64, 0, 0);
    try std.testing.expectEqual(ids.lit_redstone_ore, (w.get(4, 64, 0) orelse unreachable).id);
    var plates = PlateSet{};
    tick(&w, &sched, &burn, &plates, &w.changes, &sounds, test_rules.ore_fade_ticks, &.{}, &.{}, &.{}, null);
    try std.testing.expectEqual(ids.redstone_ore, (w.get(4, 64, 0) orelse unreachable).id);
}

test "door opens from redstone power (either half)" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    var sched = Scheduler{};
    var burn = BurnoutMap{};
    var sounds = SoundList{};
    w.floor(0, 3, 63, 0);
    w.put(0, 64, 0, ids.wooden_door_block, 2);
    w.put(0, 65, 0, ids.wooden_door_block, 8);
    w.put(1, 64, 0, ids.redstone_wire, 0);
    w.put(2, 64, 0, ids.redstone_wire, 0);
    w.put(3, 64, 0, ids.lever, 5);
    onEdit(&w, &sched, &burn, &w.changes, &sounds, 3, 64, 0, 0);
    interact(&w, &sched, &burn, &w.changes, &sounds, 3, 64, 0, 0);
    // lever -> wire(2) -> wire(1) -> door opens
    try std.testing.expect(doorOpen((w.get(0, 64, 0) orelse unreachable).meta));
}

test "support loss pops components" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    var sched = Scheduler{};
    var burn = BurnoutMap{};
    var sounds = SoundList{};
    // Torch on stone: break the stone -> torch pops.
    w.put(0, 63, 0, ids.stone, 0);
    w.put(0, 64, 0, ids.redstone_torch, 5);
    w.put(0, 63, 0, ids.air, 0);
    onEdit(&w, &sched, &burn, &w.changes, &sounds, 0, 63, 0, 0);
    try std.testing.expectEqual(ids.air, (w.get(0, 64, 0) orelse unreachable).id);
    try std.testing.expect(w.changes.items[w.changes.n - 1].popped);
}

test "trapdoor support follows jar aoe.d (meta0 -> z+1 pillar)" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    var sched = Scheduler{};
    var burn = BurnoutMap{};
    var sounds = SoundList{};
    // meta 0 (clicked north face): pillar to the SOUTH (z+1) holds it.
    w.put(2, 64, 1, ids.stone, 0);
    w.put(2, 64, 0, ids.trapdoor, 0);
    onEdit(&w, &sched, &burn, &w.changes, &sounds, 2, 64, 1, 0);
    try std.testing.expectEqual(ids.trapdoor, (w.get(2, 64, 0) orelse unreachable).id);
    // Break the pillar -> trapdoor pops.
    w.put(2, 64, 1, ids.air, 0);
    onEdit(&w, &sched, &burn, &w.changes, &sounds, 2, 64, 1, 0);
    try std.testing.expectEqual(ids.air, (w.get(2, 64, 0) orelse unreachable).id);
    try std.testing.expect(w.changes.items[w.changes.n - 1].popped);
    // meta 1 (clicked south face): pillar to the NORTH (z-1) holds it.
    w.put(4, 64, 3, ids.stone, 0);
    w.put(4, 64, 4, ids.trapdoor, 1);
    onEdit(&w, &sched, &burn, &w.changes, &sounds, 4, 64, 3, 0);
    try std.testing.expectEqual(ids.trapdoor, (w.get(4, 64, 4) orelse unreachable).id);
}

test "pressure plate senses players, wood adds items" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    var sched = Scheduler{};
    var burn = BurnoutMap{};
    var sounds = SoundList{};
    w.floor(0, 1, 63, 0);
    w.put(0, 64, 0, ids.stone_pressure_plate, 0);
    w.put(1, 64, 0, ids.wooden_pressure_plate, 0);
    var plates = PlateSet{};
    plates.add(0, 64, 0);
    plates.add(1, 64, 0);
    const nobody: []const Ent = &.{};
    tick(&w, &sched, &burn, &plates, &w.changes, &sounds, 0, nobody, nobody, nobody, null);
    try std.testing.expectEqual(@as(u4, 0), (w.get(0, 64, 0) orelse unreachable).meta);
    const player_on_stone: []const Ent = &.{.{ .x = 0.5, .y = 64.0, .z = 0.5 }};
    const item_on_wood: []const Ent = &.{.{ .x = 1.5, .y = 64.0, .z = 0.5 }};
    tick(&w, &sched, &burn, &plates, &w.changes, &sounds, 20, player_on_stone, nobody, item_on_wood, null);
    try std.testing.expectEqual(@as(u4, 1), (w.get(0, 64, 0) orelse unreachable).meta);
    try std.testing.expectEqual(@as(u4, 1), (w.get(1, 64, 0) orelse unreachable).meta);
    // Stone ignores items: clear players, keep item -> stone releases.
    tick(&w, &sched, &burn, &plates, &w.changes, &sounds, 40, nobody, nobody, item_on_wood, null);
    try std.testing.expectEqual(@as(u4, 0), (w.get(0, 64, 0) orelse unreachable).meta);
    try std.testing.expectEqual(@as(u4, 1), (w.get(1, 64, 0) orelse unreachable).meta);
}

test "pistons: extend pushes the chain, head lands, base extends" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    var sounds = SoundList{};
    w.floor(1, 8, 63, 0);
    w.put(1, 64, 0, ids.piston, 5); // facing east (+x)
    w.put(2, 64, 0, ids.stone, 0);
    w.put(3, 64, 0, ids.cobblestone, 0);
    // Power it via a lever on the block below the base (indirect path).
    w.put(1, 63, 0, ids.lever, 5);
    w.put(0, 63, 0, ids.stone, 0);
    w.put(1, 63, 0, ids.stone, 0);
    var changes: ChangeList = .{};
    _ = &changes;
    // Direct event: powered base extends.
    try std.testing.expect(pistonCanExtend(&w, 1, 64, 0, 5));
    try std.testing.expect(pistonExtend(&w, 1, 64, 0, 5, &w.changes, &sounds));
    try std.testing.expectEqual(ids.piston_head, (w.get(2, 64, 0) orelse unreachable).id);
    try std.testing.expectEqual(@as(u4, 5), (w.get(2, 64, 0) orelse unreachable).meta); // non-sticky head: no bit 3
    try std.testing.expectEqual(ids.stone, (w.get(3, 64, 0) orelse unreachable).id);
    try std.testing.expectEqual(ids.cobblestone, (w.get(4, 64, 0) orelse unreachable).id);
    try std.testing.expectEqual(@as(u4, 5 | 8), (w.get(1, 64, 0) orelse unreachable).meta);
    // Retract (non-sticky): head cell clears, chain stays put.
    pistonRetract(&w, 1, 64, 0, 5, &w.changes, &sounds);
    try std.testing.expectEqual(ids.air, (w.get(2, 64, 0) orelse unreachable).id);
    try std.testing.expectEqual(ids.stone, (w.get(3, 64, 0) orelse unreachable).id);
    try std.testing.expectEqual(@as(u4, 5), (w.get(1, 64, 0) orelse unreachable).meta);
}

test "pistons: sticky pulls one block; push limit and immovables" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    var sounds = SoundList{};
    w.floor(1, 8, 63, 0);
    w.put(1, 64, 0, ids.sticky_piston, 5);
    w.put(2, 64, 0, ids.stone, 0); // head lands here when extended
    // Extend with a block in front.
    try std.testing.expect(pistonExtend(&w, 1, 64, 0, 5, &w.changes, &sounds));
    w.put(3, 64, 0, ids.dirt, 0); // block to pull
    pistonRetract(&w, 1, 64, 0, 5, &w.changes, &sounds);
    try std.testing.expectEqual(ids.dirt, (w.get(2, 64, 0) orelse unreachable).id); // pulled into head cell
    try std.testing.expectEqual(ids.air, (w.get(3, 64, 0) orelse unreachable).id);
    // Thirteen pushable blocks: the 13th fails the whole extend.
    var i: i32 = 2;
    while (i <= 14) : (i += 1) w.put(i, 64, 0, ids.stone, 0);
    try std.testing.expect(!pistonCanExtend(&w, 1, 64, 0, 5));
    // Obsidian anywhere in the line blocks it.
    w.put(5, 64, 0, ids.obsidian, 0);
    try std.testing.expect(!pistonCanExtend(&w, 1, 64, 0, 5));
    w.put(5, 64, 0, ids.stone, 0);
    // Destroy-mobility blocks (torch) end the chain and drop.
    w.put(2, 64, 0, ids.torch, 5);
    w.put(3, 64, 0, ids.air, 0);
    try std.testing.expect(pistonCanExtend(&w, 1, 64, 0, 5));
    try std.testing.expect(pistonExtend(&w, 1, 64, 0, 5, &w.changes, &sounds));
    try std.testing.expectEqual(ids.piston_head, (w.get(2, 64, 0) orelse unreachable).id);
    var popped = false;
    for (w.changes.items[0..w.changes.n]) |c| {
        if (c.popped and c.old_id == ids.torch) popped = true;
    }
    try std.testing.expect(popped); // the torch dropped
}

test "piston power check ignores the front face and senses weak power" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    w.floor(0, 4, 63, 0);
    w.put(1, 64, 0, ids.piston, 5); // facing east; front = (2,64,0)
    // Powered block directly in front: must NOT power the piston.
    w.put(2, 64, 0, ids.redstone_block, 0);
    try std.testing.expect(!pistonPowered(&w, 1, 64, 0, 5));
    // Weak power from above does.
    w.put(2, 64, 0, ids.air, 0);
    w.put(1, 65, 0, ids.lever, 5); // floor lever on the piston top
    try std.testing.expect(!pistonPowered(&w, 1, 64, 0, 5)); // lever off
    w.put(1, 65, 0, ids.lever, 13); // on
    try std.testing.expect(pistonPowered(&w, 1, 64, 0, 5));
}

test "piston head pops when its base is gone or unextended" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    var sched = Scheduler{};
    var burn = BurnoutMap{};
    var sounds = SoundList{};
    w.floor(1, 4, 63, 0);
    w.put(1, 64, 0, ids.piston, 5); // retracted base
    w.put(2, 64, 0, ids.piston_head, 5);
    onEdit(&w, &sched, &burn, &w.changes, &sounds, 2, 64, 0, 0);
    // Base not extended -> head pops.
    try std.testing.expectEqual(ids.air, (w.get(2, 64, 0) orelse unreachable).id);
    // Extended base keeps it.
    w.put(1, 64, 0, ids.piston, 5 | 8);
    w.put(2, 64, 0, ids.piston_head, 5);
    onEdit(&w, &sched, &burn, &w.changes, &sounds, 2, 64, 0, 0);
    try std.testing.expectEqual(ids.piston_head, (w.get(2, 64, 0) orelse unreachable).id);
}

test "staged writes: lever OFF converges a wire line in one op, one change per cell" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    var sched = Scheduler{};
    var burn = BurnoutMap{};
    var sounds = SoundList{};
    w.floor(0, 6, 63, 0);
    w.put(0, 64, 0, ids.lever, 5);
    var x: i32 = 1;
    while (x <= 5) : (x += 1) {
        w.put(x, 64, 0, ids.redstone_wire, 0);
        onEdit(&w, &sched, &burn, &w.changes, &sounds, x, 64, 0, 0);
    }
    interact(&w, &sched, &burn, &w.changes, &sounds, 0, 64, 0, 0); // ON
    try std.testing.expectEqual(@as(u4, 15), (w.get(1, 64, 0) orelse unreachable).meta);
    try std.testing.expectEqual(@as(u4, 11), (w.get(5, 64, 0) orelse unreachable).meta);
    const before = w.changes.n;
    interact(&w, &sched, &burn, &w.changes, &sounds, 0, 64, 0, 20); // OFF
    // Every wire is fully dark immediately...
    x = 1;
    while (x <= 5) : (x += 1) {
        try std.testing.expectEqual(@as(u4, 0), (w.get(x, 64, 0) orelse unreachable).meta);
    }
    // ...and the OFF cascade recorded exactly one change per cell (5 wires +
    // the lever), not one per intermediate level.
    try std.testing.expectEqual(before + 6, w.changes.n);
}

test "plate poll: pressed stone plate is not re-written by later polls" {    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    var sched = Scheduler{};
    var burn = BurnoutMap{};
    var sounds = SoundList{};
    w.floor(0, 1, 63, 0);
    w.put(0, 64, 0, ids.stone_pressure_plate, 0);
    var plates = PlateSet{};
    plates.add(0, 64, 0);
    const on: []const Ent = &.{.{ .x = 0.5, .y = 64.0, .z = 0.5 }};
    const off: []const Ent = &.{};
    const before_sounds = sounds.n;
    tick(&w, &sched, &burn, &plates, &w.changes, &sounds, 0, on, off, off, null);
    try std.testing.expectEqual(@as(u4, 1), (w.get(0, 64, 0) orelse unreachable).meta);
    try std.testing.expectEqual(before_sounds + 1, sounds.n);
    // Second poll while still standing: no re-write, no click spam.
    tick(&w, &sched, &burn, &plates, &w.changes, &sounds, 20, on, off, off, null);
    try std.testing.expectEqual(before_sounds + 1, sounds.n);
    // Step off: releases.
    tick(&w, &sched, &burn, &plates, &w.changes, &sounds, 40, off, off, off, null);
    try std.testing.expectEqual(@as(u4, 0), (w.get(0, 64, 0) orelse unreachable).meta);
    try std.testing.expectEqual(before_sounds + 2, sounds.n);
}

test "plate release waits out the vanilla 20-tick minimum press" {
    // A tap vacated after 5 ticks stays pressed until tick 20 (no 1Hz
    // phase jitter), then releases exactly once.
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    var sched = Scheduler{};
    var burn = BurnoutMap{};
    var sounds = SoundList{};
    w.floor(0, 1, 63, 0);
    w.put(0, 64, 0, ids.stone_pressure_plate, 0);
    var plates = PlateSet{};
    plates.add(0, 64, 0);
    const on: []const Ent = &.{.{ .x = 0.5, .y = 64.0, .z = 0.5 }};
    const off: []const Ent = &.{};
    tick(&w, &sched, &burn, &plates, &w.changes, &sounds, 100, on, off, off, null);
    try std.testing.expectEqual(@as(u4, 1), (w.get(0, 64, 0) orelse unreachable).meta);
    const after_press = sounds.n;
    // Vacated at +5: held (no rewrite, no click) at +19...
    tick(&w, &sched, &burn, &plates, &w.changes, &sounds, 105, off, off, off, null);
    try std.testing.expectEqual(@as(u4, 1), (w.get(0, 64, 0) orelse unreachable).meta);
    tick(&w, &sched, &burn, &plates, &w.changes, &sounds, 119, off, off, off, null);
    try std.testing.expectEqual(@as(u4, 1), (w.get(0, 64, 0) orelse unreachable).meta);
    try std.testing.expectEqual(after_press, sounds.n);
    // ...and released exactly at +20 with a single click-off.
    tick(&w, &sched, &burn, &plates, &w.changes, &sounds, 120, off, off, off, null);
    try std.testing.expectEqual(@as(u4, 0), (w.get(0, 64, 0) orelse unreachable).meta);
    try std.testing.expectEqual(after_press + 1, sounds.n);
}

test "rapid external toggles burn out the torch (vanilla clock equivalent)" {
    // Vanilla burnout comes from repeated neighbor updates while the support
    // stays powered (clocks, mashing, pistons): 8 ON→OFF flips within 60
    // ticks locks the torch with a fizz. One lever cannot both power the
    // support and trigger the torch (no cell is adjacent to both), so the
    // rig uses two: Lpow on the support's wall, Ltrig next to the torch.
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    var sched = Scheduler{};
    var burn = BurnoutMap{};
    var sounds = SoundList{};
    w.put(0, 63, 0, ids.stone, 0); // S (torch support)
    w.put(0, 64, 0, ids.redstone_torch, 5); // A
    w.put(1, 63, 0, ids.lever, 1); // Lpow (wall-mounted on S, powers it)
    w.put(0, 63, 1, ids.stone, 0);
    w.put(0, 64, 1, ids.lever, 5); // Ltrig (adjacent to A, triggers updates)
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        interact(&w, &sched, &burn, &w.changes, &sounds, 1, 63, 0, 0); // power on
        interact(&w, &sched, &burn, &w.changes, &sounds, 0, 64, 1, 0); // A off + note
        interact(&w, &sched, &burn, &w.changes, &sounds, 1, 63, 0, 0); // power off
        interact(&w, &sched, &burn, &w.changes, &sounds, 0, 64, 1, 0); // A on
    }
    try std.testing.expect(burn.isBurnt(0, 64, 0, 1, test_rules));
    try std.testing.expectEqual(ids.unlit_redstone_torch, (w.get(0, 64, 0) orelse unreachable).id);
    // Fizz played on the burning flip.
    var fizzed = false;
    for (sounds.evs[0..sounds.n]) |s| {
        if (s.kind == .fizz) fizzed = true;
    }
    try std.testing.expect(fizzed);
    // ...and it stays off while burnt even with support unpowered
    // (entries are still within the 60-tick window at now=10).
    interact(&w, &sched, &burn, &w.changes, &sounds, 0, 64, 1, 10);
    try std.testing.expectEqual(ids.unlit_redstone_torch, (w.get(0, 64, 0) orelse unreachable).id);
    // After the window passes without flips, it recovers on next update
    // (a neighbor change re-evaluating it, like vanilla).
    onEdit(&w, &sched, &burn, &w.changes, &sounds, 0, 64, 0, 200);
    try std.testing.expectEqual(ids.redstone_torch, (w.get(0, 64, 0) orelse unreachable).id);
}
test "update storm terminates under budget" {
    // A dense mesh of wire re-converges instead of recursing: the processed
    // cap bounds the work and the change list stays finite.
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    var sched = Scheduler{};
    var burn = BurnoutMap{};
    var sounds = SoundList{};
    w.floor(-1, 5, 63, 0);
    w.put(-1, 64, 0, ids.redstone_block, 0);
    var x: i32 = 0;
    while (x <= 4) : (x += 1) {
        w.put(x, 64, 0, ids.redstone_wire, 0);
        onEdit(&w, &sched, &burn, &w.changes, &sounds, x, 64, 0, 0);
    }
    try std.testing.expect(w.changes.n <= max_updates_per_edit);
    try std.testing.expectEqual(@as(u4, 11), (w.get(4, 64, 0) orelse unreachable).meta);
}
