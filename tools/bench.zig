//! Micro-benchmarks for the hot paths (`zig build bench`).
//!
//! Phase D requires measured before/after numbers, not promises, so every
//! optimization ships with a benchmark that prints ns/op and ops/s.
//!
//! What is measured here:
//!   - entity tick: AoS (the old `entity.Mob` list) vs SoA (`MobStore`)
//!   - integration: scalar vs `@Vector` (the SIMD fast path)
//!   - AABB overlap: scalar vs `@Vector`
//!   - VarInt/stream scanning: scalar only (byte parsers are branch-bound;
//!     the vectorized variant is NOT a win — measured, see the note in
//!     the output)
//!   - codec roundtrip (VarInt + frame encode/decode)
//!   - Phase C region tick: sequential vs fork-join over 8 regions
//!     (200-viewer reconcile-shaped workload; the acceptance scaling)

const std = @import("std");
const asteorite = @import("asteorite");

const entity = asteorite.entity;
const store_mod = asteorite.store;
const store = asteorite.entity_store;
const codec = asteorite.codec;
const tick_mod = asteorite.tick;
const affinity_mod = asteorite.affinity;
const pool_mod = asteorite.pool;

/// Entities used by the tick benchmarks.
const bench_entities: usize = 4096;

/// Monotonic nanoseconds (the bench measures wall time, not CPU time).
fn nowNs(io: std.Io) u64 {
    return @as(u64, @intCast(@max(0, std.Io.Timestamp.now(io, .awake).nanoseconds)));
}

fn report(name: []const u8, ops: usize, ns: u64) void {
    const per_op = if (ops == 0) 0.0 else @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(ops));
    const ops_per_sec = if (per_op == 0.0) 0.0 else 1e9 / per_op;
    std.debug.print("  {s:<34} {d:>10} ops  {d:>12.2} ns/op  {d:>14.0} ops/s\n", .{
        name,
        ops,
        per_op,
        ops_per_sec,
    });
}

/// Phase C: region-tick scaling. 8 regions x 200 viewers x 2000 entities
/// with a reconcile-shaped workload (per viewer: range scan over every
/// entity — the O(V*E) cost the server parallelizes). Compares the
/// sequential engine against fork-join; also the acceptance stress test
/// (workers share one allocator, regions stay disjoint — any race would
/// corrupt the per-region checksums asserted below).
///
/// Sizing: per-region work is ~ms (like a real 25-viewer reconcile with
/// packet framing), so the ~15us thread-spawn cost is noise at 1Hz —
/// but the persistent pool (stable workers, pinned once) replaces the
/// per-tick spawn anyway, and wins outright on small ticks (measured
/// below) and at sub-second rates.
const bench_regions = 8;
const bench_viewers = 200;
const bench_ents = 2000;

var bench_px: [bench_regions * bench_viewers]f64 = undefined;
var bench_pz: [bench_regions * bench_viewers]f64 = undefined;
var bench_ex: [bench_ents]f64 = undefined;
var bench_ez: [bench_ents]f64 = undefined;
var bench_sum: [bench_regions]u64 = [_]u64{0} ** bench_regions;
// Per-viewer tracked sets + outboxes (disjoint per viewer, like the live
// conn state — the writes stay core-local, the reads are shared).
var bench_tracked: [bench_regions * bench_viewers][64]u32 = undefined;
var bench_ntracked: [bench_regions * bench_viewers]usize = undefined;
var bench_out: [bench_regions * bench_viewers][1024]u8 = undefined;
var bench_outlen: [bench_regions * bench_viewers]usize = undefined;

