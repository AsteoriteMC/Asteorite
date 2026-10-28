//! Deterministic region tick loop (20 TPS / 50ms budget).
//!
//! Folia-style: each 32x32-chunk region ticks independently and owns its
//! mob list; cross-region moves go through the target region's MPSC inbox
//! as full-state transfers, adopted by next tick's drain (delete-at-drain:
//! every snapshot holds exactly one copy). The viewer pass runs on a
//! persistent pool of stable workers (see pool.zig; fork-join survives as
//! the fallback); the barrier — pool generation or thread join — is the
//! global sync point. Time-of-day/weather publish through atomics only
//! (TickClock), never a global world lock. No global world lock.

const std = @import("std");
const mpsc = @import("mpsc.zig");
const spin = @import("spin.zig");
const affinity = @import("affinity.zig");
const mobstore_mod = @import("../entity/entity_store.zig");
const mob = @import("../../game/mob.zig");

pub const tick_budget_ns: u64 = 50_000_000; // 20 TPS

/// Load-shedding trip point: a region whose p99 tick exceeds this over a
/// window is degraded (that region only — lag machines must cost a region,
/// never global TPS).
pub const shed_p99_ns: u64 = 15_000_000;
pub const shed_enter_ticks: u8 = 3;
pub const shed_exit_ticks: u8 = 5;
pub const shed_window: usize = 16;

/// Hard cap on fork-join workers per tick (more regions than this share
/// workers via bigger slices — still correct, still one tick per region).
pub const max_workers = 64;

/// Ticks are 32 chunks (matches the storage shard regions: one tick unit
/// owns whole chunks, never split mid-tick).
pub const region_size = 32;

pub fn regionOf(chunk_coord: i32) i32 {
    return @divFloor(chunk_coord, region_size);
}

pub const RegionId = struct {
    dim: u8,
    rx: i32,
    rz: i32,
};

/// Region id for a block position (chunk = floor(pos/16), region =
/// floored div by 32). Negative coords floor, matching the shard map.
pub fn regionIdFor(dim: u8, x: f64, z: f64) RegionId {
    const cx = @as(i32, @intFromFloat(@floor(x / 16.0)));
    const cz = @as(i32, @intFromFloat(@floor(z / 16.0)));
    return .{ .dim = dim, .rx = regionOf(cx), .rz = regionOf(cz) };
}

/// Cross-region handoff message (fixed-size, no allocation on push).
/// Player crossings carry identity + position only; mob crossings carry
/// the full mob state so the target region can adopt the slot (the
/// fields below default so player-crossing literals keep compiling).
pub const Transfer = struct {
    entity_id: u64,
    from_dim: u8,
    from_rx: i32,
    from_rz: i32,
    x: f64,
    y: f64,
    z: f64,
    /// True for mob handoffs (adopt into the target store); false for
    /// player crossings (census bump only — players live in conns).
    is_mob: bool = false,
    kind: mob.Kind = .pig,
    yaw: f32 = 0,
    health: f32 = 0,
    home_x: f64 = 0,
    home_z: f64 = 0,
    patrol_r: f64 = 0,
};

