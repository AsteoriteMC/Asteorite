//! Offline-mode UUIDs (no Yggdrasil): UUIDv3("OfflinePlayer:"+name).
//! Format check: version nibble 3, variant bits 10xxxxxx.

const std = @import("std");

pub fn offlineUuid(name: []const u8) [16]u8 {
    var arena: [64]u8 = undefined; // "OfflinePlayer:" (14) + name; 1.7 names <= 16 chars
    const prefix = "OfflinePlayer:";
    std.debug.assert(name.len <= 16);
    @memcpy(arena[0..prefix.len], prefix);
    @memcpy(arena[prefix.len..][0..name.len], name);
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(arena[0 .. prefix.len + name.len], &digest, .{});
    digest[6] = (digest[6] & 0x0F) | 0x30; // version 3
    digest[8] = (digest[8] & 0x3F) | 0x80; // variant RFC4122
    return digest;
}

/// Standard 8-4-4-4-12 hyphenated form (36 chars + NUL if caller wants).
pub fn formatUuid(uuid: [16]u8, out: *[36]u8) void {
    const hex = "0123456789abcdef";
    var p: usize = 0;
    for (uuid, 0..) |b, i| {
        out[p] = hex[b >> 4];
        out[p + 1] = hex[b & 0xF];
        p += 2;
        if (i == 3 or i == 5 or i == 7 or i == 9) {
            out[p] = '-';
            p += 1;
        }
    }
    std.debug.assert(p == 36);
}

test "offline uuid vectors (python hashlib reference)" {
    const t = offlineUuid("testplayer");
    var s: [36]u8 = undefined;
    formatUuid(t, &s);
    try std.testing.expectEqualStrings("52d22a52-7b4a-339e-8a09-aa52384d72fd", &s);
    const n = offlineUuid("Notch");
    formatUuid(n, &s);
    try std.testing.expectEqualStrings("b50ad385-829d-3141-a216-7e7d7539ba7f", &s);
    // version + variant bits
    try std.testing.expectEqual(@as(u8, 3), t[6] >> 4);
    try std.testing.expectEqual(@as(u8, 0b10), t[8] >> 6);
    // case-sensitive names differ
    try std.testing.expect(!std.mem.eql(u8, &offlineUuid("notch"), &offlineUuid("Notch")));
}
