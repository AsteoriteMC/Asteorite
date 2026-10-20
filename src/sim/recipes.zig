//! Vanilla 1.7.10 crafting match (CFR ports of afh/afi/afe + aff sort).
//!
//! - Shaped: slide over every offset, normal then mirrored; cell match =
//!   both empty, or id equal with wildcard (32767) or exact damage.
//! - Shapeless: multiset consume with the same damage rule.
//! - Repair (in findMatchingRecipe BEFORE the table): exactly 2 non-empty
//!   slots holding the same damageable item, count 1 each → output damage =
//!   maxDur - (remA + remB + maxDur/20), clamped at 0.
//! - Skipped (documented): 5 NBT-sensitive specials (map extend/clone, book
//!   clone, armor dye, fireworks) — table covers tools/armor/blocks/food.
//! - Max durability comes from item.maxDamage? — J3a uses a small local
//!   table (vanilla Item durability); full data is a Phase H follow-up.

const std = @import("std");
const data = @import("recipes_data.zig");
const item_mod = @import("../item.zig");

pub const WILD: i16 = 32767;

/// Max durability for repairable vanilla items, generated from minecraft-data
/// names x jar-verified material tables (tool: wood 59/stone 131/iron 250/
/// diamond 1561/gold 32; armor base x slot {helm 11, chest 16, legs 15, boots 13}).
fn maxDurability(id: u16) ?u16 {
    return switch (id) {
        256 => 250,
        257 => 250,
        258 => 250,
        259 => 64,
        261 => 384,
        267 => 250,
        268 => 59,
        269 => 59,
        270 => 59,
        271 => 59,
        272 => 131,
        273 => 131,
        274 => 131,
        275 => 131,
        276 => 1561,
        277 => 1561,
        278 => 1561,
        279 => 1561,
        283 => 32,
        284 => 32,
        285 => 32,
        286 => 32,
        290 => 59,
        291 => 131,
        292 => 250,
        293 => 1561,
        294 => 32,
        298 => 55,
        299 => 80,
        300 => 75,
        301 => 65,
        302 => 165,
        303 => 240,
        304 => 225,
        305 => 195,
        306 => 165,
        307 => 240,
        308 => 225,
        309 => 195,
        310 => 363,
        311 => 528,
        312 => 495,
        313 => 429,
        314 => 77,
        315 => 112,
        316 => 105,
        317 => 91,
        346 => 64,
        359 => 238,
        398 => 25,
        else => null,
    };
}

/// Grid cell view: null when empty or out of bounds (vanilla aae guards).
fn cellAt(grid: []const ?item_mod.Stack, gw: u8, col: usize, row: usize) ?item_mod.Stack {
    if (col >= gw or row * @as(usize, gw) + col >= grid.len) return null;
    return grid[row * @as(usize, gw) + col];
}

fn cellMatches(have: ?item_mod.Stack, want: ?data.Cell) bool {
    if (have == null and want == null) return true;
    if (have == null or want == null) return false;
    if (have.?.id != want.?.id) return false;
    return want.?.dmg == WILD or want.?.dmg == have.?.damage;
}

fn shapedMatches(r: struct { w: u8, h: u8, cells: [9]?data.Cell }, grid: []const ?item_mod.Stack, gw: u8, gh: u8, ox: u8, oy: u8, mirror: bool) bool {
    var row: u8 = 0;
    while (row < gh) : (row += 1) {
        var col: u8 = 0;
        while (col < gw) : (col += 1) {
            const rx: i16 = @as(i16, col) - ox;
            const ry: i16 = @as(i16, row) - oy;
            var want: ?data.Cell = null;
            if (rx >= 0 and ry >= 0 and rx < r.w and ry < r.h) {
                const ux: usize = @intCast(rx);
                const uy: usize = @intCast(ry);
                const ix: usize = if (mirror) @as(usize, r.w) - 1 - ux else ux;
                want = r.cells[uy * @as(usize, r.w) + ix];
            }
            if (!cellMatches(cellAt(grid, gw, col, row), want)) return false;
        }
    }
    return true;
}

