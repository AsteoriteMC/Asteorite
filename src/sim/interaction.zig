//! Version-neutral block interaction helpers (C4).
//!
//! Reach and the face/adjacent-cell transform are shared by block breaking,
//! placement and (later) entity interaction. The profile supplies the numeric
//! rule set; this module owns only the geometry and bounds checks.

const std = @import("std");
const game_rules = @import("../game/rules.zig");

pub const Rules = game_rules.InteractionRules;

pub const Target = struct { x: i32, y: i32, z: i32 };

/// 0=-Y, 1=+Y, 2=-Z, 3=+Z, 4=-X, 5=+X. Returns the adjacent cell, or null
/// for a missing/out-of-range face or a target outside the legacy world
/// height.
pub fn targetCell(x: i32, y: u8, z: i32, face: i8) ?Target {
    if (face < 0 or face > 5) return null;
    var tx = x;
    var ty: i32 = y;
    var tz = z;
    switch (face) {
        0 => ty -= 1,
        1 => ty += 1,
        2 => tz -= 1,
        3 => tz += 1,
        4 => tx -= 1,
        5 => tx += 1,
        else => unreachable,
    }
    if (ty < 0 or ty > 255) return null;
    return .{ .x = tx, .y = ty, .z = tz };
}

/// Block-center reach check from an eye point. `<` (not `<=`) preserves the
/// 1.7.10 boundary behavior.
pub fn inReach(eye_x: f64, eye_y: f64, eye_z: f64, x: i32, y: u8, z: i32, reach: f32) bool {
    const dx = @as(f64, @floatFromInt(x)) + 0.5 - eye_x;
    const dy = @as(f64, @floatFromInt(y)) + 0.5 - eye_y;
    const dz = @as(f64, @floatFromInt(z)) + 0.5 - eye_z;
    const r = @as(f64, reach);
    return dx * dx + dy * dy + dz * dz < r * r;
}

/// Vanilla cactus contact (`BlockCactus.onEntityCollidedWithBlock`): the
/// cactus collision box is inset by 1/16 on XZ with full block height, and
/// any AABB overlap with the player (0.6 wide, 1.8 tall) deals damage —
/// brushing past a cactus hurts, not just standing inside its cell.
/// Pure geometry; the caller resolves which cells actually are cactus.
pub fn cactusOverlapsPlayer(bx: i32, by: i32, bz: i32, px: f64, py: f64, pz: f64) bool {
    const lo = 0.0625;
    const min_x: f64 = @as(f64, @floatFromInt(bx)) + lo;
    const max_x: f64 = @as(f64, @floatFromInt(bx)) + 1.0 - lo;
    const min_y: f64 = @as(f64, @floatFromInt(by));
    const max_y: f64 = @as(f64, @floatFromInt(by)) + 1.0;
    const min_z: f64 = @as(f64, @floatFromInt(bz)) + lo;
    const max_z: f64 = @as(f64, @floatFromInt(bz)) + 1.0 - lo;
    return px - 0.3 < max_x and px + 0.3 > min_x and
        py < max_y and py + 1.8 > min_y and
        pz - 0.3 < max_z and pz + 0.3 > min_z;
}

test "interaction: face targets and bounds" {
    try std.testing.expectEqual(Target{ .x = 1, .y = 63, .z = 2 }, targetCell(1, 64, 2, 0).?);
    try std.testing.expectEqual(Target{ .x = 1, .y = 65, .z = 2 }, targetCell(1, 64, 2, 1).?);
    try std.testing.expectEqual(Target{ .x = 1, .y = 64, .z = 1 }, targetCell(1, 64, 2, 2).?);
    try std.testing.expectEqual(Target{ .x = 1, .y = 64, .z = 3 }, targetCell(1, 64, 2, 3).?);
    try std.testing.expectEqual(Target{ .x = 0, .y = 64, .z = 2 }, targetCell(1, 64, 2, 4).?);
    try std.testing.expectEqual(Target{ .x = 2, .y = 64, .z = 2 }, targetCell(1, 64, 2, 5).?);
    try std.testing.expect(targetCell(0, 0, 0, 0) == null);
    try std.testing.expect(targetCell(0, 255, 0, 1) == null);
    try std.testing.expect(targetCell(0, 10, 0, 6) == null);
    try std.testing.expect(targetCell(0, 10, 0, -1) == null);
}

test "interaction: reach uses block centers and strict boundary" {
    try std.testing.expect(inReach(0.5, 1.62, 0.5, 5, 0, 0, 6.0));
    try std.testing.expect(!inReach(0.5, 1.62, 0.5, 6, 0, 0, 6.0));
    try std.testing.expect(inReach(0.5, 1.62, 0.5, 0, 0, 0, 6.0));
    try std.testing.expect(!inReach(0.5, 1.62, 0.5, 20, 0, 0, 6.0));
}

test "interaction: cactus contact is AABB overlap, not cell identity" {
    // Standing inside the cactus cell.
    try std.testing.expect(cactusOverlapsPlayer(12, 64, 8, 12.5, 64.0, 8.5));
    // Brushing past: center 0.7 from the cactus center (adjacent cell).
    // Old cell-identity check missed this; vanilla damages on overlap.
    try std.testing.expect(cactusOverlapsPlayer(12, 64, 8, 11.8, 64.0, 8.5));
    // Just out of reach: 0.8 away clears the 0.3 + 0.4375 overlap band.
    try std.testing.expect(!cactusOverlapsPlayer(12, 64, 8, 11.7, 64.0, 8.5));
    // Head-height cactus grazes a tall player; low cactus underfoot does not.
    try std.testing.expect(cactusOverlapsPlayer(12, 65, 8, 12.5, 64.0, 8.5));
    try std.testing.expect(!cactusOverlapsPlayer(12, 62, 8, 12.5, 64.0, 8.5));
    try std.testing.expect(!cactusOverlapsPlayer(12, 66, 8, 12.5, 64.0, 8.5));
}
