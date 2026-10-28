//! 1.7.10 item behavior tables: stack limits, melee damage, armor slots.
//!
//! Keyed by canonical `ids.Id` (never wire values). Engines reach these
//! through `profile.game.item_data` — never through `item.zig`, which owns
//! only the version-neutral `Stack` shape and merge/stack mechanics. A later
//! profile (1.9+ combat, new items) replaces this module; the canonical
//! registry in `ids.zig` only grows.

const std = @import("std");
const ids = @import("../../ids.zig");
const item_mod = @import("../../item.zig");

/// Max stack size (vanilla 1.7 limits). Damageable gear stacks to 1;
/// small throwables/utility to 16; everything else 64.
/// Approximation boundary: exotic 16-stacks beyond this table fall back to
/// 64 (documented; datapack-driven limits are Phase H3/F follow-ups).
pub fn maxStackSize(id: ids.Id) u8 {
    return switch (id) {
        // Swords, tools, flint&steel, shears (explicit: canonical ids are
        // dense, so the old wire ranges no longer work).
        .iron_sword, .wooden_sword, .stone_sword, .diamond_sword, .golden_sword,
        .wooden_shovel, .stone_shovel, .iron_shovel, .diamond_shovel, .golden_shovel,
        .wooden_pickaxe, .stone_pickaxe, .iron_pickaxe, .diamond_pickaxe, .golden_pickaxe,
        .wooden_axe, .stone_axe, .iron_axe, .diamond_axe, .golden_axe,
        .wooden_hoe, .stone_hoe, .iron_hoe, .diamond_hoe, .golden_hoe,
        .flint_and_steel, .shears,
        // Armor, bow, fishing rod, filled buckets.
        .leather_helmet, .leather_chestplate, .leather_leggings, .leather_boots,
        .chainmail_helmet, .chainmail_chestplate, .chainmail_leggings, .chainmail_boots,
        .iron_helmet, .iron_chestplate, .iron_leggings, .iron_boots,
        .diamond_helmet, .diamond_chestplate, .diamond_leggings, .diamond_boots,
        .golden_helmet, .golden_chestplate, .golden_leggings, .golden_boots,
        .bow, .fishing_rod, .water_bucket, .lava_bucket, .milk_bucket,
        => 1,
        .bucket, // empty bucket
        .snowball, .egg, .ender_pearl, .sign, // throwables/sign
        .minecart, .boat, .chest_minecart, .furnace_minecart, // carts/boat
        .potion, // filled potions never stack (glass bottles stack to 64)
        => 16,
        else => 64,
    };
}

/// Vanilla 1.7 melee damage by held item id (no enchantments — NBT is
/// skipped on placement, so sharpness can't apply; documented in conn.zig).
/// Swords 4-7, axes 3-6, pickaxes 2-5, shovels 1-4, everything else 1.
/// Single source of truth for 1.7 combat; later profiles own their numbers.
pub fn meleeDamage(id: ids.Id) f32 {
    return switch (id) {
        ids.wooden_sword, ids.golden_sword => 4.0, // wooden/gold sword
        ids.stone_sword => 5.0, // stone sword
        ids.iron_sword => 6.0, // iron sword
        ids.diamond_sword => 7.0, // diamond sword
        ids.wooden_axe, ids.golden_axe => 3.0, // wooden/gold axe
        ids.stone_axe => 4.0, // stone axe
        ids.iron_axe => 5.0, // iron axe
        ids.diamond_axe => 6.0, // diamond axe
        ids.wooden_pickaxe, ids.golden_pickaxe => 2.0, // wooden/gold pickaxe
        ids.stone_pickaxe => 3.0, // stone pickaxe
        ids.iron_pickaxe => 4.0, // iron pickaxe
        ids.diamond_pickaxe => 5.0, // diamond pickaxe
        ids.wooden_shovel, ids.golden_shovel => 1.0, // wooden/gold shovel (fist-equivalent)
        ids.stone_shovel => 2.0, // stone shovel
        ids.iron_shovel => 3.0, // iron shovel
        ids.diamond_shovel => 4.0, // diamond shovel
        else => 1.0, // fist and everything else
    };
}

