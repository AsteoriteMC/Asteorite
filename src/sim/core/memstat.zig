//! Memory accounting — Phase D ("Memory budget (phone claims stay
//! measured, not promised): record RSS on fresh DB + 1 player, set an
//! explicit target; per-subsystem accounting in the stats line").
//!
//! The point of this module is that every memory claim in the docs comes
//! from a measurement, not from an estimate. `rssBytes` is the process's
//! resident set (what the kernel says is really resident); the
//! per-subsystem counters are the server's own bookkeeping (outboxes,
//! sent-sets, entity stores) so a leak shows up as a growing line in the
//! stats output instead of as a mystery OOM later.

const std = @import("std");
const builtin = @import("builtin");

/// Resident set size of this process in bytes (0 when unavailable).
///
/// Linux: /proc/self/statm (field 2 = resident pages).
/// Other platforms: 0 (the phone target is Linux; the number is only
/// claimed where it is measured).
pub fn rssBytes(io: std.Io) usize {
    if (builtin.os.tag != .linux) return 0;
    const page = std.heap.page_size_min;
    var buf: [128]u8 = undefined;
    const n = readProcFile(io, "/proc/self/statm", &buf) orelse return 0;
    const text = std.mem.trim(u8, buf[0..n], " \n\r\t");
    // "size resident shared ..." — the second field is the resident pages.
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    _ = it.next(); // size
    const resident = it.next() orelse return 0;
    const pages = std.fmt.parseInt(usize, resident, 10) catch return 0;
    return pages * page;
}

/// Peak RSS in bytes (Linux: /proc/self/status VmHWM; 0 elsewhere).
pub fn peakRssBytes(io: std.Io) usize {
    if (builtin.os.tag != .linux) return 0;
    var buf: [4096]u8 = undefined;
    const n = readProcFile(io, "/proc/self/status", &buf) orelse return 0;
    const text = buf[0..n];
    const idx = std.mem.indexOf(u8, text, "VmHWM:") orelse return 0;
    var it = std.mem.tokenizeScalar(u8, text[idx + "VmHWM:".len ..], ' ');
    const kb = it.next() orelse return 0;
    const v = std.fmt.parseInt(usize, kb, 10) catch return 0;
    return v * bytes_per_kib;
}

/// Read a /proc file into `buf` (Linux only).
fn readProcFile(io: std.Io, path: []const u8, buf: []u8) ?usize {
    const f = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer f.close(io);
    var bufs = [_][]u8{buf};
    return f.readStreaming(io, &bufs) catch null;
}

/// Byte-unit constants for the stats line.
pub const bytes_per_kib: usize = 1024;
pub const bytes_per_mib: usize = 1024 * 1024;

/// Format a byte count for the stats line ("1.2 MiB").
pub fn formatBytes(bytes: usize, buf: []u8) []const u8 {
    if (bytes < bytes_per_kib) return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch buf[0..0];
    if (bytes < bytes_per_mib) return std.fmt.bufPrint(buf, "{d} KiB", .{bytes / bytes_per_kib}) catch buf[0..0];
    return std.fmt.bufPrint(buf, "{d} MiB", .{bytes / bytes_per_mib}) catch buf[0..0];
}

/// Per-subsystem byte accounting (the numbers the stats line prints).
///
/// Every subsystem reports what it *knows* it holds; the RSS line is the
/// ground truth they are reconciled against.
pub const Accounting = struct {
    /// Bytes queued in the per-connection outboxes.
    outboxes: usize = 0,
    /// Bytes held by the per-connection "sent chunk" sets.
    sent_sets: usize = 0,
    /// Bytes held by the entity stores (mobs + items).
    entities: usize = 0,
    /// Bytes held by the transport's provided-buffer rings.
    transport_buffers: usize = 0,
    /// Bytes held by the LSM store (block cache + memtables).
    store: usize = 0,
    /// Pinned io_uring SST read buffers (NVMe storage profile).
    store_ring: usize = 0,

    pub fn total(self: Accounting) usize {
        return self.outboxes + self.sent_sets + self.entities + self.transport_buffers + self.store + self.store_ring;
    }
};

test "rss is measurable on this platform" {
    const rss = rssBytes(std.testing.io);
    if (builtin.os.tag == .linux) {
        // A running process always has at least a few pages resident.
        try std.testing.expect(rss > 0);
    }
}

test "byte formatting" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("512 B", formatBytes(512, &buf));
    try std.testing.expectEqualStrings("2 KiB", formatBytes(2048, &buf));
    try std.testing.expectEqualStrings("3 MiB", formatBytes(3 * 1024 * 1024, &buf));
}

test "accounting sums the subsystems" {
    var a = Accounting{};
    a.outboxes = 100;
    a.sent_sets = 200;
    try std.testing.expectEqual(@as(usize, 300), a.total());
}
