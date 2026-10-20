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
const item_mod = @import("../item.zig");
const ids = @import("../ids.zig");

pub const MOB_PIG: u8 = 90;
pub const MOB_SHEEP: u8 = 91;
pub const MOB_COW: u8 = 92;

/// Dropped-item entity (vanilla EntityItem, type 2 on the wire).
/// Ticks are 20tps units advanced 20 per 1Hz server tick (same convention as
/// world_age in tickOnce). `stack` is OWNED (NBT duped at spawn, freed with
/// `freeStack` on removal).
pub const ItemEnt = struct {
    id: i32,
    x: f64,
    y: f64,
    z: f64,
    stack: item_mod.Stack,
    /// 20tps ticks since spawn; despawn at 6000 (5 min, vanilla `a >= 6000`).
    age: u32 = 0,
    /// 20tps pickup delay; block drops 10 (0.5s), Q-drops 40 (2s, CFR `b`).
    delay: u32 = 0,

    /// Vanilla `xk.a(xk2)` merge: same id + damage + NBT, combined count
    /// within max stack. The BIGGER stack absorbs (ties: `other` into self);
    /// survivor keeps max delay, min age. Returns true when merged.
    pub fn tryMerge(self: *ItemEnt, other: *ItemEnt) bool {
        if (!item_mod.canMerge(self.stack, other.stack)) return false;
        const limit = item_mod.maxStackSize(self.stack.id);
        if (@as(u16, @intCast(self.stack.count)) + @as(u16, @intCast(other.stack.count)) > limit) return false;
        // Bigger absorbs: fold `other` into `self` only when self is bigger.
        if (self.stack.count < other.stack.count) return false;
        self.stack.count += other.stack.count;
        self.delay = @max(self.delay, other.delay);
        self.age = @min(self.age, other.age);
        return true;
    }
};

/// Item snapshot (copied out from under the entity lock). `nbt` is a per-tick
/// OWNED dupe (may be null) — freed by the ticker after the reconcile pass.
pub const ItemSnap = struct {
    id: i32,
    x: f64,
    y: f64,
    z: f64,
    item_id: u16,
    count: i8,
    damage: i16,
    nbt: ?[]u8 = null,
    /// True once the pickup delay has expired (delay == 0 ticks).
    can_pickup: bool = false,
};

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

/// Tick-local pickup claims: first viewer to grab an item wins; later
/// viewers in the same pass see the claim and skip (no dupes, no nesting —
/// the entity list itself is only touched under ent_lock before/after).
pub const ClaimSet = struct {
    ids: [256]i32 = undefined,
    collectors: [256]i32 = undefined,
    n: usize = 0,
    pub fn contains(self: *const ClaimSet, id: i32) bool {
        for (self.ids[0..self.n]) |c| if (c == id) return true;
        return false;
    }
    /// False when full (caller skips the pickup; the item survives).
    pub fn add(self: *ClaimSet, id: i32, collector_eid: i32) bool {
        if (self.n >= self.ids.len) return false;
        self.ids[self.n] = id;
        self.collectors[self.n] = collector_eid;
        self.n += 1;
        return true;
    }
};

/// All-or-nothing inventory grant in vanilla order (window slots 9..44:
/// main first, hotbar last): merge into a partial stack, else first empty.
/// `stack` ownership STAYS with the caller in every path (merge keeps the
/// existing buffer; the empty-slot clone is conn-owned). Returns the changed
/// window slot for the 0x2F update, or null when nothing fits.
fn grantToInventory(conn: *conn_mod.Conn, stack: item_mod.Stack) !?i16 {
    // pass 1: merge into an existing partial stack
    var s: usize = 9;
    while (s <= 44) : (s += 1) {
        if (conn.inv[s]) |have| {
            if (item_mod.canMerge(have, stack) and @as(u16, @intCast(have.count)) + @as(u16, @intCast(stack.count)) <= item_mod.maxStackSize(have.id)) {
                conn.inv[s] = .{ .id = have.id, .count = have.count + stack.count, .damage = have.damage, .nbt = have.nbt };
                return @intCast(s);
            }
        }
    }
    // pass 2: first empty slot (clone: conn takes ownership)
    s = 9;
    while (s <= 44) : (s += 1) {
        if (conn.inv[s] == null) {
            conn.inv[s] = try item_mod.cloneStack(conn.allocator, stack);
            return @intCast(s);
        }
    }
    return null;
}

