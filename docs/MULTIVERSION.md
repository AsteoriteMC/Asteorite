# Compile-time Minecraft version profiles

Status: accepted, 2026-10-22. This supersedes the runtime multi-version design
in `TODO.md` Phase I.

## 1. Decision

One source tree, one build per Minecraft version:

```sh
zig build -Dmc=1.7.10
zig build -Dmc=1.12.2 -Doptimize=ReleaseFast
```

`-Dmc` selects a **version profile** at build time. The compiler analyzes only
that profile's packet codecs, registries, chunk codecs, worldgen and game-data
tables. There is no runtime protocol switch, no per-connection adapter table,
and no requirement for a universal block-state registry.

A profile pins four things:

1. wire protocol: packet IDs, framing, login flow, chunk wire format;
2. block/item registry: canonical <-> wire mappings;
3. world: storage schema, worldgen implementation, world metadata;
4. game data: recipes, drops, item stats, mob IDs, metadata indices, etc.

Worlds are tagged with the profile that created them and are owned by that
profile. A build refuses to open a world owned by another profile; crossing
versions always goes through an explicit offline import that writes a new
world. This is the main tradeoff of compile-time profiles and it is worth it
for the generated code: packet IDs, protocol branches and version-only data
disappear completely.

### 1.1 Confirmed decisions (2026-10-22)

| Topic | Decision |
|---|---|
| Ladder | 1.8.9 ships before 1.12.2 as the infrastructure proof. |
| Scope | The roadmap is committed through modern 1.20+: 1.20.4 first, then 1.21.x. Each step remains its own milestone. |
| Worlds | **Import only.** A profile never opens another profile's world at runtime, even when the storage schema matches. Crossing versions requires an explicit offline import that writes a new world owned by the target profile. |
| 1.12 worldgen | `worldgen/v340` is a ship gate for 1.12.2. The 1.7.10 generator is not reused for 1.12 terrain. |
| Artifacts | The installed binary stays `asteorite`; dist artifacts are `asteorite-<mc>-<target>`. |

## 2. Goals and non-goals

**Goals**

- An exact-version binary with no runtime version dispatch in hot paths.
- A second protocol added without forking `Server`, the tick loop, storage or
  transport code.
- 1.7.10 behavior, goldens and live E2E remain unchanged.
- Per-profile unit, golden and live-client tests.
- A support matrix that can grow one version at a time, committed through
  modern 1.20/1.21.

**Non-goals for this plan**

- Mixed-version clients on one server (the previous Phase I idea).
- One binary that accepts multiple protocol numbers.
- Modern clients in the first milestone.
- Opening a world produced by another profile at runtime.
- Cross-version world generation without an explicit import/migration.
- A universal `namespace:id+properties` registry large enough for every
  version. Compile-time profiles make per-profile registries acceptable.

## 3. Target ladder

| Profile | Protocol | Why this order | Status |
|---|---:|---|---|
| 1.7.10 | 5 | Baseline; current server | implemented |
| 1.8.9 | 47 | Smallest post-1.7 protocol delta. Forces compression, VarInt entity IDs, a second chunk codec, and the packet-model seam | first new profile (decided) |
| 1.12.2 | 340 | Last pre-flattening version; numeric block/item IDs; largest mod ecosystem | first content target; `worldgen/v340` required |
| 1.13.2 | 404 | The flattening: block-state registry, paletted chunks, command tree | first post-flattening |
| 1.16.5 | 754 | Dimension/registry codec, pre-configuration-phase | modern entry gate |
| 1.20.4 | 765 | Configuration phase, post-1.18 height/registry assumptions | first committed modern target |
| 1.21.x | 767+ | Data components, registry-driven codecs | committed follow-on |

Decision: implement **1.8.9 before 1.12.2** even though 1.8.9 is not a product
target. It is a smaller content surface and it proves every infrastructure seam
(compression, chunk codec, entity wire model, second packet table) before the
much larger 1.12 block/item/recipe/worldgen surface arrives. If 1.8.9 is
skipped, 1.12.2 carries both risks at once.

Decision: the roadmap is **committed through modern**. 1.20.4 is the first
modern milestone and 1.21.x follows it; these are planned phases, not optional
research. They remain separate milestones because the flattening, the 1.18
height change (the taller world appeared in 1.17 snapshots but shipped in
1.18), the 1.20.2 configuration phase and the 1.20.5 data components
are not linear packet deltas.

Each profile targets one exact protocol. Do not advertise a protocol range until
the packet bodies are proven compatible across that range.

## 4. How the switch works

### 4.1 Build options

`build.zig` owns the list of implemented profiles and turns the human version
name into a protocol number:

```zig
const McSpec = struct { name: []const u8, protocol: u16 };

const implemented = [_]McSpec{
    .{ .name = "1.7.10", .protocol = 5 },
    // .{ .name = "1.8.9",  .protocol = 47 },
};

const mc_name = b.option([]const u8, "mc", "Minecraft version") orelse "1.7.10";
const spec = resolveMc(mc_name) orelse @panic("unsupported -Dmc value");

const opts = b.addOptions();
opts.addOption(u16, "mc_protocol", spec.protocol);
opts.addOption([]const u8, "mc_name", spec.name);
```

The generated options module is attached to the existing `asteorite` module:

```zig
const mod = b.addModule("asteorite", .{
    .root_source_file = b.path("src/root.zig"),
    .target = target,
    .imports = &.{
        .{ .name = "build_options", .module = opts.createModule() },
    },
});
```

Every library/test/tool module already imports `asteorite`, so they all see the
same profile. No other file reads `build_options`.

### 4.2 The selector

`src/version.zig` is the single dispatch point:

```zig
const opts = @import("build_options");

pub const profile = switch (opts.mc_protocol) {
    5 => @import("versions/mc5.zig"),
    47 => @import("versions/mc47.zig"),
    340 => @import("versions/mc340.zig"),
    else => @compileError("no profile for this protocol"),
};

pub const meta = profile.meta;
pub const proto = profile.proto;
pub const worldgen = profile.worldgen;
pub const game = profile.game;
```

Because `opts.mc_protocol` is comptime-known, only the selected branch is
analyzed for code generation. Unselected profiles are still parsed and
name-resolved (so syntax/name errors are global), but their unused code paths
are not fully type-checked. `zig build test-all-mc` is therefore the real
type-check gate for every profile, and normal builds stay flat.

This is the same pattern the codebase already uses for per-OS transports
(`if (builtin.os.tag == .linux) @import("uring.zig") else struct {}`), just at
the version layer.

### 4.3 Why not a runtime switch

Compile-time selection removes:

- protocol comparisons in packet encode/decode and registry lookups;
- a tagged-union or vtable adaptor on every connection;
- data tables and parsers for versions the server cannot serve;
- version unions in structs that want different field widths.

It also lets a profile keep its natural types. For example, 1.7/1.8/1.12 can
keep `y: u8`; a 1.18+ profile can use `i16`/`i32` without paying for that in
legacy builds.

The cost is one binary per version, a build/test matrix, and no silently mixed
worlds. Those are acceptable for this project.

### 4.4 Optional end state: module aliases

Once the core/profile boundary is clean (after phase 3), the `switch` can be
promoted to build-time module imports (`proto`, `worldgen`, `game`). Zig allows
cyclical module imports, so the profile module can import core types and core
can import the selected profile module. That makes unselected profiles
unimportable by construction. Do not start there: `build_options` is less
machinery, keeps editor tooling simple, and is enough for the first three
profiles.

### 4.5 Binary naming

Keep the installed binary named `asteorite` so `zig build run`, E2E scripts and
the README do not change. Add:

- `asteorite --version` -> `Asteorite 1.12.2 (protocol 340, profile mc340)`;
- startup line and status JSON version name/protocol from `profile.meta`;
- release packaging renames to `asteorite-<mc>-<target>`;
- `zig build dist` builds every implemented profile into `dist/`.

For multiple local builds, use a separate prefix:

```sh
zig build -Dmc=1.12.2 -Doptimize=ReleaseFast -p zig-out/1.12.2
```

Compiled plugins/mods are profile-specific too: a native module built against
the 1.7.10 profile must not be loaded by a 1.12.2 binary. When the mod ABI lands,
include the profile id/protocol in the module descriptor and reject mismatches.

## 5. Current coupling audit

The code is already partly prepared for this: `ids.Id` is canonical, `item.Stack`
is canonical, storage is canonical ZC1, and the packet/slot layers are already
isolated in `src/proto/v5/`. The leaks are concentrated in the network and
game-data layers.

