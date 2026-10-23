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
const ids = @import("../../ids.zig");
const wire = @import("../../proto/v5/wire_ids.zig");

pub const SEA_LEVEL: i32 = 63;

/// 48-wide light grid edge (3x3 chunks, same layout as the decorate View:
/// idx = (x*48+z)*256+y). The extracted center 16x16 sits >=16 cells from
/// every grid border; both channels decay >=1 per block from a max of 15,
/// so no path outside the grid can reach the center: border-exact light.
pub const LW48: usize = 48;
pub const LCELLS48: usize = LW48 * LW48 * 256;

const LDIRS48: [6][3]i32 = .{
    .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 },
};

inline fn lpack48(x: usize, y: usize, z: usize) u32 {
    return @intCast((y * LW48 + z) * LW48 + x);
}

inline fn lunpack48(c: u32) struct { x: usize, y: usize, z: usize } {
    const x: usize = c % LW48;
    const t: usize = c / LW48;
    return .{ .x = x, .y = t / LW48, .z = t % LW48 };
}

/// Exact vertical skylight over the 48-wide view (same rule as
/// Chunk.relightColumn: set-then-decay, still water transparent).
fn columnSky48(sky: []u8, blocks48: []const ids.Id) void {
    std.debug.assert(sky.len == LCELLS48 and blocks48.len == LCELLS48);
    for (0..LW48) |lz| {
        for (0..LW48) |lx| {
            var s: u4 = 15;
            var y: i32 = 255;
            while (y >= 0) : (y -= 1) {
                const uy: usize = @intCast(y);
                sky[(lx * LW48 + lz) * 256 + uy] = s;
                const b = blocks48[(lx * LW48 + lz) * 256 + uy];
                const op = chunk_mod.lightOpacity(b);
                if (b != .water and op != 0) {
                    const drop: u4 = if (op > 15) 15 else @truncate(op);
                    s = if (drop >= s) 0 else s - drop;
                }
            }
        }
    }
}

/// Raise-BFS over the 48-wide grid (mirror of Chunk.bfsRaise's exact
/// per-edge contract: sky never spreads FROM opaque cells, min cost 1,
/// strict increases only). Dense: every scratch-grid cell exists.
fn bfsRaise48(arr: []u8, blocks48: []const ids.Id, channel: chunk_mod.Chunk.LightChannel, queue: []u32, head: *usize, tail: *usize) void {
    while (head.* < tail.*) {
        const c = lunpack48(queue[head.*]);
        head.* += 1;
        const ci = (c.x * LW48 + c.z) * 256 + c.y;
        const cur: u4 = @truncate(arr[ci]);
        if (cur == 0) continue;
        if (channel == .sky and chunk_mod.lightOpacity(blocks48[ci]) == 255) continue;
        for (LDIRS48) |d| {
            const nx = @as(i32, @intCast(c.x)) + d[0];
            const ny = @as(i32, @intCast(c.y)) + d[1];
            const nz = @as(i32, @intCast(c.z)) + d[2];
            if (nx < 0 or nx >= LW48 or ny < 0 or ny > 255 or nz < 0 or nz >= LW48) continue;
            const ux: usize = @intCast(nx);
            const uy: usize = @intCast(ny);
            const uz: usize = @intCast(nz);
            const ni = (ux * LW48 + uz) * 256 + uy;
            const op = chunk_mod.lightOpacity(blocks48[ni]);
            const cost: u4 = if (channel == .sky)
                (chunk_mod.Chunk.skyCost(op) orelse continue)
            else
                (chunk_mod.Chunk.blockCost(op) orelse continue);
            if (cur <= cost) continue;
            const nl: u4 = cur - cost;
            if (nl <= arr[ni]) continue;
            arr[ni] = nl;
            if (tail.* < queue.len) {
                queue[tail.*] = lpack48(ux, uy, uz);
                tail.* += 1;
            }
        }
    }
}

