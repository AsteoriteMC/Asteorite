//! Chunk-border light bleed after edits (sky + block channels).

const std = @import("std");
const chunk_mod = @import("../../../world/chunk.zig");
const store_mod = @import("../../../world/store.zig");
const shard_mod = @import("../../../world/shard.zig");

/// Which border of a chunk faces a neighbor.
const BleedSide = enum { west, east, north, south };

/// Edited-chunk border cell for one lane.
fn edgeCell(side: BleedSide, a: usize) struct { x: usize, z: usize } {
    return .{
        .x = switch (side) {
            .west => 0,
            .east => 15,
            else => a,
        },
        .z = switch (side) {
            .north => 0,
            .south => 15,
            else => a,
        },
    };
}

/// Neighbor-chunk border cell (mirrored lane).
fn neighborCell(side: BleedSide, a: usize) struct { x: usize, z: usize } {
    return .{
        .x = switch (side) {
            .west => 15,
            .east => 0,
            else => a,
        },
        .z = switch (side) {
            .north => 15,
            .south => 0,
            else => a,
        },
    };
}

/// Neighbor-chunk offset for one side.
fn neighborOff(side: BleedSide) struct { dx: i32, dz: i32 } {
    return .{
        .dx = switch (side) {
            .west => -1,
            .east => 1,
            else => 0,
        },
        .dz = switch (side) {
            .north => -1,
            .south => 1,
            else => 0,
        },
    };
}

/// One side's full fan-out step (edge writes + reverse reads + mask bit).
const SideStep = struct {
    side: BleedSide,
    dx: i32,
    dz: i32,
    pre_idx: usize,
    bit: u3,
};

const all_sides = [_]SideStep{
    .{ .side = .west, .dx = -1, .dz = 0, .pre_idx = 0, .bit = 0 },
    .{ .side = .east, .dx = 1, .dz = 0, .pre_idx = 1, .bit = 1 },
    .{ .side = .north, .dx = 0, .dz = -1, .pre_idx = 2, .bit = 2 },
    .{ .side = .south, .dx = 0, .dz = 1, .pre_idx = 3, .bit = 3 },
};

/// Both light channels (lower/raise passes iterate both).
const channels = [_]chunk_mod.Chunk.LightChannel{ .sky, .block };

/// True when every cell of the column is opaque (sky-bleed fast reject).
/// Top-down: open sky early-outs on the first cell.
fn columnSolid(ch: *const chunk_mod.Chunk, lx: usize, lz: usize) bool {
    var yy: usize = 256;
    while (yy > 0) {
        yy -= 1;
        if (chunk_mod.lightOpacity(ch.blockAt(lx, yy, lz)) != 255) return false;
    }
    return true;
}

/// Both channels of one border cell. Null sections read as engine-default
/// block 0; sky uses the heightmap (open air above the top solid reads
/// 15) so pre/post snapshots compare true values, not storage artifacts.
/// A stored all-air section and a missing one compare equal here.
fn bleedRead(ch: *const chunk_mod.Chunk, lx: usize, y: usize, lz: usize) [2]u4 {
    if (ch.sections[y >> 4]) |s| {
        const i = chunk_mod.Section.index(@intCast(lx), @intCast(y & 15), @intCast(lz));
        return .{ chunk_mod.Section.getNibble(&s.sky, i), chunk_mod.Section.getNibble(&s.light, i) };
    }
    const h: usize = ch.heights[lz * 16 + lx];
    return .{ if (y > h) @as(u4, 15) else 0, 0 };
}

/// Snapshot one border face (16 along × 256 high): both channels plus the
/// opacity the spots costs and transmissivity flips are derived from.
pub fn snapBorder(ch: *const chunk_mod.Chunk, side: BleedSide, sky: *[16][256]u8, blk: *[16][256]u8, op: *[16][256]u8) void {
    for (0..16) |a| {
        const c = edgeCell(side, a);
        for (0..256) |y| {
            const v = bleedRead(ch, c.x, y, c.z);
            sky[a][y] = v[0];
            blk[a][y] = v[1];
            op[a][y] = chunk_mod.lightOpacity(ch.blockAt(c.x, y, c.z));
        }
    }
}

