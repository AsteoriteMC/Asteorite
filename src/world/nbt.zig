//! Minimal NBT reader (big-endian) for 1.7.10 chunk data.
//!
//! NBT strings use u16 BE length prefix (NOT VarInt).
//! Reader is slice-based, zero-copy for byte arrays / strings.

const std = @import("std");

pub const TagType = enum(u8) {
    end = 0,
    byte = 1,
    short = 2,
    int = 3,
    long = 4,
    float = 5,
    double = 6,
    byte_array = 7,
    string = 8,
    list = 9,
    compound = 10,
    int_array = 11,
    _,

    pub fn fromByte(b: u8) TagType {
        return @enumFromInt(b);
    }
};

pub const NbtError = error{
    BufferUnderflow,
    InvalidTag,
    DepthExceeded,
    BadString,
};

/// Recursion cap for skipPayload (malicious nesting guard).
pub const max_depth: usize = 64;

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,
    depth: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn remaining(self: *const Reader) usize {
        return self.buf.len - self.pos;
    }

    fn take(self: *Reader, n: usize) NbtError![]const u8 {
        if (self.pos + n > self.buf.len) return error.BufferUnderflow;
        const s = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    pub fn readByte(self: *Reader) NbtError!u8 {
        return (try self.take(1))[0];
    }

    pub fn readTagType(self: *Reader) NbtError!TagType {
        return TagType.fromByte(try self.readByte());
    }

    pub fn readBE(self: *Reader, comptime T: type) NbtError!T {
        const size = @sizeOf(T);
        const b = try self.take(size);
        return std.mem.readInt(T, b[0..size], .big);
    }

    pub fn readFloat(self: *Reader) NbtError!f32 {
        const u = try self.readBE(u32);
        return @bitCast(u);
    }

    pub fn readDouble(self: *Reader) NbtError!f64 {
        const u = try self.readBE(u64);
        return @bitCast(u);
    }

    /// NBT string: u16 BE length + UTF-8 bytes (zero-copy slice).
    pub fn readString(self: *Reader) NbtError![]const u8 {
        const len = try self.readBE(u16);
        return try self.take(len);
    }

    pub fn readByteArray(self: *Reader) NbtError![]const u8 {
        const len = try self.readBE(i32);
        if (len < 0) return error.InvalidTag;
        return try self.take(@intCast(len));
    }

    /// Read an int-array length prefix (validates sign). The caller then
    /// reads that many BE i32s via readBE — or skips len*4 bytes.
    fn readArrayLen(self: *Reader) NbtError!usize {
        const len = try self.readBE(i32);
        if (len < 0) return error.InvalidTag;
        return @intCast(len);
    }

    /// Consume an int-array payload, returning its element count. Values
    /// are big-endian i32s; readers that need them loop readBE — the
    /// slice reader owns no allocation, so there is no zero-copy view.
    pub fn readIntArrayLen(self: *Reader) NbtError!usize {
        const n = try self.readArrayLen();
        _ = try self.take(n * 4);
        return n;
    }

    /// Skip a full payload of the given tag type (no name).
    pub fn skipPayload(self: *Reader, tag: TagType) NbtError!void {
        if (self.depth > max_depth) return error.DepthExceeded;
        switch (tag) {
            .end => {},
            .byte => _ = try self.take(1),
            .short => _ = try self.take(2),
            .int => _ = try self.take(4),
            .long => _ = try self.take(8),
            .float => _ = try self.take(4),
            .double => _ = try self.take(8),
            .byte_array => {
                const len = try self.readArrayLen();
                _ = try self.take(len);
            },
            .string => {
                const s = try self.readString();
                _ = s;
            },
            .list => {
                const elem = try self.readTagType();
                const len = try self.readArrayLen();
                if (elem == .end and len > 0) return error.InvalidTag;
                self.depth += 1;
                defer self.depth -= 1;
                var i: usize = 0;
                while (i < len) : (i += 1) try self.skipPayload(elem);
            },
            .compound => {
                self.depth += 1;
                defer self.depth -= 1;
                while (true) {
                    const t = try self.readTagType();
                    if (t == .end) break;
                    _ = try self.readString(); // name
                    try self.skipPayload(t);
                }
            },
            .int_array => {
                const len = try self.readArrayLen();
                _ = try self.take(len * 4);
            },
            _ => return error.InvalidTag,
        }
    }

    /// Read root compound: tag byte (must be 10), name, then positioned at entries.
    /// Returns root name.
    pub fn readRoot(self: *Reader) NbtError![]const u8 {
        const t = try self.readTagType();
        if (t != .compound) return error.InvalidTag;
        return try self.readString();
    }

    /// Verbatim bytes of the compound payload starting at the current
    /// position (caller has just read the tag type + name). Used to
    /// preserve opaque item NBT (`tag`) byte-for-byte.
    pub fn readRawCompound(self: *Reader) NbtError![]const u8 {
        const start = self.pos;
        try self.skipPayload(.compound);
        return self.buf[start..self.pos];
    }
};

