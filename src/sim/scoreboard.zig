//! Scoreboard store (vanilla 1.7.10 semantics: objectives, scores, teams,
//! display slots). In-memory + single-row persistence, same pattern as
//! permissions/bans. Packet broadcast lives on the Server side; this module
//! only stores, validates, and persists.

const std = @import("std");
const store_mod = @import("../world/store.zig");
const shard_mod = @import("../world/shard.zig");
const profile = @import("../version.zig");
const cmd_data = profile.game.cmd_data;

pub const scoreboard_dim: u8 = 251;
pub const scoreboard_key = store_mod.encodeKey(scoreboard_dim, 0, 0);

pub const max_name_len: usize = 16;
pub const max_display_len: usize = 32;

pub const ScoreboardError = error{
    NameTooLong,
    DisplayTooLong,
    AlreadyExists,
    NotFound,
    BadCriteria,
    BadSlot,
    OutOfMemory,
};

/// One tracked (player, objective) score for list output.
pub const SbScore = struct {
    player: []const u8,
    objective: []u8,
    value: i32,
};

pub const Objective = struct {
    name: []u8,
    criteria: []u8,
    display: []u8,
};

pub const Team = struct {
    name: []u8,
    display: []u8,
    prefix: []u8,
    suffix: []u8,
    friendly_fire: bool,
    color: []u8,
    see_friendly_invisibles: bool,
    members: std.StringHashMap(void),
};

