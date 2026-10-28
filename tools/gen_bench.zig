//! genbench: time chunk generation, CPU vs GPU-batched fill.
//!
//! Usage: gen_bench [seed] [cx] [cz] [count] [--gpu] [--hoist] [--phases] [--cache]
//! Walks +x from (cx,cz) so each chunk does the full 3x3 hoist. Reports
//! total, mean ms/chunk, and (with --gpu) the fill counters to prove which
//! path ran. --hoist runs the batched hoist with CPU fills (no GPU):
//! isolates hoist-structure cost from GPU cost in A/B work.
//! --phases adds per-stage means (density/fill/surface/carve/full-chunk),
//! measured on single columns plus full chunks, for before/after work.
//! --cache wires a shared 128-slot ColumnCache (like GenPool workers) so
//! steady-state hits are measured; without it every column regenerates.
//! Cache hits/misses/dups/single-flight are reported from the cache snapshot.
const std = @import("std");
const asteorite = @import("asteorite");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena_alloc: std.mem.Allocator = init.arena.allocator();
    var stdout_buf: [1024]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;
    const args = try init.minimal.args.toSlice(arena_alloc);
    var seed: i64 = 42;
    var cx: i32 = 0;
    var cz: i32 = 0;
    var count: usize = 9;
    var want_gpu = false;
    var want_hoist = false;
    var want_phases = false;
    var want_cache = false;
    var pos: usize = 0;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--gpu")) {
            want_gpu = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--hoist")) {
            want_hoist = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--phases")) {
            want_phases = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--cache")) {
            want_cache = true;
            continue;
        }
        const v = std.fmt.parseInt(i64, a, 0) catch {
            try out.print("gen_bench: bad arg '{s}' (want [seed] [cx] [cz] [count] [--gpu] [--hoist] [--phases] [--cache])\n", .{a});
            try out.flush();
            std.process.exit(2);
        };
        switch (pos) {
            0 => seed = v,
            1 => cx = @intCast(v),
            2 => cz = @intCast(v),
            3 => count = @intCast(@max(v, 1)),
            else => {},
        }
        pos += 1;
    }
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var gen = try asteorite.v5gen.Gen.init(gpa.allocator(), seed, false, false);
    defer gen.deinit();
    // Optional shared column cache (mirrors GenPool wiring): hits skip
    // density/fill/surface/carve entirely. Null = every column regenerates.
    var col_cache: ?asteorite.v5gen.ColumnCache = null;
    defer if (col_cache) |*cc| cc.deinit();
    if (want_cache) {
        col_cache = try asteorite.v5gen.ColumnCache.init(gpa.allocator(), io, asteorite.v5gen.column_cache_cap);
        gen.cache = if (col_cache) |*cc| cc else null;
    }
    // Local shared-style ore cache (single-threaded bench: same sharing
    // semantics as the pool, no contention). Always wired so --phases and
    // totals measure the real recipe-reuse path.
    var ore_cache: ?asteorite.v5decor.OreCache = null;
    defer if (ore_cache) |*oc| oc.deinit();
    ore_cache = try asteorite.v5decor.OreCache.init(gpa.allocator(), io);
    gen.ore_cache = if (ore_cache) |*oc| oc else null;
    var gpu_ctx: ?*asteorite.gpufill.GpuCtx = null;
    defer if (gpu_ctx) |c| c.deinit(gpa.allocator());
    var gpu_fill: ?*asteorite.gpufill.GpuFill = null;
    defer if (gpu_fill) |f| {
        f.deinit();
        gpa.allocator().destroy(f);
    };
    if (want_gpu) {
        gpu_ctx = try asteorite.gpufill.GpuCtx.init(gpa.allocator(), .auto) orelse {
            try out.print("gpu unavailable, aborting (no CPU fallback in bench)\n", .{});
            try out.flush();
            std.process.exit(2);
        };
        gpu_fill = asteorite.gpufill.GpuFill.init(gpu_ctx.?, gpa.allocator()) orelse {
            try out.print("gpu fill init failed, aborting\n", .{});
            try out.flush();
            std.process.exit(2);
        };
        gen.gpu = gpu_fill;
        try out.print("gpu: {s}\n", .{gpu_ctx.?.description()});
    }
    // Retained scratch arena across chunks (mirrors pool workers):
    // measures steady-state generation, not per-chunk mmap churn.
    var bench_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer bench_arena.deinit();
    // Warmup (page faults, first-dispatch pipeline).
    {
        _ = bench_arena.reset(.retain_capacity);
        const ch = try gen.genChunk(gpa.allocator(), bench_arena.allocator(), cx, cz);
        ch.destroy(gpa.allocator());
    }
    const t0 = std.Io.Timestamp.now(io, .awake);
    var x: i32 = cx;
    var n: usize = 0;
    while (n < count) : (n += 1) {
        _ = bench_arena.reset(.retain_capacity);
        const ch = if (want_hoist)
            try gen.genChunkBatched(gpa.allocator(), bench_arena.allocator(), x, cz)
        else
            try gen.genChunk(gpa.allocator(), bench_arena.allocator(), x, cz);
        ch.destroy(gpa.allocator());
        x += 1;
    }
    const t1 = std.Io.Timestamp.now(io, .awake);
    const ns: f64 = @floatFromInt(t0.durationTo(t1).nanoseconds);
    try out.print("{s}{s}: {d} chunks in {d:.1} ms = {d:.3} ms/chunk ({d:.0}/s)\n", .{
        if (want_gpu) "gpu-batched" else if (want_hoist) "cpu-batched(hoist)" else "cpu",
        if (want_cache) "+cache" else "",
        count,
        ns / 1e6,
        ns / 1e6 / @as(f64, @floatFromInt(count)),
        @as(f64, @floatFromInt(count)) / (ns / 1e9),
    });
    if (col_cache) |*cc| {
        const snap = cc.snapshot();
        const total: u64 = snap.hits + snap.misses;
        const pct: f64 = if (total == 0) 0 else @as(f64, @floatFromInt(snap.hits)) * 100.0 / @as(f64, @floatFromInt(total));
        try out.print("cache hits={d} misses={d} ({d:.1}%) dup={d} single_flight_hits={d}\n", .{ snap.hits, snap.misses, pct, snap.dup_misses, snap.single_flight_hits });
    }
    if (gen.ore_cache) |oc| {
        const snap = oc.snapshot();
        const ototal: u64 = snap.hits + snap.misses;
        const opct: f64 = if (ototal == 0) 0 else @as(f64, @floatFromInt(snap.hits)) * 100.0 / @as(f64, @floatFromInt(ototal));
        try out.print("ore hits={d} misses={d} ({d:.1}%)\n", .{ snap.hits, snap.misses, opct });
    }
    if (gpu_fill) |f| {
        try out.print("gpu fills={d} batches={d} fallbacks={d}\n", .{
            f.fills_ok.load(.monotonic),
            f.batches_ok.load(.monotonic),
            f.fills_fallback.load(.monotonic),
        });
    }
    if (want_phases) {
        // Per-stage micro-bench (single columns + full chunks): reproducible
        // before/after for noise/fill/surface/carve vs decorate+light+pack.
        // Uses the same retained arena and cache wiring as the main loop so
        // cached runs measure steady-state hits.
        var q: [asteorite.v5shaper.Q_LEN]f64 = undefined;
        const flat_blocks = try gpa.allocator().create([asteorite.v5shaper.BLOCKS_LEN]asteorite.ids.Id);
        defer gpa.allocator().destroy(flat_blocks);
        const flat_meta = try gpa.allocator().create([asteorite.v5shaper.BLOCKS_LEN]u8);
        defer gpa.allocator().destroy(flat_meta);
        const iters: usize = @max(count, 1);
        var t_density: i96 = 0;
        var t_fill: i96 = 0;
        var t_surface: i96 = 0;
        var t_carve: i96 = 0;
        var t_flat: i96 = 0;
        var px: i32 = cx;
        var pi: usize = 0;
        while (pi < iters) : (pi += 1) {
            _ = bench_arena.reset(.retain_capacity);
            const sa = bench_arena.allocator();
            var tt = std.Io.Timestamp.now(io, .awake);
            try gen.shaper.densityField(sa, px, cz, &q);
            t_density += tt.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
            tt = std.Io.Timestamp.now(io, .awake);
            asteorite.v5shaper.Shaper.fillChunk(&q, flat_blocks);
            t_fill += tt.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
            tt = std.Io.Timestamp.now(io, .awake);
            try gen.shaper.surfaceChunk(sa, px, cz, flat_blocks, flat_meta);
            t_surface += tt.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
            tt = std.Io.Timestamp.now(io, .awake);
            try gen.carver.carveChunk(sa, px, cz, seed, flat_blocks);
            t_carve += tt.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
            tt = std.Io.Timestamp.now(io, .awake);
            try gen.genFlatInto(sa, px, cz, flat_blocks, flat_meta);
            t_flat += tt.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
            px += 1;
        }
        const f = @as(f64, @floatFromInt(iters));
        try out.print("phases per column: density {d:.3} ms fill {d:.3} ms surface {d:.3} ms carve {d:.3} ms flat {d:.3} ms\n", .{
            @as(f64, @floatFromInt(t_density)) / 1e6 / f,
            @as(f64, @floatFromInt(t_fill)) / 1e6 / f,
            @as(f64, @floatFromInt(t_surface)) / 1e6 / f,
            @as(f64, @floatFromInt(t_carve)) / 1e6 / f,
            @as(f64, @floatFromInt(t_flat)) / 1e6 / f,
        });
    }
    try out.flush();
}

test {
    _ = @import("asteorite");
}
