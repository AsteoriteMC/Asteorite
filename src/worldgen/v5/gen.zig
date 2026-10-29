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
// Phase G fill offload (optional per-Gen GPU context, set by GenPool;
// null = CPU fillChunk, the proven reference path).
const gpufill_mod = @import("../../gpu/fill.zig");

pub const SEA_LEVEL: i32 = shaper_mod.SEA_LEVEL;

/// 48-wide light grid edge (3x3 chunks, same layout as the decorate View:
/// idx = (x*48+z)*256+y). The extracted center 16x16 sits >=16 cells from
/// every grid border; both channels decay >=1 per block from a max of 15,
/// so no path outside the grid can reach the center: border-exact light.
pub const LW48: usize = 48;
pub const LCELLS48: usize = LW48 * LW48 * 256;

/// Exact-only light tables (values DERIVED from the canonical switches at
/// comptime, so no drift): hot paths do branch-free loads instead of
/// re-running switches per cell/edge.
const max_lut_id: usize = 342; // ids.Id tops at 341; larger ids use the switch fallback
const op_lut: [max_lut_id]u8 = blk: {
    @setEvalBranchQuota(10000);
    var t: [max_lut_id]u8 = undefined;
    for (0..max_lut_id) |i| t[i] = chunk_mod.lightOpacity(@enumFromInt(@as(u16, @intCast(i))));
    break :blk t;
};
const emit_lut: [max_lut_id]u8 = blk: {
    @setEvalBranchQuota(10000);
    var t: [max_lut_id]u8 = undefined;
    for (0..max_lut_id) |i| t[i] = chunk_mod.emitLight(@enumFromInt(@as(u16, @intCast(i))));
    break :blk t;
};
/// Cost LUTs: 0 = blocked (null), else 1..15. Derived from skyCost/blockCost.
const sky_cost_lut: [256]u8 = blk: {
    @setEvalBranchQuota(10000);
    var t: [256]u8 = undefined;
    for (0..256) |i| t[i] = if (chunk_mod.Chunk.skyCost(@intCast(i))) |c| c else 0;
    break :blk t;
};
const block_cost_lut: [256]u8 = blk: {
    @setEvalBranchQuota(10000);
    var t: [256]u8 = undefined;
    for (0..256) |i| t[i] = if (chunk_mod.Chunk.blockCost(@intCast(i))) |c| c else 0;
    break :blk t;
};
inline fn lutOp(id: ids.Id) u8 {
    const i: usize = @intFromEnum(id);
    return if (i < max_lut_id) op_lut[i] else chunk_mod.lightOpacity(id);
}
inline fn lutEmit(id: ids.Id) u8 {
    const i: usize = @intFromEnum(id);
    return if (i < max_lut_id) emit_lut[i] else chunk_mod.emitLight(id);
}

    /// 6-neighbor offsets: Chunk.light_dirs (one table, no drift).
    const LDIRS48 = chunk_mod.Chunk.light_dirs;

inline fn lpack48(x: usize, y: usize, z: usize) u32 {
    // Bit-pack: 48 < 64 so x/z fit 6 bits, y fits 12. Used only as an
    // inverse pair inside lightGrid48/bfsRaise48 — queue order and the BFS
    // fixed point are unchanged, shifts/masks exact for these ranges.
    return @intCast((y << 12) | (z << 6) | x);
}

inline fn lunpack48(c: u32) struct { x: usize, y: usize, z: usize } {
    return .{ .x = c & 63, .y = c >> 12, .z = (c >> 6) & 63 };
}

