//! Command-line parser for `asteorite serve`.
//!
//! Hand-rolled (no dependency): zig-clap's 0.16-compatible tags don't
//! compile on 0.16 (`@Type`, `mem.trimLeft` removals) and its master needs
//! 0.17, so a small tailored parser wins over version roulette. It also
//! speaks 0.16's `std.process.Init` arg style, which clap predates.
//!
//! Supported forms per flag: `--flag value`, `--flag=value`. Booleans also
//! accept `--flag[=true|false|1|0|yes|no|on|off]` and `--no-<flag>`.
//! `--op` repeats. The first positional sets the port; `--` ends flag
//! parsing; `-h`/`--help` prints help; `-c`/`--config` selects the JSON
//! config file (see config.zig). Anything else is reported precisely.

const std = @import("std");
const config = @import("config.zig");
// Shared via the asteorite module (this file lives in main's root module,
// so it must not import cmd/ files by path — that would claim them into
// two modules).
const spec_mod = @import("asteorite").cmdspec;

/// Profile metadata needed by top-level CLI output. Kept as a value so the
/// parser does not import the selected profile or `build_options` itself.
pub const VersionInfo = struct {
    name: []const u8,
    protocol: i32,
    profile_id: []const u8,
};

/// `asteorite --version` / `asteorite version`.
pub fn printVersion(w: *std.Io.Writer, info: VersionInfo) !void {
    try w.print("Asteorite {s} (protocol {d}, profile {s})\n", .{
        info.name,
        info.protocol,
        info.profile_id,
    });
}

/// Parsed `serve` arguments. Every option is optional: null means "not
/// given", so config-file values and defaults fill in underneath.
pub const ServeArgs = struct {
    port: ?u16 = null,
    online: ?bool = null,
    db: ?[]const u8 = null,
    view_distance: ?u8 = null,
    gen_spawn: ?i32 = null,
    gen_workers: ?usize = null,
    ops: std.ArrayList([]const u8) = .empty,
    rcon_password: ?[]const u8 = null,
    rcon_port: ?u16 = null,
    motd: ?[]const u8 = null,
    max_players: ?u16 = null,
    brand: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    /// Phase B: transport backend (auto|uring|kqueue|iocp|blocking).
    transport: ?[]const u8 = null,
    /// Storage profile (auto|hdd|ssd|nvme): SST sizing, compaction
    /// cadence, and the io_uring SST read path (nvme).
    storage_profile: ?[]const u8 = null,
    /// Phase B: io_uring worker threads (0 = auto).
    transport_workers: ?usize = null,
    /// Phase C: region tick threads (0 = auto = cpus max 8; 1 = sequential).
    region_threads: ?usize = null,
    /// Phase B: per-connection outbox cap in bytes (backpressure).
    out_cap_bytes: ?usize = null,
    /// Phase B: zerocopy send threshold in bytes.
    send_zc_threshold: ?usize = null,
    /// Phase B: TCP_NODELAY on accepted sockets.
    tcp_nodelay: ?bool = null,
    /// Phase B: SO_SNDBUF / SO_RCVBUF (0 = OS default).
    sndbuf: ?usize = null,
    rcvbuf: ?usize = null,
    /// Login flood budget: joins allowed per window per IP.
    login_rate_window_ms: ?i64 = null,
    login_rate_burst: ?usize = null,
    /// Placement flood budget: placements allowed per window per conn.
    place_rate_window_ms: ?i64 = null,
    place_rate_burst: ?usize = null,
    /// Phase G: GPU offload backend (off|vulkan).
    gpu: ?[]const u8 = null,
    /// Phase G: per-tick GPU dispatch budget, milliseconds.
    gpu_budget_ms: ?u32 = null,
    /// Phase G: max chunks per GPU dispatch.
    gpu_max_batch: ?usize = null,
    /// Phase G: GPU device preference (auto|discrete|integrated|cpu).
    gpu_device: ?[]const u8 = null,
    help: bool = false,
};

