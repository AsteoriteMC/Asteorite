//! Name/IP bans and the whitelist (vanilla 1.7.10 semantics).
//!
//! Dedicated-server login rejects banned names/IPs and non-whitelisted
//! UUIDs when the list is enabled. Messages are hardcoded in the jar
//! (`oi` login handler, `nh` idle kick) — not lang keys — so they live as
//! literals on the Server side; this module only stores and persists.
//!
//! Rows persist beside the server (`banned-players.json`,
//! `banned-ips.json`, `whitelist.json` in the server directory), not in
//! the world store. Atomic tmp+rename writes keep them crash-safe.

const std = @import("std");
const perms = @import("permissions.zig");
const uuid_mod = @import("../../net/uuid.zig");

/// Offline-UUID derivation for legacy rows (exact: same bytes login uses).
fn offlineUuidFor(name: []const u8, out: *[perms.uuid_len]u8) [perms.uuid_len]u8 {
    uuid_mod.formatUuid(uuid_mod.offlineUuid(name), out);
    return out.*;
}

pub const BanEntry = struct {
    reason: []u8,
};

/// One name-ban row: display name + reason (both owned). Keyed by UUID
/// string in `BanDb.names` — a renamed account must not inherit (or shed)
/// another one's ban.
pub const NameBanRow = struct {
    name: []u8,
    reason: []u8,
};

