//! /save-off — disable world auto-saving.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "save-off",
    .node = "asteorite.command.save-off",
    .min_level = .owner,
    .spec = &.{&[_]cmd.Slot{}},
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [1][]const u8 = undefined;
    if (cmd.Spec.tokenize(args, &toks) > 0) return cmd.usageError(&def, out);
    if (!srv.getAutosave()) return "Saving is already turned off.";
    srv.setAutosave(false);
    const msg = "Turned off world auto-saving";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "save-off usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/save-off", def.usage());
}
