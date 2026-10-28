//! Server configuration: JSON file + built-in defaults + validation.
//!
//! Precedence (lowest to highest): built-in defaults < config file < CLI.
//! The file is one object per category (server, world, network, storage,
//! rates, telemetry, wasm, gpu); every section and every key inside is
//! optional, so merging is just fill-in-the-gaps in that order. Top-level
//! keys outside the section allowlist fail boot (legacy flat keys land
//! here — silently dropping them could mint a random world).
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
const toml = @import("asteorite").toml;

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

/// Raw JSON shape: one object per settings category; every section and
/// every key inside is optional, so merge = fill gaps. Unknown keys *inside*
/// a section are ignored (forward-compat); unknown *top-level* keys are a
/// hard boot error (they are legacy flat keys or typos — silently dropping
/// them could mint a random world from a lost "seed").
/// Sections: server, world, network, storage, rates, telemetry, wasm, gpu.
pub const FileServer = struct {
    port: ?u16 = null,
    online: ?bool = null,
    db: ?[]const u8 = null,
    view_distance: ?u8 = null,
    /// Server list MOTD (shown in the multiplayer menu).
    motd: ?[]const u8 = null,
    /// Server list player cap.
    max_players: ?u16 = null,
    /// Handshake brand advertised in status: "vanilla", "fabric", or "forge"
    /// ("fml" also accepted for forge). Forge adds the FML modinfo block.
    brand: ?[]const u8 = null,
    ops: ?[][]const u8 = null,
    rcon_password: ?[]const u8 = null,
    rcon_port: ?u16 = null,
    /// Minutes until idle kick (default 0 = never). Same as /setidletimeout.
    idle_timeout: ?u32 = null,
    /// Periodic autosave every 5 minutes (default true).
    autosave: ?bool = null,
};

pub const FileWorld = struct {
    /// JSON number (must fit i64) or string (MC semantics: numeric
    /// strings parse, anything else hashes). JSON null / missing = unset.
    seed: ?std.json.Value = null,
    gen_spawn: ?i32 = null,
    gen_workers: ?usize = null,
    /// Phase C: region tick threads (0 = auto).
    region_threads: ?usize = null,
    /// Default gamemode for first-time logins: "survival", "creative", or
    /// "adventure" (case-insensitive; "s"/"c"/"a" or 0/1/2 also accepted).
    /// Vanilla server.properties parity (there called gamemode=0/1/2).
    gamemode: ?[]const u8 = null,
    /// World difficulty: "peaceful", "easy", "normal", or "hard"
    /// (case-insensitive; "p"/"e"/"n"/"h" or 0-3 also accepted).
    difficulty: ?[]const u8 = null,
    /// Vanilla pvp flag (default true): false makes player-vs-player
    /// swings fizzle (mobs unaffected).
    pvp: ?bool = null,
    /// Vanilla force-gamemode (default false): when true, returning
    /// players inherit the default gamemode at login like fresh ones.
    force_gamemode: ?bool = null,
    /// Gamerule boot overrides: {"keepInventory": true, ...}. Keys must
    /// match the vanilla gamerule names exactly (case-sensitive, like
    /// /gamerule); values must be booleans. Absent rules keep their
    /// built-in defaults. Unknown keys fail boot (typo fail-closed).
    gamerules: ?std.json.Value = null,
    /// Natural-spawn master switch (default true). False stops all new
    /// natural mob spawns (existing mobs stay); doMobSpawning and the
    /// per-kind map below refine it.
    spawn_mobs: ?bool = null,
    /// Per-kind spawn allowlist: {"zombie": false, ...}. Keys are mob
    /// kind names (case-insensitive; all 29 vanilla kinds); values must
    /// be booleans. Absent kinds stay allowed. Unknown keys fail boot.
    /// Enforced by canSpawnMob at every spawn ingress.
    mob_spawns: ?std.json.Value = null,
    /// View-distance-style simulation radius placeholder (default 10).
    /// NOT implemented yet: ticking still follows view distance. Setting
    /// anything warns at boot (see TODO.md); the value is stored for
    /// forward-compat.
    simulation_distance: ?u8 = null,
};

pub const FileNetwork = struct {
    /// Bind address (default "0.0.0.0" = all interfaces).
    bind_address: ?[]const u8 = null,
    /// Kernel accept backlog (default 4096).
    backlog: ?u16 = null,
    /// io_uring ring entries, power of two (default 256).
    io_uring_entries: ?u16 = null,
    /// Phase B: network transport backend ("auto", "uring", "kqueue",
    /// "iocp", "blocking").
    transport: ?[]const u8 = null,
    /// Phase B: transport worker threads (0 = auto).
    transport_workers: ?usize = null,
    /// Phase B: TCP_NODELAY on accepted sockets.
    tcp_nodelay: ?bool = null,
    /// Phase B: socket buffer sizes (0 = OS default).
    sndbuf: ?usize = null,
    rcvbuf: ?usize = null,
    /// Global packets-per-second cap per conn, 0 disables (default 0).
    max_packets_per_second: ?u32 = null,
    /// Max inbound frame length in bytes (default 2097152). Must stay
    /// above the largest legit bulk or joining breaks; validated.
    max_packet_size: ?usize = null,
    /// Packet compression threshold in bytes, -1 disables (default -1).
    /// NOT implemented yet (no SetCompression path): any other value
    /// warns at boot (see TODO.md).
    compression_threshold: ?i64 = null,
    /// Compression level 1..9 if compression ever enables (default 3).
    compression_level: ?u8 = null,
    /// Max NBT compound depth, exploit guard (default 32). NOT enforced
    /// yet: NBT rides opaque today (never parsed), so depth is inert.
    /// Warns when changed (see TODO.md).
    max_nbt_depth: ?u32 = null,
    /// Max chat/plugin-channel string length in bytes (default 32767,
    /// the vanilla wire max). NOT honored yet: chat buffers are fixed
    /// 1024 today. Warns when changed (see TODO.md).
    max_string_length: ?u32 = null,
    /// Phase B: per-connection outbox cap in bytes (backpressure).
    out_cap_bytes: ?usize = null,
    /// Phase B: zerocopy send threshold in bytes.
    send_zc_threshold: ?usize = null,
};

pub const FileStorage = struct {
    /// Storage profile ("auto", "hdd", "ssd", "nvme").
    storage_profile: ?[]const u8 = null,
    /// Region-file cache size placeholder (default 256). The LSM store
    /// has no region files, so this currently sizes nothing; warns when
    /// changed (see TODO.md).
    region_cache_size: ?u32 = null,
    /// Auto-flush of modified chunks to disk, seconds (default 30). NOT
    /// implemented yet (durability today is WAL + 5-minute autosave);
    /// warns when changed (see TODO.md).
    disk_flush_interval: ?u32 = null,
    /// Memtable size in bytes before a background SST flush (default: the
    /// storage profile's — 1/4/8 MiB for nvme/ssd/hdd). Bigger = fewer
    /// seals + WAL rotations under sustained bulk writes (pregen), at the
    /// cost of more RAM per shard and a larger loss window before flush.
    flush_threshold_bytes: ?usize = null,
    /// Auto-compact when live SST count reaches this (default: the
    /// storage profile's — 4/8/12 for nvme/ssd/hdd; 0 = manual only).
    /// Compaction merges under the store mutex, so during bulk loads a
    /// low threshold stalls writers on every merge; raise it (or set 0
    /// and compact once after) for pregen, then restore.
    compact_threshold_ssts: ?usize = null,
};

pub const FileRates = struct {
    /// Chat flood budget: window milliseconds (default 750).
    chat_rate_window_ms: ?i64 = null,
    /// Chat flood budget: chats allowed inside one window before the
    /// spam kick (default 3).
    chat_rate_burst: ?usize = null,
    /// Consecutive-dig flood budget: window milliseconds (default 1000).
    dig_rate_window_ms: ?i64 = null,
    /// Consecutive-dig flood budget: digs allowed per window before the
    /// spam kick (default 32, same as placements).
    dig_rate_burst: ?usize = null,
    /// Anti-flood budgets (all admin-tunable; windows are milliseconds).
    /// Login gate: joins allowed per window per IP.
    login_rate_window_ms: ?i64 = null,
    login_rate_burst: ?usize = null,
    /// Placement gate: block placements allowed per window per conn
    /// (creative spam = chunk rewrite storm into the LSM).
    place_rate_window_ms: ?i64 = null,
    place_rate_burst: ?usize = null,
};

pub const FileTelemetry = struct {
    /// Performance telemetry (default off). NO exporter exists yet
    /// (per-tick stats log only; see TODO.md); enabling warns at boot.
    telemetry_enabled: ?bool = null,
    /// MSPT sampling interval, milliseconds (default 50).
    telemetry_sampling_ms: ?u32 = null,
    /// Prometheus exporter (default off; needs telemetry work, TODO.md).
    telemetry_prometheus: ?bool = null,
    /// Prometheus port (default 9090).
    telemetry_prometheus_port: ?u16 = null,
};

pub const FileWasm = struct {
    /// WebAssembly sandboxed plugins (default off). NO plugin runtime
    /// exists yet (see TODO.md); enabling warns at boot.
    wasm_enabled: ?bool = null,
    /// Per-plugin memory cap, megabytes (default 128).
    wasm_max_memory_mb: ?u32 = null,
    /// Per-tick instruction gas per plugin callback (default 10000000).
    wasm_instruction_limit: ?u64 = null,
};

pub const FileGpu = struct {
    /// Phase G: GPU offload backend ("off", "vulkan"). Off by default;
    /// CPU fill is always correct (bit-identical either way).
    gpu: ?[]const u8 = null,
    /// Phase G: per-tick GPU dispatch budget, milliseconds. Stored for the
    /// async batch scheduler (v2); v1 dispatches synchronously per chunk.
    gpu_budget_ms: ?u32 = null,
    /// Phase G: max chunks per GPU dispatch (validated 1..64; 16 keeps
    /// dispatches under the RADV large-dispatch cliff). v1 dispatches 1.
    gpu_max_batch: ?usize = null,
    /// Phase G: GPU device preference ("auto", "discrete", "integrated",
    /// "cpu"). "cpu" selects a CPU-type device for testing the GPU path
    /// without discrete hardware.
    gpu_device: ?[]const u8 = null,
};

