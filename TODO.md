# ZigCraft TODO — everything left to do

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
- [x] 90/90 `zig build test` green (was 53/53 — count the real number when touching this line)

Legend: `[ ]` todo, `[~]` partial. Each phase ends with acceptance criteria.

---

## Phase A — Playable loop (highest priority)

Without these the client connects but the world is dead. All bodies are
1.7.10-specific — verify field order against `minecraft-data/data/pc/1.7/proto.yml`
(the version pinned in research) before implementing each packet.

### A1. Chunk lifecycle on the move ✅ (done, live-verified)
- [x] Per-conn sent-set (`Conn.sent`, `sentKey`), groundUp re-send impossible by construction
- [x] Movement-driven streaming: `syncPlayerChunks` diffs view disk vs sent-set (`x<<32|z`), unloads left columns, bulks entered ones in spiral order; no-op when the center chunk is unchanged
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
- [x] ZC1 read-modify-write + LSM persist per edit (`view.applyBlock`; section created on place, no-op break of air, holes ignored)
- [x] Arm-swing `0x0B` relay to viewers; cross-thread path is conn lock → world lock → per-target locks, never nested (documented in `server.zig`)
- [x] Acceptance, all live with keepalive-echoing clients: dig+place visible to second client with exact coords/id, swing relayed; restart serves the edited chunk from WAL replay (section mask `10001`, block `3` at the exact cell)
- [ ] Follow-ups (not blocking): `0x22` multi-block batching, server-driven `0x25` crack stages, survival break-timing validation, NBT preservation, non-overworld dimensions

### A4. Entities (minimal) ✅ (done, live-verified)
- [x] Global atomic eid allocator shared by players + mobs (never reused P1)
- [x] Spawn Player `0x0C` (offline UUID *string* + name, fixed-point ints, item 0, living metadata w/ `0x7F` terminator — vanilla crashes without it) and Spawn Mob `0x0F` (pig 90 + metadata); Destroy `0x13` (single-byte count); Teleport `0x18` / Relative Move `0x15` / Look `0x16` / Move+Look `0x17` / Head Look `0x19` / Entity Metadata `0x1C` encoder + decoder tests
- [x] Per-viewer tracked sets + delta planner (vanilla 4-block rule, i8 range forces teleport at exactly ±128 fixed units); move+turn merges into `0x17`; out-of-range or unloaded-chunk → despawn; gone-scan cleans stale tracks
- [x] Patrol-wander mob with deterministic square path; demo pig auto-spawns at spawn+2 when a world is present (20tps smoothing is Phase C work)
- [x] Server tick integrates entities: snapshot players (locked one at a time, no nesting), wander+snapshot mobs under `ent_lock`, reconcile per viewer, broadcast leave doubles as immediate path while tick reap is the safety net
- [x] Acceptance, all live with echoing clients: mutual player spawns with correct offline UUIDs/names/positions, wandering pig visible to both (relmove stream), despawn on leaving view, re-spawn on return, relmove on small moves, destroy on disconnect
- [ ] Follow-ups: 20tps movement smoothing, mob AI beyond patrol, health/damage, persistence of entities, riding/velocity/projectiles, equipment slots

