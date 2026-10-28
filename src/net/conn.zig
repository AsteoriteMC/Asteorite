//! Per-connection state machine: handshake -> status/login -> play.
//!
//! TCP delivers a byte stream; this handles reassembly (partial frames),
//! dispatch, and a tick-aligned output ring (see `takeOutput`: the server
//! flushes once per 50ms tick instead of per packet).
//! Encryption (AES/CFB8) plugs in after EncryptionResponse (online mode);
//! offline mode is fully implemented. Online RSA is NOT (no std RSA) — see
//! `online_mode` handling.

const std = @import("std");
const codec = @import("codec.zig");
const ids = @import("../proto/v5/ids.zig");
const packets = @import("../proto/v5/packets.zig");
const slot_mod = @import("../proto/v5/slot.zig");
const item_mod = @import("../item.zig");
const recipes_mod = @import("../sim/world/recipes.zig");
const container_mod = @import("../sim/world/container.zig");
const interaction_mod = @import("../sim/world/interaction.zig");
const movement_mod = @import("../sim/world/movement.zig");
const uuid_mod = @import("uuid.zig");
const cfb8 = @import("cfb8.zig");
const rsa_mod = @import("rsa.zig");
const mojang = @import("mojang.zig");
const spin = @import("../sim/core/spin.zig");
const game_ids = @import("../ids.zig");
const status_mod = @import("status.zig");
const redstone_mod = @import("../sim/world/redstone.zig");
const profile = @import("../version.zig");
const arena_mod = @import("../sim/core/arena.zig");
const transport_mod = @import("transport.zig");
const rules_mod = @import("../game/rules.zig");
const ratelimit_mod = @import("../sim/core/ratelimit.zig");
const player_db = @import("../sim/player/players.zig");

/// Server-driven tick intervals.
pub const keepalive_interval_ms: i64 = 15000;
pub const keepalive_timeout_ms: i64 = 30000;
pub const time_interval_ms: i64 = 1000;

pub const max_frame_len = 2 * 1024 * 1024; // 2MB guard

pub const Config = struct {
    motd: []const u8 = "Asteorite",
    max_players: u16 = 20,
    /// Fallback count when no live source refreshes it (tests, offline
    /// tools). The serve thread overwrites this from the registry before
    /// answering each status request.
    online_count: u16 = 0,
    /// Handshake brand advertised in the status JSON (vanilla/fabric/forge).
    /// Forge adds the FML modinfo block; the mod list stays empty until the
    /// modding API registers mods.
    brand: status_mod.Brand = .vanilla,
    gamemode: rules_mod.GameMode = .creative,
    difficulty: rules_mod.Difficulty = .easy,
    level_type: []const u8 = "default",
    spawn_x: i32 = 8,
    spawn_y: i32 = 64,
    spawn_z: i32 = 8,
    online_mode: bool = false,
    /// Borrowed RSA keypair; required when online_mode is true.
    rsa: ?*const rsa_mod.RsaKeyPair = null,
    auth_url: []const u8 = "https://sessionserver.mojang.com/session/minecraft/hasJoined",
    /// Phase B: per-connection cap on queued output bytes. A slow
    /// consumer that lets its outbox grow past this is kicked (the queue
    /// is unbounded otherwise, and chunk bulks are megabytes).
    out_cap_bytes: usize = 4 * 1024 * 1024,
    /// Block-place flood budget (creative spam = chunk rewrite storm into
    /// the LSM). Server template value, copied to every conn at accept;
    /// admin-tunable via config file / CLI. The window capacity in
    /// sim/core/ratelimit.zig caps the burst.
    place_window_ms: i64 = ratelimit_mod.default_place_window_ms,
    place_burst: usize = ratelimit_mod.default_place_burst,
    /// Consecutive-dig flood budget (rapid dig packets = chunk-decode +
    /// resync-peek storm). Same kick discipline as placements.
    dig_window_ms: i64 = ratelimit_mod.default_dig_window_ms,
    dig_burst: usize = ratelimit_mod.default_dig_burst,
    /// Global packets-per-second cap per conn (0 = off). Counts every
    /// frame in sessionLocked against a 1s rolling window; tripping kicks
    /// with the same message as the other flood gates.
    max_packets_per_second: u32 = 0,
    /// Max inbound frame length (receive reassembly guard). Must stay
    /// above the largest legit bulk (multi-column 0x26); validated so a
    /// too-small cap can't brick joining.
    frame_max_len: usize = max_frame_len,
    /// Chat cooldown window + burst inside it (vanilla-style spam kick
    /// otherwise). Same template path as the other flood budgets.
    chat_window_ms: i64 = ratelimit_mod.default_chat_window_ms,
    chat_burst: usize = ratelimit_mod.default_chat_burst,
};

/// Block mutation request (break = id 0). Serve loop applies to the world
/// store, then broadcasts to viewers tracking the chunk.
pub const BlockEvent = struct {
    x: i32,
    y: u8,
    z: i32,
    id: game_ids.Id,
    meta: u4,
    /// Clicked face (0-5) for right-clicks; tells serve which cell was
    /// clicked (table-vs-place decision). Breaks leave the default.
    face: i8 = 1,
};

/// Q-key drop (digging status 3 = whole stack, 4 = one item). `stack` is
/// OWNED (cloned at dig time, or the moved slot contents); the serve loop
/// takes ownership into the item entity. `slot` is the window slot to refresh
/// with a 0x2F after the inventory mutation.
pub const QDropEvent = struct { stack: item_mod.Stack, slot: i16 };

/// Right-click eat/drink attempt (food, milk, or a drinkable potion held).
/// The serve thread resolves UI routing first (tables/furnaces win over
/// eating, like vanilla), then starts the 32-tick use. `slot`/`id` snapshot
/// the held stack at click time; the serve thread re-validates before starting.
pub const EatEvent = struct {
    /// Clicked face (-1 = air, no UI possible) or 0-5 with target cell.
    face: i8,
    x: i32,
    y: u8,
    z: i32,
    slot: usize,
    id: game_ids.Id,
    damage: i16,
};

/// Right-click splash-potion throw. The serve thread validates the held
/// stack is still a splash potion, spawns the arc entity, and consumes one
/// (creative keeps). No wind-up: vanilla throws on click, unlike drinking.
pub const ThrowPotionEvent = struct {
    slot: usize,
    damage: i16,
};

/// Flint-and-steel right-click on a block. The serve thread peeks the
/// CLICKED cell: live TNT primes (full fuse, flint takes 1 damage) while
/// anything else NACKs the target (no fire placement — the client
/// predicted fire there and L1 owns fire). `primed` is serve-set for the
/// second-loop flint wear.
pub const IgniteEvent = struct {
    x: i32,
    y: u8,
    z: i32,
    slot: usize,
    tx: i32,
    ty: u8,
    tz: i32,
    primed: bool = false,
};

/// Dig negative-ack (vanilla S23-iff-solid): the serve thread re-reads the
/// cell and 0x23s the digger with truth when it is still solid. Fires on
/// every refused dig (reach/pending/apply-failure) because the client
/// predicts the removal on FINISH (and on creative START): a bare drop
/// strands the prediction as a ghost block.
pub const ResyncEvent = struct { x: i32, y: u8, z: i32 };

/// Refused placement: serve re-reads the TARGET cell and 0x23s the placer
/// with truth even when air. Unlike dig-NACK (iff-solid: the client removed
/// and agreement needs no packet), a refused place leaves the client's
/// prediction standing — a bare drop strands it as a ghost wall the client
/// then collides with (sudden stop + stuck jitter while moving).
pub const PlaceDenyEvent = struct { x: i32, y: u8, z: i32 };

/// Furnace click (window 2): resolved by the serve thread (furnace state is
/// server-owned under furn_lock). Click validation happened in handleFrame.
pub const FurnaceClick = struct { slot: i16, button: i8, action: i16, mode: i8 };

/// Brewing-stand click (window 7): same wire shape as FurnaceClick, but
/// resolved by the brewing path (server-owned under brew_lock). Kept as a
/// distinct type so window-2 and window-7 clicks cannot be confused.
pub const BrewClick = struct { slot: i16, button: i8, action: i16, mode: i8 };

/// Chest click (windows 5/6): resolved by the serve thread (chest rows
/// are server-owned under chest_lock; one chest can have many viewers).
/// Validation happened in handleFrame; the serve thread re-checks the
/// open window id and slot bounds (single 63 vs double 90 slots).
pub const ChestClick = struct { slot: i16, button: i8, action: i16, mode: i8 };

/// Chest close (windows 5/6): serve loop drops the viewer count (lid
/// sound when the last viewer leaves). Contents persist server-side, so
/// unlike the table nothing drops. Carries the cell pos (open_win is
/// already cleared conn-side, like the furnace path).
pub const ChestClose = struct { window: u8, x: i32, y: u8, z: i32 };

/// Ender-chest close (window 3): serve loop plays the lid sound at the
/// chest and syncs the lid when the last viewer leaves. Contents persist
/// per player. Carries the cell pos (open_win is already cleared
/// conn-side); the table_close path never sees window 3.
pub const EnderClose = struct { x: i32, y: u8, z: i32 };

/// Enchanting-table click (window 4): same wire shape as FurnaceClick, but
/// resolved by the enchanting path (conn-owned item + bookshelf recount).
/// Kept as a distinct type so window-2 and window-4 clicks cannot be
/// confused at the call site.
pub const EnchantClick = struct { slot: i16, button: i8, action: i16, mode: i8 };

/// Serverbound 0x11 enchant item (window 4, slot 0/1/2 offer).
pub const EnchantEvent = struct { window: u8, slot: u8 };

/// Crafting-table close: OWNED grid stacks (result slot is virtual and
/// vanishes) for the serve loop to drop as entities + 0x2E the window.
/// Crafting-table close (0x0D or block break): grid contents (result slot
/// is virtual and vanishes) drop as entities; serve loop sends 0x2E + spawns.
/// Furnace close reuses this with window=2 and empty stacks (contents stay
/// in the server furnace — only the UI closes).
pub const TableClose = struct { window: u8, stacks: [9]?item_mod.Stack };

/// Outbound chat line (validated JSON in conn.chat_buf).
pub const ChatEvent = struct {
    json_len: usize,
};

/// Validated melee attack (serverbound 0x02, action == attack).
/// Attacker snapshot is baked in at parse time (under conn.lock) so the
/// tick thread can resolve damage without taking more locks.
pub const AttackEvent = struct {
    target_eid: i32,
    /// Damage from the attacker's held item (vanilla 1.7 table, no enchants —
    /// NBT is skipped, documented in onPlace).
    dmg: f32,
    ax: f64,
    ay: f64,
    az: f64,
};

pub const Action = union(enum) {
    none,
    /// A status ping completed; caller should flush then close.
    close_after_flush,
    /// Switched to play; bootstrap packets queued.
    entered_play,
    disconnect_queued,
    /// Mutate one block then broadcast 0x23 to chunk viewers (not sender).
    block_set: BlockEvent,
    /// Refused dig: serve re-reads the cell and 0x23s the digger with
    /// truth when still solid (client predicted the removal).
    block_resync: ResyncEvent,
    /// Refused placement: serve re-reads the TARGET cell and 0x23s the
    /// placer with truth even when air (client predicted the block).
    place_deny: PlaceDenyEvent,
    /// Empty-hand (or interactable) right-click: serve resolves the clicked
    /// block first (crafting table / furnace / K1 lever-door-repeater-ore);
    /// only unhandled clicks with a held item fall through to placement.
    /// Coordinates are the TARGET cell (clicked + face), like block_set.
    interact: BlockEvent,
    /// Validated melee attack: resolved by the tick thread against mobs +
    /// players (carries attacker snapshot so no locks are needed later).
    attack: AttackEvent,
    /// Q-key item drop: serve loop spawns the entity + refreshes the slot.
    qdrop: QDropEvent,
    /// Right-click eat/drink: serve resolves UI routing, then starts the
    /// 32-tick use on the serve thread (finish heals + consumes).
    eat: EatEvent,
    /// Right-click splash-potion throw: serve spawns the arc entity and
    /// consumes one from the held stack.
    throw_potion: ThrowPotionEvent,
    /// Flint-and-steel right-click: serve primes clicked TNT or NACKs
    /// the target (no fire placement yet).
    ignite_tnt: IgniteEvent,
    /// Right-click air with armor held: serve loop equips one piece
    /// into its armor slot (equip-if-empty) + 0x2F syncs.
    equip_armor,
    /// Furnace click (window 2): serve loop mutates server state + syncs.
    furnace_click: FurnaceClick,
    /// Brewing-stand click (window 7): serve loop mutates the server brew
    /// state + syncs.
    brew_click: BrewClick,
    /// Chest click (windows 5/6): serve loop mutates the shared chest row
    /// (multi-viewer) + syncs actor and viewers.
    chest_click: ChestClick,
    /// Chest close (windows 5/6): serve loop plays the lid sound when the
    /// last viewer leaves (contents persist; nothing drops).
    chest_close: ChestClose,
    /// Ender-chest close (window 3): serve loop plays the lid sound at
    /// the chest + lid event when the last viewer leaves.
    ender_close: EnderClose,
    /// Enchanting-table click (window 4): serve loop mutates the conn-owned
    /// enchant item + recomputes levels + syncs.
    enchant_click: EnchantClick,
    /// Serverbound 0x11 enchant item: apply one of the three offers.
    enchant: EnchantEvent,
    /// Crafting-table close (0x0D or table break): grid contents drop as
    /// entities in front of the player; serve loop sends 0x2E + spawns.
    table_close: TableClose,
    /// Relay arm swing 0x0B to chunk viewers (not sender).
    arm_swing: i8,
    /// Serverbound 0x14 tab-complete text (raw, in tab_buf). Handled by the
    /// serve thread (server.handleTabComplete), which may queue a 0x3A.
    tab_complete: ChatEvent,
    /// Broadcast formatted chat line to all play conns.
    chat: ChatEvent,
    /// Serverbound chat starting with "/" (raw text in chat_buf, cmd_len
    /// bytes). Handled by the serve thread (server.handleCommand), which may
    /// reply to the sender and/or broadcast. Spam-cooldown applies first.
    command: ChatEvent,
};

/// Last state a viewer was sent (for entity delta encoding).
pub const Tracked = struct {
    x: f64,
    y: f64,
    z: f64,
    yaw: f32,
    pitch: f32,
};

pub const Frame = struct {
    id: i32,
    /// Payload WITHOUT the packet id. Valid until next feedData/poll.
    body: []const u8,
};

/// One active potion effect (vanilla PotionEffect: id, amplifier, ticks).
pub const PotionEffect = struct {
    id: u8,
    amplifier: u8,
    ticks: i32,
};