/// Full 48-wide gen flood: exact column skylight, sideways sky spread,
/// emissive block flood. Callers extract the center 16x16 (border-exact
/// by the 16-cell margin argument above).
pub fn lightGrid48(blocks48: []const ids.Id, sky48: []u8, light48: []u8, queue: []u32) void {
    std.debug.assert(blocks48.len == LCELLS48 and sky48.len == LCELLS48 and light48.len == LCELLS48);
    std.debug.assert(queue.len >= LCELLS48);
    columnSky48(sky48, blocks48);
    @memset(light48, 0);
    // Sky spread: every bright cell seeds (mirror Chunk.spreadSky's >1 gate;
    // value-1 cells spread nothing since min cost is 1).
    var tail: usize = 0;
    var head: usize = 0;
    for (sky48, 0..) |v, i| {
        if (v > 1) {
            if (tail >= queue.len) break;
            const y: usize = i % 256;
            const t: usize = i / 256;
            queue[tail] = lpack48(t / LW48, y, t % LW48);
            tail += 1;
        }
    }
    bfsRaise48(sky48, blocks48, .sky, queue, &head, &tail);
    // Block flood from emissives (mirror Chunk.relightBlock, dense).
    head = 0;
    tail = 0;
    for (blocks48, 0..) |b, i| {
        const e = chunk_mod.emitLight(b);
        if (e == 0) continue;
        light48[i] = e;
        if (tail >= queue.len) break;
        const y: usize = i % 256;
        const t: usize = i / 256;
        queue[tail] = lpack48(t / LW48, y, t % LW48);
        tail += 1;
    }
    bfsRaise48(light48, blocks48, .block, queue, &head, &tail);
}

