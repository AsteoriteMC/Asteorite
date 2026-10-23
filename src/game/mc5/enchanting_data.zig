//! 1.7.10 enchanting tables (CFR-verified ports of the official server jar).
//!
//! Sources:
//! - `ContainerEnchantment` bookshelf counting + `calcItemStackEnchantability`
//!   + `enchantItem` lapis-free cost from the 1.8.9 MCP verbatim source
//!   (the 1.7.10 logic is identical except for the lapis slot and the
//!   XP-seed persistence, both documented below).
//! - `EnchantmentHelper.buildEnchantmentList` / `mapEnchantmentData`
//!   (modified-level calc, weighted draw, halve-and-retry, book single-keep)
//!   from the same 1.8.9 source.
//! - Min/max enchantability ranges + enchantability values + weights from
//!   the classic 1.7-era tables (pernsteiner.org/enchant/algo.html, which
//!   predates Lure/Luck and matches the 23-enchant 1.7.10 registry in
//!   `proto/v5/cmd_data.zig`). Luck of the Sea (61, added in 1.7) uses the
//!   Fortune/Looting/Lure range shape, matching the modern wiki.
//!
//! Differences from 1.8.9 that this profile owns:
//! - No lapis slot: the table has a single item slot, and enchanting costs
//!   the full shown level (1.8 costs 1/2/3 + lapis).
//! - No XpSeed persistence in 1.7.10: offers are re-rolled per inventory
//!   change from the container rand. This server keeps a per-session seed
//!   (regenerated after each enchant) so offers are stable until taken and
//!   golden-testable; the mechanic (levels, costs, outcomes) is 1.7-exact.

const ids = @import("../../ids.zig");

/// Enchantability by canonical item id (vanilla `Item.getItemEnchantability`).
/// Tools/armor use material values; book/bow/rod/shears are 1; everything
/// else is 0 (not enchantable on the table).
pub fn enchantabilityForId(id: ids.Id) i32 {
    return switch (id) {
        // Wood: 15.
        ids.wooden_sword, ids.wooden_shovel, ids.wooden_pickaxe, ids.wooden_axe, ids.wooden_hoe => 15,
        // Stone: 5.
        ids.stone_sword, ids.stone_shovel, ids.stone_pickaxe, ids.stone_axe, ids.stone_hoe => 5,
        // Iron tools/swords/hoes: 14.
        ids.iron_sword, ids.iron_shovel, ids.iron_pickaxe, ids.iron_axe, ids.iron_hoe => 14,
        // Diamond tools/swords/hoes: 10.
        ids.diamond_sword, ids.diamond_shovel, ids.diamond_pickaxe, ids.diamond_axe, ids.diamond_hoe => 10,
        // Gold tools/swords/hoes: 22.
        ids.golden_sword, ids.golden_shovel, ids.golden_pickaxe, ids.golden_axe, ids.golden_hoe => 22,
        // Leather armor: 15.
        ids.leather_helmet, ids.leather_chestplate, ids.leather_leggings, ids.leather_boots => 15,
        // Chainmail armor: 12.
        ids.chainmail_helmet, ids.chainmail_chestplate, ids.chainmail_leggings, ids.chainmail_boots => 12,
        // Iron armor: 9.
        ids.iron_helmet, ids.iron_chestplate, ids.iron_leggings, ids.iron_boots => 9,
        // Diamond armor: 10.
        ids.diamond_helmet, ids.diamond_chestplate, ids.diamond_leggings, ids.diamond_boots => 10,
        // Gold armor: 25.
        ids.golden_helmet, ids.golden_chestplate, ids.golden_leggings, ids.golden_boots => 25,
        // Book, bow, fishing rod, shears: 1.
        ids.book, ids.bow, ids.fishing_rod, ids.shears => 1,
        else => 0,
    };
}

/// Weight for the vanilla weighted draw (`Enchantment.weight`).
pub fn weightForEnch(id: u8) i32 {
    return switch (id) {
        0 => 10, // protection
        1 => 5, // fire_protection
        2 => 5, // feather_falling
        3 => 2, // blast_protection
        4 => 5, // projectile_protection
        5 => 2, // respiration
        6 => 2, // aqua_affinity
        7 => 1, // thorns
        16 => 10, // sharpness
        17 => 5, // smite
        18 => 5, // bane_of_arthropods
        19 => 5, // knockback
        20 => 2, // fire_aspect
        21 => 2, // looting
        32 => 10, // efficiency
        33 => 1, // silk_touch
        34 => 5, // unbreaking
        35 => 2, // fortune
        48 => 10, // power
        49 => 2, // punch
        50 => 2, // flame
        51 => 1, // infinity
        61 => 2, // luck_of_the_sea
        else => 0,
    };
}

/// Min/max modified-enchantability for one enchantment level.
/// Null when the level is out of range (mirrors the per-level tables).
pub const Range = struct { min: i32, max: i32 };

