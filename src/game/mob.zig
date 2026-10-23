//! Canonical mob kinds shared by every profile.
//!
//! The enum value is a stable project identity, not a wire type id. Profile
//! data (`game/mc5/mobs.zig`) maps it to the selected protocol's spawn-mob
//! number and back. Engines, region stores and snapshots only ever see
//! `Kind`; the numbers never reach the simulation.

/// One living entity kind. Names follow the modern canonical spelling where
/// 1.7 used a class/display name (`SnowMan` -> `snow_golem`, `LavaSlime` ->
/// `magma_cube`, ...); the profile table owns that translation.
pub const Kind = enum(u8) {
    creeper,
    skeleton,
    spider,
    giant,
    zombie,
    slime,
    ghast,
    pig_zombie,
    enderman,
    cave_spider,
    silverfish,
    blaze,
    magma_cube,
    ender_dragon,
    wither,
    bat,
    witch,
    pig,
    sheep,
    cow,
    chicken,
    squid,
    wolf,
    mooshroom,
    snow_golem,
    ocelot,
    iron_golem,
    horse,
    villager,
};

pub const count: usize = @typeInfo(Kind).@"enum".fields.len;
