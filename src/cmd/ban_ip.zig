//! /ban-ip — ban an address (or an online player's address).

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "ban-ip",
    .node = "asteorite.command.ban-ip",
    .min_level = .admin,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .word = {} }, .display = "<address|name>" },
            cmd.Slot{ .arg = .{ .rest = {} }, .optional = true, .display = "<reason ...>" },
        },
    },
    .usage_override = "/ban-ip <address|name> [reason ...]",
});

/// Vanilla IPv4 pattern (`af` class literal).
fn isIpv4(s: []const u8) bool {
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |p| {
        if (p.len == 0 or p.len > 3) return false;
        for (p) |c| if (!std.ascii.isDigit(c)) return false;
        const v = std.fmt.parseInt(u16, p, 10) catch return false;
        if (v > 255) return false;
        // No leading zeros unless the part is exactly "0" (vanilla regex
        // allows them; keep the regex semantics: ^([01]?\d\d?|2[0-4]\d|25[0-5])$).
        if (p.len > 1 and p[0] == '0') {
            // Vanilla regex DOES allow "01" ([01]?\d\d? matches). Keep parity:
        }
        parts += 1;
    }
    return parts == 4;
}

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [64][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n == 0) return cmd.usageError(&def, out);
    var rb: [1024]u8 = undefined;
    const reason = if (n > 1) cmd.Spec.joinRest(toks[0..n], 1, &rb) orelse return def.usage() else "";
    var ipb: [64]u8 = undefined;
    const ip: []const u8 = if (isIpv4(toks[0])) toks[0] else blk: {
        // Name form: only when that player is online (their live address).
        var resolved: [16]u8 = undefined;
        const t = srv.resolvePlayerName(sender, toks[0], &resolved) orelse {
            return "You have entered an invalid IP address or a player that is not online";
        };
        const live = srv.playerIp(t, &ipb) orelse {
            return "You have entered an invalid IP address or a player that is not online";
        };
        break :blk live;
    };
    srv.banIp(ip, reason);
    if (cmd.Spec.validPlayerNameChars(toks[0]) and !isIpv4(toks[0])) {
        const msg = std.fmt.bufPrint(out, "Banned IP address {s} belonging to {s}", .{ ip, toks[0] }) catch "Banned IP address";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    }
    const msg = std.fmt.bufPrint(out, "Banned IP address {s}", .{ip}) catch "Banned IP address";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "ban-ip usage + ipv4 validation" {
    try std.testing.expectEqualStrings("/ban-ip <address|name> [reason ...]", def.usage());
    try std.testing.expect(isIpv4("1.2.3.4"));
    try std.testing.expect(isIpv4("255.255.255.255"));
    try std.testing.expect(!isIpv4("1.2.3.256"));
    try std.testing.expect(!isIpv4("1.2.3"));
    try std.testing.expect(!isIpv4("Steve"));
    try std.testing.expect(!isIpv4("1.2.3.4.5"));
}
