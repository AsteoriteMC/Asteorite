//! Vanilla 1.7.10 potion model: damage-value table + brewing chain.
//!
//! Damage layout (ItemPotion, jar): bit 14 (16384) = splash, bit 6 (64) =
//! extended, bit 5 (32) = tier II, bits 0-3 = effect index. Base potions
//! carry no effect bits: 0 water, 16 awkward, 32 thick, 64 mundane.
//! (Bit 13 / 8192 is set on every effect potion but is NOT the splash
//! flag — splash adds a further 16384 on top.) Modifiers are exclusive: redstone needs no ext/II bits, glowstone needs
//! no ext/II bits and a tier-II-capable effect, corruption refuses tier II
//! (extended corruption keeps the ext bit). Gunpowder splashes anything.
//!
//! Effect ingredients only convert awkward (splash-awkward keeps its splash
//! bit); unlisted ingredients on water fall back to mundane; mundane/thick
//! only take gunpowder. Weakness brews straight from water + fermented eye.

const std = @import("std");
const ids = @import("../../ids.zig");

pub const splash_bit: i16 = 16384;
pub const ext_bit: i16 = 64;
pub const tier_bit: i16 = 32;

pub const effect_mask: i16 = 0x0f;

/// One brewable effect. Seconds are the 1.7.10 durations; `ext_seconds`
/// and `ii_seconds` are 0 when that modifier does not exist for the
/// effect (instant health/harm have no extended form).
pub const Effect = struct {
    bit: i16,
    a6: u8,
    name: []const u8,
    seconds: u32,
    ext_seconds: u32,
    ii_seconds: u32,
    amp: u8 = 0,
};

pub const effects: [12]Effect = .{
    .{ .bit = 1, .a6 = 10, .name = "Regeneration", .seconds = 45, .ext_seconds = 120, .ii_seconds = 22 },
    .{ .bit = 2, .a6 = 1, .name = "Swiftness", .seconds = 180, .ext_seconds = 480, .ii_seconds = 90 },
    .{ .bit = 3, .a6 = 12, .name = "Fire Resistance", .seconds = 180, .ext_seconds = 480, .ii_seconds = 0 },
    .{ .bit = 4, .a6 = 19, .name = "Poison", .seconds = 45, .ext_seconds = 120, .ii_seconds = 22 },
    .{ .bit = 5, .a6 = 6, .name = "Healing", .seconds = 0, .ext_seconds = 0, .ii_seconds = 0 },
    .{ .bit = 6, .a6 = 16, .name = "Night Vision", .seconds = 180, .ext_seconds = 480, .ii_seconds = 0 },
    .{ .bit = 8, .a6 = 18, .name = "Weakness", .seconds = 90, .ext_seconds = 240, .ii_seconds = 0 },
    .{ .bit = 9, .a6 = 5, .name = "Strength", .seconds = 180, .ext_seconds = 480, .ii_seconds = 90 },
    .{ .bit = 10, .a6 = 2, .name = "Slowness", .seconds = 90, .ext_seconds = 240, .ii_seconds = 0 },
    .{ .bit = 11, .a6 = 7, .name = "Harming", .seconds = 0, .ext_seconds = 0, .ii_seconds = 0 },
    .{ .bit = 12, .a6 = 13, .name = "Water Breathing", .seconds = 180, .ext_seconds = 480, .ii_seconds = 0 },
    .{ .bit = 14, .a6 = 14, .name = "Invisibility", .seconds = 180, .ext_seconds = 480, .ii_seconds = 0 },
};

pub fn effectByBit(bit: i16) ?Effect {
    for (effects) |e| if (e.bit == bit) return e;
    return null;
}

/// Resolved application for a potion damage value: A6 effect id, duration
/// in seconds, amplifier. Null when the damage carries no effect (water,
/// awkward, thick, mundane). Extended/tier-II decoded from the modifier
/// bits; tier II raises the amplifier by one (vanilla 0 -> 1).
pub const Applied = struct {
    a6: u8,
    seconds: u32,
    amp: u8,
};

