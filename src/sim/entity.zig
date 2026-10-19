//! Minimal entity tracking: global mob list + per-conn visibility sets.
//!
//! P1 scope: one patrolling pig + player entities mirrored from connections.
//! Ticks run at 1Hz (server ticker); smooth 20tps interpolation is Phase C.
//! All movement uses vanilla 1.7 rules: rel-move within 4 blocks (|d|<=127
//! fixed units), teleport beyond, explicit destroy on unload/out-of-range
//! (clients never garbage-collect server-side entities on their own).

const std = @import("std");
const packets = @import("../proto/v5/packets.zig");
const conn_mod = @import("../net/conn.zig");

pub const MOB_PIG: u8 = 90;
pub const MOB_SHEEP: u8 = 91;
pub const MOB_COW: u8 = 92;

pub const Mob = struct {
    id: i32,
    kind: u8,
    x: f64,
    y: f64,
    z: f64,
    yaw: f32,
    health: f32,
    /// Square patrol around (home_x, home_z), leg 0..3, radius r.
    home_x: f64,
    home_z: f64,
    patrol_r: f64,
    leg: u8 = 0,

    pub fn waypoint(self: *const Mob) struct { x: f64, z: f64 } {
        const r = self.patrol_r;
        return switch (self.leg % 4) {
            0 => .{ .x = self.home_x + r, .z = self.home_z },
            1 => .{ .x = self.home_x + r, .z = self.home_z + r },
            2 => .{ .x = self.home_x, .z = self.home_z + r },
            else => .{ .x = self.home_x, .z = self.home_z },
        };
    }

    /// Move up to `step` blocks toward the current waypoint; advance leg on arrival.
    pub fn wanderStep(self: *Mob, step: f64) void {
        const wp = self.waypoint();
        const dx = wp.x - self.x;
        const dz = wp.z - self.z;
        const dist = @sqrt(dx * dx + dz * dz);
        if (dist < 0.6) {
            self.leg = (self.leg + 1) % 4;
            return;
        }
        const k = @min(step, dist) / dist;
        self.x += dx * k;
        self.z += dz * k;
        // face travel direction (degrees, 0 = +Z per wiki yaw convention)
        self.yaw = @as(f32, @floatCast(std.math.atan2(dx, dz) * 180.0 / std.math.pi));
    }
};

/// What to send a viewer about one entity this tick.
pub const UpdatePlan = union(enum) {
    none,
    spawn,
    rel_move: struct { dx: i8, dy: i8, dz: i8 },
    look,
    move_look: struct { dx: i8, dy: i8, dz: i8 },
    teleport,
};

/// Pure delta planner (unit-testable, no IO).
pub fn planUpdate(tracked: ?conn_mod.Tracked, x: f64, y: f64, z: f64, yaw: f32, pitch: f32) UpdatePlan {
    const t = tracked orelse return .spawn;
    const dx: i32 = @as(i32, @intFromFloat(@round((x - t.x) * 32.0)));
    const dy: i32 = @as(i32, @intFromFloat(@round((y - t.y) * 32.0)));
    const dz: i32 = @as(i32, @intFromFloat(@round((z - t.z) * 32.0)));
    const moved = dx != 0 or dy != 0 or dz != 0;
    const turned = yaw != t.yaw or pitch != t.pitch;
    if (!moved and !turned) return .none;
    // vanilla 4-block rule + i8 range: 128 fixed units can't fit in an i8
    if (@abs(dx) >= 128 or @abs(dy) >= 128 or @abs(dz) >= 128) return .teleport;
    const bx: i8 = @intCast(dx);
    const by: i8 = @intCast(dy);
    const bz: i8 = @intCast(dz);
    if (moved and turned) return .{ .move_look = .{ .dx = bx, .dy = by, .dz = bz } };
    if (moved) return .{ .rel_move = .{ .dx = bx, .dy = by, .dz = bz } };
    return .look;
}

/// Player snapshot (copied out from under the conn lock).
pub const PlayerSnap = struct {
    eid: i32,
    name: [16]u8 = [_]u8{0} ** 16,
    name_len: usize = 0,
    uuid: [36]u8 = [_]u8{0} ** 36,
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,
    yaw: f32 = 0,
    pitch: f32 = 0,
};

/// Mob snapshot (copied out from under the entity lock).
pub const MobSnap = struct {
    id: i32,
    kind: u8,
    x: f64,
    y: f64,
    z: f64,
    yaw: f32,
    health: f32,
};

