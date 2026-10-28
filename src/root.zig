//! asteorite root library — re-exports modules.
pub const version = @import("version.zig");
pub const profile = version.profile;
pub const codec = @import("net/codec.zig");
pub const cfb8 = @import("net/cfb8.zig");
pub const rsa = @import("net/rsa.zig");
pub const mojang = @import("net/mojang.zig");
pub const uuid = @import("net/uuid.zig");
pub const conn = @import("net/conn.zig");
pub const server = @import("net/server.zig");
pub const v5 = @import("proto/v5/ids.zig");
pub const packets = @import("proto/v5/packets.zig");
pub const chunks = @import("proto/v5/chunks.zig");
pub const nbt = @import("world/nbt.zig");
/// Anvil decoding is IMPORT-ONLY (migration into LSM). Never the runtime format.
pub const anvil = @import("world/anvil.zig");
/// Offline Anvil chunk import (1.7.10 wire ids -> canonical ZC1).
pub const anvil_import = @import("world/import/anvil.zig");
/// Offline player import: vanilla player.dat + legacy ZPLR v3/v4 wire rows.
pub const player_import = @import("world/import/player.zig");
/// Runtime chunk storage: pure-Zig embedded LSM-tree (WAL + SSTables).
pub const store = @import("world/store.zig");
/// Versioned chunk payload (ZC1) — the only runtime chunk encoding.
pub const chunk = @import("world/chunk.zig");
/// ZWM1 world ownership metadata (profile id + generator identity).
pub const world_meta = @import("world/meta.zig");
/// Region-sharded LSM pool (Folia-style ownership, no global lock).
pub const shard = @import("world/shard.zig");
/// io_uring read ring for SST data (Phase B NVMe storage path).
/// Linux-only: the import is dead code on other targets (comptime condition).
pub const uring_io = if (@import("builtin").os.tag == .linux) @import("world/uring_io.zig") else struct {};
/// Storage profiles: hdd|ssd|nvme|auto tunings (Phase B NVMe path).
pub const storage_profile = @import("world/profile.zig");
/// Worldgen pipeline driver (version-agnostic stage order + context).
pub const worldgen = @import("worldgen/pipeline.zig");
/// Exact java.util.Random port (<=1.17 worldgen parity, JVM-verified goldens).
pub const java_random = @import("worldgen/rng/java_random.zig");
/// Xoroshiro128++ + Mojang seeding (1.18+ worldgen; H4 gate for full use).
pub const xoroshiro = @import("worldgen/rng/xoroshiro.zig");
/// fdlibm log port: StrictMath.log bit-exact (gaussian parity is load-bearing).
pub const strict_math = @import("worldgen/rng/strict_math.zig");
/// 1.7.10 worldgen noise (Improved + simplex, octave stacks). JVM-verified.
pub const v5noise = @import("worldgen/v5/noise.zig");
/// 1.7.10 biome table (ids, heights, temp categories). JVM-verified.
pub const v5biome = @import("worldgen/v5/biome.zig");
/// 1.7.10 GenLayer biome chain (CFR-verified ports + JVM goldens).
pub const v5genlayer = @import("worldgen/v5/genlayer.zig");
/// 1.7.10 overworld terrain shaper (density field + block fill). JVM-verified.
pub const v5shaper = @import("worldgen/v5/shaper.zig");
/// 1.7.10 surface builder (per-biome top/filler). JVM-verified (base path).
pub const v5surface = @import("worldgen/v5/surface.zig");
/// 1.7.10 chunk generator (density -> fill -> surface -> ZC1).
pub const v5gen = @import("worldgen/v5/gen.zig");
/// v5 generation serving glue (on-demand fill, spawn search, pre-gen).
pub const v5serve = @import("worldgen/v5/serve.zig");
/// Background chunk-generation worker pool (async H5 gen).
pub const v5genpool = @import("worldgen/v5/genpool.zig");
/// 1.7.10 decorators: ores + trees (CFR ports, JVM shape goldens).
pub const v5decor = @import("worldgen/v5/decor.zig");
/// 1.7.10 cave + ravine carvers (CFR ports, JVM-verified).
pub const v5carve = @import("worldgen/v5/carve.zig");
/// 1.7.10 structure generation (MapGen framework + pieces, jar-verified).
pub const v5struct_bbox = @import("worldgen/v5/struct/bbox.zig");
pub const v5struct_placer = @import("worldgen/v5/struct/placer.zig");
pub const v5struct_comp = @import("worldgen/v5/struct/comp.zig");
pub const v5struct_loot = @import("worldgen/v5/struct/loot.zig");
pub const v5struct_mapgen = @import("worldgen/v5/struct/mapgen.zig");
pub const v5struct_scattered = @import("worldgen/v5/struct/scattered.zig");
pub const v5struct_mineshaft = @import("worldgen/v5/struct/mineshaft.zig");
pub const v5struct_village = @import("worldgen/v5/struct/village.zig");
pub const v5struct_stronghold = @import("worldgen/v5/struct/stronghold.zig");
/// Canonical item model (version-agnostic game data; wire codecs per proto).
pub const item = @import("item.zig");
/// Profile rules (gamemode/difficulty enums + engine tuning).
pub const rules = @import("game/rules.zig");
/// Canonical mob kinds (spawn allowlist keys + engine identity).
pub const mob = @import("game/mob.zig");
/// Canonical block/item identity (interned indices; wire encodings live per proto version).
pub const ids = @import("ids.zig");
/// 1.7 slot wire codec over the canonical model (no game tables here).
pub const v5slot = @import("proto/v5/slot.zig");
/// Command metadata (gamerule defaults, scoreboard criteria, stats).
pub const cmd_data = @import("proto/v5/cmd_data.zig");
/// 1.7.10 wire encodings for canonical ids (single source of truth for v5 conversion).
pub const v5wire = @import("proto/v5/wire_ids.zig");
/// Lock-free cross-region handoff queue.
pub const mpsc = @import("sim/core/mpsc.zig");
/// CPU topology + pinning for Phase C region threads.
pub const affinity = @import("sim/core/affinity.zig");
/// Deterministic 20 TPS region tick loop.
pub const tick = @import("sim/core/tick.zig");
/// Persistent futex-barrier worker pool (Phase C follow-up: stable
/// thread identities for the region tick; falls back to fork-join).
pub const pool = @import("sim/core/pool.zig");
/// View-distance initial chunk burst + block application.
pub const view = @import("sim/world/view.zig");
/// Minimal entity tracking (players + mobs, delta-encoded updates).
pub const entity = @import("sim/entity/entity.zig");
/// Player persistence (position/inventory/health across restarts, LSM-backed).
pub const players = @import("sim/player/players.zig");
/// Per-block chest storage (single chests + double halves, LSM-backed).
pub const chest = @import("sim/world/chest.zig");
/// Permission model: op levels + per-player node grants/denies (LSM-backed).
pub const permissions = @import("sim/player/permissions.zig");
/// Server list ping payload: struct-stringified status JSON with
/// vanilla/fabric/forge handshake brands (FML modinfo for forge).
pub const status = @import("net/status.zig");
/// RCON remote console (vanilla-style Source framing, password auth).
pub const rcon = @import("net/rcon.zig");
/// OS shutdown signals (SIGINT/SIGTERM/SIGHUP/SIGQUIT, Windows console
/// events) -> atomic flag polled by the ticker; same save+exit pipeline
/// as /stop. No-op where the target has no signal concept.
pub const shutdown = @import("net/shutdown.zig");
/// Operator console TUI (scrollback, history, colors) + terminal restore
/// hook used by every stop path (console/RCON/in-game) before exit().
pub const console_tui = @import("console_tui.zig");
/// Minimal TOML parser for the server config file (tables, scalars,
/// arrays, inline tables, comments). Strict subset, fail-closed.
pub const toml = @import("toml.zig");
/// Test-and-set spinlock for short critical sections.
pub const spin = @import("sim/core/spin.zig");
/// Vanilla 1.7.10 redstone simulation: scheduled ticks, power model,
/// components (wire/torch/lever/button/plates/doors/lamp/repeater/ore).
pub const redstone = @import("sim/world/redstone.zig");
/// Version-neutral interaction geometry/reach rules (C4).
pub const interaction = @import("sim/world/interaction.zig");
/// Version-neutral movement bookkeeping (exhaustion, fall distance) (C4).
pub const movement = @import("sim/world/movement.zig");
/// Bump arena with O(1) reset (Phase D per-tick transient data).
pub const arena = @import("sim/core/arena.zig");
/// Fixed-size slab allocator (Phase D entity/block-entity storage).
pub const slab = @import("sim/core/slab.zig");
/// Seqlock for read-mostly shared state (Phase D lock-free reads).
pub const seqlock = @import("sim/core/seqlock.zig");
/// Sliding-window rate limiters (login attempts, block placement).
pub const ratelimit = @import("sim/core/ratelimit.zig");
/// Command framework: spec-driven usage, parsing, tab-completion.
/// Shared with main-module files (cli.zig) that must not import cmd/
/// files by path (that would claim them into two modules).
pub const cmdspec = @import("cmd/spec.zig");
/// SoA entity store + SIMD fast paths (Phase D prefetcher-friendly tick).
pub const entity_store = @import("sim/entity/entity_store.zig");
/// Network transport abstraction (Phase B: io_uring / kqueue / IOCP / blocking).
pub const transport = @import("net/transport.zig");
/// Linux io_uring transport backend (Phase B primary). Linux-only: the
/// import is dead code on other targets (comptime condition).
pub const uring = if (@import("builtin").os.tag == .linux) @import("net/uring.zig") else struct {};
/// Windows IOCP transport backend (Phase B). Compiles everywhere (the
/// Win32 entry points are extern decls — unlinked until called, and all
/// calls are comptime-gated to Windows); pure parts are unit-tested on
/// every target, runtime needs Windows hardware.
pub const iocp = @import("net/iocp.zig");
/// G1 GPU offload: minimal Vulkan loader + headless compute (dlopen,
/// no link-time dep; soft-fails without a driver). CPU fallback always.
pub const gpuvk = @import("gpu/vk_min.zig");
/// G1 async job interface (Backend/TickBudget/bit-compare helper). The v1
/// sync fill path doesn't route through it yet; v2 batching will.
pub const gpujob = @import("gpu/job.zig");
/// Checked-in SPIR-V kernels (embed + structural tests): echo, threshold,
/// batched threshold. Dispatched by gpu_probe and gpufill.
pub const gpuecho = @import("gpu/echo_spv.zig");
pub const gputhreshold = @import("gpu/threshold_spv.zig");
pub const gpubatch = @import("gpu/threshold_batch_spv.zig");
/// Persistent GPU fill context for GenPool workers (v1 sync offload with
/// CPU fallback; bit-identical either way).
pub const gpufill = @import("gpu/fill.zig");

