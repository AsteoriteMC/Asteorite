//! 1.7.10 command data tables (jar-verified, see `xu` analysis notes).
//!
//! Enchantment registrations (class `aft` clinit order), potion ids,
//! entity type ids (`sg` clinit: Mob=48..EnderCrystal=200), gamerule
//! defaults (`agy` ctor), scoreboard criteria, team colors, and the 32
//! achievement names. Command files stay version-agnostic by going through
//! Server backend methods; only this module and the backends know 1.7.10.

const std = @import("std");

/// Enchantment applicability category (from `afu` + per-class overrides).
pub const EnchCat = enum {
    any_armor, // protection group (agi variants 0,1,3,4)
    boots, // feather falling (agi variant 2 -> afu.c)
    head, // respiration, aqua affinity (agh/agl -> afu.f)
    torso, // thorns (agj -> afu.e)
    sword_axe, // sharpness/smite/bane (afq: axe override + weapon type)
    sword, // knockback/fire aspect/looting (agf/agd/agg type g)
    digger_shears, // efficiency/silk (afs/agk type h + shears)
    digger, // fortune (agg type h, no shears override)
    damageable, // unbreaking (afr: any damageable item)
    bow, // power/punch/flame/infinity (afm/afp/afn/afo)
    rod, // luck of the sea (agg type i)
};

pub const Ench = struct {
    id: u8,
    max: u8,
    name: []const u8,
    cat: EnchCat,
};

/// All 23 registered enchantments (lure/62 does not exist in 1.7.10: the
/// `age` class is never instantiated in `aft` clinit).
pub const enchants = [_]Ench{
    .{ .id = 0, .max = 4, .name = "protection", .cat = .any_armor },
    .{ .id = 1, .max = 4, .name = "fire_protection", .cat = .any_armor },
    .{ .id = 2, .max = 4, .name = "feather_falling", .cat = .boots },
    .{ .id = 3, .max = 4, .name = "blast_protection", .cat = .any_armor },
    .{ .id = 4, .max = 4, .name = "projectile_protection", .cat = .any_armor },
    .{ .id = 5, .max = 3, .name = "respiration", .cat = .head },
    .{ .id = 6, .max = 1, .name = "aqua_affinity", .cat = .head },
    .{ .id = 7, .max = 3, .name = "thorns", .cat = .torso },
    .{ .id = 16, .max = 5, .name = "sharpness", .cat = .sword_axe },
    .{ .id = 17, .max = 5, .name = "smite", .cat = .sword_axe },
    .{ .id = 18, .max = 5, .name = "bane_of_arthropods", .cat = .sword_axe },
    .{ .id = 19, .max = 2, .name = "knockback", .cat = .sword },
    .{ .id = 20, .max = 2, .name = "fire_aspect", .cat = .sword },
    .{ .id = 21, .max = 3, .name = "looting", .cat = .sword },
    .{ .id = 32, .max = 5, .name = "efficiency", .cat = .digger_shears },
    .{ .id = 33, .max = 1, .name = "silk_touch", .cat = .digger_shears },
    .{ .id = 34, .max = 3, .name = "unbreaking", .cat = .damageable },
    .{ .id = 35, .max = 3, .name = "fortune", .cat = .digger },
    .{ .id = 48, .max = 5, .name = "power", .cat = .bow },
    .{ .id = 49, .max = 2, .name = "punch", .cat = .bow },
    .{ .id = 50, .max = 1, .name = "flame", .cat = .bow },
    .{ .id = 51, .max = 1, .name = "infinity", .cat = .bow },
    .{ .id = 61, .max = 3, .name = "luck_of_the_sea", .cat = .rod },
};

pub fn enchantById(id: u8) ?Ench {
    for (enchants) |e| if (e.id == id) return e;
    return null;
}

