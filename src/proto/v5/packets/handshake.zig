//! 1.7.10 play handshake / status / login packets (connection setup).

const std = @import("std");
const codec = @import("../../../net/codec.zig");
const ids = @import("../ids.zig");


// ---------- handshaking ----------

pub const Handshake = struct {
    protocol: i32,
    address: []const u8,
    port: u16,
    next: i32,
};


pub fn parseHandshake(body: []const u8) codec.CodecError!Handshake {
    var r = codec.PacketReader.init(body);
    const protocol = try r.readVarInt();
    const address = try r.readString();
    const port = try r.readUShort();
    const next = try r.readVarInt();
    return .{ .protocol = protocol, .address = address, .port = port, .next = next };
}


// ---------- status ----------

pub fn frameStatusResponse(json: []const u8, out: []u8) codec.CodecError![]const u8 {
    var payload: [codec.max_string_bytes + 4]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeString(json);
    return try codec.framePacket(@intFromEnum(ids.StatusClient.response), w.written(), out);
}


pub fn parsePing(body: []const u8) codec.CodecError!i64 {
    var r = codec.PacketReader.init(body);
    return try r.readLong();
}


pub fn framePong(payload: i64, out: []u8) codec.CodecError![]const u8 {
    var pb: [8]u8 = undefined;
    std.mem.writeInt(i64, &pb, payload, .big);
    return try codec.framePacket(@intFromEnum(ids.StatusClient.pong), &pb, out);
}


// ---------- login ----------

/// Returns player name slice (borrows body).
pub fn parseLoginStart(body: []const u8) codec.CodecError![]const u8 {
    var r = codec.PacketReader.init(body);
    return try r.readString();
}


pub const EncryptionRequest = struct {
    server_id: []const u8,
    pubkey: []const u8,
    token: []const u8,
};


pub fn frameEncryptionRequest(server_id: []const u8, pubkey: []const u8, token: []const u8, out: []u8) codec.CodecError![]const u8 {
    var body: [4096]u8 = undefined;
    var w = codec.PacketWriter.init(&body);
    try w.writeString(server_id);
    try w.writeShort(@intCast(pubkey.len));
    try w.writeBytes(pubkey);
    try w.writeShort(@intCast(token.len));
    try w.writeBytes(token);
    return try codec.framePacket(@intFromEnum(ids.LoginClient.encryption_request), w.written(), out);
}


pub const EncryptionResponse = struct {
    secret: []const u8, // RSA-decrypted shared secret (caller decrypts)
    token: []const u8, // RSA-decrypted verify token
};


/// Parses the length-prefixed encrypted blobs (still encrypted; RSA step is separate).
pub fn parseEncryptionResponse(body: []const u8) codec.CodecError!struct { secret_enc: []const u8, token_enc: []const u8 } {
    var r = codec.PacketReader.init(body);
    const slen = try r.readShort();
    if (slen < 0) return error.InvalidLength;
    const secret_enc = try r.readBytes(@intCast(slen));
    const tlen = try r.readShort();
    if (tlen < 0) return error.InvalidLength;
    const token_enc = try r.readBytes(@intCast(tlen));
    return .{ .secret_enc = secret_enc, .token_enc = token_enc };
}


pub fn frameLoginSuccess(uuid_str: []const u8, name: []const u8, out: []u8) codec.CodecError![]const u8 {
    var body: [128]u8 = undefined;
    var w = codec.PacketWriter.init(&body);
    try w.writeString(uuid_str);
    try w.writeString(name);
    return try codec.framePacket(@intFromEnum(ids.LoginClient.login_success), w.written(), out);
}


pub fn frameLoginDisconnect(json: []const u8, out: []u8) codec.CodecError![]const u8 {
    var payload: [codec.max_string_bytes + 4]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeString(json);
    return try codec.framePacket(@intFromEnum(ids.LoginClient.disconnect), w.written(), out);
}


test "handshake parse" {
    var body: [64]u8 = undefined;
    var w = codec.PacketWriter.init(&body);
    try w.writeVarInt(5);
    try w.writeString("localhost");
    try w.writeUShort(25565);
    try w.writeVarInt(1);
    const h = try parseHandshake(w.written());
    try std.testing.expectEqual(@as(i32, 5), h.protocol);
    try std.testing.expectEqualStrings("localhost", h.address);
    try std.testing.expectEqual(@as(u16, 25565), h.port);
    try std.testing.expectEqual(@as(i32, 1), h.next);
}


test "status response frame + ping/pong" {
    var out: [512]u8 = undefined;
    const json = "{\"version\":{\"name\":\"1.7.10\",\"protocol\":5}}";
    const f = try frameStatusResponse(json, &out);
    var r = codec.PacketReader.init(f);
    const h = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 0x00), h.id);
    try std.testing.expectEqualStrings(json, try r.readString());
    // pong echoes ping payload
    var po: [16]u8 = undefined;
    const pf = try framePong(123456789, &po);
    var r2 = codec.PacketReader.init(pf);
    _ = try codec.decodeFrame(&r2);
    try std.testing.expectEqual(@as(i64, 123456789), try parsePing(r2.buffer[r2.index..]));
}


test "login start + login success frames" {
    var b: [64]u8 = undefined;
    var w = codec.PacketWriter.init(&b);
    try w.writeString("testplayer");
    try std.testing.expectEqualStrings("testplayer", try parseLoginStart(w.written()));
    var out: [128]u8 = undefined;
    const f = try frameLoginSuccess("52d22a52-7b4a-339e-8a09-aa52384d72fd", "testplayer", &out);
    var r = codec.PacketReader.init(f);
    const h = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 0x02), h.id);
    try std.testing.expectEqualStrings("52d22a52-7b4a-339e-8a09-aa52384d72fd", try r.readString());
    try std.testing.expectEqualStrings("testplayer", try r.readString());
}


test "encryption request/response framing" {
    var out: [512]u8 = undefined;
    const f = try frameEncryptionRequest("", &[_]u8{ 1, 2, 3 }, &[_]u8{4}, &out);
    var r = codec.PacketReader.init(f);
    const h = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 0x01), h.id);
    // request body: serverId string + short len + key + short len + token
    try std.testing.expectEqualStrings("", try r.readString());
    try std.testing.expectEqual(@as(i16, 3), try r.readShort());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, try r.readBytes(3));
    // response parse
    var rb: [16]u8 = undefined;
    var w = codec.PacketWriter.init(&rb);
    try w.writeShort(2);
    try w.writeBytes(&[_]u8{ 0xAA, 0xBB });
    try w.writeShort(1);
    try w.writeBytes(&[_]u8{0xCC});
    const er = try parseEncryptionResponse(w.written());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB }, er.secret_enc);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xCC}, er.token_enc);
}
