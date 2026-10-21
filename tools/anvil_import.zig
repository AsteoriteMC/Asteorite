//! anvil_import: migrate a 1.7.10 .mca region file INTO the LSM store.
//! Usage: zig build import -- <region.mca> <db-dir> [dim=0] [shards=4]
//!
//! Each present chunk is converted Anvil NBT -> ZC1 payload (see chunk.zig)
//! and stored under key [dim:u8|x:i32 BE|z:i32 BE]. Region filename r.X.Z.mca
//! gives the base chunk coords; local (lx,lz) -> global (X*32+lx, Z*32+lz).
//! Tombstones are NOT written for missing chunks (fresh DB assumed).
//! Layout matches the server runtime ShardPool (db/shard-NN/...).

const std = @import("std");
const zigcraft = @import("zigcraft");

fn parseRegionName(path: []const u8) ?struct { rx: i32, rz: i32 } {
    const base = std.fs.path.basename(path);
    if (!std.mem.startsWith(u8, base, "r.")) return null;
    if (!std.mem.endsWith(u8, base, ".mca")) return null;
    const inner = base[2 .. base.len - 4];
    const dot = std.mem.indexOfScalar(u8, inner, '.') orelse return null;
    const rx = std.fmt.parseInt(i32, inner[0..dot], 10) catch return null;
    const rz = std.fmt.parseInt(i32, inner[dot + 1 ..], 10) catch return null;
    return .{ .rx = rx, .rz = rz };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena_alloc: std.mem.Allocator = init.arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;

    const args = try init.minimal.args.toSlice(arena_alloc);
    if (args.len < 3) {
        try out.print("usage: anvil_import <region.mca> <db-dir> [dim=0]\n", .{});
        try out.flush();
        return;
    }
    const mca_path = args[1];
    const db_path = args[2];
    var dim: u8 = 0;
    if (args.len >= 4) dim = try std.fmt.parseInt(u8, args[3], 10);
    var n_shards: usize = 4;
    if (args.len >= 5) n_shards = try std.fmt.parseInt(usize, args[4], 10);

    const region = parseRegionName(mca_path) orelse {
        try out.print("cannot parse region coords from {s} (want r.X.Z.mca)\n", .{mca_path});
        try out.flush();
        return;
    };

    // read whole .mca
    const cwd = std.Io.Dir.cwd();
    const mca_data = cwd.readFileAlloc(io, mca_path, arena_alloc, .limited(1 << 31)) catch {
        try out.print("cannot read {s}\n", .{mca_path});
        try out.flush();
        return;
    };

    // open sharded LSM db (creates dirs) — same layout as server runtime
    var db_dir = try cwd.createDirPathOpen(io, db_path, .{});
    defer db_dir.close(io);
    var pool = try zigcraft.shard.ShardPool.open(arena_alloc, io, db_dir, n_shards, .{});
    defer pool.deinit();

    const hdr = zigcraft.anvil.parseHeader(mca_data) catch {
        try out.print("bad anvil header\n", .{});
        try out.flush();
        return;
    };
    var imported: usize = 0;
    for (0..32) |lz| {
        for (0..32) |lx| {
            const raw = hdr.locations[lx + lz * 32];
            if (zigcraft.anvil.decodeLocation(raw).present == false) continue;
            const payload = zigcraft.anvil.getChunkPayload(
                mca_data,
                @intCast(lx),
                @intCast(lz),
            ) catch continue;
            const plain = zigcraft.anvil.decompressChunk(arena_alloc, payload) catch continue;
            const gx: i32 = region.rx * 32 + @as(i32, @intCast(lx));
            const gz: i32 = region.rz * 32 + @as(i32, @intCast(lz));
            const ch = zigcraft.chunk.fromAnvilNbt(arena_alloc, plain, dim) catch continue;
            // trust filename region for coords (authoritative); override NBT pos
            ch.x = gx;
            ch.z = gz;
            try pool.putChunk(arena_alloc, ch);
            imported += 1;
        }
    }
    try pool.flushAll();
    try out.print("imported {d} chunks from {s} (region {d},{d}) dim={d} -> {s}\n", .{
        imported, mca_path, region.rx, region.rz, dim, db_path,
    });
    try out.flush();
}