/// Exact vertical skylight over the 48-wide view (same rule as
/// Chunk.relightColumn: set-then-decay, still water transparent).
/// Memoizes per-cell opacity into op48 (same values lightOpacity would
/// return) for the BFS passes below — one switch per cell instead of one
/// per neighbor visit (~7M). Bit-identical: op48[i] IS lightOpacity(i).
fn columnSky48(sky: []u8, blocks48: []const ids.Id, op48: []u8) void {
    std.debug.assert(sky.len == LCELLS48 and blocks48.len == LCELLS48 and op48.len == LCELLS48);
    for (0..LW48) |lz| {
        for (0..LW48) |lx| {
            // Column base hoisted out of the y-walk (non-negative, exact).
            const base = (lx * LW48 + lz) * 256;
            var s: u4 = 15;
            var y: i32 = 255;
            while (y >= 0) : (y -= 1) {
                const uy: usize = @intCast(y);
                sky[base + uy] = s;
                const b = blocks48[base + uy];
                const op = lutOp(b);
                op48[base + uy] = op;
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
/// Opacity comes precomputed from columnSky48 (op48), edge costs from the
/// comptime cost LUTs (same null/value contract as skyCost/blockCost), so
/// each edge costs two byte loads instead of switches + arithmetic.
/// Channel is comptime: the sky-only opaque-source gate and the LUT pick
/// vanish instead of branching per cell/edge.
///
/// `logical` mirrors the original queue tail (including filtered seeds):
/// enqueue acceptance uses `logical < queue.len` so capacity/drop behavior
/// is bit-identical to the unfiltered run, while `tail` tracks the physical
/// retained entries. Removed seed visits are proven no-ops (see
/// lightGrid48), so skipping them preserves bytes and even overflow
/// artifacts.
fn bfsRaise48(arr: []u8, op48: []const u8, comptime channel: chunk_mod.Chunk.LightChannel, queue: []u32, head: *usize, tail: *usize, logical: *usize) void {
    // Neighbor deltas for the (x*48+z)*256+y layout, in LDIRS48 order
    // (+x,-x,+y,-y,+z,-z). Bounds are checked per neighbor below, so
    // ci+delta is the identical index (values stay in [0,589824)).
    const DELTAS = [_]i32{ 12288, -12288, 1, -1, 256, -256 };
    const cost_lut = if (channel == .sky) &sky_cost_lut else &block_cost_lut;
    while (head.* < tail.*) {
        const c = lunpack48(queue[head.*]);
        head.* += 1;
        const ci: usize = (c.x * LW48 + c.z) * 256 + c.y;
        const cur: u4 = @truncate(arr[ci]);
        if (cur == 0) continue;
        if (channel == .sky and op48[ci] == 255) continue;
        const cx: i32 = @intCast(c.x);
        const cy: i32 = @intCast(c.y);
        const cz: i32 = @intCast(c.z);
        const cii: i32 = @intCast(ci);
        for (LDIRS48, 0..) |d, k| {
            const nx = cx + d[0];
            const ny = cy + d[1];
            const nz = cz + d[2];
            if (nx < 0 or nx >= LW48 or ny < 0 or ny > 255 or nz < 0 or nz >= LW48) continue;
            const ni: usize = @intCast(cii + DELTAS[k]);
            const cost: u8 = cost_lut[op48[ni]];
            if (cost == 0) continue;
            if (cur <= cost) continue;
            const nl: u4 = cur - @as(u4, @truncate(cost));
            if (nl <= arr[ni]) continue;
            arr[ni] = nl;
            if (logical.* < queue.len) {
                queue[tail.*] = lpack48(@intCast(nx), @intCast(ny), @intCast(nz));
                tail.* += 1;
                logical.* += 1;
            }
        }
    }
}

/// True when a sky seed can never cause an update (provably inert):
/// - opaque source: BFS skips expanding FROM opaque cells, so seeding one
///   performs no neighbor writes (queue occupancy still counted logically).
/// - level-15 with every traversable neighbor already >=14: source caps at
///   15, every edge costs >=1, neighbors only increase, so 15-cost can
///   never beat a >=14 neighbor. Blocked (cost 0) and OOB neighbors are
///   ignored. All other seeds are retained.
inline fn isInertSkySeed(sky48: []const u8, op48: []const u8, lx: usize, y: usize, lz: usize) bool {
    const base = (lx * LW48 + lz) * 256;
    const ci = base + y;
    if (op48[ci] == 255) return true;
    if (sky48[ci] != 15) return false;
    // Six neighbors in (x*48+z)*256+y layout.
    // +x
    if (lx + 1 < LW48) {
        const ni = base + LW48 * 256 + y;
        if (sky_cost_lut[op48[ni]] != 0 and sky48[ni] < 14) return false;
    }
    if (lx > 0) {
        const ni = base - LW48 * 256 + y;
        if (sky_cost_lut[op48[ni]] != 0 and sky48[ni] < 14) return false;
    }
    if (y + 1 < 256) {
        const ni = ci + 1;
        if (sky_cost_lut[op48[ni]] != 0 and sky48[ni] < 14) return false;
    }
    if (y > 0) {
        const ni = ci - 1;
        if (sky_cost_lut[op48[ni]] != 0 and sky48[ni] < 14) return false;
    }
    if (lz + 1 < LW48) {
        const ni = base + 256 + y;
        if (sky_cost_lut[op48[ni]] != 0 and sky48[ni] < 14) return false;
    }
    if (lz > 0) {
        const ni = base - 256 + y;
        if (sky_cost_lut[op48[ni]] != 0 and sky48[ni] < 14) return false;
    }
    return true;
}

/// Full 48-wide gen flood: exact column skylight, sideways sky spread,
/// emissive block flood. Callers extract the center 16x16 (border-exact
/// by the 16-cell margin argument above).
pub fn lightGrid48(blocks48: []const ids.Id, sky48: []u8, light48: []u8, op48: []u8, queue: []u32) void {
    std.debug.assert(blocks48.len == LCELLS48 and sky48.len == LCELLS48 and light48.len == LCELLS48 and op48.len == LCELLS48);
    std.debug.assert(queue.len >= LCELLS48);
    columnSky48(sky48, blocks48, op48);
    @memset(light48, 0);
    // Sky spread: every bright cell seeds (mirror Chunk.spreadSky's >1 gate;
    // value-1 cells spread nothing since min cost is 1). Nested x/z/y
    // loops visit cells in the same linear order as the flat scan (y
    // fastest) with no division per cell.
    // Inert-seed filter with logical capacity accounting: opaque sources
    // and level-15-already-saturated cells are proven no-ops (see
    // isInertSkySeed). `logical` counts every seed the original code
    // enqueues (including omitted) so later enqueue-accept/drop decisions
    // match the reference exactly; only retained seeds occupy the physical
    // queue, preserving order.
    var tail: usize = 0;
    var head: usize = 0;
    var logical: usize = 0;
    for (0..LW48) |lx| {
        for (0..LW48) |lz| {
            const base = (lx * LW48 + lz) * 256;
            for (0..256) |y| {
                if (sky48[base + y] > 1) {
                    if (logical >= queue.len) break;
                    logical += 1;
                    if (isInertSkySeed(sky48, op48, lx, y, lz)) continue;
                    queue[tail] = lpack48(lx, y, lz);
                    tail += 1;
                }
            }
        }
    }
    bfsRaise48(sky48, op48, .sky, queue, &head, &tail, &logical);
    // Block flood from emissives (mirror Chunk.relightBlock, dense).
    head = 0;
    tail = 0;
    logical = 0;
    for (0..LW48) |lx| {
        for (0..LW48) |lz| {
            const base = (lx * LW48 + lz) * 256;
            for (0..256) |y| {
                const e: u8 = lutEmit(blocks48[base + y]);
                if (e == 0) continue;
                light48[base + y] = e;
                if (logical >= queue.len) break;
                queue[tail] = lpack48(lx, y, lz);
                tail += 1;
                logical += 1;
            }
        }
    }
    bfsRaise48(light48, op48, .block, queue, &head, &tail, &logical);
}

/// Shared post-carve column cache (Phase H1): memoizes genFlat output
/// (blocks+meta) keyed by chunk coords. Generation is a pure function of
/// (world_seed, cx, cz) — every stage reseeds from (seed, xz) at entry and
/// workers never share mutable RNG — while player edits bypass gen via
/// direct store puts, so cached columns can never go stale and hits are
/// byte-identical to regen by construction. No invalidation needed.
/// FIFO ring eviction (each column feeds up to 9 consecutive chunks, so
/// recency approximates use); LRU is a follow-up if hit rates disappoint.
pub const ColumnCache = struct {
    const Slot = struct {
        key: u64 = 0,
        valid: bool = false,
        blocks: *[shaper_mod.BLOCKS_LEN]ids.Id,
        meta: *[shaper_mod.BLOCKS_LEN]u8,
    };

    io: std.Io,
    alloc: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    slots: []Slot,
    map: std.AutoHashMap(u64, usize),
    cursor: usize = 0, // next FIFO eviction slot
    hits: u64 = 0,
    misses: u64 = 0,
    /// Duplicate misses: concurrent misses for the same key while another
    /// worker is generating it (measurement for single-flight sizing).
    dup_misses: u64 = 0,
    /// Single-flight waits (second requester awaited the producer and hit).
    single_flight_hits: u64 = 0,
    /// Keys currently being generated (producer set). Waiters block on
    /// `cond` until the producer puts + unclaims.
    inflight_gen: std.AutoHashMap(u64, void) = undefined,
    inflight_init: bool = false,
    /// Master switch for single-flight waiting (true = await producer and
    /// reuse its bytes; false = generate redundantly but still count dups).
    single_flight: bool = true,

    pub fn keyOf(cx: i32, cz: i32) u64 {
        return (@as(u64, @bitCast(@as(i64, cx))) << 32) | @as(u64, @intCast(@as(u32, @bitCast(cz))));
    }

    pub fn init(alloc: std.mem.Allocator, io: std.Io, cap: usize) !ColumnCache {
        var slots = try alloc.alloc(Slot, cap);
        errdefer alloc.free(slots);
        var used: usize = 0;
        errdefer {
            for (slots[0..used]) |*s| {
                alloc.destroy(s.blocks);
                alloc.destroy(s.meta);
            }
        }
        for (slots) |*s| {
            s.* = .{
                .blocks = try alloc.create([shaper_mod.BLOCKS_LEN]ids.Id),
                .meta = try alloc.create([shaper_mod.BLOCKS_LEN]u8),
            };
            used += 1;
        }
        return .{
            .io = io,
            .alloc = alloc,
            .slots = slots,
            .map = std.AutoHashMap(u64, usize).init(alloc),
            .inflight_gen = std.AutoHashMap(u64, void).init(alloc),
            .inflight_init = true,
        };
    }

    pub fn deinit(self: *ColumnCache) void {
        for (self.slots) |*s| {
            self.alloc.destroy(s.blocks);
            self.alloc.destroy(s.meta);
        }
        self.alloc.free(self.slots);
        self.map.deinit();
        if (self.inflight_init) self.inflight_gen.deinit();
    }

    /// Copy the cached column into caller buffers. True on hit.
    pub fn get(self: *ColumnCache, cx: i32, cz: i32, out_blocks: *[shaper_mod.BLOCKS_LEN]ids.Id, out_meta: *[shaper_mod.BLOCKS_LEN]u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const k = keyOf(cx, cz);
        const si = self.map.get(k) orelse {
            self.misses += 1;
            return false;
        };
        const s = &self.slots[si];
        if (!s.valid or s.key != k) {
            self.misses += 1;
            return false;
        }
        @memcpy(out_blocks, s.blocks);
        @memcpy(out_meta, s.meta);
        self.hits += 1;
        return true;
    }

    /// Try to claim `key` for generation. True = caller is the producer.
    /// False = another worker is already generating it (dup_misses++).
    /// Lock-held, brief.
    pub fn tryClaimGen(self: *ColumnCache, cx: i32, cz: i32) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const k = keyOf(cx, cz);
        if (!self.inflight_init) return true;
        if (self.inflight_gen.contains(k)) {
            self.dup_misses += 1;
            return false;
        }
        self.inflight_gen.put(k, {}) catch return true;
        return true;
    }

    /// Block until the in-progress generation for `key` finishes (producer
    /// unclaims + broadcasts). Caller must then retry get() (expected hit).
    /// No-op when single-flight is disabled.
    pub fn waitForGen(self: *ColumnCache, cx: i32, cz: i32) void {
        const k = keyOf(cx, cz);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.inflight_init) return;
        while (self.inflight_gen.contains(k)) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
    }

    /// Release a generation claim and wake waiters. Lock-held, brief.
    pub fn unclaimGen(self: *ColumnCache, cx: i32, cz: i32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.inflight_init) return;
        const k = keyOf(cx, cz);
        _ = self.inflight_gen.remove(k);
        self.cond.broadcast(self.io);
    }

    /// Note a waiter that hit after awaiting the producer (telemetry).
    pub fn noteSingleFlightHit(self: *ColumnCache) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.single_flight_hits += 1;
    }

    /// Store a copy (evicts the oldest FIFO slot on pressure; a duplicate
    /// key refreshes in place — racing gens produce identical bytes).
    pub fn put(self: *ColumnCache, cx: i32, cz: i32, blocks: *const [shaper_mod.BLOCKS_LEN]ids.Id, meta: *const [shaper_mod.BLOCKS_LEN]u8) void {
        if (self.slots.len == 0) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const k = keyOf(cx, cz);
        if (self.map.get(k)) |si| {
            @memcpy(self.slots[si].blocks, blocks);
            @memcpy(self.slots[si].meta, meta);
            return;
        }
        const si = self.cursor;
        self.cursor += 1;
        if (self.cursor >= self.slots.len) self.cursor = 0;
        const s = &self.slots[si];
        if (s.valid) _ = self.map.remove(s.key);
        s.key = k;
        s.valid = true;
        @memcpy(s.blocks, blocks);
        @memcpy(s.meta, meta);
        self.map.put(k, si) catch {};
    }

    pub const Snapshot = struct { hits: u64, misses: u64, dup_misses: u64 = 0, single_flight_hits: u64 = 0 };

    pub fn snapshot(self: *ColumnCache) Snapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .hits = self.hits, .misses = self.misses, .dup_misses = self.dup_misses, .single_flight_hits = self.single_flight_hits };
    }
};

