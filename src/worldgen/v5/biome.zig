//! 1.7.10 GenLayer biome chain, ported instruction-by-instruction from javap
//! disassembly of the official server jar (verified class-by-class; the
//! runtime goldens in the tests below are JVM outputs, not re-derivations).
//!
//! Naming follows vanilla where unambiguous (island/zoom/river/...); the
//! obfuscated jar names are noted per layer for auditability.


/// 1.7.10 biome table: id -> terrain + climate. rootHeight/heightVariation
/// are exact f32 bit patterns from the jar (BiomeDump); temp categories from
/// getTempCategory probing. Only fields needed by gen are stored here.
pub const Biome = struct {
    root_height: f32,
    height_var: f32,
    temp: Temp,
};

pub const Temp = enum { ocean, cold, medium, warm };

pub fn biomeById(id: i32) ?Biome {
    return switch (id) {
        0 => .{ .root_height = -1.0, .height_var = 0.00012207031, .temp = .ocean }, // Ocean (0x1.0p-1? exact below)
        else => null,
    };
}

// Full table, generated from BiomeDump output (hex floats are exact).
pub const BIOMES: [40]?Biome = .{
    .{ .root_height = -0x1.0p0, .height_var = 0x1.99999ap-4, .temp = .ocean }, // 0 Ocean
    .{ .root_height = 0x1.0p-3, .height_var = 0x1.99999ap-5, .temp = .medium }, // 1 Plains
    .{ .root_height = 0x1.0p-3, .height_var = 0x1.99999ap-5, .temp = .warm }, // 2 Desert
    .{ .root_height = 0x1.0p0, .height_var = 0x1.0p-1, .temp = .medium }, // 3 ExtremeHills
    .{ .root_height = 0x1.99999ap-4, .height_var = 0x1.99999ap-3, .temp = .medium }, // 4 Forest
    .{ .root_height = 0x1.99999ap-3, .height_var = 0x1.99999ap-3, .temp = .medium }, // 5 Taiga
    .{ .root_height = -0x1.99999ap-3, .height_var = 0x1.99999ap-4, .temp = .medium }, // 6 Swampland
    .{ .root_height = -0x1.0p-1, .height_var = 0x0.0p0, .temp = .medium }, // 7 River
    .{ .root_height = 0x1.99999ap-4, .height_var = 0x1.99999ap-3, .temp = .warm }, // 8 Hell
    .{ .root_height = 0x1.99999ap-4, .height_var = 0x1.99999ap-3, .temp = .medium }, // 9 Sky
    .{ .root_height = -0x1.0p0, .height_var = 0x1.99999ap-4, .temp = .ocean }, // 10 FrozenOcean
    .{ .root_height = -0x1.0p-1, .height_var = 0x0.0p0, .temp = .cold }, // 11 FrozenRiver
    .{ .root_height = 0x1.0p-3, .height_var = 0x1.99999ap-5, .temp = .cold }, // 12 IcePlains
    .{ .root_height = 0x1.ccccccp-2, .height_var = 0x1.333334p-2, .temp = .cold }, // 13 IceMountains
    .{ .root_height = 0x1.99999ap-3, .height_var = 0x1.333334p-2, .temp = .medium }, // 14 MushroomIsland
    .{ .root_height = 0x0.0p0, .height_var = 0x1.99999ap-6, .temp = .medium }, // 15 MushroomIslandShore
    .{ .root_height = 0x0.0p0, .height_var = 0x1.99999ap-6, .temp = .medium }, // 16 Beach
    .{ .root_height = 0x1.ccccccp-2, .height_var = 0x1.333334p-2, .temp = .warm }, // 17 DesertHills
    .{ .root_height = 0x1.ccccccp-2, .height_var = 0x1.333334p-2, .temp = .medium }, // 18 ForestHills
    .{ .root_height = 0x1.ccccccp-2, .height_var = 0x1.333334p-2, .temp = .medium }, // 19 TaigaHills
    .{ .root_height = 0x1.99999ap-1, .height_var = 0x1.333334p-2, .temp = .medium }, // 20 ExtremeHillsEdge
    .{ .root_height = 0x1.99999ap-4, .height_var = 0x1.99999ap-3, .temp = .medium }, // 21 Jungle
    .{ .root_height = 0x1.ccccccp-2, .height_var = 0x1.333334p-2, .temp = .medium }, // 22 JungleHills
    .{ .root_height = 0x1.99999ap-4, .height_var = 0x1.99999ap-3, .temp = .medium }, // 23 JungleEdge
    .{ .root_height = -0x1.ccccccp0, .height_var = 0x1.99999ap-4, .temp = .ocean }, // 24 DeepOcean
    .{ .root_height = 0x1.99999ap-4, .height_var = 0x1.99999ap-1, .temp = .medium }, // 25 StoneBeach
    .{ .root_height = 0x0.0p0, .height_var = 0x1.99999ap-6, .temp = .cold }, // 26 ColdBeach
    .{ .root_height = 0x1.99999ap-4, .height_var = 0x1.99999ap-3, .temp = .medium }, // 27 BirchForest
    .{ .root_height = 0x1.ccccccp-2, .height_var = 0x1.333334p-2, .temp = .medium }, // 28 BirchForestHills
    .{ .root_height = 0x1.99999ap-4, .height_var = 0x1.99999ap-3, .temp = .medium }, // 29 RoofedForest
    .{ .root_height = 0x1.99999ap-3, .height_var = 0x1.99999ap-3, .temp = .cold }, // 30 ColdTaiga
    .{ .root_height = 0x1.ccccccp-2, .height_var = 0x1.333334p-2, .temp = .cold }, // 31 ColdTaigaHills
    .{ .root_height = 0x1.99999ap-3, .height_var = 0x1.99999ap-3, .temp = .medium }, // 32 MegaTaiga
    .{ .root_height = 0x1.ccccccp-2, .height_var = 0x1.333334p-2, .temp = .medium }, // 33 MegaTaigaHills
    .{ .root_height = 0x1.0p0, .height_var = 0x1.0p-1, .temp = .medium }, // 34 ExtremeHills+
    .{ .root_height = 0x1.0p-3, .height_var = 0x1.99999ap-5, .temp = .warm }, // 35 Savanna
    .{ .root_height = 0x1.8p0, .height_var = 0x1.99999ap-6, .temp = .warm }, // 36 SavannaPlateau
    .{ .root_height = 0x1.99999ap-4, .height_var = 0x1.99999ap-3, .temp = .warm }, // 37 Mesa
    .{ .root_height = 0x1.8p0, .height_var = 0x1.99999ap-6, .temp = .warm }, // 38 MesaPlateauF
    .{ .root_height = 0x1.8p0, .height_var = 0x1.99999ap-6, .temp = .warm }, // 39 MesaPlateau
};