/// Compatibility beyond "different enchants combine" (`aft.a` default):
/// protection variants are mutually exclusive except feather falling
/// (`agi.a`: same-variant -> false; either-side feather -> true), and the
/// damage trio never combines (`afq.a`: other-is-afq -> false).
pub fn enchantsCombine(a: u8, b: u8) bool {
    if (a == b) return false;
    if (a <= 4 and b <= 4) {
        return a == 2 or b == 2;
    }
    const damage_trio = [_]u8{ 16, 17, 18 };
    const ai = std.mem.indexOfScalar(u8, &damage_trio, a) != null;
    const bi = std.mem.indexOfScalar(u8, &damage_trio, b) != null;
    if (ai and bi) return false;
    return true;
}

fn inSet(wire: u16, set: []const u16) bool {
    for (set) |id| if (id == wire) return true;
    return false;
}

const swords = [_]u16{ 267, 268, 272, 276, 283 };
const axes = [_]u16{ 258, 271, 275, 279, 286 };
const picks = [_]u16{ 257, 270, 274, 278, 285 };
const shovels = [_]u16{ 256, 269, 273, 277, 284 };
const hoes = [_]u16{ 290, 291, 292, 293, 294 };
const helmets = [_]u16{ 298, 302, 306, 310, 314 };
const chests = [_]u16{ 299, 303, 307, 311, 315 };
const legs = [_]u16{ 300, 304, 308, 312, 316 };
const boots = [_]u16{ 301, 305, 309, 313, 317 };

/// Numeric item ids that take damage (vanilla `Item.p()`), for unbreaking.
/// Tools, armor, bow, rod, shears, flint+steel, carrot on a stick.
pub fn isDamageable(wire: u16) bool {
    if (wire == 259 or wire == 261 or wire == 346 or wire == 359 or wire == 398) return true;
    for (damage_sets) |set| if (inSet(wire, set)) return true;
    return false;
}

/// Tool/armor set table backing isDamageable (one loop, no 9-arm chain).
const damage_sets = [_][]const u16{ &swords, &axes, &picks, &shovels, &hoes, &helmets, &chests, &legs, &boots };

pub fn enchantApplies(cat: EnchCat, wire: u16) bool {
    return switch (cat) {
        .any_armor => inSet(wire, &helmets) or inSet(wire, &chests) or inSet(wire, &legs) or inSet(wire, &boots),
        .boots => inSet(wire, &boots),
        .head => inSet(wire, &helmets),
        .torso => inSet(wire, &chests),
        .sword_axe => inSet(wire, &swords) or inSet(wire, &axes),
        .sword => inSet(wire, &swords),
        // digger = acg tool base = pick/shovel/axe (swords excluded).
        .digger_shears => inSet(wire, &picks) or inSet(wire, &shovels) or inSet(wire, &axes) or wire == 359,
        .digger => inSet(wire, &picks) or inSet(wire, &shovels) or inSet(wire, &axes),
        .damageable => isDamageable(wire),
        .bow => wire == 261,
        .rod => wire == 346,
    };
}

/// Potion effect names 1..23 (vanilla `Potion` registry order).
pub const effect_names = [_]?[]const u8{
    null, // 0 unused
    "Speed", // 1
    "Slowness", // 2
    "Haste", // 3
    "Mining Fatigue", // 4
    "Strength", // 5
    "Instant Health", // 6
    "Instant Damage", // 7
    "Jump Boost", // 8
    "Nausea", // 9
    "Regeneration", // 10
    "Resistance", // 11
    "Fire Resistance", // 12
    "Water Breathing", // 13
    "Invisibility", // 14
    "Blindness", // 15
    "Night Vision", // 16
    "Hunger", // 17
    "Weakness", // 18
    "Poison", // 19
    "Wither", // 20
    "Health Boost", // 21
    "Absorption", // 22
    "Saturation", // 23
};

pub fn effectName(id: u8) ?[]const u8 {
    if (id >= effect_names.len) return null;
    return effect_names[id];
}

/// Summonable living entities: 1.7.10 type id + default health.
/// Names from `sg` clinit; EnderCrystal (200) is not living and rejected.
pub const Mob = struct {
    name: []const u8,
    type_id: u8,
    health: f32,
};

