//! genbench: time single-chunk generation.
const std = @import("std");
const zigcraft = @import("zigcraft");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena_alloc: std.mem.Allocator = init.arena.allocator();
    var stdout_buf: [1024]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;
    const args = try init.minimal.args.toSlice(arena_alloc);
    const seed: i64 = if (args.len > 1) try std.fmt.parseInt(i64, args[1], 0) else 42;
    const cx: i32 = if (args.len > 2) try std.fmt.parseInt(i32, args[2], 0) else 0;
    const cz: i32 = if (args.len > 3) try std.fmt.parseInt(i32, args[3], 0) else 0;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var gen = try zigcraft.v5gen.Gen.init(gpa.allocator(), seed, false, false);
    defer gen.deinit();
    const t0 = std.Io.Timestamp.now(init.io, .awake);
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const ch = try gen.genChunk(gpa.allocator(), arena.allocator(), cx, cz);
        ch.destroy(gpa.allocator());
    }
    const t1 = std.Io.Timestamp.now(init.io, .awake);
    try out.print("chunk ({d},{d}) seed {d}: {d} ms\n", .{ cx, cz, seed, @divFloor(t0.durationTo(t1).nanoseconds, 1000000) });
    try out.flush();
}

test {
    _ = @import("zigcraft");
}
