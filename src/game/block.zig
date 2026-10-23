//! Shared block-definition types.
//!
//! The profile owns the actual `BlockDef` values (`game/mc5/blocks.zig`);
//! shared engines only consume this table. Coverage grows with each
//! extraction: C2 starts with the fields redstone, piston and support logic
//! already need, rather than guessing values for systems that do not read
//! them yet.

const ids = @import("../ids.zig");

/// Piston mobility (`aji.h` / `awt.i()`): what a piston does when the block
/// is in its push line.
pub const PistonMobility = enum(u2) {
    /// `awt.b` / default: can be pushed intact.
    pushable = 0,
    /// `awt.a`: destroyed (dropped) when pushed.
    destroy = 1,
    /// Immovable; current 1.7 data reaches this through the unbreakable and
    /// container checks, but the value is kept distinct for later profiles.
    immovable = 2,
};

/// Placement orientation family. The shared placement math uses this to
/// choose the facing/meta table; the block id stays profile data.
pub const Orientation = enum(u8) {
    none,
    lever,
    button,
    torch,
    diode,
    trapdoor,
    door,
    gate,
    piston,
    directional,
    hopper,
    anvil,
};

/// Redstone component identity. This is semantic, not a wire id: profiles
/// may add components later without changing the shared power model.
pub const RedstoneKind = enum(u8) {
    none,
    wire,
    lever,
    button_stone,
    button_wood,
    plate_stone,
    plate_wood,
    plate_light,
    plate_heavy,
    torch_on,
    torch_off,
    repeater_on,
    repeater_off,
    lamp_on,
    lamp_off,
    door_wood,
    door_iron,
    trapdoor,
    gate,
    ore,
    ore_lit,
    piston,
    piston_sticky,
    piston_head,
};

/// One profile block definition. Defaults describe an ordinary pushable,
/// full-cube, inert block; profile data overrides only the exceptions.
pub const BlockDef = struct {
    /// Vanilla `aji.r`-style normal cube used for redstone conduction and
    /// component anchoring. Power sources are never normal cubes.
    normal_cube: bool = true,
    /// `ahb.a` solid top in addition to normal cubes (glass, slabs, hopper).
    solid_top: bool = false,
    /// `aoc.m` / `akz.a` post anchor (fence, wall, glass).
    anchor_post: bool = false,
    /// `ajd` pressure-plate anchor in addition to solid tops (fences).
    plate_anchor: bool = false,
    piston_mobility: PistonMobility = .pushable,
    piston_unbreakable: bool = false,
    piston_container: bool = false,
    /// Always-on redstone source regardless of metadata (redstone block,
    /// trapped chest, daylight detector).
    always_power_source: bool = false,
    /// Participates in neighbor recompute/fan-out (`needsRecompute`).
    redstone_component: bool = false,
    /// Right-click is owned by the redstone interaction path.
    redstone_interactable: bool = false,
    redstone_kind: RedstoneKind = .none,
    orientation: Orientation = .none,
};

/// Dense table indexed by canonical id. `fromFn` fills every entry at comptime
/// so hot paths get an array load instead of a switch.
pub const Table = struct {
    defs: [ids.COUNT]BlockDef,

    pub fn fromFn(comptime f: fn (ids.Id) BlockDef) Table {
        @setEvalBranchQuota(20000);
        var t: Table = undefined;
        for (&t.defs, 0..) |*d, i| {
            d.* = f(@enumFromInt(i));
        }
        return t;
    }

    pub fn get(self: *const Table, id: ids.Id) BlockDef {
        return self.defs[@intFromEnum(id)];
    }
};
