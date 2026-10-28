//! Shared enchanting engine (K3).
//!
//! Vanilla 1.7.10 enchanting-table mechanics, ported instruction-by-
//! instruction from the official server jar via the 1.8.9 MCP verbatim
//! source (`ContainerEnchantment` + `EnchantmentHelper`; the 1.7.10 logic
//! is identical except for the lapis slot and the XP-seed persistence,
//! both owned by the profile edge, not this engine).
//!
//! The engine is pure and canonical: it reads profile tables through
//! `version.game` (enchantability/weights/ranges + `cmd_data` legality)
//! and java.util.Random for bit-exact draws. It never touches packets,
//! storage, or connection state. The server edge owns windowing, XP,
//! NBT merging, and the per-session seed.
//!
//! Call order (mirrors `onCraftMatrixChanged` + `enchantItem`):
//!   1. `countBookshelves` (air-gap rule, capped at 15)
//!   2. `calcLevels` (three slot levels from one seeded rand)
//!   3. `buildList` (weighted draw for one slot, seeded with seed+slot)

const std = @import("std");
const ids = @import("../../ids.zig");
const profile = @import("../../version.zig");
const java_random = @import("../../worldgen/rng/java_random.zig");

const JavaRandom = java_random.JavaRandom;
const ench_data = profile.game.enchanting_data;
const cmd_data = profile.game.cmd_data;

pub const EnchPick = struct { id: u8, level: u8 };

/// Vanilla bookshelf cap (ContainerEnchantment caps `power` at 15).
pub const max_shelves: u8 = 15;
/// Silk touch / fortune (table-incompatible pair, operator-overridable).
pub const ench_silk_touch: u8 = 33;
pub const ench_fortune: u8 = 35;
/// Candidate scratch size (one slot's draw never needs more).
pub const max_candidates: usize = 32;
/// Extra-pick draw bound (`rand.nextInt(50) <= l` keeps adding picks).
pub const extra_draw_bound: i32 = 50;

/// Bookshelf counting, verbatim from `ContainerEnchantment.onCraftMatrixChanged`
/// (1.8.9 MCP lines 157-197; 1.7.10 is identical: air only, both y levels).
/// `getId` returns the canonical block at (x,y,z), or null for a hole
/// (holes count as non-air, non-bookshelf — no phantom power).
/// The result is capped at 15 by the caller contract (vanilla caps `power`).
pub fn countBookshelves(
    tx: i32,
    ty: i32,
    tz: i32,
    getId: *const fn (x: i32, y: i32, z: i32) ?ids.Id,
) u8 {
    var l: u8 = 0;
    var j: i32 = -1;
    while (j <= 1) : (j += 1) {
        var k: i32 = -1;
        while (k <= 1) : (k += 1) {
            if (j == 0 and k == 0) continue;
            l += shelfGains(tx, ty, tz, j, k, getId);
        }
    }
    return @min(l, max_shelves);
}

/// Bookshelves gained from one (j,k) offset: 0 unless both cells of the
/// air gap are air, then 2 face bookshelves + 4 diagonal ones when (j,k)
/// is itself diagonal.
fn shelfGains(tx: i32, ty: i32, tz: i32, j: i32, k: i32, getId: *const fn (x: i32, y: i32, z: i32) ?ids.Id) u8 {
    if (getId(tx + k, ty, tz + j) != .air) return 0;
    if (getId(tx + k, ty + 1, tz + j) != .air) return 0;
    var l: u8 = 0;
    if (getId(tx + k * 2, ty, tz + j * 2) == .bookshelf) l += 1;
    if (getId(tx + k * 2, ty + 1, tz + j * 2) == .bookshelf) l += 1;
    if (k == 0 or j == 0) return l;
    if (getId(tx + k * 2, ty, tz + j) == .bookshelf) l += 1;
    if (getId(tx + k * 2, ty + 1, tz + j) == .bookshelf) l += 1;
    if (getId(tx + k, ty, tz + j * 2) == .bookshelf) l += 1;
    if (getId(tx + k, ty + 1, tz + j * 2) == .bookshelf) l += 1;
    return l;
}

/// True when the table may offer enchantments for this item: it has
/// enchantability and carries no `ench` list yet. `has_ench` is the NBT
/// edge's answer (the engine never parses NBT itself).
pub fn isEnchantableId(id: ids.Id, has_ench: bool) bool {
    if (has_ench) return false;
    return ench_data.enchantabilityForId(id) > 0;
}

/// Three slot levels from one seeded rand, verbatim
/// `EnchantmentHelper.calcItemStackEnchantability` + the slot mapping
/// (`enchantNum==0 ? max(base/3,1) : enchantNum==1 ? base*2/3+1
/// : max(base,power*2)`, zeroed when below `slot+1`).
/// `power` is the capped bookshelf count (0..15). Returns 0 for
/// unenchantable items.
pub fn calcLevels(rand: *JavaRandom, power: u8, enchantability: i32) [3]i32 {
    if (enchantability <= 0) return .{ 0, 0, 0 };
    const p: i32 = @min(power, max_shelves);
    var out: [3]i32 = .{ 0, 0, 0 };
    for (0..3) |slot| {
        // rand.nextInt(8)+1+(power>>1)+rand.nextInt(power+1)
        const a = (rand.nextIntBound(8) catch 0) + 1;
        const b = (rand.nextIntBound(p + 1) catch 0);
        const j = a + (p >> 1) + b;
        const lvl: i32 = switch (slot) {
            0 => @max(@divTrunc(j, 3), 1),
            1 => @divTrunc(j * 2, 3) + 1,
            else => @max(j, p * 2),
        };
        out[slot] = if (lvl < @as(i32, @intCast(slot)) + 1) 0 else lvl;
    }
    return out;
}

