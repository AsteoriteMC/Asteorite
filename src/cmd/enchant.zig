//! /enchant — add an enchantment to the target's held item.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "enchant",
    .node = "asteorite.command.enchant",
    .min_level = .gamemaster,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .player = {} } },
            cmd.Slot{ .arg = .{ .int_range = .{} }, .display = "<enchantment ID>" },
            cmd.Slot{ .arg = .{ .int_range = .{} }, .optional = true, .display = "<level>" },
        },
    },
    .usage_override = "/enchant <player> <enchantment ID> [level]",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [4][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n < 2 or n > 3) return cmd.usageError(&def, out);
    var target: [cmd.max_name_len]u8 = undefined;
    const t = cmd.resolveTarget(srv, sender, toks[0], &target) orelse return cmd.unknown_player;
    const eid_raw = std.fmt.parseInt(i64, toks[1], 10) catch return cmd.usageError(&def, out);
    if (eid_raw < 0 or eid_raw > 255) return cmd.usageError(&def, out);
    const eid: u8 = @intCast(eid_raw);
    if (srv.enchantById(eid) == null) {
        return std.fmt.bufPrint(out, "There is no such enchantment with ID {d}", .{eid}) catch cmd.usageError(&def, out);
    }
    var level: i64 = 1;
    if (n == 3) {
        level = std.fmt.parseInt(i64, toks[2], 10) catch return cmd.usageError(&def, out);
    }
    const max = srv.enchantMax(eid);
    if (level < 1 or level > max) {
        if (level < 1) {
            return std.fmt.bufPrint(out, "The number you have entered ({d}) is too small, it must be at least 1", .{level}) catch cmd.usageError(&def, out);
        }
        return std.fmt.bufPrint(out, "The number you have entered ({d}) is too big, it must be at most {d}", .{ level, max }) catch cmd.usageError(&def, out);
    }
    switch (srv.enchantHeld(t, eid, @intCast(level)) orelse {
        return "That player cannot be found";
    }) {
        .no_item => return "The target doesn't hold an item",
        .cant_enchant => return "The selected enchantment can't be added to the target item",
        .no_room => return "The selected enchantment can't be added to the target item",
        .ok => {},
    }
    const msg = "Enchanting succeeded";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "enchant usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/enchant <player> <enchantment ID> [level]", def.usage());
}
