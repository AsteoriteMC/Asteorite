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
//! big-endian, NBT stored verbatim (opaque, length-prefixed, -1 = none — same
//! convention as the 1.7 slot wire format). Slots store canonical `ids.Id`
//! values (v5). Decode rejects truncated, overlong, version-skewed, and
//! username-mismatched payloads.

const std = @import("std");
const store_mod = @import("../world/store.zig");
const shard_mod = @import("../world/shard.zig");
const item_mod = @import("../item.zig");
const ids = @import("../ids.zig");
const rules_mod = @import("../game/rules.zig");

pub const player_dim: u8 = 255;
pub const magic = "ZPLR";
/// v1/v2 predate this parser and are rejected (reimport from player.dat).
/// v3 introduced the current scalar layout but, due to the historical bug
/// fixed in C1, still wrote 1.7.10 **wire** ids; v4 appended xp + spawn_forced
/// on top of that. v3/v4 rows decode through an explicit `LegacySlotMap`.
/// v5 is what `encode` writes and stores canonical `ids.Id` slots.
pub const version: u8 = 5;
pub const inv_size = 45;

/// Migration map for v3/v4 rows: 1.7.10 wire id -> canonical id. Supplied by
/// the import boundary (`world/import/player.zig`); the canonical core never
/// imports a protocol table itself.
pub const LegacySlotMap = *const fn (u16) ?ids.Id;

pub const Data = struct {
    username_len: usize = 0,
    username: [16]u8 = [_]u8{0} ** 16,
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
};

/// Free NBT owned by a loaded Data (stacks borrowed from encode are untouched
/// only if never loaded; load always dupes, so free is always safe).
pub fn freeData(alloc: std.mem.Allocator, d: *Data) void {
    for (&d.inv) |*s| item_mod.freeStack(alloc, s);
    item_mod.freeStack(alloc, &d.cursor);
}

pub fn keyFor(username: []const u8) store_mod.ChunkKey {
    var h = std.hash.Wyhash.init(0);
    h.update(username);
    const v = h.final();
    return store_mod.encodeKey(
        player_dim,
        @as(i32, @bitCast(@as(u32, @truncate(v >> 32)))),
        @as(i32, @bitCast(@as(u32, @truncate(v)))),
    );
}

fn slotSize(s: ?item_mod.Stack) usize {
    const st = s orelse return 1;
    return 1 + 2 + 1 + 2 + 4 + (if (st.nbt) |n| n.len else 0);
}

pub fn encode(alloc: std.mem.Allocator, d: *const Data) ![]u8 {
    var n: usize = 4 + 1 + 1 + d.username_len + 8 * 3 + 4 * 2 + 1 + 4 * 3 + 4 + 2 + 4 + 1;
    for (d.inv) |s| n += slotSize(s);
    n += slotSize(d.cursor);
    n += 1; // v2 trailing gamemode
    n += 4 + 4 + 4 + 1; // v4 xp_level, xp_total, xp_bar, spawn_forced
    const out = try alloc.alloc(u8, n);
    errdefer alloc.free(out);
    var i: usize = 0;
    @memcpy(out[i..][0..4], magic);
    i += 4;
    out[i] = version;
    i += 1;
    out[i] = @intCast(d.username_len);
    i += 1;
    @memcpy(out[i..][0..d.username_len], d.username[0..d.username_len]);
    i += d.username_len;
    std.mem.writeInt(u64, out[i..][0..8], @bitCast(d.pos_x), .big);
    i += 8;
    std.mem.writeInt(u64, out[i..][0..8], @bitCast(d.pos_y), .big);
    i += 8;
    std.mem.writeInt(u64, out[i..][0..8], @bitCast(d.pos_z), .big);
    i += 8;
    std.mem.writeInt(u32, out[i..][0..4], @bitCast(d.yaw), .big);
    i += 4;
    std.mem.writeInt(u32, out[i..][0..4], @bitCast(d.pitch), .big);
    i += 4;
    out[i] = if (d.on_ground) 1 else 0;
    i += 1;
    std.mem.writeInt(i32, out[i..][0..4], d.spawn_x, .big);
    i += 4;
    std.mem.writeInt(i32, out[i..][0..4], d.spawn_y, .big);
    i += 4;
    std.mem.writeInt(i32, out[i..][0..4], d.spawn_z, .big);
    i += 4;
    std.mem.writeInt(u32, out[i..][0..4], @bitCast(d.health), .big);
    i += 4;
    std.mem.writeInt(i16, out[i..][0..2], d.food, .big);
    i += 2;
    std.mem.writeInt(u32, out[i..][0..4], @bitCast(d.saturation), .big);
    i += 4;
    out[i] = d.selected;
    i += 1;
    for (d.inv) |s| i = writeSlot(out, i, s);
    i = writeSlot(out, i, d.cursor);
    out[i] = d.gamemode.wire();
    i += 1;
    std.mem.writeInt(i32, out[i..][0..4], d.xp_level, .big);
    i += 4;
    std.mem.writeInt(i32, out[i..][0..4], d.xp_total, .big);
    i += 4;
    std.mem.writeInt(u32, out[i..][0..4], @bitCast(d.xp_bar), .big);
    i += 4;
    out[i] = if (d.spawn_forced) 1 else 0;
    i += 1;
    std.debug.assert(i == n);
    return out;
}

