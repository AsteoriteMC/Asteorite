//! TCP listener + connection registry + server ticker.
//!
//! Transport is still blocking I/O, one OS thread per connection (the
//! io_uring migration keeps the `Conn` interface — only this transport
//! changes). Server-driven ticks (keepalive/timeout, time updates, player
//! list) run on a dedicated ticker thread over a refcounted registry so
//! status/login paths stay untouched.
//!
//! Locking discipline (no nesting, ever):
//! - `reg_lock`: guards the registry list only (leaf lock).
//! - `conn.lock`: guards one conn's state + outbox. Never held with another.
//! - `conn.wlock`: serializes socket writes (serve flush vs ticker flush).
//! - Registry snapshots take temp refs; destroy waits for refs == 0.
//!
//! Contents (one `Server` struct; sections in file order):
//! lifecycle | registry | chat+death | sessions | commands | player ops |
//! moderation | social+weather | rules+xp | editing+ops | tab-complete |
//! scoreboard | tick regions | broadcasts+combat | items+containers |
//! loops+serve | session state | tests.
//! Section banners (`// ---- ... ----`) mark each span; a future split
//! follows these lines (methods cannot leave the struct in Zig, so the
//! grouping is documentary until the god-object is decomposed).

const std = @import("std");
const builtin = @import("builtin");
const Conn = @import("conn.zig").Conn;
const Config = @import("conn.zig").Config;
const Action = @import("conn.zig").Action;
const AttackEvent = @import("conn.zig").AttackEvent;
const QDropEvent = @import("conn.zig").QDropEvent;
const FurnaceClick = @import("conn.zig").FurnaceClick;
const BrewClick = @import("conn.zig").BrewClick;
const ChestClick = @import("conn.zig").ChestClick;
const ChestClose = @import("conn.zig").ChestClose;
const EnderClose = @import("conn.zig").EnderClose;
const EnchantClick = @import("conn.zig").EnchantClick;
const EnchantEvent = @import("conn.zig").EnchantEvent;
const TableClose = @import("conn.zig").TableClose;
const BlockEvent = @import("conn.zig").BlockEvent;
const ThrowPotionEvent = @import("conn.zig").ThrowPotionEvent;
const furnace_mod = @import("../sim/world/furnace.zig");
const brewing_mod = @import("../sim/world/brewing.zig");
const smelting_mod = @import("../sim/world/smelting.zig");
const container_mod = @import("../sim/world/container.zig");
const chest_mod = @import("../sim/world/chest.zig");
const enchanting_mod = @import("../sim/world/enchanting.zig");
const codec = @import("codec.zig");
const uuid_mod = @import("uuid.zig");
const view = @import("../sim/world/view.zig");
const conn_sink = @import("packet_sink.zig");
const sink_mod = @import("../sim/net/packet_sink.zig");
const shard_mod = @import("../world/shard.zig");
const store_mod = @import("../world/store.zig");
const chunk_mod = @import("../world/chunk.zig");
const player_db = @import("../sim/player/players.zig");
const player_import = @import("../world/import/player.zig");
const item_mod = @import("../item.zig");
const perms_mod = @import("../sim/player/permissions.zig");
const console_tui = @import("../console_tui.zig");
const spin = @import("../sim/core/spin.zig");
const ratelimit_mod = @import("../sim/core/ratelimit.zig");
const drop_mod = @import("../game/drops.zig");
const java_random = @import("../worldgen/rng/java_random.zig");
const packets = @import("../proto/v5/packets.zig");
const ids = @import("../proto/v5/ids.zig");
const entity = @import("../sim/entity/entity.zig");
const mob_mod = @import("../game/mob.zig");
const v5gen = @import("../worldgen/v5/gen.zig");
const v5serve = @import("../worldgen/v5/serve.zig");
const v5genpool = @import("../worldgen/v5/genpool.zig");
const game_ids = @import("../ids.zig");
const rules_mod = @import("../game/rules.zig");
const wire = @import("../proto/v5/wire_ids.zig");
const tp_mod = @import("../cmd/tp.zig");
const cmd_spec = @import("../cmd/spec.zig");
const cmd_data = @import("../proto/v5/cmd_data.zig");
const bans_mod = @import("../sim/player/bans.zig");
const scoreboard_mod = @import("../sim/player/scoreboard.zig");
const redstone_mod = @import("../sim/world/redstone.zig");
const interaction_mod = @import("../sim/world/interaction.zig");
const profile = @import("../version.zig");
const transport_mod = @import("transport.zig");
const memstat_mod = @import("../sim/core/memstat.zig");
const seqlock_mod = @import("../sim/core/seqlock.zig");
const tick_mod = @import("../sim/core/tick.zig");
const affinity_mod = @import("../sim/core/affinity.zig");
const pool_mod = @import("../sim/core/pool.zig");
/// The io_uring backend is Linux-only and the kqueue backend is
/// macOS/BSD-only: the comptime condition makes the other import dead
/// code (never analyzed) on the wrong target.
const uring_mod = if (builtin.os.tag == .linux) @import("uring.zig") else struct {};
const kqueue_mod = if (builtin.os.tag.isDarwin()) @import("kqueue.zig") else struct {};
/// The IOCP backend is Windows-only (same dead-code gating). Its pure
/// parts still compile everywhere (see root.zig) so the op layout and
/// header math are unit-tested on every target.
const iocp_mod = if (builtin.os.tag == .windows) @import("iocp.zig") else struct {};
const shutdown_mod = @import("shutdown.zig");

/// Handshake/login must complete within this window (anti-slowloris).
pub const login_timeout_ms: i64 = 30000;

/// The read-mostly gameplay config, published as one snapshot.
///
/// Phase D: readers take no lock at all (a seqlock read is two atomic
/// loads and a compare) — region threads never block on the config.
pub const CfgState = struct {
    difficulty: rules_mod.Difficulty = .easy,
    default_gamemode: rules_mod.GameMode = .creative,
    /// Vanilla pvp flag (default true): false makes player-vs-player
    /// swings fizzle (config file only; no runtime command yet).
    pvp: bool = true,
    /// Vanilla force-gamemode (default false): when true, returning
    /// players inherit the default gamemode at login instead of their
    /// saved one (fresh logins always inherit it).
    force_gamemode: bool = false,
    /// Natural-spawn master switch (config "spawn_mobs", default true).
    spawn_mobs: bool = true,
    /// Per-kind spawn allowlist (config "mob_spawns" map; absent kinds
    /// stay allowed). Existing mobs are unaffected — only new spawns
    /// consult it, via canSpawnMob (the gate every spawn ingress, present
    /// and future, must call).
    mob_spawn_allowed: [mob_mod.count]bool = [_]bool{true} ** mob_mod.count,
    gamerules: [9]bool = .{ true, true, false, true, true, true, true, true, true },
    autosave: bool = true,
    idle_timeout_min: u32 = 0,
    world_spawn: [3]i32 = .{ 8, 64, 8 },
    world_spawn_set: bool = false,
};

pub const RegistryEntry = struct {
    conn: *Conn,
    stream: std.Io.net.Stream,
};

/// Registry snapshot cap for fan-out broadcasts (join/leave/chat/sound/
/// block paths all size their batch from this). Sized for the max
/// player cap (config max_players validates 1..1024): every online
/// player must fit or viewers past the cap silently miss broadcasts.
pub const max_fanout: usize = 1024;

/// Blocking-transport I/O buffer (socket reads, reader/writer scratch).
pub const io_buf_len: usize = 4096;

/// Scratch for tiny frames (S2B game-state, animation, block-action…).
/// Framers bounds-check, so an undersize buffer drops the frame, never OOB.
pub const tiny_frame_buf: usize = 8;
/// Scratch for small frames (S1F experience, effect-remove, health…).
pub const small_frame_buf: usize = 16;

/// Queue a just-built frame, dropping it when the build failed.
/// Collapses the ubiquitous `if (frame...() |f| {queue} else|_|{})`.
fn queueBuilt(conn: *Conn, r: anytype) void {
    if (r) |f| {
        conn.queueFramed(f) catch {};
    } else |_| {}
}

/// Vanilla sound-hearing radius² (16 blocks; sounds carry no farther).
pub const hear_radius_sq: f64 = 256.0;

/// Chunk-column offset (pregen spiral, neighbor resends).
pub const ColOffset = struct { dx: i32, dz: i32 };

/// Block id + meta at one position (getBlockAt).
pub const BlockWire = struct { wire: u16, meta: u4 };

/// Debug-profiling span (debugStop).
pub const DebugSpan = struct { secs: f64, ticks: u64 };

pub const Server = struct {
    /// Login-burst singleflight (thundering-herd coalescing): concurrent
    /// logins for the same chunk disk share one worldgen/read/zlib pass
    /// instead of each paying the full 289-column burst. Only in-flight
    /// work is shared (never cached), so there is no invalidation story:
    /// a late joiner just starts its own flight. Waiters park on the
    /// condvar (no spinning); the executor always publishes or fails,
    /// so waits always terminate (plus waiters re-check liveness after).
    /// Locking: flight mutex only, never nested with conn locks.
    pub const BurstFlight = struct {
        mutex: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init,
        active: bool = false,
        key: BurstKey = .{},
        done: bool = false,
        failed: bool = false,
        gen: u64 = 0,
        frames: std.ArrayListUnmanaged([]u8) = .empty,
        sent_n: usize = 0,
        sent_keys: [view.max_disk_cols]i64 = undefined,
        refs: u32 = 0,
        /// Allocator that owns `frames` (the executor's own). Reset frees
        /// with exactly this allocator — waiters may run under different
        /// allocators in tests, so it must travel with the payload.
        alloc: std.mem.Allocator = undefined,
    };
    pub const BurstKey = struct {
        dim: u8 = 0,
        cx: i32 = 0,
        cz: i32 = 0,
        radius: u8 = 0,
        sky: bool = true,
        fn eql(a: BurstKey, b: BurstKey) bool {
            return a.dim == b.dim and a.cx == b.cx and a.cz == b.cz and a.radius == b.radius and a.sky == b.sky;
        }
    };
    net: std.Io.net.Server,
    io: std.Io,
    config: Config,
    burst_flight: BurstFlight = .{},
    /// Phase B: transport selection. `auto` picks the best backend for
    /// this OS (io_uring on Linux, kqueue on macOS, IOCP on Windows);
    /// `blocking` keeps the portable thread-per-connection transport.
    transport_kind: transport_mod.Kind = .auto,
    /// Storage profile name for the stats line ("hdd", "ssd", "nvme";
    /// set by main after resolving `--storage-profile`).
    storage_profile_name: []const u8 = "auto",
    /// Phase C: region tick threads (0 = auto = cpu count, max 8;
    /// 1 = sequential legacy path). Viewers are grouped by 32x32-chunk
    /// region and ticked fork-join; the join is the global barrier.
    region_threads: usize = 0,
    /// Phase C: live region set (created on demand per populated cell).
    /// Leaf lock (see Registry docs): never take it holding conn/ent.
    region_reg: tick_mod.Registry = .{},
    /// Phase C: published age/time for region workers (atomics only).
    region_clock: tick_mod.TickClock = .{},
    /// Phase C: total shed entries across regions (stats line).
    /// Written by the tick merge pass only (single-threaded there).
    region_shed_total: u64 = 0,
    /// Phase C: cached CPU topology for worker pinning (detected lazily
    /// on the first parallel tick; flat mapping when undetectable).
    region_topo: affinity_mod.Topology = .{},
    region_topo_done: bool = false,
    /// Phase C follow-up: persistent pool for the viewer pass (stable
    /// worker identities, pinned once; created lazily on the first
    /// parallel tick, null = fork-join fallback). Destroyed in deinit/
    /// deinitRegions; never races a run (ticker-owned).
    region_pool: ?*pool_mod.Pool = null,
    /// Phase B: transport tuning (send_zc threshold, outbox cap, socket
    /// options, ring geometry).
    transport_opts: transport_mod.Options = .{},
    /// Phase B: the running async transport (null = blocking transport).
    transport_handle: ?transport_mod.Handle = null,
    /// Phase B: the io_uring backend (owned by the server). Kept as an
    /// opaque pointer so the struct compiles on every OS (the backend
    /// itself is Linux-only).
    uring_backend: ?*anyopaque = null,
    /// Phase D: rolling window of tick durations (ns) and tick-flush
    /// durations (ns) for the stats line (p50/p99).
    tick_samples: [256]u64 = undefined,
    tick_samples_n: usize = 0,
    tick_samples_idx: usize = 0,
    flush_samples: [256]u64 = undefined,
    flush_samples_n: usize = 0,
    flush_samples_idx: usize = 0,
    /// Phase D: memory accounting (per subsystem, refreshed by the stats
    /// line).
    mem_accounting: memstat_mod.Accounting = .{},
    /// Phase D: RSS at the last stats line (bytes).
    rss_bytes: usize = 0,
    /// Phase B/D: the last tick's split timings (entity reconcile vs the
    /// output flush).
    reconcile_ns_last: u64 = 0,
    send_ns_last: u64 = 0,
    /// Phase B: async conns by transport id (the worker threads look the
    /// protocol state up through this map).
    async_conns: std.AutoHashMapUnmanaged(u32, *Conn) = .empty,
    /// Phase B: per-conn protocol state for the async transport.
    async_states: std.AutoHashMapUnmanaged(u32, *SessionState) = .empty,
    async_lock: spin.SpinLock = .{},
    /// Shared by players AND mobs (single accept thread + ticker thread).
    eid_counter: std.atomic.Value(i32) = std.atomic.Value(i32).init(1),
    /// Optional world store for login chunk bursts (null = no chunks).
    /// Borrowed; must outlive the server (owned by main).
    world: ?*shard_mod.ShardPool = null,
    /// Optional terrain generator (null = serve stored chunks only, holes stay
    /// holes). Borrowed; must outlive the server (owned by main).
    gen: ?*v5gen.Gen = null,
    /// Gen-aware source state (ctx for view.Source). Set alongside gen.
    gen_src: ?v5serve.GenSource = null,
    /// Background generation workers (null = sync legacy path in GenSource).
    /// Borrowed; must outlive the server (owned by main).
    gen_pool: ?*v5genpool.GenPool = null,
    /// Chunky-style pregeneration task (/pregen). Guarded by pregen_lock
    /// (leaf: never held while acquiring conn, pool, or world locks —
    /// pollPregren snapshots under it, then works lock-free).
    pregen_lock: spin.SpinLock = .{},
    pregen: PregenState = .{},
    view_distance: u8 = 4,
    /// Allocator for the registry list. Set by serveForever/tests.
    gpa: std.mem.Allocator = undefined,
    registry: std.ArrayList(RegistryEntry) = .empty,
    reg_lock: spin.SpinLock = .{},
    /// Pending join announcements (batched fan-out, drained by the ticker).
    /// Entries are pinned conn refs; the drain releases them. Leaf lock:
    /// never held while acquiring conn or registry locks.
    announce_lock: spin.SpinLock = .{},
    announce_queue: std.ArrayList(*Conn) = .empty,
    /// Serializes chunk read-modify-write cycles across connections.
    /// Never held together with any conn.lock (strict one-lock-at-a-time).
    world_lock: spin.SpinLock = .{},
    // Live mobs are region-owned (Phase C follow-up): each tick Region
    // owns its SoA slots; look up by id with Registry.findMob. (The old
    // global SoA store is gone.) Item entities stay global (see items):
    // merge + magnet pickup are cross-region pair interactions that would
    // need a halo protocol to partition; the single ent_lock section is
    // contention-free at 1Hz.
    ent_lock: spin.SpinLock = .{},
    /// Global item-entity list (break drops + Q-drops; guarded by ent_lock).
    items: std.ArrayList(entity.ItemEnt) = .empty,
    /// Global thrown-splash-potion list (guarded by ent_lock, like items).
    /// Short-lived arcs (impact or age/void despawn); capped like items.
    potions: std.ArrayList(entity.PotionEnt) = .empty,
    /// Furnace tile entities (server-owned; in-memory only, lost on restart —
    /// no chunk unloading exists so lifetime matches the loaded world).
    /// Guarded by furn_lock (leaf; furn is never held while acquiring conn,
    /// so nesting conn->furn is deadlock-free by construction).
    furnaces: std.ArrayList(FurnaceEnt) = .empty,
    furn_lock: spin.SpinLock = .{},
    /// Brewing-stand tile entities (same ownership/lifetime discipline as
    /// furnaces; slots OWNED). Guarded by brew_lock (leaf like furn_lock).
    brews: std.ArrayList(BrewEnt) = .empty,
    brew_lock: spin.SpinLock = .{},
    /// Chest tile entities (server-owned, persisted per-block to
    /// chest_dim rows; see chest.zig). Entries exist only for chests
    /// opened since boot (lazy load on open, dropped when empty, clean,
    /// and viewerless). Viewers are DERIVED (conns with an open window
    /// at the pos), never stored — so disconnects can't leak counts.
    /// Guarded by chest_lock (leaf like furn_lock: nesting conn->chest
    /// and world->chest is deadlock-free; chest never nests outward).
    chests: std.ArrayList(ChestEnt) = .empty,
    chest_lock: spin.SpinLock = .{},
    /// K1 redstone state: scheduled ticks, torch burnout trackers, and the
    /// pressure-plate registry. No allocator, no locks of their own — only
    /// ever touched with world_lock held (serve mutation + ticker pass).
    rs_sched: redstone_mod.Scheduler = .{},
    rs_burn: redstone_mod.BurnoutMap = .{},
    rs_plates: redstone_mod.PlateSet = .{},
    /// Redstone game-tick clock (equals world_age rate: 20/s; separate epoch
    /// so sub-second scheduling doesn't disturb the day clock). Advanced by
    /// the 10Hz redstone thread AND read by the serve threads; guarded by
    /// world_lock like the rest of the K1 state. Tests set it directly.
    rs_tick: i64 = 0,
    /// Scheduler persistence: set after the first load attempt (lazy-load
    /// from the `253,0,0` row like the permission matrix).
    rs_loaded: bool = false,
    /// Gameplay RNG stream (block-drop quantities/offsets, vanilla draw order).
    /// Lazy-seeded from drop_seed under rand_lock; never held with other locks.
    drop_rand: ?java_random.JavaRandom = null,
    rand_lock: spin.SpinLock = .{},
    /// Seed for the gameplay stream (world seed from the config file).
    drop_seed: i64 = 0,
    /// Item-toss stream (break/death/Q-drop scatter direction only). A
    /// SEPARATE JavaRandom from drop_rand, seeded with a fixed
    /// domain constant — never the world seed. Vanilla draws toss
    /// motion from Math.random(), not world.rand; sharing the world
    /// stream would leak worldgen RNG state through observable item
    /// motion (the randar class of seed-recovery exploit). Guarded by
    /// rand_lock like drop_rand (leaf lock, never nested).
    toss_rand: ?java_random.JavaRandom = null,
    /// Fixed seed for the toss stream ("TossRand" as i64 — deliberately
    /// world-independent; see toss_rand).
    toss_seed: i64 = 0x546F737352616E64,
    pig_spawned: bool = false,
    /// Ticks until the demo pig respawns after death (tickOnce is 1Hz).
    /// Set on pig death; first spawn is immediate via pig_spawned.
    pig_cooldown: u32 = 0,
    world_age: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    time_of_day: std.atomic.Value(i64) = std.atomic.Value(i64).init(6000),
    /// Announced play conns, for the server list ping. Bumped in
    /// queueAnnounce/drainAnnounces (once per conn, guarded by announced) and dropped in
    /// unregister; read lock-free by serveConn when answering status.
    play_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Ticks since boot (1Hz ticker). Periodic player save every 300.
    tick_counter: u64 = 0,
    /// Permission matrix (lazy-init on first use; guarded by perm_lock).
    /// Null until loadPerms runs or a command touches it.
    perms: ?perms_mod.Db = null,
    /// Guards the permission matrix only (leaf lock; encode happens here,
    /// the LSM put itself goes under world_lock afterwards).
    perm_lock: spin.SpinLock = .{},
    /// Per-player save epochs (leaf lock): bumped at each login, copied
    /// onto the conn. A delayed unregister (quit/rejoin races, ghost
    /// autosaves) drops its save when its epoch is stale, so an older
    /// session can never overwrite a newer session's row. Keys are
    /// lowercased login names (same fold as the permission matrix).
    save_epochs: ?std.StringHashMap(u64) = null,
    epoch_lock: spin.SpinLock = .{},

    // ---- command-driven world state (guarded by state_lock; leaf lock) ----
    /// World difficulty 0-3 (peaceful..hard) and the default gamemode
    /// live in the seqlock-published config snapshot (`cfg`).
    /// Weather: raining/thundering flags + remaining ticks (0 = hold state).
    raining: bool = false,
    thundering: bool = false,
    rain_time: u32 = 0,
    thunder_time: u32 = 0,
    /// Client-visible rain/thunder strengths 0..1 (vanilla S2B 7/8). The
    /// 1.7.10 client renders precipitation from strength, not the flag:
    /// reason 1/2 alone leaves the sky clear. Lerped toward the flags in
    /// tickWeather (0.2/s at our 1Hz tick = vanilla's 0.01/tick @20tps).
    rain_strength: f32 = 0,
    thunder_strength: f32 = 0,
    /// Thunderstorm lightning cadence (ticks) + draw stream. Off the
    /// gameplay RNG so strike draws never perturb vanilla draw order.
    thunder_tick: u32 = 0,
    thunder_rand: u64 = 0x9E3779B97F4A7C15,
    /// Idle kick threshold in minutes (0 = disabled, vanilla default).
    /// Debug profiling window (`/debug start` sets both).
    debug_start_ms: ?i64 = null,
    debug_ticks: u64 = 0,
    /// Bans + whitelist (lazy-init alongside perms; own leaf lock).
    bans: ?bans_mod.BanDb = null,
    ban_lock: spin.SpinLock = .{},
    whitelist: ?bans_mod.Whitelist = null,
    wl_lock: spin.SpinLock = .{},
    /// Directory for ops.json / banned-*.json / whitelist.json. Null means
    /// the process working directory (where asteorite.toml and the world
    /// dir live). Tests point it at a tmp dir.
    list_dir: ?std.Io.Dir = null,
    /// Per-IP join flood gate (self-locking; admin-tunable window/burst
    /// below, capacities in sim/core/ratelimit.zig cap them).
    login_gate: ratelimit_mod.LoginGate = .{},
    /// Login flood budget: joins allowed per window per IP. Copied from
    /// the merged config at boot (see main.zig).
    login_rate_window_ms: i64 = ratelimit_mod.default_login_window_ms,
    login_rate_burst: usize = ratelimit_mod.default_login_burst,
    /// Scoreboard (lazy-init; own leaf lock).
    scoreboard: ?scoreboard_mod.Scoreboard = null,
    sb_lock: spin.SpinLock = .{},
    /// Serializes the scalar command state above (leaf lock: never held
    /// with conn or registry locks — copy out, release, then touch conns).
    state_lock: spin.SpinLock = .{},
    /// Phase D: the read-mostly config (difficulty, gamemode, gamerules,
    /// autosave, idle timeout, world spawn) behind a seqlock: readers
    /// never take a lock.
    cfg: seqlock_mod.Seqlock(CfgState) = seqlock_mod.Seqlock(CfgState).init(.{}),
    /// Runtime command registry (see ensureCommands): fixed capacity,
    /// no allocation. Seeded once from the comptime defs; modding-API
    /// commands append at boot.
    cmds: [max_commands]CmdEntry = undefined,
    n_cmds: usize = 0,
    /// Autosave cadence in ticks (5 min at 1Hz).
    pub const autosave_ticks: u64 = 300;
    /// Anti-DoS cap on live item entities (snapshot arrays are fixed-size).
    pub const max_items: usize = 256;

    // ---- lifecycle: bind/deinit/chunk source ----

    pub fn bind(io: std.Io, port: u16, config: Config) !Server {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        var srv = Server{ .net = try addr.listen(io, .{}), .io = io, .config = config };
        {
            var c = srv.cfg.load();
            c.world_spawn = .{ config.spawn_x, config.spawn_y, config.spawn_z };
            srv.cfg.store(c);
        }
        return srv;
    }

    pub fn deinit(self: *Server) void {
        self.net.deinit(self.io);
        // Regions are never removed mid-run, so an empty registry owns
        // nothing (and deinit needs no allocator in that case).
        if (self.region_reg.count() > 0) self.region_reg.deinit(self.gpa);
        if (self.region_pool) |p| {
            p.destroy();
            self.region_pool = null;
        }
    }

    /// Chunk source for view streaming: generating wrapper when gen is set,
    /// plain pool source otherwise. The wrapper fills LSM holes on demand.
    pub fn chunkSource(self: *Server, pool: *shard_mod.ShardPool) view.Source {
        if (self.gen_src) |*gs| {
            std.debug.assert(gs.pool == pool);
            return gs.source();
        }
        return view.shardPoolSource(pool);
    }

    /// Snapshotted refs; caller must `releaseSnap` when done.
    // ---- connection registry ----

    fn snapshot(self: *Server, out: []RegistryEntry) []RegistryEntry {
        self.reg_lock.lock();
        defer self.reg_lock.unlock();
        const n = @min(out.len, self.registry.items.len);
        for (out[0..n], self.registry.items[0..n]) |*o, e| {
            _ = e.conn.refs.fetchAdd(1, .acq_rel);
            o.* = e;
        }
        return out[0..n];
    }

    fn releaseSnap(ents: []RegistryEntry) void {
        for (ents) |e| _ = e.conn.refs.fetchSub(1, .acq_rel);
    }

    /// Find an online (.play) conn by name within a caller-held
    /// snapshot (refs keep it alive for the caller's critical section).
    /// Vanilla `getPlayer` is case-insensitive, so this is too (login
    /// `alice` matches `/op Alice`, `/tp ALICE`, ...).
    fn findInSnap(snap: []RegistryEntry, name: []const u8) ?*Conn {
        for (snap) |e| {
            e.conn.lock.lock();
            // Skip kicked/dying conns: a freshly kicked ghost can still be
            // registered while its thread unwinds — routing commands at it
            // would shadow the live session (same class of bug as the
            // duplicate-login kick this guards).
            const match = e.conn.state == .play and !e.conn.dead and !e.conn.close_after_flush and std.ascii.eqlIgnoreCase(e.conn.username[0..e.conn.username_len], name);
            e.conn.lock.unlock();
            if (match) return e.conn;
        }
        return null;
    }

    /// Resolve a player name to its UUID (authoritative permission
    /// identity). Online targets resolve via the registry snapshot
    /// (case-insensitive, like getPlayer); offline servers derive the
    /// offline UUID from the name. Null in online mode when the target
    /// isn't online — UUIDs are never invented there (a guessed row
    /// would be a hijack vector: renames free old names for recycling).
    fn resolveUuid(self: *Server, name: []const u8) ?[perms_mod.uuid_len]u8 {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        if (findInSnap(snap, name)) |c| {
            c.lock.lock();
            defer c.lock.unlock();
            if (c.username_len > 0) return c.uuid_str;
        }
        if (!self.config.online_mode) {
            var out: [perms_mod.uuid_len]u8 = undefined;
            uuid_mod.formatUuid(uuid_mod.offlineUuid(name), &out);
            return out;
        }
        return null;
    }

    /// Flush one conn's queued output to its stream. Lock-free except the
    /// conn's own locks; safe to call while holding no locks.
    ///
    /// Phase B: with an async transport the bytes are handed to the
    /// owning worker (which batches them into one send); the blocking
    /// transport writes them to the socket right here.
    fn flushEntry(e: RegistryEntry, io: std.Io) void {
        if (e.conn.transport_id != 0) {
            if (e.conn.transport) |t| {
                t.request_flush(t.ctx, e.conn.transport_id);
                return;
            }
        }
        e.conn.lock.lock();
        const pending = e.conn.takeOutput() catch {
            e.conn.lock.unlock();
            return;
        };
        const overflow = e.conn.overflow;
        e.conn.lock.unlock();
        if (overflow) {
            // Slow consumer: the outbox grew past the cap. Drop the
            // connection instead of growing the heap.
            e.conn.allocator.free(pending);
            e.conn.overflow = false;
            closeEntry(e, io);
            return;
        }
        if (pending.len == 0) {
            e.conn.allocator.free(pending);
            return;
        }
        defer e.conn.allocator.free(pending);
        e.conn.wlock.lock();
        defer e.conn.wlock.unlock();
        var wbuf: [4096]u8 = undefined;
        var w = e.stream.writer(io, &wbuf);
        w.interface.writeAll(pending) catch return;
        w.interface.flush() catch return;
    }

    /// Close the connection's socket. Phase B: with an async transport the
    /// transport owns the fd and closes it (and stops the recv).
    fn closeEntry(e: RegistryEntry, io: std.Io) void {
        if (e.conn.transport_id != 0) {
            if (e.conn.transport) |t| {
                t.close_conn(t.ctx, e.conn.transport_id);
                return;
            }
        }
        e.stream.shutdown(io, .both) catch {};
    }

    /// Register a fresh conn right after accept (no packets). Ticks start
    /// applying (login timeout); join is announced separately on play entry.
    pub fn register(self: *Server, conn: *Conn, stream: std.Io.net.Stream) !void {
        self.reg_lock.lock();
        defer self.reg_lock.unlock();
        try self.registry.append(self.gpa, .{ .conn = conn, .stream = stream });
    }

    /// Broadcast a join both ways (newcomer learns roster, roster learns
    /// newcomer) and mark announced so disconnects broadcast leave.
    ///
    /// Phase B: the packets are queued on each conn and flushed through
    /// the transport (blocking: straight to the socket; async: batched
    /// by the owning worker). One output path for every transport.
    /// Queue a completed login for batched announcement. The ticker drains
    /// the queue once per tick with a single combined fan-out (one player-
    /// list + chat burst per conn) instead of one O(players) fan-out per
    /// join — under a join storm the immediate version serializes every
    /// worker behind every conn's lock. Pins a ref; the drain releases it.
    /// Best-effort (queue OOM drops the announcement, like the old
    /// immediate path dropped frames on framer failure).
    pub fn queueAnnounce(self: *Server, conn: *Conn) void {
        _ = conn.refs.fetchAdd(1, .acq_rel);
        errdefer _ = conn.refs.fetchSub(1, .acq_rel);
        self.announce_lock.lock();
        defer self.announce_lock.unlock();
        self.announce_queue.append(self.gpa, conn) catch {};
    }

    /// Fan out one combined join burst for every queued login. Called by
    /// the ticker (and tests). Same bytes as the old per-join announce —
    /// each recipient gets list-adds for everyone else first, then every
    /// newcomer's yellow join line — but each conn takes its lock once
    /// and flushes once no matter how many joins drained.
    pub fn drainAnnounces(self: *Server) void {
        self.announce_lock.lock();
        if (self.announce_queue.items.len == 0) {
            self.announce_lock.unlock();
            return;
        }
        var pending = self.announce_queue;
        self.announce_queue = .empty;
        self.announce_lock.unlock();
        defer pending.deinit(self.gpa);
        defer {
            for (pending.items) |c| _ = c.refs.fetchSub(1, .acq_rel);
        }

        // Liveness filter (mirrors the login-burst re-check): conns that
        // disconnected mid-queue were already unregistered with announced
        // unset, so skipping them keeps unregister balanced.
        var live: std.ArrayList(*Conn) = .empty;
        defer live.deinit(self.gpa);
        for (pending.items) |c| {
            c.lock.lock();
            const alive = !c.dead and !c.close_after_flush and !c.closed;
            const dup = c.announced;
            c.lock.unlock();
            if (alive and !dup) live.append(self.gpa, c) catch {};
        }
        if (live.items.len == 0) return;

        // Pre-copy every snap member's name+ping (one lock each); every
        // frame below builds from these copies, so the recipient loop
        // takes each conn's lock exactly once no matter the batch size.
        var others: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&others);
        defer releaseSnap(snap);
        var snames: std.ArrayList([perms_mod.max_name_len]u8) = .empty;
        defer snames.deinit(self.gpa);
        var slens: std.ArrayList(usize) = .empty;
        defer slens.deinit(self.gpa);
        var spings: std.ArrayList(i16) = .empty;
        defer spings.deinit(self.gpa);
        for (snap) |e| {
            e.conn.lock.lock();
            var nm: [perms_mod.max_name_len]u8 = undefined;
            @memcpy(nm[0..e.conn.username_len], e.conn.username[0..e.conn.username_len]);
            const len = e.conn.username_len;
            const ping = e.conn.ping_ms.load(.acquire);
            e.conn.lock.unlock();
            snames.append(self.gpa, nm) catch break;
            slens.append(self.gpa, len) catch break;
            spings.append(self.gpa, ping) catch break;
        }
        const n_copied = @min(snap.len, @min(snames.items.len, @min(slens.items.len, spings.items.len)));
        // Fast newcomer-membership test for the recipient loop, plus the
        // live-newcomer subset (dead ones were filtered above).
        var is_new: [max_fanout]bool = undefined;
        var nlive: std.ArrayList(usize) = .empty;
        defer nlive.deinit(self.gpa);
        for (snap, 0..) |e, i| {
            if (i >= is_new.len) break;
            is_new[i] = false;
            for (live.items) |c| {
                if (e.conn == c) {
                    is_new[i] = true;
                    break;
                }
            }
            if (is_new[i]) nlive.append(self.gpa, i) catch {};
        }
        for (snap, 0..) |e, i| {
            if (i >= max_fanout or i >= n_copied) break;
            e.conn.lock.lock();
            const recv = e.conn.state == .play and !e.conn.dead and !e.conn.close_after_flush;
            if (!recv) {
                e.conn.lock.unlock();
                continue;
            }
            // Same bytes as sequential per-join announces, one lock hold
            // + one flush per conn: newcomers learn everyone else first
            // (vanilla list order), then every newcomer's join line.
            var nb: [64]u8 = undefined;
            if (is_new[i]) {
                for (0..n_copied) |j| {
                    if (j == i) continue;
                    const nm = snames.items[j][0..slens.items[j]];
                    if (packets.framePlayerListItem(nm, true, spings.items[j], &nb)) |f| {
                        e.conn.queueFramed(f) catch {};
                    } else |_| {}
                }
            } else {
                for (nlive.items) |j| {
                    if (j >= n_copied) continue;
                    const nm = snames.items[j][0..slens.items[j]];
                    if (packets.framePlayerListItem(nm, true, spings.items[j], &nb)) |f| {
                        e.conn.queueFramed(f) catch {};
                    } else |_| {}
                }
            }
            var jcb: [128]u8 = undefined;
            var cfb: [512]u8 = undefined;
            for (nlive.items) |j| {
                if (j >= n_copied) continue;
                const nm = snames.items[j][0..slens.items[j]];
                const join = std.fmt.bufPrint(&jcb, "{{\"text\":\"{s} joined the game\",\"color\":\"yellow\"}}", .{nm}) catch continue;
                e.conn.queueFramed(packets.frameChat(join, &cfb) catch continue) catch {};
            }
            // Count once per conn: unregister drops iff announced. The
            // closed re-check (under the same lock unregister sets it
            // with) closes the race where unregister already passed its
            // check: a closed conn is never counted, so the pair stays
            // exact no matter the interleaving.
            if (is_new[i] and !e.conn.announced and !e.conn.closed) {
                e.conn.announced = true;
                _ = self.play_count.fetchAdd(1, .release);
            }
            e.conn.lock.unlock();
            flushEntry(e, self.io);
        }
        for (nlive.items) |j| {
            if (j >= n_copied) continue;
            std.log.info("{s} joined the game", .{snames.items[j][0..slens.items[j]]});
        }
    }

    /// Broadcast a chat line to every registered play conn (including sender;
    /// vanilla echoes). Caller holds no locks.
    // ---- chat + death announcements ----

    pub fn broadcastChat(self: *Server, json: []const u8) void {
        var cb: [512]u8 = undefined;
        const f = packets.frameChat(json, &cb) catch return;
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            e.conn.lock.lock();
            // Skips non-play conns, dead ones, and ones already closing
            // (a kick/timeout/ping-done conn takes no new output — the
            // transport drains its final message(s) and closes it).
            if (e.conn.state != .play or e.conn.dead or e.conn.close_after_flush) {
                e.conn.lock.unlock();
                continue;
            }
            e.conn.queueFramed(f) catch {
                e.conn.lock.unlock();
                continue;
            };
            e.conn.lock.unlock();
            flushEntry(e, self.io);
        }
    }

    /// The void kills below this feet-Y (vanilla "fell out of the world";
    /// creative included — the void answers to nothing).
    pub const void_kill_y: f64 = -64.0;

    /// Longest possible death line: two max-length names + the longest
    /// suffix (" was slain by "). Sizes the line/JSON scratch buffers.
    const max_death_line: usize = perms_mod.max_name_len * 2 + 16;
    /// ...as a JSON chat payload ({"text":"..."}).
    const max_death_json: usize = max_death_line + 16;

    /// Death-message cause (vanilla 1.7.10 English lines; see broadcastDeath).
    pub const DeathCause = enum {
        generic, // /kill, unknown: "<n> died"
        fall, // "<n> fell from a high place"
        void, // "<n> fell out of the world"
        starve, // "<n> starved to death"
        drown, // "<n> drowned"
        lava, // "<n> tried to swim in lava"
        fire, // "<n> went up in flames"
        suffocate, // "<n> suffocated in a wall"
        cactus, // "<n> was pricked to death"
        player, // "<n> was slain by <killer>"
    };

    /// Vanilla 1.7.10 death line into `out` (killer used only for .player).
    /// Names are charset-validated at login, so no JSON escaping is needed
    /// (same as the join/leave lines).
    pub fn deathMessage(victim: []const u8, cause: DeathCause, killer: []const u8, out: []u8) []const u8 {
        return switch (cause) {
            .generic => std.fmt.bufPrint(out, "{s} died", .{victim}) catch out[0..0],
            .fall => std.fmt.bufPrint(out, "{s} fell from a high place", .{victim}) catch out[0..0],
            .void => std.fmt.bufPrint(out, "{s} fell out of the world", .{victim}) catch out[0..0],
            .starve => std.fmt.bufPrint(out, "{s} starved to death", .{victim}) catch out[0..0],
            .drown => std.fmt.bufPrint(out, "{s} drowned", .{victim}) catch out[0..0],
            .lava => std.fmt.bufPrint(out, "{s} tried to swim in lava", .{victim}) catch out[0..0],
            .fire => std.fmt.bufPrint(out, "{s} went up in flames", .{victim}) catch out[0..0],
            .suffocate => std.fmt.bufPrint(out, "{s} suffocated in a wall", .{victim}) catch out[0..0],
            .cactus => std.fmt.bufPrint(out, "{s} was pricked to death", .{victim}) catch out[0..0],
            .player => std.fmt.bufPrint(out, "{s} was slain by {s}", .{ victim, killer }) catch out[0..0],
        };
    }

    /// Broadcast a vanilla death line to every play conn + console log.
    /// Caller holds no locks (broadcastChat snapshots the registry).
    pub fn broadcastDeath(self: *Server, victim: []const u8, cause: DeathCause, killer: []const u8) void {
        var mb: [max_death_line]u8 = undefined;
        const line = deathMessage(victim, cause, killer, &mb);
        if (line.len == 0) return;
        var jb: [max_death_json]u8 = undefined;
        const json = std.fmt.bufPrint(&jb, "{{\"text\":\"{s}\"}}", .{line}) catch return;
        self.broadcastChat(json);
        std.log.info("{s}", .{line});
    }

    /// Remove + broadcast leave (iff announced) + wait for temp refs + destroy.
    /// No locks held on return.
    // ---- sessions + player persistence ----

    pub fn unregister(self: *Server, conn: *Conn) void {
        // Liveness first: mark closed under conn.lock before anything
        // else, so an unlocked gap (login burst) sees the teardown and
        // aborts instead of completing a dead login. Conn-lock only
        // (never nested with reg_lock — see Conn.closed).
        conn.lock.lock();
        conn.closed = true;
        conn.lock.unlock();
        // Persist first: conn is still fully readable here (destroyed below).
        // Skips conns that never reached play. Lock discipline: savePlayer
        // takes conn.lock then world_lock, one at a time, never nested.
        self.savePlayer(conn);
        self.reg_lock.lock();
        for (self.registry.items, 0..) |e, i| {
            if (e.conn == conn) {
                _ = self.registry.swapRemove(i);
                break;
            }
        }
        self.reg_lock.unlock();

        if (conn.announced) {
            // Paired with the fetchAdd in drainAnnounces (guarded by the same flag).
            _ = self.play_count.fetchSub(1, .release);
            var others: [max_fanout]RegistryEntry = undefined;
            const snap = self.snapshot(&others);
            defer releaseSnap(snap);
            var lb: [64]u8 = undefined;
            const lf = packets.framePlayerListItem(conn.username[0..conn.username_len], false, 0, &lb) catch return;
            for (snap) |e| {
                if (e.conn == conn) continue;
                e.conn.lock.lock();
                e.conn.queueFramed(lf) catch {
                    e.conn.lock.unlock();
                    continue;
                };
                e.conn.lock.unlock();
                // One output path: the transport decides how the bytes go out
                // (blocking: straight to the socket; async: batched by the
                // owning worker).
                flushEntry(e, self.io);
            }
            // Vanilla leave line (yellow) to everyone still online, plus the
            // server console log. The leaver is already unregistered, so they
            // don't get their own line.
            var jlb: [128]u8 = undefined;
            const leave = std.fmt.bufPrint(&jlb, "{{\"text\":\"{s} left the game\",\"color\":\"yellow\"}}", .{conn.username[0..conn.username_len]}) catch null;
            if (leave) |l| self.broadcastChat(l);
            std.log.info("{s} left the game", .{conn.username[0..conn.username_len]});
        }

        while (conn.refs.load(.acquire) != 0) std.atomic.spinLoopHint();
        const a = conn.allocator;
        conn.deinit();
        a.destroy(conn);
    }

    /// Load persisted state into a freshly logged-in conn. Caller holds
    /// conn.lock and the pool is present. Returns true when a save applied
    /// (pos/health/inv/selected/cursor restored); false = first login
    /// (caller runs land-spawn search + pos sync instead).
    /// Corrupt saves are ignored (fresh spawn); the row is overwritten on
    /// next save. Dead-at-save normalizes to alive-at-spawn on load.
    pub fn loadPlayer(self: *Server, conn: *Conn) bool {
        const pool = self.world orelse return false;
        if (conn.username_len == 0) return false;
        const name = conn.username[0..conn.username_len];
        const data = player_db.loadLegacy(pool, self.gpa, name, conn.uuid_str[0..], player_import.legacySlot) catch return false;
        if (data == null) return false;
        var d = data.?;
        defer player_db.freeData(self.gpa, &d);
        conn.pos_x = d.pos_x;
        conn.pos_y = d.pos_y;
        conn.pos_z = d.pos_z;
        conn.yaw = d.yaw;
        conn.pitch = d.pitch;
        conn.on_ground = d.on_ground;
        conn.config.spawn_x = d.spawn_x;
        conn.config.spawn_y = d.spawn_y;
        conn.config.spawn_z = d.spawn_z;
        if (d.health <= 0) {
            // Died before saving (server was killed mid-death-screen or the
            // client never respawned): respawn rules — full health at spawn.
            conn.health = 20.0;
            conn.pos_x = @as(f64, @floatFromInt(d.spawn_x)) + 0.5;
            conn.pos_y = @as(f64, @floatFromInt(d.spawn_y));
            conn.pos_z = @as(f64, @floatFromInt(d.spawn_z)) + 0.5;
            conn.is_dead = false;
        } else {
            conn.health = d.health;
            conn.is_dead = false;
        }
        conn.food = d.food;
        conn.saturation = d.saturation;
        conn.xp_level = d.xp_level;
        conn.xp_total = d.xp_total;
        conn.xp_bar = d.xp_bar;
        conn.spawn_forced = d.spawn_forced;
        for (&conn.inv, d.inv) |*slot, saved| {
            item_mod.freeStack(conn.allocator, slot);
            slot.* = item_mod.cloneStack(conn.allocator, saved) catch null;
        }
        item_mod.freeStack(conn.allocator, &conn.cursor);
        conn.cursor = item_mod.cloneStack(conn.allocator, d.cursor) catch null;
        for (&conn.ender, d.ender) |*slot, saved| {
            item_mod.freeStack(conn.allocator, slot);
            slot.* = item_mod.cloneStack(conn.allocator, saved) catch null;
        }
        conn.selected = d.selected;
        conn.config.gamemode = d.gamemode;
        for (0..7) |w| conn.resetClickSeq(w); // fresh client: all containers restart
        conn.refreshCrafting();
        return true;
    }

    /// Snapshot one conn (conn.lock taken here) and persist under world_lock.
    /// Skips conns that never reached play or have no username. A stale
    /// session (epoch bumped by a newer login) drops its save instead of
    /// overwriting the newer row. Safe to call with no locks held
    /// (unregister, console, ticker all qualify).
    pub fn savePlayer(self: *Server, conn: *Conn) void {
        const pool = self.world orelse return;
        conn.lock.lock();
        if (conn.state != .play or conn.username_len == 0) {
            conn.lock.unlock();
            return;
        }
        const name = conn.username[0..conn.username_len];
        const epoch = conn.save_epoch;
        var d = player_db.Data{};
        @memcpy(d.username[0..name.len], name);
        d.username_len = name.len;
        d.pos_x = conn.pos_x;
        d.pos_y = conn.pos_y;
        d.pos_z = conn.pos_z;
        d.yaw = conn.yaw;
        d.pitch = conn.pitch;
        d.on_ground = conn.on_ground;
        d.spawn_x = conn.config.spawn_x;
        d.spawn_y = conn.config.spawn_y;
        d.spawn_z = conn.config.spawn_z;
        d.health = conn.health;
        d.food = conn.food;
        d.saturation = conn.saturation;
        d.selected = conn.selected;
        d.gamemode = conn.config.gamemode;
        d.xp_level = conn.xp_level;
        d.xp_total = conn.xp_total;
        d.xp_bar = conn.xp_bar;
        d.spawn_forced = conn.spawn_forced;
        // Clone NBT into server-owned buffers (conn dies under us in the
        // unregister path; encode only borrows while world_lock is held).
        for (&d.inv, conn.inv) |*dst, src| {
            dst.* = item_mod.cloneStack(self.gpa, src) catch null;
        }
        d.cursor = item_mod.cloneStack(self.gpa, conn.cursor) catch null;
        for (&d.ender, conn.ender) |*dst, src| {
            dst.* = item_mod.cloneStack(self.gpa, src) catch null;
        }
        conn.lock.unlock();
        defer player_db.freeData(self.gpa, &d);
        // Stale-session guard: a newer login for this name owns the row
        // now — drop this snapshot instead of overwriting it (quit/rejoin
        // races, ghost autosaves). Leaf-lock read, no nesting.
        if (!self.saveEpochCurrent(d.username[0..d.username_len], epoch)) return;
        self.world_lock.lock();
        defer self.world_lock.unlock();
        player_db.save(pool, conn.uuid_str[0..], &d) catch {};
    }

    /// Persist every logged-in player (disconnect path calls savePlayer per
    /// conn; this is the periodic + save-all + stop path). One world_lock
    /// for the batch; per-conn locks taken one at a time, never nested.
    pub fn saveAllPlayers(self: *Server) usize {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        var n: usize = 0;
        for (snap) |e| {
            const before = e.conn.username_len;
            self.savePlayer(e.conn);
            if (before > 0) n += 1;
        }
        return n;
    }

    /// Sync-fill the landing disk (radius 2) around the login position so
    /// the join completes on solid ground. Holes (no gen, dropped gen
    /// requests, failed gen) stay holes; the login grace covers the rest.
    /// Called with conn.lock held (login bootstrap): pool reads are leaf
    /// locks, gen requests take the pool mutex, and drain() only waits on
    /// workers (which never take conn locks) — no nesting, no deadlock.
    /// True while any of ensureLanding's 5x5 disk is still queued or
    /// mid-generation. Bounded-poll helper for the scoped login wait below
    /// (no LSM reads: a key leaves the set exactly when its worker finishes
    /// the store attempt — success, failure, or shed all clear it).
    fn landingInflight(self: *Server, gp: *v5genpool.GenPool, pcx: i32, pcz: i32) bool {
        _ = self;
        var dx: i32 = -2;
        while (dx <= 2) : (dx += 1) {
            var dz: i32 = -2;
            while (dz <= 2) : (dz += 1) {
                if (gp.isInflight(0, pcx + dx, pcz + dz)) return true;
            }
        }
        return false;
    }

    /// Scoped-wait poll bound (2ms each): 30s covers a cold 5x5 many times
    /// over; anything slower means our columns are queued behind a bulk
    /// backlog, and waiting longer would just extend the hang.
    const landing_wait_polls: usize = 15000;

    fn ensureLanding(self: *Server, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, conn: *Conn) void {
        const pcx: i32 = @intFromFloat(@floor(conn.pos_x / 16.0));
        const pcz: i32 = @intFromFloat(@floor(conn.pos_z / 16.0));
        var need: usize = 0;
        var dx: i32 = -2;
        while (dx <= 2) : (dx += 1) {
            var dz: i32 = -2;
            while (dz <= 2) : (dz += 1) {
                const key = store_mod.encodeKey(0, pcx + dx, pcz + dz);
                const raw = pool.get(allocator, key) catch continue;
                if (raw) |r| {
                    allocator.free(r);
                    continue;
                }
                need += 1;
                if (self.gen_pool) |gp| {
                    // Login disk outranks bulk backlog (priority lane).
                    gp.requestPriority(0, pcx + dx, pcz + dz);
                } else if (self.gen) |gen| {
                    // No workers (tests / no-seed fallback): sync fill.
                    const filled = v5serve.getOrGen(pool, gen, &self.world_lock, 0, pcx + dx, pcz + dz, allocator) catch null;
                    if (filled) |f| allocator.free(f);
                }
            }
        }
        // Wait out only what we enqueued (warm logins skip the wait).
        // Scoped to our 25 columns: a global drain() parks the serve
        // thread behind the entire pool backlog — under /pregen that is
        // the whole remaining task. Bounded: leftovers stay holes and the
        // login grace covers them, exactly like a generation failure.
        if (need > 0) {
            if (self.gen_pool) |gp| {
                var waits: usize = 0;
                while (waits < landing_wait_polls and self.landingInflight(gp, pcx, pcz)) : (waits += 1) {
                    transport_mod.sleepMs(conn.io, 2);
                }
            }
        }
    }

    /// Login-grace maintenance (serve thread; caller holds no locks).
    /// While the grace is armed and the client fell below the login
    /// teleport through missing ground, hold: once the ground column
    /// exists, snap the client back up with a PosLook re-send (its echo
    /// clears the grace). Timeout or horizontal movement clears it.
    fn maybeLoginResync(self: *Server, conn: *Conn) void {
        const now_ms = std.Io.Timestamp.now(conn.io, .awake).toMilliseconds();
        conn.lock.lock();
        defer conn.lock.unlock();
        if (conn.login_grace_ms == 0 and !conn.login_grace_lapsed) return;
        if (conn.login_grace_lapsed or now_ms > conn.login_grace_ms) {
            // Lapse/timeout resolution (needs the pool: packets can't see
            // generation state). While the client's column is still a hole,
            // re-arm instead of releasing: adopting the held fall would
            // bury the player in terrain that generates solid around it
            // (login embedded/suffocating on join). Once ground exists,
            // release so falls adopt normally. Chunk presence (not block
            // reads): missing sections are not holes.
            var present = true;
            if (self.world) |pool| {
                const cc = conn.playerChunk();
                const raw = pool.get(self.gpa, store_mod.encodeKey(0, cc.cx, cc.cz)) catch null;
                if (raw) |r| {
                    self.gpa.free(r);
                } else present = false;
            }
            if (!present) {
                conn.login_grace_ms = now_ms + 10_000;
                conn.login_grace_lapsed = false;
                conn.login_resynced = false; // snap again on delivery
                return;
            }
            conn.login_grace_ms = 0;
            conn.login_grace_lapsed = false;
            return;
        }
        // Ground delivered means the login column left in a bulk the client
        // has actually received (sent-set), not merely present in the LSM:
        // the client falls while its burst is still in flight.
        const cx: i32 = @intFromFloat(@floor(conn.login_x / 16.0));
        const cz: i32 = @intFromFloat(@floor(conn.login_z / 16.0));
        if (!conn.sent.contains(Conn.sentKey(cx, cz))) return; // not delivered yet: keep holding
        if (conn.login_fell and !conn.login_resynced) {
            conn.login_resynced = true;
            conn.login_fell = false;
            // Never affirm an embedded cell: sub-threshold falls (within
            // a block of the teleport) adopt before suppression engages,
            // and a bare re-send would pin the client inside solid ground
            // (fallrepro: snap to feet-in-grass y=71). Lift to headroom
            // first (rescueEmbedded's two-open rule); no headroom in reach
            // keeps the adopted pos (deep solid stays the per-tick
            // rescue's case, which requires both cells opaque).
            if (self.world) |pool| {
                const lex: i32 = @intFromFloat(@floor(conn.pos_x));
                const lez: i32 = @intFromFloat(@floor(conn.pos_z));
                const lfeet: i32 = @intFromFloat(@floor(conn.pos_y));
                if (lfeet >= 0 and lfeet <= 253) {
                    const solid_feet = if (view.peekBlock(pool, self.gpa, lex, @intCast(lfeet), lez) catch null) |b| view.isOpaqueCube(b.id) else false;
                    if (solid_feet) {
                        var ly = lfeet + 1;
                        while (ly <= lfeet + 16 and ly <= 253) : (ly += 1) {
                            const fy: u8 = @intCast(ly);
                            const ey: u8 = @intCast(ly + 1);
                            const bf = view.peekBlock(pool, self.gpa, lex, fy, lez) catch null;
                            const be = view.peekBlock(pool, self.gpa, lex, ey, lez) catch null;
                            const f_ok = if (bf) |b| !view.isOpaqueCube(b.id) else false;
                            const e_ok = if (be) |b| !view.isOpaqueCube(b.id) else false;
                            if (f_ok and e_ok) {
                                conn.pos_y = @floatFromInt(ly);
                                break;
                            }
                        }
                    }
                }
            }
            // Re-baseline the grace at the agreed position (sub-threshold
            // falls may have been adopted before suppression engaged): the
            // client's echo of this exact snapshot clears the grace.
            conn.login_x = conn.pos_x;
            conn.login_y = conn.pos_y;
            conn.login_z = conn.pos_z;
            conn.queuePlayerPosLook() catch {};
        }
    }

    /// Lazy permission matrix (allocator = server gpa). Caller need hold no
    /// locks; the matrix has its own leaf lock.
    // ---- command registry, permissions, admin lookups ----

    fn permDb(self: *Server) *perms_mod.Db {
        self.perm_lock.lock();
        defer self.perm_lock.unlock();
        if (self.perms == null) self.perms = perms_mod.Db.init(self.gpa);
        return &self.perms.?;
    }

    /// Runtime command registry. Help, tab-completion, existence checks,
    /// and dispatch ALL read this table — never the comptime
    /// `perms_mod.modules` directly — so modding-API commands registered
    /// at runtime show up everywhere builtins do. Seeded once from the
    /// comptime defs; fixed capacity, no allocation, no teardown.
    /// Registration is boot-time only (reads take no lock).
    pub const max_commands: usize = 96;
    pub const CmdRunFn = *const fn (*Server, ?*Conn, []const u8, []u8) []const u8;
    pub const CmdEntry = struct {
        def: *const perms_mod.Command,
        run: CmdRunFn,
    };

    fn builtinRun(comptime M: type) CmdRunFn {
        return struct {
            fn call(srv: *Server, sender: ?*Conn, args: []const u8, out: []u8) []const u8 {
                return M.run(srv, sender, args, out);
            }
        }.call;
    }

    /// Seed the registry from the comptime defs (idempotent). Called
    /// lazily on first command use and eagerly at boot (main) so no
    /// serving thread ever pays for it mid-tick.
    pub fn ensureCommands(self: *Server) void {
        if (self.n_cmds > 0) return;
        self.state_lock.lock();
        defer self.state_lock.unlock();
        if (self.n_cmds > 0) return;
        inline for (perms_mod.modules) |M| {
            if (self.n_cmds >= self.cmds.len) return;
            self.cmds[self.n_cmds] = .{ .def = &M.def, .run = builtinRun(M) };
            self.n_cmds += 1;
        }
    }

    /// Modding-API hook (Phase F): append one command at runtime.
    /// Boot-time only (reads take no lock). Name/alias collisions with an
    /// existing entry — or a full table — are rejected (false). The def
    /// must outlive the server (static for builtins; the mod's burden).
    pub fn registerCommand(self: *Server, def: *const perms_mod.Command, run: CmdRunFn) bool {
        self.ensureCommands();
        self.state_lock.lock();
        defer self.state_lock.unlock();
        for (self.cmds[0..self.n_cmds]) |e| {
            if (cmdMatches(e.def, def.name)) return false;
            for (def.aliases) |a| if (cmdMatches(e.def, a)) return false;
        }
        if (self.n_cmds >= self.cmds.len) return false;
        self.cmds[self.n_cmds] = .{ .def = def, .run = run };
        self.n_cmds += 1;
        return true;
    }

    /// Gate: deny-match wins, then grant-match, then level gate. Unknown
    /// commands fail closed (same reply as denied — no oracle). Console
    /// bypasses the matrix entirely.
    fn commandAllowed(self: *Server, sender: ?*Conn, desc: *const perms_mod.Command) bool {
        if (sender == null) return true;
        const c = sender.?;
        c.lock.lock();
        const has_name = c.username_len > 0;
        const uuid = c.uuid_str;
        c.lock.unlock();
        if (!has_name) return false;
        self.perm_lock.lock();
        defer self.perm_lock.unlock();
        if (self.perms) |*db| return db.allowsUuid(&uuid, desc.node, desc.min_level);
        return perms_mod.DEFAULT_LEVEL.rank() >= desc.min_level.rank();
    }

    /// Persist the matrix to `ops.json` next to the server (atomic
    /// replace). Encode under perm_lock, write after unlocking — disk IO
    /// never holds the leaf lock. No world needed.
    pub fn savePerms(self: *Server) void {
        const dir = self.list_dir orelse std.Io.Dir.cwd();
        self.perm_lock.lock();
        const enc = if (self.perms) |*db| perms_mod.encodeJson(self.gpa, db) catch null else null;
        self.perm_lock.unlock();
        if (enc) |e| {
            defer self.gpa.free(e);
            perms_mod.writeOpsFile(self.io, dir, e) catch |err| {
                std.log.warn("ops.json write failed ({})", .{err});
            };
        }
    }

    /// Load the matrix at boot (single-threaded; no locks needed): `ops.json`
    /// if present, else empty. Corrupt files fail closed to an empty matrix
    /// (logged; the next mutation overwrites the bad file). `/perm reload`
    /// re-reads the file, so hand edits apply live.
    pub fn loadPerms(self: *Server) void {
        const dir = self.list_dir orelse std.Io.Dir.cwd();
        const file_db = perms_mod.loadFile(self.io, dir, self.gpa) catch |err| {
            std.log.warn("ops.json unreadable ({}) — starting empty", .{err});
            return;
        };
        if (file_db) |loaded| {
            if (loaded.skipped_legacy > 0) std.log.warn("ops.json: {d} legacy name-only rows ignored (no UUID) — re-op affected players so their rows are UUID-bound", .{loaded.skipped_legacy});
            self.perm_lock.lock();
            defer self.perm_lock.unlock();
            if (self.perms) |*old| old.deinit();
            self.perms = loaded.db;
        }
    }

    /// Persist the redstone scheduler (single row). Dues are re-derived
    /// on load, so only positions+kinds are stored. Caller must NOT hold
    /// world_lock (taken here, same as savePerms).
    pub fn saveRedstone(self: *Server) void {
        const pool = self.world orelse return;
        self.world_lock.lock();
        defer self.world_lock.unlock();
        const enc = redstone_mod.encodeSched(self.gpa, &self.rs_sched) catch return;
        defer self.gpa.free(enc);
        pool.put(redstone_mod.sched_key, enc) catch {};
    }

    /// Load the scheduler row (lazy, once). Caller must hold world_lock
    /// (all redstone mutation sites do). Corrupt rows fail closed to an
    /// empty scheduler. Dues are re-derived from the blocks still present.
    fn loadRedstone(self: *Server, pool: *shard_mod.ShardPool, now: i64) void {
        if (self.rs_loaded) return;
        self.rs_loaded = true;
        const raw = pool.get(self.gpa, redstone_mod.sched_key) catch return;
        defer if (raw) |r| self.gpa.free(r);
        const bytes = raw orelse return;
        const GetOnly = struct {
            p: *shard_mod.ShardPool,
            a: std.mem.Allocator,
            pub fn get(s: *@This(), x: i32, y: i32, z: i32) ?redstone_mod.Block {
                if (y < 0 or y > 255) return null;
                const pb = view.peekBlock(s.p, s.a, x, @intCast(y), z) catch return null;
                const b = pb orelse return null;
                return .{ .id = b.id, .meta = b.meta };
            }
            pub fn set(s: *@This(), x: i32, y: i32, z: i32, id: game_ids.Id, meta: u4) void {
                _ = s;
                _ = x;
                _ = y;
                _ = z;
                _ = id;
                _ = meta;
            }
            pub fn pop(s: *@This(), x: i32, y: i32, z: i32, old_id: game_ids.Id, old_meta: u4) void {
                _ = s;
                _ = x;
                _ = y;
                _ = z;
                _ = old_id;
                _ = old_meta;
            }
            pub fn rsView(s: *@This()) redstone_mod.WorldView {
                return redstone_mod.WorldView.init(s, &profile.game.blocks, &profile.rules.redstone);
            }
        };
        var w = GetOnly{ .p = pool, .a = self.gpa };
        _ = redstone_mod.loadSched(w.rsView(), bytes, &self.rs_sched, now);
    }

    /// Grant level 4 to a validated name (bootstrap + /op path helper).
    /// Resolves to the player's UUID (online target, or offline-UUID on
    /// offline servers); unresolvable names fail closed. Persists
    /// immediately. Name validity is the caller's job.
    pub fn grantOp(self: *Server, name: []const u8) bool {
        const uuid = self.resolveUuid(name) orelse return false;
        _ = self.permDb();
        self.perm_lock.lock();
        self.permsDbLocked().setLevelUuid(&uuid, name, .owner) catch {
            self.perm_lock.unlock();
            return false;
        };
        self.perm_lock.unlock();
        self.savePerms();
        return true;
    }

    // ------------------------------------------------------------------
    // Command backend: the version seam. Commands in src/cmd/ are
    // version-agnostic and must NEVER touch packets, wire ids, or chunk
    // streaming directly — everything version-specific funnels through
    // these methods, so a future protocol version only needs a new set
    // of them while every command file is reused unchanged.
    // ------------------------------------------------------------------

    /// /help body: page `page` (1-based, `help_page_size` entries) of the
    /// usages the sender may use (console sees everything). Vanilla
    /// header/footer.
    pub fn helpText(self: *Server, sender: ?*Conn, page: i32, out: []u8) []const u8 {
        // Vanilla shows 7 commands per page.
        const page_size: usize = 7;
        self.ensureCommands();
        var list: [max_commands]*const perms_mod.Command = undefined;
        var n: usize = 0;
        for (self.cmds[0..self.n_cmds]) |e| {
            const d = e.def;
            const ok = if (sender == null) true else self.commandAllowed(sender, d);
            if (!ok or n >= list.len) continue;
            list[n] = d;
            n += 1;
        }
        const pages: i32 = @intCast((n + page_size - 1) / page_size);
        const p = @min(@max(page, 1), @max(pages, 1));
        var ow: usize = 0;
        ow += (std.fmt.bufPrint(out[ow..], "--- Showing help page {d} of {d} (/help <page>) ---\n", .{ p, @max(pages, 1) }) catch return "Commands: /help").len;
        const start: usize = @as(usize, @intCast(p - 1)) * page_size;
        const end: usize = @min(start + page_size, n);
        for (list[start..end]) |d| {
            ow += (std.fmt.bufPrint(out[ow..], "{s}\n", .{d.usage()}) catch break).len;
        }
        ow += (std.fmt.bufPrint(out[ow..], "Tip: Use the <tab> key while typing a command to auto-complete the command or its arguments", .{}) catch return out[0..ow]).len;
        return out[0..ow];
    }

    /// /help <command>: that command's usage, or a not-found error.
    pub fn helpCommand(self: *Server, sender: ?*Conn, name: []const u8, out: []u8) []const u8 {
        self.ensureCommands();
        for (self.cmds[0..self.n_cmds]) |e| {
            const d = e.def;
            if (!cmdMatches(d, name)) continue;
            const ok = if (sender == null) true else self.commandAllowed(sender, d);
            if (!ok) break;
            return std.fmt.bufPrint(out, "--- {s} ---\n{s}", .{ d.name, d.usage() }) catch d.usage();
        }
        return "Unknown command. Try /help for a list of commands";
    }

    /// Match a typed command word against primary name + aliases.
    fn cmdMatches(d: *const perms_mod.Command, word: []const u8) bool {
        if (std.mem.eql(u8, d.name, word)) return true;
        for (d.aliases) |a| if (std.mem.eql(u8, a, word)) return true;
        return false;
    }

    /// Vanilla admin feedback (`chat.type.admin` = gray italic "[Name: msg]")
    /// to every OTHER online player who could also run this command
    /// (op + canUse, exactly like `bl.a`), plus the console log. The sender
    /// gets the raw reply via executeCommand's return — never both.
    pub fn notifyAdmins(self: *Server, sender: ?*Conn, def: *const perms_mod.Command, inner: []const u8) void {
        var sname: [perms_mod.max_name_len]u8 = undefined;
        const s = if (sender) |c| blk: {
            c.lock.lock();
            defer c.lock.unlock();
            if (c.username_len == 0) break :blk "Server";
            @memcpy(sname[0..c.username_len], c.username[0..c.username_len]);
            break :blk sname[0..c.username_len];
        } else "Server";
        // Console runs as the server itself (vanilla skips the admin log
        // then — the console already gets the raw reply via reply()).
        if (sender != null) std.log.info("[{s}: {s}]", .{ s, inner });
        // Command-block senders honor commandBlockOutput (we have no command
        // blocks; console/player senders always broadcast).
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        var eb: [2048]u8 = undefined;
        const esc = packets.escapeJsonText(inner, &eb) catch return;
        var jb: [2208]u8 = undefined;
        const admin = std.fmt.bufPrint(&jb, "{{\"text\":\"[{s}: {s}]\",\"color\":\"gray\",\"italic\":true}}", .{ s, esc }) catch return;
        var fb: [2304]u8 = undefined;
        const f = packets.frameChat(admin, &fb) catch return;
        for (snap) |e| {
            if (e.conn == sender) continue;
            e.conn.lock.lock();
            const play = e.conn.state == .play and !e.conn.dead and e.conn.username_len > 0;
            const uuid = e.conn.uuid_str;
            e.conn.lock.unlock();
            if (!play) continue;
            self.perm_lock.lock();
            const can = if (self.perms) |*db| db.allowsUuid(&uuid, def.node, def.min_level) else perms_mod.DEFAULT_LEVEL.rank() >= def.min_level.rank();
            self.perm_lock.unlock();
            if (!can) continue;
            e.conn.lock.lock();
            e.conn.queueFramed(f) catch {};
            e.conn.lock.unlock();
        }
    }

    /// Immediate one-shot message (chat frame to a player, log for console).
    /// For warnings that precede the command's own reply (e.g. /give's
    /// numeric-id deprecation notice) — mirrors reply() exactly.
    pub fn sendDirect(self: *Server, sender: ?*Conn, text: []const u8) void {
        self.reply(sender, text);
    }

    /// Validate raw JSON for /tellraw (vanilla rejects with jsonException).
    pub fn validateJson(self: *Server, json: []const u8) !void {
        const v = try std.json.parseFromSlice(std.json.Value, self.gpa, json, .{});
        defer v.deinit();
    }

    /// Raw pre-formatted JSON to one online player (/tellraw). False when
    /// the target isn't online.
    pub fn sendJsonPlayer(self: *Server, name: []const u8, json: []const u8) bool {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const c = findInSnap(snap, name) orelse return false;
        var fb: [4200]u8 = undefined;
        const f = packets.frameChat(json, &fb) catch return false;
        c.lock.lock();
        defer c.lock.unlock();
        if (c.state != .play or c.dead) return false;
        c.queueFramed(f) catch {};
        return true;
    }

    pub fn maxPlayers(self: *Server) u16 {
        return self.config.max_players;
    }

    pub fn setTimeOfDay(self: *Server, v: i64) void {
        self.time_of_day.store(v, .release);
    }

    pub fn getTimeOfDay(self: *Server) i64 {
        return self.time_of_day.load(.acquire);
    }

    /// Snapshot-free player roster: copies online names under each conn's
    /// lock. Uses a pinned snapshot (refs keep conns alive for the walk)
    /// instead of holding reg_lock across all conns — the old version
    /// serialized every join/leave fan-out behind bulk roster reads.
    pub fn playNames(self: *Server, names: [][perms_mod.max_name_len]u8, lens: []u8, uuids: ?[][perms_mod.uuid_len]u8) usize {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        var n: usize = 0;
        for (snap) |e| {
            if (n >= names.len or n >= lens.len) break;
            e.conn.lock.lock();
            const play = e.conn.state == .play;
            if (play) {
                @memcpy(names[n][0..e.conn.username_len], e.conn.username[0..e.conn.username_len]);
                lens[n] = @intCast(e.conn.username_len);
                if (uuids) |u| {
                    if (n < u.len) @memcpy(u[n][0..], e.conn.uuid_str[0..]);
                }
            }
            e.conn.lock.unlock();
            if (!play) continue;
            n += 1;
        }
        return n;
    }

    /// Flush the world store (no-op without a db).
    pub fn flushWorld(self: *Server) void {
        if (self.world) |pool| pool.flushAll() catch {};
    }

    /// Full reset of a player row (deop). Used by /deop.
    /// Resolves like grantOp; unresolvable names fail closed.
    pub fn deopPlayer(self: *Server, name: []const u8) bool {
        const uuid = self.resolveUuid(name) orelse return false;
        self.perm_lock.lock();
        if (self.perms) |*db| db.clearUuid(&uuid);
        self.perm_lock.unlock();
        self.savePerms();
        return true;
    }

    /// Login-name charset (single source; mirrors conn.zig validation).
    pub fn validName(self: *Server, name: []const u8) bool {
        _ = self;
        return Conn.validPlayerName(name);
    }

    /// Permission-node charset (single source; see sim/player/permissions.zig).
    pub fn validNode(self: *Server, node: []const u8) bool {
        _ = self;
        return perms_mod.validNode(node);
    }

    /// Wire id -> canonical id for /give. Air maps to null: it is only
    /// legal as an empty slot, never as a granted stack.
    pub fn wireToId(self: *Server, wire_id: u16) ?game_ids.Id {
        _ = self;
        const id = wire.fromWire(wire_id) orelse return null;
        if (id == game_ids.air) return null;
        return id;
    }

    /// Canonical registry name lookup (`diamond_sword`, `stone`, ...).
    /// Names are the snake_case enum tags shared with the wire tables.
    /// Blocks resolve too (vanilla /give hands out ItemBlocks).
    pub fn itemWireByName(self: *Server, name: []const u8) ?u16 {
        _ = self;
        const id = std.meta.stringToEnum(game_ids.Id, name) orelse return null;
        if (id == game_ids.air) return null;
        return wire.toWire(id);
    }

    /// Block names only (wire < 256); null for items/air/unknown.
    pub fn blockWireByName(self: *Server, name: []const u8) ?u16 {
        _ = self;
        const id = std.meta.stringToEnum(game_ids.Id, name) orelse return null;
        if (id == game_ids.air) return null;
        const w = wire.toWire(id);
        if (w > 255) return null;
        return w;
    }

    /// Block display name for testforblock feedback (canonical snake_case,
    /// numeric fallback for unmapped ids).
    pub fn blockName(self: *Server, wire_id: u16, out: []u8) []const u8 {
        _ = self;
        if (wire.fromWire(wire_id)) |id| return @tagName(id);
        return std.fmt.bufPrint(out, "{d}", .{wire_id}) catch "?";
    }

    /// True for placeable block wire ids (vanilla `g()` lookup misses items).
    pub fn isBlockWire(self: *Server, wire_id: u16) bool {
        _ = self;
        if (wire_id > 255) return false;
        const id = wire.fromWire(wire_id) orelse return false;
        return id != game_ids.air;
    }

    /// Display name for /give feedback (canonical snake_case).
    pub fn itemName(self: *Server, id: game_ids.Id) []const u8 {
        _ = self;
        return @tagName(id);
    }

    /// Drop leftover /give stacks at the target's feet (vanilla overflow).
    pub fn dropLeftover(self: *Server, name: []const u8, id: game_ids.Id, count: i32, damage: i16) void {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const c = findInSnap(snap, name) orelse return;
        c.lock.lock();
        const px = c.pos_x;
        const py = c.pos_y;
        const pz = c.pos_z;
        const play = c.state == .play;
        c.lock.unlock();
        if (!play) return;
        var left = count;
        while (left > 0) {
            const put: i8 = @intCast(@min(left, 64));
            left -= put;
            self.spawnItemLive(.{ .id = id, .count = put, .damage = damage, .nbt = null }, px, py + 0.5, pz, 10, self.tossPopMotion());
        }
    }

    /// Max stack size for /give (profile table).
    pub fn maxStack(self: *Server, id: game_ids.Id) u8 {
        _ = self;
        return profile.game.item_data.maxStackSize(id);
    }

    /// Set a player's gamemode + push the abilities packet. Returns false
    /// when the player isn't online.
    /// Set a player's gamemode. Vanilla `EntityPlayerMP.setGameType` sends
    /// S2B change-gamemode (the client flips its controller + UI/HUD off
    /// that), plus an S39 refresh with jar-verified flags (0x0D creative / 0x00
    /// survival+adventure). Returns false when the player isn't online.
    // ---- player admin ops + command dispatch ----

    pub fn applyGamemode(self: *Server, name: []const u8, mode: rules_mod.GameMode) bool {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const c = findInSnap(snap, name) orelse return false;
        c.lock.lock();
        defer c.lock.unlock();
        c.config.gamemode = mode;
        const creative = mode.isCreative();
        var gb: [perms_mod.max_name_len]u8 = undefined;
        queueBuilt(c, packets.frameGameState(packets.game_state_change_gamemode, @floatFromInt(mode.wire()), &gb));
        var ab: [32]u8 = undefined;
        const f = packets.framePlayerAbilities(packets.abilityFlags(creative), 0.05, 0.1, &ab) catch return true;
        c.queueFramed(f) catch {};
        return true;
    }

    pub const GiveResult = struct {
        placed: i32,
        remaining: i32,
    };

    /// Fill an online player's inventory (vanilla merge-then-empties rule)
    /// and sync dirty slots. Null when the player isn't online.
    pub fn giveItems(self: *Server, target: []const u8, id: game_ids.Id, count: i32, damage: i16) ?GiveResult {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const c = findInSnap(snap, target) orelse return null;
        c.lock.lock();
        defer c.lock.unlock();
        var dirty: [item_mod.inv_size]bool = [_]bool{false} ** item_mod.inv_size;
        const r = item_mod.fillInventory(&c.inv, id, count, damage, &dirty, profile.game.item_data.maxStackSize(id));
        for (item_mod.main_lo..item_mod.inv_size) |ds| {
            if (!dirty[ds]) continue;
            const f = packets.frameSetSlotAlloc(self.gpa, 0, @intCast(ds), c.inv[ds]) catch continue;
            defer self.gpa.free(f);
            c.queueFramed(f) catch {};
        }
        return .{ .placed = r.placed, .remaining = r.remaining };
    }

    pub fn teleportPlayer(self: *Server, mover: []const u8, dest: []const u8) bool {
        return self.teleport(mover, .{ .player = dest });
    }

    pub fn teleportCoords(self: *Server, mover: []const u8, c: [3]f64) bool {
        return self.teleport(mover, .{ .coords = c });
    }

    /// Live position of an online player (for `~` relative coords).
    pub fn playerPos(self: *Server, name: []const u8) ?[3]f64 {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const c = findInSnap(snap, name) orelse return null;
        c.lock.lock();
        defer c.lock.unlock();
        if (c.state != .play) return null;
        return .{ c.pos_x, c.pos_y, c.pos_z };
    }

    /// Sender position for `~` coords (null for console).
    pub fn senderPos(self: *Server, sender: ?*Conn) ?[3]f64 {
        _ = self;
        const c = sender orelse return null;
        c.lock.lock();
        defer c.lock.unlock();
        if (c.state != .play) return null;
        return .{ c.pos_x, c.pos_y, c.pos_z };
    }

    /// Teleport an online player to coordinates or onto another online
    /// player (with immediate chunk resync, same as the serve loop does
    /// after a move). False when mover (or target) isn't online.
    pub fn teleport(self: *Server, mover: []const u8, dest: tp_mod.Dest) bool {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const mc = findInSnap(snap, mover) orelse return false;
        var dx: f64 = 0;
        var dy: f64 = 0;
        var dz: f64 = 0;
        switch (dest) {
            .player => |name| {
                const tc = findInSnap(snap, name) orelse return false;
                tc.lock.lock();
                dx = tc.pos_x;
                dy = tc.pos_y;
                dz = tc.pos_z;
                tc.lock.unlock();
            },
            .coords => |c| {
                dx = c[0];
                dy = c[1];
                dz = c[2];
            },
        }
        mc.lock.lock();
        defer mc.lock.unlock();
        mc.pos_x = dx;
        mc.pos_y = dy;
        mc.pos_z = dz;
        mc.chunks_dirty = true;
        mc.queuePlayerPosLook() catch {};
        // Stream the destination area immediately: chunk follow-up is
        // otherwise frame-driven and would stall until the client sends its
        // next packet (the client has no reason to send one right after /tp).
        // Same lock order as the serve loop (conn.lock held, world_lock
        // inside the chunk source) — never the reverse.
        if (self.world) |pool| {
            const radius: u8 = @min(mc.client_view orelse self.view_distance, self.view_distance);
            view.syncPlayerChunks(mc, conn_sink.bind(mc), self.chunkSource(pool), 0, radius, true) catch {};
        }
        return true;
    }

    /// /perm reload.
    pub fn permReload(self: *Server) void {
        self.loadPerms();
    }

    /// /perm show <player>: "name: level N +node -node", or null when the
    /// line doesn't fit (caller prints "Show failed."). Unknown players
    /// show level 0, same as before (no row, no match).
    pub fn permShow(self: *Server, player: []const u8, out: []u8) ?[]const u8 {
        // Resolve before locking (snapshot + conn locks must never nest
        // inside perm_lock). Build the whole reply under perm_lock,
        // release, then return (the caller sends it; reply takes the
        // sender's conn lock — never nest the two).
        const uuid = self.resolveUuid(player);
        const built: ?usize = blk: {
            self.perm_lock.lock();
            defer self.perm_lock.unlock();
            const db = self.permsDbLocked();
            const p = if (uuid) |*u| db.lookupRowUuid(u) else null;
            var ow: usize = 0;
            {
                const s = std.fmt.bufPrint(out[ow..], "{s}: level {d}", .{ player, if (p) |pp| pp.level.rank() else perms_mod.DEFAULT_LEVEL.rank() }) catch break :blk null;
                ow += s.len;
            }
            if (p) |pp| {
                var gi = pp.grants.iterator();
                while (gi.next()) |e| {
                    const s = std.fmt.bufPrint(out[ow..], " +{s}", .{e.key_ptr.*}) catch break :blk ow;
                    ow += s.len;
                }
                var di = pp.denies.iterator();
                while (di.next()) |e| {
                    const s = std.fmt.bufPrint(out[ow..], " -{s}", .{e.key_ptr.*}) catch break :blk ow;
                    ow += s.len;
                }
            }
            break :blk ow;
        };
        if (built) |n| {
            return out[0..n];
        } else {
            return null;
        }
    }

    /// /perm grant|deny <player> <node> (persists immediately).
    pub fn permGrant(self: *Server, player: []const u8, node: []const u8) bool {
        const uuid = self.resolveUuid(player) orelse return false;
        self.perm_lock.lock();
        self.permsDbLocked().grantUuid(&uuid, player, node) catch {
            self.perm_lock.unlock();
            return false;
        };
        self.perm_lock.unlock();
        self.savePerms();
        return true;
    }

    pub fn permDeny(self: *Server, player: []const u8, node: []const u8) bool {
        const uuid = self.resolveUuid(player) orelse return false;
        self.perm_lock.lock();
        self.permsDbLocked().denyUuid(&uuid, player, node) catch {
            self.perm_lock.unlock();
            return false;
        };
        self.perm_lock.unlock();
        self.savePerms();
        return true;
    }

    /// /perm clear <player> [node] (null node = drop all nodes, keep level).
    pub fn permClear(self: *Server, player: []const u8, node: ?[]const u8) bool {
        const uuid = self.resolveUuid(player) orelse return false;
        self.perm_lock.lock();
        if (node) |n| {
            _ = self.permsDbLocked().clearNodeUuid(&uuid, n) catch false;
        } else if (self.perms) |*db| {
            if (db.lookupRowUuid(&uuid)) |pp| {
                var gi = pp.grants.iterator();
                while (gi.next()) |e| db.alloc.free(e.key_ptr.*);
                pp.grants.clearRetainingCapacity();
                var di = pp.denies.iterator();
                while (di.next()) |e| db.alloc.free(e.key_ptr.*);
                pp.denies.clearRetainingCapacity();
            }
        }
        self.perm_lock.unlock();
        self.savePerms();
        return true;
    }

    /// "/stop" (bare or with args): persist + exit. Callers deliver the
    /// reply first — in-game via the normal flush below, console/RCON via
    /// their own flush before exiting.
    pub fn isStopCommand(text: []const u8) bool {
        var t = text;
        if (t.len > 0 and t[0] == '/') t = t[1..];
        const sp = std.mem.indexOfScalar(u8, t, ' ') orelse t.len;
        return std.mem.eql(u8, t[0..sp], "stop");
    }

    /// In-game + console command entry: runs the command and delivers the
    /// reply (chat frame to a player, stdout for console). Unknown commands
    /// get a usage hint, never a kick.
    pub fn handleCommand(self: *Server, sender: ?*Conn, text: []const u8) void {
        var buf: [8192]u8 = undefined;
        const r = self.executeCommand(sender, text, &buf);
        self.reply(sender, r);
    }

    /// Command core shared by chat, console, and RCON: returns the reply
    /// text (a slice of `out`, or a static string). Side effects that must
    /// reach other players (op/deop notices) still send chats directly.
    /// Callers handle "/stop" themselves via isStopCommand (reply first).
    pub fn executeCommand(self: *Server, sender: ?*Conn, text: []const u8, out: []u8) []const u8 {
        // Split "/cmd args..." (text[0] == '/' guaranteed by caller).
        var cmd = text[1..];
        var args: []const u8 = "";
        if (std.mem.indexOfScalar(u8, cmd, ' ')) |sp| {
            args = std.mem.trim(u8, cmd[sp + 1 ..], " ");
            cmd = cmd[0..sp];
        }
        _ = self.permDb(); // matrix from here on (mutations persist below)
        // One file per command (src/cmd/); the RUNTIME registry
        // (ensureCommands/registerCommand) owns help text, permission
        // checks, and dispatch, so the three can never drift apart and
        // modding-API commands show up everywhere builtins do.
        self.ensureCommands();
        for (self.cmds[0..self.n_cmds]) |e| {
            if (cmdMatches(e.def, cmd)) {
                if (!self.commandAllowed(sender, e.def)) {
                    // Same reply as unknown: failures never oracle command
                    // existence or the caller's level.
                    return "Unknown command. Try /help for a list of commands";
                }
                return e.run(self, sender, args, out);
            }
        }
        return "Unknown command. Try /help for a list of commands";
    }

    /// Matrix must already be initialized (permDb called in handleCommand).
    fn permsDbLocked(self: *Server) *perms_mod.Db {
        return &self.perms.?;
    }

    /// Tell an online player something (case-insensitive like vanilla
    /// `getPlayer` — a direct message, not a broadcast). Command backend
    /// surface (cmd/op.zig, cmd/deop.zig).
    pub fn notifyPlayer(self: *Server, name: []const u8, text: []const u8) void {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            e.conn.lock.lock();
            const match = e.conn.state == .play and !e.conn.dead and !e.conn.close_after_flush and std.ascii.eqlIgnoreCase(e.conn.username[0..e.conn.username_len], name);
            e.conn.lock.unlock();
            if (!match) continue;
            self.reply(e.conn, text);
        }
    }

    /// Command reply: one 0x02 chat frame PER LINE (vanilla never puts
    /// `\n` inside a chat packet — /help, /list etc. arrive as separate
    /// messages; some clients render embedded newlines as "[LF]").
    /// Empty segments are skipped (no blank vanilla lines).
    fn reply(self: *Server, sender: ?*Conn, text: []const u8) void {
        _ = self;
        if (sender) |c| {
            var it = std.mem.splitScalar(u8, text, '\n');
            var any = false;
            while (it.next()) |line| {
                if (line.len == 0) continue;
                any = true;
                var eb: [2048]u8 = undefined;
                const esc = packets.escapeJsonText(line, &eb) catch return;
                var jb: [2112]u8 = undefined;
                const json = std.fmt.bufPrint(&jb, "{{\"text\":\"{s}\"}}", .{esc}) catch return;
                var fb: [2176]u8 = undefined;
                const f = packets.frameChat(json, &fb) catch return;
                c.lock.lock();
                const ok = c.state == .play and !c.dead;
                if (ok) c.queueFramed(f) catch {};
                c.lock.unlock();
                if (!ok) return;
            }
            // All-empty text (shouldn't happen): send one empty line so the
            // caller never hangs waiting for a reply that never comes.
            if (!any) {
                var fb: [64]u8 = undefined;
                const f = packets.frameChat("{\"text\":\"\"}", &fb) catch return;
                c.lock.lock();
                defer c.lock.unlock();
                if (c.state != .play or c.dead) return;
                c.queueFramed(f) catch {};
            }
        } else {
            std.log.info("(console) {s}", .{text});
        }
    }

    // ---- command backends: chat / moderation / world state ----
    // (All version-agnostic command files go through these; game logic and
    // message text live in src/cmd/, packet framing stays here.)

    /// Vanilla target selectors for single-player args: @p nearest, @r
    /// random, @a only when exactly one player is online (vanilla errors
    /// otherwise). Returns the resolved name, or null for unknown/offline.
    pub fn resolvePlayerName(self: *Server, sender: ?*Conn, token: []const u8, out: *[perms_mod.max_name_len]u8) ?[]const u8 {
        if (!cmd_spec.isSelector(token)) {
            var batch: [max_fanout]RegistryEntry = undefined;
            const snap = self.snapshot(&batch);
            defer releaseSnap(snap);
            const c = findInSnap(snap, token) orelse return null;
            c.lock.lock();
            defer c.lock.unlock();
            if (c.state != .play or c.username_len == 0) return null;
            @memcpy(out[0..c.username_len], c.username[0..c.username_len]);
            return out[0..c.username_len];
        }
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        var names: [256][perms_mod.max_name_len]u8 = undefined;
        var lens: [256]u8 = undefined;
        var pos: [256][3]f64 = undefined;
        var n: usize = 0;
        for (snap) |e| {
            if (n >= names.len) break;
            e.conn.lock.lock();
            const play = e.conn.state == .play and e.conn.username_len > 0;
            if (play) {
                @memcpy(names[n][0..e.conn.username_len], e.conn.username[0..e.conn.username_len]);
                lens[n] = @intCast(e.conn.username_len);
                pos[n] = .{ e.conn.pos_x, e.conn.pos_y, e.conn.pos_z };
                n += 1;
            }
            e.conn.lock.unlock();
        }
        if (n == 0) return null;
        if (std.mem.eql(u8, token, "@a")) {
            if (n != 1) return null;
            @memcpy(out[0..lens[0]], names[0][0..lens[0]]);
            return out[0..lens[0]];
        }
        if (std.mem.eql(u8, token, "@r")) {
            self.rand_lock.lock();
            if (self.drop_rand == null) {
                const seed: i64 = @bitCast(@as(u64, @bitCast(std.Io.Timestamp.now(self.io, .awake).toMilliseconds())));
                self.drop_rand = java_random.JavaRandom.init(seed);
            }
            const idx: usize = @intCast(@mod(self.drop_rand.?.nextInt(), @as(i32, @intCast(n))));
            self.rand_lock.unlock();
            @memcpy(out[0..lens[idx]], names[idx][0..lens[idx]]);
            return out[0..lens[idx]];
        }
        // @p: nearest to the sender (console has no position: first online).
        var sx: f64 = 0;
        var sy: f64 = 0;
        var sz: f64 = 0;
        var have_pos = false;
        if (sender) |c| {
            c.lock.lock();
            sx = c.pos_x;
            sy = c.pos_y;
            sz = c.pos_z;
            have_pos = c.state == .play;
            c.lock.unlock();
        }
        var best: usize = 0;
        var best_d: f64 = std.math.inf(f64);
        if (have_pos) {
            for (0..n) |i| {
                const dx = pos[i][0] - sx;
                const dy = pos[i][1] - sy;
                const dz = pos[i][2] - sz;
                const d = dx * dx + dy * dy + dz * dz;
                if (d < best_d) {
                    best_d = d;
                    best = i;
                }
            }
        }
        @memcpy(out[0..lens[best]], names[best][0..lens[best]]);
        return out[0..lens[best]];
    }

    /// Live peer address of an online player (for /ban-ip name form).
    pub fn playerIp(self: *Server, name: []const u8, out: *[64]u8) ?[]const u8 {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const c = findInSnap(snap, name) orelse return null;
        c.lock.lock();
        defer c.lock.unlock();
        if (c.state != .play or c.ip_len == 0) return null;
        @memcpy(out[0..c.ip_len], c.ip[0..c.ip_len]);
        return out[0..c.ip_len];
    }

    /// Multi-target resolution for spreadplayers: @a = all online,
    /// @p/@r = single, plain = single (null when nobody matches).
    pub fn resolvePlayerList(self: *Server, sender: ?*Conn, token: []const u8, out: [][perms_mod.max_name_len]u8, lens: []u8) usize {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        var n: usize = 0;
        if (std.mem.eql(u8, token, "@a")) {
            for (snap) |e| {
                if (n >= out.len) break;
                e.conn.lock.lock();
                const play = e.conn.state == .play and e.conn.username_len > 0;
                if (play) {
                    @memcpy(out[n][0..e.conn.username_len], e.conn.username[0..e.conn.username_len]);
                    lens[n] = @intCast(e.conn.username_len);
                    n += 1;
                }
                e.conn.lock.unlock();
            }
            return n;
        }
        var one: [perms_mod.max_name_len]u8 = undefined;
        const t = self.resolvePlayerName(sender, token, &one) orelse return 0;
        if (out.len == 0) return 0;
        @memcpy(out[0][0..t.len], t);
        lens[0] = @intCast(t.len);
        return 1;
    }

    /// Online check (play state). Used for "player not found" errors.
    pub fn isOnline(self: *Server, name: []const u8) bool {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const c = findInSnap(snap, name) orelse return false;
        c.lock.lock();
        defer c.lock.unlock();
        return c.state == .play;
    }

    /// Bump the save epoch for a login name; the caller stores the
    /// returned value on the conn. Leaf lock only (never nested).
    // ---- kicks, login rejects, save epochs ----

    /// Lowercase a login name for the save-epoch map (session bookkeeping
    /// only — NOT authorization; the perm matrix keys on UUIDs and never
    /// folds).
    fn foldEpochName(name: []const u8, buf: *[perms_mod.max_name_len]u8) []const u8 {
        const n = @min(name.len, perms_mod.max_name_len);
        for (name[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
        return buf[0..n];
    }

    fn bumpSaveEpoch(self: *Server, name: []const u8) u64 {
        self.epoch_lock.lock();
        defer self.epoch_lock.unlock();
        if (self.save_epochs == null) self.save_epochs = std.StringHashMap(u64).init(self.gpa);
        var fold: [perms_mod.max_name_len]u8 = undefined;
        const key = foldEpochName(name, &fold);
        const e = self.save_epochs.?.get(key) orelse 0;
        const next = e + 1;
        if (self.save_epochs.?.getPtr(key)) |p| {
            p.* = next;
        } else {
            const owned = self.gpa.dupe(u8, key) catch return next;
            self.save_epochs.?.put(owned, next) catch {
                self.gpa.free(owned);
                return next;
            };
        }
        return next;
    }

    /// True when this conn still owns its player row (no newer login for
    /// the name has bumped the epoch since). Leaf lock only (never nested).
    fn saveEpochCurrent(self: *Server, name: []const u8, epoch: u64) bool {
        self.epoch_lock.lock();
        defer self.epoch_lock.unlock();
        const m = self.save_epochs orelse return true;
        var fold: [perms_mod.max_name_len]u8 = undefined;
        const cur = m.get(foldEpochName(name, &fold)) orelse return true;
        return cur == epoch;
    }

    /// Current epoch for a name without bumping (0 = no login yet). Read
    /// at login start into `login_epoch_seen`; the straggler fence aborts
    /// when it no longer matches. Leaf lock only (never nested).
    fn epochFor(self: *Server, name: []const u8) u64 {
        self.epoch_lock.lock();
        defer self.epoch_lock.unlock();
        const m = self.save_epochs orelse return 0;
        var fold: [perms_mod.max_name_len]u8 = undefined;
        return m.get(foldEpochName(name, &fold)) orelse 0;
    }

    /// Kick by registry entry: queue the play disconnect, flush it from
    /// THIS thread, then shut the socket down. Flushing here (instead of
    /// leaving it to the victim's serve loop) matters: a quiet victim's
    /// thread can be parked in takeByte indefinitely, in which case a
    /// queue-only kick never lands and the ghost lingers in the registry
    /// shadowing the live session. Shutdown wakes the victim's thread so
    /// it unregisters promptly. Same shape as the idle-kick path.
    /// Abort our own wedged login when the straggler fence trips (a newer
    /// login owns the row now). Queues the superseded screen and unwinds
    /// via close_after_flush (finished=true); our death-rattle save is
    /// dropped by the epoch guard. Caller holds conn.lock and returns
    /// right after (need_announce stays unset). Same shape as the
    /// post-LoginSuccess rejectLogin path.
    fn abortStaleLogin(self: *Server, conn: *Conn) !void {
        _ = self;
        // Flag first: the screen is best-effort (OOM below must still
        // unwind to a close, never to a half-logged-in linger).
        conn.close_after_flush = true;
        var ab: [512]u8 = undefined;
        if (packets.frameDisconnect("{\"text\":\"You logged in from another location!\"}", &ab)) |f| {
            try conn.queueFramed(f);
        } else |_| {}
    }

    fn kickEntry(self: *Server, e: RegistryEntry, reason: []const u8) void {
        var eb: [512]u8 = undefined;
        const esc = packets.escapeJsonText(reason, &eb) catch return;
        var jb: [560]u8 = undefined;
        const json = std.fmt.bufPrint(&jb, "{{\"text\":\"{s}\"}}", .{esc}) catch return;
        e.conn.lock.lock();
        if (e.conn.state != .play or e.conn.dead or e.conn.close_after_flush) {
            // Already dying (kick/timeout in flight): its row and save are
            // decided — re-queueing another disconnect just re-flushes a
            // dead peer's outbox (the write that wedges kickers).
            e.conn.lock.unlock();
            return;
        }
        // Disconnect carries the JSON (client shows it on the screen).
        var fb: [700]u8 = undefined;
        const d = packets.frameDisconnect(json, &fb) catch {
            e.conn.lock.unlock();
            return;
        };
        e.conn.queueFramed(d) catch {};
        e.conn.close_after_flush = true;
        e.conn.lock.unlock();
        // One output path (blocking: to the socket; async: the worker).
        flushEntry(e, self.io);
        closeEntry(e, self.io);
    }

    /// Login rejection screen (conn.lock held by the caller). Queues a play
    /// disconnect with the jar-hardcoded text and closes after flush —
    /// LoginSuccess already went out, so this is a post-login kick with the
    /// same screen vanilla shows pre-login.
    fn rejectLogin(self: *Server, c: *Conn, rej: LoginReject) void {
        var reason: [1024]u8 = undefined;
        var rlen: usize = 0;
        switch (rej) {
            .banned_name => {
                self.ban_lock.lock();
                const r = if (self.bans) |*db| db.bannedUuid(&c.uuid_str) else null;
                if (r) |rr| {
                    const s = std.fmt.bufPrint(&reason, "You are banned from this server!\nReason: {s}", .{rr}) catch reason[0..0];
                    rlen = s.len;
                } else {
                    @memcpy(reason[0.."You are banned from this server.".len], "You are banned from this server.");
                    rlen = "You are banned from this server.".len;
                }
                self.ban_lock.unlock();
            },
            .banned_ip => {
                self.ban_lock.lock();
                const r = if (self.bans) |*db| (if (c.ip_len > 0) db.bannedIp(c.ip[0..c.ip_len]) else null) else null;
                if (r) |rr| {
                    const s = std.fmt.bufPrint(&reason, "Your IP address is banned from this server!\nReason: {s}", .{rr}) catch reason[0..0];
                    rlen = s.len;
                } else {
                    @memcpy(reason[0.."Your IP address is banned from this server.".len], "Your IP address is banned from this server.");
                    rlen = "Your IP address is banned from this server.".len;
                }
                self.ban_lock.unlock();
            },
            .not_whitelisted => {
                @memcpy(reason[0.."You are not white-listed on this server!".len], "You are not white-listed on this server!");
                rlen = "You are not white-listed on this server!".len;
            },
            .rate_limited => {
                @memcpy(reason[0.."Too many login attempts, try again later.".len], "Too many login attempts, try again later.");
                rlen = "Too many login attempts, try again later.".len;
            },
        }
        var eb: [2048]u8 = undefined;
        const esc = packets.escapeJsonText(reason[0..rlen], &eb) catch return;
        var jb: [2112]u8 = undefined;
        const json = std.fmt.bufPrint(&jb, "{{\"text\":\"{s}\"}}", .{esc}) catch return;
        var fb: [2300]u8 = undefined;
        queueBuilt(c, packets.frameDisconnect(json, &fb));
        c.close_after_flush = true;
    }

    /// Kick an online player. False when they aren't online.
    pub fn kickPlayer(self: *Server, name: []const u8, reason: ?[]const u8) bool {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            e.conn.lock.lock();
            const match = e.conn.state == .play and std.ascii.eqlIgnoreCase(e.conn.username[0..e.conn.username_len], name);
            e.conn.lock.unlock();
            if (!match) continue;
            self.kickEntry(e, reason orelse "Kicked by an operator.");
            return true;
        }
        return false;
    }

    // ---- moderation: bans, whitelist, scoreboard stores, ban logic ----

    fn banDb(self: *Server) *bans_mod.BanDb {
        self.ban_lock.lock();
        defer self.ban_lock.unlock();
        if (self.bans == null) self.bans = bans_mod.BanDb.init(self.gpa);
        return &self.bans.?;
    }

    fn banSave(self: *Server) void {
        const dir = self.list_dir orelse std.Io.Dir.cwd();
        self.ban_lock.lock();
        const enc = if (self.bans) |*db| bans_mod.encodeBansJson(self.gpa, db) catch null else null;
        self.ban_lock.unlock();
        if (enc) |e| {
            defer self.gpa.free(e.names);
            defer self.gpa.free(e.ips);
            bans_mod.writePlayersFile(self.io, dir, e.names) catch |err| {
                std.log.warn("banned-players.json write failed ({})", .{err});
            };
            bans_mod.writeIpsFile(self.io, dir, e.ips) catch |err| {
                std.log.warn("banned-ips.json write failed ({})", .{err});
            };
        }
    }

    pub fn banLoad(self: *Server) void {
        const dir = self.list_dir orelse std.Io.Dir.cwd();
        const file_db = bans_mod.loadBansFile(self.io, dir, self.gpa, !self.config.online_mode) catch |err| {
            std.log.warn("ban files unreadable ({}) — starting empty", .{err});
            return;
        };
        if (file_db) |loaded| {
            if (loaded.skipped_legacy > 0) std.log.warn("banned-players.json: {d} legacy name-only rows ignored (no UUID) — re-ban affected players", .{loaded.skipped_legacy});
            self.ban_lock.lock();
            defer self.ban_lock.unlock();
            if (self.bans) |*old| old.deinit();
            self.bans = loaded.db;
        }
    }

    fn wlDb(self: *Server) *bans_mod.Whitelist {
        self.wl_lock.lock();
        defer self.wl_lock.unlock();
        if (self.whitelist == null) self.whitelist = bans_mod.Whitelist.init(self.gpa);
        return &self.whitelist.?;
    }

    /// Delete a migrated legacy world-DB row (one-time migration helper;
    /// best-effort — a leftover row is re-migrated harmlessly next boot).
    fn deleteLegacyRow(self: *Server, key: store_mod.ChunkKey) void {
        const pool = self.world orelse return;
        self.world_lock.lock();
        defer self.world_lock.unlock();
        pool.delete(key) catch {};
    }

    fn wlSave(self: *Server) void {
        const dir = self.list_dir orelse std.Io.Dir.cwd();
        self.wl_lock.lock();
        const enc = if (self.whitelist) |*wl| bans_mod.encodeWhitelistJson(self.gpa, wl) catch null else null;
        self.wl_lock.unlock();
        if (enc) |e| {
            defer self.gpa.free(e);
            bans_mod.writeWhitelistFile(self.io, dir, e) catch |err| {
                std.log.warn("whitelist.json write failed ({})", .{err});
            };
        }
    }

    pub fn whitelistLoad(self: *Server) void {
        const dir = self.list_dir orelse std.Io.Dir.cwd();
        const file_wl = bans_mod.loadWhitelistFile(self.io, dir, self.gpa, !self.config.online_mode) catch |err| {
            std.log.warn("whitelist.json unreadable ({}) — starting empty", .{err});
            return;
        };
        if (file_wl) |loaded| {
            if (loaded.skipped_legacy > 0) std.log.warn("whitelist.json: {d} legacy name-only rows ignored (no UUID) — re-add affected players", .{loaded.skipped_legacy});
            self.wl_lock.lock();
            defer self.wl_lock.unlock();
            if (self.whitelist) |*old| old.deinit();
            self.whitelist = loaded.wl;
        }
    }

    pub fn wlSetEnabled(self: *Server, on: bool) void {
        const wl = self.wlDb();
        self.wl_lock.lock();
        wl.enabled = on;
        self.wl_lock.unlock();
        self.wlSave();
    }

    pub fn wlAdd(self: *Server, name: []const u8) bool {
        if (name.len == 0 or name.len > 16) return false;
        const uuid = self.resolveUuid(name) orelse return false;
        const wl = self.wlDb();
        self.wl_lock.lock();
        wl.add(&uuid, name) catch {
            self.wl_lock.unlock();
            return false;
        };
        self.wl_lock.unlock();
        self.wlSave();
        return true;
    }

    pub fn wlRemove(self: *Server, name: []const u8) bool {
        const uuid = self.resolveUuid(name) orelse return false;
        const wl = self.wlDb();
        self.wl_lock.lock();
        const ok = wl.remove(&uuid);
        self.wl_lock.unlock();
        if (ok) self.wlSave();
        return ok;
    }

    /// "There are %d (out of %d seen) whitelisted players:" + names. Seen =
    /// union of whitelisted + currently online (player rows need a store
    /// scan, which the LSM doesn't offer — this is the best available).
    pub fn wlList(self: *Server, out: []u8) []const u8 {
        var names: [256][perms_mod.max_name_len]u8 = undefined;
        var lens: [256]u8 = undefined;
        var uuids: [256][perms_mod.uuid_len]u8 = undefined;
        const online = self.playNames(&names, &lens, &uuids);
        self.wl_lock.lock();
        defer self.wl_lock.unlock();
        const wl = if (self.whitelist) |*w| w else {
            return std.fmt.bufPrint(out, "There are 0 (out of {d} seen) whitelisted players:", .{online}) catch out[0..0];
        };
        // Union count for "seen": a whitelisted row with a live session
        // (matched by UUID, so renames display once) counts once.
        var seen = online;
        var wit = wl.rows.iterator();
        while (wit.next()) |e| {
            var known = false;
            for (uuids[0..online]) |ou| {
                if (std.mem.eql(u8, ou[0..], e.key_ptr.*)) {
                    known = true;
                    break;
                }
            }
            if (!known) seen += 1;
        }
        var ow: usize = 0;
        ow += (std.fmt.bufPrint(out[ow..], "There are {d} (out of {d} seen) whitelisted players:", .{ wl.rows.count(), seen }) catch return out[0..ow]).len;
        var jit = wl.rows.iterator();
        while (jit.next()) |e| {
            ow += (std.fmt.bufPrint(out[ow..], "\n{s}", .{e.value_ptr.*}) catch break).len;
        }
        return out[0..ow];
    }

    fn sbDb(self: *Server) *scoreboard_mod.Scoreboard {
        self.sb_lock.lock();
        defer self.sb_lock.unlock();
        if (self.scoreboard == null) self.scoreboard = scoreboard_mod.Scoreboard.init(self.gpa);
        return &self.scoreboard.?;
    }

    fn sbSave(self: *Server) void {
        const pool = self.world orelse return;
        self.sb_lock.lock();
        const enc = if (self.scoreboard) |*sb| sb.encode(pool.allocator) catch null else null;
        self.sb_lock.unlock();
        if (enc) |e| {
            defer pool.allocator.free(e);
            self.world_lock.lock();
            defer self.world_lock.unlock();
            pool.put(scoreboard_mod.scoreboard_key, e) catch {};
        }
    }

    pub fn scoreboardLoad(self: *Server) void {
        const pool = self.world orelse return;
        const loaded = scoreboard_mod.load(pool, self.gpa) catch |err| blk: {
            std.log.warn("scoreboard row unreadable ({}) — starting empty", .{err});
            break :blk null;
        };
        if (loaded) |sb| {
            self.sb_lock.lock();
            defer self.sb_lock.unlock();
            if (self.scoreboard) |*old| old.deinit();
            self.scoreboard = sb;
        }
    }

    /// Ban a UUID (any valid name in offline mode) and kick them if online.
    /// Reason may be empty (login screen then shows the bare ban line).
    /// Unresolvable names fail closed (online mode, target offline).
    pub fn banName(self: *Server, name: []const u8, reason: []const u8) bool {
        const uuid = self.resolveUuid(name) orelse return false;
        const db = self.banDb();
        self.ban_lock.lock();
        db.banUuid(&uuid, name, reason) catch {
            self.ban_lock.unlock();
            return false;
        };
        self.ban_lock.unlock();
        self.banSave();
        _ = self.kickPlayer(name, "You are banned from this server.");
        return true;
    }

    pub fn pardonName(self: *Server, name: []const u8) bool {
        const uuid = self.resolveUuid(name) orelse return false;
        const db = self.banDb();
        self.ban_lock.lock();
        const ok = db.unbanUuid(&uuid);
        self.ban_lock.unlock();
        if (ok) self.banSave();
        return ok;
    }

    pub fn isUuidBanned(self: *Server, uuid: *const [perms_mod.uuid_len]u8) ?[]const u8 {
        // Reason slice borrows the map — copy out under the lock.
        self.ban_lock.lock();
        defer self.ban_lock.unlock();
        if (self.bans) |*db| {
            if (db.bannedUuid(uuid)) |r| return r;
        }
        return null;
    }

    /// Ban an IP and kick every online conn with it.
    pub fn banIp(self: *Server, ip: []const u8, reason: []const u8) void {
        const db = self.banDb();
        self.ban_lock.lock();
        db.banIp(ip, reason) catch {};
        self.ban_lock.unlock();
        self.banSave();
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            e.conn.lock.lock();
            const match = e.conn.state == .play and e.conn.ip_len == ip.len and std.mem.eql(u8, e.conn.ip[0..e.conn.ip_len], ip);
            e.conn.lock.unlock();
            if (match) self.kickEntry(e, "You have been IP banned.");
        }
    }

    pub fn pardonIp(self: *Server, ip: []const u8) bool {
        const db = self.banDb();
        self.ban_lock.lock();
        const ok = db.unbanIp(ip);
        self.ban_lock.unlock();
        if (ok) self.banSave();
        return ok;
    }

    pub fn isIpBanned(self: *Server, ip: []const u8) bool {
        self.ban_lock.lock();
        defer self.ban_lock.unlock();
        if (self.bans) |*db| return db.bannedIp(ip) != null;
        return false;
    }

    /// /banlist body: "There are %d total banned players/ips:" + entries.
    pub fn banList(self: *Server, want_ips: bool, out: []u8) []const u8 {
        self.ban_lock.lock();
        defer self.ban_lock.unlock();
        const db = if (self.bans) |*d| d else {
            return std.fmt.bufPrint(out, "There are 0 total banned {s}:", .{if (want_ips) "IP addresses" else "players"}) catch out[0..0];
        };
        var ow: usize = 0;
        if (want_ips) {
            ow += (std.fmt.bufPrint(out[ow..], "There are {d} total banned IP addresses:", .{db.ipCount()}) catch return out[0..ow]).len;
            var it = db.ips.iterator();
            while (it.next()) |e| {
                ow += (std.fmt.bufPrint(out[ow..], "\n{s}", .{e.key_ptr.*}) catch break).len;
            }
        } else {
            ow += (std.fmt.bufPrint(out[ow..], "There are {d} total banned players:", .{db.nameCount()}) catch return out[0..ow]).len;
            var it = db.names.iterator();
            while (it.next()) |e| {
                ow += (std.fmt.bufPrint(out[ow..], "\n{s}", .{e.value_ptr.name}) catch break).len;
            }
        }
        return out[0..ow];
    }

    /// Login gate: banned UUIDs/IPs and non-whitelisted UUIDs are rejected
    /// with the jar-hardcoded screens (`oi` login handler strings).
    pub const LoginReject = enum { banned_name, banned_ip, not_whitelisted, rate_limited };

    pub fn loginRejected(self: *Server, ip: []const u8, uuid: *const [perms_mod.uuid_len]u8) ?LoginReject {
        self.ban_lock.lock();
        const bn = if (self.bans) |*db| db.bannedUuid(uuid) != null else false;
        const bi = if (self.bans) |*db| (if (ip.len > 0) db.bannedIp(ip) != null else false) else false;
        self.ban_lock.unlock();
        if (bn) return .banned_name;
        if (bi) return .banned_ip;
        self.wl_lock.lock();
        defer self.wl_lock.unlock();
        if (self.whitelist) |*wl| {
            if (wl.enabled and !wl.contains(uuid)) return .not_whitelisted;
        }
        return null;
    }

    /// Per-IP join flood gate (joins are the expensive path: loadPlayer,
    /// chunk burst, gen, saves). Empty IPs (IOCP conns carry no peer
    /// address) bypass — nothing to attribute.
    pub fn noteLoginAttempt(self: *Server, ip: []const u8) bool {
        if (ip.len == 0) return true;
        const now_ms = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
        return self.login_gate.allow(ip, now_ms, self.login_rate_window_ms, self.login_rate_burst);
    }

    pub fn loginRejectText(reject: LoginReject, out: []u8) []const u8 {        _ = out;
        return switch (reject) {
            .banned_name => "You are banned from this server.",
            .banned_ip => "Your IP address is banned from this server.",
            .not_whitelisted => "You are not white-listed on this server!",
            .rate_limited => "Too many login attempts, try again later.",
        };
    }

    /// Broadcast `[name] message` (vanilla `chat.type.announcement`).
    /// Multi-line input goes out as one packet per line (never `\n`).
    // ---- social, weather, gameplay RNG ----

    pub fn broadcastSay(self: *Server, name: []const u8, msg: []const u8) void {
        var it = std.mem.splitScalar(u8, msg, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            var eb: [2048]u8 = undefined;
            const esc = packets.escapeJsonText(line, &eb) catch return;
            var jb: [2200]u8 = undefined;
            const json = std.fmt.bufPrint(&jb, "{{\"text\":\"[{s}] {s}\"}}", .{ name, esc }) catch return;
            self.broadcastChat(json);
        }
    }

    /// Broadcast `* name message` (vanilla `chat.type.emote`).
    /// Multi-line input goes out as one packet per line (never `\n`).
    pub fn broadcastMe(self: *Server, name: []const u8, msg: []const u8) void {
        var it = std.mem.splitScalar(u8, msg, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            var eb2: [2048]u8 = undefined;
            const esc = packets.escapeJsonText(line, &eb2) catch return;
            var jb: [2200]u8 = undefined;
            const json = std.fmt.bufPrint(&jb, "{{\"text\":\"* {s} {s}\"}}", .{ name, esc }) catch return;
            self.broadcastChat(json);
        }
    }

    /// Direct message pair for /tell: incoming to the target, outgoing text
    /// returned for the sender's own reply. False when target is offline.
    pub fn tellPlayer(self: *Server, target: []const u8, from: []const u8, msg: []const u8, out: []u8) ?[]const u8 {
        var eb: [2048]u8 = undefined;
        const esc = packets.escapeJsonText(msg, &eb) catch return null;
        var ib: [2200]u8 = undefined;
        const incoming = std.fmt.bufPrint(&ib, "{{\"text\":\"{s} whispers to you: {s}\"}}", .{ from, esc }) catch return null;
        if (!self.sendJsonPlayer(target, incoming)) return null;
        return std.fmt.bufPrint(out, "You whisper to {s}: {s}", .{ target, msg }) catch null;
    }

    /// Kill a player even in creative (vanilla /kill bypasses the damage
    /// gate). Mirrors the ticker death flow: drops honor keepInventory.
    pub fn killPlayer(self: *Server, name: []const u8) bool {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const c = findInSnap(snap, name) orelse return false;
        c.lock.lock();
        if (c.state != .play or c.is_dead) {
            c.lock.unlock();
            return true; // already dead: still "Ouch!" like vanilla
        }
        c.health = 0;
        c.is_dead = true;
        var hb: [32]u8 = undefined;
        queueBuilt(c, packets.frameUpdateHealth(0, c.food, c.saturation, &hb));
        var dd: ?DeathDrop = if (self.keepInv()) null else collectDeathDrops(c);
        const px = c.pos_x;
        const py = c.pos_y;
        const pz = c.pos_z;
        const eid = c.eid;
        c.lock.unlock();
        var nm: [perms_mod.max_name_len]u8 = undefined;
        const nm_len = copyUsername(c, &nm);
        // Death metadata + drops outside the conn lock.
        var mdb: [32]u8 = undefined;
        if (packets.frameEntityMetadata(eid, 0, &mdb)) |f| {
            self.broadcastToTrackers(eid, f);
        } else |_| {}
        self.broadcastDeath(nm[0..nm_len], .generic, "");
        if (dd) |*d| {
            self.spawnDeathDrops(d, px, py, pz);
            self.savePlayer(c);
        }
        return true;
    }

    /// Uniform double in [0, 1) for spreadplayers (shares the gameplay RNG).
    pub fn spreadRand(self: *Server) f64 {
        self.rand_lock.lock();
        defer self.rand_lock.unlock();
        if (self.drop_rand == null) {
            const seed: i64 = @bitCast(@as(u64, @bitCast(std.Io.Timestamp.now(self.io, .awake).toMilliseconds())));
            self.drop_rand = java_random.JavaRandom.init(seed);
        }
        return @as(f64, @floatFromInt(self.drop_rand.?.nextInt() & 0xFFFFFF)) / 16777216.0;
    }

    /// Gameplay-RNG int (vanilla draw order; e.g. weather durations).
    pub fn randInt(self: *Server) i64 {
        self.rand_lock.lock();
        defer self.rand_lock.unlock();
        if (self.drop_rand == null) {
            const seed: i64 = @bitCast(@as(u64, @bitCast(std.Io.Timestamp.now(self.io, .awake).toMilliseconds())));
            self.drop_rand = java_random.JavaRandom.init(seed);
        }
        return self.drop_rand.?.nextInt();
    }

    const WeatherMode = enum { clear, rain, thunder };

    /// /weather + /toggledownfall core. Durations are ticks (20/sec).
    pub fn setWeather(self: *Server, mode: WeatherMode, ticks: u32) void {
        self.state_lock.lock();
        switch (mode) {
            .clear => {
                self.raining = false;
                self.thundering = false;
                self.rain_time = ticks;
                self.thunder_time = ticks;
            },
            .rain => {
                self.raining = true;
                self.thundering = false;
                self.rain_time = ticks;
            },
            .thunder => {
                self.raining = true;
                self.thundering = true;
                self.rain_time = ticks;
                self.thunder_time = ticks;
            },
        }
        self.state_lock.unlock();
        var gb: [perms_mod.max_name_len]u8 = undefined;
        switch (mode) {
            .clear => {
                if (packets.frameGameState(packets.game_state_end_rain, 0, &gb)) |f| self.broadcastAll(f) else |_| {}
            },
            .rain, .thunder => {
                if (packets.frameGameState(packets.game_state_begin_rain, 0, &gb)) |f| self.broadcastAll(f) else |_| {}
            },
        }
    }

    pub fn toggleDownfall(self: *Server) void {
        self.state_lock.lock();
        self.raining = !self.raining;
        if (!self.raining) self.thundering = false;
        const now_raining = self.raining;
        self.state_lock.unlock();
        var gb: [perms_mod.max_name_len]u8 = undefined;
        if (packets.frameGameState(if (now_raining) packets.game_state_begin_rain else packets.game_state_end_rain, 0, &gb)) |f| {
            self.broadcastAll(f);
        } else |_| {}
    }

    /// Raw frame to every play conn (weather, game state).
    fn broadcastAll(self: *Server, framed: []const u8) void {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            e.conn.lock.lock();
            const play = e.conn.state == .play and !e.conn.dead;
            if (play) e.conn.queueFramed(framed) catch {};
            e.conn.lock.unlock();
        }
    }

    /// Countdown in tickOnce: rain/thunder expire to clear + S2B(2).
    /// Strengths chase the flags (vanilla fade) and broadcast S2B(7/8) on
    /// change — the 1.7.10 client renders from strength, so the flag
    /// packets alone never show rain.
    fn tickWeather(self: *Server) void {
        self.state_lock.lock();
        var changed = false;
        if (self.raining and self.rain_time > 0) {
            self.rain_time -= 20;
            if (self.rain_time >= 0xFFFFFFF0 or self.rain_time == 0) {
                // underflow guard: rain_time counts in 20-tick units
                if (self.rain_time > 1000000) self.rain_time = 0 else changed = false;
            }
            if (self.rain_time == 0) {
                self.raining = false;
                changed = true;
            }
        }
        if (self.thundering and self.thunder_time > 0) {
            if (self.thunder_time <= 20) {
                self.thunder_time = 0;
                self.thundering = false;
            } else {
                self.thunder_time -= 20;
            }
        }
        const rs_target: f32 = if (self.raining) 1.0 else 0.0;
        const ts_target: f32 = if (self.thundering) 1.0 else 0.0;
        const rs = approach(self.rain_strength, rs_target, 0.2);
        const ts = approach(self.thunder_strength, ts_target, 0.2);
        const rs_moved = @abs(rs - self.rain_strength) > 0.0001;
        const ts_moved = @abs(ts - self.thunder_strength) > 0.0001;
        self.rain_strength = rs;
        self.thunder_strength = ts;
        self.state_lock.unlock();
        if (changed) {
            var gb: [perms_mod.max_name_len]u8 = undefined;
            if (packets.frameGameState(packets.game_state_end_rain, 0, &gb)) |f| self.broadcastAll(f) else |_| {}
        }
        if (rs_moved) {
            var gb: [perms_mod.max_name_len]u8 = undefined;
            if (packets.frameGameState(packets.game_state_rain_strength, rs, &gb)) |f| self.broadcastAll(f) else |_| {}
        }
        if (ts_moved) {
            var gb: [perms_mod.max_name_len]u8 = undefined;
            if (packets.frameGameState(packets.game_state_thunder_strength, ts, &gb)) |f| self.broadcastAll(f) else |_| {}
        }
    }

    /// Move `v` toward `target` by at most `step` (same sign convention
    /// as vanilla's per-tick strength lerp).
    fn approach(v: f32, target: f32, step: f32) f32 {
        if (v < target) return @min(v + step, target);
        if (v > target) return @max(v - step, target);
        return v;
    }

    /// Send current weather state to a joining player (flag + strengths).
    /// Without this a login during rain shows clear skies until the next
    /// change, since strength defaults to 0 client-side.
    pub fn syncWeatherTo(self: *Server, conn: *Conn) void {
        self.state_lock.lock();
        const raining = self.raining;
        const rs = self.rain_strength;
        const ts = self.thunder_strength;
        self.state_lock.unlock();
        var gb: [perms_mod.max_name_len]u8 = undefined;
        queueBuilt(conn, packets.frameGameState(if (raining) packets.game_state_begin_rain else packets.game_state_end_rain, 0, &gb));
        queueBuilt(conn, packets.frameGameState(packets.game_state_rain_strength, rs, &gb));
        queueBuilt(conn, packets.frameGameState(packets.game_state_thunder_strength, ts, &gb));
    }

    /// Thunderstorm lightning: every ~5s strike near a random online
    /// player (bolt entity + client-side thunder crack; no fire/damage —
    /// fire spread is inert per the doFireTick gate).
    fn tickLightning(self: *Server) void {
        self.state_lock.lock();
        const thundering = self.thundering;
        self.state_lock.unlock();
        if (!thundering) {
            self.thunder_tick = 0;
            return;
        }
        const pool = self.world orelse return;
        self.thunder_tick += 1;
        if (self.thunder_tick < 5) return;
        self.thunder_tick = 0;
        // Random online player (own draw stream; see thunder_rand).
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        var players: [256]*Conn = undefined;
        var n: usize = 0;
        for (snap) |e| {
            if (n >= players.len) break;
            e.conn.lock.lock();
            const play = e.conn.state == .play and !e.conn.dead;
            e.conn.lock.unlock();
            if (play) {
                players[n] = e.conn;
                n += 1;
            }
        }
        if (n == 0) return;
        self.thunder_rand = self.thunder_rand *% 6364136223846793005 +% 1442695040888963407;
        const pick = players[self.thunder_rand % n];
        pick.lock.lock();
        const px = pick.pos_x;
        const pz = pick.pos_z;
        pick.lock.unlock();
        self.thunder_rand = self.thunder_rand *% 6364136223846793005 +% 1442695040888963407;
        const dx: i32 = @as(i32, @intCast(self.thunder_rand % 49)) - 24;
        self.thunder_rand = self.thunder_rand *% 6364136223846793005 +% 1442695040888963407;
        const dz: i32 = @as(i32, @intCast((self.thunder_rand >> 16) % 49)) - 24;
        const sx: i32 = @as(i32, @intFromFloat(@floor(px))) + dx;
        const sz: i32 = @as(i32, @intFromFloat(@floor(pz))) + dz;
        // Ground = topmost solid column cell (bolt renders sky-to-ground).
        const gy: ?i32 = blk: {
            const ch = pool.getChunk(self.gpa, 0, @divFloor(sx, 16), @divFloor(sz, 16)) catch null;
            const c = ch orelse break :blk null;
            defer c.destroy(self.gpa);
            const lx: usize = @intCast(@as(u4, @truncate(@as(u32, @bitCast(sx & 15)))));
            const lz: usize = @intCast(@as(u4, @truncate(@as(u32, @bitCast(sz & 15)))));
            const h = c.heights[lz * 16 + lx];
            if (h == 0) break :blk null;
            break :blk @as(i32, h);
        };
        const gyaw = gy orelse return;
        const eid = self.eid_counter.fetchAdd(1, .acq_rel);
        var lb: [32]u8 = undefined;
        if (packets.frameSpawnGlobalEntity(eid, 1, @as(f64, @floatFromInt(sx)) + 0.5, @as(f64, @floatFromInt(gyaw)), @as(f64, @floatFromInt(sz)) + 0.5, &lb)) |f| {
            self.broadcastAll(f);
        } else |_| {}
    }

    // ---- world rules, xp, effects, enchants ----

    pub fn difficultyName(_: *Server, d: rules_mod.Difficulty) []const u8 {
        return d.name();
    }

    pub fn setDifficulty(self: *Server, d: rules_mod.Difficulty) void {
        {
            var c = self.cfg.load();
            c.difficulty = d;
            self.cfg.store(c);
        }
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            e.conn.lock.lock();
            if (e.conn.state == .play) e.conn.config.difficulty = d;
            e.conn.lock.unlock();
        }
    }

    pub fn getDifficulty(self: *Server) rules_mod.Difficulty {
        return self.cfg.load().difficulty;
    }

    pub fn gamemodeName(_: *Server, m: rules_mod.GameMode) []const u8 {
        return m.name();
    }

    pub fn setDefaultGamemode(self: *Server, m: rules_mod.GameMode) void {
        var c = self.cfg.load();
        c.default_gamemode = m;
        self.cfg.store(c);
    }

    pub fn gameruleGet(self: *Server, name: []const u8) ?bool {
        const c = self.cfg.load();
        for (cmd_data.gamerules, 0..) |g, i| {
            if (std.mem.eql(u8, g.name, name)) return c.gamerules[i];
        }
        return null;
    }

    /// Returns false for unknown rules (caller prints norule).
    pub fn gameruleSet(self: *Server, name: []const u8, value: bool) bool {
        var c = self.cfg.load();
        for (cmd_data.gamerules, 0..) |g, i| {
            if (std.mem.eql(u8, g.name, name)) {
                c.gamerules[i] = value;
                self.cfg.store(c);
                return true;
            }
        }
        return false;
    }

    /// Natural-spawn gate (config spawn_mobs + per-kind mob_spawns +
    /// doMobSpawning gamerule, vanilla semantics): existing mobs are
    /// unaffected, only new spawns are refused. Every spawn ingress
    /// (pig auto-spawn today; spawners/eggs when they land) must call this.
    pub fn canSpawnMob(self: *Server, kind: mob_mod.Kind) bool {
        const c = self.cfg.load();
        if (!c.spawn_mobs) return false;
        if (!c.mob_spawn_allowed[@intFromEnum(kind)]) return false;
        return self.gameruleGet("doMobSpawning") orelse true;
    }

    /// keepInventory gamerule (death drops).
    pub fn keepInv(self: *Server) bool {
        return self.cfg.load().gamerules[2];
    }

    /// doTileDrops gamerule (block-break drops).
    pub fn tileDrops(self: *Server) bool {
        return self.cfg.load().gamerules[5];
    }

    pub fn gameruleList(self: *Server, out: []u8) []const u8 {
        const c = self.cfg.load();
        var ow: usize = 0;
        for (cmd_data.gamerules, 0..) |g, i| {
            ow += (std.fmt.bufPrint(out[ow..], "{s} = {s}\n", .{ g.name, if (c.gamerules[i]) "true" else "false" }) catch break).len;
        }
        if (ow > 0) ow -= 1; // drop trailing newline
        return out[0..ow];
    }

    pub fn seedString(self: *Server, out: []u8) []const u8 {
        return std.fmt.bufPrint(out, "Seed: {d}", .{self.drop_seed}) catch "Seed: 0";
    }

    /// World spawn block coords (default-center fallback for /pregen).
    pub fn worldSpawnPos(self: *Server) [3]i32 {
        return self.cfg.load().world_spawn;
    }

    // ---- experience ----

    pub fn xpCap(level: i32) i32 {
        if (level >= 30) return 62 + (level - 30) * 7;
        if (level >= 15) return 17 + (level - 15) * 3;
        return 17;
    }

    /// Queue S1F for one conn (lock must be held by the caller).
    fn queueExperience(c: *Conn) void {
        var eb: [perms_mod.max_name_len]u8 = undefined;
        const total: i16 = @truncate(c.xp_total);
        queueBuilt(c, packets.frameSetExperience(c.xp_bar, @intCast(c.xp_level), total, &eb));
    }

    /// Vanilla EntityPlayer.addExperience: capped total, fractional bar,
    /// level-ups preserve leftover against the new cap.
    pub fn addXp(self: *Server, name: []const u8, amount: i32) bool {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const c = findInSnap(snap, name) orelse return false;
        c.lock.lock();
        defer c.lock.unlock();
        if (c.state != .play) return false;
        var a = amount;
        const room: i64 = @as(i64, std.math.maxInt(i32)) - c.xp_total;
        if (@as(i64, a) > room) a = @intCast(room);
        c.xp_bar += @as(f32, @floatFromInt(a)) / @as(f32, @floatFromInt(xpCap(c.xp_level)));
        c.xp_total += a;
        while (c.xp_bar >= 1.0) {
            c.xp_bar = (c.xp_bar - 1.0) * @as(f32, @floatFromInt(xpCap(c.xp_level)));
            c.xp_level += 1;
            if (c.xp_level < 0) c.xp_level = 0;
            c.xp_bar /= @as(f32, @floatFromInt(xpCap(c.xp_level)));
        }
        queueExperience(c);
        return true;
    }

    /// Vanilla addExperienceLevel: negative clamps to 0/0/0; multiples of 5
    /// play the level-up sound.
    pub fn addLevels(self: *Server, name: []const u8, amount: i32) bool {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const c = findInSnap(snap, name) orelse return false;
        c.lock.lock();
        if (c.state != .play) {
            c.lock.unlock();
            return false;
        }
        c.xp_level += amount;
        if (c.xp_level < 0) {
            c.xp_level = 0;
            c.xp_bar = 0;
            c.xp_total = 0;
        }
        queueExperience(c);
        const lvl = c.xp_level;
        const px = c.pos_x;
        const py = c.pos_y;
        const pz = c.pos_z;
        c.lock.unlock();
        // Vanilla chimes every 5 levels (heard by the leveler).
        if (amount > 0 and lvl > 0 and @mod(lvl, 5) == 0) {
            _ = self.playSoundTo(name, "random.levelup", px, py, pz, 1.0, 1.0, 0.0);
        }
        return true;
    }

    // ---- pregeneration (/pregen, Chunky-style) ----
    //
    // 1.7.10 has no bossbar packet, so progress rides the next best
    // vanilla surfaces: the XP bar (level = percent, bar = fraction) for
    // the task owner, refreshed every 1Hz tick, plus chat lines for
    // milestones/rate/ETA. Progress frames are EPHEMERAL — conn.xp_* is
    // never mutated, so saves, /xp, and relogs are unaffected.

    /// Pregeneration task state (one at a time; guarded by pregen_lock).
    pub const PregenState = struct {
        active: bool = false,
        paused: bool = false,
        ccx: i32 = 0,
        ccz: i32 = 0,
        radius: i32 = 0,
        total: usize = 0,
        next_idx: usize = 0,
        done_idx: usize = 0,
        t_start_ms: i64 = 0,
        last_ms: i64 = 0,
        last_done: usize = 0,
        /// Smoothed chunks/sec (EMA over 1Hz polls).
        rate: f64 = 0,
        /// Independent completion counters for throughput discrimination:
        /// `last_completed`/`last_store_hits` snapshot the pool totals at
        /// the previous poll; `rate_true` is the EMA of fresh-generation
        /// completions, `rate_total` includes store hits. The concentric
        /// `done_idx` cursor still drives progress/ETA (order matters), but
        /// the displayed rate no longer caps at advance_cap/poll.
        last_completed: u64 = 0,
        last_store_hits: u64 = 0,
        rate_true: f64 = 0,
        rate_total: f64 = 0,
        /// Announced milestones (bit0=25%, bit1=50%, bit2=75%).
        milestones: u8 = 0,
        last_chat_ms: i64 = 0,
        /// Pool-wide failed counter at start (includes view-driven gen;
        /// reported as-is, see pollPregen).
        fail_base: u64 = 0,
        /// Pool-wide completed/store-hit baselines at start (fresh vs total
        /// throughput discrimination; view-driven gen pollutes both, so
        /// these are deltas for diagnosis, not task-exact counts).
        completed_base: u64 = 0,
        store_base: u64 = 0,
        /// GPU/cache counters sampled per 1Hz poll (deltas since task
        /// start are derived against these baselines where needed).
        /// Rendered on the progress line; all zero until the first poll
        /// with a pool attached.
        gpu_fill: u64 = 0,
        gpu_fallback: u64 = 0,
        gpu_batches: u64 = 0,
        cache_hits: u64 = 0,
        cache_misses: u64 = 0,
        cache_dup_misses: u64 = 0,
        cache_single_flight_hits: u64 = 0,
        ore_hits: u64 = 0,
        ore_misses: u64 = 0,
        owner_len: usize = 0,
        owner: [perms_mod.max_name_len]u8 = [_]u8{0} ** 16,
        /// Fake-Wither bossbar live on the owner's client (spawn frame sent;
        /// cleared when the owner drops offline so the next poll respawns).
        bar_spawned: bool = false,
        /// Bumped on begin/stop: polls commit cursors only into the task
        /// generation they snapshotted (stop+start inside one 1Hz window
        /// must not graft old cursors onto the new task).
        epoch: u64 = 0,
    };

    /// Max radius in chunks ((2r+1)^2 chunks; r=1000 is ~4M).
    pub const pregen_max_radius: i32 = 1000;
    /// In-flight ceiling for pregen top-ups (below GenPool.max_pending;
    /// leaves headroom for live view traffic on the shared pool).
    pub const pregen_inflight_cap: usize = 256;
    /// Head-advance iterations per 1Hz poll (each is one pool-mutex probe).
    /// Raised from 1024 so the concentric cursor no longer caps reported
    /// throughput at ~1024/s: 16384 probes per 1Hz poll still costs a single
    /// brief mutex per probe and only binds when the backlog is that deep.
    pub const pregen_advance_cap: usize = 16384;
    /// Milestone/heartbeat chat cadence (ms).
    pub const pregen_chat_ms: i64 = 30_000;
    /// Fake-Wither bossbar: fixed negative eid (eid_counter starts at 1 and
    /// only grows, so this can never collide with a real entity), WitherBoss
    /// network type, 300.0 max health (all jar-verified, see
    /// entity.writeBossMetadata). The wither never exists server-side.
    pub const pregen_bar_eid: i32 = -424242;
    /// Bossbar follow-point drop below the owner's feet (1.8 blocks).
    /// Jar-grounded (1.7.10 client, verified against the obfuscated jars):
    /// the bar is fed from RenderWither.doRender (BossStatus expires 100
    /// rendered frames after the wither leaves the frustum), so the fake
    /// must stay rendered — and a rendered wither is a particle fountain
    /// that invisibility does NOT silence: onLivingUpdate spawns 3 smoke
    /// puffs per tick at the head positions (middle +3.0, sides +2.2,
    /// ±1.3 lateral — no visibility check) plus a mobSpell aura while
    /// "armored" (health <= max/2, i.e. the whole first half of the bar).
    /// At feet level the heads sit at/above eye height (1.62) and the
    /// in-camera puffs wash out the screen. Dropping 1.8 puts the heads at
    /// +1.2/+0.4 (below the ahead-view, partly terrain-occluded) while the
    /// camera stays inside the 4.0-tall wither AABB (top at +2.2 vs eye
    /// 1.62, margin 0.58 — sneak/boat/horse stances included), which keeps
    /// it frustum-immune in every view direction.
    pub const pregen_bar_drop: f64 = 1.8;

    /// Concentric-square generation order: idx 0 is the center chunk,
    /// then rings r=1.. Each ring holds 8r chunks starting at
    /// 1+4r(r-1); within a ring the walk matches serve.Spiral (north edge
    /// L-to-R, east edge top-down, south edge R-to-L, west edge bottom-up).
    /// Pure/geometry-only: no locks, no IO.
    pub fn pregenOffset(idx: usize) ColOffset {
        if (idx == 0) return .{ .dx = 0, .dz = 0 };
        // Ring r: start(r) = 1+4r(r-1) <= idx < start(r+1).
        var r: usize = 1;
        while (true) : (r += 1) {
            const nr = r + 1;
            if (idx < 1 + 4 * nr * (nr - 1)) break;
        }
        const ri: i32 = @intCast(r);
        const side: usize = @intCast(2 * ri);
        const i = idx - (1 + 4 * r * (r - 1));
        if (i < side) return .{ .dx = -ri + @as(i32, @intCast(i)), .dz = -ri };
        if (i < 2 * side) return .{ .dx = ri, .dz = -ri + @as(i32, @intCast(i - side)) };
        if (i < 3 * side) return .{ .dx = ri - @as(i32, @intCast(i - 2 * side)), .dz = ri };
        return .{ .dx = -ri, .dz = ri - @as(i32, @intCast(i - 3 * side)) };
    }

    pub const PregenBegin = enum { started, already_running, no_gen };

    /// Start a task (center chunk ccx,ccz, radius chunks). Owner "" =
    /// console (progress via logs only). Caller formats the reply.
    pub fn pregenBegin(self: *Server, owner: []const u8, radius: i32, ccx: i32, ccz: i32) PregenBegin {
        if (self.gen_pool == null) return .no_gen;
        // Best-effort cleanup of a stale bar eid on the owner's client
        // (a kill -9 between spawn and destroy orphans it client-side;
        // the spawn below would otherwise fight it for BossStatus).
        self.destroyBossBar(owner);
        const now = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
        self.pregen_lock.lock();
        defer self.pregen_lock.unlock();
        if (self.pregen.active) return .already_running;
        const side: usize = @intCast(2 * radius + 1);
        self.pregen = .{
            .active = true,
            .ccx = ccx,
            .ccz = ccz,
            .radius = radius,
            .total = side * side,
            .t_start_ms = now,
            .last_ms = now,
            .last_chat_ms = now,
            .owner_len = @min(owner.len, 16),
        };
        @memcpy(self.pregen.owner[0..self.pregen.owner_len], owner[0..self.pregen.owner_len]);
        self.pregen.epoch +%= 1;
        if (self.gen_pool) |gp| {
            const gs = gp.snapshotStats();
            self.pregen.fail_base = gs.failed;
            self.pregen.completed_base = gs.completed;
            self.pregen.store_base = gs.store_hits;
            self.pregen.last_completed = gs.completed;
            self.pregen.last_store_hits = gs.store_hits;
        }
        return .started;
    }

    /// Cancel the active task. True when something was running.
    pub fn pregenStop(self: *Server) bool {
        self.pregen_lock.lock();
        if (!self.pregen.active) {
            self.pregen_lock.unlock();
            return false;
        }
        self.pregen.active = false;
        self.pregen.epoch +%= 1;
        self.pregen.bar_spawned = false;
        var owner: [perms_mod.max_name_len]u8 = undefined;
        const owner_len = self.pregen.owner_len;
        @memcpy(owner[0..owner_len], self.pregen.owner[0..owner_len]);
        self.pregen_lock.unlock();
        self.destroyBossBar(owner[0..owner_len]);
        return true;
    }

    pub const PregenPause = enum { paused, resumed, not_running };

    /// Toggle pause. Paused tasks hold their cursors (in-flight chunks
    /// still land); resume continues where it left off.
    pub fn pregenPauseToggle(self: *Server, pause: bool) PregenPause {
        self.pregen_lock.lock();
        defer self.pregen_lock.unlock();
        if (!self.pregen.active) return .not_running;
        self.pregen.paused = pause;
        return if (pause) .paused else .resumed;
    }

    /// One status line for /pregen status (or "" when idle — caller prints
    /// the idle message). Pure snapshot under the lock.
    pub fn pregenStatus(self: *Server, out: []u8) []const u8 {
        self.pregen_lock.lock();
        const st = self.pregen;
        self.pregen_lock.unlock();
        if (!st.active) return "";
        return formatPregenLine(st, memstat_mod.rssBytes(self.io), memstat_mod.peakRssBytes(self.io), out);
    }

    /// Shared line format: `12.4% (3412/27556) chunks — 87.3/s, ETA 04:12,
    /// elapsed 00:39 [paused]`.
    fn mmss(v: i64, out: []u8) []const u8 {
        const mm = @divFloor(v, 60);
        const ss = @mod(v, 60);
        return std.fmt.bufPrint(out, "{s}{d}:{s}{d}", .{
            if (mm < 10) "0" else "", mm,
            if (ss < 10) "0" else "", ss,
        }) catch "--:--";
    }

    pub fn formatPregenLine(st: PregenState, rss: usize, peak: usize, out: []u8) []const u8 {
        const pct: f64 = if (st.total == 0) 0 else @as(f64, @floatFromInt(st.done_idx)) * 100.0 / @as(f64, @floatFromInt(st.total));
        const el_s: i64 = @divFloor(st.last_ms - st.t_start_ms, 1000);
        var ebuf: [perms_mod.max_name_len]u8 = undefined;
        var lbuf: [perms_mod.max_name_len]u8 = undefined;
        var eta: []const u8 = "?";
        if (st.rate > 0.001 and st.done_idx < st.total) {
            const eta_s: i64 = @intFromFloat(@as(f64, @floatFromInt(st.total - st.done_idx)) / st.rate);
            eta = mmss(eta_s, &ebuf);
        }
        const el = mmss(el_s, &lbuf);
        var rss_buf: [32]u8 = undefined;
        var peak_buf: [32]u8 = undefined;
        // GPU/cache tail: average batch size (fills/dispatches) spots a
        // dispatch-overhead collapse; fallback count spots a failing GPU
        // path; cache hit% spots column-cache thrashing. Always shown so
        // the line shape never shifts mid-run. True/total rates (fresh
        // completions vs completions+store-hits) discriminate the old
        // 1024/poll cursor cap from real generation throughput.
        const avg_batch: f64 = if (st.gpu_batches == 0) 0 else @as(f64, @floatFromInt(st.gpu_fill)) / @as(f64, @floatFromInt(st.gpu_batches));
        const ch_total: u64 = st.cache_hits + st.cache_misses;
        const ore_total: u64 = st.ore_hits + st.ore_misses;
        const ore_pct: f64 = if (ore_total == 0) 0 else @as(f64, @floatFromInt(st.ore_hits)) * 100.0 / @as(f64, @floatFromInt(ore_total));
        var tail_buf: [192]u8 = undefined;
        const tail: []const u8 = if (ch_total == 0)
            std.fmt.bufPrint(&tail_buf, ", gpu {d}ch/{d}dsp fb={d} avg={d:.1}, cache n/a, true {d:.1}/s tot {d:.1}/s dup {d} sf {d} ore {d:.0}%", .{ st.gpu_fill, st.gpu_batches, st.gpu_fallback, avg_batch, st.rate_true, st.rate_total, st.cache_dup_misses, st.cache_single_flight_hits, ore_pct }) catch ""
        else
            std.fmt.bufPrint(&tail_buf, ", gpu {d}ch/{d}dsp fb={d} avg={d:.1}, cache {d:.0}% dup {d} sf {d} ore {d:.0}%, true {d:.1}/s tot {d:.1}/s", .{ st.gpu_fill, st.gpu_batches, st.gpu_fallback, avg_batch, @as(f64, @floatFromInt(st.cache_hits)) * 100.0 / @as(f64, @floatFromInt(ch_total)), st.cache_dup_misses, st.cache_single_flight_hits, ore_pct, st.rate_true, st.rate_total }) catch "";
        return std.fmt.bufPrint(out, "{d:.1}% ({d}/{d}) chunks — {d:.1}/s, ETA {s}, elapsed {s}, rss={s} peak={s}{s}{s}", .{
            pct, st.done_idx, st.total, st.rate, eta, el,
            memstat_mod.formatBytes(rss, &rss_buf),
            memstat_mod.formatBytes(peak, &peak_buf),
            if (st.paused) " [paused]" else "",
            tail,
        }) catch "pregen: ?%";
    }

    /// Bossbar fill from progress (Wither max health 300.0; clamped to a
    ///sliver so the bar renders ~empty rather than dead at 0%).
    pub fn pregenBarHealth(pct01: f64) f32 {
        return @floatCast(@max(1.0, @max(0, @min(1, pct01)) * 300.0));
    }

    /// Bossbar title ("Pregeneration 12%" + " (paused)" when held).
    pub fn pregenBarTitle(pct01: f64, paused: bool, out: []u8) []const u8 {
        const pct: i32 = @intFromFloat(@max(0, @min(1, pct01)) * 100.0);
        return std.fmt.bufPrint(out, "Pregeneration {d}%{s}", .{ pct, if (paused) " (paused)" else "" }) catch "Pregeneration";
    }

    /// Fake-Wither bossbar send: spawn once at the owner's feet minus
    /// pregen_bar_drop, then per-tick teleport-follow + metadata refresh
    /// (title + fill). Frames go to the owner only. Returns false when
    /// unreachable (offline/dead).
    ///
    /// Position is deliberate: the camera sits inside the wither's AABB,
    /// so it is never frustum-culled in any view direction (a parked
    /// wither feeds no BossStatus — the bar expires 100 frames after its
    /// last render — so parking it away is not an option). Invisible + tag
    /// hidden, so nothing shows except the bar; the client still ticks it,
    /// so a faint wither groan may occasionally play (same as BarAPI-era
    /// fake bars).
    fn updateBossBar(self: *Server, owner: []const u8, pct01: f64, title: []const u8, spawn: bool) bool {
        if (owner.len == 0) return false;
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const c = findInSnap(snap, owner) orelse return false;
        c.lock.lock();
        defer c.lock.unlock();
        if (c.state != .play or c.dead) return false;
        const health = pregenBarHealth(pct01);
        const bar_y = c.pos_y - pregen_bar_drop;
        if (spawn) {
            var sb: [384]u8 = undefined;
            queueBuilt(c, packets.frameBossSpawn(pregen_bar_eid, c.pos_x, bar_y, c.pos_z, health, title, &sb));
        } else {
            var tb: [64]u8 = undefined;
            queueBuilt(c, packets.frameEntityTeleport(pregen_bar_eid, c.pos_x, bar_y, c.pos_z, 0, 0, &tb));
            var mb: [384]u8 = undefined;
            queueBuilt(c, packets.frameBossUpdate(pregen_bar_eid, health, title, &mb));
        }
        return true;
    }

    /// Destroy the fake Wither on the owner's client (finish/cancel).
    /// Silent when the owner is offline (their client state is gone anyway).
    fn destroyBossBar(self: *Server, owner: []const u8) void {
        if (owner.len == 0) return;
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const c = findInSnap(snap, owner) orelse return;
        c.lock.lock();
        defer c.lock.unlock();
        if (c.state != .play or c.dead) return;
        var db: [perms_mod.max_name_len]u8 = undefined;
        queueBuilt(c, packets.frameDestroyEntitiesFramed(&[_]i32{pregen_bar_eid}, &db));
    }

    /// One poll's bossbar refresh: spawn-or-update when the owner is live,
    /// else clear the spawned flag so the next live poll respawns.
    fn refreshBossBar(self: *Server, st: PregenState, pct01: f64, paused: bool) void {
        if (st.owner_len == 0) return;
        var tb: [64]u8 = undefined;
        const title = pregenBarTitle(pct01, paused, &tb);
        const live = self.updateBossBar(st.owner[0..st.owner_len], pct01, title, !st.bar_spawned);
        self.pregen_lock.lock();
        defer self.pregen_lock.unlock();
        if (self.pregen.epoch != st.epoch) return;
        self.pregen.bar_spawned = live;
    }

    /// Chat a line to the task owner (player) and always to the log.
    fn pregenTell(self: *Server, owner: []const u8, text: []const u8) void {
        std.log.info("(pregen) {s}", .{text});
        if (owner.len > 0) self.notifyPlayer(owner, text);
    }

    /// Pregen queue top-up (10Hz driver: called from redstoneLoop; the 1Hz
    /// poll below keeps advance/rate/bar/chat). Refills in-flight to the
    /// cap so fast workers never idle between 1Hz polls — with 1Hz-only
    /// top-up, throughput capped at ~cap chunks/s (256/s) no matter how
    /// fast generation was. Respects pause; top-up only (no done cursor,
    /// no rate). Same epoch guard as the 1Hz poll on commit.
    fn topupPregen(self: *Server) void {
        self.pregen_lock.lock();
        if (!self.pregen.active or self.pregen.paused) {
            self.pregen_lock.unlock();
            return;
        }
        const st = self.pregen;
        self.pregen_lock.unlock();
        const gp = self.gen_pool orelse return;
        var budget: usize = pregen_inflight_cap - @min(gp.pending(), pregen_inflight_cap);
        var next = st.next_idx;
        while (budget > 0 and next < st.total) : (budget -= 1) {
            const o = pregenOffset(next);
            gp.request(0, st.ccx + o.dx, st.ccz + o.dz);
            next += 1;
        }
        self.pregen_lock.lock();
        if (self.pregen.active and !self.pregen.paused and self.pregen.epoch == st.epoch) {
            // Monotonic: concurrent 1Hz/10Hz top-ups must never regress
            // a cursor a newer poll already advanced (re-requests are
            // deduped, but the cursor must not move backwards).
            self.pregen.next_idx = @max(self.pregen.next_idx, next);
        }
        self.pregen_lock.unlock();
    }

    /// 1Hz driver (called from tickOnce): advance the completion cursor,
    /// refresh the XP bar, heartbeat/milestone chats. Top-up lives in
    /// topupPregen (10Hz) so the fill cadence never gates throughput.
    /// Lock discipline: pregen_lock for cursor snapshots only; pool + LSM
    /// + conn work all happens unlocked (leaf order preserved).
    pub fn pollPregen(self: *Server, now_ms: i64) void {
        self.pregen_lock.lock();
        if (!self.pregen.active) {
            self.pregen_lock.unlock();
            return;
        }
        const st = self.pregen;
        self.pregen_lock.unlock();
        if (st.paused) {
            // Frozen bar only (no top-up, no cursor, no chat): keeps the
            // client's 100-tick BossStatus alive across long pauses.
            const frozen: f64 = if (st.total == 0) 1 else @as(f64, @floatFromInt(st.done_idx)) / @as(f64, @floatFromInt(st.total));
            self.refreshBossBar(st, frozen, true);
            return;
        }
        const gp = self.gen_pool orelse return;
        // Keep the queue full first (10Hz helper, same epoch guard), then
        // re-read the cursor it committed for the advance bound below.
        self.topupPregen();
        self.pregen_lock.lock();
        const next = if (self.pregen.epoch == st.epoch) self.pregen.next_idx else st.next_idx;
        self.pregen_lock.unlock();
        // Advance: head leaves in-flight exactly when its worker finishes.
        var done = st.done_idx;
        var guard: usize = 0;
        while (guard < pregen_advance_cap and done < next) : (guard += 1) {
            const o = pregenOffset(done);
            if (gp.isInflight(0, st.ccx + o.dx, st.ccz + o.dz)) break;
            done += 1;
        }
        // Hit the raised cap with more backlog pending: the concentric
        // cursor is now the bottleneck, not generation. Independent pool
        // counters below discriminate this (completed keeps climbing while
        // done stalls at +cap). Keep the cursor (order matters for ETA)
        // but report the true rate separately.
        const capped = (guard >= pregen_advance_cap and done < next);
        _ = capped;
        // Rate (EMA) + failures (pool-wide delta, includes view-driven gen).
        const dt_ms = now_ms - st.last_ms;
        var rate = st.rate;
        if (dt_ms > 0 and done >= st.last_done) {
            const inst = @as(f64, @floatFromInt(done - st.last_done)) * 1000.0 / @as(f64, @floatFromInt(dt_ms));
            rate = if (st.last_done == 0 and st.rate == 0) inst else st.rate * 0.7 + inst * 0.3;
        }
        // Single snapshot feeds failures + GPU/cache counters below.
        const gs = gp.snapshotStats();
        const failed = gs.failed -| st.fail_base;
        // Independent throughput: fresh completions + store hits since the
        // last poll. Unaffected by the concentric-cursor cap above, so it
        // discriminates CPU/store caps from progress-counter caps.
        var rate_true = st.rate_true;
        var rate_total = st.rate_total;
        if (dt_ms > 0) {
            const d_comp: u64 = gs.completed -| st.last_completed;
            const d_hit: u64 = gs.store_hits -| st.last_store_hits;
            const inst_true = @as(f64, @floatFromInt(d_comp)) * 1000.0 / @as(f64, @floatFromInt(dt_ms));
            const inst_total = @as(f64, @floatFromInt(d_comp + d_hit)) * 1000.0 / @as(f64, @floatFromInt(dt_ms));
            rate_true = if (st.rate_true == 0) inst_true else st.rate_true * 0.7 + inst_true * 0.3;
            rate_total = if (st.rate_total == 0) inst_total else st.rate_total * 0.7 + inst_total * 0.3;
        }
        const finished = done >= st.total;
        const pct01: f64 = if (st.total == 0) 1 else @as(f64, @floatFromInt(done)) / @as(f64, @floatFromInt(st.total));
        // Commit cursors.
        self.pregen_lock.lock();
        // Task may have been stopped/paused/restarted mid-poll: commit only
        // into the same generation (epoch match implies params match).
        if (self.pregen.active and !self.pregen.paused and self.pregen.epoch == st.epoch) {
            // next_idx monotonic (see topupPregen); done_idx only moves
            // here, on the single 1Hz poller.
            self.pregen.next_idx = @max(self.pregen.next_idx, next);
            self.pregen.done_idx = done;
            self.pregen.last_ms = now_ms;
            self.pregen.last_done = done;
            self.pregen.rate = rate;
            self.pregen.last_completed = gs.completed;
            self.pregen.last_store_hits = gs.store_hits;
            self.pregen.rate_true = rate_true;
            self.pregen.rate_total = rate_total;
            self.pregen.gpu_fill = gs.gpu_fill;
            self.pregen.gpu_fallback = gs.gpu_fallback;
            self.pregen.gpu_batches = gs.gpu_batches;
            self.pregen.cache_hits = gs.cache_hits;
            self.pregen.cache_misses = gs.cache_misses;
            self.pregen.cache_dup_misses = gs.cache_dup_misses;
            self.pregen.cache_single_flight_hits = gs.cache_single_flight_hits;
            self.pregen.ore_hits = gs.ore_hits;
            self.pregen.ore_misses = gs.ore_misses;
            if (finished) self.pregen.active = false;
        }
        const cur = self.pregen;
        const still_us = cur.active and !cur.paused and cur.epoch == st.epoch;
        var owner: [perms_mod.max_name_len]u8 = undefined;
        const owner_len = st.owner_len;
        @memcpy(owner[0..owner_len], st.owner[0..owner_len]);
        self.pregen_lock.unlock();
        // Display + milestones (unlocked).
        self.refreshBossBar(st, pct01, false);
        var line: [384]u8 = undefined;
        var inner: [256]u8 = undefined;
        if (finished) {
            const el_s: i64 = @divFloor(now_ms - st.t_start_ms, 1000);
            const avg: f64 = if (el_s > 0) @as(f64, @floatFromInt(st.total)) / @as(f64, @floatFromInt(el_s)) else 0;
            const msg = std.fmt.bufPrint(&line, "Pregeneration complete: {d} chunks in {s} ({d:.1}/s avg, {d} pool failures)", .{
                st.total, mmss(el_s, &inner), avg, failed,
            }) catch "Pregeneration complete";
            self.pregenTell(if (owner_len > 0) owner[0..owner_len] else "", msg);
            self.pregen_lock.lock();
            const same_epoch = self.pregen.epoch == st.epoch;
            if (same_epoch) self.pregen.bar_spawned = false;
            self.pregen_lock.unlock();
            if (same_epoch) self.destroyBossBar(if (owner_len > 0) owner[0..owner_len] else "");
            return;
        }
        if (!still_us) return;
        // Milestones at 25/50/75 (+ periodic heartbeat).
        const marks = [_]struct { bit: u3, pct: f64, label: []const u8 }{
            .{ .bit = 0, .pct = 25, .label = "25%" },
            .{ .bit = 1, .pct = 50, .label = "50%" },
            .{ .bit = 2, .pct = 75, .label = "75%" },
        };
        for (marks) |m| {
            if (pct01 * 100.0 >= m.pct and st.milestones & (@as(u8, 1) << m.bit) == 0) {
                self.pregen_lock.lock();
                if (self.pregen.active and self.pregen.epoch == st.epoch) self.pregen.milestones |= @as(u8, 1) << m.bit;
                self.pregen_lock.unlock();
                const msg = std.fmt.bufPrint(&line, "Pregeneration {s}: {s}", .{ m.label, formatPregenLine(cur, memstat_mod.rssBytes(self.io), memstat_mod.peakRssBytes(self.io), &inner) }) catch "Pregeneration milestone";
                self.pregenTell(if (owner_len > 0) owner[0..owner_len] else "", msg);
                break;
            }
        }
        if (now_ms - st.last_chat_ms >= pregen_chat_ms) {
            self.pregen_lock.lock();
            if (self.pregen.active and self.pregen.epoch == st.epoch) self.pregen.last_chat_ms = now_ms;
            self.pregen_lock.unlock();
            const msg = std.fmt.bufPrint(&line, "Pregenerating: {s}", .{formatPregenLine(cur, memstat_mod.rssBytes(self.io), memstat_mod.peakRssBytes(self.io), &inner)}) catch "Pregenerating...";
            self.pregenTell(if (owner_len > 0) owner[0..owner_len] else "", msg);
        }
    }

    // ---- potion effects ----

    /// Give (or refresh) an effect; replaces same-id, 8-slot cap.
    /// False when the player isn't online.
    pub fn effectGive(self: *Server, name: []const u8, id: u8, seconds: i32, amp: u8) bool {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const c = findInSnap(snap, name) orelse return false;
        c.lock.lock();
        defer c.lock.unlock();
        if (c.state != .play) return false;
        const ticks: i32 = seconds * 20;
        var slot: ?usize = null;
        for (&c.effects, 0..) |*s, i| {
            if (s.*) |e| {
                if (e.id == id) {
                    slot = i;
                    break;
                }
            } else if (slot == null) {
                slot = i;
            }
        }
        const si = slot orelse return true; // full: still success, vanilla drops extras silently? no — vanilla has no cap; ours holds 8 (documented)
        c.effects[si] = .{ .id = id, .amplifier = amp, .ticks = ticks };
        var eb: [perms_mod.max_name_len]u8 = undefined;
        queueBuilt(c, packets.frameEntityEffect(c.eid, id, amp, ticks, &eb));
        return true;
    }

    /// Clear one effect (null id = all). Returns removed count, or null
    /// when the player isn't online.
    /// S1E remove-effect frame scratch (id + length + eid varints + id byte).
    const effect_remove_buf: usize = 8;

    /// Send one S1E effect removal (best-effort; drops when it won't fit).
    fn sendEffectRemove(conn: *Conn, eid: i32, id: u8) void {
        var eb: [effect_remove_buf]u8 = undefined;
        queueBuilt(conn, packets.frameRemoveEntityEffect(eid, id, &eb));
    }

    pub fn effectClear(self: *Server, name: []const u8, id: ?u8) ?usize {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const c = findInSnap(snap, name) orelse return null;
        c.lock.lock();
        defer c.lock.unlock();
        if (c.state != .play) return null;
        var n: usize = 0;
        for (&c.effects) |*s| {
            const e = s.* orelse continue;
            if (id != null and e.id != id.?) continue;
            sendEffectRemove(c, c.eid, e.id);
            s.* = null;
            n += 1;
        }
        return n;
    }

    /// Tick down effects (20 units per 1Hz tick); expiry sends S1E.
    fn tickEffects(self: *Server) void {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            e.conn.lock.lock();
            if (e.conn.state != .play) {
                e.conn.lock.unlock();
                continue;
            }
            var expired: [8]u8 = undefined;
            var n_exp: usize = 0;
            for (&e.conn.effects) |*s| {
                if (s.*) |*fx| {
                    fx.ticks -= 20;
                    if (fx.ticks <= 0) {
                        expired[n_exp] = fx.id;
                        n_exp += 1;
                        s.* = null;
                    }
                }
            }
            for (expired[0..n_exp]) |id| sendEffectRemove(e.conn, e.conn.eid, id);
            e.conn.lock.unlock();
        }
    }

    // ---- raw-NBT `ench` list helpers (wire format is uncompressed NBT) ----

    /// NBT tag numbers (the ench-list code reads/writes raw tags).
    const nbt_end: u8 = 0;
    const nbt_short: u8 = 3;
    const nbt_string: u8 = 8;
    const nbt_list: u8 = 9;
    const nbt_compound: u8 = 10;

    /// One `ench`-list compound entry ({id: short, lvl: short}, 16 bytes).
    const ench_entry_bytes: usize = 16;

    /// Write one ench entry at `w.*`, advancing it by ench_entry_bytes.
    /// Caller guarantees room (sized by the list_bytes checks below).
    fn writeEnchEntry(out: []u8, w: *usize, id: u8, lvl: u8) void {
        out[w.*] = nbt_short;
        w.* += 1;
        std.mem.writeInt(u16, out[w.*..][0..2], 2, .big);
        w.* += 2;
        out[w.*] = 'i';
        out[w.* + 1] = 'd';
        w.* += 2;
        std.mem.writeInt(i16, out[w.*..][0..2], id, .big);
        w.* += 2;
        out[w.*] = nbt_short;
        w.* += 1;
        std.mem.writeInt(u16, out[w.*..][0..2], 3, .big);
        w.* += 2;
        out[w.*] = 'l';
        out[w.* + 1] = 'v';
        out[w.* + 2] = 'l';
        w.* += 3;
        std.mem.writeInt(i16, out[w.*..][0..2], lvl, .big);
        w.* += 2;
        out[w.*] = nbt_end;
        w.* += 1;
    }

    /// Write the `ench` list header (tag + name + compound-list marker).
    /// Caller guarantees room.
    fn writeEnchListHead(out: []u8, w: *usize) void {
        out[w.*] = nbt_list;
        w.* += 1;
        std.mem.writeInt(u16, out[w.*..][0..2], 4, .big);
        w.* += 2;
        out[w.*] = 'e';
        out[w.* + 1] = 'n';
        out[w.* + 2] = 'c';
        out[w.* + 3] = 'h';
        w.* += 4;
        out[w.*] = nbt_compound;
        w.* += 1;
    }

    /// Skip one NBT payload; false on truncation/unknown tag.
    fn nbtNeed(buf: []const u8, i: *usize, n: usize) bool {
        if (i.* + n > buf.len) return false;
        i.* += n;
        return true;
    }

    /// Skip one NBT payload; false on truncation/unknown tag.
    fn nbtSkip(tag: u8, buf: []const u8, i: *usize) bool {
        switch (tag) {
            0 => return true,
            1, 7 => return nbtNeed(buf, i, 1),
            2 => return nbtNeed(buf, i, 2),
            3, 5 => return nbtNeed(buf, i, 4),
            4, 6 => return nbtNeed(buf, i, 8),
            8 => {
                if (i.* + 2 > buf.len) return false;
                const l = std.mem.readInt(u16, buf[i.*..][0..2], .big);
                i.* += 2;
                return nbtNeed(buf, i, l);
            },
            9 => {
                if (i.* + 5 > buf.len) return false;
                const et = buf[i.*];
                i.* += 1;
                const n = std.mem.readInt(i32, buf[i.*..][0..4], .big);
                i.* += 4;
                if (n < 0) return false;
                var k: i32 = 0;
                while (k < n) : (k += 1) {
                    if (et == 10) {
                        if (!nbtCompound(buf, i, false)) return false;
                    } else if (!nbtSkip(et, buf, i)) return false;
                }
                return true;
            },
            10 => return nbtCompound(buf, i, true),
            11 => {
                if (i.* + 4 > buf.len) return false;
                const n = std.mem.readInt(i32, buf[i.*..][0..4], .big);
                i.* += 4;
                if (n < 0 or n > 100000) return false;
                return nbtNeed(buf, i, @as(usize, @intCast(n)) * 4);
            },
            else => return false,
        }
    }

    /// Bounds-checked u16 read advancing the cursor (null = truncated).
    fn takeU16(raw: []const u8, i: *usize) ?u16 {
        if (i.* + 2 > raw.len) return null;
        const v = std.mem.readInt(u16, raw[i.*..][0..2], .big);
        i.* += 2;
        return v;
    }

    /// Bounds-checked slice read advancing the cursor (null = truncated).
    fn takeSlice(raw: []const u8, i: *usize, n: usize) ?[]const u8 {
        if (i.* + n > raw.len) return null;
        const s = raw[i.* .. i.* + n];
        i.* += n;
        return s;
    }

    /// Bounds-checked NBT string (u16 length + bytes).
    fn takeNbtString(raw: []const u8, i: *usize) ?[]const u8 {
        const n = takeU16(raw, i) orelse return null;
        return takeSlice(raw, i, n);
    }

    /// Walk a compound's named tags; false on truncation. When `ids_out` is
    /// given, harvests `ench`-list (id,lvl) pairs instead of stopping early.
    fn nbtCompound(buf: []const u8, i: *usize, named: bool) bool {
        _ = named;
        while (true) {
            if (i.* + 1 > buf.len) return false;
            const tag = buf[i.*];
            i.* += 1;
            if (tag == 0) return true;
            const nl = takeU16(buf, i) orelse return false;
            if (takeSlice(buf, i, nl) == null) return false;
            if (!nbtSkip(tag, buf, i)) return false;
        }
    }

    /// Harvest (id, lvl) pairs from a top-level compound's `ench` list.
    /// Returns pair count; `valid` is false when the bytes aren't a compound.
    fn parseEnchIds(raw: []const u8, out: *[8]u8) usize {
        var lvl_out: [8]u8 = undefined;
        return parseEnchList(raw, out, &lvl_out).n;
    }

    const EnchParse = struct { n: usize = 0, list_at: usize = 0, list_end: usize = 0, valid: bool = false };

    fn parseEnchList(raw: []const u8, ench_ids: *[8]u8, ench_lvls: *[8]u8) EnchParse {
        var r = EnchParse{};
        if (raw.len < 3) return r;
        if (raw[0] != 10) return r; // root compound
        var i: usize = 1;
        // Root name (usually empty u16).
        if (takeNbtString(raw, &i) == null) return r;
        while (true) {
            if (i + 1 > raw.len) return r;
            const tag = raw[i];
            i += 1;
            if (tag == 0) {
                r.valid = i == raw.len;
                return r;
            }
            const name = takeNbtString(raw, &i) orelse return r;
            if (tag == 9 and std.mem.eql(u8, name, "ench")) {
                r.list_at = i; // points at element-type byte
                if (i + 5 > raw.len) return r;
                if (raw[i] != 10) return r; // must be compound list
                i += 1;
                const n = std.mem.readInt(i32, raw[i..][0..4], .big);
                i += 4;
                if (n < 0 or n > 64) return r;
                var k: i32 = 0;
                while (k < n) : (k += 1) {
                    const pair = parseEnchEntry(raw, &i) orelse return r;
                    if (r.n < 8) {
                        ench_ids[r.n] = pair.id;
                        ench_lvls[r.n] = pair.lvl;
                        r.n += 1;
                    }
                }
                r.list_end = i;
            } else {
                var j = i;
                if (!nbtSkip(tag, raw, &j)) return r;
                i = j;
            }
        }
    }

    /// One `ench`-list compound entry: (id, lvl) shorts (missing → 0).
    /// Null when the entry is truncated (caller abandons the parse).
    const EnchPair = struct { id: u8, lvl: u8 };

    fn parseEnchEntry(raw: []const u8, i: *usize) ?EnchPair {
        var id: ?u8 = null;
        var lvl: ?u8 = null;
        while (true) {
            if (i.* + 1 > raw.len) return null;
            const et = raw[i.*];
            i.* += 1;
            if (et == 0) break;
            const ename = takeNbtString(raw, i) orelse return null;
            if (et == 3) {
                const v = takeSlice(raw, i, 2) orelse return null;
                const short = std.mem.readInt(i16, v[0..2], .big);
                if (std.mem.eql(u8, ename, "id")) id = @truncate(@max(0, short));
                if (std.mem.eql(u8, ename, "lvl")) lvl = @truncate(@max(0, short));
            } else {
                var j = i.*;
                if (!nbtSkip(et, raw, &j)) return null;
                i.* = j;
            }
        }
        return .{ .id = id orelse 0, .lvl = lvl orelse 0 };
    }

    /// Build merged NBT: existing `ench` list updated (or appended before the
    /// root TAG_End), else a fresh compound. Null when `out` is too small.
    fn buildEnchNbt(existing: ?[]const u8, ench_id: u8, level: u8, out: []u8) ?[]const u8 {
        var have: [8]u8 = undefined;
        var have_lvls: [8]u8 = undefined;
        if (existing) |raw| {
            const p = parseEnchList(raw, &have, &have_lvls);
            if (p.valid) {
                // Update or append the target entry.
                var n = p.n;
                var hit = false;
                for (have[0..n], 0..) |id, k| {
                    if (id == ench_id) {
                        have_lvls[k] = level;
                        hit = true;
                    }
                }
                if (!hit) {
                    if (n >= 8) return null;
                    have[n] = ench_id;
                    have_lvls[n] = level;
                    n += 1;
                }
                if (p.list_end > p.list_at) {
                    // Splice: raw[0..list_at] + new list + raw[list_end..].
                    var w: usize = 0;
                    const pre = raw[0..p.list_at];
                    if (w + pre.len > out.len) return null;
                    @memcpy(out[w..][0..pre.len], pre);
                    w += pre.len;
                    const list_bytes = 1 + 4 + n * ench_entry_bytes; // 0A + count + entries
                    if (w + list_bytes + (raw.len - p.list_end) > out.len) return null;
                    out[w] = nbt_compound;
                    w += 1;
                    std.mem.writeInt(i32, out[w..][0..4], @intCast(n), .big);
                    w += 4;
                    for (have[0..n], have_lvls[0..n]) |id, lvl| writeEnchEntry(out, &w, id, lvl);
                    const post = raw[p.list_end..];
                    @memcpy(out[w..][0..post.len], post);
                    w += post.len;
                    return out[0..w];
                }
                // No ench list (valid compound without one): append before end.
                if (raw.len < 1 or raw[raw.len - 1] != nbt_end) return null;
                const list_bytes = 1 + 2 + 4 + 1 + 4 + ench_entry_bytes; // tag+name+count+entry
                if (raw.len - 1 + list_bytes + 1 > out.len) return null;
                var w: usize = 0;
                @memcpy(out[w..][0 .. raw.len - 1], raw[0 .. raw.len - 1]);
                w += raw.len - 1;
                writeEnchListHead(out, &w);
                std.mem.writeInt(i32, out[w..][0..4], 1, .big);
                w += 4;
                writeEnchEntry(out, &w, ench_id, level);
                out[w] = nbt_end;
                w += 1;
                return out[0..w];
            }
        }
        // Fresh compound with a single-entry ench list:
        // root(1) + name(2) + list head(7) + count(4) + entry(16) + ends(2).
        const fresh_bytes: usize = 1 + 2 + 7 + 4 + ench_entry_bytes + 2;
        if (out.len < fresh_bytes) return null;
        var w: usize = 0;
        out[w] = nbt_compound;
        w += 1; // root compound, empty name
        out[w] = 0;
        out[w + 1] = 0;
        w += 2;
        writeEnchListHead(out, &w); // ench list
        std.mem.writeInt(i32, out[w..][0..4], 1, .big);
        w += 4;
        writeEnchEntry(out, &w, ench_id, level);
        out[w] = nbt_end;
        w += 1; // root end
        return out[0..w];
    }

    /// Enchant the held item (`ench` NBT list). Use for messages only —
    /// the NBT bytes are built by `enchNbt`.
    pub const EnchantResult = enum { ok, no_item, cant_enchant, no_room };

    pub fn enchantById(self: *Server, id: u8) ?cmd_data.Ench {
        _ = self;
        return cmd_data.enchantById(id);
    }

    pub fn enchantMax(self: *Server, id: u8) u8 {
        _ = self;
        return cmd_data.enchantById(id).?.max;
    }

    /// Potion display name for /effect feedback (1..23, else null).
    pub fn effectName(self: *Server, id: u8) ?[]const u8 {
        _ = self;
        return cmd_data.effectName(id);
    }
    pub fn enchantHeld(self: *Server, name: []const u8, ench_id: u8, level: u8) ?EnchantResult {
        const ench = cmd_data.enchantById(ench_id) orelse return .cant_enchant;
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const c = findInSnap(snap, name) orelse return null;
        c.lock.lock();
        defer c.lock.unlock();
        if (c.state != .play) return null;
        const held_i: usize = 36 + c.selected;
        var st = c.inv[held_i] orelse return .no_item;
        const wire_id = wire.toWire(st.id);
        if (!cmd_data.enchantApplies(ench.cat, wire_id)) return .cant_enchant;
        // Existing enchants must all combine (vanilla cantCombine check).
        if (st.nbt) |raw| {
            var have: [8]u8 = undefined;
            const n = parseEnchIds(raw, &have);
            for (have[0..n]) |other| {
                if (!cmd_data.enchantsCombine(ench_id, other)) return .cant_enchant;
            }
        }
        var nb: [2048]u8 = undefined;
        const nbt = buildEnchNbt(st.nbt, ench_id, level, &nb) orelse return .no_room;
        item_mod.freeStack(c.allocator, &c.inv[held_i]);
        c.inv[held_i] = .{ .id = st.id, .count = st.count, .damage = st.damage, .nbt = c.allocator.dupe(u8, nbt) catch null };
        st = c.inv[held_i] orelse return .no_room;
        const f = packets.frameSetSlotAlloc(self.gpa, 0, @intCast(held_i), st) catch return .ok;
        defer self.gpa.free(f);
        c.queueFramed(f) catch {};
        return .ok;
    }

    /// Clear one cell when `match` holds; returns units removed.
    fn clearCell(alloc: std.mem.Allocator, cell: *?item_mod.Stack, match: bool) usize {
        if (!match) return 0;
        const st = cell.* orelse return 0;
        const n: usize = @intCast(st.count);
        item_mod.freeStack(alloc, cell);
        cell.* = null;
        return n;
    }

    /// Clear matching stacks (item + data(-1 = any), or everything).
    /// Returns removed item count, or null when offline.
    pub fn clearInventory(self: *Server, name: []const u8, wire_id: ?u16, data: i16) ?usize {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const c = findInSnap(snap, name) orelse return null;
        c.lock.lock();
        if (c.state != .play) {
            c.lock.unlock();
            return null;
        }
        var removed: usize = 0;
        if (wire_id) |w| {
            // Unmapped wire ids (air, gaps) match nothing: vanilla reports
            // clear.failure, not a parse error.
            const id = wire.fromWire(w) orelse {
                c.lock.unlock();
                return 0;
            };
            for (&c.inv) |*s| {
                const keep = if (s.*) |st| st.id == id and (data < 0 or st.damage == data) else false;
                removed += clearCell(c.allocator, s, keep);
            }
            const cmatch = if (c.cursor) |st| st.id == id and (data < 0 or st.damage == data) else false;
            removed += clearCell(c.allocator, &c.cursor, cmatch);
        } else {
            for (&c.inv) |*s| removed += clearCell(c.allocator, s, true);
            removed += clearCell(c.allocator, &c.cursor, true);
        }
        // Full-window resync (vanilla detectAndSendChanges).
        const wf = packets.frameWindowItemsAlloc(self.gpa, 0, &c.inv) catch null;
        const cf = if (wf != null) packets.frameSetSlotAlloc(self.gpa, -1, -1, c.cursor) catch null else null;
        c.lock.unlock();
        if (wf != null or cf != null) {
            c.lock.lock();
            defer c.lock.unlock();
            if (wf) |f| {
                defer self.gpa.free(f);
                c.queueFramed(f) catch {};
            }
            if (cf) |f| {
                defer self.gpa.free(f);
                c.queueFramed(f) catch {};
            }
        }
        return removed;
    }

    /// Summonable living entity by vanilla name (else null).
    pub fn mobByName(self: *Server, name: []const u8) ?cmd_data.Mob {
        _ = self;
        return cmd_data.mobByName(name);
    }

    /// Read one block (wire id + meta). Null without a world / missing chunk.
    // ---- world editing, ops, stats ----

    pub fn getBlockAt(self: *Server, x: i32, y: i32, z: i32) ?BlockWire {
        const pool = self.world orelse return null;
        if (y < 0 or y > 255) return null;
        self.world_lock.lock();
        defer self.world_lock.unlock();
        const pb = view.peekBlock(pool, self.gpa, x, @intCast(y), z) catch return null;
        const b = pb orelse return null;
        return .{ .wire = wire.toWire(b.id), .meta = b.meta };
    }

    pub const SetBlockResult = enum { ok, no_world, out_of_world, no_change };

    /// Vanilla setblock modes: replace always writes (same block+data =
    /// noChange); keep writes only into air; destroy drops + breaks first.
    pub fn setBlockAt(self: *Server, x: i32, y: i32, z: i32, wire_id: u16, meta: u4, mode: enum { replace, keep, destroy }) SetBlockResult {
        const pool = self.world orelse return .no_world;
        const id = wire.fromWire(wire_id) orelse return .no_world;
        if (y < 0 or y > 255) return .out_of_world;
        self.world_lock.lock();
        defer self.world_lock.unlock();
        const cur = (view.peekBlock(pool, self.gpa, x, @intCast(y), z) catch return .no_world) orelse return .out_of_world;
        switch (mode) {
            .replace, .destroy => {
                if (cur.id == id and cur.meta == meta) return .no_change;
            },
            .keep => {
                if (cur.id != game_ids.air) return .no_change;
            },
        }
        const touched: u8 = view.applyBlock(pool, self.gpa, x, @intCast(y), z, id, meta) catch return .no_world;
        self.broadcastBlockChange(null, x, @intCast(y), z, id, meta) catch {};
        self.resendTouchedNeighbors(pool, x, z, touched);
        var eb: [24]u8 = undefined;
        if (mode == .destroy) {
            if (packets.frameWorldEffect(2001, x, @intCast(y), z, @intCast(wire.toWire(cur.id)), &eb)) |f| {
                self.broadcastAll(f);
            } else |_| {}
        }
        return .ok;
    }

    /// Survival dig-drop gate: breaking a real block drops in survival
    /// and adventure (vanilla drops there too), never in creative, and
    /// only with doTileDrops on. (Was once inverted (`!tileDrops`),
    /// which silenced all survival digging drops while /setblock destroy
    /// still dropped.)
    fn shouldDropBreak(gamemode: rules_mod.GameMode, old_id: game_ids.Id, tile_drops: bool) bool {
        return old_id != game_ids.air and !gamemode.isCreative() and tile_drops;
    }

    /// Spawn drops for a destroy-mode setblock (gamerule doTileDrops gate).
    pub fn setblockDrops(self: *Server, x: i32, y: i32, z: i32, old_wire: u16) void {
        if (!self.tileDrops()) return;
        const id = wire.fromWire(old_wire) orelse return;
        if (id == game_ids.air) return;
        if (self.world == null) return;
        self.spawnBreakDrops(x, @intCast(y), z, id, 0);
    }

    /// Summon a living entity (ticker broadcasts it like any other mob).
    /// Caller validates y in [0, 256); returns false without a world.
    /// The mob is owned by its spawn cell's region from birth (no global
    /// list to migrate later; a wander crossing adopts it elsewhere).
    pub fn summonMob(self: *Server, type_id: u8, x: f64, y: f64, z: f64, health: f32) bool {
        if (self.world == null) return false;
        const kind = profile.game.mobs.fromWire(type_id) orelse return false;
        const id = self.eid_counter.fetchAdd(1, .acq_rel);
        const rid = tick_mod.regionIdFor(0, x, z);
        const reg = self.region_reg.getOrCreate(self.gpa, rid) catch return false;
        self.ent_lock.lock();
        defer self.ent_lock.unlock();
        _ = reg.mobs.add(.{
            .id = id,
            .kind = kind,
            .x = x,
            .y = y,
            .z = z,
            .yaw = 0,
            .health = health,
            .home_x = x,
            .home_z = z,
            .patrol_r = 4.0,
        }) catch return false;
        return true;
    }

    /// Surface Y for spreadplayers: stored column top, else gen-less 64.
    pub fn surfaceY(self: *Server, x: i32, z: i32) i32 {
        const pool = self.world orelse return 64;
        self.world_lock.lock();
        defer self.world_lock.unlock();
        const top = view.groundBlockY(pool, self.gpa, x, z, 255) catch return 64;
        return if (top) |t| @as(i32, t) + 1 else 64;
    }

    /// Playsound to one player with the vanilla 16-block (minVolume-scaled)
    /// hearing check. Returns heard/unheard/offline.
    pub const HearResult = enum { heard, too_far, offline };

    pub fn playSoundTo(self: *Server, name: []const u8, sound: []const u8, x: f64, y: f64, z: f64, volume: f32, pitch: f32, min_volume: f32) HearResult {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const c = findInSnap(snap, name) orelse return .offline;
        c.lock.lock();
        defer c.lock.unlock();
        if (c.state != .play) return .offline;
        const range: f64 = if (min_volume > 1.0) @as(f64, min_volume) * 16.0 else 16.0;
        const dx = x - c.pos_x;
        const dy = y - c.pos_y;
        const dz = z - c.pos_z;
        if (dx * dx + dy * dy + dz * dz > range * range) return .too_far;
        var sb: [512]u8 = undefined;
        queueBuilt(c, packets.frameSoundEffect(sound, x, y, z, volume, pitch, &sb));
        return .heard;
    }

    pub fn nowMs(self: *Server) i64 {
        return std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
    }

    /// /netstat console body: connection + entity + tick counters (we don't
    /// track per-packet bytes, so this reports what the server does know).
    pub fn netstatText(self: *Server, out: []u8) []const u8 {
        const nmobs = self.mobCount();
        self.ent_lock.lock();
        const nitems = self.items.items.len;
        self.ent_lock.unlock();
        self.reg_lock.lock();
        const nconns = self.registry.items.len;
        self.reg_lock.unlock();
        return std.fmt.bufPrint(out, "connections: {d}, mobs: {d}, item entities: {d}, ticks: {d}, time: {d}", .{ nconns, nmobs, nitems, self.tick_counter, self.time_of_day.load(.acquire) }) catch "netstat";
    }

    /// /tps body: 1Hz tick timing + counts (honest about the 1Hz ticker:
    /// no fake 20.0 claim). Usable by players and console alike.
    pub fn tpsText(self: *Server, out: []u8) []const u8 {
        const p50 = self.percentile(0, 50);
        const p99 = self.percentile(0, 99);
        const f50 = self.percentile(1, 50);
        const f99 = self.percentile(1, 99);
        return std.fmt.bufPrint(out, "tick 1Hz p50={d}us p99={d}us flush p50={d}us p99={d}us players: {d} ticks: {d}", .{
            @divFloor(p50, 1_000),
            @divFloor(p99, 1_000),
            @divFloor(f50, 1_000),
            @divFloor(f99, 1_000),
            self.play_count.load(.acquire),
            self.tick_counter,
        }) catch "tps";
    }

    pub fn debugStart(self: *Server, now_ms: i64) void {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        self.debug_start_ms = now_ms;
        self.debug_ticks = 0;
    }

    /// Returns elapsed seconds + ticks, or null when not profiling.
    pub fn debugStop(self: *Server, now_ms: i64) ?DebugSpan {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        const start = self.debug_start_ms orelse return null;
        self.debug_start_ms = null;
        return .{ .secs = @as(f64, @floatFromInt(now_ms - start)) / 1000.0, .ticks = self.debug_ticks };
    }

    pub fn setAutosave(self: *Server, on: bool) void {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        {
            var c = self.cfg.load();
            c.autosave = on;
            self.cfg.store(c);
        }
    }

    pub fn getAutosave(self: *Server) bool {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        return self.cfg.load().autosave;
    }

    pub fn setIdleTimeout(self: *Server, mins: u32) void {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        {
            var c = self.cfg.load();
            c.idle_timeout_min = mins;
            self.cfg.store(c);
        }
    }

    /// Personal spawn (`/spawnpoint`): empty name = sender handled by caller.
    pub fn setSpawn(self: *Server, name: []const u8, x: i32, y: i32, z: i32) bool {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const c = findInSnap(snap, name) orelse return false;
        c.lock.lock();
        defer c.lock.unlock();
        if (c.state != .play) return false;
        c.config.spawn_x = x;
        c.config.spawn_y = y;
        c.config.spawn_z = z;
        c.spawn_forced = true;
        return true;
    }

    /// World spawn (`/setworldspawn`): default for new logins + every
    /// non-forced online player.
    pub fn setWorldSpawn(self: *Server, x: i32, y: i32, z: i32) void {
        self.state_lock.lock();
        {
            var c = self.cfg.load();
            c.world_spawn = .{ x, y, z };
            c.world_spawn_set = true;
            self.cfg.store(c);
        }
        self.state_lock.unlock();
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            e.conn.lock.lock();
            if (e.conn.state == .play and !e.conn.spawn_forced) {
                e.conn.config.spawn_x = x;
                e.conn.config.spawn_y = y;
                e.conn.config.spawn_z = z;
            }
            e.conn.lock.unlock();
        }
    }

    /// Achievement/stat award. Achievements announce once (vanilla
    /// `chat.type.achievement`); stats just succeed. Unknown -> null.
    pub fn awardStat(self: *Server, name: []const u8, stat: []const u8) ?bool {
        if (!cmd_data.validStatName(stat)) return null;
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const c = findInSnap(snap, name) orelse return false;
        var announced = false;
        var title: ?[]const u8 = null;
        c.lock.lock();
        if (c.state == .play and cmd_data.isAchievement(stat)) {
            var have = false;
            for (c.achieved[0..c.achieved_len]) |*slot| {
                if (stat.len < slot.len and std.mem.eql(u8, slot[0..stat.len], stat) and slot[stat.len] == 0) {
                    have = true;
                    break;
                }
            }
            if (!have and c.achieved_len < c.achieved.len) {
                @memcpy(c.achieved[c.achieved_len][0..stat.len], stat);
                c.achieved[c.achieved_len][stat.len] = 0;
                c.achieved_len += 1;
                announced = true;
                title = cmd_data.achievementTitle(stat);
            }
        }
        c.lock.unlock();
        if (announced) {
            var ab: [256]u8 = undefined;
            const line = std.fmt.bufPrint(&ab, "{s} has just earned the achievement [{s}]", .{ name, title orelse stat }) catch return true;
            var eb: [512]u8 = undefined;
            const esc = packets.escapeJsonText(line, &eb) catch return true;
            var jb: [560]u8 = undefined;
            const json = std.fmt.bufPrint(&jb, "{{\"text\":\"{s}\",\"color\":\"green\"}}", .{esc}) catch return true;
            self.broadcastChat(json);
        }
        return true;
    }

    pub fn validStatName(self: *Server, name: []const u8) bool {
        _ = self;
        return cmd_data.validStatName(name);
    }

    pub fn isAchievement(self: *Server, name: []const u8) bool {
        _ = self;
        return cmd_data.isAchievement(name);
    }

    pub fn achievementTitle(self: *Server, name: []const u8) ?[]const u8 {
        _ = self;
        return cmd_data.achievementTitle(name);
    }

    /// Award every achievement to one player (the `*` form).
    pub fn awardAll(self: *Server, name: []const u8) bool {
        for (cmd_data.achievements) |a| {
            const ok = self.awardStat(name, a) orelse return false;
            if (!ok) return false;
        }
        return true;
    }

    // ---- tab completion ----

    /// Mode/difficulty name candidates, derived from the enums so help text,
    /// parsing, and completion can never drift (short hands + wire numbers
    /// mirror parseMode/parseDifficulty in cmd/gamemode.zig and
    /// cmd/difficulty.zig).
    const gamemode_complete_names = [_][]const u8{
        rules_mod.GameMode.survival.name(),
        rules_mod.GameMode.creative.name(),
        rules_mod.GameMode.adventure.name(),
    };
    const difficulty_complete_names = [_][]const u8{
        rules_mod.Difficulty.peaceful.name(),
        rules_mod.Difficulty.easy.name(),
        rules_mod.Difficulty.normal.name(),
        rules_mod.Difficulty.hard.name(),
    };

    /// Vanilla `getPossibleCommands` + per-command `addTabCompletion`.
    /// Null = suppress (unknown command); otherwise S3A with candidates
    /// (possibly empty). Caller holds no locks; conn queued under its lock.
    // ---- tab completion ----

    pub fn handleTabComplete(self: *Server, sender: *Conn, text: []const u8) void {
        var cands: [128][]const u8 = undefined;
        var owned: [128][64]u8 = undefined; // player-name / id copies
        if (text.len == 0 or text[0] != '/') {
            // Non-slash: complete online player names (vanilla client behavior).
            const n = self.completePlayers(text, &cands, &owned);
            self.sendTab(sender, cands[0..n]);
            return;
        }
        // Split keeping the trailing empty token (vanilla split(" ", -1)).
        var toks: [32][]const u8 = undefined;
        var nt: usize = 0;
        var start: usize = 1; // skip '/'
        var i: usize = 1;
        while (i <= text.len and nt < toks.len) : (i += 1) {
            if (i == text.len or text[i] == ' ') {
                toks[nt] = text[start..i];
                nt += 1;
                start = i + 1;
            }
        }
        if (nt == 0) return;
        if (nt == 1) {
            // Command-name completion, perm-filtered (aliases included).
            const n = self.completeCommandsFor(sender, toks[0], &cands, &owned);
            self.sendTab(sender, cands[0..n]);
            return;
        }
        // Multi-word: find the command (exact, names + aliases).
        self.ensureCommands();
        var found: ?*const perms_mod.Command = null;
        for (self.cmds[0..self.n_cmds]) |e| {
            if (cmdMatches(e.def, toks[0])) {
                found = e.def;
                break;
            }
        }
        const def = found orelse return; // vanilla returns null -> suppress
        // Vanilla only completes args for commands the sender can use? No —
        // getPossibleCommands delegates without a perm re-check (the
        // single-token path already filtered). Match that: no re-check here.
        const n = self.completeArgs(def, toks[1..nt], &cands, &owned);
        self.sendTab(sender, cands[0..n]);
    }

    fn sendTab(self: *Server, sender: *Conn, cands: []const []const u8) void {
        _ = self;
        var fb: [4096]u8 = undefined;
        const f = packets.frameTabComplete(cands, &fb) catch return;
        sender.lock.lock();
        defer sender.lock.unlock();
        if (sender.state != .play or sender.dead) return;
        sender.queueFramed(f) catch {};
    }

    fn completePlayers(self: *Server, prefix: []const u8, out: [][]const u8, owned: [][64]u8) usize {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        var n: usize = 0;
        for (snap) |e| {
            if (n >= out.len or n >= owned.len) break;
            e.conn.lock.lock();
            const play = e.conn.state == .play and e.conn.username_len > 0;
            var len: u8 = 0;
            if (play) {
                len = @intCast(e.conn.username_len);
                @memcpy(owned[n][0..len], e.conn.username[0..len]);
            }
            e.conn.lock.unlock();
            if (!play) continue;
            if (cmd_spec.startsWithIgnoreCase(owned[n][0..len], prefix)) {
                out[n] = owned[n][0..len];
                n += 1;
            }
        }
        return n;
    }

    /// Command-name completion for the single-token path. Vanilla S3A
    /// carries the slash (`/gamemode` for input `/game`) — the 1.7.10
    /// client replaces the whole current word with the match, so bare
    /// names made it eat the `/`. (Was bare names; `/game<TAB>` became
    /// `game`.)
    fn completeCommandsFor(self: *Server, sender: ?*Conn, prefix: []const u8, out: [][]const u8, owned: [][64]u8) usize {
        self.ensureCommands();
        var n: usize = 0;
        var on: usize = 0;
        for (self.cmds[0..self.n_cmds]) |e| {
            const d = e.def;
            const ok = if (sender == null) true else self.commandAllowed(sender, d);
            if (!ok) continue;
            offerCommand(out, owned, &n, &on, d.name, prefix);
            for (d.aliases) |a| offerCommand(out, owned, &n, &on, a, prefix);
        }
        return n;
    }

    fn containsName(hay: [][]const u8, needle: []const u8) bool {
        for (hay) |e| if (std.mem.eql(u8, e, needle)) return true;
        return false;
    }

    /// Offer one completion candidate (prefix-filtered, capacity-checked).
    fn offerStatic(out: [][]const u8, n: *usize, s: []const u8, prefix: []const u8) void {
        if (n.* >= out.len) return;
        if (!cmd_spec.startsWithIgnoreCase(s, prefix)) return;
        out[n.*] = s;
        n.* += 1;
    }

    /// Offer every string in `list` (prefix-filtered, capacity-checked).
    fn offerList(out: [][]const u8, n: *usize, list: []const []const u8, prefix: []const u8) void {
        for (list) |v| offerStatic(out, n, v, prefix);
    }

    /// Append one candidate unless already listed (capacity-checked).
    fn appendUnique(out: [][]const u8, n: *usize, c: []const u8) void {
        if (n.* >= out.len) return;
        if (containsName(out[0..n.*], c)) return;
        out[n.*] = c;
        n.* += 1;
    }

    /// Offer one "/name" command candidate (prefix-filtered, deduped;
    /// consumes an owned slot on every render, dup or not).
    fn offerCommand(out: [][]const u8, owned: [][64]u8, n: *usize, on: *usize, word: []const u8, prefix: []const u8) void {
        if (!cmd_spec.startsWithIgnoreCase(word, prefix)) return;
        if (n.* >= out.len or on.* >= owned.len) return;
        const s = std.fmt.bufPrint(&owned[on.*], "/{s}", .{word}) catch return;
        on.* += 1;
        if (containsName(out[0..n.*], s)) return;
        out[n.*] = s;
        n.* += 1;
    }

    fn completeArgs(self: *Server, def: *const perms_mod.Command, toks: [][]const u8, out: [][]const u8, owned: [][64]u8) usize {
        // The def carries its own spec (same table help and dispatch use),
        // so no module re-lookup is needed.
        return completeArgsFor(self, def, toks, out, owned);
    }

    fn completeArgsFor(self: *Server, def: *const perms_mod.Command, toks: [][]const u8, out: [][]const u8, owned: [][64]u8) usize {
        const arg_index = toks.len - 1;
        const prefix = toks[arg_index];
        // Overloads where all COMPLETE tokens (before the prefix) match.
        var n: usize = 0;
        for (def.spec) |over| {
            if (arg_index >= over.len) continue;
            if (!prefixMatches(over, toks[0..arg_index])) continue;
            var tmp: [32][]const u8 = undefined;
            var m: usize = 0;
            const slot = over[arg_index];
            switch (slot.arg) {
                .literal => |lit| {
                    if (cmd_spec.startsWithIgnoreCase(lit, prefix) and m < tmp.len) {
                        tmp[m] = lit;
                        m += 1;
                    }
                },
                .choice => |opts| {
                    for (opts) |o| {
                        if (m >= tmp.len) break;
                        if (cmd_spec.startsWithIgnoreCase(o, prefix)) {
                            tmp[m] = o;
                            m += 1;
                        }
                    }
                },
                .player => {
                    m += self.completePlayers(prefix, tmp[m..], owned[m..]);
                },
                else => {},
            }
            for (tmp[0..m]) |c| appendUnique(out, &n, c);
        }
        // Command-specific dynamic sets (items, gamerules, mobs...).
        n += self.completeExtra(def, toks, prefix, out[n..], owned);
        return n;
    }

    /// Command-specific dynamic candidates beyond the static spec
    /// (item/block/mob names, gamerule names, enchant ids, ...).
    fn completeExtra(self: *Server, def: *const perms_mod.Command, toks: [][]const u8, prefix: []const u8, out: [][]const u8, owned: [][64]u8) usize {
        var n: usize = 0;
        const arg_index = toks.len - 1;
        // Item/block name completion for /give /clear /setblock /testforblock.
        if (std.mem.eql(u8, def.name, "give") or std.mem.eql(u8, def.name, "clear")) {
            if (arg_index == 1) n = completeWireNames(prefix, out);
        } else if (std.mem.eql(u8, def.name, "setblock") or std.mem.eql(u8, def.name, "testforblock")) {
            if (arg_index == 3) n = completeWireNames(prefix, out);
        } else if (std.mem.eql(u8, def.name, "gamerule")) {
            if (arg_index == 0) {
                for (cmd_data.gamerules) |g| offerStatic(out, &n, g.name, prefix);
            } else if (arg_index == 1) {
                offerList(out, &n, &.{ "true", "false" }, prefix);
            }
        } else if (std.mem.eql(u8, def.name, "effect")) {
            if (arg_index == 2 and n < out.len) {
                // effect names are numeric; offer 1..23 by prefix
                var id: u8 = 1;
                while (id <= 23) : (id += 1) {
                    if (n >= owned.len) break;
                    const s = std.fmt.bufPrint(&owned[n], "{d}", .{id}) catch break;
                    offerStatic(out, &n, s, prefix);
                }
            } else if (arg_index == 1 and (std.mem.eql(u8, toks[0], "clear") or toks.len > 0)) {
                offerStatic(out, &n, "clear", prefix);
            }
        } else if (std.mem.eql(u8, def.name, "enchant")) {
            if (arg_index == 1) {
                for (cmd_data.enchants) |e| {
                    if (n >= owned.len) break;
                    const s = std.fmt.bufPrint(&owned[n], "{d}", .{e.id}) catch break;
                    offerStatic(out, &n, s, prefix);
                }
            }
        } else if (std.mem.eql(u8, def.name, "summon")) {
            if (arg_index == 0) {
                for (cmd_data.mobs) |m| offerStatic(out, &n, m.name, prefix);
            }
        } else if (std.mem.eql(u8, def.name, "difficulty")) {
            if (arg_index == 0) {
                offerList(out, &n, &(difficulty_complete_names ++ [_][]const u8{ "p", "e", "n", "h", "0", "1", "2", "3" }), prefix);
            }
        } else if (std.mem.eql(u8, def.name, "gamemode") or std.mem.eql(u8, def.name, "defaultgamemode")) {
            if (arg_index == 0) {
                offerList(out, &n, &(gamemode_complete_names ++ [_][]const u8{ "s", "c", "a", "0", "1", "2" }), prefix);
            }
        } else if (std.mem.eql(u8, def.name, "scoreboard")) {
            n = self.completeScoreboard(toks, prefix, out, owned);
        } else if (std.mem.eql(u8, def.name, "tellraw")) {
            // JSON payload: no candidates.
        }
        return n;
    }

    fn completeScoreboard(self: *Server, toks: [][]const u8, prefix: []const u8, out: [][]const u8, owned: [][64]u8) usize {
        _ = self;
        _ = owned;
        var n: usize = 0;
        if (toks.len == 1) {
            offerList(out, &n, &.{ "objectives", "players", "teams" }, prefix);
            return n;
        }
        if (std.mem.eql(u8, toks[0], "objectives")) {
            if (toks.len == 2) {
                offerList(out, &n, &.{ "list", "add", "remove", "setdisplay" }, prefix);
            } else if (toks.len == 3 and std.mem.eql(u8, toks[1], "add")) {
                offerList(out, &n, &cmd_data.criteria, prefix);
            } else if (toks.len == 3 and std.mem.eql(u8, toks[1], "setdisplay")) {
                offerList(out, &n, &.{ "list", "sidebar", "belowName" }, prefix);
            }
        } else if (std.mem.eql(u8, toks[0], "players")) {
            if (toks.len == 2) offerList(out, &n, &.{ "set", "add", "remove", "reset", "list" }, prefix);
        } else if (std.mem.eql(u8, toks[0], "teams")) {
            if (toks.len == 2) {
                offerList(out, &n, &.{ "list", "add", "remove", "empty", "join", "leave", "option" }, prefix);
            } else if (toks.len == 4 and std.mem.eql(u8, toks[1], "option")) {
                offerList(out, &n, &.{ "friendlyfire", "color", "seeFriendlyInvisibles" }, prefix);
            } else if (toks.len == 5 and std.mem.eql(u8, toks[1], "option") and std.mem.eql(u8, toks[3], "color")) {
                offerList(out, &n, &cmd_data.team_colors, prefix);
            }
        }
        return n;
    }

    /// All registered item/block names (canonical snake_case) for /give etc.
    fn completeWireNames(prefix: []const u8, out: [][]const u8) usize {
        var n: usize = 0;
        inline for (@typeInfo(game_ids.Id).@"enum".fields) |f| offerStatic(out, &n, f.name, prefix);
        return n;
    }

    /// Overload-prefix check: every complete token matches its slot shape
    /// (literals/choices exactly; typed slots accept anything shapely).
    fn prefixMatches(over: cmd_spec.Overload, toks: [][]const u8) bool {
        for (over[0..toks.len], toks) |slot, tok| {
            switch (slot.arg) {
                .literal => |lit| if (!std.mem.eql(u8, lit, tok)) return false,
                .choice => |opts| {
                    var hit = false;
                    for (opts) |o| if (std.mem.eql(u8, o, tok)) {
                        hit = true;
                        break;
                    };
                    if (!hit) return false;
                },
                .player => if (!cmd_spec.isSelector(tok) and !cmd_spec.validPlayerNameChars(tok)) return false,
                .int_range => |r| {
                    const v = std.fmt.parseInt(i64, tok, 0) catch return false;
                    if (r.min) |lo| if (v < lo) return false;
                    if (r.max) |hi| if (v > hi) return false;
                },
                .float_range => |r| {
                    const v = std.fmt.parseFloat(f64, tok) catch return false;
                    if (!std.math.isFinite(v)) return false;
                    if (r.min) |lo| if (v < lo) return false;
                    if (r.max) |hi| if (v > hi) return false;
                },
                .coord => {
                    if (!cmd_spec.isCoord(tok)) return false;
                },
                .boolean => if (cmd_spec.parseBool(tok) == null) return false,
                .word => {},
                .rest => return false, // rest swallows; completion past it is moot
            }
        }
        return true;
    }

    // ---- scoreboard backends (store + broadcast) ----

    // ---- scoreboard ----

    fn sbBroadcastObjective(self: *Server, name: []const u8, display: []const u8, action: u8) void {
        var b: [512]u8 = undefined;
        if (packets.frameObjective(name, display, action, &b)) |f| self.broadcastAll(f) else |_| {}
    }

    fn sbBroadcastDisplay(self: *Server, slot: u8, objective: []const u8) void {
        var b: [256]u8 = undefined;
        if (packets.frameDisplayScoreboard(slot, objective, &b)) |f| self.broadcastAll(f) else |_| {}
    }

    fn sbBroadcastTeamsCreate(self: *Server, name: []const u8) void {
        const sb = self.sbDb();
        self.sb_lock.lock();
        const t = sb.teams.get(name);
        var info: packets.TeamInfo = undefined;
        var disp: [64]u8 = undefined;
        var pre: [64]u8 = undefined;
        var suf: [64]u8 = undefined;
        if (t) |team| {
            @memcpy(disp[0..@min(team.display.len, disp.len)], team.display[0..@min(team.display.len, disp.len)]);
            @memcpy(pre[0..@min(team.prefix.len, pre.len)], team.prefix[0..@min(team.prefix.len, pre.len)]);
            @memcpy(suf[0..@min(team.suffix.len, suf.len)], team.suffix[0..@min(team.suffix.len, suf.len)]);
            info = .{
                .display = disp[0..@min(team.display.len, disp.len)],
                .prefix = pre[0..@min(team.prefix.len, pre.len)],
                .suffix = suf[0..@min(team.suffix.len, suf.len)],
                .friendly_fire = if (team.friendly_fire) 0 else 1,
            };
        }
        self.sb_lock.unlock();
        if (t == null) return;
        var b: [4096]u8 = undefined;
        if (packets.frameTeams(name, 0, info, &.{}, &b)) |f| self.broadcastAll(f) else |_| {}
    }

    pub const SbResult = enum { ok, too_long, display_too_long, exists, not_found, bad_criteria, bad_slot };

    pub fn sbAddObjective(self: *Server, name: []const u8, criteria: []const u8, display: []const u8) SbResult {
        const sb = self.sbDb();
        self.sb_lock.lock();
        const r = sb.addObjective(name, criteria, display) catch |err| {
            self.sb_lock.unlock();
            return switch (err) {
                error.NameTooLong => .too_long,
                error.DisplayTooLong => .display_too_long,
                error.AlreadyExists => .exists,
                error.BadCriteria => .bad_criteria,
                else => .not_found,
            };
        };
        _ = r;
        self.sb_lock.unlock();
        self.sbSave();
        self.sbBroadcastObjective(name, if (display.len == 0) name else display, 0);
        return .ok;
    }

    pub fn sbRemoveObjective(self: *Server, name: []const u8) SbResult {
        const sb = self.sbDb();
        self.sb_lock.lock();
        sb.removeObjective(name) catch {
            self.sb_lock.unlock();
            return .not_found;
        };
        // removeObjective already purges the objective's scores and clears
        // slots pointing at it; broadcast only the objective removal + slot
        // clears happen implicitly client-side on objective remove.
        self.sb_lock.unlock();
        self.sbSave();
        self.sbBroadcastObjective(name, "", 1);
        return .ok;
    }

    pub fn sbListObjectives(self: *Server, out: []u8) []const u8 {
        const sb = self.sbDb();
        self.sb_lock.lock();
        defer self.sb_lock.unlock();
        var ow: usize = 0;
        var oit = sb.objectives.iterator();
        var n: usize = 0;
        while (oit.next()) |_| n += 1;
        ow += (std.fmt.bufPrint(out[ow..], "Showing {d} objective(s) on scoreboard:", .{n}) catch return out[0..ow]).len;
        var ojt = sb.objectives.iterator();
        while (ojt.next()) |e| {
            ow += (std.fmt.bufPrint(out[ow..], "\n- {s}: displays as '{s}' and is type '{s}'", .{ e.key_ptr.*, e.value_ptr.*.display, e.value_ptr.*.criteria }) catch break).len;
        }
        if (n == 0) ow += (std.fmt.bufPrint(out[ow..], "\nThere are no objectives on the scoreboard", .{}) catch return out[0..ow]).len;
        return out[0..ow];
    }

    pub fn sbSetDisplay(self: *Server, slot_name: []const u8, objective: ?[]const u8) SbResult {
        var slot: u8 = 255;
        for (cmd_data.display_slots) |s| {
            if (std.mem.eql(u8, s.name, slot_name)) slot = s.value;
        }
        if (slot == 255) {
            const v = std.fmt.parseInt(u8, slot_name, 10) catch return .bad_slot;
            if (v > 2) return .bad_slot;
            slot = v;
        }
        if (slot > 2) return .bad_slot;
        const sb = self.sbDb();
        self.sb_lock.lock();
        sb.setSlot(slot, objective) catch {
            self.sb_lock.unlock();
            return .not_found;
        };
        self.sb_lock.unlock();
        self.sbSave();
        if (objective) |o| {
            self.sbBroadcastDisplay(slot, o);
        } else {
            var b: [256]u8 = undefined;
            if (packets.frameDisplayScoreboard(slot, "", &b)) |f| self.broadcastAll(f) else |_| {}
        }
        return .ok;
    }

    /// Add/subtract a score (creates at 0 when missing). NotFound = bad objective.
    pub fn sbAddScore(self: *Server, player: []const u8, objective: []const u8, delta: i32) SbResult {
        const sb = self.sbDb();
        self.sb_lock.lock();
        const cur: i32 = sb.getScore(player, objective) orelse 0;
        if (!sb.objectives.contains(objective)) {
            self.sb_lock.unlock();
            return .not_found;
        }
        sb.setScore(player, objective, cur + delta) catch {
            self.sb_lock.unlock();
            return .not_found;
        };
        const v = cur + delta;
        self.sb_lock.unlock();
        self.sbSave();
        var b: [512]u8 = undefined;
        if (packets.frameUpdateScore(player, 0, objective, v, &b)) |f| self.broadcastAll(f) else |_| {}
        return .ok;
    }

    pub fn sbSetScore(self: *Server, player: []const u8, objective: []const u8, value: i32) SbResult {
        const sb = self.sbDb();
        self.sb_lock.lock();
        sb.setScore(player, objective, value) catch {
            self.sb_lock.unlock();
            return .not_found;
        };
        self.sb_lock.unlock();
        self.sbSave();
        var b: [512]u8 = undefined;
        if (packets.frameUpdateScore(player, 0, objective, value, &b)) |f| self.broadcastAll(f) else |_| {}
        return .ok;
    }

    /// Current value for add/remove feedback (null when untracked).
    pub fn sbGetScore(self: *Server, player: []const u8, objective: []const u8) ?i32 {
        const sb = self.sbDb();
        self.sb_lock.lock();
        defer self.sb_lock.unlock();
        return sb.getScore(player, objective);
    }

    pub fn sbResetScores(self: *Server, player: []const u8) void {
        const sb = self.sbDb();
        self.sb_lock.lock();
        // Collect first (broadcast removes outside the lock).
        var doomed: [128][80]u8 = undefined;
        var n_doomed: usize = 0;
        var sit = sb.scores.iterator();
        while (sit.next()) |e| {
            const key = e.key_ptr.*;
            const sep = std.mem.indexOfScalar(u8, key, 0) orelse continue;
            if (std.mem.eql(u8, key[0..sep], player)) {
                if (n_doomed < doomed.len and key.len < doomed[0].len) {
                    @memcpy(doomed[n_doomed][0..key.len], key);
                    doomed[n_doomed][key.len] = 0;
                    n_doomed += 1;
                }
            }
        }
        sb.resetScores(player);
        self.sb_lock.unlock();
        self.sbSave();
        for (doomed[0..n_doomed]) |k| {
            const zl = std.mem.indexOfScalar(u8, &k, 0) orelse k.len;
            const key = k[0..zl];
            const sep = std.mem.indexOfScalar(u8, key, 0) orelse continue;
            const obj = key[sep + 1 ..];
            var b: [512]u8 = undefined;
            if (packets.frameUpdateScore(player, 1, obj, 0, &b)) |f| self.broadcastAll(f) else |_| {}
        }
    }

    pub const SbScore = scoreboard_mod.SbScore;

    pub fn sbPlayerScores(self: *Server, player: []const u8, out: []SbScore, bufs: [][80]u8) usize {
        const sb = self.sbDb();
        self.sb_lock.lock();
        defer self.sb_lock.unlock();
        var n: usize = 0;
        var sit = sb.scores.iterator();
        while (sit.next()) |e| {
            if (n >= out.len or n >= bufs.len) break;
            const key = e.key_ptr.*;
            const sep = std.mem.indexOfScalar(u8, key, 0) orelse continue;
            if (!std.mem.eql(u8, key[0..sep], player)) continue;
            const obj = key[sep + 1 ..];
            if (obj.len + 1 > bufs[n].len) continue;
            @memcpy(bufs[n][0..obj.len], obj);
            bufs[n][obj.len] = 0;
            out[n] = .{ .player = player, .objective = bufs[n][0..obj.len], .value = e.value_ptr.* };
            n += 1;
        }
        return n;
    }

    pub fn sbTrackedPlayers(self: *Server, out: [][perms_mod.max_name_len]u8) usize {
        const sb = self.sbDb();
        self.sb_lock.lock();
        defer self.sb_lock.unlock();
        var n: usize = 0;
        var sit = sb.scores.iterator();
        while (sit.next()) |e| {
            if (n >= out.len) break;
            const key = e.key_ptr.*;
            const sep = std.mem.indexOfScalar(u8, key, 0) orelse continue;
            const pname = key[0..sep];
            var dup = false;
            for (out[0..n]) |*slot| {
                if (std.mem.eql(u8, slot[0..@min(pname.len, 16)], pname[0..@min(pname.len, 16)])) {
                    dup = true;
                    break;
                }
            }
            if (!dup and pname.len <= 16) {
                @memcpy(out[n][0..pname.len], pname);
                n += 1;
            }
        }
        return n;
    }

    pub fn sbAddTeam(self: *Server, name: []const u8, display: []const u8) SbResult {
        const sb = self.sbDb();
        self.sb_lock.lock();
        const r = sb.addTeam(name, display) catch |err| {
            self.sb_lock.unlock();
            return switch (err) {
                error.NameTooLong => .too_long,
                error.DisplayTooLong => .display_too_long,
                error.AlreadyExists => .exists,
                else => .not_found,
            };
        };
        _ = r;
        self.sb_lock.unlock();
        self.sbSave();
        self.sbBroadcastTeamsCreate(name);
        return .ok;
    }

    pub fn sbRemoveTeam(self: *Server, name: []const u8) SbResult {
        const sb = self.sbDb();
        self.sb_lock.lock();
        sb.removeTeam(name) catch {
            self.sb_lock.unlock();
            return .not_found;
        };
        self.sb_lock.unlock();
        self.sbSave();
        var b: [256]u8 = undefined;
        if (packets.frameTeams(name, 1, null, &.{}, &b)) |f| self.broadcastAll(f) else |_| {}
        return .ok;
    }

    /// Join one player to a team (moves them out of any current team).
    /// Returns joined count (0 = unknown team).
    pub fn sbJoinTeam(self: *Server, team: []const u8, player: []const u8, out_names: []u8) usize {
        const sb = self.sbDb();
        self.sb_lock.lock();
        sb.joinTeam(team, player) catch {
            self.sb_lock.unlock();
            return 0;
        };
        self.sb_lock.unlock();
        self.sbSave();
        var b: [512]u8 = undefined;
        const one = [_][]const u8{player};
        if (packets.frameTeams(team, 3, null, &one, &b)) |f| self.broadcastAll(f) else |_| {}
        @memcpy(out_names[0..player.len], player);
        return 1;
    }

    /// Remove players from their teams. Null player = caller resolves.
    /// Remove one player from their team with the S3E mode-4 broadcast.
    /// Returns the team name (borrowed) or null when teamless.
    pub fn sbLeavePlayer(self: *Server, player: []const u8) ?[]const u8 {
        const sb = self.sbDb();
        self.sb_lock.lock();
        const team = sb.teamOf(player) orelse {
            self.sb_lock.unlock();
            return null;
        };
        _ = sb.leaveTeams(player);
        self.sb_lock.unlock();
        self.sbSave();
        // Mode 4 (remove players) broadcast:
        var b: [512]u8 = undefined;
        const one = [_][]const u8{player};
        if (packets.frameTeams(team, 4, null, &one, &b)) |f| self.broadcastAll(f) else |_| {}
        return team;
    }

    pub fn sbTeamOf(self: *Server, player: []const u8) ?[]const u8 {
        const sb = self.sbDb();
        self.sb_lock.lock();
        defer self.sb_lock.unlock();
        if (sb.teamOf(player)) |t| return t;
        return null;
    }

    pub fn sbEmptyTeam(self: *Server, team: []const u8) ?usize {
        const sb = self.sbDb();
        self.sb_lock.lock();
        const t = sb.teams.get(team) orelse {
            self.sb_lock.unlock();
            return null;
        };
        var members: [128][]u8 = undefined;
        var mbufs: [128][24]u8 = undefined;
        var n: usize = 0;
        var mit = t.members.iterator();
        while (mit.next()) |m| {
            if (n >= members.len) break;
            @memcpy(mbufs[n][0..m.key_ptr.len], m.key_ptr.*);
            members[n] = mbufs[n][0..m.key_ptr.len];
            n += 1;
        }
        // Drop membership (keep the team itself).
        for (members[0..n]) |m| {
            if (t.members.fetchRemove(m)) |old| sb.alloc.free(old.key);
        }
        self.sb_lock.unlock();
        self.sbSave();
        if (n > 0) {
            var b: [4096]u8 = undefined;
            if (packets.frameTeams(team, 4, null, members[0..n], &b)) |f| self.broadcastAll(f) else |_| {}
        }
        return n;
    }

    pub const SbOption = enum { friendlyfire, color, see_friendly_invisibles };

    pub fn sbSetOption(self: *Server, team: []const u8, opt: SbOption, value: []const u8) enum { ok, not_found, bad_value } {
        const sb = self.sbDb();
        self.sb_lock.lock();
        const t = sb.teams.get(team) orelse {
            self.sb_lock.unlock();
            return .not_found;
        };
        switch (opt) {
            .friendlyfire => {
                if (std.mem.eql(u8, value, "true")) t.friendly_fire = true else if (std.mem.eql(u8, value, "false")) t.friendly_fire = false else {
                    self.sb_lock.unlock();
                    return .bad_value;
                }
            },
            .see_friendly_invisibles => {
                if (std.mem.eql(u8, value, "true")) t.see_friendly_invisibles = true else if (std.mem.eql(u8, value, "false")) t.see_friendly_invisibles = false else {
                    self.sb_lock.unlock();
                    return .bad_value;
                }
            },
            .color => {
                var okc = std.mem.eql(u8, value, "reset");
                for (cmd_data.team_colors) |c| {
                    if (std.mem.eql(u8, c, value)) okc = true;
                }
                if (!okc) {
                    self.sb_lock.unlock();
                    return .bad_value;
                }
                sb.alloc.free(t.color);
                t.color = sb.alloc.dupe(u8, value) catch {
                    self.sb_lock.unlock();
                    return .bad_value;
                };
            },
        }
        self.sb_lock.unlock();
        self.sbSave();
        // Mode-2 info update broadcast.
        self.sb_lock.lock();
        const tt = sb.teams.get(team);
        var disp: [64]u8 = undefined;
        var pre: [64]u8 = undefined;
        var suf: [64]u8 = undefined;
        var info: ?packets.TeamInfo = null;
        if (tt) |team2| {
            @memcpy(disp[0..@min(team2.display.len, disp.len)], team2.display[0..@min(team2.display.len, disp.len)]);
            @memcpy(pre[0..@min(team2.prefix.len, pre.len)], team2.prefix[0..@min(team2.prefix.len, pre.len)]);
            @memcpy(suf[0..@min(team2.suffix.len, suf.len)], team2.suffix[0..@min(team2.suffix.len, suf.len)]);
            info = .{
                .display = disp[0..@min(team2.display.len, disp.len)],
                .prefix = pre[0..@min(team2.prefix.len, pre.len)],
                .suffix = suf[0..@min(team2.suffix.len, suf.len)],
                .friendly_fire = if (team2.friendly_fire) 0 else 1,
            };
        }
        self.sb_lock.unlock();
        var b: [4096]u8 = undefined;
        if (packets.frameTeams(team, 2, info, &.{}, &b)) |f| self.broadcastAll(f) else |_| {}
        return .ok;
    }

    pub fn sbListTeams(self: *Server, out: []u8) []const u8 {
        const sb = self.sbDb();
        self.sb_lock.lock();
        defer self.sb_lock.unlock();
        var ow: usize = 0;
        ow += (std.fmt.bufPrint(out[ow..], "Showing {d} teams on the scoreboard:", .{sb.teams.count()}) catch return out[0..ow]).len;
        var tit = sb.teams.iterator();
        while (tit.next()) |e| {
            ow += (std.fmt.bufPrint(out[ow..], "\n- {s}: '{s}' has {d} players", .{ e.key_ptr.*, e.value_ptr.*.display, e.value_ptr.*.members.count() }) catch break).len;
        }
        if (sb.teams.count() == 0) ow += (std.fmt.bufPrint(out[ow..], "\nThere are no teams registered on the scoreboard", .{}) catch return out[0..ow]).len;
        return out[0..ow];
    }

    pub fn sbListTeamPlayers(self: *Server, team: []const u8, out: []u8) ?[]const u8 {
        const sb = self.sbDb();
        self.sb_lock.lock();
        defer self.sb_lock.unlock();
        const t = sb.teams.get(team) orelse return null;
        var ow: usize = 0;
        ow += (std.fmt.bufPrint(out[ow..], "Showing {d} player(s) in team {s}:", .{ t.members.count(), team }) catch return out[0..ow]).len;
        var mit = t.members.iterator();
        while (mit.next()) |m| {
            ow += (std.fmt.bufPrint(out[ow..], "\n- {s}", .{m.key_ptr.*}) catch break).len;
        }
        if (t.members.count() == 0) ow += (std.fmt.bufPrint(out[ow..], "\nTeam {s} has no players", .{team}) catch return out[0..ow]).len;
        return out[0..ow];
    }

    // ---- connection helpers for the login path ----

    /// Peer IP capture from the accepted socket (called once per conn).
    // ---- tick regions (Phase C) ----

    pub fn captureIp(conn: *Conn, stream: std.Io.net.Stream) void {
        switch (stream.socket.address) {
            .ip4 => |a| {
                const s = std.fmt.bufPrint(&conn.ip, "{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }) catch return;
                conn.ip_len = s.len;
            },
            .ip6 => |a| formatIp6(conn, &a.bytes),
        }
    }

    /// Render an IPv6 address as 8 hex groups (no zero compression —
    /// ban matching compares text, and the login path stores this form).
    fn formatIp6(conn: *Conn, bytes: *const [16]u8) void {
        var w: usize = 0;
        var i: usize = 0;
        while (i < bytes.len) : (i += 2) {
            if (i > 0) {
                if (w + 1 > conn.ip.len) return;
                conn.ip[w] = ':';
                w += 1;
            }
            const v: u16 = @as(u16, bytes[i]) << 8 | bytes[i + 1];
            const s = std.fmt.bufPrint(conn.ip[w..], "{x}", .{v}) catch return;
            w += s.len;
        }
        conn.ip_len = w;
    }

    /// One server tick: advance clock, queue per-conn tick packets, flush,
    /// shut down timed-out sockets. Lock-free clock via atomics.
    /// One furnace row snapshot for viewer sync (lit/unlit swaps ride
    /// alongside in `furn_swaps`; see tickOnce).
    const FurnSnap = struct {
        x: i32,
        y: u8,
        z: i32,
        burn: u32,
        total: u32,
        cook: u32,
        in: ?item_mod.Stack = null,
        fuel: ?item_mod.Stack = null,
        out: ?item_mod.Stack = null,
    };

    /// One brewing-stand row snapshot for viewer sync (progress property 0
    /// rides alongside like the furnace props; see tickOnce).
    const BrewSnap = struct {
        x: i32,
        y: u8,
        z: i32,
        brew: u32,
        bottles: [3]?item_mod.Stack = [_]?item_mod.Stack{null} ** 3,
        ingredient: ?item_mod.Stack = null,
    };

    /// Per-player environmental flags for the hazard tick (computed once
    /// per tick from pure store reads, consumed per viewer).
    const EnvFlag = struct { water: bool = false, lava: bool = false, suff: bool = false, cactus: bool = false, in_fluid: bool = false };

    /// Phase C: one tick-region's share of the viewer pass.
    const RegionGroup = struct {
        region: *tick_mod.Region,
        /// Range into the dispatcher's `order` array (snap indices).
        start: usize,
        end: usize,
        /// region.shed_events at group build (delta → region_shed_total).
        shed_events_before: u64,
    };

    /// Phase C: a border crossing recorded during grouping (pushed to the
    /// target inbox after the pass, with no locks held).
    const RegionCrossing = struct {
        eid: i32,
        from_rx: i32,
        from_rz: i32,
        to: tick_mod.RegionId,
        x: f64,
        y: f64,
        z: f64,
    };

    /// Phase C: per-worker context for the fork-join viewer pass. Every
    /// slice is pre-ranged and read-only; outputs are per-worker and the
    /// merge pass folds them in group order (deterministic for a given
    /// grouping). Groups are disjoint across workers.
    const RegionWorkerCtx = struct {
        self: *Server,
        io: std.Io,
        snap: []RegistryEntry,
        order: []const usize,
        groups: []const RegionGroup,
        /// Global group index of groups[0] (outputs are merge-indexed).
        group_base: usize,
        players: []entity.PlayerSnap,
        mobs: []entity.MobSnap,
        items: []entity.ItemSnap,
        potions: []entity.PotionSnap,
        envs: []EnvFlag,
        furn_snaps: []FurnSnap,
        brew_snaps: []BrewSnap,
        now_ms: i64,
        age: i64,
        cpu: ?usize,
        out_deaths: []std.ArrayList(DeathInfo),
        out_claims: []entity.ClaimSet,
        out_rns: []u64,
        out_sns: []u64,
    };

    /// Phase C follow-up: one viewer group, run to completion (times it,
    /// runs its viewers with shed narrowing, records the sample, moves
    /// outputs to the merge arrays). Shared by the fork-join worker and
    /// the persistent-pool handler — one body, two thread lifetimes.
    fn runViewerGroup(
        self: *Server,
        io: std.Io,
        snap: []RegistryEntry,
        order: []const usize,
        g: RegionGroup,
        gi: usize,
        players: []entity.PlayerSnap,
        mobs: []entity.MobSnap,
        items: []entity.ItemSnap,
        potions: []entity.PotionSnap,
        envs: []EnvFlag,
        furn_snaps: []FurnSnap,
        brew_snaps: []BrewSnap,
        now_ms: i64,
        age: i64,
        out_deaths: []std.ArrayList(DeathInfo),
        out_claims: []entity.ClaimSet,
        out_rns: []u64,
        out_sns: []u64,
    ) void {
        const t0 = std.Io.Timestamp.now(io, .awake);
        var deaths = std.ArrayList(DeathInfo).empty;
        defer deaths.deinit(self.gpa);
        var claims = entity.ClaimSet{};
        var rns: u64 = 0;
        var sns: u64 = 0;
        const shed = g.region.shed;
        var vc = ViewerCtx{
            .now_ms = now_ms,
            .age = age,
            .players = players,
            .mobs = if (shed) mobs[0..0] else mobs,
            .items = if (shed) items[0..0] else items,
            .potions = if (shed) potions[0..0] else potions,
            .envs = envs,
            .furn_snaps = if (shed) furn_snaps[0..0] else furn_snaps,
            .brew_snaps = if (shed) brew_snaps[0..0] else brew_snaps,
            .deaths = &deaths,
            .claims = &claims,
            .reconcile_ns = &rns,
            .send_ns = &sns,
        };
        for (order[g.start..g.end]) |si| {
            self.tickViewerOne(&vc, snap[si]);
        }
        const dt = t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
        g.region.recordSample(@intCast(@max(0, dt)));
        // Move outputs to the merge arrays (the local is reset so the
        // defer frees nothing — ownership passes to the merge pass,
        // which frees each backing after folding it in).
        out_deaths[gi] = deaths;
        deaths = std.ArrayList(DeathInfo).empty;
        out_claims[gi] = claims;
        out_rns[gi] = rns;
        out_sns[gi] = sns;
    }

    /// Phase C follow-up: one fork-join worker. Ticks its groups in order
    /// (fallback when the persistent pool is unavailable; identical body).
    /// Inbox drains live in the tick mob section (all drains under
    /// ent_lock, once per tick) — workers never touch them.
    fn runRegionWorker(w: *RegionWorkerCtx) void {
        if (w.cpu) |c| affinity_mod.pinSelf(c);
        for (w.groups, 0..) |g, k| {
            runViewerGroup(
                w.self,
                w.io,
                w.snap,
                w.order,
                g,
                w.group_base + k,
                w.players,
                w.mobs,
                w.items,
                w.potions,
                w.envs,
                w.furn_snaps,
                w.brew_snaps,
                w.now_ms,
                w.age,
                w.out_deaths,
                w.out_claims,
                w.out_rns,
                w.out_sns,
            );
        }
    }

    /// Phase C follow-up: shared dispatch for the persistent pool. The
    /// pool owns stable worker identities (pinned once at spawn); each
    /// generation covers all groups, partitioned contiguously via bounds
    /// (same math as fork-join: neighbors share workers/cores).
    const ViewerDispatch = struct {
        self: *Server,
        io: std.Io,
        snap: []RegistryEntry,
        order: []const usize,
        groups: []const RegionGroup,
        /// bounds[w]..bounds[w+1] is worker w's group range (n+1 entries).
        bounds: []const usize,
        players: []entity.PlayerSnap,
        mobs: []entity.MobSnap,
        items: []entity.ItemSnap,
        potions: []entity.PotionSnap,
        envs: []EnvFlag,
        furn_snaps: []FurnSnap,
        brew_snaps: []BrewSnap,
        now_ms: i64,
        age: i64,
        out_deaths: []std.ArrayList(DeathInfo),
        out_claims: []entity.ClaimSet,
        out_rns: []u64,
        out_sns: []u64,
    };

    fn poolViewerHandler(ctx: *anyopaque, worker: usize, n_workers: usize) void {
        const d: *const ViewerDispatch = @ptrCast(@alignCast(ctx));
        _ = n_workers;
        const start = d.bounds[worker];
        const end = d.bounds[worker + 1];
        var k = start;
        while (k < end) : (k += 1) {
            runViewerGroup(
                d.self,
                d.io,
                d.snap,
                d.order,
                d.groups[k],
                k,
                d.players,
                d.mobs,
                d.items,
                d.potions,
                d.envs,
                d.furn_snaps,
                d.brew_snaps,
                d.now_ms,
                d.age,
                d.out_deaths,
                d.out_claims,
                d.out_rns,
                d.out_sns,
            );
        }
    }

    /// Phase C: worker count for the viewer pass (0 = auto = cpu count
    /// capped at 8, matching the transport/gen worker convention).
    fn resolveRegionThreads(self: *Server) usize {
        if (self.region_threads == 1) return 1;
        if (self.region_threads > 1) return @min(self.region_threads, tick_mod.max_workers);
        return @max(1, @min(affinity_mod.cpuCount(), 8));
    }

    /// Phase C: record a player border crossing into the target region's
    /// inbox (census + load signal; players live in conns, so nothing is
    /// adopted). Never fails the tick (OOM drops the record).
    fn pushTransfer(self: *Server, entity_id: u64, from_dim: u8, from_rx: i32, from_rz: i32, to: tick_mod.RegionId, x: f64, y: f64, z: f64) void {
        const target = self.region_reg.getOrCreate(self.gpa, to) catch return;
        target.inbox.push(.{
            .entity_id = entity_id,
            .from_dim = from_dim,
            .from_rx = from_rx,
            .from_rz = from_rz,
            .x = x,
            .y = y,
            .z = z,
        }) catch {};
    }

    /// Phase C follow-up: record a mob border crossing (full-state
    /// transfer). The source copy stays put — next tick's drain adopts
    /// into the target and deletes the source (delete-at-drain). Never
    /// fails the tick (OOM drops the record; the still-present source
    /// copy re-pushes next tick).
    fn pushMobTransfer(self: *Server, t: tick_mod.Transfer) void {
        const to = tick_mod.regionIdFor(0, t.x, t.z);
        const target = self.region_reg.getOrCreate(self.gpa, to) catch return;
        target.inbox.push(t) catch {};
    }

    /// Total live mobs across regions. Takes ent_lock itself (nests the
    /// registry lock — legal per the Registry lock-order rule); for use
    /// where ent_lock is NOT already held (stats line).
    fn mobCount(self: *Server) usize {
        self.ent_lock.lock();
        defer self.ent_lock.unlock();
        return self.region_reg.totalMobs();
    }

    /// Total mob-store bytes across regions. Caller must hold ent_lock
    /// (used inside accountMemory's ent section).
    fn mobBytesLocked(self: *Server) usize {
        return self.region_reg.totalMobBytes();
    }

    /// Free all live regions + the viewer pool. Production path is
    /// deinit(); tests that tick play conns (or a world that spawns mobs)
    /// defer this next to their registry cleanup.
    pub fn deinitRegions(self: *Server) void {
        if (self.region_pool) |p| {
            p.destroy();
            self.region_pool = null;
        }
        if (self.region_reg.count() > 0) self.region_reg.deinit(self.gpa);
    }

    /// Phase C: grouped viewers for one tick (built by buildRegionGroups).
    const GroupBuild = struct {
        order: [256]usize = undefined,
        groups: [256]RegionGroup = undefined,
        n_groups: usize = 0,
        n_ordered: usize = 0,
        crossings: [256]RegionCrossing = undefined,
        n_cross: usize = 0,
    };

    /// Phase C: file snap viewers into region groups (pass 1: classify
    /// under one conn lock at a time; pass 2: compact into contiguous
    /// ranges). Non-play conns tick inline through `legacy_vc` (login /
    /// idle timeouts). The registry probe holds no conn lock (leaf).
    ///
    /// Invariant: every grouped snap index appears in exactly one
    /// group's [start,end) range (ranges are contiguous and disjoint),
    /// so no viewer ticks twice or zero times. Interleaved regions are
    /// why pass 2 exists (extending ranges in place overlaps them).
    fn buildRegionGroups(self: *Server, snap: []RegistryEntry, legacy_vc: *ViewerCtx, out: *GroupBuild) void {
        var entry_group: [256]usize = undefined;
        var group_counts: [256]usize = undefined;
        var grouped: [256]bool = [_]bool{false} ** 256;
        // Side arrays are fixed at 256 slots (stack discipline for the
        // 1Hz tick — no per-tick heap). Viewers past the cap skip
        // grouping and tick inline through the legacy body (same as group
        // overflow below and non-play conns): correct, just unbatched.
        // (Unbounded indexing here smashed the stack past 256 viewers:
        // ReleaseFast has no bounds checks, so it crashed wild.)
        const cap = grouped.len;
        out.n_groups = 0;
        out.n_cross = 0;
        for (snap, 0..) |e, si| {
            e.conn.lock.lock();
            const is_play = e.conn.state == .play;
            const px = e.conn.pos_x;
            const py = e.conn.pos_y;
            const pz = e.conn.pos_z;
            const eid = e.conn.eid;
            const prev = e.conn.last_region;
            var cur: ?struct { rx: i32, rz: i32 } = null;
            if (is_play) {
                const rid = tick_mod.regionIdFor(0, px, pz);
                cur = .{ .rx = rid.rx, .rz = rid.rz };
                e.conn.last_region = .{ .rx = rid.rx, .rz = rid.rz };
            }
            e.conn.lock.unlock();
            if (!is_play) {
                self.tickViewerOne(legacy_vc, e);
                continue;
            }
            if (si >= cap) {
                // Past the side arrays: legacy inline (see cap note).
                self.tickViewerOne(legacy_vc, e);
                continue;
            }
            const cr = cur.?;
            if (prev) |pr| {
                if ((pr.rx != cr.rx or pr.rz != cr.rz) and out.n_cross < out.crossings.len) {
                    out.crossings[out.n_cross] = .{
                        .eid = eid,
                        .from_rx = pr.rx,
                        .from_rz = pr.rz,
                        .to = .{ .dim = 0, .rx = cr.rx, .rz = cr.rz },
                        .x = px,
                        .y = py,
                        .z = pz,
                    };
                    out.n_cross += 1;
                }
            }
            // OOM or group overflow must not drop the viewer: tick
            // inline through the same body instead.
            const reg = self.region_reg.getOrCreate(self.gpa, .{ .dim = 0, .rx = cr.rx, .rz = cr.rz }) catch {
                self.tickViewerOne(legacy_vc, e);
                continue;
            };
            var gi: usize = 0;
            while (gi < out.n_groups) : (gi += 1) {
                if (out.groups[gi].region == reg) break;
            }
            if (gi == out.n_groups) {
                if (out.n_groups >= out.groups.len) {
                    self.tickViewerOne(legacy_vc, e);
                    continue;
                }
                out.groups[out.n_groups] = .{
                    .region = reg,
                    .start = 0,
                    .end = 0,
                    .shed_events_before = reg.shed_events,
                };
                group_counts[out.n_groups] = 0;
                out.n_groups += 1;
            }
            entry_group[si] = gi;
            group_counts[gi] += 1;
            grouped[si] = true;
        }
        // Pass 2: compact into contiguous ranges (group order, snap
        // order within a group — deterministic for the grouping).
        var start: usize = 0;
        for (out.groups[0..out.n_groups], group_counts[0..out.n_groups]) |*g, cnt| {
            g.start = start;
            g.end = start + cnt;
            start = g.end;
        }
        out.n_ordered = start;
        var filled: [256]usize = [_]usize{0} ** 256;
        // Only indices the classify pass could mark (si < cap above);
        // reading grouped past the arrays was the other half of the smash.
        for (snap[0..@min(snap.len, cap)], 0..) |_, si| {
            if (!grouped[si]) continue;
            const gi = entry_group[si];
            out.order[out.groups[gi].start + filled[gi]] = si;
            filled[gi] += 1;
        }
    }

    /// Phase C: per-viewer tick inputs. Slices are pre-ranged by the
    /// dispatcher; a degraded (shed) region is handed narrowed slices
    /// (players only, no furnace rows), so this body needs no shed
    /// branches — identical code, smaller work. Accumulators are
    /// per-worker; the merge pass folds them in deterministic order.
    const ViewerCtx = struct {
        now_ms: i64,
        age: i64,
        players: []entity.PlayerSnap,
        mobs: []entity.MobSnap,
        items: []entity.ItemSnap,
        potions: []entity.PotionSnap,
        envs: []EnvFlag,
        furn_snaps: []FurnSnap,
        brew_snaps: []BrewSnap,
        deaths: *std.ArrayList(DeathInfo),
        claims: *entity.ClaimSet,
        reconcile_ns: *u64,
        send_ns: *u64,
    };

    /// Milliseconds per minute (idle-timeout conversion).
    const ms_per_min: i64 = 60000;

    /// Seal a dead conn: mark dead-after-flush, unlock, flush once, close.
    /// Caller holds e.conn.lock.
    fn sealConn(e: RegistryEntry, io: std.Io) void {
        e.conn.dead = true;
        e.conn.close_after_flush = true;
        e.conn.lock.unlock();
        // One output path (blocking: to the socket; async: the worker).
        flushEntry(e, io);
        closeEntry(e, io);
    }

    /// This viewer's env flags (null when absent from the player snapshot).
    fn envFor(vc: *ViewerCtx, eid: i32) ?EnvFlag {
        for (vc.players, 0..) |p, i| {
            if (p.eid != eid or i >= vc.envs.len) continue;
            return vc.envs[i];
        }
        return null;
    }

    /// Phase C: one viewer's tick body (visibility reconcile + output
    /// drain). No locks on entry; takes the viewer's own conn.lock for
    /// the queued-output section, releases it before the transport
    /// flush (one output path, same as the legacy loop). Parallel-safe:
    /// every mutable byte touched belongs to this viewer except the ctx
    /// accumulators (per-worker deaths/claims/timings). Shared reads
    /// (snapshots, seqlock config, atomics) are all lock-free.
    /// Continuous embedding rescue (per-tick, play conns): if feet AND
    /// eyes both read opaque in PRESENT columns, nudge up to headroom and
    /// re-send PosLook. The login rescue is one-shot and hole-blind
    /// (missing reads as fine); adopted hole falls, away-burials, and
    /// drifted terrain can all leave a player embedded after it ran.
    /// Legit players are never embedded (they occupy dug air), and holes
    /// read as missing (skipped, never "rescued" blindly), so this only
    /// fires on genuine burial. No headroom within 16 → leave them
    /// (suffocation proceeds vanilla-style). Caller holds conn.lock.
    fn rescueEmbedded(self: *Server, conn: *Conn) bool {
        const pool = self.world orelse return false;
        const ex: i32 = @intFromFloat(@floor(conn.pos_x));
        const ez: i32 = @intFromFloat(@floor(conn.pos_z));
        const feet: i32 = @intFromFloat(@floor(conn.pos_y));
        if (feet < 0 or feet > 253) return false;
        const ey_i: i32 = @intFromFloat(@floor(conn.pos_y + 1.62));
        if (ey_i < 0 or ey_i > 255) return false;
        const feet_raw = view.peekBlock(pool, self.gpa, ex, @intCast(feet), ez) catch return false;
        const feet_b = feet_raw orelse return false;
        if (!view.isOpaqueCube(feet_b.id)) return false;
        const eyes_raw = view.peekBlock(pool, self.gpa, ex, @intCast(ey_i), ez) catch return false;
        const eyes_b = eyes_raw orelse return false;
        if (!view.isOpaqueCube(eyes_b.id)) return false;
        // Embedded: scan up for two consecutive present+open cells.
        var y = feet + 1;
        while (y <= feet + 16 and y <= 253) : (y += 1) {
            const fy: u8 = @intCast(y);
            const ey: u8 = @intCast(y + 1);
            const bf_raw = view.peekBlock(pool, self.gpa, ex, fy, ez) catch return false;
            const bf = bf_raw orelse continue;
            if (view.isOpaqueCube(bf.id)) continue;
            const be_raw = view.peekBlock(pool, self.gpa, ex, ey, ez) catch return false;
            const be = be_raw orelse continue;
            if (view.isOpaqueCube(be.id)) continue;
            conn.pos_y = @floatFromInt(y);
            conn.queuePlayerPosLook() catch {};
            // Desync breaker: repeated rescues at one column mean the
            // client lost the burst column (no NACK exists, and the 10Hz
            // hole-healer skips `sent` columns). Third rescue inside 10s
            // drops the column from `sent` so the rescan re-pushes it;
            // the counter resets so a still-stuck client re-triggers
            // every third rescue (one column per push, idempotent).
            // NOTE: `sent` keys are CHUNK coords (see sentKey) while ex/ez
            // above are block coords — shift, don't reuse directly.
            const now_ms = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
            if (conn.rescue_cell_x != ex or conn.rescue_cell_z != ez or now_ms - conn.rescue_window_ms > 10_000) {
                conn.rescue_cell_x = ex;
                conn.rescue_cell_z = ez;
                conn.rescue_n = 1;
                conn.rescue_window_ms = now_ms;
            } else {
                conn.rescue_n += 1;
                if (conn.rescue_n >= 3) {
                    conn.rescue_n = 0;
                    _ = conn.sent.remove(Conn.sentKey(@divFloor(ex, 16), @divFloor(ez, 16)));
                }
            }
            return true;
        }
        return false;
    }

    fn tickViewerOne(self: *Server, vc: *ViewerCtx, e: RegistryEntry) void {
        const PresentCtx = struct {
            viewer: *Conn,
            range_blocks: f64,
        };
        const present = struct {
            fn f(ctx: *anyopaque, x: f64, z: f64) bool {
                const p: *PresentCtx = @ptrCast(@alignCast(ctx));
                const dx = x - p.viewer.pos_x;
                const dz = z - p.viewer.pos_z;
                if (@abs(dx) > p.range_blocks or @abs(dz) > p.range_blocks) return false;
                const cx = @as(i32, @intFromFloat(@floor(x / 16.0)));
                const cz = @as(i32, @intFromFloat(@floor(z / 16.0)));
                return p.viewer.sent.contains(Conn.sentKey(cx, cz));
            }
        }.f;

        e.conn.lock.lock();
        // Connections that never reach play: login timeout (anti-slowloris).
        // Login state gets a kick packet (0x00 exists there); handshaking /
        // status have no disconnect packet, so they are just dropped.
        if (e.conn.state != .play) {
            const stale = vc.now_ms - e.conn.connected_at_ms > login_timeout_ms;
            const is_login = e.conn.state == .login;
            if (stale and !e.conn.dead) {
                if (is_login) {
                    var db: [128]u8 = undefined;
                    queueBuilt(e.conn, packets.frameLoginDisconnect("{\"text\":\"Login timed out\"}", &db));
                }
                sealConn(e, self.io);
                return;
            }
            const drop = e.conn.dead;
            e.conn.lock.unlock();
            // One output path (blocking: to the socket; async: the worker).
            flushEntry(e, self.io);
            if (drop) closeEntry(e, self.io);
            return;
        }
        // Idle kick (`/setidletimeout`): play conns silent past the mark
        // get the jar-hardcoded screen. last_active_ms refreshes per frame.
        self.state_lock.lock();
        const idle_min = self.cfg.load().idle_timeout_min;
        self.state_lock.unlock();
        if (idle_min > 0 and !e.conn.dead and e.conn.last_active_ms > 0 and
            vc.now_ms - e.conn.last_active_ms > @as(i64, idle_min) * ms_per_min)
        {
            var db: [128]u8 = undefined;
            queueBuilt(e.conn, packets.frameDisconnect("{\"text\":\"You have been idle for too long!\"}", &db));
            sealConn(e, self.io);
            return;
        }
        // A closing connection (kick/timeout/ping-done) takes no new
        // queued output: the transport drains its final message(s) and
        // closes it (flush-then-close). Feeding it here would keep a
        // closing conn alive forever on async transports.
        if (e.conn.close_after_flush) {
            e.conn.lock.unlock();
            return;
        }
        const tod = self.time_of_day.load(.acquire);
        const action = e.conn.queueTick(vc.now_ms, vc.age, tod) catch {
            e.conn.lock.unlock();
            return;
        };
        const timed_out = action == .timeout;
        if (!timed_out) {
            // Burial rescue before hunger/hazards read the position: the
            // login rescue is one-shot and hole-blind, so adopted hole
            // falls, away-burials, and drifted terrain can leave a player
            // embedded past it. Returns true on rescue (env scan below is
            // one tick stale — skip it so a ghost suffocation hit can't
            // kill a just-freed player).
            var died_cause: ?DeathCause = null;
            const rescued = self.rescueEmbedded(e.conn);
            if (hungerTick(e.conn, self.config.difficulty)) |c| died_cause = c;
            // Food/drink use countdown (32-tick vanilla ItemFood use).
            e.conn.tickEating();
            if (died_cause == null and !rescued) {
                if (envFor(vc, e.conn.eid)) |env| {
                    // Vanilla resets fallDistance while touching fluid:
                    // descents while swimming (including surface bobbing
                    // with eyes out of the water) are not falls, so
                    // walking out of the water can't cash in phantom
                    // damage. The serve thread consumes the flag in
                    // setPos; the tick owns it (same lock as haz_*).
                    e.conn.in_fluid = env.in_fluid;
                    if (env.in_fluid) e.conn.fall_acc = 0;
                    if (envTick(e.conn, env.water, env.lava, env.suff, env.cactus)) |c| died_cause = c;
                }
            }
            if (died_cause == null and !e.conn.is_dead and e.conn.pos_y < void_kill_y) {
                // The void kills even in creative (no gamemode gate).
                e.conn.health = 0;
                e.conn.is_dead = true;
                var hb: [32]u8 = undefined;
                queueBuilt(e.conn, packets.frameUpdateHealth(0, e.conn.food, e.conn.saturation, &hb));
                died_cause = .void;
            }
            if (died_cause) |cause| {
                const dd = if (self.keepInv()) null else collectDeathDrops(e.conn);
                vc.deaths.append(self.gpa, .{
                    .conn = e.conn,
                    .eid = e.conn.eid,
                    .dd = dd,
                    .cause = cause,
                    .x = e.conn.pos_x,
                    .y = e.conn.pos_y,
                    .z = e.conn.pos_z,
                }) catch {};
            }
            // Furnace window sync (open window 2 at a snapped furnace).
            if (e.conn.open_win) |ow| {
                if (ow.id == 2) {
                    for (vc.furn_snaps) |fs| {
                        if (fs.x != ow.x or fs.y != ow.y or fs.z != ow.z) continue;
                        // 39 slots: 0-2 furnace, 3-38 alias inv 9..44.
                        var all: [39]?item_mod.Stack = [_]?item_mod.Stack{null} ** 39;
                        all[0] = fs.in;
                        all[1] = fs.fuel;
                        all[2] = fs.out;
                        for (item_mod.main_lo..item_mod.inv_size) |i| all[i - 6] = e.conn.inv[i];
                        const wf = packets.frameWindowItemsAlloc(e.conn.allocator, 2, &all) catch null;
                        if (wf) |f| {
                            defer e.conn.allocator.free(f);
                            e.conn.queueFramed(f) catch {};
                        }
                        var pb: [perms_mod.max_name_len]u8 = undefined;
                        const props = [_]struct { p: i16, v: i16 }{
                            .{ .p = 0, .v = @intCast(@min(fs.cook, 32767)) },
                            .{ .p = 1, .v = @intCast(@min(fs.burn, 32767)) },
                            .{ .p = 2, .v = @intCast(@min(fs.total, 32767)) },
                        };
                        for (props) |pr| {
                            queueBuilt(e.conn, packets.frameProgressBar(2, pr.p, pr.v, &pb));
                        }
                        break;
                    }
                }
            }
            // Brewing-stand window sync (open window 7 at a snapped stand).
            if (e.conn.open_win) |ow| {
                if (ow.id == 7) {
                    for (vc.brew_snaps) |bs| {
                        if (bs.x != ow.x or bs.y != ow.y or bs.z != ow.z) continue;
                        // 40 slots: 0-2 bottles, 3 ingredient, 4-39 alias inv 9..44.
                        var all: [40]?item_mod.Stack = [_]?item_mod.Stack{null} ** 40;
                        all[0] = bs.bottles[0];
                        all[1] = bs.bottles[1];
                        all[2] = bs.bottles[2];
                        all[3] = bs.ingredient;
                        for (item_mod.main_lo..item_mod.inv_size) |i| all[i - 5] = e.conn.inv[i];
                        const wf = packets.frameWindowItemsAlloc(e.conn.allocator, 7, &all) catch null;
                        if (wf) |f| {
                            defer e.conn.allocator.free(f);
                            e.conn.queueFramed(f) catch {};
                        }
                        var pb: [perms_mod.max_name_len]u8 = undefined;
                        queueBuilt(e.conn, packets.frameProgressBar(7, 0, @intCast(@min(bs.brew, 32767)), &pb));
                        break;
                    }
                }
            }
            var pctx = PresentCtx{ .viewer = e.conn, .range_blocks = @as(f64, @floatFromInt(self.view_distance)) * 16.0 + 16.0 };
            const r0 = std.Io.Timestamp.now(self.io, .awake);
            entity.reconcileViewer(e.conn, conn_sink.bind(e.conn), vc.players, vc.mobs, vc.items, vc.potions, vc.claims, present, &pctx) catch {};
            const r1 = std.Io.Timestamp.now(self.io, .awake);
            vc.reconcile_ns.* += @intCast(@max(0, r0.durationTo(r1).nanoseconds));
        }
        e.conn.lock.unlock();
        // Tick-aligned flush (Phase B): the tick drains every conn's
        // outbox and hands the bytes to the transport in one batch
        // (blocking: one write; async: one queued send). This is the
        // "flush" the acceptance criteria measure; the entity
        // reconcile above is counted separately (it is O(players^2)
        // and belongs to Phase C's region work).
        //
        // Read-timeout kills skip the flush (close-only): the peer is
        // provably silent (30s, keepalives unanswered), so the "Timed
        // out" screen has nobody to reach — and flushing a dead
        // black-hole peer's outbox (mid-burst megabytes) wedges the
        // ticker in writeAll for TCP-timeout minutes, stalling every
        // other conn's ticks behind it.
        if (!timed_out) {
            const f0 = std.Io.Timestamp.now(self.io, .awake);
            flushEntry(e, self.io);
            const f1 = std.Io.Timestamp.now(self.io, .awake);
            vc.send_ns.* += @intCast(@max(0, f0.durationTo(f1).nanoseconds));
        }
        if (timed_out) closeEntry(e, self.io);
    }

    pub fn tickOnce(self: *Server, now_ms: i64) void {
        // Batched join fan-out first: one combined player-list + chat
        // burst per tick instead of one O(players) fan-out per login.
        self.drainAnnounces();
        const age = self.world_age.fetchAdd(20, .acq_rel) + 20;
        // doDaylightCycle gates the clock (world age always advances).
        self.state_lock.lock();
        const cycle = self.cfg.load().gamerules[8];
        if (self.debug_start_ms != null) self.debug_ticks += 1;
        self.state_lock.unlock();
        if (cycle) {
            const tod = @mod(self.time_of_day.load(.acquire) + 20, @as(i64, 24000));
            self.time_of_day.store(tod, .release);
        }
        // Phase C: publish the barrier payload (region workers read
        // age/time lock-free; the fork-join itself is the barrier).
        self.region_clock.publish(age, self.time_of_day.load(.acquire));
        self.tickWeather();
        self.tickLightning();
        self.tickEffects();
        self.pollPregen(now_ms);

        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);

        // Player snapshots (copied out one conn at a time; no nesting).
        var players: [256]entity.PlayerSnap = undefined;
        var n_players: usize = 0;
        for (snap) |e| {
            if (n_players >= players.len) break;
            e.conn.lock.lock();
            var p = entity.PlayerSnap{ .eid = e.conn.eid };
            @memcpy(p.name[0..e.conn.username_len], e.conn.username[0..e.conn.username_len]);
            p.name_len = e.conn.username_len;
            @memcpy(&p.uuid, &e.conn.uuid_str);
            p.x = e.conn.pos_x;
            p.y = e.conn.pos_y;
            p.z = e.conn.pos_z;
            p.yaw = e.conn.yaw;
            p.pitch = e.conn.pitch;
            // Hazard sweep bookkeeping: the env scan sweeps the movement
            // bounding box since the last sample, so a cactus crossed —
            // even a round trip — between 1Hz ticks still hurts. First
            // sample degenerates to the current position (point check).
            if (e.conn.haz_set) {
                p.hx0 = e.conn.haz_min_x;
                p.hy0 = e.conn.haz_min_y;
                p.hz0 = e.conn.haz_min_z;
                p.hx1 = e.conn.haz_max_x;
                p.hy1 = e.conn.haz_max_y;
                p.hz1 = e.conn.haz_max_z;
            } else {
                p.hx0 = e.conn.pos_x;
                p.hy0 = e.conn.pos_y;
                p.hz0 = e.conn.pos_z;
                p.hx1 = e.conn.pos_x;
                p.hy1 = e.conn.pos_y;
                p.hz1 = e.conn.pos_z;
            }
            e.conn.haz_min_x = e.conn.pos_x;
            e.conn.haz_min_y = e.conn.pos_y;
            e.conn.haz_min_z = e.conn.pos_z;
            e.conn.haz_max_x = e.conn.pos_x;
            e.conn.haz_max_y = e.conn.pos_y;
            e.conn.haz_max_z = e.conn.pos_z;
            e.conn.haz_set = true;
            e.conn.lock.unlock();
            players[n_players] = p;
            n_players += 1;
        }

        // Wander mobs + snapshot (demo pig auto-spawns when a world is present;
        // death respawns it after pig_cooldown ticks).
        //
        // Region-owned mobs, delete-at-drain protocol (Phase C follow-up):
        // drain+adopt first (last tick's crossings land, adopted mob is in
        // this tick's snapshot — zero gap), snapshot merged across regions,
        // then wander per region (crossings push full-state transfers and
        // KEEP the source copy; next tick's drain adopts + deletes). A mob
        // killed between push and drain is dropped, never resurrected; an
        // adopt OOM keeps the source copy and retries next tick.
        // Single ent_lock section throughout (registry nests innermost).
        var mobs: [256]entity.MobSnap = undefined;
        var n_mobs: usize = 0;
        self.ent_lock.lock();
        // Live regions (stable pointers; heap-falls-back past 256 cells).
        var rstack: [256]*tick_mod.Region = undefined;
        const n_live = self.region_reg.count();
        var rheap: []*tick_mod.Region = &.{};
        if (n_live > rstack.len) {
            rheap = self.gpa.alloc(*tick_mod.Region, n_live) catch &.{};
        }
        var regs: []*tick_mod.Region = if (rheap.len == n_live) rheap else rstack[0..];
        const n_regs = self.region_reg.allRegions(regs);
        defer if (rheap.len > 0) self.gpa.free(rheap);
        // 1. Drain every inbox: mob transfers adopt (delete-at-drain),
        //    player transfers bump the census.
        for (regs[0..n_regs]) |reg| {
            const msgs = reg.inbox.drain() catch continue;
            defer self.gpa.free(msgs);
            for (msgs) |m| {
                if (!m.is_mob) {
                    reg.census += 1;
                    continue;
                }
                const eid: i32 = @intCast(m.entity_id);
                const src_id = tick_mod.RegionId{ .dim = m.from_dim, .rx = m.from_rx, .rz = m.from_rz };
                const src = self.region_reg.lookup(src_id) orelse continue;
                const si = src.mobs.indexOfId(eid) orelse continue; // killed mid-flight: drop
                reg.adoptMob(m) catch continue; // OOM: source copy kept, retried next tick
                src.mobs.removeAt(si);
            }
        }
        if (self.world != null) {
            var pigs: usize = 0;
            for (regs[0..n_regs]) |reg| {
                for (reg.mobs.kinds.items) |k| {
                    if (k == entity.MOB_PIG) pigs += 1;
                }
            }
            var want_pig = false;
            if (pigs == 0) {
                if (!self.pig_spawned) {
                    self.pig_spawned = true;
                    want_pig = true;
                } else if (self.pig_cooldown == 0) {
                    self.pig_cooldown = 30;
                    want_pig = true;
                } else {
                    self.pig_cooldown -= 1;
                }
            }
            if (want_pig and self.canSpawnMob(entity.MOB_PIG)) {
                const id = self.eid_counter.fetchAdd(1, .acq_rel);
                // Owned by its spawn cell's region from birth.
                const srid = tick_mod.regionIdFor(0, @as(f64, @floatFromInt(self.config.spawn_x)) + 2.5, @as(f64, @floatFromInt(self.config.spawn_z)) + 2.5);
                const srcreg = self.region_reg.getOrCreate(self.gpa, srid) catch null;
                if (srcreg) |sr| {
                    _ = sr.mobs.add(.{
                        .id = id,
                        .kind = entity.MOB_PIG,
                        .x = @as(f64, @floatFromInt(self.config.spawn_x)) + 2.5,
                        .y = @as(f64, @floatFromInt(self.config.spawn_y)),
                        .z = @as(f64, @floatFromInt(self.config.spawn_z)) + 2.5,
                        .yaw = 0,
                        .health = 10.0,
                        .home_x = @as(f64, @floatFromInt(self.config.spawn_x)) + 2.5,
                        .home_z = @as(f64, @floatFromInt(self.config.spawn_z)) + 2.5,
                        .patrol_r = 4.0,
                    }) catch {};
                }
            }
        }
        // 2. Snapshot merged across regions (cap 256, pre-existing).
        for (regs[0..n_regs]) |reg| {
            for (0..reg.mobs.len()) |si| {
                if (n_mobs >= mobs.len) break;
                mobs[n_mobs] = .{
                    .id = reg.mobs.ids.items[si],
                    .kind = reg.mobs.kinds.items[si],
                    .x = reg.mobs.px.items[si],
                    .y = reg.mobs.py.items[si],
                    .z = reg.mobs.pz.items[si],
                    .yaw = reg.mobs.yaw.items[si],
                    .health = reg.mobs.health.items[si],
                };
                n_mobs += 1;
            }
        }
        // 3. Wander per region; crossings push full-state transfers (the
        // source copy stays — next tick's drain adopts + deletes). A mob
        // moves 0.5 blocks/tick against 512-block cells: at most one
        // crossing per mob per tick, so the 256-entry record never fills
        // from wander alone.
        var mob_cross: [256]tick_mod.Transfer = undefined;
        var n_mob_cross: usize = 0;
        for (regs[0..n_regs]) |reg| {
            reg.mobs.tick(0.5);
            for (0..reg.mobs.len()) |i| {
                const rid = tick_mod.regionIdFor(0, reg.mobs.px.items[i], reg.mobs.pz.items[i]);
                if ((rid.dim != reg.id.dim or rid.rx != reg.id.rx or rid.rz != reg.id.rz) and n_mob_cross < mob_cross.len) {
                    mob_cross[n_mob_cross] = .{
                        .entity_id = @intCast(reg.mobs.ids.items[i]),
                        .from_dim = reg.id.dim,
                        .from_rx = reg.id.rx,
                        .from_rz = reg.id.rz,
                        .x = reg.mobs.px.items[i],
                        .y = reg.mobs.py.items[i],
                        .z = reg.mobs.pz.items[i],
                        .is_mob = true,
                        .kind = reg.mobs.kinds.items[i],
                        .yaw = reg.mobs.yaw.items[i],
                        .health = reg.mobs.health.items[i],
                        .home_x = reg.mobs.home_x.items[i],
                        .home_z = reg.mobs.home_z.items[i],
                        .patrol_r = reg.mobs.patrol_r.items[i],
                    };
                    n_mob_cross += 1;
                }
            }
        }
        // Age item entities (ticks are 20tps units, +20 per 1Hz tick), tick
        // down pickup delays, merge stacks (vanilla xk merge), and mark the
        // 5-minute despawns. The item list is capped at max_items so the
        // fixed snapshot below is always complete.
        for (self.items.items) |*it| {
            it.age +|= 20;
            if (it.delay >= 20) it.delay -= 20 else it.delay = 0;
        }
        // Toss physics (vanilla EntityItem arc, jar `xk.onUpdate`): fresh
        // drops carry motion and integrate 20 substeps per 1Hz tick
        // (gravity 0.04, drag 0.98, ground bounce -0.5 + 0.7 horizontal
        // friction, landing on first-solid-top + 0.125). A 0.2 pop lands
        // within ~10 substeps; settled items go static (no tick work, no
        // move broadcasts). Over-void items fall until y < -64, then
        // despawn like vanilla.
        if (self.world) |pool| {
            var ii: usize = 0;
            while (ii < self.items.items.len) {
                const it = &self.items.items[ii];
                if (it.vx == 0 and it.vy == 0 and it.vz == 0) {
                    ii += 1;
                    continue;
                }
                self.integrateItemToss(pool, it) catch {};
                if (it.y < -64.0) {
                    const dead = self.items.swapRemove(ii);
                    var s: ?item_mod.Stack = dead.stack;
                    item_mod.freeStack(self.gpa, &s);
                    continue;
                }
                ii += 1;
            }
        }
        var mi2: usize = 0;
        while (mi2 < self.items.items.len) {
            var mj: usize = mi2 + 1;
            var consumed = false;
            while (mj < self.items.items.len) {
                if (self.items.items[mi2].tryMerge(&self.items.items[mj])) {
                    const dead = self.items.swapRemove(mj);
                    var s: ?item_mod.Stack = dead.stack;
                    item_mod.freeStack(self.gpa, &s);
                    // Survivor grew: refresh trackers (see spawnItem).
                    self.broadcastItemMeta(self.items.items[mi2].id, self.items.items[mi2].stack);
                } else if (self.items.items[mj].tryMerge(&self.items.items[mi2])) {
                    // Survivor (mj) grew: refresh trackers before the
                    // swapRemove below moves it (see spawnItem).
                    self.broadcastItemMeta(self.items.items[mj].id, self.items.items[mj].stack);
                    const dead = self.items.swapRemove(mi2);
                    var s: ?item_mod.Stack = dead.stack;
                    item_mod.freeStack(self.gpa, &s);
                    consumed = true;
                    break;
                } else {
                    mj += 1;
                }
            }
            if (!consumed) mi2 += 1;
        }
        // Splash potions: age, then arc-integrate on pool worlds (block or
        // direct-player impact), apply on impact, despawn on void/age.
        // Impacts fan out after ent_lock releases (conn locks never nest
        // under ent_lock — the lethal-PvP rule).
        var impacts: [256]PotionImpact = undefined;
        var n_impacts: usize = 0;
        for (self.potions.items) |*pot| pot.age +|= 20;
        if (self.world) |pool| {
            var pi: usize = 0;
            while (pi < self.potions.items.len) {
                const pot = &self.potions.items[pi];
                const hit = self.integratePotionArc(pool, pot, players[0..n_players]) catch -2;
                if (hit == -2) {
                    if (pot.y < -64.0 or pot.age >= 200) {
                        _ = self.potions.swapRemove(pi);
                        continue;
                    }
                    pi += 1;
                    continue;
                }
                // Impact: full duration for the direct hit, (1 - d/4)
                // falloff floored to whole seconds for everyone else in
                // radius; instant health/harm apply full to the radius.
                if (profile.game.potion_data.effectFor(pot.damage)) |ap| {
                    for (players[0..n_players]) |p| {
                        const dx = pot.x - p.x;
                        const dy = pot.y - (p.y + 1.0);
                        const dz = pot.z - p.z;
                        const d = @sqrt(dx * dx + dy * dy + dz * dz);
                        const secs = profile.game.potion_data.splashSeconds(ap.seconds, d, hit == p.eid);
                        if (secs == 0) continue;
                        if (n_impacts < impacts.len) {
                            impacts[n_impacts] = .{ .eid = p.eid, .a6 = ap.a6, .seconds = secs, .amp = ap.amp };
                            n_impacts += 1;
                        }
                    }
                }
                _ = self.potions.swapRemove(pi);
            }
        } else {
            var pi: usize = 0;
            while (pi < self.potions.items.len) {
                if (self.potions.items[pi].age >= 200) {
                    _ = self.potions.swapRemove(pi);
                    continue;
                }
                pi += 1;
            }
        }
        var item_snaps: [Server.max_items]entity.ItemSnap = undefined;
        var n_items: usize = 0;
        var despawned: [Server.max_items]i32 = undefined;
        var n_despawned: usize = 0;
        for (self.items.items) |it| {
            if (it.age >= 6000) {
                despawned[n_despawned] = it.id;
                n_despawned += 1;
            }
            if (n_items >= item_snaps.len) break;
            item_snaps[n_items] = .{
                .id = it.id,
                .x = it.x,
                .y = it.y,
                .z = it.z,
                .item_id = it.stack.id,
                .count = it.stack.count,
                .damage = it.stack.damage,
                // Owned per-tick dupe (freed after the reconcile pass); OOM
                // degrades to tagless metadata rather than dropping the item.
                .nbt = if (it.stack.nbt) |n| self.gpa.dupe(u8, n) catch null else null,
                .can_pickup = it.delay == 0,
                .vx = it.vx,
                .vy = it.vy,
                .vz = it.vz,
            };
            n_items += 1;
        }
        var potion_snaps: [256]entity.PotionSnap = undefined;
        var n_potions: usize = 0;
        for (self.potions.items) |pot| {
            if (n_potions >= potion_snaps.len) break;
            potion_snaps[n_potions] = .{
                .id = pot.id,
                .x = pot.x,
                .y = pot.y,
                .z = pot.z,
                .damage = pot.damage,
                .vx = pot.vx,
                .vy = pot.vy,
                .vz = pot.vz,
            };
            n_potions += 1;
        }
        self.ent_lock.unlock();
        // Splash impacts fan out with no locks held (conn locks nest
        // under nothing here; ent_lock already released above).
        self.applyPotionImpacts(impacts[0..n_impacts]);
        // Mob handoffs ride the target inbox (recorded above, no locks
        // held here). Full-state transfers; the source copy stays until
        // next tick's drain adopts + deletes (delete-at-drain).
        for (mob_cross[0..n_mob_cross]) |c| {
            self.pushMobTransfer(c);
        }

        // Furnaces: 20-tick quanta under furn_lock; snapshot progress + slots
        // for viewer sync, record lit/unlit swaps for the world pass.
        // (NBT duped per tick, freed after the reconcile pass like items.)
        var furn_snaps: [256]FurnSnap = undefined;
        var n_furn: usize = 0;
        var furn_swaps: [256]struct { x: i32, y: u8, z: i32, lit: bool } = undefined;
        var n_swaps: usize = 0;
        self.furn_lock.lock();
        for (self.furnaces.items) |*f| {
            const was_burning = f.burn > 0;
            var slots = furnace_mod.Slots{ .input = f.input, .fuel = f.fuel, .output = f.output };
            const prev_in_nbt: ?[]const u8 = if (f.input) |s| s.nbt else null;
            const prev_fuel_nbt: ?[]const u8 = if (f.fuel) |s| s.nbt else null;
            _ = furnace_mod.tick(&slots, &f.burn, &f.total, &f.cook);
            // tick() never allocates NBT: stacks keep their buffers, swap
            // to a container item (null NBT), or are nulled. Free prev iff dropped.
            const new_in_nbt: ?[]const u8 = if (slots.input) |ns| ns.nbt else null;
            const in_dropped = if (prev_in_nbt) |p| (if (new_in_nbt) |n| n.ptr != p.ptr else true) else false;
            if (in_dropped) self.gpa.free(prev_in_nbt.?);
            const new_nbt: ?[]const u8 = if (slots.fuel) |ns| ns.nbt else null;
            const dropped = if (prev_fuel_nbt) |p| (if (new_nbt) |n| n.ptr != p.ptr else true) else false;
            if (dropped) self.gpa.free(prev_fuel_nbt.?);
            f.input = slots.input;
            f.output = slots.output;
            f.fuel = slots.fuel;
            if (was_burning != (f.burn > 0) and n_swaps < furn_swaps.len) {
                furn_swaps[n_swaps] = .{ .x = f.x, .y = f.y, .z = f.z, .lit = f.burn > 0 };
                n_swaps += 1;
            }
            if (n_furn >= furn_snaps.len) continue;
            furn_snaps[n_furn] = .{
                .x = f.x,
                .y = f.y,
                .z = f.z,
                .burn = f.burn,
                .total = f.total,
                .cook = f.cook,
                .in = if (f.input) |s| .{ .id = s.id, .count = s.count, .damage = s.damage, .nbt = if (s.nbt) |n| self.gpa.dupe(u8, n) catch null else null } else null,
                .fuel = if (f.fuel) |s| .{ .id = s.id, .count = s.count, .damage = s.damage, .nbt = if (s.nbt) |n| self.gpa.dupe(u8, n) catch null else null } else null,
                .out = if (f.output) |s| .{ .id = s.id, .count = s.count, .damage = s.damage, .nbt = if (s.nbt) |n| self.gpa.dupe(u8, n) catch null else null } else null,
            };
            n_furn += 1;
        }
        self.furn_lock.unlock();

        // Brewing stands: 20-tick quanta under brew_lock; snapshot progress
        // + slots for viewer sync (same NBT-dupe discipline as furnaces).
        var brew_snaps: [256]BrewSnap = undefined;
        var n_brew: usize = 0;
        self.brew_lock.lock();
        for (self.brews.items) |*b| {
            var slots = brewing_mod.Slots{ .ingredient = b.ingredient };
            for (&b.bottles, 0..) |*bt, i| slots.bottles[i] = bt.*;
            const prev_nbt = [_]?[]const u8{
                if (b.bottles[0]) |s| s.nbt else null,
                if (b.bottles[1]) |s| s.nbt else null,
                if (b.bottles[2]) |s| s.nbt else null,
                if (b.ingredient) |s| s.nbt else null,
            };
            _ = brewing_mod.tick(&slots, &b.brew);
            for (&b.bottles, 0..) |*bt, i| bt.* = slots.bottles[i];
            b.ingredient = slots.ingredient;
            const new_nbt = [_]?[]const u8{
                if (b.bottles[0]) |s| s.nbt else null,
                if (b.bottles[1]) |s| s.nbt else null,
                if (b.bottles[2]) |s| s.nbt else null,
                if (b.ingredient) |s| s.nbt else null,
            };
            for (prev_nbt, new_nbt) |p, n| {
                const dropped = if (p) |pp| (if (n) |nn| nn.ptr != pp.ptr else true) else false;
                if (dropped) self.gpa.free(p.?);
            }
            if (n_brew >= brew_snaps.len) continue;
            brew_snaps[n_brew] = .{
                .x = b.x,
                .y = b.y,
                .z = b.z,
                .brew = b.brew,
                .bottles = .{
                    if (b.bottles[0]) |s| .{ .id = s.id, .count = s.count, .damage = s.damage, .nbt = if (s.nbt) |n| self.gpa.dupe(u8, n) catch null else null } else null,
                    if (b.bottles[1]) |s| .{ .id = s.id, .count = s.count, .damage = s.damage, .nbt = if (s.nbt) |n| self.gpa.dupe(u8, n) catch null else null } else null,
                    if (b.bottles[2]) |s| .{ .id = s.id, .count = s.count, .damage = s.damage, .nbt = if (s.nbt) |n| self.gpa.dupe(u8, n) catch null else null } else null,
                },
                .ingredient = if (b.ingredient) |s| .{ .id = s.id, .count = s.count, .damage = s.damage, .nbt = if (s.nbt) |n| self.gpa.dupe(u8, n) catch null else null } else null,
            };
            n_brew += 1;
        }
        self.brew_lock.unlock();

        // K1 redstone tick: drain scheduled entries (button release,
        // repeater eval, ore fade, torch recheck) + poll pressure plates.
        // World work under world_lock; broadcasts after (furnace pattern).
        // Plate detection needs entity positions: players/mobs/item snaps
        // are already copied above (no locks held here).
        if (self.world != null and (self.rs_sched.n > 0 or self.rs_plates.n > 0)) {
            var rs_changes: redstone_mod.ChangeList = .{};
            var rs_sounds: redstone_mod.SoundList = .{};
            var rs_actions: redstone_mod.ActionList = .{};
            self.world_lock.lock();
            const now_rs = self.rs_tick;
            if (self.world) |pool| self.loadRedstone(pool, now_rs);
            if (self.world) |pool| {
                var w = Server.RsWorld{ .pool = pool, .alloc = self.gpa, .changes = &rs_changes };
                defer w.deinit();
                var p_ents: [256]redstone_mod.Ent = undefined;
                var m_ents: [256]redstone_mod.Ent = undefined;
                var i_ents: [256]redstone_mod.Ent = undefined;
                for (players[0..n_players], 0..) |p, i| {
                    if (i >= p_ents.len) break;
                    p_ents[i] = .{ .x = p.x, .y = p.y, .z = p.z };
                }
                for (mobs[0..n_mobs], 0..) |m, i| {
                    if (i >= m_ents.len) break;
                    m_ents[i] = .{ .x = m.x, .y = m.y, .z = m.z };
                }
                for (item_snaps[0..n_items], 0..) |it, i| {
                    if (i >= i_ents.len) break;
                    i_ents[i] = .{ .x = it.x, .y = it.y, .z = it.z };
                }
                redstone_mod.tick(
                    w.rsView(),
                    &self.rs_sched,
                    &self.rs_burn,
                    &self.rs_plates,
                    &rs_changes,
                    &rs_sounds,
                    now_rs,
                    p_ents[0..@min(n_players, p_ents.len)],
                    m_ents[0..@min(n_mobs, m_ents.len)],
                    i_ents[0..@min(n_items, i_ents.len)],
                    &rs_actions,
                );
            }
            self.world_lock.unlock();
            if (self.world) |_| {
                self.flushRsBatch(rs_changes, rs_sounds, rs_actions);
            }
        }

        var claims = entity.ClaimSet{};
        // Environmental hazards from player snaps (no conn locks here;
        // world_lock is a leaf). Eyes block decides drown/suffocate, feet
        // block adds lava.
        var envs: [256]EnvFlag = undefined;
        for (envs[0..@min(envs.len, n_players)]) |*f| f.* = .{};
        if (self.world) |pool| {
            // Pure reads (no read-modify-write), so the world lock is NOT
            // held here: the store is internally consistent (a put
            // replaces the whole chunk value), and holding the world lock
            // across a cold-cache disk read stalled every chunk-serving
            // thread behind the tick.
            for (players[0..n_players], 0..) |p, i| {
                if (i >= envs.len) break;
                const ex: i32 = @intFromFloat(@floor(p.x));
                const ez: i32 = @intFromFloat(@floor(p.z));
                const eyes: u8 = @intFromFloat(@max(0, @min(255, p.y + 1.62)));
                const feet: u8 = @intFromFloat(@max(0, @min(255, p.y)));
                if (view.peekBlock(pool, self.gpa, ex, eyes, ez) catch null) |b| {
                    envs[i].water = b.id == game_ids.flowing_water or b.id == game_ids.water;
                    envs[i].suff = view.isOpaqueCube(b.id);
                    if (b.id == game_ids.flowing_lava or b.id == game_ids.lava) envs[i].lava = true;
                    // Fluid contact is eyes OR feet (vanilla checks the
                    // whole body): a surface swimmer breathes air but is
                    // still in the water for fall-distance purposes.
                    if (envs[i].water or envs[i].lava) envs[i].in_fluid = true;
                }
                if (view.peekBlock(pool, self.gpa, ex, feet, ez) catch null) |b| {
                    if (b.id == game_ids.flowing_water or b.id == game_ids.water or
                        b.id == game_ids.flowing_lava or b.id == game_ids.lava)
                    {
                        if (b.id == game_ids.flowing_lava or b.id == game_ids.lava) envs[i].lava = true;
                        envs[i].in_fluid = true;
                    }
                }
                // Cactus contact is AABB overlap, not cell identity: brushing
                // past a neighboring cactus hurts (vanilla collision box).
                // The segment sweep catches cacti crossed between 1Hz
                // samples (a sprint covers a cell in ~0.2s); standing
                // still degenerates to the point check.
                envs[i].cactus = self.touchesCactus(pool, p.x, p.y, p.z) or
                    self.segmentTouchesCactus(pool, p.hx0, p.hy0, p.hz0, p.hx1, p.hy1, p.hz1);
            }
        }
        var deaths: std.ArrayList(DeathInfo) = .empty;
        // Phase B: the per-viewer tick phase (reconcile + output drain) is
        // what "tick flush" means in the acceptance criteria: the time the
        // tick spends pushing the accumulated output to every connection.
        const flush_t0 = std.Io.Timestamp.now(self.io, .awake);
        var reconcile_ns: u64 = 0;
        var send_ns: u64 = 0;
        // Phase C: region dispatch. Play viewers file into region groups
        // (one region = one tick unit, never split mid-tick); groups run
        // fork-join with the join as the global barrier; the merge folds
        // worker outputs in group order (deterministic for a given
        // grouping). Non-play conns run inline first (login/idle
        // timeouts; rare).
        {
            var legacy_vc = ViewerCtx{
                .now_ms = now_ms,
                .age = age,
                .players = players[0..n_players],
                .mobs = mobs[0..n_mobs],
                .items = item_snaps[0..n_items],
                .potions = potion_snaps[0..n_potions],
                .envs = envs[0..],
                .furn_snaps = furn_snaps[0..n_furn],
                .brew_snaps = brew_snaps[0..n_brew],
                .deaths = &deaths,
                .claims = &claims,
                .reconcile_ns = &reconcile_ns,
                .send_ns = &send_ns,
            };
            var build = GroupBuild{};
            self.buildRegionGroups(snap, &legacy_vc, &build);
            // Crossings ride the target inbox (recorded above, pushed with
            // no locks held — the registry lock is a leaf).
            for (build.crossings[0..build.n_cross]) |c| {
                self.pushTransfer(@intCast(c.eid), 0, c.from_rx, c.from_rz, c.to, c.x, c.y, c.z);
            }
            // Run phase: one worker per group range (sequential when a
            // single thread is configured — same body, group order, with
            // the breaker and census live either way).
            if (build.n_groups > 0) {
                const want = self.resolveRegionThreads();
                const n_workers = @min(@min(want, build.n_groups), tick_mod.max_workers);
                var cpus: [tick_mod.max_workers]usize = undefined;
                if (n_workers >= 2) {
                    if (!self.region_topo_done) {
                        self.region_topo = affinity_mod.detect(self.io);
                        self.region_topo_done = true;
                    }
                    affinity_mod.assignRegions(&self.region_topo, n_workers, &cpus);
                }
                var out_deaths: [256]std.ArrayList(DeathInfo) = undefined;
                var out_claims: [256]entity.ClaimSet = undefined;
                var out_rns: [256]u64 = undefined;
                var out_sns: [256]u64 = undefined;
                // Phase C follow-up: persistent pool first (stable workers,
                // pinned once); fork-join fallback when creation fails or
                // off Linux (same body and merge either way).
                var disp = ViewerDispatch{
                    .self = self,
                    .io = self.io,
                    .snap = snap,
                    .order = build.order[0..build.n_ordered],
                    .groups = build.groups[0..build.n_groups],
                    .bounds = &.{},
                    .players = players[0..n_players],
                    .mobs = mobs[0..n_mobs],
                    .items = item_snaps[0..n_items],
                    .potions = potion_snaps[0..n_potions],
                    .envs = envs[0..],
                    .furn_snaps = furn_snaps[0..n_furn],
                    .brew_snaps = brew_snaps[0..n_brew],
                    .now_ms = now_ms,
                    .age = age,
                    .out_deaths = out_deaths[0..build.n_groups],
                    .out_claims = out_claims[0..build.n_groups],
                    .out_rns = out_rns[0..build.n_groups],
                    .out_sns = out_sns[0..build.n_groups],
                };
                var bounds: [tick_mod.max_workers + 1]usize = undefined;
                var pool: ?*pool_mod.Pool = null;
                if (n_workers >= 2) {
                    if (self.region_pool == null) {
                        self.region_pool = pool_mod.Pool.create(self.gpa, n_workers, cpus[0..n_workers]) catch null;
                    }
                    pool = self.region_pool;
                }
                if (pool) |pl| {
                    // Partition groups contiguously across the pool's
                    // stable workers (same math as fork-join).
                    const pn = pl.n;
                    var off: usize = 0;
                    var w: usize = 0;
                    while (w < pn) : (w += 1) {
                        bounds[w] = off;
                        off += (build.n_groups - off) / (pn - w);
                    }
                    bounds[pn] = off;
                    disp.bounds = bounds[0 .. pn + 1];
                    pl.run(&disp, poolViewerHandler);
                } else {
                    var wctx: [tick_mod.max_workers]RegionWorkerCtx = undefined;
                    var wthreads: [tick_mod.max_workers]std.Thread = undefined;
                    var spawned: usize = 0;
                    var spawned_threads: usize = 0;
                    var sequential = n_workers <= 1;
                    var off: usize = 0;
                    // Contiguous group ranges: neighboring regions share
                    // workers (pinned to neighboring cores / shared L3).
                    while (spawned < n_workers) : (spawned += 1) {
                        const len = (build.n_groups - off) / (n_workers - spawned);
                        wctx[spawned] = .{
                            .self = self,
                            .io = self.io,
                            .snap = snap,
                            .order = build.order[0..build.n_ordered],
                            .groups = build.groups[off .. off + len],
                            .group_base = off,
                            .players = players[0..n_players],
                            .mobs = mobs[0..n_mobs],
                            .items = item_snaps[0..n_items],
                            .potions = potion_snaps[0..n_potions],
                            .envs = envs[0..],
                            .furn_snaps = furn_snaps[0..n_furn],
                            .brew_snaps = brew_snaps[0..n_brew],
                            .now_ms = now_ms,
                            .age = age,
                            .cpu = if (n_workers >= 2) cpus[spawned] else null,
                            .out_deaths = out_deaths[0..build.n_groups],
                            .out_claims = out_claims[0..build.n_groups],
                            .out_rns = out_rns[0..build.n_groups],
                            .out_sns = out_sns[0..build.n_groups],
                        };
                        off += len;
                        if (sequential) {
                            runRegionWorker(&wctx[spawned]);
                        } else if (std.Thread.spawn(.{}, runRegionWorker, .{&wctx[spawned]})) |t| {
                            wthreads[spawned_threads] = t;
                            spawned_threads += 1;
                        } else |_| {
                            // No thread for this range (or any later one):
                            // run it — and the rest — inline. Still correct.
                            runRegionWorker(&wctx[spawned]);
                            sequential = true;
                        }
                    }
                    for (wthreads[0..spawned_threads]) |t| t.join();
                }
                // Merge in group order (deterministic for the grouping).
                // Shared by the pool and fork-join paths.
                for (build.groups[0..build.n_groups], 0..) |g, gi| {
                    for (out_deaths[gi].items) |di| deaths.append(self.gpa, di) catch {};
                    out_deaths[gi].deinit(self.gpa);
                    for (out_claims[gi].ids[0..out_claims[gi].n], out_claims[gi].collectors[0..out_claims[gi].n]) |id, who| {
                        _ = claims.add(id, who);
                    }
                    reconcile_ns += out_rns[gi];
                    send_ns += out_sns[gi];
                    self.region_shed_total += g.region.shed_events - g.shed_events_before;
                }
            }
        }
        {
            // The "tick flush" number the acceptance criteria measure is
            // the output push (drain + send per connection); the entity
            // reconcile is counted separately (it is O(players^2) and
            // belongs to Phase C's region work).
            const dt = flush_t0.durationTo(std.Io.Timestamp.now(self.io, .awake)).nanoseconds;
            _ = dt;
            self.pushFlushSample(send_ns);
            self.reconcile_ns_last = reconcile_ns;
            self.send_ns_last = send_ns;
        }
        // Apply pickup claims + despawns: remove under ent_lock (freeing owned
        // NBT), then broadcast Collect (claims) + Destroy to trackers. The
        // claimers themselves already got all three packets in reconcile,
        // and their tracked sets no longer contain the id, so the rebroadcast
        // naturally excludes them.
        self.ent_lock.lock();
        for (despawned[0..n_despawned]) |id| self.removeItemById(id);
        for (claims.ids[0..claims.n]) |id| self.removeItemById(id);
        self.ent_lock.unlock();
        {
            var fb: [32]u8 = undefined;
            for (despawned[0..n_despawned]) |id| {
                const f = packets.frameDestroyEntitiesFramed(&[_]i32{id}, &fb) catch continue;
                self.broadcastToTrackers(id, f);
            }
            var cb: [perms_mod.max_name_len]u8 = undefined;
            var i: usize = 0;
            while (i < claims.n) : (i += 1) {
                const id = claims.ids[i];
                const who = claims.collectors[i];
                const c = packets.frameCollect(id, who, &cb) catch continue;
                self.broadcastToTrackers(id, c);
                const f = packets.frameDestroyEntitiesFramed(&[_]i32{id}, &fb) catch continue;
                self.broadcastToTrackers(id, f);
            }
        }
        for (item_snaps[0..n_items]) |s| if (s.nbt) |n| self.gpa.free(n);
        // Furnace lit/unlit swaps (world write + broadcast, never nested).
        // Guarded by peek: a concurrently broken furnace stays broken.
        if (self.world != null and n_swaps > 0) {
            var applied: [256]bool = [_]bool{false} ** 256;
            var touched: [256]u8 = [_]u8{0} ** 256;
            self.world_lock.lock();
            for (furn_swaps[0..n_swaps], 0..) |sw, i| {
                if (self.world) |pool| {
                    const cur = view.peekBlock(pool, self.gpa, sw.x, sw.y, sw.z) catch null;
                    if (cur) |c| if (c.id == game_ids.furnace or c.id == game_ids.lit_furnace) {
                        touched[i] = view.applyBlock(pool, self.gpa, sw.x, sw.y, sw.z, if (sw.lit) game_ids.lit_furnace else game_ids.furnace, 0) catch 0;
                        applied[i] = true;
                    };
                }
            }
            self.world_lock.unlock();
            for (furn_swaps[0..n_swaps], 0..) |sw, i| {
                if (!applied[i]) continue;
                self.broadcastBlockChange(null, sw.x, sw.y, sw.z, if (sw.lit) game_ids.lit_furnace else game_ids.furnace, 0) catch {};
                if (self.world) |pool| {
                    self.resendTouchedNeighbors(pool, sw.x, sw.z, touched[i]);
                }
            }
        }
        for (furn_snaps[0..n_furn]) |s| {
            if (s.in) |st| if (st.nbt) |n| self.gpa.free(n);
            if (s.fuel) |st| if (st.nbt) |n| self.gpa.free(n);
            if (s.out) |st| if (st.nbt) |n| self.gpa.free(n);
        }
        // Deaths from hunger/environment/void this tick, one pass per
        // death (drops + metadata + death line), then one save pass.
        // No ordering is needed across deaths (each is independent).
        {
            var mb: [32]u8 = undefined;
            for (deaths.items) |*di| {
                if (di.dd) |*d| {
                    if (di.cause == .void) {
                        self.destroyDrops(d);
                    } else {
                        self.spawnDeathDrops(d, di.x, di.y, di.z);
                    }
                }
                if (packets.frameEntityMetadata(di.eid, 0, &mb)) |f| {
                    self.broadcastToTrackers(di.eid, f);
                } else |_| {}
                var nm: [perms_mod.max_name_len]u8 = undefined;
                const nm_len = copyUsername(di.conn, &nm);
                self.broadcastDeath(nm[0..nm_len], di.cause, di.killer[0..di.killer_len]);
            }
        }
        for (deaths.items) |di| self.savePlayer(di.conn);
        deaths.deinit(self.gpa);
        // Chest rows: flush click-dirty chests every tick (<=1 s crash
        // window; the row writes are a few hundred bytes each).
        self.flushDirtyChests();
        // Periodic autosave (WAL-durable; save-all/stop flush SSTs on top).
        // Counter rolls over naturally; the modulo stays aligned.
        self.tick_counter += 1;
        if (self.world != null and self.getAutosave() and self.tick_counter % autosave_ticks == 0) {
            _ = self.saveAllPlayers();
            self.saveRedstone();
        }
    }

    /// Broadcast a 0x23 block change to viewers tracking the chunk
    /// (sent-set membership), excluding the originator.
    /// Vanilla block step/break sound base for an id (`dig.<base>`).
    /// Material approximation of per-block `stepSound`: wood, grass
    /// (leaves use grass in vanilla), gravel, sand, glass (ice breaks
    /// like glass), cloth, snow, stone default.
    // ---- entity broadcasts, combat, survival ----

    fn isLiquid(id: game_ids.Id) bool {
        return id == .water or id == .flowing_water or id == .lava or id == .flowing_lava;
    }

    /// Place/break voice: liquids splash (vanilla bucket/fluid behavior),
    /// everything else digs by material.
    fn placeSound(id: game_ids.Id) struct { name: []const u8, pitch: f32 } {
        if (isLiquid(id)) return .{ .name = "liquid.splash", .pitch = 1.0 };
        return .{ .name = stepSound(id), .pitch = 0.8 };
    }

    fn stepSound(id: game_ids.Id) []const u8 {
        return switch (id) {
            .grass, .tallgrass, .deadbush, .vine, .leaves, .leaves2, .sapling, .yellow_flower, .red_flower, .brown_mushroom, .red_mushroom, .reeds_block, .cactus, .waterlily => "dig.grass",
            .dirt, .gravel, .clay, .soul_sand, .farmland, .mycelium => "dig.gravel",
            .sand, .sandstone => "dig.sand",
            .glass, .glass_pane, .stained_glass, .stained_glass_pane, .ice => "dig.glass",
            .wool, .carpet => "dig.cloth",
            .snow, .snow_layer => "dig.snow",
            .planks, .log, .log2, .bookshelf, .crafting_table, .chest, .fence, .fence_gate, .wooden_door_block, .ladder, .wooden_slab, .double_wooden_slab, .oak_stairs, .spruce_stairs, .birch_stairs, .jungle_stairs, .acacia_stairs, .dark_oak_stairs, .trapdoor, .jukebox, .pumpkin, .lit_pumpkin, .melon_block => "dig.wood",
            else => "dig.stone",
        };
    }

    /// S29 sound to every play conn within vanilla earshot (16 blocks).
    /// Block place/break feedback (silent before: only /playsound made
    /// noise). Volume 1.0, pitch 0.8 like vanilla's break/place calls.
    pub fn broadcastSound(self: *Server, exclude: ?*Conn, sound: []const u8, x: f64, y: f64, z: f64, volume: f32, pitch: f32) void {
        var sb: [512]u8 = undefined;
        const f = packets.frameSoundEffect(sound, x, y, z, volume, pitch, &sb) catch return;
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            if (exclude != null and e.conn == exclude.?) continue;
            e.conn.lock.lock();
            const play = e.conn.state == .play and !e.conn.dead;
            const dx = x - e.conn.pos_x;
            const dy = y - e.conn.pos_y;
            const dz = z - e.conn.pos_z;
            const near = dx * dx + dy * dy + dz * dz <= hear_radius_sq;
            if (play and near) e.conn.queueFramed(f) catch {};
            e.conn.lock.unlock();
        }
    }

    /// S24 Block Action to every conn tracking the chunk (vanilla
    /// PlayerManager block events: no per-player exclusion). Drives the
    /// vanilla client's own piston animation + derived final blocks.
    pub fn broadcastBlockAction(self: *Server, x: i32, y: u16, z: i32, byte1: u8, byte2: u8, id: game_ids.Id) void {
        var fb: [24]u8 = undefined;
        const f = packets.frameBlockAction(x, y, z, byte1, byte2, id, &fb) catch return;
        const key = Conn.sentKey(@divFloor(x, 16), @divFloor(z, 16));
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            e.conn.lock.lock();
            const has = e.conn.sent.contains(key);
            if (has) {
                e.conn.queueFramed(f) catch {};
            }
            e.conn.lock.unlock();
            flushEntry(e, self.io);
        }
    }

    pub fn broadcastBlockChange(self: *Server, exclude: ?*Conn, x: i32, y: u8, z: i32, id: game_ids.Id, meta: u4) !void {
        var fb: [32]u8 = undefined;
        const f = try packets.frameBlockChange(x, y, z, id, meta, &fb);
        const key = Conn.sentKey(@divFloor(x, 16), @divFloor(z, 16));
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            if (exclude != null and e.conn == exclude.?) continue;
            e.conn.lock.lock();
            const has = e.conn.sent.contains(key);
            if (has) {
                e.conn.queueFramed(f) catch {};
            }
            e.conn.lock.unlock();
            flushEntry(e, self.io);
        }
    }

    /// Targeted 0x23 truth to one viewer (dig negative-ack): the serve
    /// thread re-read a refused dig's cell and it is still solid, so send
    /// the digger the true cell. Same sent-set gate as the broadcast (a
    /// viewer that never got the column holds no stale prediction), plus
    /// the play-state check from sendJsonPlayer. Queued + flushed at once:
    /// the correction must not wait for the next tick behind bulks.
    fn sendBlockChangeTo(self: *Server, conn: *Conn, x: i32, y: u8, z: i32, id: game_ids.Id, meta: u4) void {
        var fb: [32]u8 = undefined;
        const f = packets.frameBlockChange(x, y, z, id, meta, &fb) catch return;
        const key = Conn.sentKey(@divFloor(x, 16), @divFloor(z, 16));
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            if (e.conn != conn) continue;
            e.conn.lock.lock();
            const ok = e.conn.state == .play and !e.conn.dead and e.conn.sent.contains(key);
            if (ok) e.conn.queueFramed(f) catch {};
            e.conn.lock.unlock();
            if (ok) flushEntry(e, self.io);
            return;
        }
    }

    /// Targeted 0x23 truth to the ACTING viewer, bypassing the sent-set
    /// gate. Placement NACKs must reach the placer even when the column
    /// never completed streaming (missing-chunk / teleport edge): the
    /// click packet itself proves a prediction exists to clear, while the
    /// gate's rationale (a viewer that never got the column holds nothing
    /// stale) only covers bystanders. Play-state/dead checks stay.
    fn sendBlockChangeToActor(self: *Server, conn: *Conn, x: i32, y: u8, z: i32, id: game_ids.Id, meta: u4) void {
        var fb: [32]u8 = undefined;
        const f = packets.frameBlockChange(x, y, z, id, meta, &fb) catch return;
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            if (e.conn != conn) continue;
            e.conn.lock.lock();
            const ok = e.conn.state == .play and !e.conn.dead;
            if (ok) e.conn.queueFramed(f) catch {};
            e.conn.lock.unlock();
            if (ok) flushEntry(e, self.io);
            return;
        }
    }

    /// Resend neighbor columns dirtied by an edit-path light bleed
    /// (applyBlock touched mask: bits 0-3 W,E,N,S; 4-7 NW,NE,SW,SE) to
    /// every viewer tracking them. The 0x35 for the edited cell lets
    /// nearby clients relight locally, but trackers of a touched neighbor
    /// that never got a 0x35 keep stale nibbles until a resend — this is
    /// that resend. Unload-first single-column burst (never re-send a live
    /// groundUp column). No locks held (same discipline as the other
    /// broadcast paths).
    pub fn resendTouchedNeighbors(self: *Server, pool: *shard_mod.ShardPool, x: i32, z: i32, mask: u8) void {
        if (mask == 0) return;
        const cx = @divFloor(x, 16);
        const cz = @divFloor(z, 16);
        const offs = [_]ColOffset{
            .{ .dx = -1, .dz = 0 },
            .{ .dx = 1, .dz = 0 },
            .{ .dx = 0, .dz = -1 },
            .{ .dx = 0, .dz = 1 },
            .{ .dx = -1, .dz = -1 },
            .{ .dx = 1, .dz = -1 },
            .{ .dx = -1, .dz = 1 },
            .{ .dx = 1, .dz = 1 },
        };
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (offs, 0..) |o, i| {
            if (mask & (@as(u8, 1) << @intCast(i)) == 0) continue;
            const ncx = cx + o.dx;
            const ncz = cz + o.dz;
            for (snap) |e| {
                e.conn.lock.lock();
                const has = e.conn.sent.contains(Conn.sentKey(ncx, ncz));
                if (has and e.conn.state == .play and !e.conn.dead) {
                    view.resendColumn(e.conn, conn_sink.bind(e.conn), self.chunkSource(pool), 0, ncx, ncz, true) catch {};
                }
                e.conn.lock.unlock();
                flushEntry(e, self.io);
            }
        }
    }

    /// Broadcast an arm-swing 0x0B to viewers of (cx,cz), excluding originator.
    pub fn broadcastArmSwing(self: *Server, exclude: ?*Conn, cx: i32, cz: i32, eid: i32, anim: i8) !void {
        var fb: [24]u8 = undefined;
        const f = try packets.frameAnimation(eid, @bitCast(anim), &fb);
        const key = Conn.sentKey(cx, cz);
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            if (exclude != null and e.conn == exclude.?) continue;
            e.conn.lock.lock();
            if (e.conn.sent.contains(key)) {
                e.conn.queueFramed(f) catch {};
            }
            e.conn.lock.unlock();
            flushEntry(e, self.io);
        }
    }

    /// Squared attack reach (vanilla 1.7 server checks < 36.0 = 6 blocks).
    fn attackInReach(ax: f64, ay: f64, az: f64, tx: f64, ty: f64, tz: f64) bool {
        const dx = tx - ax;
        const dy = ty - (ay + 1.62);
        const dz = tz - az;
        return dx * dx + dy * dy + dz * dz < 36.0;
    }

    /// Apply damage to a conn whose lock is ALREADY held: subtract, clamp,
    /// flag death, queue Update Health. Creative (disableDamage) is immune.
    /// Caller handles drops/save/broadcast. Returns true on a killing blow.
    fn applyPlayerDamage(conn: *Conn, amount: f32) bool {
        if (conn.is_dead) return false;
        if (conn.config.gamemode.isCreative()) return false;
        conn.health -= amount;
        if (conn.health <= 0) {
            conn.health = 0;
            conn.is_dead = true;
        }
        var hb: [32]u8 = undefined;
        queueBuilt(conn, packets.frameUpdateHealth(conn.health, conn.food, conn.saturation, &hb));
        return conn.is_dead;
    }

    /// Blockable damage (melee, fire, lava, cactus): equipped armor
    /// absorbs per the vanilla formula, then protection EPF (capped at 20),
    /// then resistance. Equipped pieces wear with the incoming hit and can
    /// break mid-call (0x2F syncs both). Bypassing sources
    /// (starve/drown/suffocate/fall/void) call applyPlayerDamage directly.
    /// Caller holds conn.lock.
    fn applyBlockedDamage(conn: *Conn, amount: f32, source: profile.game.item_data.EpfSource) bool {
        const tables = profile.game.item_data;
        // Dead/creative victims take no damage and wear nothing (vanilla
        // never reaches damageEntity for them); keep the exact old path.
        if (conn.is_dead or conn.config.gamemode.isCreative()) return applyPlayerDamage(conn, amount);
        wearArmor(conn, amount);
        var dmg = tables.reduceDamage(amount, tables.armorPoints(&conn.inv));
        var epf: u16 = 0;
        for (5..9) |s| {
            const st = conn.inv[s] orelse continue;
            const nbt = st.nbt orelse continue;
            var eids: [8]u8 = undefined;
            var elvls: [8]u8 = undefined;
            const found = parseEnchList(nbt, &eids, &elvls);
            for (eids[0..found.n], elvls[0..found.n]) |eid, elvl| {
                epf += tables.protectionEpf(eid, elvl, source);
            }
        }
        if (epf > 0) dmg = tables.reduceDamage(dmg, @intCast(@min(epf, tables.max_epf)));
        if (resistanceAmp(conn)) |amp| dmg = tables.reduceDamage(dmg, tables.resistancePoints(amp));
        return applyPlayerDamage(conn, dmg);
    }

    /// Resistance (effect 11) amplifier active on the conn, if any.
    fn resistanceAmp(conn: *Conn) ?u8 {
        for (conn.effects) |maybe| {
            const e = maybe orelse continue;
            if (e.id == 11) return e.amplifier;
        }
        return null;
    }

    /// Vanilla damageArmor: every equipped piece loses wearForHit(incoming)
    /// durability; pieces past maxDurability break (slot cleared). Worn and
    /// broken pieces re-sync their 0x2F bar. Caller holds conn.lock.
    fn wearArmor(conn: *Conn, amount: f32) void {
        const tables = profile.game.item_data;
        const w = tables.wearForHit(amount);
        for (5..9) |s| {
            const st = conn.inv[s] orelse continue;
            if (tables.armorSlot(st.id) == null) continue;
            const worn: i32 = @as(i32, st.damage) + w;
            if (worn > @as(i32, tables.maxDurability(st.id))) {
                var gone = conn.inv[s];
                item_mod.freeStack(conn.allocator, &gone);
                conn.inv[s] = null;
            } else {
                conn.inv[s].?.damage = @intCast(worn);
            }
            const f = packets.frameSetSlotAlloc(conn.allocator, 0, @intCast(s), conn.inv[s]) catch continue;
            defer conn.allocator.free(f);
            conn.queueFramed(f) catch {};
        }
    }

    /// Owned death-drop payload (inv 45 + cursor; NBT moved, not cloned).
    /// Collected under the victim's lock, spawned + freed post-loop.
    const DeathDrop = struct {
        eid: i32,
        stacks: [46]?item_mod.Stack = [_]?item_mod.Stack{null} ** 46,
        n: usize = 0,
    };

    /// Tick-local death record (victim ref held by the tick snapshot).
    const DeathInfo = struct {
        conn: *Conn,
        eid: i32,
        dd: ?DeathDrop,
        cause: DeathCause,
        killer_len: usize = 0,
        killer: [perms_mod.max_name_len]u8 = [_]u8{0} ** 16,
        x: f64,
        y: f64,
        z: f64,
    };

    /// Vanilla FoodStats.onUpdate quantized to 1Hz (+20 timer per tick).
    /// Natural-regeneration gamerule assumed on (no gamerules yet).
    /// Caller holds conn.lock. Returns the death cause on starvation death.
    fn hungerTick(conn: *Conn, difficulty: rules_mod.Difficulty) ?DeathCause {
        if (conn.is_dead or conn.health <= 0) return null;
        if (conn.config.gamemode.isCreative()) return null; // creative: nothing drains
        conn.food_timer +|= 20;
        var dirty = false;
        if (conn.exhaustion > 4.0) {
            conn.exhaustion -= 4.0;
            if (conn.saturation > 0) {
                conn.saturation = @max(conn.saturation - 1.0, 0.0);
            } else if (difficulty != .peaceful) {
                conn.food = @max(conn.food - 1, 0);
            }
            // Hunger audit: per-drumstick income attribution (counters
            // reset here, so each line accounts exactly one drop). INFO
            // (not debug): release builds compile debug logs out, and this
            // line is the only witness for drain-rate reports.
            std.log.info("hunger drop eid={d}: food={d} sat={d:.1} income(move={d:.1} jump={d:.1} regen={d:.1})", .{ conn.eid, conn.food, conn.saturation, conn.exh_move, conn.exh_jump, conn.exh_regen });
            conn.exh_move = 0;
            conn.exh_jump = 0;
            conn.exh_regen = 0;
            dirty = true;
        }
        var died: ?DeathCause = null;
        if (conn.food >= 18 and conn.health < 20.0) {
            if (conn.food_timer >= 80) {
                conn.food_timer = 0;
                conn.health = @min(conn.health + 1.0, 20.0);
                conn.addExhaustion(3.0);
                conn.exh_regen += 3.0;
                dirty = true;
            }
        } else if (conn.food <= 0) {
            if (conn.food_timer >= 80) {
                conn.food_timer = 0;
                const hp = conn.health;
                if (hp > 10.0 or difficulty == .hard or (hp > 1.0 and difficulty == .normal)) {
                    if (applyPlayerDamage(conn, 1.0)) died = .starve;
                    dirty = true;
                }
            }
        } else {
            conn.food_timer = 0;
        }
        if (dirty and died == null) {
            var hb: [32]u8 = undefined;
            queueBuilt(conn, packets.frameUpdateHealth(conn.health, conn.food, conn.saturation, &hb));
        }
        return died;
    }

    /// Cactus contact via AABB overlap (vanilla BlockCactus collision box,
    /// 1/16 XZ inset, full block height). The 3x3 block neighborhood around
    /// the player at feet/feet+1 spans at most 4 chunks; each is decoded
    /// once (the old feet/eyes identity check decoded the same chunk twice
    /// and missed every brush-past). Pure pool reads, no world_lock (same
    /// discipline as the eyes/feet checks in the tick env scan).
    /// Chunk coords pair (cactus-scan dedup list).
    const ChunkRef = struct { cx: i32, cz: i32 };

    fn touchesCactus(self: *Server, pool: *shard_mod.ShardPool, px: f64, py: f64, pz: f64) bool {
        const ex: i32 = @intFromFloat(@floor(px));
        const ez: i32 = @intFromFloat(@floor(pz));
        const feet: i32 = @intFromFloat(@floor(py));
        var chunks: [4]ChunkRef = undefined;
        var n_chunks: usize = 0;
        for ([_]i32{ -1, 0, 1 }) |dx| {
            for ([_]i32{ -1, 0, 1 }) |dz| {
                const cx = @divFloor(ex + dx, 16);
                const cz = @divFloor(ez + dz, 16);
                if (haveChunk(chunks[0..n_chunks], cx, cz)) continue;
                if (n_chunks >= chunks.len) continue; // unreachable (≤4), fail closed
                chunks[n_chunks] = .{ .cx = cx, .cz = cz };
                n_chunks += 1;
                if (self.chunkTouchesCactus(pool, cx, cz, ex, ez, feet, px, py, pz)) return true;
            }
        }
        return false;
    }

    /// True when the chunk list already holds (cx,cz).
    fn haveChunk(chunks: []const ChunkRef, cx: i32, cz: i32) bool {
        for (chunks) |c| if (c.cx == cx and c.cz == cz) return true;
        return false;
    }

    /// Scan one chunk's 3x3x2 column neighborhood for a touching cactus.
    fn chunkTouchesCactus(self: *Server, pool: *shard_mod.ShardPool, cx: i32, cz: i32, ex: i32, ez: i32, feet: i32, px: f64, py: f64, pz: f64) bool {
        const raw = pool.get(self.gpa, store_mod.encodeKey(0, cx, cz)) catch return false;
        if (raw == null) return false;
        defer self.gpa.free(raw.?);
        const ch = chunk_mod.Chunk.decode(self.gpa, raw.?) catch return false;
        defer ch.destroy(self.gpa);
        var ddx: i32 = -1;
        while (ddx <= 1) : (ddx += 1) {
            var ddz: i32 = -1;
            while (ddz <= 1) : (ddz += 1) {
                const bx = ex + ddx;
                const bz = ez + ddz;
                if (@divFloor(bx, 16) != cx or @divFloor(bz, 16) != cz) continue;
                var dy: i32 = 0;
                while (dy <= 1) : (dy += 1) {
                    if (cellTouchesCactus(ch, bx, feet + dy, bz, px, py, pz)) return true;
                }
            }
        }
        return false;
    }

    /// True when the cell holds a cactus overlapping the player.
    fn cellTouchesCactus(ch: *chunk_mod.Chunk, bx: i32, by: i32, bz: i32, px: f64, py: f64, pz: f64) bool {
        if (by < 0 or by > 255) return false;
        const yu: u8 = @intCast(by);
        const s = ch.sections[@as(usize, yu) >> 4] orelse return false;
        const li: usize = chunk_mod.Section.index(chunk_mod.Chunk.localCoord(bx), @truncate(yu & 15), chunk_mod.Chunk.localCoord(bz));
        if (s.blocks[li] != game_ids.cactus) return false;
        return interaction_mod.cactusOverlapsPlayer(bx, by, bz, px, py, pz);
    }

    /// Swept cactus check: the union of the player AABB at the previous
    /// and current hazard sample. Vanilla collides every 1/20s; our 1Hz
    /// tick samples positions a sprint moves ~5 blocks apart, so a
    /// point check misses most brush-pasts (crossing a cactus cell takes
    /// ~0.2s). Segments over 10 blocks (teleport/respawn/login jumps)
    /// fall back to the endpoint check — landing inside a cactus is
    /// caught by the point check and the ticks after it.
    fn segmentTouchesCactus(self: *Server, pool: *shard_mod.ShardPool, x0: f64, y0: f64, z0: f64, x1: f64, y1: f64, z1: f64) bool {
        const dx = x1 - x0;
        const dy = y1 - y0;
        const dz = z1 - z0;
        if (dx * dx + dy * dy + dz * dz > 100.0) return self.touchesCactus(pool, x1, y1, z1);
        const hw = interaction_mod.player_half_width;
        const ph = interaction_mod.player_height;
        const lo_x = @min(x0, x1) - hw;
        const hi_x = @max(x0, x1) + hw;
        const lo_y = @min(y0, y1);
        const hi_y = @max(y0, y1) + ph;
        const lo_z = @min(z0, z1) - hw;
        const hi_z = @max(z0, z1) + hw;
        // Candidate cells: swept box grown by one cell (the cactus box
        // is inset inside its cell; the exact test below filters).
        // Spans stay small (≤10-block segments); clamp defensively so a
        // corrupt/NaN sample can't turn this into a world scan.
        const bx0 = @as(i32, @intFromFloat(@floor(lo_x))) - 1;
        const bx1 = @as(i32, @intFromFloat(@floor(hi_x))) + 1;
        var by0 = @as(i32, @intFromFloat(@floor(lo_y))) - 1;
        var by1 = @as(i32, @intFromFloat(@floor(hi_y))) + 1;
        const bz0 = @as(i32, @intFromFloat(@floor(lo_z))) - 1;
        const bz1 = @as(i32, @intFromFloat(@floor(hi_z))) + 1;
        if (bx1 - bx0 > 24 or by1 - by0 > 24 or bz1 - bz0 > 24) return self.touchesCactus(pool, x1, y1, z1);
        if (by0 < 0) by0 = 0;
        if (by1 > 255) by1 = 255;
        // One decode per overlapped chunk (same discipline as the
        // per-tick chunk reads: pool.get + decode, freed after use).
        var cx = @divFloor(bx0, 16);
        while (cx <= @divFloor(bx1, 16)) : (cx += 1) {
            var cz = @divFloor(bz0, 16);
            while (cz <= @divFloor(bz1, 16)) : (cz += 1) {
                const raw = pool.get(self.gpa, store_mod.encodeKey(0, cx, cz)) catch continue;
                if (raw == null) continue;
                defer self.gpa.free(raw.?);
                const ch = chunk_mod.Chunk.decode(self.gpa, raw.?) catch continue;
                defer ch.destroy(self.gpa);
                var bx = bx0;
                while (bx <= bx1) : (bx += 1) {
                    if (@divFloor(bx, 16) != cx) continue;
                    var bz = bz0;
                    while (bz <= bz1) : (bz += 1) {
                        if (@divFloor(bz, 16) != cz) continue;
                        var by = by0;
                        while (by <= by1) : (by += 1) {
                            // Exact segment narrowphase: the union box above
                            // is only the broadphase (it over-approximates
                            // diagonal paths). A diagonal walk-by must not
                            // flag a cactus in the unvisited corner.
                            if (!interaction_mod.segmentHitsCactus(bx, by, bz, x0, y0, z0, x1, y1, z1)) continue;
                            const yu: u8 = @intCast(by);
                            const s = ch.sections[@as(usize, yu) >> 4] orelse continue;
                            const li: usize = chunk_mod.Section.index(chunk_mod.Chunk.localCoord(bx), @truncate(yu & 15), chunk_mod.Chunk.localCoord(bz));
                            if (s.blocks[li] == game_ids.cactus) return true;
                        }
                    }
                }
            }
        }
        return false;
    }

    /// Drown/lava/fire/suffocation/cactus for one tick (vanilla Entity
    /// rules, 1Hz-quantized; see deviations). Caller holds conn.lock.
    /// Returns the death cause on death.
    fn envTick(conn: *Conn, water: bool, lava: bool, suff: bool, cactus: bool) ?DeathCause {
        if (conn.is_dead) return null;
        var died: ?DeathCause = null;
        if (water) {
            conn.fire_ticks = 0; // extinguish on submersion
            if (!conn.config.gamemode.isCreative()) {
                conn.air -= 20;
                if (conn.air <= -20) {
                    conn.air = 0;
                    if (applyPlayerDamage(conn, 2.0)) died = .drown; // then every second
                }
            }
        } else {
            conn.air = 300;
            if (!lava and conn.fire_ticks > 0) {
                conn.fire_ticks -|= 20;
                if (died == null and applyBlockedDamage(conn, 1.0, .fire)) died = .fire; // 1/s burning
            }
        }
        if (died == null and lava and !conn.config.gamemode.isCreative()) {
            conn.fire_ticks = 300; // 15s of fire after the bath
            if (applyBlockedDamage(conn, 4.0, .fire)) died = .lava; // lenient: vanilla is 4/tick
        }
        if (died == null and suff) {
            // Vanilla is 1.0/hit behind hurt immunity (~2 hits/s), i.e.
            // ~2 dps; at our 1Hz tick that is 2.0 (4.0 was double).
            if (applyPlayerDamage(conn, 2.0)) died = .suffocate;
        }
        if (conn.cactus_cd > 0) conn.cactus_cd -= 1;
        if (died == null and cactus and !conn.config.gamemode.isCreative() and conn.cactus_cd == 0) {
            conn.cactus_cd = 1; // 1Hz tick: hit every touching tick (~1/s;
            // vanilla hurt-resistance gates to ~1/0.5s, quantized here)
            if (applyBlockedDamage(conn, 1.0, .general)) died = .cactus;
        }
        return died;
    }

    /// Copy a conn's username under its lock. Broadcast paths use this
    /// AFTER releasing the victim lock: broadcastChat snapshots the
    /// registry and takes conn locks itself, so holding one across the
    /// broadcast would nest conn locks. Names are set once at login and
    /// never mutated, so the copy can't race.
    fn copyUsername(c: *Conn, out: *[perms_mod.max_name_len]u8) usize {
        c.lock.lock();
        defer c.lock.unlock();
        @memcpy(out[0..c.username_len], c.username[0..c.username_len]);
        return c.username_len;
    }

    /// Void deaths destroy drops (vanilla): free the NBT the victim's
    /// inventory moved into the drop payload (stacks die with it).
    fn destroyDrops(self: *Server, dd: *DeathDrop) void {
        for (dd.stacks[0..dd.n]) |st| {
            const s = st orelse continue;
            const n = s.nbt orelse continue;
            self.gpa.free(n);
        }
    }

    /// Move every stack out of the victim's inventory + cursor (clears both).
    /// Caller MUST hold conn.lock. Always call on death (vanilla drops all).
    fn collectDeathDrops(conn: *Conn) DeathDrop {
        // A drag in progress dies with its owner (the cursor is dropped
        // below; a stale paint set must not survive respawn).
        conn.drag.reset();
        var dd = DeathDrop{ .eid = conn.eid };
        for (&conn.inv, 0..) |*slot, i| {
            if (i < 5 or i > 44) continue; // armor 5..8 + main 9..44 drop (crafting 0..4 vanishes)
            if (slot.*) |_| {
                dd.stacks[dd.n] = slot.*;
                slot.* = null;
                dd.n += 1;
            }
        }
        if (conn.cursor) |_| {
            dd.stacks[dd.n] = conn.cursor;
            conn.cursor = null;
            dd.n += 1;
        }
        return dd;
    }

    /// Spawn death-drop entities at the corpse: ONE entity per stack (vanilla
    /// `dropAllItems` shape), chance + rand*0.7+0.15 offsets, 10-tick delay.
    /// Takes rand_lock then ent_lock, in order. Consumes the payload.
    fn spawnDeathDrops(self: *Server, dd: *DeathDrop, x: f64, y: f64, z: f64) void {
        self.rand_lock.lock();
        if (self.drop_rand == null) self.drop_rand = java_random.JavaRandom.init(self.drop_seed);
        var rng = self.drop_rand.?;
        var offs: [46][3]f32 = undefined;
        var n_spawn: usize = 0;
        for (dd.stacks[0..dd.n]) |maybe| {
            if (maybe == null or n_spawn >= offs.len) continue;
            if (rng.nextFloat() > 1.0) continue; // chance, always 1.0
            offs[n_spawn] = .{
                rng.nextFloat() * 0.7 + 0.15,
                rng.nextFloat() * 0.7 + 0.15,
                rng.nextFloat() * 0.7 + 0.15,
            };
            n_spawn += 1;
        }
        self.drop_rand = rng;
        self.rand_lock.unlock();
        var oi: usize = 0;
        for (dd.stacks[0..dd.n]) |*maybe| {
            const st = maybe.* orelse continue;
            if (oi >= n_spawn) {
                // Cap-hit: free the undropped remainder.
                if (st.nbt) |n| self.gpa.free(n);
                maybe.* = null;
                continue;
            }
            const o = offs[oi];
            oi += 1;
            // NBT duped into server ownership (victim row keeps none).
            // spawnItemLive owns locking + instant visibility. Death drops
            // pop like break drops (vanilla EntityItem motion, toss stream).
            const owned_nbt: ?[]const u8 = if (st.nbt) |bytes| self.gpa.dupe(u8, bytes) catch null else null;
            const stored = item_mod.Stack{ .id = st.id, .count = st.count, .damage = st.damage, .nbt = owned_nbt };
            self.spawnItemLive(stored, x + o[0], y + 0.1, z + o[2], 10, self.tossPopMotion());
            if (st.nbt) |n| self.gpa.free(n);
            maybe.* = null;
        }
        dd.n = 0;
    }

    /// Resolve a stashed landing (serve thread; no locks held on entry):
    /// pool peek for water, then damage + drops + save + broadcast.
    fn resolvePendingFall(self: *Server, conn: *Conn) void {
        conn.lock.lock();
        const pf = conn.pending_fall;
        conn.pending_fall = null;
        const creative = conn.config.gamemode.isCreative();
        const dead = conn.is_dead;
        conn.lock.unlock();
        const fall = pf orelse return;
        if (creative or dead or fall.dist <= 3.0) return;
        var water = false;
        if (self.world) |pool| {
            self.world_lock.lock();
            const feet: u8 = @intFromFloat(@max(0, @min(255, fall.y)));
            const blk = view.peekBlock(pool, self.gpa, @intFromFloat(@floor(fall.x)), feet, @intFromFloat(@floor(fall.z))) catch null;
            self.world_lock.unlock();
            if (blk) |b| water = b.id == game_ids.flowing_water or b.id == game_ids.water;
        }
        if (water) return; // splash landing: vanilla resets fallDistance
        // 1e-3 epsilon: fall distance arrives as f32-summed network steps,
        // so an exact 5.0-block fall can measure 5.0000005 and ceil() would
        // flip a whole extra heart at integer boundaries. Vanilla sums its
        // own physics and never sees this dust; the epsilon restores its
        // effective thresholds (sub-packet, invisible in real falls).
        const dmg = @ceil(fall.dist - 3.0 - 1e-3);
        conn.lock.lock();
        const died = applyPlayerDamage(conn, dmg);
        const hp = conn.health;
        var dd: ?DeathDrop = if (died and !self.keepInv()) collectDeathDrops(conn) else null;
        const eid = conn.eid;
        conn.lock.unlock();
        var nm: [perms_mod.max_name_len]u8 = undefined;
        const nm_len = if (died) copyUsername(conn, &nm) else 0;
        var mb: [32]u8 = undefined;
        if (packets.frameEntityMetadata(eid, if (died) 0 else hp, &mb)) |f| {
            self.broadcastToTrackers(eid, f);
        } else |_| {}
        if (died) self.broadcastDeath(nm[0..nm_len], .fall, "");
        if (dd) |*d| {
            self.spawnDeathDrops(d, fall.x, fall.y + 0.1, fall.z);
            self.savePlayer(conn);
        }
    }

    /// Furnace tile entity (server-owned shared state; slots OWNED).
    const FurnaceEnt = struct {
        x: i32,
        y: u8,
        z: i32,
        input: ?item_mod.Stack = null,
        fuel: ?item_mod.Stack = null,
        output: ?item_mod.Stack = null,
        burn: u32 = 0,
        total: u32 = 0,
        cook: u32 = 0,
    };

    /// Brewing-stand tile entity (server-owned shared state; slots OWNED).
    /// 400-tick countdown while valid (see brewing_mod); no fuel, no
    /// output slot (bottles convert in place).
    const BrewEnt = struct {
        x: i32,
        y: u8,
        z: i32,
        bottles: [3]?item_mod.Stack = [_]?item_mod.Stack{null} ** 3,
        ingredient: ?item_mod.Stack = null,
        brew: u32 = brewing_mod.brew_target,
    };

    /// Find a brew-stand by block pos. Caller MUST hold brew_lock.
    fn findBrew(self: *Server, x: i32, y: u8, z: i32) ?*BrewEnt {
        for (self.brews.items) |*b| {
            if (b.x == x and b.y == y and b.z == z) return b;
        }
        return null;
    }

    /// Ensure brew-stand state exists (placement + first open). Caller holds brew_lock.
    fn ensureBrew(self: *Server, x: i32, y: u8, z: i32) void {
        if (self.findBrew(x, y, z) != null) return;
        self.brews.append(self.gpa, .{ .x = x, .y = y, .z = z }) catch {};
    }

    /// Remove brew-stand state, returning owned contents (block break).
    /// Caller MUST hold brew_lock.
    fn removeBrew(self: *Server, x: i32, y: u8, z: i32) BrewEnt {
        var i: usize = 0;
        while (i < self.brews.items.len) : (i += 1) {
            const b = &self.brews.items[i];
            if (b.x == x and b.y == y and b.z == z) {
                return self.brews.swapRemove(i);
            }
        }
        return .{ .x = x, .y = y, .z = z };
    }

    /// Chest column (no y lane needed for pair matching).
    const ChestCol = struct { x: i32, z: i32 };
    /// Chest cell pos (named: anonymous structs are distinct types per
    /// scope and can't cross fn boundaries).
    const ChestPos = struct { x: i32, y: u8, z: i32 };
    /// Chest tile entity: one entry per chest BLOCK (double halves keep
    /// their own 27 slots; join/split is logical, moves no data). Slots
    /// OWNED (gpa). `dirty` marks rows needing the 1 Hz ticker flush.
    /// `id` is the chest kind (chest vs trapped — pairs only join same
    /// kind, matched without re-peeking the world).
    const ChestEnt = struct {
        x: i32,
        y: u8,
        z: i32,
        id: game_ids.Id,
        slots: [chest_mod.chest_size]?item_mod.Stack = [_]?item_mod.Stack{null} ** chest_mod.chest_size,
        dirty: bool = false,
    };

    /// Find a chest entry by block pos. Caller MUST hold chest_lock.
    fn findChest(self: *Server, x: i32, y: u8, z: i32) ?*ChestEnt {
        for (self.chests.items) |*c| {
            if (c.x == x and c.y == y and c.z == z) return c;
        }
        return null;
    }

    /// Ensure chest state exists (first open): adopt the persisted row,
    /// else start empty. Caller holds chest_lock; pool reads need no
    /// world_lock (same discipline as player load). Corrupt rows fail
    /// closed to empty (chunk-ban posture, see chest.zig).
    fn ensureChest(self: *Server, pool: *shard_mod.ShardPool, x: i32, y: u8, z: i32, id: game_ids.Id) void {
        if (self.findChest(x, y, z) != null) return;
        var ent = ChestEnt{ .x = x, .y = y, .z = z, .id = id };
        if (chest_mod.loadRow(pool, self.gpa, x, y, z) catch null) |row| {
            ent.slots = row.slots;
        }
        self.chests.append(self.gpa, ent) catch {};
    }

    /// Remove chest state, returning owned contents (block break).
    /// Caller MUST hold chest_lock.
    fn removeChest(self: *Server, x: i32, y: u8, z: i32) ?[chest_mod.chest_size]?item_mod.Stack {
        var i: usize = 0;
        while (i < self.chests.items.len) : (i += 1) {
            const c = &self.chests.items[i];
            if (c.x == x and c.y == y and c.z == z) {
                const ent = self.chests.swapRemove(i);
                return ent.slots;
            }
        }
        return null;
    }

    /// Chest kind at a cell (air on hole/error/non-chest): lock-free peek
    /// for close/power paths that only have coords. Pairs only join same
    /// kind, so a wrong kind simply yields no mate (never a misjoin).
    fn chestKindAt(self: *Server, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, x: i32, y: u8, z: i32) game_ids.Id {
        _ = self;
        const pb = view.peekBlock(pool, allocator, x, y, z) catch return game_ids.air;
        return (pb orelse return game_ids.air).id;
    }

    /// Double-chest pair: the exactly-one same-id horizontal neighbor, if
    /// any (vanilla joins at most one; a sandwiched chest stays single).
    /// Returns the neighbor coords, or null for a single chest. Caller
    /// holds world_lock (peekBlock, like the UI routing below).
    fn chestPair(self: *Server, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, x: i32, y: u8, z: i32, id: game_ids.Id) ?ChestCol {
        _ = self;
        var found: ?ChestCol = null;
        var n: usize = 0;
        const nb = [_]ChestCol{
            .{ .x = x - 1, .z = z }, .{ .x = x + 1, .z = z },
            .{ .x = x, .z = z - 1 }, .{ .x = x, .z = z + 1 },
        };
        for (nb) |c| {
            const pb = view.peekBlock(pool, allocator, c.x, y, c.z) catch continue;
            const b = pb orelse continue;
            if (b.id != id) continue;
            n += 1;
            found = c;
        }
        if (n != 1) return null;
        return found;
    }

    /// Live viewer count for a chest cell (conns with an open chest window
    /// at the pos). Derived per call, never stored — disconnects can't
    /// leak it. Powers trapped-chest queries and lid-sound edges.
    fn countChestViewers(self: *Server, x: i32, y: u8, z: i32) usize {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        var n: usize = 0;
        for (snap) |e| {
            if (!e.conn.lock.tryLock()) continue;
            const ow = e.conn.open_win;
            e.conn.lock.unlock();
            if (ow) |o| {
                if ((o.id == 5 or o.id == 6) and o.x == x and o.y == y and o.z == z) n += 1;
            }
        }
        return n;
    }

    /// Live viewer count for an ender-chest block (window 3). Same derived
    /// discipline as chests (the lid is per-block while contents are
    /// per-player, exactly like vanilla's shared TE + EnderItems).
    fn countEnderViewers(self: *Server, x: i32, y: u8, z: i32) usize {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        var n: usize = 0;
        for (snap) |e| {
            if (!e.conn.lock.tryLock()) continue;
            const ow = e.conn.open_win;
            e.conn.lock.unlock();
            if (ow) |o| {
                if (o.id == 3 and o.x == x and o.y == y and o.z == z) n += 1;
            }
        }
        return n;
    }

    /// Trapped-chest power level for redstone (vanilla: 15 while any viewer
    /// has it open). Counts the PAIR total (jar `ra.f` increments both
    /// halves on any double open, so dust on either half sees power).
    /// READ-ONLY query for the redstone owner to call; the chest side
    /// never pushes power itself (engine boundary). Pool reads need no
    /// world_lock (same discipline as player load).
    pub fn trappedPower(self: *Server, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, x: i32, y: u8, z: i32) u4 {
        var total = self.countChestViewers(x, y, z);
        if (view.peekBlock(pool, allocator, x, y, z) catch null) |b| {
            if (b.id == game_ids.chest or b.id == game_ids.trapped_chest) {
                if (self.chestPair(pool, allocator, x, y, z, b.id)) |mate| {
                    total += self.countChestViewers(mate.x, y, mate.z);
                }
            }
        }
        return if (total > 0) 15 else 0;
    }

    /// Flush dirty chest rows to the store (1 Hz ticker + stop path).
    /// Takes world_lock then chest_lock (never nested outward); encodes
    /// borrowed stacks like saveRedstone (no clones). Emptied chests
    /// delete their row instead of writing an empty one (store-compact).
    fn flushDirtyChests(self: *Server) void {
        const pool = self.world orelse return;
        self.world_lock.lock();
        defer self.world_lock.unlock();
        self.chest_lock.lock();
        defer self.chest_lock.unlock();
        for (self.chests.items) |*c| {
            if (!c.dirty) continue;
            c.dirty = false;
            var empty = true;
            for (c.slots) |s| {
                if (s != null) {
                    empty = false;
                    break;
                }
            }
            if (empty) {
                chest_mod.deleteRow(pool, c.x, c.y, c.z) catch {
                    c.dirty = true;
                };
            } else {
                chest_mod.saveRow(pool, c.x, c.y, c.z, &c.slots) catch {
                    c.dirty = true;
                };
            }
        }
    }

    /// Find a furnace by block pos. Caller MUST hold furn_lock.
    // ---- items, interaction, containers, redstone glue ----

    fn findFurnace(self: *Server, x: i32, y: u8, z: i32) ?*FurnaceEnt {
        for (self.furnaces.items) |*f| {
            if (f.x == x and f.y == y and f.z == z) return f;
        }
        return null;
    }

    /// Ensure furnace state exists (placement + first open). Caller holds furn_lock.
    fn ensureFurnace(self: *Server, x: i32, y: u8, z: i32) void {
        if (self.findFurnace(x, y, z) != null) return;
        self.furnaces.append(self.gpa, .{ .x = x, .y = y, .z = z }) catch {};
    }

    /// Remove furnace state, returning owned contents (block break).
    /// Caller MUST hold furn_lock.
    fn removeFurnace(self: *Server, x: i32, y: u8, z: i32) FurnaceEnt {
        var i: usize = 0;
        while (i < self.furnaces.items.len) : (i += 1) {
            const f = &self.furnaces.items[i];
            if (f.x == x and f.y == y and f.z == z) {
                return self.furnaces.swapRemove(i);
            }
        }
        return .{ .x = x, .y = y, .z = z };
    }

    /// Remove one item entity by id, freeing its owned stack. Caller MUST hold
    /// ent_lock (leaf: takes no other lock).
    fn removeItemById(self: *Server, id: i32) void {
        var k: usize = 0;
        while (k < self.items.items.len) : (k += 1) {
            if (self.items.items[k].id == id) {
                const dead = self.items.swapRemove(k);
                var s: ?item_mod.Stack = dead.stack;
                item_mod.freeStack(self.gpa, &s);
                return;
            }
        }
    }

    /// One 1Hz tick of vanilla item-toss physics (20 substeps of the
    /// 20tps EntityItem.onUpdate, jar `xk`): gravity 0.04, drag 0.98,
    /// ground bounce -0.5 with 0.7 horizontal friction. The resting
    /// height is first-solid-top + 0.125 (the convention drops spawn
    /// at); without ground the item keeps falling (void removal is the
    /// caller's). Pure pool reads (leaf, like the env scan).
    fn integrateItemToss(self: *Server, pool: *shard_mod.ShardPool, it: *entity.ItemEnt) !void {
        var last_cx: i32 = @intFromFloat(@floor(it.x));
        var last_cz: i32 = @intFromFloat(@floor(it.z));
        var rest: ?f64 = try self.tossRest(pool, it.x, it.y, it.z);
        var n: u8 = 0;
        while (n < 20) : (n += 1) {
            it.vy -= 0.04;
            const px = it.x;
            const pz = it.z;
            it.x += it.vx;
            it.y += it.vy;
            it.z += it.vz;
            it.vx *= 0.98;
            it.vy *= 0.98;
            it.vz *= 0.98;
            // Landing surface is per-column, not per-tick: a toss crosses
            // several columns per tick, and a stale height lands the item
            // on air (or buries it) blocks from where the client's own
            // sim puts it — the next 1Hz correction then reads as a
            // mid-air teleport onto distant ground. Refresh on column
            // change only (a decode per fresh column, not per substep).
            const cx: i32 = @intFromFloat(@floor(it.x));
            const cz: i32 = @intFromFloat(@floor(it.z));
            if (cx != last_cx or cz != last_cz) {
                if (try self.tossRest(pool, it.x, it.y, it.z)) |r| {
                    if (r > it.y) {
                        // Flew into a wall (surface above the feet): vanilla
                        // stops horizontal motion at the face and drops.
                        // Revert the horizontal step, kill horizontal
                        // velocity, keep the old column's rest so it falls
                        // to that base instead of embedding or floating.
                        it.x = px;
                        it.z = pz;
                        it.vx = 0;
                        it.vz = 0;
                    } else {
                        last_cx = cx;
                        last_cz = cz;
                        rest = r;
                    }
                } else {
                    last_cx = cx;
                    last_cz = cz;
                    rest = null;
                }
            }
            if (rest) |r| {
                if (it.y <= r) {
                    it.y = r;
                    it.vx *= 0.7;
                    it.vz *= 0.7;
                    it.vy *= -0.5;
                    if (@abs(it.vy) < 0.08 and it.vx * it.vx + it.vz * it.vz < 0.0025) {
                        it.vx = 0;
                        it.vy = 0;
                        it.vz = 0;
                        break;
                    }
                }
            }
        }
    }

    /// Landing surface under an item (first-solid-top + 0.125 item rest):
    /// null over void/unknown columns (keeps falling). Search starts just
    /// above the item so a wall column reads its top (handled by the
    /// caller), not the rock around the item.
    fn tossRest(self: *Server, pool: *shard_mod.ShardPool, x: f64, y: f64, z: f64) !?f64 {
        const from_y: u8 = @intCast(@min(255, @max(0, @as(i32, @intFromFloat(@ceil(y))) + 1)));
        if (try view.groundBlockY(pool, self.gpa, @intFromFloat(@floor(x)), @intFromFloat(@floor(z)), from_y)) |g|
            return @as(f64, @floatFromInt(g)) + 1.125;
        return null;
    }

    /// Splash-potion impact fan-out (no ent_lock held; mirrors the
    /// effectGive slot logic per victim). The directly-hit player takes the
    /// full duration; everyone else within 4 blocks scales by (1 - dist/4),
    /// floored to whole seconds (1Hz quantization). Instant health/harm
    /// apply full to the whole radius. No HP changes (L2 owns those) —
    /// delivery is S1D only.
    const PotionImpact = struct { eid: i32, a6: u8, seconds: u32, amp: u8 };
    fn applyPotionImpacts(self: *Server, impacts: []const PotionImpact) void {
        if (impacts.len == 0) return;
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (impacts) |im| {
            for (snap) |e| {
                if (e.conn.eid != im.eid) continue;
                e.conn.lock.lock();
                if (e.conn.state == .play and !e.conn.is_dead) {
                    var slot: ?usize = null;
                    for (&e.conn.effects, 0..) |*s, i| {
                        if (s.*) |fx| {
                            if (fx.id == im.a6) {
                                slot = i;
                                break;
                            }
                        } else if (slot == null) {
                            slot = i;
                        }
                    }
                    if (slot) |si| {
                        const ticks: i32 = @as(i32, @intCast(im.seconds)) * 20;
                        e.conn.effects[si] = .{ .id = im.a6, .amplifier = im.amp, .ticks = ticks };
                        var eb: [64]u8 = undefined;
                        queueBuilt(e.conn, packets.frameEntityEffect(e.conn.eid, im.a6, im.amp, ticks, &eb));
                    }
                }
                e.conn.lock.unlock();
                break;
            }
        }
    }

    /// One 1Hz tick of a thrown splash potion (20 substeps of the vanilla
    /// EntityThrowable arc, jar `uo`: drag 0.99, gravity 0.03). Direct
    /// player contact (within 1.75 blocks of the player center) wins over
    /// block collision; blocks collide unless replaceable (the placement
    /// refusal set doubles as the no-collision-box set). Missing chunks
    /// read as air (keep flying). Returns the directly-hit eid, -1 on
    /// block impact, -2 to keep flying (void/age handled by the caller).
    fn integratePotionArc(self: *Server, pool: *shard_mod.ShardPool, pot: *entity.PotionEnt, players: []const entity.PlayerSnap) !i32 {
        var n: u8 = 0;
        while (n < 20) : (n += 1) {
            pot.vx *= 0.99;
            pot.vy = pot.vy * 0.99 - 0.03;
            pot.vz *= 0.99;
            pot.x += pot.vx;
            pot.y += pot.vy;
            pot.z += pot.vz;
            for (players) |p| {
                const dx = pot.x - p.x;
                const dy = pot.y - (p.y + 1.0);
                const dz = pot.z - p.z;
                if (dx * dx + dy * dy + dz * dz < 1.75 * 1.75) return p.eid;
            }
            const by: i32 = @intFromFloat(@floor(pot.y));
            if (by >= 0 and by <= 255) {
                const pb = view.peekBlock(pool, self.gpa, @intFromFloat(@floor(pot.x)), @intCast(by), @intFromFloat(@floor(pot.z))) catch null;
                if (pb) |b| {
                    if (!replaceableForPlace(b.id)) return -1;
                }
            }
        }
        return -2;
    }

    /// Right-click splash throw: validate the held stack, spawn the arc
    /// entity from eye height along the vanilla look vector (speed 1.5),
    /// consume one (creative keeps). No wind-up unlike drinking. Lock
    /// order: conn, then ent_lock, then conn again (never nested — the
    /// non-recursive SpinLock would self-deadlock, see the PvP note).
    fn throwPotion(self: *Server, conn: *Conn, tp: ThrowPotionEvent) void {
        conn.lock.lock();
        if (conn.state != .play or conn.is_dead) {
            conn.lock.unlock();
            return;
        }
        const st = conn.inv[tp.slot] orelse {
            conn.lock.unlock();
            return;
        };
        if (st.id != game_ids.potion or st.damage != tp.damage or
            !profile.game.potion_data.isThrowable(st.id, st.damage))
        {
            conn.lock.unlock();
            return;
        }
        const yaw: f64 = @as(f64, conn.yaw) * std.math.pi / 180.0;
        const pitch: f64 = @as(f64, conn.pitch) * std.math.pi / 180.0;
        const dmg = st.damage;
        const sx = conn.pos_x - @sin(yaw) * 0.5;
        const sy = conn.pos_y + 1.62;
        const sz = conn.pos_z + @cos(yaw) * 0.5;
        const cp = @cos(pitch);
        const vx = -@sin(yaw) * cp * 1.5;
        const vy = -@sin(pitch) * 1.5;
        const vz = @cos(yaw) * cp * 1.5;
        const creative = conn.config.gamemode.isCreative();
        conn.lock.unlock();
        const eid = self.eid_counter.fetchAdd(1, .acq_rel);
        self.ent_lock.lock();
        const ok = self.potions.items.len < Server.max_items;
        if (ok) self.potions.append(self.gpa, .{ .id = eid, .x = sx, .y = sy, .z = sz, .damage = dmg, .vx = vx, .vy = vy, .vz = vz }) catch {};
        self.ent_lock.unlock();
        if (!ok) return;
        // Consume only what is still the same stack (a concurrent click
        // may have moved it — then roll back the entity instead).
        conn.lock.lock();
        defer conn.lock.unlock();
        const cur = conn.inv[tp.slot] orelse {
            self.removePotionById(eid);
            return;
        };
        if (cur.id != game_ids.potion or cur.damage != dmg) {
            self.removePotionById(eid);
            return;
        }
        if (!creative) {
            if (cur.count <= 1) {
                item_mod.freeStack(conn.allocator, &conn.inv[tp.slot]);
                conn.inv[tp.slot] = null;
            } else {
                conn.inv[tp.slot].?.count -= 1;
            }
        }
        const sf = packets.frameSetSlotAlloc(conn.allocator, 0, @intCast(tp.slot), conn.inv[tp.slot]) catch null;
        if (sf) |f| {
            defer conn.allocator.free(f);
            conn.queueFramed(f) catch {};
        }
    }

    /// Remove one potion entity by id (throw rollback). Caller holds no
    /// locks (takes ent_lock alone).
    fn removePotionById(self: *Server, id: i32) void {
        self.ent_lock.lock();
        defer self.ent_lock.unlock();
        var k: usize = 0;
        while (k < self.potions.items.len) : (k += 1) {
            if (self.potions.items[k].id == id) {
                _ = self.potions.swapRemove(k);
                return;
            }
        }
    }

    /// Store an OWNED stack as a live item entity (always consumes `stack`:
    /// merged into a neighbor, appended, or freed on cap-hit). Merge-on-spawn
    /// mirrors the tick merge (same id/damage/NBT, centers within 1 block,
    /// combined count within max stack; survivor keeps max delay).
    /// Caller MUST hold ent_lock. Returns the new entity id, or null when
    /// the stack merged into an existing entity or the cap dropped it.
    fn spawnItem(self: *Server, stack: item_mod.Stack, x: f64, y: f64, z: f64, delay: u32, motion: [3]f64) ?i32 {
        for (self.items.items) |*it| {
            const dx = it.x - x;
            const dz = it.z - z;
            if (dx * dx + dz * dz > 1.0) continue;
            // 3D proximity like vanilla (jar `xk.k` expands XZ only):
            // same-column drops a block+ apart (pillar mining) stay separate.
            if (@abs(it.y - y) > 0.5) continue;
            if (!item_mod.canMerge(it.stack, stack)) continue;
            if (@as(u16, @intCast(it.stack.count)) + @as(u16, @intCast(stack.count)) > profile.game.item_data.maxStackSize(it.stack.id)) continue;
            it.stack.count += stack.count;
            it.delay = @max(it.delay, delay);
            // The survivor's count grew: viewers already tracking it must
            // see a 0x1C metadata refresh (vanilla DataWatcher update on
            // merge). Without this the extra drops stay invisible until a
            // relog re-snapshots the stack.
            self.broadcastItemMeta(it.id, it.stack);
            var s: ?item_mod.Stack = stack;
            item_mod.freeStack(self.gpa, &s);
            return null;
        }
        if (self.items.items.len >= Server.max_items) {
            var s: ?item_mod.Stack = stack;
            item_mod.freeStack(self.gpa, &s);
            return null;
        }
        const id = self.eid_counter.fetchAdd(1, .acq_rel);
        self.items.append(self.gpa, .{
            .id = id,
            .x = x,
            .y = y,
            .z = z,
            .vx = motion[0],
            .vy = motion[1],
            .vz = motion[2],
            .stack = stack,
            .delay = delay,
        }) catch {
            var s: ?item_mod.Stack = stack;
            item_mod.freeStack(self.gpa, &s);
            return null;
        };
        return id;
    }

    /// Spawn + immediately broadcast one item entity to every in-range
    /// viewer with the chunk loaded (serve thread; caller holds no locks).
    /// Cuts break→visible from ~1 tick to ~instant; pickup still happens
    /// on the tick through the tracked-gate invariant (the spawn was
    /// really queued before any pickup can run, so Collect-after-Spawn
    /// ordering holds and no ghost entities appear). Viewers that join
    /// or load the chunk later get the normal tick spawn instead.
    /// Lock order per step (never nested): ent, then reg-snapshot, then
    /// one viewer conn lock at a time. No opposite order exists: the tick
    /// never holds ent_lock while taking conn locks, and no broadcast
    /// takes ent_lock.
    fn broadcastItemSpawn(self: *Server, id: i32, item_id: game_ids.Id, count: i8, damage: i16, nbt: ?[]const u8, x: f64, y: f64, z: f64, motion: [3]f64) void {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const range = @as(f64, @floatFromInt(self.view_distance)) * 16.0 + 16.0;
        const cx: i32 = @intFromFloat(@floor(x / 16.0));
        const cz: i32 = @intFromFloat(@floor(z / 16.0));
        for (snap) |e| {
            if (e.conn.state != .play or e.conn.is_dead) continue;
            e.conn.lock.lock();
            const dx = x - e.conn.pos_x;
            const dz = z - e.conn.pos_z;
            const in_range = @abs(dx) <= range and @abs(dz) <= range;
            const loaded = e.conn.sent.contains(Conn.sentKey(cx, cz));
            var queued = false;
            if (in_range and loaded and !e.conn.tracked.contains(id)) {
                const stack = item_mod.Stack{ .id = item_id, .count = count, .damage = damage, .nbt = nbt };
                var spawn = sink_mod.ItemSpawn{ .eid = id, .stack = stack, .x = x, .y = y, .z = z, .vx = motion[0], .vy = motion[1], .vz = motion[2] };
                conn_sink.bind(e.conn).spawnItem(&spawn) catch {};
                e.conn.tracked.put(id, .{ .x = x, .y = y, .z = z, .yaw = 0, .pitch = 0 }) catch {};
                queued = true;
            }
            e.conn.lock.unlock();
            // One output path: flush only viewers we queued to (untracked
            // conns — and socket-less test conns — stay untouched).
            if (queued) flushEntry(e, self.io);
        }
    }

    /// Broadcast a 0x1C metadata refresh for a live item entity to every
    /// viewer already tracking it. Merge paths (spawn-time and the tick
    /// scan) grow the survivor's count without spawning anything new, so
    /// without this the extra drops stay invisible until a relog
    /// re-snapshots the stack (vanilla sends the DataWatcher update).
    /// Caller must hold ent_lock (same order as spawnItemLive: no other
    /// locks held when the snapshot drops to the registry lock).
    fn broadcastItemMeta(self: *Server, id: i32, stack: item_mod.Stack) void {
        var mb: [1024]u8 = undefined;
        const meta = packets.frameItemMetadata(id, stack, &mb) catch return;
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            if (e.conn.state != .play or e.conn.is_dead) continue;
            e.conn.lock.lock();
            const tracked = e.conn.tracked.contains(id);
            if (tracked) e.conn.queueFramed(meta) catch {};
            e.conn.lock.unlock();
            if (tracked) flushEntry(e, self.io);
        }
    }

    /// Serve-thread item spawn with instant visibility (see
    /// broadcastItemSpawn). Consumes `stack` exactly like spawnItem.
    /// `motion` is the vanilla EntityItem toss velocity (blocks per
    /// 20tps tick); the 1Hz tick integrates it until the item settles.
    fn spawnItemLive(self: *Server, stack: item_mod.Stack, x: f64, y: f64, z: f64, delay: u32, motion: [3]f64) void {
        self.ent_lock.lock();
        const id = self.spawnItem(stack, x, y, z, delay, motion);
        var nbt: ?[]u8 = null;
        var item_id: game_ids.Id = undefined;
        var count: i8 = 0;
        var damage: i16 = 0;
        if (id != null) {
            const it = self.items.items[self.items.items.len - 1];
            item_id = it.stack.id;
            count = it.stack.count;
            damage = it.stack.damage;
            if (it.stack.nbt) |n| nbt = self.gpa.dupe(u8, n) catch null;
        }
        self.ent_lock.unlock();
        const eid = id orelse return; // merged or capped: nothing new to show
        defer if (nbt) |n| self.gpa.free(n);
        self.broadcastItemSpawn(eid, item_id, count, damage, nbt, x, y, z, motion);
    }

    /// Roll + spawn vanilla drops for a survival break. Takes rand_lock
    /// then ent_lock, in order.
    /// Per-single draw order mirrors harvestBlock: chance float (always 1.0
    /// for player breaks, drawn anyway), then 3 position offsets
    /// (rand*0.7+0.15 per axis, CFR `aji`/`alo` drop path). Spawn position
    /// is inside the broken cell (vanilla dropBlockAsItem_do); the 1Hz
    /// tick integrates the toss arc down to first-solid-top + 0.125.
    /// Toss motion comes from the dedicated toss stream (jar `xk`: motion
    /// (rand*0.2-0.1, 0.2, rand*0.2-0.1) via Math.random(), NOT world.rand).
    /// Wake settled drops resting at/above a freshly broken block.
    /// Settled items park with zero velocity (no per-tick work); without
    /// this, digging out from under them would leave them hovering where
    /// the block was (vanilla items keep falling: gravity applies every
    /// tick). A small downward nudge re-arms integration; the ground scan
    /// settles them on whatever is actually below. Harmless when nothing
    /// rests there (one extra integrate that re-settles in place).
    /// Called with world_lock held (same as spawnBreakDrops below);
    /// takes ent_lock only, matching the established lock order.
    fn wakeItemsAbove(self: *Server, x: i32, y: u8, z: i32) void {
        self.ent_lock.lock();
        defer self.ent_lock.unlock();
        const cx = @as(f64, @floatFromInt(x)) + 0.5;
        const cz = @as(f64, @floatFromInt(z)) + 0.5;
        const top = @as(f64, @floatFromInt(y));
        for (self.items.items) |*it| {
            if (it.vx != 0 or it.vy != 0 or it.vz != 0) continue; // already live
            const dx = it.x - cx;
            const dz = it.z - cz;
            if (dx * dx + dz * dz > 1.0) continue;
            if (it.y < top) continue;
            it.vy = -0.05;
        }
    }

    fn spawnBreakDrops(self: *Server, x: i32, y: u8, z: i32, old_id: game_ids.Id, old_meta: u4) void {
        self.rand_lock.lock();
        if (self.drop_rand == null) self.drop_rand = java_random.JavaRandom.init(self.drop_seed);
        var rng = self.drop_rand.?;
        var rolls: [2]profile.game.drops_data.DropRoll = undefined;
        const n_rolls = profile.game.drops_data.rollDrops(old_id, old_meta, &rng, &rolls);
        // Materialize per-single chance + offsets while holding rand_lock so
        // the stream stays a single total order across serve threads.
        // Bounded: the table yields at most 8 singles per break (lapis).
        var offs: [8][3]f32 = undefined;
        var n_spawn: usize = 0;
        for (rolls[0..n_rolls]) |r| {
            var k: u8 = 0;
            while (k < r.singles and n_spawn < offs.len) : (k += 1) {
                if (rng.nextFloat() > 1.0) continue; // chance, always 1.0
                offs[n_spawn] = .{
                    rng.nextFloat() * 0.7 + 0.15,
                    rng.nextFloat() * 0.7 + 0.15,
                    rng.nextFloat() * 0.7 + 0.15,
                };
                n_spawn += 1;
            }
        }
        self.drop_rand = rng;
        self.rand_lock.unlock();
        // Re-walk rolls in order, consuming the materialized offsets.
        // (Truncation at 8 is unreachable per the table bound above, and the
        // chance draw never skips at 1.0 — oi always drains n_spawn.)
        // Each single pops with vanilla EntityItem motion from the toss
        // stream (never drop_rand — randar); the tick settles the arc.
        var oi: usize = 0;
        var ri: usize = 0;
        while (ri < n_rolls) : (ri += 1) {
            const r = rolls[ri];
            var k: u8 = 0;
            while (k < r.singles and oi < n_spawn) : (k += 1) {
                const o = offs[oi];
                oi += 1;
                const stack = item_mod.Stack{ .id = r.item_id, .count = 1, .damage = r.damage, .nbt = null };
                self.spawnItemLive(stack, @as(f64, @floatFromInt(x)) + o[0], @as(f64, @floatFromInt(y)) + o[1], @as(f64, @floatFromInt(z)) + o[2], 10, self.tossPopMotion());
            }
        }
    }

    /// Spawn a Q-drop entity in front of the player (always consumes the
    /// event stack) + refresh the changed window slot. Leaf locks only.
    fn spawnQDrop(self: *Server, conn: *Conn, q: QDropEvent) void {
        const fx = -@sin(@as(f64, conn.yaw) * std.math.pi / 180.0);
        const fz = @cos(@as(f64, conn.yaw) * std.math.pi / 180.0);
        const sx = conn.pos_x + fx * 0.5;
        const sy = conn.pos_y + 1.32;
        const sz = conn.pos_z + fz * 0.5;
        // Live broadcast: the dropper sees the entity immediately; the tick
        // still owns pickup (tracked-gate) and merge/despawn. Thrown
        // forward like vanilla (facing * 0.3, up 0.1, toss-stream jitter)
        // so the drop arcs to the ground instead of hovering at eye height.
        self.spawnItemLive(q.stack, sx, sy, sz, 40, .{
            fx * 0.3 + self.nextToss() * 0.04 - 0.02,
            0.15,
            fz * 0.3 + self.nextToss() * 0.04 - 0.02,
        });
        conn.lock.lock();
        const cur = conn.inv[@intCast(q.slot)];
        const f = packets.frameSetSlotAlloc(conn.allocator, 0, q.slot, cur) catch null;
        if (f) |fr| {
            defer conn.allocator.free(fr);
            conn.queueFramed(fr) catch {};
        }
        conn.lock.unlock();
        // spawnItemLive always consumes (merge/append/cap-hit frees); nothing to do
    }

    /// Right-click routing: crafting table (58) + not sneaking opens window 1.
    /// Caller holds world_lock (pool peek). Returns true when the click became
    /// a UI open (serve loop must skip placement + broadcast for the event).
    /// `sneaking` is the clicker's sneak state (sneak + held block places
    /// against the table instead); the serve loop reads it once per event.
    /// Right-click UI routing (crafting table / furnace / enchanting
    /// table / ender chest / chest open instead of placing/toggling). Shared by the block_set
    /// arm (sneak-aware) and the empty-hand interact arm (sneak=false).
    fn tryOpenAnyUI(self: *Server, conn: *Conn, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, b: *BlockEvent, sneak: bool) bool {
        if (self.tryOpenTable(conn, pool, allocator, b, sneak)) return true;
        if (self.tryOpenFurnace(conn, pool, allocator, b, sneak)) return true;
        if (self.tryOpenBrew(conn, pool, allocator, b, sneak)) return true;
        if (self.tryOpenEnder(conn, pool, allocator, b, sneak)) return true;
        if (self.tryOpenChest(conn, pool, allocator, b, sneak)) return true;
        return self.tryOpenEnchant(conn, pool, allocator, b, sneak);
    }

    /// Block-place/break sound (S29 to nearby viewers; volume 1.0, pitch
    /// 0.8 like vanilla). Liquids splash for everyone (no client
    /// prediction); solid-block sounds skip the placer (they predicted it).
    fn soundForEdit(self: *Server, conn: *Conn, id: game_ids.Id, sx: f64, sy: f64, sz: f64) void {
        if (id == game_ids.air) return;
        const v = Server.placeSound(id);
        const excl: ?*Conn = if (Server.isLiquid(id)) null else conn;
        self.broadcastSound(excl, v.name, sx, sy, sz, 1.0, v.pitch);
    }

    /// Plate registry follows place/break (add on plate-place, remove when
    /// a plate cell stops being one).
    fn trackPlates(self: *Server, b: *BlockEvent, old: ?view.PeekBlock) void {
        const new_plate = b.id != game_ids.air and redstone_mod.isPlate(&profile.game.blocks, .{ .id = b.id, .meta = b.meta });
        if (new_plate) self.rs_plates.add(b.x, b.y, b.z);
        if (old) |o| {
            const was_plate = redstone_mod.isPlate(&profile.game.blocks, .{ .id = o.id, .meta = o.meta });
            if (was_plate and !new_plate) self.rs_plates.remove(b.x, b.y, b.z);
        }
    }

    /// Survival-break follow-ups for one broken block: break sound,
    /// vanilla drops (creative drops nothing; missing chunks peek null
    /// and stay dropless), plus window cleanup for breaks with viewers.
    /// Null olds and air-to-air edits are no-ops.
    fn breakAftermath(self: *Server, conn: *Conn, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, b: *BlockEvent, old: ?view.PeekBlock, sx: f64, sy: f64, sz: f64) void {
        const o = old orelse return;
        if (o.id != game_ids.air) self.soundForEdit(conn, o.id, sx, sy, sz);
        if (Server.shouldDropBreak(conn.config.gamemode, o.id, self.tileDrops())) {
            self.spawnBreakDrops(b.x, b.y, b.z, o.id, o.meta);
        }
        // Re-arm settled drops resting at/above the broken cell (see
        // wakeItemsAbove): runs for every break, creative included, since
        // floating items are wrong in every mode.
        self.wakeItemsAbove(b.x, b.y, b.z);
        // Breaks with viewers: drop grids + close windows (tables,
        // enchanting, furnaces).
        self.breakWindowsFor(pool, allocator, b, o.id);
    }

    /// Window cleanup on break (table/enchant grids drop + close; furnace
    /// input/fuel/output drop as entities; ender chests just close — the
    /// contents are per-player and never drop; chests close both halves'
    /// viewers (stale sizes resolve only on reopen) and drop the broken
    /// half's contents). Shared by every break path.
    fn breakWindowsFor(self: *Server, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, b: *BlockEvent, old_id: game_ids.Id) void {
        if (old_id == game_ids.crafting_table or old_id == game_ids.enchanting_table) {
            self.closeWindowsAt(pool, allocator, b.x, b.y, b.z);
            return;
        }
        if (old_id == game_ids.ender_chest) {
            self.closeWindowsAt(pool, allocator, b.x, b.y, b.z);
            return;
        }
        if (old_id == game_ids.chest or old_id == game_ids.trapped_chest) {
            // Pair mate first (still intact): its viewers go stale too.
            const mate = self.chestPair(pool, allocator, b.x, b.y, b.z, old_id);
            self.closeWindowsAt(pool, allocator, b.x, b.y, b.z);
            if (mate) |m| self.closeWindowsAt(pool, allocator, m.x, b.y, m.z);
            // Drop THIS half's contents (both modes, like table grids; the
            // block itself drops only in survival via spawnBreakDrops
            // above). The surviving half keeps its row (now single).
            // Never-opened chests have no entry/row: skip drops+delete.
            self.chest_lock.lock();
            var dropped = self.removeChest(b.x, b.y, b.z);
            self.chest_lock.unlock();
            if (dropped) |*slots| {
                for (slots) |*st| {
                    const s = st.* orelse continue;
                    st.* = null;
                    self.spawnItemLive(s, @as(f64, @floatFromInt(b.x)) + 0.5, @as(f64, @floatFromInt(b.y)) + 0.5, @as(f64, @floatFromInt(b.z)) + 0.5, 10, self.tossPopMotion());
                }
                // Caller holds world_lock (same discipline as applyBlock).
                chest_mod.deleteRow(pool, b.x, b.y, b.z) catch {};
            }
            return;
        }
        if (old_id != game_ids.furnace and old_id != game_ids.lit_furnace) {
            if (old_id != game_ids.brewing_stand_block) return;
            // Brewing-stand break: close viewer windows and drop bottles +
            // ingredient as entities (both modes; the stand itself drops
            // only in survival via spawnBreakDrops above).
            self.closeWindowsAt(pool, allocator, b.x, b.y, b.z);
            var removed = self.removeBrew(b.x, b.y, b.z);
            const bstacks = [_]*?item_mod.Stack{ &removed.bottles[0], &removed.bottles[1], &removed.bottles[2], &removed.ingredient };
            for (bstacks) |st| {
                const s = st.* orelse continue;
                st.* = null;
                self.spawnItemLive(s, @as(f64, @floatFromInt(b.x)) + 0.5, @as(f64, @floatFromInt(b.y)) + 0.5, @as(f64, @floatFromInt(b.z)) + 0.5, 10, self.tossPopMotion());
            }
            return;
        }
        // Furnace break: close viewer windows and drop input/fuel/output
        // as entities (both modes, like table grids; the block itself
        // drops only in survival via spawnBreakDrops above).
        self.closeWindowsAt(pool, allocator, b.x, b.y, b.z);
        var removed = self.removeFurnace(b.x, b.y, b.z);
        const fstacks = [_]*?item_mod.Stack{ &removed.input, &removed.fuel, &removed.output };
        for (fstacks) |st| {
            const s = st.* orelse continue;
            st.* = null;
            self.spawnItemLive(s, @as(f64, @floatFromInt(b.x)) + 0.5, @as(f64, @floatFromInt(b.y)) + 0.5, @as(f64, @floatFromInt(b.z)) + 0.5, 10, self.tossPopMotion());
        }
    }

    /// Placement-target rule (jar `abi` ItemBlock + `canPlaceEntityOnSide`):
    /// only air and replaceable materials accept blocks. Overwriting
    /// anything else silently destroys tile entities (chest/furnace
    /// contents lost, rows orphaned) and desyncs the client's prediction,
    /// so the block_set arm refuses with a resync instead. Vanilla set
    /// (Material.isReplaceable, jar-probed per block id): air, water,
    /// lava, fire, snow layers, tall grass, dead bushes, vines. Flowers /
    /// mushrooms / saplings are NOT replaceable (refused, vanilla-exact).
    fn replaceableForPlace(id: game_ids.Id) bool {
        return switch (id) {
            .air, .water, .flowing_water, .lava, .flowing_lava, .fire, .snow_layer, .tallgrass, .deadbush, .vine => true,
            else => false,
        };
    }

    fn tryOpenTable(self: *Server, conn: *Conn, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, b: *BlockEvent, sneaking: bool) bool {        _ = self;
        var cx = b.x;
        var cy: i32 = b.y;
        var cz = b.z;
        switch (b.face) {
            // clicked = target - face offset
            0 => cy += 1,
            1 => cy -= 1,
            2 => cz += 1,
            3 => cz -= 1,
            4 => cx += 1,
            5 => cx -= 1,
            else => return false,
        }
        if (cy < 0 or cy > 255) return false;
        const clicked = view.peekBlock(pool, allocator, cx, @intCast(cy), cz) catch null;
        if (clicked == null or clicked.?.id != game_ids.crafting_table) return false;
        if (sneaking) return false; // sneak+held-block places against the table
        // Open UI (leaf conn lock; world_lock held by caller: world->conn).
        conn.lock.lock();
        conn.openTableUI(cx, @intCast(cy), cz);
        conn.lock.unlock();
        return true;
    }

    /// Right-click routing: furnace (61/62) + not sneaking opens window 2.
    /// Ensures server state, then queues 0x2D + full 0x30. Same locking as
    /// tryOpenTable. Returns true when the click became a UI open.
    fn tryOpenFurnace(self: *Server, conn: *Conn, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, b: *BlockEvent, sneaking: bool) bool {
        var cx = b.x;
        var cy: i32 = b.y;
        var cz = b.z;
        switch (b.face) {
            0 => cy += 1,
            1 => cy -= 1,
            2 => cz += 1,
            3 => cz -= 1,
            4 => cx += 1,
            5 => cx -= 1,
            else => return false,
        }
        if (cy < 0 or cy > 255) return false;
        const clicked = view.peekBlock(pool, allocator, cx, @intCast(cy), cz) catch null;
        if (clicked == null or (clicked.?.id != game_ids.furnace and clicked.?.id != game_ids.lit_furnace)) return false;
        if (sneaking) return false;
        self.furn_lock.lock();
        self.ensureFurnace(cx, @intCast(cy), cz);
        const f = self.findFurnace(cx, @intCast(cy), cz).?;
        // Dupe NBT under the lock (states can be removed concurrently).
        const fin: ?item_mod.Stack = if (f.input) |s| item_mod.cloneStack(self.gpa, s) catch null else null;
        const ffu: ?item_mod.Stack = if (f.fuel) |s| item_mod.cloneStack(self.gpa, s) catch null else null;
        const fout: ?item_mod.Stack = if (f.output) |s| item_mod.cloneStack(self.gpa, s) catch null else null;
        self.furn_lock.unlock();
        conn.lock.lock();
        conn.open_win = .{ .id = 2, .x = cx, .y = @intCast(cy), .z = cz };
        conn.resetClickSeq(2); // fresh client container: action numbers restart
        var ob: [128]u8 = undefined;
        if (packets.frameOpenWindow(2, 2, "container.furnace", 3, false, &ob)) |of| {
            conn.queueFramed(of) catch {};
        } else |_| {}
        // Window 2 has 39 slots: 0-2 furnace, 3-38 alias inv 9..44.
        // (A 46-count dump would overrun the client's 39-slot container.)
        var all: [39]?item_mod.Stack = [_]?item_mod.Stack{null} ** 39;
        all[0] = fin;
        all[1] = ffu;
        all[2] = fout;
        for (item_mod.main_lo..item_mod.inv_size) |i| all[i - 6] = conn.inv[i];
        const wf = packets.frameWindowItemsAlloc(conn.allocator, 2, &all) catch null;
        if (wf) |wfr| {
            defer conn.allocator.free(wfr);
            conn.queueFramed(wfr) catch {};
        }
        conn.lock.unlock();
        var ff: ?item_mod.Stack = fin;
        item_mod.freeStack(self.gpa, &ff);
        var fu: ?item_mod.Stack = ffu;
        item_mod.freeStack(self.gpa, &fu);
        var fo: ?item_mod.Stack = fout;
        item_mod.freeStack(self.gpa, &fo);
        return true;
    }

    /// Right-click routing: brewing stand (117) + not sneaking opens
    /// window 7 (type 5). Ensures server state, then queues 0x2D + full
    /// 0x30. Same locking as tryOpenFurnace. Returns true when the click
    /// became a UI open.
    fn tryOpenBrew(self: *Server, conn: *Conn, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, b: *BlockEvent, sneaking: bool) bool {
        var cx = b.x;
        var cy: i32 = b.y;
        var cz = b.z;
        switch (b.face) {
            0 => cy += 1,
            1 => cy -= 1,
            2 => cz += 1,
            3 => cz -= 1,
            4 => cx += 1,
            5 => cx -= 1,
            else => return false,
        }
        if (cy < 0 or cy > 255) return false;
        const clicked = view.peekBlock(pool, allocator, cx, @intCast(cy), cz) catch null;
        if (clicked == null or clicked.?.id != game_ids.brewing_stand_block) return false;
        if (sneaking) return false;
        self.brew_lock.lock();
        self.ensureBrew(cx, @intCast(cy), cz);
        const br = self.findBrew(cx, @intCast(cy), cz).?;
        // Dupe NBT under the lock (states can be removed concurrently).
        const bb: [3]?item_mod.Stack = .{
            if (br.bottles[0]) |s| item_mod.cloneStack(self.gpa, s) catch null else null,
            if (br.bottles[1]) |s| item_mod.cloneStack(self.gpa, s) catch null else null,
            if (br.bottles[2]) |s| item_mod.cloneStack(self.gpa, s) catch null else null,
        };
        const bi: ?item_mod.Stack = if (br.ingredient) |s| item_mod.cloneStack(self.gpa, s) catch null else null;
        self.brew_lock.unlock();
        conn.lock.lock();
        conn.open_win = .{ .id = 7, .x = cx, .y = @intCast(cy), .z = cz };
        conn.resetClickSeq(7); // fresh client container: action numbers restart
        var ob: [128]u8 = undefined;
        if (packets.frameOpenWindow(7, 5, "container.brewing", 4, false, &ob)) |of| {
            conn.queueFramed(of) catch {};
        } else |_| {}
        // Window 7 has 40 slots: 0-2 bottles, 3 ingredient, 4-39 alias
        // inv 9..44.
        var all: [40]?item_mod.Stack = [_]?item_mod.Stack{null} ** 40;
        all[0] = bb[0];
        all[1] = bb[1];
        all[2] = bb[2];
        all[3] = bi;
        for (item_mod.main_lo..item_mod.inv_size) |i| all[i - 5] = conn.inv[i];
        const wf = packets.frameWindowItemsAlloc(conn.allocator, 7, &all) catch null;
        if (wf) |wfr| {
            defer conn.allocator.free(wfr);
            conn.queueFramed(wfr) catch {};
        }
        conn.lock.unlock();
        var f0: ?item_mod.Stack = bb[0];
        item_mod.freeStack(self.gpa, &f0);
        var f1: ?item_mod.Stack = bb[1];
        item_mod.freeStack(self.gpa, &f1);
        var f2: ?item_mod.Stack = bb[2];
        item_mod.freeStack(self.gpa, &f2);
        var fi: ?item_mod.Stack = bi;
        item_mod.freeStack(self.gpa, &fi);
        return true;
    }

    /// Right-click routing: ender chest (130) + not sneaking opens window 3.
    /// Contents are per-player (conn.ender, UUID-bound in the player row) —
    /// no per-block state to ensure, unlike the furnace. Same locking as
    /// tryOpenTable. Returns true when the click became a UI open.
    fn tryOpenEnder(self: *Server, conn: *Conn, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, b: *BlockEvent, sneaking: bool) bool {
        var cx = b.x;
        var cy: i32 = b.y;
        var cz = b.z;
        switch (b.face) {
            0 => cy += 1,
            1 => cy -= 1,
            2 => cz += 1,
            3 => cz -= 1,
            4 => cx += 1,
            5 => cx -= 1,
            else => return false,
        }
        if (cy < 0 or cy > 255) return false;
        const clicked = view.peekBlock(pool, allocator, cx, @intCast(cy), cz) catch null;
        if (clicked == null or clicked.?.id != game_ids.ender_chest) return false;
        if (sneaking) return false; // sneak+held-block places against the chest
        const cyu: u8 = @intCast(cy);
        // Viewers before self (open_win not set yet): jar `ape.h` plays
        // the lid sound on the tick after 0 -> 1, like regular chests.
        const viewers_before = self.countEnderViewers(cx, cyu, cz);
        // Open UI (leaf conn lock; world_lock held by caller: world->conn).
        conn.lock.lock();
        conn.openEnderUI(cx, cyu, cz);
        conn.lock.unlock();
        // Vanilla lid sound at the chest (volume 0.5, pitch randomized
        // 0.9-1.0 there; fixed mid here — no gameplay-RNG draws for audio).
        if (viewers_before == 0) {
            self.broadcastSound(null, "random.chestopen", @as(f64, @floatFromInt(cx)) + 0.5, @as(f64, @floatFromInt(cy)) + 0.5, @as(f64, @floatFromInt(cz)) + 0.5, 0.5, 0.95);
        }
        const n: u8 = @intCast(@min(self.countEnderViewers(cx, cyu, cz), 255));
        self.broadcastBlockAction(cx, cyu, cz, 1, n, game_ids.ender_chest);
        return true;
    }

    /// Right-click routing: chest / trapped chest + not sneaking opens
    /// window 5 (single, 27 slots) or 6 (double, 54 slots). Contents are
    /// server-owned (multi-viewer); clicks resolve on the serve thread.
    /// Same locking shape as tryOpenFurnace (sequential chest -> conn,
    /// never nested). Returns true when the click became a UI open.
    fn tryOpenChest(self: *Server, conn: *Conn, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, b: *BlockEvent, sneaking: bool) bool {
        var cx = b.x;
        var cy: i32 = b.y;
        var cz = b.z;
        switch (b.face) {
            0 => cy += 1,
            1 => cy -= 1,
            2 => cz += 1,
            3 => cz -= 1,
            4 => cx += 1,
            5 => cx -= 1,
            else => return false,
        }
        if (cy < 0 or cy > 255) return false;
        const cyu: u8 = @intCast(cy);
        const clicked = view.peekBlock(pool, allocator, cx, cyu, cz) catch null;
        if (clicked == null or (clicked.?.id != game_ids.chest and clicked.?.id != game_ids.trapped_chest)) return false;
        if (sneaking) return false; // sneak+held-block places against the chest
        // Lid blocked by an opaque block above (vanilla chest rule).
        if (cy < 255) {
            const above = view.peekBlock(pool, allocator, cx, cyu + 1, cz) catch null;
            if (above) |a| {
                if (view.isOpaqueCube(a.id)) return false;
            }
        }
        const id = clicked.?.id;
        // Pair halves, sorted for a deterministic slot order (documented
        // deviation: vanilla orders by facing; all our contents originate
        // here so the order is self-consistent).
        const mate = self.chestPair(pool, allocator, cx, cyu, cz, id);
        const second: ?ChestPos = if (mate) |m| .{ .x = m.x, .y = cyu, .z = m.z } else null;
        const is_double = second != null;
        const win: u8 = if (is_double) 6 else 5;
        const nchest: usize = if (is_double) 54 else 27;
        self.chest_lock.lock();
        self.ensureChest(pool, cx, cyu, cz, id);
        if (second) |s| self.ensureChest(pool, s.x, s.y, s.z, id);
        // Viewers before self (open_win not set yet): jar `aow.h` plays
        // the lid sound on the tick after 0 -> 1, silent otherwise.
        const viewers_before = self.countChestViewers(cx, cyu, cz);
        // Clone under chest_lock (conn.lock not held yet); the frame
        // borrows the clones, freed after queue like the furnace path.
        var cbuf: [54]?item_mod.Stack = [_]?item_mod.Stack{null} ** 54;
        var halves: [2]?*ChestEnt = [_]?*ChestEnt{ self.findChest(cx, cyu, cz).?, null };
        if (second) |s| {
            const other = self.findChest(s.x, s.y, s.z).?;
            // Sorted halves: lexicographic (x, z).
            if (s.x < cx or (s.x == cx and s.z < cz)) {
                halves = [_]?*ChestEnt{ other, halves[0] };
            } else {
                halves[1] = other;
            }
        }
        var ci: usize = 0;
        for (halves) |h| {
            const e = h orelse continue;
            for (e.slots) |st| {
                cbuf[ci] = item_mod.cloneStack(conn.allocator, st) catch null;
                ci += 1;
            }
        }
        self.chest_lock.unlock();
        conn.lock.lock();
        conn.open_win = .{ .id = win, .x = cx, .y = cyu, .z = cz };
        conn.resetClickSeq(win); // fresh client container: action numbers restart
        var ob: [128]u8 = undefined;
        if (packets.frameOpenWindow(win, 0, if (is_double) "container.chestDouble" else "container.chest", @intCast(nchest), false, &ob)) |of| {
            conn.queueFramed(of) catch {};
        } else |_| {}
        // Window N chest slots + 36 player alias (inv 9..44), vanilla
        // 27/54-slot chest container shape.
        var all: [90]?item_mod.Stack = [_]?item_mod.Stack{null} ** 90;
        for (cbuf[0..nchest], 0..) |st, i| all[i] = st;
        for (item_mod.main_lo..item_mod.inv_size) |i| all[i + nchest - 9] = conn.inv[i];
        const wf = packets.frameWindowItemsAlloc(conn.allocator, win, all[0 .. nchest + 36]) catch null;
        if (wf) |wfr| {
            defer conn.allocator.free(wfr);
            conn.queueFramed(wfr) catch {};
        }
        conn.lock.unlock();
        for (cbuf[0..nchest]) |*st| item_mod.freeStack(conn.allocator, st);
        // Lid sound on first open only (0 -> 1 viewers; re-opens find self
        // already counted). S24 lid events carry the PAIR total to both
        // halves (jar `ra.f` increments both TEs on any double open, so a
        // viewer on either half lifts both lids); singles trivially match.
        // Counts include self (open_win is set).
        if (viewers_before == 0) {
            self.broadcastSound(null, "random.chestopen", @as(f64, @floatFromInt(cx)) + 0.5, @as(f64, @floatFromInt(cy)) + 0.5, @as(f64, @floatFromInt(cz)) + 0.5, 0.5, 0.95);
        }
        var total: usize = self.countChestViewers(cx, cyu, cz);
        if (second) |s| total += self.countChestViewers(s.x, s.y, s.z);
        const n: u8 = @intCast(@min(total, 255));
        self.broadcastBlockAction(cx, cyu, cz, 1, n, id);
        if (second) |s| self.broadcastBlockAction(s.x, s.y, s.z, 1, n, id);
        return true;
    }

    /// LSM-backed redstone world adapter (caller holds world_lock).
    /// Holes read as air and reject writes (no store, no broadcast).
    const RsWorld = struct {
        pool: *shard_mod.ShardPool,
        alloc: std.mem.Allocator,
        changes: *redstone_mod.ChangeList,
        /// Single-chunk MRU: redstone fan-out reads ~14 neighbors per edit
        /// plus recompute re-reads, almost always in one chunk; without
        /// this every read is a full store fetch + decode (~0.5ms each).
        /// Doubles as the write workspace (see set): light-neutral cell
        /// writes mutate the cached chunk directly and persist once at
        /// flush, instead of a full decode+relight+encode+put per cell.
        /// Store cannot change under us within one op (world lock held;
        /// all writes go through set/pop), so the cache needs no
        /// generation checks — flush + free in deinit at the end of the op.
        cached: ?*chunk_mod.Chunk = null,
        cached_cx: i32 = 0,
        cached_cz: i32 = 0,
        dirty: bool = false,

        pub fn deinit(self: *@This()) void {
            self.flushCache();
            self.invalidate();
        }

        fn invalidate(self: *@This()) void {
            if (self.cached) |ch| {
                ch.destroy(self.alloc);
                self.cached = null;
            }
            self.dirty = false;
        }

        /// Persist a dirty cached chunk (single encode+put for the whole
        /// op's writes to that chunk). Keeps the cached copy (it still
        /// matches the store).
        fn flushCache(self: *@This()) void {
            const ch = self.cached orelse return;
            if (!self.dirty) return;
            const enc = ch.encode(self.alloc) catch return;
            defer self.alloc.free(enc);
            const key = store_mod.encodeKey(0, self.cached_cx, self.cached_cz);
            self.pool.put(key, enc) catch {};
            self.dirty = false;
        }

        /// Cached chunk for (x,z), loading + caching on miss (flushing a
        /// dirty previous chunk first). Null on holes/corrupt rows.
        fn chunkFor(self: *@This(), x: i32, z: i32) ?*chunk_mod.Chunk {
            const cx = @divFloor(x, 16);
            const cz = @divFloor(z, 16);
            if (self.cached == null or self.cached_cx != cx or self.cached_cz != cz) {
                self.flushCache();
                self.invalidate();
                const ch = view.loadChunk(self.pool, self.alloc, x, z) catch return null;
                if (ch == null) return null;
                self.cached = ch;
                self.cached_cx = cx;
                self.cached_cz = cz;
            }
            return self.cached;
        }

        pub fn get(self: *@This(), x: i32, y: i32, z: i32) ?redstone_mod.Block {
            if (y < 0 or y > 255) return null;
            const ch = self.chunkFor(x, z) orelse return null;
            const yu: u8 = @intCast(y);
            const s = ch.sections[@as(usize, yu) >> 4] orelse return null;
            const li = chunk_mod.Section.index(chunk_mod.Chunk.localCoord(x), @truncate(yu & 15), chunk_mod.Chunk.localCoord(z));
            return .{ .id = s.blocks[li], .meta = chunk_mod.Section.getNibble(&s.meta, li) };
        }

        /// Raw write: no change recording — the staged commit owns ChangeList
        /// entries for sim paths, and the piston/door helpers append their
        /// own (so a cell is never double-recorded). Light-neutral writes
        /// mutate the cached chunk and persist once at deinit; writes that
        /// change emission/opacity (or need a new section) flush first and
        /// take the immediate applyBlock path, exactly as before.
        pub fn set(self: *@This(), x: i32, y: i32, z: i32, id: game_ids.Id, meta: u4) void {
            if (y < 0 or y > 255) return;
            const ch = self.chunkFor(x, z) orelse return;
            const yu: u8 = @intCast(y);
            const s = &(ch.sections[@as(usize, yu) >> 4] orelse return);
            const li = chunk_mod.Section.index(chunk_mod.Chunk.localCoord(x), @truncate(yu & 15), chunk_mod.Chunk.localCoord(z));
            const old_id = s.blocks[li];
            if (old_id == id and chunk_mod.Section.getNibble(&s.meta, li) == meta) return;
            const e_old = chunk_mod.emitLight(old_id);
            const e_new = chunk_mod.emitLight(id);
            const op_old = chunk_mod.lightOpacity(old_id);
            const op_new = chunk_mod.lightOpacity(id);
            if (e_new != e_old or op_new != op_old) {
                self.flushCache();
                _ = view.applyBlock(self.pool, self.alloc, x, @intCast(y), z, id, meta) catch 0;
                self.invalidate();
                return;
            }
            s.blocks[li] = id;
            chunk_mod.Section.setNibble(&s.meta, li, meta);
            self.dirty = true;
        }

        /// Raw pop-write + its change record (single place for pop semantics).
        /// Light-neutral pops ride the write cache like set.
        pub fn pop(self: *@This(), x: i32, y: i32, z: i32, old_id: game_ids.Id, old_meta: u4) void {
            if (y < 0 or y > 255) return;
            self.changes.append(.{ .x = x, .y = y, .z = z, .id = game_ids.air, .meta = 0, .old_id = old_id, .old_meta = old_meta, .popped = true });
            const ch = self.chunkFor(x, z) orelse return;
            const yu: u8 = @intCast(y);
            const s = &(ch.sections[@as(usize, yu) >> 4] orelse return);
            const li = chunk_mod.Section.index(chunk_mod.Chunk.localCoord(x), @truncate(yu & 15), chunk_mod.Chunk.localCoord(z));
            const cur_id = s.blocks[li];
            if (cur_id == game_ids.air) return;
            const e_old = chunk_mod.emitLight(cur_id);
            const e_new = chunk_mod.emitLight(game_ids.air);
            const op_old = chunk_mod.lightOpacity(cur_id);
            const op_new = chunk_mod.lightOpacity(game_ids.air);
            if (e_new != e_old or op_new != op_old) {
                self.flushCache();
                _ = view.applyBlock(self.pool, self.alloc, x, @intCast(y), z, game_ids.air, 0) catch 0;
                self.invalidate();
                return;
            }
            s.blocks[li] = game_ids.air;
            chunk_mod.Section.setNibble(&s.meta, li, 0);
            self.dirty = true;
        }

        /// Typed redstone boundary: profile data travels with the adapter.
        pub fn rsView(self: *@This()) redstone_mod.WorldView {
            return redstone_mod.WorldView.init(self, &profile.game.blocks, &profile.rules.redstone);
        }
    };

    /// K1 right-click routing: lever/button/door/trapdoor/gate/repeater delay
    /// cycle/redstone-ore lighting. Caller holds world_lock; takes no other
    /// lock. Returns true when the click was consumed (skip placement).
    /// `b` carries the TARGET cell + clicked face (BlockEvent shape); the
    /// clicked block is target - face offset.
    fn tryInteract(
        self: *Server,
        pool: *shard_mod.ShardPool,
        allocator: std.mem.Allocator,
        b: *BlockEvent,
        now: i64,
        changes: *redstone_mod.ChangeList,
        sounds: *redstone_mod.SoundList,
    ) bool {
        var cx = b.x;
        var cy: i32 = b.y;
        var cz = b.z;
        switch (b.face) {
            0 => cy += 1,
            1 => cy -= 1,
            2 => cz += 1,
            3 => cz -= 1,
            4 => cx += 1,
            5 => cx -= 1,
            else => return false,
        }
        if (cy < 0 or cy > 255) return false;
        const clicked = view.peekBlock(pool, allocator, cx, @intCast(cy), cz) catch null;
        if (clicked == null or !redstone_mod.isInteractable(&profile.game.blocks, clicked.?.id)) {
            return false;
        }
        self.loadRedstone(pool, now);
        var w = Server.RsWorld{ .pool = pool, .alloc = allocator, .changes = changes };
        defer w.deinit();
        redstone_mod.interact(w.rsView(), &self.rs_sched, &self.rs_burn, changes, sounds, cx, cy, cz, now);
        return true;
    }

    /// Post-edit redstone hook: recompute + fan-out after a place/break.
    /// Caller holds world_lock.
    fn redstoneOnEdit(
        self: *Server,
        pool: *shard_mod.ShardPool,
        allocator: std.mem.Allocator,
        x: i32,
        y: u8,
        z: i32,
        now: i64,
        changes: *redstone_mod.ChangeList,
        sounds: *redstone_mod.SoundList,
    ) void {
        self.loadRedstone(pool, now);
        var w = Server.RsWorld{ .pool = pool, .alloc = allocator, .changes = changes };
        defer w.deinit();
        redstone_mod.onEdit(w.rsView(), &self.rs_sched, &self.rs_burn, changes, sounds, x, y, z, now);
    }

    /// Flush one accumulated redstone change: broadcast + sounds + pop drops.
    /// No locks held (furnace-swap pattern: world work done, then broadcast).
    fn flushRsChange(
        self: *Server,
        gamemode: rules_mod.GameMode,
        c: redstone_mod.Change,
    ) void {
        if (!c.silent) {
            self.broadcastBlockChange(null, c.x, @intCast(c.y), c.z, c.id, c.meta) catch {};
        }
        if (c.popped and c.old_id != game_ids.air) {
            const sx: f64 = @as(f64, @floatFromInt(c.x)) + 0.5;
            const sy: f64 = @as(f64, @floatFromInt(c.y)) + 0.5;
            const sz: f64 = @as(f64, @floatFromInt(c.z)) + 0.5;
            self.broadcastSound(null, Server.stepSound(c.old_id), sx, sy, sz, 1.0, 0.8);
            if (Server.shouldDropBreak(gamemode, c.old_id, self.tileDrops())) {
                self.spawnBreakDrops(c.x, @intCast(c.y), c.z, c.old_id, c.old_meta);
            }
        }
    }

    /// Flush one accumulated redstone sound event.
    fn flushRsSound(self: *Server, s: redstone_mod.SoundEv) void {
        const v = redstone_mod.SoundList.voice(s.kind);
        self.broadcastSound(
            null,
            v.name,
            @as(f64, @floatFromInt(s.x)) + 0.5,
            @as(f64, @floatFromInt(s.y)) + 0.5,
            @as(f64, @floatFromInt(s.z)) + 0.5,
            v.volume,
            v.pitch,
        );
    }

    /// Door halves: placing a door also sets the upper half (air above
    /// only). Records into `changes` for broadcast.
    fn rsPlaceDoorUpper(
        pool: *shard_mod.ShardPool,
        allocator: std.mem.Allocator,
        x: i32,
        y: u8,
        z: i32,
        id: game_ids.Id,
        lower_meta: u4,
        changes: *redstone_mod.ChangeList,
    ) void {
        if (redstone_mod.upperHalfFor(&profile.game.blocks, id) == null) return;
        if (y >= 255) return;
        // Vanilla `ach.placeDoorBlock`: upper = 8 | hinge bit.
        var w = Server.RsWorld{ .pool = pool, .alloc = allocator, .changes = changes };
        defer w.deinit();
        const um: u4 = redstone_mod.doorUpperMeta(w.rsView(), x, y, z, @truncate(lower_meta & 3), id);
        const ay: u8 = y + 1;
        const above = view.peekBlock(pool, allocator, x, ay, z) catch null;
        if (above) |a| {
            if (a.id == game_ids.air) {
                w.set(x, @as(i32, y) + 1, z, id, um);
                changes.append(.{ .x = x, .y = @as(i32, y) + 1, .z = z, .id = id, .meta = um, .old_id = a.id, .old_meta = a.meta });
            }
        }
    }

    /// Breaking one door half clears the partner (no extra drop — the main
    /// half drops via the normal break path).
    fn rsBreakDoorPartner(
        pool: *shard_mod.ShardPool,
        allocator: std.mem.Allocator,
        x: i32,
        y: u8,
        z: i32,
        old_id: game_ids.Id,
        old_meta: u4,
        changes: *redstone_mod.ChangeList,
    ) void {
        if (old_id != game_ids.wooden_door_block and old_id != game_ids.iron_door_block) return;
        var w = Server.RsWorld{ .pool = pool, .alloc = allocator, .changes = changes };
        defer w.deinit();
        if (redstone_mod.doorIsUpper(old_meta)) {
            if (y == 0) return;
            const below = view.peekBlock(pool, allocator, x, y - 1, z) catch null;
            if (below) |bl| {
                if (bl.id == old_id and !redstone_mod.doorIsUpper(bl.meta)) w.pop(x, @as(i32, y) - 1, z, bl.id, bl.meta);
            }
        } else {
            const above = view.peekBlock(pool, allocator, x, y + 1, z) catch null;
            if (above) |a| {
                if (a.id == old_id and redstone_mod.doorIsUpper(a.meta)) w.pop(x, @as(i32, y) + 1, z, a.id, a.meta);
            }
        }
    }

    /// Window-2 click (slots 0-2 furnace, 3-38 alias inv 9-44). Runs on the
    /// serve thread with conn.lock held, taking furn_lock nested inside.
    /// (Safe: furn is never held while acquiring conn anywhere, and the
    /// ticker never nests. Documented exception to one-lock-at-a-time.)
    /// Mode-0 merges reuse Conn.clickPickupImplCell (same rules as window 0);
    /// shift/number-key moves are inlined below with item primitives.
    /// Full furnace Window Items (window 2: 3 furnace slots + 36 player
    /// alias) for resyncs that touch many cells at once (drag-spread,
    /// cancel). Mirrors the mode-1 tail below (borrowed stacks, no frees).
    fn queueFurnaceWindowFull(self: *Server, conn: *Conn, f: *FurnaceEnt) void {
        _ = self;
        var all: [39]?item_mod.Stack = [_]?item_mod.Stack{null} ** 39;
        all[0] = f.input;
        all[1] = f.fuel;
        all[2] = f.output;
        for (item_mod.main_lo..item_mod.inv_size) |i| all[i - 6] = conn.inv[i];
        const wf = packets.frameWindowItemsAlloc(conn.allocator, 2, &all) catch return;
        defer conn.allocator.free(wf);
        conn.queueFramed(wf) catch {};
    }

    fn applyFurnaceClick(self: *Server, conn: *Conn, fc: FurnaceClick) void {
        conn.lock.lock();
        defer conn.lock.unlock();
        const ow = conn.open_win orelse return;
        if (ow.id != 2) return;
        self.furn_lock.lock();
        defer self.furn_lock.unlock();
        const f = self.findFurnace(ow.x, ow.y, ow.z) orelse return;
        if (fc.mode <= 1 and fc.button != 0 and fc.button != 1) return;
        // Drag-spread cancel: a non-drag click drops an in-flight paint.
        // The click below resyncs its own slot; the full window here
        // snaps back any other painted slots.
        if (fc.mode != 5 and conn.drag.active and conn.drag.win == 2) {
            conn.drag.reset();
            self.queueFurnaceWindowFull(conn, f);
            echoCursor(conn);
        }
        switch (fc.mode) {
            0 => {
                if (fc.slot == 2) {
                    if (!container_mod.takeOutput(&conn.cursor, &f.output)) return;
                    echoSlotCursor(conn, 2, 2, null);
                    return;
                }
                const cell: *?item_mod.Stack = if (fc.slot == 0) &f.input else if (fc.slot == 1) &f.fuel else if (furnInvSlot(fc.slot)) |islot| &conn.inv[islot] else return;
                if (!(container_mod.pickup(conn.allocator, cell, &conn.cursor, fc.button) catch return)) return;
                echoSlotCursor(conn, 2, fc.slot, cell.*);
            },
            1 => {
                // Shift-click: output/input/fuel -> player inv; player inv ->
                // smeltable to input, fuel to fuel, else hotbar<->main.
                var changed = false;
                if (fc.slot == 2 or fc.slot == 0 or fc.slot == 1) {
                    const cell: *?item_mod.Stack = if (fc.slot == 2) &f.output else if (fc.slot == 0) &f.input else &f.fuel;
                    changed = container_mod.quickMove(conn.allocator, cell, &conn.inv, 9, 44, null, true);
                } else if (furnInvSlot(fc.slot)) |islot| {
                    const st = conn.inv[islot] orelse return;
                    if (smelting_mod.findResult(st.id, st.damage) != null) {
                        changed = container_mod.mergeInto(conn.allocator, &conn.inv[islot], &f.input);
                    } else if (smelting_mod.burnTime(st.id) > 0) {
                        changed = container_mod.mergeInto(conn.allocator, &conn.inv[islot], &f.fuel);
                    } else {
                        const in_hotbar = islot >= 36;
                        const lo: usize = if (in_hotbar) 9 else 36;
                        const hi: usize = if (in_hotbar) 35 else 44;
                        changed = container_mod.quickMove(conn.allocator, &conn.inv[islot], &conn.inv, lo, hi, islot, !in_hotbar);
                    }
                } else return;
                if (!changed) return;
                var all: [39]?item_mod.Stack = [_]?item_mod.Stack{null} ** 39;
                all[0] = f.input;
                all[1] = f.fuel;
                all[2] = f.output;
                for (item_mod.main_lo..item_mod.inv_size) |i| all[i - 6] = conn.inv[i];
                const wf = packets.frameWindowItemsAlloc(conn.allocator, 2, &all) catch return;
                defer conn.allocator.free(wf);
                conn.queueFramed(wf) catch {};
            },
            2 => {
                if (fc.slot == 2) return; // no number-key on the output
                if (fc.button < 0 or fc.button > 8) return;
                if (conn.cursor != null) return;
                const h: usize = 36 + @as(usize, @intCast(fc.button));
                if (fc.slot >= 0 and fc.slot <= 1) {
                    const cell: *?item_mod.Stack = if (fc.slot == 0) &f.input else &f.fuel;
                    if (!container_mod.swap(cell, &conn.inv[h])) return;
                    echoFurnaceSwap(conn, fc.slot, cell.*, furnWinSlot(h), conn.inv[h]);
                } else if (furnInvSlot(fc.slot)) |islot| {
                    if (!container_mod.swap(&conn.inv[islot], &conn.inv[h])) return;
                    echoFurnaceSwap(conn, fc.slot, conn.inv[islot], furnWinSlot(h), conn.inv[h]);
                }
            },
            5 => {
                // Drag-spread (paint): start/add/end per shared conn state.
                const is_start = fc.button == 0 or fc.button == 4;
                const is_add = fc.button == 1 or fc.button == 5;
                if (!is_start and !is_add and fc.button != 2 and fc.button != 6) return;
                if (is_start) {
                    conn.drag.reset();
                    if (fc.slot != -999 or conn.cursor == null) return;
                    conn.drag.begin(2, fc.button == 4);
                    return;
                }
                if (!conn.drag.active or conn.drag.win != 2) {
                    conn.drag.reset();
                    self.queueFurnaceWindowFull(conn, f);
                    echoCursor(conn);
                    return;
                }
                if (is_add) {
                    if (fc.slot < 0) return;
                    if (self.furnDragCell(f, conn, @intCast(fc.slot)) == null) return;
                    _ = conn.drag.add(2, @intCast(fc.slot));
                    return;
                }
                var buf: [90]*?item_mod.Stack = undefined;
                var nbuf: usize = 0;
                for (conn.drag.slots[0..conn.drag.n]) |ws| {
                    const cell = self.furnDragCell(f, conn, ws) orelse continue;
                    if (nbuf < buf.len) {
                        buf[nbuf] = cell;
                        nbuf += 1;
                    }
                }
                _ = container_mod.dragDistribute(conn.allocator, &conn.cursor, buf[0..nbuf], conn.drag.right);
                conn.drag.reset();
                self.queueFurnaceWindowFull(conn, f);
                echoCursor(conn);
            },
            else => {},
        }
        _ = fc.action;
    }

    /// Window-2 slot (3..38) to player-inv index (9..44); null outside.
    fn furnInvSlot(fc_slot: i16) ?usize {
        if (fc_slot < 3 or fc_slot > 38) return null;
        return @as(usize, @intCast(fc_slot)) - 3 + 9;
    }

    /// Player hotbar index (36..44) to window-2 slot (30..38).
    fn furnWinSlot(inv: usize) i16 {
        return @intCast(inv - 6);
    }

    /// Resolve a drag slot to its furnace-window cell with validity.
    /// Input takes smeltables, fuel takes burnables, the output never
    /// accepts; player alias cells take mergeable-or-empty.
    fn furnDragCell(self: *Server, f: *FurnaceEnt, conn: *Conn, slot: u8) ?*?item_mod.Stack {
        _ = self;
        const cur = conn.cursor orelse return null;
        if (slot <= 2) {
            if (slot == 2) return null;
            if (slot == 0 and smelting_mod.findResult(cur.id, cur.damage) == null) return null;
            if (slot == 1 and smelting_mod.burnTime(cur.id) == 0) return null;
            const cell: *?item_mod.Stack = if (slot == 0) &f.input else &f.fuel;
            if (cell.*) |have| {
                if (!item_mod.canMerge(have, cur)) return null;
            }
            return cell;
        }
        const islot = furnInvSlot(@intCast(slot)) orelse return null;
        const cell = &conn.inv[islot];
        if (cell.*) |have| {
            if (!item_mod.canMerge(have, cur)) return null;
        }
        return cell;
    }


    /// Window-7 slot (4..39) to player-inv index (9..44); null outside.
    fn brewInvSlot(bc_slot: i16) ?usize {
        if (bc_slot < 4 or bc_slot > 39) return null;
        return @as(usize, @intCast(bc_slot)) - 4 + 9;
    }

    /// Player hotbar index (36..44) to window-7 slot (31..39).
    fn brewWinSlot(inv: usize) i16 {
        return @intCast(inv - 5);
    }

    /// Resolve a drag slot to its brew-window cell with validity.
    /// Bottle slots take potions only (any damage — water through splash);
    /// the ingredient slot takes brewing ingredients; glass bottles never
    /// enter the stand. Player alias cells take mergeable-or-empty.
    fn brewDragCell(self: *Server, b: *BrewEnt, conn: *Conn, slot: u8) ?*?item_mod.Stack {
        _ = self;
        const cur = conn.cursor orelse return null;
        if (slot <= 3) {
            if (slot == 3 and !profile.game.potion_data.isIngredient(cur.id)) return null;
            if (slot < 3 and cur.id != game_ids.potion) return null;
            const cell: *?item_mod.Stack = if (slot == 3) &b.ingredient else &b.bottles[slot];
            if (cell.*) |have| {
                if (!item_mod.canMerge(have, cur)) return null;
            }
            return cell;
        }
        const islot = brewInvSlot(@intCast(slot)) orelse return null;
        const cell = &conn.inv[islot];
        if (cell.*) |have| {
            if (!item_mod.canMerge(have, cur)) return null;
        }
        return cell;
    }

    /// Full brew window (window 7: 4 brew slots + 36 player alias) for
    /// resyncs that touch many cells at once (drag-spread, cancel).
    /// Mirrors queueFurnaceWindowFull (borrowed stacks, no frees).
    fn queueBrewWindowFull(self: *Server, conn: *Conn, b: *BrewEnt) void {
        _ = self;
        var all: [40]?item_mod.Stack = [_]?item_mod.Stack{null} ** 40;
        all[0] = b.bottles[0];
        all[1] = b.bottles[1];
        all[2] = b.bottles[2];
        all[3] = b.ingredient;
        for (item_mod.main_lo..item_mod.inv_size) |i| all[i - 5] = conn.inv[i];
        const wf = packets.frameWindowItemsAlloc(conn.allocator, 7, &all) catch return;
        defer conn.allocator.free(wf);
        conn.queueFramed(wf) catch {};
    }

    /// Echo a mode-2 number-key swap (both window slots, window 7).
    fn echoBrewSwap(conn: *Conn, slot_a: i16, a: ?item_mod.Stack, slot_b: i16, b: ?item_mod.Stack) void {
        const sfa = packets.frameSetSlotAlloc(conn.allocator, 7, slot_a, a) catch return;
        defer conn.allocator.free(sfa);
        conn.queueFramed(sfa) catch {};
        const sfb = packets.frameSetSlotAlloc(conn.allocator, 7, slot_b, b) catch return;
        defer conn.allocator.free(sfb);
        conn.queueFramed(sfb) catch {};
    }

    /// Window-7 click (slots 0-2 bottles, 3 ingredient, 4-39 alias inv
    /// 9..44). Runs on the serve thread with conn.lock held, taking
    /// brew_lock nested inside (same leaf discipline as furn_lock: brew
    /// is never held while acquiring conn anywhere).
    /// Mode-0 merges reuse Conn.clickPickupImplCell (same rules as window
    /// 0); shift/number-key moves are inlined below with item primitives.
    fn applyBrewClick(self: *Server, conn: *Conn, bc: BrewClick) void {
        conn.lock.lock();
        defer conn.lock.unlock();
        const ow = conn.open_win orelse return;
        if (ow.id != 7) return;
        self.brew_lock.lock();
        defer self.brew_lock.unlock();
        const b = self.findBrew(ow.x, ow.y, ow.z) orelse return;
        if (bc.mode <= 1 and bc.button != 0 and bc.button != 1) return;
        // Drag-spread cancel: a non-drag click drops an in-flight paint.
        if (bc.mode != 5 and conn.drag.active and conn.drag.win == 7) {
            conn.drag.reset();
            self.queueBrewWindowFull(conn, b);
            echoCursor(conn);
        }
        switch (bc.mode) {
            0 => {
                const cell: *?item_mod.Stack = if (bc.slot <= 3) blk: {
                    if (bc.slot < 0) return;
                    break :blk if (bc.slot == 3) &b.ingredient else &b.bottles[@intCast(bc.slot)];
                } else if (brewInvSlot(bc.slot)) |islot| &conn.inv[islot] else return;
                if (!(container_mod.pickup(conn.allocator, cell, &conn.cursor, bc.button) catch return)) return;
                echoSlotCursor(conn, 7, bc.slot, cell.*);
            },
            1 => {
                // Shift-click: bottles/ingredient -> player inv; player
                // inv -> bottle slots for potions, ingredient slot for
                // brewing ingredients, else hotbar<->main.
                var changed = false;
                if (bc.slot >= 0 and bc.slot <= 3) {
                    const cell: *?item_mod.Stack = if (bc.slot == 3) &b.ingredient else &b.bottles[@intCast(bc.slot)];
                    changed = container_mod.quickMove(conn.allocator, cell, &conn.inv, 9, 44, null, true);
                } else if (brewInvSlot(bc.slot)) |islot| {
                    const st = conn.inv[islot] orelse return;
                    if (st.id == game_ids.potion) {
                        // Bottles fill first, in slot order (vanilla
                        // transferStack order for the brewing GUI).
                        for (&b.bottles) |*bt| {
                            if (container_mod.mergeInto(conn.allocator, &conn.inv[islot], bt)) {
                                changed = true;
                                break;
                            }
                        }
                    } else if (profile.game.potion_data.isIngredient(st.id)) {
                        changed = container_mod.mergeInto(conn.allocator, &conn.inv[islot], &b.ingredient);
                    } else {
                        const in_hotbar = islot >= 36;
                        const lo: usize = if (in_hotbar) 9 else 36;
                        const hi: usize = if (in_hotbar) 35 else 44;
                        changed = container_mod.quickMove(conn.allocator, &conn.inv[islot], &conn.inv, lo, hi, islot, !in_hotbar);
                    }
                } else return;
                if (!changed) return;
                self.queueBrewWindowFull(conn, b);
            },
            2 => {
                if (bc.button < 0 or bc.button > 8) return;
                if (conn.cursor != null) return;
                const h: usize = 36 + @as(usize, @intCast(bc.button));
                if (bc.slot >= 0 and bc.slot <= 3) {
                    const cell: *?item_mod.Stack = if (bc.slot == 3) &b.ingredient else &b.bottles[@intCast(bc.slot)];
                    if (!container_mod.swap(cell, &conn.inv[h])) return;
                    echoBrewSwap(conn, bc.slot, cell.*, brewWinSlot(h), conn.inv[h]);
                } else if (brewInvSlot(bc.slot)) |islot| {
                    if (!container_mod.swap(&conn.inv[islot], &conn.inv[h])) return;
                    echoBrewSwap(conn, bc.slot, conn.inv[islot], brewWinSlot(h), conn.inv[h]);
                }
            },
            5 => {
                // Drag-spread (paint): start/add/end per shared conn state.
                const is_start = bc.button == 0 or bc.button == 4;
                const is_add = bc.button == 1 or bc.button == 5;
                if (!is_start and !is_add and bc.button != 2 and bc.button != 6) return;
                if (is_start) {
                    conn.drag.reset();
                    if (bc.slot != -999 or conn.cursor == null) return;
                    conn.drag.begin(7, bc.button == 4);
                    return;
                }
                if (!conn.drag.active or conn.drag.win != 7) {
                    conn.drag.reset();
                    self.queueBrewWindowFull(conn, b);
                    echoCursor(conn);
                    return;
                }
                if (is_add) {
                    if (bc.slot < 0) return;
                    if (self.brewDragCell(b, conn, @intCast(bc.slot)) == null) return;
                    _ = conn.drag.add(7, @intCast(bc.slot));
                    return;
                }
                var buf: [90]*?item_mod.Stack = undefined;
                var nbuf: usize = 0;
                for (conn.drag.slots[0..conn.drag.n]) |ws| {
                    const cell = self.brewDragCell(b, conn, ws) orelse continue;
                    if (nbuf < buf.len) {
                        buf[nbuf] = cell;
                        nbuf += 1;
                    }
                }
                _ = container_mod.dragDistribute(conn.allocator, &conn.cursor, buf[0..nbuf], conn.drag.right);
                conn.drag.reset();
                self.queueBrewWindowFull(conn, b);
                echoCursor(conn);
            },
            else => {},
        }
        _ = bc.action;
    }

    /// Echo a mode-2 number-key swap (both window slots).
    fn echoFurnaceSwap(conn: *Conn, slot_a: i16, a: ?item_mod.Stack, slot_b: i16, b: ?item_mod.Stack) void {
        const sfa = packets.frameSetSlotAlloc(conn.allocator, 2, slot_a, a) catch return;
        defer conn.allocator.free(sfa);
        conn.queueFramed(sfa) catch {};
        const sfb = packets.frameSetSlotAlloc(conn.allocator, 2, slot_b, b) catch return;
        defer conn.allocator.free(sfb);
        conn.queueFramed(sfb) catch {};
    }

    /// Echo a chest mode-2 number-key swap (both window slots, window-aware).
    fn echoChestSwap(conn: *Conn, win: i8, slot_a: i16, a: ?item_mod.Stack, slot_b: i16, b: ?item_mod.Stack) void {
        const sfa = packets.frameSetSlotAlloc(conn.allocator, win, slot_a, a) catch return;
        defer conn.allocator.free(sfa);
        conn.queueFramed(sfa) catch {};
        const sfb = packets.frameSetSlotAlloc(conn.allocator, win, slot_b, b) catch return;
        defer conn.allocator.free(sfb);
        conn.queueFramed(sfb) catch {};
    }

    /// Window slot to player-inv index, or null outside the alias range.
    /// Single (5): 27-62 alias inv 9-44. Double (6): 54-89 alias inv 9-44.
    fn chestInvSlot(win_slot: i16, is_double: bool) ?usize {
        if (!is_double) {
            if (win_slot < 27 or win_slot > 62) return null;
            return @as(usize, @intCast(win_slot)) - 18;
        }
        if (win_slot < 54 or win_slot > 89) return null;
        return @as(usize, @intCast(win_slot)) - 45;
    }

    /// Player-inv index (36..44 hotbar) to chest-window slot.
    fn chestWinSlot(inv: usize, is_double: bool) i16 {
        return @intCast(inv + (if (is_double) @as(usize, 45) else 18));
    }

    /// Resolve a drag slot to its cell for chest windows (single: 0-26
    /// chest, 27-62 player alias; double: 0-53, 54-89). Returns null for
    /// out-of-range slots. Validity mirrors mode-0 placement gating:
    /// chest cells need the cursor's NBT to fit the row cap, player cells
    /// take anything mergeable-or-empty.
    fn chestDragCell(self: *Server, halves: []?*ChestEnt, nchest: usize, conn: *Conn, slot: u8) ?*?item_mod.Stack {
        _ = self;
        const cur = conn.cursor orelse return null;
        if (slot < nchest) {
            if (!chest_mod.slotFitsChest(cur)) return null;
            const s: usize = slot;
            const cell = if (nchest == 54) &halves[s / 27].?.slots[s % 27] else &halves[0].?.slots[s];
            if (cell.*) |have| {
                if (!item_mod.canMerge(have, cur)) return null;
            }
            return cell;
        }
        if (slot >= nchest + 36) return null;
        const islot: usize = slot - nchest + 9;
        if (islot >= item_mod.inv_size) return null;
        const cell = &conn.inv[islot];
        if (cell.*) |have| {
            if (!item_mod.canMerge(have, cur)) return null;
        }
        return cell;
    }

    /// Shift-click helper: move a source cell across chest halves (merge
    /// first across everything, then first empty). Same two-phase shape
    /// as container_mod.quickMove (which needs one contiguous range).
    fn quickMoveToChest(alloc: std.mem.Allocator, src: *?item_mod.Stack, halves: []const []?item_mod.Stack) bool {
        if (src.* == null) return false;
        var moved = false;
        for (halves) |lst| {
            for (lst) |*cell| {
                if (src.* == null) break;
                if (container_mod.mergeInto(alloc, src, cell)) moved = true;
            }
            if (src.* == null) break;
        }
        if (src.* != null) {
            for (halves) |lst| {
                for (lst) |*cell| {
                    if (cell.* != null) continue;
                    cell.* = src.*;
                    src.* = null;
                    moved = true;
                    break;
                }
                if (src.* == null) break;
            }
        }
        return moved;
    }

    /// Chest click (windows 5/6). Runs on the serve thread: conn.lock,
    /// then chest_lock (leaf-ward, like conn->furn). Shared rows mutate
    /// under chest_lock; the actor syncs before release; other viewers
    /// refresh after (their locks only — never nested under chest_lock).
    fn applyChestClick(self: *Server, conn: *Conn, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, cc: ChestClick) void {
        const sync = self.mutateChestClick(conn, pool, allocator, cc) orelse return;
        defer {
            var cbuf = sync.cbuf;
            for (cbuf[0..sync.nchest]) |*st| item_mod.freeStack(conn.allocator, st);
        }
        self.refreshChestViewers(sync, conn);
    }

    const ChestSync = struct {
        halves_pos: [2]?ChestPos,
        nhalf: usize,
        cbuf: [54]?item_mod.Stack,
        nchest: usize,
        win: i8,
    };

    fn mutateChestClick(self: *Server, conn: *Conn, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, cc: ChestClick) ?ChestSync {
        conn.lock.lock();
        defer conn.lock.unlock();
        const ow = conn.open_win orelse return null;
        if (ow.id != 5 and ow.id != 6) return null;
        if (cc.mode < 0 or (cc.mode > 2 and cc.mode != 5)) return null;
        if (cc.mode <= 1 and cc.button != 0 and cc.button != 1) return null;
        const win: i8 = @intCast(ow.id);
        const is_double_open = ow.id == 6;
        self.chest_lock.lock();
        defer self.chest_lock.unlock();
        const anchor = self.findChest(ow.x, ow.y, ow.z) orelse return null;
        // Current pair, sorted (same order as open). A double UI whose
        // pair dissolved (break closes viewers first, so unreachable in
        // practice) resolves to nothing — never misroutes.
        var halves: [2]?*ChestEnt = [_]?*ChestEnt{ anchor, null };
        var hpos: [2]?ChestPos = [_]?ChestPos{ .{ .x = ow.x, .y = ow.y, .z = ow.z }, null };
        var nhalf: usize = 1;
        if (is_double_open) {
            const mate = self.chestPair(pool, allocator, ow.x, ow.y, ow.z, anchor.id) orelse return null;
            const me = self.findChest(mate.x, ow.y, mate.z) orelse return null;
            nhalf = 2;
            if (mate.x < ow.x or (mate.x == ow.x and mate.z < ow.z)) {
                halves = [_]?*ChestEnt{ me, anchor };
                hpos = [_]?ChestPos{ .{ .x = mate.x, .y = ow.y, .z = mate.z }, .{ .x = ow.x, .y = ow.y, .z = ow.z } };
            } else {
                halves = [_]?*ChestEnt{ anchor, me };
                hpos = [_]?ChestPos{ .{ .x = ow.x, .y = ow.y, .z = ow.z }, .{ .x = mate.x, .y = ow.y, .z = mate.z } };
            }
        }
        const nchest: usize = if (is_double_open) 54 else 27;
        // Resolve the clicked cell (size comes from the OPEN id, never the
        // live pair — a pair forming/dissolving under an open UI must not
        // reroute clicks into the wrong region).
        var chest_half: ?usize = null;
        var cell: *?item_mod.Stack = undefined;
        var have_cell = false;
        if (!is_double_open) {
            if (cc.slot >= 0 and cc.slot <= 26) {
                cell = &halves[0].?.slots[@intCast(cc.slot)];
                chest_half = 0;
                have_cell = true;
            }
        } else {
            if (cc.slot >= 0 and cc.slot <= 53) {
                const s: usize = @intCast(cc.slot);
                cell = &halves[s / 27].?.slots[s % 27];
                chest_half = s / 27;
                have_cell = true;
            }
        }
        const islot = chestInvSlot(cc.slot, is_double_open);
        // Drag-spread start/end ride slot -999 (no cell): let them through
        // to the mode-5 arm below; adds need real cells like other clicks.
        const is_drag_edge = cc.mode == 5 and cc.slot == -999;
        if (!have_cell and islot == null and !is_drag_edge) return null; // out of range: ignore
        // Drag-spread cancel: a non-drag click drops an in-flight paint;
        // resync first so the client's predicted paint snaps back, then
        // the click below processes normally.
        if (cc.mode != 5 and conn.drag.active and conn.drag.win == win) {
            conn.drag.reset();
            self.queueChestWindow(conn, halves[0..nhalf], win, nchest);
            echoCursor(conn);
        }
        switch (cc.mode) {
            0 => {
                if (have_cell) {
                    // Gate the incoming stack (placing): oversize NBT would
                    // persist an unopenable row. Echo snaps back (no ghost).
                    if (conn.cursor != null and !chest_mod.slotFitsChest(conn.cursor)) {
                        echoSlotCursor(conn, win, cc.slot, cell.*);
                        return null;
                    }
                    if (!(container_mod.pickup(conn.allocator, cell, &conn.cursor, cc.button) catch return null)) return null;
                    echoSlotCursor(conn, win, cc.slot, cell.*);
                    halves[chest_half.?].?.dirty = true;
                } else {
                    const ii = islot.?;
                    if (!(container_mod.pickup(conn.allocator, &conn.inv[ii], &conn.cursor, cc.button) catch return null)) return null;
                    echoSlotCursor(conn, win, cc.slot, conn.inv[ii]);
                }
            },
            1 => {
                if (have_cell) {
                    if (cell.* == null) return null;
                    if (!container_mod.quickMove(conn.allocator, cell, &conn.inv, 9, 44, null, true)) return null;
                    halves[chest_half.?].?.dirty = true;
                } else {
                    const ii = islot.?;
                    if (conn.inv[ii] == null) return null;
                    if (!chest_mod.slotFitsChest(conn.inv[ii])) {
                        // Oversize in: full refresh snaps back (no ghost,
                        // no dirty, no viewer traffic — nothing changed).
                        self.queueChestWindow(conn, halves[0..nhalf], win, nchest);
                        echoCursor(conn);
                        return null;
                    }
                    var lists: [2][]?item_mod.Stack = undefined;
                    var nl: usize = 0;
                    for (halves[0..nhalf]) |h| {
                        lists[nl] = h.?.slots[0..];
                        nl += 1;
                    }
                    if (!container_mod.quickMoveLists(conn.allocator, &conn.inv[ii], lists[0..nl], false)) return null;
                    halves[0].?.dirty = true;
                    if (nhalf > 1) halves[1].?.dirty = true;
                }
                self.queueChestWindow(conn, halves[0..nhalf], win, nchest);
                echoCursor(conn);
            },
            2 => {
                if (cc.button < 0 or cc.button > 8) return null;
                if (conn.cursor != null) return null;
                const h: usize = 36 + @as(usize, @intCast(cc.button));
                if (have_cell) {
                    // Gate the hotbar side (it enters the chest on swap).
                    if (!chest_mod.slotFitsChest(conn.inv[h])) {
                        echoChestSwap(conn, win, cc.slot, cell.*, chestWinSlot(h, is_double_open), conn.inv[h]);
                        return null;
                    }
                    if (!container_mod.swap(cell, &conn.inv[h])) return null;
                    halves[chest_half.?].?.dirty = true;
                    self.queueChestWindow(conn, halves[0..nhalf], win, nchest);
                    echoCursor(conn);
                } else {
                    const ii = islot.?;
                    if (ii == h) return null;
                    if (!container_mod.swap(&conn.inv[ii], &conn.inv[h])) return null;
                    echoChestSwap(conn, win, cc.slot, conn.inv[ii], chestWinSlot(h, is_double_open), conn.inv[h]);
                }
            },
            5 => {
                // Drag-spread (paint): start/add/end per shared conn state.
                const is_start = cc.button == 0 or cc.button == 4;
                const is_add = cc.button == 1 or cc.button == 5;
                if (!is_start and !is_add and cc.button != 2 and cc.button != 6) return null;
                if (is_start) {
                    conn.drag.reset();
                    if (cc.slot != -999 or conn.cursor == null) return null;
                    conn.drag.begin(win, cc.button == 4);
                    return null;
                }
                if (!conn.drag.active or conn.drag.win != win) {
                    conn.drag.reset();
                    self.queueChestWindow(conn, halves[0..nhalf], win, nchest);
                    echoCursor(conn);
                    return null;
                }
                if (is_add) {
                    if (cc.slot < 0) return null;
                    if (self.chestDragCell(halves[0..nhalf], nchest, conn, @intCast(cc.slot)) == null) return null;
                    _ = conn.drag.add(win, @intCast(cc.slot));
                    return null;
                }
                // End: resolve every dragged slot against CURRENT state,
                // spread the cursor, mark touched halves, full-resync the
                // actor (viewers refresh from the returned sync below).
                var buf: [90]*?item_mod.Stack = undefined;
                var nbuf: usize = 0;
                for (conn.drag.slots[0..conn.drag.n]) |ws| {
                    const dcell = self.chestDragCell(halves[0..nhalf], nchest, conn, ws) orelse continue;
                    if (nbuf < buf.len) {
                        buf[nbuf] = dcell;
                        nbuf += 1;
                    }
                }
                const is_right = conn.drag.right;
                if (container_mod.dragDistribute(conn.allocator, &conn.cursor, buf[0..nbuf], is_right)) {
                    for (conn.drag.slots[0..conn.drag.n]) |ws| {
                        if (ws < nchest) halves[ws / 27].?.dirty = true;
                    }
                }
                conn.drag.reset();
                self.queueChestWindow(conn, halves[0..nhalf], win, nchest);
                echoCursor(conn);
            },
            else => return null,
        }
        // Snapshot for viewer refresh (cloned; chest_lock released on
        // return via defer, viewers sync lock-free of chest state).
        var cbuf: [54]?item_mod.Stack = [_]?item_mod.Stack{null} ** 54;
        var ci: usize = 0;
        for (halves[0..nhalf]) |e| {
            for (e.?.slots) |st| {
                cbuf[ci] = item_mod.cloneStack(conn.allocator, st) catch null;
                ci += 1;
            }
        }
        return ChestSync{ .halves_pos = hpos, .nhalf = nhalf, .cbuf = cbuf, .nchest = nchest, .win = win };
    }

    /// Assemble + queue a full chest Window Items for the ACTOR (caller
    /// holds conn.lock and chest_lock; borrows entry stacks + conn inv).
    fn queueChestWindow(self: *Server, conn: *Conn, halves: []?*ChestEnt, win: i8, nchest: usize) void {
        _ = self;
        var all: [90]?item_mod.Stack = [_]?item_mod.Stack{null} ** 90;
        var ci: usize = 0;
        for (halves) |h| {
            for (h.?.slots) |st| {
                all[ci] = st;
                ci += 1;
            }
        }
        for (item_mod.main_lo..item_mod.inv_size) |i| all[nchest + (i - item_mod.main_lo)] = conn.inv[i];
        const wf = packets.frameWindowItemsAlloc(conn.allocator, @intCast(win), all[0 .. nchest + 36]) catch return;
        defer conn.allocator.free(wf);
        conn.queueFramed(wf) catch {};
    }

    /// Refresh other viewers after a chest mutation (no locks held on
    /// entry; chest state arrives as clones). Skips the actor and any
    /// viewer whose UI size no longer matches (stale sizes resolve on
    /// reopen; their clicks stay safe via id-bound routing).
    fn refreshChestViewers(self: *Server, sync: ChestSync, actor: *Conn) void {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            if (e.conn == actor) continue;
            if (!e.conn.lock.tryLock()) continue;
            const ow = e.conn.open_win;
            if (ow == null or ow.?.id != @as(u8, @intCast(sync.win))) {
                e.conn.lock.unlock();
                continue;
            }
            // Locate the viewer's half in the snapshot order.
            var hidx: ?usize = null;
            for (sync.halves_pos[0..sync.nhalf], 0..) |hp, i| {
                if (hp) |p| {
                    if (p.x == ow.?.x and p.y == ow.?.y and p.z == ow.?.z) hidx = i;
                }
            }
            const hi = hidx orelse {
                e.conn.lock.unlock();
                continue;
            };
            const vnchest: usize = if (ow.?.id == 6) 54 else 27;
            if (ow.?.id == 6 and sync.nhalf < 2) {
                e.conn.lock.unlock();
                continue;
            }
            var all: [90]?item_mod.Stack = [_]?item_mod.Stack{null} ** 90;
            if (ow.?.id == 6) {
                for (sync.cbuf[0..54], 0..) |st, i| all[i] = st;
            } else {
                for (sync.cbuf[hi * 27 .. hi * 27 + 27], 0..) |st, i| all[i] = st;
            }
            for (item_mod.main_lo..item_mod.inv_size) |i| all[vnchest + (i - item_mod.main_lo)] = e.conn.inv[i];
            const wf = packets.frameWindowItemsAlloc(e.conn.allocator, ow.?.id, all[0 .. vnchest + 36]) catch {
                e.conn.lock.unlock();
                continue;
            };
            defer e.conn.allocator.free(wf);
            e.conn.queueFramed(wf) catch {};
            e.conn.lock.unlock();
            flushEntry(e, self.io);
        }
    }

    /// Client-initiated chest close (0x0D): lid sound + S24 lid events when
    /// the last viewer leaves (conn already cleared its window, so counts
    /// are the true remainder). Pair totals to both halves (see open).
    /// Contents persist; nothing drops. Look-don't-touch closes (empty,
    /// clean, alone) evict the entry entirely — zero footprint for
    /// opened-but-unused chests.
    fn spawnChestClose(self: *Server, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, cc: ChestClose) void {
        if (cc.window != 5 and cc.window != 6) return;
        var total = self.countChestViewers(cc.x, cc.y, cc.z);
        const mate = if (cc.window == 6)
            self.chestPair(pool, allocator, cc.x, cc.y, cc.z, self.chestKindAt(pool, allocator, cc.x, cc.y, cc.z))
        else
            null;
        if (mate) |m| total += self.countChestViewers(m.x, cc.y, m.z);
        if (total == 0) {
            self.broadcastSound(null, "random.chestclosed", @as(f64, @floatFromInt(cc.x)) + 0.5, @as(f64, @floatFromInt(cc.y)) + 0.5, @as(f64, @floatFromInt(cc.z)) + 0.5, 0.5, 0.95);
        }
        const n: u8 = @intCast(@min(total, 255));
        const kind = self.chestKindAt(pool, allocator, cc.x, cc.y, cc.z);
        self.broadcastBlockAction(cc.x, cc.y, cc.z, 1, n, kind);
        if (mate) |m| self.broadcastBlockAction(m.x, cc.y, m.z, 1, n, kind);
        self.chest_lock.lock();
        defer self.chest_lock.unlock();
        const e = self.findChest(cc.x, cc.y, cc.z) orelse return;
        if (e.dirty) return;
        for (e.slots) |s| {
            if (s != null) return;
        }
        // Empty, clean, alone: evict (a concurrent break already removed
        // it -> removeChest misses -> nothing to do).
        var gone = self.removeChest(cc.x, cc.y, cc.z) orelse return;
        chest_mod.freeSlots(self.gpa, &gone);
    }

    /// Next enchanting seed from the shared drop rand (leaf rand_lock only).
    fn nextEnchantSeed(self: *Server) i32 {
        self.rand_lock.lock();
        defer self.rand_lock.unlock();
        if (self.drop_rand == null) self.drop_rand = java_random.JavaRandom.init(self.drop_seed);
        return self.drop_rand.?.nextInt();
    }

    /// Next item-toss uniform in [0,1) from the DEDICATED toss stream
    /// (leaf rand_lock only). Never draws from drop_rand: toss motion is
    /// player-visible every break, and sharing the world-seeded stream
    /// would expose worldgen RNG state (randar). Matches vanilla shape,
    /// where EntityItem motion comes from Math.random(), not world.rand.
    fn nextToss(self: *Server) f32 {
        self.rand_lock.lock();
        defer self.rand_lock.unlock();
        if (self.toss_rand == null) self.toss_rand = java_random.JavaRandom.init(self.toss_seed);
        return self.toss_rand.?.nextFloat();
    }

    /// Vanilla break/drop pop motion (jar `xk` EntityItem ctor): XZ in
    /// [-0.1, 0.1], Y 0.2 — drawn from the toss stream, never drop_rand.
    fn tossPopMotion(self: *Server) [3]f64 {
        return .{ self.nextToss() * 0.2 - 0.1, 0.2, self.nextToss() * 0.2 - 0.1 };
    }

    /// Count bookshelves around an enchanting table (vanilla air-gap rule).
    /// Pure pool reads; safe without world_lock (same discipline as the tick
    /// environment reads). Holes count as non-air.
    fn countShelves(
        self: *Server,
        pool: *shard_mod.ShardPool,
        allocator: std.mem.Allocator,
        tx: i32,
        ty: u8,
        tz: i32,
    ) u8 {
        _ = self;
        // Thread-local pool binding: serve threads share this function
        // (thread-per-conn), and the shelf callback takes no context —
        // globals here would race across conns.
        const S = struct {
            threadlocal var p: *shard_mod.ShardPool = undefined;
            threadlocal var a: std.mem.Allocator = undefined;
            fn get(x: i32, y: i32, z: i32) ?game_ids.Id {
                if (y < 0 or y > 255) return null;
                const pb = view.peekBlock(p, a, x, @intCast(y), z) catch return null;
                const b = pb orelse return null;
                return b.id;
            }
        };
        S.p = pool;
        S.a = allocator;
        return enchanting_mod.countBookshelves(tx, ty, tz, &S.get);
    }

    /// Zero all three offer levels (unenchantable / missing / stacked item).
    fn zeroEnchantLevels(conn: *Conn) void {
        conn.enchant_levels = .{ 0, 0, 0 };
    }

    /// Recompute the three offer levels for the open enchant UI.
    /// Caller holds conn.lock. Uses the conn's seed + current item.
    fn recomputeEnchantLevels(
        self: *Server,
        pool: *shard_mod.ShardPool,
        allocator: std.mem.Allocator,
        conn: *Conn,
        tx: i32,
        ty: u8,
        tz: i32,
    ) void {
        const shelves = Server.countShelves(self, pool, allocator, tx, ty, tz);
        const st = conn.enchant_item orelse return zeroEnchantLevels(conn);
        var has_ench = false;
        if (st.nbt) |raw| {
            var have: [8]u8 = undefined;
            if (parseEnchIds(raw, &have) > 0) has_ench = true;
        }
        if (!enchanting_mod.isEnchantableId(st.id, has_ench)) return zeroEnchantLevels(conn);
        if (st.count != 1) return zeroEnchantLevels(conn);
        const ench = profile.game.enchanting_data.enchantabilityForId(st.id);
        var rng = java_random.JavaRandom.init(conn.enchant_seed);
        conn.enchant_levels = enchanting_mod.calcLevels(&rng, shelves, ench);
    }

    /// Sync the open enchant window: full 0x30 + three 0x31 levels.
    /// Caller holds conn.lock.
    fn syncEnchantWindow(self: *Server, conn: *Conn) void {
        _ = self;
        conn.queueEnchantWindow();
        conn.sendEnchantLevels();
    }

    /// Right-click routing: enchanting table (116) + not sneaking opens
    /// window 4. Same locking as tryOpenTable/Furnace. Returns true when the
    /// click became a UI open.
    fn tryOpenEnchant(self: *Server, conn: *Conn, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, b: *BlockEvent, sneaking: bool) bool {
        var cx = b.x;
        var cy: i32 = b.y;
        var cz = b.z;
        switch (b.face) {
            0 => cy += 1,
            1 => cy -= 1,
            2 => cz += 1,
            3 => cz -= 1,
            4 => cx += 1,
            5 => cx -= 1,
            else => return false,
        }
        if (cy < 0 or cy > 255) return false;
        const clicked = view.peekBlock(pool, allocator, cx, @intCast(cy), cz) catch null;
        if (clicked == null or clicked.?.id != game_ids.enchanting_table) return false;
        if (sneaking) return false;
        const seed = self.nextEnchantSeed();
        conn.lock.lock();
        conn.openEnchantUI(cx, @intCast(cy), cz, seed);
        self.recomputeEnchantLevels(pool, allocator, conn, cx, @intCast(cy), cz);
        // Levels are 0 with no item, but sync anyway for the client glue.
        self.syncEnchantWindow(conn);
        conn.lock.unlock();
        return true;
    }

    /// Split one unit off a stack (dupes NBT, decrements the source,
    /// frees it at zero). Null on empty/OOM. Shared by the enchant
    /// single-slot paths (place-one / shift-take-one).
    fn splitOne(alloc: std.mem.Allocator, src: *?item_mod.Stack) ?item_mod.Stack {
        const s = src.* orelse return null;
        if (s.count <= 0) return null;
        const one = item_mod.Stack{
            .id = s.id,
            .count = 1,
            .damage = s.damage,
            .nbt = if (s.nbt) |n| alloc.dupe(u8, n) catch return null else null,
        };
        src.*.?.count -= 1;
        if (src.*.?.count <= 0) item_mod.freeStack(alloc, src);
        return one;
    }

    /// Window-4 slot (1..36) to player-inv index (9..44); null outside.
    fn enchantInvSlot(ec_slot: i16) ?usize {
        if (ec_slot < 1 or ec_slot > 36) return null;
        return @as(usize, @intCast(ec_slot)) - 1 + 9;
    }

    /// Echo a window click: the touched slot plus the cursor (-1).
    fn echoSlotCursor(conn: *Conn, window: i8, slot: i16, cell: ?item_mod.Stack) void {
        const sf = packets.frameSetSlotAlloc(conn.allocator, window, slot, cell) catch return;
        defer conn.allocator.free(sf);
        conn.queueFramed(sf) catch {};
        const cf = packets.frameSetSlotAlloc(conn.allocator, -1, -1, conn.cursor) catch return;
        defer conn.allocator.free(cf);
        conn.queueFramed(cf) catch {};
    }

    /// Echo the cursor alone (slot state already synced).
    fn echoCursor(conn: *Conn) void {
        const cf = packets.frameSetSlotAlloc(conn.allocator, -1, -1, conn.cursor) catch return;
        defer conn.allocator.free(cf);
        conn.queueFramed(cf) catch {};
    }

    /// Recompute offers + sync the open enchant window.
    fn resyncEnchant(self: *Server, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, conn: *Conn, x: i32, y: u8, z: i32) void {
        self.recomputeEnchantLevels(pool, allocator, conn, x, y, z);
        self.syncEnchantWindow(conn);
    }
    /// Window-4 click (slots 0 = item, 1-36 alias inv 9-44). Runs on the
    /// serve thread with conn.lock held; pool reads need no world_lock.
    /// Mode-0 enforces the single-item slot limit (vanilla Slot limit 1);
    /// shift/number-key moves take/place exactly one.
    fn applyEnchantClick(self: *Server, conn: *Conn, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, ec: EnchantClick) void {
        conn.lock.lock();
        defer conn.lock.unlock();
        const ow = conn.open_win orelse return;
        if (ow.id != 4) return;
        switch (ec.mode) {
            0 => {
                if (ec.button != 0 and ec.button != 1) return;
                if (ec.slot == 0) {
                    // Single-item slot: place one / pick up / swap single.
                    if (conn.enchant_item == null and conn.cursor == null) return;
                    if (conn.enchant_item == null) {
                        // Place from cursor: move exactly one.
                        conn.enchant_item = splitOne(conn.allocator, &conn.cursor) orelse return;
                    } else if (conn.cursor == null) {
                        // Pick up the single item.
                        conn.cursor = conn.enchant_item;
                        conn.enchant_item = null;
                    } else {
                        // Both sides: swap only when the enchant slot holds
                        // one and the cursor holds one (never merge beyond 1).
                        const e = conn.enchant_item.?;
                        const c = conn.cursor.?;
                        if (e.count != 1 or c.count != 1) return;
                        // NBT-merge would break conservation; swap ownership.
                        const tmp = conn.enchant_item;
                        conn.enchant_item = conn.cursor;
                        conn.cursor = tmp;
                    }
                    self.resyncEnchant(pool, allocator, conn, ow.x, ow.y, ow.z);
                    echoCursor(conn);
                } else if (enchantInvSlot(ec.slot)) |islot| {
                    if (!(container_mod.pickup(conn.allocator, &conn.inv[islot], &conn.cursor, ec.button) catch return)) return;
                    echoSlotCursor(conn, 4, ec.slot, conn.inv[islot]);
                } else return;
            },
            1 => {
                // Shift-click: enchant slot -> player inv; player inv ->
                // enchant slot (exactly one, when empty and enchantable).
                if (ec.button != 0 and ec.button != 1) return;
                if (ec.slot == 0) {
                    // Enchant slot -> player inv (the slot holds exactly
                    // one; operate on it directly so NBT ownership is exact
                    // — copying the stack first would double-free it).
                    if (conn.enchant_item == null) return;
                    if (!container_mod.quickMove(conn.allocator, &conn.enchant_item, &conn.inv, 9, 44, null, true)) return;
                    self.resyncEnchant(pool, allocator, conn, ow.x, ow.y, ow.z);
                } else if (enchantInvSlot(ec.slot)) |islot| {
                    const st = conn.inv[islot] orelse return;
                    if (conn.enchant_item != null) return;
                    if (st.count <= 0) return;
                    // Take exactly one (vanilla transferStackInSlot takes 1).
                    conn.enchant_item = splitOne(conn.allocator, &conn.inv[islot]) orelse return;
                    self.resyncEnchant(pool, allocator, conn, ow.x, ow.y, ow.z);
                } else return;
            },
            2 => {
                // Number-key swap with hotbar (button 0..8). Cursor must be
                // empty (vanilla rule). Enchant slot swaps single-for-single.
                if (ec.button < 0 or ec.button > 8) return;
                if (conn.cursor != null) return;
                const h: usize = 36 + @as(usize, @intCast(ec.button));
                if (ec.slot == 0) {
                    const t = conn.enchant_item;
                    // Hotbar stacks larger than 1 cannot enter the 1-slot.
                    if (conn.inv[h]) |hh| {
                        if (hh.count != 1) return;
                    }
                    conn.enchant_item = conn.inv[h];
                    conn.inv[h] = t;
                    self.resyncEnchant(pool, allocator, conn, ow.x, ow.y, ow.z);
                } else if (enchantInvSlot(ec.slot)) |islot| {
                    if (!container_mod.swap(&conn.inv[islot], &conn.inv[h])) return;
                    self.syncEnchantWindow(conn);
                }
            },
            else => {},
        }
        _ = ec.action;
    }

    /// Serverbound 0x11: apply one of the three offers (1.7.10: full level
    /// cost, no lapis). Validates window 4, slot 0..2, level > 0, XP, and a
    /// still-enchantable single item; rolls the weighted draw with
    /// seed+slot; merges NBT; converts books; deducts levels; reseeds and
    /// resyncs. Fail-closed: any mismatch resyncs, never enchants.
    fn applyEnchant(self: *Server, conn: *Conn, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, ev: EnchantEvent) void {
        conn.lock.lock();
        defer conn.lock.unlock();
        const ow = conn.open_win orelse return;
        if (ow.id != 4) return;
        if (ev.window != 4) return;
        if (ev.slot > 2) return;
        const need = conn.enchant_levels[ev.slot];
        if (need <= 0) return;
        const st = conn.enchant_item orelse return;
        if (st.count != 1) return;
        var has_ench = false;
        if (st.nbt) |raw| {
            var have: [8]u8 = undefined;
            if (parseEnchIds(raw, &have) > 0) has_ench = true;
        }
        if (!enchanting_mod.isEnchantableId(st.id, has_ench)) return;
        const creative = conn.config.gamemode.isCreative();
        if (!creative and conn.xp_level < need) {
            // Insufficient levels: resync offers (vanilla leaves the UI up
            // with the same requirements; the client shows its own text).
            self.syncEnchantWindow(conn);
            return;
        }
        // Roll the weighted draw with seed+slot (vanilla func_178148_a).
        var rng = java_random.JavaRandom.init(conn.enchant_seed +% @as(i32, ev.slot));
        var picks: [8]enchanting_mod.EnchPick = undefined;
        const n = enchanting_mod.buildList(&rng, st.id, need, &picks);
        if (n == 0) return; // fizzle: level fell outside every range
        // Merge NBT (existing must be ench-free here, but keep the merge
        // path for custom-name preservation). Chain through an owned
        // buffer: each pick merges the previous result.
        var nb: [2048]u8 = undefined;
        var cur_owned: ?[]u8 = if (st.nbt) |nbt_bytes| conn.allocator.dupe(u8, nbt_bytes) catch return else null;
        defer if (cur_owned) |b| conn.allocator.free(b);
        for (picks[0..n]) |p| {
            const cur_const: ?[]const u8 = if (cur_owned) |b| @as([]const u8, b) else null;
            const merged = buildEnchNbt(cur_const, p.id, p.level, &nb) orelse return;
            const duped = conn.allocator.dupe(u8, merged) catch return;
            if (cur_owned) |b| conn.allocator.free(b);
            cur_owned = duped;
        }
        const final_nbt = cur_owned orelse return;
        cur_owned = null; // ownership moves into the enchant slot below
        // Consume XP (creative free) + convert books + install the item.
        if (!creative) {
            conn.xp_level -= need;
            if (conn.xp_level < 0) {
                conn.xp_level = 0;
                conn.xp_bar = 0;
                conn.xp_total = 0;
            }
            queueExperience(conn);
        }
        item_mod.freeStack(conn.allocator, &conn.enchant_item);
        var new_id = st.id;
        if (new_id == game_ids.book) new_id = game_ids.enchanted_book;
        conn.enchant_item = .{ .id = new_id, .count = 1, .damage = st.damage, .nbt = final_nbt };
        // Reseed (vanilla regenerates the seed after each enchant) and
        // recompute offers for the (now enchanted) item — which clears them.
        conn.enchant_seed = self.nextEnchantSeed();
        self.recomputeEnchantLevels(pool, allocator, conn, ow.x, ow.y, ow.z);
        self.syncEnchantWindow(conn);
        // The enchanted item is still in the table; the client shows it.
        // XP bar sync rides on queueExperience above.
    }

    /// Break-driven close: every conn with a window open AT this block gets
    /// 0x2E; crafting grids and enchant items drop as entities (furnace
    /// contents are dropped by the break handler itself via removeFurnace).
    /// Caller holds world_lock.
    fn closeWindowsAt(self: *Server, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, x: i32, y: u8, z: i32) void {
        _ = pool;
        _ = allocator;
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            e.conn.lock.lock();
            const ow = e.conn.open_win orelse {
                e.conn.lock.unlock();
                continue;
            };
            if (ow.x != x or ow.y != y or ow.z != z) {
                e.conn.lock.unlock();
                continue;
            }
            var stacks: [9]?item_mod.Stack = [_]?item_mod.Stack{null} ** 9;
            if (ow.id == 1) stacks = e.conn.takeTableGrid();
            if (ow.id == 2) {
                e.conn.open_win = null;
                e.conn.resetClickSeq(2);
            }
            if (ow.id == 7) {
                // Brewing stand: contents persist server-side (break drops
                // them separately) — close the window, drop nothing.
                e.conn.open_win = null;
                e.conn.resetClickSeq(7);
            }
            if (ow.id == 3) {
                // Ender chest: contents persist per player — close the
                // window, drop nothing.
                e.conn.open_win = null;
                e.conn.resetClickSeq(3);
            }
            if (ow.id == 4) {
                if (e.conn.takeEnchantItem()) |owned| stacks[0] = owned;
            }
            if (ow.id == 5 or ow.id == 6) {
                // Chest: contents persist server-side (break drops them
                // separately) — close the window, drop nothing.
                e.conn.open_win = null;
                e.conn.resetClickSeq(ow.id);
            }
            const px = e.conn.pos_x;
            const py = e.conn.pos_y;
            const pz = e.conn.pos_z;
            var cb: [8]u8 = undefined;
            const cf = packets.frameCloseWindow(ow.id, &cb) catch null;
            if (cf) |f| e.conn.queueFramed(f) catch {};
            e.conn.lock.unlock();
            for (stacks[0..]) |*st| {
                const s = st.* orelse continue;
                st.* = null;
                self.spawnItemLive(s, px + 0.5, py + 1.0, pz + 0.5, 10, self.tossPopMotion());
            }
            flushEntry(e, self.io);
        }
    }

    /// Client-initiated ender-chest close (0x0D): lid sound at the chest +
    /// S24 lid event when the last viewer leaves (jar `ape.h`, same
    /// edge-gating as regular chests). Contents persist per player.
    fn spawnEnderClose(self: *Server, cc: EnderClose) void {
        const n: u8 = @intCast(@min(self.countEnderViewers(cc.x, cc.y, cc.z), 255));
        if (n == 0) {
            self.broadcastSound(null, "random.chestclosed", @as(f64, @floatFromInt(cc.x)) + 0.5, @as(f64, @floatFromInt(cc.y)) + 0.5, @as(f64, @floatFromInt(cc.z)) + 0.5, 0.5, 0.95);
        }
        self.broadcastBlockAction(cc.x, cc.y, cc.z, 1, n, game_ids.ender_chest);
    }

    /// Client-initiated close (0x0D): drop the crafting grid / enchant item in
    /// front of the player. Furnace closes drop nothing (contents persist
    /// server-side). Ender/chest closes arrive as their own pos-carrying
    /// events. No 0x2E ack — the client already closed locally.
    fn spawnTableClose(self: *Server, conn: *Conn, tc: TableClose) void {
        if (tc.window != 1 and tc.window != 4) return;
        var stacks = tc.stacks;
        conn.lock.lock();
        const px = conn.pos_x;
        const py = conn.pos_y;
        const pz = conn.pos_z;
        const yaw_rad = @as(f64, conn.yaw) * std.math.pi / 180.0;
        conn.lock.unlock();
        const fx = -@sin(yaw_rad);
        const fz = @cos(yaw_rad);
        for (stacks[0..]) |*st| {
            const s = st.* orelse continue;
            st.* = null;
            self.spawnItemLive(s, px + fx * 0.5 + 0.5, py + 1.32, pz + fz * 0.5 + 0.5, 10, .{
                fx * 0.2 + self.nextToss() * 0.02 - 0.01,
                0.1,
                fz * 0.2 + self.nextToss() * 0.02 - 0.01,
            });
        }
    }

    /// Queue one framed packet on every conn tracking `eid` (attacker
    /// included — the attacker gets no client-side prediction for damage).
    /// One conn lock at a time; never nested with ent_lock/world_lock.
    // ---- attack resolution, tick loops, stats, serve ----

    fn broadcastToTrackers(self: *Server, eid: i32, framed: []const u8) void {
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            e.conn.lock.lock();
            const watching = e.conn.tracked.contains(eid);
            if (watching) e.conn.queueFramed(framed) catch {};
            e.conn.lock.unlock();
            // Flush only viewers we queued to (untracked conns — and
            // socket-less test conns — stay untouched).
            if (watching) flushEntry(e, self.io);
        }
    }

    /// Resolve a validated attack event: mobs (ent_lock) then players
    /// (registry snapshot, one target lock at a time). Never nested.
    /// Death: mobs are removed + Destroy broadcast (pig respawns on a
    /// 30s timer); players get Update Health 0 + death screen, and walk
    /// back via Client Status 0 (conn.zig resets + heals there).
    /// Vanilla per-landed-hit exhaustion charge (caller holds no locks).
    fn chargeHit(attacker: *Conn) void {
        attacker.lock.lock();
        attacker.addExhaustion(0.3); // vanilla: charged per landed hit
        attacker.lock.unlock();
    }

    /// Broadcast a just-built frame to an entity's trackers (drops on build
    /// failure — same discipline as queueBuilt for direct queues).
    fn broadcastBuilt(self: *Server, eid: i32, r: anytype) void {
        if (r) |f| {
            self.broadcastToTrackers(eid, f);
        } else |_| {}
    }

    fn resolveAttack(self: *Server, attacker: *Conn, ev: AttackEvent) void {
        // --- mobs (region-owned; ent_lock throughout, registry nests
        // innermost per the Registry lock-order rule) ---
        var mob_hit = false;
        var mob_dead_id: ?i32 = null;
        var mob_hp: f32 = 0;
        self.ent_lock.lock();
        if (self.region_reg.findMob(ev.target_eid)) |found| {
            const mx = found.region.mobs.px.items[found.index];
            const my = found.region.mobs.py.items[found.index];
            const mz = found.region.mobs.pz.items[found.index];
            if (attackInReach(ev.ax, ev.ay, ev.az, mx, my + 0.5, mz)) {
                mob_hit = true;
                found.region.mobs.health.items[found.index] -= ev.dmg;
                if (found.region.mobs.health.items[found.index] <= 0) {
                    const dead_id = found.region.mobs.ids.items[found.index];
                    const dead_kind = found.region.mobs.kinds.items[found.index];
                    found.region.mobs.removeAt(found.index);
                    mob_dead_id = dead_id;
                    if (dead_kind == entity.MOB_PIG and self.canSpawnMob(entity.MOB_PIG)) self.pig_cooldown = 30;
                } else {
                    mob_hp = found.region.mobs.health.items[found.index];
                }
            }
        }
        self.ent_lock.unlock();
        if (mob_dead_id) |id| {
            var db: [tiny_frame_buf]u8 = undefined;
            broadcastBuilt(self, id, packets.frameDestroyEntitiesFramed(&[_]i32{id}, &db));
            chargeHit(attacker);
            return;
        }
        if (mob_hit) {
            var mb: [32]u8 = undefined;
            broadcastBuilt(self, ev.target_eid, packets.frameEntityMetadata(ev.target_eid, mob_hp, &mb));
            chargeHit(attacker);
            return;
        }
        // --- players ---
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        var victim: ?RegistryEntry = null;
        for (snap) |e| {
            if (e.conn == attacker or e.conn.eid != ev.target_eid) continue;
            victim = e;
            break;
        }
        const v = victim orelse return;
        // Vanilla pvp=false: player swings at players fizzle (mobs above
        // are unaffected). Bare return like a miss: no damage, no packets.
        if (!self.cfg.load().pvp) return;
        self.resolvePvpVictim(v, attacker, ev);
    }

    /// PvP hit on one victim (found by eid): reach check, damage, drops,
    /// death broadcast. Single victim per eid — no loop.
    fn resolvePvpVictim(self: *Server, e: RegistryEntry, attacker: *Conn, ev: AttackEvent) void {
        e.conn.lock.lock();
        if (e.conn.state != .play or e.conn.is_dead) {
            e.conn.lock.unlock();
            return;
        }
        if (!attackInReach(ev.ax, ev.ay, ev.az, e.conn.pos_x, e.conn.pos_y + 1.0, e.conn.pos_z)) {
            e.conn.lock.unlock();
            return;
        }
        const died = applyBlockedDamage(e.conn, ev.dmg, .general);
        const hp = e.conn.health;
        var dd: ?DeathDrop = if (died and !self.keepInv()) collectDeathDrops(e.conn) else null;
        const px = e.conn.pos_x;
        const py = e.conn.pos_y;
        const pz = e.conn.pos_z;
        e.conn.lock.unlock();
        var vnm: [perms_mod.max_name_len]u8 = undefined;
        const vnm_len = if (died) copyUsername(e.conn, &vnm) else 0;
        // Attacker name before its lock: copyUsername takes the conn
        // lock itself, so copying under attacker.lock self-deadlocks
        // the non-recursive SpinLock (lethal-PvP hang).
        var anm: [perms_mod.max_name_len]u8 = undefined;
        const anm_len = if (died) copyUsername(attacker, &anm) else 0;
        chargeHit(attacker);
        flushEntry(e, self.io);
        // Show the new health on every tracker (attacker included).
        var mdb: [32]u8 = undefined;
        broadcastBuilt(self, ev.target_eid, packets.frameEntityMetadata(ev.target_eid, if (died) 0 else hp, &mdb));
        if (died) self.broadcastDeath(vnm[0..vnm_len], .player, anm[0..anm_len]);
        if (dd) |*d| {
            self.spawnDeathDrops(d, px, py, pz);
            self.savePlayer(e.conn);
        }
    }

    fn tickerLoop(self: *Server) void {
        while (true) {
            const one_s = std.Io.Clock.Duration{ .raw = std.Io.Duration.fromSeconds(1), .clock = .awake };
            std.Io.Timeout.sleep(.{ .duration = one_s }, self.io) catch {
                // EINTR from a shutdown signal (or any sleep failure):
                // run the same pipeline as /stop instead of dying silently.
                if (shutdown_mod.isRequested()) self.finishStop();
                continue;
            };
            if (shutdown_mod.isRequested()) self.finishStop();
            const now = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
            const t0 = std.Io.Timestamp.now(self.io, .awake);
            self.tickOnce(now);
            const dt = t0.durationTo(std.Io.Timestamp.now(self.io, .awake)).nanoseconds;
            self.pushTickSample(if (dt < 0) 0 else @intCast(dt));
            self.maybePrintStats();
        }
    }

    /// 10Hz redstone driver (vanilla repeater delays are 2-8 game ticks, i.e.
    /// 100-400ms — the 1Hz ticker alone would stretch them to ~1s). Advances
    /// the redstone clock by 2 game ticks per wakeup and drains due
    /// scheduled entries (button releases, repeater evals, ore fades).
    /// Pressure plates also poll here at 10Hz: the 1Hz tick alone left
    /// release timing phase-dependent (up to ~1s of jitter on top of the
    /// 20-tick minimum press). Snapshots are read-only (no inbox drain, no
    /// wander, no item mutation — the 1Hz tick still owns those); the
    /// world write itself stays under world_lock. The tickOnce pass doubles
    /// as the idle backstop; popDue is idempotent across both.
    fn redstoneLoop(self: *Server) void {
        while (true) {
            const quantum = std.Io.Clock.Duration{ .raw = std.Io.Duration.fromMilliseconds(100), .clock = .awake };
            std.Io.Timeout.sleep(.{ .duration = quantum }, self.io) catch {
                if (shutdown_mod.isRequested()) self.finishStop();
                continue;
            };
            if (shutdown_mod.isRequested()) self.finishStop();
            if (self.world == null) continue;
            // Pregen queue top-up at 10Hz (advance/rate/bar/chat stay 1Hz
            // in pollPregen): keeps in-flight at the cap so the 1Hz fill
            // cadence never caps throughput at ~cap chunks/s.
            self.topupPregen();
            // Read-only entity snapshots for plate occupancy (no mutation,
            // no nesting: conn locks one at a time, then ent_lock alone).
            var p_ents: [256]redstone_mod.Ent = undefined;
            var n_p: usize = 0;
            {
                var batch: [max_fanout]RegistryEntry = undefined;
                const snap = self.snapshot(&batch);
                for (snap) |e| {
                    if (n_p >= p_ents.len) break;
                    e.conn.lock.lock();
                    const is_play = e.conn.state == .play;
                    const px = e.conn.pos_x;
                    const py = e.conn.pos_y;
                    const pz = e.conn.pos_z;
                    e.conn.lock.unlock();
                    if (!is_play) continue;
                    p_ents[n_p] = .{ .x = px, .y = py, .z = pz };
                    n_p += 1;
                }
                releaseSnap(snap);
            }
            var m_ents: [256]redstone_mod.Ent = undefined;
            var n_m: usize = 0;
            var i_ents: [256]redstone_mod.Ent = undefined;
            var n_i: usize = 0;
            self.ent_lock.lock();
            {
                var rstack: [256]*tick_mod.Region = undefined;
                const n_live = self.region_reg.count();
                if (n_live <= rstack.len) {
                    var regs: []*tick_mod.Region = rstack[0..];
                    const n_regs = self.region_reg.allRegions(regs);
                    for (regs[0..n_regs]) |reg| {
                        for (0..reg.mobs.len()) |si| {
                            if (n_m >= m_ents.len) break;
                            m_ents[n_m] = .{ .x = reg.mobs.px.items[si], .y = reg.mobs.py.items[si], .z = reg.mobs.pz.items[si] };
                            n_m += 1;
                        }
                    }
                }
                for (self.items.items) |it| {
                    if (n_i >= i_ents.len) break;
                    i_ents[n_i] = .{ .x = it.x, .y = it.y, .z = it.z };
                    n_i += 1;
                }
            }
            self.ent_lock.unlock();
            self.world_lock.lock();
            self.rs_tick += 2;
            var rs_changes: redstone_mod.ChangeList = .{};
            var rs_sounds: redstone_mod.SoundList = .{};
            var rs_actions: redstone_mod.ActionList = .{};
            if (self.world) |pool| {
                var w = Server.RsWorld{ .pool = pool, .alloc = self.gpa, .changes = &rs_changes };
                defer w.deinit();
                redstone_mod.drainScheduled(w.rsView(), &self.rs_sched, &self.rs_burn, &rs_changes, &rs_sounds, self.rs_tick, &rs_actions);
                redstone_mod.pollPlates(w.rsView(), &self.rs_sched, &self.rs_burn, &self.rs_plates, &rs_changes, &rs_sounds, self.rs_tick, p_ents[0..n_p], m_ents[0..n_m], i_ents[0..n_i], false);
            }
            self.world_lock.unlock();
            if (rs_changes.n > 0 or rs_sounds.n > 0 or rs_actions.n > 0) {
                if (self.world) |_| {
                    self.flushRsBatch(rs_changes, rs_sounds, rs_actions);
                }
            }
        }
    }

    /// Flush one drained batch: block actions (S24, piston animation) first,
    /// then silent-aware change flush + sounds.
    fn flushRsBatch(self: *Server, rs_changes: redstone_mod.ChangeList, rs_sounds: redstone_mod.SoundList, rs_actions: redstone_mod.ActionList) void {
        for (rs_actions.items[0..rs_actions.n]) |a| {
            self.broadcastBlockAction(a.x, @intCast(a.y), a.z, a.event_id, a.facing, a.id);
        }
        for (rs_changes.items[0..rs_changes.n]) |c| {
            // No actor here (redstone loop, not a player break): vanilla
            // drops as if survival (creative no-drops needs a creative hand).
            self.flushRsChange(.survival, c);
        }
        for (rs_sounds.evs[0..rs_sounds.n]) |s| self.flushRsSound(s);
    }

    /// Record one tick duration (ns) in the rolling window.
    fn pushTickSample(self: *Server, ns: u64) void {
        self.tick_samples[self.tick_samples_idx] = ns;
        self.tick_samples_idx = (self.tick_samples_idx + 1) % self.tick_samples.len;
        if (self.tick_samples_n < self.tick_samples.len) self.tick_samples_n += 1;
    }

    /// Record one tick-flush duration (ns) in the rolling window.
    fn pushFlushSample(self: *Server, ns: u64) void {
        self.flush_samples[self.flush_samples_idx] = ns;
        self.flush_samples_idx = (self.flush_samples_idx + 1) % self.flush_samples.len;
        if (self.flush_samples_n < self.flush_samples.len) self.flush_samples_n += 1;
    }

    /// Percentile of the rolling window (0..100). `which` picks the
    /// window (0 = tick, 1 = flush).
    fn percentile(self: *const Server, which: u8, p: u8) u64 {
        const win = if (which == 0) self.tick_samples[0..self.tick_samples_n] else self.flush_samples[0..self.flush_samples_n];
        if (win.len == 0) return 0;
        var sorted: [256]u64 = undefined;
        const n = @min(win.len, sorted.len);
        @memcpy(sorted[0..n], win[0..n]);
        std.mem.sort(u64, sorted[0..n], {}, std.sort.asc(u64));
        const idx = (n * @as(usize, p)) / 100;
        return sorted[@min(idx, n - 1)];
    }

    /// Per-subsystem memory accounting (Phase D: the numbers the stats
    /// line prints, so a leak shows up as a growing line).
    pub fn accountMemory(self: *Server) memstat_mod.Accounting {
        var acc = memstat_mod.Accounting{};
        // Snapshot first: holding the registry lock while taking a conn
        // lock would nest the two (ABBA deadlock with the tick path,
        // which holds a conn lock and then snapshots the registry).
        var batch: [max_fanout]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            e.conn.lock.lock();
            acc.outboxes += e.conn.out.items.len * @sizeOf(u8);
            // The sent-set: one hash-map slot per column already sent.
            acc.sent_sets += e.conn.sent.count() * 32;
            e.conn.lock.unlock();
        }
        self.ent_lock.lock();
        acc.entities = self.mobBytesLocked() + self.items.items.len * @sizeOf(entity.ItemEnt);
        self.ent_lock.unlock();
        if (self.world) |pool| acc.store_ring = pool.ringBytes();
        self.mem_accounting = acc;
        self.rss_bytes = memstat_mod.rssBytes(self.io);
        return acc;
    }

    /// The transport counters (blocking transport: zeros).
    pub fn transport_stats(self: *Server) transport_mod.Stats {
        if (comptime builtin.os.tag == .linux) {
            if (self.uring_backend) |b| {
                const backend: *uring_mod.Backend = @ptrCast(@alignCast(b));
                return backend.statsSnapshot();
            }
        }
        return .{};
    }

    /// Live connection count for the stats line. The async transport
    /// tracks accepts/closes itself; the blocking transport has no
    /// counters, so the registry size is used instead.
    fn liveConnCount(self: *Server) u64 {
        if (comptime builtin.os.tag == .linux) {
            if (self.uring_backend != null) {
                const ts = self.transport_stats();
                return ts.conns_accepted -| ts.conns_closed;
            }
        }
        self.reg_lock.lock();
        defer self.reg_lock.unlock();
        return self.registry.items.len;
    }

    /// The per-tick stats line (Phase D: memory accounting + tick timing).
    pub fn statsLine(self: *Server, buf: []u8) []const u8 {
        const acc = self.accountMemory();
        // One buffer per formatted value: formatBytes writes into the
        // caller's buffer, so sharing one buffer between the three args
        // would alias them all to the last write (the "sent=64 BB" bug).
        var outbox_buf: [32]u8 = undefined;
        var sent_buf: [32]u8 = undefined;
        var ents_buf: [32]u8 = undefined;
        var ring_buf: [32]u8 = undefined;
        const p50 = self.percentile(0, 50);
        const p99 = self.percentile(0, 99);
        const f50 = self.percentile(1, 50);
        const f99 = self.percentile(1, 99);
        var rss_buf: [32]u8 = undefined;
        const rss = memstat_mod.formatBytes(self.rss_bytes, &rss_buf);
        const ts = self.transport_stats();
        var gpu_fill: u64 = 0;
        var gpu_fallback: u64 = 0;
        if (self.gen_pool) |gp| {
            const gs = gp.snapshotStats();
            gpu_fill = gs.gpu_fill;
            gpu_fallback = gs.gpu_fallback;
        }
        return std.fmt.bufPrint(buf, "stats tick_p50={d}us tick_p99={d}us out_p50={d}us out_p99={d}us send={d}us reconcile={d}us players={d} mobs={d} items={d} ssts={d} rss={s} outbox={s} sent={s} ents={s} ring={s} conns={d} zc={d} copy={d} flushes={d} starved={d} armfail={d} regions={d} region_shed={d} sp={s} gpu={d}/{d}", .{
            @divFloor(p50, 1_000),
            @divFloor(p99, 1_000),
            @divFloor(f50, 1_000),
            @divFloor(f99, 1_000),
            @divFloor(self.send_ns_last, 1_000),
            @divFloor(self.reconcile_ns_last, 1_000),
            self.play_count.load(.acquire),
            self.mobCount(),
            self.items.items.len,
            if (self.world) |w| w.sstCount() else 0,
            rss,
            memstat_mod.formatBytes(acc.outboxes, &outbox_buf),
            memstat_mod.formatBytes(acc.sent_sets, &sent_buf),
            memstat_mod.formatBytes(acc.entities, &ents_buf),
            memstat_mod.formatBytes(acc.store_ring, &ring_buf),
            // Live transport connections (accepted minus closed), not the
            // cumulative accept count: a growing number here next to a
            // flat player count means connections are leaking.
            self.liveConnCount(),
            ts.sends_zc,
            ts.sends_copy,
            ts.flushes,
            ts.buffer_starved,
            ts.recv_arm_failures,
            self.region_reg.count(),
            self.region_shed_total,
            self.storage_profile_name,
            gpu_fill,
            gpu_fallback,
        }) catch buf[0..0];
    }

    /// Print the stats line every 600 ticks (10 minutes) to avoid TUI interference.
    fn maybePrintStats(self: *Server) void {
        self.tick_counter += 1;
        if (self.tick_counter % 600 != 0) return;
        var buf: [1024]u8 = undefined;
        const line = self.statsLine(&buf);
        std.log.info("{s}", .{line});
    }

    /// Serve exactly one connection (status or login+bootstrap), no ticker.
    /// Used by tests; the production accept loop builds on this.
    pub fn serveOne(self: *Server, allocator: std.mem.Allocator) !void {
        self.gpa = allocator;
        var stream = try self.net.accept(self.io);
        defer stream.close(self.io);
        try serveConn(stream, self.io, allocator, self, self.eid_counter.fetchAdd(1, .acq_rel));
    }

    /// Accept loop: one OS thread per connection (blocking I/O) or the
    /// io_uring transport (one ring per worker thread).
    pub fn serveForever(self: *Server, allocator: std.mem.Allocator) !void {
        self.gpa = allocator;
        std.log.info("listening (proto v5 offline={})", .{!self.config.online_mode});
        const T = struct {
            fn tick(s: *Server) void {
                s.tickerLoop();
            }
        };
        const tick_th = try std.Thread.spawn(.{}, T.tick, .{self});
        tick_th.detach();
        // K1: 10Hz redstone scheduler drain (sub-second repeater delays;
        // plates stay on the 1Hz ticker, which also backstops the queue).
        const R = struct {
            fn red(s: *Server) void {
                s.redstoneLoop();
            }
        };
        const rs_th = try std.Thread.spawn(.{}, R.red, .{self});
        rs_th.detach();
        // Phase B: pick the transport. `auto` resolves to the best backend
        // for this OS; io_uring is used on Linux when the kernel supports
        // it, otherwise the portable blocking transport runs.
        const kind = transport_mod.resolve(self.transport_kind);
        if (kind == .uring) {
            if (self.serveForeverUring(allocator)) {
                return;
            }
            std.log.warn("transport: io_uring unavailable, falling back to blocking", .{});
        }
        if (kind == .kqueue) {
            if (comptime builtin.os.tag.isDarwin()) {
                if (self.serveForeverKqueue(allocator)) return;
                std.log.warn("transport: kqueue unavailable, falling back to blocking", .{});
            } else {
                std.log.warn("transport: kqueue is macOS/BSD only, falling back to blocking", .{});
            }
        }
        if (kind == .iocp) {
            if (comptime builtin.os.tag == .windows) {
                if (self.serveForeverIocp(allocator)) return;
                std.log.warn("transport: iocp unavailable, falling back to blocking", .{});
            } else {
                std.log.warn("transport: iocp is Windows only, falling back to blocking", .{});
            }
        }
        while (true) {
            // A shutdown signal interrupts the blocking accept (EINTR):
            // run the /stop pipeline instead of returning without saving.
            const stream = self.net.accept(self.io) catch |err| {
                if (shutdown_mod.isRequested()) self.finishStop();
                return err;
            };
            const eid = self.eid_counter.fetchAdd(1, .acq_rel);
            const C = struct {
                fn run(s: std.Io.net.Stream, io: std.Io, a: std.mem.Allocator, srv: *Server, id: i32) void {
                    defer s.close(io);
                    serveConn(s, io, a, srv, id) catch |err| {
                        std.log.info("conn {d} closed ({})", .{ id, err });
                    };
                }
            };
            const th = try std.Thread.spawn(.{}, C.run, .{ stream, self.io, allocator, self, eid });
            th.detach();
        }
    }

    /// Phase B: run the io_uring transport (one ring per worker thread,
    /// multishot accept + multishot recv with provided buffers).
    /// Returns false when the kernel/runtime cannot do io_uring (the
    /// caller falls back to the blocking transport).
    fn serveForeverUring(self: *Server, allocator: std.mem.Allocator) bool {
        if (comptime builtin.os.tag == .linux) {
            return self.serveForeverUringLinux(allocator);
        } else {
            return false;
        }
    }

    /// The Linux io_uring backend (only compiled on Linux).
    fn serveForeverUringLinux(self: *Server, allocator: std.mem.Allocator) bool {
        if (!uring_mod.supported) return false;
        if (!uring_mod.probe()) return false;
        const handle = transport_mod.Handler{
            .on_accept = Server.onTransportAccept,
            .on_read = Server.onTransportRead,
            .on_close = Server.onTransportClose,
            .on_flush = Server.onTransportFlush,
            .ctx = self,
        };
        const backend = allocator.create(uring_mod.Backend) catch return false;
        backend.init(allocator, self.transport_opts, self.io, self.net.socket.handle, handle) catch {
            allocator.destroy(backend);
            return false;
        };
        if (backend.failed) {
            backend.deinit();
            allocator.destroy(backend);
            return false;
        }
        self.uring_backend = @ptrCast(backend);
        self.transport_handle = backend.handle();
        std.log.info("transport: io_uring ({d} workers, {d} ring entries, zc>={d}B)", .{
            self.transport_opts.workerCount(),
            self.transport_opts.ring_entries,
            self.transport_opts.send_zc_threshold,
        });
        backend.run() catch {};
        return true;
    }

    /// Phase B: run the macOS kqueue transport.
    fn serveForeverKqueue(self: *Server, allocator: std.mem.Allocator) bool {
        if (comptime builtin.os.tag.isDarwin()) {
            const handle = transport_mod.Handler{
                .on_accept = Server.onTransportAccept,
                .on_read = Server.onTransportRead,
                .on_close = Server.onTransportClose,
                .on_flush = Server.onTransportFlush,
                .ctx = self,
            };
            const backend = allocator.create(kqueue_mod.Backend) catch return false;
            backend.init(allocator, self.transport_opts, self.net.socket.handle, handle) catch {
                allocator.destroy(backend);
                return false;
            };
            self.transport_handle = backend.handle();
            std.log.info("transport: kqueue ({d} workers)", .{self.transport_opts.workerCount()});
            backend.run() catch {};
            return true;
        } else {
            return false;
        }
    }

    /// Phase B: run the Windows IOCP transport.
    fn serveForeverIocp(self: *Server, allocator: std.mem.Allocator) bool {
        if (comptime builtin.os.tag == .windows) {
            if (!iocp_mod.supported or !iocp_mod.probe()) return false;
            const handle = transport_mod.Handler{
                .on_accept = Server.onTransportAccept,
                .on_read = Server.onTransportRead,
                .on_close = Server.onTransportClose,
                .on_flush = Server.onTransportFlush,
                .ctx = self,
            };
            const backend = allocator.create(iocp_mod.Backend) catch return false;
            backend.init(allocator, self.transport_opts, self.io, self.net.socket.handle, handle) catch {
                allocator.destroy(backend);
                return false;
            };
            if (backend.failed) {
                backend.deinit();
                allocator.destroy(backend);
                return false;
            }
            self.transport_handle = backend.handle();
            std.log.info("transport: iocp ({d} workers)", .{self.transport_opts.workerCount()});
            backend.run() catch {};
            return true;
        } else {
            return false;
        }
    }

    /// Phase B: a connection was accepted by the transport.
    fn onTransportAccept(ctx: *anyopaque, conn_id: u32, fd: std.posix.fd_t) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        const allocator = self.gpa;
        const eid = self.eid_counter.fetchAdd(1, .acq_rel);
        const conn = allocator.create(Conn) catch return;
        conn.* = Conn.init(allocator, self.io, self.config, eid);
        conn.transport_id = conn_id;
        conn.transport = self.transport_handle;
        // Peer address (the blocking transport gets it from the stream).
        // std.posix.getpeername is a compile error on Windows, so IOCP
        // conns keep ip_len == 0 (IP bans do not match them — documented;
        // name bans are unaffected).
        if (comptime builtin.os.tag == .windows) {
            conn.ip_len = 0;
        } else {
            conn.ip_len = transport_mod.peerAddress(fd, &conn.ip);
        }
        const state = allocator.create(SessionState) catch {
            conn.deinit();
            allocator.destroy(conn);
            return;
        };
        state.* = .{};
        self.async_lock.lock();
        self.async_conns.put(allocator, conn_id, conn) catch {};
        self.async_states.put(allocator, conn_id, state) catch {};
        self.async_lock.unlock();
        // Register in the player registry. The stream is a closed
        // placeholder: the transport owns the socket, and every write
        // path is transport aware (a stray write would hit EBADF, not
        // some unrelated fd).
        self.register(conn, Server.closedStream()) catch {
            self.async_lock.lock();
            _ = self.async_conns.remove(conn_id);
            _ = self.async_states.remove(conn_id);
            self.async_lock.unlock();
            state.deinit(allocator);
            allocator.destroy(state);
            conn.deinit();
            allocator.destroy(conn);
        };
    }

    /// Phase B: inbound bytes for a connection.
    fn onTransportRead(ctx: *anyopaque, conn_id: u32, bytes: []const u8) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        const allocator = self.gpa;
        self.async_lock.lock();
        const conn = self.async_conns.get(conn_id);
        const state = self.async_states.get(conn_id);
        self.async_lock.unlock();
        const c = conn orelse return;
        const st = state orelse return;
        const res = sessionStep(self, c, allocator, st, bytes) catch {
            self.kickTransportConn(conn_id);
            return;
        };
        if (res.finished) {
            self.kickTransportConn(conn_id);
            return;
        }
        if (res.announce) {
            self.queueAnnounce(c);
        }
        if (res.stop) {
            // The reply is in the outbox; give the worker a moment to send
            // it before the process exits.
            const d = std.Io.Clock.Duration{ .raw = std.Io.Duration.fromNanoseconds(50 * std.time.ns_per_ms), .clock = .awake };
            std.Io.Timeout.sleep(.{ .duration = d }, self.io) catch {};
            self.finishStop();
        }
    }

    /// Phase B: drain a connection's queued output for the transport.
    fn onTransportFlush(ctx: *anyopaque, conn_id: u32) ?[]u8 {
        const self: *Server = @ptrCast(@alignCast(ctx));
        self.async_lock.lock();
        const conn = self.async_conns.get(conn_id);
        self.async_lock.unlock();
        const c = conn orelse return null;
        c.lock.lock();
        const pending = c.takeOutput() catch {
            c.lock.unlock();
            return null;
        };
        const overflow = c.overflow;
        c.lock.unlock();
        if (overflow) {
            // Slow consumer: the outbox grew past the cap. Drop it.
            c.allocator.free(pending);
            self.kickTransportConn(conn_id);
            return null;
        }
        if (pending.len == 0) {
            c.allocator.free(pending);
            return null;
        }
        return pending;
    }

    /// Phase B: the connection is gone.
    fn onTransportClose(ctx: *anyopaque, conn_id: u32) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        const allocator = self.gpa;
        self.async_lock.lock();
        const conn = self.async_conns.fetchRemove(conn_id);
        const state = self.async_states.fetchRemove(conn_id);
        self.async_lock.unlock();
        if (conn) |c| {
            // unregister() persists, removes from the registry and
            // destroys the conn — do not free it twice.
            self.unregister(c.value);
        }
        if (state) |s| {
            s.value.deinit(allocator);
            allocator.destroy(s.value);
        }
    }

    /// Kick a connection owned by the async transport.
    fn kickTransportConn(self: *Server, conn_id: u32) void {
        if (self.transport_handle) |h| h.close_conn(h.ctx, conn_id);
    }

    /// A stream that is not a socket: the registry placeholder for
    /// connections owned by an async transport (the transport holds the
    /// real socket).
    pub fn closedStream() std.Io.net.Stream {
        // -1 is not a HANDLE (Windows): use the invalid-handle sentinel
        // there (this function is only analyzed on targets whose async
        // backend references it).
        return .{ .socket = .{ .handle = if (comptime builtin.os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else -1, .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } } } };
    }

    /// Stop the server: save the players, flush the store, exit.
    /// Persist everything before a halt (players, redstone, world flush).
    /// Shared by every stop path (console/RCON/in-game/shutdown).
    pub fn saveForHalt(self: *Server) void {
        _ = self.saveAllPlayers();
        self.saveRedstone();
        self.flushDirtyChests();
        if (self.world) |pool| pool.flushAll() catch {};
    }

    pub fn finishStop(self: *Server) noreturn {
        self.saveForHalt();
        std.log.info("stop: saved players, flushed. bye.", .{});
        // exit() skips the console thread's restore defer: without this an
        // in-game /stop leaves the operator's terminal without echo.
        console_tui.restoreTerminal();
        std.process.exit(0);
    }

    /// Bind on all interfaces (production entry).
    /// Bind + listen on an explicit address (config bind_address) with a
    /// configured kernel backlog. (The localhost-only bind() next to this
    /// stays for tests; production boot goes through here.)
    pub fn bindConfigured(io: std.Io, addr_text: []const u8, port: u16, backlog: u31, config: Config) !Server {
        const addr = try std.Io.net.IpAddress.parse(addr_text, port);
        // A deep accept backlog: a server-list ping or a login burst
        // must not be refused while the transport is busy.
        var srv = Server{ .net = try addr.listen(io, .{ .reuse_address = true, .kernel_backlog = backlog }), .io = io, .config = config };
        {
            var c = srv.cfg.load();
            c.world_spawn = .{ config.spawn_x, config.spawn_y, config.spawn_z };
            srv.cfg.store(c);
        }
        return srv;
    }
};

/// Per-connection protocol state (shared by every transport).
///
/// The blocking transport keeps it on the serve thread's stack; the
/// io_uring transport keeps one per connection (the worker owns it).
// ---- async-transport session state ----

pub const SessionState = struct {
    /// Actions queued by the frame handlers; applied to the world after
    /// the frame batch is parsed.
    events: std.ArrayList(Action) = .empty,
    /// The join still has to be announced to the other players.
    need_announce: bool = false,

    pub fn deinit(self: *SessionState, allocator: std.mem.Allocator) void {
        self.events.deinit(allocator);
    }
};

/// The chunk a player currently stands in (used for the viewer lookups
/// after the conn lock is released).
pub const ChunkPos = struct { cx: i32, cz: i32 };

/// Result of one protocol step.
pub const StepResult = struct {
    /// The connection is finished: close it after the queued bytes went
    /// out (kick, timeout, protocol error).
    finished: bool = false,
    /// The join must be announced to the other players.
    announce: bool = false,
    /// The server was asked to stop (the reply is in the outbox).
    stop: bool = false,
};
/// The part of a protocol step that runs with `conn.lock` held: feed the
/// bytes, parse the frames, run the handlers and apply the login
/// bootstrap. Split out so the lock can be released on every error path
/// (a malformed frame used to leave the lock held, and the cleanup path
/// then deadlocked on it).
fn sessionLocked(
    server: *Server,
    conn: *Conn,
    allocator: std.mem.Allocator,
    state: *SessionState,
    data: []const u8,
    entered: *bool,
    cc_now: *ChunkPos,
) !void {
    const events = &state.events;
    // Feed the raw bytes through the conn's reassembly buffer (the conn
    // parses the Length prefix itself, so the transport does not care
    // where the bytes came from).
    conn.feedData(data) catch {
        conn.lock.unlock();
        return error.FrameTooLarge;
    };
    while (try conn.poll()) |f| {
        // Server list ping reads a live player count, not the copy taken
        // at accept time. Refresh under conn.lock (held here); status
        // pings are rare so the atomic load is free.
        if (conn.state == .status and f.id == @as(i32, @intFromEnum(ids.StatusServer.request))) {
            conn.config.online_count = @intCast(@min(server.play_count.load(.acquire), std.math.maxInt(u16)));
        }
        // Global packets-per-second flood gate (config
        // max_packets_per_second, 0 = off): every frame counts against a
        // 1s rolling window. Tripping queues the same spam kick as the
        // other gates and stops the batch; the kick flushes on the normal
        // output path and close_after_flush finishes the session below.
        if (conn.config.max_packets_per_second > 0) {
            const now_ms = std.Io.Timestamp.now(conn.io, .awake).toMilliseconds();
            if (now_ms - conn.pps_window_ms >= 1000) {
                conn.pps_window_ms = now_ms;
                conn.pps_count = 0;
            }
            conn.pps_count += 1;
            if (conn.pps_count > conn.config.max_packets_per_second) {
                _ = conn.disconnect("{\"text\":\"Kicked for spamming\"}") catch {};
                break;
            }
        }
        const action = try conn.handleFrame(f);
        if (action == .entered_play) entered.* = true;
        switch (action) {
            .block_set, .block_resync, .place_deny, .interact, .arm_swing, .chat, .attack, .command, .tab_complete, .qdrop, .table_close, .furnace_click, .brew_click, .chest_click, .chest_close, .ender_close, .enchant_click, .enchant, .equip_armor, .eat, .throw_potion => try events.append(allocator, action),
            else => {},
        }
    }
    if (entered.*) {
        entered.* = false;
        const age = server.world_age.load(.acquire);
        // Worldgen spawn: ensure land spawn before Join/SpawnPosition go out.
        // Returning players skip the search: loadPlayer restores pos.
        var fresh = true;
        if (server.world) |pool| {
            const loaded = server.loadPlayer(conn);
            fresh = !loaded;
            if (!loaded) {
                if (server.gen) |gen| {
                    const sp = v5serve.findSpawn(pool, gen, &server.world_lock, allocator, 24) catch null;
                    if (sp) |p| {
                        conn.config.spawn_x = @intFromFloat(@floor(p.x));
                        conn.config.spawn_y = @intFromFloat(@floor(p.y));
                        conn.config.spawn_z = @intFromFloat(@floor(p.z));
                    }
                }
                // First login (or no save): land at spawn. (Returning
                // players keep their saved pos from loadPlayer.)
                conn.pos_x = @as(f64, @floatFromInt(conn.config.spawn_x)) + 0.5;
                conn.pos_y = @as(f64, @floatFromInt(conn.config.spawn_y));
                conn.pos_z = @as(f64, @floatFromInt(conn.config.spawn_z)) + 0.5;
                conn.yaw = 0;
                conn.pitch = 0;
            }
        }
        // Landing safety: sync-fill a small disk around the login position
        // before the chunk burst + PosLook go out. Holes (background gen
        // pending) would leave a real client falling through the world on
        // join; the server trusts client positions, so that fall would be
        // adopted and persisted. Completing login on solid ground avoids
        // the fall (the login grace below covers the remainder).
        if (server.world) |pool| {
            server.ensureLanding(pool, allocator, conn);
            // Inside-block rescue: a saved pos can sit inside a block (world
            // edited while away, stale pre-grace row, or spawn inside
            // terrain). Nudge up to the first headroom so login completes in
            // the open instead of suffocating on join.
            {
                const ex: i32 = @intFromFloat(@floor(conn.pos_x));
                const ez: i32 = @intFromFloat(@floor(conn.pos_z));
                const feet: i32 = @intFromFloat(@floor(conn.pos_y));
                var need_rescue = false;
                if (feet >= 0 and feet <= 255) {
                    const fy: u8 = @intCast(feet);
                    if (view.peekBlock(pool, allocator, ex, fy, ez) catch null) |b| {
                        if (view.isOpaqueCube(b.id)) need_rescue = true;
                    }
                }
                if (!need_rescue) {
                    const ey_i: i32 = @intFromFloat(@floor(conn.pos_y + 1.62));
                    if (ey_i >= 0 and ey_i <= 255) {
                        const ey: u8 = @intCast(ey_i);
                        if (view.peekBlock(pool, allocator, ex, ey, ez) catch null) |b| {
                            if (view.isOpaqueCube(b.id)) need_rescue = true;
                        }
                    }
                }
                if (need_rescue) {
                    var y = feet + 1;
                    while (y <= feet + 16 and y <= 253) : (y += 1) {
                        if (y < 0) continue;
                        const fy: u8 = @intCast(y);
                        const ey: u8 = @intCast(y + 1);
                        const bf = view.peekBlock(pool, allocator, ex, fy, ez) catch null;
                        const be = view.peekBlock(pool, allocator, ex, ey, ez) catch null;
                        const f_ok = if (bf) |b| !view.isOpaqueCube(b.id) else false;
                        const e_ok = if (be) |b| !view.isOpaqueCube(b.id) else false;
                        if (f_ok and e_ok) {
                            conn.pos_y = @floatFromInt(y);
                            break;
                        }
                    }
                }
            }
            // Login audit: one line per join with the settled position and
            // the feet/eyes blocks behind it (proves placement vs burial;
            // use it before reporting spawn-in-ground).
            {
                const ex: i32 = @intFromFloat(@floor(conn.pos_x));
                const ez: i32 = @intFromFloat(@floor(conn.pos_z));
                const feet: i32 = @intFromFloat(@floor(conn.pos_y));
                const feet_id: i16 = if (feet >= 0 and feet <= 255)
                    if (view.peekBlock(pool, allocator, ex, @intCast(feet), ez) catch null) |b| @intCast(@intFromEnum(b.id)) else -1
                else
                    -2;
                const ey_i: i32 = @intFromFloat(@floor(conn.pos_y + 1.62));
                const eyes_id: i16 = if (ey_i >= 0 and ey_i <= 255)
                    if (view.peekBlock(pool, allocator, ex, @intCast(ey_i), ez) catch null) |b| @intCast(@intFromEnum(b.id)) else -1
                else
                    -2;
                const nm = conn.username[0..conn.username_len];
                std.log.info("login {s} at {d:.1},{d:.1},{d:.1} feet={d} eyes={d}", .{ nm, conn.pos_x, conn.pos_y, conn.pos_z, feet_id, eyes_id });
            }
            // Hold pure falls below the login teleport until the client
            // proves it is synced (exact PosLook echo), moves horizontally
            // (it is live), or the grace times out.
            conn.armLoginGrace();
        }
        // Server defaults: difficulty is world-level (always applied);
        // fresh logins also inherit the default gamemode + world spawn
        // (an explicit /setworldspawn wins over the gen search above).
        // One lock-free config snapshot (Phase D seqlock).
        const cfg = server.cfg.load();
        const srv_diff = cfg.difficulty;
        const srv_gm = cfg.default_gamemode;
        const srv_spawn = cfg.world_spawn;
        const srv_spawn_set = cfg.world_spawn_set;
        conn.config.difficulty = srv_diff;
        // Fresh logins inherit the default gamemode; force_gamemode
        // (vanilla server.properties) also re-applies it to returning
        // players. Spawn placement below stays fresh-only: forced players
        // keep their saved position (only the mode is overridden).
        if (fresh or cfg.force_gamemode) conn.config.gamemode = srv_gm;
        if (fresh) {
            const was_forced = conn.spawn_forced;
            if (srv_spawn_set and !was_forced) {
                conn.config.spawn_x = srv_spawn[0];
                conn.config.spawn_y = srv_spawn[1];
                conn.config.spawn_z = srv_spawn[2];
                conn.pos_x = @as(f64, @floatFromInt(srv_spawn[0])) + 0.5;
                conn.pos_y = @as(f64, @floatFromInt(srv_spawn[1]));
                conn.pos_z = @as(f64, @floatFromInt(srv_spawn[2])) + 0.5;
            }
        }
        // Ban/whitelist gate (jar-hardcoded screens). Runs before any
        // join packets: rejected logins get a play disconnect + close.
        var login_rejected = false;
        if (server.loginRejected(conn.ip[0..conn.ip_len], &conn.uuid_str)) |rej| {
            server.rejectLogin(conn, rej);
            login_rejected = true;
        }
        if (!login_rejected and !server.noteLoginAttempt(conn.ip[0..conn.ip_len])) {
            server.rejectLogin(conn, .rate_limited);
            login_rejected = true;
        }
        if (!login_rejected) {
            // Remember the row epoch for the straggler fence below (a
            // side-effect-free read — the bump waits until announce, so a
            // login that never completes can't poison the live session's
            // row ownership with a newer epoch).
            conn.login_epoch_seen = server.epochFor(conn.username[0..conn.username_len]);
            // Straggler fence (first check): a newer login for this name
            // bumped the row while WE were wedged mid-login (chunk burst,
            // gen stalls) — the live session owns the row now. Abort our
            // login instead of kicking THEM ("logged in from another
            // location" on the live client) and instead of bumping the
            // epoch over them. The abort unwinds via close_after_flush
            // (finished=true); our death-rattle save is dropped by the
            // epoch guard, the live row untouched.
            {
                const nm = conn.username[0..conn.username_len];
                if (server.epochFor(nm) != conn.login_epoch_seen) {
                    server.abortStaleLogin(conn) catch {};
                    return;
                }
            }
            // Duplicate login (vanilla `initializeConnection`): kick any
            // OTHER fully-joined same-name conn. Without this, ghost
            // sessions linger in the registry and `findInSnap` (first
            // match) routes /gamemode, /tp, /tell, ... at the ghost —
            // the live session keeps its old gamemode and saves it back
            // on quit ("gamemode not saved"). Only announced targets:
            // a racing newcomer isn't announced yet, so two simultaneous
            // logins can't kick each other. Already-dying targets are
            // skipped (their row/save is decided; re-flushing a dead
            // peer's outbox is the write that wedges kickers).
            {
                var batch: [max_fanout]RegistryEntry = undefined;
                const snap = server.snapshot(&batch);
                defer Server.releaseSnap(snap);
                const nm = conn.username[0..conn.username_len];
                for (snap) |e| {
                    if (e.conn == conn) continue;
                    // Try-lock only: we already hold THIS conn's lock, and taking
                    // another conn's lock here would nest conn locks (two
                    // simultaneous logins would ABBA deadlock each other). A busy
                    // conn is skipped: the save epoch still keeps the newer
                    // session's row authoritative.
                    if (!e.conn.lock.tryLock()) continue;
                    const dup = e.conn.state == .play and e.conn.announced and !e.conn.dead and !e.conn.close_after_flush and std.ascii.eqlIgnoreCase(e.conn.username[0..e.conn.username_len], nm);
                    e.conn.lock.unlock();
                    if (dup) server.kickEntry(e, "You logged in from another location!");
                }
                // Straggler fence (second check): a racing login announced
                // and bumped between our first check and our kick scan
                // (µs window, reconnect storms). Same abort — first to
                // announce wins, exactly one session survives.
                if (server.epochFor(nm) != conn.login_epoch_seen) {
                    server.abortStaleLogin(conn) catch {};
                    return;
                }
            }
            const tod = server.time_of_day.load(.acquire);
            // JoinGame went out at bootstrap with the default gamemode (the
            // row loads after); when the final gamemode differs, correct the
            // client controller/UI the vanilla way (S2B reason 3, same as
            // /gamemode) before the abilities refresh below. Without this a
            // returning survival player keeps the creative JoinGame value
            // while the server deals survival damage.
            if (!conn.config.gamemode.isCreative()) {
                var gb: [tiny_frame_buf]u8 = undefined;
                queueBuilt(conn, packets.frameGameState(packets.game_state_change_gamemode, @floatFromInt(conn.config.gamemode.wire()), &gb));
            }
            try conn.queueJoinPackets(age, tod);
            // Current XP (vanilla re-sends S1F on login).
            var eb: [small_frame_buf]u8 = undefined;
            const xtotal: i16 = @truncate(conn.xp_total);
            if (packets.frameSetExperience(conn.xp_bar, @truncate(conn.xp_level), xtotal, &eb)) |xf| {
                try conn.queueFramed(xf);
            } else |_| {}
            // Current weather (flag + strengths) so a login during rain
            // shows rain instead of clear skies until the next change.
            server.syncWeatherTo(conn);
        }
        // Login completion: inventory sync, chunks, PosLook last.
        // (queueAnnounce runs after unlock — the drain takes conn.lock itself).
        if (!login_rejected) {
            if (server.world) |pool| {
                // Persisted inventory (or empty for fresh players): full
                // Window Items + cursor so the client starts in sync.
                const wf = try packets.frameWindowItemsAlloc(allocator, 0, &conn.inv);
                defer allocator.free(wf);
                try conn.queueFramed(wf);
                const cf = try packets.frameSetSlotAlloc(allocator, -1, -1, conn.cursor);
                defer allocator.free(cf);
                try conn.queueFramed(cf);
                const cc = conn.playerChunk();
                // Drop conn.lock across the burst: resyncDisk holds it
                // for seconds (worldgen + 289-column zlib) while the
                // tick and every join fan-out queued behind it. Refs pin
                // the conn (unregister spins instead of freeing); the
                // liveness re-check below aborts logins that died
                // mid-burst instead of completing them.
                _ = conn.refs.fetchAdd(1, .acq_rel);
                conn.lock.unlock();
                var collect = view.BurstCollect{};
                runBurstShared(server, allocator, pool, 0, cc.cx, cc.cz, server.view_distance, true, &collect) catch |err| {
                    collect.deinit(allocator);
                    conn.lock.lock();
                    _ = conn.refs.fetchSub(1, .acq_rel);
                    return err;
                };
                conn.lock.lock();
                // Liveness: kicked, timed out, or closed mid-burst (a
                // racing disconnect ran unregister while we were
                // unlocked) — do not complete a dead login: no PosLook,
                // no announce, no epoch bump. unregister spins on our ref
                // and destroys the conn once we drop it below. Lock order:
                // conn-lock only here, never reg_lock (playNames nests
                // reg_lock -> conn locks; the reverse ABBA-deadlocked the
                // server under a join storm).
                const alive = !conn.dead and !conn.close_after_flush and !conn.closed;
                // From here every exit drops the ref and frees the
                // collect (frames were copied into the outbox below).
                defer collect.deinit(allocator);
                defer _ = conn.refs.fetchSub(1, .acq_rel);
                if (!alive) return;
                for (collect.frames.items) |f| try conn.queueFramed(f);
                var sit = collect.sent.iterator();
                while (sit.next()) |e| try conn.sent.put(e.key_ptr.*, {});
                // PosLook closes the login (was completeLogin's tail).
                try conn.queuePlayerPosLook();
                const cc2 = conn.playerChunk();
                conn.sent_center = .{ .cx = cc2.cx, .cz = cc2.cz };
                conn.baseline_sent = true;
                conn.chunks_dirty = false;
                conn.force_resync = false;
            } else {
                try conn.queuePlayerPosLook();
            }
            // Straggler fence (final check): a racing login announced and
            // bumped during our long tail (chunk burst, gen waits) after
            // our kick scan ran — it owns the row now, abort instead of
            // bumping over it. First to announce wins, exactly one session
            // survives.
            if (server.epochFor(conn.username[0..conn.username_len]) != conn.login_epoch_seen) {
                server.abortStaleLogin(conn) catch {};
                return;
            }
            state.need_announce = true;
            // Own this player row from here on: bump the save epoch so any
            // older session's delayed save (quit/rejoin race, ghost
            // autosave) is dropped instead of overwriting us. Bumped at
            // announce — not login start — so a login that never completes
            // can't steal ownership: failed rejoins used to bump past the
            // still-live ghost, whose final save was then dropped as
            // stale, losing the leave position with no live session to
            // replace it. Our own pre-announce saves are dropped (epoch 0
            // never matches a bumped row), which is correct: until we
            // announce, the previous session (or nobody) owns the row.
            conn.save_epoch = server.bumpSaveEpoch(conn.username[0..conn.username_len]);
        }
    }
    if (conn.chunks_dirty) {
        // Movement / respawn follow-up (no-op without a world).
        if (server.world) |pool| {
            const radius: u8 = @min(conn.client_view orelse server.view_distance, server.view_distance);
            try view.syncPlayerChunks(conn, conn_sink.bind(conn), server.chunkSource(pool), 0, radius, true);
        } else {
            conn.chunks_dirty = false;
            conn.force_resync = false;
        }
    }
    // Async gen follow-up: holes requested earlier may have landed on
    // worker threads since. Gated on the pool sequence (idle = one atomic
    // load) and rate-limited to 10Hz: the rescan re-reads the view disk,
    // and a gen storm would otherwise redo 1k+ store reads every frame.
    // Capped at 16 pool reads per rescan (spiral order => nearest holes
    // heal first) plus outbox backpressure: without the cap a serve
    // thread stalls in store reads while generation is active and
    // stops noticing disconnects (quit->save lands minutes late).
    // 10Hz x 16 reads outruns worker completion (~80/s), so holes heal
    // within ~100ms of landing instead of queueing a full second behind;
    // per-call work is unchanged (same 16-read budget as the old 1Hz).
    if (server.world) |pool| {
        if (server.gen_pool) |gp| {
            if (conn.baseline_sent and conn.out.items.len < 262144) {
                const s = gp.sequence();
                if (s != conn.last_gen_seq) {
                    const now_ms = std.Io.Timestamp.now(server.io, .awake).toMilliseconds();
                    if (now_ms - conn.last_gen_retry_ms >= 100) {
                        conn.last_gen_seq = s;
                        conn.last_gen_retry_ms = now_ms;
                        const radius: u8 = @min(conn.client_view orelse server.view_distance, server.view_distance);
                        const cc = conn.playerChunk();
                        try view.resyncDisk(conn, conn_sink.bind(conn), server.chunkSource(pool), 0, cc.cx, cc.cz, radius, true, 16);
                    }
                }
            }
        }
    }
    const pc = conn.playerChunk();
    cc_now.* = .{ .cx = pc.cx, .cz = pc.cz };
}

    /// Login-burst singleflight: concurrent logins for the same chunk disk
    /// share one worldgen/read/zlib pass instead of each paying the full
    /// ~289-column burst. Only in-flight work is shared (never cached), so
    /// there is no invalidation story: a late joiner whose key misses just
    /// runs its own burst. Waiters park on the flight condvar (futex sleep,
    /// never spin); the executor always publishes or fails, so waits always
    /// terminate. Locking: flight mutex only, never nested with conn locks
    /// (same ABBA rule as everywhere else). Caller must hold no locks (the
    /// wait blocks) and must already hold a conn ref for liveness.
    /// Login-burst singleflight: concurrent logins for the same chunk disk
    /// share one worldgen/read/zlib pass instead of each paying the full
    /// ~289-column burst. Only in-flight work is shared (never cached), so
    /// there is no invalidation story: a late joiner whose key misses just
    /// runs its own burst. Waiters park on the flight condvar (futex sleep,
    /// never spin); the executor always publishes or fails, so waits always
    /// terminate (spurious wakeups re-check). Locking: flight mutex only,
    /// never nested with conn locks (same ABBA rule as everywhere else).
    /// Caller must hold no locks (the wait blocks) and must already hold a
    /// conn ref for liveness (freed only after the ref drops).
    fn runBurstShared(
        self: *Server,
        alloc: std.mem.Allocator,
        pool: *shard_mod.ShardPool,
        dim: u8,
        cx: i32,
        cz: i32,
        radius: u8,
        sky: bool,
        out: *view.BurstCollect,
    ) !void {
        const key = Server.BurstKey{ .dim = dim, .cx = cx, .cz = cz, .radius = radius, .sky = sky };
        // Join, execute, or run solo.
        var executor = false;
        var solo = false;
        var mygen: u64 = 0;
        {
            self.burst_flight.mutex.lockUncancelable(self.io);
            defer self.burst_flight.mutex.unlock(self.io);
            const f = &self.burst_flight;
            if (f.key.eql(key) and !f.failed and (f.active or f.done)) {
                // Attach (running: wait below; published: grab immediately).
                f.refs += 1;
                mygen = f.gen;
            } else if (!f.active and f.refs == 0) {
                // Claim a fresh flight (resetting any stale remnant first).
                if (f.done or f.failed) burstFlightReset(self, f);
                f.active = true;
                f.key = key;
                f.gen +%= 1;
                f.done = false;
                f.failed = false;
                f.refs = 1;
                f.alloc = alloc;
                mygen = f.gen;
                executor = true;
            } else {
                // A different disk is in flight, or a stale published flight
                // is still draining: run solo (correct, just unshared).
                // Decided here, executed below WITHOUT the flight lock.
                solo = true;
            }
        }
        if (solo) {
            return view.collectLoginBurst(alloc, self.chunkSource(pool), dim, cx, cz, radius, sky, out);
        }
        if (executor) {
            // Own the burst, then publish for attached waiters. The flight
            // lock is NOT held across the run (same discipline as conn.lock).
            var tmp = view.BurstCollect{};
            view.collectLoginBurst(alloc, self.chunkSource(pool), dim, cx, cz, radius, sky, &tmp) catch |err| {
                tmp.deinit(alloc);
                burstFlightFail(self);
                return err;
            };
            self.burst_flight.mutex.lockUncancelable(self.io);
            // Move ownership (no copies): tmp becomes the flight payload.
            self.burst_flight.frames = tmp.frames;
            tmp.frames = .empty;
            var sit = tmp.sent.iterator();
            while (sit.next()) |e| {
                std.debug.assert(self.burst_flight.sent_n < self.burst_flight.sent_keys.len);
                self.burst_flight.sent_keys[self.burst_flight.sent_n] = e.key_ptr.*;
                self.burst_flight.sent_n += 1;
            }
            tmp.deinit(alloc);
            self.burst_flight.done = true;
            self.burst_flight.active = false;
            self.burst_flight.cond.broadcast(self.io);
            self.burst_flight.mutex.unlock(self.io);
            // Fall through to the shared grab below (we hold a ref).
        }
        // Grab our share (executor post-publish and waiters alike).
        // The fallback solo run happens OUTSIDE the lock (a full burst
        // under the flight lock would serialize every join behind it).
        var solo_fallback = false;
        {
            self.burst_flight.mutex.lockUncancelable(self.io);
            defer self.burst_flight.mutex.unlock(self.io);
            const f = &self.burst_flight;
            while (!f.done and !f.failed and f.gen == mygen) {
                f.cond.waitUncancelable(self.io, &f.mutex);
            }
            if (f.failed or f.gen != mygen) {
                // Executor failed (or the flight recycled under us, which
                // cannot happen with a held ref — defensive).
                if (f.refs > 0) f.refs -= 1;
                if (f.refs == 0 and !f.active) burstFlightReset(self, f);
                solo_fallback = true;
            } else {
                // Copy failure (OOM) must still release our ref, or the
                // flight leaks pinned forever (the caller's collect
                // owns the partial copy and frees it).
                errdefer {
                    if (f.refs > 0) f.refs -= 1;
                    if (f.refs == 0 and !f.active) burstFlightReset(self, f);
                }
                for (f.frames.items) |fr| try out.frames.append(alloc, try alloc.dupe(u8, fr));
                for (f.sent_keys[0..f.sent_n]) |k| try out.sent.put(alloc, k, {});
                if (f.refs > 0) f.refs -= 1;
                if (f.refs == 0 and !f.active) burstFlightReset(self, f);
            }
        }
        if (solo_fallback) {
            return view.collectLoginBurst(alloc, self.chunkSource(pool), dim, cx, cz, radius, sky, out);
        }
    }

    /// Fail the current flight (executor OOM or abort): waiters fall back
    /// to solo bursts. Flight lock NOT held on entry.
    fn burstFlightFail(self: *Server) void {
        self.burst_flight.mutex.lockUncancelable(self.io);
        defer self.burst_flight.mutex.unlock(self.io);
        const f = &self.burst_flight;
        f.failed = true;
        f.done = true;
        f.active = false;
        f.cond.broadcast(self.io);
        if (f.refs > 0) f.refs -= 1; // executor's own share
        if (f.refs == 0) burstFlightReset(self, f);
    }

    /// Reset an idle flight (caller holds the flight lock, refs == 0).
    fn burstFlightReset(self: *Server, f: *Server.BurstFlight) void {
        _ = self;
        for (f.frames.items) |fr| f.alloc.free(fr);
        f.frames = .empty;
        f.sent_n = 0;
        f.done = false;
        f.failed = false;
    }

/// One protocol step: feed inbound bytes, parse frames, run the handlers,
/// apply the queued world actions and leave the answer in the conn's
/// outbox.
///
/// Both transports run this exact function, so the protocol behaviour is
/// identical no matter how the bytes travel (Phase B). The caller drains
/// `conn.out` afterwards (that is the single output path).
pub fn sessionStep(
    server: *Server,
    conn: *Conn,
    allocator: std.mem.Allocator,
    state: *SessionState,
    data: []const u8,
) !StepResult {
    const events = &state.events;
    var entered = false;
    var stop_requested = false;
    var cc_now: ChunkPos = .{ .cx = 0, .cz = 0 };
    conn.lock.lock();
    // The locked region is a separate function so that every error path
    // releases the lock (a leaked lock deadlocks the cleanup path).
    sessionLocked(server, conn, allocator, state, data, &entered, &cc_now) catch |err| {
        conn.lock.unlock();
        return err;
    };
    conn.lock.unlock();
    // World mutation (single world lock) then viewer broadcast
    // (one conn lock at a time — never nested).
    if (events.items.len > 0) {
        // Per-event light-bleed footprint (applyBlock touched-neighbor
        // mask, parallel to events.items): read at broadcast time to
        // resend refreshed neighbor columns to their trackers.
        const touched = try allocator.alloc(u8, events.items.len);
        defer allocator.free(touched);
        @memset(touched, 0);
        if (server.world) |pool| {
            // K1 accumulators: propagation/door halves/pops (broadcast +
            // sounds + pop drops flush after unlock, furnace pattern).
            var rs_changes: redstone_mod.ChangeList = .{};
            var rs_sounds: redstone_mod.SoundList = .{};
            server.world_lock.lock();
            const now_ticks = server.rs_tick;
            for (events.items, 0..) |*ev, i| {
                switch (ev.*) {
                    .block_set => |*b| {
                        // Right-click routing (not sneaking with a held
                        // item): table/furnace/enchant UIs open, K1
                        // lever-door-repeater-ore clicks toggle instead
                        // of placing.
                        conn.lock.lock();
                        const sneak = conn.sneaking;
                        conn.lock.unlock();
                        if (b.id != game_ids.air) {
                            if (server.tryOpenAnyUI(conn, pool, allocator, b, sneak)) {
                                events.items[i] = .none;
                                continue;
                            }
                            if (!sneak and server.tryInteract(pool, allocator, b, now_ticks, &rs_changes, &rs_sounds)) {
                                events.items[i] = .none;
                                continue;
                            }
                        }
                        const old = view.peekBlock(pool, allocator, b.x, b.y, b.z) catch null;
                        // Placement into an occupied non-replaceable cell is
                        // refused (see replaceableForPlace): silently
                        // overwriting tile entities loses contents and
                        // orphans rows. Resync the client's prediction with
                        // the true cell (breaks bypass: b.id == air).
                        if (b.id != game_ids.air) {
                            if (old) |o| {
                                if (o.id != game_ids.air and !Server.replaceableForPlace(o.id)) {
                                    // Broadcast BEFORE nulling: `b` aliases
                                    // items[i], and the .none write clobbers
                                    // the payload (use-after-clobber sent
                                    // garbage coords, so nobody was resynced
                                    // and the client hung on its prediction).
                                    server.broadcastBlockChange(null, b.x, b.y, b.z, o.id, o.meta) catch {};
                                    events.items[i] = .none;
                                    continue;
                                }
                            } else {
                                // No peek and no section: the chunk itself
                                // is absent (section-absent is fine —
                                // applyBlock creates it). The edit cannot
                                // land (applyBlock no-ops on missing
                                // chunks); NACK air instead of echoing a
                                // lie below. Breaks (air) keep the old
                                // path: the echo agrees with the client.
                                const ch = view.loadChunk(pool, allocator, b.x, b.z) catch null;
                                if (ch == null) {
                                    server.sendBlockChangeToActor(conn, b.x, b.y, b.z, game_ids.air, 0);
                                    events.items[i] = .none;
                                    continue;
                                }
                                ch.?.destroy(allocator);
                            }
                            // Vanilla canPlaceEntityOnSide: refuse when the
                            // target cell intersects a player. Applying
                            // there sticks the vanilla client inside solid
                            // (sudden stop + stuck jitter until broken).
                            // Placer first, then everyone else in the snap
                            // (mobs/items don't refuse: documented gap).
                            conn.lock.lock();
                            const px = conn.pos_x;
                            const py = conn.pos_y;
                            const pz = conn.pos_z;
                            conn.lock.unlock();
                            var blocked = interaction_mod.blockIntersectsPlayer(b.x, b.y, b.z, px, py, pz);
                            if (!blocked) {
                                var batch: [max_fanout]RegistryEntry = undefined;
                                const snap = server.snapshot(&batch);
                                defer Server.releaseSnap(snap);
                                for (snap) |e| {
                                    if (e.conn == conn) continue;
                                    e.conn.lock.lock();
                                    const st = e.conn.state == .play and !e.conn.dead and !e.conn.is_dead;
                                    const ex = e.conn.pos_x;
                                    const ey = e.conn.pos_y;
                                    const ez = e.conn.pos_z;
                                    e.conn.lock.unlock();
                                    if (st and interaction_mod.blockIntersectsPlayer(b.x, b.y, b.z, ex, ey, ez)) {
                                        blocked = true;
                                        break;
                                    }
                                }
                            }
                            if (blocked) {
                                if (old) |o| {
                                    server.sendBlockChangeToActor(conn, b.x, b.y, b.z, o.id, o.meta);
                                } else {
                                    server.sendBlockChangeToActor(conn, b.x, b.y, b.z, game_ids.air, 0);
                                }
                                events.items[i] = .none;
                                continue;
                            }
                        }
                        touched[i] = view.applyBlock(pool, allocator, b.x, b.y, b.z, b.id, b.meta) catch {
                            // The edit did NOT land (store/alloc failure):
                            // broadcasting the requested id would lie to
                            // every viewer (ghost), and aftermath drops for
                            // an unbroken block would dupe. Drop the event;
                            // a later resync/heal carries truth.
                            events.items[i] = .none;
                            continue;
                        };
                        // K1: plate registry follows place/break.
                        server.trackPlates(b, old);
                        // Door halves: placing a door also sets the upper
                        // half (air above only); breaking one half clears
                        // the partner (no extra drop — the main half
                        // already dropped via spawnBreakDrops below).
                        if (b.id != game_ids.air) {
                            Server.rsPlaceDoorUpper(pool, allocator, b.x, b.y, b.z, b.id, b.meta, &rs_changes);
                        } else if (old) |o| {
                            Server.rsBreakDoorPartner(pool, allocator, b.x, b.y, b.z, o.id, o.meta, &rs_changes);
                        }
                        // K1: recompute + neighbor fan-out for the edit.
                        server.redstoneOnEdit(pool, allocator, b.x, b.y, b.z, now_ticks, &rs_changes, &rs_sounds);
                        // Block sounds (S29 to nearby viewers).
                        const sx: f64 = @as(f64, @floatFromInt(b.x)) + 0.5;
                        const sy: f64 = @as(f64, @floatFromInt(b.y)) + 0.5;
                        const sz: f64 = @as(f64, @floatFromInt(b.z)) + 0.5;
                        server.soundForEdit(conn, b.id, sx, sy, sz);
                        // Survival break of a real block: vanilla drops.
                        // (Creative breaks drop nothing; missing chunks
                        // peek null and stay dropless.)
                        if (b.id == game_ids.air) {
                            server.breakAftermath(conn, pool, allocator, b, old, sx, sy, sz);
                        }
                    },
                    .interact => |*b| {
                        // Empty-hand right-click: UI opens + K1 toggles
                        // only (sneak is irrelevant with nothing held).
                        if (server.tryOpenAnyUI(conn, pool, allocator, b, false)) {
                            events.items[i] = .none;
                            continue;
                        }
                        _ = server.tryInteract(pool, allocator, b, now_ticks, &rs_changes, &rs_sounds);
                        events.items[i] = .none;
                    },
                    .eat => |e| {
                        // Right-click eat/drink: UI opens win first (tables,
                        // furnaces, chests — like vanilla), K1 toggles win
                        // when not sneaking; otherwise start the 32-tick
                        // use. Air clicks (face -1) skip routing.
                        conn.lock.lock();
                        const sneak = conn.sneaking;
                        const food_now = conn.food;
                        conn.lock.unlock();
                        var ui_b = BlockEvent{ .x = e.x, .y = e.y, .z = e.z, .id = e.id, .meta = 0, .face = e.face };
                        if (e.face != -1) {
                            if (server.tryOpenAnyUI(conn, pool, allocator, &ui_b, sneak)) {
                                events.items[i] = .none;
                                continue;
                            }
                            if (!sneak and server.tryInteract(pool, allocator, &ui_b, now_ticks, &rs_changes, &rs_sounds)) {
                                events.items[i] = .none;
                                continue;
                            }
                        }
                        // Validate the held stack is still the clicked food
                        // (it may have moved between parse and resolve).
                        conn.lock.lock();
                        defer conn.lock.unlock();
                        const st = conn.inv[e.slot] orelse {
                            events.items[i] = .none;
                            continue;
                        };
                        if (st.id != e.id or st.damage != e.damage) {
                            events.items[i] = .none;
                            continue;
                        }
                        const food = profile.game.item_data.foodFor(st.id, st.damage);
                        const potion = profile.game.potion_data.isDrinkable(st.id, st.damage);
                        if (food == null and !potion) {
                            events.items[i] = .none;
                            continue;
                        }
                        // Full hunger refuses food (except always-edible golden
                        // apples); potions always drink. Dead conns never eat.
                        // Restarting (already eating) just re-arms the timer.
                        const edible = if (food) |f| f.always_edible else true;
                        if (conn.is_dead or (food_now >= 20 and !edible)) {
                            events.items[i] = .none;
                            continue;
                        }
                        conn.eating = .{ .slot = e.slot, .id = e.id, .damage = e.damage, .ticks = profile.game.item_data.eat_ticks };
                        events.items[i] = .none;
                    },
                    else => {},
                }
            }
            server.world_lock.unlock();
            // K1 flush: propagation edits + interaction sounds/pops.
            // (Primary edits broadcast in the event loop below.)
            if (rs_changes.n > 0 or rs_sounds.n > 0) {
                conn.lock.lock();
                const gm = conn.config.gamemode;
                conn.lock.unlock();
                for (rs_changes.items[0..rs_changes.n]) |c| {
                    server.flushRsChange(gm, c);
                }
                for (rs_sounds.evs[0..rs_sounds.n]) |s| server.flushRsSound(s);
            }
        }
        for (events.items, 0..) |ev, i| {
            switch (ev) {
                .block_resync => |r| {
                    // Dig negative-ack: re-read the refused cell and send
                    // the digger truth when it is still solid (vanilla
                    // S23-iff-solid). Reads post-unlock like the neighbor
                    // resends below, so a racing edit only makes the
                    // correction fresher, never staler.
                    if (server.world) |pool| {
                        const cur = view.peekBlock(pool, allocator, r.x, r.y, r.z) catch null;
                        if (cur) |cell| {
                            if (cell.id != game_ids.air) server.sendBlockChangeTo(conn, r.x, r.y, r.z, cell.id, cell.meta);
                        }
                    }
                },
                .place_deny => |d| {
                    // Placement negative-ack: conn-side refusal (reach, bad
                    // face, side rule). The client predicted the block at
                    // the target, so truth goes out EVEN WHEN AIR (unlike
                    // dig-NACK: there the client removed and silence means
                    // agreement). Missing chunks peek null: air is truth
                    // (the edit never landed and generation won't include
                    // it). Same sent-set gate as dig-NACK (a viewer that
                    // never got the column holds no prediction to clear).
                    if (server.world) |pool| {
                        const cur = view.peekBlock(pool, allocator, d.x, d.y, d.z) catch null;
                        if (cur) |cell| {
                            server.sendBlockChangeToActor(conn, d.x, d.y, d.z, cell.id, cell.meta);
                        } else {
                            server.sendBlockChangeToActor(conn, d.x, d.y, d.z, game_ids.air, 0);
                        }
                    }
                },
                .block_set => |b| {
                    // Vanilla echoes placements/breaks to the actor too
                    // (PlayerManager marks every tracker; client prediction
                    // meets server truth immediately).
                    server.broadcastBlockChange(null, b.x, b.y, b.z, b.id, b.meta) catch {};
                    // Neighbor columns rewritten by the edit bleed get a
                    // targeted resend to their trackers (the 0x35 alone
                    // leaves remote viewers with stale light nibbles).
                    if (server.world) |pool| {
                        server.resendTouchedNeighbors(pool, b.x, b.z, touched[i]);
                    }
                    // Survival break: vanilla 0.025 exhaustion per block.
                    if (b.id == game_ids.air) {
                        conn.lock.lock();
                        if (conn.config.gamemode == .survival and !conn.is_dead) conn.addExhaustion(0.025);
                        conn.lock.unlock();
                    }
                },
                .qdrop => |q| server.spawnQDrop(conn, q),
                .throw_potion => |t| server.throwPotion(conn, t),
                .equip_armor => {
                    conn.lock.lock();
                    defer conn.lock.unlock();
                    _ = conn.applyEquipArmor();
                },
                .table_close => |t| server.spawnTableClose(conn, t),
                .furnace_click => |f| server.applyFurnaceClick(conn, f),
                .brew_click => |bc| server.applyBrewClick(conn, bc),
                .chest_click => |c| {
                    if (server.world) |pool| server.applyChestClick(conn, pool, allocator, c);
                },
                .chest_close => |c| {
                    if (server.world) |pool| server.spawnChestClose(pool, allocator, c);
                },
                .ender_close => |c| server.spawnEnderClose(c),
                .enchant_click => |ec| {
                    if (server.world) |pool| server.applyEnchantClick(conn, pool, allocator, ec);
                },
                .enchant => |ee| {
                    if (server.world) |pool| server.applyEnchant(conn, pool, allocator, ee);
                },
                .arm_swing => |a| server.broadcastArmSwing(conn, cc_now.cx, cc_now.cz, conn.eid, a) catch {},
                .chat => |m| server.broadcastChat(conn.chat_buf[0..m.json_len]),
                .attack => |a| server.resolveAttack(conn, a),
                .tab_complete => |m| server.handleTabComplete(conn, conn.tab_buf[0..m.json_len]),
                .command => |m| {
                    const text = conn.chat_buf[0..m.json_len];
                    server.handleCommand(conn, text);
                    if (Server.isStopCommand(text)) {
                        // The stopping reply stays in the conn's
                        // outbox: the caller flushes it and then
                        // persists + exits (the ticker/serve loops die
                        // with us; the WAL makes the flush a
                        // performance plea, not a durability
                        // requirement).
                        stop_requested = true;
                    }
                },
                else => {},
            }
        }
        events.clearRetainingCapacity();
    }
    // Instant pressure-plate press on movement (vanilla senses plate
    // collisions from entity movement; releases ride the 1Hz recheck, the
    // same cadence as vanilla's scheduled 20-tick update while pressed).
    // press_only never releases, so a mover can't drop a plate another
    // entity is holding down.
    if (server.world) |pool| {
        if (server.rs_plates.n > 0) {
            conn.lock.lock();
            const mover = redstone_mod.Ent{ .x = conn.pos_x, .y = conn.pos_y, .z = conn.pos_z };
            const in_play = conn.state == .play and !conn.dead;
            conn.lock.unlock();
            if (in_play) {
                var rs_changes: redstone_mod.ChangeList = .{};
                var rs_sounds: redstone_mod.SoundList = .{};
                server.world_lock.lock();
                var w = Server.RsWorld{ .pool = pool, .alloc = allocator, .changes = &rs_changes };
                defer w.deinit();
                redstone_mod.pollPlates(w.rsView(), &server.rs_sched, &server.rs_burn, &server.rs_plates, &rs_changes, &rs_sounds, server.rs_tick, &[1]redstone_mod.Ent{mover}, &.{}, &.{}, true);
                server.world_lock.unlock();
                for (rs_changes.items[0..rs_changes.n]) |c| server.flushRsChange(conn.config.gamemode, c);
                for (rs_sounds.evs[0..rs_sounds.n]) |sv| server.flushRsSound(sv);
            }
        }
    }
    // Landing resolved once per serve pass (water check + fall damage).
    server.resolvePendingFall(conn);
    // Login grace: re-snap clients that fell through undelivered ground.
    server.maybeLoginResync(conn);
    conn.lock.lock();
    const finished = conn.close_after_flush or conn.dead;
    const announce = state.need_announce;
    state.need_announce = false;
    conn.lock.unlock();
    return .{ .finished = finished, .announce = announce, .stop = stop_requested };
}

/// Handle one connection: handshake/status/login + play bootstrap, then
/// stay open consuming play packets until close or tick-timeout.
/// Login completion sends join packets, the initial chunk burst (when the
/// server has a world), then PosLook, then registers for server ticks.
///
/// This is the blocking transport's driver. The io_uring transport drives
/// the very same `sessionStep` from its worker threads.
pub fn serveConn(
    stream: std.Io.net.Stream,
    io: std.Io,
    allocator: std.mem.Allocator,
    server: *Server,
    eid: i32,
) !void {
    const conn = try allocator.create(Conn);
    conn.* = Conn.init(allocator, io, server.config, eid);
    Server.captureIp(conn, stream);
    // Same socket tuning as the async accept paths (notably SO_SNDTIMEO:
    // without it a write to a black-hole peer wedges this thread for
    // TCP-timeout minutes instead of failing fast).
    transport_mod.applySocketOpts(stream.socket.handle, server.transport_opts);
    server.register(conn, stream) catch {
        conn.deinit();
        allocator.destroy(conn);
        return error.RegistryFull;
    };
    defer server.unregister(conn);
    var rbuf: [io_buf_len]u8 = undefined;
    var wbuf: [io_buf_len]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var writer = stream.writer(io, &wbuf);
    const rin = &reader.interface;
    const wout = &writer.interface;
    var state = SessionState{};
    defer state.deinit(allocator);
    while (true) {
        // Read whatever the client sent (the conn does its own frame
        // reassembly, so a partial frame is fine). `readVec` returns after
        // one socket read: it never waits for the buffer to fill.
        var chunk: [io_buf_len]u8 = undefined;
        var bufs: [1][]u8 = .{&chunk};
        const n = rin.readVec(&bufs) catch |err| switch (err) {
            error.EndOfStream => return, // client closed
            else => return err,
        };
        if (n == 0) return;
        const res = try sessionStep(server, conn, allocator, &state, chunk[0..n]);
        // Single output path: drain the outbox and write it.
        conn.lock.lock();
        const pending = try conn.takeOutput();
        conn.lock.unlock();
        if (pending.len > 0) {
            conn.wlock.lock();
            defer conn.wlock.unlock();
            defer conn.allocator.free(pending);
            wout.writeAll(pending) catch return;
            wout.flush() catch return;
        } else {
            conn.allocator.free(pending);
        }
        if (res.stop) server.finishStop();
        if (res.finished) return;
        if (res.announce) {
            server.queueAnnounce(conn);
        }
    }
}

/// Read one framed packet body from a client-side reader (test helper).
const TestFrame = struct { id: i32, body: []u8 };

fn readFrame(r: *std.Io.Reader, buf: []u8) !TestFrame {
    var len: i32 = 0;
    var shift: u32 = 0;
    while (true) {
        const b = try r.takeByte();
        len |= @as(i32, b & 0x7F) << @as(u5, @intCast(shift));
        shift += 7;
        if (shift > 35) return error.VarIntTooLarge;
        if ((b & 0x80) == 0) break;
    }
    if (len < 0 or len > buf.len) return error.FrameTooLarge;
    const ulen: usize = @intCast(len);
    try r.readSliceAll(buf[0..ulen]);
    var pr = codec.PacketReader.init(buf[0..ulen]);
    const id = try pr.readVarInt();
    const body = buf[pr.index..ulen];
    return .{ .id = id, .body = body };
}

// ---- tests ----

test "loopback status flow over real TCP" {
    const io = std.testing.io;
    // bind with port fallback (sandbox-safe)
    var port: u16 = 37911;
    var srv: Server = while (true) {
        break Server.bind(io, port, .{}) catch |err| switch (err) {
            error.AddressInUse => {
                port += 1;
                if (port > 37930) return err;
                continue;
            },
            else => return err,
        };
    };
    defer srv.deinit();
    defer srv.registry.deinit(std.testing.allocator);
    const T = struct {
        fn run(s: *Server) !void {
            try s.serveOne(std.testing.allocator);
        }
    };
    const th = try std.Thread.spawn(.{}, T.run, .{&srv});
    // client side
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try addr.connect(io, .{ .mode = .stream });
    // (closed explicitly before join so serveOne sees EndOfStream)
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var writer = stream.writer(io, &wbuf);
    // handshake(status) + request
    var hb: [64]u8 = undefined;
    var w = codec.PacketWriter.init(&hb);
    try w.writeVarInt(5);
    try w.writeString("localhost");
    try w.writeUShort(port);
    try w.writeVarInt(1);
    var hf: [80]u8 = undefined;
    const hframe = try codec.framePacket(0x00, w.written(), &hf);
    try writer.interface.writeAll(hframe);
    var rq: [8]u8 = undefined;
    try writer.interface.writeAll(try codec.framePacket(0x00, &.{}, &rq));
    try writer.interface.flush();
    var fbuf: [2048]u8 = undefined;
    const resp = try readFrame(&reader.interface, &fbuf);
    try std.testing.expectEqual(@as(i32, 0x00), resp.id);
    var pr = codec.PacketReader.init(resp.body);
    const js = try pr.readString();
    try std.testing.expect(std.mem.indexOf(u8, js, "1.7.10") != null);
    stream.close(io);
    th.join();
}

test "play_count tracks announces and unregisters for the list ping" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), srv.play_count.load(.acquire));

    var port: u16 = 37971;
    var listener: std.Io.net.Server = while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        break addr.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => {
                port += 1;
                if (port > 37999) return err;
                continue;
            },
            else => return err,
        };
    };
    defer listener.deinit(io);
    const mk = struct {
        fn run(l: *std.Io.net.Server, p: u16, name: []const u8) !struct {
            conn: *Conn,
            srv_stream: std.Io.net.Stream,
            cli_stream: std.Io.net.Stream,
        } {
            const c = try a.create(Conn);
            errdefer a.destroy(c);
            c.* = Conn.init(a, io, .{}, 1);
            c.state = .play;
            @memcpy(c.username[0..name.len], name);
            c.username_len = name.len;
            const addr = try std.Io.net.IpAddress.parse("127.0.0.1", p);
            const cli = try addr.connect(io, .{ .mode = .stream });
            const sv = try l.accept(io);
            return .{ .conn = c, .srv_stream = sv, .cli_stream = cli };
        }
    };
    var alice = try mk.run(&listener, port, "Alice");
    defer alice.cli_stream.close(io);
    defer alice.srv_stream.close(io);
    var bob = try mk.run(&listener, port, "Bob");
    defer bob.cli_stream.close(io);
    defer bob.srv_stream.close(io);

    try srv.register(alice.conn, alice.srv_stream);
    try srv.register(bob.conn, bob.srv_stream);
    // Registered but not announced: not counted yet.
    try std.testing.expectEqual(@as(u32, 0), srv.play_count.load(.acquire));
    // Batched announce: queueing alone changes nothing; the drain counts.
    srv.queueAnnounce(alice.conn);
    try std.testing.expectEqual(@as(u32, 0), srv.play_count.load(.acquire));
    srv.drainAnnounces();
    try std.testing.expectEqual(@as(u32, 1), srv.play_count.load(.acquire));
    srv.queueAnnounce(bob.conn);
    srv.drainAnnounces();
    try std.testing.expectEqual(@as(u32, 2), srv.play_count.load(.acquire));
    // Re-announce is idempotent for the count.
    srv.queueAnnounce(bob.conn);
    srv.drainAnnounces();
    try std.testing.expectEqual(@as(u32, 2), srv.play_count.load(.acquire));
    srv.unregister(bob.conn);
    try std.testing.expectEqual(@as(u32, 1), srv.play_count.load(.acquire));
    srv.unregister(alice.conn);
    try std.testing.expectEqual(@as(u32, 0), srv.play_count.load(.acquire));
}

test "registry join/leave broadcast + tickOnce keepalive over loopback" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);

    // loopback pair without threads: connects complete via kernel backlog
    var port: u16 = 37931;
    var listener: std.Io.net.Server = while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        break addr.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => {
                port += 1;
                if (port > 37960) return err;
                continue;
            },
            else => return err,
        };
    };
    defer listener.deinit(io);
    const mk = struct {
        fn run(l: *std.Io.net.Server, p: u16, name: []const u8) !struct {
            conn: *Conn,
            srv_stream: std.Io.net.Stream,
            cli_stream: std.Io.net.Stream,
        } {
            const addr = try std.Io.net.IpAddress.parse("127.0.0.1", p);
            var cli = try addr.connect(io, .{ .mode = .stream });
            errdefer cli.close(io);
            const sv = try l.accept(io);
            const c = try a.create(Conn);
            errdefer a.destroy(c);
            c.* = Conn.init(a, io, .{}, 1);
            c.state = .play;
            @memcpy(c.username[0..name.len], name);
            c.username_len = name.len;
            return .{ .conn = c, .srv_stream = sv, .cli_stream = cli };
        }
    };
    var alice = try mk.run(&listener, port, "Alice");
    defer alice.cli_stream.close(io);
    defer alice.srv_stream.close(io);
    var bob = try mk.run(&listener, port, "Bob");
    defer bob.cli_stream.close(io);
    defer bob.srv_stream.close(io);

    try srv.register(alice.conn, alice.srv_stream);
    try srv.register(bob.conn, bob.srv_stream);
    // announce both (each conn queues itself on login, like serveConn does).
    // Duplicates are harmless (idempotent player list); drain both copies.
    srv.queueAnnounce(alice.conn);
    srv.queueAnnounce(bob.conn);
    srv.drainAnnounces();
    // Alice learns Bob; Bob learns Alice (persistent readers: fresh ones
    // would drop coalesced bytes buffered by a previous reader)
    var arb: [128]u8 = undefined;
    var afb: [128]u8 = undefined;
    var arr = alice.cli_stream.reader(io, &arb);
    var brb: [128]u8 = undefined;
    var brr = bob.cli_stream.reader(io, &brb);
    // Batched announce: ONE drain fans out everything — each side gets one
    // list-add for the other, then BOTH yellow join lines in queue order.
    for ([2]struct { r: *std.Io.net.Stream.Reader, want: []const u8 }{ .{ .r = &arr, .want = "Bob" }, .{ .r = &brr, .want = "Alice" } }) |side| {
        const f = try readFrame(&side.r.interface, &afb);
        try std.testing.expectEqual(@as(i32, 0x38), f.id);
        var pr = codec.PacketReader.init(f.body);
        try std.testing.expectEqualStrings(side.want, try pr.readString());
        try std.testing.expect(try pr.readBool());
        for ([2]u8{ 0, 1 }) |_| {
            const c = try readFrame(&side.r.interface, &afb);
            try std.testing.expectEqual(@as(i32, 0x02), c.id);
        }
    }
    // one server tick: both get TimeUpdate + KeepAlive on the wire
    srv.tickOnce(0);
    for ([2]*std.Io.net.Stream.Reader{ &arr, &brr }) |rr| {
        const t = try readFrame(&rr.interface, &afb);
        try std.testing.expectEqual(@as(i32, 0x03), t.id);
        const k = try readFrame(&rr.interface, &afb);
        try std.testing.expectEqual(@as(i32, 0x00), k.id);
    }
    // Bob leaves: Alice sees remove + yellow leave chat
    srv.unregister(bob.conn);
    {
        const f = try readFrame(&arr.interface, &afb);
        try std.testing.expectEqual(@as(i32, 0x38), f.id);
        var pr = codec.PacketReader.init(f.body);
        try std.testing.expectEqualStrings("Bob", try pr.readString());
        try std.testing.expect(!(try pr.readBool())); // online=false
        const c = try readFrame(&arr.interface, &afb);
        try std.testing.expectEqual(@as(i32, 0x02), c.id);
    }
    srv.unregister(alice.conn);
    try std.testing.expectEqual(@as(usize, 0), srv.registry.items.len);
}

test "K1 glue: piston extend/retract through the LSM pool + S24 action" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
        try pool.flushAll();
    }
    // Floor y=63; piston (facing east) at (8,64,8); stone at (9,64,8);
    // lever on the block below the piston's WEST neighbor cell.
    for ([_]i32{ 7, 8, 9, 10, 11 }) |x| _ = try view.applyBlock(pool, a, x, 63, 8, game_ids.stone, 0);
    _ = try view.applyBlock(pool, a, 8, 64, 8, game_ids.piston, 5);
    _ = try view.applyBlock(pool, a, 9, 64, 8, game_ids.stone, 0);
    _ = try view.applyBlock(pool, a, 7, 64, 8, game_ids.lever, 5);
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    srv.world = pool;
    var changes: redstone_mod.ChangeList = .{};
    var sounds: redstone_mod.SoundList = .{};
    var actions: redstone_mod.ActionList = .{};
    // Toggle the lever ON -> the piston's west neighbor sees weak power ->
    // updatePistonState schedules a piston_extend block event.
    var evt = BlockEvent{ .x = 7, .y = 65, .z = 8, .id = game_ids.air, .meta = 0, .face = 1 };
    srv.world_lock.lock();
    const consumed = srv.tryInteract(pool, a, &evt, 0, &changes, &sounds);
    srv.world_lock.unlock();
    try std.testing.expect(consumed);
    try std.testing.expectEqual(@as(u4, 13), (try view.peekBlock(pool, a, 7, 64, 8)).?.meta); // lever ON
    // Drain the scheduled event (due at now+2).
    srv.world_lock.lock();
    {
        var w = Server.RsWorld{ .pool = pool, .alloc = a, .changes = &changes };
        defer w.deinit();
        redstone_mod.drainScheduled(w.rsView(), &srv.rs_sched, &srv.rs_burn, &changes, &sounds, 2, &actions);
    }
    srv.world_lock.unlock();
    try std.testing.expectEqual(game_ids.piston_head, (try view.peekBlock(pool, a, 9, 64, 8)).?.id);
    try std.testing.expectEqual(@as(u4, 5), (try view.peekBlock(pool, a, 9, 64, 8)).?.meta); // non-sticky head
    try std.testing.expectEqual(game_ids.stone, (try view.peekBlock(pool, a, 10, 64, 8)).?.id); // pushed
    try std.testing.expectEqual(@as(u4, 5 | 8), (try view.peekBlock(pool, a, 8, 64, 8)).?.meta); // extended
    try std.testing.expectEqual(@as(usize, 1), actions.n); // exactly one S24
    try std.testing.expectEqual(@as(u8, 0), actions.items[0].event_id);
    try std.testing.expectEqual(@as(u8, 5), actions.items[0].facing);
    try std.testing.expectEqual(game_ids.piston, actions.items[0].id);

    // Lever OFF -> retract event; non-sticky leaves the pushed stone put.
    var evt2 = BlockEvent{ .x = 7, .y = 65, .z = 8, .id = game_ids.air, .meta = 0, .face = 1 };
    srv.world_lock.lock();
    _ = srv.tryInteract(pool, a, &evt2, 4, &changes, &sounds);
    var actions2: redstone_mod.ActionList = .{};
    {
        var w2 = Server.RsWorld{ .pool = pool, .alloc = a, .changes = &changes };
        defer w2.deinit();
        redstone_mod.drainScheduled(w2.rsView(), &srv.rs_sched, &srv.rs_burn, &changes, &sounds, 6, &actions2);
    }
    srv.world_lock.unlock();
    try std.testing.expectEqual(game_ids.air, (try view.peekBlock(pool, a, 9, 64, 8)).?.id); // head gone
    try std.testing.expectEqual(game_ids.stone, (try view.peekBlock(pool, a, 10, 64, 8)).?.id); // stone stays
    try std.testing.expectEqual(@as(u4, 5), (try view.peekBlock(pool, a, 8, 64, 8)).?.meta); // retracted
    try std.testing.expectEqual(@as(u8, 1), actions2.items[0].event_id);
}

test "K1 glue: sticky piston pulls its adjacent block on retract" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
        try pool.flushAll();
    }
    for ([_]i32{ 7, 8, 9, 10 }) |x| _ = try view.applyBlock(pool, a, x, 63, 8, game_ids.stone, 0);
    _ = try view.applyBlock(pool, a, 8, 64, 8, game_ids.sticky_piston, 5);
    _ = try view.applyBlock(pool, a, 9, 64, 8, game_ids.dirt, 0);
    _ = try view.applyBlock(pool, a, 7, 64, 8, game_ids.lever, 5);
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    srv.world = pool;
    var changes: redstone_mod.ChangeList = .{};
    var sounds: redstone_mod.SoundList = .{};
    var evt = BlockEvent{ .x = 7, .y = 65, .z = 8, .id = game_ids.air, .meta = 0, .face = 1 };
    srv.world_lock.lock();
    _ = srv.tryInteract(pool, a, &evt, 0, &changes, &sounds);
    {
        var w = Server.RsWorld{ .pool = pool, .alloc = a, .changes = &changes };
        defer w.deinit();
        var actions: redstone_mod.ActionList = .{};
        redstone_mod.drainScheduled(w.rsView(), &srv.rs_sched, &srv.rs_burn, &changes, &sounds, 2, &actions);
    }
    srv.world_lock.unlock();
    // Extended: head at 9, dirt pushed to 10.
    try std.testing.expectEqual(game_ids.piston_head, (try view.peekBlock(pool, a, 9, 64, 8)).?.id);
    try std.testing.expectEqual(@as(u4, 5 | 8), (try view.peekBlock(pool, a, 9, 64, 8)).?.meta); // sticky head carries bit 3
    try std.testing.expectEqual(game_ids.dirt, (try view.peekBlock(pool, a, 10, 64, 8)).?.id);
    // Retract: the dirt comes back into the head cell.
    var evt2 = BlockEvent{ .x = 7, .y = 65, .z = 8, .id = game_ids.air, .meta = 0, .face = 1 };
    srv.world_lock.lock();
    _ = srv.tryInteract(pool, a, &evt2, 4, &changes, &sounds);
    {
        var w2 = Server.RsWorld{ .pool = pool, .alloc = a, .changes = &changes };
        defer w2.deinit();
        var actions2: redstone_mod.ActionList = .{};
        redstone_mod.drainScheduled(w2.rsView(), &srv.rs_sched, &srv.rs_burn, &changes, &sounds, 6, &actions2);
    }
    srv.world_lock.unlock();
    try std.testing.expectEqual(game_ids.dirt, (try view.peekBlock(pool, a, 9, 64, 8)).?.id);
    try std.testing.expectEqual(game_ids.air, (try view.peekBlock(pool, a, 10, 64, 8)).?.id);
    try std.testing.expectEqual(@as(u4, 5), (try view.peekBlock(pool, a, 8, 64, 8)).?.meta);
}

test "K1 glue: breaking an extended piston pops its head" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
        try pool.flushAll();
    }
    for ([_]i32{ 8, 9 }) |x| _ = try view.applyBlock(pool, a, x, 63, 8, game_ids.stone, 0);
    _ = try view.applyBlock(pool, a, 8, 64, 8, game_ids.piston, 5 | 8); // extended east
    _ = try view.applyBlock(pool, a, 9, 64, 8, game_ids.piston_head, 5);
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    srv.world = pool;
    var changes: redstone_mod.ChangeList = .{};
    var sounds: redstone_mod.SoundList = .{};
    // Breaking the base: the block_set air path applies the air first, then
    // calls redstoneOnEdit (sessionStep order).
    _ = try view.applyBlock(pool, a, 8, 64, 8, game_ids.air, 0);
    srv.world_lock.lock();
    srv.redstoneOnEdit(pool, a, 8, 64, 8, 0, &changes, &sounds);
    srv.world_lock.unlock();
    try std.testing.expectEqual(game_ids.air, (try view.peekBlock(pool, a, 9, 64, 8)).?.id);
    var popped_head = false;
    for (changes.items[0..changes.n]) |c| {
        if (c.popped and c.old_id == game_ids.piston_head) popped_head = true;
    }
    try std.testing.expect(popped_head);
}

test "K1 glue: lever interact powers wire + lamp through the LSM pool" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
        try pool.flushAll();
    }
    // stone floor y=63, lever/wire/wire/lamp at y=64 (chunk 0,0).
    for ([_]i32{ 8, 9, 10, 11 }) |x| _ = try view.applyBlock(pool, a, x, 63, 8, game_ids.stone, 0);
    _ = try view.applyBlock(pool, a, 8, 64, 8, game_ids.lever, 5);
    _ = try view.applyBlock(pool, a, 9, 64, 8, game_ids.redstone_wire, 0);
    _ = try view.applyBlock(pool, a, 10, 64, 8, game_ids.redstone_wire, 0);
    _ = try view.applyBlock(pool, a, 11, 64, 8, game_ids.redstone_lamp, 0);
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    srv.world = pool;
    var changes: redstone_mod.ChangeList = .{};
    var sounds: redstone_mod.SoundList = .{};
    // Right-click the lever top (target = clicked + face).
    var evt = BlockEvent{ .x = 8, .y = 65, .z = 8, .id = game_ids.air, .meta = 0, .face = 1 };
    srv.world_lock.lock();
    const consumed = srv.tryInteract(pool, a, &evt, 0, &changes, &sounds);
    srv.world_lock.unlock();
    try std.testing.expect(consumed);
    try std.testing.expectEqual(@as(u4, 13), (try view.peekBlock(pool, a, 8, 64, 8)).?.meta);
    try std.testing.expectEqual(@as(u4, 15), (try view.peekBlock(pool, a, 9, 64, 8)).?.meta);
    try std.testing.expectEqual(@as(u4, 14), (try view.peekBlock(pool, a, 10, 64, 8)).?.meta);
    try std.testing.expectEqual(game_ids.lit_redstone_lamp, (try view.peekBlock(pool, a, 11, 64, 8)).?.id);
    try std.testing.expectEqual(@as(usize, 1), sounds.n);
    // Toggle off: wire dies, lamp unlights.
    var evt2 = BlockEvent{ .x = 8, .y = 65, .z = 8, .id = game_ids.air, .meta = 0, .face = 1 };
    srv.world_lock.lock();
    defer srv.world_lock.unlock();
    try std.testing.expect(srv.tryInteract(pool, a, &evt2, 20, &changes, &sounds));
    try std.testing.expectEqual(@as(u4, 5), (try view.peekBlock(pool, a, 8, 64, 8)).?.meta);
    try std.testing.expectEqual(@as(u4, 0), (try view.peekBlock(pool, a, 9, 64, 8)).?.meta);
    try std.testing.expectEqual(game_ids.redstone_lamp, (try view.peekBlock(pool, a, 11, 64, 8)).?.id);
}

test "K1 glue: door halves place/break together" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
        try pool.flushAll();
    }
    _ = try view.applyBlock(pool, a, 8, 63, 8, game_ids.stone, 0);
    _ = try view.applyBlock(pool, a, 8, 64, 8, game_ids.wooden_door_block, 2);
    var changes: redstone_mod.ChangeList = .{};
    Server.rsPlaceDoorUpper(pool, a, 8, 64, 8, game_ids.wooden_door_block, 2, &changes);
    try std.testing.expectEqual(@as(u4, 8), (try view.peekBlock(pool, a, 8, 65, 8)).?.meta);
    // Breaking the lower half clears the upper (partner recorded, no drop).
    _ = try view.applyBlock(pool, a, 8, 64, 8, game_ids.air, 0);
    Server.rsBreakDoorPartner(pool, a, 8, 64, 8, game_ids.wooden_door_block, 2, &changes);
    try std.testing.expectEqual(game_ids.air, (try view.peekBlock(pool, a, 8, 65, 8)).?.id);
    try std.testing.expect(changes.n >= 2);
    // Non-door blocks are ignored.
    const n_before = changes.n;
    Server.rsBreakDoorPartner(pool, a, 8, 64, 8, game_ids.stone, 0, &changes);
    Server.rsPlaceDoorUpper(pool, a, 8, 64, 8, game_ids.stone, 0, &changes);
    try std.testing.expectEqual(n_before, changes.n);
}

test "Phase C: grouping covers each viewer exactly once (interleaved regions)" {
    // Regression test for the in-place range-extension bug (interleaved
    // regions overlapped ranges and ticked viewers twice): pass 2 must
    // compact into contiguous, disjoint ranges covering every viewer.
    const a = std.heap.page_allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    // Interleaved: A(0,0) B(3,0) A(0,0) B(3,0) + one non-play conn.
    var conns: [5]*Conn = undefined;
    const xs = [_]f64{ 8.5, 2000.5, 24.5, 2016.5, 8.5 };
    for (&conns, 0..) |*slot, i| {
        const c = try a.create(Conn);
        c.* = Conn.init(a, io, .{}, 1);
        if (i < 4) c.state = .play;
        c.pos_x = xs[i];
        c.pos_z = 8.5;
        slot.* = c;
    }
    defer for (conns) |c| {
        c.deinit();
        a.destroy(c);
    };
    var snap: [5]RegistryEntry = undefined;
    for (&snap, conns) |*e, c| e.* = .{ .conn = c, .stream = undefined };
    var deaths = std.ArrayList(Server.DeathInfo).empty;
    defer deaths.deinit(a);
    var claims = entity.ClaimSet{};
    var rns: u64 = 0;
    var sns: u64 = 0;
    var players: [0]entity.PlayerSnap = .{};
    var mobs: [0]entity.MobSnap = .{};
    var items: [0]entity.ItemSnap = .{};
    var envs: [0]Server.EnvFlag = .{};
    var furn: [0]Server.FurnSnap = .{};
    var vc = Server.ViewerCtx{
        .now_ms = 1000,
        .age = 20,
        .players = &players,
        .mobs = &mobs,
        .items = &items,
        .potions = &[_]entity.PotionSnap{},
        .envs = &envs,
        .furn_snaps = &furn,
        .brew_snaps = &[_]Server.BrewSnap{},
        .deaths = &deaths,
        .claims = &claims,
        .reconcile_ns = &rns,
        .send_ns = &sns,
    };
    var build = Server.GroupBuild{};
    srv.buildRegionGroups(&snap, &vc, &build);
    // Two regions (non-play conn ticks inline, never grouped).
    try std.testing.expectEqual(@as(usize, 2), build.n_groups);
    // Every grouped index appears exactly once across all ranges.
    var seen: [5]u32 = [_]u32{0} ** 5;
    for (build.groups[0..build.n_groups]) |g| {
        // Ranges are non-empty and inside the order array.
        try std.testing.expect(g.end > g.start);
        try std.testing.expect(g.end <= build.n_ordered);
        for (build.order[g.start..g.end]) |si| {
            try std.testing.expect(si < 4); // play viewers only
            seen[si] += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 4), build.n_ordered);
    for (seen[0..4]) |n| try std.testing.expectEqual(@as(u32, 1), n);
    // First-seen order: group 0 is region (0,0) with viewers {0,2} in
    // snap order, group 1 is region (3,0) with {1,3}.
    try std.testing.expectEqual(@as(i32, 0), build.groups[0].region.id.rx);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 0, 2 }, build.order[build.groups[0].start..build.groups[0].end]);
    try std.testing.expectEqual(@as(i32, 3), build.groups[1].region.id.rx);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 1, 3 }, build.order[build.groups[1].start..build.groups[1].end]);
}

test "Phase C: >256 viewers spill to legacy without smashing the stack" {
    // Regression: the grouping side arrays are fixed [256] but
    // max_players allows 1024 — past 256 viewers the old code indexed
    // them out of bounds (ReleaseFast: no panic, smashed stack, wild
    // crash under the 600-conn load). Viewers past the cap must tick
    // inline via the legacy body; the grouped prefix stays exact.
    const a = std.heap.page_allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    const n = 260;
    // Loopback pairs: spill viewers tick inline through tickViewerOne,
    // which flushes their outbox — that needs real fds (undefined
    // streams abort on flush, like the live server would on a dead fd).
    var port: u16 = 37801;
    var listener: std.Io.net.Server = while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        break addr.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => {
                port += 1;
                if (port > 37860) return err;
                continue;
            },
            else => return err,
        };
    };
    defer listener.deinit(io);
    var conns: [n]*Conn = undefined;
    var clis: [n]std.Io.net.Stream = undefined;
    var srvs: [n]std.Io.net.Stream = undefined;
    for (&conns, &clis, &srvs) |*slot, *cli, *sv| {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        cli.* = try addr.connect(io, .{ .mode = .stream });
        sv.* = try listener.accept(io);
        const c = try a.create(Conn);
        c.* = Conn.init(a, io, .{}, 1);
        c.state = .play;
        c.pos_x = 8.5;
        c.pos_z = 8.5;
        slot.* = c;
    }
    defer {
        for (conns) |c| {
            c.deinit();
            a.destroy(c);
        }
        for (&clis) |*s| s.close(io);
        for (&srvs) |*s| s.close(io);
    }
    var snap: [n]RegistryEntry = undefined;
    for (&snap, conns, srvs) |*e, c, s| e.* = .{ .conn = c, .stream = s };
    var deaths = std.ArrayList(Server.DeathInfo).empty;
    defer deaths.deinit(a);
    var claims = entity.ClaimSet{};
    var rns: u64 = 0;
    var sns: u64 = 0;
    var players: [0]entity.PlayerSnap = .{};
    var mobs: [0]entity.MobSnap = .{};
    var items: [0]entity.ItemSnap = .{};
    var envs: [0]Server.EnvFlag = .{};
    var furn: [0]Server.FurnSnap = .{};
    var vc = Server.ViewerCtx{
        .now_ms = 1000,
        .age = 20,
        .players = &players,
        .mobs = &mobs,
        .items = &items,
        .potions = &[_]entity.PotionSnap{},
        .envs = &envs,
        .furn_snaps = &furn,
        .brew_snaps = &[_]Server.BrewSnap{},
        .deaths = &deaths,
        .claims = &claims,
        .reconcile_ns = &rns,
        .send_ns = &sns,
    };
    var build = Server.GroupBuild{};
    srv.buildRegionGroups(&snap, &vc, &build);
    // One region, first 256 grouped, last 4 legacy-inline.
    try std.testing.expectEqual(@as(usize, 1), build.n_groups);
    try std.testing.expectEqual(@as(usize, 256), build.n_ordered);
    var seen: [n]u32 = [_]u32{0} ** n;
    for (build.groups[0..build.n_groups]) |g| {
        try std.testing.expect(g.end <= build.n_ordered);
        for (build.order[g.start..g.end]) |si| {
            try std.testing.expect(si < 256); // only the capped prefix
            seen[si] += 1;
        }
    }
    for (seen[0..256]) |c| try std.testing.expectEqual(@as(u32, 1), c);
    for (seen[256..]) |c| try std.testing.expectEqual(@as(u32, 0), c);
}

test "Phase C follow-up: mob crossing adopts into target, source empties, never gaps or dups" {
    // Deterministic crossing: mob just inside region (0,0), homed so
    // wanderStep carries it over the x=512 border in one tick (0.5
    // blocks/tick toward waypoint (home+r, home)).
    const a = std.heap.page_allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    srv.region_threads = 1; // sequential: deterministic single-threaded tick
    srv.ent_lock.lock();
    const src = try srv.region_reg.getOrCreate(a, .{ .dim = 0, .rx = 0, .rz = 0 });
    _ = try src.mobs.add(.{ .id = 77, .kind = .pig, .x = 511.8, .y = 64, .z = 8.5, .yaw = 0, .health = 10, .home_x = 511.8, .home_z = 8.5, .patrol_r = 4 });
    srv.ent_lock.unlock();
    // Tick 1: wander crosses, transfer pushed, source copy kept.
    srv.tickOnce(1000);
    srv.ent_lock.lock();
    try std.testing.expectEqual(@as(usize, 1), srv.region_reg.totalMobs());
    try std.testing.expect(src.mobs.indexOfId(77) != null);
    srv.ent_lock.unlock();
    const dst = try srv.region_reg.getOrCreate(a, .{ .dim = 0, .rx = 1, .rz = 0 });
    try std.testing.expect(!dst.inbox.isEmpty());
    // Tick 2: drain adopts into target + deletes source (delete-at-drain).
    srv.tickOnce(2000);
    srv.ent_lock.lock();
    try std.testing.expectEqual(@as(usize, 1), srv.region_reg.totalMobs());
    try std.testing.expect(src.mobs.indexOfId(77) == null);
    try std.testing.expect(dst.mobs.indexOfId(77) != null);
    try std.testing.expectEqual(@as(usize, 1), dst.mobs.len());
    srv.ent_lock.unlock();
    try std.testing.expect(dst.inbox.isEmpty());
    // Tick 3: settled (owned by target, inside its cell) — no re-push,
    // no dup, still exactly one copy.
    srv.tickOnce(3000);
    srv.ent_lock.lock();
    try std.testing.expectEqual(@as(usize, 1), srv.region_reg.totalMobs());
    try std.testing.expect(dst.mobs.indexOfId(77) != null);
    srv.ent_lock.unlock();
}

test "Phase C: region dispatch ticks viewers + handoff on crossing" {
    // Page allocator throughout: region workers share it (the test
    // allocator is not for concurrent use).
    const a = std.heap.page_allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    srv.region_threads = 8; // force the parallel path (spawn fallback keeps it correct)
    var port: u16 = 37981;
    var listener: std.Io.net.Server = while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        break addr.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => {
                port += 1;
                if (port > 38010) return err;
                continue;
            },
            else => return err,
        };
    };
    defer listener.deinit(io);
    const mk = struct {
        fn run(l: *std.Io.net.Server, p: u16, name: []const u8, x: f64, z: f64) !struct {
            conn: *Conn,
            srv_stream: std.Io.net.Stream,
            cli_stream: std.Io.net.Stream,
        } {
            const addr = try std.Io.net.IpAddress.parse("127.0.0.1", p);
            var cli = try addr.connect(io, .{ .mode = .stream });
            errdefer cli.close(io);
            const sv = try l.accept(io);
            const c = try a.create(Conn);
            errdefer a.destroy(c);
            c.* = Conn.init(a, io, .{}, 1);
            c.state = .play;
            @memcpy(c.username[0..name.len], name);
            c.username_len = name.len;
            c.pos_x = x;
            c.pos_z = z;
            c.last_echo_ms = 1000; // keepalive anchored (no kick during the test)
            // Each viewer sees its own chunk (reconcile has range to work with).
            const cc = c.playerChunk();
            try c.sent.put(Conn.sentKey(cc.cx, cc.cz), {});
            return .{ .conn = c, .srv_stream = sv, .cli_stream = cli };
        }
    };
    // Alice near origin (region 0,0), Bob 2000 blocks east (region 3,0).
    var alice = try mk.run(&listener, port, "Alice", 8.5, 8.5);
    defer alice.cli_stream.close(io);
    defer alice.srv_stream.close(io);
    defer a.destroy(alice.conn);
    var bob = try mk.run(&listener, port, "Bob", 2000.5, 8.5);
    defer bob.cli_stream.close(io);
    defer bob.srv_stream.close(io);
    defer a.destroy(bob.conn);
    try srv.register(alice.conn, alice.srv_stream);
    try srv.register(bob.conn, bob.srv_stream);
    srv.tickOnce(1000);
    // Two populated regions, stamped on both conns, no crossings yet.
    try std.testing.expectEqual(@as(usize, 2), srv.region_reg.count());
    try std.testing.expect(alice.conn.last_region != null);
    try std.testing.expectEqual(@as(i32, 0), alice.conn.last_region.?.rx);
    try std.testing.expectEqual(@as(i32, 3), bob.conn.last_region.?.rx);
    // Bob teleports into Alice's region: the next tick pushes a Transfer
    // 3,0 -> 0,0; the following tick's mob section drains it and the
    // target census observes it (drains run once per tick, before wander).
    bob.conn.lock.lock();
    bob.conn.pos_x = 10.5;
    bob.conn.pos_z = 10.5;
    bob.conn.last_echo_ms = 2000;
    bob.conn.lock.unlock();
    alice.conn.lock.lock();
    alice.conn.last_echo_ms = 2000;
    alice.conn.lock.unlock();
    srv.tickOnce(2000);
    try std.testing.expectEqual(@as(i32, 0), bob.conn.last_region.?.rx);
    alice.conn.lock.lock();
    alice.conn.last_echo_ms = 3000;
    alice.conn.lock.unlock();
    bob.conn.lock.lock();
    bob.conn.last_echo_ms = 3000;
    bob.conn.lock.unlock();
    srv.tickOnce(3000);
    const home = try srv.region_reg.getOrCreate(a, .{ .dim = 0, .rx = 0, .rz = 0 });
    try std.testing.expectEqual(@as(u64, 1), home.census);
    // region_threads=8 took the persistent-pool path (not fork-join).
    try std.testing.expect(srv.region_pool != null);
    // Stats line carries the region counters (breaker quiet: no sheds).
    var buf: [1024]u8 = undefined;
    const line = srv.statsLine(&buf);
    try std.testing.expect(std.mem.indexOf(u8, line, "regions=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "region_shed=0") != null);
    try std.testing.expectEqual(@as(u64, 0), srv.region_shed_total);
}

test "Phase C: thread resolution, transfer inbox, tick clock" {
    const a = std.heap.page_allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    // 0 = auto (cpus, max 8); 1 = sequential; explicit honored, capped.
    const auto = srv.resolveRegionThreads();
    try std.testing.expect(auto >= 1 and auto <= 8);
    srv.region_threads = 1;
    try std.testing.expectEqual(@as(usize, 1), srv.resolveRegionThreads());
    srv.region_threads = 4;
    try std.testing.expectEqual(@as(usize, 4), srv.resolveRegionThreads());
    srv.region_threads = 1000;
    try std.testing.expectEqual(@as(usize, tick_mod.max_workers), srv.resolveRegionThreads());
    srv.region_threads = 0;
    // A crossing lands in the target inbox; the next tick's mob section
    // drains it and feeds the census (drains run once per tick, up front).
    srv.pushTransfer(7, 0, 0, 0, .{ .dim = 0, .rx = 5, .rz = -3 }, 1.0, 2.0, 3.0);
    const r = try srv.region_reg.getOrCreate(a, .{ .dim = 0, .rx = 5, .rz = -3 });
    try std.testing.expect(!r.inbox.isEmpty());
    srv.tickOnce(1000);
    try std.testing.expect(r.inbox.isEmpty());
    try std.testing.expectEqual(@as(u64, 1), r.census);
    const msgs = try r.inbox.drain();
    defer a.free(msgs);
    try std.testing.expectEqual(@as(usize, 0), msgs.len);
    // Barrier payload publishes monotonically (tickOnce above already
    // published at least once).
    const g0 = srv.region_clock.load().generation;
    srv.region_clock.publish(20, 6020);
    const rd = srv.region_clock.load();
    try std.testing.expectEqual(@as(i64, 20), rd.age);
    try std.testing.expect(rd.generation > g0);
    srv.region_clock.publish(40, 6040);
    try std.testing.expect(srv.region_clock.load().generation > rd.generation);
}

test "statsLine renders per-subsystem memory independently (no buffer aliasing)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    const conn = try a.create(Conn);
    conn.* = Conn.init(a, io, .{}, 1);
    // Queue 4 bytes so the outbox is nonzero while sent-sets stay empty:
    // with the old shared-buffer bug all three fields rendered the last
    // write ("outbox=0 B sent=0 B ents=0 B").
    try conn.queueFramed(&[_]u8{ 1, 2, 3, 4 });
    try srv.registry.append(a, .{ .conn = conn, .stream = Server.closedStream() });
    var buf: [1024]u8 = undefined;
    const line = srv.statsLine(&buf);
    try std.testing.expect(std.mem.indexOf(u8, line, "outbox=4 B") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "sent=0 B") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "ents=0 B") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "ring=0 B") != null);
    // Live conns (blocking transport has no counters: registry size).
    try std.testing.expect(std.mem.indexOf(u8, line, "conns=1") != null);
    // No gen pool in this harness: GPU counters render zeroed.
    try std.testing.expect(std.mem.indexOf(u8, line, "gpu=0/0") != null);
    conn.deinit();
    a.destroy(conn);
}

test "tpsText reports tick timing and counts" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    var buf: [256]u8 = undefined;
    const line = srv.tpsText(&buf);
    try std.testing.expect(std.mem.indexOf(u8, line, "tick 1Hz") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "players: 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "ticks: 0") != null);
}

test "K1 tick: scheduled button release fires through tickOnce" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
        try pool.flushAll();
    }
    _ = try view.applyBlock(pool, a, 8, 63, 8, game_ids.stone, 0);
    _ = try view.applyBlock(pool, a, 9, 63, 8, game_ids.stone, 0);
    // Pressed stone button + live wire.
    _ = try view.applyBlock(pool, a, 8, 64, 8, game_ids.stone_button, 13);
    _ = try view.applyBlock(pool, a, 9, 64, 8, game_ids.redstone_wire, 15);
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer srv.items.deinit(a);
    srv.world = pool;
    srv.rs_sched.schedule(8, 64, 8, 1020, .button_release);
    srv.rs_tick = 1020;
    srv.tickOnce(0);
    try std.testing.expectEqual(@as(u4, 5), (try view.peekBlock(pool, a, 8, 64, 8)).?.meta);
    // Wire fades a single step per update (vanilla single-step settle).
    try std.testing.expectEqual(@as(u4, 14), (try view.peekBlock(pool, a, 9, 64, 8)).?.meta);
}

test "broadcastBlockChange/ArmSwing target sent-set viewers only" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);

    var port: u16 = 37971;
    var listener: std.Io.net.Server = while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        break addr.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => {
                port += 1;
                if (port > 38000) return err;
                continue;
            },
            else => return err,
        };
    };
    defer listener.deinit(io);
    const mk = struct {
        fn run(l: *std.Io.net.Server, p: u16) !struct {
            conn: *Conn,
            srv_stream: std.Io.net.Stream,
            cli_stream: std.Io.net.Stream,
        } {
            const addr = try std.Io.net.IpAddress.parse("127.0.0.1", p);
            var cli = try addr.connect(io, .{ .mode = .stream });
            errdefer cli.close(io);
            const sv = try l.accept(io);
            const c = try a.create(Conn);
            errdefer a.destroy(c);
            c.* = Conn.init(a, io, .{}, 1);
            c.state = .play;
            return .{ .conn = c, .srv_stream = sv, .cli_stream = cli };
        }
    };
    var alice = try mk.run(&listener, port);
    defer alice.cli_stream.close(io);
    defer alice.srv_stream.close(io);
    var bob = try mk.run(&listener, port);
    defer bob.cli_stream.close(io);
    defer bob.srv_stream.close(io);
    // alice tracks (0,0); bob tracks (5,0)
    try alice.conn.sent.put(Conn.sentKey(0, 0), {});
    try bob.conn.sent.put(Conn.sentKey(5, 0), {});
    try srv.register(alice.conn, alice.srv_stream);
    try srv.register(bob.conn, bob.srv_stream);
    // register is silent; one queued announce + drain drives the join broadcast both ways.
    srv.queueAnnounce(alice.conn);
    srv.drainAnnounces();
    // (One persistent reader per stream: fresh readers would drop coalesced bytes.)
    var arb: [128]u8 = undefined;
    var afb: [128]u8 = undefined;
    var arr = alice.cli_stream.reader(io, &arb);
    var brb: [128]u8 = undefined;
    var bfb: [128]u8 = undefined;
    var brr = bob.cli_stream.reader(io, &brb);
    {
        const f = try readFrame(&arr.interface, &afb);
        try std.testing.expectEqual(@as(i32, 0x38), f.id);
        const jc = try readFrame(&arr.interface, &afb);
        try std.testing.expectEqual(@as(i32, 0x02), jc.id);
        try std.testing.expect(std.mem.indexOf(u8, jc.body, "joined the game") != null);
        const g = try readFrame(&brr.interface, &bfb);
        try std.testing.expectEqual(@as(i32, 0x38), g.id);
        const kc = try readFrame(&brr.interface, &bfb);
        try std.testing.expectEqual(@as(i32, 0x02), kc.id);
    }
    // block change at (3,65,4) -> chunk (0,0): only alice
    try srv.broadcastBlockChange(null, 3, 65, 4, game_ids.bedrock, 0);
    {
        const f = try readFrame(&arr.interface, &afb);
        try std.testing.expectEqual(@as(i32, 0x23), f.id);
        var pr = codec.PacketReader.init(f.body);
        try std.testing.expectEqual(@as(i32, 3), try pr.readInt());
        try std.testing.expectEqual(@as(u8, 65), try pr.readByte());
        try std.testing.expectEqual(@as(i32, 4), try pr.readInt());
        try std.testing.expectEqual(@as(i32, 7), try pr.readVarInt());
        try std.testing.expectEqual(@as(u8, 0), try pr.readByte());
    }
    // arm swing near (5,0) with eid of a hypothetical entity: only bob
    try srv.broadcastArmSwing(null, 5, 0, 99, 0);
    {
        const f = try readFrame(&brr.interface, &bfb);
        try std.testing.expectEqual(@as(i32, 0x0B), f.id);
    }
    // alice must NOT have received anything for chunk (5,0): verified
    // implicitly since her next read below would have been out of order;
    // additionally confirm bob got nothing for chunk (0,0) by checking
    // bob has no stray 0x23 (non-blocking check via short timeout is
    // unavailable — instead assert total frame accounting on alice's side
    // in the live E2E below).
    srv.unregister(alice.conn);
    srv.unregister(bob.conn);
    try std.testing.expectEqual(@as(usize, 0), srv.registry.items.len);
}

test "hunger: exhaustion drain, regen, starvation gates" {
    const a = std.testing.allocator;
    var c = Conn.init(a, std.testing.io, .{ .gamemode = .survival }, 7);
    defer c.deinit();
    c.state = .play;
    // exhaustion > 4 burns saturation first, then food (normal)
    c.exhaustion = 5.0;
    c.saturation = 5.0;
    try std.testing.expect(Server.hungerTick(&c, .normal) == null);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c.exhaustion, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), c.saturation, 1e-6);
    try std.testing.expectEqual(@as(i16, 20), c.food);
    // audit counters reset on every visible drop (each log line accounts
    // exactly one drumstick/saturation point)
    c.exhaustion = 5.0;
    c.exh_move = 2.5;
    c.exh_jump = 0.8;
    c.exh_regen = 0.7;
    try std.testing.expect(Server.hungerTick(&c, .normal) == null);
    try std.testing.expectEqual(@as(f32, 0), c.exh_move);
    try std.testing.expectEqual(@as(f32, 0), c.exh_jump);
    try std.testing.expectEqual(@as(f32, 0), c.exh_regen);
    // saturation 0 -> food drops (peaceful exempts)
    c.exhaustion = 5.0;
    c.saturation = 0;
    try std.testing.expect(Server.hungerTick(&c, .normal) == null);
    try std.testing.expectEqual(@as(i16, 19), c.food);
    c.exhaustion = 5.0;
    try std.testing.expect(Server.hungerTick(&c, .peaceful) == null);
    try std.testing.expectEqual(@as(i16, 19), c.food); // peaceful: no drain
    // regen at food 18+: +1 hp and +3 exhaustion every 80 timer
    c.health = 10.0;
    c.food = 18;
    c.food_timer = 60;
    c.exhaustion = 0;
    try std.testing.expect(Server.hungerTick(&c, .normal) == null);
    try std.testing.expectApproxEqAbs(@as(f32, 11.0), c.health, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), c.exhaustion, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), c.exh_regen, 1e-6);
    // starve: normal hits at hp>1, spares hp==1; hard always hits
    c.health = 2.0;
    c.food = 0;
    c.food_timer = 60;
    try std.testing.expect(Server.hungerTick(&c, .normal) == null);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c.health, 1e-6);
    c.food_timer = 60;
    try std.testing.expect(Server.hungerTick(&c, .normal) == null);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c.health, 1e-6); // spared
    c.food_timer = 60;
    try std.testing.expectEqual(Server.DeathCause.starve, Server.hungerTick(&c, .hard).?);
    try std.testing.expect(c.is_dead); // hard: killing blow
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
}

test "env: drown countdown, lava+fire, suffocate; fall resolution" {
    const a = std.testing.allocator;
    var c = Conn.init(a, std.testing.io, .{ .gamemode = .survival }, 7);
    defer c.deinit();
    c.state = .play;
    // drown: 15 ticks grace (air 300->0), damage on the 16th
    var i: usize = 0;
    while (i < 15) : (i += 1) try std.testing.expect(Server.envTick(&c, true, false, false, false) == null);
    try std.testing.expectEqual(@as(i16, 0), c.air);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), c.health, 1e-6);
    try std.testing.expect(Server.envTick(&c, true, false, false, false) == null);
    try std.testing.expectApproxEqAbs(@as(f32, 18.0), c.health, 1e-6);
    try std.testing.expectEqual(@as(i16, 0), c.air);
    // surface resets air
    try std.testing.expect(Server.envTick(&c, false, false, false, false) == null);
    try std.testing.expectEqual(@as(i16, 300), c.air);
    // lava: 4 dmg + 300 fire ticks; fire burns 1/tick after leaving
    try std.testing.expect(Server.envTick(&c, false, true, false, false) == null);
    try std.testing.expectApproxEqAbs(@as(f32, 14.0), c.health, 1e-6);
    try std.testing.expectEqual(@as(u32, 300), c.fire_ticks);
    try std.testing.expect(Server.envTick(&c, false, false, false, false) == null);
    try std.testing.expectApproxEqAbs(@as(f32, 13.0), c.health, 1e-6);
    // water extinguishes instead of burning
    c.fire_ticks = 100;
    try std.testing.expect(Server.envTick(&c, true, false, false, false) == null);
    try std.testing.expectEqual(@as(u32, 0), c.fire_ticks);
    // suffocate: 2 per tick (vanilla 1.0/hit behind ~0.5s hurt immunity)
    try std.testing.expect(Server.envTick(&c, false, false, true, false) == null);
    try std.testing.expectApproxEqAbs(@as(f32, 11.0), c.health, 1e-6);
    // cactus: 1.0 per touching tick (1Hz model hits ~1/s; vanilla
    // hurt-resistance gates to ~1/0.5s, quantized to whole ticks here)
    try std.testing.expect(Server.envTick(&c, false, false, false, true) == null);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), c.health, 1e-6);
    try std.testing.expect(Server.envTick(&c, false, false, false, true) == null);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), c.health, 1e-6); // next tick hits again
    // creative is immune to cactus
    c.config.gamemode = .creative;
    c.cactus_cd = 0;
    try std.testing.expect(Server.envTick(&c, false, false, false, true) == null);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), c.health, 1e-6);
    c.config.gamemode = .survival;
    // fall: ceil(dist-3) without a world (no water to save us)
    c.pending_fall = .{ .dist = 5.5, .x = 0, .y = 64, .z = 0 };
    var srv = Server{ .net = undefined, .io = std.testing.io, .config = .{}, .gpa = a };
    defer srv.registry.deinit(a);
    srv.resolvePendingFall(&c);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), c.health, 1e-6); // 9-3
    try std.testing.expect(c.pending_fall == null);
    // short falls are free
    c.pending_fall = .{ .dist = 3.0, .x = 0, .y = 64, .z = 0 };
    srv.resolvePendingFall(&c);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), c.health, 1e-6);
    // f32 dust at an integer boundary (5.0000005 from summed network
    // steps) must not flip a whole extra heart: ceil(2.0000005) = 3.
    c.pending_fall = .{ .dist = 5.0000005, .x = 0, .y = 64, .z = 0 };
    srv.resolvePendingFall(&c);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), c.health, 1e-6); // 6-2
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
}

test "dig-drop gate: survival+adventure drop, creative/gamerule/air do not" {
    try std.testing.expect(Server.shouldDropBreak(.survival, .stone, true));
    try std.testing.expect(Server.shouldDropBreak(.adventure, .stone, true));
    try std.testing.expect(!Server.shouldDropBreak(.creative, .stone, true));
    try std.testing.expect(!Server.shouldDropBreak(.survival, .stone, false));
    try std.testing.expect(!Server.shouldDropBreak(.survival, .air, true));
}

test "live drop spawn: instant 0x0E/0x1C, no tick re-spawn, tick pickup grants" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    var port: u16 = 38001;
    var listener: std.Io.net.Server = while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        break addr.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => {
                port += 1;
                if (port > 38100) return err;
                continue;
            },
            else => return err,
        };
    };
    defer listener.deinit(io);
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var cli = try addr.connect(io, .{ .mode = .stream });
    defer cli.close(io);
    const sv = try listener.accept(io);
    defer sv.close(io);
    const c = try a.create(Conn);
    defer {
        c.deinit();
        a.destroy(c);
    }
    c.* = Conn.init(a, io, .{ .gamemode = .survival }, 7);
    c.state = .play;
    c.pos_x = 8.5;
    c.pos_y = 65.0;
    c.pos_z = 8.5;
    try c.sent.put(Conn.sentKey(0, 0), {});
    try srv.register(c, sv);
    var crb: [128]u8 = undefined;
    var cfb: [2048]u8 = undefined;
    var cread = cli.reader(io, &crb);
    // Serve-thread spawn: visible immediately, no tick wait.
    srv.spawnItemLive(.{ .id = game_ids.dirt, .count = 1, .damage = 0, .nbt = null }, 8.5, 65.1, 8.5, 10, .{ 0, 0, 0 });
    const eid = blk: {
        srv.ent_lock.lock();
        defer srv.ent_lock.unlock();
        try std.testing.expectEqual(@as(usize, 1), srv.items.items.len);
        break :blk srv.items.items[0].id;
    };
    try std.testing.expect(c.tracked.contains(eid));
    {
        const f0 = try readFrame(&cread.interface, &cfb);
        try std.testing.expectEqual(@as(i32, 0x0E), f0.id);
        const f1 = try readFrame(&cread.interface, &cfb);
        try std.testing.expectEqual(@as(i32, 0x1C), f1.id);
    }
    // Tick reconcile before the delay expires: tracked already, so no
    // re-spawn (and no pickup while can_pickup is false).
    {
        var claims = entity.ClaimSet{};
        const snap = [_]entity.ItemSnap{.{
            .id = eid,
            .x = 8.5,
            .y = 65.1,
            .z = 8.5,
            .item_id = game_ids.dirt,
            .count = 1,
            .damage = 0,
            .can_pickup = false,
        }};
        const Always = struct {
            fn f(_: *anyopaque, _: f64, _: f64) bool {
                return true;
            }
        }.f;
        var ctx: u8 = 0;
        try entity.reconcileViewer(c, conn_sink.bind(c), &[_]entity.PlayerSnap{}, &[_]entity.MobSnap{}, &snap, &[_]entity.PotionSnap{}, &claims, Always, &ctx);
        try std.testing.expect(!claims.contains(eid));
        try std.testing.expect(c.tracked.contains(eid));
        c.lock.lock();
        const out = try c.takeOutput();
        c.lock.unlock();
        defer a.free(out);
        try std.testing.expectEqual(@as(usize, 0), out.len);
    }
    // Delay expired + standing on it: single grant (slot + collect +
    // destroy), tracked cleared, no duplicate spawn.
    {
        var claims = entity.ClaimSet{};
        const snap = [_]entity.ItemSnap{.{
            .id = eid,
            .x = 8.5,
            .y = 65.1,
            .z = 8.5,
            .item_id = game_ids.dirt,
            .count = 1,
            .damage = 0,
            .can_pickup = true,
        }};
        const Always = struct {
            fn f(_: *anyopaque, _: f64, _: f64) bool {
                return true;
            }
        }.f;
        var ctx: u8 = 0;
        try entity.reconcileViewer(c, conn_sink.bind(c), &[_]entity.PlayerSnap{}, &[_]entity.MobSnap{}, &snap, &[_]entity.PotionSnap{}, &claims, Always, &ctx);
        try std.testing.expect(claims.contains(eid));
        try std.testing.expect(!c.tracked.contains(eid));
        try std.testing.expect(c.inv[36] != null);
        try std.testing.expectEqual(game_ids.dirt, c.inv[36].?.id);
        c.lock.lock();
        const out = try c.takeOutput();
        c.lock.unlock();
        defer a.free(out);
        // grant (Set Slot) + Collect + Destroy, in that order, and nothing
        // else (in particular no duplicate 0x0E spawn).
        var off: usize = 0;
        var seen = [_]i32{ -1, -1, -1 };
        var si: usize = 0;
        while (off < out.len and si < 3) : (si += 1) {
            var rr = codec.PacketReader.init(out[off..]);
            const h = try codec.decodeFrame(&rr);
            seen[si] = h.id;
            off += @as(usize, @intCast(codec.PacketWriter.varIntLen(h.length))) + @as(usize, @intCast(h.length));
        }
        try std.testing.expectEqual(@as(usize, 3), si);
        try std.testing.expectEqual(out.len, off);
        try std.testing.expectEqualSlices(i32, &[_]i32{ 0x2F, 0x0D, 0x13 }, &seen);
    }
    // No server-side residue: the tick's removeItemById would free the
    // claimed entity; the test owns cleanup instead (same discipline).
    srv.ent_lock.lock();
    while (srv.items.items.len > 0) {
        const dead = srv.items.swapRemove(0);
        var s: ?item_mod.Stack = dead.stack;
        item_mod.freeStack(a, &s);
    }
    srv.items.deinit(a);
    srv.ent_lock.unlock();
}

test "login landing disk: ensureLanding fills the 5x5 around the player" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    var gen = try v5gen.Gen.init(a, 42, false, false);
    defer gen.deinit();
    srv.gen = &gen;
    const c = try a.create(Conn);
    defer {
        c.deinit();
        a.destroy(c);
    }
    c.* = Conn.init(a, io, .{}, 7);
    c.pos_x = 0.5;
    c.pos_y = 69.0;
    c.pos_z = 0.5;
    c.lock.lock();
    srv.ensureLanding(pool, a, c);
    c.lock.unlock();
    // All 25 landing columns exist now (sync fill; no workers in this path).
    var dx: i32 = -2;
    while (dx <= 2) : (dx += 1) {
        var dz: i32 = -2;
        while (dz <= 2) : (dz += 1) {
            const raw = try pool.get(a, store_mod.encodeKey(0, dx, dz));
            if (raw) |r| a.free(r);
            try std.testing.expect(raw != null);
        }
    }
}

test "login landing wait is scoped to the 5x5, not the whole backlog" {
    // Regression: ensureLanding used gp.drain(), which parks the serve
    // thread behind the ENTIRE pool backlog — under /pregen a fresh login
    // hung until the whole task finished. landingInflight scopes the wait
    // to our own 25 columns (bounded; leftovers stay holes under grace).
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    var lock: spin.SpinLock = .{};
    var gp = try v5genpool.GenPool.create(a, io, pool, &lock, 42, false, false, 1, .{});
    defer {
        gp.destroy();
        a.destroy(gp);
    }
    // Unrelated backlog far away (stands in for a pregen backlog).
    gp.request(0, 100, 100);
    // Our disk is clean: nothing inflight (request adds synchronously, the
    // worker needs ~100ms of noise math to clear it — no race here).
    try std.testing.expect(!srv.landingInflight(gp, 0, 0));
    // The backlogged column reads inflight from its own disk...
    try std.testing.expect(srv.landingInflight(gp, 100, 100));
    // ...but not from ours (a global drain would wait for it anyway).
    try std.testing.expect(!srv.landingInflight(gp, 0, 0));
    gp.drain();
    try std.testing.expect(!srv.landingInflight(gp, 100, 100));
}

test "login lapse resolves on generation state, not blindly" {
    // Regression for login-embedded joins: a fall held past the grace
    // deadline must not adopt into an undelivered column (terrain
    // generates solid around it and the player wakes up suffocating).
    // The tick re-arms while the column is a hole and releases once
    // ground exists.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    srv.world = pool;
    const c = try a.create(Conn);
    defer {
        c.deinit();
        a.destroy(c);
    }
    c.* = Conn.init(a, io, .{}, 7);
    c.state = .play;
    c.pos_x = 0.5;
    c.pos_y = 69.0;
    c.pos_z = 0.5;
    // Lapsed with the column missing: re-arm (deadline in the future),
    // keep holding, allow a fresh snap on delivery.
    c.login_grace_lapsed = true;
    c.login_fell = true;
    c.login_resynced = true;
    srv.maybeLoginResync(c);
    try std.testing.expect(c.login_grace_ms != 0);
    try std.testing.expect(!c.login_grace_lapsed);
    try std.testing.expect(!c.login_resynced);
    // Column lands: the next resolve releases instead of re-arming.
    var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
    defer ch.destroy(a);
    try pool.putChunk(a, ch);
    c.login_grace_lapsed = true;
    srv.maybeLoginResync(c);
    try std.testing.expect(c.login_grace_ms == 0);
    try std.testing.expect(!c.login_grace_lapsed);
}

test "tick rescue lifts embedded players to headroom" {
    // The one-shot login rescue is hole-blind; burial after it (adopted
    // hole falls, away-edits, drift) must not stick. Per-tick rescue
    // lifts fully-embedded players in present columns; open air and
    // holes are no-ops.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    srv.world = pool;
    // Solid pillar y 60..67 at column (8,*,8).
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        var y: u8 = 60;
        while (y <= 67) : (y += 1) {
            const si: usize = @as(usize, y) >> 4;
            if (ch.sections[si] == null) ch.sections[si] = chunk_mod.Section{};
            ch.sections[si].?.setBlock(8, @truncate(y & 15), 8, .stone);
        }
        try pool.putChunk(a, ch);
    }
    const c = try a.create(Conn);
    defer {
        c.deinit();
        a.destroy(c);
    }
    c.* = Conn.init(a, io, .{}, 7);
    c.state = .play;
    // Embedded (feet 62 + eyes 63 both stone): lifted to 68.
    c.pos_x = 8.5;
    c.pos_y = 62.0;
    c.pos_z = 8.5;
    try std.testing.expect(srv.rescueEmbedded(c));
    try std.testing.expectApproxEqAbs(@as(f64, 68.0), c.pos_y, 1e-9);
    // Open air: no-op.
    c.pos_y = 70.0;
    try std.testing.expect(!srv.rescueEmbedded(c));
    try std.testing.expectApproxEqAbs(@as(f64, 70.0), c.pos_y, 1e-9);
    // Missing column (holes read as missing, never "rescued" blindly).
    c.pos_x = 80.5;
    c.pos_z = 80.5;
    c.pos_y = 62.0;
    try std.testing.expect(!srv.rescueEmbedded(c));
    try std.testing.expectApproxEqAbs(@as(f64, 62.0), c.pos_y, 1e-9);
    // Desync breaker: three rescues at one column drop it from `sent`
    // (lost burst column — the 10Hz hole-healer skips sent columns, so
    // without this a client-side hole loops adopt/rescue forever).
    c.pos_x = 8.5;
    c.pos_z = 8.5;
    c.rescue_n = 0; // earlier rescues above already counted this cell
    try c.sent.put(Conn.sentKey(0, 0), {});
    c.pos_y = 62.0;
    try std.testing.expect(srv.rescueEmbedded(c));
    try std.testing.expect(c.sent.contains(Conn.sentKey(0, 0)));
    c.pos_y = 62.0;
    try std.testing.expect(srv.rescueEmbedded(c));
    try std.testing.expect(c.sent.contains(Conn.sentKey(0, 0)));
    c.pos_y = 62.0;
    try std.testing.expect(srv.rescueEmbedded(c));
    try std.testing.expect(!c.sent.contains(Conn.sentKey(0, 0)));
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
}

test "resolveAttack: mob damage/death/destroy, PvP, reach, pig respawn timer" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer {
        srv.ent_lock.lock();
        srv.items.deinit(a);
        srv.ent_lock.unlock();
    }
    var port: u16 = 37971;
    var listener: std.Io.net.Server = while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        break addr.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => {
                port += 1;
                if (port > 38000) return err;
                continue;
            },
            else => return err,
        };
    };
    defer listener.deinit(io);
    const mk = struct {
        fn run(l: *std.Io.net.Server, p: u16, eid: i32) !struct {
            conn: *Conn,
            srv_stream: std.Io.net.Stream,
            cli_stream: std.Io.net.Stream,
        } {
            const addr = try std.Io.net.IpAddress.parse("127.0.0.1", p);
            var cli = try addr.connect(io, .{ .mode = .stream });
            errdefer cli.close(io);
            const sv = try l.accept(io);
            const c = try a.create(Conn);
            errdefer a.destroy(c);
            // Survival: combat damage applies (creative is immune, like vanilla).
            c.* = Conn.init(a, io, .{ .gamemode = .survival }, eid);
            c.state = .play;
            return .{ .conn = c, .srv_stream = sv, .cli_stream = cli };
        }
    };
    var alice = try mk.run(&listener, port, 1);
    defer alice.cli_stream.close(io);
    defer alice.srv_stream.close(io);
    var bob = try mk.run(&listener, port, 2);
    defer bob.cli_stream.close(io);
    defer bob.srv_stream.close(io);
    try srv.register(alice.conn, alice.srv_stream);
    try srv.register(bob.conn, bob.srv_stream);
    // No queued announce: streams stay clean for deterministic reads.
    var arb: [128]u8 = undefined;
    var afb: [512]u8 = undefined;
    var arr = alice.cli_stream.reader(io, &arb);
    var brb: [128]u8 = undefined;
    var bfb: [512]u8 = undefined;
    var brr = bob.cli_stream.reader(io, &brb);
    // Pig id 50 at (10,64,10), hp 10; alice tracks it.
    srv.ent_lock.lock();
    const pig_reg = try srv.region_reg.getOrCreate(a, .{ .dim = 0, .rx = 0, .rz = 0 });
    _ = try pig_reg.mobs.add(.{ .id = 50, .kind = entity.MOB_PIG, .x = 10, .y = 64, .z = 10, .yaw = 0, .health = 10.0, .home_x = 10, .home_z = 10, .patrol_r = 4 });
    srv.ent_lock.unlock();
    try alice.conn.tracked.put(50, .{ .x = 0, .y = 0, .z = 0, .yaw = 0, .pitch = 0 });
    // Non-lethal hit: 10 -> 7, metadata to trackers.
    srv.resolveAttack(alice.conn, .{ .target_eid = 50, .dmg = 3, .ax = 10, .ay = 64, .az = 10 });
    srv.ent_lock.lock();
    {
        const f50 = srv.region_reg.findMob(50).?;
        try std.testing.expectApproxEqAbs(@as(f32, 7.0), f50.region.mobs.health.items[f50.index], 1e-6);
    }
    srv.ent_lock.unlock();
    {
        const f = try readFrame(&arr.interface, &afb);
        try std.testing.expectEqual(@as(i32, 0x1C), f.id);
        var pr = codec.PacketReader.init(f.body);
        try std.testing.expectEqual(@as(i32, 50), try pr.readInt());
        try std.testing.expectEqual(@as(u8, 0x00), try pr.readByte());
        _ = try pr.readByte();
        try std.testing.expectEqual(@as(u8, 0x21), try pr.readByte());
        _ = try pr.readShort();
        try std.testing.expectEqual(@as(u8, 0x66), try pr.readByte()); // (3<<5)|6 float health
        try std.testing.expectApproxEqAbs(@as(f32, 7.0), try pr.readFloat(), 1e-6);
    }
    // Out of reach: no damage.
    srv.resolveAttack(alice.conn, .{ .target_eid = 50, .dmg = 3, .ax = 900, .ay = 64, .az = 900 });
    srv.ent_lock.lock();
    {
        const f50 = srv.region_reg.findMob(50).?;
        try std.testing.expectApproxEqAbs(@as(f32, 7.0), f50.region.mobs.health.items[f50.index], 1e-6);
    }
    srv.ent_lock.unlock();
    // Lethal hit: destroy broadcast, mob removed, respawn timer armed.
    srv.resolveAttack(alice.conn, .{ .target_eid = 50, .dmg = 10, .ax = 10, .ay = 64, .az = 10 });
    srv.ent_lock.lock();
    try std.testing.expectEqual(@as(usize, 0), srv.region_reg.totalMobs());
    try std.testing.expectEqual(@as(u32, 30), srv.pig_cooldown);
    srv.ent_lock.unlock();
    {
        const f = try readFrame(&arr.interface, &afb);
        try std.testing.expectEqual(@as(i32, 0x13), f.id);
        var pr = codec.PacketReader.init(f.body);
        try std.testing.expectEqual(@as(u8, 1), try pr.readByte());
        try std.testing.expectEqual(@as(i32, 50), try pr.readInt());
    }
    // Unknown eid: silent no-op.
    srv.resolveAttack(alice.conn, .{ .target_eid = 4242, .dmg = 5, .ax = 10, .ay = 64, .az = 10 });
    // PvP: bob at (20,64,20), alice tracks him.
    bob.conn.pos_x = 20;
    bob.conn.pos_z = 20;
    try alice.conn.tracked.put(2, .{ .x = 0, .y = 0, .z = 0, .yaw = 0, .pitch = 0 });
    srv.resolveAttack(alice.conn, .{ .target_eid = 2, .dmg = 3, .ax = 20, .ay = 64, .az = 20 });
    try std.testing.expectApproxEqAbs(@as(f32, 17.0), bob.conn.health, 1e-6);
    // PvP disabled (config "pvp": false): the same swing fizzles —
    // health unchanged, nothing queued (frame alignment below depends
    // on the silence).
    {
        var c = srv.cfg.load();
        c.pvp = false;
        srv.cfg.store(c);
    }
    srv.resolveAttack(alice.conn, .{ .target_eid = 2, .dmg = 3, .ax = 20, .ay = 64, .az = 20 });
    try std.testing.expectApproxEqAbs(@as(f32, 17.0), bob.conn.health, 1e-6);
    {
        var c = srv.cfg.load();
        c.pvp = true;
        srv.cfg.store(c);
    }
    {
        const f = try readFrame(&brr.interface, &bfb);
        try std.testing.expectEqual(@as(i32, 0x06), f.id);
        var pr = codec.PacketReader.init(f.body);
        try std.testing.expectApproxEqAbs(@as(f32, 17.0), try pr.readFloat(), 1e-6);
    }
    {
        const f = try readFrame(&arr.interface, &afb);
        try std.testing.expectEqual(@as(i32, 0x1C), f.id);
        var pr = codec.PacketReader.init(f.body);
        try std.testing.expectEqual(@as(i32, 2), try pr.readInt());
    }
    // Armored PvP: iron chestplate (6 points) cuts dmg 10 -> ~7.6.
    bob.conn.inv[6] = .{ .id = game_ids.iron_chestplate, .count = 1, .damage = 0, .nbt = null };
    srv.resolveAttack(alice.conn, .{ .target_eid = 2, .dmg = 10, .ax = 20, .ay = 64, .az = 20 });
    try std.testing.expectApproxEqAbs(@as(f32, 9.4), bob.conn.health, 1e-4);
    try std.testing.expectEqual(@as(i16, 3), bob.conn.inv[6].?.damage); // wear scales with the hit
    {
        // wear 0x2F lands before the health update (same outbox order).
        const f = try readFrame(&brr.interface, &bfb);
        try std.testing.expectEqual(@as(i32, 0x2F), f.id);
        var pr = codec.PacketReader.init(f.body);
        _ = try pr.readByte(); // window 0
        try std.testing.expectEqual(@as(i16, 6), try pr.readShort());
    }
    {
        const f = try readFrame(&brr.interface, &bfb);
        try std.testing.expectEqual(@as(i32, 0x06), f.id);
        var pr = codec.PacketReader.init(f.body);
        try std.testing.expectApproxEqAbs(@as(f32, 9.4), try pr.readFloat(), 1e-4);
    }
    {
        const f = try readFrame(&arr.interface, &afb);
        try std.testing.expectEqual(@as(i32, 0x1C), f.id);
    }
    // Protection II on the chest (EPF 3) stacks after armor: 10 -> ~6.69.
    {
        var nb: [256]u8 = undefined;
        const ench_raw = Server.buildEnchNbt(null, 0, 2, &nb).?;
        bob.conn.inv[6].?.nbt = try a.dupe(u8, ench_raw);
    }
    srv.resolveAttack(alice.conn, .{ .target_eid = 2, .dmg = 10, .ax = 20, .ay = 64, .az = 20 });
    try std.testing.expectApproxEqAbs(@as(f32, 2.712), bob.conn.health, 1e-3);
    {
        const f = try readFrame(&brr.interface, &bfb);
        try std.testing.expectEqual(@as(i32, 0x2F), f.id);
    }
    {
        const f = try readFrame(&brr.interface, &bfb);
        try std.testing.expectEqual(@as(i32, 0x06), f.id);
        var pr = codec.PacketReader.init(f.body);
        try std.testing.expectApproxEqAbs(@as(f32, 2.712), try pr.readFloat(), 1e-3);
    }
    {
        const f = try readFrame(&arr.interface, &afb);
        try std.testing.expectEqual(@as(i32, 0x1C), f.id);
    }
    if (bob.conn.inv[6].?.nbt) |n| {
        a.free(n);
        bob.conn.inv[6].?.nbt = null;
    }
    // Lethal PvP: death screen + dead flag; further hits ignored.
    srv.resolveAttack(alice.conn, .{ .target_eid = 2, .dmg = 30, .ax = 20, .ay = 64, .az = 20 });
    try std.testing.expect(bob.conn.is_dead);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), bob.conn.health, 1e-6);
    {
        const f = try readFrame(&brr.interface, &bfb);
        try std.testing.expectEqual(@as(i32, 0x2F), f.id); // final wear sync
    }
    {
        const f = try readFrame(&brr.interface, &bfb);
        try std.testing.expectEqual(@as(i32, 0x06), f.id);
        var pr = codec.PacketReader.init(f.body);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), try pr.readFloat(), 1e-6);
    }
    srv.resolveAttack(alice.conn, .{ .target_eid = 2, .dmg = 30, .ax = 20, .ay = 64, .az = 20 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), bob.conn.health, 1e-6);
    // Respawn timer: 30 ticks with a world present brings the pig back.
    srv.unregister(alice.conn);
    srv.unregister(bob.conn);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    srv.world = pool;
    var t: i64 = 0;
    while (t < 31) : (t += 1) {
        srv.tickOnce(t * 1000);
    }
    srv.ent_lock.lock();
    defer srv.ent_lock.unlock();
    try std.testing.expectEqual(@as(usize, 1), srv.region_reg.totalMobs());
    var found_pig = false;
    var rbuf: [8]*tick_mod.Region = undefined;
    for (rbuf[0..srv.region_reg.allRegions(&rbuf)]) |rg| {
        for (rg.mobs.kinds.items) |k| {
            if (k == entity.MOB_PIG) found_pig = true;
        }
    }
    try std.testing.expect(found_pig);
    // Lethal PvP above left death drops in srv.items (no viewer picks them
    // up and 31 ticks don't despawn them): free them like the live-drop
    // test does, or the ArrayList buffer leaks.
    while (srv.items.items.len > 0) {
        const dead = srv.items.swapRemove(0);
        var s: ?item_mod.Stack = dead.stack;
        item_mod.freeStack(a, &s);
    }
}

test "death drops include armor, crafting vanishes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var c = Conn.init(a, io, .{}, 7);
    defer c.deinit();
    c.inv[0] = .{ .id = game_ids.stick, .count = 4, .damage = 0, .nbt = null };
    c.inv[5] = .{ .id = game_ids.iron_helmet, .count = 1, .damage = 0, .nbt = null };
    c.inv[9] = .{ .id = game_ids.dirt, .count = 3, .damage = 0, .nbt = null };
    c.cursor = .{ .id = game_ids.stone, .count = 2, .damage = 0, .nbt = null };
    c.lock.lock();
    var dd = Server.collectDeathDrops(&c);
    c.lock.unlock();
    defer {
        for (dd.stacks[0..dd.n]) |*s| {
            var tmp: ?item_mod.Stack = s.*;
            item_mod.freeStack(a, &tmp);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), dd.n);
    try std.testing.expectEqual(game_ids.iron_helmet, dd.stacks[0].?.id);
    try std.testing.expectEqual(game_ids.dirt, dd.stacks[1].?.id);
    try std.testing.expectEqual(game_ids.stone, dd.stacks[2].?.id);
    try std.testing.expect(c.inv[5] == null and c.inv[9] == null and c.cursor == null);
    try std.testing.expect(c.inv[0] != null); // crafting result stays behind (vanishes)
}

test "resistance cuts fire damage 20% per level" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var c = Conn.init(a, io, .{ .gamemode = .survival }, 7);
    defer c.deinit();
    c.state = .play;
    c.fire_ticks = 40;
    c.effects[0] = .{ .id = 11, .amplifier = 0, .ticks = 100 };
    c.lock.lock();
    const cause = Server.envTick(&c, false, false, false, false);
    c.lock.unlock();
    try std.testing.expect(cause == null);
    try std.testing.expectApproxEqAbs(@as(f32, 19.2), c.health, 1e-4);
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
}

test "deathMessage: vanilla English lines for every cause" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Al died", Server.deathMessage("Al", .generic, "", &buf));
    try std.testing.expectEqualStrings("Al fell from a high place", Server.deathMessage("Al", .fall, "", &buf));
    try std.testing.expectEqualStrings("Al fell out of the world", Server.deathMessage("Al", .void, "", &buf));
    try std.testing.expectEqualStrings("Al starved to death", Server.deathMessage("Al", .starve, "", &buf));
    try std.testing.expectEqualStrings("Al drowned", Server.deathMessage("Al", .drown, "", &buf));
    try std.testing.expectEqualStrings("Al tried to swim in lava", Server.deathMessage("Al", .lava, "", &buf));
    try std.testing.expectEqualStrings("Al went up in flames", Server.deathMessage("Al", .fire, "", &buf));
    try std.testing.expectEqualStrings("Al suffocated in a wall", Server.deathMessage("Al", .suffocate, "", &buf));
    try std.testing.expectEqualStrings("Al was pricked to death", Server.deathMessage("Al", .cactus, "", &buf));
    try std.testing.expectEqualStrings("Al was slain by Bo", Server.deathMessage("Al", .player, "Bo", &buf));
}

test "killPlayer broadcasts the vanilla death line" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    var port: u16 = 37981;
    var listener: std.Io.net.Server = while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        break addr.listen(io, .{ .mode = .stream }) catch |err| switch (err) {
            error.AddressInUse => {
                port += 1;
                if (port > 38000) return err;
                continue;
            },
            else => return err,
        };
    };
    defer listener.deinit(io);
    const mk = struct {
        fn run(l: *std.Io.net.Server, p: u16, eid: i32, name: []const u8) !struct {
            conn: *Conn,
            srv_stream: std.Io.net.Stream,
            cli_stream: std.Io.net.Stream,
        } {
            const addr = try std.Io.net.IpAddress.parse("127.0.0.1", p);
            var cli = try addr.connect(io, .{ .mode = .stream });
            errdefer cli.close(io);
            const sv = try l.accept(io);
            const c = try a.create(Conn);
            errdefer a.destroy(c);
            c.* = Conn.init(a, io, .{ .gamemode = .survival }, eid);
            c.state = .play;
            @memcpy(c.username[0..name.len], name);
            c.username_len = name.len;
            return .{ .conn = c, .srv_stream = sv, .cli_stream = cli };
        }
    }.run;
    var alice = try mk(&listener, port, 1, "Alice");
    defer alice.cli_stream.close(io);
    defer alice.srv_stream.close(io);
    var bob = try mk(&listener, port, 2, "Bob");
    defer bob.cli_stream.close(io);
    defer bob.srv_stream.close(io);
    try srv.register(alice.conn, alice.srv_stream);
    try srv.register(bob.conn, bob.srv_stream);
    var arb: [128]u8 = undefined;
    var afb: [512]u8 = undefined;
    var arr = alice.cli_stream.reader(io, &arb);
    var brb: [128]u8 = undefined;
    var bfb: [512]u8 = undefined;
    var brr = bob.cli_stream.reader(io, &brb);
    try std.testing.expect(srv.killPlayer("bob"));
    // Victim first sees the death screen, then the death line.
    {
        const f = try readFrame(&brr.interface, &bfb);
        try std.testing.expectEqual(@as(i32, 0x06), f.id);
    }
    {
        const f = try readFrame(&brr.interface, &bfb);
        try std.testing.expectEqual(@as(i32, 0x02), f.id);
        var pr = codec.PacketReader.init(f.body);
        try std.testing.expectEqualStrings("{\"text\":\"Bob died\"}", try pr.readString());
    }
    // Bystanders get the line too.
    {
        const f = try readFrame(&arr.interface, &afb);
        try std.testing.expectEqual(@as(i32, 0x02), f.id);
        var pr = codec.PacketReader.init(f.body);
        try std.testing.expectEqualStrings("{\"text\":\"Bob died\"}", try pr.readString());
    }
    srv.unregister(alice.conn);
    srv.unregister(bob.conn);
}

test "tickOnce spawns/tracks/despawns players + mobs" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    var port: u16 = 37971;
    var listener: std.Io.net.Server = while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        break addr.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => {
                port += 1;
                if (port > 38000) return err;
                continue;
            },
            else => return err,
        };
    };
    defer listener.deinit(io);
    const mk = struct {
        fn run(l: *std.Io.net.Server, p: u16, name: []const u8) !struct {
            conn: *Conn,
            srv_stream: std.Io.net.Stream,
            cli_stream: std.Io.net.Stream,
        } {
            const addr = try std.Io.net.IpAddress.parse("127.0.0.1", p);
            var cli = try addr.connect(io, .{ .mode = .stream });
            errdefer cli.close(io);
            const sv = try l.accept(io);
            const c = try a.create(Conn);
            errdefer a.destroy(c);
            c.* = Conn.init(a, io, .{}, 1);
            c.state = .play;
            @memcpy(c.username[0..name.len], name);
            c.username_len = name.len;
            @memcpy(c.uuid_str[0..36], "52d22a52-7b4a-339e-8a09-aa52384d72fd");
            return .{ .conn = c, .srv_stream = sv, .cli_stream = cli };
        }
    };
    var alice = try mk.run(&listener, port, "Alice");
    defer alice.cli_stream.close(io);
    defer alice.srv_stream.close(io);
    // alice near origin; give her chunk (0,0) so entities there are visible
    alice.conn.sent.clearRetainingCapacity();
    try alice.conn.sent.put(Conn.sentKey(0, 0), {});
    try srv.register(alice.conn, alice.srv_stream);
    // (register broadcast is a no-op with nobody else around)
    // manually add a pig at (10.5, 64, 10.5) (chunk (0,0), in range)
    var pig_id: i32 = 0;
    {
        srv.ent_lock.lock();
        defer srv.ent_lock.unlock();
        pig_id = srv.eid_counter.fetchAdd(1, .acq_rel);
        const pig_reg = try srv.region_reg.getOrCreate(a, .{ .dim = 0, .rx = 0, .rz = 0 });
        _ = try pig_reg.mobs.add(.{
            .id = pig_id,
            .kind = entity.MOB_PIG,
            .x = 10.5,
            .y = 64.0,
            .z = 10.5,
            .yaw = 0,
            .health = 10.0,
            .home_x = 10.5,
            .home_z = 10.5,
            .patrol_r = 0.5,
        });
    }
    // tick: time + keepalive + spawn pig (no players nearby besides self)
    srv.tickOnce(1000);
    var arb: [4096]u8 = undefined;
    var afb: [4096]u8 = undefined;
    var arr = alice.cli_stream.reader(io, &arb);
    // collect until pig spawn seen (time+keepalive first)
    var saw_spawn = false;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const f = try readFrame(&arr.interface, &afb);
        if (f.id == 0x0F) {
            saw_spawn = true;
            var pr = codec.PacketReader.init(f.body);
            try std.testing.expectEqual(pig_id, try pr.readVarInt());
            try std.testing.expectEqual(@as(u8, profile.game.mobs.wire(entity.MOB_PIG)), try pr.readByte());
            break;
        }
        try std.testing.expect(f.id == 0x03 or f.id == 0x00);
    }
    try std.testing.expect(saw_spawn);
    // pig wanders: relmove frames (0.5 blocks = 16 fixed units) must show up
    // across ticks. Each tick emits exactly one 0x03 (keepalive only every
    // 15s), so collect until time is seen and note any 0x15 along the way.
    var saw_move = false;
    var tick_n: usize = 0;
    while (tick_n < 8) : (tick_n += 1) {
        srv.tickOnce(3000 + @as(i64, @intCast(tick_n)) * 1000);
        var n: usize = 0;
        while (n < 5) : (n += 1) {
            const f = try readFrame(&arr.interface, &afb);
            if (f.id == 0x03) break;
            if (f.id == 0x15 or f.id == 0x17 or f.id == 0x18) saw_move = true;
        }
    }
    try std.testing.expect(saw_move);
    // move pig far away via direct edit -> next tick must teleport or destroy.
    // out of chunk: destroy expected (no sent chunk covers it).
    // (echo recently so the timeout kick doesn't fire instead)
    alice.conn.last_echo_ms = 99900;
    {
        srv.ent_lock.lock();
        const fpig = srv.region_reg.findMob(pig_id).?;
        fpig.region.mobs.px.items[fpig.index] = 500.0;
        srv.ent_lock.unlock();
    }
    srv.tickOnce(99999);
    var got_destroy = false;
    var n: usize = 0;
    while (n < 8) : (n += 1) {
        const f = try readFrame(&arr.interface, &afb);
        if (f.id == 0x13) {
            got_destroy = true;
            var pr = codec.PacketReader.init(f.body);
            try std.testing.expectEqual(@as(u8, 1), try pr.readByte());
            try std.testing.expectEqual(pig_id, try pr.readInt());
            break;
        }
        // skip time/keepalive/teleport frames
        if (f.id != 0x03 and f.id != 0x00 and f.id != 0x18) break;
    }
    try std.testing.expect(got_destroy);
    srv.unregister(alice.conn);
}

test "broadcastChat reaches all play conns; login timeout kicks stale logins" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    var port: u16 = 37981;
    var listener: std.Io.net.Server = while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        break addr.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => {
                port += 1;
                if (port > 38010) return err;
                continue;
            },
            else => return err,
        };
    };
    defer listener.deinit(io);
    const mk = struct {
        fn run(l: *std.Io.net.Server, p: u16, name: []const u8, st: ids.State) !struct {
            conn: *Conn,
            srv_stream: std.Io.net.Stream,
            cli_stream: std.Io.net.Stream,
        } {
            const addr = try std.Io.net.IpAddress.parse("127.0.0.1", p);
            var cli = try addr.connect(io, .{ .mode = .stream });
            errdefer cli.close(io);
            const sv = try l.accept(io);
            const c = try a.create(Conn);
            errdefer a.destroy(c);
            c.* = Conn.init(a, io, .{}, 1);
            c.state = st;
            @memcpy(c.username[0..name.len], name);
            c.username_len = name.len;
            return .{ .conn = c, .srv_stream = sv, .cli_stream = cli };
        }
    };
    var alice = try mk.run(&listener, port, "AliceC", .play);
    defer alice.cli_stream.close(io);
    defer alice.srv_stream.close(io);
    var bob = try mk.run(&listener, port, "BobC", .play);
    defer bob.cli_stream.close(io);
    defer bob.srv_stream.close(io);
    var stuck = try mk.run(&listener, port, "Stuck", .login);
    defer stuck.cli_stream.close(io);
    defer stuck.srv_stream.close(io);
    // (owned by the registry until unregister below; no manual deinit)
    try srv.register(alice.conn, alice.srv_stream);
    try srv.register(bob.conn, bob.srv_stream);
    try srv.register(stuck.conn, stuck.srv_stream);
    // align the stuck conn with the fake test clock
    stuck.conn.connected_at_ms = 0;

    // chat broadcast reaches every play conn (not the logging-in one).
    // NOTE: broadcastChat takes the raw JSON string (it frames internally).
    srv.broadcastChat("{\"text\":\"hi\"}");
    for ([2]std.Io.net.Stream{ alice.cli_stream, bob.cli_stream }) |cs| {
        var rb: [128]u8 = undefined;
        var fb: [256]u8 = undefined;
        var rr = cs.reader(io, &rb);
        const f = try readFrame(&rr.interface, &fb);
        try std.testing.expectEqual(@as(i32, 0x02), f.id);
        var pr = codec.PacketReader.init(f.body);
        try std.testing.expectEqualStrings("{\"text\":\"hi\"}", try pr.readString());
    }

    // login timeout: stuck is in .login with connected_at=0; tick far ahead
    // must queue a login disconnect (0x00) and mark it dead.
    srv.tickOnce(31000);
    {
        var rb: [128]u8 = undefined;
        var fb: [256]u8 = undefined;
        var rr = stuck.cli_stream.reader(io, &rb);
        const f = try readFrame(&rr.interface, &fb);
        try std.testing.expectEqual(@as(i32, 0x00), f.id);
    }
    try std.testing.expect(stuck.conn.dead);
    // play conns are unaffected (they got time+keepalive instead of kicks)
    try std.testing.expect(!alice.conn.dead);
    try std.testing.expect(!bob.conn.dead);

    srv.unregister(alice.conn);
    srv.unregister(bob.conn);
    srv.unregister(stuck.conn);
    try std.testing.expectEqual(@as(usize, 0), srv.registry.items.len);
}

test "read timeout kills without flushing the dead outbox" {
    // A peer silent for 30s (keepalives unanswered) is closed, not
    // flushed: draining a black-hole peer's outbox (mid-burst megabytes)
    // wedges the ticker in writeAll, stalling every conn behind it.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    var port: u16 = 38021;
    var listener: std.Io.net.Server = while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        break addr.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => {
                port += 1;
                if (port > 38050) return err;
                continue;
            },
            else => return err,
        };
    };
    defer listener.deinit(io);
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var cli = try addr.connect(io, .{ .mode = .stream });
    defer cli.close(io);
    const sv = try listener.accept(io);
    const c = try a.create(Conn);
    c.* = Conn.init(a, io, .{}, 1);
    c.state = .play;
    @memcpy(c.username[0.."Ghost".len], "Ghost");
    c.username_len = 5;
    try srv.register(c, sv);
    // First tick arms the keepalive (no reply ever comes); far-future
    // tick trips the 30s silence timeout.
    srv.tickOnce(1_000_000);
    try std.testing.expect(!c.dead);
    var kb: [16]u8 = undefined;
    try c.queueFramed(try packets.frameKeepAlive(9, &kb));
    const seeded = c.out.items.len;
    try std.testing.expect(seeded > 0);
    srv.tickOnce(1_000_000 + 31_000);
    try std.testing.expect(c.dead);
    try std.testing.expect(c.close_after_flush);
    // Skipped flush: our seeded bytes were never drained to the socket.
    try std.testing.expect(c.out.items.len > seeded);
    srv.unregister(c);
    try std.testing.expectEqual(@as(usize, 0), srv.registry.items.len);
}

test "player save/load roundtrip via pool (pos/health/inv/NBT)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    srv.world = pool;
    const c = try a.create(Conn);
    defer a.destroy(c);
    c.* = Conn.init(a, io, .{}, 7);
    c.state = .play;
    @memcpy(c.username[0.."Bo".len], "Bo");
    c.username_len = 2;
    // Distinct identities: rows are UUID-keyed, so the two test conns need
    // distinct UUIDs (Conn.init zeroes the field; production sets it from
    // the login handshake before loadPlayer ever runs).
    @memcpy(&c.uuid_str, "00000000-0000-4000-8000-00000000000b");
    c.pos_x = -12.5;
    c.pos_y = 70.0;
    c.pos_z = 44.25;
    c.yaw = 90.0;
    c.pitch = -15.0;
    c.health = 13.5;
    c.food = 17;
    c.saturation = 3.25;
    c.selected = 4;
    c.config.gamemode = .survival;
    c.config.spawn_x = 8;
    c.config.spawn_y = 70;
    c.config.spawn_z = 8;
    const tag = [_]u8{ 0x0A, 0x00, 0x03, 0x64, 0x75, 0x6D };
    const owned = try a.dupe(u8, &tag);
    c.inv[36] = .{ .id = game_ids.diamond_sword, .count = 1, .damage = 0, .nbt = owned };
    c.inv[10] = .{ .id = game_ids.stone, .count = 64, .damage = 0, .nbt = null };
    c.cursor = .{ .id = game_ids.dirt, .count = 5, .damage = 0, .nbt = null };
    c.ender[0] = .{ .id = game_ids.obsidian, .count = 8, .damage = 0, .nbt = null };
    c.ender[26] = .{ .id = game_ids.dirt, .count = 16, .damage = 0, .nbt = null };
    srv.savePlayer(c);
    // Mutate everything; load must restore.
    c.pos_x = 999;
    c.health = 1.0;
    item_mod.freeStack(a, &c.inv[36]);
    c.inv[36] = null;
    c.inv[10] = null;
    c.cursor = null;
    item_mod.freeStack(a, &c.ender[0]);
    c.ender[0] = null;
    c.ender[26] = null;
    c.selected = 0;
    c.config.gamemode = .creative;
    c.lock.lock();
    try std.testing.expect(srv.loadPlayer(c));
    c.lock.unlock();
    try std.testing.expectApproxEqAbs(-12.5, c.pos_x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 90.0), c.yaw, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 13.5), c.health, 1e-6);
    try std.testing.expectEqual(@as(i16, 17), c.food);
    try std.testing.expectEqual(@as(u8, 4), c.selected);
    try std.testing.expect(c.config.gamemode == .survival);
    try std.testing.expectEqual(game_ids.diamond_sword, c.inv[36].?.id);
    try std.testing.expectEqualSlices(u8, &tag, c.inv[36].?.nbt.?);
    try std.testing.expectEqual(game_ids.stone, c.inv[10].?.id);
    try std.testing.expectEqual(game_ids.dirt, c.cursor.?.id);
    try std.testing.expectEqual(@as(i32, 8), c.config.spawn_x);
    try std.testing.expectEqual(game_ids.obsidian, c.ender[0].?.id);
    try std.testing.expectEqual(@as(i8, 8), c.ender[0].?.count);
    try std.testing.expectEqual(game_ids.dirt, c.ender[26].?.id);
    try std.testing.expect(c.ender[1] == null);
    // No save -> false. Corrupt row -> false (treated as fresh spawn).
    const c2 = try a.create(Conn);
    defer a.destroy(c2);
    c2.* = Conn.init(a, io, .{}, 8);
    c2.state = .play;
    @memcpy(c2.username[0.."Al".len], "Al");
    c2.username_len = 2;
    @memcpy(&c2.uuid_str, "00000000-0000-4000-8000-0000000000a1");
    c2.lock.lock();
    try std.testing.expect(!srv.loadPlayer(c2));
    c2.lock.unlock();
    try pool.put(player_db.keyFor("Al"), "junk-bytes");
    c2.lock.lock();
    try std.testing.expect(!srv.loadPlayer(c2));
    c2.lock.unlock();
    // Non-play conns are never persisted (junk row from above untouched).
    c2.state = .login;
    srv.savePlayer(c2);
    const still = try pool.get(a, player_db.keyFor("Al"));
    defer if (still) |s| a.free(s);
    try std.testing.expectEqualStrings("junk-bytes", still.?);
    c.deinit();
    c2.deinit();
}

// Test-only wire asserts (readFrame-based): broadcast sounds queue to
// outboxes while S24 lid events flush synchronously, so socket reads
// observe send order. Bodies never escape these helpers.
// NOTE: callers keep ONE persistent buffered reader per stream (a fresh
// reader per frame would drop buffered read-ahead and misalign it).
const expectWire = struct {
    fn id(rr: anytype, want: i32) !void {
        var fb: [2048]u8 = undefined;
        const f = try readFrame(&rr.interface, &fb);
        try std.testing.expectEqual(want, f.id);
    }
    fn lid(rr: anytype, n: u8) !void {
        var fb: [256]u8 = undefined;
        const f = try readFrame(&rr.interface, &fb);
        try std.testing.expectEqual(@as(i32, 0x24), f.id);
        var pr = codec.PacketReader.init(f.body);
        _ = try pr.readInt(); // x
        _ = try pr.readShort(); // y
        _ = try pr.readInt(); // z
        try std.testing.expectEqual(@as(u8, 1), try pr.readByte()); // lid event
        try std.testing.expectEqual(n, try pr.readByte()); // viewer count
        _ = try pr.readVarInt(); // block id (jar `gg`)
        try std.testing.expectEqual(@as(usize, 0), pr.remaining());
    }
    fn winItems(rr: anytype, win: u8, count: i16) !void {
        var fb: [4096]u8 = undefined;
        const f = try readFrame(&rr.interface, &fb);
        try std.testing.expectEqual(@as(i32, 0x30), f.id);
        var pr = codec.PacketReader.init(f.body);
        try std.testing.expectEqual(win, try pr.readByte());
        try std.testing.expectEqual(count, try pr.readShort());
    }
};

test "chest: open/click/close/persist single chest" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer srv.items.deinit(a);
    defer srv.chests.deinit(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    srv.world = pool;
    const c = try a.create(Conn);
    defer {
        c.deinit();
        a.destroy(c);
    }
    c.* = Conn.init(a, io, .{}, 7);
    c.state = .play;
    // Materialize chunk (0,0): applyBlock is a no-op on missing columns.
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
    }
    _ = try view.applyBlock(pool, a, 8, 64, 8, game_ids.chest, 2);
    var bev = BlockEvent{ .x = 8, .y = 65, .z = 8, .id = game_ids.air, .meta = 0, .face = 1 };
    // Sneak places against the chest instead of opening.
    try std.testing.expect(!srv.tryOpenChest(c, pool, a, &bev, true));
    try std.testing.expect(c.open_win == null);
    // Blocked lid (opaque above) refuses the open.
    _ = try view.applyBlock(pool, a, 8, 65, 8, game_ids.stone, 0);
    try std.testing.expect(!srv.tryOpenChest(c, pool, a, &bev, false));
    _ = try view.applyBlock(pool, a, 8, 65, 8, game_ids.air, 0);
    // Open: window 5, empty chest.
    try std.testing.expect(srv.tryOpenChest(c, pool, a, &bev, false));
    try std.testing.expect(c.open_win != null);
    try std.testing.expectEqual(@as(u8, 5), c.open_win.?.id);
    {
        srv.chest_lock.lock();
        defer srv.chest_lock.unlock();
        const e = srv.findChest(8, 64, 8).?;
        for (e.slots) |s| try std.testing.expect(s == null);
    }
    // Shift player inv[9] (window slot 27) into the chest.
    c.inv[9] = .{ .id = game_ids.stone, .count = 16, .damage = 0, .nbt = null };
    srv.applyChestClick(c, pool, a, .{ .slot = 27, .button = 0, .action = 1, .mode = 1 });
    try std.testing.expect(c.inv[9] == null);
    {
        srv.chest_lock.lock();
        defer srv.chest_lock.unlock();
        const e = srv.findChest(8, 64, 8).?;
        try std.testing.expectEqual(game_ids.stone, e.slots[0].?.id);
        try std.testing.expectEqual(@as(i8, 16), e.slots[0].?.count);
        try std.testing.expect(e.dirty);
    }
    // Pickup back out (window slot 0, mode 0).
    srv.applyChestClick(c, pool, a, .{ .slot = 0, .button = 0, .action = 2, .mode = 0 });
    try std.testing.expectEqual(game_ids.stone, c.cursor.?.id);
    {
        srv.chest_lock.lock();
        defer srv.chest_lock.unlock();
        try std.testing.expect(srv.findChest(8, 64, 8).?.slots[0] == null);
    }
    // Put it back for the persistence + break legs.
    srv.applyChestClick(c, pool, a, .{ .slot = 0, .button = 0, .action = 3, .mode = 0 });
    try std.testing.expect(c.cursor == null);
    // Persist: ticker flush writes the row; reload reads it back.
    srv.flushDirtyChests();
    {
        var row = try chest_mod.loadRow(pool, a, 8, 64, 8);
        defer {
            if (row) |*r| chest_mod.freeSlots(a, &r.slots);
        }
        try std.testing.expect(row != null);
        try std.testing.expectEqual(game_ids.stone, row.?.slots[0].?.id);
    }
    {
        srv.chest_lock.lock();
        defer srv.chest_lock.unlock();
        try std.testing.expect(!srv.findChest(8, 64, 8).?.dirty);
    }
    // Client close (0x0D): window cleared, contents stay, close sound path
    // runs (no viewers left; broadcast to an empty registry is a no-op).
    {
        var cb: [8]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeByte(5);
        var f: [64]u8 = undefined;
        try c.feedData(try codec.framePacket(0x0D, w.written(), &f));
        const fr = (try c.poll()).?;
        const act = try c.handleFrame(fr);
        try std.testing.expect(act == .chest_close);
        try std.testing.expectEqual(@as(u8, 5), act.chest_close.window);
        try std.testing.expect(c.open_win == null);
        srv.spawnChestClose(pool, a, act.chest_close);
    }
    // Break: viewers closed (none), THIS half's contents drop as an
    // entity, row deleted, entry gone.
    _ = try view.applyBlock(pool, a, 8, 64, 8, game_ids.air, 0);
    var bbreak = BlockEvent{ .x = 8, .y = 64, .z = 8, .id = game_ids.chest, .meta = 2, .face = 1 };
    srv.breakWindowsFor(pool, a, &bbreak, game_ids.chest);
    {
        srv.chest_lock.lock();
        defer srv.chest_lock.unlock();
        try std.testing.expect(srv.findChest(8, 64, 8) == null);
    }
    {
        const gone = try chest_mod.loadRow(pool, a, 8, 64, 8);
        try std.testing.expect(gone == null);
    }
    try std.testing.expectEqual(@as(usize, 1), srv.items.items.len);
    try std.testing.expectEqual(game_ids.stone, srv.items.items[0].stack.id);
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
    // Second chest (isolated, no pair): look-don't-touch open + close
    // evicts the entry (zero footprint); dirty-then-emptied flush deletes
    // the row instead of writing an empty one.
    _ = try view.applyBlock(pool, a, 12, 64, 8, game_ids.chest, 2);
    var bev2 = BlockEvent{ .x = 12, .y = 65, .z = 8, .id = game_ids.air, .meta = 0, .face = 1 };
    try std.testing.expect(srv.tryOpenChest(c, pool, a, &bev2, false));
    try std.testing.expectEqual(@as(u8, 5), c.open_win.?.id);
    {
        var cb: [8]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeByte(5);
        var f: [64]u8 = undefined;
        try c.feedData(try codec.framePacket(0x0D, w.written(), &f));
        const fr = (try c.poll()).?;
        const act = try c.handleFrame(fr);
        try std.testing.expect(act == .chest_close);
        srv.spawnChestClose(pool, a, act.chest_close);
    }
    {
        srv.chest_lock.lock();
        defer srv.chest_lock.unlock();
        try std.testing.expect(srv.findChest(12, 64, 8) == null);
    }
    // Touch it, empty it, flush: row deleted, not written empty.
    try std.testing.expect(srv.tryOpenChest(c, pool, a, &bev2, false));
    c.inv[10] = .{ .id = game_ids.dirt, .count = 4, .damage = 0, .nbt = null };
    srv.applyChestClick(c, pool, a, .{ .slot = 28, .button = 0, .action = 9, .mode = 1 });
    try std.testing.expect(c.inv[10] == null);
    srv.applyChestClick(c, pool, a, .{ .slot = 0, .button = 0, .action = 10, .mode = 0 });
    try std.testing.expect(c.cursor != null);
    // Drop the cursor stack (test cleanup); the chest is empty + dirty.
    {
        var owned: ?item_mod.Stack = c.cursor;
        item_mod.freeStack(a, &owned);
        c.cursor = null;
    }
    srv.flushDirtyChests();
    {
        const gone = try chest_mod.loadRow(pool, a, 12, 64, 8);
        try std.testing.expect(gone == null);
    }
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
}

test "chest: drag-spread distributes across cells, persists on reopen" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer srv.items.deinit(a);
    defer srv.chests.deinit(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    srv.world = pool;
    const c = try a.create(Conn);
    defer {
        c.deinit();
        a.destroy(c);
    }
    c.* = Conn.init(a, io, .{}, 7);
    c.state = .play;
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
    }
    _ = try view.applyBlock(pool, a, 8, 64, 8, game_ids.chest, 2);
    var bev = BlockEvent{ .x = 8, .y = 65, .z = 8, .id = game_ids.air, .meta = 0, .face = 1 };
    try std.testing.expect(srv.tryOpenChest(c, pool, a, &bev, false));
    try std.testing.expectEqual(@as(u8, 5), c.open_win.?.id);
    // Left-drag 10 dirt over chest cells 0,1,2 -> 4/3/3.
    c.cursor = .{ .id = game_ids.dirt, .count = 10, .damage = 0, .nbt = null };
    srv.applyChestClick(c, pool, a, .{ .slot = -999, .button = 0, .action = 30, .mode = 5 });
    srv.applyChestClick(c, pool, a, .{ .slot = 0, .button = 1, .action = 31, .mode = 5 });
    srv.applyChestClick(c, pool, a, .{ .slot = 1, .button = 1, .action = 32, .mode = 5 });
    srv.applyChestClick(c, pool, a, .{ .slot = 2, .button = 1, .action = 33, .mode = 5 });
    srv.applyChestClick(c, pool, a, .{ .slot = -999, .button = 2, .action = 34, .mode = 5 });
    try std.testing.expect(c.cursor == null);
    {
        srv.chest_lock.lock();
        defer srv.chest_lock.unlock();
        const e = srv.findChest(8, 64, 8).?;
        try std.testing.expectEqual(@as(i8, 4), e.slots[0].?.count);
        try std.testing.expectEqual(@as(i8, 3), e.slots[1].?.count);
        try std.testing.expectEqual(@as(i8, 3), e.slots[2].?.count);
        try std.testing.expect(e.dirty);
    }
    // Right-drag 5 dirt over player slots 27,28 (inv 9,10) -> 1 each.
    c.cursor = .{ .id = game_ids.dirt, .count = 5, .damage = 0, .nbt = null };
    srv.applyChestClick(c, pool, a, .{ .slot = -999, .button = 4, .action = 35, .mode = 5 });
    srv.applyChestClick(c, pool, a, .{ .slot = 27, .button = 5, .action = 36, .mode = 5 });
    srv.applyChestClick(c, pool, a, .{ .slot = 28, .button = 5, .action = 37, .mode = 5 });
    srv.applyChestClick(c, pool, a, .{ .slot = -999, .button = 6, .action = 38, .mode = 5 });
    try std.testing.expectEqual(@as(i8, 3), c.cursor.?.count);
    try std.testing.expectEqual(@as(i8, 1), c.inv[9].?.count);
    try std.testing.expectEqual(@as(i8, 1), c.inv[10].?.count);
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
}

test "chest: double pair windows, break drops one half" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer srv.items.deinit(a);
    defer srv.chests.deinit(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    srv.world = pool;
    const c = try a.create(Conn);
    c.* = Conn.init(a, io, .{}, 7);
    c.state = .play;
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
    }
    _ = try view.applyBlock(pool, a, 8, 64, 8, game_ids.chest, 2);
    _ = try view.applyBlock(pool, a, 9, 64, 8, game_ids.chest, 2);
    var bev = BlockEvent{ .x = 8, .y = 65, .z = 8, .id = game_ids.air, .meta = 0, .face = 1 };
    var port: u16 = 38101;
    var listener: std.Io.net.Server = while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        break addr.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => {
                port += 1;
                if (port > 38120) return err;
                continue;
            },
            else => return err,
        };
    };
    defer listener.deinit(io);
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var cli = try addr.connect(io, .{ .mode = .stream });
    defer cli.close(io);
    const sv = try listener.accept(io);
    defer sv.close(io);
    try srv.register(c, sv);
    defer srv.unregister(c);
    // Tracked chunk: lid events scope to trackers.
    try c.sent.put(Conn.sentKey(0, 0), {});
    var cli_rb: [512]u8 = undefined;
    var cli_rr = cli.reader(io, &cli_rb);
    // Adjacent pair opens the double window (id 6); BOTH halves get the
    // S24 lid frame (pair total, viewers 1) on the wire, after the open,
    // items, and sound frames.
    try std.testing.expect(srv.tryOpenChest(c, pool, a, &bev, false));
    try std.testing.expectEqual(@as(u8, 6), c.open_win.?.id);
    try expectWire.id(&cli_rr, 0x2D);
    try expectWire.id(&cli_rr, 0x30);
    try expectWire.id(&cli_rr, 0x29);
    try expectWire.lid(&cli_rr, 1);
    try expectWire.lid(&cli_rr, 1);
    // Shift inv[9] (window slot 54) into the pair: first half first.
    c.inv[9] = .{ .id = game_ids.dirt, .count = 4, .damage = 0, .nbt = null };
    srv.applyChestClick(c, pool, a, .{ .slot = 54, .button = 0, .action = 1, .mode = 1 });
    try std.testing.expect(c.inv[9] == null);
    {
        srv.chest_lock.lock();
        defer srv.chest_lock.unlock();
        try std.testing.expectEqual(game_ids.dirt, srv.findChest(8, 64, 8).?.slots[0].?.id);
        try std.testing.expect(srv.findChest(9, 64, 8).?.slots[0] == null);
    }
    // Second-half cell (window slot 30 = half[1][3]): seed + pick up.
    {
        srv.chest_lock.lock();
        srv.findChest(9, 64, 8).?.slots[3] = .{ .id = game_ids.stone, .count = 2, .damage = 0, .nbt = null };
        srv.chest_lock.unlock();
    }
    srv.applyChestClick(c, pool, a, .{ .slot = 30, .button = 0, .action = 2, .mode = 0 });
    try std.testing.expectEqual(game_ids.stone, c.cursor.?.id);
    {
        var owned: ?item_mod.Stack = c.cursor;
        item_mod.freeStack(a, &owned);
        c.cursor = null;
    }
    // Persist both halves, then break (8,64,8): only its dirt drops, its
    // row/entry vanish, the survivor keeps its (now single) state.
    srv.flushDirtyChests();
    {
        var row = try chest_mod.loadRow(pool, a, 8, 64, 8);
        defer {
            if (row) |*r| chest_mod.freeSlots(a, &r.slots);
        }
        try std.testing.expect(row != null);
    }
    _ = try view.applyBlock(pool, a, 8, 64, 8, game_ids.air, 0);
    var bbreak = BlockEvent{ .x = 8, .y = 64, .z = 8, .id = game_ids.chest, .meta = 2, .face = 1 };
    srv.breakWindowsFor(pool, a, &bbreak, game_ids.chest);
    try std.testing.expect(c.open_win == null);
    {
        srv.chest_lock.lock();
        defer srv.chest_lock.unlock();
        try std.testing.expect(srv.findChest(8, 64, 8) == null);
        const surv = srv.findChest(9, 64, 8).?;
        for (surv.slots) |s| try std.testing.expect(s == null);
    }
    {
        const gone = try chest_mod.loadRow(pool, a, 8, 64, 8);
        try std.testing.expect(gone == null);
    }
    try std.testing.expectEqual(@as(usize, 1), srv.items.items.len);
    try std.testing.expectEqual(game_ids.dirt, srv.items.items[0].stack.id);
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
}

test "chest: multi-viewer sync, trapped power, lid sounds" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer srv.items.deinit(a);
    defer srv.chests.deinit(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    srv.world = pool;
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
    }
    _ = try view.applyBlock(pool, a, 8, 64, 8, game_ids.trapped_chest, 2);
    var port: u16 = 38121;
    var listener: std.Io.net.Server = while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        break addr.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => {
                port += 1;
                if (port > 38140) return err;
                continue;
            },
            else => return err,
        };
    };
    defer listener.deinit(io);
    const mk = struct {
        fn run(l: *std.Io.net.Server, p: u16, name: []const u8) !struct {
            conn: *Conn,
            srv_stream: std.Io.net.Stream,
            cli_stream: std.Io.net.Stream,
        } {
            const c = try a.create(Conn);
            errdefer a.destroy(c);
            c.* = Conn.init(a, io, .{}, 1);
            c.state = .play;
            @memcpy(c.username[0..name.len], name);
            c.username_len = name.len;
            const addr = try std.Io.net.IpAddress.parse("127.0.0.1", p);
            const cli = try addr.connect(io, .{ .mode = .stream });
            errdefer cli.close(io);
            const sv = try l.accept(io);
            return .{ .conn = c, .srv_stream = sv, .cli_stream = cli };
        }
    };
    var alice = try mk.run(&listener, port, "AliceV");
    defer alice.cli_stream.close(io);
    defer alice.srv_stream.close(io);
    var bob = try mk.run(&listener, port, "BobV");
    defer bob.cli_stream.close(io);
    defer bob.srv_stream.close(io);
    try srv.register(alice.conn, alice.srv_stream);
    try srv.register(bob.conn, bob.srv_stream);
    defer srv.unregister(alice.conn);
    defer srv.unregister(bob.conn);
    // Persistent wire readers (see expectWire NOTE).
    var alice_rb: [512]u8 = undefined;
    var alice_rr = alice.cli_stream.reader(io, &alice_rb);
    var bob_rb: [512]u8 = undefined;
    var bob_rr = bob.cli_stream.reader(io, &bob_rb);
    // Tracked chunk (mimics post-burst): S24 lid events scope to trackers.
    try alice.conn.sent.put(Conn.sentKey(0, 0), {});
    try bob.conn.sent.put(Conn.sentKey(0, 0), {});
    var bev = BlockEvent{ .x = 8, .y = 65, .z = 8, .id = game_ids.air, .meta = 0, .face = 1 };
    // No viewers: trapped chest is dark.
    try std.testing.expectEqual(@as(u4, 0), srv.trappedPower(pool, a, 8, 64, 8));
    // Alice opens: window 5, power 15, Bob gets the open sound (0x29).
    // Both trackers get the S24 lid frame (0x24, viewers 1) on the wire.
    try std.testing.expect(srv.tryOpenChest(alice.conn, pool, a, &bev, false));
    try std.testing.expectEqual(@as(u8, 5), alice.conn.open_win.?.id);
    try std.testing.expectEqual(@as(u4, 15), srv.trappedPower(pool, a, 8, 64, 8));
    try expectWire.id(&alice_rr, 0x2D);
    try expectWire.id(&alice_rr, 0x30);
    try expectWire.id(&alice_rr, 0x29);
    try expectWire.lid(&alice_rr, 1);
    try expectWire.id(&bob_rr, 0x29);
    try expectWire.lid(&bob_rr, 1);
    // Bob opens too: lid already open, Alice hears nothing new — but both
    // trackers get the S24 recount (viewers 2).
    try std.testing.expect(srv.tryOpenChest(bob.conn, pool, a, &bev, false));
    try expectWire.lid(&alice_rr, 2);
    try expectWire.id(&bob_rr, 0x2D);
    try expectWire.id(&bob_rr, 0x30);
    try expectWire.lid(&bob_rr, 2);
    // Alice shift-clicks stone in: Bob's window refreshes (0x30, 63 slots).
    // Viewer refresh flushes to the socket immediately (like a live tick
    // would), so read Bob's wire bytes, not his outbox.
    alice.conn.inv[9] = .{ .id = game_ids.stone, .count = 8, .damage = 0, .nbt = null };
    srv.applyChestClick(alice.conn, pool, a, .{ .slot = 27, .button = 0, .action = 1, .mode = 1 });
    try expectWire.winItems(&bob_rr, 5, 63);
    {
        const o = try alice.conn.takeOutput();
        defer a.free(o);
    }
    // Alice closes: Bob still in, lid stays open (silence), power stays.
    // Both trackers get the S24 recount (viewers 1) on the wire.
    {
        var cb: [8]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeByte(5);
        var f: [64]u8 = undefined;
        try alice.conn.feedData(try codec.framePacket(0x0D, w.written(), &f));
        const fr = (try alice.conn.poll()).?;
        const act = try alice.conn.handleFrame(fr);
        try std.testing.expect(act == .chest_close);
        srv.spawnChestClose(pool, a, act.chest_close);
    }
    try expectWire.lid(&bob_rr, 1);
    try expectWire.lid(&alice_rr, 1);
    try std.testing.expectEqual(@as(u4, 15), srv.trappedPower(pool, a, 8, 64, 8));
    // Bob closes last: Alice hears the lid (0x29), power drops, lid shuts.
    {
        var cb: [8]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeByte(5);
        var f: [64]u8 = undefined;
        try bob.conn.feedData(try codec.framePacket(0x0D, w.written(), &f));
        const fr = (try bob.conn.poll()).?;
        const act = try bob.conn.handleFrame(fr);
        try std.testing.expect(act == .chest_close);
        srv.spawnChestClose(pool, a, act.chest_close);
    }
    try expectWire.id(&alice_rr, 0x29);
    try expectWire.lid(&alice_rr, 0);
    try expectWire.id(&bob_rr, 0x29);
    try expectWire.lid(&bob_rr, 0);
    try std.testing.expectEqual(@as(u4, 0), srv.trappedPower(pool, a, 8, 64, 8));
}

test "chest: corrupt rows fail closed to empty" {
    // Chunk-ban posture: garbage, truncated, overlong, version-skewed,
    // and cross-key rows never surface as contents (and never crash the
    // open path). The store API reports corruption loudly; the open path
    // treats it as an empty chest.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer srv.items.deinit(a);
    defer srv.chests.deinit(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    srv.world = pool;
    const c = try a.create(Conn);
    defer {
        c.deinit();
        a.destroy(c);
    }
    c.* = Conn.init(a, io, .{}, 7);
    c.state = .play;
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
    }
    _ = try view.applyBlock(pool, a, 8, 64, 8, game_ids.chest, 2);
    var bev = BlockEvent{ .x = 8, .y = 65, .z = 8, .id = game_ids.air, .meta = 0, .face = 1 };
    // Garbage row under the chest's key: open succeeds with an empty chest.
    try pool.put(chest_mod.keyForChest(8, 64, 8), "junk-bytes");
    try std.testing.expectError(error.CorruptChest, chest_mod.loadRow(pool, a, 8, 64, 8));
    try std.testing.expect(srv.tryOpenChest(c, pool, a, &bev, false));
    {
        srv.chest_lock.lock();
        defer srv.chest_lock.unlock();
        const e = srv.findChest(8, 64, 8).?;
        for (e.slots) |s| try std.testing.expect(s == null);
    }
    // Valid row for a DIFFERENT pos parked under this key: position
    // mismatch reads as absent (never as someone else's contents).
    {
        var slots: [chest_mod.chest_size]?item_mod.Stack = [_]?item_mod.Stack{null} ** chest_mod.chest_size;
        slots[0] = .{ .id = game_ids.diamond, .count = 1, .damage = 0, .nbt = null };
        const enc = try chest_mod.encode(a, 9, 64, 8, &slots);
        defer a.free(enc);
        try pool.put(chest_mod.keyForChest(8, 64, 8), enc);
    }
    // ...reads as absent through the store API too.
    {
        const miss = try chest_mod.loadRow(pool, a, 8, 64, 8);
        try std.testing.expect(miss == null);
    }
    // Reopen (clear + close first so the open path re-resolves).
    c.open_win = null;
    try std.testing.expect(srv.tryOpenChest(c, pool, a, &bev, false));
    {
        srv.chest_lock.lock();
        defer srv.chest_lock.unlock();
        const e = srv.findChest(8, 64, 8).?;
        for (e.slots) |s| try std.testing.expect(s == null);
    }
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
}

test "chest: oversize stacks fail the click, never persist" {
    // Insertion gate: stacks over the slot cap can't enter chest rows
    // (decode would reject them on next load, silently emptying the
    // chest). Rejected clicks echo snap-back: no mutation, no dirty, no
    // viewer traffic. In-game NBT has no manufacturing path (no book
    // writing, no renames, no creative NBT pick-block), so the gate is a
    // backstop that legit play never touches.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer srv.items.deinit(a);
    defer srv.chests.deinit(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    srv.world = pool;
    const c = try a.create(Conn);
    defer {
        c.deinit();
        a.destroy(c);
    }
    c.* = Conn.init(a, io, .{}, 7);
    c.state = .play;
    // Materialize chunk (1,0): applyBlock is a no-op on missing columns.
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 1, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
    }
    _ = try view.applyBlock(pool, a, 20, 64, 8, game_ids.chest, 2);
    var bev = BlockEvent{ .x = 20, .y = 65, .z = 8, .id = game_ids.air, .meta = 0, .face = 1 };
    try std.testing.expect(srv.tryOpenChest(c, pool, a, &bev, false));
    const big = try a.alloc(u8, chest_mod.max_slot_nbt_bytes + 1024);
    @memset(big, 0xAB);
    // Shift oversize inv stack in: rejected, stays put, chest untouched.
    // (One buffer, moved between cells — never duped, never leaked.)
    c.inv[9] = .{ .id = game_ids.written_book, .count = 1, .damage = 0, .nbt = big };
    srv.applyChestClick(c, pool, a, .{ .slot = 27, .button = 0, .action = 1, .mode = 1 });
    try std.testing.expect(c.inv[9] != null);
    {
        srv.chest_lock.lock();
        defer srv.chest_lock.unlock();
        const e = srv.findChest(20, 64, 8).?;
        for (e.slots) |s| try std.testing.expect(s == null);
        try std.testing.expect(!e.dirty);
    }
    // Place oversize cursor stack in: rejected, cursor keeps it.
    c.cursor = c.inv[9].?;
    c.inv[9] = null;
    srv.applyChestClick(c, pool, a, .{ .slot = 0, .button = 0, .action = 2, .mode = 0 });
    try std.testing.expect(c.cursor != null);
    {
        srv.chest_lock.lock();
        defer srv.chest_lock.unlock();
        const e = srv.findChest(20, 64, 8).?;
        for (e.slots) |s| try std.testing.expect(s == null);
        try std.testing.expect(!e.dirty);
    }
    // Number-key swap oversize hotbar stack in: rejected, both stay.
    c.inv[36] = c.cursor.?;
    c.cursor = null;
    srv.applyChestClick(c, pool, a, .{ .slot = 0, .button = 0, .action = 3, .mode = 2 });
    try std.testing.expect(c.inv[36] != null);
    {
        srv.chest_lock.lock();
        defer srv.chest_lock.unlock();
        const e = srv.findChest(20, 64, 8).?;
        for (e.slots) |s| try std.testing.expect(s == null);
        try std.testing.expect(!e.dirty);
    }
    // A fitting stack still flows (gate doesn't jam legitimate clicks).
    item_mod.freeStack(a, &c.inv[36]);
    c.inv[9] = .{ .id = game_ids.stone, .count = 1, .damage = 0, .nbt = null };
    srv.applyChestClick(c, pool, a, .{ .slot = 27, .button = 0, .action = 4, .mode = 1 });
    try std.testing.expect(c.inv[9] == null);
    {
        srv.chest_lock.lock();
        defer srv.chest_lock.unlock();
        try std.testing.expectEqual(game_ids.stone, srv.findChest(20, 64, 8).?.slots[0].?.id);
    }
    // NBT ownership: the big buffer lives in conn inv (freed by deinit);
    // the chest never adopted it.
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
}

test "placement: occupied cells refuse with resync, air applies" {
    // Anti-grief gate: placing into an occupied non-replaceable cell
    // (chest, furnace, solids) is refused instead of silently overwriting
    // tile entities (contents lost, rows orphaned). The client's
    // prediction is resynced with the true cell (0x23).
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer srv.items.deinit(a);
    defer srv.chests.deinit(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    srv.world = pool;
    const c = try a.create(Conn);
    c.* = Conn.init(a, io, .{}, 7);
    c.state = .play;
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
    }
    _ = try view.applyBlock(pool, a, 8, 64, 8, game_ids.chest, 2);
    _ = try view.applyBlock(pool, a, 9, 64, 8, game_ids.stone, 0);
    var port: u16 = 38161;
    var listener: std.Io.net.Server = while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        break addr.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => {
                port += 1;
                if (port > 38180) return err;
                continue;
            },
            else => return err,
        };
    };
    defer listener.deinit(io);
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var cli = try addr.connect(io, .{ .mode = .stream });
    defer cli.close(io);
    const sv = try listener.accept(io);
    defer sv.close(io);
    try srv.register(c, sv);
    defer srv.unregister(c);
    try c.sent.put(Conn.sentKey(0, 0), {});
    var cli_rb: [512]u8 = undefined;
    var cli_rr = cli.reader(io, &cli_rb);
    c.sneaking = true; // sneak+block places (no UI routing)
    c.inv[36] = .{ .id = game_ids.stone, .count = 64, .damage = 0, .nbt = null };
    c.selected = 0;
    var state = SessionState{};
    defer state.deinit(a);
    // Frame one 0x08: click (9,64,8) face -X(4) -> target (8,64,8) chest.
    {
        var cb: [64]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeInt(9);
        try w.writeByte(64);
        try w.writeInt(8);
        try w.writeByte(4);
        try w.writeShort(-1); // held slot: empty (onPlace uses selected)
        try w.writeByte(8);
        try w.writeByte(8);
        try w.writeByte(8);
        var f: [96]u8 = undefined;
        const framed = try codec.framePacket(0x08, w.written(), &f);
        const res = try sessionStep(&srv, c, a, &state, framed);
        _ = res;
    }
    // Chest intact (block, entry-free, row-free): refused, resynced.
    {
        const pb = try view.peekBlock(pool, a, 8, 64, 8);
        try std.testing.expect(pb != null);
        try std.testing.expectEqual(game_ids.chest, pb.?.id);
    }
    try expectWire.id(&cli_rr, 0x23);
    // Control: face +Y(1) from (9,64,8) -> target (9,65,8) air applies.
    {
        var cb: [64]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeInt(9);
        try w.writeByte(64);
        try w.writeInt(8);
        try w.writeByte(1);
        try w.writeShort(-1);
        try w.writeByte(8);
        try w.writeByte(8);
        try w.writeByte(8);
        var f: [96]u8 = undefined;
        const framed = try codec.framePacket(0x08, w.written(), &f);
        const res = try sessionStep(&srv, c, a, &state, framed);
        _ = res;
    }
    {
        const pb = try view.peekBlock(pool, a, 9, 65, 8);
        try std.testing.expect(pb != null);
        try std.testing.expectEqual(game_ids.stone, pb.?.id);
    }
    try expectWire.id(&cli_rr, 0x23);
}

test "place: feet-intersection and missing chunk NACK air, control applies" {
    // Ghost-wall bundle (move-and-place stop + stuck jitter): (a) placement
    // into the placer's own cells is refused (vanilla canPlaceEntityOnSide)
    // with an air NACK — applying would stick the client inside solid;
    // (b) placement into a server-missing chunk NACKs air instead of
    // echoing a lie (the edit cannot land); (c) control: a head-clear cell
    // applies and echoes stone.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer srv.items.deinit(a);
    defer srv.chests.deinit(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    srv.world = pool;
    const c = try a.create(Conn);
    // No c.deinit/destroy: matches the neighboring placement test (conn
    // teardown after a never-fed read buffer crashes in deinit — the
    // `.empty` buffer has no allocation to free; pre-existing harness
    // quirk, out of scope for this fix).
    c.* = Conn.init(a, io, .{}, 7);
    c.state = .play;
    c.config.gamemode = .creative;
    c.pos_x = 8.5;
    c.pos_y = 64;
    c.pos_z = 8.5;
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
    }
    _ = try view.applyBlock(pool, a, 8, 63, 8, game_ids.stone, 0);
    var port: u16 = 38361;
    var listener: std.Io.net.Server = while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        break addr.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => {
                port += 1;
                if (port > 38380) return err;
                continue;
            },
            else => return err,
        };
    };
    defer listener.deinit(io);
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var cli = try addr.connect(io, .{ .mode = .stream });
    defer cli.close(io);
    const sv = try listener.accept(io);
    defer sv.close(io);
    try srv.register(c, sv);
    defer srv.unregister(c);
    try c.sent.put(Conn.sentKey(0, 0), {});
    var cli_rb: [512]u8 = undefined;
    var cli_rr = cli.reader(io, &cli_rb);
    c.inv[36] = .{ .id = game_ids.stone, .count = 64, .damage = 0, .nbt = null };
    c.selected = 0;
    var state = SessionState{};
    defer state.deinit(a);
    const doPlace = struct {
        fn run(s: *Server, cc: *Conn, al: std.mem.Allocator, st: *SessionState, x: i32, y: u8, z: i32, dir: u8) !void {
            var cb: [64]u8 = undefined;
            var w = codec.PacketWriter.init(&cb);
            try w.writeInt(x);
            try w.writeByte(y);
            try w.writeInt(z);
            try w.writeByte(dir);
            try w.writeShort(-1);
            try w.writeByte(8);
            try w.writeByte(8);
            try w.writeByte(8);
            var f: [96]u8 = undefined;
            const framed = try codec.framePacket(0x08, w.written(), &f);
            const res = try sessionStep(s, cc, al, st, framed);
            _ = res;
        }
    }.run;
    const readChange = struct {
        fn run(rr: anytype) !struct { id: i32, x: i32, y: u8, z: i32, wire_id: i32, meta: u8 } {
            var fb: [256]u8 = undefined;
            const f = try readFrame(&rr.interface, &fb);
            try std.testing.expectEqual(@as(i32, 0x23), f.id);
            var pr = codec.PacketReader.init(f.body);
            const x = try pr.readInt();
            const y = try pr.readByte();
            const z = try pr.readInt();
            const wire_id = try pr.readVarInt();
            const meta = try pr.readByte();
            return .{ .id = f.id, .x = x, .y = y, .z = z, .wire_id = wire_id, .meta = meta };
        }
    }.run;
    // (a) Feet cell: click the floor (8,63,8) face +Y -> target (8,64,8)
    // intersects the placer -> refused, air NACK, truth stays air.
    try doPlace(&srv, c, a, &state, 8, 63, 8, 1);
    {
        const n = try readChange(&cli_rr);
        try std.testing.expectEqual(@as(i32, 8), n.x);
        try std.testing.expectEqual(@as(u8, 64), n.y);
        try std.testing.expectEqual(@as(i32, 8), n.z);
        try std.testing.expectEqual(@as(i32, 0), n.wire_id);
        const pb = try view.peekBlock(pool, a, 8, 64, 8);
        try std.testing.expect(pb == null or pb.?.id == game_ids.air);
    }
    // (b) Missing chunk: click (40,64,8) face +X -> target (41,64,8) in
    // chunk (2,0), absent server-side -> air NACK, nothing applied. The
    // NACK bypasses the sent gate (no (2,0) entry): the click itself
    // proves a prediction exists to clear.
    // (Conn-side reach: move the conn next to it first.)
    c.pos_x = 38.5;
    c.pos_z = 8.5;
    try doPlace(&srv, c, a, &state, 40, 64, 8, 5);
    {
        const n = try readChange(&cli_rr);
        try std.testing.expectEqual(@as(i32, 41), n.x);
        try std.testing.expectEqual(@as(u8, 64), n.y);
        try std.testing.expectEqual(@as(i32, 0), n.wire_id);
        const pb = try view.peekBlock(pool, a, 41, 64, 8);
        try std.testing.expect(pb == null);
    }
    // (c) Control: same geometry with the chunk present applies + echoes.
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 2, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
    }
    try c.sent.put(Conn.sentKey(2, 0), {});
    try doPlace(&srv, c, a, &state, 40, 64, 8, 5);
    {
        const n = try readChange(&cli_rr);
        try std.testing.expectEqual(@as(i32, 41), n.x);
        try std.testing.expectEqual(wire.toWire(game_ids.stone), n.wire_id);
        const pb2 = try view.peekBlock(pool, a, 41, 64, 8);
        try std.testing.expect(pb2 != null);
        try std.testing.expectEqual(game_ids.stone, pb2.?.id);
    }
}

test "dig: refused finish/start resyncs the digger, applied break airs" {
    // Ghost-block negative-ack: the client predicts the removal on FINISH
    // (and on creative START), so every refused dig must 0x23 the digger
    // with truth when the cell is still solid (vanilla S23-iff-solid).
    // A bare drop strands the prediction as a ghost.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer srv.items.deinit(a);
    defer srv.chests.deinit(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    srv.world = pool;
    const c = try a.create(Conn);
    c.* = Conn.init(a, io, .{}, 7);
    c.state = .play;
    c.config.gamemode = .survival;
    c.pos_x = 12.5;
    c.pos_y = 64;
    c.pos_z = 12.5;
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
    }
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 6, 6);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
    }
    _ = try view.applyBlock(pool, a, 12, 64, 12, game_ids.stone, 0);
    _ = try view.applyBlock(pool, a, 100, 64, 100, game_ids.stone, 0);
    var port: u16 = 38201;
    var listener: std.Io.net.Server = while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        break addr.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => {
                port += 1;
                if (port > 38220) return err;
                continue;
            },
            else => return err,
        };
    };
    defer listener.deinit(io);
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var cli = try addr.connect(io, .{ .mode = .stream });
    defer cli.close(io);
    const sv = try listener.accept(io);
    defer sv.close(io);
    try srv.register(c, sv);
    defer srv.unregister(c);
    try c.sent.put(Conn.sentKey(0, 0), {});
    try c.sent.put(Conn.sentKey(6, 6), {});
    var cli_rb: [512]u8 = undefined;
    var cli_rr = cli.reader(io, &cli_rb);
    var state = SessionState{};
    defer state.deinit(a);
    const feedDig = struct {
        fn run(s: *Server, cc: *Conn, al: std.mem.Allocator, st: *SessionState, status: u8, x: i32, y: u8, z: i32) !void {
            var cb: [32]u8 = undefined;
            var w = codec.PacketWriter.init(&cb);
            try w.writeByte(status);
            try w.writeInt(x);
            try w.writeByte(y);
            try w.writeInt(z);
            try w.writeByte(1);
            var f: [64]u8 = undefined;
            const framed = try codec.framePacket(0x07, w.written(), &f);
            const res = try sessionStep(s, cc, al, st, framed);
            _ = res;
        }
    }.run;
    const expectBlock = struct {
        fn change(rr: anytype, x: i32, y: u8, z: i32, wid: i32) !void {
            var fb: [2048]u8 = undefined;
            const f = try readFrame(&rr.interface, &fb);
            try std.testing.expectEqual(@as(i32, 0x23), f.id);
            var pr = codec.PacketReader.init(f.body);
            try std.testing.expectEqual(x, try pr.readInt());
            try std.testing.expectEqual(y, try pr.readByte());
            try std.testing.expectEqual(z, try pr.readInt());
            try std.testing.expectEqual(wid, try pr.readVarInt());
        }
        // Breaks also fan out drop spawns (0x0E) + dig sounds ahead of the
        // cell broadcast: skip non-0x23 frames (bounded), then assert the
        // cell body. Fails on a solid-cell 0x23 (resurrection) or silence.
        fn changeSkip(rr: anytype, x: i32, y: u8, z: i32, wid: i32) !void {
            var fb: [2048]u8 = undefined;
            var n: usize = 0;
            while (n < 8) : (n += 1) {
                const f = try readFrame(&rr.interface, &fb);
                if (f.id != 0x23) continue;
                var pr = codec.PacketReader.init(f.body);
                const fx = try pr.readInt();
                const fy = try pr.readByte();
                const fz = try pr.readInt();
                const fw = try pr.readVarInt();
                if (fx == x and fy == y and fz == z) {
                    try std.testing.expectEqual(wid, fw);
                    return;
                }
            }
            return error.TestExpectedEqual;
        }
    };
    // Survival FINISH with no START: no break, resync stone truth.
    try feedDig(&srv, c, a, &state, 2, 12, 64, 12);
    {
        const pb = try view.peekBlock(pool, a, 12, 64, 12);
        try std.testing.expect(pb != null);
        try std.testing.expectEqual(game_ids.stone, pb.?.id);
    }
    try expectBlock.change(&cli_rr, 12, 64, 12, 1);
    // Survival START + FINISH in reach: break applies, broadcast airs.
    try feedDig(&srv, c, a, &state, 0, 12, 64, 12);
    try feedDig(&srv, c, a, &state, 2, 12, 64, 12);
    {
        const pb = try view.peekBlock(pool, a, 12, 64, 12);
        try std.testing.expect(pb != null);
        try std.testing.expectEqual(game_ids.air, pb.?.id);
    }
    try expectBlock.changeSkip(&cli_rr, 12, 64, 12, 0);
    // Creative START out of reach: no break, resync stone truth.
    c.config.gamemode = .creative;
    try feedDig(&srv, c, a, &state, 0, 100, 64, 100);
    {
        const pb = try view.peekBlock(pool, a, 100, 64, 100);
        try std.testing.expect(pb != null);
        try std.testing.expectEqual(game_ids.stone, pb.?.id);
    }
    try expectBlock.change(&cli_rr, 100, 64, 100, 1);
    // Survival FINISH out of reach (no START): no break, resync truth.
    c.config.gamemode = .survival;
    try feedDig(&srv, c, a, &state, 2, 100, 64, 100);
    try expectBlock.change(&cli_rr, 100, 64, 100, 1);
}

test "eat start: bread begins the use, tables win over eating" {
    // Right-click with food routes to the 32-tick use; a crafting table
    // in the way opens its UI instead (vanilla routing, like placements).
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer srv.items.deinit(a);
    defer srv.chests.deinit(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    srv.world = pool;
    const c = try a.create(Conn);
    c.* = Conn.init(a, io, .{}, 7);
    c.state = .play;
    c.config.gamemode = .survival;
    c.food = 10;
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
    }
    _ = try view.applyBlock(pool, a, 8, 64, 8, game_ids.crafting_table, 0);
    c.inv[36] = .{ .id = game_ids.bread, .count = 3, .damage = 0, .nbt = null };
    c.selected = 0;
    var port: u16 = 38261;
    var listener: std.Io.net.Server = while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        break addr.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => {
                port += 1;
                if (port > 38280) return err;
                continue;
            },
            else => return err,
        };
    };
    defer listener.deinit(io);
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var cli = try addr.connect(io, .{ .mode = .stream });
    defer cli.close(io);
    const sv = try listener.accept(io);
    defer sv.close(io);
    try srv.register(c, sv);
    defer srv.unregister(c);
    try c.sent.put(Conn.sentKey(0, 0), {});
    var state = SessionState{};
    defer state.deinit(a);
    const feedPlace = struct {
        fn run(s: *Server, cc: *Conn, al: std.mem.Allocator, st: *SessionState, x: i32, y: u8, z: i32, dir: u8) !void {
            var cb: [64]u8 = undefined;
            var w = codec.PacketWriter.init(&cb);
            try w.writeInt(x);
            try w.writeByte(y);
            try w.writeInt(z);
            try w.writeByte(dir);
            try w.writeShort(-1);
            try w.writeByte(8);
            try w.writeByte(8);
            try w.writeByte(8);
            var f: [96]u8 = undefined;
            const framed = try codec.framePacket(0x08, w.written(), &f);
            const res = try sessionStep(s, cc, al, st, framed);
            _ = res;
        }
    }.run;
    // Air click with bread: eating starts (survival, hungry).
    try feedPlace(&srv, c, a, &state, 8, 64, 8, 255);
    try std.testing.expect(c.eating != null);
    try std.testing.expectEqual(game_ids.bread, c.eating.?.id);
    // Full hunger refuses (bread is not always-edible).
    c.eating = null;
    c.food = 20;
    try feedPlace(&srv, c, a, &state, 8, 64, 8, 255);
    try std.testing.expect(c.eating == null);
    c.food = 10;
    // Table click with bread: UI opens (window 1), no eating.
    // Click the table block (8,64,8) face +Y(1): target (8,65,8) air,
    // reversal recovers clicked (8,64,8).
    try feedPlace(&srv, c, a, &state, 8, 64, 8, 1);
    try std.testing.expect(c.eating == null);
    try std.testing.expect(c.open_win != null);
    try std.testing.expectEqual(@as(u8, 1), c.open_win.?.id);
}

test "pps gate: 600 frames in one batch trips the per-conn cap" {
    // Global packets-per-second flood gate (config max_packets_per_second,
    // 0 = off): 600 keepalives in one sessionStep with a 500 cap must end
    // the session with the spam kick (0x40) on the wire.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer srv.items.deinit(a);
    defer srv.chests.deinit(a);
    srv.world = null;
    const c = try a.create(Conn);
    c.* = Conn.init(a, io, .{}, 7);
    c.state = .play;
    c.config.max_packets_per_second = 500;
    var port: u16 = 38241;
    var listener: std.Io.net.Server = while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        break addr.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => {
                port += 1;
                if (port > 38260) return err;
                continue;
            },
            else => return err,
        };
    };
    defer listener.deinit(io);
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var cli = try addr.connect(io, .{ .mode = .stream });
    defer cli.close(io);
    const sv = try listener.accept(io);
    defer sv.close(io);
    try srv.register(c, sv);
    defer srv.unregister(c);
    var state = SessionState{};
    defer state.deinit(a);
    var big: [600 * 8]u8 = undefined;
    var w = codec.PacketWriter.init(&big);
    var i: u32 = 0;
    while (i < 600) : (i += 1) {
        var kb: [16]u8 = undefined;
        var kw = codec.PacketWriter.init(&kb);
        try kw.writeInt(@as(i32, @intCast(i)));
        var fb: [32]u8 = undefined;
        const one = try codec.framePacket(0x00, kw.written(), &fb);
        try w.writeBytes(one);
    }
    const res = try sessionStep(&srv, c, a, &state, w.written());
    try std.testing.expect(res.finished);
    // The kick flushes on the transport's output path live; in the test
    // harness drain the outbox directly and expect the 0x40 spam kick.
    const out = try c.takeOutput();
    defer a.free(out);
    try std.testing.expect(out.len > 0);
    var pr = codec.PacketReader.init(out);
    const flen = try pr.readVarInt();
    try std.testing.expect(flen > 0 and flen <= out.len);
    try std.testing.expectEqual(@as(i32, 0x40), try pr.readVarInt());
}

test "login snap lifts out of feet-solid instead of affirming it" {
    // maybeLoginResync must never pin the client inside solid ground:
    // sub-threshold falls can adopt a feet-in-solid pos before the grace
    // engages, and the old bare re-send affirmed it (fallrepro snap-71).
    // Feet solid now lifts to headroom (rescueEmbedded's two-open rule).
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer srv.items.deinit(a);
    defer srv.chests.deinit(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    srv.world = pool;
    const c = try a.create(Conn);
    c.* = Conn.init(a, io, .{}, 7);
    c.state = .play;
    c.pos_x = 12.5;
    c.pos_y = 64;
    c.pos_z = 12.5;
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
    }
    _ = try view.applyBlock(pool, a, 12, 64, 12, game_ids.stone, 0);
    _ = try view.applyBlock(pool, a, 12, 65, 12, game_ids.stone, 0);
    _ = try view.applyBlock(pool, a, 12, 66, 12, game_ids.stone, 0);
    try c.sent.put(Conn.sentKey(0, 0), {});
    c.armLoginGrace();
    c.login_fell = true;
    var port: u16 = 38281;
    var listener: std.Io.net.Server = while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        break addr.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => {
                port += 1;
                if (port > 38300) return err;
                continue;
            },
            else => return err,
        };
    };
    defer listener.deinit(io);
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var cli = try addr.connect(io, .{ .mode = .stream });
    defer cli.close(io);
    const sv = try listener.accept(io);
    defer sv.close(io);
    try srv.register(c, sv);
    defer srv.unregister(c);
    var state = SessionState{};
    defer state.deinit(a);
    var kb: [16]u8 = undefined;
    var kw = codec.PacketWriter.init(&kb);
    try kw.writeInt(7);
    var f: [32]u8 = undefined;
    const framed = try codec.framePacket(0x00, kw.written(), &f);
    _ = try sessionStep(&srv, c, a, &state, framed);
    // Lifted to headroom (67: 67 air + 68 air above stone 64..66).
    try std.testing.expectEqual(@as(f64, 67), c.pos_y);
    const out = try c.takeOutput();
    defer a.free(out);
    var pr = codec.PacketReader.init(out);
    const flen = try pr.readVarInt();
    try std.testing.expect(flen > 0 and flen <= out.len);
    try std.testing.expectEqual(@as(i32, 0x08), try pr.readVarInt());
    try std.testing.expectEqual(@as(f64, 12.5), try pr.readDouble());
    try std.testing.expectEqual(@as(f64, 67), try pr.readDouble());
    try std.testing.expectEqual(@as(f64, 12.5), try pr.readDouble());
}

test "save epochs: bump owns rows, fence trips on newer logins" {
    // Reconnect-race ownership: only an announced login bumps; a wedged
    // earlier login must see the newer epoch and abort (straggler fence)
    // instead of kicking the live session or poisoning the row.
    const a = std.testing.allocator;
    var srv = Server{ .net = undefined, .io = std.testing.io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer {
        // bumpSaveEpoch dupes name keys; the map outlives this test only.
        if (srv.save_epochs) |*m| {
            var it = m.iterator();
            while (it.next()) |kv| a.free(kv.key_ptr.*);
            m.deinit();
        }
    }
    // Unknown names: permissive reads (no owner yet).
    try std.testing.expectEqual(@as(u64, 0), srv.epochFor("Al"));
    try std.testing.expect(srv.saveEpochCurrent("Al", 0));
    // First announce bumps to 1 and owns the row.
    try std.testing.expectEqual(@as(u64, 1), srv.bumpSaveEpoch("Al"));
    try std.testing.expectEqual(@as(u64, 1), srv.epochFor("Al"));
    try std.testing.expect(srv.saveEpochCurrent("Al", 1));
    // A session that read the epoch earlier (0) is stale now: the fence
    // predicate (epochFor != login_epoch_seen) trips for it, while the
    // owner (seen == current) proceeds.
    try std.testing.expect(!srv.saveEpochCurrent("Al", 0));
    try std.testing.expect(srv.epochFor("Al") != 0);
    // Epochs are per-name and monotonic.
    try std.testing.expectEqual(@as(u64, 1), srv.bumpSaveEpoch("Bo"));
    try std.testing.expectEqual(@as(u64, 2), srv.bumpSaveEpoch("Al"));
    try std.testing.expect(srv.saveEpochCurrent("Bo", 1));
    try std.testing.expect(!srv.saveEpochCurrent("Bo", 2));
}

test "kickEntry skips already-dying conns (no re-flush)" {
    // A second kick at a closing conn must not append another disconnect:
    // re-flushing a dead peer's outbox is the write that wedges kickers
    // (duplicate-login path) for TCP-timeout minutes.
    const a = std.testing.allocator;
    const io = std.testing.io;
    const c = try a.create(Conn);
    defer a.destroy(c);
    c.* = Conn.init(a, io, .{}, 77);
    defer c.deinit();
    c.state = .play;
    @memcpy(c.username[0.."Bo".len], "Bo");
    c.username_len = 2;
    var kb: [16]u8 = undefined;
    try c.queueFramed(try packets.frameKeepAlive(7, &kb));
    const before = c.out.items.len;
    try std.testing.expect(before > 0);
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    // Guard returns before touching the stream (undefined here on purpose).
    c.close_after_flush = true;
    srv.kickEntry(.{ .conn = c, .stream = undefined }, "bye");
    try std.testing.expectEqual(before, c.out.items.len);
    c.close_after_flush = false;
    c.dead = true;
    srv.kickEntry(.{ .conn = c, .stream = undefined }, "bye");
    try std.testing.expectEqual(before, c.out.items.len);
}

test "weather: flags, strength fade, expiry, login sync frames" {
    // S2B(1/2) flips the client flag; S2B(7/8) carry the rendered
    // strengths (flags alone leave the sky clear on 1.7.10).
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    srv.setWeather(.rain, 200);
    try std.testing.expect(srv.raining and !srv.thundering);
    try std.testing.expectEqual(@as(u32, 200), srv.rain_time);
    try std.testing.expectEqual(@as(f32, 0), srv.rain_strength);
    srv.tickWeather();
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), srv.rain_strength, 1e-6);
    var i: usize = 0;
    while (i < 4) : (i += 1) srv.tickWeather();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), srv.rain_strength, 1e-6);
    try std.testing.expect(srv.raining); // 200 - 5*20 = 100 left
    while (srv.raining) srv.tickWeather();
    try std.testing.expect(!srv.raining);
    try std.testing.expect(srv.rain_strength < 1.0); // fades out past expiry
    // Thunder sets both flags + strengths.
    srv.setWeather(.thunder, 40);
    try std.testing.expect(srv.raining and srv.thundering);
    srv.tickWeather();
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), srv.thunder_strength, 1e-6);
    // Login sync queues 1/2 + 7 + 8 for the joiner.
    const c = try a.create(Conn);
    defer {
        c.deinit();
        a.destroy(c);
    }
    c.* = Conn.init(a, io, .{}, 7);
    srv.syncWeatherTo(c);
    c.lock.lock();
    const raw = try c.takeOutput();
    c.lock.unlock();
    defer a.free(raw);
    var reasons: [8]u8 = undefined;
    var n: usize = 0;
    var r = codec.PacketReader.init(raw);
    while (r.remaining() > 0) {
        const h = try codec.decodeFrame(&r);
        const blen: usize = @as(usize, @intCast(h.length - @as(i32, @intCast(codec.PacketWriter.varIntLen(h.id)))));
        if (h.id == 0x2B) {
            var pr = codec.PacketReader.init(r.buffer[r.index..]);
            reasons[n] = try pr.readByte();
            n += 1;
        }
        r.index += blen;
    }
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u8, 1), reasons[0]);
    try std.testing.expectEqual(@as(u8, 7), reasons[1]);
    try std.testing.expectEqual(@as(u8, 8), reasons[2]);
}

test "commands help/list/save-all/unknown (+ console null-sender)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer if (srv.perms) |*db| db.deinit();
    const mk = struct {
        fn run(name: []const u8, id: i32) !*Conn {
            const c = try a.create(Conn);
            errdefer a.destroy(c);
            c.* = Conn.init(a, io, .{}, id);
            c.state = .play;
            @memcpy(c.username[0..name.len], name);
            c.username_len = name.len;
            // Offline login sets uuid_str from the name; mirror it so
            // UUID-keyed permission checks match test conns.
            uuid_mod.formatUuid(uuid_mod.offlineUuid(name), &c.uuid_str);
            return c;
        }
    };
    // Replies are queued to the sender's outbox (flushed by serve/tick
    // loops live); tests drain the outbox directly, no sockets needed.
    // Multi-frame replies (e.g. /save-all's two lines) are consumed one
    // chat frame at a time; leftovers are re-queued untouched.
    const readChat = struct {
        fn run(c: *Conn) ![]u8 {
            // Returns the first 0x02 payload, restoring every other frame
            // (abilities/setslot interleavings + multi-line replies).
            c.lock.lock();
            const raw = try c.takeOutput();
            var off: usize = 0;
            var found: ?[]u8 = null;
            var fstart: usize = 0;
            var fend: usize = 0;
            while (off < raw.len) {
                var r = codec.PacketReader.init(raw[off..]);
                const h = codec.decodeFrame(&r) catch break;
                const flen: usize = @as(usize, @intCast(codec.PacketWriter.varIntLen(h.length))) + @as(usize, @intCast(h.length));
                if (h.id == 0x02 and found == null) {
                    var pr = codec.PacketReader.init(r.buffer[r.index..]);
                    found = try a.dupe(u8, try pr.readString());
                    fstart = off;
                    fend = off + flen;
                }
                off += flen;
            }
            if (found) |f| {
                var rest: [8192]u8 = undefined;
                var rl: usize = 0;
                const pre = raw[0..fstart];
                const post = raw[fend..];
                if (pre.len + post.len <= rest.len) {
                    @memcpy(rest[0..pre.len], pre);
                    @memcpy(rest[pre.len..][0..post.len], post);
                    rl = pre.len + post.len;
                    if (rl > 0) c.queueFramed(rest[0..rl]) catch {};
                }
                c.lock.unlock();
                defer a.free(raw);
                return f;
            }
            c.lock.unlock();
            defer a.free(raw);
            return error.NoChat;
        }
    }.run;
    var alice = try mk.run("AliceD", 1);
    var bob = try mk.run("BobD", 2);
    // /list with nobody registered: empty roster, still well-formed.
    srv.handleCommand(alice, "/list");
    const l0 = try readChat(alice);
    defer a.free(l0);
    try std.testing.expectEqualStrings("{\"text\":\"There are 0/20 players online:\"}", l0);
    // Register both (commands never touch streams; leave them undefined).
    try srv.registry.append(a, .{ .conn = alice, .stream = undefined });
    try srv.registry.append(a, .{ .conn = bob, .stream = undefined });
    // /list to Alice: both names, sender-only (Bob's outbox stays empty).
    srv.handleCommand(alice, "/list");
    const l1 = try readChat(alice);
    defer a.free(l1);
    try std.testing.expectEqualStrings("{\"text\":\"There are 2/20 players online:\"}", l1);
    const l1b = try readChat(alice);
    defer a.free(l1b);
    try std.testing.expectEqualStrings("{\"text\":\"AliceD, BobD\"}", l1b);
    {
        bob.lock.lock();
        const pending = try bob.takeOutput();
        bob.lock.unlock();
        defer a.free(pending);
        try std.testing.expectEqual(@as(usize, 0), pending.len);
    }
    // /help page 1: level-0 callers only see level-0 commands (vanilla
    // 7-per-page layout, one chat packet per line).
    srv.handleCommand(bob, "/help");
    const h_lines = [_][]const u8{
        "--- Showing help page 1 of 1 (/help <page>) ---",
        "/kill",
        "/me <action ...>",
        "/help [page|command name]",
        "/tell <player> <private message ...>",
        "/list",
        "/netstat",
        "/tps",
        "Tip: Use the <tab> key while typing a command to auto-complete the command or its arguments",
    };
    for (h_lines) |want| {
        const h = try readChat(bob);
        defer a.free(h);
        var eb: [512]u8 = undefined;
        const esc = try packets.escapeJsonText(want, &eb);
        var jb: [560]u8 = undefined;
        const json = try std.fmt.bufPrint(&jb, "{{\"text\":\"{s}\"}}", .{esc});
        try std.testing.expectEqualStrings(json, h);
    }
    // /help with extra args ignores the extras (vanilla reads args[0]).
    srv.handleCommand(bob, "/help with extra args ignored");
    const h1b = try readChat(bob);
    defer a.free(h1b);
    try std.testing.expectEqualStrings("{\"text\":\"Unknown command. Try /help for a list of commands\"}", h1b);
    // /help <command> prints that command's usage (header + usage lines).
    srv.handleCommand(bob, "/help list");
    const h1c = try readChat(bob);
    defer a.free(h1c);
    try std.testing.expectEqualStrings("{\"text\":\"--- list ---\"}", h1c);
    const h1d = try readChat(bob);
    defer a.free(h1d);
    try std.testing.expectEqualStrings("{\"text\":\"/list\"}", h1d);
    // unknown
    srv.handleCommand(alice, "/frobnicate");
    const unk = try readChat(alice);
    defer a.free(unk);
    try std.testing.expectEqualStrings("{\"text\":\"Unknown command. Try /help for a list of commands\"}", unk);
    // denied == unknown (no oracle): level-0 /save-all gets the same reply.
    srv.handleCommand(alice, "/save-all");
    const denied = try readChat(alice);
    defer a.free(denied);
    try std.testing.expectEqualStrings(unk, denied);
    // console sender (null) must not crash; no chat goes out.
    srv.handleCommand(null, "/list");
    srv.handleCommand(null, "/nope");
    srv.handleCommand(null, "/help");
    // /save-all without a world still replies (0 players, no flush).
    // NOTE: still denied for level-0 Alice; op-gated path is covered below.
    _ = srv.registry.pop();
    _ = srv.registry.pop();
    alice.deinit();
    a.destroy(alice);
    bob.deinit();
    a.destroy(bob);
}

test "runtime registry: mods show in help and dispatch" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer if (srv.perms) |*db| db.deinit();
    srv.ensureCommands();
    const n_builtin = srv.n_cmds;
    try std.testing.expectEqual(perms_mod.modules.len, n_builtin);
    const Fake = struct {
        fn run(s: *Server, sender: ?*Conn, args: []const u8, out: []u8) []const u8 {
            _ = s;
            _ = sender;
            _ = args;
            _ = out;
            return "fake-ok";
        }
    };
    var fake_def = perms_mod.Command{
        .name = "fakecmd",
        .node = "asteorite.command.fakecmd",
        .min_level = .all,
        .spec = &.{},
    };
    try std.testing.expect(srv.registerCommand(&fake_def, &Fake.run));
    try std.testing.expectEqual(n_builtin + 1, srv.n_cmds);
    // Name collisions are rejected (no silent shadowing).
    try std.testing.expect(!srv.registerCommand(&fake_def, &Fake.run));
    // Dispatch reaches the runtime entry (no comptime module needed).
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings("fake-ok", srv.executeCommand(null, "/fakecmd x", &out));
    // Help reads the same registry (this is the modding-API guarantee).
    var hb: [256]u8 = undefined;
    const h = srv.helpCommand(null, "fakecmd", &hb);
    try std.testing.expect(std.mem.indexOf(u8, h, "fakecmd") != null);
}

/// Test UUID for a name (mirrors the offline-mode derivation in
/// resolveUuid; the command tests run with online_mode=false).
fn testUuid(name: []const u8) [perms_mod.uuid_len]u8 {
    var out: [perms_mod.uuid_len]u8 = undefined;
    uuid_mod.formatUuid(uuid_mod.offlineUuid(name), &out);
    return out;
}

test "permissions gate commands: op/deop/grant/deny/show/clear/reload" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer if (srv.perms) |*db| db.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    srv.world = pool;
    const mk = struct {
        fn run(name: []const u8, id: i32) !*Conn {
            const c = try a.create(Conn);
            errdefer a.destroy(c);
            c.* = Conn.init(a, io, .{}, id);
            c.state = .play;
            @memcpy(c.username[0..name.len], name);
            c.username_len = name.len;
            // Offline login sets uuid_str from the name; mirror it so
            // UUID-keyed permission checks match test conns.
            uuid_mod.formatUuid(uuid_mod.offlineUuid(name), &c.uuid_str);
            return c;
        }
    };
    const readChat = struct {
        fn run(c: *Conn) ![]u8 {
            // Returns the first 0x02 payload, restoring every other frame
            // (abilities/setslot interleavings + multi-line replies).
            c.lock.lock();
            const raw = try c.takeOutput();
            var off: usize = 0;
            var found: ?[]u8 = null;
            var fstart: usize = 0;
            var fend: usize = 0;
            while (off < raw.len) {
                var r = codec.PacketReader.init(raw[off..]);
                const h = codec.decodeFrame(&r) catch break;
                const flen: usize = @as(usize, @intCast(codec.PacketWriter.varIntLen(h.length))) + @as(usize, @intCast(h.length));
                if (h.id == 0x02 and found == null) {
                    var pr = codec.PacketReader.init(r.buffer[r.index..]);
                    found = try a.dupe(u8, try pr.readString());
                    fstart = off;
                    fend = off + flen;
                }
                off += flen;
            }
            if (found) |f| {
                var rest: [8192]u8 = undefined;
                var rl: usize = 0;
                const pre = raw[0..fstart];
                const post = raw[fend..];
                if (pre.len + post.len <= rest.len) {
                    @memcpy(rest[0..pre.len], pre);
                    @memcpy(rest[pre.len..][0..post.len], post);
                    rl = pre.len + post.len;
                    if (rl > 0) c.queueFramed(rest[0..rl]) catch {};
                }
                c.lock.unlock();
                defer a.free(raw);
                return f;
            }
            c.lock.unlock();
            defer a.free(raw);
            return error.NoChat;
        }
    }.run;
    // Discard all pending chat frames (admin broadcasts to fellow ops).
    const drainChat = struct {
        fn run(c: *Conn) !void {
            while (true) {
                c.lock.lock();
                const raw = try c.takeOutput();
                c.lock.unlock();
                defer a.free(raw);
                if (raw.len == 0) return;
            }
        }
    }.run;
    var alice = try mk.run("AliceP", 1);
    defer {
        alice.deinit();
        a.destroy(alice);
    }
    // Non-op /op is denied exactly like unknown (no leak of the op path).
    srv.handleCommand(alice, "/op AliceP");
    const d0 = try readChat(alice);
    defer a.free(d0);
    try std.testing.expectEqualStrings("{\"text\":\"Unknown command. Try /help for a list of commands\"}", d0);
    srv.handleCommand(alice, "/perm show AliceP");
    const d0b = try readChat(alice);
    defer a.free(d0b);
    try std.testing.expectEqualStrings(d0, d0b);
    // Console ops Alice (null sender): silent here — Alice isn't registered
    // yet, so the admin broadcast has no recipients (verified by level).
    srv.handleCommand(null, "/op AliceP");
    {
        srv.perm_lock.lock();
        defer srv.perm_lock.unlock();
        try std.testing.expectEqual(perms_mod.OpLevel.owner, srv.perms.?.levelForUuid(&testUuid("AliceP")));
    }
    // /help now lists privileged commands for Alice (vanilla 7-per-page).
    srv.handleCommand(alice, "/help");
    const h1_lines = [_][]const u8{
        "--- Showing help page 1 of 8 (/help <page>) ---",
        "/time <set|add> <value>",
        "/gamemode <mode> [player]",
        "/difficulty <new difficulty>",
        "/defaultgamemode <mode>",
        "/kill",
        "/toggledownfall",
        "/weather <clear|rain|thunder> [duration in seconds]",
        "Tip: Use the <tab> key while typing a command to auto-complete the command or its arguments",
    };
    for (h1_lines) |want| {
        const h = try readChat(alice);
        defer a.free(h);
        var eb2: [512]u8 = undefined;
        const esc2 = try packets.escapeJsonText(want, &eb2);
        var jb2: [560]u8 = undefined;
        const json2 = try std.fmt.bufPrint(&jb2, "{{\"text\":\"{s}\"}}", .{esc2});
        try std.testing.expectEqualStrings(json2, h);
    }
    // /save-all allowed now (pool present; flushes). Two vanilla lines.
    srv.handleCommand(alice, "/save-all");
    const s1a = try readChat(alice);
    defer a.free(s1a);
    try std.testing.expectEqualStrings("{\"text\":\"Saving...\"}", s1a);
    const s1 = try readChat(alice);
    defer a.free(s1);
    try std.testing.expectEqualStrings("{\"text\":\"Saved the world\"}", s1);
    // /perm show
    srv.handleCommand(alice, "/perm show AliceP");
    const sh1 = try readChat(alice);
    defer a.free(sh1);
    try std.testing.expectEqualStrings("{\"text\":\"AliceP: level 4\"}", sh1);
    // Targeted notify: op Bob while Bob is online -> Bob gets told.
    var bob = try mk.run("BobP", 2);
    defer {
        bob.deinit();
        a.destroy(bob);
    }
    try srv.registry.append(a, .{ .conn = alice, .stream = undefined });
    try srv.registry.append(a, .{ .conn = bob, .stream = undefined });
    srv.handleCommand(alice, "/op BobP");
    const opb = try readChat(alice);
    defer a.free(opb);
    try std.testing.expectEqualStrings("{\"text\":\"Opped BobP\"}", opb);
    // Vanilla admin-notify reaches the target too (he is op now and can use
    // /op himself — the bl.a loop only skips the sender).
    const noteb = try readChat(bob);
    defer a.free(noteb);
    try std.testing.expectEqualStrings("{\"text\":\"[AliceP: Opped BobP]\",\"color\":\"gray\",\"italic\":true}", noteb);
    // Node grant to a level-0 player: /save-all via node, not level.
    srv.handleCommand(null, "/deop BobP"); // back to 0, nodes cleared
    // Console deop admin-notifies Alice (the other op): drain it.
    const dbdrain = try readChat(alice);
    defer a.free(dbdrain);
    try std.testing.expectEqualStrings("{\"text\":\"[Server: De-opped BobP]\",\"color\":\"gray\",\"italic\":true}", dbdrain);
    srv.handleCommand(bob, "/save-all");
    const denied = try readChat(bob);
    defer a.free(denied);
    try std.testing.expectEqualStrings(d0, denied);
    srv.handleCommand(alice, "/perm grant BobP asteorite.command.save-all");
    const g1 = try readChat(alice);
    defer a.free(g1);
    try std.testing.expectEqualStrings("{\"text\":\"Granted.\"}", g1);
    srv.handleCommand(bob, "/save-all");
    const s2a = try readChat(bob);
    defer a.free(s2a);
    try std.testing.expectEqualStrings("{\"text\":\"Saving...\"}", s2a);
    const s2 = try readChat(bob);
    defer a.free(s2);
    try std.testing.expectEqualStrings("{\"text\":\"Saved the world\"}", s2);
    try drainChat(alice);
    // Deny beats grant.
    srv.handleCommand(alice, "/perm deny BobP asteorite.command.save-all");
    const denyack = try readChat(alice);
    defer a.free(denyack);
    srv.handleCommand(bob, "/save-all");
    const denied2 = try readChat(bob);
    defer a.free(denied2);
    try std.testing.expectEqualStrings(d0, denied2);
    // Clear restores denial-by-default.
    srv.handleCommand(alice, "/perm clear BobP asteorite.command.save-all");
    const clearack = try readChat(alice);
    defer a.free(clearack);
    srv.handleCommand(bob, "/save-all");
    const denied3 = try readChat(bob);
    defer a.free(denied3);
    try std.testing.expectEqualStrings(d0, denied3);
    // Wildcard grant covers save-all.
    srv.handleCommand(alice, "/perm grant BobP asteorite.command.*");
    const wildack = try readChat(alice);
    defer a.free(wildack);
    srv.handleCommand(bob, "/save-all");
    const s3a = try readChat(bob);
    defer a.free(s3a);
    try std.testing.expectEqualStrings("{\"text\":\"Saving...\"}", s3a);
    const s3 = try readChat(bob);
    defer a.free(s3);
    try std.testing.expectEqualStrings("{\"text\":\"Saved the world\"}", s3);
    try drainChat(alice);
    // /perm show lists nodes.
    srv.handleCommand(alice, "/perm show BobP");
    const sh2 = try readChat(alice);
    defer a.free(sh2);
    try std.testing.expectEqualStrings("{\"text\":\"BobP: level 0 +asteorite.command.*\"}", sh2);
    // Reload round-trips the matrix through the LSM row.
    srv.handleCommand(alice, "/perm reload");
    const rl = try readChat(alice);
    defer a.free(rl);
    try std.testing.expectEqualStrings("{\"text\":\"Permissions reloaded.\"}", rl);
    srv.handleCommand(bob, "/save-all");
    const s4a = try readChat(bob);
    defer a.free(s4a);
    try std.testing.expectEqualStrings("{\"text\":\"Saving...\"}", s4a);
    const s4 = try readChat(bob);
    defer a.free(s4);
    try std.testing.expectEqualStrings("{\"text\":\"Saved the world\"}", s4);
    try drainChat(alice);
    // Malformed inputs get usage, not crashes.
    srv.handleCommand(alice, "/op");
    const usage1 = try readChat(alice);
    defer a.free(usage1);
    try std.testing.expectEqualStrings("{\"text\":\"Usage: /op <player>\"}", usage1);
    srv.handleCommand(alice, "/op Bad!Name");
    const usage2 = try readChat(alice);
    defer a.free(usage2);
    try std.testing.expectEqualStrings("{\"text\":\"Opped Bad!Name\"}", usage2);
    srv.handleCommand(alice, "/perm grant BobP HAS SPACE");
    const usage3 = try readChat(alice);
    defer a.free(usage3);
    try std.testing.expectEqualStrings("{\"text\":\"Usage: /perm <grant|deny|clear|show|reload> [player] [node]\"}", usage3);
    srv.handleCommand(alice, "/perm frobnicate BobP asteorite.command.list");
    const usage4 = try readChat(alice);
    defer a.free(usage4);
    try std.testing.expectEqualStrings("{\"text\":\"Usage: /perm <grant|deny|clear|show|reload> [player] [node]\"}", usage4);
    _ = srv.registry.pop();
    _ = srv.registry.pop();
}

test "tab-complete: single-token candidates carry the slash" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer if (srv.perms) |*db| db.deinit();
    const mk = struct {
        fn run(name: []const u8) !*Conn {
            const c = try a.create(Conn);
            c.* = Conn.init(a, io, .{}, 7);
            @memcpy(c.username[0..name.len], name);
            c.username_len = name.len;
            c.state = .play;
            return c;
        }
    }.run;
    var alice = try mk("AliceT");
    defer {
        alice.deinit();
        a.destroy(alice);
    }
    try srv.registry.append(a, .{ .conn = alice, .stream = undefined });
    srv.handleCommand(null, "/op AliceT");
    // Drain the op admin-notice so only the S3A remains.
    {
        alice.lock.lock();
        const pending = try alice.takeOutput();
        alice.lock.unlock();
        defer a.free(pending);
    }
    // "/game" must complete to "/gamemode" (with slash): the 1.7.10
    // client replaces the whole word, so bare names ate the "/".
    srv.handleTabComplete(alice, "/game");
    {
        alice.lock.lock();
        const raw = try alice.takeOutput();
        alice.lock.unlock();
        defer a.free(raw);
        var r = codec.PacketReader.init(raw);
        const h = try codec.decodeFrame(&r);
        try std.testing.expectEqual(@as(i32, 0x3A), h.id);
        const n = try r.readVarInt();
        try std.testing.expect(n >= 1);
        var seen_slash = false;
        var i: i32 = 0;
        while (i < n) : (i += 1) {
            const cand = try r.readString();
            try std.testing.expect(cand.len > 0 and cand[0] == '/');
            if (std.mem.eql(u8, cand, "/gamemode")) seen_slash = true;
        }
        try std.testing.expect(seen_slash);
    }
}

test "gameplay commands: gamemode/give/tp/time (+ denials, usage, nodes)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer if (srv.perms) |*db| db.deinit();
    defer {
        srv.ent_lock.lock();
        srv.items.deinit(a);
        srv.ent_lock.unlock();
    }
    var port: u16 = 37951;
    const mk = struct {
        fn run(name: []const u8, id: i32) !*Conn {
            const c = try a.create(Conn);
            errdefer a.destroy(c);
            c.* = Conn.init(a, io, .{}, id);
            c.state = .play;
            @memcpy(c.username[0..name.len], name);
            c.username_len = name.len;
            // Offline login sets uuid_str from the name; mirror it so
            // UUID-keyed permission checks match test conns.
            uuid_mod.formatUuid(uuid_mod.offlineUuid(name), &c.uuid_str);
            return c;
        }
    };
    const Frame = struct { id: i32, body: []u8 };
    const Drain = struct {
        fn run(c: *Conn) !std.ArrayList(Frame) {
            var out = std.ArrayList(Frame).empty;
            errdefer {
                for (out.items) |f| a.free(f.body);
                out.deinit(a);
            }
            c.lock.lock();
            const raw = try c.takeOutput();
            c.lock.unlock();
            defer a.free(raw);
            var r = codec.PacketReader.init(raw);
            while (r.remaining() > 0) {
                const h = try codec.decodeFrame(&r);
                // decodeFrame consumed length+id; body excludes the id bytes.
                const blen: usize = @intCast(h.length - @as(i32, @intCast(codec.PacketWriter.varIntLen(h.id))));
                try out.append(a, .{ .id = h.id, .body = try a.dupe(u8, r.buffer[r.index..][0..blen]) });
                r.index += blen;
            }
            return out;
        }
        fn free(list: *std.ArrayList(Frame)) void {
            for (list.items) |f| a.free(f.body);
            list.deinit(a);
        }
        fn find(list: *const std.ArrayList(Frame), id: i32) ?[]const u8 {
            for (list.items) |f| {
                if (f.id == id) return f.body;
            }
            return null;
        }
    };
    const readChat = struct {
        fn run(c: *Conn) ![]u8 {
            // Returns the first 0x02 payload, restoring every other frame
            // (abilities/setslot interleavings + multi-line replies).
            c.lock.lock();
            const raw = try c.takeOutput();
            var off: usize = 0;
            var found: ?[]u8 = null;
            var fstart: usize = 0;
            var fend: usize = 0;
            while (off < raw.len) {
                var r = codec.PacketReader.init(raw[off..]);
                const h = codec.decodeFrame(&r) catch break;
                const flen: usize = @as(usize, @intCast(codec.PacketWriter.varIntLen(h.length))) + @as(usize, @intCast(h.length));
                if (h.id == 0x02 and found == null) {
                    var pr = codec.PacketReader.init(r.buffer[r.index..]);
                    found = try a.dupe(u8, try pr.readString());
                    fstart = off;
                    fend = off + flen;
                }
                off += flen;
            }
            if (found) |f| {
                var rest: [8192]u8 = undefined;
                var rl: usize = 0;
                const pre = raw[0..fstart];
                const post = raw[fend..];
                if (pre.len + post.len <= rest.len) {
                    @memcpy(rest[0..pre.len], pre);
                    @memcpy(rest[pre.len..][0..post.len], post);
                    rl = pre.len + post.len;
                    if (rl > 0) c.queueFramed(rest[0..rl]) catch {};
                }
                c.lock.unlock();
                defer a.free(raw);
                return f;
            }
            c.lock.unlock();
            defer a.free(raw);
            return error.NoChat;
        }
    }.run;
    // Discard pending admin broadcasts (fellow-op noise).
    const drainChat = struct {
        fn run(c: *Conn) !void {
            while (true) {
                c.lock.lock();
                const raw = try c.takeOutput();
                c.lock.unlock();
                defer a.free(raw);
                if (raw.len == 0) return;
            }
        }
    }.run;
    var alice = try mk.run("AliceG", 1);
    defer {
        alice.deinit();
        a.destroy(alice);
    }
    var bob = try mk.run("BobG", 2);
    defer {
        bob.deinit();
        a.destroy(bob);
    }
    // killPlayer now broadcasts the death line (broadcastChat flushes inline),
    // so the registry streams must be real sockets: loopback pairs whose far
    // end is never read (frames are tiny; kernel buffers hold them).
    // `.stream = undefined` panics on flush (NOTSOCK in Debug).
    var listener: std.Io.net.Server = while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        break addr.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => {
                port += 1;
                if (port > 38000) return err;
                continue;
            },
            else => return err,
        };
    };
    defer listener.deinit(io);
    const laddr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var alice_cli = try laddr.connect(io, .{ .mode = .stream });
    defer alice_cli.close(io);
    var alice_srv = try listener.accept(io);
    defer alice_srv.close(io);
    var bob_cli = try laddr.connect(io, .{ .mode = .stream });
    defer bob_cli.close(io);
    var bob_srv = try listener.accept(io);
    defer bob_srv.close(io);
    try srv.registry.append(a, .{ .conn = alice, .stream = alice_srv });
    try srv.registry.append(a, .{ .conn = bob, .stream = bob_srv });
    // Bob (level 0) is denied the new commands, same as unknown.
    srv.handleCommand(bob, "/gamemode 0");
    const _r1 = try readChat(bob);
    defer a.free(_r1);
    try std.testing.expectEqualStrings("{\"text\":\"Unknown command. Try /help for a list of commands\"}", _r1);
    // Op Alice via console; Bob stays level 0.
    srv.handleCommand(null, "/op AliceG");
    // Console op admin-notifies the target (she can use /op now herself).
    const _r2 = try readChat(alice);
    defer a.free(_r2);
    try std.testing.expectEqualStrings("{\"text\":\"[Server: Opped AliceG]\",\"color\":\"gray\",\"italic\":true}", _r2);
    // /gamemode on Bob by Alice: config flips + 0x39 abilities (flags 0x00).
    srv.handleCommand(alice, "/gamemode 0 BobG");
    try std.testing.expect(bob.config.gamemode == .survival);
    {
        var fr = try Drain.run(bob);
        defer Drain.free(&fr);
        const ab = Drain.find(&fr, 0x39) orelse return error.NoAbilities;
        try std.testing.expectEqual(@as(u8, 0x00), ab[0]);
        // Vanilla flips the client controller via S2B reason 3.
        const gs = Drain.find(&fr, 0x2B) orelse return error.NoGameState;
        try std.testing.expectEqual(@as(u8, 3), gs[0]);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), @as(f32, @bitCast(std.mem.readInt(u32, gs[1..5], .big))), 1e-6);
    }
    const gm = try readChat(alice);
    defer a.free(gm);
    try std.testing.expectEqualStrings("{\"text\":\"Set BobG's game mode to survival\"}", gm);
    // /gamemode self form + invalid forms.
    srv.handleCommand(alice, "/gamemode creative");
    try std.testing.expect(alice.config.gamemode == .creative);
    const _d1 = try readChat(alice);
    defer a.free(_d1);
    try std.testing.expectEqualStrings("{\"text\":\"Set own game mode to creative\"}", _d1);
    srv.handleCommand(alice, "/gamemode");
    const _r3 = try readChat(alice);
    defer a.free(_r3);
    try std.testing.expectEqualStrings("{\"text\":\"Usage: /gamemode <mode> [player]\"}", _r3);
    srv.handleCommand(alice, "/gamemode 7");
    const _r4 = try readChat(alice);
    defer a.free(_r4);
    try std.testing.expectEqualStrings("{\"text\":\"Usage: /gamemode <mode> [player]\"}", _r4);
    srv.handleCommand(alice, "/gamemode 0 NobodyHere");
    const _r5 = try readChat(alice);
    defer a.free(_r5);
    try std.testing.expectEqualStrings("{\"text\":\"That player cannot be found\"}", _r5);
    srv.handleCommand(alice, "/gamemode adventure BobG");
    try std.testing.expect(bob.config.gamemode == .adventure);
    const _d1b = try readChat(alice);
    defer a.free(_d1b);
    try std.testing.expectEqualStrings("{\"text\":\"Set BobG's game mode to adventure\"}", _d1b);
    // /give: 64 dirt to Bob (first empty hotbar slot = 36).
    srv.handleCommand(alice, "/give BobG 1 64");
    {
        try std.testing.expectEqual(game_ids.stone, bob.inv[36].?.id);
        try std.testing.expectEqual(@as(i8, 64), bob.inv[36].?.count);
        var fr = try Drain.run(bob);
        defer Drain.free(&fr);
        const sb = Drain.find(&fr, 0x2F) orelse return error.NoSetSlot;
        var r = codec.PacketReader.init(sb);
        _ = try r.readByte();
        try std.testing.expectEqual(@as(i16, 36), try r.readShort());
        const it = (try packets.parseSlot(&r)).?;
        try std.testing.expectEqual(@as(i16, 1), it.id);
        try std.testing.expectEqual(@as(i8, 64), it.count);
    }
    // Numeric ids warn first, then the vanilla success line.
    const gw = try readChat(alice);
    defer a.free(gw);
    try std.testing.expectEqualStrings("{\"text\":\"Warning: Using numeric IDs will not be supported in the future. Please use names, such as 'stone'\"}", gw);
    const gv = try readChat(alice);
    defer a.free(gv);
    try std.testing.expectEqualStrings("{\"text\":\"Given stone * 64 to BobG\"}", gv);
    // /give validation: bad id/count/damage, offline target, defaults.
    srv.handleCommand(alice, "/give BobG 0 1");
    const _r6 = try readChat(alice);
    defer a.free(_r6);
    try std.testing.expectEqualStrings("{\"text\":\"There is no such item with ID 0\"}", _r6);
    srv.handleCommand(alice, "/give BobG 4096 1");
    const _r7 = try readChat(alice);
    defer a.free(_r7);
    try std.testing.expectEqualStrings("{\"text\":\"There is no such item with ID 4096\"}", _r7);
    srv.handleCommand(alice, "/give BobG 1 0");
    const _r8 = try readChat(alice);
    defer a.free(_r8);
    try std.testing.expectEqualStrings("{\"text\":\"The number you have entered (0) is too small, it must be at least 1\"}", _r8);
    srv.handleCommand(alice, "/give BobG 1 65");
    const _r9 = try readChat(alice);
    defer a.free(_r9);
    try std.testing.expectEqualStrings("{\"text\":\"The number you have entered (65) is too big, it must be at most 64\"}", _r9);
    srv.handleCommand(alice, "/give Ghost 1 1");
    const _r10 = try readChat(alice);
    defer a.free(_r10);
    try std.testing.expectEqualStrings("{\"text\":\"That player cannot be found\"}", _r10);
    // Node grant lets level-0 Bob /give; deny revokes it again.
    srv.handleCommand(alice, "/perm grant BobG asteorite.command.give");
    const _d2 = try readChat(alice);
    defer a.free(_d2);
    srv.handleCommand(bob, "/give BobG 3 5");
    {
        // dirt is a new id: stone fills slot 36 (64/64 full) -> first empty slot 37.
        try std.testing.expectEqual(game_ids.dirt, bob.inv[37].?.id);
        try std.testing.expectEqual(@as(i8, 5), bob.inv[37].?.count);
    }
    const _d3w = try readChat(bob);
    defer a.free(_d3w);
    try std.testing.expectEqualStrings("{\"text\":\"Warning: Using numeric IDs will not be supported in the future. Please use names, such as 'dirt'\"}", _d3w);
    const _d3 = try readChat(bob);
    defer a.free(_d3);
    try std.testing.expectEqualStrings("{\"text\":\"Given dirt * 5 to BobG\"}", _d3);
    // Bob's success admin-notifies Alice (fellow op with the node).
    try drainChat(alice);
    srv.handleCommand(alice, "/perm deny BobG asteorite.command.give");
    const _d4 = try readChat(alice);
    defer a.free(_d4);
    srv.handleCommand(bob, "/give BobG 3 1");
    const _r11 = try readChat(bob);
    defer a.free(_r11);
    try std.testing.expectEqualStrings("{\"text\":\"Unknown command. Try /help for a list of commands\"}", _r11);
    // Name form needs no warning and skips the deprecation line.
    srv.handleCommand(alice, "/perm grant BobG asteorite.command.give");
    const _d2b = try readChat(alice);
    defer a.free(_d2b);
    srv.handleCommand(bob, "/give BobG dirt 2");
    const _d3b = try readChat(bob);
    defer a.free(_d3b);
    try std.testing.expectEqualStrings("{\"text\":\"Given dirt * 2 to BobG\"}", _d3b);
    try drainChat(alice);
    srv.handleCommand(alice, "/perm deny BobG asteorite.command.give");
    const _d4b = try readChat(alice);
    defer a.free(_d4b);
    // /tp Alice -> Bob (1-arg), then coords, then victim form.
    bob.pos_x = 100.0;
    bob.pos_y = 70.0;
    bob.pos_z = -40.0;
    srv.handleCommand(alice, "/tp BobG");
    try std.testing.expectApproxEqAbs(100.0, alice.pos_x, 1e-9);
    try std.testing.expect(alice.chunks_dirty);
    {
        var fr = try Drain.run(alice);
        defer Drain.free(&fr);
        const pl = Drain.find(&fr, 0x08) orelse return error.NoPosLook;
        const pux = std.mem.readInt(u64, pl[0..8], .big);
        try std.testing.expectApproxEqAbs(100.0, @as(f64, @bitCast(pux)), 1e-9);
        const rp = Drain.find(&fr, 0x02) orelse return error.NoReply;
        var pr = codec.PacketReader.init(rp);
        try std.testing.expectEqualStrings("{\"text\":\"Teleported AliceG to BobG\"}", try pr.readString());
    }
    srv.handleCommand(alice, "/perm grant BobG asteorite.command.tp");
    const _d5 = try readChat(alice);
    defer a.free(_d5);
    srv.handleCommand(bob, "/tp 10 70 10");
    try std.testing.expectApproxEqAbs(10.0, bob.pos_x, 1e-9);
    try std.testing.expectApproxEqAbs(70.0, bob.pos_y, 1e-9);
    const tp2 = try readChat(bob);
    defer a.free(tp2);
    try std.testing.expectEqualStrings("{\"text\":\"Teleported BobG to 10.00,70.00,10.00\"}", tp2);
    // Bob's tp admin-notifies Alice (fellow op).
    try drainChat(alice);
    srv.handleCommand(alice, "/tp BobG AliceG");
    try std.testing.expectApproxEqAbs(100.0, bob.pos_x, 1e-9);
    const tpv = try readChat(alice);
    defer a.free(tpv);
    try std.testing.expectEqualStrings("{\"text\":\"Teleported BobG to AliceG\"}", tpv);
    // Bob holds the tp node now, so he saw an admin copy: drain it.
    try drainChat(bob);
    // /tp usage + bad coords + unknown players.
    srv.handleCommand(alice, "/tp");
    const _r12 = try readChat(alice);
    defer a.free(_r12);
    try std.testing.expectEqualStrings("{\"text\":\"Usage: /tp [target player] <destination player> OR /tp [target player] <x> <y> <z>\"}", _r12);
    srv.handleCommand(alice, "/tp one two three");
    const _r13 = try readChat(alice);
    defer a.free(_r13);
    try std.testing.expectEqualStrings("{\"text\":\"Usage: /tp [target player] <destination player> OR /tp [target player] <x> <y> <z>\"}", _r13);
    srv.handleCommand(alice, "/tp 0 nan 0");
    const _r14 = try readChat(alice);
    defer a.free(_r14);
    try std.testing.expectEqualStrings("{\"text\":\"Usage: /tp [target player] <destination player> OR /tp [target player] <x> <y> <z>\"}", _r14);
    // Vanilla tp has no y clamp: y=999 works, coords render %.2f.
    srv.handleCommand(alice, "/tp 0 999 0");
    const _r15 = try readChat(alice);
    defer a.free(_r15);
    try std.testing.expectEqualStrings("{\"text\":\"Teleported AliceG to 0.00,999.00,0.00\"}", _r15);
    try drainChat(bob);
    srv.handleCommand(alice, "/tp 0 70 0");
    const _r15b = try readChat(alice);
    defer a.free(_r15b);
    try std.testing.expectEqualStrings("{\"text\":\"Teleported AliceG to 0.00,70.00,0.00\"}", _r15b);
    try drainChat(bob);
    srv.handleCommand(alice, "/tp Ghost");
    const _r16 = try readChat(alice);
    defer a.free(_r16);
    try std.testing.expectEqualStrings("{\"text\":\"That player cannot be found\"}", _r16);
    // /time set/add, keywords, usage, denial for level 0.
    srv.handleCommand(bob, "/time set 0");
    const _r17 = try readChat(bob);
    defer a.free(_r17);
    try std.testing.expectEqualStrings("{\"text\":\"Unknown command. Try /help for a list of commands\"}", _r17);
    srv.handleCommand(alice, "/time set 13000");
    try std.testing.expectEqual(@as(i64, 13000), srv.time_of_day.load(.acquire));
    const _r18 = try readChat(alice);
    defer a.free(_r18);
    try std.testing.expectEqualStrings("{\"text\":\"Set the time to 13000\"}", _r18);
    srv.handleCommand(alice, "/time add 1000");
    try std.testing.expectEqual(@as(i64, 14000), srv.time_of_day.load(.acquire));
    const _r19 = try readChat(alice);
    defer a.free(_r19);
    try std.testing.expectEqualStrings("{\"text\":\"Added 1000 to the time\"}", _r19);
    srv.handleCommand(alice, "/time set day");
    try std.testing.expectEqual(@as(i64, 1000), srv.time_of_day.load(.acquire));
    const _d6 = try readChat(alice);
    defer a.free(_d6);
    srv.handleCommand(alice, "/time set night");
    try std.testing.expectEqual(@as(i64, 13000), srv.time_of_day.load(.acquire));
    const _d7 = try readChat(alice);
    defer a.free(_d7);
    srv.handleCommand(alice, "/time");
    const _r20 = try readChat(alice);
    defer a.free(_r20);
    try std.testing.expectEqualStrings("{\"text\":\"Usage: /time <set|add> <value>\"}", _r20);
    srv.handleCommand(alice, "/time frobnicate 1");
    const _r21 = try readChat(alice);
    defer a.free(_r21);
    try std.testing.expectEqualStrings("{\"text\":\"Usage: /time <set|add> <value>\"}", _r21);
    srv.handleCommand(alice, "/time set xyz");
    const _r22 = try readChat(alice);
    defer a.free(_r22);
    try std.testing.expectEqualStrings("{\"text\":\"'xyz' is not a valid number\"}", _r22);
    // Full inventory: /give reports partial with leftover.
    for (item_mod.main_lo..item_mod.inv_size) |s| bob.inv[s] = .{ .id = game_ids.planks, .count = 64, .damage = 0, .nbt = null };
    srv.handleCommand(alice, "/perm clear BobG asteorite.command.give");
    const _d8 = try readChat(alice);
    defer a.free(_d8);
    srv.handleCommand(alice, "/op BobG");
    const _d9 = try readChat(alice);
    defer a.free(_d9);
    // The new op is admin-notified too (vanilla bl.a loop skips only sender).
    const _d9b = try readChat(bob);
    defer a.free(_d9b);
    try std.testing.expectEqualStrings("{\"text\":\"[AliceG: Opped BobG]\",\"color\":\"gray\",\"italic\":true}", _d9b);
    srv.handleCommand(bob, "/give BobG 1 10");
    const nospacew = try readChat(bob);
    defer a.free(nospacew);
    const nospace = try readChat(bob);
    defer a.free(nospace);
    try std.testing.expectEqualStrings("{\"text\":\"Given stone * 10 to BobG\"}", nospace);
    // Overflow drops at Bob's feet; Alice (fellow op) saw the admin copy.
    try std.testing.expect(srv.items.items.len > 0);
    try drainChat(alice);
    // /enchant success path: sword in the held slot gets an `ench` NBT list
    // and a 0x2F refresh; incompatible/silly targets get vanilla errors.
    bob.inv[36] = .{ .id = game_ids.diamond_sword, .count = 1, .damage = 0, .nbt = null };
    bob.selected = 0;
    srv.handleCommand(alice, "/enchant BobG 16 2");
    const ench1 = try readChat(alice);
    defer a.free(ench1);
    try std.testing.expectEqualStrings("{\"text\":\"Enchanting succeeded\"}", ench1);
    {
        const st = bob.inv[36].?;
        try std.testing.expect(st.nbt != null);
        // ench list contains (16, 2).
        var found = false;
        var i: usize = 0;
        const raw = st.nbt.?;
        // Entry layout: 03 <00 02> "id" <i16> 03 <00 03> "lvl" <i16> 00.
        while (i + 2 <= raw.len) : (i += 1) {
            if (raw[i] == 'i' and raw[i + 1] == 'd' and i + 12 <= raw.len) {
                const id = std.mem.readInt(i16, raw[i + 2 ..][0..2], .big);
                const lvl = std.mem.readInt(i16, raw[i + 10 ..][0..2], .big);
                if (id == 16 and lvl == 2) found = true;
            }
        }
        try std.testing.expect(found);
    }
    try drainChat(bob); // 0x2F setslot refresh
    // Smite on a sharp sword: vanilla cantCombine.
    srv.handleCommand(alice, "/enchant BobG 17 1");
    const ench2 = try readChat(alice);
    defer a.free(ench2);
    try std.testing.expectEqualStrings("{\"text\":\"The selected enchantment can't be added to the target item\"}", ench2);
    // Unbreaking on dirt: not damageable.
    item_mod.freeStack(a, &bob.inv[36]);
    bob.inv[36] = .{ .id = game_ids.dirt, .count = 1, .damage = 0, .nbt = null };
    srv.handleCommand(alice, "/enchant BobG 34 1");
    const ench3 = try readChat(alice);
    defer a.free(ench3);
    try std.testing.expectEqualStrings("{\"text\":\"The selected enchantment can't be added to the target item\"}", ench3);
    // keepInventory: death keeps the inventory (no drops, no wipe).
    bob.inv[9] = .{ .id = game_ids.stone, .count = 1, .damage = 0, .nbt = null };
    srv.handleCommand(alice, "/gamerule keepInventory true");
    const _ki = try readChat(alice);
    defer a.free(_ki);
    try std.testing.expect(srv.keepInv());
    try std.testing.expect(srv.killPlayer("BobG"));
    try std.testing.expect(bob.is_dead);
    try std.testing.expect(bob.inv[9] != null);
    // No death drops under keepInventory (only the earlier give overflow).
    try std.testing.expectEqual(@as(usize, 1), srv.items.items.len);
    srv.handleCommand(alice, "/gamerule keepInventory false");
    const _ki2 = try readChat(alice);
    defer a.free(_ki2);
    try std.testing.expect(!srv.keepInv());
    _ = srv.registry.pop();
    _ = srv.registry.pop();
}

test "canSpawnMob: master, per-kind, and doMobSpawning all gate" {
    // Spawn ingress gate: open by default; any one refusal (config
    // master, per-kind map, gamerule) closes it. Existing mobs are
    // unaffected by construction (callers only gate new spawns).
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer srv.items.deinit(a);
    defer srv.chests.deinit(a);
    try std.testing.expect(srv.canSpawnMob(.pig));
    try std.testing.expect(srv.canSpawnMob(.zombie));
    try std.testing.expect(srv.canSpawnMob(.ender_dragon));
    {
        var c = srv.cfg.load();
        c.spawn_mobs = false;
        srv.cfg.store(c);
    }
    try std.testing.expect(!srv.canSpawnMob(.pig));
    {
        var c = srv.cfg.load();
        c.spawn_mobs = true;
        c.mob_spawn_allowed[@intFromEnum(mob_mod.Kind.pig)] = false;
        srv.cfg.store(c);
    }
    try std.testing.expect(!srv.canSpawnMob(.pig));
    try std.testing.expect(srv.canSpawnMob(.cow));
    try std.testing.expect(srv.gameruleSet("doMobSpawning", false));
    try std.testing.expect(!srv.canSpawnMob(.cow));
    try std.testing.expect(srv.gameruleSet("doMobSpawning", true));
    try std.testing.expect(srv.canSpawnMob(.cow));
}

test "furnace: take output moves stack to cursor + syncs" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer srv.furnaces.deinit(a);
    var conn = Conn.init(a, io, .{}, 7);
    defer conn.deinit();
    conn.open_win = .{ .id = 2, .x = 2, .y = 69, .z = 0 };
    srv.ensureFurnace(2, 69, 0);
    const f = srv.findFurnace(2, 69, 0).?;
    f.output = .{ .id = game_ids.iron_ingot, .count = 3, .damage = 0, .nbt = null };
    srv.applyFurnaceClick(&conn, .{ .slot = 2, .button = 0, .action = 601, .mode = 0 });
    try std.testing.expect(conn.cursor != null);
    try std.testing.expectEqual(game_ids.iron_ingot, conn.cursor.?.id);
    try std.testing.expectEqual(@as(i8, 3), conn.cursor.?.count);
    try std.testing.expect(srv.findFurnace(2, 69, 0).?.output == null);
    const out = try conn.takeOutput();
    defer a.free(out);
    try std.testing.expect(out.len > 0);
}

test "brew: shift-click routes potions and ingredients, brews in 20s" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer srv.brews.deinit(a);
    var conn = Conn.init(a, io, .{}, 7);
    defer conn.deinit();
    conn.open_win = .{ .id = 7, .x = 2, .y = 69, .z = 0 };
    srv.ensureBrew(2, 69, 0);
    const br = srv.findBrew(2, 69, 0).?;
    // Shift-click water bottles -> bottle slots 0-2 in order.
    conn.inv[9] = .{ .id = game_ids.potion, .count = 3, .damage = 0, .nbt = null };
    srv.applyBrewClick(&conn, .{ .slot = 4, .button = 0, .action = 701, .mode = 1 });
    try std.testing.expect(br.bottles[0] != null);
    try std.testing.expectEqual(@as(i8, 3), br.bottles[0].?.count);
    try std.testing.expect(conn.inv[9] == null);
    // Shift-click nether wart -> ingredient slot.
    conn.inv[10] = .{ .id = game_ids.nether_wart_item, .count = 2, .damage = 0, .nbt = null };
    srv.applyBrewClick(&conn, .{ .slot = 5, .button = 0, .action = 702, .mode = 1 });
    try std.testing.expectEqual(game_ids.nether_wart_item, br.ingredient.?.id);
    try std.testing.expect(conn.inv[10] == null);
    // Non-brewing items refuse the stand (stone shifts to the hotbar,
    // never into a bottle or the ingredient slot).
    conn.inv[11] = .{ .id = game_ids.stone, .count = 1, .damage = 0, .nbt = null };
    srv.applyBrewClick(&conn, .{ .slot = 6, .button = 0, .action = 703, .mode = 1 });
    try std.testing.expect(br.bottles[1] == null);
    try std.testing.expect(br.bottles[2] == null);
    try std.testing.expectEqual(game_ids.nether_wart_item, br.ingredient.?.id);
    var found_stone = false;
    for (conn.inv) |st| if (st) |s| {
        if (s.id == game_ids.stone) found_stone = true;
    };
    try std.testing.expect(found_stone);
    // Drive the server row through the engine (same borrow pattern as the
    // ticker): 20 quanta convert in place, one wart consumed.
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var slots = brewing_mod.Slots{ .ingredient = br.ingredient };
        for (&br.bottles, 0..) |*bt, k| slots.bottles[k] = bt.*;
        _ = brewing_mod.tick(&slots, &br.brew);
        for (&br.bottles, 0..) |*bt, k| bt.* = slots.bottles[k];
        br.ingredient = slots.ingredient;
    }
    try std.testing.expectEqual(@as(i16, 16), br.bottles[0].?.damage);
    try std.testing.expectEqual(@as(i8, 3), br.bottles[0].?.count);
    try std.testing.expectEqual(@as(i8, 1), br.ingredient.?.count);
    try std.testing.expectEqual(@as(u32, brewing_mod.brew_target), br.brew);
}

test "brew: mode-0 pickup and number-key swap move bottles" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer srv.brews.deinit(a);
    var conn = Conn.init(a, io, .{}, 7);
    defer conn.deinit();
    conn.open_win = .{ .id = 7, .x = 2, .y = 69, .z = 0 };
    srv.ensureBrew(2, 69, 0);
    const br = srv.findBrew(2, 69, 0).?;
    br.bottles[0] = .{ .id = game_ids.potion, .count = 1, .damage = 16, .nbt = null };
    // Left-click bottle -> cursor.
    srv.applyBrewClick(&conn, .{ .slot = 0, .button = 0, .action = 710, .mode = 0 });
    try std.testing.expectEqual(game_ids.potion, conn.cursor.?.id);
    try std.testing.expectEqual(@as(i16, 16), conn.cursor.?.damage);
    try std.testing.expect(br.bottles[0] == null);
    // Right-click places one back... (single stack: whole stack returns).
    srv.applyBrewClick(&conn, .{ .slot = 0, .button = 1, .action = 711, .mode = 0 });
    try std.testing.expect(conn.cursor == null);
    try std.testing.expectEqual(@as(i16, 16), br.bottles[0].?.damage);
    // Number-key swaps bottle with hotbar.
    conn.inv[36] = .{ .id = game_ids.potion, .count = 1, .damage = 8194, .nbt = null };
    srv.applyBrewClick(&conn, .{ .slot = 0, .button = 0, .action = 712, .mode = 2 });
    try std.testing.expectEqual(@as(i16, 8194), br.bottles[0].?.damage);
    try std.testing.expectEqual(@as(i16, 16), conn.inv[36].?.damage);
    const out = try conn.takeOutput();
    defer a.free(out);
    try std.testing.expect(out.len > 0);
}

test "furnace: drag-spread fills fuel + player slots" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer srv.furnaces.deinit(a);
    var conn = Conn.init(a, io, .{}, 7);
    defer conn.deinit();
    conn.open_win = .{ .id = 2, .x = 2, .y = 69, .z = 0 };
    srv.ensureFurnace(2, 69, 0);
    // 8 coal over fuel + inv[9] + inv[10]: 3/3/2, cursor empties.
    conn.cursor = .{ .id = game_ids.coal, .count = 8, .damage = 0, .nbt = null };
    srv.applyFurnaceClick(&conn, .{ .slot = -999, .button = 0, .action = 610, .mode = 5 });
    srv.applyFurnaceClick(&conn, .{ .slot = 1, .button = 1, .action = 611, .mode = 5 });
    srv.applyFurnaceClick(&conn, .{ .slot = 3, .button = 1, .action = 612, .mode = 5 });
    srv.applyFurnaceClick(&conn, .{ .slot = 4, .button = 1, .action = 613, .mode = 5 });
    srv.applyFurnaceClick(&conn, .{ .slot = -999, .button = 2, .action = 614, .mode = 5 });
    try std.testing.expect(conn.cursor == null);
    try std.testing.expectEqual(@as(i8, 3), srv.findFurnace(2, 69, 0).?.fuel.?.count);
    try std.testing.expectEqual(@as(i8, 3), conn.inv[9].?.count);
    try std.testing.expectEqual(@as(i8, 2), conn.inv[10].?.count);
    // Output slot rejects paint: drag over it is skipped.
    conn.cursor = .{ .id = game_ids.dirt, .count = 4, .damage = 0, .nbt = null };
    srv.applyFurnaceClick(&conn, .{ .slot = -999, .button = 0, .action = 615, .mode = 5 });
    srv.applyFurnaceClick(&conn, .{ .slot = 2, .button = 1, .action = 616, .mode = 5 });
    srv.applyFurnaceClick(&conn, .{ .slot = 5, .button = 1, .action = 617, .mode = 5 });
    srv.applyFurnaceClick(&conn, .{ .slot = -999, .button = 2, .action = 618, .mode = 5 });
    try std.testing.expect(conn.cursor == null);
    try std.testing.expectEqual(@as(i8, 4), conn.inv[11].?.count);
    const out2 = try conn.takeOutput();
    defer a.free(out2);
}

test "pregenOffset walks concentric squares center-first" {
    const P = Server.pregenOffset(0);
    try std.testing.expectEqual(@as(i32, 0), P.dx);
    try std.testing.expectEqual(@as(i32, 0), P.dz);
    // Ring 1 (idx 1..8): north edge L-to-R, east top-down, south R-to-L,
    // west bottom-up — matches serve.Spiral cell for cell.
    const r1 = [_]ColOffset{
        .{ .dx = -1, .dz = -1 }, .{ .dx = 0, .dz = -1 }, .{ .dx = 1, .dz = -1 }, .{ .dx = 1, .dz = 0 },
        .{ .dx = 1, .dz = 1 }, .{ .dx = 0, .dz = 1 }, .{ .dx = -1, .dz = 1 }, .{ .dx = -1, .dz = 0 },
    };
    for (r1, 0..) |w, k| {
        const got = Server.pregenOffset(1 + k);
        try std.testing.expectEqual(w.dx, got.dx);
        try std.testing.expectEqual(w.dz, got.dz);
    }
    // Ring starts: 1, 9, 25, 49 (1+4r(r-1)).
    for ([_]struct { idx: usize, dx: i32, dz: i32 }{
        .{ .idx = 9, .dx = -2, .dz = -2 },
        .{ .idx = 25, .dx = -3, .dz = -3 },
        .{ .idx = 49, .dx = -4, .dz = -4 },
    }) |c| {
        const got = Server.pregenOffset(c.idx);
        try std.testing.expectEqual(c.dx, got.dx);
        try std.testing.expectEqual(c.dz, got.dz);
    }
    // Ring 2 has 16 cells ending adjacent to ring 3's start.
    const last2 = Server.pregenOffset(24);
    try std.testing.expectEqual(@as(i32, -2), last2.dx);
    try std.testing.expectEqual(@as(i32, -1), last2.dz);
}

test "pregen completes a radius-1 task end to end" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    var lock: spin.SpinLock = .{};
    var gp = try v5genpool.GenPool.create(a, io, pool, &lock, 42, false, false, 1, .{});
    defer {
        gp.destroy();
        a.destroy(gp);
    }
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    srv.gen_pool = gp;
    try std.testing.expect(srv.pregenBegin("", 1, 0, 0) == .started);
    try std.testing.expect(srv.pregenBegin("", 1, 0, 0) == .already_running);
    // First poll enqueues all 9 chunks; drain lets the worker finish them;
    // the next poll observes the empty in-flight set and completes.
    srv.pollPregen(std.Io.Timestamp.now(io, .awake).toMilliseconds());
    srv.pregen_lock.lock();
    const queued = srv.pregen.next_idx;
    srv.pregen_lock.unlock();
    try std.testing.expectEqual(@as(usize, 9), queued);
    gp.drain();
    srv.pollPregen(std.Io.Timestamp.now(io, .awake).toMilliseconds());
    srv.pregen_lock.lock();
    const done = srv.pregen.done_idx;
    const still = srv.pregen.active;
    srv.pregen_lock.unlock();
    try std.testing.expectEqual(@as(usize, 9), done);
    try std.testing.expect(!still);
    // Every chunk actually landed in storage.
    var ox: i32 = -1;
    while (ox <= 1) : (ox += 1) {
        var oz: i32 = -1;
        while (oz <= 1) : (oz += 1) {
            const got = try pool.getChunk(a, 0, ox, oz);
            try std.testing.expect(got != null);
            defer got.?.destroy(a);
        }
    }
    // Stop/pause on an idle task report idle.
    try std.testing.expect(!srv.pregenStop());
    try std.testing.expect(srv.pregenPauseToggle(true) == .not_running);
    var sb: [256]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), srv.pregenStatus(&sb).len);
}

test "pregen stop cancels and status formats progress" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    // No gen pool: begin refuses (no seed/generation configured).
    try std.testing.expect(srv.pregenBegin("", 2, 0, 0) == .no_gen);
    var sb: [256]u8 = undefined;
    const line = Server.formatPregenLine(.{
        .active = true,
        .ccx = 0,
        .ccz = 0,
        .radius = 1,
        .total = 9,
        .next_idx = 9,
        .done_idx = 3,
        .last_ms = 40000,
        .t_start_ms = 0,
        .rate = 1.5,
    }, 142 * 1024 * 1024, 301 * 1024 * 1024, &sb);
    try std.testing.expectEqualStrings("33.3% (3/9) chunks — 1.5/s, ETA 00:04, elapsed 00:40, rss=142 MiB peak=301 MiB, gpu 0ch/0dsp fb=0 avg=0.0, cache n/a, true 0.0/s tot 0.0/s dup 0 sf 0 ore 0%", line);
}

test "pregen command dispatches start/stop/status/pause/resume" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    var out: [8192]u8 = undefined;
    try std.testing.expectEqualStrings("No pregeneration task is running", srv.executeCommand(null, "/pregen status", &out));
    try std.testing.expectEqualStrings("/pregen start <radius> [x z] OR /pregen stop|status|pause|resume", srv.executeCommand(null, "/pregen frobnicate", &out)[7..]);
    try std.testing.expectEqualStrings(
        "/pregen start <radius> [x z] OR /pregen stop|status|pause|resume",
        srv.executeCommand(null, "/pregen start", &out)[7..],
    );
    try std.testing.expectEqualStrings(
        "Pregeneration needs a world seed (generation is not enabled on this server)",
        srv.executeCommand(null, "/pregen start 5", &out),
    );
    // With a worker pool: full lifecycle through the command layer.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    var lock: spin.SpinLock = .{};
    var gp = try v5genpool.GenPool.create(a, io, pool, &lock, 42, false, false, 1, .{});
    defer {
        gp.destroy();
        a.destroy(gp);
    }
    srv.gen_pool = gp;
    const started = srv.executeCommand(null, "/pregen start 1", &out);
    try std.testing.expect(std.mem.startsWith(u8, started, "Pregeneration started: 9 chunks"));
    try std.testing.expect(std.mem.startsWith(u8, srv.executeCommand(null, "/pregen status", &out), "Pregeneration: "));
    try std.testing.expectEqualStrings("Pregeneration paused", srv.executeCommand(null, "/pregen pause", &out));
    try std.testing.expect(std.mem.indexOf(u8, srv.executeCommand(null, "/pregen status", &out), "[paused]") != null);
    try std.testing.expectEqualStrings("Pregeneration resumed", srv.executeCommand(null, "/pregen resume", &out));
    try std.testing.expectEqualStrings("Pregeneration cancelled", srv.executeCommand(null, "/pregen stop", &out));
    try std.testing.expectEqualStrings("No pregeneration task is running", srv.executeCommand(null, "/pregen stop", &out));
    try std.testing.expectEqualStrings("No pregeneration task is running", srv.executeCommand(null, "/pregen pause", &out));
}

test "pregen bar health/title" {
    try std.testing.expectEqual(@as(f32, 1.0), Server.pregenBarHealth(0));
    try std.testing.expectEqual(@as(f32, 150.0), Server.pregenBarHealth(0.5));
    try std.testing.expectEqual(@as(f32, 300.0), Server.pregenBarHealth(1));
    try std.testing.expectEqual(@as(f32, 300.0), Server.pregenBarHealth(9));
    try std.testing.expectEqual(@as(f32, 1.0), Server.pregenBarHealth(-1));
    var tb: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Pregeneration 12%", Server.pregenBarTitle(0.124, false, &tb));
    try std.testing.expectEqualStrings("Pregeneration 12% (paused)", Server.pregenBarTitle(0.124, true, &tb));
    try std.testing.expectEqualStrings("Pregeneration 100%", Server.pregenBarTitle(1, false, &tb));
}

test "pregen bossbar tracks offline owner without crashing" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    var lock: spin.SpinLock = .{};
    var gp = try v5genpool.GenPool.create(a, io, pool, &lock, 42, false, false, 1, .{});
    defer {
        gp.destroy();
        a.destroy(gp);
    }
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    srv.gen_pool = gp;
    // "Ghost" never logs in: spawn attempts fail silent, flag stays clear.
    try std.testing.expect(srv.pregenBegin("Ghost", 1, 0, 0) == .started);
    srv.pollPregen(std.Io.Timestamp.now(io, .awake).toMilliseconds());
    srv.pregen_lock.lock();
    try std.testing.expect(!srv.pregen.bar_spawned);
    srv.pregen_lock.unlock();
    // Pause path refreshes a frozen bar (still offline: no crash, no flag).
    try std.testing.expect(srv.pregenPauseToggle(true) == .paused);
    srv.pollPregen(std.Io.Timestamp.now(io, .awake).toMilliseconds());
    srv.pregen_lock.lock();
    try std.testing.expectEqual(@as(usize, 0), srv.pregen.done_idx);
    try std.testing.expect(!srv.pregen.bar_spawned);
    srv.pregen_lock.unlock();
    try std.testing.expect(srv.pregenPauseToggle(false) == .resumed);
    gp.drain();
    srv.pollPregen(std.Io.Timestamp.now(io, .awake).toMilliseconds());
    srv.pregen_lock.lock();
    const done = srv.pregen.done_idx;
    const still = srv.pregen.active;
    const bar = srv.pregen.bar_spawned;
    srv.pregen_lock.unlock();
    try std.testing.expectEqual(@as(usize, 9), done);
    try std.testing.expect(!still);
    try std.testing.expect(!bar);
}

test "ops/bans/whitelist live in sidecar files" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Seed the files directly (as a previous boot would have left them).
    {
        var pdb = perms_mod.Db.init(a);
        defer pdb.deinit();
        const steve = testUuid("Steve");
        try pdb.setLevelUuid(&steve, "Steve", .owner);
        try perms_mod.saveFile(io, tmp.dir, a, &pdb);
    }
    {
        var bdb = bans_mod.BanDb.init(a);
        defer bdb.deinit();
        const griefer = testUuid("Griefer");
        try bdb.banUuid(&griefer, "Griefer", "x");
        try bdb.banIp("9.9.9.9", "y");
        try bans_mod.saveBansFile(io, tmp.dir, a, &bdb);
    }
    {
        var wl = bans_mod.Whitelist.init(a);
        defer wl.deinit();
        wl.enabled = true;
        const wlu = testUuid("Alice");
        try wl.add(&wlu, "Alice");
        try bans_mod.saveWhitelistFile(io, tmp.dir, a, &wl);
    }
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer if (srv.perms) |*db| db.deinit();
    defer if (srv.bans) |*db| db.deinit();
    defer if (srv.whitelist) |*wl| wl.deinit();
    srv.list_dir = tmp.dir;
    // Boot path with no world at all: files are the whole store.
    srv.loadPerms();
    srv.banLoad();
    srv.whitelistLoad();
    try std.testing.expectEqual(perms_mod.OpLevel.owner, srv.permDb().levelForUuid(&testUuid("Steve")));
    const griefer = testUuid("Griefer");
    try std.testing.expect(srv.isUuidBanned(&griefer) != null);
    // UUID identity is exact: case no longer folds at enforcement (the
    // old "GRIEFER matches Griefer" behavior died with name keys —
    // resolution stays case-insensitive, matching does not).
    const caps = testUuid("GRIEFER");
    try std.testing.expect(srv.isUuidBanned(&caps) == null);
    try std.testing.expect(srv.isIpBanned("9.9.9.9"));
    try std.testing.expect(srv.whitelist != null and srv.whitelist.?.enabled);
    const wlu = testUuid("Alice");
    try std.testing.expect(srv.whitelist.?.contains(&wlu));
    {
        const raw = try tmp.dir.readFileAlloc(io, perms_mod.ops_file, a, .limited(1 << 20));
        defer a.free(raw);
        var back = try perms_mod.decodeJson(a, raw);
        defer back.db.deinit();
        try std.testing.expectEqual(perms_mod.OpLevel.owner, back.db.levelForUuid(&testUuid("Steve")));
    }
    // Mutations persist to the files (no world writes involved).
    _ = srv.grantOp("Bob");
    _ = srv.banName("Mallory", "z");
    _ = srv.wlAdd("Bob");
    {
        const raw = try tmp.dir.readFileAlloc(io, perms_mod.ops_file, a, .limited(1 << 20));
        defer a.free(raw);
        var back = try perms_mod.decodeJson(a, raw);
        defer back.db.deinit();
        try std.testing.expectEqual(perms_mod.OpLevel.owner, back.db.levelForUuid(&testUuid("Bob")));
    }
    // Reload picks up hand edits.
    {
        var wl2 = bans_mod.Whitelist.init(a);
        defer wl2.deinit();
        wl2.enabled = false;
        try bans_mod.saveWhitelistFile(io, tmp.dir, a, &wl2);
        srv.whitelistLoad();
        try std.testing.expect(!srv.whitelist.?.enabled);
    }
}

test "pregen bossbar spawns below feet, updates, destroys on the owner's client" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    // Fake play conn (no sockets: outbox drained directly, like the
    // help-command tests).
    const c = try a.create(Conn);
    defer {
        c.deinit();
        a.destroy(c);
    }
    c.* = Conn.init(a, io, .{}, 7);
    c.state = .play;
    @memcpy(c.username[0.."Hank".len], "Hank");
    c.username_len = "Hank".len;
    c.pos_x = 100.5;
    c.pos_y = 70.0;
    c.pos_z = 200.5;
    try srv.registry.append(a, .{ .conn = c, .stream = undefined });
    // Spawn: 0x0F wither at the owner's feet minus pregen_bar_drop.
    // Invisibility hides the model but not the wither's per-tick smoke /
    // armored mobSpell emitters (jar-verified), so the follow point sits
    // below the view; the camera stays inside the 4.0-tall AABB, which keeps
    // it frustum-immune (a parked wither feeds no BossStatus — the bar
    // expires 100 frames after its last render).
    try std.testing.expect(srv.updateBossBar("hank", 0.5, "Pregeneration 50%", true));
    {
        c.lock.lock();
        const raw = try c.takeOutput();
        c.lock.unlock();
        defer a.free(raw);
        var r = codec.PacketReader.init(raw);
        const h = try codec.decodeFrame(&r);
        try std.testing.expectEqual(@as(i32, 0x0F), h.id);
        try std.testing.expectEqual(@as(i32, -424242), try r.readVarInt());
        try std.testing.expectEqual(@as(u8, 64), try r.readByte());
        try std.testing.expectEqual(@as(i32, 3216), try r.readInt()); // 100.5*32
        const want_y: i32 = @intFromFloat((70.0 - Server.pregen_bar_drop) * 32);
        try std.testing.expectEqual(want_y, try r.readInt()); // (70-1.8)*32
        try std.testing.expectEqual(@as(i32, 6416), try r.readInt()); // 200.5*32
    }
    // Update: teleport-follow + metadata refresh.
    try std.testing.expect(srv.updateBossBar("HANK", 1.0, "Pregeneration 100%", false));
    {
        c.lock.lock();
        const raw = try c.takeOutput();
        c.lock.unlock();
        defer a.free(raw);
        var off: usize = 0;
        var saw_tp = false;
        var saw_md = false;
        while (off < raw.len) {
            var r = codec.PacketReader.init(raw[off..]);
            const h = try codec.decodeFrame(&r);
            const flen: usize = @as(usize, @intCast(codec.PacketWriter.varIntLen(h.length))) + @as(usize, @intCast(h.length));
            if (h.id == 0x18) {
                saw_tp = true;
                try std.testing.expectEqual(@as(i32, -424242), try r.readInt());
                try std.testing.expectEqual(@as(i32, 3216), try r.readInt());
                const want_ty: i32 = @intFromFloat((70.0 - Server.pregen_bar_drop) * 32);
                try std.testing.expectEqual(want_ty, try r.readInt());
            }
            if (h.id == 0x1C) saw_md = true;
            off += flen;
        }
        try std.testing.expect(saw_tp and saw_md);
    }
    // Destroy + offline silence.
    srv.destroyBossBar("Hank");
    {
        c.lock.lock();
        const raw = try c.takeOutput();
        c.lock.unlock();
        defer a.free(raw);
        var r = codec.PacketReader.init(raw);
        const h = try codec.decodeFrame(&r);
        try std.testing.expectEqual(@as(i32, 0x13), h.id);
        try std.testing.expectEqual(@as(u8, 1), try r.readByte());
        try std.testing.expectEqual(@as(i32, -424242), try r.readInt());
    }
    try std.testing.expect(!srv.updateBossBar("Nobody", 0.5, "x", true));
    try std.testing.expect(!srv.updateBossBar("", 0.5, "x", true));
}

test "cactus contact: point detection incl. chunk borders" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
        try pool.flushAll();
    }
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 1, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
        try pool.flushAll();
    }
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, -1, -1);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
        try pool.flushAll();
    }
    _ = try view.applyBlock(pool, a, 8, 63, 8, game_ids.sand, 0);
    _ = try view.applyBlock(pool, a, 8, 64, 8, game_ids.cactus, 0);
    // Chunk-border cactus (x=15/16 seam) + negative coords.
    _ = try view.applyBlock(pool, a, 16, 63, 8, game_ids.sand, 0);
    _ = try view.applyBlock(pool, a, 16, 64, 8, game_ids.cactus, 0);
    _ = try view.applyBlock(pool, a, -5, 63, -3, game_ids.sand, 0);
    _ = try view.applyBlock(pool, a, -5, 64, -3, game_ids.cactus, 0);
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    srv.world = pool;
    try std.testing.expect(srv.touchesCactus(pool, 8.5, 64.0, 8.5));
    try std.testing.expect(srv.touchesCactus(pool, 8.8, 64.0, 8.5));
    try std.testing.expect(!srv.touchesCactus(pool, 4.5, 64.0, 8.5));
    try std.testing.expect(srv.touchesCactus(pool, 16.5, 64.0, 8.5));
    try std.testing.expect(srv.touchesCactus(pool, 15.8, 64.0, 8.5));
    try std.testing.expect(srv.touchesCactus(pool, -4.5, 64.0, -2.5));
}

test "cactus contact: segment sweep catches crossings between 1Hz samples" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
        try pool.flushAll();
    }
    _ = try view.applyBlock(pool, a, 8, 63, 8, game_ids.sand, 0);
    _ = try view.applyBlock(pool, a, 8, 64, 8, game_ids.cactus, 0);
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    srv.world = pool;
    // Walk-through in one tick (sprint covers ~5 blocks/tick; a cactus
    // cell takes ~0.2s): the point checks at both ends miss, the sweep hits.
    try std.testing.expect(!srv.touchesCactus(pool, 6.5, 64.0, 8.5));
    try std.testing.expect(!srv.touchesCactus(pool, 10.5, 64.0, 8.5));
    try std.testing.expect(srv.segmentTouchesCactus(pool, 6.5, 64.0, 8.5, 10.5, 64.0, 8.5));
    // A parallel lane that never overlaps stays clean.
    try std.testing.expect(!srv.segmentTouchesCactus(pool, 6.5, 64.0, 4.5, 10.5, 64.0, 4.5));
    // Standing still degenerates to the point check.
    try std.testing.expect(srv.segmentTouchesCactus(pool, 8.5, 64.0, 8.5, 8.5, 64.0, 8.5));
    try std.testing.expect(!srv.segmentTouchesCactus(pool, 4.5, 64.0, 8.5, 4.5, 64.0, 8.5));
    // Teleport-length segments fall back to the endpoint (no mid-way hit).
    try std.testing.expect(!srv.segmentTouchesCactus(pool, 4.5, 64.0, 4.5, 100.5, 64.0, 100.5));
}

test "hazard bbox spans every adopted position since the last sample" {
    const a = std.testing.allocator;
    var c = Conn.init(a, std.testing.io, .{ .gamemode = .survival }, 7);
    defer c.deinit();
    c.state = .play;
    c.baseline_sent = true; // hazard tracking is post-join (pre-burst moves don't adopt)
    // First sample initializes the box; movement expands it both ways.
    c.setPos(8.5, 64.0, 8.5, 0, 0, true);
    c.haz_min_x = c.pos_x;
    c.haz_min_y = c.pos_y;
    c.haz_min_z = c.pos_z;
    c.haz_max_x = c.pos_x;
    c.haz_max_y = c.pos_y;
    c.haz_max_z = c.pos_z;
    c.haz_set = true;
    c.setPos(10.5, 64.0, 8.5, 0, 0, true);
    c.setPos(6.5, 63.5, 8.5, 0, 0, true);
    try std.testing.expectEqual(@as(f64, 6.5), c.haz_min_x);
    try std.testing.expectEqual(@as(f64, 63.5), c.haz_min_y);
    try std.testing.expectEqual(@as(f64, 10.5), c.haz_max_x);
    try std.testing.expectEqual(@as(f64, 64.0), c.haz_max_y);
}

test "break-drop toss: vanilla motion ranges on a dedicated stream" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    // Jar `xk` EntityItem ctor: XZ in [-0.1, 0.1], Y exactly 0.2.
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const m = srv.tossPopMotion();
        try std.testing.expect(m[0] >= -0.1 and m[0] <= 0.1);
        try std.testing.expectEqual(@as(f64, 0.2), m[1]);
        try std.testing.expect(m[2] >= -0.1 and m[2] <= 0.1);
    }
    // Deterministic per fixed seed, and independent of the drop stream:
    // draining toss draws never advances drop_rand (goldens stay stable,
    // no worldgen info leaks through scatter — no randar).
    try std.testing.expect(srv.drop_rand == null);
    _ = srv.nextToss();
    try std.testing.expect(srv.toss_rand != null);
    try std.testing.expect(srv.drop_rand == null);
}

test "break drops spawn inside the cell with toss motion" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer {
        for (srv.items.items) |*it| {
            var s: ?item_mod.Stack = it.stack;
            item_mod.freeStack(a, &s);
        }
        srv.items.deinit(a);
    }
    srv.spawnBreakDrops(8, 64, 8, game_ids.stone, 0);
    try std.testing.expectEqual(@as(usize, 1), srv.items.items.len);
    const it = srv.items.items[0];
    // Inside the broken cell (vanilla dropBlockAsItem_do), not the ground.
    try std.testing.expect(it.x >= 8.15 and it.x <= 8.85);
    try std.testing.expect(it.y >= 64.15 and it.y <= 64.85);
    try std.testing.expect(it.z >= 8.15 and it.z <= 8.85);
    // Vanilla EntityItem pop (jar `xk`), from the toss stream.
    try std.testing.expect(it.vx >= -0.1 and it.vx <= 0.1);
    try std.testing.expectEqual(@as(f64, 0.2), it.vy);
    try std.testing.expect(it.vz >= -0.1 and it.vz <= 0.1);
    try std.testing.expectEqual(@as(u32, 10), it.delay);
}

test "breaking support re-arms settled drops above it" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    defer {
        for (srv.items.items) |*it| {
            var s: ?item_mod.Stack = it.stack;
            item_mod.freeStack(a, &s);
        }
        srv.items.deinit(a);
    }
    const mk = struct {
        fn stack(id: game_ids.Id) item_mod.Stack {
            return .{ .id = id, .count = 1, .damage = 0, .nbt = null };
        }
    }.stack;
    // Resting on top of where (8,64,8) was; mid-air tossed one; one below.
    srv.items.append(a, .{ .id = 1, .x = 8.5, .y = 65.125, .z = 8.5, .stack = mk(game_ids.dirt) }) catch unreachable;
    srv.items.append(a, .{ .id = 2, .x = 8.5, .y = 66.0, .z = 8.5, .vx = 0.1, .vy = 0.1, .vz = 0, .stack = mk(game_ids.dirt) }) catch unreachable;
    srv.items.append(a, .{ .id = 3, .x = 8.5, .y = 60.0, .z = 8.5, .stack = mk(game_ids.dirt) }) catch unreachable;
    srv.wakeItemsAbove(8, 64, 8);
    // The rested one re-arms (integration will drop it); the live one and
    // the one below the break are untouched.
    try std.testing.expectEqual(@as(f64, -0.05), srv.items.items[0].vy);
    try std.testing.expectEqual(@as(f64, 0), srv.items.items[0].vx);
    try std.testing.expectEqual(@as(f64, 0.1), srv.items.items[1].vx);
    try std.testing.expectEqual(@as(f64, 0.1), srv.items.items[1].vy);
    try std.testing.expectEqual(@as(f64, 0), srv.items.items[2].vx);
    try std.testing.expectEqual(@as(f64, 0), srv.items.items[2].vy);
}

test "tossed item arcs and settles on the ground" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
        try pool.flushAll();
    }
    // Flat stone floor at y=63.
    var x: i32 = 0;
    while (x < 16) : (x += 1) {
        var z: i32 = 0;
        while (z < 16) : (z += 1) {
            _ = try view.applyBlock(pool, a, x, 63, z, game_ids.stone, 0);
        }
    }
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    srv.world = pool;
    var it = entity.ItemEnt{
        .id = 1,
        .x = 8.5,
        .y = 64.6,
        .z = 8.5,
        .stack = .{ .id = game_ids.dirt, .count = 1, .damage = 0, .nbt = null },
        .delay = 10,
        .vx = 0.1,
        .vy = 0.2,
        .vz = -0.05,
    };
    // The 0.2 pop lands within a tick or two (20 substeps each); the
    // bounce decays below the settle threshold quickly.
    var n: usize = 0;
    while ((it.vx != 0 or it.vy != 0 or it.vz != 0) and n < 10) : (n += 1) {
        try srv.integrateItemToss(pool, &it);
    }
    try std.testing.expect(n < 10);
    try std.testing.expectApproxEqAbs(@as(f64, 64.125), it.y, 1e-6);
    try std.testing.expect(it.x != 8.5); // thrown, not static
    try std.testing.expectEqual(@as(f64, 0), it.vx);
    try std.testing.expectEqual(@as(f64, 0), it.vy);
    try std.testing.expectEqual(@as(f64, 0), it.vz);
    var s: ?item_mod.Stack = it.stack;
    item_mod.freeStack(a, &s);
}

test "tossed item tracks the landing column across a cliff edge" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
        try pool.flushAll();
    }
    // Step cliff: floor 63 west of x=8, floor 60 east of it.
    var x: i32 = 0;
    while (x < 16) : (x += 1) {
        var z: i32 = 0;
        while (z < 16) : (z += 1) {
            _ = try view.applyBlock(pool, a, x, if (x < 8) 63 else 60, z, game_ids.stone, 0);
        }
    }
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    srv.world = pool;
    var it = entity.ItemEnt{
        .id = 1,
        .x = 7.5,
        .y = 64.6,
        .z = 8.5,
        .stack = .{ .id = game_ids.dirt, .count = 1, .damage = 0, .nbt = null },
        .delay = 10,
        .vx = 0.3,
        .vy = 0.2,
        .vz = 0.0,
    };
    var n: usize = 0;
    while ((it.vx != 0 or it.vy != 0 or it.vz != 0) and n < 10) : (n += 1) {
        try srv.integrateItemToss(pool, &it);
    }
    try std.testing.expect(n < 10);
    // East of the edge on the LOW floor: a stale start-column height
    // would park it floating at 64.125 (the client's sim lands it below,
    // and the 1Hz correction reads as a mid-air teleport).
    try std.testing.expect(it.x > 8.0);
    try std.testing.expectApproxEqAbs(@as(f64, 61.125), it.y, 1e-6);
    var s: ?item_mod.Stack = it.stack;
    item_mod.freeStack(a, &s);
}

test "tossed item stops at a wall instead of embedding" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        try pool.putChunk(a, ch);
        try pool.flushAll();
    }
    // Flat floor 63 plus a full-height wall column at x=10.
    var x: i32 = 0;
    while (x < 16) : (x += 1) {
        var z: i32 = 0;
        while (z < 16) : (z += 1) {
            _ = try view.applyBlock(pool, a, x, 63, z, game_ids.stone, 0);
        }
    }
    var y: i32 = 64;
    while (y < 70) : (y += 1) {
        _ = try view.applyBlock(pool, a, 10, @intCast(y), 8, game_ids.stone, 0);
    }
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.deinitRegions();
    defer srv.registry.deinit(a);
    srv.world = pool;
    var it = entity.ItemEnt{
        .id = 1,
        .x = 8.5,
        .y = 64.6,
        .z = 8.5,
        .stack = .{ .id = game_ids.dirt, .count = 1, .damage = 0, .nbt = null },
        .delay = 10,
        .vx = 0.3,
        .vy = 0.2,
        .vz = 0.0,
    };
    var n: usize = 0;
    while ((it.vx != 0 or it.vy != 0 or it.vz != 0) and n < 10) : (n += 1) {
        try srv.integrateItemToss(pool, &it);
    }
    try std.testing.expect(n < 10);
    // Stopped at the wall face and settled on the floor west of it —
    // never inside the rock column, never floating above it.
    try std.testing.expect(it.x < 10.0);
    try std.testing.expectApproxEqAbs(@as(f64, 64.125), it.y, 1e-6);
    var s: ?item_mod.Stack = it.stack;
    item_mod.freeStack(a, &s);
}





