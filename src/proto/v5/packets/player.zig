//! 1.7.10 client -> server player input packets (movement, digging, placement, actions).

const std = @import("std");
const codec = @import("../../../net/codec.zig");
const item_mod = @import("../../../item.zig");
const slot_mod = @import("../slot.zig");
const game_ids = @import("../../../ids.zig");
const wire = @import("../wire_ids.zig");


pub fn parseKeepAlive(body: []const u8) codec.CodecError!i32 {
    var r = codec.PacketReader.init(body);
    return try r.readInt();
}


/// Serverbound 0x03 flying.
pub fn parseFlying(body: []const u8) codec.CodecError!bool {
    var r = codec.PacketReader.init(body);
    return try r.readBool();
}


/// Serverbound 0x04 position. Wire order (jar `jf.a(et)`, `nh.a(jd)`):
/// x, FEET y, stance (eye height = feet + 1.62), z. The stance double is
/// consumed and unused (the server only tracks feet).
pub fn parsePosition(body: []const u8) codec.CodecError!struct { x: f64, y: f64, z: f64, on_ground: bool } {
    var r = codec.PacketReader.init(body);
    const x = try r.readDouble();
    const y = try r.readDouble(); // feet
    _ = try r.readDouble(); // stance (eye height)
    const z = try r.readDouble();
    return .{ .x = x, .y = y, .z = z, .on_ground = try r.readBool() };
}


/// Serverbound 0x05 look.
pub fn parseLook(body: []const u8) codec.CodecError!struct { yaw: f32, pitch: f32, on_ground: bool } {
    var r = codec.PacketReader.init(body);
    const yaw = try r.readFloat();
    const pitch = try r.readFloat();
    return .{ .yaw = yaw, .pitch = pitch, .on_ground = try r.readBool() };
}


/// Serverbound 0x06 position+look. Same wire order as 0x04: x, FEET y,
/// stance, z, yaw, pitch, on_ground.
pub fn parsePositionLook(body: []const u8) codec.CodecError!struct { x: f64, y: f64, z: f64, yaw: f32, pitch: f32, on_ground: bool } {
    var r = codec.PacketReader.init(body);
    const x = try r.readDouble();
    const y = try r.readDouble(); // feet
    _ = try r.readDouble(); // stance (eye height)
    const z = try r.readDouble();
    const yaw = try r.readFloat();
    const pitch = try r.readFloat();
    return .{ .x = x, .y = y, .z = z, .yaw = yaw, .pitch = pitch, .on_ground = try r.readBool() };
}


/// Serverbound 0x15 client settings.
pub fn parseClientSettings(body: []const u8) codec.CodecError!struct { locale: []const u8, view_distance: i8, chat_flags: i8, chat_colors: bool, difficulty: u8, show_cape: bool } {
    var r = codec.PacketReader.init(body);
    const locale = try r.readString();
    const view_distance = try r.readByte();
    const chat_flags = try r.readByte();
    const chat_colors = try r.readBool();
    // difficulty is u8 in 1.7.10 (proto.yml), show_cape bool
    const difficulty = try r.readByte();
    const show_cape = try r.readBool();
    return .{
        .locale = locale,
        .view_distance = @as(i8, @bitCast(view_distance)),
        .chat_flags = @as(i8, @bitCast(chat_flags)),
        .chat_colors = chat_colors,
        .difficulty = difficulty,
        .show_cape = show_cape,
    };
}


/// Serverbound 0x16 client status: 0 = respawn, 1 = request stats.
pub fn parseClientStatus(body: []const u8) codec.CodecError!i8 {
    var r = codec.PacketReader.init(body);
    return @as(i8, @bitCast(try r.readByte()));
}


/// 1.7 slot: id i16 (-1 = empty, nothing follows), else count i8,
/// damage i16, NBT (i16 length + gzip bytes, -1 = none).
pub const SlotItem = struct { id: i16, count: i8, damage: i16 };


/// Legacy parse kept for placement-packet validation. The single canonical
/// implementation lives in `slot.zig`; this drops NBT for old callers
/// (placement re-reads the held stack from the inventory instead).
pub fn parseSlot(r: *codec.PacketReader) codec.CodecError!?SlotItem {
    const st = try slot_mod.readSlot(r) orelse return null;
    return .{ .id = @as(i16, @bitCast(wire.toWire(st.id))), .count = st.count, .damage = st.damage };
}