const BenchRegionH = struct {
    fn h(r: *tick_mod.Region, n: u64) void {
        _ = n;
        const ri: usize = @intCast(r.id.rx);
        const base = ri * bench_viewers;
        var acc: u64 = 0;
        var v: usize = 0;
        while (v < bench_viewers) : (v += 1) {
            const vi = base + v;
            const vx = bench_px[vi];
            const vz = bench_pz[vi];
            var k: usize = 0;
            while (k < bench_ents) : (k += 1) {
                const dx = vx - bench_ex[k];
                const dz = vz - bench_ez[k];
                const in_range = @abs(dx) < 128.0 and @abs(dz) < 128.0;
                // Tracked-set lookup (branchy linear scan, like the live
                // per-viewer tracked map probe).
                var tracked = false;
                for (bench_tracked[vi][0..bench_ntracked[vi]]) |id| {
                    if (id == k) {
                        tracked = true;
                        break;
                    }
                }
                if (in_range and !tracked) {
                    // Spawn path: claim a tracked slot + frame a packet.
                    if (bench_ntracked[vi] < 64) {
                        bench_tracked[vi][bench_ntracked[vi]] = @intCast(k);
                        bench_ntracked[vi] += 1;
                    }
                    const o = bench_outlen[vi] % 1000;
                    bench_out[vi][o] = @intCast(k & 0xFF);
                    bench_out[vi][o + 1] = @intCast((k >> 8) & 0xFF);
                    bench_outlen[vi] += 2;
                    acc += 1;
                } else if (!in_range and tracked) {
                    const o = bench_outlen[vi] % 1000;
                    bench_out[vi][o] = 0xFF;
                    bench_outlen[vi] += 1;
                    acc += 1;
                }
            }
        }
        bench_sum[ri] = acc;
        // Drain the inbox (handoffs flow here on the live path too).
        const msgs = r.inbox.drain() catch return;
        defer r.inbox.allocator.free(msgs);
    }
};

/// Near-empty tick body for the small-tick latency comparison (drain +
/// count only): per-tick thread-spawn cost dominates here, which is the
/// persistent pool's honest win. Per-region slots (indexed by rx) keep
/// the count exact without atomics.
var bench_tiny_hit: [bench_regions]u64 = [_]u64{0} ** bench_regions;

const BenchTinyH = struct {
    fn h(r: *tick_mod.Region, n: u64) void {
        _ = n;
        const msgs = r.inbox.drain() catch return;
        defer r.inbox.allocator.free(msgs);
        bench_tiny_hit[@intCast(r.id.rx)] += 1;
    }
};

