//! Vanilla-style RCON (remote console) for 1.7.10: Source-RCON framing
//! over TCP (little-endian length-prefixed packets), password auth, then
//! command execution with full console authority.
//!
//! Wire format (all integers little-endian):
//!   length i32 (bytes AFTER this field: id + type + payload + 2)
//!   id i32 (client-chosen; echoed in the response, -1 = auth failure)
//!   type i32 (3 = AUTH, 2 = EXECCOMMAND client->server / AUTH_RESPONSE
//!     server->client, 0 = RESPONSE_VALUE server->client)
//!   payload bytes (command or password, no NULs by construction)
//!   0x00 0x00 (C-string terminator + empty-string terminator)
//! Lengths are capped at max_packet (4096, the classic Source cap):
//! anything else closes the connection, no reply.
//!
//! Security posture (deliberate, documented):
//! - RCON is DISABLED unless --rcon-password is set (fail closed, like
//!   vanilla enable-rcon=false). The password travels in plaintext, same
//!   as vanilla: bind to localhost or tunnel over SSH.
//! - Passwords are compared with an XOR-accumulate loop (no early exit on
//!   content; length leaks, which is standard and unavoidable here).
//!   The password is NEVER logged.
//! - Max 3 auth attempts per connection, then close. Commands before a
//!   successful auth close the connection immediately.
//! - RCON has full console authority (op/deop/save-all/stop). Treat the
//!   port like a root shell: firewall it.
//! - Replies are single packets capped at max_response (4000) bytes with a
//!   truncation marker — our longest reply (/list with a full roster) is
//!   the only thing that can hit it.

const std = @import("std");

pub const AUTH: i32 = 3;
pub const AUTH_RESPONSE: i32 = 2;
pub const EXECCOMMAND: i32 = 2;
pub const RESPONSE_VALUE: i32 = 0;

/// Classic Source cap on the length field (id+type+payload+2 nulls).
pub const max_packet: i32 = 4096;
/// Single response packets; longer replies are truncated with a marker.
pub const max_response: usize = 4000;
pub const trunc_marker = "...[truncated]";
/// Wrong-password guesses tolerated per connection before close.
pub const max_attempts: u8 = 3;
/// Minimum useful RCON frame: id + type + two nulls, empty payload.
pub const min_len: i32 = 4 + 4 + 2;

pub const Error = error{
    TooShort,
    TooLong,
    BadTerminator,
    EndOfStream,
} || std.mem.Allocator.Error || std.Io.Reader.Error || std.Io.Writer.Error || std.Io.net.Server.ListenError || std.Io.net.Stream.ReadError || std.Io.net.Stream.WriteError;

/// Frame one packet. `payload` must not contain NUL bytes.
pub fn frame(id: i32, packet_type: i32, payload: []const u8, out: []u8) ![]const u8 {
    const total: usize = 4 + 4 + payload.len + 2;
    if (total - 4 > max_packet) return error.TooLong;
    if (out.len < 4 + total) return error.TooLong;
    std.mem.writeInt(i32, out[0..4], @intCast(total), .little);
    std.mem.writeInt(i32, out[4..8], id, .little);
    std.mem.writeInt(i32, out[8..12], packet_type, .little);
    @memcpy(out[12..][0..payload.len], payload);
    out[12 + payload.len] = 0;
    out[12 + payload.len + 1] = 0;
    return out[0 .. 4 + total];
}

pub const Packet = struct {
    id: i32,
    packet_type: i32,
    /// Borrowed from the caller's buffer (no NULs; terminator stripped).
    payload: []const u8,
};

/// Parse one length-prefixed packet from a buffered reader. The returned
/// payload aliases `buf` (caller keeps it alive for the handler tick).
pub fn parse(reader: *std.Io.Reader, buf: []u8) !Packet {
    if (buf.len < 4) return error.TooShort;
    try reader.readSliceAll(buf[0..4]);
    const len = std.mem.readInt(i32, buf[0..4], .little);
    if (len < min_len) return error.TooShort;
    if (len > max_packet) return error.TooLong;
    const ulen: usize = @intCast(len);
    if (buf.len < ulen) return error.TooShort;
    try reader.readSliceAll(buf[0..ulen]);
    const id = std.mem.readInt(i32, buf[0..4], .little);
    const ptype = std.mem.readInt(i32, buf[4..8], .little);
    const body = buf[8..ulen];
    if (body.len < 2 or body[body.len - 1] != 0 or body[body.len - 2] != 0) return error.BadTerminator;
    var end: usize = 0;
    while (end < body.len - 2 and body[end] != 0) : (end += 1) {}
    return .{ .id = id, .packet_type = ptype, .payload = body[0..end] };
}

