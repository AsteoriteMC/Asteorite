//! Version-neutral block interaction helpers (C4).
//!
//! Reach and the face/adjacent-cell transform are shared by block breaking,
//! placement and (later) entity interaction. The profile supplies the numeric
//! rule set; this module owns only the geometry and bounds checks.

const std = @import("std");
const game_rules = @import("../../game/rules.zig");

pub const Rules = game_rules.InteractionRules;

pub const Target = struct { x: i32, y: i32, z: i32 };

/// Face ids: 0=-Y, 1=+Y, 2=-Z, 3=+Z, 4=-X, 5=+X.
pub const max_face: i8 = 5;
/// Legacy world height (1.7.10: y 0..255).
pub const world_max_y: i32 = 255;

/// Returns the adjacent cell, or null for a missing/out-of-range face or
/// a target outside the legacy world height.
pub fn targetCell(x: i32, y: u8, z: i32, face: i8) ?Target {
    if (face < 0 or face > max_face) return null;
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
    if (ty < 0 or ty > world_max_y) return null;
    return .{ .x = tx, .y = ty, .z = tz };
}

/// Block-center reach check from an eye point. `<` (not `<=`) preserves the
/// 1.7.10 boundary behavior.
pub const block_center: f64 = 0.5;
pub fn inReach(eye_x: f64, eye_y: f64, eye_z: f64, x: i32, y: u8, z: i32, reach: f32) bool {
    const dx = @as(f64, @floatFromInt(x)) + block_center - eye_x;
    const dy = @as(f64, @floatFromInt(y)) + block_center - eye_y;
    const dz = @as(f64, @floatFromInt(z)) + block_center - eye_z;
    const r = @as(f64, reach);
    return dx * dx + dy * dy + dz * dz < r * r;
}

/// Vanilla cactus contact (`ajt` = BlockCactus, `sa` = Entity scan): the
/// inset box (1/16 XZ, full height) is the COLLISION box the client halts
/// against — but damage does NOT retest it. The entity scan calls the
/// damage hook for every cell overlapped by the entity AABB shrunk by
/// 0.001 (jar: `floor(min+0.001)..floor(max-0.001)`, unconditional hook
/// call per cell, no box test between fetch and call). So brushing 0.01
/// into the cactus CELL hurts even short of the inset face; resting
/// exactly on the cell face does not.
/// Pure geometry; the caller resolves which cells actually are cactus.
/// Cactus collision-box inset (client movement only, NOT the damage rule).
pub const cactus_inset: f64 = 0.0625;
/// Shrink applied to the entity box for the cell-overlap rule (jar `sa`).
pub const cactus_contact_eps: f64 = 0.001;
/// Player half-width (0.6 wide) and height (1.8 tall).
pub const player_half_width: f64 = 0.3;
pub const player_height: f64 = 1.8;
pub fn cactusOverlapsPlayer(bx: i32, by: i32, bz: i32, px: f64, py: f64, pz: f64) bool {
    const hw = player_half_width;
    const ph = player_height;
    const e = cactus_contact_eps;
    return cactusOverlapsBox(bx, by, bz, px - hw + e, py + e, pz - hw + e, px + hw - e, py + ph - e, pz + hw - e);
}

/// Vanilla `checkNoEntityCollision` placement half: does the unit cell at
/// (bx,by,bz) strictly overlap the standing player AABB at feet (px,py,pz)?
/// Strict overlap (touching faces is fine — standing ON the cell below or
/// brushing its side must not refuse). Guards placement into the placer's
/// own feet/head: applying there sticks the vanilla client inside solid
/// (sudden stop + stuck jitter until broken).
pub fn blockIntersectsPlayer(bx: i32, by: u8, bz: i32, px: f64, py: f64, pz: f64) bool {
    const hw = player_half_width;
    const ph = player_height;
    const cx0: f64 = @floatFromInt(bx);
    const cy0: f64 = @floatFromInt(by);
    const cz0: f64 = @floatFromInt(bz);
    return px - hw < cx0 + 1.0 and px + hw > cx0 and
        py < cy0 + 1.0 and py + ph > cy0 and
        pz - hw < cz0 + 1.0 and pz + hw > cz0;
}

