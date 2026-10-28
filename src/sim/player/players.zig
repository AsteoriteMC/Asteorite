//! Player persistence: position/inventory/health across restarts.
//!
//! Saves live in the same LSM pool as chunks under a reserved dimension
//! (`player_dim = 255`; real dims are small, Nether is -1 -> 255u8? No:
//! JoinGame dimension is i8 on the wire but ZC1 stores dim u8 with 0 =
//! overworld; no world code ever writes dim 255, so the keyspace is ours).
//! Key = encodeKey(255, hi32(hash), lo32(hash)) with Wyhash over the exact
//! login username bytes (case-sensitive, matching offline-UUID behavior).
//! The value carries the username for collision/mismatch detection.
//!
//! Locking: put/get go through ShardPool like chunks; callers hold
//! `world_lock` for save (same discipline as applyBlock) and need no lock
//! for load (login path is single-threaded per conn). Durability comes
//! from the WAL (kill -9 safe); `save-all`/stop/periodic flush SSTs.
//!
//! Format (versioned binary, magic "ZPLR" + u8 version): fixed-size scalars
//! (username + UUID), floats, slots, gamemode, XP. Decode rejects
//! truncated, overlong, version-skewed, and identity-mismatched rows.
//! big-endian, NBT stored verbatim (opaque, length-prefixed, -1 = none — same
//! convention as the 1.7 slot wire format). Slots store canonical `ids.Id`
//! values (v5). Decode rejects truncated, overlong, version-skewed, and
//! identity-mismatched payloads.

const std = @import("std");
const store_mod = @import("../../world/store.zig");
const shard_mod = @import("../../world/shard.zig");
const item_mod = @import("../../item.zig");
const ids = @import("../../ids.zig");
const rules_mod = @import("../../game/rules.zig");

pub const player_dim: u8 = 255;
pub const magic = "ZPLR";
/// v1/v2 predate this parser and are rejected (reimport from player.dat).
/// v3 introduced the current scalar layout but, due to the historical bug
/// fixed in C1, still wrote 1.7.10 **wire** ids; v4 appended xp + spawn_forced
/// on top of that. v3/v4 rows decode through an explicit `LegacySlotMap`.
/// v7 is what `encode` writes and stores canonical `ids.Id` slots plus the
/// row UUID and the 27-slot ender chest. v6 is identical minus the ender
/// section (decodes with an empty chest); v5 minus the UUID too.
pub const version: u8 = 7;

pub const uuid_len: usize = 36;
/// Player-inv slot count (window layout lives in item.zig).
pub const inv_size = item_mod.inv_size;
/// Ender-chest slot count (vanilla InventoryEnderChest, 27 slots, shared
/// across every ender chest like vanilla's per-player EnderItems).
pub const ender_size: usize = 27;
/// Player-name cap (matches login validation + the ops matrix).
pub const max_name_len: usize = 16;
/// Hotbar slot cap (selected 0..8).
pub const max_selected: u8 = 8;
/// Vanilla caps enforced on decode.
pub const max_health: f32 = 20;
pub const max_food: i16 = 20;
/// Opaque-NBT cap per slot (corrupt rows claim gigabytes otherwise).
pub const max_nbt_bytes: usize = 1024 * 1024;

/// Migration map for v3/v4 rows: 1.7.10 wire id -> canonical id. Supplied by
/// the import boundary (`world/import/player.zig`); the canonical core never
/// imports a protocol table itself.
pub const LegacySlotMap = *const fn (u16) ?ids.Id;

pub const Data = struct {
    username_len: usize = 0,
    username: [max_name_len]u8 = [_]u8{0} ** max_name_len,
    /// Authoritative identity (canonical lowercase hyphenated UUID string).
    /// Verified on load (UuidMismatch fails closed like UsernameMismatch);
    /// `username` above is display/last-seen only.
    uuid: [uuid_len]u8 = [_]u8{0} ** uuid_len,
    pos_x: f64 = 8.5,
    pos_y: f64 = 64.0,
    pos_z: f64 = 8.5,
    yaw: f32 = 0,
    pitch: f32 = 0,
    on_ground: bool = false,
    spawn_x: i32 = 8,
    spawn_y: i32 = 64,
    spawn_z: i32 = 8,
    health: f32 = 20.0,
    food: i16 = 20,
    saturation: f32 = 5.0,
    selected: u8 = 0,
    /// Effective gamemode. v1 rows lack the byte and decode with the
    /// old default (creative).
    gamemode: rules_mod.GameMode = .creative,
    /// Experience (v4; v3 rows decode to zeroes).
    xp_level: i32 = 0,
    xp_total: i32 = 0,
    xp_bar: f32 = 0,
    /// Personal spawn via /spawnpoint (false = world spawn).
    spawn_forced: bool = false,
    inv: [inv_size]?item_mod.Stack = [_]?item_mod.Stack{null} ** inv_size,
    cursor: ?item_mod.Stack = null,
    /// Ender-chest contents (v7; older rows decode to empty). Per-player,
    /// shared by every ender chest — never dropped on death or block break,
    /// exactly like vanilla's EnderItems.
    ender: [ender_size]?item_mod.Stack = [_]?item_mod.Stack{null} ** ender_size,
};