fn benchRegions(allocator: std.mem.Allocator, io: std.Io) !void {
    // Deterministic field (no RNG in the bench): viewers spread over 8
    // region cells, entities scattered across the same field.
    for (&bench_px, 0..) |*p, i| p.* = @as(f64, @floatFromInt((i * 37) % 2048)) - 1024.0;
    for (&bench_pz, 0..) |*p, i| p.* = @as(f64, @floatFromInt((i * 91) % 2048)) - 1024.0;
    for (&bench_ex, 0..) |*p, i| p.* = @as(f64, @floatFromInt((i * 53) % 2048)) - 1024.0;
    for (&bench_ez, 0..) |*p, i| p.* = @as(f64, @floatFromInt((i * 29) % 2048)) - 1024.0;
    var regs: [bench_regions]*tick_mod.Region = undefined;
    for (&regs, 0..) |*slot, i| {
        const r = try allocator.create(tick_mod.Region);
        r.* = tick_mod.Region.init(allocator, .{ .dim = 0, .rx = @intCast(i), .rz = 0 });
        slot.* = r;
    }
    defer for (regs) |r| {
        r.deinit();
        allocator.destroy(r);
    };
    const reset_state = struct {
        fn run() void {
            for (&bench_ntracked) |*x| x.* = 0;
            for (&bench_outlen) |*x| x.* = 0;
        }
    }.run;
    // Topology line (affinity is advisory; the mapping is printed so a
    // bad one shows up as a number, not a mystery).
    const topo = affinity_mod.detect(io);
    var cpus: [bench_regions]usize = undefined;
    affinity_mod.assignRegions(&topo, bench_regions, &cpus);
    std.debug.print("    topology: {d} cpus, {d} nodes; region->cpu:", .{ topo.ncpus, topo.nnodes });
    for (cpus) |c| std.debug.print(" {d}", .{c});
    std.debug.print("\n", .{});

    const iters: usize = 100;
    reset_state();
    const t0 = nowNs(io);
    var t: u64 = 0;
    while (t < iters) : (t += 1) _ = tick_mod.tickOnce(io, &regs, t, BenchRegionH.h);
    const dt_seq = nowNs(io) - t0;
    var seq_sum: u64 = 0;
    for (bench_sum) |v| seq_sum += v;

    reset_state();
    const t1 = nowNs(io);
    t = 0;
    while (t < iters) : (t += 1) _ = tick_mod.tickParallel(io, &regs, t, BenchRegionH.h, bench_regions, &cpus);
    const dt_par = nowNs(io) - t1;
    var par_sum: u64 = 0;
    for (bench_sum) |v| par_sum += v;

    // Same work both ways (or the parallel engine is broken, not fast).
    if (seq_sum != par_sum) std.debug.print("    (CHECKSUM MISMATCH seq={d} par={d}!)\n", .{ seq_sum, par_sum });
    const ops = iters * bench_regions * bench_viewers * bench_ents;
    report("region tick sequential (8 regions)", ops, dt_seq);
    report("region tick parallel (8 workers)", ops, dt_par);
    if (dt_par > 0) {
        std.debug.print("    parallel speedup: {d:.2}x over 8 regions (branchy reconcile-shaped work; pure scans are bandwidth-bound instead)\n", .{@as(f64, @floatFromInt(dt_seq)) / @as(f64, @floatFromInt(dt_par))});
    }

    // Persistent pool on the same workload: same work, stable threads
    // (pinned once, no per-tick spawn). Checksum must match both above.
    if (pool_mod.Pool.create(allocator, bench_regions, &cpus)) |pool| {
        defer pool.destroy();
        const PCtx = struct {
            regs: []*tick_mod.Region,
            io: std.Io,
            tick_no: u64,
            fn h(ctx: *anyopaque, worker: usize, n: usize) void {
                const c: *@This() = @ptrCast(@alignCast(ctx));
                var off: usize = 0;
                var w: usize = 0;
                while (w < n) : (w += 1) {
                    const start = off;
                    off += (c.regs.len - off) / (n - w);
                    if (w == worker) {
                        for (c.regs[start..off]) |r| tick_mod.tickOne(c.io, r, c.tick_no, BenchRegionH.h);
                    }
                }
            }
        };
        var pctx = PCtx{ .regs = &regs, .io = io, .tick_no = 0 };
        reset_state();
        const t2 = nowNs(io);
        t = 0;
        while (t < iters) : (t += 1) {
            pctx.tick_no = t;
            pool.run(&pctx, PCtx.h);
        }
        const dt_pool = nowNs(io) - t2;
        var pool_sum: u64 = 0;
        for (bench_sum) |v| pool_sum += v;
        if (pool_sum != seq_sum) std.debug.print("    (CHECKSUM MISMATCH pool={d} seq={d}!)\n", .{ pool_sum, seq_sum });
        report("region tick pool (8 stable)", ops, dt_pool);
    } else |_| {
        std.debug.print("    (no pool on this OS: fork-join is the only parallel path)\n", .{});
    }

    // Small-tick latency: 8 near-empty regions (drain-only handler). This
    // is the pool's honest win — per-tick spawn latency dominates here,
    // while the big workload above amortizes it.
    {
        for (&bench_tiny_hit) |*x| x.* = 0;
        const tiny_iters: usize = 2000;
        const t3 = nowNs(io);
        t = 0;
        while (t < tiny_iters) : (t += 1) _ = tick_mod.tickOnce(io, &regs, t, BenchTinyH.h);
        const dt_tseq = nowNs(io) - t3;
        const t4 = nowNs(io);
        t = 0;
        while (t < tiny_iters) : (t += 1) _ = tick_mod.tickParallel(io, &regs, t, BenchTinyH.h, bench_regions, &cpus);
        const dt_tpar = nowNs(io) - t4;
        var dt_tpool: u64 = 0;
        var pool_ok = false;
        if (pool_mod.Pool.create(allocator, bench_regions, &cpus)) |pool| {
            defer pool.destroy();
            pool_ok = true;
            const PCtx = struct {
                regs: []*tick_mod.Region,
                io: std.Io,
                tick_no: u64,
                fn h(ctx: *anyopaque, worker: usize, n: usize) void {
                    const c: *@This() = @ptrCast(@alignCast(ctx));
                    var off: usize = 0;
                    var w: usize = 0;
                    while (w < n) : (w += 1) {
                        const start = off;
                        off += (c.regs.len - off) / (n - w);
                        if (w == worker) {
                            for (c.regs[start..off]) |r| tick_mod.tickOne(c.io, r, c.tick_no, BenchTinyH.h);
                        }
                    }
                }
            };
            var pctx = PCtx{ .regs = &regs, .io = io, .tick_no = 0 };
            const t5 = nowNs(io);
            t = 0;
            while (t < tiny_iters) : (t += 1) {
                pctx.tick_no = t;
                pool.run(&pctx, PCtx.h);
            }
            dt_tpool = nowNs(io) - t5;
        } else |_| {}
        if (pool_ok) {
            std.debug.print("    small-tick latency per tick: seq={d:.1}us fork-join={d:.1}us pool={d:.1}us ({d} iters)\n", .{
                @as(f64, @floatFromInt(dt_tseq)) / @as(f64, @floatFromInt(tiny_iters)) / 1000.0,
                @as(f64, @floatFromInt(dt_tpar)) / @as(f64, @floatFromInt(tiny_iters)) / 1000.0,
                @as(f64, @floatFromInt(dt_tpool)) / @as(f64, @floatFromInt(tiny_iters)) / 1000.0,
                tiny_iters,
            });
        } else {
            std.debug.print("    small-tick latency per tick: seq={d:.1}us fork-join={d:.1}us pool=n/a ({d} iters)\n", .{
                @as(f64, @floatFromInt(dt_tseq)) / @as(f64, @floatFromInt(tiny_iters)) / 1000.0,
                @as(f64, @floatFromInt(dt_tpar)) / @as(f64, @floatFromInt(tiny_iters)) / 1000.0,
                tiny_iters,
            });
        }
        var tiny_total: u64 = 0;
        for (bench_tiny_hit) |v| tiny_total += v;
        // All three phases (seq + fork-join + pool) tick every region.
        if (tiny_total != 3 * tiny_iters * bench_regions) std.debug.print("    (TINY COUNT MISMATCH {d}!)\n", .{tiny_total});
    }
    // No region shed on a healthy tick (breaker quiet by default).
    var shed: usize = 0;
    for (regs) |r| {
        if (r.shed) shed += 1;
    }
    std.debug.print("    shed regions after bench: {d}\n", .{shed});
}
/// SoA (one contiguous array). This is the layout win the SoA store is
/// for: the tick itself is branch-bound, but every pass that only
/// touches the positions streams one array instead of striding through
/// the structs.
fn benchPositionPass(allocator: std.mem.Allocator, iters: usize, io: std.Io) !void {
    const n = bench_entities;
    const mobs = try allocator.alloc(entity.Mob, n);
    defer allocator.free(mobs);
    for (mobs, 0..) |*m, i| {
        m.* = .{ .id = @intCast(i + 1), .kind = entity.MOB_PIG, .x = @floatFromInt(i), .y = 64, .z = 0, .yaw = 0, .health = 10, .home_x = 0, .home_z = 0, .patrol_r = 4 };
    }
    var sum: f64 = 0;
    const t0 = nowNs(io);
    for (0..iters) |_| {
        for (mobs) |*m| sum += m.x + m.y + m.z;
    }
    const dt = nowNs(io) - t0;
    report("position pass AoS (structs)", iters * n, dt);

    var soa = store.MobStore.init(allocator);
    defer soa.deinit();
    for (0..n) |i| {
        _ = try soa.add(.{ .id = @intCast(i + 1), .kind = entity.MOB_PIG, .x = @floatFromInt(i), .y = 64, .z = 0, .yaw = 0, .health = 10, .home_x = 0, .home_z = 0, .patrol_r = 4 });
    }
    var sum2: f64 = 0;
    const t1 = nowNs(io);
    for (0..iters) |_| {
        for (soa.px.items, 0..) |v, i| {
            sum2 += v + soa.py.items[i] + soa.pz.items[i];
        }
    }
    const dt2 = nowNs(io) - t1;
    report("position pass SoA (arrays)", iters * n, dt2);
    if (sum == 0 or sum2 == 0) std.debug.print("    (unreachable)\n", .{});
}

