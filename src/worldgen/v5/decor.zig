//! 1.7.10 decorators: ores (WorldGenMinable) + trees.
//!
//! Ports `ase` (minable), `asq`/`are`/`asn`/`aso` (trees), and the
//! `aia` (BiomeDecorator) ore/tree loops with `aqz` populate seeding.
//! Shape goldens are live JVM outputs (OreShape/TreeShape harnesses using
//! the REAL jar classes); RNG call order is spec.
//!
//! Scope (documented approximations):
//! - Ores: the 8 universal veins (dirt/gravel/coal/iron/gold/redstone/
//!   diamond/lapis) with vanilla counts, sizes, y-ranges. Emerald (extreme
//!   hills) is skipped.
//! - Trees: oak (`asq`), birch (`are`), spruce (`asn`), tall-oak (`aso`
//!   for swamp, shape-exact). Big-oak (`ard`), acacia (`ask`), jungle
//!   giants (`asi`/`arp`/`arz`), mushrooms (`aru`) map to small-oak with
//!   the same RNG draws consumed (documented; shapes differ).
//! - Sand (`asj` sand) / clay (`arj`) / gravel (`asj` gravel) disks are
//!   implemented (they come before trees in RNG order).
//! - Structures, lakes, dungeons (which precede ores in `aqz.populate`)
//!   are NOT replicated: our decorator seed starts fresh per chunk via
//!   populate-style mixing, so positions differ from vanilla while
//!   shapes/counts/distributions match. Full populate-chain parity is
//!   future work (needs structures/lakes/dungeons).
//! - 3x3 neighbor loop: each of the 9 chunks runs its own populate in an
//!   ISOLATED copy of the terrain view, merged in fixed order (neighbors
//!   sorted, center wins ties). Isolation keeps trunk/canopy consistent:
//!   sharing one mutable view let place/abort checks diverge per run
//!   (canopy kept without its trunk). Vanilla order is exploration-
//!   dependent; ours is canonical (pure function of seed+chunk).

const std = @import("std");
const java_random = @import("../rng/java_random.zig");
const carve_mod = @import("carve.zig");
const genlayer_mod = @import("genlayer.zig");
const noise_mod = @import("noise.zig");
const ids = @import("../../ids.zig");
const chunk_mod = @import("../../world/chunk.zig");
const view_blocks = @import("../../sim/world/view/blocks.zig");
const wire = @import("../../proto/v5/wire_ids.zig");


// ---------------------------------------------------------------------------
// Ore geometry cache: correct partial sharing of populate work.
// ---------------------------------------------------------------------------

/// One ellipsoid segment's cached geometry (all RNG-dependent values for
/// a single i in minable's vein walk). Replay uses these directly with no
/// RNG draws, trig, or setup divisions; per-cell ellipsoid tests + target
/// checks still run against the live host view in original order.
pub const OreSeg = struct {
    d7: f64,
    d8: f64,
    d9: f64,
    d11h: f64,
    d12h: f64,
    n4: i32,
    n5: i32,
    n6: i32,
    n7: i32,
    n8: i32,
    n9: i32,
};

/// Cached vein recipe: ordered segment params + final RNG state.
/// Keyed by entry RNG state + absolute coords + size + ore + target.
/// Entry state (not just chunk coords) is the key because pre-ore phases
/// (lakes/dungeons/ice/roofed) can take host-dependent paths; keying by
/// the actual entry state keeps reuse correct where inputs coincide.
pub const OreEntry = struct {
    entry_seed: u64,
    final_seed: u64,
    wx: i32,
    wy: i32,
    wz: i32,
    size: i32,
    ore: ids.Id,
    target: ids.Id,
    nsegs: usize,
    segs: [33]OreSeg = undefined,
    valid: bool = false,
};

/// Shared sharded FIFO ore cache (GenPool-owned).
/// 16 shards each with its own mutex/map/entries: ~800k ops/s across 8
/// workers would collapse a single mutex; sharding restores parallelism
/// while preserving cross-worker hits (shard by key hash, not by worker).
/// Hits copy the recipe out under a brief shard lock, replay lock-free.
pub const OreCache = struct {
    pub const SHARDS: usize = 16;
    pub const SHARD_CAP: usize = 64; // 16*64 = 1024 total, same as before
    pub const CAP: usize = SHARDS * SHARD_CAP;
    pub const MAX_SEGS: usize = 33;

    const Shard = struct {
        entries: []OreEntry,
        map: std.AutoHashMap(u64, usize),
        cursor: usize = 0,
        hits: u64 = 0,
        misses: u64 = 0,
        mutex: std.Io.Mutex = .init,
    };

    shards: [SHARDS]Shard = undefined,
    alloc: std.mem.Allocator,
    io: std.Io,

    pub fn init(alloc: std.mem.Allocator, io: std.Io) !OreCache {
        var c = OreCache{ .shards = undefined, .alloc = alloc, .io = io };
        var i: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < i) : (j += 1) {
                c.shards[j].map.deinit();
                alloc.free(c.shards[j].entries);
            }
        }
        while (i < SHARDS) : (i += 1) {
            const ents = try alloc.alloc(OreEntry, SHARD_CAP);
            for (ents) |*e| e.valid = false;
            c.shards[i] = .{
                .entries = ents,
                .map = std.AutoHashMap(u64, usize).init(alloc),
            };
        }
        return c;
    }

    pub fn deinit(self: *OreCache) void {
        for (&self.shards) |*sh| {
            sh.map.deinit();
            self.alloc.free(sh.entries);
        }
    }

    pub const Snapshot = struct { hits: u64, misses: u64 };

    pub fn snapshot(self: *OreCache) Snapshot {
        var h: u64 = 0;
        var m: u64 = 0;
        for (&self.shards) |*sh| {
            sh.mutex.lockUncancelable(self.io);
            h += sh.hits;
            m += sh.misses;
            sh.mutex.unlock(self.io);
        }
        return .{ .hits = h, .misses = m };
    }

    fn hashKey(entry_seed: u64, wx: i32, wy: i32, wz: i32, size: i32, ore: ids.Id, target: ids.Id) u64 {
        var h: u64 = entry_seed ^ 0x9E3779B97F4A7C15;
        h = (h ^ (@as(u64, @bitCast(@as(i64, wx))) +% 0x9E3779B1)) *% 0xBF58476D1CE4E5B9;
        h = (h ^ (@as(u64, @bitCast(@as(i64, wy))) +% 0x94D049BB133111EB)) *% 0xBF58476D1CE4E5B9;
        h = (h ^ (@as(u64, @bitCast(@as(i64, wz))) +% 0x85EBCA6B)) *% 0xBF58476D1CE4E5B9;
        h = (h ^ (@as(u64, @intCast(size)) +% 0xC2B2AE35)) *% 0xBF58476D1CE4E5B9;
        h = (h ^ @as(u64, @intFromEnum(ore))) *% 0xBF58476D1CE4E5B9;
        h = (h ^ @as(u64, @intFromEnum(target))) *% 0xBF58476D1CE4E5B9;
        h ^= h >> 29;
        h *%= 0xBF58476D1CE4E5B9;
        h ^= h >> 32;
        return h;
    }

    /// Shared-cache hit: copy segment recipe + final RNG state out under a
    /// brief shard lock, then replay without holding the lock.
    /// Returns true on hit (out params valid), false on miss.
    pub fn lookupCopy(self: *OreCache, entry_seed: u64, wx: i32, wy: i32, wz: i32, size: i32, ore: ids.Id, target: ids.Id, out_segs: *[MAX_SEGS]OreSeg, out_nsegs: *usize, out_final: *u64) bool {
        const k = hashKey(entry_seed, wx, wy, wz, size, ore, target);
        const sh = &self.shards[k % SHARDS];
        sh.mutex.lockUncancelable(self.io);
        defer sh.mutex.unlock(self.io);
        const si = sh.map.get(k) orelse {
            sh.misses += 1;
            return false;
        };
        const e = &sh.entries[si];
        if (!e.valid or e.entry_seed != entry_seed or e.wx != wx or e.wy != wy or e.wz != wz or e.size != size or e.ore != ore or e.target != target) {
            sh.misses += 1;
            return false;
        }
        for (e.segs[0..e.nsegs], 0..) |s, i| out_segs[i] = s;
        out_nsegs.* = e.nsegs;
        out_final.* = e.final_seed;
        sh.hits += 1;
        return true;
    }

    pub fn store(self: *OreCache, entry_seed: u64, final_seed: u64, wx: i32, wy: i32, wz: i32, size: i32, ore: ids.Id, target: ids.Id, segs: []const OreSeg) void {
        if (segs.len > MAX_SEGS) return;
        if (size < 0 or size > 32) return;
        const k = hashKey(entry_seed, wx, wy, wz, size, ore, target);
        const sh = &self.shards[k % SHARDS];
        sh.mutex.lockUncancelable(self.io);
        defer sh.mutex.unlock(self.io);
        // Evict oldest FIFO slot on pressure.
        const si = sh.cursor;
        sh.cursor += 1;
        if (sh.cursor >= SHARD_CAP) sh.cursor = 0;
        const old = &sh.entries[si];
        if (old.valid) {
            const old_k = hashKey(old.entry_seed, old.wx, old.wy, old.wz, old.size, old.ore, old.target);
            // Only remove if the map still points at this slot (a newer
            // store for the same key may have moved it).
            if (sh.map.get(old_k)) |idx| {
                if (idx == si) _ = sh.map.remove(old_k);
            }
        }
        const e = &sh.entries[si];
        e.entry_seed = entry_seed;
        e.final_seed = final_seed;
        e.wx = wx;
        e.wy = wy;
        e.wz = wz;
        e.size = size;
        e.ore = ore;
        e.target = target;
        e.nsegs = segs.len;
        for (segs, 0..) |s, i| e.segs[i] = s;
        e.valid = true;
        sh.map.put(k, si) catch {};
    }
};

// ---------------------------------------------------------------------------
// View: mutable block+meta window with world-coord access.
// ---------------------------------------------------------------------------

pub const View = struct {
    blocks: []ids.Id,
    metas: []u8,
    ox: i32, // world x of local (0,0)
    oz: i32,
    sx: usize,
    sz: usize,
    /// Shared ore-geometry cache (nullable): when set, minable()
    /// reuses cached ellipsoid segment params keyed by entry RNG state +
    /// coords, applying against the live host view. Null = reference path
    /// (tests, standalone runs). Byte-identical either way.
    ore_cache: ?*OreCache = null,
    /// Coarse dirty tiles for sparse merge-scan skip: 8x8-column tiles over
    /// the 48-wide view (6x6=36 bits). Every write marks its tile; merge
    /// scans only marked tiles (clean tiles equal pristine by construction).
    /// Completeness is load-bearing: every direct `blocks[ix]=` site must
    /// mark (see audit + dirty-vs-full differential test). `set()` marks.
    dirty: u64 = 0,

    /// Mark the tile containing world column (wx,wz). OOB = no write could
    /// have happened (idx check drops), so ignore.
    pub fn markDirty(self: *View, wx: i32, wz: i32) void {
        const lx = wx - self.ox;
        const lz = wz - self.oz;
        if (lx < 0 or lz < 0) return;
        const ux: usize = @intCast(lx);
        const uz: usize = @intCast(lz);
        if (ux >= self.sx or uz >= self.sz) return;
        // 8-wide tiles: >>3 exact (non-negative). 48/8=6 per side.
        const tx = ux >> 3;
        const tz = uz >> 3;
        const bit: u6 = @intCast(tx * 6 + tz);
        self.dirty |= @as(u64, 1) << bit;
    }

    pub fn clearDirty(self: *View) void {
        self.dirty = 0;
    }

    fn idx(self: *const View, wx: i32, y: i32, wz: i32) ?usize {
        if (y < 0 or y >= 256) return null;
        const lx = wx - self.ox;
        const lz = wz - self.oz;
        if (lx < 0 or lz < 0) return null;
        const ux: usize = @intCast(lx);
        const uz: usize = @intCast(lz);
        if (ux >= self.sx or uz >= self.sz) return null;
        return (ux * self.sz + uz) * 256 + @as(usize, @intCast(y));
    }

    /// Column base for (wx,wz): index of y=0, so cell (wx,y,wz) is
    /// `base+y`. One bounds check per column instead of per cell.
    /// `<<8 == *256` exactly (base < sx*sz*256 fits usize many times over).
    /// Does NOT check y — callers keep their own `0<=y<256` guard.
    fn colBase(self: *const View, wx: i32, wz: i32) ?usize {
        const lx = wx - self.ox;
        const lz = wz - self.oz;
        if (lx < 0 or lz < 0) return null;
        const ux: usize = @intCast(lx);
        const uz: usize = @intCast(lz);
        if (ux >= self.sx or uz >= self.sz) return null;
        return (ux * self.sz + uz) << 8;
    }

    pub fn get(self: *const View, wx: i32, y: i32, wz: i32) ids.Id {
        const i = self.idx(wx, y, wz) orelse return ids.air;
        return self.blocks[i];
    }

    pub fn getMeta(self: *const View, wx: i32, y: i32, wz: i32) u8 {
        const i = self.idx(wx, y, wz) orelse return 0;
        return self.metas[i];
    }

    pub fn set(self: *View, wx: i32, y: i32, wz: i32, id: ids.Id, meta: u8) void {
        const i = self.idx(wx, y, wz) orelse return;
        self.blocks[i] = id;
        self.metas[i] = meta;
        self.markDirty(wx, wz);
    }

    /// Is-air for tree space checks (matches `ahb.c`: true when air).
    /// Out-of-bounds reads as solid (fail closed, unlike ores which skip).
    pub fn isAir(self: *const View, wx: i32, y: i32, wz: i32) bool {
        const i = self.idx(wx, y, wz) orelse return false;
        return self.blocks[i] == ids.air;
    }
};

// ---------------------------------------------------------------------------
// qh helpers (share carve's bit-exact trig table).
// ---------------------------------------------------------------------------

var trig: ?[65536]f32 = null;

fn table() *const [65536]f32 {
    if (trig == null) trig = carve_mod.buildTrigTable();
    return &trig.?;
}

fn qhSin(f: f32) f32 {
    return carve_mod.qhSin(table(), f);
}

fn qhCos(f: f32) f32 {
    return carve_mod.qhCos(table(), f);
}

fn floorD(d: f64) i32 {
    const t: i32 = @intFromFloat(d);
    return if (d < @as(f64, @floatFromInt(t))) t - 1 else t;
}

const PI_F: f32 = 3.1415927; // (float)Math.PI, matches `nextFloat()*PI` in ase

// ---------------------------------------------------------------------------
// WorldGenMinable (`ase`): ellipsoid vein walk replacing stone.
// ---------------------------------------------------------------------------

/// Single vein at world (wx,wy,wz). Replaces `target` (stone) with `ore`.
/// Mirrors `ase.a` exactly (float math, RNG order, floor, bounds).
/// When view.ore_cache is set, ellipsoid segment params are reused across
/// host views with identical entry RNG state + coords (correct partial
/// sharing: geometry is view-independent, application still checks host
/// bounds + target in original order). Null cache = reference path.
/// Shared cache: lookupCopy copies under a brief lock, replay lock-free.
pub fn minable(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32, ore: ids.Id, size: i32, target: ids.Id) !void {
    // Cacheable sizes only (vanilla 6..32); otherwise reference path.
    const cacheable = (view.ore_cache != null and size >= 0 and size <= 32);
    var entry_seed: u64 = 0;
    if (cacheable) {
        entry_seed = rand.seed;
        var hit_segs: [OreCache.MAX_SEGS]OreSeg = undefined;
        var hit_n: usize = 0;
        var hit_final: u64 = 0;
        if (view.ore_cache.? .lookupCopy(entry_seed, wx, wy, wz, size, ore, target, &hit_segs, &hit_n, &hit_final)) {
            // Hit: fast-forward RNG and replay cached segments in order.
            rand.seed = hit_final;
            var si: usize = 0;
            while (si < hit_n) : (si += 1) {
                const s = hit_segs[si];
                var jx: i32 = s.n4;
                while (jx <= s.n7) : (jx += 1) {
                    const d13: f64 = (@as(f64, @floatFromInt(jx)) + 0.5 - s.d7) / s.d11h;
                    if (!(d13 * d13 < 1.0)) continue;
                    var jy: i32 = s.n5;
                    while (jy <= s.n8) : (jy += 1) {
                        const d14: f64 = (@as(f64, @floatFromInt(jy)) + 0.5 - s.d8) / s.d12h;
                        if (!(d13 * d13 + d14 * d14 < 1.0)) continue;
                        var jz: i32 = s.n6;
                        while (jz <= s.n9) : (jz += 1) {
                            const d15: f64 = (@as(f64, @floatFromInt(jz)) + 0.5 - s.d9) / s.d11h;
                            if (!(d13 * d13 + d14 * d14 + d15 * d15 < 1.0)) continue;
                            if (view.idx(jx, jy, jz)) |ix| {
                                if (view.blocks[ix] != target) continue;
                                view.blocks[ix] = ore;
                                view.metas[ix] = 0;
                                view.markDirty(jx, jz);
                            }
                        }
                    }
                }
            }
            return;
        }
    }
    const f: f32 = rand.nextFloat() * PI_F;
    const sf = qhSin(f);
    const cf = qhCos(f);
    const half: f32 = @as(f32, @floatFromInt(size)) / 8.0;
    const d: f64 = @as(f64, @floatFromInt(wx + 8)) + @as(f64, sf * half);
    const d2: f64 = @as(f64, @floatFromInt(wx + 8)) - @as(f64, sf * half);
    const d3: f64 = @as(f64, @floatFromInt(wz + 8)) + @as(f64, cf * half);
    const d4: f64 = @as(f64, @floatFromInt(wz + 8)) - @as(f64, cf * half);
    const d5: f64 = @as(f64, wy + try rand.nextIntBound(3) - 2);
    const d6: f64 = @as(f64, wy + try rand.nextIntBound(3) - 2);
    var segs_buf: [33]OreSeg = undefined;
    var nsegs: usize = 0;
    var i: i32 = 0;
    while (i <= size) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const fs: f32 = @floatFromInt(size);
        const d7: f64 = d + (d2 - d) * @as(f64, fi) / @as(f64, fs);
        const d8: f64 = d5 + (d6 - d5) * @as(f64, fi) / @as(f64, fs);
        const d9: f64 = d3 + (d4 - d3) * @as(f64, fi) / @as(f64, fs);
        // Bulk two-draw double: bit-identical to nextDouble (A2/C2 form).
        const d10: f64 = rand.nextDoubleFast() * @as(f64, @floatFromInt(size)) / 16.0;
        // NOTE: `qh.a(i*PI/size)+1` in f32, then widened. Replicate exactly:
        // `d11 = (sin(i*PI/size)+1) * d10 + 1`.
        const ang: f32 = fi * PI_F / fs;
        const s1: f64 = @as(f64, qhSin(ang)) + 1.0;
        const d11: f64 = s1 * d10 + 1.0;
        const d12: f64 = s1 * d10 + 1.0;
        // Half-widths hoisted per i: `x*0.5 == x/2.0` bit-for-bit (finite
        // power-of-two scale; d11/d12 >= 1.0 always). Dividing by d11h/d12h
        // below sees the identical divisor values the inline `/2.0` made.
        const d11h: f64 = d11 * 0.5;
        const d12h: f64 = d12 * 0.5;
        const n4: i32 = floorD(d7 - d11h);
        const n5: i32 = floorD(d8 - d12h);
        const n6: i32 = floorD(d9 - d11h);
        const n7: i32 = floorD(d7 + d11h);
        const n8: i32 = floorD(d8 + d12h);
        const n9: i32 = floorD(d9 + d11h);
        if (cacheable and nsegs < 33) {
            segs_buf[nsegs] = .{ .d7 = d7, .d8 = d8, .d9 = d9, .d11h = d11h, .d12h = d12h, .n4 = n4, .n5 = n5, .n6 = n6, .n7 = n7, .n8 = n8, .n9 = n9 };
            nsegs += 1;
        }
        var jx: i32 = n4;
        while (jx <= n7) : (jx += 1) {
            const d13: f64 = (@as(f64, @floatFromInt(jx)) + 0.5 - d7) / d11h;
            if (!(d13 * d13 < 1.0)) continue;
            var jy: i32 = n5;
            while (jy <= n8) : (jy += 1) {
                const d14: f64 = (@as(f64, @floatFromInt(jy)) + 0.5 - d8) / d12h;
                if (!(d13 * d13 + d14 * d14 < 1.0)) continue;
                var jz: i32 = n6;
                while (jz <= n9) : (jz += 1) {
                    const d15: f64 = (@as(f64, @floatFromInt(jz)) + 0.5 - d9) / d11h;
                    if (!(d13 * d13 + d14 * d14 + d15 * d15 < 1.0)) continue;
                    // Single index for the get+set pair (one bounds chain +
                    // one multiply instead of two). OOB: `get` would read
                    // air != stone and `set` would no-op — same skip. All
                    // callers pass target=stone.
                    if (view.idx(jx, jy, jz)) |ix| {
                        if (view.blocks[ix] != target) continue;
                        view.blocks[ix] = ore;
                        view.metas[ix] = 0;
                        view.markDirty(jx, jz);
                    }
                }
            }
        }
    }
    if (cacheable) {
        // Miss: store the recipe for identical future veins (same entry
        // state + coords). Final RNG state is what the next caller sees.
        view.ore_cache.? .store(entry_seed, rand.seed, wx, wy, wz, size, ore, target, segs_buf[0..nsegs]);
    }
}

// ---------------------------------------------------------------------------
// Shape tests vs JVM (OreShape harness, real `ase`).
// ---------------------------------------------------------------------------

