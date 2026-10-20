//! Canonical item model: version-agnostic game data + per-version wire codecs.
//!
//! Shape rule (Phase I readiness): game logic speaks `Stack` (numeric id +
//! count + damage + opaque NBT). Wire formats live in exactly one place per
//! protocol version (`proto/v5/slot.zig`, later `proto/v340/...`) and convert
//! to/from `Stack`. No gameplay code may touch wire bytes directly, and no
//! version adapter may duplicate game tables (damage values, stack limits).
//! Numeric ids are the 1.7-era canonical space; a future `namespace:id`
//! registry maps onto them at the version boundary (Phase I2), not here.

const std = @import("std");

/// One item stack. `nbt` is opaque raw bytes (the i16 length-prefixed gzip
/// blob, WITHOUT the length prefix) borrowed from the packet body — or owned
/// (see `clone`/`free`) when stored past the current frame.
pub const Stack = struct {
    id: u16,
    count: i8,
    damage: i16,
    nbt: ?[]const u8,
};

/// Deep copy (for storing into inventories past frame lifetime).
pub fn cloneStack(alloc: std.mem.Allocator, s: ?Stack) !?Stack {
    const st = s orelse return null;
    return Stack{
        .id = st.id,
        .count = st.count,
        .damage = st.damage,
        .nbt = if (st.nbt) |n| try alloc.dupe(u8, n) else null,
    };
}

/// Free an owned stack (as produced by `cloneStack`).
pub fn freeStack(alloc: std.mem.Allocator, s: *?Stack) void {
    if (s.*) |st| {
        if (st.nbt) |n| alloc.free(n);
        s.* = null;
    }
}

pub fn stacksEqual(a: ?Stack, b: ?Stack) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.id == b.?.id and a.?.count == b.?.count and a.?.damage == b.?.damage and nbtEqual(a.?.nbt, b.?.nbt);
}

fn nbtEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// Mergeable iff same id + damage + NBT (vanilla stackability rule).
pub fn canMerge(dst: Stack, src: Stack) bool {
    return dst.id == src.id and dst.damage == src.damage and nbtEqual(dst.nbt, src.nbt);
}

/// Max stack size (vanilla 1.7 limits). Damageable gear stacks to 1;
/// small throwables/utility to 16; everything else 64.
/// Approximation boundary: exotic 16-stacks beyond this table fall back to
/// 64 (documented; datapack-driven limits are Phase H3/F follow-ups).
pub fn maxStackSize(id: u16) u8 {
    // Swords.
    if (id == 267 or id == 268 or id == 272 or id == 276 or id == 283) return 1;
    // Tools: shovels 269/273/256/277/284, pickaxes 270/274/257/278/285,
    // axes 271/275/258/279/286, hoes 290-294, flint&steel 259, shears 359.
    if ((id >= 256 and id <= 259) or (id >= 269 and id <= 279) or (id >= 283 and id <= 286) or (id >= 290 and id <= 294) or id == 359) return 1;
    // Armor 298-317, bow 261, fishing rod 346, filled buckets.
    if ((id >= 298 and id <= 317) or id == 261 or id == 346 or id == 326 or id == 327 or id == 335) return 1;
    if (id == 325) return 16; // empty bucket
    // Small throwables / utility.
    if (id == 332 or id == 344 or id == 368 or id == 323) return 16; // snowball/egg/ender pearl/sign
    if (id == 328 or id == 333 or id == 342 or id == 343) return 16; // minecarts/boat/storage carts
    return 64;
}

/// Vanilla 1.7 melee damage by held item id (no enchantments — NBT is
/// skipped on placement, so sharpness can't apply; documented in conn.zig).
/// Swords 4-7, axes 3-6, pickaxes 2-5, shovels 1-4, everything else 1.
/// Single source of truth: combat (conn.zig) and future versions import this.
pub fn meleeDamage(id: u16) f32 {
    return switch (id) {
        268, 283 => 4.0, // wooden/gold sword
        272 => 5.0, // stone sword
        267 => 6.0, // iron sword
        276 => 7.0, // diamond sword
        271, 286 => 3.0, // wooden/gold axe
        275 => 4.0, // stone axe
        258 => 5.0, // iron axe
        279 => 6.0, // diamond axe
        270, 285 => 2.0, // wooden/gold pickaxe
        274 => 3.0, // stone pickaxe
        257 => 4.0, // iron pickaxe
        278 => 5.0, // diamond pickaxe
        269, 284 => 1.0, // wooden/gold shovel (fist-equivalent)
        273 => 2.0, // stone shovel
        256 => 3.0, // iron shovel
        277 => 4.0, // diamond shovel
        else => 1.0, // fist and everything else
    };
}

test "melee damage table" {
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), meleeDamage(268), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), meleeDamage(276), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), meleeDamage(258), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), meleeDamage(256), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), meleeDamage(1), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), meleeDamage(0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), meleeDamage(9999), 1e-6);
}

test "stack limits" {
    try std.testing.expectEqual(@as(u8, 64), maxStackSize(3)); // dirt
    try std.testing.expectEqual(@as(u8, 1), maxStackSize(276)); // diamond sword
    try std.testing.expectEqual(@as(u8, 1), maxStackSize(310)); // diamond chestplate
    try std.testing.expectEqual(@as(u8, 16), maxStackSize(332)); // snowball
    try std.testing.expectEqual(@as(u8, 16), maxStackSize(344)); // egg
    try std.testing.expectEqual(@as(u8, 16), maxStackSize(325)); // empty bucket
    try std.testing.expectEqual(@as(u8, 1), maxStackSize(326)); // water bucket
    try std.testing.expectEqual(@as(u8, 1), maxStackSize(267)); // iron sword
    try std.testing.expectEqual(@as(u8, 1), maxStackSize(290)); // wooden hoe
    try std.testing.expectEqual(@as(u8, 64), maxStackSize(5)); // planks
}

test "merge rule needs id+damage+nbt equality" {
    const a = Stack{ .id = 1, .count = 1, .damage = 0, .nbt = null };
    const b = Stack{ .id = 1, .count = 1, .damage = 0, .nbt = null };
    const c = Stack{ .id = 1, .count = 1, .damage = 3, .nbt = null };
    const n = [_]u8{ 1, 2, 3 };
    const d = Stack{ .id = 1, .count = 1, .damage = 0, .nbt = &n };
    try std.testing.expect(canMerge(a, b));
    try std.testing.expect(!canMerge(a, c));
    try std.testing.expect(!canMerge(a, d));
    var owned = try cloneStack(std.testing.allocator, d);
    try std.testing.expect(stacksEqual(owned, d));
    try std.testing.expect(owned.?.nbt.?.ptr != n[0..].ptr); // deep copy
    freeStack(std.testing.allocator, &owned);
    try std.testing.expect(owned == null);
}
