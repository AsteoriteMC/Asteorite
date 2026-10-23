//! Offline player-row import boundary (1.7.10 era).
//!
//! Two wire-id sources meet the canonical `players.Data` here:
//!
//! 1. Vanilla `player.dat` NBT (gzip-NBT produced by the official 1.7.10
//!    server jar). Field mapping verified against CFR 0.152 decompiles of
//!    that jar: Entity.a/b (sa: Pos/Rotation 3d+2f, FallDistance f,
//!    Fire/Air short, OnGround bool, Dimension int, PortalCooldown int,
//!    UUIDMost/Least long), EntityLivingBase.a/b (sv: HealF float preferred,
//!    else Health float-or-short), FoodStats.a/b (zr: foodLevel int,
//!    foodTickTimer int, foodSaturationLevel float, foodExhaustionLevel
//!    float), EntityPlayer.a/b (yz: Inventory list of compounds Slot byte
//!    0-35 main / 100-103 armor, SelectedItemSlot int, SpawnX/Y/Z int +
//!    SpawnForced, XpLevel/XpTotal, EnderItems), EntityPlayerMP.a/b (mw:
//!    playerGameType int), ItemStack.a (add: id short, Count byte, Damage
//!    short, optional tag compound).
//!
//! 2. Legacy ZPLR rows (v3/v4). Those rows were written before the C1 fix
//!    and store 1.7.10 **wire** ids even though later comments claimed
//!    canonical; ZPLR v5 stores canonical `ids.Id`. `legacySlot` is the
//!    migration map used by `players.loadLegacy` / `decodeLegacy`.
//!
//! Dropped on the floor (documented): Motion, FallDistance, Fire, Air,
//! PortalCooldown, Invulnerable, UUID, Score, XP, food timers/exhaustion,
//! EnderItems (no ender chest yet), crafting grid (vanilla doesn't save it
//! either), cursor (vanilla saves none). Out-of-range gamemodes clamp to
//! survival; only gamemode 0/1 exist here.

const std = @import("std");
const ids = @import("../../ids.zig");
const item_mod = @import("../../item.zig");
const wire = @import("../../proto/v5/wire_ids.zig");
const players_mod = @import("../../sim/players.zig");
const nbt_mod = @import("../nbt.zig");

const Data = players_mod.Data;

/// Legacy ZPLR v3/v4 slot ids are 1.7.10 wire ids by definition (the rows
/// were produced by the v5 profile). This map is not profile-dispatched:
/// a v4 row can only originate from a 1.7.10-owned world, and non-1.7
/// profiles import player data offline into a fresh DB.
pub fn legacySlot(wire_id: u16) ?ids.Id {
    return wire.fromWire(wire_id);
}

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

pub const VanillaError = nbt_mod.NbtError || std.mem.Allocator.Error || error{BadUsername};

fn validImportName(name: []const u8) bool {
    // Mirrors conn.validPlayerName (kept local: the import boundary must not
    // import the whole connection stack for one charset check).
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
    errdefer players_mod.freeData(alloc, &d);
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
        // Vanilla wire id -> canonical; unmapped ids are dropped, not stored.
        const canon = wire.fromWire(@intCast(@max(id, 0))) orelse {
            stats.dropped_stacks += 1;
            continue;
        };
        const dst: ?usize = if (s < 9) @as(usize, 36 + s) else if (s < 36) @as(usize, s) else if (s >= 100 and s < 104) @as(usize, 5 + (s - 100)) else null;
        const di = dst orelse {
            stats.unknown_slots += 1;
            continue;
        };
        // Duplicate slots in one file: last wins (vanilla overwrites too).
        item_mod.freeStack(alloc, &d.inv[di]);
        d.inv[di] = .{ .id = canon, .count = count, .damage = damage, .nbt = nbt };
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
    defer players_mod.freeData(a, &d);
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
    try std.testing.expectEqual(ids.stone, d.inv[36].?.id);
    try std.testing.expectEqual(@as(i8, 64), d.inv[36].?.count);
    try std.testing.expectEqual(@as(i16, 0), d.inv[36].?.damage);
    try std.testing.expect(d.inv[36].?.nbt == null);
    // renamed sword keeps its tag bytes verbatim (NBT round-trips opaque)
    const sword = d.inv[37].?;
    try std.testing.expectEqual(ids.diamond_sword, sword.id);
    try std.testing.expectEqual(@as(i8, 1), sword.count);
    const want_tag = [_]u8{ 0x0A, 0x00, 0x07, 'd', 'i', 's', 'p', 'l', 'a', 'y', 0x08, 0x00, 0x04, 'N', 'a', 'm', 'e', 0x00, 0x02, 'H', 'i', 0x00, 0x00 };
    try std.testing.expectEqualSlices(u8, &want_tag, sword.nbt.?);
    try std.testing.expect(imp.stats.unknown_slots == 0);
    try std.testing.expect(imp.stats.dropped_stacks == 0);
    // ZPLR round-trips the import (the store path is format-agnostic).
    const enc = try players_mod.encode(a, &d);
    defer a.free(enc);
    var back = try players_mod.decode(a, enc, "Steve");
    defer players_mod.freeData(a, &back);
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
    defer players_mod.freeData(a, &imp.data);
    try std.testing.expectApproxEqAbs(@as(f64, 10.5), imp.data.pos_x, 1e-9);
    try std.testing.expect(imp.stats.defaulted_spawn);
    try std.testing.expectEqual(@as(i32, 10), imp.data.spawn_x);
    try std.testing.expectEqual(@as(i32, 65), imp.data.spawn_y);
    try std.testing.expectEqual(@as(i32, -4), imp.data.spawn_z);
    // Bad username rejected before touching NBT.
    var r_bad = fromVanillaNbt(a, buf[0..w], "has space");
    if (r_bad) |*bad| {
        players_mod.freeData(a, &bad.data);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expect(err == error.BadUsername);
    }
}

