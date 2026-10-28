//! v5 generation serving glue (H2 sync-first path).
//!
//! Holes in the LSM (ungenerated columns) are filled on demand: generate,
//! store, serve. Generation is serialized under the caller's lock because
//! GenLayer chain states mutate per call (documented H2 limitation; the
//! background gen job removes generation from request paths entirely).
//! Spawn search + boot pre-gen live here too.

const std = @import("std");
const shard_mod = @import("../../world/shard.zig");
const store_mod = @import("../../world/store.zig");
const chunk_mod = @import("../../world/chunk.zig");
const view_mod = @import("../../sim/world/view.zig");
const spin_mod = @import("../../sim/core/spin.zig");
const gen_mod = @import("gen.zig");
const genpool_mod = @import("genpool.zig");
const shaper_mod = @import("shaper.zig");
const burst_mod = @import("../../sim/world/view/burst.zig");
const ids = @import("../../ids.zig");

/// Spiral offsets for chunk-radius walks (login spawn search, pre-gen).
/// Single home is the view burst's Spiral (identical order); this alias
/// keeps serve call sites + the server.zig comments naming serve.Spiral.
pub const Spiral = burst_mod.Spiral;

/// Get-or-generate one column's ZC1 bytes (owned by `alloc`).
/// Lock must serialize concurrent gen (chain states) + pool RMW.
pub fn getOrGen(
    pool: *shard_mod.ShardPool,
    gen: *gen_mod.Gen,
    lock: *spin_mod.SpinLock,
    dim: u8,
    cx: i32,
    cz: i32,
    alloc: std.mem.Allocator,
) !?[]u8 {
    const key = store_mod.encodeKey(dim, cx, cz);
    if (try pool.get(alloc, key)) |raw| return raw;
    lock.lock();
    defer lock.unlock();
    // Recheck under lock (another conn may have filled it).
    if (try pool.get(alloc, key)) |raw| return raw;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const ch = try gen.genChunk(alloc, arena.allocator(), cx, cz);
    defer ch.destroy(alloc);
    try pool.putChunk(alloc, ch);
    return try pool.get(alloc, key);
}

/// view.Source over getOrGen. ctx must outlive use (store in Server).
/// With `gen_pool` set, misses enqueue background jobs and serve holes
/// (serveConn retries when the pool sequence advances); without it, the
/// caller blocks in sync `getOrGen` (tests, no-seed fallback).
pub const GenSource = struct {
    pool: *shard_mod.ShardPool,
    gen: *gen_mod.Gen,
    lock: *spin_mod.SpinLock,
    gen_pool: ?*genpool_mod.GenPool = null,

    pub fn source(self: *GenSource) view_mod.Source {
        return .{ .ctx = self, .getFn = get };
    }

    fn get(ctx: *anyopaque, dim: u8, x: i32, z: i32, allocator: std.mem.Allocator) ?[]u8 {
        const s: *GenSource = @ptrCast(@alignCast(ctx));
        if (s.gen_pool) |gp| {
            // Miss path: the pool read uses the caller's allocator, so
            // serve threads pass a per-call frame arena (never the process
            // arena — whole-SST reads must not be retained).
            const key = store_mod.encodeKey(dim, x, z);
            if (s.pool.get(allocator, key) catch null) |raw| return raw;
            // View hole: priority lane (jumps any bulk backlog — a hole
            // under the player outranks pregen throughput).
            gp.requestPriority(dim, x, z);
            return null;
        }
        if (getOrGen(s.pool, s.gen, s.lock, dim, x, z, allocator) catch null) |raw| {
            defer allocator.free(raw);
            return allocator.dupe(u8, raw) catch null;
        }
        return null;
    }
};

/// True when the column is absent from the pool. The probe uses a frame
/// arena: pool.get reads whole SST files on hits, which must never land
/// in a long-lived (possibly never-reset) arena.
fn missing(pool: *shard_mod.ShardPool, dim: u8, x: i32, z: i32) !bool {
    var farena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer farena.deinit();
    const key = store_mod.encodeKey(dim, x, z);
    return (try pool.get(farena.allocator(), key)) == null;
}