/// Serverbound 0x07 digging: status, x, y(u8), z, face.
pub fn parseDigging(body: []const u8) codec.CodecError!struct { status: i8, x: i32, y: u8, z: i32, face: i8 } {
    var r = codec.PacketReader.init(body);
    const status = @as(i8, @bitCast(try r.readByte()));
    const x = try r.readInt();
    const y = try r.readByte();
    const z = try r.readInt();
    const face = @as(i8, @bitCast(try r.readByte()));
    return .{ .status = status, .x = x, .y = y, .z = z, .face = face };
}


/// Serverbound 0x08 placement. NBT in held item is skipped.
pub fn parsePlacement(body: []const u8) codec.CodecError!struct {
    x: i32,
    y: u8,
    z: i32,
    direction: i8,
    held: ?SlotItem,
    cursor_x: i8,
    cursor_y: i8,
    cursor_z: i8,
} {
    var r = codec.PacketReader.init(body);
    const x = try r.readInt();
    const y = try r.readByte();
    const z = try r.readInt();
    const direction = @as(i8, @bitCast(try r.readByte()));
    const held = try parseSlot(&r);
    const cx = @as(i8, @bitCast(try r.readByte()));
    const cy = @as(i8, @bitCast(try r.readByte()));
    const cz = @as(i8, @bitCast(try r.readByte()));
    return .{ .x = x, .y = y, .z = z, .direction = direction, .held = held, .cursor_x = cx, .cursor_y = cy, .cursor_z = cz };
}


/// Serverbound 0x09 held slot (i16 on the wire in 1.7).
pub fn parseHeldSlot(body: []const u8) codec.CodecError!i16 {
    var r = codec.PacketReader.init(body);
    return try r.readShort();
}


/// Serverbound 0x0B entity action: eid + action + jump boost. Vanilla ids:
/// 1 start sneak, 2 stop sneak, 3 leave bed, 4 start sprint, 5 stop sprint
/// (CFR `nh.a(jj)`). Only sprint (4/5) matters for hunger so far.
pub fn parseEntityAction(body: []const u8) codec.CodecError!struct { entity_id: i32, action: i8 } {
    var r = codec.PacketReader.init(body);
    const eid = try r.readInt();
    const action = @as(i8, @bitCast(try r.readByte()));
    _ = try r.readInt(); // jump boost (used by horses; no riding yet)
    return .{ .entity_id = eid, .action = action };
}

/// Serverbound 0x0A arm animation.
pub fn parseArmAnimation(body: []const u8) codec.CodecError!struct { entity_id: i32, animation: i8 } {
    var r = codec.PacketReader.init(body);
    const eid = try r.readInt();
    const anim = @as(i8, @bitCast(try r.readByte()));
    return .{ .entity_id = eid, .animation = anim };
}


/// Serverbound 0x02 use entity. Verified against minecraft-data 1.7:
/// target i32, mouse i8 (0 interact, 1 attack, 2 interact-at), x/y/z f32
/// present only when mouse == 2.
pub fn parseUseEntity(body: []const u8) codec.CodecError!struct { target: i32, mouse: i8, x: f32, y: f32, z: f32 } {
    var r = codec.PacketReader.init(body);
    const target = try r.readInt();
    const mouse = @as(i8, @bitCast(try r.readByte()));
    var x: f32 = 0;
    var y: f32 = 0;
    var z: f32 = 0;
    if (mouse == 2) {
        x = try r.readFloat();
        y = try r.readFloat();
        z = try r.readFloat();
    }
    return .{ .target = target, .mouse = mouse, .x = x, .y = y, .z = z };
}


/// Serverbound 0x10 creative inventory action. NBT preserved (borrowed —
/// clone via `item.cloneStack` before storing past the current frame).
/// Backed by the single v5 slot codec (no duplicated format logic).
pub fn parseCreativeSlot(body: []const u8) codec.CodecError!struct { slot: i16, item: ?item_mod.Stack } {
    var r = codec.PacketReader.init(body);
    const slot = try r.readShort();
    const item = try slot_mod.readSlot(&r);
    return .{ .slot = slot, .item = item };
}


