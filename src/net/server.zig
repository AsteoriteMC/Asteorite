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
const codec = @import("codec.zig");
const view = @import("../sim/view.zig");
const shard_mod = @import("../world/shard.zig");
const player_db = @import("../sim/players.zig");
const item_mod = @import("../item.zig");
const spin = @import("../sim/spin.zig");
const packets = @import("../proto/v5/packets.zig");
const ids = @import("../proto/v5/ids.zig");
const entity = @import("../sim/entity.zig");
const v5gen = @import("../worldgen/v5/gen.zig");
const v5serve = @import("../worldgen/v5/serve.zig");

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
    pig_spawned: bool = false,
    /// Ticks until the demo pig respawns after death (tickOnce is 1Hz).
    /// Set on pig death; first spawn is immediate via pig_spawned.
    pig_cooldown: u32 = 0,
    world_age: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    time_of_day: std.atomic.Value(i64) = std.atomic.Value(i64).init(6000),
    /// Ticks since boot (1Hz ticker). Periodic player save every 300.
    tick_counter: u64 = 0,
    /// Autosave cadence in ticks (5 min at 1Hz).
    pub const autosave_ticks: u64 = 300;

    pub fn bind(io: std.Io, port: u16, config: Config) !Server {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        return .{ .net = try addr.listen(io, .{}), .io = io, .config = config };
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
        conn.announced = true;
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
        for (&conn.inv, d.inv) |*slot, saved| {
            item_mod.freeStack(conn.allocator, slot);
            slot.* = item_mod.cloneStack(conn.allocator, saved) catch null;
        }
        item_mod.freeStack(conn.allocator, &conn.cursor);
        conn.cursor = item_mod.cloneStack(conn.allocator, d.cursor) catch null;
        conn.selected = d.selected;
        conn.click_seq = 0;
        conn.click_seen = false;
        return true;
    }

    /// Snapshot one conn (conn.lock taken here) and persist under world_lock.
    /// Skips conns that never reached play or have no username. Safe to call
    /// with no locks held (unregister, console, ticker all qualify).
    pub fn savePlayer(self: *Server, conn: *Conn) void {
        const pool = self.world orelse return;
        conn.lock.lock();
        if (conn.state != .play or conn.username_len == 0) {
            conn.lock.unlock();
            return;
        }
        var d = player_db.Data{};
        const name = conn.username[0..conn.username_len];
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
        // Clone NBT into server-owned buffers (conn dies under us in the
        // unregister path; encode only borrows while world_lock is held).
        for (&d.inv, conn.inv) |*dst, src| {
            dst.* = item_mod.cloneStack(self.gpa, src) catch null;
        }
        d.cursor = item_mod.cloneStack(self.gpa, conn.cursor) catch null;
        conn.lock.unlock();
        defer player_db.freeData(self.gpa, &d);
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

    /// In-game + console command core. `sender` null = server console (reply
    /// goes to stdout); otherwise the reply is a chat message to the sender
    /// only. Unknown commands get a usage hint, never a kick.
    pub fn handleCommand(self: *Server, sender: ?*Conn, text: []const u8) void {
        // Split "/cmd args..." (text[0] == '/' guaranteed by caller).
        var cmd = text[1..];
        if (std.mem.indexOfScalar(u8, cmd, ' ')) |sp| cmd = cmd[0..sp];
        if (std.mem.eql(u8, cmd, "help")) {
            self.reply(sender, "Commands: /help /list /save-all");
        } else if (std.mem.eql(u8, cmd, "list")) {
            var batch: [256]RegistryEntry = undefined;
            const snap = self.snapshot(&batch);
            defer releaseSnap(snap);
            // Collect play-state names first (snapshot refs keep conns alive
            // across the lock-free build below).
            var names: [256][]const u8 = undefined;
            var n: usize = 0;
            for (snap) |e| {
                if (n >= names.len) break;
                e.conn.lock.lock();
                const play = e.conn.state == .play;
                e.conn.lock.unlock();
                if (!play) continue;
                names[n] = e.conn.username[0..e.conn.username_len];
                n += 1;
            }
            // Usernames are charset-validated at login ([A-Za-z0-9_]), so no
            // JSON escaping is needed here.
            var out: [1024]u8 = undefined;
            var ow: usize = 0;
            ow += (std.fmt.bufPrint(out[ow..], "Connected ({d}):", .{n}) catch {
                self.reply(sender, "Connected (?)");
                return;
            }).len;
            for (names[0..n], 0..) |nm, i| {
                const pre: []const u8 = if (i == 0) "" else ",";
                ow += (std.fmt.bufPrint(out[ow..], "{s} {s}", .{ pre, nm }) catch break).len;
            }
            self.reply(sender, out[0..ow]);
        } else if (std.mem.eql(u8, cmd, "save-all")) {
            const n = self.saveAllPlayers();
            if (self.world) |pool| pool.flushAll() catch {};
            var msg: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&msg, "Saved {d} player(s).", .{n}) catch "Saved.";
            self.reply(sender, s);
        } else {
            self.reply(sender, "Unknown command. Try /help");
        }
    }

    fn reply(self: *Server, sender: ?*Conn, text: []const u8) void {
        _ = self;
        if (sender) |c| {
            var jb: [1090]u8 = undefined;
            var fb: [1152]u8 = undefined;
            const json = std.fmt.bufPrint(&jb, "{{\"text\":\"{s}\"}}", .{text}) catch return;
            const f = packets.frameChat(json, &fb) catch return;
            c.lock.lock();
            defer c.lock.unlock();
            if (c.state != .play or c.dead) return;
            c.queueFramed(f) catch {};
        } else {
            std.log.info("(console) {s}", .{text});
        }
    }

    /// One server tick: advance clock, queue per-conn tick packets, flush,
    /// shut down timed-out sockets. Lock-free clock via atomics.
    pub fn tickOnce(self: *Server, now_ms: i64) void {
        const age = self.world_age.fetchAdd(20, .acq_rel) + 20;
        const tod = @mod(self.time_of_day.load(.acquire) + 20, @as(i64, 24000));
        self.time_of_day.store(tod, .release);

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
        self.ent_lock.unlock();

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
            const action = e.conn.queueTick(now_ms, age, tod) catch {
                e.conn.lock.unlock();
                continue;
            };
            const timed_out = action == .timeout;
            if (!timed_out) {
                var pctx = PresentCtx{ .viewer = e.conn, .range_blocks = @as(f64, @floatFromInt(self.view_distance)) * 16.0 + 16.0 };
                entity.reconcileViewer(e.conn, players[0..n_players], mobs[0..n_mobs], present, &pctx) catch {};
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
        // Periodic autosave (WAL-durable; save-all/stop flush SSTs on top).
        // Counter rolls over naturally; the modulo stays aligned.
        self.tick_counter += 1;
        if (self.world != null and self.tick_counter % autosave_ticks == 0) {
            _ = self.saveAllPlayers();
        }
    }

    /// Broadcast a 0x23 block change to viewers tracking the chunk
    /// (sent-set membership), excluding the originator.
    pub fn broadcastBlockChange(self: *Server, exclude: ?*Conn, x: i32, y: u8, z: i32, id: u16, meta: u4) !void {
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

    /// Queue one framed packet on every conn tracking `eid` (attacker
    /// included — the attacker gets no client-side prediction for damage).
    /// One conn lock at a time; never nested with ent_lock/world_lock.
    fn broadcastToTrackers(self: *Server, eid: i32, framed: []const u8) void {
        var batch: [256]RegistryEntry = undefined;
        const snap = self.snapshot(&batch);
        defer releaseSnap(snap);
        for (snap) |e| {
            e.conn.lock.lock();
            if (e.conn.tracked.contains(eid)) {
                e.conn.queueFramed(framed) catch {};
            }
            e.conn.lock.unlock();
            flushEntry(e, self.io);
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
            return;
        }
        if (mob_hit) {
            var mb: [32]u8 = undefined;
            if (packets.frameEntityMetadata(ev.target_eid, mob_hp, &mb)) |f| {
                self.broadcastToTrackers(ev.target_eid, f);
            } else |_| {}
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
            e.conn.health -= ev.dmg;
            var hp = e.conn.health;
            if (hp <= 0) {
                hp = 0;
                e.conn.is_dead = true;
            }
            e.conn.health = hp;
            var hb: [32]u8 = undefined;
            if (packets.frameUpdateHealth(hp, e.conn.food, e.conn.saturation, &hb)) |f| {
                e.conn.queueFramed(f) catch {};
            } else |_| {}
            e.conn.lock.unlock();
            flushEntry(e, self.io);
            // Show the new health on every tracker (attacker included).
            var mdb: [32]u8 = undefined;
            if (packets.frameEntityMetadata(ev.target_eid, hp, &mdb)) |f| {
                self.broadcastToTrackers(ev.target_eid, f);
            } else |_| {}
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
        return .{ .net = try addr.listen(io, .{ .reuse_address = true }), .io = io, .config = config };
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
            const action = try conn.handleFrame(f);
            if (action == .entered_play) entered = true;
            switch (action) {
                .block_set, .arm_swing, .chat, .attack, .command => try events.append(allocator, action),
                else => {},
            }
        }
        if (entered) {
            entered = false;
            const age = server.world_age.load(.acquire);
            const tod = server.time_of_day.load(.acquire);
            // Worldgen spawn: ensure land spawn before Join/SpawnPosition go out.
            // Returning players skip the search: loadPlayer restores pos.
            if (server.world) |pool| {
                const loaded = server.loadPlayer(conn);
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
            try conn.queueJoinPackets(age, tod);
            // Login completion: inventory sync, chunks, PosLook last.
            // (announceJoin runs after unlock — it takes conn.lock itself).
            if (server.world) |pool| {
                // Persisted inventory (or empty for fresh players): full
                // Window Items + cursor so the client starts in sync.
                const wf = try packets.frameWindowItemsAlloc(allocator, 0, &conn.inv);
                defer allocator.free(wf);
                try conn.queueFramed(wf);
                const cf = try packets.frameSetSlotAlloc(allocator, 0, -1, conn.cursor);
                defer allocator.free(cf);
                try conn.queueFramed(cf);
                const cc = conn.playerChunk();
                try view.completeLogin(conn, server.chunkSource(pool), 0, cc.cx, cc.cz, server.view_distance, true);
            } else {
                try conn.queuePlayerPosLook();
            }
            need_announce = true;
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
        const pending = try conn.takeOutput();
        const done = conn.close_after_flush or conn.dead;
        const cc_now = conn.playerChunk();
        conn.lock.unlock();
        // World mutation (single world lock) then viewer broadcast
        // (one conn lock at a time — never nested).
        if (events.items.len > 0) {
            if (server.world) |pool| {
                server.world_lock.lock();
                for (events.items) |ev| {
                    switch (ev) {
                        .block_set => |b| view.applyBlock(pool, allocator, b.x, b.y, b.z, b.id, b.meta) catch {},
                        else => {},
                    }
                }
                server.world_lock.unlock();
            }
            for (events.items) |ev| {
                switch (ev) {
                    .block_set => |b| server.broadcastBlockChange(conn, b.x, b.y, b.z, b.id, b.meta) catch {},
                    .arm_swing => |a| server.broadcastArmSwing(conn, cc_now.cx, cc_now.cz, conn.eid, a) catch {},
                    .chat => |m| server.broadcastChat(conn.chat_buf[0..m.json_len]),
                    .attack => |a| server.resolveAttack(conn, a),
                    .command => |m| server.handleCommand(conn, conn.chat_buf[0..m.json_len]),
                    else => {},
                }
            }
            events.clearRetainingCapacity();
        }
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
    try srv.broadcastBlockChange(null, 3, 65, 4, 7, 0);
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
            c.* = Conn.init(a, io, .{}, eid);
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
        try std.testing.expectEqual(@as(u8, 0x46), try pr.readByte());
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
    c.config.spawn_x = 8;
    c.config.spawn_y = 70;
    c.config.spawn_z = 8;
    const tag = [_]u8{ 0x0A, 0x00, 0x03, 0x64, 0x75, 0x6D };
    const owned = try a.dupe(u8, &tag);
    c.inv[36] = .{ .id = 276, .count = 1, .damage = 0, .nbt = owned };
    c.inv[10] = .{ .id = 1, .count = 64, .damage = 0, .nbt = null };
    c.cursor = .{ .id = 3, .count = 5, .damage = 0, .nbt = null };
    srv.savePlayer(c);
    // Mutate everything; load must restore.
    c.pos_x = 999;
    c.health = 1.0;
    item_mod.freeStack(a, &c.inv[36]);
    c.inv[36] = null;
    c.inv[10] = null;
    c.cursor = null;
    c.selected = 0;
    c.lock.lock();
    try std.testing.expect(srv.loadPlayer(c));
    c.lock.unlock();
    try std.testing.expectApproxEqAbs(-12.5, c.pos_x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 90.0), c.yaw, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 13.5), c.health, 1e-6);
    try std.testing.expectEqual(@as(i16, 17), c.food);
    try std.testing.expectEqual(@as(u8, 4), c.selected);
    try std.testing.expectEqual(@as(u16, 276), c.inv[36].?.id);
    try std.testing.expectEqualSlices(u8, &tag, c.inv[36].?.nbt.?);
    try std.testing.expectEqual(@as(u16, 1), c.inv[10].?.id);
    try std.testing.expectEqual(@as(u16, 3), c.cursor.?.id);
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
    const still = try pool.get(player_db.keyFor("Al"));
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
    const readChat = struct {
        fn run(c: *Conn) ![]u8 {
            c.lock.lock();
            const raw = try c.takeOutput();
            c.lock.unlock();
            defer a.free(raw);
            var r = codec.PacketReader.init(raw);
            const h = try codec.decodeFrame(&r);
            try std.testing.expectEqual(@as(i32, 0x02), h.id);
            var pr = codec.PacketReader.init(r.buffer[r.index..]);
            return try a.dupe(u8, try pr.readString());
        }
    }.run;
    var alice = try mk.run("AliceD", 1);
    var bob = try mk.run("BobD", 2);
    // /list with nobody registered: empty roster, still well-formed.
    srv.handleCommand(alice, "/list");
    const l0 = try readChat(alice);
    defer a.free(l0);
    try std.testing.expectEqualStrings("{\"text\":\"Connected (0):\"}", l0);
    // Register both (commands never touch streams; leave them undefined).
    try srv.registry.append(a, .{ .conn = alice, .stream = undefined });
    try srv.registry.append(a, .{ .conn = bob, .stream = undefined });
    // /list to Alice: both names, sender-only (Bob's outbox stays empty).
    srv.handleCommand(alice, "/list");
    const l1 = try readChat(alice);
    defer a.free(l1);
    try std.testing.expectEqualStrings("{\"text\":\"Connected (2): AliceD, BobD\"}", l1);
    {
        bob.lock.lock();
        const pending = try bob.takeOutput();
        bob.lock.unlock();
        defer a.free(pending);
        try std.testing.expectEqual(@as(usize, 0), pending.len);
    }
    // /help (extra args ignored)
    srv.handleCommand(bob, "/help with extra args ignored");
    const h1 = try readChat(bob);
    defer a.free(h1);
    try std.testing.expectEqualStrings("{\"text\":\"Commands: /help /list /save-all\"}", h1);
    // unknown
    srv.handleCommand(alice, "/frobnicate");
    const unk = try readChat(alice);
    defer a.free(unk);
    try std.testing.expectEqualStrings("{\"text\":\"Unknown command. Try /help\"}", unk);
    // console sender (null) must not crash; no chat goes out.
    srv.handleCommand(null, "/list");
    srv.handleCommand(null, "/nope");
    srv.handleCommand(null, "/help");
    // /save-all without a world still replies (0 players, no flush).
    srv.handleCommand(alice, "/save-all");
    const s1 = try readChat(alice);
    defer a.free(s1);
    try std.testing.expectEqualStrings("{\"text\":\"Saved 2 player(s).\"}", s1);
    _ = srv.registry.pop();
    _ = srv.registry.pop();
    alice.deinit();
    a.destroy(alice);
    bob.deinit();
    a.destroy(bob);
}
