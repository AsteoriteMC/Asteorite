# Shared core vs per-version profiles

Status: architecture research, 2026-10-22. C0 (profile contract, import gate
and scoreboard data seam) and C1 (canonical ZC1/player storage with import-only
wire translation) are implemented; no gameplay or packet behavior changed.
C5-C8 extraction is complete; C9/C10 remain as ongoing growth work.

Related: [`MULTIVERSION.md`](MULTIVERSION.md) defines the compile-time
profile seam (`zig build -Dmc=<version>`), the profile contract and the target
ladder. This document answers the next question:

> Which systems can be the same source across every Minecraft version, so we
> do not duplicate code and can patch bugs/exploits in one place?

The short answer:

> **Share every decision that is not a byte.** Simulation rules, state
> transitions, security invariants, scheduling, persistence and authorization
> belong to one canonical core. Packet layouts, registries, chunk encodings,
> world generation, UI slot layouts and genuinely changed mechanics belong to
> the version profile.

“The same” does not mean “identical behaviour everywhere”. It means one source
file, with version differences expressed as data, rules or a named strategy
hook. A profile is allowed to select a different implementation when the
algorithm itself changed; it is not allowed to copy a shared algorithm and
diverge quietly.

---

## 1. The three layers

```
┌──────────────────────────────────────────────────────────────────────┐
│ profile edge (src/proto/v*, src/versions/*)                          │
│ bytes <-> semantic actions/events; packet framing, IDs, layouts      │
├──────────────────────────────────────────────────────────────────────┤
│ profile data and rules (src/game/*, profile.rules)                   │
│ registries, tables, slot layouts, block properties, capability flags │
├──────────────────────────────────────────────────────────────────────┤
│ canonical core (src/sim, src/world, src/cmd, src/net core)           │
│ state machines, algorithms, invariants, scheduling, storage, authz   │
└──────────────────────────────────────────────────────────────────────┘
```

A good profile edge is boring: it translates bytes and layouts. It does not
decide whether a player may break a block, whether an inventory transaction
conserves items, whether a command is permitted, or whether a movement delta
is legal. Those decisions live in the core and are therefore fixed once for
every profile.

A good profile data module is also boring: it contains values and tables
(IDs, names, numbers, layouts) and, at most, small hooks whose contract is
owned by the core.

The core must never contain `if (protocol >= N)`. If a version differs, the
profile supplies a rule value, a table, or a separate implementation selected
at the profile root. This is the same dependency rule already written in
`MULTIVERSION.md` section 6.

---

## 2. How to decide whether to share

Ask these questions in order:

1. **Is it a security or conservation invariant?**
   (permissions, reach, movement bounds, inventory conservation, rate limits,
   world bounds, visibility, authentication.)
   → **Always core.** A profile may supply the numbers, never the check.

2. **Does only the representation change?**
   (packet IDs and field order, slot layout, chunk wire format, registry names,
   NBT/component encoding.)
   → **Profile edge.** Keep one canonical semantic model in the core.

3. **Does the algorithm stay the same but the data change?**
   (block hardness, stack size, food values, recipes, loot, mob attributes,
   effect durations, redstone component set.)
   → **Shared engine + profile table.**

4. **Does the algorithm itself change?**
   (pre-1.9 vs 1.9+ combat, 1.18 worldgen, 1.13 flattening, 1.19 secure chat,
   1.20.5 item components.)
   → **Dual implementation selected by the profile**, sharing the helpers that
   did not change. Do not force one algorithm through a forest of flags.

5. **Is it operational machinery?**
   (tick loop, WAL/SST, sharding, RCON, config, logging, metrics, bans.)
   → **Always core.** Versions do not get a vote.

The four labels used below:

| Label | Meaning |
|---|---|
| **S** | Shared entirely; no profile hook. |
| **E** | Shared engine; profile supplies data, rules or narrow hooks. |
| **D** | Dual model: the algorithm genuinely differs; profile selects one implementation. |
| **P** | Profile-owned: bytes, registries, layout or generator. |

---

## 3. What is already shared in this tree

This is not a greenfield proposal. Several important pieces are already
version-neutral, which is why the profile seam can be small.

| System | Current source | State | Label |
|---|---|---|---|
| Region tick loop, 20 TPS budget, load shedding | `src/sim/core/tick.zig` | No protocol imports; owns region scheduling and backpressure | **S** |
| MPSC inbox, worker pool, spin/affinity, arena/slab, seqlock, entity store | `src/sim/core/{mpsc,pool,spin,affinity,arena,slab,seqlock}.zig + sim/entity/entity_store.zig` | No protocol imports | **S** |
| LSM/WAL/SST storage, sharding, io_uring read path | `src/world/{store,shard,uring_io}.zig` | No protocol imports | **S** |
| NBT codec | `src/world/nbt.zig` | Canonical; used by storage and import | **S** |
| Config, permissions, bans, whitelist/ops | `src/config.zig`, `src/sim/player/{permissions,bans}.zig`, command files | Version-neutral today | **S** |
| RCON, TCP transport | `src/net/{rcon,transport}.zig` | Version-neutral | **S** |
| Canonical item stack | `src/item.zig` | `Stack{id,count,damage,nbt}`; no wire bytes | **E** — hardcoded 45-slot/1.7 rules |
| Canonical block/item ids | `src/ids.zig` | Dense append-only 1.7 universe; `wire` maps at the edge | **S/E** — needs 1.8/1.12 appendices |
| Redstone/piston/hopper engine | `src/sim/world/redstone.zig` | Pure sim over a caller-provided world adapter; canonical ids | **E** — reference pattern |
| Crafting, smelting, furnace, drops | `src/sim/world/{recipes,smelting,furnace,drops}.zig` | Pure engines; 1.7 recipe/smelting data tables now in `game/mc5/` | **E** |
| Worldgen stage driver + RNG | `src/worldgen/pipeline.zig`, `src/worldgen/rng/*` | Version-neutral order/context; stages are profile data | **E** |
| Command framework | `src/cmd/mod.zig`, `src/cmd/spec.zig` | Explicitly designed around a version-neutral `srv` backend and per-profile data | **E** |
| Canonical chunk storage | `src/world/chunk.zig` | ZC1 canonical ids; Anvil conversion lives in `world/import/anvil.zig`; runtime module has no protocol imports | **S/E** — ZC2 schema later |
| Player persistence | `src/sim/player/players.zig` | ZPLR v5 stores canonical `ids.Id`; v3/v4 wire rows decode through `world/import/player.zig` | **S** |
| Scoreboard state | `src/sim/player/scoreboard.zig` | Store, validation and persistence are shared; criteria now come from `profile.game` | **S/E after C0** |
| Chunk-view scheduling | `src/sim/world/view.zig` | Spiral/sent-set/hole-heal logic is shared; encoding is v5 | **E** |
| Entity tracking/update planning | `src/sim/entity/entity.zig` | Plan logic is shared; packet calls and raw `u8` mob kinds are v5 | **E** |
| Connection/server/status/main | `src/net/{conn,server,status}.zig`, `src/main.zig` | Tightly coupled to v5 packets, IDs, worldgen and `u8 y` | **P** currently |