pub const ParseError = struct {
    kind: Kind = .none,
    /// Flag involved ("--db", "--no-online", "<positional>", ...).
    flag: []const u8 = "",
    /// Offending value ("" when missing).
    value: []const u8 = "",

    pub const Kind = enum {
        none,
        unknown_flag,
        missing_value,
        bad_value,
        unexpected_positional,
    };
};

pub const Error = error{
    UnknownFlag,
    MissingValue,
    BadValue,
    UnexpectedPositional,
    OutOfMemory,
};

fn fail(err: *ParseError, kind: ParseError.Kind, flag: []const u8, value: []const u8, zig_err: Error) Error {
    err.kind = kind;
    err.flag = flag;
    err.value = value;
    return zig_err;
}

/// One-line message for a parse failure ("serve: ...").
pub fn message(err: *const ParseError, buf: []u8) []u8 {
    return switch (err.kind) {
        .none => std.fmt.bufPrint(buf, "serve: no error", .{}) catch buf[0..0],
        .unknown_flag => std.fmt.bufPrint(buf, "serve: unknown flag '{s}' (try 'serve --help')", .{err.flag}) catch buf[0..0],
        .missing_value => std.fmt.bufPrint(buf, "serve: flag '{s}' needs a value", .{err.flag}) catch buf[0..0],
        .bad_value => std.fmt.bufPrint(buf, "serve: bad value '{s}' for '{s}'", .{ err.value, err.flag }) catch buf[0..0],
        .unexpected_positional => std.fmt.bufPrint(buf, "serve: unexpected argument '{s}' (only [port] is positional)", .{err.value}) catch buf[0..0],
    };
}

/// Flag value: `--flag=value` or the next argv element (missing → fail).
fn flagValue(argv: []const []const u8, i: *usize, inline_val: ?[]const u8, flag: []const u8, err: *ParseError) Error![]const u8 {
    if (inline_val) |v| return v;
    i.* += 1;
    if (i.* >= argv.len) return fail(err, .missing_value, flag, "", error.MissingValue);
    return argv[i.*];
}

/// Typed flag value (parse failure → fail).
fn flagInt(comptime T: type, argv: []const []const u8, i: *usize, inline_val: ?[]const u8, flag: []const u8, err: *ParseError) Error!T {
    const v = try flagValue(argv, i, inline_val, flag, err);
    return std.fmt.parseInt(T, v, 10) catch return fail(err, .bad_value, flag, v, error.BadValue);
}

/// Optional-inline bool flag (`--flag[=bool]`; bare means true).
fn flagBool(inline_val: ?[]const u8, flag: []const u8, err: *ParseError) Error!bool {
    const v = inline_val orelse return true;
    return spec_mod.parseBool(v) orelse return fail(err, .bad_value, flag, v, error.BadValue);
}

/// Bare-only negating flag (`--no-foo` takes no value).
fn flagBare(inline_val: ?[]const u8, flag: []const u8, err: *ParseError) Error!void {
    if (inline_val != null) return fail(err, .bad_value, flag, inline_val.?, error.BadValue);
}