pub const mobs = [_]Mob{
    .{ .name = "Creeper", .type_id = 50, .health = 20 },
    .{ .name = "Skeleton", .type_id = 51, .health = 20 },
    .{ .name = "Spider", .type_id = 52, .health = 16 },
    .{ .name = "Giant", .type_id = 53, .health = 100 },
    .{ .name = "Zombie", .type_id = 54, .health = 20 },
    .{ .name = "Slime", .type_id = 55, .health = 8 },
    .{ .name = "Ghast", .type_id = 56, .health = 10 },
    .{ .name = "PigZombie", .type_id = 57, .health = 20 },
    .{ .name = "Enderman", .type_id = 58, .health = 40 },
    .{ .name = "CaveSpider", .type_id = 59, .health = 12 },
    .{ .name = "Silverfish", .type_id = 60, .health = 8 },
    .{ .name = "Blaze", .type_id = 61, .health = 20 },
    .{ .name = "LavaSlime", .type_id = 62, .health = 8 },
    .{ .name = "EnderDragon", .type_id = 63, .health = 200 },
    .{ .name = "WitherBoss", .type_id = 64, .health = 300 },
    .{ .name = "Bat", .type_id = 65, .health = 6 },
    .{ .name = "Witch", .type_id = 66, .health = 26 },
    .{ .name = "Pig", .type_id = 90, .health = 10 },
    .{ .name = "Sheep", .type_id = 91, .health = 8 },
    .{ .name = "Cow", .type_id = 92, .health = 10 },
    .{ .name = "Chicken", .type_id = 93, .health = 4 },
    .{ .name = "Squid", .type_id = 94, .health = 10 },
    .{ .name = "Wolf", .type_id = 95, .health = 8 },
    .{ .name = "MushroomCow", .type_id = 96, .health = 10 },
    .{ .name = "SnowMan", .type_id = 97, .health = 4 },
    .{ .name = "Ozelot", .type_id = 98, .health = 6 },
    .{ .name = "VillagerGolem", .type_id = 99, .health = 100 },
    .{ .name = "EntityHorse", .type_id = 100, .health = 20 },
    .{ .name = "Villager", .type_id = 120, .health = 20 },
};

pub fn mobByName(name: []const u8) ?Mob {
    for (mobs) |m| if (std.mem.eql(u8, m.name, name)) return m;
    return null;
}

/// Gamerules with vanilla defaults (`agy` ctor).
pub const Gamerule = struct {
    name: []const u8,
    default: bool,
};

pub const gamerules = [_]Gamerule{
    .{ .name = "doFireTick", .default = true },
    .{ .name = "mobGriefing", .default = true },
    .{ .name = "keepInventory", .default = false },
    .{ .name = "doMobSpawning", .default = true },
    .{ .name = "doMobLoot", .default = true },
    .{ .name = "doTileDrops", .default = true },
    .{ .name = "commandBlockOutput", .default = true },
    .{ .name = "naturalRegeneration", .default = true },
    .{ .name = "doDaylightCycle", .default = true },
};

/// Scoreboard objective criteria in 1.7.10 (`bah` + `bph`).
pub const criteria = [_][]const u8{ "dummy", "health", "deathCount", "playerKillCount", "totalKillCount" };

/// Display slots for `setdisplay` (name + numeric wire value).
pub const display_slots = [_]struct { name: []const u8, value: u8 }{
    .{ .name = "list", .value = 0 },
    .{ .name = "sidebar", .value = 1 },
    .{ .name = "belowName", .value = 2 },
};

/// Team color option values (the 16 vanilla chat colors).
pub const team_colors = [_][]const u8{
    "black", "dark_blue", "dark_green", "dark_aqua", "dark_red",
    "dark_purple", "gold", "gray", "dark_gray", "blue",
    "green", "aqua", "red", "light_purple", "yellow", "white",
};