/// Write one channel nibble, creating the section on demand so open-air
/// borders still carry flood values. A fresh section is all air: run the
/// exact column rule over every column first (defaults would otherwise
/// strand underground 15s), mirroring the section_created path.
fn bleedWrite(nch: *chunk_mod.Chunk, nx: usize, y: usize, nz: usize, channel: chunk_mod.Chunk.LightChannel, v: u4) void {
    const si = y >> 4;
    if (nch.sections[si] == null) {
        nch.sections[si] = chunk_mod.Section{};
        for (0..16) |ex| {
            for (0..16) |ez| nch.relightColumn(ex, ez);
        }
    }
    const s = &nch.sections[si].?;
    const i = chunk_mod.Section.index(@intCast(nx), @intCast(y & 15), @intCast(nz));
    if (channel == .sky) {
        chunk_mod.Section.setNibble(&s.sky, i, v);
    } else {
        chunk_mod.Section.setNibble(&s.light, i, v);
    }
}

/// Per-op neighbor-chunk cache for the bleed path: a light edit touches
/// the center chunk plus up to 4 edge + 4 diagonal neighbors, and the
/// forward bleed, reverse pull, and diagonal hop each re-read the same
/// neighbors — without sharing, one edit costs ~13-20 full chunk
/// store-fetch + decode cycles. The cache decodes each neighbor once per
/// op, shares it across all three passes (forward writes are visible to
/// the reverse pass immediately, same as store round-trips), and
/// encode+puts dirty neighbors once at flush. Owned chunks, freed by
/// deinit; the center chunk is NOT cached (caller-owned).
const NeighborCache = struct {
    entries: [8]struct { cx: i32, cz: i32, ch: ?*chunk_mod.Chunk, dirty: bool } = undefined,
    n: usize = 0,

    fn get(self: *NeighborCache, pool: *shard_mod.ShardPool, alloc: std.mem.Allocator, cx: i32, cz: i32) !?*chunk_mod.Chunk {
        for (self.entries[0..self.n]) |*e| {
            if (e.cx == cx and e.cz == cz) return e.ch;
        }
        const raw = try pool.get(alloc, store_mod.encodeKey(0, cx, cz)) orelse {
            // Negative entry: missing chunks read as dark air everywhere,
            // and the reverse pass would otherwise re-query them per
            // channel (8 wasted store hits per edit near void).
            if (self.n < self.entries.len) {
                self.entries[self.n] = .{ .cx = cx, .cz = cz, .ch = null, .dirty = false };
                self.n += 1;
            }
            return null;
        };
        defer alloc.free(raw);
        const ch = try chunk_mod.Chunk.decode(alloc, raw);
        if (self.n >= self.entries.len) {
            ch.destroy(alloc);
            return null; // full (unreachable: ≤8 distinct neighbors)
        }
        self.entries[self.n] = .{ .cx = cx, .cz = cz, .ch = ch, .dirty = false };
        self.n += 1;
        return ch;
    }

    fn markDirty(self: *NeighborCache, ch: *chunk_mod.Chunk) void {
        for (self.entries[0..self.n]) |*e| {
            if (e.ch) |ech| {
                if (ech == ch) {
                    e.dirty = true;
                    return;
                }
            }
        }
    }

    /// Encode + put every dirty neighbor (single write-back per chunk).
    fn flush(self: *NeighborCache, pool: *shard_mod.ShardPool, alloc: std.mem.Allocator) !void {
        for (self.entries[0..self.n]) |*e| {
            if (!e.dirty) continue;
            const ch = e.ch orelse continue;
            const enc = try ch.encode(alloc);
            defer alloc.free(enc);
            try pool.put(store_mod.encodeKey(0, e.cx, e.cz), enc);
            e.dirty = false;
        }
    }

    fn deinit(self: *NeighborCache, alloc: std.mem.Allocator) void {
        for (self.entries[0..self.n]) |e| {
            if (e.ch) |ch| ch.destroy(alloc);
        }
        self.n = 0;
    }
};