/// Free NBT owned by a loaded Data (stacks borrowed from encode are untouched
/// only if never loaded; load always dupes, so free is always safe).
pub fn freeData(alloc: std.mem.Allocator, d: *Data) void {
    for (&d.inv) |*s| item_mod.freeStack(alloc, s);
    item_mod.freeStack(alloc, &d.cursor);
    for (&d.ender) |*s| item_mod.freeStack(alloc, s);
}

/// Legacy name-keyed rows (pre-UUID): read during login migration only,
/// never written. Case-sensitive (exact login bytes, as originally stored).
pub fn keyFor(username: []const u8) store_mod.ChunkKey {
    return keyForBytes(username);
}

/// UUID-keyed row lookup (canonical lowercase hyphenated UUID string —
/// no parsing, no folding: the exact bytes login verified). Shares the
/// player_dim namespace with legacy name keys; cross-kind hash hits fail
/// closed at decode (UuidMismatch/UsernameMismatch), same as before.
pub fn keyForUuid(uuid: []const u8) store_mod.ChunkKey {
    return keyForBytes(uuid);
}

fn keyForBytes(id: []const u8) store_mod.ChunkKey {
    var h = std.hash.Wyhash.init(0);
    h.update(id);
    const v = h.final();
    return store_mod.encodeKey(
        player_dim,
        @as(i32, @bitCast(@as(u32, @truncate(v >> 32)))),
        @as(i32, @bitCast(@as(u32, @truncate(v)))),
    );
}

/// Take `n` bytes from the decode cursor (bounds-checked).
fn take(r: *[]const u8, n: usize) LoadError![]const u8 {
    if (r.len < n) return error.CorruptPlayer;
    const s = r.*[0..n];
    r.* = r.*[n..];
    return s;
}

pub fn encode(alloc: std.mem.Allocator, d: *const Data) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(magic);
    try w.writeByte(version);
    try w.writeByte(@intCast(d.username_len));
    try w.writeAll(d.username[0..d.username_len]);
    try w.writeAll(d.uuid[0..]);
    try w.writeInt(u64, @bitCast(d.pos_x), .big);
    try w.writeInt(u64, @bitCast(d.pos_y), .big);
    try w.writeInt(u64, @bitCast(d.pos_z), .big);
    try w.writeInt(u32, @bitCast(d.yaw), .big);
    try w.writeInt(u32, @bitCast(d.pitch), .big);
    try w.writeByte(if (d.on_ground) 1 else 0);
    try w.writeInt(i32, d.spawn_x, .big);
    try w.writeInt(i32, d.spawn_y, .big);
    try w.writeInt(i32, d.spawn_z, .big);
    try w.writeInt(u32, @bitCast(d.health), .big);
    try w.writeInt(i16, d.food, .big);
    try w.writeInt(u32, @bitCast(d.saturation), .big);
    try w.writeByte(d.selected);
    for (d.inv) |s| try writeSlot(w, s);
    try writeSlot(w, d.cursor);
    try w.writeByte(d.gamemode.wire());
    try w.writeInt(i32, d.xp_level, .big);
    try w.writeInt(i32, d.xp_total, .big);
    try w.writeInt(u32, @bitCast(d.xp_bar), .big);
    try w.writeByte(if (d.spawn_forced) 1 else 0);
    // Ender chest tail (v7): appended last so every earlier byte offset —
    // and every legacy vector built by excising UUID bytes — is unchanged.
    // An empty chest is exactly `ender_size` zero bytes, which is also what
    // the legacy-vector tests strip to reconstruct true pre-v7 layouts.
    for (d.ender) |s| try writeSlot(w, s);
    return aw.toOwnedSlice();
}