pub const Region = struct {
    id: RegionId,
    ticks: u64 = 0,
    overruns: u64 = 0,
    last_tick_ns: u64 = 0,
    inbox: mpsc.Queue(Transfer),
    /// Region-owned mob list (authoritative handoff target). Only touched
    /// under the server's ent_lock (ticker mob section, summon, attack);
    /// the registry lock guards the map, never the contents.
    mobs: mobstore_mod.MobStore,
    // Phase C: rolling timing window + load-shedding breaker. Written by
    // the region's owning worker only (fork-join: disjoint regions), read
    // by the merge pass after the join — never shared-mutable mid-tick.
    samples: [shed_window]u64 = undefined,
    samples_n: usize = 0,
    samples_idx: usize = 0,
    shed: bool = false,
    /// Entries into shed (the `region_shed` stats counter sums deltas).
    shed_events: u64 = 0,
    bad_streak: u8 = 0,
    good_streak: u8 = 0,
    /// Entities handed in through the inbox since boot (load signal).
    census: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, id: RegionId) Region {
        return .{ .id = id, .inbox = mpsc.Queue(Transfer).init(allocator), .mobs = mobstore_mod.MobStore.init(allocator) };
    }

    pub fn deinit(self: *Region) void {
        self.mobs.deinit();
        self.inbox.deinit();
    }

    /// Adopt a drained mob handoff into this region's store. The source
    /// copy is deleted by the drain loop after adoption (delete-at-drain:
    /// every snapshot holds exactly one copy, attacks never miss).
    pub fn adoptMob(self: *Region, t: Transfer) !void {
        _ = try self.mobs.add(.{
            .id = @intCast(t.entity_id),
            .kind = t.kind,
            .x = t.x,
            .y = t.y,
            .z = t.z,
            .yaw = t.yaw,
            .health = t.health,
            .home_x = t.home_x,
            .home_z = t.home_z,
            .patrol_r = t.patrol_r,
        });
    }

    /// Record one tick duration and run the breaker. p99 over the window
    /// above 15ms for `shed_enter_ticks` straight ticks sheds; below it
    /// for `shed_exit_ticks` recovers (automatic, no operator action).
    pub fn recordSample(self: *Region, ns: u64) void {
        self.samples[self.samples_idx] = ns;
        self.samples_idx = (self.samples_idx + 1) % self.samples.len;
        if (self.samples_n < self.samples.len) self.samples_n += 1;
        self.last_tick_ns = ns;
        self.ticks += 1;
        if (ns > tick_budget_ns) self.overruns += 1;
        if (self.p99() > shed_p99_ns) {
            self.bad_streak +|= 1;
            self.good_streak = 0;
        } else {
            self.good_streak +|= 1;
            self.bad_streak = 0;
        }
        if (!self.shed and self.bad_streak >= shed_enter_ticks) {
            self.shed = true;
            self.shed_events += 1;
            self.bad_streak = 0;
        } else if (self.shed and self.good_streak >= shed_exit_ticks) {
            self.shed = false;
            self.good_streak = 0;
        }
    }

    /// p99 of the timing window (0 when empty). The ring is chronological;
    /// copy in oldest-first order so the percentile is over samples, not
    /// slots (order is irrelevant to the sort, but keep it honest).
    pub fn p99(self: *const Region) u64 {
        if (self.samples_n == 0) return 0;
        var sorted: [shed_window]u64 = undefined;
        const start = (self.samples_idx + self.samples.len - self.samples_n) % self.samples.len;
        for (0..self.samples_n) |k| {
            sorted[k] = self.samples[(start + k) % self.samples.len];
        }
        std.mem.sort(u64, sorted[0..self.samples_n], {}, std.sort.asc(u64));
        const idx = (self.samples_n * 99) / 100;
        return sorted[@min(idx, self.samples_n - 1)];
    }
};

pub const Stats = struct {
    regions: usize,
    total_ns: u64,
    overruns: usize,
};

/// Tick one region: time the handler, record the sample (overrun + shed
/// accounting ride along). Shared by the sequential and parallel paths so
/// both measure identically.
pub fn tickOne(io: std.Io, r: *Region, tick_no: u64, handler: *const fn (*Region, u64) void) void {
    const t0 = std.Io.Timestamp.now(io, .awake);
    handler(r, tick_no);
    const dt_i96 = t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
    r.recordSample(@intCast(@max(0, dt_i96)));
}

/// Run one global tick over all regions. The handler owns per-region logic
/// (physics/AI/save) and must drain `region.inbox` for handoffs.
/// Overrun = single region exceeding the 50ms budget (counts, never blocks).
pub fn tickOnce(
    io: std.Io,
    regions: []*Region,
    tick_no: u64,
    handler: *const fn (*Region, u64) void,
) Stats {
    for (regions) |r| tickOne(io, r, tick_no, handler);
    return accumulate(regions);
}