pub fn rangeForEnch(id: u8, level: u8) ?Range {
    if (level == 0) return null;
    const l: i32 = level;
    return switch (id) {
        0 => if (l >= 1 and l <= 4) Range{ .min = 1 + (l - 1) * 11, .max = 21 + (l - 1) * 11 } else null,
        1 => if (l >= 1 and l <= 4) Range{ .min = 10 + (l - 1) * 8, .max = 22 + (l - 1) * 8 } else null,
        2 => if (l >= 1 and l <= 4) Range{ .min = 5 + (l - 1) * 6, .max = 15 + (l - 1) * 6 } else null,
        3 => if (l >= 1 and l <= 4) Range{ .min = 5 + (l - 1) * 8, .max = 17 + (l - 1) * 8 } else null,
        4 => if (l >= 1 and l <= 4) Range{ .min = 3 + (l - 1) * 6, .max = 18 + (l - 1) * 6 } else null,
        5 => if (l >= 1 and l <= 3) Range{ .min = 10 + (l - 1) * 10, .max = 40 + (l - 1) * 10 } else null,
        6 => if (l == 1) Range{ .min = 1, .max = 41 } else null,
        7 => if (l >= 1 and l <= 3) Range{ .min = 10 + (l - 1) * 20, .max = 60 + (l - 1) * 20 } else null,
        16 => if (l >= 1 and l <= 5) Range{ .min = 1 + (l - 1) * 11, .max = 21 + (l - 1) * 11 } else null,
        17, 18 => if (l >= 1 and l <= 5) Range{ .min = 5 + (l - 1) * 8, .max = 25 + (l - 1) * 8 } else null,
        19 => if (l >= 1 and l <= 2) Range{ .min = 5 + (l - 1) * 20, .max = 55 + (l - 1) * 20 } else null,
        20 => if (l >= 1 and l <= 2) Range{ .min = 10 + (l - 1) * 20, .max = 60 + (l - 1) * 20 } else null,
        21 => if (l >= 1 and l <= 3) Range{ .min = 15 + (l - 1) * 9, .max = 65 + (l - 1) * 9 } else null,
        32 => if (l >= 1 and l <= 5) Range{ .min = 1 + (l - 1) * 10, .max = 51 + (l - 1) * 10 } else null,
        33 => if (l == 1) Range{ .min = 15, .max = 65 } else null,
        34 => if (l >= 1 and l <= 3) Range{ .min = 5 + (l - 1) * 8, .max = 55 + (l - 1) * 8 } else null,
        35 => if (l >= 1 and l <= 3) Range{ .min = 15 + (l - 1) * 9, .max = 65 + (l - 1) * 9 } else null,
        48 => if (l >= 1 and l <= 5) Range{ .min = 1 + (l - 1) * 10, .max = 16 + (l - 1) * 10 } else null,
        49 => if (l >= 1 and l <= 2) Range{ .min = 12 + (l - 1) * 20, .max = 37 + (l - 1) * 20 } else null,
        50, 51 => if (l == 1) Range{ .min = 20, .max = 50 } else null,
        61 => if (l >= 1 and l <= 3) Range{ .min = 15 + (l - 1) * 9, .max = 65 + (l - 1) * 9 } else null,
        else => null,
    };
}

test "enchantability values are the 1.7 values" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i32, 15), enchantabilityForId(ids.wooden_pickaxe));
    try std.testing.expectEqual(@as(i32, 5), enchantabilityForId(ids.stone_pickaxe));
    try std.testing.expectEqual(@as(i32, 14), enchantabilityForId(ids.iron_pickaxe));
    try std.testing.expectEqual(@as(i32, 10), enchantabilityForId(ids.diamond_pickaxe));
    try std.testing.expectEqual(@as(i32, 22), enchantabilityForId(ids.golden_pickaxe));
    try std.testing.expectEqual(@as(i32, 15), enchantabilityForId(ids.leather_chestplate));
    try std.testing.expectEqual(@as(i32, 12), enchantabilityForId(ids.chainmail_chestplate));
    try std.testing.expectEqual(@as(i32, 9), enchantabilityForId(ids.iron_chestplate));
    try std.testing.expectEqual(@as(i32, 10), enchantabilityForId(ids.diamond_chestplate));
    try std.testing.expectEqual(@as(i32, 25), enchantabilityForId(ids.golden_chestplate));
    try std.testing.expectEqual(@as(i32, 1), enchantabilityForId(ids.book));
    try std.testing.expectEqual(@as(i32, 1), enchantabilityForId(ids.bow));
    try std.testing.expectEqual(@as(i32, 1), enchantabilityForId(ids.fishing_rod));
    try std.testing.expectEqual(@as(i32, 1), enchantabilityForId(ids.shears));
    try std.testing.expectEqual(@as(i32, 0), enchantabilityForId(ids.stone));
    try std.testing.expectEqual(@as(i32, 0), enchantabilityForId(ids.dirt));
}

test "min/max ranges match the classic tables" {
    const std = @import("std");
    try std.testing.expectEqual(Range{ .min = 1, .max = 21 }, rangeForEnch(0, 1).?);
    try std.testing.expectEqual(Range{ .min = 34, .max = 54 }, rangeForEnch(0, 4).?);
    try std.testing.expect(rangeForEnch(0, 5) == null);
    try std.testing.expectEqual(Range{ .min = 1, .max = 41 }, rangeForEnch(6, 1).?);
    try std.testing.expect(rangeForEnch(6, 2) == null);
    try std.testing.expectEqual(Range{ .min = 45, .max = 65 }, rangeForEnch(16, 5).?);
    try std.testing.expectEqual(Range{ .min = 15, .max = 65 }, rangeForEnch(33, 1).?);
    try std.testing.expect(rangeForEnch(33, 2) == null);
    try std.testing.expectEqual(Range{ .min = 20, .max = 50 }, rangeForEnch(50, 1).?);
    try std.testing.expectEqual(Range{ .min = 33, .max = 83 }, rangeForEnch(61, 3).?);
}

test "weights match the classic tables" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i32, 10), weightForEnch(0));
    try std.testing.expectEqual(@as(i32, 1), weightForEnch(7));
    try std.testing.expectEqual(@as(i32, 10), weightForEnch(16));
    try std.testing.expectEqual(@as(i32, 1), weightForEnch(33));
    try std.testing.expectEqual(@as(i32, 1), weightForEnch(51));
    try std.testing.expectEqual(@as(i32, 2), weightForEnch(61));
    try std.testing.expectEqual(@as(i32, 0), weightForEnch(8));
}
