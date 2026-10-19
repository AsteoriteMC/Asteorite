//! Slice-based packet codec for Minecraft 1.7.10 / protocol v5.
//!
//! 1.7.10 framing (no compression):
//!   Length: VarInt = len(PacketID bytes + Data)
//!   PacketID: VarInt
//!   Data: bytes (big-endian fields)
//!
//! No heap allocation: caller provides buffers. Per-connection code should
//! wrap this with an ArenaAllocator reset on disconnect.

const std = @import("std");

pub const max_varint_len = 5;
pub const max_string_chars = 32767;
pub const max_string_bytes = max_string_chars * 4 + 3;

pub const CodecError = error{
    BufferUnderflow,
    VarIntTooLarge,
    StringTooLong,
    PacketTooLarge,
    InvalidLength,
};

/// Forward-only reader over a byte slice (zero-copy).
pub const PacketReader = struct {
    buffer: []const u8,
    index: usize = 0,

    pub fn init(buffer: []const u8) PacketReader {
        return .{ .buffer = buffer };
    }

    pub fn remaining(self: *const PacketReader) usize {
        return self.buffer.len - self.index;
    }

    pub fn readByte(self: *PacketReader) CodecError!u8 {
        if (self.index >= self.buffer.len) return error.BufferUnderflow;
        const b = self.buffer[self.index];
        self.index += 1;
        return b;
    }

    pub fn readBytes(self: *PacketReader, n: usize) CodecError![]const u8 {
        if (self.index + n > self.buffer.len) return error.BufferUnderflow;
        const s = self.buffer[self.index .. self.index + n];
        self.index += n;
        return s;
    }

    /// Minecraft VarInt: signed 32-bit, 7 bits/byte LE groups, max 5 bytes.
    /// Negative values always use 5 bytes.
    pub fn readVarInt(self: *PacketReader) CodecError!i32 {
        var num: i32 = 0;
        var shift: u32 = 0;
        var count: usize = 0;
        while (true) {
            if (self.index >= self.buffer.len) return error.BufferUnderflow;
            const b = self.buffer[self.index];
            self.index += 1;
            count += 1;
            if (count > 5) return error.VarIntTooLarge;
            const group: i32 = @as(i32, b & 0x7F);
            // Valid shifts are 0,7,14,21,28 — always < 32.
            num |= group << @as(u5, @intCast(shift));
            shift += 7;
            if ((b & 0x80) == 0) break;
        }
        return num;
    }

    pub fn readBool(self: *PacketReader) CodecError!bool {
        return (try self.readByte()) != 0;
    }

    pub fn readShort(self: *PacketReader) CodecError!i16 {
        const b = try self.readBytes(2);
        return std.mem.readInt(i16, b[0..2], .big);
    }

    pub fn readUShort(self: *PacketReader) CodecError!u16 {
        const b = try self.readBytes(2);
        return std.mem.readInt(u16, b[0..2], .big);
    }

    pub fn readInt(self: *PacketReader) CodecError!i32 {
        const b = try self.readBytes(4);
        return std.mem.readInt(i32, b[0..4], .big);
    }

    pub fn readLong(self: *PacketReader) CodecError!i64 {
        const b = try self.readBytes(8);
        return std.mem.readInt(i64, b[0..8], .big);
    }

    pub fn readFloat(self: *PacketReader) CodecError!f32 {
        const b = try self.readBytes(4);
        return @bitCast(std.mem.readInt(u32, b[0..4], .big));
    }

    pub fn readDouble(self: *PacketReader) CodecError!f64 {
        const b = try self.readBytes(8);
        return @bitCast(std.mem.readInt(u64, b[0..8], .big));
    }

    /// 1.7 string: VarInt byte-length + UTF-8, max 32767 chars.
    /// Returns slice aliasing the buffer (zero-copy). Caller validates UTF-8 if needed.
    pub fn readString(self: *PacketReader) CodecError![]const u8 {
        const len = try self.readVarInt();
        if (len < 0) return error.InvalidLength;
        const ulen: usize = @intCast(len);
        if (ulen > max_string_bytes) return error.StringTooLong;
        return try self.readBytes(ulen);
    }

    /// 1.7.10 Position is NOT used (that packing is post-1.8).
    /// 1.7 uses plain int x/y/z or fixed-point ints. Keep helpers explicit:
    pub fn readBlockCoords(self: *PacketReader) CodecError!struct { x: i32, y: u8, z: i32 } {
        const x = try self.readInt();
        const y = try self.readByte();
        const z = try self.readInt();
        return .{ .x = x, .y = y, .z = z };
    }
};

