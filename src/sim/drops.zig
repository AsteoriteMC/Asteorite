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
const ids = @import("../ids.zig");

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
        ids.lapis_ore => {
            const q: u8 = @intCast(4 + (rand.nextIntBound(5) catch unreachable));
            out[0] = .{ .item_id = ids.dye, .damage = 4, .singles = q };
            n = 1;
        },
        // Redstone ore (lit or not): dust, 4 + nextInt(2) (amz).
        ids.redstone_ore, ids.lit_redstone_ore => {
            const q: u8 = @intCast(4 + (rand.nextIntBound(2) catch unreachable));
            out[0] = .{ .item_id = ids.redstone, .damage = 0, .singles = q };
            n = 1;
        },
        // Gravel: flint iff nextInt(10) == 0, else the block (ali, fortune 0).
        ids.gravel => {
            if (rand.nextIntBound(10) catch unreachable == 0) {
                out[0] = .{ .item_id = ids.flint, .damage = 0, .singles = 1 };
            } else {
                out[0] = .{ .item_id = ids.gravel, .damage = 0, .singles = 1 };
            }
            n = 1;
        },
        // Leaves: sapling 1/20 (jungle 1/40), damage meta&3; apple 1/200 for
        // oak (old leaves) / dark oak (new leaves) (alt/aml/amh, fortune 0).
        ids.leaves, ids.leaves2 => {
            const m: u4 = @truncate(meta & 3);
            const rate: i32 = if (block_id == ids.leaves and m == 3) 40 else 20;
            if (rand.nextIntBound(rate) catch unreachable == 0) {
                out[n] = .{ .item_id = ids.sapling, .damage = m, .singles = 1 };
                n += 1;
            }
            const apple_tree = (block_id == ids.leaves and m == 0) or (block_id == ids.leaves2 and m == 1);
            if (apple_tree and rand.nextIntBound(200) catch unreachable == 0) {
                out[n] = .{ .item_id = ids.apple, .damage = 0, .singles = 1 };
                n += 1;
            }
        },
        // Stone -> cobblestone (anv).
        ids.stone => {
            out[0] = .{ .item_id = ids.cobblestone, .damage = 0, .singles = 1 };
            n = 1;
        },
        // Ores that drop themselves or a fixed item, qty 1 (amn).
        ids.coal_ore => {
            out[0] = .{ .item_id = ids.coal, .damage = 0, .singles = 1 };
            n = 1;
        },
        ids.diamond_ore => {
            out[0] = .{ .item_id = ids.diamond, .damage = 0, .singles = 1 };
            n = 1;
        },
        ids.emerald_ore => {
            out[0] = .{ .item_id = ids.emerald, .damage = 0, .singles = 1 };
            n = 1;
        },
        // Gold/iron ore drop themselves (no furnace yet); quartz drops the item.
        ids.gold_ore, ids.iron_ore => {
            out[0] = .{ .item_id = block_id, .damage = 0, .singles = 1 };
            n = 1;
        },
        ids.quartz_ore => {
            out[0] = .{ .item_id = ids.quartz, .damage = 0, .singles = 1 };
            n = 1;
        },
        // Clay -> 4 balls (ajy).
        ids.clay => {
            out[0] = .{ .item_id = ids.clay_ball, .damage = 0, .singles = 4 };
            n = 1;
        },
        // Glowstone -> 2 + nextInt(3) dust (alg, fortune 0).
        ids.glowstone => {
            const q: u8 = @intCast(2 + (rand.nextIntBound(3) catch unreachable));
            out[0] = .{ .item_id = ids.glowstone_dust, .damage = 0, .singles = q };
            n = 1;
        },
        // Melon -> 3 + nextInt(5) slices (aly).
        ids.melon_block => {
            const q: u8 = @intCast(3 + (rand.nextIntBound(5) catch unreachable));
            out[0] = .{ .item_id = ids.melon, .damage = 0, .singles = q };
            n = 1;
        },
        // Double stone slab -> 2 single slabs.
        ids.double_stone_slab => {
            out[0] = .{ .item_id = ids.stone_slab, .damage = 0, .singles = 2 };
            n = 1;
        },
        // Tall grass / dead bush: seeds iff nextInt(8) == 0, else nothing (anz).
        ids.tallgrass, ids.deadbush => {
            if (rand.nextIntBound(8) catch unreachable == 0) {
                out[0] = .{ .item_id = ids.wheat_seeds, .damage = 0, .singles = 1 };
                n = 1;
            }
        },
        // Glass, ice, bedrock: nothing (quantityDropped 0 / unbreakable).
        ids.bedrock, ids.glass, ids.ice => {},
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
        ids.planks, ids.sapling, ids.log, ids.sandstone, ids.wool, ids.stone_slab, ids.stonebrick, ids.double_wooden_slab, ids.wooden_slab, ids.quartz_block, ids.stained_hardened_clay, ids.log2, ids.carpet, ids.double_plant => true,
        else => false,
    };
}

