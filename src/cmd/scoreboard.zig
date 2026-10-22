//! /scoreboard — objectives, player scores, teams.

const cmd = @import("mod.zig");

pub const def = cmd.define(.{
    .name = "scoreboard",
    .node = "asteorite.command.scoreboard",
    .min_level = 2,
    .spec = &.{
        &[_]cmd.Slot{
            cmd.Slot{ .arg = .{ .choice = &.{ "objectives", "players", "teams" } } },
            cmd.Slot{ .arg = .{ .word = {} }, .optional = true, .display = "<action>" },
            cmd.Slot{ .arg = .{ .rest = {} }, .optional = true, .display = "<args ...>" },
        },
    },
    .usage_override = "/scoreboard <objectives|players|teams>",
});

// Branch usages (vanilla subcommand texts, used for arity errors).
const u_objectives = "/scoreboard objectives <list|add|remove|setdisplay>";
const u_obj_add = "/scoreboard objectives add <name> <criteriaType> [display name ...]";
const u_obj_remove = "/scoreboard objectives remove <name>";
const u_obj_setdisplay = "/scoreboard objectives setdisplay <slot> [objective]";
const u_players = "/scoreboard players <set|add|remove|reset|list>";
const u_pla_set = "/scoreboard players set <player> <objective> <score>";
const u_pla_add = "/scoreboard players add <player> <objective> <count>";
const u_pla_remove = "/scoreboard players remove <player> <objective> <count>";
const u_pla_reset = "/scoreboard players reset <player>";
const u_pla_list = "/scoreboard players list [name]";
const u_teams = "/scoreboard teams <list|add|remove|empty|join|leave|option>";
const u_team_add = "/scoreboard teams add <name> [display name ...]";
const u_team_remove = "/scoreboard teams remove <name>";
const u_team_empty = "/scoreboard teams empty";
const u_team_join = "/scoreboard teams join <team> [player]";
const u_team_leave = "/scoreboard teams leave [player]";
const u_team_list = "/scoreboard teams list [name]";
const u_team_option = "/scoreboard teams option <team> <friendlyfire|color|seeFriendlyInvisibles> <value>";

pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8 {
    var toks: [64][]const u8 = undefined;
    const n = cmd.Spec.tokenize(args, &toks);
    if (n == 0) return cmd.usageError(&def, out);
    if (std.mem.eql(u8, toks[0], "objectives")) return objectives(srv, sender, toks[1..n], out);
    if (std.mem.eql(u8, toks[0], "players")) return playersCmd(srv, sender, toks[1..n], out);
    if (std.mem.eql(u8, toks[0], "teams")) return teams(srv, sender, toks[1..n], out);
    return cmd.usageError(&def, out);
}

fn objectives(srv: anytype, sender: anytype, args: [][]const u8, out: []u8) []const u8 {
    if (args.len == 0) return u_objectives;
    if (std.mem.eql(u8, args[0], "list")) {
        if (args.len != 1) return u_obj_setdisplay;
        return srv.sbListObjectives(out);
    }
    if (std.mem.eql(u8, args[0], "add")) {
        if (args.len < 3) return u_obj_add;
        var db: [96]u8 = undefined;
        const display = if (args.len > 3) cmd.Spec.joinRest(args, 3, &db) orelse return u_obj_add else "";
        switch (srv.sbAddObjective(args[1], args[2], display)) {
            .ok => {
                const msg = std.fmt.bufPrint(out, "Added new objective '{s}' successfully", .{args[1]}) catch "Added objective";
                srv.notifyAdmins(sender, &def, msg);
                return msg;
            },
            .too_long => return std.fmt.bufPrint(out, "The name '{s}' is too long for an objective, it can be at most 16 characters long", .{args[1]}) catch u_obj_add,
            .display_too_long => return std.fmt.bufPrint(out, "The display name '{s}' is too long for an objective, it can be at most 32 characters long", .{display}) catch u_obj_add,
            .exists => return std.fmt.bufPrint(out, "An objective with the name '{s}' already exists", .{args[1]}) catch u_obj_add,
            .bad_criteria => return std.fmt.bufPrint(out, "Invalid objective criteria type '{s}'", .{args[2]}) catch u_obj_add,
            else => return u_obj_add,
        }
    }
    if (std.mem.eql(u8, args[0], "remove")) {
        if (args.len != 2) return u_obj_remove;
        switch (srv.sbRemoveObjective(args[1])) {
            .ok => {
                const msg = std.fmt.bufPrint(out, "Removed objective '{s}' successfully", .{args[1]}) catch "Removed objective";
                srv.notifyAdmins(sender, &def, msg);
                return msg;
            },
            else => return std.fmt.bufPrint(out, "No objective was found by the name '{s}'", .{args[1]}) catch u_obj_remove,
        }
    }
    if (std.mem.eql(u8, args[0], "setdisplay")) {
        if (args.len < 2 or args.len > 3) return u_obj_setdisplay;
        const obj: ?[]const u8 = if (args.len == 3) args[2] else null;
        switch (srv.sbSetDisplay(args[1], obj)) {
            .ok => {
                if (obj) |o| {
                    const msg = std.fmt.bufPrint(out, "Set the display objective in slot '{s}' to '{s}'", .{ args[1], o }) catch "Set display slot";
                    srv.notifyAdmins(sender, &def, msg);
                    return msg;
                }
                const msg = std.fmt.bufPrint(out, "Cleared objective display slot '{s}'", .{args[1]}) catch "Cleared display slot";
                srv.notifyAdmins(sender, &def, msg);
                return msg;
            },
            .bad_slot => return std.fmt.bufPrint(out, "No such display slot '{s}'", .{args[1]}) catch u_obj_setdisplay,
            .not_found => return std.fmt.bufPrint(out, "No objective was found by the name '{s}'", .{obj orelse ""}) catch u_obj_setdisplay,
            else => return u_obj_setdisplay,
        }
    }
    return u_objectives;
}

