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
    // failures surface as op.failed, which needs mojang access).
    if (toks[0].len == 0 or toks[0].len > 16) return cmd.usageError(&def, out);
    srv.grantOp(toks[0]);
    const msg = std.fmt.bufPrint(out, "Opped {s}", .{toks[0]}) catch "Opped";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "op usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/op <player>", def.usage());
}
