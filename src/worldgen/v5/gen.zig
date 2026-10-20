//! 1.7.10 chunk generator (v5 terrain half).
//!
//! Pure function f(worldSeed, cx, cz) -> ZC1 Chunk: density field, block
//! fill, surface builder, carvers, decorators (ores/trees via 3x3 neighbor
//! loop), column skylight, heightmap, voronoi biomes.
//! The stage order mirrors ChunkProviderGenerate.d.

const std = @import("std");
const chunk_mod = @import("../../world/chunk.zig");
const shaper_mod = @import("shaper.zig");
const decor_mod = @import("decor.zig");
const surface_mod = @import("surface.zig");
const carve_mod = @import("carve.zig");

pub const SEA_LEVEL: i32 = 63;

pub const Gen = struct {
    shaper: shaper_mod.Shaper,
    carver: carve_mod.Carver,
    world_seed: i64,

    pub fn init(alloc: std.mem.Allocator, world_seed: i64, large_biomes: bool, amplified: bool) !Gen {
        var gen = Gen{
            .shaper = try shaper_mod.Shaper.init(alloc, world_seed, large_biomes, amplified),
            .carver = undefined,
            .world_seed = world_seed,
        };
        errdefer gen.shaper.deinit();
        gen.carver = carve_mod.Carver.init(alloc, &gen.shaper.chain, gen.shaper.roots[1]);
        return gen;
    }

    pub fn deinit(self: *Gen) void {
        self.shaper.deinit();
    }

    /// Full terrain pipeline into flat vanilla-layout arrays (test seam).
    /// Returned buffers are heap-owned; caller destroys both.
    pub const Flat = struct { blocks: *[shaper_mod.BLOCKS_LEN]u16, meta: *[shaper_mod.BLOCKS_LEN]u8 };

    pub fn genFlat(self: *Gen, alloc: std.mem.Allocator, scratch: std.mem.Allocator, cx: i32, cz: i32) !Flat {
        var q: [shaper_mod.Q_LEN]f64 = undefined;
        try self.shaper.densityField(scratch, cx, cz, &q);
        const blocks = try alloc.create([shaper_mod.BLOCKS_LEN]u16);
        errdefer alloc.destroy(blocks);
        @memset(blocks, 0);
        shaper_mod.Shaper.fillChunk(&q, blocks);
        const meta = try alloc.create([shaper_mod.BLOCKS_LEN]u8);
        errdefer alloc.destroy(meta);
        @memset(meta, 0);
        try self.shaper.surfaceChunk(scratch, cx, cz, blocks, meta);
        // Cave + ravine carvers (in place on the same arrays).
        try self.carver.carveChunk(scratch, cx, cz, self.world_seed, blocks);
        return .{ .blocks = blocks, .meta = meta };
    }

    /// Generate chunk (cx,cz) into a heap Chunk. Caller destroys.
    /// scratch is a per-call arena; alloc backs the returned Chunk.
    /// Decorators (ores/trees) run on a 3x3 shaped view (terrain+carve for
    /// neighbors + center), then the center is extracted. Cost: 9x genFlat
    /// per chunk (cached in LSM; background pre-gen amortizes).
    pub fn genChunk(self: *Gen, alloc: std.mem.Allocator, scratch: std.mem.Allocator, cx: i32, cz: i32) !*chunk_mod.Chunk {
        const flat = try self.genFlat(alloc, scratch, cx, cz);
        defer alloc.destroy(flat.blocks);
        defer alloc.destroy(flat.meta);
        // 3x3 decorate: neighbors + center terrain into a 48x48 view.
        try self.decorateInto(alloc, scratch, cx, cz, flat.blocks, flat.meta);
        const blocks = flat.blocks;
        const meta_fixed: *[shaper_mod.BLOCKS_LEN]u8 = flat.meta;

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
                        const mv: u4 = @truncate(meta_fixed[vpos]);
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
    fn decorateInto(self: *Gen, alloc: std.mem.Allocator, scratch: std.mem.Allocator, cx: i32, cz: i32, blocks: *[shaper_mod.BLOCKS_LEN]u16, meta: *[shaper_mod.BLOCKS_LEN]u8) !void {
        const VS: usize = 48;
        const vblocks = try scratch.alloc(u16, VS * 256 * VS);
        defer scratch.free(vblocks);
        const vmetas = try scratch.alloc(u8, VS * 256 * VS);
        defer scratch.free(vmetas);
        @memset(vblocks, 0);
        @memset(vmetas, 0);
        // Copy center first (then neighbors overwrite their regions; center
        // region will be overwritten by our copy below? Actually copy center
        // into view center, then neighbors into their regions).
        // Layout: view (x,z) with ox=(cx-1)*16. Local lx in 0..48.
        // Center chunk occupies lx 16..31, lz 16..31.
        {
            var lx: usize = 0;
            while (lx < 16) : (lx += 1) {
                var lz: usize = 0;
                while (lz < 16) : (lz += 1) {
                    var y: usize = 0;
                    while (y < 256) : (y += 1) {
                        const src = (lx * 4096 + lz * 256) + y;
                        const dst = ((lx + 16) * VS + (lz + 16)) * 256 + y;
                        vblocks[dst] = blocks[src];
                        vmetas[dst] = meta[src];
                    }
                }
            }
        }
        // Neighbors (8 surrounding chunks).
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                if (dx == 0 and dz == 0) continue;
                const nx = cx + dx;
                const nz = cz + dz;
                const nflat = try self.genFlat(alloc, scratch, nx, nz);
                defer alloc.destroy(nflat.blocks);
                defer alloc.destroy(nflat.meta);
                const ox: usize = @intCast(dx + 1);
                const oz: usize = @intCast(dz + 1);
                var lx: usize = 0;
                while (lx < 16) : (lx += 1) {
                    var lz: usize = 0;
                    while (lz < 16) : (lz += 1) {
                        var y: usize = 0;
                        while (y < 256) : (y += 1) {
                            const src = (lx * 4096 + lz * 256) + y;
                            const dst = ((lx + ox * 16) * VS + (lz + oz * 16)) * 256 + y;
                            vblocks[dst] = nflat.blocks[src];
                            vmetas[dst] = nflat.meta[src];
                        }
                    }
                }
            }
        }
        var view = decor_mod.View{
            .blocks = vblocks,
            .metas = vmetas,
            .ox = (cx - 1) * 16,
            .oz = (cz - 1) * 16,
            .sx = VS,
            .sz = VS,
        };
        const vheights = try scratch.alloc(i32, VS * VS);
        defer scratch.free(vheights);
        decor_mod.computeHeights(&view, vheights);
        try decor_mod.decorateCenter(&view, vheights, self.world_seed, cx, cz, &self.shaper.chain, self.shaper.roots[1], scratch);
        // Extract decorated center back into blocks/meta.
        var lx: usize = 0;
        while (lx < 16) : (lx += 1) {
            var lz: usize = 0;
            while (lz < 16) : (lz += 1) {
                var y: usize = 0;
                while (y < 256) : (y += 1) {
                    const dst = (lx * 4096 + lz * 256) + y;
                    const src = ((lx + 16) * VS + (lz + 16)) * 256 + y;
                    blocks[dst] = vblocks[src];
                    meta[dst] = vmetas[src];
                }
            }
        }
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

test "full pipeline matches JVM (seed 1 chunk 0,0)" {
    const alloc = std.testing.allocator;
    var gen = try Gen.init(alloc, 1, false, false);
    defer gen.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const flat = try gen.genFlat(alloc, arena.allocator(), 0, 0);
    defer alloc.destroy(flat.blocks);
    defer alloc.destroy(flat.meta);
    // JVM: 0:49568 1:10657 7:762 9:4288 11:5 13:256
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 2364179251614800980), bc);
    var mc: i64 = 0; for (flat.meta.*) |v| mc = mc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 0), mc);
    const samp_idx = [_]usize{0,1024,2048,3072,4096,5120,6144,7168,8192,9216,10240,11264,12288,13312,14336,15360,16384,17408,18432,19456,20480,21504,22528,23552,24576,25600,26624,27648,28672,29696,30720,31744,32768,33792,34816,35840,36864,37888,38912,39936,40960,41984,43008,44032,45056,46080,47104,48128,49152,50176,51200,52224,53248,54272,55296,56320,57344,58368,59392,60416,61440,62464,63488,64512};
    const samp_want = [_]u16{7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7};
    const sampm_want = [_]u8{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
    for (samp_idx, 0..) |idx, k| {
        try std.testing.expectEqual(samp_want[k], flat.blocks[idx]);
        try std.testing.expectEqual(sampm_want[k], flat.meta[idx]);
    }
}

