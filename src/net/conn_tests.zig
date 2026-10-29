//! Conn behavior tests: framing, login flow, play dispatch, inventory.
//!
//! Extracted from `conn.zig` (which keeps the state machine itself) so the
//! protocol core stays readable. Reaches the three window/position helpers
//! (`onPlace`, `refreshTable`, `setPos`) through their public API.

const std = @import("std");
const conn_mod = @import("conn.zig");
const profile = @import("../version.zig");

const Conn = conn_mod.Conn;
const Config = conn_mod.Config;
const Action = conn_mod.Action;

const codec = @import("codec.zig");
const packets = @import("../proto/v5/packets.zig");
const item_mod = @import("../item.zig");
const cfb8 = @import("cfb8.zig");
const rsa_mod = @import("rsa.zig");
const game_ids = @import("../ids.zig");

/// Test conn with the testing allocator/io (one site instead of ~26
/// `Conn.init(a, std.testing.io, ...)` repetitions). Tests needing a
/// custom Io (the online-mode mock) still call Conn.init directly.
fn mkConn(cfg: Config, eid: i32) Conn {
    return Conn.init(std.testing.allocator, std.testing.io, cfg, eid);
}

test "Phase B: the outbox cap marks the conn for a backpressure kick" {
    var c = mkConn(.{ .out_cap_bytes = 1024 }, 1);
    defer c.deinit();
    // Fill the outbox past the cap.
    var payload: [200]u8 = undefined;
    var framed: [256]u8 = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const f = try codec.framePacket(0x02, &payload, &framed);
        try c.queueFramed(f);
    }
    try std.testing.expect(c.overflow);
    try std.testing.expect(c.out.items.len > 1024);
    // Under the cap: no overflow.
    var c2 = mkConn(.{ .out_cap_bytes = 1 << 20 }, 2);
    defer c2.deinit();
    const f2 = try codec.framePacket(0x02, payload[0..10], &framed);
    try c2.queueFramed(f2);
    try std.testing.expect(!c2.overflow);
}

test "status flow with split feeds" {
    const a = std.testing.allocator;
    var c = mkConn(.{}, 1);
    defer c.deinit();
    // handshake -> status
    var hb: [64]u8 = undefined;
    var w = codec.PacketWriter.init(&hb);
    try w.writeVarInt(5);
    try w.writeString("localhost");
    try w.writeUShort(25565);
    try w.writeVarInt(1);
    var hf: [80]u8 = undefined;
    const hframe = try codec.framePacket(0x00, w.written(), &hf);
    // feed one byte at a time (TCP segmentation)
    var got_status = false;
    var i: usize = 0;
    while (i < hframe.len) : (i += 1) {
        try c.feedData(hframe[i .. i + 1]);
        while (try c.poll()) |f| {
            _ = try c.handleFrame(f);
            got_status = true;
        }
    }
    try std.testing.expect(got_status);
    try std.testing.expect(c.state == .status);
    // request
    var rq: [8]u8 = undefined;
    const rqframe = try codec.framePacket(0x00, &.{}, &rq);
    try c.feedData(rqframe);
    const f1 = (try c.poll()).?;
    _ = try c.handleFrame(f1);
    const out1 = try c.takeOutput();
    defer a.free(out1);
    var r = codec.PacketReader.init(out1);
    const h1 = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 0x00), h1.id);
    const js = try r.readString();
    try std.testing.expect(std.mem.indexOf(u8, js, "Asteorite") != null);
    // Structured payload (not raw bufPrint): parse and check fields.
    {
        const pv = try std.json.parseFromSlice(std.json.Value, a, js, .{});
        defer pv.deinit();
        const root = pv.value.object;
        try std.testing.expectEqualStrings("Asteorite", root.get("description").?.object.get("text").?.string);
        try std.testing.expectEqual(@as(i64, 20), root.get("players").?.object.get("max").?.integer);
        try std.testing.expectEqual(@as(i64, 0), root.get("players").?.object.get("online").?.integer);
        try std.testing.expectEqualStrings("1.7.10", root.get("version").?.object.get("name").?.string);
        try std.testing.expectEqual(@as(i64, 5), root.get("version").?.object.get("protocol").?.integer);
        try std.testing.expect(root.get("modinfo") == null);
    }
    // ping -> pong + close_after_flush
    var pg: [16]u8 = undefined;
    var pw: [8]u8 = undefined;
    std.mem.writeInt(i64, &pw, 987654321, .big);
    const pgframe = try codec.framePacket(0x01, &pw, &pg);
    try c.feedData(pgframe);
    const f2 = (try c.poll()).?;
    const act = try c.handleFrame(f2);
    try std.testing.expectEqual(Action.close_after_flush, act);
    const out2 = try c.takeOutput();
    defer a.free(out2);
    var r2 = codec.PacketReader.init(out2);
    _ = try codec.decodeFrame(&r2);
    try std.testing.expectEqual(@as(i64, 987654321), try packets.parsePing(r2.buffer[r2.index..]));
}

test "forge status carries FML modinfo; live count is used verbatim" {
    const a = std.testing.allocator;
    var c = mkConn(.{ .motd = "hi", .max_players = 50, .online_count = 7, .brand = .forge }, 1);
    defer c.deinit();
    var hb: [64]u8 = undefined;
    var w = codec.PacketWriter.init(&hb);
    try w.writeVarInt(5);
    try w.writeString("localhost");
    try w.writeUShort(25565);
    try w.writeVarInt(1);
    var hf: [80]u8 = undefined;
    try c.feedData(try codec.framePacket(0x00, w.written(), &hf));
    _ = try c.handleFrame((try c.poll()).?);
    var rq: [8]u8 = undefined;
    try c.feedData(try codec.framePacket(0x00, &.{}, &rq));
    _ = try c.handleFrame((try c.poll()).?);
    const out = try c.takeOutput();
    defer a.free(out);
    var r = codec.PacketReader.init(out);
    _ = try codec.decodeFrame(&r);
    const js = try r.readString();
    const pv = try std.json.parseFromSlice(std.json.Value, a, js, .{});
    defer pv.deinit();
    const root = pv.value.object;
    try std.testing.expectEqual(@as(i64, 7), root.get("players").?.object.get("online").?.integer);
    const modinfo = root.get("modinfo").?.object;
    try std.testing.expectEqualStrings("FML", modinfo.get("type").?.string);
    try std.testing.expectEqual(@as(usize, 0), modinfo.get("modList").?.array.items.len);
}

test "offline login -> play bootstrap" {
    const a = std.testing.allocator;
    var c = mkConn(.{}, 7);
    defer c.deinit();
    // handshake -> login
    var hb: [64]u8 = undefined;
    var w = codec.PacketWriter.init(&hb);
    try w.writeVarInt(5);
    try w.writeString("localhost");
    try w.writeUShort(25565);
    try w.writeVarInt(2);
    var hf: [80]u8 = undefined;
    try c.feedData(try codec.framePacket(0x00, w.written(), &hf));
    _ = try c.handleFrame((try c.poll()).?);
    try std.testing.expect(c.state == .login);
    // login start
    var lb: [32]u8 = undefined;
    var wl = codec.PacketWriter.init(&lb);
    try wl.writeString("testplayer");
    var lf: [48]u8 = undefined;
    try c.feedData(try codec.framePacket(0x00, wl.written(), &lf));
    const act = try c.handleFrame((try c.poll()).?);
    try std.testing.expectEqual(Action.entered_play, act);
    try std.testing.expect(c.state == .play);
    try std.testing.expectEqualStrings("testplayer", c.username[0..c.username_len]);
    const out = try c.takeOutput();
    defer a.free(out);
    // frames: LoginSuccess(0x02) JoinGame(0x01) SpawnPosition(0x05).
    // Chunks (view.completeLogin) then PlayerPosLook(0x08) close the login.
    var r = codec.PacketReader.init(out);
    const h0 = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 0x02), h0.id);
    try std.testing.expectEqualStrings("52d22a52-7b4a-339e-8a09-aa52384d72fd", try r.readString());
    try std.testing.expectEqualStrings("testplayer", try r.readString());
    const h1 = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 0x01), h1.id);
    const j = try packets.parseJoinGame(r.buffer[r.index..]);
    try std.testing.expectEqual(@as(i32, 7), j.eid);
    r.index += 4 + 1 + 1 + 1 + 1 + codec.PacketWriter.varIntLen(@intCast(j.level_type.len)) + j.level_type.len;
    const h2 = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 0x05), h2.id);
    r.index += 12;
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
    // login closer (normally after chunk bulks)
    try c.queuePlayerPosLook();
    const out2 = try c.takeOutput();
    defer a.free(out2);
    var r2 = codec.PacketReader.init(out2);
    const h3 = try codec.decodeFrame(&r2);
    try std.testing.expectEqual(@as(i32, 0x08), h3.id);
}

test "player position tracked (feet, not eye height), chunk computed" {
    var c = mkConn(.{}, 1);
    defer c.deinit();
    c.state = .play;
    c.baseline_sent = true; // position tracking is post-join (pre-burst moves don't adopt)
    // serverbound 0x06 position+look: x, FEET 65.0, stance 66.62, z
    var pb: [48]u8 = undefined;
    var w = codec.PacketWriter.init(&pb);
    try w.writeDouble(100.7);
    try w.writeDouble(65.0); // feet
    try w.writeDouble(66.62); // stance (eye)
    try w.writeDouble(-40.2);
    try w.writeFloat(90.0);
    try w.writeFloat(0.0);
    try w.writeByte(1);
    var pf: [64]u8 = undefined;
    try c.feedData(try codec.framePacket(0x06, w.written(), &pf));
    _ = try c.handleFrame((try c.poll()).?);
    try std.testing.expectApproxEqAbs(@as(f64, 100.7), c.pos_x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 65.0), c.pos_y, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 90.0), @as(f64, c.yaw), 1e-6);
    try std.testing.expect(c.on_ground);
    const cc = c.playerChunk();
    try std.testing.expectEqual(@as(i32, 6), cc.cx); // floor(100.7/16)
    try std.testing.expectEqual(@as(i32, -3), cc.cz); // floor(-40.2/16)
}

test "chat formats, rate-limits, and validates" {
    var c = mkConn(.{}, 1);
    defer c.deinit();
    c.state = .play;
    @memcpy(c.username[0.."Bo".len], "Bo");
    c.username_len = 2;
    const feed = struct {
        fn run(conn: *Conn, text: []const u8) !?Action {
            var sb: [256]u8 = undefined;
            var w = codec.PacketWriter.init(&sb);
            try w.writeString(text);
            var f: [300]u8 = undefined;
            try conn.feedData(try codec.framePacket(0x01, w.written(), &f));
            return try conn.handleFrame((try conn.poll()).?);
        }
    }.run;
    // first message formats JSON into chat_buf
    const act = try feed(&c, "hi <there>");
    try std.testing.expect(act.? == .chat);
    try std.testing.expectEqualStrings("{\"text\":\"<Bo> hi <there>\"}", c.chat_buf[0..act.?.chat.json_len]);
    // immediate second message: tolerated (stall-bunched pairs must not
    // kick); sustained floods still kick (burst cap 3 per window)
    c.last_chat_ms = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds();
    const act2 = try feed(&c, "again");
    try std.testing.expect(act2.? == .chat);
    // hammer inside the window: 4th rapid repeat kicks
    _ = try feed(&c, "m3");
    _ = try feed(&c, "m4");
    const act5 = try feed(&c, "m5");
    try std.testing.expectEqual(Action.disconnect_queued, act5.?);
    try std.testing.expect(c.close_after_flush);
}

test "chat drops invalid/overlong without kicking" {
    const a = std.testing.allocator;
    var c = mkConn(.{}, 1);
    defer c.deinit();
    c.state = .play;
    @memcpy(c.username[0.."Bo".len], "Bo");
    c.username_len = 2;
    // overlong (101 chars): dropped, no output, no kick
    var long: [101]u8 = [_]u8{'x'} ** 101;
    var lb: [256]u8 = undefined;
    var lw = codec.PacketWriter.init(&lb);
    try lw.writeString(&long);
    var lf: [300]u8 = undefined;
    try c.feedData(try codec.framePacket(0x01, lw.written(), &lf));
    try std.testing.expect((try c.handleFrame((try c.poll()).?)) == .none);
    const out = try c.takeOutput();
    defer a.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
    try std.testing.expect(!c.close_after_flush);
}

test "bad protocol disconnects" {
    var c = mkConn(.{}, 1);
    defer c.deinit();
    var hb: [64]u8 = undefined;
    var w = codec.PacketWriter.init(&hb);
    try w.writeVarInt(47); // 1.8, wrong
    try w.writeString("localhost");
    try w.writeUShort(25565);
    try w.writeVarInt(2);
    var hf: [80]u8 = undefined;
    try c.feedData(try codec.framePacket(0x00, w.written(), &hf));
    const act = try c.handleFrame((try c.poll()).?);
    try std.testing.expectEqual(Action.disconnect_queued, act);
    try std.testing.expect(c.close_after_flush);
}

