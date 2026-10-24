//! Server configuration: JSON file + built-in defaults + validation.
//!
//! Precedence (lowest to highest): built-in defaults < config file < CLI.
//! Every field in `FileConfig` is optional; "was it set?" is tracked by
//! nullness, so merging is just fill-in-the-gaps in that order.
//!
//! The world seed lives here (`seed`). Minecraft seeds ARE int64 already
//! (Java `long`), so the full numeric range -2^63..2^63-1 round-trips
//! exactly — yes, any numeric MC seed works, including negatives and the
//! full 19-digit range. Strings follow vanilla semantics: a string that
//! parses as an integer is that integer, anything else hashes with Java
//! `String.hashCode` (sign-extended to i64), exactly like typing text into
//! the vanilla seed field.

const std = @import("std");
// Shared via the asteorite module (this file lives in main's root module,
// so it must not import sim/ files by path — that would claim them into
// two modules).
const ratelimit = @import("asteorite").ratelimit;

/// Java String.hashCode over bytes. Exact for ASCII (UTF-16 code units ==
// bytes there); non-ASCII differs from Java the same way any UTF-8 port
/// does (documented; MC text seeds are near-universally ASCII).
pub fn javaStringHash(s: []const u8) i64 {
    var h: i32 = 0;
    for (s) |c| h = h *% 31 +% @as(i32, c);
    return h;
}

/// Parse a seed the way vanilla does: integer (decimal, 0x hex, 0o octal)
// verbatim, otherwise the Java string hash. Never fails on non-empty
/// input; empty string hashes to 0 like Java (`"".hashCode() == 0`).
pub fn parseSeedString(s: []const u8) i64 {
    if (std.fmt.parseInt(i64, s, 0) catch null) |n| return n;
    return javaStringHash(s);
}

/// Raw JSON shape: every field optional so merge = fill gaps.
/// Unknown JSON keys are ignored (forward-compat).
pub const FileConfig = struct {
    port: ?u16 = null,
    online: ?bool = null,
    db: ?[]const u8 = null,
    view_distance: ?u8 = null,
    /// JSON number (must fit i64) or string (MC semantics: numeric
    /// strings parse, anything else hashes). JSON null / missing = unset.
    seed: ?std.json.Value = null,
    gen_spawn: ?i32 = null,
    gen_workers: ?usize = null,
    ops: ?[][]const u8 = null,
    rcon_password: ?[]const u8 = null,
    rcon_port: ?u16 = null,
    /// Server list MOTD (shown in the multiplayer menu).
    motd: ?[]const u8 = null,
    /// Server list player cap.
    max_players: ?u8 = null,
    /// Handshake brand advertised in status: "vanilla", "fabric", or "forge"
    /// ("fml" also accepted for forge). Forge adds the FML modinfo block.
    brand: ?[]const u8 = null,
    /// Phase B: network transport backend ("auto", "uring", "kqueue",
    /// "iocp", "blocking").
    transport: ?[]const u8 = null,
    /// Storage profile ("auto", "hdd", "ssd", "nvme").
    storage_profile: ?[]const u8 = null,
    /// Phase B: transport worker threads (0 = auto).
    transport_workers: ?usize = null,
    /// Phase C: region tick threads (0 = auto).
    region_threads: ?usize = null,
    /// Phase B: per-connection outbox cap in bytes (backpressure).
    out_cap_bytes: ?usize = null,
    /// Phase B: zerocopy send threshold in bytes.
    send_zc_threshold: ?usize = null,
    /// Phase B: TCP_NODELAY on accepted sockets.
    tcp_nodelay: ?bool = null,
    /// Phase B: socket buffer sizes (0 = OS default).
    sndbuf: ?usize = null,
    rcvbuf: ?usize = null,
    /// Anti-flood budgets (all admin-tunable; windows are milliseconds).
    /// Login gate: joins allowed per window per IP.
    login_rate_window_ms: ?i64 = null,
    login_rate_burst: ?usize = null,
    /// Placement gate: block placements allowed per window per conn
    /// (creative spam = chunk rewrite storm into the LSM).
    place_rate_window_ms: ?i64 = null,
    place_rate_burst: ?usize = null,

    /// Resolve the seed union into a plain i64. Errors on float values
    /// and out-of-range integers (with the offending value echoed by the
    /// caller via ConfigError context).
    pub fn resolveSeed(self: *const FileConfig) ResolveSeedError! ?i64 {
        const v = self.seed orelse return null;
        return switch (v) {
            .integer => |n| n,
            .string => |s| parseSeedString(s),
            .float => error.SeedMustBeIntegerOrString,
            .null => null,
            else => error.SeedMustBeIntegerOrString,
        };
    }
};