/// Parallel tick: one worker per region slice (fork-join over the calling
/// thread — the join IS the global barrier). Deterministic within a
/// region: each region is ticked exactly once, in slice order, and inbox
/// drains are FIFO, so a region's event order matches the sequential
/// path; across regions delivery may interleave (fine by design).
///
/// `max_threads` <= 1 (or a single region) runs the sequential path.
/// `cpus` optionally pins worker i to cpus[i] (see affinity.assignRegions;
/// pinning is advisory and never affects correctness). The handler must
/// only touch its own region plus thread-safe shared state (snapshots,
/// lock-free queues, per-conn locks on disjoint conns).
///
/// Spawn failure degrades to sequential for the unspawned slices (still
/// correct, just slower) — a tick never fails for want of a thread.
pub fn tickParallel(
    io: std.Io,
    regions: []*Region,
    tick_no: u64,
    handler: *const fn (*Region, u64) void,
    max_threads: usize,
    cpus: ?[]const usize,
) Stats {
    if (max_threads <= 1 or regions.len <= 1) return tickOnce(io, regions, tick_no, handler);
    const n = @min(@min(max_threads, regions.len), max_workers);
    const Ctx = struct {
        io: std.Io,
        slice: []*Region,
        tick_no: u64,
        handler: *const fn (*Region, u64) void,
        cpu: ?usize,
    };
    var ctxs: [max_workers]Ctx = undefined;
    var threads: [max_workers]std.Thread = undefined;
    const Run = struct {
        fn run(c: *Ctx) void {
            if (c.cpu) |cpu| affinity.pinSelf(cpu);
            for (c.slice) |r| tickOne(c.io, r, c.tick_no, c.handler);
        }
    };
    // Contiguous slices keep neighboring regions on neighboring workers
    // (which affinity pins to neighboring cores / shared L3).
    var spawned: usize = 0;
    var off: usize = 0;
    while (spawned < n) : (spawned += 1) {
        const len = (regions.len - off) / (n - spawned);
        ctxs[spawned] = .{
            .io = io,
            .slice = regions[off .. off + len],
            .tick_no = tick_no,
            .handler = handler,
            .cpu = pickCpu(cpus, spawned),
        };
        off += len;
        threads[spawned] = std.Thread.spawn(.{}, Run.run, .{&ctxs[spawned]}) catch {
            // Degraded: run this slice (and the rest) inline.
            Run.run(&ctxs[spawned]);
            runTailInline(io, regions[off..], tick_no, handler);
            off = regions.len;
            break;
        };
    }
    for (threads[0..spawned]) |t| t.join();
    return accumulate(regions);
}

/// Worker i pins to cpus[i] when the caller supplied that slot.
fn pickCpu(cpus: ?[]const usize, i: usize) ?usize {
    const cs = cpus orelse return null;
    return if (i < cs.len) cs[i] else null;
}

/// Spawn-failure fallback: tick the remaining tail inline.
fn runTailInline(io: std.Io, tail: []*Region, tick_no: u64, handler: *const fn (*Region, u64) void) void {
    for (tail) |r| tickOne(io, r, tick_no, handler);
}

/// Sum per-region timings into the tick stats (shared by both paths so
/// sequential and parallel measure identically).
fn accumulate(regions: []*Region) Stats {
    var s = Stats{ .regions = regions.len, .total_ns = 0, .overruns = 0 };
    for (regions) |r| {
        s.total_ns += r.last_tick_ns;
        if (r.last_tick_ns > tick_budget_ns) s.overruns += 1;
    }
    return s;
}

