//! Storage profiles — Phase B NVMe path + the HDD/SSD tunings it contrasts
//! with (`--storage-profile hdd|ssd|nvme|auto`).
//!
//! The three profiles trade write amplification against read fan-out:
//!
//!   hdd:  big SSTs (8 MiB flush), rare compactions (12 runs), WAL syncs
//!          batched (64 KiB) — disk seeks are the bottleneck, old-CPU
//!          cycles are cheap, so move as few bytes as possible.
//!   ssd:   today's defaults (4 MiB flush, compact at 8) — unchanged.
//!   nvme:  small SSTs (1 MiB flush), frequent small compactions (4 runs),
//!          io_uring fixed files + registered buffers for SST reads,
//!          parallel cross-shard compaction — IOPS are plentiful, so spend
//!          them to keep every compaction unit small.
//!
//! `auto` detects rotational storage via sysfs and otherwise behaves like
//! `ssd` (today's proven defaults). Detection is best-effort: any failure
//! yields `ssd`, never an error.

const std = @import("std");
const builtin = @import("builtin");
const store_mod = @import("store.zig");
/// Linux-only (stub elsewhere — see store.zig): keeps `uring_io.zig` out
/// of analysis off Linux.
const uring_io = if (builtin.os.tag == .linux) @import("uring_io.zig") else struct {
    pub fn probe() bool {
        return false;
    }
};

pub const Profile = enum {
    auto,
    hdd,
    ssd,
    nvme,

    /// Parse a `--storage-profile` / config value. Null for unknown text.
    pub fn parse(text: []const u8) ?Profile {
        if (std.mem.eql(u8, text, "auto")) return .auto;
        if (std.mem.eql(u8, text, "hdd")) return .hdd;
        if (std.mem.eql(u8, text, "ssd")) return .ssd;
        if (std.mem.eql(u8, text, "nvme")) return .nvme;
        return null;
    }

    pub fn name(self: Profile) []const u8 {
        return switch (self) {
            .auto => "auto",
            .hdd => "hdd",
            .ssd => "ssd",
            .nvme => "nvme",
        };
    }
};

/// Options the profile resolves to, plus the concrete profile `auto`
/// picked (for the startup log / stats line).
pub const Resolved = struct {
    profile: Profile,
    opts: store_mod.Store.Options,
    /// True when the nvme tunings were selected (ring attempted at open;
    /// a kernel that refuses it still serves, on plain pread).
    wants_uring_io: bool,
};

/// Tunings per concrete profile. `ssd` is exactly today's defaults.
pub fn optionsFor(profile: Profile) store_mod.Store.Options {
    return switch (profile) {
        .auto => optionsFor(.ssd), // auto resolves before this is used
        .hdd => .{
            .flush_threshold_bytes = 8 * 1024 * 1024,
            .wal_sync_bytes = 64 * 1024,
            .compact_threshold_ssts = 12,
        },
        .ssd => .{},
        .nvme => .{
            .flush_threshold_bytes = 1 * 1024 * 1024,
            .wal_sync_bytes = 0,
            .compact_threshold_ssts = 4,
            .use_uring_io = true,
        },
    };
}

/// Resolve a profile against the database path: `auto` detects rotational
/// storage (Linux sysfs), everything else is literal.
pub fn resolve(io: std.Io, db_path: []const u8, profile: Profile) Resolved {
    switch (profile) {
        .auto => {
            const detected = detectProfile(io, db_path);
            return .{
                .profile = detected,
                .opts = optionsFor(detected),
                .wants_uring_io = detected == .nvme,
            };
        },
        else => return .{
            .profile = profile,
            .opts = optionsFor(profile),
            .wants_uring_io = profile == .nvme,
        },
    }
}

/// The `auto` decision: rotational backing device -> hdd; non-rotational
/// with a working io_uring -> nvme; anything else (or undetectable) ->
/// ssd (today's defaults — the safe choice).
pub fn detectProfile(io: std.Io, db_path: []const u8) Profile {
    if (builtin.os.tag != .linux) return .ssd;
    const rotational = isRotational(io, db_path) orelse return .ssd;
    if (rotational) return .hdd;
    if (uring_io.probe()) return .nvme;
    return .ssd;
}

/// True when the filesystem backing `db_path` sits on a rotational
/// device. Null when undetectable (non-Linux, containers without sysfs,
/// exotic mounts) — the caller treats that as "ssd".
pub fn isRotational(io: std.Io, db_path: []const u8) ?bool {
    if (comptime builtin.os.tag != .linux) return null;
    const linux = std.os.linux;
    // statx on the path (relative paths resolve against the cwd, which
    // is where the server runs) gives the backing device's maj:min.
    const path_z = std.posix.toPosixPath(db_path) catch return null;
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, &path_z, 0, .{ .TYPE = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    var sysfs_buf: [64]u8 = undefined;
    const sysfs_path = std.fmt.bufPrint(&sysfs_buf, "/sys/dev/block/{d}:{d}/queue/rotational", .{ stx.dev_major, stx.dev_minor }) catch return null;
    const f = std.Io.Dir.openFileAbsolute(io, sysfs_path, .{}) catch return null;
    defer f.close(io);
    var byte: [2]u8 = undefined;
    var bufs = [_][]u8{&byte};
    const n = f.readStreaming(io, &bufs) catch return null;
    if (n == 0) return null;
    return switch (byte[0]) {
        '0' => false,
        '1' => true,
        else => null,
    };
}

test "profile parsing" {
    try std.testing.expectEqual(Profile.auto, Profile.parse("auto").?);
    try std.testing.expectEqual(Profile.hdd, Profile.parse("hdd").?);
    try std.testing.expectEqual(Profile.ssd, Profile.parse("ssd").?);
    try std.testing.expectEqual(Profile.nvme, Profile.parse("nvme").?);
    try std.testing.expect(Profile.parse("tape") == null);
    try std.testing.expect(Profile.parse("") == null);
}

test "profile tunings order sanely" {
    const hdd = optionsFor(.hdd);
    const ssd = optionsFor(.ssd);
    const nvme = optionsFor(.nvme);
    // Smaller SSTs + more frequent compactions down the stack.
    try std.testing.expect(hdd.flush_threshold_bytes > ssd.flush_threshold_bytes);
    try std.testing.expect(ssd.flush_threshold_bytes > nvme.flush_threshold_bytes);
    try std.testing.expect(hdd.compact_threshold_ssts > ssd.compact_threshold_ssts);
    try std.testing.expect(ssd.compact_threshold_ssts >= nvme.compact_threshold_ssts);
    // Only nvme asks for the ring; ssd is exactly today's defaults.
    try std.testing.expect(nvme.use_uring_io);
    try std.testing.expect(!ssd.use_uring_io);
    try std.testing.expect(!hdd.use_uring_io);
    try std.testing.expectEqual(store_mod.Store.Options{}, ssd);
    // HDD batches WAL syncs (seek cost); the others sync on flush/close.
    try std.testing.expect(hdd.wal_sync_bytes > 0);
    try std.testing.expectEqual(@as(usize, 0), ssd.wal_sync_bytes);
}

test "rotational detection never errors" {
    // Environment-dependent value (this box may be SSD or HDD), but the
    // call itself must always complete without crashing.
    const io = std.testing.io;
    _ = isRotational(io, "/tmp");
    _ = isRotational(io, "/nonexistent-path-xyz");
    _ = detectProfile(io, "/tmp");
}