| Area | Current state | Action |
|---|---|---|
| `src/proto/v5/*` | packet IDs, packets, slots, chunks, wire map, command data | wrap in `proto/v5/root.zig`; becomes `profile.proto` |
| `src/net/conn.zig` | imports `proto/v5/{ids,packets,slot}` directly; 1.7 login/framing assumptions | import `version.proto`; add compression/login hooks |
| `src/net/server.zig` | imports packets/ids/wire/v5 worldgen/cmd data; hundreds of semantic packet calls | swap imports to `version.proto`; later canonicalize block APIs |
| `src/net/status.zig` | defaults now from `profile.meta` | keep only profile-selected defaults; no per-version branches |
| `src/sim/view.zig` | imports v5 chunk + packet codecs; bulk buffers sized for 1.7 | use `profile.proto.chunks`; profile batch size/scratch |
| `src/sim/entity.zig` | v5 entity frame functions; raw `u8` mob kinds | use `profile.proto.packets`; canonical mob kind + per-profile ID |
| `src/world/chunk.zig` | ZC1 canonical storage; Anvil conversion split to `world/import/anvil.zig` in C1 | no proto import in runtime storage |
| `src/sim/players.zig` | ZPLR v5 stores canonical ids; v3/v4 wire rows decode through `world/import/player.zig` in C1 | keep canonical slots append-only |
| `src/worldgen/v5/*` | 1.7.10 generator | behind `profile.worldgen`; 1.12 can initially reuse it |
| `src/sim/{drops,recipes,smelting,furnace,redstone}.zig` | 1.7.10 engines/behavior; recipe/smelting data tables now live in `game/mc5/` | keep engines; move remaining tables to `game` profile modules |
| `src/sim/scoreboard.zig` | Criteria come from `profile.game.cmd_data` (C0) | replace the transitional re-export when tables move in C6 |
| `src/cmd/*`, `src/cmd/spec.zig` | 1.7 command names/IDs | per-profile command data; 1.13+ Brigadier later |
| `src/main.zig` | hardcodes `asteorite.v5gen` | use `asteorite.worldgen` (selected profile) |
| `src/ids.zig` | 342 canonical ids, 1.7 universe | append 1.8/1.12 ids; per-profile support sets |

The import swap is mechanical; the remaining semantic leak is more serious:

1. `wire.toWire(id)` is **total** over all canonical ids. As soon as the canonical
   enum grows for 1.8/1.12 content, the 1.7 profile cannot honestly map them.
   Change the contract to optional (`?u16` or `supports(id)`), map unsupported
   ids to a placeholder at the wire boundary, and preserve the canonical id on
   disk.
2. Player persistence used to write wire ids, which made the player DB
   version-bound. Fixed in C1: ZPLR v5 stores canonical ids and the v3/v4
   reader translates legacy wire rows at the import boundary.

## 6. Target layout

```
src/
  version.zig                 # build_options -> profile switch
  versions/
    mc5.zig                   # profile root: meta + proto + worldgen + game
    mc47.zig
    mc340.zig
  proto/
    model.zig                 # shared semantic structs (JoinGame, PosLook, ...)
    v5/root.zig               # aggregates ids/packets/slot/chunks/wire/meta
    v5/...                    # existing files
    v47/...
    v340/...
  game/
    legacy/                   # tables shared by 1.7/1.8 (and some 1.12)
    mc5.zig
    mc47.zig
    mc340.zig
  world/
    chunk.zig                 # canonical ZC1/ZC2 in-memory + storage
    meta.zig                  # ZWM1 ownership + world profile metadata
    import/                   # profile-to-profile, Anvil and player.dat importers
  worldgen/
    pipeline.zig              # version-agnostic stage driver
    v5/root.zig
    v340/...
```

Dependency rules (code-review gates):

- `src/proto/*` may import canonical core (`ids`, `item`, read-only
  `world/chunk`) and `proto/model.zig`.
- Core may import `version.proto` only at delivery boundaries: `net/conn.zig`,
  `net/server.zig`, `net/status.zig`, `sim/view.zig`, `sim/entity.zig`.
- `src/world/*` must not import a protocol module. Profile-to-profile, Anvil and
  player.dat conversion lives in `world/import/` or tools.
- `src/sim/*` tick/physics/redstone/recipes code must not import a protocol
  module. It uses canonical ids and `version.game` tables.
- No `if (protocol >= N)` comparisons outside `proto/`, `versions/` and
  `meta`. Version logic lives in the version module, not sprinkled in core.

## 7. The profile contract

A profile root is small and intentionally boring:

```zig
// src/versions/mc5.zig
pub const proto = @import("../proto/v5/root.zig");
pub const meta = proto.meta;
pub const worldgen = @import("../worldgen/v5/root.zig");
pub const game = @import("../game/mc5.zig");
```

`src/proto/v5/root.zig`:

```zig
pub const meta = @import("meta.zig").current;
pub const ids = @import("ids.zig");
pub const packets = @import("packets.zig");
pub const slot = @import("slot.zig");
pub const wire = @import("wire_ids.zig");
pub const chunks = @import("chunks.zig");
pub const cmd_data = @import("cmd_data.zig");
pub const framing = @import("../../net/framing.zig");
```

### 7.1 Metadata and capabilities