test "play keepalive recorded" {
    const a = std.testing.allocator;
    var c = mkConn(.{}, 1);
    defer c.deinit();
    c.state = .play;
    var kb: [8]u8 = undefined;
    var w = codec.PacketWriter.init(&kb);
    try w.writeInt(777);
    var kf: [16]u8 = undefined;
    try c.feedData(try codec.framePacket(0x00, w.written(), &kf));
    _ = try c.handleFrame((try c.poll()).?);
    try std.testing.expectEqual(@as(i32, 777), c.last_keepalive);
    const out = try c.takeOutput();
    defer a.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "eat routing: food starts eating, never places" {
    // Right-click with food routes to the 32-tick use (never a block_set:
    // food ids are not blocks). Air clicks and block clicks both emit
    // .eat; the serve thread tries UI opens first for block clicks.
    var c = mkConn(.{ .gamemode = .survival, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 30);
    defer c.deinit();
    c.state = .play;
    c.inv[36] = .{ .id = game_ids.bread, .count = 3, .damage = 0, .nbt = null };
    c.selected = 0;
    {
        const act = c.onPlace(8, 64, 8, -1, 8);
        try std.testing.expect(act == .eat);
        try std.testing.expectEqual(@as(i8, -1), act.eat.face);
        try std.testing.expectEqual(@as(usize, 36), act.eat.slot);
        try std.testing.expectEqual(game_ids.bread, act.eat.id);
    }
    {
        const act = c.onPlace(8, 64, 8, 1, 8);
        try std.testing.expect(act == .eat);
        try std.testing.expectEqual(@as(i8, 1), act.eat.face);
    }
    // Stone still places; armor still equips; empty hand still nichts.
    c.inv[36] = .{ .id = game_ids.stone, .count = 64, .damage = 0, .nbt = null };
    {
        const act = c.onPlace(8, 64, 8, -1, 8);
        try std.testing.expect(act == .none);
    }
    {
        const act = c.onPlace(8, 64, 8, 1, 8);
        try std.testing.expect(act == .block_set);
    }
    // Cake item places the cake block (slice-eating is P-next).
    c.inv[36] = .{ .id = game_ids.cake_item, .count = 1, .damage = 0, .nbt = null };
    {
        const act = c.onPlace(8, 64, 8, 1, 8);
        try std.testing.expect(act == .block_set);
        try std.testing.expectEqual(game_ids.cake_block, act.block_set.id);
    }
    // Any fresh right-click aborts an in-progress meal (a food click
    // would restart it via a new .eat event).
    c.eating = .{ .slot = 36, .id = game_ids.bread, .damage = 0, .ticks = 30 };
    _ = c.onPlace(8, 64, 8, -1, 8);
    try std.testing.expect(c.eating == null);
}

test "eat finish: consume, heal, syncs, effects" {
    // 32-tick countdown then consume: bread x3 at food 10 -> x2, food 15,
    // slot + health syncs and the burp queued (no server needed).
    var c = mkConn(.{ .gamemode = .survival, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 31);
    defer c.deinit();
    c.state = .play;
    c.food = 10;
    c.saturation = 0;
    c.inv[36] = .{ .id = game_ids.bread, .count = 3, .damage = 0, .nbt = null };
    c.selected = 0;
    c.eating = .{ .slot = 36, .id = game_ids.bread, .damage = 0, .ticks = 32 };
    c.tickEating();
    try std.testing.expect(c.eating != null);
    try std.testing.expectEqual(@as(i8, 3), c.inv[36].?.count);
    c.tickEating();
    try std.testing.expect(c.eating == null);
    try std.testing.expectEqual(@as(i8, 2), c.inv[36].?.count);
    try std.testing.expectEqual(@as(i16, 15), c.food);
    // saturation: min(15, 0 + 5*0.6*2) = 6
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), c.saturation, 1e-4);
    {
        const out = try c.takeOutput();
        defer c.allocator.free(out);
        var seen_slot = false;
        var seen_health = false;
        var seen_sound = false;
        var r = codec.PacketReader.init(out);
        while (r.index < out.len) {
            const start = r.index;
            const ln = r.readVarInt() catch break;
            if (ln <= 0) break;
            const id = try r.readVarInt();
            if (id == 0x2F) seen_slot = true;
            if (id == 0x06) seen_health = true;
            if (id == 0x29) seen_sound = true;
            r.index = start + codec.PacketWriter.varIntLen(ln) + @as(usize, @intCast(ln));
        }
        try std.testing.expect(seen_slot and seen_health and seen_sound);
    }
    // Last bite with a container behind it: stew -> bowl, slot synced.
    c.inv[36] = .{ .id = game_ids.mushroom_stew, .count = 1, .damage = 0, .nbt = null };
    c.food = 10;
    c.eating = .{ .slot = 36, .id = game_ids.mushroom_stew, .damage = 0, .ticks = 1 };
    c.tickEating();
    try std.testing.expectEqual(game_ids.bowl, c.inv[36].?.id);
    try std.testing.expectEqual(@as(i16, 16), c.food);
    // Golden apple: regen effect applied + S1D queued.
    c.inv[36] = .{ .id = game_ids.golden_apple, .count = 1, .damage = 0, .nbt = null };
    c.food = 10;
    c.eating = .{ .slot = 36, .id = game_ids.golden_apple, .damage = 0, .ticks = 1 };
    c.tickEating();
    try std.testing.expect(c.effects[0] != null);
    try std.testing.expectEqual(@as(u8, 10), c.effects[0].?.id);
    // Milk clears effects.
    c.inv[36] = .{ .id = game_ids.milk_bucket, .count = 1, .damage = 0, .nbt = null };
    c.eating = .{ .slot = 36, .id = game_ids.milk_bucket, .damage = 0, .ticks = 1 };
    c.tickEating();
    try std.testing.expect(c.effects[0] == null);
    try std.testing.expectEqual(game_ids.bucket, c.inv[36].?.id);
    // Abort paths: emptied slot, swapped item, death.
    c.inv[36] = .{ .id = game_ids.bread, .count = 3, .damage = 0, .nbt = null };
    c.eating = .{ .slot = 36, .id = game_ids.bread, .damage = 0, .ticks = 30 };
    c.inv[36] = null;
    c.tickEating();
    try std.testing.expect(c.eating == null);
    c.inv[36] = .{ .id = game_ids.stone, .count = 3, .damage = 0, .nbt = null };
    c.eating = .{ .slot = 36, .id = game_ids.bread, .damage = 0, .ticks = 30 };
    c.tickEating();
    try std.testing.expect(c.eating == null);
    c.inv[36] = .{ .id = game_ids.bread, .count = 3, .damage = 0, .nbt = null };
    c.eating = .{ .slot = 36, .id = game_ids.bread, .damage = 0, .ticks = 30 };
    c.is_dead = true;
    c.tickEating();
    try std.testing.expect(c.eating == null);
    c.is_dead = false;
}

test "potion routing: drinkables eat, splash throws, never places" {
    // Drinkable potions (effect or base) start the 32-tick use like food,
    // on air and on blocks. Splash potions throw instead. Neither ever
    // becomes a block_set (potion ids are not blocks).
    var c = mkConn(.{ .gamemode = .survival, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 32);
    defer c.deinit();
    c.state = .play;
    // Swiftness drinks (air + block).
    c.inv[36] = .{ .id = game_ids.potion, .count = 1, .damage = 8194, .nbt = null };
    c.selected = 0;
    {
        const act = c.onPlace(8, 64, 8, -1, 8);
        try std.testing.expect(act == .eat);
        try std.testing.expectEqual(@as(i16, 8194), act.eat.damage);
    }
    {
        const act = c.onPlace(8, 64, 8, 1, 8);
        try std.testing.expect(act == .eat);
    }
    // Water bottle (damage 0) also drinks.
    c.inv[36].?.damage = 0;
    {
        const act = c.onPlace(8, 64, 8, -1, 8);
        try std.testing.expect(act == .eat);
    }
    // Splash swiftness throws (air + block), never eats or places.
    c.inv[36].?.damage = 8194 | 16384;
    {
        const act = c.onPlace(8, 64, 8, -1, 8);
        try std.testing.expect(act == .throw_potion);
        try std.testing.expectEqual(@as(i16, 8194 | 16384), act.throw_potion.damage);
        try std.testing.expectEqual(@as(usize, 36), act.throw_potion.slot);
    }
    {
        const act = c.onPlace(8, 64, 8, 1, 8);
        try std.testing.expect(act == .throw_potion);
    }
}

test "flint-and-steel routing: block click ignites, air does nothing" {
    var c = mkConn(.{ .gamemode = .survival, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 34);
    defer c.deinit();
    c.state = .play;
    c.inv[36] = .{ .id = game_ids.flint_and_steel, .count = 1, .damage = 0, .nbt = null };
    c.selected = 0;
    // Air click: vanilla does nothing (no fire without a face).
    {
        const act = c.onPlace(8, 64, 8, -1, 8);
        try std.testing.expect(act == .none);
    }
    // Block click carries the clicked cell (serve peeks for TNT) and the
    // target (serve NACKs it when the click was not TNT).
    {
        const act = c.onPlace(8, 64, 8, 1, 8);
        try std.testing.expect(act == .ignite_tnt);
        try std.testing.expectEqual(@as(i32, 8), act.ignite_tnt.x);
        try std.testing.expectEqual(@as(u8, 64), act.ignite_tnt.y);
        try std.testing.expectEqual(@as(i32, 8), act.ignite_tnt.z);
        try std.testing.expectEqual(@as(usize, 36), act.ignite_tnt.slot);
    }
}

test "potion drink finish: effect applies, bottle back, no food change" {
    // Swiftness (8194) at low food: 32 ticks -> effect 1 (speed) for 3600
    // ticks, bottle back, food/saturation untouched (potions don't feed).
    var c = mkConn(.{ .gamemode = .survival, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 33);
    defer c.deinit();
    c.state = .play;
    c.food = 10;
    c.saturation = 2.0;
    c.inv[36] = .{ .id = game_ids.potion, .count = 1, .damage = 8194, .nbt = null };
    c.selected = 0;
    c.eating = .{ .slot = 36, .id = game_ids.potion, .damage = 8194, .ticks = 32 };
    c.tickEating();
    try std.testing.expect(c.eating != null);
    c.tickEating();
    try std.testing.expect(c.eating == null);
    // Glass bottle back, food untouched.
    try std.testing.expectEqual(game_ids.glass_bottle, c.inv[36].?.id);
    try std.testing.expectEqual(@as(i16, 10), c.food);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), c.saturation, 1e-4);
    // Speed effect applied with the full 180s duration.
    try std.testing.expect(c.effects[0] != null);
    try std.testing.expectEqual(@as(u8, 1), c.effects[0].?.id);
    try std.testing.expectEqual(@as(i32, 3600), c.effects[0].?.ticks);
    // Water bottle drinks to nothing (still consumes + bottle back).
    c.inv[36] = .{ .id = game_ids.potion, .count = 2, .damage = 0, .nbt = null };
    c.eating = .{ .slot = 36, .id = game_ids.potion, .damage = 0, .ticks = 1 };
    c.tickEating();
    try std.testing.expectEqual(@as(i8, 1), c.inv[36].?.count);
    try std.testing.expectEqual(game_ids.potion, c.inv[36].?.id);
}

test "dig sequences: survival pending races, creative immediacy" {
    // Survival dig state machine under adversarial interleavings: a single
    // pending slot must never apply a stale finish, and every refused dig
    // carries a block_resync (the client predicts the removal; a bare drop
    // strands a ghost). Nearby cells (conn at spawn 8,64,8).
    var s = mkConn(.{ .gamemode = .survival, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 21);
    defer s.deinit();
    s.state = .play;
    const A = struct { x: i32, y: u8, z: i32 }{ .x = 8, .y = 64, .z = 8 };
    const B = struct { x: i32, y: u8, z: i32 }{ .x = 9, .y = 64, .z = 8 };
    const resyncIs = struct {
        fn f(act: conn_mod.Action, x: i32, y: u8, z: i32) !void {
            try std.testing.expect(act == .block_resync);
            try std.testing.expectEqual(x, act.block_resync.x);
            try std.testing.expectEqual(y, act.block_resync.y);
            try std.testing.expectEqual(z, act.block_resync.z);
        }
    }.f;
    // start A, finish A: applies.
    try std.testing.expect((try s.onDig(0, A.x, A.y, A.z)) == .none);
    {
        const act = try s.onDig(2, A.x, A.y, A.z);
        try std.testing.expect(act == .block_set);
        try std.testing.expectEqual(game_ids.air, act.block_set.id);
    }
    // finish with no start: resync, never break.
    try resyncIs(try s.onDig(2, A.x, A.y, A.z), A.x, A.y, A.z);
    // start A, start B (retarget, no cancel): finish B applies, stale
    // finish A resyncs (pending already consumed).
    try std.testing.expect((try s.onDig(0, A.x, A.y, A.z)) == .none);
    try std.testing.expect((try s.onDig(0, B.x, B.y, B.z)) == .none);
    {
        const act = try s.onDig(2, B.x, B.y, B.z);
        try std.testing.expect(act == .block_set);
    }
    try resyncIs(try s.onDig(2, A.x, A.y, A.z), A.x, A.y, A.z);
    // start A, cancel A, finish A: cancel resyncs, finish resyncs.
    try std.testing.expect((try s.onDig(0, A.x, A.y, A.z)) == .none);
    try resyncIs(try s.onDig(1, A.x, A.y, A.z), A.x, A.y, A.z);
    try resyncIs(try s.onDig(2, A.x, A.y, A.z), A.x, A.y, A.z);
    // cancel elsewhere resyncs but keeps pending: finish still applies.
    try std.testing.expect((try s.onDig(0, A.x, A.y, A.z)) == .none);
    try resyncIs(try s.onDig(1, B.x, B.y, B.z), B.x, B.y, B.z);
    {
        const act = try s.onDig(2, A.x, A.y, A.z);
        try std.testing.expect(act == .block_set);
    }
    // start/finish mismatch resyncs AND clears (no sticky pending).
    try std.testing.expect((try s.onDig(0, A.x, A.y, A.z)) == .none);
    try resyncIs(try s.onDig(2, B.x, B.y, B.z), B.x, B.y, B.z);
    try resyncIs(try s.onDig(2, A.x, A.y, A.z), A.x, A.y, A.z);
    // out-of-reach start sets no pending (survival: bare drop, the client
    // only started the crack overlay); the finish resyncs.
    try std.testing.expect((try s.onDig(0, 100, 64, 100)) == .none);
    try resyncIs(try s.onDig(2, 100, 64, 100), 100, 64, 100);
    // out-of-reach abort: bare drop, no state change (vanilla parity).
    try std.testing.expect((try s.onDig(0, A.x, A.y, A.z)) == .none);
    try std.testing.expect((try s.onDig(1, 100, 64, 100)) == .none);
    {
        const act = try s.onDig(2, A.x, A.y, A.z);
        try std.testing.expect(act == .block_set);
    }
    // creative: start breaks immediately, finish re-breaks harmlessly;
    // out-of-reach creative start resyncs (the click removed it locally).
    var cr = mkConn(.{ .gamemode = .creative, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 22);
    defer cr.deinit();
    cr.state = .play;
    {
        const act = try cr.onDig(0, A.x, A.y, A.z);
        try std.testing.expect(act == .block_set);
    }
    {
        const act = try cr.onDig(2, A.x, A.y, A.z);
        try std.testing.expect(act == .block_set);
    }
    try resyncIs(try cr.onDig(0, 100, 64, 100), 100, 64, 100);
    // dead conns drop everything.
    cr.is_dead = true;
    try std.testing.expect((try cr.onDig(0, A.x, A.y, A.z)) == .none);
    try std.testing.expect((try cr.onDig(2, A.x, A.y, A.z)) == .none);
}

test "dig flood gate kicks sustained spam" {
    // 40 immediate digs blow the default 32-per-1000ms budget: the 33rd+
    // trips the same "Kicked for spamming" discipline as placements.
    var c = mkConn(.{ .gamemode = .creative, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 23);
    defer c.deinit();
    c.state = .play;
    var kicked = false;
    for (0..40) |_| {
        const act = try c.onDig(0, 8, 64, 8);
        if (act == .disconnect_queued) kicked = true;
    }
    try std.testing.expect(kicked);
}

test "dig/place/held/creative/arm behavior" {
    // creative conn near origin: pos defaults to config spawn (8,64,8)
    var c = mkConn(.{ .gamemode = .creative, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 7);
    defer c.deinit();
    c.state = .play;
    const feed = struct {
        fn run(conn: *Conn, id: i32, body: []const u8) !?Action {
            var f: [64]u8 = undefined;
            try conn.feedData(try codec.framePacket(id, body, &f));
            const fr = (try conn.poll()).?;
            return try conn.handleFrame(fr);
        }
    }.run;
    // helper: dig body
    const digBody = struct {
        fn run(status: i8, x: i32, y: u8, z: i32, out: []u8) []const u8 {
            var w = codec.PacketWriter.init(out);
            w.writeByte(@bitCast(status)) catch unreachable;
            w.writeInt(x) catch unreachable;
            w.writeByte(y) catch unreachable;
            w.writeInt(z) catch unreachable;
            w.writeByte(1) catch unreachable; // face
            return w.written();
        }
    }.run;
    var db: [32]u8 = undefined;
    // creative: start breaks immediately (block next to spawn)
    {
        const act = try feed(&c, 0x07, digBody(0, 8, 64, 9, &db));
        try std.testing.expect(act != null);
        const ev = act.?.block_set;
        try std.testing.expectEqual(game_ids.air, ev.id);
        try std.testing.expectEqual(@as(i32, 8), ev.x);
        try std.testing.expectEqual(@as(u8, 64), ev.y);
        try std.testing.expectEqual(@as(i32, 9), ev.z);
    }
    // creative: finish also breaks
    {
        const act = try feed(&c, 0x07, digBody(2, 8, 64, 9, &db));
        try std.testing.expect(act.?.block_set.id == game_ids.air);
    }
    // far away: refused with a resync (creative clients remove on click)
    {
        const act = try feed(&c, 0x07, digBody(0, 9000, 64, 9, &db));
        try std.testing.expect(act.? == .block_resync);
        try std.testing.expectEqual(@as(i32, 9000), act.?.block_resync.x);
        try std.testing.expectEqual(@as(u8, 64), act.?.block_resync.y);
        try std.testing.expectEqual(@as(i32, 9), act.?.block_resync.z);
    }
    // survival: finish without start resyncs; start->finish works
    {
        var s = mkConn(.{ .gamemode = .survival, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 8);
        defer s.deinit();
        s.state = .play;
        try std.testing.expect((try feed(&s, 0x07, digBody(2, 8, 64, 9, &db))).? == .block_resync);
        try std.testing.expect((try feed(&s, 0x07, digBody(0, 8, 64, 9, &db))).? == .none); // start
        const act = try feed(&s, 0x07, digBody(2, 8, 64, 9, &db));
        try std.testing.expect(act.?.block_set.id == game_ids.air);
        // cancel clears pending: start then cancel then finish -> resync
        _ = try feed(&s, 0x07, digBody(0, 8, 64, 10, &db));
        var cb: [32]u8 = undefined;
        _ = try feed(&s, 0x07, digBody(1, 8, 64, 10, &cb));
        try std.testing.expect((try feed(&s, 0x07, digBody(2, 8, 64, 10, &db))).? == .block_resync);
    }
    // held slot + creative give + place
    {
        // give stone(id 1, damage 3) into hotbar slot 36+2=38
        var cb: [32]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeShort(38);
        try w.writeShort(1);
        try w.writeByte(64);
        try w.writeShort(3);
        try w.writeShort(-1);
        _ = try feed(&c, 0x10, w.written());
        try std.testing.expect(c.inv[38].?.id == game_ids.stone);
        // select hotbar slot 2
        var hb: [8]u8 = undefined;
        var hw = codec.PacketWriter.init(&hb);
        try hw.writeShort(2);
        _ = try feed(&c, 0x09, hw.written());
        try std.testing.expectEqual(@as(u8, 2), c.selected);
        // place against +Y face of (8,64,8) -> target (8,65,8), id 1 meta 3
        var pb: [48]u8 = undefined;
        var pw = codec.PacketWriter.init(&pb);
        try pw.writeInt(8);
        try pw.writeByte(64);
        try pw.writeInt(8);
        try pw.writeByte(1); // face +Y
        try pw.writeShort(1);
        try pw.writeByte(1);
        try pw.writeShort(3);
        try pw.writeShort(-1);
        try pw.writeByte(8);
        try pw.writeByte(8);
        try pw.writeByte(8);
        const pact = try feed(&c, 0x08, pw.written());
        const be = pact.?.block_set;
        try std.testing.expectEqual(game_ids.stone, be.id);
        try std.testing.expectEqual(@as(u4, 3), be.meta);
        try std.testing.expectEqual(@as(i32, 8), be.x);
        try std.testing.expectEqual(@as(u8, 65), be.y);
        // direction 255 (-1): ignored
        var qb: [48]u8 = undefined;
        var qw = codec.PacketWriter.init(&qb);
        try qw.writeInt(8);
        try qw.writeByte(64);
        try qw.writeInt(8);
        try qw.writeByte(255);
        try qw.writeShort(-1);
        try qw.writeByte(0);
        try qw.writeByte(0);
        try qw.writeByte(0);
        const qact = try feed(&c, 0x08, qw.written());
        try std.testing.expect(qact.? == .none);
    }
    // arm swing: own eid relays, others ignored
    {
        var ab: [8]u8 = undefined;
        var w = codec.PacketWriter.init(&ab);
        try w.writeInt(7); // own eid
        try w.writeByte(0);
        const act = try feed(&c, 0x0A, w.written());
        try std.testing.expectEqual(@as(i8, 0), act.?.arm_swing);
        var zb: [8]u8 = undefined;
        var zw = codec.PacketWriter.init(&zb);
        try zw.writeInt(99);
        try zw.writeByte(0);
        const zact = try feed(&c, 0x0A, zw.written());
        try std.testing.expect(zact.? == .none);
    }
}

test "K1 placement: redstone mapping, facing metas, empty-hand interact" {
    var c = mkConn(.{ .gamemode = .creative, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 7);
    defer c.deinit();
    c.state = .play;
    // Redstone dust in hotbar slot 0 -> places wire (not dust-as-block).
    c.inv[36] = .{ .id = game_ids.redstone, .count = 64, .damage = 0, .nbt = null };
    c.selected = 0;
    {
        const act = c.onPlace(8, 64, 8, 1, 8);
        const b = act.block_set;
        try std.testing.expectEqual(game_ids.redstone_wire, b.id);
        try std.testing.expectEqual(@as(i32, 8), b.x);
    }
    // Repeater item -> unpowered repeater with yaw facing (yaw 0 = south = 2).
    c.inv[36] = .{ .id = game_ids.repeater, .count = 1, .damage = 0, .nbt = null };
    c.yaw = 0;
    {
        const act = c.onPlace(8, 64, 8, 1, 8);
        try std.testing.expectEqual(game_ids.unpowered_repeater, act.block_set.id);
        try std.testing.expectEqual(@as(u4, 2), act.block_set.meta);
    }
    // Lever places with wall meta from the clicked face (face 2 -> 4).
    c.inv[36] = .{ .id = game_ids.lever, .count = 1, .damage = 0, .nbt = null };
    {
        const act = c.onPlace(8, 64, 8, 2, 8);
        try std.testing.expectEqual(game_ids.lever, act.block_set.id);
        try std.testing.expectEqual(@as(u4, 4), act.block_set.meta);
    }
    // Stone keeps the legacy damage-nibble meta.
    c.inv[36] = .{ .id = game_ids.stone, .count = 1, .damage = 7, .nbt = null };
    {
        const act = c.onPlace(8, 64, 8, 1, 8);
        try std.testing.expectEqual(game_ids.stone, act.block_set.id);
        try std.testing.expectEqual(@as(u4, 7), act.block_set.meta);
    }
    // Buttons are wall-only (vanilla canPlaceBlockOnSide): floor/ceiling
    // clicks with a held button are refused but NACK the target (the
    // client predicted there); walls place with facing metas.
    c.inv[36] = .{ .id = game_ids.stone_button, .count = 1, .damage = 0, .nbt = null };
    {
        const d1 = c.onPlace(8, 64, 8, 1, 8);
        try std.testing.expect(d1 == .place_deny);
        try std.testing.expectEqual(@as(i32, 8), d1.place_deny.x);
        try std.testing.expectEqual(@as(u8, 65), d1.place_deny.y);
        const d0 = c.onPlace(8, 64, 8, 0, 8);
        try std.testing.expect(d0 == .place_deny);
        try std.testing.expectEqual(@as(u8, 63), d0.place_deny.y);
        const act = c.onPlace(8, 64, 8, 2, 8);
        try std.testing.expectEqual(game_ids.stone_button, act.block_set.id);
        try std.testing.expectEqual(@as(u4, 4), act.block_set.meta);
    }
    // Torch on ceiling mounts upward (meta 0, vanilla `aoc` table).
    c.inv[36] = .{ .id = game_ids.redstone_torch, .count = 1, .damage = 0, .nbt = null };
    {
        const act = c.onPlace(8, 64, 8, 0, 8);
        try std.testing.expectEqual(game_ids.redstone_torch, act.block_set.id);
        try std.testing.expectEqual(@as(u4, 0), act.block_set.meta);
    }
    // Trapdoor: wall-only (face 0/1 refused with target NACK), meta =
    // side-2, upper half bit from cursor height.
    c.inv[36] = .{ .id = game_ids.trapdoor, .count = 1, .damage = 0, .nbt = null };
    {
        const d0 = c.onPlace(8, 64, 8, 0, 8);
        try std.testing.expect(d0 == .place_deny);
        try std.testing.expectEqual(@as(u8, 63), d0.place_deny.y);
        const d1 = c.onPlace(8, 64, 8, 1, 8);
        try std.testing.expect(d1 == .place_deny);
        try std.testing.expectEqual(@as(u8, 65), d1.place_deny.y);
        const lo = c.onPlace(8, 64, 8, 3, 2);
        try std.testing.expectEqual(game_ids.trapdoor, lo.block_set.id);
        try std.testing.expectEqual(@as(u4, 1), lo.block_set.meta);
        const hi = c.onPlace(8, 64, 8, 3, 12);
        try std.testing.expectEqual(@as(u4, 1 | 8), hi.block_set.meta);
    }
    // Ender chest faces the placer (chest yaw table, not damage nibble).
    c.inv[36] = .{ .id = game_ids.ender_chest, .count = 1, .damage = 0, .nbt = null };
    c.yaw = 0;
    {
        const act = c.onPlace(8, 64, 8, 1, 8);
        try std.testing.expectEqual(game_ids.ender_chest, act.block_set.id);
        try std.testing.expectEqual(@as(u4, 2), act.block_set.meta);
    }
    c.yaw = 90;
    {
        const act = c.onPlace(8, 64, 8, 1, 8);
        try std.testing.expectEqual(@as(u4, 5), act.block_set.meta);
    }
    // Furnace shares the chest table.
    c.inv[36] = .{ .id = game_ids.furnace, .count = 1, .damage = 0, .nbt = null };
    c.yaw = 180;
    {
        const act = c.onPlace(8, 64, 8, 1, 8);
        try std.testing.expectEqual(game_ids.furnace, act.block_set.id);
        try std.testing.expectEqual(@as(u4, 3), act.block_set.meta);
    }
    // Out-of-reach clicks are refused but NACK the target (never a bare
    // drop: the client predicted the block there and would keep a ghost).
    c.inv[36] = .{ .id = game_ids.stone, .count = 64, .damage = 0, .nbt = null };
    {
        const act = c.onPlace(100, 64, 8, 1, 8);
        try std.testing.expect(act == .place_deny);
        try std.testing.expectEqual(@as(i32, 100), act.place_deny.x);
        try std.testing.expectEqual(@as(u8, 65), act.place_deny.y);
        try std.testing.expectEqual(@as(i32, 8), act.place_deny.z);
    }
    // Anvil: jar table + damage bits (yaw 180 -> 1, damage in bits 2-3).
    c.inv[36] = .{ .id = game_ids.anvil, .count = 1, .damage = 0, .nbt = null };
    c.yaw = 180;
    {
        const act = c.onPlace(8, 64, 8, 1, 8);
        try std.testing.expectEqual(game_ids.anvil, act.block_set.id);
        try std.testing.expectEqual(@as(u4, 1), act.block_set.meta);
    }
    c.inv[36] = .{ .id = game_ids.anvil, .count = 1, .damage = 2, .nbt = null };
    {
        const act = c.onPlace(8, 64, 8, 1, 8);
        try std.testing.expectEqual(@as(u4, 1 | (2 << 2)), act.block_set.meta);
    }
    // Empty hand -> interact event (target cell + face, id air).
    c.inv[36] = null;
    {
        const act = c.onPlace(8, 64, 8, 1, 8);
        try std.testing.expect(act == .interact);
        try std.testing.expectEqual(@as(i32, 8), act.interact.x);
        try std.testing.expectEqual(@as(u8, 65), act.interact.y);
        try std.testing.expectEqual(game_ids.air, act.interact.id);
    }
}

test "place flood gate: burst admitted, sustained flood disconnects" {
    var c = mkConn(.{ .gamemode = .creative, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 7);
    defer c.deinit();
    c.state = .play;
    c.inv[36] = .{ .id = game_ids.stone, .count = 64, .damage = 0, .nbt = null };
    // A full burst inside one window is admitted (block_set events).
    var i: usize = 0;
    while (i < c.config.place_burst) : (i += 1) {
        try std.testing.expect(c.onPlace(8, 64, 8, 1, 8) == .block_set);
    }
    // The next placement in the same window disconnects with the spam
    // screen and arms close-after-flush, like the chat throttle.
    try std.testing.expect(c.onPlace(8, 64, 8, 1, 8) == .disconnect_queued);
    try std.testing.expect(c.close_after_flush);
}

test "use entity: attack validation, damage table, dead gates, respawn" {
    const a = std.testing.allocator;
    var c = mkConn(.{ .gamemode = .survival, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 7);
    defer c.deinit();
    c.state = .play;
    @memcpy(c.username[0.."Al".len], "Al");
    c.username_len = "Al".len;
    const feed = struct {
        fn run(conn: *Conn, id: i32, body: []const u8) !?Action {
            var f: [64]u8 = undefined;
            try conn.feedData(try codec.framePacket(id, body, &f));
            const fr = (try conn.poll()).?;
            return try conn.handleFrame(fr);
        }
    }.run;
    const useBody = struct {
        fn run(target: i32, mouse: i8, out: []u8) []const u8 {
            var w = codec.PacketWriter.init(out);
            w.writeInt(target) catch unreachable;
            w.writeByte(@bitCast(mouse)) catch unreachable;
            return w.written();
        }
    }.run;
    var ub: [16]u8 = undefined;
    // empty hand attack -> event with fist damage, attacker snapshot
    {
        const act = try feed(&c, 0x02, useBody(99, 1, &ub));
        const ev = act.?.attack;
        try std.testing.expectEqual(@as(i32, 99), ev.target_eid);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), ev.dmg, 1e-6);
        try std.testing.expectApproxEqAbs(@as(f64, 8.5), ev.ax, 1e-9);
    }
    // interact (0) and interact-at (2): dropped, no target system yet
    {
        try std.testing.expect((try feed(&c, 0x02, useBody(99, 0, &ub))).? == .none);
        var ib: [32]u8 = undefined;
        var w = codec.PacketWriter.init(&ib);
        try w.writeInt(99);
        try w.writeByte(2);
        try w.writeFloat(1.0);
        try w.writeFloat(2.0);
        try w.writeFloat(3.0);
        try std.testing.expect((try feed(&c, 0x02, w.written())).? == .none);
    }
    // self-hit dropped
    try std.testing.expect((try feed(&c, 0x02, useBody(7, 1, &ub))).? == .none);
    // damage table: diamond sword 7, iron axe 5, stick 1
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), profile.game.item_data.meleeDamage(game_ids.diamond_sword), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), profile.game.item_data.meleeDamage(game_ids.iron_axe), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), profile.game.item_data.meleeDamage(game_ids.stick), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), profile.game.item_data.meleeDamage(game_ids.air), 1e-6);
    // diamond sword in hand -> 7.0 event
    {
        var cb: [32]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeShort(36);
        try w.writeShort(276);
        try w.writeByte(1);
        try w.writeShort(0);
        try w.writeShort(-1);
        c.inv[36] = .{ .id = game_ids.diamond_sword, .count = 1, .damage = 0, .nbt = null };
        c.selected = 0;
        const act = try feed(&c, 0x02, useBody(100, 1, &ub));
        try std.testing.expectApproxEqAbs(@as(f32, 7.0), act.?.attack.dmg, 1e-6);
        c.inv[36] = null;
    }
    // dead: dig/place/attack all dropped
    {
        c.is_dead = true;
        var db: [32]u8 = undefined;
        var w = codec.PacketWriter.init(&db);
        try w.writeByte(0);
        try w.writeInt(8);
        try w.writeByte(64);
        try w.writeInt(9);
        try w.writeByte(1);
        try std.testing.expect((try feed(&c, 0x07, w.written())).? == .none);
        try std.testing.expect((try feed(&c, 0x02, useBody(99, 1, &ub))).? == .none);
        // chat still works while dead
        var chb: [32]u8 = undefined;
        var chw = codec.PacketWriter.init(&chb);
        try chw.writeString("hi");
        const chact = try feed(&c, 0x01, chw.written());
        try std.testing.expect(chact.? == .chat);
        // respawn via client status 0: healed, alive, Update Health queued
        var sb: [8]u8 = undefined;
        var sw = codec.PacketWriter.init(&sb);
        try sw.writeByte(0);
        try std.testing.expect((try feed(&c, 0x16, sw.written())).? == .none);
        try std.testing.expect(!c.is_dead);
        try std.testing.expectApproxEqAbs(@as(f32, 20.0), c.health, 1e-6);
        const out = try c.takeOutput();
        defer a.free(out);
        var r = codec.PacketReader.init(out);
        try std.testing.expectEqual(@as(i32, 0x06), (try codec.decodeFrame(&r)).id);
        try std.testing.expectApproxEqAbs(@as(f32, 20.0), try r.readFloat(), 1e-6);
    }
}

test "crafting table: 3x3 take, shift-craft, close drops grid" {
    const a = std.testing.allocator;
    var c = mkConn(.{ .gamemode = .survival, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 7);
    defer c.deinit();
    c.state = .play;
    const feed = struct {
        fn run(conn: *Conn, id: i32, body: []const u8) !?Action {
            var f: [64]u8 = undefined;
            try conn.feedData(try codec.framePacket(id, body, &f));
            const fr = (try conn.poll()).?;
            return try conn.handleFrame(fr);
        }
    }.run;
    // open + iron pickaxe shape (row0 iron, stick col1 rows1-2)
    c.openTableUI(8, 64, 8);
    try std.testing.expect(c.open_win != null);
    c.table[1] = .{ .id = game_ids.iron_ingot, .count = 1, .damage = 0, .nbt = null };
    c.table[2] = .{ .id = game_ids.iron_ingot, .count = 1, .damage = 0, .nbt = null };
    c.table[3] = .{ .id = game_ids.iron_ingot, .count = 1, .damage = 0, .nbt = null };
    c.table[5] = .{ .id = game_ids.stick, .count = 1, .damage = 0, .nbt = null };
    c.table[8] = .{ .id = game_ids.stick, .count = 1, .damage = 0, .nbt = null };
    c.refreshTable();
    try std.testing.expect(c.table[0] != null);
    try std.testing.expectEqual(game_ids.iron_pickaxe, c.table[0].?.id);
    // take via mode-0 click on window-1 slot 0 (action 1 seeds)
    {
        var cb: [64]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeByte(1); // window 1
        try w.writeShort(0);
        try w.writeByte(0);
        try w.writeShort(1);
        try w.writeByte(0);
        try w.writeShort(-1);
        try w.writeShort(-1);
        _ = try feed(&c, 0x0E, w.written());
        try std.testing.expect(c.cursor != null);
        try std.testing.expectEqual(game_ids.iron_pickaxe, c.cursor.?.id);
        try std.testing.expect(c.table[1] == null); // consumed
        try std.testing.expect(c.table[0] == null); // no longer matches
        var owned: ?item_mod.Stack = c.cursor;
        item_mod.freeStack(a, &owned);
        c.cursor = null;
        {
            const o = try c.takeOutput();
            defer a.free(o);
        }
    }
    // shift-craft sticks x64: grid col0 rows0-2... use 3-high column? sticks need 2x1; fill col0
    c.table[1] = .{ .id = game_ids.planks, .count = 64, .damage = 0, .nbt = null };
    c.table[4] = .{ .id = game_ids.planks, .count = 64, .damage = 0, .nbt = null };
    {
        var cb: [64]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeByte(1);
        try w.writeShort(0);
        try w.writeByte(0);
        try w.writeShort(2);
        try w.writeByte(1); // shift
        try w.writeShort(-1);
        try w.writeShort(-1);
        _ = try feed(&c, 0x0E, w.written());
        var total: i32 = 0;
        for (item_mod.main_lo..item_mod.inv_size) |i| if (c.inv[i]) |st| if (st.id == game_ids.stick) {
            total += st.count;
        };
        try std.testing.expectEqual(@as(i32, 256), total);
        {
            const o = try c.takeOutput();
            defer a.free(o);
        }
    }
    // close (0x0D) drops remaining grid stacks as entities
    c.table[6] = .{ .id = game_ids.stone, .count = 7, .damage = 0, .nbt = null };
    {
        var cb: [8]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeByte(1);
        const act = try feed(&c, 0x0D, w.written());
        const tc = act.?.table_close;
        var n: usize = 0;
        for (tc.stacks) |st| if (st != null) {
            n += 1;
            try std.testing.expectEqual(game_ids.stone, st.?.id);
        };
        try std.testing.expectEqual(@as(usize, 1), n);
        try std.testing.expect(c.open_win == null);
        var owned = tc.stacks;
        for (&owned) |*st| item_mod.freeStack(a, st);
        {
            const o = try c.takeOutput();
            defer a.free(o);
        }
    }
    // table shift-craft (craftAll path, window 1): sticks from 2x64 planks.
    // Reopened windows restart the client's action counter, so this also
    // pins the per-window seq: without the open-reset the action-2 click
    // below would false-reject against the previous session's expectation.
    {
        c.openTableUI(8, 64, 8);
        for (item_mod.main_lo..item_mod.inv_size) |i| item_mod.freeStack(a, &c.inv[i]); // clear the earlier batch
        c.table[1] = .{ .id = game_ids.planks, .count = 64, .damage = 0, .nbt = null };
        c.table[4] = .{ .id = game_ids.planks, .count = 64, .damage = 0, .nbt = null };
        c.refreshTable();
        var cb: [64]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeByte(1);
        try w.writeShort(0);
        try w.writeByte(0);
        try w.writeShort(2);
        try w.writeByte(1); // shift
        try w.writeShort(-1);
        try w.writeShort(-1);
        _ = try feed(&c, 0x0E, w.written());
        var total: i32 = 0;
        for (item_mod.main_lo..item_mod.inv_size) |i| if (c.inv[i]) |st| if (st.id == game_ids.stick) {
            total += st.count;
        };
        try std.testing.expectEqual(@as(i32, 256), total);
        {
            const o = try c.takeOutput();
            defer a.free(o);
        }
    }
}

test "click window: pickup/place/merge/swap/shift/number/desync/nbt" {
    const a = std.testing.allocator;
    var c = mkConn(.{ .gamemode = .survival, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 7);
    defer c.deinit();
    c.state = .play;
    @memcpy(c.username[0.."Bo".len], "Bo");
    c.username_len = "Bo".len;
    const feed = struct {
        fn run(conn: *Conn, id: i32, body: []const u8) !?Action {
            var f: [64]u8 = undefined;
            try conn.feedData(try codec.framePacket(id, body, &f));
            const fr = (try conn.poll()).?;
            return try conn.handleFrame(fr);
        }
    }.run;
    const click = struct {
        fn run(conn: *Conn, slot: i16, button: i8, action: i16, mode: i8) !?Action {
            var cb: [32]u8 = undefined;
            var w = codec.PacketWriter.init(&cb);
            try w.writeByte(0); // window 0
            try w.writeShort(slot);
            try w.writeByte(@as(u8, @bitCast(button)));
            try w.writeShort(action);
            try w.writeByte(@as(u8, @bitCast(mode)));
            try w.writeShort(-1); // empty clicked slot
            return try feed(conn, 0x0E, w.written());
        }
    }.run;
    // 0. movement accounting: walk/jump/fall/sprint exhaustion + landing
    {
        var m = mkConn(.{ .gamemode = .survival, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 7);
        defer m.deinit();
        m.state = .play;
        m.baseline_sent = true;
        m.pos_x = 8.5;
        m.pos_y = 64.0;
        m.pos_z = 8.5;
        m.on_ground = true;
        // walk 1 block: +0.01
        m.setPos(9.5, 64.0, 8.5, 0, 0, true);
        try std.testing.expectApproxEqAbs(@as(f32, 0.01), m.exhaustion, 1e-6);
        // takeoff upward: jump +0.2 (no fall accumulated rising)
        m.setPos(9.5, 64.6, 8.5, 0, 0, false);
        try std.testing.expectApproxEqAbs(@as(f32, 0.21), m.exhaustion, 1e-6);
        try std.testing.expectEqual(@as(f32, 0), m.fall_acc);
        // fall 5.1 down: accumulates
        m.setPos(9.5, 59.5, 8.5, 0, 0, false);
        try std.testing.expectApproxEqAbs(@as(f32, 5.1), m.fall_acc, 1e-4);
        // land: pending fall stashed, accumulator cleared
        m.setPos(9.5, 59.5, 8.5, 0, 0, true);
        try std.testing.expectEqual(@as(f32, 0), m.fall_acc);
        try std.testing.expect(m.pending_fall != null);
        try std.testing.expectApproxEqAbs(@as(f32, 5.1), m.pending_fall.?.dist, 1e-4);
        // sprint flag via 0x0B action 4/5; sprint-jump costs 0.8
        var eb: [16]u8 = undefined;
        var ew = codec.PacketWriter.init(&eb);
        try ew.writeInt(7);
        try ew.writeByte(4);
        try ew.writeInt(0);
        _ = try feed(&m, 0x0B, ew.written());
        try std.testing.expect(m.sprinting);
        m.on_ground = true;
        m.setPos(9.5, 60.0, 8.5, 0, 0, false);
        try std.testing.expectApproxEqAbs(@as(f32, 0.21 + 0.8), m.exhaustion, 1e-4);
        // sneak-start clears a (possibly stale) sprint flag: later hops
        // price at the 0.2 walk rate, not 0.8.
        var sb2: [16]u8 = undefined;
        var sw2 = codec.PacketWriter.init(&sb2);
        try sw2.writeInt(7);
        try sw2.writeByte(1);
        try sw2.writeInt(0);
        _ = try feed(&m, 0x0B, sw2.written());
        try std.testing.expect(m.sneaking);
        try std.testing.expect(!m.sprinting);
        // exhaustion caps at 40 (vanilla FoodStats cap)
        m.exhaustion = 39.9;
        m.addExhaustion(5.0);
        try std.testing.expectEqual(@as(f32, 40.0), m.exhaustion);
        // creative is exempt
        m.config.gamemode = .creative;
        m.exhaustion = 0;
        m.addExhaustion(3.0);
        try std.testing.expectEqual(@as(f32, 0), m.exhaustion);
    }
    // 0b. swimming never accumulates fall distance (vanilla resets
    // fallDistance in fluid): descents + surface bobbing with eyes out
    // must not cash in as damage when walking out onto a beach.
    {
        var m = mkConn(.{ .gamemode = .survival, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 7);
        defer m.deinit();
        m.state = .play;
        m.baseline_sent = true;
        m.pos_x = 8.5;
        m.pos_y = 64.0;
        m.pos_z = 8.5;
        m.on_ground = false;
        m.in_fluid = true;
        // dive 5 down + bob up/down at the "surface": nothing accrues
        m.setPos(8.5, 59.0, 8.5, 0, 0, false);
        try std.testing.expectEqual(@as(f32, 0), m.fall_acc);
        try std.testing.expect(m.pending_fall == null);
        m.setPos(8.5, 64.2, 8.5, 0, 0, false);
        m.setPos(8.5, 63.8, 8.5, 0, 0, false);
        m.setPos(8.5, 64.1, 8.5, 0, 0, false);
        try std.testing.expectEqual(@as(f32, 0), m.fall_acc);
        try std.testing.expect(m.pending_fall == null);
        // step out onto land while the flag is still set: no stash
        m.setPos(8.5, 64.0, 8.5, 0, 0, true);
        try std.testing.expectEqual(@as(f32, 0), m.fall_acc);
        try std.testing.expect(m.pending_fall == null);
        // dry again: descents accumulate and landings stash normally
        m.in_fluid = false;
        m.setPos(8.5, 59.0, 8.5, 0, 0, false);
        try std.testing.expectApproxEqAbs(@as(f32, 5.0), m.fall_acc, 1e-4);
        m.setPos(8.5, 59.0, 8.5, 0, 0, true);
        try std.testing.expect(m.pending_fall != null);
        try std.testing.expectApproxEqAbs(@as(f32, 5.0), m.pending_fall.?.dist, 1e-4);
    }
    // 0. Crafting 2x2: sticks from 2 planks, take consumes grid.
    {
        c.inv[1] = .{ .id = game_ids.planks, .count = 1, .damage = 0, .nbt = null };
        c.inv[3] = .{ .id = game_ids.planks, .count = 1, .damage = 0, .nbt = null };
        c.refreshCrafting();
        try std.testing.expect(c.inv[0] != null);
        try std.testing.expectEqual(game_ids.stick, c.inv[0].?.id);
        try std.testing.expectEqual(@as(i8, 4), c.inv[0].?.count);
        // take with left-click on slot 0 (mode 0, empty cursor)
        var cb: [64]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeByte(0);
        try w.writeShort(0);
        try w.writeByte(0);
        try w.writeShort(4);
        try w.writeByte(0);
        try w.writeShort(-1);
        try w.writeShort(-1); // clicked item: empty
        _ = try feed(&c, 0x0E, w.written());
        try std.testing.expect(c.cursor != null);
        try std.testing.expectEqual(game_ids.stick, c.cursor.?.id);
        try std.testing.expect(c.inv[1] == null and c.inv[3] == null);
        try std.testing.expect(c.inv[0] == null); // grid empty -> no match
        var owned: ?item_mod.Stack = c.cursor;
        item_mod.freeStack(a, &owned);
        c.cursor = null;
        {
            const o = try c.takeOutput();
            defer a.free(o);
        }
    }
    // 0b. Shift-click result crafts repeatedly into the pack.
    {
        c.inv[1] = .{ .id = game_ids.planks, .count = 64, .damage = 0, .nbt = null };
        c.inv[3] = .{ .id = game_ids.planks, .count = 64, .damage = 0, .nbt = null };
        c.refreshCrafting();
        var cb: [64]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeByte(0);
        try w.writeShort(0);
        try w.writeByte(0);
        try w.writeShort(5);
        try w.writeByte(1); // shift
        try w.writeShort(-1); // clicked item: empty
        _ = try feed(&c, 0x0E, w.written());
        // 64 crafts x4 sticks = 256 sticks across 4+ stacks in main
        var total: i32 = 0;
        for (item_mod.main_lo..item_mod.inv_size) |i| if (c.inv[i]) |st| if (st.id == game_ids.stick) {
            total += st.count;
        };
        try std.testing.expectEqual(@as(i32, 256), total);
        try std.testing.expect(c.inv[1] == null and c.inv[3] == null);
        {
            const o = try c.takeOutput();
            defer a.free(o);
        }
        c.click_seq[0] = 1; // restore the window-0 action counter for the steps below
        for (item_mod.main_lo..item_mod.inv_size) |i| item_mod.freeStack(a, &c.inv[i]); // clear crafted stacks
    }
    // 0. Creative 0x10 rejects the result slot (vanilla parity).
    {
        // two planks vertical = sticks (a lone plank is a button)
        c.inv[1] = .{ .id = game_ids.planks, .count = 1, .damage = 0, .nbt = null };
        c.inv[3] = .{ .id = game_ids.planks, .count = 1, .damage = 0, .nbt = null };
        c.refreshCrafting();
        try std.testing.expect(c.inv[0] != null); // sticks offered
        var cb: [32]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeShort(0); // slot 0: rejected
        try w.writeShort(999);
        try w.writeByte(1);
        try w.writeShort(0);
        try w.writeShort(-1);
        var f: [64]u8 = undefined;
        try c.feedData(try codec.framePacket(0x10, w.written(), &f));
        const fr = (try c.poll()).?;
        _ = try c.handleFrame(fr);
        try std.testing.expect(c.inv[0] != null); // recompute untouched it
        try std.testing.expectEqual(game_ids.stick, c.inv[0].?.id);
        c.inv[0] = null;
        c.inv[1] = null;
        c.inv[3] = null;
        {
            const o = try c.takeOutput();
            defer a.free(o);
        }
    }
    // 0. Q-drop: status 4 drops one (slot decrements, event owns one),
    // status 3 drops the whole stack (slot empties).
    c.inv[36] = .{ .id = game_ids.diamond, .count = 5, .damage = 0, .nbt = null };
    {
        var qb: [32]u8 = undefined;
        var qw = codec.PacketWriter.init(&qb);
        try qw.writeByte(4); // status: drop one
        try qw.writeInt(@as(i32, 0));
        try qw.writeByte(64);
        try qw.writeInt(@as(i32, 0));
        try qw.writeByte(1); // face
        const act = try feed(&c, 0x07, qw.written());
        const q = act.?.qdrop;
        try std.testing.expectEqual(@as(i16, 36), q.slot);
        try std.testing.expectEqual(game_ids.diamond, q.stack.id);
        try std.testing.expectEqual(@as(i8, 1), q.stack.count);
        try std.testing.expectEqual(@as(i8, 4), c.inv[36].?.count);
        var owned: ?item_mod.Stack = q.stack;
        item_mod.freeStack(a, &owned);
    }
    {
        var qb: [32]u8 = undefined;
        var qw = codec.PacketWriter.init(&qb);
        try qw.writeByte(3); // status: drop whole stack
        try qw.writeInt(@as(i32, 0));
        try qw.writeByte(64);
        try qw.writeInt(@as(i32, 0));
        try qw.writeByte(1);
        const act = try feed(&c, 0x07, qw.written());
        const q = act.?.qdrop;
        try std.testing.expectEqual(@as(i8, 4), q.stack.count);
        try std.testing.expect(c.inv[36] == null);
        var owned: ?item_mod.Stack = q.stack;
        item_mod.freeStack(a, &owned);
    }
    // 1. pickup all (left on stack, empty cursor) -> slot empty, cursor full
    c.inv[10] = .{ .id = game_ids.stone, .count = 64, .damage = 0, .nbt = null };
    try std.testing.expect((try click(&c, 10, 0, 1, 0)).? == .none);
    try std.testing.expect(c.inv[10] == null);
    try std.testing.expectEqual(@as(i8, 64), c.cursor.?.count);
    {
        const out = try c.takeOutput();
        defer a.free(out);
        // slot 10 cleared + cursor set
        var r = codec.PacketReader.init(out);
        var saw_slot = false;
        var saw_cursor = false;
        while (r.remaining() > 0) {
            const h = try codec.decodeFrame(&r);
            try std.testing.expectEqual(@as(i32, 0x2F), h.id);
            const win = @as(i8, @bitCast(try r.readByte())); // window
            const slot = try r.readShort();
            if (slot == 10) {
                try std.testing.expectEqual(@as(i16, -1), try r.readShort());
                saw_slot = true;
            } else if (slot == -1) {
                // cursor must ride window -1 (window 0/slot -1 crashes vanilla)
                try std.testing.expectEqual(@as(i8, -1), win);
                try std.testing.expectEqual(@as(i16, 1), try r.readShort());
                try std.testing.expectEqual(@as(i8, 64), @as(i8, @bitCast(try r.readByte())));
                try std.testing.expectEqual(@as(i16, 0), try r.readShort());
                try std.testing.expectEqual(@as(i16, -1), try r.readShort());
                saw_cursor = true;
            } else return error.TestUnexpectedResult;
        }
        try std.testing.expect(saw_slot and saw_cursor);
    }
    // 2. place all into empty slot
    try std.testing.expect((try click(&c, 11, 0, 2, 0)).? == .none);
    try std.testing.expectEqual(@as(i8, 64), c.inv[11].?.count);
    try std.testing.expect(c.cursor == null);
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
    // 3. right-click pickup half (ceil): 10 -> cursor 5, slot 5
    c.inv[12] = .{ .id = game_ids.stone, .count = 10, .damage = 0, .nbt = null };
    try std.testing.expect((try click(&c, 12, 1, 3, 0)).? == .none);
    try std.testing.expectEqual(@as(i8, 5), c.cursor.?.count);
    try std.testing.expectEqual(@as(i8, 5), c.inv[12].?.count);
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
    // 4. right-click place one: slot 13 empty -> 1, cursor 5 -> 4
    try std.testing.expect((try click(&c, 13, 1, 4, 0)).? == .none);
    try std.testing.expectEqual(@as(i8, 1), c.inv[13].?.count);
    try std.testing.expectEqual(@as(i8, 4), c.cursor.?.count);
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
    // 5. merge: slot has 60, cursor has 10 of same -> slot 64, cursor 6
    c.inv[14] = .{ .id = game_ids.stone, .count = 60, .damage = 0, .nbt = null };
    c.cursor = .{ .id = game_ids.stone, .count = 10, .damage = 0, .nbt = null };
    try std.testing.expect((try click(&c, 14, 0, 5, 0)).? == .none);
    try std.testing.expectEqual(@as(i8, 64), c.inv[14].?.count);
    try std.testing.expectEqual(@as(i8, 6), c.cursor.?.count);
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
    // 6. swap: cursor stone vs slot dirt
    c.inv[16] = .{ .id = game_ids.dirt, .count = 5, .damage = 0, .nbt = null };
    c.cursor = .{ .id = game_ids.stone, .count = 6, .damage = 0, .nbt = null };
    try std.testing.expect((try click(&c, 16, 0, 6, 0)).? == .none);
    try std.testing.expectEqual(game_ids.stone, c.inv[16].?.id);
    try std.testing.expectEqual(@as(i8, 6), c.inv[16].?.count);
    try std.testing.expectEqual(game_ids.dirt, c.cursor.?.id);
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
    // 7. shift-click merge: main slot 20 (stone 32) merges hotbar-end
    // first — 44 (stone 32) fills to 42 with the whole stack, 36 stays.
    // (Vanilla mergeItemStack reverse pass: hotbar fills at the END first.)
    c.cursor = null;
    for (36..45) |i| item_mod.freeStack(a, &c.inv[i]);
    c.inv[20] = .{ .id = game_ids.stone, .count = 10, .damage = 0, .nbt = null };
    c.inv[36] = .{ .id = game_ids.stone, .count = 32, .damage = 0, .nbt = null };
    c.inv[37] = .{ .id = game_ids.grass, .count = 1, .damage = 0, .nbt = null };
    c.inv[44] = .{ .id = game_ids.stone, .count = 32, .damage = 0, .nbt = null };
    try std.testing.expect((try click(&c, 20, 0, 7, 1)).? == .none);
    try std.testing.expect(c.inv[20] == null);
    try std.testing.expectEqual(@as(i8, 42), c.inv[44].?.count);
    try std.testing.expectEqual(@as(i8, 32), c.inv[36].?.count);
    // 7b. shift-click fill: no merge target -> first empty from the END
    // (slot 44), not the beginning.
    for (36..45) |i| item_mod.freeStack(a, &c.inv[i]);
    c.inv[24] = .{ .id = game_ids.stone, .count = 10, .damage = 0, .nbt = null };
    try std.testing.expect((try click(&c, 24, 0, 8, 1)).? == .none);
    try std.testing.expect(c.inv[24] == null);
    try std.testing.expectEqual(@as(i8, 10), c.inv[44].?.count);
    try std.testing.expect(c.inv[36] == null);
    // 7c. shift-click from the hotbar fills main FORWARD from slot 9.
    c.inv[36] = .{ .id = game_ids.dirt, .count = 7, .damage = 0, .nbt = null };
    try std.testing.expect((try click(&c, 36, 0, 9, 1)).? == .none);
    try std.testing.expect(c.inv[36] == null);
    try std.testing.expectEqual(@as(i8, 7), c.inv[9].?.count);
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
    // 8. number key: swap slot 21 with hotbar 0 (button 0); ignored w/ cursor
    c.inv[21] = .{ .id = game_ids.planks, .count = 1, .damage = 0, .nbt = null };
    c.inv[36] = .{ .id = game_ids.stone, .count = 64, .damage = 0, .nbt = null };
    try std.testing.expect((try click(&c, 21, 0, 10, 2)).? == .none);
    try std.testing.expectEqual(game_ids.stone, c.inv[21].?.id);
    try std.testing.expectEqual(game_ids.planks, c.inv[36].?.id);
    c.cursor = .{ .id = game_ids.stone, .count = 1, .damage = 0, .nbt = null };
    try std.testing.expect((try click(&c, 21, 1, 11, 2)).? == .none);
    try std.testing.expectEqual(game_ids.stone, c.inv[21].?.id); // unchanged
    c.cursor = null;
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
    // 9. desync: reused action number triggers full Window Items + ignore
    c.inv[22] = .{ .id = game_ids.bedrock, .count = 3, .damage = 0, .nbt = null };
    try std.testing.expect((try click(&c, 22, 0, 11, 0)).? == .none); // stale action
    try std.testing.expectEqual(game_ids.bedrock, c.inv[22].?.id); // untouched
    try std.testing.expectEqual(@as(i8, 3), c.inv[22].?.count);
    {
        const out = try c.takeOutput();
        defer a.free(out);
        var r = codec.PacketReader.init(out);
        try std.testing.expectEqual(@as(i32, 0x30), (try codec.decodeFrame(&r)).id);
        try std.testing.expectEqual(@as(u8, 0), try r.readByte()); // window
        try std.testing.expectEqual(@as(i16, 45), try r.readShort()); // full inventory
    }
    // 10. NBT survives moves: whole-stack pickup transfers the tag bytes
    // (same allocation, no copy); split-half copies them (no aliasing).
    const tag = [_]u8{ 0x0A, 0x00, 0x03, 0x64, 0x75, 0x6D };
    const owned_tag = try a.dupe(u8, &tag);
    c.inv[30] = .{ .id = game_ids.diamond_sword, .count = 1, .damage = 0, .nbt = owned_tag };
    try std.testing.expect((try click(&c, 30, 0, 12, 0)).? == .none); // pickup
    try std.testing.expect(c.inv[30] == null);
    try std.testing.expectEqualSlices(u8, &tag, c.cursor.?.nbt.?);
    try std.testing.expect(c.cursor.?.nbt.?.ptr == owned_tag.ptr); // moved, not copied
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
    // park it in an empty slot (place path keeps NBT too)
    try std.testing.expect((try click(&c, 31, 0, 13, 0)).? == .none);
    try std.testing.expect(c.cursor == null);
    try std.testing.expectEqualSlices(u8, &tag, c.inv[31].?.nbt.?);
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
    // two-stack split: fresh enchanted stack of 2, right-click takes half
    const tag2 = try a.dupe(u8, &tag);
    c.inv[32] = .{ .id = game_ids.diamond_sword, .count = 2, .damage = 0, .nbt = tag2 };
    try std.testing.expect((try click(&c, 32, 1, 14, 0)).? == .none);
    try std.testing.expectEqual(@as(i8, 1), c.cursor.?.count);
    try std.testing.expectEqual(@as(i8, 1), c.inv[32].?.count);
    try std.testing.expectEqualSlices(u8, c.cursor.?.nbt.?, c.inv[32].?.nbt.?);
    try std.testing.expect(c.cursor.?.nbt.?.ptr != c.inv[32].?.nbt.?.ptr); // independent copies
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
}

test "click window: drag-spread distributes, merges, and cancels" {
    const a = std.testing.allocator;
    var c = mkConn(.{ .gamemode = .survival, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 7);
    defer c.deinit();
    c.state = .play;
    const clickW = struct {
        fn feed(conn: *Conn, id: i32, body: []const u8) !void {
            var f: [64]u8 = undefined;
            try conn.feedData(try codec.framePacket(id, body, &f));
        }
        fn run(conn: *Conn, window: i8, slot: i16, button: i8, action: i16, mode: i8) !void {
            try feed(conn, 0x0E, blk: {
                var cb: [32]u8 = undefined;
                var w = codec.PacketWriter.init(&cb);
                try w.writeByte(@as(u8, @bitCast(window)));
                try w.writeShort(slot);
                try w.writeByte(@as(u8, @bitCast(button)));
                try w.writeShort(action);
                try w.writeByte(@as(u8, @bitCast(mode)));
                try w.writeShort(-1);
                break :blk w.written();
            });
            const fr = (try conn.poll()).?;
            _ = try conn.handleFrame(fr);
        }
    }.run;
    // left-drag 10 dirt over slots 9,10,11 -> 4/3/3, cursor empties.
    c.cursor = .{ .id = game_ids.dirt, .count = 10, .damage = 0, .nbt = null };
    try clickW(&c, 0, -999, 0, 20, 5);
    try clickW(&c, 0, 9, 1, 21, 5);
    try clickW(&c, 0, 10, 1, 22, 5);
    try clickW(&c, 0, 11, 1, 23, 5);
    try clickW(&c, 0, -999, 2, 24, 5);
    try std.testing.expect(c.cursor == null);
    try std.testing.expectEqual(@as(i8, 4), c.inv[9].?.count);
    try std.testing.expectEqual(@as(i8, 3), c.inv[10].?.count);
    try std.testing.expectEqual(@as(i8, 3), c.inv[11].?.count);
    // right-drag 5 dirt over 12,13,14,15 -> 1 each, 1 left on cursor.
    c.cursor = .{ .id = game_ids.dirt, .count = 5, .damage = 0, .nbt = null };
    try clickW(&c, 0, -999, 4, 25, 5);
    try clickW(&c, 0, 12, 5, 26, 5);
    try clickW(&c, 0, 13, 5, 27, 5);
    try clickW(&c, 0, 14, 5, 28, 5);
    try clickW(&c, 0, 15, 5, 29, 5);
    try clickW(&c, 0, -999, 6, 30, 5);
    try std.testing.expectEqual(@as(i8, 1), c.cursor.?.count);
    try std.testing.expectEqual(@as(i8, 1), c.inv[12].?.count);
    try std.testing.expectEqual(@as(i8, 1), c.inv[15].?.count);
    // result slot 0 is never painted: drag including it skips it.
    c.cursor = .{ .id = game_ids.dirt, .count = 4, .damage = 0, .nbt = null };
    try clickW(&c, 0, -999, 0, 31, 5);
    try clickW(&c, 0, 0, 1, 32, 5);
    try clickW(&c, 0, 16, 1, 33, 5);
    try clickW(&c, 0, -999, 2, 34, 5);
    try std.testing.expect(c.cursor == null);
    try std.testing.expect(c.inv[0] == null);
    try std.testing.expectEqual(@as(i8, 4), c.inv[16].?.count);
    // armor slots only take the matching piece.
    c.cursor = .{ .id = game_ids.dirt, .count = 3, .damage = 0, .nbt = null };
    try clickW(&c, 0, -999, 0, 35, 5);
    try clickW(&c, 0, 5, 1, 36, 5);
    try clickW(&c, 0, 17, 1, 37, 5);
    try clickW(&c, 0, -999, 2, 38, 5);
    try std.testing.expect(c.cursor == null);
    try std.testing.expect(c.inv[5] == null);
    try std.testing.expectEqual(@as(i8, 3), c.inv[17].?.count);
    // a non-drag click mid-drag cancels (slot 19 keeps its dirt).
    c.inv[18] = .{ .id = game_ids.dirt, .count = 2, .damage = 0, .nbt = null };
    c.cursor = .{ .id = game_ids.stone, .count = 9, .damage = 0, .nbt = null };
    try clickW(&c, 0, -999, 0, 39, 5);
    try clickW(&c, 0, 19, 1, 40, 5);
    try clickW(&c, 0, 36, 0, 41, 0); // plain pickup cancels the drag...
    try clickW(&c, 0, -999, 2, 42, 5); // ...so a later end finds no drag.
    try std.testing.expect(c.inv[19] == null); // never distributed
    try std.testing.expectEqual(@as(i8, 2), c.inv[18].?.count); // untouched
    try std.testing.expect(c.cursor == null); // ...and the click placed it
    try std.testing.expectEqual(@as(i8, 9), c.inv[36].?.count);
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
}

test "enchant window: open, click validation, close, 0x11" {
    const a = std.testing.allocator;
    var c = mkConn(.{ .gamemode = .survival, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 7);
    defer c.deinit();
    c.state = .play;
    const feed = struct {
        fn run(conn: *Conn, id: i32, body: []const u8) !?Action {
            var f: [128]u8 = undefined;
            try conn.feedData(try codec.framePacket(id, body, &f));
            const fr = (try conn.poll()).?;
            return try conn.handleFrame(fr);
        }
    }.run;
    // Open window 4 directly (server computes bookshelves/levels).
    c.openEnchantUI(8, 64, 8, 1234);
    try std.testing.expect(c.open_win != null);
    try std.testing.expectEqual(@as(u8, 4), c.open_win.?.id);
    try std.testing.expectEqual(@as(i32, 1234), c.enchant_seed);
    try std.testing.expect(c.enchant_item == null);
    // 0x0E click on window 4 validates the action number and returns an
    // enchant_click for the serve thread (no direct mutation here).
    {
        var cb: [32]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeByte(4); // window 4
        try w.writeShort(1); // player alias slot
        try w.writeByte(0); // left
        try w.writeShort(100); // action
        try w.writeByte(0); // pickup
        try w.writeShort(-1);
        const act = (try feed(&c, 0x0E, w.written())).?;
        try std.testing.expect(act == .enchant_click);
        try std.testing.expectEqual(@as(i16, 1), act.enchant_click.slot);
        // Replay with a stale action number resyncs instead of clicking.
        var cb2: [32]u8 = undefined;
        var w2 = codec.PacketWriter.init(&cb2);
        try w2.writeByte(4);
        try w2.writeShort(1);
        try w2.writeByte(0);
        try w2.writeShort(99); // stale
        try w2.writeByte(0);
        try w2.writeShort(-1);
        try std.testing.expect((try feed(&c, 0x0E, w2.written())).? == .none);
    }
    // 0x11 enchant item parses window + slot.
    {
        var eb: [8]u8 = undefined;
        var w = codec.PacketWriter.init(&eb);
        try w.writeByte(4);
        try w.writeByte(1);
        const act = (try feed(&c, 0x11, w.written())).?;
        try std.testing.expect(act == .enchant);
        try std.testing.expectEqual(@as(u8, 4), act.enchant.window);
        try std.testing.expectEqual(@as(u8, 1), act.enchant.slot);
    }
    // 0x0D close window 4 takes the item out for the serve loop to drop.
    {
        c.enchant_item = .{ .id = game_ids.diamond_sword, .count = 1, .damage = 0, .nbt = null };
        var cb: [8]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeByte(4);
        const act = (try feed(&c, 0x0D, w.written())).?;
        try std.testing.expect(act == .table_close);
        try std.testing.expectEqual(@as(u8, 4), act.table_close.window);
        try std.testing.expectEqual(game_ids.diamond_sword, act.table_close.stacks[0].?.id);
        try std.testing.expect(c.open_win == null);
    }
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
}

test "brewing window: click routing, action seq, close persists" {
    const a = std.testing.allocator;
    var c = mkConn(.{ .gamemode = .survival, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 10);
    defer c.deinit();
    c.state = .play;
    const feed = struct {
        fn run(conn: *Conn, id: i32, body: []const u8) !?Action {
            var f: [128]u8 = undefined;
            try conn.feedData(try codec.framePacket(id, body, &f));
            const fr = (try conn.poll()).?;
            return try conn.handleFrame(fr);
        }
    }.run;
    const click = struct {
        fn run(conn: *Conn, slot: i16, action: i16) !?Action {
            var cb: [32]u8 = undefined;
            var w = codec.PacketWriter.init(&cb);
            try w.writeByte(7); // window 7
            try w.writeShort(slot);
            try w.writeByte(0); // left
            try w.writeShort(action);
            try w.writeByte(0); // pickup
            try w.writeShort(-1);
            return try feed(conn, 0x0E, w.written());
        }
    }.run;
    // Open window 7 directly (server frames it on right-click).
    c.open_win = .{ .id = 7, .x = 8, .y = 64, .z = 8 };
    c.resetClickSeq(7);
    try std.testing.expectEqual(@as(u8, 7), c.open_win.?.id);
    // Clicks resolve to brew_click for the serve thread (slots 0-39).
    {
        const act = (try click(&c, 3, 100)).?;
        try std.testing.expect(act == .brew_click);
        try std.testing.expectEqual(@as(i16, 3), act.brew_click.slot);
        // Replay with a stale action number resyncs instead of clicking.
        try std.testing.expect((try click(&c, 3, 99)).? == .none);
    }
    // Out-of-range slots are refused (40+ is outside the 40-slot window).
    {
        const act = (try click(&c, 40, 101)).?;
        try std.testing.expect(act == .none);
    }
    // 0x0D close window 7 clears the window and reports no drops
    // (contents persist server-side, like the furnace).
    {
        var cb: [8]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeByte(7);
        const act = (try feed(&c, 0x0D, w.written())).?;
        try std.testing.expect(act == .table_close);
        try std.testing.expectEqual(@as(u8, 7), act.table_close.window);
        try std.testing.expect(c.open_win == null);
    }
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
}

test "ender chest: open, pickup/shift/number clicks, close keeps contents" {
    const a = std.testing.allocator;
    var c = mkConn(.{ .gamemode = .survival, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 9);
    defer c.deinit();
    c.state = .play;
    const feed = struct {
        fn run(conn: *Conn, id: i32, body: []const u8) !?Action {
            var f: [64]u8 = undefined;
            try conn.feedData(try codec.framePacket(id, body, &f));
            const fr = (try conn.poll()).?;
            return try conn.handleFrame(fr);
        }
    }.run;
    const click = struct {
        fn run(conn: *Conn, window: u8, slot: i16, button: u8, action: i16, mode: u8) !void {
            var cb: [64]u8 = undefined;
            var w = codec.PacketWriter.init(&cb);
            try w.writeByte(window);
            try w.writeShort(slot);
            try w.writeByte(button);
            try w.writeShort(action);
            try w.writeByte(mode);
            try w.writeShort(-1);
            try w.writeShort(-1);
            var f: [64]u8 = undefined;
            try conn.feedData(try codec.framePacket(0x0E, w.written(), &f));
            const fr = (try conn.poll()).?;
            _ = try conn.handleFrame(fr);
        }
    }.run;
    c.openEnderUI(8, 64, 8);
    try std.testing.expect(c.open_win != null);
    try std.testing.expectEqual(@as(u8, 3), c.open_win.?.id);
    // pickup: ender slot 0 -> cursor -> back
    c.ender[0] = .{ .id = game_ids.stone, .count = 64, .damage = 0, .nbt = null };
    try click(&c, 3, 0, 0, 1, 0);
    try std.testing.expect(c.ender[0] == null);
    try std.testing.expectEqual(game_ids.stone, c.cursor.?.id);
    try click(&c, 3, 0, 0, 2, 0);
    try std.testing.expect(c.cursor == null);
    try std.testing.expectEqual(@as(i8, 64), c.ender[0].?.count);
    // shift-click: ender -> player lands at the hotbar END first (slot 44,
    // vanilla reverse fill), then back to the ender chest
    try click(&c, 3, 0, 0, 3, 1);
    try std.testing.expect(c.ender[0] == null);
    try std.testing.expectEqual(game_ids.stone, c.inv[44].?.id);
    try click(&c, 3, 62, 0, 4, 1);
    try std.testing.expect(c.inv[44] == null);
    try std.testing.expectEqual(game_ids.stone, c.ender[0].?.id);
    // number key: swap ender slot 0 with hotbar slot 0 (inv 36)
    c.inv[36] = .{ .id = game_ids.dirt, .count = 16, .damage = 0, .nbt = null };
    try click(&c, 3, 0, 0, 5, 2);
    try std.testing.expectEqual(game_ids.dirt, c.ender[0].?.id);
    try std.testing.expectEqual(game_ids.stone, c.inv[36].?.id);
    // desync: stale action number refreshes, click ignored
    try click(&c, 3, 0, 0, 5, 0);
    try std.testing.expectEqual(game_ids.dirt, c.ender[0].?.id);
    try std.testing.expect(c.cursor == null);
    // close (0x0D): window 3 drops nothing, contents persist; the close
    // carries the cell pos for the serve-side lid sound + S24 event.
    {
        var cb: [8]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeByte(3);
        const act = (try feed(&c, 0x0D, w.written())).?;
        try std.testing.expect(act == .ender_close);
        try std.testing.expectEqual(@as(i32, 8), act.ender_close.x);
        try std.testing.expectEqual(@as(u8, 64), act.ender_close.y);
        try std.testing.expectEqual(@as(i32, 8), act.ender_close.z);
        try std.testing.expect(c.open_win == null);
        try std.testing.expectEqual(game_ids.dirt, c.ender[0].?.id);
    }
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
}

test "ender chest: drag-spread distributes across cells" {
    const a = std.testing.allocator;
    var c = mkConn(.{ .gamemode = .survival, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 9);
    defer c.deinit();
    c.state = .play;
    const feed = struct {
        fn run(conn: *Conn, id: i32, body: []const u8) !void {
            var f: [64]u8 = undefined;
            try conn.feedData(try codec.framePacket(id, body, &f));
            const fr = (try conn.poll()).?;
            _ = try conn.handleFrame(fr);
        }
    }.run;
    const click = struct {
        fn run(conn: *Conn, window: i8, slot: i16, button: i8, action: i16, mode: i8) !void {
            var cb: [32]u8 = undefined;
            var w = codec.PacketWriter.init(&cb);
            try w.writeByte(@as(u8, @bitCast(window)));
            try w.writeShort(slot);
            try w.writeByte(@as(u8, @bitCast(button)));
            try w.writeShort(action);
            try w.writeByte(@as(u8, @bitCast(mode)));
            try w.writeShort(-1);
            try feed(conn, 0x0E, w.written());
        }
    }.run;
    c.openEnderUI(8, 64, 8);
    // left-drag 6 stone over ender cells 0,1 -> 3/3, cursor empties.
    c.cursor = .{ .id = game_ids.stone, .count = 6, .damage = 0, .nbt = null };
    try click(&c, 3, -999, 0, 20, 5);
    try click(&c, 3, 0, 1, 21, 5);
    try click(&c, 3, 1, 1, 22, 5);
    try click(&c, 3, -999, 2, 23, 5);
    try std.testing.expect(c.cursor == null);
    try std.testing.expectEqual(@as(i8, 3), c.ender[0].?.count);
    try std.testing.expectEqual(@as(i8, 3), c.ender[1].?.count);
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
}

test "enchant clicks survive inventory use: per-window action counters" {
    // Regression for "pick up snaps back in the enchant UI": the client
    // restarts click action numbers with every window open (per-container
    // transactionID), but the server kept one shared expectation — after
    // any inventory use, every enchant click mismatched, echoed the old
    // state, and never healed (rejects don't advance the counter). Each
    // window now has its own expectation, reset on open/close.
    const a = std.testing.allocator;
    var c = mkConn(.{ .gamemode = .survival, .spawn_x = 8, .spawn_y = 64, .spawn_z = 8 }, 7);
    defer c.deinit();
    c.state = .play;
    const feed = struct {
        fn run(conn: *Conn, id: i32, body: []const u8) !?Action {
            var f: [128]u8 = undefined;
            try conn.feedData(try codec.framePacket(id, body, &f));
            const fr = (try conn.poll()).?;
            return try conn.handleFrame(fr);
        }
    }.run;
    const clickWin = struct {
        fn run(conn: *Conn, window: i8, slot: i16, action: i16) !?Action {
            var cb: [32]u8 = undefined;
            var w = codec.PacketWriter.init(&cb);
            try w.writeByte(@as(u8, @bitCast(window)));
            try w.writeShort(slot);
            try w.writeByte(0);
            try w.writeShort(action);
            try w.writeByte(0);
            try w.writeShort(-1);
            return try feed(conn, 0x0E, w.written());
        }
    }.run;
    // Burn window-0 actions deep first (the user moving items around).
    var act_n: i16 = 1;
    while (act_n <= 5) : (act_n += 1) {
        _ = try clickWin(&c, 0, 9, act_n);
    }
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
    // Open the enchant UI: the client's counter restarts, so a fresh
    // action number must be accepted, not snapped back.
    c.openEnchantUI(8, 64, 8, 1234);
    {
        const act = (try clickWin(&c, 4, 1, 1)).?;
        try std.testing.expect(act == .enchant_click);
        const act2 = (try clickWin(&c, 4, 1, 2)).?;
        try std.testing.expect(act2 == .enchant_click);
    }
    // Close + reopen drops the stale expectation: fresh numbers work again.
    {
        var cb: [8]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeByte(4);
        _ = try feed(&c, 0x0D, w.written());
        try std.testing.expect(c.open_win == null);
        c.openEnchantUI(8, 64, 8, 5678);
        const act = (try clickWin(&c, 4, 0, 1)).?;
        try std.testing.expect(act == .enchant_click);
    }
    // A genuinely stale number in the SAME window still resyncs.
    {
        const act = (try clickWin(&c, 4, 0, 1)).?;
        try std.testing.expect(act == .none);
    }
    {
        const o = try c.takeOutput();
        defer a.free(o);
    }
}

test "login grace holds load-falls until echo, move, or timeout" {
    var c = mkConn(.{}, 7);
    defer c.deinit();
    c.state = .play;
    c.baseline_sent = true;
    c.pos_x = 0.5;
    c.pos_y = 69.0;
    c.pos_z = 0.5;
    c.on_ground = true;
    c.armLoginGrace();
    try std.testing.expect(c.login_grace_ms != 0);
    // Exact PosLook echo: synced, grace clears, position adopted.
    c.setPos(0.5, 69.0, 0.5, 10.0, 0.0, true);
    try std.testing.expect(c.login_grace_ms == 0);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), c.yaw, 1e-6);
    // Re-arm: a pure fall below login-1 is held (no save corruption,
    // no phantom fall damage); look still updates. The serve loop
    // re-snaps the client once the ground column is actually delivered.
    c.armLoginGrace();
    c.setPos(0.5, 67.5, 0.5, 20.0, 0.0, false);
    try std.testing.expect(c.login_grace_ms != 0);
    try std.testing.expect(c.login_fell);
    try std.testing.expectApproxEqAbs(@as(f64, 69.0), c.pos_y, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), c.yaw, 1e-6);
    try std.testing.expect(c.pending_fall == null);
    // Horizontal move means the client is live: grace clears, pos adopted.
    c.setPos(2.5, 67.5, 0.5, 20.0, 0.0, false);
    try std.testing.expect(c.login_grace_ms == 0);
    try std.testing.expectApproxEqAbs(@as(f64, 67.5), c.pos_y, 1e-9);
    // Re-arm: centimeter drift while falling (2cm/packet jitter) stays
    // held — a 1mm threshold disarmed on the first drifting packet and
    // adopted the whole fall through solid ground (fallrepro burial).
    // Anchor here is (2.5,67.5,0.5); the drifted fall holds at 67.5.
    c.armLoginGrace();
    c.setPos(2.55, 66.0, 0.52, 20.0, 0.0, false);
    try std.testing.expect(c.login_grace_ms != 0);
    try std.testing.expect(c.login_fell);
    try std.testing.expectApproxEqAbs(@as(f64, 67.5), c.pos_y, 1e-9);
    // Re-arm: small vertical jitter above the threshold is adopted, not held.
    c.armLoginGrace();
    c.setPos(2.5, 67.2, 0.5, 0.0, 0.0, false);
    try std.testing.expect(c.login_grace_ms != 0); // still armed (no echo/move/timeout)
    try std.testing.expectApproxEqAbs(@as(f64, 67.2), c.pos_y, 1e-9);
    // Timeout parks (does not adopt): the serve loop resolves once it
    // can see generation state — adopting a fall through an undelivered
    // column would bury the player in terrain that generates solid
    // around them. Position held at the pre-fall teleport.
    c.login_grace_ms = std.Io.Timestamp.now(c.io, .awake).toMilliseconds() - 1;
    c.setPos(2.5, 60.0, 0.5, 0.0, 0.0, false);
    try std.testing.expect(c.login_grace_ms == 0);
    try std.testing.expect(c.login_grace_lapsed);
    try std.testing.expectApproxEqAbs(@as(f64, 67.2), c.pos_y, 1e-9);
}

test "pre-baseline moves never adopt position" {
    // The client runs physics from world spawn before our login teleport
    // goes out; adopting those packets would clobber the loaded row, the
    // burst would center on the junk, and PosLook would teleport the
    // client to it. Orientation still updates so the client feels live.
    var c = mkConn(.{}, 24);
    defer c.deinit();
    c.state = .play;
    c.pos_x = 11.1;
    c.pos_y = 68.0;
    c.pos_z = 16.3;
    try std.testing.expect(!c.baseline_sent);
    c.setPos(0.5, 72.0, 0.5, 30.0, 10.0, true);
    try std.testing.expectApproxEqAbs(@as(f64, 11.1), c.pos_x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 68.0), c.pos_y, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 16.3), c.pos_z, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 30.0), c.yaw, 1e-6);
    // Post-baseline the same packet adopts normally.
    c.baseline_sent = true;
    c.setPos(0.5, 72.0, 0.5, 30.0, 10.0, true);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), c.pos_x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 72.0), c.pos_y, 1e-9);
}

test "pre-baseline drift never disarms the login grace" {
    // The client runs physics from world spawn before our login teleport
    // goes out, so its first packets always read "far away" — disarming
    // on them would kill the grace before the burst even arrives, and a
    // post-PosLook hole-fall would adopt instead of holding for the
    // resync snap. Horizontal jumps pre-baseline hold the grace (and, via
    // the baseline gate, never adopt); the same jump post-baseline
    // disarms immediately.
    var c = mkConn(.{}, 25);
    defer c.deinit();
    c.state = .play;
    c.pos_x = 0.5;
    c.pos_y = 74.0;
    c.pos_z = 0.5;
    c.armLoginGrace();
    try std.testing.expect(c.login_grace_ms != 0);
    // Far pre-baseline packet (client falling at world spawn): grace holds.
    c.setPos(8.5, 60.0, 8.5, 0.0, 0.0, false);
    try std.testing.expect(c.login_grace_ms != 0);
    try std.testing.expect(c.login_fell);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), c.pos_x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 74.0), c.pos_y, 1e-9);
    // Same jump post-baseline: live input, grace clears, pos adopted.
    c.baseline_sent = true;
    c.armLoginGrace();
    c.setPos(8.5, 60.0, 8.5, 0.0, 0.0, false);
    try std.testing.expect(c.login_grace_ms == 0);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), c.pos_x, 1e-9);
}

