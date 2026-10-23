//! 1.7.10 game-data tables.
//!
//! C0 establishes the profile-owned game namespace and moves the scoreboard's
//! criteria dependency behind it. `cmd_data` still lives under `proto/v5/`
//! for now; C6 relocates the remaining tables here without changing their
//! contents.
//!
//! C6 (partial): the 1.7.10 recipe and smelting data tables now live here;
//! their shared engines remain `sim/{recipes,smelting}.zig`. Block/redstone
//! behavior data lives in `mc5/{blocks,rules}.zig`; drops and enchanting
//! tables live in `mc5/{drops,enchanting}_data.zig`; generated registry
//! tables remain to move.

pub const cmd_data = @import("../proto/v5/cmd_data.zig");
pub const recipes_data = @import("mc5/recipes_data.zig");
pub const smelting_data = @import("mc5/smelting_data.zig");
/// Canonical mob kind <-> 1.7.10 SpawnMob type id.
pub const mobs = @import("mc5/mobs.zig");
/// 1.7.10 block drop table.
pub const drops_data = @import("mc5/drops_data.zig");
/// Dense 1.7.10 block-definition table (normal cube, support, piston
/// mobility, redstone component identity).
pub const blocks = @import("mc5/blocks.zig").table;
pub const placeBlockForHeld = @import("mc5/blocks.zig").placeBlockForHeld;
/// 1.7.10 enchanting tables (enchantability, weights, min/max ranges).
pub const enchanting_data = @import("mc5/enchanting_data.zig");
