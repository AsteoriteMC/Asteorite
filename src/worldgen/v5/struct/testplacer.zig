//! HashMap-backed placer for structure goldens (test-only).
//!
//! Flat-terrain preload must match the Java FakeWorld exactly:
//! y=0 bedrock, 1..60 stone, 61..63 dirt, 64 grass, air above.
//! `collect` gathers setBlock calls in order for diffing against the
//! Java `StructDump` output.

const std = @import("std");
const ids = @import("../../../ids.zig");
const wire = @import("../../../proto/v5/wire_ids.zig");
const placer_mod = @import("placer.zig");
const struct_mapgen = @import("mapgen.zig");

pub fn key(x: i32, y: i32, z: i32) u64 {
    return (@as(u64, @bitCast(@as(i64, x))) << 32) |
        (@as(u64, @bitCast(@as(i64, z))) << 16) |
        @as(u64, @as(u16, @truncate(@as(u32, @bitCast(y)))) & 0xffff);
}

pub const Rec = struct { x: i32, y: i32, z: i32, wire: u16, meta: u4 };

pub const TestWorld = struct {
    blocks: std.AutoHashMap(u64, u64), // key -> (wireId<<4)|meta
    writes: std.ArrayList(Rec),
    villagers: usize = 0,
    witches: usize = 0,
    spawns: usize = 0,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) TestWorld {
        return .{
            .blocks = std.AutoHashMap(u64, u64).init(alloc),
            .writes = .empty,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *TestWorld) void {
        self.blocks.deinit();
        self.writes.deinit(self.alloc);
    }

    pub fn preloadFlat(self: *TestWorld, x0: i32, z0: i32, x1: i32, z1: i32) !void {
        var x = x0;
        while (x <= x1) : (x += 1) {
            var z = z0;
            while (z <= z1) : (z += 1) {
                try self.blocks.put(key(x, 0, z), (@as(u64, 7) << 4));
                var y: i32 = 1;
                while (y <= 60) : (y += 1) try self.blocks.put(key(x, y, z), (@as(u64, 1) << 4));
                y = 61;
                while (y <= 63) : (y += 1) try self.blocks.put(key(x, y, z), (@as(u64, 3) << 4));
                try self.blocks.put(key(x, 64, z), (@as(u64, 2) << 4));
            }
        }
    }

    fn getBlock(self: *TestWorld, x: i32, y: i32, z: i32) placer_mod.Block {
        if (y < 0 or y > 255) return .{ .id = .air, .meta = 0 };
        const v = self.blocks.get(key(x, y, z)) orelse return .{ .id = .air, .meta = 0 };
        const w: u16 = @truncate(v >> 4);
        const m: u4 = @truncate(v & 0xf);
        const id = wire.fromWire(w) orelse .air;
        return .{ .id = id, .meta = m };
    }

    fn setBlock(self: *TestWorld, x: i32, y: i32, z: i32, id: ids.Id, meta: u4) void {
        self.blocks.put(key(x, y, z), (@as(u64, wire.toWire(id)) << 4) | meta) catch unreachable;
        self.writes.append(self.alloc, .{ .x = x, .y = y, .z = z, .wire = wire.toWire(id), .meta = meta }) catch unreachable;
    }

    fn topY(self: *TestWorld, x: i32, z: i32) i32 {
        var y: i32 = 255;
        while (y > 0) : (y -= 1) {
            const b = self.getBlock(x, y, z);
            if (placer_mod.countsForTopY(wire.toWire(b.id))) return y + 1;
        }
        return -1;
    }

    pub fn placer(self: *TestWorld) placer_mod.Placer {
        const VTable = struct {
            fn get(ptr: *anyopaque, x: i32, y: i32, z: i32) placer_mod.Block {
                const self_: *TestWorld = @ptrCast(@alignCast(ptr));
                return self_.getBlock(x, y, z);
            }
            fn set(ptr: *anyopaque, x: i32, y: i32, z: i32, id: ids.Id, meta: u4) void {
                const self_: *TestWorld = @ptrCast(@alignCast(ptr));
                self_.setBlock(x, y, z, id, meta);
            }
            fn top(ptr: *anyopaque, x: i32, z: i32) i32 {
                const self_: *TestWorld = @ptrCast(@alignCast(ptr));
                return self_.topY(x, z);
            }
            fn sea(ptr: *anyopaque) i32 {
                _ = ptr;
                return 64;
            }
            fn spawn(ptr: *anyopaque, kind: placer_mod.SpawnKind, x: f64, y: f64, z: f64) void {
                _ = x;
                _ = y;
                _ = z;
                const self_: *TestWorld = @ptrCast(@alignCast(ptr));
                self_.spawns += 1;
                if (kind == .villager) self_.villagers += 1;
                if (kind == .witch) self_.witches += 1;
            }
            const table = placer_mod.Placer.VTable{
                .get = get,
                .set = set,
                .topSolidOrLiquid = top,
                .seaLevel = sea,
                .spawn = spawn,
            };
        };
        return .{ .ptr = self, .vtable = &VTable.table };
    }
};
