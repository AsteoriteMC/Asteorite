//! Permission model: op levels (0-4) + per-player node grants/denies.
//!
//! Shape (deliberately vanilla-inspired, not vanilla-identical):
//! - Every command declares a minimum op level (0 = everyone, 4 = owner)
//!   and a node (`asteorite.command.<name>`).
//! - A player's effective level is their explicit entry, else 0. Console
//!   is implicitly 4 and is never stored.
//! - Node check order: explicit DENY wins, then explicit GRANT, then
//!   `level >= cmd.level`. Denied and unknown commands produce the SAME
//!   reply so failures never oracle command existence.
//! - Identity is the player's UUID (36-char lowercase hyphenated form),
//!   keyed exactly (no folding: hex is already canonical). The stored
//!   `name` is display only (last seen at grant/load) and never matches.
//!   Name-keyed rows are a hijack vector (account renames free the old
//!   name for re-registration, which would inherit the row), so rows are
//!   UUID-bound at grant time and never rebound by name alone. In offline
//!   mode UUIDs derive deterministically from the name, so nothing changes
//!   there — UUID-keying only hardens online mode, where auth backs it.
//! - Nodes are `[a-z0-9_.-]` segments, 1..64 chars; a grant/deny ending
//!   in `.*` matches that prefix (`asteorite.command.*` covers all
//!   commands). Exact match otherwise.
//!
//! Storage: `ops.json` in the server directory (same dir as
//! `asteorite.toml` and the world DB), holding the whole matrix. The file
//! changes on human timescales (op/deop/grant/revoke, reload), so one small
//! file with last-writer-wins semantics is the right tradeoff; the caller
//! serializes encode vs write (see server.zig). Atomic tmp+rename writes
//! keep it crash-safe.

const std = @import("std");
const cmd_mod = @import("../../cmd/mod.zig");
// Vanilla 1.7.10 dedicated registration order (bl clinit), `perm` last
// (server extension, not a vanilla command).
const cmd_time = @import("../../cmd/time.zig");
const cmd_gamemode = @import("../../cmd/gamemode.zig");
const cmd_difficulty = @import("../../cmd/difficulty.zig");
const cmd_defaultgamemode = @import("../../cmd/defaultgamemode.zig");
const cmd_kill = @import("../../cmd/kill.zig");
const cmd_toggledownfall = @import("../../cmd/toggledownfall.zig");
const cmd_weather = @import("../../cmd/weather.zig");
const cmd_xp = @import("../../cmd/xp.zig");
const cmd_tp = @import("../../cmd/tp.zig");
const cmd_give = @import("../../cmd/give.zig");
const cmd_effect = @import("../../cmd/effect.zig");
const cmd_enchant = @import("../../cmd/enchant.zig");
const cmd_me = @import("../../cmd/me.zig");
const cmd_seed = @import("../../cmd/seed.zig");
const cmd_help = @import("../../cmd/help.zig");
const cmd_debug = @import("../../cmd/debug.zig");
const cmd_tell = @import("../../cmd/tell.zig");
const cmd_say = @import("../../cmd/say.zig");
const cmd_spawnpoint = @import("../../cmd/spawnpoint.zig");
const cmd_setworldspawn = @import("../../cmd/setworldspawn.zig");
const cmd_gamerule = @import("../../cmd/gamerule.zig");
const cmd_clear = @import("../../cmd/clear.zig");
const cmd_testfor = @import("../../cmd/testfor.zig");
const cmd_spreadplayers = @import("../../cmd/spreadplayers.zig");
const cmd_playsound = @import("../../cmd/playsound.zig");
const cmd_scoreboard = @import("../../cmd/scoreboard.zig");
const cmd_achievement = @import("../../cmd/achievement.zig");
const cmd_summon = @import("../../cmd/summon.zig");
const cmd_setblock = @import("../../cmd/setblock.zig");
const cmd_testforblock = @import("../../cmd/testforblock.zig");
const cmd_tellraw = @import("../../cmd/tellraw.zig");
const cmd_op = @import("../../cmd/op.zig");
const cmd_deop = @import("../../cmd/deop.zig");
const cmd_stop = @import("../../cmd/stop.zig");
const cmd_save_all = @import("../../cmd/save_all.zig");
const cmd_save_off = @import("../../cmd/save_off.zig");
const cmd_save_on = @import("../../cmd/save_on.zig");
const cmd_ban_ip = @import("../../cmd/ban_ip.zig");
const cmd_pardon_ip = @import("../../cmd/pardon_ip.zig");
const cmd_ban = @import("../../cmd/ban.zig");
const cmd_banlist = @import("../../cmd/banlist.zig");
const cmd_pardon = @import("../../cmd/pardon.zig");
const cmd_kick = @import("../../cmd/kick.zig");
const cmd_list = @import("../../cmd/list.zig");
const cmd_whitelist = @import("../../cmd/whitelist.zig");
const cmd_setidletimeout = @import("../../cmd/setidletimeout.zig");
const cmd_netstat = @import("../../cmd/netstat.zig");
const cmd_tps = @import("../../cmd/tps.zig");
const cmd_pregen = @import("../../cmd/pregen.zig");
const cmd_publish = @import("../../cmd/publish.zig");
const cmd_perm = @import("../../cmd/perm.zig");

/// Vanilla op ladder, shared with `cmd/mod.zig` (command defs gate on
/// rank, never on a raw int). Re-exported so server code has one path.
pub const OpLevel = cmd_mod.OpLevel;
pub const MAX_LEVEL: OpLevel = .owner;
pub const DEFAULT_LEVEL: OpLevel = .all;
pub const CONSOLE_LEVEL: OpLevel = .owner;

