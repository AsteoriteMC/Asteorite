//! /testfor — command-block-only player check (always fails for players).

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "testfor",
    .node = "asteorite.command.testfor",
    .min_level = .gamemaster,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .player = {} } },
        },
    },
    .usage_override = "/testfor <player>",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [2][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n != 1) return cmd.usageError(&def, out);
    // Vanilla: only usable by command blocks with analog output. There are
    // no command blocks here, and the player path always throws — even the
    // sender's own name. Existence is still validated first (player lookup
    // throws playerNotFound before the command-block check).
    var target: [16]u8 = undefined;
    _ = srv.resolvePlayerName(sender, toks[0], &target) orelse {
        return "That player cannot be found";
    };
    return "/testfor is only usable by commandblocks with analog output";
}

const std = @import("std");

test "testfor usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/testfor <player>", def.usage());
}
