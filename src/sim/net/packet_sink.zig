//! Semantic outbound packet boundary for the shared simulation.
//!
//! `sim/entity.zig` and `sim/view.zig` describe *what happened* (an entity
//! spawned, a chunk entered/left view, a slot changed). The selected profile
//! implements this sink and owns packet ids, field order, compression and
//! scratch buffers. No game/simulation code imports `proto/*`.
//!
//! The vtable is intentionally small and cold: entity reconciliation runs at
//! 1 Hz and chunk delivery is bursty, so an indirect call per event is not on
//! a hot tick path. The profile is still compile-time selected; there is no
//! runtime version dispatch.

const item_mod = @import("../../item.zig");
const mob_mod = @import("../../game/mob.zig");
const chunk_mod = @import("../../world/chunk.zig");

/// Spawn Player semantic payload. Fixed arrays copy the identity out of the
/// connection lock, matching the existing `PlayerSnap` lifetime discipline.
pub const PlayerSpawn = struct {
    eid: i32,
    uuid: [36]u8 = [_]u8{0} ** 36,
    name: [16]u8 = [_]u8{0} ** 16,
    name_len: usize = 0,
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,
    yaw: f32 = 0,
    pitch: f32 = 0,
    health: f32 = 20.0,
};

/// Spawn Mob semantic payload. `kind` is canonical; the profile sink maps it
/// to the wire type id at this edge.
pub const MobSpawn = struct {
    eid: i32,
    kind: mob_mod.Kind,
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,
    yaw: f32 = 0,
    pitch: f32 = 0,
    head_pitch: f32 = 0,
    health: f32 = 20.0,
};

/// Dropped-item spawn: the sink sends both the object spawn and the metadata
/// watcher as one semantic event.
pub const ItemSpawn = struct {
    eid: i32,
    stack: item_mod.Stack,
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,
    /// Vanilla EntityItem toss velocity (blocks per 20tps tick). Rides the
    /// 0x0E spawn as x8000 shorts so the client simulates the arc itself
    /// between our 1Hz corrections; zero for settled items.
    vx: f64 = 0,
    vy: f64 = 0,
    vz: f64 = 0,
};

/// Thrown splash-potion spawn: type 73 with the item damage in the data
/// field (vanilla EntityPotion), plus the arc velocity shorts so the client
/// simulates the arc itself between our 1Hz corrections.
pub const PotionSpawn = struct {
    eid: i32,
    damage: i16,
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,
    vx: f64 = 0,
    vy: f64 = 0,
    vz: f64 = 0,
};

/// Primed-TNT spawn: type 50 (vanilla EntityTNTPrimed). No data field and
/// no velocity shorts on the wire (data 0 carries none); the client
/// renders the flashing primed block from the type alone and our 1Hz
/// rel_move/teleport stream corrects the arc, same as settled items.
pub const TntSpawn = struct {
    eid: i32,
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,
    vx: f64 = 0,
    vy: f64 = 0,
    vz: f64 = 0,
};
/// One column in a bulk delivery. The layout fields are codec results, not
/// canonical world state.
pub const BulkColumn = struct {
    x: i32,
    z: i32,
    primary: u16,
    add: u16,
};

pub const ColumnLayout = struct {
    primary: u16,
    add: u16,
    len: usize,
};

