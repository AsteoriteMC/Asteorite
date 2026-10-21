//! Per-connection state machine: handshake -> status/login -> play.
//!
//! TCP delivers a byte stream; this handles reassembly (partial frames),
//! dispatch, and a tick-aligned output ring (see `takeOutput`: the server
//! flushes once per 50ms tick instead of per packet).
//! Encryption (AES/CFB8) plugs in after EncryptionResponse (online mode);
//! offline mode is fully implemented. Online RSA is NOT (no std RSA) — see
//! `online_mode` handling.

const std = @import("std");
const codec = @import("codec.zig");
const ids = @import("../proto/v5/ids.zig");
const packets = @import("../proto/v5/packets.zig");
const slot_mod = @import("../proto/v5/slot.zig");
const item_mod = @import("../item.zig");
const recipes_mod = @import("../sim/recipes.zig");
const uuid_mod = @import("uuid.zig");
const cfb8 = @import("cfb8.zig");
const rsa_mod = @import("rsa.zig");
const mojang = @import("mojang.zig");
const spin = @import("../sim/spin.zig");
const game_ids = @import("../ids.zig");

/// Server-driven tick intervals.
pub const keepalive_interval_ms: i64 = 15000;
pub const keepalive_timeout_ms: i64 = 30000;
pub const time_interval_ms: i64 = 1000;

pub const max_frame_len = 2 * 1024 * 1024; // 2MB guard

pub const Config = struct {
    motd: []const u8 = "zigcraft",
    max_players: u8 = 20,
    online_count: u8 = 0,
    gamemode: u8 = 1,
    difficulty: u8 = 1,
    level_type: []const u8 = "default",
    spawn_x: i32 = 8,
    spawn_y: i32 = 64,
    spawn_z: i32 = 8,
    online_mode: bool = false,
    /// Borrowed RSA keypair; required when online_mode is true.
    rsa: ?*const rsa_mod.RsaKeyPair = null,
    auth_url: []const u8 = "https://sessionserver.mojang.com/session/minecraft/hasJoined",
};

/// Block mutation request (break = id 0). Serve loop applies to the world
/// store, then broadcasts to viewers tracking the chunk.
pub const BlockEvent = struct {
    x: i32,
    y: u8,
    z: i32,
    id: game_ids.Id,
    meta: u4,
    /// Clicked face (0-5) for right-clicks; tells serve which cell was
    /// clicked (table-vs-place decision). Breaks leave the default.
    face: i8 = 1,
};

/// Q-key drop (digging status 3 = whole stack, 4 = one item). `stack` is
/// OWNED (cloned at dig time, or the moved slot contents); the serve loop
/// takes ownership into the item entity. `slot` is the window slot to refresh
/// with a 0x2F after the inventory mutation.
pub const QDropEvent = struct { stack: item_mod.Stack, slot: i16 };

/// Furnace click (window 2): resolved by the serve thread (furnace state is
/// server-owned under furn_lock). Click validation happened in handleFrame.
pub const FurnaceClick = struct { slot: i16, button: i8, action: i16, mode: i8 };

/// Crafting-table close: OWNED grid stacks (result slot is virtual and
/// vanishes) for the serve loop to drop as entities + 0x2E the window.
/// Crafting-table close (0x0D or block break): grid contents (result slot
/// is virtual and vanishes) drop as entities; serve loop sends 0x2E + spawns.
/// Furnace close reuses this with window=2 and empty stacks (contents stay
/// in the server furnace — only the UI closes).
pub const TableClose = struct { window: u8, stacks: [9]?item_mod.Stack };

/// Outbound chat line (validated JSON in conn.chat_buf).
pub const ChatEvent = struct {
    json_len: usize,
};

/// Validated melee attack (serverbound 0x02, action == attack).
/// Attacker snapshot is baked in at parse time (under conn.lock) so the
/// tick thread can resolve damage without taking more locks.
pub const AttackEvent = struct {
    target_eid: i32,
    /// Damage from the attacker's held item (vanilla 1.7 table, no enchants —
    /// NBT is skipped, documented in onPlace).
    dmg: f32,
    ax: f64,
    ay: f64,
    az: f64,
};

pub const Action = union(enum) {
    none,
    /// A status ping completed; caller should flush then close.
    close_after_flush,
    /// Switched to play; bootstrap packets queued.
    entered_play,
    disconnect_queued,
    /// Mutate one block then broadcast 0x23 to chunk viewers (not sender).
    block_set: BlockEvent,
    /// Validated melee attack: resolved by the tick thread against mobs +
    /// players (carries attacker snapshot so no locks are needed later).
    attack: AttackEvent,
    /// Q-key item drop: serve loop spawns the entity + refreshes the slot.
    qdrop: QDropEvent,
    /// Furnace click (window 2): serve loop mutates server state + syncs.
    furnace_click: FurnaceClick,
    /// Crafting-table close (0x0D or table break): grid contents drop as
    /// entities in front of the player; serve loop sends 0x2E + spawns.
    table_close: TableClose,
    /// Relay arm swing 0x0B to chunk viewers (not sender).
    arm_swing: i8,
    /// Broadcast formatted chat line to all play conns.
    chat: ChatEvent,
    /// Serverbound chat starting with "/" (raw text in chat_buf, cmd_len
    /// bytes). Handled by the serve thread (server.handleCommand), which may
    /// reply to the sender and/or broadcast. Spam-cooldown applies first.
    command: ChatEvent,
};

/// Minimum gap between chat packets (vanilla-style spam kick otherwise).
pub const chat_cooldown_ms: i64 = 750;

/// Last state a viewer was sent (for entity delta encoding).
pub const Tracked = struct {
    x: f64,
    y: f64,
    z: f64,
    yaw: f32,
    pitch: f32,
};

pub const Frame = struct {
    id: i32,
    /// Payload WITHOUT the packet id. Valid until next feedData/poll.
    body: []const u8,
};