/// Hash context for region keys (explicit field hashing — no padding
/// surprises, same convention as the store's ChunkKey).
pub const KeyCtx = struct {
    pub fn hash(_: KeyCtx, k: RegionId) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(&[_]u8{k.dim});
        var b: [8]u8 = undefined;
        std.mem.writeInt(i32, b[0..4], k.rx, .little);
        std.mem.writeInt(i32, b[4..8], k.rz, .little);
        h.update(&b);
        return h.final();
    }
    pub fn eql(_: KeyCtx, a: RegionId, b: RegionId) bool {
        return a.dim == b.dim and a.rx == b.rx and a.rz == b.rz;
    }
};

/// Owns the live region set: creates regions on demand (first viewer or
/// entity in a 32x32 cell), hands out stable pointers (a region is never
/// moved or freed mid-tick — deinit only at shutdown).
///
/// Lock order (deadlock audit, Phase C follow-up): the registry lock is
/// INNERMOST. Holders of ent/world/conn locks may take it (summon, attack
/// and the tick mob section all do); code running UNDER it must never
/// take another lock. All methods below take it only around map
/// structure; region contents (inbox, mob store) are guarded by the
/// server's ent_lock, which callers must already hold when a method
/// reads them (documented per method). Region pointers stay valid after
/// unlock (never removed), so collect-then-use is exact.
pub const Registry = struct {
    map: std.HashMapUnmanaged(RegionId, *Region, KeyCtx, 80) = .{},
    lock: spin.SpinLock = .{},

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.deinit();
            allocator.destroy(e.value_ptr.*);
        }
        self.map.deinit(allocator);
    }

    /// Look up the region, creating it (empty inbox, zeroed breaker) when
    /// absent. Returns a stable pointer valid until deinit.
    pub fn getOrCreate(self: *Registry, allocator: std.mem.Allocator, id: RegionId) !*Region {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.map.get(id)) |r| return r;
        const r = try allocator.create(Region);
        r.* = Region.init(allocator, id);
        try self.map.put(allocator, id, r);
        return r;
    }

    pub fn count(self: *Registry) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.map.count();
    }

    /// Sum of shed entries across regions (the stats counter reads this).
    pub fn shedEvents(self: *Registry) usize {
        self.lock.lock();
        defer self.lock.unlock();
        var n: usize = 0;
        var it = self.map.iterator();
        while (it.next()) |e| n += @as(usize, @intCast(e.value_ptr.*.shed_events));
        return n;
    }

    /// Fill `buf` with every live region (stable pointers). Returns the
    /// count; truncates silently past `buf.len` (caller sizes for it, or
    /// heap-falls-back via count()).
    pub fn allRegions(self: *Registry, buf: []*Region) usize {
        self.lock.lock();
        defer self.lock.unlock();
        var it = self.map.iterator();
        var n: usize = 0;
        while (it.next()) |e| {
            if (n >= buf.len) break;
            buf[n] = e.value_ptr.*;
            n += 1;
        }
        return n;
    }

    /// Look up a region without creating it. Stable pointer (or null).
    pub fn lookup(self: *Registry, id: RegionId) ?*Region {
        self.lock.lock();
        defer self.lock.unlock();
        return self.map.get(id);
    }

    /// Locate the region + slot holding mob `id`, or null. Reads store
    /// contents: the server holds ent_lock (single-threaded callers
    /// need nothing).
    pub fn findMob(self: *Registry, id: i32) ?struct { region: *Region, index: usize } {
        self.lock.lock();
        defer self.lock.unlock();
        var it = self.map.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.*.mobs.indexOfId(id)) |i| {
                return .{ .region = e.value_ptr.*, .index = i };
            }
        }
        return null;
    }

    /// Total live mobs across regions (same locking as findMob).
    pub fn totalMobs(self: *Registry) usize {
        self.lock.lock();
        defer self.lock.unlock();
        var n: usize = 0;
        var it = self.map.iterator();
        while (it.next()) |e| n += e.value_ptr.*.mobs.len();
        return n;
    }

    /// Total mob-store bytes across regions (same locking as findMob).
    pub fn totalMobBytes(self: *Registry) usize {
        self.lock.lock();
        defer self.lock.unlock();
        var n: usize = 0;
        var it = self.map.iterator();
        while (it.next()) |e| n += e.value_ptr.*.mobs.bytes();
        return n;
    }
};

