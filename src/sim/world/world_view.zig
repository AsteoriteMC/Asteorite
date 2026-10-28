//! Typed world-access boundary for shared engines at an I/O edge.
//!
//! Hot simulation paths keep using a comptime adapter (the `get`/`set`/`pop`
//! contract) so the profile is inlined; this vtable form is the stable edge
//! used by server/storage adapters that cannot be generic over every caller.
//! The same `WorldView` carries the selected profile's block table and
//! redstone rules, so an engine never imports a profile root directly.

const ids = @import("../../ids.zig");
const block = @import("../../game/block.zig");
const rules_mod = @import("../../game/rules.zig");

pub const Block = struct { id: ids.Id, meta: u4 };

pub const VTable = struct {
    get: *const fn (ctx: *anyopaque, x: i32, y: i32, z: i32) ?Block,
    set: *const fn (ctx: *anyopaque, x: i32, y: i32, z: i32, id: ids.Id, meta: u4) void,
    pop: *const fn (ctx: *anyopaque, x: i32, y: i32, z: i32, old_id: ids.Id, old_meta: u4) void,
};

pub const WorldView = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    blocks: *const block.Table,
    rules: *const rules_mod.RedstoneRules,

    pub fn get(self: WorldView, x: i32, y: i32, z: i32) ?Block {
        return self.vtable.get(self.ctx, x, y, z);
    }

    pub fn set(self: WorldView, x: i32, y: i32, z: i32, id: ids.Id, meta: u4) void {
        self.vtable.set(self.ctx, x, y, z, id, meta);
    }

    pub fn pop(self: WorldView, x: i32, y: i32, z: i32, old_id: ids.Id, old_meta: u4) void {
        self.vtable.pop(self.ctx, x, y, z, old_id, old_meta);
    }

    /// Build a view over a type with `get`/`set`/`pop` methods. The context
    /// must outlive the view (server callers build one per operation).
    pub fn init(
        ctx: anytype,
        blocks: *const block.Table,
        rules: *const rules_mod.RedstoneRules,
    ) WorldView {
        const T = @TypeOf(ctx.*);
        const Impl = struct {
            fn implGet(c: *anyopaque, x: i32, y: i32, z: i32) ?Block {
                const self: *T = @ptrCast(@alignCast(c));
                return self.get(x, y, z);
            }
            fn implSet(c: *anyopaque, x: i32, y: i32, z: i32, id: ids.Id, meta: u4) void {
                const self: *T = @ptrCast(@alignCast(c));
                self.set(x, y, z, id, meta);
            }
            fn implPop(c: *anyopaque, x: i32, y: i32, z: i32, old_id: ids.Id, old_meta: u4) void {
                const self: *T = @ptrCast(@alignCast(c));
                self.pop(x, y, z, old_id, old_meta);
            }
            const vtable = VTable{ .get = implGet, .set = implSet, .pop = implPop };
        };
        return .{
            .ctx = @ptrCast(ctx),
            .vtable = &Impl.vtable,
            .blocks = blocks,
            .rules = rules,
        };
    }
};

test "world view dispatches get/set/pop to the adapter" {
    const std = @import("std");
    const mc5_blocks = @import("../../game/mc5/blocks.zig");
    const mc5_rules = @import("../../game/rules.zig");

    const Mock = struct {
        block: Block = .{ .id = .stone, .meta = 0 },
        sets: usize = 0,
        pops: usize = 0,

        pub fn get(self: *@This(), x: i32, y: i32, z: i32) ?Block {
            _ = x;
            _ = y;
            _ = z;
            return self.block;
        }
        pub fn set(self: *@This(), x: i32, y: i32, z: i32, id: ids.Id, meta: u4) void {
            _ = x;
            _ = y;
            _ = z;
            self.block = .{ .id = id, .meta = meta };
            self.sets += 1;
        }
        pub fn pop(self: *@This(), x: i32, y: i32, z: i32, old_id: ids.Id, old_meta: u4) void {
            _ = x;
            _ = y;
            _ = z;
            _ = old_id;
            _ = old_meta;
            self.block = .{ .id = .air, .meta = 0 };
            self.pops += 1;
        }
    };

    var mock = Mock{};
    const view = WorldView.init(&mock, &mc5_blocks.table, &mc5_rules.mc5_redstone);
    try std.testing.expectEqual(ids.stone, view.get(1, 2, 3).?.id);
    view.set(1, 2, 3, .redstone_wire, 15);
    try std.testing.expectEqual(@as(usize, 1), mock.sets);
    try std.testing.expectEqual(@as(u4, 15), mock.block.meta);
    view.pop(1, 2, 3, .redstone_wire, 15);
    try std.testing.expectEqual(@as(usize, 1), mock.pops);
    try std.testing.expectEqual(ids.air, mock.block.id);
    try std.testing.expectEqual(@as(u8, 12), view.rules.piston_push_limit);
    try std.testing.expect(view.blocks.get(.stone).normal_cube);
}
