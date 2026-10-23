//! 1.7.10 block definitions consumed by shared behaviour engines.
//!
//! The switches below are the old `sim/redstone.zig` predicates moved behind
//! profile data. They are compiled into a dense canonical-id table at
//! comptime; no runtime profile dispatch remains.

const ids = @import("../../ids.zig");
const block = @import("../block.zig");

fn isNormalCube(id: ids.Id) bool {
    // `aji.r` approximation from the K1 port: full opaque cubes that carry
    // power and anchor components. Glass/ice/leaves/slabs/stairs/plants and
    // every power source never qualify.
    return switch (id) {
        .air,
        .sapling,
        .flowing_water,
        .water,
        .flowing_lava,
        .lava,
        .leaves,
        .leaves2,
        .glass,
        .bed_block,
        .golden_rail,
        .detector_rail,
        .activator_rail,
        .web,
        .tallgrass,
        .deadbush,
        .yellow_flower,
        .red_flower,
        .brown_mushroom,
        .red_mushroom,
        .stone_slab,
        .wooden_slab,
        .double_stone_slab,
        .double_wooden_slab,
        .torch,
        .fire,
        .oak_stairs,
        .spruce_stairs,
        .birch_stairs,
        .jungle_stairs,
        .acacia_stairs,
        .dark_oak_stairs,
        .stone_stairs,
        .brick_stairs,
        .stone_brick_stairs,
        .quartz_stairs,
        .sandstone_stairs,
        .nether_brick_stairs,
        .redstone_wire,
        .redstone_block,
        .wheat_block,
        .standing_sign,
        .wall_sign,
        .wooden_door_block,
        .iron_door_block,
        .ladder,
        .rail,
        .lever,
        .stone_pressure_plate,
        .wooden_pressure_plate,
        .light_weighted_pressure_plate,
        .heavy_weighted_pressure_plate,
        .unlit_redstone_torch,
        .redstone_torch,
        .stone_button,
        .wooden_button,
        .snow_layer,
        .ice,
        .reeds_block,
        .fence,
        .nether_brick_fence,
        .cobblestone_wall,
        .fence_gate,
        .unpowered_repeater,
        .powered_repeater,
        .unpowered_comparator,
        .powered_comparator,
        .trapdoor,
        .pumpkin_stem,
        .melon_stem,
        .vine,
        .waterlily,
        .nether_wart_block,
        .piston_head,
        .piston_extension,
        .enchanting_table,
        .brewing_stand_block,
        .cauldron_block,
        .end_portal_frame,
        .flower_pot_block,
        .carrots,
        .potatoes,
        .skull_block,
        .anvil,
        .trapped_chest,
        .daylight_detector,
        .hopper,
        .dropper,
        .dispenser,
        .tripwire,
        .tripwire_hook,
        .snow,
        .cactus,
        .portal,
        .cake_block,
        .stained_glass,
        .stained_glass_pane,
        .glass_pane,
        => false,
        else => true,
    };
}

fn isSolidTop(id: ids.Id) bool {
    return switch (id) {
        .glass, .glowstone, .stone_slab, .wooden_slab, .hopper => true,
        else => false,
    };
}

fn isAnchorPost(id: ids.Id) bool {
    return switch (id) {
        .fence, .nether_brick_fence, .glass, .cobblestone_wall => true,
        else => false,
    };
}

fn isPlateAnchor(id: ids.Id) bool {
    return switch (id) {
        .fence, .nether_brick_fence => true,
        else => false,
    };
}

fn mobility(id: ids.Id) block.PistonMobility {
    return switch (id) {
        .redstone_wire,
        .redstone_torch,
        .unlit_redstone_torch,
        .lever,
        .stone_button,
        .wooden_button,
        .stone_pressure_plate,
        .wooden_pressure_plate,
        .light_weighted_pressure_plate,
        .heavy_weighted_pressure_plate,
        .unpowered_repeater,
        .powered_repeater,
        .unpowered_comparator,
        .powered_comparator,
        .torch,
        .tripwire,
        .tripwire_hook,
        .rail,
        .golden_rail,
        .detector_rail,
        .activator_rail,
        .sapling,
        .tallgrass,
        .deadbush,
        .yellow_flower,
        .red_flower,
        .brown_mushroom,
        .red_mushroom,
        .wheat_block,
        .carrots,
        .potatoes,
        .pumpkin_stem,
        .melon_stem,
        .reeds_block,
        .nether_wart_block,
        .cactus,
        .vine,
        .waterlily,
        .leaves,
        .leaves2,
        .web,
        .fire,
        .snow_layer,
        .snow,
        .flowing_water,
        .water,
        .flowing_lava,
        .lava,
        => .destroy,
        else => .pushable,
    };
}

fn isUnbreakable(id: ids.Id) bool {
    return switch (id) {
        .bedrock, .portal, .end_portal, .end_portal_frame => true,
        else => false,
    };
}

fn isContainer(id: ids.Id) bool {
    return switch (id) {
        .chest,
        .trapped_chest,
        .furnace,
        .lit_furnace,
        .dispenser,
        .dropper,
        .brewing_stand_block,
        .enchanting_table,
        .jukebox,
        .hopper,
        .wall_sign,
        .standing_sign,
        .skull_block,
        .flower_pot_block,
        .piston_extension,
        => true,
        else => false,
    };
}

