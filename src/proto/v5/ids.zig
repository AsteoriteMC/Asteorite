//! Packet ID tables for Minecraft 1.7.10 / protocol version 5.
//!
//! Sources: wiki.vg Protocol History revision for proto 5
//! (minecraft.wiki oldid=2771654), PrismarineJS node-minecraft-protocol 1.7 branch.
//!
//! Status: handshake/login/status IDs are stable and covered by tests.
//! Play IDs below are the widely-used 1.7.10 values; the full play table
//! MUST be validated against a live 1.7.10 capture before implementing
//! play-state handlers (P1). Unknown IDs must be skipped, never crash.

/// Connection state machine.
pub const State = enum {
    handshaking,
    status,
    login,
    play,
};

/// Next-state field of Handshake (serverbound 0x00 while in handshaking).
pub const HandshakeNext = enum(i32) {
    status = 1,
    login = 2,
};

/// Handshaking state, serverbound.
pub const HandshakingServer = enum(i32) {
    handshake = 0x00,
    legacy_server_list_ping = 0xFE, // special-cased, non-VarInt framing
};

/// Status state.
pub const StatusServer = enum(i32) {
    request = 0x00,
    ping = 0x01,
};

pub const StatusClient = enum(i32) {
    response = 0x00,
    pong = 0x01,
};

/// Login state.
pub const LoginServer = enum(i32) {
    login_start = 0x00,
    encryption_response = 0x01,
};

pub const LoginClient = enum(i32) {
    disconnect = 0x00,
    encryption_request = 0x01,
    login_success = 0x02,
};

pub const protocol_version_1_7_10: i32 = 5;

/// Play-state clientbound IDs (server -> client) for 1.7.10.
/// Partial table: covers P0/P1 bootstrap path. Verify remainder vs capture.
pub const PlayClient = enum(i32) {
    keep_alive = 0x00,
    join_game = 0x01,
    chat_message = 0x02,
    time_update = 0x03,
    entity_equipment = 0x04,
    spawn_position = 0x05,
    update_health = 0x06,
    respawn = 0x07,
    player_position_and_look = 0x08,
    held_item_change = 0x09,
    use_bed = 0x0A,
    animation = 0x0B,
    spawn_player = 0x0C,
    collect_item = 0x0D,
    spawn_object = 0x0E,
    spawn_mob = 0x0F,
    spawn_painting = 0x10,
    spawn_experience_orb = 0x11,
    entity_velocity = 0x12,
    destroy_entities = 0x13,
    entity = 0x14,
    entity_relative_move = 0x15,
    entity_look = 0x16,
    entity_look_and_relative_move = 0x17,
    entity_teleport = 0x18,
    entity_head_look = 0x19,
    entity_status = 0x1A,
    attach_entity = 0x1B,
    entity_metadata = 0x1C,
    entity_effect = 0x1D,
    remove_entity_effect = 0x1E,
    set_experience = 0x1F,
    entity_properties = 0x20,
    chunk_data = 0x21,
    multi_block_change = 0x22,
    block_change = 0x23,
    block_action = 0x24,
    block_break_animation = 0x25,
    map_chunk_bulk = 0x26,
    explosion = 0x27,
    effect = 0x28,
    sound_effect = 0x29,
    particle = 0x2A,
    change_game_state = 0x2B,
    spawn_global_entity = 0x2C,
    open_window = 0x2D,
    close_window = 0x2E,
    set_slot = 0x2F,
    window_items = 0x30,
    window_property = 0x31,
    confirm_transaction = 0x32,
    update_sign = 0x33,
    maps = 0x34,
    update_block_entity = 0x35,
    sign_editor_open = 0x36,
    statistics = 0x37,
    player_list_item = 0x38,
    player_abilities = 0x39,
    tab_complete = 0x3A,
    scoreboard_objective = 0x3B,
    update_score = 0x3C,
    display_scoreboard = 0x3D,
    teams = 0x3E,
    plugin_message = 0x3F,
    disconnect = 0x40,
};

/// Play-state serverbound IDs (client -> server) for 1.7.10 (partial).
pub const PlayServer = enum(i32) {
    keep_alive = 0x00,
    chat_message = 0x01,
    use_entity = 0x02,
    player = 0x03,
    player_position = 0x04,
    player_look = 0x05,
    player_position_and_look = 0x06,
    player_digging = 0x07,
    player_block_placement = 0x08,
    held_item_change = 0x09,
    animation = 0x0A,
    entity_action = 0x0B,
    steer_vehicle = 0x0C,
    close_window = 0x0D,
    click_window = 0x0E,
    confirm_transaction = 0x0F,
    creative_inventory_action = 0x10,
    enchant_item = 0x11,
    update_sign = 0x12,
    player_abilities = 0x13,
    tab_complete = 0x14,
    client_settings = 0x15,
    client_status = 0x16,
    plugin_message = 0x17,
};

const std = @import("std");

test "stable ids: handshake/status/login" {
    try std.testing.expectEqual(@as(i32, 0x00), @intFromEnum(HandshakingServer.handshake));
    try std.testing.expectEqual(@as(i32, 0x00), @intFromEnum(StatusServer.request));
    try std.testing.expectEqual(@as(i32, 0x01), @intFromEnum(StatusServer.ping));
    try std.testing.expectEqual(@as(i32, 0x00), @intFromEnum(StatusClient.response));
    try std.testing.expectEqual(@as(i32, 0x01), @intFromEnum(StatusClient.pong));
    try std.testing.expectEqual(@as(i32, 0x00), @intFromEnum(LoginServer.login_start));
    try std.testing.expectEqual(@as(i32, 0x01), @intFromEnum(LoginServer.encryption_response));
    try std.testing.expectEqual(@as(i32, 0x01), @intFromEnum(LoginClient.encryption_request));
    try std.testing.expectEqual(@as(i32, 0x02), @intFromEnum(LoginClient.login_success));
    try std.testing.expectEqual(@as(i32, 5), protocol_version_1_7_10);
}

test "play bootstrap ids distinct" {
    try std.testing.expectEqual(@as(i32, 0x00), @intFromEnum(PlayClient.keep_alive));
    try std.testing.expectEqual(@as(i32, 0x01), @intFromEnum(PlayClient.join_game));
    try std.testing.expectEqual(@as(i32, 0x26), @intFromEnum(PlayClient.map_chunk_bulk));
}