/// UUID-keyed name bans + raw IP bans. Vanilla compares ban UUIDs, not
/// names (GameProfile) — keys here are canonical UUID strings, so a
/// renamed account keeps its ban and a recycled name doesn't inherit one.
/// Offline servers derive UUIDs from names, so nothing changes there.
pub const BanDb = struct {
    alloc: std.mem.Allocator,
    names: std.StringHashMap(NameBanRow),
    ips: std.StringHashMap([]u8),

    pub fn init(alloc: std.mem.Allocator) BanDb {
        return .{ .alloc = alloc, .names = .init(alloc), .ips = .init(alloc) };
    }

    pub fn deinit(self: *BanDb) void {
        var it = self.names.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.name);
            self.alloc.free(e.value_ptr.reason);
        }
        self.names.deinit();
        freeReasonMap(self.alloc, &self.ips);
    }

    /// Free every key+reason in a ban map, then drop the map.
    fn freeReasonMap(alloc: std.mem.Allocator, map: *std.StringHashMap([]u8)) void {
        var it = map.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*);
        }
        map.deinit();
    }

    /// Insert-or-replace a reason row (owned key, duped reason).
    fn replace(map: *std.StringHashMap([]u8), alloc: std.mem.Allocator, key: []u8, reason: []const u8) !void {
        const r = try alloc.dupe(u8, reason);
        errdefer alloc.free(r);
        if (map.fetchRemove(key)) |old| {
            alloc.free(old.key);
            alloc.free(old.value);
        }
        errdefer alloc.free(key);
        try map.put(key, r);
    }

    /// Remove a reason row, freeing it. True when one existed.
    fn remove(map: *std.StringHashMap([]u8), alloc: std.mem.Allocator, key: []const u8) bool {
        if (map.fetchRemove(key)) |old| {
            alloc.free(old.key);
            alloc.free(old.value);
            return true;
        }
        return false;
    }

    pub fn banUuid(self: *BanDb, uuid: *const [perms.uuid_len]u8, name: []const u8, reason: []const u8) !void {
        if (!perms.validPlayerName(name)) return error.BadName;
        const owned_name = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(owned_name);
        const r = try self.alloc.dupe(u8, reason);
        errdefer self.alloc.free(r);
        if (self.names.fetchRemove(uuid[0..])) |old| {
            self.alloc.free(old.key);
            self.alloc.free(old.value.name);
            self.alloc.free(old.value.reason);
        }
        const key = try self.alloc.dupe(u8, uuid[0..]);
        errdefer self.alloc.free(key);
        try self.names.put(key, .{ .name = owned_name, .reason = r });
    }

    pub fn unbanUuid(self: *BanDb, uuid: *const [perms.uuid_len]u8) bool {
        if (self.names.fetchRemove(uuid[0..])) |old| {
            self.alloc.free(old.key);
            self.alloc.free(old.value.name);
            self.alloc.free(old.value.reason);
            return true;
        }
        return false;
    }

    /// Ban reason for a UUID, if banned.
    pub fn bannedUuid(self: *const BanDb, uuid: *const [perms.uuid_len]u8) ?[]const u8 {
        if (self.names.get(uuid[0..])) |row| return row.reason;
        return null;
    }

    pub fn banIp(self: *BanDb, ip: []const u8, reason: []const u8) !void {
        const k = try self.alloc.dupe(u8, ip);
        try replace(&self.ips, self.alloc, k, reason);
    }

    pub fn unbanIp(self: *BanDb, ip: []const u8) bool {
        return remove(&self.ips, self.alloc, ip);
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
    const version: u8 = 2;

    /// One ban-map entry on the wire: u8 key len + key + u16 reason len.
    fn entrySize(key_len: usize, val_len: usize) usize {
        return 1 + key_len + 2 + val_len;
    }

    /// One UUID name-ban row: uuid16 + u8 name len + name + u16 reason len.
    fn nameRowSize(name_len: usize, reason_len: usize) usize {
        return perms.uuid_len + 1 + name_len + 2 + reason_len;
    }

    fn writeEntries(out: []u8, i: usize, map: *const std.StringHashMap([]u8)) usize {
        var o = i;
        var it = map.iterator();
        while (it.next()) |e| {
            out[o] = @intCast(e.key_ptr.len);
            o += 1;
            @memcpy(out[o..][0..e.key_ptr.len], e.key_ptr.*);
            o += e.key_ptr.len;
            std.mem.writeInt(u16, out[o..][0..2], @intCast(e.value_ptr.len), .big);
            o += 2;
            @memcpy(out[o..][0..e.value_ptr.len], e.value_ptr.*);
            o += e.value_ptr.len;
        }
        return o;
    }

    /// Decode one ban section (u32 count, then entries) into `map`.
    fn readSection(bytes: []const u8, i: usize, alloc: std.mem.Allocator, map: *std.StringHashMap([]u8)) !usize {
        var o = i;
        if (o + 4 > bytes.len) return error.Corrupt;
        const n = std.mem.readInt(u32, bytes[o..][0..4], .big);
        o += 4;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            if (o + 1 > bytes.len) return error.Corrupt;
            const kl = bytes[o];
            o += 1;
            if (o + kl + 2 > bytes.len) return error.Corrupt;
            const key = bytes[o .. o + kl];
            o += kl;
            const vl = std.mem.readInt(u16, bytes[o..][0..2], .big);
            o += 2;
            if (o + vl > bytes.len) return error.Corrupt;
            const owned_k = try alloc.dupe(u8, key);
            errdefer alloc.free(owned_k);
            const owned_v = try alloc.dupe(u8, bytes[o .. o + vl]);
            errdefer alloc.free(owned_v);
            try map.put(owned_k, owned_v);
            o += vl;
        }
        return o;
    }

    pub fn encode(self: *const BanDb, alloc: std.mem.Allocator) ![]u8 {
        var n: usize = 4 + 1 + 4;
        var it = self.names.iterator();
        while (it.next()) |e| n += nameRowSize(e.value_ptr.name.len, e.value_ptr.reason.len);
        n += 4;
        var it2 = self.ips.iterator();
        while (it2.next()) |e| n += entrySize(e.key_ptr.len, e.value_ptr.len);
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
            @memcpy(out[i..][0..perms.uuid_len], e.key_ptr.*[0..perms.uuid_len]);
            i += perms.uuid_len;
            out[i] = @intCast(e.value_ptr.name.len);
            i += 1;
            @memcpy(out[i..][0..e.value_ptr.name.len], e.value_ptr.name);
            i += e.value_ptr.name.len;
            std.mem.writeInt(u16, out[i..][0..2], @intCast(e.value_ptr.reason.len), .big);
            i += 2;
            @memcpy(out[i..][0..e.value_ptr.reason.len], e.value_ptr.reason);
            i += e.value_ptr.reason.len;
        }
        std.mem.writeInt(u32, out[i..][0..4], @intCast(self.ips.count()), .big);
        i += 4;
        i = writeEntries(out, i, &self.ips);
        std.debug.assert(i == n);
        return out;
    }

    /// Decode one UUID name-ban section (u32 count, then uuid16 + u8 name
    /// len + name + u16 reason len rows) into `db.names`. v1 (name-keyed)
    /// bytes fail closed here via the version gate above.
    fn readNameSection(bytes: []const u8, i: usize, alloc: std.mem.Allocator, db: *BanDb) !usize {
        var o = i;
        if (o + 4 > bytes.len) return error.Corrupt;
        const n = std.mem.readInt(u32, bytes[o..][0..4], .big);
        o += 4;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            if (o + perms.uuid_len + 1 > bytes.len) return error.Corrupt;
            const ubytes = bytes[o .. o + perms.uuid_len];
            o += perms.uuid_len;
            if (!perms.validUuid(ubytes)) return error.Corrupt;
            var ubuf: [perms.uuid_len]u8 = undefined;
            const uuid = perms.normUuid(ubytes, &ubuf);
            const nl = bytes[o];
            o += 1;
            if (o + nl > bytes.len) return error.Corrupt;
            const name = bytes[o .. o + nl];
            o += nl;
            if (!perms.validPlayerName(name)) return error.Corrupt;
            if (o + 2 > bytes.len) return error.Corrupt;
            const rl = std.mem.readInt(u16, bytes[o..][0..2], .big);
            o += 2;
            if (o + rl > bytes.len) return error.Corrupt;
            if (db.names.contains(uuid[0..])) return error.Corrupt;
            const key = try alloc.dupe(u8, uuid[0..]);
            errdefer alloc.free(key);
            const owned_name = try alloc.dupe(u8, name);
            errdefer alloc.free(owned_name);
            const reason = try alloc.dupe(u8, bytes[o .. o + rl]);
            errdefer alloc.free(reason);
            try db.names.put(key, .{ .name = owned_name, .reason = reason });
            o += rl;
        }
        return o;
    }

    pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) !BanDb {
        var db = BanDb.init(alloc);
        errdefer db.deinit();
        if (bytes.len < 9 or !std.mem.eql(u8, bytes[0..4], magic) or bytes[4] != version) return error.Corrupt;
        var i: usize = 5;
        i = try readNameSection(bytes, i, alloc, &db);
        i = try readSection(bytes, i, alloc, &db.ips);
        if (i != bytes.len) return error.Corrupt;
        return db;
    }
};

