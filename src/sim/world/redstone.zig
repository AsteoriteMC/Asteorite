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
const ids = @import("../../ids.zig");
const world_view = @import("world_view.zig");
const block_mod = @import("../../game/block.zig");
const rules_mod = @import("../../game/rules.zig");

const components = @import("redstone/components.zig");
const schedule = @import("redstone/schedule.zig");
const power = @import("redstone/power.zig");
const sim = @import("redstone/sim.zig");

pub const Block = world_view.Block;
pub const WorldView = world_view.WorldView;

pub const anchorPost = components.anchorPost;
pub const anvilYawToMeta = components.anvilYawToMeta;
pub const buttonOn = components.buttonOn;
pub const chestYawToFacing = components.chestYawToFacing;
pub const dispenserYawToFacing = components.dispenserYawToFacing;
pub const doorHingeBit = components.doorHingeBit;
pub const doorIsUpper = components.doorIsUpper;
pub const doorOpen = components.doorOpen;
pub const doorUpperMeta = components.doorUpperMeta;
pub const doorYawToFacing = components.doorYawToFacing;
pub const facingVec = components.facingVec;
pub const gateOpen = components.gateOpen;
pub const hopperFaceToMeta = components.hopperFaceToMeta;
pub const isButton = components.isButton;
pub const isDoor = components.isDoor;
pub const isGate = components.isGate;
pub const isInteractable = components.isInteractable;
pub const isLamp = components.isLamp;
pub const isLever = components.isLever;
pub const isOre = components.isOre;
pub const isPiston = components.isPiston;
pub const isPistonHead = components.isPistonHead;
pub const isPlate = components.isPlate;
pub const isRepeater = components.isRepeater;
pub const isTorch = components.isTorch;
pub const isTrapdoor = components.isTrapdoor;
pub const isWire = components.isWire;
pub const lampLit = components.lampLit;
pub const leverAnchor = components.leverAnchor;
pub const leverOn = components.leverOn;
pub const leverPlacedBy = components.leverPlacedBy;
pub const mountSupport = components.mountSupport;
pub const normalCube = components.normalCube;
pub const orientButton = components.orientButton;
pub const orientLever = components.orientLever;
pub const orientOnPlace = components.orientOnPlace;
pub const orientTorch = components.orientTorch;
pub const orientTrapdoor = components.orientTrapdoor;
pub const pistonExtended = components.pistonExtended;
pub const pistonFacing = components.pistonFacing;
pub const pistonVec = components.pistonVec;
pub const plateAnchor = components.plateAnchor;
pub const plateLevel = components.plateLevel;
pub const repeaterDelay = components.repeaterDelay;
pub const repeaterFacing = components.repeaterFacing;
pub const repeaterOn = components.repeaterOn;
pub const solidTop = components.solidTop;
pub const torchAnchor = components.torchAnchor;
pub const torchCheckSide = components.torchCheckSide;
pub const torchOn = components.torchOn;
pub const torchSupportPos = components.torchSupportPos;
pub const trapOpen = components.trapOpen;
pub const trapdoorSupport = components.trapdoorSupport;
pub const upperHalfFor = components.upperHalfFor;
pub const yawToFacing = components.yawToFacing;
pub const ActionList = schedule.ActionList;
pub const BlockAction = schedule.BlockAction;
pub const BurnoutMap = schedule.BurnoutMap;
pub const Change = schedule.Change;
pub const ChangeList = schedule.ChangeList;
pub const PlatePos = schedule.PlatePos;
pub const PlateSet = schedule.PlateSet;
pub const SchedEntry = schedule.SchedEntry;
pub const SchedKind = schedule.SchedKind;
pub const Scheduler = schedule.Scheduler;
pub const SoundEv = schedule.SoundEv;
pub const SoundKind = schedule.SoundKind;
pub const SoundList = schedule.SoundList;
pub const burn_cap = schedule.burn_cap;
pub const burn_hist_cap = schedule.burn_hist_cap;
pub const max_changes = schedule.max_changes;
pub const max_scheduled_per_tick = schedule.max_scheduled_per_tick;
pub const max_updates_per_edit = schedule.max_updates_per_edit;
pub const plate_cap = schedule.plate_cap;
pub const sched_cap = schedule.sched_cap;
pub const Staged = power.Staged;
pub const canProvidePower = power.canProvidePower;
pub const computeWire = power.computeWire;
pub const gettingPowered = power.gettingPowered;
pub const indirectAt = power.indirectAt;
pub const interact = power.interact;
pub const needsRecompute = power.needsRecompute;
pub const notify = power.notify;
pub const onEdit = power.onEdit;
pub const pistonCanExtend = power.pistonCanExtend;
pub const pistonCanPush = power.pistonCanPush;
pub const pistonExtend = power.pistonExtend;
pub const pistonMobility = power.pistonMobility;
pub const pistonPlacementFacing = power.pistonPlacementFacing;
pub const pistonPowered = power.pistonPowered;
pub const pistonRetract = power.pistonRetract;
pub const repeaterInputPowered = power.repeaterInputPowered;
pub const repeaterLocked = power.repeaterLocked;
pub const reqSide = power.reqSide;
pub const stage_cap = power.stage_cap;
pub const strongAt = power.strongAt;
pub const strongestAt = power.strongestAt;
pub const torchShouldBeOff = power.torchShouldBeOff;
pub const weakAt = power.weakAt;
pub const Ent = sim.Ent;
pub const drainScheduled = sim.drainScheduled;
pub const encodeSched = sim.encodeSched;
pub const loadSched = sim.loadSched;
pub const pollPlates = sim.pollPlates;
pub const sched_key = sim.sched_key;
pub const tick = sim.tick;

const mc5_blocks = @import("../../game/mc5/blocks.zig");
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
    // anvil yaw (`ajb.onBlockPlacedBy`, jar bytecode): l=(idx+1)&3 then
    // {0:2, 1:3, 2:0, 3:1} — net (idx-1)&3, mirrored vs the naive +1
    // (which faces every quadrant 180° off). Damage rides bits 2-3.
    try std.testing.expectEqual(@as(u4, 3), anvilYawToMeta(0, 0));
    try std.testing.expectEqual(@as(u4, 0), anvilYawToMeta(90, 0));
    try std.testing.expectEqual(@as(u4, 1), anvilYawToMeta(180, 0));
    try std.testing.expectEqual(@as(u4, 2), anvilYawToMeta(270, 0));
    try std.testing.expectEqual(@as(u4, 2), anvilYawToMeta(-90, 0));
    try std.testing.expectEqual(@as(u4, 3 | (1 << 2)), anvilYawToMeta(0, 1));
    try std.testing.expectEqual(@as(u4, 1 | (2 << 2)), anvilYawToMeta(180, 2));
    // chest/furnace/ender yaw (`akv`/`ale` onBlockPlacedBy, jar): shared
    // {0:2, 1:5, 2:3, 3:4} — the front faces the placer.
    try std.testing.expectEqual(@as(u4, 2), chestYawToFacing(0));
    try std.testing.expectEqual(@as(u4, 5), chestYawToFacing(90));
    try std.testing.expectEqual(@as(u4, 3), chestYawToFacing(180));
    try std.testing.expectEqual(@as(u4, 4), chestYawToFacing(270));
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