/// Vanilla light opacity (`aji.k()`, jar-verified via Opac harness over all
/// 175 block ids). Single table lives in world/chunk.zig (shared with the
/// relight path); this delegates so the two can never drift.
pub fn lightOpacity(id: ids.Id) u8 {
    return chunk_mod.lightOpacity(id);
}

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
    pub const Flat = struct { blocks: *[shaper_mod.BLOCKS_LEN]ids.Id, meta: *[shaper_mod.BLOCKS_LEN]u8 };

    pub fn genFlat(self: *Gen, alloc: std.mem.Allocator, scratch: std.mem.Allocator, cx: i32, cz: i32) !Flat {
        var q: [shaper_mod.Q_LEN]f64 = undefined;
        try self.shaper.densityField(scratch, cx, cz, &q);
        const blocks = try alloc.create([shaper_mod.BLOCKS_LEN]ids.Id);
        errdefer alloc.destroy(blocks);
        @memset(blocks, ids.air);
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
        // Also computes border-exact center light (48-wide flood below).
        var sky_c: [16 * 256 * 16]u8 = undefined;
        var light_c: [16 * 256 * 16]u8 = undefined;
        try self.decorateInto(alloc, scratch, cx, cz, flat.blocks, flat.meta, &sky_c, &light_c);
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
                if (blocks[(lx * 4096 + lz * 256) + (s * 16 + ly)] != ids.air) {
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
            // Border-exact light from the 48-wide gen flood (same vertical
            // rule as relightColumn — leaves 15->14, ice 15->12, opaque
            // 255->0, still water transparent — plus the cross-border
            // sideways spread the old per-chunk flood clamped away).
            for (0..16) |ly| {
                for (0..16) |lz| {
                    for (0..16) |lx| {
                        const si = chunk_mod.Section.index(@intCast(lx), @intCast(ly), @intCast(lz));
                        const cpos = (lx * 16 + lz) * 256 + (s * 16 + ly);
                        chunk_mod.Section.setNibble(&ch.sections[s].?.sky, si, @truncate(sky_c[cpos]));
                        chunk_mod.Section.setNibble(&ch.sections[s].?.light, si, @truncate(light_c[cpos]));
                    }
                }
            }
        }
        // Biomes (voronoi) + heights (topmost light-blocking block, i.e.
        // opacity!=0: flora/snow/glass/lava don't count, water/ice/leaves do).
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
                        if (lightOpacity(blocks[(lx * 4096 + lz * 256) + @as(usize, @intCast(y))]) != 0) {
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
    pub fn surfaceY(blocks: *const [shaper_mod.BLOCKS_LEN]ids.Id, lx: usize, lz: usize) i32 {
        var y: i32 = 255;
        while (y >= 0) : (y -= 1) {
            if (blocks[(lx * 4096 + lz * 256) + @as(usize, @intCast(y))] != 0) return y + 1;
        }
        return SEA_LEVEL + 1;
    }
    fn decorateInto(self: *Gen, alloc: std.mem.Allocator, scratch: std.mem.Allocator, cx: i32, cz: i32, blocks: *[shaper_mod.BLOCKS_LEN]ids.Id, meta: *[shaper_mod.BLOCKS_LEN]u8, out_sky: *[16 * 256 * 16]u8, out_light: *[16 * 256 * 16]u8) !void {
        const VS: usize = 48;
        const vblocks = try scratch.alloc(ids.Id, VS * 256 * VS);
        defer scratch.free(vblocks);
        const vmetas = try scratch.alloc(u8, VS * 256 * VS);
        defer scratch.free(vmetas);
        @memset(vblocks, ids.air);
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
        try decor_mod.decorateCenter(&view, self.world_seed, cx, cz, &self.shaper.chain, self.shaper.roots[1], scratch);
        // Border-exact light over the merged 48x48 view (cross-chunk
        // flood; the old per-chunk flood clamped at borders and seamed).
        // Layout matches View: idx = (x*48+z)*256+y.
        const sky48 = try scratch.alloc(u8, LW48 * LW48 * 256);
        defer scratch.free(sky48);
        const light48 = try scratch.alloc(u8, LW48 * LW48 * 256);
        defer scratch.free(light48);
        const q48 = try scratch.alloc(u32, LW48 * LW48 * 256);
        defer scratch.free(q48);
        lightGrid48(vblocks, sky48, light48, q48);
        // Extract decorated center back into blocks/meta (+ center light).
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
                    const cpos = (lx * 16 + lz) * 256 + y;
                    const gpos = ((lx + 16) * LW48 + (lz + 16)) * 256 + y;
                    out_sky[cpos] = sky48[gpos];
                    out_light[cpos] = light48[gpos];
                }
            }
        }
        // Cross-chunk merge can undercut the snow/ice tail: a later
        // populate's lake carves air below a neighbor's already-placed
        // snow_layer (vanilla runs on one live world, so this never
        // floats). Enforce the tail's own gate post-merge — snow_layer
        // whose support fails `isSoilOpaque` (air, water, lava, leaves)
        // is removed. Mirrors decor's gate exactly (leaves excluded).
        {
            var sx: usize = 0;
            while (sx < 16) : (sx += 1) {
                var sz: usize = 0;
                while (sz < 16) : (sz += 1) {
                    var yy: usize = 1;
                    while (yy < 256) : (yy += 1) {
                        if (blocks[(sx * 4096 + sz * 256) + yy] != ids.snow_layer) continue;
                        const below = blocks[(sx * 4096 + sz * 256) + yy - 1];
                        const solid = below != ids.air and below != ids.leaves and below != ids.leaves2 and below != ids.water and below != ids.flowing_water and below != ids.lava and below != ids.flowing_lava;
                        if (!solid) {
                            blocks[(sx * 4096 + sz * 256) + yy] = ids.air;
                            meta[(sx * 4096 + sz * 256) + yy] = 0;
                        }
                    }
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
        try std.testing.expectEqual(ids.bedrock, s0.blocks[0]);
    }
    {
        const s4 = ch.sections[4].?;
        const dirt = s4.blocks[3 * 256];
        const grass = s4.blocks[4 * 256];
        try std.testing.expectEqual(ids.dirt, dirt);
        try std.testing.expectEqual(ids.grass, grass);
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

test "frozen chunk has no floating snow (seed 42 chunk 3,-5)" {
    // Ice-plains window: the 3x3 merge used to undercut the snow/ice tail
    // (neighbor lake carves below already-placed snow_layer), leaving
    // snow floating over air/water in ponds. The post-merge sweep enforces
    // the tail's own support gate.
    const alloc = std.testing.allocator;
    var gen = try Gen.init(alloc, 42, false, false);
    defer gen.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ch = try gen.genChunk(alloc, arena.allocator(), 3, -5);
    defer ch.destroy(alloc);
    for (0..16) |lx| {
        for (0..16) |lz| {
            var y: usize = 1;
            while (y < 256) : (y += 1) {
                const s = ch.sections[y >> 4] orelse continue;
                if (s.blocks[chunk_mod.Section.index(@intCast(lx), @intCast(y & 15), @intCast(lz))] != ids.snow_layer) continue;
                const below = ch.blockAt(lx, y - 1, lz);
                try std.testing.expect(below != ids.air and below != ids.water and below != ids.flowing_water and below != ids.lava and below != ids.flowing_lava);
            }
        }
    }
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
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, wire.toWire(v)); // JVM goldens are wire ids
    try std.testing.expectEqual(@as(i64, 2364179251614800980), bc);
    var mc: i64 = 0; for (flat.meta.*) |v| mc = mc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 0), mc);
    const samp_idx = [_]usize{0,1024,2048,3072,4096,5120,6144,7168,8192,9216,10240,11264,12288,13312,14336,15360,16384,17408,18432,19456,20480,21504,22528,23552,24576,25600,26624,27648,28672,29696,30720,31744,32768,33792,34816,35840,36864,37888,38912,39936,40960,41984,43008,44032,45056,46080,47104,48128,49152,50176,51200,52224,53248,54272,55296,56320,57344,58368,59392,60416,61440,62464,63488,64512};
    const samp_want = [_]ids.Id{ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock};
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
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, wire.toWire(v)); // JVM goldens are wire ids
    try std.testing.expectEqual(@as(i64, -5565306032280757361), bc);
    var mc: i64 = 0; for (flat.meta.*) |v| mc = mc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 0), mc);
    const samp_idx = [_]usize{0,1024,2048,3072,4096,5120,6144,7168,8192,9216,10240,11264,12288,13312,14336,15360,16384,17408,18432,19456,20480,21504,22528,23552,24576,25600,26624,27648,28672,29696,30720,31744,32768,33792,34816,35840,36864,37888,38912,39936,40960,41984,43008,44032,45056,46080,47104,48128,49152,50176,51200,52224,53248,54272,55296,56320,57344,58368,59392,60416,61440,62464,63488,64512};
    const samp_want = [_]ids.Id{ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock};
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
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, wire.toWire(v)); // JVM goldens are wire ids
    try std.testing.expectEqual(@as(i64, 8615861512796570065), bc);
    var mc: i64 = 0; for (flat.meta.*) |v| mc = mc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 0), mc);
    const samp_idx = [_]usize{0,1024,2048,3072,4096,5120,6144,7168,8192,9216,10240,11264,12288,13312,14336,15360,16384,17408,18432,19456,20480,21504,22528,23552,24576,25600,26624,27648,28672,29696,30720,31744,32768,33792,34816,35840,36864,37888,38912,39936,40960,41984,43008,44032,45056,46080,47104,48128,49152,50176,51200,52224,53248,54272,55296,56320,57344,58368,59392,60416,61440,62464,63488,64512};
    const samp_want = [_]ids.Id{ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock};
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
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, wire.toWire(v)); // JVM goldens are wire ids
    try std.testing.expectEqual(@as(i64, 4935923522670880547), bc);
    var mc: i64 = 0; for (flat.meta.*) |v| mc = mc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 4590157575938082706), mc);
    const samp_idx = [_]usize{0,1024,2048,3072,4096,5120,6144,7168,8192,9216,10240,11264,12288,13312,14336,15360,16384,17408,18432,19456,20480,21504,22528,23552,24576,25600,26624,27648,28672,29696,30720,31744,32768,33792,34816,35840,36864,37888,38912,39936,40960,41984,43008,44032,45056,46080,47104,48128,49152,50176,51200,52224,53248,54272,55296,56320,57344,58368,59392,60416,61440,62464,63488,64512};
    const samp_want = [_]ids.Id{ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock};
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
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, wire.toWire(v)); // JVM goldens are wire ids
    try std.testing.expectEqual(@as(i64, 4287607934416868155), bc);
    var mc: i64 = 0; for (flat.meta.*) |v| mc = mc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 3474580793047174204), mc);
    const samp_idx = [_]usize{0,1024,2048,3072,4096,5120,6144,7168,8192,9216,10240,11264,12288,13312,14336,15360,16384,17408,18432,19456,20480,21504,22528,23552,24576,25600,26624,27648,28672,29696,30720,31744,32768,33792,34816,35840,36864,37888,38912,39936,40960,41984,43008,44032,45056,46080,47104,48128,49152,50176,51200,52224,53248,54272,55296,56320,57344,58368,59392,60416,61440,62464,63488,64512};
    const samp_want = [_]ids.Id{ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock};
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
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, wire.toWire(v)); // JVM goldens are wire ids
    try std.testing.expectEqual(@as(i64, -1906778931135305072), bc);
    var mc: i64 = 0; for (flat.meta.*) |v| mc = mc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 0), mc);
    const samp_idx = [_]usize{0,1024,2048,3072,4096,5120,6144,7168,8192,9216,10240,11264,12288,13312,14336,15360,16384,17408,18432,19456,20480,21504,22528,23552,24576,25600,26624,27648,28672,29696,30720,31744,32768,33792,34816,35840,36864,37888,38912,39936,40960,41984,43008,44032,45056,46080,47104,48128,49152,50176,51200,52224,53248,54272,55296,56320,57344,58368,59392,60416,61440,62464,63488,64512};
    const samp_want = [_]ids.Id{ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock};
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
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, wire.toWire(v)); // JVM goldens are wire ids
    try std.testing.expectEqual(@as(i64, 6731895858531559897), bc);
    var mc: i64 = 0; for (flat.meta.*) |v| mc = mc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 0), mc);
    const samp_idx = [_]usize{0,1024,2048,3072,4096,5120,6144,7168,8192,9216,10240,11264,12288,13312,14336,15360,16384,17408,18432,19456,20480,21504,22528,23552,24576,25600,26624,27648,28672,29696,30720,31744,32768,33792,34816,35840,36864,37888,38912,39936,40960,41984,43008,44032,45056,46080,47104,48128,49152,50176,51200,52224,53248,54272,55296,56320,57344,58368,59392,60416,61440,62464,63488,64512};
    const samp_want = [_]ids.Id{ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock};
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
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, wire.toWire(v)); // JVM goldens are wire ids
    try std.testing.expectEqual(@as(i64, -7603012981142211267), bc);
    var mc: i64 = 0; for (flat.meta.*) |v| mc = mc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 0), mc);
    const samp_idx = [_]usize{0,1024,2048,3072,4096,5120,6144,7168,8192,9216,10240,11264,12288,13312,14336,15360,16384,17408,18432,19456,20480,21504,22528,23552,24576,25600,26624,27648,28672,29696,30720,31744,32768,33792,34816,35840,36864,37888,38912,39936,40960,41984,43008,44032,45056,46080,47104,48128,49152,50176,51200,52224,53248,54272,55296,56320,57344,58368,59392,60416,61440,62464,63488,64512};
    const samp_want = [_]ids.Id{ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock};
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
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, wire.toWire(v)); // JVM goldens are wire ids
    try std.testing.expectEqual(@as(i64, -7906692029262442158), bc);
    var mc: i64 = 0; for (flat.meta.*) |v| mc = mc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 0), mc);
    const samp_idx = [_]usize{0,1024,2048,3072,4096,5120,6144,7168,8192,9216,10240,11264,12288,13312,14336,15360,16384,17408,18432,19456,20480,21504,22528,23552,24576,25600,26624,27648,28672,29696,30720,31744,32768,33792,34816,35840,36864,37888,38912,39936,40960,41984,43008,44032,45056,46080,47104,48128,49152,50176,51200,52224,53248,54272,55296,56320,57344,58368,59392,60416,61440,62464,63488,64512};
    const samp_want = [_]ids.Id{ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock};
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
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, wire.toWire(v)); // JVM goldens are wire ids
    try std.testing.expectEqual(@as(i64, -6949208695922250385), bc);
    var mc: i64 = 0; for (flat.meta.*) |v| mc = mc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 0), mc);
    const samp_idx = [_]usize{0,1024,2048,3072,4096,5120,6144,7168,8192,9216,10240,11264,12288,13312,14336,15360,16384,17408,18432,19456,20480,21504,22528,23552,24576,25600,26624,27648,28672,29696,30720,31744,32768,33792,34816,35840,36864,37888,38912,39936,40960,41984,43008,44032,45056,46080,47104,48128,49152,50176,51200,52224,53248,54272,55296,56320,57344,58368,59392,60416,61440,62464,63488,64512};
    const samp_want = [_]ids.Id{ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock,ids.bedrock};
    const sampm_want = [_]u8{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
    for (samp_idx, 0..) |idx, k| {
        try std.testing.expectEqual(samp_want[k], flat.blocks[idx]);
        try std.testing.expectEqual(sampm_want[k], flat.meta[idx]);
    }
}

