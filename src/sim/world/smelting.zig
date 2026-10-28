//! Vanilla 1.7.10 furnace tables (CFR ports of afa FurnaceRecipes +
//! apg TileEntityFurnace).
//!
//! - Smelt match: id equal AND (recipe dmg wild 32767 OR exact).
//! - Fuel (apg.a, ticks): explicit table first, then wood-material blocks
//!   (300), wooden slab special-cased to 150, wooden tools 200.
//! - Container item: only lava bucket leaves one (empty bucket 325).

const std = @import("std");
const profile = @import("../../version.zig");
const data = profile.game.smelting_data;
const ids = @import("../../ids.zig");
const item_mod = @import("../../item.zig");

pub const WILD: i16 = item_mod.wild_damage;

/// Smelting result for an input stack (first table match wins, like vanilla).
pub fn findResult(id: ids.Id, dmg: i16) ?struct { id: ids.Id, count: i8, dmg: i16 } {
    for (data.table) |r| {
        if (r.in_id != id) continue;
        if (r.in_dmg != WILD and r.in_dmg != dmg) continue;
        return .{ .id = r.out_id, .count = r.out_count, .dmg = r.out_dmg };
    }
    return null;
}

/// Burn time in ticks (0 = not fuel). Order: explicit table, then wood blocks.
pub fn burnTime(id: ids.Id) u16 {
    for (data.fuels) |f| if (f.id == id) return f.burn;
    for (data.wood_blocks) |w| if (w == id) return 300;
    return 0;
}

/// Container left after burning one fuel item (lava bucket -> empty bucket).
pub fn containerItem(id: ids.Id) ?ids.Id {
    if (id == ids.lava_bucket) return ids.bucket; // lava_bucket -> bucket
    return null;
}

test "smelting table spot checks" {
    // iron/gold/diamond ore (wildcard damage)
    try std.testing.expectEqual(ids.iron_ingot, findResult(ids.iron_ore, 3).?.id);
    try std.testing.expectEqual(ids.gold_ingot, findResult(ids.gold_ore, 0).?.id);
    try std.testing.expectEqual(ids.diamond, findResult(ids.diamond_ore, 0).?.id);
    // sand glass / cobble stone / clay hardened
    try std.testing.expectEqual(ids.glass, findResult(ids.sand, 0).?.id);
    try std.testing.expectEqual(ids.stone, findResult(ids.cobblestone, 0).?.id);
    try std.testing.expectEqual(ids.hardened_clay, findResult(ids.clay, 0).?.id);
    // charcoal from either log
    try std.testing.expectEqual(@as(i16, 1), findResult(ids.log2, 2).?.dmg);
    // fish keep damage
    try std.testing.expectEqual(@as(i16, 1), findResult(ids.fish, 1).?.dmg);
    // lapis ore -> dye/4; redstone dust; quartz
    try std.testing.expectEqual(@as(i16, 4), findResult(ids.lapis_ore, 0).?.dmg);
    try std.testing.expectEqual(ids.redstone, findResult(ids.redstone_ore, 0).?.id);
    // cactus green, clay ball brick, porkchop cooked
    try std.testing.expectEqual(ids.brick, findResult(ids.clay_ball, 0).?.id);
    try std.testing.expectEqual(ids.cooked_porkchop, findResult(ids.porkchop, 0).?.id);
    // no match
    try std.testing.expect(findResult(ids.stone, 0) == null);
    try std.testing.expect(findResult(ids.planks, 0) == null);
}

test "fuel burn times" {
    try std.testing.expectEqual(@as(u16, 100), burnTime(ids.stick)); // stick
    try std.testing.expectEqual(@as(u16, 1600), burnTime(ids.coal)); // coal
    try std.testing.expectEqual(@as(u16, 20000), burnTime(ids.lava_bucket)); // lava bucket
    try std.testing.expectEqual(@as(u16, 100), burnTime(ids.sapling)); // sapling
    try std.testing.expectEqual(@as(u16, 2400), burnTime(ids.blaze_rod)); // blaze rod
    try std.testing.expectEqual(@as(u16, 16000), burnTime(ids.coal_block)); // coal block
    try std.testing.expectEqual(@as(u16, 150), burnTime(ids.wooden_slab)); // wooden slab (not 300!)
    try std.testing.expectEqual(@as(u16, 200), burnTime(ids.wooden_sword)); // wooden sword
    try std.testing.expectEqual(@as(u16, 300), burnTime(ids.planks)); // planks (wood set)
    try std.testing.expectEqual(@as(u16, 300), burnTime(ids.crafting_table)); // crafting table (wood set)
    try std.testing.expectEqual(@as(u16, 0), burnTime(ids.stone)); // stone
    try std.testing.expectEqual(@as(u16, 0), burnTime(ids.iron_ingot)); // iron ingot
    try std.testing.expect(containerItem(ids.lava_bucket).? == ids.bucket);
    try std.testing.expect(containerItem(ids.coal) == null);
}