/// Gunzip a whole buffer (vanilla player.dat is gzip-NBT; region chunks
/// are zlib-NBT and keep their own path in anvil.zig).
pub fn gunzipAlloc(alloc: std.mem.Allocator, gz: []const u8) error{ OutOfMemory, DecompressFailed }![]u8 {
    var in: std.Io.Reader = .fixed(gz);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    var decomp = std.compress.flate.Decompress.init(&in, .gzip, &.{});
    _ = decomp.reader.streamRemaining(&aw.writer) catch return error.DecompressFailed;
    return aw.toOwnedSlice() catch return error.OutOfMemory;
}

test "nbt string + primitives" {
    // TAG_Compound("") { TAG_Short("x") = 0x0102, TAG_String("s") = "hi", TAG_End }
    var data = [_]u8{
        0x0A, 0x00, 0x00, // root compound, empty name
        0x02, 0x00, 0x01, 'x', 0x01, 0x02, // short x
        0x08, 0x00, 0x01, 's', 0x00, 0x02, 'h', 'i', // string s
        0x00, // end
    };
    var r = Reader.init(&data);
    const name = try r.readRoot();
    try std.testing.expectEqual(@as(usize, 0), name.len);
    // walk entries manually
    const t1 = try r.readTagType();
    try std.testing.expectEqual(TagType.short, t1);
    const n1 = try r.readString();
    try std.testing.expectEqualStrings("x", n1);
    try std.testing.expectEqual(@as(i16, 0x0102), try r.readBE(i16));
    const t2 = try r.readTagType();
    try std.testing.expectEqual(TagType.string, t2);
    const n2 = try r.readString();
    try std.testing.expectEqualStrings("s", n2);
    const s = try r.readString();
    try std.testing.expectEqualStrings("hi", s);
    try std.testing.expectEqual(TagType.end, try r.readTagType());
}

test "skip compound with list" {
    var data = [_]u8{
        0x0A, 0x00, 0x00,
        0x09, 0x00, 0x01, 'L', 0x01, 0x00, 0x00, 0x00, 0x02, 0x2A, 0x2B,
        0x00,
    };
    var r = Reader.init(&data);
    _ = try r.readRoot();
    const t = try r.readTagType();
    try std.testing.expectEqual(TagType.list, t);
    _ = try r.readString();
    // rewind one entry: easier to test skipPayload on whole compound
    var r2 = Reader.init(&data);
    _ = try r2.readRoot();
    _ = try r2.readTagType();
    const _n = try r2.readString();
    _ = _n;
    // put back? just skip payload directly from fresh reader at list payload
    var r3 = Reader.init(data[3..]);
    // r3 starts at list tag itself; read tag+name then skip
    const lt = try r3.readTagType();
    _ = try r3.readString();
    try r3.skipPayload(lt);
    try std.testing.expectEqual(TagType.end, try r3.readTagType());
}