/// Armor slot for an item id: 0 helmet, 1 chestplate, 2 leggings, 3 boots
/// (window slot = 5 + type, matching the survival inventory layout).
/// Null for non-armor. Right-click and shift-click equip consult this;
/// later profiles own their armor sets.
pub fn armorSlot(id: ids.Id) ?u3 {
    return switch (id) {
        ids.leather_helmet, ids.chainmail_helmet, ids.iron_helmet, ids.diamond_helmet, ids.golden_helmet => 0,
        ids.leather_chestplate, ids.chainmail_chestplate, ids.iron_chestplate, ids.diamond_chestplate, ids.golden_chestplate => 1,
        ids.leather_leggings, ids.chainmail_leggings, ids.iron_leggings, ids.diamond_leggings, ids.golden_leggings => 2,
        ids.leather_boots, ids.chainmail_boots, ids.iron_boots, ids.diamond_boots, ids.golden_boots => 3,
        else => null,
    };
}

test "melee damage table" {
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), meleeDamage(ids.wooden_sword), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), meleeDamage(ids.diamond_sword), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), meleeDamage(ids.iron_axe), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), meleeDamage(ids.iron_shovel), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), meleeDamage(ids.stone), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), meleeDamage(ids.air), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), meleeDamage(@as(ids.Id, @enumFromInt(9999))), 1e-6);
}

/// Vanilla ItemArmor damageReduceAmount per piece: leather 1/3/2/1,
/// chain 2/5/4/1, iron 2/6/5/2, diamond 3/8/6/3, gold 2/5/3/1.
/// Zero for non-armor. Later profiles own their numbers.
pub fn damageReduceAmount(id: ids.Id) u8 {
    return switch (id) {
        ids.leather_helmet => 1,
        ids.leather_chestplate => 3,
        ids.leather_leggings => 2,
        ids.leather_boots => 1,
        ids.chainmail_helmet => 2,
        ids.chainmail_chestplate => 5,
        ids.chainmail_leggings => 4,
        ids.chainmail_boots => 1,
        ids.iron_helmet => 2,
        ids.iron_chestplate => 6,
        ids.iron_leggings => 5,
        ids.iron_boots => 2,
        ids.diamond_helmet => 3,
        ids.diamond_chestplate => 8,
        ids.diamond_leggings => 6,
        ids.diamond_boots => 3,
        ids.golden_helmet => 2,
        ids.golden_chestplate => 5,
        ids.golden_leggings => 3,
        ids.golden_boots => 1,
        else => 0,
    };
}

/// Total armor points over the equipped slots (window armor_lo..armor_hi),
/// capped at 20 (vanilla 80% cap — full diamond).
pub const armor_lo: usize = 5;
pub const armor_hi: usize = 9; // exclusive

pub fn armorPoints(inv: []const ?item_mod.Stack) u8 {
    var total: u16 = 0;
    for (armor_lo..armor_hi) |s| {
        if (s >= inv.len) break;
        if (inv[s]) |st| total += damageReduceAmount(st.id);
    }
    return @intCast(@min(total, 20));
}

/// Vanilla EntityLivingBase armor formula: each point blocks 4% of a
/// non-bypassing hit. Bypassing sources (starve/drown/suffocate/fall/void)
/// skip this; melee, fire, lava and cactus do not.
pub fn reduceDamage(dmg: f32, armor: u8) f32 {
    const a: f32 = @floatFromInt(@min(armor, 20));
    return dmg * (25.0 - a) / 25.0;
}

test "armor slots map to window 5..8" {
    try std.testing.expectEqual(@as(?u3, 0), armorSlot(ids.leather_helmet));
    try std.testing.expectEqual(@as(?u3, 1), armorSlot(ids.iron_chestplate));
    try std.testing.expectEqual(@as(?u3, 2), armorSlot(ids.diamond_leggings));
    try std.testing.expectEqual(@as(?u3, 3), armorSlot(ids.golden_boots));
    try std.testing.expect(armorSlot(ids.dirt) == null);
    try std.testing.expect(armorSlot(ids.diamond_sword) == null);
}

