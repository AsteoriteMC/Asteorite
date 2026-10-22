//! /effect — give/clear mob effects (ids 1..23, vanilla names).

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "effect",
    .node = "asteorite.command.effect",
    .min_level = 2,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .player = {} } },
            cmd.Slot{ .arg = .{ .word = {} }, .display = "<effect>" },
            cmd.Slot{ .arg = .{ .int_range = .{} }, .optional = true, .display = "<seconds>" },
            cmd.Slot{ .arg = .{ .int_range = .{} }, .optional = true, .display = "<amplifier>" },
        },
    },
    .usage_override = "/effect <player> <effect> [seconds] [amplifier]",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [5][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n < 2 or n > 4) return cmd.usageError(&def, out);
    var target: [16]u8 = undefined;
    const t = srv.resolvePlayerName(sender, toks[0], &target) orelse {
        return "That player cannot be found";
    };
    if (std.mem.eql(u8, toks[1], "clear")) {
        if (n != 2) return cmd.usageError(&def, out);
        const removed = srv.effectClear(t, null) orelse {
            return "That player cannot be found";
        };
        if (removed == 0) {
            return std.fmt.bufPrint(out, "Couldn't take any effects from {s} as they do not have any", .{t}) catch cmd.usageError(&def, out);
        }
        return std.fmt.bufPrint(out, "Took all effects from {s}", .{t}) catch "Took all effects";
    }
    // Effect id 1..23 (vanilla parseInt min 1; lookup miss = notFound).
    const id_raw = std.fmt.parseInt(i64, toks[1], 10) catch return cmd.usageError(&def, out);
    if (id_raw < 1) {
        return std.fmt.bufPrint(out, "The number you have entered ({d}) is too small, it must be at least 1", .{id_raw}) catch cmd.usageError(&def, out);
    }
    if (id_raw > 23 or srv.effectName(@intCast(id_raw)) == null) {
        return std.fmt.bufPrint(out, "There is no such mob effect with ID {d}", .{id_raw}) catch cmd.usageError(&def, out);
    }
    const id: u8 = @intCast(id_raw);
    var seconds: i64 = 30;
    if (n >= 3) {
        seconds = std.fmt.parseInt(i64, toks[2], 10) catch return cmd.usageError(&def, out);
        if (seconds < 0 or seconds > 1000000) {
            if (seconds < 0) {
                return std.fmt.bufPrint(out, "The number you have entered ({d}) is too small, it must be at least 0", .{seconds}) catch cmd.usageError(&def, out);
            }
            return std.fmt.bufPrint(out, "The number you have entered ({d}) is too big, it must be at most 1000000", .{seconds}) catch cmd.usageError(&def, out);
        }
    }
    var amp: i64 = 0;
    if (n >= 4) {
        amp = std.fmt.parseInt(i64, toks[3], 10) catch return cmd.usageError(&def, out);
        if (amp < 0 or amp > 255) {
            if (amp < 0) {
                return std.fmt.bufPrint(out, "The number you have entered ({d}) is too small, it must be at least 0", .{amp}) catch cmd.usageError(&def, out);
            }
            return std.fmt.bufPrint(out, "The number you have entered ({d}) is too big, it must be at most 255", .{amp}) catch cmd.usageError(&def, out);
        }
    }
    // seconds == 0 applies a zero-duration effect (vanilla prints Given;
    // the ticker expires it on the next tick).
    if (!srv.effectGive(t, id, @intCast(seconds), @intCast(amp))) {
        return "That player cannot be found";
    }
    const msg = std.fmt.bufPrint(out, "Given {s} (ID {d}) * {d} to {s} for {d} seconds", .{ srv.effectName(id).?, id, amp, t, seconds }) catch "Given effect";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "effect usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/effect <player> <effect> [seconds] [amplifier]", def.usage());
}
