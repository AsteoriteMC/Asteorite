//! 1.7.10 entity packets (spawn, move, look, teleport, metadata, effects).

const std = @import("std");
const codec = @import("../../../net/codec.zig");
const ids = @import("../ids.zig");
const item_mod = @import("../../../item.zig");
const slot_mod = @import("../slot.zig");
const game_ids = @import("../../../ids.zig");


/// Animation 0x0B (swing arm etc, relayed to viewers).
pub fn frameAnimation(eid: i32, animation: u8, out: []u8) codec.CodecError![]const u8 {
    var payload: [8]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeVarInt(eid);
    try w.writeByte(animation);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.animation), w.written(), out);
}


/// 1.7 fixed-point: absolute int = floor(double * 32).
pub fn toFixed(v: f64) i32 {
    return @as(i32, @intFromFloat(@floor(v * 32.0)));
}


/// Rotation packed byte: yaw degrees -> fraction of 360 (wraps negatives).
pub fn toPackedByte(degrees: f32) i8 {
    const steps = @floor(degrees * (256.0 / 360.0));
    return @as(i8, @truncate(@as(i32, @intFromFloat(steps))));
}


/// Minimal living-entity metadata (index 0 flags, 1 air, 6 health) + 0x7F end.
/// 1.7 clients crash when player spawn carries no metadata at all.
pub fn writeLivingBaseline(w: *codec.PacketWriter, health: f32) codec.CodecError!void {
    try w.writeByte((0 << 5) | 0); // type byte(0), index 0
    try w.writeByte(0); // flags
    try w.writeByte((1 << 5) | 1); // type short(1), index 1
    try w.writeShort(300); // air
    try w.writeByte((3 << 5) | 6); // type float(3), index 6 (3, not 2: 2 is int)
    const u: u32 = @bitCast(health);
    var fb: [4]u8 = undefined;
    std.mem.writeInt(u32, &fb, u, .big);
    try w.writeBytes(&fb);
    try w.writeByte(0x7F); // end
}


/// Spawn Player 0x0C. position_iii fixed-point ints, yaw/pitch packed bytes.
/// properties: empty (count 0) for offline players; session properties P-next.
pub fn frameSpawnPlayer(eid: i32, uuid_str: []const u8, name: []const u8, x: f64, y: f64, z: f64, yaw: f32, pitch: f32, health: f32, out: []u8) codec.CodecError![]const u8 {
    var payload: [256]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeVarInt(eid);
    try w.writeString(uuid_str);
    try w.writeString(name);
    try w.writeVarInt(0); // property count
    try w.writeInt(toFixed(x));
    try w.writeInt(toFixed(y));
    try w.writeInt(toFixed(z));
    try w.writeByte(@bitCast(toPackedByte(yaw)));
    try w.writeByte(@bitCast(toPackedByte(pitch)));
    try w.writeShort(0); // current item: none
    try writeLivingBaseline(&w, health);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.spawn_player), w.written(), out);
}


/// Spawn Mob 0x0F.
pub fn frameSpawnMob(eid: i32, mob_type: u8, x: f64, y: f64, z: f64, yaw: f32, pitch: f32, head_pitch: f32, health: f32, out: []u8) codec.CodecError![]const u8 {
    var payload: [128]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeVarInt(eid);
    try w.writeByte(mob_type);
    try w.writeInt(toFixed(x));
    try w.writeInt(toFixed(y));
    try w.writeInt(toFixed(z));
    try w.writeByte(@bitCast(toPackedByte(yaw)));
    try w.writeByte(@bitCast(toPackedByte(pitch)));
    try w.writeByte(@bitCast(toPackedByte(head_pitch)));
    try w.writeShort(0); // vel x
    try w.writeShort(0); // vel y
    try w.writeShort(0); // vel z
    try writeLivingBaseline(&w, health);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.spawn_mob), w.written(), out);
}