/// Length-safe comparison: early-out on length only, content compared in
/// full (XOR accumulation, no short-circuit).
pub fn passwordOk(stored: []const u8, provided: []const u8) bool {
    if (stored.len != provided.len) return false;
    if (stored.len == 0) return false; // empty passwords never authenticate
    var acc: u8 = 0;
    for (stored, provided) |a, b| acc |= a ^ b;
    return acc == 0;
}

const Server = @import("server.zig").Server;

/// Accept loop: one thread per connection (RCON is low-traffic admin use;
/// the game transport keeps its own model). Never returns.
pub fn serve(io: std.Io, server: *Server, password: []const u8, port: u16) !void {
    const addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    std.log.info("rcon listening on 0.0.0.0:{d}", .{port});
    while (true) {
        const stream = try listener.accept(io);
        const C = struct {
            fn run(s: std.Io.net.Stream, i: std.Io, srv: *Server, pw: []const u8) void {
                handleConn(s, i, srv, pw);
            }
        };
        const th = try std.Thread.spawn(.{}, C.run, .{ stream, io, server, password });
        th.detach();
    }
}

/// Handle a single RCON connection until close. All framing violations,
/// unauthenticated commands, and auth-cap exhaustion close the connection
/// without a reply (fail closed; the password itself is never logged).
pub fn handleConn(stream: std.Io.net.Stream, io: std.Io, server: *Server, password: []const u8) void {
    defer stream.close(io);
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var writer = stream.writer(io, &wbuf);
    const rin = &reader.interface;
    const wout = &writer.interface;
    var pbuf: [max_packet]u8 = undefined;
    var authed = false;
    var attempts: u8 = 0;
    while (true) {
        const p = parse(rin, &pbuf) catch return;
        if (p.packet_type == AUTH) {
            attempts += 1;
            if (attempts > max_attempts) return;
            if (passwordOk(password, p.payload)) {
                authed = true;
                sendPacket(wout, p.id, AUTH_RESPONSE, "") catch return;
            } else {
                // Vanilla echoes -1 on failure (the only oracle by design).
                sendPacket(wout, -1, AUTH_RESPONSE, "") catch return;
            }
        } else if (p.packet_type == EXECCOMMAND) {
            if (!authed) return;
            // RCON clients send bare commands; tolerate one leading slash.
            var cmd: [max_packet]u8 = undefined;
            var clen: usize = 0;
            var pl = p.payload;
            if (pl.len > 0 and pl[0] == '/') pl = pl[1..];
            cmd[0] = '/';
            clen = 1;
            const n = @min(pl.len, cmd.len - 1);
            @memcpy(cmd[clen..][0..n], pl[0..n]);
            clen += n;
            const text = cmd[0..clen];
            var out: [8192]u8 = undefined;
            const reply = server.executeCommand(null, text, &out);
            sendResponse(wout, p.id, reply) catch return;
            if (Server.isStopCommand(text)) {
                _ = server.saveAllPlayers();
                if (server.world) |pool| pool.flushAll() catch {};
                std.log.info("rcon stop: saved players, flushed. bye.", .{});
                std.process.exit(0);
            }
        } else {
            return;
        }
    }
}

fn sendPacket(wout: *std.Io.Writer, id: i32, packet_type: i32, payload: []const u8) !void {
    var fb: [8192]u8 = undefined;
    const f = try frame(id, packet_type, payload, &fb);
    try wout.writeAll(f);
    try wout.flush();
}

/// Single-packet response; longer replies are truncated with a marker
/// (our longest reply is a full /list, and only barely).
fn sendResponse(wout: *std.Io.Writer, id: i32, reply: []const u8) !void {
    if (reply.len <= max_response) {
        try sendPacket(wout, id, RESPONSE_VALUE, reply);
        return;
    }
    var tb: [max_response + 32]u8 = undefined;
    const keep = max_response - trunc_marker.len;
    @memcpy(tb[0..keep], reply[0..keep]);
    @memcpy(tb[keep..][0..trunc_marker.len], trunc_marker);
    try sendPacket(wout, id, RESPONSE_VALUE, tb[0 .. keep + trunc_marker.len]);
}