test "lightGrid48 flows skylight across chunk borders" {
    // Hill fills x>=16 (center+east), open air to the west; a west-opening
    // tunnel y=64..66 spans the x=16 border. The old per-chunk flood
    // clamped at the border and left the mouth at 0; the 48-wide flood
    // must carry 15 in from the open side with exact per-block decay.
    const alloc = std.testing.allocator;
    const grid = try alloc.alloc(ids.Id, LCELLS48);
    defer alloc.free(grid);
    @memset(grid, ids.air);
    for (16..48) |x| {
        for (0..48) |z| {
            for (0..101) |y| grid[(x * LW48 + z) * 256 + y] = ids.stone;
        }
    }
    for (10..31) |x| {
        for (24..27) |z| {
            for (64..67) |y| grid[(x * LW48 + z) * 256 + y] = ids.air;
        }
    }
    const sky = try alloc.alloc(u8, LCELLS48);
    defer alloc.free(sky);
    const light = try alloc.alloc(u8, LCELLS48);
    defer alloc.free(light);
    const q = try alloc.alloc(u32, LCELLS48);
    defer alloc.free(q);
    lightGrid48(grid, sky, light, q);
    // Mouth cell just inside the hill: 15 - 1 (air cost).
    try std.testing.expectEqual(@as(u8, 14), sky[(16 * LW48 + 24) * 256 + 64]);
    // 14 steps in: 15 - 14 = 1.
    try std.testing.expectEqual(@as(u8, 1), sky[(29 * LW48 + 24) * 256 + 64]);
    // 15 steps of decay: dark.
    try std.testing.expectEqual(@as(u8, 0), sky[(30 * LW48 + 24) * 256 + 64]);
    // Past the tunnel end (solid stone): dark.
    try std.testing.expectEqual(@as(u8, 0), sky[(40 * LW48 + 24) * 256 + 64]);
    // Open air above the hill stays bright; no emitters so no block light.
    try std.testing.expectEqual(@as(u8, 15), sky[(20 * LW48 + 24) * 256 + 200]);
    try std.testing.expectEqual(@as(u8, 0), light[(16 * LW48 + 24) * 256 + 64]);
    // Same terrain through the OLD per-chunk engine stays dark at the
    // mouth (border clamp drops cross-chunk inflow): the regression this
    // flood fixes.
    {
        var solo = try chunk_mod.Chunk.createEmpty(alloc, 0, 0, 0);
        defer solo.destroy(alloc);
        for (0..7) |s| solo.sections[s] = chunk_mod.Section{};
        for (0..16) |lz| {
            for (0..16) |lx| {
                for (0..101) |y| solo.sections[y >> 4].?.blocks[chunk_mod.Section.index(@intCast(lx), @intCast(y & 15), @intCast(lz))] = ids.stone;
                for (64..67) |y| solo.sections[y >> 4].?.blocks[chunk_mod.Section.index(@intCast(lx), @intCast(y & 15), @intCast(lz))] = ids.air;
            }
        }
        for (0..16) |lz| {
            for (0..16) |lx| solo.relightColumn(lx, lz);
        }
        const q2 = try alloc.alloc(u32, 65536);
        defer alloc.free(q2);
        solo.spreadSky(q2);
        try std.testing.expectEqual(@as(u4, 0), chunk_mod.Section.getNibble(&solo.sections[4].?.sky, chunk_mod.Section.index(0, 0, 8)));
    }
}