/// Global tick barrier for time-of-day/weather sync only (never a world
/// lock). The ticker publishes age/time once per tick; region workers
/// read them lock-free. The pool generation (or fork-join thread join)
/// is the barrier; this is the payload it carries.
pub const TickClock = struct {
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    age: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    time_of_day: std.atomic.Value(i64) = std.atomic.Value(i64).init(6000),

    pub fn publish(self: *TickClock, age: i64, tod: i64) void {
        self.age.store(age, .release);
        self.time_of_day.store(tod, .release);
        _ = self.generation.fetchAdd(1, .acq_rel);
    }

    pub const Reading = struct {
        generation: u64,
        age: i64,
        time_of_day: i64,
    };

    pub fn load(self: *const TickClock) Reading {
        // Generation first (acquire): age/tod read after are no older.
        const g0 = self.generation.load(.acquire);
        const a = self.age.load(.acquire);
        const t = self.time_of_day.load(.acquire);
        return .{ .generation = g0, .age = a, .time_of_day = t };
    }
};

test "tickOnce runs handler + counts ticks" {
    const a = std.testing.allocator;
    var r0 = Region.init(a, .{ .dim = 0, .rx = 0, .rz = 0 });
    defer r0.deinit();
    var r1 = Region.init(a, .{ .dim = 0, .rx = 1, .rz = 0 });
    defer r1.deinit();
    var regions = [_]*Region{ &r0, &r1 };
    const H = struct {
        fn h(r: *Region, n: u64) void {
            _ = n;
            // drain handoffs (none here)
            const msgs = r.inbox.drain() catch return;
            defer r.inbox.allocator.free(msgs);
        }
    };
    const s = tickOnce(std.testing.io, &regions, 1, H.h);
    try std.testing.expectEqual(@as(usize, 2), s.regions);
    try std.testing.expectEqual(@as(u64, 1), r0.ticks);
    try std.testing.expectEqual(@as(u64, 0), s.overruns);
}

test "cross-region transfer delivered on next tick" {
    const a = std.testing.allocator;
    var src = Region.init(a, .{ .dim = 0, .rx = 0, .rz = 0 });
    defer src.deinit();
    var dst = Region.init(a, .{ .dim = 0, .rx = 1, .rz = 0 });
    defer dst.deinit();
    try dst.inbox.push(.{
        .entity_id = 42,
        .from_dim = 0,
        .from_rx = 0,
        .from_rz = 0,
        .x = 33 * 16.0,
        .y = 64.0,
        .z = 0.0,
    });
    var regions = [_]*Region{ &src, &dst };
    var seen: u64 = 0;
    const H = struct {
        var out: *u64 = undefined;
        fn h(r: *Region, n: u64) void {
            _ = n;
            const msgs = r.inbox.drain() catch return;
            defer r.inbox.allocator.free(msgs);
            for (msgs) |m| out.* = m.entity_id;
        }
    };
    H.out = &seen;
    _ = tickOnce(std.testing.io, &regions, 2, H.h);
    try std.testing.expectEqual(@as(u64, 42), seen);
}

