//! 1.7.10 (proto v5) packet bodies: status / login / play-bootstrap.
//!
//! Convention: `frame*` returns a complete Length-prefixed frame in `out`.
//! `parse*` borrows slices from the caller's body buffer (zero-copy).
//! Play IDs follow the widely-used 1.7.10 table (see ids.zig); the bootstrap
//! path below (JoinGame/SpawnPosition/PlayerPositionAndLook) MUST be verified
//! against a live 1.7.10 capture before release.

const std = @import("std");
const codec = @import("../../net/codec.zig");
const ids = @import("ids.zig");
const item_mod = @import("../../item.zig");
const slot_mod = @import("slot.zig");
const game_ids = @import("../../ids.zig");
const wire = @import("wire_ids.zig");

// ---------- handshaking ----------

pub const Handshake = struct {
    protocol: i32,
    address: []const u8,
    port: u16,
    next: i32,
};

pub fn parseHandshake(body: []const u8) codec.CodecError!Handshake {
    var r = codec.PacketReader.init(body);
    const protocol = try r.readVarInt();
    const address = try r.readString();
    const port = try r.readUShort();
    const next = try r.readVarInt();
    return .{ .protocol = protocol, .address = address, .port = port, .next = next };
}

// ---------- status ----------

pub fn frameStatusResponse(json: []const u8, out: []u8) codec.CodecError![]const u8 {
    var payload: [codec.max_string_bytes + 4]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeString(json);
    return try codec.framePacket(@intFromEnum(ids.StatusClient.response), w.written(), out);
}

pub fn parsePing(body: []const u8) codec.CodecError!i64 {
    var r = codec.PacketReader.init(body);
    return try r.readLong();
}

pub fn framePong(payload: i64, out: []u8) codec.CodecError![]const u8 {
    var pb: [8]u8 = undefined;
    std.mem.writeInt(i64, &pb, payload, .big);
    return try codec.framePacket(@intFromEnum(ids.StatusClient.pong), &pb, out);
}

// ---------- login ----------

/// Returns player name slice (borrows body).
pub fn parseLoginStart(body: []const u8) codec.CodecError![]const u8 {
    var r = codec.PacketReader.init(body);
    return try r.readString();
}

pub const EncryptionRequest = struct {
    server_id: []const u8,
    pubkey: []const u8,
    token: []const u8,
};

pub fn frameEncryptionRequest(server_id: []const u8, pubkey: []const u8, token: []const u8, out: []u8) codec.CodecError![]const u8 {
    var body: [4096]u8 = undefined;
    var w = codec.PacketWriter.init(&body);
    try w.writeString(server_id);
    try w.writeShort(@intCast(pubkey.len));
    try w.writeBytes(pubkey);
    try w.writeShort(@intCast(token.len));
    try w.writeBytes(token);
    return try codec.framePacket(@intFromEnum(ids.LoginClient.encryption_request), w.written(), out);
}

pub const EncryptionResponse = struct {
    secret: []const u8, // RSA-decrypted shared secret (caller decrypts)
    token: []const u8, // RSA-decrypted verify token
};

/// Parses the length-prefixed encrypted blobs (still encrypted; RSA step is separate).
pub fn parseEncryptionResponse(body: []const u8) codec.CodecError!struct { secret_enc: []const u8, token_enc: []const u8 } {
    var r = codec.PacketReader.init(body);
    const slen = try r.readShort();
    if (slen < 0) return error.InvalidLength;
    const secret_enc = try r.readBytes(@intCast(slen));
    const tlen = try r.readShort();
    if (tlen < 0) return error.InvalidLength;
    const token_enc = try r.readBytes(@intCast(tlen));
    return .{ .secret_enc = secret_enc, .token_enc = token_enc };
}

pub fn frameLoginSuccess(uuid_str: []const u8, name: []const u8, out: []u8) codec.CodecError![]const u8 {
    var body: [128]u8 = undefined;
    var w = codec.PacketWriter.init(&body);
    try w.writeString(uuid_str);
    try w.writeString(name);
    return try codec.framePacket(@intFromEnum(ids.LoginClient.login_success), w.written(), out);
}

pub fn frameLoginDisconnect(json: []const u8, out: []u8) codec.CodecError![]const u8 {
    var payload: [codec.max_string_bytes + 4]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeString(json);
    return try codec.framePacket(@intFromEnum(ids.LoginClient.disconnect), w.written(), out);
}

// ---------- play bootstrap ----------

pub const JoinGame = struct {
    eid: i32,
    gamemode: u8,
    dimension: i8,
    difficulty: u8,
    max_players: u8,
    level_type: []const u8,
};

pub fn frameJoinGame(j: JoinGame, out: []u8) codec.CodecError![]const u8 {
    var body: [256]u8 = undefined;
    var w = codec.PacketWriter.init(&body);
    try w.writeInt(j.eid);
    try w.writeByte(j.gamemode);
    try w.writeByte(@bitCast(j.dimension));
    try w.writeByte(j.difficulty);
    try w.writeByte(j.max_players);
    try w.writeString(j.level_type);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.join_game), w.written(), out);
}

pub fn parseJoinGame(body: []const u8) codec.CodecError!JoinGame {
    var r = codec.PacketReader.init(body);
    const eid = try r.readInt();
    const gamemode = try r.readByte();
    const dimension: i8 = @bitCast(try r.readByte());
    const difficulty = try r.readByte();
    const max_players = try r.readByte();
    const level_type = try r.readString();
    return .{ .eid = eid, .gamemode = gamemode, .dimension = dimension, .difficulty = difficulty, .max_players = max_players, .level_type = level_type };
}

pub fn frameSpawnPosition(x: i32, y: i32, z: i32, out: []u8) codec.CodecError![]const u8 {
    var pb: [12]u8 = undefined;
    std.mem.writeInt(i32, pb[0..4], x, .big);
    std.mem.writeInt(i32, pb[4..8], y, .big);
    std.mem.writeInt(i32, pb[8..12], z, .big);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.spawn_position), &pb, out);
}

/// Respawn 0x07 (same-dimension refresh; dimension change is P-next).
pub fn frameRespawn(dimension: i32, difficulty: u8, gamemode: u8, level_type: []const u8, out: []u8) codec.CodecError![]const u8 {
    var payload: [256]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(dimension);
    try w.writeByte(difficulty);
    try w.writeByte(gamemode);
    try w.writeString(level_type);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.respawn), w.written(), out);
}

/// Time Update 0x03.
pub fn frameTimeUpdate(world_age: i64, time_of_day: i64, out: []u8) codec.CodecError![]const u8 {
    var pb: [16]u8 = undefined;
    std.mem.writeInt(i64, pb[0..8], world_age, .big);
    std.mem.writeInt(i64, pb[8..16], time_of_day, .big);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.time_update), &pb, out);
}

/// Player Abilities 0x39. flags bit0=creative,bit1=flying,bit2=fly-allowed,bit3=god.
/// S39 ability flags (jar-verified `hk.b`: bit0 = disableDamage,
/// bit1 = isFlying, bit2 = allowFlying, bit3 = isCreativeMode). Grounded
/// creative = 0x0D, survival/adventure = 0x00.
pub fn abilityFlags(creative: bool) u8 {
    return if (creative) 0x0D else 0x00;
}