pub const Conn = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    state: ids.State = .handshaking,
    eid: i32 = 0,
    username_len: usize = 0,
    username: [16]u8 = [_]u8{0} ** 16,
    uuid_str: [36]u8 = [_]u8{0} ** 36,
    last_keepalive: i32 = 0,
    /// Window 0 (player inventory): 45 slots. Only hotbar (36..44) is
    /// interpreted for placement; the rest is stored verbatim.
    /// Canonical stacks; NBT buffers are OWNED (duped on store, freed on
    /// replace/deinit) so enchanted/named items survive across frames.
    inv: [item_mod.inv_size]?item_mod.Stack = [_]?item_mod.Stack{null} ** item_mod.inv_size,
    selected: u8 = 0,
    pending_dig: ?struct { x: i32, y: u8, z: i32 } = null,
    /// Survival cursor stack (mode-0 clicks) + per-window action counters
    /// for click validation (desync -> full Window Items refresh, never a
    /// kick). One expectation per window id (0..7): vanilla restarts the
    /// click action number with every window open (per-container
    /// transactionID), so a single shared counter desyncs forever after
    /// the first window switch — every later click in the new window
    /// mismatches and snaps back, and the reject path never advances the
    /// counter to heal. Reset on every open AND close (see resetClickSeq).
    cursor: ?item_mod.Stack = null,
    click_seq: [8]i16 = [_]i16{0} ** 8,
    click_seen: [8]bool = [_]bool{false} ** 8,
    /// Mode-5 drag-spread (paint) in progress. Vanilla streams start /
    /// add-slot / end clicks; the END distributes the cursor across the
    /// accumulated slots. Any other click, a window change, or death
    /// cancels (vanilla drops the drag). Shared by conn-local windows
    /// (0/1/3) and the serve-thread ones (2/5/6), which resolve their
    /// cells through the same state.
    drag: container_mod.DragPaint = .{},
    /// Window 1 (crafting table): slot 0 = result, 1-9 = 3x3 grid.
    /// Owned stacks (NBT duped). open_win records the table block pos.
    table: [10]?item_mod.Stack = [_]?item_mod.Stack{null} ** 10,
    /// Window 3 (ender chest): 27 per-player slots shared by every ender
    /// chest (vanilla EnderItems). Owned stacks, loaded from the player
    /// row on login and written back on save — never dropped on close,
    /// break, or death. open_win id 3 records the chest pos.
    ender: [player_db.ender_size]?item_mod.Stack = [_]?item_mod.Stack{null} ** player_db.ender_size,
    /// Window 4 (enchanting table): single item slot (1.7.10 has no lapis).
    /// Owned stack; levels/seed drive the K3 engine. open_win id 4 records
    /// the table pos, like the table/furnace paths.
    enchant_item: ?item_mod.Stack = null,
    enchant_levels: [3]i32 = .{ 0, 0, 0 },
    enchant_seed: i32 = 0,
    open_win: ?struct { id: u8, x: i32, y: u8, z: i32 } = null,
    sneaking: bool = false,
    /// Survival state. Damage resolution lives in the tick thread
    /// (server.zig); the serve thread only records validated attack events.
    /// While is_dead the client shows the death screen: block/entity
    /// actions are dropped until Client Status 0 (respawn) arrives.
    health: f32 = 20.0,
    food: i16 = 20,
    saturation: f32 = 5.0,
    is_dead: bool = false,
    /// Hunger/attrition state (vanilla FoodStats + env hazards). Ticks are
    /// 20tps units advanced 20 per 1Hz server tick (same convention as
    /// world_age); server.zig drives, conn owns. Not persisted (ZPLR keeps
    /// health/food/saturation; these reset on login — documented J2 gap).
    exhaustion: f32 = 0,
    /// Hunger-audit income counters by source (move/jump/regen), reset on
    /// every visible food/saturation drop (see hungerTick). Diagnoses
    /// "drains too fast" reports without guessing: the drop line in the
    /// file log shows exactly which income caused each drumstick.
    exh_move: f32 = 0,
    exh_jump: f32 = 0,
    exh_regen: f32 = 0,
    food_timer: u32 = 0,
    air: i16 = 300,
    fire_ticks: u32 = 0,
    /// Cactus hurt throttle (1Hz ticks remaining; vanilla hurt-resistance
    /// gates to ~1/0.5s, quantized here to one hit per touching tick).
    cactus_cd: u8 = 0,
    /// Save-epoch assigned at login (see Server.bumpSaveEpoch): a stale
    /// session's delayed save is dropped once a newer login owns the row.
    save_epoch: u64 = 0,
    /// Epoch for this name seen when our login started (see
    /// Server.epochFor). The straggler fence compares it at the
    /// duplicate-kick point: a mismatch means a newer login bumped the
    /// row while we were wedged mid-login, so we abort instead of
    /// kicking the live session (or poisoning the epoch further).
    login_epoch_seen: u64 = 0,
    sprinting: bool = false,
    /// Accumulated downward distance while airborne (vanilla fallDistance).
    fall_acc: f32 = 0,
    /// Landing awaiting a water check (serve thread owns the pool peek).
    pending_fall: ?struct { dist: f32, x: f64, y: f64, z: f64 } = null,
    /// Food/drink use in progress (vanilla 32-tick ItemFood use): slot +
    /// item snapshot at click time, counted down on the serve tick. Any
    /// dig packet but Q-drop, attack, held change, fresh right-click, or
    /// death aborts (vanilla clearItemInUse discipline; release = status
    /// 5). The per-tick slot check also catches Q-dropped stacks.
    eating: ?struct { slot: usize, id: game_ids.Id, damage: i16, ticks: u8 } = null,
    /// Connection established timestamp (ms, monotonic). Login must complete
    /// within login_timeout_ms or the ticker drops the connection.
    connected_at_ms: i64 = 0,
    /// Set when the join is announced to other players (leave broadcast iff set).
    announced: bool = false,
    /// Scratch for one validated outbound chat line (JSON).
    chat_buf: [1024]u8 = [_]u8{0} ** 1024,
    last_chat_ms: ?i64 = null,
    /// Burst allowance inside the chat cooldown window. The cooldown is
    /// measured at receive time, but a multithreaded server can stall reads
    /// (chunk-bulk writes, world_lock contention, SST flushes) and then
    /// read two legit chats back-to-back — that must not kick. Vanilla is
    /// similarly lenient (threshold counter, not a single gap). Kick only
    /// when the burst exceeds this many chats inside one window.
    chat_burst: usize = 0,
    /// Block-place flood gate state (sliding window; counts every
    /// placement attempt, valid or not). Budget lives in Config so the
    /// server template carries the admin-tuned values to every conn.
    place_gate: ratelimit_mod.Window(ratelimit_mod.place_window_capacity) = .{},
    /// Consecutive-dig flood gate state (same discipline as placements;
    /// budget in Config for the same template path).
    dig_gate: ratelimit_mod.Window(ratelimit_mod.dig_window_capacity) = .{},
    /// Global packets-per-second accounting (config max_packets_per_second,
    /// 0 = off): rolling 1s window start + frames seen inside it. Counted
    /// in sessionLocked (conn.lock held there); tripping kicks.
    pps_window_ms: i64 = 0,
    pps_count: u32 = 0,
    /// Scratch for one serverbound 0x14 tab-complete request (raw text).
    tab_buf: [1024]u8 = [_]u8{0} ** 1024,
    /// Peer address ("127.0.0.1"-style; filled by the serve thread from the
    /// accepted socket — used by /ban-ip matching and login IP-ban checks).
    ip: [64]u8 = [_]u8{0} ** 64,
    ip_len: usize = 0,
    /// Last play-frame timestamp (ms). The ticker kicks past the idle
    /// timeout (`/setidletimeout`); 0 disables. Updated per frame above.
    last_active_ms: i64 = 0,
    /// Experience (vanilla EntityPlayer fields; persisted in ZPLR v4).
    xp_level: i32 = 0,
    xp_total: i32 = 0,
    xp_bar: f32 = 0,
    /// Active potion effects (vanilla PotionEffect list, ephemeral across
    /// logins — ZPLR keeps health/food/saturation only). Ticked down by
    /// the server ticker, which sends S1E removals on expiry.
    effects: [8]?PotionEffect = [_]?PotionEffect{null} ** 8,
    /// Personal spawn set via /spawnpoint (vs world default).
    spawn_forced: bool = false,
    /// Awarded achievement names (`achievement.*`, max 32, ephemeral).
    achieved: [32][40]u8 = [_][40]u8{[_]u8{0} ** 40} ** 32,
    achieved_len: usize = 0,
    // tracked player state (serverbound position packets; stance consumed)
    pos_x: f64 = 8.5,
    pos_y: f64 = 64.0,
    pos_z: f64 = 8.5,
    yaw: f32 = 0,
    pitch: f32 = 0,
    on_ground: bool = false,
    /// Login grace: the last teleported-to position (login PosLook /
    /// respawn). While the grace is armed (deadline in `login_grace_ms`,
    /// 0 = inactive), pure falls below it are held server-side: a real
    /// client that falls through not-yet-streamed ground during the login
    /// burst would otherwise be adopted at the fallen position (and that
    /// wrong position persisted). Cleared by the exact PosLook echo, by
    /// any horizontal move (the client is live), or by timeout; the serve
    /// loop re-snaps the client once ground is confirmed present.
    login_x: f64 = 8.5,
    login_y: f64 = 64.0,
    login_z: f64 = 8.5,
    login_grace_ms: i64 = 0,
    login_fell: bool = false,
    login_resynced: bool = false,
    /// Grace lapse: set when the deadline passes while falls are still
    /// held. Packets can't see generation state, so the timeout parks for
    /// the serve loop to resolve (re-arm while the client's column is
    /// still a hole, release once ground exists) instead of adopting
    /// blindly — adopting a fall through an undelivered column buries the
    /// player in terrain that generates solid around them.
    login_grace_lapsed: bool = false,
    /// Rescue-desync breaker (see rescueEmbedded): repeated per-tick
    /// rescues at one column mean the client can't see the ground the
    /// server stands it on (lost burst column — the protocol has no NACK,
    /// and the hole-healer skips `sent` columns forever). The third rescue
    /// inside the window drops the column from `sent` so the 10Hz rescan
    /// re-pushes it (spiral is center-first, so the player's own column
    /// heals first). Fields live here (not in the tick) because the count
    /// spans ticks; mutated under conn.lock like the rest of conn state.
    rescue_cell_x: i32 = 0,
    rescue_cell_z: i32 = 0,
    rescue_n: u8 = 0,
    rescue_window_ms: i64 = 0,
    /// Grace lapse: set when the deadline passes while falls are still
    /// held. Packets can't see generation state, so the timeout parks for
    /// the serve loop to resolve (re-arm while the client's column is
    /// still a hole, release once ground exists) instead of adopting
    /// blindly — adopting a fall through an undelivered column buries the
    /// player in terrain that generates solid around them.
    /// Columns already sent groundUp (groundUp re-send leaks client memory,
    /// so each column goes out at most once until unloaded). Key: x<<32|z.
    sent: std.AutoHashMap(i64, void),
    /// Reusable bulk-encode scratch (sendColumns writes grouped columns here).
    /// Allocated once and retained: this allocator is a never-reset arena,
    /// so per-call 12MB allocs leak until process exit — that OOM-freezes
    /// the box under gen-storm retries. Freed in deinit.
    bulk_raw: []u8 = &[_]u8{},
    bulk_comp: []u8 = &[_]u8{},
    bulk_work: []u8 = &[_]u8{},
    sent_center: ?struct { cx: i32, cz: i32 } = null,
    /// Phase C: tick-region (32x32 chunks) the player was in on the last
    /// server tick. Compared every tick: a change pushes a Transfer into
    /// the target region's inbox (cross-region handoff). Null until the
    /// first tick (spawn, not a crossing — no Transfer).
    last_region: ?struct { rx: i32, rz: i32 } = null,
    /// Set once the login burst went out; movement before that is ignored.
    baseline_sent: bool = false,
    /// Tick-maintained fluid contact (eyes or feet in water/lava, per the
    /// 1Hz env scan). While set, descents are swimming, not falling:
    /// vanilla resets fallDistance in fluid, so a surface swim can't
    /// ratchet up fall damage that lands when walking out onto a beach.
    /// Written by the tick, consumed in setPos (same lock as haz_*).
    in_fluid: bool = false,
    /// Movement bounding box since the last hazard sample (min/max of
    /// every adopted position). The sweep covers this box, so even a
    /// round trip completed inside one 1Hz tick still collides.
    /// Expanded in setPos (same lock discipline as the other tick
    /// fields); reset to the current pos by the snapshot pass.
    haz_min_x: f64 = 0,
    haz_min_y: f64 = 0,
    haz_min_z: f64 = 0,
    haz_max_x: f64 = 0,
    haz_max_y: f64 = 0,
    haz_max_z: f64 = 0,
    /// Set once the snapshot pass has initialized the hazard bbox.
    haz_set: bool = false,
    /// Set by movement/respawn handlers; serveConn drains via view.sync.
    chunks_dirty: bool = false,
    /// Respawn: unload everything first, then full re-burst.
    force_resync: bool = false,
    /// Last observed background-gen sequence (async gen follow-up below).
    last_gen_seq: u64 = 0,
    /// Last async-gen retry (ms). Retries re-scan the view disk; without a
    /// floor, a gen storm re-runs 1k+ store reads every serve iteration.
    last_gen_retry_ms: i64 = 0,
    /// From Client Settings 0x15 (unclamped); effective radius = min(this, server max).
    client_view: ?u8 = null,
    /// Per-viewer entity visibility (ticker writes under conn.lock).
    tracked: std.AutoHashMap(i32, Tracked),
    // ---- server-tick state (touched by serve + ticker threads: hold lock) ----
    /// Guards out/read/sent/state and all tick fields below.
    lock: spin.SpinLock = .{},
    /// Serializes socket writes (serve flush vs ticker flush).
    wlock: spin.SpinLock = .{},
    /// Registry refcount (server holds no ref; forEach takes temp refs).
    refs: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Set by the ticker on timeout; serveConn exits after flushing.
    dead: bool = false,
    /// Set once by unregister under conn.lock before anything else.
    /// Liveness bit for code that drops conn.lock across slow work
    /// (login burst): a racing unregister sets this, and the unlocked
    /// path aborts instead of completing a dead login. Never read or
    /// written while holding any other lock (ABBA: playNames takes
    /// reg_lock, then conn locks — the reverse order here would
    /// deadlock the whole server under a join storm).
    closed: bool = false,    keepalive_id: i32 = 0,
    next_keepalive_ms: i64 = 0,
    keepalive_outstanding: bool = false,
    keepalive_sent_ms: i64 = 0,
    last_echo_ms: i64 = -1,
    first_tick_ms: i64 = -1,
    ping_ms: std.atomic.Value(i16) = std.atomic.Value(i16).init(1),
    next_time_ms: i64 = 0,
    close_after_flush: bool = false,
    // online-mode session state
    verify_token: [4]u8 = [_]u8{0} ** 4,
    awaiting_enc_response: bool = false,
    enc: ?cfb8.Cfb8 = null, // encrypts queued output once enabled
    dec: ?cfb8.Cfb8 = null, // decrypts fed input once enabled
    read: std.ArrayList(u8) = .empty,
    out: std.ArrayList(u8) = .empty,
    /// Scratch for the current frame body. `poll` copies the body here
    /// BEFORE compacting `read` (compaction memsets vacated bytes to
    /// `undefined`, so returning a slice into `read` would alias poisoned
    /// memory). Valid until the next poll/feedData.
    frame: std.ArrayList(u8) = .empty,
    /// Phase B: transport-assigned connection id (0 = blocking transport,
    /// which does not use ids). The server uses it to route flush and
    /// close requests to the owning transport worker.
    transport_id: u32 = 0,
    /// Phase B: the async transport that owns this connection (null =
    /// blocking transport, which writes to the socket itself).
    transport: ?transport_mod.Handle = null,
    /// Phase B: the queued output grew past `config.out_cap_bytes`.
    /// The server kicks the connection (slow-consumer protection).
    overflow: bool = false,
    /// Phase D: scratch arena for the decrypt/encrypt copies. Reset after
    /// every use, so the steady-state allocation rate is zero.
    scratch: arena_mod.Arena = .{},

    // ---- lifecycle ----

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config, eid: i32) Conn {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .eid = eid,
            .pos_x = @as(f64, @floatFromInt(config.spawn_x)) + 0.5,
            .pos_y = @as(f64, @floatFromInt(config.spawn_y)),
            .pos_z = @as(f64, @floatFromInt(config.spawn_z)) + 0.5,
            .sent = std.AutoHashMap(i64, void).init(allocator),
            .tracked = std.AutoHashMap(i32, Tracked).init(allocator),
            .connected_at_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds(),
            .scratch = arena_mod.Arena.init(allocator, 4096),
        };
    }

    pub fn deinit(self: *Conn) void {
        self.read.deinit(self.allocator);
        self.out.deinit(self.allocator);
        self.frame.deinit(self.allocator);
        self.sent.deinit();
        self.tracked.deinit();
        self.scratch.deinit();
        if (self.bulk_raw.len > 0) self.allocator.free(self.bulk_raw);
        if (self.bulk_comp.len > 0) self.allocator.free(self.bulk_comp);
        if (self.bulk_work.len > 0) self.allocator.free(self.bulk_work);
        for (&self.inv) |*s| item_mod.freeStack(self.allocator, s);
        for (&self.table) |*s| item_mod.freeStack(self.allocator, s);
        for (&self.ender) |*s| item_mod.freeStack(self.allocator, s);
        item_mod.freeStack(self.allocator, &self.enchant_item);
        item_mod.freeStack(self.allocator, &self.cursor);
    }

    /// Pack chunk coords for the sent-set.
    pub fn sentKey(x: i32, z: i32) i64 {
        return (@as(i64, x) << 32) | @as(u32, @bitCast(z));
    }

    // ---- frame reassembly + dispatch ----

    pub fn feedData(self: *Conn, data: []const u8) !void {
        if (self.dec) |*d| {
            // AES-CFB8 is a stream cipher: decrypt arrival-ordered bytes.
            // The scratch arena (Phase D) replaces the per-feed heap dupe:
            // the copy is a bump allocation and the arena is reset right
            // after the bytes land in the (owning) read buffer.
            const tmp = try self.scratch.alloc(data.len);
            defer self.scratch.reset();
            @memcpy(tmp, data);
            d.decrypt(tmp);
            try self.read.appendSlice(self.allocator, tmp);
        } else {
            try self.read.appendSlice(self.allocator, data);
        }
        if (self.read.items.len > self.config.frame_max_len + 8) return error.FrameTooLarge;
    }

    /// Parse one frame if complete. Returns null when more bytes are needed.
    /// Caller must handleFrame before the next poll (body aliases read buf).
    pub fn poll(self: *Conn) !?Frame {
        var r = codec.PacketReader.init(self.read.items);
        const start = r.index;
        const length = r.readVarInt() catch |err| switch (err) {
            error.BufferUnderflow => return null,
            else => return err,
        };
        if (length < 0 or length > self.config.frame_max_len) return error.FrameTooLarge;
        const ulen: usize = @intCast(length);
        // need: varint-len(length) + length bytes total
        const header_len = r.index - start;
        if (self.read.items.len < header_len + ulen) return null; // partial
        const id = try r.readVarInt();
        const body_src = self.read.items[r.index .. header_len + ulen];
        // copy body aside, then compact (replaceRange memsets vacated tail
        // to undefined — must not alias read buf across compaction)
        self.frame.clearRetainingCapacity();
        try self.frame.appendSlice(self.allocator, body_src);
        const consumed = header_len + ulen;
        try self.read.replaceRange(self.allocator, 0, consumed, &.{});
        return .{ .id = id, .body = self.frame.items };
    }

    fn queueRaw(self: *Conn, framed: []const u8) !void {
        if (self.enc) |*e| {
            // Scratch arena instead of a per-frame heap dupe (Phase D).
            const tmp = try self.scratch.alloc(framed.len);
            defer self.scratch.reset();
            @memcpy(tmp, framed);
            e.encrypt(tmp);
            try self.out.appendSlice(self.allocator, tmp);
        } else {
            try self.out.appendSlice(self.allocator, framed);
        }
        // Phase B: backpressure. The outbox is unbounded otherwise, and
        // chunk bulks are megabytes: a slow consumer would eat the heap.
        // The server kicks the connection once the cap is hit.
        if (self.out.items.len > self.config.out_cap_bytes) self.overflow = true;
    }

    pub fn handleFrame(self: *Conn, frame: Frame) !Action {
        self.last_active_ms = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
        return switch (self.state) {
            .handshaking => try self.handleHandshaking(frame),
            .status => try self.handleStatus(frame),
            .login => try self.handleLogin(frame),
            .play => try self.handlePlay(frame),
        };
    }

    /// Queue a play disconnect (0x40; login state gets 0x00) and arm
    /// close-after-flush. Pub for the session flood gate (server.zig),
    /// which kicks outside handleFrame.
    pub fn disconnect(self: *Conn, json: []const u8) !Action {
        var buf: [512]u8 = undefined;
        const f = switch (self.state) {
            .login => try packets.frameLoginDisconnect(json, &buf),
            else => try packets.frameDisconnect(json, &buf),
        };
        try self.queueRaw(f);
        self.close_after_flush = true;
        return .disconnect_queued;
    }

    fn handleHandshaking(self: *Conn, frame: Frame) !Action {
        if (frame.id != @as(i32, @intFromEnum(ids.HandshakingServer.handshake))) {
            return try self.disconnect("{\"text\":\"Expected handshake\"}");
        }
        const h = try packets.parseHandshake(frame.body);
        if (h.protocol != ids.protocol_version_1_7_10) {
            var msg: [128]u8 = undefined;
            const m = try std.fmt.bufPrint(&msg, "{{\"text\":\"Outdated client (want proto 5, got {d})\"}}", .{h.protocol});
            return try self.disconnect(m);
        }
        self.state = switch (h.next) {
            1 => .status,
            2 => .login,
            else => return try self.disconnect("{\"text\":\"Bad handshake next state\"}"),
        };
        return .none;
    }

    fn handleStatus(self: *Conn, frame: Frame) !Action {
        if (frame.id == @as(i32, @intFromEnum(ids.StatusServer.request))) {
            // Struct-stringified (never raw format strings: MOTDs with quotes
            // used to emit invalid JSON). Sized by the MOTD, not a fixed buffer.
            const j = try status_mod.writeJson(self.allocator, .{
                .motd = self.config.motd,
                .max_players = self.config.max_players,
                .online_players = self.config.online_count,
                .brand = self.config.brand,
            });
            defer self.allocator.free(j);
            const out = try self.allocator.alloc(u8, j.len + 10);
            defer self.allocator.free(out);
            try self.queueRaw(try packets.frameStatusResponse(j, out));
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.StatusServer.ping))) {
            const payload = try packets.parsePing(frame.body);
            var out: [16]u8 = undefined;
            try self.queueRaw(try packets.framePong(payload, &out));
            self.close_after_flush = true;
            return .close_after_flush;
        }
        return try self.disconnect("{\"text\":\"Bad status packet\"}");
    }

    fn validNameChars(name: []const u8) bool {
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
        }
        return true;
    }

    /// Login + command-target name policy (shared so /op can't smuggle
    /// anything the login gate would reject).
    // ---- handshake/login helpers ----

    pub fn validPlayerName(name: []const u8) bool {
        return name.len > 0 and name.len <= 16 and validNameChars(name);
    }

    fn sendLoginSuccess(self: *Conn, uuid_str: []const u8, name: []const u8) !void {
        var out: [128]u8 = undefined;
        try self.queueRaw(try packets.frameLoginSuccess(uuid_str, name, &out));
    }

    fn enterPlay(self: *Conn) !Action {
        self.state = .play;
        try self.queuePlayBootstrap();
        return .entered_play;
    }

    fn handleLogin(self: *Conn, frame: Frame) !Action {
        if (frame.id == @as(i32, @intFromEnum(ids.LoginServer.login_start))) {
            const name = try packets.parseLoginStart(frame.body);
            if (!validPlayerName(name)) {
                return try self.disconnect("{\"text\":\"Bad username\"}");
            }
            @memcpy(self.username[0..name.len], name);
            self.username_len = name.len;
            if (self.config.online_mode) {
                const keys = self.config.rsa orelse {
                    return try self.disconnect("{\"text\":\"Online mode misconfigured\"}");
                };
                if (name.len < 3) {
                    return try self.disconnect("{\"text\":\"Bad username\"}");
                }
                self.io.randomSecure(&self.verify_token) catch self.io.random(&self.verify_token);
                self.awaiting_enc_response = true;
                var out: [2048]u8 = undefined;
                try self.queueRaw(try packets.frameEncryptionRequest(
                    "",
                    keys.public_key_der,
                    &self.verify_token,
                    &out,
                ));
                return .none;
            }
            const uuid = uuid_mod.offlineUuid(name);
            uuid_mod.formatUuid(uuid, &self.uuid_str);
            try self.sendLoginSuccess(&self.uuid_str, name);
            return try self.enterPlay();
        }
        if (frame.id == @as(i32, @intFromEnum(ids.LoginServer.encryption_response))) {
            if (!self.awaiting_enc_response) {
                return try self.disconnect("{\"text\":\"Unexpected encryption response\"}");
            }
            self.awaiting_enc_response = false;
            const keys = self.config.rsa orelse {
                return try self.disconnect("{\"text\":\"Online mode misconfigured\"}");
            };
            const enc = try packets.parseEncryptionResponse(frame.body);
            const token = keys.decrypt(self.allocator, enc.token_enc) catch {
                return try self.disconnect("{\"text\":\"Bad login token\"}");
            };
            defer self.allocator.free(token);
            if (token.len != 4 or !std.mem.eql(u8, token, &self.verify_token)) {
                return try self.disconnect("{\"text\":\"Bad login token\"}");
            }
            const secret = keys.decrypt(self.allocator, enc.secret_enc) catch {
                return try self.disconnect("{\"text\":\"Bad shared secret\"}");
            };
            defer self.allocator.free(secret);
            if (secret.len != 16) {
                return try self.disconnect("{\"text\":\"Bad shared secret\"}");
            }
            var shared: [16]u8 = undefined;
            @memcpy(&shared, secret[0..16]);
            // Enable link encryption BEFORE session verify (not just before
            // LoginSuccess). The client switches on encryption the moment it
            // sends EncryptionResponse, so a verify failure kick
            // ("Failed to verify username!") must go out encrypted too.
            // Unencrypted post-response kicks garble on the client and
            // surface as "biz cannot be cast to fv" instead of the message.
            self.enc = cfb8.Cfb8.init(&shared);
            self.dec = cfb8.Cfb8.init(&shared);
            const hash = mojang.computeMinecraftHash("", &shared, keys.public_key_der);
            const name = self.username[0..self.username_len];
            const session_uuid = mojang.verifySession(self.io, self.allocator, self.config.auth_url, name, hash.slice()) catch {
                return try self.disconnect("{\"text\":\"Failed to verify username!\"}");
            };
            const hex = std.fmt.bytesToHex(&session_uuid, .lower);
            // hyphenated 8-4-4-4-12
            var p: usize = 0;
            var o: usize = 0;
            const dash_at = [_]usize{ 8, 12, 16, 20 };
            var di: usize = 0;
            while (p < 32) : (p += 1) {
                if (di < 4 and p == dash_at[di]) {
                    self.uuid_str[o] = '-';
                    o += 1;
                    di += 1;
                }
                self.uuid_str[o] = hex[p];
                o += 1;
            }
            // Link encryption already enabled above (before session verify,
            // so failure kicks go out encrypted like vanilla).
            try self.sendLoginSuccess(&self.uuid_str, name);
            return try self.enterPlay();
        }
        return try self.disconnect("{\"text\":\"Unexpected login packet\"}");
    }

    fn queuePlayBootstrap(self: *Conn) !void {
        var jb: [512]u8 = undefined;
        try self.queueRaw(try packets.frameJoinGame(.{
            .eid = self.eid,
            .gamemode = self.config.gamemode.wire(),
            .dimension = 0,
            .difficulty = self.config.difficulty.wire(),
            // Wire max is one byte in 1.7.10 (S01); the status list
            // carries the full configured cap.
            .max_players = @intCast(@min(self.config.max_players, 255)),
            .level_type = self.config.level_type,
        }, &jb));
        var sb: [32]u8 = undefined;
        try self.queueRaw(try packets.frameSpawnPosition(self.config.spawn_x, self.config.spawn_y, self.config.spawn_z, &sb));
        // Chunks (view.completeLogin) go here; PlayerPosLook closes login.
    }

    /// Final login step; view.completeLogin calls this after chunk bulks.
    /// Sends the player's actual position (persisted across restarts, or
    /// spawn on first login — serveConn syncs pos to spawn before calling).
    pub fn queuePlayerPosLook(self: *Conn) !void {
        var pb: [64]u8 = undefined;
        try self.queueRaw(try packets.framePlayerPosLook(.{
            .x = self.pos_x,
            .y = self.pos_y,
            .z = self.pos_z,
            .yaw = self.yaw,
            .pitch = self.pitch,
            .on_ground = false,
        }, &pb));
    }

    /// Raw framed packet into the tick output ring (used by view + tests).
    // ---- play dispatch + inventory/window helpers ----

    pub fn queueFramed(self: *Conn, framed: []const u8) !void {
        try self.queueRaw(framed);
    }

    fn handlePlay(self: *Conn, frame: Frame) !Action {
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.keep_alive))) {
            const id = try packets.parseKeepAlive(frame.body);
            const now = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
            self.last_keepalive = id;
            self.last_echo_ms = now;
            if (self.keepalive_outstanding and id == self.keepalive_id) {
                const rtt = now - self.keepalive_sent_ms;
                self.ping_ms.store(@intCast(@min(rtt, std.math.maxInt(i16))), .release);
                self.keepalive_outstanding = false;
            } else if (self.keepalive_outstanding) {
                // any echo proves liveness even with a stale id
                self.keepalive_outstanding = false;
            }
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.player))) {
            const g = try packets.parseFlying(frame.body);
            self.groundTransition(0, g);
            self.on_ground = g;
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.player_position))) {
            const p = try packets.parsePosition(frame.body);
            self.setPos(p.x, p.y, p.z, self.yaw, self.pitch, p.on_ground);
            self.markChunkDirty();
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.player_look))) {
            const l = try packets.parseLook(frame.body);
            self.setPos(self.pos_x, self.pos_y, self.pos_z, l.yaw, l.pitch, l.on_ground);
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.player_position_and_look))) {
            const p = try packets.parsePositionLook(frame.body);
            self.setPos(p.x, p.y, p.z, p.yaw, p.pitch, p.on_ground);
            self.markChunkDirty();
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.client_settings))) {
            const s = try packets.parseClientSettings(frame.body);
            // clamp: vanilla sends 2..16, server max enforced at use site
            const vd: i8 = @max(1, @min(16, s.view_distance));
            self.client_view = @intCast(vd);
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.client_status))) {
            const st = try packets.parseClientStatus(frame.body);
            if (st == 0) {
                // respawn: back to spawn, full chunk resync; the dead walk
                // back with full health (food/saturation kept as-is).
                self.setPos(
                    @as(f64, @floatFromInt(self.config.spawn_x)) + 0.5,
                    @as(f64, @floatFromInt(self.config.spawn_y)),
                    @as(f64, @floatFromInt(self.config.spawn_z)) + 0.5,
                    self.yaw,
                    self.pitch,
                    false,
                );
                // Falling through the respawn burst is the same hazard as
                // the login fall: hold pure falls until the client syncs.
                self.armLoginGrace();
                self.force_resync = true;
                self.chunks_dirty = true;
                if (self.is_dead) {
                    self.is_dead = false;
                    self.health = 20.0;
                    // Fresh-body reset (vanilla respawn restores food too;
                    // inventory was dropped on death and re-syncs below).
                    self.food = 20;
                    self.saturation = 5.0;
                    self.exhaustion = 0;
                    self.exh_move = 0;
                    self.exh_jump = 0;
                    self.exh_regen = 0;
                    self.food_timer = 0;
                    self.air = 300;
                    self.fire_ticks = 0;
                    self.sprinting = false;
                    self.fall_acc = 0;
                    self.pending_fall = null;
                    var hb: [32]u8 = undefined;
                    try self.queueRaw(try packets.frameUpdateHealth(self.health, self.food, self.saturation, &hb));
                    // Dropped inventory: full re-sync (login does the same).
                    self.sendWindow();
                    self.sendSlot(-1);
                }
            }
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.player_digging))) {
            const d = try packets.parseDigging(frame.body);
            return self.onDig(d.status, d.x, d.y, d.z);
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.player_block_placement))) {
            const p = try packets.parsePlacement(frame.body);
            return self.onPlace(p.x, p.y, p.z, p.direction, @bitCast(p.cursor_y));
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.held_item_change))) {
            const slot = try packets.parseHeldSlot(frame.body);
            if (slot >= 0 and slot <= 8) self.selected = @intCast(slot);
            self.eating = null; // switching held item aborts eating
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.animation))) {
            const a = try packets.parseArmAnimation(frame.body);
            if (a.entity_id == self.eid) return .{ .arm_swing = a.animation };
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.entity_action))) {
            const a = try packets.parseEntityAction(frame.body);
            if (a.entity_id == self.eid) {
                if (a.action == 4) self.sprinting = true else if (a.action == 5) self.sprinting = false;
                // Sneak-start forces walk: a stale sprint flag (missed
                // stop-sprint) would otherwise price every later hop at
                // the 0.8 sprint rate instead of 0.2. Harmless when the
                // client already sent action 5 (already false); the
                // client's per-tick sprint recompute re-sends action 4
                // while Ctrl stays held, so no legit sprint is lost.
                if (a.action == 1) {
                    self.sneaking = true;
                    self.sprinting = false;
                } else if (a.action == 2) self.sneaking = false;
            }
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.creative_inventory_action))) {
            const c = try packets.parseCreativeSlot(frame.body);
            // Vanilla only processes these in creative; in survival the
            // client never sends them, so a stale/replayed 0x10 must not
            // mutate (or resurrect) the survival inventory.
            if (!self.config.gamemode.isCreative()) {
                if (c.slot >= 1 and c.slot < item_mod.inv_size) self.sendSlot(c.slot);
                return .none;
            }
            // Vanilla rejects the output slot (slot 0); grid edits recompute.
            if (c.slot >= 1 and c.slot < item_mod.inv_size) {
                const idx: usize = @intCast(c.slot);
                item_mod.freeStack(self.allocator, &self.inv[idx]);
                self.inv[idx] = try item_mod.cloneStack(self.allocator, c.item);
                if (idx >= 1 and idx <= 4) {
                    self.refreshCrafting();
                    self.sendSlot(0);
                }
            }
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.chat_message))) {
            const text = try packets.parseChat(frame.body);
            const now = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
            if (self.last_chat_ms) |last| {
                if (now - last < self.config.chat_window_ms) {
                    // Same-window repeat: tolerate stall-bunched pairs, kick
                    // sustained floods (vanilla uses a threshold counter too).
                    self.chat_burst += 1;
                    if (self.chat_burst > self.config.chat_burst) {
                        return try self.disconnect("{\"text\":\"Kicked for spamming\"}");
                    }
                } else self.chat_burst = 0;
            }
            // Commands ride the chat packet (vanilla behavior): "/" prefix
            // routes to server.handleCommand instead of broadcast. Raw bytes
            // go in chat_buf (not JSON); length cap is parseChat's own.
            if (text.len > 0 and text[0] == '/') {
                if (text.len > self.chat_buf.len) return .none;
                @memcpy(self.chat_buf[0..text.len], text);
                self.last_chat_ms = now;
                return .{ .command = .{ .json_len = text.len } };
            }
            const json = packets.formatChatJson(self.username[0..self.username_len], text, &self.chat_buf) catch {
                return .none; // invalid/overlong: drop, don't broadcast, don't kick
            };
            self.last_chat_ms = now;
            return .{ .chat = .{ .json_len = json.len } };
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.tab_complete))) {
            const text = try packets.parseTabComplete(frame.body);
            // Bound the request (vanilla allows 32767 chars; completion only
            // needs the tail — drop absurd inputs instead of truncating).
            if (text.len > self.tab_buf.len) return .none;
            @memcpy(self.tab_buf[0..text.len], text);
            return .{ .tab_complete = .{ .json_len = text.len } };
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.use_entity))) {
            const u = try packets.parseUseEntity(frame.body);
            return self.onUseEntity(u.target, u.mouse);
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.click_window))) {
            const u = try packets.parseClickWindow(frame.body);
            // Window 4 clicks resolve on the serve thread (bookshelf recount
            // needs the world); window 2 the same. Both share the click
            // validation shape, but map to distinct actions.
            if (u.window == 4) {
                if (try self.onClickWindowEnchant(u.window, u.slot, u.button, u.action, u.mode)) |ec| {
                    return .{ .enchant_click = ec };
                }
                return .none;
            }
            if (u.window == 5 or u.window == 6) {
                if (try self.onClickWindowChest(u.window, u.slot, u.button, u.action, u.mode)) |cc| {
                    return .{ .chest_click = cc };
                }
                return .none;
            }
            if (u.window == 7) {
                if (try self.onClickWindowBrew(u.window, u.slot, u.button, u.action, u.mode)) |bc| {
                    return .{ .brew_click = bc };
                }
                return .none;
            }
            if (try self.onClickWindow(u.window, u.slot, u.button, u.action, u.mode)) |fc| {
                return .{ .furnace_click = fc };
            }
            return .none;
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.enchant_item))) {
            if (self.is_dead) return .none;
            const e = packets.parseEnchantItem(frame.body) catch return .none;
            return .{ .enchant = .{ .window = e.window, .slot = e.slot } };
        }
        if (frame.id == @as(i32, @intFromEnum(ids.PlayServer.close_window))) {
            const w = try packets.parseCloseWindow(frame.body);
            if (self.open_win) |ow| {
                if (w == ow.id and ow.id == 1) return .{ .table_close = .{ .window = 1, .stacks = self.takeTableGrid() } };
                if (w == ow.id and ow.id == 2) {
                    self.open_win = null;
                    self.resetClickSeq(2);
                    return .{ .table_close = .{ .window = 2, .stacks = [_]?item_mod.Stack{null} ** 9 } };
                }
                if (w == ow.id and ow.id == 7) {
                    // Brewing stand: contents persist server-side (never
                    // dropped on close) — clear + reset like the furnace.
                    self.open_win = null;
                    self.resetClickSeq(7);
                    return .{ .table_close = .{ .window = 7, .stacks = [_]?item_mod.Stack{null} ** 9 } };
                }
                if (w == ow.id and ow.id == 3) {
                    // Ender chest: contents persist per player (never
                    // dropped). Report the cell pos (serve plays the lid
                    // sound at the chest + lid event on last close).
                    const cx = ow.x;
                    const cy = ow.y;
                    const cz = ow.z;
                    self.open_win = null;
                    self.resetClickSeq(3);
                    return .{ .ender_close = .{ .x = cx, .y = cy, .z = cz } };
                }
                if (w == ow.id and ow.id == 4) {
                    const owned = self.takeEnchantItem();
                    var stacks = [_]?item_mod.Stack{null} ** 9;
                    stacks[0] = owned;
                    return .{ .table_close = .{ .window = 4, .stacks = stacks } };
                }
                if (w == ow.id and (ow.id == 5 or ow.id == 6)) {
                    // Chest: contents persist server-side (never dropped).
                    // Clear + report the cell pos (serve plays the lid
                    // sound when the last viewer leaves).
                    const cx = ow.x;
                    const cy = ow.y;
                    const cz = ow.z;
                    const wid = ow.id;
                    self.open_win = null;
                    self.resetClickSeq(wid);
                    return .{ .chest_close = .{ .window = wid, .x = cx, .y = cy, .z = cz } };
                }
            }
            return .none;
        }
        // P-next: actions.
        return .none;
    }

    /// Serverbound 0x02: mouse 0 = interact, 1 = attack, 2 = interact-at.
    /// Interact has no target system yet (no riding/leashing) — dropped.
    /// Attack validates the target isn't self and packs an event; the tick
    /// thread resolves it against mobs + players (tick-owned entity state).
    fn onUseEntity(self: *Conn, target: i32, mouse: i8) Action {
        if (self.is_dead) return .none;
        if (mouse != 1) return .none; // interact / interact-at: P-next
        if (target == self.eid) return .none;
        self.eating = null; // attacking aborts eating
        const held = self.inv[36 + self.selected] orelse null;
        const dmg = if (held) |h| profile.game.item_data.meleeDamage(h.id) else 1.0;
        return .{ .attack = .{ .target_eid = target, .dmg = dmg, .ax = self.pos_x, .ay = self.pos_y, .az = self.pos_z } };
    }

    /// Reach check from the profile eye point to the block center.
    fn inReach(self: *const Conn, x: i32, y: u8, z: i32) bool {
        const r = profile.rules.interaction;
        return interaction_mod.inReach(
            self.pos_x,
            self.pos_y + r.eye_height,
            self.pos_z,
            x,
            y,
            z,
            r.reach,
        );
    }

    /// Send one Set Slot (0x2F) update. Heap frame (NBT can be large);
    /// failures drop the update (client keeps its prediction; the next
    /// action-number mismatch triggers a full resync).
    fn sendSlot(self: *Conn, slot: i16) void {
        // Vanilla cursor convention: window -1 + slot -1 (window 0/slot -1
        // hits Container.getSlot(-1) -> AIOOBE and crashes the client).
        const window: i8 = if (slot < 0) -1 else 0;
        const f = packets.frameSetSlotAlloc(self.allocator, window, slot, if (slot < 0) self.cursor else self.inv[@as(usize, @intCast(slot))]) catch return;
        defer self.allocator.free(f);
        self.queueRaw(f) catch {};
    }

    /// Full window refresh after desync (action-number mismatch). Includes
    /// the cursor: without it the client keeps a stale held stack (ghost
    /// item) while the server sees empty, and the next click duplicates
    /// then vanishes.
    fn sendWindow(self: *Conn) void {
        const f = packets.frameWindowItemsAlloc(self.allocator, 0, &self.inv) catch return;
        defer self.allocator.free(f);
        self.queueRaw(f) catch {};
        self.sendCursor();
    }

    /// Validate one window's click-action number (see click_seq). False =
    /// desynced/replayed client: caller refreshes that window, click
    /// ignored. First click seeds the expectation; later clicks must
    /// increment (wrapping, like the client's short counter).
    fn checkClickSeq(self: *Conn, window: usize, action: i16) bool {
        if (!self.click_seen[window]) {
            self.click_seen[window] = true;
        } else if (action != self.click_seq[window]) {
            return false;
        }
        self.click_seq[window] = action +% 1;
        return true;
    }

    /// Forget one window's click-action expectation. Call on every window
    /// open AND close: the client's action counter restarts with each
    /// container, so a stale expectation would false-reject the new
    /// window's clicks (each rejection echoes the old state, which is the
    /// "pick up snaps back" desync). Window 0 never resets — the inventory
    /// container persists for the whole session. Also drops any drag in
    /// that window (vanilla cancels paint on container change).
    pub fn resetClickSeq(self: *Conn, window: usize) void {
        self.click_seen[window] = false;
        self.click_seq[window] = 0;
        if (self.drag.win >= 0 and @as(usize, @intCast(self.drag.win)) == window) self.drag.reset();
    }

    /// Serverbound 0x0E click window. Brewing stand (window 7, slots 0-3
    /// brew + 4-39 player alias inv 9-44). Validation shape mirrors the
    /// furnace arm; resolution happens on the serve thread.
    fn onClickWindowBrew(self: *Conn, window: i8, slot: i16, button: i8, action: i16, mode: i8) !?BrewClick {
        if (self.is_dead) return null;
        _ = window;
        if (self.open_win == null or self.open_win.?.id != 7) {
            self.sendWindow();
            return null;
        }
        if (!self.checkClickSeq(7, action)) {
            self.drag.reset();
            self.sendWindow();
            return null;
        }
        // Mode 5 passes through (incl. slot -999 start/end); the serve
        // thread owns brew drag state on the shared conn fields.
        if (mode == 5) return BrewClick{ .slot = slot, .button = button, .action = action, .mode = mode };
        self.cancelDrag();
        if (slot == -999 or slot < 0 or slot > 39) return null;
        return BrewClick{ .slot = slot, .button = button, .action = action, .mode = mode };
    }

    /// Serverbound 0x0E click window. Window 0 = player inventory (2x2 grid
    /// live in slots 0-4); window 1 = open crafting table. Modes 3/4/6
    /// (creative pick, drop, collect) are no-ops: drop/collect need item
    /// entities (0x15 Spawn Object, follow-up), so nothing happens rather
    /// than deleting or duplicating the player's items. Mode 5 is the
    /// drag-spread (paint) gesture, implemented per window below.
    fn onClickWindow(self: *Conn, window: i8, slot: i16, button: i8, action: i16, mode: i8) !?FurnaceClick {
        if (self.is_dead) return null;
        if (window == 1) {
            if (self.open_win == null) {
                self.sendWindow();
                return null;
            }
            // Click validation shared across windows (desync -> refresh).
            if (!self.checkClickSeq(1, action)) {
                self.drag.reset();
                self.queueTableWindow();
                self.sendCursor();
                return null;
            }
            if (mode == 5) {
                try self.clickDragWin(1, slot, button);
                return null;
            }
            self.cancelDrag();
            if (slot == -999) return null;
            try self.onClickTable(slot, button, action, mode);
            return null;
        }
        if (window == 2) {
            if (self.open_win == null or self.open_win.?.id != 2) {
                self.sendWindow();
                return null;
            }
            if (!self.checkClickSeq(2, action)) {
                self.drag.reset();
                self.sendWindow();
                return null;
            }
            // Mode 5 passes through (incl. slot -999 start/end); the serve
            // thread owns furnace drag state on the shared conn fields.
            if (mode == 5) return FurnaceClick{ .slot = slot, .button = button, .action = action, .mode = mode };
            self.cancelDrag();
            if (slot == -999 or slot < 0 or slot > 38) return null;
            return FurnaceClick{ .slot = slot, .button = button, .action = action, .mode = mode };
        }
        if (window == 3) {
            // Ender chest resolves in-conn (contents are per-conn state,
            // like the table grid — no world on the click path).
            if (self.open_win == null or self.open_win.?.id != 3) {
                self.sendWindow();
                return null;
            }
            if (!self.checkClickSeq(3, action)) {
                self.drag.reset();
                self.queueEnderWindow();
                self.sendCursor();
                return null;
            }
            if (mode == 5) {
                try self.clickDragWin(3, slot, button);
                return null;
            }
            self.cancelDrag();
            if (slot == -999) return null;
            try self.onClickEnder(slot, button, action, mode);
            return null;
        }
        if (window != 0) return null;
        if (slot < -999 or slot > 44) return null;
        // First click seeds the expectation; later clicks must increment.
        // Mismatch = desynced/replayed client: refresh, ignore the click.
        if (!self.checkClickSeq(0, action)) {
            self.drag.reset(); // stale paint state dies with the desync
            self.sendWindow();
            self.sendCursor();
            return null;
        }
        // Mode 5 drag-spread (slots are validated per add/end inside).
        if (mode == 5) {
            try self.clickDragWin(0, slot, button);
            return null;
        }
        // Any other click cancels a paint in progress (vanilla drops it);
        // the click itself is processed normally below.
        self.cancelDrag();
        if (slot == -999) return null; // outside click: drop path needs entities
        const s: usize = @intCast(slot);
        if (s == 0) {
            // Crafting result slot (2x2).
            if (mode == 0) {
                _ = try self.takeResult(0, self.inv[1..5], &self.inv[0], false);
                return null;
            }
            if (mode == 1) {
                try self.craftAll(self.inv[1..5], &self.inv[0], false);
                return null;
            }
            return null; // number-key on the result: no-op
        }
        switch (mode) {
            0 => {
                if (button != 0 and button != 1) return null;
                if (s >= 5 and s <= 8) {
                    // Armor slots only accept the matching armor piece
                    // (vanilla SlotArmor validity); taking is always fine.
                    if (self.cursor) |cur| {
                        const want = profile.game.item_data.armorSlot(cur.id) orelse {
                            self.sendSlot(@intCast(s));
                            self.sendCursor();
                            return null;
                        };
                        if (5 + @as(usize, want) != s) {
                            self.sendSlot(@intCast(s));
                            self.sendCursor();
                            return null;
                        }
                    }
                }
                if (!(try self.clickPickupImplCell(&self.inv[s], button))) {
                    // No-op (empty-empty) or full-merge: echo the current
                    // slot + cursor so a predicting client snaps back.
                    self.sendSlot(@intCast(s));
                    self.sendCursor();
                    return null;
                }
                self.sendSlot(@intCast(s));
                self.sendCursor();
                if (s >= 1 and s <= 4) {
                    self.refreshCrafting();
                    self.sendSlot(0);
                }
            },
            1 => {
                self.clickQuickMove(s, button);
                self.refreshCrafting();
                self.sendSlot(0);
            },
            2 => self.clickNumberKey(s, button),
            else => {},
        }
        return null;
    }

    /// Serverbound 0x0E validation for windows 5/6 (single/double chest).
    /// Chest rows are server-owned (multi-viewer), so validated clicks
    /// return an event instead of mutating here. Mirrors the window-2
    /// gate: desync -> full refresh, never a kick. Bounds follow the
    /// open size (single 0-62, double 0-89); the serve thread re-checks.
    fn onClickWindowChest(self: *Conn, window: i8, slot: i16, button: i8, action: i16, mode: i8) !?ChestClick {
        if (self.is_dead) return null;
        if (window != 5 and window != 6) return null;
        const w: usize = @intCast(window);
        const wu: u8 = @intCast(window);
        if (self.open_win == null or self.open_win.?.id != wu) {
            self.sendWindow();
            return null;
        }
        if (!self.checkClickSeq(w, action)) {
            self.sendWindow();
            return null;
        }
        const hi: i16 = if (window == 5) 62 else 89;
        // Drag-spread start/end legitimately use slot -999 (mode 5 only);
        // everything else needs a real cell in range.
        if (slot == -999) {
            if (mode != 5) return null;
        } else if (slot < 0 or slot > hi) return null;
        return ChestClick{ .slot = slot, .button = button, .action = action, .mode = mode };
    }

    /// Mode 0: left (all) / right (one) pickup, place, merge, swap.
    /// cursor == null means empty-handed. Merge prefers stacking; when the
    /// stacks can't merge the two sides swap (both buttons).
    fn clickPickup(self: *Conn, s: usize, button: i8) !void {
        if (button != 0 and button != 1) return;
        if (!(try self.clickPickupImplCell(&self.inv[s], button))) return;
        self.sendSlot(@intCast(s));
        self.sendCursor();
    }

    /// Returns true when anything moved (caller syncs slot + cursor then).
    /// Operates on any resolved cell (window-0 inv or table slot).
    pub fn clickPickupImplCell(self: *Conn, cell: *?item_mod.Stack, button: i8) !bool {
        return container_mod.pickup(self.allocator, cell, &self.cursor, button);
    }

    /// Mode 1: shift-click moves the slot stack into the opposite region
    /// (main 9..35 <-> hotbar 36..44), merging first then filling the first
    /// empty. Shift-clicked armor goes to its armor slot instead (vanilla
    /// transferStack). Crafting/armor slots (0..8) are sources only.
    /// Cursor untouched. Ends with a full refresh (many slots can change
    /// at once).
    fn clickQuickMove(self: *Conn, s: usize, button: i8) void {
        if (button != 0 and button != 1) return;
        if (self.inv[s] == null) return;
        if (s >= 9) {
            if (self.inv[s]) |st| {
                if (profile.game.item_data.armorSlot(st.id)) |at| {
                    const dst: usize = 5 + at;
                    if (container_mod.quickMove(self.allocator, &self.inv[s], &self.inv, dst, dst, s, false)) {
                        self.sendWindow();
                    }
                    return;
                }
            }
        }
        const in_hotbar = s >= 36;
        const dst_lo: usize = if (in_hotbar) 9 else 36;
        const dst_hi: usize = if (in_hotbar) 35 else 44;
        // Vanilla mergeItemStack direction: hotbar->main scans forward from
        // 9; main->hotbar scans backward from 44 (hotbar fills at the END).
        if (container_mod.quickMove(self.allocator, &self.inv[s], &self.inv, dst_lo, dst_hi, s, !in_hotbar)) {
            self.sendWindow();
        }
    }

    /// Mode-5 drag-spread entry for conn-local windows (0 = player,
    /// 1 = table, 3 = ender). Start requires slot -999 + non-empty cursor;
    /// adds record validated slots; end distributes the cursor over the
    /// accumulated set (vanilla paint semantics) and full-resyncs.
    fn clickDragWin(self: *Conn, window: i8, slot: i16, button: i8) !void {
        const is_start = button == 0 or button == 4;
        const is_add = button == 1 or button == 5;
        if (!is_start and !is_add and button != 2 and button != 6) {
            self.cancelDrag();
            self.resyncWindow(window);
            return;
        }
        if (is_start) {
            self.drag.reset();
            if (slot != -999 or self.cursor == null) return;
            self.drag.begin(window, button == 4);
            return;
        }
        if (!self.drag.active or self.drag.win != window) {
            self.cancelDrag();
            self.resyncWindow(window);
            self.sendCursor();
            return;
        }
        if (is_add) {
            if (slot < 0) return;
            const s: usize = @intCast(slot);
            if (!self.dragSlotOk(window, s)) return;
            _ = self.drag.add(window, s);
            return;
        }
        // End: resolve every dragged slot against CURRENT state, spread,
        // then full-resync window + cursor (vanilla commits on release).
        const is_right = self.drag.right;
        var buf: [90]*?item_mod.Stack = undefined;
        const cells = self.dragCells(window, &buf);
        _ = container_mod.dragDistribute(self.allocator, &self.cursor, cells, is_right);
        self.drag.reset();
        self.refreshDragWindow(window);
        self.sendCursor();
    }

    /// Cancel an in-flight drag, snapping the client back if it had painted
    /// anything (the END always resyncs, so only mid-drag cancels need one).
    fn cancelDrag(self: *Conn) void {
        if (!self.drag.active) return;
        const w = self.drag.win;
        self.drag.reset();
        self.resyncWindow(w);
        self.sendCursor();
    }

    /// Full window + cursor resync for drag cancel paths.
    fn resyncWindow(self: *Conn, window: i8) void {
        switch (window) {
            0 => {
                self.refreshCrafting();
                self.sendWindow();
            },
            1 => {
                self.refreshTable();
                self.queueTableWindow();
            },
            3 => self.queueEnderWindow(),
            else => {},
        }
    }

    /// Refresh the window after a drag END (same shape as cancel resync).
    fn refreshDragWindow(self: *Conn, window: i8) void {
        self.resyncWindow(window);
    }

    /// Drag slot validity for conn-local windows at END/ADD time. Result
    /// slot (win0: 0, win1: 0) never accepts paint; armor slots only take
    /// the matching piece; everything else takes mergeable-or-empty.
    fn dragSlotOk(self: *Conn, window: i8, s: usize) bool {
        const cur = self.cursor orelse return false;
        switch (window) {
            0 => {
                if (s > 44) return false;
                if (s == 0) return false;
                if (s >= 5 and s <= 8) {
                    const want = profile.game.item_data.armorSlot(cur.id) orelse return false;
                    if (s - 5 != want) return false;
                }
            },
            1 => {
                if (s > 45 or s == 0) return false;
            },
            3 => {
                if (s > 62) return false;
            },
            else => return false,
        }
        const cell = self.cellAt(window, @intCast(s)) orelse return false;
        if (cell.*) |have| {
            return item_mod.canMerge(have, cur);
        }
        return true;
    }

    /// Resolve the accumulated drag slots to live cells (caller: END).
    /// Invalid cells (window changed under us, filled by another viewer,
    /// armor mismatch) are skipped; distribution caps the rest.
    fn dragCells(self: *Conn, window: i8, buf: []*?item_mod.Stack) []const *?item_mod.Stack {
        var n: usize = 0;
        for (self.drag.slots[0..self.drag.n]) |ws| {
            if (n >= buf.len) break;
            // Re-resolve + re-validate against CURRENT state (the window
            // may have changed under the drag; invalid cells are skipped).
            if (!self.dragSlotOk(window, ws)) continue;
            buf[n] = self.cellAt(window, ws).?;
            n += 1;
        }
        return buf[0..n];
    }

    /// Mode 2: number-key swap with hotbar slot `button` (0..8).
    /// Ignored while dragging (cursor non-empty), like vanilla — but the
    /// predicting client still swapped locally, so echo both slots.
    fn clickNumberKey(self: *Conn, s: usize, button: i8) void {
        if (button < 0 or button > 8) return;
        if (self.cursor != null) {
            self.sendSlot(@intCast(s));
            self.sendCursor();
            return;
        }
        const h: usize = 36 + @as(usize, @intCast(button));
        _ = container_mod.swap(&self.inv[s], &self.inv[h]);
        // Echo unconditionally: the predicting client swapped locally even
        // when the server treats it as a no-op (same cell, desync echo).
        self.sendSlot(@intCast(s));
        self.sendSlot(@intCast(h));
    }

    /// Right-click air with armor held: move one piece into its armor
    /// slot (window 5..8), vanilla equip-if-empty — an occupied slot keeps
    /// the held stack (no swap in 1.7). NBT moves with the piece. Queues
    /// both 0x2F updates; caller holds the conn lock (serve thread).
    /// Returns true when anything equipped.
    pub fn applyEquipArmor(self: *Conn) bool {
        if (self.is_dead or self.state != .play) return false;
        const hs: usize = 36 + self.selected;
        const held = self.inv[hs] orelse return false;
        const at = profile.game.item_data.armorSlot(held.id) orelse return false;
        const a: usize = 5 + @as(usize, at);
        if (self.inv[a] != null) return false;
        const nbt = held.nbt; // owned buffer moves with the piece
        if (held.count <= 1) {
            self.inv[hs] = null;
        } else {
            self.inv[hs].?.count -= 1;
        }
        self.inv[a] = .{ .id = held.id, .count = 1, .damage = held.damage, .nbt = nbt };
        self.sendSlot(@intCast(hs));
        self.sendSlot(@intCast(a));
        return true;
    }

    // ---------- crafting (2x2 player grid + window-1 table) ----------

    /// Recompute a crafting result cell from its grid (owned clone; null
    /// when no match). Vanilla refreshes the output on every grid change.
    fn refreshResult(self: *Conn, grid: []?item_mod.Stack, gw: u8, gh: u8, result: *?item_mod.Stack) void {
        const r = recipes_mod.findMatch(grid, gw, gh);
        item_mod.freeStack(self.allocator, result);
        if (r) |o| result.* = item_mod.cloneStack(self.allocator, o) catch null;
    }

    /// Refresh the crafting grid in use (window-1 table vs window-0 2x2).
    fn refreshGrid(self: *Conn, is_table: bool) void {
        if (is_table) self.refreshTable() else self.refreshCrafting();
    }

    /// Recompute the window-0 2x2 result into inv[0] (owned clone; null when
    /// no match). Vanilla refreshes the output on every grid change.
    pub fn refreshCrafting(self: *Conn) void {
        self.refreshResult(self.inv[1..5], 2, 2, &self.inv[0]);
    }

    /// Recompute the window-1 3x3 result into table[0].
    pub fn refreshTable(self: *Conn) void {
        self.refreshResult(self.table[1..10], 3, 3, &self.table[0]);
    }

    /// Resolve a window slot to its storage cell. Window 0: inv directly.
    /// Window 1: 0-9 = table, 10-45 = alias inv[9..44].
    /// Window 3: 0-26 = ender, 27-62 = alias inv[9..44].
    fn cellAt(self: *Conn, window: i8, slot: i16) ?*?item_mod.Stack {
        if (window == 0) {
            if (slot < 0 or slot > 44) return null;
            return &self.inv[@intCast(slot)];
        }
        if (window == 1) {
            if (slot < 0 or slot > item_mod.inv_size) return null;
            const s: usize = @intCast(slot);
            if (s <= 9) return &self.table[s];
            return &self.inv[s - 1];
        }
        if (window == 3) {
            if (slot < 0 or slot > 62) return null;
            const s: usize = @intCast(slot);
            if (s < player_db.ender_size) return &self.ender[s];
            return &self.inv[s - 18];
        }
        return null;
    }

    /// Window-aware Set Slot (0x2F carries the window id).
    fn sendSlotWin(self: *Conn, window: i8, slot: i16) void {
        const st: ?item_mod.Stack = self.slotForWindow(window, slot);
        const f = packets.frameSetSlotAlloc(self.allocator, window, slot, st) catch return;
        defer self.allocator.free(f);
        self.queueRaw(f) catch {};
    }

    /// Resolve the stack a window slot shows (null = empty/invalid).
    /// Window 1: 0-9 = table, 10-45 = alias inv[9..44]; cursor is -1.
    /// Window 3: 0-26 = ender, 27-62 = alias inv[9..44].
    fn slotForWindow(self: *Conn, window: i8, slot: i16) ?item_mod.Stack {
        if (window == 1) {
            if (slot >= 0 and slot <= 9) return self.table[@as(usize, @intCast(slot))];
            if (slot >= 10 and slot <= item_mod.inv_size) return self.inv[@as(usize, @intCast(slot)) - 1];
            return null;
        }
        if (window == 3) {
            if (slot >= 0 and slot < player_db.ender_size) return self.ender[@as(usize, @intCast(slot))];
            if (slot >= 27 and slot <= 62) return self.inv[@as(usize, @intCast(slot)) - 18];
            return null;
        }
        if (slot >= 0 and slot <= 44) return self.inv[@as(usize, @intCast(slot))];
        if (slot == -1) return self.cursor;
        return null;
    }

    /// Take the computed result (left-click on slot 0, empty cursor):
    /// result moves to cursor, one unit consumed per grid cell.
    /// `grid` borrows inv[1..5] or table[1..10]; `is_table` picks refresh.
    fn takeResult(self: *Conn, window: i8, grid: []?item_mod.Stack, result: *?item_mod.Stack, is_table: bool) !bool {
        if (!container_mod.takeResult(self.allocator, &self.cursor, result, grid)) return false;
        for (grid, 0..) |_, i| self.sendSlotWin(window, @intCast(1 + i));
        self.refreshGrid(is_table);
        self.sendSlotWin(window, 0);
        self.sendSlotWin(-1, -1); // cursor lives on window -1 (vanilla rule)
        return true;
    }

    /// Shift-click on a result slot: craft repeatedly into the player
    /// inventory (window-0 slots 9..44) until no match or no fit.
    fn craftAll(self: *Conn, grid: []?item_mod.Stack, result: *?item_mod.Stack, is_table: bool) !void {
        var made = false;
        while (true) {
            self.refreshGrid(is_table);
            const res = result.* orelse break;
            if (!(try container_mod.insertWhole(self.allocator, &self.inv, 9, 44, res))) break;
            container_mod.consumeGrid(self.allocator, grid);
            made = true;
        }
        if (!made) return;
        self.refreshGrid(is_table);
        // many slots may have changed: full refresh of the window.
        if (is_table) {
            self.queueTableWindow();
        } else {
            self.sendWindow();
        }
    }

    /// Assemble + queue a full Window Items 0x30 for the open table window
    /// (slots 0-9 table, 10-45 alias inv 9-44).
    fn queueTableWindow(self: *Conn) void {
        var all: [46]?item_mod.Stack = [_]?item_mod.Stack{null} ** 46;
        for (0..10) |i| all[i] = self.table[i];
        for (item_mod.main_lo..item_mod.inv_size) |i| all[i + 1] = self.inv[i];
        const f = packets.frameWindowItemsAlloc(self.allocator, 1, &all) catch return;
        defer self.allocator.free(f);
        self.queueRaw(f) catch {};
    }

    /// Open the crafting-table UI (window id 1, type 1, 9 grid slots).
    pub fn openTableUI(self: *Conn, x: i32, y: u8, z: i32) void {
        self.open_win = .{ .id = 1, .x = x, .y = y, .z = z };
        self.resetClickSeq(1); // fresh client container: action numbers restart
        for (&self.table) |*s| item_mod.freeStack(self.allocator, s);
        var ob: [128]u8 = undefined;
        if (packets.frameOpenWindow(1, 1, "container.crafting", 9, false, &ob)) |f| {
            self.queueRaw(f) catch {};
        } else |_| {}
        self.queueTableWindow();
    }

    /// Open the ender-chest UI (window id 3, type 0 = chest, 27 slots).
    /// Contents persist per player (never cleared here, unlike the table
    /// grid — opening a second chest shows the same items).
    pub fn openEnderUI(self: *Conn, x: i32, y: u8, z: i32) void {
        self.open_win = .{ .id = 3, .x = x, .y = y, .z = z };
        self.resetClickSeq(3); // fresh client container: action numbers restart
        var ob: [128]u8 = undefined;
        if (packets.frameOpenWindow(3, 0, "container.enderchest", 27, false, &ob)) |f| {
            self.queueRaw(f) catch {};
        } else |_| {}
        self.queueEnderWindow();
    }

    /// Assemble + queue a full Window Items 0x30 for the ender window
    /// (slots 0-26 ender, 27-62 alias inv 9-44 — the vanilla 27-slot
    /// chest container shape).
    pub fn queueEnderWindow(self: *Conn) void {
        var all: [63]?item_mod.Stack = [_]?item_mod.Stack{null} ** 63;
        for (&self.ender, 0..) |st, i| all[i] = st;
        for (item_mod.main_lo..item_mod.inv_size) |i| all[i + 18] = self.inv[i];
        const f = packets.frameWindowItemsAlloc(self.allocator, 3, &all) catch return;
        defer self.allocator.free(f);
        self.queueRaw(f) catch {};
    }

    /// Window-3 click router (slots 0-26 ender, 27-62 player alias).    /// Vanilla transferStack shape: ender <-> player inv, cursor shared.
    fn onClickEnder(self: *Conn, slot: i16, button: i8, action: i16, mode: i8) !void {
        if (slot < 0 or slot > 62) return;
        const s: usize = @intCast(slot);
        switch (mode) {
            0 => {
                if (button != 0 and button != 1) return;
                if (s < player_db.ender_size) {
                    if (!(try self.clickPickupImplCell(&self.ender[s], button))) return;
                } else {
                    const islot: usize = s - 18;
                    if (!(try self.clickPickupImplCell(&self.inv[islot], button))) return;
                }
                self.sendSlotWin(3, slot);
                self.sendSlotWin(-1, -1);
            },
            1 => {
                if (button != 0 and button != 1) return;
                if (s < player_db.ender_size) {
                    // shift ender cell -> player range (merge then empty)
                    if (self.ender[s] == null) return;
                    if (self.quickMoveCellToInv(&self.ender[s])) {
                        self.queueEnderWindow();
                    }
                    return;
                }
                // shift player cell -> ender (merge then first empty)
                const islot: usize = s - 18;
                if (self.inv[islot] == null) return;
                if (container_mod.quickMove(self.allocator, &self.inv[islot], &self.ender, 0, player_db.ender_size - 1, null, false)) {
                    self.queueEnderWindow();
                }
            },
            2 => {
                if (button < 0 or button > 8) return;
                if (self.cursor != null) return;
                // swap resolved cell with hotbar (inv 36+button)
                const h: usize = 36 + @as(usize, @intCast(button));
                if (s < player_db.ender_size) {
                    const t = self.ender[s];
                    self.ender[s] = self.inv[h];
                    self.inv[h] = t;
                    self.queueEnderWindow();
                } else {
                    const islot: usize = s - 18;
                    if (islot == h) return;
                    const t = self.inv[islot];
                    self.inv[islot] = self.inv[h];
                    self.inv[h] = t;
                    self.sendSlotWin(3, slot);
                    self.sendSlotWin(3, @as(i16, @intCast(h + 18)));
                }
            },
            else => {},
        }
        _ = action;
    }

    /// Open the enchanting-table UI (window id 4, type 4, 1 item slot).
    /// 1.7.10 has no lapis slot: the window carries the single item plus
    /// the 36-slot player alias. `seed` is the per-session enchanting seed
    /// (regenerated after each successful enchant); levels start at 0 and
    /// are recomputed by the server once the item lands.
    pub fn openEnchantUI(self: *Conn, x: i32, y: u8, z: i32, seed: i32) void {
        self.open_win = .{ .id = 4, .x = x, .y = y, .z = z };
        self.resetClickSeq(4); // fresh client container: action numbers restart
        item_mod.freeStack(self.allocator, &self.enchant_item);
        self.enchant_item = null;
        self.enchant_levels = .{ 0, 0, 0 };
        self.enchant_seed = seed;
        var ob: [128]u8 = undefined;
        if (packets.frameOpenWindow(4, 4, "container.enchant", 1, false, &ob)) |f| {
            self.queueRaw(f) catch {};
        } else |_| {}
        self.queueEnchantWindow();
        self.sendEnchantLevels();
    }

    /// Assemble + queue a full Window Items 0x30 for the enchanting window
    /// (slot 0 = item, 1-36 alias inv 9-44). Mirrors the furnace 39-slot
    /// shape (3 + 36); enchanting is 1 + 36 = 37.
    pub fn queueEnchantWindow(self: *Conn) void {
        var all: [37]?item_mod.Stack = [_]?item_mod.Stack{null} ** 37;
        all[0] = self.enchant_item;
        for (item_mod.main_lo..item_mod.inv_size) |i| all[i - 8] = self.inv[i];
        const f = packets.frameWindowItemsAlloc(self.allocator, 4, &all) catch return;
        defer self.allocator.free(f);
        self.queueRaw(f) catch {};
    }

    /// Queue the three S31 window-property levels for the open enchant UI.
    pub fn sendEnchantLevels(self: *Conn) void {
        if (self.open_win == null or self.open_win.?.id != 4) return;
        var pb: [16]u8 = undefined;
        for (0..3) |i| {
            const v: i16 = @intCast(@max(0, @min(30, self.enchant_levels[i])));
            if (packets.frameProgressBar(4, @intCast(i), v, &pb)) |f| {
                self.queueRaw(f) catch {};
            } else |_| {}
        }
    }

    /// Move the enchant item out (ownership transfer) + clear levels + close.
    /// Serve loop drops the stack as an entity, like the table grid.
    pub fn takeEnchantItem(self: *Conn) ?item_mod.Stack {
        const out = self.enchant_item;
        self.enchant_item = null;
        self.enchant_levels = .{ 0, 0, 0 };
        self.open_win = null;
        self.resetClickSeq(4); // container gone: drop the stale expectation
        return out;
    }

    /// Serverbound 0x0E validation for window 4. The serve thread owns the
    /// mutation (bookshelf recount needs the world), so validated clicks
    /// return an event instead of mutating here. Mirrors the window-2 gate:
    /// desync -> full refresh, never a kick.
    fn onClickWindowEnchant(self: *Conn, window: i8, slot: i16, button: i8, action: i16, mode: i8) !?EnchantClick {
        if (self.is_dead) return null;
        if (window != 4) return null;
        if (self.open_win == null or self.open_win.?.id != 4) {
            self.sendWindow();
            return null;
        }
        if (!self.checkClickSeq(4, action)) {
            self.queueEnchantWindow();
            self.sendCursor();
            return null;
        }
        // No drag-spread in the enchant window (single-item slot has no
        // vanilla paint semantics): snap back the client's prediction.
        if (mode == 5) {
            self.drag.reset();
            self.queueEnchantWindow();
            self.sendCursor();
            return null;
        }
        if (slot == -999 or slot < 0 or slot > 36) return null;
        return EnchantClick{ .slot = slot, .button = button, .action = action, .mode = mode };
    }

    /// Move the table grid out (ownership transfer), clear table + result +
    /// open state. Serve loop drops the stacks as entities.
    pub fn takeTableGrid(self: *Conn) [9]?item_mod.Stack {
        var out: [9]?item_mod.Stack = [_]?item_mod.Stack{null} ** 9;
        for (1..10) |i| {
            out[i - 1] = self.table[i];
            self.table[i] = null;
        }
        item_mod.freeStack(self.allocator, &self.table[0]);
        self.open_win = null;
        self.resetClickSeq(1); // container gone: drop the stale expectation
        return out;
    }

    /// Window-1 click router (slots 0-9 table, 10-45 player alias).
    fn onClickTable(self: *Conn, slot: i16, button: i8, action: i16, mode: i8) !void {
        if (slot < 0 or slot > item_mod.inv_size) return;
        const s: usize = @intCast(slot);
        switch (mode) {
            0 => {
                if (s == 0) {
                    _ = try self.takeResult(1, self.table[1..10], &self.table[0], true);
                    return;
                }
                if (slot >= 1 and slot <= 9) {
                    if (!(try self.clickPickupImplCell(&self.table[s], button))) return;
                    self.sendSlotWin(1, slot);
                    self.sendSlotWin(-1, -1);
                    self.refreshTable();
                    self.sendSlotWin(1, 0);
                    return;
                }
                // player range 10-45 -> inv 9-44
                const islot: usize = s - 1;
                if (!(try self.clickPickupImplCell(&self.inv[islot], button))) return;
                self.sendSlotWin(1, slot);
                self.sendSlotWin(-1, -1);
            },
            1 => {
                if (s == 0) {
                    try self.craftAll(self.table[1..10], &self.table[0], true);
                    return;
                }
                if (slot >= 1 and slot <= 9) {
                    // shift grid cell -> player range (merge then empty)
                    if (self.table[s] == null) return;
                    if (self.quickMoveCellToInv(&self.table[s])) {
                        self.refreshTable();
                        self.queueTableWindow();
                    }
                    return;
                }
                // player range: hotbar<->main within inv indices
                const islot: usize = s - 1;
                self.clickQuickMove(islot, button);
            },
            2 => {
                if (s == 0) return; // no number-key on the result
                if (button < 0 or button > 8) return;
                if (self.cursor != null) return;
                // swap resolved cell with hotbar (inv 36+button)
                const h: usize = 36 + @as(usize, @intCast(button));
                if (slot >= 1 and slot <= 9) {
                    const t = self.table[s];
                    self.table[s] = self.inv[h];
                    self.inv[h] = t;
                    self.refreshTable();
                    self.queueTableWindow();
                } else {
                    const islot: usize = s - 1;
                    if (islot == h) return;
                    const t = self.inv[islot];
                    self.inv[islot] = self.inv[h];
                    self.inv[h] = t;
                    self.sendSlotWin(1, slot);
                    self.sendSlotWin(1, @as(i16, @intCast(h + 1)));
                }
            },
            else => {},
        }
        _ = action;
    }

    /// Shift-click helper: move a source cell into player range 9..44,
    /// vanilla order (hotbar end backwards: slot 44 fills first).
    /// Returns true when anything moved.
    fn quickMoveCellToInv(self: *Conn, src: *?item_mod.Stack) bool {
        return container_mod.quickMove(self.allocator, src, &self.inv, 9, 44, null, true);
    }

    fn sendCursor(self: *Conn) void {
        const f = packets.frameSetSlotAlloc(self.allocator, -1, -1, self.cursor) catch return;
        defer self.allocator.free(f);
        self.queueRaw(f) catch {};
    }

    pub fn onDig(self: *Conn, status: i8, x: i32, y: u8, z: i32) !Action {
        if (self.is_dead) return .none; // death screen: client sends nothing; drop anything
        // Any mining intent or use-release aborts eating (Q-drop relies on
        // the per-tick slot check instead: dropping another stack keeps a
        // held meal going, like vanilla).
        if (status != 3 and status != 4) self.eating = null;
        // Flood gate: burst-tolerant, disconnect on sustained flood (same
        // kick discipline as placements — rapid digs are a chunk-decode +
        // resync-peek storm either way). Queued directly; onDig stays
        // infallible-shaped (!Action only for the NBT dupe) like onPlace.
        const now_ms = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
        if (!self.dig_gate.allow(now_ms, self.config.dig_window_ms, self.config.dig_burst)) {
            return self.disconnect("{\"text\":\"Kicked for spamming\"}") catch .none;
        }
        // Q-key: 3 = drop whole selected stack, 4 = drop one item.
        // Vanilla `yz.a(boolean)` removes from inventory either way and pops
        // the entity in front of the player with a 40-tick pickup delay.
        if (status == 3 or status == 4) {
            const slot: usize = 36 + self.selected;
            const held = self.inv[slot] orelse return .none;
            if (status == 3) {
                self.inv[slot] = null;
                return .{ .qdrop = .{ .stack = held, .slot = @intCast(slot) } };
            }
            if (held.count <= 1) {
                self.inv[slot] = null;
                return .{ .qdrop = .{ .stack = held, .slot = @intCast(slot) } };
            }
            const one = item_mod.Stack{
                .id = held.id,
                .count = 1,
                .damage = held.damage,
                .nbt = if (held.nbt) |n| try self.allocator.dupe(u8, n) else null,
            };
            self.inv[slot] = .{ .id = held.id, .count = held.count - 1, .damage = held.damage, .nbt = held.nbt };
            return .{ .qdrop = .{ .stack = one, .slot = @intCast(slot) } };
        }
        const creative = self.config.gamemode.isCreative();
        switch (status) {
            0 => { // start
                if (!self.inReach(x, y, z)) {
                    // Creative clients remove the block on click: a refused
                    // START must correct the prediction or it strands a
                    // ghost. Survival clients only start the crack overlay
                    // (nothing removed), so the vanilla bare drop stands.
                    if (creative) return .{ .block_resync = .{ .x = x, .y = y, .z = z } };
                    return .none;
                }
                if (creative) return .{ .block_set = .{ .x = x, .y = y, .z = z, .id = game_ids.air, .meta = 0 } };
                self.pending_dig = .{ .x = x, .y = y, .z = z };
                return .none;
            },
            1 => { // cancel
                // Vanilla reach-gates the abort too (jar `nh`: the 36.0
                // check covers statuses 0, 1 and 2): out of range, the
                // abort neither clears server state nor resyncs.
                if (!self.inReach(x, y, z)) return .none;
                if (self.pending_dig) |p| {
                    if (p.x == x and p.y == y and p.z == z) self.pending_dig = null;
                }
                // Vanilla cancelDestroyingBlock + S23-iff-solid (serve
                // decides): the client may hold a finished-crack removal
                // prediction from a raced FINISH.
                return .{ .block_resync = .{ .x = x, .y = y, .z = z } };
            },
            2 => { // finish
                // Every drop path below carries a resync: the client removes
                // the block when its crack completes (survival) or on click
                // (creative), so a bare drop strands a ghost. The serve
                // thread sends 0x23 iff the cell is still solid — the
                // vanilla tryHarvest-no-break equivalent. (Vanilla
                // bare-drops the reach case; correcting it too is a
                // deliberate hardening: same truth, one extra frame.)
                if (!self.inReach(x, y, z)) {
                    self.pending_dig = null;
                    return .{ .block_resync = .{ .x = x, .y = y, .z = z } };
                }
                if (!creative) {
                    const p = self.pending_dig orelse return .{ .block_resync = .{ .x = x, .y = y, .z = z } }; // no start seen
                    self.pending_dig = null;
                    if (p.x != x or p.y != y or p.z != z) return .{ .block_resync = .{ .x = x, .y = y, .z = z } };
                } else {
                    self.pending_dig = null;
                }
                return .{ .block_set = .{ .x = x, .y = y, .z = z, .id = game_ids.air, .meta = 0 } };
            },
            else => return .none, // unknown dig statuses: ignored (eat-release is status 5, cleared above)
        }
    }

    /// Face offsets: 0=-Y,1=+Y,2=-Z,3=+Z,4=-X,5=+X. 255/-1 = no placement.
    /// Empty-hand clicks still route (interact) so levers/doors/buttons work
    /// bare-handed; held redstone-family items map to their blocks (dust ->
    /// wire, repeater/comparator/door items) with facing-aware metas.
    pub fn onPlace(self: *Conn, x: i32, y: u8, z: i32, direction: i8, cursor_y: u8) Action {
        if (self.is_dead) return .none;
        // Flood gate: burst-tolerant, disconnect on sustained flood (chat
        // discipline). Queued directly — onPlace stays infallible so the
        // hot path and its tests keep a plain Action.
        const now_ms = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
        if (!self.place_gate.allow(now_ms, self.config.place_window_ms, self.config.place_burst)) {
            return self.disconnect("{\"text\":\"Kicked for spamming\"}") catch .none;
        }
        // Any fresh right-click restarts/aborts eating (vanilla uses the
        // new click: a food click re-fires below, anything else drops it).
        self.eating = null;
        if (direction == -1) {
            // Right-click air: armor equips (vanilla ItemArmor use), food
            // or drink starts the 32-tick use (serve resolves + counts).
            const air_held = self.inv[36 + self.selected] orelse return .none;
            if (profile.game.item_data.armorSlot(air_held.id) != null) return .equip_armor;
            // Splash potions throw on right-click (never drink, never place).
            if (profile.game.potion_data.isThrowable(air_held.id, air_held.damage)) {
                return .{ .throw_potion = .{ .slot = 36 + self.selected, .damage = air_held.damage } };
            }
            if (profile.game.item_data.foodFor(air_held.id, air_held.damage) != null or
                profile.game.potion_data.isDrinkable(air_held.id, air_held.damage))
            {
                const ex: i32 = @intFromFloat(@floor(self.pos_x));
                const ey: i32 = @intFromFloat(@max(0, @min(255, self.pos_y)));
                const ez: i32 = @intFromFloat(@floor(self.pos_z));
                return .{ .eat = .{
                    .face = -1,
                    .x = ex,
                    .y = @intCast(ey),
                    .z = ez,
                    .slot = 36 + self.selected,
                    .id = air_held.id,
                    .damage = air_held.damage,
                } };
            }
            return .none;
        }
        if (direction < 0 or direction > 5) {
            // No valid target (bad face): NACK the clicked cell so a
            // predicting client drops whatever it showed there.
            return .{ .place_deny = .{ .x = x, .y = y, .z = z } };
        }
        const target = interaction_mod.targetCell(x, y, z, direction) orelse {
            // Off-world target (y bounds): same NACK on the clicked cell.
            return .{ .place_deny = .{ .x = x, .y = y, .z = z } };
        };
        const tx = target.x;
        const ty = target.y;
        const tz = target.z;
        // Reach is checked on the clicked cell (vanilla distance gate);
        // refusal NACKs the TARGET (that is where the client predicted).
        if (!self.inReach(x, y, z)) return .{ .place_deny = .{ .x = tx, .y = @intCast(ty), .z = tz } };
        const held = self.inv[36 + self.selected];
        const h = held orelse return .{ .interact = .{ .x = tx, .y = @intCast(ty), .z = tz, .id = game_ids.air, .meta = 0, .face = direction } };
        // Splash potions throw even when clicking a block (no UI, no place).
        if (profile.game.potion_data.isThrowable(h.id, h.damage)) {
            return .{ .throw_potion = .{ .slot = 36 + self.selected, .damage = h.damage } };
        }
        // Food/drink on a block: serve tries UI opens first (tables win,
        // like vanilla), otherwise starts the 32-tick use. Never a
        // placement (food/potion ids are not blocks).
        if (profile.game.item_data.foodFor(h.id, h.damage) != null or
            profile.game.potion_data.isDrinkable(h.id, h.damage))
        {
            return .{ .eat = .{ .face = direction, .x = tx, .y = @intCast(ty), .z = tz, .slot = 36 + self.selected, .id = h.id, .damage = h.damage } };
        }
        // Flint-and-steel lights clicked TNT (prime) instead of placing;
        // anything else is a deny (fire placement lives in L1).
        if (h.id == game_ids.flint_and_steel) {
            return .{ .ignite_tnt = .{ .x = x, .y = y, .z = z, .slot = 36 + self.selected, .tx = tx, .ty = @intCast(ty), .tz = tz } };
        }
        // Canonical ids are always < 4096, so the old wire range check is
        // vacuous; unknown wires never reach here (slot parse maps them to empty).
        const bid = profile.game.placeBlockForHeld(h.id) orelse h.id;
        // Vanilla canPlaceBlockOnSide rejects floor/ceiling (sides 0/1)
        // for buttons and trapdoors: no placement, no interact (jar).
        // Refusal still NACKs the target (the client predicted there).
        if (redstone_mod.isButton(&profile.game.blocks, .{ .id = bid, .meta = 0 }) and (direction == 0 or direction == 1)) return .{ .place_deny = .{ .x = tx, .y = @intCast(ty), .z = tz } };
        if (profile.game.blocks.get(bid).orientation == .trapdoor and (direction == 0 or direction == 1)) return .{ .place_deny = .{ .x = tx, .y = @intCast(ty), .z = tz } };
        // Redstone-family placement is facing-aware; everything else keeps
        // the legacy creative damage-nibble behavior. The anvil rule needs
        // the held damage (bits 2-3 carry the damage state), so it rides
        // along (ignored by every other orientation).
        const held_dmg: u4 = @truncate(@as(u16, @bitCast(h.damage)) & 0x0F);
        const m: u4 = redstone_mod.orientOnPlace(
            &profile.game.blocks,
            bid,
            direction,
            self.yaw,
            cursor_y,
            .{ self.pos_x, self.pos_y, self.pos_z },
            tx,
            ty,
            tz,
            held_dmg,
        ) orelse held_dmg;
        return .{ .block_set = .{ .x = tx, .y = @intCast(ty), .z = tz, .id = bid, .meta = m, .face = direction } };
    }

    fn markChunkDirty(self: *Conn) void {
        if (!self.baseline_sent) return;
        const cc = self.playerChunk();
        if (self.sent_center) |c| {
            if (c.cx == cc.cx and c.cz == cc.cz) return;
        }
        self.chunks_dirty = true;
    }

    /// Join packets: abilities, health, XP, own list entry, clock.
    /// Queued after JoinGame/Spawn, before chunk bulks (serveConn orders this).
    // ---- join burst + server tick ----

    pub fn queueJoinPackets(self: *Conn, world_age: i64, time_of_day: i64) !void {
        const creative = self.config.gamemode.isCreative();
        var ab: [32]u8 = undefined;
        try self.queueRaw(try packets.framePlayerAbilities(packets.abilityFlags(creative), 0.05, 0.1, &ab));
        var hb: [32]u8 = undefined;
        try self.queueRaw(try packets.frameUpdateHealth(self.health, self.food, self.saturation, &hb));
        var xb: [32]u8 = undefined;
        try self.queueRaw(try packets.frameSetExperience(0.0, 0, 0, &xb));
        var lb: [64]u8 = undefined;
        try self.queueRaw(try packets.framePlayerListItem(self.username[0..self.username_len], true, self.ping_ms.load(.acquire), &lb));
        var tb: [32]u8 = undefined;
        try self.queueRaw(try packets.frameTimeUpdate(world_age, time_of_day, &tb));
    }

    pub const TickAction = enum { none, timeout };

    /// Food/drink use countdown (vanilla 32 game ticks = 1.6s ItemFood use).
    /// Call once per 1Hz gameplay tick with the shared lock held
    /// (tickViewerOne); all output is queued, never broadcast (burp is
    /// eater-only: broadcasting would nest conn locks — see the lethal-PvP
    /// hang note in server.zig). Game-tick convention matches effects
    /// (20 per tickOnce): 32 finishes on the 2nd tick (~2s, documented
    /// 1Hz granularity). Aborts when dead, when the held stack moved on
    /// (Q-drop, swap, consume elsewhere), or when the item stopped being
    /// food. Finish consumes one (creative keeps; stew/milk leave
    /// bowl/bucket), applies the jar-verified heal/saturation (saturation
    /// capped at food level) + potion effects, then syncs slot + health
    /// + burp.
    pub fn tickEating(self: *Conn) void {
        const e = self.eating orelse return;
        if (self.is_dead or self.dead) {
            self.eating = null;
            return;
        }
        const st = self.inv[e.slot] orelse {
            self.eating = null;
            return;
        };
        if (st.id != e.id or st.damage != e.damage) {
            self.eating = null;
            return;
        }
        const food = profile.game.item_data.foodFor(st.id, st.damage);
        const potion = profile.game.potion_data.isDrinkable(st.id, st.damage);
        if (food == null and !potion) {
            self.eating = null;
            return;
        }
        if (e.ticks > 20) {
            self.eating.?.ticks -= 20;
            return;
        }
        self.eating = null;
        const creative = self.config.gamemode.isCreative();
        if (!creative) {
            if (st.count <= 1) {
                item_mod.freeStack(self.allocator, &self.inv[e.slot]);
                // Last bite swaps to the container: food's own (stew -> bowl,
                // milk -> bucket), potions -> glass bottle.
                const back: ?game_ids.Id = if (food) |f| f.container_back else .glass_bottle;
                if (back) |bid| {
                    self.inv[e.slot] = .{ .id = bid, .count = 1, .damage = 0, .nbt = null };
                } else self.inv[e.slot] = null;
            } else {
                self.inv[e.slot].?.count -= 1;
            }
        }
        var drank_potion = false;
        if (food) |f| {
            // Vanilla FoodStats.addFoodStats: food capped at 20, saturation
            // capped at the new food level.
            const healed: i16 = @min(20, self.food + f.heal);
            self.food = healed;
            self.saturation = @min(@as(f32, @floatFromInt(healed)), self.saturation + @as(f32, @floatFromInt(f.heal)) * f.saturation * 2.0);
            if (f.clears_effects) {
                for (&self.effects) |*fx| {
                    if (fx.*) |old| {
                        var eb: [8]u8 = undefined;
                        const fr = packets.frameRemoveEntityEffect(self.eid, old.id, &eb) catch continue;
                        self.queueRaw(fr) catch {};
                        fx.* = null;
                    }
                }
            } else {
                for (f.effects) |fx| {
                    if (fx.probability_percent < 100) {
                        var rb: [1]u8 = undefined;
                        self.io.random(&rb);
                        if (@as(u16, rb[0]) * 100 >= @as(u16, fx.probability_percent) * 255) continue;
                    }
                    self.giveEffect(fx.id, fx.amplifier, @intCast(fx.seconds * 20));
                }
            }
        } else {
            // Potion drink: no food or saturation; the damage value's
            // effect applies (water/mundane/awkward/thick drink to nothing
            // but still consume + return the bottle).
            drank_potion = true;
            if (profile.game.potion_data.effectFor(st.damage)) |ap| {
                self.giveEffect(ap.a6, ap.amp, @intCast(ap.seconds * 20));
            }
        }
        // Slot sync, then health (food changed it) and the consume sound
        // (eater only): burp for food, drink for potions.
        const sf = packets.frameSetSlotAlloc(self.allocator, 0, @intCast(e.slot), self.inv[e.slot]) catch null;
        if (sf) |f| {
            defer self.allocator.free(f);
            self.queueRaw(f) catch {};
        }
        if (food != null) {
            var hb: [32]u8 = undefined;
            const hf = packets.frameUpdateHealth(self.health, self.food, self.saturation, &hb) catch null;
            if (hf) |f| self.queueRaw(f) catch {};
        }
        var ab: [64]u8 = undefined;
        const aname = if (drank_potion) "random.drink" else "random.burp";
        const af = packets.frameSoundEffect(aname, self.pos_x, self.pos_y + 1.62, self.pos_z, 0.5, 1.0, &ab) catch null;
        if (af) |f| self.queueRaw(f) catch {};
    }

    /// Give (or refresh) a potion effect on this conn; replaces same-id.
    /// Conn-local twin of the server effectGive path (which routes by
    /// player name); used where conn.lock is already held (eat finish).
    fn giveEffect(self: *Conn, id: u8, amp: u8, ticks: i32) void {
        var slot: ?usize = null;
        for (&self.effects, 0..) |*s, i| {
            if (s.*) |fx| {
                if (fx.id == id) {
                    slot = i;
                    break;
                }
            } else if (slot == null) {
                slot = i;
            }
        }
        const si = slot orelse return;
        self.effects[si] = .{ .id = id, .amplifier = amp, .ticks = ticks };
        var eb: [64]u8 = undefined;
        const f = packets.frameEntityEffect(self.eid, id, amp, ticks, &eb) catch return;
        self.queueRaw(f) catch {};
    }

    /// Server-driven per-second work. Call with shared lock held; flush outside.
    /// Time update every 1s, keepalive every 15s, kick 30s after the last echo
    /// (or 30s after the first tick when nothing was ever echoed — the send
    /// timestamp refreshes on every ping, so it must NOT anchor the timeout).
    pub fn queueTick(self: *Conn, now_ms: i64, world_age: i64, time_of_day: i64) !TickAction {
        if (self.state != .play or self.dead) return .none;
        if (self.first_tick_ms < 0) self.first_tick_ms = now_ms;
        const since_echo = if (self.last_echo_ms < 0) now_ms - self.first_tick_ms else now_ms - self.last_echo_ms;
        if (since_echo > keepalive_timeout_ms) {
            var db: [128]u8 = undefined;
            try self.queueRaw(try packets.frameDisconnect("{\"text\":\"Timed out\"}", &db));
            self.dead = true;
            self.close_after_flush = true;
            return .timeout;
        }
        if (now_ms >= self.next_time_ms) {
            var tb: [32]u8 = undefined;
            try self.queueRaw(try packets.frameTimeUpdate(world_age, time_of_day, &tb));
            self.next_time_ms = now_ms + time_interval_ms;
        }
        if (now_ms >= self.next_keepalive_ms) {
            self.keepalive_id += 1;
            var kb: [16]u8 = undefined;
            try self.queueRaw(try packets.frameKeepAlive(self.keepalive_id, &kb));
            self.keepalive_outstanding = true;
            self.keepalive_sent_ms = now_ms;
            self.next_keepalive_ms = now_ms + keepalive_interval_ms;
        }
        return .none;
    }

    /// Arm the login grace at the current (teleported-to) position (login
    /// PosLook / respawn): pure falls below it are held server-side until
    /// the echo, a horizontal move, or the timeout. See setPos.
    pub fn armLoginGrace(self: *Conn) void {
        self.login_x = self.pos_x;
        self.login_y = self.pos_y;
        self.login_z = self.pos_z;
        self.login_fell = false;
        self.login_resynced = false;
        self.login_grace_lapsed = false;
        self.login_grace_ms = std.Io.Timestamp.now(self.io, .awake).toMilliseconds() + 10_000;
    }

    pub fn setPos(self: *Conn, x: f64, y: f64, z: f64, yaw: f32, pitch: f32, on_ground: bool) void {
        // Login grace: hold pure falls below the login teleport until the
        // client proves it is synced (exact PosLook echo), moves
        // horizontally (it is live), or the grace times out. A real client
        // that falls through not-yet-streamed ground during the login burst
        // would otherwise be adopted at the fallen position — joining in
        // the ground despite having left on the ground — and that wrong
        // position persisted on the next save.
        if (self.login_grace_ms != 0 or self.login_grace_lapsed) {
            const now = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
            if (!self.login_grace_lapsed and now > self.login_grace_ms) {
                // Deadline passed: drop the timer but keep holding until
                // the serve loop resolves (see below). Blind adoption here
                // buries players who fell through an undelivered column in
                // terrain that generates solid around the fall.
                self.login_grace_ms = 0;
            }
            if (x == self.login_x and y == self.login_y and z == self.login_z) {
                self.login_grace_ms = 0; // exact teleport echo: synced
                self.login_grace_lapsed = false;
            } else {
                const gdx = x - self.login_x;
                const gdz = z - self.login_z;
                // Quarter-block release radius (squared): login/respawn
                // velocity is ~0, so legit drift is millimeters — but a 1mm
                // threshold disarms on the first drifting packet and then
                // adopts the whole fall through solid ground (fallrepro:
                // 2cm/packet drift buried a login fall to y=66, saved).
                // Intentional moves (walk 4+ blocks/s) clear instantly.
                // Pre-baseline packets never disarm: the client runs physics
                // from world spawn before our login teleport goes out, so its
                // first packets always read "far away" — disarming on them
                // would kill the grace before the burst even arrives, and a
                // post-PosLook hole-fall would adopt instead of holding for
                // the resync snap.
                if (self.baseline_sent and gdx * gdx + gdz * gdz > 0.0625) {
                    self.login_grace_ms = 0; // playing, not falling
                    self.login_grace_lapsed = false;
                } else if (y < self.login_y - 1.0) {
                    // Load-fall held: the client runs physics before its
                    // burst arrives and falls through not-yet-streamed
                    // ground (the sent-set only proves the bytes left, not
                    // that the client processed them). Look still updates
                    // so the client feels live; fall/landing bookkeeping
                    // is skipped — no phantom fall damage, and the fallen
                    // position is never adopted/persisted.
                    self.login_fell = true;
                    // Holding past the deadline (serve loop resolves): mark
                    // the lapse so later packets keep holding instead of
                    // adopting blind (see the timeout branch above).
                    if (self.login_grace_ms == 0) self.login_grace_lapsed = true;
                    self.yaw = yaw;
                    self.pitch = pitch;
                    return;
                }
            }
        }
        // dy is captured before assignment (groundTransition compares
        // against the previous position).
        const dy = y - self.pos_y;
        self.groundTransition(dy, on_ground);
        if (self.state == .play and !self.is_dead and self.baseline_sent) {
            const dx = x - self.pos_x;
            const dz = z - self.pos_z;
            // Movement exhaustion (vanilla `yz.k` rates): horizontal blocks
            // while grounded, sprint 0.1 / walk 0.01. Airborne moves are free
            // (swim 0.015 needs a water check — documented J2 gap).
            if (on_ground and self.on_ground) {
                const hd = movement_mod.horizontalDistance(dx, dz);
                const cost = movement_mod.moveExhaustion(hd, self.sprinting, profile.rules.movement);
                if (cost != 0) {
                    self.addExhaustion(cost);
                    self.exh_move += cost;
                }
            }
            // Position adopts only on a live baseline: pre-burst packets
            // (the client runs physics from world spawn before our login
            // teleport goes out) must not clobber the loaded row — the
            // burst would then center on the wrong chunk, the row area
            // would never send, and the login PosLook would teleport the
            // client to the junk position instead of its save.
            self.pos_x = x;
            self.pos_y = y;
            self.pos_z = z;
            // Hazard-sweep bounding box: every adopted position since the
            // last tick sample (same lock discipline as the fields above).
            if (self.haz_set) {
                self.haz_min_x = @min(self.haz_min_x, x);
                self.haz_min_y = @min(self.haz_min_y, y);
                self.haz_min_z = @min(self.haz_min_z, z);
                self.haz_max_x = @max(self.haz_max_x, x);
                self.haz_max_y = @max(self.haz_max_y, y);
                self.haz_max_z = @max(self.haz_max_z, z);
            }
        }
        self.yaw = yaw;
        self.pitch = pitch;
        self.on_ground = on_ground;
    }

    /// Shared ground-transition logic (landing stashes pending_fall for the
    /// serve thread's water check; server-grounded + client-airborne + rising
    /// is a jump). dy is the vertical delta (0 for flying-only frames).
    fn groundTransition(self: *Conn, dy: f64, on_ground: bool) void {
        if (self.state != .play or self.is_dead or !self.baseline_sent) return;
        const tr = movement_mod.groundTransition(
            self.on_ground,
            on_ground,
            dy,
            self.sprinting,
            self.fall_acc,
            profile.rules.movement,
        );
        // Vanilla `yz.bj()` via the flying handler; step-ups keep the client
        // grounded, so they don't charge.
        if (tr.jump_exhaustion != 0) {
            self.addExhaustion(tr.jump_exhaustion);
            self.exh_jump += tr.jump_exhaustion;
        }
        self.fall_acc = tr.fall_acc;
        if (tr.landing) |dist| {
            self.pending_fall = .{ .dist = dist, .x = self.pos_x, .y = self.pos_y, .z = self.pos_z };
        }
        // Vanilla resets fallDistance while touching fluid (set by the
        // 1Hz tick from the env scan): descents while swimming — dives,
        // wave bobbing at the surface with eyes out — are not falls, so
        // stepping onto a beach can't cash in phantom drop damage.
        if (self.in_fluid) {
            self.fall_acc = 0;
            self.pending_fall = null;
        }
    }

    /// Vanilla `yz.a(float)`: creative (disableDamage) is exempt; cap 40.
    pub fn addExhaustion(self: *Conn, amount: f32) void {
        if (self.config.gamemode.isCreative()) return;
        self.exhaustion = movement_mod.addExhaustion(self.exhaustion, amount, profile.rules.movement);
    }

    /// Chunk coords of the player's current position (for resend-on-move).
    pub fn playerChunk(self: *const Conn) struct { cx: i32, cz: i32 } {
        return .{
            .cx = @as(i32, @intFromFloat(@floor(self.pos_x / 16.0))),
            .cz = @as(i32, @intFromFloat(@floor(self.pos_z / 16.0))),
        };
    }

    /// Tick-aligned flush: returns pending bytes (owned, caller frees/sends).
    pub fn takeOutput(self: *Conn) ![]u8 {
        const out = try self.out.toOwnedSlice(self.allocator);
        self.out.clearRetainingCapacity();
        return out;
    }
};
