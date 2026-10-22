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
- [x] 283/283 `zig build test` green (21/21 steps; was 184/184 — count the real number when touching this line)

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
- [x] Lighting (subtractive sky + block-light flood): shared `chunk.lightOpacity`/`emitLight` tables; gen computes column skylight (leaves 15→14, ice 15→12, opaque→0; water stays transparent) + BFS block light (torch 14, lava 15, ...) at gen time; edits relight (stale nibbles were the "light only fixes on re-enter" bug); horizontal sky spread + cross-chunk bleed remain documented approximations
- [x] Cactus contact damage: 1.0 per touch throttled to ~1/0.5s (`cactus_cd`), survival/adventure only (was: harmless)
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
- [x] Spam throttle: 750ms min gap, `Kicked for spamming` disconnect on violation (unit + live verified)
- [x] Login timeout: conns stuck in handshake/login dropped after 30s of no progress (login state gets `0x00` disconnect + close; handshaking/status just closed — no disconnect packet exists in those states). Verified live: handshake-only conn gets clean EOF at ~31s
- [x] Disconnect audit: all paths use JSON reason with the right packet — `0x00` in login, `0x40` in play, keepalive timeout `0x40 "Timed out"`, login timeout `0x00`. Ticker shuts the socket down (unblocks serve loops); close happens exactly once in serveConn's defer
- [x] Acceptance, all live with echoing clients: broadcast reaches sender + others with byte-exact vanilla-style JSON (unicode preserved, not `\uXXXX`-escaped); spam → `0x40`; invalid UTF-8 → silent drop; idle handshake → clean drop at 30s
- [ ] Follow-ups: per-IP connection rate limiting, RCON (remote) kick, chat reporting/muting hooks for the mod API (F)