/// Parse `argv` (WITHOUT argv[0]/subcommand: just the flags). `arena`
/// backs `ops` entries (slices alias argv, no copy).
pub fn parseServe(arena: std.mem.Allocator, argv: []const []const u8, err: *ParseError) Error!ServeArgs {
    var out = ServeArgs{};
    err.* = .{};
    var i: usize = 0;
    var positional: usize = 0;
    var no_more_flags = false;
    while (i < argv.len) : (i += 1) {
        const tok = argv[i];
        if (!no_more_flags and std.mem.eql(u8, tok, "--")) {
            no_more_flags = true;
            continue;
        }
        if (!no_more_flags and tok.len >= 2 and tok[0] == '-' and tok[1] == '-') {
            // Long flag, maybe --flag=value.
            var name = tok;
            var inline_val: ?[]const u8 = null;
            if (std.mem.indexOfScalar(u8, tok, '=')) |eq| {
                name = tok[0..eq];
                inline_val = tok[eq + 1 ..];
            }
            if (std.mem.eql(u8, name, "--help")) {
                out.help = true;
                continue;
            } else if (std.mem.eql(u8, name, "--config")) {
                const v = try flagValue(argv, &i, inline_val, "--config", err);
                out.config_path = v;
                continue;
            } else if (std.mem.eql(u8, name, "--online")) {
                out.online = try flagBool(inline_val, "--online", err);
                continue;
            } else if (std.mem.eql(u8, name, "--no-online")) {
                try flagBare(inline_val, "--no-online", err);
                out.online = false;
                continue;
            } else if (std.mem.eql(u8, name, "--db")) {
                const v = try flagValue(argv, &i, inline_val, "--db", err);
                out.db = v;
                continue;
            } else if (std.mem.eql(u8, name, "--view")) {
                out.view_distance = try flagInt(u8, argv, &i, inline_val, "--view", err);
                continue;
            } else if (std.mem.eql(u8, name, "--gen-spawn")) {
                out.gen_spawn = try flagInt(i32, argv, &i, inline_val, "--gen-spawn", err);
                continue;
            } else if (std.mem.eql(u8, name, "--gen-workers")) {
                out.gen_workers = try flagInt(usize, argv, &i, inline_val, "--gen-workers", err);
                continue;
            } else if (std.mem.eql(u8, name, "--op")) {
                const v = try flagValue(argv, &i, inline_val, "--op", err);
                try out.ops.append(arena, v);
                continue;
            } else if (std.mem.eql(u8, name, "--rcon-password")) {
                const v = try flagValue(argv, &i, inline_val, "--rcon-password", err);
                out.rcon_password = v;
                continue;
            } else if (std.mem.eql(u8, name, "--rcon-port")) {
                out.rcon_port = try flagInt(u16, argv, &i, inline_val, "--rcon-port", err);
                continue;
            } else if (std.mem.eql(u8, name, "--motd")) {
                const v = try flagValue(argv, &i, inline_val, "--motd", err);
                out.motd = v;
                continue;
            } else if (std.mem.eql(u8, name, "--max-players")) {
                out.max_players = try flagInt(u16, argv, &i, inline_val, "--max-players", err);
                continue;
            } else if (std.mem.eql(u8, name, "--brand")) {
                const v = try flagValue(argv, &i, inline_val, "--brand", err);
                if (!config.isKnownBrand(v)) return fail(err, .bad_value, "--brand", v, error.BadValue);
                out.brand = v;
                continue;
            } else if (std.mem.eql(u8, name, "--transport")) {
                const v = try flagValue(argv, &i, inline_val, "--transport", err);
                out.transport = v;
                continue;
            } else if (std.mem.eql(u8, name, "--storage-profile")) {
                const v = try flagValue(argv, &i, inline_val, "--storage-profile", err);
                out.storage_profile = v;
                continue;
            } else if (std.mem.eql(u8, name, "--transport-workers")) {
                out.transport_workers = try flagInt(usize, argv, &i, inline_val, "--transport-workers", err);
                continue;
            } else if (std.mem.eql(u8, name, "--region-threads")) {
                out.region_threads = try flagInt(usize, argv, &i, inline_val, "--region-threads", err);
                continue;
            } else if (std.mem.eql(u8, name, "--out-cap")) {
                out.out_cap_bytes = try flagInt(usize, argv, &i, inline_val, "--out-cap", err);
                continue;
            } else if (std.mem.eql(u8, name, "--send-zc-threshold")) {
                out.send_zc_threshold = try flagInt(usize, argv, &i, inline_val, "--send-zc-threshold", err);
                continue;
            } else if (std.mem.eql(u8, name, "--tcp-nodelay")) {
                out.tcp_nodelay = try flagBool(inline_val, "--tcp-nodelay", err);
                continue;
            } else if (std.mem.eql(u8, name, "--no-tcp-nodelay")) {
                try flagBare(inline_val, "--no-tcp-nodelay", err);
                out.tcp_nodelay = false;
                continue;
            } else if (std.mem.eql(u8, name, "--sndbuf")) {
                out.sndbuf = try flagInt(usize, argv, &i, inline_val, "--sndbuf", err);
                continue;
            } else if (std.mem.eql(u8, name, "--rcvbuf")) {
                out.rcvbuf = try flagInt(usize, argv, &i, inline_val, "--rcvbuf", err);
                continue;
            } else if (std.mem.eql(u8, name, "--login-rate-window-ms")) {
                out.login_rate_window_ms = try flagInt(i64, argv, &i, inline_val, "--login-rate-window-ms", err);
                continue;
            } else if (std.mem.eql(u8, name, "--login-rate-burst")) {
                out.login_rate_burst = try flagInt(usize, argv, &i, inline_val, "--login-rate-burst", err);
                continue;
            } else if (std.mem.eql(u8, name, "--place-rate-window-ms")) {
                out.place_rate_window_ms = try flagInt(i64, argv, &i, inline_val, "--place-rate-window-ms", err);
                continue;
            } else if (std.mem.eql(u8, name, "--place-rate-burst")) {
                out.place_rate_burst = try flagInt(usize, argv, &i, inline_val, "--place-rate-burst", err);
                continue;
            } else if (std.mem.eql(u8, name, "--gpu")) {
                const v = try flagValue(argv, &i, inline_val, "--gpu", err);
                out.gpu = v;
                continue;
            } else if (std.mem.eql(u8, name, "--gpu-budget-ms")) {
                out.gpu_budget_ms = try flagInt(u32, argv, &i, inline_val, "--gpu-budget-ms", err);
                continue;
            } else if (std.mem.eql(u8, name, "--gpu-max-batch")) {
                out.gpu_max_batch = try flagInt(usize, argv, &i, inline_val, "--gpu-max-batch", err);
                continue;
            } else if (std.mem.eql(u8, name, "--gpu-device")) {
                const v = try flagValue(argv, &i, inline_val, "--gpu-device", err);
                out.gpu_device = v;
                continue;
            }
            return fail(err, .unknown_flag, name, "", error.UnknownFlag);
        }
        if (!no_more_flags and tok.len == 2 and tok[0] == '-' and tok[1] != '-') {
            if (tok[1] == 'h') {
                out.help = true;
                continue;
            } else if (tok[1] == 'c') {
                i += 1;
                if (i >= argv.len) return fail(err, .missing_value, "-c", "", error.MissingValue);
                out.config_path = argv[i];
                continue;
            }
            return fail(err, .unknown_flag, tok, "", error.UnknownFlag);
        }
        // Positional: only [port].
        if (positional == 0) {
            out.port = std.fmt.parseInt(u16, tok, 10) catch return fail(err, .bad_value, "<port>", tok, error.BadValue);
            positional += 1;
        } else {
            return fail(err, .unexpected_positional, "<positional>", tok, error.UnexpectedPositional);
        }
    }
    return out;
}

