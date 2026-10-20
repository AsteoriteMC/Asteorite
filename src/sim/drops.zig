//! Vanilla 1.7.10 block-drop table (single source of truth for J-phase).
//!
//! Every entry is CFR-verified against the official 1.7.10 server jar
//! (`cfr_out/amn.java` = BlockOre, `amz` = BlockRedstoneOre, `ali` = gravel,
//! `alt`/`aml`/`amh` = leaves, `anv` = stone, `aly` = melon, `alg` =
//! glowstone, `ajy` = clay, `anz` = tallgrass/deadbush), except the
//! DEFAULT arm which is the vanilla base-class behavior itself
//! (`aji.a(int,Random,int)` returns self, quantity 1, damage 0) plus a
//! meta-preserving set for "same item, meta matters" blocks (damageDropped
//! overrides — listed per block, spot-checked in CFR).
//!
//! Excluded by design: fortune/silk-touch (no enchantments yet — every roll
//! uses fortune level 0), XP orbs, tile-entity contents, shear-only drops.
//!
//! Drop loop mirrors `aji.a(ahb,n2,n3,n4,n5,f2,n6)`: the returned count is a
//! number of ROLLS, each spawning a SEPARATE single-item EntityItem (they
//! merge later via EntityItem merge). RNG draws happen on the caller's
//! java.util.Random in vanilla order (quantity rolls, then per-roll chance
//! draws, then per-entity position offsets drawn by the spawner).

const std = @import("std");
const JavaRandom = @import("../worldgen/rng/java_random.zig").JavaRandom;

/// One drop roll: spawn `singles` separate single-item entities of this stack.
pub const DropRoll = struct {
    item_id: u16,
    damage: i16,
    singles: u8,
};

/// Roll drops for a broken block. Writes up to 2 rolls (leaves need two:
/// sapling + apple) into `out`, returns the count. `meta` is the low nibble
/// of the broken block.
pub fn rollDrops(block_id: u16, meta: u4, rand: *JavaRandom, out: *[2]DropRoll) usize {
    var n: usize = 0;
    switch (block_id) {
        // Lapis ore: dye/4, 4 + nextInt(5) (amn, fortune 0).
        21 => {
            const q: u8 = @intCast(4 + (rand.nextIntBound(5) catch unreachable));
            out[0] = .{ .item_id = 351, .damage = 4, .singles = q };
            n = 1;
        },
        // Redstone ore (lit or not): dust, 4 + nextInt(2) (amz).
        73, 74 => {
            const q: u8 = @intCast(4 + (rand.nextIntBound(2) catch unreachable));
            out[0] = .{ .item_id = 331, .damage = 0, .singles = q };
            n = 1;
        },
        // Gravel: flint iff nextInt(10) == 0, else the block (ali, fortune 0).
        13 => {
            if (rand.nextIntBound(10) catch unreachable == 0) {
                out[0] = .{ .item_id = 318, .damage = 0, .singles = 1 };
            } else {
                out[0] = .{ .item_id = 13, .damage = 0, .singles = 1 };
            }
            n = 1;
        },
        // Leaves: sapling 1/20 (jungle 1/40), damage meta&3; apple 1/200 for
        // oak (old leaves) / dark oak (new leaves) (alt/aml/amh, fortune 0).
        18, 161 => {
            const m: u4 = @truncate(meta & 3);
            const rate: i32 = if (block_id == 18 and m == 3) 40 else 20;
            if (rand.nextIntBound(rate) catch unreachable == 0) {
                out[n] = .{ .item_id = 6, .damage = m, .singles = 1 };
                n += 1;
            }
            const apple_tree = (block_id == 18 and m == 0) or (block_id == 161 and m == 1);
            if (apple_tree and rand.nextIntBound(200) catch unreachable == 0) {
                out[n] = .{ .item_id = 260, .damage = 0, .singles = 1 };
                n += 1;
            }
        },
        // Stone -> cobblestone (anv).
        1 => {
            out[0] = .{ .item_id = 4, .damage = 0, .singles = 1 };
            n = 1;
        },
        // Ores that drop themselves or a fixed item, qty 1 (amn).
        16 => {
            out[0] = .{ .item_id = 263, .damage = 0, .singles = 1 };
            n = 1;
        },
        56 => {
            out[0] = .{ .item_id = 264, .damage = 0, .singles = 1 };
            n = 1;
        },
        129 => {
            out[0] = .{ .item_id = 388, .damage = 0, .singles = 1 };
            n = 1;
        },
        // Gold/iron ore drop themselves (no furnace yet); quartz drops the item.
        14, 15 => {
            out[0] = .{ .item_id = block_id, .damage = 0, .singles = 1 };
            n = 1;
        },
        153 => {
            out[0] = .{ .item_id = 406, .damage = 0, .singles = 1 };
            n = 1;
        },
        // Clay -> 4 balls (ajy).
        82 => {
            out[0] = .{ .item_id = 337, .damage = 0, .singles = 4 };
            n = 1;
        },
        // Glowstone -> 2 + nextInt(3) dust (alg, fortune 0).
        89 => {
            const q: u8 = @intCast(2 + (rand.nextIntBound(3) catch unreachable));
            out[0] = .{ .item_id = 348, .damage = 0, .singles = q };
            n = 1;
        },
        // Melon -> 3 + nextInt(5) slices (aly).
        103 => {
            const q: u8 = @intCast(3 + (rand.nextIntBound(5) catch unreachable));
            out[0] = .{ .item_id = 360, .damage = 0, .singles = q };
            n = 1;
        },
        // Double stone slab -> 2 single slabs.
        43 => {
            out[0] = .{ .item_id = 44, .damage = 0, .singles = 2 };
            n = 1;
        },
        // Tall grass / dead bush: seeds iff nextInt(8) == 0, else nothing (anz).
        31, 32 => {
            if (rand.nextIntBound(8) catch unreachable == 0) {
                out[0] = .{ .item_id = 295, .damage = 0, .singles = 1 };
                n = 1;
            }
        },
        // Glass, ice, bedrock: nothing (quantityDropped 0 / unbreakable).
        7, 20, 79 => {},
        else => {
            out[0] = .{ .item_id = block_id, .damage = if (preservesMeta(block_id)) meta else 0, .singles = 1 };
            n = 1;
        },
    }
    return n;
}