### A6. Player persistence + permissions + commands ✅ (done, live-verified)- [x] LSM-backed player rows (`src/sim/players.zig`): `ZPLR` v4 binary (pos/yaw/pitch, spawn, health/food/saturation, 45-slot NBT-verbatim inventory + cursor + selected + gamemode + xp level/total/bar + spawn_forced; v3 rows decode with xp/spawn_forced defaults, v1/v2 rejected as wire-id rows), key `encodeKey(255, Wyhash(name))` with stored-username mismatch guard; corrupt rows treated as fresh spawn (overwritten on next save)
- [x] Save triggers: disconnect (`unregister`), in-game `/save-all`, console `save-all`, ticker autosave every 300 ticks (WAL-durable; save-all/stop flush SSTs). Load on login (conn.lock held): restores pos/health/inv/cursor/selected/gamemode, skips land-spawn search; dead-at-save normalizes to alive-at-spawn on load
- [x] Login inventory sync: full Window Items `0x30` + cursor Set Slot after chunk burst; PosLook now sends actual player pos (fresh logins land at found spawn via pos sync — burst center + PosLook consistent)
- [x] Permission model (`src/sim/permissions.zig`): op levels 0-4 + per-player node grants/denies in one LSM row (`ZPRM` v1, dim 254), deny-beats-grant-beats-level, `.*` wildcards, console implicitly 4, secure default (no ops → console only). Player-name matching is case-insensitive throughout (vanilla `UserList` folds: `/op Alice` covers login `alice`, target lookup + `/perm show` too — the "opped but every command unknown" class of bug). Denied and unknown commands share one reply (no oracle); `/help` filters to usable commands; validated names/nodes everywhere
- [x] Session integrity: duplicate-login kick ("You logged in from another location!", vanilla) flushes + shuts the ghost down so it unregisters promptly; per-player save epochs (`bumpSaveEpoch`/`saveEpochCurrent`) drop stale saves on quit/rejoin races and ghost autosaves; name-targeted commands skip kicked/dying conns (first-match `findInSnap` used to route at the ghost — the "gamemode not saved" class of bug)
- [x] Default world folder is `world` (vanilla name; `"db": null` disables persistence)
- [x] Commands: full vanilla 1.7.10 dedicated roster (48 commands in vanilla registration order) + `perm` extension. Spec-driven defs (`src/cmd/spec.zig`): usage strings, argument parsing, and tab-completion all derived from one typed spec per command (comptime-rendered usage; `usage_override` only for the few vanilla texts the generator cannot spell). Jar-verified usage strings/messages/perm levels/aliases (`?`, `w`, `msg`); admin feedback to fellow ops as gray-italic `[Name: msg]`; vanilla tab-complete (`0x14`->`0x3A`: case-insensitive, perm-filtered, aliases, per-command dynamic sets for items/gamerules/mobs/enchants) with non-slash player completion and unknown-command suppression. Systems: name/IP bans + whitelist + login gates (jar-hardcoded screens), 9 gamerules (doDaylightCycle/keepInventory live), weather w/ countdowns + S2B, difficulty/default-gamemode, XP (vanilla formulas, level-up chime, ZPLR v4), effects (S1D/S1E + ticker expiry), ench NBT (hand-merged list, canApply/cantCombine tables), summon, setblock/testforblock (replace/keep/destroy + drops + S28), testfor (command-block-only), spreadplayers (vanilla iterations + teams), playsound (hearing check), scoreboard (objectives/players/teams/slots + S3B-E), achievements, save-on/off, idle kick, debug, seed, kill, publish (dedicated-fail), netstat. Bootstrap via repeatable `--op <name>`. Operator stdin console unchanged
- [x] Acceptance, live over TCP: permission gating (deny==unknown, grant/deny/wildcard, op/deop + notify); full gameplay loop (gamemode flags, give slots/damage, tp PosLook + chunks, time set/add/day, gamemode persist across restart); restart persistence (pos + staged dirt + perms matrix); inventory E2E still green
- [x] RCON remote console (`src/net/rcon.zig`): vanilla-style Source framing (LE length/id/type + double-NUL), password auth with constant-time compare, fail-closed without `--rcon-password`, 3-strike auth cap, no-auth/oversize/unknown-type → close, single-packet truncated replies. Full console authority (all 14 commands incl. `/stop`, which saves + flushes + exits after the reply flushes). `--rcon-password` (short-password warning) / `--rcon-port` (default 25575); password never logged (localhost/SSH-tunnel posture documented)
- [x] Acceptance, live: RCON auth/id-echo, no-auth close, 3-strike cap, roster/save-all/op/perm/unknown round-trips, oversize/unknown-type close, game conn undisturbed; in-game `/stop` (reply flushes, exit 0) + console `stop` re-verified after the executeCommand refactor
- [x] Playerdata migration tooling: `player_import <player.dat> <db> <name>` (gzip-NBT → ZPLR row, with human-readable summary + warnings) and `player_dump <db> <name>` (row inspection incl. NBT byte counts); `build.zig` gains `player-import` / `player-dump` steps + test targets
- [x] Acceptance: real `player.dat` from the official 1.7.10 server jar (sha256-pinned, checked in as `src/sim/testdata/vanilla_player.dat` with a provenance README) round-trips through import → ZPLR golden asserts (pos, health, food, gamemode, hotbar stone + NBT-named sword, spawn fallback, zero skipped/dropped slots); save/load + console + inventory + RCON E2Es re-verified green on the final binary

---

## Phase J — Survival loop (playability: mining must pay, hunger must bite)

Without this the server is a creative building + chat room: breaking blocks yields
nothing, nobody starves, nothing hunts you. In dependency order (each slice is
independently live-verifiable):

