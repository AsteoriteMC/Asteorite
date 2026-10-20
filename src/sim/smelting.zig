//! Vanilla 1.7.10 furnace tables (CFR ports of afa FurnaceRecipes +
//! apg TileEntityFurnace).
//!
//! - Smelt match: id equal AND (recipe dmg wild 32767 OR exact).
//! - Fuel (apg.a, ticks): explicit table first, then wood-material blocks
//!   (300), wooden slab special-cased to 150, wooden tools 200.
//! - Container item: only lava bucket leaves one (empty bucket 325).

const std = @import("std");
const data = @import("smelting_data.zig");

pub const WILD: i16 = 32767;

/// Smelting result for an input stack (first table match wins, like vanilla).
pub fn findResult(id: u16, dmg: i16) ?struct { id: u16, count: i8, dmg: i16 } {
    for (data.table) |r| {
        if (r.in_id != id) continue;
        if (r.in_dmg != WILD and r.in_dmg != dmg) continue;
        return .{ .id = r.out_id, .count = r.out_count, .dmg = r.out_dmg };
    }
    return null;
}

/// Burn time in ticks (0 = not fuel). Order: explicit table, then wood blocks.
pub fn burnTime(id: u16) u16 {
    for (data.fuels) |f| if (f.id == id) return f.burn;
    for (data.wood_blocks) |w| if (w == id) return 300;
    return 0;
}

/// Container left after burning one fuel item (lava bucket -> empty bucket).
pub fn containerItem(id: u16) ?u16 {
    if (id == 327) return 325; // lava_bucket -> bucket
    return null;
}

test "smelting table spot checks" {
    // iron/gold/diamond ore (wildcard damage)
    try std.testing.expectEqual(@as(u16, 265), findResult(15, 3).?.id);
    try std.testing.expectEqual(@as(u16, 266), findResult(14, 0).?.id);
    try std.testing.expectEqual(@as(u16, 264), findResult(56, 0).?.id);
    // sand glass / cobble stone / clay hardened
    try std.testing.expectEqual(@as(u16, 20), findResult(12, 0).?.id);
    try std.testing.expectEqual(@as(u16, 1), findResult(4, 0).?.id);
    try std.testing.expectEqual(@as(u16, 172), findResult(82, 0).?.id);
    // charcoal from either log
    try std.testing.expectEqual(@as(i16, 1), findResult(162, 2).?.dmg);
    // fish keep damage
    try std.testing.expectEqual(@as(i16, 1), findResult(349, 1).?.dmg);
    // lapis ore -> dye/4; redstone dust; quartz
    try std.testing.expectEqual(@as(i16, 4), findResult(21, 0).?.dmg);
    try std.testing.expectEqual(@as(u16, 331), findResult(73, 0).?.id);
    // cactus green, clay ball brick, porkchop cooked
    try std.testing.expectEqual(@as(u16, 336), findResult(337, 0).?.id);
    try std.testing.expectEqual(@as(u16, 320), findResult(319, 0).?.id);
    // no match
    try std.testing.expect(findResult(1, 0) == null);
    try std.testing.expect(findResult(5, 0) == null);
}

test "fuel burn times" {
    try std.testing.expectEqual(@as(u16, 100), burnTime(280)); // stick
    try std.testing.expectEqual(@as(u16, 1600), burnTime(263)); // coal
    try std.testing.expectEqual(@as(u16, 20000), burnTime(327)); // lava bucket
    try std.testing.expectEqual(@as(u16, 100), burnTime(6)); // sapling
    try std.testing.expectEqual(@as(u16, 2400), burnTime(369)); // blaze rod
    try std.testing.expectEqual(@as(u16, 16000), burnTime(173)); // coal block
    try std.testing.expectEqual(@as(u16, 150), burnTime(126)); // wooden slab (not 300!)
    try std.testing.expectEqual(@as(u16, 200), burnTime(268)); // wooden sword
    try std.testing.expectEqual(@as(u16, 300), burnTime(5)); // planks (wood set)
    try std.testing.expectEqual(@as(u16, 300), burnTime(58)); // crafting table (wood set)
    try std.testing.expectEqual(@as(u16, 0), burnTime(1)); // stone
    try std.testing.expectEqual(@as(u16, 0), burnTime(265)); // iron ingot
    try std.testing.expect(containerItem(327).? == 325);
    try std.testing.expect(containerItem(263) == null);
}
