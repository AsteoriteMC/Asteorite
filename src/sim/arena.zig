//! Bump arena with O(1) reset — Phase D "per-tick arena reset for transient
//! tick data".
//!
//! Why not `std.heap.ArenaAllocator`? It keeps a per-allocation header and
//! a free list, so every `alloc` walks a linked list and every reset pays a
//! free-list walk. The hot paths we care about (per-feed decrypt/encrypt
//! copies in `Conn.feedData`/`Conn.queueRaw`, per-tick snapshot scratch)
//! want a plain bump pointer: `alloc` is a compare + add, and `reset` is
//! `len = 0`.
//!
//! Lifetime model: slices handed out by `alloc` are valid until the next
//! `reset` (or `deinit`). Callers that need a longer life copy the bytes
//! out. This is deliberate — it is what makes the per-tick arena cheap.
//!
//! Not thread-safe: one arena belongs to one thread (a conn's serve thread,
//! or the tick thread). Shared state must be copied out, not shared.

const std = @import("std");

pub const Error = error{OutOfMemory};

pub const Arena = struct {
    /// Backing store. Grown in chunks; never shrinks (reset keeps capacity).
    buf: []u8 = &[_]u8{},
    /// Bump offset into `buf`.
    len: usize = 0,
    /// Total bytes handed out since the last reset (diagnostics).
    used_bytes: usize = 0,
    /// Peak bytes handed out between resets (diagnostics).
    peak_bytes: usize = 0,
    /// Growth chunk size.
    chunk: usize = 4096,
    /// Backing allocator. `undefined` means "not initialized": an arena
    /// that was never `init`ed must not be used (its buffer is empty, so
    /// `deinit` is a no-op).
    allocator: std.mem.Allocator = undefined,

    pub fn init(allocator: std.mem.Allocator, chunk: usize) Arena {
        return .{ .allocator = allocator, .chunk = @max(chunk, 4096) };
    }

    pub fn deinit(self: *Arena) void {
        if (self.buf.len > 0) self.allocator.free(self.buf);
        self.buf = &[_]u8{};
        self.len = 0;
    }

    /// Drop every allocation but keep the backing buffer for reuse.
    /// Contents are NOT zeroed: the arena is a scratch buffer, callers must
    /// not read stale bytes.
    pub fn reset(self: *Arena) void {
        self.len = 0;
        self.used_bytes = 0;
        self.peak_bytes = 0;
    }

    pub fn capacity(self: *const Arena) usize {
        return self.buf.len;
    }

    pub fn alloc(self: *Arena, n: usize) Error![]u8 {
        return self.allocAligned(n, 1);
    }

    /// Bump-allocate `n` bytes with the given alignment. Alignment is
    /// relative to the buffer start (the buffer itself comes from the page
    /// allocator, so it is page-aligned), so `@alignCast` on the result is
    /// safe.
    pub fn allocAligned(self: *Arena, n: usize, alignment: usize) Error![]u8 {
        const al = @max(alignment, 1);
        var need = self.padFor(al) + n;
        if (need > self.buf.len - self.len) {
            try self.grow(need);
            // grow() may have moved the buffer (new base address), so the
            // alignment padding has to be recomputed.
            need = self.padFor(al) + n;
            if (need > self.buf.len - self.len) return error.OutOfMemory;
        }
        self.len += need;
        const out = self.buf[self.len - n ..][0..n];
        self.used_bytes += n;
        self.peak_bytes = @max(self.peak_bytes, self.used_bytes);
        return out;
    }

    /// Bytes of padding needed to align the current bump position.
    fn padFor(self: *const Arena, al: usize) usize {
        const base = @intFromPtr(self.buf.ptr);
        const cur = base + self.len;
        return std.mem.alignForward(usize, cur, al) - cur;
    }

    /// Copy `src` into the arena.
    pub fn dupe(self: *Arena, src: []const u8) Error![]u8 {
        const out = try self.alloc(src.len);
        @memcpy(out, src);
        return out;
    }

    /// Allocate zeroed memory.
    pub fn allocZeroed(self: *Arena, n: usize) Error![]u8 {
        const out = try self.alloc(n);
        @memset(out, 0);
        return out;
    }

    fn grow(self: *Arena, need: usize) Error!void {
        const want = @max(need, self.chunk);
        const new_len = @max(self.buf.len * 2, want);
        const new_buf = try self.allocator.alloc(u8, new_len);
        if (self.buf.len > 0) {
            @memcpy(new_buf[0..self.len], self.buf[0..self.len]);
            self.allocator.free(self.buf);
        }
        self.buf = new_buf;
    }
};

test "arena bump + reset keeps capacity" {
    const a = std.testing.allocator;
    var arena = Arena.init(a, 4096);
    defer arena.deinit();

    const s1 = try arena.dupe("hello");
    try std.testing.expectEqualStrings("hello", s1);
    _ = try arena.alloc(10);
    try std.testing.expectEqual(@as(usize, 15), arena.used_bytes);

    // Slices stay valid until reset.
    try std.testing.expectEqual(@as(u8, 'h'), s1[0]);

    arena.reset();
    try std.testing.expectEqual(@as(usize, 0), arena.len);
    try std.testing.expectEqual(@as(usize, 0), arena.used_bytes);
    // Capacity is retained (no realloc on the next round).
    const cap = arena.capacity();
    const s3 = try arena.dupe("world");
    try std.testing.expectEqualStrings("world", s3);
    try std.testing.expectEqual(cap, arena.capacity());
}

test "arena grows past the initial chunk" {
    const a = std.testing.allocator;
    var arena = Arena.init(a, 64);
    defer arena.deinit();
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const s = try arena.alloc(100);
        s[0] = @intCast(i);
        s[99] = @intCast(i);
    }
    try std.testing.expect(arena.capacity() >= 10_000);
}

test "arena alignment" {
    const a = std.testing.allocator;
    var arena = Arena.init(a, 4096);
    defer arena.deinit();
    const p = try arena.allocAligned(3, 8);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(p.ptr) % 8);
    const q = try arena.allocAligned(5, 16);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(q.ptr) % 16);
    const r = try arena.allocAligned(7, 64);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(r.ptr) % 64);
}
