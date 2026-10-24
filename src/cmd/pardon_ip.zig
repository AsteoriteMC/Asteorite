//! /pardon-ip — unban an address.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "pardon-ip",
    .node = "asteorite.command.pardon-ip",
    .min_level = .admin,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .word = {} }, .display = "<address>" },
        },
    },
    .usage_override = "/pardon-ip <address>",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [2][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n != 1) return cmd.usageError(&def, out);
    if (!srv.pardonIp(toks[0])) {
        return "You have entered an invalid IP address";
    }
    const msg = std.fmt.bufPrint(out, "Unbanned IP address {s}", .{toks[0]}) catch "Unbanned IP address";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "pardon-ip usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/pardon-ip <address>", def.usage());
}