fn playersCmd(srv: anytype, sender: anytype, args: [][]const u8, out: []u8) []const u8 {
    if (args.len == 0) return u_players;
    if (std.mem.eql(u8, args[0], "list")) {
        if (args.len > 2) return u_pla_list;
        if (args.len == 2) return playersListOne(srv, args[1], out);
        return playersListAll(srv, out);
    }
    if (std.mem.eql(u8, args[0], "reset")) {
        if (args.len != 2) return u_pla_reset;
        var target: [16]u8 = undefined;
        const t = srv.resolvePlayerName(sender, args[1], &target) orelse {
            return "That player cannot be found";
        };
        srv.sbResetScores(t);
        const msg = std.fmt.bufPrint(out, "Reset all scores of player {s}", .{t}) catch "Reset scores";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    }
    if (std.mem.eql(u8, args[0], "set") or std.mem.eql(u8, args[0], "add") or std.mem.eql(u8, args[0], "remove")) {
        const is_set = std.mem.eql(u8, args[0], "set");
        const is_add = std.mem.eql(u8, args[0], "add");
        const usage = if (is_set) u_pla_set else if (is_add) u_pla_add else u_pla_remove;
        if (args.len != 4) return usage;
        var target: [16]u8 = undefined;
        const t = srv.resolvePlayerName(sender, args[1], &target) orelse {
            return "That player cannot be found";
        };
        const v = std.fmt.parseInt(i32, args[3], 10) catch return usage;
        if (is_set) {
            switch (srv.sbSetScore(t, args[2], v)) {
                .ok => {
                    const msg = std.fmt.bufPrint(out, "Set score of {s} for player {s} to {d}", .{ args[2], t, v }) catch "Set score";
                    srv.notifyAdmins(sender, &def, msg);
                    return msg;
                },
                else => return std.fmt.bufPrint(out, "No objective was found by the name '{s}'", .{args[2]}) catch usage,
            }
        }
        switch (srv.sbAddScore(t, args[2], if (std.mem.eql(u8, args[0], "add")) v else -v)) {
            .ok => {
                const cur = srv.sbGetScore(t, args[2]) orelse v;
                const msg = std.fmt.bufPrint(out, "Set score of {s} for player {s} to {d}", .{ args[2], t, cur }) catch "Set score";
                srv.notifyAdmins(sender, &def, msg);
                return msg;
            },
            else => return std.fmt.bufPrint(out, "No objective was found by the name '{s}'", .{args[2]}) catch usage,
        }
    }
    return u_players;
}