test "minable coal matches JVM (seed 42)" {
    const alloc = std.testing.allocator;
    const S: usize = 64;
    const blocks = try alloc.alloc(ids.Id, S * 256 * S);
    defer alloc.free(blocks);
    const metas = try alloc.alloc(u8, S * 256 * S);
    defer alloc.free(metas);
    @memset(blocks, ids.air);
    @memset(metas, 0);
    // stone below y=70 (matches harness)
    for (0..S) |x| {
        for (0..S) |z| {
            for (0..70) |y| {
                blocks[(x * S + z) * 256 + y] = ids.stone;
            }
        }
    }
    var view = View{ .blocks = blocks, .metas = metas, .ox = -32, .oz = -32, .sx = S, .sz = S };
    var r = java_random.JavaRandom.init(42);
    try minable(&view, &r, 0, 50, 0, ids.coal_ore, 16, ids.stone);
    // JVM: changed=20, crc over 64x32x64 window around (0,50,0)
    var crc: i64 = 0;
    var changed: usize = 0;
    var coal: usize = 0;
    var wx: i32 = -32;
    while (wx < 32) : (wx += 1) {
        var wy: i32 = 34;
        while (wy < 66) : (wy += 1) {
            var wz: i32 = -32;
            while (wz < 32) : (wz += 1) {
                const id = view.get(wx, wy, wz);
                crc = crc *% 31 +% @as(i64, wire.toWire(id)); // JVM goldens are wire ids
                if (id == ids.coal_ore) coal += 1;
                if (id != ids.stone and id != ids.air) changed += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 20), coal);
    try std.testing.expectEqual(@as(usize, 20), changed);
    try std.testing.expectEqual(@as(i64, 6664539788273627968), crc);
}

test "minable iron/gold/redstone/diamond/lapis match JVM (seed 42)" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { ore: ids.Id, size: i32, want_n: usize, want_crc: i64 }{
        .{ .ore = ids.iron_ore, .size = 8, .want_n = 4, .want_crc = -4985998703837180800 },
        .{ .ore = ids.gold_ore, .size = 8, .want_n = 4, .want_crc = -1848336028041915200 },
        .{ .ore = ids.redstone_ore, .size = 7, .want_n = 4, .want_crc = -2502993162867069440 },
        .{ .ore = ids.diamond_ore, .size = 7, .want_n = 4, .want_crc = -4502959895476209088 },
        .{ .ore = ids.lapis_ore, .size = 6, .want_n = 4, .want_crc = -5365230684899222784 },
    };
    for (cases) |c| {
        const S: usize = 64;
        const blocks = try alloc.alloc(ids.Id, S * 256 * S);
        defer alloc.free(blocks);
        const metas = try alloc.alloc(u8, S * 256 * S);
        defer alloc.free(metas);
        @memset(blocks, ids.air);
        @memset(metas, 0);
        for (0..S) |x| {
            for (0..S) |z| {
                for (0..70) |y| {
                    blocks[(x * S + z) * 256 + y] = ids.stone;
                }
            }
        }
        var view = View{ .blocks = blocks, .metas = metas, .ox = -32, .oz = -32, .sx = S, .sz = S };
        var r = java_random.JavaRandom.init(42);
        try minable(&view, &r, 0, 50, 0, c.ore, c.size, ids.stone);
        var crc: i64 = 0;
        var n: usize = 0;
        var wx: i32 = -32;
        while (wx < 32) : (wx += 1) {
            var wy: i32 = 34;
            while (wy < 66) : (wy += 1) {
                var wz: i32 = -32;
                while (wz < 32) : (wz += 1) {
                    const id = view.get(wx, wy, wz);
                    crc = crc *% 31 +% @as(i64, wire.toWire(id)); // JVM goldens are wire ids
                    if (id == c.ore) n += 1;
                }
            }
        }
        try std.testing.expectEqual(c.want_crc, crc);
        try std.testing.expectEqual(c.want_n, n);
    }
}

test "minable dirt/gravel match JVM (seed 42)" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { ore: ids.Id, size: i32, want_n: usize, want_crc: i64 }{
        .{ .ore = ids.dirt, .size = 32, .want_n = 102, .want_crc = 3423075958434408956 },
        .{ .ore = ids.gravel, .size = 32, .want_n = 102, .want_crc = -8147241372490269720 },
    };
    for (cases) |c| {
        const S: usize = 64;
        const blocks = try alloc.alloc(ids.Id, S * 256 * S);
        defer alloc.free(blocks);
        const metas = try alloc.alloc(u8, S * 256 * S);
        defer alloc.free(metas);
        @memset(blocks, ids.air);
        @memset(metas, 0);
        for (0..S) |x| {
            for (0..S) |z| {
                for (0..70) |y| {
                    blocks[(x * S + z) * 256 + y] = ids.stone;
                }
            }
        }
        var view = View{ .blocks = blocks, .metas = metas, .ox = -32, .oz = -32, .sx = S, .sz = S };
        var r = java_random.JavaRandom.init(42);
        try minable(&view, &r, 0, 50, 0, c.ore, c.size, ids.stone);
        var crc: i64 = 0;
        var n: usize = 0;
        var wx: i32 = -32;
        while (wx < 32) : (wx += 1) {
            var wy: i32 = 34;
            while (wy < 66) : (wy += 1) {
                var wz: i32 = -32;
                while (wz < 32) : (wz += 1) {
                    const id = view.get(wx, wy, wz);
                    crc = crc *% 31 +% @as(i64, wire.toWire(id)); // JVM goldens are wire ids
                    if (id == c.ore) n += 1;
                }
            }
        }
        try std.testing.expectEqual(c.want_crc, crc);
        try std.testing.expectEqual(c.want_n, n);
    }
}

// ---------------------------------------------------------------------------
// Trees (`asq` oak, `are` birch, `asn` spruce, `aso` swamp oak).
// ---------------------------------------------------------------------------

test "ore cache hit matches reference (full-view + RNG state)" {
    const alloc = std.testing.allocator;
    const S: usize = 64;
    const mkView = struct {
        fn make(allocator: std.mem.Allocator) !struct { blocks: []ids.Id, metas: []u8 } {
            const b = try allocator.alloc(ids.Id, S * 256 * S);
            const m = try allocator.alloc(u8, S * 256 * S);
            @memset(b, ids.air);
            @memset(m, 0);
            for (0..S) |x| {
                for (0..S) |z| {
                    for (0..70) |y| {
                        b[(x * S + z) * 256 + y] = ids.stone;
                    }
                }
            }
            return .{ .blocks = b, .metas = m };
        }
    }.make;
    // Reference (no cache).
    const ref = try mkView(alloc);
    defer alloc.free(ref.blocks);
    defer alloc.free(ref.metas);
    var ref_view = View{ .blocks = ref.blocks, .metas = ref.metas, .ox = -32, .oz = -32, .sx = S, .sz = S, .ore_cache = null };
    var rr = java_random.JavaRandom.init(12345);
    try minable(&ref_view, &rr, 0, 50, 0, ids.dirt, 32, ids.stone);
    const ref_seed = rr.seed;
    // Cached: first call misses + stores, second call hits.
    const c1 = try mkView(alloc);
    defer alloc.free(c1.blocks);
    defer alloc.free(c1.metas);
    var oc = try OreCache.init(alloc, std.testing.io);
    defer oc.deinit();
    var v1 = View{ .blocks = c1.blocks, .metas = c1.metas, .ox = -32, .oz = -32, .sx = S, .sz = S, .ore_cache = &oc };
    var r1 = java_random.JavaRandom.init(12345);
    try minable(&v1, &r1, 0, 50, 0, ids.dirt, 32, ids.stone);
    try std.testing.expectEqual(ref_seed, r1.seed);
    try std.testing.expectEqualSlices(ids.Id, ref.blocks, c1.blocks);
    try std.testing.expectEqualSlices(u8, ref.metas, c1.metas);
    // Second view with same seed must hit and match byte-for-byte, even
    // though the host view differs (target checks still apply per host).
    const c2 = try mkView(alloc);
    defer alloc.free(c2.blocks);
    defer alloc.free(c2.metas);
    // Perturb one stone cell to air (host-dependent target check).
    c2.blocks[(32 * S + 32) * 256 + 50] = ids.air;
    var v2 = View{ .blocks = c2.blocks, .metas = c2.metas, .ox = -32, .oz = -32, .sx = S, .sz = S, .ore_cache = &oc };
    var r2 = java_random.JavaRandom.init(12345);
    try minable(&v2, &r2, 0, 50, 0, ids.dirt, 32, ids.stone);
    try std.testing.expectEqual(ref_seed, r2.seed);
    try std.testing.expect(oc.snapshot().hits >= 1);
    // Hit path must not write where the reference (with same host
    // perturbation) would not: recompute reference on the perturbed host.
    const rp = try mkView(alloc);
    defer alloc.free(rp.blocks);
    defer alloc.free(rp.metas);
    rp.blocks[(32 * S + 32) * 256 + 50] = ids.air;
    var ref_view2 = View{ .blocks = rp.blocks, .metas = rp.metas, .ox = -32, .oz = -32, .sx = S, .sz = S, .ore_cache = null };
    var rr2 = java_random.JavaRandom.init(12345);
    try minable(&ref_view2, &rr2, 0, 50, 0, ids.dirt, 32, ids.stone);
    try std.testing.expectEqualSlices(ids.Id, rp.blocks, c2.blocks);
    try std.testing.expectEqualSlices(u8, rp.metas, c2.metas);
}

test "dirty tiles cover every populate write (biomes 140/29/4)" {
    // Completeness gate for per-write markDirty: run the full populate for
    // spike/ice-path (140), roofed-grid (29), and forest (4) hosts, then
    // assert clean tiles equal pristine. A missed markDirty would fail here
    // before it could corrupt a tile-skipped merge (the same gate runs in
    // decorateCenter under runtime safety).
    const alloc = std.testing.allocator;
    const S: usize = 48;
    for ([_]i32{ 140, 29, 4 }) |biome_id| {
        const blocks = try alloc.alloc(ids.Id, S * 256 * S);
        defer alloc.free(blocks);
        const metas = try alloc.alloc(u8, S * 256 * S);
        defer alloc.free(metas);
        @memset(blocks, ids.air);
        @memset(metas, 0);
        for (0..S) |x| {
            for (0..S) |z| {
                for (0..70) |y| blocks[(x * S + z) * 256 + y] = ids.stone;
                blocks[(x * S + z) * 256 + 70] = ids.grass;
            }
        }
        const base_b = try alloc.alloc(ids.Id, S * 256 * S);
        defer alloc.free(base_b);
        const base_m = try alloc.alloc(u8, S * 256 * S);
        defer alloc.free(base_m);
        @memcpy(base_b, blocks);
        @memcpy(base_m, metas);
        var work = View{ .blocks = blocks, .metas = metas, .ox = -16, .oz = -16, .sx = S, .sz = S, .ore_cache = null };
        work.clearDirty();
        const heights = try alloc.alloc(i32, S * S);
        defer alloc.free(heights);
        var frand = java_random.JavaRandom.init(2345);
        var fnoise = try noise_mod.SimplexOctaves.init(alloc, &frand, 1);
        defer fnoise.deinit();
        var rand = java_random.JavaRandom.init(0);
        seedForChunk(&rand, 42, 0, 0);
        var win_bio: [256]i32 = undefined;
        @memset(&win_bio, biome_id);
        try populateOne(&work, heights, &rand, &fnoise, 0, 0, biome_id, win_bio);
        var tx: usize = 0;
        while (tx < 6) : (tx += 1) {
            var tz: usize = 0;
            while (tz < 6) : (tz += 1) {
                const bit: u6 = @intCast(tx * 6 + tz);
                if ((work.dirty >> bit) & 1 == 1) continue;
                var dx: usize = 0;
                while (dx < 8) : (dx += 1) {
                    var dz: usize = 0;
                    while (dz < 8) : (dz += 1) {
                        const cx_ = tx * 8 + dx;
                        const cz_ = tz * 8 + dz;
                        const cbase = (cx_ * S + cz_) * 256;
                        var yy: usize = 0;
                        while (yy < 256) : (yy += 1) {
                            const ii = cbase + yy;
                            try std.testing.expectEqual(base_b[ii], blocks[ii]);
                            try std.testing.expectEqual(base_m[ii], metas[ii]);
                        }
                    }
                }
            }
        }
    }
}

/// Replaceable for tree space checks (`arc.a`): air, leaves, grass, dirt,
/// logs, saplings, vines. Everything else (stone, ores, sand...) fails.
fn replaceable(id: ids.Id) bool {
    return id == ids.air or id == ids.grass or id == ids.dirt or id == ids.log or id == ids.leaves or
        id == ids.log2 or id == ids.leaves2 or id == ids.sapling or id == ids.vine;
}

/// Opaque cube for leaf placement (`aji.j()`): leaves and air are NOT
/// opaque; everything else is. Pre-tree world has no other transparents.
fn isOpaque(id: ids.Id) bool {
    return id != ids.air and id != ids.leaves and id != ids.leaves2;
}

/// Oak (`asq`): height `h_min` + nextInt(3), log meta `lm`, leaves meta `em`,
/// vines when `do_vines`. Covers base oak (h=4, no vines) and jungle oak
/// (caller draws +nextInt(7) for h, vines + cocoa RNG).
/// Cocoa draws are consumed but placement is skipped (documented).
pub fn oakTree(
    view: *View,
    rand: *java_random.JavaRandom,
    wx: i32,
    wy: i32,
    wz: i32,
    h_min: i32,
    log_meta: u8,
    leaf_meta: u8,
    do_vines: bool,
    do_cocoa: bool,
) !bool {
    const n10: i32 = try rand.nextIntBound(3) + h_min;
    if (wy < 1 or wy + n10 + 1 > 256) return false;
    var y: i32 = wy;
    while (y <= wy + 1 + n10) : (y += 1) {
        // y-plane guard hoisted out of the x/z loops (no side effects in
        // the check loops — identical fail-fast outcome).
        if (y < 0 or y >= 256) return false;
        var n9: i32 = 1;
        if (y == wy) n9 = 0;
        if (y >= wy + 1 + n10 - 2) n9 = 2;
        var x: i32 = wx - n9;
        while (x <= wx + n9) : (x += 1) {
            var z: i32 = wz - n9;
            while (z <= wz + n9) : (z += 1) {
                if (!replaceable(view.get(x, y, z))) return false;
            }
        }
    }
    const soil = view.get(wx, wy - 1, wz);
    if (soil != ids.grass and soil != ids.dirt) return false;
    if (wy >= 256 - n10 - 1) return false;
    view.set(wx, wy - 1, wz, ids.dirt, 0);
    const n8: i32 = 0;
    y = wy - 3 + n10;
    while (y <= wy + n10) : (y += 1) {
        const n11: i32 = y - (wy + n10);
        const n6: i32 = n8 + 1 - @divTrunc(n11, 2);
        var x: i32 = wx - n6;
        while (x <= wx + n6) : (x += 1) {
            const n4: i32 = x - wx;
            var z: i32 = wz - n6;
            while (z <= wz + n6) : (z += 1) {
                const n12: i32 = z - wz;
                const corner = @abs(n4) == n6 and @abs(n12) == n6;
                if (corner and ((try rand.nextIntBound(2)) == 0 or n11 == 0)) continue;
                // Single index for the isOpaque check + leaf set: OOB `get`
                // reads air (not opaque) and `set` no-ops — same skip.
                if (view.idx(x, y, z)) |ix| {
                    if (isOpaque(view.blocks[ix])) continue;
                    view.blocks[ix] = ids.leaves;
                    view.metas[ix] = leaf_meta;
                    view.markDirty(x, z);
                }
            }
        }
    }
    var n7: i32 = 0;
    while (n7 < n10) : (n7 += 1) {
        // Single index for the trunk get+set (OOB no-ops either way).
        if (view.idx(wx, wy + n7, wz)) |ix| {
            const b = view.blocks[ix];
            if (b != ids.air and b != ids.leaves and b != ids.leaves2) continue;
            view.blocks[ix] = ids.log;
            view.metas[ix] = log_meta;
            view.markDirty(wx, wz);
        }
    }
    if (do_vines) {
        y = wy - 3 + n10;
        while (y <= wy + n10) : (y += 1) {
            const n13: i32 = y - (wy + n10);
            const n6: i32 = 2 - @divTrunc(n13, 2);
            var x: i32 = wx - n6;
            while (x <= wx + n6) : (x += 1) {
                var z: i32 = wz - n6;
                while (z <= wz + n6) : (z += 1) {
                    const vc = view.get(x, y, z);
                    if (vc != ids.leaves and vc != ids.leaves2) continue;
                    if (try rand.nextIntBound(4) == 0 and view.get(x - 1, y, z) == ids.air) {
                        view.set(x - 1, y, z, ids.vine, 8);
                        hangVine(view, x - 1, y, z, 8);
                    }
                    if (try rand.nextIntBound(4) == 0 and view.get(x + 1, y, z) == ids.air) {
                        view.set(x + 1, y, z, ids.vine, 2);
                        hangVine(view, x + 1, y, z, 2);
                    }
                    if (try rand.nextIntBound(4) == 0 and view.get(x, y, z - 1) == ids.air) {
                        view.set(x, y, z - 1, ids.vine, 1);
                        hangVine(view, x, y, z - 1, 1);
                    }
                    if (try rand.nextIntBound(4) == 0 and view.get(x, y, z + 1) == ids.air) {
                        view.set(x, y, z + 1, ids.vine, 4);
                        hangVine(view, x, y, z + 1, 4);
                    }
                }
            }
        }
        if (do_cocoa and try rand.nextIntBound(5) == 0 and n10 > 5) {
            var n7c: i32 = 0;
            while (n7c < 2) : (n7c += 1) {
                var i: i32 = 0;
                while (i < 4) : (i += 1) {
                    if (try rand.nextIntBound(4 - n7c) != 0) continue;
                    _ = try rand.nextIntBound(3);
                }
            }
        }
    }
    return true;
}

fn hangVine(view: *View, wx: i32, wy: i32, wz: i32, meta: u8) void {
    var y = wy - 1;
    var left: i32 = 4;
    while (view.get(wx, y, wz) == ids.air and left > 0) : ({
        y -= 1;
        left -= 1;
    }) {
        view.set(wx, y, wz, ids.vine, meta);
    }
}

/// Birch (`are`): same shape as oak, height 5-7 (or +0-6 when tall),
/// log/leaves meta 2. Tall variant (`a` flag) adds `nextInt(7)`.
pub fn birchTree(
    view: *View,
    rand: *java_random.JavaRandom,
    wx: i32,
    wy: i32,
    wz: i32,
    tall: bool,
) !bool {
    var h_min: i32 = 5;
    if (tall) h_min += try rand.nextIntBound(7);
    return oakTree(view, rand, wx, wy, wz, h_min, 2, 2, false, false);
}

/// Swamp oak (`aso`): height nextInt(4)+5, WIDER canopy (radius 2-3 via
/// `2 - n6/2`), vines, no cocoa. Soil is grass/dirt (no farmland).
/// Down-shift loop (`while below material==h`) skipped: our views have no
/// tall-grass blocks, and the test/harness bases are always clear.
pub fn swampTree(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32) !bool {
    const n8: i32 = try rand.nextIntBound(4) + 5;
    if (wy < 1 or wy + n8 + 1 > 256) return false;
    var y: i32 = wy;
    while (y <= wy + 1 + n8) : (y += 1) {
        if (y < 0 or y >= 256) return false;
        var n7: i32 = 1;
        if (y == wy) n7 = 0;
        if (y >= wy + 1 + n8 - 2) n7 = 3;
        var x: i32 = wx - n7;
        while (x <= wx + n7) : (x += 1) {
            var z: i32 = wz - n7;
            while (z <= wz + n7) : (z += 1) {
                if (!replaceable(view.get(x, y, z))) return false;
            }
        }
    }
    const soil = view.get(wx, wy - 1, wz);
    if (soil != ids.grass and soil != ids.dirt) return false;
    if (wy >= 256 - n8 - 1) return false;
    view.set(wx, wy - 1, wz, ids.dirt, 0);
    y = wy - 3 + n8;
    while (y <= wy + n8) : (y += 1) {
        const n6: i32 = y - (wy + n8);
        const n5: i32 = 2 - @divTrunc(n6, 2);
        var x: i32 = wx - n5;
        while (x <= wx + n5) : (x += 1) {
            const n4: i32 = x - wx;
            var z: i32 = wz - n5;
            while (z <= wz + n5) : (z += 1) {
                const n9: i32 = z - wz;
                if (@abs(n4) == n5 and @abs(n9) == n5 and ((try rand.nextIntBound(2)) == 0 or n6 == 0)) continue;
                if (view.idx(x, y, z)) |ix| {
                    if (isOpaque(view.blocks[ix])) continue;
                    view.blocks[ix] = ids.leaves;
                    view.metas[ix] = 0;
                    view.markDirty(x, z);
                }
            }
        }
    }
    var n7t: i32 = 0;
    while (n7t < n8) : (n7t += 1) {
        if (view.idx(wx, wy + n7t, wz)) |ix| {
            const b = view.blocks[ix];
            if (b != ids.air and b != ids.leaves and b != ids.leaves2) continue;
            view.blocks[ix] = ids.log;
            view.metas[ix] = 0;
            view.markDirty(wx, wz);
        }
    }
    y = wy - 3 + n8;
    while (y <= wy + n8) : (y += 1) {
        const n10: i32 = y - (wy + n8);
        const n5: i32 = 2 - @divTrunc(n10, 2);
        var x: i32 = wx - n5;
        while (x <= wx + n5) : (x += 1) {
            var z: i32 = wz - n5;
            while (z <= wz + n5) : (z += 1) {
                const vc = view.get(x, y, z);
                if (vc != ids.leaves and vc != ids.leaves2) continue;
                if (try rand.nextIntBound(4) == 0 and view.get(x - 1, y, z) == ids.air) {
                    view.set(x - 1, y, z, ids.vine, 8);
                    hangVine(view, x - 1, y, z, 8);
                }
                if (try rand.nextIntBound(4) == 0 and view.get(x + 1, y, z) == ids.air) {
                    view.set(x + 1, y, z, ids.vine, 2);
                    hangVine(view, x + 1, y, z, 2);
                }
                if (try rand.nextIntBound(4) == 0 and view.get(x, y, z - 1) == ids.air) {
                    view.set(x, y, z - 1, ids.vine, 1);
                    hangVine(view, x, y, z - 1, 1);
                }
                if (try rand.nextIntBound(4) == 0 and view.get(x, y, z + 1) == ids.air) {
                    view.set(x, y, z + 1, ids.vine, 4);
                    hangVine(view, x, y, z + 1, 4);
                }
            }
        }
    }
    return true;
}

