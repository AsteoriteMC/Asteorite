//! Structure bounding box + orientation (vanilla `asv`, jar-verified).
//!
//! Integer box, inclusive on both ends: min/max corners. `a`/`b`/`c` are
//! min x/y/z, `d`/`e`/`f` are max x/y/z (vanilla field order).

pub const BBox = struct {
    min_x: i32,
    min_y: i32,
    min_z: i32,
    max_x: i32,
    max_y: i32,
    max_z: i32,

    pub fn init(min_x: i32, min_y: i32, min_z: i32, max_x: i32, max_y: i32, max_z: i32) BBox {
        return .{ .min_x = min_x, .min_y = min_y, .min_z = min_z, .max_x = max_x, .max_y = max_y, .max_z = max_z };
    }

    /// Inverted box for `expandToInclude` accumulation (`asv.a()`).
    pub fn empty() BBox {
        return .{
            .min_x = std.math.maxInt(i32),
            .min_y = std.math.maxInt(i32),
            .min_z = std.math.maxInt(i32),
            .max_x = std.math.minInt(i32),
            .max_y = std.math.minInt(i32),
            .max_z = std.math.minInt(i32),
        };
    }

    /// Intersection test (`asv.a(asv)`).
    pub fn intersects(a: BBox, b: BBox) bool {
        return a.max_x >= b.min_x and a.min_x <= b.max_x and
            a.max_z >= b.min_z and a.min_z <= b.max_z and
            a.max_y >= b.min_y and a.min_y <= b.max_y;
    }

    /// 2D (x,z) overlap used by generateStructuresInChunk (`asv.a(x0,z0,x1,z1)`).
    pub fn intersectsXZ(a: BBox, x0: i32, z0: i32, x1: i32, z1: i32) bool {
        return a.max_x >= x0 and a.min_x <= x1 and a.max_z >= z0 and a.min_z <= z1;
    }

    /// Point containment (`asv.b(x,y,z)`).
    pub fn contains(a: BBox, x: i32, y: i32, z: i32) bool {
        return x >= a.min_x and x <= a.max_x and z >= a.min_z and z <= a.max_z and y >= a.min_y and y <= a.max_y;
    }

    /// Union (`asv.b(asv)`).
    pub fn expandToInclude(a: BBox, b: BBox) BBox {
        return .{
            .min_x = @min(a.min_x, b.min_x),
            .min_y = @min(a.min_y, b.min_y),
            .min_z = @min(a.min_z, b.min_z),
            .max_x = @max(a.max_x, b.max_x),
            .max_y = @max(a.max_y, b.max_y),
            .max_z = @max(a.max_z, b.max_z),
        };
    }

    /// Translation (`asv.a(dx,dy,dz)`).
    pub fn offset(a: BBox, dx: i32, dy: i32, dz: i32) BBox {
        return .{
            .min_x = a.min_x + dx,
            .min_y = a.min_y + dy,
            .min_z = a.min_z + dz,
            .max_x = a.max_x + dx,
            .max_y = a.max_y + dy,
            .max_z = a.max_z + dz,
        };
    }

    pub fn sizeX(a: BBox) i32 {
        return a.max_x - a.min_x + 1;
    }
    pub fn sizeY(a: BBox) i32 {
        return a.max_y - a.min_y + 1;
    }
    pub fn sizeZ(a: BBox) i32 {
        return a.max_z - a.min_z + 1;
    }

    pub fn centerX(a: BBox) i32 {
        return a.min_x + @divFloor(a.max_x - a.min_x + 1, 2);
    }
    pub fn centerY(a: BBox) i32 {
        return a.min_y + @divFloor(a.max_y - a.min_y + 1, 2);
    }
    pub fn centerZ(a: BBox) i32 {
        return a.min_z + @divFloor(a.max_z - a.min_z + 1, 2);
    }
};

/// Piece facing (`coordBaseMode`): 0 south(+Z), 1 west(-X), 2 north(-Z),
/// 3 east(+X). Matches vanilla numeric semantics in every helper.
pub const Facing = enum(u2) {
    south = 0,
    west = 1,
    north = 2,
    east = 3,

    pub fn fromInt(v: u2) Facing {
        return @enumFromInt(v);
    }
};

/// Oriented child footprint (`asv.a` static: anchor + local size +
/// facing). Used when attaching a child piece to a parent.
pub fn orientedBox(x: i32, y: i32, z: i32, w: i32, h: i32, d: i32, mode: Facing) BBox {
    return switch (mode) {
        .south => BBox.init(x, y, z, x + w - 1, y + h - 1, z + d - 1),
        .west => BBox.init(x - d + 1, y, z, x, y + h - 1, z + w - 1),
        .north => BBox.init(x, y, z - d + 1, x + w - 1, y + h - 1, z),
        .east => BBox.init(x, y, z, x + d - 1, y + h - 1, z + w - 1),
    };
}

/// Piece's own footprint (`aue` constructor: anchor + w/h/d with the
/// horizontal extents swapped for west/east facings, no shift).
pub fn sizedBox(x: i32, y: i32, z: i32, w: i32, h: i32, d: i32, mode: Facing) BBox {
    return switch (mode) {
        .south, .north => BBox.init(x, y, z, x + w - 1, y + h - 1, z + d - 1),
        .west, .east => BBox.init(x, y, z, x + d - 1, y + h - 1, z + w - 1),
    };
}

const std = @import("std");

test "bbox intersects/contains/offset/oriented match jar" {
    const b = BBox.init(0, 0, 0, 15, 15, 15);
    try std.testing.expect(b.intersects(BBox.init(15, 0, 15, 31, 15, 31)));
    try std.testing.expect(!b.intersects(BBox.init(16, 0, 0, 31, 15, 15)));
    try std.testing.expect(b.contains(15, 15, 15));
    try std.testing.expect(!b.contains(16, 0, 0));
    try std.testing.expect(b.intersectsXZ(15, 15, 31, 31));
    try std.testing.expect(!b.intersectsXZ(16, 0, 31, 15));
    const moved = b.offset(0, -4, 0);
    try std.testing.expectEqual(@as(i32, -4), moved.min_y);
    try std.testing.expectEqual(@as(i32, 11), moved.max_y);
    // Oriented boxes: 21x15x21 desert pyramid footprint (static child form).
    try std.testing.expectEqual(BBox.init(0, 64, 0, 20, 78, 20), orientedBox(0, 64, 0, 21, 15, 21, .south));
    try std.testing.expectEqual(BBox.init(0, 64, 0, 20, 78, 20), orientedBox(20, 64, 0, 21, 15, 21, .west));
    // Constructor form swaps extents without shifting.
    try std.testing.expectEqual(BBox.init(20, 64, 0, 40, 78, 20), sizedBox(20, 64, 0, 21, 15, 21, .west));
    try std.testing.expectEqual(BBox.init(0, 64, 0, 20, 78, 20), sizedBox(0, 64, 0, 21, 15, 21, .south));
}
