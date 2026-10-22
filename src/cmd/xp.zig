//! /xp — grant experience points or levels (`L` suffix = levels).

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "xp",
    .node = "asteorite.command.xp",
    .min_level = 2,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .word = {} }, .display = "<amount>" },
            cmd.Slot{ .arg = .{ .player = {} }, .optional = true },
        },
    },
    .usage_override = "/xp <amount> [player] OR /xp <amount>L [player]",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [3][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n == 0 or n > 2) return cmd.usageError(&def, out);
    // Target defaults to the sender (must be a player then).
    var target: [16]u8 = undefined;
    var t: []const u8 = "";
    if (n == 2) {
        t = srv.resolvePlayerName(sender, toks[1], &target) orelse {
            return "That player cannot be found";
        };
    } else {
        if (sender == null) return cmd.usageError(&def, out);
        const self_name = cmd.senderName(sender, &target);
        if (self_name.len == 0) return cmd.usageError(&def, out);
        t = self_name;
    }
    // Levels form: trailing l/L (either case).
    const raw = toks[0];
    const levels = raw.len > 0 and (raw[raw.len - 1] == 'l' or raw[raw.len - 1] == 'L');
    const num = if (levels) raw[0 .. raw.len - 1] else raw;
    const amount = std.fmt.parseInt(i32, num, 10) catch return cmd.usageError(&def, out);
    if (levels) {
        if (!srv.addLevels(t, amount)) return "That player cannot be found";
        if (amount >= 0) {
            const msg = std.fmt.bufPrint(out, "Given {d} levels to {s}", .{ amount, t }) catch "Given levels";
            srv.notifyAdmins(sender, &def, msg);
            return msg;
        }
        const msg = std.fmt.bufPrint(out, "Taken {d} levels from {s}", .{ -amount, t }) catch "Taken levels";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    }
    if (amount < 0) return "Cannot give player negative experience points";
    if (!srv.addXp(t, amount)) return "That player cannot be found";
    const msg = std.fmt.bufPrint(out, "Given {d} experience to {s}", .{ amount, t }) catch "Given experience";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "xp usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/xp <amount> [player] OR /xp <amount>L [player]", def.usage());
}
