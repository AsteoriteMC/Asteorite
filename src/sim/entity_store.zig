//! SoA entity store + SIMD fast paths — Phase D.
//!
//! "A4's mob/player tracking is AoS today — migrate it, never add new AoS
//! stores": this module is the replacement. Positions, velocities and AABB
//! bounds live in separate contiguous arrays, so a tick touches one cache
//! line per component instead of striding through a struct-of-everything.
//!
//! The SIMD paths are scalar-first: every vectorized routine has a scalar
//! twin (`*Scalar`) that is the reference implementation, and the unit
//! tests assert the two agree bit-for-bit. Vectorization is only worth it
//! where the work is data-parallel and branch-free — position integration
//! and AABB overlap. Byte-stream parsing (VarInt) is branch-bound and is
//! NOT vectorized here (measured: no win, see tools/bench.zig).
//!
//! The vector width is 4 lanes of f64 / f32: on x86_64 that maps to AVX
//! (256-bit) and on aarch64 to NEON (128-bit) — the same source compiles to
//! both, and `zig build bench` reports the asm check.

const std = @import("std");
const mob = @import("../game/mob.zig");

pub const lanes: usize = 4;

/// Axis-aligned bounding box (f32 like vanilla's entity AABB math).
pub const Aabb = struct {
    min_x: f32,
    min_y: f32,
    min_z: f32,
    max_x: f32,
    max_y: f32,
    max_z: f32,

    pub fn fromCenter(x: f64, y: f64, z: f64, half: f64) Aabb {
        return .{
            .min_x = @floatCast(x - half),
            .min_y = @floatCast(y - half),
            .min_z = @floatCast(z - half),
            .max_x = @floatCast(x + half),
            .max_y = @floatCast(y + half),
            .max_z = @floatCast(z + half),
        };
    }
};

/// Scalar reference: `pos[i] += vel[i] * dt`.
pub fn integrateScalar(pos: []f64, vel: []f64, dt: f64) void {
    const n = @min(pos.len, vel.len);
    for (0..n) |i| pos[i] += vel[i] * dt;
}

/// SIMD: `pos[i] += vel[i] * dt`, four entities at a time.
///
/// The arrays are contiguous (SoA), so each lane pair is two adjacent
/// 32-byte loads — the shape the prefetcher likes.
pub fn integrateVector(pos: []f64, vel: []f64, dt: f64) void {
    const V = @Vector(lanes, f64);
    const n = @min(pos.len, vel.len);
    const d: V = @splat(dt);
    var i: usize = 0;
    while (i + lanes <= n) : (i += lanes) {
        const p: V = pos[i..][0..lanes].*;
        const v: V = vel[i..][0..lanes].*;
        const out = p + v * d;
        pos[i..][0..lanes].* = @as([lanes]f64, out);
    }
    while (i < n) : (i += 1) pos[i] += vel[i] * dt;
}

/// Scalar reference: does box `i` overlap `q`?
pub fn aabbOverlapScalar(a: Aabb, q: Aabb) bool {
    return a.min_x <= q.max_x and a.max_x >= q.min_x and
        a.min_y <= q.max_y and a.max_y >= q.min_y and
        a.min_z <= q.max_z and a.max_z >= q.min_z;
}

/// SIMD overlap: returns a bitmask of the boxes that overlap `q`
/// (bit i = box i; only the first 64 boxes are considered).
pub fn aabbOverlapMask(boxes: []const Aabb, q: Aabb) u64 {
    const V = @Vector(lanes, f32);
    const qmin = V{ q.min_x, q.min_y, q.min_z, q.min_x };
    const qmax = V{ q.max_x, q.max_y, q.max_z, q.max_x };
    // weights turn the 4 lane results into a 4-bit mask.
    const weights: V = .{ 1.0, 2.0, 4.0, 8.0 };
    var mask: u64 = 0;
    const n = @min(boxes.len, 64);
    var i: usize = 0;
    while (i + lanes <= n) : (i += lanes) {
        const min_x: V = .{ boxes[i].min_x, boxes[i + 1].min_x, boxes[i + 2].min_x, boxes[i + 3].min_x };
        const min_y: V = .{ boxes[i].min_y, boxes[i + 1].min_y, boxes[i + 2].min_y, boxes[i + 3].min_y };
        const min_z: V = .{ boxes[i].min_z, boxes[i + 1].min_z, boxes[i + 2].min_z, boxes[i + 3].min_z };
        const max_x: V = .{ boxes[i].max_x, boxes[i + 1].max_x, boxes[i + 2].max_x, boxes[i + 3].max_x };
        const max_y: V = .{ boxes[i].max_y, boxes[i + 1].max_y, boxes[i + 2].max_y, boxes[i + 3].max_y };
        const max_z: V = .{ boxes[i].max_z, boxes[i + 1].max_z, boxes[i + 2].max_z, boxes[i + 3].max_z };
        // per-lane hit test (axis-aligned, inclusive)
        const hit = (min_x <= qmax) & (max_x >= qmin) &
            (min_y <= @as(V, @splat(q.max_y))) & (max_y >= @as(V, @splat(q.min_y))) &
            (min_z <= @as(V, @splat(q.max_z))) & (max_z >= @as(V, @splat(q.min_z)));
        const bits: V = @select(f32, hit, @as(V, @splat(1.0)), @as(V, @splat(0.0)));
        const bits4: u32 = @intFromFloat(@reduce(.Add, bits * weights));
        mask |= @as(u64, bits4) << @intCast(i);
    }
    // Tail (fewer than `lanes` boxes left): scalar.
    while (i < n) : (i += 1) {
        if (aabbOverlapScalar(boxes[i], q)) mask |= @as(u64, 1) << @intCast(i);
    }
    return mask;
}

