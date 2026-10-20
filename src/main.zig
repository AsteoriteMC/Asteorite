const std = @import("std");
const zigcraft = @import("zigcraft");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena: std.mem.Allocator = init.arena.allocator();
    var file_buf: [1024]u8 = undefined;
    var out: std.Io.File.Writer = .initStreaming(.stdout(), io, &file_buf);
    const w = &out.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "serve")) {
        var port: u16 = 25565;
        var online = false;
        var db_path: ?[]const u8 = null;
        var view_distance: u8 = 4;
        var seed: ?i64 = null;
        var gen_spawn: ?i32 = null;
        var ops: std.ArrayList([]const u8) = .empty;
        defer ops.deinit(arena);
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
            } else if (std.mem.eql(u8, a, "--seed")) {
                i += 1;
                if (i >= args.len) return error.MissingSeed;
                seed = try std.fmt.parseInt(i64, args[i], 0);
            } else if (std.mem.eql(u8, a, "--gen-spawn")) {
                i += 1;
                if (i >= args.len) return error.MissingGenSpawn;
                gen_spawn = try std.fmt.parseInt(i32, args[i], 10);
            } else if (std.mem.eql(u8, a, "--op")) {
                i += 1;
                if (i >= args.len) return error.MissingOpName;
                try ops.append(arena, args[i]);
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
        // Worldgen (needs the pool): --seed enables on-demand fill, and
        // --gen-spawn N pre-generates a spiral disk of radius N on boot.
        var gen: ?zigcraft.v5gen.Gen = null;
        defer if (gen) |*g| g.deinit();
        if (seed) |s| {
            if (db_path == null) return error.GenNeedsDb;
            gen = try zigcraft.v5gen.Gen.init(arena, s, false, false);
            srv.gen = &gen.?;
            srv.gen_src = .{ .pool = pool.?, .gen = &gen.?, .lock = &srv.world_lock };
        } else if (gen_spawn != null) {
            return error.GenSpawnNeedsSeed;
        }
        if (gen_spawn) |r| {
            const n = try zigcraft.v5serve.preGen(pool.?, &gen.?, &srv.world_lock, arena, r);
            try w.print("gen: pre-generated {d} chunks around spawn\n", .{n});
        }
        // Permissions: load the matrix, then apply --op bootstraps (level 4,
        // persisted immediately so restarts keep them without the flag).
        // No --op and no stored ops: secure default, console-only admin.
        srv.gpa = arena;
        srv.loadPerms();
        for (ops.items) |name| {
            if (!zigcraft.conn.Conn.validPlayerName(name)) {
                try w.print("ignoring --op {s}: bad player name\n", .{name});
                continue;
            }
            srv.grantOp(name);
        }
        {
            srv.perm_lock.lock();
            const n = if (srv.perms) |*db| db.countOps() else 0;
            srv.perm_lock.unlock();
            if (n == 0) try w.print("perms: no ops stored (console only). use --op <name> to bootstrap.\n", .{});
        }
        try w.print("zigcraft listening on 0.0.0.0:{d} (proto 5, online={}, db={s}, view={d}, seed={?d})\n", .{ port, online, db_path orelse "none", view_distance, seed });
        try w.flush();
        // Operator console (stdin): help | list | save-all | stop.
        // Detached; in-game commands share Server.handleCommand.
        const Console = struct {
            fn run(s: *zigcraft.server.Server) void {
                var fbuf: [256]u8 = undefined;
                var reader = std.Io.File.stdin().reader(s.io, &fbuf);
                const rin = &reader.interface;
                var line: [256]u8 = undefined;
                var len: usize = 0;
                while (true) {
                    const b = rin.takeByte() catch return;
                    if (b == '\n') {
                        var cmd = line[0..len];
                        len = 0;
                        while (cmd.len > 0 and (cmd[cmd.len - 1] == '\r' or cmd[cmd.len - 1] == ' ')) cmd = cmd[0 .. cmd.len - 1];
                        if (cmd.len == 0) continue;
                        if (std.mem.eql(u8, cmd, "stop")) {
                            const n = s.saveAllPlayers();
                            if (s.world) |pl| pl.flushAll() catch {};
                            std.log.info("stop: saved {d} player(s), flushed. bye.", .{n});
                            std.process.exit(0);
                        }
                        // Route through the same core (null sender = console).
                        var tmp: [257]u8 = undefined;
                        tmp[0] = '/';
                        const n = @min(cmd.len, tmp.len - 1);
                        @memcpy(tmp[1..][0..n], cmd[0..n]);
                        s.handleCommand(null, tmp[0 .. n + 1]);
                    } else {
                        if (len < line.len) {
                            line[len] = b;
                            len += 1;
                        }
                    }
                }
            }
        };
        const console_th = std.Thread.spawn(.{}, Console.run, .{&srv}) catch null;
        if (console_th) |th| th.detach();
        // serveForever never returns; per-conn arenas hang off the process arena.
        try srv.serveForever(arena);
        return;
    }
    try w.print("zigcraft 1.7.10 proto v5. Try `zig build run -- serve [port] [--online] [--db <path>] [--view N] [--seed S] [--gen-spawn N] [--op <name>...]`, `zig build test`, `zig build dump -- <region.mca>`, `zig build import -- <region.mca> <db> [dim] [shards]`\n", .{});
    try w.flush();
}