test "full pipeline matches JVM (seed 42 chunk 3,-5)" {
    const alloc = std.testing.allocator;
    var gen = try Gen.init(alloc, 42, false, false);
    defer gen.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const flat = try gen.genFlat(alloc, arena.allocator(), 3, -5);
    defer alloc.destroy(flat.blocks);
    defer alloc.destroy(flat.meta);
    // JVM: 0:47873 1:16080 2:256 3:542 7:762 11:23
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, -5565306032280757361), bc);
    var mc: i64 = 0; for (flat.meta.*) |v| mc = mc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 0), mc);
    const samp_idx = [_]usize{0,1024,2048,3072,4096,5120,6144,7168,8192,9216,10240,11264,12288,13312,14336,15360,16384,17408,18432,19456,20480,21504,22528,23552,24576,25600,26624,27648,28672,29696,30720,31744,32768,33792,34816,35840,36864,37888,38912,39936,40960,41984,43008,44032,45056,46080,47104,48128,49152,50176,51200,52224,53248,54272,55296,56320,57344,58368,59392,60416,61440,62464,63488,64512};
    const samp_want = [_]u16{7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7};
    const sampm_want = [_]u8{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
    for (samp_idx, 0..) |idx, k| {
        try std.testing.expectEqual(samp_want[k], flat.blocks[idx]);
        try std.testing.expectEqual(sampm_want[k], flat.meta[idx]);
    }
}

