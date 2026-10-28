//! Per-block chest storage (single chests and double-chest halves).
//!
//! Design (compact + chunk-ban-proof + lag-proof):
//! - One small row per chest BLOCK (never per chunk, never in the chunk
//!   bytes): magic "ZCHT" v1 + xyz + 27 slots, ~44 bytes empty. A 1000-
//!   chest town costs ~44 KiB plus LSM overhead. Double chests are two
//!   rows read together; join/split moves no data (split/join is logical).
//! - Rows live in the same LSM pool under a reserved dimension
//!   (`chest_dim = 254`; same rationale as `player_dim = 255`: no world
//!   code ever writes it). Keys hash (x,y,z) like player rows; the row
//!   carries xyz and decode fails closed on mismatch (hash hit on
//!   someone else's row reads as absent, never as contents).
//! - Anti-chunk-ban decode: exact layout (trailing garbage rejects),
//!   canonical ids only (`ids.COUNT`-checked, air-as-stack rejected),
//!   per-slot NBT capped at 64 KiB plus a 1 MiB per-row total (a stuffed
//!   double chest peaks ≈ 2 MiB per window — under the 4 MiB outbox
//!   budget, so no overflow-kick and no lag spike). NBT is always opaque
//!   bytes here (measured and copied, never parsed), so nesting depth —
//!   shulkers-in-theory included — is irrelevant: only byte size counts,
//!   and in-game NBT has no manufacturing path anyway (no book writing,
//!   no renames, creative NBT pick-block is a no-op; bytes arrive via
//!   capped imports and bounded server-made outputs). Insertion is gated
//!   too: oversize stacks fail the click (snap-back echo), so an
//!   unopenable brick can never persist.
//! - Durability: dirty-flag + 1 Hz ticker flush (world_lock, borrowed
//!   encode like saveRedstone), close needs no flush, stop flushes.
//!   Crash window is <=1 s of clicks (vanilla loses up to 45 s).
//! - Locking: callers hold `chest_lock` (leaf, mirroring furn_lock) for
//!   map access and `world_lock` for pool put/get/delete (same discipline
//!   as applyBlock). Rows load lazily on first open — never at boot.
//!   Worldgen loot (scattered chests) can seed rows directly via saveRow.

const std = @import("std");
const store_mod = @import("../../world/store.zig");
const shard_mod = @import("../../world/shard.zig");
const item_mod = @import("../../item.zig");
const ids = @import("../../ids.zig");

/// Reserved LSM dimension for chest rows (see module doc).
pub const chest_dim: u8 = 254;
pub const magic = "ZCHT";
pub const version: u8 = 1;
/// Vanilla chest slots (double chests are two rows of 27).
pub const chest_size: usize = 27;
/// Per-row NBT total cap (anti-bloat: bounds the worst window packet and
/// SST entry a chest can produce).
pub const max_row_nbt_bytes: usize = 1024 * 1024;
/// Per-slot NBT cap: 1.7.10's largest legit item NBT is a full written
/// book (~50 pages x 256 chars ≈ 50 KB); 64 KiB leaves headroom. Worst
/// case per row is min(27 x 64 KiB, 1 MiB) = 1 MiB, so a stuffed double
/// chest peaks ≈ 2 MiB per window — under the 4 MiB outbox budget with
/// 2x margin (no overflow-kick, no lag spike); an unopenable brick can
/// never persist.
/// Deliberately stricter than player rows (1 MiB/slot, pre-existing
/// posture kept for vanilla-import compatibility): chests are new storage
/// with no legacy rows to honor, and books are the only large-NBT item
/// that can actually arrive here (no book writing, no renames, no
/// creative NBT pick-block — NBT only arrives via capped imports and
/// server-made outputs).
pub const max_slot_nbt_bytes: usize = 64 * 1024;

pub const LoadError = error{ CorruptChest, PosMismatch };

