//! Structure chest/dispenser contents (vanilla `qx`, jar-verified).
//!
//! Chests/dispensers are placed as BLOCKS (ZC1 has no tile entities —
//! same precedent as dungeons), but the loot RNG draws are replicated
//! EXACTLY so every downstream draw stays vanilla-identical. Contents
//! themselves are discarded.
//!
//! Draw sequence per `qx.a(Random, qx[], count)` call (verified against
//! the decompiled method):
//!   repeat count times:
//!     entry = weightedPick(rand, table)   // 1x nextInt(totalWeight)
//!     n = min + rand.nextInt(max-min+1)   // 1 draw
//!     if (limit >= n): slot = rand.nextInt(invSize)      // 1 draw
//!     else: repeat n times: slot = rand.nextInt(invSize) // n draws
//! All current tables take the single-slot path (verified: every entry
//! with limit 1 has max 1; every entry with max > 1 has limit >= max),
//! but the branch is encoded anyway.

const java_random = @import("../../rng/java_random.zig");

pub const JavaRandom = java_random.JavaRandom;

pub const chest_slots: i32 = 27;
pub const dispenser_slots: i32 = 9;

pub const Entry = struct {
    /// Max stack size of the item (branch selector).
    limit: u8,
    weight: u8,
    min: u8,
    max: u8,
};

/// Weighted pick (`qv.a`): nextInt(total), subtract, first negative wins.
fn weightedPick(rand: *JavaRandom, table: []const Entry) usize {
    var total: i32 = 0;
    for (table) |e| total += e.weight;
    var roll = rand.nextIntBound(total) catch unreachable;
    for (table, 0..) |e, i| {
        roll -= e.weight;
        if (roll < 0) return i;
    }
    unreachable;
}

/// Replicate one `qx.a` call's draws; results discarded. `count` is the
/// `var3` roll count, `inv_size` the container slot count.
pub fn replicateChestDraws(rand: *JavaRandom, table: []const Entry, count: i32, inv_size: i32) void {
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const e = table[weightedPick(rand, table)];
        const span: i32 = @as(i32, e.max) - @as(i32, e.min) + 1;
        const n: i32 = @as(i32, e.min) + (rand.nextIntBound(span) catch unreachable);
        if (@as(i32, e.limit) >= n) {
            _ = rand.nextIntBound(inv_size) catch unreachable;
        } else {
            var j: i32 = 0;
            while (j < n) : (j += 1) {
                _ = rand.nextIntBound(inv_size) catch unreachable;
            }
        }
    }
}

// Tables below: (limit, weight, min, max). Limits probed live per item id;
// weights dumped live from the static qx[] fields. Order matches the jar.

/// Mineshaft corridor chest (`asx.a`, 13 entries).
pub const mineshaft_corridor = [_]Entry{
    .{ .limit = 64, .weight = 10, .min = 1, .max = 5 }, // iron ingot
    .{ .limit = 64, .weight = 5, .min = 1, .max = 3 }, // gold ingot
    .{ .limit = 64, .weight = 5, .min = 4, .max = 9 }, // redstone
    .{ .limit = 64, .weight = 5, .min = 4, .max = 9 }, // lapis
    .{ .limit = 64, .weight = 3, .min = 1, .max = 2 }, // diamond
    .{ .limit = 64, .weight = 10, .min = 3, .max = 8 }, // coal
    .{ .limit = 64, .weight = 15, .min = 1, .max = 3 }, // bread
    .{ .limit = 1, .weight = 1, .min = 1, .max = 1 }, // iron pickaxe
    .{ .limit = 64, .weight = 10, .min = 4, .max = 8 }, // rails
    .{ .limit = 64, .weight = 10, .min = 2, .max = 4 }, // melon seeds
    .{ .limit = 64, .weight = 10, .min = 2, .max = 4 }, // pumpkin seeds
    .{ .limit = 1, .weight = 3, .min = 1, .max = 1 }, // saddle
    .{ .limit = 1, .weight = 1, .min = 1, .max = 1 }, // iron horse armor
};