/// Destroy Entities 0x13, framed. Count is a single byte (max 255 per packet).
pub fn frameDestroyEntitiesFramed(eids: []const i32, out: []u8) codec.CodecError![]const u8 {
    if (eids.len > 255) return error.PacketTooLarge;
    var payload: [4 + 255 * 4]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeByte(@intCast(eids.len));
    for (eids) |id| try w.writeInt(id);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.destroy_entities), w.written(), out);
}


/// Entity Teleport 0x18 (fixed-point ints, packed bytes).
pub fn frameEntityTeleport(eid: i32, x: f64, y: f64, z: f64, yaw: f32, pitch: f32, out: []u8) codec.CodecError![]const u8 {
    var payload: [32]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(eid);
    try w.writeInt(toFixed(x));
    try w.writeInt(toFixed(y));
    try w.writeInt(toFixed(z));
    try w.writeByte(@bitCast(toPackedByte(yaw)));
    try w.writeByte(@bitCast(toPackedByte(pitch)));
    return try codec.framePacket(@intFromEnum(ids.PlayClient.entity_teleport), w.written(), out);
}


/// Entity Relative Move 0x15 (byte deltas, |d| <= 127 enforced by caller).
pub fn frameEntityRelativeMove(eid: i32, dx: i8, dy: i8, dz: i8, out: []u8) codec.CodecError![]const u8 {
    var payload: [8]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(eid);
    try w.writeByte(@bitCast(dx));
    try w.writeByte(@bitCast(dy));
    try w.writeByte(@bitCast(dz));
    return try codec.framePacket(@intFromEnum(ids.PlayClient.entity_relative_move), w.written(), out);
}


/// Entity Look 0x16.
pub fn frameEntityLook(eid: i32, yaw: f32, pitch: f32, out: []u8) codec.CodecError![]const u8 {
    var payload: [8]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(eid);
    try w.writeByte(@bitCast(toPackedByte(yaw)));
    try w.writeByte(@bitCast(toPackedByte(pitch)));
    return try codec.framePacket(@intFromEnum(ids.PlayClient.entity_look), w.written(), out);
}


/// Entity Look and Relative Move 0x17.
pub fn frameEntityMoveLook(eid: i32, dx: i8, dy: i8, dz: i8, yaw: f32, pitch: f32, out: []u8) codec.CodecError![]const u8 {
    var payload: [12]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(eid);
    try w.writeByte(@bitCast(dx));
    try w.writeByte(@bitCast(dy));
    try w.writeByte(@bitCast(dz));
    try w.writeByte(@bitCast(toPackedByte(yaw)));
    try w.writeByte(@bitCast(toPackedByte(pitch)));
    return try codec.framePacket(@intFromEnum(ids.PlayClient.entity_look_and_relative_move), w.written(), out);
}


/// Entity Head Look 0x19.
pub fn frameEntityHeadLook(eid: i32, yaw: f32, out: []u8) codec.CodecError![]const u8 {
    var payload: [8]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(eid);
    try w.writeByte(@bitCast(toPackedByte(yaw)));
    return try codec.framePacket(@intFromEnum(ids.PlayClient.entity_head_look), w.written(), out);
}


/// Spawn Object 0x0E. Vanilla EntityTrackerEntry (`my.c()`): items spawn as
/// type 2 with data 1 (CFR-verified against the official 1.7.10 server jar),
/// which makes the client read 3 velocity shorts (clamped x8000 server-side).
/// Pitch is written before yaw on the wire.
pub fn frameSpawnObject(eid: i32, obj_type: u8, x: f64, y: f64, z: f64, pitch: f32, yaw: f32, data: i32, vel: ?[3]i16, out: []u8) codec.CodecError![]const u8 {
    var payload: [64]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeVarInt(eid);
    try w.writeByte(obj_type);
    try w.writeInt(toFixed(x));
    try w.writeInt(toFixed(y));
    try w.writeInt(toFixed(z));
    try w.writeByte(@bitCast(toPackedByte(pitch)));
    try w.writeByte(@bitCast(toPackedByte(yaw)));
    try w.writeInt(data);
    if (data > 0) {
        const v = vel orelse [3]i16{ 0, 0, 0 };
        try w.writeShort(v[0]);
        try w.writeShort(v[1]);
        try w.writeShort(v[2]);
    }
    return try codec.framePacket(@intFromEnum(ids.PlayClient.spawn_object), w.written(), out);
}