/// Row key: Wyhash over xyz (same posture as player name keys; fixed
/// little-endian so keys are platform-stable).
pub fn keyForChest(x: i32, y: i32, z: i32) store_mod.ChunkKey {
    var h = std.hash.Wyhash.init(0);
    var b: [4]u8 = undefined;
    std.mem.writeInt(i32, &b, x, .little);
    h.update(&b);
    std.mem.writeInt(i32, &b, y, .little);
    h.update(&b);
    std.mem.writeInt(i32, &b, z, .little);
    h.update(&b);
    const v = h.final();
    return store_mod.encodeKey(
        chest_dim,
        @as(i32, @bitCast(@as(u32, @truncate(v >> 32)))),
        @as(i32, @bitCast(@as(u32, @truncate(v)))),
    );
}

fn take(r: *[]const u8, n: usize) LoadError![]const u8 {
    if (r.len < n) return error.CorruptChest;
    const s = r.*[0..n];
    r.* = r.*[n..];
    return s;
}

fn writeSlot(w: *std.Io.Writer, s: ?item_mod.Stack) !void {
    const st = s orelse return w.writeByte(0);
    try w.writeByte(1);
    // Canonical ids.Id (same convention as player rows v5+).
    try w.writeInt(u16, @intFromEnum(st.id), .big);
    try w.writeByte(@bitCast(st.count));
    try w.writeInt(i16, st.damage, .big);
    const nb = st.nbt orelse return w.writeInt(i32, -1, .big);
    try w.writeInt(i32, @intCast(nb.len), .big);
    try w.writeAll(nb);
}

pub fn encode(alloc: std.mem.Allocator, x: i32, y: i32, z: i32, slots: *const [chest_size]?item_mod.Stack) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(magic);
    try w.writeByte(version);
    try w.writeInt(i32, x, .big);
    try w.writeInt(i32, y, .big);
    try w.writeInt(i32, z, .big);
    for (slots) |s| try writeSlot(w, s);
    return aw.toOwnedSlice();
}

fn readSlot(alloc: std.mem.Allocator, r: *[]const u8, total_nbt: *usize) (LoadError || std.mem.Allocator.Error)!?item_mod.Stack {
    if ((try take(r, 1))[0] == 0) return null;
    const raw_id = std.mem.readInt(u16, (try take(r, 2))[0..2], .big);
    const count: i8 = @bitCast((try take(r, 1))[0]);
    const damage = std.mem.readInt(i16, (try take(r, 2))[0..2], .big);
    const nlen = std.mem.readInt(i32, (try take(r, 4))[0..4], .big);
    if (nlen < -1) return error.CorruptChest;
    if (@as(usize, raw_id) >= ids.COUNT) return error.CorruptChest;
    const id: ids.Id = @enumFromInt(raw_id);
    if (id == ids.air) return error.CorruptChest;
    if (nlen == -1) return .{ .id = id, .count = count, .damage = damage, .nbt = null };
    if (nlen > max_slot_nbt_bytes) return error.CorruptChest;
    total_nbt.* += @intCast(nlen);
    if (total_nbt.* > max_row_nbt_bytes) return error.CorruptChest;
    const nb = try take(r, @intCast(nlen));
    const owned = try alloc.dupe(u8, nb);
    return .{ .id = id, .count = count, .damage = damage, .nbt = owned };
}

/// Decoded row (owned NBT; free with freeSlots). Verifies xyz.
pub const Row = struct {
    slots: [chest_size]?item_mod.Stack = [_]?item_mod.Stack{null} ** chest_size,
};

pub fn freeSlots(alloc: std.mem.Allocator, slots: *[chest_size]?item_mod.Stack) void {
    for (slots) |*s| item_mod.freeStack(alloc, s);
}

pub fn decode(alloc: std.mem.Allocator, bytes: []const u8, x: i32, y: i32, z: i32) (LoadError || std.mem.Allocator.Error)!Row {
    var row = Row{};
    errdefer freeSlots(alloc, &row.slots);
    var r = bytes;
    if (!std.mem.eql(u8, try take(&r, 4), magic)) return error.CorruptChest;
    if ((try take(&r, 1))[0] != version) return error.CorruptChest;
    const rx = std.mem.readInt(i32, (try take(&r, 4))[0..4], .big);
    const ry = std.mem.readInt(i32, (try take(&r, 4))[0..4], .big);
    const rz = std.mem.readInt(i32, (try take(&r, 4))[0..4], .big);
    if (rx != x or ry != y or rz != z) return error.PosMismatch;
    var total_nbt: usize = 0;
    for (&row.slots) |*s| s.* = try readSlot(alloc, &r, &total_nbt);
    if (r.len != 0) return error.CorruptChest;
    return row;
}

