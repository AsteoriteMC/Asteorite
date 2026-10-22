//! Canonical item model: version-agnostic game data + per-version wire codecs.
//!
//! Shape rule (Phase I readiness): game logic speaks `Stack` (canonical id +
//! count + damage + opaque NBT). Wire formats live in exactly one place per
//! protocol version (`proto/v5/slot.zig`, later `proto/v340/...`) and convert
//! to/from `Stack`. No gameplay code may touch wire bytes directly, and no
//! version adapter may duplicate game tables (damage values, stack limits).
//! Canonical ids are dense indices into the `ids` registry (NOT wire values;
//! see `proto/v5/wire_ids.zig` for the v5 mapping): never persist or compare
//! them against wire ranges.

const std = @import("std");
const ids = @import("ids.zig");

/// One item stack. `nbt` is opaque raw bytes (the i16 length-prefixed gzip
/// blob, WITHOUT the length prefix) borrowed from the packet body — or owned
/// (see `clone`/`free`) when stored past the current frame.
pub const Stack = struct {
    id: ids.Id,
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

/// Result of filling a player inventory.
pub const FillResult = struct {
    placed: i32,
    remaining: i32,
};

/// Fill a 45-slot player inventory like vanilla addItemStackToInventory:
/// merge into main-inventory stacks (slots 9..44), then empties; NBT
/// stacks never merge. Marks touched slots in `dirty`. Shared by the
/// /give command backend (and any future dispenser/pickup paths) so the
/// merge rule lives in exactly one place.
pub fn fillInventory(inv: *[45]?Stack, id: ids.Id, count: i32, damage: i16, dirty: *[45]bool) FillResult {
    var remaining = count;
    const limit: i32 = maxStackSize(id);
    for (9..45) |s| {
        if (remaining <= 0) break;
        const st = inv[s] orelse continue;
        if (st.id != id or st.damage != damage or st.nbt != null) continue;
        if (st.count >= limit) continue;
        const room = limit - @as(i32, st.count);
        const take = @min(room, remaining);
        inv[s].?.count += @intCast(take);
        remaining -= take;
        dirty[s] = true;
    }
    var s: usize = 9;
    while (remaining > 0 and s < 45) : (s += 1) {
        if (inv[s] != null) continue;
        const put: i8 = @intCast(@min(@as(i32, limit), remaining));
        inv[s] = .{ .id = id, .count = put, .damage = damage, .nbt = null };
        remaining -= put;
        dirty[s] = true;
    }
    return .{ .placed = count - remaining, .remaining = remaining };
}

/// Max stack size (vanilla 1.7 limits). Damageable gear stacks to 1;
/// small throwables/utility to 16; everything else 64.
/// Approximation boundary: exotic 16-stacks beyond this table fall back to
/// 64 (documented; datapack-driven limits are Phase H3/F follow-ups).
pub fn maxStackSize(id: ids.Id) u8 {
    // Swords.
    if (id == ids.iron_sword or id == ids.wooden_sword or id == ids.stone_sword or id == ids.diamond_sword or id == ids.golden_sword) return 1;
    // Tools: shovels, pickaxes, axes, hoes, flint&steel, shears (explicit:
    // canonical ids are dense, so the old wire ranges no longer work).
    if (id == ids.wooden_shovel or id == ids.stone_shovel or id == ids.iron_shovel or id == ids.diamond_shovel or id == ids.golden_shovel) return 1;
    if (id == ids.wooden_pickaxe or id == ids.stone_pickaxe or id == ids.iron_pickaxe or id == ids.diamond_pickaxe or id == ids.golden_pickaxe) return 1;
    if (id == ids.wooden_axe or id == ids.stone_axe or id == ids.iron_axe or id == ids.diamond_axe or id == ids.golden_axe) return 1;
    if (id == ids.wooden_hoe or id == ids.stone_hoe or id == ids.iron_hoe or id == ids.diamond_hoe or id == ids.golden_hoe) return 1;
    if (id == ids.flint_and_steel or id == ids.shears) return 1;
    // Armor, bow, fishing rod, filled buckets.
    if (id == ids.leather_helmet or id == ids.leather_chestplate or id == ids.leather_leggings or id == ids.leather_boots) return 1;
    if (id == ids.chainmail_helmet or id == ids.chainmail_chestplate or id == ids.chainmail_leggings or id == ids.chainmail_boots) return 1;
    if (id == ids.iron_helmet or id == ids.iron_chestplate or id == ids.iron_leggings or id == ids.iron_boots) return 1;
    if (id == ids.diamond_helmet or id == ids.diamond_chestplate or id == ids.diamond_leggings or id == ids.diamond_boots) return 1;
    if (id == ids.golden_helmet or id == ids.golden_chestplate or id == ids.golden_leggings or id == ids.golden_boots) return 1;
    if (id == ids.bow or id == ids.fishing_rod or id == ids.water_bucket or id == ids.lava_bucket or id == ids.milk_bucket) return 1;
    if (id == ids.bucket) return 16; // empty bucket
    // Small throwables / utility.
    if (id == ids.snowball or id == ids.egg or id == ids.ender_pearl or id == ids.sign) return 16; // snowball/egg/ender pearl/sign
    if (id == ids.minecart or id == ids.boat or id == ids.chest_minecart or id == ids.furnace_minecart) return 16; // minecarts/boat/storage carts
    return 64;
}

/// Vanilla 1.7 melee damage by held item id (no enchantments — NBT is
/// skipped on placement, so sharpness can't apply; documented in conn.zig).
/// Swords 4-7, axes 3-6, pickaxes 2-5, shovels 1-4, everything else 1.
/// Single source of truth: combat (conn.zig) and future versions import this.
pub fn meleeDamage(id: ids.Id) f32 {
    return switch (id) {
        ids.wooden_sword, ids.golden_sword => 4.0, // wooden/gold sword
        ids.stone_sword => 5.0, // stone sword
        ids.iron_sword => 6.0, // iron sword
        ids.diamond_sword => 7.0, // diamond sword
        ids.wooden_axe, ids.golden_axe => 3.0, // wooden/gold axe
        ids.stone_axe => 4.0, // stone axe
        ids.iron_axe => 5.0, // iron axe
        ids.diamond_axe => 6.0, // diamond axe
        ids.wooden_pickaxe, ids.golden_pickaxe => 2.0, // wooden/gold pickaxe
        ids.stone_pickaxe => 3.0, // stone pickaxe
        ids.iron_pickaxe => 4.0, // iron pickaxe
        ids.diamond_pickaxe => 5.0, // diamond pickaxe
        ids.wooden_shovel, ids.golden_shovel => 1.0, // wooden/gold shovel (fist-equivalent)
        ids.stone_shovel => 2.0, // stone shovel
        ids.iron_shovel => 3.0, // iron shovel
        ids.diamond_shovel => 4.0, // diamond shovel
        else => 1.0, // fist and everything else
    };
}

test "melee damage table" {
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), meleeDamage(ids.wooden_sword), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), meleeDamage(ids.diamond_sword), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), meleeDamage(ids.iron_axe), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), meleeDamage(ids.iron_shovel), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), meleeDamage(ids.stone), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), meleeDamage(ids.air), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), meleeDamage(@as(ids.Id, @enumFromInt(9999))), 1e-6);
}

