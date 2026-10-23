//! Synchronous io_uring reads for SST data — Phase B NVMe storage path.
//!
//! Shape: one small ring per Store, used only under the store mutex, so at
//! most one IO is ever in flight and no extra locking is needed. Reads use
//! IORING_OP_READ_FIXED into a pre-registered buffer (no per-IO page
//! pinning) from a pre-registered file (no per-IO fd lookup): the two
//! per-IO costs the kernel would otherwise pay on every SST stride read.
//!
//! Everything here degrades gracefully: if the kernel refuses io_uring
//! (old kernel, seccomp, memlock limits), init fails and the store uses
//! plain pread — same bytes, slower path. A read that does not fit the
//! registered buffer, or any ring error mid-read, also falls back to
//! pread. The ring never changes correctness, only speed.
//!
//! Linux-only at runtime (`supported`); the module compiles everywhere so
//! the store has one code path and the fallback is a branch, not a fork.

const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.os.tag == .linux;

const linux = std.os.linux;
const IoUring = linux.IoUring;
const posix = std.posix;

pub const RingStats = struct {
    ring_reads: u64 = 0,
    fallback_reads: u64 = 0,
};

pub const RingIo = struct {
    ring: IoUring,
    /// Owned read buffer, registered with the ring (pinned). Sized to
    /// cover the largest stride the store will ask for.
    buf: []u8 = &[_]u8{},
    files_registered: bool = false,
    stats: RingStats = .{},
    allocator: std.mem.Allocator,

    /// Set up the ring + one registered buffer of `want_bytes`. Tries
    /// smaller buffers (down to 1 MiB) when registration hits memlock
    /// limits, then fails with error.NoUring (the caller falls back to
    /// plain pread — never a hard error at the server level).
    pub fn init(allocator: std.mem.Allocator, want_bytes: usize) !RingIo {
        var size = @max(want_bytes, 1 << 20);
        while (true) {
            // tryInit only fails with NoUring (every failure maps to it).
            if (tryInit(allocator, size)) |r| return r else |_| {
                if (size <= 1 << 20) return error.NoUring;
                size = @max(size / 4, 1 << 20);
                continue;
            }
        }
    }

    fn tryInit(allocator: std.mem.Allocator, size: usize) !RingIo {
        var ring = IoUring.init(32, 0) catch return error.NoUring;
        errdefer ring.deinit();
        const buf = allocator.alloc(u8, size) catch return error.NoUring;
        errdefer allocator.free(buf);
        const iovecs = [_]posix.iovec{.{ .base = buf.ptr, .len = buf.len }};
        ring.register_buffers(&iovecs) catch return error.NoUring;
        return .{
            .ring = ring,
            .buf = buf,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RingIo) void {
        if (self.files_registered) {
            self.ring.unregister_files() catch {};
            self.files_registered = false;
        }
        self.ring.unregister_buffers() catch {};
        self.ring.deinit();
        if (self.buf.len > 0) self.allocator.free(self.buf);
        self.buf = &[_]u8{};
    }

    pub fn bufLen(self: *const RingIo) usize {
        return self.buf.len;
    }

    /// Replace the fixed-file table with `fds` (positional: the store's
    /// per-SST fixed index is the position in this slice). Empty list
    /// unregisters. Called after every SST-set change (open/flush/
    /// compact) — those paths already do file IO, so the extra syscalls
    /// are noise. On failure the caller tears the ring down (plain path
    /// from then on).
    ///
    /// NOTE: the kernel refuses a second REGISTER_FILES while a table is
    /// live (`FilesAlreadyRegistered`), so an existing table is always
    /// unregistered first.
    pub fn registerFiles(self: *RingIo, fds: []const posix.fd_t) !void {
        if (self.files_registered) {
            try self.ring.unregister_files();
            self.files_registered = false;
        }
        if (fds.len == 0) return;
        try self.ring.register_files(fds);
        self.files_registered = true;
    }

    /// Read `len` bytes at `offset` from fixed-file `fixed_index` into
    /// the registered buffer. Returns a slice valid until the next
    /// readAt (single in-flight use under the store mutex). Any failure
    /// (including a short read) is error.Fallback: the caller retries
    /// with plain pread.
    pub fn readAt(self: *RingIo, fixed_index: u32, offset: u64, len: usize) ![]u8 {
        if (len == 0 or len > self.buf.len) return error.Fallback;
        // The per-IO iovec carries the REQUESTED length: READ_FIXED reads
        // iovec.len bytes (not the registered buffer's full size), and
        // prep_read_fixed copies base+len into the SQE synchronously, so
        // a stack iovec is safe. buf_index selects the registered buffer;
        // the SQE len bounds the read.
        var iov = posix.iovec{ .base = self.buf.ptr, .len = len };
        // With IOSQE_FIXED_FILE the kernel reads `fd` as the index into
        // the registered file table (not a raw fd).
        const sqe = self.ring.read_fixed(1, @intCast(fixed_index), &iov, offset, 0) catch return error.Fallback;
        sqe.flags |= linux.IOSQE_FIXED_FILE;
        _ = self.ring.submit_and_wait(1) catch return error.Fallback;
        const cqe = self.ring.copy_cqe() catch return error.Fallback;
        if (cqe.res < 0) return error.Fallback;
        if (@as(usize, @intCast(cqe.res)) != len) return error.Fallback;
        self.stats.ring_reads += 1;
        return self.buf[0..len];
    }

    pub fn noteFallback(self: *RingIo) void {
        self.stats.fallback_reads += 1;
    }
};

/// Can io_uring be used at all on this kernel? (ring setup probe; no
/// buffers registered, no files touched).
pub fn probe() bool {
    if (!supported) return false;
    var ring = IoUring.init(8, 0) catch return false;
    defer ring.deinit();
    return true;
}

test "probe does not crash off-Linux" {
    // Must be callable everywhere; on non-Linux it is always false.
    const p = probe();
    if (!supported) try std.testing.expect(!p);
}

test "ring init degrades gracefully" {
    if (!supported) return error.SkipZigTest;
    if (!probe()) return error.SkipZigTest;
    // A 1 MiB buffer must succeed wherever the probe did; deinit must
    // not crash with nothing registered.
    var r = RingIo.init(std.testing.allocator, 1 << 20) catch |err| switch (err) {
        // locked-down container (memlock limits, seccomp)
        error.NoUring => return error.SkipZigTest,
    };
    defer r.deinit();
    try std.testing.expect(r.bufLen() >= 1 << 20);
    // Empty file table is a no-op, not an error.
    try r.registerFiles(&.{});
    try std.testing.expect(!r.files_registered);
}