```zig
pub const Meta = struct {
    profile_id: []const u8 = "mc5",
    name: []const u8 = "1.7.10",
    protocol: i32 = 5,
    protocol_min: i32 = 5,
    protocol_max: i32 = 5,

    min_y: i16 = 0,
    max_y: i16 = 255,
    section_count: u16 = 16,

    has_compression: bool = false,
    has_bulk_chunks: bool = true,
    has_block_states: bool = false,
    has_offhand: bool = false,
    has_config_phase: bool = false,
    inventory_slots: u16 = 45,
};
```

Capabilities are for **structural** core decisions (height bounds, batch size,
inventory size). Packet differences do not get capability flags; they are
implemented inside the version module.

### 7.2 Packet API

Keep the existing semantic function names as the initial contract. The server
already calls `frameJoinGame`, `frameBlockChange`, `parseFlying`, etc.; that set
is a proven API and rewriting 9k lines of server logic up front would add risk
without helping.

Move shared request/response structs into `src/proto/model.zig`:

```zig
pub const JoinGame = struct {
    eid: i32,
    gamemode: u8,
    dimension: i8,
    difficulty: u8,
    max_players: u8,
    level_type: []const u8,
    reduced_debug: bool = false, // ignored by 1.7
};

pub const PlayerPosLook = struct {
    x: f64, y: f64, z: f64,
    yaw: f32, pitch: f32,
    flags: u8 = 0,       // 1.8+
    teleport_id: i32 = 0, // 1.9+
};
```

Rules:

- Version modules encode only the fields their protocol has; extra fields are
  ignored.
- Parsers return canonical structs, never raw packet bytes.
- Packet IDs and body layouts never leave the version module.
- Normalize known 1.7-isms now: keepalive as `i64`, entity ids as `i32`, block
  coordinates as `i32`, `y` as `i32` in packet structs even when 1.7 encodes a
  byte. This avoids another signature sweep for 1.13+.
- A version module compiles only if it provides every symbol reachable from
  `Server`/`Conn`. That reachability is the contract. Add a
  `src/proto/contract.zig` test that references critical meta/types/functions
  and runs per profile.

### 7.3 Framing and compression

Split framing from the primitive reader/writer:

- `src/net/codec.zig`: VarInt/string/primitive reader/writer (version-neutral).
- `src/net/framing.zig`: length prefix, optional compression, `max_frame_len`.
- 1.7: no network compression. Chunk payloads carry their own inner zlib.
- 1.8+: login `Set Compression`, compressed frame envelope
  (`Length, Data Length, zlib(packet id + body)`), enabled after auth and
  before `LoginSuccess`. Below the threshold, `Data Length` is 0 and the body
  is uncompressed; accept both forms on inbound.
- Encryption is applied after framing and before enqueueing.

Target shape: packet builders return `(id, body)` and `Conn.queuePacket` frames
+ compresses + encrypts exactly once. Transitional bridge: keep the existing
`frame*` functions returning complete 1.7-style frames and let `queueRaw`
re-frame them when compression is enabled. That bridge is acceptable for the
1.8 bring-up but should not survive the second compressed profile. Plan a
mechanical migration of hot paths (chunk, entity, block change) to
`queuePacket` first.

Inbound: `Conn.feedData` reads the length prefix, applies profile framing
(decompress if enabled), enforces a hard uncompressed-size cap, then dispatches.
Fuzz this path; it is the main remote attack surface.

### 7.4 Chunk delivery

`src/sim/view.zig` keeps the version-neutral work: spiral order, holes,
sent-set, movement resync, unload diff. The profile owns byte layout and
batching:

```zig
pub const max_batch: usize = 32;       // 1 for 1.9+
pub const scratch_per_column: usize = 196864;
pub fn encodeColumn(ch: *const chunk.Chunk, sky: bool, out: []u8) !Encoded;
pub fn frameBatch(cols: []const BulkColumn, ...) ![]const u8; // caller queues
pub fn frameUnload(x: i32, z: i32, out: []u8) ![]const u8;
```

- 1.7 and 1.8 have `MapChunkBulk`; 1.9+ send one `Chunk Data` per column.
- 1.13+ chunks carry palettes/block entities; 1.14+ adds heightmaps.
- The core passes a decoded `world.chunk.Chunk` (or a read-only column view),
  never wire bytes.
- `Conn.bulk_raw/bulk_comp/bulk_work` sizing becomes profile-provided scratch,
  not hardcoded 1.7 numbers.

### 7.5 Canonical ids and registries

Pre-flattening (1.7/1.8/1.12):