/// Nether fortress chest (`ats.a`, 11 entries). Deferred with fortresses.
pub const fortress_corridor = [_]Entry{
    .{ .limit = 64, .weight = 5, .min = 1, .max = 3 }, // diamond
    .{ .limit = 64, .weight = 5, .min = 1, .max = 5 }, // iron ingot
    .{ .limit = 64, .weight = 15, .min = 1, .max = 3 }, // gold ingot
    .{ .limit = 1, .weight = 5, .min = 1, .max = 1 }, // gold sword
    .{ .limit = 1, .weight = 5, .min = 1, .max = 1 }, // gold chestplate
    .{ .limit = 1, .weight = 5, .min = 1, .max = 1 }, // flint and steel
    .{ .limit = 64, .weight = 10, .min = 3, .max = 7 }, // nether wart
    .{ .limit = 1, .weight = 8, .min = 1, .max = 1 }, // saddle
    .{ .limit = 1, .weight = 10, .min = 1, .max = 1 }, // gold horse armor
    .{ .limit = 1, .weight = 5, .min = 1, .max = 1 }, // iron horse armor
    .{ .limit = 1, .weight = 3, .min = 1, .max = 1 }, // diamond horse armor
};

/// Desert pyramid (`aub.i`) and jungle pyramid (`auc.l`) share one table.
pub const pyramid = [_]Entry{
    .{ .limit = 64, .weight = 3, .min = 1, .max = 3 }, // diamond
    .{ .limit = 64, .weight = 10, .min = 1, .max = 5 }, // iron ingot
    .{ .limit = 64, .weight = 15, .min = 2, .max = 7 }, // gold ingot
    .{ .limit = 64, .weight = 2, .min = 1, .max = 3 }, // emerald
    .{ .limit = 64, .weight = 20, .min = 4, .max = 6 }, // bone
    .{ .limit = 64, .weight = 16, .min = 3, .max = 7 }, // rotten flesh
    .{ .limit = 1, .weight = 3, .min = 1, .max = 1 }, // saddle
    .{ .limit = 1, .weight = 1, .min = 1, .max = 1 }, // iron horse armor
    .{ .limit = 1, .weight = 1, .min = 1, .max = 1 }, // gold horse armor
    .{ .limit = 1, .weight = 1, .min = 1, .max = 1 }, // diamond horse armor
};

/// Jungle dispenser arrows (`auc.m`, 1 entry, dispenser slots).
pub const jungle_dispenser = [_]Entry{
    .{ .limit = 64, .weight = 30, .min = 2, .max = 7 }, // arrow
};

/// Stronghold crossing (`aum.a`, 18 entries).
pub const stronghold_crossing = [_]Entry{
    .{ .limit = 16, .weight = 10, .min = 1, .max = 1 }, // ender pearl
    .{ .limit = 64, .weight = 3, .min = 1, .max = 3 }, // diamond
    .{ .limit = 64, .weight = 10, .min = 1, .max = 5 }, // iron ingot
    .{ .limit = 64, .weight = 5, .min = 1, .max = 3 }, // gold ingot
    .{ .limit = 64, .weight = 5, .min = 4, .max = 9 }, // redstone
    .{ .limit = 64, .weight = 15, .min = 1, .max = 3 }, // bread
    .{ .limit = 64, .weight = 15, .min = 1, .max = 3 }, // apple
    .{ .limit = 1, .weight = 5, .min = 1, .max = 1 }, // iron pickaxe
    .{ .limit = 1, .weight = 5, .min = 1, .max = 1 }, // iron sword
    .{ .limit = 1, .weight = 5, .min = 1, .max = 1 }, // iron chestplate
    .{ .limit = 1, .weight = 5, .min = 1, .max = 1 }, // iron helmet
    .{ .limit = 1, .weight = 5, .min = 1, .max = 1 }, // iron leggings
    .{ .limit = 1, .weight = 5, .min = 1, .max = 1 }, // iron boots
    .{ .limit = 64, .weight = 5, .min = 1, .max = 1 }, // golden apple
    .{ .limit = 1, .weight = 1, .min = 1, .max = 1 }, // saddle
    .{ .limit = 1, .weight = 1, .min = 1, .max = 1 }, // iron horse armor
    .{ .limit = 1, .weight = 1, .min = 1, .max = 1 }, // gold horse armor
    .{ .limit = 1, .weight = 1, .min = 1, .max = 1 }, // diamond horse armor
};

