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
//! Format (versioned binary, "ZPLR"+1): fixed-size scalars big-endian,
//! NBT stored verbatim (opaque, length-prefixed, -1 = none — same
//! convention as the 1.7 slot wire format). Decode rejects truncated,
//! overlong, version-skewed, and username-mismatched payloads.

const std = @import("std");
const store_mod = @import("../world/store.zig");
const shard_mod = @import("../world/shard.zig");
const item_mod = @import("../item.zig");
const nbt_mod = @import("../world/nbt.zig");
const ids = @import("../ids.zig");

pub const player_dim: u8 = 255;
pub const magic = "ZPLR";
/// v2 adds trailing gamemode (v1 rows decode with gamemode defaulting to 1).
pub const version: u8 = 2;
pub const inv_size = 45;

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
    /// Effective gamemode (0 survival, 1 creative). v1 rows lack the byte
    /// and decode with the old default (creative).
    gamemode: u8 = 1,
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
    out[i] = d.gamemode;
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
    std.mem.writeInt(u16, out[j..][0..2], st.id, .big);
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
    if (ver != 1 and ver != version) return error.CorruptPlayer;
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
    for (&d.inv) |*s| s.* = try readSlot(alloc, &r, take);
    d.cursor = try readSlot(alloc, &r, take);
    if (ver == 1) {
        if (r.len != 0) return error.CorruptPlayer;
        return d; // gamemode stays at the v1 default (creative)
    }
    d.gamemode = (try take(&r, 1))[0];
    if (d.gamemode > 1) return error.CorruptPlayer;
    if (r.len != 0) return error.CorruptPlayer;
    return d;
}

