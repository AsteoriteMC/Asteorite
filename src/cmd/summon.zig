//! /summon — spawn a living entity at coordinates (or the sender).

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "summon",
    .node = "asteorite.command.summon",
    .min_level = .gamemaster,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .word = {} }, .display = "<EntityName>" },
            cmd.Slot{ .arg = .{ .coord = {} }, .optional = true, .display = "<x>" },
            cmd.Slot{ .arg = .{ .coord = {} }, .optional = true, .display = "<y>" },
            cmd.Slot{ .arg = .{ .coord = {} }, .optional = true, .display = "<z>" },
            cmd.Slot{ .arg = .{ .word = {} }, .optional = true, .display = "<dataTag>" },
        },
    },
    .usage_override = "/summon <EntityName> [x] [y] [z] [dataTag]",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [6][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n == 0 or n > 5 or n == 2 or n == 3) return cmd.usageError(&def, out);
    const mob = srv.mobByName(toks[0]) orelse {
        // Vanilla broadcasts the failure to ops too (notifyAdmins path).
        const msg = "Unable to summon object";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    };
    if (n == 5) {
        // No JSON-NBT parser yet: reject dataTags with the vanilla message.
        const msg = std.fmt.bufPrint(out, "Data tag parsing failed: {s}", .{"Not a valid tag"}) catch "Data tag parsing failed";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    }
    var x: f64 = 0;
    var y: f64 = 0;
    var z: f64 = 0;
    if (n == 4) {
        // Absolute doubles (vanilla parseCoordinate against the sender).
        const base = srv.senderPos(sender) orelse return cmd.usageError(&def, out);
        x = cmd.Spec.parseCoord(toks[1], base[0]) orelse return cmd.usageError(&def, out);
        y = cmd.Spec.parseCoord(toks[2], base[1]) orelse return cmd.usageError(&def, out);
        z = cmd.Spec.parseCoord(toks[3], base[2]) orelse return cmd.usageError(&def, out);
    } else {
        const pos = srv.senderPos(sender) orelse return cmd.usageError(&def, out);
        x = pos[0];
        y = pos[1];
        z = pos[2];
    }
    if (y < 0 or y > 256) {
        const msg = "Cannot summon the object out of the world";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    }
    if (!srv.summonMob(mob.type_id, x, y, z, mob.health)) {
        const msg = "Unable to summon object";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    }
    const msg = "Object successfully summoned";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "summon usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/summon <EntityName> [x] [y] [z] [dataTag]", def.usage());
}