fn isAlwaysPowerSource(id: ids.Id) bool {
    return switch (id) {
        .redstone_block, .trapped_chest, .daylight_detector => true,
        else => false,
    };
}

fn isComponent(id: ids.Id) bool {
    return switch (id) {
        .redstone_wire,
        .redstone_torch,
        .unlit_redstone_torch,
        .lever,
        .stone_button,
        .wooden_button,
        .stone_pressure_plate,
        .wooden_pressure_plate,
        .light_weighted_pressure_plate,
        .heavy_weighted_pressure_plate,
        .unpowered_repeater,
        .powered_repeater,
        .redstone_lamp,
        .lit_redstone_lamp,
        .wooden_door_block,
        .iron_door_block,
        .trapdoor,
        .piston,
        .sticky_piston,
        .piston_head,
        => true,
        else => false,
    };
}

fn isInteractable(id: ids.Id) bool {
    return switch (id) {
        .lever,
        .stone_button,
        .wooden_button,
        .wooden_door_block,
        .iron_door_block,
        .trapdoor,
        .fence_gate,
        .unpowered_repeater,
        .powered_repeater,
        .redstone_ore,
        .lit_redstone_ore,
        => true,
        else => false,
    };
}

fn kind(id: ids.Id) block.RedstoneKind {
    return switch (id) {
        .redstone_wire => .wire,
        .lever => .lever,
        .stone_button => .button_stone,
        .wooden_button => .button_wood,
        .stone_pressure_plate => .plate_stone,
        .wooden_pressure_plate => .plate_wood,
        .light_weighted_pressure_plate => .plate_light,
        .heavy_weighted_pressure_plate => .plate_heavy,
        .redstone_torch => .torch_on,
        .unlit_redstone_torch => .torch_off,
        .powered_repeater => .repeater_on,
        .unpowered_repeater => .repeater_off,
        .lit_redstone_lamp => .lamp_on,
        .redstone_lamp => .lamp_off,
        .wooden_door_block => .door_wood,
        .iron_door_block => .door_iron,
        .trapdoor => .trapdoor,
        .fence_gate => .gate,
        .redstone_ore => .ore,
        .lit_redstone_ore => .ore_lit,
        .piston => .piston,
        .sticky_piston => .piston_sticky,
        .piston_head => .piston_head,
        else => .none,
    };
}

fn orientation(id: ids.Id) block.Orientation {
    return switch (id) {
        .lever => .lever,
        .stone_button, .wooden_button => .button,
        .torch, .redstone_torch, .unlit_redstone_torch => .torch,
        .unpowered_repeater, .powered_repeater, .unpowered_comparator, .powered_comparator => .diode,
        .trapdoor => .trapdoor,
        .wooden_door_block, .iron_door_block => .door,
        .fence_gate => .gate,
        .piston, .sticky_piston => .piston,
        .dispenser, .dropper => .directional,
        .hopper => .hopper,
        .anvil => .anvil,
        else => .none,
    };
}

fn def(id: ids.Id) block.BlockDef {
    return .{
        .normal_cube = isNormalCube(id),
        .solid_top = isSolidTop(id),
        .anchor_post = isAnchorPost(id),
        .plate_anchor = isPlateAnchor(id),
        .piston_mobility = mobility(id),
        .piston_unbreakable = isUnbreakable(id),
        .piston_container = isContainer(id),
        .always_power_source = isAlwaysPowerSource(id),
        .redstone_component = isComponent(id),
        .redstone_interactable = isInteractable(id),
        .redstone_kind = kind(id),
        .orientation = orientation(id),
    };
}

/// Held item -> block placed. Item placement identity is profile data;
/// shared interaction code only calls this table.
pub fn placeBlockForHeld(held: ids.Id) ?ids.Id {
    return switch (held) {
        .redstone => .redstone_wire,
        .water_bucket => .water,
        .lava_bucket => .lava,
        .repeater => .unpowered_repeater,
        .comparator => .unpowered_comparator,
        .wooden_door_item => .wooden_door_block,
        .iron_door_item => .iron_door_block,
        else => null,
    };
}

/// Dense canonical-id table. This is profile data, not engine logic.
pub const table: block.Table = block.Table.fromFn(def);

test "1.7.10 block table anchors" {
    const t = &table;
    try @import("std").testing.expect(t.get(.stone).normal_cube);
    try @import("std").testing.expect(!t.get(.glass).normal_cube);
    try @import("std").testing.expect(t.get(.glass).solid_top);
    try @import("std").testing.expect(!t.get(.redstone_block).normal_cube);
    try @import("std").testing.expect(t.get(.redstone_block).always_power_source);
    try @import("std").testing.expectEqual(block.PistonMobility.destroy, t.get(.torch).piston_mobility);
    try @import("std").testing.expect(t.get(.chest).piston_container);
    try @import("std").testing.expect(t.get(.bedrock).piston_unbreakable);
    try @import("std").testing.expectEqual(block.RedstoneKind.torch_on, t.get(.redstone_torch).redstone_kind);
    try @import("std").testing.expect(t.get(.redstone_torch).redstone_component);
    try @import("std").testing.expect(t.get(.redstone_ore).redstone_interactable);
    try @import("std").testing.expect(!t.get(.redstone_ore).redstone_component);
    try @import("std").testing.expectEqual(block.RedstoneKind.gate, t.get(.fence_gate).redstone_kind);
}
