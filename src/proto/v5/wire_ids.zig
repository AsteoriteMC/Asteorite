//! 1.7.10 (protocol v5) wire encodings for canonical ids.
//!
//! The single source of truth pairing each canonical `ids.Id` with its
//! on-the-wire u16 (jar registries: Block `aji.p`, Item `adb`).
//! All packet/world/anvil/player.dat conversion goes through here so the
//! rest of the codebase only ever speaks canonical ids.
//!
//! The mapping is five sequential runs separated by unassigned wire gaps
//! (which `fromWire` rejects as null):
//!
//! | canonical      | wire          | offset | note                    |
//! |----------------|---------------|--------|-------------------------|
//! | 0..164         | 0..164        | +0     | blocks incl. beacon     |
//! | 165..170       | 170..175      | +5     | skips wire 165..169     |
//! | 171..323       | 256..408      | +85    | items incl. hopper cart |
//! | 324..329       | 417..422      | +93    | skips wire 409..416     |
//! | 330..341       | 2256..2267    | +1926  | records; skips 423..2255|
//!
//! To add a protocol version: copy this file to the new proto/vNN dir
//! with that version's runs (see tools/ + minecraft-data).

const std = @import("std");
const ids = @import("../../ids.zig");

/// Canonical id -> v5 wire id. Total over `ids.COUNT`: every canonical id
/// has exactly one wire encoding.
/// Callers must only pass ids valid in the target context (e.g. a placeable
/// block for chunk storage); validation happens at parse boundaries.
pub fn toWire(id: ids.Id) u16 {
    const c: u16 = @intFromEnum(id);
    if (c <= 164) return c;
    if (c <= 170) return c + 5; // skip wire 165..169
    if (c <= 323) return c + 85; // 171 -> 256 ... 323 -> 408
    if (c <= 329) return c + 93; // skip wire 409..416: 324 -> 417 ... 329 -> 422
    if (c <= 341) return c + 1926; // skip wire 423..2255: 330 -> 2256 ... 341 -> 2267
    unreachable; // ids.COUNT is 342; canonical indices stop at 341
}

/// v5 wire id -> canonical id, or null for unassigned ranges (blocks
/// 165-169, items 409-416/423-2255/2268+, and anything above 2267).
pub fn fromWire(wire: u16) ?ids.Id {
    const c: u16 = if (wire <= 164)
        wire
    else if (wire >= 170 and wire <= 175)
        wire - 5
    else if (wire >= 256 and wire <= 408)
        wire - 85
    else if (wire >= 417 and wire <= 422)
        wire - 93
    else if (wire >= 2256 and wire <= 2267)
        wire - 1926
    else
        return null;
    return @enumFromInt(c);
}

test "wire mapping round-trips every id" {
    // canonical -> wire -> canonical is the identity
    for (0..ids.COUNT) |i| {
        const id: ids.Id = @enumFromInt(i);
        const w = toWire(id);
        try std.testing.expectEqual(id, fromWire(w).?);
    }
    // every wire id in an assigned range maps back to its table entry
    for (0..4096) |w| {
        const back = fromWire(@intCast(w));
        if (back) |id| {
            try std.testing.expectEqual(@as(u16, @intCast(w)), toWire(id));
        }
    }
    // unassigned ranges reject
    try std.testing.expect(fromWire(165) == null);
    try std.testing.expect(fromWire(169) == null);
    try std.testing.expect(fromWire(176) == null);
    try std.testing.expect(fromWire(255) == null);
    try std.testing.expect(fromWire(409) == null);
    try std.testing.expect(fromWire(423) == null);
    try std.testing.expect(fromWire(3000) == null);
    // spot checks against jar ground truth
    try std.testing.expectEqual(ids.stone, fromWire(1).?);
    try std.testing.expectEqual(ids.lit_furnace, fromWire(62).?);
    try std.testing.expectEqual(ids.iron_ingot, fromWire(265).?);
    try std.testing.expectEqual(ids.record_wait, fromWire(2267).?);
    try std.testing.expectEqual(@as(u16, 265), toWire(ids.iron_ingot));
    try std.testing.expectEqual(@as(u16, 62), toWire(ids.lit_furnace));
    // run-boundary pins: first/last of each segment
    try std.testing.expectEqual(@as(u16, 0), toWire(ids.air));
    try std.testing.expectEqual(@as(u16, 164), toWire(@enumFromInt(164)));
    try std.testing.expectEqual(@as(u16, 170), toWire(@enumFromInt(165)));
    try std.testing.expectEqual(@as(u16, 175), toWire(ids.double_plant));
    try std.testing.expectEqual(@as(u16, 256), toWire(ids.iron_shovel));
    try std.testing.expectEqual(@as(u16, 408), toWire(ids.hopper_minecart));
    try std.testing.expectEqual(@as(u16, 417), toWire(ids.iron_horse_armor));
    try std.testing.expectEqual(@as(u16, 422), toWire(ids.command_block_minecart));
    try std.testing.expectEqual(@as(u16, 2256), toWire(ids.record_13));
}
