//! Name/IP bans and the whitelist (vanilla 1.7.10 semantics).
//!
//! Dedicated-server login rejects banned names/IPs and non-whitelisted
//! names when the list is enabled. Messages are hardcoded in the jar
//! (`oi` login handler, `nh` idle kick) — not lang keys — so they live as
//! literals on the Server side; this module only stores and persists.
//!
//! Rows persist in the world store under their own dims (same single-row
//! pattern as permissions): no world = in-memory only.

const std = @import("std");
const store_mod = @import("../world/store.zig");
const shard_mod = @import("../world/shard.zig");

pub const bans_dim: u8 = 253;
pub const bans_key = store_mod.encodeKey(bans_dim, 0, 0);
pub const whitelist_dim: u8 = 252;
pub const whitelist_key = store_mod.encodeKey(whitelist_dim, 0, 0);

pub const BanEntry = struct {
    reason: []u8,
};

/// Lowercased-name map. Vanilla compares names case-insensitively for
/// bans (GameProfile) — keys here are stored lowered.
pub const BanDb = struct {
    alloc: std.mem.Allocator,
    names: std.StringHashMap([]u8),
    ips: std.StringHashMap([]u8),

    pub fn init(alloc: std.mem.Allocator) BanDb {
        return .{ .alloc = alloc, .names = .init(alloc), .ips = .init(alloc) };
    }

    pub fn deinit(self: *BanDb) void {
        var it = self.names.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        self.names.deinit();
        var it2 = self.ips.iterator();
        while (it2.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        self.ips.deinit();
    }

    fn lower(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
        const out = try alloc.dupe(u8, s);
        for (out) |*c| c.* = std.ascii.toLower(c.*);
        return out;
    }

    pub fn banName(self: *BanDb, name: []const u8, reason: []const u8) !void {
        const k = try lower(self.alloc, name);
        errdefer self.alloc.free(k);
        const r = try self.alloc.dupe(u8, reason);
        errdefer self.alloc.free(r);
        if (self.names.fetchRemove(k)) |old| {
            self.alloc.free(old.key);
            self.alloc.free(old.value);
        }
        try self.names.put(k, r);
    }

    pub fn unbanName(self: *BanDb, name: []const u8) bool {
        const tmp = lower(self.alloc, name) catch return false;
        defer self.alloc.free(tmp);
        if (self.names.fetchRemove(tmp)) |old| {
            self.alloc.free(old.key);
            self.alloc.free(old.value);
            return true;
        }
        return false;
    }

    pub fn bannedName(self: *const BanDb, name: []const u8) ?[]const u8 {
        var lb: [16]u8 = undefined;
        if (name.len > lb.len) return null;
        for (name, 0..) |c, i| lb[i] = std.ascii.toLower(c);
        return self.names.get(lb[0..name.len]);
    }

    pub fn banIp(self: *BanDb, ip: []const u8, reason: []const u8) !void {
        const k = try self.alloc.dupe(u8, ip);
        errdefer self.alloc.free(k);
        const r = try self.alloc.dupe(u8, reason);
        errdefer self.alloc.free(r);
        if (self.ips.fetchRemove(k)) |old| {
            self.alloc.free(old.key);
            self.alloc.free(old.value);
        }
        try self.ips.put(k, r);
    }

    pub fn unbanIp(self: *BanDb, ip: []const u8) bool {
        if (self.ips.fetchRemove(ip)) |old| {
            self.alloc.free(old.key);
            self.alloc.free(old.value);
            return true;
        }
        return false;
    }

    pub fn bannedIp(self: *const BanDb, ip: []const u8) ?[]const u8 {
        return self.ips.get(ip);
    }

    pub fn nameCount(self: *const BanDb) usize {
        return self.names.count();
    }

    pub fn ipCount(self: *const BanDb) usize {
        return self.ips.count();
    }

    const magic = "ZBAN";
    const version: u8 = 1;

    pub fn encode(self: *const BanDb, alloc: std.mem.Allocator) ![]u8 {
        var n: usize = 4 + 1 + 4;
        var it = self.names.iterator();
        while (it.next()) |e| n += 1 + e.key_ptr.len + 2 + e.value_ptr.len;
        n += 4;
        var it2 = self.ips.iterator();
        while (it2.next()) |e| n += 1 + e.key_ptr.len + 2 + e.value_ptr.len;
        const out = try alloc.alloc(u8, n);
        errdefer alloc.free(out);
        var i: usize = 0;
        @memcpy(out[i..][0..4], magic);
        i += 4;
        out[i] = version;
        i += 1;
        std.mem.writeInt(u32, out[i..][0..4], @intCast(self.names.count()), .big);
        i += 4;
        var jt = self.names.iterator();
        while (jt.next()) |e| {
            out[i] = @intCast(e.key_ptr.len);
            i += 1;
            @memcpy(out[i..][0..e.key_ptr.len], e.key_ptr.*);
            i += e.key_ptr.len;
            std.mem.writeInt(u16, out[i..][0..2], @intCast(e.value_ptr.len), .big);
            i += 2;
            @memcpy(out[i..][0..e.value_ptr.len], e.value_ptr.*);
            i += e.value_ptr.len;
        }
        std.mem.writeInt(u32, out[i..][0..4], @intCast(self.ips.count()), .big);
        i += 4;
        var kt = self.ips.iterator();
        while (kt.next()) |e| {
            out[i] = @intCast(e.key_ptr.len);
            i += 1;
            @memcpy(out[i..][0..e.key_ptr.len], e.key_ptr.*);
            i += e.key_ptr.len;
            std.mem.writeInt(u16, out[i..][0..2], @intCast(e.value_ptr.len), .big);
            i += 2;
            @memcpy(out[i..][0..e.value_ptr.len], e.value_ptr.*);
            i += e.value_ptr.len;
        }
        std.debug.assert(i == n);
        return out;
    }

    pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) !BanDb {
        var db = BanDb.init(alloc);
        errdefer db.deinit();
        if (bytes.len < 9 or !std.mem.eql(u8, bytes[0..4], magic) or bytes[4] != version) return error.Corrupt;
        var i: usize = 5;
        const nn = std.mem.readInt(u32, bytes[i..][0..4], .big);
        i += 4;
        var k: usize = 0;
        while (k < nn) : (k += 1) {
            if (i + 1 > bytes.len) return error.Corrupt;
            const kl = bytes[i];
            i += 1;
            if (i + kl + 2 > bytes.len) return error.Corrupt;
            const key = bytes[i .. i + kl];
            i += kl;
            const vl = std.mem.readInt(u16, bytes[i..][0..2], .big);
            i += 2;
            if (i + vl > bytes.len) return error.Corrupt;
            try db.names.put(try alloc.dupe(u8, key), try alloc.dupe(u8, bytes[i .. i + vl]));
            i += vl;
        }
        if (i + 4 > bytes.len) return error.Corrupt;
        const ni = std.mem.readInt(u32, bytes[i..][0..4], .big);
        i += 4;
        k = 0;
        while (k < ni) : (k += 1) {
            if (i + 1 > bytes.len) return error.Corrupt;
            const kl = bytes[i];
            i += 1;
            if (i + kl + 2 > bytes.len) return error.Corrupt;
            const key = bytes[i .. i + kl];
            i += kl;
            const vl = std.mem.readInt(u16, bytes[i..][0..2], .big);
            i += 2;
            if (i + vl > bytes.len) return error.Corrupt;
            try db.ips.put(try alloc.dupe(u8, key), try alloc.dupe(u8, bytes[i .. i + vl]));
            i += vl;
        }
        return db;
    }
};