pub fn framePlayerAbilities(flags: u8, flying_speed: f32, walking_speed: f32, out: []u8) codec.CodecError![]const u8 {
    var pb: [9]u8 = undefined;
    pb[0] = flags;
    std.mem.writeInt(u32, pb[1..5], @bitCast(flying_speed), .big);
    std.mem.writeInt(u32, pb[5..9], @bitCast(walking_speed), .big);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.player_abilities), &pb, out);
}

/// Update Health 0x06.
pub fn frameUpdateHealth(health: f32, food: i16, saturation: f32, out: []u8) codec.CodecError![]const u8 {
    var pb: [10]u8 = undefined;
    std.mem.writeInt(u32, pb[0..4], @bitCast(health), .big);
    std.mem.writeInt(i16, pb[4..6], food, .big);
    std.mem.writeInt(u32, pb[6..10], @bitCast(saturation), .big);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.update_health), &pb, out);
}

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

/// Set Experience 0x1F.
pub fn frameSetExperience(bar: f32, level: i16, total: i16, out: []u8) codec.CodecError![]const u8 {
    var pb: [8]u8 = undefined;
    std.mem.writeInt(u32, pb[0..4], @bitCast(bar), .big);
    std.mem.writeInt(i16, pb[4..6], level, .big);
    std.mem.writeInt(i16, pb[6..8], total, .big);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.set_experience), &pb, out);
}

/// Player List Item 0x38 (1.7 form: name/online/ping, NOT uuid-based).
/// online=false removes the entry.
pub fn framePlayerListItem(name: []const u8, online: bool, ping_ms: i16, out: []u8) codec.CodecError![]const u8 {
    var payload: [64]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeString(name);
    try w.writeByte(if (online) 1 else 0);
    try w.writeShort(ping_ms);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.player_list_item), w.written(), out);
}

pub const PlayerPosLook = struct {
    x: f64,
    y: f64,
    z: f64,
    yaw: f32,
    pitch: f32,
    on_ground: bool,
};

pub fn framePlayerPosLook(p: PlayerPosLook, out: []u8) codec.CodecError![]const u8 {
    var pb: [33]u8 = undefined;
    std.mem.writeInt(u64, pb[0..8], @bitCast(p.x), .big);
    std.mem.writeInt(u64, pb[8..16], @bitCast(p.y), .big);
    std.mem.writeInt(u64, pb[16..24], @bitCast(p.z), .big);
    std.mem.writeInt(u32, pb[24..28], @bitCast(p.yaw), .big);
    std.mem.writeInt(u32, pb[28..32], @bitCast(p.pitch), .big);
    pb[32] = if (p.on_ground) 1 else 0;
    return try codec.framePacket(@intFromEnum(ids.PlayClient.player_position_and_look), &pb, out);
}

pub fn frameKeepAlive(id: i32, out: []u8) codec.CodecError![]const u8 {
    var pb: [4]u8 = undefined;
    std.mem.writeInt(i32, &pb, id, .big);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.keep_alive), &pb, out);
}

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

/// Serverbound chat 0x01: plain-text message (validated by caller).
pub fn parseChat(body: []const u8) codec.CodecError![]const u8 {
    var r = codec.PacketReader.init(body);
    return try r.readString();
}

/// Clientbound chat 0x02: pre-formatted JSON string.
pub fn frameChat(json: []const u8, out: []u8) codec.CodecError![]const u8 {
    var payload: [4096]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeString(json);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.chat_message), w.written(), out);
}

/// Escape one raw string for embedding in JSON (quotes, backslashes,
/// control chars). Rejects invalid UTF-8 like formatChatJson does.
pub fn escapeJsonText(in: []const u8, out: []u8) error{ BadMessage, OutOfMemory }![]const u8 {
    if (!std.unicode.utf8ValidateSlice(in)) return error.BadMessage;
    const hex = "0123456789abcdef";
    var p: usize = 0;
    for (in) |c| {
        if (c == '"') {
            if (p + 2 > out.len) return error.OutOfMemory;
            out[p] = '\\';
            out[p + 1] = '"';
            p += 2;
        } else if (c == '\\') {
            if (p + 2 > out.len) return error.OutOfMemory;
            out[p] = '\\';
            out[p + 1] = '\\';
            p += 2;
        } else if (c == '\n') {
            if (p + 2 > out.len) return error.OutOfMemory;
            out[p] = '\\';
            out[p + 1] = 'n';
            p += 2;
        } else if (c == '\r') {
            if (p + 2 > out.len) return error.OutOfMemory;
            out[p] = '\\';
            out[p + 1] = 'r';
            p += 2;
        } else if (c == '\t') {
            if (p + 2 > out.len) return error.OutOfMemory;
            out[p] = '\\';
            out[p + 1] = 't';
            p += 2;
        } else if (c < 0x20) {
            if (p + 6 > out.len) return error.OutOfMemory;
            out[p] = '\\';
            out[p + 1] = 'u';
            out[p + 2] = '0';
            out[p + 3] = '0';
            out[p + 4] = hex[c >> 4];
            out[p + 5] = hex[c & 0xF];
            p += 6;
        } else {
            if (p + 1 > out.len) return error.OutOfMemory;
            out[p] = c;
            p += 1;
        }
    }
    return out[0..p];
}

/// `<name> message` chat line as JSON with escaping. Rejects invalid UTF-8,
/// overlong messages (>100 code points, mirroring the vanilla client cap),
/// and names with characters outside [A-Za-z0-9_].
pub fn formatChatJson(name: []const u8, msg: []const u8, out: []u8) error{ BadName, BadMessage, OutOfMemory }![]const u8 {
    if (name.len == 0 or name.len > 16) return error.BadName;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return error.BadName;
    }
    if (!std.unicode.utf8ValidateSlice(msg)) return error.BadMessage;
    const points = std.unicode.utf8CountCodepoints(msg) catch return error.BadMessage;
    if (points == 0 or points > 100) return error.BadMessage;
    const hex = "0123456789abcdef";
    var p: usize = 0;
    const put = struct {
        fn s(o: []u8, pp: *usize, s_: []const u8) error{OutOfMemory}!void {
            if (pp.* + s_.len > o.len) return error.OutOfMemory;
            @memcpy(o[pp.*..][0..s_.len], s_);
            pp.* += s_.len;
        }
        fn c(o: []u8, pp: *usize, ch: u8) error{OutOfMemory}!void {
            if (pp.* + 1 > o.len) return error.OutOfMemory;
            o[pp.*] = ch;
            pp.* += 1;
        }
    };
    try put.s(out, &p, "{\"text\":\"<");
    try put.s(out, &p, name);
    try put.s(out, &p, "> ");
    for (msg) |c| {
        if (c == '"') {
            try put.s(out, &p, "\\\"");
        } else if (c == '\\') {
            try put.s(out, &p, "\\\\");
        } else if (c == '\n') {
            try put.s(out, &p, "\\n");
        } else if (c == '\r') {
            try put.s(out, &p, "\\r");
        } else if (c == '\t') {
            try put.s(out, &p, "\\t");
        } else if (c < 0x20) {
            try put.s(out, &p, "\\u00");
            try put.c(out, &p, hex[c >> 4]);
            try put.c(out, &p, hex[c & 0xF]);
        } else {
            try put.c(out, &p, c);
        }
    }
    try put.s(out, &p, "\"}");
    return out[0..p];
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