One canonical-ID leak remains: `wire.toWire` is total over a 1.7-only enum.
`ZPLR` now stores canonical ids (C1), with v3/v4 wire rows handled only by
`world/import/player.zig`, and `world/chunk.zig` no longer imports proto. The
scoreboard criteria import is a smaller data leak handled by C0 below. The new
point in this document is that the same “canonical in the middle, mapping at
the edge” rule should be applied to *every* shared subsystem, not only blocks
and items.

---

## 4. Decision matrix

The matrix is deliberately grouped by ownership, not by Minecraft release.
A system is placed in the most shared column that is honest.

### 4.1 Always shared (S)

These have no legitimate per-version behaviour. If a profile needs to change
one of them, the change belongs in profile data passed into the core.

| System | What is shared | Why it must not fork |
|---|---|---|
| Tick loop, region ownership, scheduler, load shedding | 20 TPS loop, per-region queues, p99 budget, backpressure | A lag exploit must be contained by one scheduler, not six |
| Storage engine | WAL, SSTables, compaction, key encoding, snapshots | World corruption bugs must be fixed once |
| Sharding and region hand-off | Ownership, MPSC transfer, drain/adopt rules | Cross-region duplication bugs are catastrophic |
| NBT, UUID, VarInt, zlib primitives, math/RNG | Codecs and primitives | A parser bug is exploitable in every version |
| Authentication/session | Mojang `hasJoined`, RSA/AES handshake, username rules, replay checks | Security boundary; versions must not reimplement it |
| Frame length/decompression caps | Max frame length, decompression bomb cap, malformed-frame handling | Same DoS class on every protocol |
| Permissions, ops, bans, whitelist | Nodes, levels, enforcement, persistence | Permission bypass must be fixed once |
| Config, logging, metrics, RCON | Operational surface | No version semantics |
| Connection I/O, timeout/close discipline | Socket read/write loop, framing, backpressure, close/timeout handling | Slowloris and resource leaks are shared |
| Command execution/permission gate | Permission checks, execution context, output routing, selector expansion bounds | Command injection/permission bugs are shared |
| Chat moderation/rate limiting | Length, rate, burst, JSON validation, mute/ban hooks | Spam/exploit policy is server policy, not protocol |
| Inventory transaction validator | Cursor/slot state machine, merge/swap/split, conservation checks | Dupe bugs are the highest-value exploit class |
| Interaction validation | Reach, eye height, line of sight, placement bounds, spawn protection | Reach/placement exploits must be patched once |
| Movement validation | Max delta, teleport rules, flight/ground checks, world bounds | Movement cheats are shared |
| Entity tracking/visibility | Sent sets, enter/leave ranges, despawn, viewer diff | Info leaks and ghost entities are shared |
| Chunk-view scheduler | Spiral order, holes, sent-set, unload diff, priority | Client memory/ghost-chunk bugs are shared |
| Spawn protection, difficulty, gamerule storage | State and enforcement | Bounds checks are security invariants |
| Scoreboard/team/objective storage | Names, criteria, scores, membership, persistence | Mutation bugs are shared |
| Test harness, golden fixtures, fuzz drivers | Test protocol and invariant checks | A fix must be testable on every profile |
| Import/migration framework | Read-only source, validation, target-owned write | Cross-profile corruption must be handled once |

Some rows have a profile-facing *delivery* edge. For example, chat moderation
is shared, but 1.19+ chat signing is a separate profile layer; entity tracking
is shared, but the spawn/metadata packets are profile codecs. That does not
move the decision into the profile.

### 4.2 Shared engine + profile data/hooks (E)

This is where most of the code-volume win is. The engine owns the algorithm
and the invariants; the profile owns the universe of content and the numbers.