/// Splash falloff (vanilla EntityPotion radius 4.0): full duration for the
/// directly-hit entity; (1 - dist/4) floored to whole seconds for everyone
/// else in radius (1Hz quantization — sub-second durations expire on the
/// next tick anyway); instant health/harm apply full to the whole radius.
/// 0 = no effect (out of radius or scaled away).
pub fn splashSeconds(base_seconds: u32, dist: f64, direct: bool) u32 {
    if (dist >= 4.0) return 0;
    if (base_seconds <= instant_seconds or direct) return base_seconds;
    return @intFromFloat(@floor(@as(f64, @floatFromInt(base_seconds)) * (1.0 - dist / 4.0)));
}
/// Instant health/harm have no duration; K2 delivers them as a 1s effect
/// tick (visible in S1D, expires next tick). Server-side HP application is
/// L2's job (TODO L2); the delivery here is cosmetic but exact.
pub const instant_seconds: u32 = 1;

/// Splash falloff (vanilla EntityPotion radius 4.0): full duration for the

pub fn effectFor(dmg: i16) ?Applied {
    const e = effectByBit(dmg & effect_mask) orelse return null;
    const ext = dmg & ext_bit != 0;
    const tier = dmg & tier_bit != 0;
    if (e.seconds == 0) return .{ .a6 = e.a6, .seconds = instant_seconds, .amp = if (tier) 1 else 0 };
    if (tier) {
        if (e.ii_seconds == 0) return null; // unreachable via brewResult; defensive
        return .{ .a6 = e.a6, .seconds = e.ii_seconds, .amp = 1 };
    }
    if (ext) return .{ .a6 = e.a6, .seconds = e.ext_seconds, .amp = 0 };
    return .{ .a6 = e.a6, .seconds = e.seconds, .amp = 0 };
}

pub fn isSplash(dmg: i16) bool {
    return dmg & splash_bit != 0;
}

/// Right-click drink: any unsplashed potion bottle (water and base brews
/// drink to nothing; effect potions apply via effectFor). Splash bottles
/// throw instead of drinking.
pub fn isDrinkable(id: ids.Id, dmg: i16) bool {
    return id == ids.potion and !isSplash(dmg);
}

/// Right-click throw: splash bottles only.
pub fn isThrowable(id: ids.Id, dmg: i16) bool {
    return id == ids.potion and isSplash(dmg);
}

pub fn hasEffect(dmg: i16) bool {
    return effectByBit(dmg & effect_mask) != null;
}

/// Fermented-spider-eye corruption (vanilla one-way map). Identity when the
/// effect does not corrupt (slowness, harming, water breathing,
/// invisibility, regen, weakness, strength stay put).
pub fn corrupt(bit: i16) i16 {
    return switch (bit) {
        2 => 10, // swiftness -> slowness
        3 => 10, // fire resistance -> slowness
        4 => 11, // poison -> harming
        5 => 11, // healing -> harming
        6 => 14, // night vision -> invisibility
        else => bit,
    };
}

/// Effect ingredient -> effect bit. Damage-qualified ingredients (pufferfish
/// is .fish damage 3) check `ing_dmg`; others ignore it.
pub fn ingredientEffect(id: ids.Id, ing_dmg: i16) ?i16 {
    if (id == ids.sugar) return 2;
    if (id == ids.ghast_tear) return 1;
    if (id == ids.magma_cream) return 3;
    if (id == ids.spider_eye) return 4;
    if (id == ids.speckled_melon) return 5;
    if (id == ids.golden_carrot) return 6;
    if (id == ids.blaze_powder) return 9;
    if (id == ids.fish and ing_dmg == 3) return 12; // pufferfish
    return null;
}

/// Any item the brewer consumes (effect ingredients, modifiers, gunpowder,
/// eye, wart). Drag-cell + shift-click validity.
pub fn isIngredient(id: ids.Id) bool {
    return switch (id) {
        .nether_wart_item, .redstone, .glowstone_dust, .gunpowder, .fermented_spider_eye, .sugar, .magma_cream, .ghast_tear, .spider_eye, .speckled_melon, .golden_carrot, .blaze_powder, .fish => true,
        else => false,
    };
}