test "login grace adopts real landings instead of rubber-banding them" {
    // A deep fall that LANDS (client reports on_ground) is a normal
    // login landing on delivered ground: adopt it so the tick can run
    // fall bookkeeping, instead of holding + resync-snapping until the
    // timeout (the login rubber-band). Airborne falls still hold.
    var c = mkConn(.{}, 26);
    defer c.deinit();
    c.state = .play;
    c.baseline_sent = true;
    c.pos_x = 0.5;
    c.pos_y = 74.0;
    c.pos_z = 0.5;
    c.armLoginGrace();
    // Airborne deep fall: held, no adopt, no fall damage queued.
    c.setPos(0.5, 71.0, 0.5, 0.0, 0.0, false);
    try std.testing.expect(c.login_grace_ms != 0);
    try std.testing.expect(c.login_fell);
    try std.testing.expectApproxEqAbs(@as(f64, 74.0), c.pos_y, 1e-9);
    try std.testing.expect(c.pending_fall == null);
    // Same spot, now landed: adopted (a 2-block landing stashes no
    // pending fall — below damage distance — but the position moves).
    c.setPos(0.5, 72.0, 0.5, 0.0, 0.0, true);
    try std.testing.expectApproxEqAbs(@as(f64, 72.0), c.pos_y, 1e-9);
}