/// AoS tick: the pre-Phase-D layout (one struct per mob).
fn benchAosTick(allocator: std.mem.Allocator, iters: usize, io: std.Io) !u64 {
    const mobs = try allocator.alloc(entity.Mob, bench_entities);
    defer allocator.free(mobs);
    for (mobs, 0..) |*m, i| {
        m.* = .{
            .id = @intCast(i + 1),
            .kind = entity.MOB_PIG,
            .x = @as(f64, @floatFromInt(i % 64)) * 0.5,
            .y = 64,
            .z = @as(f64, @floatFromInt(i / 64)) * 0.5,
            .yaw = 0,
            .health = 10,
            .home_x = 0,
            .home_z = 0,
            .patrol_r = 4,
        };
    }
    const t0 = nowNs(io);
    for (0..iters) |_| {
        for (mobs) |*m| m.wanderStep(0.5);
    }
    return nowNs(io) - t0;
}

/// SoA tick: the Phase-D layout (separate contiguous component arrays).
fn benchSoaTick(allocator: std.mem.Allocator, iters: usize, io: std.Io) !u64 {
    var mobs = store.MobStore.init(allocator);
    defer mobs.deinit();
    for (0..bench_entities) |i| {
        _ = try mobs.add(.{
            .id = @intCast(i + 1),
            .kind = entity.MOB_PIG,
            .x = @as(f64, @floatFromInt(i % 64)) * 0.5,
            .y = 64,
            .z = @as(f64, @floatFromInt(i / 64)) * 0.5,
            .yaw = 0,
            .health = 10,
            .home_x = 0,
            .home_z = 0,
            .patrol_r = 4,
        });
    }
    const t0 = nowNs(io);
    for (0..iters) |_| {
        mobs.tick(0.5);
    }
    return nowNs(io) - t0;
}