/// Reconcile one viewer's tracked set against the world snapshot.
/// Queues spawn/update/destroy packets; caller flushes. `in_range` decides
/// visibility (block distance + sent-chunk gate applied by caller via `present`).
/// `present` answers: is (x,z) loaded for this viewer right now?
pub fn reconcileViewer(
    conn: *conn_mod.Conn,
    players: []const PlayerSnap,
    mobs: []const MobSnap,
    present: *const fn (ctx: *anyopaque, x: f64, z: f64) bool,
    present_ctx: *anyopaque,
) !void {
    // players
    for (players) |p| {
        if (p.eid == conn.eid) continue;
        if (!present(present_ctx, p.x, p.z)) {
            if (conn.tracked.fetchRemove(p.eid)) |_| {
                var db: [8]u8 = undefined;
                try conn.queueFramed(try packets.frameDestroyEntitiesFramed(&[_]i32{p.eid}, &db));
            }
            continue;
        }
        const t = conn.tracked.get(p.eid);
        switch (planUpdate(if (t) |tv| tv else null, p.x, p.y, p.z, p.yaw, p.pitch)) {
            .none => {},
            .spawn => {
                var sb: [256]u8 = undefined;
                try conn.queueFramed(try packets.frameSpawnPlayer(p.eid, &p.uuid, p.name[0..p.name_len], p.x, p.y, p.z, p.yaw, p.pitch, 20.0, &sb));
                var hb: [16]u8 = undefined;
                try conn.queueFramed(try packets.frameEntityHeadLook(p.eid, p.yaw, &hb));
                try conn.tracked.put(p.eid, .{ .x = p.x, .y = p.y, .z = p.z, .yaw = p.yaw, .pitch = p.pitch });
            },
            .rel_move => |d| {
                var mb: [16]u8 = undefined;
                try conn.queueFramed(try packets.frameEntityRelativeMove(p.eid, d.dx, d.dy, d.dz, &mb));
                try conn.tracked.put(p.eid, .{ .x = p.x, .y = p.y, .z = p.z, .yaw = p.yaw, .pitch = p.pitch });
            },
            .look => {
                var lb: [16]u8 = undefined;
                try conn.queueFramed(try packets.frameEntityLook(p.eid, p.yaw, p.pitch, &lb));
                var hb: [16]u8 = undefined;
                try conn.queueFramed(try packets.frameEntityHeadLook(p.eid, p.yaw, &hb));
                try conn.tracked.put(p.eid, .{ .x = p.x, .y = p.y, .z = p.z, .yaw = p.yaw, .pitch = p.pitch });
            },
            .move_look => |d| {
                var mb: [16]u8 = undefined;
                try conn.queueFramed(try packets.frameEntityMoveLook(p.eid, d.dx, d.dy, d.dz, p.yaw, p.pitch, &mb));
                var hb: [16]u8 = undefined;
                try conn.queueFramed(try packets.frameEntityHeadLook(p.eid, p.yaw, &hb));
                try conn.tracked.put(p.eid, .{ .x = p.x, .y = p.y, .z = p.z, .yaw = p.yaw, .pitch = p.pitch });
            },
            .teleport => {
                var tb: [32]u8 = undefined;
                try conn.queueFramed(try packets.frameEntityTeleport(p.eid, p.x, p.y, p.z, p.yaw, p.pitch, &tb));
                var hb: [16]u8 = undefined;
                try conn.queueFramed(try packets.frameEntityHeadLook(p.eid, p.yaw, &hb));
                try conn.tracked.put(p.eid, .{ .x = p.x, .y = p.y, .z = p.z, .yaw = p.yaw, .pitch = p.pitch });
            },
        }
    }
    // mobs
    for (mobs) |m| {
        if (!present(present_ctx, m.x, m.z)) {
            if (conn.tracked.fetchRemove(m.id)) |_| {
                var db: [8]u8 = undefined;
                try conn.queueFramed(try packets.frameDestroyEntitiesFramed(&[_]i32{m.id}, &db));
            }
            continue;
        }
        const t = conn.tracked.get(m.id);
        switch (planUpdate(if (t) |tv| tv else null, m.x, m.y, m.z, m.yaw, 0)) {
            .none => {},
            .spawn => {
                var sb: [256]u8 = undefined;
                try conn.queueFramed(try packets.frameSpawnMob(m.id, m.kind, m.x, m.y, m.z, m.yaw, 0, m.yaw, m.health, &sb));
                var hb: [16]u8 = undefined;
                try conn.queueFramed(try packets.frameEntityHeadLook(m.id, m.yaw, &hb));
                try conn.tracked.put(m.id, .{ .x = m.x, .y = m.y, .z = m.z, .yaw = m.yaw, .pitch = 0 });
            },
            .rel_move => |d| {
                var mb: [16]u8 = undefined;
                try conn.queueFramed(try packets.frameEntityRelativeMove(m.id, d.dx, d.dy, d.dz, &mb));
                try conn.tracked.put(m.id, .{ .x = m.x, .y = m.y, .z = m.z, .yaw = m.yaw, .pitch = 0 });
            },
            .look => {
                var hb: [16]u8 = undefined;
                try conn.queueFramed(try packets.frameEntityHeadLook(m.id, m.yaw, &hb));
                try conn.tracked.put(m.id, .{ .x = m.x, .y = m.y, .z = m.z, .yaw = m.yaw, .pitch = 0 });
            },
            .move_look => |d| {
                var mb: [16]u8 = undefined;
                try conn.queueFramed(try packets.frameEntityMoveLook(m.id, d.dx, d.dy, d.dz, m.yaw, 0, &mb));
                var hb: [16]u8 = undefined;
                try conn.queueFramed(try packets.frameEntityHeadLook(m.id, m.yaw, &hb));
                try conn.tracked.put(m.id, .{ .x = m.x, .y = m.y, .z = m.z, .yaw = m.yaw, .pitch = 0 });
            },
            .teleport => {
                var tb: [32]u8 = undefined;
                try conn.queueFramed(try packets.frameEntityTeleport(m.id, m.x, m.y, m.z, m.yaw, 0, &tb));
                try conn.tracked.put(m.id, .{ .x = m.x, .y = m.y, .z = m.z, .yaw = m.yaw, .pitch = 0 });
            },
        }
    }
    // despawn tracked ids absent from the snapshot (left range / removed)
    var gone: [64]i32 = undefined;
    var n_gone: usize = 0;
    var it = conn.tracked.keyIterator();
    while (it.next()) |id| {
        var found = false;
        for (players) |p| {
            if (p.eid != conn.eid and p.eid == id.* and present(present_ctx, p.x, p.z)) {
                found = true;
                break;
            }
        }
        if (!found) {
            for (mobs) |m| {
                if (m.id == id.* and present(present_ctx, m.x, m.z)) {
                    found = true;
                    break;
                }
            }
        }
        if (!found and n_gone < gone.len) {
            gone[n_gone] = id.*;
            n_gone += 1;
        }
    }
    for (gone[0..n_gone]) |id| {
        _ = conn.tracked.remove(id);
        var db: [8]u8 = undefined;
        try conn.queueFramed(try packets.frameDestroyEntitiesFramed(&[_]i32{id}, &db));
    }
}

