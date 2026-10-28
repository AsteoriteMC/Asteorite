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
//! Workers compute lock-free, recheck under the caller's world lock, then
//! store under the store's own mutex (never the world lock: the serve
//! thread busy-spins on it for every click, so holding it across encode +
//! LSM put + synchronous flush/compact used to freeze gameplay for seconds
//! during bulk generation). Completions bump an atomic sequence;
//! serveConn retries the view disk when it advances (holes become hits).
//! FIFO order preserves each requester's spiral (center-first) priority;
//! true cross-conn distance priority + shaped-column LRU are H5 follow-ups.

const std = @import("std");
const shard_mod = @import("../../world/shard.zig");
const store_mod = @import("../../world/store.zig");
const chunk_mod = @import("../../world/chunk.zig");
const spin_mod = @import("../../sim/core/spin.zig");
const ids_mod = @import("../../ids.zig");
const gen_mod = @import("gen.zig");
const decor_mod = @import("decor.zig");
// Phase G fill offload (per-worker GPU contexts; null = CPU everywhere).
const gpufill_mod = @import("../../gpu/fill.zig");

pub const Job = struct { dim: u8, x: i32, z: i32 };

pub const Stats = struct {
    requested: u64 = 0,
    deduped: u64 = 0,
    completed: u64 = 0,
    failed: u64 = 0,
    dropped: u64 = 0,
    /// Store hits: jobs that found the chunk already in the LSM (queued
    /// duplicate filled while waiting, or re-requested stored chunk).
    /// Distinct from `completed` (fresh generation + store). Together they
    /// measure total job throughput vs fresh-generation throughput.
    store_hits: u64 = 0,
    /// Fills completed on the GPU (Phase G v1 sync offload).
    gpu_fill: u64 = 0,
    /// GPU fills declined/failed over to the CPU reference path.
    gpu_fallback: u64 = 0,
    /// GPU dispatches submitted (fills / dispatches = average batch size;
    /// a collapse toward 1 with flat speed points at dispatch overhead,
    /// not fill work).
    gpu_batches: u64 = 0,
    /// Column-cache hits (columns served without regen).
    cache_hits: u64 = 0,
    /// Column-cache misses (columns generated + stored).
    cache_misses: u64 = 0,
    /// Column-cache duplicate misses (concurrent same-key misses).
    cache_dup_misses: u64 = 0,
    /// Single-flight waiter hits (awaited producer, reused bytes).
    cache_single_flight_hits: u64 = 0,
    /// Ore-geometry cache hits (segment recipes reused across hosts).
    ore_hits: u64 = 0,
    /// Ore-geometry cache misses (recipes computed + stored).
    ore_misses: u64 = 0,
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
    /// Per-worker scratch arenas (page-backed, retained across jobs):
    /// genChunk temp buffers live here, so steady state performs zero
    /// backing-allocator calls per chunk (no mmap churn, no GPA lock).
    /// Index-parallel to gens; only worker i touches scratch[i].
    scratch: []std.heap.ArenaAllocator = &[_]std.heap.ArenaAllocator{},
    threads: []std.Thread = &[_]std.Thread{},
    seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    stats: Stats = .{},
    /// Shared GPU context (one device family pick for the pool; null runs
    /// every worker on CPU). Owned by the pool; destroyed in destroy().
    gpu_ctx: ?*gpufill_mod.GpuCtx = null,
    /// Per-worker GPU fill state, parallel to gens (null entries run CPU).
    /// Owned by the pool; destroyed in destroy().
    gpu_fills: []?*gpufill_mod.GpuFill = &[_]?*gpufill_mod.GpuFill{},
    /// Shared post-carve column cache (Phase H1): memoizes genFlat output
    /// across workers and chunks. Wired into every worker Gen at create
    /// (null cache = every worker regenerates; correct, just slower).
    col_cache: ?gen_mod.ColumnCache = null,
    /// Shared ore-geometry cache: ellipsoid recipes keyed by entry RNG
    /// state + coords, reused across workers/chunks. Null = reference
    /// path (correct, just slower). Wired into every worker Gen.
    ore_cache: ?decor_mod.OreCache = null,
    /// Master switch for cache wiring (tests null worker caches directly).
    cache_on: bool = true,

    /// Stop signal: workers exit once the queue drains (shared by
    /// destroy and the create-failure unwind).
    fn signalStop(self: *GenPool) void {
        self.mutex.lockUncancelable(self.io);
        self.running = false;
        self.mutex.unlock(self.io);
        self.work_avail.broadcast(self.io);
    }

    /// Queued (unstarted) job count. Call with the mutex held.
    fn pendingLocked(self: *const GenPool) usize {
        return self.queue.items.len - self.head;
    }

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
        gpu_opts: gpufill_mod.Options,
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
        // Phase H1: shared column cache (fixed slots, freed in destroy).
        // Soft-fail like the GPU path: no cache = every worker regenerates
        // (correct, just slower). Wired into each worker Gen below.
        self.col_cache = gen_mod.ColumnCache.init(self.alloc, io, gen_mod.column_cache_cap) catch null;
        errdefer if (self.col_cache) |*cc| cc.deinit();
        // Shared ore-geometry cache (correct partial populate sharing across
        // workers; null = reference minable path). Soft-fail like above.
        self.ore_cache = decor_mod.OreCache.init(self.alloc, io) catch null;
        errdefer if (self.ore_cache) |*oc| oc.deinit();
        // Phase G: shared GPU context (null = every worker CPU-only). The
        // context outlives the per-worker fills below; destroy() tears both
        // down. Soft-fail by design: no driver/device/compute/float64 means
        // correct CPU generation, never a boot failure.
        if (gpu_opts.enabled) {
            const pref: gpufill_mod.DevicePref = switch (gpu_opts.device) {
                .auto => .auto,
                .discrete => .discrete,
                .integrated => .integrated,
                .cpu => .cpu,
            };
            self.gpu_ctx = try gpufill_mod.GpuCtx.init(self.alloc, pref);
        }
        errdefer if (self.gpu_ctx) |ctx| {
            ctx.deinit(self.alloc);
            self.gpu_ctx = null;
        };
        const n = @max(1, n_workers);
        self.gens = try self.alloc.alloc(gen_mod.Gen, n);
        errdefer self.alloc.free(self.gens);
        self.gpu_fills = try self.alloc.alloc(?*gpufill_mod.GpuFill, n);
        errdefer self.alloc.free(self.gpu_fills);
        @memset(self.gpu_fills, null);
        // Per-worker scratch arenas (page-backed: never the contended
        // GPA). Retained across jobs — steady state performs zero
        // backing-allocator calls per chunk.
        self.scratch = try self.alloc.alloc(std.heap.ArenaAllocator, n);
        errdefer self.alloc.free(self.scratch);
        var made_scratch: usize = 0;
        errdefer {
            for (self.scratch[0..made_scratch]) |*sa| sa.deinit();
        }
        for (self.scratch) |*sa| {
            sa.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            made_scratch += 1;
        }
        errdefer {
            for (self.gpu_fills) |maybe_fill| {
                if (maybe_fill) |gf| {
                    gf.deinit();
                    self.alloc.destroy(gf);
                }
            }
        }
        var made: usize = 0;
        errdefer {
            for (self.gens[0..made]) |*g| g.deinit();
            for (self.scratch) |*sa| sa.deinit();
        }
        for (self.gens, self.gpu_fills) |*g, *gf_slot| {
            g.* = try gen_mod.Gen.init(self.alloc, seed, large_biomes, amplified);
            made += 1;
            // Per-worker device + queue + pipeline (no cross-thread GPU
            // sharing, mirroring the per-worker Gen rule). Null keeps this
            // worker on CPU; genFlat falls back per fill.
            if (self.gpu_ctx) |ctx| {
                if (gpufill_mod.GpuFill.init(ctx, self.alloc)) |gf| {
                    gf_slot.* = gf;
                    g.gpu = gf;
                    // Floor at 9 (one game chunk = one dispatch): smaller
                    // caps only multiply fence waits with no benefit.
                    g.gpu_batch = @min(@max(gpu_opts.max_batch, 9), gpufill_mod.batch_cap);
                }
            }
            // Phase H1: shared column cache (null = regenerate per chunk).
            g.cache = if (self.cache_on) if (self.col_cache) |*cc| cc else null else null;
            // Shared ore-geometry cache (null = reference minable path).
            g.ore_cache = if (self.cache_on) if (self.ore_cache) |*oc| oc else null else null;
        }
        self.threads = try self.alloc.alloc(std.Thread, n);
        errdefer self.alloc.free(self.threads);
        var spawned: usize = 0;
        errdefer {
            self.signalStop();
            for (self.threads[0..spawned]) |th| th.join();
            for (self.gens) |*g| g.deinit();
            for (self.scratch) |*sa| sa.deinit();
            self.alloc.free(self.scratch);
            for (self.gpu_fills) |maybe_fill| {
                if (maybe_fill) |gf| {
                    gf.deinit();
                    self.alloc.destroy(gf);
                }
            }
            self.alloc.free(self.gpu_fills);
            if (self.gpu_ctx) |ctx| ctx.deinit(self.alloc);
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
        self.signalStop();
        for (self.threads) |th| th.join();
        for (self.gens) |*g| g.deinit();
        for (self.gpu_fills) |maybe_fill| {
            if (maybe_fill) |gf| {
                gf.deinit();
                self.alloc.destroy(gf);
            }
        }
        self.alloc.free(self.gpu_fills);
        if (self.gpu_ctx) |ctx| ctx.deinit(self.alloc);
        self.alloc.free(self.threads);
        self.alloc.free(self.gens);
        self.queue.deinit(self.alloc);
        self.inflight.deinit();
        if (self.col_cache) |*cc| cc.deinit();
        if (self.ore_cache) |*oc| oc.deinit();
        for (self.scratch) |*sa| sa.deinit();
        self.alloc.free(self.scratch);
        _ = self.gpa.deinit();
    }

    /// Enqueue a miss. Dedupes against in-flight work (the worker rechecks
    /// the LSM under the world lock anyway, so races resolve to one store).
    /// Drops the job if the pool is stopped.
    pub fn request(self: *GenPool, dim: u8, x: i32, z: i32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.requestLocked(dim, x, z, false);
    }

    /// Enqueue a miss at the FRONT of the queue (view/login holes). Bulk
    /// backlogs (pregen, boot pre-gen) sit thousands deep; without a lane,
    /// a hole under the player waits behind all of them (~seconds) even
    /// though a worker is free. View/login traffic is sporadic next to
    /// bulk generation, so preemption stays brief and pregen keeps flowing
    /// between. An already-queued job is promoted instead of duplicated.
    pub fn requestPriority(self: *GenPool, dim: u8, x: i32, z: i32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.requestLocked(dim, x, z, true);
    }

    /// Queue body with the mutex held (pendingLocked convention).
    fn requestLocked(self: *GenPool, dim: u8, x: i32, z: i32, priority: bool) void {
        if (!self.running) return;
        const k = keyOf(dim, x, z);
        self.stats.requested += 1;
        if (self.inflight.contains(k)) {
            self.stats.deduped += 1;
            if (priority) self.promoteLocked(k);
            return;
        }
        if (self.pendingLocked() >= max_pending) {
            self.stats.dropped += 1;
            return;
        }
        self.inflight.put(k, {}) catch return;
        if (priority) {
            // Front of the unconsumed queue (workers take queue[head]).
            self.queue.insert(self.alloc, self.head, .{ .dim = dim, .x = x, .z = z }) catch {
                _ = self.inflight.remove(k);
                return;
            };
        } else {
            self.queue.append(self.alloc, .{ .dim = dim, .x = x, .z = z }) catch {
                _ = self.inflight.remove(k);
                return;
            };
        }
        self.work_avail.signal(self.io);
    }

    /// Move an already-queued job to the front (a view/login hole landing
    /// on a column the bulk backlog already holds). No-op when a worker
    /// already picked it up. Call with the mutex held.
    fn promoteLocked(self: *GenPool, k: store_mod.ChunkKey) void {
        var i = self.head;
        while (i < self.queue.items.len) : (i += 1) {
            const j = self.queue.items[i];
            if (!std.mem.eql(u8, &keyOf(j.dim, j.x, j.z), &k)) continue;
            if (i == self.head) return; // already next: nothing to do
            const job = self.queue.items[i];
            std.mem.copyBackwards(Job, self.queue.items[self.head + 1 .. i + 1], self.queue.items[self.head..i]);
            self.queue.items[self.head] = job;
            return;
        }
    }

    /// Completed-store sequence. Serve threads retry the view disk when this
    /// advances (the store is guaranteed visible: put precedes the bump).
    pub fn sequence(self: *GenPool) u64 {
        return self.seq.load(.acquire);
    }

    pub fn pending(self: *GenPool) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.pendingLocked() + self.active;
    }

    pub fn snapshotStats(self: *GenPool) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var out = self.stats;
        // Per-worker GPU counters (single-writer atomics, no lock needed
        // on the write side; summed here for the stats line).
        for (self.gpu_fills) |maybe_fill| {
            if (maybe_fill) |gf| {
                out.gpu_fill += gf.fills_ok.load(.monotonic);
                out.gpu_fallback += gf.fills_fallback.load(.monotonic);
                out.gpu_batches += gf.batches_ok.load(.monotonic);
            }
        }
        // Column-cache counters (own mutex; leaf lock, never held across
        // the pool mutex — snapshot holds pool mutex + takes cache mutex,
        // the only nesting direction in the codebase).
        if (self.col_cache) |*cc| {
            const snap = cc.snapshot();
            out.cache_hits = snap.hits;
            out.cache_misses = snap.misses;
            out.cache_dup_misses = snap.dup_misses;
            out.cache_single_flight_hits = snap.single_flight_hits;
        }
        // Shared ore-geometry counters (own mutex; same leaf-lock order).
        if (self.ore_cache) |*oc| {
            const snap = oc.snapshot();
            out.ore_hits = snap.hits;
            out.ore_misses = snap.misses;
        }
        return out;
    }

    /// True while (dim,x,z) is queued or mid-generation. Pregen progress
    /// drives its completion cursor off this (no LSM reads: a chunk leaves
    /// the set exactly when its worker finishes the store attempt).
    pub fn isInflight(self: *GenPool, dim: u8, x: i32, z: i32) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.inflight.contains(keyOf(dim, x, z));
    }

    /// Block until the queue is empty and no worker is mid-job (boot pre-gen,
    /// tests). Workers hold no locks while computing, so this only waits.
    pub fn drain(self: *GenPool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.pendingLocked() > 0 or self.active > 0) {
            self.drained.waitUncancelable(self.io, &self.mutex);
        }
    }

    fn workerMain(self: *GenPool, idx: usize) void {
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

            self.runJob(idx, job);

            self.mutex.lockUncancelable(self.io);
            self.active -= 1;
            _ = self.inflight.remove(keyOf(job.dim, job.x, job.z));
            if (self.pendingLocked() == 0 and self.active == 0) {
                self.drained.signal(self.io);
            }
            self.mutex.unlock(self.io);
        }
    }

    /// True when the store already holds the column (presence probe that
    /// frees the hit — both recheck sites share it).
    fn alreadyStored(self: *GenPool, k: store_mod.ChunkKey) bool {
        if (self.pool.get(self.alloc, k) catch null) |raw| {
            self.alloc.free(raw);
            return true;
        }
        return false;
    }

    /// Bump the failure counter (mutex-guarded stats).
    fn noteFailed(self: *GenPool) void {
        self.mutex.lockUncancelable(self.io);
        self.stats.failed += 1;
        self.mutex.unlock(self.io);
    }

    /// Bump the completion counter (mutex-guarded stats).
    fn noteCompleted(self: *GenPool) void {
        self.mutex.lockUncancelable(self.io);
        self.stats.completed += 1;
        self.mutex.unlock(self.io);
    }

    /// Bump the store-hit counter (already in LSM at recheck).
    fn noteStoreHit(self: *GenPool) void {
        self.mutex.lockUncancelable(self.io);
        self.stats.store_hits += 1;
        self.mutex.unlock(self.io);
    }

    fn runJob(self: *GenPool, idx: usize, job: Job) void {
        const gen = &self.gens[idx];
        const k = keyOf(job.dim, job.x, job.z);
        // Fast path: another conn (or pre-gen) filled it while queued.
        if (self.alreadyStored(k)) {
            self.noteStoreHit();
            return;
        }
        // Retained per-worker scratch: reset keeps capacity, so steady
        // state performs zero backing-allocator calls per chunk. The
        // reset return (preheat realloc failed) is safe to ignore — the
        // arena stays fully functional, just slower until it regrows.
        var sa = &self.scratch[idx];
        _ = sa.reset(.retain_capacity);
        const ch = gen.genChunk(self.alloc, sa.allocator(), job.x, job.z) catch {
            // Failures behave like today's holes (fixed on move/resync): no
            // sequence bump, so serve threads don't spin on a poison column.
            self.noteFailed();
            return;
        };
        defer ch.destroy(self.alloc);
        // Recheck under the world lock, then store WITHOUT it. The store
        // serializes puts under its own mutex, and the serve side never
        // creates chunk keys (holes stay holes on every serve path: edits
        // and light bleed skip missing columns), so a recheck miss can only
        // race another worker storing byte-identical bytes (generation is
        // deterministic; last-wins is a no-op, the sequence just bumps
        // twice). Holding the world SpinLock across encode + LSM put +
        // synchronous flush/compact parked the serve thread — enchant and
        // inventory clicks busy-spin on that lock — for seconds at a time
        // during bulk generation.
        self.lock.lock();
        const dup = self.alreadyStored(k);
        self.lock.unlock();
        if (dup) {
            self.noteStoreHit();
            return;
        }
        self.pool.putChunk(self.alloc, ch) catch {
            self.noteFailed();
            return;
        };
        _ = self.seq.fetchAdd(1, .acq_rel);
        self.noteCompleted();
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
    var gp = try GenPool.create(a, io, pool, &lock, 42, false, false, 1, .{});
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

// Phase G wiring proof: with GPU fill enabled the pool generates chunks
// byte-identical to the CPU reference (fill falls back per chunk on any
// GPU problem). Skips where no Vulkan driver/device/compute/float64 is
// present (CI without a GPU stays green); on GPU hardware it asserts the
// GPU path actually ran (gpu_fill > 0, zero fallbacks on valid chunks).
test "pool gpu fill matches sync gen (skips without GPU)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    var lock: spin_mod.SpinLock = .{};
    var gp = try GenPool.create(a, io, pool, &lock, 42, false, false, 1, .{ .enabled = true, .device = .auto, .max_batch = 16 });
    defer {
        gp.destroy();
        a.destroy(gp);
    }
    if (gp.gpu_ctx == null) return error.SkipZigTest;
    // Exact fill/dispatch counts below assume no column reuse: bypass the
    // shared cache for this worker (byte-identity is unaffected either
    // way; the dedicated cache test below covers hits).
    for (gp.gens) |*g| g.cache = null;
    const want = [_][2]i32{ .{ 0, 0 }, .{ 3, -5 }, .{ -2, 7 }, .{ 5, 5 }, .{ 6, 0 }, .{ 7, -1 } };
    for (want) |c| gp.request(0, c[0], c[1]);
    gp.drain();
    try std.testing.expectEqual(@as(usize, 0), gp.pending());
    var ref = try gen_mod.Gen.init(a, 42, false, false);
    defer ref.deinit();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    for (want) |c| {
        const ref_ch = try ref.genChunk(a, arena.allocator(), c[0], c[1]);
        defer ref_ch.destroy(a);
        const got = try pool.getChunk(a, 0, c[0], c[1]);
        defer got.?.destroy(a);
        try std.testing.expect(got != null);
        try std.testing.expectEqual(ref_ch.mask(), got.?.mask());
        try std.testing.expectEqualSlices(u8, &ref_ch.biomes, &got.?.biomes);
        try std.testing.expectEqualSlices(u8, &ref_ch.heights, &got.?.heights);
        for (0..16) |s| {
            if (ref_ch.sections[s]) |rs| {
                try std.testing.expect(got.?.sections[s] != null);
                const gs = &got.?.sections[s].?;
                try std.testing.expectEqualSlices(ids_mod.Id, &rs.blocks, &gs.blocks);
            } else {
                try std.testing.expect(got.?.sections[s] == null);
            }
        }
    }
    const st = gp.snapshotStats();
    try std.testing.expect(st.gpu_fill > 0);
    try std.testing.expectEqual(@as(u64, 0), st.gpu_fallback);
    // 6 requested chunks x 9 columns, all through the amortized path:
    // 54 fills in exactly 6 batch dispatches (not 54 single fills).
    try std.testing.expectEqual(@as(u64, 54), st.gpu_fill);
    try std.testing.expectEqual(@as(u64, 6), gp.gpu_fills[0].?.batches_ok.load(.monotonic));
}