pub const Scoreboard = struct {
    alloc: std.mem.Allocator,
    objectives: std.StringHashMap(*Objective),
    /// "player\x00objective" composite keys.
    scores: std.StringHashMap(i32),
    teams: std.StringHashMap(*Team),
    slots: [3]?[]u8, // list, sidebar, belowName -> objective name

    pub fn init(alloc: std.mem.Allocator) Scoreboard {
        return .{
            .alloc = alloc,
            .objectives = .init(alloc),
            .scores = .init(alloc),
            .teams = .init(alloc),
            .slots = .{ null, null, null },
        };
    }

    pub fn deinit(self: *Scoreboard) void {
        var oit = self.objectives.iterator();
        while (oit.next()) |e| {
            // Map key and objective.name are the same allocation (put takes
            // ownership of o.name); free once.
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*.criteria);
            self.alloc.free(e.value_ptr.*.display);
            self.alloc.destroy(e.value_ptr.*);
        }
        self.objectives.deinit();
        var sit = self.scores.iterator();
        while (sit.next()) |e| self.alloc.free(e.key_ptr.*);
        self.scores.deinit();
        var tit = self.teams.iterator();
        while (tit.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            const t = e.value_ptr.*;
            self.alloc.free(t.display);
            self.alloc.free(t.prefix);
            self.alloc.free(t.suffix);
            self.alloc.free(t.color);
            var mit = t.members.iterator();
            while (mit.next()) |m| self.alloc.free(m.key_ptr.*);
            t.members.deinit();
            self.alloc.destroy(t);
        }
        self.teams.deinit();
        for (&self.slots) |*s| if (s.*) |v| self.alloc.free(v);
    }

    pub fn addObjective(self: *Scoreboard, name: []const u8, criteria: []const u8, display: []const u8) ScoreboardError!void {
        if (name.len == 0 or name.len > max_name_len) return error.NameTooLong;
        if (display.len > max_display_len) return error.DisplayTooLong;
        var ok_criteria = false;
        for (cmd_data.criteria) |c| {
            if (std.mem.eql(u8, c, criteria)) {
                ok_criteria = true;
                break;
            }
        }
        if (!ok_criteria) {
            // stat.* / achievement.* families are 1.8+; 1.7.10 has 5 fixed.
            return error.BadCriteria;
        }
        if (self.objectives.contains(name)) return error.AlreadyExists;
        const o = try self.alloc.create(Objective);
        errdefer self.alloc.destroy(o);
        o.* = .{
            .name = try self.alloc.dupe(u8, name),
            .criteria = try self.alloc.dupe(u8, criteria),
            .display = try self.alloc.dupe(u8, if (display.len == 0) name else display),
        };
        errdefer self.alloc.free(o.name);
        errdefer self.alloc.free(o.criteria);
        errdefer self.alloc.free(o.display);
        try self.objectives.put(o.name, o);
    }

    pub fn removeObjective(self: *Scoreboard, name: []const u8) ScoreboardError!void {
        const kv = self.objectives.fetchRemove(name) orelse return error.NotFound;
        // kv.key and kv.value.name are the same allocation; free once.
        self.alloc.free(kv.key);
        self.alloc.free(kv.value.criteria);
        self.alloc.free(kv.value.display);
        self.alloc.destroy(kv.value);
        // Drop its scores + clear slots pointing at it.
        var sit = self.scores.iterator();
        var dead: [256][]const u8 = undefined;
        var n_dead: usize = 0;
        while (sit.next()) |e| {
            const key = e.key_ptr.*;
            const sep = std.mem.indexOfScalar(u8, key, 0) orelse continue;
            if (std.mem.eql(u8, key[sep + 1 ..], name)) {
                if (n_dead < dead.len) {
                    dead[n_dead] = key;
                    n_dead += 1;
                }
            }
        }
        for (dead[0..n_dead]) |k| {
            if (self.scores.fetchRemove(k)) |old| self.alloc.free(old.key);
        }
        for (&self.slots) |*s| {
            if (s.*) |v| {
                if (std.mem.eql(u8, v, name)) {
                    self.alloc.free(v);
                    s.* = null;
                }
            }
        }
    }

    fn scoreKey(self: *Scoreboard, player: []const u8, objective: []const u8) ![]u8 {
        var k = try self.alloc.alloc(u8, player.len + 1 + objective.len);
        @memcpy(k[0..player.len], player);
        k[player.len] = 0;
        @memcpy(k[player.len + 1 ..], objective);
        return k;
    }

    pub fn setScore(self: *Scoreboard, player: []const u8, objective: []const u8, value: i32) ScoreboardError!void {
        if (!self.objectives.contains(objective)) return error.NotFound;
        const k = try self.scoreKey(player, objective);
        errdefer self.alloc.free(k);
        if (self.scores.fetchRemove(k)) |old| self.alloc.free(old.key);
        try self.scores.put(k, value);
    }

    pub fn getScore(self: *const Scoreboard, player: []const u8, objective: []const u8) ?i32 {
        var kb: [64]u8 = undefined;
        if (player.len + 1 + objective.len > kb.len) return null;
        @memcpy(kb[0..player.len], player);
        kb[player.len] = 0;
        @memcpy(kb[player.len + 1 ..][0..objective.len], objective);
        return self.scores.get(kb[0 .. player.len + 1 + objective.len]);
    }

    pub fn resetScores(self: *Scoreboard, player: []const u8) void {
        var sit = self.scores.iterator();
        var dead: [256][]const u8 = undefined;
        var n_dead: usize = 0;
        while (sit.next()) |e| {
            const key = e.key_ptr.*;
            const sep = std.mem.indexOfScalar(u8, key, 0) orelse continue;
            if (std.mem.eql(u8, key[0..sep], player)) {
                if (n_dead < dead.len) {
                    dead[n_dead] = key;
                    n_dead += 1;
                }
            }
        }
        for (dead[0..n_dead]) |k| {
            if (self.scores.fetchRemove(k)) |old| self.alloc.free(old.key);
        }
        // Vanilla reset also drops team membership.
        var tit = self.teams.iterator();
        while (tit.next()) |e| {
            if (e.value_ptr.*.members.fetchRemove(player)) |old| self.alloc.free(old.key);
        }
    }

    pub fn objectiveCount(self: *const Scoreboard) usize {
        return self.objectives.count();
    }

    pub fn addTeam(self: *Scoreboard, name: []const u8, display: []const u8) ScoreboardError!void {
        if (name.len == 0 or name.len > max_name_len) return error.NameTooLong;
        if (display.len > max_display_len) return error.DisplayTooLong;
        if (self.teams.contains(name)) return error.AlreadyExists;
        const t = try self.alloc.create(Team);
        errdefer self.alloc.destroy(t);
        t.* = .{
            .name = try self.alloc.dupe(u8, name),
            .display = try self.alloc.dupe(u8, if (display.len == 0) name else display),
            .prefix = try self.alloc.dupe(u8, ""),
            .suffix = try self.alloc.dupe(u8, ""),
            .friendly_fire = true,
            .color = try self.alloc.dupe(u8, "reset"),
            .see_friendly_invisibles = true,
            .members = .init(self.alloc),
        };
        errdefer self.alloc.free(t.name);
        try self.teams.put(t.name, t);
    }

    pub fn removeTeam(self: *Scoreboard, name: []const u8) ScoreboardError!void {
        const kv = self.teams.fetchRemove(name) orelse return error.NotFound;
        self.alloc.free(kv.key);
        self.alloc.free(kv.value.display);
        self.alloc.free(kv.value.prefix);
        self.alloc.free(kv.value.suffix);
        self.alloc.free(kv.value.color);
        var mit = kv.value.members.iterator();
        while (mit.next()) |m| self.alloc.free(m.key_ptr.*);
        kv.value.members.deinit();
        self.alloc.destroy(kv.value);
    }

    pub fn joinTeam(self: *Scoreboard, team: []const u8, player: []const u8) ScoreboardError!void {
        const t = self.teams.get(team) orelse return error.NotFound;
        // Leave any current team first (vanilla moves players between teams).
        var tit = self.teams.iterator();
        while (tit.next()) |e| {
            if (e.value_ptr.*.members.fetchRemove(player)) |old| self.alloc.free(old.key);
        }
        const k = try self.alloc.dupe(u8, player);
        errdefer self.alloc.free(k);
        try t.members.put(k, {});
    }

    pub fn teamOf(self: *const Scoreboard, player: []const u8) ?[]const u8 {
        var tit = self.teams.iterator();
        while (tit.next()) |e| {
            if (e.value_ptr.*.members.contains(player)) return e.key_ptr.*;
        }
        return null;
    }

    pub fn leaveTeams(self: *Scoreboard, player: []const u8) bool {
        var left = false;
        var tit = self.teams.iterator();
        while (tit.next()) |e| {
            if (e.value_ptr.*.members.fetchRemove(player)) |old| {
                self.alloc.free(old.key);
                left = true;
            }
        }
        return left;
    }

    pub fn setSlot(self: *Scoreboard, slot: u8, objective: ?[]const u8) ScoreboardError!void {
        if (slot > 2) return error.BadSlot;
        // Validate first: a bad objective leaves the slot untouched.
        if (objective) |o| {
            if (!self.objectives.contains(o)) return error.NotFound;
        }
        if (self.slots[slot]) |v| {
            self.alloc.free(v);
            self.slots[slot] = null;
        }
        if (objective) |o| {
            self.slots[slot] = try self.alloc.dupe(u8, o);
        }
    }

    const magic = "ZSBD";
    const version: u8 = 1;

    fn writeStr(out: []u8, i: *usize, s: []const u8) void {
        std.mem.writeInt(u16, out[i.*..][0..2], @intCast(s.len), .big);
        i.* += 2;
        @memcpy(out[i.*..][0..s.len], s);
        i.* += s.len;
    }

    fn strLen(s: []const u8) usize {
        return 2 + s.len;
    }

    pub fn encode(self: *const Scoreboard, alloc: std.mem.Allocator) ![]u8 {
        var n: usize = 4 + 1 + 4;
        var oit = self.objectives.iterator();
        while (oit.next()) |e| n += strLen(e.key_ptr.*) + strLen(e.value_ptr.*.criteria) + strLen(e.value_ptr.*.display);
        n += 4;
        var sit = self.scores.iterator();
        while (sit.next()) |e| n += 2 + e.key_ptr.len + 4;
        n += 4;
        var tit = self.teams.iterator();
        while (tit.next()) |e| {
            const t = e.value_ptr.*;
            n += strLen(t.name) + strLen(t.display) + strLen(t.prefix) + strLen(t.suffix) + 1 + strLen(t.color) + 1 + 4;
            var mit = t.members.iterator();
            while (mit.next()) |m| n += strLen(m.key_ptr.*);
        }
        n += 3 * 2;
        for (self.slots) |s| n += if (s) |v| v.len else 0;
        const out = try alloc.alloc(u8, n);
        errdefer alloc.free(out);
        var i: usize = 0;
        @memcpy(out[i..][0..4], magic);
        i += 4;
        out[i] = version;
        i += 1;
        std.mem.writeInt(u32, out[i..][0..4], @intCast(self.objectives.count()), .big);
        i += 4;
        var ojt = self.objectives.iterator();
        while (ojt.next()) |e| {
            writeStr(out, &i, e.key_ptr.*);
            writeStr(out, &i, e.value_ptr.*.criteria);
            writeStr(out, &i, e.value_ptr.*.display);
        }
        std.mem.writeInt(u32, out[i..][0..4], @intCast(self.scores.count()), .big);
        i += 4;
        var sjt = self.scores.iterator();
        while (sjt.next()) |e| {
            std.mem.writeInt(u16, out[i..][0..2], @intCast(e.key_ptr.len), .big);
            i += 2;
            @memcpy(out[i..][0..e.key_ptr.len], e.key_ptr.*);
            i += e.key_ptr.len;
            std.mem.writeInt(i32, out[i..][0..4], e.value_ptr.*, .big);
            i += 4;
        }
        std.mem.writeInt(u32, out[i..][0..4], @intCast(self.teams.count()), .big);
        i += 4;
        var tjt = self.teams.iterator();
        while (tjt.next()) |e| {
            const t = e.value_ptr.*;
            writeStr(out, &i, t.name);
            writeStr(out, &i, t.display);
            writeStr(out, &i, t.prefix);
            writeStr(out, &i, t.suffix);
            out[i] = if (t.friendly_fire) 1 else 0;
            i += 1;
            writeStr(out, &i, t.color);
            out[i] = if (t.see_friendly_invisibles) 1 else 0;
            i += 1;
            std.mem.writeInt(u32, out[i..][0..4], @intCast(t.members.count()), .big);
            i += 4;
            var mjt = t.members.iterator();
            while (mjt.next()) |m| writeStr(out, &i, m.key_ptr.*);
        }
        for (self.slots) |s| {
            if (s) |v| {
                std.mem.writeInt(u16, out[i..][0..2], @intCast(v.len), .big);
                i += 2;
                @memcpy(out[i..][0..v.len], v);
                i += v.len;
            } else {
                std.mem.writeInt(u16, out[i..][0..2], 0xFFFF, .big);
                i += 2;
            }
        }
        std.debug.assert(i == n);
        return out;
    }

    fn readStr(bytes: []const u8, i: *usize, alloc: std.mem.Allocator) ![]u8 {
        if (i.* + 2 > bytes.len) return error.Corrupt;
        const l = std.mem.readInt(u16, bytes[i.*..][0..2], .big);
        i.* += 2;
        if (i.* + l > bytes.len) return error.Corrupt;
        const s = try alloc.dupe(u8, bytes[i.* .. i.* + l]);
        i.* += l;
        return s;
    }

    pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) !Scoreboard {
        var sb = Scoreboard.init(alloc);
        errdefer sb.deinit();
        if (bytes.len < 9 or !std.mem.eql(u8, bytes[0..4], magic) or bytes[4] != version) return error.Corrupt;
        var i: usize = 5;
        const no = std.mem.readInt(u32, bytes[i..][0..4], .big);
        i += 4;
        var k: usize = 0;
        while (k < no) : (k += 1) {
            const name = try readStr(bytes, &i, alloc);
            errdefer alloc.free(name);
            const crit = try readStr(bytes, &i, alloc);
            errdefer alloc.free(crit);
            const disp = try readStr(bytes, &i, alloc);
            errdefer alloc.free(disp);
            const o = try alloc.create(Objective);
            o.* = .{ .name = name, .criteria = crit, .display = disp };
            try sb.objectives.put(o.name, o);
        }
        if (i + 4 > bytes.len) return error.Corrupt;
        const ns = std.mem.readInt(u32, bytes[i..][0..4], .big);
        i += 4;
        k = 0;
        while (k < ns) : (k += 1) {
            const key = try readStr(bytes, &i, alloc);
            errdefer alloc.free(key);
            if (i + 4 > bytes.len) return error.Corrupt;
            const v = std.mem.readInt(i32, bytes[i..][0..4], .big);
            i += 4;
            try sb.scores.put(key, v);
        }
        if (i + 4 > bytes.len) return error.Corrupt;
        const nt = std.mem.readInt(u32, bytes[i..][0..4], .big);
        i += 4;
        k = 0;
        while (k < nt) : (k += 1) {
            const t = try alloc.create(Team);
            errdefer alloc.destroy(t);
            t.name = try readStr(bytes, &i, alloc);
            t.display = try readStr(bytes, &i, alloc);
            t.prefix = try readStr(bytes, &i, alloc);
            t.suffix = try readStr(bytes, &i, alloc);
            if (i + 1 > bytes.len) return error.Corrupt;
            t.friendly_fire = bytes[i] != 0;
            i += 1;
            t.color = try readStr(bytes, &i, alloc);
            if (i + 1 > bytes.len) return error.Corrupt;
            t.see_friendly_invisibles = bytes[i] != 0;
            i += 1;
            t.members = .init(alloc);
            if (i + 4 > bytes.len) return error.Corrupt;
            const nm = std.mem.readInt(u32, bytes[i..][0..4], .big);
            i += 4;
            var m: usize = 0;
            while (m < nm) : (m += 1) {
                const ms = try readStr(bytes, &i, alloc);
                try t.members.put(ms, {});
            }
            try sb.teams.put(t.name, t);
        }
        for (&sb.slots) |*s| {
            if (i + 2 > bytes.len) return error.Corrupt;
            const l = std.mem.readInt(u16, bytes[i..][0..2], .big);
            i += 2;
            if (l == 0xFFFF) {
                s.* = null;
            } else {
                if (i + l > bytes.len) return error.Corrupt;
                s.* = try alloc.dupe(u8, bytes[i .. i + l]);
                i += l;
            }
        }
        return sb;
    }
};

