//! /tell — private message (aliases w, msg).

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "tell",
    .node = "asteorite.command.tell",
    .min_level = .all,
    .aliases = &.{ "w", "msg" },
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .player = {} } },
            cmd.Slot{ .arg = .{ .rest = {} }, .display = "<private message ...>" },
        },
    },
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [64][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n < 2) return cmd.usageError(&def, out);
    var target: [cmd.max_name_len]u8 = undefined;
    const t = cmd.resolveTarget(srv, sender, toks[0], &target) orelse return cmd.unknown_player;
    if (sender) |c| {
        var who: [cmd.max_name_len]u8 = undefined;
        const from = cmd.senderName(c, &who);
        if (std.mem.eql(u8, from, t)) return "You can't send a private message to yourself!";
    }
    var msg: [1024]u8 = undefined;
    const text = cmd.Spec.joinRest(toks[0..n], 1, &msg) orelse return cmd.usageError(&def, out);
    var who: [cmd.max_name_len]u8 = undefined;
    const from = cmd.senderName(sender, &who);
    const sent = srv.tellPlayer(t, if (from.len == 0) "Server" else from, text, out) orelse {
        return "That player cannot be found";
    };
    return sent;
}

const std = @import("std");

test "tell usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/tell <player> <private message ...>", def.usage());
}