/// Whitelist: enabled flag + UUID rows (display names kept for /list).
/// Same identity model as the perm matrix: UUID-bound at add time, never
/// name-matched (account renames free old names for re-registration,
/// which would inherit a name-keyed row). Offline servers derive UUIDs
/// from names, so /whitelist add works offline exactly as before.
pub const Whitelist = struct {
    alloc: std.mem.Allocator,
    enabled: bool = false,
    /// UUID string -> display name (both owned). Display refreshes on
    /// re-add; enforcement compares UUID bytes only.
    rows: std.StringHashMap([]u8),

    pub fn init(alloc: std.mem.Allocator) Whitelist {
        return .{ .alloc = alloc, .rows = .init(alloc) };
    }

    pub fn deinit(self: *Whitelist) void {
        var it = self.rows.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        self.rows.deinit();
    }

    pub fn add(self: *Whitelist, uuid: *const [perms.uuid_len]u8, name: []const u8) !void {
        if (!perms.validPlayerName(name)) return error.BadName;
        const owned_name = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(owned_name);
        if (self.rows.fetchRemove(uuid[0..])) |old| {
            self.alloc.free(old.key);
            self.alloc.free(old.value);
        }
        const key = try self.alloc.dupe(u8, uuid[0..]);
        errdefer self.alloc.free(key);
        try self.rows.put(key, owned_name);
    }

    pub fn remove(self: *Whitelist, uuid: *const [perms.uuid_len]u8) bool {
        if (self.rows.fetchRemove(uuid[0..])) |old| {
            self.alloc.free(old.key);
            self.alloc.free(old.value);
            return true;
        }
        return false;
    }

    pub fn contains(self: *const Whitelist, uuid: *const [perms.uuid_len]u8) bool {
        return self.rows.contains(uuid[0..]);
    }

    const magic = "ZWL_";
    const version: u8 = 2;

    pub fn encode(self: *const Whitelist, alloc: std.mem.Allocator) ![]u8 {
        var n: usize = 4 + 1 + 1 + 4;
        var it = self.rows.iterator();
        while (it.next()) |e| n += perms.uuid_len + 1 + e.value_ptr.len;
        const out = try alloc.alloc(u8, n);
        errdefer alloc.free(out);
        var i: usize = 0;
        @memcpy(out[i..][0..4], magic);
        i += 4;
        out[i] = version;
        i += 1;
        out[i] = if (self.enabled) 1 else 0;
        i += 1;
        std.mem.writeInt(u32, out[i..][0..4], @intCast(self.rows.count()), .big);
        i += 4;
        var jt = self.rows.iterator();
        while (jt.next()) |e| {
            @memcpy(out[i..][0..perms.uuid_len], e.key_ptr.*[0..perms.uuid_len]);
            i += perms.uuid_len;
            out[i] = @intCast(e.value_ptr.len);
            i += 1;
            @memcpy(out[i..][0..e.value_ptr.len], e.value_ptr.*);
            i += e.value_ptr.len;
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
            if (i + perms.uuid_len + 1 > bytes.len) return error.Corrupt;
            const ubytes = bytes[i .. i + perms.uuid_len];
            i += perms.uuid_len;
            if (!perms.validUuid(ubytes)) return error.Corrupt;
            var ubuf: [perms.uuid_len]u8 = undefined;
            const uuid = perms.normUuid(ubytes, &ubuf);
            const nl = bytes[i];
            i += 1;
            if (i + nl > bytes.len) return error.Corrupt;
            const name = bytes[i .. i + nl];
            i += nl;
            if (!perms.validPlayerName(name)) return error.Corrupt;
            if (wl.rows.contains(uuid[0..])) return error.Corrupt;
            const key = try alloc.dupe(u8, uuid[0..]);
            errdefer alloc.free(key);
            const owned_name = try alloc.dupe(u8, name);
            errdefer alloc.free(owned_name);
            try wl.rows.put(key, owned_name);
        }
        return wl;
    }
};

/// File persistence (vanilla file names in the server directory, JSON
/// shapes matching our in-memory model).
pub const players_file = "banned-players.json";
const players_tmp = "banned-players.json.tmp";
pub const ips_file = "banned-ips.json";
const ips_tmp = "banned-ips.json.tmp";
pub const whitelist_file = "whitelist.json";
const whitelist_tmp = "whitelist.json.tmp";

const NameBanEntry = struct {
    uuid: []const u8 = "",
    name: []const u8,
    reason: []const u8 = "",
};

const IpBanEntry = struct {
    ip: []const u8,
    reason: []const u8 = "",
};

const WhitelistFile = struct {
    enabled: bool = false,
    entries: []const WhitelistEntry = &.{},
    /// Pre-UUID legacy shape (`{"enabled", "names"}`). Accepted on read
    /// only; always written back in the entries shape.
    names: []const []const u8 = &.{},
};

const WhitelistEntry = struct {
    uuid: []const u8 = "",
    name: []const u8 = "",
};

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