/// Stronghold library (`auq.a`, 4 entries).
pub const stronghold_library = [_]Entry{
    .{ .limit = 64, .weight = 20, .min = 1, .max = 3 }, // book
    .{ .limit = 64, .weight = 20, .min = 2, .max = 7 }, // paper
    .{ .limit = 64, .weight = 1, .min = 1, .max = 1 }, // empty map
    .{ .limit = 64, .weight = 1, .min = 1, .max = 1 }, // compass
};

/// Stronghold corridor (`auv.b`, 7 entries).
pub const stronghold_corridor = [_]Entry{
    .{ .limit = 64, .weight = 10, .min = 1, .max = 5 }, // iron ingot
    .{ .limit = 64, .weight = 5, .min = 1, .max = 3 }, // gold ingot
    .{ .limit = 64, .weight = 5, .min = 4, .max = 9 }, // redstone
    .{ .limit = 64, .weight = 10, .min = 3, .max = 8 }, // coal
    .{ .limit = 64, .weight = 15, .min = 1, .max = 3 }, // bread
    .{ .limit = 64, .weight = 15, .min = 1, .max = 3 }, // apple
    .{ .limit = 1, .weight = 5, .min = 1, .max = 1 }, // iron pickaxe
};

/// Village blacksmith (`avz.a`, 17 entries).
pub const village_blacksmith = [_]Entry{
    .{ .limit = 64, .weight = 3, .min = 1, .max = 3 }, // diamond
    .{ .limit = 64, .weight = 10, .min = 1, .max = 5 }, // iron ingot
    .{ .limit = 64, .weight = 5, .min = 1, .max = 3 }, // gold ingot
    .{ .limit = 64, .weight = 15, .min = 1, .max = 3 }, // bread
    .{ .limit = 64, .weight = 15, .min = 1, .max = 3 }, // apple
    .{ .limit = 1, .weight = 5, .min = 1, .max = 1 }, // iron pickaxe
    .{ .limit = 1, .weight = 5, .min = 1, .max = 1 }, // iron sword
    .{ .limit = 1, .weight = 5, .min = 1, .max = 1 }, // iron chestplate
    .{ .limit = 1, .weight = 5, .min = 1, .max = 1 }, // iron helmet
    .{ .limit = 1, .weight = 5, .min = 1, .max = 1 }, // iron leggings
    .{ .limit = 1, .weight = 5, .min = 1, .max = 1 }, // iron boots
    .{ .limit = 64, .weight = 5, .min = 3, .max = 7 }, // obsidian
    .{ .limit = 64, .weight = 5, .min = 3, .max = 7 }, // sapling
    .{ .limit = 1, .weight = 3, .min = 1, .max = 1 }, // saddle
    .{ .limit = 1, .weight = 1, .min = 1, .max = 1 }, // iron horse armor
    .{ .limit = 1, .weight = 1, .min = 1, .max = 1 }, // gold horse armor
    .{ .limit = 1, .weight = 1, .min = 1, .max = 1 }, // diamond horse armor
};

/// Dungeon (`asd.a`, 15 entries; loot draws currently deferred with the
/// dungeon port — table ready for the follow-up).
pub const dungeon = [_]Entry{
    .{ .limit = 1, .weight = 10, .min = 1, .max = 1 }, // saddle
    .{ .limit = 64, .weight = 10, .min = 1, .max = 4 }, // iron ingot
    .{ .limit = 64, .weight = 10, .min = 1, .max = 1 }, // bread
    .{ .limit = 64, .weight = 10, .min = 1, .max = 4 }, // wheat
    .{ .limit = 64, .weight = 10, .min = 1, .max = 4 }, // gunpowder
    .{ .limit = 64, .weight = 10, .min = 1, .max = 4 }, // string
    .{ .limit = 16, .weight = 10, .min = 1, .max = 1 }, // bucket
    .{ .limit = 64, .weight = 1, .min = 1, .max = 1 }, // golden apple
    .{ .limit = 64, .weight = 10, .min = 1, .max = 4 }, // redstone
    .{ .limit = 1, .weight = 10, .min = 1, .max = 1 }, // record 13
    .{ .limit = 1, .weight = 10, .min = 1, .max = 1 }, // record cat
    .{ .limit = 64, .weight = 10, .min = 1, .max = 1 }, // name tag
    .{ .limit = 1, .weight = 2, .min = 1, .max = 1 }, // gold horse armor
    .{ .limit = 1, .weight = 5, .min = 1, .max = 1 }, // iron horse armor
    .{ .limit = 1, .weight = 1, .min = 1, .max = 1 }, // diamond horse armor
};

