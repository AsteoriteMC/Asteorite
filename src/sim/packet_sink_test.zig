//! Test recorder for the semantic packet sink.
//!
//! Shared simulation tests assert what the core decided (spawn/move/unload/
//! bulk/collect), while `net/packet_sink.zig` tests assert the v5 bytes. This
//! keeps the import gate honest and makes scheduling regressions readable.

const sink_mod = @import("packet_sink.zig");
const chunk_mod = @import("../world/chunk.zig");
const item_mod = @import("../item.zig");

pub const Event = enum {
    destroy,
    player,
    mob,
    rel_move,
    look,
    move_look,
    teleport,
    head_look,
    item,
    collect,
    slot,
    unload,
    respawn,
    encode,
    bulk,
};

pub const SlotEvent = struct {
    window: i8,
    slot: i16,
    stack: ?item_mod.Stack,
};

pub const Recorder = struct {
    events: [512]Event = undefined,
    n: usize = 0,

    destroy_ids: [64]i32 = undefined,
    destroy_n: usize = 0,
    player_spawns: usize = 0,
    last_player: ?sink_mod.PlayerSpawn = null,
    mob_spawns: usize = 0,
    last_mob: ?sink_mod.MobSpawn = null,
    rel_moves: usize = 0,
    looks: usize = 0,
    move_looks: usize = 0,
    teleports: usize = 0,
    head_looks: usize = 0,
    item_spawns: usize = 0,
    last_item: ?sink_mod.ItemSpawn = null,
    collects: usize = 0,
    last_collect: ?[2]i32 = null,
    slots: usize = 0,
    last_slot: ?SlotEvent = null,
    unloads: usize = 0,
    unload_pos: [64]struct { x: i32, z: i32 } = undefined,
    respawns: usize = 0,
    encodes: usize = 0,
    bulks: usize = 0,
    bulk_cols: [64]sink_mod.BulkColumn = undefined,
    bulk_n: usize = 0,
    bulk_raw_len: usize = 0,
    bulk_sky: bool = false,

    fn add(self: *Recorder, event: Event) void {
        if (self.n < self.events.len) self.events[self.n] = event;
        self.n += 1;
    }

    pub fn reset(self: *Recorder) void {
        self.n = 0;
        self.destroy_n = 0;
        self.player_spawns = 0;
        self.last_player = null;
        self.mob_spawns = 0;
        self.last_mob = null;
        self.rel_moves = 0;
        self.looks = 0;
        self.move_looks = 0;
        self.teleports = 0;
        self.head_looks = 0;
        self.item_spawns = 0;
        self.last_item = null;
        self.collects = 0;
        self.last_collect = null;
        self.slots = 0;
        self.last_slot = null;
        self.unloads = 0;
        self.respawns = 0;
        self.encodes = 0;
        self.bulks = 0;
        self.bulk_n = 0;
        self.bulk_raw_len = 0;
        self.bulk_sky = false;
    }

    pub fn eventSlice(self: *const Recorder) []const Event {
        return self.events[0..@min(self.n, self.events.len)];
    }

    pub fn sink(self: *Recorder) sink_mod.PacketSink {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    fn destroyEntities(ctx: *anyopaque, ids: []const i32) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.add(.destroy);
        for (ids) |id| {
            if (self.destroy_n < self.destroy_ids.len) self.destroy_ids[self.destroy_n] = id;
            self.destroy_n += 1;
        }
    }

    fn spawnPlayer(ctx: *anyopaque, spawn: *const sink_mod.PlayerSpawn) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.add(.player);
        self.player_spawns += 1;
        self.last_player = spawn.*;
    }

    fn spawnMob(ctx: *anyopaque, spawn: *const sink_mod.MobSpawn) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.add(.mob);
        self.mob_spawns += 1;
        self.last_mob = spawn.*;
    }

    fn moveRelative(ctx: *anyopaque, eid: i32, dx: i8, dy: i8, dz: i8) anyerror!void {
        _ = eid;
        _ = dx;
        _ = dy;
        _ = dz;
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.add(.rel_move);
        self.rel_moves += 1;
    }

    fn look(ctx: *anyopaque, eid: i32, yaw: f32, pitch: f32) anyerror!void {
        _ = eid;
        _ = yaw;
        _ = pitch;
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.add(.look);
        self.looks += 1;
    }

    fn moveLook(ctx: *anyopaque, eid: i32, dx: i8, dy: i8, dz: i8, yaw: f32, pitch: f32) anyerror!void {
        _ = eid;
        _ = dx;
        _ = dy;
        _ = dz;
        _ = yaw;
        _ = pitch;
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.add(.move_look);
        self.move_looks += 1;
    }

    fn teleport(ctx: *anyopaque, eid: i32, x: f64, y: f64, z: f64, yaw: f32, pitch: f32) anyerror!void {
        _ = eid;
        _ = x;
        _ = y;
        _ = z;
        _ = yaw;
        _ = pitch;
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.add(.teleport);
        self.teleports += 1;
    }

    fn headLook(ctx: *anyopaque, eid: i32, yaw: f32) anyerror!void {
        _ = eid;
        _ = yaw;
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.add(.head_look);
        self.head_looks += 1;
    }

    fn spawnItem(ctx: *anyopaque, spawn: *const sink_mod.ItemSpawn) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.add(.item);
        self.item_spawns += 1;
        self.last_item = spawn.*;
    }

    fn collectItem(ctx: *anyopaque, collected_eid: i32, collector_eid: i32) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.add(.collect);
        self.collects += 1;
        self.last_collect = .{ collected_eid, collector_eid };
    }

    fn inventorySlot(ctx: *anyopaque, window: i8, slot: i16, stack: ?item_mod.Stack) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.add(.slot);
        self.slots += 1;
        self.last_slot = .{ .window = window, .slot = slot, .stack = stack };
    }

    fn unloadChunk(ctx: *anyopaque, x: i32, z: i32) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.add(.unload);
        if (self.unloads < self.unload_pos.len) self.unload_pos[self.unloads] = .{ .x = x, .z = z };
        self.unloads += 1;
    }

    fn respawn(ctx: *anyopaque) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.add(.respawn);
        self.respawns += 1;
    }

    fn encodeColumn(ctx: *anyopaque, ch: *const chunk_mod.Chunk, sky: bool, out: []u8) anyerror!sink_mod.ColumnLayout {
        _ = ch;
        _ = sky;
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.add(.encode);
        self.encodes += 1;
        if (out.len > 0) out[0] = 0xAB;
        return .{ .primary = 1, .add = 0, .len = if (out.len > 0) 1 else 0 };
    }

    fn sendBulk(ctx: *anyopaque, cols: []const sink_mod.BulkColumn, raw: []const u8, sky: bool) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.add(.bulk);
        self.bulks += 1;
        for (cols) |c| {
            if (self.bulk_n < self.bulk_cols.len) self.bulk_cols[self.bulk_n] = c;
            self.bulk_n += 1;
        }
        self.bulk_raw_len = raw.len;
        self.bulk_sky = sky;
    }
};

const vtable = sink_mod.VTable{
    .destroy_entities = Recorder.destroyEntities,
    .spawn_player = Recorder.spawnPlayer,
    .spawn_mob = Recorder.spawnMob,
    .move_relative = Recorder.moveRelative,
    .look = Recorder.look,
    .move_look = Recorder.moveLook,
    .teleport = Recorder.teleport,
    .head_look = Recorder.headLook,
    .spawn_item = Recorder.spawnItem,
    .collect_item = Recorder.collectItem,
    .inventory_slot = Recorder.inventorySlot,
    .unload_chunk = Recorder.unloadChunk,
    .respawn = Recorder.respawn,
    .encode_column = Recorder.encodeColumn,
    .send_bulk = Recorder.sendBulk,
};