fn writeSlot(w: *std.Io.Writer, s: ?item_mod.Stack) !void {
    const st = s orelse return w.writeByte(0);
    try w.writeByte(1);
    // v5 stores the canonical ids.Id; only pre-C1 v3/v4 rows held wire ids.
    try w.writeInt(u16, @intFromEnum(st.id), .big);
    try w.writeByte(@bitCast(st.count));
    try w.writeInt(i16, st.damage, .big);
    const nb = st.nbt orelse return w.writeInt(i32, -1, .big);
    try w.writeInt(i32, @intCast(nb.len), .big);
    try w.writeAll(nb);
}

pub const LoadError = error{ CorruptPlayer, UsernameMismatch, UuidMismatch };

pub fn decode(alloc: std.mem.Allocator, bytes: []const u8, expect_username: []const u8, expect_uuid: []const u8) (LoadError || std.mem.Allocator.Error)!Data {
    return decodeInner(alloc, bytes, expect_username, expect_uuid, null);
}

/// Decode a legacy v3/v4 row by mapping its 1.7.10 wire slot ids through
/// `legacy`. v5+ rows ignore `legacy` (their slots are already canonical);
/// v3/v4 without a mapper are rejected rather than guessed. Pre-v7 rows
/// decode with an empty ender chest (the section did not exist yet).
pub fn decodeLegacy(alloc: std.mem.Allocator, bytes: []const u8, expect_username: []const u8, expect_uuid: []const u8, legacy: LegacySlotMap) (LoadError || std.mem.Allocator.Error)!Data {
    return decodeInner(alloc, bytes, expect_username, expect_uuid, legacy);
}

fn decodeInner(alloc: std.mem.Allocator, bytes: []const u8, expect_username: []const u8, expect_uuid: []const u8, legacy: ?LegacySlotMap) (LoadError || std.mem.Allocator.Error)!Data {
    var d = Data{};
    errdefer freeData(alloc, &d);
    var r = bytes;
    if (!std.mem.eql(u8, try take(&r, 4), magic)) return error.CorruptPlayer;
    const ver = (try take(&r, 1))[0];
    // v7 stores canonical ids.Id plus the row UUID and the ender chest.
    // v6 is identical minus the ender section (decodes with an empty
    // chest). v5 minus the UUID too (adopted on read). v3/v4 stored
    // 1.7.10 wire ids and need the explicit migration map; v1/v2 predate
    // this parser (reimport instead).
    if (ver != version and ver != 6 and ver != 5 and ver != 4 and ver != 3) return error.CorruptPlayer;
    const needs_map = ver == 3 or ver == 4;
    if (needs_map and legacy == null) return error.CorruptPlayer;
    const ulen: usize = (try take(&r, 1))[0];
    if (ulen == 0 or ulen > max_name_len) return error.CorruptPlayer;
    const uname = try take(&r, ulen);
    if (ver >= 6) {
        // UUID-bound rows verify identity, not the (stale-able) name.
        const stored = try take(&r, uuid_len);
        if (!std.mem.eql(u8, stored, expect_uuid)) return error.UuidMismatch;
    } else {
        // Legacy rows verify the name (unchanged semantics); the caller
        // adopts the row under the login UUID afterwards.
        if (!std.mem.eql(u8, uname, expect_username)) return error.UsernameMismatch;
    }
    d.username_len = ulen;
    @memcpy(d.username[0..ulen], uname);
    @memcpy(d.uuid[0..], expect_uuid);
    d.pos_x = @bitCast(std.mem.readInt(u64, (try take(&r, 8))[0..8], .big));
    d.pos_y = @bitCast(std.mem.readInt(u64, (try take(&r, 8))[0..8], .big));
    d.pos_z = @bitCast(std.mem.readInt(u64, (try take(&r, 8))[0..8], .big));
    d.yaw = @bitCast(std.mem.readInt(u32, (try take(&r, 4))[0..4], .big));
    d.pitch = @bitCast(std.mem.readInt(u32, (try take(&r, 4))[0..4], .big));
    d.on_ground = (try take(&r, 1))[0] != 0;
    d.spawn_x = std.mem.readInt(i32, (try take(&r, 4))[0..4], .big);
    d.spawn_y = std.mem.readInt(i32, (try take(&r, 4))[0..4], .big);
    d.spawn_z = std.mem.readInt(i32, (try take(&r, 4))[0..4], .big);
    d.health = @bitCast(std.mem.readInt(u32, (try take(&r, 4))[0..4], .big));
    d.food = std.mem.readInt(i16, (try take(&r, 2))[0..2], .big);
    d.saturation = @bitCast(std.mem.readInt(u32, (try take(&r, 4))[0..4], .big));
    d.selected = (try take(&r, 1))[0];
    if (d.selected > max_selected) return error.CorruptPlayer;
    if (!std.math.isFinite(d.pos_x) or !std.math.isFinite(d.pos_y) or !std.math.isFinite(d.pos_z)) return error.CorruptPlayer;
    if (!std.math.isFinite(d.health) or d.health < 0 or d.health > max_health) return error.CorruptPlayer;
    if (d.food < 0 or d.food > max_food) return error.CorruptPlayer;
    if (!std.math.isFinite(d.saturation) or d.saturation < 0) return error.CorruptPlayer;
    for (&d.inv) |*s| s.* = try readSlot(alloc, &r, if (needs_map) legacy else null);
    d.cursor = try readSlot(alloc, &r, if (needs_map) legacy else null);
    const gm_wire = (try take(&r, 1))[0];
    if (gm_wire > 1) return error.CorruptPlayer;
    d.gamemode = @enumFromInt(gm_wire);
    if (ver >= 4) {
        d.xp_level = std.mem.readInt(i32, (try take(&r, 4))[0..4], .big);
        d.xp_total = std.mem.readInt(i32, (try take(&r, 4))[0..4], .big);
        d.xp_bar = @bitCast(std.mem.readInt(u32, (try take(&r, 4))[0..4], .big));
        d.spawn_forced = (try take(&r, 1))[0] != 0;
        if (d.xp_level < 0 or d.xp_total < 0) return error.CorruptPlayer;
        if (!std.math.isFinite(d.xp_bar) or d.xp_bar < 0 or d.xp_bar > 1) return error.CorruptPlayer;
    }
    if (ver >= 7) {
        for (&d.ender) |*s| s.* = try readSlot(alloc, &r, null);
    }
    if (r.len != 0) return error.CorruptPlayer;
    return d;
}