fn readSlot(alloc: std.mem.Allocator, r: *[]const u8, take: fn (*[]const u8, usize) LoadError![]const u8) (LoadError || std.mem.Allocator.Error)!?item_mod.Stack {
    if ((try take(r, 1))[0] == 0) return null;
    const id = std.mem.readInt(u16, (try take(r, 2))[0..2], .big);
    const count: i8 = @bitCast((try take(r, 1))[0]);
    const damage = std.mem.readInt(i16, (try take(r, 2))[0..2], .big);
    const nlen = std.mem.readInt(i32, (try take(r, 4))[0..4], .big);
    if (nlen < -1) return error.CorruptPlayer;
    // id 0 is air: only legal as an empty slot, never as a stack.
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

/// Load one player's Data (owned NBT; free with freeData). Null = no save.
/// UsernameMismatch is treated as absent (a hash hit on someone else's row —
/// vanishingly unlikely, but never trust a key alone).
pub fn load(pool: *shard_mod.ShardPool, alloc: std.mem.Allocator, username: []const u8) !?Data {
    const raw = try pool.get(keyFor(username));
    if (raw == null) return null;
    defer alloc.free(raw.?);
    return decode(alloc, raw.?, username) catch |err| switch (err) {
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
    d.gamemode = 0;
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
    try std.testing.expectEqual(@as(u8, 0), back.gamemode);
    try std.testing.expect(item_mod.stacksEqual(d.inv[36], back.inv[36]));
    try std.testing.expect(back.inv[36].?.nbt.?.ptr != tag[0..].ptr);
    try std.testing.expect(item_mod.stacksEqual(d.cursor, back.cursor));
    try std.testing.expect(back.inv[0] == null);
}

test "player v1 rows decode with gamemode default" {
    const a = std.testing.allocator;
    var d = Data{};
    @memcpy(d.username[0.."Al".len], "Al");
    d.username_len = 2;
    d.gamemode = 0;
    const enc = try encode(a, &d);
    defer a.free(enc);
    // Downgrade to v1 on the wire: version byte 1, drop trailing gamemode.
    const v1 = try a.alloc(u8, enc.len - 1);
    defer a.free(v1);
    @memcpy(v1, enc[0 .. enc.len - 1]);
    v1[4] = 1;
    var back = try decode(a, v1, "Al");
    defer freeData(a, &back);
    try std.testing.expectEqual(@as(u8, 1), back.gamemode);
    // v2 garbage gamemode rejected (2 = neither survival nor creative).
    const bad = try a.dupe(u8, enc);
    defer a.free(bad);
    bad[bad.len - 1] = 7;
    var r_bad = decode(a, bad, "Al");
    if (r_bad) |*b| {
        freeData(a, b);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expect(err == error.CorruptPlayer);
    }
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

// ---------------------------------------------------------------------------
// Vanilla 1.7.10 player.dat import (Anvil home-world migration).
// ---------------------------------------------------------------------------
// Field mapping verified against CFR 0.152 decompiles of the official
// 1.7.10 server jar (see notes): Entity.a/b (sa: Pos/Rotation 3d+2f,
// FallDistance f, Fire/Air short, OnGround bool, Dimension int,
// PortalCooldown int, UUIDMost/Least long), EntityLivingBase.a/b (sv:
// HealF float preferred, else Health float-or-short), FoodStats.a/b (zr:
// lowercase foodLevel int, foodTickTimer int, foodSaturationLevel float,
// foodExhaustionLevel float), EntityPlayer.a/b (yz: Inventory list of
// compounds Slot byte 0-35 main / 100-103 armor, SelectedItemSlot int,
// SpawnX/Y/Z int + SpawnForced, XpLevel/XpTotal, EnderItems),
// EntityPlayerMP.a/b (mw: playerGameType int), ItemStack.a (add:
// id short, Count byte, Damage short, optional tag compound).
//
// Dropped on the floor (documented): Motion, FallDistance, Fire, Air,
// PortalCooldown, Invulnerable, UUID, Score, XP, food timers/exhaustion,
// EnderItems (no ender chest yet), crafting grid (vanilla doesn't save
// it either), cursor (vanilla saves none). Out-of-range gamemodes clamp
// to survival; only gamemode 0/1 exist here.

pub const ImportStats = struct {
    /// Inventory entries whose Slot byte maps nowhere (vanilla only emits
    /// 0-35/100-103, but be liberal on read).
    unknown_slots: usize = 0,
    /// Entries dropped for bad id (<=0) or Count (<=0).
    dropped_stacks: usize = 0,
    /// True when no SpawnX/Y/Z trio was present (spawn falls back to pos).
    defaulted_spawn: bool = true,
    /// Player.dat Dimension (we always land the import in dim 0).
    dimension: i32 = 0,
};

pub const VanillaError = nbt_mod.NbtError || std.mem.Allocator.Error || error{ BadUsername };

fn validImportName(name: []const u8) bool {
    // Mirrors conn.validPlayerName (kept local: players.zig must not import
    // the whole connection stack for one charset check).
    if (name.len == 0 or name.len > 16) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// Convert decompressed (gunzip already applied by the caller) vanilla
/// 1.7.10 player.dat NBT into canonical Data. NBT `tag` compounds are
/// preserved byte-for-byte (owned). Never fails a whole file on one bad
/// scalar; structural corruption (truncation, bad tags) errors out.
pub fn fromVanillaNbt(alloc: std.mem.Allocator, nbt: []const u8, username: []const u8) !struct { data: Data, stats: ImportStats } {
    if (!validImportName(username)) return error.BadUsername;
    var d = Data{};
    var stats = ImportStats{};
    errdefer freeData(alloc, &d);
    d.username_len = username.len;
    @memcpy(d.username[0..username.len], username);
    var r = nbt_mod.Reader.init(nbt);
    _ = try r.readRoot();
    var have_healf = false;
    var health_short: ?f32 = null;
    var sx: ?i32 = null;
    var sy: ?i32 = null;
    var sz: ?i32 = null;
    while (true) {
        const t = try r.readTagType();
        if (t == .end) break;
        const name = try r.readString();
        if (std.mem.eql(u8, name, "Pos")) {
            if (t == .list) {
                const elem = try r.readTagType();
                const len = try r.readBE(i32);
                if (elem == .double and len == 3) {
                    d.pos_x = try r.readDouble();
                    d.pos_y = try r.readDouble();
                    d.pos_z = try r.readDouble();
                } else {
                    // Wrong shape: skip element-by-element.
                    var i: i32 = 0;
                    while (i < len) : (i += 1) try r.skipPayload(elem);
                }
            } else try r.skipPayload(t);
        } else if (std.mem.eql(u8, name, "Rotation")) {
            if (t == .list) {
                const elem = try r.readTagType();
                const len = try r.readBE(i32);
                if (elem == .float and len == 2) {
                    d.yaw = try r.readFloat();
                    d.pitch = try r.readFloat();
                } else {
                    var i: i32 = 0;
                    while (i < len) : (i += 1) try r.skipPayload(elem);
                }
            } else try r.skipPayload(t);
        } else if (std.mem.eql(u8, name, "OnGround")) {
            if (t == .byte) d.on_ground = (try r.readByte()) != 0 else try r.skipPayload(t);
        } else if (std.mem.eql(u8, name, "Health")) {
            // Legacy short-or-float form (HealF preferred; see below).
            if (t == .float) {
                health_short = try r.readFloat();
            } else if (t == .short) {
                health_short = @floatFromInt(try r.readBE(i16));
            } else try r.skipPayload(t);
        } else if (std.mem.eql(u8, name, "HealF")) {
            if (t == .float) {
                d.health = try r.readFloat();
                have_healf = true;
            } else try r.skipPayload(t);
        } else if (std.mem.eql(u8, name, "foodLevel")) {
            if (t == .int) {
                const v = try r.readBE(i32);
                d.food = @intCast(@max(0, @min(@as(i32, 20), v)));
            } else try r.skipPayload(t);
        } else if (std.mem.eql(u8, name, "foodSaturationLevel")) {
            if (t == .float) {
                d.saturation = @max(0.0, try r.readFloat());
            } else try r.skipPayload(t);
        } else if (std.mem.eql(u8, name, "playerGameType")) {
            if (t == .int) {
                d.gamemode = if ((try r.readBE(i32)) == 1) 1 else 0;
            } else try r.skipPayload(t);
        } else if (std.mem.eql(u8, name, "SpawnX")) {
            if (t == .int) sx = try r.readBE(i32) else try r.skipPayload(t);
        } else if (std.mem.eql(u8, name, "SpawnY")) {
            if (t == .int) sy = try r.readBE(i32) else try r.skipPayload(t);
        } else if (std.mem.eql(u8, name, "SpawnZ")) {
            if (t == .int) sz = try r.readBE(i32) else try r.skipPayload(t);
        } else if (std.mem.eql(u8, name, "SelectedItemSlot")) {
            if (t == .int) {
                const v = try r.readBE(i32);
                d.selected = if (v >= 0 and v <= 8) @intCast(v) else 0;
            } else try r.skipPayload(t);
        } else if (std.mem.eql(u8, name, "Dimension")) {
            if (t == .int) stats.dimension = try r.readBE(i32) else try r.skipPayload(t);
        } else if (std.mem.eql(u8, name, "Inventory")) {
            try readVanillaInventory(alloc, &r, t, &d, &stats);
        } else {
            try r.skipPayload(t);
        }
    }
    if (!have_healf) {
        if (health_short) |h| d.health = @min(@as(f32, 20.0), @max(0.0, h));
    } else {
        d.health = @min(@as(f32, 20.0), @max(0.0, d.health));
    }
    if (!std.math.isFinite(d.pos_x) or !std.math.isFinite(d.pos_y) or !std.math.isFinite(d.pos_z)) {
        d.pos_x = 8.5;
        d.pos_y = 64.0;
        d.pos_z = 8.5;
    }
    if (sx != null and sy != null and sz != null) {
        d.spawn_x = sx.?;
        d.spawn_y = sy.?;
        d.spawn_z = sz.?;
        stats.defaulted_spawn = false;
    } else {
        d.spawn_x = @intFromFloat(@floor(d.pos_x));
        d.spawn_y = @intFromFloat(@floor(d.pos_y));
        d.spawn_z = @intFromFloat(@floor(d.pos_z));
    }
    return .{ .data = d, .stats = stats };
}

/// Player.dat Inventory list: compounds with Slot byte, id short, Count
/// byte, Damage short, optional tag compound. Maps vanilla main 0-8 to
/// hotbar window slots 36-44, main 9-35 to window 9-35, armor 100-103 to
/// window 5-8. Anything else counts as an unknown slot.
fn readVanillaInventory(alloc: std.mem.Allocator, r: *nbt_mod.Reader, outer: nbt_mod.TagType, d: *Data, stats: *ImportStats) !void {
    if (outer != .list) {
        try r.skipPayload(outer);
        return;
    }
    const elem = try r.readTagType();
    const len = try r.readBE(i32);
    if (len < 0) return nbt_mod.NbtError.InvalidTag;
    if (elem != .compound) {
        var i: i32 = 0;
        while (i < len) : (i += 1) try r.skipPayload(elem);
        return;
    }
    var i: i32 = 0;
    while (i < len) : (i += 1) {
        // List elements are bare compounds (no name).
        var id: i32 = 0;
        var count: i8 = 0;
        var damage: i16 = 0;
        var slot: ?u8 = null;
        var nbt: ?[]const u8 = null;
        errdefer if (nbt) |n| alloc.free(n);
        while (true) {
            const t = try r.readTagType();
            if (t == .end) break;
            const fname = try r.readString();
            if (std.mem.eql(u8, fname, "Slot")) {
                if (t == .byte) slot = try r.readByte() else try r.skipPayload(t);
            } else if (std.mem.eql(u8, fname, "id")) {
                if (t == .short) id = try r.readBE(i16) else try r.skipPayload(t);
            } else if (std.mem.eql(u8, fname, "Count")) {
                if (t == .byte) count = @bitCast(try r.readByte()) else try r.skipPayload(t);
            } else if (std.mem.eql(u8, fname, "Damage")) {
                if (t == .short) damage = try r.readBE(i16) else try r.skipPayload(t);
            } else if (std.mem.eql(u8, fname, "tag")) {
                if (t == .compound) {
                    nbt = try alloc.dupe(u8, try r.readRawCompound());
                } else try r.skipPayload(t);
            } else {
                try r.skipPayload(t);
            }
        }
        const s = slot orelse {
            stats.dropped_stacks += 1;
            continue;
        };
        if (id <= 0 or count <= 0) {
            stats.dropped_stacks += 1;
            continue;
        }
        const dst: ?usize = if (s < 9) @as(usize, 36 + s) else if (s < 36) @as(usize, s) else if (s >= 100 and s < 104) @as(usize, 5 + (s - 100)) else null;
        const di = dst orelse {
            stats.unknown_slots += 1;
            continue;
        };
        // Duplicate slots in one file: last wins (vanilla overwrites too).
        item_mod.freeStack(alloc, &d.inv[di]);
        d.inv[di] = .{ .id = @intCast(id), .count = count, .damage = damage, .nbt = nbt };
        nbt = null; // owned by the slot now
    }
}

test "vanilla player.dat golden (official 1.7.10 server)" {
    const a = std.testing.allocator;
    const blob = @embedFile("testdata/vanilla_player.dat");
    const plain = try nbt_mod.gunzipAlloc(a, blob);
    defer a.free(plain);
    const imp = try fromVanillaNbt(a, plain, "Steve");
    var d = imp.data;
    defer freeData(a, &d);
    // Fixture provenance: official 1.7.10 server.jar (sha256 pinned in
    // testdata/README), offline mode, gamemode=creative Steve: creative
    // gave 64 dirt, renamed diamond sword via 0x10 with NBT, walked to
    // +X, disconnected. See testdata/README for the exact session script.
    // NOTE: vanilla ignored the teleport (moved-too-quickly guard), so the
    // row holds the login spawn, not x=100.5.
    try std.testing.expectApproxEqAbs(@as(f64, -116.5), d.pos_x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 69.0), d.pos_y, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 250.5), d.pos_z, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), d.yaw, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), d.pitch, 1e-6);
    try std.testing.expect(!d.on_ground);
    try std.testing.expectEqual(@as(u8, 1), d.gamemode);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), d.health, 1e-6);
    try std.testing.expectEqual(@as(i16, 20), d.food);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), d.saturation, 1e-6);
    try std.testing.expectEqual(@as(u8, 0), d.selected);
    // no SpawnX/Y/Z in the fixture (no bed): spawn falls back to pos.
    try std.testing.expect(imp.stats.defaulted_spawn);
    try std.testing.expectEqual(@as(i32, -117), d.spawn_x);
    try std.testing.expectEqual(@as(i32, 69), d.spawn_y);
    try std.testing.expectEqual(@as(i32, 250), d.spawn_z);
    // stone in hotbar slot 0 -> window 36
    try std.testing.expectEqual(@as(u16, 1), d.inv[36].?.id);
    try std.testing.expectEqual(@as(i8, 64), d.inv[36].?.count);
    try std.testing.expectEqual(@as(i16, 0), d.inv[36].?.damage);
    try std.testing.expect(d.inv[36].?.nbt == null);
    // renamed sword keeps its tag bytes verbatim (NBT round-trips opaque)
    const sword = d.inv[37].?;
    try std.testing.expectEqual(@as(u16, 276), sword.id);
    try std.testing.expectEqual(@as(i8, 1), sword.count);
    const want_tag = [_]u8{ 0x0A, 0x00, 0x07, 'd', 'i', 's', 'p', 'l', 'a', 'y', 0x08, 0x00, 0x04, 'N', 'a', 'm', 'e', 0x00, 0x02, 'H', 'i', 0x00, 0x00 };
    try std.testing.expectEqualSlices(u8, &want_tag, sword.nbt.?);
    try std.testing.expect(imp.stats.unknown_slots == 0);
    try std.testing.expect(imp.stats.dropped_stacks == 0);
    // ZPLR round-trips the import (the store path is format-agnostic).
    const enc = try encode(a, &d);
    defer a.free(enc);
    var back = try decode(a, enc, "Steve");
    defer freeData(a, &back);
    try std.testing.expect(item_mod.stacksEqual(d.inv[37], back.inv[37]));
    try std.testing.expect(back.inv[37].?.nbt.?[0..back.inv[37].?.nbt.?.len].ptr != sword.nbt.?.ptr);
}

