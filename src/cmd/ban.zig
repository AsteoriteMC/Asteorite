//! /ban — ban a name (offline-safe) and kick if online.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "ban",
    .node = "asteorite.command.ban",
    .min_level = .admin,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .word = {} }, .display = "<name>" },
            cmd.Slot{ .arg = .{ .rest = {} }, .optional = true, .display = "<reason ...>" },
        },
    },
    .usage_override = "/ban <name> [reason ...]",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [64][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n == 0) return cmd.usageError(&def, out);
    // Offline-capable: vanilla resolves any name to a profile when the
    // server is offline, so any single token is bannable (online-mode
    // lookup failures surface as ban.failed, which needs mojang access).
    if (toks[0].len == 0 or toks[0].len > 16) return cmd.usageError(&def, out);
    var rb: [1024]u8 = undefined;
    const reason = if (n > 1) cmd.Spec.joinRest(toks[0..n], 1, &rb) orelse return def.usage() else "";
    // UUIDs bind at ban time: online-mode offline targets can't resolve
    // (same rule as /op) — use an IP ban for those, it needs no identity.
    if (!srv.banName(toks[0], reason)) return std.fmt.bufPrint(out, "Could not ban player {s}", .{toks[0]}) catch "Could not ban player";
    const msg = std.fmt.bufPrint(out, "Banned player {s}", .{toks[0]}) catch "Banned player";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "ban usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/ban <name> [reason ...]", def.usage());
}
