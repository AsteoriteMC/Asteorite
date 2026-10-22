//! /stop — shut the server down (the caller acts on it after the reply).

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "stop",
    .node = "asteorite.command.stop",
    .min_level = 4,
    .spec = &.{&[_]cmd.Slot{}},
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [1][]const u8 = undefined;
    if (cmd.Spec.tokenize(args, &toks) > 0) return cmd.usageError(&def, out);
    // Reply is delivered by the caller; it exits right after.
    const msg = "Stopping the server";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "stop usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/stop", def.usage());
}
