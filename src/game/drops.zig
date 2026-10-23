//! Canonical drop-roll result shared by all profiles.
//!
//! The actual drop table is profile data (`game/mc5/drops_data.zig`); this
//! module only owns the shared result type so engines and tests can name it
//! without reaching into a profile.

const ids = @import("../ids.zig");

pub const DropRoll = struct {
    item_id: ids.Id,
    damage: i16,
    singles: u8,
};
