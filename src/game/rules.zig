//! Profile rules consumed by shared engines.
//!
//! C2 added the redstone rule set and C4 added interaction/movement. Keep
//! fields only when an engine reads them; profile deltas land here as the
//! corresponding component does.

const std = @import("std");
const ids = @import("../ids.zig");

/// Numbers, toggles and component state ids for the redstone/piston engine.
/// Defaults are the 1.7.10 values; a later profile overrides only what
/// changed.
pub const RedstoneRules = struct {
    wire: ids.Id = .redstone_wire,
    torch_on: ids.Id = .redstone_torch,
    torch_off: ids.Id = .unlit_redstone_torch,
    repeater_on: ids.Id = .powered_repeater,
    repeater_off: ids.Id = .unpowered_repeater,
    lamp_on: ids.Id = .lit_redstone_lamp,
    lamp_off: ids.Id = .redstone_lamp,
    ore: ids.Id = .redstone_ore,
    ore_lit: ids.Id = .lit_redstone_ore,
    piston: ids.Id = .piston,
    sticky_piston: ids.Id = .sticky_piston,
    piston_head: ids.Id = .piston_head,
    redstone_block: ids.Id = .redstone_block,

    button_ticks_stone: i64 = 20,
    button_ticks_wood: i64 = 30,
    ore_fade_ticks: i64 = 30,
    repeater_delays: [4]i64 = .{ 2, 4, 6, 8 },
    torch_burnout_window: i64 = 60,
    torch_burnout_toggles: usize = 8,
    /// `app.h` push-line limit: 1.7.10 allows 12 blocks.
    piston_push_limit: u8 = 12,
    /// Torches burn out after repeated ON->OFF flips within the window.
    torch_burnout: bool = true,
};

pub const InteractionRules = struct {
    eye_height: f32 = 1.62,
    reach: f32 = 6.0,
};

pub const MovementRules = struct {
    walk_exhaustion: f32 = 0.01,
    sprint_exhaustion: f32 = 0.1,
    jump_exhaustion: f32 = 0.2,
    sprint_jump_exhaustion: f32 = 0.8,
    max_exhaustion: f32 = 40.0,
    min_move: f32 = 0.01,
};

/// Height/section/lighting rules consumed by world and view code. A later
/// profile (1.18+) changes these instead of scattering `u8 y` assumptions.
pub const HeightRules = struct {
    min_y: i16 = 0,
    max_y: i16 = 255,
    section_count: u16 = 16,
    lighting_model: []const u8 = "pre_1_18",
};

/// Player game mode (vanilla 0-2). Gameplay gates compare variants, never
/// raw ints; `wire()`/`fromWire()` are the only int boundary (packets,
/// player rows). A later profile extends this instead of scattering `== 1`.
pub const GameMode = enum(u8) {
    survival = 0,
    creative = 1,
    adventure = 2,

    pub fn isCreative(self: GameMode) bool {
        return self == .creative;
    }

    /// Wire/persistence value (1.7.10: survival 0, creative 1).
    pub fn wire(self: GameMode) u8 {
        return @intFromEnum(self);
    }

    /// Wire/persistence value back to a mode; unknown clamps to survival
    /// (vanilla loads out-of-range rows as survival).
    pub fn fromWire(v: u8) GameMode {
        return switch (v) {
            0 => .survival,
            1 => .creative,
            2 => .adventure,
            else => .survival,
        };
    }

    pub fn name(self: GameMode) []const u8 {
        return @tagName(self);
    }

    /// Config/chat spelling back to a mode: full names + single letters
    /// (case-insensitive) + wire digits, else null. Same contract as the
    /// /gamemode argument parser (which delegates here).
    pub fn parse(s: []const u8) ?GameMode {
        if (std.ascii.eqlIgnoreCase(s, "survival") or std.ascii.eqlIgnoreCase(s, "s")) return .survival;
        if (std.ascii.eqlIgnoreCase(s, "creative") or std.ascii.eqlIgnoreCase(s, "c")) return .creative;
        if (std.ascii.eqlIgnoreCase(s, "adventure") or std.ascii.eqlIgnoreCase(s, "a")) return .adventure;
        const v = std.fmt.parseInt(i64, s, 10) catch return null;
        if (v < 0 or v >= std.enums.values(GameMode).len) return null;
        return @enumFromInt(v);
    }
};