test "planUpdate thresholds" {
    // no track -> spawn
    try std.testing.expectEqual(UpdatePlan.spawn, planUpdate(null, 0, 0, 0, 0, 0));
    const t = conn_mod.Tracked{ .x = 100.0, .y = 64.0, .z = 100.0, .yaw = 0, .pitch = 0 };
    // identical -> none
    try std.testing.expectEqual(UpdatePlan.none, planUpdate(t, 100.0, 64.0, 100.0, 0, 0));
    // 1 block move -> rel_move
    switch (planUpdate(t, 101.0, 64.0, 100.0, 0, 0)) {
        .rel_move => |d| {
            try std.testing.expectEqual(@as(i8, 32), d.dx);
            try std.testing.expectEqual(@as(i8, 0), d.dy);
        },
        else => return error.TestUnexpectedResult,
    }
    // 5 blocks -> teleport (vanilla 4-block rule)
    try std.testing.expectEqual(UpdatePlan.teleport, planUpdate(t, 105.0, 64.0, 100.0, 0, 0));
    // >127 fixed units on an axis -> teleport (i8 overflow guard)
    try std.testing.expectEqual(UpdatePlan.teleport, planUpdate(t, 104.0, 64.0, 100.0, 0, 0));
    // rotation only -> look
    try std.testing.expectEqual(UpdatePlan.look, planUpdate(t, 100.0, 64.0, 100.0, 90.0, 0));
    // move + turn -> move_look
    switch (planUpdate(t, 101.0, 64.0, 100.0, 90.0, 0)) {
        .move_look => {},
        else => return error.TestUnexpectedResult,
    }
}

test "mob patrol is deterministic and bounded" {
    var m = Mob{ .id = 1, .kind = MOB_PIG, .x = 0, .y = 64, .z = 0, .yaw = 0, .health = 10, .home_x = 0, .home_z = 0, .patrol_r = 4 };
    var ever_moved = false;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        m.wanderStep(1.0);
        try std.testing.expect(@abs(m.x) <= 5.0 and @abs(m.z) <= 5.0);
        if (@abs(m.x) > 1.0 or @abs(m.z) > 1.0) ever_moved = true;
    }
    try std.testing.expect(ever_moved);
}
