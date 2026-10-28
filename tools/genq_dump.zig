//! genq-dump: stage REAL q[825] + fillChunk output for GPU threshold proof.
//!
//! Built via `zig build genq-dump` (imports the `asteorite` module like
//! every other tool); run directly:
//!
//!   ./zig-out/bin/genq_dump 1 0 0 /tmp/opencode/realq_1_0_0.bin [iters]
//!
//! Output file layout (all little-endian):
//!   u32 magic 0x47514e44 ("GQND"), u32 q_len (=825), u32 cells (=65536),
//!   u32 sea, stone, water, air,
//!   q_len f64 density field (CPU-computed, JVM-verified via shaper goldens),
//!   cells u32 expected block codes from the REAL `fillChunk`.
//! The probe's `--realq <file>` mode stages this q and bit-compares the GPU
//! fill against `expected` — the true end-to-end proof on game data
//! (the soup oracle only proves the kernel matches its transcription).
//! With [iters], also prints fill/surface/densityField/rng-floor bench means.

const std = @import("std");
const shaper_mod = @import("asteorite").v5shaper;
const ids_mod = @import("asteorite").ids;
const java_random_mod = @import("asteorite").java_random;

const BlocksArray = [shaper_mod.BLOCKS_LEN]ids_mod.Id;

