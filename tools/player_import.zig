//! player_import: migrate a vanilla 1.7.10 player.dat into the LSM store.
//! Usage: player_import <player.dat> <db-dir> <username> [shards=4]
//!
//! player.dat is gzip-NBT (vanilla per-UUID file, e.g.
//! world/playerdata/<uuid>.dat). The username is required explicitly: the
//! filename carries only a UUID, while our key + stored name need the exact
//! login bytes (case-sensitive, matching offline-UUID behavior).
//! Conversion follows src/sim/players.zig.fromVanillaNbt (JVM-verified
//! layout; see the doc comment there for the field mapping).

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
        try out.print("usage: player_import <player.dat> <db-dir> <username> [shards=4]\n", .{});
        try out.flush();
        return;
    }
    const dat_path = args[1];
    const db_path = args[2];
    const username = args[3];
    var shards: usize = 4;
    if (args.len >= 5) shards = std.fmt.parseInt(usize, args[4], 10) catch {
        try out.print("bad shards {s}\n", .{args[4]});
        try out.flush();
        return;
    };
    if (username.len == 0 or username.len > 16) {
        try out.print("bad username (1..16 chars)\n", .{});
        try out.flush();
        return;
    }

    const cwd = std.Io.Dir.cwd();
    const gz = cwd.readFileAlloc(io, dat_path, arena_alloc, .limited(1 << 26)) catch {
        try out.print("cannot read {s}\n", .{dat_path});
        try out.flush();
        return;
    };
    const plain = zigcraft.nbt.gunzipAlloc(arena_alloc, gz) catch {
        try out.print("cannot gunzip {s} (not a vanilla player.dat?)\n", .{dat_path});
        try out.flush();
        return;
    };
    var imported = zigcraft.players.fromVanillaNbt(arena_alloc, plain, username) catch {
        try out.print("cannot parse {s} as 1.7.10 player NBT\n", .{dat_path});
        try out.flush();
        return;
    };
    defer zigcraft.players.freeData(arena_alloc, &imported.data);

    var db_dir = try std.Io.Dir.cwd().createDirPathOpen(io, db_path, .{});
    defer db_dir.close(io);
    var pool = try zigcraft.shard.ShardPool.open(arena_alloc, io, db_dir, shards, .{});
    defer pool.deinit();
    try zigcraft.players.save(pool, username, &imported.data);
    try pool.flushAll();

    var nbt_total: usize = 0;
    var filled: usize = 0;
    for (imported.data.inv) |s| {
        if (s) |st| {
            filled += 1;
            if (st.nbt) |n| nbt_total += n.len;
        }
    }
    try out.print(
        "imported {s} -> {s}: pos=({d:.1},{d:.1},{d:.1}) spawn=({d},{d},{d}) health={d:.1} food={d} gamemode={d} inv_slots={d} nbt_bytes={d}",
        .{
            dat_path,                    db_path,
            imported.data.pos_x,         imported.data.pos_y, imported.data.pos_z,
            imported.data.spawn_x,       imported.data.spawn_y, imported.data.spawn_z,
            imported.data.health,        imported.data.food,    imported.data.gamemode,
            filled,                      nbt_total,
        },
    );
    if (imported.stats.defaulted_spawn) try out.print(" [spawn=defaulted-to-pos]", .{});
    if (imported.stats.dimension != 0) try out.print(" [WARNING: vanilla dimension was {d}, imported flat into dim 0]", .{imported.stats.dimension});
    if (imported.stats.unknown_slots > 0 or imported.stats.dropped_stacks > 0) try out.print(" [skipped slots={d} stacks={d}]", .{ imported.stats.unknown_slots, imported.stats.dropped_stacks });
    try out.print("\n", .{});
    try out.flush();
}