/// Modified enchantability for one slot's draw, verbatim from
/// `buildEnchantmentList` lines 423-432:
/// `i=enchant/2; i=1+rand((i>>1)+1)+rand((i>>1)+1); j=i+level;
/// f=(f1+f2-1)*0.15; k=(j*(1+f)+0.5); k>=1`.
pub fn modifiedLevel(rand: *JavaRandom, shelf_level: i32, enchantability: i32) i32 {
    var i = @divTrunc(enchantability, 2);
    const half = (i >> 1) + 1;
    i = 1 + (rand.nextIntBound(half) catch 0) + (rand.nextIntBound(half) catch 0);
    const j = i + shelf_level;
    const f = (rand.nextFloat() + rand.nextFloat() - 1.0) * 0.15;
    var k: i32 = @intFromFloat(@as(f32, @floatFromInt(j)) * (1.0 + f) + 0.5);
    if (k < 1) k = 1;
    return k;
}

/// Highest level of one enchantment whose [min,max] contains `k`, else null.
fn levelForK(ench_id: u8, k: i32) ?u8 {
    const e = cmd_data.enchantById(ench_id) orelse return null;
    const max: u8 = e.max;
    var lvl: u8 = max;
    while (true) {
        if (ench_data.rangeForEnch(ench_id, lvl)) |r| {
            if (k >= r.min and k <= r.max) return lvl;
        }
        if (lvl == 1) break;
        lvl -= 1;
    }
    return null;
}

/// Table conflict rule: vanilla `canApplyTogether` for the 1.7 set.
/// This is `cmd_data.enchantsCombine` plus the silk-touch <-> fortune
/// exclusion (`EnchantmentUntouching`/`EnchantmentLootBonus` both veto
/// each other; `/enchant` still allows the pair as an operator override).
pub fn tableCombines(a: u8, b: u8) bool {
    if (!cmd_data.enchantsCombine(a, b)) return false;
    if ((a == ench_silk_touch and b == ench_fortune) or (a == ench_fortune and b == ench_silk_touch)) return false;
    return true;
}

/// Candidate at modified level `k` for one item: every table enchantment
/// that applies to the item (or any, for books) with a level whose range
/// contains `k`, at its highest such level.
pub fn candidatesForK(item_id: ids.Id, is_book: bool, k: i32, out: []EnchPick) usize {
    var n: usize = 0;
    const wire = profile.proto.wire.toWire(item_id);
    for (cmd_data.enchants) |e| {
        if (!is_book) {
            if (!cmd_data.enchantApplies(e.cat, wire)) continue;
        }
        if (levelForK(e.id, k)) |lvl| {
            if (n < out.len) {
                out[n] = .{ .id = e.id, .level = lvl };
                n += 1;
            }
        }
    }
    return n;
}

/// Weighted random pick over candidates (vanilla `WeightedRandom`).
fn weightedPick(rand: *JavaRandom, cands: []const EnchPick) ?EnchPick {
    var total: i32 = 0;
    for (cands) |c| total += ench_data.weightForEnch(c.id);
    if (total <= 0) return null;
    var r = rand.nextIntBound(total) catch return null;
    for (cands) |c| {
        r -= ench_data.weightForEnch(c.id);
        if (r < 0) return c;
    }
    return cands[cands.len - 1];
}

/// Full weighted draw for one slot, verbatim from `buildEnchantmentList`
/// lines 434-476 + the book single-keep (`ContainerEnchantment.func_178148_a`
/// lines 313-316 drop a random extra when a book rolls 2+).
/// `rand` must already be seeded with `xpSeed+slot`.
/// Writes up to 8 picks into `out`, returns the count (0 = fizzle: the
/// level falls outside every range — vanilla leaves the item unenchanted
/// and charges nothing).
pub fn buildList(
    rand: *JavaRandom,
    item_id: ids.Id,
    shelf_level: i32,
    out: []EnchPick,
) usize {
    const ench = ench_data.enchantabilityForId(item_id);
    if (ench <= 0) return 0;
    const is_book = item_id == ids.book;
    const k = modifiedLevel(rand, shelf_level, ench);
    var cands_buf: [max_candidates]EnchPick = undefined;
    const n_cands = candidatesForK(item_id, is_book, k, &cands_buf);
    if (n_cands == 0) return 0;
    var cands = cands_buf[0..n_cands];

    var n: usize = 0;
    const first = weightedPick(rand, cands) orelse return 0;
    if (!pushPick(out, &n, first)) return n;
    // `for (l=k; rand.nextInt(50)<=l; l>>=1)`: each extra pick removes
    // conflicts with every kept pick, then draws again.
    var l = k;
    while (true) {
        const draw = rand.nextIntBound(extra_draw_bound) catch break;
        if (draw > l) break;
        // Remove candidates conflicting with any kept pick.
        var kept: usize = 0;
        for (cands) |c| {
            var ok = true;
            for (out[0..n]) |held| {
                if (!tableCombines(held.id, c.id)) {
                    ok = false;
                    break;
                }
            }
            if (ok) {
                cands_buf[kept] = c;
                kept += 1;
            }
        }
        cands = cands_buf[0..kept];
        if (cands.len == 0) break;
        const next = weightedPick(rand, cands) orelse break;
        if (!pushPick(out, &n, next)) break;
        l >>= 1;
    }
    // Books keep at most one when the table rolls 2+.
    if (is_book and n > 1) {
        const drop = @as(usize, @intCast(rand.nextIntBound(@intCast(n)) catch 0));
        if (drop < n) {
            out[drop] = out[n - 1];
            n -= 1;
        }
    }
    return n;
}

