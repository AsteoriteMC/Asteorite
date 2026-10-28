//! /op — grant a player level-4 operator.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "op",
    .node = "asteorite.command.op",
    .min_level = .admin,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .word = {} }, .display = "<player>" },
        },
    },
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [2][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n != 1) return cmd.usageError(&def, out);
    // Offline parity: any single token resolves (online-mode lookup
    // failures surface as unknown_player — UUIDs are bound at grant time,
    // so an offline target in online mode cannot be opped).
    if (toks[0].len == 0 or toks[0].len > 16) return cmd.usageError(&def, out);
    if (!srv.grantOp(toks[0])) return cmd.unknown_player;
    const msg = std.fmt.bufPrint(out, "Opped {s}", .{toks[0]}) catch "Opped";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "op usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/op <player>", def.usage());
}
