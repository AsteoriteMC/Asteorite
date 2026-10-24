//! /weather — clear/rain/thunder with optional duration.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "weather",
    .node = "asteorite.command.weather",
    .min_level = .gamemaster,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .choice = &.{ "clear", "rain", "thunder" } } },
            cmd.Slot{ .arg = .{ .int_range = .{} }, .optional = true, .display = "<duration in seconds>" },
        },
    },
    .usage_override = "/weather <clear|rain|thunder> [duration in seconds]",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [3][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n == 0 or n > 2) return cmd.usageError(&def, out);
    const clear = std.mem.eql(u8, toks[0], "clear");
    const rain = std.mem.eql(u8, toks[0], "rain");
    const thunder = std.mem.eql(u8, toks[0], "thunder");
    if (!clear and !rain and !thunder) return cmd.usageError(&def, out);
    // Default 300..899s, explicit 1..1000000s (vanilla `* 20` ticks).
    var seconds: i64 = 300 + @mod(srv.randInt(), 600);
    if (n == 2) {
        const s = std.fmt.parseInt(i64, toks[1], 10) catch return cmd.usageError(&def, out);
        if (s < 1 or s > 1000000) {
            if (s < 1) {
                return std.fmt.bufPrint(out, "The number you have entered ({d}) is too small, it must be at least 1", .{s}) catch cmd.usageError(&def, out);
            }
            return std.fmt.bufPrint(out, "The number you have entered ({d}) is too big, it must be at most 1000000", .{s}) catch cmd.usageError(&def, out);
        }
        seconds = s;
    }
    const ticks: u32 = @intCast(seconds * 20);
    const msg: []const u8 = if (clear) blk: {
        srv.setWeather(.clear, ticks);
        break :blk "Changing to clear weather";
    } else if (rain) blk: {
        srv.setWeather(.rain, ticks);
        break :blk "Changing to rainy weather";
    } else blk: {
        srv.setWeather(.thunder, ticks);
        break :blk "Changing to rain and thunder";
    };
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "weather usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/weather <clear|rain|thunder> [duration in seconds]", def.usage());
}