/// Registered biome ids (getBiomeById(x) != null). Used for the +128 mutated
/// checks in RiverMix; verified by dumping the jar's registry.
pub fn biomeExists(id: i32) bool {
    if (id < 0 or id > 255) return false;
    if (id <= 39) return true;
    return switch (@as(u8, @truncate(@as(u32, @bitCast(id))))) {
        129, 130, 131, 132, 133, 134, 140, 149, 151, 155, 156, 157, 158, 160, 161, 162, 163, 164, 165, 166, 167 => true,
        else => false,
    };
}

/// Root height / height variation per biome id (BiomeAll probe, hex exact).
/// Includes mutated (+128) variants — the density field blends them.
pub const HEIGHTS: [256][2]f32 = blk: {
    var t: [256][2]f32 = .{.{ 0x1.0p-3, 0x1.99999ap-5 }} ** 256; // fallback: plains
    t[0] = .{ -0x1.0p0, 0x1.99999ap-4 };
    t[1] = .{ 0x1.0p-3, 0x1.99999ap-5 };
    t[2] = .{ 0x1.0p-3, 0x1.99999ap-5 };
    t[3] = .{ 0x1.0p0, 0x1.0p-1 };
    t[4] = .{ 0x1.99999ap-4, 0x1.99999ap-3 };
    t[5] = .{ 0x1.99999ap-3, 0x1.99999ap-3 };
    t[6] = .{ -0x1.99999ap-3, 0x1.99999ap-4 };
    t[7] = .{ -0x1.0p-1, 0x0.0p0 };
    t[8] = .{ 0x1.99999ap-4, 0x1.99999ap-3 };
    t[9] = .{ 0x1.99999ap-4, 0x1.99999ap-3 };
    t[10] = .{ -0x1.0p0, 0x1.99999ap-4 };
    t[11] = .{ -0x1.0p-1, 0x0.0p0 };
    t[12] = .{ 0x1.0p-3, 0x1.99999ap-5 };
    t[13] = .{ 0x1.ccccccp-2, 0x1.333334p-2 };
    t[14] = .{ 0x1.99999ap-3, 0x1.333334p-2 };
    t[15] = .{ 0x0.0p0, 0x1.99999ap-6 };
    t[16] = .{ 0x0.0p0, 0x1.99999ap-6 };
    t[17] = .{ 0x1.ccccccp-2, 0x1.333334p-2 };
    t[18] = .{ 0x1.ccccccp-2, 0x1.333334p-2 };
    t[19] = .{ 0x1.ccccccp-2, 0x1.333334p-2 };
    t[20] = .{ 0x1.99999ap-1, 0x1.333334p-2 };
    t[21] = .{ 0x1.99999ap-4, 0x1.99999ap-3 };
    t[22] = .{ 0x1.ccccccp-2, 0x1.333334p-2 };
    t[23] = .{ 0x1.99999ap-4, 0x1.99999ap-3 };
    t[24] = .{ -0x1.ccccccp0, 0x1.99999ap-4 };
    t[25] = .{ 0x1.99999ap-4, 0x1.99999ap-1 };
    t[26] = .{ 0x0.0p0, 0x1.99999ap-6 };
    t[27] = .{ 0x1.99999ap-4, 0x1.99999ap-3 };
    t[28] = .{ 0x1.ccccccp-2, 0x1.333334p-2 };
    t[29] = .{ 0x1.99999ap-4, 0x1.99999ap-3 };
    t[30] = .{ 0x1.99999ap-3, 0x1.99999ap-3 };
    t[31] = .{ 0x1.ccccccp-2, 0x1.333334p-2 };
    t[32] = .{ 0x1.99999ap-3, 0x1.99999ap-3 };
    t[33] = .{ 0x1.ccccccp-2, 0x1.333334p-2 };
    t[34] = .{ 0x1.0p0, 0x1.0p-1 };
    t[35] = .{ 0x1.0p-3, 0x1.99999ap-5 };
    t[36] = .{ 0x1.8p0, 0x1.99999ap-6 };
    t[37] = .{ 0x1.99999ap-4, 0x1.99999ap-3 };
    t[38] = .{ 0x1.8p0, 0x1.99999ap-6 };
    t[39] = .{ 0x1.8p0, 0x1.99999ap-6 };
    t[129] = .{ 0x1.0p-3, 0x1.99999ap-5 };
    t[130] = .{ 0x1.ccccccp-3, 0x1.0p-2 };
    t[131] = .{ 0x1.0p0, 0x1.0p-1 };
    t[132] = .{ 0x1.99999ap-4, 0x1.99999ap-2 };
    t[133] = .{ 0x1.333334p-2, 0x1.99999ap-2 };
    t[134] = .{ -0x1.99999ap-4, 0x1.333334p-2 };
    t[140] = .{ 0x1.b33334p-2, 0x1.cccccep-2 };
    t[149] = .{ 0x1.99999ap-3, 0x1.99999ap-2 };
    t[151] = .{ 0x1.99999ap-3, 0x1.99999ap-2 };
    t[155] = .{ 0x1.99999ap-3, 0x1.99999ap-2 };
    t[156] = .{ 0x1.19999ap-1, 0x1.0p-1 };
    t[157] = .{ 0x1.99999ap-3, 0x1.99999ap-2 };
    t[158] = .{ 0x1.333334p-2, 0x1.99999ap-2 };
    t[160] = .{ 0x1.99999ap-3, 0x1.99999ap-3 };
    t[161] = .{ 0x1.99999ap-3, 0x1.99999ap-3 };
    t[162] = .{ 0x1.0p0, 0x1.0p-1 };
    t[163] = .{ 0x1.733334p-2, 0x1.39999ap0 };
    t[164] = .{ 0x1.0cccccp0, 0x1.366668p0 };
    t[165] = .{ 0x1.99999ap-4, 0x1.99999ap-3 };
    t[166] = .{ 0x1.ccccccp-2, 0x1.333334p-2 };
    t[167] = .{ 0x1.ccccccp-2, 0x1.333334p-2 };
    break :blk t;
};