/// One brewing step: ingredient + input bottle damage -> output bottle
/// damage. Null when the combination does nothing (vanilla leaves the
/// bottles; the ingredient is NOT consumed — the caller checks this first).
pub fn brewResult(ing: ids.Id, ing_dmg: i16, input: i16) ?i16 {
    const splash = input & splash_bit;
    const base = input & ~splash_bit;
    // Water branch (unsplashed only — splash water is unbrewable).
    if (base == 0 and splash == 0) {
        if (ing == ids.nether_wart_item) return 16;
        if (ing == ids.redstone) return 64;
        if (ing == ids.glowstone_dust) return 32;
        if (ing == ids.fermented_spider_eye) return 8192 | 8; // weakness
        if (ing == ids.gunpowder) return 64 | splash_bit; // mundane splash
        if (isIngredient(ing)) return 64; // anything else -> mundane
        return null;
    }
    // Gunpowder splashes anything unsplashed.
    if (ing == ids.gunpowder) {
        if (splash != 0) return null;
        return input | splash_bit;
    }
    // Awkward branch (splash-awkward keeps its splash bit).
    if (base == 16) {
        if (ingredientEffect(ing, ing_dmg)) |e| return splash | 8192 | e;
        return null;
    }
    // Effect branch: modifiers + corruption.
    if (effectByBit(base & effect_mask)) |e| {
        const ext = base & ext_bit != 0;
        const tier = base & tier_bit != 0;
        if (ing == ids.redstone) {
            if (ext or tier or e.ext_seconds == 0) return null;
            return input | ext_bit;
        }
        if (ing == ids.glowstone_dust) {
            if (ext or tier or e.ii_seconds == 0) return null;
            return input | tier_bit;
        }
        if (ing == ids.fermented_spider_eye) {
            if (tier) return null;
            const out_bit = corrupt(e.bit);
            if (out_bit == e.bit) return null;
            return splash | (if (ext) ext_bit else 0) | 8192 | out_bit;
        }
        return null;
    }
    // Mundane/thick/unknown: gunpowder handled above; nothing else brews.
    return null;
}

/// Display name (1.7.10 lang: effect/extended/tier share the base name;
/// splash prefixes; base potions use their mundane/awkward/thick names).
pub fn displayName(dmg: i16, buf: []u8) ?[]const u8 {
    const base = dmg & ~splash_bit;
    const splash = isSplash(dmg);
    if (base == 0) return "Water Bottle";
    if (base == 16) return if (splash) "Splash Awkward Potion" else "Awkward Potion";
    if (base == 32) return if (splash) "Splash Thick Potion" else "Thick Potion";
    if (base == 64) return if (splash) "Splash Mundane Potion" else "Mundane Potion";
    const e = effectByBit(base & effect_mask) orelse return null;
    if (splash) return std.fmt.bufPrint(buf, "Splash Potion of {s}", .{e.name}) catch null;
    return std.fmt.bufPrint(buf, "Potion of {s}", .{e.name}) catch null;
}

test "potion chain: water to awkward to swiftness and back" {
    // water + wart -> awkward
    try std.testing.expectEqual(@as(?i16, 16), brewResult(ids.nether_wart_item, 0, 0));
    // awkward + sugar -> swiftness
    try std.testing.expectEqual(@as(?i16, 8194), brewResult(ids.sugar, 0, 16));
    // awkward splash keeps splash: awkward splash + sugar -> splash swiftness
    try std.testing.expectEqual(@as(?i16, 16384 | 8194), brewResult(ids.sugar, 0, 16 | splash_bit));
    // redstone/glowstone/eye on awkward do nothing
    try std.testing.expect(brewResult(ids.redstone, 0, 16) == null);
    try std.testing.expect(brewResult(ids.glowstone_dust, 0, 16) == null);
    try std.testing.expect(brewResult(ids.fermented_spider_eye, 0, 16) == null);
}