/// SoA mob store.
///
/// One mob = one slot per component array. Slots are reused via
/// swap-remove (order is not meaningful for mobs).
pub const MobStore = struct {
    allocator: std.mem.Allocator,
    ids: std.ArrayListUnmanaged(i32) = .empty,
    kinds: std.ArrayListUnmanaged(mob.Kind) = .empty,
    px: std.ArrayListUnmanaged(f64) = .empty,
    py: std.ArrayListUnmanaged(f64) = .empty,
    pz: std.ArrayListUnmanaged(f64) = .empty,
    vx: std.ArrayListUnmanaged(f64) = .empty,
    vy: std.ArrayListUnmanaged(f64) = .empty,
    vz: std.ArrayListUnmanaged(f64) = .empty,
    yaw: std.ArrayListUnmanaged(f32) = .empty,
    health: std.ArrayListUnmanaged(f32) = .empty,
    home_x: std.ArrayListUnmanaged(f64) = .empty,
    home_z: std.ArrayListUnmanaged(f64) = .empty,
    patrol_r: std.ArrayListUnmanaged(f64) = .empty,
    leg: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) MobStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MobStore) void {
        self.ids.deinit(self.allocator);
        self.kinds.deinit(self.allocator);
        self.px.deinit(self.allocator);
        self.py.deinit(self.allocator);
        self.pz.deinit(self.allocator);
        self.vx.deinit(self.allocator);
        self.vy.deinit(self.allocator);
        self.vz.deinit(self.allocator);
        self.yaw.deinit(self.allocator);
        self.health.deinit(self.allocator);
        self.home_x.deinit(self.allocator);
        self.home_z.deinit(self.allocator);
        self.patrol_r.deinit(self.allocator);
        self.leg.deinit(self.allocator);
    }

    pub fn len(self: *const MobStore) usize {
        return self.ids.items.len;
    }

    pub fn isEmpty(self: *const MobStore) bool {
        return self.ids.items.len == 0;
    }

    fn ensure(self: *MobStore, n: usize) !void {
        if (self.ids.capacity >= n) return;
        try self.ids.ensureTotalCapacity(self.allocator, n);
        try self.kinds.ensureTotalCapacity(self.allocator, n);
        try self.px.ensureTotalCapacity(self.allocator, n);
        try self.py.ensureTotalCapacity(self.allocator, n);
        try self.pz.ensureTotalCapacity(self.allocator, n);
        try self.vx.ensureTotalCapacity(self.allocator, n);
        try self.vy.ensureTotalCapacity(self.allocator, n);
        try self.vz.ensureTotalCapacity(self.allocator, n);
        try self.yaw.ensureTotalCapacity(self.allocator, n);
        try self.health.ensureTotalCapacity(self.allocator, n);
        try self.home_x.ensureTotalCapacity(self.allocator, n);
        try self.home_z.ensureTotalCapacity(self.allocator, n);
        try self.patrol_r.ensureTotalCapacity(self.allocator, n);
        try self.leg.ensureTotalCapacity(self.allocator, n);
    }

    pub const Mob = struct {
        id: i32,
        kind: mob.Kind,
        x: f64,
        y: f64,
        z: f64,
        yaw: f32,
        health: f32,
        home_x: f64,
        home_z: f64,
        patrol_r: f64,
    };

    /// Append a mob. Returns its slot index.
    pub fn add(self: *MobStore, m: Mob) !usize {
        const n = self.len();
        try self.ensure(n + 1);
        self.ids.append(self.allocator, m.id) catch unreachable;
        self.kinds.append(self.allocator, m.kind) catch unreachable;
        self.px.append(self.allocator, m.x) catch unreachable;
        self.py.append(self.allocator, m.y) catch unreachable;
        self.pz.append(self.allocator, m.z) catch unreachable;
        self.vx.append(self.allocator, 0) catch unreachable;
        self.vy.append(self.allocator, 0) catch unreachable;
        self.vz.append(self.allocator, 0) catch unreachable;
        self.yaw.append(self.allocator, m.yaw) catch unreachable;
        self.health.append(self.allocator, m.health) catch unreachable;
        self.home_x.append(self.allocator, m.home_x) catch unreachable;
        self.home_z.append(self.allocator, m.home_z) catch unreachable;
        self.patrol_r.append(self.allocator, m.patrol_r) catch unreachable;
        self.leg.append(self.allocator, 0) catch unreachable;
        return n;
    }

    /// Remove slot `i` (swap-remove; order is not meaningful).
    pub fn removeAt(self: *MobStore, i: usize) void {
        const last = self.len() - 1;
        if (i != last) {
            self.ids.items[i] = self.ids.items[last];
            self.kinds.items[i] = self.kinds.items[last];
            self.px.items[i] = self.px.items[last];
            self.py.items[i] = self.py.items[last];
            self.pz.items[i] = self.pz.items[last];
            self.vx.items[i] = self.vx.items[last];
            self.vy.items[i] = self.vy.items[last];
            self.vz.items[i] = self.vz.items[last];
            self.yaw.items[i] = self.yaw.items[last];
            self.health.items[i] = self.health.items[last];
            self.home_x.items[i] = self.home_x.items[last];
            self.home_z.items[i] = self.home_z.items[last];
            self.patrol_r.items[i] = self.patrol_r.items[last];
            self.leg.items[i] = self.leg.items[last];
        }
        _ = self.ids.pop();
        _ = self.kinds.pop();
        _ = self.px.pop();
        _ = self.py.pop();
        _ = self.pz.pop();
        _ = self.vx.pop();
        _ = self.vy.pop();
        _ = self.vz.pop();
        _ = self.yaw.pop();
        _ = self.health.pop();
        _ = self.home_x.pop();
        _ = self.home_z.pop();
        _ = self.patrol_r.pop();
        _ = self.leg.pop();
    }

    pub fn indexOfId(self: *const MobStore, id: i32) ?usize {
        for (self.ids.items, 0..) |e, i| if (e == id) return i;
        return null;
    }

    /// Square patrol waypoint for slot `i` (vanilla-ish demo mob).
    pub fn waypoint(self: *const MobStore, i: usize) struct { x: f64, z: f64 } {
        const r = self.patrol_r.items[i];
        return switch (self.leg.items[i] % 4) {
            0 => .{ .x = self.home_x.items[i] + r, .z = self.home_z.items[i] },
            1 => .{ .x = self.home_x.items[i] + r, .z = self.home_z.items[i] + r },
            2 => .{ .x = self.home_x.items[i], .z = self.home_z.items[i] + r },
            else => .{ .x = self.home_x.items[i], .z = self.home_z.items[i] },
        };
    }

    /// Compute the velocity toward the current waypoint for every mob.
    /// `step` is the distance a mob may travel this tick.
    pub fn computeWanderVelocity(self: *MobStore, step: f64) void {
        const n = self.len();
        for (0..n) |i| {
            const wp = self.waypoint(i);
            const dx = wp.x - self.px.items[i];
            const dz = wp.z - self.pz.items[i];
            const dist = @sqrt(dx * dx + dz * dz);
            if (dist < 0.6) {
                self.leg.items[i] = (self.leg.items[i] + 1) % 4;
                self.vx.items[i] = 0;
                self.vz.items[i] = 0;
                continue;
            }
            const travel = @min(step, dist);
            self.vx.items[i] = dx / dist * travel;
            self.vz.items[i] = dz / dist * travel;
            self.yaw.items[i] = @floatCast(std.math.atan2(dx, dz) * 180.0 / std.math.pi);
        }
    }

    /// Integrate every mob: `pos += vel * dt`.
    pub fn integrate(self: *MobStore, dt: f64) void {
        integrateVector(self.px.items, self.vx.items, dt);
        integrateVector(self.py.items, self.vy.items, dt);
        integrateVector(self.pz.items, self.vz.items, dt);
    }

    /// Tick: compute wander velocity, then integrate (dt = 1 tick).
    pub fn tick(self: *MobStore, step: f64) void {
        self.computeWanderVelocity(step);
        self.integrate(1.0);
    }

    /// Mob snapshot (copied out; the caller frees nothing).
    pub const Snap = struct {
        id: i32,
        kind: mob.Kind,
        x: f64,
        y: f64,
        z: f64,
        yaw: f32,
        health: f32,
    };

    /// Fill `out` with up to `out.len` mob snapshots. Returns the count.
    pub fn snapshot(self: *const MobStore, out: []Snap) usize {
        const n = @min(out.len, self.len());
        for (0..n) |i| {
            out[i] = .{
                .id = self.ids.items[i],
                .kind = self.kinds.items[i],
                .x = self.px.items[i],
                .y = self.py.items[i],
                .z = self.pz.items[i],
                .yaw = self.yaw.items[i],
                .health = self.health.items[i],
            };
        }
        return n;
    }

    /// Bytes held by the component arrays (memory budget accounting).
    pub fn bytes(self: *const MobStore) usize {
        return self.ids.items.len * @sizeOf(i32) +
            self.kinds.items.len * @sizeOf(mob.Kind) +
            self.px.items.len * @sizeOf(f64) +
            self.py.items.len * @sizeOf(f64) +
            self.pz.items.len * @sizeOf(f64) +
            self.vx.items.len * @sizeOf(f64) +
            self.vy.items.len * @sizeOf(f64) +
            self.vz.items.len * @sizeOf(f64) +
            self.yaw.items.len * @sizeOf(f32) +
            self.health.items.len * @sizeOf(f32) +
            self.home_x.items.len * @sizeOf(f64) +
            self.home_z.items.len * @sizeOf(f64) +
            self.patrol_r.items.len * @sizeOf(f64) +
            self.leg.items.len * @sizeOf(u8);
    }
};

