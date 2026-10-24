//! /perm — inspect and edit the permission matrix.
//!
//! The matrix itself lives in sim/permissions.zig; this file only parses
//! the subcommand and formats replies. Node charset checks go through the
//! backend so future versions can tighten the rules without touching this.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "perm",
    .node = "asteorite.command.perm",
    .min_level = .owner,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .choice = &.{ "grant", "deny", "clear", "show", "reload" } } },
            cmd.Slot{ .arg = .{ .player = {} }, .optional = true },
            cmd.Slot{ .arg = .{ .word = {} }, .optional = true, .display = "<node>" },
        },
    },
    .usage_override = "/perm <grant|deny|clear|show|reload> [player] [node]",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    _ = sender;
    var toks: [4][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n == 0 or n > 3) return cmd.usageError(&def, out);
    const sub = toks[0];
    if (std.mem.eql(u8, sub, "reload")) {
        if (n != 1) return cmd.usageError(&def, out);
        srv.permReload();
        return "Permissions reloaded.";
    }
    const is_grant = std.mem.eql(u8, sub, "grant");
    const is_deny = std.mem.eql(u8, sub, "deny");
    const is_clear = std.mem.eql(u8, sub, "clear");
    const is_show = std.mem.eql(u8, sub, "show");
    if (!is_grant and !is_deny and !is_clear and !is_show) return cmd.usageError(&def, out);
    if (n < 2) return cmd.usageError(&def, out);
    const player = toks[1];
    if (!srv.validName(player)) return cmd.usageError(&def, out);
    if (is_show) {
        if (n != 2) return cmd.usageError(&def, out);
        return srv.permShow(player, out) orelse "Show failed.";
    }
    if (is_clear) {
        if (n == 2) {
            srv.permClear(player, null);
            return "Nodes cleared.";
        }
        if (n != 3) return cmd.usageError(&def, out);
        srv.permClear(player, toks[2]);
        return "Cleared.";
    }
    if (n != 3) return cmd.usageError(&def, out);
    if (!srv.validNode(toks[2])) {
        return "Bad node. Use [a-z0-9_.-], optional trailing .*";
    }
    if (is_grant) {
        srv.permGrant(player, toks[2]);
        return "Granted.";
    }
    srv.permDeny(player, toks[2]);
    return "Denied.";
}

const std = @import("std");

test "perm usage string" {
    try std.testing.expectEqualStrings("/perm <grant|deny|clear|show|reload> [player] [node]", def.usage());
}