fn sortedKeys(alloc: std.mem.Allocator, set: *const std.StringHashMap([]u8)) ![][]const u8 {
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

/// Both ban lists as JSON (keys sorted, so bytes are deterministic).
/// Name entries carry `{uuid, name, reason}` (vanilla shape).
pub fn encodeBansJson(alloc: std.mem.Allocator, db: *const BanDb) !struct { names: []u8, ips: []u8 } {
    const nkeys = try sortedBanUuids(alloc, &db.names);
    defer alloc.free(nkeys);
    const nents = try alloc.alloc(NameBanEntry, nkeys.len);
    defer alloc.free(nents);
    for (nkeys, 0..) |k, i| {
        const row = db.names.get(k).?;
        nents[i] = .{ .uuid = k, .name = row.name, .reason = row.reason };
    }
    const names_js = try std.json.Stringify.valueAlloc(alloc, nents, .{});
    errdefer alloc.free(names_js);
    const ikeys = try sortedKeys(alloc, &db.ips);
    defer alloc.free(ikeys);
    const ients = try alloc.alloc(IpBanEntry, ikeys.len);
    defer alloc.free(ients);
    for (ikeys, 0..) |k, i| ients[i] = .{ .ip = k, .reason = db.ips.get(k).? };
    const ips_js = try std.json.Stringify.valueAlloc(alloc, ients, .{});
    errdefer alloc.free(ips_js);
    return .{ .names = names_js, .ips = ips_js };
}

/// Sorted name-ban UUIDs (deterministic encode order).
fn sortedBanUuids(alloc: std.mem.Allocator, map: *const std.StringHashMap(NameBanRow)) ![][]const u8 {
    const out = try alloc.alloc([]const u8, map.count());
    var i: usize = 0;
    var it = map.iterator();
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

/// Decoded names section: UUID rows plus a legacy skip count (see
/// decodeWhitelistJson for the policy).
pub const DecodedNameBans = struct {
    rows: std.StringHashMap(NameBanRow),
    skipped_legacy: usize,
};

/// Inverse of encodeBansJson (names part). UUID rows validate fully;
/// uuid-less rows are legacy (derive offline, skip + count online).
/// Duplicates (post-normalization) are rejected.
pub fn decodeNamesJson(alloc: std.mem.Allocator, bytes: []const u8, derive_offline: bool) !DecodedNameBans {
    const parsed = std.json.parseFromSlice([]const NameBanEntry, alloc, bytes, .{ .ignore_unknown_fields = true }) catch return error.Corrupt;
    defer parsed.deinit();
    var out = std.StringHashMap(NameBanRow).init(alloc);
    errdefer {
        var it = out.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.name);
            alloc.free(e.value_ptr.reason);
        }
        out.deinit();
    }
    var skipped: usize = 0;
    for (parsed.value) |e| {
        if (e.uuid.len == 0) {
            skipped += try insertLegacyBan(&out, alloc, e.name, e.reason, derive_offline);
            continue;
        }
        if (!perms.validUuid(e.uuid)) return error.Corrupt;
        if (!perms.validPlayerName(e.name)) return error.Corrupt;
        var ubuf: [perms.uuid_len]u8 = undefined;
        const uuid = perms.normUuid(e.uuid, &ubuf);
        if (out.contains(uuid[0..])) return error.Corrupt;
        const key = try alloc.dupe(u8, uuid[0..]);
        errdefer alloc.free(key);
        const owned_name = try alloc.dupe(u8, e.name);
        errdefer alloc.free(owned_name);
        const reason = try alloc.dupe(u8, e.reason);
        errdefer alloc.free(reason);
        try out.put(key, .{ .name = owned_name, .reason = reason });
    }
    return .{ .rows = out, .skipped_legacy = skipped };
}

/// Insert one legacy name-only ban row: derive the exact UUID offline,
/// else skip and count (1 = skipped). Bad names fail closed either way.
fn insertLegacyBan(out: *std.StringHashMap(NameBanRow), alloc: std.mem.Allocator, name: []const u8, reason: []const u8, derive_offline: bool) !usize {
    if (!perms.validPlayerName(name)) return error.Corrupt;
    if (!derive_offline) return 1;
    var ubuf: [perms.uuid_len]u8 = undefined;
    const uuid = offlineUuidFor(name, &ubuf);
    if (out.contains(uuid[0..])) return error.Corrupt;
    const key = try alloc.dupe(u8, uuid[0..]);
    errdefer alloc.free(key);
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    const owned_reason = try alloc.dupe(u8, reason);
    errdefer alloc.free(owned_reason);
    try out.put(key, .{ .name = owned_name, .reason = owned_reason });
    return 0;
}

/// Inverse of encodeBansJson (IPs part).
pub fn decodeIpsJson(alloc: std.mem.Allocator, bytes: []const u8) !std.StringHashMap([]u8) {
    const parsed = std.json.parseFromSlice([]const IpBanEntry, alloc, bytes, .{ .ignore_unknown_fields = true }) catch return error.Corrupt;
    defer parsed.deinit();
    var out = std.StringHashMap([]u8).init(alloc);
    errdefer {
        var it = out.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*);
        }
        out.deinit();
    }
    for (parsed.value) |e| {
        if (e.ip.len == 0 or e.ip.len > 64) return error.Corrupt;
        if (out.contains(e.ip)) return error.Corrupt;
        const k = try alloc.dupe(u8, e.ip);
        const r = try alloc.dupe(u8, e.reason);
        out.put(k, r) catch |err| {
            alloc.free(k);
            alloc.free(r);
            return err;
        };
    }
    return out;
}

/// Whitelist file as JSON (enabled flag + entries sorted by UUID).
/// Shape mirrors vanilla (`[{uuid, name}]`); the legacy `names` string
/// array still reads (see decode).
pub fn encodeWhitelistJson(alloc: std.mem.Allocator, wl: *const Whitelist) ![]u8 {
    const keys = try sortedUuidKeys(alloc, &wl.rows);
    defer alloc.free(keys);
    const entries = try alloc.alloc(WhitelistEntry, keys.len);
    defer alloc.free(entries);
    for (keys, 0..) |k, i| entries[i] = .{ .uuid = k, .name = wl.rows.get(k).? };
    return try std.json.Stringify.valueAlloc(alloc, WhitelistFile{ .enabled = wl.enabled, .entries = entries }, .{});
}