test "legacy ZPLR v4 rows decode through the v5 wire mapper" {
    const a = std.testing.allocator;
    var d = Data{};
    @memcpy(d.username[0.."Al".len], "Al");
    d.username_len = 2;
    d.inv[0] = .{ .id = .stone, .count = 64, .damage = 0, .nbt = null };
    d.inv[36] = .{ .id = .diamond_sword, .count = 1, .damage = 3, .nbt = null };
    const enc = try players_mod.encode(a, &d);
    defer a.free(enc);

    // Re-create what the pre-C1 v4 writer produced: canonical encode with
    // the version byte downgraded and every slot id rewritten to its v5
    // wire value (the historical bug/format).
    const v4 = try a.dupe(u8, enc);
    defer a.free(v4);
    v4[4] = 4;
    var i: usize = 4 + 1 + 1 + 2 + 24 + 8 + 1 + 12 + 4 + 2 + 4 + 1; // 64
    var n: usize = 0;
    while (n < players_mod.inv_size + 1) : (n += 1) {
        if (v4[i] == 0) {
            i += 1;
            continue;
        }
        const canon = std.mem.readInt(u16, v4[i + 1 ..][0..2], .big);
        std.mem.writeInt(u16, v4[i + 1 ..][0..2], wire.toWire(@enumFromInt(canon)), .big);
        const nlen = std.mem.readInt(i32, v4[i + 6 ..][0..4], .big);
        i += 1 + 2 + 1 + 2 + 4;
        if (nlen > 0) i += @intCast(nlen);
    }

    var back = try players_mod.decodeLegacy(a, v4, "Al", legacySlot);
    defer players_mod.freeData(a, &back);
    try std.testing.expectEqual(ids.stone, back.inv[0].?.id);
    try std.testing.expectEqual(@as(i8, 64), back.inv[0].?.count);
    try std.testing.expectEqual(ids.diamond_sword, back.inv[36].?.id);
    try std.testing.expectEqual(@as(i16, 3), back.inv[36].?.damage);
}

test "legacy ZPLR rows with unmapped wire ids are rejected" {
    const a = std.testing.allocator;
    var d = Data{};
    @memcpy(d.username[0.."Al".len], "Al");
    d.username_len = 2;
    d.inv[0] = .{ .id = .stone, .count = 1, .damage = 0, .nbt = null };
    const enc = try players_mod.encode(a, &d);
    defer a.free(enc);
    const v3 = try a.dupe(u8, enc[0 .. enc.len - 13]); // strip v4 xp tail
    defer a.free(v3);
    v3[4] = 3;
    // Wire 176 is unassigned in 1.7.10 (gap between blocks and items).
    std.mem.writeInt(u16, v3[65..][0..2], 176, .big);
    try std.testing.expectError(error.CorruptPlayer, players_mod.decodeLegacy(a, v3, "Al", legacySlot));
}
