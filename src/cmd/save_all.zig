//! /save-all — persist players and flush the world store.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "save-all",
    .node = "asteorite.command.save-all",
    .min_level = .owner,
    .spec = &.{&[_]cmd.Slot{}},
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [1][]const u8 = undefined;
    if (cmd.Spec.tokenize(args, &toks) > 0) return cmd.usageError(&def, out);
    // Vanilla two-step flow: the sender sees both raw lines (direct +
    // reply); other ops see the gray admin forms.
    srv.sendDirect(sender, "Saving...");
    srv.notifyAdmins(sender, &def, "Saving...");
    _ = srv.saveAllPlayers();
    srv.saveRedstone();
    srv.flushWorld();
    const done = "Saved the world";
    srv.notifyAdmins(sender, &def, done);
    return done;
}

const std = @import("std");

test "save-all usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/save-all", def.usage());
}