test "integrate vector matches scalar" {
    var pos_a = [_]f64{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };
    var pos_b = pos_a;
    var vel = [_]f64{ 1, -1, 0.5, 2, -3, 0.25, 0, 1, -0.5 };
    integrateScalar(&pos_a, &vel, 0.5);
    integrateVector(&pos_b, &vel, 0.5);
    for (pos_a, pos_b) |x, y| try std.testing.expectEqual(x, y);
}

test "integrate vector handles the tail" {
    var pos_a = [_]f64{ 1, 2, 3, 4, 5 };
    var pos_b = pos_a;
    var vel = [_]f64{ 1, 1, 1, 1, 1 };
    integrateScalar(&pos_a, &vel, 2);
    integrateVector(&pos_b, &vel, 2);
    for (pos_a, pos_b) |x, y| try std.testing.expectEqual(x, y);
}

test "aabb overlap mask matches the scalar test" {
    var boxes: [6]Aabb = undefined;
    boxes[0] = .{ .min_x = 0, .min_y = 0, .min_z = 0, .max_x = 1, .max_y = 1, .max_z = 1 };
    boxes[1] = .{ .min_x = 10, .min_y = 10, .min_z = 10, .max_x = 11, .max_y = 11, .max_z = 11 };
    boxes[2] = .{ .min_x = 0.5, .min_y = 0.5, .min_z = 0.5, .max_x = 2, .max_y = 2, .max_z = 2 };
    boxes[3] = .{ .min_x = -5, .min_y = -5, .min_z = -5, .max_x = -4, .max_y = -4, .max_z = -4 };
    boxes[4] = .{ .min_x = 0.2, .min_y = 0.2, .min_z = 0.2, .max_x = 0.4, .max_y = 0.4, .max_z = 0.4 };
    boxes[5] = .{ .min_x = 0.9, .min_y = 0.9, .min_z = 0.9, .max_x = 5, .max_y = 5, .max_z = 5 };
    const q = Aabb{ .min_x = 0.8, .min_y = 0.8, .min_z = 0.8, .max_x = 1.2, .max_y = 1.2, .max_z = 1.2 };
    const mask = aabbOverlapMask(&boxes, q);
    var expect: u64 = 0;
    for (boxes, 0..) |b, i| {
        if (aabbOverlapScalar(b, q)) expect |= @as(u64, 1) << @intCast(i);
    }
    try std.testing.expectEqual(expect, mask);
    try std.testing.expect((mask & 1) != 0);
    try std.testing.expect((mask & 2) == 0);
}