const std = @import("std");

/// Enchanted-book loot append (`acm.b` + `afv.b`): the book qx entry is
/// `qx.a(table, [book(rand)])`, so these draws happen BEFORE the chest
/// content draws. Replicated exactly (contents discarded).
///
/// Sequence for level 30 (`afv.b(rand, bookStack, 30)`):
///   nextInt(1), nextInt(1)          // enchantability 1 -> var4 = 1
///   nextFloat, nextFloat            // var6 jitter
///   var7 = (int)(31*(1+var6)+0.5), min 1
///   build id->Agc map (pure), HashMap iteration order (Java 8+, tail
///     insert, cap 16 -> 32 on 13th put), weighted pick (1 nextInt)
///   loop: nextInt(50) <= v (v >>= 1); each passing round filters
///     incompatible entries and picks again (1 nextInt) when non-empty.
pub const EnchantEntry = struct {
    id: u8,
    weight: u8,
    min_lvl: u8,
    max_lvl: u8,
    min_e: [5]u8,
    max_e: [5]u8,
};

/// Live-dumped enchantment registry (id asc). min_e/max_e indexed by
/// level-1 (only levels <= max_lvl are valid).
pub const enchantments: [24]EnchantEntry = .{
    .{ .id = 0, .weight = 10, .min_lvl = 1, .max_lvl = 4, .min_e = .{ 1, 12, 23, 34, 0 }, .max_e = .{ 21, 32, 43, 54, 0 } },
    .{ .id = 1, .weight = 5, .min_lvl = 1, .max_lvl = 4, .min_e = .{ 10, 18, 26, 34, 0 }, .max_e = .{ 22, 30, 38, 46, 0 } },
    .{ .id = 2, .weight = 5, .min_lvl = 1, .max_lvl = 4, .min_e = .{ 5, 11, 17, 23, 0 }, .max_e = .{ 15, 21, 27, 33, 0 } },
    .{ .id = 3, .weight = 2, .min_lvl = 1, .max_lvl = 4, .min_e = .{ 5, 13, 21, 29, 0 }, .max_e = .{ 17, 25, 33, 41, 0 } },
    .{ .id = 4, .weight = 5, .min_lvl = 1, .max_lvl = 4, .min_e = .{ 3, 9, 15, 21, 0 }, .max_e = .{ 18, 24, 30, 36, 0 } },
    .{ .id = 5, .weight = 2, .min_lvl = 1, .max_lvl = 3, .min_e = .{ 10, 20, 30, 0, 0 }, .max_e = .{ 40, 50, 60, 0, 0 } },
    .{ .id = 6, .weight = 2, .min_lvl = 1, .max_lvl = 1, .min_e = .{ 1, 0, 0, 0, 0 }, .max_e = .{ 41, 0, 0, 0, 0 } },
    .{ .id = 7, .weight = 1, .min_lvl = 1, .max_lvl = 3, .min_e = .{ 10, 30, 50, 0, 0 }, .max_e = .{ 61, 71, 81, 0, 0 } },
    .{ .id = 16, .weight = 10, .min_lvl = 1, .max_lvl = 5, .min_e = .{ 1, 12, 23, 34, 45 }, .max_e = .{ 21, 32, 43, 54, 65 } },
    .{ .id = 17, .weight = 5, .min_lvl = 1, .max_lvl = 5, .min_e = .{ 5, 13, 21, 29, 37 }, .max_e = .{ 25, 33, 41, 49, 57 } },
    .{ .id = 18, .weight = 5, .min_lvl = 1, .max_lvl = 5, .min_e = .{ 5, 13, 21, 29, 37 }, .max_e = .{ 25, 33, 41, 49, 57 } },
    .{ .id = 19, .weight = 5, .min_lvl = 1, .max_lvl = 2, .min_e = .{ 5, 25, 0, 0, 0 }, .max_e = .{ 61, 71, 0, 0, 0 } },
    .{ .id = 20, .weight = 2, .min_lvl = 1, .max_lvl = 2, .min_e = .{ 10, 30, 0, 0, 0 }, .max_e = .{ 61, 71, 0, 0, 0 } },
    .{ .id = 21, .weight = 2, .min_lvl = 1, .max_lvl = 3, .min_e = .{ 15, 24, 33, 0, 0 }, .max_e = .{ 61, 71, 81, 0, 0 } },
    .{ .id = 32, .weight = 10, .min_lvl = 1, .max_lvl = 5, .min_e = .{ 1, 11, 21, 31, 41 }, .max_e = .{ 61, 71, 81, 91, 101 } },
    .{ .id = 33, .weight = 1, .min_lvl = 1, .max_lvl = 1, .min_e = .{ 15, 0, 0, 0, 0 }, .max_e = .{ 61, 0, 0, 0, 0 } },
    .{ .id = 34, .weight = 5, .min_lvl = 1, .max_lvl = 3, .min_e = .{ 5, 13, 21, 0, 0 }, .max_e = .{ 61, 71, 81, 0, 0 } },
    .{ .id = 35, .weight = 2, .min_lvl = 1, .max_lvl = 3, .min_e = .{ 15, 24, 33, 0, 0 }, .max_e = .{ 61, 71, 81, 0, 0 } },
    .{ .id = 48, .weight = 10, .min_lvl = 1, .max_lvl = 5, .min_e = .{ 1, 11, 21, 31, 41 }, .max_e = .{ 16, 26, 36, 46, 56 } },
    .{ .id = 49, .weight = 2, .min_lvl = 1, .max_lvl = 2, .min_e = .{ 12, 32, 0, 0, 0 }, .max_e = .{ 37, 57, 0, 0, 0 } },
    .{ .id = 50, .weight = 2, .min_lvl = 1, .max_lvl = 1, .min_e = .{ 20, 0, 0, 0, 0 }, .max_e = .{ 50, 0, 0, 0, 0 } },
    .{ .id = 51, .weight = 1, .min_lvl = 1, .max_lvl = 1, .min_e = .{ 20, 0, 0, 0, 0 }, .max_e = .{ 50, 0, 0, 0, 0 } },
    .{ .id = 61, .weight = 2, .min_lvl = 1, .max_lvl = 3, .min_e = .{ 15, 24, 33, 0, 0 }, .max_e = .{ 61, 71, 81, 0, 0 } },
    .{ .id = 62, .weight = 2, .min_lvl = 1, .max_lvl = 3, .min_e = .{ 15, 24, 33, 0, 0 }, .max_e = .{ 61, 71, 81, 0, 0 } },
};