fn readSlot(alloc: std.mem.Allocator, r: *[]const u8, legacy: ?LegacySlotMap) (LoadError || std.mem.Allocator.Error)!?item_mod.Stack {
    if ((try take(r, 1))[0] == 0) return null;
    const raw_id = std.mem.readInt(u16, (try take(r, 2))[0..2], .big);
    const count: i8 = @bitCast((try take(r, 1))[0]);
    const damage = std.mem.readInt(i16, (try take(r, 2))[0..2], .big);
    const nlen = std.mem.readInt(i32, (try take(r, 4))[0..4], .big);
    if (nlen < -1) return error.CorruptPlayer;
    // id 0 is air: only legal as an empty slot, never as a stack.
    // v5 payloads are canonical; v3/v4 payloads are wire ids and must be
    // translated through the migration map (never guessed).
    const id: ids.Id = if (legacy) |map|
        map(raw_id) orelse return error.CorruptPlayer
    else blk: {
        if (@as(usize, raw_id) >= ids.COUNT) return error.CorruptPlayer;
        break :blk @enumFromInt(raw_id);
    };
    if (id == ids.air) return error.CorruptPlayer;
    if (nlen == -1) return .{ .id = id, .count = count, .damage = damage, .nbt = null };
    if (nlen > max_nbt_bytes) return error.CorruptPlayer;
    const nb = try take(r, @intCast(nlen));
    const owned = try alloc.dupe(u8, nb);
    return .{ .id = id, .count = count, .damage = damage, .nbt = owned };
}

/// Store one player's Data under their UUID. Caller holds world_lock (same
/// as applyBlock). Stamps the row UUID from the key (callers may pass a
/// Data whose display name is fresh but whose uuid field is stale).
pub fn save(pool: *shard_mod.ShardPool, uuid: []const u8, d: *Data) !void {
    std.debug.assert(uuid.len == uuid_len);
    @memcpy(d.uuid[0..], uuid);
    const enc = try encode(pool.allocator, d);
    defer pool.allocator.free(enc);
    try pool.put(keyForUuid(uuid), enc);
}

/// Load one player's canonical Data (owned NBT; free with freeData).
/// Null = no save. UuidMismatch is treated as absent (a hash hit on
/// someone else's row — vanishingly unlikely, but never trust a key alone).
pub fn load(pool: *shard_mod.ShardPool, alloc: std.mem.Allocator, uuid: []const u8) !?Data {
    return loadInner(pool, alloc, null, uuid, null);
}

/// Like `load`, but also adopts legacy name-keyed rows (v3/v4/v5/v6, created
/// before UUID binding) on first sight: the row is verified by name,
/// re-keyed under the login UUID, and the legacy row deleted (one-shot —
/// a recycled name can never re-adopt it afterwards). The runtime login
/// path uses this; v7 rows ignore `legacy`/`username` except for display.
pub fn loadLegacy(pool: *shard_mod.ShardPool, alloc: std.mem.Allocator, username: []const u8, uuid: []const u8, legacy: LegacySlotMap) !?Data {
    return loadInner(pool, alloc, username, uuid, legacy);
}