/// Whitelist: enabled flag + lowercased names. "Seen" count for the list
/// reply is derived server-side (player-row count), not stored here.
pub const Whitelist = struct {
    alloc: std.mem.Allocator,
    enabled: bool = false,
    names: std.StringHashMap(void),

    pub fn init(alloc: std.mem.Allocator) Whitelist {
        return .{ .alloc = alloc, .names = .init(alloc) };
    }

    pub fn deinit(self: *Whitelist) void {
        var it = self.names.iterator();
        while (it.next()) |e| self.alloc.free(e.key_ptr.*);
        self.names.deinit();
    }

    pub fn add(self: *Whitelist, name: []const u8) !void {
        var lb: [16]u8 = undefined;
        if (name.len == 0 or name.len > lb.len) return error.BadName;
        for (name, 0..) |c, i| lb[i] = std.ascii.toLower(c);
        const key = try self.alloc.dupe(u8, lb[0..name.len]);
        errdefer self.alloc.free(key);
        if (self.names.fetchRemove(key)) |old| self.alloc.free(old.key);
        try self.names.put(key, {});
    }

    pub fn remove(self: *Whitelist, name: []const u8) bool {
        var lb: [16]u8 = undefined;
        if (name.len == 0 or name.len > lb.len) return false;
        for (name, 0..) |c, i| lb[i] = std.ascii.toLower(c);
        if (self.names.fetchRemove(lb[0..name.len])) |old| {
            self.alloc.free(old.key);
            return true;
        }
        return false;
    }

    pub fn contains(self: *const Whitelist, name: []const u8) bool {
        var lb: [16]u8 = undefined;
        if (name.len == 0 or name.len > lb.len) return false;
        for (name, 0..) |c, i| lb[i] = std.ascii.toLower(c);
        return self.names.contains(lb[0..name.len]);
    }

    const magic = "ZWL_";
    const version: u8 = 1;

    pub fn encode(self: *const Whitelist, alloc: std.mem.Allocator) ![]u8 {
        var n: usize = 4 + 1 + 1 + 4;
        var it = self.names.iterator();
        while (it.next()) |e| n += 1 + e.key_ptr.len;
        const out = try alloc.alloc(u8, n);
        errdefer alloc.free(out);
        var i: usize = 0;
        @memcpy(out[i..][0..4], magic);
        i += 4;
        out[i] = version;
        i += 1;
        out[i] = if (self.enabled) 1 else 0;
        i += 1;
        std.mem.writeInt(u32, out[i..][0..4], @intCast(self.names.count()), .big);
        i += 4;
        var jt = self.names.iterator();
        while (jt.next()) |e| {
            out[i] = @intCast(e.key_ptr.len);
            i += 1;
            @memcpy(out[i..][0..e.key_ptr.len], e.key_ptr.*);
            i += e.key_ptr.len;
        }
        return out;
    }

    pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) !Whitelist {
        var wl = Whitelist.init(alloc);
        errdefer wl.deinit();
        if (bytes.len < 10 or !std.mem.eql(u8, bytes[0..4], magic) or bytes[4] != version) return error.Corrupt;
        wl.enabled = bytes[5] != 0;
        var i: usize = 6;
        const nn = std.mem.readInt(u32, bytes[i..][0..4], .big);
        i += 4;
        var k: usize = 0;
        while (k < nn) : (k += 1) {
            if (i + 1 > bytes.len) return error.Corrupt;
            const kl = bytes[i];
            i += 1;
            if (i + kl > bytes.len) return error.Corrupt;
            try wl.names.put(try alloc.dupe(u8, bytes[i .. i + kl]), {});
            i += kl;
        }
        return wl;
    }
};

