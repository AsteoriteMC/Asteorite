//! /seed — print the world seed.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "seed",
    .node = "asteorite.command.seed",
    .min_level = .gamemaster,
    .spec = &.{&[_]cmd.Slot{}},
    .usage_override = "/seed",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    _ = sender;
    var toks: [1][]const u8 = undefined;
    if (cmd.Spec.tokenize(args, &toks) > 0) return cmd.usageError(&def, out);
    return srv.seedString(out);
}

const std = @import("std");

test "seed usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/seed", def.usage());
}
