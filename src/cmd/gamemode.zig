//! /gamemode — switch survival/creative/adventure (self or another player).

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "gamemode",
    .node = "asteorite.command.gamemode",
    .min_level = 2,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .word = {} }, .display = "<mode>" },
            cmd.Slot{ .arg = .{ .player = {} }, .optional = true },
        },
    },
    .usage_override = "/gamemode <mode> [player]",
});

/// Vanilla mode parse: full names + single letters (case-insensitive),
/// else integer 0..2 (parseIntBounded with min 0, max values-2).
fn parseMode(s: []const u8) ?u8 {
    if (std.ascii.eqlIgnoreCase(s, "survival") or std.ascii.eqlIgnoreCase(s, "s")) return 0;
    if (std.ascii.eqlIgnoreCase(s, "creative") or std.ascii.eqlIgnoreCase(s, "c")) return 1;
    if (std.ascii.eqlIgnoreCase(s, "adventure") or std.ascii.eqlIgnoreCase(s, "a")) return 2;
    const v = std.fmt.parseInt(i64, s, 10) catch return null;
    if (v < 0 or v > 2) return null;
    return @intCast(v);
}

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [3][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n == 0 or n > 2) return cmd.usageError(&def, out);
    const mode = parseMode(toks[0]) orelse return cmd.usageError(&def, out);
    const target: []const u8 = if (n == 2) blk: {
        var tb: [16]u8 = undefined;
        break :blk srv.resolvePlayerName(sender, toks[1], &tb) orelse {
            return "That player cannot be found";
        };
    } else blk: {
        if (sender == null) return cmd.usageError(&def, out);
        var who: [16]u8 = undefined;
        const self_name = cmd.senderName(sender, &who);
        if (self_name.len == 0) return cmd.usageError(&def, out);
        break :blk self_name;
    };
    if (!srv.applyGamemode(target, mode)) return "That player cannot be found";
    const gname = srv.gamemodeName(mode);
    if (n == 2) {
        const msg = std.fmt.bufPrint(out, "Set {s}'s game mode to {s}", .{ target, gname }) catch "Set game mode";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    }
    return std.fmt.bufPrint(out, "Set own game mode to {s}", .{gname}) catch "Set game mode";
}

const std = @import("std");

test "gamemode usage + parse" {
    try std.testing.expectEqualStrings("/gamemode <mode> [player]", def.usage());
    try std.testing.expectEqual(@as(?u8, 0), parseMode("survival"));
    try std.testing.expectEqual(@as(?u8, 0), parseMode("S"));
    try std.testing.expectEqual(@as(?u8, 1), parseMode("c"));
    try std.testing.expectEqual(@as(?u8, 2), parseMode("Adventure"));
    try std.testing.expectEqual(@as(?u8, 2), parseMode("2"));
    try std.testing.expect(parseMode("7") == null);
    try std.testing.expect(parseMode("nope") == null);
}
