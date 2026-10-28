//! /tp — teleport a player to coordinates or to another player.
//!
//! All four vanilla forms: `/tp <dest>`, `/tp <mover> <dest>`,
//! `/tp <x> <y> <z>`, `/tp <mover> <x> <y> <z>` (absolute doubles with
//! `~`-relative support, y unbounded).

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "tp",
    .node = "asteorite.command.tp",
    .min_level = .gamemaster,
    .spec = &.{
        &[_]cmd.Slot{cmd.Slot{ .arg = .{ .player = {} } }},
        &[_]cmd.Slot{ cmd.Slot{ .arg = .{ .player = {} } }, cmd.Slot{ .arg = .{ .player = {} } } },
        &[_]cmd.Slot{ cmd.Slot{ .arg = .{ .coord = {} } }, cmd.Slot{ .arg = .{ .coord = {} } }, cmd.Slot{ .arg = .{ .coord = {} } } },
        &[_]cmd.Slot{ cmd.Slot{ .arg = .{ .player = {} } }, cmd.Slot{ .arg = .{ .coord = {} } }, cmd.Slot{ .arg = .{ .coord = {} } }, cmd.Slot{ .arg = .{ .coord = {} } } },
    },
    .usage_override = "/tp [target player] <destination player> OR /tp [target player] <x> <y> <z>",
});

/// Teleport destination, resolved by argument parsing. The backend turns
/// names into coordinates (needs the player snapshot).
pub const Dest = union(enum) {
    coords: [3]f64,
    player: []const u8,
};

/// Parse one coordinate: absolute double or `~[offset]` relative to base
/// (vanilla parseCoordinate; `~` alone = base).
fn parseCoord(s: []const u8, base: f64) ?f64 {
    return cmd.Spec.parseCoord(s, base);
}

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [5][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    // Shape-check via the spec (right arity + numeric coords parse).
    var vals: [4]cmd.Value = undefined;
    if (cmd.matchFirst(def.spec, toks[0..n], &vals) == null) return cmd.usageError(&def, out);
    // Resolve mover + destination per arity.
    var mover_name: [cmd.max_name_len]u8 = undefined;
    var dest_name: [cmd.max_name_len]u8 = undefined;
    if (n == 1 or n == 3) {
        // Sender is the mover (console cannot use these forms).
        if (sender == null) return cmd.usageError(&def, out);
        const self_name = cmd.senderName(sender, &mover_name);
        if (self_name.len == 0) return cmd.usageError(&def, out);
        if (n == 1) {
            const d = cmd.resolveTarget(srv, sender, toks[0], &dest_name) orelse return cmd.unknown_player;
            if (!srv.teleportPlayer(self_name, d)) return "That player cannot be found";
            const msg = std.fmt.bufPrint(out, "Teleported {s} to {s}", .{ self_name, d }) catch "Teleported";
            srv.notifyAdmins(sender, &def, msg);
            return msg;
        }
        const base = srv.playerPos(self_name) orelse return "That player cannot be found";
        const x = parseCoord(toks[0], base[0]) orelse return cmd.usageError(&def, out);
        const y = parseCoord(toks[1], base[1]) orelse return cmd.usageError(&def, out);
        const z = parseCoord(toks[2], base[2]) orelse return cmd.usageError(&def, out);
        if (!srv.teleportCoords(self_name, .{ x, y, z })) return "That player cannot be found";
        const msg = std.fmt.bufPrint(out, "Teleported {s} to {d:.2},{d:.2},{d:.2}", .{ self_name, x, y, z }) catch "Teleported";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    }
    // n == 2 or 4: first arg is the mover.
    const mover = cmd.resolveTarget(srv, sender, toks[0], &mover_name) orelse return cmd.unknown_player;
    if (n == 2) {
        const d = cmd.resolveTarget(srv, sender, toks[1], &dest_name) orelse return cmd.unknown_player;
        if (std.mem.eql(u8, mover, d)) {
            // Same player: vanilla skips the dimension check and succeeds.
            return std.fmt.bufPrint(out, "Teleported {s} to {s}", .{ mover, d }) catch "Teleported";
        }
        if (!srv.teleportPlayer(mover, d)) return "That player cannot be found";
        const msg = std.fmt.bufPrint(out, "Teleported {s} to {s}", .{ mover, d }) catch "Teleported";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    }
    // n == 4: coords relative to the SENDER (vanilla parseCoordinate base).
    const base = srv.senderPos(sender) orelse return cmd.usageError(&def, out);
    const x = parseCoord(toks[1], base[0]) orelse return cmd.usageError(&def, out);
    const y = parseCoord(toks[2], base[1]) orelse return cmd.usageError(&def, out);
    const z = parseCoord(toks[3], base[2]) orelse return cmd.usageError(&def, out);
    if (!srv.teleportCoords(mover, .{ x, y, z })) return "That player cannot be found";
    const msg = std.fmt.bufPrint(out, "Teleported {s} to {d:.2},{d:.2},{d:.2}", .{ mover, x, y, z }) catch "Teleported";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

const std = @import("std");

test "tp usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/tp [target player] <destination player> OR /tp [target player] <x> <y> <z>", def.usage());
}

test "parseCoord absolute and relative" {
    try std.testing.expectEqual(@as(?f64, 10.0), parseCoord("10", 100.0));
    try std.testing.expectEqual(@as(?f64, 100.0), parseCoord("~", 100.0));
    try std.testing.expectEqual(@as(?f64, 105.0), parseCoord("~5", 100.0));
    try std.testing.expect(parseCoord("nan", 0) == null);
}