pub const magic = "ZPRM";
pub const version: u8 = 2;
pub const max_name_len = 16;
pub const max_node_len = 64;
/// Canonical UUID string length (8-4-4-4-12 lowercase hex).
pub const uuid_len: usize = 36;

/// Built-in command metadata. Levels follow a vanilla-inspired ladder
/// (0 everyone, 2 future gameplay cheats, 3 unused, 4 owner-only); only
/// 0 and 4 gate anything today. Nodes give fine-grained control now.
///
/// Single source of truth: each file under src/cmd/ owns its `def`
/// (validated at comptime by `cmd.define`); this table is generated from
/// those defs, so help text, permission checks, and dispatch can never
/// drift apart. To add a command: write src/cmd/<name>.zig and add it to
/// `modules` below (dispatch is registry-driven, one file per command).
pub const Command = cmd_mod.Command;

/// One module per command, in vanilla `/help` display order (the dedicated
/// manager's registration order). Server dispatch iterates this same list,
/// so there is exactly one place to update.
pub const modules = [_]type{
    cmd_time,
    cmd_gamemode,
    cmd_difficulty,
    cmd_defaultgamemode,
    cmd_kill,
    cmd_toggledownfall,
    cmd_weather,
    cmd_xp,
    cmd_tp,
    cmd_give,
    cmd_effect,
    cmd_enchant,
    cmd_me,
    cmd_seed,
    cmd_help,
    cmd_debug,
    cmd_tell,
    cmd_say,
    cmd_spawnpoint,
    cmd_setworldspawn,
    cmd_gamerule,
    cmd_clear,
    cmd_testfor,
    cmd_spreadplayers,
    cmd_playsound,
    cmd_scoreboard,
    cmd_achievement,
    cmd_summon,
    cmd_setblock,
    cmd_testforblock,
    cmd_tellraw,
    cmd_op,
    cmd_deop,
    cmd_stop,
    cmd_save_all,
    cmd_save_off,
    cmd_save_on,
    cmd_ban_ip,
    cmd_pardon_ip,
    cmd_ban,
    cmd_banlist,
    cmd_pardon,
    cmd_kick,
    cmd_list,
    cmd_whitelist,
    cmd_setidletimeout,
    cmd_netstat,
    cmd_tps,
    cmd_pregen,
    cmd_publish,
    cmd_perm,
};

/// One module per command, in /help display order. The server seeds its
/// runtime registry from this list once at boot; lookups never touch it
/// directly (see Server.ensureCommands — the runtime table is the single
/// source of truth, so modding-API commands show up everywhere).
pub const commands: [modules.len]Command = blk: {
    var table: [modules.len]Command = undefined;
    for (modules, 0..) |M, i| table[i] = M.def;
    break :blk table;
};

