//! Transport abstraction — Phase B ("per-OS backends behind one transport
//! interface", "`Conn` interface unchanged").
//!
//! The protocol layer (`Conn` in conn.zig) never learns which transport
//! carries its bytes. It gets fed inbound chunks and hands back outbound
//! chunks; the transport decides whether those bytes travel through a
//! thread-per-connection blocking socket, a Linux io_uring ring, a macOS
//! kqueue loop or a Windows completion-port loop.
//!
//! Selection:
//!   - `auto`     — the best backend this OS/kernel supports
//!   - `uring`    — Linux io_uring (multishot accept + multishot recv)
//!   - `kqueue`   — macOS/BSD kqueue (non-blocking, level-triggered)
//!   - `iocp`     — Windows I/O completion ports
//!   - `blocking` — portable thread-per-connection blocking transport
//!
//! Every backend implements the same contract:
//!   - `Conn` bytes in  -> `Session.feed(bytes)`
//!   - `Session` bytes out -> one batched send per flush point
//!
//! Tuning knobs live here so the CLI/config and the backends agree on
//! defaults (send_zc threshold, per-conn output cap, TCP_NODELAY, socket
//! buffer sizes, ring geometry).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const Kind = enum {
    auto,
    uring,
    kqueue,
    iocp,
    blocking,

    /// Parse a `--transport` value. Returns null for unknown text.
    pub fn parse(text: []const u8) ?Kind {
        inline for (@typeInfo(Kind).@"enum".fields) |f| {
            if (std.mem.eql(u8, text, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }

    pub fn name(self: Kind) []const u8 {
        return @tagName(self);
    }

    /// True when the backend can run on this OS at all.
    pub fn supportedOnCurrentOs(self: Kind) bool {
        return switch (self) {
            .auto, .blocking => true,
            .uring => builtin.os.tag == .linux,
            .kqueue => builtin.os.tag.isDarwin() or builtin.os.tag == .freebsd or builtin.os.tag == .netbsd or builtin.os.tag == .openbsd,
            .iocp => builtin.os.tag == .windows,
        };
    }
};

/// Resolve `auto` to the concrete backend for the current OS.
/// `uring` is only chosen on Linux; a kernel without io_uring support is
/// detected at runtime by the backend itself (it falls back to blocking).
pub fn resolve(kind: Kind) Kind {
    return switch (kind) {
        .auto => switch (builtin.os.tag) {
            .linux => .uring,
            .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .openbsd => .kqueue,
            .windows => .iocp,
            else => .blocking,
        },
        else => kind,
    };
}

pub const Options = struct {
    /// Requested backend.
    kind: Kind = .auto,
    /// SEND_ZC (zerocopy send) threshold in bytes. Chunk bulks go
    /// zerocopy; chat/keepalive frames are cheaper to copy (the copy is
    /// a few hundred bytes, the zerocopy notification round-trip is not
    /// free). 8 KiB is the measured knee.
    send_zc_threshold: usize = 8 * 1024,
    /// Per-connection queued-output cap in bytes. A slow consumer that
    /// lets its queue grow past this is kicked (slow-consumer protection:
    /// once chunk bulks flow, an unbounded queue is an OOM).
    out_cap_bytes: usize = 4 * 1024 * 1024,
    /// Set TCP_NODELAY on accepted sockets (1.7.10 traffic is chatty and
    /// latency-sensitive; Nagle delays the 1-byte keepalive echoes).
    tcp_nodelay: bool = true,
    /// SO_SNDBUF / SO_RCVBUF (0 = leave the OS default).
    send_buf_bytes: usize = 0,
    recv_buf_bytes: usize = 0,
    /// SO_SNDTIMEO in seconds (0 = leave the OS default = block forever).
    /// Bounds every synchronous write: a peer that accepts zero bytes for
    /// this long trips the send, which unwedges the writer (serve thread,
    /// ticker, or duplicate-login kicker) instead of stalling it for
    /// TCP-timeout minutes. Only fires on zero-progress windows — a slow
    /// but moving peer never trips it — while the 30s read timeout owns
    /// liveness for slow loaders. 10s fits inside the 30s login window so
    /// a duplicate-kick flush to a dead ghost can't fail the new login.
    send_timeout_s: u16 = 10,
    /// io_uring entries per ring (power of two, 1..32768).
    ring_entries: u16 = 256,
    /// io_uring worker threads (0 = auto: min(cores, 8)).
    workers: usize = 0,
    /// Provided-buffer ring size per io_uring worker (power of two).
    /// 256 x 4 KiB = 1 MiB of registered buffers per worker: enough to
    /// absorb a burst of reads without starving the ring.
    buf_ring_entries: u16 = 256,
    /// Bytes per provided buffer (multishot recv granularity).
    buf_size: usize = 4 * 1024,

    pub fn workerCount(self: Options) usize {
        if (self.workers > 0) return self.workers;
        const cpus = std.Thread.getCpuCount() catch 4;
        return @min(cpus, 8);
    }
};

/// Transport counters (per-server; reported in the stats line).
pub const Stats = struct {
    conns_accepted: u64 = 0,
    conns_closed: u64 = 0,
    bytes_in: u64 = 0,
    bytes_out: u64 = 0,
    /// Sends that used the zerocopy path.
    sends_zc: u64 = 0,
    /// Sends that used the copy path (small frames).
    sends_copy: u64 = 0,
    /// Connections dropped because their queued output hit the cap.
    kicks_backpressure: u64 = 0,
    /// Batched flushes (one send per flush point).
    flushes: u64 = 0,
    /// Recv arming failures (the submission queue was full).
    recv_arm_failures: u64 = 0,
    /// Times the provided-buffer group ran dry (ENOBUFS).
    buffer_starved: u64 = 0,
    /// Send submission failures.
    send_failures: u64 = 0,
    /// Successful recv re-arms by the worker sweep (connections that lost
    /// their multishot recv and would otherwise stay deaf forever).
    recv_rearmed: u64 = 0,

    pub fn merge(self: *Stats, other: Stats) void {
        self.conns_accepted += other.conns_accepted;
        self.conns_closed += other.conns_closed;
        self.bytes_in += other.bytes_in;
        self.bytes_out += other.bytes_out;
        self.sends_zc += other.sends_zc;
        self.sends_copy += other.sends_copy;
        self.kicks_backpressure += other.kicks_backpressure;
        self.flushes += other.flushes;
        self.recv_arm_failures += other.recv_arm_failures;
        self.buffer_starved += other.buffer_starved;
        self.send_failures += other.send_failures;
        self.recv_rearmed += other.recv_rearmed;
    }
};

/// Apply the socket options to an accepted socket. Errors are ignored on
/// purpose: a kernel that refuses TCP_NODELAY must not kill the conn.
pub fn applySocketOpts(fd: std.posix.fd_t, opts: Options) void {
    if (opts.tcp_nodelay) {
        // Level IPPROTO.TCP (6), option TCP_NODELAY (1).
        std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
    }
    if (opts.send_buf_bytes > 0) {
        const v: c_int = @intCast(opts.send_buf_bytes);
        std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, &std.mem.toBytes(v)) catch {};
    }
    if (opts.recv_buf_bytes > 0) {
        const v: c_int = @intCast(opts.recv_buf_bytes);
        std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, &std.mem.toBytes(v)) catch {};
    }
    if (opts.send_timeout_s > 0) {
        const tv = std.posix.timeval{ .sec = opts.send_timeout_s, .usec = 0 };
        std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, &std.mem.toBytes(tv)) catch {};
    }
}