test "stack limits" {
    try std.testing.expectEqual(@as(u8, 64), maxStackSize(ids.dirt)); // dirt
    try std.testing.expectEqual(@as(u8, 1), maxStackSize(ids.diamond_sword)); // diamond sword
    try std.testing.expectEqual(@as(u8, 1), maxStackSize(ids.diamond_helmet)); // diamond chestplate
    try std.testing.expectEqual(@as(u8, 16), maxStackSize(ids.snowball)); // snowball
    try std.testing.expectEqual(@as(u8, 16), maxStackSize(ids.egg)); // egg
    try std.testing.expectEqual(@as(u8, 16), maxStackSize(ids.bucket)); // empty bucket
    try std.testing.expectEqual(@as(u8, 1), maxStackSize(ids.water_bucket)); // water bucket
    try std.testing.expectEqual(@as(u8, 1), maxStackSize(ids.iron_sword)); // iron sword
    try std.testing.expectEqual(@as(u8, 1), maxStackSize(ids.wooden_hoe)); // wooden hoe
    try std.testing.expectEqual(@as(u8, 64), maxStackSize(ids.planks)); // planks
}

/// Vanilla armor-material durability (slot factors helmet 11, chest 16,
/// legs 15, boots 13 over material bases leather 5, chain/iron 15, gold 7,
/// diamond 33). Later profiles own their numbers.
pub fn maxDurability(id: ids.Id) u16 {
    return switch (id) {
        ids.leather_helmet => 55,
        ids.leather_chestplate => 80,
        ids.leather_leggings => 75,
        ids.leather_boots => 65,
        ids.chainmail_helmet => 165,
        ids.chainmail_chestplate => 240,
        ids.chainmail_leggings => 225,
        ids.chainmail_boots => 195,
        ids.iron_helmet => 165,
        ids.iron_chestplate => 240,
        ids.iron_leggings => 225,
        ids.iron_boots => 195,
        ids.diamond_helmet => 363,
        ids.diamond_chestplate => 528,
        ids.diamond_leggings => 495,
        ids.diamond_boots => 429,
        ids.golden_helmet => 77,
        ids.golden_chestplate => 112,
        ids.golden_leggings => 105,
        ids.golden_boots => 95,
        else => 0,
    };
}

/// Durability lost per equipped piece on one absorbed hit, from the
/// incoming (pre-reduction) damage: vanilla `damageArmor` shape.
pub fn wearForHit(dmg: f32) u16 {
    const w: i32 = @intFromFloat(dmg / 4.0 + 1.0);
    return @intCast(@min(@max(w, 1), 10000));
}

/// Damage-source classes the EPF system distinguishes. Fall bypasses
/// armor/EPF entirely (never queried); explosion/projectile have no
/// damage path yet but complete the table.
pub const EpfSource = enum { general, fire, explosion, projectile };

/// Enchant ids with EPF (vanilla ids: protection 0, fire 1, blast 3,
/// projectile 4; thorns 7 and the rest contribute nothing).
pub const epf_protection: u8 = 0;
pub const epf_fire: u8 = 1;
pub const epf_blast: u8 = 3;
pub const epf_projectile: u8 = 4;

/// Per-enchant EPF contribution (vanilla EnchantmentProtection shape):
/// protection counts everywhere, specifics double against their source
/// and contribute nothing elsewhere. Feather falling never applies here.
pub fn protectionEpf(ench_id: u8, lvl: u8, source: EpfSource) u8 {
    if (lvl == 0) return 0;
    const l: u16 = lvl;
    return switch (ench_id) {
        epf_protection => @intCast(@min((6 + l * l) / 3, 255)), // protection, all sources
        epf_fire => if (source == .fire) @intCast(@min(l * 2, 255)) else 0, // fire protection
        epf_blast => if (source == .explosion) @intCast(@min(l * 2, 255)) else 0, // blast protection
        epf_projectile => if (source == .projectile) @intCast(@min(l * 2, 255)) else 0, // projectile protection
        else => 0,
    };
}

