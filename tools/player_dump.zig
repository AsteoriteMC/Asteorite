//! player_dump: inspect one persisted player row (ZPLR format).
//! Usage: player_dump <db-dir> <username>
//!
//! Read-only in spirit (opens the pool like the server does; creates the
//! dir if missing, in which case there is simply no save). Prints position,
//! health/food/gamemode, spawn, and every non-empty inventory slot with
//! NBT byte counts (never dumps raw NBT — use an NBT tool for that).

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
    if (args.len < 3) {
        try out.print("usage: player_dump <db-dir> <username>\n", .{});
        try out.flush();
        return;
    }
    const db_path = args[1];
    const username = args[2];

    const cwd = std.Io.Dir.cwd();
    var db_dir = try cwd.createDirPathOpen(io, db_path, .{});
    defer db_dir.close(io);
    var pool = try asteorite.shard.ShardPool.open(arena_alloc, io, db_dir, 4, .{});
    defer pool.deinit();

    var data = try asteorite.players.loadLegacy(pool, arena_alloc, username, asteorite.player_import.legacySlot) orelse {
        try out.print("no save found for {s} in {s}\n", .{ username, db_path });
        try out.flush();
        return;
    };
    defer asteorite.players.freeData(arena_alloc, &data);
    try out.print(
        "{s}: pos=({d:.1},{d:.1},{d:.1}) yaw={d:.1} pitch={d:.1} spawn=({d},{d},{d}) health={d:.1} food={d} sat={d:.1} gamemode={d} selected={d}\n",
        .{
            username,
            data.pos_x,
            data.pos_y,
            data.pos_z,
            data.yaw,
            data.pitch,
            data.spawn_x,
            data.spawn_y,
            data.spawn_z,
            data.health,
            data.food,
            data.saturation,
            data.gamemode,
            data.selected,
        },
    );
    for (data.inv, 0..) |slot, i| {
        if (slot) |st| {
            // Operator-facing: wire ids match /give and vanilla tools; canonical indices are internal.
            const wid = wire.toWire(st.id);
            if (st.nbt) |n| {
                try out.print("  slot {d}: id={d} count={d} dmg={d} nbt={d}B\n", .{ i, wid, st.count, st.damage, n.len });
            } else {
                try out.print("  slot {d}: id={d} count={d} dmg={d}\n", .{ i, wid, st.count, st.damage });
            }
        }
    }
    if (data.cursor) |c| {
        try out.print("  cursor: id={d} count={d} dmg={d}", .{ wire.toWire(c.id), c.count, c.damage });
        if (c.nbt) |n| try out.print(" nbt={d}B", .{n.len});
        try out.print("\n", .{});
    }
    try out.flush();
}
