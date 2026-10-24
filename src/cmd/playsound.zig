//! /playsound — play a named sound to one player.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "playsound",
    .node = "asteorite.command.playsound",
    .min_level = .gamemaster,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .word = {} }, .display = "<sound>" },
            cmd.Slot{ .arg = .{ .player = {} } },
            cmd.Slot{ .arg = .{ .coord = {} }, .optional = true, .display = "<x>" },
            cmd.Slot{ .arg = .{ .coord = {} }, .optional = true, .display = "<y>" },
            cmd.Slot{ .arg = .{ .coord = {} }, .optional = true, .display = "<z>" },
            cmd.Slot{ .arg = .{ .float_range = .{} }, .optional = true, .display = "<volume>" },
            cmd.Slot{ .arg = .{ .float_range = .{} }, .optional = true, .display = "<pitch>" },
            cmd.Slot{ .arg = .{ .float_range = .{} }, .optional = true, .display = "<minimumVolume>" },
        },
    },
    .usage_override = "/playsound <sound> <player> [x] [y] [z] [volume] [pitch] [minimumVolume]",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [9][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n < 2 or n > 8) return cmd.usageError(&def, out);
    var target: [16]u8 = undefined;
    const t = srv.resolvePlayerName(sender, toks[1], &target) orelse {
        return "That player cannot be found";
    };
    // Defaults: the target's block position, volume/pitch 1, minVolume 0.
    // x/y/z are sequential parseCoordinate slots (partial allowed, `~`
    // relative — vanilla advances one index per present arg).
    const tp = srv.playerPos(t) orelse {
        return "That player cannot be found";
    };
    var x: f64 = @floor(tp[0]);
    var y: f64 = @floor(tp[1]);
    var z: f64 = @floor(tp[2]);
    var volume: f64 = 1.0;
    var pitch: f64 = 1.0;
    var minvol: f64 = 0.0;
    var vi: usize = 2;
    if (n > vi) {
        x = cmd.Spec.parseCoord(toks[vi], tp[0]) orelse return cmd.usageError(&def, out);
        vi += 1;
    }
    if (n > vi and vi < 5) {
        // y uses parseCoordinate too (vanilla passes min=max=0 = unbounded).
        y = cmd.Spec.parseCoord(toks[vi], tp[1]) orelse return cmd.usageError(&def, out);
        vi += 1;
    }
    if (n > vi and vi < 5) {
        z = cmd.Spec.parseCoord(toks[vi], tp[2]) orelse return cmd.usageError(&def, out);
        vi += 1;
    }
    if (n > vi) {
        volume = std.fmt.parseFloat(f64, toks[vi]) catch return cmd.usageError(&def, out);
        if (!std.math.isFinite(volume) or volume < 0 or volume > 3.4028234663852886e38) return cmd.usageError(&def, out);
        vi += 1;
    }
    if (n > vi) {
        pitch = std.fmt.parseFloat(f64, toks[vi]) catch return cmd.usageError(&def, out);
        if (!std.math.isFinite(pitch) or pitch < 0 or pitch > 2) return cmd.usageError(&def, out);
        vi += 1;
    }
    if (n > vi) {
        minvol = std.fmt.parseFloat(f64, toks[vi]) catch return cmd.usageError(&def, out);
        if (!std.math.isFinite(minvol) or minvol < 0 or minvol > 1) return cmd.usageError(&def, out);
    }
    switch (srv.playSoundTo(t, toks[0], x, y, z, @floatCast(volume), @floatCast(pitch), @floatCast(minvol))) {
        .offline => return "That player cannot be found",
        .too_far => return std.fmt.bufPrint(out, "Player {s} is too far away to hear the sound", .{t}) catch "Too far",
        .heard => {},
    }
    const msg = std.fmt.bufPrint(out, "Played sound '{s}' to {s}", .{ toks[0], t }) catch "Played sound";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "playsound usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/playsound <sound> <player> [x] [y] [z] [volume] [pitch] [minimumVolume]", def.usage());
}