test "pool column cache shares neighbor columns (byte-identical)" {
    // Adjacent chunks overlap 6/9 columns: (0,0) fills 9 (all miss), then
    // (1,0) reuses x=0..1 (6 hits) and generates x=2 (3 misses). Output
    // must equal the uncached sync reference either way.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    var lock: spin_mod.SpinLock = .{};
    var gp = try GenPool.create(a, io, pool, &lock, 42, false, false, 1, .{});
    defer {
        gp.destroy();
        a.destroy(gp);
    }
    gp.request(0, 0, 0);
    gp.request(0, 1, 0);
    gp.drain();
    try std.testing.expectEqual(@as(usize, 0), gp.pending());
    const st = gp.snapshotStats();
    try std.testing.expectEqual(@as(u64, 6), st.cache_hits);
    try std.testing.expectEqual(@as(u64, 12), st.cache_misses);
    var ref = try gen_mod.Gen.init(a, 42, false, false);
    defer ref.deinit();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const want = [_][2]i32{ .{ 0, 0 }, .{ 1, 0 } };
    for (want) |c| {
        const ref_ch = try ref.genChunk(a, arena.allocator(), c[0], c[1]);
        defer ref_ch.destroy(a);
        const got = try pool.getChunk(a, 0, c[0], c[1]);
        defer got.?.destroy(a);
        try std.testing.expect(got != null);
        try std.testing.expectEqual(ref_ch.mask(), got.?.mask());
        try std.testing.expectEqualSlices(u8, &ref_ch.biomes, &got.?.biomes);
        try std.testing.expectEqualSlices(u8, &ref_ch.heights, &got.?.heights);
        for (0..16) |s| {
            if (ref_ch.sections[s]) |rs| {
                try std.testing.expect(got.?.sections[s] != null);
                const gs = &got.?.sections[s].?;
                try std.testing.expectEqualSlices(ids_mod.Id, &rs.blocks, &gs.blocks);
                try std.testing.expectEqualSlices(u8, &rs.meta, &gs.meta);
            } else {
                try std.testing.expect(got.?.sections[s] == null);
            }
        }
    }
}