test "full pipeline matches JVM (seed 12345 chunk -7,11)" {
    const alloc = std.testing.allocator;
    var gen = try Gen.init(alloc, 12345, false, false);
    defer gen.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const flat = try gen.genFlat(alloc, arena.allocator(), -7, 11);
    defer alloc.destroy(flat.blocks);
    defer alloc.destroy(flat.meta);
    // JVM: 0:44957 1:19145 2:256 3:429 7:749
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 8615861512796570065), bc);
    var mc: i64 = 0; for (flat.meta.*) |v| mc = mc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 0), mc);
    const samp_idx = [_]usize{0,1024,2048,3072,4096,5120,6144,7168,8192,9216,10240,11264,12288,13312,14336,15360,16384,17408,18432,19456,20480,21504,22528,23552,24576,25600,26624,27648,28672,29696,30720,31744,32768,33792,34816,35840,36864,37888,38912,39936,40960,41984,43008,44032,45056,46080,47104,48128,49152,50176,51200,52224,53248,54272,55296,56320,57344,58368,59392,60416,61440,62464,63488,64512};
    const samp_want = [_]u16{7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7};
    const sampm_want = [_]u8{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
    for (samp_idx, 0..) |idx, k| {
        try std.testing.expectEqual(samp_want[k], flat.blocks[idx]);
        try std.testing.expectEqual(sampm_want[k], flat.meta[idx]);
    }
}

test "full pipeline matches JVM (seed 55555 chunk -1,-1)" {
    const alloc = std.testing.allocator;
    var gen = try Gen.init(alloc, 55555, false, false);
    defer gen.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const flat = try gen.genFlat(alloc, arena.allocator(), -1, -1);
    defer alloc.destroy(flat.blocks);
    defer alloc.destroy(flat.meta);
    // JVM: 0:42769 1:14739 2:11 3:69 7:765 11:86 159:2836 172:4261
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 4935923522670880547), bc);
    var mc: i64 = 0; for (flat.meta.*) |v| mc = mc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 4590157575938082706), mc);
    const samp_idx = [_]usize{0,1024,2048,3072,4096,5120,6144,7168,8192,9216,10240,11264,12288,13312,14336,15360,16384,17408,18432,19456,20480,21504,22528,23552,24576,25600,26624,27648,28672,29696,30720,31744,32768,33792,34816,35840,36864,37888,38912,39936,40960,41984,43008,44032,45056,46080,47104,48128,49152,50176,51200,52224,53248,54272,55296,56320,57344,58368,59392,60416,61440,62464,63488,64512};
    const samp_want = [_]u16{7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7};
    const sampm_want = [_]u8{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
    for (samp_idx, 0..) |idx, k| {
        try std.testing.expectEqual(samp_want[k], flat.blocks[idx]);
        try std.testing.expectEqual(sampm_want[k], flat.meta[idx]);
    }
}

