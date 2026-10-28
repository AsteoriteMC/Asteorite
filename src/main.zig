const std = @import("std");
const asteorite = @import("asteorite");
const cli = @import("cli.zig");
const config = @import("config.zig");
const console_tui = asteorite.console_tui;
const file_log = @import("file_log.zig");

pub const std_options: std.Options = .{
    .logFn = logFn,
};

/// Fan-out log hook: console TUI as before, plus the rolling file log
/// (logs/latest.log; no-op until serve initializes it).
pub fn logFn(    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    console_tui.logFn(level, scope, format, args);
    file_log.append(level, scope, format, args);
}

/// Background gen worker cap (default is core count, clamped here until
/// contention is measured).
pub const max_gen_workers: usize = 8;

/// Boot info line: prints to raw stdout now AND remembers the text for
/// replay into the TUI after it starts (the fullscreen redraw wipes
/// everything printed before TUI init — GPU/storage/gen lines included).
fn bootPrint(
    w: *std.Io.Writer,
    lines: *std.ArrayList([]const u8),
    arena: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try w.print(fmt, args);
    try w.flush();
    const s = try std.fmt.allocPrint(arena, fmt, args);
    // The TUI adds its own line ending; don't carry stdout's over.
    try lines.append(arena, std.mem.trimEnd(u8, s, "\n"));
}

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
        // Config file: explicit --config (must exist) or ./asteorite.toml if
        // present. Precedence: defaults < file < CLI flags.
        var eff = config.Effective{};
        // Boot lines printed before the TUI starts (wiped by its redraw):
        // bootPrint() remembers them; replayed into the TUI after init.
        var boot_lines: std.ArrayList([]const u8) = .empty;
        defer boot_lines.deinit(arena);
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
            var fc: config.FileConfig = config.parseToml(arena, text) catch |err| {
                if (err == error.UnknownSection) {
                    try w.print("serve: bad config '{s}': unknown table (want sections:", .{cfg_path});
                    for (config.sections) |s| try w.print(" {s}", .{s});
                    try w.print(" — see asteorite.example.toml)\n", .{});
                    try w.flush();
                    return err;
                }
                if (err == error.UnknownKey) {
                    try w.print("serve: bad config '{s}': unknown key (check spelling against asteorite.example.toml)\n", .{cfg_path});
                    try w.flush();
                    return err;
                }
                try w.print("serve: bad config '{s}' ({s})\n", .{ cfg_path, @errorName(err) });
                try w.flush();
                return err;
            };
            // NOTE: eff borrows the file's strings (db, ops, rcon_password)
            // for the life of the server and the process arena never frees
            // anyway (see above).
            file_seed = fc.resolveSeed() catch |err| {
                try w.print("serve: bad world.seed in '{s}' ({s}: integer or string)\n", .{ cfg_path, @errorName(err) });
                try w.flush();
                return err;
            };
            eff = config.merge(eff, &fc, file_seed);
            eff.source = .file;
            cfg_source = cfg_path;
        }
        // Pre-CLI snapshot for first-boot file creation below: one-shot
        // flags must stay ephemeral, never baked into the persisted file.
        var base = eff;
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
        if (parsed.gpu) |v| eff.gpu = v;
        if (parsed.gpu_budget_ms) |v| eff.gpu_budget_ms = v;
        if (parsed.gpu_max_batch) |v| eff.gpu_max_batch = v;
        if (parsed.gpu_device) |v| eff.gpu_device = v;
        config.validate(&eff) catch |err| {
            try w.print("serve: {s}\n", .{config.validateMessage(err)});
            try w.flush();
            return err;
        };
        // Gameplay defaults from the config file (validated above, so the
        // parses cannot fail — fallbacks keep the previous hardcoded boot).
        // The difficulty also seeds the conn template so JoinGame carries
        // it (vanilla has no post-login difficulty sync; the gamemode keeps
        // its bootstrap-creative + S2B-patch flow, whose client chat line
        // is vanilla-standard).
        const default_gamemode = asteorite.rules.GameMode.parse(eff.gamemode) orelse .creative;
        const default_difficulty = asteorite.rules.Difficulty.parse(eff.difficulty) orelse .easy;
        // Rolling file log (logs/latest.log, previous session xz-compressed).
        // Console-only if this fails — logging must never block boot.
        // xz is NOT bundled: Linux usually ships it, macOS needs
        // `brew install xz`, Windows needs MSYS2/Git-Bash xz on PATH.
        const xz_hint = comptime switch (@import("builtin").os.tag) {
            .linux => "xz missing? (apt/dnf/pacman install xz)",
            .macos => "xz missing? (brew install xz)",
            .windows => "xz missing? (MSYS2: pacman -S xz, or Git for Windows) and ensure it is on PATH",
            else => "xz missing? install xz and ensure it is on PATH",
        };
        var log_dir: ?std.Io.Dir = null;
        defer if (log_dir) |*d| d.close(io);
        var log_file_ok = false;
        {
            std.Io.Dir.cwd().createDir(io, "logs", .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => {
                    try w.print("serve: file logging disabled ({s})\n", .{@errorName(err)});
                    try w.flush();
                },
            };
            if (std.Io.Dir.cwd().openDir(io, "logs", .{ .iterate = true }) catch null) |d| {
                log_dir = d;
                if (file_log.init(io, d)) {
                    log_file_ok = true;
                    if (file_log.rotationFailed()) {
                        try w.print("serve: log rotation failed ({s}) — appending to existing logs/latest.log\n", .{xz_hint});
                        try w.flush();
                    }
                } else |err| {
                    try w.print("serve: file logging disabled ({s})\n", .{@errorName(err)});
                    try w.flush();
                }
            }
        }
        defer file_log.deinit();
        if (log_file_ok) {
            try w.print("logs: persisting to logs/latest.log\n", .{});
            try w.flush();
        }
        const port: u16 = eff.port;
        const online = eff.online;
        const db_path: ?[]const u8 = eff.db;
        const view_distance: u8 = eff.view_distance;
        // Vanilla parity: no seed configured => random seed + loud log.
        // A missing seed used to disable worldgen entirely (fresh joins got
        // zero chunks and fell in the void). Vanilla picks a random seed and
        // tells you; we do the same. The seed persists via the auto-created
        // config file below, so restarts keep the same world.
        var seed: ?i64 = eff.seed;
        if (seed == null and db_path != null) {
            var sb: [8]u8 = undefined;
            io.random(&sb);
            const s = std.mem.readInt(i64, &sb, .little);
            seed = s;
            eff.seed = s;
            try bootPrint(w, &boot_lines, arena, "serve: no \"seed\" configured — using random seed {d}\n", .{s});
        }
        // First boot on the default path (no file existed): persist the
        // effective config — defaults plus the generated seed — so restarts
        // keep the same world and the user gets a documented file to edit.
        // Explicit --config paths are never auto-created (a missing one is
        // a user typo — still a hard error above). Exclusive create wins
        // the race against a parallel boot; any other failure warns and
        // the server keeps booting (a config file is a nicety, not boot).
        if (cfg_text == null) {
            base.seed = eff.seed;
            const rendered = config.renderDefaults(arena, &base) catch null;
            if (rendered) |bytes| {
                const created: ?std.Io.File = cfg_dir.createFile(io, cfg_path, .{ .exclusive = true }) catch |err| blk: {
                    if (err != error.PathAlreadyExists) {
                        try w.print("serve: note: could not create default config '{s}' ({s}) — continuing without it\n", .{ cfg_path, @errorName(err) });
                        try w.flush();
                    }
                    break :blk null;
                };
                if (created) |*f| {
                    defer f.close(io);
                    f.writePositionalAll(io, bytes, 0) catch {};
                    f.sync(io) catch {};
                    try bootPrint(w, &boot_lines, arena, "serve: created default config '{s}' (edit it to tune the server)\n", .{cfg_path});
                }
            }
        } else if (file_seed == null and seed != null) {
            // Existing file, but seedless: we must not clobber it, so the
            // random seed above stays in-memory-only and the world changes
            // on every restart. Say so loudly, every boot.
            try bootPrint(w, &boot_lines, arena, "serve: warning: config '{s}' has no \"seed\" — world changes every restart (add one to keep it)\n", .{cfg_path});
        }
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
        cfg.difficulty = default_difficulty;
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
        var srv = try asteorite.server.Server.bindConfigured(io, eff.bind_address, port, eff.backlog, cfg);
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
        // Default gamemode for first-time logins (config file key
        // "gamemode"; validated above, so the parse cannot fail — the
        // fallback keeps the previous hardcoded default).
        srv.setDefaultGamemode(default_gamemode);
        // World difficulty (config file key "difficulty"; validated above).
        // setDifficulty also refreshes online conns (none yet at boot).
        srv.setDifficulty(default_difficulty);
        // PvP + force-gamemode flags: direct seqlock seeds (no runtime
        // commands own these yet; the values only flow outward to
        // combat/logins from here).
        {
            var c = srv.cfg.load();
            c.pvp = eff.pvp;
            c.force_gamemode = eff.force_gamemode;
            srv.cfg.store(c);
        }
        // Natural-spawn controls (validated above): master switch plus a
        // per-kind allow array (absent kinds stay allowed). canSpawnMob
        // consults both plus the doMobSpawning gamerule at every ingress.
        {
            var allowed = [_]bool{true} ** asteorite.mob.count;
            if (eff.mob_spawns) |m| {
                var it = m.object.iterator();
                while (it.next()) |kv| {
                    if (asteorite.mob.parse(kv.key_ptr.*)) |k| {
                        if (kv.value_ptr.* == .bool) allowed[@intFromEnum(k)] = kv.value_ptr.*.bool;
                    }
                }
            }
            var c = srv.cfg.load();
            c.spawn_mobs = eff.spawn_mobs;
            c.mob_spawn_allowed = allowed;
            srv.cfg.store(c);
        }
        // Idle timeout + autosave seed their runtime owners (/setidletimeout,
        // /save-off//save-on mutate the same state afterwards).
        srv.setIdleTimeout(eff.idle_timeout);
        srv.setAutosave(eff.autosave);
        // Gamerule boot overrides (config "gamerules" object; validated
        // above, so names are known and values are bools — /gamerule
        // mutates the same state afterwards).
        if (eff.gamerules) |g| {
            var it = g.object.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.* == .bool) _ = srv.gameruleSet(kv.key_ptr.*, kv.value_ptr.*.bool);
            }
        }
        // Accepted-but-unimplemented keys: parsed, validated, and stored
        // for forward-compat, with a boot warning pointing at TODO.md.
        // Each fires only when set away from its default.
        if (eff.simulation_distance != 10) {
            try w.print("serve: note: simulation_distance is not implemented yet (ticking follows view distance; see TODO.md) — value stored\n", .{});
            try w.flush();
        }
        if (eff.compression_threshold != -1) {
            try w.print("serve: note: packet compression is not implemented yet (no SetCompression path; see TODO.md) — threshold stored, ignored\n", .{});
            try w.flush();
        }
        if (eff.max_nbt_depth != 32) {
            try w.print("serve: note: max_nbt_depth is not enforced yet (NBT rides opaque, never parsed; see TODO.md) — value stored\n", .{});
            try w.flush();
        }
        if (eff.max_string_length != 32767) {
            try w.print("serve: note: max_string_length is not honored yet (chat buffers are fixed 1024; see TODO.md) — value stored\n", .{});
            try w.flush();
        }
        if (eff.region_cache_size != 256) {
            try w.print("serve: note: region_cache_size sizes nothing (LSM store has no region files; see TODO.md) — value stored\n", .{});
            try w.flush();
        }
        if (eff.disk_flush_interval != 30) {
            try w.print("serve: note: disk_flush_interval is not implemented yet (durability is WAL + autosave; see TODO.md) — value stored\n", .{});
            try w.flush();
        }
        if (eff.wasm_enabled) {
            try w.print("serve: note: wasm plugins are not implemented yet (no runtime; see TODO.md) — plugins stay off\n", .{});
            try w.flush();
        }
        if (eff.telemetry_enabled or eff.telemetry_prometheus) {
            try w.print("serve: note: telemetry/prometheus export is not implemented yet (stats log only; see TODO.md) — values stored\n", .{});
            try w.flush();
        }
        // Phase G: GPU chunk-gen offload. v1 wires the fill stage behind
        // --gpu vulkan (CPU fallback is bit-identical). The budget paces
        // the future async batch scheduler and max_batch caps future
        // multi-chunk dispatches (v1 dispatches 1 per fill) — both parsed,
        // validated, and stored here, warned once.
        if (eff.gpu_budget_ms != 4) {
            try w.print("serve: note: gpu_budget_ms is stored for the async batch scheduler (v1 dispatches synchronously; see TODO.md Phase G)\n", .{});
            try w.flush();
        }
        if (eff.gpu_max_batch != 16) {
            try bootPrint(w, &boot_lines, arena, "serve: note: gpu_max_batch is {d} (clamped to 9..16: one game chunk is 9 columns = one dispatch; 16 is the 128-group RADV-safe ceiling)\n", .{eff.gpu_max_batch});
        }
        if (!std.mem.eql(u8, eff.gpu, "off") and seed == null) {
            try bootPrint(w, &boot_lines, arena, "serve: note: gpu {s} requested but no seed configured — fill offload inactive (GPU needs worldgen)\n", .{eff.gpu});
        }
        // Phase B: transport selection + tuning.
        srv.transport_kind = asteorite.transport.Kind.parse(eff.transport) orelse .auto;
        srv.transport_opts = .{
            .kind = srv.transport_kind,
            .ring_entries = eff.io_uring_entries,
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
        srv.config.chat_window_ms = eff.chat_rate_window_ms;
        srv.config.chat_burst = eff.chat_rate_burst;
        srv.config.dig_window_ms = eff.dig_rate_window_ms;
        srv.config.dig_burst = eff.dig_rate_burst;
        srv.config.max_packets_per_second = eff.max_packets_per_second;
        srv.config.frame_max_len = eff.max_packet_size;
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
            // Bulk-load overrides (pregen): bigger memtable = fewer seals +
            // WAL rotations; higher compact threshold = fewer mutex-held
            // merges. Null keeps the profile default in both cases.
            var storage_opts = storage.opts;
            if (eff.flush_threshold_bytes) |v| storage_opts.flush_threshold_bytes = v;
            if (eff.compact_threshold_ssts) |v| storage_opts.compact_threshold_ssts = v;
            pool = try asteorite.shard.ShardPool.open(salloc, io, db_dir.?, 4, storage_opts);
            srv.world = pool;
            srv.storage_profile_name = storage.profile.name();
            try bootPrint(w, &boot_lines, arena, "storage: profile {s} (SST flush {d} KiB, compact at {d} runs, uring_io={any})\n", .{
                storage.profile.name(),
                storage_opts.flush_threshold_bytes / 1024,
                storage_opts.compact_threshold_ssts,
                storage_opts.use_uring_io,
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
            const n_workers = @min(@max(gen_workers orelse cpus, 1), max_gen_workers);
            // Phase G: GPU fill offload. Disabled (default) or unavailable
            // hardware runs every worker on CPU — identical bytes either way
            // (probe-gated on JVM goldens).
            const gpu_opts = asteorite.gpufill.Options{
                .enabled = std.mem.eql(u8, eff.gpu, "vulkan"),
                .device = asteorite.gpufill.DevicePref.parse(eff.gpu_device) orelse .auto,
                .max_batch = eff.gpu_max_batch,
            };
            const gp = try asteorite.v5genpool.GenPool.create(salloc, io, pool.?, &srv.world_lock, s, false, false, n_workers, gpu_opts);
            srv.gen_pool = gp;
            srv.gen_src.?.gen_pool = gp;
            try bootPrint(w, &boot_lines, arena, "gen: {d} background workers\n", .{n_workers});
            if (gpu_opts.enabled) {
                if (gp.gpu_ctx) |gctx| {
                    try bootPrint(w, &boot_lines, arena, "gpu: fill offload active ({s})\n", .{gctx.description()});
                    // Boot pregen Gen shares the context with one device;
                    // serve-thread fallback (no gen_pool) uses the same Gen.
                    if (asteorite.gpufill.GpuFill.init(gctx, salloc)) |gf| {
                        gen.?.gpu = gf;
                        // Floor at 9 (one game chunk = one dispatch).
                        gen.?.gpu_batch = @min(@max(eff.gpu_max_batch, 9), asteorite.gpufill.batch_cap);
                    }
                } else {
                    try bootPrint(w, &boot_lines, arena, "gpu: requested but unavailable (no driver/device/compute/float64) — CPU fill\n", .{});
                }
            }
            defer if (gen) |*g| {
                // Boot pregen Gen's GPU fill (worker fills die with the pool
                // above; salloc outlives the server).
                if (g.gpu) |gf| {
                    gf.deinit();
                    salloc.destroy(gf);
                    g.gpu = null;
                }
            };
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
            try bootPrint(w, &boot_lines, arena, "gen: pre-generated {d} chunks around spawn in {d} ms\n", .{ n, ms });
        }
        // Permissions: load the matrix, then apply --op bootstraps (level 4,
        // persisted immediately so restarts keep them without the flag).
        // No --op and no stored ops: secure default, console-only admin.
        srv.gpa = salloc;
        srv.loadPerms();
        srv.banLoad();
        srv.whitelistLoad();
        for (ops.items) |name| {
            if (!asteorite.conn.Conn.validPlayerName(name)) {
                try w.print("ignoring --op {s}: bad player name\n", .{name});
                continue;
            }
            // Online mode can't resolve a UUID for an offline name (rows
            // are UUID-bound at grant time, never invented): warn loudly
            // and op them from the console once they're online instead.
            if (!srv.grantOp(name)) {
                try w.print("ignoring --op {s}: UUID unknown while offline (online mode) — /op them once online\n", .{name});
                continue;
            }
        }
        // Operator console (stdin): ZigZag TUI (tabs, scrollback, history,
        // styled log levels, completion) on a background thread.
        var console_inst = console_tui.Console.init(salloc, io);
        defer console_inst.deinit();
        console_inst.setEnvironMap(init.environ_map);
        console_tui.setGlobal(&console_inst);

        {
            srv.perm_lock.lock();
            const n = if (srv.perms) |*db| db.countOps() else 0;
            srv.perm_lock.unlock();
            if (n == 0) console_inst.logf(.info, "perms: no ops stored (console only). use --op <name> to bootstrap.", .{});
        }
        
        // The fullscreen TUI wiped everything printed above: replay the
        // boot lines into it (chronological, before the listening line).
        for (boot_lines.items) |line| console_inst.logf(.info, "{s}", .{line});

        // Log startup message through TUI
        var startup_buf: [256]u8 = undefined;
        const startup_msg = std.fmt.bufPrint(&startup_buf, "Asteorite listening on {s}:{d} (proto 5, online={}, db={s}, view={d}, seed={?d}, config={s})", .{ eff.bind_address, port, online, db_path orelse "none", view_distance, seed, cfg_source }) catch "Asteorite listening";
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
                    srv_ptr.saveForHalt();
                    console.logf(.info, "stop: saved player(s), flushed. bye.", .{});
                    // Unwind the Program cleanly (deinit restores the
                    // terminal); the thread wrapper below exits(0) after
                    // run() returns. No exit() here: it would skip the
                    // restore and strand the terminal in alt-screen.
                    console.flush();
                    console.stop();
                    console.exit_after_stop.store(true, .monotonic);
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

        const C = struct {
            fn run(console: *console_tui.Console) void {
                console.run() catch |err| {
                    std.log.err("console TUI failed: {}", .{err});
                    return;
                };
                // Console-initiated `stop`: the Program already restored the
                // terminal via deinit; exit after the goodbye line renders.
                if (console.exit_after_stop.load(.monotonic)) {
                    console.flush();
                    console_tui.restoreTerminal();
                    std.process.exit(0);
                }
            }
        };
        const console_th = std.Thread.spawn(.{}, C.run, .{&console_inst}) catch null;
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
        // GPA above (the process arena never frees — see above). An error
        // return would exit without the Program's restore defer, so put
        // the terminal back first (same as every /stop path).
        srv.serveForever(salloc) catch |err| {
            console_tui.restoreTerminal();
            return err;
        };
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
