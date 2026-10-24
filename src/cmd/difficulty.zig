//! /difficulty — set world difficulty peaceful..hard.

const cmd = @import("mod.zig");
const rules = @import("../game/rules.zig");

pub const def = cmd.define(.{
    .name = "difficulty",
    .node = "asteorite.command.difficulty",
    .min_level = .gamemaster,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .word = {} }, .display = "<new difficulty>" },
        },
    },
    .usage_override = "/difficulty <new difficulty>",
});

fn parseDifficulty(s: []const u8) ?rules.Difficulty {
    if (std.ascii.eqlIgnoreCase(s, "peaceful") or std.ascii.eqlIgnoreCase(s, "p")) return .peaceful;
    if (std.ascii.eqlIgnoreCase(s, "easy") or std.ascii.eqlIgnoreCase(s, "e")) return .easy;
    if (std.ascii.eqlIgnoreCase(s, "normal") or std.ascii.eqlIgnoreCase(s, "n")) return .normal;
    if (std.ascii.eqlIgnoreCase(s, "hard") or std.ascii.eqlIgnoreCase(s, "h")) return .hard;
    const v = std.fmt.parseInt(i64, s, 10) catch return null;
    if (v < 0 or v >= std.enums.values(rules.Difficulty).len) return null;
    return @enumFromInt(v);
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
    try std.testing.expectEqual(@as(?rules.Difficulty, .peaceful), parseDifficulty("peaceful"));
    try std.testing.expectEqual(@as(?rules.Difficulty, .peaceful), parseDifficulty("P"));
    try std.testing.expectEqual(@as(?rules.Difficulty, .hard), parseDifficulty("hard"));
    try std.testing.expectEqual(@as(?rules.Difficulty, .hard), parseDifficulty("h"));
    try std.testing.expectEqual(@as(?rules.Difficulty, .normal), parseDifficulty("2"));
    try std.testing.expect(parseDifficulty("9") == null);
    try std.testing.expect(parseDifficulty("nope") == null);
}