test "pool skips already-stored chunks without generating" {    const a = std.testing.allocator;
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
    var gp = try GenPool.create(a, io, pool, &lock, 1, false, false, 1, .{});
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

test "priority lane jumps the bulk backlog (exact queue order)" {
    // View/login holes must not wait behind thousands of bulk (pregen)
    // jobs. Freeze workers out by holding the pool mutex while driving
    // the locked entry points directly, so queue order below is exact
    // rather than timing-dependent.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    var lock: spin_mod.SpinLock = .{};
    var gp = try GenPool.create(a, io, pool, &lock, 42, false, false, 1, .{});
    defer {
        gp.destroy();
        a.destroy(gp);
    }
    const orderIs = struct {
        fn run(g: *GenPool, want: []const i32) !void {
            try std.testing.expectEqual(want.len, g.pendingLocked());
            for (want, 0..) |wx, i| {
                try std.testing.expectEqual(wx, g.queue.items[g.head + i].x);
            }
        }
    }.run;
    gp.mutex.lockUncancelable(io);
    gp.requestLocked(0, 1, 0, false); // bulk backlog stands in for pregen
    gp.requestLocked(0, 2, 0, false);
    gp.requestLocked(0, 3, 0, false);
    try orderIs(gp, &.{ 1, 2, 3 });
    gp.requestLocked(0, 9, 0, true); // view hole jumps to front
    try orderIs(gp, &.{ 9, 1, 2, 3 });
    gp.requestLocked(0, 2, 0, true); // queued bulk promotes, no duplicate
    try orderIs(gp, &.{ 2, 9, 1, 3 });
    gp.requestLocked(0, 2, 0, true); // already front: no-op
    try orderIs(gp, &.{ 2, 9, 1, 3 });
    gp.mutex.unlock(io);
    const st = gp.snapshotStats();
    try std.testing.expectEqual(@as(u64, 6), st.requested);
    try std.testing.expectEqual(@as(u64, 2), st.deduped);
    // Everything still generates (priority only reorders).
    gp.drain();
    for ([_]i32{ 1, 2, 3, 9 }) |x| {
        const got = try pool.getChunk(a, 0, x, 0);
        try std.testing.expect(got != null);
        defer got.?.destroy(a);
    }
}