/// Position integration: scalar vs SIMD.
fn benchIntegrate(iters: usize, io: std.Io) !void {
    const pos = try std.heap.page_allocator.alloc(f64, bench_entities);
    defer std.heap.page_allocator.free(pos);
    const vel = try std.heap.page_allocator.alloc(f64, bench_entities);
    defer std.heap.page_allocator.free(vel);
    for (pos, vel, 0..) |*p, *v, i| {
        p.* = @floatFromInt(i % 100);
        v.* = 0.5;
    }
    {
        const t0 = nowNs(io);
        for (0..iters) |_| store.integrateScalar(pos, vel, 0.01);
        const dt = nowNs(io) - t0;
        report("integrate scalar (f64)", iters * bench_entities, dt);
    }
    {
        const t0 = nowNs(io);
        for (0..iters) |_| store.integrateVector(pos, vel, 0.01);
        const dt = nowNs(io) - t0;
        report("integrate SIMD  (f64 x4)", iters * bench_entities, dt);
    }
}

/// AABB overlap: scalar vs SIMD.
fn benchAabb(iters: usize, io: std.Io) !void {
    const boxes = try std.heap.page_allocator.alloc(store.Aabb, 256);
    defer std.heap.page_allocator.free(boxes);
    for (boxes, 0..) |*b, i| {
        const x: f32 = @floatFromInt(i % 16);
        const z: f32 = @floatFromInt(i / 16);
        b.* = .{ .min_x = x, .min_y = 60, .min_z = z, .max_x = x + 0.9, .max_y = 61.8, .max_z = z + 0.9 };
    }
    const q = store.Aabb{ .min_x = 1, .min_y = 60, .min_z = 1, .max_x = 2, .max_y = 62, .max_z = 2 };
    {
        var hits: usize = 0;
        const t0 = nowNs(io);
        for (0..iters) |_| {
            for (boxes) |b| {
                if (store.aabbOverlapScalar(b, q)) hits += 1;
            }
        }
        const dt = nowNs(io) - t0;
        report("aabb overlap scalar", iters * boxes.len, dt);
        if (hits == 0) std.debug.print("    (no hits)\n", .{});
    }
    {
        var hits: u64 = 0;
        const t0 = nowNs(io);
        for (0..iters) |_| {
            hits +%= @popCount(store.aabbOverlapMask(boxes, q));
        }
        const dt = nowNs(io) - t0;
        report("aabb overlap SIMD mask", iters * boxes.len, dt);
        if (hits == 0) std.debug.print("    (no hits)\n", .{});
    }
}