test "mob handoff is authoritative: adopt + delete, exactly once" {
    // Delete-at-drain protocol: the source keeps its copy at push time
    // (attacks never miss an in-flight mob); the drain adopts into the
    // target and deletes from the source only if still present (a mob
    // killed mid-flight is dropped, never resurrected).
    const alloc = std.heap.page_allocator;
    var reg = Registry{};
    defer reg.deinit(alloc);
    const src = try reg.getOrCreate(alloc, .{ .dim = 0, .rx = 0, .rz = 0 });
    const dst = try reg.getOrCreate(alloc, .{ .dim = 0, .rx = 1, .rz = 0 });
    _ = try src.mobs.add(.{ .id = 7, .kind = .pig, .x = 511.0, .y = 64, .z = 0, .yaw = 0, .health = 10, .home_x = 511, .home_z = 0, .patrol_r = 4 });
    // Crossing push carries full state (source copy kept).
    try dst.inbox.push(.{
        .entity_id = 7,
        .from_dim = 0,
        .from_rx = 0,
        .from_rz = 0,
        .x = 512.5,
        .y = 64,
        .z = 0,
        .is_mob = true,
        .kind = .pig,
        .yaw = 1.5,
        .health = 8,
        .home_x = 511,
        .home_z = 0,
        .patrol_r = 4,
    });
    try std.testing.expectEqual(@as(usize, 1), reg.totalMobs());
    // Drain: adopt into target, delete from source (present here).
    const msgs = try dst.inbox.drain();
    defer alloc.free(msgs);
    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    try std.testing.expect(msgs[0].is_mob);
    try dst.adoptMob(msgs[0]);
    if (src.mobs.indexOfId(7)) |i| src.mobs.removeAt(i);
    // Exactly one copy, in the target, with the pushed state.
    try std.testing.expectEqual(@as(usize, 1), reg.totalMobs());
    try std.testing.expect(src.mobs.indexOfId(7) == null);
    const found = reg.findMob(7).?;
    try std.testing.expect(found.region == dst);
    try std.testing.expectEqual(@as(f64, 512.5), dst.mobs.px.items[found.index]);
    try std.testing.expectEqual(@as(f32, 8), dst.mobs.health.items[found.index]);
    // Mid-flight kill: source copy gone at drain → transfer dropped.
    _ = try src.mobs.add(.{ .id = 9, .kind = .pig, .x = 511.0, .y = 64, .z = 0, .yaw = 0, .health = 10, .home_x = 511, .home_z = 0, .patrol_r = 4 });
    try dst.inbox.push(.{ .entity_id = 9, .from_dim = 0, .from_rx = 0, .from_rz = 0, .x = 512.5, .y = 64, .z = 0, .is_mob = true, .kind = .pig });
    // ...killed before the drain runs:
    if (src.mobs.indexOfId(9)) |i| src.mobs.removeAt(i);
    const msgs2 = try dst.inbox.drain();
    defer alloc.free(msgs2);
    for (msgs2) |m| {
        if (!m.is_mob) continue;
        if (src.mobs.indexOfId(@intCast(m.entity_id)) == null) continue; // dropped
        try dst.adoptMob(m);
    }
    try std.testing.expect(reg.findMob(9) == null);
    try std.testing.expectEqual(@as(usize, 1), reg.totalMobs());
}

test "registry mob helpers agree" {
    const alloc = std.heap.page_allocator;
    var reg = Registry{};
    defer reg.deinit(alloc);
    const a = try reg.getOrCreate(alloc, .{ .dim = 0, .rx = 0, .rz = 0 });
    const b = try reg.getOrCreate(alloc, .{ .dim = 0, .rx = 5, .rz = -3 });
    _ = try a.mobs.add(.{ .id = 1, .kind = .pig, .x = 0, .y = 64, .z = 0, .yaw = 0, .health = 10, .home_x = 0, .home_z = 0, .patrol_r = 4 });
    _ = try b.mobs.add(.{ .id = 2, .kind = .pig, .x = 0, .y = 64, .z = 0, .yaw = 0, .health = 10, .home_x = 0, .home_z = 0, .patrol_r = 4 });
    _ = try b.mobs.add(.{ .id = 3, .kind = .pig, .x = 0, .y = 64, .z = 0, .yaw = 0, .health = 10, .home_x = 0, .home_z = 0, .patrol_r = 4 });
    try std.testing.expectEqual(@as(usize, 3), reg.totalMobs());
    try std.testing.expect(reg.totalMobBytes() > 3 * @sizeOf(i32));
    const f = reg.findMob(3).?;
    try std.testing.expect(f.region == b);
    try std.testing.expect(reg.findMob(999) == null);
    var buf: [8]*Region = undefined;
    try std.testing.expectEqual(@as(usize, 2), reg.allRegions(&buf));
}