/// Find a land spawn: spiral chunks, first column with solid ground above
/// sea level. Falls back to default_spawn after max_chunks attempts.
pub const Spawn = struct { x: f64, y: f64, z: f64 };

/// Spawn-search radius (chunks) and fallback when no land is found.
pub const spawn_search_radius: i32 = 8;
pub const default_spawn = Spawn{ .x = 8.5, .y = 70.0, .z = 8.5 };

pub fn findSpawn(
    pool: *shard_mod.ShardPool,
    gen: *gen_mod.Gen,
    lock: *spin_mod.SpinLock,
    alloc: std.mem.Allocator,
    max_chunks: usize,
) !Spawn {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var sp = Spiral{ .radius = spawn_search_radius };
    var done: usize = 0;
    while (sp.next()) |off| {
        if (done >= max_chunks) break;
        done += 1;
        const cx = off.dx;
        const cz = off.dz;
        const key = store_mod.encodeKey(0, cx, cz);
        const found: ?Spawn = blk: {
            // Scratch lifetime is this probe only: pool.get reads whole SST
            // files on hits, which must never land in a long-lived arena.
            var farena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer farena.deinit();
            const have = try pool.get(farena.allocator(), key);
            var ch: *chunk_mod.Chunk = undefined;
            if (have) |raw| {
                ch = try chunk_mod.Chunk.decode(alloc, raw);
            } else {
                lock.lock();
                defer lock.unlock();
                const ch2 = gen.genChunk(alloc, arena.allocator(), cx, cz) catch break :blk null;
                errdefer ch2.destroy(alloc);
                try pool.putChunk(farena.allocator(), ch2);
                ch = ch2;
            }
            defer ch.destroy(alloc);
            _ = arena.reset(.retain_capacity);
            for (0..16) |lz| {
                for (0..16) |lx| {
                    const top: i32 = ch.heights[lz * 16 + lx];
                    if (top <= shaper_mod.SEA_LEVEL) continue;
                    const s: usize = @intCast(@divFloor(top, 16));
                    const sec = ch.sections[s] orelse continue;
                    const lsi = chunk_mod.Section.index(@intCast(lx), @intCast(@mod(top, 16)), @intCast(lz));
                    const id = sec.blocks[lsi];
                    // NOTE: water/snow-covered tops don't count; need solid ground.
                    // Water surface also exceeds sea level — skip it.
                    if (id == ids.air or id == ids.water) continue;
                    break :blk .{
                        .x = @as(f64, @floatFromInt(cx * 16 + @as(i32, @intCast(lx)))) + 0.5,
                        .y = @as(f64, @floatFromInt(top + 1)),
                        .z = @as(f64, @floatFromInt(cz * 16 + @as(i32, @intCast(lz)))) + 0.5,
                    };
                }
            }
            break :blk null;
        };
        if (found) |f| return f;
    }
    return default_spawn;
}

/// Pre-generate a spiral disk of chunks around (0,0). Reports count.
/// With a worker pool, missing columns fan out to workers and this drains;
/// otherwise serial (the old path). Returns newly-present columns.
pub fn preGen(
    pool: *shard_mod.ShardPool,
    gen: *gen_mod.Gen,
    lock: *spin_mod.SpinLock,
    alloc: std.mem.Allocator,
    radius_chunks: i32,
    gp: ?*genpool_mod.GenPool,
) !usize {
    var n: usize = 0;
    var sp = Spiral{ .radius = radius_chunks };
    if (gp) |p| {
        while (sp.next()) |off| {
            if (try missing(pool, 0, off.dx, off.dz)) {
                p.request(0, off.dx, off.dz);
                n += 1;
            }
        }
        p.drain();
        return n;
    }
    while (sp.next()) |off| {
        if (!try missing(pool, 0, off.dx, off.dz)) continue;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        lock.lock();
        defer lock.unlock();
        const ch = try gen.genChunk(alloc, arena.allocator(), off.dx, off.dz);
        defer ch.destroy(alloc);
        try pool.putChunk(arena.allocator(), ch);
        n += 1;
    }
    return n;
}