### J1. Block drops + item entities + pickup [~] (implemented + live-verified; vanilla ground-truth sampling in progress)
- [x] Vanilla drop table (`src/sim/drops.zig`: explicit CFR-verified cases — lapis 4-8 dye/4, redstone 4-5, gravel flint 1/10, leaves sapling 1/20 (jungle 1/40) + apple 1/200 oak/dark-oak, stone→cobble, ore items, clay 4, glowstone 2-4, melon 3-7, double-slab 2, tallgrass/deadbush seeds 1/8, glass/ice/bedrock nothing, meta-preserving default; fortune/silk excluded by design — no enchants yet)
- [x] Spawn Object `0x0E` (type 2, data 1, velocity iff data>0) + full watcher `0x1C` (`[(0:B),(1:S=300),(10:slot)]` per EntityTrackerEntry `my.b` + Entity init CFR) + `0x0D` collect (i32 pair, collected first) framing (roundtrip unit tests; minecraft-data 1.7 + `fw`/`ij` decompiles)
- [x] Item entity sim (server-owned list under ent_lock, cap 256): 10-tick block-drop delay, 40-tick Q-drop delay, 6000-tick despawn, vanilla xk merge (bigger absorbs, max delay, min age), magnet pickup (spawn-visible-first, all-or-nothing grant in vanilla order, Set Slot + Collect + Destroy, tick-local claims, rebroadcast to trackers)
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
- [x] Matcher (`src/sim/recipes.zig`): shaped slide+mirror, shapeless multiset, repair (maxDur formula, generated per-item table from minecraft-data names x jar-verified material enums), NBT-copy flag
- [x] 2x2 player grid live in window 0 (result recompute on grid change, take consumes, shift craft-all, 0x10 rejects slot 0)
- [x] Container window 1 (crafting table): right-click opens 0x2D type 1 + full 0x30, sneak bypass places instead, click routing incl. shift/number, 0x0D close drops grid, table-break force-closes viewers + drops + 0x2E
- [x] Acceptance, live E2E: 2x2 planks take, table open, 3x3 pickaxe take, close drops, break-close ack, sneak bypass (fresh-DB runs; note: E2E reruns on a dirty DB can desync — restart server per run)
- [x] J3b furnace (`src/sim/furnace.zig` tick/canSmelt ported from CFR `apg.h/k/j` + `src/sim/smelting{,_data}.zig` burn/result tables; 20-tick quanta at 1Hz): window-2 open/click/close routing, lit/unlit 61/62 swaps, per-viewer 0x30 + 0x31 (cook/burn/total) sync, shift/number-key moves, break drops contents + 0x2E, entity leak fixed (removeFurnace wired)
- [x] Acceptance, live E2E vs vanilla 1.7.10 reference (cold-start: ignite 61->62 + fuel-1 + burn/total 1600, cook +20/tick, output at 200, take/park, burnout 62->61 + cook freeze, shift/number moves, break-close + drops; vanilla 0x0E clicked-item = pre-click slot, match = silent accept + client-applies-locally, mismatch = confirm-0 + resync + container blacklist — asteorite validates action-seq instead, compatible with real clients)
- [x] 283/283 `zig build test` green (21/21 steps; was 184/184 — count the real number when touching this line)

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

### K1. Block-tick scheduler + redstone circuits (the foundation)
- [ ] Scheduled-tick queue (vanilla `scheduleBlockUpdate` semantics): per-position dedupe (reschedule replaces), ticker drains with a per-tick budget (anti-lag-machine; the Phase C breaker counts this load per region). Powers repeater delays, button timers, torch burnout, lamp updates.
- [ ] Power model: strong/weak power 0–15 per face, recomputed never stored (component state lives in id/meta as vanilla does); neighbor-change fan-out to 6 neighbors + diagonal wire, budgeted, recursion-capped.
- [ ] Components in order: wire (placement shape, 1/block falloff), torch (inverter + vanilla burnout: N rapid toggles → 160-tick burnout, golden-tested), lever/button (stone 20-tick / wooden 30-tick pulses via scheduler), pressure plates (stone vs wooden detection sets over entity AABBs), doors/trapdoors/fence gates (open/close + `dig.*`/click sounds), lamps (on/off id swap drives the A3 relight path), redstone-ore lit/unlit swap on touch (lit emits 9 — already in `emitLight`).
- [ ] Follow-ups (explicitly not this slice): pistons (block pushing), comparators, note blocks, dispensers/droppers (needs a dispense-behavior table; shooting TNT/arrows ties to K4/J4).
- [ ] Acceptance, live E2E: lever→wire(15)→lamp on/off; torch inverter + burnout lockout; button pulse length in ticks; repeater 1–4 delay settings; lamp toggle visibly relights; update storm (clock loop) stays under tick budget.

### K2. Brewing + potions
- [ ] Brewing-stand window (type 5) on the J3b pattern: 3 bottle slots + ingredient (1.7.10 has no blaze-powder fuel — time only, 400 ticks, progress on window property 0 via the same `0x31` path as the furnace).
- [ ] Potion item model: vanilla 1.7.10 damage-value table as checked-in data + unit tests (mirrors the `smelting_data` convention); splash bit; display names.
- [ ] Brewing chain as data: nether wart → awkward, effect ingredients, glowstone/redstone modifiers, gunpowder → splash, fermented-spider-eye corruption; ingredient consumed, bottles convert in place.
- [ ] Drinking: Use-Item path (32-tick consume) → effect via the A6 `/effect` infra + glass bottle back; splash: Spawn Object type 73 (verify against proto.yml), direct-hit full effect + AoE falloff on impact.
- [ ] Acceptance, live E2E: awkward→swiftness brews in 20s with progress bar; drink applies Speed (S1D visible, ticks down); splash entity arcs and applies on impact; recipe-table unit goldens for the full chain.

