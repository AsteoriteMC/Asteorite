//! Minimal entity tracking: global mob list + per-conn visibility sets.
//!
//! P1 scope: one patrolling pig + player entities mirrored from connections.
//! Ticks run at 1Hz (server ticker); smooth 20tps interpolation is Phase C.
//! All movement uses vanilla 1.7 rules: rel-move within 4 blocks (|d|<=127
//! fixed units), teleport beyond, explicit destroy on unload/out-of-range
//! (clients never garbage-collect server-side entities on their own).

const std = @import("std");
const conn_mod = @import("../../net/conn.zig");
const item_mod = @import("../../item.zig");
const ids = @import("../../ids.zig");
const mob_mod = @import("../../game/mob.zig");
const packet_sink = @import("../net/packet_sink.zig");
const profile = @import("../../version.zig");

/// Canonical aliases kept for existing simulation/demo writers.
pub const MOB_PIG: mob_mod.Kind = .pig;
pub const MOB_SHEEP: mob_mod.Kind = .sheep;
pub const MOB_COW: mob_mod.Kind = .cow;

/// Thrown splash potion (vanilla EntityPotion, type 73 on the wire).
/// Arc is 20tps units integrated 20 substeps per 1Hz server tick (same
/// convention as items): drag 0.99, gravity 0.03 (jar `uo`). No pickup,
/// no merging — impact (block or player) applies the effect and despawns.
/// Age caps flight at 200 ticks (vanilla lives until impact; the cap is a
/// backstop for void throws, which despawn at y < -64 like items).
pub const PotionEnt = struct {
    id: i32,
    x: f64,
    y: f64,
    z: f64,
    /// Potion item damage (effect + splash bit; the 0x0E data field).
    damage: i16,
    vx: f64 = 0,
    vy: f64 = 0,
    vz: f64 = 0,
    age: u32 = 0,
};

/// Potion snapshot (copied out from under the entity lock, no NBT — the
/// damage value fully describes the potion).
pub const PotionSnap = struct {
    id: i32,
    x: f64,
    y: f64,
    z: f64,
    damage: i16,
    vx: f64 = 0,
    vy: f64 = 0,
    vz: f64 = 0,
};
/// Primed TNT (vanilla EntityTNTPrimed, type 50 on the wire).
/// Fuse is game ticks (20 per 1Hz server tick; vanilla fuse 80 = 4s).
/// Motion is blocks per 20tps tick, integrated 20 substeps per 1Hz tick
/// like items (vanilla: gravity 0.04, drag 0.98, ground bounce -0.5 with
/// 0.7 horizontal friction). No pickup, no merging — detonation at
/// fuse <= 0 queues a batched blast (see sim/world/explosion.zig).
pub const TntEnt = struct {
    id: i32,
    x: f64,
    y: f64,
    z: f64,
    vx: f64 = 0,
    vy: f64 = 0,
    vz: f64 = 0,
    /// Game ticks remaining (vanilla 80 at prime, 10-30 for chains).
    fuse: u16 = 80,
};

