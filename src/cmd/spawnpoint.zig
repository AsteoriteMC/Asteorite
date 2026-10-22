//! /spawnpoint — personal spawn (self or player, optionally at coords).

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "spawnpoint",
    .node = "asteorite.command.spawnpoint",
    .min_level = 2,
    .spec = &.{
        &[_]cmd.Slot{},
        &[_]cmd.Slot{cmd.Slot{ .arg = .{ .player = {} } }},
        &[_]cmd.Slot{ cmd.Slot{ .arg = .{ .player = {} } }, cmd.Slot{ .arg = .{ .int_range = .{} }, .display = "<x>" }, cmd.Slot{ .arg = .{ .int_range = .{} }, .display = "<y>" }, cmd.Slot{ .arg = .{ .int_range = .{} }, .display = "<z>" } },
    },
    .usage_override = "/spawnpoint OR /spawnpoint <player> OR /spawnpoint <player> <x> <y> <z>",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [5][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n != 0 and n != 1 and n != 4) return cmd.usageError(&def, out);
    // Target: named player, or the sender for the bare form.
    var target: [16]u8 = undefined;
    var t: []const u8 = "";
    if (n == 0) {
        if (sender == null) return cmd.usageError(&def, out);
        const self_name = cmd.senderName(sender, &target);
        if (self_name.len == 0) return cmd.usageError(&def, out);
        t = self_name;
    } else {
        t = srv.resolvePlayerName(sender, toks[0], &target) orelse {
            return "That player cannot be found";
        };
    }
    var x: i32 = 0;
    var y: i32 = 0;
    var z: i32 = 0;
    if (n == 4) {
        x = std.fmt.parseInt(i32, toks[1], 10) catch return cmd.usageError(&def, out);
        y = std.fmt.parseInt(i32, toks[2], 10) catch return cmd.usageError(&def, out);
        z = std.fmt.parseInt(i32, toks[3], 10) catch return cmd.usageError(&def, out);
        if (x < -30000000 or x > 30000000 or y < 0 or y > 256 or z < -30000000 or z > 30000000) return cmd.usageError(&def, out);
    } else {
        // No coords: the target's current position (floored).
        const pos = srv.playerPos(t) orelse return "That player cannot be found";
        x = @intFromFloat(@floor(pos[0]));
        y = @intFromFloat(@floor(pos[1]));
        z = @intFromFloat(@floor(pos[2]));
    }
    if (!srv.setSpawn(t, x, y, z)) return "That player cannot be found";
    const msg = std.fmt.bufPrint(out, "Set {s}'s spawn point to ({d}, {d}, {d})", .{ t, x, y, z }) catch "Set spawn point";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "spawnpoint usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/spawnpoint OR /spawnpoint <player> OR /spawnpoint <player> <x> <y> <z>", def.usage());
}
