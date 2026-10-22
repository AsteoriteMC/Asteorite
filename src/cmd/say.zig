//! /say — broadcast `[name] message` to everyone.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "say",
    .node = "asteorite.command.say",
    .min_level = 1,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .rest = {} }, .display = "<message ...>" },
        },
    },
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [64][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n == 0) return cmd.usageError(&def, out);
    var msg: [1024]u8 = undefined;
    const text = cmd.Spec.joinRest(toks[0..n], 0, &msg) orelse return cmd.usageError(&def, out);
    var who: [16]u8 = undefined;
    const name = cmd.senderName(sender, &who);
    srv.broadcastSay(if (name.len == 0) "Server" else name, text);
    return std.fmt.bufPrint(out, "[{s}] {s}", .{ if (name.len == 0) "Server" else name, text }) catch cmd.usageError(&def, out);
}

const std = @import("std");

test "say usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/say <message ...>", def.usage());
}