/// Exact swept contact: does the player's AABB, moving linearly from
/// feet (x0,y0,z0) to feet (x1,y1,z1), touch the cactus CELL? Slab test on
/// the Minkowski-expanded cell (full cell grown by the player half-extents
/// minus the 0.001 contact shrink, jar `sa`). The inset box plays no role
/// in damage. A union-box narrowphase would over-approximate diagonal
/// paths, so the slab runs on the true segment. Zero-length segments
/// degenerate to the point check.
pub fn segmentHitsCactus(bx: i32, by: i32, bz: i32, x0: f64, y0: f64, z0: f64, x1: f64, y1: f64, z1: f64) bool {
    const hw = player_half_width - cactus_contact_eps;
    const ph = player_height - cactus_contact_eps;
    const ex0: f64 = @as(f64, @floatFromInt(bx)) - hw;
    const ex1: f64 = @as(f64, @floatFromInt(bx)) + 1.0 + hw;
    const ey0: f64 = @as(f64, @floatFromInt(by)) - ph;
    const ey1: f64 = @as(f64, @floatFromInt(by)) + 1.0 - cactus_contact_eps;
    const ez0: f64 = @as(f64, @floatFromInt(bz)) - hw;
    const ez1: f64 = @as(f64, @floatFromInt(bz)) + 1.0 + hw;
    var tmin: f64 = 0.0;
    var tmax: f64 = 1.0;
    inline for (.{ .{ x0, x1, ex0, ex1 }, .{ y0, y1, ey0, ey1 }, .{ z0, z1, ez0, ez1 } }) |ax| {
        const p0 = ax[0];
        const d = ax[1] - p0;
        const e0 = ax[2];
        const e1 = ax[3];
        if (@abs(d) < 1e-9) {
            if (p0 < e0 or p0 > e1) return false;
        } else {
            var ta = (e0 - p0) / d;
            var tb = (e1 - p0) / d;
            if (ta > tb) {
                const tmp = ta;
                ta = tb;
                tb = tmp;
            }
            if (ta > tmin) tmin = ta;
            if (tb < tmax) tmax = tb;
            if (tmin > tmax) return false;
        }
    }
    return true;
}