/// Directed incompatibility (chosen -> candidate means reject). Jar-probed,
/// including the two asymmetric pairs.
fn enchIncompatible(chosen: u8, candidate: u8) bool {
    if (chosen == candidate) return false;
    const a = @min(chosen, candidate);
    const b = @max(chosen, candidate);
    // Symmetric exclusions.
    if ((a == 0 and (b == 1 or b == 3 or b == 4)) or
        (a == 1 and (b == 3 or b == 4)) or
        (a == 3 and b == 4) or
        (a == 16 and (b == 17 or b == 18)) or
        (a == 17 and b == 18) or
        (a == 33 and b == 35)) return true;
    // Asymmetric: looting(21) and luck(61) reject silk touch(33), not versa.
    if ((chosen == 21 or chosen == 61) and candidate == 33) return true;
    return false;
}

/// One book candidate: enchantment id + level + weight.
const BookCand = struct { id: u8, lvl: u8, weight: u8 };

/// Replicate `afv.b(rand, bookStack, 30)` draws (contents discarded).
pub fn replicateBookDraws(rand: *JavaRandom) void {
    _ = rand.nextIntBound(1) catch unreachable;
    _ = rand.nextIntBound(1) catch unreachable;
    const j1 = rand.nextFloat();
    const j2 = rand.nextFloat();
    const jitter: f32 = (j1 + j2 - 1.0) * 0.15;
    var v: i32 = @as(i32, @intFromFloat(31.0 * (1.0 + jitter) + 0.5));
    if (v < 1) v = 1;
    // Build id->candidate map (last matching level wins), insertion order.
    var cands: [32]BookCand = undefined;
    var n: usize = 0;
    for (enchantments) |e| {
        var lvl: u8 = 0;
        var li: u8 = e.min_lvl;
        while (li <= e.max_lvl) : (li += 1) {
            const lo: i32 = e.min_e[li - 1];
            const hi: i32 = e.max_e[li - 1];
            if (v >= lo and v <= hi) lvl = li;
        }
        if (lvl != 0) {
            cands[n] = .{ .id = e.id, .lvl = lvl, .weight = e.weight };
            n += 1;
        }
    }
    if (n == 0) return;
    // Java 8+ HashMap<Integer,Agc> iteration order (default cap 16,
    // load 0.75; tail insertion; resize preserves order).
    var cap: usize = 16;
    var threshold: usize = 12;
    while (n > threshold) {
        cap *= 2;
        threshold = cap * 3 / 4;
    }
    var order: [32]usize = undefined;
    for (0..n) |i| order[i] = i;
    // Stable sort by bucket (insertion order = id asc already): simple
    // insertion of each index into bucket order.
    var sorted: [32]usize = undefined;
    var sn: usize = 0;
    var b: usize = 0;
    while (b < cap) : (b += 1) {
        for (0..n) |i| {
            if (@as(usize, cands[i].id) & (cap - 1) == b) {
                sorted[sn] = i;
                sn += 1;
            }
        }
    }
    // Weighted pick over values() order.
    var total: i32 = 0;
    for (sorted[0..sn]) |i| total += cands[i].weight;
    var roll = rand.nextIntBound(total) catch unreachable;
    var first: ?usize = null;
    for (sorted[0..sn]) |i| {
        roll -= cands[i].weight;
        if (roll < 0) {
            first = i;
            break;
        }
    }
    if (first == null) return;
    var chosen: [32]usize = undefined;
    chosen[0] = first.?;
    var nc: usize = 1;
    var vv: i32 = v;
    while (true) {
        if ((rand.nextIntBound(50) catch unreachable) > vv) break;
        vv >>= 1;
        // Remove entries incompatible with any chosen one.
        var avail: [32]usize = undefined;
        var na: usize = 0;
        for (sorted[0..sn]) |i| {
            var ok = true;
            var k: usize = 0;
            while (k < nc) : (k += 1) {
                if (enchIncompatible(cands[chosen[k]].id, cands[i].id)) {
                    ok = false;
                    break;
                }
            }
            if (ok) {
                avail[na] = i;
                na += 1;
            }
        }
        if (na == 0) break;
        var t2: i32 = 0;
        for (avail[0..na]) |i| t2 += cands[i].weight;
        var r2 = rand.nextIntBound(t2) catch unreachable;
        var pick: usize = avail[0];
        for (avail[0..na]) |i| {
            r2 -= cands[i].weight;
            if (r2 < 0) {
                pick = i;
                break;
            }
        }
        chosen[nc] = pick;
        nc += 1;
    }
}

