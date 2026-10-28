//! Server list ping (status) payload.
//!
//! The old code `bufPrint`ed raw JSON inline in `Conn.handleStatus` — which
//! breaks the moment the MOTD contains a quote, and hardcodes a vanilla
//! shape. This module stringifies a real struct instead, with a `Brand`
//! switch for the handshake the server advertises:
//!
//! - vanilla: `{"description","players","version"}` (1.7.10 shape).
//! - fabric: byte-identical to vanilla today (no 1.7.10-era status
//!   marker exists); the enum reserves the slot so the future modding API
//!   can attach loader brand/version without touching this path again.
//! - forge: adds FML `"modinfo":{"type":"FML","modList":[...]}`. The list
//!   is empty until the modding API registers mods — each entry is
//!   `{modid, version}` exactly as FML clients parse it.
//!
//! Serialization goes through `std.json.Stringify` (correct escaping) with
//! `emit_null_optional_fields = false`, so vanilla/fabric never carry a
//! `"modinfo":null`.

const std = @import("std");
const version = @import("../version.zig");

/// Which server software the status handshake advertises.
pub const Brand = enum {
    vanilla,
    fabric,
    forge,

    /// CLI/config spelling. Accepts `fml` as the common alias for forge.
    pub fn parse(s: []const u8) !Brand {
        if (std.mem.eql(u8, s, "vanilla")) return .vanilla;
        if (std.mem.eql(u8, s, "fabric")) return .fabric;
        if (std.mem.eql(u8, s, "forge") or std.mem.eql(u8, s, "fml")) return .forge;
        return error.UnknownBrand;
    }

    pub fn name(self: Brand) []const u8 {
        return @tagName(self);
    }
};

/// One FML modList entry. Reserved for the modding API (H-modding); the
/// status path just renders whatever is registered.
pub const ModEntry = struct {
    modid: []const u8,
    version: []const u8,
};

/// Everything the status JSON needs; counts are filled in live by the
/// caller (serve thread), mods by the future modding API.
pub const StatusPayload = struct {
    motd: []const u8,
    max_players: u16,
    online_players: u16,
    brand: Brand = .vanilla,
    mods: []const ModEntry = &.{},
    version_name: []const u8 = version.meta.name,
    protocol: i32 = version.meta.protocol,
};

/// Serialize to a freshly allocated JSON string (caller frees).
pub fn writeJson(alloc: std.mem.Allocator, p: StatusPayload) ![]u8 {
    const WirePlayers = struct {
        max: u16,
        online: u16,
    };
    const WireVersion = struct {
        name: []const u8,
        protocol: i32,
    };
    const WireDesc = struct {
        text: []const u8,
    };
    const WireModInfo = struct {
        type: []const u8,
        modList: []const ModEntry,
    };
    const Wire = struct {
        description: WireDesc,
        players: WirePlayers,
        version: WireVersion,
        modinfo: ?WireModInfo = null,
    };
    const wire = Wire{
        .description = .{ .text = p.motd },
        .players = .{ .max = p.max_players, .online = p.online_players },
        .version = .{ .name = p.version_name, .protocol = p.protocol },
        .modinfo = if (p.brand == .forge) .{ .type = "FML", .modList = p.mods } else null,
    };
    return std.json.Stringify.valueAlloc(alloc, wire, .{ .emit_null_optional_fields = false });
}

test "vanilla status is the exact 1.7.10 shape" {
    const alloc = std.testing.allocator;
    const js = try writeJson(alloc, .{ .motd = "Asteorite", .max_players = 20, .online_players = 3 });
    defer alloc.free(js);
    try std.testing.expectEqualStrings(
        \\{"description":{"text":"Asteorite"},"players":{"max":20,"online":3},"version":{"name":"1.7.10","protocol":5}}
    , js);
}

test "status version defaults come from the selected profile" {
    const p = StatusPayload{ .motd = "x", .max_players = 1, .online_players = 0 };
    try std.testing.expectEqualStrings(version.meta.name, p.version_name);
    try std.testing.expectEqual(version.meta.protocol, p.protocol);
}

test "fabric status matches vanilla bytes (no 1.7.10 marker)" {
    const alloc = std.testing.allocator;
    const js = try writeJson(alloc, .{ .motd = "x", .max_players = 1, .online_players = 0, .brand = .fabric });
    defer alloc.free(js);
    try std.testing.expectEqualStrings(
        \\{"description":{"text":"x"},"players":{"max":1,"online":0},"version":{"name":"1.7.10","protocol":5}}
    , js);
}

test "forge status carries empty FML modinfo" {
    const alloc = std.testing.allocator;
    const js = try writeJson(alloc, .{ .motd = "x", .max_players = 1, .online_players = 0, .brand = .forge });
    defer alloc.free(js);
    try std.testing.expectEqualStrings(
        \\{"description":{"text":"x"},"players":{"max":1,"online":0},"version":{"name":"1.7.10","protocol":5},"modinfo":{"type":"FML","modList":[]}}
    , js);
}

test "forge modinfo renders registered mods for the future modding API" {
    const alloc = std.testing.allocator;
    const mods = [_]ModEntry{
        .{ .modid = "examplemod", .version = "1.0" },
        .{ .modid = "anothermod", .version = "2.3.1" },
    };
    const js = try writeJson(alloc, .{ .motd = "x", .max_players = 1, .online_players = 0, .brand = .forge, .mods = &mods });
    defer alloc.free(js);
    try std.testing.expectEqualStrings(
        \\{"description":{"text":"x"},"players":{"max":1,"online":0},"version":{"name":"1.7.10","protocol":5},"modinfo":{"type":"FML","modList":[{"modid":"examplemod","version":"1.0"},{"modid":"anothermod","version":"2.3.1"}]}}
    , js);
}

test "motd with quotes round-trips as valid JSON (raw bufPrint used to break)" {
    const alloc = std.testing.allocator;
    const js = try writeJson(alloc, .{ .motd = "say \"hi\"\nbye", .max_players = 20, .online_players = 0 });
    defer alloc.free(js);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, js, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("say \"hi\"\nbye", parsed.value.object.get("description").?.object.get("text").?.string);
}

test "brand parsing accepts the fml alias, rejects junk" {
    try std.testing.expectEqual(Brand.vanilla, try Brand.parse("vanilla"));
    try std.testing.expectEqual(Brand.fabric, try Brand.parse("fabric"));
    try std.testing.expectEqual(Brand.forge, try Brand.parse("forge"));
    try std.testing.expectEqual(Brand.forge, try Brand.parse("fml"));
    try std.testing.expectError(error.UnknownBrand, Brand.parse("Forge"));
    try std.testing.expectError(error.UnknownBrand, Brand.parse(""));
}
