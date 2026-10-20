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
    if (id == 0) return error.CorruptPlayer;
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
    d.inv[36] = .{ .id = 276, .count = 1, .damage = 0, .nbt = &tag };
    d.inv[10] = .{ .id = 1, .count = 64, .damage = 0, .nbt = null };
    d.cursor = .{ .id = 3, .count = 5, .damage = 0, .nbt = null };
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