/// Shared column-cache slots (192 KiB each → 24 MiB at the default).
pub const column_cache_cap: usize = 128;

pub const Gen = struct {
    shaper: shaper_mod.Shaper,
    carver: carve_mod.Carver,
    world_seed: i64,
    /// Optional GPU fill offload (Phase G: synchronous dispatch on GenPool
    /// worker threads, CPU fallback on any failure). Null keeps the CPU
    /// reference path; set by GenPool.create (workers) and main (boot
    /// pregen Gen) when --gpu vulkan is active. Non-null routes genChunk
    /// through the v2 batched fill (one dispatch per chunk's 9 columns).
    gpu: ?*gpufill_mod.GpuFill = null,
    /// Effective per-dispatch chunk cap for the batched fill (clamped
    /// 1..16 at wiring time from gpu_max_batch; 9 columns per chunk fit in
    /// one dispatch at the default). Ignored when gpu is null.
    gpu_batch: usize = 16,
    /// Shared post-carve column cache (Phase H1, wired by GenPool;
    /// null = standalone reference path). Pure-function memo: hits are
    /// byte-identical to regen by construction (see ColumnCache).
    cache: ?*ColumnCache = null,
    /// Shared ore-geometry cache (wired by GenPool; null = reference path):
    /// ellipsoid segment recipes keyed by entry RNG state + coords.
    /// Brief mutex inside; replay lock-free via copy-out. Byte-identical.
    ore_cache: ?*decor_mod.OreCache = null,

    pub fn init(alloc: std.mem.Allocator, world_seed: i64, large_biomes: bool, amplified: bool) !Gen {
        var gen = Gen{
            .shaper = try shaper_mod.Shaper.init(alloc, world_seed, large_biomes, amplified),
            .carver = undefined,
            .world_seed = world_seed,
        };
        errdefer gen.shaper.deinit();
        gen.carver = carve_mod.Carver.init(alloc, gen.shaper.chain, gen.shaper.roots[1]);
        return gen;
    }

    pub fn deinit(self: *Gen) void {
        self.shaper.deinit();
    }

    /// Full terrain pipeline into flat vanilla-layout arrays (test seam).
    /// Returned buffers are heap-owned; caller destroys both.
    pub const Flat = struct { blocks: *[shaper_mod.BLOCKS_LEN]ids.Id, meta: *[shaper_mod.BLOCKS_LEN]u8 };

    /// Full terrain pipeline into caller buffers (the old genFlat body).
    /// Shared by genFlat (heap wrapper below) and flatFor (cache-aware).
    pub fn genFlatInto(self: *Gen, scratch: std.mem.Allocator, cx: i32, cz: i32, blocks: *[shaper_mod.BLOCKS_LEN]ids.Id, meta: *[shaper_mod.BLOCKS_LEN]u8) !void {
        var q: [shaper_mod.Q_LEN]f64 = undefined;
        try self.shaper.densityField(scratch, cx, cz, &q);
        // No blocks memset: fillChunk memsets + writes every cell below
        // (CPU) / full-buffer GPU fill (probe-gated identical).
        // Phase G: GPU fill offload when a context is attached (GenPool
        // workers + boot pregen Gen under --gpu vulkan). Single-chunk
        // path; the 9-column batch lives in genChunkBatched. fill()
        // returns false on any GPU problem; the CPU reference path then
        // runs — bit-identical either way (probe-gated on JVM goldens).
        if (self.gpu) |g| {
            if (!g.fill(&q, blocks, shaper_mod.SEA_LEVEL, @intFromEnum(ids.stone), @intFromEnum(ids.water), @intFromEnum(ids.air))) {
                shaper_mod.Shaper.fillChunk(&q, blocks);
            }
        } else {
            shaper_mod.Shaper.fillChunk(&q, blocks);
        }
        @memset(meta, 0);
        try self.shaper.surfaceChunk(scratch, cx, cz, blocks, meta);
        // Cave + ravine carvers (in place on the same arrays).
        try self.carver.carveChunk(scratch, cx, cz, self.world_seed, blocks);
    }

    /// Full terrain pipeline into heap-owned flat vanilla-layout arrays.
    /// Returned buffers are heap-owned; caller destroys both.
    pub fn genFlat(self: *Gen, alloc: std.mem.Allocator, scratch: std.mem.Allocator, cx: i32, cz: i32) !Flat {
        const blocks = try alloc.create([shaper_mod.BLOCKS_LEN]ids.Id);
        errdefer alloc.destroy(blocks);
        const meta = try alloc.create([shaper_mod.BLOCKS_LEN]u8);
        errdefer alloc.destroy(meta);
        try self.genFlatInto(scratch, cx, cz, blocks, meta);
        return .{ .blocks = blocks, .meta = meta };
    }

    /// Cache-aware column fetch (Phase H1): a hit copies from the shared
    /// cache, a miss generates in place and stores a copy. Null cache =
    /// plain genFlatInto. Hits skip density/fill/surface/carve entirely.
    /// Single-flight: concurrent misses for the same key collapse to one
    /// producer; waiters await it and reuse its bytes (identical by
    /// construction). Duplicate-miss telemetry spots contention.
    pub fn flatFor(self: *Gen, scratch: std.mem.Allocator, cx: i32, cz: i32, blocks: *[shaper_mod.BLOCKS_LEN]ids.Id, meta: *[shaper_mod.BLOCKS_LEN]u8) !void {
        if (self.cache) |c| {
            if (c.get(cx, cz, blocks, meta)) return;
            if (c.single_flight) {
                if (!c.tryClaimGen(cx, cz)) {
                    // Another worker is generating this exact column:
                    // await it, then reuse (expected hit). Falls through
                    // to regen only if the producer failed to store.
                    c.waitForGen(cx, cz);
                    if (c.get(cx, cz, blocks, meta)) {
                        c.noteSingleFlightHit();
                        return;
                    }
                    // Producer missed without storing (should not happen);
                    // claim and generate below.
                    if (!c.tryClaimGen(cx, cz)) {
                        // Lost the race twice: generate redundantly (still
                        // correct; puts are idempotent, last-wins).
                        try self.genFlatInto(scratch, cx, cz, blocks, meta);
                        c.put(cx, cz, blocks, meta);
                        return;
                    }
                }
                defer c.unclaimGen(cx, cz);
                try self.genFlatInto(scratch, cx, cz, blocks, meta);
                c.put(cx, cz, blocks, meta);
                return;
            }
        }
        try self.genFlatInto(scratch, cx, cz, blocks, meta);
        if (self.cache) |c| c.put(cx, cz, blocks, meta);
    }

    /// Generate chunk (cx,cz) into a heap Chunk. Caller destroys.
    /// scratch is a caller-owned arena reused across calls (pool workers
    /// retain one per thread; tests/tools use a per-call arena) — temp
    /// column/view/light buffers live there; alloc backs only the
    /// returned Chunk (and genFlat's escaping Flat, never scratch).
    /// Decorators (ores/trees) run on a 3x3 shaped view (terrain+carve for
    /// neighbors + center), then the center is extracted. Center + neighbor
    /// columns come from the shared column cache when wired (Phase H1);
    /// steady state regenerates ~1 column per chunk instead of 9.
    pub fn genChunk(self: *Gen, alloc: std.mem.Allocator, scratch: std.mem.Allocator, cx: i32, cz: i32) !*chunk_mod.Chunk {
        // GPU attached: one batched fill dispatch for all 9 columns
        // instead of 9 synchronous N=1 fills (same bytes, see
        // genChunkBatched). Null GPU keeps the sequential path below.
        if (self.gpu != null) return try self.genChunkBatched(alloc, scratch, cx, cz);
        // Scratch-owned (freed by the arena owner): never alloc, which may
        // be a contended thread-safe GPA on the pool path.
        const cblocks = try scratch.create([shaper_mod.BLOCKS_LEN]ids.Id);
        const cmeta = try scratch.create([shaper_mod.BLOCKS_LEN]u8);
        try self.flatFor(scratch, cx, cz, cblocks, cmeta);
        const flat = .{ .blocks = cblocks, .meta = cmeta };
        // 3x3 decorate: neighbors + center terrain into a 48x48 view.
        // Also computes border-exact center light (48-wide flood below).
        var sky_c: [16 * 256 * 16]u8 = undefined;
        var light_c: [16 * 256 * 16]u8 = undefined;
        try self.decorateInto(scratch, cx, cz, flat.blocks, flat.meta, &sky_c, &light_c);
        return try self.finishChunk(alloc, scratch, cx, cz, flat.blocks, flat.meta, &sky_c, &light_c);
    }

    /// Pack flat center arrays (+ light) into the heap Chunk: sections,
    /// biomes (voronoi), heights. Shared by genChunk/genChunkBatched.
    fn finishChunk(self: *Gen, alloc: std.mem.Allocator, scratch: std.mem.Allocator, cx: i32, cz: i32, blocks: *[shaper_mod.BLOCKS_LEN]ids.Id, meta_fixed: *[shaper_mod.BLOCKS_LEN]u8, sky_c: *[16 * 256 * 16]u8, light_c: *[16 * 256 * 16]u8) !*chunk_mod.Chunk {
        const ch = try chunk_mod.Chunk.createEmpty(alloc, 0, cx, cz);
        errdefer ch.destroy(alloc);
        for (0..16) |s| {
            if (!sectionOccupied(blocks, s)) continue;
            var sec = packSection(blocks, meta_fixed, s);
            // Border-exact light from the 48-wide gen flood (same vertical
            // rule as relightColumn — leaves 15->14, ice 15->12, opaque
            // 255->0, still water transparent — plus the cross-border
            // sideways spread the old per-chunk flood clamped away).
            // lz/lx outer hoists the light-column base; ly innermost walks
            // stride-1. Each nibble is written exactly once, so visit order
            // is unobservable (nibble-pair RMWs commute to the same byte).
            const s16: usize = s * 16;
            for (0..16) |lz| {
                for (0..16) |lx| {
                    const ccol: usize = (lx * 16 + lz) * 256 + s16;
                    for (0..16) |ly| {
                        const si = chunk_mod.Section.index(@intCast(lx), @intCast(ly), @intCast(lz));
                        chunk_mod.Section.setNibble(&sec.sky, si, @truncate(sky_c[ccol + ly]));
                        chunk_mod.Section.setNibble(&sec.light, si, @truncate(light_c[ccol + ly]));
                    }
                }
            }
            ch.sections[s] = sec;
        }
        // Biomes (voronoi) + heights (topmost light-blocking block, i.e.
        // opacity!=0: flora/snow/glass/lava don't count, water/ice/leaves do).
        {
            const bio = try scratch.alloc(i32, 256);
            defer scratch.free(bio);
            // Chunk biome array (F3 + foliage colors): vanilla
            // loadBlockGeneratorData runs on the full-res genBiomes layer.
            try self.shaper.chain.getInts(scratch, self.shaper.roots[0], cx * 16, cz * 16, 16, 16, bio);
            for (bio, 0..) |id, k| ch.biomes[k] = @truncate(@as(u32, @bitCast(id)));
            for (0..16) |lz| {
                for (0..16) |lx| {
                    // Column base hoisted out of the top-down scan.
                    const col = (lx * 4096 + lz * 256);
                    var top: u8 = 0;
                    var y: i32 = 255;
                    while (y >= 0) : (y -= 1) {
                        if (chunk_mod.lightOpacity(blocks[col + @as(usize, @intCast(y))]) != 0) {
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
        const col = (lx * 4096 + lz * 256);
        var y: i32 = 255;
        while (y >= 0) : (y -= 1) {
            if (blocks[col + @as(usize, @intCast(y))] != ids.air) return y + 1;
        }
        return SEA_LEVEL + 1;
    }
    /// True when section `s` holds any non-air block.
    fn sectionOccupied(blocks: *[shaper_mod.BLOCKS_LEN]ids.Id, s: usize) bool {
        const s16 = s * 16;
        for (0..16) |lz| {
            for (0..16) |lx| {
                const col = (lx * 4096 + lz * 256) + s16;
                for (0..16) |ly| {
                    if (blocks[col + ly] != ids.air) return true;
                }
            }
        }
        return false;
    }

    /// Pack section `s` (blocks + meta nibbles; light filled by the caller).
    /// lz/lx outer hoists the source column; each (si, vpos) pair is
    /// written once, so the visit order is unobservable.
    fn packSection(blocks: *[shaper_mod.BLOCKS_LEN]ids.Id, meta: *[shaper_mod.BLOCKS_LEN]u8, s: usize) chunk_mod.Section {
        var sec = chunk_mod.Section{};
        const s16 = s * 16;
        for (0..16) |lz| {
            for (0..16) |lx| {
                const vcol = (lx * 4096 + lz * 256) + s16;
                for (0..16) |ly| {
                    const vpos = vcol + ly;
                    const si = chunk_mod.Section.index(@intCast(lx), @intCast(ly), @intCast(lz));
                    sec.blocks[si] = blocks[vpos];
                    const mv: u4 = @truncate(meta[vpos]);
                    chunk_mod.Section.setNibble(&sec.meta, si, mv);
                }
            }
        }
        return sec;
    }

    /// Copy one 16x256x16 chunk into the 48-wide view at cell (ox, oz)
    /// (view offset ox*16, oz*16). Shared by the center + 8 neighbors.
    /// The y-column is stride-1 contiguous on both sides, so each column
    /// copies as one 256-slice memcpy (identical bytes).
    fn blitIntoView(vblocks: []ids.Id, vmetas: []u8, ox: usize, oz: usize, nblocks: *const [shaper_mod.BLOCKS_LEN]ids.Id, nmeta: *const [shaper_mod.BLOCKS_LEN]u8) void {
        const VS: usize = 48;
        const vx = ox * 16;
        const vz = oz * 16;
        for (0..16) |lx| {
            for (0..16) |lz| {
                const src = (lx * 4096 + lz * 256);
                const dst = ((lx + vx) * VS + (lz + vz)) * 256;
                @memcpy(vblocks[dst..][0..256], nblocks[src..][0..256]);
                @memcpy(vmetas[dst..][0..256], nmeta[src..][0..256]);
            }
        }
    }

    /// Copy the decorated 48-wide center back into chunk arrays (+ light).
    /// Same contiguous-column memcpy (identical bytes, incl. nibbles below
    /// — light is copied separately per nibble in finishChunk).
    fn blitFromView(blocks: *[shaper_mod.BLOCKS_LEN]ids.Id, meta: *[shaper_mod.BLOCKS_LEN]u8, out_sky: *[16 * 256 * 16]u8, out_light: *[16 * 256 * 16]u8, vblocks: []const ids.Id, vmetas: []const u8, sky48: []const u8, light48: []const u8) void {
        const VS: usize = 48;
        const LW: usize = 48;
        for (0..16) |lx| {
            for (0..16) |lz| {
                const dst = (lx * 4096 + lz * 256);
                const src = ((lx + 16) * VS + (lz + 16)) * 256;
                @memcpy(blocks[dst..][0..256], vblocks[src..][0..256]);
                @memcpy(meta[dst..][0..256], vmetas[src..][0..256]);
                const cpos = (lx * 16 + lz) * 256;
                const gpos = ((lx + 16) * LW + (lz + 16)) * 256;
                @memcpy(out_sky[cpos..][0..256], sky48[gpos..][0..256]);
                @memcpy(out_light[cpos..][0..256], light48[gpos..][0..256]);
            }
        }
    }

    /// Post-merge snow sweep (see the call site: neighbor lakes can carve
    /// air below already-placed snow_layer).
    fn sweepSnow(blocks: *[shaper_mod.BLOCKS_LEN]ids.Id, meta: *[shaper_mod.BLOCKS_LEN]u8) void {
        for (0..16) |sx| {
            for (0..16) |sz| {
                const col = (sx * 4096 + sz * 256);
                var yy: usize = 1;
                while (yy < 256) : (yy += 1) {
                    if (blocks[col + yy] != ids.snow_layer) continue;
                    const below = blocks[col + yy - 1];
                    const bmeta: u8 = meta[col + yy - 1];
                    if (!decor_mod.snowSupport(below, bmeta)) {
                        blocks[col + yy] = ids.air;
                        meta[col + yy] = 0;
                    }
                }
            }
        }
    }

    /// Batched genChunk: same 9 columns (center + 8 neighbors) as
    /// genChunk, but density for cache MISSES first, then ONE batched GPU
    /// fill dispatch over the misses (split to the `gpu_batch` cap when
    /// smaller), then surface + carve per miss and cache store. Per-column
    /// op order matches genFlat exactly, so the bytes are identical to the
    /// sequential path; without a GPU (or on batch failure) every miss
    /// column CPU-fills like genFlat. Hits skip the whole pipeline.
    pub fn genChunkBatched(self: *Gen, alloc: std.mem.Allocator, scratch: std.mem.Allocator, cx: i32, cz: i32) !*chunk_mod.Chunk {
        const offs = [_][2]i32{
            .{ 0, 0 }, .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 },
            .{ -1, 0 }, .{ 1, 0 }, .{ -1, 1 }, .{ 0, 1 }, .{ 1, 1 },
        };
        var qs: [9][]f64 = undefined;
        var blk: [9]*[shaper_mod.BLOCKS_LEN]ids.Id = undefined;
        var met: [9]*[shaper_mod.BLOCKS_LEN]u8 = undefined;
        // Scratch-owned column bufs (freed by the arena owner; no errdefer
        // needed — nothing here escapes into the returned Chunk).
        var miss_idx: [9]usize = undefined;
        var nmiss: usize = 0;
        for (offs, 0..) |o, i| {
            blk[i] = try scratch.create([shaper_mod.BLOCKS_LEN]ids.Id);
            met[i] = try scratch.create([shaper_mod.BLOCKS_LEN]u8);
            // No memsets: hits fully memcpy; misses are fully written by
            // density+fill+surface+carve below before any read.
            if (self.cache) |c| {
                if (c.get(cx + o[0], cz + o[1], blk[i], met[i])) continue;
            }
            qs[i] = try scratch.alloc(f64, shaper_mod.Q_LEN);
            try self.shaper.densityField(scratch, cx + o[0], cz + o[1], qs[i][0..shaper_mod.Q_LEN]);
            miss_idx[nmiss] = i;
            nmiss += 1;
        }
        // Fill: batched GPU dispatch in cap-sized groups, else per-column
        // CPU. A failed group CPU-fills just its own columns (earlier
        // groups already wrote correct outputs). Operates on the miss
        // list only; nmiss <= 9 <= cap, so one group.
        var mqs: [9][]const f64 = undefined;
        var mblk: [9]*[shaper_mod.BLOCKS_LEN]ids.Id = undefined;
        for (miss_idx[0..nmiss], 0..) |mi, k| {
            mqs[k] = qs[mi];
            mblk[k] = blk[mi];
        }
        if (self.gpu) |g| {
            // Floor at 9 (one game chunk = one dispatch; see wiring).
            const cap = @min(@max(self.gpu_batch, 9), gpufill_mod.batch_cap);
            var qi: usize = 0;
            while (qi < nmiss) {
                const m = @min(cap, nmiss - qi);
                var qsl: [gpufill_mod.batch_cap][]const f64 = undefined;
                var osl: [gpufill_mod.batch_cap][]ids.Id = undefined;
                for (0..m) |k| {
                    qsl[k] = mqs[qi + k];
                    osl[k] = mblk[qi + k];
                }
                if (!g.fillBatch(qsl[0..m], osl[0..m], shaper_mod.SEA_LEVEL, @intFromEnum(ids.stone), @intFromEnum(ids.water), @intFromEnum(ids.air))) {
                    for (qi..(qi + m)) |j| shaper_mod.Shaper.fillChunk(mqs[j][0..shaper_mod.Q_LEN], mblk[j]);
                }
                qi += m;
            }
        } else {
            for (miss_idx[0..nmiss]) |mi| shaper_mod.Shaper.fillChunk(qs[mi][0..shaper_mod.Q_LEN], blk[mi]);
        }
        for (miss_idx[0..nmiss]) |mi| {
            const o = offs[mi];
            try self.shaper.surfaceChunk(scratch, cx + o[0], cz + o[1], blk[mi], met[mi]);
            try self.carver.carveChunk(scratch, cx + o[0], cz + o[1], self.world_seed, blk[mi]);
            if (self.cache) |c| c.put(cx + o[0], cz + o[1], blk[mi], met[mi]);
        }
        // Blit center + neighbors into the 48-wide view (same layout as
        // decorateInto), then the shared finish path.
        const VS: usize = 48;
        const vblocks = try scratch.alloc(ids.Id, VS * 256 * VS);
        defer scratch.free(vblocks);
        const vmetas = try scratch.alloc(u8, VS * 256 * VS);
        defer scratch.free(vmetas);
        // No air/zero memset: the 9 blits below tile 48x48 exactly (every
        // cell memcpy'd before any read in decorateCenter/light).
        // Center first so neighbors overwrite their own regions below.
        blitIntoView(vblocks, vmetas, 1, 1, blk[0], met[0]);
        for (offs[1..], 1..) |o, i| {
            blitIntoView(vblocks, vmetas, @intCast(o[0] + 1), @intCast(o[1] + 1), blk[i], met[i]);
        }
        var sky_c: [16 * 256 * 16]u8 = undefined;
        var light_c: [16 * 256 * 16]u8 = undefined;
        try self.finishView(scratch, cx, cz, vblocks, vmetas, blk[0], met[0], &sky_c, &light_c);
        const ch = try self.finishChunk(alloc, scratch, cx, cz, blk[0], met[0], &sky_c, &light_c);
        // finishChunk copies out of the center arrays (nothing aliases
        // them); scratch bufs free with the arena, no per-buf destroy.
        return ch;
    }

    fn decorateInto(self: *Gen, scratch: std.mem.Allocator, cx: i32, cz: i32, blocks: *[shaper_mod.BLOCKS_LEN]ids.Id, meta: *[shaper_mod.BLOCKS_LEN]u8, out_sky: *[16 * 256 * 16]u8, out_light: *[16 * 256 * 16]u8) !void {
        const VS: usize = 48;
        const vblocks = try scratch.alloc(ids.Id, VS * 256 * VS);
        defer scratch.free(vblocks);
        const vmetas = try scratch.alloc(u8, VS * 256 * VS);
        defer scratch.free(vmetas);
        // No air/zero memset: center + 8 neighbor blits tile 48x48
        // exactly (same argument as genChunkBatched above).
        // Copy center first (then neighbors overwrite their regions).
        // Layout: view (x,z) with ox=(cx-1)*16. Local lx in 0..48.
        // Center chunk occupies lx 16..31, lz 16..31.
        blitIntoView(vblocks, vmetas, 1, 1, blocks, meta);
        // Neighbors (8 surrounding chunks). One reusable scratch pair for
        // all 8 (sequential): flatFor copies cache hits, generates +
        // stores misses, then each column blits into its view region.
        const nblocks = try scratch.create([shaper_mod.BLOCKS_LEN]ids.Id);
        const nmetas = try scratch.create([shaper_mod.BLOCKS_LEN]u8);
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                if (dx == 0 and dz == 0) continue;
                try self.flatFor(scratch, cx + dx, cz + dz, nblocks, nmetas);
                blitIntoView(vblocks, vmetas, @intCast(dx + 1), @intCast(dz + 1), nblocks, nmetas);
            }
        }
        try self.finishView(scratch, cx, cz, vblocks, vmetas, blocks, meta, out_sky, out_light);
    }

    /// Decorate + light + extract the merged 48-wide view into the center
    /// arrays. Shared by decorateInto (sequential neighbors) and
    /// genChunkBatched (hoisted batched neighbors).
    fn finishView(self: *Gen, scratch: std.mem.Allocator, cx: i32, cz: i32, vblocks: []ids.Id, vmetas: []u8, blocks: *[shaper_mod.BLOCKS_LEN]ids.Id, meta: *[shaper_mod.BLOCKS_LEN]u8, out_sky: *[16 * 256 * 16]u8, out_light: *[16 * 256 * 16]u8) !void {
        const VS: usize = 48;
        var view = decor_mod.View{
            .blocks = vblocks,
            .metas = vmetas,
            .ox = (cx - 1) * 16,
            .oz = (cz - 1) * 16,
            .sx = VS,
            .sz = VS,
            .ore_cache = self.ore_cache,
        };
        try decor_mod.decorateCenter(&view, self.world_seed, cx, cz, &self.shaper.chain, self.shaper.roots[0], scratch);
        // Border-exact light over the merged 48x48 view (cross-chunk
        // flood; the old per-chunk flood clamped at borders and seamed).
        // Layout matches View: idx = (x*48+z)*256+y.
        const sky48 = try scratch.alloc(u8, LW48 * LW48 * 256);
        defer scratch.free(sky48);
        const light48 = try scratch.alloc(u8, LW48 * LW48 * 256);
        defer scratch.free(light48);
        const q48 = try scratch.alloc(u32, LW48 * LW48 * 256);
        defer scratch.free(q48);
        const op48 = try scratch.alloc(u8, LCELLS48);
        defer scratch.free(op48);
        lightGrid48(vblocks, sky48, light48, op48, q48);
        // Extract decorated center back into blocks/meta (+ center light).
        blitFromView(blocks, meta, out_sky, out_light, vblocks, vmetas, sky48, light48);
        // Cross-chunk merge can undercut the snow/ice tail: a later
        // populate's lake carves air below a neighbor's already-placed
        // snow_layer (vanilla runs on one live world, so this never
        // floats). Enforce the tail's own gate post-merge via
        // decor.snowSupport (leaves/full snow hold; ice, fluids,
        // vegetation never do).
        sweepSnow(blocks, meta);
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
    // Chunk biome array follows full-res genBiomes (vanilla
    // loadBlockGeneratorData), not voronoi: taiga(5) with a
    // taiga-hills(19) corner intruding at the south edge.
    {
        var n5: usize = 0;
        var n19: usize = 0;
        for (ch.biomes) |b| {
            if (b == 5) n5 += 1;
            if (b == 19) n19 += 1;
            try std.testing.expect(b == 5 or b == 19);
        }
        try std.testing.expectEqual(@as(usize, 249), n5);
        try std.testing.expectEqual(@as(usize, 7), n19);
        try std.testing.expectEqual(@as(u8, 5), ch.biomes[0]);
        try std.testing.expectEqual(@as(u8, 19), ch.biomes[240]);
    }
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
        // Skylight: shaded to 12 at the surface by the spruce canopy
        // overhanging (0,0) (taiga runs now plant; voronoi ice-plains
        // planted nothing), 0 inside stone.
        const sky_top = chunk_mod.Section.getNibble(&s4.sky, 4 * 256);
        try std.testing.expectEqual(@as(u4, 12), sky_top);
        const sky_in = s4.blocks[0];
        _ = sky_in;
        const sky_below = chunk_mod.Section.getNibble(&s4.sky, 0);
        try std.testing.expectEqual(@as(u4, 0), sky_below);
    }
    // Heightmap: topmost non-air (spruce canopy at 75 overhangs (0,0)).
    try std.testing.expectEqual(@as(u8, 75), ch.heights[0]);
    // Full-res taiga runs plant spruce only: every log/leaf in the chunk
    // is meta 1 (regression lock for mixed-leaf canopies: voronoi runs
    // planted oak/birch/spruce side by side here).
    {
        var nlog: usize = 0;
        var nleaves: usize = 0;
        for (ch.sections) |maybe| {
            const sec = maybe orelse continue;
            for (0..4096) |kk| {
                if (sec.blocks[kk] == ids.log) {
                    nlog += 1;
                    try std.testing.expectEqual(@as(u4, 1), chunk_mod.Section.getNibble(&sec.meta, @intCast(kk)));
                }
                if (sec.blocks[kk] == ids.leaves) {
                    nleaves += 1;
                    try std.testing.expectEqual(@as(u4, 1), chunk_mod.Section.getNibble(&sec.meta, @intCast(kk)));
                }
            }
        }
        try std.testing.expect(nlog > 0);
        try std.testing.expect(nleaves > 0);
    }
}

// Batched hoist == sequential genChunk, byte-for-byte, on the CPU path
// (null GPU forces per-column CPU fills, so this runs everywhere without
// a driver and proves the 9-column reorder itself is a no-op).
test "batched hoist matches sequential chunk (CPU, seeds 42/12345)" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { seed: i64, cx: i32, cz: i32 }{
        .{ .seed = 42, .cx = 3, .cz = -5 },
        .{ .seed = 42, .cx = 0, .cz = 0 },
        .{ .seed = 42, .cx = 6, .cz = 0 },
        .{ .seed = 42, .cx = 7, .cz = -1 },
        .{ .seed = 12345, .cx = -7, .cz = 11 },
        .{ .seed = 7, .cx = 100, .cz = -40 },
    };
    for (cases) |tc| {
        var gen = try Gen.init(alloc, tc.seed, false, false);
        defer gen.deinit();
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = try gen.genChunk(alloc, arena.allocator(), tc.cx, tc.cz);
        defer a.destroy(alloc);
        // Twice: the second batched call must also match (catches state
        // pollution across batched calls on one Gen).
        const b = try gen.genChunkBatched(alloc, arena.allocator(), tc.cx, tc.cz);
        defer b.destroy(alloc);
        const c = try gen.genChunkBatched(alloc, arena.allocator(), tc.cx, tc.cz);
        defer c.destroy(alloc);
        for ([_]*chunk_mod.Chunk{ b, c }) |got| {
            try std.testing.expectEqual(a.mask(), got.mask());
            try std.testing.expectEqualSlices(u8, &a.biomes, &got.biomes);
            try std.testing.expectEqualSlices(u8, &a.heights, &got.heights);
            for (0..16) |s| {
                if (a.sections[s]) |rs| {
                    try std.testing.expect(got.sections[s] != null);
                    const gs = &got.sections[s].?;
                    try std.testing.expectEqualSlices(ids.Id, &rs.blocks, &gs.blocks);
                    try std.testing.expectEqualSlices(u8, &rs.meta, &gs.meta);
                    try std.testing.expectEqualSlices(u8, &rs.sky, &gs.sky);
                    try std.testing.expectEqualSlices(u8, &rs.light, &gs.light);
                } else {
                    try std.testing.expect(got.sections[s] == null);
                }
            }
        }
    }
}

// Batched GPU fill vs CPU fillChunk on identical density fields, seeded
// from a real neighborhood (seed 42 around chunk (6,0) — the first
// neighborhood that crashed pre-fix development). GPU-gated: skips
// without a driver; on GPU hardware any mismatch fails loudly with the
// first differing cell instead of flowing downstream.
test "repeat batched genChunk back-to-back on fresh arenas (seed 42 chunk (6,0))" {
    // Mirrors the bench shape that crashed pre-fix: warmup + measured on
    // the SAME chunk with a FRESH scratch arena each call (not one shared
    // arena). GPU-gated; compares both against a CPU reference.
    const alloc = std.testing.allocator;
    var ctx = (try gpufill_mod.GpuCtx.init(alloc, .auto)) orelse return error.SkipZigTest;
    defer ctx.deinit(alloc);
    const gf = gpufill_mod.GpuFill.init(ctx, alloc) orelse return error.SkipZigTest;
    defer {
        gf.deinit();
        alloc.destroy(gf);
    }
    if (!gf.batch_ok) return error.SkipZigTest;
    var ref = try Gen.init(alloc, 42, false, false);
    defer ref.deinit();
    var gen = try Gen.init(alloc, 42, false, false);
    defer gen.deinit();
    gen.gpu = gf;
    var arena0 = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena0.deinit();
    const want = try ref.genChunk(alloc, arena0.allocator(), 6, 0);
    defer want.destroy(alloc);
    for (0..2) |_| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const got = try gen.genChunkBatched(alloc, arena.allocator(), 6, 0);
        defer got.destroy(alloc);
        try std.testing.expectEqual(want.mask(), got.mask());
        try std.testing.expectEqualSlices(u8, &want.biomes, &got.biomes);
        try std.testing.expectEqualSlices(u8, &want.heights, &got.heights);
        for (0..16) |s| {
            if (want.sections[s]) |rs| {
                try std.testing.expect(got.sections[s] != null);
                const gs = &got.sections[s].?;
                try std.testing.expectEqualSlices(ids.Id, &rs.blocks, &gs.blocks);
                try std.testing.expectEqualSlices(u8, &rs.meta, &gs.meta);
                try std.testing.expectEqualSlices(u8, &rs.sky, &gs.sky);
                try std.testing.expectEqualSlices(u8, &rs.light, &gs.light);
            } else {
                try std.testing.expect(got.sections[s] == null);
            }
        }
    }
}