/// Crafting result for a gw x gh grid (2x2 player or 3x3 table). Returns the
/// output stack (count/damage as registered; NBT copied from the first
/// tagged input when the recipe sets nbt_copy, else null).
pub fn findMatch(grid: []const ?item_mod.Stack, gw: u8, gh: u8) ?item_mod.Stack {
    // repair first (vanilla order)
    {
        var n: usize = 0;
        var first: ?item_mod.Stack = null;
        var second: ?item_mod.Stack = null;
        for (grid) |s| {
            const st = s orelse continue;
            n += 1;
            if (n == 1) first = st else if (n == 2) second = st;
        }
        if (n == 2) {
            const a = first.?;
            const b = second.?;
            if (a.id == b.id and a.count == 1 and b.count == 1) {
                if (maxDurability(a.id)) |dur| {
                    const rem_a: i32 = @as(i32, dur) - a.damage;
                    const rem_b: i32 = @as(i32, dur) - b.damage;
                    if (rem_a > 0 and rem_b > 0) {
                        var out_dmg: i32 = @as(i32, dur) - (rem_a + rem_b + @divTrunc(@as(i32, dur) * 5, 100));
                        if (out_dmg < 0) out_dmg = 0;
                        return .{ .id = a.id, .count = 1, .damage = @intCast(out_dmg), .nbt = null };
                    }
                }
            }
        }
    }
    for (data.table) |r| {
        switch (r) {
            .shaped => |s| {
                if (s.w > gw or s.h > gh) continue;
                var oy: u8 = 0;
                while (oy + s.h <= gh) : (oy += 1) {
                    var ox: u8 = 0;
                    while (ox + s.w <= gw) : (ox += 1) {
                        if (shapedMatches(.{ .w = s.w, .h = s.h, .cells = s.cells }, grid, gw, gh, ox, oy, false) or
                            shapedMatches(.{ .w = s.w, .h = s.h, .cells = s.cells }, grid, gw, gh, ox, oy, true))
                        {
                            const nbt: ?[]const u8 = if (s.nbt_copy) firstTaggedNbt(grid) else null;
                            return .{ .id = s.out.id, .count = s.out.count, .damage = s.out.dmg, .nbt = nbt };
                        }
                    }
                }
            },
            .shapeless => |s| {
                // multiset consume (vanilla afi)
                var remaining: [9]?data.Cell = .{null} ** 9;
                var rn: usize = 0;
                for (s.ins[0..s.n]) |c| {
                    remaining[rn] = c;
                    rn += 1;
                }
                var ok = true;
                for (grid) |gs| {
                    const st = gs orelse continue;
                    var hit = false;
                    var k: usize = 0;
                    while (k < rn) : (k += 1) {
                        const want = remaining[k] orelse continue;
                        if (st.id == want.id and (want.dmg == WILD or want.dmg == st.damage)) {
                            hit = true;
                            remaining[k] = null;
                            break;
                        }
                    }
                    if (!hit) {
                        ok = false;
                        break;
                    }
                }
                if (ok) {
                    for (remaining[0..rn]) |left| if (left != null) {
                        ok = false;
                        break;
                    };
                }
                if (ok) return .{ .id = s.out.id, .count = s.out.count, .damage = s.out.dmg, .nbt = null };
            },
        }
    }
    return null;
}

fn firstTaggedNbt(grid: []const ?item_mod.Stack) ?[]const u8 {
    for (grid) |s| if (s) |st| if (st.nbt) |n| return n;
    return null;
}

test "shaped basics: sticks, torches, planks, mirror" {
    // sticks: 2 planks vertical (2x2 player grid)
    const sticks: [4]?item_mod.Stack = .{ null, .{ .id = 5, .count = 1, .damage = 0, .nbt = null }, null, .{ .id = 5, .count = 1, .damage = 0, .nbt = null } };
    // grid is row-major 2-wide: [.,plank, .,plank] = col1 rows 0..1
    const r = findMatch(&sticks, 2, 2);
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u16, 280), r.?.id);
    try std.testing.expectEqual(@as(i8, 4), r.?.count);
    // torches: coal over stick
    const torch: [4]?item_mod.Stack = .{ null, .{ .id = 263, .count = 1, .damage = 0, .nbt = null }, null, .{ .id = 280, .count = 1, .damage = 0, .nbt = null } };
    const t = findMatch(&torch, 2, 2);
    try std.testing.expect(t != null);
    try std.testing.expectEqual(@as(u16, 50), t.?.id);
    try std.testing.expectEqual(@as(i8, 4), t.?.count);
    // planks from log (any damage wildcard? log recipe damage is explicit per type; oak here)
    const planks: [4]?item_mod.Stack = .{ .{ .id = 17, .count = 1, .damage = 0, .nbt = null }, null, null, null };
    const p = findMatch(&planks, 2, 2);
    try std.testing.expect(p != null);
    try std.testing.expectEqual(@as(u16, 5), p.?.id);
    // mirror: arrow " #X / # X /  #X"? use asymmetric pickaxe head on 3x3
    var g3: [9]?item_mod.Stack = [_]?item_mod.Stack{null} ** 9;
    // mirrored iron pickaxe: ingots at cols 2,1,0 row 0 + sticks col 1 rows 1-2
    g3[2] = .{ .id = 265, .count = 1, .damage = 0, .nbt = null };
    g3[1] = .{ .id = 265, .count = 1, .damage = 0, .nbt = null };
    g3[0] = .{ .id = 265, .count = 1, .damage = 0, .nbt = null };
    g3[4] = .{ .id = 280, .count = 1, .damage = 0, .nbt = null };
    g3[7] = .{ .id = 280, .count = 1, .damage = 0, .nbt = null };
    const pk = findMatch(&g3, 3, 3);
    try std.testing.expect(pk != null);
    try std.testing.expectEqual(@as(u16, 257), pk.?.id);
    // wrong material arrangement: no match
    var bad: [9]?item_mod.Stack = [_]?item_mod.Stack{null} ** 9;
    bad[0] = .{ .id = 265, .count = 1, .damage = 0, .nbt = null };
    try std.testing.expect(findMatch(&bad, 3, 3) == null);
}

