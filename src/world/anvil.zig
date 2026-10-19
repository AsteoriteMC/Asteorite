//! Anvil .mca region parsing for 1.7.10.
//!
//! File layout: 4KiB sectors. Sector 0: 1024x u32 BE locations.
//! Sector 1: 1024x u32 BE timestamps. Then chunk payloads.
//! Location entry: (offset_sectors: u24 BE << 8 | size_sectors: u8).
//! Index: (x_mod_32) + (z_mod_32)*32 where x,z are chunk coords mod 32.
//! Payload: i32 BE length + u8 compression (1=gzip,2=zlib) + data.
//!
//! No file I/O here (caller maps file); decompress via std.compress.flate.

const std = @import("std");
const flate = std.compress.flate;

pub const sector_size = 4096;
pub const header_sectors = 2;
pub const chunks_per_region = 1024;

pub const AnvilError = error{
    FileTooSmall,
    BadOffset,
    BadLength,
    TruncatedPayload,
    UnsupportedCompression,
    DecompressFailed,
    OutOfMemory,
};

pub const Compression = enum(u8) {
    gzip = 1,
    zlib = 2,
};

/// Parse 8KB header. Returns location table (1024 entries, raw u32 BE).
pub fn parseHeader(file: []const u8) AnvilError!struct { locations: [1024]u32, timestamps: [1024]u32 } {
    if (file.len < sector_size * header_sectors) return error.FileTooSmall;
    var locs: [1024]u32 = undefined;
    var stamps: [1024]u32 = undefined;
    for (0..1024) |i| {
        locs[i] = std.mem.readInt(u32, file[i * 4 ..][0..4], .big);
        stamps[i] = std.mem.readInt(u32, file[sector_size + i * 4 ..][0..4], .big);
    }
    return .{ .locations = locs, .timestamps = stamps };
}

pub inline fn chunkIndex(local_x: u5, local_z: u5) usize {
    return @as(usize, local_x) + @as(usize, local_z) * 32;
}

pub inline fn localCoord(chunk: i32) u5 {
    // mod 32 in [0,32)
    const m = @mod(chunk, @as(i32, 32));
    return @intCast(m);
}

pub const ChunkLocation = struct {
    offset_sectors: u32,
    size_sectors: u8,
    present: bool,
};

pub fn decodeLocation(raw: u32) ChunkLocation {
    if (raw == 0) return .{ .offset_sectors = 0, .size_sectors = 0, .present = false };
    return .{
        .offset_sectors = raw >> 8,
        .size_sectors = @truncate(raw & 0xFF),
        .present = true,
    };
}

pub const ChunkPayload = struct {
    compression: Compression,
    /// Compressed bytes (length-1 bytes after compression-type byte).
    compressed: []const u8,
};

/// Locate + slice a chunk payload. Validates sector bounds.
pub fn getChunkPayload(file: []const u8, local_x: u5, local_z: u5) AnvilError!ChunkPayload {
    const hdr = try parseHeader(file);
    const raw = hdr.locations[chunkIndex(local_x, local_z)];
    const loc = decodeLocation(raw);
    if (!loc.present) return error.BadOffset;
    if (loc.offset_sectors < 2) return error.BadOffset;
    if (loc.size_sectors == 0) return error.BadLength;
    const start: usize = @as(usize, loc.offset_sectors) * sector_size;
    if (start + 5 > file.len) return error.TruncatedPayload;
    const end_sectors: usize = @as(usize, loc.offset_sectors + loc.size_sectors) * sector_size;
    if (end_sectors > file.len) return error.TruncatedPayload;
    const length = std.mem.readInt(i32, file[start..][0..4], .big);
    if (length <= 0) return error.BadLength;
    if (length > @as(i32, loc.size_sectors) * sector_size - 4) return error.BadLength;
    const ctype = file[start + 4];
    const comp: Compression = switch (ctype) {
        1 => .gzip,
        2 => .zlib,
        else => return error.UnsupportedCompression,
    };
    const clen: usize = @intCast(length - 1);
    if (start + 5 + clen > file.len) return error.TruncatedPayload;
    return .{ .compression = comp, .compressed = file[start + 5 .. start + 5 + clen] };
}

/// Decompress chunk NBT bytes into allocator-owned buffer.
pub fn decompressChunk(allocator: std.mem.Allocator, payload: ChunkPayload) AnvilError![]u8 {
    const container: flate.Container = switch (payload.compression) {
        .gzip => .gzip,
        .zlib => .zlib,
    };
    var in: std.Io.Reader = .fixed(payload.compressed);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var decomp = flate.Decompress.init(&in, container, &.{});
    _ = decomp.reader.streamRemaining(&aw.writer) catch return error.DecompressFailed;
    // streamRemaining returns count; ownership moves to caller via toOwnedSlice
    const out = aw.toOwnedSlice() catch return error.OutOfMemory;
    return out;
}

const testing = std.testing;

test "header too small" {
    try testing.expectError(error.FileTooSmall, parseHeader(&[_]u8{}));
}

test "decode location" {
    const l = decodeLocation(0);
    try testing.expect(!l.present);
    // offset=2, size=1 -> raw = (2<<8)|1
    const l2 = decodeLocation((2 << 8) | 1);
    try testing.expect(l2.present);
    try testing.expectEqual(@as(u32, 2), l2.offset_sectors);
    try testing.expectEqual(@as(u8, 1), l2.size_sectors);
}

test "local coord mod" {
    try testing.expectEqual(@as(u5, 0), localCoord(0));
    try testing.expectEqual(@as(u5, 31), localCoord(31));
    try testing.expectEqual(@as(u5, 0), localCoord(32));
    try testing.expectEqual(@as(u5, 31), localCoord(-1));
}

test "synthetic region roundtrip (zlib)" {
    // Minimal region in memory: header + 1 chunk sector.
    // raw NBT = empty root compound: TAG_Compound("") + TAG_End.
    // zlib bytes precomputed (python zlib.compress): 78 9c e3 62 60 60 00 00 00 2c 00 0b
    const allocator = testing.allocator;
    const raw_nbt = [_]u8{ 0x0A, 0x00, 0x00, 0x00 };
    const comp_bytes = [_]u8{ 0x78, 0x9C, 0xE3, 0x62, 0x60, 0x60, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x0B };
    // assemble file: 2 header sectors + 1 data sector
    var file = try allocator.alloc(u8, sector_size * 3);
    defer allocator.free(file);
    @memset(file, 0);
    const loc_raw: u32 = (2 << 8) | 1;
    std.mem.writeInt(u32, file[0..4], loc_raw, .big);
    const paylen: i32 = @intCast(comp_bytes.len + 1);
    std.mem.writeInt(i32, file[sector_size * 2 ..][0..4], paylen, .big);
    file[sector_size * 2 + 4] = 2; // zlib
    @memcpy(file[sector_size * 2 + 5 ..][0..comp_bytes.len], &comp_bytes);
    const payload = try getChunkPayload(file, 0, 0);
    try testing.expectEqual(Compression.zlib, payload.compression);
    const plain = try decompressChunk(allocator, payload);
    defer allocator.free(plain);
    try testing.expectEqualSlices(u8, &raw_nbt, plain);
}
