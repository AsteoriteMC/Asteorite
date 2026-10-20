//! Vanilla 1.7.10 furnace tables, machine-extracted from CFR 0.152 of the
//! official server jar (afa.java FurnaceRecipes + apg.java TileEntityFurnace).
//! Match rule (afa.a): id equal AND (recipe dmg wild 32767 OR exact).
//! XP values recorded but unused (no XP system yet).

const ids = @import("../ids.zig");

pub const Smelt = struct { in_id: u16, in_dmg: i16, out_id: u16, out_count: i8, out_dmg: i16 };

pub const table: [22]Smelt = .{
    .{ .in_id = ids.iron_ore, .in_dmg = 32767, .out_id = ids.iron_ingot, .out_count = 1, .out_dmg = 0 }, // xp 0.70
    .{ .in_id = ids.gold_ore, .in_dmg = 32767, .out_id = ids.gold_ingot, .out_count = 1, .out_dmg = 0 }, // xp 1.00
    .{ .in_id = ids.diamond_ore, .in_dmg = 32767, .out_id = ids.diamond, .out_count = 1, .out_dmg = 0 }, // xp 1.00
    .{ .in_id = ids.sand, .in_dmg = 32767, .out_id = ids.glass, .out_count = 1, .out_dmg = 0 }, // xp 0.10
    .{ .in_id = ids.porkchop, .in_dmg = 0, .out_id = ids.cooked_porkchop, .out_count = 1, .out_dmg = 0 }, // xp 0.35
    .{ .in_id = ids.beef, .in_dmg = 0, .out_id = ids.cooked_beef, .out_count = 1, .out_dmg = 0 }, // xp 0.35
    .{ .in_id = ids.chicken, .in_dmg = 0, .out_id = ids.cooked_chicken, .out_count = 1, .out_dmg = 0 }, // xp 0.35
    .{ .in_id = ids.cobblestone, .in_dmg = 32767, .out_id = ids.stone, .out_count = 1, .out_dmg = 0 }, // xp 0.10
    .{ .in_id = ids.clay_ball, .in_dmg = 0, .out_id = ids.brick, .out_count = 1, .out_dmg = 0 }, // xp 0.30
    .{ .in_id = ids.clay, .in_dmg = 32767, .out_id = ids.hardened_clay, .out_count = 1, .out_dmg = 0 }, // xp 0.35
    .{ .in_id = ids.cactus, .in_dmg = 32767, .out_id = ids.dye, .out_count = 1, .out_dmg = 2 }, // xp 0.20
    .{ .in_id = ids.log, .in_dmg = 32767, .out_id = ids.coal, .out_count = 1, .out_dmg = 1 }, // xp 0.15
    .{ .in_id = ids.log2, .in_dmg = 32767, .out_id = ids.coal, .out_count = 1, .out_dmg = 1 }, // xp 0.15
    .{ .in_id = ids.emerald_ore, .in_dmg = 32767, .out_id = ids.emerald, .out_count = 1, .out_dmg = 0 }, // xp 1.00
    .{ .in_id = ids.potato, .in_dmg = 0, .out_id = ids.baked_potato, .out_count = 1, .out_dmg = 0 }, // xp 0.35
    .{ .in_id = ids.netherrack, .in_dmg = 32767, .out_id = ids.netherbrick, .out_count = 1, .out_dmg = 0 }, // xp 0.10
    .{ .in_id = ids.coal_ore, .in_dmg = 32767, .out_id = ids.coal, .out_count = 1, .out_dmg = 0 }, // xp 0.10
    .{ .in_id = ids.redstone_ore, .in_dmg = 32767, .out_id = ids.redstone, .out_count = 1, .out_dmg = 0 }, // xp 0.70
    .{ .in_id = ids.lapis_ore, .in_dmg = 32767, .out_id = ids.dye, .out_count = 1, .out_dmg = 4 }, // xp 0.20
    .{ .in_id = ids.quartz_ore, .in_dmg = 32767, .out_id = ids.quartz, .out_count = 1, .out_dmg = 0 }, // xp 0.20
    .{ .in_id = ids.fish, .in_dmg = 0, .out_id = ids.cooked_fished, .out_count = 1, .out_dmg = 0 }, // xp 0.35
    .{ .in_id = ids.fish, .in_dmg = 1, .out_id = ids.cooked_fished, .out_count = 1, .out_dmg = 1 }, // xp 0.35
};

/// Explicit fuel burn times (ticks). Wood-material blocks handled separately.
pub const fuels: [12]struct { id: u16, burn: u16 } = .{
    .{ .id = ids.stick, .burn = 100 },
    .{ .id = ids.coal, .burn = 1600 },
    .{ .id = ids.lava_bucket, .burn = 20000 },
    .{ .id = ids.sapling, .burn = 100 },
    .{ .id = ids.blaze_rod, .burn = 2400 },
    .{ .id = ids.coal_block, .burn = 16000 },
    .{ .id = ids.wooden_slab, .burn = 150 },
    .{ .id = ids.wooden_sword, .burn = 200 },
    .{ .id = ids.wooden_shovel, .burn = 200 },
    .{ .id = ids.wooden_pickaxe, .burn = 200 },
    .{ .id = ids.wooden_axe, .burn = 200 },
    .{ .id = ids.wooden_hoe, .burn = 200 },
};

/// minecraft-data material=wood block ids (burn 300, except explicit entries above).
pub const wood_blocks: [25]u16 = .{ids.planks, ids.log, ids.noteblock, ids.bookshelf, ids.oak_stairs, ids.chest, ids.crafting_table, ids.standing_sign, ids.wooden_door_block, ids.wall_sign, ids.wooden_pressure_plate, ids.jukebox, ids.fence, ids.trapdoor, ids.fence_gate, ids.double_wooden_slab, ids.wooden_slab, ids.spruce_stairs, ids.birch_stairs, ids.jungle_stairs, ids.trapped_chest, ids.daylight_detector, ids.log2, ids.acacia_stairs, ids.dark_oak_stairs};
