//! Permission model: op levels (0-4) + per-player node grants/denies.
//!
//! Shape (deliberately vanilla-inspired, not vanilla-identical):
//! - Every command declares a minimum op level (0 = everyone, 4 = owner)
//!   and a node (`zigcraft.command.<name>`).
//! - A player's effective level is their explicit entry, else 0. Console
//!   is implicitly 4 and is never stored.
//! - Node check order: explicit DENY wins, then explicit GRANT, then
//!   `level >= cmd.level`. Denied and unknown commands produce the SAME
//!   reply so failures never oracle command existence.
//! - Identity is the exact login username bytes (case-sensitive, matching
//!   offline-UUID derivation and the player-row scheme). "Steve" and
//!   "steve" are different players.
//! - Nodes are `[a-z0-9_.-]` segments, 1..64 chars; a grant/deny ending
//!   in `.*` matches that prefix (`zigcraft.command.*` covers all
//!   commands). Exact match otherwise.
//!
//! Storage: one LSM row (`encodeKey(254, 0, 0)`) holding the whole matrix
//! ("ZPRM" v1). The DB changes on human timescales (op/deop/grant/revoke,
//! reload), so a single small row with last-writer-wins semantics is the
//! right tradeoff; the caller serializes encode vs put (see server.zig).
//! Durability comes from the WAL like everything else.

const std = @import("std");
const store_mod = @import("../world/store.zig");
const shard_mod = @import("../world/shard.zig");

pub const MAX_LEVEL: u8 = 4;
pub const DEFAULT_LEVEL: u8 = 0;
pub const CONSOLE_LEVEL: u8 = 4;

pub const perm_dim: u8 = 254;
pub const perm_key = store_mod.encodeKey(perm_dim, 0, 0);
pub const magic = "ZPRM";
pub const version: u8 = 1;
pub const max_name_len = 16;
pub const max_node_len = 64;

/// Built-in command metadata. Levels follow a vanilla-inspired ladder
/// (0 everyone, 2 future gameplay cheats, 3 unused, 4 owner-only); only
/// 0 and 4 gate anything today. Nodes give fine-grained control now.
pub const Command = struct {
    name: []const u8,
    node: []const u8,
    min_level: u8,
    usage: []const u8,
};

pub const commands = [_]Command{
    .{ .name = "help", .node = "zigcraft.command.help", .min_level = 0, .usage = "/help" },
    .{ .name = "list", .node = "zigcraft.command.list", .min_level = 0, .usage = "/list" },
    .{ .name = "save-all", .node = "zigcraft.command.save-all", .min_level = 4, .usage = "/save-all" },
    .{ .name = "op", .node = "zigcraft.command.op", .min_level = 4, .usage = "/op <player>" },
    .{ .name = "deop", .node = "zigcraft.command.deop", .min_level = 4, .usage = "/deop <player>" },
    .{ .name = "perm", .node = "zigcraft.command.perm", .min_level = 4, .usage = "/perm <grant|deny|clear|show|reload> [player] [node]" },
};