pub const Conn = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    state: ids.State = .handshaking,
    eid: i32 = 0,
    username_len: usize = 0,
    username: [16]u8 = [_]u8{0} ** 16,
    uuid_str: [36]u8 = [_]u8{0} ** 36,
    last_keepalive: i32 = 0,
    /// Window 0 (player inventory): 45 slots. Only hotbar (36..44) is
    /// interpreted for placement; the rest is stored verbatim.
    /// Canonical stacks; NBT buffers are OWNED (duped on store, freed on
    /// replace/deinit) so enchanted/named items survive across frames.
    inv: [45]?item_mod.Stack = [_]?item_mod.Stack{null} ** 45,
    selected: u8 = 0,
    pending_dig: ?struct { x: i32, y: u8, z: i32 } = null,
    /// Survival cursor stack (mode-0 clicks) + per-window action counter for
    /// click validation (desync -> full Window Items refresh, never a kick).
    cursor: ?item_mod.Stack = null,
    click_seq: i16 = 0,
    click_seen: bool = false,
    /// Window 1 (crafting table): slot 0 = result, 1-9 = 3x3 grid.
    /// Owned stacks (NBT duped). open_win records the table block pos.
    table: [10]?item_mod.Stack = [_]?item_mod.Stack{null} ** 10,
    open_win: ?struct { id: u8, x: i32, y: u8, z: i32 } = null,
    sneaking: bool = false,
    /// Survival state. Damage resolution lives in the tick thread
    /// (server.zig); the serve thread only records validated attack events.
    /// While is_dead the client shows the death screen: block/entity
    /// actions are dropped until Client Status 0 (respawn) arrives.
    health: f32 = 20.0,
    food: i16 = 20,
    saturation: f32 = 5.0,
    is_dead: bool = false,
    /// Hunger/attrition state (vanilla FoodStats + env hazards). Ticks are
    /// 20tps units advanced 20 per 1Hz server tick (same convention as
    /// world_age); server.zig drives, conn owns. Not persisted (ZPLR keeps
    /// health/food/saturation; these reset on login — documented J2 gap).
    exhaustion: f32 = 0,
    food_timer: u32 = 0,
    air: i16 = 300,
    fire_ticks: u32 = 0,
    sprinting: bool = false,
    /// Accumulated downward distance while airborne (vanilla fallDistance).
    fall_acc: f32 = 0,
    /// Landing awaiting a water check (serve thread owns the pool peek).
    pending_fall: ?struct { dist: f32, x: f64, y: f64, z: f64 } = null,
    /// Connection established timestamp (ms, monotonic). Login must complete
    /// within login_timeout_ms or the ticker drops the connection.
    connected_at_ms: i64 = 0,
    /// Set when the join is announced to other players (leave broadcast iff set).
    announced: bool = false,
    /// Scratch for one validated outbound chat line (JSON).
    chat_buf: [1024]u8 = [_]u8{0} ** 1024,
    last_chat_ms: ?i64 = null,
    // tracked player state (serverbound position packets; stance consumed)
    pos_x: f64 = 8.5,
    pos_y: f64 = 64.0,
    pos_z: f64 = 8.5,
    yaw: f32 = 0,
    pitch: f32 = 0,
    on_ground: bool = false,
    /// Columns already sent groundUp (groundUp re-send leaks client memory,
    /// so each column goes out at most once until unloaded). Key: x<<32|z.
    sent: std.AutoHashMap(i64, void),
    /// Reusable bulk-encode scratch (sendColumns writes grouped columns here).
    /// Allocated once and retained: this allocator is a never-reset arena,
    /// so per-call 12MB allocs leak until process exit — that OOM-freezes
    /// the box under gen-storm retries. Freed in deinit.
    bulk_raw: []u8 = &[_]u8{},
    bulk_comp: []u8 = &[_]u8{},
    bulk_work: []u8 = &[_]u8{},
    sent_center: ?struct { cx: i32, cz: i32 } = null,
    /// Set once the login burst went out; movement before that is ignored.
    baseline_sent: bool = false,
    /// Set by movement/respawn handlers; serveConn drains via view.sync.
    chunks_dirty: bool = false,
    /// Respawn: unload everything first, then full re-burst.
    force_resync: bool = false,
    /// Last observed background-gen sequence (async gen follow-up below).
    last_gen_seq: u64 = 0,
    /// Last async-gen retry (ms). Retries re-scan the view disk; without a
    /// floor, a gen storm re-runs 1k+ store reads every serve iteration.
    last_gen_retry_ms: i64 = 0,
    /// From Client Settings 0x15 (unclamped); effective radius = min(this, server max).
    client_view: ?u8 = null,
    /// Per-viewer entity visibility (ticker writes under conn.lock).
    tracked: std.AutoHashMap(i32, Tracked),
    // ---- server-tick state (touched by serve + ticker threads: hold lock) ----
    /// Guards out/read/sent/state and all tick fields below.
    lock: spin.SpinLock = .{},
    /// Serializes socket writes (serve flush vs ticker flush).
    wlock: spin.SpinLock = .{},
    /// Registry refcount (server holds no ref; forEach takes temp refs).
    refs: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Set by the ticker on timeout; serveConn exits after flushing.
    dead: bool = false,
    keepalive_id: i32 = 0,
    next_keepalive_ms: i64 = 0,
    keepalive_outstanding: bool = false,
    keepalive_sent_ms: i64 = 0,
    last_echo_ms: i64 = -1,
    first_tick_ms: i64 = -1,
    ping_ms: std.atomic.Value(i16) = std.atomic.Value(i16).init(1),
    next_time_ms: i64 = 0,
    close_after_flush: bool = false,
    // online-mode session state
    verify_token: [4]u8 = [_]u8{0} ** 4,
    awaiting_enc_response: bool = false,
    enc: ?cfb8.Cfb8 = null, // encrypts queued output once enabled
    dec: ?cfb8.Cfb8 = null, // decrypts fed input once enabled
    read: std.ArrayList(u8) = .empty,
    out: std.ArrayList(u8) = .empty,
    /// Scratch for the current frame body. `poll` copies the body here
    /// BEFORE compacting `read` (compaction memsets vacated bytes to
    /// `undefined`, so returning a slice into `read` would alias poisoned
    /// memory). Valid until the next poll/feedData.
    frame: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config, eid: i32) Conn {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .eid = eid,
            .pos_x = @as(f64, @floatFromInt(config.spawn_x)) + 0.5,
            .pos_y = @as(f64, @floatFromInt(config.spawn_y)),
            .pos_z = @as(f64, @floatFromInt(config.spawn_z)) + 0.5,
            .sent = std.AutoHashMap(i64, void).init(allocator),
            .tracked = std.AutoHashMap(i32, Tracked).init(allocator),
            .connected_at_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds(),
        };
    }

    pub fn deinit(self: *Conn) void {
        self.read.deinit(self.allocator);
        self.out.deinit(self.allocator);
        self.frame.deinit(self.allocator);
        self.sent.deinit();
        self.tracked.deinit();
        if (self.bulk_raw.len > 0) self.allocator.free(self.bulk_raw);
        if (self.bulk_comp.len > 0) self.allocator.free(self.bulk_comp);
        if (self.bulk_work.len > 0) self.allocator.free(self.bulk_work);
        for (&self.inv) |*s| item_mod.freeStack(self.allocator, s);
        for (&self.table) |*s| item_mod.freeStack(self.allocator, s);
        item_mod.freeStack(self.allocator, &self.cursor);
    }

    /// Pack chunk coords for the sent-set.
    pub fn sentKey(x: i32, z: i32) i64 {
        return (@as(i64, x) << 32) | @as(u32, @bitCast(z));
    }

    pub fn feedData(self: *Conn, data: []const u8) !void {
        if (self.dec) |*d| {
            // AES-CFB8 is a stream cipher: decrypt arrival-ordered bytes.
            // (Heap copy per feed; P-next uses per-conn arena slices.)
            const tmp = try self.allocator.dupe(u8, data);
            defer self.allocator.free(tmp);
            d.decrypt(tmp);
            try self.read.appendSlice(self.allocator, tmp);
        } else {
            try self.read.appendSlice(self.allocator, data);
        }
        if (self.read.items.len > max_frame_len + 8) return error.FrameTooLarge;
    }

    /// Parse one frame if complete. Returns null when more bytes are needed.
    /// Caller must handleFrame before the next poll (body aliases read buf).
    pub fn poll(self: *Conn) !?Frame {
        var r = codec.PacketReader.init(self.read.items);
        const start = r.index;
        const length = r.readVarInt() catch |err| switch (err) {
            error.BufferUnderflow => return null,
            else => return err,
        };
        if (length < 0 or length > max_frame_len) return error.FrameTooLarge;
        const ulen: usize = @intCast(length);
        // need: varint-len(length) + length bytes total
        const header_len = r.index - start;
        if (self.read.items.len < header_len + ulen) return null; // partial
        const id = try r.readVarInt();
        const body_src = self.read.items[r.index .. header_len + ulen];
        // copy body aside, then compact (replaceRange memsets vacated tail
        // to undefined — must not alias read buf across compaction)
        self.frame.clearRetainingCapacity();
        try self.frame.appendSlice(self.allocator, body_src);
        const consumed = header_len + ulen;
        try self.read.replaceRange(self.allocator, 0, consumed, &.{});
        return .{ .id = id, .body = self.frame.items };
    }

    fn queueRaw(self: *Conn, framed: []const u8) !void {
        if (self.enc) |*e| {
            const tmp = try self.allocator.dupe(u8, framed);
            defer self.allocator.free(tmp);
            e.encrypt(tmp);
            try self.out.appendSlice(self.allocator, tmp);
        } else {
            try self.out.appendSlice(self.allocator, framed);
        }
    }

    pub fn handleFrame(self: *Conn, frame: Frame) !Action {
        return switch (self.state) {
            .handshaking => try self.handleHandshaking(frame),
            .status => try self.handleStatus(frame),
            .login => try self.handleLogin(frame),
            .play => try self.handlePlay(frame),
        };
    }

    fn disconnect(self: *Conn, json: []const u8) !Action {
        var buf: [512]u8 = undefined;
        const id: i32 = switch (self.state) {
            .login => @intFromEnum(ids.LoginClient.disconnect),
            else => @intFromEnum(ids.PlayClient.disconnect),
        };
        var payload: [500]u8 = undefined;
        var w = codec.PacketWriter.init(&payload);
        try w.writeString(json);
        const f = try codec.framePacket(id, w.written(), &buf);
        try self.queueRaw(f);
        self.close_after_flush = true;
        return .disconnect_queued;
    }

    fn handleHandshaking(self: *Conn, frame: Frame) !Action {
        if (frame.id != @as(i32, @intFromEnum(ids.HandshakingServer.handshake))) {
            return try self.disconnect("{\"text\":\"Expected handshake\"}");
        }
        const h = try packets.parseHandshake(frame.body);
        if (h.protocol != ids.protocol_version_1_7_10) {
            var msg: [128]u8 = undefined;
            const m = try std.fmt.bufPrint(&msg, "{{\"text\":\"Outdated client (want proto 5, got {d})\"}}", .{h.protocol});
            return try self.disconnect(m);
        }
        self.state = switch (h.next) {
            1 => .status,
            2 => .login,
            else => return try self.disconnect("{\"text\":\"Bad handshake next state\"}"),
        };
        return .none;
    }

    fn handleStatus(self: *Conn, frame: Frame) !Action {
        if (frame.id == @as(i32, @intFromEnum(ids.StatusServer.request))) {
            var json: [512]u8 = undefined;
            const j = try std.fmt.bufPrint(&json,
                "{{\"version\":{{\"name\":\"1.7.10\",\"protocol\":5}}," ++
                    "\"players\":{{\"max\":{d},\"online\":{d}}}," ++
                    "\"description\":{{\"text\":\"{s}\"}}}}",
                .{ self.config.max_players, self.config.online_count, self.config.motd });
            var out: [1024]u8 = undefined;
            try self.queueRaw(try packets.frameStatusResponse(j, &out));
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.StatusServer.ping))) {
            const payload = try packets.parsePing(frame.body);
            var out: [16]u8 = undefined;
            try self.queueRaw(try packets.framePong(payload, &out));
            self.close_after_flush = true;
            return .close_after_flush;
        }
        return try self.disconnect("{\"text\":\"Bad status packet\"}");
    }

    fn validNameChars(name: []const u8) bool {
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
        }
        return true;
    }

    /// Login + command-target name policy (shared so /op can't smuggle
    /// anything the login gate would reject).
    pub fn validPlayerName(name: []const u8) bool {
        return name.len > 0 and name.len <= 16 and validNameChars(name);
    }

    fn sendLoginSuccess(self: *Conn, uuid_str: []const u8, name: []const u8) !void {
        var out: [128]u8 = undefined;
        try self.queueRaw(try packets.frameLoginSuccess(uuid_str, name, &out));
    }

    fn enterPlay(self: *Conn) !Action {
        self.state = .play;
        try self.queuePlayBootstrap();
        return .entered_play;
    }

    fn handleLogin(self: *Conn, frame: Frame) !Action {
        if (frame.id == @as(i32, @intFromEnum(ids.LoginServer.login_start))) {
            const name = try packets.parseLoginStart(frame.body);
            if (!validPlayerName(name)) {
                return try self.disconnect("{\"text\":\"Bad username\"}");
            }
            @memcpy(self.username[0..name.len], name);
            self.username_len = name.len;
            if (self.config.online_mode) {
                const keys = self.config.rsa orelse {
                    return try self.disconnect("{\"text\":\"Online mode misconfigured\"}");
                };
                if (name.len < 3) {
                    return try self.disconnect("{\"text\":\"Bad username\"}");
                }
                self.io.randomSecure(&self.verify_token) catch self.io.random(&self.verify_token);
                self.awaiting_enc_response = true;
                var out: [2048]u8 = undefined;
                try self.queueRaw(try packets.frameEncryptionRequest(
                    "",
                    keys.public_key_der,
                    &self.verify_token,
                    &out,
                ));
                return .none;
            }
            const uuid = uuid_mod.offlineUuid(name);
            uuid_mod.formatUuid(uuid, &self.uuid_str);
            try self.sendLoginSuccess(&self.uuid_str, name);
            return try self.enterPlay();
        }
        if (frame.id == @as(i32, @intFromEnum(ids.LoginServer.encryption_response))) {
            if (!self.awaiting_enc_response) {
                return try self.disconnect("{\"text\":\"Unexpected encryption response\"}");
            }
            self.awaiting_enc_response = false;
            const keys = self.config.rsa orelse {
                return try self.disconnect("{\"text\":\"Online mode misconfigured\"}");
            };
            const enc = try packets.parseEncryptionResponse(frame.body);
            const token = keys.decrypt(self.allocator, enc.token_enc) catch {
                return try self.disconnect("{\"text\":\"Bad login token\"}");
            };
            defer self.allocator.free(token);
            if (token.len != 4 or !std.mem.eql(u8, token, &self.verify_token)) {
                return try self.disconnect("{\"text\":\"Bad login token\"}");
            }
            const secret = keys.decrypt(self.allocator, enc.secret_enc) catch {
                return try self.disconnect("{\"text\":\"Bad shared secret\"}");
            };
            defer self.allocator.free(secret);
            if (secret.len != 16) {
                return try self.disconnect("{\"text\":\"Bad shared secret\"}");
            }
            var shared: [16]u8 = undefined;
            @memcpy(&shared, secret[0..16]);
            const hash = mojang.computeMinecraftHash("", &shared, keys.public_key_der);
            const name = self.username[0..self.username_len];
            const session_uuid = mojang.verifySession(self.io, self.allocator, self.config.auth_url, name, hash.slice()) catch {
                return try self.disconnect("{\"text\":\"Failed to verify username!\"}");
            };
            const hex = std.fmt.bytesToHex(&session_uuid, .lower);
            // hyphenated 8-4-4-4-12
            var p: usize = 0;
            var o: usize = 0;
            const dash_at = [_]usize{ 8, 12, 16, 20 };
            var di: usize = 0;
            while (p < 32) : (p += 1) {
                if (di < 4 and p == dash_at[di]) {
                    self.uuid_str[o] = '-';
                    o += 1;
                    di += 1;
                }
                self.uuid_str[o] = hex[p];
                o += 1;
            }
            // enable link encryption BEFORE LoginSuccess (it goes out encrypted)
            self.enc = cfb8.Cfb8.init(&shared);
            self.dec = cfb8.Cfb8.init(&shared);
            try self.sendLoginSuccess(&self.uuid_str, name);
            return try self.enterPlay();
        }
        return try self.disconnect("{\"text\":\"Unexpected login packet\"}");
    }

    fn queuePlayBootstrap(self: *Conn) !void {
        var jb: [512]u8 = undefined;
        try self.queueRaw(try packets.frameJoinGame(.{
            .eid = self.eid,
            .gamemode = self.config.gamemode,
            .dimension = 0,
            .difficulty = self.config.difficulty,
            .max_players = self.config.max_players,
            .level_type = self.config.level_type,
        }, &jb));
        var sb: [32]u8 = undefined;
        try self.queueRaw(try packets.frameSpawnPosition(self.config.spawn_x, self.config.spawn_y, self.config.spawn_z, &sb));
        // Chunks (view.completeLogin) go here; PlayerPosLook closes login.
    }

    /// Final login step; view.completeLogin calls this after chunk bulks.
    /// Sends the player's actual position (persisted across restarts, or
    /// spawn on first login — serveConn syncs pos to spawn before calling).
    pub fn queuePlayerPosLook(self: *Conn) !void {
        var pb: [64]u8 = undefined;
        try self.queueRaw(try packets.framePlayerPosLook(.{
            .x = self.pos_x,
            .y = self.pos_y,
            .z = self.pos_z,
            .yaw = self.yaw,
            .pitch = self.pitch,
            .on_ground = false,
        }, &pb));
    }

    /// Raw framed packet into the tick output ring (used by view + tests).
    pub fn queueFramed(self: *Conn, framed: []const u8) !void {
        try self.queueRaw(framed);
    }

    fn handlePlay(self: *Conn, frame: Frame) !Action {
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.keep_alive))) {
            const id = try packets.parseKeepAlive(frame.body);
            const now = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
            self.last_keepalive = id;
            self.last_echo_ms = now;
            if (self.keepalive_outstanding and id == self.keepalive_id) {
                const rtt = now - self.keepalive_sent_ms;
                self.ping_ms.store(@intCast(@min(rtt, std.math.maxInt(i16))), .release);
                self.keepalive_outstanding = false;
            } else if (self.keepalive_outstanding) {
                // any echo proves liveness even with a stale id
                self.keepalive_outstanding = false;
            }
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.player))) {
            const g = try packets.parseFlying(frame.body);
            self.groundTransition(0, g);
            self.on_ground = g;
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.player_position))) {
            const p = try packets.parsePosition(frame.body);
            self.setPos(p.x, p.y, p.z, self.yaw, self.pitch, p.on_ground);
            self.markChunkDirty();
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.player_look))) {
            const l = try packets.parseLook(frame.body);
            self.setPos(self.pos_x, self.pos_y, self.pos_z, l.yaw, l.pitch, l.on_ground);
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.player_position_and_look))) {
            const p = try packets.parsePositionLook(frame.body);
            self.setPos(p.x, p.y, p.z, p.yaw, p.pitch, p.on_ground);
            self.markChunkDirty();
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.client_settings))) {
            const s = try packets.parseClientSettings(frame.body);
            // clamp: vanilla sends 2..16, server max enforced at use site
            const vd: i8 = @max(1, @min(16, s.view_distance));
            self.client_view = @intCast(vd);
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.client_status))) {
            const st = try packets.parseClientStatus(frame.body);
            if (st == 0) {
                // respawn: back to spawn, full chunk resync; the dead walk
                // back with full health (food/saturation kept as-is).
                self.setPos(
                    @as(f64, @floatFromInt(self.config.spawn_x)) + 0.5,
                    @as(f64, @floatFromInt(self.config.spawn_y)),
                    @as(f64, @floatFromInt(self.config.spawn_z)) + 0.5,
                    self.yaw,
                    self.pitch,
                    false,
                );
                self.force_resync = true;
                self.chunks_dirty = true;
                if (self.is_dead) {
                    self.is_dead = false;
                    self.health = 20.0;
                    // Fresh-body reset (vanilla respawn restores food too;
                    // inventory was dropped on death and re-syncs below).
                    self.food = 20;
                    self.saturation = 5.0;
                    self.exhaustion = 0;
                    self.food_timer = 0;
                    self.air = 300;
                    self.fire_ticks = 0;
                    self.sprinting = false;
                    self.fall_acc = 0;
                    self.pending_fall = null;
                    var hb: [32]u8 = undefined;
                    try self.queueRaw(try packets.frameUpdateHealth(self.health, self.food, self.saturation, &hb));
                    // Dropped inventory: full re-sync (login does the same).
                    self.sendWindow();
                    self.sendSlot(-1);
                }
            }
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.player_digging))) {
            const d = try packets.parseDigging(frame.body);
            return self.onDig(d.status, d.x, d.y, d.z);
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.player_block_placement))) {
            const p = try packets.parsePlacement(frame.body);
            return self.onPlace(p.x, p.y, p.z, p.direction);
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.held_item_change))) {
            const slot = try packets.parseHeldSlot(frame.body);
            if (slot >= 0 and slot <= 8) self.selected = @intCast(slot);
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.animation))) {
            const a = try packets.parseArmAnimation(frame.body);
            if (a.entity_id == self.eid) return .{ .arm_swing = a.animation };
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.entity_action))) {
            const a = try packets.parseEntityAction(frame.body);
            if (a.entity_id == self.eid) {
                if (a.action == 4) self.sprinting = true else if (a.action == 5) self.sprinting = false;
                if (a.action == 1) self.sneaking = true else if (a.action == 2) self.sneaking = false;
            }
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.creative_inventory_action))) {
            const c = try packets.parseCreativeSlot(frame.body);
            // Vanilla rejects the output slot (slot 0); grid edits recompute.
            if (c.slot >= 1 and c.slot < 45) {
                const idx: usize = @intCast(c.slot);
                item_mod.freeStack(self.allocator, &self.inv[idx]);
                self.inv[idx] = try item_mod.cloneStack(self.allocator, c.item);
                if (idx >= 1 and idx <= 4) {
                    self.refreshCrafting();
                    self.sendSlot(0);
                }
            }
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.chat_message))) {
            const text = try packets.parseChat(frame.body);
            const now = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
            if (self.last_chat_ms) |last| {
                if (now - last < chat_cooldown_ms) {
                    return try self.disconnect("{\"text\":\"Kicked for spamming\"}");
                }
            }
            // Commands ride the chat packet (vanilla behavior): "/" prefix
            // routes to server.handleCommand instead of broadcast. Raw bytes
            // go in chat_buf (not JSON); length cap is parseChat's own.
            if (text.len > 0 and text[0] == '/') {
                if (text.len > self.chat_buf.len) return .none;
                @memcpy(self.chat_buf[0..text.len], text);
                self.last_chat_ms = now;
                return .{ .command = .{ .json_len = text.len } };
            }
            const json = packets.formatChatJson(self.username[0..self.username_len], text, &self.chat_buf) catch {
                return .none; // invalid/overlong: drop, don't broadcast, don't kick
            };
            self.last_chat_ms = now;
            return .{ .chat = .{ .json_len = json.len } };
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.use_entity))) {
            const u = try packets.parseUseEntity(frame.body);
            return self.onUseEntity(u.target, u.mouse);
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.click_window))) {
            const u = try packets.parseClickWindow(frame.body);
            if (try self.onClickWindow(u.window, u.slot, u.button, u.action, u.mode)) |fc| {
                return .{ .furnace_click = fc };
            }
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.close_window))) {
            const w = try packets.parseCloseWindow(frame.body);
            if (self.open_win) |ow| {
                if (w == ow.id and ow.id == 1) return .{ .table_close = .{ .window = 1, .stacks = self.takeTableGrid() } };
                if (w == ow.id and ow.id == 2) {
                    self.open_win = null;
                    return .{ .table_close = .{ .window = 2, .stacks = [_]?item_mod.Stack{null} ** 9 } };
                }
            }
            return .none;
        }
        // P-next: actions.
        return .none;
    }

    /// Serverbound 0x02: mouse 0 = interact, 1 = attack, 2 = interact-at.
    /// Interact has no target system yet (no riding/leashing) — dropped.
    /// Attack validates the target isn't self and packs an event; the tick
    /// thread resolves it against mobs + players (tick-owned entity state).
    fn onUseEntity(self: *Conn, target: i32, mouse: i8) Action {
        if (self.is_dead) return .none;
        if (mouse != 1) return .none; // interact / interact-at: P-next
        if (target == self.eid) return .none;
        const held = self.inv[36 + self.selected] orelse null;
        const dmg = if (held) |h| item_mod.meleeDamage(h.id) else 1.0;
        return .{ .attack = .{ .target_eid = target, .dmg = dmg, .ax = self.pos_x, .ay = self.pos_y, .az = self.pos_z } };
    }

    /// Reach check from eyes (feet + 1.62) to block center; 6.0 generous.
    fn inReach(self: *const Conn, x: i32, y: u8, z: i32) bool {
        const dx = @as(f64, @floatFromInt(x)) + 0.5 - self.pos_x;
        const dy = @as(f64, @floatFromInt(y)) + 0.5 - (self.pos_y + 1.62);
        const dz = @as(f64, @floatFromInt(z)) + 0.5 - self.pos_z;
        return dx * dx + dy * dy + dz * dz < 36.0;
    }

    /// Send one Set Slot (0x2F) update. Heap frame (NBT can be large);
    /// failures drop the update (client keeps its prediction; the next
    /// action-number mismatch triggers a full resync).
    fn sendSlot(self: *Conn, slot: i16) void {
        // Vanilla cursor convention: window -1 + slot -1 (window 0/slot -1
        // hits Container.getSlot(-1) -> AIOOBE and crashes the client).
        const window: i8 = if (slot < 0) -1 else 0;
        const f = packets.frameSetSlotAlloc(self.allocator, window, slot, if (slot < 0) self.cursor else self.inv[@as(usize, @intCast(slot))]) catch return;
        defer self.allocator.free(f);
        self.queueRaw(f) catch {};
    }

    /// Full window refresh after desync (action-number mismatch).
    fn sendWindow(self: *Conn) void {
        const f = packets.frameWindowItemsAlloc(self.allocator, 0, &self.inv) catch return;
        defer self.allocator.free(f);
        self.queueRaw(f) catch {};
    }

    /// Serverbound 0x0E click window. Window 0 = player inventory (2x2 grid
    /// live in slots 0-4); window 1 = open crafting table. Modes 3/4/5/6
    /// (creative pick, drop, drag, collect) are no-ops: drop/drag/collect
    /// need item entities (0x15 Spawn Object, follow-up), so nothing happens
    /// rather than deleting or duplicating the player's items.
    fn onClickWindow(self: *Conn, window: i8, slot: i16, button: i8, action: i16, mode: i8) !?FurnaceClick {
        if (self.is_dead) return null;
        if (window == 1) {
            if (self.open_win == null) {
                self.sendWindow();
                return null;
            }
            // Click validation shared across windows (desync -> refresh).
            if (!self.click_seen) {
                self.click_seen = true;
            } else if (action != self.click_seq) {
                self.queueTableWindow();
                return null;
            }
            self.click_seq = action +% 1;
            if (slot == -999) return null;
            try self.onClickTable(slot, button, action, mode);
            return null;
        }
        if (window == 2) {
            if (self.open_win == null or self.open_win.?.id != 2) {
                self.sendWindow();
                return null;
            }
            if (!self.click_seen) {
                self.click_seen = true;
            } else if (action != self.click_seq) {
                self.sendWindow();
                return null;
            }
            self.click_seq = action +% 1;
            if (slot == -999 or slot < 0 or slot > 38) return null;
            return FurnaceClick{ .slot = slot, .button = button, .action = action, .mode = mode };
        }
        if (window != 0) return null;
        if (slot < -999 or slot > 44) return null;
        // First click seeds the expectation; later clicks must increment.
        // Mismatch = desynced/replayed client: refresh, ignore the click.
        if (!self.click_seen) {
            self.click_seen = true;
        } else if (action != self.click_seq) {
            self.sendWindow();
            return null;
        }
        self.click_seq = action +% 1;
        if (slot == -999) return null; // outside click: drop path needs entities
        const s: usize = @intCast(slot);
        if (s == 0) {
            // Crafting result slot (2x2).
            if (mode == 0) {
                _ = try self.takeResult(0, self.inv[1..5], &self.inv[0], false);
                return null;
            }
            if (mode == 1) {
                try self.craftAll(self.inv[1..5], &self.inv[0], false);
                return null;
            }
            return null; // number-key on the result: no-op
        }
        switch (mode) {
            0 => {
                if (button != 0 and button != 1) return null;
                if (!(try self.clickPickupImplCell(&self.inv[s], button))) return null;
                self.sendSlot(@intCast(s));
                self.sendCursor();
                if (s >= 1 and s <= 4) {
                    self.refreshCrafting();
                    self.sendSlot(0);
                }
            },
            1 => {
                self.clickQuickMove(s, button);
                self.refreshCrafting();
                self.sendSlot(0);
            },
            2 => self.clickNumberKey(s, button),
            else => {},
        }
        return null;
    }

    /// Mode 0: left (all) / right (one) pickup, place, merge, swap.
    /// cursor == null means empty-handed. Merge prefers stacking; when the
    /// stacks can't merge the two sides swap (both buttons).
    fn clickPickup(self: *Conn, s: usize, button: i8) !void {
        if (button != 0 and button != 1) return;
        if (!(try self.clickPickupImplCell(&self.inv[s], button))) return;
        self.sendSlot(@intCast(s));
        self.sendCursor();
    }

    /// Returns true when anything moved (caller syncs slot + cursor then).
    /// Operates on any resolved cell (window-0 inv or table slot).
    pub fn clickPickupImplCell(self: *Conn, cell: *?item_mod.Stack, button: i8) !bool {
        if (cell.* == null and self.cursor == null) return false;
        if (cell.* == null) {
            // Place from cursor.
            if (button == 0) {
                cell.* = self.cursor.?;
                self.cursor = null;
            } else {
                const c = self.cursor.?;
                cell.* = .{ .id = c.id, .count = 1, .damage = c.damage, .nbt = if (c.nbt) |n| try self.allocator.dupe(u8, n) else null };
                self.cursor.?.count -= 1;
                if (self.cursor.?.count <= 0) item_mod.freeStack(self.allocator, &self.cursor);
            }
            return true;
        }
        if (self.cursor == null) {
            // Pick up from slot.
            if (button == 0) {
                self.cursor = cell.*;
                cell.* = null;
            } else {
                const st = cell.*.?;
                const take: i8 = @divTrunc(st.count + 1, 2); // ceil half
                self.cursor = .{ .id = st.id, .count = take, .damage = st.damage, .nbt = if (st.nbt) |n| try self.allocator.dupe(u8, n) else null };
                cell.*.?.count -= take;
                if (cell.*.?.count <= 0) item_mod.freeStack(self.allocator, cell);
            }
            return true;
        }
        // Both sides occupied.
        const dst = cell.*.?;
        const src = self.cursor.?;
        const limit = item_mod.maxStackSize(dst.id);
        if (item_mod.canMerge(dst, src) and dst.count < limit) {
            const space: i16 = @as(i16, limit) - dst.count;
            var n: i16 = if (button == 0) @min(space, src.count) else 1;
            if (space <= 0 or n <= 0) return false;
            if (n > src.count) n = src.count;
            cell.*.?.count += @as(i8, @intCast(n));
            self.cursor.?.count -= @as(i8, @intCast(n));
            if (self.cursor.?.count <= 0) item_mod.freeStack(self.allocator, &self.cursor);
            return true;
        }
        if (!item_mod.canMerge(dst, src)) {
            const t = cell.*;
            cell.* = self.cursor.?;
            self.cursor = t;
            return true;
        }
        return false;
    }

    /// Mode 1: shift-click moves the slot stack into the opposite region
    /// (main 9..35 <-> hotbar 36..44), merging first then filling the first
    /// empty. Crafting/armor slots (0..8) are sources only. Cursor untouched.
    /// Ends with a full refresh (many slots can change at once).
    fn clickQuickMove(self: *Conn, s: usize, button: i8) void {
        if (button != 0 and button != 1) return;
        if (self.inv[s] == null) return;
        const in_hotbar = s >= 36;
        const dst_lo: usize = if (in_hotbar) 9 else 36;
        const dst_hi: usize = if (in_hotbar) 35 else 44;
        var moved = false;
        // 1. merge into compatible non-full dest stacks.
        var i: usize = dst_lo;
        while (i <= dst_hi) : (i += 1) {
            if (i == s) continue;
            const src = self.inv[s] orelse break;
            const dst = self.inv[i] orelse continue;
            if (!item_mod.canMerge(dst, src)) continue;
            const room: i16 = @as(i16, item_mod.maxStackSize(dst.id)) - dst.count;
            if (room <= 0) continue;
            const n: i16 = @min(room, @as(i16, src.count));
            if (n <= 0) continue;
            self.inv[i].?.count += @as(i8, @intCast(n));
            self.inv[s].?.count -= @as(i8, @intCast(n));
            moved = true;
            if (self.inv[s].?.count <= 0) {
                item_mod.freeStack(self.allocator, &self.inv[s]);
                break;
            }
        }
        // 2. remainder goes whole into the first empty dest slot.
        if (self.inv[s] != null) {
            i = dst_lo;
            while (i <= dst_hi) : (i += 1) {
                if (i == s) continue;
                if (self.inv[i] != null) continue;
                self.inv[i] = self.inv[s];
                self.inv[s] = null;
                moved = true;
                break;
            }
        }
        if (moved) self.sendWindow();
    }

    /// Mode 2: number-key swap with hotbar slot `button` (0..8).
    /// Ignored while dragging (cursor non-empty), like vanilla.
    fn clickNumberKey(self: *Conn, s: usize, button: i8) void {
        if (button < 0 or button > 8) return;
        if (self.cursor != null) return;
        const h: usize = 36 + @as(usize, @intCast(button));
        if (s == h) return;
        const t = self.inv[s];
        self.inv[s] = self.inv[h];
        self.inv[h] = t;
        self.sendSlot(@intCast(s));
        self.sendSlot(@intCast(h));
    }

    // ---------- crafting (2x2 player grid + window-1 table) ----------

    /// Recompute the window-0 2x2 result into inv[0] (owned clone; null when
    /// no match). Vanilla refreshes the output on every grid change.
    pub fn refreshCrafting(self: *Conn) void {
        const r = recipes_mod.findMatch(self.inv[1..5], 2, 2);
        item_mod.freeStack(self.allocator, &self.inv[0]);
        if (r) |o| self.inv[0] = item_mod.cloneStack(self.allocator, o) catch null;
    }

    /// Recompute the window-1 3x3 result into table[0].
    fn refreshTable(self: *Conn) void {
        const r = recipes_mod.findMatch(self.table[1..10], 3, 3);
        item_mod.freeStack(self.allocator, &self.table[0]);
        if (r) |o| self.table[0] = item_mod.cloneStack(self.allocator, o) catch null;
    }

    /// Resolve a window slot to its storage cell. Window 0: inv directly.
    /// Window 1: 0-9 = table, 10-45 = alias inv[9..44].
    fn cellAt(self: *Conn, window: i8, slot: i16) ?*?item_mod.Stack {
        if (window == 0) {
            if (slot < 0 or slot > 44) return null;
            return &self.inv[@intCast(slot)];
        }
        if (window == 1) {
            if (slot < 0 or slot > 45) return null;
            const s: usize = @intCast(slot);
            if (s <= 9) return &self.table[s];
            return &self.inv[s - 1];
        }
        return null;
    }

    /// Window-aware Set Slot (0x2F carries the window id).
    fn sendSlotWin(self: *Conn, window: i8, slot: i16) void {
        const st: ?item_mod.Stack = if (window == 1)
            (if (slot >= 0 and slot <= 9) self.table[@as(usize, @intCast(slot))] else if (slot >= 10 and slot <= 45) self.inv[@as(usize, @intCast(slot)) - 1] else null)
        else if (slot >= 0 and slot <= 44)
            self.inv[@intCast(slot)]
        else if (slot == -1)
            self.cursor
        else
            null;
        const f = packets.frameSetSlotAlloc(self.allocator, window, slot, st) catch return;
        defer self.allocator.free(f);
        self.queueRaw(f) catch {};
    }

    /// Take the computed result (left-click on slot 0, empty cursor):
    /// result moves to cursor, one unit consumed per grid cell.
    /// `grid` borrows inv[1..5] or table[1..10]; `is_table` picks refresh.
    fn takeResult(self: *Conn, window: i8, grid: []?item_mod.Stack, result: *?item_mod.Stack, is_table: bool) !bool {
        const res = result.* orelse return false;
        if (self.cursor != null) return false;
        self.cursor = res;
        result.* = null;
        for (grid, 0..) |*cell, i| {
            if (cell.*) |_| {
                cell.*.?.count -= 1;
                if (cell.*.?.count <= 0) item_mod.freeStack(self.allocator, cell);
                self.sendSlotWin(window, @intCast(1 + i));
            }
        }
        if (is_table) self.refreshTable() else self.refreshCrafting();
        self.sendSlotWin(window, 0);
        self.sendSlotWin(-1, -1); // cursor lives on window -1 (vanilla rule)
        return true;
    }

    /// Shift-click on a result slot: craft repeatedly into the player
    /// inventory (window-0 slots 9..44) until no match or no fit.
    fn craftAll(self: *Conn, grid: []?item_mod.Stack, result: *?item_mod.Stack, is_table: bool) !void {
        var made = false;
        while (true) {
            if (is_table) self.refreshTable() else self.refreshCrafting();
            const res = result.* orelse break;
            // grant into player range (merge first, then empty)
            var placed = false;
            var i: usize = 9;
            while (i <= 44) : (i += 1) {
                const dst = self.inv[i] orelse continue;
                if (!item_mod.canMerge(dst, res)) continue;
                if (@as(u16, @intCast(dst.count)) + @as(u16, @intCast(res.count)) > item_mod.maxStackSize(dst.id)) continue;
                self.inv[i].?.count += res.count;
                placed = true;
                break;
            }
            if (!placed) {
                i = 9;
                while (i <= 44) : (i += 1) {
                    if (self.inv[i] != null) continue;
                    self.inv[i] = try item_mod.cloneStack(self.allocator, res);
                    placed = true;
                    break;
                }
            }
            if (!placed) break;
            for (grid) |*cell| {
                if (cell.*) |_| {
                    cell.*.?.count -= 1;
                    if (cell.*.?.count <= 0) item_mod.freeStack(self.allocator, cell);
                }
            }
            made = true;
        }
        if (made) {
            if (is_table) self.refreshTable() else self.refreshCrafting();
            // many slots may have changed: full refresh of the window.
            if (is_table) {
                self.queueTableWindow();
            } else {
                self.sendWindow();
            }
        }
    }

    /// Assemble + queue a full Window Items 0x30 for the open table window
    /// (slots 0-9 table, 10-45 alias inv 9-44).
    fn queueTableWindow(self: *Conn) void {
        var all: [46]?item_mod.Stack = [_]?item_mod.Stack{null} ** 46;
        for (0..10) |i| all[i] = self.table[i];
        for (9..45) |i| all[i + 1] = self.inv[i];
        const f = packets.frameWindowItemsAlloc(self.allocator, 1, &all) catch return;
        defer self.allocator.free(f);
        self.queueRaw(f) catch {};
    }

    /// Open the crafting-table UI (window id 1, type 1, 9 grid slots).
    pub fn openTableUI(self: *Conn, x: i32, y: u8, z: i32) void {
        self.open_win = .{ .id = 1, .x = x, .y = y, .z = z };
        for (&self.table) |*s| item_mod.freeStack(self.allocator, s);
        var ob: [128]u8 = undefined;
        if (packets.frameOpenWindow(1, 1, "Crafting", 9, &ob)) |f| {
            self.queueRaw(f) catch {};
        } else |_| {}
        self.queueTableWindow();
    }

    /// Move the table grid out (ownership transfer), clear table + result +
    /// open state. Serve loop drops the stacks as entities.
    pub fn takeTableGrid(self: *Conn) [9]?item_mod.Stack {
        var out: [9]?item_mod.Stack = [_]?item_mod.Stack{null} ** 9;
        for (1..10) |i| {
            out[i - 1] = self.table[i];
            self.table[i] = null;
        }
        item_mod.freeStack(self.allocator, &self.table[0]);
        self.open_win = null;
        return out;
    }

    /// Window-1 click router (slots 0-9 table, 10-45 player alias).
    fn onClickTable(self: *Conn, slot: i16, button: i8, action: i16, mode: i8) !void {
        if (slot < 0 or slot > 45) return;
        const s: usize = @intCast(slot);
        switch (mode) {
            0 => {
                if (s == 0) {
                    _ = try self.takeResult(1, self.table[1..10], &self.table[0], true);
                    return;
                }
                if (slot >= 1 and slot <= 9) {
                    if (!(try self.clickPickupImplCell(&self.table[s], button))) return;
                    self.sendSlotWin(1, slot);
                    self.sendSlotWin(-1, -1);
                    self.refreshTable();
                    self.sendSlotWin(1, 0);
                    return;
                }
                // player range 10-45 -> inv 9-44
                const islot: usize = s - 1;
                if (!(try self.clickPickupImplCell(&self.inv[islot], button))) return;
                self.sendSlotWin(1, slot);
                self.sendSlotWin(-1, -1);
            },
            1 => {
                if (s == 0) {
                    try self.craftAll(self.table[1..10], &self.table[0], true);
                    return;
                }
                if (slot >= 1 and slot <= 9) {
                    // shift grid cell -> player range (merge then empty)
                    if (self.table[s] == null) return;
                    if (self.quickMoveCellToInv(&self.table[s])) {
                        self.refreshTable();
                        self.queueTableWindow();
                    }
                    return;
                }
                // player range: hotbar<->main within inv indices
                const islot: usize = s - 1;
                self.clickQuickMove(islot, button);
            },
            2 => {
                if (s == 0) return; // no number-key on the result
                if (button < 0 or button > 8) return;
                if (self.cursor != null) return;
                // swap resolved cell with hotbar (inv 36+button)
                const h: usize = 36 + @as(usize, @intCast(button));
                if (slot >= 1 and slot <= 9) {
                    const t = self.table[s];
                    self.table[s] = self.inv[h];
                    self.inv[h] = t;
                    self.refreshTable();
                    self.queueTableWindow();
                } else {
                    const islot: usize = s - 1;
                    if (islot == h) return;
                    const t = self.inv[islot];
                    self.inv[islot] = self.inv[h];
                    self.inv[h] = t;
                    self.sendSlotWin(1, slot);
                    self.sendSlotWin(1, @as(i16, @intCast(h + 1)));
                }
            },
            else => {},
        }
        _ = action;
    }

    /// Shift-click helper: move a source cell into player range 9..44
    /// (merge first, then first empty). Returns true when anything moved.
    fn quickMoveCellToInv(self: *Conn, src: *?item_mod.Stack) bool {
        if (src.* == null) return false;
        var moved = false;
        var i: usize = 9;
        while (i <= 44) : (i += 1) {
            const dst = self.inv[i] orelse continue;
            const s = src.* orelse break;
            if (!item_mod.canMerge(dst, s)) continue;
            const room: i16 = @as(i16, item_mod.maxStackSize(dst.id)) - dst.count;
            if (room <= 0) continue;
            const n: i16 = @min(room, @as(i16, s.count));
            if (n <= 0) continue;
            self.inv[i].?.count += @as(i8, @intCast(n));
            src.*.?.count -= @as(i8, @intCast(n));
            moved = true;
            if (src.*.?.count <= 0) {
                item_mod.freeStack(self.allocator, src);
                break;
            }
        }
        if (src.* != null) {
            i = 9;
            while (i <= 44) : (i += 1) {
                if (self.inv[i] != null) continue;
                self.inv[i] = src.*;
                src.* = null;
                moved = true;
                break;
            }
        }
        return moved;
    }

    fn sendCursor(self: *Conn) void {
        const f = packets.frameSetSlotAlloc(self.allocator, -1, -1, self.cursor) catch return;
        defer self.allocator.free(f);
        self.queueRaw(f) catch {};
    }

    fn onDig(self: *Conn, status: i8, x: i32, y: u8, z: i32) !Action {
        if (self.is_dead) return .none; // death screen: client sends nothing; drop anything
        // Q-key: 3 = drop whole selected stack, 4 = drop one item.
        // Vanilla `yz.a(boolean)` removes from inventory either way and pops
        // the entity in front of the player with a 40-tick pickup delay.
        if (status == 3 or status == 4) {
            const slot: usize = 36 + self.selected;
            const held = self.inv[slot] orelse return .none;
            if (status == 3) {
                self.inv[slot] = null;
                return .{ .qdrop = .{ .stack = held, .slot = @intCast(slot) } };
            }
            if (held.count <= 1) {
                self.inv[slot] = null;
                return .{ .qdrop = .{ .stack = held, .slot = @intCast(slot) } };
            }
            const one = item_mod.Stack{
                .id = held.id,
                .count = 1,
                .damage = held.damage,
                .nbt = if (held.nbt) |n| try self.allocator.dupe(u8, n) else null,
            };
            self.inv[slot] = .{ .id = held.id, .count = held.count - 1, .damage = held.damage, .nbt = held.nbt };
            return .{ .qdrop = .{ .stack = one, .slot = @intCast(slot) } };
        }
        const creative = self.config.gamemode == 1;
        switch (status) {
            0 => { // start
                if (!self.inReach(x, y, z)) return .none;
                if (creative) return .{ .block_set = .{ .x = x, .y = y, .z = z, .id = game_ids.air, .meta = 0 } };
                self.pending_dig = .{ .x = x, .y = y, .z = z };
                return .none;
            },
            1 => { // cancel
                if (self.pending_dig) |p| {
                    if (p.x == x and p.y == y and p.z == z) self.pending_dig = null;
                }
                return .none;
            },
            2 => { // finish
                if (!self.inReach(x, y, z)) {
                    self.pending_dig = null;
                    return .none;
                }
                if (!creative) {
                    const p = self.pending_dig orelse return .none; // no start seen
                    self.pending_dig = null;
                    if (p.x != x or p.y != y or p.z != z) return .none;
                } else {
                    self.pending_dig = null;
                }
                return .{ .block_set = .{ .x = x, .y = y, .z = z, .id = game_ids.air, .meta = 0 } };
            },
            else => return .none, // eat-finish etc: ignored
        }
    }

    /// Face offsets: 0=-Y,1=+Y,2=-Z,3=+Z,4=-X,5=+X. 255/-1 = no placement.
    fn onPlace(self: *Conn, x: i32, y: u8, z: i32, direction: i8) Action {
        if (self.is_dead) return .none;
        if (direction < 0 or direction > 5) return .none;
        if (!self.inReach(x, y, z)) return .none;
        const held = self.inv[36 + self.selected] orelse return .none;
        // Canonical ids are always < 4096, so the old wire range check is
        // vacuous; unknown wires never reach here (slot parse maps them to empty).
        // target cell adjacent on the clicked face
        var tx = x;
        var ty: i32 = y;
        var tz = z;
        switch (direction) {
            0 => ty -= 1,
            1 => ty += 1,
            2 => tz -= 1,
            3 => tz += 1,
            4 => tx -= 1,
            5 => tx += 1,
            else => unreachable,
        }
        if (ty < 0 or ty > 255) return .none;
        // creative damage value doubles as block metadata (low nibble)
        const m: u4 = @truncate(@as(u16, @bitCast(held.damage)) & 0x0F);
        return .{ .block_set = .{ .x = tx, .y = @intCast(ty), .z = tz, .id = held.id, .meta = m, .face = direction } };
    }

    fn markChunkDirty(self: *Conn) void {
        if (!self.baseline_sent) return;
        const cc = self.playerChunk();
        if (self.sent_center) |c| {
            if (c.cx == cc.cx and c.cz == cc.cz) return;
        }
        self.chunks_dirty = true;
    }

    /// Join packets: abilities, health, XP, own list entry, clock.
    /// Queued after JoinGame/Spawn, before chunk bulks (serveConn orders this).
    pub fn queueJoinPackets(self: *Conn, world_age: i64, time_of_day: i64) !void {
        const creative = self.config.gamemode == 1;
        var ab: [32]u8 = undefined;
        try self.queueRaw(try packets.framePlayerAbilities(if (creative) 0x07 else 0x00, 0.05, 0.1, &ab));
        var hb: [32]u8 = undefined;
        try self.queueRaw(try packets.frameUpdateHealth(self.health, self.food, self.saturation, &hb));
        var xb: [32]u8 = undefined;
        try self.queueRaw(try packets.frameSetExperience(0.0, 0, 0, &xb));
        var lb: [64]u8 = undefined;
        try self.queueRaw(try packets.framePlayerListItem(self.username[0..self.username_len], true, self.ping_ms.load(.acquire), &lb));
        var tb: [32]u8 = undefined;
        try self.queueRaw(try packets.frameTimeUpdate(world_age, time_of_day, &tb));
    }

    pub const TickAction = enum { none, timeout };

    /// Server-driven per-second work. Call with shared lock held; flush outside.
    /// Time update every 1s, keepalive every 15s, kick 30s after the last echo
    /// (or 30s after the first tick when nothing was ever echoed — the send
    /// timestamp refreshes on every ping, so it must NOT anchor the timeout).
    pub fn queueTick(self: *Conn, now_ms: i64, world_age: i64, time_of_day: i64) !TickAction {
        if (self.state != .play or self.dead) return .none;
        if (self.first_tick_ms < 0) self.first_tick_ms = now_ms;
        const since_echo = if (self.last_echo_ms < 0) now_ms - self.first_tick_ms else now_ms - self.last_echo_ms;
        if (since_echo > keepalive_timeout_ms) {
            var db: [128]u8 = undefined;
            const id: i32 = @intFromEnum(ids.PlayClient.disconnect);
            var payload: [120]u8 = undefined;
            var w = codec.PacketWriter.init(&payload);
            try w.writeString("{\"text\":\"Timed out\"}");
            try self.queueRaw(try codec.framePacket(id, w.written(), &db));
            self.dead = true;
            self.close_after_flush = true;
            return .timeout;
        }
        if (now_ms >= self.next_time_ms) {
            var tb: [32]u8 = undefined;
            try self.queueRaw(try packets.frameTimeUpdate(world_age, time_of_day, &tb));
            self.next_time_ms = now_ms + time_interval_ms;
        }
        if (now_ms >= self.next_keepalive_ms) {
            self.keepalive_id += 1;
            var kb: [16]u8 = undefined;
            try self.queueRaw(try packets.frameKeepAlive(self.keepalive_id, &kb));
            self.keepalive_outstanding = true;
            self.keepalive_sent_ms = now_ms;
            self.next_keepalive_ms = now_ms + keepalive_interval_ms;
        }
        return .none;
    }

    fn setPos(self: *Conn, x: f64, y: f64, z: f64, yaw: f32, pitch: f32, on_ground: bool) void {
        if (self.state == .play and !self.is_dead and self.baseline_sent) {
            const dx = x - self.pos_x;
            const dz = z - self.pos_z;
            // Movement exhaustion (vanilla `yz.k` rates): horizontal blocks
            // while grounded, sprint 0.1 / walk 0.01. Airborne moves are free
            // (swim 0.015 needs a water check — documented J2 gap).
            if (on_ground and self.on_ground) {
                const hd = @sqrt(dx * dx + dz * dz);
                if (hd > 0.01) self.addExhaustion(@as(f32, @floatCast(hd)) * @as(f32, if (self.sprinting) 0.1 else 0.01));
            }
        }
        self.groundTransition(y - self.pos_y, on_ground);
        self.pos_x = x;
        self.pos_y = y;
        self.pos_z = z;
        self.yaw = yaw;
        self.pitch = pitch;
        self.on_ground = on_ground;
    }

    /// Shared ground-transition logic (landing stashes pending_fall for the
    /// serve thread's water check; server-grounded + client-airborne + rising
    /// is a jump). dy is the vertical delta (0 for flying-only frames).
    fn groundTransition(self: *Conn, dy: f64, on_ground: bool) void {
        if (self.state != .play or self.is_dead or !self.baseline_sent) return;
        if (self.on_ground and !on_ground and dy > 0) {
            // Vanilla `yz.bj()` via the flying handler; step-ups keep the
            // client grounded, so they don't charge.
            self.addExhaustion(@as(f32, if (self.sprinting) 0.8 else 0.2));
        }
        if (!on_ground and dy < 0) self.fall_acc += @floatCast(-dy);
        if (!self.on_ground and on_ground) {
            if (self.fall_acc > 0) self.pending_fall = .{ .dist = self.fall_acc, .x = self.pos_x, .y = self.pos_y, .z = self.pos_z };
            self.fall_acc = 0;
        }
        if (on_ground) self.fall_acc = 0;
    }

    /// Vanilla `yz.a(float)`: creative (disableDamage) is exempt; cap 40.
    pub fn addExhaustion(self: *Conn, amount: f32) void {
        if (self.config.gamemode == 1) return;
        self.exhaustion = @min(self.exhaustion + amount, 40.0);
    }

    /// Chunk coords of the player's current position (for resend-on-move).
    pub fn playerChunk(self: *const Conn) struct { cx: i32, cz: i32 } {
        return .{
            .cx = @as(i32, @intFromFloat(@floor(self.pos_x / 16.0))),
            .cz = @as(i32, @intFromFloat(@floor(self.pos_z / 16.0))),
        };
    }

    /// Tick-aligned flush: returns pending bytes (owned, caller frees/sends).
    pub fn takeOutput(self: *Conn) ![]u8 {
        const out = try self.out.toOwnedSlice(self.allocator);
        self.out.clearRetainingCapacity();
        return out;
    }
};

