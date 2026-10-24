//! /setblock — place a block (replace/keep/destroy).

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "setblock",
    .node = "asteorite.command.setblock",
    .min_level = .gamemaster,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .coord = {} }, .display = "<x>" },
            cmd.Slot{ .arg = .{ .coord = {} }, .display = "<y>" },
            cmd.Slot{ .arg = .{ .coord = {} }, .display = "<z>" },
            cmd.Slot{ .arg = .{ .word = {} }, .display = "<TileName>" },
            cmd.Slot{ .arg = .{ .int_range = .{} }, .optional = true, .display = "<dataValue>" },
            cmd.Slot{ .arg = .{ .choice = &.{ "replace", "keep", "destroy" } }, .optional = true },
            cmd.Slot{ .arg = .{ .word = {} }, .optional = true, .display = "<dataTag>" },
        },
    },
    .usage_override = "/setblock <x> <y> <z> <TileName> [dataValue] [oldBlockHandling] [dataTag]",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [64][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n < 4 or n > 7) return cmd.usageError(&def, out);
    // Positions are block coords (vanilla floors parseCoordinate). Sender
    // base supports `~` like vanilla.
    const base = srv.senderPos(sender);
    const bx: f64 = if (base) |b| b[0] else 0;
    const by: f64 = if (base) |b| b[1] else 0;
    const bz: f64 = if (base) |b| b[2] else 0;
    const fx = cmd.Spec.parseCoord(toks[0], bx) orelse return cmd.usageError(&def, out);
    const fy = cmd.Spec.parseCoord(toks[1], by) orelse return cmd.usageError(&def, out);
    const fz = cmd.Spec.parseCoord(toks[2], bz) orelse return cmd.usageError(&def, out);
    const x: i32 = @intFromFloat(@floor(fx));
    const yy: i32 = @intFromFloat(@floor(fy));
    const z: i32 = @intFromFloat(@floor(fz));
    if (yy < 0 or yy > 255) return "Cannot place block outside of the world";
    const y: u8 = @intCast(yy);
    _ = y;
    const wire_id: u16 = blk: {
        if (srv.blockWireByName(toks[3])) |w| break :blk w;
        const v = std.fmt.parseInt(i64, toks[3], 10) catch {
            return std.fmt.bufPrint(out, "There is no such block with ID/name {s}", .{toks[3]}) catch "No such block";
        };
        if (v < 0 or v > 32767) {
            return std.fmt.bufPrint(out, "There is no such block with ID/name {s}", .{toks[3]}) catch "No such block";
        }
        break :blk @intCast(v);
    };
    // Items are not blocks (vanilla g() lookup fails the same way).
    if (!srv.isBlockWire(wire_id)) {
        return std.fmt.bufPrint(out, "There is no such block with ID/name {s}", .{toks[3]}) catch "No such block";
    }
    var meta: u4 = 0;
    if (n >= 5) {
        const d = std.fmt.parseInt(i64, toks[4], 10) catch return cmd.usageError(&def, out);
        if (d < 0 or d > 15) {
            if (d < 0) {
                return std.fmt.bufPrint(out, "The number you have entered ({d}) is too small, it must be at least 0", .{d}) catch cmd.usageError(&def, out);
            }
            return std.fmt.bufPrint(out, "The number you have entered ({d}) is too big, it must be at most 15", .{d}) catch cmd.usageError(&def, out);
        }
        meta = @intCast(d);
    }
    var m: u8 = 0; // 0 replace, 1 keep, 2 destroy
    if (n >= 6) {
        if (std.mem.eql(u8, toks[5], "keep")) {
            m = 1;
        } else if (std.mem.eql(u8, toks[5], "destroy")) {
            m = 2;
        } else if (!std.mem.eql(u8, toks[5], "replace")) {
            return cmd.usageError(&def, out);
        }
    }
    if (n == 7) {
        return std.fmt.bufPrint(out, "Data tag parsing failed: {s}", .{"Not a valid tag"}) catch "Data tag parsing failed";
    }
    const old = srv.getBlockAt(x, yy, z);
    switch (srv.setBlockAt(x, yy, z, wire_id, meta, if (m == 0) .replace else if (m == 1) .keep else .destroy)) {
        .no_world => return "Unable to place block",
        .out_of_world => return "Cannot place block outside of the world",
        .no_change => return "The block couldn't be placed",
        .ok => {},
    }
    if (m == 2) {
        if (old) |o| srv.setblockDrops(x, yy, z, o.wire);
    }
    const msg = "Block placed";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

test "setblock usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/setblock <x> <y> <z> <TileName> [dataValue] [oldBlockHandling] [dataTag]", def.usage());
}

const std = @import("std");