pub const FileConfig = struct {
    server: ?FileServer = null,
    world: ?FileWorld = null,
    network: ?FileNetwork = null,
    storage: ?FileStorage = null,
    rates: ?FileRates = null,
    telemetry: ?FileTelemetry = null,
    wasm: ?FileWasm = null,
    gpu: ?FileGpu = null,

    /// Resolve the seed union into a plain i64. Errors on float values
    /// and out-of-range integers (with the offending value echoed by the
    /// caller via ConfigError context).
    pub fn resolveSeed(self: *const FileConfig) ResolveSeedError! ?i64 {
        const s = self.world orelse return null;
        const v = s.seed orelse return null;
        return switch (v) {
            .integer => |n| n,
            .string => |str| parseSeedString(str),
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
    max_players: u16 = 20,
    brand: []const u8 = "vanilla",
    /// Default gamemode for first-time logins (config spelling; parsed at
    /// boot, same contract as /gamemode).
    gamemode: []const u8 = "creative",
    /// World difficulty (config spelling; parsed at boot, same contract
    /// as /difficulty).
    difficulty: []const u8 = "easy",
    /// Vanilla pvp flag.
    pvp: bool = true,
    /// Vanilla force-gamemode flag.
    force_gamemode: bool = false,
    /// Minutes until idle kick (0 = never).
    idle_timeout: u32 = 0,
    /// Periodic autosave.
    autosave: bool = true,
    /// Gamerule boot overrides (borrowed object or null; applied after
    /// validate in main).
    gamerules: ?std.json.Value = null,
    /// Natural-spawn master switch.
    spawn_mobs: bool = true,
    /// Per-kind spawn allowlist (borrowed object or null; resolved to an
    /// allow array in main).
    mob_spawns: ?std.json.Value = null,
    /// Bind address.
    bind_address: []const u8 = "0.0.0.0",
    /// Kernel accept backlog.
    backlog: u16 = 4096,
    /// io_uring ring entries.
    io_uring_entries: u16 = 256,
    /// Simulation radius placeholder (stored; ticking follows view).
    simulation_distance: u8 = 10,
    /// Packet compression threshold, -1 disables (stored; no path yet).
    compression_threshold: i64 = -1,
    /// Compression level (stored).
    compression_level: u8 = 3,
    /// Max NBT depth guard (stored; NBT rides opaque today).
    max_nbt_depth: u32 = 32,
    /// Max string length (stored; chat buffers are fixed 1024 today).
    max_string_length: u32 = 32767,
    /// Region-file cache size placeholder (LSM has no region files).
    region_cache_size: u32 = 256,
    /// Disk auto-flush interval, seconds (stored; WAL + autosave rule).
    disk_flush_interval: u32 = 30,
    /// Memtable size override in bytes (null = storage profile default).
    flush_threshold_bytes: ?usize = null,
    /// Auto-compact SST threshold override (null = profile default).
    /// Counts newest contiguous fragment runs only (0 = manual).
    compact_threshold_ssts: ?usize = null,
    /// Wasm plugins enabled (no runtime exists).
    wasm_enabled: bool = false,
    /// Per-plugin memory cap, megabytes.
    wasm_max_memory_mb: u32 = 128,
    /// Per-tick instruction gas per plugin callback.
    wasm_instruction_limit: u64 = 10000000,
    /// Telemetry enabled (no exporter exists; stats log only).
    telemetry_enabled: bool = false,
    /// MSPT sampling interval, milliseconds.
    telemetry_sampling_ms: u32 = 50,
    /// Prometheus exporter enabled.
    telemetry_prometheus: bool = false,
    /// Prometheus port.
    telemetry_prometheus_port: u16 = 9090,
    /// Chat flood budget: window milliseconds.
    chat_rate_window_ms: i64 = ratelimit.default_chat_window_ms,
    /// Chat flood budget: chats allowed inside one window.
    chat_rate_burst: usize = ratelimit.default_chat_burst,
    /// Consecutive-dig flood budget: window milliseconds.
    dig_rate_window_ms: i64 = ratelimit.default_dig_window_ms,
    /// Consecutive-dig flood budget: digs allowed per window.
    dig_rate_burst: usize = ratelimit.default_dig_burst,
    /// Global packets-per-second cap per conn (0 = off).
    max_packets_per_second: u32 = 0,
    /// Max inbound frame length in bytes.
    max_packet_size: usize = 2 * 1024 * 1024,
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
    /// sim/core/ratelimit.zig cap the burst).
    login_rate_window_ms: i64 = ratelimit.default_login_window_ms,
    login_rate_burst: usize = ratelimit.default_login_burst,
    /// Placement flood budget: placements allowed per window per conn.
    place_rate_window_ms: i64 = ratelimit.default_place_window_ms,
    place_rate_burst: usize = ratelimit.default_place_burst,
    /// Phase G: GPU offload backend.
    gpu: []const u8 = "off",
    /// Phase G: per-tick GPU dispatch budget, ms (stored; v2 async use).
    gpu_budget_ms: u32 = 4,
    /// Phase G: max chunks per GPU dispatch.
    gpu_max_batch: usize = 16,
    /// Phase G: GPU device preference.
    gpu_device: []const u8 = "auto",
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
    BadGamemode,
    BadDifficulty,
    BadGamerules,
    BadMobSpawns,
    BadChatRate,
    BadDigRate,
    BadBindAddress,
    BadBacklog,
    BadUringEntries,
    BadPacketSize,
    BadCompressionLevel,
    BadPrometheusPort,
    BadTransport,
    BadStorageProfile,
    BadLoginRate,
    BadPlaceRate,
    BadGpu,
    BadGpuBudget,
    BadGpuBatch,
    BadGpuDevice,
};

/// Protocol/gameplay sanity checks. View is capped at 16: the 1.7.10
/// client never requests more and chunk packets assume it.
pub fn validate(c: *const Effective) ValidateError!void {
    if (c.port == 0) return error.BadPort;
    if (c.view_distance < 1 or c.view_distance > 16) return error.BadViewDistance;
    if (c.gen_spawn != null and c.gen_spawn.? < 0) return error.BadGenSpawn;
    if (c.gen_workers != null and c.gen_workers.? == 0) return error.BadGenWorkers;
    if (c.rcon_port == 0 and c.rcon_password != null) return error.BadRconPort;
    if (c.max_players == 0 or c.max_players > 1024) return error.BadMaxPlayers;
    if (!isKnownBrand(c.brand)) return error.BadBrand;
    if (!isKnownGamemode(c.gamemode)) return error.BadGamemode;
    if (!isKnownDifficulty(c.difficulty)) return error.BadDifficulty;
    if (c.gamerules) |g| {
        if (g != .object) return error.BadGamerules;
        var it = g.object.iterator();
        while (it.next()) |kv| {
            if (!isKnownGamerule(kv.key_ptr.*)) return error.BadGamerules;
            if (kv.value_ptr.* != .bool) return error.BadGamerules;
        }
    }
    if (c.mob_spawns) |m| {
        if (m != .object) return error.BadMobSpawns;
        var it = m.object.iterator();
        while (it.next()) |kv| {
            if (!isKnownMobKind(kv.key_ptr.*)) return error.BadMobSpawns;
            if (kv.value_ptr.* != .bool) return error.BadMobSpawns;
        }
    }
    // Flood gates: windows below the noise floor are rejected; bursts
    // are capped by the fixed window capacities (see sim/core/ratelimit.zig).
    // The chat burst is a plain counter (no fixed array), so only the
    // floor applies there.
    if (c.chat_rate_window_ms < ratelimit.min_window_ms or c.chat_rate_burst < 1) return error.BadChatRate;
    if (c.dig_rate_window_ms < ratelimit.min_window_ms or c.dig_rate_burst < 1 or c.dig_rate_burst > ratelimit.dig_window_capacity) return error.BadDigRate;
    _ = std.Io.net.IpAddress.parse(c.bind_address, 1) catch return error.BadBindAddress;
    if (c.backlog == 0) return error.BadBacklog;
    if (c.io_uring_entries < 1 or c.io_uring_entries > 8192 or !std.math.isPowerOfTwo(c.io_uring_entries)) return error.BadUringEntries;
    if (c.max_packet_size < 1024 * 1024 or c.max_packet_size > 16 * 1024 * 1024) return error.BadPacketSize;
    if (c.compression_level < 1 or c.compression_level > 9) return error.BadCompressionLevel;
    if (c.telemetry_prometheus_port == 0) return error.BadPrometheusPort;
    if (!isKnownTransport(c.transport)) return error.BadTransport;
    if (!isKnownStorageProfile(c.storage_profile)) return error.BadStorageProfile;
    if (c.login_rate_window_ms < ratelimit.min_window_ms or c.login_rate_burst < 1 or c.login_rate_burst > ratelimit.login_window_capacity) return error.BadLoginRate;
    if (c.place_rate_window_ms < ratelimit.min_window_ms or c.place_rate_burst < 1 or c.place_rate_burst > ratelimit.place_window_capacity) return error.BadPlaceRate;
    if (!isKnownGpu(c.gpu)) return error.BadGpu;
    if (c.gpu_budget_ms < 1 or c.gpu_budget_ms > 50) return error.BadGpuBudget;
    if (c.gpu_max_batch < 1 or c.gpu_max_batch > 64) return error.BadGpuBatch;
    if (!isKnownGpuDevice(c.gpu_device)) return error.BadGpuDevice;
}

/// True when `s` is one of `known` (config spelling allowlists).
fn isOneOf(s: []const u8, known: []const []const u8) bool {
    for (known) |k| {
        if (std.mem.eql(u8, s, k)) return true;
    }
    return false;
}

/// Accepted storage-profile spellings (Phase B NVMe path).
pub fn isKnownStorageProfile(s: []const u8) bool {
    return isOneOf(s, &.{ "auto", "hdd", "ssd", "nvme" });
}

/// Accepted transport spellings (Phase B).
pub fn isKnownTransport(s: []const u8) bool {
    return isOneOf(s, &.{ "auto", "uring", "kqueue", "iocp", "blocking" });
}

/// Accepted GPU backend spellings (Phase G1: off or headless Vulkan).
pub fn isKnownGpu(s: []const u8) bool {
    return isOneOf(s, &.{ "off", "vulkan" });
}

/// Accepted GPU device preferences (Phase G device pick).
pub fn isKnownGpuDevice(s: []const u8) bool {
    return isOneOf(s, &.{ "auto", "discrete", "integrated", "cpu" });
}

/// Accepted `brand` spellings (mirrors status.Brand.parse; kept as plain
/// strings here so config.zig stays dependency-free).
pub fn isKnownBrand(s: []const u8) bool {
    return isOneOf(s, &.{ "vanilla", "fabric", "forge", "fml" });
}

/// Accepted `gamemode` spellings (full names + s/c/a + 0/1/2, any case).
/// The single implementation is game/rules GameMode.parse (shared with
/// /gamemode); this is the validation alias, like isKnownBrand.
pub fn isKnownGamemode(s: []const u8) bool {
    return @import("asteorite").rules.GameMode.parse(s) != null;
}

/// Accepted `difficulty` spellings (full names + p/e/n/h + 0-3, any
/// case). Single implementation in game/rules, shared with /difficulty.
pub fn isKnownDifficulty(s: []const u8) bool {
    return @import("asteorite").rules.Difficulty.parse(s) != null;
}

/// Accepted gamerule names (exact vanilla camelCase, like /gamerule).
/// Single source is the default table in proto/v5/cmd_data (shared with
/// the /gamerule command); reached through the main module so config.zig
/// needs no direct protocol import (import gate).
pub fn isKnownGamerule(s: []const u8) bool {
    for (@import("asteorite").cmd_data.gamerules) |g| {
        if (std.mem.eql(u8, g.name, s)) return true;
    }
    return false;
}

/// Accepted mob kind names (canonical tag spellings, case-insensitive).
/// Single implementation in game/mob (shared with the spawn gate).
pub fn isKnownMobKind(s: []const u8) bool {
    return @import("asteorite").mob.parse(s) != null;
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
        error.BadMaxPlayers => "max_players must be 1-1024 (fan-out cap)",
        error.BadBrand => "brand must be vanilla, fabric, or forge",
        error.BadGamemode => "gamemode must be survival, creative, or adventure (s/c/a or 0/1/2 also accepted)",
        error.BadDifficulty => "difficulty must be peaceful, easy, normal, or hard (p/e/n/h or 0-3 also accepted)",
        error.BadGamerules => "gamerules must be an object of known gamerule names to booleans (e.g. {\"keepInventory\": true})",
        error.BadMobSpawns => "mob_spawns must be an object of mob kind names to booleans (e.g. {\"zombie\": false})",
        error.BadChatRate => comptime std.fmt.comptimePrint("chat_rate_window_ms must be >= {d}, chat_rate_burst at least 1", .{ratelimit.min_window_ms}),
        error.BadDigRate => comptime std.fmt.comptimePrint("dig_rate_window_ms must be >= {d}, dig_rate_burst 1..{d}", .{ ratelimit.min_window_ms, ratelimit.dig_window_capacity }),
        error.BadBindAddress => "bind_address must be a valid IP address (e.g. \"0.0.0.0\")",
        error.BadBacklog => "backlog must be 1-65535",
        error.BadUringEntries => "io_uring_entries must be a power of two, 1-8192",
        error.BadPacketSize => "max_packet_size must be 1048576-16777216 (1-16 MiB)",
        error.BadCompressionLevel => "compression_level must be 1-9",
        error.BadPrometheusPort => "telemetry_prometheus_port must be 1-65535",
        error.BadTransport => "transport must be auto, uring, kqueue, iocp, or blocking",
        error.BadStorageProfile => "storage_profile must be auto, hdd, ssd, or nvme",
        error.BadLoginRate => comptime std.fmt.comptimePrint("login_rate_window_ms must be >= {d}, login_rate_burst 1..{d}", .{ ratelimit.min_window_ms, ratelimit.login_window_capacity }),
        error.BadPlaceRate => comptime std.fmt.comptimePrint("place_rate_window_ms must be >= {d}, place_rate_burst 1..{d}", .{ ratelimit.min_window_ms, ratelimit.place_window_capacity }),
        error.BadGpu => "gpu must be off or vulkan",
        error.BadGpuBudget => "gpu_budget_ms must be 1-50",
        error.BadGpuBatch => "gpu_max_batch must be 1-64",
        error.BadGpuDevice => "gpu_device must be auto, discrete, integrated, or cpu",
    };
}

/// Top-level section names: the only allowed top-level config keys.
/// Anything else is a legacy flat key or a typo — fail closed (a silently
/// dropped "seed" would mint a random world). No legacy key names live in
/// the code; the allowlist alone rejects every old file.
pub const sections: []const []const u8 = &.{
    "server", "world", "network", "storage", "rates", "telemetry", "wasm", "gpu",
};

pub const DecodeError = error{
    UnknownSection,
    UnknownKey,
    BadType,
    OutOfMemory,
};

/// Parse a TOML config document into a FileConfig. `backing` owns all
/// strings/slices (pass an arena). Unknown tables and unknown keys are
/// hard errors; legacy flat keys land here (root pairs are not tables).
pub fn parseToml(backing: std.mem.Allocator, text: []const u8) (toml.Error || DecodeError)!FileConfig {
    const root = try toml.parse(backing, text);
    var file = FileConfig{};
    for (root) |e| {
        if (e.value != .table) return error.UnknownSection;
        if (std.mem.eql(u8, e.key, "server")) {
            var s = FileServer{};
            try decodeServer(&s, backing, e.value.table);
            file.server = s;
        } else if (std.mem.eql(u8, e.key, "world")) {
            var w = FileWorld{};
            try decodeWorld(&w, backing, e.value.table);
            file.world = w;
        } else if (std.mem.eql(u8, e.key, "network")) {
            var n = FileNetwork{};
            try decodeNetwork(&n, e.value.table);
            file.network = n;
        } else if (std.mem.eql(u8, e.key, "storage")) {
            var st = FileStorage{};
            try decodeStorage(&st, e.value.table);
            file.storage = st;
        } else if (std.mem.eql(u8, e.key, "rates")) {
            var r = FileRates{};
            try decodeRates(&r, e.value.table);
            file.rates = r;
        } else if (std.mem.eql(u8, e.key, "telemetry")) {
            var t = FileTelemetry{};
            try decodeTelemetry(&t, e.value.table);
            file.telemetry = t;
        } else if (std.mem.eql(u8, e.key, "wasm")) {
            var w = FileWasm{};
            try decodeWasm(&w, e.value.table);
            file.wasm = w;
        } else if (std.mem.eql(u8, e.key, "gpu")) {
            var g = FileGpu{};
            try decodeGpu(&g, e.value.table);
            file.gpu = g;
        } else return error.UnknownSection;
    }
    return file;
}

fn asBool(v: toml.Value) DecodeError!bool {
    return switch (v) {
        .boolean => |b| b,
        else => error.BadType,
    };
}

fn asString(v: toml.Value) DecodeError![]const u8 {
    return switch (v) {
        .string => |s| s,
        else => error.BadType,
    };
}

fn asInt(v: toml.Value) DecodeError!i64 {
    return switch (v) {
        .int => |n| n,
        else => error.BadType,
    };
}

fn asU16(v: toml.Value) DecodeError!u16 {
    const n = try asInt(v);
    if (n < 0 or n > 65535) return error.BadType;
    return @intCast(n);
}

fn asU8(v: toml.Value) DecodeError!u8 {
    const n = try asInt(v);
    if (n < 0 or n > 255) return error.BadType;
    return @intCast(n);
}

fn asU32(v: toml.Value) DecodeError!u32 {
    const n = try asInt(v);
    if (n < 0 or n > 0xffff_ffff) return error.BadType;
    return @intCast(n);
}

fn asU64(v: toml.Value) DecodeError!u64 {
    const n = try asInt(v);
    if (n < 0) return error.BadType;
    return @intCast(n);
}

fn asUsize(v: toml.Value) DecodeError!usize {
    const n = try asInt(v);
    if (n < 0) return error.BadType;
    return @intCast(n);
}

fn asI32(v: toml.Value) DecodeError!i32 {
    const n = try asInt(v);
    if (n < -0x8000_0000 or n > 0x7fff_ffff) return error.BadType;
    return @intCast(n);
}

fn asStringArray(backing: std.mem.Allocator, v: toml.Value) DecodeError![][]const u8 {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadType,
    };
    const out = backing.alloc([]const u8, arr.len) catch return error.OutOfMemory;
    for (arr, 0..) |item, i| out[i] = try asString(item);
    return out;
}

