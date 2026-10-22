//! /difficulty — set world difficulty 0-3 / peaceful..hard.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "difficulty",
    .node = "asteorite.command.difficulty",
    .min_level = 2,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .word = {} }, .display = "<new difficulty>" },
        },
    },
    .usage_override = "/difficulty <new difficulty>",
});

fn parseDifficulty(s: []const u8) ?u8 {
    if (std.ascii.eqlIgnoreCase(s, "peaceful") or std.ascii.eqlIgnoreCase(s, "p")) return 0;
    if (std.ascii.eqlIgnoreCase(s, "easy") or std.ascii.eqlIgnoreCase(s, "e")) return 1;
    if (std.ascii.eqlIgnoreCase(s, "normal") or std.ascii.eqlIgnoreCase(s, "n")) return 2;
    if (std.ascii.eqlIgnoreCase(s, "hard") or std.ascii.eqlIgnoreCase(s, "h")) return 3;
    const v = std.fmt.parseInt(i64, s, 10) catch return null;
    if (v < 0 or v > 3) return null;
    return @intCast(v);
}

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [2][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n != 1) return cmd.usageError(&def, out);
    const d = parseDifficulty(toks[0]) orelse return cmd.usageError(&def, out);
    srv.setDifficulty(d);
    const msg = std.fmt.bufPrint(out, "Set game difficulty to {s}", .{srv.difficultyName(d)}) catch "Set difficulty";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "difficulty usage + parse" {
    try std.testing.expectEqualStrings("/difficulty <new difficulty>", def.usage());
    try std.testing.expectEqual(@as(?u8, 0), parseDifficulty("peaceful"));
    try std.testing.expectEqual(@as(?u8, 0), parseDifficulty("P"));
    try std.testing.expectEqual(@as(?u8, 3), parseDifficulty("hard"));
    try std.testing.expectEqual(@as(?u8, 3), parseDifficulty("h"));
    try std.testing.expectEqual(@as(?u8, 2), parseDifficulty("2"));
    try std.testing.expect(parseDifficulty("9") == null);
    try std.testing.expect(parseDifficulty("nope") == null);
}
