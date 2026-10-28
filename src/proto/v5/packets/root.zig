//! 1.7.10 packet registry: re-exports the per-category packet modules.
//!
//! Categories follow packet purpose, not numeric order:
//! - `handshake` — connection setup (handshake / status / login)
//! - `server` — server -> client control (join, spawn, time, abilities,
//!   game state, scoreboard, tab-complete responses)
//! - `player` — client -> server player input (movement, digging,
//!   placement, entity actions, window clicks)
//! - `inventory` — window open/close/progress/slot sync
//! - `world` — block changes, break animation, effects, sound
//! - `entity` — spawn, move, look, teleport, metadata, effects
//! - `chat` — chat text in both directions + JSON escaping
//!
//! Core code should keep importing `packets` (or `version.proto`); reach
//! into a category only when the narrower API is what you mean.

pub const handshake = @import("handshake.zig");
pub const server = @import("server.zig");
pub const player = @import("player.zig");
pub const inventory = @import("inventory.zig");
pub const world = @import("world.zig");
pub const entity = @import("entity.zig");
pub const chat = @import("chat.zig");

// Flat re-exports: `packets.frameChat` keeps working after the split.
pub const Handshake = handshake.Handshake;
pub const parseHandshake = handshake.parseHandshake;
pub const frameStatusResponse = handshake.frameStatusResponse;
pub const parsePing = handshake.parsePing;
pub const framePong = handshake.framePong;
pub const parseLoginStart = handshake.parseLoginStart;
pub const EncryptionRequest = handshake.EncryptionRequest;
pub const frameEncryptionRequest = handshake.frameEncryptionRequest;
pub const EncryptionResponse = handshake.EncryptionResponse;
pub const parseEncryptionResponse = handshake.parseEncryptionResponse;
pub const frameLoginSuccess = handshake.frameLoginSuccess;
pub const frameLoginDisconnect = handshake.frameLoginDisconnect;

pub const JoinGame = server.JoinGame;
pub const frameJoinGame = server.frameJoinGame;
pub const parseJoinGame = server.parseJoinGame;
pub const frameSpawnPosition = server.frameSpawnPosition;
pub const frameRespawn = server.frameRespawn;
pub const frameTimeUpdate = server.frameTimeUpdate;
pub const abilityFlags = server.abilityFlags;
pub const framePlayerAbilities = server.framePlayerAbilities;
pub const frameUpdateHealth = server.frameUpdateHealth;
pub const frameSetExperience = server.frameSetExperience;
pub const framePlayerListItem = server.framePlayerListItem;
pub const PlayerPosLook = server.PlayerPosLook;
pub const framePlayerPosLook = server.framePlayerPosLook;
pub const frameDisconnect = server.frameDisconnect;
pub const frameKeepAlive = server.frameKeepAlive;
pub const frameTabComplete = server.frameTabComplete;
pub const game_state_begin_rain = server.game_state_begin_rain;
pub const game_state_end_rain = server.game_state_end_rain;
pub const game_state_change_gamemode = server.game_state_change_gamemode;
pub const game_state_rain_strength = server.game_state_rain_strength;
pub const game_state_thunder_strength = server.game_state_thunder_strength;
pub const frameGameState = server.frameGameState;
pub const frameObjective = server.frameObjective;
pub const frameUpdateScore = server.frameUpdateScore;
pub const frameDisplayScoreboard = server.frameDisplayScoreboard;
pub const TeamInfo = server.TeamInfo;
pub const frameTeams = server.frameTeams;

pub const parseKeepAlive = player.parseKeepAlive;
pub const parseFlying = player.parseFlying;
pub const parsePosition = player.parsePosition;
pub const parseLook = player.parseLook;
pub const parsePositionLook = player.parsePositionLook;
pub const parseClientSettings = player.parseClientSettings;
pub const parseClientStatus = player.parseClientStatus;
pub const SlotItem = player.SlotItem;
pub const parseSlot = player.parseSlot;
pub const parseDigging = player.parseDigging;
pub const parsePlacement = player.parsePlacement;
pub const parseHeldSlot = player.parseHeldSlot;
pub const parseEntityAction = player.parseEntityAction;
pub const parseArmAnimation = player.parseArmAnimation;
pub const parseUseEntity = player.parseUseEntity;
pub const parseCreativeSlot = player.parseCreativeSlot;
pub const parseClickWindow = player.parseClickWindow;
pub const parseCloseWindow = player.parseCloseWindow;
pub const parseEnchantItem = player.parseEnchantItem;
pub const parseTabComplete = player.parseTabComplete;

pub const frameOpenWindow = inventory.frameOpenWindow;
pub const frameCloseWindow = inventory.frameCloseWindow;
pub const frameProgressBar = inventory.frameProgressBar;
pub const frameSetSlotAlloc = inventory.frameSetSlotAlloc;
pub const frameWindowItemsAlloc = inventory.frameWindowItemsAlloc;

pub const frameBlockChange = world.frameBlockChange;
pub const frameBlockAction = world.frameBlockAction;
pub const frameBlockBreakAnimation = world.frameBlockBreakAnimation;
pub const frameExplosion = world.frameExplosion;
pub const ExplosionRecord = world.ExplosionRecord;
pub const frameSpawnGlobalEntity = world.frameSpawnGlobalEntity;
pub const frameWorldEffect = world.frameWorldEffect;
pub const frameSoundEffect = world.frameSoundEffect;

pub const toFixed = entity.toFixed;
pub const toPackedByte = entity.toPackedByte;
pub const writeLivingBaseline = entity.writeLivingBaseline;
pub const frameSpawnPlayer = entity.frameSpawnPlayer;
pub const frameSpawnMob = entity.frameSpawnMob;
pub const frameDestroyEntitiesFramed = entity.frameDestroyEntitiesFramed;
pub const frameEntityTeleport = entity.frameEntityTeleport;
pub const frameEntityRelativeMove = entity.frameEntityRelativeMove;
pub const frameEntityLook = entity.frameEntityLook;
pub const frameEntityMoveLook = entity.frameEntityMoveLook;
pub const frameEntityHeadLook = entity.frameEntityHeadLook;
pub const frameSpawnObject = entity.frameSpawnObject;
pub const frameCollect = entity.frameCollect;
pub const frameItemMetadata = entity.frameItemMetadata;
pub const frameEntityMetadata = entity.frameEntityMetadata;
pub const frameBossSpawn = entity.frameBossSpawn;
pub const frameBossUpdate = entity.frameBossUpdate;
pub const frameEntityEffect = entity.frameEntityEffect;
pub const frameRemoveEntityEffect = entity.frameRemoveEntityEffect;
pub const frameAnimation = entity.frameAnimation;

pub const parseChat = chat.parseChat;
pub const frameChat = chat.frameChat;
pub const escapeJsonText = chat.escapeJsonText;
pub const formatChatJson = chat.formatChatJson;

test {
    _ = @import("handshake.zig");
    _ = @import("server.zig");
    _ = @import("player.zig");
    _ = @import("inventory.zig");
    _ = @import("world.zig");
    _ = @import("entity.zig");
    _ = @import("chat.zig");
}