test {
    _ = @import("version.zig");
    _ = @import("proto/v5/root.zig");
    _ = @import("worldgen/v5/root.zig");
    _ = @import("game/block.zig");
    _ = @import("game/drops.zig");
    _ = @import("game/mob.zig");
    _ = @import("game/mc5.zig");
    _ = @import("game/mc5/blocks.zig");
    _ = @import("game/mc5/mobs.zig");
    _ = @import("game/mc5/drops_data.zig");
    _ = @import("game/mc5/enchanting_data.zig");
    _ = @import("game/mc5/item_data.zig");
    _ = @import("game/rules.zig");
    _ = @import("net/codec.zig");
    _ = @import("net/cfb8.zig");
    _ = @import("net/rsa.zig");
    _ = @import("net/mojang.zig");
    _ = @import("net/uuid.zig");
    _ = @import("net/conn.zig");
    _ = @import("net/conn_tests.zig");
    _ = @import("net/server.zig");
    _ = @import("net/packet_sink.zig");
    _ = @import("net/rcon.zig");
    _ = @import("console_tui.zig");
    _ = @import("toml.zig");
    _ = @import("net/status.zig");
    _ = @import("proto/v5/ids.zig");
    _ = @import("proto/v5/packets.zig");
    _ = @import("proto/v5/cmd_data.zig");
    _ = @import("sim/player/bans.zig");
    _ = @import("sim/player/scoreboard.zig");
    _ = @import("proto/v5/chunks.zig");
    _ = @import("world/nbt.zig");
    _ = @import("world/anvil.zig");
    _ = @import("world/import/anvil.zig");
    _ = @import("world/import/player.zig");
    _ = @import("world/store.zig");
    _ = @import("world/chunk.zig");
    _ = @import("world/shard.zig");
    _ = if (@import("builtin").os.tag == .linux) @import("world/uring_io.zig") else struct {};
    _ = @import("world/profile.zig");
    _ = @import("worldgen/pipeline.zig");
    _ = @import("worldgen/rng/java_random.zig");
    _ = @import("worldgen/rng/xoroshiro.zig");
    _ = @import("worldgen/rng/strict_math.zig");
    _ = @import("worldgen/v5/noise.zig");
    _ = @import("worldgen/v5/biome.zig");
    _ = @import("worldgen/v5/genlayer.zig");
    _ = @import("worldgen/v5/shaper.zig");
    _ = @import("worldgen/v5/surface.zig");
    _ = @import("worldgen/v5/gen.zig");
    _ = @import("worldgen/v5/serve.zig");
    _ = @import("worldgen/v5/genpool.zig");
    _ = @import("worldgen/v5/decor.zig");
    _ = @import("worldgen/v5/carve.zig");
    _ = @import("item.zig");
    _ = @import("ids.zig");
    _ = @import("proto/v5/wire_ids.zig");
    _ = @import("proto/v5/slot.zig");
    _ = @import("sim/core/mpsc.zig");
    _ = @import("sim/core/affinity.zig");
    _ = @import("sim/core/tick.zig");
    _ = @import("sim/core/pool.zig");
    _ = @import("sim/world/view.zig");
    _ = @import("sim/entity/entity.zig");
    _ = @import("sim/player/players.zig");
    _ = @import("sim/player/permissions.zig");
    _ = @import("sim/core/spin.zig");
    _ = @import("sim/world/redstone.zig");
    _ = @import("sim/world/container.zig");
    _ = @import("sim/world/chest.zig");
    _ = @import("sim/world/enchanting.zig");
    _ = @import("sim/world/interaction.zig");
    _ = @import("sim/world/movement.zig");
    _ = @import("sim/world/world_view.zig");
    _ = @import("sim/core/arena.zig");
    _ = @import("sim/core/slab.zig");
    _ = @import("sim/core/seqlock.zig");
    _ = @import("sim/core/ratelimit.zig");
    _ = @import("sim/entity/entity_store.zig");
    _ = @import("sim/net/packet_sink.zig");
    _ = @import("sim/net/packet_sink_test.zig");
    _ = @import("net/transport.zig");
    _ = @import("net/shutdown.zig");
    _ = @import("worldgen/v5/struct/bbox.zig");
    _ = @import("worldgen/v5/struct/placer.zig");
    _ = @import("worldgen/v5/struct/comp.zig");
    _ = @import("worldgen/v5/struct/loot.zig");
    _ = @import("worldgen/v5/struct/mapgen.zig");
    _ = @import("worldgen/v5/struct/scattered.zig");
    _ = @import("worldgen/v5/struct/testplacer.zig");
    _ = @import("worldgen/v5/struct/golden.zig");
    _ = @import("worldgen/v5/struct/mineshaft.zig");
    _ = @import("worldgen/v5/struct/village.zig");
    _ = @import("worldgen/v5/struct/stronghold.zig");
    _ = if (@import("builtin").os.tag == .linux) @import("net/uring.zig") else struct {};
    _ = @import("net/iocp.zig");
    _ = @import("gpu/vk_min.zig");
    _ = @import("gpu/job.zig");
    _ = @import("gpu/echo_spv.zig");
    _ = @import("gpu/threshold_spv.zig");
    _ = @import("gpu/threshold_batch_spv.zig");
    _ = @import("gpu/fill.zig");
    _ = @import("cmd/mod.zig");
    _ = @import("cmd/help.zig");
    _ = @import("cmd/list.zig");
    _ = @import("cmd/save_all.zig");
    _ = @import("cmd/op.zig");
    _ = @import("cmd/deop.zig");
    _ = @import("cmd/perm.zig");
    _ = @import("cmd/stop.zig");
    _ = @import("cmd/spec.zig");
    _ = @import("cmd/gamemode.zig");
    _ = @import("cmd/give.zig");
    _ = @import("cmd/tp.zig");
    _ = @import("cmd/time.zig");
}