pub const MAGIC: u32 = 0x47514e44;
pub const Q_LEN: usize = 825;
pub const CELLS: usize = 16 * 256 * 16;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena_alloc: std.mem.Allocator = init.arena.allocator();
    var stdout_buf: [1024]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;
    const args = try init.minimal.args.toSlice(arena_alloc);
    const seed: i64 = if (args.len > 1) try std.fmt.parseInt(i64, args[1], 0) else 1;
    const cx: i32 = if (args.len > 2) try std.fmt.parseInt(i32, args[2], 0) else 0;
    const cz: i32 = if (args.len > 3) try std.fmt.parseInt(i32, args[3], 0) else 0;
    const path: []const u8 = if (args.len > 4) args[4] else "/tmp/opencode/realq.bin";
    const bench_iters: usize = if (args.len > 5) try std.fmt.parseInt(usize, args[5], 0) else 0;

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var sh = try shaper_mod.Shaper.init(gpa.allocator(), seed, false, false);
    defer sh.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    var q: [Q_LEN]f64 = undefined;
    try sh.densityField(arena.allocator(), cx, cz, &q);
    var blocks: BlocksArray = undefined;
    shaper_mod.Shaper.fillChunk(&q, &blocks);

    if (bench_iters > 0) {
        // RNG floor: the exact minimum draw sequence surfaceChunk consumes
        // per chunk (1 nextDouble + 256 nextIntBound(5) per column; sand
        // nextIntBound(4)s add on top in sand biomes). If this floor is most
        // of the surface cost, the stream — not the scan — dominates, and a
        // GPU scan offload has little to win (the stream is inherently
        // sequential: data-dependent draw counts per column).
        {
            var r = java_random_mod.JavaRandom.init(12345);
            const r0 = std.Io.Timestamp.now(io, .awake);
            for (0..bench_iters) |_| {
                for (0..256) |_| {
                    _ = r.nextDouble();
                    for (0..256) |_| {
                        _ = r.nextIntBound(5) catch unreachable;
                    }
                }
                std.mem.doNotOptimizeAway(&r);
            }
            const r1 = std.Io.Timestamp.now(io, .awake);
            const rns: f64 = @floatFromInt(@max(0, r0.durationTo(r1).nanoseconds));
            try out.print("genq-bench: rng-floor {d} iters: {d:.1} us/chunk\n", .{ bench_iters, rns / @as(f64, @floatFromInt(bench_iters)) / 1000.0 });
        }
        // CPU baseline for the GPU comparison: warmed-up fillChunk only
        // (the ported stage — densityField stays CPU either way).
        shaper_mod.Shaper.fillChunk(&q, &blocks);
        const t0 = std.Io.Timestamp.now(io, .awake);
        for (0..bench_iters) |_| {
            shaper_mod.Shaper.fillChunk(&q, &blocks);
            std.mem.doNotOptimizeAway(&blocks);
        }
        const t1 = std.Io.Timestamp.now(io, .awake);
        const ns: f64 = @floatFromInt(@max(0, t0.durationTo(t1).nanoseconds));
        try out.print("genq-bench: fillChunk {d} iters: {d:.1} us/chunk\n", .{ bench_iters, ns / @as(f64, @floatFromInt(bench_iters)) / 1000.0 });
        // Surface stage (base + mesa paths): fill fresh, then surface.
        // Reports fill+surface; subtract fillChunk for the surface-only cost.
        var meta: [shaper_mod.BLOCKS_LEN]u8 = undefined;
        shaper_mod.Shaper.fillChunk(&q, &blocks);
        try sh.surfaceChunk(arena.allocator(), cx, cz, &blocks, &meta);
        const s0 = std.Io.Timestamp.now(io, .awake);
        for (0..bench_iters) |_| {
            shaper_mod.Shaper.fillChunk(&q, &blocks);
            _ = arena.reset(.retain_capacity);
            try sh.surfaceChunk(arena.allocator(), cx, cz, &blocks, &meta);
            std.mem.doNotOptimizeAway(&blocks);
            std.mem.doNotOptimizeAway(&meta);
        }
        const s1 = std.Io.Timestamp.now(io, .awake);
        const sns: f64 = @floatFromInt(@max(0, s0.durationTo(s1).nanoseconds));
        try out.print("genq-bench: fill+surface {d} iters: {d:.1} us/chunk\n", .{ bench_iters, sns / @as(f64, @floatFromInt(bench_iters)) / 1000.0 });
        // Context: the unported densityField stage (stays CPU per H5).
        var arena2 = std.heap.ArenaAllocator.init(gpa.allocator());
        defer arena2.deinit();
        var q2: [Q_LEN]f64 = undefined;
        try sh.densityField(arena2.allocator(), cx, cz, &q2);
        const d0 = std.Io.Timestamp.now(io, .awake);
        for (0..bench_iters) |_| {
            _ = arena2.reset(.retain_capacity);
            try sh.densityField(arena2.allocator(), cx, cz, &q2);
            std.mem.doNotOptimizeAway(&q2);
        }
        const d1 = std.Io.Timestamp.now(io, .awake);
        const dns: f64 = @floatFromInt(@max(0, d0.durationTo(d1).nanoseconds));
        try out.print("genq-bench: densityField {d} iters: {d:.1} us/chunk\n", .{ bench_iters, dns / @as(f64, @floatFromInt(bench_iters)) / 1000.0 });
    }

    // fillChunk's alphabet is air=0, stone=1, water=9 (ids.Id wire values,
    // src/ids.zig). Asserted here so a future id renumber fails loudly
    // instead of silently writing wrong codes into the file.
    // NOTE: refill fresh — the bench block above leaves surface mutations
    // (bedrock) in blocks.
    shaper_mod.Shaper.fillChunk(&q, &blocks);

    var f = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer f.close(io);
    var fw_buf: [4096]u8 = undefined;
    var fw: std.Io.File.Writer = .initStreaming(f, io, &fw_buf);
    const w = &fw.interface;
    try w.writeInt(u32, MAGIC, .little);
    try w.writeInt(u32, Q_LEN, .little);
    try w.writeInt(u32, CELLS, .little);
    try w.writeInt(u32, @as(u32, shaper_mod.SEA_LEVEL), .little);
    try w.writeInt(u32, 1, .little); // stone
    try w.writeInt(u32, 9, .little); // water
    try w.writeInt(u32, 0, .little); // air
    for (q) |v| try w.writeInt(u64, @bitCast(v), .little);
    var stone_n: usize = 0;
    var water_n: usize = 0;
    for (blocks) |b| {
        const wv: u32 = @intFromEnum(b);
        try w.writeInt(u32, wv, .little);
        if (wv == 1) stone_n += 1 else if (wv == 9) water_n += 1 else {
            try std.testing.expectEqual(@as(u32, 0), wv);
        }
    }
    try w.flush();
    try out.print("genq-dump: seed={d} chunk=({d},{d}) stone={d} water={d} -> {s}\n", .{ seed, cx, cz, stone_n, water_n, path });
    try out.flush();
}