/// The 33 achievements (`AchievementList`, class `pc`).
pub const achievements = [_][]const u8{
    "achievement.openInventory", "achievement.mineWood", "achievement.buildWorkBench",
    "achievement.buildPickaxe", "achievement.buildFurnace", "achievement.acquireIron",
    "achievement.buildHoe", "achievement.makeBread", "achievement.bakeCake",
    "achievement.buildBetterPickaxe", "achievement.cookFish", "achievement.onARail",
    "achievement.buildSword", "achievement.killEnemy", "achievement.killCow",
    "achievement.flyPig", "achievement.snipeSkeleton", "achievement.diamonds",
    "achievement.portal", "achievement.ghast", "achievement.blazeRod",
    "achievement.potion", "achievement.theEnd", "achievement.theEnd2",
    "achievement.enchantments", "achievement.overkill", "achievement.bookcase",
    "achievement.breedCow", "achievement.spawnWither", "achievement.killWither",
    "achievement.fullBeacon", "achievement.exploreAllBiomes", "achievement.diamondsToYou",
};

pub fn isAchievement(name: []const u8) bool {
    for (achievements) |a| if (std.mem.eql(u8, a, name)) return true;
    return false;
}

/// Display titles for the announce line (`en_US.lang`).
pub fn achievementTitle(name: []const u8) ?[]const u8 {
    const table = [_]struct { key: []const u8, title: []const u8 }{
        .{ .key = "achievement.openInventory", .title = "Taking Inventory" },
        .{ .key = "achievement.mineWood", .title = "Getting Wood" },
        .{ .key = "achievement.buildWorkBench", .title = "Benchmarking" },
        .{ .key = "achievement.buildPickaxe", .title = "Time to Mine!" },
        .{ .key = "achievement.buildFurnace", .title = "Hot Topic" },
        .{ .key = "achievement.acquireIron", .title = "Acquire Hardware" },
        .{ .key = "achievement.buildHoe", .title = "Time to Farm!" },
        .{ .key = "achievement.makeBread", .title = "Bake Bread" },
        .{ .key = "achievement.bakeCake", .title = "The Lie" },
        .{ .key = "achievement.buildBetterPickaxe", .title = "Getting an Upgrade" },
        .{ .key = "achievement.cookFish", .title = "Delicious Fish" },
        .{ .key = "achievement.onARail", .title = "On A Rail" },
        .{ .key = "achievement.buildSword", .title = "Time to Strike!" },
        .{ .key = "achievement.killEnemy", .title = "Monster Hunter" },
        .{ .key = "achievement.killCow", .title = "Cow Tipper" },
        .{ .key = "achievement.flyPig", .title = "When Pigs Fly" },
        .{ .key = "achievement.snipeSkeleton", .title = "Sniper Duel" },
        .{ .key = "achievement.diamonds", .title = "DIAMONDS!" },
        .{ .key = "achievement.portal", .title = "We Need to Go Deeper" },
        .{ .key = "achievement.ghast", .title = "Return to Sender" },
        .{ .key = "achievement.blazeRod", .title = "Into Fire" },
        .{ .key = "achievement.potion", .title = "Local Brewery" },
        .{ .key = "achievement.theEnd", .title = "The End?" },
        .{ .key = "achievement.theEnd2", .title = "The End." },
        .{ .key = "achievement.enchantments", .title = "Enchanter" },
        .{ .key = "achievement.overkill", .title = "Overkill" },
        .{ .key = "achievement.bookcase", .title = "Librarian" },
        .{ .key = "achievement.breedCow", .title = "Repopulation" },
        .{ .key = "achievement.spawnWither", .title = "The Beginning?" },
        .{ .key = "achievement.killWither", .title = "The Beginning." },
        .{ .key = "achievement.fullBeacon", .title = "Beaconator" },
        .{ .key = "achievement.exploreAllBiomes", .title = "Adventuring Time" },
        .{ .key = "achievement.diamondsToYou", .title = "Diamonds to you!" },
    };
    for (table) |e| if (std.mem.eql(u8, e.key, name)) return e.title;
    return null;
}

/// Plain (non-suffixed) stat names (`StatList`, class `pp`).
pub const stat_bases = [_][]const u8{
    "stat.leaveGame", "stat.playOneMinute", "stat.walkOneCm", "stat.swimOneCm",
    "stat.fallOneCm", "stat.climbOneCm", "stat.flyOneCm", "stat.diveOneCm",
    "stat.minecartOneCm", "stat.boatOneCm", "stat.pigOneCm", "stat.horseOneCm",
    "stat.jump", "stat.drop", "stat.damageDealt", "stat.damageTaken",
    "stat.deaths", "stat.mobKills", "stat.animalsBred", "stat.playerKills",
    "stat.fishCaught", "stat.junkFished", "stat.treasureFished",
};

