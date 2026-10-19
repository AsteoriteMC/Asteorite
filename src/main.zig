const std = @import("std");
const zigcraft = @import("zigcraft");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena: std.mem.Allocator = init.arena.allocator();
    var file_buf: [1024]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), io, &file_buf);
    const w = &out.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "serve")) {
        var port: u16 = 25565;
        var online = false;
        var db_path: ?[]const u8 = null;
        var view_distance: u8 = 4;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--online")) {
                online = true;
            } else if (std.mem.eql(u8, a, "--db")) {
                i += 1;
                if (i >= args.len) return error.MissingDbPath;
                db_path = args[i];
            } else if (std.mem.eql(u8, a, "--view")) {
                i += 1;
                if (i >= args.len) return error.MissingViewDistance;
                view_distance = try std.fmt.parseInt(u8, args[i], 10);
            } else {
                port = try std.fmt.parseInt(u16, a, 10);
            }
        }
        var cfg = zigcraft.conn.Config{};
        var keys: ?zigcraft.rsa.RsaKeyPair = null;
        if (online) {
            const cwd = std.Io.Dir.cwd();
            keys = try zigcraft.rsa.ensureKeys(io, arena, cwd, "server_rsa.key", "server_rsa.der");
            cfg.online_mode = true;
            cfg.rsa = &keys.?;
        }
        var srv = try zigcraft.server.Server.bindAny(io, port, cfg);
        defer srv.deinit();
        srv.view_distance = view_distance;
        var db_dir: ?std.Io.Dir = null;
        defer if (db_dir) |*d| d.close(io);
        var pool: ?*zigcraft.shard.ShardPool = null;
        if (db_path) |p| {
            db_dir = try std.Io.Dir.cwd().createDirPathOpen(io, p, .{});
            pool = try zigcraft.shard.ShardPool.open(arena, io, db_dir.?, 4, .{});
            srv.world = pool;
        }
        defer if (pool) |pl| pl.deinit();
        try w.print("zigcraft listening on 0.0.0.0:{d} (proto 5, online={}, db={s}, view={d})\n", .{ port, online, db_path orelse "none", view_distance });
        try w.flush();
        // serveForever never returns; per-conn arenas hang off the process arena.
        try srv.serveForever(arena);
        return;
    }
    try w.print("zigcraft 1.7.10 proto v5. Try `zig build run -- serve [port] [--online] [--db <path>] [--view N]`, `zig build test`, `zig build dump -- <region.mca>`, `zig build import -- <region.mca> <db> [dim] [shards]`\n", .{});
    try w.flush();
}
