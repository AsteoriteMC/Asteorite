//! /help — list commands the sender may use, 7 per page like vanilla.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "help",
    .node = "asteorite.command.help",
    .min_level = 0,
    .aliases = &.{"?"},
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .word = {} }, .optional = true, .display = "<page|command name>" },
        },
    },
    .usage_override = "/help [page|command name]",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [2][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    // Vanilla only reads args[0] (a page number or command name); extra
    // words are ignored, and bare /help shows page 1.
    if (n == 0) return srv.helpText(sender, 1, out);
    // Page number or command name (vanilla tries int first, else name).
    const page = std.fmt.parseInt(i32, toks[0], 10) catch {
        return srv.helpCommand(sender, toks[0], out);
    };
    if (page < 1) {
        return std.fmt.bufPrint(out, "The number you have entered ({d}) is too small, it must be at least 1", .{page}) catch cmd.usageError(&def, out);
    }
    return srv.helpText(sender, page, out);
}

const std = @import("std");

test "help parses page or name, rejects extras" {
    var toks: [2][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), cmd.Spec.tokenize("", &toks));
    try std.testing.expectEqual(@as(usize, 1), cmd.Spec.tokenize("2", &toks));
    try std.testing.expectEqual(@as(usize, 1), cmd.Spec.tokenize("give", &toks));
    try std.testing.expectEqualStrings("/help [page|command name]", def.usage());
}
