//! zigcraft root library — re-exports modules.
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
/// Runtime chunk storage: pure-Zig embedded LSM-tree (WAL + SSTables).
pub const store = @import("world/store.zig");
/// Versioned chunk payload (ZC1) — the only runtime chunk encoding.
pub const chunk = @import("world/chunk.zig");
/// Region-sharded LSM pool (Folia-style ownership, no global lock).
pub const shard = @import("world/shard.zig");
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
/// 1.7.10 decorators: ores + trees (CFR ports, JVM shape goldens).
pub const v5decor = @import("worldgen/v5/decor.zig");
/// 1.7.10 cave + ravine carvers (CFR ports, JVM-verified).
pub const v5carve = @import("worldgen/v5/carve.zig");
/// Canonical item model (version-agnostic game data; wire codecs per proto).
pub const item = @import("item.zig");
/// Canonical 1.7.10 block + item numeric IDs (jar-extracted, single flat u16 space).
pub const ids = @import("ids.zig");
/// 1.7 slot wire codec over the canonical model (no game tables here).
pub const v5slot = @import("proto/v5/slot.zig");
/// Lock-free cross-region handoff queue.
pub const mpsc = @import("sim/mpsc.zig");
/// Deterministic 20 TPS region tick loop.
pub const tick = @import("sim/tick.zig");
/// View-distance initial chunk burst + block application.
pub const view = @import("sim/view.zig");
/// Minimal entity tracking (players + mobs, delta-encoded updates).
pub const entity = @import("sim/entity.zig");
/// Player persistence (position/inventory/health across restarts, LSM-backed).
pub const players = @import("sim/players.zig");
/// Permission model: op levels + per-player node grants/denies (LSM-backed).
pub const permissions = @import("sim/permissions.zig");
/// RCON remote console (vanilla-style Source framing, password auth).
pub const rcon = @import("net/rcon.zig");
/// Test-and-set spinlock for short critical sections.
pub const spin = @import("sim/spin.zig");

test {
    _ = @import("net/codec.zig");
    _ = @import("net/cfb8.zig");
    _ = @import("net/rsa.zig");
    _ = @import("net/mojang.zig");
    _ = @import("net/uuid.zig");
    _ = @import("net/conn.zig");
    _ = @import("net/server.zig");
    _ = @import("net/rcon.zig");
    _ = @import("proto/v5/ids.zig");
    _ = @import("proto/v5/packets.zig");
    _ = @import("proto/v5/chunks.zig");
    _ = @import("world/nbt.zig");
    _ = @import("world/anvil.zig");
    _ = @import("world/store.zig");
    _ = @import("world/chunk.zig");
    _ = @import("world/shard.zig");
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
    _ = @import("worldgen/v5/decor.zig");
    _ = @import("worldgen/v5/carve.zig");
    _ = @import("item.zig");
    _ = @import("ids.zig");
    _ = @import("proto/v5/slot.zig");
    _ = @import("sim/mpsc.zig");
    _ = @import("sim/tick.zig");
    _ = @import("sim/view.zig");
    _ = @import("sim/entity.zig");
    _ = @import("sim/players.zig");
    _ = @import("sim/permissions.zig");
    _ = @import("sim/spin.zig");
}
