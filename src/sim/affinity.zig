//! CPU topology + thread pinning for Phase C region threads.
//!
//! Folia-style region ticking only scales when region threads stay on
//! their cores: a region thread migrating across CCXs loses its L3
//! footprint every hop. This module detects the topology (best-effort,
//! `/sys` on Linux) and pins each region worker after spawn.
//!
//! Everything here degrades gracefully: detection failure yields a flat
//! 1:1 mapping, pinning failure is ignored (affinity is advisory —
//! under cpusets/containers the kernel is allowed to say no). Measure,
//! never assume: the bench prints the detected topology so a bad
//! mapping shows up as a number, not a mystery.

const std = @import("std");
const builtin = @import("builtin");

pub const max_cpus = 512;

/// Best-effort snapshot of the machine. Fixed-size (no allocation, no
/// deinit) so the server can hold one inline.
pub const Topology = struct {
    ncpus: usize = 1,
    nnodes: usize = 1,
    /// NUMA node per cpu (0 when unknown — everything groups together).
    node_of_cpu: [max_cpus]u16 = [_]u16{0} ** max_cpus,
    /// False for efficiency cores (ARM big.LITTLE via cpu_capacity).
    /// Unknown (x86, containers) reads true: no parking without evidence.
    is_big: [max_cpus]bool = [_]bool{true} ** max_cpus,
};

/// Logical cpu count, clamped to max_cpus. Never fails (1 on error).
pub fn cpuCount() usize {
    const n = std.Thread.getCpuCount() catch return 1;
    return @max(1, @min(n, max_cpus));
}

/// Detect the topology. Never errors fatally: any unreadable file degrades
/// that cpu to node 0 / big-core. Call once at startup (it stats /sys),
// not per tick.
pub fn detect(io: std.Io) Topology {
    var t = Topology{};
    t.ncpus = cpuCount();
    if (builtin.os.tag != .linux) return t;
    var max_node: u16 = 0;
    var cpu: usize = 0;
    while (cpu < t.ncpus) : (cpu += 1) {
        t.node_of_cpu[cpu] = nodeOf(io, cpu);
        if (t.node_of_cpu[cpu] > max_node) max_node = t.node_of_cpu[cpu];
        if (isLittle(io, cpu)) t.is_big[cpu] = false;
    }
    t.nnodes = @as(usize, max_node) + 1;
    return t;
}

/// NUMA node owning `cpu`, via /sys/devices/system/node/node{d}/cpu{cpu}.
/// 0 when undetectable (single node, containers, exotic kernels).
fn nodeOf(io: std.Io, cpu: usize) u16 {
    var d: u16 = 0;
    while (d < 16) : (d += 1) {
        var buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "/sys/devices/system/node/node{d}/cpu{d}", .{ d, cpu }) catch return 0;
        // Existence probe: the cpuN entries are symlinks; opening the dir
        // entry itself is enough (no read needed).
        const f = std.Io.Dir.openFileAbsolute(io, path, .{}) catch continue;
        f.close(io);
        return d;
    }
    return 0;
}

/// True when `cpu` looks like an efficiency core (ARM cpu_capacity below
/// the max on the box). Missing files mean "not little".
fn isLittle(io: std.Io, cpu: usize) bool {
    const max = maxCapacity(io) orelse return false;
    if (max == 0) return false;
    const mine = capacityOf(io, cpu) orelse return false;
    // A core at less than 3/4 of the max is parked for net/IO, not tick.
    return mine * 4 < max * 3;
}

fn capacityOf(io: std.Io, cpu: usize) ?u64 {
    var buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/sys/devices/system/cpu/cpu{d}/cpu_capacity", .{cpu}) catch return null;
    const f = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer f.close(io);
    var num: [32]u8 = undefined;
    var bufs = [_][]u8{&num};
    const n = f.readStreaming(io, &bufs) catch return null;
    const text = std.mem.trim(u8, num[0..n], " \t\n");
    return std.fmt.parseInt(u64, text, 10) catch null;
}

fn maxCapacity(io: std.Io) ?u64 {
    var best: ?u64 = null;
    var cpu: usize = 0;
    while (cpu < cpuCount()) : (cpu += 1) {
        if (capacityOf(io, cpu)) |c| {
            if (best == null or c > best.?) best = c;
        }
    }
    return best;
}