test "potion modifiers: extend, enhance, splash" {
    const swift: i16 = 8194;
    // extend then enhance-excluded
    try std.testing.expectEqual(@as(?i16, 8258), brewResult(ids.redstone, 0, swift));
    try std.testing.expect(brewResult(ids.redstone, 0, 8258) == null);
    try std.testing.expect(brewResult(ids.glowstone_dust, 0, 8258) == null);
    // enhance then extend-excluded
    try std.testing.expectEqual(@as(?i16, 8226), brewResult(ids.glowstone_dust, 0, swift));
    try std.testing.expect(brewResult(ids.redstone, 0, 8226) == null);
    try std.testing.expect(brewResult(ids.glowstone_dust, 0, 8226) == null);
    // glowstone on non-tier effects does nothing
    try std.testing.expect(brewResult(ids.glowstone_dust, 0, 8195) == null); // fire res
    try std.testing.expect(brewResult(ids.glowstone_dust, 0, 8200) == null); // weakness
    // gunpowder splashes, twice is a no-op
    try std.testing.expectEqual(@as(?i16, 16384 | swift), brewResult(ids.gunpowder, 0, swift));
    try std.testing.expect(brewResult(ids.gunpowder, 0, 16384 | swift) == null);
    // modifiers work on splash too
    try std.testing.expectEqual(@as(?i16, 16384 | 8258), brewResult(ids.redstone, 0, 16384 | swift));
}

test "potion corruption: eye map, extended preserved, tier refused" {
    // base corruptions
    try std.testing.expectEqual(@as(?i16, 8202), brewResult(ids.fermented_spider_eye, 0, 8194)); // speed -> slowness
    try std.testing.expectEqual(@as(?i16, 8202), brewResult(ids.fermented_spider_eye, 0, 8195)); // fire -> slowness
    try std.testing.expectEqual(@as(?i16, 8203), brewResult(ids.fermented_spider_eye, 0, 8196)); // poison -> harming
    try std.testing.expectEqual(@as(?i16, 8203), brewResult(ids.fermented_spider_eye, 0, 8197)); // healing -> harming
    try std.testing.expectEqual(@as(?i16, 8206), brewResult(ids.fermented_spider_eye, 0, 8198)); // night vision -> invis
    // non-corrupters refuse
    try std.testing.expect(brewResult(ids.fermented_spider_eye, 0, 8202) == null);
    try std.testing.expect(brewResult(ids.fermented_spider_eye, 0, 8203) == null);
    try std.testing.expect(brewResult(ids.fermented_spider_eye, 0, 8201) == null); // strength
    // extended corruption keeps the ext bit: ext swiftness -> ext slowness
    try std.testing.expectEqual(@as(?i16, 8192 | 64 | 10), brewResult(ids.fermented_spider_eye, 0, 8258));
    // tier II corruption refused
    try std.testing.expect(brewResult(ids.fermented_spider_eye, 0, 8226) == null);
    // splash corruption keeps splash
    try std.testing.expectEqual(@as(?i16, 16384 | 8202), brewResult(ids.fermented_spider_eye, 0, 16384 | 8194));
}

test "potion water branch: mundane, thick, weakness, fallback" {
    try std.testing.expectEqual(@as(?i16, 64), brewResult(ids.redstone, 0, 0));
    try std.testing.expectEqual(@as(?i16, 32), brewResult(ids.glowstone_dust, 0, 0));
    try std.testing.expectEqual(@as(?i16, 8200), brewResult(ids.fermented_spider_eye, 0, 0));
    try std.testing.expectEqual(@as(?i16, 64), brewResult(ids.sugar, 0, 0)); // fallback mundane
    try std.testing.expectEqual(@as(?i16, 64), brewResult(ids.blaze_powder, 0, 0));
    try std.testing.expectEqual(@as(?i16, 16448), brewResult(ids.gunpowder, 0, 0)); // mundane splash
    try std.testing.expect(brewResult(ids.stone, 0, 0) == null); // not an ingredient
    // mundane/thick only take gunpowder
    try std.testing.expectEqual(@as(?i16, 64 | splash_bit), brewResult(ids.gunpowder, 0, 64));
    try std.testing.expect(brewResult(ids.redstone, 0, 64) == null);
    try std.testing.expect(brewResult(ids.sugar, 0, 64) == null);
}

