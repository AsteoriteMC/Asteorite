# ZigCraft TODO — everything left to do

Derived from the implementation plan (pure-Zig 1.7.10/proto-5 server:
io_uring net, Folia-style regions, LSM store, comptime modding API, GPU
offload, SIMD/SIMT, DOD/ECS) plus gaps found while building.

Status snapshot (done, tested, live-verified over TCP):
- [x] VarInt/String/NBT/framing codecs (`src/net/codec.zig`, `src/world/nbt.zig`)
- [x] Handshake/status/login, offline UUID, AES-CFB8 (`src/net/cfb8.zig`), RSA-2048 decrypt + Mojang verify (`src/net/rsa.zig`, `src/net/mojang.zig`), online mode behind `--online`
- [x] Play bootstrap: JoinGame/SpawnPosition/MapChunkBulk/PlayerPosLook (`src/proto/v5/chunks.zig`, `src/sim/view.zig`), `--db` world serving
- [x] Pure-Zig LSM (WAL + SST + `ShardPool`), ZC1 payloads, Anvil→ZC1 import (`tools/anvil_import.zig`)
- [x] Region tick stub, MPSC handoff queue, player position tracking (stance quirk handled)
- [x] 53/53 `zig build test` green

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

## Phase B — Network: async zero-copy (`io_uring`)

Current state: thread-per-conn blocking I/O (`src/net/server.zig`) with a
per-conn output ring flushed per frame batch. The `Conn` interface stays;
only transport changes (as documented in `server.zig`).

