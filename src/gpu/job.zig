//! G1 async GPU job interface (unwired, see README.md).
//!
//! One job interface, budgeted per tick — the shape the GenPool wiring will
//! use later. This file owns ONLY the contract; it imports nothing from the
//! server so the bench agent's tree cannot conflict with it.
//!
//! Hard rules (from TODO.md Phase G + the G1 plan):
//! - Async bulk jobs only, never on the critical 50ms path. The tick polls,
//!   never waits: queue-full or over-budget submits decline and the chunk
//!   falls back to the CPU path that same tick.
//! - Bit-identical: GPU output must equal the CPU bytes exactly. The v1
//!   kernel set is integer-exact by construction (threshold/table/mask
//!   combines over CPU-computed buffers); float reimplementation of the
//!   noise core is explicitly out of scope (H5 forbids touching noise
//!   internals, and Vulkan f32 != Java StrictMath bit-for-bit).
//! - CPU fallback for every job (flag-off and queue-full paths must be
//!   correct, just slower). This interface cannot express "GPU or bust".

const std = @import("std");

/// v1 kernel set. Integer-exact combines over CPU-owned buffers. Explosion
/// raycast / fluid CA / A* / LoS are NOT listed: K4/L1 CPU references must
/// exist first (TODO.md), and each needs its own golden before it earns a
/// variant here.
pub const JobKind = enum {
    /// Block fill from a CPU-computed density field: per-cell threshold
    /// compare + id select. Pure integer compare on the GPU side.
    density_threshold,
    /// Surface-rule application over column batches: table lookups keyed
    /// by CPU-computed depth/biome ids. No float on the GPU side.
    /// STATUS: measured + deprioritized — see SURFACE_DESIGN.md. The
    /// shared RNG stream (491µs/chunk floor, data-dependent counts) caps
    /// the win at ~480µs/chunk for a complex kernel; fill + batching is
    /// the better spend. Contract stays valid; kernel not built.
    surface_apply,
    /// Carver-mask combine: boolean ops merging cave/ravine masks into the
    /// fill. No float on the GPU side.
    carve_combine,
};

/// What the job covers. Chunks stay the unit (pure function
/// f(worldSeed, chunkXZ) like the pipeline driver); regions batch them.
pub const JobScope = struct {
    dim: u8,
    /// Center chunk + radius in chunks (radius 0 = single chunk).
    cx: i32,
    cz: i32,
    radius: u16,
    seed: i64,
};

/// Host-side buffer descriptor. Staging memory stays host-visible; the
/// backend copies to device-local behind this descriptor at dispatch time
/// (discrete path) or maps it directly (UMA path, G2 — same interface).
pub const BufferView = struct {
    ptr: [*]u8,
    len: usize,

    pub fn bytes(self: BufferView) []u8 {
        return self.ptr[0..self.len];
    }
};

pub const JobId = u64;

pub const Job = struct {
    id: JobId,
    kind: JobKind,
    scope: JobScope,
    /// Backend reads inputs, writes outputs. Lengths are part of the
    /// contract: a backend that would overrun declines instead of
    /// truncating (truncation breaks bit-identical silently).
    inputs: []const BufferView,
    outputs: []BufferView,
};

/// Submit outcomes. There is no blocking submit and no error return for
/// "busy": decline reasons are values so the caller falls back on-path.
pub const SubmitResult = enum {
    accepted,
    /// Queue full or tick budget spent: run this job on CPU this tick.
    declined_busy,
    /// No device / init failed: run on CPU, stop offering until re-probed.
    declined_no_device,
};

/// Completion observed by polling (tick-aligned readback).
pub const PollResult = enum {
    pending,
    complete,
    /// Device lost / dispatch failed: outputs untouched, CPU must redo.
    failed,
};

/// Backend vtable. Lifetimes: the backend never owns job buffers; inputs
/// stay valid until `poll` reports terminal, outputs are written exactly
/// once on `complete`.
pub const BackendVTable = struct {
    name: []const u8,
    submit: *const fn (ctx: *anyopaque, job: *const Job) SubmitResult,
    poll: *const fn (ctx: *anyopaque, id: JobId) PollResult,
};

pub const Backend = struct {
    ctx: *anyopaque,
    vtable: *const BackendVTable,

    pub fn submit(self: Backend, job: *const Job) SubmitResult {
        return self.vtable.submit(self.ctx, job);
    }

    pub fn poll(self: Backend, id: JobId) PollResult {
        return self.vtable.poll(self.ctx, id);
    }
};