/// Collect Item 0x0D: collected eid first, collector eid second (both i32 —
/// NOT varints; verified against minecraft-data 1.7 + `ij` decompile).
pub fn frameCollect(collected_eid: i32, collector_eid: i32, out: []u8) codec.CodecError![]const u8 {
    var payload: [8]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(collected_eid);
    try w.writeInt(collector_eid);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.collect_item), w.written(), out);
}


/// Item-stack Entity Metadata 0x1C: full watcher `[(0: byte 0), (1: short
/// 300), (10: slot)]` + 0x7F end. Vanilla EntityTrackerEntry (`my.b`)
/// sends the spawn packet then the FULL DataWatcher list (`new hw(eid,
/// watcher, true)`); the base Entity inits 0/1 and EntityItem adds slot 10.
/// The spawn packet itself carries no metadata.
pub fn frameItemMetadata(eid: i32, stack: item_mod.Stack, out: []u8) codec.CodecError![]const u8 {
    var payload: [512]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(eid);
    try w.writeByte((0 << 5) | 0); // type byte(0), index 0: flags
    try w.writeByte(0);
    try w.writeByte((1 << 5) | 1); // type short(1), index 1: air
    try w.writeShort(300);
    try w.writeByte((5 << 5) | 10); // type slot(5), index 10: the stack
    try slot_mod.writeSlot(&w, stack);
    try w.writeByte(0x7F); // end
    return try codec.framePacket(@intFromEnum(ids.PlayClient.entity_metadata), w.written(), out);
}

/// Entity Metadata 0x1C with a living-entity baseline body.
pub fn frameEntityMetadata(eid: i32, health: f32, out: []u8) codec.CodecError![]const u8 {
    var payload: [32]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(eid);
    try writeLivingBaseline(&w, health);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.entity_metadata), w.written(), out);
}


/// Boss-bar metadata (DataWatcher subset for a fake Wither, type 64):
/// (0: byte flags with invisible bit), (6: float health),
/// (10: string custom name), (11: byte show-name, off) + 0x7F end.
///
/// There is NO bossbar packet in 1.7.10: the bar is purely client-side.
/// RenderWither feeds BossStatus (title = custom name, fill =
/// health/300.0) while rendering the entity, and GuiIngame draws it
/// (jar-verified: only client classes touch BossStatus; the server side
/// just spawns/tracks a normal Wither). Name/tag indices 10/11 and the
/// 300.0 max-health attribute are likewise jar-verified (sw/xc).
///
/// Invisibility hides the model and the nametag but NOT the wither's
/// particle emitters (jar-verified onLivingUpdate): 3 smoke puffs per tick
/// at the head positions unconditionally, plus a mobSpell aura while
/// "armored" (health <= max/2 — the whole first half of a 0→100% bar).
/// The follow point therefore sits pregen_bar_drop below the owner's feet
/// (server.zig), putting the heads below the ahead-view instead of in the
/// camera. Groans still play: sounds are client-tick random and muting one
/// entity is not on the 1.7.10 protocol.
pub fn writeBossMetadata(w: *codec.PacketWriter, health: f32, name: []const u8) codec.CodecError!void {
    try w.writeByte((0 << 5) | 0); // type byte(0), index 0: flags
    try w.writeByte(0x20); // invisible (vanilla flag bit 5)
    try w.writeByte((3 << 5) | 6); // type float(3), index 6: health
    const u: u32 = @bitCast(health);
    var fb: [4]u8 = undefined;
    std.mem.writeInt(u32, &fb, u, .big);
    try w.writeBytes(&fb);
    try w.writeByte((4 << 5) | 10); // type string(4), index 10: custom name
    try w.writeString(name);
    try w.writeByte((0 << 5) | 11); // type byte(0), index 11: show name tag
    try w.writeByte(0); // tag stays hidden; the bar title still uses the name
    try w.writeByte(0x7F); // end
}