| System | Shared engine | Profile supplies | Known deltas / hooks |
|---|---|---|---|
| Block behaviour | Collision/light/hardness/blast/support/replaceability queries; update dispatch | `BlockDef` table: shapes, opacity, emission, hardness, resistance, flammability, tool, drops, path cost, waterlogged flag | 1.13 flattening/waterlogging; 1.18 height; 1.21 new blocks |
| Redstone/pistons/hoppers/observers | Power model, scheduled ticks, update ordering, quasi-connectivity, piston push limit, torch burnout | Component set, per-component rules, block IDs, `RedstoneRules` flags | 1.8 slime blocks; 1.11 observers; 1.13 state-change detection; 1.17 lightning rod; 1.19 sculk sensor; 1.20 calibrated sculk sensor; 1.21 crafter/copper bulb |
| Fluids/fire/explosions | Flow, spread, source conversion, ignition, blast ray/block resistance | Fluid/fire properties, resistance table, explosion power rules | 1.13 waterlogging/bubble columns; 1.16 soul fire; 1.17 lava cauldrons |
| Physics/collision | AABB sweep, gravity, friction, step, water/lava drag, fall distance, knockback base | `MovementRules`: heights, eye height, step, gravity, terminal velocity, water/lava constants; block shapes | 1.8 slime bounce; 1.9 elytra; 1.13 sprint-swim; 1.14 sneak 1.5; 1.18 height; 1.20 camel; 1.21 wind charge |
| Entity AI/pathfinding/spawning | Pathfinder, goal scheduler, attribute map, breeding/anger/schedule framework, spawn/despawn caps | `MobDef`: kind, dimensions, attributes, goal list, spawn rules, loot table, metadata fields | 1.8 armor stands; 1.9 shulkers; 1.14 villager AI/raids; 1.16 piglins; 1.17 goats/axolotl; 1.19 warden/allay/frog; 1.20 camel/sniffer; 1.21 breeze/bogged |
| Combat/damage | Damage pipeline, armor/enchant/potion modifiers, invulnerability frames, knockback, crit/sweep helpers | Combat model selection; weapon/armor tables; damage-type table; enchantment tables | **D** for pre-1.9 vs 1.9+; 1.14 crossbows; 1.16 netherite; 1.19 damage types; 1.21 mace/wind charge |
| Hunger/health/XP/effects | Saturation/exhaustion/regen/XP/effect ticking and stacking | Food values, exhaustion constants, effect registry/durations, potion data | 1.9 saturation regen; 1.11 exhaustion rates; 1.14 suspicious stew; 1.20.5 effect components |
| Crafting/smelting/brewing/anvil/beacon/stonecutter/smithing | Matcher, recipe transaction, fuel/cook/progress, anvil cost, beacon effects | Recipe/smelting/brewing tables, station layouts, material costs | 1.8 lapis enchanting; 1.12 JSON recipes/recipe book; 1.13 datapack recipes; 1.14 stations; 1.16 smithing; 1.20 templates |
| Loot/drops | Roll engine, luck/fortune/silk hooks, pool/entry evaluation | Loot tables, block drop tables, mob drops, tool requirements | 1.9 loot tables; 1.14 mob loot tables; later table additions |
| Item stack semantics | `Stack` identity, max stack, damage, merge, NBT/component validation hooks | Item table; stack limits; component schema; slot/window layout | 1.9 offhand; 1.20.5 data components; 1.21 new item behaviours |
| Container/inventory UI | Transaction state machine, click modes, cursor, quick-move, drag/drop, action-number desync | `ContainerLayout`: slot count/mapping, window type, output/input roles, quick-move rules | 1.9 offhand (45→46); 1.12 recipe book; 1.14 station windows; 1.20.5 components; 1.21 crafter |
| Entity metadata | Semantic fields: health, name, pose, flags, held item, variant | Index/type mapping, optional fields, codec | 1.8/1.9/1.13/1.14/1.17/1.19/1.20 metadata changes |
| Chat/scoreboard/teams/advancements/statistics | State, mutation rules, criteria evaluation, persistence | Packet codecs, criteria list, display slots, number format, IDs | 1.13 Brigadier/teams; 1.19 secure chat; 1.20.3 scoreboard number format |
| Worldgen | Stage driver, RNG discipline, biome-source interface, structure placement framework, chunk dependency graph | Generator stages, biome tables, height, features, structures, surface rules | 1.13 aquatic; 1.18 overhaul; 1.17 caves/biomes; 1.20 archaeology |
| Lighting | Light storage, queue, relight scheduling | Algorithm hook/parameters for pre-1.18 vs 1.18+ | 1.18 light engine and height change |
| Chunk/column model | Canonical sections, biomes, heightmap, block entities, storage codec | Wire codec, palette, section count, height, block-state registry | 1.8 bulk; 1.9 paletted; 1.13 palettes/block entities; 1.14 heightmaps; 1.18 24 sections/biomes |
| World storage/import | ZC1/ZC2 codec, ownership metadata, import driver | Block-state mapping, generator identity, target metadata | ZC1→ZC2; 1.13 flattening; future schemas |
| Commands | Execution, permission gate, argument validation, output routing | Command registry, syntax tree/parser, selectors, data tables | 1.13 Brigadier; per-version command availability |
| Sounds/particles/effects/status | Semantic event model | ID mapping, packet codec | Every version adds/removes IDs |
| Player list/tab/skin | State, ordering, ping, gamemode | Packet codec, profile fields | 1.8+ player-list formats; 1.19.3 player info changes |
| World border/time/weather/difficulty | State and tick logic | Packet codec, gamerule list, defaults | 1.8 world border; 1.16 dimension changes |

The key design rule for this column: **the engine reads a table or a rule
struct; it never reads a protocol number.** The table can be `comptime` and
fully inlined, so this does not imply dynamic dispatch in hot loops.

### 4.3 Dual models (D)

These are the places where “share the algorithm” would be dishonest. Keep the
shared helpers, but make the model selection explicit.

| Model | Why it is genuinely different | Shared underneath |
|---|---|---|
| Combat: legacy (≤1.8) vs cooldown (1.9+) | 1.9 added attack cooldown, shields, offhand, sweeping, and changed armor/knockback; 1.8 is spam-click + sword block | Damage/armor/enchant/potion resolution, reach validation, knockback math, death/drop handling |
| Worldgen: 1.7/1.8/1.12 vs 1.13 vs 1.18+ | Terrain, biome source, carvers, features and height changed at multiple points | Stage driver, RNG contract, chunk dependency graph, structure placement framework, storage |
| Lighting: pre-1.18 vs 1.18+ | 1.18 replaced the light engine and changed height/section assumptions | Light storage, relight queue, chunk model, packet encoding |
| Secure chat: ≤1.18 vs 1.19+ | 1.19 added signed messages, message chains and reporting; 1.19.1 changed what is signed | Rate limiting, moderation, command routing, player identity, chat state |
| Item data: NBT (≤1.20.4) vs components (1.20.5+) | Item identity and validation moved from item-specific NBT to data components | Canonical stack, merge/stack rules, transaction validation, persistence envelope |
| World height/chunk shape: ≤1.17 vs 1.18+ | 1.18+ has negative Y, 384 height, 24 sections and a different chunk payload; the taller world appeared in 1.17 snapshots but was removed before release | Section/column model, storage, bounds checks, view scheduling |
| Configuration phase: ≤1.20.1 vs 1.20.2+ | Login now hands off to a configuration state before play | Connection lifecycle, auth, registry data delivery, timeout/close handling |

A dual model is not a license to duplicate the whole server. It is a named
strategy object (for example `CombatModel.legacy` and `CombatModel.cooldown`)
with a common interface at the semantic boundary.

### 4.4 Profile-owned (P)

These are bytes, registries, layouts and generators. They change per version
and should be generated or written once per profile, never “shared by
accident”.

| Area | Why profile-owned |
|---|---|
| Packet IDs, field order, framing, compression envelope | Directly versioned; a shared body is a bug |
| Login/configuration/play state transitions | 1.20.2+ adds a state; login success shape changed over time |
| Chunk wire encoding | 1.7/1.8 bulk, 1.9 paletted, 1.13 palettes/block entities, 1.14 heightmaps, 1.17 entity extraction, 1.18 sections/biomes |
| Block/item/entity/effect/enchantment/sound/particle registries | Wire IDs and names changed; 1.13 flattening; 1.20.5 components |
| Worldgen terrain/biomes/structures | The generator is the content; 1.18 is a different world |
| Entity metadata indices/types | Reordered and retyped frequently |
| Window/slot layouts and click modes | 1.9 offhand; 1.14 stations; later UI changes |
| Command tree encoding and syntax | 1.13 Brigadier; command availability is versioned |
| Secure chat signing | 1.19+ only; cryptographic and protocol-specific |
| Resource pack/status JSON details | Mostly protocol-shaped; keep metadata in profile |
| Native mod/plugin ABI descriptor | Must be profile-tagged to prevent cross-loading |

### 4.5 A compact answer

If you only remember one table:

| Share entirely | Share engine + tables | Dual model | Profile-only |
|---|---|---|---|
| tick/scheduler | physics/collision | combat ≤1.8 vs 1.9+ | packet IDs/layouts |
| storage/WAL/sharding | redstone/pistons/hoppers | worldgen eras | chunk wire format |
| NBT/UUID/math/RNG | fluids/fire/explosions | lighting pre/post-1.18 | registries/wire maps |
| auth/session/rate limits | AI/pathfinding/spawning | secure chat | entity metadata indices |
| permissions/bans/RCON | combat/damage helpers | item NBT vs components | window/slot layouts |
| config/logging/metrics | hunger/effects/XP | world height/chunk shape | command tree encoding |
| connection I/O/timeouts | crafting/smelting/brewing/anvil/beacon | configuration phase | worldgen stages |
| command dispatch | loot/drops | | block-state properties |
| inventory transaction validator | entity/player tracking | | status/resource-pack details |
| interaction/movement validation | view scheduling | | mod ABI descriptor |
| scoreboard/team state | chat/scoreboard delivery | | |
| spawn protection/bounds | world border/time/weather; world storage/import | | |
| test/fuzz harness | lighting storage | | |

---

## 5. The systems that most deserve a shared seam

The following are the highest-value extractions because they are both
security-sensitive and duplicated by every protocol implementation if left in
`conn.zig` / `server.zig`.

### 5.1 Inventory and container transactions

This is the single biggest exploit-patching win. Item duplication, item loss,
negative stacks, cursor duplication and window desync are all properties of
the transaction state machine, not of the packet layout.

Current state:

- `src/net/conn.zig` owns window-0/1 click logic, cursor, click modes,
  action-number checks and quick-move.
- `src/net/server.zig` owns table/furnace windows and repeats pickup/merge
  rules for the furnace (`applyFurnaceClick`).
- Both operate on the 45-slot array in `Conn.inv`.

Target:

```
src/sim/world/container.zig          // transaction state machine + conservation
src/sim/inventory.zig          // canonical player inventory view
src/game/containers/*.zig      // per-profile layout: slots, window type, roles
```

The profile supplies `ContainerLayout` (slot count, mapping, input/output/
fuel roles, quick-move rules, window ID) and the slot codec. The core supplies
`click`, `quickMove`, `numberKey`, `drag`, `drop`, `creativeSet`, `open`,
`close` and the invariant checker. A protocol handler may only decode a click
and call the core; it may not move stacks itself.

This also fixes the current `45` hardcoding in `item.fillInventory` and
`Conn.inv`: 1.9 adds an offhand slot, 1.14 adds station windows, and future
profiles add more. Layout is data.

### 5.2 Reach, placement, digging and interaction

Current state: `Conn.inReach` uses a fixed 6.0-block sphere and `onDig` /
`onPlace` / `tryOpenTable` / `tryOpenFurnace` each encode their own target
math. The numbers are 1.7 values and the target selection is mixed with
protocol parsing.

Target:

```
src/sim/interaction.zig        // reach, eye height, face offset, line of sight
src/sim/placement.zig          // canPlace, support, collision, protection
src/game/rules.zig             // per-profile reach/eye/height constants
```

The core owns the check; the profile owns `max_reach`, `eye_height`,
`placement_reach`, `world_min_y/max_y`, and protection hooks. Every protocol
gets the same exploit fix. Vanilla has changed reach/eye values and block
placement rules over time, so these are rule values, not literals in `conn`.

### 5.3 Movement validation

Current state: `Conn.handlePlay` trusts the client position after parsing;
`setPos` updates state without a speed/teleport/flight validator. The tick
loop and collision engine are shared, but the network edge does not yet use
them for validation.

Target:

```
src/sim/movement.zig           // validate(delta, state, rules) -> accept/correct
src/sim/physics.zig            // shared collision/integrator (extract from server)
src/game/rules.zig             // max speeds, gravity, step, water/lava constants
```

The profile supplies the packet parser and the constants; the core owns the
decision and the correction/teleport response. This prevents “1.8 has no
elytra check, 1.12 forgot the water speed cap” classes of bug.

### 5.4 Entity tracking and metadata

Current state: `src/sim/entity/entity.zig` has shared `planUpdate`, tracking sets and
viewer reconciliation, but it calls v5 packet functions directly and uses
raw `u8` mob kinds (`MOB_PIG = 90`). Metadata is encoded inside the packet
functions.

Target:

```
src/sim/tracking.zig           // sent sets, ranges, enter/leave, despawn
src/sim/entity_meta.zig        // semantic fields (health, name, pose, item, flags)
src/game/entities.zig          // canonical kind -> profile id; metadata index map
```

The shared tracking algorithm stays; only `spawn(kind)`, `metadata(fields)` and
`destroy(ids)` are profile codecs. This is how a “players see invisible mobs”
or “health update never reaches the client” bug gets fixed once.

### 5.5 Redstone and block behaviour

`src/sim/world/redstone.zig` is the model to copy. It is pure, allocation-free,
canonical-ID based and uses a caller-provided world adapter with `get`/`set`/
`pop`. It already owns the hard part: weak/strong/indirect power, scheduled
ticks, torch burnout, repeater delays, piston rules, quasi-connectivity.

What it lacks is version data:

- 1.8 slime blocks and their entity/block interaction;
- 1.11 observers (and the 1.13 change that observers see all block-state
  changes);
- 1.13 waterlogging/update-order interactions;
- 1.17 lightning rods;
- 1.19/1.20 sculk sensors and calibrated sculk sensors;
- 1.21 crafter and copper bulb.

Those should be component behaviours plus a `RedstoneRules` table
(`quasi_connectivity`, `observer_sees_state_changes`, `piston_push_limit`,
`update_order`, `wire_requires_support`, `torch_burnout`), not a fork of the
engine. A new component is a new module keyed by canonical block ID; it is
not a new `redstone_v340.zig`.

The same pattern applies to fluids, fire, explosions and hoppers: the engine
is stable, the block properties and component set change. A profile table can
be `comptime` and inlined, so this does not cost a virtual call per block.

### 5.6 Physics and collision

The collision/AABB integrator, gravity, friction, step handling, water/lava
drag and fall-distance accounting are shared. The version differences are
parameters and a few behaviours:

- 1.8: slime-block bounce and entity pushing;
- 1.9: elytra flight, shield/offhand (combat), changed boat physics;
- 1.13: sprint-swimming and waterlogged blocks;
- 1.14: sneak height 1.5 (from 1.65);
- 1.18+: negative Y and 384 height;
- 1.20: camel dimensions/mount;
- 1.21: wind charge/mace interactions.

