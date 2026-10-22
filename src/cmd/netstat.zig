//! /netstat — packet counters (console only; players get the vanilla refusal).

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "netstat",
    .node = "asteorite.command.netstat",
    .min_level = 0,
    .spec = &.{
        &[_]cmd.Slot{},
        &[_]cmd.Slot{cmd.Slot{ .arg = .{ .word = {} }, .display = "<hottest-read|hottest-write|most-read|most-write|netstat|packet-read|packet-write>" }},
    },
    .usage_override = "/netstat",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [2][]const u8 = undefined;
    _ = cmd.Spec.tokenize(args, &toks);
    // Players always get the refusal (vanilla checks the sender first).
    if (sender != null) return "Command is not available for players";
    return srv.netstatText(out);
}

const std = @import("std");

test "netstat usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/netstat", def.usage());
}
