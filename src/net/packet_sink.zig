//! 1.7.10 implementation of the shared semantic packet sink.
//!
//! This is the only place the entity/view core meets v5 framing. The profile
//! is selected at compile time through `version.proto`/`version.game`; there
//! is no runtime protocol switch.

const std = @import("std");
const flate = std.compress.flate;
const Conn = @import("conn.zig").Conn;
const codec = @import("codec.zig");
const sink_mod = @import("../sim/packet_sink.zig");
const chunk_mod = @import("../world/chunk.zig");
const item_mod = @import("../item.zig");
const profile = @import("../version.zig");

const packets = profile.proto.packets;
const chunks = profile.proto.chunks;
const mobs = profile.game.mobs;

fn asConn(ctx: *anyopaque) *Conn {
    return @ptrCast(@alignCast(ctx));
}

fn destroyEntities(ctx: *anyopaque, ids: []const i32) anyerror!void {
    var buf: [4 + 255 * 4 + 8]u8 = undefined;
    const f = try packets.frameDestroyEntitiesFramed(ids, &buf);
    try asConn(ctx).queueFramed(f);
}

fn spawnPlayer(ctx: *anyopaque, spawn: *const sink_mod.PlayerSpawn) anyerror!void {
    var buf: [512]u8 = undefined;
    const f = try packets.frameSpawnPlayer(
        spawn.eid,
        &spawn.uuid,
        spawn.name[0..spawn.name_len],
        spawn.x,
        spawn.y,
        spawn.z,
        spawn.yaw,
        spawn.pitch,
        spawn.health,
        &buf,
    );
    try asConn(ctx).queueFramed(f);
}

fn spawnMob(ctx: *anyopaque, spawn: *const sink_mod.MobSpawn) anyerror!void {
    var buf: [256]u8 = undefined;
    const f = try packets.frameSpawnMob(
        spawn.eid,
        mobs.wire(spawn.kind),
        spawn.x,
        spawn.y,
        spawn.z,
        spawn.yaw,
        spawn.pitch,
        spawn.head_pitch,
        spawn.health,
        &buf,
    );
    try asConn(ctx).queueFramed(f);
}

fn moveRelative(ctx: *anyopaque, eid: i32, dx: i8, dy: i8, dz: i8) anyerror!void {
    var buf: [16]u8 = undefined;
    const f = try packets.frameEntityRelativeMove(eid, dx, dy, dz, &buf);
    try asConn(ctx).queueFramed(f);
}

fn look(ctx: *anyopaque, eid: i32, yaw: f32, pitch: f32) anyerror!void {
    var buf: [16]u8 = undefined;
    const f = try packets.frameEntityLook(eid, yaw, pitch, &buf);
    try asConn(ctx).queueFramed(f);
}

fn moveLook(ctx: *anyopaque, eid: i32, dx: i8, dy: i8, dz: i8, yaw: f32, pitch: f32) anyerror!void {
    var buf: [24]u8 = undefined;
    const f = try packets.frameEntityMoveLook(eid, dx, dy, dz, yaw, pitch, &buf);
    try asConn(ctx).queueFramed(f);
}

fn teleport(ctx: *anyopaque, eid: i32, x: f64, y: f64, z: f64, yaw: f32, pitch: f32) anyerror!void {
    var buf: [40]u8 = undefined;
    const f = try packets.frameEntityTeleport(eid, x, y, z, yaw, pitch, &buf);
    try asConn(ctx).queueFramed(f);
}

fn headLook(ctx: *anyopaque, eid: i32, yaw: f32) anyerror!void {
    var buf: [16]u8 = undefined;
    const f = try packets.frameEntityHeadLook(eid, yaw, &buf);
    try asConn(ctx).queueFramed(f);
}

fn spawnItem(ctx: *anyopaque, spawn: *const sink_mod.ItemSpawn) anyerror!void {
    const conn = asConn(ctx);
    var sb: [96]u8 = undefined;
    const spawn_frame = try packets.frameSpawnObject(spawn.eid, 2, spawn.x, spawn.y, spawn.z, 0, 0, 1, null, &sb);
    try conn.queueFramed(spawn_frame);
    var mb: [1024]u8 = undefined;
    const meta_frame = try packets.frameItemMetadata(spawn.eid, spawn.stack, &mb);
    try conn.queueFramed(meta_frame);
}

