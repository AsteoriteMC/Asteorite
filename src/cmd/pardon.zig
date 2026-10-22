//! /pardon — unban a name.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "pardon",
    .node = "asteorite.command.pardon",
    .min_level = 3,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .word = {} }, .display = "<name>" },
        },
    },
    .usage_override = "/pardon <name>",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [2][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n != 1) return cmd.usageError(&def, out);
    if (!srv.pardonName(toks[0])) {
        return std.fmt.bufPrint(out, "Could not unban player {s}", .{toks[0]}) catch "Could not unban player";
    }
    const msg = std.fmt.bufPrint(out, "Unbanned player {s}", .{toks[0]}) catch "Unbanned player";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "pardon usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/pardon <name>", def.usage());
}