/// Spruce (`asn`): tapered conifer, log/leaves meta 1.
/// Ports the CFR decompile exactly (space check shape, leaf layers,
// trunk height `n9 - nextInt(3)`).
pub fn spruceTree(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32) !bool {
    const n9: i32 = try rand.nextIntBound(4) + 6;
    const n10: i32 = 1 + try rand.nextIntBound(2);
    const n11: i32 = n9 - n10;
    const n12: i32 = 2 + try rand.nextIntBound(2);
    if (wy < 1 or wy + n9 + 1 > 256) return false;
    var y: i32 = wy;
    while (y <= wy + 1 + n9) : (y += 1) {
        if (y < 0 or y >= 256) return false;
        var n8: i32 = 1;
        if (y - wy < n10) {
            n8 = 0;
        } else {
            n8 = n12;
        }
        var x: i32 = wx - n8;
        while (x <= wx + n8) : (x += 1) {
            var z: i32 = wz - n8;
            while (z <= wz + n8) : (z += 1) {
                const b = view.get(x, y, z);
                if (b != ids.air and b != ids.leaves and b != ids.leaves2) return false;
            }
        }
    }
    const soil = view.get(wx, wy - 1, wz);
    if (soil != ids.grass and soil != ids.dirt) return false;
    if (wy >= 256 - n9 - 1) return false;
    view.set(wx, wy - 1, wz, ids.dirt, 0);
    var n8: i32 = try rand.nextIntBound(2);
    var n7: i32 = 1;
    var n6: i32 = 0;
    var n5: i32 = 0;
    while (n5 <= n11) : (n5 += 1) {
        const n4: i32 = wy + n9 - n5;
        var x: i32 = wx - n8;
        while (x <= wx + n8) : (x += 1) {
            const n13: i32 = x - wx;
            var z: i32 = wz - n8;
            while (z <= wz + n8) : (z += 1) {
                const n14: i32 = z - wz;
                if (@abs(n13) == n8 and @abs(n14) == n8 and n8 > 0) continue;
                if (view.idx(x, n4, z)) |ix| {
                    if (isOpaque(view.blocks[ix])) continue;
                    view.blocks[ix] = ids.leaves;
                    view.metas[ix] = 1;
                    view.markDirty(x, z);
                }
            }
        }
        if (n8 >= n7) {
            n8 = n6;
            n6 = 1;
            n7 += 1;
            if (n7 > n12) n7 = n12;
        } else {
            n8 += 1;
        }
    }
    const n5t: i32 = try rand.nextIntBound(3);
    var n4: i32 = 0;
    while (n4 < n9 - n5t) : (n4 += 1) {
        if (view.idx(wx, wy + n4, wz)) |ix| {
            const b = view.blocks[ix];
            if (b != ids.air and b != ids.leaves and b != ids.leaves2) continue;
            view.blocks[ix] = ids.log;
            view.metas[ix] = 1;
            view.markDirty(wx, wz);
        }
    }
    return true;
}

/// Dark oak canopy tree (`asi`, jar-verified CFR 0.152): 2x2 `log2:1`
/// trunk (height 6-10 with up-to-2 lean toward a horizontal facing),
/// 2x2 dirt pad under it, blob + disk + hanging-branch `leaves2:1`
/// canopy. Draw order matches the jar exactly.
pub fn canopyTree(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32) !bool {
    // Facing offsets (jar `p.a` / `p.b`: SOUTH, WEST, NORTH, EAST).
    const lean_dx = [_]i32{ 0, -1, 0, 1 };
    const lean_dz = [_]i32{ 1, 0, -1, 0 };
    const n10: i32 = try rand.nextIntBound(3) + try rand.nextIntBound(2) + 6;
    var clear = true;
    if (wy < 1 or wy + n10 + 1 > 256) return false;
    var y: i32 = wy;
    while (y <= wy + 1 + n10) : (y += 1) {
        // y-plane guard hoisted: original set clear=false + broke the z
        // loop, after which `and clear` gates skipped every remaining
        // cell — identical fail outcome, no side effects either way.
        if (y < 0 or y >= 256) clear = false;
        var rad: i32 = 1;
        if (y == wy) rad = 0;
        if (y >= wy + 1 + n10 - 2) rad = 2;
        var x: i32 = wx - rad;
        while (x <= wx + rad and clear) : (x += 1) {
            var z: i32 = wz - rad;
            while (z <= wz + rad and clear) : (z += 1) {
                if (replaceable(view.get(x, y, z))) continue;
                clear = false;
            }
        }
    }
    if (!clear) return false;
    const soil = view.get(wx, wy - 1, wz);
    if (soil != ids.dirt and soil != ids.grass) return false;
    if (wy >= 256 - n10 - 1) return false;
    // 2x2 dirt pad (vanilla setDirtAt x4).
    view.set(wx, wy - 1, wz, ids.dirt, 0);
    view.set(wx + 1, wy - 1, wz, ids.dirt, 0);
    view.set(wx + 1, wy - 1, wz + 1, ids.dirt, 0);
    view.set(wx, wy - 1, wz + 1, ids.dirt, 0);
    const n9: i32 = try rand.nextIntBound(4);
    const n8: i32 = n10 - try rand.nextIntBound(4);
    var n7: i32 = 2 - try rand.nextIntBound(3);
    var n11: i32 = wx;
    var n12: i32 = wz;
    var n13: i32 = 0;
    var n6: i32 = 0;
    while (n6 < n10) : (n6 += 1) {
        const n5: i32 = wy + n6;
        if (n6 >= n8 and n7 > 0) {
            n11 += lean_dx[@as(usize, @intCast(n9))];
            n12 += lean_dz[@as(usize, @intCast(n9))];
            n7 -= 1;
        }
        // Trunk cells replace air/leaves only (else the column stops).
        // Fused single indexes: an OOB origin reads air (passes the check)
        // with no-op sets — `n13` still advances, exactly as before.
        const trunk_ok = if (view.idx(n11, n5, n12)) |ix| blk: {
            const trunk = view.blocks[ix];
            if (trunk != ids.air and trunk != ids.leaves and trunk != ids.leaves2) break :blk false;
            view.blocks[ix] = ids.log2;
            view.metas[ix] = 1;
            view.markDirty(n11, n12);
            break :blk true;
        } else true;
        if (!trunk_ok) continue;
        if (view.idx(n11 + 1, n5, n12)) |ix1| {
            view.blocks[ix1] = ids.log2;
            view.metas[ix1] = 1;
            view.markDirty(n11 + 1, n12);
        }
        if (view.idx(n11, n5, n12 + 1)) |ix2| {
            view.blocks[ix2] = ids.log2;
            view.metas[ix2] = 1;
            view.markDirty(n11, n12 + 1);
        }
        if (view.idx(n11 + 1, n5, n12 + 1)) |ix3| {
            view.blocks[ix3] = ids.log2;
            view.metas[ix3] = 1;
            view.markDirty(n11 + 1, n12 + 1);
        }
        n13 = n5;
    }
    // Leaves helper: air-only `leaves2:1` (vanilla 4-arg `a`).
    const leafAt = struct {
        fn put(v: *View, x: i32, yy: i32, z: i32) void {
            if (v.idx(x, yy, z)) |ix| {
                if (v.blocks[ix] == ids.air) {
                    v.blocks[ix] = ids.leaves2;
                    v.metas[ix] = 1;
                    v.markDirty(x, z);
                }
            }
        }
    }.put;
    // Lower blob ring at n13-1 (4 mirrored), upper ring at n13+1 except
    // the (-2,-2..-1)/(-1,-2) corner cells (vanilla quirk, verbatim).
    var m6: i32 = -2;
    while (m6 <= 0) : (m6 += 1) {
        var m5: i32 = -2;
        while (m5 <= 0) : (m5 += 1) {
            leafAt(view, n11 + m6, n13 - 1, n12 + m5);
            leafAt(view, 1 + n11 - m6, n13 - 1, n12 + m5);
            leafAt(view, n11 + m6, n13 - 1, 1 + n12 - m5);
            leafAt(view, 1 + n11 - m6, n13 - 1, 1 + n12 - m5);
            if (m6 <= -2 and m5 <= -1) continue;
            if (m6 == -1 and m5 == -2) continue;
            leafAt(view, n11 + m6, n13 + 1, n12 + m5);
            leafAt(view, 1 + n11 - m6, n13 + 1, n12 + m5);
            leafAt(view, n11 + m6, n13 + 1, 1 + n12 - m5);
            leafAt(view, 1 + n11 - m6, n13 + 1, 1 + n12 - m5);
        }
    }
    // Top knob (coin flip): 2x2 at n13+2.
    if (rand.nextBoolean()) {
        leafAt(view, n11, n13 + 2, n12);
        leafAt(view, n11 + 1, n13 + 2, n12);
        leafAt(view, n11 + 1, n13 + 2, n12 + 1);
        leafAt(view, n11, n13 + 2, n12 + 1);
    }
    // Wide disk at n13 (-3..4, minus the 2x2 corners).
    var d6: i32 = -3;
    while (d6 <= 4) : (d6 += 1) {
        var d5: i32 = -3;
        while (d5 <= 4) : (d5 += 1) {
            if (d6 == -3 and d5 == -3) continue;
            if (d6 == -3 and d5 == 4) continue;
            if (d6 == 4 and d5 == -3) continue;
            if (d6 == 4 and d5 == 4) continue;
            if (@abs(d6) >= 3 and @abs(d5) >= 3) continue;
            leafAt(view, n11 + d6, n13, n12 + d5);
        }
    }
    // Hanging branches off the trunk footprint (origin-based columns):
    // non-trunk cells with a 1/3 roll grow a 2-4 log2:1 pillar down,
    // capped with a 3x3 blob at n13 and a 5x5-minus-corners at n13-1
    // (trunk-top-based). Column writes are unconditional (vanilla 6-arg).
    var b6: i32 = -1;
    while (b6 <= 2) : (b6 += 1) {
        var b5: i32 = -1;
        while (b5 <= 2) : (b5 += 1) {
            if (b6 >= 0 and b6 <= 1 and b5 >= 0 and b5 <= 1) continue;
            if (try rand.nextIntBound(3) > 0) continue;
            const hang: i32 = try rand.nextIntBound(3) + 2;
            // Column walk with one bounds check: x/z fixed per branch, no
            // RNG inside — OOB columns no-op, same as `set` drops.
            if (view.colBase(wx + b6, wz + b5)) |hbase| {
                var n16: i32 = 0;
                while (n16 < hang) : (n16 += 1) {
                    const hy = n13 - n16 - 1;
                    if (hy < 0 or hy >= 256) continue;
                    const hi = hbase + @as(usize, @intCast(hy));
                    view.blocks[hi] = ids.log2;
                    view.metas[hi] = 1;
                    view.markDirty(wx + b6, wz + b5);
                }
            }
            var l16: i32 = -1;
            while (l16 <= 1) : (l16 += 1) {
                var l15: i32 = -1;
                while (l15 <= 1) : (l15 += 1) {
                    leafAt(view, n11 + b6 + l16, n13, n12 + b5 + l15);
                }
            }
            var w16: i32 = -2;
            while (w16 <= 2) : (w16 += 1) {
                var w15: i32 = -2;
                while (w15 <= 2) : (w15 += 1) {
                    if (@abs(w16) == 2 and @abs(w15) == 2) continue;
                    leafAt(view, n11 + b6 + w16, n13 - 1, n12 + b5 + w15);
                }
            }
        }
    }
    return true;
}

/// Roofed forest 4x4 canopy grid (see hook in populateOne). Draw order
/// per cell matches the jar exactly: x jitter, z jitter, mushroom roll,
/// then tree selection + generation draws.
fn roofedGrid(view: *View, heights: []i32, rand: *java_random.JavaRandom, base_x: i32, base_z: i32) !void {
    var i: i32 = 0;
    while (i < 4) : (i += 1) {
        var j: i32 = 0;
        while (j < 4) : (j += 1) {
            const wx = base_x + i * 4 + 1 + 8 + try rand.nextIntBound(3);
            const wz = base_z + j * 4 + 1 + 8 + try rand.nextIntBound(3);
            const wy = heightAt(view, heights, wx, wz) + 1;
            if (try rand.nextIntBound(20) == 0) {
                _ = try bigMushroom(view, rand, wx, wy, wz);
                continue;
            }
            switch (try selectTree(rand, 29)) {
                .canopy => _ = try canopyTree(view, rand, wx, wy, wz),
                .birch => _ = try birchTree(view, rand, wx, wy, wz, false),
                else => _ = try oakTree(view, rand, wx, wy, wz, 4, 0, 0, false, false),
            }
        }
    }
}

test "oak tree matches JVM (seed 42)" {
    const alloc = std.testing.allocator;
    const S: usize = 32;
    const blocks = try alloc.alloc(ids.Id, S * 256 * S);
    defer alloc.free(blocks);
    const metas = try alloc.alloc(u8, S * 256 * S);
    defer alloc.free(metas);
    @memset(blocks, ids.air);
    @memset(metas, 0);
    for (0..S) |x| {
        for (0..S) |z| {
            for (0..70) |y| {
                blocks[(x * S + z) * 256 + y] = ids.stone;
            }
            blocks[(x * S + z) * 256 + 70] = ids.grass;
        }
    }
    var view = View{ .blocks = blocks, .metas = metas, .ox = -16, .oz = -16, .sx = S, .sz = S };
    var r = java_random.JavaRandom.init(42);
    try std.testing.expect(try oakTree(&view, &r, 0, 71, 0, 4, 0, 0, false, false));
    var crc: i64 = 0;
    var mcrc: i64 = 0;
    var logs: usize = 0;
    var leaves: usize = 0;
    var wx: i32 = -16;
    while (wx < 16) : (wx += 1) {
        var wy: i32 = 66;
        while (wy < 91) : (wy += 1) {
            var wz: i32 = -16;
            while (wz < 16) : (wz += 1) {
                const id = view.get(wx, wy, wz);
                const m = view.getMeta(wx, wy, wz);
                crc = crc *% 31 +% @as(i64, wire.toWire(id)); // JVM goldens are wire ids
                mcrc = mcrc *% 31 +% @as(i64, m);
                if (id == ids.log) logs += 1;
                if (id == ids.leaves) leaves += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 6), logs);
    try std.testing.expectEqual(@as(usize, 54), leaves);
    try std.testing.expectEqual(@as(i64, -1826668108914625103), crc);
    try std.testing.expectEqual(@as(i64, 0), mcrc);
}

test "birch/spruce/swamp trees match JVM (seed 42)" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { kind: u8, logs: usize, leaves: usize, vines: usize, crc: i64, mcrc: i64 }{
        .{ .kind = 0, .logs = 7, .leaves = 54, .vines = 0, .crc = -877977615031885440, .mcrc = 8117188618465272170 }, // birch
        .{ .kind = 1, .logs = 8, .leaves = 97, .vines = 0, .crc = -3696107158537190579, .mcrc = 3409266497238487387 }, // spruce
        .{ .kind = 2, .logs = 7, .leaves = 134, .vines = 60, .crc = 8230978779061728660, .mcrc = -8457845339367753324 }, // swamp
    };
    for (cases) |c| {
        const S: usize = 32;
        const blocks = try alloc.alloc(ids.Id, S * 256 * S);
        defer alloc.free(blocks);
        const metas = try alloc.alloc(u8, S * 256 * S);
        defer alloc.free(metas);
        @memset(blocks, ids.air);
        @memset(metas, 0);
        for (0..S) |x| {
            for (0..S) |z| {
                for (0..70) |y| blocks[(x * S + z) * 256 + y] = ids.stone;
                blocks[(x * S + z) * 256 + 70] = ids.grass;
            }
        }
        var view = View{ .blocks = blocks, .metas = metas, .ox = -16, .oz = -16, .sx = S, .sz = S };
        var r = java_random.JavaRandom.init(42);
        if (c.kind == 0) {
            try std.testing.expect(try birchTree(&view, &r, 0, 71, 0, false));
        } else if (c.kind == 1) {
            try std.testing.expect(try spruceTree(&view, &r, 0, 71, 0));
        } else {
            try std.testing.expect(try swampTree(&view, &r, 0, 71, 0));
        }
        var crc: i64 = 0;
        var mcrc: i64 = 0;
        var logs: usize = 0;
        var leaves: usize = 0;
        var vines: usize = 0;
        var wx: i32 = -16;
        while (wx < 16) : (wx += 1) {
            var wy: i32 = 66;
            while (wy < 91) : (wy += 1) {
                var wz: i32 = -16;
                while (wz < 16) : (wz += 1) {
                    const id = view.get(wx, wy, wz);
                    const m = view.getMeta(wx, wy, wz);
                    crc = crc *% 31 +% @as(i64, wire.toWire(id)); // JVM goldens are wire ids
                    mcrc = mcrc *% 31 +% @as(i64, m);
                    if (id == ids.log) logs += 1;
                    if (id == ids.leaves) leaves += 1;
                    if (id == ids.vine) vines += 1;
                }
            }
        }
        try std.testing.expectEqual(c.logs, logs);
        try std.testing.expectEqual(c.leaves, leaves);
        try std.testing.expectEqual(c.vines, vines);
        try std.testing.expectEqual(c.crc, crc);
        try std.testing.expectEqual(c.mcrc, mcrc);
    }
}

test "canopy tree grows 2x2 dark oak on flat grass (seed 42)" {
    // Flat world: stone to 69, grass at 70; canopy at (0,71,0).
    // Structural assertions (vanilla shape): 2x2 log2:1 trunk of height
    // 6..10, leaves2 canopy present, 2x2 dirt pad under the trunk.
    // Exact counts below are implementation-derived regression locks
    // (jar-verified port; no JVM harness for canopy goldens yet).
    const alloc = std.testing.allocator;
    const S: usize = 32;
    const blocks = try alloc.alloc(ids.Id, S * 256 * S);
    defer alloc.free(blocks);
    const metas = try alloc.alloc(u8, S * 256 * S);
    defer alloc.free(metas);
    @memset(blocks, ids.air);
    @memset(metas, 0);
    for (0..S) |x| {
        for (0..S) |z| {
            for (0..70) |y| blocks[(x * S + z) * 256 + y] = ids.stone;
            blocks[(x * S + z) * 256 + 70] = ids.grass;
        }
    }
    var view = View{ .blocks = blocks, .metas = metas, .ox = -16, .oz = -16, .sx = S, .sz = S };
    var r = java_random.JavaRandom.init(42);
    try std.testing.expect(try canopyTree(&view, &r, 0, 71, 0));
    // Dirt pad: full 2x2 under the trunk.
    try std.testing.expectEqual(ids.dirt, view.get(0, 70, 0));
    try std.testing.expectEqual(ids.dirt, view.get(1, 70, 0));
    try std.testing.expectEqual(ids.dirt, view.get(0, 70, 1));
    try std.testing.expectEqual(ids.dirt, view.get(1, 70, 1));
    // Trunk: 2x2 log2:1 columns, same height each, 6..10 tall.
    var h: [4]usize = .{ 0, 0, 0, 0 };
    const cols = [_][2]i32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } };
    for (cols, 0..) |c, k| {
        var y: i32 = 71;
        while (y < 256 and view.get(c[0], y, c[1]) == ids.log2) : (y += 1) {
            try std.testing.expectEqual(@as(u8, 1), view.getMeta(c[0], y, c[1]));
            h[k] += 1;
        }
        try std.testing.expect(h[k] >= 6 and h[k] <= 10);
    }
    try std.testing.expectEqual(h[0], h[1]);
    try std.testing.expectEqual(h[0], h[2]);
    try std.testing.expectEqual(h[0], h[3]);
    // Canopy: dark-oak leaves present above and around the trunk top.
    var leaves: usize = 0;
    var wx: i32 = -16;
    while (wx < 16) : (wx += 1) {
        var wy: i32 = 66;
        while (wy < 91) : (wy += 1) {
            var wz: i32 = -16;
            while (wz < 16) : (wz += 1) {
                if (view.get(wx, wy, wz) == ids.leaves2) {
                    try std.testing.expectEqual(@as(u8, 1), view.getMeta(wx, wy, wz));
                    leaves += 1;
                }
            }
        }
    }
    try std.testing.expect(leaves > 50);
}

test "roofed grid plants dark oaks on flat grass (seed 7)" {
    // Flat grass world + fixed RNG: the grid must place 2x2 log2:1 trunks
    // (the reported bug was zero trees). Mushrooms are 1/20 per cell so
    // the assertion targets trunks, not shrooms.
    const alloc = std.testing.allocator;
    const S: usize = 48;
    const blocks = try alloc.alloc(ids.Id, S * 256 * S);
    defer alloc.free(blocks);
    const metas = try alloc.alloc(u8, S * 256 * S);
    defer alloc.free(metas);
    @memset(blocks, ids.air);
    @memset(metas, 0);
    for (0..S) |x| {
        for (0..S) |z| {
            for (0..64) |y| blocks[(x * S + z) * 256 + y] = ids.stone;
            blocks[(x * S + z) * 256 + 64] = ids.grass;
        }
    }
    var view = View{ .blocks = blocks, .metas = metas, .ox = -24, .oz = -24, .sx = S, .sz = S };
    const heights = try alloc.alloc(i32, S * S);
    defer alloc.free(heights);
    computeHeights(&view, heights);
    var r = java_random.JavaRandom.init(7);
    try roofedGrid(&view, heights, &r, 0, 0);
    // Count dark-oak trunk cells (2x2 columns of log2:1 resting on dirt).
    var trunks: usize = 0;
    var x: i32 = -24;
    while (x < 24) : (x += 1) {
        var z: i32 = -24;
        while (z < 24) : (z += 1) {
            var y: i32 = 60;
            while (y < 90) : (y += 1) {
                if (view.get(x, y, z) != ids.log2) continue;
                if (view.getMeta(x, y, z) != 1) continue;
                if (view.get(x, y - 1, z) != ids.log2 and view.get(x, y - 1, z) != ids.dirt) continue;
                trunks += 1;
            }
        }
    }
    // 16 cells x 2/3 canopy rate minus edge clipping: comfortably non-zero.
    try std.testing.expect(trunks >= 8);
}

// ---------------------------------------------------------------------------
// Sand / clay / gravel disks (`asj` sand/gravel, `arj` clay).
// ---------------------------------------------------------------------------

