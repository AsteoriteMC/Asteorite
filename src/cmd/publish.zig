//! /publish — LAN hosting is a single-player feature; always fails dedicated.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "publish",
    .node = "asteorite.command.publish",
    .min_level = 4,
    .spec = &.{&[_]cmd.Slot{}},
    .usage_override = "/publish",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [1][]const u8 = undefined;
    if (cmd.Spec.tokenize(args, &toks) > 0) return cmd.usageError(&def, out);
    // Vanilla tries shareToLAN, which returns null on a dedicated server.
    const msg = "Unable to host local game";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "publish usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/publish", def.usage());
}
