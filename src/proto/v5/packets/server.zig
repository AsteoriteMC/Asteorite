//! 1.7.10 server -> client control packets (join, spawn, time, abilities, game state, scoreboard).

const std = @import("std");
const codec = @import("../../../net/codec.zig");
const ids = @import("../ids.zig");


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

/// Play disconnect 0x40: pre-formatted JSON kick screen (client shows it
/// and drops to the multiplayer list). Same body shape as the login
/// disconnect — only the packet id differs per state.
pub fn frameDisconnect(json: []const u8, out: []u8) codec.CodecError![]const u8 {
    var payload: [4096]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeString(json);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.disconnect), w.written(), out);
}


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

test "play bootstrap roundtrips" {
    const player = @import("player.zig");
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
    try std.testing.expectEqual(@as(i32, 42), try player.parseKeepAlive(rk.buffer[rk.index..]));
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


test "tab-complete frame roundtrip" {
    const player = @import("player.zig");
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
    try std.testing.expectEqualStrings("/wea", try player.parseTabComplete(w.written()));
}


test "game state / sound / effect frames" {
    const world = @import("world.zig");
    const entity = @import("entity.zig");
    var b: [512]u8 = undefined;
    var r = codec.PacketReader.init(try frameGameState(game_state_begin_rain, 0, &b));
    try std.testing.expectEqual(@as(i32, 0x2B), (try codec.decodeFrame(&r)).id);
    try std.testing.expectEqual(@as(u8, 1), try r.readByte());
    var s = codec.PacketReader.init(try world.frameSoundEffect("mob.pig.say", 1, 64, -3, 1.0, 1.0, &b));
    try std.testing.expectEqual(@as(i32, 0x29), (try codec.decodeFrame(&s)).id);
    try std.testing.expectEqualStrings("mob.pig.say", try s.readString());
    try std.testing.expectEqual(@as(i32, 8), try s.readInt());
    try std.testing.expectEqual(@as(i32, 512), try s.readInt());
    try std.testing.expectEqual(@as(i32, -24), try s.readInt());
    try std.testing.expectEqual(@as(u8, 63), try s.readByte());
    var e = codec.PacketReader.init(try entity.frameEntityEffect(7, 1, 0, 600, &b));
    try std.testing.expectEqual(@as(i32, 0x1D), (try codec.decodeFrame(&e)).id);
    try std.testing.expectEqual(@as(i32, 7), try e.readInt());
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
