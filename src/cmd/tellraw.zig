//! /tellraw — send a raw JSON message to one player.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "tellraw",
    .node = "asteorite.command.tellraw",
    .min_level = .gamemaster,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .player = {} } },
            cmd.Slot{ .arg = .{ .rest = {} }, .display = "<raw json message>" },
        },
    },
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [64][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n < 2) return cmd.usageError(&def, out);
    var target: [cmd.max_name_len]u8 = undefined;
    const t = cmd.resolveTarget(srv, sender, toks[0], &target) orelse return cmd.unknown_player;
    var jb: [2048]u8 = undefined;
    const json = cmd.Spec.joinRest(toks[0..n], 1, &jb) orelse return cmd.usageError(&def, out);
    // Validate: must parse as JSON (vanilla rejects with jsonException).
    srv.validateJson(json) catch {
        return std.fmt.bufPrint(out, "Invalid json: {s}", .{json}) catch "Invalid json";
    };
    if (!srv.sendJsonPlayer(t, json)) return "That player cannot be found";
    return "";
}

const std = @import("std");

test "tellraw usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/tellraw <player> <raw json message>", def.usage());
}
