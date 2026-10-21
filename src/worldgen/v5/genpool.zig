//! Background chunk-generation worker pool (H5 step 1: async gen).
//!
//! Serve threads never generate inline anymore: a miss enqueues a job and
//! serves a hole. Each worker owns a private `Gen` — the GenLayer chain and
//! the carver RNG carry per-call mutable state, so one shared `Gen` across
//! threads is unsound — but every stage reseeds from (world_seed, xz) at
//! entry (`genlayer.Base.initChunkSeed`, `carver.carveChunk` reseed,
//! per-chunk shaper/surface/decor seeds), so per-worker Gens are
//! order-independent and byte-identical to sync generation.
//!
//! Workers compute lock-free, then recheck + store under the caller's world
//! lock — the same discipline as the old sync `getOrGen`, minus ~105ms of
//! noise math on the serve path. Completions bump an atomic sequence;
//! serveConn retries the view disk when it advances (holes become hits).
//! FIFO order preserves each requester's spiral (center-first) priority;
//! true cross-conn distance priority + shaped-column LRU are H5 follow-ups.

const std = @import("std");
const shard_mod = @import("../../world/shard.zig");
const store_mod = @import("../../world/store.zig");
const chunk_mod = @import("../../world/chunk.zig");
const spin_mod = @import("../../sim/spin.zig");
const ids_mod = @import("../../ids.zig");
const gen_mod = @import("gen.zig");

pub const Job = struct { dim: u8, x: i32, z: i32 };

pub const Stats = struct {
    requested: u64 = 0,
    deduped: u64 = 0,
    completed: u64 = 0,
    failed: u64 = 0,
    dropped: u64 = 0,
};

/// Backpressure: beyond this many queued jobs the pool sheds load (holes
/// stay holes until the next retry, same as the old sync path under pressure).
pub const max_pending = 4096;

fn keyOf(dim: u8, x: i32, z: i32) store_mod.ChunkKey {
    return store_mod.encodeKey(dim, x, z);
}