test "parallel tick matches sequential (same per-region counts)" {
    // Page allocator: workers share it (the test allocator is not for
    // concurrent use).
    const alloc = std.heap.page_allocator;
    const io = std.testing.io;
    var regs: [8]*Region = undefined;
    for (&regs, 0..) |*slot, i| {
        const r = try alloc.create(Region);
        r.* = Region.init(alloc, .{ .dim = 0, .rx = @intCast(i), .rz = 0 });
        slot.* = r;
    }
    defer for (regs) |r| {
        r.deinit();
        alloc.destroy(r);
    };
    const H = struct {
        fn h(r: *Region, n: u64) void {
            _ = n;
            // Simulate ~50us of per-region work (deterministic spin, no
            // sleep: keeps the test fast and allocation-free).
            var x: u64 = 0;
            var k: u64 = 0;
            while (k < 2000) : (k += 1) x += k;
            std.mem.doNotOptimizeAway(&x);
            const msgs = r.inbox.drain() catch return;
            defer r.inbox.allocator.free(msgs);
        }
    };
    const ticks: u64 = 5;
    var t: u64 = 0;
    while (t < ticks) : (t += 1) {
        _ = tickParallel(io, &regs, t, H.h, 4, null);
    }
    for (regs) |r| try std.testing.expectEqual(ticks, r.ticks);
    // Sequential control ticks the same way (same counts, no workers).
    var sregs: [8]*Region = undefined;
    for (&sregs, 0..) |*slot, i| {
        const r = try alloc.create(Region);
        r.* = Region.init(alloc, .{ .dim = 0, .rx = @intCast(i), .rz = 0 });
        slot.* = r;
    }
    defer for (sregs) |r| {
        r.deinit();
        alloc.destroy(r);
    };
    t = 0;
    while (t < ticks) : (t += 1) {
        _ = tickOnce(io, &sregs, t, H.h);
    }
    for (sregs) |r| try std.testing.expectEqual(ticks, r.ticks);
}

test "tick order deterministic within a region under parallel tick" {
    const alloc = std.heap.page_allocator;
    const io = std.testing.io;
    var regs: [4]*Region = undefined;
    for (&regs, 0..) |*slot, i| {
        const r = try alloc.create(Region);
        r.* = Region.init(alloc, .{ .dim = 0, .rx = @intCast(i), .rz = 0 });
        slot.* = r;
    }
    defer for (regs) |r| {
        r.deinit();
        alloc.destroy(r);
    };
    // Each region records the tick numbers it saw; parallel execution
    // may interleave regions, but a region's own sequence must be exact.
    const H = struct {
        var last: [4]u64 = [_]u64{0} ** 4;
        fn h(r: *Region, n: u64) void {
            const i: usize = @intCast(r.id.rx);
            // n starts at 1: strictly increasing per region.
            std.debug.assert(n == last[i] + 1);
            last[i] = n;
        }
    };
    var t: u64 = 1;
    while (t <= 10) : (t += 1) {
        _ = tickParallel(io, &regs, t, H.h, 4, null);
    }
    for (H.last) |v| try std.testing.expectEqual(@as(u64, 10), v);
}