/// Sand or gravel disk (`asj`): radius `nextInt(b-2)+2`, height 2 (n5=2).
/// Replaces dirt/grass with `mat`. Requires material-h at base (we check
/// grass/dirt, matching `o()==awt.h` for our block set).
pub fn sandDisk(
    view: *View,
    rand: *java_random.JavaRandom,
    wx: i32,
    wy: i32,
    wz: i32,
    mat: ids.Id,
    b: i32,
) !bool {
    // Vanilla requires water material (`awt.h`) at base: disks are
    // underwater patches. Land views correctly place nothing.
    const base = view.get(wx, wy, wz);
    if (base != ids.flowing_water and base != ids.water) return false;
    const n4: i32 = try rand.nextIntBound(b - 2) + 2;
    const n5: i32 = 2;
    // r2 hoisted (|n4|<=5, no overflow); one bounds check per column,
    // per-y guard kept (edge columns can touch y=-1/256+).
    const r2: i32 = n4 * n4;
    var x: i32 = wx - n4;
    while (x <= wx + n4) : (x += 1) {
        const dx = x - wx;
        const dx2: i32 = dx * dx;
        var z: i32 = wz - n4;
        while (z <= wz + n4) : (z += 1) {
            const dz = z - wz;
            if (dx2 + dz * dz > r2) continue;
            const cbase = view.colBase(x, z) orelse continue;
            var y: i32 = wy - n5;
            while (y <= wy + n5) : (y += 1) {
                if (y < 0 or y >= 256) continue;
                const ci: usize = cbase + @as(usize, @intCast(y));
                const cur = view.blocks[ci];
                if (cur != ids.dirt and cur != ids.grass) continue;
                view.blocks[ci] = mat;
                view.metas[ci] = 0;
                view.markDirty(x, z);
            }
        }
    }
    return true;
}

/// Clay disk (`arj`): radius `nextInt(2)+2` (b=4), height 1, replaces
/// dirt/clay with clay. Base must be grass/dirt (material-h check).
pub fn clayDisk(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32) !bool {
    const base = view.get(wx, wy, wz);
    if (base != ids.flowing_water and base != ids.water) return false;
    const n4: i32 = try rand.nextIntBound(2) + 2;
    const n5: i32 = 1;
    const r2: i32 = n4 * n4;
    var x: i32 = wx - n4;
    while (x <= wx + n4) : (x += 1) {
        const dx = x - wx;
        const dx2: i32 = dx * dx;
        var z: i32 = wz - n4;
        while (z <= wz + n4) : (z += 1) {
            const dz = z - wz;
            if (dx2 + dz * dz > r2) continue;
            const cbase = view.colBase(x, z) orelse continue;
            var y: i32 = wy - n5;
            while (y <= wy + n5) : (y += 1) {
                if (y < 0 or y >= 256) continue;
                const ci: usize = cbase + @as(usize, @intCast(y));
                const cur = view.blocks[ci];
                if (cur != ids.dirt and cur != ids.clay) continue;
                view.blocks[ci] = ids.clay;
                view.metas[ci] = 0;
                view.markDirty(x, z);
            }
        }
    }
    return true;
}

/// Underground spring (`asm`): needs stone above+below, center air-or-stone,
/// exactly 3 stone horizontals and 1 air among (down,east,north,south);
/// then sets the liquid. Water and lava share the shape.
pub fn springGen(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32, liquid: ids.Id) !bool {
    _ = rand;
    if (view.get(wx, wy + 1, wz) != ids.stone) return false;
    if (view.get(wx, wy - 1, wz) != ids.stone) return false;
    // Center read once: OOB `get` is air (fails `!= stone`) while OOB
    // `isAir` is false — both demand `return false`, so null → return.
    const ci = view.idx(wx, wy, wz) orelse return false;
    const c = view.blocks[ci];
    if (c != ids.air and c != ids.stone) return false;
    // Each neighbor column read once for its stone+air checks (OOB skips
    // both, matching `get`→air-not-stone + `isAir`→false).
    var stone_n: i32 = 0;
    var air_n: i32 = 0;
    if (view.idx(wx - 1, wy, wz)) |ix| {
        if (view.blocks[ix] == ids.stone) stone_n += 1;
    }
    if (view.idx(wx + 1, wy, wz)) |ix| {
        if (view.blocks[ix] == ids.stone) stone_n += 1;
        if (view.blocks[ix] == ids.air) air_n += 1;
    }
    if (view.idx(wx, wy, wz - 1)) |ix| {
        if (view.blocks[ix] == ids.stone) stone_n += 1;
        if (view.blocks[ix] == ids.air) air_n += 1;
    }
    if (view.idx(wx, wy, wz + 1)) |ix| {
        if (view.blocks[ix] == ids.stone) stone_n += 1;
        if (view.blocks[ix] == ids.air) air_n += 1;
    }
    if (view.idx(wx, wy - 1, wz)) |ix| {
        if (view.blocks[ix] == ids.air) air_n += 1;
    }
    if (stone_n != 3 or air_n != 1) return false;
    view.set(wx, wy, wz, liquid, 0);
    return true;
}

/// Surface lake (`arx`): ellipsoid hollow carved around (wx,wy,wz),
/// validated (shell must be liquid-free above / opaque below), filled with
/// liquid below y+4 and air above, grass dirt rim, and stone shell.
/// `frozen` is reserved: jar-verified vanilla `arx` has no snow/ice branch
/// (rim is always grass; surface ice comes from the populate snow/ice tail,
/// which already freezes top water per column). Kept so call sites don't
/// churn if a frozen-specific lake tweak is ever verified.
pub fn lakeGen(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32, liquid: ids.Id, frozen: bool) !bool {
    const x = wx - 8;
    var y = wy;
    const z = wz - 8;
    while (y > 5 and view.isAir(x, y, z)) y -= 1;
    if (y <= 4) return false;
    y -= 4;
    var hollow: [2048]bool = [_]bool{false} ** 2048;
    const layers: i32 = try rand.nextIntBound(4) + 4;
    var l: i32 = 0;
    while (l < layers) : (l += 1) {
        const rx = rand.nextDouble() * 6.0 + 3.0;
        const ry = rand.nextDouble() * 4.0 + 2.0;
        const rz = rand.nextDouble() * 6.0 + 3.0;
        // Half-widths up front: `x*0.5 == x/2.0` bit-for-bit (finite
        // power-of-two scale). ox/oy/oz and the per-cell divisors below
        // all see the identical values the inline `/2.0` made — no
        // reciprocal multiply (that would round differently).
        const rxh: f64 = rx * 0.5;
        const ryh: f64 = ry * 0.5;
        const rzh: f64 = rz * 0.5;
        const ox = rand.nextDouble() * (16.0 - rx - 2.0) + 1.0 + rxh;
        // NOTE: oy adds +2.0 (ldc 2.0 in bytecode), NOT +1.0 like ox/oz
        // (dconst_1). Misreading this as +1.0 shifts the whole bowl down
        // one block (224 lava vs vanilla's 131 for the seed-999 case).
        const oy = rand.nextDouble() * (8.0 - ry - 4.0) + 2.0 + ryh;
        const oz = rand.nextDouble() * (16.0 - rz - 2.0) + 1.0 + rzh;
        var i: i32 = 1;
        while (i < 15) : (i += 1) {
            var k: i32 = 1;
            while (k < 15) : (k += 1) {
                const plane: usize = @as(usize, @intCast(i * 16 + k)) << 3;
                var j: i32 = 1;
                while (j < 7) : (j += 1) {
                    const dx = (@as(f64, @floatFromInt(i)) - ox) / rxh;
                    const dy = (@as(f64, @floatFromInt(j)) - oy) / ryh;
                    const dz = (@as(f64, @floatFromInt(k)) - oz) / rzh;
                    if (dx * dx + dy * dy + dz * dz < 1.0) {
                        hollow[plane + @as(usize, @intCast(j))] = true;
                    }
                }
            }
        }
    }
    // Suitability: for each NON-hollow cell adjacent (6-neighborhood) to
    // hollow, the shell must be valid: upper half (j>=4) must hold no
    // liquid; lower half must be opaque or the lake liquid itself.
    // (Bytecode checks shell cells — h0||hn — not hollow interior.)
    var i: i32 = 0;
    while (i < 16) : (i += 1) {
        var k: i32 = 0;
        while (k < 16) : (k += 1) {
            // (i*16+k)*8 hoisted: neighbors are fixed ±strides from it.
            // Guards keep every index in [0,2048) exactly as before.
            const base: i32 = (i * 16 + k) * 8;
            var j: i32 = 0;
            while (j < 8) : (j += 1) {
                const h0: bool = hollow[@as(usize, @intCast(base + j))];
                const hn: bool = (i < 15 and hollow[@as(usize, @intCast(base + 128 + j))]) or
                    (i > 0 and hollow[@as(usize, @intCast(base - 128 + j))]) or
                    (k < 15 and hollow[@as(usize, @intCast(base + 8 + j))]) or
                    (k > 0 and hollow[@as(usize, @intCast(base - 8 + j))]) or
                    (j < 7 and hollow[@as(usize, @intCast(base + j + 1))]) or
                    (j > 0 and hollow[@as(usize, @intCast(base + j - 1))]);
                if (!h0 and !hn) continue;
                if (h0) continue; // interior needs no validation
                const id = view.get(x + i, y + j, z + k);
                if (j >= 4) {
                    if (id == ids.water or id == ids.flowing_water or id == ids.lava or id == ids.flowing_lava) return false;
                } else {
                    if (!isSoilOpaque(id) and id != liquid) return false;
                }
            }
        }
    }
    // Fill: liquid below y+4, air above.
    i = 0;
    while (i < 16) : (i += 1) {
        var k: i32 = 0;
        while (k < 16) : (k += 1) {
            const base: i32 = (i * 16 + k) * 8;
            var j: i32 = 0;
            while (j < 8) : (j += 1) {
                if (!hollow[@as(usize, @intCast(base + j))]) continue;
                if (j >= 4) {
                    view.set(x + i, y + j, z + k, ids.air, 0);
                } else {
                    view.set(x + i, y + j, z + k, liquid, 0);
                }
            }
        }
    }
    // Grass rim (jar-verified: always grass, even in frozen biomes — the
    // populate snow/ice tail lays snow_layer on top afterwards): for hollow
    // cells in the upper half, dirt directly below becomes grass when open
    // to the sky. Skylight in our engine is vertical-only (no horizontal
    // spread), so the light gate is approximated as always-pass (documented;
    // lakes generate near the surface where this holds).
    _ = frozen;
    i = 0;
    while (i < 16) : (i += 1) {
        var k: i32 = 0;
        while (k < 16) : (k += 1) {
            var j: i32 = 4;
            while (j < 8) : (j += 1) {
                if (!hollow[@as(usize, @intCast((i * 16 + k) * 8 + j))]) continue;
                if (view.get(x + i, y + j - 1, z + k) != ids.dirt) continue;
                view.set(x + i, y + j - 1, z + k, ids.grass, 0);
            }
        }
    }
    // Stone shell: shell cells (non-hollow adjacent to hollow) get a stone
    // casing. Lower half always; upper half proceeds on nextInt(2)!=0
    // (draws are load-bearing for everything downstream).
    i = 0;
    while (i < 16) : (i += 1) {
        var k: i32 = 0;
        while (k < 16) : (k += 1) {
            var j: i32 = 0;
            while (j < 8) : (j += 1) {
                const h0: bool = hollow[@as(usize, @intCast((i * 16 + k) * 8 + j))];
                const hn: bool = (i < 15 and hollow[@as(usize, @intCast(((i + 1) * 16 + k) * 8 + j))]) or
                    (i > 0 and hollow[@as(usize, @intCast(((i - 1) * 16 + k) * 8 + j))]) or
                    (k < 15 and hollow[@as(usize, @intCast((i * 16 + (k + 1)) * 8 + j))]) or
                    (k > 0 and hollow[@as(usize, @intCast((i * 16 + (k - 1)) * 8 + j))]) or
                    (j < 7 and hollow[@as(usize, @intCast((i * 16 + k) * 8 + (j + 1)))]) or
                    (j > 0 and hollow[@as(usize, @intCast((i * 16 + k) * 8 + (j - 1)))]);
                if (!h0 and !hn) continue;
                if (h0) continue; // shell only
                if (j >= 4 and try rand.nextIntBound(2) == 0) continue;
                if (!isSoilOpaque(view.get(x + i, y + j, z + k))) continue;
                view.set(x + i, y + j, z + k, ids.stone, 0);
            }
        }
    }
    // No freeze pass here (jar-verified `arx` ends at the stone shell;
    // surface ice in frozen biomes comes from the populate snow/ice tail,
    // which freezes each column's top water). The old y+3 ice cap iced
    // below the surface and left floating snow over ponds.
    return true;
}

/// Dungeon room (`asd`): floor/ceiling must be opaque; 1-5 wall openings;
/// carve with mossy/cobble floor (1/4 mossy) and cobble walls; 2 chest spots
/// (air + exactly 1 opaque horizontal neighbor) get plain chests — loot
/// needs tile-entity storage (follow-up; draws deferred with it); spawner
/// block placed, type drawn (Skeleton/Zombie/Zombie/Spider) but the entity
/// logic is a follow-up like all mob AI.
pub fn dungeonGen(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32) !bool {
    const iw: i32 = try rand.nextIntBound(2) + 2;
    const il: i32 = try rand.nextIntBound(2) + 2;
    // Suitability: floor (y-1) and ceiling (y+4) all opaque. Only those
    // two planes are ever read — the y-loop's other four planes were
    // no-op iterations (pure `y==` tests), so this loops planes directly
    // in the same (x,z) order. Identical fail-fast outcome.
    var x: i32 = wx - iw - 1;
    while (x <= wx + iw + 1) : (x += 1) {
        var z: i32 = wz - il - 1;
        while (z <= wz + il + 1) : (z += 1) {
            if (!isSoilOpaque(view.get(x, wy - 1, z))) return false;
            if (!isSoilOpaque(view.get(x, wy + 3 + 1, z))) return false;
        }
    }
    // Openings: border cells at floor level with 2 air above, 1..5 allowed.
    // (y2-loop collapsed the same way: only y2==wy did work.)
    var openings: i32 = 0;
    x = wx - iw - 1;
    while (x <= wx + iw + 1) : (x += 1) {
        var z: i32 = wz - il - 1;
        while (z <= wz + il + 1) : (z += 1) {
            const border = x == wx - iw - 1 or x == wx + iw + 1 or z == wz - il - 1 or z == wz + il + 1;
            if (!border) continue;
            if (view.isAir(x, wy, z) and view.isAir(x, wy + 1, z)) openings += 1;
        }
    }
    if (openings < 1 or openings > 5) return false;
    // Carve: border -> mossy/cobble floor, cobble walls/ceiling (or air when
    // below is open); interior -> air.
    x = wx - iw - 1;
    while (x <= wx + iw + 1) : (x += 1) {
        var y3: i32 = wy + 3;
        while (y3 >= wy - 1) : (y3 -= 1) {
            var z: i32 = wz - il - 1;
            while (z <= wz + il + 1) : (z += 1) {
                const border = x == wx - iw - 1 or x == wx + iw + 1 or y3 == wy - 1 or y3 == wy + 3 + 1 or z == wz - il - 1 or z == wz + il + 1;
                if (!border) {
                    view.set(x, y3, z, ids.air, 0);
                    continue;
                }
                if (y3 < 0) {
                    view.set(x, y3, z, ids.air, 0);
                    continue;
                }
                if (!isSoilOpaque(view.get(x, y3 - 1, z))) {
                    view.set(x, y3, z, ids.air, 0);
                    continue;
                }
                if (y3 == wy - 1 and try rand.nextIntBound(4) == 0) {
                    view.set(x, y3, z, ids.mossy_cobblestone, 0);
                } else {
                    view.set(x, y3, z, ids.cobblestone, 0);
                }
            }
        }
    }
    // Chests: 2 spots, air + exactly 1 opaque horizontal neighbor.
    var c: i32 = 0;
    while (c < 2) : (c += 1) {
        const cx: i32 = wx + try rand.nextIntBound(iw * 2 + 1) - iw;
        const cz: i32 = wz + try rand.nextIntBound(il * 2 + 1) - il;
        if (!view.isAir(cx, wy, cz)) continue;
        var solid_n: i32 = 0;
        if (isSoilOpaque(view.get(cx - 1, wy, cz))) solid_n += 1;
        if (isSoilOpaque(view.get(cx + 1, wy, cz))) solid_n += 1;
        if (isSoilOpaque(view.get(cx, wy, cz - 1))) solid_n += 1;
        if (isSoilOpaque(view.get(cx, wy, cz + 1))) solid_n += 1;
        if (solid_n != 1) continue;
        view.set(cx, wy, cz, ids.chest, 0);
        // Loot rolls + spawner-entity logic need tile entities (follow-up);
        // the placement draws above are exact, loot draws are deferred with it.
    }
    // Spawner (type drawn exactly; block placed, entity logic follows mobs).
    view.set(wx, wy, wz, ids.mob_spawner, 0);
    _ = try rand.nextIntBound(4);
    return true;
}

/// Spike-body replaceable set (vanilla `arw`: air material, dirt, snow,
/// ice). Out-of-view reads are air (never replaceable — fail closed).
fn isSpikeReplaceable(id: ids.Id) bool {
    return id == ids.air or id == ids.dirt or id == ids.snow or id == ids.ice;
}

/// Base-ray replaceable set (same + packed ice: rays pierce older spikes).
fn isSpikeRayReplaceable(id: ids.Id) bool {
    return isSpikeReplaceable(id) or id == ids.packed_ice;
}

/// Ice spike (vanilla `arw`, WorldGenIceSpike, jar-verified): packed-ice
/// spike on snow ground, with mirrored underside and sinking base rays.
/// RNG draws, in order: nextInt(4) lift, nextInt(4)+7 height, nextInt(2)
/// radius term, [nextInt(60)[, nextInt(30)] tall variant], per-rim-cell
/// nextFloat (0.75 gate), per-corner-ray nextInt(5), per ray segment
/// nextInt(5)+1 skip then nextInt(5) refill. f32 arithmetic matches Java
/// float ops (golden-pinned below); ceil matches (int)Math.ceil via exact
/// f32->f64 widening.
pub fn iceSpike(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32) !bool {
    // Downscan with one bounds check: OOB `isAir` is false (stops the
    // scan), and y>=256 likewise stops — the guarded walk matches both.
    var y = wy;
    if (view.colBase(wx, wz)) |base| {
        while (y > 2 and y < 256 and view.blocks[base + @as(usize, @intCast(y))] == ids.air) y -= 1;
    }
    if (view.get(wx, y, wz) != ids.snow) return false;
    y += try rand.nextIntBound(4);
    const i = try rand.nextIntBound(4) + 7;
    const j = @divTrunc(i, 4) + try rand.nextIntBound(2);
    if (j > 1 and try rand.nextIntBound(60) == 0) {
        y += 10 + try rand.nextIntBound(30);
    }
    const fi: f32 = @floatFromInt(i);
    const fj: f32 = @floatFromInt(j);
    var k: i32 = 0;
    while (k < i) : (k += 1) {
        const f = (1.0 - @as(f32, @floatFromInt(k)) / fi) * fj;
        const l: i32 = @intFromFloat(@ceil(f));
        var dx1: i32 = -l;
        while (dx1 <= l) : (dx1 += 1) {
            const f1 = @as(f32, @floatFromInt(@abs(dx1))) - 0.25;
            var dz1: i32 = -l;
            while (dz1 <= l) : (dz1 += 1) {
                const f2 = @as(f32, @floatFromInt(@abs(dz1))) - 0.25;
                if ((dx1 != 0 or dz1 != 0) and f1 * f1 + f2 * f2 > f * f) continue;
                const interior = dx1 != -l and dx1 != l and dz1 != -l and dz1 != l;
                if (!interior and rand.nextFloat() > 0.75) continue;
                // Fused get+set: OOB reads air (replaceable) with no-op
                // set — same skip.
                if (view.idx(wx + dx1, y + k, wz + dz1)) |ix| {
                    if (isSpikeReplaceable(view.blocks[ix])) {
                        view.blocks[ix] = ids.packed_ice;
                        view.metas[ix] = 0;
                        view.markDirty(wx + dx1, wz + dz1);
                    }
                }
                if (k != 0 and l > 1) {
                    if (view.idx(wx + dx1, y - k, wz + dz1)) |ix| {
                        if (isSpikeReplaceable(view.blocks[ix])) {
                            view.blocks[ix] = ids.packed_ice;
                            view.metas[ix] = 0;
                            view.markDirty(wx + dx1, wz + dz1);
                        }
                    }
                }
            }
        }
    }
    // Base rays: clamped (j-1) radius columns sinking while replaceable
    // (y > 50 strict), segment length 50 (corners: nextInt(5)).
    var k1 = j - 1;
    if (k1 < 0) {
        k1 = 0;
    } else if (k1 > 1) {
        k1 = 1;
    }
    var l1: i32 = -k1;
    while (l1 <= k1) : (l1 += 1) {
        var dz2: i32 = -k1;
        while (dz2 <= k1) : (dz2 += 1) {
            var by = y - 1;
            var j2: i32 = 50;
            if (@abs(l1) == 1 and @abs(dz2) == 1) j2 = try rand.nextIntBound(5);
            while (by > 50) {
                // OOB reads air (ray-replaceable) with no-op set: skip the
                // cell but keep sinking — not a break.
                if (view.idx(wx + l1, by, wz + dz2)) |rix| {
                    if (!isSpikeRayReplaceable(view.blocks[rix])) break;
                    view.blocks[rix] = ids.packed_ice;
                    view.metas[rix] = 0;
                    view.markDirty(wx + l1, wz + dz2);
                }
                by -= 1;
                j2 -= 1;
                if (j2 <= 0) {
                    by -= try rand.nextIntBound(5) + 1;
                    j2 = try rand.nextIntBound(5);
                }
            }
        }
    }
    return true;
}

