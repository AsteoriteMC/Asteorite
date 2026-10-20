//! Exact port of java.util.Random (48-bit LCG) for <=1.17 worldgen parity.
//!
//! Constants and algorithms are from the J2SE spec (Class Random):
//! multiplier 0x5DEECE66D, addend 0xB, mask (1<<48)-1. Every method below
//! replicates the documented call sequence, including the nextInt(bound)
//! rejection loop — parity depends on the *sequence*, not just the values.
//!
//! Golden tests are real JVM outputs (java Goldens, OpenJDK on this box),
//! not re-derivations of the algorithm. If a golden fails, the port is
//! wrong; do not "fix" the test.

const std = @import("std");
const strict_math = @import("strict_math.zig");

pub const multiplier: u64 = 0x5DEECE66D;
pub const addend: u64 = 0xB;
pub const mask: u64 = (1 << 48) - 1;

pub const JavaRandom = struct {
    seed: u64, // only the low 48 bits are live
    next_next_gaussian: f64 = 0.0,
    have_next_next_gaussian: bool = false,

    pub fn init(seed: i64) JavaRandom {
        var r = JavaRandom{ .seed = 0 };
        r.setSeed(seed);
        return r;
    }

    pub fn setSeed(self: *JavaRandom, seed: i64) void {
        self.seed = (@as(u64, @bitCast(seed)) ^ multiplier) & mask;
        self.have_next_next_gaussian = false;
    }

    /// The single primitive: advance the LCG, return the top `bits` bits.
    fn next(self: *JavaRandom, comptime bits: u6) u32 {
        self.seed = (self.seed *% multiplier +% addend) & mask;
        return @intCast(self.seed >> (48 - bits));
    }

    pub fn nextInt(self: *JavaRandom) i32 {
        return @bitCast(self.next(32));
    }

    /// Bounded int, replicating Random.nextInt(int) exactly, including the
    /// power-of-two fast path and the rejection loop in signed-32 arithmetic.
    pub fn nextIntBound(self: *JavaRandom, bound: i32) error{BadBound}!i32 {
        if (bound <= 0) return error.BadBound;
        const b: u32 = @bitCast(bound);
        const r: u32 = self.next(31);
        const m: u32 = b -% 1;
        if (b & m == 0) {
            // (int)((bound * (long)r) >> 31): 64-bit product, arithmetic shift.
            const prod: i64 = @as(i64, bound) * @as(i64, @intCast(r));
            return @intCast(prod >> 31);
        }
        var u: u32 = r;
        var res: u32 = u % b;
        // Java: while (u - r + m < 0) — signed 32-bit wraparound.
        while (@as(i32, @bitCast(u -% res +% m)) < 0) {
            u = self.next(31);
            res = u % b;
        }
        return @bitCast(res);
    }

    pub fn nextLong(self: *JavaRandom) i64 {
        const hi: i64 = @as(i32, @bitCast(self.next(32)));
        const lo: i64 = @as(i32, @bitCast(self.next(32)));
        return (hi << 32) +% lo;
    }

    pub fn nextBoolean(self: *JavaRandom) bool {
        return self.next(1) != 0;
    }

    pub fn nextFloat(self: *JavaRandom) f32 {
        return @as(f32, @floatFromInt(self.next(24))) / @as(f32, 1 << 24);
    }

    pub fn nextDouble(self: *JavaRandom) f64 {
        const hi: u64 = self.next(26);
        const lo: u64 = self.next(27);
        return @as(f64, @floatFromInt((hi << 27) + lo)) / @as(f64, 1 << 53);
    }

    /// Fills buf like Random.nextBytes: 4 bytes per nextInt, little-endian.
    pub fn nextBytes(self: *JavaRandom, buf: []u8) void {
        var i: usize = 0;
        while (i < buf.len) {
            var rnd: u32 = @bitCast(self.nextInt());
            var n: usize = @min(buf.len - i, 4);
            while (n > 0) : (n -= 1) {
                buf[i] = @truncate(rnd);
                rnd >>= 8;
                i += 1;
            }
        }
    }

    /// Polar-method gaussian. Uses the fdlibm log port (strict_math.zig):
    /// StrictMath.log differs from libc/Zig log by 1 ulp on some inputs and
    /// gaussian parity is bit-exact only through this path. Do not "simplify".
    pub fn nextGaussian(self: *JavaRandom) f64 {
        if (self.have_next_next_gaussian) {
            self.have_next_next_gaussian = false;
            return self.next_next_gaussian;
        }
        var v1: f64 = 0;
        var v2: f64 = 0;
        var s: f64 = 0;
        while (true) {
            v1 = 2.0 * self.nextDouble() - 1.0;
            v2 = 2.0 * self.nextDouble() - 1.0;
            s = v1 * v1 + v2 * v2;
            if (!(s >= 1.0 or s == 0.0)) break;
        }
        const mult = @sqrt(-2.0 * strict_math.strictLog(s) / s);
        self.next_next_gaussian = v2 * mult;
        self.have_next_next_gaussian = true;
        return v1 * mult;
    }
};

// ---------------------------------------------------------------------------
// Golden tests: real OpenJDK outputs (see /tmp/opencode/goldens/Goldens.java).
// Hex-float (%a) goldens pin the exact bits of float/double outputs.

test "nextInt goldens" {
    const cases = [_]struct { seed: i64, want: i32 }{
        .{ .seed = 0, .want = -1155484576 },
        .{ .seed = 1, .want = -1155869325 },
        .{ .seed = 42, .want = -1170105035 },
        .{ .seed = -1, .want = 1155099827 },
        .{ .seed = std.math.minInt(i64), .want = -1155484576 },
        .{ .seed = 0x123456789ABCDEF, .want = -332795332 },
    };
    for (cases) |c| {
        var r = JavaRandom.init(c.seed);
        try std.testing.expectEqual(c.want, r.nextInt());
    }
}