// Batched GPU fill vs CPU fillChunk on identical density fields, seeded
// from a real neighborhood (seed 42 around chunk (6,0)). GPU-gated: skips
// without a driver; on GPU hardware any mismatch fails loudly with the
// first differing cell instead of flowing downstream.
test "batched fill matches CPU fill (seed 42, chunk (6,0) neighborhood)" {
    const alloc = std.testing.allocator;
    var ctx = (try gpufill_mod.GpuCtx.init(alloc, .auto)) orelse return error.SkipZigTest;
    defer ctx.deinit(alloc);
    const gf = gpufill_mod.GpuFill.init(ctx, alloc) orelse return error.SkipZigTest;
    defer {
        gf.deinit();
        alloc.destroy(gf);
    }
    if (!gf.batch_ok) return error.SkipZigTest;
    var gen = try Gen.init(alloc, 42, false, false);
    defer gen.deinit();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const offs = [_][2]i32{
        .{ 0, 0 }, .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 },
        .{ -1, 0 }, .{ 1, 0 }, .{ -1, 1 }, .{ 0, 1 }, .{ 1, 1 },
    };
    var qs: [9][shaper_mod.Q_LEN]f64 = undefined;
    var gpu_b: [9]*[shaper_mod.BLOCKS_LEN]ids.Id = undefined;
    var cpu_b: [9]*[shaper_mod.BLOCKS_LEN]ids.Id = undefined;
    // Single completion-counted cleanup: per-iteration errdefers would
    // double-free against the final defer once the loop completes.
    var made: usize = 0;
    errdefer {
        for (gpu_b[0..made]) |b| alloc.destroy(b);
        for (cpu_b[0..made]) |b| alloc.destroy(b);
    }
    for (offs, 0..) |o, i| {
        try gen.shaper.densityField(arena.allocator(), 6 + o[0], 0 + o[1], &qs[i]);
        gpu_b[i] = try alloc.create([shaper_mod.BLOCKS_LEN]ids.Id);
        cpu_b[i] = alloc.create([shaper_mod.BLOCKS_LEN]ids.Id) catch |e| {
            alloc.destroy(gpu_b[i]);
            return e;
        };
        made = i + 1;
    }
    defer {
        for (gpu_b) |b| alloc.destroy(b);
        for (cpu_b) |b| alloc.destroy(b);
    }
    var qsl: [9][]const f64 = undefined;
    var osl: [9][]ids.Id = undefined;
    for (0..9) |i| {
        qsl[i] = &qs[i];
        osl[i] = gpu_b[i];
    }
    // Repeat on the SAME fill object: catches cross-dispatch state bugs
    // (command-buffer re-record, mapped-memory staleness). Each round
    // must match the CPU reference independently.
    for (0..3) |_| {
        try std.testing.expect(gf.fillBatch(&qsl, &osl, shaper_mod.SEA_LEVEL, @intFromEnum(ids.stone), @intFromEnum(ids.water), @intFromEnum(ids.air)));
        for (0..9) |i| shaper_mod.Shaper.fillChunk(&qs[i], cpu_b[i]);
        for (0..9) |i| try std.testing.expectEqualSlices(ids.Id, cpu_b[i], gpu_b[i]);
    }
}