pub fn save(pool: *shard_mod.ShardPool, alloc: std.mem.Allocator, sb: *const Scoreboard) !void {
    const enc = try sb.encode(alloc);
    defer alloc.free(enc);
    try pool.put(scoreboard_key, enc);
}

pub fn load(pool: *shard_mod.ShardPool, alloc: std.mem.Allocator) !?Scoreboard {
    const raw = try pool.get(alloc, scoreboard_key);
    if (raw == null) return null;
    defer alloc.free(raw.?);
    return try Scoreboard.decode(alloc, raw.?);
}

test "scoreboard crud + roundtrip" {
    var sb = Scoreboard.init(std.testing.allocator);
    defer sb.deinit();
    try sb.addObjective("obj", "dummy", "Obj");
    try std.testing.expectError(error.AlreadyExists, sb.addObjective("obj", "dummy", ""));
    try std.testing.expectError(error.BadCriteria, sb.addObjective("x", "stat.jump", ""));
    try std.testing.expectError(error.NameTooLong, sb.addObjective("0123456789abcdefg", "dummy", ""));
    try sb.setScore("Al", "obj", 5);
    try std.testing.expectEqual(@as(i32, 5), sb.getScore("Al", "obj").?);
    try std.testing.expectError(error.NotFound, sb.setScore("Al", "nope", 1));
    try sb.addTeam("red", "Red");
    try sb.joinTeam("red", "Al");
    try std.testing.expectEqualStrings("red", sb.teamOf("Al").?);
    try sb.setSlot(1, "obj");
    try std.testing.expectError(error.NotFound, sb.setSlot(1, "nope"));
    const enc = try sb.encode(std.testing.allocator);
    defer std.testing.allocator.free(enc);
    var sb2 = try Scoreboard.decode(std.testing.allocator, enc);
    defer sb2.deinit();
    try std.testing.expectEqual(@as(i32, 5), sb2.getScore("Al", "obj").?);
    try std.testing.expectEqualStrings("red", sb2.teamOf("Al").?);
    try std.testing.expectEqualStrings("obj", sb2.slots[1].?);
    try sb2.removeObjective("obj");
    try std.testing.expect(sb2.getScore("Al", "obj") == null);
    try std.testing.expect(sb2.slots[1] == null);
    try sb2.removeTeam("red");
    try std.testing.expect(sb2.teamOf("Al") == null);
}
