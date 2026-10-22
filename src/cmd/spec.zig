//! Command framework: spec-driven usage, parsing, and tab-completion.
//!
//! Every command declares a `Spec`: a list of overloads, each an ordered
//! list of typed arguments. Usage strings, argument validation, and
//! tab-completion candidates are all DERIVED from the spec — never
//! hand-written — so help text, parsing, and completion can never drift
//! apart. Where vanilla's own usage text has quirks the generator can't
//! produce (e.g. `/tp [target player] <destination player> OR ...`), the
//! command may set `usage_override` to the exact vanilla string.
//!
//! Versioning: this module only depends on `std`. Argument *values* that
//! are inherently versioned (item/block/entity names, gamerule names,
//! enchantment ids) live in `proto/v5/` data tables and are passed in by
//! the caller/backend — the spec machinery itself is version-neutral.

const std = @import("std");

/// One typed argument in an overload.
pub const Arg = union(enum) {
    /// Fixed keyword, e.g. `set`, `add`. Renders literally.
    literal: []const u8,
    /// Online player name (completion from the player list).
    player: void,
    /// One word (no spaces).
    word: void,
    /// Rest of the line, may contain spaces.
    rest: void,
    /// Integer in [min, max] (null = unbounded).
    int_range: struct {
        min: ?i64 = null,
        max: ?i64 = null,
    },
    /// Float in [min, max].
    float_range: struct {
        min: ?f64 = null,
        max: ?f64 = null,
    },
    /// Block coordinate: absolute double or `~[offset]` relative to the
    /// sender (vanilla parseCoordinate). Validated loosely here (float or
    /// `~` + float); the command resolves it against the sender position.
    coord: void,
    /// Boolean (true/false/1/0/yes/no/on/off).
    boolean: void,
    /// One of the given literals (completion + validation).
    choice: []const []const u8,
};

/// One argument slot: whether it may be omitted, its spec, and the usage
/// display name. `display` overrides the generated placeholder (e.g.
/// `<message ...>`, `<Minutes until kick>`); null keeps the type default.
pub const Slot = struct {
    arg: Arg,
    optional: bool = false,
    display: ?[]const u8 = null,
};

/// One calling convention: `/cmd <a> [b]`.
pub const Overload = []const Slot;

/// Parse outcome for one argument.
pub const Value = union(enum) {
    literal: void,
    player: []const u8,
    word: []const u8,
    /// Remaining tokens (caller joins with `joinRest` when it needs text).
    rest: [][]const u8,
    int: i64,
    float: f64,
    /// Raw coordinate token (absolute or `~`-relative; resolved by the
    /// command via parseCoord against the sender position).
    coord: []const u8,
    boolean: bool,
    choice: usize, // index into the choice list
};

pub const ParseError = union(enum) {
    ok,
    /// No overload matched; the caller should print usage.
    no_match,
};

/// Split a raw args string into tokens. Quoting is NOT supported (matches
/// vanilla, which splits on spaces and drops empties).
pub fn tokenize(args: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, args, ' ');
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (n >= out.len) break;
        out[n] = tok;
        n += 1;
    }
    return n;
}