/// Spawn Mob 0x0F carrying boss-bar metadata (fake Wither for a task bar).
/// The wither never exists server-side: no AI, no saves, no interaction —
/// just the spawn + per-tick metadata/teleport frames to one viewer.
pub fn frameBossSpawn(eid: i32, x: f64, y: f64, z: f64, health: f32, name: []const u8, out: []u8) codec.CodecError![]const u8 {
    var payload: [320]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeVarInt(eid);
    try w.writeByte(64); // WitherBoss (EntityList-verified)
    try w.writeInt(toFixed(x));
    try w.writeInt(toFixed(y));
    try w.writeInt(toFixed(z));
    try w.writeByte(@bitCast(toPackedByte(0)));
    try w.writeByte(@bitCast(toPackedByte(0)));
    try w.writeByte(@bitCast(toPackedByte(0)));
    try w.writeShort(0); // vel x
    try w.writeShort(0); // vel y
    try w.writeShort(0); // vel z
    try writeBossMetadata(&w, health, name);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.spawn_mob), w.written(), out);
}

/// Entity Metadata 0x1C boss refresh (health fill + title).
pub fn frameBossUpdate(eid: i32, health: f32, name: []const u8, out: []u8) codec.CodecError![]const u8 {
    var payload: [320]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(eid);
    try writeBossMetadata(&w, health, name);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.entity_metadata), w.written(), out);
}


