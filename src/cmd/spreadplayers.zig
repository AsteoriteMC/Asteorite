//! /spreadplayers — scatter players/teams around a center point.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "spreadplayers",
    .node = "asteorite.command.spreadplayers",
    .min_level = 2,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .float_range = .{} }, .display = "<x>" },
            cmd.Slot{ .arg = .{ .float_range = .{} }, .display = "<z>" },
            cmd.Slot{ .arg = .{ .float_range = .{} }, .display = "<spreadDistance>" },
            cmd.Slot{ .arg = .{ .float_range = .{} }, .display = "<maxRange>" },
            cmd.Slot{ .arg = .{ .boolean = {} }, .display = "<respectTeams true|false>" },
            cmd.Slot{ .arg = .{ .rest = {} }, .display = "<player ...>" },
        },
    },
    .usage_override = "/spreadplayers <x> <z> <spreadDistance> <maxRange> <respectTeams true|false> <player ...>",
});

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [40][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n < 6) return cmd.usageError(&def, out);
    const x = std.fmt.parseFloat(f64, toks[0]) catch return cmd.usageError(&def, out);
    const z = std.fmt.parseFloat(f64, toks[1]) catch return cmd.usageError(&def, out);
    if (!std.math.isFinite(x) or !std.math.isFinite(z)) return cmd.usageError(&def, out);
    const spread = std.fmt.parseFloat(f64, toks[2]) catch return cmd.usageError(&def, out);
    if (!std.math.isFinite(spread) or spread < 0) {
        return std.fmt.bufPrint(out, "The number you have entered ({d}) is too small, it must be at least 0", .{spread}) catch cmd.usageError(&def, out);
    }
    const range = std.fmt.parseFloat(f64, toks[3]) catch return cmd.usageError(&def, out);
    if (!std.math.isFinite(range) or range < 1) {
        return std.fmt.bufPrint(out, "The number you have entered ({d}) is too small, it must be at least 1", .{range}) catch cmd.usageError(&def, out);
    }
    const respect = cmd.Spec.parseBool(toks[4]) orelse {
        return std.fmt.bufPrint(out, "'{s}' is not true or false", .{toks[4]}) catch cmd.usageError(&def, out);
    };
    // Expand targets (@a = everyone, @p/@r/plain = one).
    var members: [64][16]u8 = undefined;
    var mlens: [64]u8 = undefined;
    var mcount: usize = 0;
    for (toks[5..n]) |tok| {
        var one: [8][16]u8 = undefined;
        var ll: [8]u8 = undefined;
        const got = srv.resolvePlayerList(sender, tok, &one, &ll);
        for (one[0..got], ll[0..got]) |nm, ln| {
            if (mcount >= members.len) break;
            @memcpy(members[mcount][0..ln], nm[0..ln]);
            mlens[mcount] = ln;
            mcount += 1;
        }
    }
    if (mcount == 0) return "That player cannot be found";
    if (mcount == 1) {
        // Vanilla short-circuit: single player lands on the center, with
        // only the success line (no spreading/average chatter).
        const nm = members[0][0..mlens[0]];
        const sy = srv.surfaceY(@intFromFloat(@floor(x)), @intFromFloat(@floor(z)));
        if (!srv.teleportCoords(nm, .{ @floor(x) + 0.5, @floatFromInt(sy), @floor(z) + 0.5 })) {
            return "That player cannot be found";
        }
        const msg = std.fmt.bufPrint(out, "Successfully spread 1 players around {d},{d}", .{ @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(z)) }) catch "Spread";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    }
    // Group by team when respecting teams (vanilla spreads teams as units).
    var keys: [64][16]u8 = undefined;
    var klens: [64]u8 = undefined;
    var groups: [64][8]u8 = undefined; // member indices per group
    var glens: [64]u8 = undefined;
    var ngroups: usize = 0;
    for (0..mcount) |mi| {
        const nm = members[mi][0..mlens[mi]];
        var key: [16]u8 = undefined;
        var klen: u8 = 0;
        if (respect) {
            if (srv.sbTeamOf(nm)) |team| {
                const tl = @min(team.len, 16);
                @memcpy(key[0..tl], team[0..tl]);
                klen = @intCast(tl);
            }
        }
        if (klen == 0) {
            @memcpy(key[0..mlens[mi]], nm);
            klen = mlens[mi];
        }
        var gi: ?usize = null;
        for (0..ngroups) |g| {
            if (klens[g] == klen and std.mem.eql(u8, keys[g][0..klen], key[0..klen])) {
                gi = g;
                break;
            }
        }
        const g = gi orelse blk: {
            if (ngroups >= groups.len) break :blk 0;
            @memcpy(keys[ngroups][0..klen], key[0..klen]);
            klens[ngroups] = klen;
            glens[ngroups] = 0;
            ngroups += 1;
            break :blk ngroups - 1;
        };
        if (glens[g] < groups[g].len) {
            groups[g][glens[g]] = @intCast(mi);
            glens[g] += 1;
        }
    }
    // Vanilla spread iterations: 10000 attempts maximizing min-distance.
    var px: [64]f64 = undefined;
    var pz: [64]f64 = undefined;
    var best: [64]f64 = undefined;
    for (0..ngroups) |g| {
        px[g] = x + (srv.spreadRand() * 2 - 1) * range;
        pz[g] = z + (srv.spreadRand() * 2 - 1) * range;
        best[g] = 0;
    }
    var attempt: usize = 0;
    while (attempt < 10000) : (attempt += 1) {
        for (0..ngroups) |g| {
            const cx = x + (srv.spreadRand() * 2 - 1) * range;
            const cz = z + (srv.spreadRand() * 2 - 1) * range;
            var dmin: f64 = std.math.inf(f64);
            for (0..ngroups) |h| {
                if (h == g) continue;
                const dx = cx - px[h];
                const dz = cz - pz[h];
                const d = dx * dx + dz * dz;
                if (d < dmin) dmin = d;
            }
            if (dmin > best[g]) {
                best[g] = dmin;
                px[g] = cx;
                pz[g] = cz;
            }
        }
        // Early-out once every group clears the spread distance.
        var ok = true;
        for (0..ngroups) |g| {
            if (best[g] < spread * spread) {
                ok = false;
                break;
            }
        }
        if (ok and attempt > 100) break;
    }
    var sum: f64 = 0;
    var min_d: f64 = std.math.inf(f64);
    for (0..ngroups) |g| {
        const d = @sqrt(best[g]);
        sum += d;
        if (d < min_d) min_d = d;
    }
    const avg = sum / @as(f64, @floatFromInt(ngroups));
    if (min_d < spread) {
        return std.fmt.bufPrint(out, "Could not spread {d} {s} around {d},{d} (too many players for space - try using spread of at most {s})", .{ ngroups, if (respect) "teams" else "players", @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(z)), toks[3] }) catch "Could not spread";
    }
    for (0..ngroups) |g| {
        const sy = srv.surfaceY(@intFromFloat(@floor(px[g])), @intFromFloat(@floor(pz[g])));
        for (groups[g][0..glens[g]]) |mi| {
            const nm = members[mi][0..mlens[mi]];
            _ = srv.teleportCoords(nm, .{ @floor(px[g]) + 0.5, @floatFromInt(sy), @floor(pz[g]) + 0.5 });
        }
    }
    var reply: [1024]u8 = undefined;
    const success = std.fmt.bufPrint(&reply, "Successfully spread {d} {s} around {d},{d}", .{
        ngroups, if (respect) "teams" else "players",
        @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(z)),
    }) catch "Spread";
    const line1 = std.fmt.bufPrint(out, "Spreading {d} {s} {d} blocks around {d},{d} (min {d} blocks apart)\n(Average distance between {s} is {d:.2} blocks apart after {d} iterations)\n{s}", .{
        ngroups,                                                       if (respect) "teams" else "players", @as(i32, @intFromFloat(range)),
        @as(i32, @intFromFloat(x)),                                    @as(i32, @intFromFloat(z)),          @as(i32, @intFromFloat(spread)),
        if (respect) "teams" else "players",                           avg,                                 attempt,
        success,
    }) catch "Spread";
    srv.notifyAdmins(sender, &def, success);
    return line1;
}

const std = @import("std");

test "spreadplayers usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/spreadplayers <x> <z> <spreadDistance> <maxRange> <respectTeams true|false> <player ...>", def.usage());
}
