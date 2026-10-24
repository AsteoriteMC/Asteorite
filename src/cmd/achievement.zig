//! /achievement — award stats/achievements (`*` = all achievements).

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "achievement",
    .node = "asteorite.command.achievement",
    .min_level = .gamemaster,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .literal = "give" } },
            cmd.Slot{ .arg = .{ .word = {} }, .display = "<stat_name>" },
            cmd.Slot{ .arg = .{ .player = {} }, .optional = true },
        },
    },
    .usage_override = "/achievement give <stat_name> [player]",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [4][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n < 2 or n > 3) return cmd.usageError(&def, out);
    if (!std.mem.eql(u8, toks[0], "give")) return cmd.usageError(&def, out);
    if (!srv.validStatName(toks[1])) {
        return std.fmt.bufPrint(out, "Unknown achievement or statistic '{s}'", .{toks[1]}) catch "Unknown achievement";
    }
    var target: [16]u8 = undefined;
    var t: []const u8 = "";
    if (n == 3) {
        t = srv.resolvePlayerName(sender, toks[2], &target) orelse {
            return "That player cannot be found";
        };
    } else {
        if (sender == null) return cmd.usageError(&def, out);
        const self_name = cmd.senderName(sender, &target);
        if (self_name.len == 0) return cmd.usageError(&def, out);
        t = self_name;
    }
    if (std.mem.eql(u8, toks[1], "*")) {
        if (!srv.awardAll(t)) return "That player cannot be found";
        const msg = std.fmt.bufPrint(out, "Successfully given all achievements to {s}", .{t}) catch "Given all achievements";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    }
    const ok = srv.awardStat(t, toks[1]) orelse {
        return std.fmt.bufPrint(out, "Unknown achievement or statistic '{s}'", .{toks[1]}) catch "Unknown achievement";
    };
    if (!ok) return "That player cannot be found";
    if (srv.isAchievement(toks[1])) {
        const title = srv.achievementTitle(toks[1]) orelse toks[1];
        const msg = std.fmt.bufPrint(out, "Successfully given {s} the stat {s}", .{ t, title }) catch "Given achievement";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    }
    const msg = std.fmt.bufPrint(out, "Successfully given {s} the stat {s}", .{ t, toks[1] }) catch "Given stat";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "achievement usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/achievement give <stat_name> [player]", def.usage());
}
