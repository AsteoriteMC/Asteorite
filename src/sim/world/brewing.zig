//! Vanilla 1.7.10 brewing-stand tick (TileEntityBrewer port), quantized to
//! 20-tick quanta for the 1Hz server tick (same convention as furnace).
//!
//! Exact rules carried over: brew_time counts 400 -> 0 only while an
//! ingredient is present AND at least one bottle converts; any invalid
//! state resets to 400. At 0 the ingredient is consumed once and every
//! convertible bottle converts in place (no output slot — the bottles keep
//! their slots and stack counts).

const std = @import("std");
const item_mod = @import("../../item.zig");
const ids = @import("../../ids.zig");
const profile = @import("../../version.zig");

/// Owned stacks live in the server entity; this operates on borrowed views
/// (mutations write back counts in place, like vanilla).
pub const Slots = struct {
    bottles: [3]?item_mod.Stack = [_]?item_mod.Stack{null} ** 3,
    ingredient: ?item_mod.Stack = null,
};

/// Ticks per server quantum and ticks for one brew (400 = 20s).
pub const brew_quantum: u32 = 20;
pub const brew_target: u32 = 400;

/// A bottle slot converts when it holds a potion (any damage — water,
/// mundane, awkward and effect potions all brew) or a glass bottle being
/// filled... no: glass bottles never go in the stand (water comes from
/// bottles filled elsewhere — in 1.7.10 water bottles ARE id 288 damage 0,
/// filled at a water source). So: convertible iff id == potion and the
/// ingredient has a result for its damage.
pub fn converts(ing_id: ids.Id, ing_dmg: i16, bottle: ?item_mod.Stack) bool {
    const b = bottle orelse return false;
    if (b.id != ids.potion) return false;
    return profile.game.potion_data.brewResult(ing_id, ing_dmg, b.damage) != null;
}

pub fn canBrew(slots: Slots) bool {
    const ing = slots.ingredient orelse return false;
    if (ing.count <= 0) return false;
    for (slots.bottles) |b| {
        if (converts(ing.id, ing.damage, b)) return true;
    }
    return false;
}

/// One 20-tick quantum. Returns true when server state visibly changed
/// (ingredient consumed + bottles converted — caller marks dirty).
pub fn tick(slots: *Slots, brew: *u32) bool {
    if (!canBrew(slots.*)) {
        brew.* = brew_target;
        return false;
    }
    brew.* -|= brew_quantum;
    if (brew.* > 0) return false;
    doBrew(slots);
    brew.* = brew_target;
    return true;
}

fn doBrew(slots: *Slots) void {
    const ing = slots.ingredient orelse return;
    for (&slots.bottles) |*b| {
        const cur = b.* orelse continue;
        if (cur.id != ids.potion) continue;
        const out = profile.game.potion_data.brewResult(ing.id, ing.damage, cur.damage) orelse continue;
        b.* = .{ .id = ids.potion, .count = cur.count, .damage = out, .nbt = null };
    }
    slots.ingredient.?.count -= 1;
    if (slots.ingredient.?.count <= 0) slots.ingredient = null;
}

test "brewing: water plus wart makes awkward in 400 ticks" {
    var s = Slots{
        .bottles = .{
            .{ .id = ids.potion, .count = 1, .damage = 0, .nbt = null },
            .{ .id = ids.potion, .count = 1, .damage = 0, .nbt = null },
            .{ .id = ids.potion, .count = 1, .damage = 0, .nbt = null },
        },
        .ingredient = .{ .id = ids.nether_wart_item, .count = 2, .damage = 0, .nbt = null },
    };
    var brew: u32 = brew_target;
    // 19 quanta: 380 ticks, no conversion yet
    var i: usize = 0;
    while (i < 19) : (i += 1) _ = tick(&s, &brew);
    try std.testing.expectEqual(@as(u32, 20), brew);
    for (s.bottles) |b| try std.testing.expectEqual(@as(i16, 0), b.?.damage);
    // 20th quantum: converts in place, one ingredient consumed
    try std.testing.expect(tick(&s, &brew));
    try std.testing.expectEqual(@as(u32, brew_target), brew);
    for (s.bottles) |b| try std.testing.expectEqual(@as(i16, 16), b.?.damage);
    try std.testing.expectEqual(@as(i8, 1), s.ingredient.?.count);
}

test "brewing: invalid states reset, partial bottles convert" {
    // No ingredient: timer resets, bottles untouched.
    var s = Slots{
        .bottles = .{.{ .id = ids.potion, .count = 1, .damage = 16, .nbt = null }, null, null},
        .ingredient = null,
    };
    var brew: u32 = 120;
    try std.testing.expect(!tick(&s, &brew));
    try std.testing.expectEqual(@as(u32, brew_target), brew);
    // Ingredient with no convertible bottle: same reset.
    s.ingredient = .{ .id = ids.sugar, .count = 1, .damage = 0, .nbt = null };
    s.bottles[0].?.damage = 0; // water + sugar -> mundane, convertible
    brew = 120;
    try std.testing.expect(!tick(&s, &brew));
    try std.testing.expectEqual(@as(u32, 100), brew); // valid: counts down
    // Partial: one convertible bottle converts, others (glass bottle,
    // non-potion) stay; ingredient still consumed once.
    s = .{
        .bottles = .{
            .{ .id = ids.potion, .count = 1, .damage = 16, .nbt = null },
            .{ .id = ids.glass_bottle, .count = 1, .damage = 0, .nbt = null },
            null,
        },
        .ingredient = .{ .id = ids.sugar, .count = 1, .damage = 0, .nbt = null },
    };
    brew = 20;
    try std.testing.expect(tick(&s, &brew));
    try std.testing.expectEqual(@as(i16, 8194), s.bottles[0].?.damage);
    try std.testing.expectEqual(ids.glass_bottle, s.bottles[1].?.id);
    try std.testing.expect(s.bottles[2] == null);
    try std.testing.expect(s.ingredient == null);
}

test "brewing: full awkward to splash-swiftness chain converts in place" {
    var s = Slots{
        .bottles = .{.{ .id = ids.potion, .count = 3, .damage = 16, .nbt = null }, null, null},
        .ingredient = .{ .id = ids.sugar, .count = 1, .damage = 0, .nbt = null },
    };
    var brew: u32 = 20;
    _ = tick(&s, &brew);
    // stack count preserved, damage converted (stacks never split)
    try std.testing.expectEqual(@as(i8, 3), s.bottles[0].?.count);
    try std.testing.expectEqual(@as(i16, 8194), s.bottles[0].?.damage);
    // gunpowder next: splash
    s.ingredient = .{ .id = ids.gunpowder, .count = 1, .damage = 0, .nbt = null };
    brew = 20;
    _ = tick(&s, &brew);
    try std.testing.expectEqual(@as(i16, 8194 | 16384), s.bottles[0].?.damage);
}
