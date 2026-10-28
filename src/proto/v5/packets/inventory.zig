//! 1.7.10 inventory window packets (open/close/progress/set-slot/window-items).

const std = @import("std");
const codec = @import("../../../net/codec.zig");
const ids = @import("../ids.zig");
const item_mod = @import("../../../item.zig");
const slot_mod = @import("../slot.zig");
const game_ids = @import("../../../ids.zig");


/// Set Slot 0x2F (slot -1 = cursor). Item encoded by the v5 slot codec
/// (NBT verbatim), so enchanted/named items survive server round-trips.
/// Heap-allocated: NBT is attacker-controlled up to the frame limit, so no
/// fixed stack buffer is safe. Rare UI packet — caller frees.
pub fn frameSetSlotAlloc(alloc: std.mem.Allocator, window: i8, slot: i16, item: ?item_mod.Stack) ![]u8 {
    const nbt_len: usize = if (item) |s| (if (s.nbt) |n| n.len else 0) else 0;
    // payload: window(1) + slot(2) + slot-bytes(2+1+2+2+nbt)
    const payload = try alloc.alloc(u8, 1 + 2 + 7 + nbt_len);
    defer alloc.free(payload);
    var w = codec.PacketWriter.init(payload);
    try w.writeByte(@bitCast(window));
    try w.writeShort(slot);
    try slot_mod.writeSlot(&w, item);
    const id = @intFromEnum(ids.PlayClient.set_slot);
    const out = try alloc.alloc(u8, codec.PacketWriter.varIntLen(id) + codec.PacketWriter.varIntLen(@as(i32, @intCast(w.written().len + codec.PacketWriter.varIntLen(id)))) + w.written().len);
    errdefer alloc.free(out);
    const f = try codec.framePacket(id, w.written(), out);
    const owned = try alloc.dupe(u8, f);
    alloc.free(out);
    return owned;
}


/// Window Items 0x30: full window contents (used for desync resyncs).
/// Same heap discipline as frameSetSlotAlloc.
pub fn frameWindowItemsAlloc(alloc: std.mem.Allocator, window: u8, items: []const ?item_mod.Stack) ![]u8 {
    var nbt_total: usize = 0;
    for (items) |it| {
        if (it) |s| {
            if (s.nbt) |n| nbt_total += n.len;
        }
    }
    const payload = try alloc.alloc(u8, 1 + 2 + items.len * 7 + nbt_total);
    defer alloc.free(payload);
    var w = codec.PacketWriter.init(payload);
    try w.writeByte(window);
    if (items.len > std.math.maxInt(i16)) return error.PacketTooLarge;
    try w.writeShort(@as(i16, @intCast(items.len)));
    for (items) |it| try slot_mod.writeSlot(&w, it);
    const id = @intFromEnum(ids.PlayClient.window_items);
    const out = try alloc.alloc(u8, codec.PacketWriter.varIntLen(id) + codec.PacketWriter.varIntLen(@as(i32, @intCast(w.written().len + codec.PacketWriter.varIntLen(id)))) + w.written().len);
    errdefer alloc.free(out);
    const f = try codec.framePacket(id, w.written(), out);
    const owned = try alloc.dupe(u8, f);
    alloc.free(out);
    return owned;
}


/// Open Window 0x2D (crafting table = type 1, 9 slots; title + slot count).
/// use_provided_title is always true here (vanilla sends the container name).
pub fn frameOpenWindow(window: u8, inv_type: u8, title: []const u8, slot_count: u8, use_provided: bool, out: []u8) codec.CodecError![]const u8 {
    var payload: [128]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeByte(window);
    try w.writeByte(inv_type);
    try w.writeString(title);
    try w.writeByte(slot_count);
    // Vanilla sends (unlocalized key, false) for every default block
    // container — the client localizes ("container.enderchest" -> "Ender
    // Chest", including non-English langs). `true` renders the string
    // literally (only for custom-named containers, which 1.7.10 blocks
    // never produce — hardcoding true showed raw keys like
    // "container.enderchest" as the window title).
    try w.writeByte(if (use_provided) 1 else 0);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.open_window), w.written(), out);
}


/// Close Window 0x2E (clientbound ack so the client drops its container UI).
pub fn frameCloseWindow(window: u8, out: []u8) codec.CodecError![]const u8 {
    var payload: [2]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeByte(window);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.close_window), w.written(), out);
}


/// Window Property 0x31 (craft progress bar): window id + property + value.
/// Furnace properties: 0 = burn time left, 1 = cook progress, 2 = burn total.
pub fn frameProgressBar(window: u8, property: i16, value: i16, out: []u8) codec.CodecError![]const u8 {
    var payload: [8]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeByte(window);
    try w.writeShort(property);
    try w.writeShort(value);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.window_property), w.written(), out);
}