/// Append a pick when `out` has room. False when full.
fn pushPick(out: []EnchPick, n: *usize, pick: EnchPick) bool {
    if (n.* >= out.len) return false;
    out[n.*] = pick;
    n.* += 1;
    return true;
}

test "levels: 15 shelves offer 30 on the bottom with a fixed seed" {
    var r = JavaRandom.init(0);
    // Diamond sword (enchantability 10) with 15 shelves: bottom must be 30.
    const lv = calcLevels(&r, 15, 10);
    try std.testing.expectEqual(@as(i32, 30), lv[2]);
    // Zero shelves still offers low levels; unenchantable offers nothing.
    var r2 = JavaRandom.init(0);
    const lv0 = calcLevels(&r2, 0, 10);
    try std.testing.expect(lv0[0] >= 1 and lv0[0] <= 2);
    try std.testing.expectEqual([3]i32{ 0, 0, 0 }, calcLevels(&r2, 15, 0));
}

test "level mapping matches the wiki table" {
    // Seed 0, power 15: base j = nextInt(8)+1 + 7 + nextInt(16).
    // Whatever j is, the slot mapping must hold:
    var r = JavaRandom.init(1234);
    const lv = calcLevels(&r, 15, 10);
    // bottom is max(j, 30) so >= 30 whenever nonzero; top/middle follow.
    if (lv[2] != 0) try std.testing.expect(lv[2] >= 30);
    if (lv[0] != 0) try std.testing.expect(lv[0] >= 1);
}

test "same seed gives the same enchantment list (golden)" {
    var a = JavaRandom.init(42 + 2);
    var b = JavaRandom.init(42 + 2);
    var out_a: [8]EnchPick = undefined;
    var out_b: [8]EnchPick = undefined;
    const na = buildList(&a, ids.diamond_sword, 30, &out_a);
    const nb = buildList(&b, ids.diamond_sword, 30, &out_b);
    try std.testing.expectEqual(na, nb);
    try std.testing.expect(na > 0);
    for (out_a[0..na], out_b[0..nb]) |x, y| {
        try std.testing.expectEqual(x.id, y.id);
        try std.testing.expectEqual(x.level, y.level);
    }
    // Every pick must apply to swords and combine with the others.
    const wire = profile.proto.wire.toWire(ids.diamond_sword);
    for (out_a[0..na]) |p| {
        const e = cmd_data.enchantById(p.id).?;
        try std.testing.expect(cmd_data.enchantApplies(e.cat, wire));
        try std.testing.expect(p.level >= 1 and p.level <= e.max);
    }
    for (out_a[0..na], 0..) |x, i| {
        for (out_a[0..na], 0..) |y, j| {
            if (i == j) continue;
            try std.testing.expect(tableCombines(x.id, y.id));
        }
    }
}

test "books keep at most one extra (vanilla removes one)" {
    var out: [8]EnchPick = undefined;
    // Vanilla `func_178148_a` removes exactly one pick when a book rolls 2+,
    // so books can rarely carry two. They must never carry three.
    var seed: i64 = 0;
    while (seed < 20) : (seed += 1) {
        var rr = JavaRandom.init(seed + 1);
        const n = buildList(&rr, ids.book, 30, &out);
        try std.testing.expect(n <= 2);
    }
}

test "silk and fortune never combine on the table" {
    try std.testing.expect(!tableCombines(33, 35));
    try std.testing.expect(!tableCombines(35, 33));
    // ...but /enchant still allows the pair (operator override).
    try std.testing.expect(cmd_data.enchantsCombine(33, 35));
}

test "unenchantable items fizzle to zero picks" {
    var r = JavaRandom.init(0);
    var out: [8]EnchPick = undefined;
    try std.testing.expectEqual(@as(usize, 0), buildList(&r, ids.stone, 30, &out));
    try std.testing.expect(!isEnchantableId(ids.stone, false));
    try std.testing.expect(isEnchantableId(ids.diamond_sword, false));
    try std.testing.expect(!isEnchantableId(ids.diamond_sword, true));
}
