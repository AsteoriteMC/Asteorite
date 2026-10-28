//! 1.7.10 world packets (block change/action, break animation, effects, sound).

const std = @import("std");
const codec = @import("../../../net/codec.zig");
const ids = @import("../ids.zig");
const game_ids = @import("../../../ids.zig");
const wire = @import("../wire_ids.zig");


/// Block Change 0x23 (1.7 form: separate id VarInt + meta u8, NOT packed).
pub fn frameBlockChange(x: i32, y: u8, z: i32, id: game_ids.Id, meta: u8, out: []u8) codec.CodecError![]const u8 {
    var payload: [16]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(x);
    try w.writeByte(y);
    try w.writeInt(z);
    try w.writeVarInt(@as(i32, wire.toWire(id)));
    try w.writeByte(meta);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.block_change), w.written(), out);
}


/// Block Action 0x24 (1.7.10: x, y as unsigned byte, z, byte1, byte2,
/// VarInt blockId). Pistons animate the vanilla client from this packet —
/// the client re-runs `onBlockEventReceived` locally and derives the same
/// final blocks, so the server must NOT also echo 0x23 for those cells.
pub fn frameBlockAction(x: i32, y: u16, z: i32, byte1: u8, byte2: u8, id: game_ids.Id, out: []u8) codec.CodecError![]const u8 {
    // Jar `gg.a(et)`: int x, SHORT y, int z, ubyte, ubyte, then a VarInt
    // block id (& 4095, resolved via Block.getBlockById). Omitting it
    // kicks vanilla clients opening chests (lid S24): the client reads
    // the 12 bytes and overruns by exactly 1 on the missing id.
    var payload: [24]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(x);
    try w.writeShort(@intCast(y));
    try w.writeInt(z);
    try w.writeByte(byte1);
    try w.writeByte(byte2);
    try w.writeVarInt(@as(i32, wire.toWire(id)));
    return try codec.framePacket(@intFromEnum(ids.PlayClient.block_action), w.written(), out);
}


/// Block Break Animation 0x25.
pub fn frameBlockBreakAnimation(eid: i32, x: i32, y: i32, z: i32, stage: i8, out: []u8) codec.CodecError![]const u8 {
    var payload: [32]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeVarInt(eid);
    try w.writeInt(x);
    try w.writeInt(y);
    try w.writeInt(z);
    try w.writeByte(@bitCast(stage));
    return try codec.framePacket(@intFromEnum(ids.PlayClient.block_break_animation), w.written(), out);
}


test "block change + animation frames parse back" {
    const entity = @import("entity.zig");
    var out: [64]u8 = undefined;
    const f = try frameBlockChange(10, 64, -3, game_ids.dirt, 2, &out);
    var r = codec.PacketReader.init(f);
    try std.testing.expectEqual(@as(i32, 0x23), (try codec.decodeFrame(&r)).id);
    try std.testing.expectEqual(@as(i32, 10), try r.readInt());
    try std.testing.expectEqual(@as(u8, 64), try r.readByte());
    try std.testing.expectEqual(@as(i32, -3), try r.readInt());
    try std.testing.expectEqual(@as(i32, 3), try r.readVarInt());
    try std.testing.expectEqual(@as(u8, 2), try r.readByte());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
    var ao: [32]u8 = undefined;
    const af = try entity.frameAnimation(7, 0, &ao);
    var ra = codec.PacketReader.init(af);
    try std.testing.expectEqual(@as(i32, 0x0B), (try codec.decodeFrame(&ra)).id);
    try std.testing.expectEqual(@as(i32, 7), try ra.readVarInt());
    try std.testing.expectEqual(@as(u8, 0), try ra.readByte());
    // S24 block action: jar `gg` reads int, SHORT, int, ubyte, ubyte,
    // then a VarInt block id (& 4095). Omitting it kicked vanilla
    // clients opening chests (lid S24 overran by exactly 1 byte).
    var ab: [32]u8 = undefined;
    const bf = try frameBlockAction(10, 64, -3, 1, 2, game_ids.chest, &ab);
    var rb = codec.PacketReader.init(bf);
    try std.testing.expectEqual(@as(i32, 0x24), (try codec.decodeFrame(&rb)).id);
    try std.testing.expectEqual(@as(i32, 10), try rb.readInt());
    try std.testing.expectEqual(@as(i16, 64), try rb.readShort());
    try std.testing.expectEqual(@as(i32, -3), try rb.readInt());
    try std.testing.expectEqual(@as(u8, 1), try rb.readByte());
    try std.testing.expectEqual(@as(u8, 2), try rb.readByte());
    try std.testing.expectEqual(wire.toWire(game_ids.chest), try rb.readVarInt());
    try std.testing.expectEqual(@as(usize, 0), rb.remaining());
}

