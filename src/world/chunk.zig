//! Versioned chunk payload (ZC1) — the ONLY runtime chunk encoding.
//! Stored as the LSM value under key [dim|x|z] (see store.zig).
//!
//! Layout (big-endian):
//!   magic "ZC1" (3B) + version u8 (=2; v1 stored wire ids, v2+ stores
//!   canonical ids.Id values)
//!   dim u8, x i32, z i32                      (9B, mirrors key)
//!   section_mask u16                           (bit i => section i present)
//!   per present section, ascending:
//!     blocks 4096 x u16 BE (full id 0..4095, YZX order)
//!     meta   2048B nibbles, add 2048B nibbles, sky 2048B, light 2048B
//!   biomes 256B, heights 256B (u8, clamped)
//!
//! YZX order: idx = (y*16 + z)*16 + x, xyz local 0..15. Matches Anvil.

const std = @import("std");
const nbt = @import("nbt.zig");
const ids = @import("../ids.zig");
const wire = @import("../proto/v5/wire_ids.zig");

pub const version: u8 = 2;
pub const magic = "ZC1";
pub const section_size = 4096;
pub const nibble_size = 2048;
pub const section_bytes = section_size * 2 + nibble_size * 4; // 16384

pub const ChunkError = error{
    BadMagic,
    UnsupportedVersion,
    Truncated,
    BlockIdRange,
    InvalidMask,
    OutOfMemory,
} || nbt.NbtError || std.mem.Allocator.Error;

pub const Section = struct {
    blocks: [section_size]ids.Id = [_]ids.Id{ids.air} ** section_size,
    meta: [nibble_size]u8 = [_]u8{0} ** nibble_size,
    add: [nibble_size]u8 = [_]u8{0} ** nibble_size,
    sky: [nibble_size]u8 = [_]u8{0xFF} ** nibble_size,
    light: [nibble_size]u8 = [_]u8{0} ** nibble_size,

    pub inline fn index(x: u4, y: u4, z: u4) usize {
        return (@as(usize, y) * 16 + @as(usize, z)) * 16 + @as(usize, x);
    }

    pub fn getBlock(self: *const Section, x: u4, y: u4, z: u4) ids.Id {
        return self.blocks[index(x, y, z)];
    }

    pub fn setBlock(self: *Section, x: u4, y: u4, z: u4, id: ids.Id) void {
        const i = index(x, y, z);
        self.blocks[i] = id;
    }

    pub fn getNibble(arr: *const [nibble_size]u8, i: usize) u4 {
        const b = arr[i >> 1];
        return if (i & 1 == 0) @truncate(b & 0x0F) else @truncate(b >> 4);
    }

    pub fn setNibble(arr: *[nibble_size]u8, i: usize, v: u4) void {
        const b = &arr[i >> 1];
        if (i & 1 == 0) {
            b.* = (b.* & 0xF0) | v;
        } else {
            b.* = (b.* & 0x0F) | (@as(u8, v) << 4);
        }
    }
};

