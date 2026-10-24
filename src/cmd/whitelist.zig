//! /whitelist — on|off|list|add|remove|reload.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "whitelist",
    .node = "asteorite.command.whitelist",
    .min_level = .admin,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .choice = &.{ "on", "off", "list", "add", "remove", "reload" } } },
            cmd.Slot{ .arg = .{ .word = {} }, .optional = true, .display = "<player>" },
        },
    },
    .usage_override = "/whitelist <on|off|list|add|remove|reload>",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [3][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n == 0 or n > 2) return cmd.usageError(&def, out);
    const sub = toks[0];
    if (std.mem.eql(u8, sub, "on")) {
        if (n != 1) return "/whitelist <on|off|list|add|remove|reload>";
        srv.wlSetEnabled(true);
        const msg = "Turned on the whitelist";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    }
    if (std.mem.eql(u8, sub, "off")) {
        if (n != 1) return "/whitelist <on|off|list|add|remove|reload>";
        srv.wlSetEnabled(false);
        const msg = "Turned off the whitelist";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    }
    if (std.mem.eql(u8, sub, "list")) {
        if (n != 1) return "/whitelist <on|off|list|add|remove|reload>";
        return srv.wlList(out);
    }
    if (std.mem.eql(u8, sub, "reload")) {
        if (n != 1) return "/whitelist <on|off|list|add|remove|reload>";
        srv.whitelistLoad();
        const msg = "Reloaded the whitelist";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    }
    if (std.mem.eql(u8, sub, "add")) {
        if (n != 2) return "Usage: /whitelist add <player>";
        const msg: []const u8 = if (srv.wlAdd(toks[1]))
            std.fmt.bufPrint(out, "Added {s} to the whitelist", .{toks[1]}) catch "Added to the whitelist"
        else
            std.fmt.bufPrint(out, "Could not add {s} to the whitelist", .{toks[1]}) catch "Could not add to the whitelist";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    }
    if (std.mem.eql(u8, sub, "remove")) {
        if (n != 2) return "Usage: /whitelist remove <player>";
        const msg: []const u8 = if (srv.wlRemove(toks[1]))
            std.fmt.bufPrint(out, "Removed {s} from the whitelist", .{toks[1]}) catch "Removed from the whitelist"
        else
            std.fmt.bufPrint(out, "Could not remove {s} from the whitelist", .{toks[1]}) catch "Could not remove from the whitelist";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    }
    return cmd.usageError(&def, out);
}

const std = @import("std");

test "whitelist usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/whitelist <on|off|list|add|remove|reload>", def.usage());
}