test "nextLong goldens" {
    const cases = [_]struct { seed: i64, want: i64 }{
        .{ .seed = 0, .want = -4962768465676381896 },
        .{ .seed = 1, .want = -4964420948893066024 },
        .{ .seed = 42, .want = -5025562857975149833 },
        .{ .seed = -1, .want = 4961115982468162243 },
        .{ .seed = std.math.minInt(i64), .want = -4962768465676381896 },
        .{ .seed = 0x123456789ABCDEF, .want = -1429345065179356975 },
    };
    for (cases) |c| {
        var r = JavaRandom.init(c.seed);
        try std.testing.expectEqual(c.want, r.nextLong());
    }
}

test "nextInt(bound) goldens incl. rejection loop" {
    // bound=1000/seed=0 exercises the rejection path (first draw rejected).
    const cases = [_]struct { seed: i64, bound: i32, v0: i32, v1: i32, v2: i32 }{
        .{ .seed = 0, .bound = 1, .v0 = 0, .v1 = 0, .v2 = 0 },
        .{ .seed = 0, .bound = 2, .v0 = 1, .v1 = 1, .v2 = 0 },
        .{ .seed = 0, .bound = 3, .v0 = 0, .v1 = 1, .v2 = 1 },
        .{ .seed = 0, .bound = 100, .v0 = 60, .v1 = 48, .v2 = 29 },
        .{ .seed = 0, .bound = 1000, .v0 = 360, .v1 = 948, .v2 = 29 },
        .{ .seed = 0, .bound = 1 << 30, .v0 = 784870680, .v1 = 892752974, .v2 = 258274014 },
        .{ .seed = 0, .bound = std.math.maxInt(i32), .v0 = 1569741360, .v1 = 1785505948, .v2 = 516548029 },
        .{ .seed = 42, .bound = 1, .v0 = 0, .v1 = 0, .v2 = 0 },
        .{ .seed = 42, .bound = 2, .v0 = 1, .v1 = 0, .v2 = 1 },
        .{ .seed = 42, .bound = 3, .v0 = 2, .v1 = 0, .v2 = 0 },
        .{ .seed = 42, .bound = 100, .v0 = 30, .v1 = 63, .v2 = 48 },
        .{ .seed = 42, .bound = 1000, .v0 = 130, .v1 = 763, .v2 = 248 },
        .{ .seed = 42, .bound = 1 << 30, .v0 = 781215565, .v1 = 58696381, .v2 = 733605624 },
        .{ .seed = 42, .bound = std.math.maxInt(i32), .v0 = 1562431130, .v1 = 117392763, .v2 = 1467211248 },
    };
    for (cases) |c| {
        var r = JavaRandom.init(c.seed);
        try std.testing.expectEqual(c.v0, try r.nextIntBound(c.bound));
        try std.testing.expectEqual(c.v1, try r.nextIntBound(c.bound));
        try std.testing.expectEqual(c.v2, try r.nextIntBound(c.bound));
    }
    var r = JavaRandom.init(0);
    try std.testing.expectError(error.BadBound, r.nextIntBound(0));
    try std.testing.expectError(error.BadBound, r.nextIntBound(-5));
}

test "float/double/boolean goldens (exact bits)" {
    var r0 = JavaRandom.init(0);
    try std.testing.expectEqual(@as(f32, 0x1.764168p-1), r0.nextFloat());
    try std.testing.expectEqual(@as(f64, 0x1.a9b2a21ec9e5bp-1), r0.nextDouble());
    try std.testing.expectEqual(true, r0.nextBoolean());
    try std.testing.expectEqual(true, r0.nextBoolean());
    var r42 = JavaRandom.init(42);
    try std.testing.expectEqual(@as(f32, 0x1.74833ap-1), r42.nextFloat());
    try std.testing.expectEqual(@as(f64, 0x1.bfd15d773ddfp-5), r42.nextDouble());
    try std.testing.expectEqual(false, r42.nextBoolean());
    try std.testing.expectEqual(false, r42.nextBoolean());
}

test "nextBytes goldens" {
    var r0 = JavaRandom.init(0);
    var b0: [8]u8 = undefined;
    r0.nextBytes(&b0);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x60, 0xb4, 0x20, 0xbb, 0x38, 0x51, 0xd9, 0xd4 }, &b0);
    var r42 = JavaRandom.init(42);
    var b42: [8]u8 = undefined;
    r42.nextBytes(&b42);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x35, 0x9d, 0x41, 0xba, 0xf7, 0x8a, 0xfe, 0x0d }, &b42);
}

test "gaussian goldens (exact bits)" {
    var r0 = JavaRandom.init(0);
    try std.testing.expectEqual(@as(f64, 0x1.9ae59d1d6f861p-1), r0.nextGaussian());
    try std.testing.expectEqual(@as(f64, -0x1.cd9772eb2e0c8p-1), r0.nextGaussian());
    var r42 = JavaRandom.init(42);
    try std.testing.expectEqual(@as(f64, 0x1.2453e82115d86p0), r42.nextGaussian());
    try std.testing.expectEqual(@as(f64, 0x1.d6bca38120847p-1), r42.nextGaussian());
}

test "setSeed resets stream incl. gaussian state" {
    var r = JavaRandom.init(7);
    _ = r.nextGaussian(); // consume into have_next_next_gaussian = true
    r.setSeed(7);
    var fresh = JavaRandom.init(7);
    try std.testing.expectEqual(fresh.nextInt(), r.nextInt());
    try std.testing.expectEqual(fresh.nextGaussian(), r.nextGaussian());
}
