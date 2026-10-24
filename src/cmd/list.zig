//! /list — who is online (vanilla two-line format).

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "list",
    .node = "asteorite.command.list",
    .min_level = .all,
    .spec = &.{&[_]cmd.Slot{}},
    .usage_override = "/list",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    _ = sender;
    var toks: [1][]const u8 = undefined;
    if (cmd.Spec.tokenize(args, &toks) > 0) return cmd.usageError(&def, out);
    var names: [256][16]u8 = undefined;
    var lens: [256]u8 = undefined;
    const n = srv.playNames(&names, &lens);
    var ow: usize = 0;
    ow += (std.fmt.bufPrint(out[ow..], "There are {d}/{d} players online:\n", .{ n, srv.maxPlayers() }) catch return def.usage()).len;
    for (0..n) |i| {
        ow += (std.fmt.bufPrint(out[ow..], "{s}{s}", .{ if (i == 0) "" else ", ", names[i][0..lens[i]] }) catch break).len;
    }
    return out[0..ow];
}

const std = @import("std");

test "list usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/list", def.usage());
}