/// Open Window 0x2D (crafting table = type 1, 9 slots; title + slot count).
/// use_provided_title is always true here (vanilla sends the container name).
pub fn frameOpenWindow(window: u8, inv_type: u8, title: []const u8, slot_count: u8, out: []u8) codec.CodecError![]const u8 {
    var payload: [128]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeByte(window);
    try w.writeByte(inv_type);
    try w.writeString(title);
    try w.writeByte(slot_count);
    try w.writeByte(1); // useProvidedTitle
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

/// Block Change 0x23 (1.7 form: separate id VarInt + meta u8, NOT packed).
pub fn frameBlockChange(x: i32, y: u8, z: i32, id: game_ids.Id, meta: u8, out: []u8) codec.CodecError![]const u8 {
    var payload: [16]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(x);
    try w.writeByte(y);
    try w.writeInt(z);
    try w.writeVarInt(@as(i32, wire.toWire(id)));
    try w.writeByte(meta);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.block_change), w.written(), out);
}

/// Block Action 0x24 (1.7.10: x, y as unsigned byte, z, byte1, byte2,
/// VarInt blockId). Pistons animate the vanilla client from this packet —
/// the client re-runs `onBlockEventReceived` locally and derives the same
/// final blocks, so the server must NOT also echo 0x23 for those cells.
pub fn frameBlockAction(x: i32, y: u16, z: i32, byte1: u8, byte2: u8, block_id: u16, out: []u8) codec.CodecError![]const u8 {
    var payload: [20]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(x);
    try w.writeShort(@intCast(y));
    try w.writeInt(z);
    try w.writeByte(byte1);
    try w.writeByte(byte2);
    try w.writeVarInt(@as(i32, block_id));
    return try codec.framePacket(@intFromEnum(ids.PlayClient.block_action), w.written(), out);
}

/// Animation 0x0B (swing arm etc, relayed to viewers).
pub fn frameAnimation(eid: i32, animation: u8, out: []u8) codec.CodecError![]const u8 {
    var payload: [8]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeVarInt(eid);
    try w.writeByte(animation);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.animation), w.written(), out);
}

/// Block Break Animation 0x25.
pub fn frameBlockBreakAnimation(eid: i32, x: i32, y: i32, z: i32, stage: i8, out: []u8) codec.CodecError![]const u8 {
    var payload: [32]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeVarInt(eid);
    try w.writeInt(x);
    try w.writeInt(y);
    try w.writeInt(z);
    try w.writeByte(@bitCast(stage));
    return try codec.framePacket(@intFromEnum(ids.PlayClient.block_break_animation), w.written(), out);
}

test "handshake parse" {
    var body: [64]u8 = undefined;
    var w = codec.PacketWriter.init(&body);
    try w.writeVarInt(5);
    try w.writeString("localhost");
    try w.writeUShort(25565);
    try w.writeVarInt(1);
    const h = try parseHandshake(w.written());
    try std.testing.expectEqual(@as(i32, 5), h.protocol);
    try std.testing.expectEqualStrings("localhost", h.address);
    try std.testing.expectEqual(@as(u16, 25565), h.port);
    try std.testing.expectEqual(@as(i32, 1), h.next);
}

test "status response frame + ping/pong" {
    var out: [512]u8 = undefined;
    const json = "{\"version\":{\"name\":\"1.7.10\",\"protocol\":5}}";
    const f = try frameStatusResponse(json, &out);
    var r = codec.PacketReader.init(f);
    const h = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 0x00), h.id);
    try std.testing.expectEqualStrings(json, try r.readString());
    // pong echoes ping payload
    var po: [16]u8 = undefined;
    const pf = try framePong(123456789, &po);
    var r2 = codec.PacketReader.init(pf);
    _ = try codec.decodeFrame(&r2);
    try std.testing.expectEqual(@as(i64, 123456789), try parsePing(r2.buffer[r2.index..]));
}

test "login start + login success frames" {
    var b: [64]u8 = undefined;
    var w = codec.PacketWriter.init(&b);
    try w.writeString("testplayer");
    try std.testing.expectEqualStrings("testplayer", try parseLoginStart(w.written()));
    var out: [128]u8 = undefined;
    const f = try frameLoginSuccess("52d22a52-7b4a-339e-8a09-aa52384d72fd", "testplayer", &out);
    var r = codec.PacketReader.init(f);
    const h = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 0x02), h.id);
    try std.testing.expectEqualStrings("52d22a52-7b4a-339e-8a09-aa52384d72fd", try r.readString());
    try std.testing.expectEqualStrings("testplayer", try r.readString());
}

test "encryption request/response framing" {
    var out: [512]u8 = undefined;
    const f = try frameEncryptionRequest("", &[_]u8{ 1, 2, 3 }, &[_]u8{4}, &out);
    var r = codec.PacketReader.init(f);
    const h = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 0x01), h.id);
    // request body: serverId string + short len + key + short len + token
    try std.testing.expectEqualStrings("", try r.readString());
    try std.testing.expectEqual(@as(i16, 3), try r.readShort());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, try r.readBytes(3));
    // response parse
    var rb: [16]u8 = undefined;
    var w = codec.PacketWriter.init(&rb);
    try w.writeShort(2);
    try w.writeBytes(&[_]u8{ 0xAA, 0xBB });
    try w.writeShort(1);
    try w.writeBytes(&[_]u8{0xCC});
    const er = try parseEncryptionResponse(w.written());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB }, er.secret_enc);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xCC}, er.token_enc);
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