/// Append-only writer into a caller-provided fixed buffer.
pub const PacketWriter = struct {
    buffer: []u8,
    index: usize = 0,

    pub fn init(buffer: []u8) PacketWriter {
        return .{ .buffer = buffer };
    }

    pub fn written(self: *const PacketWriter) []const u8 {
        return self.buffer[0..self.index];
    }

    fn reserve(self: *PacketWriter, n: usize) CodecError![]u8 {
        if (self.index + n > self.buffer.len) return error.PacketTooLarge;
        const s = self.buffer[self.index .. self.index + n];
        self.index += n;
        return s;
    }

    pub fn writeByte(self: *PacketWriter, b: u8) CodecError!void {
        (try self.reserve(1))[0] = b;
    }

    pub fn writeBytes(self: *PacketWriter, data: []const u8) CodecError!void {
        const dst = try self.reserve(data.len);
        @memcpy(dst, data);
    }

    pub fn writeVarInt(self: *PacketWriter, value: i32) CodecError!void {
        var v: u32 = @bitCast(value);
        while (true) {
            var b: u8 = @truncate(v & 0x7F);
            v >>= 7;
            if (v != 0) b |= 0x80;
            try self.writeByte(b);
            if (v == 0) break;
        }
    }

    pub fn varIntLen(value: i32) usize {
        var v: u32 = @bitCast(value);
        var n: usize = 0;
        while (true) {
            n += 1;
            v >>= 7;
            if (v == 0) break;
        }
        return n;
    }

    pub fn writeShort(self: *PacketWriter, v: i16) CodecError!void {
        const dst = try self.reserve(2);
        std.mem.writeInt(i16, dst[0..2], v, .big);
    }

    pub fn writeUShort(self: *PacketWriter, v: u16) CodecError!void {
        const dst = try self.reserve(2);
        std.mem.writeInt(u16, dst[0..2], v, .big);
    }

    pub fn writeInt(self: *PacketWriter, v: i32) CodecError!void {
        const dst = try self.reserve(4);
        std.mem.writeInt(i32, dst[0..4], v, .big);
    }

    pub fn writeLong(self: *PacketWriter, v: i64) CodecError!void {
        const dst = try self.reserve(8);
        std.mem.writeInt(i64, dst[0..8], v, .big);
    }

    pub fn writeFloat(self: *PacketWriter, v: f32) CodecError!void {
        const dst = try self.reserve(4);
        std.mem.writeInt(u32, dst[0..4], @bitCast(v), .big);
    }

    pub fn writeDouble(self: *PacketWriter, v: f64) CodecError!void {
        const dst = try self.reserve(8);
        std.mem.writeInt(u64, dst[0..8], @bitCast(v), .big);
    }

    pub fn writeString(self: *PacketWriter, s: []const u8) CodecError!void {
        if (s.len > max_string_bytes) return error.StringTooLong;
        try self.writeVarInt(@intCast(s.len));
        try self.writeBytes(s);
    }
};

/// Encode a full 1.7.10 frame: Length VarInt + (ID VarInt + payload) into out.
/// Returns framed slice. Caller builds body (id+payload) first, then frames.
pub fn framePacket(id: i32, payload: []const u8, out: []u8) CodecError![]const u8 {
    const id_len = PacketWriter.varIntLen(id);
    const total: usize = id_len + payload.len;
    const total_len_len = PacketWriter.varIntLen(@intCast(total));
    if (total_len_len + total > out.len) return error.PacketTooLarge;
    var w = PacketWriter.init(out);
    try w.writeVarInt(@intCast(total));
    try w.writeVarInt(id);
    try w.writeBytes(payload);
    return w.written();
}

/// Decode frame header: returns (packet_id, body_slice consumed from reader).
/// Caller must have already split the TCP stream on Length prefix.
pub fn decodeFrame(reader: *PacketReader) CodecError!struct { length: i32, id: i32 } {
    const length = try reader.readVarInt();
    if (length < 0) return error.InvalidLength;
    const id = try reader.readVarInt();
    return .{ .length = length, .id = id };
}

// ---------------- tests ----------------

test "varint samples from wiki.vg" {
    const cases = [_]struct { bytes: []const u8, want: i32 }{
        .{ .bytes = &[_]u8{0x00}, .want = 0 },
        .{ .bytes = &[_]u8{0x01}, .want = 1 },
        .{ .bytes = &[_]u8{0x02}, .want = 2 },
        .{ .bytes = &[_]u8{0x7f}, .want = 127 },
        .{ .bytes = &[_]u8{ 0x80, 0x01 }, .want = 128 },
        .{ .bytes = &[_]u8{ 0xff, 0x01 }, .want = 255 },
        .{ .bytes = &[_]u8{ 0xff, 0xff, 0xff, 0xff, 0x07 }, .want = 2147483647 },
        .{ .bytes = &[_]u8{ 0xff, 0xff, 0xff, 0xff, 0x0f }, .want = -1 },
        .{ .bytes = &[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x08 }, .want = -2147483648 },
    };
    for (cases) |c| {
        var r = PacketReader.init(c.bytes);
        try std.testing.expectEqual(c.want, try r.readVarInt());
    }
}

test "varint too large" {
    var r = PacketReader.init(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 });
    try std.testing.expectError(error.VarIntTooLarge, r.readVarInt());
}

test "varint underflow" {
    var r = PacketReader.init(&[_]u8{0x80});
    try std.testing.expectError(error.BufferUnderflow, r.readVarInt());
}

test "roundtrip writer/reader" {
    var buf: [64]u8 = undefined;
    var w = PacketWriter.init(&buf);
    try w.writeVarInt(-1);
    try w.writeVarInt(128);
    try w.writeString("hello");
    try w.writeInt(-123456);
    var r = PacketReader.init(w.written());
    try std.testing.expectEqual(@as(i32, -1), try r.readVarInt());
    try std.testing.expectEqual(@as(i32, 128), try r.readVarInt());
    const s = try r.readString();
    try std.testing.expectEqualStrings("hello", s);
    try std.testing.expectEqual(@as(i32, -123456), try r.readInt());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "frame encode/decode" {
    var out: [32]u8 = undefined;
    const framed = try framePacket(0x01, &[_]u8{0xAB}, &out);
    var r = PacketReader.init(framed);
    const h = try decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 2), h.length); // 1 byte id + 1 byte payload
    try std.testing.expectEqual(@as(i32, 0x01), h.id);
    try std.testing.expectEqual(@as(u8, 0xAB), try r.readByte());
}