/// Seed union: TOML integer or string (floats are stored and rejected
/// later by resolveSeed with the tailored message, like the JSON era).
fn asSeed(backing: std.mem.Allocator, v: toml.Value) DecodeError!std.json.Value {
    _ = backing;
    return switch (v) {
        .int => |n| .{ .integer = n },
        .string => |s| .{ .string = s },
        .float => |f| .{ .float = f },
        else => error.BadType,
    };
}

/// Gamerule/mob-spawn maps: `{ name = bool }` inline tables.
fn asBoolMap(backing: std.mem.Allocator, v: toml.Value) DecodeError!std.json.Value {
    const t = switch (v) {
        .table => |entries| entries,
        else => return error.BadType,
    };
    var m = std.json.ObjectMap.init(backing, &.{}, &.{}) catch return error.OutOfMemory;
    errdefer m.deinit(backing);
    for (t) |e| {
        const b = try asBool(e.value);
        m.put(backing, e.key, .{ .bool = b }) catch return error.OutOfMemory;
    }
    return .{ .object = m };
}

fn decodeServer(s: *FileServer, backing: std.mem.Allocator, t: []const toml.Entry) DecodeError!void {
    for (t) |e| {
        if (std.mem.eql(u8, e.key, "port")) { s.port = try asU16(e.value); }
        else if (std.mem.eql(u8, e.key, "online")) { s.online = try asBool(e.value); }
        else if (std.mem.eql(u8, e.key, "db")) { s.db = try asString(e.value); }
        else if (std.mem.eql(u8, e.key, "view_distance")) { s.view_distance = try asU8(e.value); }
        else if (std.mem.eql(u8, e.key, "motd")) { s.motd = try asString(e.value); }
        else if (std.mem.eql(u8, e.key, "max_players")) { s.max_players = try asU16(e.value); }
        else if (std.mem.eql(u8, e.key, "brand")) { s.brand = try asString(e.value); }
        else if (std.mem.eql(u8, e.key, "ops")) { s.ops = try asStringArray(backing, e.value); }
        else if (std.mem.eql(u8, e.key, "rcon_password")) { s.rcon_password = try asString(e.value); }
        else if (std.mem.eql(u8, e.key, "rcon_port")) { s.rcon_port = try asU16(e.value); }
        else if (std.mem.eql(u8, e.key, "idle_timeout")) { s.idle_timeout = try asU32(e.value); }
        else if (std.mem.eql(u8, e.key, "autosave")) { s.autosave = try asBool(e.value); }
        else return error.UnknownKey;
    }
}

fn decodeWorld(w: *FileWorld, backing: std.mem.Allocator, t: []const toml.Entry) DecodeError!void {
    for (t) |e| {
        if (std.mem.eql(u8, e.key, "seed")) { w.seed = try asSeed(backing, e.value); }
        else if (std.mem.eql(u8, e.key, "gen_spawn")) { w.gen_spawn = try asI32(e.value); }
        else if (std.mem.eql(u8, e.key, "gen_workers")) { w.gen_workers = try asUsize(e.value); }
        else if (std.mem.eql(u8, e.key, "region_threads")) { w.region_threads = try asUsize(e.value); }
        else if (std.mem.eql(u8, e.key, "gamemode")) { w.gamemode = try asString(e.value); }
        else if (std.mem.eql(u8, e.key, "difficulty")) { w.difficulty = try asString(e.value); }
        else if (std.mem.eql(u8, e.key, "pvp")) { w.pvp = try asBool(e.value); }
        else if (std.mem.eql(u8, e.key, "force_gamemode")) { w.force_gamemode = try asBool(e.value); }
        else if (std.mem.eql(u8, e.key, "gamerules")) { w.gamerules = try asBoolMap(backing, e.value); }
        else if (std.mem.eql(u8, e.key, "spawn_mobs")) { w.spawn_mobs = try asBool(e.value); }
        else if (std.mem.eql(u8, e.key, "mob_spawns")) { w.mob_spawns = try asBoolMap(backing, e.value); }
        else if (std.mem.eql(u8, e.key, "simulation_distance")) { w.simulation_distance = try asU8(e.value); }
        else return error.UnknownKey;
    }
}

