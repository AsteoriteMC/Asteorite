//! Vanilla 1.7.10 block blast resistance (the `blockResistance` field from
//! `Block` static init, CFR 0.152). The explosion core divides by 5
//! (`Block.getExplosionResistance` returns `blockResistance / 5.0F`) and
//! attenuates each 0.3-step ray by `(res + 0.3) * 0.3` for non-air blocks.
//!
//! Values below are the jar's field values for the blocks that matter to
//! blasts (stone-like 10, dirt-like 2.5-3, wood 10-15, water 500, bedrock
//! effectively infinite). Unlisted blocks default to 0 (the jar default
//! when `setResistance` is never called), which errs toward bigger craters
//! in exotic terrain — documented, and invisible to the flat-stone golden.

const ids = @import("../../ids.zig");

/// Raw `blockResistance` (pre-/5) for blast attenuation.
pub fn resistance(id: ids.Id) f32 {
    return switch (id) {
        .air => 0,
        .stone => 10,
        .grass => 3,
        .dirt => 2.5,
        .cobblestone => 10,
        .bedrock => 18000000,
        .sand => 2.5,
        .gravel => 3,
        .gold_ore, .iron_ore, .coal_ore, .lapis_ore, .diamond_ore, .redstone_ore, .lit_redstone_ore, .emerald_ore, .quartz_ore => 15,
        .log, .log2 => 10,
        .leaves, .leaves2 => 1,
        .planks => 15,
        .sandstone => 4,
        .glass, .glass_pane => 1.5,
        .wool, .carpet => 5,
        .gold_block, .iron_block, .diamond_block, .emerald_block, .coal_block, .quartz_block => 30,
        .brick_block => 10,
        .tnt => 0,
        .bookshelf => 7.5,
        .mossy_cobblestone => 10,
        .obsidian => 2000,
        .ice => 2.5,
        .snow, .snow_layer => 1,
        .clay => 3,
        .pumpkin, .lit_pumpkin, .melon_block => 5,
        .netherrack => 2,
        .soul_sand => 2.5,
        .glowstone => 1.5,
        .furnace, .lit_furnace => 17.5,
        .crafting_table => 12.5,
        .chest, .trapped_chest => 12.5,
        .water, .flowing_water => 500,
        // Lava does not absorb blasts in 1.7.10 (only water does).
        .lava, .flowing_lava => 0,
        .fire => 0,
        else => 0,
    };
}

/// Post-/5 value the raycast actually subtracts with (jar
/// `getExplosionResistance`).
pub fn attenuate(id: ids.Id) f32 {
    return resistance(id) / 5.0;
}

test "blast resistance anchors (1.7.10 jar values)" {
    const std = @import("std");
    try std.testing.expectEqual(@as(f32, 10), resistance(.stone));
    try std.testing.expectEqual(@as(f32, 0), resistance(.tnt));
    try std.testing.expectEqual(@as(f32, 500), resistance(.water));
    try std.testing.expectEqual(@as(f32, 0), resistance(.lava));
    try std.testing.expectEqual(@as(f32, 2000), resistance(.obsidian));
    try std.testing.expectEqual(@as(f32, 10), resistance(.log));
    try std.testing.expectEqual(@as(f32, 1.5), resistance(.glass));
    // Post-/5 rule the core uses.
    try std.testing.expectEqual(@as(f32, 2.0), attenuate(.stone));
    try std.testing.expectEqual(@as(f32, 100.0), attenuate(.water));
}