test "entity packets roundtrip" {
    var buf: [512]u8 = undefined;
    // fixed-point + packed yaw edge cases
    try std.testing.expectEqual(@as(i32, 0), toFixed(0.0));
    try std.testing.expectEqual(@as(i32, 272), toFixed(8.5));
    try std.testing.expectEqual(@as(i32, -1280), toFixed(-40.0));
    try std.testing.expectEqual(@as(i8, 0), toPackedByte(0));
    try std.testing.expectEqual(@as(i8, 64), toPackedByte(90));
    try std.testing.expectEqual(@as(i8, -64), toPackedByte(270)); // wraps
    // spawn player
    {
        const f = try frameSpawnPlayer(7, "52d22a52-7b4a-339e-8a09-aa52384d72fd", "Steve", 8.5, 64.0, 8.5, 90.0, 0.0, 20.0, &buf);
        var r = codec.PacketReader.init(f);
        try std.testing.expectEqual(@as(i32, 0x0C), (try codec.decodeFrame(&r)).id);
        try std.testing.expectEqual(@as(i32, 7), try r.readVarInt());
        try std.testing.expectEqualStrings("52d22a52-7b4a-339e-8a09-aa52384d72fd", try r.readString());
        try std.testing.expectEqualStrings("Steve", try r.readString());
        try std.testing.expectEqual(@as(i32, 0), try r.readVarInt()); // no properties
        try std.testing.expectEqual(@as(i32, 272), try r.readInt());
        try std.testing.expectEqual(@as(i32, 2048), try r.readInt());
        // metadata present (terminator 0x7F at end) so notch client won't crash
        try std.testing.expect(r.buffer[r.index..].len > 1);
        try std.testing.expectEqual(@as(u8, 0x7F), r.buffer[r.index..][r.buffer[r.index..].len - 1]);
    }
    // living baseline pins vanilla DataWatcher types: (0:byte)(1:short 300)
    // (6:float) + 0x7F. Tagging health as int(2) crashes 1.7.10 with
    // ClassCastException Integer->Float on the first living-entity tick.
    {
        var wb: [32]u8 = undefined;
        var w = codec.PacketWriter.init(&wb);
        try writeLivingBaseline(&w, 20.0);
        const got = w.written();
        try std.testing.expectEqual(@as(usize, 11), got.len);
        try std.testing.expectEqual(@as(u8, 0x00), got[0]); // (0<<5)|0
        try std.testing.expectEqual(@as(u8, 0x00), got[1]); // flags
        try std.testing.expectEqual(@as(u8, 0x21), got[2]); // (1<<5)|1
        try std.testing.expectEqual(@as(i16, 300), std.mem.readInt(i16, got[3..5], .big));
        try std.testing.expectEqual(@as(u8, 0x66), got[5]); // (3<<5)|6 float
        try std.testing.expectEqual(@as(f32, 20.0), @as(f32, @bitCast(std.mem.readInt(u32, got[6..10], .big))));
        try std.testing.expectEqual(@as(u8, 0x7F), got[10]);
    }
    // spawn mob (pig 90)
    {
        const f = try frameSpawnMob(8, 90, 10.5, 64.0, -3.25, 180.0, 0.0, 180.0, 10.0, &buf);
        var r = codec.PacketReader.init(f);
        try std.testing.expectEqual(@as(i32, 0x0F), (try codec.decodeFrame(&r)).id);
        try std.testing.expectEqual(@as(i32, 8), try r.readVarInt());
        try std.testing.expectEqual(@as(u8, 90), try r.readByte());
    }
    // destroy (byte count)
    {
        const f = try frameDestroyEntitiesFramed(&[_]i32{ 7, 8 }, &buf);
        var r = codec.PacketReader.init(f);
        try std.testing.expectEqual(@as(i32, 0x13), (try codec.decodeFrame(&r)).id);
        try std.testing.expectEqual(@as(u8, 2), try r.readByte());
        try std.testing.expectEqual(@as(i32, 7), try r.readInt());
        try std.testing.expectEqual(@as(i32, 8), try r.readInt());
    }
    // teleport / relmove / look / movelook / headlook / metadata ids
    {
        var b2: [64]u8 = undefined;
        const t = try frameEntityTeleport(9, 1.5, 65.0, 2.5, 45.0, -10.0, &b2);
        var r = codec.PacketReader.init(t);
        try std.testing.expectEqual(@as(i32, 0x18), (try codec.decodeFrame(&r)).id);
        try std.testing.expectEqual(@as(i32, 9), try r.readInt());
        try std.testing.expectEqual(@as(i32, 48), try r.readInt());
        const m = try frameEntityRelativeMove(9, 1, -2, 3, &b2);
        var r2 = codec.PacketReader.init(m);
        try std.testing.expectEqual(@as(i32, 0x15), (try codec.decodeFrame(&r2)).id);
        const l = try frameEntityLook(9, 90.0, 0.0, &b2);
        var r3 = codec.PacketReader.init(l);
        try std.testing.expectEqual(@as(i32, 0x16), (try codec.decodeFrame(&r3)).id);
        const ml = try frameEntityMoveLook(9, 1, 0, 0, 90.0, 0.0, &b2);
        var r4 = codec.PacketReader.init(ml);
        try std.testing.expectEqual(@as(i32, 0x17), (try codec.decodeFrame(&r4)).id);
        const hl = try frameEntityHeadLook(9, 180.0, &b2);
        var r5 = codec.PacketReader.init(hl);
        try std.testing.expectEqual(@as(i32, 0x19), (try codec.decodeFrame(&r5)).id);
        const md = try frameEntityMetadata(9, 20.0, &b2);
        var r6 = codec.PacketReader.init(md);
        try std.testing.expectEqual(@as(i32, 0x1C), (try codec.decodeFrame(&r6)).id);
    }
    // effect packets carry INT eids (jar `in`/`hr` read readInt, not
    // varint — a varint eid shifts every later field and crashes the
    // vanilla parser past the frame end).
    {
        var b3: [64]u8 = undefined;
        const e = try frameEntityEffect(300, 1, 2, 200, &b3);
        var re = codec.PacketReader.init(e);
        try std.testing.expectEqual(@as(i32, 0x1D), (try codec.decodeFrame(&re)).id);
        try std.testing.expectEqual(@as(i32, 300), try re.readInt());
        try std.testing.expectEqual(@as(u8, 1), try re.readByte());
        try std.testing.expectEqual(@as(u8, 2), try re.readByte());
        try std.testing.expectEqual(@as(i16, 200), try re.readShort());
        try std.testing.expectEqual(@as(usize, 0), re.remaining());
        const x = try frameRemoveEntityEffect(300, 1, &b3);
        var rx = codec.PacketReader.init(x);
        try std.testing.expectEqual(@as(i32, 0x1E), (try codec.decodeFrame(&rx)).id);
        try std.testing.expectEqual(@as(i32, 300), try rx.readInt());
        try std.testing.expectEqual(@as(u8, 1), try rx.readByte());
        try std.testing.expectEqual(@as(usize, 0), rx.remaining());
    }
}


