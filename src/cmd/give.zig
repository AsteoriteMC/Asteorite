//! /give — spawn items into a player's inventory.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "give",
    .node = "asteorite.command.give",
    .min_level = .gamemaster,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .player = {} } },
            cmd.Slot{ .arg = .{ .word = {} }, .display = "<item>" },
            cmd.Slot{ .arg = .{ .int_range = .{} }, .optional = true, .display = "<amount>" },
            cmd.Slot{ .arg = .{ .int_range = .{} }, .optional = true, .display = "<data>" },
            cmd.Slot{ .arg = .{ .word = {} }, .optional = true, .display = "<dataTag>" },
        },
    },
    .usage_override = "/give <player> <item> [amount] [data] [dataTag]",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [6][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n < 2 or n > 5) return cmd.usageError(&def, out);
    var target: [cmd.max_name_len]u8 = undefined;
    const t = cmd.resolveTarget(srv, sender, toks[0], &target) orelse return cmd.unknown_player;
    // Item by name (canonical snake_case) or numeric id (vanilla warns).
    var numeric = false;
    const wire_id: u16 = blk: {
        if (srv.itemWireByName(toks[1])) |w| break :blk w;
        const v = std.fmt.parseInt(i64, toks[1], 10) catch return cmd.usageError(&def, out);
        if (v < 0 or v > 32767) return std.fmt.bufPrint(out, "There is no such item with ID {d}", .{v}) catch "No such item";
        numeric = true;
        break :blk @intCast(v);
    };
    if (n >= 5) {
        // No JSON-NBT parser yet: reject dataTags with the vanilla message.
        return std.fmt.bufPrint(out, "Data tag parsing failed: {s}", .{"Not a valid tag"}) catch "Data tag parsing failed";
    }
    // Wire ids map onto canonical ids; unassigned ranges (and air, which is
    // only legal as an empty slot) are rejected like vanilla.
    const id = srv.wireToId(wire_id) orelse {
        return std.fmt.bufPrint(out, "There is no such item with ID {d}", .{wire_id}) catch "No such item";
    };
    var count: i32 = 1;
    if (n >= 3) {
        const c = std.fmt.parseInt(i64, toks[2], 10) catch return cmd.usageError(&def, out);
        if (c < 1) {
            return std.fmt.bufPrint(out, "The number you have entered ({d}) is too small, it must be at least 1", .{c}) catch "Bad count";
        }
        if (c > 64) {
            return std.fmt.bufPrint(out, "The number you have entered ({d}) is too big, it must be at most 64", .{c}) catch "Bad count";
        }
        count = @intCast(c);
    }
    var damage: i16 = 0;
    if (n >= 4) {
        const d = std.fmt.parseInt(i64, toks[3], 10) catch return cmd.usageError(&def, out);
        if (d < -32768 or d > 32767) return cmd.usageError(&def, out);
        damage = @intCast(d);
    }
    if (numeric) {
        // Vanilla deprecation warning (separate message, then the success).
        srv.sendDirect(sender, std.fmt.bufPrint(out, "Warning: Using numeric IDs will not be supported in the future. Please use names, such as '{s}'", .{srv.itemName(id)}) catch "Warning: numeric IDs are deprecated");
    }
    const r = srv.giveItems(t, id, count, damage) orelse {
        return "That player cannot be found";
    };
    if (r.remaining > 0) srv.dropLeftover(t, id, r.remaining, damage);
    const iname = srv.itemName(id);
    const msg = std.fmt.bufPrint(out, "Given {s} * {d} to {s}", .{ iname, count, t }) catch "Given items";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "give usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/give <player> <item> [amount] [data] [dataTag]", def.usage());
}
