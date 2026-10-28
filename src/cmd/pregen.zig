//! /pregen — Chunky-style chunk pregeneration with a live bossbar.
//!
//! The bar is a fake Wither (1.7.10 has no bossbar packet — the bar is
//! purely client-side, fed by rendering a tracked Wither; see
//! entity.writeBossMetadata): invisible, glued under the task owner's feet
//! (the camera stays inside its AABB, the only spot rendered in every view
//! direction — the bar expires 100 frames after its last render), dropped
//! pregen_bar_drop so its per-tick smoke/aura spawns below the view instead
//! of in the camera (invisibility hides the model, not the emitters).
//! Titled "Pregeneration NN%" with health driving the fill. It never
//! exists server-side (no AI, saves, or interaction), and is destroyed on
//! finish/cancel. The client still ticks it, so a faint wither groan may
//! occasionally play (same as BarAPI-era fake bars). Chat lines still
//! cover milestones, rate, and ETA.
//!
//! Subcommands: `start <radius> [x z]` (radius in chunks, 1..1000; center
//! defaults to your position, else world spawn), `stop`, `status`,
//! `pause`, `resume`. One task at a time; generation runs on the existing
//! background GenPool workers, so players never hitch.

const cmd = @import("mod.zig");

const subs = &.{ "start", "stop", "status", "pause", "resume" };

pub const def = cmd.define(.{
    .name = "pregen",
    .node = "asteorite.command.pregen",
    .min_level = .admin,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .choice = subs } },
        },
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .choice = subs } },
            cmd.Slot{ .arg = .{ .int_range = .{ .min = 1, .max = 1000 } }, .display = "<radius>" },
        },
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .choice = subs } },
            cmd.Slot{ .arg = .{ .int_range = .{ .min = 1, .max = 1000 } }, .display = "<radius>" },
            cmd.Slot{ .arg = .{ .coord = {} }, .display = "<x>" },
            cmd.Slot{ .arg = .{ .coord = {} }, .display = "<z>" },
        },
    },
    .usage_override = "/pregen start <radius> [x z] OR /pregen stop|status|pause|resume",
});

fn blockToChunk(b: f64) i32 {
    return @divFloor(@as(i32, @intFromFloat(@floor(b))), 16);
}

/// Task center: explicit coords, else the sender's position, else spawn.
const Center = struct { x: f64, z: f64 };

fn defaultCenter(srv: anytype, sender: anytype) Center {
    if (srv.senderPos(sender)) |p| return .{ .x = p[0], .z = p[2] };
    const sp = srv.worldSpawnPos();
    return .{ .x = @floatFromInt(sp[0]), .z = @floatFromInt(sp[2]) };
}

/// Pause/resume reply (the opposite variant is unreachable by construction:
/// toggle(true) only pauses, toggle(false) only resumes).
fn pauseReply(srv: anytype, sender: anytype, pause: bool, msg: []const u8) []const u8 {
    const r = srv.pregenPauseToggle(pause);
    if ((pause and r != .paused) or (!pause and r != .resumed)) return "No pregeneration task is running";
    srv.notifyAdmins(sender, &def, msg);
    return msg;
}

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [5][]const u8 = undefined;
    var vals: [4]cmd.Value = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    const m = cmd.matchFirst(def.spec, toks[0..n], &vals) orelse return cmd.usageError(&def, out);
    switch (vals[0].choice) {
        0 => { // start
            if (m != 2 and m != 4) return cmd.usageError(&def, out);
            const radius: i32 = @intCast(vals[1].int);
            var center: Center = undefined;
            if (m == 4) {
                const base = defaultCenter(srv, sender);
                center.x = cmd.Spec.parseCoord(vals[2].coord, base.x) orelse return cmd.usageError(&def, out);
                center.z = cmd.Spec.parseCoord(vals[3].coord, base.z) orelse return cmd.usageError(&def, out);
            } else {
                center = defaultCenter(srv, sender);
            }
            const ccx = blockToChunk(center.x);
            const ccz = blockToChunk(center.z);
            var oname: [cmd.max_name_len]u8 = undefined;
            const owner = cmd.senderName(sender, &oname);
            const side: usize = @intCast(2 * radius + 1);
            switch (srv.pregenBegin(owner, radius, ccx, ccz)) {
                .started => {
                    const msg = std.fmt.bufPrint(out, "Pregeneration started: {d} chunks, radius {d} around chunk {d},{d}", .{ side * side, radius, ccx, ccz }) catch "Pregeneration started";
                    srv.notifyAdmins(sender, &def, msg);
                    return msg;
                },
                .already_running => return "Pregeneration is already running (/pregen status, /pregen stop to cancel)",
                .no_gen => return "Pregeneration needs a world seed (generation is not enabled on this server)",
            }
        },
        1 => { // stop
            if (m != 1) return cmd.usageError(&def, out);
            if (!srv.pregenStop()) return "No pregeneration task is running";
            const msg = "Pregeneration cancelled";
            srv.notifyAdmins(sender, &def, msg);
            return msg;
        },
        2 => { // status
            if (m != 1) return cmd.usageError(&def, out);
            var sbuf: [256]u8 = undefined;
            const line = srv.pregenStatus(&sbuf);
            if (line.len == 0) return "No pregeneration task is running";
            return std.fmt.bufPrint(out, "Pregeneration: {s}", .{line}) catch "Pregeneration status unavailable";
        },
        3 => return pauseReply(srv, sender, true, "Pregeneration paused"), // pause
        4 => return pauseReply(srv, sender, false, "Pregeneration resumed"), // resume
        else => unreachable,
    }
}

const std = @import("std");

test "pregen usage string" {
    try std.testing.expectEqualStrings("/pregen start <radius> [x z] OR /pregen stop|status|pause|resume", def.usage());
}

test "blockToChunk floors toward negative infinity" {
    try std.testing.expectEqual(@as(i32, 15), blockToChunk(247.7));
    try std.testing.expectEqual(@as(i32, -1), blockToChunk(-0.5));
    try std.testing.expectEqual(@as(i32, -2), blockToChunk(-17.0));
    try std.testing.expectEqual(@as(i32, 0), blockToChunk(0.0));
}