/// Vanilla pickup reach: entity-collision AABBs (player 0.6 + item 0.5 +
/// 0.2 expand) — centers within ~1 block horizontally, same height band.
/// Generous static approximation (no per-tick physics in the 1Hz model).
fn inPickupReach(px: f64, py: f64, pz: f64, x: f64, y: f64, z: f64) bool {
    const dx = x - px;
    const dz = z - pz;
    return dx * dx + dz * dz <= 1.0 and @abs(y - py) <= 2.0;
}

/// Reconcile one viewer's tracked set against the world snapshot.
/// Queues spawn/update/destroy packets; caller flushes. `in_range` decides
/// visibility (block distance + sent-chunk gate applied by caller via `present`).
/// `present` answers: is (x,z) loaded for this viewer right now?
pub fn reconcileViewer(
    conn: *conn_mod.Conn,
    players: []const PlayerSnap,
    mobs: []const MobSnap,
    items: []const ItemSnap,
    claimed: *ClaimSet,
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
    // items (static: spawn + metadata once, pickup claims, destroy on gone)
    for (items) |it| {
        if (claimed.contains(it.id)) {
            // claimed by an earlier viewer this pass: self already got
            // Set Slot + Collect + Destroy; drop from our tracked set now.
            if (conn.tracked.fetchRemove(it.id)) |_| {
                var db: [8]u8 = undefined;
                try conn.queueFramed(try packets.frameDestroyEntitiesFramed(&[_]i32{it.id}, &db));
            }
            continue;
        }
        if (!present(present_ctx, it.x, it.z)) {
            if (conn.tracked.fetchRemove(it.id)) |_| {
                var db: [8]u8 = undefined;
                try conn.queueFramed(try packets.frameDestroyEntitiesFramed(&[_]i32{it.id}, &db));
            }
            continue;
        }
        if (conn.tracked.contains(it.id)) {
            // static post-spawn (no movement updates in the 1Hz model);
            // pickup only after the spawn was actually sent (tracked), so
            // drops are visible for >= 1 tick even with an expired delay.
            if (!conn.is_dead and it.count > 0 and it.can_pickup and inPickupReach(conn.pos_x, conn.pos_y, conn.pos_z, it.x, it.y, it.z) and !claimed.contains(it.id)) {
                // magnet pickup: all-or-nothing grant, then claim for the tick.
                const stack = item_mod.Stack{ .id = it.item_id, .count = it.count, .damage = it.damage, .nbt = it.nbt };
                if (try grantToInventory(conn, stack)) |slot| {
                    if (claimed.add(it.id, conn.eid)) {
                        const f = try packets.frameSetSlotAlloc(conn.allocator, 0, slot, conn.inv[@intCast(slot)]);
                        defer conn.allocator.free(f);
                        try conn.queueFramed(f);
                        var cb: [16]u8 = undefined;
                        try conn.queueFramed(try packets.frameCollect(it.id, conn.eid, &cb));
                        var db: [8]u8 = undefined;
                        try conn.queueFramed(try packets.frameDestroyEntitiesFramed(&[_]i32{it.id}, &db));
                        // Already destroyed for self: drop from tracked now so
                        // the gone-scan below doesn't send a duplicate.
                        _ = conn.tracked.remove(it.id);
                    }
                }
            }
        } else if (!claimed.contains(it.id)) {
            var sb: [64]u8 = undefined;
            try conn.queueFramed(try packets.frameSpawnObject(it.id, 2, it.x, it.y, it.z, 0, 0, 1, null, &sb));
            var mb: [1024]u8 = undefined;
            const stack = item_mod.Stack{ .id = it.item_id, .count = it.count, .damage = it.damage, .nbt = it.nbt };
            try conn.queueFramed(try packets.frameItemMetadata(it.id, stack, &mb));
            try conn.tracked.put(it.id, .{ .x = it.x, .y = it.y, .z = it.z, .yaw = 0, .pitch = 0 });
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
        if (!found) {
            for (items) |ent| {
                if (ent.id == id.* and present(present_ctx, ent.x, ent.z)) {
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

test "item merge rules (vanilla xk semantics)" {
    var big = ItemEnt{ .id = 1, .x = 0, .y = 64, .z = 0, .stack = .{ .id = ids.diamond, .count = 60, .damage = 0, .nbt = null }, .delay = 5, .age = 100 };
    var small = ItemEnt{ .id = 2, .x = 0, .y = 64, .z = 0, .stack = .{ .id = ids.diamond, .count = 4, .damage = 0, .nbt = null }, .delay = 40, .age = 10 };
    try std.testing.expect(big.tryMerge(&small));
    try std.testing.expectEqual(@as(i8, 64), big.stack.count);
    try std.testing.expectEqual(@as(u32, 40), big.delay); // max
    try std.testing.expectEqual(@as(u32, 10), big.age); // min
    // small-into-big direction refuses (caller tries the other way)
    var a = ItemEnt{ .id = 3, .x = 0, .y = 64, .z = 0, .stack = .{ .id = ids.diamond, .count = 4, .damage = 0, .nbt = null } };
    var b = ItemEnt{ .id = 4, .x = 0, .y = 64, .z = 0, .stack = .{ .id = ids.diamond, .count = 60, .damage = 0, .nbt = null } };
    try std.testing.expect(!a.tryMerge(&b));
    try std.testing.expect(b.tryMerge(&a));
    // over max stack refuses
    var c = ItemEnt{ .id = 5, .x = 0, .y = 64, .z = 0, .stack = .{ .id = ids.diamond, .count = 64, .damage = 0, .nbt = null } };
    var d = ItemEnt{ .id = 6, .x = 0, .y = 64, .z = 0, .stack = .{ .id = ids.diamond, .count = 1, .damage = 0, .nbt = null } };
    try std.testing.expect(!c.tryMerge(&d));
    // different id / damage refuse
    var e = ItemEnt{ .id = 7, .x = 0, .y = 64, .z = 0, .stack = .{ .id = ids.coal, .count = 1, .damage = 0, .nbt = null } };
    try std.testing.expect(!c.tryMerge(&e));
    var f = ItemEnt{ .id = 8, .x = 0, .y = 64, .z = 0, .stack = .{ .id = ids.diamond, .count = 1, .damage = 1, .nbt = null } };
    try std.testing.expect(!c.tryMerge(&f));
    // claims: first wins, full rejects
    var claims = ClaimSet{};
    try std.testing.expect(!claims.contains(9));
    try std.testing.expect(claims.add(9, 100));
    try std.testing.expect(claims.contains(9));
}

test "pickup grants to inventory with collect + destroy" {
    const a = std.testing.allocator;
    var c = conn_mod.Conn.init(a, std.testing.io, .{ .spawn_x = 0, .spawn_y = 64, .spawn_z = 0 }, 7);
    defer c.deinit();
    c.state = .play;
    const items = [_]ItemSnap{.{
        .id = 51,
        .x = 0.5,
        .y = 64.1,
        .z = 0.5,
        .item_id = ids.diamond,
        .count = 3,
        .damage = 0,
        .can_pickup = true,
    }};
    var claims = ClaimSet{};
    const Always = struct {
        fn f(_: *anyopaque, _: f64, _: f64) bool {
            return true;
        }
    }.f;
    const ctx: *anyopaque = @ptrCast(@alignCast(@as(*u8, @ptrFromInt(0x1000))));
    // pass 1: untracked -> spawn + metadata (visible for >= 1 tick)
    try reconcileViewer(&c, &[_]PlayerSnap{}, &[_]MobSnap{}, &items, &claims, Always, ctx);
    try std.testing.expect(!claims.contains(51));
    try std.testing.expect(c.tracked.contains(51));
    // pass 2: tracked + delay expired -> grant + collect + destroy
    try reconcileViewer(&c, &[_]PlayerSnap{}, &[_]MobSnap{}, &items, &claims, Always, ctx);
    try std.testing.expect(claims.contains(51));
    // main inventory first slot (9) got the diamonds
    try std.testing.expect(c.inv[9] != null);
    try std.testing.expectEqual(@as(u16, 264), c.inv[9].?.id);
    try std.testing.expectEqual(@as(i8, 3), c.inv[9].?.count);
    // outbox carries 0x2F set slot + 0x0D collect + 0x13 destroy, in order
    const out = try c.takeOutput();
    defer a.free(out);
    var r = @import("../net/codec.zig").PacketReader.init(out);
    var seen: [5]i32 = .{ -1, -1, -1, -1, -1 };
    var k: usize = 0;
    const Codec = @import("../net/codec.zig");
    while (r.remaining() > 0 and k < seen.len) : (k += 1) {
        const h = try Codec.decodeFrame(&r);
        seen[k] = h.id;
        const blen: usize = @intCast(h.length - @as(i32, @intCast(Codec.PacketWriter.varIntLen(h.id))));
        r.index += blen;
    }
    try std.testing.expectEqualSlices(i32, &[_]i32{ 0x0E, 0x1C, 0x2F, 0x0D, 0x13 }, seen[0..k]);
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