pub const VTable = struct {
    destroy_entities: *const fn (ctx: *anyopaque, ids: []const i32) anyerror!void,
    spawn_player: *const fn (ctx: *anyopaque, spawn: *const PlayerSpawn) anyerror!void,
    spawn_mob: *const fn (ctx: *anyopaque, spawn: *const MobSpawn) anyerror!void,
    move_relative: *const fn (ctx: *anyopaque, eid: i32, dx: i8, dy: i8, dz: i8) anyerror!void,
    look: *const fn (ctx: *anyopaque, eid: i32, yaw: f32, pitch: f32) anyerror!void,
    move_look: *const fn (ctx: *anyopaque, eid: i32, dx: i8, dy: i8, dz: i8, yaw: f32, pitch: f32) anyerror!void,
    teleport: *const fn (ctx: *anyopaque, eid: i32, x: f64, y: f64, z: f64, yaw: f32, pitch: f32) anyerror!void,
    head_look: *const fn (ctx: *anyopaque, eid: i32, yaw: f32) anyerror!void,
    spawn_item: *const fn (ctx: *anyopaque, spawn: *const ItemSpawn) anyerror!void,
    spawn_potion: *const fn (ctx: *anyopaque, spawn: *const PotionSpawn) anyerror!void,
    spawn_tnt: *const fn (ctx: *anyopaque, spawn: *const TntSpawn) anyerror!void,
    collect_item: *const fn (ctx: *anyopaque, collected_eid: i32, collector_eid: i32) anyerror!void,
    inventory_slot: *const fn (ctx: *anyopaque, window: i8, slot: i16, stack: ?item_mod.Stack) anyerror!void,
    unload_chunk: *const fn (ctx: *anyopaque, x: i32, z: i32) anyerror!void,
    respawn: *const fn (ctx: *anyopaque) anyerror!void,
    encode_column: *const fn (ctx: *anyopaque, ch: *const chunk_mod.Chunk, sky: bool, out: []u8) anyerror!ColumnLayout,
    send_bulk: *const fn (ctx: *anyopaque, cols: []const BulkColumn, raw: []const u8, sky: bool) anyerror!void,
};

pub const PacketSink = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn destroyEntities(self: PacketSink, ids: []const i32) !void {
        return self.vtable.destroy_entities(self.ctx, ids);
    }

    pub fn spawnPlayer(self: PacketSink, spawn: *const PlayerSpawn) !void {
        return self.vtable.spawn_player(self.ctx, spawn);
    }

    pub fn spawnMob(self: PacketSink, spawn: *const MobSpawn) !void {
        return self.vtable.spawn_mob(self.ctx, spawn);
    }

    pub fn moveRelative(self: PacketSink, eid: i32, dx: i8, dy: i8, dz: i8) !void {
        return self.vtable.move_relative(self.ctx, eid, dx, dy, dz);
    }

    pub fn look(self: PacketSink, eid: i32, yaw: f32, pitch: f32) !void {
        return self.vtable.look(self.ctx, eid, yaw, pitch);
    }

    pub fn moveLook(self: PacketSink, eid: i32, dx: i8, dy: i8, dz: i8, yaw: f32, pitch: f32) !void {
        return self.vtable.move_look(self.ctx, eid, dx, dy, dz, yaw, pitch);
    }

    pub fn teleport(self: PacketSink, eid: i32, x: f64, y: f64, z: f64, yaw: f32, pitch: f32) !void {
        return self.vtable.teleport(self.ctx, eid, x, y, z, yaw, pitch);
    }

    pub fn headLook(self: PacketSink, eid: i32, yaw: f32) !void {
        return self.vtable.head_look(self.ctx, eid, yaw);
    }

    pub fn spawnItem(self: PacketSink, spawn: *const ItemSpawn) !void {
        return self.vtable.spawn_item(self.ctx, spawn);
    }

    pub fn spawnPotion(self: PacketSink, spawn: *const PotionSpawn) !void {
        return self.vtable.spawn_potion(self.ctx, spawn);
    }

    pub fn spawnTnt(self: PacketSink, spawn: *const TntSpawn) !void {
        return self.vtable.spawn_tnt(self.ctx, spawn);
    }

    pub fn collectItem(self: PacketSink, collected_eid: i32, collector_eid: i32) !void {
        return self.vtable.collect_item(self.ctx, collected_eid, collector_eid);
    }

    pub fn inventorySlot(self: PacketSink, window: i8, slot: i16, stack: ?item_mod.Stack) !void {
        return self.vtable.inventory_slot(self.ctx, window, slot, stack);
    }

    pub fn unloadChunk(self: PacketSink, x: i32, z: i32) !void {
        return self.vtable.unload_chunk(self.ctx, x, z);
    }

    pub fn respawn(self: PacketSink) !void {
        return self.vtable.respawn(self.ctx);
    }

    pub fn encodeColumn(self: PacketSink, ch: *const chunk_mod.Chunk, sky: bool, out: []u8) !ColumnLayout {
        return self.vtable.encode_column(self.ctx, ch, sky, out);
    }

    pub fn sendBulk(self: PacketSink, cols: []const BulkColumn, raw: []const u8, sky: bool) !void {
        return self.vtable.send_bulk(self.ctx, cols, raw, sky);
    }
};