pub const max_epf: u8 = 20;

/// Resistance points from a potion amplifier: 20% per level
/// ((amp+1)*5, vanilla shape), clamped so extreme amplifiers cannot
/// flip damage negative (no heal bug).
pub fn resistancePoints(amp: u8) u8 {
    const pts: u16 = (@as(u16, amp) + 1) * 5;
    return @intCast(@min(pts, 25));
}

test "armor values and reduction" {
    try std.testing.expectEqual(@as(u8, 0), damageReduceAmount(ids.dirt));
    try std.testing.expectEqual(@as(u8, 3), damageReduceAmount(ids.diamond_helmet));
    try std.testing.expectEqual(@as(u8, 8), damageReduceAmount(ids.diamond_chestplate));
    try std.testing.expectEqual(@as(u8, 6), damageReduceAmount(ids.diamond_leggings));
    try std.testing.expectEqual(@as(u8, 3), damageReduceAmount(ids.diamond_boots));
    var inv = [_]?item_mod.Stack{null} ** 45;
    try std.testing.expectEqual(@as(u8, 0), armorPoints(&inv));
    inv[5] = .{ .id = ids.diamond_helmet, .count = 1, .damage = 0, .nbt = null };
    inv[6] = .{ .id = ids.diamond_chestplate, .count = 1, .damage = 0, .nbt = null };
    inv[7] = .{ .id = ids.diamond_leggings, .count = 1, .damage = 0, .nbt = null };
    inv[8] = .{ .id = ids.diamond_boots, .count = 1, .damage = 0, .nbt = null };
    try std.testing.expectEqual(@as(u8, 20), armorPoints(&inv));
    // full diamond blocks 80%
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), reduceDamage(10.0, 20), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), reduceDamage(10.0, 0), 1e-6);
    // iron chest alone (6): 10 * 19/25
    try std.testing.expectApproxEqAbs(@as(f32, 7.6), reduceDamage(10.0, 6), 1e-4);
}

/// Vanilla 1.7.10 ItemFood stats, read off the jar (ItemFood `acx`,
/// FishType `acu`, ItemAppleGold `acy`, ItemSoup `abn` constructors +
/// setPotionEffect calls; durations verified seconds via the x20 in
/// onEaten). heal = food points, saturation = modifier (food added as
/// heal, saturation as min(sat + heal*mod*2, food)).
pub const FoodEffect = struct {
    /// Potion effect id (10 regen, 11 resistance, 12 fire resistance,
    /// 17 hunger, 19 poison, 9 nausea).
    id: u8,
    /// Duration in seconds (vanilla setPotionEffect unit).
    seconds: u32,
    amplifier: u8,
    /// Application probability percent (100 = always).
    probability_percent: u8,
};

pub const Food = struct {
    heal: u8,
    saturation: f32,
    /// Edible at full hunger (vanilla: only the golden apple).
    always_edible: bool = false,
    /// Potion effects applied on consume (probabilities rolled server-side).
    effects: []const FoodEffect = &.{},
    /// Container returned on consume (stew -> bowl, milk -> bucket).
    container_back: ?ids.Id = null,
    /// Clears all potion effects on drink (milk).
    clears_effects: bool = false,
};

