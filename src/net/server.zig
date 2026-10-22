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

const std = @import("std");
const Conn = @import("conn.zig").Conn;
const Config = @import("conn.zig").Config;
const Action = @import("conn.zig").Action;
const AttackEvent = @import("conn.zig").AttackEvent;
const QDropEvent = @import("conn.zig").QDropEvent;
const FurnaceClick = @import("conn.zig").FurnaceClick;
const TableClose = @import("conn.zig").TableClose;
const BlockEvent = @import("conn.zig").BlockEvent;
const furnace_mod = @import("../sim/furnace.zig");
const smelting_mod = @import("../sim/smelting.zig");
const codec = @import("codec.zig");
const view = @import("../sim/view.zig");
const shard_mod = @import("../world/shard.zig");
const player_db = @import("../sim/players.zig");
const item_mod = @import("../item.zig");
const perms_mod = @import("../sim/permissions.zig");const spin = @import("../sim/spin.zig");
const drops_mod = @import("../sim/drops.zig");
const java_random = @import("../worldgen/rng/java_random.zig");
const packets = @import("../proto/v5/packets.zig");
const ids = @import("../proto/v5/ids.zig");
const entity = @import("../sim/entity.zig");
const v5gen = @import("../worldgen/v5/gen.zig");
const v5serve = @import("../worldgen/v5/serve.zig");
const v5genpool = @import("../worldgen/v5/genpool.zig");
const game_ids = @import("../ids.zig");
const wire = @import("../proto/v5/wire_ids.zig");
const tp_mod = @import("../cmd/tp.zig");
const cmd_spec = @import("../cmd/spec.zig");
const cmd_data = @import("../proto/v5/cmd_data.zig");
const bans_mod = @import("../sim/bans.zig");
const scoreboard_mod = @import("../sim/scoreboard.zig");

/// Handshake/login must complete within this window (anti-slowloris).
pub const login_timeout_ms: i64 = 30000;

pub const RegistryEntry = struct {
    conn: *Conn,
    stream: std.Io.net.Stream,
};

