//! Aggregate for the 1.7.10 protocol profile.
//!
//! Core code should refer to `version.proto` (or a narrower semantic API)
//! rather than reaching into individual v5 files. During C0 this root only
//! re-exports the existing modules; no packet or registry behaviour changes.

pub const meta = @import("meta.zig").current;
pub const ids = @import("ids.zig");
pub const packets = @import("packets.zig");
pub const slot = @import("slot.zig");
pub const wire = @import("wire_ids.zig");
pub const chunks = @import("chunks.zig");
pub const cmd_data = @import("cmd_data.zig");