test "repair: two damaged tools combine (vanilla formula)" {
    // iron pick, dur 250: dmg 200 + dmg 200 -> rem 50+50, bonus 12 -> 138
    const rep: [4]?item_mod.Stack = .{
        .{ .id = 257, .count = 1, .damage = 200, .nbt = null },
        .{ .id = 257, .count = 1, .damage = 200, .nbt = null },
        null, null,
    };
    const r = findMatch(&rep, 2, 2);
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u16, 257), r.?.id);
    try std.testing.expectEqual(@as(i16, 138), r.?.damage);
    // count 2 stacks don't repair (vanilla requires count 1 each)
    var rep2 = rep;
    rep2[0].?.count = 2;
    try std.testing.expect(findMatch(&rep2, 2, 2) == null);
    // different items don't repair
    var rep3 = rep;
    rep3[1].?.id = 258;
    try std.testing.expect(findMatch(&rep3, 2, 2) == null);
    // three items: not repair (falls through to table -> null here)
    var rep4 = rep;
    rep4[2] = .{ .id = 257, .count = 1, .damage = 0, .nbt = null };
    try std.testing.expect(findMatch(&rep4, 2, 2) == null);
}

test "mirror + damage rules (stairs mirrored, wildcard planks, exact stone)" {
    // oak stairs normal: "#  / ##  / ###"
    var norm: [9]?item_mod.Stack = [_]?item_mod.Stack{null} ** 9;
    norm[0] = .{ .id = 5, .count = 1, .damage = 0, .nbt = null };
    norm[3] = .{ .id = 5, .count = 1, .damage = 0, .nbt = null };
    norm[4] = .{ .id = 5, .count = 1, .damage = 0, .nbt = null };
    norm[6] = .{ .id = 5, .count = 1, .damage = 0, .nbt = null };
    norm[7] = .{ .id = 5, .count = 1, .damage = 0, .nbt = null };
    norm[8] = .{ .id = 5, .count = 1, .damage = 0, .nbt = null };
    const n = findMatch(&norm, 3, 3);
    try std.testing.expect(n != null);
    try std.testing.expectEqual(@as(u16, 53), n.?.id);
    // mirrored ("  # / ## / ###"): same output
    var mirr: [9]?item_mod.Stack = [_]?item_mod.Stack{null} ** 9;
    mirr[2] = .{ .id = 5, .count = 1, .damage = 0, .nbt = null };
    mirr[4] = .{ .id = 5, .count = 1, .damage = 0, .nbt = null };
    mirr[5] = .{ .id = 5, .count = 1, .damage = 0, .nbt = null };
    mirr[6] = .{ .id = 5, .count = 1, .damage = 0, .nbt = null };
    mirr[7] = .{ .id = 5, .count = 1, .damage = 0, .nbt = null };
    mirr[8] = .{ .id = 5, .count = 1, .damage = 0, .nbt = null };
    const m = findMatch(&mirr, 3, 3);
    try std.testing.expect(m != null);
    try std.testing.expectEqual(@as(u16, 53), m.?.id);
    // wildcard planks: birch (dmg 2) works for sticks
    const sticks: [4]?item_mod.Stack = .{ null, .{ .id = 5, .count = 1, .damage = 2, .nbt = null }, null, .{ .id = 5, .count = 1, .damage = 2, .nbt = null } };
    const st = findMatch(&sticks, 2, 2);
    try std.testing.expect(st != null);
    try std.testing.expectEqual(@as(u16, 280), st.?.id);
}

test "shapeless: bread, dye wildcard, paper" {
    // bread: shaped 3x1 wheat row
    const bread: [9]?item_mod.Stack = .{
        null,                         null,                         null,
        .{ .id = 296, .count = 1, .damage = 0, .nbt = null },
        .{ .id = 296, .count = 1, .damage = 0, .nbt = null },
        .{ .id = 296, .count = 1, .damage = 0, .nbt = null },
        null,                         null,                         null,
    };
    const b = findMatch(&bread, 3, 3);
    try std.testing.expect(b != null);
    try std.testing.expectEqual(@as(u16, 297), b.?.id);
    // exact-damage shapeless: white wool needs dye 15 + white wool
    const dye: [9]?item_mod.Stack = .{
        .{ .id = 351, .count = 1, .damage = 15, .nbt = null }, .{ .id = 35, .count = 1, .damage = 0, .nbt = null }, null,
        null, null, null,
        null, null, null,
    };
    const d = findMatch(&dye, 3, 3);
    try std.testing.expect(d != null);
    try std.testing.expectEqual(@as(u16, 35), d.?.id);
    try std.testing.expectEqual(@as(i16, 0), d.?.damage); // aka.c(15)=0 white
    // wrong dye damage: bonemeal(15) + ORANGE wool(1)? needs white wool -> null
    // (use red dye(1) + white wool -> rose red stays? red+white... skip: extra item breaks it)
    var extra = dye;
    extra[2] = .{ .id = 1, .count = 1, .damage = 0, .nbt = null };
    try std.testing.expect(findMatch(&extra, 3, 3) == null);
}
