//! col_dump: print one column of a stored chunk (diagnostic).
//! Usage: col_dump <db-dir> <cx> <cz> <lx> <lz> [y0=0] [y1=255]
//!
//! Opens the shard pool like the server does (point it at a COPY of a
//! live world, never the live dir itself) and prints `y wire-id name`
//! for the column, plus the heightmap value. Wire ids match /give and
//! vanilla tools; canonical indices are internal.

const std = @import("std");
const asteorite = @import("asteorite");
const wire = asteorite.v5wire;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena_alloc: std.mem.Allocator = init.arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;

    const args = try init.minimal.args.toSlice(arena_alloc);
    if (args.len < 6) {
        try out.print("usage: col_dump <db-dir> <cx> <cz> <lx> <lz> [y0=0] [y1=255]\n", .{});
        try out.flush();
        return;
    }
    const db_path = args[1];
    const cx = std.fmt.parseInt(i32, args[2], 0) catch {
        try out.print("bad cx {s}\n", .{args[2]});
        try out.flush();
        return;
    };
    const cz = std.fmt.parseInt(i32, args[3], 0) catch {
        try out.print("bad cz {s}\n", .{args[3]});
        try out.flush();
        return;
    };
    const lx = std.fmt.parseInt(usize, args[4], 0) catch {
        try out.print("bad lx {s}\n", .{args[4]});
        try out.flush();
        return;
    };
    const lz = std.fmt.parseInt(usize, args[5], 0) catch {
        try out.print("bad lz {s}\n", .{args[5]});
        try out.flush();
        return;
    };
    var y0: usize = 0;
    var y1: usize = 255;
    if (args.len >= 7) y0 = std.fmt.parseInt(usize, args[6], 0) catch {
        try out.print("bad y0 {s}\n", .{args[6]});
        try out.flush();
        return;
    };
    if (args.len >= 8) y1 = std.fmt.parseInt(usize, args[7], 0) catch {
        try out.print("bad y1 {s}\n", .{args[7]});
        try out.flush();
        return;
    };
    if (lx > 15 or lz > 15 or y0 > y1 or y1 > 255) {
        try out.print("bad range\n", .{});
        try out.flush();
        return;
    }

    const cwd = std.Io.Dir.cwd();
    var db_dir = try cwd.createDirPathOpen(io, db_path, .{});
    defer db_dir.close(io);
    var pool = try asteorite.shard.ShardPool.open(arena_alloc, io, db_dir, 4, .{});
    defer pool.deinit();

    var ch = try pool.getChunk(arena_alloc, 0, cx, cz) orelse {
        try out.print("chunk ({d},{d}) absent (hole)\n", .{ cx, cz });
        try out.flush();
        return;
    };
    defer ch.destroy(arena_alloc);
    try out.print("chunk ({d},{d}) heights[{d}]={d}\n", .{ cx, cz, lz * 16 + lx, ch.heights[lz * 16 + lx] });
    var y = y0;
    while (y <= y1) : (y += 1) {
        const id = ch.blockAt(lx, y, lz);
        try out.print("{d} {d} {s}\n", .{ y, wire.toWire(id), @tagName(id) });
    }
    try out.flush();
}