test "boss bar spawn/update carry wither type + invisible/health/name watcher" {
    var b3: [512]u8 = undefined;
    const s = try frameBossSpawn(-424242, 8.5, 24.0, 8.5, 150.0, "Pregeneration 50%", &b3);
    var r = codec.PacketReader.init(s);
    try std.testing.expectEqual(@as(i32, 0x0F), (try codec.decodeFrame(&r)).id);
    try std.testing.expectEqual(@as(i32, -424242), try r.readVarInt());
    try std.testing.expectEqual(@as(u8, 64), try r.readByte()); // WitherBoss
    try std.testing.expectEqual(@as(i32, 272), try r.readInt()); // 8.5*32
    try std.testing.expectEqual(@as(i32, 768), try r.readInt()); // 24*32
    try std.testing.expectEqual(@as(i32, 272), try r.readInt()); // 8.5*32
    // skip yaw/pitch/head + velocities to the metadata tail
    _ = try r.readByte();
    _ = try r.readByte();
    _ = try r.readByte();
    _ = try r.readShort();
    _ = try r.readShort();
    _ = try r.readShort();
    try std.testing.expectEqual(@as(u8, 0x00), try r.readByte()); // (0<<5)|0 flags
    try std.testing.expectEqual(@as(u8, 0x20), try r.readByte()); // invisible
    try std.testing.expectEqual(@as(u8, 0x66), try r.readByte()); // (3<<5)|6 health
    try std.testing.expectEqual(@as(f32, 150.0), @as(f32, @bitCast(try r.readInt())));
    try std.testing.expectEqual(@as(u8, 0x8A), try r.readByte()); // (4<<5)|10 name
    try std.testing.expectEqualStrings("Pregeneration 50%", try r.readString());
    try std.testing.expectEqual(@as(u8, 0x0B), try r.readByte()); // (0<<5)|11 show-name
    try std.testing.expectEqual(@as(u8, 0x00), try r.readByte()); // tag hidden
    try std.testing.expectEqual(@as(u8, 0x7F), try r.readByte()); // end
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
    const u = try frameBossUpdate(-424242, 300.0, "Pregeneration 100%", &b3);
    var ru = codec.PacketReader.init(u);
    try std.testing.expectEqual(@as(i32, 0x1C), (try codec.decodeFrame(&ru)).id);
    try std.testing.expectEqual(@as(i32, -424242), try ru.readInt());
}


