//! Canonical mob kinds shared by every profile.
//!
//! The enum value is a stable project identity, not a wire type id. Profile
//! data (`game/mc5/mobs.zig`) maps it to the selected protocol's spawn-mob
//! number and back. Engines, region stores and snapshots only ever see
//! `Kind`; the numbers never reach the simulation.

/// One living entity kind. Names follow the modern canonical spelling where
/// 1.7 used a class/display name (`SnowMan` -> `snow_golem`, `LavaSlime` ->
/// `magma_cube`, ...); the profile table owns that translation.

const std = @import("std");

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

/// Config spelling back to a kind: canonical tag names, case-insensitive
/// ("pig_zombie", "Pig_Zombie", "PIG"), else null. Shared by the
/// "mob_spawns" config map.
pub fn parse(s: []const u8) ?Kind {
    inline for (@typeInfo(Kind).@"enum".fields) |f| {
        if (std.ascii.eqlIgnoreCase(s, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

/// Arrival radius for square-patrol legs (shared by the AoS `entity.Mob`
/// and the SoA `MobStore` wander paths — one constant, one golden test).
pub const arrive_dist: f64 = 0.6;

/// Square-patrol waypoint (shared AoS/SoA wander paths).
pub const Waypoint = struct { x: f64, z: f64 };

/// Square patrol waypoint around (home_x, home_z): leg 0..3 walks the
/// corners (+r,+0) -> (+r,+r) -> (+0,+r) -> home.
pub fn squareWaypoint(home_x: f64, home_z: f64, r: f64, leg: u8) Waypoint {
    return switch (leg % 4) {
        0 => .{ .x = home_x + r, .z = home_z },
        1 => .{ .x = home_x + r, .z = home_z + r },
        2 => .{ .x = home_x, .z = home_z + r },
        else => .{ .x = home_x, .z = home_z },
    };
}

/// Facing yaw for a travel direction (degrees, 0 = +Z wiki convention).
pub fn facingYaw(dx: f64, dz: f64) f32 {
    return @floatCast(std.math.atan2(dx, dz) * 180.0 / std.math.pi);
}
