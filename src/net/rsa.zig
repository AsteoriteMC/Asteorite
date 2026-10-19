//! RSA-2048 PKCS#1 v1.5 for Minecraft online-mode login.
//!
//! Ported from SculkHeart (https://github.com/OrkenSab/SculkHeart,
//! src/crypto/rsa.zig, MIT licensed, (c) OrkenSab) with changes:
//! - Zig 0.16 bigint API (`Managed` lost arithmetic ops; modpow is built on
//!   `Mutable.mulNoAlias` + `Managed.divTrunc` + `setString(16, hex)`).
//! - File/process APIs use `std.Io` (`Dir`, `process.spawn(io, ...)`).
//!
//! Only decryption runs per login (in-process, no subprocess). Keypair
//! generation shells out to `openssl` ONCE at first startup, exactly like
//! upstream. The private key file is created 0600 and gitignored.

const std = @import("std");
const big = std.math.big;
const Limb = big.Limb;
const Managed = big.int.Managed;
const Mutable = big.int.Mutable;

pub const key_bytes = 256; // RSA-2048

pub const RsaKeyPair = struct {
    allocator: std.mem.Allocator,
    public_key_der: []const u8, // owned (SubjectPublicKeyInfo DER, sent to client)
    modulus: [key_bytes]u8,
    private_exp: [key_bytes]u8,

    pub fn deinit(self: *RsaKeyPair) void {
        self.allocator.free(self.public_key_der);
    }

    /// PKCS#1 v1.5 decrypt: m = c^d mod n, strip 0x00 0x02 PS 0x00.
    pub fn decrypt(self: *const RsaKeyPair, allocator: std.mem.Allocator, ciphertext: []const u8) ![]u8 {
        if (ciphertext.len != key_bytes) return error.InvalidCiphertextLength;

        var n_num = try bytesToManaged(allocator, &self.modulus);
        defer n_num.deinit();
        var d_num = try bytesToManaged(allocator, &self.private_exp);
        defer d_num.deinit();
        var ct_num = try bytesToManaged(allocator, ciphertext);
        defer ct_num.deinit();
        var pt_num = try Managed.init(allocator);
        defer pt_num.deinit();

        try modPow(&pt_num, &ct_num, &d_num, &n_num);

        var block: [key_bytes]u8 = undefined;
        try managedToBytes(&pt_num, &block);

        // 0x00 0x02 [PS >= 8 nonzero] 0x00 [message]
        if (block[0] != 0x00 or block[1] != 0x02) return error.InvalidPadding;
        var sep: usize = 2;
        while (sep < key_bytes and block[sep] != 0) : (sep += 1) {}
        if (sep < 10 or sep >= key_bytes - 1) return error.InvalidPadding;
        return try allocator.dupe(u8, block[sep + 1 ..]);
    }

    /// PKCS#1 v1.5 encrypt with e=65537 (used by tests + any client-side tooling).
    pub fn encryptPkcs1v15(self: *const RsaKeyPair, io: std.Io, allocator: std.mem.Allocator, message: []const u8) ![key_bytes]u8 {
        if (message.len > key_bytes - 11) return error.MessageTooLong;
        var block: [key_bytes]u8 = undefined;
        block[0] = 0x00;
        block[1] = 0x02;
        const ps_len = key_bytes - 3 - message.len;
        var i: usize = 0;
        while (i < ps_len) : (i += 1) {
            var r: [1]u8 = undefined;
            // nonzero random padding bytes
            while (true) {
                io.randomSecure(&r) catch {
                    io.random(&r);
                    if (r[0] != 0) break;
                    continue;
                };
                if (r[0] != 0) break;
            }
            block[2 + i] = r[0];
        }
        block[2 + ps_len] = 0x00;
        @memcpy(block[3 + ps_len ..], message);

        var base = try bytesToManaged(allocator, &block);
        defer base.deinit();
        var exp = try Managed.initSet(allocator, 65537);
        defer exp.deinit();
        var mod = try bytesToManaged(allocator, &self.modulus);
        defer mod.deinit();
        var res = try Managed.init(allocator);
        defer res.deinit();
        try modPow(&res, &base, &exp, &mod);

        var out: [key_bytes]u8 = undefined;
        try managedToBytes(&res, &out);
        return out;
    }
};

// ---------- bigint helpers (0.16: Mutable ops + Managed.divTrunc) ----------

fn bytesToManaged(allocator: std.mem.Allocator, bytes: []const u8) !Managed {
    const hex = try allocator.alloc(u8, bytes.len * 2);
    defer allocator.free(hex);
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        hex[2 * i] = digits[b >> 4];
        hex[2 * i + 1] = digits[b & 0xF];
    }
    var m = try Managed.init(allocator);
    errdefer m.deinit();
    try m.setString(16, hex);
    return m;
}