test "item entity packets roundtrip (spawn/collect/slot-10)" {
    var buf: [1024]u8 = undefined;
    // spawn object type 2 (item), data 1 -> 3 velocity shorts present
    {
        const f = try frameSpawnObject(51, 2, 8.5, 64.0, -3.25, 0.0, 90.0, 1, .{ 10, -20, 30 }, &buf);
        var r = codec.PacketReader.init(f);
        try std.testing.expectEqual(@as(i32, 0x0E), (try codec.decodeFrame(&r)).id);
        try std.testing.expectEqual(@as(i32, 51), try r.readVarInt());
        try std.testing.expectEqual(@as(u8, 2), try r.readByte());
        try std.testing.expectEqual(@as(i32, 272), try r.readInt()); // 8.5*32
        try std.testing.expectEqual(@as(i32, 2048), try r.readInt()); // 64*32
        try std.testing.expectEqual(@as(i32, -104), try r.readInt()); // floor(-3.25*32)
        try std.testing.expectEqual(@as(u8, 0), try r.readByte()); // pitch first
        try std.testing.expectEqual(@as(u8, 64), try r.readByte()); // yaw 90 -> 64
        try std.testing.expectEqual(@as(i32, 1), try r.readInt()); // data
        try std.testing.expectEqual(@as(i16, 10), try r.readShort());
        try std.testing.expectEqual(@as(i16, -20), try r.readShort());
        try std.testing.expectEqual(@as(i16, 30), try r.readShort());
        try std.testing.expectEqual(@as(usize, 0), r.remaining());
    }
    // data 0 -> no velocity tail (minecart-style); explicit null vel is zeroed
    {
        const f = try frameSpawnObject(52, 2, 0.0, 64.0, 0.0, 0.0, 0.0, 1, null, &buf);
        var r = codec.PacketReader.init(f);
        try std.testing.expectEqual(@as(i32, 0x0E), (try codec.decodeFrame(&r)).id);
        _ = try r.readVarInt();
        _ = try r.readByte();
        _ = try r.readInt();
        _ = try r.readInt();
        _ = try r.readInt();
        _ = try r.readByte();
        _ = try r.readByte();
        try std.testing.expectEqual(@as(i32, 1), try r.readInt());
        try std.testing.expectEqual(@as(i16, 0), try r.readShort());
        try std.testing.expectEqual(@as(i16, 0), try r.readShort());
        try std.testing.expectEqual(@as(i16, 0), try r.readShort());
        try std.testing.expectEqual(@as(usize, 0), r.remaining());
    }
    // collect: two i32s, collected first
    {
        const f = try frameCollect(51, 7, &buf);
        var r = codec.PacketReader.init(f);
        try std.testing.expectEqual(@as(i32, 0x0D), (try codec.decodeFrame(&r)).id);
        try std.testing.expectEqual(@as(i32, 51), try r.readInt());
        try std.testing.expectEqual(@as(i32, 7), try r.readInt());
        try std.testing.expectEqual(@as(usize, 0), r.remaining());
    }
    // item metadata: eid + flags/air baseline + 0xAA head + slot + 0x7F end
    {
        const stack = item_mod.Stack{ .id = game_ids.diamond, .count = 1, .damage = 0, .nbt = null };
        const f = try frameItemMetadata(51, stack, &buf);
        var r = codec.PacketReader.init(f);
        try std.testing.expectEqual(@as(i32, 0x1C), (try codec.decodeFrame(&r)).id);
        try std.testing.expectEqual(@as(i32, 51), try r.readInt());
        try std.testing.expectEqual(@as(u8, 0x00), try r.readByte());
        try std.testing.expectEqual(@as(u8, 0x00), try r.readByte());
        try std.testing.expectEqual(@as(u8, 0x21), try r.readByte());
        try std.testing.expectEqual(@as(i16, 300), try r.readShort());
        try std.testing.expectEqual(@as(u8, 0xAA), try r.readByte());
        const back = try slot_mod.readSlot(&r);
        try std.testing.expect(back != null);
        try std.testing.expect(item_mod.stacksEqual(back, stack));
        try std.testing.expectEqual(@as(u8, 0x7F), try r.readByte());
        try std.testing.expectEqual(@as(usize, 0), r.remaining());
    }
}


/// Clientbound 0x1D EntityEffect: duration in ticks (vanilla truncates to
/// i16 — huge /effect durations wrap exactly like the 1.7.10 client shows).
/// Entity Effect 0x1D (jar `in`: int eid, byte effect, byte amplifier,
/// short duration — NOT varint; the pre-1.8 spawn-shaped packets are the
/// only varint-eid ones).
pub fn frameEntityEffect(eid: i32, effect_id: u8, amplifier: u8, duration_ticks: i32, out: []u8) codec.CodecError![]const u8 {
    var payload: [16]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(eid);
    try w.writeByte(effect_id);
    try w.writeByte(amplifier);
    try w.writeShort(@truncate(duration_ticks));
    return try codec.framePacket(@intFromEnum(ids.PlayClient.entity_effect), w.written(), out);
}


/// Clientbound 0x1E RemoveEntityEffect (jar `hr`: int eid, byte effect).
pub fn frameRemoveEntityEffect(eid: i32, effect_id: u8, out: []u8) codec.CodecError![]const u8 {
    var payload: [8]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(eid);
    try w.writeByte(effect_id);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.remove_entity_effect), w.written(), out);
}