/// TNT snapshot (copied out from under the entity lock; fuse is shown so
/// viewers could render urgency, though the client flashes on its own).
pub const TntSnap = struct {
    id: i32,
    x: f64,
    y: f64,
    z: f64,
    vx: f64 = 0,
    vy: f64 = 0,
    vz: f64 = 0,
    fuse: u16 = 80,
};
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
    /// Toss velocity in blocks per 20tps tick (vanilla EntityItem motion:
    /// break drops pop with motionY 0.2 and motionXZ in [-0.1, 0.1]).
    /// Integrated 20 substeps per 1Hz server tick until the item settles;
    /// zero means static (at rest, no tick work, no move broadcasts).
    vx: f64 = 0,
    vy: f64 = 0,
    vz: f64 = 0,
    /// 20tps ticks since spawn; despawn at 6000 (5 min, vanilla `a >= 6000`).
    age: u32 = 0,
    /// 20tps pickup delay; block drops 10 (0.5s), Q-drops 40 (2s, CFR `b`).
    delay: u32 = 0,

    /// Vanilla `xk.a(xk2)` merge: same id + damage + NBT, combined count
    /// within max stack. The BIGGER stack absorbs (ties: `other` into self);
    /// survivor keeps max delay, min age. Returns true when merged.
    /// Proximity is 3D like vanilla (jar `xk.k`: AABB expanded 0.5 in XZ
    /// only — no Y expansion): drops stacked vertically (mining down a
    /// pillar) must NOT merge, only ones actually touching.
    pub fn tryMerge(self: *ItemEnt, other: *ItemEnt) bool {
        if (!item_mod.canMerge(self.stack, other.stack)) return false;
        const dx = self.x - other.x;
        const dz = self.z - other.z;
        if (dx * dx + dz * dz > 1.0) return false;
        if (@abs(self.y - other.y) > 0.5) return false;
        const limit = profile.game.item_data.maxStackSize(self.stack.id);
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
    item_id: ids.Id,
    count: i8,
    damage: i16,
    nbt: ?[]u8 = null,
    /// True once the pickup delay has expired (delay == 0 ticks).
    can_pickup: bool = false,
    /// Live toss velocity (blocks per 20tps tick); zero once settled.
    /// Snapshotted so spawns can hand the client its arc (0x0E velocity
    /// shorts) instead of a stationary item that snaps blocks away on the
    /// next 1Hz correction.
    vx: f64 = 0,
    vy: f64 = 0,
    vz: f64 = 0,
};