test "shed breaker trips and recovers" {
    const alloc = std.testing.allocator;
    var r = Region.init(alloc, .{ .dim = 0, .rx = 0, .rz = 0 });
    defer r.deinit();
    try std.testing.expect(!r.shed);
    // 3 straight ticks over the 15ms p99 line (window still filling, but
    // every sample is hot so p99 is hot) -> shed.
    r.recordSample(20_000_000);
    try std.testing.expect(!r.shed);
    r.recordSample(20_000_000);
    try std.testing.expect(!r.shed);
    r.recordSample(20_000_000);
    try std.testing.expect(r.shed);
    try std.testing.expectEqual(@as(u64, 1), r.shed_events);
    // Still hot: no double-count, no recovery.
    r.recordSample(20_000_000);
    try std.testing.expect(r.shed);
    try std.testing.expectEqual(@as(u64, 1), r.shed_events);
    // 5 straight cool ticks -> recover (window still holds hot samples,
    // but the streak rule needs sustained cool — p99 stays hot here, so
    // feed enough cool samples to flush the window first).
    var k: usize = 0;
    while (k < shed_window + shed_exit_ticks) : (k += 1) r.recordSample(1_000_000);
    try std.testing.expect(!r.shed);
    // Re-trip counts again.
    k = 0;
    while (k < shed_enter_ticks) : (k += 1) r.recordSample(20_000_000);
    try std.testing.expect(r.shed);
    try std.testing.expectEqual(@as(u64, 2), r.shed_events);
}

test "registry creates once, concurrent create is safe" {
    const alloc = std.heap.page_allocator;
    var reg = Registry{};
    defer reg.deinit(alloc);
    const a = try reg.getOrCreate(alloc, .{ .dim = 0, .rx = 1, .rz = -2 });
    const b = try reg.getOrCreate(alloc, .{ .dim = 0, .rx = 1, .rz = -2 });
    try std.testing.expect(a == b);
    try std.testing.expectEqual(@as(usize, 1), reg.count());
    // Hammer the same keys from 8 threads (page allocator is thread-safe).
    const Hammer = struct {
        fn run(rg: *Registry, al: std.mem.Allocator, id: RegionId) void {
            var k: usize = 0;
            while (k < 200) : (k += 1) {
                _ = rg.getOrCreate(al, id) catch {};
            }
        }
    };
    const ids = [_]RegionId{
        .{ .dim = 0, .rx = 0, .rz = 0 },
        .{ .dim = 0, .rx = 1, .rz = 0 },
        .{ .dim = 1, .rx = 0, .rz = 0 },
        .{ .dim = 0, .rx = 0, .rz = 1 },
    };
    var th: [8]std.Thread = undefined;
    for (&th, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Hammer.run, .{ &reg, alloc, ids[i % ids.len] });
    for (th) |t| t.join();
    try std.testing.expectEqual(@as(usize, 5), reg.count());
    // Same-key lookups all agree after the hammer.
    const c = try reg.getOrCreate(alloc, ids[0]);
    const d = try reg.getOrCreate(alloc, ids[0]);
    try std.testing.expect(c == d);
}

test "tick clock publishes monotonically" {
    var c = TickClock{};
    c.publish(20, 6020);
    const r1 = c.load();
    try std.testing.expectEqual(@as(i64, 20), r1.age);
    try std.testing.expectEqual(@as(i64, 6020), r1.time_of_day);
    try std.testing.expectEqual(@as(u64, 1), r1.generation);
    c.publish(40, 6040);
    const r2 = c.load();
    try std.testing.expect(r2.generation > r1.generation);
    try std.testing.expectEqual(@as(i64, 40), r2.age);
}

test "regionIdFor floors negatives like the shard map" {
    // Block (0,0) -> chunk (0,0) -> region (0,0).
    const a = regionIdFor(0, 8.5, 8.5);
    try std.testing.expectEqual(RegionId{ .dim = 0, .rx = 0, .rz = 0 }, a);
    // x=-0.5 -> chunk -1 -> region -1 (floored, not truncated).
    const b = regionIdFor(0, -0.5, -0.5);
    try std.testing.expectEqual(@as(i32, -1), b.rx);
    try std.testing.expectEqual(@as(i32, -1), b.rz);
    // Region edge: chunk 31 -> region 0, chunk 32 -> region 1.
    const c = regionIdFor(0, 31 * 16.0 + 1.0, 0);
    try std.testing.expectEqual(@as(i32, 0), c.rx);
    const d = regionIdFor(0, 32 * 16.0 + 1.0, 0);
    try std.testing.expectEqual(@as(i32, 1), d.rx);
}