test "explosion frame parses back (S27 layout)" {
    var out: [4096]u8 = undefined;
    const recs = [_]ExplosionRecord{
        .{ .dx = 0, .dy = 0, .dz = 0 },
        .{ .dx = -3, .dy = 1, .dz = 2 },
    };
    const f = try frameExplosion(10.5, 64.0, -3.25, 4.0, &recs, .{ 0.5, 1.0, -0.25 }, &out);
    var r = codec.PacketReader.init(f);
    try std.testing.expectEqual(@as(i32, 0x27), (try codec.decodeFrame(&r)).id);
    try std.testing.expectEqual(@as(f32, 10.5), try r.readFloat());
    try std.testing.expectEqual(@as(f32, 64.0), try r.readFloat());
    try std.testing.expectEqual(@as(f32, -3.25), try r.readFloat());
    try std.testing.expectEqual(@as(f32, 4.0), try r.readFloat());
    try std.testing.expectEqual(@as(i32, 2), try r.readInt());
    try std.testing.expectEqual(@as(u8, 0), try r.readByte());
    try std.testing.expectEqual(@as(u8, 0), try r.readByte());
    try std.testing.expectEqual(@as(u8, 0), try r.readByte());
    try std.testing.expectEqual(@as(u8, @bitCast(@as(i8, -3))), try r.readByte());
    try std.testing.expectEqual(@as(u8, 1), try r.readByte());
    try std.testing.expectEqual(@as(u8, 2), try r.readByte());
    try std.testing.expectEqual(@as(f32, 0.5), try r.readFloat());
    try std.testing.expectEqual(@as(f32, 1.0), try r.readFloat());
    try std.testing.expectEqual(@as(f32, -0.25), try r.readFloat());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}


/// Clientbound 0x29 NamedSoundEffect: coords are absolute blocks * 8,
/// volume float, pitch byte (vanilla scale: pitch * 63).
pub fn frameSoundEffect(name: []const u8, x: f64, y: f64, z: f64, volume: f32, pitch: f32, out: []u8) codec.CodecError![]const u8 {
    var payload: [512]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeString(name);
    try w.writeInt(@as(i32, @intFromFloat(@floor(x * 8.0))));
    try w.writeInt(@as(i32, @intFromFloat(@floor(y * 8.0))));
    try w.writeInt(@as(i32, @intFromFloat(@floor(z * 8.0))));
    try w.writeFloat(volume);
    const pb: i32 = @as(i32, @intFromFloat(pitch * 63.0));
    try w.writeByte(@intCast(@max(0, @min(255, pb))));
    return try codec.framePacket(@intFromEnum(ids.PlayClient.sound_effect), w.written(), out);
}


/// S27 record: one floor-relative block offset (client particles).
pub const ExplosionRecord = struct { dx: i8, dy: i8, dz: i8 };

/// Clientbound 0x27 Explosion (minecraft-data 1.7 `packet_explosion`:
/// f32 x/y/z, f32 radius, i32 count + i8 xyz triples, then 3x f32
/// player motion). Records are floor-relative byte offsets of the broken
/// cells (the client spawns particles there); the tail velocity is
/// per-viewer knockback (vanilla sends one S27 per player with their
/// own motion — no shared broadcast).
pub fn frameExplosion(
    x: f32,
    y: f32,
    z: f32,
    radius: f32,
    records: []const ExplosionRecord,
    vel: [3]f32,
    out: []u8,
) codec.CodecError![]const u8 {
    var payload: [4096]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeFloat(x);
    try w.writeFloat(y);
    try w.writeFloat(z);
    try w.writeFloat(radius);
    try w.writeInt(@as(i32, @intCast(records.len)));
    for (records) |r| {
        try w.writeByte(@bitCast(r.dx));
        try w.writeByte(@bitCast(r.dy));
        try w.writeByte(@bitCast(r.dz));
    }
    try w.writeFloat(vel[0]);
    try w.writeFloat(vel[1]);
    try w.writeFloat(vel[2]);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.explosion), w.written(), out);
}

/// Clientbound 0x2C SpawnGlobalEntity (lightning = type 1): fixed-point
/// absolute coords (* 32, floored like vanilla).
pub fn frameSpawnGlobalEntity(eid: i32, kind: u8, x: f64, y: f64, z: f64, out: []u8) codec.CodecError![]const u8 {
    var payload: [24]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeVarInt(eid);
    try w.writeByte(kind);
    try w.writeInt(@as(i32, @intFromFloat(@floor(x * 32.0))));
    try w.writeInt(@as(i32, @intFromFloat(@floor(y * 32.0))));
    try w.writeInt(@as(i32, @intFromFloat(@floor(z * 32.0))));
    return try codec.framePacket(@intFromEnum(ids.PlayClient.spawn_global_entity), w.written(), out);
}


/// Clientbound 0x28 Effect (world event: 2001 = block break particles).
/// Coords are absolute blocks * 8 (vanilla S28 layout).
pub fn frameWorldEffect(event_id: i32, x: i32, y: u8, z: i32, data: i32, out: []u8) codec.CodecError![]const u8 {
    var payload: [24]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(event_id);
    try w.writeInt(x * 8);
    try w.writeInt(@as(i32, y) * 8);
    try w.writeInt(z * 8);
    try w.writeInt(data);
    try w.writeByte(0); // volume decrease flag: 0 = full range
    return try codec.framePacket(@intFromEnum(ids.PlayClient.effect), w.written(), out);
}
