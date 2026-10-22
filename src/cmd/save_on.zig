//! /save-on — enable world auto-saving.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "save-on",
    .node = "asteorite.command.save-on",
    .min_level = 4,
    .spec = &.{&[_]cmd.Slot{}},
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [1][]const u8 = undefined;
    if (cmd.Spec.tokenize(args, &toks) > 0) return cmd.usageError(&def, out);
    if (srv.getAutosave()) return "Saving is already turned on.";
    srv.setAutosave(true);
    const msg = "Turned on world auto-saving";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "save-on usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/save-on", def.usage());
}
