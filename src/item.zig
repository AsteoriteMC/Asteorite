//! Canonical item model: version-neutral stack shape + mechanics.
//!
//! Shape rule (Phase I readiness): game logic speaks `Stack` (canonical id +
//! count + damage + opaque NBT). Wire formats live in exactly one place per
//! protocol version (`proto/v5/slot.zig`, later `proto/v340/...`) and convert
//! to/from `Stack`. No gameplay code may touch wire bytes directly.
//! Per-version numbers (stack limits, melee damage) live in the profile game
//! tables (`game/mc5/item_data.zig`, via `profile.game.item_data`) and are
//! passed in — never hardcoded here.
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
    const sa = a orelse return b == null;
    const sb = b orelse return false;
    return sa.id == sb.id and sa.count == sb.count and sa.damage == sb.damage and nbtEqual(sa.nbt, sb.nbt);
}

fn nbtEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// Wildcard damage (32767): recipe/s_template match-any-damage marker.
/// Single home for the constant smelting + crafting both used to copy.
pub const wild_damage: i16 = 32767;

/// Mergeable iff same id + damage + NBT (vanilla stackability rule).
pub fn canMerge(dst: Stack, src: Stack) bool {
    return dst.id == src.id and dst.damage == src.damage and nbtEqual(dst.nbt, src.nbt);
}

/// Result of filling a player inventory.
pub const FillResult = struct {
    placed: i32,
    remaining: i32,
};

/// Vanilla player-inventory window layout (`InventoryPlayer`, 45 slots):
/// 0 = 2x2 craft result, 1..4 = 2x2 grid, 5..8 = armor, 9..35 = main,
/// 36..44 = hotbar. One home so bounds readers never drift (armor_lo/hi
/// live in profile item_data beside the armor-point rule).
pub const inv_size: usize = 45;
pub const main_lo: usize = 9;
pub const hotbar_lo: usize = 36;

/// Vanilla `InventoryPlayer` scan order: hotbar first (window 36..44 =
/// `mainInventory[0..8]`), then main inventory (window 9..35). Both the
/// merge pass and the first-empty pass of `addItemStackToInventory` scan
/// this way, so an empty-handed grant lands in window slot 36 — shared by
/// `fillInventory` (/give) and the pickup grant in `sim/entity`.
pub const fill_order: [inv_size - main_lo]usize = blk: {
    var o: [inv_size - main_lo]usize = undefined;
    var i: usize = 0;
    for (hotbar_lo..inv_size) |s| {
        o[i] = s;
        i += 1;
    }
    for (main_lo..hotbar_lo) |s| {
        o[i] = s;
        i += 1;
    }
    break :blk o;
};

/// Fill a 45-slot player inventory like vanilla addItemStackToInventory:
/// merge into existing stacks in `fill_order`, then empties in the same
/// order; NBT stacks never merge. Marks touched slots in `dirty`. Shared
/// by the /give command backend (and any future dispenser/pickup paths)
/// so the merge rule lives in exactly one place. `limit` is the profile
/// stack limit for `id` (`profile.game.item_data.maxStackSize`).
pub fn fillInventory(inv: *[inv_size]?Stack, id: ids.Id, count: i32, damage: i16, dirty: *[inv_size]bool, limit: i32) FillResult {
    var remaining = count;
    for (fill_order) |s| {
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
    for (fill_order) |s| {
        if (remaining <= 0) break;
        if (inv[s] != null) continue;
        const put: i8 = @intCast(@min(@as(i32, limit), remaining));
        inv[s] = .{ .id = id, .count = put, .damage = damage, .nbt = null };
        remaining -= put;
        dirty[s] = true;
    }
    return .{ .placed = count - remaining, .remaining = remaining };
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
