//! 1.7.10 / protocol 5 profile root.
//!
//! This file is intentionally a manifest, not a second implementation. The
//! modules it points at are the existing 1.7 trees; later profiles replace
//! only the namespaces that genuinely differ.

pub const meta = @import("../proto/v5/meta.zig").current;
pub const proto = @import("../proto/v5/root.zig");
pub const worldgen = @import("../worldgen/v5/root.zig");
pub const game = @import("../game/mc5.zig");
pub const rules = @import("../game/rules.zig").mc5;
