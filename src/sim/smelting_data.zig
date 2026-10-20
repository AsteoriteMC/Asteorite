//! Vanilla 1.7.10 furnace tables, machine-extracted from CFR 0.152 of the
//! official server jar (afa.java FurnaceRecipes + apg.java TileEntityFurnace).
//! Match rule (afa.a): id equal AND (recipe dmg wild 32767 OR exact).
//! XP values recorded but unused (no XP system yet).

pub const Smelt = struct { in_id: u16, in_dmg: i16, out_id: u16, out_count: i8, out_dmg: i16 };

pub const table: [22]Smelt = .{
    .{ .in_id = 15, .in_dmg = 32767, .out_id = 265, .out_count = 1, .out_dmg = 0 }, // xp 0.70
    .{ .in_id = 14, .in_dmg = 32767, .out_id = 266, .out_count = 1, .out_dmg = 0 }, // xp 1.00
    .{ .in_id = 56, .in_dmg = 32767, .out_id = 264, .out_count = 1, .out_dmg = 0 }, // xp 1.00
    .{ .in_id = 12, .in_dmg = 32767, .out_id = 20, .out_count = 1, .out_dmg = 0 }, // xp 0.10
    .{ .in_id = 319, .in_dmg = 0, .out_id = 320, .out_count = 1, .out_dmg = 0 }, // xp 0.35
    .{ .in_id = 363, .in_dmg = 0, .out_id = 364, .out_count = 1, .out_dmg = 0 }, // xp 0.35
    .{ .in_id = 365, .in_dmg = 0, .out_id = 366, .out_count = 1, .out_dmg = 0 }, // xp 0.35
    .{ .in_id = 4, .in_dmg = 32767, .out_id = 1, .out_count = 1, .out_dmg = 0 }, // xp 0.10
    .{ .in_id = 337, .in_dmg = 0, .out_id = 336, .out_count = 1, .out_dmg = 0 }, // xp 0.30
    .{ .in_id = 82, .in_dmg = 32767, .out_id = 172, .out_count = 1, .out_dmg = 0 }, // xp 0.35
    .{ .in_id = 81, .in_dmg = 32767, .out_id = 351, .out_count = 1, .out_dmg = 2 }, // xp 0.20
    .{ .in_id = 17, .in_dmg = 32767, .out_id = 263, .out_count = 1, .out_dmg = 1 }, // xp 0.15
    .{ .in_id = 162, .in_dmg = 32767, .out_id = 263, .out_count = 1, .out_dmg = 1 }, // xp 0.15
    .{ .in_id = 129, .in_dmg = 32767, .out_id = 388, .out_count = 1, .out_dmg = 0 }, // xp 1.00
    .{ .in_id = 392, .in_dmg = 0, .out_id = 393, .out_count = 1, .out_dmg = 0 }, // xp 0.35
    .{ .in_id = 87, .in_dmg = 32767, .out_id = 405, .out_count = 1, .out_dmg = 0 }, // xp 0.10
    .{ .in_id = 16, .in_dmg = 32767, .out_id = 263, .out_count = 1, .out_dmg = 0 }, // xp 0.10
    .{ .in_id = 73, .in_dmg = 32767, .out_id = 331, .out_count = 1, .out_dmg = 0 }, // xp 0.70
    .{ .in_id = 21, .in_dmg = 32767, .out_id = 351, .out_count = 1, .out_dmg = 4 }, // xp 0.20
    .{ .in_id = 153, .in_dmg = 32767, .out_id = 406, .out_count = 1, .out_dmg = 0 }, // xp 0.20
    .{ .in_id = 349, .in_dmg = 0, .out_id = 350, .out_count = 1, .out_dmg = 0 }, // xp 0.35
    .{ .in_id = 349, .in_dmg = 1, .out_id = 350, .out_count = 1, .out_dmg = 1 }, // xp 0.35
};

/// Explicit fuel burn times (ticks). Wood-material blocks handled separately.
pub const fuels: [12]struct { id: u16, burn: u16 } = .{
    .{ .id = 280, .burn = 100 },
    .{ .id = 263, .burn = 1600 },
    .{ .id = 327, .burn = 20000 },
    .{ .id = 6, .burn = 100 },
    .{ .id = 369, .burn = 2400 },
    .{ .id = 173, .burn = 16000 },
    .{ .id = 126, .burn = 150 },
    .{ .id = 268, .burn = 200 },
    .{ .id = 269, .burn = 200 },
    .{ .id = 270, .burn = 200 },
    .{ .id = 271, .burn = 200 },
    .{ .id = 290, .burn = 200 },
};

/// minecraft-data material=wood block ids (burn 300, except explicit entries above).
pub const wood_blocks: [25]u16 = .{5, 17, 25, 47, 53, 54, 58, 63, 64, 68, 72, 84, 85, 96, 107, 125, 126, 134, 135, 136, 146, 151, 162, 163, 164};