/// Heap-allocated chunk (full 16-section inline storage is ~264KB — never on stack).
pub const Chunk = struct {
    dim: u8,
    x: i32,
    z: i32,
    sections: [16]?Section = [_]?Section{null} ** 16,
    biomes: [256]u8 = [_]u8{0} ** 256,
    heights: [256]u8 = [_]u8{0} ** 256,

    pub fn createEmpty(allocator: std.mem.Allocator, dim: u8, x: i32, z: i32) !*Chunk {
        const c = try allocator.create(Chunk);
        c.* = .{ .dim = dim, .x = x, .z = z };
        return c;
    }

    pub fn destroy(self: *Chunk, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    pub fn mask(self: *const Chunk) u16 {
        var m: u16 = 0;
        for (self.sections, 0..) |s, i| {
            if (s != null) m |= @as(u16, 1) << @intCast(i);
        }
        return m;
    }

    pub fn encodedLen(self: *const Chunk) usize {
        return 3 + 1 + 9 + 2 + @as(usize, @popCount(self.mask())) * section_bytes + 512;
    }

    pub fn encode(self: *const Chunk, allocator: std.mem.Allocator) ![]u8 {
        const out = try allocator.alloc(u8, self.encodedLen());
        var p: usize = 0;
        @memcpy(out[p..][0..3], magic);
        p += 3;
        out[p] = version;
        p += 1;
        out[p] = self.dim;
        p += 1;
        std.mem.writeInt(i32, out[p..][0..4], self.x, .big);
        p += 4;
        std.mem.writeInt(i32, out[p..][0..4], self.z, .big);
        p += 4;
        std.mem.writeInt(u16, out[p..][0..2], self.mask(), .big);
        p += 2;
        for (self.sections) |maybe| {
            const s = maybe orelse continue;
            for (s.blocks) |b| {
                std.mem.writeInt(u16, out[p..][0..2], @intFromEnum(b), .big);
                p += 2;
            }
            @memcpy(out[p..][0..nibble_size], &s.meta);
            p += nibble_size;
            @memcpy(out[p..][0..nibble_size], &s.add);
            p += nibble_size;
            @memcpy(out[p..][0..nibble_size], &s.sky);
            p += nibble_size;
            @memcpy(out[p..][0..nibble_size], &s.light);
            p += nibble_size;
        }
        @memcpy(out[p..][0..256], &self.biomes);
        p += 256;
        @memcpy(out[p..][0..256], &self.heights);
        p += 256;
        std.debug.assert(p == out.len);
        return out;
    }

    pub fn decode(allocator: std.mem.Allocator, data: []const u8) ChunkError!*Chunk {
        if (data.len < 3 + 1 + 9 + 2 + 512) return error.Truncated;
        if (!std.mem.eql(u8, data[0..3], magic)) return error.BadMagic;
        if (data[3] != version) return error.UnsupportedVersion;
        var p: usize = 4;
        const dim = data[p];
        p += 1;
        const x = std.mem.readInt(i32, data[p..][0..4], .big);
        p += 4;
        const z = std.mem.readInt(i32, data[p..][0..4], .big);
        p += 4;
        const section_mask = std.mem.readInt(u16, data[p..][0..2], .big);
        p += 2;
        const want: usize = 3 + 1 + 9 + 2 + @as(usize, @popCount(section_mask)) * section_bytes + 512;
        if (data.len != want) return error.Truncated;
        const c = try allocator.create(Chunk);
        c.* = .{ .dim = dim, .x = x, .z = z };
        for (0..16) |i| {
            if (section_mask & (@as(u16, 1) << @intCast(i)) == 0) continue;
            var s = Section{};
            for (&s.blocks) |*b| {
                const raw = std.mem.readInt(u16, data[p..][0..2], .big);
                if (raw >= ids.COUNT) {
                    allocator.destroy(c);
                    return error.BlockIdRange;
                }
                b.* = @enumFromInt(raw);
                p += 2;
            }
            @memcpy(&s.meta, data[p..][0..nibble_size]);
            p += nibble_size;
            @memcpy(&s.add, data[p..][0..nibble_size]);
            p += nibble_size;
            @memcpy(&s.sky, data[p..][0..nibble_size]);
            p += nibble_size;
            @memcpy(&s.light, data[p..][0..nibble_size]);
            p += nibble_size;
            c.sections[i] = s;
        }
        @memcpy(&c.biomes, data[p..][0..256]);
        p += 256;
        @memcpy(&c.heights, data[p..][0..256]);
        p += 256;
        std.debug.assert(p == data.len);
        return c;
    }
};

/// Build a ZC1 chunk from decompressed Anvil chunk NBT (1.7.10 Level format).
/// Reads Level.{xPos,zPos,Sections[{Y,Blocks[4096],Data[2048],Add?,SkyLight,BlockLight}],Biomes[256],HeightMap[256]}.
pub fn fromAnvilNbt(allocator: std.mem.Allocator, nbt_bytes: []const u8, dim: u8) ChunkError!*Chunk {
    var r = nbt.Reader.init(nbt_bytes);
    _ = try r.readRoot();
    // find Level compound at root
    var found_level = false;
    const c = try allocator.create(Chunk);
    c.* = .{ .dim = dim, .x = 0, .z = 0 };
    errdefer allocator.destroy(c);

    while (true) {
        const t = try r.readTagType();
        if (t == .end) break;
        const name = try r.readString();
        if (t == .compound and std.mem.eql(u8, name, "Level")) {
            found_level = true;
            try parseLevel(&r, c);
        } else {
            try r.skipPayload(t);
        }
    }
    if (!found_level) {
        allocator.destroy(c);
        return error.Truncated;
    }
    return c;
}

fn parseLevel(r: *nbt.Reader, c: *Chunk) ChunkError!void {
    while (true) {
        const t = try r.readTagType();
        if (t == .end) break;
        const name = try r.readString();
        if (t == .int and std.mem.eql(u8, name, "xPos")) {
            c.x = try r.readBE(i32);
        } else if (t == .int and std.mem.eql(u8, name, "zPos")) {
            c.z = try r.readBE(i32);
        } else if (t == .list and std.mem.eql(u8, name, "Sections")) {
            try parseSections(r, c);
        } else if (t == .byte_array and std.mem.eql(u8, name, "Biomes")) {
            const b = try r.readByteArray();
            if (b.len != 256) return error.Truncated;
            @memcpy(&c.biomes, b[0..256]);
        } else if (t == .int_array and std.mem.eql(u8, name, "HeightMap")) {
            const len = try r.readBE(i32);
            if (len != 256) return error.Truncated;
            for (&c.heights) |*h| {
                const v = try r.readBE(i32);
                h.* = @truncate(@as(u32, @intCast(@min(@max(v, 0), 255))));
            }
        } else {
            try r.skipPayload(t);
        }
    }
}

fn parseSections(r: *nbt.Reader, c: *Chunk) ChunkError!void {
    const elem = try r.readTagType();
    if (elem != .compound) return error.Truncated;
    const count = try r.readBE(i32);
    if (count < 0 or count > 16) return error.Truncated;
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        // section compound entries
        var y: ?u8 = null;
        var blocks: ?[]const u8 = null;
        var data: ?[]const u8 = null;
        var add: ?[]const u8 = null;
        var sky: ?[]const u8 = null;
        var light: ?[]const u8 = null;
        while (true) {
            const t = try r.readTagType();
            if (t == .end) break;
            const name = try r.readString();
            if (t == .byte and std.mem.eql(u8, name, "Y")) {
                y = try r.readByte();
            } else if (t == .byte_array and std.mem.eql(u8, name, "Blocks")) {
                blocks = try r.readByteArray();
            } else if (t == .byte_array and std.mem.eql(u8, name, "Data")) {
                data = try r.readByteArray();
            } else if (t == .byte_array and std.mem.eql(u8, name, "Add")) {
                add = try r.readByteArray();
            } else if (t == .byte_array and std.mem.eql(u8, name, "SkyLight")) {
                sky = try r.readByteArray();
            } else if (t == .byte_array and std.mem.eql(u8, name, "BlockLight")) {
                light = try r.readByteArray();
            } else {
                try r.skipPayload(t);
            }
        }
        const yi = y orelse return error.Truncated;
        if (yi > 15) return error.Truncated;
        const b = blocks orelse return error.Truncated;
        const d = data orelse return error.Truncated;
        if (b.len != 4096 or d.len != 2048) return error.Truncated;
        if (add) |a| {
            if (a.len != 2048) return error.Truncated;
        }
        if (sky) |s| {
            if (s.len != 2048) return error.Truncated;
        }
        if (light) |l| {
            if (l.len != 2048) return error.Truncated;
        }
        var s = Section{};
        // Anvil order is YZX already: idx=(y*16+z)*16+x matches ours.
        for (0..4096) |idx| {
            const base: u16 = b[idx];
            const an: u16 = if (add) |a| nibbleAt(a, idx) else 0;
            const w: u16 = (an << 8) | base;
            s.blocks[idx] = wire.fromWire(w) orelse return error.BlockIdRange;
            s.meta[idx >> 1] = d[idx >> 1]; // copy whole byte once (loop hits twice, idempotent)
        }
        if (add) |a| @memcpy(&s.add, a[0..2048]);
        @memcpy(&s.meta, d[0..2048]);
        if (sky) |sk| @memcpy(&s.sky, sk[0..2048]);
        if (light) |li| @memcpy(&s.light, li[0..2048]);
        c.sections[yi] = s;
    }
}