fn decodeNetwork(n: *FileNetwork, t: []const toml.Entry) DecodeError!void {
    for (t) |e| {
        if (std.mem.eql(u8, e.key, "bind_address")) { n.bind_address = try asString(e.value); }
        else if (std.mem.eql(u8, e.key, "backlog")) { n.backlog = try asU16(e.value); }
        else if (std.mem.eql(u8, e.key, "io_uring_entries")) { n.io_uring_entries = try asU16(e.value); }
        else if (std.mem.eql(u8, e.key, "transport")) { n.transport = try asString(e.value); }
        else if (std.mem.eql(u8, e.key, "transport_workers")) { n.transport_workers = try asUsize(e.value); }
        else if (std.mem.eql(u8, e.key, "tcp_nodelay")) { n.tcp_nodelay = try asBool(e.value); }
        else if (std.mem.eql(u8, e.key, "sndbuf")) { n.sndbuf = try asUsize(e.value); }
        else if (std.mem.eql(u8, e.key, "rcvbuf")) { n.rcvbuf = try asUsize(e.value); }
        else if (std.mem.eql(u8, e.key, "max_packets_per_second")) { n.max_packets_per_second = try asU32(e.value); }
        else if (std.mem.eql(u8, e.key, "max_packet_size")) { n.max_packet_size = try asUsize(e.value); }
        else if (std.mem.eql(u8, e.key, "compression_threshold")) { n.compression_threshold = try asInt(e.value); }
        else if (std.mem.eql(u8, e.key, "compression_level")) { n.compression_level = try asU8(e.value); }
        else if (std.mem.eql(u8, e.key, "max_nbt_depth")) { n.max_nbt_depth = try asU32(e.value); }
        else if (std.mem.eql(u8, e.key, "max_string_length")) { n.max_string_length = try asU32(e.value); }
        else if (std.mem.eql(u8, e.key, "out_cap_bytes")) { n.out_cap_bytes = try asUsize(e.value); }
        else if (std.mem.eql(u8, e.key, "send_zc_threshold")) { n.send_zc_threshold = try asUsize(e.value); }
        else return error.UnknownKey;
    }
}

fn decodeStorage(st: *FileStorage, t: []const toml.Entry) DecodeError!void {
    for (t) |e| {
        if (std.mem.eql(u8, e.key, "storage_profile")) { st.storage_profile = try asString(e.value); }
        else if (std.mem.eql(u8, e.key, "region_cache_size")) { st.region_cache_size = try asU32(e.value); }
        else if (std.mem.eql(u8, e.key, "disk_flush_interval")) { st.disk_flush_interval = try asU32(e.value); }
        else if (std.mem.eql(u8, e.key, "flush_threshold_bytes")) { st.flush_threshold_bytes = try asUsize(e.value); }
        else if (std.mem.eql(u8, e.key, "compact_threshold_ssts")) { st.compact_threshold_ssts = try asUsize(e.value); }
        else return error.UnknownKey;
    }
}

fn decodeRates(r: *FileRates, t: []const toml.Entry) DecodeError!void {
    for (t) |e| {
        if (std.mem.eql(u8, e.key, "chat_rate_window_ms")) { r.chat_rate_window_ms = try asInt(e.value); }
        else if (std.mem.eql(u8, e.key, "chat_rate_burst")) { r.chat_rate_burst = try asUsize(e.value); }
        else if (std.mem.eql(u8, e.key, "dig_rate_window_ms")) { r.dig_rate_window_ms = try asInt(e.value); }
        else if (std.mem.eql(u8, e.key, "dig_rate_burst")) { r.dig_rate_burst = try asUsize(e.value); }
        else if (std.mem.eql(u8, e.key, "login_rate_window_ms")) { r.login_rate_window_ms = try asInt(e.value); }
        else if (std.mem.eql(u8, e.key, "login_rate_burst")) { r.login_rate_burst = try asUsize(e.value); }
        else if (std.mem.eql(u8, e.key, "place_rate_window_ms")) { r.place_rate_window_ms = try asInt(e.value); }
        else if (std.mem.eql(u8, e.key, "place_rate_burst")) { r.place_rate_burst = try asUsize(e.value); }
        else return error.UnknownKey;
    }
}

fn decodeTelemetry(t: *FileTelemetry, tbl: []const toml.Entry) DecodeError!void {
    for (tbl) |e| {
        if (std.mem.eql(u8, e.key, "telemetry_enabled")) { t.telemetry_enabled = try asBool(e.value); }
        else if (std.mem.eql(u8, e.key, "telemetry_sampling_ms")) { t.telemetry_sampling_ms = try asU32(e.value); }
        else if (std.mem.eql(u8, e.key, "telemetry_prometheus")) { t.telemetry_prometheus = try asBool(e.value); }
        else if (std.mem.eql(u8, e.key, "telemetry_prometheus_port")) { t.telemetry_prometheus_port = try asU16(e.value); }
        else return error.UnknownKey;
    }
}

fn decodeWasm(w: *FileWasm, t: []const toml.Entry) DecodeError!void {
    for (t) |e| {
        if (std.mem.eql(u8, e.key, "wasm_enabled")) { w.wasm_enabled = try asBool(e.value); }
        else if (std.mem.eql(u8, e.key, "wasm_max_memory_mb")) { w.wasm_max_memory_mb = try asU32(e.value); }
        else if (std.mem.eql(u8, e.key, "wasm_instruction_limit")) { w.wasm_instruction_limit = try asU64(e.value); }
        else return error.UnknownKey;
    }
}

fn decodeGpu(g: *FileGpu, t: []const toml.Entry) DecodeError!void {
    for (t) |e| {
        if (std.mem.eql(u8, e.key, "gpu")) { g.gpu = try asString(e.value); }
        else if (std.mem.eql(u8, e.key, "gpu_budget_ms")) { g.gpu_budget_ms = try asU32(e.value); }
        else if (std.mem.eql(u8, e.key, "gpu_max_batch")) { g.gpu_max_batch = try asUsize(e.value); }
        else if (std.mem.eql(u8, e.key, "gpu_device")) { g.gpu_device = try asString(e.value); }
        else return error.UnknownKey;
    }
}

/// Per-key documentation for the rendered config file. `example` is the
/// TOML value snippet used (commented out) when the effective value is
/// null — TOML has no null, so unset keys render as disabled examples.
const KeyDoc = struct {
    section: []const u8,
    key: []const u8,
    doc: []const u8,
    example: ?[]const u8 = null,
};

const key_docs: []const KeyDoc = &.{
    .{ .section = "server", .key = "port", .doc = "TCP port (1-65535)." },
    .{ .section = "server", .key = "online", .doc = "Mojang auth (offline UUIDs when false)." },
    .{ .section = "server", .key = "db", .doc = "World folder (vanilla name).", .example = "\"world\"" },
    .{ .section = "server", .key = "view_distance", .doc = "Chunk view radius (1-16, 1.7.10 client cap)." },
    .{ .section = "server", .key = "motd", .doc = "Server list message (multiplayer menu)." },
    .{ .section = "server", .key = "max_players", .doc = "Server list player cap (1-1024)." },
    .{ .section = "server", .key = "brand", .doc = "Handshake brand: vanilla, fabric, or forge." },
    .{ .section = "server", .key = "ops", .doc = "Console operators (repeat --op works too)." },
    .{ .section = "server", .key = "rcon_password", .doc = "RCON password (unset disables RCON).", .example = "\"choose-a-long-random-secret\"" },
    .{ .section = "server", .key = "rcon_port", .doc = "RCON port." },
    .{ .section = "server", .key = "idle_timeout", .doc = "Minutes until idle kick (0 = never)." },
    .{ .section = "server", .key = "autosave", .doc = "Periodic autosave every 5 minutes." },
    .{ .section = "world", .key = "seed", .doc = "Int64 or string (hashed Java-style); absent = random + loud log.", .example = "42" },
    .{ .section = "world", .key = "gen_spawn", .doc = "Spawn disk radius pre-generated at boot.", .example = "4" },
    .{ .section = "world", .key = "gen_workers", .doc = "Background gen threads.", .example = "4" },
    .{ .section = "world", .key = "region_threads", .doc = "Region tick threads (0 = auto)." },
    .{ .section = "world", .key = "gamemode", .doc = "Default gamemode: survival, creative, adventure." },
    .{ .section = "world", .key = "difficulty", .doc = "peaceful, easy, normal, or hard." },
    .{ .section = "world", .key = "pvp", .doc = "Player-vs-player damage." },
    .{ .section = "world", .key = "force_gamemode", .doc = "Re-apply default gamemode to returning players." },
    .{ .section = "world", .key = "gamerules", .doc = "Vanilla gamerule overrides.", .example = "{ keepInventory = true }" },
    .{ .section = "world", .key = "spawn_mobs", .doc = "Natural mob spawn master switch." },
    .{ .section = "world", .key = "mob_spawns", .doc = "Per-kind spawn allowlist.", .example = "{ zombie = false }" },
    .{ .section = "world", .key = "simulation_distance", .doc = "Placeholder (ticking follows view distance)." },
    .{ .section = "network", .key = "bind_address", .doc = "Listen interface (0.0.0.0 = all)." },
    .{ .section = "network", .key = "backlog", .doc = "Kernel accept backlog." },
    .{ .section = "network", .key = "io_uring_entries", .doc = "Ring entries, power of two 1-8192." },
    .{ .section = "network", .key = "transport", .doc = "Backend: auto, uring, kqueue, iocp, blocking." },
    .{ .section = "network", .key = "transport_workers", .doc = "Transport threads (0 = auto)." },
    .{ .section = "network", .key = "tcp_nodelay", .doc = "TCP_NODELAY on accepted sockets." },
    .{ .section = "network", .key = "sndbuf", .doc = "Socket send buffer (0 = OS default)." },
    .{ .section = "network", .key = "rcvbuf", .doc = "Socket receive buffer (0 = OS default)." },
    .{ .section = "network", .key = "max_packets_per_second", .doc = "Per-conn packet cap (0 = off)." },
    .{ .section = "network", .key = "max_packet_size", .doc = "Max inbound frame bytes (1-16 MiB)." },
    .{ .section = "network", .key = "compression_threshold", .doc = "Compression bytes (-1 = off; no path yet)." },
    .{ .section = "network", .key = "compression_level", .doc = "Compression level 1-9." },
    .{ .section = "network", .key = "max_nbt_depth", .doc = "NBT depth guard (rides opaque today)." },
    .{ .section = "network", .key = "max_string_length", .doc = "Max chat/channel string bytes." },
    .{ .section = "network", .key = "out_cap_bytes", .doc = "Per-connection outbox cap." },
    .{ .section = "network", .key = "send_zc_threshold", .doc = "Zerocopy send threshold bytes." },
    .{ .section = "storage", .key = "storage_profile", .doc = "auto, hdd, ssd, or nvme." },
    .{ .section = "storage", .key = "region_cache_size", .doc = "Placeholder (LSM has no region files)." },
    .{ .section = "storage", .key = "disk_flush_interval", .doc = "Placeholder (WAL + autosave rule)." },
    .{ .section = "storage", .key = "flush_threshold_bytes", .doc = "Memtable bytes before background SST flush (profile default).", .example = "67108864" },
    .{ .section = "storage", .key = "compact_threshold_ssts", .doc = "Auto-compact at this many fragment runs (profile default; 0 = manual).", .example = "32" },
    .{ .section = "rates", .key = "chat_rate_window_ms", .doc = "Chat flood window milliseconds." },
    .{ .section = "rates", .key = "chat_rate_burst", .doc = "Chats allowed per window." },
    .{ .section = "rates", .key = "dig_rate_window_ms", .doc = "Dig flood window milliseconds." },
    .{ .section = "rates", .key = "dig_rate_burst", .doc = "Digs allowed per window." },
    .{ .section = "rates", .key = "login_rate_window_ms", .doc = "Login flood window milliseconds." },
    .{ .section = "rates", .key = "login_rate_burst", .doc = "Joins allowed per window per IP." },
    .{ .section = "rates", .key = "place_rate_window_ms", .doc = "Placement flood window milliseconds." },
    .{ .section = "rates", .key = "place_rate_burst", .doc = "Placements allowed per window per conn." },
    .{ .section = "telemetry", .key = "telemetry_enabled", .doc = "Stats logging (no exporter yet)." },
    .{ .section = "telemetry", .key = "telemetry_sampling_ms", .doc = "MSPT sampling interval." },
    .{ .section = "telemetry", .key = "telemetry_prometheus", .doc = "Prometheus exporter (needs work)." },
    .{ .section = "telemetry", .key = "telemetry_prometheus_port", .doc = "Prometheus port." },
    .{ .section = "wasm", .key = "wasm_enabled", .doc = "Sandboxed plugins (no runtime yet)." },
    .{ .section = "wasm", .key = "wasm_max_memory_mb", .doc = "Per-plugin memory cap." },
    .{ .section = "wasm", .key = "wasm_instruction_limit", .doc = "Per-tick instruction gas per callback." },
    .{ .section = "gpu", .key = "gpu", .doc = "Offload backend: off or vulkan." },
    .{ .section = "gpu", .key = "gpu_budget_ms", .doc = "Dispatch budget ms (stored for v2)." },
    .{ .section = "gpu", .key = "gpu_max_batch", .doc = "Max chunks per dispatch (1-64)." },
    .{ .section = "gpu", .key = "gpu_device", .doc = "Pick: auto, discrete, integrated, cpu." },
};