- `ids.Id` stays append-only. Add 1.8 and 1.12 blocks/items at the end; never
  reorder. Every build knows the full legacy enum, so import tools can decode a
  world produced by another legacy profile. The runtime still refuses to open a
  foreign-profile world (section 7.6).
- `wire.toWire` becomes optional. A profile advertises which canonical ids it
  can encode. Unsupported ids map to a visible placeholder at the wire boundary
  (stone/air) but remain intact on disk.
- Commands/game tables only expose ids the profile supports.

Flattening (1.13+):

- A profile owns a `BlockState` `u32` registry generated from that version's
  data: name + properties <-> state id.
- World storage becomes ZC2 with profile state ids. There is no universal
  24k-state registry because profiles never coexist in one process.
- Migration ZC1 -> ZC2 is a tool: canonical `(id, meta)` -> state name+props ->
  target state id. Unmapped states become a placeholder and are logged.
- Items remain canonical `Stack` (id/count/damage/opaque NBT) for now. 1.20.5+
  data components may require an opaque component blob in `Stack`; that belongs
  to the modern profile work, not this seam.

### 7.6 World ownership, metadata and import

`src/world/meta.zig` (record implemented; startup wiring pending) is stored in
the LSM under a reserved dimension (254, next to the existing player dimension
255; the permissions row uses `(254,0,0)`, so ZWM1 uses `(254,0,1)`):

```
magic "ZWM1"
schema_version
profile_id              # "mc5", "mc47", "mc340", ...
created_by_mc / protocol
worldgen_profile
source_worldgen         # set by an importer; empty for native worlds
block_registry_version
min_y / max_y / section_count
```

Policy:

- **A world belongs to exactly one profile.** The runtime compares `profile_id`
  to `profile.meta.profile_id` and refuses a mismatch with an actionable error,
  even when `schema_version` and the block registry match.
- New world: write the current profile's metadata.
- Existing world without metadata: treat as legacy 1.7 / ZC1; only `mc5` may
  open it directly, and any other profile must import it.
- Unknown newer schema: refuse.
- Unsupported block ids: placeholder on the wire, preserved on disk.
- Different `worldgen_profile`: never mixed implicitly at runtime. New chunks
  are generated by the profile that owns the world.

**Import is the only crossing point.** A separate external importer
repository opens the source read-only, validates its ZWM1 metadata, converts
canonical ids/state ids as needed, and writes a new world with the target
profile's metadata. It never modifies the source. This repository intentionally
does not ship a `world import` command.

- Same schema + same registry (1.7 -> 1.8): the importer may perform a verified
  copy and rewrite metadata, but the result is still a new world owned by the
  target profile.
- Different schema (ZC1 -> ZC2): re-encode chunks through canonical
  `(id, meta)` / state-name mapping; unmapped states become a placeholder and
  are reported.
- Different generator: the importer preserves existing chunks and records
  `source_worldgen`. Because that creates a visible seam with newly generated
  chunks, the import requires `--accept-mixed-worldgen`; alternatively
  `--regenerate` discards chunk data and generates a fresh world.
- Import is offline. The server never opens a world tagged for another profile,
  not even for a read-only compatibility check.

### 7.7 Game data

Split engines from tables:

- Engines stay version-agnostic: crafting match, furnace tick, drop roll,
  redstone update logic, entity tick, physics.
- Tables move to `game/<profile>`: item stats (max stack, melee, tool),
  drops, smelting, recipes, redstone constants, mob type IDs, entity metadata
  indices, sounds/particles/effects, statistics/achievements, command data and
  permission/command registration order.
- `game/legacy/` holds tables shared by 1.7 and 1.8 (and initially 1.12);
  a profile re-exports shared tables plus its additions/overrides. Do not copy
  100 KB tables per version when the data is identical.
- Generate packet ID tables, block/item registries and gameplay tables from
  pinned `minecraft-data` / vanilla jars; check the generated files in with
  provenance comments and a source hash. No network or Python at build time.
- 1.9 combat changes, 1.12 JSON recipes, 1.13 command trees and modern
  registries are profile-specific. A profile may ship playable before it ships
  parity; document the gap in the support matrix.

The shared-core taxonomy, extraction order and exploit ownership map are in
[`CORE_SHARING.md`](CORE_SHARING.md). It is the companion to this plan: this
document defines the profile seam; that document defines what must stay behind
the seam so a bug fix does not have to be repeated per version.

### 7.8 Login flow hooks

The version module owns the login-state differences:

- accepted protocol range;
- optional `Set Compression` after auth;
- optional login plugin request/response (1.13+ Forge/Velocity);
- `LoginSuccess` layout (string UUID vs binary UUID);
- optional configuration phase (1.20.2+);
- `JoinGame` shape and registry/dimension payloads.

