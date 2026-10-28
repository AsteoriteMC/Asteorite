//! Server chat/console/RCON commands, one file per command.
//!
//! Each command declares a `Def`: name (+aliases), permission node, minimum
//! op level, and a spec (see `spec.zig`). `define()` validates the def at
//! comptime and renders `usage` from the spec, so help text, parsing, and
//! tab-completion can never drift apart.
//!
//! Versioning: command files are version-AGNOSTIC. They may only import
//! `std`, this module, and version-neutral leaves (`sim/item.zig`,
//! `src/ids.zig` — never `net/`, `proto/`, or worldgen). Everything
//! version-specific (packet framing, wire ids, chunk streaming, block/
//! item/mob/gamerule tables) goes through the backend parameter `srv`,
//! which today is `*Server`. Versioned data lives under `proto/v5/`.
//!
//! ```zig
//! pub fn run(srv: anytype, sender: anytype, args: []const u8, out: []u8) []const u8
//! ```
//!
//! `sender` is the same `anytype` deal (`?*Conn` today). To support a new
//! protocol version, implement the backend methods used below on the new
//! version's server type and reuse every file in this directory unchanged.
//! Game logic (parsing, validation, reply text) lives here exactly once;
//! only the backend grows per version.

const std = @import("std");
const spec_mod = @import("spec.zig");

/// Re-exported so command files only import `mod.zig`.
pub const Spec = spec_mod;
pub const Slot = spec_mod.Slot;
pub const Arg = spec_mod.Arg;
pub const Overload = spec_mod.Overload;
pub const Value = spec_mod.Value;

/// Static command metadata. Field types intentionally match
/// `sim/player/permissions.zig`'s registry entry so defs plug straight into the
/// permission matrix with no conversion.
///
/// `usage` is DERIVED, never written by hand: `define()` renders it from
/// `spec` at comptime (or takes `usage_override` verbatim for the rare
/// vanilla strings the generator can't spell). Help text, parsing, and
/// tab-completion all read the same spec, so the three can never drift.
/// Vanilla op ladder (0-4). Commands gate on rank, never on a raw int:
/// comparisons go through `rank()` below.
pub const OpLevel = enum(u8) {
    all = 0,
    moderator = 1,
    gamemaster = 2,
    admin = 3,
    owner = 4,

    /// Numeric rank for `>=` gates (Zig enums don't order-compare).
    pub fn rank(self: OpLevel) u8 {
        return @intFromEnum(self);
    }
};

pub const Command = struct {
    name: []const u8,
    node: []const u8,
    min_level: OpLevel,
    /// Rendered usage text (filled by define() from the spec). Fixed array
    /// so no comptime-var pointer ever escapes into the runtime value.
    usage_buf: [192]u8 = [_]u8{0} ** 192,
    usage_len: usize = 0,
    spec: []const spec_mod.Overload,
    aliases: []const []const u8 = &.{},

    pub fn usage(self: *const Command) []const u8 {
        return self.usage_buf[0..self.usage_len];
    }
};

/// Comptime single-word check shared by command names + aliases.
fn checkWord(comptime what: []const u8, comptime s: []const u8) void {
    if (s.len == 0) @compileError(what ++ " must not be empty");
    if (std.mem.indexOfAny(u8, s, " /") != null) @compileError(what ++ " must be a single word");
}