test "rcon framing roundtrips (LE, double null, id echo)" {
    var buf: [128]u8 = undefined;
    const f = try frame(42, EXECCOMMAND, "list", &buf);
    // length prefix then id/type LE
    try std.testing.expectEqual(@as(i32, 4 + 4 + 4 + 2), std.mem.readInt(i32, f[0..4], .little));
    try std.testing.expectEqual(@as(i32, 42), std.mem.readInt(i32, f[4..8], .little));
    try std.testing.expectEqual(@as(i32, 2), std.mem.readInt(i32, f[8..12], .little));
    try std.testing.expectEqualSlices(u8, "list\x00\x00", f[12..]);
    // parse back through a fixed reader
    var r = std.Io.Reader.fixed(f);
    var pbuf: [128]u8 = undefined;
    const p = try parse(&r, &pbuf);
    try std.testing.expectEqual(@as(i32, 42), p.id);
    try std.testing.expectEqual(@as(i32, EXECCOMMAND), p.packet_type);
    try std.testing.expectEqualSlices(u8, "list", p.payload);
    // empty payload frame
    const e = try frame(-1, AUTH_RESPONSE, "", &buf);
    var re = std.Io.Reader.fixed(e);
    const pe = try parse(&re, &pbuf);
    try std.testing.expectEqual(@as(i32, -1), pe.id);
    try std.testing.expectEqual(@as(usize, 0), pe.payload.len);
}

test "rcon framing rejects short/oversize/unterminated" {
    var buf: [8192]u8 = undefined;
    // length below minimum (id+type+2 nulls)
    {
        std.mem.writeInt(i32, buf[0..4], 9, .little);
        var r = std.Io.Reader.fixed(buf[0..4]);
        var tmp: [64]u8 = undefined;
        if (parse(&r, &tmp)) |_| return error.TestUnexpectedResult else |err| try std.testing.expectEqual(error.TooShort, err);
    }
    // length above the cap
    {
        std.mem.writeInt(i32, buf[0..4], max_packet + 1, .little);
        var r = std.Io.Reader.fixed(buf[0..4]);
        var tmp: [64]u8 = undefined;
        if (parse(&r, &tmp)) |_| return error.TestUnexpectedResult else |err| try std.testing.expectEqual(error.TooLong, err);
    }
    // missing double-null terminator
    {
        var raw: [32]u8 = undefined;
        std.mem.writeInt(i32, raw[0..4], 4 + 4 + 4 + 2, .little);
        std.mem.writeInt(i32, raw[4..8], 1, .little);
        std.mem.writeInt(i32, raw[8..12], EXECCOMMAND, .little);
        @memcpy(raw[12..][0..4], "list");
        raw[16] = 0;
        raw[17] = 'X'; // broken terminator
        var r = std.Io.Reader.fixed(raw[0..18]);
        var tmp: [128]u8 = undefined;
        if (parse(&r, &tmp)) |_| return error.TestUnexpectedResult else |err| try std.testing.expectEqual(error.BadTerminator, err);
    }
    // truncated stream
    {
        const f = try frame(1, EXECCOMMAND, "list", &buf);
        var r = std.Io.Reader.fixed(f[0 .. f.len - 2]);
        var tmp: [128]u8 = undefined;
        if (parse(&r, &tmp)) |_| return error.TestUnexpectedResult else |err| try std.testing.expect(err == error.EndOfStream or err == error.TooShort);
    }
    // interior NUL truncates the payload (no smuggling past the cut)
    {
        var raw: [32]u8 = undefined;
        std.mem.writeInt(i32, raw[0..4], 4 + 4 + 3 + 2, .little);
        std.mem.writeInt(i32, raw[4..8], 7, .little);
        std.mem.writeInt(i32, raw[8..12], EXECCOMMAND, .little);
        raw[12] = 'a';
        raw[13] = 0;
        raw[14] = 'b';
        raw[15] = 0;
        raw[16] = 0;
        var r = std.Io.Reader.fixed(raw[0..17]);
        var tmp: [128]u8 = undefined;
        const p = try parse(&r, &tmp);
        try std.testing.expectEqualSlices(u8, "a", p.payload);
    }
}