test "status flow with split feeds" {
    const a = std.testing.allocator;
    var c = Conn.init(a, std.testing.io, .{}, 1);
    defer c.deinit();
    // handshake -> status
    var hb: [64]u8 = undefined;
    var w = codec.PacketWriter.init(&hb);
    try w.writeVarInt(5);
    try w.writeString("localhost");
    try w.writeUShort(25565);
    try w.writeVarInt(1);
    var hf: [80]u8 = undefined;
    const hframe = try codec.framePacket(0x00, w.written(), &hf);
    // feed one byte at a time (TCP segmentation)
    var got_status = false;
    var i: usize = 0;
    while (i < hframe.len) : (i += 1) {
        try c.feedData(hframe[i .. i + 1]);
        while (try c.poll()) |f| {
            _ = try c.handleFrame(f);
            got_status = true;
        }
    }
    try std.testing.expect(got_status);
    try std.testing.expect(c.state == .status);
    // request
    var rq: [8]u8 = undefined;
    const rqframe = try codec.framePacket(0x00, &.{}, &rq);
    try c.feedData(rqframe);
    const f1 = (try c.poll()).?;
    _ = try c.handleFrame(f1);
    const out1 = try c.takeOutput();
    defer a.free(out1);
    var r = codec.PacketReader.init(out1);
    const h1 = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 0x00), h1.id);
    const js = try r.readString();
    try std.testing.expect(std.mem.indexOf(u8, js, "zigcraft") != null);
    // ping -> pong + close_after_flush
    var pg: [16]u8 = undefined;
    var pw: [8]u8 = undefined;
    std.mem.writeInt(i64, &pw, 987654321, .big);
    const pgframe = try codec.framePacket(0x01, &pw, &pg);
    try c.feedData(pgframe);
    const f2 = (try c.poll()).?;
    const act = try c.handleFrame(f2);
    try std.testing.expectEqual(Action.close_after_flush, act);
    const out2 = try c.takeOutput();
    defer a.free(out2);
    var r2 = codec.PacketReader.init(out2);
    _ = try codec.decodeFrame(&r2);
    try std.testing.expectEqual(@as(i64, 987654321), try packets.parsePing(r2.buffer[r2.index..]));
}