test "vanilla spawn trio fallback + synthetic edge cases" {
    const a = std.testing.allocator;
    // Minimal synthetic root: Pos only, no spawn trio, no health/food keys.
    // (Labeled synthetic: exercises fallback branches the golden file's
    // full fixture doesn't hit.)
    var buf: [256]u8 = undefined;
    var w: usize = 0;
    buf[w] = 10;
    w += 1; // TAG_Compound root
    buf[w] = 0;
    buf[w + 1] = 0;
    w += 2; // empty name
    // Pos: list of 3 doubles (tag + u16 name + element type + count)
    buf[w] = 9;
    w += 1;
    std.mem.writeInt(u16, buf[w..][0..2], 3, .big);
    w += 2;
    @memcpy(buf[w..][0..3], "Pos");
    w += 3;
    buf[w] = 6;
    w += 1;
    std.mem.writeInt(i32, buf[w..][0..4], 3, .big);
    w += 4;
    for ([_]f64{ 10.5, 65.0, -3.25 }) |v| {
        std.mem.writeInt(u64, buf[w..][0..8], @bitCast(v), .big);
        w += 8;
    }
    buf[w] = 0;
    w += 1; // TAG_End
    var imp = try fromVanillaNbt(a, buf[0..w], "Al");
    defer freeData(a, &imp.data);
    try std.testing.expectApproxEqAbs(@as(f64, 10.5), imp.data.pos_x, 1e-9);
    try std.testing.expect(imp.stats.defaulted_spawn);
    try std.testing.expectEqual(@as(i32, 10), imp.data.spawn_x);
    try std.testing.expectEqual(@as(i32, 65), imp.data.spawn_y);
    try std.testing.expectEqual(@as(i32, -4), imp.data.spawn_z);
    // Bad username rejected before touching NBT.
    var r_bad = fromVanillaNbt(a, buf[0..w], "has space");
    if (r_bad) |*bad| {
        freeData(a, &bad.data);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expect(err == error.BadUsername);
    }
}