1.7/1.8/1.12 share the existing RSA/AES/Mojang verification path. Modern
secure profiles/chat signing are a separate workstream.

## 8. Build and CI

- `zig build -Dmc=<version>` selects exactly one profile.
- `zig build test -Dmc=<version>` runs the shared suite plus that profile.
- `zig build test-all-mc` can be a `b.addSystemCommand` that invokes
  `zig build test -Dmc=...` per implemented profile. This avoids maintaining
  several module graphs with different generated options in one build process.
- `zig build dist` builds ReleaseFast binaries for every implemented profile
  and target, named `asteorite-<mc>-<target>`.
- CI matrix: unit tests + ReleaseFast build per profile; live bot smoke per
  profile; world ownership and import fixtures; fuzz framing/decompression.
- `build.zig.zon` is unchanged. `README.md` gains a Versions section and a
  support matrix.

## 9. Phased implementation

### Phase 0 — Compiler seam with only 1.7.10 (no behavior change)

> Status 2026-10-22: the `-Dmc` selector, `src/version.zig`, the `mc5`
> profile root and the C0 import gate are implemented. C1 is implemented too:
> ZPLR v5 stores canonical ids (v3/v4 migrate through
> `world/import/player.zig`) and Anvil conversion moved to
> `world/import/anvil.zig`. `asteorite --version`, the top-level help, and the
> status JSON defaults now read `profile.meta`. The packet-import swaps, the
> server startup line, and the optional `wire.toWire` contract below remain
> pending. C2 is implemented: redstone reads the profile `BlockDef` table and
> `RedstoneRules`, and the server/storage edge exposes a typed `WorldView`;
> see `CORE_SHARING.md` section 8. C3 and C4 are implemented too: container
> click primitives live in `sim/container.zig`; reach and movement rules live
> in `sim/{interaction,movement}.zig`, backed by `game/rules.zig`. C5 is next.

- Add `-Dmc`, `build_options`, `src/version.zig`, `src/versions/mc5.zig`.
- Add `src/proto/v5/root.zig`, `src/worldgen/v5/root.zig`, `src/game/mc5.zig`.
- Swap direct imports in `net/conn`, `net/server`, `net/status`, `sim/view`,
  `sim/entity`, `sim/scoreboard` and `main` to the selected profile aliases.
- Add `asteorite --version` and drive top-level help/version and status JSON
  defaults from `profile.meta`; the server startup line remains pending.
- Keep the binary name and existing 1.7.10 serve output unchanged.
- Add the `wire.toWire` optional contract. (The canonical player-row fix,
  ZPLR v5 with a v3/v4 wire-row reader, landed in C1.)

**Acceptance:** `zig build test -Dmc=1.7.10` green; live 1.7.10 E2E unchanged;
no direct `proto/v5` imports outside `src/proto/v5/`, `src/versions/mc5.zig`,
`src/worldgen/v5/` and import/tool code; `zig build -Dmc=1.8.9` fails with a
clear "profile not implemented" error.

### Phase 1 — Build matrix and guardrails

> Status 2026-10-22: the profile table/name-resolution guard in `build.zig` is
> implemented. `src/world/meta.zig` now implements the ZWM1 record, validation,
> and fail-closed profile/worldgen ownership checks with golden and malformed
> input tests. Runtime startup wiring remains pending. Anvil/world import is
> intentionally a separate external tool repository; this repo only owns the
> canonical storage and ZWM1 contract it consumes.

- Profile table + name resolution in `build.zig`; clear error for unknown or
  unimplemented versions.
- `test-all-mc` and `dist` steps.
- `src/proto/model.zig`, `src/proto/contract.zig`, capability metadata.
- Code-review gates from section 6 documented in `README` or a `CONTRIBUTING`
  note.
- `src/world/meta.zig` + `ZWM1` record; runtime ownership check with a clear
  foreign-profile error.
- External importer contract: the importer lives in its own repository, reads
  a source world, verifies its ZWM1 metadata, and writes a new target-owned
  world with the target profile's ZWM1 record. No import command is added to
  this repository.
- A compatibility test: generate ZC1 with the 1.7 profile, decode it with the
  shared chunk layer, ensure every canonical id round-trips, and assert that the
  runtime metadata layer refuses to accept it as 1.8/1.12.

**Acceptance:** one command type-checks/tests every implemented profile; a
deliberately broken unimplemented profile is not analyzed by a normal build; a
world owned by another profile is refused at startup; the external importer can
consume the ZWM1 contract and produce a target-owned world.

### Phase 2 — 1.8.9 profile