fn loadInner(pool: *shard_mod.ShardPool, alloc: std.mem.Allocator, username: ?[]const u8, uuid: []const u8, legacy: ?LegacySlotMap) !?Data {
    const raw = try pool.get(alloc, keyForUuid(uuid));
    if (raw) |bytes| {
        defer alloc.free(bytes);
        return decodeInner(alloc, bytes, username orelse "", uuid, legacy) catch |err| switch (err) {
            error.UuidMismatch, error.UsernameMismatch => null,
            else => |e| e,
        };
    }
    // No UUID row: adopt a legacy same-name row once (see loadLegacy).
    const lname = username orelse return null;
    const lraw = try pool.get(alloc, keyFor(lname));
    if (lraw == null) return null;
    defer alloc.free(lraw.?);
    var d = decodeInner(alloc, lraw.?, lname, uuid, legacy) catch |err| switch (err) {
        error.UuidMismatch, error.UsernameMismatch => return null,
        else => |e| return e,
    };
    errdefer freeData(alloc, &d);
    try save(pool, uuid, &d);
    try pool.delete(keyFor(lname));
    return d;
}

/// Fixed test UUID (v6 rows require one; content is arbitrary).
fn tu() [36]u8 {
    return "00000000-0000-4000-8000-000000000001".*;
}

test "player roundtrip incl NBT, cursor, selected, spawn" {
    const a = std.testing.allocator;
    var d = Data{};
    @memcpy(d.username[0.."Bo".len], "Bo");
    d.username_len = 2;
    const u = tu();
    d.uuid = u;
    d.pos_x = -12.5;
    d.pos_y = 70.0;
    d.pos_z = 44.25;
    d.yaw = 90.0;
    d.pitch = -15.0;
    d.on_ground = true;
    d.spawn_x = 8;
    d.spawn_y = 70;
    d.spawn_z = 8;
    d.health = 13.5;
    d.food = 17;
    d.saturation = 3.25;
    d.selected = 4;
    d.gamemode = .survival;
    const tag = [_]u8{ 0x0A, 0x00, 0x03, 0x64, 0x75, 0x6D };
    d.inv[36] = .{ .id = ids.diamond_sword, .count = 1, .damage = 0, .nbt = &tag };
    d.inv[10] = .{ .id = ids.stone, .count = 64, .damage = 0, .nbt = null };
    d.cursor = .{ .id = ids.dirt, .count = 5, .damage = 0, .nbt = null };
    d.ender[0] = .{ .id = ids.obsidian, .count = 8, .damage = 0, .nbt = null };
    d.ender[26] = .{ .id = ids.diamond, .count = 64, .damage = 0, .nbt = &tag };
    const enc = try encode(a, &d);
    defer a.free(enc);
    var back = try decode(a, enc, "Bo", &u);
    defer freeData(a, &back);
    try std.testing.expectEqualStrings("Bo", back.username[0..back.username_len]);
    try std.testing.expectEqual(u, back.uuid);
    try std.testing.expectApproxEqAbs(-12.5, back.pos_x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 90.0), back.yaw, 1e-6);
    try std.testing.expect(back.on_ground);
    try std.testing.expectEqual(@as(i32, 8), back.spawn_x);
    try std.testing.expectApproxEqAbs(@as(f32, 13.5), back.health, 1e-6);
    try std.testing.expectEqual(@as(i16, 17), back.food);
    try std.testing.expectEqual(@as(u8, 4), back.selected);
    try std.testing.expect(back.gamemode == .survival);
    try std.testing.expect(item_mod.stacksEqual(d.inv[36], back.inv[36]));
    try std.testing.expect(back.inv[36].?.nbt.?.ptr != tag[0..].ptr);
    try std.testing.expect(item_mod.stacksEqual(d.cursor, back.cursor));
    try std.testing.expect(back.inv[0] == null);
    try std.testing.expect(item_mod.stacksEqual(d.ender[0], back.ender[0]));
    try std.testing.expect(item_mod.stacksEqual(d.ender[26], back.ender[26]));
    try std.testing.expect(back.ender[26].?.nbt.?.ptr != tag[0..].ptr);
    try std.testing.expect(back.ender[1] == null);
}

fn fakeLegacySlot(w: u16) ?ids.Id {
    return switch (w) {
        1 => .stone,
        999 => .diamond_sword,
        else => null,
    };
}