/// Per-tick dispatch budget. The tick sets `budget_ns` (from
/// `--gpu-budget-ms` at wiring time) and calls `consume` per dispatch;
/// once spent, further submits decline with `declined_busy`. Integer ns,
/// monotonic clock deltas — no float, no allocation.
pub const TickBudget = struct {
    budget_ns: u64,
    spent_ns: u64 = 0,

    pub fn remaining(self: TickBudget) u64 {
        return self.budget_ns -| self.spent_ns;
    }

    pub fn consume(self: *TickBudget, cost_ns: u64) bool {
        if (cost_ns > self.remaining()) return false;
        self.spent_ns += cost_ns;
        return true;
    }

    pub fn reset(self: *TickBudget) void {
        self.spent_ns = 0;
    }
};

/// Bit-compare helper for golden tests (CPU vs GPU bytes). Length mismatch
/// is failure, not truncation — see `Job` docs.
pub fn expectBitIdentical(a: []const u8, b: []const u8) !void {
    // No std.testing.expectEqual here: those print on mismatch, and this
    // helper is exercised with intentional mismatches (expectError) whose
    // stderr breaks the `--listen` build runner. Explicit errors preserve
    // the reject-drift contract silently.
    if (a.len != b.len) return error.TestExpectedEqual;
    if (!std.mem.eql(u8, a, b)) return error.TestExpectedEqual;
}

// ---------------------------------------------------------------------------
// Tests: contract mechanics only (no device needed).
// ---------------------------------------------------------------------------

const FakeBackend = struct {
    full: bool,
    submitted: u64 = 0,

    fn submitFn(ctx: *anyopaque, job: *const Job) SubmitResult {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx));
        if (self.full) return .declined_busy;
        self.submitted += 1;
        _ = job;
        return .accepted;
    }

    fn pollFn(ctx: *anyopaque, id: JobId) PollResult {
        _ = ctx;
        _ = id;
        return .complete;
    }

    const vtable = BackendVTable{
        .name = "fake",
        .submit = submitFn,
        .poll = pollFn,
    };

    fn backend(self: *FakeBackend) Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

test "decline-on-full falls back without touching buffers" {
    var fake = FakeBackend{ .full = true };
    const be = fake.backend();
    var out_mem: [4]u8 = .{ 0, 0, 0, 0 };
    var out = BufferView{ .ptr = &out_mem, .len = out_mem.len };
    const job = Job{
        .id = 7,
        .kind = .density_threshold,
        .scope = .{ .dim = 0, .cx = 0, .cz = 0, .radius = 0, .seed = 42 },
        .inputs = &.{},
        .outputs = @as(*[1]BufferView, &out)[0..],
    };
    try std.testing.expectEqual(SubmitResult.declined_busy, be.submit(&job));
    try std.testing.expectEqual(@as(u64, 0), fake.submitted);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &out_mem);
}

test "accept then poll completes" {
    var fake = FakeBackend{ .full = false };
    const be = fake.backend();
    const job = Job{
        .id = 1,
        .kind = .surface_apply,
        .scope = .{ .dim = 0, .cx = 3, .cz = -7, .radius = 1, .seed = 42 },
        .inputs = &.{},
        .outputs = &.{},
    };
    try std.testing.expectEqual(SubmitResult.accepted, be.submit(&job));
    try std.testing.expectEqual(PollResult.complete, be.poll(1));
}

test "tick budget spends, blocks, resets" {
    var b = TickBudget{ .budget_ns = 1000 };
    try std.testing.expect(b.consume(600));
    try std.testing.expect(!b.consume(500));
    try std.testing.expectEqual(@as(u64, 400), b.remaining());
    try std.testing.expect(b.consume(400));
    try std.testing.expectEqual(@as(u64, 0), b.remaining());
    b.reset();
    try std.testing.expectEqual(@as(u64, 1000), b.remaining());
}

test "bit-compare rejects length and content drift" {
    try expectBitIdentical(&.{ 1, 2, 3 }, &.{ 1, 2, 3 });
    try std.testing.expectError(error.TestExpectedEqual, expectBitIdentical(&.{ 1, 2 }, &.{ 1, 2, 3 }));
    try std.testing.expectError(error.TestExpectedEqual, expectBitIdentical(&.{ 1, 2, 3 }, &.{ 1, 2, 4 }));
}