/// Push one border's edge deltas into the adjacent neighbor chunk:
/// raises via spread, lowers via unspread+reflood (same two-phase
/// contract as relightEdit). Mutates the cached neighbor (write-back at
/// flush) and reports whether it changed. Reuses the caller's BFS queue
/// (free: the same-chunk flood already drained it).
fn bleedSide(
    pool: *shard_mod.ShardPool,
    alloc: std.mem.Allocator,
    q: []u32,
    ch: *chunk_mod.Chunk,
    cx: i32,
    cz: i32,
    side: BleedSide,
    pre_sky: *const [16][256]u8,
    pre_blk: *const [16][256]u8,
    pre_op: *const [16][256]u8,
    cache: *NeighborCache,
) !bool {
    const off = neighborOff(side);
    const ncx = cx + off.dx;
    const ncz = cz + off.dz;
    // Fast path: no edge delta, no neighbor I/O. Values alone are not
    // enough: opaque cells store the incoming top-face value, so an
    // air<->stone flip at the edge leaves identical nibbles while killing
    // (or opening) the flow. Opacity deltas trigger too.
    var touched = false;
    for (0..16) |a| {
        const c = edgeCell(side, a);
        for (0..256) |y| {
            const v = bleedRead(ch, c.x, y, c.z);
            if (v[0] != pre_sky[a][y] or v[1] != pre_blk[a][y] or chunk_mod.lightOpacity(ch.blockAt(c.x, y, c.z)) != pre_op[a][y]) {
                touched = true;
                break;
            }
        }
        if (touched) break;
    }
    if (!touched) return false;
    const nch = (try cache.get(pool, alloc, ncx, ncz)) orelse return false;
    var n_dirty = false;
    // Exact vertical sky for the adjacent row first (mirrors the
    // section_created path): stored nibbles alone can't distinguish a
    // stale-dark column from an enclosed one, and the unspread below
    // must not erase a column-ruled 15 it cannot rebuild.
    for (0..16) |a| {
        const n = neighborCell(side, a);
        nch.relightColumn(n.x, n.z);
        n_dirty = true;
    }
    inline for (channels) |channel| {
        const ci: usize = if (channel == .sky) 0 else 1;
        const pre = if (channel == .sky) pre_sky else pre_blk;
        var olds = try alloc.alloc(chunk_mod.Chunk.CellValue, 4096);
        defer alloc.free(olds);
        var rewrites = try alloc.alloc(chunk_mod.Chunk.CellValue, 4096);
        defer alloc.free(rewrites);
        var n_old: usize = 0;
        // Pass 1: lower. Invalidate what flowed through removed edge
        // light (same-nibble opacity flips included). Only cells strictly
        // dimmer than the old flow can depend on it (spread costs >= 1);
        // the rest are sustained from elsewhere and must be left alone —
        // phase A never zeroes seed cells, so an unconditional rewrite
        // would strand a stale floor here. The rewrite floor is the
        // cell's own emission (always <= true): reflood rebuilds inflows
        // from survivors.
        for (0..16) |a| {
            const c = edgeCell(side, a);
            const n = neighborCell(side, a);
            const lx = c.x;
            const lz = c.z;
            const nx = n.x;
            const nz = n.z;
            for (0..256) |y| {
                const post: u4 = @truncate(bleedRead(ch, lx, y, lz)[ci]);
                const pre_v: u4 = @truncate(pre[a][y]);
                const plo: u8 = pre_op[a][y];
                const qlo: u8 = chunk_mod.lightOpacity(ch.blockAt(lx, y, lz));
                if (!(post < pre_v or (post == pre_v and qlo > plo))) continue;
                const cur: u4 = @truncate(bleedRead(nch, nx, y, nz)[ci]);
                if (cur >= pre_v) continue;
                if (n_old >= olds.len) continue;
                const own: u4 = if (channel == .block) chunk_mod.emitLight(nch.blockAt(nx, y, nz)) else cur;
                olds[n_old] = .{ .cell = chunk_mod.Chunk.packCell(nx, y, nz), .value = pre_v };
                rewrites[n_old] = .{ .cell = chunk_mod.Chunk.packCell(nx, y, nz), .value = own };
                n_old += 1;
                n_dirty = true;
            }
        }
        if (n_old > 0) nch.unspreadLight(q, channel, olds[0..n_old], rewrites[0..n_old]);
        // Pass 2: raise from live post-unspread values (unspread may have
        // zeroed cells this pass needs to rebuild; computing seeds before
        // it would strand them when spread skips zeroed cells).
        var seeds = try alloc.alloc(u32, 4096);
        defer alloc.free(seeds);
        var n_seeds: usize = 0;
        for (0..16) |a| {
            const c = edgeCell(side, a);
            const n = neighborCell(side, a);
            const lx = c.x;
            const lz = c.z;
            const nx = n.x;
            const nz = n.z;
            // Sky never flows out of opaque cells (mirrors bfsRaise):
            // fast-reject solid columns, then check per cell.
            if (channel == .sky and columnSolid(ch, lx, lz)) continue;
            for (0..256) |y| {
                const post: u4 = @truncate(bleedRead(ch, lx, y, lz)[ci]);
                if (post == 0) continue;
                if (channel == .sky and chunk_mod.lightOpacity(ch.blockAt(lx, y, lz)) == 255) continue;
                const cur: u4 = @truncate(bleedRead(nch, nx, y, nz)[ci]);
                const op = chunk_mod.lightOpacity(nch.blockAt(nx, y, nz));
                const cost = (if (channel == .sky) chunk_mod.Chunk.skyCost(op) else chunk_mod.Chunk.blockCost(op)) orelse continue;
                const cand: u4 = if (post > cost) post - cost else continue;
                if (cand <= cur) continue;
                bleedWrite(nch, nx, y, nz, channel, cand);
                if (n_seeds < seeds.len) {
                    seeds[n_seeds] = chunk_mod.Chunk.packCell(nx, y, nz);
                    n_seeds += 1;
                }
                n_dirty = true;
            }
        }
        if (n_seeds > 0) nch.spreadLight(q, channel, seeds[0..n_seeds]);
    }
    if (n_dirty) cache.markDirty(nch);
    return n_dirty;
}