comptime {
    // Every section field must be documented exactly once, and every
    // nullable rendered field must carry a commented example.
    // Compile-time: docs can never drift from the schema.
    @setEvalBranchQuota(1000000);
    for (@typeInfo(FileConfig).@"struct".fields) |sf| {
        const Section = @typeInfo(sf.type).optional.child;
        for (@typeInfo(Section).@"struct".fields) |f| {
            var found = false;
            for (key_docs) |d| {
                if (std.mem.eql(u8, d.section, sf.name) and std.mem.eql(u8, d.key, f.name)) {
                    if (found) @compileError("duplicate key_docs entry");
                    found = true;
                    const ET = @typeInfo(@TypeOf(@field(Effective{}, d.key)));
                    if (ET == .optional and d.example == null) @compileError("nullable key needs an example");
                }
            }
            if (!found) @compileError("key_docs missing an entry");
        }
    }
}

/// Render an Effective config as commented TOML for first-boot file
/// creation. Nulls render as commented-out examples (TOML has no null), so
/// the file documents every setting. Round-trips through parseToml+merge
/// back to an equal Effective (covered below).
pub fn renderDefaults(alloc: std.mem.Allocator, eff: *const Effective) ![]u8 {
    @setEvalBranchQuota(10000); // unrolls ~70 doc entries; grows with keys
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("# Asteorite server config. Every section and key is optional;\n# CLI flags override file keys. Unknown tables/keys fail boot.\n");
    inline for (sections) |s| {
        try w.print("\n# {s}.\n[{s}]\n", .{ sectionDoc(s), s });
        inline for (key_docs) |d| {
            if (!comptime std.mem.eql(u8, d.section, s)) continue;
            const v = @field(eff, d.key);
            const TI = @typeInfo(@TypeOf(v));
            if (TI == .optional and v == null) {
                try w.print("# {s}\n# {s} = {s}\n", .{ d.doc, d.key, d.example.? });
            } else {
                try w.print("# {s}\n{s} = ", .{ d.doc, d.key });
                if (TI == .optional) {
                    try writeTomlValue(w, v.?);
                } else {
                    try writeTomlValue(w, v);
                }
                try w.writeAll("\n");
            }
        }
    }
    return try alloc.dupe(u8, aw.written());
}

fn sectionDoc(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "server")) return "Identity and presence";
    if (std.mem.eql(u8, name, "world")) return "World generation and gameplay";
    if (std.mem.eql(u8, name, "network")) return "Sockets, transport, and protocol guards";
    if (std.mem.eql(u8, name, "storage")) return "On-disk store";
    if (std.mem.eql(u8, name, "rates")) return "Anti-flood budgets (windows are milliseconds)";
    if (std.mem.eql(u8, name, "telemetry")) return "Performance telemetry";
    if (std.mem.eql(u8, name, "wasm")) return "Sandboxed plugins";
    if (std.mem.eql(u8, name, "gpu")) return "GPU chunk-gen offload";
    unreachable;
}

fn writeTomlString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    const hexd = "0123456789abcdef";
                    try w.writeAll("\\u00");
                    try w.writeByte(hexd[c >> 4]);
                    try w.writeByte(hexd[c & 0xf]);
                } else try w.writeByte(c);
            },
        }
    }
    try w.writeByte('"');
}

fn writeTomlValue(w: *std.Io.Writer, v: anytype) !void {
    const T = @TypeOf(v);
    if (T == std.json.Value) {
        switch (v) {
            .integer => |n| try w.print("{d}", .{n}),
            .string => |s| try writeTomlString(w, s),
            .bool => |b| try w.writeAll(if (b) "true" else "false"),
            .object => |o| {
                if (o.count() == 0) {
                    try w.writeAll("{}");
                } else {
                    try w.writeAll("{ ");
                    var it = o.iterator();
                    var first = true;
                    while (it.next()) |kv| {
                        if (!first) try w.writeAll(", ");
                        first = false;
                        try writeTomlString(w, kv.key_ptr.*);
                        try w.writeAll(" = ");
                        try writeTomlValue(w, kv.value_ptr.*);
                    }
                    try w.writeAll(" }");
                }
            },
            .array => |a| {
                if (a.items.len == 0) {
                    try w.writeAll("[]");
                } else {
                    try w.writeAll("[ ");
                    for (a.items, 0..) |item, i| {
                        if (i > 0) try w.writeAll(", ");
                        try writeTomlValue(w, item);
                    }
                    try w.writeAll(" ]");
                }
            },
            .float => |f| try w.print("{d}", .{f}),
            .null => try w.writeAll("\"<null>\""),
            .number_string => |s| try writeTomlString(w, s),
        }
        return;
    }
    switch (@typeInfo(T)) {
        .int => try w.print("{d}", .{v}),
        .bool => try w.writeAll(if (v) "true" else "false"),
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                try writeTomlString(w, v);
            } else if (ptr.size == .slice) {
                // ops: array of strings.
                if (v.len == 0) {
                    try w.writeAll("[]");
                } else {
                    try w.writeAll("[ ");
                    for (v, 0..) |item, i| {
                        if (i > 0) try w.writeAll(", ");
                        try writeTomlString(w, item);
                    }
                    try w.writeAll(" ]");
                }
            } else @compileError("unsupported TOML value type");
        },
        else => @compileError("unsupported TOML value type"),
    }
}

