//! /clear — clear a player's inventory (optional item + data filter).

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "clear",
    .node = "asteorite.command.clear",
    .min_level = .gamemaster,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .player = {} } },
            cmd.Slot{ .arg = .{ .word = {} }, .optional = true, .display = "<item>" },
            cmd.Slot{ .arg = .{ .int_range = .{} }, .optional = true, .display = "<data>" },
        },
    },
    .usage_override = "/clear <player> [item] [data]",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [4][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n == 0 or n > 3) return cmd.usageError(&def, out);
    var target: [cmd.max_name_len]u8 = undefined;
    const t = cmd.resolveTarget(srv, sender, toks[0], &target) orelse return cmd.unknown_player;
    var wire: ?u16 = null;
    if (n >= 2) {
        if (srv.itemWireByName(toks[1])) |w| {
            wire = w;
        } else {
            const v = std.fmt.parseInt(i64, toks[1], 10) catch return cmd.usageError(&def, out);
            if (v < 0 or v > 32767) return std.fmt.bufPrint(out, "There is no such item with ID {d}", .{v}) catch "No such item";
            wire = @intCast(v);
        }
    }
    var data: i16 = -1;
    if (n >= 3) {
        const d = std.fmt.parseInt(i64, toks[2], 10) catch return cmd.usageError(&def, out);
        if (d < -1 or d > 32767) return cmd.usageError(&def, out);
        data = @intCast(d);
    }
    // Item given but unresolvable (e.g. air id 0): vanilla reports
    // clear.failure when an item arg is present but matches nothing.
    // clearInventory maps that to 0 removed; unknown names are usage.
    if (wire) |w| {
        if (srv.wireToId(w) == null and std.fmt.parseInt(i64, toks[1], 10) catch null == null) {
            return cmd.usageError(&def, out);
        }
    }
    const removed = srv.clearInventory(t, wire, data) orelse {
        return "That player cannot be found";
    };
    if (removed == 0) {
        return std.fmt.bufPrint(out, "Could not clear the inventory of {s}, no items to remove", .{t}) catch cmd.usageError(&def, out);
    }
    const msg = std.fmt.bufPrint(out, "Cleared the inventory of {s}, removing {d} items", .{ t, removed }) catch "Cleared inventory";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "clear usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/clear <player> [item] [data]", def.usage());
}