test "mob store: add, wander, snapshot, remove" {
    const a = std.testing.allocator;
    var s = MobStore.init(a);
    defer s.deinit();
    _ = try s.add(.{ .id = 1, .kind = .pig, .x = 0, .y = 64, .z = 0, .yaw = 0, .health = 10, .home_x = 0, .home_z = 0, .patrol_r = 4 });
    _ = try s.add(.{ .id = 2, .kind = .pig, .x = 5, .y = 64, .z = 5, .yaw = 0, .health = 10, .home_x = 5, .home_z = 5, .patrol_r = 4 });
    try std.testing.expectEqual(@as(usize, 2), s.len());

    var snaps: [4]MobStore.Snap = undefined;
    try std.testing.expectEqual(@as(usize, 2), s.snapshot(&snaps));
    try std.testing.expectEqual(@as(i32, 1), snaps[0].id);
    try std.testing.expectEqual(@as(f64, 5), snaps[1].x);

    // Wander: the mob walks toward its waypoint and stays bounded.
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        s.tick(0.5);
        try std.testing.expect(@abs(s.px.items[0]) <= 5.0);
        try std.testing.expect(@abs(s.pz.items[0]) <= 5.0);
    }
    try std.testing.expect(s.px.items[0] != 0 or s.pz.items[0] != 0);

    // Removal keeps the arrays consistent.
    const idx = s.indexOfId(2).?;
    s.removeAt(idx);
    try std.testing.expectEqual(@as(usize, 1), s.len());
    try std.testing.expect(s.indexOfId(2) == null);
    try std.testing.expectEqual(@as(i32, 1), s.ids.items[0]);
}