- `proto/v47`: packet IDs, packets, slots, chunk codec, wire registry, meta.
- `net/framing.zig`: compressed frame envelope, Set Compression at login,
  malformed/normal threshold tests, zlib bomb cap.
- Packet model migration: packed positions, JoinGame, PlayerPosLook flags,
  player list, click-window, entity VarInt ids, 1.8 chunk body.
- Chunk delivery: 1.8 MapChunk/MapChunkBulk path, profile scratch sizes.
- Entity metadata: semantic `health`/`item` encoders per profile.
- Game data: 1.8-only blocks/items/mobs appended to `ids`; shared legacy tables
  plus additions.
- World: ZC1 + shared canonical ids, owned by `mc47`; 1.7-derived worldgen with
  the 1.8 parity gap documented (1.8 is the infrastructure profile, not a
  content target).

**Acceptance:** vanilla 1.8.9 client logs in, sees terrain, moves, breaks/places
blocks, chats, uses inventory, summons/attacks a mob, respawns; compressed and
uncompressed frame tests; 1.7.10 suite still green.

### Phase 3 — 1.12.2 profile

- `proto/v340`: packet table, 1.9-1.12 paletted chunk codec, block entities,
  unload chunk, no bulk path, offhand inventory (46 slots).
- Append 1.9-1.12 canonical blocks/items; generated wire map; optional
  `toWire` support set.
- Slots/windows: 1.12 click-window and inventory semantics.
- Game data: 1.12 recipe JSON generator, smelting/drops deltas, combat table.
  Playable milestones may keep 1.7 values with documented parity gaps.
- World: ZC1 owned by `mc340`; `worldgen/v340` is required before the profile
  ships (1.12 biomes, terrain and structures; the 1.7.10 generator is not
  reused). The external importer handles Anvil and player.dat sources.

**Acceptance:** the external importer can produce a 1.12.2-owned world from a
1.7.10 source and the 1.12.2 build renders it (direct open is refused); block
round-trip `1.7 canonical -> 1.12 wire -> 1.12 canonical` for every supported
id; `worldgen/v340` matches checked-in terrain goldens; vanilla 1.12.2 client
playable; no 1.7.10 regression.

### Phase 4 — Flattening: 1.13.2+

- Per-profile `BlockState` registry, ZC2 storage, palette chunk codec,
  heightmaps/block entities.
- ZC1 -> ZC2 import via the external importer; legacy ids+meta <-> state
  properties.
- Item registry generation; 1.13 command tree/brigadier (at least
  declare-commands + tab-complete; chat-command parsing can remain string-based
  initially).
- Height/section bounds become profile data; all `u8 y` assumptions in
  view/server/sim are audited. Keep `u8` in legacy profiles; use `i16` in the
  flattened profile.

**Acceptance:** full palette round-trip on a test world; 1.13.2 client playable;
the external importer produces a valid ZC2 world owned by `mc404`, with a
logged placeholder report.

### Phase 5 — Modern (committed)

The roadmap is committed through 1.20.4 and 1.21.x. Treat each item as its own
milestone:

- 1.16.5: dimension registry codec, metadata types, client settings.
- 1.18+: min_y -64, height 384, 24 sections, new chunk format. This is where
  `y` widths and all height constants must already be profile-driven.
- 1.19+: secure profiles/chat signing (online mode becomes a separate project).
- 1.20.2+: configuration phase.
- 1.20.5+: data components and item-stack changes.
- 1.21+: registry-driven codecs.

1.20.4 is the first modern target; 1.21.x follows once the 1.20.4 profile is
stable. Do not bundle these into the 1.8/1.12 work. Each deserves its own design
note and golden fixtures.

### Phase 6 — Release and maintenance

- `dist/` packaging, binary naming, support matrix, docs.
- CI per profile, live bot per profile, fuzz per profile.
- Performance guard: 1.7 profile tick/join p99 and RSS must not regress after
  the seam; profile binary must not link other versions' tables.
- Deprecation policy for profiles (world format, security, supported protocol).

## 10. Test strategy

- **Shared unit tests** run in every profile (codec primitives, storage, tick,
  entity store, worldgen pipeline). Tests must assert `profile.meta` values, not
  hardcoded `"1.7.10"`/protocol 5 strings, or they will fail in every other
  profile by design.
- **Profile unit tests** cover packet encode/decode, slot codec, chunk codec,
  registry mapping, login flow.
- **Golden frames** per profile: handshake/status/login/join/chunk/block
  change/entity/inventory/chat. Store as checked-in fixtures with provenance.
- **Registry property tests**: for every supported canonical id,
  `fromWire(toWire(id)) == id`; unsupported ids produce the placeholder.