/// Builder: validates the definition at comptime and renders `usage` from
/// the spec. The explicit `comptime` block matters: bare `if` +
/// `@compileError` mis-evaluates `indexOfAny` on 0.16 (fires for clean
/// names); the block form is exact.
pub fn define(comptime d: anytype) Command {
    const aliases: []const []const u8 = if (@hasField(@TypeOf(d), "aliases")) d.aliases else &.{};
    const usage_override: ?[]const u8 = if (@hasField(@TypeOf(d), "usage_override")) d.usage_override else null;
    comptime {
        checkWord("command name", d.name);
        for (aliases) |a| {
            checkWord("command alias", a);
            if (std.mem.eql(u8, a, d.name)) @compileError("alias must differ from the command name");
        }
        if (!std.mem.startsWith(u8, d.node, "asteorite.command.")) @compileError("command node must live under asteorite.command.");
        if (d.spec.len == 0) @compileError("command spec must list at least one overload");
        for (d.spec) |over| {
            if (over.len == 0) continue; // bare `/cmd` (list, stop, seed)
            for (over) |slot| {
                if (slot.display) |s| {
                    if (s.len == 0) @compileError("display name must not be empty");
                }
            }
        }
        if (usage_override) |u| {
            if (u.len == 0 or u[0] != '/') @compileError("command usage_override must start with '/'");
        }
    }
    // Rendered at comptime into the returned value (arrays copy; no
    // comptime-var pointer ever reaches runtime). define() only ever runs
    // for `pub const def` initializers, so the bytes are static.
    const slash_name = comptime ("/" ++ d.name);
    const rendered = usage_override orelse comptimeRender(slash_name, d.spec);
    comptime {
        if (rendered.len > 192) @compileError("rendered usage exceeds 192 bytes");
    }
    var cmd = Command{
        .name = d.name,
        .node = d.node,
        .min_level = d.min_level,
        .usage_len = rendered.len,
        .spec = d.spec,
        .aliases = aliases,
    };
    @memcpy(cmd.usage_buf[0..rendered.len], rendered);
    return cmd;
}

/// Comptime usage renderer: same output as spec.renderUsage, but built
/// with `++` concatenation (slices of comptime locals can't escape).
fn comptimeRender(comptime slash_name: []const u8, comptime spec: []const spec_mod.Overload) []const u8 {
    comptime var out: []const u8 = "";
    inline for (spec, 0..) |over, oi| {
        if (oi > 0) out = out ++ " OR ";
        out = out ++ slash_name ++ comptimeSlots(over);
    }
    return out;
}

fn comptimeSlots(comptime over: spec_mod.Overload) []const u8 {
    comptime var out: []const u8 = "";
    inline for (over) |slot| out = out ++ " " ++ comptimeSlot(slot);
    return out;
}

/// One slot rendered at comptime (mirrors spec.renderSlot: same
/// display/optional/choice rules, `++` concatenation instead of bufPrint).
fn comptimeSlot(comptime slot: spec_mod.Slot) []const u8 {
    const inner = if (slot.display) |disp| disp else switch (slot.arg) {
        .literal => |lit| lit,
        .player => "<player>",
        .word => "<text>",
        .rest => "<message ...>",
        .int_range, .float_range, .coord => "<number>",
        .boolean => "<true|false>",
        .choice => |opts| comptimeChoices(opts),
    };
    if (!slot.optional and slot.arg == .choice) return "<" ++ inner ++ ">";
    if (slot.optional) return "[" ++ inner ++ "]";
    return inner;
}

fn comptimeChoices(comptime opts: []const []const u8) []const u8 {
    comptime var out: []const u8 = opts[0];
    inline for (opts[1..]) |o| out = out ++ "|" ++ o;
    return out;
}

/// `Usage: <usage>` error line for wrong-arity calls. Vanilla wraps every
/// syntax failure in `commands.generic.usage` ("Usage: %s"); help entries
/// and `/help <cmd>` show the bare usage instead.
pub fn usageError(cmd_: *const Command, out: []u8) []const u8 {
    return std.fmt.bufPrint(out, "Usage: {s}", .{cmd_.usage()}) catch cmd_.usage();
}

/// Try each overload in order; first match wins (mirrors vanilla's
/// single-path parse per command). Returns matched value count, or null
/// when no overload fits (caller prints usage).
pub fn matchFirst(spec: []const spec_mod.Overload, toks: [][]const u8, vals: []spec_mod.Value) ?usize {
    for (spec) |over| {
        if (spec_mod.matchOverload(over, toks, vals)) |n| return n;
    }
    return null;
}

/// Match iff the sender typed this command (primary name or alias).
pub fn matches(cmd: *const Command, word: []const u8) bool {
    if (std.mem.eql(u8, cmd.name, word)) return true;
    for (cmd.aliases) |a| if (std.mem.eql(u8, a, word)) return true;
    return false;
}

