//! Offline Anvil chunk-NBT import (1.7.10 `Level` format) -> canonical ZC1.
//!
//! This is the ONLY boundary that translates 1.7.10 wire ids into the
//! canonical `ids.Id` universe for chunk data. Runtime storage
//! (`world/chunk.zig`) and every simulation module speak canonical ids only;
//! the wire map lives here because an imported 1.7.10 world is, by
//! definition, a protocol-v5 artifact.
//!
//! Reads Level.{xPos,zPos,Sections[{Y,Blocks[4096],Data[2048],Add?,
//! SkyLight,BlockLight}],Biomes[256],HeightMap[256]} and returns a fully
//! populated canonical chunk. `ChunkError` is reused so callers see the
//! same errors they saw when this lived in `world/chunk.zig`.

const std = @import("std");
const ids = @import("../../ids.zig");
const nbt = @import("../nbt.zig");
const wire = @import("../../proto/v5/wire_ids.zig");
const chunk_mod = @import("../chunk.zig");

const Chunk = chunk_mod.Chunk;
const Section = chunk_mod.Section;
const ChunkError = chunk_mod.ChunkError;

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
    if (!found_level) return error.Truncated;
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
                h.* = @intCast(@min(@max(v, 0), 255));
            }
        } else {
            try r.skipPayload(t);
        }
    }
}

/// Sections per Anvil chunk (16 x 16 blocks high).
pub const max_sections: i32 = 16;

fn parseSections(r: *nbt.Reader, c: *Chunk) ChunkError!void {
    const elem = try r.readTagType();
    if (elem != .compound) return error.Truncated;
    const count = try r.readBE(i32);
    if (count < 0 or count > max_sections) return error.Truncated;
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
