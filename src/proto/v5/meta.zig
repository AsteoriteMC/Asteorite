//! Profile metadata for 1.7.10 / protocol 5.

pub const Meta = struct {
    profile_id: []const u8,
    name: []const u8,
    protocol: i32,

    min_y: i16,
    max_y: i16,
    section_count: u16,

    has_compression: bool,
    has_bulk_chunks: bool,
    has_block_states: bool,
    has_offhand: bool,
    has_config_phase: bool,
    inventory_slots: u16,

    // C7/C8 profile-owned limits. Shared scheduling reads these instead of
    // hardcoding 1.7.10 bulk dimensions or height assumptions.
    max_bulk_columns: u16 = 32,
    max_column_bytes: usize = 196864,
    lighting_model: []const u8 = "pre_1_18",
};

pub const current: Meta = .{
    .profile_id = "mc5",
    .name = "1.7.10",
    .protocol = 5,

    .min_y = 0,
    .max_y = 255,
    .section_count = 16,

    .has_compression = false,
    .has_bulk_chunks = true,
    .has_block_states = false,
    .has_offhand = false,
    .has_config_phase = false,
    .inventory_slots = 45,

    .max_bulk_columns = 32,
    .max_column_bytes = 196864,
    .lighting_model = "pre_1_18",
};

test "1.7.10 metadata" {
    const std = @import("std");
    try std.testing.expectEqualStrings("mc5", current.profile_id);
    try std.testing.expectEqual(@as(i32, 5), current.protocol);
    try std.testing.expectEqual(@as(i16, 0), current.min_y);
    try std.testing.expectEqual(@as(i16, 255), current.max_y);
    try std.testing.expect(!current.has_compression);
    try std.testing.expect(current.has_bulk_chunks);
    try std.testing.expectEqual(@as(u16, 45), current.inventory_slots);
}