pub const GenPool = struct {
    io: std.Io,
    alloc: std.mem.Allocator, // pool GPA (thread-safe): queue + worker Gens
    gpa: std.heap.DebugAllocator(.{ .thread_safe = true }),
    pool: *shard_mod.ShardPool,
    lock: *spin_mod.SpinLock, // world lock: recheck + store only, never compute
    seed: i64,
    large_biomes: bool,
    amplified: bool,

    mutex: std.Io.Mutex = .init,
    work_avail: std.Io.Condition = .init,
    drained: std.Io.Condition = .init,
    queue: std.ArrayList(Job) = .empty,
    head: usize = 0,
    inflight: std.AutoHashMap(store_mod.ChunkKey, void) = undefined,
    active: usize = 0,
    running: bool = true,

    gens: []gen_mod.Gen = &[_]gen_mod.Gen{},
    threads: []std.Thread = &[_]std.Thread{},
    seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    stats: Stats = .{},

    /// Heap-allocates the pool (thread entry takes a stable pointer) and
    /// spawns `n_workers`, each with its own `Gen`. `pool`/`lock` must
    /// outlive the GenPool (same lifetime rule as `GenSource`). The caller
    /// frees the returned pointer with its `backing` allocator after
    /// `destroy()` (see main.zig / tests).
    pub fn create(
        backing: std.mem.Allocator,
        io: std.Io,
        pool: *shard_mod.ShardPool,
        lock: *spin_mod.SpinLock,
        seed: i64,
        large_biomes: bool,
        amplified: bool,
        n_workers: usize,
    ) !*GenPool {
        const self = try backing.create(GenPool);
        errdefer backing.destroy(self);
        self.* = .{
            .io = io,
            .alloc = undefined,
            .gpa = std.heap.DebugAllocator(.{ .thread_safe = true }){},
            .pool = pool,
            .lock = lock,
            .seed = seed,
            .large_biomes = large_biomes,
            .amplified = amplified,
        };
        self.alloc = self.gpa.allocator();
        errdefer _ = self.gpa.deinit();
        self.queue = .empty;
        self.inflight = std.AutoHashMap(store_mod.ChunkKey, void).init(self.alloc);
        const n = @max(1, n_workers);
        self.gens = try self.alloc.alloc(gen_mod.Gen, n);
        errdefer self.alloc.free(self.gens);
        var made: usize = 0;
        errdefer {
            for (self.gens[0..made]) |*g| g.deinit();
        }
        for (self.gens) |*g| {
            g.* = try gen_mod.Gen.init(self.alloc, seed, large_biomes, amplified);
            made += 1;
        }
        self.threads = try self.alloc.alloc(std.Thread, n);
        errdefer self.alloc.free(self.threads);
        var spawned: usize = 0;
        errdefer {
            self.mutex.lockUncancelable(self.io);
            self.running = false;
            self.mutex.unlock(self.io);
            self.work_avail.broadcast(self.io);
            for (self.threads[0..spawned]) |th| th.join();
            for (self.gens) |*g| g.deinit();
        }
        for (self.threads, 0..) |*th, i| {
            th.* = try std.Thread.spawn(.{}, workerMain, .{ self, i });
            spawned += 1;
        }
        return self;
    }

    /// Stop workers and free pool-owned state (not `self` itself). A stop
    /// with queued jobs drops them; serve threads re-request on retry, and
    /// boot callers `drain()` first.
    pub fn destroy(self: *GenPool) void {
        self.mutex.lockUncancelable(self.io);
        self.running = false;
        self.mutex.unlock(self.io);
        self.work_avail.broadcast(self.io);
        for (self.threads) |th| th.join();
        for (self.gens) |*g| g.deinit();
        self.alloc.free(self.threads);
        self.alloc.free(self.gens);
        self.queue.deinit(self.alloc);
        self.inflight.deinit();
        _ = self.gpa.deinit();
    }

    /// Enqueue a miss. Dedupes against in-flight work (the worker rechecks
    /// the LSM under the world lock anyway, so races resolve to one store).
    /// Drops the job if the pool is stopped.
    pub fn request(self: *GenPool, dim: u8, x: i32, z: i32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.running) return;
        const k = keyOf(dim, x, z);
        self.stats.requested += 1;
        if (self.inflight.contains(k)) {
            self.stats.deduped += 1;
            return;
        }
        if (self.queue.items.len - self.head >= max_pending) {
            self.stats.dropped += 1;
            return;
        }
        self.inflight.put(k, {}) catch return;
        self.queue.append(self.alloc, .{ .dim = dim, .x = x, .z = z }) catch {
            _ = self.inflight.remove(k);
            return;
        };
        self.work_avail.signal(self.io);
    }

    /// Completed-store sequence. Serve threads retry the view disk when this
    /// advances (the store is guaranteed visible: put precedes the bump).
    pub fn sequence(self: *GenPool) u64 {
        return self.seq.load(.acquire);
    }

    pub fn pending(self: *GenPool) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return (self.queue.items.len - self.head) + self.active;
    }

    pub fn snapshotStats(self: *GenPool) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.stats;
    }

    /// Block until the queue is empty and no worker is mid-job (boot pre-gen,
    /// tests). Workers hold no locks while computing, so this only waits.
    pub fn drain(self: *GenPool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.queue.items.len - self.head > 0 or self.active > 0) {
            self.drained.waitUncancelable(self.io, &self.mutex);
        }
    }

    fn workerMain(self: *GenPool, idx: usize) void {
        const gen = &self.gens[idx];
        while (true) {
            var job: Job = undefined;
            self.mutex.lockUncancelable(self.io);
            while (self.head >= self.queue.items.len and self.running) {
                self.work_avail.waitUncancelable(self.io, &self.mutex);
            }
            if (self.head >= self.queue.items.len) {
                // Stopped with an empty queue.
                self.mutex.unlock(self.io);
                return;
            }
            job = self.queue.items[self.head];
            self.head += 1;
            if (self.head >= self.queue.items.len) {
                // Queue fully consumed: reset so the backing doesn't grow
                // across a long run; in-flight set still guards duplicates.
                self.queue.clearRetainingCapacity();
                self.head = 0;
            }
            self.active += 1;
            self.mutex.unlock(self.io);

            self.runJob(gen, job);

            self.mutex.lockUncancelable(self.io);
            self.active -= 1;
            _ = self.inflight.remove(keyOf(job.dim, job.x, job.z));
            if (self.queue.items.len - self.head == 0 and self.active == 0) {
                self.drained.signal(self.io);
            }
            self.mutex.unlock(self.io);
        }
    }

    fn runJob(self: *GenPool, gen: *gen_mod.Gen, job: Job) void {
        const k = keyOf(job.dim, job.x, job.z);
        // Fast path: another conn (or pre-gen) filled it while queued.
        if (self.pool.get(self.alloc, k) catch null) |raw| {
            self.alloc.free(raw);
            return;
        }
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const ch = gen.genChunk(self.alloc, arena.allocator(), job.x, job.z) catch {
            // Failures behave like today's holes (fixed on move/resync): no
            // sequence bump, so serve threads don't spin on a poison column.
            self.mutex.lockUncancelable(self.io);
            self.stats.failed += 1;
            self.mutex.unlock(self.io);
            return;
        };
        defer ch.destroy(self.alloc);
        // Narrow critical section: recheck + store only.
        self.lock.lock();
        defer self.lock.unlock();
        if (self.pool.get(self.alloc, k) catch null) |raw| {
            self.alloc.free(raw);
            return;
        }
        self.pool.putChunk(self.alloc, ch) catch {
            self.mutex.lockUncancelable(self.io);
            self.stats.failed += 1;
            self.mutex.unlock(self.io);
            return;
        };
        _ = self.seq.fetchAdd(1, .acq_rel);
        self.mutex.lockUncancelable(self.io);
        self.stats.completed += 1;
        self.mutex.unlock(self.io);
    }
};