test "join packets order + fields" {
    const a = std.testing.allocator;
    var c = mkConn(.{ .gamemode = .creative }, 1);
    defer c.deinit();
    @memcpy(c.username[0.."Steve".len], "Steve");
    c.username_len = "Steve".len;
    c.state = .play;
    try c.queueJoinPackets(24000, 6000);
    const out = try c.takeOutput();
    defer a.free(out);
    var r = codec.PacketReader.init(out);
    const want = [_]i32{ 0x39, 0x06, 0x1F, 0x38, 0x03 };
    for (want) |id| {
        const h = try codec.decodeFrame(&r);
        try std.testing.expectEqual(id, h.id);
        switch (id) {
            0x39 => {
                try std.testing.expectEqual(@as(u8, 0x0D), try r.readByte()); // creative flags (jar S39 bits)
                _ = try r.readFloat(); // flying speed
                _ = try r.readFloat(); // walking speed
            },
            0x06 => {
                try std.testing.expectApproxEqAbs(@as(f32, 20.0), try r.readFloat(), 1e-6);
                try std.testing.expectEqual(@as(i16, 20), try r.readShort());
                _ = try r.readFloat(); // saturation
            },
            0x1F => {
                try std.testing.expectApproxEqAbs(@as(f32, 0.0), try r.readFloat(), 1e-9);
                _ = try r.readShort(); // level
                _ = try r.readShort(); // total xp
            },
            0x38 => {
                try std.testing.expectEqualStrings("Steve", try r.readString());
                try std.testing.expect(try r.readBool());
                _ = try r.readShort(); // ping
            },
            0x03 => {
                try std.testing.expectEqual(@as(i64, 24000), try r.readLong());
                try std.testing.expectEqual(@as(i64, 6000), try r.readLong());
            },
            else => unreachable,
        }
    }
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "queueTick cadence + timeout" {
    const a = std.testing.allocator;
    var c = mkConn(.{}, 1);
    defer c.deinit();
    c.state = .play;
    // t=0: time + keepalive
    try std.testing.expectEqual(Conn.TickAction.none, try c.queueTick(0, 0, 6000));
    {
        const out = try c.takeOutput();
        defer a.free(out);
        var r = codec.PacketReader.init(out);
        try std.testing.expectEqual(@as(i32, 0x03), (try codec.decodeFrame(&r)).id);
        _ = try r.readLong();
        _ = try r.readLong();
        try std.testing.expectEqual(@as(i32, 0x00), (try codec.decodeFrame(&r)).id);
        try std.testing.expect(c.keepalive_outstanding);
    }
    // t=500: nothing
    try std.testing.expectEqual(Conn.TickAction.none, try c.queueTick(500, 20, 6020));
    {
        const out = try c.takeOutput();
        defer a.free(out);
        try std.testing.expectEqual(@as(usize, 0), out.len);
    }
    // t=1000: time only (keepalive next due at 15000)
    try std.testing.expectEqual(Conn.TickAction.none, try c.queueTick(1000, 40, 6040));
    {
        const out = try c.takeOutput();
        defer a.free(out);
        var r = codec.PacketReader.init(out);
        try std.testing.expectEqual(@as(i32, 0x03), (try codec.decodeFrame(&r)).id);
        _ = try r.readLong();
        _ = try r.readLong();
        try std.testing.expectEqual(@as(usize, 0), r.remaining());
    }
    // no echo for 30s after the ping sent at t=0 -> timeout at t=31000
    try std.testing.expectEqual(Conn.TickAction.timeout, try c.queueTick(31001, 620, 6600));
    try std.testing.expect(c.dead);
    {
        const out = try c.takeOutput();
        defer a.free(out);
        var r = codec.PacketReader.init(out);
        try std.testing.expectEqual(@as(i32, 0x40), (try codec.decodeFrame(&r)).id);
    }
    // dead conns stay silent
    try std.testing.expectEqual(Conn.TickAction.none, try c.queueTick(999999, 0, 0));
    {
        const out = try c.takeOutput();
        defer a.free(out);
        try std.testing.expectEqual(@as(usize, 0), out.len);
    }
}

test "recent echo prevents kick, stale echo kicks" {
    const a = std.testing.allocator;
    var c = mkConn(.{}, 1);
    defer c.deinit();
    c.state = .play;
    try std.testing.expectEqual(Conn.TickAction.none, try c.queueTick(0, 0, 6000));
    {
        const drained = try c.takeOutput();
        defer a.free(drained);
    }
    // echo at t=10, then quiet: no kick at t=20000 (10s of silence)
    c.last_echo_ms = 10;
    c.keepalive_outstanding = false;
    try std.testing.expectEqual(Conn.TickAction.none, try c.queueTick(20000, 0, 0));
    try std.testing.expect(!c.dead);
    {
        const drained = try c.takeOutput();
        defer a.free(drained);
    }
    // ...but kicked once silence exceeds 30s
    try std.testing.expectEqual(Conn.TickAction.timeout, try c.queueTick(40000, 0, 0));
    try std.testing.expect(c.dead);
}

test "online login full handshake (mock Mojang)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var keys = try rsa_mod.ensureKeys(io, a, tmp.dir, "o_rsa.key", "o_rsa.der");
    defer keys.deinit();

    // mock session server: one-shot HTTP responder
    var port: u16 = 38131;
    const mock_json = "{\"id\":\"069a79f444e94726a5bef2a2fce1b293\",\"name\":\"Steve\"}";
    const Mock = struct {
        var json_body: []const u8 = "";
        var listen_port: u16 = 0;
        fn run(mock_io: std.Io) void {
            const addr = std.Io.net.IpAddress.parse("127.0.0.1", listen_port) catch return;
            var srv = addr.listen(mock_io, .{}) catch return;
            defer srv.deinit(mock_io);
            var stream = srv.accept(mock_io) catch return;
            defer stream.close(mock_io);
            var rbuf: [2048]u8 = undefined;
            var reader = stream.reader(mock_io, &rbuf);
            // read headers until \r\n\r\n
            var tail: [4]u8 = .{ 0, 0, 0, 0 };
            while (true) {
                const b = reader.interface.takeByte() catch return;
                tail[0] = tail[1];
                tail[1] = tail[2];
                tail[2] = tail[3];
                tail[3] = b;
                if (std.mem.eql(u8, &tail, "\r\n\r\n")) break;
            }
            var wbuf: [512]u8 = undefined;
            var writer = stream.writer(mock_io, &wbuf);
            writer.interface.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body }) catch return;
            writer.interface.flush() catch return;
        }
    };
    // find a free port by binding probe
    while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        var probe = addr.listen(io, .{}) catch {
            port += 1;
            if (port > 38230) return error.NoFreePort;
            continue;
        };
        probe.deinit(io);
        break;
    }
    Mock.json_body = mock_json;
    Mock.listen_port = port;
    const th = try std.Thread.spawn(.{}, Mock.run, .{io});
    errdefer th.join();

    var auth_url_buf: [64]u8 = undefined;
    const auth_url = try std.fmt.bufPrint(&auth_url_buf, "http://127.0.0.1:{d}/hasJoined", .{port});
    const cfg = Config{ .online_mode = true, .rsa = &keys, .auth_url = auth_url };
    var c = Conn.init(a, io, cfg, 9);
    defer c.deinit();

    // handshake(login) + login start
    var hb: [64]u8 = undefined;
    var w = codec.PacketWriter.init(&hb);
    try w.writeVarInt(5);
    try w.writeString("localhost");
    try w.writeUShort(25565);
    try w.writeVarInt(2);
    var hf: [80]u8 = undefined;
    try c.feedData(try codec.framePacket(0x00, w.written(), &hf));
    _ = try c.handleFrame((try c.poll()).?);
    var lb: [32]u8 = undefined;
    var wl = codec.PacketWriter.init(&lb);
    try wl.writeString("Steve");
    var lf: [48]u8 = undefined;
    try c.feedData(try codec.framePacket(0x00, wl.written(), &lf));
    _ = try c.handleFrame((try c.poll()).?);
    // server must have emitted EncryptionRequest and nothing else yet
    const enc_req_out = try c.takeOutput();
    defer a.free(enc_req_out);
    var r = codec.PacketReader.init(enc_req_out);
    const h = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 0x01), h.id);
    try std.testing.expectEqualStrings("", try r.readString());
    const pk_len = try r.readShort();
    try std.testing.expectEqual(@as(i16, @intCast(keys.public_key_der.len)), pk_len);
    try std.testing.expectEqualSlices(u8, keys.public_key_der, try r.readBytes(@intCast(pk_len)));
    const tok_len = try r.readShort();
    try std.testing.expectEqual(@as(i16, 4), tok_len);
    const token = try r.readBytes(4);
    try std.testing.expectEqualSlices(u8, &c.verify_token, token);

    // client side: encrypt secret + token with server pubkey
    const shared: [16]u8 = .{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160 };
    const enc_secret = try keys.encryptPkcs1v15(io, a, &shared);
    const enc_token = try keys.encryptPkcs1v15(io, a, token);
    var rb: [600]u8 = undefined;
    var wr = codec.PacketWriter.init(&rb);
    try wr.writeShort(@intCast(enc_secret.len));
    try wr.writeBytes(&enc_secret);
    try wr.writeShort(@intCast(enc_token.len));
    try wr.writeBytes(&enc_token);
    var rf: [640]u8 = undefined;
    try c.feedData(try codec.framePacket(0x01, wr.written(), &rf));
    const act = try c.handleFrame((try c.poll()).?);
    try std.testing.expectEqual(Action.entered_play, act);
    try std.testing.expect(c.state == .play);
    th.join();

    // output is encrypted now: decrypt client-side and check LoginSuccess
    const enc_out = try c.takeOutput();
    defer a.free(enc_out);
    var dec = cfb8.Cfb8.init(&shared);
    dec.decrypt(enc_out);
    var r2 = codec.PacketReader.init(enc_out);
    const lh = try codec.decodeFrame(&r2);
    try std.testing.expectEqual(@as(i32, 0x02), lh.id);
    try std.testing.expectEqualStrings("069a79f4-44e9-4726-a5be-f2a2fce1b293", try r2.readString());
    try std.testing.expectEqualStrings("Steve", try r2.readString());
}