test "fixed drops: stone/cobble/ores/clay/glass" {
    var rng = JavaRandom.init(12345);
    var out: [2]DropRoll = undefined;
    // stone -> cobble
    try std.testing.expectEqual(@as(usize, 1), rollDrops(ids.stone, 0, &rng, &out));
    try std.testing.expectEqual(DropRoll{ .item_id = ids.cobblestone, .damage = 0, .singles = 1 }, out[0]);
    // coal/diamond/emerald/gold/iron/quartz
    for ([_]struct { b: u16, i: u16 }{ .{ .b = ids.coal_ore, .i = ids.coal }, .{ .b = ids.diamond_ore, .i = ids.diamond }, .{ .b = ids.emerald_ore, .i = ids.emerald }, .{ .b = ids.gold_ore, .i = ids.gold_ore }, .{ .b = ids.iron_ore, .i = ids.iron_ore } }) |c| {
        try std.testing.expectEqual(@as(usize, 1), rollDrops(c.b, 0, &rng, &out));
        try std.testing.expectEqual(c.i, out[0].item_id);
        try std.testing.expectEqual(@as(u8, 1), out[0].singles);
    }
    // clay -> 4 balls
    try std.testing.expectEqual(@as(usize, 1), rollDrops(ids.clay, 0, &rng, &out));
    try std.testing.expectEqual(DropRoll{ .item_id = ids.clay_ball, .damage = 0, .singles = 4 }, out[0]);
    // glass / ice / bedrock -> nothing
    try std.testing.expectEqual(@as(usize, 0), rollDrops(ids.glass, 0, &rng, &out));
    try std.testing.expectEqual(@as(usize, 0), rollDrops(ids.ice, 0, &rng, &out));
    // quartz ore -> quartz item (not the block)
    try std.testing.expectEqual(@as(usize, 1), rollDrops(ids.quartz_ore, 0, &rng, &out));
    try std.testing.expectEqual(DropRoll{ .item_id = ids.quartz, .damage = 0, .singles = 1 }, out[0]);
    try std.testing.expectEqual(@as(usize, 0), rollDrops(ids.bedrock, 0, &rng, &out));
    // double slab -> 2 singles
    try std.testing.expectEqual(@as(usize, 1), rollDrops(ids.double_stone_slab, 0, &rng, &out));
    try std.testing.expectEqual(DropRoll{ .item_id = ids.stone_slab, .damage = 0, .singles = 2 }, out[0]);
    // default: self-drop; wool keeps color
    try std.testing.expectEqual(@as(usize, 1), rollDrops(ids.dirt, 0, &rng, &out));
    try std.testing.expectEqual(DropRoll{ .item_id = ids.dirt, .damage = 0, .singles = 1 }, out[0]);
    try std.testing.expectEqual(@as(usize, 1), rollDrops(ids.wool, 11, &rng, &out));
    try std.testing.expectEqual(DropRoll{ .item_id = ids.wool, .damage = 11, .singles = 1 }, out[0]);
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
        _ = rollDrops(ids.lapis_ore, 0, &rng, &out);
        lapis_min = @min(lapis_min, out[0].singles);
        lapis_max = @max(lapis_max, out[0].singles);
        try std.testing.expectEqual(@as(u16, ids.dye), out[0].item_id);
        try std.testing.expectEqual(@as(i16, 4), out[0].damage);
        _ = rollDrops(ids.redstone_ore, 0, &rng, &out);
        red_min = @min(red_min, out[0].singles);
        red_max = @max(red_max, out[0].singles);
        _ = rollDrops(ids.glowstone, 0, &rng, &out);
        glow_min = @min(glow_min, out[0].singles);
        glow_max = @max(glow_max, out[0].singles);
        _ = rollDrops(ids.melon_block, 0, &rng, &out);
        melon_min = @min(melon_min, out[0].singles);
        melon_max = @max(melon_max, out[0].singles);
        _ = rollDrops(ids.gravel, 0, &rng, &out);
        if (out[0].item_id == ids.flint) flint += 1 else try std.testing.expectEqual(@as(u16, ids.gravel), out[0].item_id);
        if (rollDrops(ids.leaves, 0, &rng, &out) > 0 and out[0].item_id == ids.sapling) sap += 1;
        if (rollDrops(ids.tallgrass, 1, &rng, &out) > 0) seeds += 1;
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
        if (rollDrops(ids.leaves, 3, &r, &out) > 0 and out[0].item_id == ids.sapling) {
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
            const k = rollDrops(ids.leaves, m, &r, &out);
            var i: usize = 0;
            while (i < k) : (i += 1) try std.testing.expect(out[i].item_id != ids.apple);
        }
    }
}