### K3. Enchanting table
- [ ] Table window (type 4) on the J3b pattern: item slot only (1.7.10 has no lapis cost), 3 level options; bookshelf counting (15 max, vanilla air-gap rule) gates the 30-level option.
- [ ] Outcome RNG: vanilla enchantability + weighted-draw algorithm, deterministic under a fixed seed — golden-tested (reuses `cmd_data` max-level/canApply/exclusion tables and the `/enchant` NBT merge; `/enchant` stays as the operator override).
- [ ] XP deduction through the existing XP/level infra (A6).
- [ ] Follow-up: anvil combine/repair UI (can reuse the J3 repair matcher + XP cost rules).
- [ ] Acceptance, live E2E: 15-shelf setup offers 30; same seed → same outcome as the golden; applied enchants visible in NBT; XP levels deducted; insufficient levels reject with the vanilla screen text.

### K4. TNT + optimized explosions
- [ ] Primed TNT entity (Spawn Object type 50), 80-tick fuse, gravity/drag on the J1 entity-motion path; ignition via K1 redstone power and flint-and-steel Use-Item action (shared with K2 drinking); fire-spread ignition deferred (no fire-spread sim yet — say so).
- [ ] Explosion core, batched (the "optimized TNT" design): one 16³-raycast exposure pass per blast (vanilla attenuation by blast resistance), per-tick update budget with a chain queue (no recursion, chained TNT never skips ticks — closes the G1 acceptance item), single collect-then-apply block pass; drops through the J1 pipeline at the vanilla size-scaled chance; entity damage with exposure falloff + knockback; S27 Explosion packet (pos + radius + records) + `random.explode` S29.
- [ ] Chain reactions ride the same queue; per-region load counted by the Phase C breaker; GPU raycast stays a Phase G1 job only after this CPU reference proves out with goldens.
- [ ] Follow-ups: creeper/ghast-fireball variants on the same core.
- [ ] Acceptance: fuse→S27→crater matches a vanilla raycast golden on flat stone; 64-TNT chain clears with zero skipped ticks (timing logged); drops + damage + knockback live-verified over TCP.

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
- [ ] Death messages (`<name> was slain by …`, `… fell out of the world`) broadcast on death + void damage below y=-64.
- [ ] Spawn protection (16-block, op-bypassed, vanilla radius) + sleeping in beds (skip-night vote + spawn set) + hardcore world flag.
- [ ] Presentation sweep: S2A particle packet (potion splash, crits, note smoke — K2/K4/L3 consume it), remaining S29 voices (hurt, eat, splash, explode is K4, doors), server-list favicon.
- [ ] Command blocks (redstone-powered command execution via K1 power + existing dispatch; `testfor` already hardcodes its message).
- [ ] Acceptance: query responds to GameSpy packets; death by creeper prints the vanilla line; non-op can't break spawn; all sleepers → dawn; hardcore death bans (vanilla SMP rule).

---

## Phase B — Network: async zero-copy (`io_uring` on Linux, per-OS backends elsewhere)

Current state: thread-per-conn blocking I/O (`src/net/server.zig`) with a
per-conn output ring flushed per frame batch. The `Conn` interface stays;
only transport changes (as documented in `server.zig`).

