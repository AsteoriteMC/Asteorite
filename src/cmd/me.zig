//! /me — emote broadcast `* name message`.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "me",
    .node = "asteorite.command.me",
    .min_level = .all,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .rest = {} }, .display = "<action ...>" },
        },
    },
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [64][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n == 0) return cmd.usageError(&def, out);
    var msg: [1024]u8 = undefined;
    const text = cmd.Spec.joinRest(toks[0..n], 0, &msg) orelse return cmd.usageError(&def, out);
    var who: [cmd.max_name_len]u8 = undefined;
    const name = cmd.senderName(sender, &who);
    srv.broadcastMe(if (name.len == 0) "Server" else name, text);
    return std.fmt.bufPrint(out, "* {s} {s}", .{ if (name.len == 0) "Server" else name, text }) catch cmd.usageError(&def, out);
}

const std = @import("std");

test "me usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/me <action ...>", def.usage());
}