pub const ResolveSeedError = error{
    SeedMustBeIntegerOrString,
    OutOfMemory,
};

/// Effective configuration after merging defaults < file < CLI.
/// `ops` aliases the winning source's slice (no copy).
pub const Effective = struct {
    port: u16 = 25565,
    online: bool = false,
    /// World folder (vanilla name). Bare `serve` persists here.
    db: ?[]const u8 = "world",
    view_distance: u8 = 4,
    seed: ?i64 = null,
    gen_spawn: ?i32 = null,
    gen_workers: ?usize = null,
    ops: []const []const u8 = &.{},
    rcon_password: ?[]const u8 = null,
    rcon_port: u16 = 25575,
    motd: []const u8 = "Asteorite",
    max_players: u8 = 20,
    brand: []const u8 = "vanilla",
    /// Phase B: transport backend ("auto" resolves per OS).
    transport: []const u8 = "auto",
    /// Storage profile ("auto" detects rotational storage on Linux).
    storage_profile: []const u8 = "auto",
    /// Phase B: transport worker threads (0 = auto).
    transport_workers: usize = 0,
    /// Phase C: region tick threads (0 = auto = cpus, max 8).
    region_threads: usize = 0,
    /// Phase B: per-connection outbox cap in bytes.
    out_cap_bytes: usize = 4 * 1024 * 1024,
    /// Phase B: zerocopy send threshold in bytes.
    send_zc_threshold: usize = 8 * 1024,
    /// Phase B: TCP_NODELAY on accepted sockets.
    tcp_nodelay: bool = true,
    /// Phase B: socket buffer sizes (0 = OS default).
    sndbuf: usize = 0,
    rcvbuf: usize = 0,
    /// Login flood budget: joins allowed per window per IP (capacities in
    /// sim/ratelimit.zig cap the burst).
    login_rate_window_ms: i64 = ratelimit.default_login_window_ms,
    login_rate_burst: usize = ratelimit.default_login_burst,
    /// Placement flood budget: placements allowed per window per conn.
    place_rate_window_ms: i64 = ratelimit.default_place_window_ms,
    place_rate_burst: usize = ratelimit.default_place_burst,
    /// Where non-default values came from (startup log + debugging).
    source: Source = .defaults,

    pub const Source = enum {
        defaults,
        /// Config file was loaded (CLI may still override individual keys).
        file,
    };
};

pub const ValidateError = error{
    BadPort,
    BadViewDistance,
    BadGenSpawn,
    BadGenWorkers,
    BadRconPort,
    BadMaxPlayers,
    BadBrand,
    BadTransport,
    BadStorageProfile,
    BadLoginRate,
    BadPlaceRate,
};

/// Protocol/gameplay sanity checks. View is capped at 16: the 1.7.10
/// client never requests more and chunk packets assume it.
pub fn validate(c: *const Effective) ValidateError!void {
    if (c.port == 0) return error.BadPort;
    if (c.view_distance < 1 or c.view_distance > 16) return error.BadViewDistance;
    if (c.gen_spawn != null and c.gen_spawn.? < 0) return error.BadGenSpawn;
    if (c.gen_workers != null and c.gen_workers.? == 0) return error.BadGenWorkers;
    if (c.rcon_port == 0 and c.rcon_password != null) return error.BadRconPort;
    if (c.max_players == 0) return error.BadMaxPlayers;
    if (!isKnownBrand(c.brand)) return error.BadBrand;
    if (!isKnownTransport(c.transport)) return error.BadTransport;
    if (!isKnownStorageProfile(c.storage_profile)) return error.BadStorageProfile;
    // Flood gates: windows below the noise floor are rejected; bursts
    // are capped by the fixed window capacities (see sim/ratelimit.zig).
    if (c.login_rate_window_ms < ratelimit.min_window_ms or c.login_rate_burst < 1 or c.login_rate_burst > ratelimit.login_window_capacity) return error.BadLoginRate;
    if (c.place_rate_window_ms < ratelimit.min_window_ms or c.place_rate_burst < 1 or c.place_rate_burst > ratelimit.place_window_capacity) return error.BadPlaceRate;
}