fn playersListAll(srv: anytype, out: []u8) []const u8 {
    var names: [64][16]u8 = undefined;
    const n = srv.sbTrackedPlayers(&names);
    var ow: usize = 0;
    ow += (std.fmt.bufPrint(out[ow..], "Showing {d} tracked players on the scoreboard:", .{n}) catch return out[0..ow]).len;
    for (names[0..n]) |nm| {
        const ln = std.mem.indexOfScalar(u8, &nm, 0) orelse 16;
        ow += (std.fmt.bufPrint(out[ow..], "\n- {s}", .{nm[0..ln]}) catch break).len;
    }
    if (n == 0) ow += (std.fmt.bufPrint(out[ow..], "\nThere are no tracked players on the scoreboard", .{}) catch return out[0..ow]).len;
    return out[0..ow];
}

fn playersListOne(srv: anytype, name: []const u8, out: []u8) []const u8 {
    var scores: [32]srv_mod.SbScore = undefined;
    var bufs: [32][80]u8 = undefined;
    const n = srv.sbPlayerScores(name, &scores, &bufs);
    var ow: usize = 0;
    ow += (std.fmt.bufPrint(out[ow..], "Showing {d} tracked objective(s) for {s}:", .{ n, name }) catch return out[0..ow]).len;
    for (scores[0..n]) |s| {
        // "- <score>: <value> (<objective>)" per vanilla list.player.entry.
        ow += (std.fmt.bufPrint(out[ow..], "\n- {s}: {d} ({s})", .{ s.objective, s.value, s.objective }) catch break).len;
    }
    if (n == 0) ow += (std.fmt.bufPrint(out[ow..], "\nPlayer {s} has no scores recorded", .{name}) catch return out[0..ow]).len;
    return out[0..ow];
}

const srv_mod = @import("../sim/scoreboard.zig");

