//! /kill — kill yourself (or the target), even in creative.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "kill",
    .node = "asteorite.command.kill",
    .min_level = .all,
    .spec = &.{&[_]cmd.Slot{}},
    .usage_override = "/kill",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [1][]const u8 = undefined;
    if (cmd.Spec.tokenize(args, &toks) > 0) return cmd.usageError(&def, out);
    // Vanilla /kill targets the sender (must be a player).
    if (sender == null) return cmd.usageError(&def, out);
    var who: [16]u8 = undefined;
    const name = cmd.senderName(sender, &who);
    if (name.len == 0) return cmd.usageError(&def, out);
    // Offline check without killing: resolve first for the error text.
    var probe: [16]u8 = undefined;
    _ = srv.resolvePlayerName(sender, name, &probe) orelse {
        return "That player cannot be found";
    };
    if (!srv.killPlayer(name)) return "That player cannot be found";
    return "Ouch! That looked like it hurt";
}

const std = @import("std");

test "kill usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/kill", def.usage());
}
