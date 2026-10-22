//! genlayer_dump: verify the 1.7.10 GenLayer chain against live JVM goldens.
//! Usage: genlayer_dump <seed> <x> <z> <w> <h> [--all]
//! Default prints the 3 roots (biome, voronoi, biome) exactly like GenGoldens.
//! --all prints every layer in construction order (like ChainDump.java):
//!   L{idx} {kind}: ..

const std = @import("std");
const asteorite = @import("asteorite");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena_alloc: std.mem.Allocator = init.arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;

    const args = try init.minimal.args.toSlice(arena_alloc);
    if (args.len < 6) {
        try out.print("usage: genlayer_dump <seed> <x> <z> <w> <h> [--all]\n", .{});
        try out.flush();
        return;
    }
    const seed = std.fmt.parseInt(i64, args[1], 0) catch {
        try out.print("bad seed {s}\n", .{args[1]});
        try out.flush();
        return;
    };
    const x = std.fmt.parseInt(i32, args[2], 0) catch return;
    const z = std.fmt.parseInt(i32, args[3], 0) catch return;
    const w = std.fmt.parseInt(usize, args[4], 0) catch return;
    const h = std.fmt.parseInt(usize, args[5], 0) catch return;
    const dump_all = args.len >= 7 and std.mem.eql(u8, args[6], "--all");

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var built = try asteorite.v5genlayer.Chain.buildDefault(alloc, seed, false);
    defer built.chain.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();

    if (!dump_all) {
        try out.print("seed={d} nlayers=3 window=({d},{d},{d},{d})\n", .{ seed, x, z, w, h });
        for (built.roots, 0..) |root, li| {
            const buf = try scratch.alloc(i32, w * h);
            try built.chain.getInts(scratch, root, x, z, w, h, buf);
            try out.print("L{d}:", .{li});
            for (buf) |v| try out.print(" {d}", .{v});
            try out.print("\n", .{});
            _ = arena.reset(.retain_capacity);
        }
    } else {
        try out.print("seed={d} nlayers={d} window=({d},{d},{d},{d})\n", .{ seed, built.chain.layers.len, x, z, w, h });
        for (built.chain.layers, 0..) |lay, li| {
            const buf = try scratch.alloc(i32, w * h);
            try built.chain.getInts(scratch, @intCast(li), x, z, w, h, buf);
            try out.print("L{d} {s}:", .{ li, @tagName(lay.kind) });
            for (buf) |v| try out.print(" {d}", .{v});
            try out.print("\n", .{});
            _ = arena.reset(.retain_capacity);
        }
    }
    try out.flush();
}

test {
    _ = @import("asteorite");
}
