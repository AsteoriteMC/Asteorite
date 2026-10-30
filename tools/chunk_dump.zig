//! chunk_dump: parity probe for the tools/parity chunk area (mirrors
//! oracles/chunk/ChunkOracle.java stage for stage).
//! Usage: chunk_dump <seed> <cx> <cz>
//! Prints base-fill then surface digests (linear wire-id CRC + counts,
//! Java TreeMap format) plus the chunk-corner and populate-center biome
//! ids. Carvers deliberately NOT run (see COVERAGE.md: ours is
//! caves-only until ravines land).

const std = @import("std");
const asteorite = @import("asteorite");

const shaper_mod = asteorite.v5shaper;
const gen_mod = asteorite.v5gen;
const wire = asteorite.v5wire;
const ids = asteorite.ids;

fn digest(out: *std.Io.Writer, stage: []const u8, blocks: []const ids.Id, meta: []const u8) !void {
    var bc: i64 = 0;
    for (blocks) |b| bc = bc *% 31 +% @as(i64, wire.toWire(b));
    var mc: i64 = 0;
    for (meta) |m| mc = mc *% 31 +% @as(i64, m);
    try out.print("{s}_blocks={d} {s}_meta={d}\n", .{ stage, bc, stage, mc });
    var counts = [_]u64{0} ** 4096;
    for (blocks) |b| counts[wire.toWire(b)] += 1;
    try out.print("{s}_counts {{", .{stage});
    var first = true;
    for (counts, 0..) |c, w| {
        if (c == 0) continue;
        if (!first) try out.print(", ", .{});
        first = false;
        try out.print("{d}={d}", .{ w, c });
    }
    try out.print("}}\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena_alloc: std.mem.Allocator = init.arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;

    const args = try init.minimal.args.toSlice(arena_alloc);
    if (args.len < 4) {
        try out.print("usage: chunk_dump <seed> <cx> <cz>\n", .{});
        try out.flush();
        return;
    }
    const seed = std.fmt.parseInt(i64, args[1], 0) catch {
        try out.print("bad seed {s}\n", .{args[1]});
        try out.flush();
        return;
    };
    const cx = std.fmt.parseInt(i32, args[2], 0) catch return;
    const cz = std.fmt.parseInt(i32, args[3], 0) catch return;

    var gen = try gen_mod.Gen.init(arena_alloc, seed, false, false);
    defer gen.deinit();

    const blocks = try arena_alloc.create([shaper_mod.BLOCKS_LEN]ids.Id);
    const meta = try arena_alloc.create([shaper_mod.BLOCKS_LEN]u8);
    var q: [shaper_mod.Q_LEN]f64 = undefined;
    try gen.shaper.densityField(arena_alloc, cx, cz, &q);
    shaper_mod.Shaper.fillChunk(&q, blocks);
    @memset(meta, 0);
    try digest(out, "base", blocks, meta);
    try gen.shaper.surfaceChunk(arena_alloc, cx, cz, blocks, meta);
    try digest(out, "surface", blocks, meta);

    const bio = try arena_alloc.alloc(i32, 256);
    defer arena_alloc.free(bio);
    try gen.shaper.chain.getInts(arena_alloc, gen.shaper.roots[1], cx * 16, cz * 16, 16, 16, bio);
    var pop: [1]i32 = undefined;
    try gen.shaper.chain.getInts(arena_alloc, gen.shaper.roots[1], cx * 16 + 16, cz * 16 + 16, 1, 1, &pop);
    try out.print("biome0={d} population={d}\n", .{ bio[0], pop[0] });
    try out.flush();
}
