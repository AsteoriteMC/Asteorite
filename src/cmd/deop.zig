//! /deop — strip a player's operator status.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "deop",
    .node = "asteorite.command.deop",
    .min_level = 3,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .word = {} }, .display = "<player>" },
        },
    },
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [2][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n != 1) return cmd.usageError(&def, out);
    if (toks[0].len == 0 or toks[0].len > 16) return cmd.usageError(&def, out);
    srv.deopPlayer(toks[0]);
    const msg = std.fmt.bufPrint(out, "De-opped {s}", .{toks[0]}) catch "De-opped";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "deop usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/deop <player>", def.usage());
}