test "full pipeline matches JVM (seed 55555 chunk 0,0)" {
    const alloc = std.testing.allocator;
    var gen = try Gen.init(alloc, 55555, false, false);
    defer gen.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const flat = try gen.genFlat(alloc, arena.allocator(), 0, 0);
    defer alloc.destroy(flat.blocks);
    defer alloc.destroy(flat.meta);
    // JVM: 0:44920 1:14337 7:762 12:16 159:1996 172:3505
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 4287607934416868155), bc);
    var mc: i64 = 0; for (flat.meta.*) |v| mc = mc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 3474580793047174204), mc);
    const samp_idx = [_]usize{0,1024,2048,3072,4096,5120,6144,7168,8192,9216,10240,11264,12288,13312,14336,15360,16384,17408,18432,19456,20480,21504,22528,23552,24576,25600,26624,27648,28672,29696,30720,31744,32768,33792,34816,35840,36864,37888,38912,39936,40960,41984,43008,44032,45056,46080,47104,48128,49152,50176,51200,52224,53248,54272,55296,56320,57344,58368,59392,60416,61440,62464,63488,64512};
    const samp_want = [_]u16{7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7};
    const sampm_want = [_]u8{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
    for (samp_idx, 0..) |idx, k| {
        try std.testing.expectEqual(samp_want[k], flat.blocks[idx]);
        try std.testing.expectEqual(sampm_want[k], flat.meta[idx]);
    }
}

test "full pipeline matches JVM (seed 42 chunk 0,1)" {
    const alloc = std.testing.allocator;
    var gen = try Gen.init(alloc, 42, false, false);
    defer gen.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const flat = try gen.genFlat(alloc, arena.allocator(), 0, 1);
    defer alloc.destroy(flat.blocks);
    defer alloc.destroy(flat.meta);
    // JVM: 0:49676 1:13999 2:256 3:786 7:773 11:46
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, -1906778931135305072), bc);
    var mc: i64 = 0; for (flat.meta.*) |v| mc = mc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 0), mc);
    const samp_idx = [_]usize{0,1024,2048,3072,4096,5120,6144,7168,8192,9216,10240,11264,12288,13312,14336,15360,16384,17408,18432,19456,20480,21504,22528,23552,24576,25600,26624,27648,28672,29696,30720,31744,32768,33792,34816,35840,36864,37888,38912,39936,40960,41984,43008,44032,45056,46080,47104,48128,49152,50176,51200,52224,53248,54272,55296,56320,57344,58368,59392,60416,61440,62464,63488,64512};
    const samp_want = [_]u16{7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7};
    const sampm_want = [_]u8{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
    for (samp_idx, 0..) |idx, k| {
        try std.testing.expectEqual(samp_want[k], flat.blocks[idx]);
        try std.testing.expectEqual(sampm_want[k], flat.meta[idx]);
    }
}

test "full pipeline matches JVM (seed 1 chunk 5,-3)" {
    const alloc = std.testing.allocator;
    var gen = try Gen.init(alloc, 1, false, false);
    defer gen.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const flat = try gen.genFlat(alloc, arena.allocator(), 5, -3);
    defer alloc.destroy(flat.blocks);
    defer alloc.destroy(flat.meta);
    // JVM: 0:49469 1:12246 3:132 7:769 9:2244 12:395 13:104 24:177
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 6731895858531559897), bc);
    var mc: i64 = 0; for (flat.meta.*) |v| mc = mc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 0), mc);
    const samp_idx = [_]usize{0,1024,2048,3072,4096,5120,6144,7168,8192,9216,10240,11264,12288,13312,14336,15360,16384,17408,18432,19456,20480,21504,22528,23552,24576,25600,26624,27648,28672,29696,30720,31744,32768,33792,34816,35840,36864,37888,38912,39936,40960,41984,43008,44032,45056,46080,47104,48128,49152,50176,51200,52224,53248,54272,55296,56320,57344,58368,59392,60416,61440,62464,63488,64512};
    const samp_want = [_]u16{7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7};
    const sampm_want = [_]u8{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
    for (samp_idx, 0..) |idx, k| {
        try std.testing.expectEqual(samp_want[k], flat.blocks[idx]);
        try std.testing.expectEqual(sampm_want[k], flat.meta[idx]);
    }
}