Use `MovementRules` plus a `BlockShape` table. Do not put `if (protocol >=
N)` in the collision code. If a movement mode is genuinely new (elytra),
add a named mode to the shared movement state machine.

### 5.7 Crafting, smelting, brewing, anvil, beacon

The current engines are already pure and table-driven. Keep them. Move tables
to `src/game/legacy` / `src/game/mc*` and add the new station transactions as
containers, not as new crafting engines. The 1.7.10 recipe and smelting data
tables have moved to `game/mc5/`; their shared engines stay in `sim/` until the
remaining C6 tables can move without colliding with active work.

Version notes that are data, not algorithm:

- 1.8 enchanting consumes lapis lazuli;
- 1.9 adds loot tables and changes saturation regeneration;
- 1.11 reduces exhaustion rates;
- 1.12 introduces JSON recipes, the recipe book and advancements/functions;
- 1.13 introduces datapacks and Brigadier;
- 1.14 adds villager trading/workstations, stonecutter, loom, cartography,
  smithing table, grindstone, barrel, smoker, blast furnace, campfire;
- 1.16 adds netherite smithing;
- 1.20 adds smithing templates and archaeology;
- 1.21 adds the crafter.

The engine that matches a shaped/shapeless recipe, consumes inputs, rolls
loot or ticks a furnace does not need to know which release it is. Only the
tables and the container layout do.

### 5.8 Worldgen, chunk and lighting

`src/worldgen/pipeline.zig` already owns the version-neutral stage order
(biome → shaper → surface → carver → features → structures) and the RNG
contract. That is the right seam. The generator stages are profile-owned:
1.13 aquatic generation, 1.18 terrain overhaul and 1.20 archaeology are
different content, not different pipeline plumbing. The release decisions
already recorded in `MULTIVERSION.md` apply: 1.8.9 may use a 1.7-derived
generator with a documented parity gap, but 1.12.2 requires its own
`worldgen/v340`; the 1.7 generator is not a parity substitute.

Similarly, `src/world/chunk.zig` is the canonical in-memory/storage model.
C1 split Anvil conversion into `world/import/anvil.zig`, which is now the only
chunk-side module that imports the v5 wire map; the runtime chunk module has no
protocol dependency.

Chunk wire codecs are profile-owned and are the largest per-version code.
Keep the shared column model and the golden fixtures; never let the wire
layout leak into `sim/view`.

Lighting is a dual model: share light storage, the relight queue and the
chunk model; select the pre-1.18 or 1.18+ algorithm in the profile. The
height/section count is a profile rule, not a `u8 y` assumption.

### 5.9 Chat, scoreboard, commands and UI state

The state machines are shared; the delivery is not.

- Chat: shared rate limiting, length validation, moderation and command
  routing. 1.19+ adds a signing layer (`D`), not a second moderation system.
- Scoreboard/teams: shared objectives/scores/teams and validation. Profile
  supplies display slots, criteria data, packet codec and the 1.20.3 number
  format.
- Commands: the current `cmd/mod.zig` design is already correct — command
  files are version-agnostic and talk to a backend. Keep that rule. 1.13
  Brigadier changes the parser/tree encoder, not the command implementations.
- Player list, tab, boss bar, world border, sounds/particles: shared state,
  profile codec.

### 5.10 Persistence and import

Player/world persistence must be canonical before profiles can share data:

- `ZPLR` v5 stores canonical `ids.Id`. The v3/v4 reader maps legacy wire ids
  through `world/import/player.zig`; v1/v2 rows are reimported from
  `player.dat` instead of guessed.
- `ZC1` stores canonical ids; the Anvil conversion now lives in
  `world/import/anvil.zig`, so the runtime chunk module has no `proto/v5`
  import.
- `ZWM1` ownership metadata (`world/meta.zig`) is the enforcement point: a
  world belongs to one profile; crossing versions is an offline import that
  writes a new target-owned world. The record, validation, and fail-closed
  profile/worldgen checks are implemented; startup wiring is still pending.
  This is already the decision in `MULTIVERSION.md` §7.6.

The import framework is shared. Only the block-state mapping and generator
identity are profile data.

---

## 6. Interfaces that make the sharing real

A document does not prevent copy-paste. The following interfaces and CI gates
do. Names are proposals; the contracts matter more than the filenames.

### 6.1 Profile root

```zig
// src/versions/mc47.zig (illustrative)
pub const meta = ...;              // protocol, height, sections, capabilities
pub const proto = ...;             // packet/chunk/slot codecs
pub const worldgen = ...;          // generator stages
pub const game = ...;              // tables and registries
pub const rules = ...;             // MovementRules, RedstoneRules, CombatModel...
```

The core receives `rules` and `game` at comptime. It does not import
`versions/` directly except through `src/version.zig`.

### 6.2 World and block access

```zig
pub const WorldView = struct {
    ctx: *anyopaque,
    getFn: *const fn (*anyopaque, i32, i32, i32) ?Block,
    setFn: *const fn (*anyopaque, i32, i32, i32, Block) anyerror!void,
    popFn: *const fn (*anyopaque, i32, i32, i32, Block) void,
    notifyFn: *const fn (*anyopaque, i32, i32, i32) void,
    scheduleFn: *const fn (*anyopaque, i32, i32, i32, u32) void,
};
```

The redstone engine already uses this `get`/`set`/`pop` contract through a
generic adapter. `WorldView` is the typed boundary for systems that need
dispatch at an I/O edge; hot paths should keep using a `comptime` adapter so
the profile is inlined. Physics, fluids, explosions and worldgen stages should
use the same `Block` (`canonical id + state/props`) rather than wire values.

### 6.3 Inventory transaction

```zig
pub const InventoryTx = struct {
    // Core-owned state machine. The profile supplies the layout and codec.
    pub fn click(self: *InventoryTx, slot: SlotId, button: u8, mode: ClickMode) !Result;
    pub fn quickMove(self: *InventoryTx, slot: SlotId) !Result;
    pub fn commit(self: *InventoryTx) !void;   // applies and checks conservation
    pub fn rollback(self: *InventoryTx) void;
};
```

`ContainerLayout` is data: slot count, mapping, roles (`input`, `fuel`,
`output`, `result`, `armor`, `offhand`), quick-move destinations, window ID.
The transaction engine never sees a packet.

### 6.4 Semantic packet sink

```zig
pub const PacketSink = struct {
    // Core emits semantic events; the profile encodes them.
    pub fn blockChange(self: *PacketSink, x: i32, y: i32, z: i32, b: Block) !void;
    pub fn chat(self: *PacketSink, msg: ChatMessage) !void;
    pub fn entitySpawn(self: *PacketSink, e: EntitySnapshot) !void;
    pub fn entityMeta(self: *PacketSink, id: i32, meta: EntityMeta) !void;
    pub fn inventorySlot(self: *PacketSink, window: i16, slot: i16, stack: ?Stack) !void;
};
```