test "roofed forest chunk grows dark oaks (seed 42 chunk 11,10)" {
    // End-to-end through the real pipeline: chunk (11,10) is biome 29 at
    // its full-res center (11*16+16, 10*16+16), so populateOne runs the
    // roofed grid. Must contain dark-oak wood (log2:1) and dark-oak
    // leaves (leaves2:1). Catches "no trees" wiring regressions (grid
    // skipped/unreachable).
    const alloc = std.testing.allocator;
    var gen = try Gen.init(alloc, 42, false, false);
    defer gen.deinit();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const ch = try gen.genChunk(alloc, arena.allocator(), 11, 10);
    defer ch.destroy(alloc);
    var dark_wood: usize = 0;
    var dark_leaves: usize = 0;
    for (ch.sections) |maybe| {
        const s = maybe orelse continue;
        for (0..4096) |k| {
            if (s.blocks[k] == ids.log2 and chunk_mod.Section.getNibble(&s.meta, @intCast(k)) == 1) dark_wood += 1;
            if (s.blocks[k] == ids.leaves2 and chunk_mod.Section.getNibble(&s.meta, @intCast(k)) == 1) dark_leaves += 1;
        }
    }
    // At least one 2-high 2x2 trunk segment plus canopy leaves.
    try std.testing.expect(dark_wood >= 8);
    try std.testing.expect(dark_leaves > 0);
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
    // re-pinned for full-res surface (jar aqz.setBlocksForChunk uses genBiomes): 0:42769 1:14696 3:22 7:812 11:88 12:18 24:105 159:2791 172:4235
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, wire.toWire(v)); // JVM goldens are wire ids
    try std.testing.expectEqual(@as(i64, 1734699579716538761), bc);
    var mc: i64 = 0; for (flat.meta.*) |v| mc = mc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 8890299795990835328), mc);
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
    // re-pinned for full-res surface (jar aqz.setBlocksForChunk uses genBiomes): 0:44920 1:14356 7:755 12:32 24:60 159:1967 172:3446
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, wire.toWire(v)); // JVM goldens are wire ids
    try std.testing.expectEqual(@as(i64, -6192574806577642146), bc);
    var mc: i64 = 0; for (flat.meta.*) |v| mc = mc *% 31 +% @as(i64, v);
    try std.testing.expectEqual(@as(i64, 88520079354623547), mc);
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
    // re-pinned for full-res surface (jar aqz.setBlocksForChunk uses genBiomes): 0:49469 1:12424 3:519 7:775 9:2244 13:105
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, wire.toWire(v)); // JVM goldens are wire ids
    try std.testing.expectEqual(@as(i64, -6145317988220835743), bc);
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
    // re-pinned for full-res surface (jar aqz.setBlocksForChunk uses genBiomes): 0:46261 1:17752 2:247 3:494 7:782
    var bc: i64 = 0; for (flat.blocks.*) |v| bc = bc *% 31 +% @as(i64, wire.toWire(v)); // JVM goldens are wire ids
    try std.testing.expectEqual(@as(i64, 3726581644871276838), bc);
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
    const op = try alloc.alloc(u8, LCELLS48);
    defer alloc.free(op);
    lightGrid48(grid, sky, light, op, q);
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
    const op = try alloc.alloc(u8, LCELLS48);
    defer alloc.free(op);
    lightGrid48(grid, sky, light, op, q);
    try std.testing.expectEqual(@as(u8, 13), light[(16 * LW48 + 24) * 256 + 64]);
    try std.testing.expectEqual(@as(u8, 12), light[(17 * LW48 + 24) * 256 + 64]);
    try std.testing.expectEqual(@as(u8, 0), light[(29 * LW48 + 24) * 256 + 64]);
    try std.testing.expectEqual(@as(u8, 14), light[(15 * LW48 + 24) * 256 + 64]);
    try std.testing.expectEqual(@as(u8, 15), sky[(16 * LW48 + 24) * 256 + 64]);
}

