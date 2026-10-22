//! /toggledownfall — flip rain on/off.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "toggledownfall",
    .node = "asteorite.command.toggledownfall",
    .min_level = 2,
    .spec = &.{&[_]cmd.Slot{}},
    .usage_override = "/toggledownfall",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [1][]const u8 = undefined;
    if (cmd.Spec.tokenize(args, &toks) > 0) return cmd.usageError(&def, out);
    srv.toggleDownfall();
    const msg = "Toggled downfall";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "toggledownfall usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/toggledownfall", def.usage());
}
