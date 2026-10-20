//! seedump: print (kind, seed, worldGenSeed, baseSeed) for each chain layer.
const std = @import("std");
const zigcraft = @import("zigcraft");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena_alloc: std.mem.Allocator = init.arena.allocator();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;
    const args = try init.minimal.args.toSlice(arena_alloc);
    const seed: i64 = if (args.len >= 2) try std.fmt.parseInt(i64, args[1], 0) else 1;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var built = try zigcraft.v5genlayer.Chain.buildDefault(gpa.allocator(), seed, false);
    defer built.chain.deinit();
    for (built.chain.layers, 0..) |lay, i| {
        const st = built.chain.states[i];
        try out.print("{d} {s} seed={d} wgs={d} base={d}\n", .{ i, @tagName(lay.kind), lay.seed, st.world_gen_seed, st.base_seed });
    }
    try out.flush();
}

test {
    _ = @import("zigcraft");
}