test "click window parse + set slot / window items roundtrip" {
    // 0x0E: window i8, slot i16, button i8, action i16, mode i8, item slot
    var cb: [32]u8 = undefined;
    var cw = codec.PacketWriter.init(&cb);
    try cw.writeByte(0); // window 0
    try cw.writeShort(12); // slot
    try cw.writeByte(1); // right button
    try cw.writeShort(7); // action number
    try cw.writeByte(0); // pickup mode
    try cw.writeShort(-1); // empty clicked slot
    const c = try parseClickWindow(cw.written());
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

test "block change + animation frames parse back" {
    var out: [64]u8 = undefined;
    const f = try frameBlockChange(10, 64, -3, game_ids.dirt, 2, &out);
    var r = codec.PacketReader.init(f);
    try std.testing.expectEqual(@as(i32, 0x23), (try codec.decodeFrame(&r)).id);
    try std.testing.expectEqual(@as(i32, 10), try r.readInt());
    try std.testing.expectEqual(@as(u8, 64), try r.readByte());
    try std.testing.expectEqual(@as(i32, -3), try r.readInt());
    try std.testing.expectEqual(@as(i32, 3), try r.readVarInt());
    try std.testing.expectEqual(@as(u8, 2), try r.readByte());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
    var ao: [32]u8 = undefined;
    const af = try frameAnimation(7, 0, &ao);
    var ra = codec.PacketReader.init(af);
    try std.testing.expectEqual(@as(i32, 0x0B), (try codec.decodeFrame(&ra)).id);
    try std.testing.expectEqual(@as(i32, 7), try ra.readVarInt());
    try std.testing.expectEqual(@as(u8, 0), try ra.readByte());
}
test "play bootstrap roundtrips" {
    var out: [512]u8 = undefined;
    const jf = try frameJoinGame(.{ .eid = 7, .gamemode = 1, .dimension = 0, .difficulty = 1, .max_players = 20, .level_type = "default" }, &out);
    var r = codec.PacketReader.init(jf);
    const h = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 0x01), h.id);
    const j = try parseJoinGame(r.buffer[r.index..]);
    try std.testing.expectEqual(@as(i32, 7), j.eid);
    try std.testing.expectEqualStrings("default", j.level_type);
    var so: [32]u8 = undefined;
    const sf = try frameSpawnPosition(8, 64, 8, &so);
    var rs = codec.PacketReader.init(sf);
    const hs = try codec.decodeFrame(&rs);
    try std.testing.expectEqual(@as(i32, 0x05), hs.id);
    var ko: [16]u8 = undefined;
    const kf = try frameKeepAlive(42, &ko);
    var rk = codec.PacketReader.init(kf);
    _ = try codec.decodeFrame(&rk);
    try std.testing.expectEqual(@as(i32, 42), try parseKeepAlive(rk.buffer[rk.index..]));
}

test "tick + join packets roundtrip" {
    var buf: [256]u8 = undefined;
    // time update
    {
        const f = try frameTimeUpdate(24000, 6000, &buf);
        var r = codec.PacketReader.init(f);
        try std.testing.expectEqual(@as(i32, 0x03), (try codec.decodeFrame(&r)).id);
        try std.testing.expectEqual(@as(i64, 24000), try r.readLong());
        try std.testing.expectEqual(@as(i64, 6000), try r.readLong());
    }
    // abilities
    {
        const f = try framePlayerAbilities(0x0E, 0.05, 0.1, &buf);
        var r = codec.PacketReader.init(f);
        try std.testing.expectEqual(@as(i32, 0x39), (try codec.decodeFrame(&r)).id);
        try std.testing.expectEqual(@as(u8, 0x0E), try r.readByte());
    }
    // health
    {
        const f = try frameUpdateHealth(20.0, 20, 5.0, &buf);
        var r = codec.PacketReader.init(f);
        try std.testing.expectEqual(@as(i32, 0x06), (try codec.decodeFrame(&r)).id);
        try std.testing.expectApproxEqAbs(@as(f32, 20.0), try r.readFloat(), 1e-6);
        try std.testing.expectEqual(@as(i16, 20), try r.readShort());
    }
    // experience
    {
        const f = try frameSetExperience(0.5, 7, 100, &buf);
        var r = codec.PacketReader.init(f);
        try std.testing.expectEqual(@as(i32, 0x1F), (try codec.decodeFrame(&r)).id);
    }
    // player list add + remove
    {
        const f = try framePlayerListItem("Steve", true, 42, &buf);
        var r = codec.PacketReader.init(f);
        try std.testing.expectEqual(@as(i32, 0x38), (try codec.decodeFrame(&r)).id);
        try std.testing.expectEqualStrings("Steve", try r.readString());
        try std.testing.expect(try r.readBool());
        try std.testing.expectEqual(@as(i16, 42), try r.readShort());
    }
}

/// 1.7 fixed-point: absolute int = floor(double * 32).
pub fn toFixed(v: f64) i32 {
    return @as(i32, @intFromFloat(@floor(v * 32.0)));
}

/// Rotation packed byte: yaw degrees -> fraction of 360 (wraps negatives).
pub fn toPackedByte(degrees: f32) i8 {
    const steps = @floor(degrees * (256.0 / 360.0));
    return @as(i8, @truncate(@as(i32, @intFromFloat(steps))));
}

/// Minimal living-entity metadata (index 0 flags, 1 air, 6 health) + 0x7F end.
/// 1.7 clients crash when player spawn carries no metadata at all.
pub fn writeLivingBaseline(w: *codec.PacketWriter, health: f32) codec.CodecError!void {
    try w.writeByte((0 << 5) | 0); // type byte(0), index 0
    try w.writeByte(0); // flags
    try w.writeByte((1 << 5) | 1); // type short(1), index 1
    try w.writeShort(300); // air
    try w.writeByte((3 << 5) | 6); // type float(3), index 6 (3, not 2: 2 is int)
    const u: u32 = @bitCast(health);
    var fb: [4]u8 = undefined;
    std.mem.writeInt(u32, &fb, u, .big);
    try w.writeBytes(&fb);
    try w.writeByte(0x7F); // end
}

/// Spawn Player 0x0C. position_iii fixed-point ints, yaw/pitch packed bytes.
/// properties: empty (count 0) for offline players; session properties P-next.
pub fn frameSpawnPlayer(eid: i32, uuid_str: []const u8, name: []const u8, x: f64, y: f64, z: f64, yaw: f32, pitch: f32, health: f32, out: []u8) codec.CodecError![]const u8 {
    var payload: [256]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeVarInt(eid);
    try w.writeString(uuid_str);
    try w.writeString(name);
    try w.writeVarInt(0); // property count
    try w.writeInt(toFixed(x));
    try w.writeInt(toFixed(y));
    try w.writeInt(toFixed(z));
    try w.writeByte(@bitCast(toPackedByte(yaw)));
    try w.writeByte(@bitCast(toPackedByte(pitch)));
    try w.writeShort(0); // current item: none
    try writeLivingBaseline(&w, health);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.spawn_player), w.written(), out);
}

/// Spawn Mob 0x0F.
pub fn frameSpawnMob(eid: i32, mob_type: u8, x: f64, y: f64, z: f64, yaw: f32, pitch: f32, head_pitch: f32, health: f32, out: []u8) codec.CodecError![]const u8 {
    var payload: [128]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeVarInt(eid);
    try w.writeByte(mob_type);
    try w.writeInt(toFixed(x));
    try w.writeInt(toFixed(y));
    try w.writeInt(toFixed(z));
    try w.writeByte(@bitCast(toPackedByte(yaw)));
    try w.writeByte(@bitCast(toPackedByte(pitch)));
    try w.writeByte(@bitCast(toPackedByte(head_pitch)));
    try w.writeShort(0); // vel x
    try w.writeShort(0); // vel y
    try w.writeShort(0); // vel z
    try writeLivingBaseline(&w, health);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.spawn_mob), w.written(), out);
}

/// Destroy Entities 0x13, framed. Count is a single byte (max 255 per packet).
pub fn frameDestroyEntitiesFramed(eids: []const i32, out: []u8) codec.CodecError![]const u8 {
    if (eids.len > 255) return error.PacketTooLarge;
    var payload: [4 + 255 * 4]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeByte(@intCast(eids.len));
    for (eids) |id| try w.writeInt(id);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.destroy_entities), w.written(), out);
}