/// Would this frame take the zerocopy path?
pub fn useZerocopy(len: usize, opts: Options) bool {
    return len >= opts.send_zc_threshold;
}

/// The transport actually in use (after `auto` resolution and any runtime
/// fallback), for the stats line / log output.
pub fn describe(kind: Kind) []const u8 {
    return switch (kind) {
        .auto => "auto",
        .uring => "io_uring",
        .kqueue => "kqueue",
        .iocp => "iocp",
        .blocking => "blocking",
    };
}

/// Protocol callbacks an event-driven transport invokes.
///
/// The blocking transport does not use these (it drives the protocol
/// inline), but every async backend speaks exactly this contract, so the
/// protocol layer stays transport-agnostic.
pub const Handler = struct {
    /// A connection was accepted (worker thread).
    /// `conn_id` is the transport-assigned id; the server maps it to its
    /// `Conn`. `fd` is the raw socket (the transport owns it).
    on_accept: *const fn (ctx: *anyopaque, conn_id: u32, fd: std.posix.fd_t) void,
    /// Inbound bytes (worker thread). The protocol layer queues its
    /// answer on the connection; the transport drains it with `on_flush`.
    on_read: *const fn (ctx: *anyopaque, conn_id: u32, bytes: []const u8) void,
    /// The connection is gone (peer closed or error) (worker thread).
    on_close: *const fn (ctx: *anyopaque, conn_id: u32) void,
    /// Drain the connection's queued output (worker thread). The returned
    /// slice is owned by the transport.
    on_flush: *const fn (ctx: *anyopaque, conn_id: u32) ?[]u8,
    /// Handler context (the server).
    ctx: *anyopaque,
};

/// Handle to a running transport, stored by the server so any thread can
/// ask for a flush (the ticker queues output, the transport sends it).
pub const Handle = struct {
    /// Request that the connection's queued output be sent. Safe to call
    /// from any thread.
    request_flush: *const fn (ctx: *anyopaque, conn_id: u32) void,
    /// Close the connection (the transport owns the socket). Safe to call
    /// from any thread. Graceful: already-queued output still goes out
    /// first (e.g. the status pong, kick/disconnect reasons), then the
    /// connection is closed — same flush-then-close contract as the
    /// blocking transport, whose write path flushes before it closes.
    close_conn: *const fn (ctx: *anyopaque, conn_id: u32) void,
    ctx: *anyopaque,
};