fn managedToBytes(num: *const Managed, buf: []u8) !void {
    var v = try num.clone();
    defer v.deinit();
    var c256 = try Managed.initSet(v.allocator, 256);
    defer c256.deinit();
    var q = try Managed.init(v.allocator);
    defer q.deinit();
    var r = try Managed.init(v.allocator);
    defer r.deinit();
    var idx = buf.len;
    while (idx > 0) {
        idx -= 1;
        try Managed.divTrunc(&q, &r, &v, &c256);
        buf[idx] = try r.toInt(u8);
        try v.copy(q.toConst());
    }
}

/// r = (a * b) % m. `a`, `b`, `m` are not modified.
fn modMul(r: *Managed, a: *const Managed, b: *const Managed, m: *const Managed) !void {
    const allocator = r.allocator;
    const la = a.len();
    const lb = b.len();
    const prod_limbs = try allocator.alloc(Limb, la + lb);
    defer allocator.free(prod_limbs);
    var prod_mut = Mutable{ .limbs = prod_limbs, .len = prod_limbs.len, .positive = true };
    Mutable.mulNoAlias(&prod_mut, a.toConst(), b.toConst(), allocator);
    var prod = try Managed.init(allocator);
    defer prod.deinit();
    try prod.copy(prod_mut.toConst());
    var q = try Managed.init(allocator);
    defer q.deinit();
    try Managed.divTrunc(&q, r, &prod, m);
}

fn modPow(res: *Managed, base: *const Managed, exp: *const Managed, mod: *const Managed) !void {
    const allocator = res.allocator;
    var r = try Managed.initSet(allocator, 1);
    defer r.deinit();
    var b = try base.clone();
    defer b.deinit();
    var e = try exp.clone();
    defer e.deinit();
    var tmp = try Managed.init(allocator);
    defer tmp.deinit();

    const bit_len = e.bitCountAbs();
    var i: usize = 0;
    while (i < bit_len) : (i += 1) {
        if (e.isOdd()) {
            try modMul(&tmp, &r, &b, mod);
            try r.copy(tmp.toConst());
        }
        // e >>= 1 (via temp; Managed.shiftRight documents aliasing via capacity path, temp is safest)
        try Managed.shiftRight(&tmp, &e, 1);
        try e.copy(tmp.toConst());
        if (i + 1 < bit_len) {
            try modMul(&tmp, &b, &b, mod);
            try b.copy(tmp.toConst());
        }
    }
    try res.copy(r.toConst());
}

// ---------- ASN.1 DER (PKCS#1 / PKCS#8), unchanged logic from upstream ----------

fn readAsn1Length(data: []const u8, offset: *usize) !usize {
    if (offset.* >= data.len) return error.InvalidAsn1;
    const b = data[offset.*];
    offset.* += 1;
    if ((b & 0x80) == 0) return b;
    const num_bytes = b & 0x7F;
    if (num_bytes == 0 or num_bytes > 4 or offset.* + num_bytes > data.len) return error.InvalidAsn1;
    var len: usize = 0;
    var i: usize = 0;
    while (i < num_bytes) : (i += 1) {
        len = (len << 8) | data[offset.*];
        offset.* += 1;
    }
    return len;
}

fn readAsn1Integer(data: []const u8, offset: *usize) ![]const u8 {
    if (offset.* >= data.len or data[offset.*] != 0x02) return error.InvalidAsn1;
    offset.* += 1;
    const len = try readAsn1Length(data, offset);
    if (offset.* + len > data.len) return error.InvalidAsn1;
    var slice = data[offset.* .. offset.* + len];
    offset.* += len;
    while (slice.len > 1 and slice[0] == 0x00) slice = slice[1..];
    return slice;
}

fn parseRsaPrivateKey(der: []const u8) !struct { n: []const u8, d: []const u8 } {
    if (der.len < 4 or der[0] != 0x30) return error.InvalidAsn1;
    var offset: usize = 1;
    _ = try readAsn1Length(der, &offset);
    if (offset >= der.len) return error.InvalidAsn1;
    if (der[offset] != 0x02) return error.InvalidAsn1;
    _ = try readAsn1Integer(der, &offset);
    if (offset >= der.len) return error.InvalidAsn1;
    if (der[offset] == 0x02) {
        const n = try readAsn1Integer(der, &offset);
        _ = try readAsn1Integer(der, &offset); // e
        const d = try readAsn1Integer(der, &offset);
        return .{ .n = n, .d = d };
    } else if (der[offset] == 0x30) {
        offset += 1;
        const alg_len = try readAsn1Length(der, &offset);
        offset += alg_len;
        if (offset >= der.len or der[offset] != 0x04) return error.InvalidAsn1;
        offset += 1;
        _ = try readAsn1Length(der, &offset);
        return try parseRsaPrivateKey(der[offset..]);
    } else {
        return error.InvalidAsn1;
    }
}