const hunger_30 = [_]FoodEffect{.{ .id = 17, .seconds = 30, .amplifier = 0, .probability_percent = 30 }};
const hunger_80 = [_]FoodEffect{.{ .id = 17, .seconds = 30, .amplifier = 0, .probability_percent = 80 }};
const poison_5 = [_]FoodEffect{.{ .id = 19, .seconds = 5, .amplifier = 0, .probability_percent = 100 }};
const poison_60 = [_]FoodEffect{.{ .id = 19, .seconds = 5, .amplifier = 0, .probability_percent = 60 }};
const puffer_fx = [_]FoodEffect{
    .{ .id = 19, .seconds = 60, .amplifier = 3, .probability_percent = 100 },
    .{ .id = 17, .seconds = 15, .amplifier = 2, .probability_percent = 100 },
    .{ .id = 9, .seconds = 15, .amplifier = 1, .probability_percent = 100 },
};
const regen_5 = [_]FoodEffect{.{ .id = 10, .seconds = 5, .amplifier = 1, .probability_percent = 100 }};
const notch_fx = [_]FoodEffect{
    .{ .id = 22, .seconds = 120, .amplifier = 0, .probability_percent = 100 },
    .{ .id = 10, .seconds = 30, .amplifier = 4, .probability_percent = 100 },
    .{ .id = 11, .seconds = 300, .amplifier = 0, .probability_percent = 100 },
    .{ .id = 12, .seconds = 300, .amplifier = 0, .probability_percent = 100 },
};

/// Food stats by held item (+ damage for fish kinds / golden tier).
/// Null for non-foods (milk is a drink, handled by id below).
pub fn foodFor(id: ids.Id, damage: i16) ?Food {
    return switch (id) {
        .apple => .{ .heal = 4, .saturation = 0.3 },
        .bread => .{ .heal = 5, .saturation = 0.6 },
        .porkchop => .{ .heal = 3, .saturation = 0.3 },
        .cooked_porkchop => .{ .heal = 8, .saturation = 0.8 },
        .beef => .{ .heal = 3, .saturation = 0.3 },
        .cooked_beef => .{ .heal = 8, .saturation = 0.8 },
        .chicken => .{ .heal = 2, .saturation = 0.3, .effects = &hunger_30 },
        .cooked_chicken => .{ .heal = 6, .saturation = 0.6 },
        .rotten_flesh => .{ .heal = 4, .saturation = 0.1, .effects = &hunger_80 },
        .spider_eye => .{ .heal = 2, .saturation = 0.8, .effects = &poison_5 },
        .carrot => .{ .heal = 4, .saturation = 0.6 },
        .potato => .{ .heal = 1, .saturation = 0.3 },
        .baked_potato => .{ .heal = 6, .saturation = 0.6 },
        .poisonous_potato => .{ .heal = 2, .saturation = 0.3, .effects = &poison_60 },
        .cookie => .{ .heal = 2, .saturation = 0.1 },
        .melon => .{ .heal = 2, .saturation = 0.3 },
        .pumpkin_pie => .{ .heal = 8, .saturation = 0.3 },
        .mushroom_stew => .{ .heal = 6, .saturation = 0.6, .container_back = .bowl },
        .golden_carrot => .{ .heal = 6, .saturation = 1.2 },
        .golden_apple => if (damage > 0)
            .{ .heal = 4, .saturation = 1.2, .always_edible = true, .effects = &notch_fx }
        else
            .{ .heal = 4, .saturation = 1.2, .always_edible = true, .effects = &regen_5 },
        .fish => switch (damage) {
            0 => .{ .heal = 2, .saturation = 0.1 }, // cod
            1 => .{ .heal = 2, .saturation = 0.1 }, // salmon
            2 => .{ .heal = 1, .saturation = 0.1 }, // clownfish
            3 => .{ .heal = 1, .saturation = 0.1, .effects = &puffer_fx },
            else => null,
        },
        .cooked_fished => switch (damage) {
            0 => .{ .heal = 5, .saturation = 0.6 }, // cod
            1 => .{ .heal = 6, .saturation = 0.8 }, // salmon
            else => null,
        },
        .milk_bucket => .{ .heal = 0, .saturation = 0, .container_back = .bucket, .clears_effects = true },
        else => null,
    };
}

/// Vanilla eat use-duration: 32 ticks for food and drink alike.
pub const eat_ticks: u8 = 32;