/// Accepted storage-profile spellings (Phase B NVMe path).
pub fn isKnownStorageProfile(s: []const u8) bool {
    for ([_][]const u8{ "auto", "hdd", "ssd", "nvme" }) |known| {
        if (std.mem.eql(u8, s, known)) return true;
    }
    return false;
}

/// Accepted transport spellings (Phase B).
pub fn isKnownTransport(s: []const u8) bool {
    for ([_][]const u8{ "auto", "uring", "kqueue", "iocp", "blocking" }) |known| {
        if (std.mem.eql(u8, s, known)) return true;
    }
    return false;
}

/// Accepted `brand` spellings (mirrors status.Brand.parse; kept as plain
/// strings here so config.zig stays dependency-free).
pub fn isKnownBrand(s: []const u8) bool {
    for ([_][]const u8{ "vanilla", "fabric", "forge", "fml" }) |known| {
        if (std.mem.eql(u8, s, known)) return true;
    }
    return false;
}

/// Human message for a validation failure (caller prints + usage).
/// Burst bounds name the window capacities (single source of truth).
pub fn validateMessage(err: ValidateError) []const u8 {
    return switch (err) {
        error.BadPort => "port must be 1-65535",
        error.BadViewDistance => "view_distance must be 1-16 (1.7.10 client cap)",
        error.BadGenSpawn => "gen_spawn must be >= 0",
        error.BadGenWorkers => "gen_workers must be >= 1",
        error.BadRconPort => "rcon_port must be 1-65535 when rcon_password is set",
        error.BadMaxPlayers => "max_players must be 1-255",
        error.BadBrand => "brand must be vanilla, fabric, or forge",
        error.BadTransport => "transport must be auto, uring, kqueue, iocp, or blocking",
        error.BadStorageProfile => "storage_profile must be auto, hdd, ssd, or nvme",
        error.BadLoginRate => comptime std.fmt.comptimePrint("login_rate_window_ms must be >= {d}, login_rate_burst 1..{d}", .{ ratelimit.min_window_ms, ratelimit.login_window_capacity }),
        error.BadPlaceRate => comptime std.fmt.comptimePrint("place_rate_window_ms must be >= {d}, place_rate_burst 1..{d}", .{ ratelimit.min_window_ms, ratelimit.place_window_capacity }),
    };
}