fn writeSlot(out: []u8, i: usize, s: ?item_mod.Stack) usize {
    var j = i;
    const st = s orelse {
        out[j] = 0;
        return j + 1;
    };
    out[j] = 1;
    j += 1;
    // v5 stores the canonical ids.Id; only pre-C1 v3/v4 rows held wire ids.
    std.mem.writeInt(u16, out[j..][0..2], @intFromEnum(st.id), .big);
    j += 2;
    out[j] = @bitCast(st.count);
    j += 1;
    std.mem.writeInt(i16, out[j..][0..2], st.damage, .big);
    j += 2;
    if (st.nbt) |nb| {
        std.mem.writeInt(i32, out[j..][0..4], @intCast(nb.len), .big);
        j += 4;
        @memcpy(out[j..][0..nb.len], nb);
        j += nb.len;
    } else {
        std.mem.writeInt(i32, out[j..][0..4], -1, .big);
        j += 4;
    }
    return j;
}

pub const LoadError = error{ CorruptPlayer, UsernameMismatch };

pub fn decode(alloc: std.mem.Allocator, bytes: []const u8, expect_username: []const u8) (LoadError || std.mem.Allocator.Error)!Data {
    return decodeInner(alloc, bytes, expect_username, null);
}

/// Decode a legacy v3/v4 row by mapping its 1.7.10 wire slot ids through
/// `legacy`. v5 rows ignore `legacy` (their slots are already canonical);
/// v3/v4 without a mapper are rejected rather than guessed.
pub fn decodeLegacy(alloc: std.mem.Allocator, bytes: []const u8, expect_username: []const u8, legacy: LegacySlotMap) (LoadError || std.mem.Allocator.Error)!Data {
    return decodeInner(alloc, bytes, expect_username, legacy);
}

fn decodeInner(alloc: std.mem.Allocator, bytes: []const u8, expect_username: []const u8, legacy: ?LegacySlotMap) (LoadError || std.mem.Allocator.Error)!Data {
    var d = Data{};
    errdefer freeData(alloc, &d);
    var r = bytes;
    const take = struct {
        fn run(b: *[]const u8, n: usize) LoadError![]const u8 {
            if (b.len < n) return error.CorruptPlayer;
            const s = b.*[0..n];
            b.* = b.*[n..];
            return s;
        }
    }.run;
    if (!std.mem.eql(u8, try take(&r, 4), magic)) return error.CorruptPlayer;
    const ver = (try take(&r, 1))[0];
    // v5 stores canonical ids.Id. v3/v4 stored 1.7.10 wire ids and need the
    // explicit migration map; v1/v2 predate this parser (reimport instead).
    if (ver != version and ver != 3 and ver != 4) return error.CorruptPlayer;
    const legacy_row = ver != version;
    if (legacy_row and legacy == null) return error.CorruptPlayer;
    const ulen: usize = (try take(&r, 1))[0];
    if (ulen == 0 or ulen > 16) return error.CorruptPlayer;
    const uname = try take(&r, ulen);
    if (!std.mem.eql(u8, uname, expect_username)) return error.UsernameMismatch;
    d.username_len = ulen;
    @memcpy(d.username[0..ulen], uname);
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
    if (d.selected > 8) return error.CorruptPlayer;
    if (!std.math.isFinite(d.pos_x) or !std.math.isFinite(d.pos_y) or !std.math.isFinite(d.pos_z)) return error.CorruptPlayer;
    if (!std.math.isFinite(d.health) or d.health < 0 or d.health > 20) return error.CorruptPlayer;
    if (d.food < 0 or d.food > 20) return error.CorruptPlayer;
    if (!std.math.isFinite(d.saturation) or d.saturation < 0) return error.CorruptPlayer;
    for (&d.inv) |*s| s.* = try readSlot(alloc, &r, take, if (legacy_row) legacy else null);
    d.cursor = try readSlot(alloc, &r, take, if (legacy_row) legacy else null);
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
    if (r.len != 0) return error.CorruptPlayer;
    return d;
}

