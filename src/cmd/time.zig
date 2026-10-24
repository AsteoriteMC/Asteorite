//! /time — world clock control (set/add, day/night keywords).

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "time",
    .node = "asteorite.command.time",
    .min_level = .gamemaster,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .choice = &.{ "set", "add" } } },
            cmd.Slot{ .arg = .{ .word = {} }, .display = "<value>" },
        },
    },
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [3][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n != 2) return cmd.usageError(&def, out);
    const is_set = std.mem.eql(u8, toks[0], "set");
    const is_add = std.mem.eql(u8, toks[0], "add");
    if (!is_set and !is_add) return cmd.usageError(&def, out);
    // day/night keywords, else a plain integer (vanilla parseInt, unbounded).
    const delta: ?i64 = if (std.mem.eql(u8, toks[1], "day")) 1000 else if (std.mem.eql(u8, toks[1], "night")) 13000 else std.fmt.parseInt(i64, toks[1], 10) catch null;
    const d = delta orelse {
        return std.fmt.bufPrint(out, "'{s}' is not a valid number", .{toks[1]}) catch cmd.usageError(&def, out);
    };
    if (is_set) {
        const v = @mod(d, 24000);
        srv.setTimeOfDay(v);
        const msg = std.fmt.bufPrint(out, "Set the time to {d}", .{v}) catch "Set the time";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    }
    const now = srv.getTimeOfDay();
    const v = @mod(now + d, 24000);
    srv.setTimeOfDay(v);
    const msg = std.fmt.bufPrint(out, "Added {d} to the time", .{d}) catch "Added time";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "time usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/time <set|add> <value>", def.usage());
}