fn collectItem(ctx: *anyopaque, collected_eid: i32, collector_eid: i32) anyerror!void {
    var buf: [24]u8 = undefined;
    const f = try packets.frameCollect(collected_eid, collector_eid, &buf);
    try asConn(ctx).queueFramed(f);
}

fn inventorySlot(ctx: *anyopaque, window: i8, slot: i16, stack: ?item_mod.Stack) anyerror!void {
    const conn = asConn(ctx);
    const f = try packets.frameSetSlotAlloc(conn.allocator, window, slot, stack);
    defer conn.allocator.free(f);
    try conn.queueFramed(f);
}

fn unloadChunk(ctx: *anyopaque, x: i32, z: i32) anyerror!void {
    var buf: [2048]u8 = undefined;
    const f = try chunks.frameUnloadChunk(x, z, &buf);
    try asConn(ctx).queueFramed(f);
}

fn respawn(ctx: *anyopaque) anyerror!void {
    const conn = asConn(ctx);
    var buf: [256]u8 = undefined;
    const f = try packets.frameRespawn(0, conn.config.difficulty.wire(), conn.config.gamemode.wire(), conn.config.level_type, &buf);
    try conn.queueFramed(f);
}

fn encodeColumn(ctx: *anyopaque, ch: *const chunk_mod.Chunk, sky: bool, out: []u8) anyerror!sink_mod.ColumnLayout {
    _ = ctx;
    const layout = chunks.encodeColumn(ch, sky, out);
    return .{ .primary = layout.primary, .add = layout.add, .len = layout.len };
}

fn ensureBulkScratch(conn: *Conn, raw_len: usize) !void {
    const a = conn.allocator;
    const comp_need = raw_len + raw_len / 1024 + 4096;
    if (conn.bulk_comp.len < comp_need) {
        const comp = try a.alloc(u8, comp_need);
        if (conn.bulk_comp.len > 0) a.free(conn.bulk_comp);
        conn.bulk_comp = comp;
    }
    if (conn.bulk_work.len < flate.max_window_len) {
        const work = try a.alloc(u8, flate.max_window_len);
        if (conn.bulk_work.len > 0) a.free(conn.bulk_work);
        conn.bulk_work = work;
    }
}

fn sendBulk(ctx: *anyopaque, cols: []const sink_mod.BulkColumn, raw: []const u8, sky: bool) anyerror!void {
    const conn = asConn(ctx);
    const a = conn.allocator;
    if (cols.len > std.math.maxInt(i16)) return error.TooManyColumns;
    try ensureBulkScratch(conn, raw.len);
    const compressed = try chunks.zlibCompress(raw, conn.bulk_comp, conn.bulk_work);

    const wire_cols = try a.alloc(chunks.BulkColumn, cols.len);
    defer a.free(wire_cols);
    for (cols, 0..) |c, i| {
        wire_cols[i] = .{ .x = c.x, .z = c.z, .primary = c.primary, .add = c.add };
    }

    const out = try a.alloc(u8, 16 + compressed.len + 12 * cols.len);
    defer a.free(out);
    const f = try chunks.frameMapChunkBulk(wire_cols, compressed, sky, out);
    try conn.queueFramed(f);
}

const vtable = sink_mod.VTable{
    .destroy_entities = destroyEntities,
    .spawn_player = spawnPlayer,
    .spawn_mob = spawnMob,
    .move_relative = moveRelative,
    .look = look,
    .move_look = moveLook,
    .teleport = teleport,
    .head_look = headLook,
    .spawn_item = spawnItem,
    .collect_item = collectItem,
    .inventory_slot = inventorySlot,
    .unload_chunk = unloadChunk,
    .respawn = respawn,
    .encode_column = encodeColumn,
    .send_bulk = sendBulk,
};

/// Bind the selected profile's codec to one connection.
pub fn bind(conn: *Conn) sink_mod.PacketSink {
    return .{ .ctx = @ptrCast(conn), .vtable = &vtable };
}

test "sink maps canonical mob kind to the v5 SpawnMob type id" {
    const a = std.testing.allocator;
    var c = Conn.init(a, std.testing.io, .{}, 7);
    defer c.deinit();
    c.state = .play;

    var spawn = sink_mod.MobSpawn{ .eid = 7, .kind = .cow, .x = 1, .y = 64, .z = -2, .health = 10 };
    try bind(&c).spawnMob(&spawn);

    const out = try c.takeOutput();
    defer a.free(out);
    var r = codec.PacketReader.init(out);
    const h = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, @intFromEnum(profile.proto.ids.PlayClient.spawn_mob)), h.id);
    try std.testing.expectEqual(@as(i32, 7), try r.readVarInt());
    try std.testing.expectEqual(@as(u8, 92), try r.readByte());
}

