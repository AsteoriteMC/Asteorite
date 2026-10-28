//! chest_dump: inspect one persisted chest row (ZCHT format).
//! Usage: chest_dump <db-dir> <x> <y> <z>
//!
//! Read-only in spirit (opens the pool like the server does; creates the
//! dir if missing, in which case there is simply no row). Prints every
//! non-empty slot with NBT byte counts (never dumps raw NBT).

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
    if (args.len < 5) {
        try out.print("usage: chest_dump <db-dir> <x> <y> <z>\n", .{});
        try out.flush();
        return;
    }
    const db_path = args[1];
    const x = std.fmt.parseInt(i32, args[2], 0) catch {
        try out.print("bad x {s}\n", .{args[2]});
        try out.flush();
        return;
    };
    const y = std.fmt.parseInt(i32, args[3], 0) catch {
        try out.print("bad y {s}\n", .{args[3]});
        try out.flush();
        return;
    };
    const z = std.fmt.parseInt(i32, args[4], 0) catch {
        try out.print("bad z {s}\n", .{args[4]});
        try out.flush();
        return;
    };

    const cwd = std.Io.Dir.cwd();
    var db_dir = try cwd.createDirPathOpen(io, db_path, .{});
    defer db_dir.close(io);
    var pool = try asteorite.shard.ShardPool.open(arena_alloc, io, db_dir, 4, .{});
    defer pool.deinit();

    var row = try asteorite.chest.loadRow(pool, arena_alloc, x, y, z) orelse {
        try out.print("no chest row at {d},{d},{d} in {s}\n", .{ x, y, z, db_path });
        try out.flush();
        return;
    };
    defer asteorite.chest.freeSlots(arena_alloc, &row.slots);
    var filled: usize = 0;
    for (row.slots, 0..) |slot, i| {
        if (slot) |st| {
            filled += 1;
            const wid = wire.toWire(st.id);
            if (st.nbt) |n| {
                try out.print("  slot {d}: id={d} count={d} dmg={d} nbt={d}B\n", .{ i, wid, st.count, st.damage, n.len });
            } else {
                try out.print("  slot {d}: id={d} count={d} dmg={d}\n", .{ i, wid, st.count, st.damage });
            }
        }
    }
    try out.print("chest {d},{d},{d}: {d}/27 slots filled\n", .{ x, y, z, filled });
    try out.flush();
}