inline fn nibbleAt(arr: []const u8, idx: usize) u8 {
    const v = arr[idx >> 1];
    return if (idx & 1 == 0) v & 0x0F else v >> 4;
}

test "section index order + nibbles" {
    // corners map to distinct slots; nibble pack/unpack roundtrips
    try std.testing.expectEqual(@as(usize, 0), Section.index(0, 0, 0));
    try std.testing.expectEqual(@as(usize, 4095), Section.index(15, 15, 15));
    var s = Section{};
    s.setBlock(1, 2, 3, ids.diamond_block);
    try std.testing.expectEqual(ids.diamond_block, s.getBlock(1, 2, 3));
    var n: [2048]u8 = [_]u8{0} ** 2048;
    Section.setNibble(&n, 0, 0xA);
    Section.setNibble(&n, 1, 0xB);
    try std.testing.expectEqual(@as(u4, 0xA), Section.getNibble(&n, 0));
    try std.testing.expectEqual(@as(u4, 0xB), Section.getNibble(&n, 1));
}

test "zc1 sparse roundtrip" {
    const a = std.testing.allocator;
    var ch = try Chunk.createEmpty(a, 0, 3, -7);
    defer ch.destroy(a);
    ch.biomes[0] = 21;
    ch.heights[0] = 64;
    var s0 = Section{};
    s0.setBlock(0, 0, 0, ids.stone);
    s0.setBlock(15, 15, 15, ids.diamond_block);
    Section.setNibble(&s0.meta, 0, 0x5);
    ch.sections[0] = s0;
    var s5 = Section{};
    s5.setBlock(8, 8, 8, ids.record_wait);
    ch.sections[5] = s5;
    const enc = try ch.encode(a);
    defer a.free(enc);
    // 4+9+2 header + 2 sections + 512 tail
    try std.testing.expectEqual(@as(usize, 4 + 9 + 2 + 2 * section_bytes + 512), enc.len);
    const dec = try Chunk.decode(a, enc);
    defer dec.destroy(a);
    try std.testing.expectEqual(ch.dim, dec.dim);
    try std.testing.expectEqual(ch.x, dec.x);
    try std.testing.expectEqual(ch.z, dec.z);
    try std.testing.expectEqual(ch.mask(), dec.mask());
    try std.testing.expectEqual(ids.stone, dec.sections[0].?.getBlock(0, 0, 0));
    try std.testing.expectEqual(ids.diamond_block, dec.sections[0].?.getBlock(15, 15, 15));
    try std.testing.expectEqual(@as(u4, 0x5), Section.getNibble(&dec.sections[0].?.meta, 0));
    try std.testing.expectEqual(ids.record_wait, dec.sections[5].?.getBlock(8, 8, 8));
    try std.testing.expect(dec.sections[1] == null);
    try std.testing.expectEqual(@as(u8, 21), dec.biomes[0]);
    try std.testing.expectEqual(@as(u8, 64), dec.heights[0]);
}

