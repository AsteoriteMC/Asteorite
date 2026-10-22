//! /gamerule — query or set one of the nine world rules.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "gamerule",
    .node = "asteorite.command.gamerule",
    .min_level = 2,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .word = {} }, .display = "<rule name>" },
        },
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .word = {} }, .display = "<rule name>" },
            cmd.Slot{ .arg = .{ .word = {} }, .display = "<value>" },
        },
    },
    .usage_override = "/gamerule <rule name> <value> OR /gamerule <rule name>",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [3][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n == 0 or n > 2) return cmd.usageError(&def, out);
    if (n == 1) {
        if (srv.gameruleGet(toks[0])) |v| {
            return std.fmt.bufPrint(out, "{s} = {s}", .{ toks[0], if (v) "true" else "false" }) catch cmd.usageError(&def, out);
        }
        return std.fmt.bufPrint(out, "No game rule called '{s}' is available", .{toks[0]}) catch cmd.usageError(&def, out);
    }
    const v: bool = if (std.mem.eql(u8, toks[1], "true"))
        true
    else if (std.mem.eql(u8, toks[1], "false"))
        false
    else {
        return std.fmt.bufPrint(out, "'{s}' is not true or false", .{toks[1]}) catch cmd.usageError(&def, out);
    };
    if (!srv.gameruleSet(toks[0], v)) {
        return std.fmt.bufPrint(out, "No game rule called '{s}' is available", .{toks[0]}) catch cmd.usageError(&def, out);
    }
    const msg = "Game rule has been updated";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "gamerule usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/gamerule <rule name> <value> OR /gamerule <rule name>", def.usage());
}
