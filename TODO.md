# AsteoriteMC TODO — everything left to do

Derived from the implementation plan (pure-Zig 1.7.10/proto-5 server:
io_uring net, Folia-style regions, LSM store, comptime modding API, GPU
offload, SIMD/SIMT, DOD/ECS) plus gaps found while building.

Status snapshot (done, tested, live-verified over TCP):

- [x] VarInt/String/NBT/framing codecs (`src/net/codec.zig`, `src/world/nbt.zig`)
- [x] Handshake/status/login, offline UUID, AES-CFB8 (`src/net/cfb8.zig`), RSA-2048 decrypt + Mojang verify (`src/net/rsa.zig`, `src/net/mojang.zig`), online mode behind `--online`
- [x] Play bootstrap: JoinGame/SpawnPosition/MapChunkBulk/PlayerPosLook (`src/proto/v5/chunks.zig`, `src/sim/view.zig`), `--db` world serving
- [x] Pure-Zig LSM (WAL + SST + `ShardPool`), ZC1 payloads, Anvil→ZC1 import (`tools/anvil_import.zig`)
- [x] H1 worldgen foundation: `java.util.Random` LCG port (JVM-verified goldens incl. `nextInt(bound)` rejection path), fdlibm `log` port (StrictMath bit-exact — Zig/glibc differ by 1 ulp, proven live), Xoroshiro128++ + Mojang seeding, version-agnostic pipeline driver, `worldgen_dump` tool (`src/worldgen/`, `tools/worldgen_dump.zig`)
- [x] Region tick stub, MPSC handoff queue, player position tracking (stance quirk handled)
- [x] ZWM1 world ownership metadata module (`src/world/meta.zig`) with golden/malformed tests and C9 fuzz seeds
- [x] `asteorite --version` and top-level help name/protocol from `profile.meta`
- [x] C2 shared-core extraction: typed `WorldView`, dense `BlockDef` table, profile `RedstoneRules`; redstone/server no longer own 1.7 block behavior/timing data
- [x] C3 shared container primitives: pickup/merge/quick-move/hotbar/result take; furnace and table routing call `sim/container.zig`
- [x] C4 interaction/movement extraction: reach/eye height and exhaustion/fall rules are profile data in `game/rules.zig`
- [x] 515/516 `zig build test` green (1 skipped: pre-existing platform gate; 26/26 steps; `test-exploit` 123/123; C2-C4 add the typed `WorldView`/`BlockDef`/`RedstoneRules` seam, shared container primitives, and profile interaction/movement rules — count the real number when touching this line)
- [x] Phase B transport (Linux io_uring: multishot accept/recv, provided buffers, SEND_ZC, tick-aligned flush, backpressure) + Phase D fast paths (arena, slab, SoA+SIMD, seqlock config, memory budget, `zig build bench`) — measured numbers in the Phase B/D sections

Legend: `[ ]` todo, `[~]` partial. Each phase ends with acceptance criteria.

---

## Phase A — Playable loop (highest priority)

Without these the client connects but the world is dead. All bodies are
1.7.10-specific — verify field order against `minecraft-data/data/pc/1.7/proto.yml`
(the version pinned in research) before implementing each packet.

### A1. Chunk lifecycle on the move ✅ (done, live-verified)

- [x] Per-conn sent-set (`Conn.sent`, `sentKey`), groundUp re-send impossible by construction
- [x] Movement-driven streaming: `syncPlayerChunks` diffs view disk vs sent-set (`x<<32|z`), unloads left columns, bulks entered ones in spiral order; no-op when the center chunk is unchanged
- [x] Hole-heal rescan is capped (16 pool reads/tick, spiral = nearest-first) with outbox backpressure: an uncapped rescan stalled serve threads in store reads while generation was active, delaying disconnect processing (quit→save landed minutes late)
- [x] View distance from Client Settings (`0x15`, clamped 1..16, server max wins at use site)
- [x] Respawn: `0x16` status → Respawn `0x07` + full unload + re-burst + PosLook (`fullResync`); same-dimension only, dimension change is P-next
- [x] Acceptance: live E2E — login `[2,1,5,0x26,8]`, same-chunk move silent, cross-chunk move `[0x21,0x21]`, respawn `[7,0x26,8]`; holes skipped (terrain gen is Phase H)

### A2. Keepalive + time + lists (server-driven ticks) ✅ (done, live-verified)

- [x] Server keepalive ticker (15s) with echo tracking + RTT ping: ticker thread, 1s `tickOnce` cadence; timeout anchored on last *echo* (30s), not last send (a send-anchored timeout is unreachable and was caught live)
- [x] Time Update `0x03` broadcast every second (server-owned atomic age/time)
- [x] Player List `0x38` on join (self) + join/leave broadcast via refcounted, spinlocked connection registry
- [x] Player Abilities `0x39` / Health `0x06` / XP `0x1F` on join (creative flags when gamemode=1)
- [x] Idle/dead handling: timeout queues `0x40 Timed out`, flushes, shuts down the socket to unblock the serve loop
- [x] Acceptance, all live: join burst `[2,1,5,0x39,6,0x1F,0x38,3,0x26,8]`; echo → 2nd keepalive + 25 time updates, no kick; silence → `0x40` + close at ~30s; two clients see each other's join + leave in tab list

### A3. Block interaction ✅ (done, live-verified)