/// Full `serve` help (flags, config file, seeds, examples).
pub fn printServeHelp(w: *std.Io.Writer) !void {
    try w.print(
        \\usage: asteorite serve [port] [options]
        \\
        \\options:
        \\  [port]                 listen port (default 25565)
        \\  --online               Mojang auth on (persists RSA keys locally)
        \\  --no-online            force offline mode (overrides config file)
        \\  --db <path>            LSM world database directory
        \\  --view <1..16>         view distance (default 4; 1.7.10 caps at 16)
        \\  --gen-spawn <r>        pre-generate spawn disk of radius r on boot
        \\  --gen-workers <n>      background gen workers (default: cpus, max 8)
        \\  --op <name>            grant op (repeatable; persisted in ops.json)
        \\  --rcon-password <pw>   enable RCON with this password
        \\  --rcon-port <port>     RCON port (default 25575)
        \\  --motd <text>          server list message (default "Asteorite")
        \\  --max-players <n>      server list player cap (default 20)
        \\  --brand <name>         handshake brand: vanilla, fabric, or forge
        \\                         (forge adds the FML modinfo block; the mod
        \\                         list stays empty until the modding API)
        \\  --transport <kind>     network transport: auto, uring, kqueue,
        \\                         iocp, or blocking (default auto)
        \\  --storage-profile <p>  storage profile: auto, hdd, ssd, nvme
        \\                         (default auto; nvme = io_uring SST reads)
        \\  --transport-workers <n>  io_uring worker threads (default: cpus, max 8)
        \\  --region-threads <n>  region tick threads (default: cpus, max 8;
        \\                         1 = sequential legacy path)
        \\  --out-cap <bytes>      per-connection outbox cap (default 4 MiB;
        \\                         a slow consumer past this is kicked)
        \\  --send-zc-threshold <bytes>  zerocopy send threshold (default 8192)
        \\  --tcp-nodelay / --no-tcp-nodelay  TCP_NODELAY on accepted sockets
        \\  --sndbuf <bytes>       SO_SNDBUF on accepted sockets (0 = default)
        \\  --rcvbuf <bytes>       SO_RCVBUF on accepted sockets (0 = default)
        \\  --login-rate-window-ms <ms>  login flood window per IP
        \\  --login-rate-burst <n>  logins allowed per window per IP
        \\  --place-rate-window-ms <ms>  placement flood window per conn
        \\  --place-rate-burst <n>  placements allowed per window per conn
        \\  --gpu <backend>      GPU chunk-gen offload: off or vulkan
        \\                         (default off; CPU fill is bit-identical)
        \\  --gpu-budget-ms <ms>  per-tick GPU dispatch budget (default 4;
        \\                         stored for the async scheduler)
        \\  --gpu-max-batch <n>  max chunks per GPU dispatch, 1..64
        \\                         (default 16; v1 dispatches 1 per fill)
        \\  --gpu-device <kind>  GPU pick: auto, discrete, integrated, cpu
        \\                         (default auto; cpu = CPU-type test device)
        \\  -c, --config <path>    TOML config file (default ./asteorite.toml
        \\                         if present; CLI flags override file keys)
        \\  -h, --help             this help
        \\
        \\config file (TOML, all sections/keys optional):
        \\  [server]
        \\  port = 25565
        \\  online = false
        \\  db = "world"
        \\  view_distance = 8
        \\  ops = ["alice"]
        \\  motd = "Asteorite"
        \\  max_players = 20
        \\  brand = "vanilla"  # vanilla, fabric, forge (fml accepted)
        \\  [world]
        \\  seed = 42  # int64 or string ("Notch" hashes Java-style)
        \\  gen_spawn = 4
        \\  gen_workers = 4
        \\  gamemode = "survival"  # survival, creative, adventure
        \\  difficulty = "normal"  # peaceful, easy, normal, hard
        \\  pvp = true
        \\  idle_timeout = 0
        \\  autosave = true
        \\  gamerules = {{ keepInventory = true }}
        \\  mob_spawns = {{ zombie = false }}
        \\  [network]
        \\  bind_address = "0.0.0.0"
        \\  transport = "auto"  # auto, uring, kqueue, iocp, blocking
        \\  [storage]
        \\  storage_profile = "auto"
        \\  [rates]  # flood budgets: windows ms, bursts per window
        \\  [telemetry]
        \\  [wasm]
        \\  [gpu]
        \\  gpu = "off"  # off, vulkan
        \\  there is no --seed flag: set world.seed in the config file.
        \\  precedence: built-in defaults < config file < CLI flags.
        \\
        \\examples:
        \\  asteorite serve --db world --view 8
        \\  asteorite serve 25566 --config myserver.toml --op alice
        \\  asteorite serve --brand forge --motd "modded-ish" --max-players 50
        \\  # world seed lives in the config file, e.g. [world] seed = 42
        \\
    , .{});
    // Flood-gate defaults come from the config defaults (single source;
    // the flag lines above stay static like the rest of this text).
    try w.print("  (flood-gate defaults: login {d}ms/{d}, place {d}ms/{d})\n", .{
        (config.Effective{}).login_rate_window_ms,
        (config.Effective{}).login_rate_burst,
        (config.Effective{}).place_rate_window_ms,
        (config.Effective{}).place_rate_burst,
    });
}

