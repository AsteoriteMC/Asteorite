//! Mojang session hash + hasJoined verification.
//!
//! Hash algorithm (unchanged since classic protocol, same as SculkHeart's
//! sha1.zig, MIT (c) OrkenSab): SHA1(serverId + secret + pubkeyDER),
//! rendered as signed two's-complement hex with no leading zeroes.

const std = @import("std");

pub const McHashString = struct {
    buf: [41]u8,
    len: usize,

    pub fn slice(self: *const McHashString) []const u8 {
        return self.buf[0..self.len];
    }
};

pub fn formatMinecraftDigest(digest: [20]u8) McHashString {
    var result = McHashString{ .buf = undefined, .len = 0 };
    const is_negative = (digest[0] & 0x80) != 0;
    var magnitude: [20]u8 = undefined;
    if (is_negative) {
        for (digest, 0..) |b, i| magnitude[i] = ~b;
        var carry: u16 = 1;
        var i: usize = 20;
        while (i > 0) {
            i -= 1;
            const sum = @as(u16, magnitude[i]) + carry;
            magnitude[i] = @as(u8, @truncate(sum));
            carry = sum >> 8;
        }
    } else {
        @memcpy(&magnitude, &digest);
    }
    var idx: usize = 0;
    while (idx < 20 and magnitude[idx] == 0) : (idx += 1) {}
    if (idx == 20) {
        result.buf[0] = '0';
        result.len = 1;
        return result;
    }
    var out_pos: usize = 0;
    if (is_negative) {
        result.buf[out_pos] = '-';
        out_pos += 1;
    }
    const hex_chars = "0123456789abcdef";
    const first = magnitude[idx];
    if ((first >> 4) != 0) {
        result.buf[out_pos] = hex_chars[first >> 4];
        out_pos += 1;
    }
    result.buf[out_pos] = hex_chars[first & 0xF];
    out_pos += 1;
    idx += 1;
    while (idx < 20) : (idx += 1) {
        result.buf[out_pos] = hex_chars[magnitude[idx] >> 4];
        out_pos += 1;
        result.buf[out_pos] = hex_chars[magnitude[idx] & 0xF];
        out_pos += 1;
    }
    result.len = out_pos;
    return result;
}

pub fn computeMinecraftHash(server_id: []const u8, secret: []const u8, pub_der: []const u8) McHashString {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(server_id);
    sha.update(secret);
    sha.update(pub_der);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    return formatMinecraftDigest(digest);
}

/// GET {auth_url}?username={name}&serverId={hash} -> 32-hex-char profile id.
/// `auth_url` is configurable so tests can point at a local mock.
pub fn verifySession(io: std.Io, allocator: std.mem.Allocator, auth_url: []const u8, username: []const u8, server_hash: []const u8) ![16]u8 {
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    var url_buf: [1024]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}?username={s}&serverId={s}", .{ auth_url, username, server_hash });
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
    });
    if (res.status != .ok) return error.SessionRejected;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body.written(), .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadSessionJson,
    };
    const id_val = obj.get("id") orelse return error.BadSessionJson;
    const id_str = switch (id_val) {
        .string => |s| s,
        else => return error.BadSessionJson,
    };
    if (id_str.len != 32) return error.BadSessionJson;
    var uuid: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&uuid, id_str) catch return error.BadSessionJson;
    return uuid;
}

test "minecraft digest vectors (wiki)" {
    const vectors = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "Notch", .want = "4ed1f46bbe04bc756bcb17c0c7ce3e4632f06a48" },
        .{ .in = "jeb_", .want = "-7c9d5b0044c130109a5d7b5fb5c317c02b4e28c1" },
        .{ .in = "simon", .want = "88e16a1019277b15d58faf0541e11910eb756f6" },
        .{ .in = "", .want = "-25c65c11a194b4f2cdaa40106a9fe76f5027f8f7" },
    };
    for (vectors) |v| {
        var sha = std.crypto.hash.Sha1.init(.{});
        sha.update(v.in);
        var digest: [20]u8 = undefined;
        sha.final(&digest);
        try std.testing.expectEqualStrings(v.want, formatMinecraftDigest(digest).slice());
    }
}