/// Merge file config under CLI overrides (already parsed). CLI wins per key.
pub fn merge(base: Effective, file: *const FileConfig, file_seed: ?i64) Effective {
    var out = base;
    if (file.server) |s| {
        if (s.port) |v| out.port = v;
        if (s.online) |v| out.online = v;
        if (s.db) |v| out.db = v;
        if (s.view_distance) |v| out.view_distance = v;
        if (s.motd) |v| out.motd = v;
        if (s.max_players) |v| out.max_players = v;
        if (s.brand) |v| out.brand = v;
        if (s.ops) |v| out.ops = v;
        if (s.rcon_password) |v| out.rcon_password = v;
        if (s.rcon_port) |v| out.rcon_port = v;
        if (s.idle_timeout) |v| out.idle_timeout = v;
        if (s.autosave) |v| out.autosave = v;
    }
    if (file_seed) |v| out.seed = v;
    if (file.world) |w| {
        if (w.gen_spawn) |v| out.gen_spawn = v;
        if (w.gen_workers) |v| out.gen_workers = v;
        if (w.region_threads) |v| out.region_threads = v;
        if (w.gamemode) |v| out.gamemode = v;
        if (w.difficulty) |v| out.difficulty = v;
        if (w.pvp) |v| out.pvp = v;
        if (w.force_gamemode) |v| out.force_gamemode = v;
        if (w.gamerules) |v| out.gamerules = v;
        if (w.spawn_mobs) |v| out.spawn_mobs = v;
        if (w.mob_spawns) |v| out.mob_spawns = v;
        if (w.simulation_distance) |v| out.simulation_distance = v;
    }
    if (file.network) |n| {
        if (n.bind_address) |v| out.bind_address = v;
        if (n.backlog) |v| out.backlog = v;
        if (n.io_uring_entries) |v| out.io_uring_entries = v;
        if (n.transport) |v| out.transport = v;
        if (n.transport_workers) |v| out.transport_workers = v;
        if (n.tcp_nodelay) |v| out.tcp_nodelay = v;
        if (n.sndbuf) |v| out.sndbuf = v;
        if (n.rcvbuf) |v| out.rcvbuf = v;
        if (n.max_packets_per_second) |v| out.max_packets_per_second = v;
        if (n.max_packet_size) |v| out.max_packet_size = v;
        if (n.compression_threshold) |v| out.compression_threshold = v;
        if (n.compression_level) |v| out.compression_level = v;
        if (n.max_nbt_depth) |v| out.max_nbt_depth = v;
        if (n.max_string_length) |v| out.max_string_length = v;
        if (n.out_cap_bytes) |v| out.out_cap_bytes = v;
        if (n.send_zc_threshold) |v| out.send_zc_threshold = v;
    }
    if (file.storage) |st| {
        if (st.storage_profile) |v| out.storage_profile = v;
        if (st.region_cache_size) |v| out.region_cache_size = v;
        if (st.disk_flush_interval) |v| out.disk_flush_interval = v;
        if (st.flush_threshold_bytes) |v| out.flush_threshold_bytes = v;
        if (st.compact_threshold_ssts) |v| out.compact_threshold_ssts = v;
    }
    if (file.rates) |r| {
        if (r.chat_rate_window_ms) |v| out.chat_rate_window_ms = v;
        if (r.chat_rate_burst) |v| out.chat_rate_burst = v;
        if (r.dig_rate_window_ms) |v| out.dig_rate_window_ms = v;
        if (r.dig_rate_burst) |v| out.dig_rate_burst = v;
        if (r.login_rate_window_ms) |v| out.login_rate_window_ms = v;
        if (r.login_rate_burst) |v| out.login_rate_burst = v;
        if (r.place_rate_window_ms) |v| out.place_rate_window_ms = v;
        if (r.place_rate_burst) |v| out.place_rate_burst = v;
    }
    if (file.telemetry) |t| {
        if (t.telemetry_enabled) |v| out.telemetry_enabled = v;
        if (t.telemetry_sampling_ms) |v| out.telemetry_sampling_ms = v;
        if (t.telemetry_prometheus) |v| out.telemetry_prometheus = v;
        if (t.telemetry_prometheus_port) |v| out.telemetry_prometheus_port = v;
    }
    if (file.wasm) |w| {
        if (w.wasm_enabled) |v| out.wasm_enabled = v;
        if (w.wasm_max_memory_mb) |v| out.wasm_max_memory_mb = v;
        if (w.wasm_instruction_limit) |v| out.wasm_instruction_limit = v;
    }
    if (file.gpu) |g| {
        if (g.gpu) |v| out.gpu = v;
        if (g.gpu_budget_ms) |v| out.gpu_budget_ms = v;
        if (g.gpu_max_batch) |v| out.gpu_max_batch = v;
        if (g.gpu_device) |v| out.gpu_device = v;
    }
    return out;
}

/// Default config file name probed in the working directory.
pub const default_path = "asteorite.toml";

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

test "renderDefaults round-trips through parse+merge (no source key)" {
    const alloc = std.testing.allocator;
    var eff = Effective{};
    eff.seed = -3755478573795537924;
    eff.port = 25566;
    eff.online = true;
    const rendered = try renderDefaults(alloc, &eff);
    defer alloc.free(rendered);
    // `source` is a startup-log concern, not a setting: must not leak in.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "source") == null);
    // Sections render as TOML tables with per-key comments.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[server]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[gpu]") != null);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const file = try parseToml(arena.allocator(), rendered);
    const file_seed = try file.resolveSeed();
    try std.testing.expectEqual(eff.seed, file_seed);
    const back = merge(Effective{}, &file, file_seed);
    try std.testing.expectEqual(eff.port, back.port);
    try std.testing.expectEqual(eff.online, back.online);
    try std.testing.expectEqual(eff.view_distance, back.view_distance);
    try std.testing.expectEqualStrings(eff.motd, back.motd);
    try std.testing.expectEqual(eff.gpu_max_batch, back.gpu_max_batch);
    try std.testing.expectEqualStrings(eff.gpu_device, back.gpu_device);
}

test "config toml: full file parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const text =
        \\# full example, every key set
        \\[server]
        \\port = 25566
        \\online = true
        \\db = "zc-db"
        \\view_distance = 8
        \\ops = ["alice", "bob"]
        \\rcon_password = "hunter2hunter2"
        \\rcon_port = 25576
        \\motd = "hello \"quoted\""
        \\max_players = 30
        \\brand = "forge"
        \\idle_timeout = 30
        \\autosave = false
        \\[world]
        \\seed = 42
        \\gen_spawn = 4
        \\gen_workers = 2
        \\region_threads = 6
        \\gamemode = "survival"
        \\difficulty = "hard"
        \\pvp = false
        \\force_gamemode = true
        \\gamerules = { keepInventory = true }
        \\spawn_mobs = false
        \\mob_spawns = { zombie = false }
        \\simulation_distance = 8
        \\[network]
        \\bind_address = "127.0.0.1"
        \\backlog = 512
        \\io_uring_entries = 4096
        \\transport = "uring"
        \\transport_workers = 4
        \\out_cap_bytes = 1048576
        \\max_packets_per_second = 500
        \\max_packet_size = 2097152
        \\compression_threshold = 256
        \\compression_level = 3
        \\max_nbt_depth = 32
        \\max_string_length = 32767
        \\[storage]
        \\storage_profile = "nvme"
        \\region_cache_size = 256
        \\disk_flush_interval = 30
        \\flush_threshold_bytes = 67108864
        \\compact_threshold_ssts = 32
        \\[rates]
        \\login_rate_window_ms = 5000
        \\login_rate_burst = 3
        \\place_rate_window_ms = 2000
        \\place_rate_burst = 16
        \\chat_rate_window_ms = 500
        \\chat_rate_burst = 5
        \\dig_rate_window_ms = 2000
        \\dig_rate_burst = 16
        \\[telemetry]
        \\telemetry_enabled = false
        \\telemetry_sampling_ms = 50
        \\telemetry_prometheus = true
        \\telemetry_prometheus_port = 9090
        \\[wasm]
        \\wasm_enabled = false
        \\wasm_max_memory_mb = 128
        \\wasm_instruction_limit = 10000000
        \\[gpu]
        \\gpu = "vulkan"
        \\gpu_budget_ms = 8
        \\gpu_max_batch = 32
        \\gpu_device = "discrete"
        \\
    ;
    const f = try parseToml(alloc, text);
    try std.testing.expectEqual(@as(?u16, 25566), f.server.?.port);
    try std.testing.expectEqual(@as(?bool, true), f.server.?.online);
    try std.testing.expectEqualStrings("zc-db", f.server.?.db.?);
    try std.testing.expectEqual(@as(?u8, 8), f.server.?.view_distance);
    try std.testing.expectEqual(@as(?i64, 42), try f.resolveSeed());
    try std.testing.expectEqual(@as(?i32, 4), f.world.?.gen_spawn);
    try std.testing.expectEqual(@as(?usize, 2), f.world.?.gen_workers);
    try std.testing.expectEqual(@as(usize, 2), f.server.?.ops.?.len);
    try std.testing.expectEqualStrings("bob", f.server.?.ops.?[1]);
    try std.testing.expectEqual(@as(?u16, 25576), f.server.?.rcon_port);
    try std.testing.expectEqualStrings("hello \"quoted\"", f.server.?.motd.?);
    try std.testing.expectEqual(@as(?u16, 30), f.server.?.max_players);
    try std.testing.expectEqualStrings("forge", f.server.?.brand.?);
    try std.testing.expectEqualStrings("uring", f.network.?.transport.?);
    try std.testing.expectEqual(@as(?usize, 4), f.network.?.transport_workers);
    try std.testing.expectEqual(@as(?usize, 6), f.world.?.region_threads);
    try std.testing.expectEqualStrings("nvme", f.storage.?.storage_profile.?);
    try std.testing.expectEqual(@as(?usize, 67108864), f.storage.?.flush_threshold_bytes);
    try std.testing.expectEqual(@as(?usize, 32), f.storage.?.compact_threshold_ssts);
    try std.testing.expectEqual(@as(usize, 1048576), f.network.?.out_cap_bytes);
    try std.testing.expectEqual(@as(?i64, 5000), f.rates.?.login_rate_window_ms);
    try std.testing.expectEqual(@as(?usize, 3), f.rates.?.login_rate_burst);
    try std.testing.expectEqual(@as(?i64, 2000), f.rates.?.place_rate_window_ms);
    try std.testing.expectEqual(@as(?usize, 16), f.rates.?.place_rate_burst);
    try std.testing.expectEqualStrings("survival", f.world.?.gamemode.?);
    try std.testing.expectEqualStrings("hard", f.world.?.difficulty.?);
    try std.testing.expectEqual(@as(?bool, false), f.world.?.pvp);
    try std.testing.expectEqual(@as(?bool, true), f.world.?.force_gamemode);
    try std.testing.expectEqual(@as(?u32, 30), f.server.?.idle_timeout);
    try std.testing.expectEqual(@as(?bool, false), f.server.?.autosave);
    try std.testing.expect(f.world.?.gamerules.? == .object);
    try std.testing.expectEqual(true, f.world.?.gamerules.?.object.get("keepInventory").?.bool);
    try std.testing.expectEqual(@as(?bool, false), f.world.?.spawn_mobs);
    try std.testing.expect(f.world.?.mob_spawns.? == .object);
    try std.testing.expectEqual(false, f.world.?.mob_spawns.?.object.get("zombie").?.bool);
    try std.testing.expectEqual(@as(?i64, 500), f.rates.?.chat_rate_window_ms);
    try std.testing.expectEqual(@as(?usize, 5), f.rates.?.chat_rate_burst);
    try std.testing.expectEqual(@as(?i64, 2000), f.rates.?.dig_rate_window_ms);
    try std.testing.expectEqual(@as(?usize, 16), f.rates.?.dig_rate_burst);
    try std.testing.expectEqualStrings("127.0.0.1", f.network.?.bind_address.?);
    try std.testing.expectEqual(@as(?u16, 512), f.network.?.backlog);
    try std.testing.expectEqual(@as(?u16, 4096), f.network.?.io_uring_entries);
    try std.testing.expectEqual(@as(?u8, 8), f.world.?.simulation_distance);
    try std.testing.expectEqual(@as(?u32, 500), f.network.?.max_packets_per_second);
    try std.testing.expectEqual(@as(?usize, 2097152), f.network.?.max_packet_size);
    try std.testing.expectEqual(@as(?i64, 256), f.network.?.compression_threshold);
    try std.testing.expectEqual(@as(?u8, 3), f.network.?.compression_level);
    try std.testing.expectEqual(@as(?u32, 32), f.network.?.max_nbt_depth);
    try std.testing.expectEqual(@as(?u32, 32767), f.network.?.max_string_length);
    try std.testing.expectEqual(@as(?u32, 256), f.storage.?.region_cache_size);
    try std.testing.expectEqual(@as(?u32, 30), f.storage.?.disk_flush_interval);
    try std.testing.expectEqual(@as(?bool, false), f.wasm.?.wasm_enabled);
    try std.testing.expectEqual(@as(?u32, 128), f.wasm.?.wasm_max_memory_mb);
    try std.testing.expectEqual(@as(?u64, 10000000), f.wasm.?.wasm_instruction_limit);
    try std.testing.expectEqual(@as(?bool, false), f.telemetry.?.telemetry_enabled);
    try std.testing.expectEqual(@as(?u32, 50), f.telemetry.?.telemetry_sampling_ms);
    try std.testing.expectEqual(@as(?bool, true), f.telemetry.?.telemetry_prometheus);
    try std.testing.expectEqual(@as(?u16, 9090), f.telemetry.?.telemetry_prometheus_port);
    try std.testing.expectEqualStrings("vulkan", f.gpu.?.gpu.?);
    try std.testing.expectEqual(@as(?u32, 8), f.gpu.?.gpu_budget_ms);
    try std.testing.expectEqual(@as(?usize, 32), f.gpu.?.gpu_max_batch);
    try std.testing.expectEqualStrings("discrete", f.gpu.?.gpu_device.?);
}

