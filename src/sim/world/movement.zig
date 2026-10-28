//! Version-neutral movement bookkeeping (C4).
//!
//! The network edge owns position packets and the server owns collision.
//! This module owns the rule-driven side effects that must stay identical
//! across profiles: grounded movement exhaustion, jump cost, fall-distance
//! accumulation and the landing hand-off for the serve thread.

const std = @import("std");
const game_rules = @import("../../game/rules.zig");

pub const Rules = game_rules.MovementRules;

pub const Transition = struct {
    fall_acc: f32,
    jump_exhaustion: f32 = 0,
    landing: ?f32 = null,
};

pub fn horizontalDistance(dx: f64, dz: f64) f32 {
    return @floatCast(@sqrt(dx * dx + dz * dz));
}

/// Exhaustion for a grounded horizontal move, or 0 when the move is below
/// the vanilla noise threshold.
pub fn moveExhaustion(hd: f32, sprinting: bool, rules: Rules) f32 {
    if (hd <= rules.min_move) return 0;
    return hd * (if (sprinting) rules.sprint_exhaustion else rules.walk_exhaustion);
}

/// Ground-transition state update. `dy` is the vertical delta of this frame;
/// `prev_on_ground`/`on_ground` are the prior and current client flags.
/// Landings report the accumulated fall distance; the caller stashes it with
/// the pre-update position for the serve thread's water/fall-damage check.
pub fn groundTransition(
    prev_on_ground: bool,
    on_ground: bool,
    dy: f64,
    sprinting: bool,
    fall_acc: f32,
    rules: Rules,
) Transition {
    var out = Transition{ .fall_acc = fall_acc };
    if (prev_on_ground and !on_ground and dy > 0) {
        out.jump_exhaustion = if (sprinting) rules.sprint_jump_exhaustion else rules.jump_exhaustion;
    }
    if (!on_ground and dy < 0) out.fall_acc += @as(f32, @floatCast(-dy));
    if (!prev_on_ground and on_ground) {
        // Include the landing frame's own descent: vanilla counts the full
        // fall including the final move into the ground, but this frame
        // runs with on_ground set so the arm above skipped it. Dropping it
        // loses up to a full packet-step (~0.5-0.7 near impact speed),
        // pushing the effective damage threshold from 3.0 up to ~3.7.
        var dist = out.fall_acc;
        if (dy < 0) dist += @as(f32, @floatCast(-dy));
        if (dist > 0) out.landing = dist;
        out.fall_acc = 0;
    }
    // Invariant: grounded never accumulates (covers flag flaps where the
    // transition above did not run but a stale fall_acc rode along).
    if (on_ground) out.fall_acc = 0;
    return out;
}

pub fn addExhaustion(current: f32, amount: f32, rules: Rules) f32 {
    return @min(current + amount, rules.max_exhaustion);
}

test "movement: walk/sprint/jump exhaustion" {
    const r = Rules{};
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), moveExhaustion(5.0, false, r), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), moveExhaustion(5.0, true, r), 1e-6);
    try std.testing.expectEqual(@as(f32, 0), moveExhaustion(0.01, true, r));
    try std.testing.expectApproxEqAbs(@as(f32, 39.8), addExhaustion(39.0, 0.8, r), 1e-6);
    try std.testing.expectEqual(@as(f32, 40.0), addExhaustion(39.5, 1.0, r));
}

test "movement: fall accumulation and landing hand-off" {
    const r = Rules{};
    var t = groundTransition(true, false, -0.4, false, 0, r);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), t.fall_acc, 1e-6);
    try std.testing.expect(t.landing == null);
    t = groundTransition(false, false, -1.0, false, t.fall_acc, r);
    try std.testing.expectApproxEqAbs(@as(f32, 1.4), t.fall_acc, 1e-6);
    t = groundTransition(false, true, -0.2, false, t.fall_acc, r);
    try std.testing.expectApproxEqAbs(@as(f32, 1.6), t.landing.?, 1e-6);
    try std.testing.expectEqual(@as(f32, 0), t.fall_acc);

    // Jump only charges when the server was grounded and the client rises.
    t = groundTransition(true, false, 0.42, true, 0, r);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), t.jump_exhaustion, 1e-6);
    t = groundTransition(false, false, 0.42, true, 0, r);
    try std.testing.expectEqual(@as(f32, 0), t.jump_exhaustion);
}

test "movement: landing frame counts its own descent (3.0/3.5 threshold)" {
    const r = Rules{};
    // 3.5-block fall at impact speed: last airborne steps ~0.6, landing
    // step ~0.4. Dropping the landing dy measured 3.1 (no damage... and
    // faster falls lost more); vanilla counts the full 3.5 (1 heart).
    var acc: f32 = 0;
    var t = groundTransition(true, false, -0.1, false, acc, r);
    acc = t.fall_acc;
    t = groundTransition(false, false, -0.6, false, acc, r);
    acc = t.fall_acc;
    t = groundTransition(false, false, -0.6, false, acc, r);
    acc = t.fall_acc;
    t = groundTransition(false, false, -0.6, false, acc, r);
    acc = t.fall_acc;
    t = groundTransition(false, false, -0.6, false, acc, r);
    acc = t.fall_acc;
    t = groundTransition(false, false, -0.6, false, acc, r);
    acc = t.fall_acc;
    t = groundTransition(false, true, -0.4, false, acc, r);
    try std.testing.expectApproxEqAbs(@as(f32, 3.5), t.landing.?, 1e-6);
    // Exact 3.0 stays damage-free: ceil(3.0 - 3.0) = 0.
    acc = 0;
    t = groundTransition(true, false, -0.5, false, acc, r);
    acc = t.fall_acc;
    t = groundTransition(false, false, -0.5, false, acc, r);
    acc = t.fall_acc;
    t = groundTransition(false, false, -0.5, false, acc, r);
    acc = t.fall_acc;
    t = groundTransition(false, false, -0.5, false, acc, r);
    acc = t.fall_acc;
    t = groundTransition(false, false, -0.5, false, acc, r);
    acc = t.fall_acc;
    t = groundTransition(false, true, -0.5, false, acc, r);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), t.landing.?, 1e-6);
}