test "password compare: equal/different/length/empty" {
    try std.testing.expect(passwordOk("s3cret!", "s3cret!"));
    try std.testing.expect(!passwordOk("s3cret!", "s3cret?"));
    try std.testing.expect(!passwordOk("s3cret!", "s3cret"));
    try std.testing.expect(!passwordOk("s3cret", "s3cret!"));
    try std.testing.expect(!passwordOk("", ""));
    try std.testing.expect(!passwordOk("x", ""));
}


const Conn = @import("conn.zig").Conn;

test "rcon loopback: auth, gating, dispatch, close rules" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var srv = Server{ .net = undefined, .io = io, .config = .{}, .gpa = a };
    defer srv.registry.deinit(a);
    defer if (srv.perms) |*db| db.deinit();
    var port: u16 = 38081;
    var listener: std.Io.net.Server = while (true) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        break addr.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => {
                port += 1;
                if (port > 38110) return err;
                continue;
            },
            else => return err,
        };
    };
    defer listener.deinit(io);
    const Harness = struct {
        fn run(l: *std.Io.net.Server, rio: std.Io, srv_: *Server, pw: []const u8) void {
            const stream = l.accept(rio) catch return;
            handleConn(stream, rio, srv_, pw);
        }
    };
    // Owned raw packet bytes (id+type+payload+2 nulls); payload() views them.
    const Raw = struct {
        buf: []u8,
        fn free(self: *@This()) void {
            a.free(self.buf);
        }
        fn id(self: *const @This()) i32 {
            return std.mem.readInt(i32, self.buf[0..4], .little);
        }
        fn typ(self: *const @This()) i32 {
            return std.mem.readInt(i32, self.buf[4..8], .little);
        }
        fn payload(self: *const @This()) []const u8 {
            return self.buf[8 .. self.buf.len - 2];
        }
    };
    const Cli = struct {
        stream: std.Io.net.Stream,
        fn connect(p: u16) !@This() {
            const addr = try std.Io.net.IpAddress.parse("127.0.0.1", p);
            return .{ .stream = try addr.connect(io, .{ .mode = .stream }) };
        }
        fn close(self: *@This()) void {
            self.stream.close(io);
        }
        fn send(self: *@This(), id: i32, typ: i32, payload: []const u8) !void {
            var fb: [8192]u8 = undefined;
            const f = try frame(id, typ, payload, &fb);
            var wb: [8192]u8 = undefined;
            var w = self.stream.writer(io, &wb);
            try w.interface.writeAll(f);
            try w.interface.flush();
        }
        fn sendRaw(self: *@This(), bytes: []const u8) !void {
            var wb: [256]u8 = undefined;
            var w = self.stream.writer(io, &wb);
            try w.interface.writeAll(bytes);
            try w.interface.flush();
        }
        fn recv(self: *@This()) !Raw {
            var rb: [8192]u8 = undefined;
            var r = self.stream.reader(io, &rb);
            var lb: [4]u8 = undefined;
            r.interface.readSliceAll(&lb) catch return error.EndOfStream;
            const len = std.mem.readInt(i32, &lb, .little);
            if (len < 0 or len > 8192) return error.CorruptPacket;
            const raw = try a.alloc(u8, @intCast(len));
            errdefer a.free(raw);
            r.interface.readSliceAll(raw) catch return error.EndOfStream;
            return .{ .buf = raw };
        }
    };
    // 1. command before auth -> connection closed, no reply.
    {
        var th = try std.Thread.spawn(.{}, Harness.run, .{ &listener, io, &srv, "secret" });
        var c = try Cli.connect(port);
        try c.send(11, EXECCOMMAND, "list");
        try std.testing.expectError(error.EndOfStream, c.recv());
        c.close();
        th.join();
    }
    // 2. wrong password -> id -1; 3-strike cap closes even a correct 4th try.
    {
        var th = try std.Thread.spawn(.{}, Harness.run, .{ &listener, io, &srv, "secret" });
        var c = try Cli.connect(port);
        try c.send(21, AUTH, "nope");
        var r0 = try c.recv();
        defer r0.free();
        try std.testing.expectEqual(@as(i32, -1), r0.id());
        try std.testing.expectEqual(AUTH_RESPONSE, r0.typ());
        try c.send(22, AUTH, "nope2");
        var r1 = try c.recv();
        defer r1.free();
        try std.testing.expectEqual(@as(i32, -1), r1.id());
        try c.send(23, AUTH, "nope3");
        var r2 = try c.recv();
        defer r2.free();
        try std.testing.expectEqual(@as(i32, -1), r2.id());
        try c.send(24, AUTH, "secret");
        try std.testing.expectError(error.EndOfStream, c.recv());
        c.close();
        th.join();
    }
    // 3. auth ok, then commands run with console authority.
    {
        var th = try std.Thread.spawn(.{}, Harness.run, .{ &listener, io, &srv, "secret" });
        var c = try Cli.connect(port);
        try c.send(7, AUTH, "secret");
        var ra = try c.recv();
        defer ra.free();
        try std.testing.expectEqual(@as(i32, 7), ra.id());
        try std.testing.expectEqual(AUTH_RESPONSE, ra.typ());
        try c.send(8, EXECCOMMAND, "list");
        var rl = try c.recv();
        defer rl.free();
        try std.testing.expectEqual(@as(i32, 8), rl.id());
        try std.testing.expectEqual(RESPONSE_VALUE, rl.typ());
        try std.testing.expectEqualStrings("Connected (0):", rl.payload());
        // unknown command -> same unknown reply as in-game
        try c.send(9, EXECCOMMAND, "frobnicate");
        var ru = try c.recv();
        defer ru.free();
        try std.testing.expectEqualStrings("Unknown command. Try /help", ru.payload());
        // leading slash tolerated
        try c.send(10, EXECCOMMAND, "/help");
        var rh = try c.recv();
        defer rh.free();
        try std.testing.expect(std.mem.startsWith(u8, rh.payload(), "Commands: /help"));
        c.close();
        th.join();
    }
    // 4. RCON can administrate: op a player, verify the matrix changed.
    {
        var th = try std.Thread.spawn(.{}, Harness.run, .{ &listener, io, &srv, "secret" });
        var c = try Cli.connect(port);
        try c.send(31, AUTH, "secret");
        var ra = try c.recv();
        defer ra.free();
        try std.testing.expectEqual(@as(i32, 31), ra.id());
        try c.send(32, EXECCOMMAND, "op MalloryR");
        var ro = try c.recv();
        defer ro.free();
        try std.testing.expectEqualStrings("Opped MalloryR.", ro.payload());
        srv.perm_lock.lock();
        const lvl = if (srv.perms) |*db| db.levelFor("MalloryR") else 0;
        srv.perm_lock.unlock();
        try std.testing.expectEqual(@as(u8, 4), lvl);
        c.close();
        th.join();
    }
    // 5. oversize length / unknown type close the connection.
    {
        var th = try std.Thread.spawn(.{}, Harness.run, .{ &listener, io, &srv, "secret" });
        var c = try Cli.connect(port);
        var lb: [4]u8 = undefined;
        std.mem.writeInt(i32, &lb, max_packet + 1, .little);
        try c.sendRaw(&lb);
        try std.testing.expectError(error.EndOfStream, c.recv());
        c.close();
        th.join();
    }
    {
        var th = try std.Thread.spawn(.{}, Harness.run, .{ &listener, io, &srv, "secret" });
        var c = try Cli.connect(port);
        try c.send(41, AUTH, "secret");
        var ra = try c.recv();
        defer ra.free();
        try std.testing.expectEqual(@as(i32, 41), ra.id());
        try c.send(42, 99, "whatever");
        try std.testing.expectError(error.EndOfStream, c.recv());
        c.close();
        th.join();
    }
}

test "isStopCommand shapes" {
    const S = @import("server.zig").Server;
    try std.testing.expect(S.isStopCommand("/stop"));
    try std.testing.expect(S.isStopCommand("stop"));
    try std.testing.expect(S.isStopCommand("/stop now please"));
    try std.testing.expect(!S.isStopCommand("/sto"));
    try std.testing.expect(!S.isStopCommand("/status"));
    try std.testing.expect(!S.isStopCommand("/save-all"));
    try std.testing.expect(!S.isStopCommand(""));
    try std.testing.expect(!S.isStopCommand("/"));
}