/// Sorted row UUIDs (deterministic encode order).
fn sortedUuidKeys(alloc: std.mem.Allocator, rows: *const std.StringHashMap([]u8)) ![][]const u8 {
    const out = try alloc.alloc([]const u8, rows.count());
    var i: usize = 0;
    var it = rows.iterator();
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

/// Inverse of encodeWhitelistJson. `derive_offline` selects the legacy-row
/// policy: offline servers derive the exact UUID from the name (lossless),
/// online servers skip them and count (`DecodedWhitelist.skipped_legacy` —
/// the name alone proves nothing there). Malformed UUIDs/names fail the
/// whole file closed; duplicate UUIDs too.
pub const DecodedWhitelist = struct {
    wl: Whitelist,
    skipped_legacy: usize,
};

pub fn decodeWhitelistJson(alloc: std.mem.Allocator, bytes: []const u8, derive_offline: bool) !DecodedWhitelist {
    const parsed = std.json.parseFromSlice(WhitelistFile, alloc, bytes, .{ .ignore_unknown_fields = true }) catch return error.Corrupt;
    defer parsed.deinit();
    var wl = Whitelist.init(alloc);
    errdefer wl.deinit();
    wl.enabled = parsed.value.enabled;
    var skipped: usize = 0;
    for (parsed.value.entries) |e| {
        if (e.uuid.len == 0) {
            skipped += try insertLegacy(&wl, alloc, e.name, derive_offline);
            continue;
        }
        if (!perms.validUuid(e.uuid)) return error.Corrupt;
        if (!perms.validPlayerName(e.name)) return error.Corrupt;
        var ubuf: [perms.uuid_len]u8 = undefined;
        const uuid = perms.normUuid(e.uuid, &ubuf);
        if (wl.rows.contains(uuid[0..])) return error.Corrupt;
        const key = try alloc.dupe(u8, uuid[0..]);
        errdefer alloc.free(key);
        const owned_name = try alloc.dupe(u8, e.name);
        errdefer alloc.free(owned_name);
        try wl.rows.put(key, owned_name);
    }
    for (parsed.value.names) |n| {
        skipped += try insertLegacy(&wl, alloc, n, derive_offline);
    }
    return .{ .wl = wl, .skipped_legacy = skipped };
}

/// Insert one legacy name-only row: derive the exact UUID offline, else
/// skip and count (1 = skipped). Bad names fail closed either way.
fn insertLegacy(wl: *Whitelist, alloc: std.mem.Allocator, name: []const u8, derive_offline: bool) !usize {
    if (!perms.validPlayerName(name)) return error.Corrupt;
    if (!derive_offline) return 1;
    var ubuf: [perms.uuid_len]u8 = undefined;
    const uuid = offlineUuidFor(name, &ubuf);
    if (wl.rows.contains(uuid[0..])) return error.Corrupt;
    const key = try alloc.dupe(u8, uuid[0..]);
    errdefer alloc.free(key);
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    try wl.rows.put(key, owned_name);
    return 0;
}

/// Persist both ban lists (atomic replace each). No world needed.
pub fn saveBansFile(io: std.Io, dir: std.Io.Dir, alloc: std.mem.Allocator, db: *const BanDb) !void {
    const enc = try encodeBansJson(alloc, db);
    defer alloc.free(enc.names);
    defer alloc.free(enc.ips);
    try writePlayersFile(io, dir, enc.names);
    try writeIpsFile(io, dir, enc.ips);
}

/// Raw-bytes halves of saveBansFile (atomic replace each). The server
/// encodes under ban_lock, then calls these after unlocking.
pub fn writePlayersFile(io: std.Io, dir: std.Io.Dir, bytes: []const u8) !void {
    try writeFileAtomic(io, dir, players_tmp, players_file, bytes);
}

pub fn writeIpsFile(io: std.Io, dir: std.Io.Dir, bytes: []const u8) !void {
    try writeFileAtomic(io, dir, ips_tmp, ips_file, bytes);
}

/// Load both ban files. Null when neither exists (caller falls back to the
/// legacy DB row); a present-but-corrupt file fails closed.
pub const DecodedBans = struct {
    db: BanDb,
    skipped_legacy: usize,
};

pub fn loadBansFile(io: std.Io, dir: std.Io.Dir, alloc: std.mem.Allocator, derive_offline: bool) !?DecodedBans {
    const rnames = dir.readFileAlloc(io, players_file, alloc, .limited(1 << 20)) catch |err| blk: {
        if (err == error.FileNotFound) break :blk null;
        return err;
    };
    defer if (rnames) |r| alloc.free(r);
    const rips = dir.readFileAlloc(io, ips_file, alloc, .limited(1 << 20)) catch |err| blk: {
        if (err == error.FileNotFound) break :blk null;
        return err;
    };
    defer if (rips) |r| alloc.free(r);
    if (rnames == null and rips == null) return null;
    var db = BanDb.init(alloc);
    errdefer db.deinit();
    var skipped: usize = 0;
    if (rnames) |raw| {
        var names = try decodeNamesJson(alloc, raw, derive_offline);
        skipped += names.skipped_legacy;
        var it = names.rows.iterator();
        while (it.next()) |e| try db.names.put(e.key_ptr.*, e.value_ptr.*);
        names.rows.deinit();
    }
    if (rips) |raw| {
        var ips = try decodeIpsJson(alloc, raw);
        var it = ips.iterator();
        while (it.next()) |e| try db.ips.put(e.key_ptr.*, e.value_ptr.*);
        ips.deinit();
    }
    return .{ .db = db, .skipped_legacy = skipped };
}

/// Persist the whitelist (atomic replace). No world needed.
pub fn saveWhitelistFile(io: std.Io, dir: std.Io.Dir, alloc: std.mem.Allocator, wl: *const Whitelist) !void {
    const enc = try encodeWhitelistJson(alloc, wl);
    defer alloc.free(enc);
    try writeWhitelistFile(io, dir, enc);
}

/// Raw-bytes half of saveWhitelistFile (atomic replace). The server encodes
/// under wl_lock, then calls this after unlocking.
pub fn writeWhitelistFile(io: std.Io, dir: std.Io.Dir, bytes: []const u8) !void {
    try writeFileAtomic(io, dir, whitelist_tmp, whitelist_file, bytes);
}

/// Load `whitelist.json`. Null when absent (caller falls back to the legacy
/// DB row); corrupt files fail closed. Legacy name-only rows derive exact
/// UUIDs offline, else skip (counted) — the caller must warn so admins
/// re-add affected players.
pub fn loadWhitelistFile(io: std.Io, dir: std.Io.Dir, alloc: std.mem.Allocator, derive_offline: bool) !?DecodedWhitelist {
    const raw = dir.readFileAlloc(io, whitelist_file, alloc, .limited(1 << 20)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer alloc.free(raw);
    return try decodeWhitelistJson(alloc, raw, derive_offline);
}

test "ban db roundtrip (UUID identity)" {
    var db = BanDb.init(std.testing.allocator);
    defer db.deinit();
    var sb: [36]u8 = undefined;
    const steve = testUuid("Steve", &sb);
    try db.banUuid(&steve, "Steve", "griefing");
    try std.testing.expectEqualStrings("griefing", db.bannedUuid(&steve).?);
    // A different UUID never matches, even for the same display name
    // (renamed accounts keep their ban; recycled names don't inherit it).
    var ib: [36]u8 = undefined;
    const impostor = testUuid("Steve2", &ib);
    try std.testing.expect(db.bannedUuid(&impostor) == null);
    try db.banIp("1.2.3.4", "spam");
    try std.testing.expectEqualStrings("spam", db.bannedIp("1.2.3.4").?);
    try std.testing.expect(db.unbanUuid(&steve));
    try std.testing.expect(db.bannedUuid(&steve) == null);
    try std.testing.expect(!db.unbanUuid(&steve));
    // Re-ban for the roundtrip below (display name must survive too).
    try db.banUuid(&steve, "Steve", "griefing");
    const enc = try db.encode(std.testing.allocator);
    defer std.testing.allocator.free(enc);
    var db2 = try BanDb.decode(std.testing.allocator, enc);
    defer db2.deinit();
    try std.testing.expectEqualStrings("spam", db2.bannedIp("1.2.3.4").?);
    try std.testing.expectEqualStrings("griefing", db2.bannedUuid(&steve).?);
    try std.testing.expectEqualStrings("Steve", db2.names.get(steve[0..]).?.name);
}

/// Offline UUID for tests (mirrors the derivation login/resolution use).
fn testUuid(name: []const u8, out: *[36]u8) [36]u8 {
    uuid_mod.formatUuid(uuid_mod.offlineUuid(name), out);
    return out.*;
}

test "whitelist roundtrip (UUID identity)" {
    var wl = Whitelist.init(std.testing.allocator);
    defer wl.deinit();
    var sb: [36]u8 = undefined;
    const steve = testUuid("Steve", &sb);
    wl.enabled = true;
    try wl.add(&steve, "Steve");
    // A different UUID never matches, even with the same display name
    // (recycled-name hijack rejected at the containment check).
    var ib: [36]u8 = undefined;
    const impostor = testUuid("Steve2", &ib);
    try std.testing.expect(wl.contains(&steve));
    try std.testing.expect(!wl.contains(&impostor));
    try std.testing.expect(wl.remove(&steve));
    try std.testing.expect(!wl.contains(&steve));
    // Re-add refreshes the display name; enforcement still keys on UUID.
    try wl.add(&steve, "Stephen");
    try std.testing.expect(wl.contains(&steve));
    try std.testing.expectEqualStrings("Stephen", wl.rows.get(steve[0..]).?);
    const enc = try wl.encode(std.testing.allocator);
    defer std.testing.allocator.free(enc);
    var wl2 = try Whitelist.decode(std.testing.allocator, enc);
    defer wl2.deinit();
    try std.testing.expect(wl2.enabled);
    try std.testing.expect(wl2.contains(&steve));
    try std.testing.expectEqualStrings("Stephen", wl2.rows.get(steve[0..]).?);
    // v1 (name-keyed) bytes are rejected, not misread
    {
        const v1 = [_]u8{ 'Z', 'W', 'L', '_', 1, 1, 0, 0, 0, 1, 5, 'a', 'l', 'i', 'c', 'e' };
        var r_v1 = Whitelist.decode(std.testing.allocator, &v1);
        if (r_v1) |*bad| {
            bad.deinit();
            try std.testing.expect(false);
        } else |err| {
            try std.testing.expect(err == error.Corrupt);
        }
    }
}

test "bans/whitelist json roundtrip incl corrupt rejection" {
    const a = std.testing.allocator;
    var db = BanDb.init(a);
    defer db.deinit();
    var sbuf: [36]u8 = undefined;
    const steve = testUuid("Steve", &sbuf);
    try db.banUuid(&steve, "Steve", "griefing \"quoted\"");
    try db.banIp("1.2.3.4", "spam");
    const enc = try encodeBansJson(a, &db);
    defer a.free(enc.names);
    defer a.free(enc.ips);
    // names part: uuid + display + reason preserved through JSON escaping
    var names = try decodeNamesJson(a, enc.names, true);
    defer {
        var it = names.rows.iterator();
        while (it.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.name);
            a.free(e.value_ptr.reason);
        }
        names.rows.deinit();
    }
    try std.testing.expectEqual(@as(usize, 0), names.skipped_legacy);
    try std.testing.expectEqualStrings("griefing \"quoted\"", names.rows.get(steve[0..]).?.reason);
    try std.testing.expectEqualStrings("Steve", names.rows.get(steve[0..]).?.name);
    var ips = try decodeIpsJson(a, enc.ips);
    defer {
        var it = ips.iterator();
        while (it.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.*);
        }
        ips.deinit();
    }
    try std.testing.expectEqualStrings("spam", ips.get("1.2.3.4").?);
    // deterministic bytes (sorted keys)
    const enc2 = try encodeBansJson(a, &db);
    defer a.free(enc2.names);
    defer a.free(enc2.ips);
    try std.testing.expectEqualSlices(u8, enc.names, enc2.names);
    try std.testing.expectEqualSlices(u8, enc.ips, enc2.ips);
    // whitelist envelope
    var wl = Whitelist.init(a);
    defer wl.deinit();
    wl.enabled = true;
    var ebuf: [36]u8 = undefined;
    const alice = testUuid("Alice", &ebuf);
    try wl.add(&alice, "Alice");
    const wenc = try encodeWhitelistJson(a, &wl);
    defer a.free(wenc);
    var wl2 = try decodeWhitelistJson(a, wenc, true);
    defer wl2.wl.deinit();
    try std.testing.expect(wl2.wl.enabled);
    try std.testing.expect(wl2.wl.contains(&alice));
    try std.testing.expectEqual(@as(usize, 0), wl2.skipped_legacy);
    // corrupt inputs rejected (legacy name-only rows decode via the
    // legacy path instead — see the whitelist legacy tests above)
    for ([_][]const u8{
        "not json",
        "[",
        "{}",
        "[{\"uuid\":\"nope\",\"name\":\"Nope\",\"reason\":\"x\"}]",
        "[{\"uuid\":\"00000000-0000-4000-8000-00000000000\",\"name\":\"Nope\",\"reason\":\"x\"}]",
        "[{\"uuid\":\"00000000-0000-4000-8000-00000000000a\",\"reason\":\"x\"}]",
        "[{\"uuid\":\"00000000-0000-4000-8000-00000000000a\",\"name\":\"\",\"reason\":\"x\"}]",
        "[{\"uuid\":\"00000000-0000-4000-8000-00000000000a\",\"name\":\"0123456789abcdefg\",\"reason\":\"x\"}]",
        "[{\"uuid\":\"00000000-0000-4000-8000-00000000000a\",\"name\":\"Bad Name\",\"reason\":\"x\"}]",
        "[{\"uuid\":\"00000000-0000-4000-8000-00000000000a\",\"name\":\"a\"},{\"uuid\":\"00000000-0000-4000-8000-00000000000A\",\"name\":\"b\"}]",
    }) |bad| {
        var r = decodeNamesJson(a, bad, true);
        if (r) |*m| {
            var it = m.rows.iterator();
            while (it.next()) |e| {
                a.free(e.key_ptr.*);
                a.free(e.value_ptr.name);
                a.free(e.value_ptr.reason);
            }
            m.rows.deinit();
            try std.testing.expect(false);
        } else |err| {
            try std.testing.expect(err == error.Corrupt);
        }
    }
    // legacy name-only rows derive offline, skip online (counted)
    var leg_boff = try decodeNamesJson(a, "[{\"name\":\"Old\",\"reason\":\"x\"}]", true);
    defer {
        var it = leg_boff.rows.iterator();
        while (it.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.name);
            a.free(e.value_ptr.reason);
        }
        leg_boff.rows.deinit();
    }
    try std.testing.expectEqual(@as(usize, 0), leg_boff.skipped_legacy);
    var obuf: [36]u8 = undefined;
    try std.testing.expectEqualStrings("x", leg_boff.rows.get(testUuid("Old", &obuf)[0..]).?.reason);
    var leg_bon = try decodeNamesJson(a, "[{\"name\":\"Old\",\"reason\":\"x\"}]", false);
    defer leg_bon.rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), leg_bon.skipped_legacy);
    try std.testing.expectEqual(@as(usize, 0), leg_bon.rows.count());
    for ([_][]const u8{
        "[{\"ip\":\"\",\"reason\":\"x\"}]",
        "[{\"ip\":\"1.2.3.4\"},{\"ip\":\"1.2.3.4\"}]",
    }) |bad| {
        var r = decodeIpsJson(a, bad);
        if (r) |*m| {
            var it = m.iterator();
            while (it.next()) |e| {
                a.free(e.key_ptr.*);
                a.free(e.value_ptr.*);
            }
            m.deinit();
            try std.testing.expect(false);
        } else |err| {
            try std.testing.expect(err == error.Corrupt);
        }
    }
    for ([_][]const u8{
        "[]",
        "{\"names\":[\"\"]}",
        "{\"names\":[\"Bad Name\"]}",
        "{\"entries\":[{\"uuid\":\"nope\",\"name\":\"Nope\"}]}",
        "{\"entries\":[{\"uuid\":\"00000000-0000-4000-8000-00000000000a\"}]}",
        "{\"entries\":[{\"uuid\":\"00000000-0000-4000-8000-00000000000a\",\"name\":\"A\"},{\"uuid\":\"00000000-0000-4000-8000-00000000000A\",\"name\":\"B\"}]}",
    }) |bad| {
        var r = decodeWhitelistJson(a, bad, true);
        if (r) |*w| {
            w.wl.deinit();
            try std.testing.expect(false);
        } else |err| {
            try std.testing.expect(err == error.Corrupt);
        }
    }
    // case-distinct legacy names derive distinct UUIDs (offline derivation
    // is case-sensitive, like login): two rows, not a dup rejection.
    var cased = try decodeWhitelistJson(a, "{\"names\":[\"a\",\"A\"]}", true);
    defer cased.wl.deinit();
    try std.testing.expectEqual(@as(usize, 2), cased.wl.rows.count());
    // missing optional fields decode as empty/default
    var lax = try decodeWhitelistJson(a, "{}", true);
    defer lax.wl.deinit();
    try std.testing.expect(!lax.wl.enabled);
    try std.testing.expectEqual(@as(usize, 0), lax.wl.rows.count());
    try std.testing.expectEqual(@as(usize, 0), lax.skipped_legacy);
    // legacy names[] derive offline (exact), skip online (counted)
    var leg_off = try decodeWhitelistJson(a, "{\"enabled\":true,\"names\":[\"Alice\"]}", true);
    defer leg_off.wl.deinit();
    try std.testing.expect(leg_off.wl.enabled);
    try std.testing.expectEqual(@as(usize, 0), leg_off.skipped_legacy);
    var abuf: [36]u8 = undefined;
    try std.testing.expect(leg_off.wl.contains(&testUuid("Alice", &abuf)));
    var leg_on = try decodeWhitelistJson(a, "{\"enabled\":true,\"names\":[\"Alice\"]}", false);
    defer leg_on.wl.deinit();
    try std.testing.expectEqual(@as(usize, 1), leg_on.skipped_legacy);
    try std.testing.expectEqual(@as(usize, 0), leg_on.wl.rows.count());
    // new-shape entries without uuid take the same legacy path
    var leg_new = try decodeWhitelistJson(a, "{\"entries\":[{\"name\":\"Bob\"}]}", true);
    defer leg_new.wl.deinit();
    var bbuf: [36]u8 = undefined;
    try std.testing.expect(leg_new.wl.contains(&testUuid("Bob", &bbuf)));
}