/// Player-name charset (matches login validation: alnum + underscore).
/// Names are display/resolution only — enforcement keys on UUIDs.
pub fn validPlayerName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// UUID shape: 8-4-4-4-12 hex with hyphens at 8/13/18/23 (case-insensitive;
/// stored lowercased — see normUuid).
pub fn validUuid(s: []const u8) bool {
    if (s.len != uuid_len) return false;
    for (s, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// Lowercase a validated UUID into `buf` (returns the 36-byte slice).
pub fn normUuid(s: []const u8, buf: *[uuid_len]u8) [uuid_len]u8 {
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf.*;
}

/// Node charset: dot-separated `[a-z0-9_-]` segments; optional trailing `.*`
/// wildcard. Rejects empty segments, leading/trailing dots, and anything
/// outside the alphabet (no spaces, no JSON metacharacters).
pub fn validNode(node: []const u8) bool {
    if (node.len == 0 or node.len > max_node_len) return false;
    var body = node;
    if (std.mem.endsWith(u8, body, ".*")) body = body[0 .. body.len - 2];
    if (body.len == 0) return false;
    var it = std.mem.splitScalar(u8, body, '.');
    while (it.next()) |seg| {
        if (seg.len == 0) return false;
        for (seg) |c| {
            if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_' and c != '-') return false;
        }
    }
    return true;
}

fn nodeMatches(pattern: []const u8, node: []const u8) bool {
    if (std.mem.eql(u8, pattern, node)) return true;
    if (std.mem.endsWith(u8, pattern, ".*")) {
        const prefix = pattern[0 .. pattern.len - 1]; // keeps the trailing dot
        return std.mem.startsWith(u8, node, prefix);
    }
    return false;
}

/// True when any node in `set` matches `node` (exact or `.*` prefix).
fn matchesAny(set: *const std.StringHashMap(void), node: []const u8) bool {
    var it = set.iterator();
    while (it.next()) |e| {
        if (nodeMatches(e.key_ptr.*, node)) return true;
    }
    return false;
}

/// Sort row/node names (deterministic bytes everywhere).
fn sortStrings(names: [][]const u8) void {
    std.mem.sort([]const u8, names, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
}

/// Collect every row UUID, sorted (deterministic encode order).
fn sortedUuids(alloc: std.mem.Allocator, db: *const Db) ![][uuid_len]u8 {
    const out = try alloc.alloc([uuid_len]u8, db.players.count());
    var k: usize = 0;
    var it = db.players.iterator();
    while (it.next()) |e| {
        std.mem.copyForwards(u8, &out[k], e.key_ptr.*[0..uuid_len]);
        k += 1;
    }
    std.mem.sort([uuid_len]u8, out, {}, struct {
        fn less(_: void, a: [uuid_len]u8, b: [uuid_len]u8) bool {
            return std.mem.lessThan(u8, &a, &b);
        }
    }.less);
    return out;
}

/// Free every owned key in a node set, then drop the set.
fn freeKeySet(alloc: std.mem.Allocator, set: *std.StringHashMap(void)) void {
    var it = set.iterator();
    while (it.next()) |e| alloc.free(e.key_ptr.*);
    set.deinit();
}

const PlayerPerms = struct {
    uuid: [uuid_len]u8, // canonical key (map key holds the same bytes)
    name: []u8, // owned display name (last seen; never matches)
    level: OpLevel, // explicit level (DEFAULT_LEVEL when only nodes exist)
    grants: std.StringHashMap(void), // owned node strings
    denies: std.StringHashMap(void),
};

pub const Db = struct {
    alloc: std.mem.Allocator,
    players: std.StringHashMap(*PlayerPerms),

    pub fn init(alloc: std.mem.Allocator) Db {
        return .{ .alloc = alloc, .players = std.StringHashMap(*PlayerPerms).init(alloc) };
    }

    pub fn deinit(self: *Db) void {
        var it = self.players.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            freePerms(self.alloc, e.value_ptr.*);
        }
        self.players.deinit();
    }

    fn getOrPutUuid(self: *Db, uuid: *const [uuid_len]u8, name: []const u8) !*PlayerPerms {
        if (self.players.get(uuid[0..])) |p| {
            // Refresh stale display names (renames): enforcement keys on
            // the UUID, so this is cosmetic only.
            if (!std.mem.eql(u8, p.name, name)) {
                const owned = try self.alloc.dupe(u8, name);
                self.alloc.free(p.name);
                p.name = owned;
            }
            return p;
        }
        const key = try self.alloc.dupe(u8, uuid[0..]);
        errdefer self.alloc.free(key);
        const owned_name = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(owned_name);
        const p = try self.alloc.create(PlayerPerms);
        errdefer self.alloc.destroy(p);
        p.* = .{
            .uuid = uuid.*,
            .name = owned_name,
            .level = DEFAULT_LEVEL,
            .grants = std.StringHashMap(void).init(self.alloc),
            .denies = std.StringHashMap(void).init(self.alloc),
        };
        try self.players.put(key, p);
        return p;
    }

    fn lookupUuid(self: *const Db, uuid: *const [uuid_len]u8) ?*PlayerPerms {
        return self.players.get(uuid[0..]);
    }

    /// Case-insensitive row lookup for display paths (`/perm show` resolves
    /// the name to a UUID first; this takes the resolved row key).
    /// Returns the stored row, if any.
    pub fn lookupRowUuid(self: *const Db, uuid: *const [uuid_len]u8) ?*PlayerPerms {
        return self.lookupUuid(uuid);
    }

    /// Explicit level, else DEFAULT_LEVEL. Console never reaches here.
    pub fn levelForUuid(self: *const Db, uuid: *const [uuid_len]u8) OpLevel {
        const p = self.lookupUuid(uuid) orelse return DEFAULT_LEVEL;
        return p.level;
    }

    /// Set an explicit level. Level .all with no nodes removes the row.
    pub fn setLevelUuid(self: *Db, uuid: *const [uuid_len]u8, name: []const u8, level: OpLevel) !void {
        const p = try self.getOrPutUuid(uuid, name);
        p.level = level;
        try self.gc(uuid);
    }

    /// Full reset (deop): level 0 and all nodes dropped.
    pub fn clearUuid(self: *Db, uuid: *const [uuid_len]u8) void {
        if (self.players.fetchRemove(uuid[0..])) |kv| {
            self.alloc.free(kv.key);
            freePerms(self.alloc, kv.value);
        }
    }

    pub fn grantUuid(self: *Db, uuid: *const [uuid_len]u8, name: []const u8, node: []const u8) !void {
        std.debug.assert(validNode(node));
        const p = try self.getOrPutUuid(uuid, name);
        try setNode(self.alloc, &p.denies, &p.grants, node);
    }

    pub fn denyUuid(self: *Db, uuid: *const [uuid_len]u8, name: []const u8, node: []const u8) !void {
        std.debug.assert(validNode(node));
        const p = try self.getOrPutUuid(uuid, name);
        try setNode(self.alloc, &p.grants, &p.denies, node);
    }

    /// Move `node` into `dst`, removing it from `src` (grant/deny are
    /// exclusive: setting one clears the other).
    fn setNode(alloc: std.mem.Allocator, src: *std.StringHashMap(void), dst: *std.StringHashMap(void), node: []const u8) !void {
        if (src.fetchRemove(node)) |kv| alloc.free(kv.key);
        if (dst.contains(node)) return;
        const owned = try alloc.dupe(u8, node);
        errdefer alloc.free(owned);
        try dst.put(owned, {});
    }

    /// Remove a node from both sets (returns true when something changed).
    pub fn clearNodeUuid(self: *Db, uuid: *const [uuid_len]u8, node: []const u8) !bool {
        const p = self.lookupUuid(uuid) orelse return false;
        var changed = false;
        if (p.grants.fetchRemove(node)) |kv| {
            self.alloc.free(kv.key);
            changed = true;
        }
        if (p.denies.fetchRemove(node)) |kv| {
            self.alloc.free(kv.key);
            changed = true;
        }
        try self.gc(uuid);
        return changed;
    }

    fn gc(self: *Db, uuid: *const [uuid_len]u8) !void {
        const p = self.lookupUuid(uuid) orelse return;
        if (p.level == DEFAULT_LEVEL and p.grants.count() == 0 and p.denies.count() == 0) {
            self.clearUuid(&p.uuid);
        }
    }

    /// Decision core: deny-match wins, then grant-match, then level gate.
    /// `sender_level` is CONSOLE_LEVEL for console, else levelForUuid(uuid).
    pub fn allowsUuid(self: *const Db, uuid: *const [uuid_len]u8, node: []const u8, min_level: OpLevel) bool {
        const need = min_level.rank();
        const p = self.lookupUuid(uuid) orelse return DEFAULT_LEVEL.rank() >= need;
        if (matchesAny(&p.denies, node)) return false;
        if (matchesAny(&p.grants, node)) return true;
        return p.level.rank() >= need;
    }

    pub fn countOps(self: *const Db) usize {
        var n: usize = 0;
        var it = self.players.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.*.level != .all) n += 1;
        }
        return n;
    }
};