/// Build a Handle for a backend exposing `requestFlush`/`closeConn`
/// (the three OS backends had byte-identical vtable shims — one home).
pub fn handleFor(comptime B: type, backend: *B) Handle {
    return .{
        .request_flush = struct {
            fn f(ctx: *anyopaque, conn_id: u32) void {
                const b: *B = @ptrCast(@alignCast(ctx));
                b.requestFlush(conn_id);
            }
        }.f,
        .close_conn = struct {
            fn f(ctx: *anyopaque, conn_id: u32) void {
                const b: *B = @ptrCast(@alignCast(ctx));
                b.closeConn(conn_id);
            }
        }.f,
        .ctx = backend,
    };
}

/// Sleep helper for backends (they carry the server's Io for this).
pub fn sleepMs(io: std.Io, ms: u64) void {
    const d = std.Io.Clock.Duration{ .raw = std.Io.Duration.fromNanoseconds(@intCast(ms * std.time.ns_per_ms)), .clock = .awake };
    std.Io.Timeout.sleep(.{ .duration = d }, io) catch {};
}

/// Peer address of an accepted socket, formatted as IPv4/IPv6 text (the
/// shape the ban tables use). Returns the number of bytes written into
/// `out` (0 when the address is unavailable).
pub fn peerAddress(fd: std.posix.fd_t, out: []u8) usize {
    var addr: std.posix.sockaddr.storage = undefined;
    var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    std.posix.getpeername(fd, @ptrCast(&addr), &len) catch return 0;
    switch (addr.family) {
        posix.AF.INET => {
            const sa: *const std.posix.sockaddr.in = @ptrCast(&addr);
            const b = sa.addr & 0xFFFF_FFFF;
            const s = std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}", .{
                @as(u8, @truncate(b >> 24)),
                @as(u8, @truncate(b >> 16)),
                @as(u8, @truncate(b >> 8)),
                @as(u8, @truncate(b)),
            }) catch return 0;
            return s.len;
        },
        posix.AF.INET6 => {
            const sa: *const std.posix.sockaddr.in6 = @ptrCast(&addr);
            var w: usize = 0;
            var i: usize = 0;
            while (i < 16) : (i += 2) {
                if (i > 0) {
                    if (w + 1 > out.len) return w;
                    out[w] = ':';
                    w += 1;
                }
                const v: u16 = @as(u16, sa.addr[i]) << 8 | sa.addr[i + 1];
                const s = std.fmt.bufPrint(out[w..], "{x}", .{v}) catch return w;
                w += s.len;
            }
            return w;
        },
        else => return 0,
    }
}

test "transport kind parsing" {
    try std.testing.expectEqual(Kind.auto, Kind.parse("auto").?);
    try std.testing.expectEqual(Kind.uring, Kind.parse("uring").?);
    try std.testing.expectEqual(Kind.kqueue, Kind.parse("kqueue").?);
    try std.testing.expectEqual(Kind.iocp, Kind.parse("iocp").?);
    try std.testing.expectEqual(Kind.blocking, Kind.parse("blocking").?);
    try std.testing.expect(Kind.parse("epoll") == null);
    try std.testing.expect(Kind.parse("") == null);
}

test "send timeout defaults bound synchronous writes" {
    // applySocketOpts programs SO_SNDTIMEO from this: a peer accepting
    // zero bytes for this long trips the send instead of wedging the
    // writer (serve thread, ticker, duplicate-login kicker) for
    // TCP-timeout minutes. Must stay inside the 30s login window.
    try std.testing.expectEqual(@as(u16, 10), (Options{}).send_timeout_s);
    try std.testing.expect((Options{}).send_timeout_s * 1000 < 30000);
}

test "auto resolves to a backend supported by this OS" {
    const k = resolve(.auto);
    try std.testing.expect(k.supportedOnCurrentOs());
    try std.testing.expect(k != .auto);
}

test "zerocopy threshold gate" {
    const opts = Options{};
    try std.testing.expect(!useZerocopy(1024, opts));
    try std.testing.expect(useZerocopy(16 * 1024, opts));
    const custom = Options{ .send_zc_threshold = 1024 };
    try std.testing.expect(useZerocopy(2048, custom));
}

test "stats merge" {
    var s = Stats{};
    s.merge(.{ .bytes_in = 10, .bytes_out = 20, .sends_zc = 1 });
    s.merge(.{ .bytes_in = 5, .bytes_out = 5, .sends_copy = 3 });
    try std.testing.expectEqual(@as(u64, 15), s.bytes_in);
    try std.testing.expectEqual(@as(u64, 25), s.bytes_out);
    try std.testing.expectEqual(@as(u64, 1), s.sends_zc);
    try std.testing.expectEqual(@as(u64, 3), s.sends_copy);
}