test "online login session rejected sends encrypted disconnect (no CCE)" {
    // Regression: the client enables encryption the moment it sends
    // EncryptionResponse, so a hasJoined failure kick must go out
    // encrypted. Unencrypted failure kicks garble client-side and surface
    // as "biz cannot be cast to fv" instead of the kick message.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var keys = try rsa_mod.ensureKeys(io, a, tmp.dir, "o2_rsa.key", "o2_rsa.der");
    defer keys.deinit();

    // mock session server: always 204 (unknown user) -> SessionRejected
    var port: u16 = 38251;
    const Mock = struct {
        var listen_port: u16 = 0;
        fn run(mock_io: std.Io) void {
            const addr = std.Io.net.IpAddress.parse("127.0.0.1", listen_port) catch return;
            var srv = addr.listen(mock_io, .{}) catch return;
            defer srv.deinit(mock_io);
            var stream = srv.accept(mock_io) catch return;
            defer stream.close(mock_io);
            var rbuf: [2048]u8 = undefined;
            var reader = stream.reader(mock_io, &rbuf);
            var tail: [4]u8 = .{ 0, 0, 0, 0 };
            while (true) {
                const b = reader.interface.takeByte() catch return;
                tail[0] = tail[1];
                tail[1] = tail[2];
                tail[2] = tail[3];
                tail[3] = b;
                if (std.mem.eql(u8, &tail, "\r\n\r\n")) break;
            }
            var wbuf: [256]u8 = undefined;
            var writer = stream.writer(mock_io, &wbuf);
            writer.interface.print("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{}) catch return;
            writer.interface.flush() catch return;
        }
    };
    while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        var probe = addr.listen(io, .{}) catch {
            port += 1;
            if (port > 38350) return error.NoFreePort;
            continue;
        };
        probe.deinit(io);
        break;
    }
    Mock.listen_port = port;
    const th = try std.Thread.spawn(.{}, Mock.run, .{io});
    errdefer th.join();

    var auth_url_buf: [64]u8 = undefined;
    const auth_url = try std.fmt.bufPrint(&auth_url_buf, "http://127.0.0.1:{d}/hasJoined", .{port});
    const cfg = Config{ .online_mode = true, .rsa = &keys, .auth_url = auth_url };
    var c = Conn.init(a, io, cfg, 9);
    defer c.deinit();

    var hb: [64]u8 = undefined;
    var w = codec.PacketWriter.init(&hb);
    try w.writeVarInt(5);
    try w.writeString("localhost");
    try w.writeUShort(25565);
    try w.writeVarInt(2);
    var hf: [80]u8 = undefined;
    try c.feedData(try codec.framePacket(0x00, w.written(), &hf));
    _ = try c.handleFrame((try c.poll()).?);
    var lb: [32]u8 = undefined;
    var wl = codec.PacketWriter.init(&lb);
    try wl.writeString("Steve");
    var lf: [48]u8 = undefined;
    try c.feedData(try codec.framePacket(0x00, wl.written(), &lf));
    _ = try c.handleFrame((try c.poll()).?);
    // consume EncryptionRequest to learn the verify token
    const enc_req_out = try c.takeOutput();
    defer a.free(enc_req_out);
    var r = codec.PacketReader.init(enc_req_out);
    _ = try codec.decodeFrame(&r);
    _ = try r.readString();
    const pk_len = try r.readShort();
    _ = try r.readBytes(@intCast(pk_len));
    _ = try r.readShort();
    const token = try r.readBytes(4);

    const shared: [16]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const enc_secret = try keys.encryptPkcs1v15(io, a, &shared);
    const enc_token = try keys.encryptPkcs1v15(io, a, token);
    var rb: [600]u8 = undefined;
    var wr = codec.PacketWriter.init(&rb);
    try wr.writeShort(@intCast(enc_secret.len));
    try wr.writeBytes(&enc_secret);
    try wr.writeShort(@intCast(enc_token.len));
    try wr.writeBytes(&enc_token);
    var rf: [640]u8 = undefined;
    try c.feedData(try codec.framePacket(0x01, wr.written(), &rf));
    const act = try c.handleFrame((try c.poll()).?);
    try std.testing.expectEqual(Action.disconnect_queued, act);
    try std.testing.expect(c.state == .login);
    th.join();

    // The kick must be encrypted with the shared secret (client already
    // switched): decrypt and check it is a login disconnect (0x00) with
    // the verify-failure message.
    const kick_out = try c.takeOutput();
    defer a.free(kick_out);
    // Sanity: plaintext parse must NOT look like a valid login disconnect
    // (it is ciphertext now).
    {
        var rp = codec.PacketReader.init(kick_out);
        const hp = try codec.decodeFrame(&rp);
        var looks_plain = false;
        if (hp.id == 0x00) {
            if (rp.readString()) |s| {
                if (std.mem.indexOf(u8, s, "Failed to verify") != null) looks_plain = true;
            } else |_| {}
        }
        try std.testing.expect(!looks_plain);
    }
    var dec = cfb8.Cfb8.init(&shared);
    dec.decrypt(kick_out);
    var r2 = codec.PacketReader.init(kick_out);
    const kh = try codec.decodeFrame(&r2);
    try std.testing.expectEqual(@as(i32, 0x00), kh.id);
    const msg = try r2.readString();
    try std.testing.expect(std.mem.indexOf(u8, msg, "Failed to verify username!") != null);
}
test "armor: right-click air proposes equip, shift-click moves, slots validate" {
    const a = std.testing.allocator;
    // Right-click air (0x08 direction -1) with armor held -> equip_armor.
    {
        var c = mkConn(.{}, 7);
        defer c.deinit();
        c.state = .play;
        c.inv[36] = .{ .id = game_ids.iron_helmet, .count = 1, .damage = 0, .nbt = null };
        try std.testing.expect(c.onPlace(8, 64, 8, -1, 0) == .equip_armor);
        // Non-armor air-click has no use yet; empty hand the same.
        c.inv[36] = .{ .id = game_ids.dirt, .count = 1, .damage = 0, .nbt = null };
        try std.testing.expect(c.onPlace(8, 64, 8, -1, 0) == .none);
        c.inv[36] = null;
        try std.testing.expect(c.onPlace(8, 64, 8, -1, 0) == .none);
    }
    // applyEquipArmor moves one piece + queues both 0x2F updates.
    {
        var c = mkConn(.{}, 7);
        defer c.deinit();
        c.state = .play;
        c.inv[36] = .{ .id = game_ids.diamond_chestplate, .count = 1, .damage = 0, .nbt = null };
        try std.testing.expect(c.applyEquipArmor());
        try std.testing.expect(c.inv[36] == null);
        try std.testing.expect(c.inv[6] != null);
        try std.testing.expectEqual(game_ids.diamond_chestplate, c.inv[6].?.id);
        try std.testing.expectEqual(@as(i8, 1), c.inv[6].?.count);
        const out = try c.takeOutput();
        defer a.free(out);
        var off: usize = 0;
        var slots = [_]i16{ -2, -2 };
        var si: usize = 0;
        while (off < out.len and si < 2) : (si += 1) {
            var rr = codec.PacketReader.init(out[off..]);
            const h = try codec.decodeFrame(&rr);
            try std.testing.expectEqual(@as(i32, 0x2F), h.id);
            _ = try rr.readByte(); // window 0
            slots[si] = try rr.readShort();
            off = out.len - rr.remaining();
        }
        try std.testing.expectEqual(@as(usize, 2), si);
        try std.testing.expectEqual(@as(i16, 36), slots[0]);
        try std.testing.expectEqual(@as(i16, 6), slots[1]);
        // Occupied armor slot: no-op, held stays.
        c.inv[36] = .{ .id = game_ids.iron_boots, .count = 1, .damage = 0, .nbt = null };
        c.inv[8] = .{ .id = game_ids.leather_boots, .count = 1, .damage = 0, .nbt = null };
        try std.testing.expect(!c.applyEquipArmor());
        try std.testing.expect(c.inv[36] != null);
        try std.testing.expectEqual(game_ids.leather_boots, c.inv[8].?.id);
    }
    // Shift-click armor from the pack -> armor slot; occupied -> stays.
    {
        var c = mkConn(.{}, 7);
        defer c.deinit();
        c.state = .play;
        c.inv[9] = .{ .id = game_ids.golden_leggings, .count = 1, .damage = 0, .nbt = null };
        var cb: [32]u8 = undefined;
        var w = codec.PacketWriter.init(&cb);
        try w.writeByte(0); // window 0
        try w.writeShort(9);
        try w.writeByte(0);
        try w.writeShort(1); // action 1 (first click seeds)
        try w.writeByte(1); // shift mode
        try w.writeShort(-1); // clicked echo: empty
        var f: [64]u8 = undefined;
        try c.feedData(try codec.framePacket(0x0E, w.written(), &f));
        _ = try c.handleFrame((try c.poll()).?);
        try std.testing.expect(c.inv[9] == null);
        try std.testing.expect(c.inv[7] != null);
        try std.testing.expectEqual(game_ids.golden_leggings, c.inv[7].?.id);
        // Occupied now: a second piece stays in the pack.
        c.inv[10] = .{ .id = game_ids.iron_leggings, .count = 1, .damage = 0, .nbt = null };
        var cb2: [32]u8 = undefined;
        var w2 = codec.PacketWriter.init(&cb2);
        try w2.writeByte(0);
        try w2.writeShort(10);
        try w2.writeByte(0);
        try w2.writeShort(2);
        try w2.writeByte(1);
        try w2.writeShort(-1);
        var f2: [64]u8 = undefined;
        try c.feedData(try codec.framePacket(0x0E, w2.written(), &f2));
        _ = try c.handleFrame((try c.poll()).?);
        try std.testing.expect(c.inv[10] != null);
        try std.testing.expectEqual(game_ids.golden_leggings, c.inv[7].?.id);
        // Mode-0 onto an armor slot rejects the wrong kind, takes the right one.
        c.cursor = .{ .id = game_ids.dirt, .count = 1, .damage = 0, .nbt = null };
        var cb3: [64]u8 = undefined;
        var w3 = codec.PacketWriter.init(&cb3);
        try w3.writeByte(0);
        try w3.writeShort(5);
        try w3.writeByte(0);
        try w3.writeShort(3);
        try w3.writeByte(0); // pickup mode
        try w3.writeShort(-1);
        var f3: [64]u8 = undefined;
        try c.feedData(try codec.framePacket(0x0E, w3.written(), &f3));
        _ = try c.handleFrame((try c.poll()).?);
        try std.testing.expect(c.inv[5] == null);
        try std.testing.expect(c.cursor != null);
        var owned: ?item_mod.Stack = c.cursor;
        item_mod.freeStack(a, &owned);
        c.cursor = .{ .id = game_ids.leather_helmet, .count = 1, .damage = 0, .nbt = null };
        var cb4: [64]u8 = undefined;
        var w4 = codec.PacketWriter.init(&cb4);
        try w4.writeByte(0);
        try w4.writeShort(5);
        try w4.writeByte(0);
        try w4.writeShort(4);
        try w4.writeByte(0);
        try w4.writeShort(-1);
        var f4: [64]u8 = undefined;
        try c.feedData(try codec.framePacket(0x0E, w4.written(), &f4));
        _ = try c.handleFrame((try c.poll()).?);
        try std.testing.expect(c.cursor == null);
        try std.testing.expect(c.inv[5] != null);
        try std.testing.expectEqual(game_ids.leather_helmet, c.inv[5].?.id);
        {
            const o = try c.takeOutput();
            defer a.free(o);
        }
    }
}