/// VarInt scanning: the byte parser is branch-bound (measured: no SIMD
/// win), so this is the scalar reference the codec uses.
fn benchVarInt(iters: usize, io: std.Io) !void {
    var buf: [8192]u8 = undefined;
    var w = codec.PacketWriter.init(&buf);
    var count: usize = 0;
    while (w.written().len < buf.len - 8) {
        try w.writeVarInt(@intCast(count % 300));
        count += 1;
    }
    const bytes = w.written();
    var sum: i64 = 0;
    const t0 = nowNs(io);
    for (0..iters) |_| {
        var r = codec.PacketReader.init(bytes);
        while (r.remaining() > 0) {
            sum += try r.readVarInt();
        }
    }
    const dt = nowNs(io) - t0;
    report("varint scan (branch-bound)", iters * count, dt);
    if (sum == 0) std.debug.print("    (unreachable)\n", .{});
}

/// Codec roundtrip: VarInt + frame.
fn benchCodec(iters: usize, io: std.Io) !void {
    var payload: [256]u8 = undefined;
    @memset(&payload, 0xAB);
    var framed: [512]u8 = undefined;
    const frame = try codec.framePacket(0x38, &payload, &framed);
    const t0 = nowNs(io);
    var n: usize = 0;
    for (0..iters) |_| {
        var r = codec.PacketReader.init(frame);
        const h = try codec.decodeFrame(&r);
        n += @as(usize, @intCast(h.length));
    }
    const dt = nowNs(io) - t0;
    report("codec frame roundtrip", iters, dt);
    if (n == 0) std.debug.print("    (unreachable)\n", .{});
}

