//! /setidletimeout — minutes until idle kick (0 = never).

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "setidletimeout",
    .node = "asteorite.command.setidletimeout",
    .min_level = .admin,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .int_range = .{} }, .display = "<Minutes until kick>" },
        },
    },
    .usage_override = "/setidletimeout <Minutes until kick>",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [2][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n != 1) return cmd.usageError(&def, out);
    const mins = std.fmt.parseInt(i64, toks[0], 10) catch return cmd.usageError(&def, out);
    if (mins < 0) {
        return std.fmt.bufPrint(out, "The number you have entered ({d}) is too small, it must be at least 0", .{mins}) catch cmd.usageError(&def, out);
    }
    if (mins > 2147483647) {
        return std.fmt.bufPrint(out, "The number you have entered ({d}) is too big, it must be at most 2147483647", .{mins}) catch cmd.usageError(&def, out);
    }
    srv.setIdleTimeout(@intCast(mins));
    const msg = std.fmt.bufPrint(out, "Successfully set the idle timeout to {d} minutes.", .{mins}) catch "Idle timeout set";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "setidletimeout usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/setidletimeout <Minutes until kick>", def.usage());
}