/// Ice patch (vanilla `arv`, WorldGenIcePath, radius 4 in BiomeGenSnow):
/// packed-ice disc (y±1) where ground is snow. Single RNG draw.
pub fn icePath(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32, radius: i32) !bool {
    var y = wy;
    if (view.colBase(wx, wz)) |base| {
        while (y > 2 and y < 256 and view.blocks[base + @as(usize, @intCast(y))] == ids.air) y -= 1;
    }
    if (view.get(wx, y, wz) != ids.snow) return false;
    const i = try rand.nextIntBound(radius - 2) + 2;
    // r2 hoisted (|i|<=6, no overflow); one bounds check per column, per-y
    // guard kept (y±1 can touch -1/256 on degenerate columns).
    const r2: i32 = i * i;
    var x: i32 = wx - i;
    while (x <= wx + i) : (x += 1) {
        const dx = x - wx;
        const dx2: i32 = dx * dx;
        var z: i32 = wz - i;
        while (z <= wz + i) : (z += 1) {
            const dz = z - wz;
            if (dx2 + dz * dz > r2) continue;
            const cbase = view.colBase(x, z) orelse continue;
            var yy: i32 = y - 1;
            while (yy <= y + 1) : (yy += 1) {
                if (yy < 0 or yy >= 256) continue;
                const ci: usize = cbase + @as(usize, @intCast(yy));
                const b = view.blocks[ci];
                if (b == ids.dirt or b == ids.snow or b == ids.ice) {
                    view.blocks[ci] = ids.packed_ice;
                    view.metas[ci] = 0;
                    view.markDirty(x, z);
                }
            }
        }
    }
    return true;
}

/// Big mushroom (`aru`, type -1 = random): space check, dirt/grass/mycelium
/// soil, stem + cap with per-cell meta. Cap block id follows type
/// (brown/red); stem meta is 10. Red caps dome over 4 layers, brown is a
/// single wide layer; below-top red layers place rim cells only (corners get
/// pore metas 1/3/7/9). Center-column meta 5 becomes 0 below the top layer.
pub fn bigMushroom(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32) !bool {
    const mtype: i32 = try rand.nextIntBound(2);
    const h: i32 = try rand.nextIntBound(3) + 4;
    if (wy < 1 or wy + h + 1 > 256) return false;
    var y: i32 = wy;
    while (y <= wy + 1 + h) : (y += 1) {
        if (y < 0 or y >= 256) return false;
        var rad: i32 = 1;
        if (y == wy) rad = 0;
        if (y >= wy + 1 + h - 2) rad = 2;
        var x: i32 = wx - rad;
        while (x <= wx + rad) : (x += 1) {
            var z: i32 = wz - rad;
            while (z <= wz + rad) : (z += 1) {
                const id = view.get(x, y, z);
                if (id != ids.air and id != ids.leaves and id != ids.leaves2) return false;
            }
        }
    }
    const soil = view.get(wx, wy - 1, wz);
    if (soil != ids.dirt and soil != ids.grass and soil != ids.mycelium) return false;
    if (wy >= 256 - h - 1) return false;
    const cap: ids.Id = if (mtype == 0) ids.brown_mushroom_block else ids.red_mushroom_block;
    const cap_top: i32 = wy + h;
    const cap_bot: i32 = if (mtype == 1) wy + h - 3 else wy + h;
    var yy: i32 = cap_bot;
    while (yy <= cap_top) : (yy += 1) {
        var rad: i32 = 1;
        if (yy < wy + h) rad = 2;
        if (mtype == 0) rad = 3;
        var x: i32 = wx - rad;
        while (x <= wx + rad) : (x += 1) {
            var z: i32 = wz - rad;
            while (z <= wz + rad) : (z += 1) {
                if (mtype == 1 and yy < wy + h) {
                    // Below-top red layers: rim only, no corners.
                    const on_rim_x = x == wx - rad or x == wx + rad;
                    const on_rim_z = z == wz - rad or z == wz + rad;
                    if (!on_rim_x and !on_rim_z) continue;
                    if (on_rim_x and on_rim_z) continue;
                }
                var meta: u8 = 5;
                if (x == wx - rad) meta -= 1;
                if (x == wx + rad) meta += 1;
                if (z == wz - rad) meta -= 3;
                if (z == wz + rad) meta += 3;
                if (meta == 5 and yy < wy + h) meta = 0;
                if (!isOpaque(view.get(x, yy, z))) view.set(x, yy, z, cap, meta);
            }
        }
    }
    // Stem with meta 10.
    var sy: i32 = 0;
    while (sy < h) : (sy += 1) {
        if (!isOpaque(view.get(wx, wy + sy, wz))) view.set(wx, wy + sy, wz, cap, 10);
    }
    return true;
}

// ---------------------------------------------------------------------------
// Per-biome decorator params (from `aia` defaults + biome overrides).
// ---------------------------------------------------------------------------

/// Trees per chunk (`ar.x`). Mutated (+128) use base. Roofed forest (29)
/// runs its own 4x4 canopy grid (`roofedGrid`, jar `aif` aF==3 branch);
/// the generic count stays -999 (zero iterations) so it can't double-plant.
/// Soil helpers for small-flora canStay checks (verified via Mats dump:
/// material h = water (ids 8,9), l = tallgrass/deadbush (31,32) + leaves2,
/// j = leaves (18,161), k = saplings/flowers/mushrooms/reeds/lily).
fn isWaterLike(id: ids.Id) bool {
    return id == ids.water or id == ids.flowing_water;
}

fn isSoilGrass(id: ids.Id) bool {
    return id == ids.grass or id == ids.dirt or id == ids.farmland;
}

fn isSoilOpaque(id: ids.Id) bool {
    return id != ids.air and id != ids.leaves and id != ids.leaves2 and !isWaterLike(id) and id != ids.flowing_lava and id != ids.lava;
}

fn isSoilDeadbush(id: ids.Id) bool {
    return id == ids.sand or id == ids.dirt or id == ids.hardened_clay or id == ids.stained_hardened_clay;
}

/// Snow-layer support (vanilla BlockSnow placement shape): leaves and full
/// snow layers hold snow; ice never does; otherwise the block must be an
/// opaque cube. Vegetation, glass, fluids and lava fail (this is what keeps
/// the snow/ice tail off tufts and mushrooms).
pub fn snowSupport(id: ids.Id, meta: u8) bool {
    if (id == ids.ice or id == ids.packed_ice) return false;
    if (id == ids.leaves or id == ids.leaves2) return true;
    if (id == ids.snow_layer) return meta == 7;
    return view_blocks.isOpaqueCube(id);
}

/// Soft one-cell flora the snow tail buries: vanilla heightMap skips
/// non-opaque flora, so snow lands where the tuft was. Saplings, reeds,
/// cacti and pumpkins keep their cells (snow must find real support
/// beside them, never on top).
fn isSoftFlora(id: ids.Id) bool {
    return id == ids.tallgrass or id == ids.yellow_flower or id == ids.red_flower or id == ids.brown_mushroom or id == ids.red_mushroom or id == ids.deadbush;
}

/// Mushroom soil (vanilla BlockMushroom stay rule): dirt, grass, mycelium.
fn isMushroomSoil(id: ids.Id) bool {
    return id == ids.grass or id == ids.dirt or id == ids.mycelium;
}

/// Skylight at (x,y,z) from block opacity above. Populate runs before
/// lighting, but skylight depends only on opacity (final by decorate
/// time), so flora light gates evaluate like vanilla's
/// `getFullBlockLightValue` skylight component (block light is zero
/// pre-lighting, same as vanilla at this stage).
fn skyLight(view: *const View, x: i32, y: i32, z: i32) u8 {
    // OOB column reads all-air (opacity 0): light stays 15, same as the
    // per-cell `get`→air walk below.
    const base = view.colBase(x, z) orelse return 15;
    var light: i32 = 15;
    var yy = y + 1;
    while (yy < 256) : (yy += 1) {
        if (yy < 0) continue; // OOB cell reads air (opacity 0)
        light -= chunk_mod.lightOpacity(view.blocks[base + @as(usize, @intCast(yy))]);
        if (light <= 0) return 0;
    }
    return @intCast(light);
}

/// Per-biome decorate counts (vanilla `aia` fields, jar-verified via Dec):
/// trees=x, flowers=y, grass=z, deadbush=A, shrooms=B, reeds=C, cactus=D,
/// lilies=w, bigshroom=H. `ex_hills` runs the emerald+silverfish extra phase
/// (`aid`). Lake gate uses the RAW biome id (vanilla compares instances:
/// only exact desert/desert-hills skip; mutated desert does not).
pub const DecorParams = struct {
    trees: i32 = 0,
    flowers: i32 = 2,
    grass: i32 = 1,
    deadbush: i32 = 0,
    shrooms: i32 = 0,
    reeds: i32 = 0,
    cactus: i32 = 0,
    lilies: i32 = 0,
    bigshroom: i32 = 0,
    ex_hills: bool = false,
};

pub fn decorParams(biome_id: i32) DecorParams {
    const b: i32 = if (biome_id >= 128) biome_id - 128 else biome_id;
    return switch (b) {
        1 => .{ .trees = -999, .flowers = 4, .grass = 10 }, // plains
        2 => .{ .trees = -999, .flowers = 2, .grass = 1, .deadbush = 2, .reeds = 50, .cactus = 10 }, // desert
        3 => .{ .ex_hills = true }, // extreme hills (+emerald/silverfish below)
        4 => .{ .trees = 10, .flowers = 2, .grass = 2 }, // forest
        5 => .{ .trees = 10, .flowers = 2, .grass = 1, .shrooms = 1 }, // taiga
        6 => .{ .lilies = 4, .trees = 2, .flowers = 1, .grass = 5, .deadbush = 1, .shrooms = 8, .reeds = 10 }, // swamp
        14, 15 => .{ .trees = -100, .flowers = -100, .grass = -100, .shrooms = 1, .bigshroom = 1 }, // mushroom (trees/flowers/grass all off)
        16 => .{ .trees = -999, .flowers = 2, .grass = 1, .deadbush = 2, .reeds = 50, .cactus = 10 }, // beach
        17 => .{ .trees = -999, .flowers = 2, .grass = 1, .deadbush = 2, .reeds = 50, .cactus = 10 }, // desert hills
        18 => .{ .trees = 10, .flowers = 2, .grass = 2 }, // forest hills
        19 => .{ .trees = 10, .flowers = 2, .grass = 1, .shrooms = 1 }, // taiga hills
        20 => .{ .trees = 3, .flowers = 2, .grass = 1, .ex_hills = true }, // extreme hills edge
        21, 22 => .{ .trees = 50, .flowers = 4, .grass = 25 }, // jungle
        23 => .{ .trees = 2, .flowers = 4, .grass = 25 }, // jungle edge
        25 => .{ .trees = -999 }, // stone beach
        26 => .{ .trees = -999, .flowers = 2, .grass = 1, .deadbush = 2, .reeds = 50, .cactus = 10 }, // cold beach
        27, 28 => .{ .trees = 10, .flowers = 2, .grass = 2 }, // birch forest / hills
        29 => .{ .trees = -999, .flowers = 2, .grass = 2 }, // roofed forest
        30, 31 => .{ .trees = 10, .flowers = 2, .grass = 1, .shrooms = 1 }, // cold taiga
        32, 33 => .{ .trees = 10, .flowers = 2, .grass = 7, .deadbush = 1, .shrooms = 3 }, // mega taiga
        34 => .{ .trees = 3, .flowers = 2, .grass = 1, .ex_hills = true }, // extreme hills+
        35, 36 => .{ .trees = 1, .flowers = 4, .grass = 20 }, // savanna
        37 => .{ .trees = -999, .flowers = 0, .grass = 1, .deadbush = 20, .reeds = 3, .cactus = 5 }, // mesa
        38 => .{ .trees = 5, .flowers = 0, .grass = 1, .deadbush = 20, .reeds = 3, .cactus = 5 }, // mesa plateau F
        39 => .{ .trees = -999, .flowers = 0, .grass = 1, .deadbush = 20, .reeds = 3, .cactus = 5 }, // mesa plateau
        else => .{},
    };
}

/// Flower (y-loop) type for one attempt: (block, meta). Plains: tulip patch
/// (octave noise < -0.8) else poppy/houstonia/daisy/dandelion. Base: 1/3
/// dandelion, 2/3 poppy. (alc.a = red flowers, alc.b = [dandelion].)
fn flowerType(rand: *java_random.JavaRandom, biome_id: i32, wx: i32, wz: i32, flower_noise: *const noise_mod.SimplexOctaves) !struct { id: ids.Id, meta: u8 } {
    const b: i32 = if (biome_id >= 128) biome_id - 128 else biome_id;
    if (b == 1) {
        if (flower_noise.eval(@as(f64, @floatFromInt(wx)) / 200.0, @as(f64, @floatFromInt(wz)) / 200.0) < -0.8) {
            const k = try rand.nextIntBound(4);
            return .{ .id = ids.red_flower, .meta = @intCast(4 + k) }; // tulips 4..7
        }
        if (try rand.nextIntBound(3) > 0) {
            const k = try rand.nextIntBound(3);
            return switch (k) {
                0 => .{ .id = ids.red_flower, .meta = 0 }, // poppy
                1 => .{ .id = ids.red_flower, .meta = 3 }, // houstonia
                else => .{ .id = ids.red_flower, .meta = 8 }, // oxeye daisy
            };
        }
        return .{ .id = ids.yellow_flower, .meta = 0 }; // dandelion
    }
    if (try rand.nextIntBound(3) == 0) return .{ .id = ids.yellow_flower, .meta = 0 }; // dandelion (alc.b[0])
    return .{ .id = ids.red_flower, .meta = 0 }; // poppy (alc.a[0])
}

/// Grass (z-loop) tallgrass meta: base 1; taiga family 1/6 fern (2);
/// jungle family 1/4 fern.
fn grassMeta(rand: *java_random.JavaRandom, biome_id: i32) !u8 {
    const b: i32 = if (biome_id >= 128) biome_id - 128 else biome_id;
    switch (b) {
        5, 19, 30, 31, 32, 33 => if (try rand.nextIntBound(5) <= 0) return 2,
        21, 22, 23 => if (try rand.nextIntBound(4) == 0) return 2,
        else => {},
    }
    return 1;
}

/// Generic 64-try flora scatter (`aro` shape): random walk ±8/±4, needs air
/// (+ always-sky overworld short-circuits vanilla's hasNoSky check), soil
/// gate below, then set.
fn scatterFlora(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32, id: ids.Id, meta: u8, soil: enum { grass_dirt, mushroom, deadbush_soil }) !void {
    var i: i32 = 0;
    while (i < 64) : (i += 1) {
        const x = wx + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        const y = wy + try rand.nextIntBound(4) - try rand.nextIntBound(4);
        const z = wz + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        if (!view.isAir(x, y, z)) continue;
        const below = view.get(x, y - 1, z);
        const ok = switch (soil) {
            // Vanilla BlockFlower stay rule (light 8+, else sky).
            .grass_dirt => isSoilGrass(below) and skyLight(view, x, y, z) >= 8,
            // Vanilla BlockMushroom stay rule (darkness, mycelium exempt).
            .mushroom => isMushroomSoil(below) and (below == ids.mycelium or skyLight(view, x, y, z) < 13),
            .deadbush_soil => isSoilDeadbush(below),
        };
        if (!ok) continue;
        view.set(x, y, z, id, meta);
    }
}

/// Tall-grass scatter (`asp` shape): sink through air/leaves first (no
/// draws), then 128 tries, air + soil gate, set.
fn scatterTallGrass(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32, meta: u8) !void {
    // Downscan with one bounds check: OOB columns read all-air, so the
    // scan sinks to 0 — same as the per-cell `get` walk.
    var y: i32 = 0;
    if (view.colBase(wx, wz)) |base| {
        y = wy;
        while (y > 0) {
            const id = view.blocks[base + @as(usize, @intCast(y))];
            if (id != ids.air and id != ids.leaves and id != ids.leaves2) break;
            y -= 1;
        }
    }
    var i: i32 = 0;
    while (i < 128) : (i += 1) {
        const x = wx + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        const yy = y + try rand.nextIntBound(4) - try rand.nextIntBound(4);
        const z = wz + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        if (!view.isAir(x, yy, z)) continue;
        if (!isSoilGrass(view.get(x, yy - 1, z))) continue;
        view.set(x, yy, z, ids.tallgrass, meta);
    }
}

/// Dead-bush scatter (`ark` shape): downscan past air/leaves, then 4 tries.
fn scatterDeadbush(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32) !void {
    // Same single-bounds downscan as scatterTallGrass (OOB sinks to 0,
    // then `y <= 0` returns — matching the all-air walk).
    var y: i32 = 0;
    if (view.colBase(wx, wz)) |base| {
        y = wy;
        while (y > 0) {
            const id = view.blocks[base + @as(usize, @intCast(y))];
            if (id != ids.air and id != ids.leaves and id != ids.leaves2) break;
            y -= 1;
        }
    }
    if (y <= 0) return;
    var i: i32 = 0;
    while (i < 4) : (i += 1) {
        const x = wx + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        const yy = y + try rand.nextIntBound(4) - try rand.nextIntBound(4);
        const z = wz + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        if (!view.isAir(x, yy, z)) continue;
        if (!isSoilDeadbush(view.get(x, yy - 1, z))) continue;
        view.set(x, yy, z, ids.deadbush, 0);
    }
}

/// Reed clump (`ash` shape): 20 tries ±4 (y fixed), air + any-of-4-below is
/// water-like, height 2+nextInt(nextInt(3)+1), per-level canStay.
fn reedClump(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32) !void {
    var i: i32 = 0;
    while (i < 20) : (i += 1) {
        const x = wx + try rand.nextIntBound(4) - try rand.nextIntBound(4);
        const z = wz + try rand.nextIntBound(4) - try rand.nextIntBound(4);
        if (!view.isAir(x, wy, z)) continue;
        if (!isWaterLike(view.get(x - 1, wy - 1, z)) and !isWaterLike(view.get(x + 1, wy - 1, z)) and
            !isWaterLike(view.get(x, wy - 1, z - 1)) and !isWaterLike(view.get(x, wy - 1, z + 1))) continue;
        const h = 2 + try rand.nextIntBound(try rand.nextIntBound(3) + 1);
        var k: i32 = 0;
        while (k < h) : (k += 1) {
            if (reedCanStay(view, x, wy + k, z)) view.set(x, wy + k, z, ids.reeds_block, 0);
        }
    }
}

fn reedCanStay(view: *const View, x: i32, y: i32, z: i32) bool {
    const below = view.get(x, y - 1, z);
    if (below == ids.reeds_block) return true;
    if (below != ids.grass and below != ids.dirt and below != ids.sand) return false;
    return isWaterLike(view.get(x - 1, y, z)) or isWaterLike(view.get(x + 1, y, z)) or
        isWaterLike(view.get(x, y, z - 1)) or isWaterLike(view.get(x, y, z + 1));
}

/// Cactus clump (`arh` shape): 10 tries ±8/±4, air, height 1+nextInt(nextInt(3)+1),
/// per-level canStay (sand/cactus below + air neighbors).
fn cactusClump(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32) !void {
    var i: i32 = 0;
    while (i < 10) : (i += 1) {
        const x = wx + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        const y = wy + try rand.nextIntBound(4) - try rand.nextIntBound(4);
        const z = wz + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        if (!view.isAir(x, y, z)) continue;
        const h = 1 + try rand.nextIntBound(try rand.nextIntBound(3) + 1);
        var k: i32 = 0;
        while (k < h) : (k += 1) {
            if (cactusCanStay(view, x, y + k, z)) view.set(x, y + k, z, ids.cactus, 0);
        }
    }
}

fn cactusCanStay(view: *const View, x: i32, y: i32, z: i32) bool {
    const below = view.get(x, y - 1, z);
    if (below != ids.cactus and below != ids.sand) return false;
    if (!view.isAir(x - 1, y, z) or !view.isAir(x + 1, y, z) or
        !view.isAir(x, y, z - 1) or !view.isAir(x, y, z + 1)) return false;
    return true;
}

/// Pumpkin patch (`asg` shape): 64 tries ±8/±4, air + grass below +
/// canPlace, facing = nextInt(4).
fn pumpkinPatch(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32) !void {
    var i: i32 = 0;
    while (i < 64) : (i += 1) {
        const x = wx + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        const y = wy + try rand.nextIntBound(4) - try rand.nextIntBound(4);
        const z = wz + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        if (!view.isAir(x, y, z)) continue;
        if (view.get(x, y - 1, z) != ids.grass) continue;
        // canPlaceBlockAt (pumpkin): below solid-opaque; grass qualifies.
        view.set(x, y, z, ids.pumpkin, @intCast(try rand.nextIntBound(4)));
    }
}

/// Water-lily patch (`aiz` shape with the w-loop downscan done by caller):
/// 10 tries ±8/±4, air, below is water.
fn lilyPatch(view: *View, rand: *java_random.JavaRandom, wx: i32, wy: i32, wz: i32) !void {
    var i: i32 = 0;
    while (i < 10) : (i += 1) {
        const x = wx + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        const y = wy + try rand.nextIntBound(4) - try rand.nextIntBound(4);
        const z = wz + try rand.nextIntBound(8) - try rand.nextIntBound(8);
        if (!view.isAir(x, y, z)) continue;
        if (!isWaterLike(view.get(x, y - 1, z))) continue;
        view.set(x, y, z, ids.waterlily, 0);
    }
}

/// Downscan for the lily loop (`aia` w-loop): sink while the block below is
/// AIR (vanilla checks `ahb.c`, not opacity — water stops the scan).
fn lilyGroundY(view: *const View, wx: i32, wy: i32, wz: i32) i32 {
    // Same single-bounds downscan (OOB `isAir` is false: no iterations).
    var y = wy;
    if (view.colBase(wx, wz)) |base| {
        while (y > 0 and view.blocks[base + @as(usize, @intCast(y - 1))] == ids.air) y -= 1;
    }
    return y;
}

/// Standard ore loop (`aia.a` helper): `count` veins, x/z = base+nextInt16
/// (no +8), y = nextInt(range)+min.
fn oreVein(view: *View, rand: *java_random.JavaRandom, base_x: i32, base_z: i32, count: i32, ore: ids.Id, size: i32, y_min: i32, y_max: i32) !void {
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const nx: i32 = base_x + try rand.nextIntBound(16);
        const ny: i32 = try rand.nextIntBound(y_max - y_min) + y_min;
        const nz: i32 = base_z + try rand.nextIntBound(16);
        try minable(view, rand, nx, ny, nz, ore, size, ids.stone);
    }
}