/// Raise-only second hop into a diagonal neighbor (corner edits): seed the
/// diagonal corner-adjacent cell from the two edge-neighbor cells that feed
/// it (post-bleed values, re-read from the store). Diagonal lowering stays
/// an approximation.
const CornerRef = struct { cx: i32, cz: i32, lx: usize, lz: usize };

fn bleedDiagonal(
    pool: *shard_mod.ShardPool,
    alloc: std.mem.Allocator,
    q: []u32,
    cache: *NeighborCache,
    dst: CornerRef,
    s1: CornerRef,
    s2: CornerRef,
) !bool {
    const dch = (try cache.get(pool, alloc, dst.cx, dst.cz)) orelse return false;
    const s1ch = (try cache.get(pool, alloc, s1.cx, s1.cz)) orelse return false;
    const s2ch = (try cache.get(pool, alloc, s2.cx, s2.cz)) orelse return false;
    const dlx = dst.lx;
    const dlz = dst.lz;
    const s1lx = s1.lx;
    const s1lz = s1.lz;
    const s2lx = s2.lx;
    const s2lz = s2.lz;
    var dirty = false;
    // Exact vertical sky for the corner column first (mirrors the edge
    // path: stored nibbles alone can't distinguish stale-dark from
    // enclosed, and unspread below must not erase a column-ruled value
    // it cannot rebuild).
    dch.relightColumn(dlx, dlz);
    dirty = true;
    inline for ([2]chunk_mod.Chunk.LightChannel{ .sky, .block }) |channel| {
        const ci: usize = if (channel == .sky) 0 else 1;
        // Lower first: the diagonal cell may hold light that only flowed
        // through the corner being edited away. No pre snapshot exists
        // here, so gate on the live value: only cells dimmer than their
        // own level can depend on removed inflow (same contract as the
        // edge path's cur < pre gate, with the live value standing in).
        var olds: [64]chunk_mod.Chunk.CellValue = undefined;
        var rewrites: [64]chunk_mod.Chunk.CellValue = undefined;
        var n_old: usize = 0;
        for (0..256) |y| {
            const cur: u4 = @truncate(bleedRead(dch, dlx, y, dlz)[ci]);
            if (cur == 0) continue;
            // Only unspread when the corner edit actually dropped light:
            // recompute the best inflow from the post-bleed edge chunks
            // and invalidate when the stored value exceeds it.
            const v1: u4 = @truncate(bleedRead(s1ch, s1lx, y, s1lz)[ci]);
            const v2: u4 = @truncate(bleedRead(s2ch, s2lx, y, s2lz)[ci]);
            const best: u4 = @max(v1, v2);
            const dop = chunk_mod.lightOpacity(dch.blockAt(dlx, y, dlz));
            const cost = (if (channel == .sky) chunk_mod.Chunk.skyCost(dop) else chunk_mod.Chunk.blockCost(dop)) orelse continue;
            const support: u4 = if (best > cost) best - cost else 0;
            if (cur <= support) continue;
            const own: u4 = if (channel == .block) chunk_mod.emitLight(dch.blockAt(dlx, y, dlz)) else cur;
            if (n_old >= olds.len) continue;
            olds[n_old] = .{ .cell = chunk_mod.Chunk.packCell(dlx, y, dlz), .value = cur };
            rewrites[n_old] = .{ .cell = chunk_mod.Chunk.packCell(dlx, y, dlz), .value = own };
            n_old += 1;
            dirty = true;
        }
        if (n_old > 0) dch.unspreadLight(q, channel, olds[0..n_old], rewrites[0..n_old]);
        // Raise from post-bleed edge values (re-read live: unspread may
        // have zeroed cells this pass needs to rebuild).
        var seeds: [64]u32 = undefined;
        var n_seeds: usize = 0;
        for (0..256) |y| {
            const v1: u4 = @truncate(bleedRead(s1ch, s1lx, y, s1lz)[ci]);
            const v2: u4 = @truncate(bleedRead(s2ch, s2lx, y, s2lz)[ci]);
            const best: u4 = @max(v1, v2);
            if (best == 0) continue;
            const dop = chunk_mod.lightOpacity(dch.blockAt(dlx, y, dlz));
            const cost = (if (channel == .sky) chunk_mod.Chunk.skyCost(dop) else chunk_mod.Chunk.blockCost(dop)) orelse continue;
            const cand: u4 = if (best > cost) best - cost else continue;
            const cur: u4 = @truncate(bleedRead(dch, dlx, y, dlz)[ci]);
            if (cand <= cur) continue;
            bleedWrite(dch, dlx, y, dlz, channel, cand);
            if (n_seeds < seeds.len) {
                seeds[n_seeds] = chunk_mod.Chunk.packCell(dlx, y, dlz);
                n_seeds += 1;
            }
            dirty = true;
        }
        if (n_seeds > 0) dch.spreadLight(q, channel, seeds[0..n_seeds]);
    }
    if (!dirty) return false;
    cache.markDirty(dch);
    return true;
}