/// Load or (once) generate RSA-2048 keys via openssl. Private key is 0600.
pub fn ensureKeys(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, priv_name: []const u8, pub_name: []const u8) !RsaKeyPair {
    const priv_exists = blk: {
        var f = dir.openFile(io, priv_name, .{}) catch break :blk false;
        f.close(io);
        break :blk true;
    };
    const pub_exists = blk: {
        var f = dir.openFile(io, pub_name, .{}) catch break :blk false;
        f.close(io);
        break :blk true;
    };

    if (!priv_exists or !pub_exists) {
        std.log.info("generating RSA-2048 keypair ({s}, {s})...", .{ priv_name, pub_name });
        // tmp PEM in the same dir
        const spawn_opts = .{
            .cwd = std.process.Child.Cwd{ .dir = dir },
            .stdout = std.process.SpawnOptions.StdIo.ignore,
            .stderr = std.process.SpawnOptions.StdIo.ignore,
        };
        {
            var gen = try std.process.spawn(io, .{
                .argv = &.{ "openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", "tmp_rsa_gen.pem" },
                .cwd = spawn_opts.cwd,
                .stdout = .ignore,
                .stderr = .ignore,
            });
            const term = try gen.wait(io);
            if (term != .exited or term.exited != 0) return error.KeyGenerationFailed;
        }
        defer dir.deleteFile(io, "tmp_rsa_gen.pem") catch {};
        {
            var conv = try std.process.spawn(io, .{
                .argv = &.{ "openssl", "rsa", "-in", "tmp_rsa_gen.pem", "-traditional", "-outform", "DER", "-out", priv_name },
                .cwd = spawn_opts.cwd,
                .stdout = .ignore,
                .stderr = .ignore,
            });
            const term = try conv.wait(io);
            if (term != .exited or term.exited != 0) return error.KeyGenerationFailed;
        }
        {
            var pubgen = try std.process.spawn(io, .{
                .argv = &.{ "openssl", "rsa", "-in", "tmp_rsa_gen.pem", "-pubout", "-outform", "DER", "-out", pub_name },
                .cwd = spawn_opts.cwd,
                .stdout = .ignore,
                .stderr = .ignore,
            });
            const term = try pubgen.wait(io);
            if (term != .exited or term.exited != 0) return error.KeyGenerationFailed;
        }
        // enforce 0600 on the private key. Permissions is a mode_t enum; build it by int.
        const want: std.Io.File.Permissions = @enumFromInt(0o600);
        try dir.setFilePermissions(io, priv_name, want, .{});
    }

    const priv_der = try dir.readFileAlloc(io, priv_name, allocator, .limited(16 * 1024));
    defer allocator.free(priv_der);
    const parts = try parseRsaPrivateKey(priv_der);
    if (parts.n.len > key_bytes or parts.d.len > key_bytes or parts.n.len < 250 or parts.d.len < 250) {
        return error.InvalidKeySize;
    }
    var mod_bytes = [_]u8{0} ** key_bytes;
    @memcpy(mod_bytes[key_bytes - parts.n.len ..], parts.n);
    var exp_bytes = [_]u8{0} ** key_bytes;
    @memcpy(exp_bytes[key_bytes - parts.d.len ..], parts.d);
    const pub_der = try dir.readFileAlloc(io, pub_name, allocator, .limited(1024 * 1024));
    errdefer allocator.free(pub_der);

    return RsaKeyPair{
        .allocator = allocator,
        .public_key_der = pub_der,
        .modulus = mod_bytes,
        .private_exp = exp_bytes,
    };
}

test "rsa pkcs1v15 roundtrip (openssl keygen)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var keys = try ensureKeys(io, std.testing.allocator, tmp.dir, "t_rsa.key", "t_rsa.der");
    defer keys.deinit();
    // public DER is a SubjectPublicKeyInfo (~294 bytes for RSA-2048)
    try std.testing.expectEqual(@as(usize, 294), keys.public_key_der.len);

    const secret = "TestInProcessRSA2048!";
    const ct = try keys.encryptPkcs1v15(io, std.testing.allocator, secret);
    const pt = try keys.decrypt(std.testing.allocator, &ct);
    defer std.testing.allocator.free(pt);
    try std.testing.expectEqualStrings(secret, pt);
}

test "rsa rejects bad input deterministically" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var keys = try ensureKeys(io, std.testing.allocator, tmp.dir, "t2_rsa.key", "t2_rsa.der");
    defer keys.deinit();
    // wrong length
    try std.testing.expectError(error.InvalidCiphertextLength, keys.decrypt(std.testing.allocator, "short"));
    // ASN.1 garbage
    try std.testing.expectError(error.InvalidAsn1, parseRsaPrivateKey("not a der blob at all.............."));
}