/// Serverbound 0x0E click window. Verified against minecraft-data 1.7:
/// windowId i8, slot i16, mouseButton i8, action i16, mode i8, clicked item
/// (full slot incl. NBT). The clicked-item echo is read and validated
/// against server state in conn.zig (desync -> resync, never trust).
/// Modes: 0 pickup/place/swap, 1 shift-move, 2 number-key swap, 3 creative
/// pick (ignored survival-side), 4 drop (no-op: no item entities yet),
/// 5 drag (no-op), 6 collect (no-op).
pub fn parseClickWindow(body: []const u8) codec.CodecError!struct {
    window: i8,
    slot: i16,
    button: i8,
    action: i16,
    mode: i8,
    clicked: ?item_mod.Stack,
} {
    var r = codec.PacketReader.init(body);
    const window = @as(i8, @bitCast(try r.readByte()));
    const slot = try r.readShort();
    const button = @as(i8, @bitCast(try r.readByte()));
    const action = try r.readShort();
    const mode = @as(i8, @bitCast(try r.readByte()));
    const clicked = try slot_mod.readSlot(&r);
    return .{ .window = window, .slot = slot, .button = button, .action = action, .mode = mode, .clicked = clicked };
}


/// Serverbound 0x0D close window (windowId u8).
pub fn parseCloseWindow(body: []const u8) codec.CodecError!u8 {
    var r = codec.PacketReader.init(body);
    return try r.readByte();
}


/// Serverbound 0x11 enchant item (windowId u8, enchantment u8: 0/1/2 slot).
/// 1.7.10 has no lapis: the cost is the full shown level.
pub fn parseEnchantItem(body: []const u8) codec.CodecError!struct { window: u8, slot: u8 } {
    var r = codec.PacketReader.init(body);
    return .{ .window = try r.readByte(), .slot = try r.readByte() };
}


test "serverbound movement: wire order is x, feet, stance, z" {
    var b: [64]u8 = undefined;
    var w = codec.PacketWriter.init(&b);
    try w.writeDouble(1.5);
    try w.writeDouble(65.0); // feet
    try w.writeDouble(66.62); // stance = feet + 1.62, consumed
    try w.writeDouble(-7.25);
    try w.writeByte(0);
    const p = try parsePosition(w.written());
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), p.x, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 65.0), p.y, 1e-12);
    try std.testing.expect(!p.on_ground);
    try std.testing.expect(try parseFlying(&[_]u8{1}));
    try std.testing.expect(!(try parseFlying(&[_]u8{0})));
}


test "dig/place/held/arm/creative/serverbound roundtrips" {
    // digging
    {
        var b: [16]u8 = undefined;
        var w = codec.PacketWriter.init(&b);
        try w.writeByte(2);
        try w.writeInt(10);
        try w.writeByte(64);
        try w.writeInt(-3);
        try w.writeByte(1);
        const d = try parseDigging(w.written());
        try std.testing.expectEqual(@as(i8, 2), d.status);
        try std.testing.expectEqual(@as(i32, 10), d.x);
        try std.testing.expectEqual(@as(u8, 64), d.y);
        try std.testing.expectEqual(@as(i32, -3), d.z);
        try std.testing.expectEqual(@as(i8, 1), d.face);
    }
    // placement with NBT-bearing item (skipped)
    {
        var b: [64]u8 = undefined;
        var w = codec.PacketWriter.init(&b);
        try w.writeInt(7);
        try w.writeByte(65);
        try w.writeInt(8);
        try w.writeByte(1); // face +Y
        try w.writeShort(1); // stone
        try w.writeByte(3); // count
        try w.writeShort(2); // damage
        try w.writeShort(4); // nbt len
        try w.writeBytes(&[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });
        try w.writeByte(8); // cursor
        try w.writeByte(9);
        try w.writeByte(10);
        const p = try parsePlacement(w.written());
        try std.testing.expectEqual(@as(i8, 1), p.direction);
        try std.testing.expect(p.held != null);
        try std.testing.expectEqual(@as(i16, 1), p.held.?.id);
        try std.testing.expectEqual(@as(i8, 3), p.held.?.count);
    }
    // empty hand
    {
        var b: [32]u8 = undefined;
        var w = codec.PacketWriter.init(&b);
        try w.writeInt(0);
        try w.writeByte(64);
        try w.writeInt(0);
        try w.writeByte(255); // no face
        try w.writeShort(-1);
        try w.writeByte(0);
        try w.writeByte(0);
        try w.writeByte(0);
        const p = try parsePlacement(w.written());
        try std.testing.expect(p.held == null);
        try std.testing.expectEqual(@as(i8, -1), p.direction);
    }
    // held slot + arm + creative
    {
        var hb: [2]u8 = undefined;
        var hw = codec.PacketWriter.init(&hb);
        try hw.writeShort(5);
        try std.testing.expectEqual(@as(i16, 5), try parseHeldSlot(hw.written()));
        var ab: [8]u8 = undefined;
        var aw = codec.PacketWriter.init(&ab);
        try aw.writeInt(42);
        try aw.writeByte(0);
        const an = try parseArmAnimation(aw.written());
        try std.testing.expectEqual(@as(i32, 42), an.entity_id);
        var cb: [16]u8 = undefined;
        var cw = codec.PacketWriter.init(&cb);
        try cw.writeShort(37);
        try cw.writeShort(3); // dirt
        try cw.writeByte(64);
        try cw.writeShort(0);
        try cw.writeShort(-1); // no nbt
        const cs = try parseCreativeSlot(cw.written());
        try std.testing.expectEqual(@as(i16, 37), cs.slot);
        try std.testing.expectEqual(game_ids.dirt, cs.item.?.id);
        try std.testing.expect(cs.item.?.nbt == null);
        // nbt len 0 and -2 are tolerated/rejected
        var zb: [16]u8 = undefined;
        var zw = codec.PacketWriter.init(&zb);
        try zw.writeShort(30);
        try zw.writeShort(5);
        try zw.writeByte(1);
        try zw.writeShort(7);
        try zw.writeShort(0); // zero-length nbt
        try zw.writeShort(0);
        const zs = try parseCreativeSlot(zw.written());
        try std.testing.expect(zs.item != null);
        try std.testing.expect(zs.item.?.nbt == null);
        // real NBT bytes are preserved (borrowed)
        var nb: [32]u8 = undefined;
        var nw = codec.PacketWriter.init(&nb);
        try nw.writeShort(36);
        try nw.writeShort(276);
        try nw.writeByte(1);
        try nw.writeShort(0);
        const tag = [_]u8{ 0x0A, 0x00, 0x04, 0x64, 0x75, 0x6D, 0x6D, 0x79, 0x00 };
        try nw.writeShort(@as(i16, @intCast(tag.len)));
        try nw.writeBytes(&tag);
        const ns = try parseCreativeSlot(nw.written());
        try std.testing.expectEqualSlices(u8, &tag, ns.item.?.nbt.?);
    }
}