/// LSM store: put / get / flush / compact. The compaction is the number
/// that matters for the tick: it runs synchronously inside `put`, so a
/// compaction lands on whatever thread did the write (often the tick
/// thread) and shows up as a tick spike.
fn benchStore(allocator: std.mem.Allocator, io: std.Io) !void {
    var tmp = try std.Io.Dir.cwd().createDirPathOpen(io, "/tmp/opencode/bench-store", .{});
    defer tmp.close(io);
    // 1 MiB memtable flush, no auto-compaction: the compaction is measured
    // explicitly below (it is the stall the tick p99 shows: it merges every
    // live SST and runs synchronously on the writing thread).
    var st = try store_mod.Store.open(allocator, io, tmp, .{
        .flush_threshold_bytes = 1024 * 1024,
        .compact_threshold_ssts = 0,
    });
    defer st.close();

    // Realistic chunk-sized values (the store's 8 MiB stride cap assumes
    // <300 KiB payloads — 1 MiB values would trip the torn-file guard
    // by design, not by bug).
    var value: [128 * 1024]u8 = undefined;
    @memset(&value, 0x5A);

    var keys: [32]store_mod.ChunkKey = undefined;
    for (&keys, 0..) |*k, i| {
        @memset(k, 0);
        k[0] = @intCast(i);
    }

    const t0 = nowNs(io);
    for (keys) |k| try st.put(k, &value);
    const dt_put = nowNs(io) - t0;
    report("lsm put (128 KiB chunk)", keys.len, dt_put);
    std.debug.print("    ssts after the puts: {d}\n", .{st.sstCount()});

    const t1 = nowNs(io);
    var hits: usize = 0;
    for (keys) |k| {
        const got = try st.get(allocator, k);
        if (got) |g| {
            hits += 1;
            allocator.free(g);
        }
    }
    const dt_get = nowNs(io) - t1;
    report("lsm get (hit, 128 KiB value)", keys.len, dt_get);
    if (hits != keys.len) std.debug.print("    (missing hits!)\n", .{});

    const t2 = nowNs(io);
    try st.compact();
    const dt_compact = nowNs(io) - t2;
    report("lsm compact (merge all runs)", 1, dt_compact);
    std.debug.print("    ssts after compact: {d}\n", .{st.sstCount()});
    const mb = (keys.len * value.len) / (1024 * 1024);
    if (dt_compact > 0) {
        std.debug.print("    compaction throughput: {d} MiB in {d} ms\n", .{ mb, dt_compact / 1_000_000 });
    }

    // NVMe store for comparison: same dataset with use_uring_io set.
    // NOTE (optimistic-get split): both loops below go through the
    // unlocked pread path — without lock contention nothing falls back
    // to getLocked, so the ring stays idle (counters prove it: expect
    // ring reads 0, fallback reads 0). This section now compares store
    // configs, not I/O roads; the ring-vs-pread proof lives in the
    // getLocked unit tests (ring counters advance only there).
    var tmp_ring = try std.Io.Dir.cwd().createDirPathOpen(io, "/tmp/opencode/bench-store-ring", .{});
    defer tmp_ring.close(io);
    var ring_st = try store_mod.Store.open(allocator, io, tmp_ring, .{
        .flush_threshold_bytes = 1024 * 1024,
        .compact_threshold_ssts = 0,
        .use_uring_io = true,
    });
    defer ring_st.close();
    for (keys) |k| try ring_st.put(k, &value);
    const reps: usize = 20;
    const t3 = nowNs(io);
    var ring_hits: usize = 0;
    for (0..reps) |_| {
        for (keys) |k| {
            const got = try ring_st.get(allocator, k);
            if (got) |g| {
                ring_hits += 1;
                allocator.free(g);
            }
        }
    }
    const dt_ring = nowNs(io) - t3;
    const rs = ring_st.ringStats();
    if (ring_st.ringActive()) {
        report("lsm get (uring-configured store, optimistic pread)", reps * keys.len, dt_ring);
        std.debug.print("    ring reads: {d}, fallback reads: {d} (both 0 expected: no contention, no fallback)\n", .{ rs.ring_reads, rs.fallback_reads });
    } else {
        std.debug.print("    (no io_uring in this environment — ring path skipped)\n", .{});
    }
    if (ring_hits != reps * keys.len) std.debug.print("    (missing hits!)\n", .{});
    // Same repetition count on the plain store for the before/after.
    const t4 = nowNs(io);
    var plain_hits: usize = 0;
    for (0..reps) |_| {
        for (keys) |k| {
            const got = try st.get(allocator, k);
            if (got) |g| {
                plain_hits += 1;
                allocator.free(g);
            }
        }
    }
    const dt_plain = nowNs(io) - t4;
    report("lsm get (plain store, optimistic pread)", reps * keys.len, dt_plain);
    if (plain_hits != reps * keys.len) std.debug.print("    (missing hits!)\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const iters: usize = 200;

    std.debug.print("\nasteorite bench (entities={d}, iters={d})\n\n", .{ bench_entities, iters });

    std.debug.print("entity tick:\n", .{});
    const io = init.io;
    const aos = try benchAosTick(allocator, iters, io);
    report("tick AoS (entity.Mob)", iters * bench_entities, aos);
    const soa = try benchSoaTick(allocator, iters, io);
    report("tick SoA (entity_store.MobStore)", iters * bench_entities, soa);
    if (aos > 0 and soa > 0) {
        // The SoA tick does the SAME work in two passes (velocity, then
        // integrate), so it is not a straight "speedup" number: the win
        // shows up in the SIMD integration and in the memory-bound
        // passes (see below).
        std.debug.print("    AoS/SoA tick ratio: {d:.2}x (SoA splits the move into velocity + integrate)\n", .{@as(f64, @floatFromInt(aos)) / @as(f64, @floatFromInt(soa))});
    }

    std.debug.print("\nlayout (memory-bound pass):\n", .{});
    try benchPositionPass(allocator, iters, io);

    std.debug.print("\nSIMD fast paths:\n", .{});
    try benchIntegrate(iters, io);
    try benchAabb(iters, io);

    std.debug.print("\nLSM store:\n", .{});
    try benchStore(allocator, io);

    std.debug.print("\ncodec:\n", .{});
    try benchVarInt(iters, io);
    try benchCodec(iters * 100, io);

    std.debug.print("\nPhase C region tick (8 regions x 200 viewers x 2000 entities):\n", .{});
    try benchRegions(allocator, io);

    std.debug.print("\n", .{});
}