test "lightGrid48 matches div-based reference on mixed terrain" {
    // Differential gate for the optimized flood (bit-packed queue, delta
    // indexing, nested seed loops, hoisted column bases): the reference
    // below is the ORIGINAL formulation (flat scans with %//, per-neighbor
    // index multiplies). Any divergence in pack/unpack, deltas, loop
    // order, or seed order fails this byte-for-byte over a view mixing
    // opaque, transparent, emissive, and water cells.
    const alloc = std.testing.allocator;
    const grid = try alloc.alloc(ids.Id, LCELLS48);
    defer alloc.free(grid);
    const palette = [_]ids.Id{
        ids.air, ids.stone, ids.dirt, ids.grass, ids.log, ids.leaves,
        ids.leaves2, ids.water, ids.flowing_water, ids.glass, ids.torch,
        ids.lava, ids.flowing_lava, ids.sand, ids.ice, ids.snow_layer,
        ids.tallgrass, ids.red_flower, ids.pumpkin, ids.chest,
    };
    var h: u64 = 0x12345678;
    for (0..LCELLS48) |i| {
        // SplitMix64-style stir (test-only variety, not worldgen RNG).
        h +%= 0x9E3779B97F4A7C15;
        var z = h;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        z = z ^ (z >> 31);
        grid[i] = palette[z % palette.len];
    }
    const sky = try alloc.alloc(u8, LCELLS48);
    defer alloc.free(sky);
    const light = try alloc.alloc(u8, LCELLS48);
    defer alloc.free(light);
    const q = try alloc.alloc(u32, LCELLS48);
    defer alloc.free(q);
    const op = try alloc.alloc(u8, LCELLS48);
    defer alloc.free(op);
    lightGrid48(grid, sky, light, op, q);
    const rsky = try alloc.alloc(u8, LCELLS48);
    defer alloc.free(rsky);
    const rlight = try alloc.alloc(u8, LCELLS48);
    defer alloc.free(rlight);
    const rq = try alloc.alloc(u32, LCELLS48);
    defer alloc.free(rq);
    refLightGrid48(grid, rsky, rlight, rq);
    try std.testing.expectEqualSlices(u8, rsky, sky);
    try std.testing.expectEqualSlices(u8, rlight, light);
}