test "offline login -> play bootstrap" {
    const a = std.testing.allocator;
    var c = Conn.init(a, std.testing.io, .{}, 7);
    defer c.deinit();
    // handshake -> login
    var hb: [64]u8 = undefined;
    var w = codec.PacketWriter.init(&hb);
    try w.writeVarInt(5);
    try w.writeString("localhost");
    try w.writeUShort(25565);
    try w.writeVarInt(2);
    var hf: [80]u8 = undefined;
    try c.feedData(try codec.framePacket(0x00, w.written(), &hf));
    _ = try c.handleFrame((try c.poll()).?);
    try std.testing.expect(c.state == .login);
    // login start
    var lb: [32]u8 = undefined;
    var wl = codec.PacketWriter.init(&lb);
    try wl.writeString("testplayer");
    var lf: [48]u8 = undefined;
    try c.feedData(try codec.framePacket(0x00, wl.written(), &lf));
    const act = try c.handleFrame((try c.poll()).?);
    try std.testing.expectEqual(Action.entered_play, act);
    try std.testing.expect(c.state == .play);
    try std.testing.expectEqualStrings("testplayer", c.username[0..c.username_len]);
    const out = try c.takeOutput();
    defer a.free(out);
    // frames: LoginSuccess(0x02) JoinGame(0x01) SpawnPosition(0x05).
    // Chunks (view.completeLogin) then PlayerPosLook(0x08) close the login.
    var r = codec.PacketReader.init(out);
    const h0 = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 0x02), h0.id);
    try std.testing.expectEqualStrings("52d22a52-7b4a-339e-8a09-aa52384d72fd", try r.readString());
    try std.testing.expectEqualStrings("testplayer", try r.readString());
    const h1 = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 0x01), h1.id);
    const j = try packets.parseJoinGame(r.buffer[r.index..]);
    try std.testing.expectEqual(@as(i32, 7), j.eid);
    r.index += 4 + 1 + 1 + 1 + 1 + codec.PacketWriter.varIntLen(@intCast(j.level_type.len)) + j.level_type.len;
    const h2 = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 0x05), h2.id);
    r.index += 12;
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
    // login closer (normally after chunk bulks)
    try c.queuePlayerPosLook();
    const out2 = try c.takeOutput();
    defer a.free(out2);
    var r2 = codec.PacketReader.init(out2);
    const h3 = try codec.decodeFrame(&r2);
    try std.testing.expectEqual(@as(i32, 0x08), h3.id);
}

