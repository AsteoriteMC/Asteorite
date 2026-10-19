//! 1.7.10 chunk column wire encoding (MapChunk 0x21 / MapChunkBulk 0x26).
//!
//! Uncompressed column layout (grouped, sections low->high), verified against
//! ClientViaVersion's 1.8->1.7 transformer size formula
//! (8192*k + 2048*l + sky + 256) and proto.yml packet shells:
//!   blocks 4096B x k | meta 2048B x k | blocklight 2048B x k
//!   | skylight 2048B x k (overworld only) | add 2048B x l | biomes 256B (groundUp)
//! Compressed with zlib (RFC1950). YZX cell order matches ZC1 sections.
//!
//! We only ever send full columns (groundUp=true). Unload = mask 0 + 256
//! zero bytes (biome slot), per the vanilla convention.

const std = @import("std");
const flate = std.compress.flate;
const codec = @import("../../net/codec.zig");
const ids = @import("ids.zig");
const chunk_mod = @import("../../world/chunk.zig");

pub const sky_sent_overworld = true;

/// k = sections present, l = sections needing Add (>255 ids).
pub fn columnUncompressedLen(primary_mask: u16, add_mask: u16, sky: bool, ground_up: bool) usize {
    const k: usize = @popCount(primary_mask);
    const l: usize = @popCount(add_mask);
    var n: usize = 8192 * k + 2048 * l;
    if (sky) n += 2048 * k;
    if (ground_up) n += 256;
    return n;
}

pub fn primaryMask(ch: *const chunk_mod.Chunk) u16 {
    return ch.mask();
}

/// Sections containing any id > 0xFF need Add nibbles on the wire.
pub fn addMask(ch: *const chunk_mod.Chunk) u16 {
    var m: u16 = 0;
    for (ch.sections, 0..) |maybe, i| {
        const s = maybe orelse continue;
        for (s.blocks) |b| {
            if (b > 0xFF) {
                m |= @as(u16, 1) << @intCast(i);
                break;
            }
        }
    }
    return m;
}

pub const ColumnLayout = struct {
    primary: u16,
    add: u16,
    len: usize,
};

/// Serialize one full ZC1 column into grouped wire order. Returns layout.
/// `out` must hold columnUncompressedLen(primary, add, sky, true) bytes.
pub fn encodeColumn(ch: *const chunk_mod.Chunk, sky: bool, out: []u8) ColumnLayout {
    const primary = primaryMask(ch);
    const add = addMask(ch);
    const want = columnUncompressedLen(primary, add, sky, true);
    std.debug.assert(out.len >= want);
    var p: usize = 0;
    // 1. block LSBs, all present sections
    for (ch.sections) |maybe| {
        const s = maybe orelse continue;
        for (s.blocks) |b| {
            out[p] = @truncate(b & 0xFF);
            p += 1;
        }
    }
    // 2. metadata nibbles
    for (ch.sections) |maybe| {
        const s = maybe orelse continue;
        @memcpy(out[p..][0..2048], &s.meta);
        p += 2048;
    }
    // 3. blocklight
    for (ch.sections) |maybe| {
        const s = maybe orelse continue;
        @memcpy(out[p..][0..2048], &s.light);
        p += 2048;
    }
    // 4. skylight (overworld)
    if (sky) {
        for (ch.sections) |maybe| {
            const s = maybe orelse continue;
            @memcpy(out[p..][0..2048], &s.sky);
            p += 2048;
        }
    }
    // 5. add nibbles for add-mask sections
    for (ch.sections, 0..) |maybe, i| {
        if (add & (@as(u16, 1) << @intCast(i)) == 0) continue;
        const s = maybe orelse continue;
        for (0..4096) |idx| {
            const v: u8 = @truncate((s.blocks[idx] >> 8) & 0xF);
            if (idx & 1 == 0) {
                out[p + (idx >> 1)] = v;
            } else {
                out[p + (idx >> 1)] |= v << 4;
            }
        }
        p += 2048;
    }
    // 6. biomes
    @memcpy(out[p..][0..256], &ch.biomes);
    p += 256;
    std.debug.assert(p == want);
    return .{ .primary = primary, .add = add, .len = want };
}

/// zlib-compress `raw` into `compressed_out`. `work` must be >= 64KB history.
pub fn zlibCompress(raw: []const u8, compressed_out: []u8, work: []u8) ![]u8 {
    std.debug.assert(work.len >= flate.max_window_len);
    var out_w: std.Io.Writer = .fixed(compressed_out);
    // Writer.fixed needs spare capacity for the container header; require slack.
    var comp = try flate.Compress.init(&out_w, work, .zlib, .default);
    try comp.writer.writeAll(raw);
    try comp.finish();
    return out_w.buffered();
}