test "full pipeline matches JVM (seed 777 chunk 10,10)" {
    const alloc = std.testing.allocator;
    var gen = try Gen.init(alloc, 777, false, false);
    defer gen.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const flat = try gen.genFlat(alloc, arena.allocator(), 10, 10);
    defer alloc.destroy(flat.blocks);
    defer alloc.destroy(flat.meta);
    // JVM: 0:46261 1:17725 2:256 3:512 7:782
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, -7603012981142211267), bc);
    var mc: i64 = 0; for (flat.meta.*) |v| mc = mc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 0), mc);
    const samp_idx = [_]usize{0,1024,2048,3072,4096,5120,6144,7168,8192,9216,10240,11264,12288,13312,14336,15360,16384,17408,18432,19456,20480,21504,22528,23552,24576,25600,26624,27648,28672,29696,30720,31744,32768,33792,34816,35840,36864,37888,38912,39936,40960,41984,43008,44032,45056,46080,47104,48128,49152,50176,51200,52224,53248,54272,55296,56320,57344,58368,59392,60416,61440,62464,63488,64512};
    const samp_want = [_]u16{7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7};
    const sampm_want = [_]u8{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
    for (samp_idx, 0..) |idx, k| {
        try std.testing.expectEqual(samp_want[k], flat.blocks[idx]);
        try std.testing.expectEqual(sampm_want[k], flat.meta[idx]);
    }
}

test "full pipeline matches JVM (seed 99 chunk -4,6)" {
    const alloc = std.testing.allocator;
    var gen = try Gen.init(alloc, 99, false, false);
    defer gen.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const flat = try gen.genFlat(alloc, arena.allocator(), -4, 6);
    defer alloc.destroy(flat.blocks);
    defer alloc.destroy(flat.meta);
    // JVM: 0:49890 1:10234 7:812 9:4321 11:23 13:256
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, -7906692029262442158), bc);
    var mc: i64 = 0; for (flat.meta.*) |v| mc = mc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 0), mc);
    const samp_idx = [_]usize{0,1024,2048,3072,4096,5120,6144,7168,8192,9216,10240,11264,12288,13312,14336,15360,16384,17408,18432,19456,20480,21504,22528,23552,24576,25600,26624,27648,28672,29696,30720,31744,32768,33792,34816,35840,36864,37888,38912,39936,40960,41984,43008,44032,45056,46080,47104,48128,49152,50176,51200,52224,53248,54272,55296,56320,57344,58368,59392,60416,61440,62464,63488,64512};
    const samp_want = [_]u16{7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7};
    const sampm_want = [_]u8{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
    for (samp_idx, 0..) |idx, k| {
        try std.testing.expectEqual(samp_want[k], flat.blocks[idx]);
        try std.testing.expectEqual(sampm_want[k], flat.meta[idx]);
    }
}

test "full pipeline matches JVM (seed 7 chunk 8,8)" {
    const alloc = std.testing.allocator;
    var gen = try Gen.init(alloc, 7, false, false);
    defer gen.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const flat = try gen.genFlat(alloc, arena.allocator(), 8, 8);
    defer alloc.destroy(flat.blocks);
    defer alloc.destroy(flat.meta);
    // JVM: 0:48853 1:15102 2:256 3:564 7:761
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, -6949208695922250385), bc);
    var mc: i64 = 0; for (flat.meta.*) |v| mc = mc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 0), mc);
    const samp_idx = [_]usize{0,1024,2048,3072,4096,5120,6144,7168,8192,9216,10240,11264,12288,13312,14336,15360,16384,17408,18432,19456,20480,21504,22528,23552,24576,25600,26624,27648,28672,29696,30720,31744,32768,33792,34816,35840,36864,37888,38912,39936,40960,41984,43008,44032,45056,46080,47104,48128,49152,50176,51200,52224,53248,54272,55296,56320,57344,58368,59392,60416,61440,62464,63488,64512};
    const samp_want = [_]u16{7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7};
    const sampm_want = [_]u8{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
    for (samp_idx, 0..) |idx, k| {
        try std.testing.expectEqual(samp_want[k], flat.blocks[idx]);
        try std.testing.expectEqual(sampm_want[k], flat.meta[idx]);
    }
}

