//! /defaultgamemode — default for first-time logins.

const cmd = @import("mod.zig");
const rules = @import("../game/rules.zig");

pub const def = cmd.define(.{
    .name = "defaultgamemode",
    .node = "asteorite.command.defaultgamemode",
    .min_level = .gamemaster,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .word = {} }, .display = "<mode>" },
        },
    },
    .usage_override = "/defaultgamemode <mode>",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [2][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n != 1) return cmd.usageError(&def, out);
    const mode: rules.GameMode = blk: {
        const s = toks[0];
        if (std.ascii.eqlIgnoreCase(s, "survival") or std.ascii.eqlIgnoreCase(s, "s")) break :blk .survival;
        if (std.ascii.eqlIgnoreCase(s, "creative") or std.ascii.eqlIgnoreCase(s, "c")) break :blk .creative;
        if (std.ascii.eqlIgnoreCase(s, "adventure") or std.ascii.eqlIgnoreCase(s, "a")) break :blk .adventure;
        const v = std.fmt.parseInt(i64, s, 10) catch return cmd.usageError(&def, out);
        if (v < 0 or v >= std.enums.values(rules.GameMode).len) return cmd.usageError(&def, out);
        break :blk @enumFromInt(v);
    };
    srv.setDefaultGamemode(mode);
    const msg = std.fmt.bufPrint(out, "The world's default game mode is now {s}", .{srv.gamemodeName(mode)}) catch "Set default game mode";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "defaultgamemode usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/defaultgamemode <mode>", def.usage());
}
