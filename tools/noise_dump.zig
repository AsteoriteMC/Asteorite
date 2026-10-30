//! noise_dump: parity probe for tools/parity noise area (mirrors
//! oracles/noise/NoiseOracle.java). All floats print as raw u64 bits
//! (hex), so comparison is bit-exact.
//! Usage: noise_dump <mode> <seed> [params...]
//!   oct <seed> <count> <x> <y> <z> <xs> <ys> <zs> <sx> <sy> <sz>
//!   oct2 <seed> <count> <x> <z> <xs> <zs> <sx> <sz>
//!   simplex <seed> <count> <x> <z>
//!   sgrid <seed> <count> <x> <z> <xs> <zs> <sx> <sz> <fm> <am>

const std = @import("std");
const asteorite = @import("asteorite");

const noise_mod = asteorite.v5noise;
const java_random = asteorite.java_random;

fn printBits(out: *std.Io.Writer, tag: []const u8, vals: []const f64) !void {
    try out.print("{s}={d}", .{ tag, vals.len });
    for (vals) |v| try out.print(" {x}", .{@as(u64, @bitCast(v))});
    try out.print("\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena_alloc: std.mem.Allocator = init.arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;

    const args = try init.minimal.args.toSlice(arena_alloc);
    if (args.len < 4) {
        try out.print("usage: noise_dump <mode> <seed> [params...]\n", .{});
        try out.flush();
        return;
    }
    const mode = args[1];
    const seed = std.fmt.parseInt(i64, args[2], 0) catch return;

    if (std.mem.eql(u8, mode, "oct")) {
        if (args.len < 13) return;
        const count = try std.fmt.parseInt(usize, args[3], 0);
        const x = try std.fmt.parseInt(i32, args[4], 0);
        const y = try std.fmt.parseInt(i32, args[5], 0);
        const z = try std.fmt.parseInt(i32, args[6], 0);
        const xs = try std.fmt.parseInt(usize, args[7], 0);
        const ys = try std.fmt.parseInt(usize, args[8], 0);
        const zs = try std.fmt.parseInt(usize, args[9], 0);
        const sx = try std.fmt.parseFloat(f64, args[10]);
        const sy = try std.fmt.parseFloat(f64, args[11]);
        const sz = try std.fmt.parseFloat(f64, args[12]);
        var r = java_random.JavaRandom.init(seed);
        var g = try noise_mod.Octaves.init(arena_alloc, &r, count);
        defer g.deinit();
        const vals = g.generate(null, x, y, z, xs, ys, zs, sx, sy, sz);
        defer arena_alloc.free(vals);
        try printBits(out, "oct", vals);
    } else if (std.mem.eql(u8, mode, "oct2")) {
        if (args.len < 10) return;
        const count = try std.fmt.parseInt(usize, args[3], 0);
        const x = try std.fmt.parseInt(i32, args[4], 0);
        const z = try std.fmt.parseInt(i32, args[5], 0);
        const xs = try std.fmt.parseInt(usize, args[6], 0);
        const zs = try std.fmt.parseInt(usize, args[7], 0);
        const sx = try std.fmt.parseFloat(f64, args[8]);
        const sz = try std.fmt.parseFloat(f64, args[9]);
        var r = java_random.JavaRandom.init(seed);
        var g = try noise_mod.Octaves.init(arena_alloc, &r, count);
        defer g.deinit();
        // awk 2D entry point calls 3D with y=10, ySize=1.
        const vals = g.generate(null, x, 10, z, xs, 1, zs, sx, 1.0, sz);
        defer arena_alloc.free(vals);
        try printBits(out, "oct2", vals);
    } else if (std.mem.eql(u8, mode, "simplex")) {
        if (args.len < 6) return;
        const count = try std.fmt.parseInt(usize, args[3], 0);
        const x = try std.fmt.parseFloat(f64, args[4]);
        const z = try std.fmt.parseFloat(f64, args[5]);
        var r = java_random.JavaRandom.init(seed);
        var g = try noise_mod.SimplexOctaves.init(arena_alloc, &r, count);
        defer g.deinit();
        const v = g.eval(x, z);
        try out.print("simplex={x}\n", .{@as(u64, @bitCast(v))});
    } else if (std.mem.eql(u8, mode, "sgrid")) {
        if (args.len < 12) return;
        const count = try std.fmt.parseInt(usize, args[3], 0);
        const x = try std.fmt.parseFloat(f64, args[4]);
        const z = try std.fmt.parseFloat(f64, args[5]);
        const xs = try std.fmt.parseInt(usize, args[6], 0);
        const zs = try std.fmt.parseInt(usize, args[7], 0);
        const sx = try std.fmt.parseFloat(f64, args[8]);
        const sz = try std.fmt.parseFloat(f64, args[9]);
        const fm = try std.fmt.parseFloat(f64, args[10]);
        const am = try std.fmt.parseFloat(f64, args[11]);
        var r = java_random.JavaRandom.init(seed);
        var g = try noise_mod.SimplexOctaves.init(arena_alloc, &r, count);
        defer g.deinit();
        const vals = g.grid(null, x, z, xs, zs, sx, sz, fm, am);
        defer arena_alloc.free(vals);
        try printBits(out, "sgrid", vals);
    } else {
        try out.print("unknown mode {s}\n", .{mode});
    }
    try out.flush();
}