pub const Server = struct {
    net: std.Io.net.Server,
    io: std.Io,
    config: Config,
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
    view_distance: u8 = 4,
    /// Allocator for the registry list. Set by serveForever/tests.
    gpa: std.mem.Allocator = undefined,
    registry: std.ArrayList(RegistryEntry) = .empty,
    reg_lock: spin.SpinLock = .{},
    /// Serializes chunk read-modify-write cycles across connections.
    /// Never held together with any conn.lock (strict one-lock-at-a-time).
    world_lock: spin.SpinLock = .{},
    /// Global mob list (ticker-owned; guarded by ent_lock).
    entities: std.ArrayList(entity.Mob) = .empty,
    ent_lock: spin.SpinLock = .{},
    /// Global item-entity list (break drops + Q-drops; guarded by ent_lock).
    items: std.ArrayList(entity.ItemEnt) = .empty,
    /// Furnace tile entities (server-owned; in-memory only, lost on restart —
    /// no chunk unloading exists so lifetime matches the loaded world).
    /// Guarded by furn_lock (leaf; furn is never held while acquiring conn,
    /// so nesting conn->furn is deadlock-free by construction).
    furnaces: std.ArrayList(FurnaceEnt) = .empty,
    furn_lock: spin.SpinLock = .{},
    /// Gameplay RNG stream (block-drop quantities/offsets, vanilla draw order).
    /// Lazy-seeded from drop_seed under rand_lock; never held with other locks.
    drop_rand: ?java_random.JavaRandom = null,
    rand_lock: spin.SpinLock = .{},
    /// Seed for the gameplay stream (world seed from the config file).
    drop_seed: i64 = 0,
    pig_spawned: bool = false,
    /// Ticks until the demo pig respawns after death (tickOnce is 1Hz).
    /// Set on pig death; first spawn is immediate via pig_spawned.
    pig_cooldown: u32 = 0,
    world_age: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    time_of_day: std.atomic.Value(i64) = std.atomic.Value(i64).init(6000),
    /// Announced play conns, for the server list ping. Bumped in
    /// announceJoin (once per conn, guarded by announced) and dropped in
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
    /// World difficulty 0-3 (peaceful..hard). New logins inherit it.
    difficulty: u8 = 1,
    /// Default gamemode for first-time logins (0 survival, 1 creative, 2 adventure).
    default_gamemode: u8 = 1,
    /// Weather: raining/thundering flags + remaining ticks (0 = hold state).
    raining: bool = false,
    thundering: bool = false,
    rain_time: u32 = 0,
    thunder_time: u32 = 0,
    /// Idle kick threshold in minutes (0 = disabled, vanilla default).
    idle_timeout_min: u32 = 0,
    /// Master switch for periodic saves (`/save-on`, `/save-off`).
    autosave: bool = true,
    /// Debug profiling window (`/debug start` sets both).
    debug_start_ms: ?i64 = null,
    debug_ticks: u64 = 0,
    /// World spawn for first-time logins (`/setworldspawn`).
    world_spawn: [3]i32 = .{ 8, 64, 8 },
    /// Set once /setworldspawn runs: fresh logins keep the world spawn
    /// instead of re-running the worldgen spawn search.
    world_spawn_set: bool = false,
    /// Nine vanilla gamerules (vanilla defaults; see cmd_data.gamerules).
    gamerules: [9]bool = .{ true, true, false, true, true, true, true, true, true },
    /// Bans + whitelist (lazy-init alongside perms; own leaf lock).
    bans: ?bans_mod.BanDb = null,
    ban_lock: spin.SpinLock = .{},
    whitelist: ?bans_mod.Whitelist = null,
    wl_lock: spin.SpinLock = .{},
    /// Scoreboard (lazy-init; own leaf lock).
    scoreboard: ?scoreboard_mod.Scoreboard = null,
    sb_lock: spin.SpinLock = .{},
    /// Serializes the scalar command state above (leaf lock: never held
    /// with conn or registry locks — copy out, release, then touch conns).
    state_lock: spin.SpinLock = .{},
    /// Autosave cadence in ticks (5 min at 1Hz).
    pub const autosave_ticks: u64 = 300;
    /// Anti-DoS cap on live item entities (snapshot arrays are fixed-size).
    pub const max_items: usize = 256;

    pub fn bind(io: std.Io, port: u16, config: Config) !Server {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        var srv = Server{ .net = try addr.listen(io, .{}), .io = io, .config = config };
        srv.world_spawn = .{ config.spawn_x, config.spawn_y, config.spawn_z };
        return srv;
    }

    pub fn deinit(self: *Server) void {
        self.net.deinit(self.io);
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

    /// Flush one conn's queued output to its stream. Lock-free except the
    /// conn's own locks; safe to call while holding no locks.
    fn flushEntry(e: RegistryEntry, io: std.Io) void {
        e.conn.lock.lock();
        const pending = e.conn.takeOutput() catch {
            e.conn.lock.unlock();
            return;
        };
        e.conn.lock.unlock();
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

    fn writeFramed(e: RegistryEntry, io: std.Io, framed: []const u8) void {
        e.conn.wlock.lock();
        defer e.conn.wlock.unlock();
        var wbuf: [4096]u8 = undefined;
        var w = e.stream.writer(io, &wbuf);
        w.interface.writeAll(framed) catch return;
        w.interface.flush() catch return;
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
    pub fn announceJoin(self: *Server, conn: *Conn, stream: std.Io.net.Stream) !void {
        var others: [256]RegistryEntry = undefined;
        const snap = self.snapshot(&others);
        defer releaseSnap(snap);
        // newcomer learns existing players
        var nb: [64]u8 = undefined;
        for (snap) |e| {
            if (e.conn == conn) continue;
            e.conn.lock.lock();
            const nm = e.conn.username[0..e.conn.username_len];
            const ping = e.conn.ping_ms.load(.acquire);
            e.conn.lock.unlock();
            const f = try packets.framePlayerListItem(nm, true, ping, &nb);
            conn.lock.lock();
            conn.queueFramed(f) catch {};
            const pending = conn.takeOutput() catch {
                conn.lock.unlock();
                continue;
            };
            conn.lock.unlock();
            writeFramed(.{ .conn = conn, .stream = stream }, self.io, pending);
            conn.allocator.free(pending);
        }
        // existing players learn the newcomer
        var jb: [64]u8 = undefined;
        const jf = try packets.framePlayerListItem(
            conn.username[0..conn.username_len],
            true,
            conn.ping_ms.load(.acquire),
            &jb,
        );
        for (snap) |e| {
            if (e.conn == conn) continue;
            e.conn.lock.lock();
            e.conn.queueFramed(jf) catch {
                e.conn.lock.unlock();
                continue;
            };
            const pending = e.conn.takeOutput() catch {
                e.conn.lock.unlock();
                continue;
            };
            e.conn.lock.unlock();
            writeFramed(e, self.io, pending);
            e.conn.allocator.free(pending);
        }
        // Count once per conn: unregister drops iff announced, so these pair
        // exactly even if announceJoin is ever re-entered.
        if (!conn.announced) {
            conn.announced = true;
            _ = self.play_count.fetchAdd(1, .release);
        }
    }

    /// Broadcast a chat line to every registered play conn (including sender;
    /// vanilla echoes). Caller holds no locks.
    pub fn broadcastChat(self: *Server, json: []const u8) void {
        var cb: [512]u8 = undefined;
        const f = packets.frameChat(json, &cb) catch return;
        var batch: [256]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            e.conn.lock.lock();
            if (e.conn.state != .play or e.conn.dead) {
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

    /// Remove + broadcast leave (iff announced) + wait for temp refs + destroy.
    /// No locks held on return.
    pub fn unregister(self: *Server, conn: *Conn) void {
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
            // Paired with the fetchAdd in announceJoin (guarded by the same flag).
            _ = self.play_count.fetchSub(1, .release);
            var others: [256]RegistryEntry = undefined;
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
            const pending = e.conn.takeOutput() catch {
                e.conn.lock.unlock();
                continue;
            };
            e.conn.lock.unlock();
            writeFramed(e, self.io, pending);
            e.conn.allocator.free(pending);
        }
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
        const data = player_db.load(pool, self.gpa, name) catch return false;
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
        conn.selected = d.selected;
        conn.config.gamemode = d.gamemode;
        conn.click_seq = 0;
        conn.click_seen = false;
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
        conn.lock.unlock();
        defer player_db.freeData(self.gpa, &d);
        // Stale-session guard: a newer login for this name owns the row
        // now — drop this snapshot instead of overwriting it (quit/rejoin
        // races, ghost autosaves). Leaf-lock read, no nesting.
        if (!self.saveEpochCurrent(d.username[0..d.username_len], epoch)) return;
        self.world_lock.lock();
        defer self.world_lock.unlock();
        player_db.save(pool, name, &d) catch {};
    }

    /// Persist every logged-in player (disconnect path calls savePlayer per
    /// conn; this is the periodic + save-all + stop path). One world_lock
    /// for the batch; per-conn locks taken one at a time, never nested.
    pub fn saveAllPlayers(self: *Server) usize {
        var batch: [256]RegistryEntry = undefined;
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

    /// Lazy permission matrix (allocator = server gpa). Caller need hold no
    /// locks; the matrix has its own leaf lock.
    fn permDb(self: *Server) *perms_mod.Db {
        self.perm_lock.lock();
        defer self.perm_lock.unlock();
        if (self.perms == null) self.perms = perms_mod.Db.init(self.gpa);
        return &self.perms.?;
    }

    /// Gate: deny-match wins, then grant-match, then level gate. Unknown
    /// commands fail closed (same reply as denied — no oracle). Console
    /// bypasses the matrix entirely.
    fn commandAllowed(self: *Server, sender: ?*Conn, desc: *const perms_mod.Command) bool {
        if (sender == null) return true;
        const c = sender.?;
        c.lock.lock();
        const name = c.username[0..c.username_len];
        const has_name = c.username_len > 0;
        c.lock.unlock();
        if (!has_name) return false;
        self.perm_lock.lock();
        defer self.perm_lock.unlock();
        if (self.perms) |*db| return db.allows(name, desc.node, desc.min_level);
        return perms_mod.DEFAULT_LEVEL >= desc.min_level;
    }

    /// Persist the matrix (single row). Encode under perm_lock, put under
    /// world_lock — one at a time, never nested (matches player rows).
    pub fn savePerms(self: *Server) void {
        const pool = self.world orelse return;
        self.perm_lock.lock();
        const enc = if (self.perms) |*db| perms_mod.encode(pool.allocator, db) catch null else null;
        self.perm_lock.unlock();
        if (enc) |e| {
            defer pool.allocator.free(e);
            self.world_lock.lock();
            defer self.world_lock.unlock();
            pool.put(perms_mod.perm_key, e) catch {};
        }
    }

    /// Load the matrix at boot (single-threaded; no locks needed). Corrupt
    /// rows fail closed to an empty matrix (logged; the next mutation
    /// overwrites the bad row).
    pub fn loadPerms(self: *Server) void {
        const pool = self.world orelse return;
        const loaded = perms_mod.load(pool, self.gpa) catch |err| blk: {
            std.log.warn("permissions row unreadable ({}) — starting empty", .{err});
            break :blk null;
        };
        if (loaded) |db| {
            self.perm_lock.lock();
            defer self.perm_lock.unlock();
            if (self.perms) |*old| old.deinit();
            self.perms = db;
        }
    }

    /// Grant level 4 to a validated name (bootstrap + /op path helper).
    /// Persists immediately. Name validity is the caller's job.
    pub fn grantOp(self: *Server, name: []const u8) void {
        _ = self.permDb();
        self.perm_lock.lock();
        self.permsDbLocked().setLevel(name, 4) catch {};
        self.perm_lock.unlock();
        self.savePerms();
    }

    // ------------------------------------------------------------------
    // Command backend: the version seam. Commands in src/cmd/ are
    // version-agnostic and must NEVER touch packets, wire ids, or chunk
    // streaming directly — everything version-specific funnels through
    // these methods, so a future protocol version only needs a new set
    // of them while every command file is reused unchanged.
    // ------------------------------------------------------------------

    /// /help body: page `page` (1-based, 7 entries) of the usages the
    /// sender may run (console sees everything). Vanilla header/footer.
    pub fn helpText(self: *Server, sender: ?*Conn, page: i32, out: []u8) []const u8 {
        var list: [64]*const perms_mod.Command = undefined;
        var n: usize = 0;
        for (&perms_mod.commands) |*d| {
            const ok = if (sender == null) true else self.commandAllowed(sender, d);
            if (!ok or n >= list.len) continue;
            list[n] = d;
            n += 1;
        }
        const pages: i32 = @intCast((n + 6) / 7);
        const p = @min(@max(page, 1), @max(pages, 1));
        var ow: usize = 0;
        ow += (std.fmt.bufPrint(out[ow..], "--- Showing help page {d} of {d} (/help <page>) ---\n", .{ p, @max(pages, 1) }) catch return "Commands: /help").len;
        const start: usize = @intCast((p - 1) * 7);
        const end: usize = @min(start + 7, n);
        for (list[start..end]) |d| {
            ow += (std.fmt.bufPrint(out[ow..], "{s}\n", .{d.usage()}) catch break).len;
        }
        ow += (std.fmt.bufPrint(out[ow..], "Tip: Use the <tab> key while typing a command to auto-complete the command or its arguments", .{}) catch return out[0..ow]).len;
        return out[0..ow];
    }

    /// /help <command>: that command's usage, or a not-found error.
    pub fn helpCommand(self: *Server, sender: ?*Conn, name: []const u8, out: []u8) []const u8 {
        for (&perms_mod.commands) |*d| {
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
        var sname: [16]u8 = undefined;
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
        var batch: [256]RegistryEntry = undefined;
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
            const nm = e.conn.username[0..e.conn.username_len];
            e.conn.lock.unlock();
            if (!play) continue;
            self.perm_lock.lock();
            const can = if (self.perms) |*db| db.allows(nm, def.node, def.min_level) else perms_mod.DEFAULT_LEVEL >= def.min_level;
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
        var batch: [256]RegistryEntry = undefined;
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

    pub fn maxPlayers(self: *Server) u8 {
        return self.config.max_players;
    }

    pub fn setTimeOfDay(self: *Server, v: i64) void {
        self.time_of_day.store(v, .release);
    }

    pub fn getTimeOfDay(self: *Server) i64 {
        return self.time_of_day.load(.acquire);
    }

    /// Snapshot-free play roster: copies online names under each conn's
    /// lock (registry lock held throughout, so unregister can't destroy
    /// a conn mid-copy). Returns the count.
    pub fn playNames(self: *Server, names: [][16]u8, lens: []u8) usize {
        self.reg_lock.lock();
        defer self.reg_lock.unlock();
        var n: usize = 0;
        for (self.registry.items) |e| {
            if (n >= names.len or n >= lens.len) break;
            e.conn.lock.lock();
            const play = e.conn.state == .play;
            if (play) {
                @memcpy(names[n][0..e.conn.username_len], e.conn.username[0..e.conn.username_len]);
                lens[n] = @intCast(e.conn.username_len);
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

    /// Strip all nodes from a player (keeps level). Used by /deop.
    pub fn deopPlayer(self: *Server, name: []const u8) void {
        self.perm_lock.lock();
        if (self.perms) |*db| db.clearPlayer(name);
        self.perm_lock.unlock();
        self.savePerms();
    }

    /// Login-name charset (single source; mirrors conn.zig validation).
    pub fn validName(self: *Server, name: []const u8) bool {
        _ = self;
        return Conn.validPlayerName(name);
    }

    /// Permission-node charset (single source; see sim/permissions.zig).
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
        var batch: [256]RegistryEntry = undefined;
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
            self.ent_lock.lock();
            _ = self.spawnItem(.{ .id = id, .count = put, .damage = damage, .nbt = null }, px, py + 0.5, pz, 10);
            self.ent_lock.unlock();
        }
    }

    /// Max stack size for /give (vanilla 1.7 table).
    pub fn maxStack(self: *Server, id: game_ids.Id) u8 {
        _ = self;
        return item_mod.maxStackSize(id);
    }

    /// Set a player's gamemode + push the abilities packet. Returns false
    /// when the player isn't online.
    /// Set a player's gamemode. Vanilla `EntityPlayerMP.setGameType` sends
    /// S2B reason 3 (the client flips its controller + UI/HUD off that),
    /// plus an S39 refresh with jar-verified flags (0x0D creative / 0x00
    /// survival+adventure). Returns false when the player isn't online.
    pub fn applyGamemode(self: *Server, name: []const u8, mode: u8) bool {
        var batch: [256]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const c = findInSnap(snap, name) orelse return false;
        c.lock.lock();
        defer c.lock.unlock();
        c.config.gamemode = mode;
        const creative = mode == 1;
        var gb: [16]u8 = undefined;
        if (packets.frameGameState(3, @floatFromInt(mode), &gb)) |f| {
            c.queueFramed(f) catch {};
        } else |_| {}
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
        var batch: [256]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const c = findInSnap(snap, target) orelse return null;
        c.lock.lock();
        defer c.lock.unlock();
        var dirty: [45]bool = [_]bool{false} ** 45;
        const r = item_mod.fillInventory(&c.inv, id, count, damage, &dirty);
        for (9..45) |ds| {
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
        var batch: [256]RegistryEntry = undefined;
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
        var batch: [256]RegistryEntry = undefined;
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
            view.syncPlayerChunks(mc, self.chunkSource(pool), 0, radius, true) catch {};
        }
        return true;
    }

    /// /perm reload.
    pub fn permReload(self: *Server) void {
        self.loadPerms();
    }

    /// /perm show <player>: "name: level N +node -node", or null when the
    /// line doesn't fit (caller prints "Show failed.").
    pub fn permShow(self: *Server, player: []const u8, out: []u8) ?[]const u8 {
        // Build the whole reply under perm_lock, release, then return
        // (the caller sends it; reply takes the sender's conn lock —
        // never nest the two).
        const built: ?usize = blk: {
            self.perm_lock.lock();
            defer self.perm_lock.unlock();
            const db = self.permsDbLocked();
            const p = db.lookupRow(player);
            var ow: usize = 0;
            {
                const s = std.fmt.bufPrint(out[ow..], "{s}: level {d}", .{ player, if (p) |pp| pp.level else perms_mod.DEFAULT_LEVEL }) catch break :blk null;
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
    pub fn permGrant(self: *Server, player: []const u8, node: []const u8) void {
        self.perm_lock.lock();
        self.permsDbLocked().grant(player, node) catch {};
        self.perm_lock.unlock();
        self.savePerms();
    }

    pub fn permDeny(self: *Server, player: []const u8, node: []const u8) void {
        self.perm_lock.lock();
        self.permsDbLocked().deny(player, node) catch {};
        self.perm_lock.unlock();
        self.savePerms();
    }

    /// /perm clear <player> [node] (null node = drop all nodes, keep level).
    pub fn permClear(self: *Server, player: []const u8, node: ?[]const u8) void {
        self.perm_lock.lock();
        if (node) |n| {
            _ = self.permsDbLocked().clearNode(player, n) catch false;
        } else if (self.perms) |*db| {
            if (db.lookupRow(player)) |pp| {
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
        // One file per command (src/cmd/); dispatch table and permission
        // metadata both derive from per-file defs (perms_mod.modules), so
        // help text, permission checks, and dispatch can never drift apart.
        inline for (perms_mod.modules) |M| {
            if (cmdMatches(&M.def, cmd)) {
                if (!self.commandAllowed(sender, &M.def)) {
                    // Same reply as unknown: failures never oracle command
                    // existence or the caller's level.
                    return "Unknown command. Try /help for a list of commands";
                }
                return M.run(self, sender, args, out);
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
        var batch: [256]RegistryEntry = undefined;
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
    pub fn resolvePlayerName(self: *Server, sender: ?*Conn, token: []const u8, out: *[16]u8) ?[]const u8 {
        if (!cmd_spec.isSelector(token)) {
            var batch: [256]RegistryEntry = undefined;
            const snap = self.snapshot(&batch);
            defer releaseSnap(snap);
            const c = findInSnap(snap, token) orelse return null;
            c.lock.lock();
            defer c.lock.unlock();
            if (c.state != .play or c.username_len == 0) return null;
            @memcpy(out[0..c.username_len], c.username[0..c.username_len]);
            return out[0..c.username_len];
        }
        var batch: [256]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        var names: [256][16]u8 = undefined;
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
        var batch: [256]RegistryEntry = undefined;
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
    pub fn resolvePlayerList(self: *Server, sender: ?*Conn, token: []const u8, out: [][16]u8, lens: []u8) usize {
        var batch: [256]RegistryEntry = undefined;
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
        var one: [16]u8 = undefined;
        const t = self.resolvePlayerName(sender, token, &one) orelse return 0;
        if (out.len == 0) return 0;
        @memcpy(out[0][0..t.len], t);
        lens[0] = @intCast(t.len);
        return 1;
    }

    /// Online check (play state). Used for "player not found" errors.
    pub fn isOnline(self: *Server, name: []const u8) bool {
        var batch: [256]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const c = findInSnap(snap, name) orelse return false;
        c.lock.lock();
        defer c.lock.unlock();
        return c.state == .play;
    }

    /// Bump the save epoch for a login name; the caller stores the
    /// returned value on the conn. Leaf lock only (never nested).
    fn bumpSaveEpoch(self: *Server, name: []const u8) u64 {
        self.epoch_lock.lock();
        defer self.epoch_lock.unlock();
        if (self.save_epochs == null) self.save_epochs = std.StringHashMap(u64).init(self.gpa);
        var fold: [perms_mod.max_name_len]u8 = undefined;
        const key = perms_mod.Db.normKey(name, &fold);
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
        const cur = m.get(perms_mod.Db.normKey(name, &fold)) orelse return true;
        return cur == epoch;
    }

    /// Kick by registry entry: queue the play disconnect, flush it from
    /// THIS thread, then shut the socket down. Flushing here (instead of
    /// leaving it to the victim's serve loop) matters: a quiet victim's
    /// thread can be parked in takeByte indefinitely, in which case a
    /// queue-only kick never lands and the ghost lingers in the registry
    /// shadowing the live session. Shutdown wakes the victim's thread so
    /// it unregisters promptly. Same shape as the idle-kick path.
    fn kickEntry(self: *Server, e: RegistryEntry, reason: []const u8) void {
        var eb: [512]u8 = undefined;
        const esc = packets.escapeJsonText(reason, &eb) catch return;
        var jb: [560]u8 = undefined;
        const json = std.fmt.bufPrint(&jb, "{{\"text\":\"{s}\"}}", .{esc}) catch return;
        e.conn.lock.lock();
        if (e.conn.state != .play or e.conn.dead) {
            e.conn.lock.unlock();
            return;
        }
        // Disconnect carries the JSON (client shows it on the screen).
        var pb: [640]u8 = undefined;
        var w = codec.PacketWriter.init(&pb);
        w.writeString(json) catch {
            e.conn.lock.unlock();
            return;
        };
        var fb: [700]u8 = undefined;
        const d = codec.framePacket(@intFromEnum(ids.PlayClient.disconnect), w.written(), &fb) catch {
            e.conn.lock.unlock();
            return;
        };
        e.conn.queueFramed(d) catch {};
        e.conn.close_after_flush = true;
        const pending = e.conn.takeOutput() catch {
            e.conn.lock.unlock();
            return;
        };
        e.conn.lock.unlock();
        if (pending.len > 0) writeFramed(e, self.io, pending);
        e.conn.allocator.free(pending);
        e.stream.shutdown(self.io, .both) catch {};
    }

    /// Login rejection screen (conn.lock held by the caller). Queues a play
    /// disconnect with the jar-hardcoded text and closes after flush —
    /// LoginSuccess already went out, so this is a post-login kick with the
    /// same screen vanilla shows pre-login.
    fn rejectLogin(self: *Server, c: *Conn, rej: LoginReject) void {
        const name = c.username[0..c.username_len];
        var reason: [1024]u8 = undefined;
        var rlen: usize = 0;
        switch (rej) {
            .banned_name => {
                self.ban_lock.lock();
                const r = if (self.bans) |*db| db.bannedName(name) else null;
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
        }
        var eb: [2048]u8 = undefined;
        const esc = packets.escapeJsonText(reason[0..rlen], &eb) catch return;
        var jb: [2112]u8 = undefined;
        const json = std.fmt.bufPrint(&jb, "{{\"text\":\"{s}\"}}", .{esc}) catch return;
        var pb: [2200]u8 = undefined;
        var w = codec.PacketWriter.init(&pb);
        w.writeString(json) catch return;
        var fb: [2300]u8 = undefined;
        if (codec.framePacket(@intFromEnum(ids.PlayClient.disconnect), w.written(), &fb)) |f| {
            c.queueFramed(f) catch {};
        } else |_| {}
        c.close_after_flush = true;
    }

    /// Kick an online player. False when they aren't online.
    pub fn kickPlayer(self: *Server, name: []const u8, reason: ?[]const u8) bool {
        var batch: [256]RegistryEntry = undefined;
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

    fn banDb(self: *Server) *bans_mod.BanDb {
        self.ban_lock.lock();
        defer self.ban_lock.unlock();
        if (self.bans == null) self.bans = bans_mod.BanDb.init(self.gpa);
        return &self.bans.?;
    }

    fn banSave(self: *Server) void {
        const pool = self.world orelse return;
        self.ban_lock.lock();
        const enc = if (self.bans) |*db| db.encode(pool.allocator) catch null else null;
        self.ban_lock.unlock();
        if (enc) |e| {
            defer pool.allocator.free(e);
            self.world_lock.lock();
            defer self.world_lock.unlock();
            pool.put(bans_mod.bans_key, e) catch {};
        }
    }

    pub fn banLoad(self: *Server) void {
        const pool = self.world orelse return;
        const loaded = bans_mod.loadBans(pool, self.gpa) catch |err| blk: {
            std.log.warn("bans row unreadable ({}) — starting empty", .{err});
            break :blk null;
        };
        if (loaded) |db| {
            self.ban_lock.lock();
            defer self.ban_lock.unlock();
            if (self.bans) |*old| old.deinit();
            self.bans = db;
        }
    }

    fn wlDb(self: *Server) *bans_mod.Whitelist {
        self.wl_lock.lock();
        defer self.wl_lock.unlock();
        if (self.whitelist == null) self.whitelist = bans_mod.Whitelist.init(self.gpa);
        return &self.whitelist.?;
    }

    fn wlSave(self: *Server) void {
        const pool = self.world orelse return;
        self.wl_lock.lock();
        const enc = if (self.whitelist) |*wl| wl.encode(pool.allocator) catch null else null;
        self.wl_lock.unlock();
        if (enc) |e| {
            defer pool.allocator.free(e);
            self.world_lock.lock();
            defer self.world_lock.unlock();
            pool.put(bans_mod.whitelist_key, e) catch {};
        }
    }

    pub fn whitelistLoad(self: *Server) void {
        const pool = self.world orelse return;
        const loaded = bans_mod.loadWhitelist(pool, self.gpa) catch |err| blk: {
            std.log.warn("whitelist row unreadable ({}) — starting empty", .{err});
            break :blk null;
        };
        if (loaded) |wl| {
            self.wl_lock.lock();
            defer self.wl_lock.unlock();
            if (self.whitelist) |*old| old.deinit();
            self.whitelist = wl;
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
        const wl = self.wlDb();
        self.wl_lock.lock();
        wl.add(name) catch {
            self.wl_lock.unlock();
            return false;
        };
        self.wl_lock.unlock();
        self.wlSave();
        return true;
    }

    pub fn wlRemove(self: *Server, name: []const u8) bool {
        const wl = self.wlDb();
        self.wl_lock.lock();
        const ok = wl.remove(name);
        self.wl_lock.unlock();
        if (ok) self.wlSave();
        return ok;
    }

    /// "There are %d (out of %d seen) whitelisted players:" + names. Seen =
    /// union of whitelisted + currently online (player rows need a store
    /// scan, which the LSM doesn't offer — this is the best available).
    pub fn wlList(self: *Server, out: []u8) []const u8 {
        var names: [256][16]u8 = undefined;
        var lens: [256]u8 = undefined;
        const online = self.playNames(&names, &lens);
        self.wl_lock.lock();
        defer self.wl_lock.unlock();
        const wl = if (self.whitelist) |*w| w else {
            return std.fmt.bufPrint(out, "There are 0 (out of {d} seen) whitelisted players:", .{online}) catch out[0..0];
        };
        // Union count for "seen".
        var seen = online;
        var wit = wl.names.iterator();
        while (wit.next()) |e| {
            var known = false;
            for (names[0..online], lens[0..online]) |nm, ln| {
                if (std.mem.eql(u8, nm[0..ln], e.key_ptr.*)) {
                    known = true;
                    break;
                }
            }
            if (!known) seen += 1;
        }
        var ow: usize = 0;
        ow += (std.fmt.bufPrint(out[ow..], "There are {d} (out of {d} seen) whitelisted players:", .{ wl.names.count(), seen }) catch return out[0..ow]).len;
        var jit = wl.names.iterator();
        while (jit.next()) |e| {
            ow += (std.fmt.bufPrint(out[ow..], "\n{s}", .{e.key_ptr.*}) catch break).len;
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

    /// Ban a name (any valid name in offline mode) and kick them if online.
    /// Reason may be empty (login screen then shows the bare ban line).
    pub fn banName(self: *Server, name: []const u8, reason: []const u8) void {
        const db = self.banDb();
        self.ban_lock.lock();
        db.banName(name, reason) catch {};
        self.ban_lock.unlock();
        self.banSave();
        _ = self.kickPlayer(name, "You are banned from this server.");
    }

    pub fn pardonName(self: *Server, name: []const u8) bool {
        const db = self.banDb();
        self.ban_lock.lock();
        const ok = db.unbanName(name);
        self.ban_lock.unlock();
        if (ok) self.banSave();
        return ok;
    }

    pub fn isNameBanned(self: *Server, name: []const u8) ?[]const u8 {
        // Reason slice borrows the map — copy out under the lock.
        self.ban_lock.lock();
        defer self.ban_lock.unlock();
        if (self.bans) |*db| {
            if (db.bannedName(name)) |r| return r;
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
        var batch: [256]RegistryEntry = undefined;
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
                ow += (std.fmt.bufPrint(out[ow..], "\n{s}", .{e.key_ptr.*}) catch break).len;
            }
        }
        return out[0..ow];
    }

    /// Login gate: banned names/IPs and non-whitelisted names are rejected
    /// with the jar-hardcoded screens (`oi` login handler strings).
    pub const LoginReject = enum { banned_name, banned_ip, not_whitelisted };

    pub fn loginRejected(self: *Server, name: []const u8, ip: []const u8) ?LoginReject {
        self.ban_lock.lock();
        const bn = if (self.bans) |*db| db.bannedName(name) != null else false;
        const bi = if (self.bans) |*db| (if (ip.len > 0) db.bannedIp(ip) != null else false) else false;
        self.ban_lock.unlock();
        if (bn) return .banned_name;
        if (bi) return .banned_ip;
        self.wl_lock.lock();
        defer self.wl_lock.unlock();
        if (self.whitelist) |*wl| {
            if (wl.enabled and !wl.contains(name)) return .not_whitelisted;
        }
        return null;
    }

    pub fn loginRejectText(reject: LoginReject, out: []u8) []const u8 {
        _ = out;
        return switch (reject) {
            .banned_name => "You are banned from this server.",
            .banned_ip => "Your IP address is banned from this server.",
            .not_whitelisted => "You are not white-listed on this server!",
        };
    }

    /// Broadcast `[name] message` (vanilla `chat.type.announcement`).
    /// Multi-line input goes out as one packet per line (never `\n`).
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
        var batch: [256]RegistryEntry = undefined;
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
        if (packets.frameUpdateHealth(0, c.food, c.saturation, &hb)) |f| {
            c.queueFramed(f) catch {};
        } else |_| {}
        var dd: ?DeathDrop = if (self.keepInv()) null else collectDeathDrops(c);
        const px = c.pos_x;
        const py = c.pos_y;
        const pz = c.pos_z;
        const eid = c.eid;
        c.lock.unlock();
        // Death metadata + drops outside the conn lock.
        var mdb: [32]u8 = undefined;
        if (packets.frameEntityMetadata(eid, 0, &mdb)) |f| {
            self.broadcastToTrackers(eid, f);
        } else |_| {}
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
        var gb: [16]u8 = undefined;
        switch (mode) {
            .clear => {
                if (packets.frameGameState(2, 0, &gb)) |f| self.broadcastAll(f) else |_| {}
            },
            .rain, .thunder => {
                if (packets.frameGameState(1, 0, &gb)) |f| self.broadcastAll(f) else |_| {}
            },
        }
    }

    pub fn toggleDownfall(self: *Server) void {
        self.state_lock.lock();
        self.raining = !self.raining;
        if (!self.raining) self.thundering = false;
        const now_raining = self.raining;
        self.state_lock.unlock();
        var gb: [16]u8 = undefined;
        if (packets.frameGameState(if (now_raining) 1 else 2, 0, &gb)) |f| {
            self.broadcastAll(f);
        } else |_| {}
    }

    /// Raw frame to every play conn (weather, game state).
    fn broadcastAll(self: *Server, framed: []const u8) void {
        var batch: [256]RegistryEntry = undefined;
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
        self.state_lock.unlock();
        if (changed) {
            var gb: [16]u8 = undefined;
            if (packets.frameGameState(2, 0, &gb)) |f| self.broadcastAll(f) else |_| {}
        }
    }

    const diff_names = [_][]const u8{ "peaceful", "easy", "normal", "hard" };

    pub fn difficultyName(_: *Server, d: u8) []const u8 {
        return if (d < 4) diff_names[d] else "normal";
    }

    pub fn setDifficulty(self: *Server, d: u8) void {
        self.state_lock.lock();
        self.difficulty = d;
        self.state_lock.unlock();
        var batch: [256]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            e.conn.lock.lock();
            if (e.conn.state == .play) e.conn.config.difficulty = d;
            e.conn.lock.unlock();
        }
    }

    pub fn getDifficulty(self: *Server) u8 {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        return self.difficulty;
    }

    const gamemode_names = [_][]const u8{ "survival", "creative", "adventure" };

    pub fn gamemodeName(_: *Server, m: u8) []const u8 {
        return if (m < 3) gamemode_names[m] else "survival";
    }

    pub fn setDefaultGamemode(self: *Server, m: u8) void {
        self.state_lock.lock();
        self.default_gamemode = m;
        self.state_lock.unlock();
    }

    pub fn gameruleGet(self: *Server, name: []const u8) ?bool {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        for (cmd_data.gamerules, 0..) |g, i| {
            if (std.mem.eql(u8, g.name, name)) return self.gamerules[i];
        }
        return null;
    }

    /// Returns false for unknown rules (caller prints norule).
    pub fn gameruleSet(self: *Server, name: []const u8, value: bool) bool {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        for (cmd_data.gamerules, 0..) |g, i| {
            if (std.mem.eql(u8, g.name, name)) {
                self.gamerules[i] = value;
                return true;
            }
        }
        return false;
    }

    /// keepInventory gamerule (death drops).
    pub fn keepInv(self: *Server) bool {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        return self.gamerules[2];
    }

    /// doTileDrops gamerule (block-break drops).
    pub fn tileDrops(self: *Server) bool {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        return self.gamerules[5];
    }

    pub fn gameruleList(self: *Server, out: []u8) []const u8 {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        var ow: usize = 0;
        for (cmd_data.gamerules, 0..) |g, i| {
            ow += (std.fmt.bufPrint(out[ow..], "{s} = {s}\n", .{ g.name, if (self.gamerules[i]) "true" else "false" }) catch break).len;
        }
        if (ow > 0) ow -= 1; // drop trailing newline
        return out[0..ow];
    }

    pub fn seedString(self: *Server, out: []u8) []const u8 {
        return std.fmt.bufPrint(out, "Seed: {d}", .{self.drop_seed}) catch "Seed: 0";
    }

    // ---- experience ----

    pub fn xpCap(level: i32) i32 {
        if (level >= 30) return 62 + (level - 30) * 7;
        if (level >= 15) return 17 + (level - 15) * 3;
        return 17;
    }

    /// Queue S1F for one conn (lock must be held by the caller).
    fn queueExperience(c: *Conn) void {
        var eb: [16]u8 = undefined;
        const total: i16 = @truncate(c.xp_total);
        if (packets.frameSetExperience(c.xp_bar, @intCast(c.xp_level), total, &eb)) |f| {
            c.queueFramed(f) catch {};
        } else |_| {}
    }

    /// Vanilla EntityPlayer.addExperience: capped total, fractional bar,
    /// level-ups preserve leftover against the new cap.
    pub fn addXp(self: *Server, name: []const u8, amount: i32) bool {
        var batch: [256]RegistryEntry = undefined;
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
        var batch: [256]RegistryEntry = undefined;
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

    // ---- potion effects ----

    /// Give (or refresh) an effect; replaces same-id, 8-slot cap.
    /// False when the player isn't online.
    pub fn effectGive(self: *Server, name: []const u8, id: u8, seconds: i32, amp: u8) bool {
        var batch: [256]RegistryEntry = undefined;
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
        var eb: [16]u8 = undefined;
        if (packets.frameEntityEffect(c.eid, id, amp, ticks, &eb)) |f| {
            c.queueFramed(f) catch {};
        } else |_| {}
        return true;
    }

    /// Clear one effect (null id = all). Returns removed count, or null
    /// when the player isn't online.
    pub fn effectClear(self: *Server, name: []const u8, id: ?u8) ?usize {
        var batch: [256]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        const c = findInSnap(snap, name) orelse return null;
        c.lock.lock();
        defer c.lock.unlock();
        if (c.state != .play) return null;
        var n: usize = 0;
        for (&c.effects) |*s| {
            if (s.*) |e| {
                if (id == null or e.id == id.?) {
                    var eb: [16]u8 = undefined;
                    if (packets.frameRemoveEntityEffect(c.eid, e.id, &eb)) |f| {
                        c.queueFramed(f) catch {};
                    } else |_| {}
                    s.* = null;
                    n += 1;
                }
            }
        }
        return n;
    }

    /// Tick down effects (20 units per 1Hz tick); expiry sends S1E.
    fn tickEffects(self: *Server) void {
        var batch: [256]RegistryEntry = undefined;
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
            for (expired[0..n_exp]) |id| {
                var eb: [16]u8 = undefined;
                if (packets.frameRemoveEntityEffect(e.conn.eid, id, &eb)) |f| {
                    e.conn.queueFramed(f) catch {};
                } else |_| {}
            }
            e.conn.lock.unlock();
        }
    }

    // ---- raw-NBT `ench` list helpers (wire format is uncompressed NBT) ----

    /// Skip one NBT payload; false on truncation/unknown tag.
    fn nbtSkip(tag: u8, buf: []const u8, i: *usize) bool {
        const need = struct {
            fn f(buf_: []const u8, i_: *usize, n: usize) bool {
                if (i_.* + n > buf_.len) return false;
                i_.* += n;
                return true;
            }
        }.f;
        switch (tag) {
            0 => return true,
            1, 7 => return need(buf, i, 1),
            2 => return need(buf, i, 2),
            3, 5 => return need(buf, i, 4),
            4, 6 => return need(buf, i, 8),
            8 => {
                if (i.* + 2 > buf.len) return false;
                const l = std.mem.readInt(u16, buf[i.*..][0..2], .big);
                i.* += 2;
                return need(buf, i, l);
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
                return need(buf, i, @as(usize, @intCast(n)) * 4);
            },
            else => return false,
        }
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
            if (i.* + 2 > buf.len) return false;
            const nl = std.mem.readInt(u16, buf[i.*..][0..2], .big);
            i.* += 2;
            if (i.* + nl > buf.len) return false;
            i.* += nl;
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
        if (i + 2 > raw.len) return r;
        const nl0 = std.mem.readInt(u16, raw[i..][0..2], .big);
        i += 2;
        if (i + nl0 > raw.len) return r;
        i += nl0;
        while (true) {
            if (i + 1 > raw.len) return r;
            const tag = raw[i];
            i += 1;
            if (tag == 0) {
                r.valid = i == raw.len;
                return r;
            }
            if (i + 2 > raw.len) return r;
            const nl = std.mem.readInt(u16, raw[i..][0..2], .big);
            i += 2;
            if (i + nl > raw.len) return r;
            const name = raw[i .. i + nl];
            i += nl;
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
                    var id: ?u8 = null;
                    var lvl: ?u8 = null;
                    while (true) {
                        if (i + 1 > raw.len) return r;
                        const et = raw[i];
                        i += 1;
                        if (et == 0) break;
                        if (i + 2 > raw.len) return r;
                        const el = std.mem.readInt(u16, raw[i..][0..2], .big);
                        i += 2;
                        if (i + el > raw.len) return r;
                        const ename = raw[i .. i + el];
                        i += el;
                        if (et == 3 and i + 2 <= raw.len) {
                            const v = std.mem.readInt(i16, raw[i..][0..2], .big);
                            if (std.mem.eql(u8, ename, "id")) id = @truncate(@max(0, v));
                            if (std.mem.eql(u8, ename, "lvl")) lvl = @truncate(@max(0, v));
                            i += 2;
                        } else {
                            var j = i;
                            if (!nbtSkip(et, raw, &j)) return r;
                            i = j;
                        }
                    }
                    if (r.n < 8) {
                        ench_ids[r.n] = id orelse 0;
                        ench_lvls[r.n] = lvl orelse 0;
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
                    const list_bytes = 1 + 4 + n * 16; // 0A + count + entries
                    if (w + list_bytes + (raw.len - p.list_end) > out.len) return null;
                    out[w] = 10;
                    w += 1;
                    std.mem.writeInt(i32, out[w..][0..4], @intCast(n), .big);
                    w += 4;
                    for (have[0..n], have_lvls[0..n]) |id, lvl| {
                        out[w] = 3;
                        w += 1;
                        std.mem.writeInt(u16, out[w..][0..2], 2, .big);
                        w += 2;
                        out[w] = 'i';
                        out[w + 1] = 'd';
                        w += 2;
                        std.mem.writeInt(i16, out[w..][0..2], id, .big);
                        w += 2;
                        out[w] = 3;
                        w += 1;
                        std.mem.writeInt(u16, out[w..][0..2], 3, .big);
                        w += 2;
                        out[w] = 'l';
                        out[w + 1] = 'v';
                        out[w + 2] = 'l';
                        w += 3;
                        std.mem.writeInt(i16, out[w..][0..2], lvl, .big);
                        w += 2;
                        out[w] = 0;
                        w += 1;
                    }
                    const post = raw[p.list_end..];
                    @memcpy(out[w..][0..post.len], post);
                    w += post.len;
                    return out[0..w];
                }
                // No ench list (valid compound without one): append before end.
                if (raw.len < 1 or raw[raw.len - 1] != 0) return null;
                const list_bytes = 1 + 2 + 4 + 1 + 4 + 16; // tag+name+count+entry
                if (raw.len - 1 + list_bytes + 1 > out.len) return null;
                var w: usize = 0;
                @memcpy(out[w..][0 .. raw.len - 1], raw[0 .. raw.len - 1]);
                w += raw.len - 1;
                out[w] = 9;
                w += 1;
                std.mem.writeInt(u16, out[w..][0..2], 4, .big);
                w += 2;
                out[w] = 'e';
                out[w + 1] = 'n';
                out[w + 2] = 'c';
                out[w + 3] = 'h';
                w += 4;
                out[w] = 10;
                w += 1;
                std.mem.writeInt(i32, out[w..][0..4], 1, .big);
                w += 4;
                out[w] = 3;
                w += 1;
                std.mem.writeInt(u16, out[w..][0..2], 2, .big);
                w += 2;
                out[w] = 'i';
                out[w + 1] = 'd';
                w += 2;
                std.mem.writeInt(i16, out[w..][0..2], ench_id, .big);
                w += 2;
                out[w] = 3;
                w += 1;
                std.mem.writeInt(u16, out[w..][0..2], 3, .big);
                w += 2;
                out[w] = 'l';
                out[w + 1] = 'v';
                out[w + 2] = 'l';
                w += 3;
                std.mem.writeInt(i16, out[w..][0..2], level, .big);
                w += 2;
                out[w] = 0;
                w += 1;
                out[w] = 0;
                w += 1;
                return out[0..w];
            }
        }
        // Fresh compound with a single-entry ench list (23 bytes).
        if (out.len < 23) return null;
        var w: usize = 0;
        out[w] = 10;
        w += 1; // root compound, empty name
        out[w] = 0;
        out[w + 1] = 0;
        w += 2;
        out[w] = 9;
        w += 1; // ench list
        out[w] = 0;
        out[w + 1] = 4;
        w += 2;
        out[w] = 'e';
        out[w + 1] = 'n';
        out[w + 2] = 'c';
        out[w + 3] = 'h';
        w += 4;
        out[w] = 10;
        w += 1;
        std.mem.writeInt(i32, out[w..][0..4], 1, .big);
        w += 4;
        out[w] = 3;
        w += 1;
        std.mem.writeInt(u16, out[w..][0..2], 2, .big);
        w += 2;
        out[w] = 'i';
        out[w + 1] = 'd';
        w += 2;
        std.mem.writeInt(i16, out[w..][0..2], ench_id, .big);
        w += 2;
        out[w] = 3;
        w += 1;
        std.mem.writeInt(u16, out[w..][0..2], 3, .big);
        w += 2;
        out[w] = 'l';
        out[w + 1] = 'v';
        out[w + 2] = 'l';
        w += 3;
        std.mem.writeInt(i16, out[w..][0..2], level, .big);
        w += 2;
        out[w] = 0;
        w += 1; // entry end
        out[w] = 0;
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
        var batch: [256]RegistryEntry = undefined;
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

    /// Clear matching stacks (item + data(-1 = any), or everything).
    /// Returns removed item count, or null when offline.
    pub fn clearInventory(self: *Server, name: []const u8, wire_id: ?u16, data: i16) ?usize {
        var batch: [256]RegistryEntry = undefined;
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
            const id = wire.fromWire(w) orelse return 0;
            for (&c.inv) |*s| {
                if (s.*) |st| {
                    if (st.id == id and (data < 0 or st.damage == data)) {
                        removed += @intCast(st.count);
                        item_mod.freeStack(c.allocator, s);
                        s.* = null;
                    }
                }
            }
            if (c.cursor) |st| {
                if (st.id == id and (data < 0 or st.damage == data)) {
                    removed += @intCast(st.count);
                    item_mod.freeStack(c.allocator, &c.cursor);
                    c.cursor = null;
                }
            }
        } else {
            for (&c.inv) |*s| {
                if (s.*) |st| {
                    removed += @intCast(st.count);
                    item_mod.freeStack(c.allocator, s);
                    s.* = null;
                }
            }
            if (c.cursor) |st| {
                removed += @intCast(st.count);
                item_mod.freeStack(c.allocator, &c.cursor);
                c.cursor = null;
            }
        }
        // Full-window resync (vanilla detectAndSendChanges).
        const wf = packets.frameWindowItemsAlloc(self.gpa, 0, &c.inv) catch null;
        const cf = if (wf != null) packets.frameSetSlotAlloc(self.gpa, -1, -1, c.cursor) catch null else null;
        c.lock.unlock();
        if (wf) |f| {
            defer self.gpa.free(f);
            c.lock.lock();
            c.queueFramed(f) catch {};
            c.lock.unlock();
        }
        if (cf) |f| {
            defer self.gpa.free(f);
            c.lock.lock();
            c.queueFramed(f) catch {};
            c.lock.unlock();
        }
        return removed;
    }

    /// Summonable living entity by vanilla name (else null).
    pub fn mobByName(self: *Server, name: []const u8) ?cmd_data.Mob {
        _ = self;
        return cmd_data.mobByName(name);
    }

    /// Read one block (wire id + meta). Null without a world / missing chunk.
    pub fn getBlockAt(self: *Server, x: i32, y: i32, z: i32) ?struct { wire: u16, meta: u4 } {
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
            .replace => {
                if (cur.id == id and cur.meta == meta) return .no_change;
            },
            .keep => {
                if (cur.id != game_ids.air) return .no_change;
            },
            .destroy => {
                if (cur.id == id and cur.meta == meta) return .no_change;
            },
        }
        if (mode == .destroy and cur.id != game_ids.air) {
            // Break particles + survival-style drop handled by the caller
            // (drops need gamerule state, checked outside world_lock).
        }
        view.applyBlock(pool, self.gpa, x, @intCast(y), z, id, meta) catch return .no_world;
        self.broadcastBlockChange(null, x, @intCast(y), z, id, meta) catch {};
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
    fn shouldDropBreak(gamemode: u8, old_id: game_ids.Id, tile_drops: bool) bool {
        return old_id != game_ids.air and gamemode != 1 and tile_drops;
    }

    /// Spawn drops for a destroy-mode setblock (gamerule doTileDrops gate).
    pub fn setblockDrops(self: *Server, x: i32, y: i32, z: i32, old_wire: u16) void {
        if (!self.tileDrops()) return;
        const id = wire.fromWire(old_wire) orelse return;
        if (id == game_ids.air) return;
        const pool = self.world orelse return;
        self.spawnBreakDrops(pool, self.gpa, x, @intCast(y), z, id, 0);
    }

    /// Summon a living entity (ticker broadcasts it like any other mob).
    /// Caller validates y in [0, 256); returns false without a world.
    pub fn summonMob(self: *Server, type_id: u8, x: f64, y: f64, z: f64, health: f32) bool {
        if (self.world == null) return false;
        const id = self.eid_counter.fetchAdd(1, .acq_rel);
        self.ent_lock.lock();
        defer self.ent_lock.unlock();
        self.entities.append(self.gpa, .{
            .id = id,
            .kind = type_id,
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
        var batch: [256]RegistryEntry = undefined;
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
        if (packets.frameSoundEffect(sound, x, y, z, volume, pitch, &sb)) |f| {
            c.queueFramed(f) catch {};
        } else |_| {}
        return .heard;
    }

    pub fn nowMs(self: *Server) i64 {
        return std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
    }

    /// /netstat console body: connection + entity + tick counters (we don't
    /// track per-packet bytes, so this reports what the server does know).
    pub fn netstatText(self: *Server, out: []u8) []const u8 {
        self.ent_lock.lock();
        const nmobs = self.entities.items.len;
        const nitems = self.items.items.len;
        self.ent_lock.unlock();
        self.reg_lock.lock();
        const nconns = self.registry.items.len;
        self.reg_lock.unlock();
        return std.fmt.bufPrint(out, "connections: {d}, mobs: {d}, item entities: {d}, ticks: {d}, time: {d}", .{ nconns, nmobs, nitems, self.tick_counter, self.time_of_day.load(.acquire) }) catch "netstat";
    }

    pub fn debugStart(self: *Server, now_ms: i64) void {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        self.debug_start_ms = now_ms;
        self.debug_ticks = 0;
    }

    /// Returns elapsed seconds + ticks, or null when not profiling.
    pub fn debugStop(self: *Server, now_ms: i64) ?struct { secs: f64, ticks: u64 } {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        const start = self.debug_start_ms orelse return null;
        self.debug_start_ms = null;
        return .{ .secs = @as(f64, @floatFromInt(now_ms - start)) / 1000.0, .ticks = self.debug_ticks };
    }

    pub fn setAutosave(self: *Server, on: bool) void {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        self.autosave = on;
    }

    pub fn getAutosave(self: *Server) bool {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        return self.autosave;
    }

    pub fn setIdleTimeout(self: *Server, mins: u32) void {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        self.idle_timeout_min = mins;
    }

    /// Personal spawn (`/spawnpoint`): empty name = sender handled by caller.
    pub fn setSpawn(self: *Server, name: []const u8, x: i32, y: i32, z: i32) bool {
        var batch: [256]RegistryEntry = undefined;
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
        self.world_spawn = .{ x, y, z };
        self.world_spawn_set = true;
        self.state_lock.unlock();
        var batch: [256]RegistryEntry = undefined;
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
        var batch: [256]RegistryEntry = undefined;
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

    /// Vanilla `getPossibleCommands` + per-command `addTabCompletion`.
    /// Null = suppress (unknown command); otherwise S3A with candidates
    /// (possibly empty). Caller holds no locks; conn queued under its lock.
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
        var found: ?*const perms_mod.Command = null;
        for (&perms_mod.commands) |*d| {
            if (cmdMatches(d, toks[0])) {
                found = d;
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
        var batch: [256]RegistryEntry = undefined;
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
        var n: usize = 0;
        var on: usize = 0;
        inline for (perms_mod.modules) |M| {
            const ok = if (sender == null) true else self.commandAllowed(sender, &M.def);
            if (ok) {
                if (cmd_spec.startsWithIgnoreCase(M.def.name, prefix)) {
                    if (n < out.len and on < owned.len) {
                        const s = std.fmt.bufPrint(&owned[on], "/{s}", .{M.def.name}) catch null;
                        if (s) |cand| {
                            if (!containsName(out[0..n], cand)) {
                                out[n] = cand;
                                n += 1;
                            }
                            on += 1;
                        }
                    }
                }
                for (M.def.aliases) |a| {
                    if (cmd_spec.startsWithIgnoreCase(a, prefix)) {
                        if (n < out.len and on < owned.len) {
                            const s = std.fmt.bufPrint(&owned[on], "/{s}", .{a}) catch null;
                            if (s) |cand| {
                                if (!containsName(out[0..n], cand)) {
                                    out[n] = cand;
                                    n += 1;
                                }
                                on += 1;
                            }
                        }
                    }
                }
            }
        }
        return n;
    }

    fn containsName(hay: [][]const u8, needle: []const u8) bool {
        for (hay) |e| if (std.mem.eql(u8, e, needle)) return true;
        return false;
    }

    fn completeArgs(self: *Server, def: *const perms_mod.Command, toks: [][]const u8, out: [][]const u8, owned: [][64]u8) usize {
        // Find the command module to get its spec.
        inline for (perms_mod.modules) |M| {
            if (std.mem.eql(u8, M.def.name, def.name)) {
                return completeArgsFor(self, &M.def, toks, out, owned);
            }
        }
        return 0;
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
            for (tmp[0..m]) |c| {
                if (n >= out.len) break;
                var dup = false;
                for (out[0..n]) |e| if (std.mem.eql(u8, e, c)) {
                    dup = true;
                    break;
                };
                if (!dup) {
                    out[n] = c;
                    n += 1;
                }
            }
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
                for (cmd_data.gamerules) |g| {
                    if (n >= out.len) break;
                    if (cmd_spec.startsWithIgnoreCase(g.name, prefix)) {
                        out[n] = g.name;
                        n += 1;
                    }
                }
            } else if (arg_index == 1) {
                for ([_][]const u8{ "true", "false" }) |b| {
                    if (n >= out.len) break;
                    if (cmd_spec.startsWithIgnoreCase(b, prefix)) {
                        out[n] = b;
                        n += 1;
                    }
                }
            }
        } else if (std.mem.eql(u8, def.name, "effect")) {
            if (arg_index == 2 and n < out.len) {
                // effect names are numeric; offer 1..23 by prefix
                var id: u8 = 1;
                while (id <= 23) : (id += 1) {
                    if (n >= out.len or n >= owned.len) break;
                    const s = std.fmt.bufPrint(&owned[n], "{d}", .{id}) catch break;
                    if (cmd_spec.startsWithIgnoreCase(s, prefix)) {
                        out[n] = s;
                        n += 1;
                    }
                }
            } else if (arg_index == 1 and (std.mem.eql(u8, toks[0], "clear") or toks.len > 0)) {
                if (cmd_spec.startsWithIgnoreCase("clear", prefix) and n < out.len) {
                    out[n] = "clear";
                    n += 1;
                }
            }
        } else if (std.mem.eql(u8, def.name, "enchant")) {
            if (arg_index == 1) {
                for (cmd_data.enchants) |e| {
                    if (n >= out.len or n >= owned.len) break;
                    const s = std.fmt.bufPrint(&owned[n], "{d}", .{e.id}) catch break;
                    if (cmd_spec.startsWithIgnoreCase(s, prefix)) {
                        out[n] = s;
                        n += 1;
                    }
                }
            }
        } else if (std.mem.eql(u8, def.name, "summon")) {
            if (arg_index == 0) {
                for (cmd_data.mobs) |m| {
                    if (n >= out.len) break;
                    if (cmd_spec.startsWithIgnoreCase(m.name, prefix)) {
                        out[n] = m.name;
                        n += 1;
                    }
                }
            }
        } else if (std.mem.eql(u8, def.name, "difficulty")) {
            if (arg_index == 0) {
                for (diff_names ++ [_][]const u8{ "p", "e", "n", "h", "0", "1", "2", "3" }) |v| {
                    if (n >= out.len) break;
                    if (cmd_spec.startsWithIgnoreCase(v, prefix)) {
                        out[n] = v;
                        n += 1;
                    }
                }
            }
        } else if (std.mem.eql(u8, def.name, "gamemode") or std.mem.eql(u8, def.name, "defaultgamemode")) {
            if (arg_index == 0) {
                for ([_][]const u8{ "survival", "creative", "adventure", "s", "c", "a", "0", "1", "2" }) |v| {
                    if (n >= out.len) break;
                    if (cmd_spec.startsWithIgnoreCase(v, prefix)) {
                        out[n] = v;
                        n += 1;
                    }
                }
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
        const put = struct {
            fn f(list: []const []const u8, prefix_: []const u8, o: [][]const u8, nn: *usize) void {
                for (list) |v| {
                    if (nn.* >= o.len) break;
                    if (cmd_spec.startsWithIgnoreCase(v, prefix_)) {
                        o[nn.*] = v;
                        nn.* += 1;
                    }
                }
            }
        }.f;
        if (toks.len == 1) {
            put(&.{ "objectives", "players", "teams" }, prefix, out, &n);
            return n;
        }
        if (std.mem.eql(u8, toks[0], "objectives")) {
            if (toks.len == 2) {
                put(&.{ "list", "add", "remove", "setdisplay" }, prefix, out, &n);
            } else if (toks.len == 3 and std.mem.eql(u8, toks[1], "add")) {
                put(&cmd_data.criteria, prefix, out, &n);
            } else if (toks.len == 3 and std.mem.eql(u8, toks[1], "setdisplay")) {
                put(&.{ "list", "sidebar", "belowName" }, prefix, out, &n);
            }
        } else if (std.mem.eql(u8, toks[0], "players")) {
            if (toks.len == 2) put(&.{ "set", "add", "remove", "reset", "list" }, prefix, out, &n);
        } else if (std.mem.eql(u8, toks[0], "teams")) {
            if (toks.len == 2) {
                put(&.{ "list", "add", "remove", "empty", "join", "leave", "option" }, prefix, out, &n);
            } else if (toks.len == 4 and std.mem.eql(u8, toks[1], "option")) {
                put(&.{ "friendlyfire", "color", "seeFriendlyInvisibles" }, prefix, out, &n);
            } else if (toks.len == 5 and std.mem.eql(u8, toks[1], "option") and std.mem.eql(u8, toks[3], "color")) {
                put(&cmd_data.team_colors, prefix, out, &n);
            }
        }
        return n;
    }

    /// All registered item/block names (canonical snake_case) for /give etc.
    fn completeWireNames(prefix: []const u8, out: [][]const u8) usize {
        var n: usize = 0;
        inline for (@typeInfo(game_ids.Id).@"enum".fields) |f| {
            if (n >= out.len) break;
            if (cmd_spec.startsWithIgnoreCase(f.name, prefix)) {
                out[n] = f.name;
                n += 1;
            }
        }
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

    pub fn sbTrackedPlayers(self: *Server, out: [][16]u8) usize {
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
    pub fn captureIp(conn: *Conn, stream: std.Io.net.Stream) void {
        switch (stream.socket.address) {
            .ip4 => |a| {
                const s = std.fmt.bufPrint(&conn.ip, "{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }) catch return;
                conn.ip_len = s.len;
            },
            .ip6 => |a| {
                var w: usize = 0;
                for (a.bytes, 0..) |b, i| {
                    if (i % 2 == 0) {
                        if (i > 0) {
                            if (w + 1 > conn.ip.len) return;
                            conn.ip[w] = ':';
                            w += 1;
                        }
                        const v: u16 = @as(u16, b) << 8 | a.bytes[i + 1];
                        const s = std.fmt.bufPrint(conn.ip[w..], "{x}", .{v}) catch return;
                        w += s.len;
                    }
                }
                conn.ip_len = w;
            },
        }
    }

    /// One server tick: advance clock, queue per-conn tick packets, flush,
    /// shut down timed-out sockets. Lock-free clock via atomics.
    pub fn tickOnce(self: *Server, now_ms: i64) void {
        const age = self.world_age.fetchAdd(20, .acq_rel) + 20;
        // doDaylightCycle gates the clock (world age always advances).
        self.state_lock.lock();
        const cycle = self.gamerules[8];
        if (self.debug_start_ms != null) self.debug_ticks += 1;
        self.state_lock.unlock();
        if (cycle) {
            const tod = @mod(self.time_of_day.load(.acquire) + 20, @as(i64, 24000));
            self.time_of_day.store(tod, .release);
        }
        self.tickWeather();
        self.tickEffects();

        var batch: [256]RegistryEntry = undefined;
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
            e.conn.lock.unlock();
            players[n_players] = p;
            n_players += 1;
        }

        // Wander mobs + snapshot (demo pig auto-spawns when a world is present;
        // death respawns it after pig_cooldown ticks).
        var mobs: [256]entity.MobSnap = undefined;
        var n_mobs: usize = 0;
        self.ent_lock.lock();
        if (self.world != null) {
            var pigs: usize = 0;
            for (self.entities.items) |m| {
                if (m.kind == entity.MOB_PIG) pigs += 1;
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
            if (want_pig) {
                const id = self.eid_counter.fetchAdd(1, .acq_rel);
                self.entities.append(self.gpa, .{
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
        for (self.entities.items) |*m| m.wanderStep(0.5);
        for (self.entities.items) |m| {
            if (n_mobs >= mobs.len) break;
            mobs[n_mobs] = .{ .id = m.id, .kind = m.kind, .x = m.x, .y = m.y, .z = m.z, .yaw = m.yaw, .health = m.health };
            n_mobs += 1;
        }
        // Age item entities (ticks are 20tps units, +20 per 1Hz tick), tick
        // down pickup delays, merge stacks (vanilla xk merge), and mark the
        // 5-minute despawns. The item list is capped at max_items so the
        // fixed snapshot below is always complete.
        for (self.items.items) |*it| {
            it.age +|= 20;
            if (it.delay >= 20) it.delay -= 20 else it.delay = 0;
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
                } else if (self.items.items[mj].tryMerge(&self.items.items[mi2])) {
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
            };
            n_items += 1;
        }
        self.ent_lock.unlock();

        // Furnaces: 20-tick quanta under furn_lock; snapshot progress + slots
        // for viewer sync, record lit/unlit swaps for the world pass.
        // (NBT duped per tick, freed after the reconcile pass like items.)
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

        var claims = entity.ClaimSet{};
        // Environmental hazards from player snaps (no conn locks here;
        // world_lock is a leaf). Eyes block decides drown/suffocate, feet
        // block adds lava.
        const EnvFlag = struct { water: bool = false, lava: bool = false, suff: bool = false, cactus: bool = false };
        var envs: [256]EnvFlag = undefined;
        for (envs[0..@min(envs.len, n_players)]) |*f| f.* = .{};
        if (self.world) |pool| {
            self.world_lock.lock();
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
                    if (b.id == game_ids.cactus) envs[i].cactus = true;
                }
                if (view.peekBlock(pool, self.gpa, ex, feet, ez) catch null) |b| {
                    if (b.id == game_ids.flowing_lava or b.id == game_ids.lava) envs[i].lava = true;
                    if (b.id == game_ids.cactus) envs[i].cactus = true;
                }
            }
            self.world_lock.unlock();
        }
        var deaths: std.ArrayList(DeathInfo) = .empty;
        for (snap) |e| {
            e.conn.lock.lock();
            // Connections that never reach play: login timeout (anti-slowloris).
            // Login state gets a kick packet (0x00 exists there); handshaking /
            // status have no disconnect packet, so they are just dropped.
            if (e.conn.state != .play) {
                const stale = now_ms - e.conn.connected_at_ms > login_timeout_ms;
                const is_login = e.conn.state == .login;
                if (stale and !e.conn.dead) {
                    if (is_login) {
                        var db: [128]u8 = undefined;
                        const id: i32 = @intFromEnum(ids.LoginClient.disconnect);
                        var payload: [120]u8 = undefined;
                        var w = codec.PacketWriter.init(&payload);
                        w.writeString("{\"text\":\"Login timed out\"}") catch {};
                        if (codec.framePacket(id, w.written(), &db)) |f| {
                            e.conn.queueFramed(f) catch {};
                        } else |_| {}
                    }
                    e.conn.dead = true;
                    e.conn.close_after_flush = true;
                }
                const pending = e.conn.takeOutput() catch {
                    e.conn.lock.unlock();
                    continue;
                };
                const drop = e.conn.dead;
                e.conn.lock.unlock();
                if (pending.len > 0) writeFramed(e, self.io, pending);
                e.conn.allocator.free(pending);
                if (drop) e.stream.shutdown(self.io, .both) catch {};
                continue;
            }
            // Idle kick (`/setidletimeout`): play conns silent past the mark
            // get the jar-hardcoded screen. last_active_ms refreshes per frame.
            self.state_lock.lock();
            const idle_min = self.idle_timeout_min;
            self.state_lock.unlock();
            if (idle_min > 0 and !e.conn.dead and e.conn.last_active_ms > 0 and
                now_ms - e.conn.last_active_ms > @as(i64, idle_min) * 60000)
            {
                var db: [128]u8 = undefined;
                var payload: [96]u8 = undefined;
                var w = codec.PacketWriter.init(&payload);
                w.writeString("{\"text\":\"You have been idle for too long!\"}") catch {};
                if (codec.framePacket(@intFromEnum(ids.PlayClient.disconnect), w.written(), &db)) |f| {
                    e.conn.queueFramed(f) catch {};
                } else |_| {}
                e.conn.dead = true;
                e.conn.close_after_flush = true;
                const pending = e.conn.takeOutput() catch {
                    e.conn.lock.unlock();
                    continue;
                };
                e.conn.lock.unlock();
                if (pending.len > 0) writeFramed(e, self.io, pending);
                e.conn.allocator.free(pending);
                e.stream.shutdown(self.io, .both) catch {};
                continue;
            }
            const tod = self.time_of_day.load(.acquire);
            const action = e.conn.queueTick(now_ms, age, tod) catch {
                e.conn.lock.unlock();
                continue;
            };
            const timed_out = action == .timeout;
            if (!timed_out) {
                // Hunger + hazards before visibility (death gates pickup).
                var died_now = false;
                if (hungerTick(e.conn, self.config.difficulty)) died_now = true;
                if (!died_now) {
                    for (players[0..n_players], 0..) |p, i| {
                        if (p.eid != e.conn.eid or i >= envs.len) continue;
                        if (envTick(e.conn, envs[i].water, envs[i].lava, envs[i].suff, envs[i].cactus)) died_now = true;
                        break;
                    }
                }
                if (died_now) {
                    const dd = if (self.keepInv()) null else collectDeathDrops(e.conn);
                    deaths.append(self.gpa, .{
                        .conn = e.conn,
                        .eid = e.conn.eid,
                        .dd = dd,
                        .x = e.conn.pos_x,
                        .y = e.conn.pos_y,
                        .z = e.conn.pos_z,
                    }) catch {};
                }
                // Furnace window sync (open window 2 at a snapped furnace).
                if (e.conn.open_win) |ow| {
                    if (ow.id == 2) {
                        for (furn_snaps[0..n_furn]) |fs| {
                            if (fs.x != ow.x or fs.y != ow.y or fs.z != ow.z) continue;
                            // 39 slots: 0-2 furnace, 3-38 alias inv 9..44.
                            var all: [39]?item_mod.Stack = [_]?item_mod.Stack{null} ** 39;
                            all[0] = fs.in;
                            all[1] = fs.fuel;
                            all[2] = fs.out;
                            for (9..45) |i| all[i - 6] = e.conn.inv[i];
                            const wf = packets.frameWindowItemsAlloc(e.conn.allocator, 2, &all) catch null;
                            if (wf) |f| {
                                defer e.conn.allocator.free(f);
                                e.conn.queueFramed(f) catch {};
                            }
                            var pb: [16]u8 = undefined;
                            const props = [_]struct { p: i16, v: i16 }{
                                .{ .p = 0, .v = @intCast(@min(fs.cook, 32767)) },
                                .{ .p = 1, .v = @intCast(@min(fs.burn, 32767)) },
                                .{ .p = 2, .v = @intCast(@min(fs.total, 32767)) },
                            };
                            for (props) |pr| {
                                if (packets.frameProgressBar(2, pr.p, pr.v, &pb)) |f| {
                                    e.conn.queueFramed(f) catch {};
                                } else |_| {}
                            }
                            break;
                        }
                    }
                }
                var pctx = PresentCtx{ .viewer = e.conn, .range_blocks = @as(f64, @floatFromInt(self.view_distance)) * 16.0 + 16.0 };
                entity.reconcileViewer(e.conn, players[0..n_players], mobs[0..n_mobs], item_snaps[0..n_items], &claims, present, &pctx) catch {};
            }
            const pending = e.conn.takeOutput() catch {
                e.conn.lock.unlock();
                continue;
            };
            const had_output = pending.len > 0;
            e.conn.lock.unlock();
            if (had_output) writeFramed(e, self.io, pending);
            e.conn.allocator.free(pending);
            if (timed_out) e.stream.shutdown(self.io, .both) catch {};
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
            var cb: [16]u8 = undefined;
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
            self.world_lock.lock();
            for (furn_swaps[0..n_swaps], 0..) |sw, i| {
                if (self.world) |pool| {
                    const cur = view.peekBlock(pool, self.gpa, sw.x, sw.y, sw.z) catch null;
                    if (cur) |c| if (c.id == game_ids.furnace or c.id == game_ids.lit_furnace) {
                        view.applyBlock(pool, self.gpa, sw.x, sw.y, sw.z, if (sw.lit) game_ids.lit_furnace else game_ids.furnace, 0) catch {};
                        applied[i] = true;
                    };
                }
            }
            self.world_lock.unlock();
            for (furn_swaps[0..n_swaps], 0..) |sw, i| {
                if (!applied[i]) continue;
                self.broadcastBlockChange(null, sw.x, sw.y, sw.z, if (sw.lit) game_ids.lit_furnace else game_ids.furnace, 0) catch {};
            }
        }
        for (furn_snaps[0..n_furn]) |s| {
            if (s.in) |st| if (st.nbt) |n| self.gpa.free(n);
            if (s.fuel) |st| if (st.nbt) |n| self.gpa.free(n);
            if (s.out) |st| if (st.nbt) |n| self.gpa.free(n);
        }
        // Deaths from hunger/environment this tick: spawn drops (ent_lock),
        // persist emptied rows (savePlayer locks), broadcast death metadata.
        for (deaths.items) |*di| {
            if (di.dd) |*d| self.spawnDeathDrops(d, di.x, di.y, di.z);
        }
        {
            var mb: [32]u8 = undefined;
            for (deaths.items) |di| {
                const f = packets.frameEntityMetadata(di.eid, 0, &mb) catch continue;
                self.broadcastToTrackers(di.eid, f);
            }
        }
        for (deaths.items) |di| self.savePlayer(di.conn);
        deaths.deinit(self.gpa);
        // Periodic autosave (WAL-durable; save-all/stop flush SSTs on top).
        // Counter rolls over naturally; the modulo stays aligned.
        self.tick_counter += 1;
        if (self.world != null and self.getAutosave() and self.tick_counter % autosave_ticks == 0) {
            _ = self.saveAllPlayers();
        }
    }

    /// Broadcast a 0x23 block change to viewers tracking the chunk
    /// (sent-set membership), excluding the originator.
    /// Vanilla block step/break sound base for an id (`dig.<base>`).
    /// Material approximation of per-block `stepSound`: wood, grass
    /// (leaves use grass in vanilla), gravel, sand, glass (ice breaks
    /// like glass), cloth, snow, stone default.
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
    pub fn broadcastSound(self: *Server, sound: []const u8, x: f64, y: f64, z: f64, volume: f32, pitch: f32) void {
        var sb: [512]u8 = undefined;
        const f = packets.frameSoundEffect(sound, x, y, z, volume, pitch, &sb) catch return;
        var batch: [256]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            e.conn.lock.lock();
            const play = e.conn.state == .play and !e.conn.dead;
            const dx = x - e.conn.pos_x;
            const dy = y - e.conn.pos_y;
            const dz = z - e.conn.pos_z;
            const near = dx * dx + dy * dy + dz * dz <= 256.0;
            if (play and near) e.conn.queueFramed(f) catch {};
            e.conn.lock.unlock();
        }
    }

    pub fn broadcastBlockChange(self: *Server, exclude: ?*Conn, x: i32, y: u8, z: i32, id: game_ids.Id, meta: u4) !void {
        var fb: [32]u8 = undefined;
        const f = try packets.frameBlockChange(x, y, z, id, meta, &fb);
        const key = Conn.sentKey(@divFloor(x, 16), @divFloor(z, 16));
        var batch: [256]RegistryEntry = undefined;
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

    /// Broadcast an arm-swing 0x0B to viewers of (cx,cz), excluding originator.
    pub fn broadcastArmSwing(self: *Server, exclude: ?*Conn, cx: i32, cz: i32, eid: i32, anim: i8) !void {
        var fb: [16]u8 = undefined;
        const f = try packets.frameAnimation(eid, @bitCast(anim), &fb);
        const key = Conn.sentKey(cx, cz);
        var batch: [256]RegistryEntry = undefined;
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
        if (conn.config.gamemode == 1) return false;
        conn.health -= amount;
        if (conn.health <= 0) {
            conn.health = 0;
            conn.is_dead = true;
        }
        var hb: [32]u8 = undefined;
        if (packets.frameUpdateHealth(conn.health, conn.food, conn.saturation, &hb)) |f| {
            conn.queueFramed(f) catch {};
        } else |_| {}
        return conn.is_dead;
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
        x: f64,
        y: f64,
        z: f64,
    };

    /// Vanilla FoodStats.onUpdate quantized to 1Hz (+20 timer per tick).
    /// Natural-regeneration gamerule assumed on (no gamerules yet).
    /// Caller holds conn.lock. Returns true on starvation death.
    fn hungerTick(conn: *Conn, difficulty: u8) bool {
        if (conn.is_dead or conn.health <= 0) return false;
        if (conn.config.gamemode == 1) return false; // creative: nothing drains
        conn.food_timer +|= 20;
        var dirty = false;
        if (conn.exhaustion > 4.0) {
            conn.exhaustion -= 4.0;
            if (conn.saturation > 0) {
                conn.saturation = @max(conn.saturation - 1.0, 0.0);
            } else if (difficulty != 0) {
                conn.food = @max(conn.food - 1, 0);
            }
            dirty = true;
        }
        var died = false;
        if (conn.food >= 18 and conn.health < 20.0) {
            if (conn.food_timer >= 80) {
                conn.food_timer = 0;
                conn.health = @min(conn.health + 1.0, 20.0);
                conn.addExhaustion(3.0);
                dirty = true;
            }
        } else if (conn.food <= 0) {
            if (conn.food_timer >= 80) {
                conn.food_timer = 0;
                const hp = conn.health;
                if (hp > 10.0 or difficulty == 3 or (hp > 1.0 and difficulty == 2)) {
                    died = applyPlayerDamage(conn, 1.0);
                    dirty = true;
                }
            }
        } else {
            conn.food_timer = 0;
        }
        if (dirty and !died) {
            var hb: [32]u8 = undefined;
            if (packets.frameUpdateHealth(conn.health, conn.food, conn.saturation, &hb)) |f| {
                conn.queueFramed(f) catch {};
            } else |_| {}
        }
        return died;
    }

    /// Drown/lava/fire/suffocation/cactus for one tick (vanilla Entity
    /// rules, 1Hz-quantized; see deviations). Caller holds conn.lock.
    /// Returns true on death.
    fn envTick(conn: *Conn, water: bool, lava: bool, suff: bool, cactus: bool) bool {
        if (conn.is_dead) return false;
        var died = false;
        if (water) {
            conn.fire_ticks = 0; // extinguish on submersion
            if (conn.config.gamemode != 1) {
                conn.air -= 20;
                if (conn.air <= -20) {
                    conn.air = 0;
                    died = applyPlayerDamage(conn, 2.0); // then every second
                }
            }
        } else {
            conn.air = 300;
            if (!lava and conn.fire_ticks > 0) {
                conn.fire_ticks -|= 20;
                if (!died) died = applyPlayerDamage(conn, 1.0); // 1/s burning
            }
        }
        if (!died and lava and conn.config.gamemode != 1) {
            conn.fire_ticks = 300; // 15s of fire after the bath
            died = applyPlayerDamage(conn, 4.0); // lenient: vanilla is 4/tick
        }
        if (!died and suff) {
            died = applyPlayerDamage(conn, 4.0); // lenient: vanilla is 1/tick
        }
        if (conn.cactus_cd > 0) conn.cactus_cd -= 1;
        if (!died and cactus and conn.config.gamemode != 1 and conn.cactus_cd == 0) {
            conn.cactus_cd = 10; // ~0.5s between hits (no hurt-resistance yet)
            died = applyPlayerDamage(conn, 1.0);
        }
        return died;
    }

    /// Move every stack out of the victim's inventory + cursor (clears both).
    /// Caller MUST hold conn.lock. Always call on death (vanilla drops all).
    fn collectDeathDrops(conn: *Conn) DeathDrop {
        var dd = DeathDrop{ .eid = conn.eid };
        for (&conn.inv, 0..) |*slot, i| {
            if (i < 9 or i > 44) continue; // main 9..44 only (craft/armor vanish)
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
            self.ent_lock.lock();
            // NBT duped into server ownership (victim row keeps none).
            const owned_nbt: ?[]const u8 = if (st.nbt) |bytes| self.gpa.dupe(u8, bytes) catch null else null;
            const stored = item_mod.Stack{ .id = st.id, .count = st.count, .damage = st.damage, .nbt = owned_nbt };
            _ = self.spawnItem(stored, x + o[0], y + 0.1, z + o[2], 10);
            self.ent_lock.unlock();
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
        const creative = conn.config.gamemode == 1;
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
        const dmg = @ceil(fall.dist - 3.0);
        conn.lock.lock();
        const died = applyPlayerDamage(conn, dmg);
        const hp = conn.health;
        var dd: ?DeathDrop = if (died and !self.keepInv()) collectDeathDrops(conn) else null;
        const eid = conn.eid;
        conn.lock.unlock();
        var mb: [32]u8 = undefined;
        if (packets.frameEntityMetadata(eid, if (died) 0 else hp, &mb)) |f| {
            self.broadcastToTrackers(eid, f);
        } else |_| {}
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

    /// Find a furnace by block pos. Caller MUST hold furn_lock.
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

    /// Store an OWNED stack as a live item entity (always consumes `stack`:
    /// merged into a neighbor, appended, or freed on cap-hit). Merge-on-spawn
    /// mirrors the tick merge (same id/damage/NBT, centers within 1 block,
    /// combined count within max stack; survivor keeps max delay).
    /// Caller MUST hold ent_lock. Returns false when the cap dropped it.
    fn spawnItem(self: *Server, stack: item_mod.Stack, x: f64, y: f64, z: f64, delay: u32) bool {
        for (self.items.items) |*it| {
            const dx = it.x - x;
            const dz = it.z - z;
            if (dx * dx + dz * dz > 1.0) continue;
            if (!item_mod.canMerge(it.stack, stack)) continue;
            if (@as(u16, @intCast(it.stack.count)) + @as(u16, @intCast(stack.count)) > item_mod.maxStackSize(it.stack.id)) continue;
            it.stack.count += stack.count;
            it.delay = @max(it.delay, delay);
            var s: ?item_mod.Stack = stack;
            item_mod.freeStack(self.gpa, &s);
            return true;
        }
        if (self.items.items.len >= Server.max_items) {
            var s: ?item_mod.Stack = stack;
            item_mod.freeStack(self.gpa, &s);
            return false;
        }
        const id = self.eid_counter.fetchAdd(1, .acq_rel);
        self.items.append(self.gpa, .{
            .id = id,
            .x = x,
            .y = y,
            .z = z,
            .stack = stack,
            .delay = delay,
        }) catch {
            var s: ?item_mod.Stack = stack;
            item_mod.freeStack(self.gpa, &s);
            return false;
        };
        return true;
    }

    /// Roll + spawn vanilla drops for a survival break. Caller holds world_lock
    /// (ground scan reads the pool); takes rand_lock then ent_lock, in order.
    /// Per-single draw order mirrors harvestBlock: chance float (always 1.0
    /// for player breaks, drawn anyway), then 3 position offsets
    /// (rand*0.7+0.15 per axis, CFR `aji`/`alo` drop path). Resting y is the
    /// first solid top + 0.125 (no per-tick physics in the 1Hz model).
    fn spawnBreakDrops(self: *Server, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, x: i32, y: u8, z: i32, old_id: game_ids.Id, old_meta: u4) void {
        self.rand_lock.lock();
        if (self.drop_rand == null) self.drop_rand = java_random.JavaRandom.init(self.drop_seed);
        var rng = self.drop_rand.?;
        var rolls: [2]drops_mod.DropRoll = undefined;
        const n_rolls = drops_mod.rollDrops(old_id, old_meta, &rng, &rolls);
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
        // Resting y is resolved once: first solid top + 0.125 (the 1Hz model
        // has no per-tick physics; entities never move post-spawn).
        const gy = view.groundBlockY(pool, allocator, x, z, y) catch null;
        const ry: f64 = if (gy) |g| @as(f64, @floatFromInt(g)) + 1.125 else 0.125;
        var oi: usize = 0;
        var ri: usize = 0;
        while (ri < n_rolls) : (ri += 1) {
            const r = rolls[ri];
            var k: u8 = 0;
            while (k < r.singles and oi < n_spawn) : (k += 1) {
                const o = offs[oi];
                oi += 1;
                const stack = item_mod.Stack{ .id = r.item_id, .count = 1, .damage = r.damage, .nbt = null };
                self.ent_lock.lock();
                _ = self.spawnItem(stack, @as(f64, @floatFromInt(x)) + o[0], ry, @as(f64, @floatFromInt(z)) + o[2], 10);
                self.ent_lock.unlock();
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
        self.ent_lock.lock();
        const ok = self.spawnItem(q.stack, sx, sy, sz, 40);
        self.ent_lock.unlock();
        conn.lock.lock();
        const cur = conn.inv[@intCast(q.slot)];
        const f = packets.frameSetSlotAlloc(conn.allocator, 0, q.slot, cur) catch null;
        if (f) |fr| {
            defer conn.allocator.free(fr);
            conn.queueFramed(fr) catch {};
        }
        conn.lock.unlock();
        _ = ok; // spawnItem always consumes (cap-hit frees); nothing to do
    }

    /// Right-click routing: crafting table (58) + not sneaking opens window 1.
    /// Caller holds world_lock (pool peek). Returns true when the click became
    /// a UI open (serve loop must skip placement + broadcast for the event).
    fn tryOpenTable(self: *Server, conn: *Conn, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, b: *BlockEvent) bool {
        _ = self;
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
        conn.lock.lock();
        const sneak = conn.sneaking;
        conn.lock.unlock();
        if (sneak) return false; // sneak+click places against the table
        // Open UI (leaf conn lock; world_lock held by caller: world->conn).
        conn.lock.lock();
        conn.openTableUI(cx, @intCast(cy), cz);
        conn.lock.unlock();
        return true;
    }

    /// Right-click routing: furnace (61/62) + not sneaking opens window 2.
    /// Ensures server state, then queues 0x2D + full 0x30. Same locking as
    /// tryOpenTable. Returns true when the click became a UI open.
    fn tryOpenFurnace(self: *Server, conn: *Conn, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, b: *BlockEvent) bool {
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
        conn.lock.lock();
        const sneak = conn.sneaking;
        conn.lock.unlock();
        if (sneak) return false;
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
        var ob: [128]u8 = undefined;
        if (packets.frameOpenWindow(2, 2, "container.furnace", 3, &ob)) |of| {
            conn.queueFramed(of) catch {};
        } else |_| {}
        // Window 2 has 39 slots: 0-2 furnace, 3-38 alias inv 9..44.
        // (A 46-count dump would overrun the client's 39-slot container.)
        var all: [39]?item_mod.Stack = [_]?item_mod.Stack{null} ** 39;
        all[0] = fin;
        all[1] = ffu;
        all[2] = fout;
        for (9..45) |i| all[i - 6] = conn.inv[i];
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

    /// Window-2 click (slots 0-2 furnace, 3-38 alias inv 9-44). Runs on the
    /// serve thread with conn.lock held, taking furn_lock nested inside.
    /// (Safe: furn is never held while acquiring conn anywhere, and the
    /// ticker never nests. Documented exception to one-lock-at-a-time.)
    /// Mode-0 merges reuse Conn.clickPickupImplCell (same rules as window 0);
    /// shift/number-key moves are inlined below with item primitives.
    fn applyFurnaceClick(self: *Server, conn: *Conn, fc: FurnaceClick) void {
        conn.lock.lock();
        defer conn.lock.unlock();
        const ow = conn.open_win orelse return;
        if (ow.id != 2) return;
        self.furn_lock.lock();
        defer self.furn_lock.unlock();
        const f = self.findFurnace(ow.x, ow.y, ow.z) orelse return;
        switch (fc.mode) {
            0 => {
                if (fc.button != 0 and fc.button != 1) return;
                if (fc.slot == 2) {
                    // take output (cursor must be empty; no consume — the
                    // tick already consumed the input)
                    const out = f.output orelse return;
                    if (conn.cursor != null) return;
                    conn.cursor = out;
                    f.output = null;
                    const sf = packets.frameSetSlotAlloc(conn.allocator, 2, 2, null) catch return;
                    defer conn.allocator.free(sf);
                    conn.queueFramed(sf) catch {};
                    const cf = packets.frameSetSlotAlloc(conn.allocator, -1, -1, conn.cursor) catch return;
                    defer conn.allocator.free(cf);
                    conn.queueFramed(cf) catch {};
                    return;
                }
                const cell: *?item_mod.Stack = if (fc.slot == 0) &f.input else if (fc.slot == 1) &f.fuel else if (fc.slot >= 3 and fc.slot <= 38) &conn.inv[@as(usize, @intCast(fc.slot)) - 3 + 9] else return;
                if (!(conn.clickPickupImplCell(cell, fc.button) catch return)) return;
                const sf = packets.frameSetSlotAlloc(conn.allocator, 2, fc.slot, cell.*) catch return;
                defer conn.allocator.free(sf);
                conn.queueFramed(sf) catch {};
                const cf = packets.frameSetSlotAlloc(conn.allocator, -1, -1, conn.cursor) catch return;
                defer conn.allocator.free(cf);
                conn.queueFramed(cf) catch {};
            },
            1 => {
                // shift-click: output/input/fuel -> player inv; player inv ->
                // smeltable to input, fuel to fuel, else hotbar<->main.
                if (fc.button != 0 and fc.button != 1) return;
                var changed = false;
                if (fc.slot == 2 or fc.slot == 0 or fc.slot == 1) {
                    // move whole furnace stack into inv 9..44 (merge, then fill)
                    const cell: *?item_mod.Stack = if (fc.slot == 2) &f.output else if (fc.slot == 0) &f.input else &f.fuel;
                    if (cell.* != null) {
                        var i: usize = 9;
                        while (i <= 44) : (i += 1) {
                            const dst = conn.inv[i] orelse continue;
                            const src = cell.* orelse break;
                            if (!item_mod.canMerge(dst, src)) continue;
                            const room: i16 = @as(i16, item_mod.maxStackSize(dst.id)) - dst.count;
                            if (room <= 0) continue;
                            const n: i16 = @min(room, @as(i16, src.count));
                            if (n <= 0) continue;
                            conn.inv[i].?.count += @as(i8, @intCast(n));
                            cell.*.?.count -= @as(i8, @intCast(n));
                            changed = true;
                            if (cell.*.?.count <= 0) {
                                item_mod.freeStack(conn.allocator, cell);
                                break;
                            }
                        }
                        if (cell.* != null) {
                            var j: usize = 9;
                            while (j <= 44) : (j += 1) {
                                if (conn.inv[j] != null) continue;
                                conn.inv[j] = cell.*;
                                cell.* = null;
                                changed = true;
                                break;
                            }
                        }
                    }
                } else if (fc.slot >= 3 and fc.slot <= 38) {
                    const islot: usize = @as(usize, @intCast(fc.slot)) - 3 + 9;
                    const st = conn.inv[islot] orelse return;
                    if (smelting_mod.findResult(st.id, st.damage) != null) {
                        // smeltable -> input slot (merge, else fill if empty)
                        if (f.input) |dst| {
                            if (item_mod.canMerge(dst, st)) {
                                const room: i16 = @as(i16, item_mod.maxStackSize(dst.id)) - dst.count;
                                const n: i16 = @min(room, @as(i16, st.count));
                                if (n > 0) {
                                    f.input.?.count += @as(i8, @intCast(n));
                                    conn.inv[islot].?.count -= @as(i8, @intCast(n));
                                    changed = true;
                                    if (conn.inv[islot].?.count <= 0) item_mod.freeStack(conn.allocator, &conn.inv[islot]);
                                }
                            }
                        } else {
                            f.input = conn.inv[islot];
                            conn.inv[islot] = null;
                            changed = true;
                        }
                    } else if (smelting_mod.burnTime(st.id) > 0) {
                        // fuel -> fuel slot (merge, else fill)
                        if (f.fuel) |dst| {
                            if (item_mod.canMerge(dst, st)) {
                                const room: i16 = @as(i16, item_mod.maxStackSize(dst.id)) - dst.count;
                                const n: i16 = @min(room, @as(i16, st.count));
                                if (n > 0) {
                                    f.fuel.?.count += @as(i8, @intCast(n));
                                    conn.inv[islot].?.count -= @as(i8, @intCast(n));
                                    changed = true;
                                    if (conn.inv[islot].?.count <= 0) item_mod.freeStack(conn.allocator, &conn.inv[islot]);
                                }
                            }
                        } else {
                            f.fuel = conn.inv[islot];
                            conn.inv[islot] = null;
                            changed = true;
                        }
                    } else {
                        // hotbar<->main within the player range
                        const in_hotbar = islot >= 36;
                        const lo: usize = if (in_hotbar) 9 else 36;
                        const hi: usize = if (in_hotbar) 35 else 44;
                        var i: usize = lo;
                        while (i <= hi) : (i += 1) {
                            if (i == islot) continue;
                            const dst = conn.inv[i] orelse continue;
                            const s = conn.inv[islot] orelse break;
                            if (!item_mod.canMerge(dst, s)) continue;
                            const room: i16 = @as(i16, item_mod.maxStackSize(dst.id)) - dst.count;
                            if (room <= 0) continue;
                            const n: i16 = @min(room, @as(i16, s.count));
                            if (n <= 0) continue;
                            conn.inv[i].?.count += @as(i8, @intCast(n));
                            conn.inv[islot].?.count -= @as(i8, @intCast(n));
                            changed = true;
                            if (conn.inv[islot].?.count <= 0) {
                                item_mod.freeStack(conn.allocator, &conn.inv[islot]);
                                break;
                            }
                        }
                        if (conn.inv[islot] != null) {
                            var j: usize = lo;
                            while (j <= hi) : (j += 1) {
                                if (j == islot or conn.inv[j] != null) continue;
                                conn.inv[j] = conn.inv[islot];
                                conn.inv[islot] = null;
                                changed = true;
                                break;
                            }
                        }
                    }
                } else return;
                if (!changed) return;
                var all: [39]?item_mod.Stack = [_]?item_mod.Stack{null} ** 39;
                all[0] = f.input;
                all[1] = f.fuel;
                all[2] = f.output;
                for (9..45) |i| all[i - 6] = conn.inv[i];
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
                    const t = cell.*;
                    cell.* = conn.inv[h];
                    conn.inv[h] = t;
                    const sfa = packets.frameSetSlotAlloc(conn.allocator, 2, fc.slot, cell.*) catch return;
                    defer conn.allocator.free(sfa);
                    conn.queueFramed(sfa) catch {};
                    const sfb = packets.frameSetSlotAlloc(conn.allocator, 2, @as(i16, @intCast(h - 6)), conn.inv[h]) catch return;
                    defer conn.allocator.free(sfb);
                    conn.queueFramed(sfb) catch {};
                } else if (fc.slot >= 3 and fc.slot <= 38) {
                    const islot: usize = @as(usize, @intCast(fc.slot)) - 3 + 9;
                    if (islot == h) return;
                    const t = conn.inv[islot];
                    conn.inv[islot] = conn.inv[h];
                    conn.inv[h] = t;
                    const sfa = packets.frameSetSlotAlloc(conn.allocator, 2, fc.slot, conn.inv[islot]) catch return;
                    defer conn.allocator.free(sfa);
                    conn.queueFramed(sfa) catch {};
                    const sfb = packets.frameSetSlotAlloc(conn.allocator, 2, @as(i16, @intCast(h - 6)), conn.inv[h]) catch return;
                    defer conn.allocator.free(sfb);
                    conn.queueFramed(sfb) catch {};
                }
            },
            else => {},
        }
        _ = fc.action;
    }

    /// Break-driven close: every conn with a window open AT this block gets
    /// 0x2E; crafting grids drop as entities (furnace contents are dropped
    /// by the break handler itself via removeFurnace). Caller holds world_lock.
    fn closeWindowsAt(self: *Server, pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, x: i32, y: u8, z: i32) void {
        _ = pool;
        _ = allocator;
        var batch: [256]RegistryEntry = undefined;
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
            if (ow.id == 2) e.conn.open_win = null;
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
                self.ent_lock.lock();
                _ = self.spawnItem(s, px + 0.5, py + 1.0, pz + 0.5, 10);
                self.ent_lock.unlock();
            }
            flushEntry(e, self.io);
        }
    }

    /// Client-initiated close (0x0D): drop the crafting grid in front of the
    /// player. Furnace closes drop nothing (contents persist server-side).
    /// No 0x2E ack — the client already closed locally (vanilla flow).
    fn spawnTableClose(self: *Server, conn: *Conn, tc: TableClose) void {
        if (tc.window != 1) return;
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
            self.ent_lock.lock();
            _ = self.spawnItem(s, px + fx * 0.5 + 0.5, py + 1.32, pz + fz * 0.5 + 0.5, 10);
            self.ent_lock.unlock();
        }
    }

    /// Queue one framed packet on every conn tracking `eid` (attacker
    /// included — the attacker gets no client-side prediction for damage).
    /// One conn lock at a time; never nested with ent_lock/world_lock.
    fn broadcastToTrackers(self: *Server, eid: i32, framed: []const u8) void {
        var batch: [256]RegistryEntry = undefined;
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
    fn resolveAttack(self: *Server, attacker: *Conn, ev: AttackEvent) void {
        // --- mobs (ticker-owned list) ---
        var mob_hit = false;
        var mob_dead_id: ?i32 = null;
        var mob_hp: f32 = 0;
        self.ent_lock.lock();
        var mi: usize = 0;
        while (mi < self.entities.items.len) : (mi += 1) {
            if (self.entities.items[mi].id != ev.target_eid) continue;
            const m = &self.entities.items[mi];
            if (!attackInReach(ev.ax, ev.ay, ev.az, m.x, m.y + 0.5, m.z)) break;
            mob_hit = true;
            m.health -= ev.dmg;
            if (m.health <= 0) {
                const dead = self.entities.swapRemove(mi);
                mob_dead_id = dead.id;
                if (dead.kind == entity.MOB_PIG) self.pig_cooldown = 30;
            } else {
                mob_hp = m.health;
            }
            break;
        }
        self.ent_lock.unlock();
        if (mob_dead_id) |id| {
            var db: [8]u8 = undefined;
            if (packets.frameDestroyEntitiesFramed(&[_]i32{id}, &db)) |f| {
                self.broadcastToTrackers(id, f);
            } else |_| {}
            attacker.lock.lock();
            attacker.addExhaustion(0.3); // vanilla: charged per landed hit
            attacker.lock.unlock();
            return;
        }
        if (mob_hit) {
            var mb: [32]u8 = undefined;
            if (packets.frameEntityMetadata(ev.target_eid, mob_hp, &mb)) |f| {
                self.broadcastToTrackers(ev.target_eid, f);
            } else |_| {}
            attacker.lock.lock();
            attacker.addExhaustion(0.3); // vanilla: charged per landed hit
            attacker.lock.unlock();
            return;
        }
        // --- players ---
        var batch: [256]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            if (e.conn == attacker or e.conn.eid != ev.target_eid) continue;
            e.conn.lock.lock();
            if (e.conn.state != .play or e.conn.is_dead) {
                e.conn.lock.unlock();
                return;
            }
            if (!attackInReach(ev.ax, ev.ay, ev.az, e.conn.pos_x, e.conn.pos_y + 1.0, e.conn.pos_z)) {
                e.conn.lock.unlock();
                return;
            }
            const died = applyPlayerDamage(e.conn, ev.dmg);
            const hp = e.conn.health;
            var dd: ?DeathDrop = if (died and !self.keepInv()) collectDeathDrops(e.conn) else null;
            const px = e.conn.pos_x;
            const py = e.conn.pos_y;
            const pz = e.conn.pos_z;
            e.conn.lock.unlock();
            attacker.lock.lock();
            attacker.addExhaustion(0.3); // vanilla: charged per landed hit
            attacker.lock.unlock();
            flushEntry(e, self.io);
            // Show the new health on every tracker (attacker included).
            var mdb: [32]u8 = undefined;
            if (packets.frameEntityMetadata(ev.target_eid, if (died) 0 else hp, &mdb)) |f| {
                self.broadcastToTrackers(ev.target_eid, f);
            } else |_| {}
            if (dd) |*d| {
                self.spawnDeathDrops(d, px, py, pz);
                self.savePlayer(e.conn);
            }
            return;
        }
    }

    fn tickerLoop(self: *Server) void {
        while (true) {
            const one_s = std.Io.Clock.Duration{ .raw = std.Io.Duration.fromSeconds(1), .clock = .awake };
            std.Io.Timeout.sleep(.{ .duration = one_s }, self.io) catch return;
            const now = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
            self.tickOnce(now);
        }
    }

    /// Serve exactly one connection (status or login+bootstrap), no ticker.
    /// Used by tests; the production accept loop builds on this.
    pub fn serveOne(self: *Server, allocator: std.mem.Allocator) !void {
        self.gpa = allocator;
        var stream = try self.net.accept(self.io);
        defer stream.close(self.io);
        try serveConn(stream, self.io, allocator, self, self.eid_counter.fetchAdd(1, .acq_rel));
    }

    /// Accept loop: one OS thread per connection (blocking I/O).
    /// Tick-aligned flush + io_uring transport slot in here later.
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
        while (true) {
            const stream = try self.net.accept(self.io);
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

    /// Bind on all interfaces (production entry).
    pub fn bindAny(io: std.Io, port: u16, config: Config) !Server {
        const addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
        var srv = Server{ .net = try addr.listen(io, .{ .reuse_address = true }), .io = io, .config = config };
        srv.world_spawn = .{ config.spawn_x, config.spawn_y, config.spawn_z };
        return srv;
    }
};

/// Handle one connection: handshake/status/login + play bootstrap, then
/// stay open consuming play packets until close or tick-timeout.
/// Login completion sends join packets, the initial chunk burst (when the
/// server has a world), then PosLook, then registers for server ticks.
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
    server.register(conn, stream) catch {
        conn.deinit();
        allocator.destroy(conn);
        return error.RegistryFull;
    };
    defer server.unregister(conn);
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var writer = stream.writer(io, &wbuf);
    const rin = &reader.interface;
    const wout = &writer.interface;
    var entered = false;
    var events: std.ArrayList(Action) = .empty;
    defer events.deinit(allocator);
    var need_announce = false;
    while (true) {
        // read one Length-prefixed frame (byte-wise length, then body)
        var len: i32 = 0;
        var shift: u32 = 0;
        var header: [5]u8 = undefined;
        var hlen: usize = 0;
        while (true) {
            const b = rin.takeByte() catch |err| switch (err) {
                error.EndOfStream => return, // client closed
                else => return err,
            };
            header[hlen] = b;
            hlen += 1;
            if (hlen > 5) return error.VarIntTooLarge;
            len |= @as(i32, b & 0x7F) << @as(u5, @intCast(shift));
            shift += 7;
            if ((b & 0x80) == 0) break;
        }
        if (len < 0 or len > @import("conn.zig").max_frame_len) return error.FrameTooLarge;
        const ulen: usize = @intCast(len);
        conn.lock.lock();
        // feed header+body through Conn reassembly (also exercises it)
        conn.feedData(header[0..hlen]) catch {
            conn.lock.unlock();
            return error.FrameTooLarge;
        };
        var remaining = ulen;
        var chunk: [4096]u8 = undefined;
        while (remaining > 0) {
            const n = @min(remaining, chunk.len);
            rin.readSliceAll(chunk[0..n]) catch {
                conn.lock.unlock();
                return error.ReadFailed;
            };
            conn.feedData(chunk[0..n]) catch {
                conn.lock.unlock();
                return error.FrameTooLarge;
            };
            remaining -= n;
        }
        while (try conn.poll()) |f| {
            // Server list ping reads a live player count, not the copy taken
            // at accept time. Refresh under conn.lock (held here); status
            // pings are rare so the atomic load is free.
            if (conn.state == .status and f.id == @as(i32, @intFromEnum(ids.StatusServer.request))) {
                conn.config.online_count = @intCast(@min(server.play_count.load(.acquire), 255));
            }
            const action = try conn.handleFrame(f);
            if (action == .entered_play) entered = true;
            switch (action) {
                .block_set, .arm_swing, .chat, .attack, .command, .tab_complete, .qdrop, .table_close, .furnace_click => try events.append(allocator, action),
                else => {},
            }
        }
        if (entered) {
            entered = false;
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
            // Server defaults: difficulty is world-level (always applied);
            // fresh logins also inherit the default gamemode + world spawn
            // (an explicit /setworldspawn wins over the gen search above).
            server.state_lock.lock();
            const srv_diff = server.difficulty;
            const srv_gm = server.default_gamemode;
            const srv_spawn = server.world_spawn;
            const srv_spawn_set = server.world_spawn_set;
            server.state_lock.unlock();
            conn.config.difficulty = srv_diff;
            if (fresh) {
                const was_forced = conn.spawn_forced;
                conn.config.gamemode = srv_gm;
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
            if (server.loginRejected(conn.username[0..conn.username_len], conn.ip[0..conn.ip_len])) |rej| {
                server.rejectLogin(conn, rej);
                login_rejected = true;
            }
            if (!login_rejected) {
                // Own this player row from here on: bump the save epoch so
                // any older session's delayed save (quit/rejoin race, ghost
                // autosave) is dropped instead of overwriting us.
                conn.save_epoch = server.bumpSaveEpoch(conn.username[0..conn.username_len]);
                // Duplicate login (vanilla `initializeConnection`): kick any
                // OTHER fully-joined same-name conn. Without this, ghost
                // sessions linger in the registry and `findInSnap` (first
                // match) routes /gamemode, /tp, /tell, ... at the ghost —
                // the live session keeps its old gamemode and saves it back
                // on quit ("gamemode not saved"). Only announced targets:
                // a racing newcomer isn't announced yet, so two simultaneous
                // logins can't kick each other.
                {
                    var batch: [256]RegistryEntry = undefined;
                    const snap = server.snapshot(&batch);
                    defer Server.releaseSnap(snap);
                    const nm = conn.username[0..conn.username_len];
                    for (snap) |e| {
                        if (e.conn == conn) continue;
                        e.conn.lock.lock();
                        const dup = e.conn.state == .play and e.conn.announced and std.ascii.eqlIgnoreCase(e.conn.username[0..e.conn.username_len], nm);
                        e.conn.lock.unlock();
                        if (dup) server.kickEntry(e, "You logged in from another location!");
                    }
                }
                const tod = server.time_of_day.load(.acquire);
                try conn.queueJoinPackets(age, tod);
                // Current XP (vanilla re-sends S1F on login).
                var eb: [16]u8 = undefined;
                const xtotal: i16 = @truncate(conn.xp_total);
                if (packets.frameSetExperience(conn.xp_bar, @truncate(conn.xp_level), xtotal, &eb)) |xf| {
                    try conn.queueFramed(xf);
                } else |_| {}
            }
            // Login completion: inventory sync, chunks, PosLook last.
            // (announceJoin runs after unlock — it takes conn.lock itself).
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
                    try view.completeLogin(conn, server.chunkSource(pool), 0, cc.cx, cc.cz, server.view_distance, true);
                } else {
                    try conn.queuePlayerPosLook();
                }
                need_announce = true;
            }
        }
        if (conn.chunks_dirty) {
            // Movement / respawn follow-up (no-op without a world).
            if (server.world) |pool| {
                const radius: u8 = @min(conn.client_view orelse server.view_distance, server.view_distance);
                try view.syncPlayerChunks(conn, server.chunkSource(pool), 0, radius, true);
            } else {
                conn.chunks_dirty = false;
                conn.force_resync = false;
            }
        }
        // Async gen follow-up: holes requested earlier may have landed on
        // worker threads since. Gated on the pool sequence (idle = one atomic
        // load) and rate-limited to 1Hz: the rescan re-reads the view disk,
        // and a gen storm would otherwise redo 1k+ store reads every frame.
        // Capped at 16 pool reads per tick (spiral order => nearest holes
        // heal first) plus outbox backpressure: without the cap a serve
        // thread stalls in store reads while generation is active and
        // stops noticing disconnects (quit->save lands minutes late).
        if (server.world) |pool| {
            if (server.gen_pool) |gp| {
                if (conn.baseline_sent and conn.out.items.len < 262144) {
                    const s = gp.sequence();
                    if (s != conn.last_gen_seq) {
                        const now_ms = std.Io.Timestamp.now(server.io, .awake).toMilliseconds();
                        if (now_ms - conn.last_gen_retry_ms >= 1000) {
                            conn.last_gen_seq = s;
                            conn.last_gen_retry_ms = now_ms;
                            const radius: u8 = @min(conn.client_view orelse server.view_distance, server.view_distance);
                            const cc = conn.playerChunk();
                            try view.resyncDisk(conn, server.chunkSource(pool), 0, cc.cx, cc.cz, radius, true, 16);
                        }
                    }
                }
            }
        }
        const pending = try conn.takeOutput();
        const done = conn.close_after_flush or conn.dead;
        const cc_now = conn.playerChunk();
        conn.lock.unlock();
        // World mutation (single world lock) then viewer broadcast
        // (one conn lock at a time — never nested).
        if (events.items.len > 0) {
            if (server.world) |pool| {
                server.world_lock.lock();
                for (events.items, 0..) |*ev, i| {
                    switch (ev.*) {
                        .block_set => |*b| {
                            // Right-click on a crafting table (not sneaking)
                            // opens the 3x3 UI instead of placing.
                            if (b.id != game_ids.air) {
                                if (server.tryOpenTable(conn, pool, allocator, b)) {
                                    events.items[i] = .none;
                                    continue;
                                }
                                // Right-click on a furnace (not sneaking)
                                // opens window 2 instead of placing.
                                if (server.tryOpenFurnace(conn, pool, allocator, b)) {
                                    events.items[i] = .none;
                                    continue;
                                }
                            }
                            const old = view.peekBlock(pool, allocator, b.x, b.y, b.z) catch null;
                            view.applyBlock(pool, allocator, b.x, b.y, b.z, b.id, b.meta) catch {};
                            // Block sounds (S29 to nearby viewers; volume
                            // 1.0, pitch 0.8 like vanilla break/place).
                            const sx: f64 = @as(f64, @floatFromInt(b.x)) + 0.5;
                            const sy: f64 = @as(f64, @floatFromInt(b.y)) + 0.5;
                            const sz: f64 = @as(f64, @floatFromInt(b.z)) + 0.5;
                            if (b.id != game_ids.air) {
                                server.broadcastSound(Server.stepSound(b.id), sx, sy, sz, 1.0, 0.8);
                            }
                            // Survival break of a real block: vanilla drops.
                            // (Creative breaks drop nothing; missing chunks
                            // peek null and stay dropless.)
                            if (b.id == game_ids.air) {
                                if (old) |o| {
                                    if (o.id != game_ids.air) {
                                        server.broadcastSound(Server.stepSound(o.id), sx, sy, sz, 1.0, 0.8);
                                    }
                                    if (Server.shouldDropBreak(conn.config.gamemode, o.id, server.tileDrops())) {
                                        server.spawnBreakDrops(pool, allocator, b.x, b.y, b.z, o.id, o.meta);
                                    }
                                    // Table break with viewers: drop their
                                    // grids + close the windows.
                                    if (o.id == game_ids.crafting_table) server.closeWindowsAt(pool, allocator, b.x, b.y, b.z);
                                    // Furnace break: close viewer windows and
                                    // drop input/fuel/output as entities
                                    // (both modes, like table grids; the
                                    // block itself drops only in survival
                                    // via spawnBreakDrops above).
                                    if (o.id == game_ids.furnace or o.id == game_ids.lit_furnace) {
                                        server.closeWindowsAt(pool, allocator, b.x, b.y, b.z);
                                        var removed = server.removeFurnace(b.x, b.y, b.z);
                                        const fstacks = [_]*?item_mod.Stack{ &removed.input, &removed.fuel, &removed.output };
                                        for (fstacks) |st| {
                                            const s = st.* orelse continue;
                                            st.* = null;
                                            server.ent_lock.lock();
                                            _ = server.spawnItem(s, @as(f64, @floatFromInt(b.x)) + 0.5, @as(f64, @floatFromInt(b.y)) + 0.5, @as(f64, @floatFromInt(b.z)) + 0.5, 10);
                                            server.ent_lock.unlock();
                                        }
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                }
                server.world_lock.unlock();
            }
            for (events.items) |ev| {
                switch (ev) {
                    .block_set => |b| {
                        server.broadcastBlockChange(conn, b.x, b.y, b.z, b.id, b.meta) catch {};
                        // Survival break: vanilla 0.025 exhaustion per block.
                        if (b.id == game_ids.air) {
                            conn.lock.lock();
                            if (conn.config.gamemode == 0 and !conn.is_dead) conn.addExhaustion(0.025);
                            conn.lock.unlock();
                        }
                    },
                    .qdrop => |q| server.spawnQDrop(conn, q),
                    .table_close => |t| server.spawnTableClose(conn, t),
                    .furnace_click => |f| server.applyFurnaceClick(conn, f),
                    .arm_swing => |a| server.broadcastArmSwing(conn, cc_now.cx, cc_now.cz, conn.eid, a) catch {},
                    .chat => |m| server.broadcastChat(conn.chat_buf[0..m.json_len]),
                    .attack => |a| server.resolveAttack(conn, a),
                    .tab_complete => |m| server.handleTabComplete(conn, conn.tab_buf[0..m.json_len]),
                    .command => |m| {
                        const text = conn.chat_buf[0..m.json_len];
                        server.handleCommand(conn, text);
                        if (Server.isStopCommand(text)) {
                            // Flush the stopping reply first, then
                            // persist + exit. (Ticker/serve loops die with us;
                            // the WAL makes the flush a performance plea, not
                            // a durability requirement.)
                            conn.lock.lock();
                            const tail = conn.takeOutput() catch &[_]u8{};
                            const nm = conn.username[0..conn.username_len];
                            var nm_copy: [16]u8 = undefined;
                            @memcpy(nm_copy[0..nm.len], nm);
                            const nm_len = nm.len;
                            conn.lock.unlock();
                            defer conn.allocator.free(tail);
                            if (tail.len > 0) {
                                conn.wlock.lock();
                                defer conn.wlock.unlock();
                                wout.writeAll(tail) catch {};
                                wout.flush() catch {};
                            }
                            _ = server.saveAllPlayers();
                            if (server.world) |pool| pool.flushAll() catch {};
                            std.log.info("in-game stop by {s}: saved players, flushed. bye.", .{nm_copy[0..nm_len]});
                            std.process.exit(0);
                        }
                    },
                    else => {},
                }
            }
            events.clearRetainingCapacity();
        }
        // Landing resolved once per serve pass (water check + fall damage).
        server.resolvePendingFall(conn);
        if (pending.len > 0) {
            conn.wlock.lock();
            wout.writeAll(pending) catch {
                conn.wlock.unlock();
                conn.allocator.free(pending);
                return;
            };
            wout.flush() catch {
                conn.wlock.unlock();
                conn.allocator.free(pending);
                return;
            };
            conn.wlock.unlock();
        }
        conn.allocator.free(pending);
        if (done) return;
        if (need_announce) {
            need_announce = false;
            server.announceJoin(conn, stream) catch {};
        }
    }
}

/// Read one framed packet body from a client-side reader (test helper).
fn readFrame(r: *std.Io.Reader, buf: []u8) !struct { id: i32, body: []u8 } {
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
    try srv.announceJoin(alice.conn, alice.srv_stream);
    try std.testing.expectEqual(@as(u32, 1), srv.play_count.load(.acquire));
    try srv.announceJoin(bob.conn, bob.srv_stream);
    try std.testing.expectEqual(@as(u32, 2), srv.play_count.load(.acquire));
    // Re-announce is idempotent for the count.
    try srv.announceJoin(bob.conn, bob.srv_stream);
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
    // announce both (each conn announces itself on login, like serveConn does).
    // Duplicates are harmless (idempotent player list); drain both copies.
    try srv.announceJoin(alice.conn, alice.srv_stream);
    try srv.announceJoin(bob.conn, bob.srv_stream);
    // Alice learns Bob; Bob learns Alice (persistent readers: fresh ones
    // would drop coalesced bytes buffered by a previous reader)
    var arb: [128]u8 = undefined;
    var afb: [128]u8 = undefined;
    var arr = alice.cli_stream.reader(io, &arb);
    var brb: [128]u8 = undefined;
    var brr = bob.cli_stream.reader(io, &brb);
    // two join frames per side (one per announceJoin call)
    for ([2]struct { r : *std.Io.net.Stream.Reader, want : []const u8 }{ .{ .r = &arr, .want = "Bob" }, .{ .r = &brr, .want = "Alice" } }) |side| {
        var n: usize = 0;
        while (n < 2) : (n += 1) {
            const f = try readFrame(&side.r.interface, &afb);
            try std.testing.expectEqual(@as(i32, 0x38), f.id);
            var pr = codec.PacketReader.init(f.body);
            try std.testing.expectEqualStrings(side.want, try pr.readString());
            try std.testing.expect(try pr.readBool());
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
    // Bob leaves: Alice sees remove
    srv.unregister(bob.conn);
    {
        const f = try readFrame(&arr.interface, &afb);
        try std.testing.expectEqual(@as(i32, 0x38), f.id);
        var pr = codec.PacketReader.init(f.body);
        try std.testing.expectEqualStrings("Bob", try pr.readString());
        try std.testing.expect(!(try pr.readBool())); // online=false
    }
    srv.unregister(alice.conn);
    try std.testing.expectEqual(@as(usize, 0), srv.registry.items.len);
}

test "broadcastBlockChange/ArmSwing target sent-set viewers only" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
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
    // register is silent; one announceJoin drives the join broadcast both ways.
    try srv.announceJoin(alice.conn, alice.srv_stream);
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
        const g = try readFrame(&brr.interface, &bfb);
        try std.testing.expectEqual(@as(i32, 0x38), g.id);
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
    var c = Conn.init(a, std.testing.io, .{ .gamemode = 0 }, 7);
    defer c.deinit();
    c.state = .play;
    // exhaustion > 4 burns saturation first, then food (normal)
    c.exhaustion = 5.0;
    c.saturation = 5.0;
    try std.testing.expect(!Server.hungerTick(&c, 2));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c.exhaustion, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), c.saturation, 1e-6);
    try std.testing.expectEqual(@as(i16, 20), c.food);
    // saturation 0 -> food drops (peaceful exempts)
    c.exhaustion = 5.0;
    c.saturation = 0;
    try std.testing.expect(!Server.hungerTick(&c, 2));
    try std.testing.expectEqual(@as(i16, 19), c.food);
    c.exhaustion = 5.0;
    try std.testing.expect(!Server.hungerTick(&c, 0));
    try std.testing.expectEqual(@as(i16, 19), c.food); // peaceful: no drain
    // regen at food 18+: +1 hp and +3 exhaustion every 80 timer
    c.health = 10.0;
    c.food = 18;
    c.food_timer = 60;
    c.exhaustion = 0;
    try std.testing.expect(!Server.hungerTick(&c, 2));
    try std.testing.expectApproxEqAbs(@as(f32, 11.0), c.health, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), c.exhaustion, 1e-6);
    // starve: normal hits at hp>1, spares hp==1; hard always hits
    c.health = 2.0;
    c.food = 0;
    c.food_timer = 60;
    try std.testing.expect(!Server.hungerTick(&c, 2));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c.health, 1e-6);
    c.food_timer = 60;
    try std.testing.expect(!Server.hungerTick(&c, 2));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c.health, 1e-6); // spared
    c.food_timer = 60;
    try std.testing.expect(Server.hungerTick(&c, 3));
    try std.testing.expect(c.is_dead); // hard: killing blow
    { const o = try c.takeOutput(); defer a.free(o); }
}

test "env: drown countdown, lava+fire, suffocate; fall resolution" {
    const a = std.testing.allocator;
    var c = Conn.init(a, std.testing.io, .{ .gamemode = 0 }, 7);
    defer c.deinit();
    c.state = .play;
    // drown: 15 ticks grace (air 300->0), damage on the 16th
    var i: usize = 0;
    while (i < 15) : (i += 1) try std.testing.expect(!Server.envTick(&c, true, false, false, false));
    try std.testing.expectEqual(@as(i16, 0), c.air);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), c.health, 1e-6);
    try std.testing.expect(!Server.envTick(&c, true, false, false, false));
    try std.testing.expectApproxEqAbs(@as(f32, 18.0), c.health, 1e-6);
    try std.testing.expectEqual(@as(i16, 0), c.air);
    // surface resets air
    try std.testing.expect(!Server.envTick(&c, false, false, false, false));
    try std.testing.expectEqual(@as(i16, 300), c.air);
    // lava: 4 dmg + 300 fire ticks; fire burns 1/tick after leaving
    try std.testing.expect(!Server.envTick(&c, false, true, false, false));
    try std.testing.expectApproxEqAbs(@as(f32, 14.0), c.health, 1e-6);
    try std.testing.expectEqual(@as(u32, 300), c.fire_ticks);
    try std.testing.expect(!Server.envTick(&c, false, false, false, false));
    try std.testing.expectApproxEqAbs(@as(f32, 13.0), c.health, 1e-6);
    // water extinguishes instead of burning
    c.fire_ticks = 100;
    try std.testing.expect(!Server.envTick(&c, true, false, false, false));
    try std.testing.expectEqual(@as(u32, 0), c.fire_ticks);
    // suffocate: 4 per tick
    try std.testing.expect(!Server.envTick(&c, false, false, true, false));
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), c.health, 1e-6);
    // cactus: 1.0 per touch, throttled to ~1/0.5s (10-tick cooldown)
    try std.testing.expect(!Server.envTick(&c, false, false, false, true));
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), c.health, 1e-6);
    try std.testing.expect(!Server.envTick(&c, false, false, false, true));
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), c.health, 1e-6); // cooldown: no double-hit
    // creative is immune to cactus
    c.config.gamemode = 1;
    c.cactus_cd = 0;
    try std.testing.expect(!Server.envTick(&c, false, false, false, true));
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), c.health, 1e-6);
    c.config.gamemode = 0;
    // fall: ceil(dist-3) without a world (no water to save us)
    c.pending_fall = .{ .dist = 5.5, .x = 0, .y = 64, .z = 0 };
    var srv = Server{ .net = undefined, .io = std.testing.io, .config = .{}, .gpa = a };
    defer srv.registry.deinit(a);
    srv.resolvePendingFall(&c);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), c.health, 1e-6); // 8-3
    try std.testing.expect(c.pending_fall == null);
    // short falls are free
    c.pending_fall = .{ .dist = 3.0, .x = 0, .y = 64, .z = 0 };
    srv.resolvePendingFall(&c);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), c.health, 1e-6);
    { const o = try c.takeOutput(); defer a.free(o); }
}

test "dig-drop gate: survival+adventure drop, creative/gamerule/air do not" {
    try std.testing.expect(Server.shouldDropBreak(0, .stone, true));
    try std.testing.expect(Server.shouldDropBreak(2, .stone, true));
    try std.testing.expect(!Server.shouldDropBreak(1, .stone, true));
    try std.testing.expect(!Server.shouldDropBreak(0, .stone, false));
    try std.testing.expect(!Server.shouldDropBreak(0, .air, true));
}

test "resolveAttack: mob damage/death/destroy, PvP, reach, pig respawn timer" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.registry.deinit(a);
    defer {
        srv.ent_lock.lock();
        srv.entities.deinit(a);
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
            c.* = Conn.init(a, io, .{ .gamemode = 0 }, eid);
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
    // No announceJoin: streams stay clean for deterministic reads.
    var arb: [128]u8 = undefined;
    var afb: [512]u8 = undefined;
    var arr = alice.cli_stream.reader(io, &arb);
    var brb: [128]u8 = undefined;
    var bfb: [512]u8 = undefined;
    var brr = bob.cli_stream.reader(io, &brb);
    // Pig id 50 at (10,64,10), hp 10; alice tracks it.
    srv.ent_lock.lock();
    try srv.entities.append(a, .{ .id = 50, .kind = entity.MOB_PIG, .x = 10, .y = 64, .z = 10, .yaw = 0, .health = 10.0, .home_x = 10, .home_z = 10, .patrol_r = 4 });
    srv.ent_lock.unlock();
    try alice.conn.tracked.put(50, .{ .x = 0, .y = 0, .z = 0, .yaw = 0, .pitch = 0 });
    // Non-lethal hit: 10 -> 7, metadata to trackers.
    srv.resolveAttack(alice.conn, .{ .target_eid = 50, .dmg = 3, .ax = 10, .ay = 64, .az = 10 });
    srv.ent_lock.lock();
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), srv.entities.items[0].health, 1e-6);
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
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), srv.entities.items[0].health, 1e-6);
    srv.ent_lock.unlock();
    // Lethal hit: destroy broadcast, mob removed, respawn timer armed.
    srv.resolveAttack(alice.conn, .{ .target_eid = 50, .dmg = 10, .ax = 10, .ay = 64, .az = 10 });
    srv.ent_lock.lock();
    try std.testing.expectEqual(@as(usize, 0), srv.entities.items.len);
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
    // Lethal PvP: death screen + dead flag; further hits ignored.
    srv.resolveAttack(alice.conn, .{ .target_eid = 2, .dmg = 30, .ax = 20, .ay = 64, .az = 20 });
    try std.testing.expect(bob.conn.is_dead);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), bob.conn.health, 1e-6);
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
    try std.testing.expectEqual(@as(usize, 1), srv.entities.items.len);
    try std.testing.expectEqual(@as(i32, 90), srv.entities.items[0].kind);
}

test "tickOnce spawns/tracks/despawns players + mobs" {    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.registry.deinit(a);
    defer {
        srv.ent_lock.lock();
        srv.entities.deinit(a);
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
        try srv.entities.append(a, .{
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
            try std.testing.expectEqual(@as(u8, entity.MOB_PIG), try pr.readByte());
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
        srv.entities.items[0].x = 500.0;
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

test "player save/load roundtrip via pool (pos/health/inv/NBT)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
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
    c.pos_x = -12.5;
    c.pos_y = 70.0;
    c.pos_z = 44.25;
    c.yaw = 90.0;
    c.pitch = -15.0;
    c.health = 13.5;
    c.food = 17;
    c.saturation = 3.25;
    c.selected = 4;
    c.config.gamemode = 0;
    c.config.spawn_x = 8;
    c.config.spawn_y = 70;
    c.config.spawn_z = 8;
    const tag = [_]u8{ 0x0A, 0x00, 0x03, 0x64, 0x75, 0x6D };
    const owned = try a.dupe(u8, &tag);
    c.inv[36] = .{ .id = game_ids.diamond_sword, .count = 1, .damage = 0, .nbt = owned };
    c.inv[10] = .{ .id = game_ids.stone, .count = 64, .damage = 0, .nbt = null };
    c.cursor = .{ .id = game_ids.dirt, .count = 5, .damage = 0, .nbt = null };
    srv.savePlayer(c);
    // Mutate everything; load must restore.
    c.pos_x = 999;
    c.health = 1.0;
    item_mod.freeStack(a, &c.inv[36]);
    c.inv[36] = null;
    c.inv[10] = null;
    c.cursor = null;
    c.selected = 0;
    c.config.gamemode = 1;
    c.lock.lock();
    try std.testing.expect(srv.loadPlayer(c));
    c.lock.unlock();
    try std.testing.expectApproxEqAbs(-12.5, c.pos_x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 90.0), c.yaw, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 13.5), c.health, 1e-6);
    try std.testing.expectEqual(@as(i16, 17), c.food);
    try std.testing.expectEqual(@as(u8, 4), c.selected);
    try std.testing.expectEqual(@as(u8, 0), c.config.gamemode);
    try std.testing.expectEqual(game_ids.diamond_sword, c.inv[36].?.id);
    try std.testing.expectEqualSlices(u8, &tag, c.inv[36].?.nbt.?);
    try std.testing.expectEqual(game_ids.stone, c.inv[10].?.id);
    try std.testing.expectEqual(game_ids.dirt, c.cursor.?.id);
    try std.testing.expectEqual(@as(i32, 8), c.config.spawn_x);
    // No save -> false. Corrupt row -> false (treated as fresh spawn).
    const c2 = try a.create(Conn);
    defer a.destroy(c2);
    c2.* = Conn.init(a, io, .{}, 8);
    c2.state = .play;
    @memcpy(c2.username[0.."Al".len], "Al");
    c2.username_len = 2;
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

test "commands help/list/save-all/unknown (+ console null-sender)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
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

test "permissions gate commands: op/deop/grant/deny/show/clear/reload" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
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
        try std.testing.expectEqual(@as(u8, 4), srv.perms.?.levelFor("AliceP"));
    }
    // /help now lists privileged commands for Alice (vanilla 7-per-page).
    srv.handleCommand(alice, "/help");
    const h1_lines = [_][]const u8{
        "--- Showing help page 1 of 7 (/help <page>) ---",
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
    defer srv.registry.deinit(a);
    defer if (srv.perms) |*db| db.deinit();
    defer {
        srv.ent_lock.lock();
        srv.entities.deinit(a);
        srv.items.deinit(a);
        srv.ent_lock.unlock();
    }
    const mk = struct {
        fn run(name: []const u8, id: i32) !*Conn {
            const c = try a.create(Conn);
            errdefer a.destroy(c);
            c.* = Conn.init(a, io, .{}, id);
            c.state = .play;
            @memcpy(c.username[0..name.len], name);
            c.username_len = name.len;
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
    try srv.registry.append(a, .{ .conn = alice, .stream = undefined });
    try srv.registry.append(a, .{ .conn = bob, .stream = undefined });
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
    try std.testing.expectEqual(@as(u8, 0), bob.config.gamemode);
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
    try std.testing.expectEqual(@as(u8, 1), alice.config.gamemode);
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
    try std.testing.expectEqual(@as(u8, 2), bob.config.gamemode);
    const _d1b = try readChat(alice);
    defer a.free(_d1b);
    try std.testing.expectEqualStrings("{\"text\":\"Set BobG's game mode to adventure\"}", _d1b);
    // /give: 64 dirt to Bob (first empty main slot = 9).
    srv.handleCommand(alice, "/give BobG 1 64");
    {
        try std.testing.expectEqual(game_ids.stone, bob.inv[9].?.id);
        try std.testing.expectEqual(@as(i8, 64), bob.inv[9].?.count);
        var fr = try Drain.run(bob);
        defer Drain.free(&fr);
        const sb = Drain.find(&fr, 0x2F) orelse return error.NoSetSlot;
        var r = codec.PacketReader.init(sb);
        _ = try r.readByte();
        try std.testing.expectEqual(@as(i16, 9), try r.readShort());
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
        // dirt merges into slot 9 (64/64 full) -> first empty slot 10.
        try std.testing.expectEqual(game_ids.dirt, bob.inv[10].?.id);
        try std.testing.expectEqual(@as(i8, 5), bob.inv[10].?.count);
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
    for (9..45) |s| bob.inv[s] = .{ .id = game_ids.planks, .count = 64, .damage = 0, .nbt = null };
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


test "furnace: take output moves stack to cursor + syncs" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
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