/// Bleed border deltas of an edited chunk into adjacent neighbors.
/// `pre` holds the pre-edit border faces (both channels); `lx`/`lz` locate
/// the edit. Owned neighbor chunks are written back before return.
/// Returns the touched-neighbor mask (bits 0-3: W,E,N,S; bits 4-7:
/// NW,NE,SW,SE) for targeted viewer resends.
pub fn bleedBorders(
    pool: *shard_mod.ShardPool,
    alloc: std.mem.Allocator,
    q: []u32,
    ch: *chunk_mod.Chunk,
    cx: i32,
    cz: i32,
    lx: usize,
    lz: usize,
    pre: *const [4][3][16][256]u8,
) !u8 {
    // Forward FIRST: push edited-chunk border deltas into neighbors.
    // This must precede the reverse pull below: on removal the neighbors
    // still hold stale light, and pulling first would resurrect it into
    // the edited chunk (then forward re-bleeds the ghost as 11s).
    // Neighbor chunks are shared with the reverse pass and diagonal hop
    // below via the cache (one decode + one write-back per neighbor).
    var cache = NeighborCache{};
    defer cache.deinit(alloc);
    var touched: u8 = 0;
    for (all_sides) |s| {
        if (try bleedSide(pool, alloc, q, ch, cx, cz, s.side, &pre[s.pre_idx][0], &pre[s.pre_idx][1], &pre[s.pre_idx][2], &cache)) {
            touched |= @as(u8, 1) << s.bit;
        }
    }
    // Reverse pass: pull cross-border inflow into the edited chunk from
    // post-bleed neighbors (same-chunk relight above cannot see across
    // the border; e.g. an under-roof cell whose only open direction faces
    // the neighbor). Reads post-forward values so removals don't resurrect
    // stale light. Idempotent: skips when nothing flows.
    for (channels) |channel| {
        const ci: usize = if (channel == .sky) 0 else 1;
        var seeds: [4096]u32 = undefined;
        var n_seeds: usize = 0;
        for (all_sides) |s| {
            const nch = (try cache.get(pool, alloc, cx + s.dx, cz + s.dz)) orelse continue;
            for (0..16) |a| {
                const ec = edgeCell(s.side, a);
                const nc = neighborCell(s.side, a);
                const ex = ec.x;
                const ez = ec.z;
                const nx = nc.x;
                const nz = nc.z;
                // Sky never flows out of opaque cells (mirrors bfsRaise).
                if (channel == .sky and columnSolid(nch, nx, nz)) continue;
                for (0..256) |y| {
                    const nv: u4 = @truncate(bleedRead(nch, nx, y, nz)[ci]);
                    if (nv == 0) continue;
                    if (channel == .sky and chunk_mod.lightOpacity(nch.blockAt(nx, y, nz)) == 255) continue;
                    const op = chunk_mod.lightOpacity(ch.blockAt(ex, y, ez));
                    const cost = (if (channel == .sky) chunk_mod.Chunk.skyCost(op) else chunk_mod.Chunk.blockCost(op)) orelse continue;
                    const cand: u4 = if (nv > cost) nv - cost else continue;
                    const cur: u4 = @truncate(bleedRead(ch, ex, y, ez)[ci]);
                    if (cand <= cur) continue;
                    bleedWrite(ch, ex, y, ez, channel, cand);
                    if (n_seeds < seeds.len) {
                        seeds[n_seeds] = chunk_mod.Chunk.packCell(ex, y, ez);
                        n_seeds += 1;
                    }
                }
            }
        }
        if (n_seeds > 0) ch.spreadLight(q, channel, seeds[0..n_seeds]);
    }
    // Diagonal raise hop for exact-corner edits with a changed corner cell.
    // (Single-edge changes are covered: the unchanged side contributes its
    // stored values, re-read here.)
    const on_w = lx == 0;
    const on_e = lx == 15;
    const on_n = lz == 0;
    const on_s = lz == 15;
    if (on_w and on_n and cornerCellChanged(ch, 0, 0, &pre[0], 0, &pre[2], 0)) {
        if (try bleedDiagonal(pool, alloc, q, &cache, .{ .cx = cx - 1, .cz = cz - 1, .lx = 15, .lz = 15 }, .{ .cx = cx - 1, .cz = cz, .lx = 15, .lz = 0 }, .{ .cx = cx, .cz = cz - 1, .lx = 0, .lz = 15 })) touched |= 1 << 4;
    } else if (on_e and on_n and cornerCellChanged(ch, 15, 0, &pre[1], 0, &pre[2], 15)) {
        if (try bleedDiagonal(pool, alloc, q, &cache, .{ .cx = cx + 1, .cz = cz - 1, .lx = 0, .lz = 15 }, .{ .cx = cx + 1, .cz = cz, .lx = 0, .lz = 0 }, .{ .cx = cx, .cz = cz - 1, .lx = 15, .lz = 15 })) touched |= 1 << 5;
    } else if (on_w and on_s and cornerCellChanged(ch, 0, 15, &pre[0], 15, &pre[3], 0)) {
        if (try bleedDiagonal(pool, alloc, q, &cache, .{ .cx = cx - 1, .cz = cz + 1, .lx = 15, .lz = 0 }, .{ .cx = cx - 1, .cz = cz, .lx = 15, .lz = 15 }, .{ .cx = cx, .cz = cz + 1, .lx = 0, .lz = 0 })) touched |= 1 << 6;
    } else if (on_e and on_s and cornerCellChanged(ch, 15, 15, &pre[1], 15, &pre[3], 15)) {
        if (try bleedDiagonal(pool, alloc, q, &cache, .{ .cx = cx + 1, .cz = cz + 1, .lx = 0, .lz = 0 }, .{ .cx = cx + 1, .cz = cz, .lx = 0, .lz = 15 }, .{ .cx = cx, .cz = cz + 1, .lx = 15, .lz = 0 })) touched |= 1 << 7;
    }
    try cache.flush(pool, alloc);
    return touched;
}

