//! /kick — disconnect a player with an optional reason.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "kick",
    .node = "asteorite.command.kick",
    .min_level = .gamemaster,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .player = {} } },
            cmd.Slot{ .arg = .{ .rest = {} }, .optional = true, .display = "<reason ...>" },
        },
    },
    .usage_override = "/kick <player> [reason ...]",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [64][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n == 0) return cmd.usageError(&def, out);
    var target: [16]u8 = undefined;
    const t = srv.resolvePlayerName(sender, toks[0], &target) orelse {
        return "That player cannot be found";
    };
    if (n == 1) {
        if (!srv.kickPlayer(t, null)) return "That player cannot be found";
        srv.notifyAdmins(sender, &def, std.fmt.bufPrint(out, "Kicked {s} from the game", .{t}) catch "Kicked");
        return std.fmt.bufPrint(out, "Kicked {s} from the game", .{t}) catch cmd.usageError(&def, out);
    }
    var rb: [1024]u8 = undefined;
    const reason = cmd.Spec.joinRest(toks[0..n], 1, &rb) orelse return cmd.usageError(&def, out);
    if (!srv.kickPlayer(t, reason)) return "That player cannot be found";
    const msg = std.fmt.bufPrint(out, "Kicked {s} from the game: '{s}'", .{ t, reason }) catch "Kicked";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "kick usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/kick <player> [reason ...]", def.usage());
}
