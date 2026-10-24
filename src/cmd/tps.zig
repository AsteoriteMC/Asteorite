//! /tps — tick timing + counts (server extension like /netstat, but
//! usable by players: no vanilla refusal).

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "tps",
    .node = "asteorite.command.tps",
    .min_level = .all,
    .spec = &.{&[_]cmd.Slot{}},
    .usage_override = "/tps",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    _ = sender;
    var toks: [1][]const u8 = undefined;
    if (cmd.Spec.tokenize(args, &toks) > 0) return cmd.usageError(&def, out);
    return srv.tpsText(out);
}

const std = @import("std");

test "tps usage string" {
    try std.testing.expectEqualStrings("/tps", def.usage());
}
