const std = @import("std");
const asteorite = @import("asteorite");
const cli = @import("cli.zig");
const config = @import("config.zig");
const console_tui = asteorite.console_tui;

pub const std_options: std.Options = .{
    .logFn = console_tui.logFn,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena: std.mem.Allocator = init.arena.allocator();
    var file_buf: [1024]u8 = undefined;
    var out: std.Io.File.Writer = .initStreaming(.stdout(), io, &file_buf);
    const w = &out.interface;

    const args = try init.minimal.args.toSlice(arena);
    const version_info = cli.VersionInfo{
        .name = asteorite.version.meta.name,
        .protocol = asteorite.version.meta.protocol,
        .profile_id = asteorite.version.meta.profile_id,
    };
    if (args.len >= 2 and
        (std.mem.eql(u8, args[1], "--version") or
            std.mem.eql(u8, args[1], "-v") or
            std.mem.eql(u8, args[1], "version")))
    {
        try cli.printVersion(w, version_info);
        try w.flush();
        return;
    }
    if (args.len < 2 or std.mem.eql(u8, args[1], "help") or
        std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))
    {
        try cli.printTopHelp(w, version_info);
        try w.flush();
        return;
    }
    if (!std.mem.eql(u8, args[1], "serve")) {
        try w.print("asteorite: unknown subcommand '{s}'\n\n", .{args[1]});
        try cli.printTopHelp(w, version_info);
        try w.flush();
        return error.UnknownSubcommand;
    }
    {
        var perr = cli.ParseError{};
        var parsed = cli.parseServe(arena, args[2..], &perr) catch {
            var mbuf: [192]u8 = undefined;
            try w.print("{s}\n", .{cli.message(&perr, &mbuf)});
            try w.flush();
            return perrToError(&perr);
        };
        defer parsed.ops.deinit(arena);
        if (parsed.help) {
            try cli.printServeHelp(w);
            try w.flush();
            return;
        }
        // Config file: explicit --config (must exist) or ./asteorite.json if
        // present. Precedence: defaults < file < CLI flags.
        var eff = config.Effective{};
        var cfg_source: []const u8 = "defaults";
        const cfg_path = parsed.config_path orelse config.default_path;
        const cfg_required = parsed.config_path != null;
        const cfg_dir = std.Io.Dir.cwd();
        const cfg_text = cfg_dir.readFileAlloc(io, cfg_path, arena, .limited(1 << 20)) catch |err| blk: {
            if (!cfg_required and err == error.FileNotFound) break :blk null;
            try w.print("serve: cannot read config '{s}' ({s})\n", .{ cfg_path, @errorName(err) });
            try w.flush();
            return err;
        };
        var file_seed: ?i64 = null;
        if (cfg_text) |text| {
            var fc = config.parseJson(arena, text) catch |err| {
                try w.print("serve: bad config '{s}' ({s})\n", .{ cfg_path, @errorName(err) });
                try w.flush();
                return err;
            };
            // NOTE: no fc.deinit() — eff borrows the file's strings (db,
            // ops, rcon_password) for the life of the server and the process
            // arena never frees anyway (see above).
            file_seed = fc.value.resolveSeed() catch |err| {
                try w.print("serve: bad \"seed\" in '{s}' ({s}: integer or string)\n", .{ cfg_path, @errorName(err) });
                try w.flush();
                return err;
            };
            eff = config.merge(eff, &fc.value, file_seed);
            eff.source = .file;
            cfg_source = cfg_path;
        }
        // CLI overrides (only keys actually given).
        if (parsed.port) |v| eff.port = v;
        if (parsed.online) |v| eff.online = v;
        if (parsed.db) |v| eff.db = v;
        if (parsed.view_distance) |v| eff.view_distance = v;
        if (parsed.gen_spawn) |v| eff.gen_spawn = v;
        if (parsed.gen_workers) |v| eff.gen_workers = v;
        if (parsed.ops.items.len > 0) eff.ops = parsed.ops.items;
        if (parsed.rcon_password) |v| eff.rcon_password = v;
        if (parsed.rcon_port) |v| eff.rcon_port = v;
        if (parsed.motd) |v| eff.motd = v;
        if (parsed.max_players) |v| eff.max_players = v;
        if (parsed.brand) |v| eff.brand = v;
        if (parsed.transport) |v| eff.transport = v;
        if (parsed.storage_profile) |v| eff.storage_profile = v;
        if (parsed.transport_workers) |v| eff.transport_workers = v;
        if (parsed.region_threads) |v| eff.region_threads = v;
        if (parsed.out_cap_bytes) |v| eff.out_cap_bytes = v;
        if (parsed.send_zc_threshold) |v| eff.send_zc_threshold = v;
        if (parsed.tcp_nodelay) |v| eff.tcp_nodelay = v;
        if (parsed.sndbuf) |v| eff.sndbuf = v;
        if (parsed.rcvbuf) |v| eff.rcvbuf = v;
        if (parsed.login_rate_window_ms) |v| eff.login_rate_window_ms = v;
        if (parsed.login_rate_burst) |v| eff.login_rate_burst = v;
        if (parsed.place_rate_window_ms) |v| eff.place_rate_window_ms = v;
        if (parsed.place_rate_burst) |v| eff.place_rate_burst = v;
        config.validate(&eff) catch |err| {
            try w.print("serve: {s}\n", .{config.validateMessage(err)});
            try w.flush();
            return err;
        };
        const port: u16 = eff.port;
        const online = eff.online;
        const db_path: ?[]const u8 = eff.db;
        const view_distance: u8 = eff.view_distance;
        const seed: ?i64 = eff.seed;
        const gen_spawn: ?i32 = eff.gen_spawn;
        var ops: std.ArrayList([]const u8) = .empty;
        defer ops.deinit(arena);
        for (eff.ops) |name| try ops.append(arena, name);
        const rcon_password: ?[]const u8 = eff.rcon_password;
        const rcon_port: u16 = eff.rcon_port;
        const gen_workers: ?usize = eff.gen_workers;
        var cfg = asteorite.conn.Config{};
        cfg.motd = eff.motd;
        cfg.max_players = eff.max_players;
        cfg.brand = asteorite.status.Brand.parse(eff.brand) catch |err| {
            try w.print("serve: bad brand '{s}' (want vanilla, fabric, or forge)\n", .{eff.brand});
            try w.flush();
            return err;
        };
        var keys: ?asteorite.rsa.RsaKeyPair = null;
        if (online) {
            const cwd = std.Io.Dir.cwd();
            keys = try asteorite.rsa.ensureKeys(io, arena, cwd, "server_rsa.key", "server_rsa.der");
            cfg.online_mode = true;
            cfg.rsa = &keys.?;
        }
        var srv = try asteorite.server.Server.bindAny(io, port, cfg);
        defer srv.deinit();
        // Seed the runtime command registry once, before any serving
        // thread can take the serving path (lazy ensure covers the rest).
        srv.ensureCommands();
        // OS shutdown signals (SIGINT/SIGTERM/SIGHUP/SIGQUIT, Windows
        // console events) set an atomic flag; the ticker loop turns it
        // into finishStop() (same save+flush+exit as /stop). Installed
        // before pregen so a signal during boot still shuts down cleanly.
        asteorite.shutdown.install();
        srv.view_distance = view_distance;
        // Phase B: transport selection + tuning.
        srv.transport_kind = asteorite.transport.Kind.parse(eff.transport) orelse .auto;
        srv.transport_opts = .{
            .kind = srv.transport_kind,
            .send_zc_threshold = eff.send_zc_threshold,
            .out_cap_bytes = eff.out_cap_bytes,
            .tcp_nodelay = eff.tcp_nodelay,
            .send_buf_bytes = eff.sndbuf,
            .recv_buf_bytes = eff.rcvbuf,
            .workers = eff.transport_workers,
        };
        // The per-connection outbox cap travels with the conn config.
        srv.config.out_cap_bytes = eff.out_cap_bytes;
        // Flood-gate budgets travel the same way (conn template + server).
        srv.config.place_window_ms = eff.place_rate_window_ms;
        srv.config.place_burst = eff.place_rate_burst;
        srv.login_rate_window_ms = eff.login_rate_window_ms;
        srv.login_rate_burst = eff.login_rate_burst;
        // Phase C: region tick threads (0 = auto).
        srv.region_threads = eff.region_threads;
        if (seed) |s| srv.drop_seed = s;
        // Long-lived mutable state (LSM memtable/SSTs, gen tables, conn
        // buffers, registry) must NOT sit on the process arena: free is a
        // no-op there, so every login burst / flush / compaction leaks
        // until the box OOM-freezes. A thread-safe GPA reclaims it all
        // (serve + ticker threads share conns; store is cross-thread too).
        var store_gpa = std.heap.DebugAllocator(.{ .thread_safe = true }){};
        const salloc = store_gpa.allocator();
        var db_dir: ?std.Io.Dir = null;
        defer if (db_dir) |*d| d.close(io);
        var pool: ?*asteorite.shard.ShardPool = null;
        if (db_path) |p| {
            db_dir = try std.Io.Dir.cwd().createDirPathOpen(io, p, .{});
            // Storage profile: SST sizing, compaction cadence, and the
            // io_uring SST read path (nvme). `auto` detects rotational
            // storage on Linux, else keeps today's defaults.
            const storage = asteorite.storage_profile.resolve(io, p, asteorite.storage_profile.Profile.parse(eff.storage_profile) orelse .auto);
            pool = try asteorite.shard.ShardPool.open(salloc, io, db_dir.?, 4, storage.opts);
            srv.world = pool;
            srv.storage_profile_name = storage.profile.name();
            try w.print("storage: profile {s} (SST flush {d} KiB, compact at {d} runs, uring_io={any})\n", .{
                storage.profile.name(),
                storage.opts.flush_threshold_bytes / 1024,
                storage.opts.compact_threshold_ssts,
                storage.opts.use_uring_io,
            });
        }
        defer if (pool) |pl| pl.deinit();
        // Worldgen (needs the pool): a "seed" in the config file enables
        // on-demand fill, and --gen-spawn N pre-generates a spiral disk of
        // radius N on boot.
        var gen: ?asteorite.v5gen.Gen = null;
        defer if (gen) |*g| g.deinit();
        if (seed) |s| {
            if (db_path == null) return error.GenNeedsDb;
            gen = try asteorite.v5gen.Gen.init(salloc, s, false, false);
            srv.gen = &gen.?;
            srv.gen_src = .{ .pool = pool.?, .gen = &gen.?, .lock = &srv.world_lock };
            // Background gen workers: misses enqueue + serve holes instead
            // of blocking the serve thread (~105ms/chunk sync). Each worker
            // owns a private Gen (chain state isn't shareable); default to
            // core count, capped until contention is measured (H5). The pool
            // sheds load past its queue cap instead of growing memory.
            const cpus = std.Thread.getCpuCount() catch 4;
            const n_workers = @min(@max(gen_workers orelse cpus, 1), 8);
            const gp = try asteorite.v5genpool.GenPool.create(salloc, io, pool.?, &srv.world_lock, s, false, false, n_workers);
            srv.gen_pool = gp;
            srv.gen_src.?.gen_pool = gp;
            try w.print("gen: {d} background workers\n", .{n_workers});
        } else if (gen_spawn != null) {
            try w.print("serve: --gen-spawn needs \"seed\" in the config file\n", .{});
            try w.flush();
            return error.GenSpawnNeedsSeed;
        }
        defer if (srv.gen_pool) |gp| {
            gp.destroy();
            salloc.destroy(gp);
        };
        if (gen_spawn) |r| {
            const t0 = std.Io.Timestamp.now(io, .awake);
            const n = try asteorite.v5serve.preGen(pool.?, &gen.?, &srv.world_lock, salloc, r, srv.gen_pool);
            const ms = @divFloor(t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds, 1000000);
            try w.print("gen: pre-generated {d} chunks around spawn in {d} ms\n", .{ n, ms });
        }
        // Permissions: load the matrix, then apply --op bootstraps (level 4,
        // persisted immediately so restarts keep them without the flag).
        // No --op and no stored ops: secure default, console-only admin.
        srv.gpa = salloc;
        srv.loadPerms();
        for (ops.items) |name| {
            if (!asteorite.conn.Conn.validPlayerName(name)) {
                try w.print("ignoring --op {s}: bad player name\n", .{name});
                continue;
            }
            srv.grantOp(name);
        }
        // Operator console (stdin): full TUI with scrollback, history, colors.
        var console_inst = console_tui.Console.init(salloc, io);
        defer console_inst.deinit();
        console_tui.setGlobal(&console_inst);

        {
            srv.perm_lock.lock();
            const n = if (srv.perms) |*db| db.countOps() else 0;
            srv.perm_lock.unlock();
            if (n == 0) console_inst.logf(.info, "perms: no ops stored (console only). use --op <name> to bootstrap.", .{});
        }
        
        // Log startup message through TUI
        var startup_buf: [256]u8 = undefined;
        const startup_msg = std.fmt.bufPrint(&startup_buf, "Asteorite listening on 0.0.0.0:{d} (proto 5, online={}, db={s}, view={d}, seed={?d}, config={s})", .{ port, online, db_path orelse "none", view_distance, seed, cfg_source }) catch "Asteorite listening";
        console_inst.logf(.info, "{s}", .{startup_msg});

        // Set up command callback
        console_inst.setUserData(&srv);
        console_inst.setInputCallback(struct {
            fn handle(console: *console_tui.Console, cmd: []const u8) void {
                const srv_ptr: *asteorite.server.Server = @ptrCast(@alignCast(console.getUserData().?));
                var tmp: [1025]u8 = undefined;
                tmp[0] = '/';
                const n = @min(cmd.len, tmp.len - 1);
                @memcpy(tmp[1..][0..n], cmd[0..n]);
                const full = tmp[0 .. n + 1];
                srv_ptr.handleCommand(null, full);
                if (asteorite.server.Server.isStopCommand(full)) {
                        _ = srv_ptr.saveAllPlayers();
                        srv_ptr.saveRedstone();
                        if (srv_ptr.world) |pl| pl.flushAll() catch {};
                        console.logf(.info, "stop: saved player(s), flushed. bye.", .{});
                        // Drain + render synchronously: we are on the console
                        // thread, and exit() below would drop queued lines.
                        console.flush();
                        // exit() skips runTty's defer: restore the terminal
                        // or the user's shell is left without echo.
                        console_tui.restoreTerminal();
                        std.process.exit(0);
                }
            }
        }.handle);

        // Update status line with server info
        var status_buf: [128]u8 = undefined;
        const status = std.fmt.bufPrint(&status_buf, "Asteorite 1.7.10 | Port: {d} | Online: {s} | DB: {s} | View: {d}", .{
            port,
            if (online) "yes" else "no",
            db_path orelse "none",
            view_distance,
        }) catch "Asteorite";
        console_inst.setStatus(status);

        const console_th = std.Thread.spawn(.{}, console_tui.Console.run, .{ &console_inst }) catch null;
        if (console_th) |th| th.detach();
        // RCON remote console (disabled unless a password is configured).
        // Same command core as chat/console, full console authority.
        if (rcon_password) |pw| {
            if (pw.len == 0) {
                try w.print("rcon: empty --rcon-password ignored (RCON stays disabled).\n", .{});
            } else {
                if (pw.len < 8) try w.print("rcon: WARNING: password is short; use a long random secret.\n", .{});
                const R = struct {
                    fn run(s: *asteorite.server.Server, p: []const u8, rport: u16) void {
                        asteorite.rcon.serve(s.io, s, p, rport) catch |err| {
                            std.log.err("rcon failed to start: {}", .{err});
                        };
                    }
                };
                const rcon_th = std.Thread.spawn(.{}, R.run, .{ &srv, pw, rcon_port }) catch null;
                if (rcon_th) |th| th.detach();
            }
        }
        // Signal during boot (pregen/perms/console setup can take seconds):
        // don't start serving, run the /stop pipeline instead.
        if (asteorite.shutdown.isRequested()) srv.finishStop();
        // serveForever never returns; per-conn + store allocs hang off the
        // GPA above (the process arena never frees — see above).
        try srv.serveForever(salloc);
    }
}

/// Map a CLI parse failure to a process error (message already printed).
/// `.none` with an error means allocation failure (the only path that
/// returns without recording a flag error).
fn perrToError(perr: *const cli.ParseError) anyerror {
    return switch (perr.kind) {
        .none => error.OutOfMemory,
        .unknown_flag => error.UnknownFlag,
        .missing_value => error.MissingValue,
        .bad_value => error.BadValue,
        .unexpected_positional => error.UnexpectedPositional,
    };
}

test {
    _ = @import("cli.zig");
    _ = @import("config.zig");
}