/// Top-level help (no/unknown subcommand).
pub fn printTopHelp(w: *std.Io.Writer, info: VersionInfo) !void {
    try w.print(
        \\Asteorite {s} (proto v{d}) server + tools.
        \\
        \\usage: asteorite <subcommand> [options]
        \\
        \\subcommands:
        \\  serve    run the server (see 'asteorite serve --help')
        \\  version  print the selected profile (also --version)
        \\  help     this help
        \\
        \\tools (separate binaries): zig build dump|import|wgen|genlayer|check|player-import|player-dump
        \\
    , .{ info.name, info.protocol });
}

test "parse: long flags with space and =" {
    const alloc = std.testing.allocator;
    var err = ParseError{};
    var a = try parseServe(alloc, &.{ "--db", "zc-db", "--view", "8", "25566" }, &err);
    defer a.ops.deinit(alloc);
    try std.testing.expectEqual(@as(?[]const u8, "zc-db"), a.db);
    try std.testing.expectEqual(@as(?u8, 8), a.view_distance);
    try std.testing.expectEqual(@as(?u16, 25566), a.port);
    try std.testing.expectEqual(ParseError.Kind.none, err.kind);
}

test "parse: seed is config-only (no --seed flag)" {
    const alloc = std.testing.allocator;
    var err = ParseError{};
    try std.testing.expectError(error.UnknownFlag, parseServe(alloc, &.{"--seed=42"}, &err));
    try std.testing.expectEqual(ParseError.Kind.unknown_flag, err.kind);
    try std.testing.expectEqualStrings("--seed", err.flag);
}