test "config strict tables and keys: unknown sections/keys fail, typos fail" {
    // A legacy flat file (or a typo'd section) must fail boot loudly, never
    // silently boot defaults — a dropped seed would mint a random world.
    // No legacy key names live in the code; the section allowlist plus
    // per-section key checks reject every old file.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Legacy flat keys at root level are not tables.
    try std.testing.expectError(error.UnknownSection, parseToml(alloc, "port = 1\nseed = 42\n"));
    // Misspelled tables and keys.
    try std.testing.expectError(error.UnknownSection, parseToml(alloc, "[sever]\nport = 1\n"));
    try std.testing.expectError(error.UnknownKey, parseToml(alloc, "[server]\nprot = 1\n"));
    try std.testing.expectError(error.UnknownKey, parseToml(alloc, "[gpu]\ngpu = \"off\"\ngpu_budget = 8\n"));
    // Wrong value shapes.
    try std.testing.expectError(error.BadType, parseToml(alloc, "[server]\nport = \"high\"\n"));
    try std.testing.expectError(error.BadType, parseToml(alloc, "[server]\nport = 1.5\n"));
    try std.testing.expectError(error.BadType, parseToml(alloc, "[server]\nport = -1\n"));
    try std.testing.expectError(error.BadType, parseToml(alloc, "[server]\nops = \"alice\"\n"));
    try std.testing.expectError(error.BadType, parseToml(alloc, "[world]\ngamerules = [true]\n"));
    try std.testing.expectError(error.BadType, parseToml(alloc, "[world]\nseed = true\n"));
    // Parsed values still type-check through the same gates.
    const ok = try parseToml(alloc, "[server]\nport = 1\n");
    try std.testing.expectEqual(@as(?u16, 1), ok.server.?.port);
}

test "config gamemode: spellings merge, validate, and map" {
    // File key flows through merge with the creative default intact.
    const base = Effective{};
    try std.testing.expectEqualStrings("creative", base.gamemode);
    const file = FileConfig{ .world = .{ .gamemode = "Survival" } };
    const merged = merge(base, &file, null);
    try std.testing.expectEqualStrings("Survival", merged.gamemode);
    // Accepted spellings (same contract as /gamemode).
    for ([_][]const u8{ "survival", "Survival", "SURVIVAL", "s", "S", "0", "creative", "Creative", "c", "1", "adventure", "A", "2" }) |s| {
        try std.testing.expect(isKnownGamemode(s));
    }
    for ([_][]const u8{ "", "surviv", "peaceful", "3", "-1", "00x", "creative " }) |s| {
        try std.testing.expect(!isKnownGamemode(s));
    }
    // Validate gates the merged value; mapping matches /gamemode.
    const rules = @import("asteorite").rules;
    try validate(&merged);
    try std.testing.expectEqual(rules.GameMode.survival, rules.GameMode.parse(merged.gamemode).?);
    var bad = Effective{ .gamemode = "peaceful" };
    try std.testing.expectError(error.BadGamemode, validate(&bad));
    var def = Effective{};
    try validate(&def);
    try std.testing.expectEqual(rules.GameMode.creative, rules.GameMode.parse(def.gamemode).?);
}

test "config gameplay keys: difficulty/pvp/force/idle/autosave" {
    // Merge carries every key; defaults match the previous hardcoded boot.
    const base = Effective{};
    try std.testing.expectEqualStrings("easy", base.difficulty);
    try std.testing.expectEqual(true, base.pvp);
    try std.testing.expectEqual(false, base.force_gamemode);
    try std.testing.expectEqual(@as(u32, 0), base.idle_timeout);
    try std.testing.expectEqual(true, base.autosave);
    const file = FileConfig{ .world = .{ .difficulty = "Hard", .pvp = false, .force_gamemode = true }, .server = .{ .idle_timeout = 30, .autosave = false } };
    const merged = merge(base, &file, null);
    try std.testing.expectEqualStrings("Hard", merged.difficulty);
    try std.testing.expectEqual(false, merged.pvp);
    try std.testing.expectEqual(true, merged.force_gamemode);
    try std.testing.expectEqual(@as(u32, 30), merged.idle_timeout);
    try std.testing.expectEqual(false, merged.autosave);
    // Difficulty spellings (same contract as /difficulty).
    for ([_][]const u8{ "peaceful", "Peaceful", "p", "P", "0", "easy", "e", "1", "normal", "n", "2", "hard", "H", "3" }) |s| {
        try std.testing.expect(isKnownDifficulty(s));
    }
    for ([_][]const u8{ "", "eas", "nightmare", "4", "-1", "hard " }) |s| {
        try std.testing.expect(!isKnownDifficulty(s));
    }
    // Validate gates the merged value; mapping matches /difficulty.
    const rules = @import("asteorite").rules;
    try validate(&merged);
    try std.testing.expectEqual(rules.Difficulty.hard, rules.Difficulty.parse(merged.difficulty).?);
    var bad = Effective{ .difficulty = "nightmare" };
    try std.testing.expectError(error.BadDifficulty, validate(&bad));
}

test "config gamerules: table of known names to bools" {
    // Gamerule overrides merge and validate; unknown names and non-bool
    // values fail closed (typo-proofing, like /gamerule).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\[world]
        \\gamerules = { keepInventory = true, doMobSpawning = false }
    ;
    const filed = try parseToml(arena.allocator(), text);
    const base = Effective{};
    try std.testing.expect(base.gamerules == null);
    const merged = merge(base, &filed, null);
    try validate(&merged);
    try std.testing.expect(merged.gamerules.? == .object);
    try std.testing.expect(isKnownGamerule("keepInventory"));
    try std.testing.expect(isKnownGamerule("doDaylightCycle"));
    try std.testing.expect(!isKnownGamerule("keepinventory"));
    try std.testing.expect(!isKnownGamerule("keepInventory2"));
    try std.testing.expect(!isKnownGamerule(""));
    const alloc = std.testing.allocator;
    const parseVal = struct {
        fn f(a: std.mem.Allocator, s: []const u8) !std.json.Parsed(std.json.Value) {
            return std.json.parseFromSlice(std.json.Value, a, s, .{});
        }
    }.f;
    var p_name = try parseVal(alloc, "{\"keepinventry\": true}");
    defer p_name.deinit();
    var bad_name = Effective{ .gamerules = p_name.value };
    try std.testing.expectError(error.BadGamerules, validate(&bad_name));
    var p_type = try parseVal(alloc, "{\"keepInventory\": \"yes\"}");
    defer p_type.deinit();
    var bad_type = Effective{ .gamerules = p_type.value };
    try std.testing.expectError(error.BadGamerules, validate(&bad_type));
    var p_shape = try parseVal(alloc, "[\"keepInventory\"]");
    defer p_shape.deinit();
    const bad_shape = Effective{ .gamerules = p_shape.value };
    try std.testing.expectError(error.BadGamerules, validate(&bad_shape));
}

test "config mob spawns: master switch plus per-kind map" {
    // Master defaults on; the map defaults to absent (all kinds allowed).
    const base = Effective{};
    try std.testing.expectEqual(true, base.spawn_mobs);
    try std.testing.expect(base.mob_spawns == null);
    const alloc = std.testing.allocator;
    const parseVal = struct {
        fn f(a: std.mem.Allocator, s: []const u8) !std.json.Parsed(std.json.Value) {
            return std.json.parseFromSlice(std.json.Value, a, s, .{});
        }
    }.f;
    var parsed = try parseVal(alloc, "{\"pig\": false, \"Zombie\": false, \"ender_dragon\": true}");
    defer parsed.deinit();
    var filed = FileConfig{ .world = .{ .mob_spawns = parsed.value, .spawn_mobs = false } };
    const merged = merge(base, &filed, null);
    try std.testing.expectEqual(false, merged.spawn_mobs);
    try std.testing.expect(merged.mob_spawns.? == .object);
    try validate(&merged);
    try std.testing.expect(isKnownMobKind("pig"));
    try std.testing.expect(isKnownMobKind("Pig_Zombie"));
    try std.testing.expect(isKnownMobKind("ENDER_DRAGON"));
    try std.testing.expect(isKnownMobKind("villager"));
    try std.testing.expect(!isKnownMobKind("pigman"));
    try std.testing.expect(!isKnownMobKind("zombie "));
    try std.testing.expect(!isKnownMobKind(""));
    var p_name = try parseVal(alloc, "{\"pigman\": false}");
    defer p_name.deinit();
    var bad_name = Effective{ .mob_spawns = p_name.value };
    try std.testing.expectError(error.BadMobSpawns, validate(&bad_name));
    var p_type = try parseVal(alloc, "{\"pig\": \"no\"}");
    defer p_type.deinit();
    const bad_type = Effective{ .mob_spawns = p_type.value };
    try std.testing.expectError(error.BadMobSpawns, validate(&bad_type));
    var p_shape = try parseVal(alloc, "[\"pig\"]");
    defer p_shape.deinit();
    const bad_shape = Effective{ .mob_spawns = p_shape.value };
    try std.testing.expectError(error.BadMobSpawns, validate(&bad_shape));
}

