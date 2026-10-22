//! /banlist — show banned names or IPs.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "banlist",
    .node = "asteorite.command.banlist",
    .min_level = 3,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .choice = &.{ "ips", "players" } }, .optional = true },
        },
    },
    .usage_override = "/banlist [ips|players]",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    _ = sender;
    var toks: [2][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n > 1) return cmd.usageError(&def, out);
    const want_ips = n == 1 and std.mem.eql(u8, toks[0], "ips");
    if (n == 1 and !want_ips and !std.mem.eql(u8, toks[0], "players")) return cmd.usageError(&def, out);
    return srv.banList(want_ips, out);
}

const std = @import("std");

test "banlist usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/banlist [ips|players]", def.usage());
}