/// Suffixed stat families (`stat.mineBlock.<id>` etc., numeric suffix).
pub const stat_suffixed = [_][]const u8{
    "stat.breakItem", "stat.craftItem", "stat.useItem",
    "stat.mineBlock", "stat.killEntity", "stat.entityKilledBy",
};

/// Validate a `/achievement give` name: `*`, an achievement, a plain stat,
/// or a suffixed stat with a numeric id.
pub fn validStatName(name: []const u8) bool {
    if (std.mem.eql(u8, name, "*")) return true;
    if (isAchievement(name)) return true;
    for (stat_bases) |s| if (std.mem.eql(u8, s, name)) return true;
    for (stat_suffixed) |fam| {
        if (name.len > fam.len + 1 and std.mem.startsWith(u8, name, fam) and name[fam.len] == '.') {
            const num = name[fam.len + 1 ..];
            if (num.len == 0) return false;
            for (num) |c| if (!std.ascii.isDigit(c)) return false;
            return true;
        }
    }
    return false;
}

test "enchant table: 23 entries, max levels spot-checked" {
    try std.testing.expectEqual(@as(usize, 23), enchants.len);
    try std.testing.expectEqual(@as(u8, 4), enchantById(0).?.max);
    try std.testing.expectEqual(@as(u8, 1), enchantById(6).?.max);
    try std.testing.expectEqual(@as(u8, 3), enchantById(61).?.max);
    try std.testing.expect(enchantById(62) == null);
    try std.testing.expect(enchantById(8) == null);
    // combine rules: protection variants exclusive except feather;
    // damage trio (sharp/smite/bane) never combines
    try std.testing.expect(!enchantsCombine(0, 1));
    try std.testing.expect(!enchantsCombine(3, 3));
    try std.testing.expect(enchantsCombine(0, 2));
    try std.testing.expect(enchantsCombine(2, 4));
    try std.testing.expect(!enchantsCombine(16, 17));
    try std.testing.expect(!enchantsCombine(17, 18));
    try std.testing.expect(enchantsCombine(16, 19));
    // silk + fortune combine via /enchant (the anvil blocks it separately)
    try std.testing.expect(enchantsCombine(33, 35));
}

test "applicability spot checks" {
    try std.testing.expect(enchantApplies(.sword_axe, 267));
    try std.testing.expect(enchantApplies(.sword_axe, 258));
    try std.testing.expect(!enchantApplies(.sword, 258));
    try std.testing.expect(!enchantApplies(.digger, 359));
    try std.testing.expect(enchantApplies(.digger_shears, 359));
    try std.testing.expect(enchantApplies(.damageable, 290)); // hoes
    try std.testing.expect(!enchantApplies(.damageable, 1)); // stone block item? wire 1 not in sets
    try std.testing.expect(enchantApplies(.boots, 301));
    try std.testing.expect(!enchantApplies(.head, 301));
    try std.testing.expect(enchantApplies(.rod, 346));
}

test "mobs/effects/stats tables" {
    try std.testing.expectEqual(@as(u8, 50), mobByName("Creeper").?.type_id);
    try std.testing.expectEqual(@as(u8, 90), mobByName("Pig").?.type_id);
    try std.testing.expect(mobByName("EnderCrystal") == null);
    try std.testing.expectEqualStrings("Speed", effectName(1).?);
    try std.testing.expect(effectName(0) == null);
    try std.testing.expect(effectName(24) == null);
    try std.testing.expect(validStatName("*"));
    try std.testing.expect(validStatName("achievement.openInventory"));
    try std.testing.expect(validStatName("stat.jump"));
    try std.testing.expect(validStatName("stat.mineBlock.1"));
    try std.testing.expect(!validStatName("stat.nope"));
    try std.testing.expect(!validStatName("stat.mineBlock.x"));
}