test "pool generates missing chunks in parallel, byte-identical to sync gen" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    var lock: spin_mod.SpinLock = .{};
    var gp = try GenPool.create(a, io, pool, &lock, 42, false, false, 2);
    defer {
        gp.destroy();
        a.destroy(gp);
    }
    // Request a spread of columns (incl. duplicates to exercise dedup).
    const want = [_][2]i32{ .{ 0, 0 }, .{ 3, -5 }, .{ -2, 7 }, .{ 5, 5 }, .{ 0, 0 }, .{ 3, -5 } };
    for (want) |c| gp.request(0, c[0], c[1]);
    gp.drain();
    try std.testing.expectEqual(@as(usize, 0), gp.pending());
    // Every requested column is now stored...
    for (want[0..4]) |c| {
        const got = try pool.getChunk(a, 0, c[0], c[1]);
        try std.testing.expect(got != null);
        defer got.?.destroy(a);
    }
    // ...and byte-identical to single-threaded sync generation.
    var ref = try gen_mod.Gen.init(a, 42, false, false);
    defer ref.deinit();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    for (want[0..4]) |c| {
        const ref_ch = try ref.genChunk(a, arena.allocator(), c[0], c[1]);
        defer ref_ch.destroy(a);
        const got = try pool.getChunk(a, 0, c[0], c[1]);
        defer got.?.destroy(a);
        try std.testing.expectEqual(ref_ch.mask(), got.?.mask());
        try std.testing.expectEqualSlices(u8, &ref_ch.biomes, &got.?.biomes);
        try std.testing.expectEqualSlices(u8, &ref_ch.heights, &got.?.heights);
        for (0..16) |s| {
            if (ref_ch.sections[s]) |rs| {
                try std.testing.expect(got.?.sections[s] != null);
                const gs = &got.?.sections[s].?;
                try std.testing.expectEqualSlices(ids_mod.Id, &rs.blocks, &gs.blocks);
                try std.testing.expectEqualSlices(u8, &rs.meta, &gs.meta);
                try std.testing.expectEqualSlices(u8, &rs.sky, &gs.sky);
                try std.testing.expectEqualSlices(u8, &rs.light, &gs.light);
            } else {
                try std.testing.expect(got.?.sections[s] == null);
            }
        }
    }
    const st = gp.snapshotStats();
    try std.testing.expectEqual(@as(u64, want.len), st.requested);
    try std.testing.expect(st.completed >= 4);
}

test "pool skips already-stored chunks without generating" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    var lock: spin_mod.SpinLock = .{};
    // Store one chunk directly (sync path).
    {
        var ref = try gen_mod.Gen.init(a, 1, false, false);
        defer ref.deinit();
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const ch = try ref.genChunk(a, arena.allocator(), 0, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
    }
    var gp = try GenPool.create(a, io, pool, &lock, 1, false, false, 1);
    defer {
        gp.destroy();
        a.destroy(gp);
    }
    gp.request(0, 0, 0);
    gp.drain();
    const st = gp.snapshotStats();
    try std.testing.expectEqual(@as(u64, 0), st.completed);
    try std.testing.expectEqual(@as(u64, 0), st.failed);
}