/// Blocks whose item form carries the block metadata (vanilla damageDropped
/// overrides returning meta — same item, meta matters). Spot-checked in CFR.
fn preservesMeta(id: u16) bool {
    return switch (id) {
        5, 6, 17, 24, 35, 44, 98, 125, 126, 155, 159, 162, 171, 175 => true,
        else => false,
    };
}

test "fixed drops: stone/cobble/ores/clay/glass" {
    var rng = JavaRandom.init(12345);
    var out: [2]DropRoll = undefined;
    // stone -> cobble
    try std.testing.expectEqual(@as(usize, 1), rollDrops(1, 0, &rng, &out));
    try std.testing.expectEqual(DropRoll{ .item_id = 4, .damage = 0, .singles = 1 }, out[0]);
    // coal/diamond/emerald/gold/iron/quartz
    for ([_]struct { b: u16, i: u16 }{ .{ .b = 16, .i = 263 }, .{ .b = 56, .i = 264 }, .{ .b = 129, .i = 388 }, .{ .b = 14, .i = 14 }, .{ .b = 15, .i = 15 } }) |c| {
        try std.testing.expectEqual(@as(usize, 1), rollDrops(c.b, 0, &rng, &out));
        try std.testing.expectEqual(c.i, out[0].item_id);
        try std.testing.expectEqual(@as(u8, 1), out[0].singles);
    }
    // clay -> 4 balls
    try std.testing.expectEqual(@as(usize, 1), rollDrops(82, 0, &rng, &out));
    try std.testing.expectEqual(DropRoll{ .item_id = 337, .damage = 0, .singles = 4 }, out[0]);
    // glass / ice / bedrock -> nothing
    try std.testing.expectEqual(@as(usize, 0), rollDrops(20, 0, &rng, &out));
    try std.testing.expectEqual(@as(usize, 0), rollDrops(79, 0, &rng, &out));
    // quartz ore -> quartz item (not the block)
    try std.testing.expectEqual(@as(usize, 1), rollDrops(153, 0, &rng, &out));
    try std.testing.expectEqual(DropRoll{ .item_id = 406, .damage = 0, .singles = 1 }, out[0]);
    try std.testing.expectEqual(@as(usize, 0), rollDrops(7, 0, &rng, &out));
    // double slab -> 2 singles
    try std.testing.expectEqual(@as(usize, 1), rollDrops(43, 0, &rng, &out));
    try std.testing.expectEqual(DropRoll{ .item_id = 44, .damage = 0, .singles = 2 }, out[0]);
    // default: self-drop; wool keeps color
    try std.testing.expectEqual(@as(usize, 1), rollDrops(3, 0, &rng, &out));
    try std.testing.expectEqual(DropRoll{ .item_id = 3, .damage = 0, .singles = 1 }, out[0]);
    try std.testing.expectEqual(@as(usize, 1), rollDrops(35, 11, &rng, &out));
    try std.testing.expectEqual(DropRoll{ .item_id = 35, .damage = 11, .singles = 1 }, out[0]);
}

