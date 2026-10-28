//! Shared micro-helpers for the redstone parts (block lookup + direction tables).

const ids = @import("../../../ids.zig");
const world_view = @import("../world_view.zig");

const Block = world_view.Block;


pub fn at(world: anytype, x: i32, y: i32, z: i32) Block {
    if (y < 0 or y > 255) return .{ .id = ids.air, .meta = 0 };
    return world.get(x, y, z) orelse .{ .id = ids.air, .meta = 0 };
}
pub const dirs6 = [_]struct { dx: i32, dy: i32, dz: i32, side: u3 }{
    .{ .dx = 0, .dy = -1, .dz = 0, .side = 0 },
    .{ .dx = 0, .dy = 1, .dz = 0, .side = 1 },
    .{ .dx = 0, .dy = 0, .dz = -1, .side = 2 },
    .{ .dx = 0, .dy = 0, .dz = 1, .side = 3 },
    .{ .dx = -1, .dy = 0, .dz = 0, .side = 4 },
    .{ .dx = 1, .dy = 0, .dz = 0, .side = 5 },
};