test "player v1/v2 rows are rejected; v3/v4 need the legacy mapper" {
    const a = std.testing.allocator;
    var d = Data{};
    @memcpy(d.username[0.."Al".len], "Al");
    d.username_len = 2;
    d.gamemode = .survival;
    const u = tu();
    d.uuid = u;
    const enc = try encode(a, &d);
    defer a.free(enc);
    // Downgrade to v1 on the wire (and snip a tail byte so it cannot be
    // mistaken for the current layout).
    const v1 = try a.alloc(u8, enc.len - 1);
    defer a.free(v1);
    @memcpy(v1, enc[0 .. enc.len - 1]);
    v1[4] = 1;
    var r_v1 = decode(a, v1, "Al", &u);
    if (r_v1) |*b| {
        freeData(a, b);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expect(err == error.CorruptPlayer);
    }
    // v2 payloads (also wire ids) are rejected too.
    const v2 = try a.dupe(u8, enc);
    defer a.free(v2);
    v2[4] = 2;
    var r_v2 = decode(a, v2, "Al", &u);
    if (r_v2) |*b| {
        freeData(a, b);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expect(err == error.CorruptPlayer);
    }
    // v3/v4 are pre-C1 wire-id rows: without the explicit legacy mapper the
    // decoder rejects them instead of misreading wire ids as canonical.
    for ([_]u8{ 3, 4 }) |legacy_ver| {
        const row = try a.dupe(u8, enc);
        defer a.free(row);
        row[4] = legacy_ver;
        var r = decode(a, row, "Al", &u);
        if (r) |*b| {
            freeData(a, b);
            try std.testing.expect(false);
        } else |err| {
            try std.testing.expect(err == error.CorruptPlayer);
        }
    }
    // garbage gamemode rejected (7 = neither survival nor creative).
    // The tail is gamemode + xp_level/total/bar + spawn_forced + the v7
    // ender section (empty here: 27 zero bytes, stripped nowhere).
    const bad = try a.dupe(u8, enc);
    defer a.free(bad);
    bad[bad.len - 14 - ender_size] = 7;
    var r_bad = decode(a, bad, "Al", &u);
    if (r_bad) |*b| {
        freeData(a, b);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expect(err == error.CorruptPlayer);
    }
    // UUID mismatch fails closed (wrong row, right name).
    var other = tu();
    other[35] = '2';
    var r_uuid = decode(a, enc, "Al", &other);
    if (r_uuid) |*b| {
        freeData(a, b);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expect(err == error.UuidMismatch);
    }
}

test "v4/v3 rows decode through the injected legacy mapper" {
    const a = std.testing.allocator;
    var d = Data{};
    @memcpy(d.username[0.."Al".len], "Al");
    d.username_len = 2;
    d.inv[0] = .{ .id = .stone, .count = 64, .damage = 0, .nbt = null };
    d.inv[36] = .{ .id = .diamond_sword, .count = 1, .damage = 0, .nbt = null };
    const u = tu();
    d.uuid = u;
    const enc = try encode(a, &d);
    defer a.free(enc);
    // True v4 layout: excise the v6 UUID field (magic 4 + ver 1 + namelen
    // 1 + name 2 = 8 header bytes, then 36 uuid bytes) and strip the v7
    // ender tail (empty here: exactly `ender_size` zero bytes), relabel.
    const v4 = try a.alloc(u8, enc.len - uuid_len - ender_size);
    defer a.free(v4);
    @memcpy(v4[0..8], enc[0..8]);
    @memcpy(v4[8..], enc[8 + uuid_len .. enc.len - ender_size]);
    v4[4] = 4;
    // Header before inv[0] is 4 magic + 1 version + 1 name length + 2 name
    // + 24 pos + 8 rotation + 1 ground + 12 spawn + 4 health + 2 food
    // + 4 saturation + 1 selected = 64 bytes. inv[0] is 1+2+1+2+4 = 10 bytes
    // and slots 1..35 are one empty byte each, so inv[36]'s id is at 110.
    std.mem.writeInt(u16, v4[65..][0..2], 1, .big); // stone wire
    std.mem.writeInt(u16, v4[110..][0..2], 999, .big); // diamond_sword wire
    var back = try decodeLegacy(a, v4, "Al", &u, fakeLegacySlot);
    defer freeData(a, &back);
    try std.testing.expectEqual(ids.stone, back.inv[0].?.id);
    try std.testing.expectEqual(@as(i8, 64), back.inv[0].?.count);
    try std.testing.expectEqual(ids.diamond_sword, back.inv[36].?.id);
    // Adopted rows carry the login UUID (the v4 bytes hold no identity).
    try std.testing.expectEqual(u, back.uuid);
    // v3 rows (no xp tail) default xp/spawn_forced instead of requiring it.
    const v3 = try a.dupe(u8, v4[0 .. v4.len - 13]);
    defer a.free(v3);
    v3[4] = 3;
    var back3 = try decodeLegacy(a, v3, "Al", &u, fakeLegacySlot);
    defer freeData(a, &back3);
    try std.testing.expectEqual(ids.stone, back3.inv[0].?.id);
    try std.testing.expectEqual(@as(i32, 0), back3.xp_level);
    try std.testing.expect(!back3.spawn_forced);
    // Unmapped wire ids are rejected, not stored as canonical guesses.
    const bad = try a.dupe(u8, v4);
    defer a.free(bad);
    std.mem.writeInt(u16, bad[65..][0..2], 176, .big);
    try std.testing.expectError(error.CorruptPlayer, decodeLegacy(a, bad, "Al", &u, fakeLegacySlot));
}