test "parse: bools, negation, repeatable ops, -c/-h, -- terminator" {
    const alloc = std.testing.allocator;
    var err = ParseError{};
    var a = try parseServe(alloc, &.{ "--online", "--op", "alice", "--op=bob", "--no-online" }, &err);
    defer a.ops.deinit(alloc);
    try std.testing.expectEqual(@as(?bool, false), a.online);
    try std.testing.expectEqual(@as(usize, 2), a.ops.items.len);

    var err2 = ParseError{};
    var b = try parseServe(alloc, &.{ "-c", "x.json", "-h" }, &err2);
    defer b.ops.deinit(alloc);
    try std.testing.expectEqualStrings("x.json", b.config_path.?);
    try std.testing.expect(b.help);

    var err3 = ParseError{};
    try std.testing.expectError(error.BadValue, parseServe(alloc, &.{ "--", "--bogus" }, &err3));
    // "--bogus" after -- is positional -> bad port value, not a flag.
    try std.testing.expectEqual(ParseError.Kind.bad_value, err3.kind);
    try std.testing.expectEqualStrings("<port>", err3.flag);
}

test "parse: rate-limit flags" {
    const alloc = std.testing.allocator;
    var err = ParseError{};
    var a = try parseServe(alloc, &.{ "--login-rate-window-ms", "5000", "--login-rate-burst=3", "--place-rate-window-ms", "2000", "--place-rate-burst=16" }, &err);
    defer a.ops.deinit(alloc);
    try std.testing.expectEqual(@as(?i64, 5000), a.login_rate_window_ms);
    try std.testing.expectEqual(@as(?usize, 3), a.login_rate_burst);
    try std.testing.expectEqual(@as(?i64, 2000), a.place_rate_window_ms);
    try std.testing.expectEqual(@as(?usize, 16), a.place_rate_burst);
    try std.testing.expectError(error.BadValue, parseServe(alloc, &.{"--login-rate-burst=abc"}, &err));
    try std.testing.expectEqualStrings("--login-rate-burst", err.flag);
}

