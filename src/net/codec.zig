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
            if (count > max_varint_len) return error.VarIntTooLarge;
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

    /// Read a big-endian integer or float (the six fixed-width readers below
    /// are one-liners over this; floats reinterpret the same bytes).
    fn readBE(self: *PacketReader, comptime T: type) CodecError!T {
        const size = @sizeOf(T);
        const b = try self.readBytes(size);
        return switch (@typeInfo(T)) {
            .int => std.mem.readInt(T, b[0..size], .big),
            .float => @bitCast(std.mem.readInt(std.meta.Int(.unsigned, size * 8), b[0..size], .big)),
            else => @compileError("codec.readBE supports int/float types only"),
        };
    }

    pub fn readShort(self: *PacketReader) CodecError!i16 {
        return self.readBE(i16);
    }

    pub fn readUShort(self: *PacketReader) CodecError!u16 {
        return self.readBE(u16);
    }

    pub fn readInt(self: *PacketReader) CodecError!i32 {
        return self.readBE(i32);
    }

    pub fn readLong(self: *PacketReader) CodecError!i64 {
        return self.readBE(i64);
    }

    pub fn readFloat(self: *PacketReader) CodecError!f32 {
        return self.readBE(f32);
    }

    pub fn readDouble(self: *PacketReader) CodecError!f64 {
        return self.readBE(f64);
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

    /// 1.7.10 block coords (int x, byte y, int z).
    pub const BlockCoords = struct { x: i32, y: u8, z: i32 };

    /// 1.7.10 Position is NOT used (that packing is post-1.8).
    /// 1.7 uses plain int x/y/z or fixed-point ints. Keep helpers explicit:
    pub fn readBlockCoords(self: *PacketReader) CodecError!BlockCoords {
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

    /// Write a big-endian integer or float (mirrors readBE).
    fn writeBE(self: *PacketWriter, comptime T: type, v: T) CodecError!void {
        const size = @sizeOf(T);
        const dst = try self.reserve(size);
        switch (@typeInfo(T)) {
            .int => std.mem.writeInt(T, dst[0..size], v, .big),
            .float => std.mem.writeInt(std.meta.Int(.unsigned, size * 8), dst[0..size], @bitCast(v), .big),
            else => @compileError("codec.writeBE supports int/float types only"),
        }
    }

    pub fn writeShort(self: *PacketWriter, v: i16) CodecError!void {
        return self.writeBE(i16, v);
    }

    pub fn writeUShort(self: *PacketWriter, v: u16) CodecError!void {
        return self.writeBE(u16, v);
    }

    pub fn writeInt(self: *PacketWriter, v: i32) CodecError!void {
        return self.writeBE(i32, v);
    }

    pub fn writeLong(self: *PacketWriter, v: i64) CodecError!void {
        return self.writeBE(i64, v);
    }

    pub fn writeFloat(self: *PacketWriter, v: f32) CodecError!void {
        return self.writeBE(f32, v);
    }

    pub fn writeDouble(self: *PacketWriter, v: f64) CodecError!void {
        return self.writeBE(f64, v);
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

/// Decoded frame header (packet id + declared body length).
pub const FrameHeader = struct { length: i32, id: i32 };

/// Decode frame header: returns (packet_id, body_slice consumed from reader).
/// Caller must have already split the TCP stream on Length prefix.
pub fn decodeFrame(reader: *PacketReader) CodecError!FrameHeader {
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
