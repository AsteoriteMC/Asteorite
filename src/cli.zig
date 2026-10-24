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
    max_players: ?u8 = null,
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

fn parseBool(s: []const u8) ?bool {
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1") or
        std.mem.eql(u8, s, "yes") or std.mem.eql(u8, s, "on")) return true;
    if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "0") or
        std.mem.eql(u8, s, "no") or std.mem.eql(u8, s, "off")) return false;
    return null;
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
                const v = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return fail(err, .missing_value, "--config", "", error.MissingValue);
                    break :blk argv[i];
                };
                out.config_path = v;
                continue;
            } else if (std.mem.eql(u8, name, "--online")) {
                if (inline_val) |v| {
                    out.online = parseBool(v) orelse return fail(err, .bad_value, "--online", v, error.BadValue);
                } else out.online = true;
                continue;
            } else if (std.mem.eql(u8, name, "--no-online")) {
                if (inline_val != null) return fail(err, .bad_value, "--no-online", inline_val.?, error.BadValue);
                out.online = false;
                continue;
            } else if (std.mem.eql(u8, name, "--db")) {
                const v = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return fail(err, .missing_value, "--db", "", error.MissingValue);
                    break :blk argv[i];
                };
                out.db = v;
                continue;
            } else if (std.mem.eql(u8, name, "--view")) {
                const v = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return fail(err, .missing_value, "--view", "", error.MissingValue);
                    break :blk argv[i];
                };
                out.view_distance = std.fmt.parseInt(u8, v, 10) catch return fail(err, .bad_value, "--view", v, error.BadValue);
                continue;
            } else if (std.mem.eql(u8, name, "--gen-spawn")) {
                const v = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return fail(err, .missing_value, "--gen-spawn", "", error.MissingValue);
                    break :blk argv[i];
                };
                out.gen_spawn = std.fmt.parseInt(i32, v, 10) catch return fail(err, .bad_value, "--gen-spawn", v, error.BadValue);
                continue;
            } else if (std.mem.eql(u8, name, "--gen-workers")) {
                const v = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return fail(err, .missing_value, "--gen-workers", "", error.MissingValue);
                    break :blk argv[i];
                };
                out.gen_workers = std.fmt.parseInt(usize, v, 10) catch return fail(err, .bad_value, "--gen-workers", v, error.BadValue);
                continue;
            } else if (std.mem.eql(u8, name, "--op")) {
                const v = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return fail(err, .missing_value, "--op", "", error.MissingValue);
                    break :blk argv[i];
                };
                try out.ops.append(arena, v);
                continue;
            } else if (std.mem.eql(u8, name, "--rcon-password")) {
                const v = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return fail(err, .missing_value, "--rcon-password", "", error.MissingValue);
                    break :blk argv[i];
                };
                out.rcon_password = v;
                continue;
            } else if (std.mem.eql(u8, name, "--rcon-port")) {
                const v = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return fail(err, .missing_value, "--rcon-port", "", error.MissingValue);
                    break :blk argv[i];
                };
                out.rcon_port = std.fmt.parseInt(u16, v, 10) catch return fail(err, .bad_value, "--rcon-port", v, error.BadValue);
                continue;
            } else if (std.mem.eql(u8, name, "--motd")) {
                const v = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return fail(err, .missing_value, "--motd", "", error.MissingValue);
                    break :blk argv[i];
                };
                out.motd = v;
                continue;
            } else if (std.mem.eql(u8, name, "--max-players")) {
                const v = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return fail(err, .missing_value, "--max-players", "", error.MissingValue);
                    break :blk argv[i];
                };
                out.max_players = std.fmt.parseInt(u8, v, 10) catch return fail(err, .bad_value, "--max-players", v, error.BadValue);
                continue;
            } else if (std.mem.eql(u8, name, "--brand")) {
                const v = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return fail(err, .missing_value, "--brand", "", error.MissingValue);
                    break :blk argv[i];
                };
                if (!config.isKnownBrand(v)) return fail(err, .bad_value, "--brand", v, error.BadValue);
                out.brand = v;
                continue;
            } else if (std.mem.eql(u8, name, "--transport")) {
                const v = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return fail(err, .missing_value, "--transport", "", error.MissingValue);
                    break :blk argv[i];
                };
                out.transport = v;
                continue;
            } else if (std.mem.eql(u8, name, "--storage-profile")) {
                const v = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return fail(err, .missing_value, "--storage-profile", "", error.MissingValue);
                    break :blk argv[i];
                };
                out.storage_profile = v;
                continue;
            } else if (std.mem.eql(u8, name, "--transport-workers")) {
                const v = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return fail(err, .missing_value, "--transport-workers", "", error.MissingValue);
                    break :blk argv[i];
                };
                out.transport_workers = std.fmt.parseInt(usize, v, 10) catch return fail(err, .bad_value, "--transport-workers", v, error.BadValue);
                continue;
            } else if (std.mem.eql(u8, name, "--region-threads")) {
                const v = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return fail(err, .missing_value, "--region-threads", "", error.MissingValue);
                    break :blk argv[i];
                };
                out.region_threads = std.fmt.parseInt(usize, v, 10) catch return fail(err, .bad_value, "--region-threads", v, error.BadValue);
                continue;
            } else if (std.mem.eql(u8, name, "--out-cap")) {
                const v = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return fail(err, .missing_value, "--out-cap", "", error.MissingValue);
                    break :blk argv[i];
                };
                out.out_cap_bytes = std.fmt.parseInt(usize, v, 10) catch return fail(err, .bad_value, "--out-cap", v, error.BadValue);
                continue;
            } else if (std.mem.eql(u8, name, "--send-zc-threshold")) {
                const v = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return fail(err, .missing_value, "--send-zc-threshold", "", error.MissingValue);
                    break :blk argv[i];
                };
                out.send_zc_threshold = std.fmt.parseInt(usize, v, 10) catch return fail(err, .bad_value, "--send-zc-threshold", v, error.BadValue);
                continue;
            } else if (std.mem.eql(u8, name, "--tcp-nodelay")) {
                if (inline_val) |v| {
                    out.tcp_nodelay = parseBool(v) orelse return fail(err, .bad_value, "--tcp-nodelay", v, error.BadValue);
                } else out.tcp_nodelay = true;
                continue;
            } else if (std.mem.eql(u8, name, "--no-tcp-nodelay")) {
                if (inline_val != null) return fail(err, .bad_value, "--no-tcp-nodelay", inline_val.?, error.BadValue);
                out.tcp_nodelay = false;
                continue;
            } else if (std.mem.eql(u8, name, "--sndbuf")) {
                const v = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return fail(err, .missing_value, "--sndbuf", "", error.MissingValue);
                    break :blk argv[i];
                };
                out.sndbuf = std.fmt.parseInt(usize, v, 10) catch return fail(err, .bad_value, "--sndbuf", v, error.BadValue);
                continue;
            } else if (std.mem.eql(u8, name, "--rcvbuf")) {
                const v = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return fail(err, .missing_value, "--rcvbuf", "", error.MissingValue);
                    break :blk argv[i];
                };
                out.rcvbuf = std.fmt.parseInt(usize, v, 10) catch return fail(err, .bad_value, "--rcvbuf", v, error.BadValue);
                continue;
            } else if (std.mem.eql(u8, name, "--login-rate-window-ms")) {
                const v = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return fail(err, .missing_value, "--login-rate-window-ms", "", error.MissingValue);
                    break :blk argv[i];
                };
                out.login_rate_window_ms = std.fmt.parseInt(i64, v, 10) catch return fail(err, .bad_value, "--login-rate-window-ms", v, error.BadValue);
                continue;
            } else if (std.mem.eql(u8, name, "--login-rate-burst")) {
                const v = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return fail(err, .missing_value, "--login-rate-burst", "", error.MissingValue);
                    break :blk argv[i];
                };
                out.login_rate_burst = std.fmt.parseInt(usize, v, 10) catch return fail(err, .bad_value, "--login-rate-burst", v, error.BadValue);
                continue;
            } else if (std.mem.eql(u8, name, "--place-rate-window-ms")) {
                const v = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return fail(err, .missing_value, "--place-rate-window-ms", "", error.MissingValue);
                    break :blk argv[i];
                };
                out.place_rate_window_ms = std.fmt.parseInt(i64, v, 10) catch return fail(err, .bad_value, "--place-rate-window-ms", v, error.BadValue);
                continue;
            } else if (std.mem.eql(u8, name, "--place-rate-burst")) {
                const v = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return fail(err, .missing_value, "--place-rate-burst", "", error.MissingValue);
                    break :blk argv[i];
                };
                out.place_rate_burst = std.fmt.parseInt(usize, v, 10) catch return fail(err, .bad_value, "--place-rate-burst", v, error.BadValue);
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
        \\  --op <name>            grant op (repeatable; persisted in db)
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
        \\  -c, --config <path>    JSON config file (default ./asteorite.json
        \\                         if present; CLI flags override file keys)
        \\  -h, --help             this help
        \\
        \\config file (JSON, all keys optional):
        \\  {{"port": 25565, "online": false, "db": "world", "view_distance": 8,
        \\   "seed": 42, "gen_spawn": 4, "gen_workers": 4, "ops": ["alice"],
        \\   "rcon_password": null, "rcon_port": 25575, "motd": "Asteorite",
        \\   "max_players": 20, "brand": "vanilla"}}
        \\  "seed" also accepts a string ("Notch") with vanilla hash semantics.
        \\  "brand" is one of vanilla, fabric, forge (fml accepted for forge).
        \\  there is no --seed flag: set "seed" in the config file.
        \\  precedence: built-in defaults < config file < CLI flags.
        \\
        \\examples:
        \\  asteorite serve --db world --view 8
        \\  asteorite serve 25566 --config myserver.json --op alice
        \\  asteorite serve --brand forge --motd "modded-ish" --max-players 50
        \\  # world seed lives in the config file, e.g. {{"seed": 42}}
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

test "parse: motd/max-players/brand" {
    const alloc = std.testing.allocator;
    var err = ParseError{};
    var a = try parseServe(alloc, &.{ "--motd", "hi there", "--max-players=50", "--brand", "forge" }, &err);
    defer a.ops.deinit(alloc);
    try std.testing.expectEqualStrings("hi there", a.motd.?);
    try std.testing.expectEqual(@as(?u8, 50), a.max_players);
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
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try printServeHelp(&w);
    const text = w.buffered();
    // Seed lives in the config file; help says so explicitly.
    try std.testing.expect(std.mem.indexOf(u8, text, "no --seed flag") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"seed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "asteorite.json") != null);
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