test "config flood gates: chat/dig budgets merge and validate" {
    // Gate budgets merge; defaults preserve the previous hardcoded gates
    // (750ms/3 chats, 1000ms/32 digs — same as placements).
    const base = Effective{};
    try std.testing.expectEqual(@as(i64, 750), base.chat_rate_window_ms);
    try std.testing.expectEqual(@as(usize, 3), base.chat_rate_burst);
    try std.testing.expectEqual(@as(i64, 1000), base.dig_rate_window_ms);
    try std.testing.expectEqual(@as(usize, 32), base.dig_rate_burst);
    var filed = FileConfig{ .rates = .{ .chat_rate_window_ms = 500, .chat_rate_burst = 5, .dig_rate_window_ms = 2000, .dig_rate_burst = 16 } };
    const merged = merge(base, &filed, null);
    try validate(&merged);
    try std.testing.expectEqual(@as(i64, 500), merged.chat_rate_window_ms);
    try std.testing.expectEqual(@as(usize, 5), merged.chat_rate_burst);
    try std.testing.expectEqual(@as(i64, 2000), merged.dig_rate_window_ms);
    try std.testing.expectEqual(@as(usize, 16), merged.dig_rate_burst);
    var bad_win = Effective{ .chat_rate_window_ms = 50 };
    try std.testing.expectError(error.BadChatRate, validate(&bad_win));
    var bad_burst = Effective{ .chat_rate_burst = 0 };
    try std.testing.expectError(error.BadChatRate, validate(&bad_burst));
    var bad_dwin = Effective{ .dig_rate_window_ms = 50 };
    try std.testing.expectError(error.BadDigRate, validate(&bad_dwin));
    var bad_dburs = Effective{ .dig_rate_burst = 0 };
    try std.testing.expectError(error.BadDigRate, validate(&bad_dburs));
    var bad_dcap = Effective{ .dig_rate_burst = 65 };
    try std.testing.expectError(error.BadDigRate, validate(&bad_dcap));
}

test "config net/world/future keys: merge, validate, defaults" {
    // Every newer key merges; defaults preserve previous boot behavior
    // (bind-all, 4096 backlog, 256 ring entries, 2 MiB frames, pps off,
    // sim 10, compression off, nbt 32, strings 32767, region 256,
    // flush 30s, wasm/telemetry off).
    const base = Effective{};
    try std.testing.expectEqualStrings("0.0.0.0", base.bind_address);
    try std.testing.expectEqual(@as(u16, 4096), base.backlog);
    try std.testing.expectEqual(@as(u16, 256), base.io_uring_entries);
    try std.testing.expectEqual(@as(u8, 10), base.simulation_distance);
    try std.testing.expectEqual(@as(u32, 0), base.max_packets_per_second);
    try std.testing.expectEqual(@as(usize, 2097152), base.max_packet_size);
    try std.testing.expectEqual(@as(i64, -1), base.compression_threshold);
    try std.testing.expectEqual(@as(u8, 3), base.compression_level);
    try std.testing.expectEqual(@as(u32, 32), base.max_nbt_depth);
    try std.testing.expectEqual(@as(u32, 32767), base.max_string_length);
    try std.testing.expectEqual(@as(u32, 256), base.region_cache_size);
    try std.testing.expectEqual(@as(u32, 30), base.disk_flush_interval);
    try std.testing.expectEqual(@as(?usize, null), base.flush_threshold_bytes);
    try std.testing.expectEqual(@as(?usize, null), base.compact_threshold_ssts);
    try std.testing.expectEqual(false, base.wasm_enabled);
    try std.testing.expectEqual(@as(u32, 128), base.wasm_max_memory_mb);
    try std.testing.expectEqual(@as(u64, 10000000), base.wasm_instruction_limit);
    try std.testing.expectEqual(false, base.telemetry_enabled);
    try std.testing.expectEqual(@as(u32, 50), base.telemetry_sampling_ms);
    try std.testing.expectEqual(false, base.telemetry_prometheus);
    try std.testing.expectEqual(@as(u16, 9090), base.telemetry_prometheus_port);
    var filed = FileConfig{
        .server = .{
            .idle_timeout = 30,
            .autosave = false,
        },
        .network = .{
            .bind_address = "127.0.0.1",
            .backlog = 512,
            .io_uring_entries = 4096,
            .max_packets_per_second = 500,
            .max_packet_size = 4194304,
            .compression_threshold = 256,
            .compression_level = 6,
            .max_nbt_depth = 64,
            .max_string_length = 10000,
        },
        .storage = .{
            .storage_profile = "nvme",
            .region_cache_size = 128,
            .disk_flush_interval = 60,
            .flush_threshold_bytes = 67108864,
            .compact_threshold_ssts = 32,
        },
        .world = .{
            .simulation_distance = 8,
        },
        .telemetry = .{
            .telemetry_enabled = true,
            .telemetry_sampling_ms = 100,
            .telemetry_prometheus = true,
            .telemetry_prometheus_port = 9091,
        },
        .wasm = .{
            .wasm_enabled = true,
            .wasm_max_memory_mb = 256,
            .wasm_instruction_limit = 5000000,
        },
    };
    const merged = merge(base, &filed, null);
    try validate(&merged);
    try std.testing.expectEqualStrings("127.0.0.1", merged.bind_address);
    try std.testing.expectEqual(@as(u16, 512), merged.backlog);
    try std.testing.expectEqual(@as(u16, 4096), merged.io_uring_entries);
    try std.testing.expectEqual(@as(u8, 8), merged.simulation_distance);
    try std.testing.expectEqual(@as(u32, 500), merged.max_packets_per_second);
    try std.testing.expectEqual(@as(usize, 4194304), merged.max_packet_size);
    try std.testing.expectEqual(@as(?usize, 67108864), merged.flush_threshold_bytes);
    try std.testing.expectEqual(@as(?usize, 32), merged.compact_threshold_ssts);
    // Validation edges.
    var bad_bind = Effective{ .bind_address = "not-an-ip" };
    try std.testing.expectError(error.BadBindAddress, validate(&bad_bind));
    var bad_v6 = Effective{ .bind_address = "::1" };
    try validate(&bad_v6);
    var bad_backlog = Effective{ .backlog = 0 };
    try std.testing.expectError(error.BadBacklog, validate(&bad_backlog));
    var bad_ring = Effective{ .io_uring_entries = 300 };
    try std.testing.expectError(error.BadUringEntries, validate(&bad_ring));
    var bad_ring2 = Effective{ .io_uring_entries = 16384 };
    try std.testing.expectError(error.BadUringEntries, validate(&bad_ring2));
    var ok_ring = Effective{ .io_uring_entries = 4096 };
    try validate(&ok_ring);
    var bad_frame = Effective{ .max_packet_size = 65536 };
    try std.testing.expectError(error.BadPacketSize, validate(&bad_frame));
    var bad_frame2 = Effective{ .max_packet_size = 32 * 1024 * 1024 };
    try std.testing.expectError(error.BadPacketSize, validate(&bad_frame2));
    var bad_level = Effective{ .compression_level = 0 };
    try std.testing.expectError(error.BadCompressionLevel, validate(&bad_level));
    var bad_level2 = Effective{ .compression_level = 10 };
    try std.testing.expectError(error.BadCompressionLevel, validate(&bad_level2));
    var bad_pport = Effective{ .telemetry_prometheus_port = 0 };
    try std.testing.expectError(error.BadPrometheusPort, validate(&bad_pport));
    var bad_players = Effective{ .max_players = 0 };
    try std.testing.expectError(error.BadMaxPlayers, validate(&bad_players));
    var bad_players2 = Effective{ .max_players = 1025 };
    try std.testing.expectError(error.BadMaxPlayers, validate(&bad_players2));
    var ok_players = Effective{ .max_players = 1000 };
    try validate(&ok_players);
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

test "config gpu: spellings merge, validate, defaults" {
    // GPU offload knobs (Phase G): backend + per-tick budget + batch cap +
    // device preference. Off by default; validation is typo fail-closed
    // like transport/storage-profile.
    const base = Effective{};
    try std.testing.expectEqualStrings("off", base.gpu);
    try std.testing.expectEqual(@as(u32, 4), base.gpu_budget_ms);
    try std.testing.expectEqual(@as(usize, 16), base.gpu_max_batch);
    try std.testing.expectEqualStrings("auto", base.gpu_device);
    try std.testing.expect(isKnownGpu("off"));
    try std.testing.expect(isKnownGpu("vulkan"));
    try std.testing.expect(!isKnownGpu("cuda"));
    try std.testing.expect(!isKnownGpu(""));
    try std.testing.expect(isKnownGpuDevice("auto"));
    try std.testing.expect(isKnownGpuDevice("discrete"));
    try std.testing.expect(isKnownGpuDevice("integrated"));
    try std.testing.expect(isKnownGpuDevice("cpu"));
    try std.testing.expect(!isKnownGpuDevice("gpu0"));
    var filed = FileConfig{ .gpu = .{ .gpu = "vulkan", .gpu_budget_ms = 8, .gpu_max_batch = 32, .gpu_device = "discrete" } };
    const merged = merge(base, &filed, null);
    try validate(&merged);
    try std.testing.expectEqualStrings("vulkan", merged.gpu);
    try std.testing.expectEqual(@as(u32, 8), merged.gpu_budget_ms);
    try std.testing.expectEqual(@as(usize, 32), merged.gpu_max_batch);
    try std.testing.expectEqualStrings("discrete", merged.gpu_device);
    var bad = Effective{ .gpu = "cuda" };
    try std.testing.expectError(error.BadGpu, validate(&bad));
    var bad_budget = Effective{ .gpu_budget_ms = 0 };
    try std.testing.expectError(error.BadGpuBudget, validate(&bad_budget));
    var bad_budget2 = Effective{ .gpu_budget_ms = 51 };
    try std.testing.expectError(error.BadGpuBudget, validate(&bad_budget2));
    var bad_batch = Effective{ .gpu_max_batch = 0 };
    try std.testing.expectError(error.BadGpuBatch, validate(&bad_batch));
    var bad_batch2 = Effective{ .gpu_max_batch = 65 };
    try std.testing.expectError(error.BadGpuBatch, validate(&bad_batch2));
    var bad_dev = Effective{ .gpu_device = "gpu0" };
    try std.testing.expectError(error.BadGpuDevice, validate(&bad_dev));
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

test "config toml: string and negative seeds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const p1 = try parseToml(alloc, "[world]\nseed = \"Notch\"\n");
    try std.testing.expectEqual(@as(?i64, 75456088), try p1.resolveSeed());
    const p2 = try parseToml(alloc, "[world]\nseed = -123456789012345678\n");
    try std.testing.expectEqual(@as(?i64, -123456789012345678), try p2.resolveSeed());
    const p3 = try parseToml(alloc, "[world]\nseed = 1.5\n");
    try std.testing.expectError(error.SeedMustBeIntegerOrString, p3.resolveSeed());
}

test "config toml: missing keys stay null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const f = try parseToml(alloc, "# empty\n");
    try std.testing.expect(f.server == null);
    try std.testing.expect(f.world == null);
    try std.testing.expect(try f.resolveSeed() == null);
    const partial = try parseToml(alloc, "[server]\nport = 1\n");
    try std.testing.expect(partial.server.?.view_distance == null);
    try std.testing.expect(partial.world == null);
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