test "player position tracked (stance consumed), chunk computed" {
    const a = std.testing.allocator;
    var c = Conn.init(a, std.testing.io, .{}, 1);
    defer c.deinit();
    c.state = .play;
    // serverbound 0x06 position+look with stance 66.5
    var pb: [48]u8 = undefined;
    var w = codec.PacketWriter.init(&pb);
    try w.writeDouble(100.7);
    try w.writeDouble(66.5); // stance
    try w.writeDouble(65.0);
    try w.writeDouble(-40.2);
    try w.writeFloat(90.0);
    try w.writeFloat(0.0);
    try w.writeByte(1);
    var pf: [64]u8 = undefined;
    try c.feedData(try codec.framePacket(0x06, w.written(), &pf));
    _ = try c.handleFrame((try c.poll()).?);
    try std.testing.expectApproxEqAbs(@as(f64, 100.7), c.pos_x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 65.0), c.pos_y, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 90.0), @as(f64, c.yaw), 1e-6);
    try std.testing.expect(c.on_ground);
    const cc = c.playerChunk();
    try std.testing.expectEqual(@as(i32, 6), cc.cx); // floor(100.7/16)
    try std.testing.expectEqual(@as(i32, -3), cc.cz); // floor(-40.2/16)
}

test "chat formats, rate-limits, and validates" {
    const a = std.testing.allocator;
    var c = Conn.init(a, std.testing.io, .{}, 1);
    defer c.deinit();
    c.state = .play;
    @memcpy(c.username[0.."Bo".len], "Bo");
    c.username_len = 2;
    const feed = struct {
        fn run(conn: *Conn, text: []const u8) !?Action {
            var sb: [256]u8 = undefined;
            var w = codec.PacketWriter.init(&sb);
            try w.writeString(text);
            var f: [300]u8 = undefined;
            try conn.feedData(try codec.framePacket(0x01, w.written(), &f));
            return try conn.handleFrame((try conn.poll()).?);
        }
    }.run;
    // first message formats JSON into chat_buf
    const act = try feed(&c, "hi <there>");
    try std.testing.expect(act.? == .chat);
    try std.testing.expectEqualStrings("{\"text\":\"<Bo> hi <there>\"}", c.chat_buf[0..act.?.chat.json_len]);
    // immediate second message: spam kick (simulated recent chat => deterministic)
    c.last_chat_ms = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds();
    const act2 = try feed(&c, "again");
    try std.testing.expectEqual(Action.disconnect_queued, act2.?);
    try std.testing.expect(c.close_after_flush);
}

test "chat drops invalid/overlong without kicking" {
    const a = std.testing.allocator;
    var c = Conn.init(a, std.testing.io, .{}, 1);
    defer c.deinit();
    c.state = .play;
    @memcpy(c.username[0.."Bo".len], "Bo");
    c.username_len = 2;
    // overlong (101 chars): dropped, no output, no kick
    var long: [101]u8 = [_]u8{'x'} ** 101;
    var lb: [256]u8 = undefined;
    var lw = codec.PacketWriter.init(&lb);
    try lw.writeString(&long);
    var lf: [300]u8 = undefined;
    try c.feedData(try codec.framePacket(0x01, lw.written(), &lf));
    try std.testing.expect((try c.handleFrame((try c.poll()).?)) == .none);
    const out = try c.takeOutput();
    defer a.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
    try std.testing.expect(!c.close_after_flush);
}

test "bad protocol disconnects" {
    const a = std.testing.allocator;
    var c = Conn.init(a, std.testing.io, .{}, 1);
    defer c.deinit();
    var hb: [64]u8 = undefined;
    var w = codec.PacketWriter.init(&hb);
    try w.writeVarInt(47); // 1.8, wrong
    try w.writeString("localhost");
    try w.writeUShort(25565);
    try w.writeVarInt(2);
    var hf: [80]u8 = undefined;
    try c.feedData(try codec.framePacket(0x00, w.written(), &hf));
    const act = try c.handleFrame((try c.poll()).?);
    try std.testing.expectEqual(Action.disconnect_queued, act);
    try std.testing.expect(c.close_after_flush);
}