pub const Mob = struct {
    id: i32,
    kind: mob_mod.Kind,
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

    pub fn waypoint(self: *const Mob) mob_mod.Waypoint {
        return mob_mod.squareWaypoint(self.home_x, self.home_z, self.patrol_r, self.leg);
    }

    /// Move up to `step` blocks toward the current waypoint; advance leg on arrival.
    pub fn wanderStep(self: *Mob, step: f64) void {
        const wp = self.waypoint();
        const dx = wp.x - self.x;
        const dz = wp.z - self.z;
        const dist = @sqrt(dx * dx + dz * dz);
        if (dist < mob_mod.arrive_dist) {
            self.leg = (self.leg + 1) % 4;
            return;
        }
        const k = @min(step, dist) / dist;
        self.x += dx * k;
        self.z += dz * k;
        self.yaw = mob_mod.facingYaw(dx, dz);
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
    /// Movement bounding box since the last hazard sample (min/max
    /// corners). The env scan sweeps this box for cactus contact so a
    /// crossing — even a round trip — inside one 1Hz tick still hurts.
    /// Both corners equal x/y/z until the first sample.
    hx0: f64 = 0,
    hy0: f64 = 0,
    hz0: f64 = 0,
    hx1: f64 = 0,
    hy1: f64 = 0,
    hz1: f64 = 0,
};

/// Mob snapshot (copied out from under the entity lock).
pub const MobSnap = struct {
    id: i32,
    kind: mob_mod.Kind,
    x: f64,
    y: f64,
    z: f64,
    yaw: f32,
    health: f32,
};

/// Tick-local pickup claims: first viewer to grab an item wins; later
/// viewers in the same pass see the claim and skip (no dupes, no nesting —
/// the entity list itself is only touched under ent_lock before/after).
pub const max_claims: usize = 256;
pub const ClaimSet = struct {
    ids: [max_claims]i32 = undefined,
    collectors: [max_claims]i32 = undefined,
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

/// All-or-nothing inventory grant in vanilla order (`item.fill_order`:
/// hotbar first, window slots 36..44, then main 9..35): merge into a
/// partial stack, else first empty.
/// `stack` ownership STAYS with the caller in every path (merge keeps the
/// existing buffer; the empty-slot clone is conn-owned). Returns the changed
/// window slot for the 0x2F update, or null when nothing fits.
fn grantToInventory(conn: *conn_mod.Conn, stack: item_mod.Stack) !?i16 {
    // pass 1: merge into an existing partial stack
    for (item_mod.fill_order) |s| {
        if (conn.inv[s]) |have| {
            if (item_mod.canMerge(have, stack) and @as(u16, @intCast(have.count)) + @as(u16, @intCast(stack.count)) <= profile.game.item_data.maxStackSize(have.id)) {
                conn.inv[s] = .{ .id = have.id, .count = have.count + stack.count, .damage = have.damage, .nbt = have.nbt };
                return @intCast(s);
            }
        }
    }
    // pass 2: first empty slot (clone: conn takes ownership)
    for (item_mod.fill_order) |s| {
        if (conn.inv[s] == null) {
            conn.inv[s] = try item_mod.cloneStack(conn.allocator, stack);
            return @intCast(s);
        }
    }
    return null;
}

/// Vanilla pickup reach: entity-collision AABBs (player 0.6 + item 0.5 +
/// 0.2 expand) plus the item magnet — centers within ~2 blocks horizontally
/// pick up, same height band. The magnet matters at 1Hz: with a 1-block
/// radius a walking player steps past a drop between ticks and never
/// overlaps it on a tick boundary, so walking over drops felt broken.
pub const pickup_radius_sq: f64 = 4.0;
pub const pickup_height: f64 = 2.0;
fn inPickupReach(px: f64, py: f64, pz: f64, x: f64, y: f64, z: f64) bool {
    const dx = x - px;
    const dz = z - pz;
    return dx * dx + dz * dz <= pickup_radius_sq and @abs(y - py) <= pickup_height;
}

/// Record the latest known state for a tracked entity (one call per
/// non-none plan — the old code repeated this line in every switch arm).
fn track(conn: *conn_mod.Conn, id: i32, x: f64, y: f64, z: f64, yaw: f32, pitch: f32) !void {
    try conn.tracked.put(id, .{ .x = x, .y = y, .z = z, .yaw = yaw, .pitch = pitch });
}

/// Despawn batch cap (tracked sets stay small; overflow skips gracefully).
pub const max_gone_batch: usize = 64;

/// Reconcile one viewer's tracked set against the world snapshot.
/// Queues spawn/update/destroy packets; caller flushes. `in_range` decides
/// visibility (block distance + sent-chunk gate applied by caller via `present`).
/// `present` answers: is (x,z) loaded for this viewer right now?
pub fn reconcileViewer(
    conn: *conn_mod.Conn,
    sink: packet_sink.PacketSink,
    players: []const PlayerSnap,
    mobs: []const MobSnap,
    items: []const ItemSnap,
    potions: []const PotionSnap,
    tnts: []const TntSnap,
    claimed: *ClaimSet,
    present: *const fn (ctx: *anyopaque, x: f64, z: f64) bool,
    present_ctx: *anyopaque,
) !void {
    // players
    for (players) |p| {
        if (p.eid == conn.eid) continue;
        if (!present(present_ctx, p.x, p.z)) {
            if (conn.tracked.fetchRemove(p.eid)) |_| try sink.destroyEntities(&[_]i32{p.eid});
            continue;
        }
        const t = conn.tracked.get(p.eid);
        const plan = planUpdate(if (t) |tv| tv else null, p.x, p.y, p.z, p.yaw, p.pitch);
        switch (plan) {
            .none => continue,
            .spawn => {
                var spawn = packet_sink.PlayerSpawn{
                    .eid = p.eid,
                    .uuid = p.uuid,
                    .name = p.name,
                    .name_len = p.name_len,
                    .x = p.x,
                    .y = p.y,
                    .z = p.z,
                    .yaw = p.yaw,
                    .pitch = p.pitch,
                    .health = 20.0,
                };
                try sink.spawnPlayer(&spawn);
                try sink.headLook(p.eid, p.yaw);
            },
            .rel_move => |d| try sink.moveRelative(p.eid, d.dx, d.dy, d.dz),
            .look => {
                try sink.look(p.eid, p.yaw, p.pitch);
                try sink.headLook(p.eid, p.yaw);
            },
            .move_look => |d| {
                try sink.moveLook(p.eid, d.dx, d.dy, d.dz, p.yaw, p.pitch);
                try sink.headLook(p.eid, p.yaw);
            },
            .teleport => {
                try sink.teleport(p.eid, p.x, p.y, p.z, p.yaw, p.pitch);
                try sink.headLook(p.eid, p.yaw);
            },
        }
        try track(conn, p.eid, p.x, p.y, p.z, p.yaw, p.pitch);
    }
    // mobs
    for (mobs) |m| {
        if (!present(present_ctx, m.x, m.z)) {
            if (conn.tracked.fetchRemove(m.id)) |_| try sink.destroyEntities(&[_]i32{m.id});
            continue;
        }
        const t = conn.tracked.get(m.id);
        switch (planUpdate(if (t) |tv| tv else null, m.x, m.y, m.z, m.yaw, 0)) {
            .none => continue,
            .spawn => {
                var spawn = packet_sink.MobSpawn{
                    .eid = m.id,
                    .kind = m.kind,
                    .x = m.x,
                    .y = m.y,
                    .z = m.z,
                    .yaw = m.yaw,
                    .pitch = 0,
                    .head_pitch = m.yaw,
                    .health = m.health,
                };
                try sink.spawnMob(&spawn);
                try sink.headLook(m.id, m.yaw);
            },
            .rel_move => |d| try sink.moveRelative(m.id, d.dx, d.dy, d.dz),
            .look => try sink.headLook(m.id, m.yaw),
            .move_look => |d| {
                try sink.moveLook(m.id, d.dx, d.dy, d.dz, m.yaw, 0);
                try sink.headLook(m.id, m.yaw);
            },
            .teleport => try sink.teleport(m.id, m.x, m.y, m.z, m.yaw, 0),
        }
        try track(conn, m.id, m.x, m.y, m.z, m.yaw, 0);
    }
    // items (spawn + toss-arc moves + metadata, pickup claims, destroy on gone)
    for (items) |it| {
        if (claimed.contains(it.id)) {
            // claimed by an earlier viewer this pass: self already got
            // Set Slot + Collect + Destroy; drop from our tracked set now.
            if (conn.tracked.fetchRemove(it.id)) |_| try sink.destroyEntities(&[_]i32{it.id});
            continue;
        }
        if (!present(present_ctx, it.x, it.z)) {
            if (conn.tracked.fetchRemove(it.id)) |_| try sink.destroyEntities(&[_]i32{it.id});
            continue;
        }
        if (conn.tracked.get(it.id)) |t| {
            // tossed drops move post-spawn (tick-integrated arc); relay
            // rel_move/teleport like mobs so the throw is visible.
            // Settled items go static again (planUpdate -> none).
            const iplan = planUpdate(t, it.x, it.y, it.z, 0, 0);
            switch (iplan) {
                .none => {},
                .rel_move => |d| try sink.moveRelative(it.id, d.dx, d.dy, d.dz),
                .teleport => try sink.teleport(it.id, it.x, it.y, it.z, 0, 0),
                else => {},
            }
            try track(conn, it.id, it.x, it.y, it.z, 0, 0);
            // pickup only after the spawn was actually sent (tracked), so
            // drops are visible for >= 1 tick even with an expired delay.
            if (!conn.is_dead and it.count > 0 and it.can_pickup and inPickupReach(conn.pos_x, conn.pos_y, conn.pos_z, it.x, it.y, it.z) and !claimed.contains(it.id)) {
                // magnet pickup: all-or-nothing grant, then claim for the tick.
                const stack = item_mod.Stack{ .id = it.item_id, .count = it.count, .damage = it.damage, .nbt = it.nbt };
                if (try grantToInventory(conn, stack)) |slot| {
                    if (claimed.add(it.id, conn.eid)) {
                        try sink.inventorySlot(0, slot, conn.inv[@intCast(slot)]);
                        try sink.collectItem(it.id, conn.eid);
                        try sink.destroyEntities(&[_]i32{it.id});
                        // Already destroyed for self: drop from tracked now so
                        // the gone-scan below doesn't send a duplicate.
                        _ = conn.tracked.remove(it.id);
                    }
                }
            }
        } else if (!claimed.contains(it.id)) {
            const stack = item_mod.Stack{ .id = it.item_id, .count = it.count, .damage = it.damage, .nbt = it.nbt };
            var spawn = packet_sink.ItemSpawn{ .eid = it.id, .stack = stack, .x = it.x, .y = it.y, .z = it.z, .vx = it.vx, .vy = it.vy, .vz = it.vz };
            try sink.spawnItem(&spawn);
            try conn.tracked.put(it.id, .{ .x = it.x, .y = it.y, .z = it.z, .yaw = 0, .pitch = 0 });
        }
    }
    // potions (thrown splash arcs: spawn type 73 with the damage value,
    // rel_move/teleport like items so the arc is visible, destroy on gone)
    for (potions) |pot| {
        if (!present(present_ctx, pot.x, pot.z)) {
            if (conn.tracked.fetchRemove(pot.id)) |_| try sink.destroyEntities(&[_]i32{pot.id});
            continue;
        }
        if (conn.tracked.get(pot.id)) |t| {
            const pplan = planUpdate(t, pot.x, pot.y, pot.z, 0, 0);
            switch (pplan) {
                .none => {},
                .rel_move => |d| try sink.moveRelative(pot.id, d.dx, d.dy, d.dz),
                .teleport => try sink.teleport(pot.id, pot.x, pot.y, pot.z, 0, 0),
                else => {},
            }
            try track(conn, pot.id, pot.x, pot.y, pot.z, 0, 0);
        } else {
            var spawn = packet_sink.PotionSpawn{ .eid = pot.id, .damage = pot.damage, .x = pot.x, .y = pot.y, .z = pot.z, .vx = pot.vx, .vy = pot.vy, .vz = pot.vz };
            try sink.spawnPotion(&spawn);
            try conn.tracked.put(pot.id, .{ .x = pot.x, .y = pot.y, .z = pot.z, .yaw = 0, .pitch = 0 });
        }
    }
    // primed TNT (spawn type 50 with the flicker fuse, rel_move/teleport
    // like items so the arc is visible, destroy on gone/detonate)
    for (tnts) |tnt| {
        if (!present(present_ctx, tnt.x, tnt.z)) {
            if (conn.tracked.fetchRemove(tnt.id)) |_| try sink.destroyEntities(&[_]i32{tnt.id});
            continue;
        }
        if (conn.tracked.get(tnt.id)) |t| {
            const tplan = planUpdate(t, tnt.x, tnt.y, tnt.z, 0, 0);
            switch (tplan) {
                .none => {},
                .rel_move => |d| try sink.moveRelative(tnt.id, d.dx, d.dy, d.dz),
                .teleport => try sink.teleport(tnt.id, tnt.x, tnt.y, tnt.z, 0, 0),
                else => {},
            }
            try track(conn, tnt.id, tnt.x, tnt.y, tnt.z, 0, 0);
        } else {
            var spawn = packet_sink.TntSpawn{ .eid = tnt.id, .x = tnt.x, .y = tnt.y, .z = tnt.z, .vx = tnt.vx, .vy = tnt.vy, .vz = tnt.vz };
            try sink.spawnTnt(&spawn);
            try conn.tracked.put(tnt.id, .{ .x = tnt.x, .y = tnt.y, .z = tnt.z, .yaw = 0, .pitch = 0 });
        }
    }
    // despawn tracked ids absent from the snapshot (left range / removed)
    var gone: [max_gone_batch]i32 = undefined;
    var n_gone: usize = 0;
    var it = conn.tracked.keyIterator();
    while (it.next()) |id| {
        if (!stillVisible(id.*, conn.eid, players, mobs, items, potions, tnts, present, present_ctx)) {
            if (n_gone < gone.len) {
                gone[n_gone] = id.*;
                n_gone += 1;
            }
        }
    }
    for (gone[0..n_gone]) |id| {
        _ = conn.tracked.remove(id);
        try sink.destroyEntities(&[_]i32{id});
    }
}

/// True when a tracked id is still in the snapshot and in range.
fn stillVisible(
    id: i32,
    self_eid: i32,
    players: []const PlayerSnap,
    mobs: []const MobSnap,
    items: []const ItemSnap,
    potions: []const PotionSnap,
    tnts: []const TntSnap,
    present: *const fn (ctx: *anyopaque, x: f64, z: f64) bool,
    present_ctx: *anyopaque,
) bool {
    for (players) |p| {
        if (p.eid != self_eid and p.eid == id and present(present_ctx, p.x, p.z)) return true;
    }
    for (mobs) |m| {
        if (m.id == id and present(present_ctx, m.x, m.z)) return true;
    }
    for (items) |ent| {
        if (ent.id == id and present(present_ctx, ent.x, ent.z)) return true;
    }
    for (potions) |pot| {
        if (pot.id == id and present(present_ctx, pot.x, pot.z)) return true;
    }
    for (tnts) |tnt| {
        if (tnt.id == id and present(present_ctx, tnt.x, tnt.z)) return true;
    }
    return false;
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
    // vertical separation blocks merging (jar xk.k expands XZ only):
    // same-column drops a block apart (pillar mining) stay separate.
    var g = ItemEnt{ .id = 9, .x = 0, .y = 64, .z = 0, .stack = .{ .id = ids.dirt, .count = 32, .damage = 0, .nbt = null }, .delay = 0, .age = 5 };
    var h = ItemEnt{ .id = 10, .x = 0.3, .y = 65, .z = 0.2, .stack = .{ .id = ids.dirt, .count = 32, .damage = 0, .nbt = null }, .delay = 0, .age = 5 };
    try std.testing.expect(!g.tryMerge(&h));
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
    const sink_test = @import("../net/packet_sink_test.zig");
    var recorder = sink_test.Recorder{};
    const sink = recorder.sink();
    const Always = struct {
        fn f(_: *anyopaque, _: f64, _: f64) bool {
            return true;
        }
    }.f;
    const ctx: *anyopaque = @ptrCast(@alignCast(@as(*u8, @ptrFromInt(0x1000))));
    // pass 1: untracked -> semantic item spawn (object + metadata at the edge)
    try reconcileViewer(&c, sink, &[_]PlayerSnap{}, &[_]MobSnap{}, &items, &[_]PotionSnap{}, &[_]TntSnap{}, &claims, Always, ctx);
    try std.testing.expect(!claims.contains(51));
    try std.testing.expect(c.tracked.contains(51));
    try std.testing.expectEqualSlices(sink_test.Event, &[_]sink_test.Event{.item}, recorder.eventSlice());
    try std.testing.expectEqual(@as(usize, 1), recorder.item_spawns);
    try std.testing.expectEqual(ids.diamond, recorder.last_item.?.stack.id);
    try std.testing.expectEqual(@as(i8, 3), recorder.last_item.?.stack.count);

    // pass 2: tracked + delay expired -> grant + collect + destroy
    recorder.reset();
    try reconcileViewer(&c, sink, &[_]PlayerSnap{}, &[_]MobSnap{}, &items, &[_]PotionSnap{}, &[_]TntSnap{}, &claims, Always, ctx);
    try std.testing.expect(claims.contains(51));
    // first hotbar slot (36) got the diamonds
    try std.testing.expect(c.inv[36] != null);
    try std.testing.expectEqual(ids.diamond, c.inv[36].?.id);
    try std.testing.expectEqual(@as(i8, 3), c.inv[36].?.count);
    try std.testing.expectEqualSlices(sink_test.Event, &[_]sink_test.Event{ .slot, .collect, .destroy }, recorder.eventSlice());
    try std.testing.expectEqual(@as(i16, 36), recorder.last_slot.?.slot);
    try std.testing.expectEqual(ids.diamond, recorder.last_slot.?.stack.?.id);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 51, 7 }, &recorder.last_collect.?);
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

test "potion reconcile: spawn type 73, arc moves, destroy on gone" {
    // Thrown splash shows as a Spawn Object with the damage in the data
    // field, follows the arc with rel_move, and despawns when the server
    // drops it from the snapshot (impact).
    const a = std.testing.allocator;
    var c = conn_mod.Conn.init(a, std.testing.io, .{ .spawn_x = 0, .spawn_y = 64, .spawn_z = 0 }, 7);
    defer c.deinit();
    c.state = .play;
    const pots = [_]PotionSnap{.{
        .id = 61,
        .x = 0.5,
        .y = 65.0,
        .z = 0.5,
        .damage = 8194 | 16384,
        .vx = 0.5,
        .vy = 0.1,
        .vz = 0.0,
    }};
    var claims = ClaimSet{};
    const sink_test = @import("../net/packet_sink_test.zig");
    var recorder = sink_test.Recorder{};
    const sink = recorder.sink();
    const Always = struct {
        fn f(_: *anyopaque, _: f64, _: f64) bool {
            return true;
        }
    }.f;
    const ctx: *anyopaque = @ptrCast(@alignCast(@as(*u8, @ptrFromInt(0x1000))));
    // pass 1: untracked -> potion spawn
    try reconcileViewer(&c, sink, &[_]PlayerSnap{}, &[_]MobSnap{}, &[_]ItemSnap{}, &pots, &[_]TntSnap{}, &claims, Always, ctx);
    try std.testing.expect(c.tracked.contains(61));
    try std.testing.expectEqualSlices(sink_test.Event, &[_]sink_test.Event{.potion}, recorder.eventSlice());
    try std.testing.expectEqual(@as(usize, 1), recorder.potion_spawns);
    try std.testing.expectEqual(@as(i16, 8194 | 16384), recorder.last_potion.?.damage);
    // pass 2: moved along the arc -> rel_move (velocity hint, no respawn)
    var moved = pots;
    moved[0].x += 1.0;
    recorder.reset();
    try reconcileViewer(&c, sink, &[_]PlayerSnap{}, &[_]MobSnap{}, &[_]ItemSnap{}, &moved, &[_]TntSnap{}, &claims, Always, ctx);
    try std.testing.expectEqualSlices(sink_test.Event, &[_]sink_test.Event{.rel_move}, recorder.eventSlice());
    // pass 3: gone from the snapshot (impact) -> destroy
    recorder.reset();
    try reconcileViewer(&c, sink, &[_]PlayerSnap{}, &[_]MobSnap{}, &[_]ItemSnap{}, &[_]PotionSnap{}, &[_]TntSnap{}, &claims, Always, ctx);
    try std.testing.expect(!c.tracked.contains(61));
    try std.testing.expectEqualSlices(sink_test.Event, &[_]sink_test.Event{.destroy}, recorder.eventSlice());
}

test "mob patrol is deterministic and bounded" {    var m = Mob{ .id = 1, .kind = MOB_PIG, .x = 0, .y = 64, .z = 0, .yaw = 0, .health = 10, .home_x = 0, .home_z = 0, .patrol_r = 4 };
    var ever_moved = false;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        m.wanderStep(1.0);
        try std.testing.expect(@abs(m.x) <= 5.0 and @abs(m.z) <= 5.0);
        if (@abs(m.x) > 1.0 or @abs(m.z) > 1.0) ever_moved = true;
    }
    try std.testing.expect(ever_moved);
}