fn readSlot(alloc: std.mem.Allocator, r: *[]const u8, take: fn (*[]const u8, usize) LoadError![]const u8, legacy: ?LegacySlotMap) (LoadError || std.mem.Allocator.Error)!?item_mod.Stack {
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
    if (nlen > 1024 * 1024) return error.CorruptPlayer;
    const nb = try take(r, @intCast(nlen));
    const owned = try alloc.dupe(u8, nb);
    return .{ .id = id, .count = count, .damage = damage, .nbt = owned };
}

/// Store one player's Data. Caller holds world_lock (same as applyBlock).
pub fn save(pool: *shard_mod.ShardPool, username: []const u8, d: *const Data) !void {
    const enc = try encode(pool.allocator, d);
    defer pool.allocator.free(enc);
    try pool.put(keyFor(username), enc);
}

/// Load one player's canonical Data (owned NBT; free with freeData).
/// Null = no save. UsernameMismatch is treated as absent (a hash hit on
/// someone else's row — vanishingly unlikely, but never trust a key alone).
pub fn load(pool: *shard_mod.ShardPool, alloc: std.mem.Allocator, username: []const u8) !?Data {
    return loadInner(pool, alloc, username, null);
}

/// Like `load`, but also accepts legacy v3/v4 rows by translating their wire
/// slot ids through `legacy` (see `LegacySlotMap`). The runtime login path
/// uses this so pre-C1 saves keep loading; v5 rows are unaffected.
pub fn loadLegacy(pool: *shard_mod.ShardPool, alloc: std.mem.Allocator, username: []const u8, legacy: LegacySlotMap) !?Data {
    return loadInner(pool, alloc, username, legacy);
}

fn loadInner(pool: *shard_mod.ShardPool, alloc: std.mem.Allocator, username: []const u8, legacy: ?LegacySlotMap) !?Data {
    const raw = try pool.get(alloc, keyFor(username));
    if (raw == null) return null;
    defer alloc.free(raw.?);
    return decodeInner(alloc, raw.?, username, legacy) catch |err| switch (err) {
        error.UsernameMismatch => null,
        else => |e| e,
    };
}

test "player roundtrip incl NBT, cursor, selected, spawn" {
    const a = std.testing.allocator;
    var d = Data{};
    @memcpy(d.username[0.."Bo".len], "Bo");
    d.username_len = 2;
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
    const enc = try encode(a, &d);
    defer a.free(enc);
    var back = try decode(a, enc, "Bo");
    defer freeData(a, &back);
    try std.testing.expectEqualStrings("Bo", back.username[0..back.username_len]);
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
    const enc = try encode(a, &d);
    defer a.free(enc);
    // Downgrade to v1 on the wire (and snip a tail byte so it cannot be
    // mistaken for the current layout).
    const v1 = try a.alloc(u8, enc.len - 1);
    defer a.free(v1);
    @memcpy(v1, enc[0 .. enc.len - 1]);
    v1[4] = 1;
    var r_v1 = decode(a, v1, "Al");
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
    var r_v2 = decode(a, v2, "Al");
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
        var r = decode(a, row, "Al");
        if (r) |*b| {
            freeData(a, b);
            try std.testing.expect(false);
        } else |err| {
            try std.testing.expect(err == error.CorruptPlayer);
        }
    }
    // garbage gamemode rejected (7 = neither survival nor creative).
    // The tail is gamemode + xp_level/total/bar + spawn_forced.
    const bad = try a.dupe(u8, enc);
    defer a.free(bad);
    bad[bad.len - 14] = 7;
    var r_bad = decode(a, bad, "Al");
    if (r_bad) |*b| {
        freeData(a, b);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expect(err == error.CorruptPlayer);
    }
}