/// Entity Teleport 0x18 (fixed-point ints, packed bytes).
pub fn frameEntityTeleport(eid: i32, x: f64, y: f64, z: f64, yaw: f32, pitch: f32, out: []u8) codec.CodecError![]const u8 {
    var payload: [32]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(eid);
    try w.writeInt(toFixed(x));
    try w.writeInt(toFixed(y));
    try w.writeInt(toFixed(z));
    try w.writeByte(@bitCast(toPackedByte(yaw)));
    try w.writeByte(@bitCast(toPackedByte(pitch)));
    return try codec.framePacket(@intFromEnum(ids.PlayClient.entity_teleport), w.written(), out);
}

/// Entity Relative Move 0x15 (byte deltas, |d| <= 127 enforced by caller).
pub fn frameEntityRelativeMove(eid: i32, dx: i8, dy: i8, dz: i8, out: []u8) codec.CodecError![]const u8 {
    var payload: [8]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(eid);
    try w.writeByte(@bitCast(dx));
    try w.writeByte(@bitCast(dy));
    try w.writeByte(@bitCast(dz));
    return try codec.framePacket(@intFromEnum(ids.PlayClient.entity_relative_move), w.written(), out);
}

/// Entity Look 0x16.
pub fn frameEntityLook(eid: i32, yaw: f32, pitch: f32, out: []u8) codec.CodecError![]const u8 {
    var payload: [8]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(eid);
    try w.writeByte(@bitCast(toPackedByte(yaw)));
    try w.writeByte(@bitCast(toPackedByte(pitch)));
    return try codec.framePacket(@intFromEnum(ids.PlayClient.entity_look), w.written(), out);
}

/// Entity Look and Relative Move 0x17.
pub fn frameEntityMoveLook(eid: i32, dx: i8, dy: i8, dz: i8, yaw: f32, pitch: f32, out: []u8) codec.CodecError![]const u8 {
    var payload: [12]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(eid);
    try w.writeByte(@bitCast(dx));
    try w.writeByte(@bitCast(dy));
    try w.writeByte(@bitCast(dz));
    try w.writeByte(@bitCast(toPackedByte(yaw)));
    try w.writeByte(@bitCast(toPackedByte(pitch)));
    return try codec.framePacket(@intFromEnum(ids.PlayClient.entity_look_and_relative_move), w.written(), out);
}

/// Entity Head Look 0x19.
pub fn frameEntityHeadLook(eid: i32, yaw: f32, out: []u8) codec.CodecError![]const u8 {
    var payload: [8]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(eid);
    try w.writeByte(@bitCast(toPackedByte(yaw)));
    return try codec.framePacket(@intFromEnum(ids.PlayClient.entity_head_look), w.written(), out);
}

/// Spawn Object 0x0E. Vanilla EntityTrackerEntry (`my.c()`): items spawn as
/// type 2 with data 1 (CFR-verified against the official 1.7.10 server jar),
/// which makes the client read 3 velocity shorts (clamped x8000 server-side).
/// Pitch is written before yaw on the wire.
pub fn frameSpawnObject(eid: i32, obj_type: u8, x: f64, y: f64, z: f64, pitch: f32, yaw: f32, data: i32, vel: ?[3]i16, out: []u8) codec.CodecError![]const u8 {
    var payload: [64]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeVarInt(eid);
    try w.writeByte(obj_type);
    try w.writeInt(toFixed(x));
    try w.writeInt(toFixed(y));
    try w.writeInt(toFixed(z));
    try w.writeByte(@bitCast(toPackedByte(pitch)));
    try w.writeByte(@bitCast(toPackedByte(yaw)));
    try w.writeInt(data);
    if (data > 0) {
        const v = vel orelse [3]i16{ 0, 0, 0 };
        try w.writeShort(v[0]);
        try w.writeShort(v[1]);
        try w.writeShort(v[2]);
    }
    return try codec.framePacket(@intFromEnum(ids.PlayClient.spawn_object), w.written(), out);
}

/// Collect Item 0x0D: collected eid first, collector eid second (both i32 —
/// NOT varints; verified against minecraft-data 1.7 + `ij` decompile).
pub fn frameCollect(collected_eid: i32, collector_eid: i32, out: []u8) codec.CodecError![]const u8 {
    var payload: [8]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(collected_eid);
    try w.writeInt(collector_eid);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.collect_item), w.written(), out);
}

/// Item-stack Entity Metadata 0x1C: full watcher `[(0: byte 0), (1: short
/// 300), (10: slot)]` + 0x7F end. Vanilla EntityTrackerEntry (`my.b`)
/// sends the spawn packet then the FULL DataWatcher list (`new hw(eid,
/// watcher, true)`); the base Entity inits 0/1 and EntityItem adds slot 10.
/// The spawn packet itself carries no metadata.
pub fn frameItemMetadata(eid: i32, stack: item_mod.Stack, out: []u8) codec.CodecError![]const u8 {
    var payload: [512]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(eid);
    try w.writeByte((0 << 5) | 0); // type byte(0), index 0: flags
    try w.writeByte(0);
    try w.writeByte((1 << 5) | 1); // type short(1), index 1: air
    try w.writeShort(300);
    try w.writeByte((5 << 5) | 10); // type slot(5), index 10: the stack
    try slot_mod.writeSlot(&w, stack);
    try w.writeByte(0x7F); // end
    return try codec.framePacket(@intFromEnum(ids.PlayClient.entity_metadata), w.written(), out);
}
/// Entity Metadata 0x1C with a living-entity baseline body.
pub fn frameEntityMetadata(eid: i32, health: f32, out: []u8) codec.CodecError![]const u8 {
    var payload: [32]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(eid);
    try writeLivingBaseline(&w, health);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.entity_metadata), w.written(), out);
}