test "weighted pick is deterministic" {
    var r = JavaRandom.init(12345);
    const idx = blk: {
        var total: i32 = 0;
        for (mineshaft_corridor) |e| total += e.weight;
        var roll = try r.nextIntBound(total);
        var pick: usize = 0;
        for (mineshaft_corridor, 0..) |e, i| {
            roll -= e.weight;
            if (roll < 0) {
                pick = i;
                break;
            }
        }
        break :blk pick;
    };
    // Same seed through the helper must agree.
    var r2 = JavaRandom.init(12345);
    const got = blk2: {
        var t: i32 = 0;
        for (mineshaft_corridor) |e| t += e.weight;
        var roll = try r2.nextIntBound(t);
        for (mineshaft_corridor, 0..) |e, i| {
            roll -= e.weight;
            if (roll < 0) break :blk2 i;
        }
        break :blk2 0;
    };
    try std.testing.expectEqual(idx, got);
    // Corridor total weight (live-dumped): guards the table.
    var total2: i32 = 0;
    for (mineshaft_corridor) |e| total2 += e.weight;
    try std.testing.expectEqual(@as(i32, 88), total2);
}

test "loot draws are deterministic and consume RNG" {
    var r1 = JavaRandom.init(999);
    replicateChestDraws(&r1, &mineshaft_corridor, 2, chest_slots);
    const a = try r1.nextIntBound(1000000);
    var r2 = JavaRandom.init(999);
    replicateChestDraws(&r2, &mineshaft_corridor, 2, chest_slots);
    const b = try r2.nextIntBound(1000000);
    try std.testing.expectEqual(a, b);
    var r3 = JavaRandom.init(1000);
    replicateChestDraws(&r3, &mineshaft_corridor, 2, chest_slots);
    const c = try r3.nextIntBound(1000000);
    try std.testing.expect(a != c);
}