test "mob store tick matches legacy AoS wanderStep (server migration golden)" {
    // The live server ticked `entity.Mob.wanderStep`; it now runs
    // `MobStore.tick` on the same herd. Same starts, N ticks: positions
    // agree to 1e-9 (the SoA form multiplies in a different order, so the
    // last ulp can differ — 1/32-block quantization makes that invisible),
    // yaw and leg agree exactly.
    const entity = @import("entity.zig");
    const a = std.testing.allocator;
    var s = MobStore.init(a);
    defer s.deinit();
    var herd: [6]entity.Mob = undefined;
    const starts = [_]struct { x: f64, z: f64, r: f64 }{
        .{ .x = 0, .z = 0, .r = 4 },
        .{ .x = 10.5, .z = -3.25, .r = 4 },
        .{ .x = -7.75, .z = 12.0, .r = 0.5 },
        .{ .x = 100.125, .z = 100.75, .r = 8 },
        .{ .x = -0.5, .z = -0.5, .r = 4 },
        .{ .x = 3.375, .z = 9.625, .r = 2 },
    };
    for (starts, 0..) |st, i| {
        herd[i] = .{
            .id = @intCast(i + 1),
            .kind = .pig,
            .x = st.x,
            .y = 64,
            .z = st.z,
            .yaw = 0,
            .health = 10,
            .home_x = st.x,
            .home_z = st.z,
            .patrol_r = st.r,
        };
        _ = try s.add(.{
            .id = @intCast(i + 1),
            .kind = .pig,
            .x = st.x,
            .y = 64,
            .z = st.z,
            .yaw = 0,
            .health = 10,
            .home_x = st.x,
            .home_z = st.z,
            .patrol_r = st.r,
        });
    }
    var t: usize = 0;
    while (t < 500) : (t += 1) {
        for (&herd) |*m| m.wanderStep(0.5);
        s.tick(0.5);
        for (herd, 0..) |m, i| {
            try std.testing.expectApproxEqAbs(m.x, s.px.items[i], 1e-9);
            try std.testing.expectApproxEqAbs(m.z, s.pz.items[i], 1e-9);
            try std.testing.expectEqual(m.yaw, s.yaw.items[i]);
            try std.testing.expectEqual(m.leg, s.leg.items[i]);
        }
    }
}

test "mob store removeAt swaps the last slot in" {
    const a = std.testing.allocator;
    var s = MobStore.init(a);
    defer s.deinit();
    for ([_]i32{ 10, 20, 30 }) |id| {
        _ = try s.add(.{ .id = id, .kind = .pig, .x = 0, .y = 0, .z = 0, .yaw = 0, .health = 1, .home_x = 0, .home_z = 0, .patrol_r = 1 });
    }
    s.removeAt(0);
    try std.testing.expectEqual(@as(usize, 2), s.len());
    try std.testing.expectEqual(@as(i32, 30), s.ids.items[0]);
    try std.testing.expectEqual(@as(usize, 2), s.ids.items.len);
    try std.testing.expectEqual(s.ids.items.len, s.px.items.len);
    try std.testing.expectEqual(s.ids.items.len, s.leg.items.len);
}