test "v4/v3 rows decode through the injected legacy mapper" {
    const a = std.testing.allocator;
    var d = Data{};
    @memcpy(d.username[0.."Al".len], "Al");
    d.username_len = 2;
    d.inv[0] = .{ .id = .stone, .count = 64, .damage = 0, .nbt = null };
    d.inv[36] = .{ .id = .diamond_sword, .count = 1, .damage = 0, .nbt = null };
    const enc = try encode(a, &d);
    defer a.free(enc);
    const v4 = try a.dupe(u8, enc);
    defer a.free(v4);
    v4[4] = 4;
    // Header before inv[0] is 4 magic + 1 version + 1 name length + 2 name
    // + 24 pos + 8 rotation + 1 ground + 12 spawn + 4 health + 2 food
    // + 4 saturation + 1 selected = 64 bytes. inv[0] is 1+2+1+2+4 = 10 bytes
    // and slots 1..35 are one empty byte each, so inv[36]'s id is at 110.
    std.mem.writeInt(u16, v4[65..][0..2], 1, .big); // stone wire
    std.mem.writeInt(u16, v4[110..][0..2], 999, .big); // diamond_sword wire
    var back = try decodeLegacy(a, v4, "Al", fakeLegacySlot);
    defer freeData(a, &back);
    try std.testing.expectEqual(ids.stone, back.inv[0].?.id);
    try std.testing.expectEqual(@as(i8, 64), back.inv[0].?.count);
    try std.testing.expectEqual(ids.diamond_sword, back.inv[36].?.id);
    // v3 rows (no xp tail) default xp/spawn_forced instead of requiring it.
    const v3 = try a.dupe(u8, v4[0 .. v4.len - 13]);
    defer a.free(v3);
    v3[4] = 3;
    var back3 = try decodeLegacy(a, v3, "Al", fakeLegacySlot);
    defer freeData(a, &back3);
    try std.testing.expectEqual(ids.stone, back3.inv[0].?.id);
    try std.testing.expectEqual(@as(i32, 0), back3.xp_level);
    try std.testing.expect(!back3.spawn_forced);
    // Unmapped wire ids are rejected, not stored as canonical guesses.
    const bad = try a.dupe(u8, v4);
    defer a.free(bad);
    std.mem.writeInt(u16, bad[65..][0..2], 176, .big);
    try std.testing.expectError(error.CorruptPlayer, decodeLegacy(a, bad, "Al", fakeLegacySlot));
}

test "player decode rejects corrupt/truncated/mismatched" {
    const a = std.testing.allocator;
    var d = Data{};
    @memcpy(d.username[0.."Al".len], "Al");
    d.username_len = 2;
    const enc = try encode(a, &d);
    defer a.free(enc);
    // truncated
    var r_trunc = decode(a, enc[0 .. enc.len - 3], "Al");
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
        var r_mut: @TypeOf(decode(a, mut, "Al")) = decode(a, mut, "Al");
        if (r_mut) |*bad| {
            freeData(a, bad);
            try std.testing.expect(false);
        } else |err| {
            try std.testing.expect(err == error.CorruptPlayer);
        }
    }
    // username mismatch
    var r_mm = decode(a, enc, "Bo");
    if (r_mm) |*bad| {
        freeData(a, bad);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expect(err == error.UsernameMismatch);
    }
    // trailing garbage
    {
        const grown = try a.alloc(u8, enc.len + 1);
        defer a.free(grown);
        @memcpy(grown[0..enc.len], enc);
        grown[enc.len] = 0;
        var r_grown = decode(a, grown, "Al");
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
        // header len = 4+1+1+2 = 8; then pos(24)+yaw/pitch(8)+ground(1)+
        // spawn(12)+health(4)+food(2)+sat(4)+selected(1) = 56; inv[0] at 8+56=64.
        mut[64] = 1;
        mut[65] = 0;
        mut[66] = 0;
        var r_mut: @TypeOf(decode(a, mut, "Al")) = decode(a, mut, "Al");
        if (r_mut) |*bad| {
            freeData(a, bad);
            try std.testing.expect(false);
        } else |err| {
            try std.testing.expect(err == error.CorruptPlayer);
        }
    }
}

test "player keys stable + distinct" {
    const k1 = keyFor("Steve");
    const k2 = keyFor("Steve");
    try std.testing.expectEqualSlices(u8, &k1, &k2);
    try std.testing.expectEqual(player_dim, k1[0]);
    const k3 = keyFor("steve");
    try std.testing.expect(!std.mem.eql(u8, &k1, &k3));
}
