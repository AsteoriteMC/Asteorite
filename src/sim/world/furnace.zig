//! Vanilla 1.7.10 TileEntityFurnace tick (CFR port of apg.h/k/j), quantized
//! to 20-tick quanta for the 1Hz server tick.
//!
//! Exact rules carried over: burn decrements first; fuel is consumed only
//! when burn hits 0 with fuel+smeltable input present (container item left
//! behind); cook advances only while burning AND smeltable; cook resets
//! otherwise; a burn-state flip swaps the lit/unlit block.

const std = @import("std");
const item_mod = @import("../../item.zig");
const smelting = @import("smelting.zig");
const ids = @import("../../ids.zig");
const profile = @import("../../version.zig");

/// Owned stacks live in the server entity; this operates on borrowed views
/// (mutations write back counts in place, like vanilla).
pub const Slots = struct {
    input: ?item_mod.Stack = null,
    fuel: ?item_mod.Stack = null,
    output: ?item_mod.Stack = null,
};

pub fn isBurning(burn: u32) bool {
    return burn > 0;
}

pub fn canSmelt(input: ?item_mod.Stack, output: ?item_mod.Stack) bool {
    const inp = input orelse return false;
    const res = smelting.findResult(inp.id, inp.damage) orelse return false;
    const out = output orelse return true;
    if (out.id != res.id or out.damage != res.dmg) return false;
    // vanilla: output.count < 64 && < outputMax && < resultMax
    if (out.count >= vanilla_output_cap) return false;
    if (@as(u16, @intCast(out.count)) >= profile.game.item_data.maxStackSize(out.id)) return false;
    if (@as(u16, @intCast(out.count)) >= profile.game.item_data.maxStackSize(res.id)) return false;
    return true;
}

/// Vanilla output-slot cap (the hardcoded 64 in TileEntityFurnace).
pub const vanilla_output_cap: i8 = 64;
/// Ticks per server quantum and ticks to smelt one item (200 = 10s).
pub const burn_quantum: u32 = 20;
pub const cook_target: u32 = 200;

/// One 20-tick quantum. Returns true when server state visibly changed
/// (fuel consumed, smelt done — caller marks dirty / rebroadcasts).
/// Burn-state flips are detected by the caller comparing isBurning around it.
pub fn tick(slots: *Slots, burn: *u32, total: *u32, cook: *u32) bool {
    var dirty = false;
    if (burn.* > 0) burn.* -|= burn_quantum;
    if (burn.* == 0) dirty = consumeFuel(slots, burn, total);
    if (isBurning(burn.*) and canSmelt(slots.input, slots.output)) {
        cook.* += burn_quantum;
        if (cook.* >= cook_target) {
            cook.* = 0;
            doSmelt(slots);
            dirty = true;
        }
    } else {
        cook.* = 0;
    }
    return dirty;
}

/// Burn one fuel item into `burn`/`total` (leaving its container behind).
/// False when there is nothing to burn (no fuel/input, unsmeltable, or a
/// fuel with zero burn time).
fn consumeFuel(slots: *Slots, burn: *u32, total: *u32) bool {
    if (slots.fuel == null or slots.input == null) return false;
    if (!canSmelt(slots.input, slots.output)) return false;
    const bt = smelting.burnTime(slots.fuel.?.id);
    if (bt == 0) return false;
    total.* = bt;
    burn.* = bt;
    // consume one fuel, leaving its container (lava bucket -> bucket)
    slots.fuel.?.count -= 1;
    if (slots.fuel.?.count > 0) return true;
    const cid = smelting.containerItem(slots.fuel.?.id);
    if (cid) |c| {
        slots.fuel = .{ .id = c, .count = 1, .damage = 0, .nbt = null };
    } else {
        slots.fuel = null;
    }
    return true;
}

fn doSmelt(slots: *Slots) void {
    if (!canSmelt(slots.input, slots.output)) return;
    const res = smelting.findResult(slots.input.?.id, slots.input.?.damage).?;
    if (slots.output == null) {
        slots.output = .{ .id = res.id, .count = res.count, .damage = res.dmg, .nbt = null };
    } else {
        // vanilla adds exactly 1 here (results are all count-1)
        slots.output.?.count += 1;
    }
    slots.input.?.count -= 1;
    if (slots.input.?.count <= 0) slots.input = null;
}

test "furnace: coal smelts iron on vanilla timing" {
    var s = Slots{
        .input = .{ .id = ids.iron_ore, .count = 1, .damage = 0, .nbt = null },
        .fuel = .{ .id = ids.coal, .count = 1, .damage = 0, .nbt = null },
        .output = null,
    };
    var burn: u32 = 0;
    var total: u32 = 0;
    var cook: u32 = 0;
    // tick 1: fuel consumed (burn 1600), cook 20
    try std.testing.expect(tick(&s, &burn, &total, &cook));
    try std.testing.expectEqual(@as(u32, 1600), burn);
    try std.testing.expect(s.fuel == null); // single coal consumed
    try std.testing.expectEqual(@as(u32, 20), cook);
    // 8 more ticks: cook 180, no output yet
    var i: usize = 0;
    while (i < 8) : (i += 1) _ = tick(&s, &burn, &total, &cook);
    try std.testing.expect(s.output == null);
    try std.testing.expectEqual(@as(u32, 180), cook);
    // 10th tick: smelt completes
    _ = tick(&s, &burn, &total, &cook);
    try std.testing.expectEqual(@as(u32, 0), cook);
    try std.testing.expect(s.output != null);
    try std.testing.expectEqual(ids.iron_ingot, s.output.?.id);
    try std.testing.expect(s.input == null);
    // burn keeps ticking down 20/tick (9 decrements over 10 ticks: tick 1
    // consumes fuel with no decrement since burn started at 0)
    try std.testing.expectEqual(@as(u32, 1600 - 180), burn);
}

test "furnace: no fuel/input/output-full stalls, lava bucket leaves bucket" {
    // no fuel: nothing happens, cook stays 0
    var s = Slots{ .input = .{ .id = ids.iron_ore, .count = 1, .damage = 0, .nbt = null } };
    var burn: u32 = 0;
    var total: u32 = 0;
    var cook: u32 = 0;
    try std.testing.expect(!tick(&s, &burn, &total, &cook));
    try std.testing.expectEqual(@as(u32, 0), cook);
    // output full: cook resets, no consume
    s = .{
        .input = .{ .id = ids.iron_ore, .count = 1, .damage = 0, .nbt = null },
        .fuel = .{ .id = ids.coal, .count = 1, .damage = 0, .nbt = null },
        .output = .{ .id = ids.iron_ingot, .count = 64, .damage = 0, .nbt = null },
    };
    // force burning first
    burn = 100;
    total = 100;
    cook = 40;
    _ = tick(&s, &burn, &total, &cook);
    try std.testing.expectEqual(@as(u32, 0), cook);
    try std.testing.expect(s.input.?.count == 1); // unconsumed
    // lava bucket leaves an empty bucket
    s = .{
        .input = .{ .id = ids.iron_ore, .count = 1, .damage = 0, .nbt = null },
        .fuel = .{ .id = ids.lava_bucket, .count = 1, .damage = 0, .nbt = null },
    };
    burn = 0;
    total = 0;
    cook = 0;
    _ = tick(&s, &burn, &total, &cook);
    try std.testing.expectEqual(@as(u32, 20000), burn);
    try std.testing.expect(s.fuel != null);
    try std.testing.expectEqual(ids.bucket, s.fuel.?.id);
}