test "ranged drops stay in vanilla bounds (seed sweep)" {
    var seed: i64 = 1;
    var lapis_min: u8 = 99;
    var lapis_max: u8 = 0;
    var red_min: u8 = 99;
    var red_max: u8 = 0;
    var glow_min: u8 = 99;
    var glow_max: u8 = 0;
    var melon_min: u8 = 99;
    var melon_max: u8 = 0;
    var flint: usize = 0;
    var sap: usize = 0;
    var seeds: usize = 0;
    const N = 2000;
    while (seed <= N) : (seed += 1) {
        var rng = JavaRandom.init(seed * 7919);
        var out: [2]DropRoll = undefined;
        _ = rollDrops(21, 0, &rng, &out);
        lapis_min = @min(lapis_min, out[0].singles);
        lapis_max = @max(lapis_max, out[0].singles);
        try std.testing.expectEqual(@as(u16, 351), out[0].item_id);
        try std.testing.expectEqual(@as(i16, 4), out[0].damage);
        _ = rollDrops(73, 0, &rng, &out);
        red_min = @min(red_min, out[0].singles);
        red_max = @max(red_max, out[0].singles);
        _ = rollDrops(89, 0, &rng, &out);
        glow_min = @min(glow_min, out[0].singles);
        glow_max = @max(glow_max, out[0].singles);
        _ = rollDrops(103, 0, &rng, &out);
        melon_min = @min(melon_min, out[0].singles);
        melon_max = @max(melon_max, out[0].singles);
        _ = rollDrops(13, 0, &rng, &out);
        if (out[0].item_id == 318) flint += 1 else try std.testing.expectEqual(@as(u16, 13), out[0].item_id);
        if (rollDrops(18, 0, &rng, &out) > 0 and out[0].item_id == 6) sap += 1;
        if (rollDrops(31, 1, &rng, &out) > 0) seeds += 1;
    }
    try std.testing.expectEqual(@as(u8, 4), lapis_min);
    try std.testing.expectEqual(@as(u8, 8), lapis_max);
    try std.testing.expectEqual(@as(u8, 4), red_min);
    try std.testing.expectEqual(@as(u8, 5), red_max);
    try std.testing.expectEqual(@as(u8, 2), glow_min);
    try std.testing.expectEqual(@as(u8, 4), glow_max);
    try std.testing.expectEqual(@as(u8, 3), melon_min);
    try std.testing.expectEqual(@as(u8, 7), melon_max);
    // statistical: flint ~10%, sapling ~5%, seeds ~12.5% (N=2000, wide bands)
    try std.testing.expect(flint > 120 and flint < 300);
    try std.testing.expect(sap > 50 and sap < 170);
    try std.testing.expect(seeds > 150 and seeds < 350);
}

test "leaves damage + apple gating" {
    var out: [2]DropRoll = undefined;
    // find a seed producing a jungle sapling to check damage passthrough
    var found = false;
    var s: i64 = 0;
    while (s < 500) : (s += 1) {
        var r = JavaRandom.init(s);
        if (rollDrops(18, 3, &r, &out) > 0 and out[0].item_id == 6) {
            try std.testing.expectEqual(@as(i16, 3), out[0].damage);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
    // non-oak old leaves never apple: meta 1..3 over many seeds
    var m: u4 = 1;
    while (m <= 3) : (m += 1) {
        var seed: i64 = 0;
        while (seed < 300) : (seed += 1) {
            var r = JavaRandom.init(seed * 31 + m);
            const k = rollDrops(18, m, &r, &out);
            var i: usize = 0;
            while (i < k) : (i += 1) try std.testing.expect(out[i].item_id != 260);
        }
    }
}
