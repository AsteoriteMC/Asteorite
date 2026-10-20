//! Version-agnostic worldgen stage driver (Phase H1).
//!
//! Every chunk is a pure function f(worldSeed, chunkXZ) through fixed stages:
//! biome -> shaper -> surface -> carver -> features -> structures.
//! This file owns the *order* and the *context*; H2+ provides real stages.
//! Stages share one RNG by design — call order is spec (see rng docs).

const std = @import("std");
const java_random = @import("rng/java_random.zig");

pub const StageId = enum {
    biome,
    shaper,
    surface,
    carver,
    features,
    structures,

    pub fn order() [6]StageId {
        return .{ .biome, .shaper, .surface, .carver, .features, .structures };
    }
};

/// Per-chunk generation context. H2 stages will hang block buffers off this.
pub const GenCtx = struct {
    world_seed: i64,
    cx: i32,
    cz: i32,
    rng: java_random.JavaRandom,
    visited: [6]StageId = undefined,
    visited_len: usize = 0,

    pub fn init(world_seed: i64, cx: i32, cz: i32) GenCtx {
        return .{
            .world_seed = world_seed,
            .cx = cx,
            .cz = cz,
            .rng = java_random.JavaRandom.init(world_seed),
        };
    }

    /// Record a stage visit (test/debug; proves pipeline order end to end).
    pub fn mark(self: *GenCtx, s: StageId) void {
        std.debug.assert(self.visited_len < self.visited.len);
        self.visited[self.visited_len] = s;
        self.visited_len += 1;
    }

    pub fn visitedOrder(self: *const GenCtx) []const StageId {
        return self.visited[0..self.visited_len];
    }
};

/// One pipeline stage: fixed id + run fn operating on the shared context.
pub const Stage = struct {
    id: StageId,
    run: *const fn (*GenCtx) void,
};

/// Run stages in declaration order. Comptime unrolled: zero dispatch cost,
/// and a misplaced stage is a compile-time-visible list, not a vtable.
pub fn runPipeline(ctx: *GenCtx, comptime stages: []const Stage) void {
    inline for (stages) |st| {
        ctx.mark(st.id);
        st.run(ctx);
    }
}

// ---------------------------------------------------------------------------
// Tests: order + determinism with stub stages (real stages land in H2).

const Stub = struct {
    fn noop(_: *GenCtx) void {}
};

const canonical_stages = [_]Stage{
    .{ .id = .biome, .run = Stub.noop },
    .{ .id = .shaper, .run = Stub.noop },
    .{ .id = .surface, .run = Stub.noop },
    .{ .id = .carver, .run = Stub.noop },
    .{ .id = .features, .run = Stub.noop },
    .{ .id = .structures, .run = Stub.noop },
};

test "pipeline visits stages in canonical order" {
    var ctx = GenCtx.init(1234, 3, -7);
    runPipeline(&ctx, &canonical_stages);
    try std.testing.expectEqualSlices(StageId, &StageId.order(), ctx.visitedOrder());
}

test "same seed twice gives identical rng streams" {
    var a = GenCtx.init(42, 0, 0);
    var b = GenCtx.init(42, 0, 0);
    runPipeline(&a, &canonical_stages);
    runPipeline(&b, &canonical_stages);
    for (0..8) |_| {
        try std.testing.expectEqual(a.rng.nextInt(), b.rng.nextInt());
    }
    try std.testing.expectEqualSlices(StageId, a.visitedOrder(), b.visitedOrder());
}

test "StageId.order matches declaration order" {
    try std.testing.expectEqual(StageId.biome, StageId.order()[0]);
    try std.testing.expectEqual(StageId.structures, StageId.order()[5]);
}