pub fn findCommand(name: []const u8) ?*const Command {
    for (&commands) |*c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

/// Player-name charset (matches login validation: alnum + underscore).
pub fn validPlayerName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
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

const PlayerPerms = struct {
    name: []u8, // owned exact-case username
    level: u8, // explicit level (DEFAULT_LEVEL when only nodes exist)
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

    fn getOrPut(self: *Db, name: []const u8) !*PlayerPerms {
        if (self.players.get(name)) |p| return p;
        const key = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(key);
        const p = try self.alloc.create(PlayerPerms);
        errdefer self.alloc.destroy(p);
        p.* = .{
            .name = key,
            .level = DEFAULT_LEVEL,
            .grants = std.StringHashMap(void).init(self.alloc),
            .denies = std.StringHashMap(void).init(self.alloc),
        };
        try self.players.put(key, p);
        return p;
    }

    /// Explicit level, else DEFAULT_LEVEL. Console never reaches here.
    pub fn levelFor(self: *const Db, name: []const u8) u8 {
        const p = self.players.get(name) orelse return DEFAULT_LEVEL;
        return p.level;
    }

    /// Set an explicit level (0-4). Level 0 with no nodes removes the row.
    pub fn setLevel(self: *Db, name: []const u8, level: u8) !void {
        std.debug.assert(level <= MAX_LEVEL);
        const p = try self.getOrPut(name);
        p.level = level;
        try self.gc(name);
    }

    /// Full reset (deop): level 0 and all nodes dropped.
    pub fn clearPlayer(self: *Db, name: []const u8) void {
        if (self.players.fetchRemove(name)) |kv| {
            self.alloc.free(kv.key);
            freePerms(self.alloc, kv.value);
        }
    }

    pub fn grant(self: *Db, name: []const u8, node: []const u8) !void {
        std.debug.assert(validNode(node));
        const p = try self.getOrPut(name);
        if (p.denies.fetchRemove(node)) |kv| self.alloc.free(kv.key);
        if (!p.grants.contains(node)) {
            const owned = try self.alloc.dupe(u8, node);
            errdefer self.alloc.free(owned);
            try p.grants.put(owned, {});
        }
    }

    pub fn deny(self: *Db, name: []const u8, node: []const u8) !void {
        std.debug.assert(validNode(node));
        const p = try self.getOrPut(name);
        if (p.grants.fetchRemove(node)) |kv| self.alloc.free(kv.key);
        if (!p.denies.contains(node)) {
            const owned = try self.alloc.dupe(u8, node);
            errdefer self.alloc.free(owned);
            try p.denies.put(owned, {});
        }
    }

    /// Remove a node from both sets (returns true when something changed).
    pub fn clearNode(self: *Db, name: []const u8, node: []const u8) !bool {
        const p = self.players.get(name) orelse return false;
        var changed = false;
        if (p.grants.fetchRemove(node)) |kv| {
            self.alloc.free(kv.key);
            changed = true;
        }
        if (p.denies.fetchRemove(node)) |kv| {
            self.alloc.free(kv.key);
            changed = true;
        }
        try self.gc(name);
        return changed;
    }

    fn gc(self: *Db, name: []const u8) !void {
        const p = self.players.get(name) orelse return;
        if (p.level == DEFAULT_LEVEL and p.grants.count() == 0 and p.denies.count() == 0) {
            self.clearPlayer(name);
        }
    }

    /// Decision core: deny-match wins, then grant-match, then level gate.
    /// `sender_level` is CONSOLE_LEVEL for console, else levelFor(name).
    pub fn allows(self: *const Db, name: []const u8, node: []const u8, min_level: u8) bool {
        const p = self.players.get(name) orelse return DEFAULT_LEVEL >= min_level;
        var it = p.denies.iterator();
        while (it.next()) |e| {
            if (nodeMatches(e.key_ptr.*, node)) return false;
        }
        var jt = p.grants.iterator();
        while (jt.next()) |e| {
            if (nodeMatches(e.key_ptr.*, node)) return true;
        }
        return p.level >= min_level;
    }

    pub fn countOps(self: *const Db) usize {
        var n: usize = 0;
        var it = self.players.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.*.level > 0) n += 1;
        }
        return n;
    }
};

fn freePerms(alloc: std.mem.Allocator, p: *PlayerPerms) void {
    var gi = p.grants.iterator();
    while (gi.next()) |e| alloc.free(e.key_ptr.*);
    p.grants.deinit();
    var di = p.denies.iterator();
    while (di.next()) |e| alloc.free(e.key_ptr.*);
    p.denies.deinit();
    alloc.destroy(p);
}

pub const DbError = error{CorruptPerms} || std.mem.Allocator.Error;