/// Single column packet 0x21.
pub fn frameMapChunk(x: i32, z: i32, primary: u16, add: u16, compressed: []const u8, out: []u8) codec.CodecError![]const u8 {
    // Payload size = 4+4+1+2+2+4+len; Length covers id + payload.
    const payload_len: usize = 17 + compressed.len;
    const total: usize = payload_len + 1;
    if (codec.PacketWriter.varIntLen(@intCast(total)) + total > out.len) return error.PacketTooLarge;
    var w = codec.PacketWriter.init(out);
    try w.writeVarInt(@intCast(total));
    try w.writeVarInt(@intFromEnum(ids.PlayClient.chunk_data));
    try w.writeInt(x);
    try w.writeInt(z);
    try w.writeByte(1); // groundUp
    try w.writeUShort(primary);
    try w.writeUShort(add);
    try w.writeInt(@intCast(compressed.len));
    try w.writeBytes(compressed);
    return w.written();
}

/// Bulk packet 0x26: ONE zlib stream over concatenated raw columns,
/// then per-column metas. (Vanilla compresses buildBuffer once; the client
/// splits by computed per-column sizes.)
pub const BulkColumn = struct {
    x: i32,
    z: i32,
    primary: u16,
    add: u16,
};

pub fn frameMapChunkBulk(cols: []const BulkColumn, compressed: []const u8, sky: bool, out: []u8) codec.CodecError![]const u8 {
    // payload = 2 + 4 + 1 + data + 12*cols (meta = x+z+primary+add)
    const payload_len = 7 + compressed.len + 12 * cols.len;
    if (codec.PacketWriter.varIntLen(@intCast(payload_len + 1)) + payload_len + 1 > out.len) {
        return error.PacketTooLarge;
    }
    var w = codec.PacketWriter.init(out);
    try w.writeVarInt(@intCast(payload_len + 1)); // +1 for packet id byte
    try w.writeVarInt(@intFromEnum(ids.PlayClient.map_chunk_bulk));
    try w.writeShort(@intCast(cols.len));
    try w.writeInt(@intCast(compressed.len));
    try w.writeByte(if (sky) 1 else 0);
    try w.writeBytes(compressed);
    for (cols) |c| {
        try w.writeInt(c.x);
        try w.writeInt(c.z);
        try w.writeUShort(c.primary);
        try w.writeUShort(c.add);
    }
    return w.written();
}

/// Unload signal: groundUp + empty masks + 256 zero bytes (biome slot).
pub fn frameUnloadChunk(x: i32, z: i32, out: []u8) ![]const u8 {
    var zeros: [256]u8 = [_]u8{0} ** 256;
    var zbuf: [512]u8 = undefined;
    var work: [flate.max_window_len]u8 = undefined;
    const comp = try zlibCompress(&zeros, &zbuf, &work);
    return try frameMapChunk(x, z, 0, 0, comp, out);
}

test "size formula matches ClientViaVersion calcSize" {
    try std.testing.expectEqual(@as(usize, 8192 + 2048 + 256), columnUncompressedLen(0x1, 0, true, true));
    try std.testing.expectEqual(@as(usize, 16 * 8192 + 16 * 2048 + 256), columnUncompressedLen(0xFFFF, 0, true, true));
    try std.testing.expectEqual(@as(usize, 0), columnUncompressedLen(0, 0, true, false));
    try std.testing.expectEqual(@as(usize, 256), columnUncompressedLen(0, 0, true, true)); // unload shape
    // add section: +2048
    try std.testing.expectEqual(@as(usize, 8192 + 2048 + 2048 + 256), columnUncompressedLen(0x1, 0x1, true, true));
}

test "single chunk + unload frames carry exact Length" {
    // Length must cover id + full payload (caught an off-by-one live).
    var out: [2048]u8 = undefined;
    const f = try frameMapChunk(3, -2, 1, 0, &[_]u8{ 0x78, 0x9C, 0x01 }, &out);
    var r = codec.PacketReader.init(f);
    const h = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 0x21), h.id);
    try std.testing.expectEqual(@as(i32, @intCast(f.len - codec.PacketWriter.varIntLen(h.length))), h.length);
    try std.testing.expectEqual(@as(i32, 3), try r.readInt());
    try std.testing.expectEqual(@as(i32, -2), try r.readInt());
    var uo: [2048]u8 = undefined;
    const u = try frameUnloadChunk(7, 9, &uo);
    var ru = codec.PacketReader.init(u);
    const hu = try codec.decodeFrame(&ru);
    try std.testing.expectEqual(@as(i32, 0x21), hu.id);
    try std.testing.expectEqual(@as(i32, @intCast(u.len - codec.PacketWriter.varIntLen(hu.length))), hu.length);
}