This is how `sim/entity/entity.zig` and `sim/world/view.zig` stop importing v5 packets.
The profile implements the sink; the core owns “what happened”.

### 6.5 Command backend

The existing `srv` backend is the right pattern. Formalize the method set
(players, worlds, permissions, item/block lookup, teleport, message) so a new
profile cannot silently fork command logic. Command files remain shared; only
the registry/data and the Brigadier tree encoder are profile-owned.

### 6.6 Enforcement gates

- **Import gate:** `src/sim/**`, `src/world/**` and `src/cmd/**` must not
  import `src/proto/**` (except `world/import/**` and explicit profile roots).
  `zig build check-imports` enforces this with a temporary allowlist;
  C2–C5 burn the rest down. C0 removed `sim/player/scoreboard.zig` and C1 removed
  `sim/player/players.zig` and `world/chunk.zig`; today the list contains only
  `sim/world/view.zig` and `sim/entity/entity.zig`, both owned by C5.
- **Protocol-number gate:** no `if (protocol >= N)` outside `src/proto/**`,
  `src/versions/**`, `src/version.zig` and `meta`.
- **Canonical persistence gate:** persisted values must be canonical IDs or
  opaque profile blobs with a schema version; tests reject wire IDs.
- **Security ownership gate:** authorization/inventory/movement/reach code
  must live in the core modules, not in a `proto/*` file. Code review rejects
  a profile parser that calls `setBlock` or moves a stack directly.

---

## 7. The exploit/bug patch playbook

The goal is not only “less code”; it is that a fix lands once and every
profile inherits it. Use this table as the ownership map for security work.

| Vulnerability class | Single owner | Invariant/test | Profile input |
|---|---|---|---|
| Item duplication/loss | `sim/world/container.zig` | Sum of stacks + cursor is conserved across every click mode; no negative/overstack; window IDs bounded | Slot layout, stack limits |
| Cursor/window desync | `sim/world/container.zig` | Action sequence monotonic; full resync on mismatch; no state change on rejected click | Window IDs/layout |
| Reach/placement cheats | `sim/interaction.zig` | Eye-to-target distance, face validity, line of sight, world bounds, protection | Max reach, eye height, min/max Y |
| Flight/speed/teleport | `sim/movement.zig` | Max delta per tick, ground/water state, teleport confirmation, world border | Movement constants, height |
| Command permission bypass | `cmd` + `sim/permissions.zig` | Every command path checks node/level; selector expansion is bounded | Command registry, op levels |
| Chat spam/oversize/JSON | `net/chat.zig` + `Conn` | Rate/burst/length caps; valid component JSON; no control chars | Chat codec/signing |
| Packet/decompression bomb | `net/framing.zig` | Frame length cap, zlib output cap, malformed length rejection | Compression threshold, envelope |
| Entity visibility/info leak | `sim/tracking.zig` | Viewer set matches range/dimension; no spawn before enter; destroy on leave | Spawn/metadata codec |
| World border/height escape | `world/bounds.zig` | Clamp/teleport outside border; reject Y outside profile bounds | min/max Y, border size |
| Auth/session replay | `net/auth.zig` | Username/UUID binding, nonce/replay checks, online-mode verification | Login codec |
| NBT/component abuse | `item` validation + profile codec | Size/depth caps, type checks, no executable data; canonical on disk | NBT/component schema |
| Redstone lag machine | `sim/world/redstone.zig` + `sim/core/tick.zig` | Scheduled-tick budget, per-region load shedding, deterministic update cap | Component set/rules |
| Chunk unload/ghost chunk | `sim/world/view.zig` | Sent-set/unload diff, per-column once, resync on dimension change | Chunk codec |
| Teleport/vehicle desync | `sim/movement.zig` + `sim/entity/entity.zig` | Server-authoritative position, rider/passenger consistency | Entity dimensions/metadata |

### 7.1 Fix-once workflow

1. Reproduce on the oldest and newest implemented profile.
2. Add a core invariant or regression test that fails on both.
3. Fix the core, or add a rule/table entry if the difference is intentional.
4. Run `zig build test -Dmc=<each>` (or `test-all-mc`).
5. If behaviour intentionally differs, encode a named rule and document it in
   the support matrix. Never add an unlabelled protocol comparison.

### 7.2 What profile code may never do

- Decide whether a player has permission.
- Move items between slots or create/destroy stacks.
- Accept a block placement or movement delta as valid.
- Enforce or bypass a rate limit, world border, reach check or spawn
  protection.
- Write a world/player record in wire IDs.
- Define a second copy of a game table that already exists in `game/legacy`.

Profile code may only: parse bytes, validate wire-level structure (length,
enum range, field presence), translate IDs, and call the core semantic API.

---

## 8. Recommended extraction order

This is a “shared-core track” that runs alongside the phases in
`MULTIVERSION.md`; it is not a new release phase. Each step keeps the 1.7.10
profile green. The order is risk reduction, not a release gate: the minimum
before the 1.8 proof is C0–C2; C3–C5 should land before 1.12.2 or as soon as
possible; C6–C8 should land before the 1.13/modern flattening work; C9 starts
with C0 and grows with every step.

| Step | Work | Unblocks/why |
|---|---|---|
| C0 (done) | Add the import gate with an explicit temporary allowlist for the current leaks; add the `rules`/`game` fields to the profile contract; move `scoreboard`'s v5 `cmd_data` import behind `profile.game` | Prevents new leaks while the seam is fresh |
| C1 (done) | Split Anvil import out of `world/chunk.zig`; fix `ZPLR` canonical IDs (v5 writer, v3/v4 wire-row reader at the import boundary) | Storage/player data become truly canonical |
| C2 (done) | Extract `WorldView` + `BlockDef` table from redstone/server; make redstone read `RedstoneRules` | The reference engine becomes profile-data driven; 1.8 slime/1.11 observer become additive |
| C3 (done) | Extract `sim/world/container.zig` from `conn.zig` + furnace/table windows; add conservation tests | Biggest exploit-centralization win; 1.9 offhand/1.14 stations become layouts |
| C4 (done) | Extract `sim/interaction.zig` and `sim/movement.zig` from `conn.zig`; add profile rules | Reach/placement/movement fixes apply to every profile |
| C5 | Extract semantic entity metadata and canonical mob kinds; add `PacketSink` for entity/view | Stops `sim/entity/entity.zig`/`sim/world/view.zig` importing v5 packets |
| C6 | Move recipe/smelting/drops/redstone tables to `game/legacy` + `game/mc*`; generate registry tables | Makes 1.8/1.12 data additions cheap and reviewable |
| C7 | Add `ChunkCodec` + `PacketSink` boundary for view; profile scratch/batch sizes | done |
| C8 | Add `LightingModel` (pre-1.18/1.18+) and profile height/section rules | done |
| C9 (started) | Start the exploit regression suite + per-profile fuzz targets; grow them with each step | Every future fix is tested against every profile |
| C10 | Add `proto/v47`/`v340` gameplay breadth once C0–C5 are green; the 1.8 proof may begin after C0–C2 | Profiles become data/codec work, not server rewrites |