test "zc1 rejects bad magic/trailing bytes" {
    const a = std.testing.allocator;
    var ch = try Chunk.createEmpty(a, 0, 0, 0);
    defer ch.destroy(a);
    const enc = try ch.encode(a);
    defer a.free(enc);
    var bad = try a.dupe(u8, enc);
    defer a.free(bad);
    bad[0] = 'X';
    try std.testing.expectError(error.BadMagic, Chunk.decode(a, bad));
    try std.testing.expectError(error.Truncated, Chunk.decode(a, enc[0 .. enc.len - 1]));
}

test "fromAnvilNbt minimal one-section chunk" {
    const a = std.testing.allocator;
    // Build NBT: root{ Level{ xPos=7(int), zPos=-3(int),
    //   Sections=[ {Y=0B, Blocks[4096](id 1 at 0, 57 at 4095), Data[2048](0), SkyLight[2048](FF), BlockLight[2048](0)} ],
    //   Biomes[256](7), HeightMap[256](64) } }
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeByte(10); // root compound
    try w.writeInt(u16, 0, .big); // empty name
    // Level compound
    try w.writeByte(10);
    try w.writeInt(u16, 5, .big);
    try w.writeAll("Level");
    try w.writeByte(3);
    try w.writeInt(u16, 4, .big);
    try w.writeAll("xPos");
    try w.writeInt(i32, 7, .big);
    try w.writeByte(3);
    try w.writeInt(u16, 4, .big);
    try w.writeAll("zPos");
    try w.writeInt(i32, -3, .big);
    // Sections list
    try w.writeByte(9);
    try w.writeInt(u16, 8, .big);
    try w.writeAll("Sections");
    try w.writeByte(10); // elem compound
    try w.writeInt(i32, 1, .big); // len
    try w.writeByte(1);
    try w.writeInt(u16, 1, .big);
    try w.writeAll("Y");
    try w.writeByte(0);
    // Blocks
    var blocks: [4096]u8 = [_]u8{0} ** 4096;
    blocks[0] = 1;
    blocks[4095] = 57;
    try w.writeByte(7);
    try w.writeInt(u16, 6, .big);
    try w.writeAll("Blocks");
    try w.writeInt(i32, 4096, .big);
    try w.writeAll(&blocks);
    const zeros2048 = [_]u8{0} ** 2048;
    const ff2048 = [_]u8{0xFF} ** 2048;
    try w.writeByte(7);
    try w.writeInt(u16, 4, .big);
    try w.writeAll("Data");
    try w.writeInt(i32, 2048, .big);
    try w.writeAll(&zeros2048);
    try w.writeByte(7);
    try w.writeInt(u16, 8, .big);
    try w.writeAll("SkyLight");
    try w.writeInt(i32, 2048, .big);
    try w.writeAll(&ff2048);
    try w.writeByte(7);
    try w.writeInt(u16, 10, .big);
    try w.writeAll("BlockLight");
    try w.writeInt(i32, 2048, .big);
    try w.writeAll(&zeros2048);
    try w.writeByte(0); // end section
    // Biomes
    const bio = [_]u8{7} ** 256;
    try w.writeByte(7);
    try w.writeInt(u16, 6, .big);
    try w.writeAll("Biomes");
    try w.writeInt(i32, 256, .big);
    try w.writeAll(&bio);
    // HeightMap
    try w.writeByte(11);
    try w.writeInt(u16, 9, .big);
    try w.writeAll("HeightMap");
    try w.writeInt(i32, 256, .big);
    var hi: usize = 0;
    while (hi < 256) : (hi += 1) try w.writeInt(i32, 64, .big);
    try w.writeByte(0); // end Level
    try w.writeByte(0); // end root

    const ch = try fromAnvilNbt(a, aw.written(), 0);
    defer ch.destroy(a);
    try std.testing.expectEqual(@as(i32, 7), ch.x);
    try std.testing.expectEqual(@as(i32, -3), ch.z);
    try std.testing.expect(ch.sections[0] != null);
    try std.testing.expect(ch.sections[1] == null);
    try std.testing.expectEqual(ids.stone, ch.sections[0].?.getBlock(0, 0, 0));
    try std.testing.expectEqual(ids.diamond_block, ch.sections[0].?.getBlock(15, 15, 15));
    try std.testing.expectEqual(@as(u8, 7), ch.biomes[100]);
    try std.testing.expectEqual(@as(u8, 64), ch.heights[100]);
    // ZC1 encode of converted chunk decodes back
    const enc = try ch.encode(a);
    defer a.free(enc);
    const dec = try Chunk.decode(a, enc);
    defer dec.destroy(a);
    try std.testing.expectEqual(ids.diamond_block, dec.sections[0].?.getBlock(15, 15, 15));
}