/// Float temperature per biome id (ahu.ao, TempProbe hex exact).
/// Used by the freeze check (getFloatTemperature).
pub const TEMP_F: [40]f32 = .{
    0x1.0p-1, // 0
    0x1.99999ap-1, // 1
    0x1.0p1, // 2
    0x1.99999ap-3, // 3
    0x1.666666p-1, // 4
    0x1.0p-2, // 5
    0x1.99999ap-1, // 6
    0x1.0p-1, // 7
    0x1.0p1, // 8
    0x1.0p-1, // 9
    0x0.0p0, // 10
    0x0.0p0, // 11
    0x0.0p0, // 12
    0x0.0p0, // 13
    0x1.ccccccp-1, // 14
    0x1.ccccccp-1, // 15
    0x1.99999ap-1, // 16
    0x1.0p1, // 17
    0x1.666666p-1, // 18
    0x1.0p-2, // 19
    0x1.99999ap-3, // 20
    0x1.e66666p-1, // 21
    0x1.e66666p-1, // 22
    0x1.e66666p-1, // 23
    0x1.0p-1, // 24
    0x1.99999ap-3, // 25
    0x1.99999ap-5, // 26
    0x1.333334p-1, // 27
    0x1.333334p-1, // 28
    0x1.666666p-1, // 29
    -0x1.0p-1, // 30
    -0x1.0p-1, // 31
    0x1.333334p-2, // 32
    0x1.333334p-2, // 33
    0x1.99999ap-3, // 34
    0x1.333334p0, // 35
    0x1.0p0, // 36
    0x1.0p1, // 37
    0x1.0p1, // 38
    0x1.0p1, // 39
};

