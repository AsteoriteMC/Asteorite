//! 1.7.10 chunk generator (v5 terrain half).
//!
//! Pure function f(worldSeed, cx, cz) -> ZC1 Chunk: density field, block
//! fill, surface builder, column skylight, heightmap, voronoi biomes.
//! Carvers (caves/ravines) and decorators (ores/trees) hook into genChunk
//! (H2 follow-ups); the stage order mirrors ChunkProviderGenerate.d.

const std = @import("std");
const chunk_mod = @import("../../world/chunk.zig");
const shaper_mod = @import("shaper.zig");
const surface_mod = @import("surface.zig");

pub const SEA_LEVEL: i32 = 63;

pub const Gen = struct {
    shaper: shaper_mod.Shaper,

    pub fn init(alloc: std.mem.Allocator, world_seed: i64, large_biomes: bool, amplified: bool) !Gen {
        return .{ .shaper = try shaper_mod.Shaper.init(alloc, world_seed, large_biomes, amplified) };
    }

    pub fn deinit(self: *Gen) void {
        self.shaper.deinit();
    }

    /// Generate chunk (cx,cz) into a heap Chunk. Caller destroys.
    /// scratch is a per-call arena; alloc backs the returned Chunk.
    pub fn genChunk(self: *Gen, alloc: std.mem.Allocator, scratch: std.mem.Allocator, cx: i32, cz: i32) !*chunk_mod.Chunk {
        var q: [shaper_mod.Q_LEN]f64 = undefined;
        try self.shaper.densityField(scratch, cx, cz, &q);
        const blocks = try alloc.create([shaper_mod.BLOCKS_LEN]u16);
        errdefer alloc.destroy(blocks);
        @memset(blocks, 0);
        shaper_mod.Shaper.fillChunk(&q, blocks);
        const meta = try scratch.alloc(u8, shaper_mod.BLOCKS_LEN);
        @memset(meta, 0);
        const meta_fixed: *[shaper_mod.BLOCKS_LEN]u8 = meta[0..shaper_mod.BLOCKS_LEN];
        try self.shaper.surfaceChunk(scratch, cx, cz, blocks, meta_fixed);

        const ch = try chunk_mod.Chunk.createEmpty(alloc, 0, cx, cz);
        errdefer ch.destroy(alloc);
        for (0..16) |s| {
            var any = false;
            for (0..4096) |k| {
                const ly = k / 256;
                const rem = k % 256;
                const lz = rem / 16;
                const lx = rem % 16;
                if (blocks[(lx * 4096 + lz * 256) + (s * 16 + ly)] != 0) {
                    any = true;
                    break;
                }
            }
            if (!any) continue;
            var sec = chunk_mod.Section{};
            for (0..16) |ly| {
                for (0..16) |lz| {
                    for (0..16) |lx| {
                        const vpos = (lx * 4096 + lz * 256) + (s * 16 + ly);
                        const si = chunk_mod.Section.index(@intCast(lx), @intCast(ly), @intCast(lz));
                        sec.blocks[si] = blocks[vpos];
                        const mv: u4 = @truncate(meta[vpos]);
                        chunk_mod.Section.setNibble(&sec.meta, si, mv);
                    }
                }
            }
            ch.sections[s] = sec;
        }
        // Column skylight on existing sections: 15 down to first opaque.
        // NOTE: water is transparent here (vanilla attenuates; approximation
        // documented in H2 notes). Nibble first, then close the sky below:
        // the surface cell itself sees full skylight.
        for (0..16) |lz| {
            for (0..16) |lx| {
                var sky: u4 = 15;
                var y: i32 = 255;
                while (y >= 0) : (y -= 1) {
                    const uy: usize = @intCast(y);
                    const s: usize = uy / 16;
                    if (ch.sections[s]) |*sec| {
                        const lsi = chunk_mod.Section.index(@intCast(lx), @intCast(uy % 16), @intCast(lz));
                        chunk_mod.Section.setNibble(&sec.sky, lsi, sky);
                    }
                    if (blocks[(lx * 4096 + lz * 256) + uy] != 0 and blocks[(lx * 4096 + lz * 256) + uy] != surface_mod.WATER) sky = 0;
                }
            }
        }
        // Biomes (voronoi) + heights (topmost non-air).
        {
            const bio = try scratch.alloc(i32, 256);
            defer scratch.free(bio);
            try self.shaper.chain.getInts(scratch, self.shaper.roots[1], cx * 16, cz * 16, 16, 16, bio);
            for (bio, 0..) |id, k| ch.biomes[k] = @truncate(@as(u32, @bitCast(id)));
            for (0..16) |lz| {
                for (0..16) |lx| {
                    var top: u8 = 0;
                    var y: i32 = 255;
                    while (y >= 0) : (y -= 1) {
                        if (blocks[(lx * 4096 + lz * 256) + @as(usize, @intCast(y))] != 0) {
                            top = @intCast(y);
                            break;
                        }
                    }
                    ch.heights[lz * 16 + lx] = top;
                }
            }
        }
        // Caller owns blocks/meta copies? No — blocks is baked into ch.
        // Free the staging buffer (sections hold copies).
        alloc.destroy(blocks);
        return ch;
    }

    /// Standing-room Y at column (lx,lz) of a vanilla-layout block array.
    pub fn surfaceY(blocks: *const [shaper_mod.BLOCKS_LEN]u16, lx: usize, lz: usize) i32 {
        var y: i32 = 255;
        while (y >= 0) : (y -= 1) {
            if (blocks[(lx * 4096 + lz * 256) + @as(usize, @intCast(y))] != 0) return y + 1;
        }
        return SEA_LEVEL + 1;
    }
};

test "genChunk packs ZC1 faithfully (seed 42 chunk 3,-5)" {
    const alloc = std.testing.allocator;
    var gen = try Gen.init(alloc, 42, false, false);
    defer gen.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ch = try gen.genChunk(alloc, arena.allocator(), 3, -5);
    defer ch.destroy(alloc);
    // Sections with terrain: y 0..68 => sections 0..4.
    try std.testing.expect(ch.mask() & 0x1F == 0x1F);
    // Voronoi icePlains everywhere in this window.
    for (ch.biomes) |b| try std.testing.expectEqual(@as(u8, 12), b);
    // Column (0,0): bedrock, dirt at 67, grass at 68 (JVM goldens).
    {
        const s0 = ch.sections[0].?;
        try std.testing.expectEqual(@as(u16, 7), s0.blocks[0]);
    }
    {
        const s4 = ch.sections[4].?;
        const dirt = s4.blocks[3 * 256];
        const grass = s4.blocks[4 * 256];
        try std.testing.expectEqual(@as(u16, 3), dirt);
        try std.testing.expectEqual(@as(u16, 2), grass);
        // Skylight: 15 at/above surface, 0 inside stone.
        const sky_top = chunk_mod.Section.getNibble(&s4.sky, 4 * 256);
        try std.testing.expectEqual(@as(u4, 15), sky_top);
        const sky_in = s4.blocks[0];
        _ = sky_in;
        const sky_below = chunk_mod.Section.getNibble(&s4.sky, 0);
        try std.testing.expectEqual(@as(u4, 0), sky_below);
    }
    // Heightmap: topmost non-air.
    try std.testing.expectEqual(@as(u8, 68), ch.heights[0]);
}