pub fn saveBans(pool: *shard_mod.ShardPool, alloc: std.mem.Allocator, db: *const BanDb) !void {
    const enc = try db.encode(alloc);
    defer alloc.free(enc);
    try pool.put(bans_key, enc);
}

pub fn loadBans(pool: *shard_mod.ShardPool, alloc: std.mem.Allocator) !?BanDb {
    const raw = try pool.get(alloc, bans_key);
    if (raw == null) return null;
    defer alloc.free(raw.?);
    return try BanDb.decode(alloc, raw.?);
}

pub fn saveWhitelist(pool: *shard_mod.ShardPool, alloc: std.mem.Allocator, wl: *const Whitelist) !void {
    const enc = try wl.encode(alloc);
    defer alloc.free(enc);
    try pool.put(whitelist_key, enc);
}

pub fn loadWhitelist(pool: *shard_mod.ShardPool, alloc: std.mem.Allocator) !?Whitelist {
    const raw = try pool.get(alloc, whitelist_key);
    if (raw == null) return null;
    defer alloc.free(raw.?);
    return try Whitelist.decode(alloc, raw.?);
}

test "ban db roundtrip incl case-insensitivity" {
    var db = BanDb.init(std.testing.allocator);
    defer db.deinit();
    try db.banName("Steve", "griefing");
    try std.testing.expectEqualStrings("griefing", db.bannedName("steve").?);
    try std.testing.expectEqualStrings("griefing", db.bannedName("STEVE").?);
    try std.testing.expect(db.bannedName("Alex") == null);
    try db.banIp("1.2.3.4", "spam");
    try std.testing.expectEqualStrings("spam", db.bannedIp("1.2.3.4").?);
    try std.testing.expect(db.unbanName("STEVE"));
    try std.testing.expect(db.bannedName("steve") == null);
    try std.testing.expect(!db.unbanName("Steve"));
    const enc = try db.encode(std.testing.allocator);
    defer std.testing.allocator.free(enc);
    var db2 = try BanDb.decode(std.testing.allocator, enc);
    defer db2.deinit();
    try std.testing.expectEqualStrings("spam", db2.bannedIp("1.2.3.4").?);
    try std.testing.expect(db2.bannedName("steve") == null);
}

test "whitelist roundtrip" {
    var wl = Whitelist.init(std.testing.allocator);
    defer wl.deinit();
    wl.enabled = true;
    try wl.add("Steve");
    try std.testing.expect(wl.contains("STEVE"));
    try std.testing.expect(wl.remove("steve"));
    try std.testing.expect(!wl.contains("steve"));
    const enc = try wl.encode(std.testing.allocator);
    defer std.testing.allocator.free(enc);
    var wl2 = try Whitelist.decode(std.testing.allocator, enc);
    defer wl2.deinit();
    try std.testing.expect(wl2.enabled);
    try std.testing.expectEqual(@as(usize, 0), wl2.names.count());
}
