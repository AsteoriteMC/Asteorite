//! 1.7 (proto v5) slot wire codec over the canonical item model.
//!
//! The ONLY place that knows the 1.7 slot byte layout (id i16, -1 = empty,
//! count i8, damage i16, NBT i16 length + gzip bytes, -1 = none). Gameplay
//! code speaks `item.Stack`; future versions add their own `proto/vXXX`
//! codec with the same shape — no game tables are duplicated here.

const std = @import("std");
const codec = @import("../../net/codec.zig");
const item = @import("../../item.zig");

/// Read one slot. NBT bytes are borrowed from the reader buffer (dupe via
/// `item.cloneStack` before storing past the current frame). Zero-length NBT
/// normalizes to null (no tag).
pub fn readSlot(r: *codec.PacketReader) codec.CodecError!?item.Stack {
    const id = try r.readShort();
    if (id == -1) return null;
    const count = @as(i8, @bitCast(try r.readByte()));
    const damage = try r.readShort();
    const nbt_len = try r.readShort();
    if (nbt_len < -1) return error.InvalidLength;
    const nbt: ?[]const u8 = if (nbt_len > 0) try r.readBytes(@intCast(nbt_len)) else null;
    return .{ .id = @as(u16, @bitCast(id)), .count = count, .damage = damage, .nbt = nbt };
}

/// Write one slot (NBT bytes verbatim, including empty; null NBT -> -1).
pub fn writeSlot(w: *codec.PacketWriter, s: ?item.Stack) codec.CodecError!void {
    const st = s orelse {
        try w.writeShort(-1);
        return;
    };
    try w.writeShort(@as(i16, @bitCast(st.id)));
    try w.writeByte(@as(u8, @bitCast(st.count)));
    try w.writeShort(st.damage);
    if (st.nbt) |n| {
        if (n.len == 0) {
            try w.writeShort(-1);
        } else {
            if (n.len > std.math.maxInt(i16)) return error.PacketTooLarge;
            try w.writeShort(@as(i16, @intCast(n.len)));
            try w.writeBytes(n);
        }
    } else {
        try w.writeShort(-1);
    }
}

test "slot roundtrip incl NBT bytes" {
    var buf: [64]u8 = undefined;
    var w = codec.PacketWriter.init(&buf);
    const nbt = [_]u8{ 0x0A, 0x00, 0x00, 0x09 };
    const s: ?item.Stack = .{ .id = 276, .count = 1, .damage = 0, .nbt = &nbt };
    try writeSlot(&w, s);
    try writeSlot(&w, null);
    var r = codec.PacketReader.init(w.written());
    const back = try readSlot(&r);
    try std.testing.expect(back != null);
    try std.testing.expect(item.stacksEqual(back, s));
    try std.testing.expect((try readSlot(&r)) == null);
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
    // zero-length NBT normalizes to null
    var b2: [32]u8 = undefined;
    var w2 = codec.PacketWriter.init(&b2);
    try writeSlot(&w2, .{ .id = 1, .count = 64, .damage = 0, .nbt = &.{} });
    var r2 = codec.PacketReader.init(w2.written());
    const back2 = (try readSlot(&r2)).?;
    try std.testing.expect(back2.nbt == null);
}