test "entity packets roundtrip" {
    var buf: [512]u8 = undefined;
    // fixed-point + packed yaw edge cases
    try std.testing.expectEqual(@as(i32, 0), toFixed(0.0));
    try std.testing.expectEqual(@as(i32, 272), toFixed(8.5));
    try std.testing.expectEqual(@as(i32, -1280), toFixed(-40.0));
    try std.testing.expectEqual(@as(i8, 0), toPackedByte(0));
    try std.testing.expectEqual(@as(i8, 64), toPackedByte(90));
    try std.testing.expectEqual(@as(i8, -64), toPackedByte(270)); // wraps
    // spawn player
    {
        const f = try frameSpawnPlayer(7, "52d22a52-7b4a-339e-8a09-aa52384d72fd", "Steve", 8.5, 64.0, 8.5, 90.0, 0.0, 20.0, &buf);
        var r = codec.PacketReader.init(f);
        try std.testing.expectEqual(@as(i32, 0x0C), (try codec.decodeFrame(&r)).id);
        try std.testing.expectEqual(@as(i32, 7), try r.readVarInt());
        try std.testing.expectEqualStrings("52d22a52-7b4a-339e-8a09-aa52384d72fd", try r.readString());
        try std.testing.expectEqualStrings("Steve", try r.readString());
        try std.testing.expectEqual(@as(i32, 0), try r.readVarInt()); // no properties
        try std.testing.expectEqual(@as(i32, 272), try r.readInt());
        try std.testing.expectEqual(@as(i32, 2048), try r.readInt());
        // metadata present (terminator 0x7F at end) so notch client won't crash
        try std.testing.expect(r.buffer[r.index..].len > 1);
        try std.testing.expectEqual(@as(u8, 0x7F), r.buffer[r.index..][r.buffer[r.index..].len - 1]);
    }
    // living baseline pins vanilla DataWatcher types: (0:byte)(1:short 300)
    // (6:float) + 0x7F. Tagging health as int(2) crashes 1.7.10 with
    // ClassCastException Integer->Float on the first living-entity tick.
    {
        var wb: [32]u8 = undefined;
        var w = codec.PacketWriter.init(&wb);
        try writeLivingBaseline(&w, 20.0);
        const got = w.written();
        try std.testing.expectEqual(@as(usize, 11), got.len);
        try std.testing.expectEqual(@as(u8, 0x00), got[0]); // (0<<5)|0
        try std.testing.expectEqual(@as(u8, 0x00), got[1]); // flags
        try std.testing.expectEqual(@as(u8, 0x21), got[2]); // (1<<5)|1
        try std.testing.expectEqual(@as(i16, 300), std.mem.readInt(i16, got[3..5], .big));
        try std.testing.expectEqual(@as(u8, 0x66), got[5]); // (3<<5)|6 float
        try std.testing.expectEqual(@as(f32, 20.0), @as(f32, @bitCast(std.mem.readInt(u32, got[6..10], .big))));
        try std.testing.expectEqual(@as(u8, 0x7F), got[10]);
    }
    // spawn mob (pig 90)
    {
        const f = try frameSpawnMob(8, 90, 10.5, 64.0, -3.25, 180.0, 0.0, 180.0, 10.0, &buf);
        var r = codec.PacketReader.init(f);
        try std.testing.expectEqual(@as(i32, 0x0F), (try codec.decodeFrame(&r)).id);
        try std.testing.expectEqual(@as(i32, 8), try r.readVarInt());
        try std.testing.expectEqual(@as(u8, 90), try r.readByte());
    }
    // destroy (byte count)
    {
        const f = try frameDestroyEntitiesFramed(&[_]i32{ 7, 8 }, &buf);
        var r = codec.PacketReader.init(f);
        try std.testing.expectEqual(@as(i32, 0x13), (try codec.decodeFrame(&r)).id);
        try std.testing.expectEqual(@as(u8, 2), try r.readByte());
        try std.testing.expectEqual(@as(i32, 7), try r.readInt());
        try std.testing.expectEqual(@as(i32, 8), try r.readInt());
    }
    // teleport / relmove / look / movelook / headlook / metadata ids
    {
        var b2: [64]u8 = undefined;
        const t = try frameEntityTeleport(9, 1.5, 65.0, 2.5, 45.0, -10.0, &b2);
        var r = codec.PacketReader.init(t);
        try std.testing.expectEqual(@as(i32, 0x18), (try codec.decodeFrame(&r)).id);
        try std.testing.expectEqual(@as(i32, 9), try r.readInt());
        try std.testing.expectEqual(@as(i32, 48), try r.readInt());
        const m = try frameEntityRelativeMove(9, 1, -2, 3, &b2);
        var r2 = codec.PacketReader.init(m);
        try std.testing.expectEqual(@as(i32, 0x15), (try codec.decodeFrame(&r2)).id);
        const l = try frameEntityLook(9, 90.0, 0.0, &b2);
        var r3 = codec.PacketReader.init(l);
        try std.testing.expectEqual(@as(i32, 0x16), (try codec.decodeFrame(&r3)).id);
        const ml = try frameEntityMoveLook(9, 1, 0, 0, 90.0, 0.0, &b2);
        var r4 = codec.PacketReader.init(ml);
        try std.testing.expectEqual(@as(i32, 0x17), (try codec.decodeFrame(&r4)).id);
        const hl = try frameEntityHeadLook(9, 180.0, &b2);
        var r5 = codec.PacketReader.init(hl);
        try std.testing.expectEqual(@as(i32, 0x19), (try codec.decodeFrame(&r5)).id);
        const md = try frameEntityMetadata(9, 20.0, &b2);
        var r6 = codec.PacketReader.init(md);
        try std.testing.expectEqual(@as(i32, 0x1C), (try codec.decodeFrame(&r6)).id);
    }
}

test "item entity packets roundtrip (spawn/collect/slot-10)" {
    var buf: [1024]u8 = undefined;
    // spawn object type 2 (item), data 1 -> 3 velocity shorts present
    {
        const f = try frameSpawnObject(51, 2, 8.5, 64.0, -3.25, 0.0, 90.0, 1, .{ 10, -20, 30 }, &buf);
        var r = codec.PacketReader.init(f);
        try std.testing.expectEqual(@as(i32, 0x0E), (try codec.decodeFrame(&r)).id);
        try std.testing.expectEqual(@as(i32, 51), try r.readVarInt());
        try std.testing.expectEqual(@as(u8, 2), try r.readByte());
        try std.testing.expectEqual(@as(i32, 272), try r.readInt()); // 8.5*32
        try std.testing.expectEqual(@as(i32, 2048), try r.readInt()); // 64*32
        try std.testing.expectEqual(@as(i32, -104), try r.readInt()); // floor(-3.25*32)
        try std.testing.expectEqual(@as(u8, 0), try r.readByte()); // pitch first
        try std.testing.expectEqual(@as(u8, 64), try r.readByte()); // yaw 90 -> 64
        try std.testing.expectEqual(@as(i32, 1), try r.readInt()); // data
        try std.testing.expectEqual(@as(i16, 10), try r.readShort());
        try std.testing.expectEqual(@as(i16, -20), try r.readShort());
        try std.testing.expectEqual(@as(i16, 30), try r.readShort());
        try std.testing.expectEqual(@as(usize, 0), r.remaining());
    }
    // data 0 -> no velocity tail (minecart-style); explicit null vel is zeroed
    {
        const f = try frameSpawnObject(52, 2, 0.0, 64.0, 0.0, 0.0, 0.0, 1, null, &buf);
        var r = codec.PacketReader.init(f);
        try std.testing.expectEqual(@as(i32, 0x0E), (try codec.decodeFrame(&r)).id);
        _ = try r.readVarInt();
        _ = try r.readByte();
        _ = try r.readInt();
        _ = try r.readInt();
        _ = try r.readInt();
        _ = try r.readByte();
        _ = try r.readByte();
        try std.testing.expectEqual(@as(i32, 1), try r.readInt());
        try std.testing.expectEqual(@as(i16, 0), try r.readShort());
        try std.testing.expectEqual(@as(i16, 0), try r.readShort());
        try std.testing.expectEqual(@as(i16, 0), try r.readShort());
        try std.testing.expectEqual(@as(usize, 0), r.remaining());
    }
    // collect: two i32s, collected first
    {
        const f = try frameCollect(51, 7, &buf);
        var r = codec.PacketReader.init(f);
        try std.testing.expectEqual(@as(i32, 0x0D), (try codec.decodeFrame(&r)).id);
        try std.testing.expectEqual(@as(i32, 51), try r.readInt());
        try std.testing.expectEqual(@as(i32, 7), try r.readInt());
        try std.testing.expectEqual(@as(usize, 0), r.remaining());
    }
    // item metadata: eid + flags/air baseline + 0xAA head + slot + 0x7F end
    {
        const stack = item_mod.Stack{ .id = game_ids.diamond, .count = 1, .damage = 0, .nbt = null };
        const f = try frameItemMetadata(51, stack, &buf);
        var r = codec.PacketReader.init(f);
        try std.testing.expectEqual(@as(i32, 0x1C), (try codec.decodeFrame(&r)).id);
        try std.testing.expectEqual(@as(i32, 51), try r.readInt());
        try std.testing.expectEqual(@as(u8, 0x00), try r.readByte());
        try std.testing.expectEqual(@as(u8, 0x00), try r.readByte());
        try std.testing.expectEqual(@as(u8, 0x21), try r.readByte());
        try std.testing.expectEqual(@as(i16, 300), try r.readShort());
        try std.testing.expectEqual(@as(u8, 0xAA), try r.readByte());
        const back = try slot_mod.readSlot(&r);
        try std.testing.expect(back != null);
        try std.testing.expect(item_mod.stacksEqual(back, stack));
        try std.testing.expectEqual(@as(u8, 0x7F), try r.readByte());
        try std.testing.expectEqual(@as(usize, 0), r.remaining());
    }
}

