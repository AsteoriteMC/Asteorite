//! worldgen_dump: inspect the H1 pipeline foundation for a seed + chunk.
//! Usage: worldgen_dump <seed> <x> <z> [count]
//! Prints stage order + the first `count` java.util.Random draws
//! (nextInt/nextLong/nextFloat/nextDouble). Every value here is
//! JVM-verified: diff against Goldens.java output for the same seed.

const std = @import("std");
const zigcraft = @import("zigcraft");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena_alloc: std.mem.Allocator = init.arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;

    const args = try init.minimal.args.toSlice(arena_alloc);
    if (args.len < 4) {
        try out.print("usage: worldgen_dump <seed> <x> <z> [count=4]\n", .{});
        try out.flush();
        return;
    }
    const seed = std.fmt.parseInt(i64, args[1], 0) catch {
        try out.print("bad seed {s}\n", .{args[1]});
        try out.flush();
        return;
    };
    const cx = std.fmt.parseInt(i32, args[2], 0) catch {
        try out.print("bad x {s}\n", .{args[2]});
        try out.flush();
        return;
    };
    const cz = std.fmt.parseInt(i32, args[3], 0) catch {
        try out.print("bad z {s}\n", .{args[3]});
        try out.flush();
        return;
    };
    var count: usize = 4;
    if (args.len >= 5) {
        count = std.fmt.parseInt(usize, args[4], 0) catch {
            try out.print("bad count {s}\n", .{args[4]});
            try out.flush();
            return;
        };
        count = @min(count, 64);
    }

    var ctx = zigcraft.worldgen.GenCtx.init(seed, cx, cz);
    try out.print("seed={d} chunk=({d},{d}) stages=", .{ seed, cx, cz });
    for (zigcraft.worldgen.StageId.order(), 0..) |s, i| {
        if (i > 0) try out.print(",", .{});
        try out.print("{s}", .{@tagName(s)});
    }
    try out.print("\n", .{});

    // Section 1: fresh-stream first draws — byte-comparable with Goldens.java
    // (each method from `new Random(seed)`). This is the parity contract.
    try out.print("--- fresh-stream first draws (diff vs Goldens.java)\n", .{});
    {
        var r = zigcraft.java_random.JavaRandom.init(seed);
        try out.print("nextInt={d}\n", .{r.nextInt()});
    }
    {
        var r = zigcraft.java_random.JavaRandom.init(seed);
        try out.print("nextLong={d}\n", .{r.nextLong()});
    }
    {
        var r = zigcraft.java_random.JavaRandom.init(seed);
        try out.print("nextInt(100)={d},{d},{d}\n", .{
            try r.nextIntBound(100),
            try r.nextIntBound(100),
            try r.nextIntBound(100),
        });
    }
    {
        var r = zigcraft.java_random.JavaRandom.init(seed);
        try out.print("nextFloat={} nextDouble={}\n", .{ r.nextFloat(), r.nextDouble() });
    }
    {
        var r = zigcraft.java_random.JavaRandom.init(seed);
        var b: [8]u8 = undefined;
        r.nextBytes(&b);
        try out.print("nextBytes=", .{});
        for (b) |x| try out.print("{x:0>2}", .{x});
        try out.print("\n", .{});
    }
    {
        var r = zigcraft.java_random.JavaRandom.init(seed);
        try out.print("nextGaussian={}, {}\n", .{ r.nextGaussian(), r.nextGaussian() });
    }

    // Section 2: interleaved draws through the pipeline context's shared RNG
    // — the same path H2 stages will consume. Same seed => same stream.
    try out.print("--- interleaved stream (ctx.rng, {d} rows)\n", .{count});
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try out.print(
            "[{d}] nextInt={d} nextLong={d} nextFloat={} nextDouble={}\n",
            .{ i, ctx.rng.nextInt(), ctx.rng.nextLong(), ctx.rng.nextFloat(), ctx.rng.nextDouble() },
        );
    }
    try out.flush();
}

test {
    _ = @import("zigcraft");
}