test "sink item spawn emits object + metadata, inventory/collect/destroy frame" {
    const a = std.testing.allocator;
    var c = Conn.init(a, std.testing.io, .{}, 9);
    defer c.deinit();
    c.state = .play;
    const sink = bind(&c);

    var item = sink_mod.ItemSpawn{
        .eid = 51,
        .stack = .{ .id = @import("../ids.zig").diamond, .count = 3, .damage = 0, .nbt = null },
        .x = 0.5,
        .y = 64,
        .z = 0.5,
    };
    try sink.spawnItem(&item);
    try sink.collectItem(51, 9);
    try sink.inventorySlot(0, 9, item.stack);
    try sink.destroyEntities(&[_]i32{51});

    const out = try c.takeOutput();
    defer a.free(out);
    var r = codec.PacketReader.init(out);
    const ids_seen = [_]i32{ 0x0E, 0x1C, 0x0D, 0x2F, 0x13 };
    for (ids_seen) |expected| {
        const h = try codec.decodeFrame(&r);
        try std.testing.expectEqual(expected, h.id);
        const body_len: usize = @intCast(h.length - @as(i32, @intCast(codec.PacketWriter.varIntLen(h.id))));
        r.index += body_len;
    }
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "sink encodes and bulk-frames a canonical column, then unload/respawn" {
    const a = std.testing.allocator;
    var c = Conn.init(a, std.testing.io, .{}, 3);
    defer c.deinit();
    c.state = .play;
    const sink = bind(&c);

    const ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
    defer ch.destroy(a);
    var section = chunk_mod.Section{};
    section.setBlock(0, 0, 0, @import("../ids.zig").stone);
    ch.sections[0] = section;

    const raw = try a.alloc(u8, 196864);
    defer a.free(raw);
    const layout = try sink.encodeColumn(ch, true, raw);
    try std.testing.expectEqual(@as(u16, 1), layout.primary);
    try std.testing.expectEqual(@as(u16, 0), layout.add);
    try std.testing.expectEqual(@as(usize, 4096 + 2048 * 3 + 256), layout.len);
    try std.testing.expectEqual(@as(u8, 1), raw[0]); // stone wire id

    const cols = [_]sink_mod.BulkColumn{.{ .x = 0, .z = 0, .primary = layout.primary, .add = layout.add }};
    try sink.sendBulk(&cols, raw[0..layout.len], true);

    {
        const out = try c.takeOutput();
        defer a.free(out);
        var r = codec.PacketReader.init(out);
        const h = try codec.decodeFrame(&r);
        try std.testing.expectEqual(@as(i32, 0x26), h.id);
        try std.testing.expectEqual(@as(i16, 1), try r.readShort());
        const dlen = try r.readInt();
        try std.testing.expect(try r.readBool());
        const zdata = try r.readBytes(@intCast(dlen));
        try std.testing.expectEqual(@as(i32, 0), try r.readInt());
        try std.testing.expectEqual(@as(i32, 0), try r.readInt());
        try std.testing.expectEqual(@as(u16, 1), try r.readUShort());
        try std.testing.expectEqual(@as(u16, 0), try r.readUShort());

        var in: std.Io.Reader = .fixed(zdata);
        var aw: std.Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        var decomp = flate.Decompress.init(&in, .zlib, &.{});
        _ = try decomp.reader.streamRemaining(&aw.writer);
        try std.testing.expectEqual(layout.len, aw.written().len);
        try std.testing.expectEqual(@as(u8, 1), aw.written()[0]);
    }

    try sink.unloadChunk(7, 9);
    {
        const out = try c.takeOutput();
        defer a.free(out);
        var r = codec.PacketReader.init(out);
        const h = try codec.decodeFrame(&r);
        try std.testing.expectEqual(@as(i32, 0x21), h.id);
        try std.testing.expectEqual(@as(i32, 7), try r.readInt());
        try std.testing.expectEqual(@as(i32, 9), try r.readInt());
    }

    try sink.respawn();
    {
        const out = try c.takeOutput();
        defer a.free(out);
        var r = codec.PacketReader.init(out);
        const h = try codec.decodeFrame(&r);
        try std.testing.expectEqual(@as(i32, 0x07), h.id);
        try std.testing.expectEqual(@as(i32, 0), try r.readInt());
    }
}