/// Assign `n_regions` region slots to cpus: big cores first, then grouped
/// by node so neighboring regions (adjacent slots) share L3. Writes cpu
/// indices into `out` (len >= n_regions). Pure + total: always succeeds.
pub fn assignRegions(topo: *const Topology, n_regions: usize, out: []usize) void {
    std.debug.assert(out.len >= n_regions);
    // Order cpus: big first, then node, then id. Insertion sort over at
    // most max_cpus entries, once per tick at worst (usually once ever —
    // the server caches the assignment).
    var order: [max_cpus]usize = undefined;
    const n = @min(topo.ncpus, max_cpus);
    for (0..n) |i| order[i] = i;
    var i: usize = 1;
    while (i < n) : (i += 1) {
        var j = i;
        while (j > 0 and lessCpu(topo, order[j], order[j - 1])) {
            const tmp = order[j];
            order[j] = order[j - 1];
            order[j - 1] = tmp;
            j -= 1;
        }
    }
    // Stripe regions over the ordered cpus: adjacent regions land on
    // adjacent cpus (same node while the node lasts).
    for (0..n_regions) |r| out[r] = order[r % n];
}

fn lessCpu(topo: *const Topology, a: usize, b: usize) bool {
    if (topo.is_big[a] != topo.is_big[b]) return topo.is_big[a];
    if (topo.node_of_cpu[a] != topo.node_of_cpu[b]) return topo.node_of_cpu[a] < topo.node_of_cpu[b];
    return a < b;
}

/// Pin the calling thread to `cpu`. Linux-only, best-effort: failure is
/// silently ignored (cpusets/containers overrule us; correctness never
/// depends on pinning).
pub fn pinSelf(cpu: usize) void {
    if (comptime builtin.os.tag != .linux) return;
    if (cpu >= max_cpus) return;
    var set: std.os.linux.cpu_set_t = [_]usize{0} ** (std.os.linux.CPU_SETSIZE / @sizeOf(usize));
    const word = cpu / @bitSizeOf(usize);
    if (word >= set.len) return;
    set[word] |= @as(usize, 1) << @intCast(cpu % @bitSizeOf(usize));
    std.os.linux.sched_setaffinity(0, &set) catch {};
}

test "detect never fails and stays in range" {
    const t = detect(std.testing.io);
    try std.testing.expect(t.ncpus >= 1 and t.ncpus <= max_cpus);
    try std.testing.expect(t.nnodes >= 1);
    var c: usize = 0;
    while (c < t.ncpus) : (c += 1) {
        try std.testing.expect(t.node_of_cpu[c] < 16);
    }
}

test "assignRegions stripes in range, big-first" {
    var topo = Topology{ .ncpus = 4, .nnodes = 1 };
    topo.is_big[0] = true;
    topo.is_big[1] = true;
    topo.is_big[2] = false;
    topo.is_big[3] = false;
    var out: [8]usize = undefined;
    assignRegions(&topo, 8, &out);
    for (out) |c| try std.testing.expect(c < 4);
    // First two slots land on big cores.
    try std.testing.expect(topo.is_big[out[0]]);
    try std.testing.expect(topo.is_big[out[1]]);
}

test "assignRegions groups by node" {
    var topo = Topology{ .ncpus = 4, .nnodes = 2 };
    topo.node_of_cpu[0] = 0;
    topo.node_of_cpu[1] = 1;
    topo.node_of_cpu[2] = 0;
    topo.node_of_cpu[3] = 1;
    var out: [4]usize = undefined;
    assignRegions(&topo, 4, &out);
    // Slots 0,1 share node 0; slots 2,3 share node 1 (neighbors on L3).
    try std.testing.expectEqual(topo.node_of_cpu[out[0]], topo.node_of_cpu[out[1]]);
    try std.testing.expectEqual(@as(u16, 0), topo.node_of_cpu[out[0]]);
}

test "pinSelf never crashes (any cpu, incl. bogus)" {
    pinSelf(0);
    pinSelf(max_cpus + 100);
}