test "play keepalive recorded" {
    const a = std.testing.allocator;
    var c = Conn.init(a, std.testing.io, .{}, 1);
    defer c.deinit();
    c.state = .play;
    var kb: [8]u8 = undefined;
    var w = codec.PacketWriter.init(&kb);
    try w.writeInt(777);
    var kf: [16]u8 = undefined;
    try c.feedData(try codec.framePacket(0x00, w.written(), &kf));
    _ = try c.handleFrame((try c.poll()).?);
    try std.testing.expectEqual(@as(i32, 777), c.last_keepalive);
    const out = try c.takeOutput();
    defer a.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "dig/place/held/creative/arm behavior" {
    const a = std.testing.allocator;
    // creative conn near origin: pos defaults to config spawn (8,64,8)
    var c = Conn.init(a, std.testing.io, .{ .gamemode = 1, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 7);
    defer c.deinit();
    c.state = .play;
    const feed = struct {
        fn run(conn: *Conn, id: i32, body: []const u8) !?Action {
            var f: [64]u8 = undefined;
            try conn.feedData(try codec.framePacket(id, body, &f));
            const fr = (try conn.poll()).?;
            return try conn.handleFrame(fr);
        }
    }.run;
    // helper: dig body
    const digBody = struct {
        fn run(status: i8, x: i32, y: u8, z: i32, out: []u8) []const u8 {
            var w = codec.PacketWriter.init(out);
            w.writeByte(@bitCast(status)) catch unreachable;
            w.writeInt(x) catch unreachable;
            w.writeByte(y) catch unreachable;
            w.writeInt(z) catch unreachable;
            w.writeByte(1) catch unreachable; // face
            return w.written();
        }
    }.run;
    var db: [32]u8 = undefined;
    // creative: start breaks immediately (block next to spawn)
    {
        const act = try feed(&c, 0x07, digBody(0, 8, 64, 9, &db));
        try std.testing.expect(act != null);
        const ev = act.?.block_set;
        try std.testing.expectEqual(game_ids.air, ev.id);
        try std.testing.expectEqual(@as(i32, 8), ev.x);
        try std.testing.expectEqual(@as(u8, 64), ev.y);
        try std.testing.expectEqual(@as(i32, 9), ev.z);
    }
    // creative: finish also breaks
    {
        const act = try feed(&c, 0x07, digBody(2, 8, 64, 9, &db));
        try std.testing.expect(act.?.block_set.id == game_ids.air);
    }
    // far away: ignored
    {
        const act = try feed(&c, 0x07, digBody(0, 9000, 64, 9, &db));
        try std.testing.expect(act.? == .none);
    }
    // survival: finish without start is ignored; start->finish works
    {
        var s = Conn.init(a, std.testing.io, .{ .gamemode = 0, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 8);
        defer s.deinit();
        s.state = .play;
        try std.testing.expect((try feed(&s, 0x07, digBody(2, 8, 64, 9, &db))).? == .none);
        try std.testing.expect((try feed(&s, 0x07, digBody(0, 8, 64, 9, &db))).? == .none); // start
        const act = try feed(&s, 0x07, digBody(2, 8, 64, 9, &db));
        try std.testing.expect(act.?.block_set.id == game_ids.air);
        // cancel clears pending: start then cancel then finish -> none
        _ = try feed(&s, 0x07, digBody(0, 8, 64, 10, &db));
        var cb: [32]u8 = undefined;
        _ = try feed(&s, 0x07, digBody(1, 8, 64, 10, &cb));
        try std.testing.expect((try feed(&s, 0x07, digBody(2, 8, 64, 10, &db))).? == .none);
    }
    // held slot + creative give + place
    {
        // give stone(id 1, damage 3) into hotbar slot 36+2=38
        var cb: [32]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeShort(38);
        try w.writeShort(1);
        try w.writeByte(64);
        try w.writeShort(3);
        try w.writeShort(-1);
        _ = try feed(&c, 0x10, w.written());
        try std.testing.expect(c.inv[38].?.id == game_ids.stone);
        // select hotbar slot 2
        var hb: [8]u8 = undefined;
        var hw = codec.PacketWriter.init(&hb);
        try hw.writeShort(2);
        _ = try feed(&c, 0x09, hw.written());
        try std.testing.expectEqual(@as(u8, 2), c.selected);
        // place against +Y face of (8,64,8) -> target (8,65,8), id 1 meta 3
        var pb: [48]u8 = undefined;
        var pw = codec.PacketWriter.init(&pb);
        try pw.writeInt(8);
        try pw.writeByte(64);
        try pw.writeInt(8);
        try pw.writeByte(1); // face +Y
        try pw.writeShort(1);
        try pw.writeByte(1);
        try pw.writeShort(3);
        try pw.writeShort(-1);
        try pw.writeByte(8);
        try pw.writeByte(8);
        try pw.writeByte(8);
        const pact = try feed(&c, 0x08, pw.written());
        const be = pact.?.block_set;
        try std.testing.expectEqual(game_ids.stone, be.id);
        try std.testing.expectEqual(@as(u4, 3), be.meta);
        try std.testing.expectEqual(@as(i32, 8), be.x);
        try std.testing.expectEqual(@as(u8, 65), be.y);
        // direction 255 (-1): ignored
        var qb: [48]u8 = undefined;
        var qw = codec.PacketWriter.init(&qb);
        try qw.writeInt(8);
        try qw.writeByte(64);
        try qw.writeInt(8);
        try qw.writeByte(255);
        try qw.writeShort(-1);
        try qw.writeByte(0);
        try qw.writeByte(0);
        try qw.writeByte(0);
        const qact = try feed(&c, 0x08, qw.written());
        try std.testing.expect(qact.? == .none);
    }
    // arm swing: own eid relays, others ignored
    {
        var ab: [8]u8 = undefined;
        var w = codec.PacketWriter.init(&ab);
        try w.writeInt(7); // own eid
        try w.writeByte(0);
        const act = try feed(&c, 0x0A, w.written());
        try std.testing.expectEqual(@as(i8, 0), act.?.arm_swing);
        var zb: [8]u8 = undefined;
        var zw = codec.PacketWriter.init(&zb);
        try zw.writeInt(99);
        try zw.writeByte(0);
        const zact = try feed(&c, 0x0A, zw.written());
        try std.testing.expect(zact.? == .none);
    }
}

test "use entity: attack validation, damage table, dead gates, respawn" {
    const a = std.testing.allocator;
    var c = Conn.init(a, std.testing.io, .{ .gamemode = 0, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 7);
    defer c.deinit();
    c.state = .play;
    @memcpy(c.username[0.."Al".len], "Al");
    c.username_len = "Al".len;
    const feed = struct {
        fn run(conn: *Conn, id: i32, body: []const u8) !?Action {
            var f: [64]u8 = undefined;
            try conn.feedData(try codec.framePacket(id, body, &f));
            const fr = (try conn.poll()).?;
            return try conn.handleFrame(fr);
        }
    }.run;
    const useBody = struct {
        fn run(target: i32, mouse: i8, out: []u8) []const u8 {
            var w = codec.PacketWriter.init(out);
            w.writeInt(target) catch unreachable;
            w.writeByte(@bitCast(mouse)) catch unreachable;
            return w.written();
        }
    }.run;
    var ub: [16]u8 = undefined;
    // empty hand attack -> event with fist damage, attacker snapshot
    {
        const act = try feed(&c, 0x02, useBody(99, 1, &ub));
        const ev = act.?.attack;
        try std.testing.expectEqual(@as(i32, 99), ev.target_eid);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), ev.dmg, 1e-6);
        try std.testing.expectApproxEqAbs(@as(f64, 8.5), ev.ax, 1e-9);
    }
    // interact (0) and interact-at (2): dropped, no target system yet
    {
        try std.testing.expect((try feed(&c, 0x02, useBody(99, 0, &ub))).? == .none);
        var ib: [32]u8 = undefined;
        var w = codec.PacketWriter.init(&ib);
        try w.writeInt(99);
        try w.writeByte(2);
        try w.writeFloat(1.0);
        try w.writeFloat(2.0);
        try w.writeFloat(3.0);
        try std.testing.expect((try feed(&c, 0x02, w.written())).? == .none);
    }
    // self-hit dropped
    try std.testing.expect((try feed(&c, 0x02, useBody(7, 1, &ub))).? == .none);
    // damage table: diamond sword 7, iron axe 5, stick 1
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), item_mod.meleeDamage(game_ids.diamond_sword), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), item_mod.meleeDamage(game_ids.iron_axe), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), item_mod.meleeDamage(game_ids.stick), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), item_mod.meleeDamage(game_ids.air), 1e-6);
    // diamond sword in hand -> 7.0 event
    {
        var cb: [32]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeShort(36);
        try w.writeShort(276);
        try w.writeByte(1);
        try w.writeShort(0);
        try w.writeShort(-1);
        c.inv[36] = .{ .id = game_ids.diamond_sword, .count = 1, .damage = 0, .nbt = null };
        c.selected = 0;
        const act = try feed(&c, 0x02, useBody(100, 1, &ub));
        try std.testing.expectApproxEqAbs(@as(f32, 7.0), act.?.attack.dmg, 1e-6);
        c.inv[36] = null;
    }
    // dead: dig/place/attack all dropped
    {
        c.is_dead = true;
        var db: [32]u8 = undefined;
        var w = codec.PacketWriter.init(&db);
        try w.writeByte(0);
        try w.writeInt(8);
        try w.writeByte(64);
        try w.writeInt(9);
        try w.writeByte(1);
        try std.testing.expect((try feed(&c, 0x07, w.written())).? == .none);
        try std.testing.expect((try feed(&c, 0x02, useBody(99, 1, &ub))).? == .none);
        // chat still works while dead
        var chb: [32]u8 = undefined;
        var chw = codec.PacketWriter.init(&chb);
        try chw.writeString("hi");
        const chact = try feed(&c, 0x01, chw.written());
        try std.testing.expect(chact.? == .chat);
        // respawn via client status 0: healed, alive, Update Health queued
        var sb: [8]u8 = undefined;
        var sw = codec.PacketWriter.init(&sb);
        try sw.writeByte(0);
        try std.testing.expect((try feed(&c, 0x16, sw.written())).? == .none);
        try std.testing.expect(!c.is_dead);
        try std.testing.expectApproxEqAbs(@as(f32, 20.0), c.health, 1e-6);
        const out = try c.takeOutput();
        defer a.free(out);
        var r = codec.PacketReader.init(out);
        try std.testing.expectEqual(@as(i32, 0x06), (try codec.decodeFrame(&r)).id);
        try std.testing.expectApproxEqAbs(@as(f32, 20.0), try r.readFloat(), 1e-6);
    }
}