/// ORIGINAL lightGrid48 formulation (pre-optimization): flat scans with
/// %//, per-neighbor index multiplies, div-based pack/unpack. Test-only
/// reference for the differential test above — do not "optimize".
fn refPack48(x: usize, y: usize, z: usize) u32 {
    return @intCast((y * LW48 + z) * LW48 + x);
}

fn refUnpack48(c: u32) struct { x: usize, y: usize, z: usize } {
    const x: usize = c % LW48;
    const t: usize = c / LW48;
    return .{ .x = x, .y = t / LW48, .z = t % LW48 };
}

fn refLightGrid48(blocks48: []const ids.Id, sky48: []u8, light48: []u8, queue: []u32) void {
    for (0..LW48) |lz| {
        for (0..LW48) |lx| {
            var s: u4 = 15;
            var y: i32 = 255;
            while (y >= 0) : (y -= 1) {
                const uy: usize = @intCast(y);
                sky48[(lx * LW48 + lz) * 256 + uy] = s;
                const b = blocks48[(lx * LW48 + lz) * 256 + uy];
                const op = chunk_mod.lightOpacity(b);
                if (b != .water and op != 0) {
                    const drop: u4 = if (op > 15) 15 else @truncate(op);
                    s = if (drop >= s) 0 else s - drop;
                }
            }
        }
    }
    @memset(light48, 0);
    var tail: usize = 0;
    var head: usize = 0;
    for (sky48, 0..) |v, i| {
        if (v > 1) {
            if (tail >= queue.len) break;
            const y: usize = i % 256;
            const t: usize = i / 256;
            queue[tail] = refPack48(t / LW48, y, t % LW48);
            tail += 1;
        }
    }
    refBfs48(sky48, blocks48, .sky, queue, &head, &tail);
    head = 0;
    tail = 0;
    for (blocks48, 0..) |b, i| {
        const e = chunk_mod.emitLight(b);
        if (e == 0) continue;
        light48[i] = e;
        if (tail >= queue.len) break;
        const y: usize = i % 256;
        const t: usize = i / 256;
        queue[tail] = refPack48(t / LW48, y, t % LW48);
        tail += 1;
    }
    refBfs48(light48, blocks48, .block, queue, &head, &tail);
}

fn refBfs48(arr: []u8, blocks48: []const ids.Id, channel: chunk_mod.Chunk.LightChannel, queue: []u32, head: *usize, tail: *usize) void {
    while (head.* < tail.*) {
        const c = refUnpack48(queue[head.*]);
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
                queue[tail.*] = refPack48(ux, uy, uz);
                tail.* += 1;
            }
        }
    }
}