test "potion effect resolution: durations, amps, instants" {
    const swift = effectFor(8194).?;
    try std.testing.expectEqual(@as(u8, 1), swift.a6);
    try std.testing.expectEqual(@as(u32, 180), swift.seconds);
    try std.testing.expectEqual(@as(u8, 0), swift.amp);
    const swift_ext = effectFor(8258).?;
    try std.testing.expectEqual(@as(u32, 480), swift_ext.seconds);
    const swift_ii = effectFor(8226).?;
    try std.testing.expectEqual(@as(u32, 90), swift_ii.seconds);
    try std.testing.expectEqual(@as(u8, 1), swift_ii.amp);
    // splash resolves like its drinkable twin
    const splash = effectFor(16384 | 8194).?;
    try std.testing.expectEqual(@as(u8, 1), splash.a6);
    try std.testing.expectEqual(@as(u32, 180), splash.seconds);
    // instants deliver a 1s tick (L2 owns HP)
    const heal = effectFor(8197).?;
    try std.testing.expectEqual(@as(u8, 6), heal.a6);
    try std.testing.expectEqual(@as(u32, 1), heal.seconds);
    const harm_ii = effectFor(8203 | 32).?;
    try std.testing.expectEqual(@as(u8, 1), harm_ii.amp);
    // effect-less damages resolve null
    try std.testing.expect(effectFor(0) == null);
    try std.testing.expect(effectFor(16) == null);
    try std.testing.expect(effectFor(32) == null);
    try std.testing.expect(effectFor(64) == null);
    // weakness resolves (direct water+eye brew)
    const weak = effectFor(8200).?;
    try std.testing.expectEqual(@as(u8, 18), weak.a6);
    try std.testing.expectEqual(@as(u32, 90), weak.seconds);
}

test "potion splash falloff: direct full, scaled by (1 - d/4), instants full" {
    // Swiftness base 180s: direct hit full anywhere in radius.
    try std.testing.expectEqual(@as(u32, 180), splashSeconds(180, 0.0, true));
    try std.testing.expectEqual(@as(u32, 180), splashSeconds(180, 3.9, true));
    // Edge of radius: nothing (vanilla d < 4.0 gate).
    try std.testing.expectEqual(@as(u32, 0), splashSeconds(180, 4.0, false));
    try std.testing.expectEqual(@as(u32, 0), splashSeconds(180, 10.0, false));
    // Halfway: 90s; quarter: 135s; floored to whole seconds.
    try std.testing.expectEqual(@as(u32, 90), splashSeconds(180, 2.0, false));
    try std.testing.expectEqual(@as(u32, 135), splashSeconds(180, 1.0, false));
    try std.testing.expectEqual(@as(u32, 45), splashSeconds(45, 0.0, false)); // dist 0, not direct
    // Instants apply full to the whole radius.
    try std.testing.expectEqual(@as(u32, 1), splashSeconds(1, 3.5, false));
    try std.testing.expectEqual(@as(u32, 1), splashSeconds(1, 0.0, false));
}

test "potion display names" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Water Bottle", displayName(0, &buf).?);
    try std.testing.expectEqualStrings("Awkward Potion", displayName(16, &buf).?);
    try std.testing.expectEqualStrings("Mundane Potion", displayName(64, &buf).?);
    try std.testing.expectEqualStrings("Potion of Swiftness", displayName(8194, &buf).?);
    try std.testing.expectEqualStrings("Splash Potion of Swiftness", displayName(16384 | 8194, &buf).?);
    try std.testing.expectEqualStrings("Potion of Swiftness", displayName(8258, &buf).?); // ext shares base name
    try std.testing.expectEqualStrings("Splash Mundane Potion", displayName(16448, &buf).?);
    try std.testing.expect(displayName(7, &buf) == null); // unused effect bit
}
