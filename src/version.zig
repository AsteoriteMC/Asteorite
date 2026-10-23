//! Compile-time Minecraft profile selection.
//!
//! `build.zig` turns `-Dmc=<version>` into the `build_options.mc_protocol`
//! constant. Because that value is comptime-known, this switch selects one
//! profile root and only that root's codecs/tables are analyzed for code
//! generation. There is deliberately no runtime protocol dispatch here.
//!
//! A profile root owns five namespaces:
//!   - `meta`:     identity, wire protocol, height/section and capabilities
//!   - `proto`:    packet/registry/chunk codecs
//!   - `worldgen`: the generator selected for this profile
//!   - `game`:     game-data tables
//!   - `rules`:    profile numbers consumed by shared engines
//!
//! C0 wires the contract for the existing 1.7.10 tree. The core still imports
//! some v5 modules directly behind the import-gate allowlist; C1-C5 burn that
//! list down.

const std = @import("std");
const opts = @import("build_options");

pub const profile = switch (opts.mc_protocol) {
    5 => @import("versions/mc5.zig"),
    else => @compileError("no profile root for this mc_protocol"),
};

pub const meta = profile.meta;
pub const proto = profile.proto;
pub const worldgen = profile.worldgen;
pub const game = profile.game;
pub const rules = profile.rules;

test "selected profile matches build options" {
    try std.testing.expectEqualStrings(opts.mc_name, meta.name);
    try std.testing.expectEqual(@as(i32, 5), meta.protocol);
    try std.testing.expectEqual(@as(u16, 5), opts.mc_protocol);
    // The profile root must expose the same contract the rest of the tree
    // consumes. Referencing a few critical aliases catches a broken root even
    // when the selected code path is shallow.
    try std.testing.expectEqual(@as(i32, 5), proto.ids.protocol_version_1_7_10);
    try std.testing.expect(proto.wire.fromWire(1) != null);
    try std.testing.expect(@hasDecl(proto.packets, "frameJoinGame"));
    try std.testing.expect(game.cmd_data.criteria.len > 0);
    try std.testing.expectEqual(@as(usize, 312), game.recipes_data.table.len);
    try std.testing.expectEqual(@as(usize, 22), game.smelting_data.table.len);
    try std.testing.expectEqual(@as(u16, 16), meta.section_count);
}