test "ban/whitelist file roundtrip" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = BanDb.init(a);
    defer db.deinit();
    var sbuf: [36]u8 = undefined;
    const steve = testUuid("Steve", &sbuf);
    try db.banUuid(&steve, "Steve", "griefing");
    try db.banIp("1.2.3.4", "spam");
    try saveBansFile(io, tmp.dir, a, &db);
    var back = (try loadBansFile(io, tmp.dir, a, true)).?;
    defer back.db.deinit();
    try std.testing.expectEqualStrings("griefing", back.db.bannedUuid(&steve).?);
    try std.testing.expectEqualStrings("spam", back.db.bannedIp("1.2.3.4").?);
    try std.testing.expectEqual(@as(usize, 0), back.skipped_legacy);
    var wl = Whitelist.init(a);
    defer wl.deinit();
    wl.enabled = true;
    var fbuf: [36]u8 = undefined;
    const alice = testUuid("Alice", &fbuf);
    try wl.add(&alice, "Alice");
    try saveWhitelistFile(io, tmp.dir, a, &wl);
    var loaded = (try loadWhitelistFile(io, tmp.dir, a, true)).?;
    defer loaded.wl.deinit();
    try std.testing.expect(loaded.wl.enabled);
    try std.testing.expect(loaded.wl.contains(&alice));
    try std.testing.expectEqual(@as(usize, 0), loaded.skipped_legacy);
    // missing files read as absent (caller migrates from the DB rows)
    try tmp.dir.deleteFile(io, players_file);
    try tmp.dir.deleteFile(io, ips_file);
    try tmp.dir.deleteFile(io, whitelist_file);
    try std.testing.expect(try loadBansFile(io, tmp.dir, a, true) == null);
    try std.testing.expect(try loadWhitelistFile(io, tmp.dir, a, true) == null);
    // half-present pair still loads (missing side is empty)
    var obuf: [36]u8 = undefined;
    const only = testUuid("Only", &obuf);
    try db.banUuid(&only, "Only", "names");
    try saveBansFile(io, tmp.dir, a, &db);
    try tmp.dir.deleteFile(io, ips_file);
    var half = (try loadBansFile(io, tmp.dir, a, true)).?;
    defer half.db.deinit();
    try std.testing.expect(half.db.bannedUuid(&only) != null);
    try std.testing.expect(half.db.bannedIp("1.2.3.4") == null);
}