/// Try to match tokens against one overload. On success writes values and
/// returns the count; on failure returns null without touching `vals`
/// (caller tries the next overload).
pub fn matchOverload(over: Overload, toks: [][]const u8, vals: []Value) ?usize {
    var ti: usize = 0;
    var vi: usize = 0;
    for (over) |slot| {
        if (ti >= toks.len) {
            if (slot.optional) continue;
            return null;
        }
        const tok = toks[ti];
        switch (slot.arg) {
            .literal => |lit| {
                if (!std.mem.eql(u8, tok, lit)) return null;
                vals[vi] = .{ .literal = {} };
            },
            .player => {
                // Plain names plus vanilla 1.7 target selectors (@p/@r/@a);
                // the backend resolves selectors, existence is checked there.
                if (isSelector(tok) or validPlayerNameChars(tok)) {
                    vals[vi] = .{ .player = tok };
                } else return null;
            },
            .word => {
                vals[vi] = .{ .word = tok };
            },
            .rest => {
                // Consumes all remaining tokens; caller joins as needed.
                vals[vi] = .{ .rest = toks[ti..] };
                vi += 1;
                ti = toks.len;
            },
            .int_range => |r| {
                const v = std.fmt.parseInt(i64, tok, 0) catch return null;
                if (r.min) |lo| if (v < lo) return null;
                if (r.max) |hi| if (v > hi) return null;
                vals[vi] = .{ .int = v };
            },
            .float_range => |r| {
                const v = std.fmt.parseFloat(f64, tok) catch return null;
                if (!std.math.isFinite(v)) return null;
                if (r.min) |lo| if (v < lo) return null;
                if (r.max) |hi| if (v > hi) return null;
                vals[vi] = .{ .float = v };
            },
            .coord => {
                if (tok.len > 0 and tok[0] == '~') {
                    if (tok.len > 1) {
                        const v = std.fmt.parseFloat(f64, tok[1..]) catch return null;
                        if (!std.math.isFinite(v)) return null;
                    }
                } else {
                    const v = std.fmt.parseFloat(f64, tok) catch return null;
                    if (!std.math.isFinite(v)) return null;
                }
                vals[vi] = .{ .coord = tok };
            },
            .boolean => {
                vals[vi] = .{ .boolean = parseBool(tok) orelse return null };
            },
            .choice => |opts| {
                var hit: ?usize = null;
                for (opts, 0..) |o, oi| {
                    if (std.mem.eql(u8, tok, o)) {
                        hit = oi;
                        break;
                    }
                }
                const h = hit orelse return null;
                vals[vi] = .{ .choice = h };
            },
        }
        vi += 1;
        ti += 1;
    }
    if (ti != toks.len) return null;
    return vi;
}

/// Join tokens[from..] with single spaces (for `.rest` args).
pub fn joinRest(toks: [][]const u8, from: usize, out: []u8) ?[]const u8 {
    var ow: usize = 0;
    for (toks[from..], 0..) |t, i| {
        if (i > 0) {
            if (ow + 1 > out.len) return null;
            out[ow] = ' ';
            ow += 1;
        }
        if (ow + t.len > out.len) return null;
        @memcpy(out[ow..][0..t.len], t);
        ow += t.len;
    }
    return out[0..ow];
}

pub fn parseBool(s: []const u8) ?bool {
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1") or
        std.mem.eql(u8, s, "yes") or std.mem.eql(u8, s, "on")) return true;
    if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "0") or
        std.mem.eql(u8, s, "no") or std.mem.eql(u8, s, "off")) return false;
    return null;
}

/// Parse one coordinate: absolute double or `~[offset]` relative to base
/// (vanilla parseCoordinate; `~` alone = base).
pub fn parseCoord(s: []const u8, base: f64) ?f64 {
    if (s.len > 0 and s[0] == '~') {
        if (s.len == 1) return base;
        const off = std.fmt.parseFloat(f64, s[1..]) catch return null;
        if (!std.math.isFinite(off)) return null;
        return base + off;
    }
    const v = std.fmt.parseFloat(f64, s) catch return null;
    if (!std.math.isFinite(v)) return null;
    return v;
}

