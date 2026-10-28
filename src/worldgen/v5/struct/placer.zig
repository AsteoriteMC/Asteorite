//! Structure world-access interface (vanilla `ahb` surface used by pieces).
//!
//! Pieces never touch chunks directly: every read/write goes through this
//! vtable, so the same placement code runs against the live populate view
//! (integration) and against test/harness stores (goldens). Out-of-view
//! reads return air (matches decor `View.get`).

const std = @import("std");
const ids = @import("../../../ids.zig");

pub const Block = struct {
    id: ids.Id,
    meta: u4,
};

pub const Placer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (ptr: *anyopaque, x: i32, y: i32, z: i32) Block,
        set: *const fn (ptr: *anyopaque, x: i32, y: i32, z: i32, id: ids.Id, meta: u4) void,
        /// `World.getTopSolidOrLiquidBlock`: y+1 of the highest top-counting
        /// block, or -1 if none above y=0 (jar-verified).
        topSolidOrLiquid: *const fn (ptr: *anyopaque, x: i32, z: i32) i32,
        /// Provider average ground level (overworld 64 in vanilla
        /// `WorldProvider.getAverageGroundLevel` used by ground leveling).
        seaLevel: *const fn (ptr: *anyopaque) i32,
        /// Villager/witch spawn hook (no RNG involved; integration no-ops,
        /// tests count by kind for goldens).
        spawn: *const fn (ptr: *anyopaque, kind: SpawnKind, x: f64, y: f64, z: f64) void,
    };


    pub inline fn get(self: Placer, x: i32, y: i32, z: i32) Block {
        return self.vtable.get(self.ptr, x, y, z);
    }

    pub inline fn set(self: Placer, x: i32, y: i32, z: i32, id: ids.Id, meta: u4) void {
        self.vtable.set(self.ptr, x, y, z, id, meta);
    }

    pub inline fn topY(self: Placer, x: i32, z: i32) i32 {
        return self.vtable.topSolidOrLiquid(self.ptr, x, z);
    }

    pub inline fn groundBase(self: Placer) i32 {
        return self.vtable.seaLevel(self.ptr);
    }

    pub inline fn spawn(self: Placer, kind: SpawnKind, x: f64, y: f64, z: f64) void {
        self.vtable.spawn(self.ptr, kind, x, y, z);
    }
};

/// Entity kinds spawned during generation (runtime mobs, not blocks).
pub const SpawnKind = enum { villager, witch };

/// Exact `getTopSolidOrLiquidBlock` predicate (probed live over all 171
/// `ajn` fields: `c()=true` counts; nothing has the excluded `awt.j`
/// material). Input is a vanilla WIRE id (matches the probe).
pub fn countsForTopY(wire_id: u16) bool {
    return switch (wire_id) {
        // air, saplings, flowing water/lava, rails, web, flora, torches,
        // air, flora/saplings/crops/stems/reeds/cocoa, water+lava (still
        // and flowing), rails, web, torches, wire, ladders, levers,
        // buttons, snow layer, vines, lily pads, nether wart, portals,
        // tripwire, pots, skulls, activator rails, carpet, double plants.
        0, 6, 8, 9, 10, 11, 27, 28, 30, 31, 32, 37, 38, 39, 40, 50, 51, 55, 59, 65, 66, 69, 75, 76, 77, 78, 83, 90, 93, 94, 104, 105, 106, 111, 115, 119, 127, 131, 132, 140, 141, 142, 143, 144, 149, 150, 157, 171, 175 => false,
        // Leaves count for c() but use the excluded awt.j material.
        18, 161 => false,
        else => true,
    };
}

/// Liquid test for `isLiquidInStructureBoundingBox` (`Material.isLiquid`).
pub fn isLiquidId(id: ids.Id) bool {
    return id == .water or id == .flowing_water or id == .lava or id == .flowing_lava;
}

test "topY predicate spot checks" {
    // No water (still or flowing) and no leaves count; snow/rails don't.
    try std.testing.expect(!countsForTopY(8));
    try std.testing.expect(!countsForTopY(10));
    try std.testing.expect(!countsForTopY(9));
    try std.testing.expect(!countsForTopY(11));
    try std.testing.expect(!countsForTopY(18));
    try std.testing.expect(!countsForTopY(161));
    try std.testing.expect(!countsForTopY(78));
    try std.testing.expect(!countsForTopY(66));
    try std.testing.expect(countsForTopY(1));
    try std.testing.expect(!countsForTopY(0));
}