- [ ] One `io_uring` ring per worker thread (not per connection): multishot accept (`IORING_OP_ACCEPT` multishot where available) + multishot recv with provided buffers (`IORING_OP_RECV` + buffer rings — required, kernel can't borrow user memory between multishot events)
- [ ] `SEND_ZC` (zerocopy send) gated behind size threshold (~8KB: chunk bulks yes, chat/keepalive no — copy is cheaper for small frames)
- [ ] Tick-aligned flush: accumulate per-player output during the 50ms tick, single `writev`/batched-send at tick end (`Conn.takeOutput` already returns owned slices — hook the tick loop, stop flushing per frame batch in `serveConn`)
- [ ] Backpressure: per-conn cap on queued bytes (kick on overflow — slow-consumer protection, critical once bulks flow)
- [ ] TCP_NODELAY + socket buffer tuning behind flags
- [ ] Fallback path: keep blocking transport behind a `--transport blocking|uring` flag (matches Zig 0.16 reality: `std.Io.Evented` is still experimental — raw `std.os.linux.IORING_*` is the way, not `std.Io`)
- [ ] Acceptance: 500 idle + 100 moving bot conns, p99 tick flush < 2ms, `strace` shows batched syscalls (no per-packet `writev`)

## Phase C — Concurrency: region threading (Folia-style)

Current state: `tickOnce` is sequential; `ShardPool` shards storage; MPSC exists but isn't wired to movement.

- [ ] Grid sharding: `32x32`-chunk regions owned by worker threads (`src/sim/tick.zig` owns the registry; one region = one tick unit, never split mid-tick)
- [ ] Thread pool sized to cores with `pthread_setaffinity_np` pinning, CCX-aware grouping (keep region neighbors on shared L3; document topology detection via `/sys`)
- [ ] Cross-region handoff: entity/player border crossing pushes `Transfer` into target inbox (wire `playerChunk` changes into this — currently tracked but unused)
- [ ] Per-region 50ms budget with overrun accounting (exists) + global tick barrier for time-of-day/weather sync only (never a global world lock)
- [ ] Deterministic tick order within a region; out-of-order delivery across regions is fine
- [ ] Acceptance: spread 200 bots across 8 regions on 8 cores — linear tick scaling vs single-thread, zero data races under ThreadSanitizer-equivalent review + stress test

## Phase D — Memory + CPU fast paths

- [ ] Slab allocator for entities/block entities (fixed-size, contiguous), per-tick arena reset for transient tick data (replaces per-feed `allocator.dupe` in `feedData`/`queueRaw` — profiled hot)
- [ ] SoA entity store / minimal ECS: contiguous pos/vel/AABB arrays; prefetcher-friendly tick (`src/sim/` new module; entities currently don't exist — build it SoA from day one, never AoS)
- [ ] SIMD fast paths with Zig `@Vector`: entity integration `pos += vel*dt`, AABB overlap tests, VarInt/stream scanning — scalar-first with benchmarks, vectorize the top 2 via profiling
- [ ] Seqlocks for read-heavy shared state (config, time-of-day, player count for status) so region threads never block on a mutex
- [ ] Acceptance: `zig build bench` tick micro-benchmarks (entity tick ns/entity, AABB queries/s) with before/after numbers in comments

## Phase E — Storage hardening (LSM is P1-complete, needs P2)

- [ ] Compaction: merge SSTs within a shard (size-tiered; simplest correct first), delete superseded runs, keep `next_sst_id` monotonic across restarts (exists) + MANIFEST so a crash mid-compact can't lose runs
- [ ] Read path: per-SST Bloom filter + block index (current linear scan is the known bottleneck — measure first: `get` p99 with 50 SSTs)
- [ ] fsync policy: WAL `sync()` per N ms or per K bytes (currently sync-on-flush/close only) + `wal.log` truncation atomicity review
- [ ] Signed-BE key sort fix: offset x/z by 2^31 in `encodeKey` so lexicographic order matches numeric (noted in `store.zig` tests)
- [ ] Repair/verify tool: `zig build check -- <db>` replays WAL, checks CRCs, lists orphans (`tools/` new binary; reuse `store.zig` open path)
- [ ] Snapshot/backup: SST file-level snapshot while running (LSM makes this cheap — document procedure)
- [ ] Acceptance: kill -9 mid-write storm → reopen recovers, zero CRC failures, `check` clean

## Phase F — Pure-Zig modding API (per plan §5)

- [ ] `Registry`: comptime block/item/fluid registration with numeric-ID assignment (1.7.10 range 0–4095 + Add nibble), duplicate detection, frozen-after-boot
- [ ] `EventBus`: comptime `subscribe(EventType, fn)` with zero-cost dispatch table generated at compile time; core events first: `PlayerJoin`, `PlayerChat`, `BlockBreak`, `BlockPlace`, `ChunkLoad`, `TickEnd`
- [ ] C-ABI boundary: `ModDescriptor{ id, version, init, tick?, deinit? }` as `extern struct`; mods are `.so` loaded via `std.DynLib` — comptime/`anytype` must NEVER cross the boundary (documented footgun, Zig ABI is unstable)
- [ ] Hot-reload for dev (`--hotreload`: dlclose/dlopen on file change; state migration is mod's problem — document)
- [ ] Sandboxing story: mods run in-process (same as Bukkit reality) — resource limits via tick-budget accounting per mod tick callback; document the trust model explicitly
- [ ] Example mod: `custom_ore` (register block + break→drop logic) as `mods/example/` + integration test
- [ ] Acceptance: server boots with 0 and 3 mods identically when idle; example mod altera gameplay over real TCP

## Phase G — GPU offload (last, behind flags — per plan)

Headless Vulkan compute on the RX 9070 XT via `Snektron/vulkan-zig` or `mach-vulkan`.
Rule: async bulk jobs only, never on the critical 50ms path (dispatch latency alone is ~50–200µs).

- [ ] Headless compute context init at startup (`--gpu off|vulkan`), persistent device-local buffers for voxel data, pinned host-visible staging
- [ ] Job queue with async readback wired to tick loop: submit → continue ticking → consume next tick
- [ ] Candidates in order: terrain noise/gen (biggest win, pairs with missing worldgen) → explosion raycast → fluid cellular automata (ping-pong) → mass A* wave propagation → entity LoS/proximity queries
- [ ] CPU fallback for every job (flag-off and queue-full paths must be correct, just slower)
- [ ] Acceptance: 32×32 region gen ≥10× faster than CPU path; TNT chain doesn't skip ticks; `--gpu off` bit-identical results

## Phase H — World generation (needed for playability)

- [ ] Deterministic seedable terrain: heightmap + biomes per column (fills the current void holes — `completeLogin` skips missing today)
- [ ] Cave carver + decorations pass (keep cheap: 2D heightmap + 3D noise only where needed)
- [ ] Chunk generation as a tick-loop job writing ZC1 into the pool (sync first, GPU job later per Phase G)
- [ ] Spawn area pre-generation on boot (`--gen-spawn N` chunks)
- [ ] Acceptance: fresh DB + no import → login shows terrain, F3 biomes sane

## Cross-cutting

### Protocol correctness (1.7.10 is full of quirks — verify each against a real client before calling done)
- [ ] Real-client compat harness: scripted 1.7.10 client session (status→login→move→place→break→chat→disconnect) with packet log diffed against vanilla server behavior; check in logs/specs, not binaries
- [x] Slot/inventory *parsing* (`Slot_Data` id/damage/NBT-skip for creative + placement) — done in A3; full NBT-preserving *encoding* still open (needed for window contents `0x30`/`0x2F`)
- [x] Living-entity metadata encoder (index 0/1/6 + `0x7F` terminator) used by `0x0C`/`0x0F`/`0x1C` — done in A4
- [ ] Multi Block Change `0x22` record packing (4-bit meta + 12-bit id + Y + Z + X nibble layout)

### Security / robustness
- [x] RSA key file 0600, gitignored
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
- [ ] CI: `zig build test` + `zig build` (ReleaseFast) + fuzz smoke on every change; pin Zig version in README (currently 0.16.0)

### Tech debt already known (grep these)
- [ ] `serveConn`/`feedData`/`queueRaw` per-feed heap dupes → arena slices (Phase D)
- [ ] `Conn.out` unbounded growth → backpressure cap (Phase B)
- [ ] `ShardPool` fixed 4 shards at open in `main` — make shard count = f(threads), document migration when changed
- [ ] `Mock` statics in `conn.zig` online test — isolate if tests ever run parallel
- [ ] `frameMapChunkBulk` OOM guard verified only by construction — add oversized-column rejection test
- [ ] `anvil_dump`/`anvil_import` are import-path only — ensure they never become runtime paths (CI lint: `world/anvil` not imported outside tools + `chunk.fromAnvilNbt`)