// ---------- tab completion (serverbound 0x14, clientbound 0x3A) ----------

/// Serverbound 0x14 text (vanilla cap 32767 chars — same as chat).
pub fn parseTabComplete(body: []const u8) codec.CodecError![]const u8 {
    var r = codec.PacketReader.init(body);
    return try r.readString();
}


test "entity action parse (sprint start/stop)" {
    var ab: [16]u8 = undefined;
    var w = codec.PacketWriter.init(&ab);
    try w.writeInt(7);
    try w.writeByte(4); // start sprint
    try w.writeInt(0); // jump boost
    const a = try parseEntityAction(w.written());
    try std.testing.expectEqual(@as(i32, 7), a.entity_id);
    try std.testing.expectEqual(@as(i8, 4), a.action);
}


test "use entity parse (attack vs interact-at)" {
    var ab: [16]u8 = undefined;
    var w = codec.PacketWriter.init(&ab);
    try w.writeInt(99);
    try w.writeByte(1); // attack: no trailing coords
    const a = try parseUseEntity(w.written());
    try std.testing.expectEqual(@as(i32, 99), a.target);
    try std.testing.expectEqual(@as(i8, 1), a.mouse);
    var ib: [32]u8 = undefined;
    var w2 = codec.PacketWriter.init(&ib);
    try w2.writeInt(7);
    try w2.writeByte(2); // interact-at: three f32s follow
    try w2.writeFloat(1.5);
    try w2.writeFloat(2.5);
    try w2.writeFloat(3.5);
    const b = try parseUseEntity(w2.written());
    try std.testing.expectEqual(@as(i32, 7), b.target);
    try std.testing.expectEqual(@as(i8, 2), b.mouse);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), b.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), b.y, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.5), b.z, 1e-6);
}


test "enchant item 0x11 parses window + slot" {
    var eb: [2]u8 = undefined;
    var w = codec.PacketWriter.init(&eb);
    try w.writeByte(4); // window 4
    try w.writeByte(2); // bottom offer
    const e = try parseEnchantItem(w.written());
    try std.testing.expectEqual(@as(u8, 4), e.window);
    try std.testing.expectEqual(@as(u8, 2), e.slot);
    // truncated body fails closed
    try std.testing.expectError(error.BufferUnderflow, parseEnchantItem(&[_]u8{4}));
}