test "player decode rejects corrupt/truncated/mismatched" {
    const a = std.testing.allocator;
    var d = Data{};
    @memcpy(d.username[0.."Al".len], "Al");
    d.username_len = 2;
    const zu: [36]u8 = [_]u8{0} ** 36;
    const enc = try encode(a, &d);
    defer a.free(enc);
    // truncated
    var r_trunc = decode(a, enc[0 .. enc.len - 3], "Al", &zu);
    if (r_trunc) |*bad| {
        freeData(a, bad);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expect(err == error.CorruptPlayer);
    }
    // bad magic
    {
        const mut = try a.dupe(u8, enc);
        defer a.free(mut);
        mut[0] = 'X';
        var r_mut: @TypeOf(decode(a, mut, "Al", &zu)) = decode(a, mut, "Al", &zu);
        if (r_mut) |*bad| {
            freeData(a, bad);
            try std.testing.expect(false);
        } else |err| {
            try std.testing.expect(err == error.CorruptPlayer);
        }
    }
    // v7 rows verify UUID, not the (stale-able) display name: a renamed
    // login still loads its row.
    var r_rename = decode(a, enc, "Bo", &zu);
    if (r_rename) |*renamed| {
        defer freeData(a, renamed);
        try std.testing.expectEqualStrings("Al", renamed.username[0..renamed.username_len]);
    } else |_| {
        try std.testing.expect(false);
    }
    // ...but a wrong UUID fails closed even with the right name.
    var other: [36]u8 = [_]u8{0} ** 36;
    other[35] = 7;
    var r_uuid = decode(a, enc, "Al", &other);
    if (r_uuid) |*bad| {
        freeData(a, bad);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expect(err == error.UuidMismatch);
    }
    // legacy (pre-uuid) rows still verify the name: excise the v6 UUID
    // field and strip the v7 ender tail for a true v5 layout, then
    // mismatch the name.
    {
        const v5 = try a.alloc(u8, enc.len - uuid_len - ender_size);
        defer a.free(v5);
        @memcpy(v5[0..8], enc[0..8]);
        @memcpy(v5[8..], enc[8 + uuid_len .. enc.len - ender_size]);
        v5[4] = 5;
        var r_mm = decode(a, v5, "Bo", &zu);
        if (r_mm) |*bad| {
            freeData(a, bad);
            try std.testing.expect(false);
        } else |err| {
            try std.testing.expect(err == error.UsernameMismatch);
        }
    }
    // trailing garbage
    {
        const grown = try a.alloc(u8, enc.len + 1);
        defer a.free(grown);
        @memcpy(grown[0..enc.len], enc);
        grown[enc.len] = 0;
        var r_grown = decode(a, grown, "Al", &zu);
        if (r_grown) |*bad| {
            freeData(a, bad);
            try std.testing.expect(false);
        } else |err| {
            try std.testing.expect(err == error.CorruptPlayer);
        }
    }
    // id 0 stack rejected
    {
        const mut = try a.dupe(u8, enc);
        defer a.free(mut);
        // first slot (inv[0], offset after header) to present with id 0:
        // header len = 8 + 36 uuid; then pos(24)+yaw/pitch(8)+ground(1)+
        // spawn(12)+health(4)+food(2)+sat(4)+selected(1) = 56; inv[0] at
        // 8+36+56=100.
        mut[100] = 1;
        mut[101] = 0;
        mut[102] = 0;
        var r_mut: @TypeOf(decode(a, mut, "Al", &zu)) = decode(a, mut, "Al", &zu);
        if (r_mut) |*bad| {
            freeData(a, bad);
            try std.testing.expect(false);
        } else |err| {
            try std.testing.expect(err == error.CorruptPlayer);
        }
    }
}