/// True when the edited corner cell changed on either channel (gates the
/// diagonal hop; unchanged corners imply unchanged diagonal inflow).
fn cornerCellChanged(
    ch: *chunk_mod.Chunk,
    clx: usize,
    clz: usize,
    pre_a: *const [3][16][256]u8,
    aa: usize,
    pre_b: *const [3][16][256]u8,
    ab: usize,
) bool {
    for (0..256) |y| {
        const v = bleedRead(ch, clx, y, clz);
        if (v[0] != pre_a[0][aa][y] or v[1] != pre_a[1][aa][y]) return true;
        if (v[0] != pre_b[0][ab][y] or v[1] != pre_b[1][ab][y]) return true;
        const op: u8 = chunk_mod.lightOpacity(ch.blockAt(clx, y, clz));
        if (op != pre_a[2][aa][y] or op != pre_b[2][ab][y]) return true;
    }
    return false;
}

/// Read one column's sky nibbles (top-down) into `out`.
pub fn skyColumn(ch: *const chunk_mod.Chunk, lx: usize, lz: usize, out: *[256]u8) void {
    var y: usize = 0;
    while (y < 256) : (y += 1) {
        if (ch.sections[y >> 4]) |s| {
            out[y] = chunk_mod.Section.getNibble(&s.sky, chunk_mod.Section.index(@intCast(lx), @truncate(y & 15), @intCast(lz)));
        } else {
            out[y] = 0;
        }
    }
}