test "parse: gpu flags" {
    const alloc = std.testing.allocator;
    var err = ParseError{};
    var a = try parseServe(alloc, &.{ "--gpu", "vulkan", "--gpu-budget-ms=8", "--gpu-max-batch", "32", "--gpu-device=discrete" }, &err);
    defer a.ops.deinit(alloc);
    try std.testing.expectEqualStrings("vulkan", a.gpu.?);
    try std.testing.expectEqual(@as(?u32, 8), a.gpu_budget_ms);
    try std.testing.expectEqual(@as(?usize, 32), a.gpu_max_batch);
    try std.testing.expectEqualStrings("discrete", a.gpu_device.?);
    try std.testing.expectError(error.BadValue, parseServe(alloc, &.{"--gpu-max-batch=abc"}, &err));
    try std.testing.expectEqualStrings("--gpu-max-batch", err.flag);
}

test "parse: motd/max-players/brand" {
    const alloc = std.testing.allocator;
    var err = ParseError{};
    var a = try parseServe(alloc, &.{ "--motd", "hi there", "--max-players=50", "--brand", "forge" }, &err);
    defer a.ops.deinit(alloc);
    try std.testing.expectEqualStrings("hi there", a.motd.?);
    try std.testing.expectEqual(@as(?u16, 50), a.max_players);
    try std.testing.expectEqualStrings("forge", a.brand.?);
    try std.testing.expectError(error.BadValue, parseServe(alloc, &.{"--brand=spigot"}, &err));
    try std.testing.expectEqualStrings("--brand", err.flag);
}

test "parse: errors carry flag and value" {
    const alloc = std.testing.allocator;
    var err = ParseError{};
    try std.testing.expectError(error.UnknownFlag, parseServe(alloc, &.{"--frobnicate"}, &err));
    try std.testing.expectEqual(ParseError.Kind.unknown_flag, err.kind);
    try std.testing.expectError(error.MissingValue, parseServe(alloc, &.{"--db"}, &err));
    try std.testing.expectEqual(ParseError.Kind.missing_value, err.kind);
    try std.testing.expectEqualStrings("--db", err.flag);
    try std.testing.expectError(error.BadValue, parseServe(alloc, &.{ "--view", "abc" }, &err));
    try std.testing.expectEqualStrings("--view", err.flag);
    try std.testing.expectEqualStrings("abc", err.value);
    try std.testing.expectError(error.UnexpectedPositional, parseServe(alloc, &.{ "25565", "25566" }, &err));
}

test "help text mentions seed semantics and config" {
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try printServeHelp(&w);
    const text = w.buffered();
    // Seed lives in the config file; help says so explicitly.
    try std.testing.expect(std.mem.indexOf(u8, text, "no --seed flag") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "seed") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "asteorite.toml") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "hash") != null);
}

test "version output uses the selected profile metadata" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try printVersion(&w, .{ .name = "1.8.9", .protocol = 47, .profile_id = "mc47" });
    try std.testing.expectEqualStrings(
        "Asteorite 1.8.9 (protocol 47, profile mc47)\n",
        w.buffered(),
    );
}

test "top help renders the selected profile metadata" {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try printTopHelp(&w, .{ .name = "1.7.10", .protocol = 5, .profile_id = "mc5" });
    const text = w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, text, "Asteorite 1.7.10 (proto v5) server + tools."));
    try std.testing.expect(std.mem.indexOf(u8, text, "version  print the selected profile") != null);
}