test "chat format + frame roundtrip" {
    var out: [512]u8 = undefined;
    const j = try formatChatJson("Steve", "hi \"there\" \\ ok", &out);
    try std.testing.expectEqualStrings("{\"text\":\"<Steve> hi \\\"there\\\" \\\\ ok\"}", j);
    // control chars escaped, multibyte preserved
    const j2 = try formatChatJson("Al", "a\nb\x01é", &out);
    try std.testing.expectEqualStrings("{\"text\":\"<Al> a\\nb\\u0001é\"}", j2);
    // rejects: bad name, empty, too long, invalid utf-8
    try std.testing.expectError(error.BadName, formatChatJson("a b", "hi", &out));
    try std.testing.expectError(error.BadName, formatChatJson("", "hi", &out));
    var long: [101]u8 = [_]u8{'x'} ** 101;
    try std.testing.expectError(error.BadMessage, formatChatJson("Al", &long, &out));
    try std.testing.expectError(error.BadMessage, formatChatJson("Al", "\xff\xfe", &out));
    try std.testing.expectError(error.OutOfMemory, formatChatJson("Steve", "hi", out[0..10]));
    // 0x02 frame carries the JSON verbatim (1.7 has no position byte)
    var fb: [512]u8 = undefined;
    const f = try frameChat(j, &fb);
    var r = codec.PacketReader.init(f);
    try std.testing.expectEqual(@as(i32, 0x02), (try codec.decodeFrame(&r)).id);
    try std.testing.expectEqualStrings(j, try r.readString());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
    // serverbound parse is a plain string
    var sb: [32]u8 = undefined;
    var w = codec.PacketWriter.init(&sb);
    try w.writeString("hello there");
    try std.testing.expectEqualStrings("hello there", try parseChat(w.written()));
}

// ---------- tab completion (serverbound 0x14, clientbound 0x3A) ----------

/// Serverbound 0x14 text (vanilla cap 32767 chars — same as chat).
pub fn parseTabComplete(body: []const u8) codec.CodecError![]const u8 {
    var r = codec.PacketReader.init(body);
    return try r.readString();
}

/// Clientbound 0x3A: VarInt count + candidate strings.
pub fn frameTabComplete(cands: []const []const u8, out: []u8) codec.CodecError![]const u8 {
    var payload: [4096]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeVarInt(@intCast(cands.len));
    for (cands) |c| try w.writeString(c);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.tab_complete), w.written(), out);
}

// ---------- game state / effects / scoreboard ----------

/// Clientbound 0x2B ChangeGameState: reason byte + float value.
pub const game_state_begin_rain: u8 = 1;
pub const game_state_end_rain: u8 = 2;
pub const game_state_change_gamemode: u8 = 3;
pub const game_state_rain_strength: u8 = 7;
pub const game_state_thunder_strength: u8 = 8;

pub fn frameGameState(reason: u8, value: f32, out: []u8) codec.CodecError![]const u8 {
    var payload: [8]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeByte(reason);
    try w.writeFloat(value);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.change_game_state), w.written(), out);
}

/// Clientbound 0x29 NamedSoundEffect: coords are absolute blocks * 8,
/// volume float, pitch byte (vanilla scale: pitch * 63).
pub fn frameSoundEffect(name: []const u8, x: f64, y: f64, z: f64, volume: f32, pitch: f32, out: []u8) codec.CodecError![]const u8 {
    var payload: [512]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeString(name);
    try w.writeInt(@as(i32, @intFromFloat(@floor(x * 8.0))));
    try w.writeInt(@as(i32, @intFromFloat(@floor(y * 8.0))));
    try w.writeInt(@as(i32, @intFromFloat(@floor(z * 8.0))));
    try w.writeFloat(volume);
    const pb: i32 = @as(i32, @intFromFloat(pitch * 63.0));
    try w.writeByte(@intCast(@max(0, @min(255, pb))));
    return try codec.framePacket(@intFromEnum(ids.PlayClient.sound_effect), w.written(), out);
}

/// Clientbound 0x1D EntityEffect: duration in ticks (vanilla truncates to
/// i16 — huge /effect durations wrap exactly like the 1.7.10 client shows).
pub fn frameEntityEffect(eid: i32, effect_id: u8, amplifier: u8, duration_ticks: i32, out: []u8) codec.CodecError![]const u8 {
    var payload: [16]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeVarInt(eid);
    try w.writeByte(effect_id);
    try w.writeByte(amplifier);
    try w.writeShort(@truncate(duration_ticks));
    return try codec.framePacket(@intFromEnum(ids.PlayClient.entity_effect), w.written(), out);
}

/// Clientbound 0x1E RemoveEntityEffect.
pub fn frameRemoveEntityEffect(eid: i32, effect_id: u8, out: []u8) codec.CodecError![]const u8 {
    var payload: [8]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeVarInt(eid);
    try w.writeByte(effect_id);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.remove_entity_effect), w.written(), out);
}

/// Clientbound 0x3B ScoreboardObjective: action 0 = create, 1 = remove,
/// 2 = update display text.
pub fn frameObjective(name: []const u8, display: []const u8, action: u8, out: []u8) codec.CodecError![]const u8 {
    var payload: [512]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeString(name);
    try w.writeString(display);
    try w.writeByte(action);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.scoreboard_objective), w.written(), out);
}

