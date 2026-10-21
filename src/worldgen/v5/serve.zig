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
const view_mod = @import("../../sim/view.zig");
const spin_mod = @import("../../sim/spin.zig");
const gen_mod = @import("gen.zig");
const genpool_mod = @import("genpool.zig");
const shaper_mod = @import("shaper.zig");
const ids = @import("../../ids.zig");

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
    if (try pool.get(key)) |raw| return raw;
    lock.lock();
    defer lock.unlock();
    // Recheck under lock (another conn may have filled it).
    if (try pool.get(key)) |raw| return raw;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const ch = try gen.genChunk(alloc, arena.allocator(), cx, cz);
    defer ch.destroy(alloc);
    try pool.putChunk(ch);
    return try pool.get(key);
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
            // Returned bytes are owned by `allocator` (duped); pool-owned
            // bytes are freed with the pool allocator, never the caller's
            // (serve threads pass a per-call frame arena).
            const key = store_mod.encodeKey(dim, x, z);
            if (s.pool.get(key) catch null) |raw| {
                defer s.pool.allocator.free(raw);
                return allocator.dupe(u8, raw) catch null;
            }
            gp.request(dim, x, z);
            return null;
        }
        if (getOrGen(s.pool, s.gen, s.lock, dim, x, z, allocator) catch null) |raw| {
            defer s.pool.allocator.free(raw);
            return allocator.dupe(u8, raw) catch null;
        }
        return null;
    }
};

/// Spiral offsets for radius r (center first), same order as view.Spiral
/// but over chunk coords with an explicit bound.
pub const Spiral = struct {
    radius: i32,
    ring: i32 = 0,
    idx: usize = 0,

    pub fn next(self: *Spiral) ?struct { dx: i32, dz: i32 } {
        if (self.ring == 0) {
            self.ring = 1;
            return .{ .dx = 0, .dz = 0 };
        }
        while (self.ring <= self.radius) {
            const per: usize = @intCast(8 * self.ring);
            if (self.idx < per) {
                const side: usize = @intCast(2 * self.ring);
                const i = self.idx;
                self.idx += 1;
                const r = self.ring;
                if (i < side) return .{ .dx = -r + @as(i32, @intCast(i)), .dz = -r };
                if (i < 2 * side) return .{ .dx = r, .dz = -r + @as(i32, @intCast(i - side)) };
                if (i < 3 * side) return .{ .dx = r - @as(i32, @intCast(i - 2 * side)), .dz = r };
                return .{ .dx = -r, .dz = r - @as(i32, @intCast(i - 3 * side)) };
            }
            self.ring += 1;
            self.idx = 0;
        }
        return null;
    }
};

/// Find a land spawn: spiral chunks, first column with solid ground above
/// sea level. Falls back to (8.5, 70, 8.5) after max_chunks attempts.
pub const Spawn = struct { x: f64, y: f64, z: f64 };

pub fn findSpawn(
    pool: *shard_mod.ShardPool,
    gen: *gen_mod.Gen,
    lock: *spin_mod.SpinLock,
    alloc: std.mem.Allocator,
    max_chunks: usize,
) !Spawn {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var sp = Spiral{ .radius = 8 };
    var done: usize = 0;
    while (sp.next()) |off| {
        if (done >= max_chunks) break;
        done += 1;
        const cx = off.dx;
        const cz = off.dz;
        const key = store_mod.encodeKey(0, cx, cz);
        const found: ?Spawn = blk: {
            const have = try pool.get(key);
            var ch: *chunk_mod.Chunk = undefined;
            if (have) |raw| {
                defer pool.allocator.free(raw);
                ch = try chunk_mod.Chunk.decode(alloc, raw);
            } else {
                lock.lock();
                defer lock.unlock();
                const ch2 = gen.genChunk(alloc, arena.allocator(), cx, cz) catch break :blk null;
                errdefer ch2.destroy(alloc);
                try pool.putChunk(ch2);
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
    return .{ .x = @as(f64, 8.5), .y = @as(f64, 70.0), .z = @as(f64, 8.5) };
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
            const key = store_mod.encodeKey(0, off.dx, off.dz);
            if (try pool.get(key)) |raw| {
                pool.allocator.free(raw);
                continue;
            }
            p.request(0, off.dx, off.dz);
            n += 1;
        }
        p.drain();
        return n;
    }
    while (sp.next()) |off| {
        const key = store_mod.encodeKey(0, off.dx, off.dz);
        if (try pool.get(key)) |raw| {
            pool.allocator.free(raw);
            continue;
        }
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        lock.lock();
        defer lock.unlock();
        const ch = try gen.genChunk(alloc, arena.allocator(), off.dx, off.dz);
        defer ch.destroy(alloc);
        try pool.putChunk(ch);
        n += 1;
    }
    return n;
}