test "stack limits" {
    try std.testing.expectEqual(@as(u8, 64), maxStackSize(ids.dirt)); // dirt
    try std.testing.expectEqual(@as(u8, 1), maxStackSize(ids.diamond_sword)); // diamond sword
    try std.testing.expectEqual(@as(u8, 1), maxStackSize(ids.diamond_helmet)); // diamond chestplate
    try std.testing.expectEqual(@as(u8, 16), maxStackSize(ids.snowball)); // snowball
    try std.testing.expectEqual(@as(u8, 16), maxStackSize(ids.egg)); // egg
    try std.testing.expectEqual(@as(u8, 16), maxStackSize(ids.bucket)); // empty bucket
    try std.testing.expectEqual(@as(u8, 1), maxStackSize(ids.water_bucket)); // water bucket
    try std.testing.expectEqual(@as(u8, 1), maxStackSize(ids.iron_sword)); // iron sword
    try std.testing.expectEqual(@as(u8, 1), maxStackSize(ids.wooden_hoe)); // wooden hoe
    try std.testing.expectEqual(@as(u8, 64), maxStackSize(ids.planks)); // planks
}

test "merge rule needs id+damage+nbt equality" {
    const a = Stack{ .id = ids.stone, .count = 1, .damage = 0, .nbt = null };
    const b = Stack{ .id = ids.stone, .count = 1, .damage = 0, .nbt = null };
    const c = Stack{ .id = ids.stone, .count = 1, .damage = 3, .nbt = null };
    const n = [_]u8{ 1, 2, 3 };
    const d = Stack{ .id = ids.stone, .count = 1, .damage = 0, .nbt = &n };
    try std.testing.expect(canMerge(a, b));
    try std.testing.expect(!canMerge(a, c));
    try std.testing.expect(!canMerge(a, d));
    var owned = try cloneStack(std.testing.allocator, d);
    try std.testing.expect(stacksEqual(owned, d));
    try std.testing.expect(owned.?.nbt.?.ptr != n[0..].ptr); // deep copy
    freeStack(std.testing.allocator, &owned);
    try std.testing.expect(owned == null);
}