/// Insertion gate: oversize NBT fails the click instead of persisting an
/// unopenable row (decode would reject it on next load, silently emptying
/// the chest). Stacks already inside need no check (validated at load);
/// in-container merges never grow NBT (identical blobs only), so gating
/// the incoming stack suffices. Null (pure take) always fits.
pub fn slotFitsChest(s: ?item_mod.Stack) bool {
    const st = s orelse return true;
    const n = st.nbt orelse return true;
    return n.len <= max_slot_nbt_bytes;
}

/// Store one chest row. Caller holds world_lock (same as applyBlock).
pub fn saveRow(pool: *shard_mod.ShardPool, x: i32, y: i32, z: i32, slots: *const [chest_size]?item_mod.Stack) !void {
    const enc = try encode(pool.allocator, x, y, z, slots);
    defer pool.allocator.free(enc);
    try pool.put(keyForChest(x, y, z), enc);
}

/// Load one chest row (owned NBT; free with freeSlots). Null = no row.
/// PosMismatch reads as absent (hash hit on someone else's row — never
/// trust a key alone; same posture as player UUID rows).
pub fn loadRow(pool: *shard_mod.ShardPool, alloc: std.mem.Allocator, x: i32, y: i32, z: i32) !?Row {
    const raw = try pool.get(alloc, keyForChest(x, y, z));
    if (raw == null) return null;
    defer alloc.free(raw.?);
    return decode(alloc, raw.?, x, y, z) catch |err| switch (err) {
        error.PosMismatch => null,
        else => |e| e,
    };
}

/// Delete one chest row (block broken). Caller holds world_lock.
pub fn deleteRow(pool: *shard_mod.ShardPool, x: i32, y: i32, z: i32) !void {
    try pool.delete(keyForChest(x, y, z));
}

test "chest row roundtrip incl NBT" {
    const a = std.testing.allocator;
    var slots: [chest_size]?item_mod.Stack = [_]?item_mod.Stack{null} ** chest_size;
    const tag = [_]u8{ 0x0A, 0x00, 0x03, 0x64, 0x75, 0x6D };
    slots[0] = .{ .id = ids.diamond, .count = 64, .damage = 0, .nbt = &tag };
    slots[26] = .{ .id = ids.stone, .count = 1, .damage = 3, .nbt = null };
    const enc = try encode(a, 10, 66, -4, &slots);
    defer a.free(enc);
    var back = try decode(a, enc, 10, 66, -4);
    defer freeSlots(a, &back.slots);
    try std.testing.expect(item_mod.stacksEqual(slots[0], back.slots[0]));
    try std.testing.expect(back.slots[0].?.nbt.?.ptr != tag[0..].ptr);
    try std.testing.expect(item_mod.stacksEqual(slots[26], back.slots[26]));
    try std.testing.expect(back.slots[1] == null);
}