/// Extended surface tables (BiomeAll2 probe, hex exact).
/// Covers mutated (+128) ids; unregistered slots fall back to plains.
/// TOP/FILLER hold 1.7 numeric block ids (0 = air/null top).
pub const TOP256: [256]u16 = blk: {
    var t: [256]u16 = .{2} ** 256;
    t[0] = 2;
    t[1] = 2;
    t[2] = 12;
    t[3] = 2;
    t[4] = 2;
    t[5] = 2;
    t[6] = 2;
    t[7] = 2;
    t[8] = 2;
    t[9] = 3;
    t[10] = 2;
    t[11] = 2;
    t[12] = 2;
    t[13] = 2;
    t[14] = 110;
    t[15] = 110;
    t[16] = 12;
    t[17] = 12;
    t[18] = 2;
    t[19] = 2;
    t[20] = 2;
    t[21] = 2;
    t[22] = 2;
    t[23] = 2;
    t[24] = 2;
    t[25] = 1;
    t[26] = 12;
    t[27] = 2;
    t[28] = 2;
    t[29] = 2;
    t[30] = 2;
    t[31] = 2;
    t[32] = 2;
    t[33] = 2;
    t[34] = 2;
    t[35] = 2;
    t[36] = 2;
    t[37] = 12;
    t[38] = 12;
    t[39] = 12;
    t[129] = 2;
    t[130] = 12;
    t[131] = 2;
    t[132] = 2;
    t[133] = 2;
    t[134] = 2;
    t[140] = 80;
    t[149] = 2;
    t[151] = 2;
    t[155] = 2;
    t[156] = 2;
    t[157] = 2;
    t[158] = 2;
    t[160] = 2;
    t[161] = 2;
    t[162] = 2;
    t[163] = 2;
    t[164] = 2;
    t[165] = 12;
    t[166] = 12;
    t[167] = 12;
    break :blk t;
};
pub const TOPMETA256: [256]u8 = blk: {
    var t: [256]u8 = .{0} ** 256;
    t[37] = 1;
    t[38] = 1;
    t[39] = 1;
    t[165] = 1;
    t[166] = 1;
    t[167] = 1;
    break :blk t;
};
pub const FILLER256: [256]u16 = blk: {
    var t: [256]u16 = .{3} ** 256;
    t[0] = 3;
    t[1] = 3;
    t[2] = 12;
    t[3] = 3;
    t[4] = 3;
    t[5] = 3;
    t[6] = 3;
    t[7] = 3;
    t[8] = 3;
    t[9] = 3;
    t[10] = 3;
    t[11] = 3;
    t[12] = 3;
    t[13] = 3;
    t[14] = 3;
    t[15] = 3;
    t[16] = 12;
    t[17] = 12;
    t[18] = 3;
    t[19] = 3;
    t[20] = 3;
    t[21] = 3;
    t[22] = 3;
    t[23] = 3;
    t[24] = 3;
    t[25] = 1;
    t[26] = 12;
    t[27] = 3;
    t[28] = 3;
    t[29] = 3;
    t[30] = 3;
    t[31] = 3;
    t[32] = 3;
    t[33] = 3;
    t[34] = 3;
    t[35] = 3;
    t[36] = 3;
    t[37] = 159;
    t[38] = 159;
    t[39] = 159;
    t[129] = 3;
    t[130] = 12;
    t[131] = 3;
    t[132] = 3;
    t[133] = 3;
    t[134] = 3;
    t[140] = 3;
    t[149] = 3;
    t[151] = 3;
    t[155] = 3;
    t[156] = 3;
    t[157] = 3;
    t[158] = 3;
    t[160] = 3;
    t[161] = 3;
    t[162] = 3;
    t[163] = 3;
    t[164] = 3;
    t[165] = 159;
    t[166] = 159;
    t[167] = 159;
    break :blk t;
};
pub const TEMPF256: [256]f32 = blk: {
    var t: [256]f32 = .{0x1.99999ap-1} ** 256;
    t[0] = 0x1.0p-1;
    t[1] = 0x1.99999ap-1;
    t[2] = 0x1.0p1;
    t[3] = 0x1.99999ap-3;
    t[4] = 0x1.666666p-1;
    t[5] = 0x1.0p-2;
    t[6] = 0x1.99999ap-1;
    t[7] = 0x1.0p-1;
    t[8] = 0x1.0p1;
    t[9] = 0x1.0p-1;
    t[10] = 0x0.0p0;
    t[11] = 0x0.0p0;
    t[12] = 0x0.0p0;
    t[13] = 0x0.0p0;
    t[14] = 0x1.ccccccp-1;
    t[15] = 0x1.ccccccp-1;
    t[16] = 0x1.99999ap-1;
    t[17] = 0x1.0p1;
    t[18] = 0x1.666666p-1;
    t[19] = 0x1.0p-2;
    t[20] = 0x1.99999ap-3;
    t[21] = 0x1.e66666p-1;
    t[22] = 0x1.e66666p-1;
    t[23] = 0x1.e66666p-1;
    t[24] = 0x1.0p-1;
    t[25] = 0x1.99999ap-3;
    t[26] = 0x1.99999ap-5;
    t[27] = 0x1.333334p-1;
    t[28] = 0x1.333334p-1;
    t[29] = 0x1.666666p-1;
    t[30] = -0x1.0p-1;
    t[31] = -0x1.0p-1;
    t[32] = 0x1.333334p-2;
    t[33] = 0x1.333334p-2;
    t[34] = 0x1.99999ap-3;
    t[35] = 0x1.333334p0;
    t[36] = 0x1.0p0;
    t[37] = 0x1.0p1;
    t[38] = 0x1.0p1;
    t[39] = 0x1.0p1;
    t[129] = 0x1.99999ap-1;
    t[130] = 0x1.0p1;
    t[131] = 0x1.99999ap-3;
    t[132] = 0x1.666666p-1;
    t[133] = 0x1.0p-2;
    t[134] = 0x1.99999ap-1;
    t[140] = 0x0.0p0;
    t[149] = 0x1.e66666p-1;
    t[151] = 0x1.e66666p-1;
    t[155] = 0x1.333334p-1;
    t[156] = 0x1.333334p-1;
    t[157] = 0x1.666666p-1;
    t[158] = -0x1.0p-1;
    t[160] = 0x1.0p-2;
    t[161] = 0x1.0p-2;
    t[162] = 0x1.99999ap-3;
    t[163] = 0x1.19999ap0;
    t[164] = 0x1.0p0;
    t[165] = 0x1.0p1;
    t[166] = 0x1.0p1;
    t[167] = 0x1.0p1;
    break :blk t;
};