/// Frozen (snowy) base biomes for the populate snow/ice pass.
fn isFrozenBiome(b: i32) bool {
    return b == 10 or b == 11 or b == 12 or b == 13 or b == 30 or b == 31;
}

pub fn treesPerChunk(biome_id: i32) i32 {
    const b: i32 = if (biome_id >= 128) biome_id - 128 else biome_id;
    return switch (b) {
        1 => -999, // plains
        2 => -999, // desert
        3 => 0, // extreme hills
        4 => 10, // forest
        5 => 10, // taiga
        6 => 2, // swamp
        12 => 0, // ice plains (default 0; spikes are custom, no trees)
        14, 15 => -100, // mushroom
        16 => -999, // beach
        17 => -999, // desert hills
        18 => 10, // forest hills
        19 => 10, // taiga hills
        20 => 3, // extreme hills edge (bl=true)
        21, 22 => 50, // jungle / jungle hills
        23 => 2, // jungle edge
        25 => -999, // stone beach
        26 => -999, // cold beach
        27, 28 => 10, // birch forest / hills
        29 => -999, // roofed forest (own 4x4 grid; generic loop stays empty)
        30, 31 => 10, // cold taiga
        32, 33 => 10, // mega taiga
        34 => 3, // extreme hills+ (bl=true)
        35, 36 => 1, // savanna / plateau
        37 => -999, // mesa
        38 => 5, // mesa plateau F (bl2=true)
        39 => -999, // mesa plateau
        else => 0, // ocean, river, hell, sky, frozen, etc.
    };
}

/// Sand/clay/gravel disk counts (F/G/E). Only swamp differs from 3/1/1.
pub fn diskCounts(biome_id: i32) struct { sand: i32, clay: i32, gravel: i32 } {
    const b: i32 = if (biome_id >= 128) biome_id - 128 else biome_id;
    if (b == 6) return .{ .sand = 0, .clay = 1, .gravel = 0 }; // swamp
    return .{ .sand = 3, .clay = 1, .gravel = 1 };
}

pub const TreeKind = enum { oak, birch, spruce, swamp, jungle_oak, canopy };

/// Tree type selection per biome (replicates `ahu.a` draws; approximations
/// documented in module header). Returns kind; caller generates.
/// For jungle oak, caller must ALSO draw `nextInt(7)` for height (done in
/// `genJungleOak` wrapper to keep call sites clean).
pub fn selectTree(rand: *java_random.JavaRandom, biome_id: i32) !TreeKind {
    const b: i32 = if (biome_id >= 128) biome_id - 128 else biome_id;
    switch (b) {
        4, 18 => { // forest / hills: 20% birch
            if (try rand.nextIntBound(5) == 0) return .birch;
            return .oak;
        },
        27, 28 => return .birch, // birch forest: always birch, no draw
        5, 19, 30, 31 => { // taiga: nextInt3==0 -> pine else nextInt3 (pine/spruce); all spruce here
            if (try rand.nextIntBound(3) == 0) return .spruce;
            _ = try rand.nextIntBound(3);
            return .spruce;
        },
        32, 33 => { // mega taiga: same shape (aH==2/nextInt13 is dead in vanilla — aH is only 0/1)
            if (try rand.nextIntBound(3) == 0) return .spruce;
            _ = try rand.nextIntBound(3);
            return .spruce;
        },
        6 => return .swamp, // swamp: always aso, no draw
        21, 22, 23 => { // jungle: big/arp/arz/jungle-oak
            if (try rand.nextIntBound(10) == 0) return .oak; // big->oak approx
            if (try rand.nextIntBound(2) == 0) return .oak; // arp->oak approx
            if (b != 23) { // non-edge: 1/3 arz
                if (try rand.nextIntBound(3) == 0) return .oak; // arz->oak approx
            }
            return .jungle_oak;
        },
        35, 36 => { // savanna: 1/5 oak, 4/5 acacia->oak (one draw either way)
            _ = try rand.nextIntBound(5);
            return .oak;
        },
        29 => { // roofed forest: 2/3 canopy, else 1/5 birch else oak (jar aif.a)
            if (try rand.nextIntBound(3) > 0) return .canopy;
            if (try rand.nextIntBound(5) == 0) return .birch;
            return .oak;
        },
        3, 20, 34 => { // extreme hills: 1/3 spruce else base select (10% big->oak, 90% oak)
            if (try rand.nextIntBound(3) == 0) return .spruce;
            _ = try rand.nextIntBound(10);
            return .oak;
        },
        else => { // base: 10% big->oak, 90% oak (draw consumed)
            _ = try rand.nextIntBound(10);
            return .oak;
        },
    }
}

// ---------------------------------------------------------------------------
// Chunk populate (ores + disks + trees) with populate-style seeding.
// ---------------------------------------------------------------------------

/// Seed a chunk's decorator RNG (matches `aqz.populate` mixing).
/// Structures draw zero populate-RNG (own ChunkRand streams), so skipping
/// block placement does not desync the stream; lakes/dungeons/ores below
/// run in vanilla order.
pub fn seedForChunk(rand: *java_random.JavaRandom, world_seed: i64, cx: i32, cz: i32) void {
    rand.setSeed(world_seed);
    // Bulk two-draw longs: bit-identical to nextLong (affine A2/C2 form).
    const l: i64 = @divTrunc(rand.nextLongFast(), 2) * 2 + 1;
    const l1: i64 = @divTrunc(rand.nextLongFast(), 2) * 2 + 1;
    rand.setSeed(cx *% l +% cz *% l1 ^ world_seed);
}

