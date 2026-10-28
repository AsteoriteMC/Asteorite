//! 1.7.10 canonical mob-kind mapping.
//!
//! These numbers are the `SpawnMob 0x0F` type ids used by the 1.7.10
//! protocol. They stay in this profile table; the region store, snapshots
//! and shared entity tracker use `game/mob.zig`'s canonical `Kind`.

const std = @import("std");
const mob = @import("../mob.zig");

const Kind = mob.Kind;

pub const Def = struct {
    kind: Kind,
    /// 1.7.10 SpawnMob type id.
    wire: u8,
    /// Canonical name used by profile data/tests. `/summon` still reads its
    /// jar-verified display names from `proto/v5/cmd_data.zig`.
    name: []const u8,
};

pub const defs = [_]Def{
    .{ .kind = .creeper, .wire = 50, .name = "creeper" },
    .{ .kind = .skeleton, .wire = 51, .name = "skeleton" },
    .{ .kind = .spider, .wire = 52, .name = "spider" },
    .{ .kind = .giant, .wire = 53, .name = "giant" },
    .{ .kind = .zombie, .wire = 54, .name = "zombie" },
    .{ .kind = .slime, .wire = 55, .name = "slime" },
    .{ .kind = .ghast, .wire = 56, .name = "ghast" },
    .{ .kind = .pig_zombie, .wire = 57, .name = "zombie_pigman" },
    .{ .kind = .enderman, .wire = 58, .name = "enderman" },
    .{ .kind = .cave_spider, .wire = 59, .name = "cave_spider" },
    .{ .kind = .silverfish, .wire = 60, .name = "silverfish" },
    .{ .kind = .blaze, .wire = 61, .name = "blaze" },
    .{ .kind = .magma_cube, .wire = 62, .name = "magma_cube" },
    .{ .kind = .ender_dragon, .wire = 63, .name = "ender_dragon" },
    .{ .kind = .wither, .wire = 64, .name = "wither" },
    .{ .kind = .bat, .wire = 65, .name = "bat" },
    .{ .kind = .witch, .wire = 66, .name = "witch" },
    .{ .kind = .pig, .wire = 90, .name = "pig" },
    .{ .kind = .sheep, .wire = 91, .name = "sheep" },
    .{ .kind = .cow, .wire = 92, .name = "cow" },
    .{ .kind = .chicken, .wire = 93, .name = "chicken" },
    .{ .kind = .squid, .wire = 94, .name = "squid" },
    .{ .kind = .wolf, .wire = 95, .name = "wolf" },
    .{ .kind = .mooshroom, .wire = 96, .name = "mooshroom" },
    .{ .kind = .snow_golem, .wire = 97, .name = "snow_golem" },
    .{ .kind = .ocelot, .wire = 98, .name = "ocelot" },
    .{ .kind = .iron_golem, .wire = 99, .name = "iron_golem" },
    .{ .kind = .horse, .wire = 100, .name = "horse" },
    .{ .kind = .villager, .wire = 120, .name = "villager" },
};

/// Dense canonical-kind -> wire table. The enum is sequential and append-only,
/// so this is one array load at the packet boundary.
pub const wire_by_kind: [mob.count]u8 = blk: {
    var out = [_]u8{0xFF} ** mob.count;
    for (defs) |d| out[@intFromEnum(d.kind)] = d.wire;
    break :blk out;
};

/// Dense canonical-kind -> display name table (same shape as wire_by_kind).
pub const name_by_kind: [mob.count][]const u8 = blk: {
    var out = [_][]const u8{""} ** mob.count;
    for (defs) |d| out[@intFromEnum(d.kind)] = d.name;
    break :blk out;
};

/// Sparse reverse map. Unassigned wire ids fail closed instead of becoming a
/// neighbouring mob kind.
pub const kind_by_wire: [256]?Kind = blk: {
    var out = [_]?Kind{null} ** 256;
    for (defs) |d| out[d.wire] = d.kind;
    break :blk out;
};

pub fn wire(kind: Kind) u8 {
    return wire_by_kind[@intFromEnum(kind)];
}

pub fn fromWire(type_id: u8) ?Kind {
    return kind_by_wire[type_id];
}

pub fn name(kind: Kind) []const u8 {
    return name_by_kind[@intFromEnum(kind)];
}

test "every canonical kind maps to exactly one 1.7.10 wire id" {
    try std.testing.expectEqual(mob.count, defs.len);
    for (0..mob.count) |i| {
        const kind: Kind = @enumFromInt(i);
        const wire_id = wire(kind);
        try std.testing.expectEqual(kind, fromWire(wire_id).?);
    }
    try std.testing.expect(fromWire(0) == null);
    try std.testing.expect(fromWire(89) == null);
    try std.testing.expect(fromWire(121) == null);
    try std.testing.expectEqual(@as(u8, 90), wire(.pig));
    try std.testing.expectEqual(@as(u8, 92), wire(.cow));
}

test "1.7.10 summonable table is covered by the canonical map" {
    const cmd_data = @import("../../proto/v5/cmd_data.zig");
    for (cmd_data.mobs) |m| {
        const kind = fromWire(m.type_id) orelse return error.UnmappedSummonMob;
        try std.testing.expectEqual(m.type_id, wire(kind));
    }
}