fn freePerms(alloc: std.mem.Allocator, p: *PlayerPerms) void {
    // Map key (freed by the caller) holds the UUID bytes; the display
    // name is owned separately here.
    alloc.free(p.name);
    freeKeySet(alloc, &p.grants);
    freeKeySet(alloc, &p.denies);
    alloc.destroy(p);
}

pub const DbError = error{CorruptPerms} || std.mem.Allocator.Error;

pub fn encode(alloc: std.mem.Allocator, db: *const Db) ![]u8 {
    var n: usize = 4 + 1 + 2;
    var it = db.players.iterator();
    while (it.next()) |e| {
        const p = e.value_ptr.*;
        n += uuid_len + 1 + p.name.len + 1 + 2 + 2; // uuid + name + level + ngrants + ndenies
        var gi = p.grants.iterator();
        while (gi.next()) |g| n += 2 + g.key_ptr.len;
        var di = p.denies.iterator();
        while (di.next()) |g| n += 2 + g.key_ptr.len;
    }
    const out = try alloc.alloc(u8, n);
    errdefer alloc.free(out);
    var i: usize = 0;
    @memcpy(out[i..][0..4], magic);
    i += 4;
    out[i] = version;
    i += 1;
    // Canonical order (sorted by UUID) so bytes are deterministic.
    const uuids = try sortedUuids(alloc, db);
    defer alloc.free(uuids);
    std.mem.writeInt(u16, out[i..][0..2], @intCast(uuids.len), .big);
    i += 2;
    for (uuids) |u| {
        const p = db.players.get(u[0..]).?;
        @memcpy(out[i..][0..uuid_len], u[0..]);
        i += uuid_len;
        out[i] = @intCast(p.name.len);
        i += 1;
        @memcpy(out[i..][0..p.name.len], p.name);
        i += p.name.len;
        out[i] = p.level.rank();
        i += 1;
        const gkeys = try sortedKeys(alloc, &p.grants);
        defer alloc.free(gkeys);
        i = writeKeyBlock(out, i, gkeys);
        const dkeys = try sortedKeys(alloc, &p.denies);
        defer alloc.free(dkeys);
        i = writeKeyBlock(out, i, dkeys);
    }
    std.debug.assert(i == n);
    return out;
}

/// Write one node set: u16 count, then u16-len + bytes per node.
/// Returns the next offset.
fn writeKeyBlock(out: []u8, i: usize, keys: [][]const u8) usize {
    var o = i;
    std.mem.writeInt(u16, out[o..][0..2], @intCast(keys.len), .big);
    o += 2;
    for (keys) |g| {
        std.mem.writeInt(u16, out[o..][0..2], @intCast(g.len), .big);
        o += 2;
        @memcpy(out[o..][0..g.len], g);
        o += g.len;
    }
    return o;
}

fn sortedKeys(alloc: std.mem.Allocator, set: *const std.StringHashMap(void)) ![][]const u8 {
    const out = try alloc.alloc([]const u8, set.count());
    var i: usize = 0;
    var it = set.iterator();
    while (it.next()) |e| {
        out[i] = e.key_ptr.*;
        i += 1;
    }
    sortStrings(out);
    return out;
}

/// Take `n` bytes from the decode cursor (bounds-checked).
fn takeBytes(b: *[]const u8, n: usize) error{CorruptPerms}![]const u8 {
    if (b.len < n) return error.CorruptPerms;
    const s = b.*[0..n];
    b.* = b.*[n..];
    return s;
}

/// Decode one node set (u16 count, then u16-len + bytes each): validated,
/// duplicate-free, and disjoint from `other` when given.
fn readNodeSet(r: *[]const u8, alloc: std.mem.Allocator, set: *std.StringHashMap(void), other: ?*const std.StringHashMap(void)) DbError!void {
    const n = std.mem.readInt(u16, (try takeBytes(r, 2))[0..2], .big);
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const nl = std.mem.readInt(u16, (try takeBytes(r, 2))[0..2], .big);
        if (nl == 0 or nl > max_node_len) return error.CorruptPerms;
        const node = try takeBytes(r, nl);
        if (!validNode(node)) return error.CorruptPerms;
        if (set.contains(node)) return error.CorruptPerms;
        if (other) |o| {
            if (o.contains(node)) return error.CorruptPerms;
        }
        const owned = try alloc.dupe(u8, node);
        errdefer alloc.free(owned);
        try set.put(owned, {});
    }
}

pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) DbError!Db {
    var db = Db.init(alloc);
    errdefer db.deinit();
    var r = bytes;
    const take = takeBytes;
    if (!std.mem.eql(u8, try take(&r, 4), magic)) return error.CorruptPerms;
    // v1 rows were name-keyed (hijackable via renames): fail closed and
    // force re-creation under UUIDs rather than misreading the bytes.
    if ((try take(&r, 1))[0] != version) return error.CorruptPerms;
    const count = std.mem.readInt(u16, (try take(&r, 2))[0..2], .big);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const ubytes = try take(&r, uuid_len);
        if (!validUuid(ubytes)) return error.CorruptPerms;
        var ubuf: [uuid_len]u8 = undefined;
        const uuid = normUuid(ubytes, &ubuf);
        if (db.players.contains(uuid[0..])) return error.CorruptPerms;
        const ulen: usize = (try take(&r, 1))[0];
        if (ulen == 0 or ulen > max_name_len) return error.CorruptPerms;
        const name = try take(&r, ulen);
        if (!validPlayerName(name)) return error.CorruptPerms;
        const level = (try take(&r, 1))[0];
        if (level > MAX_LEVEL.rank()) return error.CorruptPerms;
        const p = try db.getOrPutUuid(&uuid, name);
        p.level = @enumFromInt(level);
        try readNodeSet(&r, alloc, &p.grants, null);
        try readNodeSet(&r, alloc, &p.denies, &p.grants);
    }
    if (r.len != 0) return error.CorruptPerms;
    // Drop empty rows (level 0 + no nodes) to keep the invariant that
    // setLevelUuid's gc maintains. Loops: crafted files may hold several.
    while (findEmptyRow(&db)) |k| db.clearUuid(k);
    return db;
}

/// One empty row UUID (level 0 + no nodes), if any.
fn findEmptyRow(db: *Db) ?*const [uuid_len]u8 {
    var it = db.players.iterator();
    while (it.next()) |e| {
        const p = e.value_ptr.*;
        if (p.level == DEFAULT_LEVEL and p.grants.count() == 0 and p.denies.count() == 0) {
            return &p.uuid;
        }
    }
    return null;
}

/// File persistence (`ops.json` in the server directory). Vanilla keeps
/// ops in ops.json next to the world, not inside it — same here.
pub const ops_file = "ops.json";
const ops_tmp = "ops.json.tmp";

const OpsEntry = struct {
    uuid: []const u8 = "",
    name: []const u8,
    level: u8 = 0,
    grant: []const []const u8 = &.{},
    deny: []const []const u8 = &.{},
};

/// Whole matrix as JSON (rows + nodes sorted, so bytes are deterministic).
/// Shape mirrors vanilla ops.json (`uuid` hyphenated + `name`), with
/// `grant`/`deny` arrays as the server extension.
pub fn encodeJson(alloc: std.mem.Allocator, db: *const Db) ![]u8 {
    const uuids = try sortedUuids(alloc, db);
    defer alloc.free(uuids);
    const entries = try alloc.alloc(OpsEntry, uuids.len);
    defer alloc.free(entries);
    for (uuids, 0..) |u, i| {
        const p = db.players.get(u[0..]).?;
        const gkeys = try sortedKeys(alloc, &p.grants);
        defer alloc.free(gkeys);
        const dkeys = try sortedKeys(alloc, &p.denies);
        defer alloc.free(dkeys);
        const grants = try alloc.dupe([]const u8, gkeys);
        errdefer alloc.free(grants);
        const denies = try alloc.dupe([]const u8, dkeys);
        errdefer alloc.free(denies);
        // Slice the sorted backing array (lives through valueAlloc below),
        // not the loop-local copy.
        entries[i] = .{ .uuid = uuids[i][0..], .name = p.name, .level = p.level.rank(), .grant = grants, .deny = denies };
    }
    defer {
        for (entries) |e| {
            alloc.free(e.grant);
            alloc.free(e.deny);
        }
    }
    return try std.json.Stringify.valueAlloc(alloc, entries, .{ .emit_null_optional_fields = false });
}

/// Validate + insert a JSON node list into `set` (rejects overlap with
/// `other` and internal duplicates — same rules as the binary form).
fn putNodes(alloc: std.mem.Allocator, nodes: []const []const u8, set: *std.StringHashMap(void), other: *const std.StringHashMap(void)) DbError!void {
    for (nodes) |node| {
        if (!validNode(node)) return error.CorruptPerms;
        if (set.contains(node) or other.contains(node)) return error.CorruptPerms;
        const owned = try alloc.dupe(u8, node);
        set.put(owned, {}) catch |err| {
            alloc.free(owned);
            return err;
        };
    }
}

/// Inverse of encodeJson. Unknown fields are ignored; everything else is
/// validated exactly like the binary form (uuids, names, levels, nodes).
/// Rows WITHOUT a uuid are pre-UUID legacy rows: skipped and counted
/// (never name-matched — a recycled account name would inherit the row).
/// Callers must warn on skipped_legacy so admins re-op affected players.
pub const DecodedJson = struct {
    db: Db,
    skipped_legacy: usize,
};

pub fn decodeJson(alloc: std.mem.Allocator, bytes: []const u8) DbError!DecodedJson {
    const parsed = std.json.parseFromSlice([]const OpsEntry, alloc, bytes, .{ .ignore_unknown_fields = true }) catch return error.CorruptPerms;
    defer parsed.deinit();
    var db = Db.init(alloc);
    errdefer db.deinit();
    var skipped: usize = 0;
    for (parsed.value) |e| {
        if (e.uuid.len == 0) {
            // Legacy name-only row: dead weight (name ignored entirely,
            // not even validated) — counted for the caller's warning.
            skipped += 1;
            continue;
        }
        if (!validUuid(e.uuid)) return error.CorruptPerms;
        if (!validPlayerName(e.name)) return error.CorruptPerms;
        if (e.level > MAX_LEVEL.rank()) return error.CorruptPerms;
        var ubuf: [uuid_len]u8 = undefined;
        const uuid = normUuid(e.uuid, &ubuf);
        if (db.players.contains(uuid[0..])) return error.CorruptPerms;
        const p = try db.getOrPutUuid(&uuid, e.name);
        p.level = @enumFromInt(e.level);
        try putNodes(alloc, e.grant, &p.grants, &p.denies);
        try putNodes(alloc, e.deny, &p.denies, &p.grants);
        try db.gc(&uuid);
    }
    return .{ .db = db, .skipped_legacy = skipped };
}