### A5. Chat + disconnect hygiene ✅ (done, live-verified)
- [x] Serverbound Chat `0x01` (plain string) → broadcast Chat Message `0x02` to all play conns including sender (1.7 has no position byte); JSON escaped (`"`, `\`, control chars → `\u00XX`), UTF-8 validated, 100-codepoint cap; invalid/overlong dropped silently (no kick — can't be weaponized)
- [x] Spam throttle: 750ms min gap, `Kicked for spamming` disconnect on violation (unit + live verified)
- [x] Login timeout: conns stuck in handshake/login dropped after 30s of no progress (login state gets `0x00` disconnect + close; handshaking/status just closed — no disconnect packet exists in those states). Verified live: handshake-only conn gets clean EOF at ~31s
- [x] Disconnect audit: all paths use JSON reason with the right packet — `0x00` in login, `0x40` in play, keepalive timeout `0x40 "Timed out"`, login timeout `0x00`. Ticker shuts the socket down (unblocks serve loops); close happens exactly once in serveConn's defer
- [x] Acceptance, all live with echoing clients: broadcast reaches sender + others with byte-exact vanilla-style JSON (unicode preserved, not `\uXXXX`-escaped); spam → `0x40`; invalid UTF-8 → silent drop; idle handshake → clean drop at 30s
- [ ] Follow-ups: per-IP connection rate limiting, RCON/console kick, chat reporting/muting hooks for the mod API (F), tab-complete `0x3A`

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

## Phase E — Storage hardening (LSM is P1-complete, needs P2)

- [ ] Compaction: merge SSTs within a shard (size-tiered; simplest correct first), delete superseded runs, keep `next_sst_id` monotonic across restarts (exists) + MANIFEST so a crash mid-compact can't lose runs
- [ ] Read path: per-SST Bloom filter + block index (current linear scan is the known bottleneck — measure first: `get` p99 with 50 SSTs)
- [ ] fsync policy: WAL `sync()` per N ms or per K bytes (currently sync-on-flush/close only) + `wal.log` truncation atomicity review
- [ ] Signed-BE key sort fix: offset x/z by 2^31 in `encodeKey` so lexicographic order matches numeric (noted in `store.zig` tests)
- [ ] Repair/verify tool: `zig build check -- <db>` replays WAL, checks CRCs, lists orphans (`tools/` new binary; reuse `store.zig` open path)
- [ ] Snapshot/backup: SST file-level snapshot while running (LSM makes this cheap — document procedure)
- [ ] (Stretch) Per-tick input journal for forensics/anti-cheat: append compact {tick, player, action} records (separate from the store WAL); used to verify reach/speed claims post-hoc and debug desyncs. NOT instant crash recovery by itself — world durability still comes from LSM WAL/SST; replay needs a deterministic sim we don't have yet. Measure overhead before enabling by default
- [ ] Acceptance: kill -9 mid-write storm → reopen recovers, zero CRC failures, `check` clean

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

### H1. Pipeline driver + RNG (parity foundation — build first) ✅ (done — RNG goldens JVM-verified, chunk parity pending H2)

- [x] `src/worldgen/pipeline.zig`: version-agnostic stage driver — biome source → terrain shaper → surface builder → carvers → features → structures. Every chunk is a pure function `f(worldSeed, chunkXZ)` (enables parallel gen + golden tests); features read a 3×3 shaped area, decorate the center
- [x] `src/worldgen/rng/java_random.zig`: exact `java.util.Random` 48-bit LCG port (≤1.17 parity) with tests against known Java outputs; exact per-chunk seed-mixing formulas. Includes fdlibm `log` port (`strict_math.zig`) — proven necessary: StrictMath.log differs from Zig/glibc by 1 ulp on real inputs, caught by the seed-42 gaussian golden
- [x] `src/worldgen/rng/xoroshiro.zig`: Xoroshiro128++ port for 1.18+ (needed by H4)
- [x] Hard rule (code review gate): RNG call order is part of the spec — one stray `nextInt()` shifts all downstream terrain; call sites versioned + counted in tests
- [x] `tools/worldgen_dump.zig`: gen chunk for seed+X/Z, dump bytes for golden tests (`zig build wgen -- <seed> <x> <z>`; fresh-stream section diffs directly against Goldens.java)
- [~] Acceptance (partial): RNG-level golden hashes checked in and JVM-verified; same-seed-vs-vanilla **chunk-byte** parity needs H2's real stages

### H2. 1.7.10 generator (v5 — fills today's void holes)

- [ ] `src/worldgen/v5/`: GenLayer zoom chain, hill noise, per-biome surface map, tunnel-walk cave/ravine carvers, ore/tree decorators
- [ ] Chunk gen as a background job writing ZC1 into the pool (sync first, never on the 50ms path); spawn pre-gen on boot (`--gen-spawn N` chunks)
- [ ] Acceptance: fresh DB + no import → login shows terrain, F3 biomes sane, caves/ores/trees present; same-seed parity vs vanilla 1.7.10

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

- [ ] Parallel fan-out across Phase C region threads, prioritized by viewer distance; LRU of shaped-but-undecorated columns for neighbor reads
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

- [ ] Canonical internal model first: block state as internal `u16/u32` (not wire id+meta) at the `view.applyBlock`/ZC1 boundary; entity pos/vel/AABB version-free (the Phase D SoA store is the seam). No second protocol until the core stops speaking 1.7
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
- [x] Slot/inventory *parsing* (`Slot_Data` id/damage/NBT-skip for creative + placement) — done in A3; full NBT-preserving *encoding* still open (needed for window contents `0x30`/`0x2F`)
- [x] Living-entity metadata encoder (index 0/1/6 + `0x7F` terminator) used by `0x0C`/`0x0F`/`0x1C` — done in A4
- [ ] Multi Block Change `0x22` record packing (4-bit meta + 12-bit id + Y + Z + X nibble layout)

### Security / robustness
- [x] RSA key file 0600, gitignored
- [ ] Attack/use-entity validation (`0x02` Use Entity not yet implemented): reach check first; optional ~200ms hitbox history for high-ping fairness later. Scoped to hit validation only — no full rollback, no client reconciliation (1.7 protocol can't do it). Packet first, history later, both measured
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
