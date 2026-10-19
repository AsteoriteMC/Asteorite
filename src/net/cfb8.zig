//! AES-128/CFB8 stream cipher (Minecraft 1.7.10 login encryption).
//!
//! After EncryptionResponse, both directions use AES with key == IV ==
//! 16-byte shared secret, 8-bit feedback. No std primitive exists, so this
//! implements CFB8 directly on `Aes128.initEnc` block encryption:
//!   enc[i]  = AES(key, sr)[0]; ct[i] = pt[i] ^ enc[i]; sr = sr[1..] ++ ct[i]
//!   pt[i]   = ct[i] ^ AES(key, sr)[0];                 sr = sr[1..] ++ ct[i]
//! One context per direction (encrypt for writes, decrypt for reads).

const std = @import("std");

pub const key_len = 16;

pub const Cfb8 = struct {
    ctx: std.crypto.core.aes.AesEncryptCtx(std.crypto.core.aes.Aes128),
    sr: [16]u8,

    pub fn init(shared_secret: *const [key_len]u8) Cfb8 {
        return .{
            .ctx = std.crypto.core.aes.Aes128.initEnc(shared_secret.*),
            .sr = shared_secret.*,
        };
    }

    fn keystreamByte(self: *Cfb8) u8 {
        var out: [16]u8 = undefined;
        self.ctx.encrypt(&out, &self.sr);
        return out[0];
    }

    fn shift(self: *Cfb8, b: u8) void {
        std.mem.copyForwards(u8, self.sr[0..15], self.sr[1..16]);
        self.sr[15] = b;
    }

    /// Encrypt in place (sender side).
    pub fn encrypt(self: *Cfb8, data: []u8) void {
        for (data) |*b| {
            const k = self.keystreamByte();
            const ct = b.* ^ k;
            b.* = ct;
            self.shift(ct);
        }
    }

    /// Decrypt in place (receiver side).
    pub fn decrypt(self: *Cfb8, data: []u8) void {
        for (data) |*b| {
            const k = self.keystreamByte();
            const ct = b.*;
            b.* = ct ^ k;
            self.shift(ct);
        }
    }
};

test "cfb8 roundtrip + determinism" {
    const secret: [16]u8 = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const pt = "hello minecraft 1.7.10 encryption path";
    var ct = pt.*;
    var enc = Cfb8.init(&secret);
    enc.encrypt(&ct);
    // ciphertext differs from plaintext ( overwhelmingly likely; assert at least one byte differs)
    try std.testing.expect(!std.mem.eql(u8, &ct, pt));
    var dec = Cfb8.init(&secret);
    dec.decrypt(&ct);
    try std.testing.expectEqualSlices(u8, pt, &ct);
    // empty + single byte edge cases
    var e2 = Cfb8.init(&secret);
    var one = [_]u8{0xAB};
    e2.encrypt(&one);
    var d2 = Cfb8.init(&secret);
    d2.decrypt(&one);
    try std.testing.expectEqual(@as(u8, 0xAB), one[0]);
}

test "cfb8 first byte matches raw AES block" {
    // CFB8's first keystream byte must equal AES_ECB(key, iv)[0].
    const secret: [16]u8 = [_]u8{42} ** 16;
    var ctx = std.crypto.core.aes.Aes128.initEnc(secret);
    var blk: [16]u8 = undefined;
    ctx.encrypt(blk[0..], secret[0..]);
    var enc = Cfb8.init(&secret);
    var one = [_]u8{0x00};
    enc.encrypt(&one);
    try std.testing.expectEqual(blk[0], one[0]);
}