/// Clientbound 0x3C UpdateScore: action 0 = create/update (objective +
/// value follow), 1 = remove (name only).
pub fn frameUpdateScore(player: []const u8, action: u8, objective: []const u8, value: i32, out: []u8) codec.CodecError![]const u8 {
    var payload: [512]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeString(player);
    try w.writeByte(action);
    if (action == 0) {
        try w.writeString(objective);
        try w.writeInt(value);
    }
    return try codec.framePacket(@intFromEnum(ids.PlayClient.update_score), w.written(), out);
}

/// Clientbound 0x3D DisplayScoreboard: position 0 = list, 1 = sidebar,
/// 2 = below name.
pub fn frameDisplayScoreboard(position: u8, objective: []const u8, out: []u8) codec.CodecError![]const u8 {
    var payload: [256]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeByte(position);
    try w.writeString(objective);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.display_scoreboard), w.written(), out);
}

/// Clientbound 0x3E Teams, create/update/remove-team/player modes.
/// Modes: 0 = create, 1 = remove, 2 = update info, 3 = add players,
/// 4 = remove players. Info triple only for modes 0/2, player list only
/// for modes 0/3/4.
pub const TeamInfo = struct {
    display: []const u8,
    prefix: []const u8,
    suffix: []const u8,
    friendly_fire: u8,
};

pub fn frameTeams(name: []const u8, mode: u8, info: ?TeamInfo, players: []const []const u8, out: []u8) codec.CodecError![]const u8 {
    var payload: [4096]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeString(name);
    try w.writeByte(mode);
    if (mode == 0 or mode == 2) {
        const t = info orelse return error.InvalidLength;
        try w.writeString(t.display);
        try w.writeString(t.prefix);
        try w.writeString(t.suffix);
        try w.writeByte(t.friendly_fire);
    }
    if (mode == 0 or mode == 3 or mode == 4) {
        try w.writeShort(@intCast(players.len));
        for (players) |p| try w.writeString(p);
    }
    return try codec.framePacket(@intFromEnum(ids.PlayClient.teams), w.written(), out);
}

/// Clientbound 0x2C SpawnGlobalEntity (lightning = type 1): fixed-point
/// absolute coords (* 32, floored like vanilla).
pub fn frameSpawnGlobalEntity(eid: i32, kind: u8, x: f64, y: f64, z: f64, out: []u8) codec.CodecError![]const u8 {
    var payload: [24]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeVarInt(eid);
    try w.writeByte(kind);
    try w.writeInt(@as(i32, @intFromFloat(@floor(x * 32.0))));
    try w.writeInt(@as(i32, @intFromFloat(@floor(y * 32.0))));
    try w.writeInt(@as(i32, @intFromFloat(@floor(z * 32.0))));
    return try codec.framePacket(@intFromEnum(ids.PlayClient.spawn_global_entity), w.written(), out);
}

/// Clientbound 0x28 Effect (world event: 2001 = block break particles).
/// Coords are absolute blocks * 8 (vanilla S28 layout).
pub fn frameWorldEffect(event_id: i32, x: i32, y: u8, z: i32, data: i32, out: []u8) codec.CodecError![]const u8 {
    var payload: [24]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeInt(event_id);
    try w.writeInt(x * 8);
    try w.writeInt(@as(i32, y) * 8);
    try w.writeInt(z * 8);
    try w.writeInt(data);
    try w.writeByte(0); // volume decrease flag: 0 = full range
    return try codec.framePacket(@intFromEnum(ids.PlayClient.effect), w.written(), out);
}

test "tab-complete frame roundtrip" {
    var fb: [256]u8 = undefined;
    const cands = [_][]const u8{ "give", "gamemode" };
    const f = try frameTabComplete(&cands, &fb);
    var r = codec.PacketReader.init(f);
    try std.testing.expectEqual(@as(i32, 0x3A), (try codec.decodeFrame(&r)).id);
    try std.testing.expectEqual(@as(i32, 2), try r.readVarInt());
    try std.testing.expectEqualStrings("give", try r.readString());
    try std.testing.expectEqualStrings("gamemode", try r.readString());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
    // serverbound parse is a plain string
    var sb: [32]u8 = undefined;
    var w = codec.PacketWriter.init(&sb);
    try w.writeString("/wea");
    try std.testing.expectEqualStrings("/wea", try parseTabComplete(w.written()));
}

test "game state / sound / effect frames" {
    var b: [512]u8 = undefined;
    var r = codec.PacketReader.init(try frameGameState(game_state_begin_rain, 0, &b));
    try std.testing.expectEqual(@as(i32, 0x2B), (try codec.decodeFrame(&r)).id);
    try std.testing.expectEqual(@as(u8, 1), try r.readByte());
    var s = codec.PacketReader.init(try frameSoundEffect("mob.pig.say", 1, 64, -3, 1.0, 1.0, &b));
    try std.testing.expectEqual(@as(i32, 0x29), (try codec.decodeFrame(&s)).id);
    try std.testing.expectEqualStrings("mob.pig.say", try s.readString());
    try std.testing.expectEqual(@as(i32, 8), try s.readInt());
    try std.testing.expectEqual(@as(i32, 512), try s.readInt());
    try std.testing.expectEqual(@as(i32, -24), try s.readInt());
    try std.testing.expectEqual(@as(u8, 63), try s.readByte());
    var e = codec.PacketReader.init(try frameEntityEffect(7, 1, 0, 600, &b));
    try std.testing.expectEqual(@as(i32, 0x1D), (try codec.decodeFrame(&e)).id);
    try std.testing.expectEqual(@as(i32, 7), try e.readVarInt());
    try std.testing.expectEqual(@as(u8, 1), try e.readByte());
    try std.testing.expectEqual(@as(u8, 0), try e.readByte());
    try std.testing.expectEqual(@as(i16, 600), try e.readShort());
}

test "scoreboard frames" {
    var b: [1024]u8 = undefined;
    var r = codec.PacketReader.init(try frameObjective("obj", "Obj", 0, &b));
    try std.testing.expectEqual(@as(i32, 0x3B), (try codec.decodeFrame(&r)).id);
    var u = codec.PacketReader.init(try frameUpdateScore("Al", 0, "obj", 5, &b));
    try std.testing.expectEqual(@as(i32, 0x3C), (try codec.decodeFrame(&u)).id);
    try std.testing.expectEqualStrings("Al", try u.readString());
    try std.testing.expectEqual(@as(u8, 0), try u.readByte());
    try std.testing.expectEqualStrings("obj", try u.readString());
    var d = codec.PacketReader.init(try frameDisplayScoreboard(1, "obj", &b));
    try std.testing.expectEqual(@as(i32, 0x3D), (try codec.decodeFrame(&d)).id);
    try std.testing.expectEqual(@as(u8, 1), try d.readByte());
    var t = codec.PacketReader.init(try frameTeams("red", 0, .{ .display = "Red", .prefix = "[R]", .suffix = "", .friendly_fire = 0 }, &.{ "Al", "Bo" }, &b));
    try std.testing.expectEqual(@as(i32, 0x3E), (try codec.decodeFrame(&t)).id);
    try std.testing.expectEqualStrings("red", try t.readString());
    try std.testing.expectEqual(@as(u8, 0), try t.readByte());
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