test "food table matches the jar (heal/saturation/effects)" {
    const f = foodFor(ids.apple, 0).?;
    try std.testing.expectEqual(@as(u8, 4), f.heal);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), f.saturation, 1e-6);
    try std.testing.expectEqual(@as(u8, 8), foodFor(ids.cooked_beef, 0).?.heal);
    try std.testing.expectEqual(@as(u8, 6), foodFor(ids.baked_potato, 0).?.heal);
    try std.testing.expectEqual(@as(u8, 4), foodFor(ids.carrot, 0).?.heal);
    try std.testing.expectEqual(@as(u8, 6), foodFor(ids.mushroom_stew, 0).?.heal);
    try std.testing.expectEqual(ids.bowl, foodFor(ids.mushroom_stew, 0).?.container_back.?);
    try std.testing.expectEqual(ids.bucket, foodFor(ids.milk_bucket, 0).?.container_back.?);
    try std.testing.expect(foodFor(ids.milk_bucket, 0).?.clears_effects);
    try std.testing.expect(foodFor(ids.golden_apple, 0).?.always_edible);
    try std.testing.expectEqual(@as(usize, 1), foodFor(ids.golden_apple, 0).?.effects.len);
    try std.testing.expectEqual(@as(usize, 4), foodFor(ids.golden_apple, 1).?.effects.len);
    try std.testing.expectEqual(@as(u8, 10), foodFor(ids.golden_apple, 0).?.effects[0].id);
    try std.testing.expectEqual(@as(u32, 5), foodFor(ids.golden_apple, 0).?.effects[0].seconds);
    try std.testing.expectEqual(@as(u8, 22), foodFor(ids.golden_apple, 1).?.effects[0].id);
    try std.testing.expectEqual(@as(u8, 2), foodFor(ids.fish, 0).?.heal);
    try std.testing.expectEqual(@as(u8, 1), foodFor(ids.fish, 2).?.heal);
    try std.testing.expectEqual(@as(usize, 3), foodFor(ids.fish, 3).?.effects.len);
    try std.testing.expectEqual(@as(u8, 19), foodFor(ids.fish, 3).?.effects[0].id);
    try std.testing.expectEqual(@as(u8, 6), foodFor(ids.cooked_fished, 1).?.heal);
    try std.testing.expect(foodFor(ids.fish, 9) == null);
    try std.testing.expect(foodFor(ids.cooked_fished, 2) == null);
    try std.testing.expect(foodFor(ids.dirt, 0) == null);
    try std.testing.expect(foodFor(ids.stone_sword, 0) == null);
}

test "durability, wear, EPF, resistance" {
    try std.testing.expectEqual(@as(u16, 528), maxDurability(ids.diamond_chestplate));
    try std.testing.expectEqual(@as(u16, 65), maxDurability(ids.leather_boots));
    try std.testing.expectEqual(@as(u16, 0), maxDurability(ids.dirt));
    try std.testing.expectEqual(@as(u16, 1), wearForHit(3.0));
    try std.testing.expectEqual(@as(u16, 8), wearForHit(30.0));
    // protection II: (6+4)/3 = 3 everywhere
    try std.testing.expectEqual(@as(u8, 3), protectionEpf(0, 2, .general));
    try std.testing.expectEqual(@as(u8, 3), protectionEpf(0, 2, .fire));
    try std.testing.expectEqual(@as(u8, 7), protectionEpf(0, 4, .general));
    // fire prot II doubles vs fire only
    try std.testing.expectEqual(@as(u8, 4), protectionEpf(1, 2, .fire));
    try std.testing.expectEqual(@as(u8, 0), protectionEpf(1, 2, .general));
    try std.testing.expectEqual(@as(u8, 0), protectionEpf(7, 3, .general)); // thorns: no EPF
    try std.testing.expectEqual(@as(u8, 0), protectionEpf(0, 0, .general));
    // resistance: 20% per level, clamped
    try std.testing.expectEqual(@as(u8, 5), resistancePoints(0));
    try std.testing.expectEqual(@as(u8, 25), resistancePoints(4));
    try std.testing.expectEqual(@as(u8, 25), resistancePoints(255));
}