pub fn encode(alloc: std.mem.Allocator, db: *const Db) ![]u8 {
    var n: usize = 4 + 1 + 2;
    var it = db.players.iterator();
    while (it.next()) |e| {
        const p = e.value_ptr.*;
        n += 1 + p.name.len + 1 + 2 + 2; // name + level + ngrants + ndenies
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
    // Canonical order (sorted by name) so bytes are deterministic.
    const names = try alloc.alloc([]const u8, db.players.count());
    defer alloc.free(names);
    var k: usize = 0;
    var kit = db.players.iterator();
    while (kit.next()) |e| {
        names[k] = e.key_ptr.*;
        k += 1;
    }
    std.mem.sort([]const u8, names, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    std.mem.writeInt(u16, out[i..][0..2], @intCast(names.len), .big);
    i += 2;
    for (names) |nm| {
        const p = db.players.get(nm).?;
        out[i] = @intCast(nm.len);
        i += 1;
        @memcpy(out[i..][0..nm.len], nm);
        i += nm.len;
        out[i] = p.level;
        i += 1;
        const gkeys = try sortedKeys(alloc, &p.grants);
        defer alloc.free(gkeys);
        std.mem.writeInt(u16, out[i..][0..2], @intCast(gkeys.len), .big);
        i += 2;
        for (gkeys) |g| {
            std.mem.writeInt(u16, out[i..][0..2], @intCast(g.len), .big);
            i += 2;
            @memcpy(out[i..][0..g.len], g);
            i += g.len;
        }
        const dkeys = try sortedKeys(alloc, &p.denies);
        defer alloc.free(dkeys);
        std.mem.writeInt(u16, out[i..][0..2], @intCast(dkeys.len), .big);
        i += 2;
        for (dkeys) |g| {
            std.mem.writeInt(u16, out[i..][0..2], @intCast(g.len), .big);
            i += 2;
            @memcpy(out[i..][0..g.len], g);
            i += g.len;
        }
    }
    std.debug.assert(i == n);
    return out;
}

fn sortedKeys(alloc: std.mem.Allocator, set: *const std.StringHashMap(void)) ![][]const u8 {
    const out = try alloc.alloc([]const u8, set.count());
    var i: usize = 0;
    var it = set.iterator();
    while (it.next()) |e| {
        out[i] = e.key_ptr.*;
        i += 1;
    }
    std.mem.sort([]const u8, out, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return out;
}

pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) DbError!Db {
    var db = Db.init(alloc);
    errdefer db.deinit();
    var r = bytes;
    const take = struct {
        fn run(b: *[]const u8, n: usize) error{CorruptPerms}![]const u8 {
            if (b.len < n) return error.CorruptPerms;
            const s = b.*[0..n];
            b.* = b.*[n..];
            return s;
        }
    }.run;
    if (!std.mem.eql(u8, try take(&r, 4), magic)) return error.CorruptPerms;
    if ((try take(&r, 1))[0] != version) return error.CorruptPerms;
    const count = std.mem.readInt(u16, (try take(&r, 2))[0..2], .big);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const ulen: usize = (try take(&r, 1))[0];
        if (ulen == 0 or ulen > max_name_len) return error.CorruptPerms;
        const name = try take(&r, ulen);
        if (!validPlayerName(name)) return error.CorruptPerms;
        const level = (try take(&r, 1))[0];
        if (level > MAX_LEVEL) return error.CorruptPerms;
        // Duplicate names would fork the matrix — reject.
        if (db.players.contains(name)) return error.CorruptPerms;
        const p = try db.getOrPut(name);
        p.level = level;
        const ng = std.mem.readInt(u16, (try take(&r, 2))[0..2], .big);
        var g: usize = 0;
        while (g < ng) : (g += 1) {
            const nl = std.mem.readInt(u16, (try take(&r, 2))[0..2], .big);
            if (nl == 0 or nl > max_node_len) return error.CorruptPerms;
            const node = try take(&r, nl);
            if (!validNode(node)) return error.CorruptPerms;
            if (p.grants.contains(node)) return error.CorruptPerms;
            const owned = try alloc.dupe(u8, node);
            errdefer alloc.free(owned);
            try p.grants.put(owned, {});
        }
        const nd = std.mem.readInt(u16, (try take(&r, 2))[0..2], .big);
        var d: usize = 0;
        while (d < nd) : (d += 1) {
            const nl = std.mem.readInt(u16, (try take(&r, 2))[0..2], .big);
            if (nl == 0 or nl > max_node_len) return error.CorruptPerms;
            const node = try take(&r, nl);
            if (!validNode(node)) return error.CorruptPerms;
            if (p.denies.contains(node) or p.grants.contains(node)) return error.CorruptPerms;
            const owned = try alloc.dupe(u8, node);
            errdefer alloc.free(owned);
            try p.denies.put(owned, {});
        }
    }
    if (r.len != 0) return error.CorruptPerms;
    // Drop empty rows (level 0 + no nodes) to keep the invariant that
    // setLevel's gc maintains.
    var it = db.players.iterator();
    var drop: ?[]const u8 = null;
    while (it.next()) |e| {
        const p = e.value_ptr.*;
        if (p.level == DEFAULT_LEVEL and p.grants.count() == 0 and p.denies.count() == 0) {
            drop = e.key_ptr.*;
            break;
        }
    }
    if (drop) |k| db.clearPlayer(k);
    return db;
}

/// Persist the whole matrix (single row). Caller holds the encode-side
/// lock; put itself needs world_lock (same discipline as player rows).
pub fn save(pool: *shard_mod.ShardPool, db: *const Db) !void {
    const enc = try encode(pool.allocator, db);
    defer pool.allocator.free(enc);
    try pool.put(perm_key, enc);
}

pub fn load(pool: *shard_mod.ShardPool, alloc: std.mem.Allocator) !?Db {
    const raw = try pool.get(perm_key);
    if (raw == null) return null;
    defer alloc.free(raw.?);
    return try decode(alloc, raw.?);
}

test "levels + grants + denies + wildcards" {
    const a = std.testing.allocator;
    var db = Db.init(a);
    defer db.deinit();
    // default deny
    try std.testing.expect(!db.allows("Steve", "zigcraft.command.save-all", 4));
    try std.testing.expect(db.allows("Steve", "zigcraft.command.list", 0));
    // op level
    try db.setLevel("Steve", 4);
    try std.testing.expect(db.allows("Steve", "zigcraft.command.save-all", 4));
    // deny beats level
    try db.deny("Steve", "zigcraft.command.save-all");
    try std.testing.expect(!db.allows("Steve", "zigcraft.command.save-all", 4));
    try std.testing.expect(db.allows("Steve", "zigcraft.command.list", 0));
    // grant beats level-gate for a low player
    try db.grant("Bob", "zigcraft.command.save-all");
    try std.testing.expect(db.allows("Bob", "zigcraft.command.save-all", 4));
    // wildcard grant
    try db.grant("Bob", "zigcraft.command.*");
    try std.testing.expect(db.allows("Bob", "zigcraft.command.op", 4));
    // wildcard does not cross the dot boundary
    try std.testing.expect(!db.allows("Bob", "zigcraft.cmd", 4));
    // exact deny inside a granted wildcard still wins
    try db.deny("Bob", "zigcraft.command.stop");
    try std.testing.expect(!db.allows("Bob", "zigcraft.command.stop", 0));
    // clearNode restores level behavior
    try std.testing.expect(try db.clearNode("Bob", "zigcraft.command.stop"));
    try std.testing.expect(db.allows("Bob", "zigcraft.command.stop", 0));
    // deop resets everything
    db.clearPlayer("Steve");
    try std.testing.expect(!db.allows("Steve", "zigcraft.command.save-all", 4));
    try std.testing.expect(db.levelFor("Nobody") == 0);
}

test "node validation" {
    try std.testing.expect(validNode("zigcraft.command.list"));
    try std.testing.expect(validNode("zigcraft.command.*"));
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
}

test "perms roundtrip incl empty + corrupt rejection" {
    const a = std.testing.allocator;
    var db = Db.init(a);
    defer db.deinit();
    try db.setLevel("Steve", 4);
    try db.grant("Bob", "zigcraft.command.save-all");
    try db.deny("Bob", "zigcraft.command.stop");
    try db.grant("Al", "zigcraft.*");
    const enc = try encode(a, &db);
    defer a.free(enc);
    var back = try decode(a, enc);
    defer back.deinit();
    try std.testing.expectEqual(@as(u8, 4), back.levelFor("Steve"));
    try std.testing.expect(back.allows("Bob", "zigcraft.command.save-all", 4));
    try std.testing.expect(!back.allows("Bob", "zigcraft.command.stop", 4));
    try std.testing.expect(back.allows("Al", "zigcraft.command.stop", 4));
    try std.testing.expect(!back.allows("Al", "other.tree", 4));
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