/// Run one chunk's populate into `view` (48x48 or larger, covering base).
/// `heights` is caller-owned scratch (sx*sz) threaded through for API
/// stability; nothing reads it — `heightAt` scans the column LIVE (topmost
/// non-air), matching vanilla `ahb.f` which reads the live world per
/// attempt (a stale snapshot reused across phases shifts downstream
/// `nextInt` bounds and breaks parity).
/// `biome_id` is the chunk's biome (at center+8, voronoi).
/// `win_bio` is the per-column voronoi biome over the populate window
/// (base+8..base+23, row-major `dx*16+dz`): the snow/ice tail gates each
/// column on its own biome (vanilla `World.r`/`World.e` check the column's
/// biome temperature < 0.15), NOT on the chunk-center biome. Gating the
/// whole window on one biome freezes ocean/beach columns whenever any
/// frozen biome sits in the window — an 8-wide ice square spilling across
/// the border (vanilla leaves those columns water).
/// `flower_noise` is the plains tulip-patch octave (seed 2345, 1 octave).
/// Writes outside `view` are dropped by View bounds checks.
///
/// Vanilla order (`aqz.populate` + `aia` decorate), jar-verified:
/// structures (detection only — placement is the next phase, zero populate
/// draws) → water lake → lava lake → dungeons → ice spikes/paths (id 140
/// only) → ores → disks → trees →
/// bigshroom → flora → grass → deadbush → lilies → shrooms → reeds →
/// pumpkin → cactus → springs → exHills extras → snow/ice.
pub fn populateOne(
    view: *View,
    heights: []i32, // sx*sz, same layout as blocks (x*sz+z)
    rand: *java_random.JavaRandom,
    flower_noise: *const noise_mod.SimplexOctaves,
    base_x: i32, // chunk base world x (cx*16)
    base_z: i32,
    biome_id: i32,
    win_bio: [256]i32,
) !void {
    const b: i32 = if (biome_id >= 128) biome_id - 128 else biome_id;
    const p = decorParams(b);
    // -- structures (MapGen): detection only for now (own ChunkRand streams,
    // zero populate draws). Full block placement is the next phase; chunks
    // with structures nearby will shift ore positions then (documented).
    // Vanilla also suppresses both lakes near strongholds; assumed absent
    // (no stronghold detection yet — same phase as placement).
    // -- surface lakes.
    if (biome_id != 2 and biome_id != 17 and try rand.nextIntBound(4) == 0) {
        const wx = try spot8(rand, base_x);
        const wy: i32 = try rand.nextIntBound(256);
        const wz = try spot8(rand, base_z);
        _ = try lakeGen(view, rand, wx, wy, wz, ids.water, isFrozenBiome(b));
    }
    if (try rand.nextIntBound(8) == 0) {
        const wx = try spot8(rand, base_x);
        const wy: i32 = try rand.nextIntBound(try rand.nextIntBound(248) + 8);
        const wz = try spot8(rand, base_z);
        if (wy < 63 or try rand.nextIntBound(10) == 0) {
            _ = try lakeGen(view, rand, wx, wy, wz, ids.lava, isFrozenBiome(b));
        }
    }
    // -- dungeons (8 attempts; loot draws deferred with placement — blocks only).
    {
        var i: i32 = 0;
        while (i < 8) : (i += 1) {
            const wx = try spot8(rand, base_x);
            const wy: i32 = try rand.nextIntBound(256);
            const wz = try spot8(rand, base_z);
            _ = try dungeonGen(view, rand, wx, wy, wz);
        }
    }
    // NOTE: no height snapshot here — `heightAt` reads the live world per
    // attempt (vanilla `ahb.f`); a `computeHeights` snapshot would be dead.
    // Ice spikes + ice paths (BiomeGenSnow spikes variant, id 140: `aij.a`
    // runs 3x IceSpike + 2x IcePath(4) BEFORE super.decorate; base ice
    // plains (12) skips. Gated on the raw biome id, not the base).
    if (biome_id == 140) {
        var s: i32 = 0;
        while (s < 3) : (s += 1) {
            const sp = try surfaceSpot(view, heights, rand, base_x, base_z);
            _ = try iceSpike(view, rand, sp.x, sp.y, sp.z);
        }
        s = 0;
        while (s < 2) : (s += 1) {
            const sp = try surfaceSpot(view, heights, rand, base_x, base_z);
            _ = try icePath(view, rand, sp.x, sp.y, sp.z, 4);
        }
    }
    // Roofed forest canopy grid (vanilla `aif.a` aF==3 branch, jar-verified
    // CFR 0.152): 16 cells per chunk on a fixed 4x4 grid
    // (base+i*4+9+jitter(3)), each either a big mushroom (1/20) or a
    // canopy (2/3) / birch (1/15) / oak (4/15). Runs BEFORE ores/disks
    // like vanilla (the grid is in BiomeGenForest.decorate; super.decorate
    // does the rest). The generic tree loop below stays empty for 29
    // (trees=-999).
    if (b == 29) try roofedGrid(view, heights, rand, base_x, base_z);
    // Ores (universal, no +8 offset).
    try oreVein(view, rand, base_x, base_z, 20, ids.dirt, 32, 0, 256);
    try oreVein(view, rand, base_x, base_z, 10, ids.gravel, 32, 0, 256);
    try oreVein(view, rand, base_x, base_z, 20, ids.coal_ore, 16, 0, 128);
    try oreVein(view, rand, base_x, base_z, 20, ids.iron_ore, 8, 0, 64);
    try oreVein(view, rand, base_x, base_z, 2, ids.gold_ore, 8, 0, 32);
    try oreVein(view, rand, base_x, base_z, 8, ids.redstone_ore, 7, 0, 16);
    try oreVein(view, rand, base_x, base_z, 1, ids.diamond_ore, 7, 0, 16);
    // Lapis (triangular via b(); no +8 offset, like the `a()` helper).
    {
        const nx = try spot16(rand, base_x);
        const ny: i32 = try rand.nextIntBound(16) + try rand.nextIntBound(16);
        const nz = try spot16(rand, base_z);
        // NOTE: no +8 offset (matches `a()` helper, unlike trees/disks).
        try minable(view, rand, nx, ny, nz, ids.lapis_ore, 6, ids.stone);
    }
    // Sand / clay / gravel disks (+8 offset, wy ~= i() ~= top+1, documented).
    const disks = diskCounts(biome_id);
    var i: i32 = 0;
    while (i < disks.sand) : (i += 1) {
        const sp = try surfaceSpot(view, heights, rand, base_x, base_z);
        _ = try sandDisk(view, rand, sp.x, sp.y, sp.z, ids.sand, 7);
    }
    i = 0;
    while (i < disks.clay) : (i += 1) {
        const sp = try surfaceSpot(view, heights, rand, base_x, base_z);
        _ = try clayDisk(view, rand, sp.x, sp.y, sp.z);
    }
    i = 0;
    while (i < disks.gravel) : (i += 1) {
        const sp = try surfaceSpot(view, heights, rand, base_x, base_z);
        _ = try sandDisk(view, rand, sp.x, sp.y, sp.z, ids.gravel, 6);
    }
    // Trees (+8 offset, base wy = f() = top+1, per-biome count + selection).
    var n5: i32 = p.trees;
    if (try rand.nextIntBound(10) == 0) n5 += 1;
    var t: i32 = 0;
    while (t < n5) : (t += 1) {
        const sp = try surfaceSpot(view, heights, rand, base_x, base_z);
        const wx = sp.x;
        const wz = sp.z;
        const wy = sp.y;
        const kind = try selectTree(rand, biome_id);
        switch (kind) {
            .oak => _ = try oakTree(view, rand, wx, wy, wz, 4, 0, 0, false, false),
            .birch => _ = try birchTree(view, rand, wx, wy, wz, false),
            .spruce => _ = try spruceTree(view, rand, wx, wy, wz),
            .swamp => _ = try swampTree(view, rand, wx, wy, wz),
            .jungle_oak => {
                const h_extra: i32 = try rand.nextIntBound(7);
                _ = try oakTree(view, rand, wx, wy, wz, 4 + h_extra, 3, 3, true, true);
            },
            .canopy => _ = try canopyTree(view, rand, wx, wy, wz),
        }
    }
    // Big mushrooms (H; mushroom isles only in practice).
    i = 0;
    while (i < p.bigshroom) : (i += 1) {
        const sp = try surfaceSpot(view, heights, rand, base_x, base_z);
        _ = try bigMushroom(view, rand, sp.x, sp.y, sp.z);
    }
    // Flowers (y): wy = nextInt(f + 32) with f = top + 1.
    i = 0;
    while (i < p.flowers) : (i += 1) {
        const sp = try surfaceSpot(view, heights, rand, base_x, base_z);
        const wy = try rand.nextIntBound(@intCast(sp.y + 32));
        const ft = try flowerType(rand, biome_id, sp.x, sp.z, flower_noise);
        try scatterFlora(view, rand, sp.x, wy, sp.z, ft.id, ft.meta, .grass_dirt);
    }
    // Tall grass (z): wy = nextInt(f * 2), per-biome meta.
    i = 0;
    while (i < p.grass) : (i += 1) {
        const sp = try surfaceSpot(view, heights, rand, base_x, base_z);
        const wy = try rand.nextIntBound(@intCast(sp.y * 2));
        const meta = try grassMeta(rand, biome_id);
        try scatterTallGrass(view, rand, sp.x, wy, sp.z, meta);
    }
    // Dead bushes (A): wy = nextInt(f * 2).
    i = 0;
    while (i < p.deadbush) : (i += 1) {
        const sp = try surfaceSpot(view, heights, rand, base_x, base_z);
        const wy = try rand.nextIntBound(@intCast(sp.y * 2));
        try scatterDeadbush(view, rand, sp.x, wy, sp.z);
    }
    // Water lilies (w): wy = nextInt(f * 2), then sink through air only.
    i = 0;
    while (i < p.lilies) : (i += 1) {
        const sp = try surfaceSpot(view, heights, rand, base_x, base_z);
        const wy0 = try rand.nextIntBound(@intCast(sp.y * 2));
        const wy = lilyGroundY(view, sp.x, wy0, sp.z);
        try lilyPatch(view, rand, sp.x, wy, sp.z);
    }
    // Mushrooms (B loop + two standalone patches; brown=q, red=r).
    // Every patch attempt draws wy = nextInt(f * 2).
    i = 0;
    while (i < p.shrooms) : (i += 1) {
        if (try rand.nextIntBound(4) == 0) {
            const sp = try surfaceSpot(view, heights, rand, base_x, base_z);
            try scatterFlora(view, rand, sp.x, try rand.nextIntBound(@intCast(sp.y * 2)), sp.z, ids.brown_mushroom, 0, .mushroom);
        }
        if (try rand.nextIntBound(8) == 0) {
            const sp = try surfaceSpot(view, heights, rand, base_x, base_z);
            try scatterFlora(view, rand, sp.x, try rand.nextIntBound(@intCast(sp.y * 2)), sp.z, ids.red_mushroom, 0, .mushroom);
        }
    }
    if (try rand.nextIntBound(4) == 0) {
        const sp = try surfaceSpot(view, heights, rand, base_x, base_z);
        try scatterFlora(view, rand, sp.x, try rand.nextIntBound(@intCast(sp.y * 2)), sp.z, ids.brown_mushroom, 0, .mushroom);
    }
    if (try rand.nextIntBound(8) == 0) {
        const sp = try surfaceSpot(view, heights, rand, base_x, base_z);
        try scatterFlora(view, rand, sp.x, try rand.nextIntBound(@intCast(sp.y * 2)), sp.z, ids.red_mushroom, 0, .mushroom);
    }
    // Reeds (C loop + unconditional 10 attempts; wy = nextInt(f * 2)).
    i = 0;
    while (i < p.reeds) : (i += 1) {
        const sp = try surfaceSpot(view, heights, rand, base_x, base_z);
        const wy = try rand.nextIntBound(@intCast(sp.y * 2));
        try reedClump(view, rand, sp.x, wy, sp.z);
    }
    i = 0;
    while (i < 10) : (i += 1) {
        const sp = try surfaceSpot(view, heights, rand, base_x, base_z);
        const wy = try rand.nextIntBound(@intCast(sp.y * 2));
        try reedClump(view, rand, sp.x, wy, sp.z);
    }
    // Pumpkin patch (1/32): wy = nextInt(f * 2).
    if (try rand.nextIntBound(32) == 0) {
        const sp = try surfaceSpot(view, heights, rand, base_x, base_z);
        const wy = try rand.nextIntBound(@intCast(sp.y * 2));
        try pumpkinPatch(view, rand, sp.x, wy, sp.z);
    }
    // Cactus (D): wy = nextInt(f * 2).
    i = 0;
    while (i < p.cactus) : (i += 1) {
        const sp = try surfaceSpot(view, heights, rand, base_x, base_z);
        const wy = try rand.nextIntBound(@intCast(sp.y * 2));
        try cactusClump(view, rand, sp.x, wy, sp.z);
    }
    // Underground springs (always on, gated by `I` which is always true in
    // vanilla biomes; water 50x then lava 20x).
    i = 0;
    while (i < 50) : (i += 1) {
        const wx = try spot8(rand, base_x);
        const wy: i32 = try rand.nextIntBound(try rand.nextIntBound(248) + 8);
        const wz = try spot8(rand, base_z);
        _ = try springGen(view, rand, wx, wy, wz, ids.flowing_water);
    }
    i = 0;
    while (i < 20) : (i += 1) {
        const wx = try spot8(rand, base_x);
        const wy: i32 = try rand.nextIntBound(try rand.nextIntBound(try rand.nextIntBound(240) + 8) + 8);
        const wz = try spot8(rand, base_z);
        _ = try springGen(view, rand, wx, wy, wz, ids.flowing_lava);
    }
    // Extreme-hills extras (after base decorate, like `aid`).
    if (p.ex_hills) {
        // Emerald singles: 3+nextInt(6), y=nextInt(28)+4, below must be stone.
        const n_em = 3 + try rand.nextIntBound(6);
        var e: i32 = 0;
        while (e < n_em) : (e += 1) {
            const nx = try spot16(rand, base_x);
            const ny: i32 = try rand.nextIntBound(28) + 4;
            const nz = try spot16(rand, base_z);
            if (view.get(nx, ny - 1, nz) == ids.stone) view.set(nx, ny, nz, ids.emerald_ore, 0);
        }
        // Silverfish veins: 7x minable(monster_egg, 8), y=nextInt(64).
        var ss: i32 = 0;
        while (ss < 7) : (ss += 1) {
            const nx = try spot16(rand, base_x);
            const ny: i32 = try rand.nextIntBound(64);
            const nz = try spot16(rand, base_z);
            try minable(view, rand, nx, ny, nz, ids.monster_egg, 8, ids.stone);
        }
    }
    // Snow + ice (behavioral port of the populate tail: per-column frozen
    // check, matching vanilla `World.r`/`World.e` which gate each column on
    // its own biome temperature < 0.15; light checks skipped — populate runs
    // before lighting, same as vanilla).
    {
        var dx: i32 = 0;
        while (dx < 16) : (dx += 1) {
            var dz: i32 = 0;
            while (dz < 16) : (dz += 1) {
                if (!isFrozenBiome(win_bio[@as(usize, @intCast(dx * 16 + dz))])) continue;
                const wx: i32 = base_x + 8 + dx;
                const wz: i32 = base_z + 8 + dz;
                const top = heightAt(view, heights, wx, wz);
                const tid = view.get(wx, top, wz);
                if (isWaterLike(tid)) {
                    view.set(wx, top, wz, ids.ice, 0);
                } else if (isSoftFlora(tid) and top > 0 and snowSupport(view.get(wx, top - 1, wz), view.getMeta(wx, top - 1, wz))) {
                    // Buried tuft (vanilla heightMap skips flora): snow
                    // replaces it, supported by the soil below.
                    view.set(wx, top, wz, ids.snow_layer, 0);
                } else if (view.isAir(wx, top + 1, wz) and snowSupport(tid, view.getMeta(wx, top, wz))) {
                    view.set(wx, top + 1, wz, ids.snow_layer, 0);
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Populate spot helpers: every decorate attempt below picks spots from the
// same two RNG streams, in x-then-z draw order. Helpers keep that order
// identical (draw order advances the shared chunk rand — reordering draws
// shifts every downstream placement and breaks JVM parity).
// ---------------------------------------------------------------------------

/// One horizontal decorate coordinate: chunk base + nextInt(16) + 8
/// (vanilla tree/disk/flower/lake placement).
fn spot8(rand: *java_random.JavaRandom, base: i32) !i32 {
    return base + try rand.nextIntBound(16) + 8;
}

/// One horizontal ore coordinate: chunk base + nextInt(16), no offset
/// (vanilla ore/emerald/silverfish placement).
fn spot16(rand: *java_random.JavaRandom, base: i32) !i32 {
    return base + try rand.nextIntBound(16);
}

pub const Spot = struct { x: i32, y: i32, z: i32 };

/// Surface spot: random X/Z plus live top+1 (tree/disk/flower base).
fn surfaceSpot(view: *View, heights: []i32, rand: *java_random.JavaRandom, base_x: i32, base_z: i32) !Spot {
    const wx = try spot8(rand, base_x);
    const wz = try spot8(rand, base_z);
    return .{ .x = wx, .y = heightAt(view, heights, wx, wz) + 1, .z = wz };
}

// ---------------------------------------------------------------------------
// 3x3 decorate: isolated per-chunk populates merged in fixed order.
// ---------------------------------------------------------------------------

/// Surface height lookup (world coords via view). Scans the column LIVE
/// (topmost non-air), matching vanilla `ahb.f` which reads the live world
/// per attempt — flowers/trees/grass placed earlier in the same populate
/// raise the surface for later attempts. (A stale snapshot reused across
/// phases shifts every downstream `nextInt` bound and breaks parity.)
fn heightAt(view: *const View, heights: []const i32, wx: i32, wz: i32) i32 {
    _ = heights;
    const base = view.colBase(wx, wz) orelse return SEA_Y;
    var y: i32 = 255;
    while (y >= 0) : (y -= 1) {
        if (view.blocks[base + @as(usize, @intCast(y))] != ids.air) return y;
    }
    return 0;
}

pub const SEA_Y: i32 = 63;

/// Compute surface heights (topmost non-air) for a view. Layout matches
/// blocks: heights[x*sz+z].
pub fn computeHeights(view: *const View, heights: []i32) void {
    var x: usize = 0;
    while (x < view.sx) : (x += 1) {
        var z: usize = 0;
        while (z < view.sz) : (z += 1) {
            var top: i32 = 0;
            var y: i32 = 255;
            while (y >= 0) : (y -= 1) {
                const i = (x * view.sz + z) * 256 + @as(usize, @intCast(y));
                if (view.blocks[i] != ids.air) {
                    top = y;
                    break;
                }
            }
            heights[x * view.sz + z] = top;
        }
    }
}

/// Decorate center chunk (cx,cz) in `view` (must cover (cx-1..cx+1) chunks,
/// i.e. 48x48 with ox=(cx-1)*16). `biomeAt` returns voronoi biome id at
/// world (x,z). Heights are recomputed per run after lakes/dungeons.
pub fn decorateCenter(
    view: *View,
    world_seed: i64,
    cx: i32,
    cz: i32,
    chain: *genlayer_mod.Chain,
    root_voronoi: u32,
    scratch: std.mem.Allocator,
) !void {
    const n = view.sx * 256 * view.sz;
    const base_blocks = try scratch.alloc(ids.Id, n);
    defer scratch.free(base_blocks);
    const base_metas = try scratch.alloc(u8, n);
    defer scratch.free(base_metas);
    @memcpy(base_blocks, view.blocks[0..n]);
    @memcpy(base_metas, view.metas[0..n]);
    const work_blocks = try scratch.alloc(ids.Id, n);
    defer scratch.free(work_blocks);
    const work_metas = try scratch.alloc(u8, n);
    defer scratch.free(work_metas);
    var work = View{ .blocks = work_blocks, .metas = work_metas, .ox = view.ox, .oz = view.oz, .sx = view.sx, .sz = view.sz, .ore_cache = view.ore_cache };
    var rand = java_random.JavaRandom.init(0);
    // Plains tulip-patch octave (vanilla `new awl(new Random(2345), 1)`).
    var flower_rand = java_random.JavaRandom.init(2345);
    var flower_noise = try noise_mod.SimplexOctaves.init(scratch, &flower_rand, 1);
    defer flower_noise.deinit();
    const run_heights = try scratch.alloc(i32, view.sx * view.sz);
    defer scratch.free(run_heights);
    // Per-column voronoi for the snow/ice tail (one fetch for the whole
    // 48x48 view; each run slices its 16x16 populate window). The tail
    // gates every column on its own biome (vanilla `World.r`/`World.e`);
    // a single center biome per window would freeze warm columns.
    const bio48 = try scratch.alloc(i32, view.sx * view.sz);
    defer scratch.free(bio48);
    try chain.getInts(scratch, root_voronoi, view.ox, view.oz, view.sx, view.sz, bio48);
    // Fixed order: 8 neighbors (sorted dz,dx) then center last.
    var order: [9]struct { dx: i32, dz: i32 } = undefined;
    var k: usize = 0;
    var dz: i32 = -1;
    while (dz <= 1) : (dz += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            if (dx == 0 and dz == 0) continue;
            order[k] = .{ .dx = dx, .dz = dz };
            k += 1;
        }
    }
    order[8] = .{ .dx = 0, .dz = 0 };
    // Sparse reset/merge: one pristine work copy + per-run dirty-group
    // restore (no per-write tracking needed). Merge still compares work vs
    // pristine base (not vs view), so a cell written then restored to
    // pristine never clobbers an earlier populate's merged result.
    // Independent block/meta comparisons are preserved exactly.
    @memcpy(work_blocks, base_blocks);
    @memcpy(work_metas, base_metas);
    const dirty_b = try scratch.alloc(usize, n / 4 + 1);
    defer scratch.free(dirty_b);
    const dirty_m = try scratch.alloc(usize, n / 8 + 1);
    defer scratch.free(dirty_m);
    for (order) |o| {
        const nx = cx + o.dx;
        const nz = cz + o.dz;
        seedForChunk(&rand, world_seed, nx, nz);
        // Center biome straight from the prefetched 48-wide voronoi window
        // (same chain, same root, same coords as biomeAt's 1x1 fetch —
        // identical value, no second chain eval). lx/lz land on {8,24,40}
        // by construction ((nx-cx+1)*16+8 for nx-cx in -1..1).
        const blx: usize = @intCast(nx * 16 + 8 - view.ox);
        const blz: usize = @intCast(nz * 16 + 8 - view.oz);
        std.debug.assert(blx < view.sx and blz < view.sz);
        const biome: i32 = bio48[blx + blz * view.sx];
        // Populate window [nx*16+8, nx*16+23]^2 in view-local coords;
        // out-of-view cells fall back to the center biome (their writes
        // are dropped by View bounds checks anyway).
        var win_bio: [256]i32 = undefined;
        const lx0: i32 = nx * 16 + 8 - view.ox;
        const lz0: i32 = nz * 16 + 8 - view.oz;
        var wdx: usize = 0;
        while (wdx < 16) : (wdx += 1) {
            // lx-part of the bounds test hoisted per row (wdx-invariant).
            const lx: i32 = lx0 + @as(i32, @intCast(wdx));
            const ok_x = lx >= 0 and lx < @as(i32, @intCast(view.sx));
            const uxl: usize = @intCast(@max(lx, 0));
            var wdz: usize = 0;
            while (wdz < 16) : (wdz += 1) {
                const lz: i32 = lz0 + @as(i32, @intCast(wdz));
                win_bio[wdx * 16 + wdz] = if (ok_x and lz >= 0 and lz < @as(i32, @intCast(view.sz)))
                    // genlayer buffers are row-major [z*w + x] (see
                    // getInts convention); the View/block layout is
                    // [x*sz + z] — do not mix them (transposed reads gate
                    // the snow/ice tail on mirrored biomes and cut ice
                    // along the view diagonal, jar-verified via StructDump
                    // regen + per-column biome/block probe).
                    bio48[uxl + @as(usize, @intCast(lz)) * view.sx]
                else
                    biome;
            }
        }
        // Work is already pristine on entry (restored at the end of the
        // previous iteration; initially copied above). No full copy here.
        work.clearDirty();
        try populateOne(&work, run_heights, &rand, &flower_noise, nx * 16, nz * 16, biome, win_bio);
        // Debug completeness gate for per-write dirty marking (compiled
        // out in release): every write marks its 8x8 tile, so clean tiles
        // must equal pristine. A missed markDirty would diverge here in
        // tests before it could corrupt a merge.
        if (std.debug.runtime_safety) {
            var ctx_: usize = 0;
            while (ctx_ < 6) : (ctx_ += 1) {
                var ctz_: usize = 0;
                while (ctz_ < 6) : (ctz_ += 1) {
                    const bit_: u6 = @intCast(ctx_ * 6 + ctz_);
                    if ((work.dirty >> bit_) & 1 == 1) continue;
                    var dx_: usize = 0;
                    while (dx_ < 8) : (dx_ += 1) {
                        var dz_: usize = 0;
                        while (dz_ < 8) : (dz_ += 1) {
                            const cx_ = ctx_ * 8 + dx_;
                            const cz_ = ctz_ * 8 + dz_;
                            const cbase_ = (cx_ * view.sz + cz_) * 256;
                            var yy_: usize = 0;
                            while (yy_ < 256) : (yy_ += 1) {
                                const ii_ = cbase_ + yy_;
                                std.debug.assert(work_blocks[ii_] == base_blocks[ii_]);
                                std.debug.assert(work_metas[ii_] == base_metas[ii_]);
                            }
                        }
                    }
                }
            }
        }
        // Merge over dirty tiles only (tile-major order; per-cell stores
        // are independent so order is unobservable). Clean tiles equal
        // pristine by the gate above, so skipping them is exact.
        // Dirty group indices are recorded so only they are restored to
        // pristine afterwards (sparse reset, no full copy).
        var nb_dirty: usize = 0;
        var dtx: usize = 0;
        while (dtx < 6) : (dtx += 1) {
            var dtz: usize = 0;
            while (dtz < 6) : (dtz += 1) {
                const dbit: u6 = @intCast(dtx * 6 + dtz);
                if ((work.dirty >> dbit) & 1 == 0) continue;
                var ddx: usize = 0;
                while (ddx < 8) : (ddx += 1) {
                    var ddz: usize = 0;
                    while (ddz < 8) : (ddz += 1) {
                        const col_x = dtx * 8 + ddx;
                        const col_z = dtz * 8 + ddz;
                        const cbase = (col_x * view.sz + col_z) * 256;
                        var y0: usize = 0;
                        while (y0 < 256) : (y0 += 4) {
                            const b0 = cbase + y0;
                            const wb64 = std.mem.readInt(u64, std.mem.sliceAsBytes(work_blocks[b0..][0..4])[0..8], .little);
                            const bb64 = std.mem.readInt(u64, std.mem.sliceAsBytes(base_blocks[b0..][0..4])[0..8], .little);
                            if (wb64 != bb64) {
                                var kb: usize = 0;
                                while (kb < 4) : (kb += 1) {
                                    const wb = work_blocks[b0 + kb];
                                    if (wb != base_blocks[b0 + kb]) view.blocks[b0 + kb] = wb;
                                }
                                dirty_b[nb_dirty] = b0 / 4;
                                nb_dirty += 1;
                            }
                        }
                    }
                }
            }
        }
        var nm_dirty: usize = 0;
        var mtx: usize = 0;
        while (mtx < 6) : (mtx += 1) {
            var mtz: usize = 0;
            while (mtz < 6) : (mtz += 1) {
                const mbit: u6 = @intCast(mtx * 6 + mtz);
                if ((work.dirty >> mbit) & 1 == 0) continue;
                var mdx: usize = 0;
                while (mdx < 8) : (mdx += 1) {
                    var mdz: usize = 0;
                    while (mdz < 8) : (mdz += 1) {
                        const col_x = mtx * 8 + mdx;
                        const col_z = mtz * 8 + mdz;
                        const cbase = (col_x * view.sz + col_z) * 256;
                        var y0: usize = 0;
                        while (y0 < 256) : (y0 += 8) {
                            const m0 = cbase + y0;
                            const wm64 = std.mem.readInt(u64, work_metas[m0..][0..8], .little);
                            const bm64 = std.mem.readInt(u64, base_metas[m0..][0..8], .little);
                            if (wm64 != bm64) {
                                var km: usize = 0;
                                while (km < 8) : (km += 1) {
                                    const wm = work_metas[m0 + km];
                                    if (wm != base_metas[m0 + km]) view.metas[m0 + km] = wm;
                                }
                                dirty_m[nm_dirty] = m0 / 8;
                                nm_dirty += 1;
                            }
                        }
                    }
                }
            }
        }
        // Restore dirty groups to pristine for the next run.
        var di: usize = 0;
        while (di < nb_dirty) : (di += 1) {
            const gg = dirty_b[di];
            const b0 = gg * 4;
            @memcpy(work_blocks[b0..][0..4], base_blocks[b0..][0..4]);
        }
        var dj: usize = 0;
        while (dj < nm_dirty) : (dj += 1) {
            const hh = dirty_m[dj];
            const m0 = hh * 8;
            @memcpy(work_metas[m0..][0..8], base_metas[m0..][0..8]);
        }
    }
    // Post-merge floater sweep: a later run's lake can undercut an earlier
    // run's flora (see sweepFloaters). Center chunk only; neighbors sweep
    // themselves in their own decorateCenter runs.
    sweepFloaters(view, cx, cz);
}

/// Post-merge floater sweep for soil-gated plants (counterpart to gen's
/// snow sweep): the 3x3 merge can undercut one run's flora when a later
/// run's lake carves water/air below it (vanilla runs on one live world,
/// so this never floats). Only removes what vanilla placement gates
/// forbid — every soil set below mirrors the scatter gate exactly, so
/// legitimate placements are never touched. Sweeps the center chunk only
/// (each chunk's own decorateCenter run sweeps itself).
pub fn sweepFloaters(view: *View, cx: i32, cz: i32) void {
    var lx: i32 = 0;
    while (lx < 16) : (lx += 1) {
        var lz: i32 = 0;
        while (lz < 16) : (lz += 1) {
            const wx = cx * 16 + lx;
            const wz = cz * 16 + lz;
            // One bounds check per column: OOB reads air (always kept, no
            // writes) — skipping the column matches exactly.
            const cbase = view.colBase(wx, wz) orelse continue;
            var y: i32 = 1;
            while (y < 256) : (y += 1) {
                const uy: usize = @intCast(y);
                const id = view.blocks[cbase + uy];
                const below = view.blocks[cbase + uy - 1];
                const keep = switch (id) {
                    .tallgrass, .yellow_flower, .red_flower => isSoilGrass(below),
                    .deadbush => isSoilDeadbush(below),
                    .brown_mushroom, .red_mushroom => isMushroomSoil(below),
                    .waterlily => isWaterLike(below),
                    .pumpkin => below == ids.grass,
                    .reeds_block => reedCanStay(view, wx, y, wz),
                    .cactus => cactusCanStay(view, wx, y, wz),
                    else => true,
                };
                if (!keep) {
                    view.blocks[cbase + uy] = ids.air;
                    view.metas[cbase + uy] = 0;
                }
            }
        }
    }
}

test "populateOne matches JVM (seed 42 chunk 0,0 forest)" {
    const alloc = std.testing.allocator;
    // 48x48 view, ox=-16 (matches harness). Terrain: stone<70, grass at 70.
    const S: usize = 48;
    const blocks = try alloc.alloc(ids.Id, S * 256 * S);
    defer alloc.free(blocks);
    const metas = try alloc.alloc(u8, S * 256 * S);
    defer alloc.free(metas);
    @memset(blocks, ids.air);
    @memset(metas, 0);
    for (0..S) |x| {
        for (0..S) |z| {
            for (0..70) |y| {
                blocks[(x * S + z) * 256 + y] = ids.stone;
            }
            blocks[(x * S + z) * 256 + 70] = ids.grass;
        }
    }
    var view = View{ .blocks = blocks, .metas = metas, .ox = -16, .oz = -16, .sx = S, .sz = S };
    const heights = try alloc.alloc(i32, S * S);
    defer alloc.free(heights);
    var frand = java_random.JavaRandom.init(2345);
    var fnoise = try noise_mod.SimplexOctaves.init(alloc, &frand, 1);
    defer fnoise.deinit();
    var rand = java_random.JavaRandom.init(0);
    seedForChunk(&rand, 42, 0, 0);
    // Forest biome id 4.
    try populateOne(&view, heights, &rand, &fnoise, 0, 0, 4, [_]i32{4} ** 256);
    var crc: i64 = 0;
    var counts: [256]usize = [_]usize{0} ** 256;
    var wx: i32 = 0;
    while (wx < 16) : (wx += 1) {
        var wy: i32 = 0;
        while (wy < 256) : (wy += 1) {
            var wz: i32 = 0;
            while (wz < 16) : (wz += 1) {
                const id = view.get(wx, wy, wz);
                crc = crc *% 31 +% @as(i64, wire.toWire(id)); // JVM goldens are wire ids
                counts[@intFromEnum(id)] += 1; // canonical block ids always < 256
            }
        }
    }
    // Full-populate JVM golden (VGold harness: real 1.7.10 populate +
    // decorate on identical synthetic terrain, seed 42 chunk (0,0)).
    try std.testing.expectEqual(@as(i64, 321941256375464097), crc);
    try std.testing.expectEqual(@as(usize, 47243), counts[@intFromEnum(ids.air)]);
    try std.testing.expectEqual(@as(usize, 17790), counts[@intFromEnum(ids.stone)]);
    try std.testing.expectEqual(@as(usize, 254), counts[@intFromEnum(ids.grass)]);
    try std.testing.expectEqual(@as(usize, 26), counts[@intFromEnum(ids.dirt)]);
    try std.testing.expectEqual(@as(usize, 0), counts[@intFromEnum(ids.gravel)]);
    try std.testing.expectEqual(@as(usize, 0), counts[@intFromEnum(ids.gold_ore)]);
    try std.testing.expectEqual(@as(usize, 51), counts[@intFromEnum(ids.iron_ore)]);
    try std.testing.expectEqual(@as(usize, 37), counts[@intFromEnum(ids.coal_ore)]);
    try std.testing.expectEqual(@as(usize, 0), counts[@intFromEnum(ids.diamond_ore)]);
    try std.testing.expectEqual(@as(usize, 4), counts[@intFromEnum(ids.lapis_ore)]);
    try std.testing.expectEqual(@as(usize, 14), counts[@intFromEnum(ids.redstone_ore)]);
    try std.testing.expectEqual(@as(usize, 10), counts[@intFromEnum(ids.log)]);
    try std.testing.expectEqual(@as(usize, 107), counts[@intFromEnum(ids.leaves)]);
    try std.testing.expectEqual(@as(usize, 0), counts[@intFromEnum(ids.red_flower)]);
}

test "populateOne plains matches JVM (seed 42, no trees)" {
    const alloc = std.testing.allocator;
    const S: usize = 48;
    const blocks = try alloc.alloc(ids.Id, S * 256 * S);
    defer alloc.free(blocks);
    const metas = try alloc.alloc(u8, S * 256 * S);
    defer alloc.free(metas);
    @memset(blocks, ids.air);
    @memset(metas, 0);
    for (0..S) |x| {
        for (0..S) |z| {
            for (0..70) |y| {
                blocks[(x * S + z) * 256 + y] = ids.stone;
            }
            blocks[(x * S + z) * 256 + 70] = ids.grass;
        }
    }
    var view = View{ .blocks = blocks, .metas = metas, .ox = -16, .oz = -16, .sx = S, .sz = S };
    const heights = try alloc.alloc(i32, S * S);
    defer alloc.free(heights);
    computeHeights(&view, heights);
    var frand2 = java_random.JavaRandom.init(2345);
    var fnoise2 = try noise_mod.SimplexOctaves.init(alloc, &frand2, 1);
    defer fnoise2.deinit();
    var rand = java_random.JavaRandom.init(0);
    seedForChunk(&rand, 42, 0, 0);
    // Plains biome id 1 (x=-999, no trees, but nextInt10 still drawn).
    try populateOne(&view, heights, &rand, &fnoise2, 0, 0, 1, [_]i32{1} ** 256);
    var crc: i64 = 0;
    var counts: [256]usize = [_]usize{0} ** 256;
    var wx: i32 = 0;
    while (wx < 16) : (wx += 1) {
        var wy: i32 = 0;
        while (wy < 256) : (wy += 1) {
            var wz: i32 = 0;
            while (wz < 16) : (wz += 1) {
                const id = view.get(wx, wy, wz);
                crc = crc *% 31 +% @as(i64, wire.toWire(id)); // JVM goldens are wire ids
                counts[@intFromEnum(id)] += 1; // canonical block ids always < 256
            }
        }
    }
    // Full-populate JVM golden (VGold harness: real 1.7.10 populate +
    // decorate on identical synthetic terrain, seed 42 chunk (0,0)).
    try std.testing.expectEqual(@as(i64, 3297028603511917183), crc);
    try std.testing.expectEqual(@as(usize, 47324), counts[@intFromEnum(ids.air)]);
    try std.testing.expectEqual(@as(usize, 17790), counts[@intFromEnum(ids.stone)]);
    try std.testing.expectEqual(@as(usize, 256), counts[@intFromEnum(ids.grass)]);
    try std.testing.expectEqual(@as(usize, 24), counts[@intFromEnum(ids.dirt)]);
    try std.testing.expectEqual(@as(usize, 0), counts[@intFromEnum(ids.gravel)]);
    try std.testing.expectEqual(@as(usize, 0), counts[@intFromEnum(ids.gold_ore)]);
    try std.testing.expectEqual(@as(usize, 51), counts[@intFromEnum(ids.iron_ore)]);
    try std.testing.expectEqual(@as(usize, 37), counts[@intFromEnum(ids.coal_ore)]);
    try std.testing.expectEqual(@as(usize, 0), counts[@intFromEnum(ids.diamond_ore)]);
    try std.testing.expectEqual(@as(usize, 4), counts[@intFromEnum(ids.lapis_ore)]);
    try std.testing.expectEqual(@as(usize, 36), counts[@intFromEnum(ids.tallgrass)]);
    try std.testing.expectEqual(@as(usize, 14), counts[@intFromEnum(ids.redstone_ore)]);
}

test "sweepFloaters removes only support-less plants" {
    const alloc = std.testing.allocator;
    const S: usize = 16;
    const blocks = try alloc.alloc(ids.Id, S * 256 * S);
    defer alloc.free(blocks);
    const metas = try alloc.alloc(u8, S * 256 * S);
    defer alloc.free(metas);
    @memset(blocks, ids.stone);
    @memset(metas, 0);
    var view = View{ .blocks = blocks, .metas = metas, .ox = 0, .oz = 0, .sx = S, .sz = S };
    const at = struct {
        fn f(v: *View, x: i32, y: i32, z: i32, below: ids.Id, plant: ids.Id) void {
            v.set(x, y - 1, z, below, 0);
            v.set(x, y, z, plant, 0);
        }
    }.f;
    at(&view, 0, 70, 0, .water, .tallgrass); // floating -> air
    at(&view, 1, 70, 0, .dirt, .tallgrass); // kept
    at(&view, 2, 70, 0, .air, .yellow_flower); // floating -> air
    at(&view, 3, 70, 0, .sand, .deadbush); // kept
    at(&view, 4, 70, 0, .grass, .red_mushroom); // kept (mushroom soil)
    at(&view, 5, 70, 0, .grass, .pumpkin); // kept
    at(&view, 6, 70, 0, .stone, .pumpkin); // no grass below -> air
    at(&view, 7, 70, 0, .water, .waterlily); // kept
    at(&view, 8, 70, 0, .dirt, .waterlily); // sinks -> air
    at(&view, 9, 70, 0, .dirt, .reeds_block); // no adjacent water -> air
    at(&view, 10, 70, 0, .grass, .cactus); // wrong soil -> air
    view.set(11, 70, 1, ids.water, 0); // adjacent water for the kept reed
    at(&view, 11, 70, 0, .dirt, .reeds_block); // kept
    view.set(12, 70, 2, ids.sand, 0);
    view.set(11, 71, 2, ids.air, 0);
    view.set(13, 71, 2, ids.air, 0);
    view.set(12, 71, 1, ids.air, 0);
    view.set(12, 71, 3, ids.air, 0);
    view.set(12, 71, 2, ids.cactus, 0); // kept (sand + air neighbors)

    sweepFloaters(&view, 0, 0);

    try std.testing.expectEqual(ids.air, view.get(0, 70, 0));
    try std.testing.expectEqual(ids.tallgrass, view.get(1, 70, 0));
    try std.testing.expectEqual(ids.air, view.get(2, 70, 0));
    try std.testing.expectEqual(ids.deadbush, view.get(3, 70, 0));
    try std.testing.expectEqual(ids.red_mushroom, view.get(4, 70, 0));
    try std.testing.expectEqual(ids.pumpkin, view.get(5, 70, 0));
    try std.testing.expectEqual(ids.air, view.get(6, 70, 0));
    try std.testing.expectEqual(ids.waterlily, view.get(7, 70, 0));
    try std.testing.expectEqual(ids.air, view.get(8, 70, 0));
    try std.testing.expectEqual(ids.air, view.get(9, 70, 0));
    try std.testing.expectEqual(ids.air, view.get(10, 70, 0));
    try std.testing.expectEqual(ids.reeds_block, view.get(11, 70, 0));
    try std.testing.expectEqual(ids.cactus, view.get(12, 71, 2));
}

test "snow/ice tail gates per column, not per window" {
    // Regression: the old code gated the whole 16x16 populate window on
    // the chunk-center biome, freezing ocean/beach water into an ice
    // square whenever a frozen biome sat in the window (vanilla checks
    // each column's own biome temperature < 0.15 via World.r/World.e).
    const alloc = std.testing.allocator;
    const S: usize = 48;
    const blocks = try alloc.alloc(ids.Id, S * 256 * S);
    defer alloc.free(blocks);
    const metas = try alloc.alloc(u8, S * 256 * S);
    defer alloc.free(metas);
    @memset(blocks, ids.air);
    @memset(metas, 0);
    // Ocean world: stone to 70 everywhere; water at 71 on the west half
    // of the window, bare stone at 71 on the east half.
    for (0..S) |x| {
        for (0..S) |z| {
            for (0..71) |y| blocks[(x * S + z) * 256 + y] = ids.stone;
        }
    }
    // Window for base (0,0) is wx 8..23, wz 8..23 (view ox=-16,oz=-16).
    var dx: i32 = 0;
    while (dx < 16) : (dx += 1) {
        var dz: i32 = 0;
        while (dz < 16) : (dz += 1) {
            const wx = 8 + dx;
            const wz = 8 + dz;
            const lx: usize = @intCast(wx + 16);
            const lz: usize = @intCast(wz + 16);
            if (dx < 8) {
                blocks[(lx * S + lz) * 256 + 71] = ids.water;
            } else {
                blocks[(lx * S + lz) * 256 + 71] = ids.stone;
            }
        }
    }
    var view = View{ .blocks = blocks, .metas = metas, .ox = -16, .oz = -16, .sx = S, .sz = S };
    const heights = try alloc.alloc(i32, S * S);
    defer alloc.free(heights);
    computeHeights(&view, heights);
    var frand = java_random.JavaRandom.init(2345);
    var fnoise = try noise_mod.SimplexOctaves.init(alloc, &frand, 1);
    defer fnoise.deinit();
    var rand = java_random.JavaRandom.init(0);
    seedForChunk(&rand, 42, 0, 0);
    // Window biomes: west half ocean (0, warm), east half ice plains
    // (12, frozen). Center biome is frozen on purpose: the old
    // whole-window gate would freeze the western water too.
    var win_bio: [256]i32 = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        win_bio[i] = if (i / 16 < 8) 0 else 12;
    }
    try populateOne(&view, heights, &rand, &fnoise, 0, 0, 12, win_bio);
    // Warm columns: water untouched, no snow anywhere above.
    dx = 0;
    while (dx < 8) : (dx += 1) {
        var dz: i32 = 0;
        while (dz < 16) : (dz += 1) {
            const wx = 8 + dx;
            const wz = 8 + dz;
            try std.testing.expectEqual(ids.water, view.get(wx, 71, wz));
            try std.testing.expectEqual(ids.air, view.get(wx, 72, wz));
        }
    }
    // Frozen stone columns: snow_layer on top (proves the tail ran).
    var snow_n: usize = 0;
    dx = 8;
    while (dx < 16) : (dx += 1) {
        var dz: i32 = 0;
        while (dz < 16) : (dz += 1) {
            const wx = 8 + dx;
            const wz = 8 + dz;
            if (view.get(wx, 72, wz) == ids.snow_layer) snow_n += 1;
            try std.testing.expect(view.get(wx, 71, wz) != ids.ice);
        }
    }
    try std.testing.expect(snow_n > 100);
}


test "snow support gate: soil/leaves hold, ice/fluids/flora never do" {
    try std.testing.expect(snowSupport(ids.grass, 0));
    try std.testing.expect(snowSupport(ids.dirt, 0));
    try std.testing.expect(snowSupport(ids.stone, 0));
    try std.testing.expect(snowSupport(ids.leaves, 0));
    try std.testing.expect(snowSupport(ids.leaves2, 0));
    try std.testing.expect(snowSupport(ids.snow_layer, 7));
    try std.testing.expect(!snowSupport(ids.snow_layer, 0));
    try std.testing.expect(!snowSupport(ids.ice, 0));
    try std.testing.expect(!snowSupport(ids.packed_ice, 0));
    try std.testing.expect(!snowSupport(ids.air, 0));
    try std.testing.expect(!snowSupport(ids.water, 0));
    try std.testing.expect(!snowSupport(ids.lava, 0));
    try std.testing.expect(!snowSupport(ids.glass, 0));
    try std.testing.expect(!snowSupport(ids.tallgrass, 0));
    try std.testing.expect(!snowSupport(ids.yellow_flower, 0));
    try std.testing.expect(!snowSupport(ids.red_flower, 0));
    try std.testing.expect(!snowSupport(ids.brown_mushroom, 0));
    try std.testing.expect(!snowSupport(ids.red_mushroom, 0));
    try std.testing.expect(!snowSupport(ids.deadbush, 0));
}

test "snow tail buries soft flora instead of capping it" {
    const alloc = std.testing.allocator;
    const S: usize = 48;
    const blocks = try alloc.alloc(ids.Id, S * 256 * S);
    defer alloc.free(blocks);
    const metas = try alloc.alloc(u8, S * 256 * S);
    defer alloc.free(metas);
    @memset(blocks, ids.air);
    @memset(metas, 0);
    for (0..S) |x| {
        for (0..S) |z| {
            for (0..70) |y| blocks[(x * S + z) * 256 + y] = ids.stone;
            blocks[(x * S + z) * 256 + 70] = ids.grass;
        }
    }
    // Pre-placed flora on open daylight grass.
    blocks[(20 * S + 20) * 256 + 71] = ids.tallgrass;
    blocks[(21 * S + 20) * 256 + 71] = ids.brown_mushroom;
    var view = View{ .blocks = blocks, .metas = metas, .ox = -16, .oz = -16, .sx = S, .sz = S };
    const heights = try alloc.alloc(i32, S * S);
    defer alloc.free(heights);
    var frand = java_random.JavaRandom.init(2345);
    var fnoise = try noise_mod.SimplexOctaves.init(alloc, &frand, 1);
    defer fnoise.deinit();
    var rand = java_random.JavaRandom.init(0);
    seedForChunk(&rand, 42, 0, 0);
    try populateOne(&view, heights, &rand, &fnoise, 0, 0, 12, [_]i32{12} ** 256);
    // Buried, not snow-capped.
    try std.testing.expectEqual(ids.snow_layer, view.get(20, 71, 20));
    try std.testing.expectEqual(ids.snow_layer, view.get(21, 71, 20));
    // No snow directly above any flora anywhere in the chunk window.
    var wx: i32 = 8;
    while (wx < 24) : (wx += 1) {
        var wz: i32 = 8;
        while (wz < 24) : (wz += 1) {
            var y: i32 = 1;
            while (y < 255) : (y += 1) {
                if (view.get(wx, y, wz) != ids.snow_layer) continue;
                const b = view.get(wx, y - 1, wz);
                try std.testing.expect(b != ids.tallgrass and b != ids.yellow_flower and b != ids.red_flower and b != ids.brown_mushroom and b != ids.red_mushroom and b != ids.deadbush);
            }
        }
    }
}

test "mushrooms need soil and darkness (mycelium exempt)" {
    const alloc = std.testing.allocator;
    const S: usize = 32;
    const blocks = try alloc.alloc(ids.Id, S * 256 * S);
    defer alloc.free(blocks);
    const metas = try alloc.alloc(u8, S * 256 * S);
    defer alloc.free(metas);
    @memset(blocks, ids.air);
    @memset(metas, 0);
    for (0..S) |x| {
        for (0..S) |z| {
            for (0..70) |y| blocks[(x * S + z) * 256 + y] = ids.stone;
            blocks[(x * S + z) * 256 + 70] = ids.grass;
        }
    }
    var view = View{ .blocks = blocks, .metas = metas, .ox = 0, .oz = 0, .sx = S, .sz = S };
    var rand = java_random.JavaRandom.init(1234);
    // Open daylight grass: nothing plants.
    try scatterFlora(&view, &rand, 16, 71, 16, ids.brown_mushroom, 0, .mushroom);
    var n: usize = 0;
    for (0..S) |x| {
        for (0..S) |z| {
            for (71..76) |y| {
                if (view.get(@intCast(x), @intCast(y), @intCast(z)) == ids.brown_mushroom) n += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), n);
    // Stone roof overhead: the same scatter takes.
    for (8..24) |x| {
        for (8..24) |z| {
            blocks[(x * S + z) * 256 + 75] = ids.stone;
        }
    }
    try scatterFlora(&view, &rand, 16, 71, 16, ids.brown_mushroom, 0, .mushroom);
    n = 0;
    for (0..S) |x| {
        for (0..S) |z| {
            for (71..75) |y| {
                if (view.get(@intCast(x), @intCast(y), @intCast(z)) == ids.brown_mushroom) n += 1;
            }
        }
    }
    try std.testing.expect(n > 0);
}

test "ice spike + ice path match JVM (arw/arv goldens)" {
    // SpikeGold harness (real 1.7.10 arw/arv on synthetic terrain):
    // 48x48 view, stone<68, dirt 68..69, snow @70, generate at (24,71,24).
    // CRC over placed cells (wire id 174): crc*31 + id + lx*7919 +
    // y*104729 + lz*1299709 in i64 wrap, scan lx/lz/y ascending.
    const alloc = std.testing.allocator;
    const seeds = [_]i64{ 1, 2, 3, 7, 42 };
    const spike_n = [_]usize{ 18, 176, 99, 198, 82 };
    const spike_crc = [_]i64{ -4418964843523393343, -2964852016081260997, -6610057545680418322, 4056833247769555053, 6806564705251544950 };
    for (seeds, 0..) |s, k| {
        const S: usize = 48;
        const blocks = try alloc.alloc(ids.Id, S * 256 * S);
        defer alloc.free(blocks);
        const metas = try alloc.alloc(u8, S * 256 * S);
        defer alloc.free(metas);
        @memset(blocks, ids.air);
        @memset(metas, 0);
        for (0..S) |x| {
            for (0..S) |z| {
                for (0..68) |y| blocks[(x * S + z) * 256 + y] = ids.stone;
                blocks[(x * S + z) * 256 + 68] = ids.dirt;
                blocks[(x * S + z) * 256 + 69] = ids.dirt;
                blocks[(x * S + z) * 256 + 70] = ids.snow;
            }
        }
        var view = View{ .blocks = blocks, .metas = metas, .ox = 0, .oz = 0, .sx = S, .sz = S };
        var rand = java_random.JavaRandom.init(s);
        try std.testing.expect(try iceSpike(&view, &rand, 24, 71, 24));
        var n: usize = 0;
        var crc: i64 = 0;
        for (0..S) |x| {
            for (0..S) |z| {
                for (0..256) |y| {
                    const id = view.get(@intCast(x), @intCast(y), @intCast(z));
                    if (id == ids.stone or id == ids.dirt or id == ids.snow or id == ids.air) continue;
                    n += 1;
                    crc = crc *% 31 +% 174 +% @as(i64, @intCast(x)) * 7919 +% @as(i64, @intCast(y)) * 104729 +% @as(i64, @intCast(z)) * 1299709;
                }
            }
        }
        try std.testing.expectEqual(spike_n[k], n);
        try std.testing.expectEqual(spike_crc[k], crc);
    }
    // Ice paths: all five seeds draw radius 3 (n=58, same CRC).
    for (seeds) |s| {
        const S: usize = 48;
        const blocks = try alloc.alloc(ids.Id, S * 256 * S);
        defer alloc.free(blocks);
        const metas = try alloc.alloc(u8, S * 256 * S);
        defer alloc.free(metas);
        @memset(blocks, ids.air);
        @memset(metas, 0);
        for (0..S) |x| {
            for (0..S) |z| {
                for (0..68) |y| blocks[(x * S + z) * 256 + y] = ids.stone;
                blocks[(x * S + z) * 256 + 68] = ids.dirt;
                blocks[(x * S + z) * 256 + 69] = ids.dirt;
                blocks[(x * S + z) * 256 + 70] = ids.snow;
            }
        }
        var view = View{ .blocks = blocks, .metas = metas, .ox = 0, .oz = 0, .sx = S, .sz = S };
        var rand = java_random.JavaRandom.init(s);
        try std.testing.expect(try icePath(&view, &rand, 24, 71, 24, 4));
        var n: usize = 0;
        var crc: i64 = 0;
        for (0..S) |x| {
            for (0..S) |z| {
                for (0..256) |y| {
                    const id = view.get(@intCast(x), @intCast(y), @intCast(z));
                    if (id == ids.stone or id == ids.dirt or id == ids.snow or id == ids.air) continue;
                    n += 1;
                    crc = crc *% 31 +% 174 +% @as(i64, @intCast(x)) * 7919 +% @as(i64, @intCast(y)) * 104729 +% @as(i64, @intCast(z)) * 1299709;
                }
            }
        }
        try std.testing.expectEqual(@as(usize, 58), n);
        try std.testing.expectEqual(@as(i64, 2845064153872846389), crc);
    }
    // Dirt top (no snow): spike refuses and places nothing.
    {
        const S: usize = 48;
        const blocks = try alloc.alloc(ids.Id, S * 256 * S);
        defer alloc.free(blocks);
        const metas = try alloc.alloc(u8, S * 256 * S);
        defer alloc.free(metas);
        @memset(blocks, ids.air);
        @memset(metas, 0);
        for (0..S) |x| {
            for (0..S) |z| {
                for (0..69) |y| blocks[(x * S + z) * 256 + y] = ids.stone;
                blocks[(x * S + z) * 256 + 69] = ids.dirt;
            }
        }
        var view = View{ .blocks = blocks, .metas = metas, .ox = 0, .oz = 0, .sx = S, .sz = S };
        var rand = java_random.JavaRandom.init(1);
        try std.testing.expect(!try iceSpike(&view, &rand, 24, 70, 24));
        for (blocks) |id| try std.testing.expect(id != ids.packed_ice);
    }
}

test "tree scan: single-meta grounded trunks across seeds" {
    // Certifies fresh generator output against two live-world reports:
    // (a) mixed-meta trunk bases (a spruce log under an oak), (b) floating
    // trunks (grass where the dirt-ified base should be). Part 1 places one
    // of each tree kind per seed on flat terrain and asserts every trunk
    // column is single-meta, starts at the soil line, and bottoms on dirt.
    // Part 2 populates forest chunks and asserts no spruce/jungle-meta logs
    // appear, no log2 at all, and every trunk column bottoms on dirt.
    // Same-spot overlap columns stay single-meta here (one biome's metas);
    // cross-chunk overlap with another biome's trees is vanilla behavior
    // (identical in the jar) and out of scope.
    const alloc = std.testing.allocator;
    var seed: i64 = 1;
    while (seed <= 32) : (seed += 1) {
        const S: usize = 32;
        const blocks = try alloc.alloc(ids.Id, S * 256 * S);
        defer alloc.free(blocks);
        const metas = try alloc.alloc(u8, S * 256 * S);
        defer alloc.free(metas);
        @memset(blocks, ids.air);
        @memset(metas, 0);
        for (0..S) |x| {
            for (0..S) |z| {
                for (0..70) |y| blocks[(x * S + z) * 256 + y] = ids.stone;
                blocks[(x * S + z) * 256 + 70] = ids.grass;
            }
        }
        var view = View{ .blocks = blocks, .metas = metas, .ox = -16, .oz = -16, .sx = S, .sz = S };
        var r = java_random.JavaRandom.init(seed);
        const spots = [_]struct { x: i32, z: i32, meta: u8 }{
            .{ .x = -8, .z = -8, .meta = 0 }, // oak
            .{ .x = 8, .z = -8, .meta = 2 }, // birch
            .{ .x = -8, .z = 8, .meta = 1 }, // spruce
            .{ .x = 8, .z = 8, .meta = 0 }, // swamp oak
        };
        try std.testing.expect(try oakTree(&view, &r, spots[0].x, 71, spots[0].z, 4, 0, 0, false, false));
        try std.testing.expect(try birchTree(&view, &r, spots[1].x, 71, spots[1].z, false));
        try std.testing.expect(try spruceTree(&view, &r, spots[2].x, 71, spots[2].z));
        try std.testing.expect(try swampTree(&view, &r, spots[3].x, 71, spots[3].z));
        for (spots) |sp| {
            var n_logs: usize = 0;
            var low_y: i32 = 256;
            var y: i32 = 71;
            while (y < 100) : (y += 1) {
                if (view.get(sp.x, y, sp.z) == ids.log) {
                    n_logs += 1;
                    if (y < low_y) low_y = y;
                    try std.testing.expectEqual(sp.meta, view.getMeta(sp.x, y, sp.z));
                }
            }
            try std.testing.expect(n_logs >= 4);
            try std.testing.expectEqual(@as(i32, 71), low_y);
            try std.testing.expectEqual(ids.dirt, view.get(sp.x, 70, sp.z));
        }
    }
    // Part 2: forest populate (biome 4) across seeds.
    var frand = java_random.JavaRandom.init(2345);
    var fnoise = try noise_mod.SimplexOctaves.init(alloc, &frand, 1);
    defer fnoise.deinit();
    seed = 1;
    while (seed <= 12) : (seed += 1) {
        const S: usize = 48;
        const blocks = try alloc.alloc(ids.Id, S * 256 * S);
        defer alloc.free(blocks);
        const metas = try alloc.alloc(u8, S * 256 * S);
        defer alloc.free(metas);
        @memset(blocks, ids.air);
        @memset(metas, 0);
        for (0..S) |x| {
            for (0..S) |z| {
                for (0..70) |y| blocks[(x * S + z) * 256 + y] = ids.stone;
                blocks[(x * S + z) * 256 + 70] = ids.grass;
            }
        }
        var view = View{ .blocks = blocks, .metas = metas, .ox = -16, .oz = -16, .sx = S, .sz = S };
        const heights = try alloc.alloc(i32, S * S);
        defer alloc.free(heights);
        var rand = java_random.JavaRandom.init(0);
        seedForChunk(&rand, seed, 0, 0);
        try populateOne(&view, heights, &rand, &fnoise, 0, 0, 4, [_]i32{4} ** 256);
        var wx: i32 = 0;
        while (wx < 16) : (wx += 1) {
            var wz: i32 = 0;
            while (wz < 16) : (wz += 1) {
                var n_logs: usize = 0;
                var low_y: i32 = 256;
                var col_meta: u8 = 0;
                var y: i32 = 0;
                while (y < 256) : (y += 1) {
                    const id = view.get(wx, y, wz);
                    try std.testing.expect(id != ids.log2);
                    if (id == ids.log) {
                        const m = view.getMeta(wx, y, wz);
                        try std.testing.expect(m == 0 or m == 2);
                        if (n_logs == 0) col_meta = m;
                        try std.testing.expectEqual(col_meta, m);
                        n_logs += 1;
                        if (y < low_y) low_y = y;
                    }
                }
                if (n_logs > 0) {
                    // Trunk columns bottom on dirt (the tree dirt-ifies its
                    // soil); grass/air below means flora or a lake ate the
                    // base — both write air cells only, so this fires only
                    // on a real generator regression.
                    try std.testing.expectEqual(ids.dirt, view.get(wx, low_y - 1, wz));
                }
            }
        }
    }
}
