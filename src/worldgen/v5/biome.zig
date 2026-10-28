//! 1.7.10 GenLayer biome chain, ported instruction-by-instruction from javap
//! disassembly of the official server jar (verified class-by-class; the
//! runtime goldens in the tests below are JVM outputs, not re-derivations).
//!
//! Naming follows vanilla where unambiguous (island/zoom/river/...); the
//! obfuscated jar names are noted per layer for auditability.

const ids = @import("../../ids.zig");

/// 1.7.10 biome table: id -> terrain + climate. rootHeight/heightVariation
/// are exact f32 bit patterns from the jar (BiomeDump); temp categories from
/// getTempCategory probing. Only fields needed by gen are stored here.
pub const Biome = struct {
    root_height: f32,
    height_var: f32,
    temp: Temp,
};

pub const Temp = enum { ocean, cold, medium, warm };

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
/// Vanilla ids fit in a byte (0..255); 0..39 are always registered.
pub const max_biome_id: i32 = 255;
pub fn biomeExists(id: i32) bool {
    if (id < 0 or id > max_biome_id) return false;
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
pub const TOP256: [256]ids.Id = blk: {
    var t: [256]ids.Id = .{ids.grass} ** 256;
    t[0] = ids.grass;
    t[1] = ids.grass;
    t[2] = ids.sand;
    t[3] = ids.grass;
    t[4] = ids.grass;
    t[5] = ids.grass;
    t[6] = ids.grass;
    t[7] = ids.grass;
    t[8] = ids.grass;
    t[9] = ids.dirt;
    t[10] = ids.grass;
    t[11] = ids.grass;
    t[12] = ids.grass;
    t[13] = ids.grass;
    t[14] = ids.mycelium;
    t[15] = ids.mycelium;
    t[16] = ids.sand;
    t[17] = ids.sand;
    t[18] = ids.grass;
    t[19] = ids.grass;
    t[20] = ids.grass;
    t[21] = ids.grass;
    t[22] = ids.grass;
    t[23] = ids.grass;
    t[24] = ids.grass;
    t[25] = ids.stone;
    t[26] = ids.sand;
    t[27] = ids.grass;
    t[28] = ids.grass;
    t[29] = ids.grass;
    t[30] = ids.grass;
    t[31] = ids.grass;
    t[32] = ids.grass;
    t[33] = ids.grass;
    t[34] = ids.grass;
    t[35] = ids.grass;
    t[36] = ids.grass;
    t[37] = ids.sand;
    t[38] = ids.sand;
    t[39] = ids.sand;
    t[129] = ids.grass;
    t[130] = ids.sand;
    t[131] = ids.grass;
    t[132] = ids.grass;
    t[133] = ids.grass;
    t[134] = ids.grass;
    t[140] = ids.snow;
    t[149] = ids.grass;
    t[151] = ids.grass;
    t[155] = ids.grass;
    t[156] = ids.grass;
    t[157] = ids.grass;
    t[158] = ids.grass;
    t[160] = ids.grass;
    t[161] = ids.grass;
    t[162] = ids.grass;
    t[163] = ids.grass;
    t[164] = ids.grass;
    t[165] = ids.sand;
    t[166] = ids.sand;
    t[167] = ids.sand;
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
pub const FILLER256: [256]ids.Id = blk: {
    var t: [256]ids.Id = .{ids.dirt} ** 256;
    t[0] = ids.dirt;
    t[1] = ids.dirt;
    t[2] = ids.sand;
    t[3] = ids.dirt;
    t[4] = ids.dirt;
    t[5] = ids.dirt;
    t[6] = ids.dirt;
    t[7] = ids.dirt;
    t[8] = ids.dirt;
    t[9] = ids.dirt;
    t[10] = ids.dirt;
    t[11] = ids.dirt;
    t[12] = ids.dirt;
    t[13] = ids.dirt;
    t[14] = ids.dirt;
    t[15] = ids.dirt;
    t[16] = ids.sand;
    t[17] = ids.sand;
    t[18] = ids.dirt;
    t[19] = ids.dirt;
    t[20] = ids.dirt;
    t[21] = ids.dirt;
    t[22] = ids.dirt;
    t[23] = ids.dirt;
    t[24] = ids.dirt;
    t[25] = ids.stone;
    t[26] = ids.sand;
    t[27] = ids.dirt;
    t[28] = ids.dirt;
    t[29] = ids.dirt;
    t[30] = ids.dirt;
    t[31] = ids.dirt;
    t[32] = ids.dirt;
    t[33] = ids.dirt;
    t[34] = ids.dirt;
    t[35] = ids.dirt;
    t[36] = ids.dirt;
    t[37] = ids.stained_hardened_clay;
    t[38] = ids.stained_hardened_clay;
    t[39] = ids.stained_hardened_clay;
    t[129] = ids.dirt;
    t[130] = ids.sand;
    t[131] = ids.dirt;
    t[132] = ids.dirt;
    t[133] = ids.dirt;
    t[134] = ids.dirt;
    t[140] = ids.dirt;
    t[149] = ids.dirt;
    t[151] = ids.dirt;
    t[155] = ids.dirt;
    t[156] = ids.dirt;
    t[157] = ids.dirt;
    t[158] = ids.dirt;
    t[160] = ids.dirt;
    t[161] = ids.dirt;
    t[162] = ids.dirt;
    t[163] = ids.dirt;
    t[164] = ids.dirt;
    t[165] = ids.stained_hardened_clay;
    t[166] = ids.stained_hardened_clay;
    t[167] = ids.stained_hardened_clay;
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