/// Split args on spaces, skipping empties, up to `out.len` tokens.
/// Returns the token count. (Single home is Spec.tokenize; every command
/// calls that directly. This alias keeps the framework test local.)
pub fn splitArgs(args: []const u8, out: [][]const u8) usize {
    return spec_mod.tokenize(args, out);
}

/// First whitespace-separated token, or null when blank.
pub fn firstArg(args: []const u8) ?[]const u8 {
    if (args.len == 0) return null;
    const end = std.mem.indexOfScalar(u8, args, ' ') orelse args.len;
    if (end == 0) return null;
    return args[0..end];
}

/// Login-name cap (mirrors the login gate; local literal keeps cmd
/// free of net/sim imports — see the module docs).
pub const max_name_len: usize = 16;

/// Vanilla "player not found" reply (one spelling across commands).
pub const unknown_player: []const u8 = "That player cannot be found";

/// Resolve a player token to its login name (selectors included).
/// Null when vanilla would reply unknown_player — the caller returns
/// that const. `target` is a `[max_name_len]u8` scratch buffer.
pub fn resolveTarget(srv: anytype, sender: anytype, tok: []const u8, target: *[max_name_len]u8) ?[]const u8 {
    return srv.resolvePlayerName(sender, tok, target);
}

/// Sender's login name ("" for console). Backend-agnostic: only needs
/// `lock`, `username`, `username_len` like today's Conn. Accepts both
/// `?*Conn` and `*Conn`.
pub fn senderName(sender: anytype, out: *[max_name_len]u8) []const u8 {
    const c = switch (@typeInfo(@TypeOf(sender))) {
        .optional => sender orelse return "",
        else => sender,
    };
    c.lock.lock();
    defer c.lock.unlock();
    if (c.username_len == 0) return "";
    @memcpy(out[0..c.username_len], c.username[0..c.username_len]);
    return out[0..c.username_len];
}

test "define rejects bad defs" {
    // Valid defs compile (all real commands are exercised by the suite).
    // `comptime const`: the spec must be comptime-known for usage rendering
    // (real commands are `pub const def`, likewise comptime).
    const d = comptime define(.{
        .name = "ping",
        .node = "asteorite.command.ping",
        .min_level = .all,
        .spec = &.{&[_]Slot{}},
    });
    try std.testing.expectEqualStrings("ping", d.name);
    try std.testing.expectEqualStrings("/ping", d.usage());
    // Usage renders from the spec: required choice brackets, OR overloads.
    const t = comptime define(.{
        .name = "time",
        .node = "asteorite.command.time",
        .min_level = .gamemaster,
        .spec = &.{
            &[_]Slot{ Slot{ .arg = .{ .choice = &.{ "set", "add" } } }, Slot{ .arg = .{ .int_range = .{} }, .display = "<value>" } },
        },
    });
    try std.testing.expectEqualStrings("/time <set|add> <value>", t.usage());
    const tp = comptime define(.{
        .name = "tp",
        .node = "asteorite.command.tp",
        .min_level = .gamemaster,
        .spec = &.{
            &[_]Slot{Slot{ .arg = .{ .player = {} } }},
            &[_]Slot{ Slot{ .arg = .{ .player = {} } }, Slot{ .arg = .{ .player = {} } } },
        },
        .usage_override = "/tp [target player] <destination player> OR /tp [target player] <x> <y> <z>",
    });
    try std.testing.expectEqualStrings("/tp [target player] <destination player> OR /tp [target player] <x> <y> <z>", tp.usage());
}

test "splitArgs skips empties and caps at out.len" {
    var toks: [2][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), splitArgs("a  b c", &toks));
    try std.testing.expectEqualStrings("a", toks[0]);
    try std.testing.expectEqualStrings("b", toks[1]);
    try std.testing.expectEqual(@as(usize, 0), splitArgs("   ", &toks));
}

test "firstArg" {
    try std.testing.expectEqualStrings("a", firstArg("a b").?);
    try std.testing.expect(firstArg("") == null);
    try std.testing.expect(firstArg("   ") == null);
}