/// Parse a JSON config document. `alloc` backs all strings/slices
/// (pass an arena). Unknown fields ignored.
pub fn parseJson(alloc: std.mem.Allocator, text: []const u8) !std.json.Parsed(FileConfig) {
    return std.json.parseFromSlice(FileConfig, alloc, text, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

/// Merge file config under CLI overrides (already parsed). CLI wins per key.
pub fn merge(base: Effective, file: *const FileConfig, file_seed: ?i64) Effective {
    var out = base;
    if (file.port) |v| out.port = v;
    if (file.online) |v| out.online = v;
    if (file.db) |v| out.db = v;
    if (file.view_distance) |v| out.view_distance = v;
    if (file_seed) |v| out.seed = v;
    if (file.gen_spawn) |v| out.gen_spawn = v;
    if (file.gen_workers) |v| out.gen_workers = v;
    if (file.ops) |v| out.ops = v;
    if (file.rcon_password) |v| out.rcon_password = v;
    if (file.rcon_port) |v| out.rcon_port = v;
    if (file.motd) |v| out.motd = v;
    if (file.max_players) |v| out.max_players = v;
    if (file.brand) |v| out.brand = v;
    if (file.transport) |v| out.transport = v;
    if (file.storage_profile) |v| out.storage_profile = v;
    if (file.transport_workers) |v| out.transport_workers = v;
    if (file.region_threads) |v| out.region_threads = v;
    if (file.out_cap_bytes) |v| out.out_cap_bytes = v;
    if (file.send_zc_threshold) |v| out.send_zc_threshold = v;
    if (file.tcp_nodelay) |v| out.tcp_nodelay = v;
    if (file.sndbuf) |v| out.sndbuf = v;
    if (file.rcvbuf) |v| out.rcvbuf = v;
    if (file.login_rate_window_ms) |v| out.login_rate_window_ms = v;
    if (file.login_rate_burst) |v| out.login_rate_burst = v;
    if (file.place_rate_window_ms) |v| out.place_rate_window_ms = v;
    if (file.place_rate_burst) |v| out.place_rate_burst = v;
    return out;
}

/// Default config file name probed in the working directory.
pub const default_path = "asteorite.json";

test "seed: integers round-trip the full int64 range" {
    try std.testing.expectEqual(@as(i64, 42), parseSeedString("42"));
    try std.testing.expectEqual(@as(i64, -42), parseSeedString("-42"));
    try std.testing.expectEqual(@as(i64, 0), parseSeedString("0"));
    try std.testing.expectEqual(@as(i64, 9223372036854775807), parseSeedString("9223372036854775807"));
    try std.testing.expectEqual(@as(i64, -9223372036854775808), parseSeedString("-9223372036854775808"));
    try std.testing.expectEqual(@as(i64, 0x1234), parseSeedString("0x1234"));
}

test "seed: non-numeric strings use Java hashCode" {
    // Goldens from `java HashT` (OpenJDK): "".hashCode()==0, "a"==97.
    try std.testing.expectEqual(@as(i64, 0), parseSeedString(""));
    try std.testing.expectEqual(@as(i64, 97), parseSeedString("a"));
    try std.testing.expectEqual(@as(i64, 75456088), parseSeedString("Notch"));
    try std.testing.expectEqual(@as(i64, 1936551105), parseSeedString("Mission to the Moon"));
}

test "seed: out-of-range integers fall back to hash (never crash)" {
    // "9223372036854775808" overflows i64 -> hashCode, like vanilla's
    // Long.parseLong catch path.
    try std.testing.expectEqual(@as(i64, -1773151197), parseSeedString("9223372036854775808"));
}

test "config json: full file parses" {
    const alloc = std.testing.allocator;
    const text =
        \\{
        \\  "port": 25566,
        \\  "online": true,
        \\  "db": "zc-db",
        \\  "view_distance": 8,
        \\  "seed": 42,
        \\  "gen_spawn": 4,
        \\  "gen_workers": 2,
        \\  "ops": ["alice", "bob"],
        \\  "rcon_password": "hunter2hunter2",
        \\  "rcon_port": 25576,
        \\  "motd": "hello \"quoted\"",
        \\  "max_players": 30,
        \\  "brand": "forge",
        \\  "transport": "uring",
        \\  "transport_workers": 4,
        \\  "region_threads": 6,
        \\  "storage_profile": "nvme",
        \\  "out_cap_bytes": 1048576,
        \\  "login_rate_window_ms": 5000,
        \\  "login_rate_burst": 3,
        \\  "place_rate_window_ms": 2000,
        \\  "place_rate_burst": 16,
        \\  "future_key": "ignored"
        \\}
    ;
    var parsed = try parseJson(alloc, text);
    defer parsed.deinit();
    const f = parsed.value;
    try std.testing.expectEqual(@as(?u16, 25566), f.port);
    try std.testing.expectEqual(@as(?bool, true), f.online);
    try std.testing.expectEqualStrings("zc-db", f.db.?);
    try std.testing.expectEqual(@as(?u8, 8), f.view_distance);
    try std.testing.expectEqual(@as(?i64, 42), try f.resolveSeed());
    try std.testing.expectEqual(@as(?i32, 4), f.gen_spawn);
    try std.testing.expectEqual(@as(?usize, 2), f.gen_workers);
    try std.testing.expectEqual(@as(usize, 2), f.ops.?.len);
    try std.testing.expectEqualStrings("bob", f.ops.?[1]);
    try std.testing.expectEqual(@as(?u16, 25576), f.rcon_port);
    try std.testing.expectEqualStrings("hello \"quoted\"", f.motd.?);
    try std.testing.expectEqual(@as(?u8, 30), f.max_players);
    try std.testing.expectEqualStrings("forge", f.brand.?);
    try std.testing.expectEqualStrings("uring", f.transport.?);
    try std.testing.expectEqual(@as(?usize, 4), f.transport_workers);
    try std.testing.expectEqual(@as(?usize, 6), f.region_threads);
    try std.testing.expectEqualStrings("nvme", f.storage_profile.?);
    try std.testing.expectEqual(@as(usize, 1048576), f.out_cap_bytes);
    try std.testing.expectEqual(@as(?i64, 5000), f.login_rate_window_ms);
    try std.testing.expectEqual(@as(?usize, 3), f.login_rate_burst);
    try std.testing.expectEqual(@as(?i64, 2000), f.place_rate_window_ms);
    try std.testing.expectEqual(@as(?usize, 16), f.place_rate_burst);
}

test "config validate: storage-profile spelling" {
    try std.testing.expect(isKnownStorageProfile("auto"));
    try std.testing.expect(isKnownStorageProfile("hdd"));
    try std.testing.expect(isKnownStorageProfile("ssd"));
    try std.testing.expect(isKnownStorageProfile("nvme"));
    try std.testing.expect(!isKnownStorageProfile("tape"));
    var bad = Effective{ .storage_profile = "tape" };
    try std.testing.expectError(error.BadStorageProfile, validate(&bad));
}

test "config validate: transport spelling" {
    try std.testing.expect(isKnownTransport("auto"));
    try std.testing.expect(isKnownTransport("uring"));
    try std.testing.expect(isKnownTransport("blocking"));
    try std.testing.expect(!isKnownTransport("epoll"));
    var bad = Effective{ .transport = "epoll" };
    try std.testing.expectError(error.BadTransport, validate(&bad));
}

test "config validate: motd/brand/max_players" {
    var ok = Effective{};
    try validate(&ok);
    try std.testing.expect(isKnownBrand("vanilla"));
    try std.testing.expect(isKnownBrand("fml"));
    try std.testing.expect(!isKnownBrand("Forge"));
    var bad = Effective{ .max_players = 0 };
    try std.testing.expectError(error.BadMaxPlayers, validate(&bad));
    bad = Effective{ .brand = "spigot" };
    try std.testing.expectError(error.BadBrand, validate(&bad));
}

test "config json: string and negative seeds" {
    const alloc = std.testing.allocator;
    var p1 = try parseJson(alloc, "{\"seed\": \"Notch\"}");
    defer p1.deinit();
    try std.testing.expectEqual(@as(?i64, 75456088), try p1.value.resolveSeed());
    var p2 = try parseJson(alloc, "{\"seed\": -123456789012345678}");
    defer p2.deinit();
    try std.testing.expectEqual(@as(?i64, -123456789012345678), try p2.value.resolveSeed());
    var p3 = try parseJson(alloc, "{\"seed\": 1.5}");
    defer p3.deinit();
    try std.testing.expectError(error.SeedMustBeIntegerOrString, p3.value.resolveSeed());
}

test "config json: missing keys stay null" {
    const alloc = std.testing.allocator;
    var parsed = try parseJson(alloc, "{}");
    defer parsed.deinit();
    const f = parsed.value;
    try std.testing.expect(f.port == null);
    try std.testing.expect(f.seed == null);
    try std.testing.expect(try f.resolveSeed() == null);
}

test "config validate" {
    var ok = Effective{};
    try validate(&ok);
    try std.testing.expectEqual(@as(i64, 10000), ok.login_rate_window_ms);
    try std.testing.expectEqual(@as(usize, 5), ok.login_rate_burst);
    try std.testing.expectEqual(@as(i64, 1000), ok.place_rate_window_ms);
    try std.testing.expectEqual(@as(usize, 32), ok.place_rate_burst);
    var bad = Effective{ .view_distance = 0 };
    try std.testing.expectError(error.BadViewDistance, validate(&bad));
    bad = Effective{ .view_distance = 17 };
    try std.testing.expectError(error.BadViewDistance, validate(&bad));
    bad = Effective{ .port = 0 };
    try std.testing.expectError(error.BadPort, validate(&bad));
    bad = Effective{ .gen_spawn = -1 };
    try std.testing.expectError(error.BadGenSpawn, validate(&bad));
    bad = Effective{ .gen_workers = 0 };
    try std.testing.expectError(error.BadGenWorkers, validate(&bad));
    bad = Effective{ .login_rate_window_ms = 50 };
    try std.testing.expectError(error.BadLoginRate, validate(&bad));
    bad = Effective{ .login_rate_burst = 0 };
    try std.testing.expectError(error.BadLoginRate, validate(&bad));
    bad = Effective{ .login_rate_burst = ratelimit.login_window_capacity + 1 };
    try std.testing.expectError(error.BadLoginRate, validate(&bad));
    bad = Effective{ .place_rate_window_ms = 50 };
    try std.testing.expectError(error.BadPlaceRate, validate(&bad));
    bad = Effective{ .place_rate_burst = 0 };
    try std.testing.expectError(error.BadPlaceRate, validate(&bad));
    bad = Effective{ .place_rate_burst = ratelimit.place_window_capacity + 1 };
    try std.testing.expectError(error.BadPlaceRate, validate(&bad));
}