fn teams(srv: anytype, sender: anytype, args: [][]const u8, out: []u8) []const u8 {
    if (args.len == 0) return u_teams;
    if (std.mem.eql(u8, args[0], "list")) {
        if (args.len > 2) return u_team_list;
        if (args.len == 2) {
            return srv.sbListTeamPlayers(args[1], out) orelse std.fmt.bufPrint(out, "No team was found by the name '{s}'", .{args[1]}) catch u_team_list;
        }
        return srv.sbListTeams(out);
    }
    if (std.mem.eql(u8, args[0], "add")) {
        if (args.len < 2) return u_team_add;
        var db: [96]u8 = undefined;
        const display = if (args.len > 2) cmd.Spec.joinRest(args, 2, &db) orelse return u_team_add else "";
        switch (srv.sbAddTeam(args[1], display)) {
            .ok => {
                const msg = std.fmt.bufPrint(out, "Added new team '{s}' successfully", .{args[1]}) catch "Added team";
                srv.notifyAdmins(sender, &def, msg);
                return msg;
            },
            .too_long => return std.fmt.bufPrint(out, "The name '{s}' is too long for a team, it can be at most 16 characters long", .{args[1]}) catch u_team_add,
            .display_too_long => return std.fmt.bufPrint(out, "The display name '{s}' is too long for a team, it can be at most 32 characters long", .{display}) catch u_team_add,
            .exists => return std.fmt.bufPrint(out, "A team with the name '{s}' already exists", .{args[1]}) catch u_team_add,
            else => return u_team_add,
        }
    }
    if (std.mem.eql(u8, args[0], "remove")) {
        if (args.len != 2) return u_team_remove;
        switch (srv.sbRemoveTeam(args[1])) {
            .ok => {
                const msg = std.fmt.bufPrint(out, "Removed team {s}", .{args[1]}) catch "Removed team";
                srv.notifyAdmins(sender, &def, msg);
                return msg;
            },
            else => return std.fmt.bufPrint(out, "No team was found by the name '{s}'", .{args[1]}) catch u_team_remove,
        }
    }
    if (std.mem.eql(u8, args[0], "empty")) {
        if (args.len != 2) return u_team_empty;
        const n = srv.sbEmptyTeam(args[1]) orelse {
            return std.fmt.bufPrint(out, "No team was found by the name '{s}'", .{args[1]}) catch u_team_empty;
        };
        if (n == 0) {
            return std.fmt.bufPrint(out, "Team {s} is already empty, cannot remove nonexistant players", .{args[1]}) catch u_team_empty;
        }
        const msg = std.fmt.bufPrint(out, "Removed all {d} player(s) from team {s}", .{ n, args[1] }) catch "Emptied team";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    }
    if (std.mem.eql(u8, args[0], "join")) {
        if (args.len < 2 or args.len > 3) return u_team_join;
        var target: [16]u8 = undefined;
        var t: []const u8 = "";
        if (args.len == 3) {
            t = srv.resolvePlayerName(sender, args[2], &target) orelse {
                return "That player cannot be found";
            };
        } else {
            if (sender == null) return u_team_join;
            const self_name = cmd.senderName(sender, &target);
            if (self_name.len == 0) return u_team_join;
            t = self_name;
        }
        var nb: [32]u8 = undefined;
        if (srv.sbJoinTeam(args[1], t, &nb) == 0) {
            return std.fmt.bufPrint(out, "No team was found by the name '{s}'", .{args[1]}) catch u_team_join;
        }
        const msg = std.fmt.bufPrint(out, "Added {d} player(s) to team {s}: {s}", .{ 1, args[1], t }) catch "Joined team";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    }
    if (std.mem.eql(u8, args[0], "leave")) {
        if (args.len > 2) return u_team_leave;
        var target: [16]u8 = undefined;
        var t: []const u8 = "";
        if (args.len == 2) {
            t = srv.resolvePlayerName(sender, args[1], &target) orelse {
                return "That player cannot be found";
            };
        } else {
            if (sender == null) return u_team_leave;
            const self_name = cmd.senderName(sender, &target);
            if (self_name.len == 0) return u_team_leave;
            t = self_name;
        }
        if (srv.sbLeavePlayer(t) == null) {
            if (args.len == 1) return "You are not in a team";
            return std.fmt.bufPrint(out, "Could not remove {d} player(s) from their teams: {s}", .{ 1, t }) catch u_team_leave;
        }
        const msg = std.fmt.bufPrint(out, "Removed {d} player(s) from their teams: {s}", .{ 1, t }) catch "Left team";
        srv.notifyAdmins(sender, &def, msg);
        return msg;
    }
    if (std.mem.eql(u8, args[0], "option")) {
        if (args.len != 4) return u_team_option;
        if (std.mem.eql(u8, args[2], "friendlyfire")) {
            switch (srv.sbSetOption(args[1], .friendlyfire, args[3])) {
                .ok => {
                    const msg = std.fmt.bufPrint(out, "Set option {s} for team {s} to {s}", .{ args[2], args[1], args[3] }) catch "Set option";
                    srv.notifyAdmins(sender, &def, msg);
                    return msg;
                },
                .not_found => return std.fmt.bufPrint(out, "No team was found by the name '{s}'", .{args[1]}) catch u_team_option,
                .bad_value => return std.fmt.bufPrint(out, "Valid values for option {s} are: {s}", .{ args[2], "true, false" }) catch u_team_option,
            }
        }
        if (std.mem.eql(u8, args[2], "color")) {
            switch (srv.sbSetOption(args[1], .color, args[3])) {
                .ok => {
                    const msg = std.fmt.bufPrint(out, "Set option {s} for team {s} to {s}", .{ args[2], args[1], args[3] }) catch "Set option";
                    srv.notifyAdmins(sender, &def, msg);
                    return msg;
                },
                .not_found => return std.fmt.bufPrint(out, "No team was found by the name '{s}'", .{args[1]}) catch u_team_option,
                .bad_value => return std.fmt.bufPrint(out, "Valid values for option {s} are: {s}", .{ args[2], "black, dark_blue, dark_green, dark_aqua, dark_red, dark_purple, gold, gray, dark_gray, blue, green, aqua, red, light_purple, yellow, white" }) catch u_team_option,
            }
        }
        if (std.mem.eql(u8, args[2], "seeFriendlyInvisibles")) {
            switch (srv.sbSetOption(args[1], .see_friendly_invisibles, args[3])) {
                .ok => {
                    const msg = std.fmt.bufPrint(out, "Set option {s} for team {s} to {s}", .{ args[2], args[1], args[3] }) catch "Set option";
                    srv.notifyAdmins(sender, &def, msg);
                    return msg;
                },
                .not_found => return std.fmt.bufPrint(out, "No team was found by the name '{s}'", .{args[1]}) catch u_team_option,
                .bad_value => return std.fmt.bufPrint(out, "Valid values for option {s} are: {s}", .{ args[2], "true, false" }) catch u_team_option,
            }
        }
        return u_team_option;
    }
    return u_teams;
}

const std = @import("std");

test "scoreboard usage string is vanilla-exact" {
    try std.testing.expectEqualStrings("/scoreboard <objectives|players|teams>", def.usage());
}