test "add mask detects high ids" {
    const a = std.testing.allocator;
    var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
    defer ch.destroy(a);
    try std.testing.expectEqual(@as(u16, 0), addMask(ch));
    var s = chunk_mod.Section{};
    try s.setBlock(0, 0, 0, 0x1AB);
    ch.sections[3] = s;
    try std.testing.expectEqual(@as(u16, 1 << 3), addMask(ch));
}

test "encode column grouped layout + zlib roundtrip" {
    const a = std.testing.allocator;
    var ch = try chunk_mod.Chunk.createEmpty(a, 0, 5, -2);
    defer ch.destroy(a);
    var s0 = chunk_mod.Section{};
    try s0.setBlock(0, 0, 0, 1);
    try s0.setBlock(1, 0, 0, 0x1AB); // forces add bit
    chunk_mod.Section.setNibble(&s0.meta, 0, 0x5);
    ch.sections[0] = s0;
    var s2 = chunk_mod.Section{};
    try s2.setBlock(15, 15, 15, 57);
    ch.sections[2] = s2;
    ch.biomes[0] = 4;
    ch.biomes[255] = 4;

    var raw: [70000]u8 = undefined;
    const layout = encodeColumn(ch, true, &raw);
    try std.testing.expectEqual(@as(u16, 0b101), layout.primary);
    try std.testing.expectEqual(@as(u16, 0b001), layout.add);
    const k: usize = 2;
    // grouped offsets: blocks 8192 | meta 4096 | blight 4096 | slight 4096 | add 2048 | biome 256
    const data = raw[0..layout.len];
    try std.testing.expectEqual(@as(usize, 8192 * k + 2048 * k + 2048 + 256), data.len);
    // section0 blocks[0]=1, blocks[1] LSB of 0x1AB = 0xAB
    try std.testing.expectEqual(@as(u8, 1), data[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), data[1]);
    // section2 starts at 4096; its last cell = 57
    try std.testing.expectEqual(@as(u8, 57), data[8191]);
    // meta for section0 starts at 8192: nibble0 = 0x5
    try std.testing.expectEqual(@as(u8, 0x05), data[8192] & 0x0F);
    // add array starts after blocks+meta+blight+slight
    const base = 4096 * k + 2048 * k + 2048 * k + 2048 * k;
    // add nibble idx1 (odd) of section0 holds 0x1
    try std.testing.expectEqual(@as(u8, 0x10), data[base] & 0xF0);
    // biomes tail
    try std.testing.expectEqual(@as(u8, 4), data[data.len - 256]);
    try std.testing.expectEqual(@as(u8, 4), data[data.len - 1]);

    // zlib roundtrip
    var comp: [70000]u8 = undefined;
    var work: [flate.max_window_len]u8 = undefined;
    const cz = try zlibCompress(data, &comp, &work);
    var in: std.Io.Reader = .fixed(cz);
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    var decomp = flate.Decompress.init(&in, .zlib, &.{});
    _ = try decomp.reader.streamRemaining(&aw.writer);
    try std.testing.expectEqualSlices(u8, data, aw.written());
}

test "bulk frame parses back" {
    const a = std.testing.allocator;
    var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
    defer ch.destroy(a);
    var s = chunk_mod.Section{};
    try s.setBlock(0, 0, 0, 3);
    ch.sections[0] = s;
    var raw: [70000]u8 = undefined;
    const layout = encodeColumn(ch, true, &raw);
    var comp: [70000]u8 = undefined;
    var work: [flate.max_window_len]u8 = undefined;
    const cz = try zlibCompress(raw[0..layout.len], &comp, &work);
    const cols = [_]BulkColumn{.{ .x = 0, .z = 0, .primary = layout.primary, .add = layout.add }};
    var out: [80000]u8 = undefined;
    const f = try frameMapChunkBulk(&cols, cz, true, &out);
    var r = codec.PacketReader.init(f);
    const h = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 0x26), h.id);
    // Length prefix must cover id + full payload (meta is 12B/col)
    try std.testing.expectEqual(@as(i32, @intCast(f.len - codec.PacketWriter.varIntLen(h.length))), h.length);
    try std.testing.expectEqual(@as(i16, 1), try r.readShort());
    const dlen = try r.readInt();
    try std.testing.expectEqual(@as(i32, @intCast(cz.len)), dlen);
    try std.testing.expect(try r.readBool());
    const got = try r.readBytes(@intCast(dlen));
    try std.testing.expectEqualSlices(u8, cz, got);
    try std.testing.expectEqual(@as(i32, 0), try r.readInt());
    try std.testing.expectEqual(@as(i32, 0), try r.readInt());
    try std.testing.expectEqual(layout.primary, try r.readUShort());
    try std.testing.expectEqual(layout.add, try r.readUShort());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}
