//! /testforblock — check the block at coords (id + optional data).

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "testforblock",
    .node = "asteorite.command.testforblock",
    .min_level = .gamemaster,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .coord = {} }, .display = "<x>" },
            cmd.Slot{ .arg = .{ .coord = {} }, .display = "<y>" },
            cmd.Slot{ .arg = .{ .coord = {} }, .display = "<z>" },
            cmd.Slot{ .arg = .{ .word = {} }, .display = "<TileName>" },
            cmd.Slot{ .arg = .{ .int_range = .{} }, .optional = true, .display = "<dataValue>" },
            cmd.Slot{ .arg = .{ .word = {} }, .optional = true, .display = "<dataTag>" },
        },
    },
    .usage_override = "/testforblock <x> <y> <z> <TileName> [dataValue] [dataTag]",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [7][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n < 4 or n > 6) return cmd.usageError(&def, out);
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
    if (yy < 0 or yy > 255) return "Cannot test for block outside of the world";
    const wire_id: u16 = blk: {
        if (srv.blockWireByName(toks[3])) |w| break :blk w;
        const v = std.fmt.parseInt(i64, toks[3], 10) catch {
            return std.fmt.bufPrint(out, "There is no such block with ID/name {s}", .{toks[3]}) catch "No such block";
        };
        if (v < 0 or v > 255 or !srv.isBlockWire(@intCast(v))) {
            return std.fmt.bufPrint(out, "There is no such block with ID/name {s}", .{toks[3]}) catch "No such block";
        }
        break :blk @intCast(v);
    };
    var data: i32 = -1;
    if (n >= 5) {
        const d = std.fmt.parseInt(i64, toks[4], 10) catch return cmd.usageError(&def, out);
        if (d < -1 or d > 15) return cmd.usageError(&def, out);
        data = @intCast(d);
    }
    if (n == 6) {
        return std.fmt.bufPrint(out, "Data tag parsing failed: {s}", .{"Not a valid tag"}) catch "Data tag parsing failed";
    }
    const got = srv.getBlockAt(x, yy, z) orelse {
        return "Cannot test for block outside of the world";
    };
    if (got.wire != wire_id) {
        var gb: [64]u8 = undefined;
        var eb: [64]u8 = undefined;
        return std.fmt.bufPrint(out, "The block at {d},{d},{d} is {s} (expected: {s})", .{ x, yy, z, srv.blockName(got.wire, &gb), srv.blockName(wire_id, &eb) }) catch "Block mismatch";
    }
    if (data >= 0 and got.meta != data) {
        return std.fmt.bufPrint(out, "The block at {d},{d},{d} had the data value of {d} (expected: {d})", .{ x, yy, z, got.meta, data }) catch "Data mismatch";
    }
    // Queries report to the sender only (no admin broadcast).
    return std.fmt.bufPrint(out, "Successfully found the block at {d},{d},{d}.", .{ x, yy, z }) catch "Found block";
}

const std = @import("std");

test "testforblock usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/testforblock <x> <y> <z> <TileName> [dataValue] [dataTag]", def.usage());
}
