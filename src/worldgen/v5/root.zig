//! Aggregate for the 1.7.10 world generator.
//!
//! The version-neutral pipeline driver lives one level up; this root exposes
//! the concrete stage implementations selected by the `mc5` profile.

pub const gen = @import("gen.zig");
pub const serve = @import("serve.zig");
pub const genpool = @import("genpool.zig");
pub const noise = @import("noise.zig");
pub const biome = @import("biome.zig");
pub const genlayer = @import("genlayer.zig");
pub const shaper = @import("shaper.zig");
pub const surface = @import("surface.zig");
pub const decor = @import("decor.zig");
pub const carve = @import("carve.zig");
