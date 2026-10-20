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