/// Cactus cell vs an arbitrary player box: strict overlap with the FULL
/// cell (no inset — vanilla damages on cell contact, jar `sa`).
pub fn cactusOverlapsBox(bx: i32, by: i32, bz: i32, min_x: f64, min_y: f64, min_z: f64, max_x: f64, max_y: f64, max_z: f64) bool {
    const cmin_x: f64 = @as(f64, @floatFromInt(bx));
    const cmax_x: f64 = @as(f64, @floatFromInt(bx)) + 1.0;
    const cmin_y: f64 = @as(f64, @floatFromInt(by));
    const cmax_y: f64 = @as(f64, @floatFromInt(by)) + 1.0;
    const cmin_z: f64 = @as(f64, @floatFromInt(bz));
    const cmax_z: f64 = @as(f64, @floatFromInt(bz)) + 1.0;
    return min_x < cmax_x and max_x > cmin_x and
        min_y < cmax_y and max_y > cmin_y and
        min_z < cmax_z and max_z > cmin_z;
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

test "interaction: placement refuses player-intersecting cells only" {
    // Feet cell and head cell intersect; the block below (stood upon) and
    // the adjacent cell do not (touching faces is fine).
    try std.testing.expect(blockIntersectsPlayer(0, 64, 0, 0.5, 64.0, 0.5));
    try std.testing.expect(blockIntersectsPlayer(0, 65, 0, 0.5, 64.0, 0.5));
    try std.testing.expect(!blockIntersectsPlayer(0, 63, 0, 0.5, 64.0, 0.5));
    try std.testing.expect(!blockIntersectsPlayer(1, 64, 0, 0.5, 64.0, 0.5));
    try std.testing.expect(!blockIntersectsPlayer(0, 66, 0, 0.5, 64.0, 0.5));
    // Edge graze still counts (strict overlap, not cell identity).
    try std.testing.expect(blockIntersectsPlayer(1, 64, 0, 0.9, 64.0, 0.5));
}

test "interaction: cactus contact is AABB overlap, not cell identity" {
    // Standing inside the cactus cell.
    try std.testing.expect(cactusOverlapsPlayer(12, 64, 8, 12.5, 64.0, 8.5));
    // Brushing past: center 0.7 from the cactus center (adjacent cell).
    // Old cell-identity check missed this; vanilla damages on overlap.
    try std.testing.expect(cactusOverlapsPlayer(12, 64, 8, 11.8, 64.0, 8.5));
    // Just out of reach: 0.8 away clears the 0.3 + 0.5 overlap band.
    try std.testing.expect(!cactusOverlapsPlayer(12, 64, 8, 11.7, 64.0, 8.5));
    // Head-height cactus grazes a tall player; low cactus underfoot does not.
    try std.testing.expect(cactusOverlapsPlayer(12, 65, 8, 12.5, 64.0, 8.5));
    try std.testing.expect(!cactusOverlapsPlayer(12, 62, 8, 12.5, 64.0, 8.5));
    try std.testing.expect(!cactusOverlapsPlayer(12, 66, 8, 12.5, 64.0, 8.5));
    // The 0.0625 shell: 0.03 inside the CELL but short of the inset box
    // face still hurts (jar `sa` has no box retest — cell overlap is the
    // whole rule). Flush with the cell face does not.
    try std.testing.expect(cactusOverlapsPlayer(4, 71, 4, 3.73, 71.0, 4.5));
    try std.testing.expect(!cactusOverlapsPlayer(4, 71, 4, 3.7, 71.0, 4.5));
}

test "interaction: swept cactus contact is exact on diagonal walk-bys" {
    // Diagonal walk-by: the union rectangle of the path covers cactus
    // (12,64,10), but the walked segment never comes within reach.
    // The old rectangle narrowphase flagged this (phantom damage 1-2
    // blocks away); the slab test must not.
    try std.testing.expect(!segmentHitsCactus(12, 64, 10, 10.5, 64.0, 10.5, 12.5, 64.0, 12.5));
    // Same rectangle, path straight through the cactus: must still hit.
    try std.testing.expect(segmentHitsCactus(11, 64, 10, 10.5, 64.0, 10.5, 12.5, 64.0, 10.5));
    // Standing still inside / outside degenerates to the point check.
    try std.testing.expect(segmentHitsCactus(12, 64, 8, 12.5, 64.0, 8.5, 12.5, 64.0, 8.5));
    try std.testing.expect(!segmentHitsCactus(12, 64, 8, 11.0, 64.0, 8.5, 11.0, 64.0, 8.5));
    // Jump arc over a 1-high cactus clears it; landing into it hits.
    try std.testing.expect(!segmentHitsCactus(12, 64, 8, 11.5, 65.5, 8.5, 13.5, 65.5, 8.5));
    try std.testing.expect(segmentHitsCactus(12, 64, 8, 11.5, 65.0, 8.5, 13.5, 63.0, 8.5));
    // Side-press into the shell (inside the cell, short of the inset
    // face): vanilla cell rule hits, the old box rule missed.
    try std.testing.expect(segmentHitsCactus(4, 71, 4, 3.0, 71.0, 4.5, 3.73, 71.0, 4.5));
    try std.testing.expect(!segmentHitsCactus(4, 71, 4, 3.0, 71.0, 4.5, 3.7, 71.0, 4.5));
}