/// World difficulty (vanilla 0-3). Hunger/environment gates compare
/// variants; the wire value stays a u8 at packet parse sites.
pub const Difficulty = enum(u8) {
    peaceful = 0,
    easy = 1,
    normal = 2,
    hard = 3,

    pub fn wire(self: Difficulty) u8 {
        return @intFromEnum(self);
    }

    pub fn fromWire(v: u8) Difficulty {
        return switch (v) {
            0 => .peaceful,
            1 => .easy,
            2 => .normal,
            3 => .hard,
            else => .normal,
        };
    }

    pub fn name(self: Difficulty) []const u8 {
        return @tagName(self);
    }

    /// Config/chat spelling back to a difficulty: full names + single
    /// letters (case-insensitive) + wire digits, else null. Same contract
    /// as the /difficulty argument parser (which delegates here).
    pub fn parse(s: []const u8) ?Difficulty {
        if (std.ascii.eqlIgnoreCase(s, "peaceful") or std.ascii.eqlIgnoreCase(s, "p")) return .peaceful;
        if (std.ascii.eqlIgnoreCase(s, "easy") or std.ascii.eqlIgnoreCase(s, "e")) return .easy;
        if (std.ascii.eqlIgnoreCase(s, "normal") or std.ascii.eqlIgnoreCase(s, "n")) return .normal;
        if (std.ascii.eqlIgnoreCase(s, "hard") or std.ascii.eqlIgnoreCase(s, "h")) return .hard;
        const v = std.fmt.parseInt(i64, s, 10) catch return null;
        if (v < 0 or v >= std.enums.values(Difficulty).len) return null;
        return @enumFromInt(v);
    }
};

pub const Rules = struct {
    redstone: RedstoneRules = .{},
    interaction: InteractionRules = .{},
    movement: MovementRules = .{},
    height: HeightRules = .{},
};

pub const mc5: Rules = .{ .redstone = .{}, .interaction = .{}, .movement = .{}, .height = .{} };

/// Keep the defaults stable as a single named value for tests and adapters.
pub const mc5_redstone: RedstoneRules = mc5.redstone;

test "mc5 redstone rules are the 1.7.10 values" {
    try std.testing.expectEqual(@as(i64, 20), mc5.redstone.button_ticks_stone);
    try std.testing.expectEqual(@as(i64, 30), mc5.redstone.button_ticks_wood);
    try std.testing.expectEqual(@as(i64, 30), mc5.redstone.ore_fade_ticks);
    try std.testing.expectEqualSlices(i64, &.{ 2, 4, 6, 8 }, &mc5.redstone.repeater_delays);
    try std.testing.expectEqual(@as(u8, 12), mc5.redstone.piston_push_limit);
    try std.testing.expect(mc5.redstone.torch_burnout);
    try std.testing.expectEqual(ids.redstone_wire, mc5.redstone.wire);
    try std.testing.expectEqual(ids.redstone_torch, mc5.redstone.torch_on);
    try std.testing.expectEqual(ids.unlit_redstone_torch, mc5.redstone.torch_off);
    try std.testing.expectEqual(ids.powered_repeater, mc5.redstone.repeater_on);
    try std.testing.expectEqual(ids.unpowered_repeater, mc5.redstone.repeater_off);
    try std.testing.expectEqual(ids.lit_redstone_lamp, mc5.redstone.lamp_on);
    try std.testing.expectEqual(ids.redstone_lamp, mc5.redstone.lamp_off);
    try std.testing.expectEqual(ids.lit_redstone_ore, mc5.redstone.ore_lit);
    try std.testing.expectEqual(ids.sticky_piston, mc5.redstone.sticky_piston);
    try std.testing.expectEqual(ids.piston_head, mc5.redstone.piston_head);
}

test "mc5 interaction and movement rules are the 1.7.10 values" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.62), mc5.interaction.eye_height, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), mc5.interaction.reach, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.01), mc5.movement.walk_exhaustion, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), mc5.movement.sprint_exhaustion, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), mc5.movement.jump_exhaustion, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), mc5.movement.sprint_jump_exhaustion, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 40.0), mc5.movement.max_exhaustion, 1e-6);
}
