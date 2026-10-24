//! /setworldspawn — world spawn (here or at coords).

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "setworldspawn",
    .node = "asteorite.command.setworldspawn",
    .min_level = .gamemaster,
    .spec = &.{
        &[_]cmd.Slot{},
        &[_]cmd.Slot{ cmd.Slot{ .arg = .{ .int_range = .{} }, .display = "<x>" }, cmd.Slot{ .arg = .{ .int_range = .{} }, .display = "<y>" }, cmd.Slot{ .arg = .{ .int_range = .{} }, .display = "<z>" } },
    },
    .usage_override = "/setworldspawn OR /setworldspawn <x> <y> <z>",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [4][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n != 0 and n != 3) return cmd.usageError(&def, out);
    var x: i32 = 0;
    var y: i32 = 0;
    var z: i32 = 0;
    if (n == 3) {
        x = std.fmt.parseInt(i32, toks[0], 10) catch return cmd.usageError(&def, out);
        y = std.fmt.parseInt(i32, toks[1], 10) catch return cmd.usageError(&def, out);
        z = std.fmt.parseInt(i32, toks[2], 10) catch return cmd.usageError(&def, out);
        if (x < -30000000 or x > 30000000 or y < 0 or y > 256 or z < -30000000 or z > 30000000) return cmd.usageError(&def, out);
    } else {
        // Bare form: the sender's position (console must give coords).
        const pos = srv.senderPos(sender) orelse return cmd.usageError(&def, out);
        x = @intFromFloat(@floor(pos[0]));
        y = @intFromFloat(@floor(pos[1]));
        z = @intFromFloat(@floor(pos[2]));
    }
    srv.setWorldSpawn(x, y, z);
    const msg = std.fmt.bufPrint(out, "Set the world spawn point to ({d}, {d}, {d})", .{ x, y, z }) catch "Set world spawn";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "setworldspawn usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/setworldspawn OR /setworldspawn <x> <y> <z>", def.usage());
}