test "crafting table: 3x3 take, shift-craft, close drops grid" {
    const a = std.testing.allocator;
    var c = Conn.init(a, std.testing.io, .{ .gamemode = 0, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 7);
    defer c.deinit();
    c.state = .play;
    const feed = struct {
        fn run(conn: *Conn, id: i32, body: []const u8) !?Action {
            var f: [64]u8 = undefined;
            try conn.feedData(try codec.framePacket(id, body, &f));
            const fr = (try conn.poll()).?;
            return try conn.handleFrame(fr);
        }
    }.run;
    // open + iron pickaxe shape (row0 iron, stick col1 rows1-2)
    c.openTableUI(8, 64, 8);
    try std.testing.expect(c.open_win != null);
    c.table[1] = .{ .id = game_ids.iron_ingot, .count = 1, .damage = 0, .nbt = null };
    c.table[2] = .{ .id = game_ids.iron_ingot, .count = 1, .damage = 0, .nbt = null };
    c.table[3] = .{ .id = game_ids.iron_ingot, .count = 1, .damage = 0, .nbt = null };
    c.table[5] = .{ .id = game_ids.stick, .count = 1, .damage = 0, .nbt = null };
    c.table[8] = .{ .id = game_ids.stick, .count = 1, .damage = 0, .nbt = null };
    c.refreshTable();
    try std.testing.expect(c.table[0] != null);
    try std.testing.expectEqual(game_ids.iron_pickaxe, c.table[0].?.id);
    // take via mode-0 click on window-1 slot 0 (action 1 seeds)
    {
        var cb: [64]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeByte(1); // window 1
        try w.writeShort(0);
        try w.writeByte(0);
        try w.writeShort(1);
        try w.writeByte(0);
        try w.writeShort(-1);
        try w.writeShort(-1);
        _ = try feed(&c, 0x0E, w.written());
        try std.testing.expect(c.cursor != null);
        try std.testing.expectEqual(game_ids.iron_pickaxe, c.cursor.?.id);
        try std.testing.expect(c.table[1] == null); // consumed
        try std.testing.expect(c.table[0] == null); // no longer matches
        var owned: ?item_mod.Stack = c.cursor;
        item_mod.freeStack(a, &owned);
        c.cursor = null;
        { const o = try c.takeOutput(); defer a.free(o); }
    }
    // shift-craft sticks x64: grid col0 rows0-2... use 3-high column? sticks need 2x1; fill col0
    c.table[1] = .{ .id = game_ids.planks, .count = 64, .damage = 0, .nbt = null };
    c.table[4] = .{ .id = game_ids.planks, .count = 64, .damage = 0, .nbt = null };
    {
        var cb: [64]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeByte(1);
        try w.writeShort(0);
        try w.writeByte(0);
        try w.writeShort(2);
        try w.writeByte(1); // shift
        try w.writeShort(-1);
        try w.writeShort(-1);
        _ = try feed(&c, 0x0E, w.written());
        var total: i32 = 0;
        for (9..45) |i| if (c.inv[i]) |st| if (st.id == game_ids.stick) {
            total += st.count;
        };
        try std.testing.expectEqual(@as(i32, 256), total);
        { const o = try c.takeOutput(); defer a.free(o); }
    }
    // close (0x0D) drops remaining grid stacks as entities
    c.table[6] = .{ .id = game_ids.stone, .count = 7, .damage = 0, .nbt = null };
    {
        var cb: [8]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeByte(1);
        const act = try feed(&c, 0x0D, w.written());
        const tc = act.?.table_close;
        var n: usize = 0;
        for (tc.stacks) |st| if (st != null) {
            n += 1;
            try std.testing.expectEqual(game_ids.stone, st.?.id);
        };
        try std.testing.expectEqual(@as(usize, 1), n);
        try std.testing.expect(c.open_win == null);
        var owned = tc.stacks;
        for (&owned) |*st| item_mod.freeStack(a, st);
        { const o = try c.takeOutput(); defer a.free(o); }
    }
    // table shift-craft (craftAll path, window 1): sticks from 2x64 planks
    {
        c.openTableUI(8, 64, 8);
        c.table[1] = .{ .id = game_ids.planks, .count = 64, .damage = 0, .nbt = null };
        c.table[4] = .{ .id = game_ids.planks, .count = 64, .damage = 0, .nbt = null };
        c.refreshTable();
        var cb: [64]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeByte(1);
        try w.writeShort(0);
        try w.writeByte(0);
        try w.writeShort(2);
        try w.writeByte(1); // shift
        try w.writeShort(-1);
        try w.writeShort(-1);
        _ = try feed(&c, 0x0E, w.written());
        var total: i32 = 0;
        for (9..45) |i| if (c.inv[i]) |st| if (st.id == game_ids.stick) {
            total += st.count;
        };
        try std.testing.expectEqual(@as(i32, 256), total);
        { const o = try c.takeOutput(); defer a.free(o); }
    }
}

test "click window: pickup/place/merge/swap/shift/number/desync/nbt" {
    const a = std.testing.allocator;
    var c = Conn.init(a, std.testing.io, .{ .gamemode = 0, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 7);
    defer c.deinit();
    c.state = .play;
    @memcpy(c.username[0.."Bo".len], "Bo");
    c.username_len = "Bo".len;
    const feed = struct {
        fn run(conn: *Conn, id: i32, body: []const u8) !?Action {
            var f: [64]u8 = undefined;
            try conn.feedData(try codec.framePacket(id, body, &f));
            const fr = (try conn.poll()).?;
            return try conn.handleFrame(fr);
        }
    }.run;
    const click = struct {
        fn run(conn: *Conn, slot: i16, button: i8, action: i16, mode: i8) !?Action {
            var cb: [32]u8 = undefined;
            var w = codec.PacketWriter.init(&cb);
            try w.writeByte(0); // window 0
            try w.writeShort(slot);
            try w.writeByte(@as(u8, @bitCast(button)));
            try w.writeShort(action);
            try w.writeByte(@as(u8, @bitCast(mode)));
            try w.writeShort(-1); // empty clicked slot
            return try feed(conn, 0x0E, w.written());
        }
    }.run;
    // 0. movement accounting: walk/jump/fall/sprint exhaustion + landing
    {
        var m = Conn.init(a, std.testing.io, .{ .gamemode = 0, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 7);
        defer m.deinit();
        m.state = .play;
        m.baseline_sent = true;
        m.pos_x = 8.5;
        m.pos_y = 64.0;
        m.pos_z = 8.5;
        m.on_ground = true;
        // walk 1 block: +0.01
        m.setPos(9.5, 64.0, 8.5, 0, 0, true);
        try std.testing.expectApproxEqAbs(@as(f32, 0.01), m.exhaustion, 1e-6);
        // takeoff upward: jump +0.2 (no fall accumulated rising)
        m.setPos(9.5, 64.6, 8.5, 0, 0, false);
        try std.testing.expectApproxEqAbs(@as(f32, 0.21), m.exhaustion, 1e-6);
        try std.testing.expectEqual(@as(f32, 0), m.fall_acc);
        // fall 5.1 down: accumulates
        m.setPos(9.5, 59.5, 8.5, 0, 0, false);
        try std.testing.expectApproxEqAbs(@as(f32, 5.1), m.fall_acc, 1e-4);
        // land: pending fall stashed, accumulator cleared
        m.setPos(9.5, 59.5, 8.5, 0, 0, true);
        try std.testing.expectEqual(@as(f32, 0), m.fall_acc);
        try std.testing.expect(m.pending_fall != null);
        try std.testing.expectApproxEqAbs(@as(f32, 5.1), m.pending_fall.?.dist, 1e-4);
        // sprint flag via 0x0B action 4/5; sprint-jump costs 0.8
        var eb: [16]u8 = undefined;
        var ew = codec.PacketWriter.init(&eb);
        try ew.writeInt(7);
        try ew.writeByte(4);
        try ew.writeInt(0);
        _ = try feed(&m, 0x0B, ew.written());
        try std.testing.expect(m.sprinting);
        m.on_ground = true;
        m.setPos(9.5, 60.0, 8.5, 0, 0, false);
        try std.testing.expectApproxEqAbs(@as(f32, 0.21 + 0.8), m.exhaustion, 1e-4);
        // exhaustion caps at 40 (vanilla FoodStats cap)
        m.exhaustion = 39.9;
        m.addExhaustion(5.0);
        try std.testing.expectEqual(@as(f32, 40.0), m.exhaustion);
        // creative is exempt
        m.config.gamemode = 1;
        m.exhaustion = 0;
        m.addExhaustion(3.0);
        try std.testing.expectEqual(@as(f32, 0), m.exhaustion);
    }
    // 0. Crafting 2x2: sticks from 2 planks, take consumes grid.
    {
        c.inv[1] = .{ .id = game_ids.planks, .count = 1, .damage = 0, .nbt = null };
        c.inv[3] = .{ .id = game_ids.planks, .count = 1, .damage = 0, .nbt = null };
        c.refreshCrafting();
        try std.testing.expect(c.inv[0] != null);
        try std.testing.expectEqual(game_ids.stick, c.inv[0].?.id);
        try std.testing.expectEqual(@as(i8, 4), c.inv[0].?.count);
        // take with left-click on slot 0 (mode 0, empty cursor)
        var cb: [64]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeByte(0);
        try w.writeShort(0);
        try w.writeByte(0);
        try w.writeShort(4);
        try w.writeByte(0);
        try w.writeShort(-1);
        try w.writeShort(-1); // clicked item: empty
        _ = try feed(&c, 0x0E, w.written());
        try std.testing.expect(c.cursor != null);
        try std.testing.expectEqual(game_ids.stick, c.cursor.?.id);
        try std.testing.expect(c.inv[1] == null and c.inv[3] == null);
        try std.testing.expect(c.inv[0] == null); // grid empty -> no match
        var owned: ?item_mod.Stack = c.cursor;
        item_mod.freeStack(a, &owned);
        c.cursor = null;
        { const o = try c.takeOutput(); defer a.free(o); }
    }
    // 0b. Shift-click result crafts repeatedly into the pack.
    {
        c.inv[1] = .{ .id = game_ids.planks, .count = 64, .damage = 0, .nbt = null };
        c.inv[3] = .{ .id = game_ids.planks, .count = 64, .damage = 0, .nbt = null };
        c.refreshCrafting();
        var cb: [64]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeByte(0);
        try w.writeShort(0);
        try w.writeByte(0);
        try w.writeShort(5);
        try w.writeByte(1); // shift
        try w.writeShort(-1); // clicked item: empty
        _ = try feed(&c, 0x0E, w.written());
        // 64 crafts x4 sticks = 256 sticks across 4+ stacks in main
        var total: i32 = 0;
        for (9..45) |i| if (c.inv[i]) |st| if (st.id == game_ids.stick) {
            total += st.count;
        };
        try std.testing.expectEqual(@as(i32, 256), total);
        try std.testing.expect(c.inv[1] == null and c.inv[3] == null);
        { const o = try c.takeOutput(); defer a.free(o); }
        c.click_seq = 1; // restore the action counter for the steps below
        for (9..45) |i| item_mod.freeStack(a, &c.inv[i]); // clear crafted stacks
    }
    // 0. Creative 0x10 rejects the result slot (vanilla parity).
    {
        // two planks vertical = sticks (a lone plank is a button)
        c.inv[1] = .{ .id = game_ids.planks, .count = 1, .damage = 0, .nbt = null };
        c.inv[3] = .{ .id = game_ids.planks, .count = 1, .damage = 0, .nbt = null };
        c.refreshCrafting();
        try std.testing.expect(c.inv[0] != null); // sticks offered
        var cb: [32]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeShort(0); // slot 0: rejected
        try w.writeShort(999);
        try w.writeByte(1);
        try w.writeShort(0);
        try w.writeShort(-1);
        var f: [64]u8 = undefined;
        try c.feedData(try codec.framePacket(0x10, w.written(), &f));
        const fr = (try c.poll()).?;
        _ = try c.handleFrame(fr);
        try std.testing.expect(c.inv[0] != null); // recompute untouched it
        try std.testing.expectEqual(game_ids.stick, c.inv[0].?.id);
        c.inv[0] = null;
        c.inv[1] = null;
        c.inv[3] = null;
        { const o = try c.takeOutput(); defer a.free(o); }
    }
    // 0. Q-drop: status 4 drops one (slot decrements, event owns one),
    // status 3 drops the whole stack (slot empties).
    c.inv[36] = .{ .id = game_ids.diamond, .count = 5, .damage = 0, .nbt = null };
    {
        var qb: [32]u8 = undefined;
        var qw = codec.PacketWriter.init(&qb);
        try qw.writeByte(4); // status: drop one
        try qw.writeInt(@as(i32, 0));
        try qw.writeByte(64);
        try qw.writeInt(@as(i32, 0));
        try qw.writeByte(1); // face
        const act = try feed(&c, 0x07, qw.written());
        const q = act.?.qdrop;
        try std.testing.expectEqual(@as(i16, 36), q.slot);
        try std.testing.expectEqual(game_ids.diamond, q.stack.id);
        try std.testing.expectEqual(@as(i8, 1), q.stack.count);
        try std.testing.expectEqual(@as(i8, 4), c.inv[36].?.count);
        var owned: ?item_mod.Stack = q.stack;
        item_mod.freeStack(a, &owned);
    }
    {
        var qb: [32]u8 = undefined;
        var qw = codec.PacketWriter.init(&qb);
        try qw.writeByte(3); // status: drop whole stack
        try qw.writeInt(@as(i32, 0));
        try qw.writeByte(64);
        try qw.writeInt(@as(i32, 0));
        try qw.writeByte(1);
        const act = try feed(&c, 0x07, qw.written());
        const q = act.?.qdrop;
        try std.testing.expectEqual(@as(i8, 4), q.stack.count);
        try std.testing.expect(c.inv[36] == null);
        var owned: ?item_mod.Stack = q.stack;
        item_mod.freeStack(a, &owned);
    }
    // 1. pickup all (left on stack, empty cursor) -> slot empty, cursor full
    c.inv[10] = .{ .id = game_ids.stone, .count = 64, .damage = 0, .nbt = null };
    try std.testing.expect((try click(&c, 10, 0, 1, 0)).? == .none);
    try std.testing.expect(c.inv[10] == null);
    try std.testing.expectEqual(@as(i8, 64), c.cursor.?.count);
    {
        const out = try c.takeOutput();
        defer a.free(out);
        // slot 10 cleared + cursor set
        var r = codec.PacketReader.init(out);
        var saw_slot = false;
        var saw_cursor = false;
        while (r.remaining() > 0) {
            const h = try codec.decodeFrame(&r);
            try std.testing.expectEqual(@as(i32, 0x2F), h.id);
            const win = @as(i8, @bitCast(try r.readByte())); // window
            const slot = try r.readShort();
            if (slot == 10) {
                try std.testing.expectEqual(@as(i16, -1), try r.readShort());
                saw_slot = true;
            } else if (slot == -1) {
                // cursor must ride window -1 (window 0/slot -1 crashes vanilla)
                try std.testing.expectEqual(@as(i8, -1), win);
                try std.testing.expectEqual(@as(i16, 1), try r.readShort());
                try std.testing.expectEqual(@as(i8, 64), @as(i8, @bitCast(try r.readByte())));
                try std.testing.expectEqual(@as(i16, 0), try r.readShort());
                try std.testing.expectEqual(@as(i16, -1), try r.readShort());
                saw_cursor = true;
            } else return error.TestUnexpectedResult;
        }
        try std.testing.expect(saw_slot and saw_cursor);
    }
    // 2. place all into empty slot
    try std.testing.expect((try click(&c, 11, 0, 2, 0)).? == .none);
    try std.testing.expectEqual(@as(i8, 64), c.inv[11].?.count);
    try std.testing.expect(c.cursor == null);
    { const o = try c.takeOutput(); defer a.free(o); }
    // 3. right-click pickup half (ceil): 10 -> cursor 5, slot 5
    c.inv[12] = .{ .id = game_ids.stone, .count = 10, .damage = 0, .nbt = null };
    try std.testing.expect((try click(&c, 12, 1, 3, 0)).? == .none);
    try std.testing.expectEqual(@as(i8, 5), c.cursor.?.count);
    try std.testing.expectEqual(@as(i8, 5), c.inv[12].?.count);
    { const o = try c.takeOutput(); defer a.free(o); }
    // 4. right-click place one: slot 13 empty -> 1, cursor 5 -> 4
    try std.testing.expect((try click(&c, 13, 1, 4, 0)).? == .none);
    try std.testing.expectEqual(@as(i8, 1), c.inv[13].?.count);
    try std.testing.expectEqual(@as(i8, 4), c.cursor.?.count);
    { const o = try c.takeOutput(); defer a.free(o); }
    // 5. merge: slot has 60, cursor has 10 of same -> slot 64, cursor 6
    c.inv[14] = .{ .id = game_ids.stone, .count = 60, .damage = 0, .nbt = null };
    c.cursor = .{ .id = game_ids.stone, .count = 10, .damage = 0, .nbt = null };
    try std.testing.expect((try click(&c, 14, 0, 5, 0)).? == .none);
    try std.testing.expectEqual(@as(i8, 64), c.inv[14].?.count);
    try std.testing.expectEqual(@as(i8, 6), c.cursor.?.count);
    { const o = try c.takeOutput(); defer a.free(o); }
    // 6. swap: cursor stone vs slot dirt
    c.inv[16] = .{ .id = game_ids.dirt, .count = 5, .damage = 0, .nbt = null };
    c.cursor = .{ .id = game_ids.stone, .count = 6, .damage = 0, .nbt = null };
    try std.testing.expect((try click(&c, 16, 0, 6, 0)).? == .none);
    try std.testing.expectEqual(game_ids.stone, c.inv[16].?.id);
    try std.testing.expectEqual(@as(i8, 6), c.inv[16].?.count);
    try std.testing.expectEqual(game_ids.dirt, c.cursor.?.id);
    { const o = try c.takeOutput(); defer a.free(o); }
    // 7. shift-click merge: main slot 20 (dirt 32) into hotbar 36 (dirt 32)
    // exact fill: source empties, no remainder to place
    c.cursor = null;
    c.inv[20] = .{ .id = game_ids.stone, .count = 32, .damage = 0, .nbt = null };
    c.inv[36] = .{ .id = game_ids.stone, .count = 32, .damage = 0, .nbt = null };
    c.inv[37] = .{ .id = game_ids.grass, .count = 1, .damage = 0, .nbt = null };
    try std.testing.expect((try click(&c, 20, 0, 7, 1)).? == .none);
    try std.testing.expect(c.inv[20] == null);
    try std.testing.expectEqual(@as(i8, 64), c.inv[36].?.count);
    try std.testing.expect(c.inv[38] == null);
    // 7b. shift-click fill: no merge target -> first empty dest slot (38)
    c.inv[24] = .{ .id = game_ids.stone, .count = 10, .damage = 0, .nbt = null };
    try std.testing.expect((try click(&c, 24, 0, 8, 1)).? == .none);
    try std.testing.expect(c.inv[24] == null);
    try std.testing.expectEqual(@as(i8, 10), c.inv[38].?.count);
    { const o = try c.takeOutput(); defer a.free(o); }
    // 8. number key: swap slot 21 with hotbar 0 (button 0); ignored w/ cursor
    c.inv[21] = .{ .id = game_ids.planks, .count = 1, .damage = 0, .nbt = null };
    c.inv[36] = .{ .id = game_ids.stone, .count = 64, .damage = 0, .nbt = null };
    try std.testing.expect((try click(&c, 21, 0, 9, 2)).? == .none);
    try std.testing.expectEqual(game_ids.stone, c.inv[21].?.id);
    try std.testing.expectEqual(game_ids.planks, c.inv[36].?.id);
    c.cursor = .{ .id = game_ids.stone, .count = 1, .damage = 0, .nbt = null };
    try std.testing.expect((try click(&c, 21, 1, 10, 2)).? == .none);
    try std.testing.expectEqual(game_ids.stone, c.inv[21].?.id); // unchanged
    c.cursor = null;
    { const o = try c.takeOutput(); defer a.free(o); }
    // 9. desync: reused action number triggers full Window Items + ignore
    c.inv[22] = .{ .id = game_ids.bedrock, .count = 3, .damage = 0, .nbt = null };
    try std.testing.expect((try click(&c, 22, 0, 10, 0)).? == .none); // stale action
    try std.testing.expectEqual(game_ids.bedrock, c.inv[22].?.id); // untouched
    try std.testing.expectEqual(@as(i8, 3), c.inv[22].?.count);
    {
        const out = try c.takeOutput();
        defer a.free(out);
        var r = codec.PacketReader.init(out);
        try std.testing.expectEqual(@as(i32, 0x30), (try codec.decodeFrame(&r)).id);
        try std.testing.expectEqual(@as(u8, 0), try r.readByte()); // window
        try std.testing.expectEqual(@as(i16, 45), try r.readShort()); // full inventory
    }
    // 10. NBT survives moves: whole-stack pickup transfers the tag bytes
    // (same allocation, no copy); split-half copies them (no aliasing).
    const tag = [_]u8{ 0x0A, 0x00, 0x03, 0x64, 0x75, 0x6D };
    const owned_tag = try a.dupe(u8, &tag);
    c.inv[30] = .{ .id = game_ids.diamond_sword, .count = 1, .damage = 0, .nbt = owned_tag };
    try std.testing.expect((try click(&c, 30, 0, 11, 0)).? == .none); // pickup
    try std.testing.expect(c.inv[30] == null);
    try std.testing.expectEqualSlices(u8, &tag, c.cursor.?.nbt.?);
    try std.testing.expect(c.cursor.?.nbt.?.ptr == owned_tag.ptr); // moved, not copied
    { const o = try c.takeOutput(); defer a.free(o); }
    // park it in an empty slot (place path keeps NBT too)
    try std.testing.expect((try click(&c, 31, 0, 12, 0)).? == .none);
    try std.testing.expect(c.cursor == null);
    try std.testing.expectEqualSlices(u8, &tag, c.inv[31].?.nbt.?);
    { const o = try c.takeOutput(); defer a.free(o); }
    // two-stack split: fresh enchanted stack of 2, right-click takes half
    const tag2 = try a.dupe(u8, &tag);
    c.inv[32] = .{ .id = game_ids.diamond_sword, .count = 2, .damage = 0, .nbt = tag2 };
    try std.testing.expect((try click(&c, 32, 1, 13, 0)).? == .none);
    try std.testing.expectEqual(@as(i8, 1), c.cursor.?.count);
    try std.testing.expectEqual(@as(i8, 1), c.inv[32].?.count);
    try std.testing.expectEqualSlices(u8, c.cursor.?.nbt.?, c.inv[32].?.nbt.?);
    try std.testing.expect(c.cursor.?.nbt.?.ptr != c.inv[32].?.nbt.?.ptr); // independent copies
    { const o = try c.takeOutput(); defer a.free(o); }
}

test "join packets order + fields" {
    const a = std.testing.allocator;
    var c = Conn.init(a, std.testing.io, .{ .gamemode = 1 }, 1);
    defer c.deinit();
    @memcpy(c.username[0.."Steve".len], "Steve");
    c.username_len = "Steve".len;
    c.state = .play;
    try c.queueJoinPackets(24000, 6000);
    const out = try c.takeOutput();
    defer a.free(out);
    var r = codec.PacketReader.init(out);
    const want = [_]i32{ 0x39, 0x06, 0x1F, 0x38, 0x03 };
    for (want) |id| {
        const h = try codec.decodeFrame(&r);
        try std.testing.expectEqual(id, h.id);
        switch (id) {
            0x39 => {
                try std.testing.expectEqual(@as(u8, 0x07), try r.readByte()); // creative flags
                _ = try r.readFloat(); // flying speed
                _ = try r.readFloat(); // walking speed
            },
            0x06 => {
                try std.testing.expectApproxEqAbs(@as(f32, 20.0), try r.readFloat(), 1e-6);
                try std.testing.expectEqual(@as(i16, 20), try r.readShort());
                _ = try r.readFloat(); // saturation
            },
            0x1F => {
                try std.testing.expectApproxEqAbs(@as(f32, 0.0), try r.readFloat(), 1e-9);
                _ = try r.readShort(); // level
                _ = try r.readShort(); // total xp
            },
            0x38 => {
                try std.testing.expectEqualStrings("Steve", try r.readString());
                try std.testing.expect(try r.readBool());
                _ = try r.readShort(); // ping
            },
            0x03 => {
                try std.testing.expectEqual(@as(i64, 24000), try r.readLong());
                try std.testing.expectEqual(@as(i64, 6000), try r.readLong());
            },
            else => unreachable,
        }
    }
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "queueTick cadence + timeout" {
    const a = std.testing.allocator;
    var c = Conn.init(a, std.testing.io, .{}, 1);
    defer c.deinit();
    c.state = .play;
    // t=0: time + keepalive
    try std.testing.expectEqual(Conn.TickAction.none, try c.queueTick(0, 0, 6000));
    {
        const out = try c.takeOutput();
        defer a.free(out);
        var r = codec.PacketReader.init(out);
        try std.testing.expectEqual(@as(i32, 0x03), (try codec.decodeFrame(&r)).id);
        _ = try r.readLong();
        _ = try r.readLong();
        try std.testing.expectEqual(@as(i32, 0x00), (try codec.decodeFrame(&r)).id);
        try std.testing.expect(c.keepalive_outstanding);
    }
    // t=500: nothing
    try std.testing.expectEqual(Conn.TickAction.none, try c.queueTick(500, 20, 6020));
    {
        const out = try c.takeOutput();
        defer a.free(out);
        try std.testing.expectEqual(@as(usize, 0), out.len);
    }
    // t=1000: time only (keepalive next due at 15000)
    try std.testing.expectEqual(Conn.TickAction.none, try c.queueTick(1000, 40, 6040));
    {
        const out = try c.takeOutput();
        defer a.free(out);
        var r = codec.PacketReader.init(out);
        try std.testing.expectEqual(@as(i32, 0x03), (try codec.decodeFrame(&r)).id);
        _ = try r.readLong();
        _ = try r.readLong();
        try std.testing.expectEqual(@as(usize, 0), r.remaining());
    }
    // no echo for 30s after the ping sent at t=0 -> timeout at t=31000
    try std.testing.expectEqual(Conn.TickAction.timeout, try c.queueTick(31001, 620, 6600));
    try std.testing.expect(c.dead);
    {
        const out = try c.takeOutput();
        defer a.free(out);
        var r = codec.PacketReader.init(out);
        try std.testing.expectEqual(@as(i32, 0x40), (try codec.decodeFrame(&r)).id);
    }
    // dead conns stay silent
    try std.testing.expectEqual(Conn.TickAction.none, try c.queueTick(999999, 0, 0));
    {
        const out = try c.takeOutput();
        defer a.free(out);
        try std.testing.expectEqual(@as(usize, 0), out.len);
    }
}

test "recent echo prevents kick, stale echo kicks" {
    const a = std.testing.allocator;
    var c = Conn.init(a, std.testing.io, .{}, 1);
    defer c.deinit();
    c.state = .play;
    try std.testing.expectEqual(Conn.TickAction.none, try c.queueTick(0, 0, 6000));
    {
        const drained = try c.takeOutput();
        defer a.free(drained);
    }
    // echo at t=10, then quiet: no kick at t=20000 (10s of silence)
    c.last_echo_ms = 10;
    c.keepalive_outstanding = false;
    try std.testing.expectEqual(Conn.TickAction.none, try c.queueTick(20000, 0, 0));
    try std.testing.expect(!c.dead);
    {
        const drained = try c.takeOutput();
        defer a.free(drained);
    }
    // ...but kicked once silence exceeds 30s
    try std.testing.expectEqual(Conn.TickAction.timeout, try c.queueTick(40000, 0, 0));
    try std.testing.expect(c.dead);
}

test "online login full handshake (mock Mojang)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var keys = try rsa_mod.ensureKeys(io, a, tmp.dir, "o_rsa.key", "o_rsa.der");
    defer keys.deinit();

    // mock session server: one-shot HTTP responder
    var port: u16 = 38131;
    const mock_json = "{\"id\":\"069a79f444e94726a5bef2a2fce1b293\",\"name\":\"Steve\"}";
    const Mock = struct {
        var json_body: []const u8 = "";
        var listen_port: u16 = 0;
        fn run(mock_io: std.Io) void {
            const addr = std.Io.net.IpAddress.parse("127.0.0.1", listen_port) catch return;
            var srv = addr.listen(mock_io, .{}) catch return;
            defer srv.deinit(mock_io);
            var stream = srv.accept(mock_io) catch return;
            defer stream.close(mock_io);
            var rbuf: [2048]u8 = undefined;
            var reader = stream.reader(mock_io, &rbuf);
            // read headers until \r\n\r\n
            var tail: [4]u8 = .{ 0, 0, 0, 0 };
            while (true) {
                const b = reader.interface.takeByte() catch return;
                tail[0] = tail[1];
                tail[1] = tail[2];
                tail[2] = tail[3];
                tail[3] = b;
                if (std.mem.eql(u8, &tail, "\r\n\r\n")) break;
            }
            var wbuf: [512]u8 = undefined;
            var writer = stream.writer(mock_io, &wbuf);
            writer.interface.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body }) catch return;
            writer.interface.flush() catch return;
        }
    };
    // find a free port by binding probe
    while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        var probe = addr.listen(io, .{}) catch {
            port += 1;
            if (port > 38230) return error.NoFreePort;
            continue;
        };
        probe.deinit(io);
        break;
    }
    Mock.json_body = mock_json;
    Mock.listen_port = port;
    const th = try std.Thread.spawn(.{}, Mock.run, .{io});
    errdefer th.join();

    var auth_url_buf: [64]u8 = undefined;
    const auth_url = try std.fmt.bufPrint(&auth_url_buf, "http://127.0.0.1:{d}/hasJoined", .{port});
    const cfg = Config{ .online_mode = true, .rsa = &keys, .auth_url = auth_url };
    var c = Conn.init(a, io, cfg, 9);
    defer c.deinit();

    // handshake(login) + login start
    var hb: [64]u8 = undefined;
    var w = codec.PacketWriter.init(&hb);
    try w.writeVarInt(5);
    try w.writeString("localhost");
    try w.writeUShort(25565);
    try w.writeVarInt(2);
    var hf: [80]u8 = undefined;
    try c.feedData(try codec.framePacket(0x00, w.written(), &hf));
    _ = try c.handleFrame((try c.poll()).?);
    var lb: [32]u8 = undefined;
    var wl = codec.PacketWriter.init(&lb);
    try wl.writeString("Steve");
    var lf: [48]u8 = undefined;
    try c.feedData(try codec.framePacket(0x00, wl.written(), &lf));
    _ = try c.handleFrame((try c.poll()).?);
    // server must have emitted EncryptionRequest and nothing else yet
    const enc_req_out = try c.takeOutput();
    defer a.free(enc_req_out);
    var r = codec.PacketReader.init(enc_req_out);
    const h = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 0x01), h.id);
    try std.testing.expectEqualStrings("", try r.readString());
    const pk_len = try r.readShort();
    try std.testing.expectEqual(@as(i16, @intCast(keys.public_key_der.len)), pk_len);
    try std.testing.expectEqualSlices(u8, keys.public_key_der, try r.readBytes(@intCast(pk_len)));
    const tok_len = try r.readShort();
    try std.testing.expectEqual(@as(i16, 4), tok_len);
    const token = try r.readBytes(4);
    try std.testing.expectEqualSlices(u8, &c.verify_token, token);

    // client side: encrypt secret + token with server pubkey
    const shared: [16]u8 = .{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160 };
    const enc_secret = try keys.encryptPkcs1v15(io, a, &shared);
    const enc_token = try keys.encryptPkcs1v15(io, a, token);
    var rb: [600]u8 = undefined;
    var wr = codec.PacketWriter.init(&rb);
    try wr.writeShort(@intCast(enc_secret.len));
    try wr.writeBytes(&enc_secret);
    try wr.writeShort(@intCast(enc_token.len));
    try wr.writeBytes(&enc_token);
    var rf: [640]u8 = undefined;
    try c.feedData(try codec.framePacket(0x01, wr.written(), &rf));
    const act = try c.handleFrame((try c.poll()).?);
    try std.testing.expectEqual(Action.entered_play, act);
    try std.testing.expect(c.state == .play);
    th.join();

    // output is encrypted now: decrypt client-side and check LoginSuccess
    const enc_out = try c.takeOutput();
    defer a.free(enc_out);
    var dec = cfb8.Cfb8.init(&shared);
    dec.decrypt(enc_out);
    var r2 = codec.PacketReader.init(enc_out);
    const lh = try codec.decodeFrame(&r2);
    try std.testing.expectEqual(@as(i32, 0x02), lh.id);
    try std.testing.expectEqualStrings("069a79f4-44e9-4726-a5be-f2a2fce1b293", try r2.readString());
    try std.testing.expectEqualStrings("Steve", try r2.readString());
}