- **World ownership tests**: a world tagged `mc5` is refused by `mc47`/`mc340`
  builds; import produces a target-owned world; canonical block values survive
  export/import; the source world is unchanged afterwards.
- **Import tests**: same-schema copy, ZC1 -> ZC2 re-encode, unmapped-state
  placeholder report, mixed-worldgen flag, regenerate mode.
- **Compression tests**: sizes around threshold, empty/oversized frames,
  malformed data-length, zlib bomb cap, encryption ordering.
- **Live E2E**: use `node-minecraft-protocol` (supports 1.7 through modern) or
  a per-profile bot; record packet ID histograms and fail on unknown packets.
- **Fuzz**: `feedData` framing/decompression, every `parse*` body, chunk
  decode, registry conversion, NBT/anvil import.
- **Performance**: 1.7 join burst, tick p99, RSS; binary size per profile.

## 11. Risks and open decisions

**Risks**

1. `server.zig` is monolithic. The import swap is cheap, but 1.7 semantics leak
   through block APIs (`getBlockAt` returns wire ids, `setBlockAt` takes wire
   ids) and through `u8` coordinates. Audit and canonicalize before 1.12.
2. `wire.toWire` is currently total. Extending `ids` without changing it will
   silently lie. Fix the contract in phase 0.
3. Player rows stored wire ids before C1. ZPLR v5 now stores canonical ids and
   the v3/v4 reader lives at the import boundary; future profiles must keep
   canonical ids as the interchange format.
4. Import-only worlds add tooling work. Land the metadata/ownership refusal
   before any second profile, or ad-hoc cross-profile opening will creep back in.
5. Chunk codecs are the largest per-version code. Keep the shared in-memory
   model and golden fixtures; do not let wire layout leak into `sim/view`.
6. Game-data volume grows quickly. Generate from pinned data; never hand-copy
   tables. Keep shared legacy tables.
7. Build matrix cost. Use lazy analysis + per-profile CI jobs; do not pay for
   all profiles in a normal build.
8. Modern protocols are not linear increments from 1.12. 1.13 flattening,
   1.18 height, 1.20.2 configuration and 1.20.5 components are each a project.
   The roadmap commits to them, but they remain separate milestones.
9. Online mode for modern versions (secure profiles/chat signing) is a separate
   security-sensitive workstream.
10. Generated-data provenance/versioning. Pin the source commit/hash in the
    generated file header.
11. `worldgen/v340` is a full ship gate for 1.12.2, not a follow-up. Schedule it
    with the profile; reusing the 1.7 generator is explicitly rejected.

**Resolved decisions (2026-10-22)**

- Ladder: 1.8.9 before 1.12.2.
- Scope: committed through modern 1.20.4 and 1.21.x.
- Worlds: import-only; no runtime cross-profile opening.
- 1.12 worldgen: `worldgen/v340` before ship.
- Artifacts: `asteorite` installed; `asteorite-<mc>-<target>` in `dist/`.

**Remaining open decisions**

- Exact 1.21.x endpoint, and whether 1.20.4 remains the first modern release
  once phase 5 starts (current plan: 1.20.4 first).
- Import command surface: resolved 2026-10-22 — world/Anvil import is a
  standalone external tool in its own repository, not a server subcommand.
- Default same-schema import: verified copy + metadata rewrite (proposed) vs
  canonical re-encode.
- Whether 1.8.9 keeps the 1.7-derived generator for its whole lifetime or gains
  a `worldgen/v47` later. The current plan accepts the parity gap because 1.8 is
  the infrastructure profile.

## 12. First pull requests

1. **Seam only:** build options + `version.zig` + profile roots + import swaps;
   no behavior change, 1.7 tests green.
2. **Metadata:** `profile.meta`, `--version`, startup/status text, unsupported
   `-Dmc` errors.
3. **Canonical storage and ownership:** optional `toWire`, canonical player
   rows, `world/meta` ownership refusal, split Anvil import from runtime chunk
   storage. The external importer consumes the ZWM1 contract; no import command
   lands in this repository.
4. **Framing:** shared `net/framing.zig`, compression hooks, inbound cap and
   fuzz tests.
5. **Contract:** `proto/model.zig`, `proto/contract.zig`, per-profile test
   matrix, `test-all-mc`, `dist`.
6. **1.8.9 profile:** packet table, chunk codec, registry, login compression,
   entity wire model, live E2E.
7. **1.12 worldgen:** `worldgen/v340` terrain, biomes, structures and goldens
   before `proto/v340` ships.

Each PR must keep `zig build test -Dmc=1.7.10` green and must not add a
protocol-number comparison outside the profile layer.