test "chest rows reject corrupt/mismatched/overlong" {
    const a = std.testing.allocator;
    var slots: [chest_size]?item_mod.Stack = [_]?item_mod.Stack{null} ** chest_size;
    slots[0] = .{ .id = ids.stone, .count = 1, .damage = 0, .nbt = null };
    const enc = try encode(a, 1, 2, 3, &slots);
    defer a.free(enc);
    // truncated
    try std.testing.expectError(error.CorruptChest, decode(a, enc[0 .. enc.len - 3], 1, 2, 3));
    // bad magic / version
    {
        const mut = try a.dupe(u8, enc);
        defer a.free(mut);
        mut[0] = 'X';
        try std.testing.expectError(error.CorruptChest, decode(a, mut, 1, 2, 3));
    }
    {
        const mut = try a.dupe(u8, enc);
        defer a.free(mut);
        mut[4] = 9;
        try std.testing.expectError(error.CorruptChest, decode(a, mut, 1, 2, 3));
    }
    // wrong pos fails closed (not someone else's contents)
    try std.testing.expectError(error.PosMismatch, decode(a, enc, 1, 2, 4));
    // trailing garbage
    {
        const grown = try a.alloc(u8, enc.len + 1);
        defer a.free(grown);
        @memcpy(grown[0..enc.len], enc);
        grown[enc.len] = 0;
        try std.testing.expectError(error.CorruptChest, decode(a, grown, 1, 2, 3));
    }
    // id 0 stack rejected (header 4+1+12 = 17; slot 0 present flag at 17,
    // id bytes at 18..20)
    {
        const mut = try a.dupe(u8, enc);
        defer a.free(mut);
        mut[17] = 1;
        mut[18] = 0;
        mut[19] = 0;
        try std.testing.expectError(error.CorruptChest, decode(a, mut, 1, 2, 3));
    }
}

test "chest rows enforce slot + total NBT caps" {
    const a = std.testing.allocator;
    // One slot over 64 KiB rejects (chunk-ban bound; 1.7.10's largest
    // legit item NBT is a ~50 KiB written book).
    {
        const big = try a.alloc(u8, max_slot_nbt_bytes + 1);
        defer a.free(big);
        @memset(big, 0xAB);
        var slots: [chest_size]?item_mod.Stack = [_]?item_mod.Stack{null} ** chest_size;
        slots[0] = .{ .id = ids.written_book, .count = 1, .damage = 0, .nbt = big };
        const enc = try encode(a, 1, 2, 3, &slots);
        defer a.free(enc);
        try std.testing.expectError(error.CorruptChest, decode(a, enc, 1, 2, 3));
    }
    // Many medium slots summing past 1 MiB reject even though each fits.
    {
        const per: usize = 63 * 1024;
        var slots: [chest_size]?item_mod.Stack = [_]?item_mod.Stack{null} ** chest_size;
        var i: usize = 0;
        while (i < 17) : (i += 1) {
            const nb = try a.alloc(u8, per);
            errdefer a.free(nb);
            @memset(nb, 0xCD);
            slots[i] = .{ .id = ids.written_book, .count = 1, .damage = 0, .nbt = nb };
        }
        defer {
            for (&slots) |*s| {
                if (s.*) |st| {
                    if (st.nbt) |n| a.free(n);
                    s.* = null;
                }
            }
        }
        const enc = try encode(a, 1, 2, 3, &slots);
        defer a.free(enc);
        try std.testing.expectError(error.CorruptChest, decode(a, enc, 1, 2, 3));
    }
    // Just under both caps round-trips.
    {
        const nb = try a.alloc(u8, max_slot_nbt_bytes);
        defer a.free(nb);
        @memset(nb, 0xEF);
        var slots: [chest_size]?item_mod.Stack = [_]?item_mod.Stack{null} ** chest_size;
        slots[0] = .{ .id = ids.written_book, .count = 1, .damage = 0, .nbt = nb };
        const enc = try encode(a, 1, 2, 3, &slots);
        defer a.free(enc);
        var back = try decode(a, enc, 1, 2, 3);
        defer freeSlots(a, &back.slots);
        try std.testing.expectEqual(nb.len, back.slots[0].?.nbt.?.len);
    }
}

test "chest keys stable + distinct + dimensioned" {
    const k1 = keyForChest(10, 66, -4);
    const k2 = keyForChest(10, 66, -4);
    try std.testing.expectEqualSlices(u8, &k1, &k2);
    try std.testing.expectEqual(chest_dim, k1[0]);
    // y distinguishes stacked chests (ChunkKey has no y lane).
    try std.testing.expect(!std.mem.eql(u8, &k1, &keyForChest(10, 67, -4)));
    try std.testing.expect(!std.mem.eql(u8, &k1, &keyForChest(11, 66, -4)));
}