- [x] Block Change `0x23` (1.7 form: X int, Y **ubyte**, Z int, id VarInt + meta u8) broadcast to chunk viewers (sent-set filtered); `0x22` batching + `0x25` crack stages are follow-ups
- [x] Serverbound Digging `0x07` / Placement `0x08` / Held `0x09` / Arm `0x0A` / Creative `0x10` handlers: 6-block reach check, creative instant-break, survival start→finish validation (break-timing anti-cheat is P-next), face-offset placement, per-conn hotbar + selected slot, NBT skipped not preserved (documented)
- [x] ZC1 read-modify-write + LSM persist per edit (`view.applyBlock`; section created on place, no-op break of air, holes ignored; relights the column sky + re-floods chunk block light, updates heights)
- [x] Dig-drop gate was inverted (`!tileDrops`) — survival digging dropped nothing while `/setblock destroy` dropped; fixed + unit-tested (`shouldDropBreak`: survival/adventure drop, creative/gamerule/air don't)
- [x] Block place/break sounds: S29 `dig.<base>` broadcast to viewers in earshot (volume 1.0, pitch 0.8), vanilla step-sound mapping (was: silent digging/placing)
- [x] Lighting (subtractive sky + block-light flood): shared `chunk.lightOpacity`/`emitLight` tables; gen computes column skylight (leaves 15→14, ice 15→12, opaque→0; water stays transparent) + BFS block light (torch 14, lava 15, ...) over the 48-wide decorated view so border light is exact (16-cell margin, min cost 1; the old per-chunk flood clamped at borders and seamed); edits relight (stale nibbles were the "light only fixes on re-enter" bug); horizontal sky spread + cross-chunk bleed on the edit path (border snapshots + neighbor raise/unspread, diagonal raise+lower, forward-then-reverse (removal no longer resurrects); same-chunk engine untouched); bleed-touched neighbors are unload+resent to their trackers (a bare 0x35 left remote viewers stale)
- [x] Cactus contact damage: 1.0 per touching tick (~1/s at 1Hz; vanilla hurt-resistance gates to ~1/0.5s, quantized) via AABB overlap with the vanilla 1/16-inset collision box (was: feet/eyes cell identity only — brushing past never hurt; throttle was 10 ticks = 10s between hits)
- [x] Tab-complete sends the slash (`/gamemode`, not `gamemode` — vanilla S3A; the client replaces the whole word, so bare names ate the `/`)
- [x] Arm-swing `0x0B` relay to viewers; cross-thread path is conn lock → world lock → per-target locks, never nested (documented in `server.zig`)
- [x] Acceptance, all live with keepalive-echoing clients: dig+place visible to second client with exact coords/id, swing relayed; restart serves the edited chunk from WAL replay (section mask `10001`, block `3` at the exact cell)
- [x] Survival inventory: Click Window `0x0E` (pickup/place/merge/swap, shift-click move, number-key swap, action-number desync → full `0x30` resync) + Close Window `0x0D` no-op on the 45-slot player inventory; NBT-preserving storage, per-change `0x2F` updates, dead-player gates; drop/drag/collect are documented no-ops (no item entities yet); live-verified over TCP
- [ ] Follow-ups (not blocking): `0x22` multi-block batching, server-driven `0x25` crack stages, survival break-timing validation, NBT in the placement packet's held-item copy (inventory itself preserves NBT end-to-end — see protocol quirks), non-overworld dimensions

### A4. Entities (minimal) ✅ (done, live-verified)

- [x] Global atomic eid allocator shared by players + mobs (never reused P1)
- [x] Spawn Player `0x0C` (offline UUID *string* + name, fixed-point ints, item 0, living metadata w/ `0x7F` terminator — vanilla crashes without it) and Spawn Mob `0x0F` (pig 90 + metadata); Destroy `0x13` (single-byte count); Teleport `0x18` / Relative Move `0x15` / Look `0x16` / Move+Look `0x17` / Head Look `0x19` / Entity Metadata `0x1C` encoder + decoder tests
- [x] Per-viewer tracked sets + delta planner (vanilla 4-block rule, i8 range forces teleport at exactly ±128 fixed units); move+turn merges into `0x17`; out-of-range or unloaded-chunk → despawn; gone-scan cleans stale tracks
- [x] Patrol-wander mob with deterministic square path; demo pig auto-spawns at spawn+2 when a world is present (20tps smoothing is Phase C work)
- [x] Server tick integrates entities: snapshot players (locked one at a time, no nesting), wander+snapshot mobs under `ent_lock`, reconcile per viewer, broadcast leave doubles as immediate path while tick reap is the safety net
- [x] Acceptance, all live with echoing clients: mutual player spawns with correct offline UUIDs/names/positions, wandering pig visible to both (relmove stream), despawn on leaving view, re-spawn on return, relmove on small moves, destroy on disconnect
- [ ] Follow-ups: 20tps movement smoothing, mob AI beyond patrol, persistence of entities, riding/velocity/projectiles, equipment slots (health/damage/death/respawn + Use Entity reach validation done, live-verified — see protocol quirks validation below)

### A5. Chat + disconnect hygiene ✅ (done, live-verified)- [x] Serverbound Chat `0x01` (plain string) → broadcast Chat Message `0x02` to all play conns including sender (1.7 has no position byte); JSON escaped (`"`, `\`, control chars → `\u00XX`), UTF-8 validated, 100-codepoint cap; invalid/overlong dropped silently (no kick — can't be weaponized)

- [x] Spam throttle: 750ms min gap with burst allowance 3 per window (receive-time gaps false-positive after read stalls — chunk bulks/world_lock/SST stalls bunch legit chats; kick only on sustained flood, vanilla-threshold style), `Kicked for spamming` disconnect on violation (unit + live verified)
- [x] Login timeout: conns stuck in handshake/login dropped after 30s of no progress (login state gets `0x00` disconnect + close; handshaking/status just closed — no disconnect packet exists in those states). Verified live: handshake-only conn gets clean EOF at ~31s
- [x] Disconnect audit: all paths use JSON reason with the right packet — `0x00` in login, `0x40` in play, keepalive timeout `0x40 "Timed out"`, login timeout `0x00`. Ticker shuts the socket down (unblocks serve loops); close happens exactly once in serveConn's defer
- [x] Acceptance, all live with echoing clients: broadcast reaches sender + others with byte-exact vanilla-style JSON (unicode preserved, not `\uXXXX`-escaped); spam → `0x40`; invalid UTF-8 → silent drop; idle handshake → clean drop at 30s
- [x] Join/leave presence (vanilla `multiplayer.player.joined/left`, yellow): `announceJoin` broadcasts `"X joined the game"` to all play conns incl. newcomer + console log; `unregister` broadcasts `"X left the game"` to the rest + console log (leaver already removed, gets nothing). Unit loopback tests assert the 0x02 frames; live E2E asserts newcomer + other-player delivery
- [ ] Follow-ups: per-IP connection rate limiting, RCON (remote) kick, chat reporting/muting hooks for the mod API (F)

### A6. Player persistence + permissions + commands ✅ (done, live-verified)- [x] LSM-backed player rows (`src/sim/players.zig`): `ZPLR` v5 binary (pos/yaw/pitch, spawn, health/food/saturation, 45-slot NBT-verbatim inventory + cursor + selected + gamemode + xp level/total/bar + spawn_forced; v5 slots store canonical `ids.Id`; v3/v4 wire rows decode through `world/import/player.zig`'s legacy map, with v3 xp/spawn_forced defaults; v1/v2 rejected and reimported), key `encodeKey(255, Wyhash(name))` with stored-username mismatch guard; corrupt rows treated as fresh spawn (overwritten on next save)

- [x] Save triggers: disconnect (`unregister`), in-game `/save-all`, console `save-all`, ticker autosave every 300 ticks (WAL-durable; save-all/stop flush SSTs). Load on login (conn.lock held): restores pos/health/inv/cursor/selected/gamemode, skips land-spawn search; dead-at-save normalizes to alive-at-spawn on load
- [x] Login inventory sync: full Window Items `0x30` + cursor Set Slot after chunk burst; PosLook now sends actual player pos (fresh logins land at found spawn via pos sync — burst center + PosLook consistent); login completes on solid ground (radius-2 landing disk sync-filled at join) + 10s login grace (sub-1-block-exact falls held server-side until PosLook echo / horizontal move / timeout, with one PosLook re-snap once the ground column is delivered — joining in the ground from client physics during the burst can no longer be adopted or persisted)
- [x] Permission model (`src/sim/permissions.zig`): op levels 0-4 + per-player node grants/denies persisted in `ops.json` beside the server (vanilla-style), deny-beats-grant-beats-level, `.*` wildcards, console implicitly 4, secure default (no ops → console only). Bans/whitelist likewise live in `banned-players.json`/`banned-ips.json`/`whitelist.json`; `/perm reload` + `/whitelist reload` re-read the files, so hand edits apply live. Player-name matching is case-insensitive throughout (vanilla `UserList` folds: `/op Alice` covers login `alice`, target lookup + `/perm show` too — the "opped but every command unknown" class of bug). Denied and unknown commands share one reply (no oracle); `/help` filters to usable commands; validated names/nodes everywhere
- [x] Session integrity: duplicate-login kick ("You logged in from another location!", vanilla) flushes + shuts the ghost down so it unregisters promptly; per-player save epochs (`bumpSaveEpoch`/`saveEpochCurrent`) drop stale saves on quit/rejoin races and ghost autosaves; name-targeted commands skip kicked/dying conns (first-match `findInSnap` used to route at the ghost — the "gamemode not saved" class of bug)
- [x] Default world folder is `world` (vanilla name; `"db": null` disables persistence)
- [x] Commands: full vanilla 1.7.10 dedicated roster (48 commands in vanilla registration order) + `perm` extension. Spec-driven defs (`src/cmd/spec.zig`): usage strings, argument parsing, and tab-completion all derived from one typed spec per command (comptime-rendered usage; `usage_override` only for the few vanilla texts the generator cannot spell). Jar-verified usage strings/messages/perm levels/aliases (`?`, `w`, `msg`); admin feedback to fellow ops as gray-italic `[Name: msg]`; vanilla tab-complete (`0x14`->`0x3A`: case-insensitive, perm-filtered, aliases, per-command dynamic sets for items/gamerules/mobs/enchants) with non-slash player completion and unknown-command suppression. Systems: name/IP bans + whitelist + login gates (jar-hardcoded screens), 9 gamerules (doDaylightCycle/keepInventory live), weather w/ countdowns + S2B (flag + strengths 7/8, login sync, thunder lightning), difficulty/default-gamemode, XP (vanilla formulas, level-up chime, ZPLR v5), effects (S1D/S1E + ticker expiry), ench NBT (hand-merged list, canApply/cantCombine tables), summon, setblock/testforblock (replace/keep/destroy + drops + S28), testfor (command-block-only), spreadplayers (vanilla iterations + teams), playsound (hearing check), scoreboard (objectives/players/teams/slots + S3B-E), achievements, save-on/off, idle kick, debug, seed, kill, publish (dedicated-fail), netstat. Bootstrap via repeatable `--op <name>`. Operator stdin console unchanged
- [x] Acceptance, live over TCP: permission gating (deny==unknown, grant/deny/wildcard, op/deop + notify); full gameplay loop (gamemode flags, give slots/damage, tp PosLook + chunks, time set/add/day, gamemode persist across restart); restart persistence (pos + staged dirt + perms matrix); inventory E2E still green
- [x] RCON remote console (`src/net/rcon.zig`): vanilla-style Source framing (LE length/id/type + double-NUL), password auth with constant-time compare, fail-closed without `--rcon-password`, 3-strike auth cap, no-auth/oversize/unknown-type → close, single-packet truncated replies. Full console authority (all 14 commands incl. `/stop`, which saves + flushes + exits after the reply flushes). `--rcon-password` (short-password warning) / `--rcon-port` (default 25575); password never logged (localhost/SSH-tunnel posture documented)
- [x] Acceptance, live: RCON auth/id-echo, no-auth close, 3-strike cap, roster/save-all/op/perm/unknown round-trips, oversize/unknown-type close, game conn undisturbed; in-game `/stop` (reply flushes, exit 0) + console `stop` re-verified after the executeCommand refactor
- [x] Playerdata migration tooling: `player_import <player.dat> <db> <name>` (gzip-NBT → ZPLR row, with human-readable summary + warnings) and `player_dump <db> <name>` (row inspection incl. NBT byte counts); `build.zig` gains `player-import` / `player-dump` steps + test targets
- [x] Acceptance: real `player.dat` from the official 1.7.10 server jar (sha256-pinned, checked in as `src/world/import/testdata/vanilla_player.dat` with a provenance README) round-trips through import → ZPLR golden asserts (pos, health, food, gamemode, hotbar stone + NBT-named sword, spawn fallback, zero skipped/dropped slots); save/load + console + inventory + RCON E2Es re-verified green on the final binary

---

## Phase J — Survival loop (playability: mining must pay, hunger must bite)

Without this the server is a creative building + chat room: breaking blocks yields
nothing, nobody starves, nothing hunts you. In dependency order (each slice is
independently live-verifiable):

### J1. Block drops + item entities + pickup [~] (implemented + live-verified; vanilla ground-truth sampling in progress)

- [x] Vanilla drop table (`src/sim/drops.zig`: explicit CFR-verified cases — lapis 4-8 dye/4, redstone 4-5, gravel flint 1/10, leaves sapling 1/20 (jungle 1/40) + apple 1/200 oak/dark-oak, stone→cobble, ore items, clay 4, glowstone 2-4, melon 3-7, double-slab 2, tallgrass/deadbush seeds 1/8, glass/ice/bedrock nothing, meta-preserving default; fortune/silk excluded by design — no enchants yet)
- [x] Spawn Object `0x0E` (type 2, data 1, velocity iff data>0) + full watcher `0x1C` (`[(0:B),(1:S=300),(10:slot)]` per EntityTrackerEntry `my.b` + Entity init CFR) + `0x0D` collect (i32 pair, collected first) framing (roundtrip unit tests; minecraft-data 1.7 + `fw`/`ij` decompiles)
- [x] Item entity sim (server-owned list under ent_lock, cap 256): 10-tick block-drop delay, 40-tick Q-drop delay, 6000-tick despawn, vanilla xk merge (bigger absorbs, max delay, min age), magnet pickup (spawn-visible-first, all-or-nothing grant in vanilla order, Set Slot + Collect + Destroy, tick-local claims, rebroadcast to trackers); serve-thread drops broadcast Spawn Object + metadata immediately to in-range viewers with the chunk loaded (break→visible ~instant, pickup next tick — was up to ~2 ticks to even see the drop, which also stranded drops behind walking players)
- [x] Q-drop (digging status 3 = whole stack, 4 = one item; spawns in front, delay 40; slot refresh; serveConn event whitelist includes `.qdrop`)
- [x] Creative breaks drop nothing; survival start-then-finish dig rolls drops
- [x] Acceptance, live E2E over TCP (`/tmp/opencode/zc_drops_e2e.py`): survival diamond-ore dig → 0x0E + full slot-10 (264,1,0) + collect + single destroy + setslot; creative break dropless; Q-drop entity + slot refresh + self-pickup merge
- [x] Ground truth: drop formulas/ids are CFR 0.152 ports of the official 1.7.10 jar (`amn`/`amz`/`ali`/`alt`+`aml`+`amh`/`anv`/`aly`/`alg`/`ajy`/`anz` + `aji` harvestBlock/dropBlockAsItemWithChance), not re-derivations; `drops.zig` unit tests sweep seeds for bounds (lapis 4-8, redstone 4-5, glow 2-4, melon 3-7) and rates (flint ~10%, sapling ~5%, seeds ~12.5%). Live JVM sampling was abandoned after the harness fought back — but it paid for itself in protocol facts now baked in: 0x1C eid is i32, living metadata carries a string@10, /tp clears the move-confirm flag (exact-echo 0x06 needed), placement uses the server-side selected stack (mismatch → SetSlot correction), harvestBlock breaks mid-hold (collect during hold, not after)
- [ ] Follow-ups: our onPlace trusts the packet item (vanilla checks the hand — Phase P cheat-hardening); Q-drop/throw velocity is zeroed (vanilla scatters with world rand); pickup radius is a static approximation (no per-tick physics at 1Hz)

### J2. Hunger + attrition (health regen, fall/drown/lava damage, starvation) [~] (implemented + live-verified)

- [x] FoodStats port (`hungerTick`: exhaustion>4 drain, regen +1/80t at food>=18 (+3 exh), starvation gates easy>10/normal>1/hard-always, peaceful no-drain; saturation default 5.0 kept)
- [x] Exhaustion sources: attack +0.3 (per landed hit), break +0.025, jump +0.2 / sprint-jump +0.8 (takeoff detect), walk +0.01 / sprint +0.1 per block (0x0B sprint flag); swim 0.015 gap (no water check in packet path)
- [x] Fall: server-side accumulate + landing stash; serve-thread water check (feet block 8/9 cancels); damage ceil(dist-3), survival-only
- [x] Drown (eyes water: -20 air/tick, 2 dmg at -20 then 1/s), lava (4 + fire 300; lenient vs 4/tick vanilla), fire (1/s, water extinguishes), suffocate (eyes opaque: 4/tick; lenient vs 1/tick vanilla) — 1Hz-quantized deviations documented
- [x] Death drops (full inv+cursor as one-entity-per-stack, 10-tick delay), victim row saved on death, respawn full-inv re-sync; combat deaths unified (PvP now respects creative immunity — vanilla-exact, test conns flipped to survival)
- [x] Acceptance, live E2E: fall 6 → 17.0, regen → 20, lethal fall → 0 + 2 drops, respawn → 20 + Window Items, suffocate 4/tick → death + drops + re-pickup path
- [ ] Live gaps (unit-covered): drown/lava/fire timing, starvation TTK, fall-into-water cancel, peaceful; swim exhaustion unimplemented

### J3. Crafting (+ furnace) [x] (J3a containers+crafting + J3b furnace done + live-verified)

- [x] Vanilla recipe table (312 entries, machine-extracted from CFR 0.152 `afh`/`afi`/`afe`/`afj`/`afk`/`afl`/`aev`/`aex`/`aez`/`afd` + `aka.c` dye inversion; aff sort order; id/damage rules: bare-block wildcard, explicit-add exact, shapeless block-inputs damage-0; NBT specials deferred: map extend/clone, book clone, armor dye, fireworks)
- [x] Matcher (`src/sim/recipes.zig`, table `src/game/mc5/recipes_data.zig`): shaped slide+mirror, shapeless multiset, repair (maxDur formula, generated per-item table from minecraft-data names x jar-verified material enums), NBT-copy flag
- [x] 2x2 player grid live in window 0 (result recompute on grid change, take consumes, shift craft-all, 0x10 rejects slot 0)
- [x] Container window 1 (crafting table): right-click opens 0x2D type 1 + full 0x30, sneak bypass places instead, click routing incl. shift/number, 0x0D close drops grid, table-break force-closes viewers + drops + 0x2E
- [x] Acceptance, live E2E: 2x2 planks take, table open, 3x3 pickaxe take, close drops, break-close ack, sneak bypass (fresh-DB runs; note: E2E reruns on a dirty DB can desync — restart server per run)
- [x] J3b furnace (`src/sim/furnace.zig` tick/canSmelt ported from CFR `apg.h/k/j` + `src/sim/smelting.zig` burn/result engine over `src/game/mc5/smelting_data.zig`; 20-tick quanta at 1Hz): window-2 open/click/close routing, lit/unlit 61/62 swaps, per-viewer 0x30 + 0x31 (cook/burn/total) sync, shift/number-key moves, break drops contents + 0x2E, entity leak fixed (removeFurnace wired)
- [x] Acceptance, live E2E vs vanilla 1.7.10 reference (cold-start: ignite 61->62 + fuel-1 + burn/total 1600, cook +20/tick, output at 200, take/park, burnout 62->61 + cook freeze, shift/number moves, break-close + drops; vanilla 0x0E clicked-item = pre-click slot, match = silent accept + client-applies-locally, mismatch = confirm-0 + resync + container blacklist — asteorite validates action-seq instead, compatible with real clients)
- [x] 325/325 `zig build test` green (21/21 steps; was 283/283 — count the real number when touching this line)

### J4. Mobs: spawning + hostiles + drops

- [ ] Spawner by light/position, wander/chase/attack AI, mob drops via J1 pipeline, entity persistence

---

## Phase K — Interactive simulation (redstone, brewing, enchanting, explosives)

All four are greenfield (wire/torches/levers place as dead blocks today; only
the crafting table + furnace open UIs on right-click), but every hook they
need exists: right-click routing (`tryOpenTable`/`tryOpenFurnace`), container
windows (J3b), effect application (`/effect` S1D/S1E + ticker expiry, A6),
enchantment legality tables (`cmd_data.enchantsCombine/enchantApplies`, A6),
item-entity sim + drops pipeline (J1), block-light relight on edit (A3).
Suggested build order: K1 first (scheduler + power query everything else
needs), then K4, then K2/K3 (independent of K1, can interleave).

### K1. Block-tick scheduler + redstone circuits (the foundation) ✅ SHIPPED (jar-verbatim)

- [x] Scheduled-tick queue (vanilla `scheduleBlockUpdate` semantics): per-position dedupe (reschedule replaces), ticker drains with a per-tick budget (anti-lag-machine; the Phase C breaker counts this load per region). Powers repeater delays, button timers. (`sim/redstone.zig` Scheduler: 1024 entries, 500/tick drain)
- [x] Power model, ported instruction-by-instruction from the 1.7.10 server jar (`ana`/`anc`/`aoc`/`alv`/`ajs`/`ajd`/`amu`/`aol`/`akj`/`anf`/`akn`/`anb`/`amz`, `ahb.e/f/g/u/v/w`): weak/strong/indirect/strongest/gettingPowered with vanilla face conventions; wire output connection-gated per `ana.b` (down always, dot wires everywhere, otherwise direction && !perpendiculars); powered cubes do NOT conduct wire power (`getMaxCurrentStrength`-exact, wires dead during calc); torches check ONLY their support (`anc.m`); burnout = 8 ON→OFF flips within 60 ticks, fizz + smoke, no forced recheck.
- [x] Components, all jar-verified: wire (falloff, up/down steps, support = solidTop|glowstone), torch (inverter + burnout, mount = normal-cube or fence/glass/wall/piston, ceiling meta 0), lever (toggle preserves orientation, mount = normal cube below / solid top floor), button (stone 20 / wood 30 ticks, WALL-ONLY placement like vanilla `canPlaceBlockOnSide`, mount = normal cube), pressure plates (stone=mobs, wood=everything, weighted ceil(15*min(n,max)/max) with gold 15 / iron 150, vanilla inset detection box, recheck only when pressed), doors (power-driven via gettingPowered(lower||upper), hand toggle for wood, 2-block halves + hinge bit, iron = redstone-only), trapdoors/gates (hand-only), lamps (`ahb.v` driven), redstone-ore lit/unlit on touch with 30-tick fade (lit emits 9).
- [x] Repeater exact: facing formula `(floor(yaw*4/360+0.5)&3+2)%4`, output/weak/strong gated to facing side {3,4,2,5}, input = indirect(behind)+wire level, side-lock vs perpendicular powered diodes, schedule on mismatch only (delay `M={1,2,3,4}*2`), no-lock/no-stale/no-op skips; right-click cycles delay.
- [x] PISTONS (round 2, jar-verbatim from `app`/`apq`/`apr`): updatePistonState on every neighbor change (extend/retract block events, 2-tick schedule), 5-face weak power check excluding the front, canPush (obsidian / extended pistons / hardness -1 / mobility destroy-without-flag / container blocks), 12-block push limit + 13-cell scan, destroyables drop + end the chain, head block with sticky bit, sticky pull (`canPush(...,false)`), head pops when its base is gone or unextended (`apq` neighbor rule), placement orientation (`getPistonOrientation`: close-player up/down by eye, yaw table 0->2/1->5/2->3/3->4, faces the player), S24 Block Action broadcast drives the vanilla client's own animation (doMove writes are `silent` — no S23 echo that would cancel the moving-block render), `tile.piston.out/in` at volume 0.5. Sim: 5 new piston tests; server glue: 3 LSM tests incl. S24 action list; live E2E (`/tmp/rt/e3_piston.py`): push, head meta, sticky pull, silence, no spurious re-extend while powered (1 action), 88ms extend latency. Server-side moving-block TEs replaced by immediate final blocks (documented divergence: no TE ticker; identical observable outcome).
- [x] Latency round: staged writes for every redstone op (`Staged` overlay: reads memoized, writes coalesced, ONE store write + ONE change per cell — wire decay was ~30 writes x ~7ms store round-trips = the 1-2s lever-off report; now 36-39ms end-to-end, `e1_lever.py`), plate poll spam fix (stored-meta compare, not output level: pressed plates stopped re-clicking + re-notifying every poll), instant plate press on movement (vanilla collision sense; 759ms -> 27ms, releases stay on the 1Hz recheck like vanilla's 20-tick cadence), per-edit budget 512->4096 + wire_check follow-up valve (budget exhaustion mid-decay no longer stalls at intermediate levels).
- [x] Serverbound 0x04/0x06 position: wire order is x, FEET y, stance, z (jar `jf`/`nh` verified; our parser consumed the 2nd double as stance and took the 3rd as feet, so every real client's feet was read as eye height +1.62 — plates never triggered for real players; the old test harness packed the wrong order too, hiding it). Fixed + both unit tests + harness; live-verified plates now press.
- [x] Placement/break S23 echoes to the actor like vanilla (PlayerManager marks every tracker; our placer exclusion let any prediction divergence surface as a "lever rotates on first activation" instead of correcting at placement). Sounds stay excluded for the actor (no double-sound).
- [ ] Follow-ups (explicitly not this slice): comparator LOGIC (placed, inert), note blocks, dispensers/droppers (needs a dispense-behavior table; shooting TNT/arrows ties to K4/J4). Trapdoor/gate support-pop, repeat side-orientation rendering nuances, command-block edits bypassing redstone hooks likewise deferred.
- [x] Acceptance: sim goldens 16/16 (`zig test` on the module: falloff, no-cube-conduction, lever→wire(15,14)→lamp, torch inverter + burnout + support-only + fizz + recovery, button 20/30 with single-step fade, repeater delay/flip/lock, scheduler dedupe, orientation tables, doors/trapdoor/gate/ore, door-from-power, support pops, plates, storm bound); server-glue tests (lever interact through LSM, door halves, tick-driven release); live E2E over TCP (`/tmp/k1_live.py`: lever→wire→lamp on/off, button press+release, repeater power/unpower, torch ignores adjacent wire, clock storm terminates + server alive, plates sense + power). Full-tree re-verify pending (tree red: concurrent Phase B refactor in `server.zig`, missing piece is theirs).
- [x] Bugfix round (user-reported gameplay bugs, all jar-verified, live-verified 33/33 in `/tmp/k1_live.py`): 10Hz redstone thread (sub-second repeater/button timing; plates stay on 1Hz), scheduler persistence row (dim 253, dues re-derived — no more stuck buttons after reboot), lever/button now notify their mount support too (opposite-side torches/components update), trapdoor support table fixed to the jar (`meta0→z+1` etc.) + wall-only + support-pop, door ItemDoor-exact facing `floor((yaw+180)*4/360-0.5)&3` + hinge-bit rule + upper `8|hinge` (doors no longer rotate on open), bucket place maps to water/lava with `liquid.splash` voice, own break/place sounds excluded for the placer (no more double sounds), trapdoor upper-half bit from cursor height, chat spam check allows burst-of-3 (no more false kicks after read stalls). Trapdoor/door/placement checks converted to `/testforblock` ground truth where the placer is excluded from 0x23 echoes by design.

### K2. Brewing + potions ✅ (implemented, golden-tested; live E2E pending)

- [x] Brewing-stand window (type 5) on the J3b pattern: 3 bottle slots + ingredient (1.7.10 has no blaze-powder fuel — time only, 400 ticks, progress on window property 0 via the same `0x31` path as the furnace). (`sim/world/brewing.zig` engine + server `BrewEnt`/window-7 open/click/close/break; `conn` window-7 routing + click-seq; per-tick 40-slot `0x30` + prop-0 sync.)
- [x] Potion item model: vanilla 1.7.10 damage-value table as checked-in data + unit tests (mirrors the `smelting_data` convention); splash bit; display names. (`game/mc5/potion_data.zig`: 8192-base + 16384-splash + 64-extended + 32-tier bits, effect map, corruption map.)
- [x] Brewing chain as data: nether wart → awkward, effect ingredients, glowstone/redstone modifiers, gunpowder → splash, fermented-spider-eye corruption; ingredient consumed, bottles convert in place.
- [x] Drinking: Use-Item path (32-tick consume) → effect via the A6 `/effect` infra + glass bottle back; splash: Spawn Object type 73 (type/data per vanilla EntityPotion — no proto.yml in tree), direct-hit full effect + AoE falloff on impact. (Splash HP/damage is L2-owned; K2 delivery is S1D-only, like drinking.)
- [x] Acceptance, unit goldens (no live client in this session): potion-table goldens for the full chain (awkward→swiftness→extended/tier/splash, corruption set, mundane/thick/weakness, no-op exclusivity); 400-tick engine goldens (invalid resets, in-place convert, partial bottles); drink applies Speed (S1D + 3600 ticks, bottle back, food untouched); splash reconcile goldens (type-73 spawn, arc rel_move, destroy on gone) + falloff goldens. Live E2E (20s brew with progress bar, thrown splash impacting a bot) pending a live client.

### K3. Enchanting table ✅ (implemented, golden-tested; live E2E pending)

- [x] Table window (type 4) on the J3b pattern: item slot only (1.7.10 has no lapis cost), 3 level options; bookshelf counting (15 max, vanilla air-gap rule) gates the 30-level option. (`sim/enchanting.zig` engine + `game/mc5/enchanting_data.zig` profile tables; `conn` window-4 open/click/close + `server` tryOpen/applyClick/applyEnchant; 0x11 parse + 0x2D/0x30/0x31 sync; break/close drops the item.)
- [x] Outcome RNG: vanilla enchantability + weighted-draw algorithm, deterministic under a fixed seed — golden-tested (reuses `cmd_data` max-level/canApply/exclusion tables and the `/enchant` NBT merge; `/enchant` stays as the operator override; table additionally vetoes silk↔fortune per vanilla `canApplyTogether`).
- [x] XP deduction through the existing XP/level infra (A6; full shown-level cost, creative free; reseed after each enchant like vanilla).
- [ ] Follow-up: anvil combine/repair UI (can reuse the J3 repair matcher + XP cost rules).
- [x] Acceptance (unit goldens, no live client in this session): 15-shelf setup offers 30 (seed-0 golden `[8,13,30]`); same seed → same outcome; applied enchants visible in NBT (multi-pick merge, book→enchanted_book); XP levels deducted; insufficient levels resync without enchanting; books keep ≤2 (vanilla single-removal).

### K4. TNT + optimized explosions ✅ (implemented, golden-tested; live E2E pending)

- [x] Primed TNT entity (Spawn Object type 50, S27-tested framer + recorder/loopback paths), 80-tick fuse, gravity/drag on the J1 entity-motion path (20 substeps/tick: 0.04 gravity, 0.98 drag, -0.5 bounce + 0.7 friction, rest on first-solid-top); ignition via K1 redstone power (post-edit neighbor scan primes powered TNT) and flint-and-steel Use-Item action (shared K2 drinking path shape; 64-use wear, creative keeps); fire-spread ignition deferred (no fire-spread sim yet — pinned by `fire never ignites tnt`).
- [x] Explosion core, batched: one 16³-face raycast exposure pass per blast (vanilla attenuation, blast-resistance table as data), per-tick update budget (8 blasts/tick) with a chain queue (no recursion, chained TNT primes with 10+rand(20) fuses so fuses never skip ticks), single collect-then-apply block pass (re-peek guards, unbreakable skipped); drops through the J1 pipeline at the vanilla 1/size chance; entity damage with exposure falloff + knockback (players: EPF-reduced + capped authoritative shove + PosLook; S27 tail velocity zeroed so the client never double-applies); S27 Explosion packet (per-viewer records + zeroed vel) + `random.explode` S29 (volume 4.0, 64-block earshot).
- [x] Chain reactions ride short-fuse entities (never the blast queue); per-region breaker integration is a follow-up (the budget caps tick load; no breaker accounting yet). GPU raycast stays a Phase G1 job — the CPU reference here is the golden baseline.
- [ ] Follow-ups: creeper/ghast-fireball variants on the same core; blast-popped container contents are lost (no window fan-out on blast breaks); mob drops ride J4; live-client feel (fuse flicker is client-side from type 50).
- [x] Acceptance, unit goldens + headless glue (no live client in this session): flat-stone crater golden (seed 42), water-absorbs/bedrock-stops/TNT-chains goldens, damage/exposure formula anchors, 64-blast bounded-chain test; headless LSM tests (redstone lever→wire→prime, full fuse→detonate→crater→drops); conn test (flint routing); S27 layout test. Live E2E (fuse→S27→crater over TCP, 64-TNT chain timing, drops + damage + knockback feel) pending a live client.

## Phase L — Vanilla parity sweep (everything else 1.7.10 does that we don't)

Verified missing by code search (no handler, no packet framer, no sim —
ids/items/recipes alone don't count). Each slice states its dependency;
all acceptance is live E2E over TCP with a real 1.7.10 client plus unit
goldens where the algorithm is deterministic.

### L1. Block simulation (fluids, falling blocks, growth, decay, fire)

- [ ] Random-tick family (distinct from K1's scheduled ticks; shares the per-tick budget discipline): leaf decay, grass spread, wheat/carrot/potato + stems + saplings + cactus/reeds/mushroom/vine growth, farmland hydration/decay.
- [ ] Fluids: water/lava flow spread + settling (the G1 fluid-CA candidate needs this CPU reference first); placed buckets (L7) and springs feed the same sim.
- [ ] Falling sand/gravel (entity type 70 + landing logic), fire spread + burnout (gated on the existing `doFireTick` gamerule, inert today), ice/snow melt near light, snow/iron golem assembly (block-pattern build → entity spawn).
- [ ] Acceptance: poured water reaches 7-block still level; floating sand column collapses; leaves 4+ from wood decay; wheat grows through stages; fire set by flint (L7) spreads and burns out; golem built by hand comes alive.

### L2. Potion-effect application (server side)

- [ ] Today effects are tracked + displayed + expired (A6) but change no gameplay; K2's potions are cosmetic without this. Apply server-side: Strength/Weakness damage scaling, Fire Resistance immunity, Water Breathing (no drown), Regeneration/Poison/Wither ticks, Absorption/Health-Boost hearts.
- [ ] Client-side effects (Speed, Haste, Night Vision…) need no server code beyond S1D — verify each id is correctly classified, don't simulate what the client owns.
- [ ] Acceptance: Strength II raises melee damage by the vanilla formula; Fire Resist swims in lava; poison ticks; absorption hearts show and absorb; unit goldens for the damage formulas.

### L3. Combat depth

- [ ] Armor damage reduction (armor bar exists client-side; server applies nothing today) incl. Protection-family reduction reusing the `cmd_data` enchant tables; sword blocking (right-click Use-Item → damage halved while held); falling crits (×1.5 + S2A crit particles — needs L8's particle packet).
- [ ] Thorns if the enchant table carries it (else follow-up with K3's anvil).
- [ ] Acceptance: full iron takes the vanilla-reduced hit (golden formula test + live E2E); blocking halves; crits proc only while falling.

### L4. Dimensions: Nether + End

- [ ] Nether gen (netherrack caves, lava ocean, glowstone, quartz, fortresses — structures ride the L5 generator work), End gen (island, obsidian pillars, crystals as entities or scheduled ticks).
- [ ] Portals: obsidian-frame detection + flint-and-steel lighting (shares L7's Use-Item path), cross-dim travel with per-dim chunk namespaces (store keys already carry dim), per-dimension rules (no skylight/weather in Nether, beds, respawn-at-bed only in Overworld, End exit → Overworld spawn).
- [ ] Acceptance: light portal → walk through → Nether terrain + lava ocean; die there → correct respawn; return portal links back within vanilla search radius.

### L5. Structures + villagers + trading

- [ ] Overworld structures the v5 generator skips (H2 documents the gap): villages, desert/jungle temples, witch huts, mineshafts, strongholds (+ lake/carve suppression near them, already stubbed in `decor.zig`), scattered loot chests.
- [ ] Villagers (extend J4/L6 AI minimally: idle + door-seeking is enough for v1), trading UI + offer generation/re-stock, Eye of Ender flight toward the nearest stronghold (needs stronghold gen above).
- [ ] Acceptance: locate a village live, trade wheat → emerald, eye of ender flies true; loot chests contain vanilla-table rolls.

### L6. Mobs: the full roster (extends J4, don't duplicate it)

- [ ] J4 covers spawner/AI/drops/persistence; this slice is breadth: passives (cow/sheep/pig/chicken/squid/bat/ocelot/wolf), hostiles (zombie/skeleton/spider/creeper/enderman/slime/witch/silverfish-from-infested-block), breeding/taming/saddles/horses/leads/nametags, Nether mobs behind L4.
- [ ] Acceptance: night spawns hostiles that path to the player; wheat lures cows + breeding makes calves; tamed wolf fights back; difficulty scales damage.

### L7. Items, vehicles, XP orbs

- [ ] Use-Item path (shared with K2 drinking / K4 flint-and-steel): bows (draw power → arrow SpawnObject + damage), fishing (bobber entity + catch table), buckets (place water/lava, milk clears effects, fill from source), shears/hoes/bonemeal/cauldron interactions, ender pearls (teleport + fall damage), maps/books/sign-text (`0x12` Update Sign handler — signs are blank wood today), jukebox playback.
- [ ] Vehicles: minecarts (+ chest/furnace/hopper/powered variants, detector/powered rails) and boats as entities with boarding (`0x0C` Steer Vehicle exists but nothing drives it); minecart/boat items craft today and do nothing.
- [ ] XP orbs (Spawn Experience Orb `0x11` framer + magnet on the J1 item path): mining/smelting/breeding/trading XP awards (`drops.zig` explicitly excludes orbs today).
- [ ] Paintings (`0x10` framer exists as an id only) + item frames (place + rotate + hold item).
- [ ] Acceptance: bow one-shots at full draw per vanilla formula; fish bite on vanilla timing; bucket places source water that flows (L1); XP bar fills from mining coal ore; painting hangs on wall.

### L8. Multiplayer + misc parity

- [ ] Query protocol (GS4 `enable-query` equivalent) for server lists.
- [ ] Statistics triggers (blocks mined, distance walked — the `stat.*` criteria strings exist, nothing feeds them) + achievement grants on action (today only via command).
- [x] Death messages (yellow join/leave style, plain white text): hunger/starvation, drown, lava, fire, suffocation, cactus, fall, void below y=-64 (kills even in creative, drops destroyed), combat ("was slain by X"), /kill ("died") — broadcast to all play conns + console log; unit goldens for every line + loopback `/kill` broadcast test + live bot check
- [x] Rate limits: login attempts per IP (5 joins/10s sliding window, `Too many login attempts` + close; IOCP conns carry no IP and bypass), block-place attempts per conn (32/s burst, same vanilla spam kick as chat — creative spam is a chunk-rewrite storm into the LSM). Chat throttle pre-existing. Unit + live bot verified (5 in, 6th/7th rejected)
- [x] `/tps` (server extension like `/perm`, `/netstat`, usable by players): 1Hz tick p50/p99 + flush timing + player/tick counts (honest about the 1Hz ticker, no fake 20.0)
- [ ] Spawn protection (16-block, op-bypassed, vanilla radius) + sleeping in beds (skip-night vote + spawn set) + hardcore world flag.
- [ ] Presentation sweep: S2A particle packet (potion splash, crits, note smoke — K2/K4/L3 consume it), remaining S29 voices (hurt, eat, splash, doors — `random.explode` shipped in K4), server-list favicon.
- [ ] Command blocks (redstone-powered command execution via K1 power + existing dispatch; `testfor` already hardcodes its message).
- [ ] Acceptance: query responds to GameSpy packets; death by creeper prints the vanilla line; non-op can't break spawn; all sleepers → dawn; hardcore death bans (vanilla SMP rule).

---

## Bugfix round — user-reported gameplay (Oct 2026, all live-verified over TCP unless noted)

- [x] Placements: dispenser/dropper yaw-only facing 2/5/3/4, hopper opposite-face, anvil rotate-once + damage<<2 (`sim/redstone.zig` + `game/mc5/blocks.zig` + held-damage threading through `conn.onPlace`); anvil drops carry damage>>2. Door lower metas 1/2/3/0 at 0/90/180/270 confirmed; upper half unchanged (places in air only)
- [x] Enchanting: `.enchant_click`/`.enchant` were missing from the serve-thread event whitelist, so table clicks silently died and no offers ever appeared — whitelisted; offers (e.g. 1/5/6 with shelves) now arrive via 0x31
- [x] Cactus: 1.0/s contact damage with regen between hits (live: 18→14 over 6s); `cactus` added to the `isOpaqueCube` transparent set (it was stacking 4/tick suffocation on top)
- [x] Login gamemode: JoinGame goes out at bootstrap before the player row loads, so returners kept the creative JoinGame value while the server dealt survival damage — now sends S2B reason 3 with the loaded gamemode before the abilities refresh (live: rejoin shows GameState 3 survival + abilities 0)
- [x] Login inside blocks: rescue scan moves the login pos up to the first 2-air headroom before arming the grace (unit-covered paths: feet/eyes opaque)
- [x] Plates: release checks now run on the 10Hz redstone loop with read-only entity snapshots (no inbox drain/wander/item mutation — the 1Hz tick still owns those), so deactivation jitter drops from ~1s to ~0.1s on top of the 20-tick minimum press
- [x] Pickup feel: magnet radius 1→2 blocks (walking over break-drops no longer steps past between 1Hz ticks); spawn already instant, collect ~1 tick, merge on grant (live: spawn 0.00s, collect 1.07s)
- [x] Survival inventory: resyncs now include the cursor (stale-action full refresh, table/enchant mismatch, ignored number-key swaps echo both slots); creative 0x10 gated to creative (survival replays echo the slot unchanged); click conservation verified live (6 planks through pickup/split/swap/delete with no dup/resurrect)
- [x] Jungle golden (was listed as pre-existing/untouched, now fixed — three real bugs, all verified against the 1.7.10 jar + live `StructDump` regen): (1) `junglePyramid` was missing four 1x1x1 pillar-top `fillBoxChoose` calls (`(4,9,4)`,`(7,9,4)`,`(4,9,10)`,`(7,9,10)`, all out-of-clip so writeless but RNG-consuming — the 4-draw stream shift behind the write-300 cobble/mossy mismatch); (2) east piston-group rotation mapped 4→3/5→2, jar (`avk.a`) says 4→2/5→3; (3) diodes (repeaters/comparators) were missing from `isDirectional`, so the repeater fell through unrotated (meta 2, jar wants 3). Full suite green: 431 pass, 1 skip, 0 fail on mod_tests; `zig build test` + `check-imports` clean
- [x] Cactus brush-past: standing in a cactus damaged fine, but walking/running through one usually dealt nothing — the 1Hz tick only sampled the current position (a sprint crosses a cell in ~0.2s vs vanilla's 20tps collision). The tick now sweeps the player's per-tick movement bounding box (`Conn.haz_*`, expanded in `setPos`, consumed/reset in the snapshot pass) against the inset cactus box, so any crossing — even a round trip inside one tick — hits; teleports fall back to the endpoint check (live: 4/4 crossings damage, was ~2/8)
- [x] Break drops pop instead of appearing glued to the ground: drops now spawn inside the broken cell with vanilla EntityItem motion (XZ in [-0.1, 0.1], Y 0.2, jar-verified `xk` ctor) from a dedicated toss stream (`toss_seed` fixed constant — never the world/drop seed, so scatter can't leak worldgen RNG state the way randar did; vanilla uses `Math.random()`, not `world.rand`), then arc under 1Hz-quantized physics (20 vanilla substeps/tick: gravity 0.04, drag 0.98, ground bounce -0.5, settle on first-solid-top + 0.125, void despawn below y=-64) with rel_move/teleport broadcasts until they settle; Q-drops/table/death drops got the same treatment (Q-drops arc forward instead of hovering at eye height). Live: spawn-in-cell + upward toss + settle + magnet pickup + destroy all observed over TCP
- [x] Swim-then-shore phantom fall damage: only downward motion while airborne accrued `fall_acc` (never subtracted, never reset in water), so a surface swim ratcheted up a huge phantom drop that cashed in as `ceil(dist-3)` damage the moment you walked out onto a beach. The tick now maintains `in_fluid` (eyes or feet in water/lava) on the conn and zeroes `fall_acc` while set; `setPos` skips accumulation/stash while set (vanilla resets fallDistance in fluid). Live: 10s surface bobbing + walk-out, health stays 20.0
- [x] Phantom diagonal cactus damage (hits 1-2 blocks away, landing late): the 1Hz segment sweep used the path's bounding rectangle as its narrowphase, so a diagonal walk-by flagged cacti in the rectangle's unvisited corner — damage fired a tick later when already blocks past. The sweep is now an exact segment-vs-box slab test (`segmentHitsCactus`: Minkowski-expanded cactus box), which degenerates to the point check when standing still. Verified against the 1.7.10 jar (`ajt` inset box, `sa` cell-overlap rule): offsets 2.0/1.0/flush safe, 0.7/0.6/center damage. Live on a verified sky pad: diagonal walk-by at closest 1.13 safe, straight-through still damages. Unit tests cover walk-by miss, walk-through hit, stationary, jump-over/land-in. Follow-up (jar `ajt`+`sa` recheck): the inset box is collision-only — damage fires per overlapped CELL with no box retest, so the 0.0625 shell inside the cell (short of the inset face) must hurt. Both tests now use the full-cell rule with the 0.001 shrink. Live: side-press 0.03 into the cell repeats every tick, cell-flush hold stays safe, diagonal still safe
- [x] Weird/invisible drops: two real bugs. (1) Over-merging: `spawnItem`/tick-merge matched on XZ only, so pillar/tunnel drops stacked vertically merged instantly and invisibly; now gated on |dy| <= 0.5 like vanilla (jar `xk.k`: AABB expand is XZ-only, no Y expansion). (2) Floating drops: settled items park with zero velocity and the tick skips them, so digging out from under a settled drop left it hovering where the block was; `breakAftermath` now re-arms items at/above the broken cell (`wakeItemsAbove` nudges vy) so they fall to the new ground. Live: pillar dig shows per-break spawns, drops fall/settle/pick up (collect+setslot+destroy verified), total conservation holds
- [x] Item teleports (diagonal 2-block snaps, Q-drops jumping 5-6 blocks): spawn packets (`0x0E` type 2) hard-coded zero velocity, so the client drew a stationary item until the 1Hz correction snapped it to the integrated position — and Q-drops travel ~5 blocks in that first simulated second. The spawn now carries the live toss velocity as x8000 shorts (vanilla `xk`/`EntityTrackerEntry` behavior: the client runs the same EntityItem sim between corrections), so break pops arc and Q-drops fly smoothly. Live wire check: Q-drop spawn arrives with vel=(43,1200,2493). Unit test asserts tossed vs settled velocity bytes. Follow-up: tosses over uneven ground still snapped mid-air — the landing surface was computed once from the spawn column, so a cliff throw "landed" on air at the old height and the correction yanked the correctly-falling client item back up. `integrateItemToss` now refreshes the surface per crossed column (decode per fresh column, not per substep) and treats a surface above the feet as a wall (revert horizontal step, drop to that base) instead of embedding/floating. Live: pillar throw settles (14.6,71.1) on the low ground; unit tests cover cliff tracking + wall stop
- [x] Fall damage threshold off (3.5 blocks safe, phantom hits at 3.0): two bugs. (1) The landing frame's own descent was never counted (`on_ground` set, so the accumulation arm skipped it) — losing up to a full packet-step (~0.5-0.7 near impact speed), pushing the effective threshold from 3.0 to ~3.7. `groundTransition` now adds the landing dy into the stashed distance, matching vanilla's full-fall count. (2) f32-summed network steps read 5.0000005 for an exact 5.0 fall and `ceil` flipped a whole extra heart at integer boundaries; the damage calc carries a 1e-3 epsilon. Live: 3.0 safe, 3.5 = 1 heart, 5.0 = 2 hearts. Unit tests pin the 3.0/3.5 landings + dust boundary
- [x] Single-chest kick (vanilla `length(1) exceeds writerIndex(13)` ByteBuf overrun): our S24 Block Action omitted the trailing VarInt block id (jar `gg` reads int x, SHORT y, int z, ubyte, ubyte, block id & 4095) — the client consumed our 12 payload bytes (+1 id byte in its buffer = 13) and overran by exactly 1 on the missing id. `frameBlockAction` now takes the id (all 6 call sites: chest/ender/double-chest lids + redstone actions), unit test asserts the trailing varint, lid test helper parses the full packet. Live: chest opens with 0x2D window + 0x30 items + 0x24, no kick. (Also fixed my probe bot: 1.7.10 open-window is 0x2D, not 0x64.)
- [x] Drops invisible until relog: item merges (spawn-time and tick) grew the survivor's stack with no packet — vanilla sends a DataWatcher update on merge, so the extra drops stayed invisible until a relog re-snapshotted the stack. `broadcastItemMeta` now sends a 0x1C refresh to trackers on every merge (both sites). Live: same-spot re-digs show META updates without new spawns; per-break spawns/collects verified end to end
- [x] Inventory shortcuts: shift-click filled the hotbar at the START (slot 36) and drag-spread (mode 5) was a no-op that silently reverted on reopen. `quickMove`/`quickMoveLists` take a `reverse` flag: into-player moves scan hi→lo (vanilla `mergeItemStack` reverse pass — chest→hotbar lands on slot 44 first, hotbar→main still fills forward from 9); drag-spread implemented per vanilla (`DragPaint` start/add/end, left even-split remainder-first, right one-per-slot, result/armor/fuel/output validity per window, cancel on any other click, full resync on end/cancel) for windows 0/1/3 in-conn and 2/5/6 serve-side. Two dispatcher gaps fixed on the way: chest mode-5 start/end (slot -999) died in `onClickWindowChest` range checks, and `mutateChestClick` gated `mode > 2`. Full suite green (508/0); live: window-0 drag 10→4/3/3, shift main→44 / hotbar→9, chest drag 12→4/4/4 persisting across close+reopen
- [x] Phase C 600-conn SIGSEGV (stack smash, not LTO): `buildRegionGroups` indexed fixed `[256]` side arrays with up to 1024 viewers — ReleaseFast has no bounds checks, so past 256 viewers it smashed the tick thread's stack and crashed wild (misleading backtrace pointed at an inlined `mobs[0..0]` with a null `Registry*`; fault address 0x10 + disassembly proved a smashed stack). Fix matches the code's own overflow philosophy: viewers past the cap tick inline via the legacy body. Regression test with 260 loopback conns (256 grouped exactly once + 4 legacy, no smash). Live: same 600-conn storm that segfaulted twice now survives; suite green (509/0). LTO formally exonerated (non-LTO build crashed identically)
- [x] Join-stall diagnosis under 600-conn login storm (uring): NOT recv starvation — transport counters after a full load prove `buffer_starved=0`, `recv_arm_failures=0`, 600 accepted/600 closed, and the re-arm sweep + an early-release experiment changed nothing (early-release reverted). Direct gdb stacks show the real mechanism: each login burst holds its conn spinlock for seconds (worldgen + zlib of 289 columns) while `announceJoin` (and the tick grouping) take EVERY conn's lock — 7 of 8 uring workers pile onto one bursting conn's lock, throughput collapses to a flatline (~330 joins regardless of window). Blocking reaches 580/600 on the same load because per-conn threads don't serialize behind one lock this way. Proposed fix (needs sign-off, UAF-sensitive): drop `conn.lock` across the burst portion of login with a liveness re-check, and/or make the announce loop non-blocking; secondary: the world-store mutex is 8% of all samples under the same load (shared spawn-burst cache would collapse 600x289 gets)
- [x] 600-join storm fixed end-to-end (was: ~230-400 join, rest silently stuck; now 600/600 twice, clean tree, no instrumentation). Three stacked causes, fixed in order: (1) Phase C stack smash (above) crashed the server outright; (2) per-login bursts held conn.lock for seconds, convoying the tick + every announceJoin into a standstill — fixed by dropping the lock across the burst with refcount pinning + closed-flag liveness check (first attempt used a registry lookup under the conn lock = ABBA deadlock vs playNames; caught live via gdb, fixed the same session); (3) 600x redundant 289-column bursts (gen+read+zlib) serialized every login — fixed with cross-login burst singleflight (shared owned frames, condvar parking, solo fallback; exhaustively reasoned lock discipline, no nested locks anywhere). Bonus PGO finding along the way: the world-store global mutex is ~8% of all samples under join load (next bottleneck candidate), and per-conn outbox appends serialize on the shared DebugAllocator — left alone (out of networking scope, needs your call)
- [x] Store-mutex convoy under join load (the "next bottleneck" from the entry above): live gdb on the singleflight-fixed binary showed 7 workers parked in `Store.get`'s futex while one holder did plain-pread SST I/O under the same mutex (flush/compact also hold it across file IO). `get` is now optimistic: snapshot the SST set under a brief lock (Bloom + stride ranges copied by value — names copied, never borrowed), do all file I/O unlocked via fresh `openFile`+pread, then re-validate (memtable re-check for newest-wins + `generation` check). Only a genuine mid-read flush/compact retries (bounded 3, then the fully-locked `getLocked` backstop with byte-identical behavior). `generation` (+%=1, no atomics needed — only touched under the mutex) bumps on every live-set mutation (flush append, append-rollback, compact swap); memtable-only puts need no bump (re-check covers them). Deliberately NOT reusing the ring or kept-open fds on the optimistic path (the ring is single-in-flight under the store mutex by design; sharing it needs its own lock + lifetime dance — follow-up if pread ever profiles hot). The two ring-counter tests now drive `getLocked` (ring stays wired there); a new threaded test hammers `get` against concurrent flush+auto-compact (3 readers x 400 version-stamped gets, format-checked for tears) plus an end-state check. Full suite green (170 + 511/1-skip, `check-imports` clean). Live 600-conn x2 on fresh worlds, ReleaseFast: 600/600 joins, 0 errors both runs (~22k bulks, ~276k unloads served); mid-storm gdb shows the convoy gone — readers sit in `readCandidate`→`pread` with no mutex held (vs 7 parked on the store futex pre-fix), the only parking is singleflight `runBurstShared` condvar wait, which is by design
- [x] GPU-era re-verification (their Phase G Vulkan wiring + 122-file reorg on top of the store split): full suite green across all four test binaries (528 passed/1 skipped + 170 + 28 + 0 failed), including the CPU-vs-GPU fill equivalence test EXECUTING (not skipping) on this box's RX 9070 XT -- byte-identical mask/biomes/heights/section-blocks, zero fallbacks. Optimistic-get telemetry added (`get_attempts/get_retries/get_locked_fallbacks` atomics + `readStats()`): the hammer test asserts retries stay a trace (fallbacks <5% of attempts -- one legit fallback observed, which is the backstop working as designed, and forced the bound to be statistical rather than zero). `tools/bench.zig` LSM labels fixed -- both loops now exercise the optimistic pread path (counters prove ring reads 0), so the section compares store configs; ring-vs-pread proof lives in the `getLocked` unit tests. Optimized bench re-run: region-tick pool still beats fork-join (~29%), codec at timer floor, no regressions. Live 600-conn storms on the merged tree: gpu-off 600/600, gpu-vulkan 600/600 (fresh worlds, 0 errors, no store-mutex waits in any mid-storm sample). Indicative only: the vulkan storm served ~2-3x more chunk traffic in-window (21488 bulks/268726 unloads vs 11527/97057) -- consistent with faster gen drain, NOT a controlled timing claim (needs load-side join timestamps for a real number). Two self-inflicted incidents, no code harmed: (1) an RCON `list`-every-2s probe under a join storm piles `playNames` walks (holds `reg_lock` across the 600-conn roster) against `announceJoin` snapshots until probes time out and reconnect-spiral -- retired the probe; pre-existing wart, lethal only with concurrent `list` storms, left alone; (2) `pkill -f` patterns matching my own command line SIGKILLed my own shells twice -- use `[bracket]` patterns or exact PIDs.
- [x] Join fan-out batching (bottleneck #1): every login did O(players) work -- announceJoin took 3 registry snapshots + ~4N conn locks + 2N flushes, so 600 concurrent joins serialized all 8 workers behind every conn's spinlock (observed live). Now `queueAnnounce` pins a ref + appends under a leaf lock, and the ticker's `drainAnnounces` fans out one combined burst per tick (list-adds for everyone-else first, then all join lines -- same bytes/order as sequential announces, one lock hold + one flush per conn regardless of batch size). `playNames` (RCON list) no longer holds `reg_lock` across the 600-conn walk (snapshot+pin first -- the pre-existing playNames pileup that killed my RCON probe is structurally gone). Count pairing kept exact: `announced`+`play_count` set under the recipient lock with a `closed` re-check that closes an unregister race the old code had too (old window was tiny; the tick gap widens it). Tests rewritten to queue+drain (counts asserted at each stage, duplicate-enqueue idempotent, wire order list-then-chats). Live 600-conn (fresh world, ReleaseFast, gpu-off): 600/600 joins, 0 errors, most chunk traffic served yet (23887 bulks/305671 unloads -- faster login drain, indicative); mid-storm gdb shows zero workers in announce paths and zero spin-waiting (vs 5-9 spinning pre-fix). E2E wire proof: throwaway 2-bot probe asserts exact 0x38/0x02 sequences for staggered joins. Note: `std.log.info` join lines never reach serve logs (pre-existing, identical on old binaries) -- not a drain signal. Residual observed once: 3 readers queued on the snapshot lock + 1 in getLocked fallback during a flush-heavy window -- transient writer-camping (fresh-world write storm), bounded by design (unit hammer test); the writer side (flush/compact under mutex) stays bottleneck #2.
- [x] Background flush off the write path (bottleneck #2): put() held the store mutex across sort+build+write+sync+manifest+truncate, stalling every reader snapshot and every other writer for the whole flush (~ms each, ~1000x per join storm). Now put() only appends WAL + memtable under a brief hold; when full it seals (swap + WAL rotation to wal-NNN.log, one fsync) and a per-store worker thread builds the SST + commits (append + gen bump + MANIFEST + sealed-WAL delete) without holding the mutex across I/O. Single in-flight flush; a second full memtable stalls the writer (backpressure, counted) instead of growing memory unboundedly. Crash model unchanged (WAL segments replay oldest-first; commits delete only after MANIFEST; open replays segments then pins them with a flush). Auto-compact moved to the worker thread (same merge, off the put path); manual compact() requests + waits on an epoch. Telemetry: flush_waits/bg_flushes in flushStats(). Caught and fixed along the way: (1) a missed in-flight window (sealed-but-uncommitted entries invisible to gets) via an in-snapshot pending-map check; (2) a REAL ABBA deadlock found live (writer in flush() holding flush + waiting store while a reader held store + waited flush) -- fixed by releasing store before the flush wait loop, so flush() never holds one lock while acquiring the other; (3) a stack-buffer fix for an mmap-under-lock fault in the snapshot path plus a 32-candidate overflow to getLocked. Full suite green (530+172+28, incl. new overflow/fallback-budget tests); live 600-conn storm on ReleaseFast: 600/600 joins, 0 errors, zero store-mutex waits in 4/4 mid-storm samples, background workers correctly parked on condvars when idle.
- [x] Deployed fresh ReleaseFast to asteorite-test/ (asteorite + all tools, incl new bulk_dump/chest_dump/col_dump/genq_dump/gpu_probe; dbg_light/dbg_ring left as-is). Config/world/ops/RSA untouched. Unstripped this time (76MB with debug_info) for live crash triage; smoke-tested boot against the real world+config. Previous binary was the stripped Oct-26 max build.
---

## Phase B — Network: async zero-copy (`io_uring` on Linux, per-OS backends elsewhere) ✅ (Linux path done + measured; macOS compiled only; Windows = blocking fallback)

The `Conn` interface never changed: the protocol layer still gets bytes
in and hands back bytes out. What changed is the transport underneath
(`src/net/transport.zig` + `src/net/uring.zig` + `src/net/kqueue.zig`),
and the *output* path: every byte now goes through the per-conn outbox
(`Conn.out`) and leaves the server in exactly one place — the transport.

- [x] One `io_uring` ring per worker thread (not per connection): multishot accept (`IORING_OP_ACCEPT` + `IORING_ACCEPT_MULTISHOT`) on a dedicated acceptor ring, multishot recv with provided buffers (`IORING_OP_RECV` + `IORING_RECV_MULTISHOT` + a registered buffer ring, `IORING_REGISTER_PBUF_RING`; buffers are handed back after every data CQE). The acceptor is a *separate* ring on purpose: several rings accepting on one listening socket is not well defined, so accept happens in exactly one place and hands the fd to a worker (ring handoff via a locked submission queue + a NOP wakeup SQE — the registered eventfd only signals, it never interrupts `io_uring_enter`).
- [x] `SEND_ZC` (zerocopy send) gated behind a size threshold (default 8 KiB: chunk bulks go zerocopy, chat/keepalive are copied — the copy of a few hundred bytes is cheaper than the zerocopy notification round trip). Live: 2 967 zerocopy sends during a 150-conn world load.
- [x] Tick-aligned flush: the tick drains every conn's outbox and the transport sends it as ONE batched send per conn (`flushEntry` → `Conn.takeOutput`); the serve path no longer flushes per frame batch. One output path for every transport (blocking writes to the socket, async queues a ring send).
- [x] Backpressure: per-conn outbox cap (`config.out_cap_bytes`, default 4 MiB, `--out-cap`). A slow consumer that overflows it is dropped (the transport closes the conn).
- [x] TCP_NODELAY + socket buffer tuning behind flags (`--tcp-nodelay` / `--no-tcp-nodelay`, `--sndbuf`, `--rcvbuf`; config-file keys too).
- [x] Fallback path: the blocking transport is still there and is the default fallback — `--transport blocking|uring|auto` (plus `kqueue`/`iocp` spellings), and `auto` resolves per OS. If io_uring is unavailable (old kernel, sandboxed `io_uring_setup`), the server logs it and runs the blocking transport.
- [x] Per-OS backends behind one transport interface: Linux `io_uring` (primary, above); macOS `kqueue` non-blocking (`src/net/kqueue.zig`, wired via `--transport kqueue`, lifecycle-reviewed: map-authority close, retained slots, flush wakeups, working stop — runtime still needs macOS hardware); Windows IOCP (`src/net/iocp.zig`, wired via `--transport iocp`: one completion port + worker completion loops + blocking acceptor thread, same `Handler` contract, Win32 entry points as externs; x86_64-windows cross-compiles clean, pure parts unit-tested everywhere, runtime needs Windows hardware; v1 limits: no peer IP on IOCP conns so IP bans don't match them). `--transport` accepts `auto|uring|kqueue|iocp|blocking`; the `Conn` interface is unchanged. Blocking remains the documented fallback on macOS/Windows (one thread per connection).
- [x] NVMe storage path (distinct from net): `io_uring` registered buffers + fixed files for SST reads (`src/world/uring_io.zig`: one ring per Store, single in-flight under the store mutex, READ_FIXED into a pre-registered 8 MiB buffer from pre-registered SST fds); SST files stay open for the store lifetime (no per-lookup open/close on any path); smaller SSTs (1 MiB flush, compact at 4) + parallel cross-shard compaction (`ShardPool.compactAllParallel`, equivalence-tested vs serial); profiles selected by `--storage-profile hdd|ssd|nvme|auto` (+ config key, `auto` detects rotational storage via sysfs). Measured `zig build bench`: gets 572 µs → 85 µs (6.7×) on 2 MB strides, 640/640 via ring with 0 fallbacks; live E2E 10/10 + 30-conn soak (7 317 bulks, ssts bounded at 3) on `--storage-profile nvme`, `check` clean after shutdown, reopen recovery green. The ring is best-effort throughout: a refusing kernel still serves on pread (counters prove which road was taken).
- [x] Acceptance (measured, `tools/load_test.py`, 500 idle + 100 moving conns, ReleaseFast, 20-core box): **600/600 joined, 0 errors**; output push **p50 666 µs / p99 830 µs** (target < 2 ms); tick p99 5.5 ms; **RSS 14 MiB** (blocking transport on the same box: out p50 2.0 ms / p99 3.3 ms and RSS 212 MiB — the difference is the per-connection thread stacks); batched sends: 7 828 flushes for 7 828 send ops (one send per flush, no per-packet `writev`). `strace` is not installed on this box, so the syscall shape is evidenced by the transport counters (flushes == sends) rather than by strace output.

### Bugs found and fixed on the way (all pre-existing)

- **Conn lock leak on a malformed frame**: the frame handler could return an error while `conn.lock` was held; the cleanup path then deadlocked on the same lock (a malformed handshake hung the serve thread forever). Fixed by splitting the locked region into `sessionLocked` (the lock is released on every error path).
- **ABBA deadlock on the duplicate-login check**: the login path held *our* conn lock and then took *other* conns' locks — two simultaneous logins deadlocked each other. Now a try-lock (the save epoch still keeps the newer row authoritative).
- **ABBA deadlock in the memory accounting**: the stats line held the registry lock and took conn locks while the tick path did the opposite. The accounting now snapshots the registry first.
- **Double close of a conn slot** freed the slot and closed an unrelated fd (a ring fd → the worker died with `EBADR`). Closing is now idempotent: the map is the authority, and slot memory is kept until the worker exits.
- The multishot accept is re-armed when the kernel stops it (otherwise the listener goes deaf after the first hiccup).
- **The stats line rendered garbage (`sent=64 BB`)**: the three memory
  fields shared one format buffer, so all three aliased the last write.
  Each field has its own buffer now, plus a regression test
  (`statsLine renders per-subsystem memory independently`).
- **`conns=` showed the cumulative accept count, not live connections**:
  it now shows accepted-minus-closed (blocking transport: registry size),
  so a growing number next to a flat player count actually means a leak.
- **The tick held the world lock across the per-player environment reads** (2 store reads per player per tick): a cold-cache read stalled every chunk-serving thread behind the world lock. The env checks are pure reads (the store replaces whole chunk values, so a read is never torn) — the world lock is no longer held for them.
- **Flush-kick self-deadlock in the io_uring backend** (latent, found by audit while building IOCP): `workerCloseConn` spun on slot refcounts, but the flush path held a ref across `on_flush` — an overflow kick (slow-consumer protection firing mid-flush) deadlocked the worker on itself. Fixed with retention + a `dead` flag (no waiting anywhere); the same discipline was applied to kqueue (`closeSlot`) and designed into IOCP from the start.
- **kqueue stalls ticker output + races** (found by the same audit, untestable here so fixed by review): flushes never woke the worker (keepalives/time updates sat until inbound traffic arrived — idle clients would time out), the conn map was scanned lock-free from any thread, and closed slots were freed under a live worker. Fixed: per-worker lock, retained dead slots, flush wakeups via a new `drainFlushes` sweep, and a working `stop()` via `EVFILT_USER`.
- **`closedStream` used `-1` as a socket handle**: fine for POSIX fds, a type error for Windows HANDLEs. It only surfaced once the IOCP wiring newly analyzed that function for the Windows target — fixed with a per-OS sentinel.

### What the tick p99 spike actually is (measured: 1 player, world on)

`tick_p99=85…188 ms` with one player is **not** the transport: the output
push stays at 6-13 µs (`out_p99`) the whole time. It is the **synchronous
LSM auto-compaction**: the store compacts inside `put` when the live SST
count reaches 8, and one compaction merges every live run — with the
server defaults (4 MiB flush threshold, 8 SSTs) that is up to 32 MiB per
compaction. Measured in `zig build bench`: 46 ms per 8 MiB merged
(174 MiB/s, CPU/allocation-bound — the disk itself does 4.9 GB/s here) →
**~180 ms for 32 MiB**, which is exactly the p99 the server reports. It
lands on whichever thread did the write (the tick thread, a serve thread
or a gen worker).

Not fixed here: moving the compaction off the write path is Phase C/H5
work ("auto-compact at 8 runs (sync; backgrounding is Phase C/H5)" in
Phase E). The cheap mitigation today is a bigger `flush_threshold_bytes`
(fewer, larger compactions) or a higher `compact_threshold_ssts`.

## Phase C — Concurrency: region threading (Folia-style) ✅ (shipped: parallel viewer tick + authoritative handoff + breaker + affinity + persistent pool; per-region mob-AI halving is the remaining follow-up)

Current state: `tickOnce` files play viewers into region groups and ticks
them on a persistent pool (fork-join fallback); mobs live in per-region
SoA stores with delete-at-drain handoff; `ShardPool` shards storage.

- [x] Grid sharding: `32x32`-chunk regions owned per-tick by worker threads (`src/sim/tick.zig` Registry owns the region set; one region = one tick unit, never split mid-tick; deterministic within a region via single-tick-per-region + FIFO inbox drains, group-ordered merge)
- [x] Thread pool sized to cores with `sched_setaffinity` pinning, CCX-aware grouping (neighbors on shared L3; topology via `/sys`, flat fallback). big.LITTLE: P-cores first via `cpu_capacity`, net/IO unpinned; affinity advisory (containers/cpusets may refuse — correctness never depends on it). Persistent pool (`src/sim/pool.zig`: Linux futex generation barrier, stable worker identities pinned once; `error.Unsupported` off Linux → fork-join fallback) drives the viewer pass; fork-join survives as the fallback. Measured (`zig build bench`, ReleaseFast): pool matches fork-join on big ticks (0.81 vs 1.20ns/op, same checksums) and does **3.0µs vs 1317µs per near-empty tick** — per-tick spawn costs ~150µs/worker on this box, which is what the pool removes
- [x] Cross-region handoff, authoritative (Phase C follow-up): each tick Region owns its SoA mob slots; wander crossings push full-state `Transfer`s (source copy kept); next tick's drain adopts into the target and deletes the source **only if still present** — delete-at-drain gives zero-gap snapshots (adopt lands before the merge), no duplicates, attacks that never miss an in-flight mob, and mid-flight kills that drop instead of resurrecting (all unit-tested, incl. a deterministic 3-tick border crossing). Player crossings still feed the per-region census + shed load signal. Item entities stay global (merge + magnet pickup are cross-region pair interactions — partitioning needs a halo protocol, documented in code)
- [x] Per-region 50ms budget with overrun accounting (per-region `recordSample`: ticks/overruns/last_tick_ns + timing window) + global tick barrier for time-of-day/weather sync only (`TickClock` atomics publish; never a global world lock)
- [x] Per-region load-shedding (circuit breaker): p99 over a 16-tick window above 15ms for 3 straight ticks sheds that region only (players-only reconcile, no furnace-window resync — the O(V*E) dominant cost); 5 straight cool ticks recover automatically; `region_shed` (entries) + `regions` (live count) in the stats line
- [x] Deterministic tick order within a region; out-of-order delivery across regions is fine (group-ordered merge; same-tick claim priority follows group order — documented)
- [x] Acceptance: `zig build bench` (ReleaseFast, 8 regions x 200 viewers x 2000 entities, reconcile-shaped branchy work): **5.63×** over sequential with identical checksums (pure streaming scans are bandwidth-bound at ~1.2× — measured, not claimed; pool matches at 0.81 vs 1.20ns/op); engine + server stress tests (8-thread registry hammer, concurrent MPSC drain, 2-region parallel tick with crossing, exact-once grouping goldens, pool 50-generation barrier exactness, authoritative 3-tick border adoption); `--region-threads 1` keeps the sequential legacy path; live E2E 10/10 + 16-bot RCON spread (8 live regions, `region_shed` tripped once under the teleport storm and held, 0 errors, 2.5k chunk bulks, `check` clean after shutdown); follow-up live (pool viewer path + region-owned pig through a 16-conn soak, 4 regions, 0 errors, `check` clean)
- [ ] Follow-ups (not blocking): per-region mob-AI halving as a second shed stage (today: narrowed reconcile slices)

### Bugs found and fixed on the way

- **Region group ranges overlapped on interleaved regions**: extending ranges in place (`groups[gi].end = n_ordered`) covers other groups' members when regions interleave in snap order — viewers ticked twice per tick (double hunger drain, double packets). Fixed with two-pass compaction (classify, then prefix-sum into contiguous disjoint ranges); regression test (`grouping covers each viewer exactly once`) asserts exact-once coverage + snap-ordered membership, which the old code fails.

## Phase D — Memory + CPU fast paths ✅ (modules + adoption done; numbers measured)

- [x] Slab allocator for entities/block entities (`src/sim/slab.zig`: fixed-size, contiguous pages, intrusive free list, slot addresses stable so a live entity can never be moved) + per-tick arena reset for transient tick data (`src/sim/arena.zig`: bump arena, `reset()` is `len = 0`). The per-feed `allocator.dupe` in `feedData`/`queueRaw` is gone — the decrypt/encrypt copies now use the per-conn scratch arena (reset right after the bytes land in the owning buffer), so the steady-state allocation rate on the hot path is zero.
- [x] SoA entity store (`src/sim/entity_store.zig`): contiguous pos/vel/health/AABB component arrays (`MobStore`), never a new AoS store. The live server mob list is migrated: `Server.mobs` is a `MobStore` (swap-remove slots, `indexOfId` lookup, SIMD `tick` for wander+integrate, snapshot conversion at the reconcile boundary). Migration golden (`mob store tick matches legacy AoS wanderStep`): 6-mob herd, 500 ticks, positions agree to 1e-9 with exact yaw/leg. Live-verified: demo pig auto-spawns/wanders/reconciles off the SoA arrays (`mobs=1` through a 15-conn soak), summon/attack paths covered by the migrated unit tests (non-lethal/lethal/destroy + pig respawn timer). `entity.Mob` remains as the AoS reference type for unit tests only.
- [x] SIMD fast paths with Zig `@Vector`: entity integration `pos += vel*dt` (4×f64 lanes) and AABB overlap (4×f32 lanes + a 4-bit mask) — scalar twins are the reference implementation and the unit tests assert the two agree. VarInt/stream scanning was measured and NOT vectorized: byte parsers are branch-bound (0.83 ns/varint), a vectorized parser is not a win. Numbers from `zig build bench` (ReleaseFast, x86_64): integrate **0.24 → 0.16 ns/entity (1.5×)**, AABB overlap **0.33 → 0.22 ns/test (1.5×)**. The same `@Vector` source compiles to NEON on aarch64 and to SSE2/AVX on x86_64 — verified by inspecting the emitted asm (`zig build-obj -O ReleaseFast -target aarch64-linux-musl -femit-asm`): the aarch64 object contains `fcmge v19.4s` / `faddp s21, v19.2s` (4×f32 NEON lanes) and the x86_64 object contains `mulpd`/`addpd` (packed doubles).
- [x] Memory budget (measured, not promised): **RSS 3.6 MiB** on a fresh DB + 1 player (ReleaseFast, io_uring transport) — the P1 target was < 100 MB. Per-subsystem accounting is in the stats line (`outbox=`, `sent=` (sent-sets), `ents=`, `rss=`), plus the transport counters (`conns=`, `zc=`, `copy=`, `flushes=`, `starved=`, `armfail=`). The stats line prints every 10 ticks: `stats tick_p50=… tick_p99=… out_p50=… out_p99=… send=… reconcile=… players=… rss=…`.
- [x] Seqlocks for read-heavy shared state (`src/sim/seqlock.zig`): the read-mostly config (difficulty, default gamemode, the nine gamerules, autosave, idle timeout, world spawn) is published as one snapshot behind a seqlock — the readers (`getDifficulty`, `gameruleGet`, `keepInv`, `tileDrops`, the login bootstrap, the tick) take **no lock at all**. The hot shared scalars (time-of-day, world age, player count) are atomics (lock-free, no mutex). The weather state still uses the command spinlock (written once per tick, read rarely).
- [x] Acceptance: `zig build bench` tick micro-benchmarks with before/after numbers (`tools/bench.zig`): entity tick 8.07 ns/entity (AoS) vs 9.05 ns/entity (SoA — the SoA tick splits the move into velocity + integrate, so the layout alone is not a tick win; the win is in the SIMD paths and in cache behaviour at scale), position pass 0.43 ns (AoS) vs 0.44 ns (SoA — 4 096 entities fit in L2, so the layout difference is invisible at this size), integrate 0.24 → 0.16 ns, AABB 0.33 → 0.22 ns, varint scan 0.83 ns (branch-bound, no SIMD win). LSM: put 5.7 ms per 1 MiB chunk, get 0.58 ms per 1 MiB hit, **compaction 46 ms per 8 MiB merged (174 MiB/s)** — the compaction is CPU/allocation-bound, not disk-bound (the disk does 4.9 GB/s here); that compaction is what the tick p99 spike is (see Phase B).

## Phase E — Storage hardening ✅ (done: compaction + MANIFEST, Bloom/index reads, fsync policy, key-order fix, `check` tool, snapshots; stretch journal deferred)

- [x] Compaction: merge SSTs within a shard (all-run newest-wins merge, simplest correct first), delete superseded runs, keep `next_sst_id` monotonic across restarts + MANIFEST (tmp+rename swap) so a crash mid-compact can't lose runs; auto-compact at 8 runs (sync; backgrounding is Phase C/H5)
- [x] Read path: per-SST Bloom filter + sparse block index (ZLS2 footer; ZLS1 reader kept). Measured first: 50-SST `get` p99 1.58ms → 67µs, p50 1.24ms → 33µs (Bloom skips absent files, index narrows present scans)
- [x] fsync policy: WAL `sync()` per `wal_sync_bytes` (0 = sync on flush/close only, the P1 behavior preserved by default) + truncating WAL only after the SST+MANIFEST it replaces are durable (truncation atomicity reviewed in `flushLocked`)
- [x] Signed-BE key sort fix: `encodeKey` biases x/z by 2^31 so lexicographic order matches numeric (old P1 DBs not readable — reimport via Anvil)
- [x] Repair/verify tool: `zig build check -- <db>` replays WAL, checks CRCs, audits SSTs (magic/count/order/footer-CRC/Bloom rebuild), lists orphans (`tools/check.zig`, read-only)
- [x] Snapshot/backup: SST file-level snapshot while running (`Store.snapshot`/`ShardPool.snapshotAll`: flush, copy MANIFEST + live SSTs; quiesce writes first — documented in code)
- [ ] (Stretch) Per-tick input journal for forensics/anti-cheat: append compact {tick, player, action} records (separate from the store WAL); used to verify reach/speed claims post-hoc and debug desyncs. NOT instant crash recovery by itself — world durability still comes from LSM WAL/SST; replay needs a deterministic sim we don't have yet. Measure overhead before enabling by default
- [x] Acceptance: kill -9 mid-write storm (300k+ puts, live compactions) → reopen recovers, zero CRC failures, `check` clean (live-verified: clean before and after server reopen; torn-tail truncation covered by unit test)

## Phase F — Pure-Zig modding API (per plan §5)

- [ ] `Registry`: comptime block/item/fluid registration with numeric-ID assignment (1.7.10 range 0–4095 + Add nibble), duplicate detection, frozen-after-boot
- [ ] `EventBus`: comptime `subscribe(EventType, fn)` with zero-cost dispatch table generated at compile time; core events first: `PlayerJoin`, `PlayerChat`, `BlockBreak`, `BlockPlace`, `ChunkLoad`, `TickEnd`
- [ ] C-ABI boundary: `ModDescriptor{ id, version, init, tick?, deinit? }` as `extern struct`; mods are `.so` loaded via `std.DynLib` — comptime/`anytype` must NEVER cross the boundary (documented footgun, Zig ABI is unstable)
- [ ] Hot-reload for dev (`--hotreload`: dlclose/dlopen on file change; state migration is mod's problem — document)
- [ ] Sandboxing story: mods run in-process (same as Bukkit reality) — resource limits via tick-budget accounting per mod tick callback; document the trust model explicitly
- [ ] Example mod: `custom_ore` (register block + break→drop logic) as `mods/example/` + integration test
- [ ] Acceptance: server boots with 0 and 3 mods identically when idle; example mod altera gameplay over real TCP

## Phase G — GPU offload (behind flags — desktop first, mobile second)

Rule: async bulk jobs only, never on the critical 50ms path (dispatch latency alone is ~50–200µs).
One job interface, two backends (discrete desktop GPU vs integrated mobile GPU).

### G1. Desktop headless Vulkan (RX 9070 XT)

Headless Vulkan compute via `Snektron/vulkan-zig` or `mach-vulkan`.

- [ ] Headless compute context init at startup (`--gpu off|vulkan`), persistent device-local buffers for voxel data, pinned host-visible staging
- [ ] Job queue with async readback wired to tick loop: submit → continue ticking → consume next tick
- [ ] Candidates in order: terrain noise/gen (biggest win, pairs with missing worldgen) → explosion raycast → fluid cellular automata (ping-pong) → mass A* wave propagation → entity LoS/proximity queries
- [ ] CPU fallback for every job (flag-off and queue-full paths must be correct, just slower)
- [ ] Acceptance: 32×32 region gen ≥10× faster than CPU path; TNT chain doesn't skip ticks; `--gpu off` bit-identical results

### G2. Mobile GPU — Adreno/Mali via Vulkan compute (ambitious)

Same job queue as G1, separate memory strategy. UMA helps (no PCIe copy) but does
not make mobile GPUs free: drivers are thinner, thermal/battery budget is real, and
compute queues may be absent — so the GPU is opportunistic and the tick never waits.

- [ ] Mobile backend via the same Vulkan binding: capability probe at boot (`--gpu off|vulkan|mobile-vulkan`), graceful CPU fallback when no compute queue/driver (Termux/proot or native wrapper both supported — probe, don't assume)
- [ ] UMA-aware buffers: single coherent host-visible allocation shared CPU+GPU where `HOST_COHERENT` + UMA is present; keep the staged device-local path for desktop discrete GPUs — one job interface, two memory strategies
- [ ] Power/thermal budget: small dispatches, tick-pacing, `--gpu-budget-ms` cap; tick never blocks past budget, overflow runs on CPU next tick
- [ ] First mobile jobs in order: terrain noise/gen (pairs with Phase H) → light/propagation passes; fluid/explosion/A* only after gen proves out on-device
- [ ] Acceptance: `--gpu off` bit-identical results on both backends; on-device bench recorded (gen ms/chunk CPU vs mobile-GPU, RSS, thermal note); server stays playable with the GPU killed mid-run (fallback exercised live)

### G3. Apple Silicon + x86 APUs (UMA without the phone constraints)

Same shared-buffer trick as G2 — these are UMA parts too — without the thermal cap.

- [ ] MoltenVK backend for M-series (Vulkan-on-Metal translation, probed like `mobile-vulkan` with caveats); native Vulkan on AMD/Intel iGPUs where drivers exist
- [ ] Bigger dispatches than phones, still behind `--gpu-budget-ms`; CPU fallback identical to G1/G2
- [ ] Acceptance: same bit-identical + fallback requirements as G2; bench on one M-series box + one AMD APU checked in

## Phase H — World generation (data-driven: vanilla parity + datapack-class custom terrain)

Design: vanilla's own worldgen became data-driven over time (1.12 Customized-world
JSON → 1.18 datapack JSON: noise settings, density functions, surface rules).
So the pipeline is an **interpreter over versioned data definitions** — vanilla
defaults ship as checked-in data (`data/worldgen/`), custom packs (Terralith /
JJThunder-class) override the data, code only changes for new node *types*.
Worldgen version follows the world's version, not the client's (ties to Phase I).

### H1. Pipeline driver + RNG (parity foundation — build first) ✅ (done — RNG goldens JVM-verified, chunk parity covered by H2 full-pipeline goldens)

- [x] `src/worldgen/pipeline.zig`: version-agnostic stage driver — biome source → terrain shaper → surface builder → carvers → features → structures. Every chunk is a pure function `f(worldSeed, chunkXZ)` (enables parallel gen + golden tests); features read a 3×3 shaped area, decorate the center
- [x] `src/worldgen/rng/java_random.zig`: exact `java.util.Random` 48-bit LCG port (≤1.17 parity) with tests against known Java outputs; exact per-chunk seed-mixing formulas. Includes fdlibm `log` port (`strict_math.zig`) — proven necessary: StrictMath.log differs from Zig/glibc by 1 ulp on real inputs, caught by the seed-42 gaussian golden
- [x] `src/worldgen/rng/xoroshiro.zig`: Xoroshiro128++ port for 1.18+ (needed by H4)
- [x] Hard rule (code review gate): RNG call order is part of the spec — one stray `nextInt()` shifts all downstream terrain; call sites versioned + counted in tests
- [x] `tools/worldgen_dump.zig`: gen chunk for seed+X/Z, dump bytes for golden tests (`zig build wgen -- <seed> <x> <z>`; fresh-stream section diffs directly against Goldens.java)
- [x] Acceptance: RNG-level golden hashes checked in and JVM-verified; same-seed-vs-vanilla **chunk-byte** parity covered by H2's full-pipeline goldens (10 chunks, bit-exact)

### H2. 1.7.10 generator (v5 — fills today's void holes)

- [~] `src/worldgen/v5/`: GenLayer chain ✅ + hill noise ✅ + density ✅ + fill ✅ + surface ✅ (base + mesa plateau w/ Bryce) + cave ✅ + ravine ✅ carvers + ores ✅ / trees ✅ decorators — all JVM-verified per-stage incl. 10 full-pipeline chunks (terrain+carve bit-exact); decorator positions differ from vanilla (structures/lakes/dungeons skipped, documented) but shapes/counts/distributions are vanilla-exact via JVM goldens
- [x] Chunk gen as background worker pool (`src/worldgen/v5/genpool.zig`): per-worker private `Gen` (chain state isn't shareable), compute lock-free + recheck/store under the world lock; serve threads never generate inline — misses enqueue + serve holes, retry when the pool sequence advances; `--gen-workers N` (default all cores, cap 16); boot `preGen` fans out + drains (81 chunks: 8.9s serial → 2.3s on 4 workers, Debug build). Live-verified over TCP
- [x] CPU light propagation (vanilla BFS reference — `src/world/chunk.zig` light engine): skylight flood fill from the surface with vanilla opacity/attenuation (vertical column rule + horizontal BFS spread; overhangs leak sideways with falloff, sealed rooms stay dark, roof stones don't leak downward), block-light BFS from emissives (lava/glowstone/torches/furnace-lit) with the established emission tables; incremental two-phase relight on the `view.applyBlock` path (invalidate plausibly-lit cells + reflood from survivors, output-sensitive — never the old full-chunk re-flood per edit; fresh sections get boundary inflow seeds). Stays scalar (branchy BFS). Goldens: overhang/sealed/shaft/leaves/water sideways costs, torch corridor two-phase both directions, 24-edit incremental≡full differential (per-edit nibble compare), roof-plug regression (pins the value-preserving hole fix). Cross-chunk bleed on the edit path (border snapshots + neighbor raise/unspread, diagonal raise+lower, forward-then-reverse)
- [~] Acceptance: fresh DB → login shows terrain ✅, F3 biomes sane ✅ (voronoi biomes on the wire), same-seed parity ✅ per-stage (biomes, density, fill, surface, carve, full-pipeline bit-exact); ores ✅ / trees ✅ present (live-verified: 249-353 ore blocks/chunk, logs+leaves in forest chunks); decorator positions differ from vanilla (documented approximation, structures/lakes/dungeons are future work); lighting is subtractive-sky + horizontal sky/block floods over the 48-wide gen view (border-exact) and incremental two-phase relight on edits + cross-chunk border bleed with neighbor resend (live-verified: RCON place/break cycles + 15-conn soak, `check` clean); boot pre-gen parallelized (81 chunks 8.9s → 2.3s on 4 workers, Debug), serve path never blocks on gen (holes + capped sequence-gated retry with outbox backpressure)

### H3. Data overlay: custom packs (Terralith / JJThunder-class terrain)

- [ ] `data/worldgen/v5/default/...` vanilla defaults as data (same schema packs use)
- [ ] `--worldgen-pack <dir>` datapack-style overlay: biome JSON, noise settings, surface rules, feature lists override defaults; unmapped states fall back to a visible placeholder (never crash, never corrupt)
- [ ] Node registry: density-function ops, surface conditions, placement modifiers registered by name — packs compose shipped nodes freely; novel node types come from a Zig mod via Phase F hooks
- [ ] Mod API: generation-stage events (`ChunkShaped`, `SurfaceBuilt`, `FeaturesPlaced`) + custom node registration — a Terralith-level overhaul ships as data pack + optional `.so`
- [ ] Acceptance: example pack in `data/worldgen/packs/example/` visibly changes terrain live over TCP; vanilla-default run is byte-identical with and without the overlay machinery

### H4. Newer versions (1.12 Customized → modern density functions)

- [ ] `src/worldgen/v340/`: 1.12 generator with built-in Customized-world JSON schema support (vanilla's own custom-terrain lever for that era)
- [ ] `src/worldgen/modern/`: density-function expression interpreter, splines, surface-rule tree, multi-noise biome picker — driven by datapack-style JSON so modern Terralith-style packs load as data
- [ ] Acceptance: 1.12 Customized JSON round-trips; modern pipeline reproduces a reference datapack's terrain; per-version golden hashes like H1

### H5. Generation performance (optimize around the noise, never inside it)

Float noise math must match Java bit-for-bit, so: octave-result caching per column,
column-major gen buffers matching ZC1 layout (no transpose), LUTs for fixed tables.
SIMD only for the safe parts (surface-rule application across column batches,
density-field thresholding) — never inside noise sampling.

- [~] Parallel fan-out: dedicated gen worker pool done (`--gen-workers`, per-worker `Gen`, FIFO + dedup, completion-sequence retries); still to do: Phase C region-thread fan-out, true viewer-distance priority (FIFO preserves per-conn spiral order only), LRU of shaped-but-undecorated columns for neighbor reads
- [ ] Gen once → LSM/ZC1, never regenerate (cache is the primary optimization)
- [ ] GPU plugs in at exactly one stage: density-field computation as a Phase G noise job (G1/G2/G3)
- [ ] Acceptance: gen ms/chunk (CPU, per backend where present) checked in; background gen never blocks a tick (tick p99 unchanged with gen storm running)

## Phase I — Multi-version: one world, any client (ambitious)

> **Direction change (2026-10-22):** runtime multi-version is superseded by
> compile-time version profiles (`zig build -Dmc=<version>`). The authoritative
> plan is [`docs/MULTIVERSION.md`](docs/MULTIVERSION.md). Decisions: 1.8.9 ships
> before 1.12.2 as the infrastructure proof; the roadmap is committed through
> 1.20.4/1.21.x; worlds are profile-owned and cross-version access is
> import-only; 1.12.2 requires `worldgen/v340` rather than reusing 1.7 worldgen.
> The shared-core research — what stays identical, what is profile data, and
> the fix-once exploit ownership map — is in
> [`docs/CORE_SHARING.md`](docs/CORE_SHARING.md).
> The checklist below is retained as historical context: the canonical-core,
> registry and data-generation work still applies, but per-connection protocol
> routing, mixed-version clients and shared worlds are no longer goals.

Goal: 1.7.10 and newer clients walking the same world simultaneously, served by one
binary with zero external proxies. Shape: version-agnostic core + per-version
adapters bound per connection from the handshake version; `--protocols 5,340,...`
is only an allowlist. Staged: each stage must be playable before the next starts —
the mapping work grows superlinearly past 1.13, so no skipping ahead.

### I1. Canonical core + 1.12.2 (tractable — numeric IDs both sides)

- [ ] Canonical internal model first: block state as internal `u16/u32` (not wire id+meta) at the `view.applyBlock`/ZC1 boundary; entity pos/vel/AABB version-free (the Phase D SoA store is the seam). Items already follow this shape (`src/item.zig` canonical `Stack` + per-version `proto/vXXX/slot.zig` codecs; no game table duplicated across versions). No second protocol until the core stops speaking 1.7
- [ ] `src/proto/v340/` (1.12.2) adapter behind the same `Conn` interface: packet IDs, chunk format, `v5 <-> internal <-> v340` mappings; block-entity/NBT mapping proven here before anything newer
- [ ] Handshake-version routing: bind adapter per conn, reject unlisted versions with a JSON disconnect
- [ ] Acceptance: same world serves a 1.7.10 and a 1.12.2 client (sequentially first, simultaneously later) with block round-trip tests `v5 -> internal -> v340 -> internal -> v5` for every mapped ID

### I2. The Flattening — 1.13+ block states (the hard one, explicitly scoped)

- [ ] Internal block-state registry: `namespace:id` + properties <-> compact `u32`; per-version palettes (1.13+ chunk sections are palette-encoded, not id+meta arrays)
- [ ] Translation tables generated from `minecraft-data` JSON at comptime where possible (no hand-maintained 10k-line maps); unmapped states fall back to a visible placeholder (never crash, never corrupt)
- [ ] Acceptance: Anvil-1.13+ import path + round-trip property tests for the full palette used by the test world

### I3. Modern clients + embedded in-process routing (the moonshot)

- [ ] Modern adapters (1.16/1.21 line): registry-driven codecs, login/config-phase flow, NBT-heavy packets, entity/particle/sound registries — one `src/proto/vXXX/` module per version behind the same `Conn` interface
- [ ] Embedded translation core (the "proxy" is just routing, no separate process): single socket loop reads the handshake version, binds the matching adapter, and translates to/from the canonical model per conn — no Velocity/Bungee sidecar needed
- [ ] Mixed-version acceptance: 1.7.10 + 1.12.2 + one modern client on the same world, same region, mutually visible (position/chat/block edits cross versions); per-version packet-log diffs checked in like the 1.7 harness demands

## Cross-cutting

### Platform targets (ARM/mobile is a first-class target, CPU first / GPU opportunistic)

- [ ] CPU baseline: release binary runs on an aarch64 phone (Termux) through the existing live E2E (login→move→chat) with RSS recorded in the stats line
- [ ] GPU opportunistic: mobile Vulkan backend (Phase G2) probed at boot, never required — CPU-only remains a fully supported configuration, and every GPU job has a CPU fallback
- [ ] Acceptance: same E2E passes on-device in both `--gpu off` and `--gpu mobile-vulkan` modes; on-device bench + thermal note checked in

### Slow big-iron (old Xeon / DDR3, no GPU — trade cheap cycles for bytes moved)

Many slow cores, bandwidth-starved DDR3, spinning/SATA disks, often dual-socket NUMA.
Everything GPU-shaped is irrelevant here; the wins all reduce bytes moved per tick.

- [ ] NUMA: pin region threads + shard storage + allocations to the local node (first-touch, never serve remote-node chunks on the hot path); Phase C topology detection extended from CCX to NUMA nodes
- [ ] Huge pages: 2MB THP (`madvise`) for LSM block cache + chunk buffers — fewer TLB misses on big-but-slow RAM
- [ ] Storage compression (pure-Zig LZ4/Zstd for SSTs + ZC1 sections — wire zlib already exists, this is separate): disk IOPS is the bottleneck on these boxes, old-CPU cycles are cheap
- [ ] ISA targeting: `-mcpu` matching the box (AVX on Sandy, AVX2 on Haswell+, never AVX-512); `@Vector` width chosen per target, asm-inspected like the NEON rule in Phase D
- [ ] Internal palette + section dedup for 1.7 (I2 palettes are for 1.13+ wire format — this is a RAM optimization): paletted sections + shared air/empty sections with copy-on-write to cut DDR3 traffic
- [ ] RAM-as-cache: size the LSM block cache to available RAM (these boxes often have 32–64GB ECC), keep hot regions resident, report hot-set hit rate in the stats line
- [ ] HDD-aware LSM profile: bigger SSTs, fewer levels, sequential writes, WAL batching tuned for seek cost (alongside the existing fsync-policy item, not instead of it)
- [ ] Compiler: PGO/LTO on top of ReleaseFast for the branchy packet/codec paths (CI does ReleaseFast only today)
- [ ] OS runbook (docs, not code): performance governor, C-states off, NIC interrupt affinity — README ops section
- [ ] Acceptance: bench on a representative box (e.g. E5-2670, spinning disk): tick p99, `get` p99 at 50 SSTs, gen ms/chunk, before/after per item — no item lands without numbers

### Modern high-end (EPYC / Xeon Scalable, DDR5, NVMe — the inverse of slow big-iron)

Bandwidth-rich, IOPS-rich, AVX-512-capable. The slow-iron advice inverts here:
keep hot data resident instead of compressing it, split work smaller instead of batching it.

- [ ] AVX-512 paths: `-mcpu` + runtime dispatch where the box supports it (goes beyond the AVX/AVX2-only slow-iron item); `@Vector` width per target, asm-inspected
- [x] NVMe storage profile (the Phase B registered-buffer item, done above): smaller SSTs, parallel compaction, registered buffers + fixed files — selected by `--storage-profile hdd|ssd|nvme|auto`
- [ ] Resident-first: full-res hot data over aggressive compression; compression stays for cold SSTs, off the hot path
- [ ] Acceptance: same bench trio as slow big-iron (tick p99, `get` p99 at 50 SSTs, gen ms/chunk) on a representative box — numbers decide which profile wins

### Apple Silicon (M-series — P/E cores + Metal, no native Vulkan)

- [ ] `aarch64-macos` build target in the CI matrix (see Observability); P/E-aware pinning via `sysctl`/QoS classes instead of Linux `/sys` + `pthread_setaffinity_np` (Phase C pinning is Linux-specific today)
- [ ] GPU via MoltenVK (Phase G3); CPU-only fully supported
- [ ] Acceptance: E2E passes on one M-series box, CPU + MoltenVK modes, bench checked in

### Windows hosts (many real operators run them)

- [ ] `x86_64-windows` build in CI (the backend cross-compiles clean today: `src/net/iocp.zig` + Windows-gated wiring, 23/23 steps); IOCP runtime verification + service packaging (run as a Windows Service) + firewall/ops notes in README with thread-pool blocking as the documented fallback including its scale limits
- [ ] Acceptance: E2E passes on Windows, IOCP + blocking modes

### Low-end ARM SBCs (Pi 4/5 — tiny RAM, SD cards)

Phone-adjacent but distinct: the storage is random-write-hostile and wear-limited,
and the RAM budget is smaller than a phone's.

- [ ] SD-card storage profile: aggressive WAL batching, minimal write amplification — the opposite of the HDD profile (`--storage-profile sd`)
- [ ] Tiny-RAM tier below the phone target: smaller block cache + sent-set caps, RSS measured against a 1GB/2GB budget
- [ ] Acceptance: E2E passes on a Pi with RSS + write-amplification numbers checked in

### Cloud/VPS (contended vCPU, network-attached disks — assume hostile hardware)

- [ ] No pinning assumptions: pinning can hurt under a hypervisor — detect steal time / vCPU migration and degrade to unpinned + load-shedding (the Phase C breaker does the work, this wires the signal)
- [ ] Snapshot-to-object-storage next to the SST file-level snapshot item (Phase E)
- [ ] Acceptance: E2E + 200-bot soak on a 4-vCPU VPS with neighbor noise; tick p99 recorded, no tuning that assumes bare metal

### Protocol correctness (1.7.10 is full of quirks — verify each against a real client before calling done)

- [ ] Real-client compat harness: scripted 1.7.10 client session (status→login→move→place→break→chat→disconnect) with packet log diffed against vanilla server behavior; check in logs/specs, not binaries
- [x] Slot/inventory *parsing* (`Slot_Data` id/damage/NBT-skip for creative + placement) — done in A3; NBT-preserving *storage + encoding* done via canonical `item.Stack` + `v5/slot.zig` (creative give, click handling, Set Slot `0x2F` / Window Items `0x30` all round-trip NBT verbatim, live-verified; unit + golden coverage in `packets.zig`/`conn.zig`)
- [x] Living-entity metadata encoder (index 0/1/6 + `0x7F` terminator) used by `0x0C`/`0x0F`/`0x1C` — done in A4
- [ ] Multi Block Change `0x22` record packing (4-bit meta + 12-bit id + Y + Z + X nibble layout)

### Security / robustness

- [x] RSA key file 0600, gitignored
- [~] Attack/use-entity validation (`0x02` Use Entity implemented with 6-block reach check, melee damage table, mob/player health + death + Destroy broadcast, respawn via Client Status 0 — all live-verified; optional ~200ms hitbox history for high-ping fairness later). Scoped to hit validation only — no full rollback, no client reconciliation (1.7 protocol can't do it). Packet first, history later, both measured
- [x] Rate limits: login attempts/IP (5 joins/10s, see L8) + block-place rate (32/s, same spam kick as chat) done; chat rate pre-existing. Still open: per-IP connection rate limiting at accept (SYN-flood shape, before handshake).
- [ ] Username/chat validation everywhere (charset + length; chat JSON validated — vanilla disconnects on malformed)
- [ ] Decompression bomb guards on any client-controlled zlib (chunk packets are server→client today, but future-proof the limit)
- [ ] Online-mode session cache (avoid Mojang roundtrip per relog; TTL + negative cache)
- [~] Fuzz tests: `zig build test-exploit -Dmc=1.7.10` now runs the C9 seed corpus for ZC1, NBT, Anvil, framing, VarInts, slots and ZPLR (also part of `zig build test`). The `std.testing.fuzz` targets are present, but this Zig 0.16.0 install cannot compile its own `compiler/test_runner.zig` in `--fuzz` mode (`writeStackTrace` StackTrace type mismatch), so the fuzz lane stays open until the toolchain is fixed. Next: expose an SST structural-validation seam and fuzz it, then add a fuzz smoke job after the runner works.

### Observability + ops

- [ ] `server.toml`/JSON config file (currently CLI flags only): motd, ports, view distance, online mode, db path, tick budget, log level
- [~] Structured logging levels (currently `std.log.info` ad hoc) + per-tick stats line: the stats line exists (Phase D: `stats tick_p50=… out_p50=… players=… rss=… outbox=… ents=…` every 10 ticks) but the tick histogram is a 256-sample rolling window, not a proper histogram, and the SST count is not in the line yet
- [~] Metrics endpoint or in-game `/tps`: `/tps` done (tick p50/p99 + counts, console + players). Still open: HTTP metrics endpoint.
- [ ] Benchmarks: `zig build bench` (codec roundtrip, chunk encode, LSM put/get, tick) — required before any Phase D/G claim
- [ ] CI: `zig build test` + `zig build` (ReleaseFast) + fuzz smoke on every change; pin Zig version in README (currently 0.16.0). Build matrix: `x86_64-linux` (baseline), `aarch64-linux-musl` (static, Termux/Linux phones; `aarch64-linux-android` only if Bionic issues appear), `aarch64-macos`, `x86_64-windows`

### Tech debt already known (grep these)

- [x] `serveConn`/`feedData`/`queueRaw` per-feed heap dupes → arena slices (Phase D): the decrypt/encrypt copies use the per-conn scratch arena (`src/sim/arena.zig`), reset after every use
- [x] `Conn.out` unbounded growth → backpressure cap (Phase B): `config.out_cap_bytes` (default 4 MiB, `--out-cap`); an overflowing conn is dropped
- [ ] `ShardPool` fixed 4 shards at open in `main` — make shard count = f(threads), document migration when changed
- [ ] `Mock` statics in `conn.zig` online test — isolate if tests ever run parallel
- [ ] `frameMapChunkBulk` OOM guard verified only by construction — add oversized-column rejection test
- [ ] `anvil_dump`/`anvil_import` are import-path only — ensure they never become runtime paths (CI lint: `world/anvil` not imported outside tools; chunk conversion called only through `world/import/anvil.fromAnvilNbt`)
