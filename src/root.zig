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
/// Lock-free cross-region handoff queue.
pub const mpsc = @import("sim/mpsc.zig");
/// Deterministic 20 TPS region tick loop.
pub const tick = @import("sim/tick.zig");
/// View-distance initial chunk burst + block application.
pub const view = @import("sim/view.zig");
/// Minimal entity tracking (players + mobs, delta-encoded updates).
pub const entity = @import("sim/entity.zig");
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
    _ = @import("proto/v5/ids.zig");
    _ = @import("proto/v5/packets.zig");
    _ = @import("proto/v5/chunks.zig");
    _ = @import("world/nbt.zig");
    _ = @import("world/anvil.zig");
    _ = @import("world/store.zig");
    _ = @import("world/chunk.zig");
    _ = @import("world/shard.zig");
    _ = @import("sim/mpsc.zig");
    _ = @import("sim/tick.zig");
    _ = @import("sim/view.zig");
    _ = @import("sim/entity.zig");
    _ = @import("sim/spin.zig");
}