C0 landed with `src/version.zig`, the `mc5` profile root, the `rules`/`game`
contract fields and `src/import_gate.zig`. C1 landed with
`world/import/{anvil,player}.zig`, ZPLR v5 canonical slot IDs and the explicit
v3/v4 migration map; `sim/player/players.zig` and `world/chunk.zig` are protocol-free.
The gate's temporary allowlist is now the two C5 leaks: `sim/world/view.zig` and
`sim/entity/entity.zig`. C5 removes them; the gate fails on both a new violation and
a stale allowlist entry.

C2 landed with `src/sim/world_view.zig` (typed get/set/pop boundary carrying
the selected profile's table and rules), `src/game/block.zig` +
`src/game/mc5/blocks.zig` (dense canonical-id `BlockDef` table: normal cube,
support/anchors, piston mobility/containers/unbreakables, component identity,
interaction and placement orientation), and `src/game/rules.zig`
(`RedstoneRules`: timing, burnout, push limit and component state ids). The
server's LSM adapter and scheduler loader expose `WorldView`; the redstone hot
path keeps the comptime adapter and reads `world.blocks`/`world.rules`, so no
engine code imports a profile root. C9 covers the table anchors, rules and
typed view dispatch.

C3 landed with `src/sim/world/container.zig`: pickup/place/merge, quick-move, hotbar
swap, crafting-result consumption, whole-stack insertion and furnace-output
take. `conn.zig` window/alias routing and `server.zig` furnace click routing
keep only packet framing and server-owned state; both call the shared
primitives. C9 covers cursor/slot conservation, stack caps, rejected clicks,
grid consumption and furnace output.

C4 landed with `src/sim/interaction.zig` (profile eye height/reach, strict
block-center distance, face -> target cell) and `src/sim/movement.zig`
(exhaustion rates, jump cost, fall accumulation and landing hand-off). The
profile rules live in `game/rules.zig` (`InteractionRules`, `MovementRules`).
`conn.zig` now delegates all four paths, so a profile can change reach or
exhaustion without touching the network state machine.

C6 is now complete: `game/mc5/{recipes_data,smelting_data,drops_data}.zig` own
the 1.7.10 data tables, while `sim/{recipes,smelting}.zig` keep the shared
engines and read the profile data. The redstone behavior/timing/state-id data
lives in `game/{mc5/blocks,rules}.zig`, and the drop table lives in
`game/mc5/drops_data.zig` with the shared `DropRoll` result in
`game/drops.zig`. Generated registry tables remain a future optional
refinement.

C9 is started with `src/exploit_tests.zig` and a standalone
`zig build test-exploit -Dmc=<profile>` step (also wired into `zig build test`).
The root deliberately references only the extracted canonical/storage/data
modules; it does not analyze declarations from `net/server.zig`,
`net/conn.zig`, `sim/world/redstone.zig` or `sim/world/view.zig`, so the security lane
stays runnable while those are in flux. Its current
coverage is the profile contract and all-ID wire round-trip, ZC1 goldens and
malformed input, NBT depth/truncation/oversized arrays, Anvil rejection, ZPLR
canonical persistence plus the v3/v4 legacy map, recipe/smelting/furnace
conservation and output caps, inventory fill/merge conservation, container
click/quick-move/number-key/result conservation, profile reach and movement
transitions, scoreboard persistence, and v5 frame/slot/VarInt goldens. Chat
limits, command permissions and entity visibility stay deferred until C5/C7
extract their core modules; they must be added here rather than tested only
through the packet edge.

The fuzz entry points for ZC1, NBT, Anvil, framing, VarInts, slots and ZPLR
are in the same file and carry a seed corpus. Normal test runs execute every
seed. The installed Zig 0.16.0 toolchain currently fails to compile its own
`compiler/test_runner.zig` in `--fuzz` mode (`writeStackTrace` receives
`*builtin.StackTrace` instead of `*const debug.StackTrace`), so the fuzz lane
cannot be marked green until that toolchain defect is fixed; this is a runner
failure before any test input is executed, not a suite failure.

C2–C5 are the core of the answer. If only the protocol seam lands and these
extractions do not, every new profile will copy the click/movement/reach code
and the exploit surface will multiply.

---

## 9. Test strategy for shared code

The test matrix should prove both “shared” and “intentionally different”.

- **Core invariant tests** run for every profile from one source: storage
  round-trip, NBT depth/size, inventory conservation, movement bounds,
  interaction bounds, command permission gates, chat limits, entity
  visibility.
- **Profile golden tests**: packet frames, chunk bodies, slot codecs, metadata
  indices, registry round-trip, login/configuration flow.
- **Cross-profile property tests**: for every supported canonical ID,
  `fromWire(toWire(id)) == id`; unsupported IDs map to a documented
  placeholder; canonical storage survives import.
- **Exploit regression suite**: one test per row in §7, run against all
  profiles. A fix is not done until the oldest and newest profiles pass.
- **Fuzz**: framing/decompression, every `parse*`, chunk decode, NBT/Anvil
  import, component/NBT validation.
- **Differential tests**: for behaviour that should be identical (redstone
  power, crafting match, loot rolls, movement collision), compare profiles
  against the same canonical fixture. For behaviour that should differ
  (combat, worldgen, light), assert the selected model explicitly.
- **Performance**: shared abstractions must not add per-block/per-tick
  dispatch. Use `comptime` profile parameters and inline adapters in hot
  paths; dynamic dispatch only at I/O boundaries.

### C9 suite

Run the focused lane with:

```sh
zig build test-exploit -Dmc=1.7.10
```

The full test step includes it, so CI needs no separate invocation once the
main tree is green:

```sh
zig build test -Dmc=1.7.10
```

Current fuzz entry points (seed corpus runs in the normal test lane):
ZC1 chunk decode, NBT reader, Anvil import, v5 frame decode, VarInt decode,
v5 slot decode, and ZPLR player decode. Every target accepts arbitrary input
and must return a typed error, not panic, leak, or allocate without bound.
Add a target here when a new `parse*`/codec/storage decoder lands, and add the
corresponding invariant/golden test before closing the extraction step.

---

## 10. Risks and anti-patterns

**Over-sharing.** Forcing one implementation where the algorithm changed
(combat, worldgen, light, secure chat, components) produces `if` soup and
parity bugs. Use a named dual model.

**Under-sharing.** Copying click handling, reach checks, movement validation
or command dispatch into each protocol is how one dupe bug becomes six. The
core must own the decision even when the packet layout differs.

**Monolith gravity.** `src/net/server.zig` is a ~9k-line mix of shared
orchestration, v5 packets, worldgen and data access. New profile work must call
extracted services; if it lands in `server.zig`, the core seam is bypassed.
Treat the server decomposition as part of C3–C5, not as cleanup after the
profiles ship.

**Capability-flag sprawl.** Capabilities are for structural decisions
(height, sections, slots, batch size, compression). Packet differences belong
inside the profile codec, not in a growing list of booleans consulted by core.

**Hand-copied data.** Generate registries, packet tables and gameplay tables
from pinned `minecraft-data` / vanilla jars; check in provenance and a source
hash. `game/legacy` avoids copying identical 1.7/1.8/1.12 tables.

**Canonical-ID drift.** `ids.Id` is append-only. Never reorder, never persist
wire IDs, and make `toWire` optional. A canonical enum that silently lies is
worse than a profile-specific enum.

**`u8 y` and 16-section assumptions.** They are already in `view`, `server`,
`chunk` and `conn`. Move min/max Y and section count into `meta` before the
1.18 profile, not during it.

**Security in the parser.** A profile parser that calls `setBlock`, moves a
stack or checks a permission has bypassed the core. Keep parsers pure and
route every state change through a core API.

---

## 11. Source notes

Version claims above are grounded in the Minecraft Wiki and the existing
code. Key references (checked 2026-10-22):

- Java Edition 1.8: world border, spectator, slime blocks, armor stands,
  enchanting lapis — <https://minecraft.wiki/w/Java_Edition_1.8>
- Java Edition 1.9: attack cooldown, shield, offhand, elytra, loot tables,
  saturation regeneration — <https://minecraft.wiki/w/Java_Edition_1.9>
- Java Edition 1.11: observers, exhaustion-rate changes —
  <https://minecraft.wiki/w/Java_Edition_1.11>
- Java Edition 1.12: JSON recipes, recipe book, advancements/functions —
  <https://minecraft.wiki/w/Java_Edition_1.12>
- Java Edition 1.13: The Flattening, waterlogging, sprint-swimming, datapacks,
  Brigadier — <https://minecraft.wiki/w/Java_Edition_1.13>
- Java Edition 1.14: villager trading/workstations, stonecutter/loom/
  cartography/smithing, sneak height 1.5 —
  <https://minecraft.wiki/w/Java_Edition_1.14>
- Java Edition 1.17: Caves & Cliffs Part I (copper, deepslate, goats,
  axolotl, lightning rods); the taller world existed only in snapshots and was
  removed before release — <https://minecraft.wiki/w/Java_Edition_1.17>
- Java Edition 1.18: height −64..320, 24 sections, worldgen/light overhaul —
  <https://minecraft.wiki/w/Java_Edition_1.18>
- Java Edition 1.19: secure chat/signing —
  <https://minecraft.wiki/w/Java_Edition_1.19>
- Java Edition 1.20.2: configuration phase —
  <https://minecraft.wiki/w/Java_Edition_1.20.2>
- Java Edition 1.20.5: data components —
  <https://minecraft.wiki/w/Data_component_format>
- Java Edition 1.21: crafter, copper bulb, trial chambers —
  <https://minecraft.wiki/w/Java_Edition_1.21>
- Redstone/observer/copper bulb:
  <https://minecraft.wiki/w/Redstone_circuit>,
  <https://minecraft.wiki/w/Observer>,
  <https://minecraft.wiki/w/Copper_Bulb>
- Hunger/enchanting/trading/recipes/scoreboard/Brigadier:
  <https://minecraft.wiki/w/Hunger>,
  <https://minecraft.wiki/w/Enchantment>,
  <https://minecraft.wiki/w/Trading>,
  <https://minecraft.wiki/w/Recipe_(Java_Edition)>,
  <https://minecraft.wiki/w/Scoreboard>,
  <https://minecraft.wiki/w/Brigadier>

Code references:

- `src/sim/world/redstone.zig` — pure engine, canonical IDs, world adapter.
- `src/sim/core/tick.zig` — region tick/scheduler/load shedding, no protocol.
- `src/sim/entity/entity.zig` — shared tracking plan + v5 packet calls (to split).
- `src/sim/world/view.zig` — shared view scheduling + v5 chunk codec (to split).
- `src/net/conn.zig` — click/movement/reach logic currently in the packet
  edge (to extract).
- `src/net/server.zig` — shared orchestration mixed with v5 packets/worldgen/
  data (to decompose).
- `src/world/chunk.zig` — canonical ZC1; no protocol imports (C1).
- `src/world/import/anvil.zig` — only chunk-side 1.7.10 wire-id translation.
- `src/world/import/player.zig` — vanilla `player.dat` import and the v3/v4
  ZPLR wire-id migration map.
- `src/sim/player/players.zig` — ZPLR v5 canonical rows; legacy mapping is injected.
- `src/cmd/mod.zig`, `src/cmd/spec.zig` — the existing version-neutral command
  pattern.
- `docs/MULTIVERSION.md` — profile contract, ownership/import policy and
  release phases.

---

## 12. Bottom line

The systems that should be the same across every version are not just
redstone. The shareable core is:

- **operational:** tick, storage, sharding, config, permissions, bans, RCON,
  logging, auth, rate limits;
- **semantic:** canonical blocks/items/entities, inventory transactions,
  interaction/movement validation, tracking/visibility, command dispatch,
  chat moderation, scoreboard/team state;
- **simulation engines:** physics/collision, redstone/pistons/hoppers, fluids/
  fire/explosions, AI/pathfinding/spawning, hunger/effects, crafting/
  smelting/brewing/anvil/beacon, loot;
- **pipeline:** worldgen stage driver, chunk/column model, lighting storage,
  import/migration, test/fuzz harness.

The profile should own bytes, registries, slots, chunk encodings, worldgen
content, metadata indices, command trees, secure chat and the handful of
genuinely different models (combat, lighting, worldgen eras, item components).
That division gives one place to fix a dupe, a reach exploit, a permission
bypass, a packet bomb or a movement cheat — and it still lets each Minecraft
version behave like itself.
