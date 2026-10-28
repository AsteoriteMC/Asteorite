//! Compatibility shim: the 1.7.10 packet bodies moved to `packets/`.
//!
//! One module per packet purpose: `handshake`, `server`, `player`,
//! `inventory`, `world`, `entity`, `chat` (see `packets/root.zig`).
//! This file re-exports the flat API so existing `packets.frameX`
//! call sites keep compiling; new code may import a category directly.

const root = @import("packets/root.zig");

pub const Handshake = root.Handshake;
pub const parseHandshake = root.parseHandshake;
pub const frameStatusResponse = root.frameStatusResponse;
pub const parsePing = root.parsePing;
pub const framePong = root.framePong;
pub const parseLoginStart = root.parseLoginStart;
pub const EncryptionRequest = root.EncryptionRequest;
pub const frameEncryptionRequest = root.frameEncryptionRequest;
pub const EncryptionResponse = root.EncryptionResponse;
pub const parseEncryptionResponse = root.parseEncryptionResponse;
pub const frameLoginSuccess = root.frameLoginSuccess;
pub const frameLoginDisconnect = root.frameLoginDisconnect;
pub const JoinGame = root.JoinGame;
pub const frameJoinGame = root.frameJoinGame;
pub const parseJoinGame = root.parseJoinGame;
pub const frameSpawnPosition = root.frameSpawnPosition;
pub const frameRespawn = root.frameRespawn;
pub const frameTimeUpdate = root.frameTimeUpdate;
pub const abilityFlags = root.abilityFlags;
pub const framePlayerAbilities = root.framePlayerAbilities;
pub const frameUpdateHealth = root.frameUpdateHealth;
pub const frameSetExperience = root.frameSetExperience;
pub const framePlayerListItem = root.framePlayerListItem;
pub const PlayerPosLook = root.PlayerPosLook;
pub const framePlayerPosLook = root.framePlayerPosLook;
pub const frameDisconnect = root.frameDisconnect;
pub const frameKeepAlive = root.frameKeepAlive;
pub const frameTabComplete = root.frameTabComplete;
pub const game_state_begin_rain = root.game_state_begin_rain;
pub const game_state_end_rain = root.game_state_end_rain;
pub const game_state_change_gamemode = root.game_state_change_gamemode;
pub const game_state_rain_strength = root.game_state_rain_strength;
pub const game_state_thunder_strength = root.game_state_thunder_strength;
pub const frameGameState = root.frameGameState;
pub const frameObjective = root.frameObjective;
pub const frameUpdateScore = root.frameUpdateScore;
pub const frameDisplayScoreboard = root.frameDisplayScoreboard;
pub const TeamInfo = root.TeamInfo;
pub const frameTeams = root.frameTeams;
pub const parseKeepAlive = root.parseKeepAlive;
pub const parseFlying = root.parseFlying;
pub const parsePosition = root.parsePosition;
pub const parseLook = root.parseLook;
pub const parsePositionLook = root.parsePositionLook;
pub const parseClientSettings = root.parseClientSettings;
pub const parseClientStatus = root.parseClientStatus;
pub const SlotItem = root.SlotItem;
pub const parseSlot = root.parseSlot;
pub const parseDigging = root.parseDigging;
pub const parsePlacement = root.parsePlacement;
pub const parseHeldSlot = root.parseHeldSlot;
pub const parseEntityAction = root.parseEntityAction;
pub const parseArmAnimation = root.parseArmAnimation;
pub const parseUseEntity = root.parseUseEntity;
pub const parseCreativeSlot = root.parseCreativeSlot;
pub const parseClickWindow = root.parseClickWindow;
pub const parseCloseWindow = root.parseCloseWindow;
pub const parseEnchantItem = root.parseEnchantItem;
pub const parseTabComplete = root.parseTabComplete;
pub const frameOpenWindow = root.frameOpenWindow;
pub const frameCloseWindow = root.frameCloseWindow;
pub const frameProgressBar = root.frameProgressBar;
pub const frameSetSlotAlloc = root.frameSetSlotAlloc;
pub const frameWindowItemsAlloc = root.frameWindowItemsAlloc;
pub const frameBlockChange = root.frameBlockChange;
pub const frameBlockAction = root.frameBlockAction;
pub const frameBlockBreakAnimation = root.frameBlockBreakAnimation;
pub const frameSpawnGlobalEntity = root.frameSpawnGlobalEntity;
pub const frameWorldEffect = root.frameWorldEffect;
pub const frameSoundEffect = root.frameSoundEffect;
pub const toFixed = root.toFixed;
pub const toPackedByte = root.toPackedByte;
pub const writeLivingBaseline = root.writeLivingBaseline;
pub const frameSpawnPlayer = root.frameSpawnPlayer;
pub const frameSpawnMob = root.frameSpawnMob;
pub const frameDestroyEntitiesFramed = root.frameDestroyEntitiesFramed;
pub const frameEntityTeleport = root.frameEntityTeleport;
pub const frameEntityRelativeMove = root.frameEntityRelativeMove;
pub const frameEntityLook = root.frameEntityLook;
pub const frameEntityMoveLook = root.frameEntityMoveLook;
pub const frameEntityHeadLook = root.frameEntityHeadLook;
pub const frameSpawnObject = root.frameSpawnObject;
pub const frameCollect = root.frameCollect;
pub const frameItemMetadata = root.frameItemMetadata;
pub const frameEntityMetadata = root.frameEntityMetadata;
pub const frameBossSpawn = root.frameBossSpawn;
pub const frameBossUpdate = root.frameBossUpdate;
pub const frameEntityEffect = root.frameEntityEffect;
pub const frameRemoveEntityEffect = root.frameRemoveEntityEffect;
pub const frameAnimation = root.frameAnimation;
pub const parseChat = root.parseChat;
pub const frameChat = root.frameChat;
pub const escapeJsonText = root.escapeJsonText;
pub const formatChatJson = root.formatChatJson;
pub const handshake = root.handshake;
pub const server = root.server;
pub const player = root.player;
pub const inventory = root.inventory;
pub const world = root.world;
pub const entity = root.entity;
pub const chat = root.chat;

test {
    _ = root;
}
