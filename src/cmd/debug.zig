//! /debug — start/stop profiling (elapsed wall time + tick count).

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "debug",
    .node = "asteorite.command.debug",
    .min_level = 3,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .choice = &.{ "start", "stop" } } },
        },
    },
    .usage_override = "/debug <start|stop>",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [2][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n != 1) return cmd.usageError(&def, out);
    if (std.mem.eql(u8, toks[0], "start")) {
        srv.debugStart(srv.nowMs());
        const msg = "Started debug profiling";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    }
    if (std.mem.eql(u8, toks[0], "stop")) {
        const r = srv.debugStop(srv.nowMs()) orelse {
            return "Can't stop profiling when we haven't started yet!";
        };
        const msg = std.fmt.bufPrint(out, "Stopped debug profiling after {d:.2} seconds ({d} ticks)", .{ r.secs, r.ticks }) catch "Stopped debug profiling";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    }
    return cmd.usageError(&def, out);
}

const std = @import("std");

test "debug usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/debug <start|stop>", def.usage());
}