/// Write bytes to `tmp_name` (sync) then rename onto `final_name`.
/// Crash-safe: observers only ever see the old or the new file.
fn writeFileAtomic(io: std.Io, dir: std.Io.Dir, tmp_name: []const u8, final_name: []const u8, bytes: []const u8) !void {
    var f = try dir.createFile(io, tmp_name, .{ .read = false, .truncate = true });
    errdefer {
        f.close(io);
        dir.deleteFile(io, tmp_name) catch {};
    }
    try f.writePositionalAll(io, bytes, 0);
    try f.sync(io);
    f.close(io);
    try dir.rename(tmp_name, dir, final_name, io);
}

/// Persist the matrix to `ops.json` (atomic replace). No world needed.
pub fn saveFile(io: std.Io, dir: std.Io.Dir, alloc: std.mem.Allocator, db: *const Db) !void {
    const enc = try encodeJson(alloc, db);
    defer alloc.free(enc);
    try writeFileAtomic(io, dir, ops_tmp, ops_file, enc);
}

/// Raw-bytes half of saveFile (atomic replace). The server encodes under
/// perm_lock, then calls this after unlocking so disk IO never holds it.
pub fn writeOpsFile(io: std.Io, dir: std.Io.Dir, bytes: []const u8) !void {
    try writeFileAtomic(io, dir, ops_tmp, ops_file, bytes);
}