test "login migrates legacy name rows to UUID once" {
    // Pre-UUID v5 row under the name key; first login adopts it (uuid row
    // created with identical bytes, legacy row deleted); later logins read
    // the UUID row directly. A recycled name can never re-adopt the
    // deleted row afterwards.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    var d = Data{};
    @memcpy(d.username[0.."Mig".len], "Mig");
    d.username_len = 3;
    d.pos_x = 11.5;
    const u = tu();
    const enc = try encode(a, &d);
    defer a.free(enc);
    // True v5 layout: excise the v6 UUID field (header is magic 4 + ver 1
    // + namelen 1 + name bytes, then 36 uuid bytes) and strip the v7
    // ender tail (empty here: exactly `ender_size` zero bytes).
    const hlen: usize = 4 + 1 + 1 + d.username_len;
    const v5 = try a.alloc(u8, enc.len - uuid_len - ender_size);
    defer a.free(v5);
    @memcpy(v5[0..hlen], enc[0..hlen]);
    @memcpy(v5[hlen..], enc[hlen + uuid_len .. enc.len - ender_size]);
    v5[4] = 5;
    try pool.put(keyFor("Mig"), v5);
    // First login: adopts (same bytes, uuid filled) and deletes legacy.
    var first = try loadLegacy(pool, a, "Mig", &u, fakeLegacySlot);
    defer if (first) |*f| freeData(a, f);
    try std.testing.expect(first != null);
    try std.testing.expectApproxEqAbs(@as(f64, 11.5), first.?.pos_x, 1e-9);
    try std.testing.expectEqual(u, first.?.uuid);
    {
        const gone = try pool.get(a, keyFor("Mig"));
        defer if (gone) |g| a.free(g);
        try std.testing.expect(gone == null);
    }
    {
        const uw = try pool.get(a, keyForUuid(&u));
        defer if (uw) |w| a.free(w);
        try std.testing.expect(uw != null);
    }
    // Second login: uuid path, no migration involved.
    var second = try loadLegacy(pool, a, "Mig", &u, fakeLegacySlot);
    defer if (second) |*s| freeData(a, s);
    try std.testing.expect(second != null);
    try std.testing.expectApproxEqAbs(@as(f64, 11.5), second.?.pos_x, 1e-9);
    // Another UUID never sees the row (rename-evasion and recycling both
    // fail closed).
    var other = tu();
    other[35] = 9;
    try std.testing.expect(try loadLegacy(pool, a, "Mig", &other, fakeLegacySlot) == null);
}

test "v6 rows decode with an empty ender chest" {
    // Live v6 rows (pre-ender) keep loading after the v7 bump; the chest
    // defaults empty and the next savePlayer persists the row as v7.
    const a = std.testing.allocator;
    var d = Data{};
    @memcpy(d.username[0.."Al".len], "Al");
    d.username_len = 2;
    d.inv[0] = .{ .id = .stone, .count = 64, .damage = 0, .nbt = null };
    const u = tu();
    d.uuid = u;
    const enc = try encode(a, &d);
    defer a.free(enc);
    const v6 = try a.alloc(u8, enc.len - ender_size);
    defer a.free(v6);
    @memcpy(v6, enc[0 .. enc.len - ender_size]);
    v6[4] = 6;
    var back = try decode(a, v6, "Al", &u);
    defer freeData(a, &back);
    try std.testing.expectEqual(ids.stone, back.inv[0].?.id);
    for (back.ender) |s| try std.testing.expect(s == null);
}

test "player keys stable + distinct" {
    const k1 = keyFor("Steve");
    const k2 = keyFor("Steve");
    try std.testing.expectEqualSlices(u8, &k1, &k2);
    try std.testing.expectEqual(player_dim, k1[0]);
    const k3 = keyFor("steve");
    try std.testing.expect(!std.mem.eql(u8, &k1, &k3));
    // UUID keys: stable per UUID, distinct across UUIDs (and across the
    // legacy name namespace only by hash chance, as before).
    const uu1 = "00000000-0000-4000-8000-000000000001";
    const uu2 = "00000000-0000-4000-8000-000000000002";
    try std.testing.expectEqualSlices(u8, &keyForUuid(uu1), &keyForUuid(uu1));
    try std.testing.expect(!std.mem.eql(u8, &keyForUuid(uu1), &keyForUuid(uu2)));
}
