//! /gamemode — switch survival/creative/adventure (self or another player).

const cmd = @import("mod.zig");
const rules = @import("../game/rules.zig");

pub const def = cmd.define(.{
    .name = "gamemode",
    .node = "asteorite.command.gamemode",
    .min_level = .gamemaster,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .word = {} }, .display = "<mode>" },
            cmd.Slot{ .arg = .{ .player = {} }, .optional = true },
        },
    },
    .usage_override = "/gamemode <mode> [player]",
});

/// Vanilla mode parse: full names + single letters (case-insensitive),
/// else the wire value. Bounds track the enum (no hardcoded max).
/// Single home for the spelling: rules.GameMode.parse.
fn parseMode(s: []const u8) ?rules.GameMode {
    return rules.GameMode.parse(s);
}

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [3][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n == 0 or n > 2) return cmd.usageError(&def, out);
    const mode = parseMode(toks[0]) orelse return cmd.usageError(&def, out);
    const target: []const u8 = if (n == 2) blk: {
        var tb: [cmd.max_name_len]u8 = undefined;
        break :blk cmd.resolveTarget(srv, sender, toks[1], &tb) orelse return cmd.unknown_player;
    } else blk: {
        if (sender == null) return cmd.usageError(&def, out);
        var who: [cmd.max_name_len]u8 = undefined;
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
    try std.testing.expectEqual(@as(?rules.GameMode, .survival), parseMode("survival"));
    try std.testing.expectEqual(@as(?rules.GameMode, .survival), parseMode("S"));
    try std.testing.expectEqual(@as(?rules.GameMode, .creative), parseMode("c"));
    try std.testing.expectEqual(@as(?rules.GameMode, .adventure), parseMode("Adventure"));
    try std.testing.expectEqual(@as(?rules.GameMode, .adventure), parseMode("2"));
    try std.testing.expect(parseMode("7") == null);
    try std.testing.expect(parseMode("nope") == null);
}