/// Load `ops.json`. Null when the file is absent (caller falls back to the
/// legacy DB row); corrupt files fail closed like corrupt rows do.
/// Legacy name-only rows are skipped (counted in `skipped_legacy`) — the
/// caller must warn so admins re-op affected players under UUIDs.
pub fn loadFile(io: std.Io, dir: std.Io.Dir, alloc: std.mem.Allocator) !?DecodedJson {
    const raw = dir.readFileAlloc(io, ops_file, alloc, .limited(1 << 20)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer alloc.free(raw);
    return try decodeJson(alloc, raw);
}

/// Distinct test UUIDs (last byte varies; shape-valid lowercase).
fn tu(n: u8) [36]u8 {
    var out: [36]u8 = "00000000-0000-4000-8000-000000000000".*;
    out[34] = "0123456789abcdef"[n >> 4];
    out[35] = "0123456789abcdef"[n & 0xF];
    return out;
}

test "levels + grants + denies + wildcards" {
    const a = std.testing.allocator;
    var db = Db.init(a);
    defer db.deinit();
    const steve = tu(1);
    const bob = tu(2);
    // default deny
    try std.testing.expect(!db.allowsUuid(&steve, "asteorite.command.save-all", .owner));
    try std.testing.expect(db.allowsUuid(&steve, "asteorite.command.list", .all));
    // op level
    try db.setLevelUuid(&steve, "Steve", .owner);
    try std.testing.expect(db.allowsUuid(&steve, "asteorite.command.save-all", .owner));
    // deny beats level
    try db.denyUuid(&steve, "Steve", "asteorite.command.save-all");
    try std.testing.expect(!db.allowsUuid(&steve, "asteorite.command.save-all", .owner));
    try std.testing.expect(db.allowsUuid(&steve, "asteorite.command.list", .all));
    // grant beats level-gate for a low player
    try db.grantUuid(&bob, "Bob", "asteorite.command.save-all");
    try std.testing.expect(db.allowsUuid(&bob, "asteorite.command.save-all", .owner));
    // wildcard grant
    try db.grantUuid(&bob, "Bob", "asteorite.command.*");
    try std.testing.expect(db.allowsUuid(&bob, "asteorite.command.op", .owner));
    // wildcard does not cross the dot boundary
    try std.testing.expect(!db.allowsUuid(&bob, "asteorite.cmd", .owner));
    // exact deny inside a granted wildcard still wins
    try db.denyUuid(&bob, "Bob", "asteorite.command.stop");
    try std.testing.expect(!db.allowsUuid(&bob, "asteorite.command.stop", .all));
    // clearNode restores level behavior
    try std.testing.expect(try db.clearNodeUuid(&bob, "asteorite.command.stop"));
    try std.testing.expect(db.allowsUuid(&bob, "asteorite.command.stop", .all));
    // deop resets everything
    db.clearUuid(&steve);
    try std.testing.expect(!db.allowsUuid(&steve, "asteorite.command.save-all", .owner));
    try std.testing.expect(db.levelForUuid(&bob) == .all);
}

test "identity is the UUID, never the name" {
    const a = std.testing.allocator;
    var db = Db.init(a);
    defer db.deinit();
    const alice = tu(3);
    // Same UUID under a renamed display: one row, still opped (this is
    // the whole point — renames must not drop grants).
    try db.setLevelUuid(&alice, "Alice", .owner);
    try std.testing.expectEqual(OpLevel.owner, db.levelForUuid(&alice));
    try db.setLevelUuid(&alice, "Alicia", .owner);
    try std.testing.expectEqual(OpLevel.owner, db.levelForUuid(&alice));
    try std.testing.expectEqual(@as(usize, 1), db.players.count());
    // A different UUID never matches, even with the same display name
    // (this is the recycled-name hijack the UUID keying kills).
    const impostor = tu(4);
    try std.testing.expect(!db.allowsUuid(&impostor, "asteorite.command.save-all", .owner));
    try std.testing.expectEqual(OpLevel.all, db.levelForUuid(&impostor));
    // Unknown UUIDs fall back to default level, same as unknown names did.
    const stranger = tu(5);
    try std.testing.expect(db.allowsUuid(&stranger, "asteorite.command.list", .all));
}

test "node + uuid validation" {
    try std.testing.expect(validNode("asteorite.command.list"));
    try std.testing.expect(validNode("asteorite.command.*"));
    try std.testing.expect(validNode("a"));
    try std.testing.expect(!validNode(""));
    try std.testing.expect(!validNode("UPPER"));
    try std.testing.expect(!validNode("has space"));
    try std.testing.expect(!validNode(".leading"));
    try std.testing.expect(!validNode("trailing."));
    try std.testing.expect(!validNode("double..dot"));
    try std.testing.expect(!validNode(".*"));
    try std.testing.expect(!validNode("a.*.b"));
    try std.testing.expect(!validPlayerName("Steve!"));
    try std.testing.expect(!validPlayerName(""));
    try std.testing.expect(!validPlayerName("has space"));
    try std.testing.expect(!validPlayerName("0123456789abcdefg")); // 17 chars
    try std.testing.expect(validUuid("00000000-0000-4000-8000-000000000000"));
    try std.testing.expect(validUuid("b50ad385-829d-3141-a216-7e7d7539ba7f"));
    try std.testing.expect(validUuid("B50AD385-829D-3141-A216-7E7D7539BA7F")); // case-insensitive
    try std.testing.expect(!validUuid(""));
    try std.testing.expect(!validUuid("steve"));
    try std.testing.expect(!validUuid("00000000-0000-4000-8000-00000000000")); // 35 chars
    try std.testing.expect(!validUuid("00000000_0000_4000_8000_000000000000")); // no hyphens
    try std.testing.expect(!validUuid("g0000000-0000-4000-8000-000000000000")); // non-hex
    var ubuf: [uuid_len]u8 = undefined;
    try std.testing.expectEqualStrings("b50ad385-829d-3141-a216-7e7d7539ba7f", normUuid("B50AD385-829D-3141-A216-7E7D7539BA7F", &ubuf)[0..]);
}

test "perms roundtrip incl empty + corrupt rejection" {
    const a = std.testing.allocator;
    var db = Db.init(a);
    defer db.deinit();
    const steve = tu(1);
    const bob = tu(2);
    const al = tu(3);
    try db.setLevelUuid(&steve, "Steve", .owner);
    try db.grantUuid(&bob, "Bob", "asteorite.command.save-all");
    try db.denyUuid(&bob, "Bob", "asteorite.command.stop");
    try db.grantUuid(&al, "Al", "asteorite.*");
    const enc = try encode(a, &db);
    defer a.free(enc);
    var back = try decode(a, enc);
    defer back.deinit();
    try std.testing.expectEqual(OpLevel.owner, back.levelForUuid(&steve));
    try std.testing.expect(back.allowsUuid(&bob, "asteorite.command.save-all", .owner));
    try std.testing.expect(!back.allowsUuid(&bob, "asteorite.command.stop", .owner));
    try std.testing.expect(back.allowsUuid(&al, "asteorite.command.stop", .owner));
    try std.testing.expect(!back.allowsUuid(&al, "other.tree", .owner));
    // display names survive the roundtrip too
    try std.testing.expectEqualStrings("Steve", back.lookupRowUuid(&steve).?.name);
    // deterministic bytes (sorted rows + nodes)
    const enc2 = try encode(a, &back);
    defer a.free(enc2);
    try std.testing.expectEqualSlices(u8, enc, enc2);
    // empty db roundtrips
    var empty = Db.init(a);
    defer empty.deinit();
    const ee = try encode(a, &empty);
    defer a.free(ee);
    var back2 = try decode(a, ee);
    defer back2.deinit();
    try std.testing.expectEqual(@as(usize, 0), back2.players.count());
    // v1 (name-keyed) bytes are rejected, not misread
    {
        const v1 = [_]u8{ 'Z', 'P', 'R', 'M', 1, 0, 0 };
        var r_v1 = decode(a, &v1);
        if (r_v1) |*bad| {
            bad.deinit();
            try std.testing.expect(false);
        } else |err| {
            try std.testing.expect(err == error.CorruptPerms);
        }
    }
    // corruptions rejected
    {
        const mut = try a.dupe(u8, enc);
        defer a.free(mut);
        mut[0] = 'X';
        var r_mut = decode(a, mut);
        if (r_mut) |*bad| {
            bad.deinit();
            try std.testing.expect(false);
        } else |err| {
            try std.testing.expect(err == error.CorruptPerms);
        }
    }
    {
        const trunc = enc[0 .. enc.len - 2];
        var r_trunc = decode(a, trunc);
        if (r_trunc) |*bad| {
            bad.deinit();
            try std.testing.expect(false);
        } else |err| {
            try std.testing.expect(err == error.CorruptPerms);
        }
    }
    {
        const grown = try a.alloc(u8, enc.len + 1);
        defer a.free(grown);
        @memcpy(grown[0..enc.len], enc);
        grown[enc.len] = 0;
        var r_grown = decode(a, grown);
        if (r_grown) |*bad| {
            bad.deinit();
            try std.testing.expect(false);
        } else |err| {
            try std.testing.expect(err == error.CorruptPerms);
        }
    }
}

test "ops.json roundtrip incl legacy skip + corrupt rejection" {
    const a = std.testing.allocator;
    var db = Db.init(a);
    defer db.deinit();
    const steve = tu(1);
    const bob = tu(2);
    try db.setLevelUuid(&steve, "Steve", .owner);
    try db.grantUuid(&bob, "Bob", "asteorite.command.save-all");
    try db.denyUuid(&bob, "Bob", "asteorite.command.stop");
    const enc = try encodeJson(a, &db);
    defer a.free(enc);
    var back = try decodeJson(a, enc);
    defer back.db.deinit();
    try std.testing.expectEqual(@as(usize, 0), back.skipped_legacy);
    try std.testing.expectEqual(OpLevel.owner, back.db.levelForUuid(&steve));
    try std.testing.expect(back.db.allowsUuid(&bob, "asteorite.command.save-all", .owner));
    try std.testing.expect(!back.db.allowsUuid(&bob, "asteorite.command.stop", .owner));
    // deterministic bytes (sorted rows + nodes)
    const enc2 = try encodeJson(a, &back.db);
    defer a.free(enc2);
    try std.testing.expectEqualSlices(u8, enc, enc2);
    // missing grant/deny arrays decode as empty; unknown fields ignored
    var lax = try decodeJson(a,
        \\[{"uuid":"00000000-0000-4000-8000-00000000000a","name":"Al"}]
    );
    defer lax.db.deinit();
    try std.testing.expectEqual(@as(usize, 0), lax.skipped_legacy);
    try std.testing.expectEqual(OpLevel.all, lax.db.levelForUuid(&tu(0x0a)));
    var lax2 = try decodeJson(a,
        \\[{"uuid":"00000000-0000-4000-8000-00000000000b","name":"Bo","level":2,"grant":[],"deny":[],"extra":1}]
    );
    defer lax2.db.deinit();
    try std.testing.expectEqual(OpLevel.gamemaster, lax2.db.levelForUuid(&tu(0x0b)));
    // legacy name-only rows are skipped (counted), never matched: a file
    // mixing a legacy row with a live UUID row keeps the live one only.
    var mixed = try decodeJson(a,
        \\[{"name":"OldSteve","level":4},{"uuid":"00000000-0000-4000-8000-00000000000c","name":"Newbie","level":4}]
    );
    defer mixed.db.deinit();
    try std.testing.expectEqual(@as(usize, 1), mixed.skipped_legacy);
    try std.testing.expectEqual(@as(usize, 1), mixed.db.players.count());
    try std.testing.expectEqual(OpLevel.owner, mixed.db.levelForUuid(&tu(0x0c)));
    // corrupt inputs rejected (malformed uuid joins them; a bare name is
    // legacy-skip only when the row is otherwise lax-decodable)
    for ([_][]const u8{
        "not json",
        "[",
        "{}",
        "[{\"uuid\":\"steve\",\"name\":\"Steve\",\"level\":4}]",
        "[{\"uuid\":\"00000000-0000-4000-8000-00000000000\",\"name\":\"Steve\",\"level\":4}]",
        "[{\"uuid\":\"00000000-0000-4000-8000-00000000000c\",\"name\":\"\",\"level\":4}]",
        "[{\"uuid\":\"00000000-0000-4000-8000-00000000000c\",\"name\":\"0123456789abcdefg\",\"level\":4}]",
        "[{\"uuid\":\"00000000-0000-4000-8000-00000000000c\",\"name\":\"Steve!\",\"level\":4}]",
        "[{\"uuid\":\"00000000-0000-4000-8000-00000000000c\",\"name\":\"Steve\",\"level\":5}]",
        "[{\"uuid\":\"00000000-0000-4000-8000-00000000000c\",\"name\":\"Steve\",\"level\":-1}]",
        "[{\"uuid\":\"00000000-0000-4000-8000-00000000000c\",\"name\":\"Steve\",\"grant\":[\"UPPER\"]}]",
        "[{\"uuid\":\"00000000-0000-4000-8000-00000000000c\",\"name\":\"Steve\",\"deny\":[\"ok\",\"ok\"]}]",
        "[{\"uuid\":\"00000000-0000-4000-8000-00000000000c\",\"name\":\"a\",\"level\":1},{\"uuid\":\"00000000-0000-4000-8000-00000000000c\",\"name\":\"A\",\"level\":2}]",
    }) |bad| {
        var r = decodeJson(a, bad);
        if (r) |*b| {
            b.db.deinit();
            try std.testing.expect(false);
        } else |err| {
            try std.testing.expect(err == error.CorruptPerms);
        }
    }
}

test "ops.json file roundtrip" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = Db.init(a);
    defer db.deinit();
    const steve = tu(1);
    const bob = tu(2);
    try db.setLevelUuid(&steve, "Steve", .owner);
    try db.grantUuid(&bob, "Bob", "asteorite.command.list");
    try saveFile(io, tmp.dir, a, &db);
    var loaded = (try loadFile(io, tmp.dir, a)).?;
    defer loaded.db.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.skipped_legacy);
    try std.testing.expectEqual(OpLevel.owner, loaded.db.levelForUuid(&steve));
    try std.testing.expect(loaded.db.allowsUuid(&bob, "asteorite.command.list", .owner));
    // missing file reads as absent (caller migrates from the DB row)
    try tmp.dir.deleteFile(io, ops_file);
    try std.testing.expect(try loadFile(io, tmp.dir, a) == null);
}