- [ ] One `io_uring` ring per worker thread (not per connection): multishot accept (`IORING_OP_ACCEPT` multishot where available) + multishot recv with provided buffers (`IORING_OP_RECV` + buffer rings — required, kernel can't borrow user memory between multishot events)
- [ ] `SEND_ZC` (zerocopy send) gated behind size threshold (~8KB: chunk bulks yes, chat/keepalive no — copy is cheaper for small frames)
- [ ] Tick-aligned flush: accumulate per-player output during the 50ms tick, single `writev`/batched-send at tick end (`Conn.takeOutput` already returns owned slices — hook the tick loop, stop flushing per frame batch in `serveConn`)
- [ ] Backpressure: per-conn cap on queued bytes (kick on overflow — slow-consumer protection, critical once bulks flow)
- [ ] TCP_NODELAY + socket buffer tuning behind flags
- [ ] Fallback path: keep blocking transport behind a `--transport blocking|uring` flag (matches Zig 0.16 reality: `std.Io.Evented` is still experimental — raw `std.os.linux.IORING_*` is the way, not `std.Io`)
- [ ] Per-OS backends behind one transport interface: Linux `io_uring` (primary, above); macOS `kqueue` non-blocking; Windows IOCP, falling back to the thread-pool blocking transport with documented scale limits. `--transport` gains per-OS values (`auto|uring|kqueue|iocp|blocking`); `Conn` interface unchanged
- [ ] NVMe storage path (distinct from net): `io_uring` registered buffers + fixed files for SST reads; complements the HDD-aware profile (slow big-iron) with the opposite tuning — smaller SSTs, parallel compaction
- [ ] Acceptance: 500 idle + 100 moving bot conns, p99 tick flush < 2ms, `strace` shows batched syscalls (no per-packet `writev`)

## Phase C — Concurrency: region threading (Folia-style)
Current state: `tickOnce` is sequential; `ShardPool` shards storage; MPSC exists but isn't wired to movement.

- [ ] Grid sharding: `32x32`-chunk regions owned by worker threads (`src/sim/tick.zig` owns the registry; one region = one tick unit, never split mid-tick)
- [ ] Thread pool sized to cores with `pthread_setaffinity_np` pinning, CCX-aware grouping (keep region neighbors on shared L3; document topology detection via `/sys`). On ARM big.LITTLE: prefer P-cores for region tick, park net/IO + compaction on E-cores; detect via `/sys/devices/system/cpu` (`capacity`, `cpu_capacity`); affinity is advisory under Android cpusets — measure, never assume
- [ ] Cross-region handoff: entity/player border crossing pushes `Transfer` into target inbox (wire `playerChunk` changes into this — currently tracked but unused)
- [ ] Per-region 50ms budget with overrun accounting (exists) + global tick barrier for time-of-day/weather sync only (never a global world lock)
- [ ] Per-region load-shedding (circuit breaker): if a region's p99 tick >15ms over N ticks, degrade that region only — halve mob AI rate, skip particle/leaf block ticks, defer entity LoS queries; recover automatically when clear; expose a `region_shed` counter in the stats line. Lag machines must cost a region, never global TPS
- [ ] Deterministic tick order within a region; out-of-order delivery across regions is fine
- [ ] Acceptance: spread 200 bots across 8 regions on 8 cores — linear tick scaling vs single-thread, zero data races under ThreadSanitizer-equivalent review + stress test

## Phase D — Memory + CPU fast paths

- [ ] Slab allocator for entities/block entities (fixed-size, contiguous), per-tick arena reset for transient tick data (replaces per-feed `allocator.dupe` in `feedData`/`queueRaw` — profiled hot)
- [ ] SoA entity store / minimal ECS: contiguous pos/vel/AABB arrays; prefetcher-friendly tick (A4's mob/player tracking is AoS today — migrate it, never add new AoS stores)
- [ ] SIMD fast paths with Zig `@Vector`: entity integration `pos += vel*dt`, AABB overlap tests, VarInt/stream scanning — scalar-first with benchmarks, vectorize the top 2 via profiling. Must compile to NEON on aarch64 (inspect asm on both targets); byte-stream parsers are mostly branch-bound, so never assume a vector win — measure
- [ ] Memory budget (phone claims stay measured, not promised): record RSS on fresh DB + 1 player (`/usr/bin/time -v`), set an explicit target (e.g. <100MB P1, squeeze later); per-subsystem accounting (LSM block cache, sent-sets, output rings) in the stats line
- [ ] Seqlocks for read-heavy shared state (config, time-of-day, player count for status) so region threads never block on a mutex
- [ ] Acceptance: `zig build bench` tick micro-benchmarks (entity tick ns/entity, AABB queries/s) with before/after numbers in comments

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
- [ ] CPU light propagation (vanilla BFS reference — the current `gen.zig` skylight is a 15/0 column stub and block light is never written, so clients see a binary lightmap and caves are pitch black): skylight flood fill from the surface with vanilla opacity/attenuation (not the 15/0 column hack), block-light BFS from emissives (lava/glowstone/torches/furnace-lit) with vanilla emission tables; incremental relight on the `view.applyBlock` path (never a full re-flood per edit). Must stay scalar — branchy BFS like noise sampling, same H5 rule; GPU (G2 light passes) only after the CPU reference proves out with goldens
- [~] Acceptance: fresh DB → login shows terrain ✅, F3 biomes sane ✅ (voronoi biomes on the wire), same-seed parity ✅ per-stage (biomes, density, fill, surface, carve, full-pipeline bit-exact); ores ✅ / trees ✅ present (live-verified: 249-353 ore blocks/chunk, logs+leaves in forest chunks); decorator positions differ from vanilla (documented approximation, structures/lakes/dungeons are future work); lighting is subtractive-sky + block-light flood at gen and on edits (horizontal spread + cross-chunk bleed remain approximations); boot pre-gen parallelized (81 chunks 8.9s → 2.3s on 4 workers, Debug), serve path never blocks on gen (holes + capped sequence-gated retry with outbox backpressure)

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
- [ ] NVMe storage profile (pairs with the Phase B registered-buffer item): smaller SSTs, parallel compaction, registered buffers + fixed files — selected by `--storage-profile hdd|ssd|nvme|auto`
- [ ] Resident-first: full-res hot data over aggressive compression; compression stays for cold SSTs, off the hot path
- [ ] Acceptance: same bench trio as slow big-iron (tick p99, `get` p99 at 50 SSTs, gen ms/chunk) on a representative box — numbers decide which profile wins

### Apple Silicon (M-series — P/E cores + Metal, no native Vulkan)

- [ ] `aarch64-macos` build target in the CI matrix (see Observability); P/E-aware pinning via `sysctl`/QoS classes instead of Linux `/sys` + `pthread_setaffinity_np` (Phase C pinning is Linux-specific today)
- [ ] GPU via MoltenVK (Phase G3); CPU-only fully supported
- [ ] Acceptance: E2E passes on one M-series box, CPU + MoltenVK modes, bench checked in

### Windows hosts (many real operators run them)

- [ ] `x86_64-windows` build in CI; IOCP backend (Phase B) with thread-pool blocking as the documented fallback including its scale limits
- [ ] Service packaging (run as a Windows Service) + firewall/ops notes in README
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
- [ ] Rate limits: login attempts/IP, chat rate, block-place rate (creative spam = chunk rewrite storm → LSM pressure)
- [ ] Username/chat validation everywhere (charset + length; chat JSON validated — vanilla disconnects on malformed)
- [ ] Decompression bomb guards on any client-controlled zlib (chunk packets are server→client today, but future-proof the limit)
- [ ] Online-mode session cache (avoid Mojang roundtrip per relog; TTL + negative cache)
- [ ] Fuzz tests: `zig build test --fuzz` on VarInt/framing/NBT/SST parsers with malicious inputs (frame-too-large already guarded; extend to all decoders)

### Observability + ops
- [ ] `server.toml`/JSON config file (currently CLI flags only): motd, ports, view distance, online mode, db path, tick budget, log level
- [ ] Structured logging levels (currently `std.log.info` ad hoc) + per-tick stats line (tick ms p50/p99, players, regions, SST count)
- [ ] Metrics endpoint or in-game `/tps` equivalent (tick histogram from existing overrun counters)
- [ ] Benchmarks: `zig build bench` (codec roundtrip, chunk encode, LSM put/get, tick) — required before any Phase D/G claim
- [ ] CI: `zig build test` + `zig build` (ReleaseFast) + fuzz smoke on every change; pin Zig version in README (currently 0.16.0). Build matrix: `x86_64-linux` (baseline), `aarch64-linux-musl` (static, Termux/Linux phones; `aarch64-linux-android` only if Bionic issues appear), `aarch64-macos`, `x86_64-windows`

### Tech debt already known (grep these)
- [ ] `serveConn`/`feedData`/`queueRaw` per-feed heap dupes → arena slices (Phase D)
- [ ] `Conn.out` unbounded growth → backpressure cap (Phase B)
- [ ] `ShardPool` fixed 4 shards at open in `main` — make shard count = f(threads), document migration when changed
- [ ] `Mock` statics in `conn.zig` online test — isolate if tests ever run parallel
- [ ] `frameMapChunkBulk` OOM guard verified only by construction — add oversized-column rejection test
- [ ] `anvil_dump`/`anvil_import` are import-path only — ensure they never become runtime paths (CI lint: `world/anvil` not imported outside tools + `chunk.fromAnvilNbt`)