/// Login-name charset (mirrors conn.validPlayerName; kept local so this
/// module stays dependency-free).
pub fn validPlayerNameChars(name: []const u8) bool {
    if (name.len == 0 or name.len > 16) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// Vanilla 1.7 target selectors (no @e until 1.8).
pub fn isSelector(tok: []const u8) bool {
    return std.mem.eql(u8, tok, "@p") or std.mem.eql(u8, tok, "@r") or std.mem.eql(u8, tok, "@a");
}

/// Shape check for Arg.coord (absolute double or `~[offset]`).
pub fn isCoord(tok: []const u8) bool {
    if (tok.len > 0 and tok[0] == '~') {
        if (tok.len == 1) return true;
        const v = std.fmt.parseFloat(f64, tok[1..]) catch return false;
        return std.math.isFinite(v);
    }
    const v = std.fmt.parseFloat(f64, tok) catch return false;
    return std.math.isFinite(v);
}

/// Render one argument for usage text. `display` wins; otherwise the type
/// default (`<player>`, `[amount]`-style via the optional flag, `set|add`
/// for choices). Required choices render bracketed (`<set|add>`), matching
/// vanilla (`/time <set|add> <value>`, `/debug <start|stop>`); optional
/// ones stay bare in brackets (`[ips|players]`, `/banlist [ips|players]`).
fn renderSlot(slot: Slot, buf: []u8) []const u8 {
    if (slot.display) |d| {
        if (slot.optional) {
            return std.fmt.bufPrint(buf, "[{s}]", .{d}) catch buf[0..0];
        }
        return d;
    }
    return switch (slot.arg) {
        .literal => |lit| if (slot.optional)
            std.fmt.bufPrint(buf, "[{s}]", .{lit}) catch buf[0..0]
        else
            lit,
        .player => if (slot.optional) "[<player>]" else "<player>",
        .word => if (slot.optional) "[<text>]" else "<text>",
        .rest => if (slot.optional) "[<message ...>]" else "<message ...>",
        .int_range => if (slot.optional) "[<number>]" else "<number>",
        .float_range => if (slot.optional) "[<number>]" else "<number>",
        .coord => if (slot.optional) "[<number>]" else "<number>",
        .boolean => if (slot.optional) "[<true|false>]" else "<true|false>",
        .choice => |opts| blk: {
            var ibuf: [128]u8 = undefined;
            const inner = joinChoices(opts, &ibuf);
            break :blk if (slot.optional)
                std.fmt.bufPrint(buf, "[{s}]", .{inner}) catch buf[0..0]
            else
                std.fmt.bufPrint(buf, "<{s}>", .{inner}) catch buf[0..0];
        },
    };
}

fn joinChoices(opts: []const []const u8, buf: []u8) []const u8 {
    var ow: usize = 0;
    for (opts, 0..) |o, i| {
        if (i > 0) {
            if (ow + 1 > buf.len) return buf[0..ow];
            buf[ow] = '|';
            ow += 1;
        }
        const n = @min(o.len, buf.len - ow);
        @memcpy(buf[ow..][0..n], o[0..n]);
        ow += n;
    }
    return buf[0..ow];
}

/// Render `/name <req> [opt] OR /name ...` for a spec. `name_with_slash`
/// includes the leading slash (e.g. "/tp").
pub fn renderUsage(name_with_slash: []const u8, spec: []const Overload, out: []u8) []const u8 {
    var ow: usize = 0;
    for (spec, 0..) |over, oi| {
        if (oi > 0) {
            ow += (std.fmt.bufPrint(out[ow..], " OR ", .{}) catch break).len;
        }
        ow += (std.fmt.bufPrint(out[ow..], "{s}", .{name_with_slash}) catch break).len;
        for (over) |slot| {
            var abuf: [160]u8 = undefined;
            const r = renderSlot(slot, &abuf);
            ow += (std.fmt.bufPrint(out[ow..], " {s}", .{r}) catch break).len;
        }
    }
    return out[0..ow];
}

/// Case-insensitive prefix match (mirrors CommandBase.doesStringStartWith,
/// which uses regionMatches(ignoreCase=true)).
pub fn startsWithIgnoreCase(hay: []const u8, prefix: []const u8) bool {
    if (prefix.len > hay.len) return false;
    for (hay[0..prefix.len], prefix) |h, p| {
        if (std.ascii.toLower(h) != std.ascii.toLower(p)) return false;
    }
    return true;
}

/// Completion candidates for the token at `arg_index` (0-based within the
/// args, not counting the command name). `prefix` is the partial token.
/// Player names and command-specific dynamic sets come from the caller via
/// `extra` (already filtered or not — this function filters by prefix,
/// case-INsensitively like vanilla). Returns the number written to `out`.
pub fn completeStatic(
    spec: []const Overload,
    arg_index: usize,
    prefix: []const u8,
    extra: []const []const u8,
    out: [][]const u8,
) usize {
    var n: usize = 0;
    // Collect literals/choices valid at this position across overloads.
    for (spec) |over| {
        if (arg_index >= over.len) continue;
        const slot = over[arg_index];
        switch (slot.arg) {
            .literal => |lit| {
                if (n < out.len and startsWithIgnoreCase(lit, prefix) and !containsStr(out[0..n], lit)) {
                    out[n] = lit;
                    n += 1;
                }
            },
            .choice => |opts| {
                for (opts) |o| {
                    if (n < out.len and startsWithIgnoreCase(o, prefix) and !containsStr(out[0..n], o)) {
                        out[n] = o;
                        n += 1;
                    }
                }
            },
            else => {},
        }
    }
    for (extra) |e| {
        if (n >= out.len) break;
        if (startsWithIgnoreCase(e, prefix)) {
            out[n] = e;
            n += 1;
        }
    }
    return n;
}

fn containsStr(hay: [][]const u8, needle: []const u8) bool {
    for (hay) |e| {
        if (std.mem.eql(u8, e, needle)) return true;
    }
    return false;
}

test "usage rendering" {
    var buf: [256]u8 = undefined;
    const s1 = &[_]Overload{
        &[_]Slot{ .{ .arg = .{ .choice = &.{ "set", "add" } } }, .{ .arg = .{ .int_range = .{} } } },
    };
    try std.testing.expectEqualStrings("/cmd <set|add> <number>", renderUsage("/cmd", s1, &buf));
    const s2 = &[_]Overload{
        &[_]Slot{ .{ .arg = .{ .literal = "set" } }, .{ .arg = .{ .int_range = .{} }, .optional = true } },
    };
    try std.testing.expectEqualStrings("/cmd set [<number>]", renderUsage("/cmd", s2, &buf));
    // display override renders verbatim, optional or not
    try std.testing.expectEqualStrings("/say <message ...>", renderUsage("/say", &[_]Overload{
        &[_]Slot{.{ .arg = .{ .rest = {} }, .display = "<message ...>" }},
    }, &buf));
    const s3 = &[_]Overload{
        &[_]Slot{.{ .arg = .{ .player = {} } }},
        &[_]Slot{ .{ .arg = .{ .player = {} } }, .{ .arg = .{ .player = {} } } },
        &[_]Slot{ .{ .arg = .{ .player = {} } }, .{ .arg = .{ .float_range = .{} } }, .{ .arg = .{ .float_range = .{} } }, .{ .arg = .{ .float_range = .{} } } },
    };
    try std.testing.expectEqualStrings("/tp <player> OR /tp <player> <player> OR /tp <player> <number> <number> <number>", renderUsage("/tp", s3, &buf));
}

test "matchOverload picks typed values, rejects extras" {
    var vals: [4]Value = undefined;
    const over = &[_]Slot{
        .{ .arg = .{ .literal = "set" } },
        .{ .arg = .{ .int_range = .{ .min = 0, .max = 10 } } },
        .{ .arg = .{ .choice = &.{ "a", "b" } }, .optional = true },
    };
    var t1 = [_][]const u8{ "set", "5" };
    try std.testing.expectEqual(@as(?usize, 2), matchOverload(over, &t1, &vals));
    try std.testing.expectEqual(@as(i64, 5), vals[1].int);
    var t2 = [_][]const u8{"set"};
    try std.testing.expect(matchOverload(over, &t2, &vals) == null);
    var t3 = [_][]const u8{ "set", "99" };
    try std.testing.expect(matchOverload(over, &t3, &vals) == null);
    var t4 = [_][]const u8{ "set", "5", "b", "extra" };
    try std.testing.expect(matchOverload(over, &t4, &vals) == null);
    var t5 = [_][]const u8{ "set", "5", "b" };
    try std.testing.expectEqual(@as(?usize, 3), matchOverload(over, &t5, &vals));
    try std.testing.expectEqual(@as(usize, 1), vals[2].choice);
}

test "completeStatic merges literals and choices, filters by prefix" {
    const spec = &[_]Overload{
        &[_]Slot{.{ .arg = .{ .choice = &.{ "add", "remove", "list" } } }},
        &[_]Slot{.{ .arg = .{ .literal = "add" } }, .{ .arg = .{ .word = {} } }},
    };
    var out: [8][]const u8 = undefined;
    const extra = [_][]const u8{"Alice", "Bob"};
    // arg 0, empty prefix: choices + extra (literals only if literal slot at 0; here literal is in overload 2 slot 0 too)
    const n = completeStatic(spec, 0, "", &extra, &out);
    try std.testing.expect(n >= 5);
    // prefix filter
    var out2: [8][]const u8 = undefined;
    const extra2 = [_][]const u8{};
    const m = completeStatic(spec, 0, "re", &extra2, &out2);
    try std.testing.expectEqual(@as(usize, 1), m);
    try std.testing.expectEqualStrings("remove", out2[0]);
}

test "joinRest" {
    var buf: [64]u8 = undefined;
    var toks = [_][]const u8{ "hello", "big", "world" };
    try std.testing.expectEqualStrings("big world", joinRest(toks[0..], 1, &buf).?);
}