test "lightGrid48 flows block light across chunk borders" {
    // Open air everywhere; one torch just west of the center window.
    // The old per-chunk flood left the center dark; the 48-wide flood
    // must carry torch light (emit 14) across with exact decay.
    const alloc = std.testing.allocator;
    const grid = try alloc.alloc(ids.Id, LCELLS48);
    defer alloc.free(grid);
    @memset(grid, ids.air);
    grid[(15 * LW48 + 24) * 256 + 64] = ids.torch;
    const sky = try alloc.alloc(u8, LCELLS48);
    defer alloc.free(sky);
    const light = try alloc.alloc(u8, LCELLS48);
    defer alloc.free(light);
    const q = try alloc.alloc(u32, LCELLS48);
    defer alloc.free(q);
    lightGrid48(grid, sky, light, q);
    try std.testing.expectEqual(@as(u8, 13), light[(16 * LW48 + 24) * 256 + 64]);
    try std.testing.expectEqual(@as(u8, 12), light[(17 * LW48 + 24) * 256 + 64]);
    try std.testing.expectEqual(@as(u8, 0), light[(29 * LW48 + 24) * 256 + 64]);
    try std.testing.expectEqual(@as(u8, 14), light[(15 * LW48 + 24) * 256 + 64]);
    try std.testing.expectEqual(@as(u8, 15), sky[(16 * LW48 + 24) * 256 + 64]);
}