test "open window carries the jar S2D tail flag" {
    // Jar `gn` reads ubyte, ubyte, string, ubyte, boolean. Default block
    // containers send (unlocalized key, false) so the client localizes
    // ("container.enderchest" -> "Ender Chest"); `true` renders literally.
    var ob: [128]u8 = undefined;
    const f = try frameOpenWindow(3, 0, "container.enderchest", 27, false, &ob);
    var r = codec.PacketReader.init(f);
    try std.testing.expectEqual(@as(i32, 0x2D), (try codec.decodeFrame(&r)).id);
    try std.testing.expectEqual(@as(u8, 3), try r.readByte());
    try std.testing.expectEqual(@as(u8, 0), try r.readByte());
    try std.testing.expectEqualStrings("container.enderchest", try r.readString());
    try std.testing.expectEqual(@as(u8, 27), try r.readByte());
    try std.testing.expectEqual(@as(u8, 0), try r.readByte());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
    const g = try frameOpenWindow(1, 1, "container.crafting", 9, false, &ob);
    var r2 = codec.PacketReader.init(g);
    try std.testing.expectEqual(@as(i32, 0x2D), (try codec.decodeFrame(&r2)).id);
    try std.testing.expectEqualStrings("container.crafting", blk: {
        _ = try r2.readByte();
        _ = try r2.readByte();
        break :blk try r2.readString();
    });
}


test "click window parse + set slot / window items roundtrip" {
    const player = @import("player.zig");
    // 0x0E: window i8, slot i16, button i8, action i16, mode i8, item slot
    var cb: [32]u8 = undefined;
    var cw = codec.PacketWriter.init(&cb);
    try cw.writeByte(0); // window 0
    try cw.writeShort(12); // slot
    try cw.writeByte(1); // right button
    try cw.writeShort(7); // action number
    try cw.writeByte(0); // pickup mode
    try cw.writeShort(-1); // empty clicked slot
    const c = try player.parseClickWindow(cw.written());
    try std.testing.expectEqual(@as(i8, 0), c.window);
    try std.testing.expectEqual(@as(i16, 12), c.slot);
    try std.testing.expectEqual(@as(i8, 1), c.button);
    try std.testing.expectEqual(@as(i16, 7), c.action);
    try std.testing.expectEqual(@as(i8, 0), c.mode);
    try std.testing.expect(c.clicked == null);
    try std.testing.expectEqual(@as(u8, 0x0D), @intFromEnum(ids.PlayServer.close_window));
    // 0x2F roundtrip incl NBT, then 0x30 full window
    const tag = [_]u8{ 0x0A, 0x00, 0x01, 0x58 };
    const item: ?item_mod.Stack = .{ .id = game_ids.diamond_sword, .count = 1, .damage = 0, .nbt = &tag };
    const sf = try frameSetSlotAlloc(std.testing.allocator, 0, 36, item);
    defer std.testing.allocator.free(sf);
    var r = codec.PacketReader.init(sf);
    try std.testing.expectEqual(@as(i32, 0x2F), (try codec.decodeFrame(&r)).id);
    try std.testing.expectEqual(@as(i8, 0), @as(i8, @bitCast(try r.readByte())));
    try std.testing.expectEqual(@as(i16, 36), try r.readShort());
    try std.testing.expectEqual(@as(i16, 276), try r.readShort()); // wire id, not canonical
    try std.testing.expectEqual(@as(i8, 1), @as(i8, @bitCast(try r.readByte())));
    try std.testing.expectEqual(@as(i16, 0), try r.readShort());
    try std.testing.expectEqual(@as(i16, 4), try r.readShort());
    try std.testing.expectEqualSlices(u8, &tag, try r.readBytes(4));
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
    // cursor lives on window -1 per the vanilla rule (window 0/slot -1
    // crashes 1.7.10: Container.getSlot(-1) -> AIOOBE). Empty slot encodes.
    const cur = try frameSetSlotAlloc(std.testing.allocator, -1, -1, null);
    defer std.testing.allocator.free(cur);
    var r2 = codec.PacketReader.init(cur);
    try std.testing.expectEqual(@as(i32, 0x2F), (try codec.decodeFrame(&r2)).id);
    try std.testing.expectEqual(@as(i8, -1), @as(i8, @bitCast(try r2.readByte())));
    try std.testing.expectEqual(@as(i16, -1), try r2.readShort());
    try std.testing.expectEqual(@as(i16, -1), try r2.readShort());
    const items = [_]?item_mod.Stack{ item, null };
    const wf = try frameWindowItemsAlloc(std.testing.allocator, 0, &items);
    defer std.testing.allocator.free(wf);
    var r3 = codec.PacketReader.init(wf);
    try std.testing.expectEqual(@as(i32, 0x30), (try codec.decodeFrame(&r3)).id);
    try std.testing.expectEqual(@as(u8, 0), try r3.readByte());
    try std.testing.expectEqual(@as(i16, 2), try r3.readShort());
    try std.testing.expectEqual(@as(i16, 276), try r3.readShort());
}
