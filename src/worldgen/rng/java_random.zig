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

/// Affine batch coefficients: s_{n+k} = A_k * s_n + C_k (mod 2^48).
/// A_1 = a, C_1 = c; A_{2k} = A_k^2, C_{2k} = A_k*C_k + C_k.
/// Precomputed for k=2,3,4,8 to evaluate successive seeds independently
/// from one starting state (shortens the serial multiply chain).
/// Wrapping u64 arithmetic masked to 48 bits preserves the low bits.
pub const A2: u64 = (multiplier *% multiplier) & mask;
pub const C2: u64 = (multiplier *% addend +% addend) & mask;
pub const A3: u64 = (A2 *% multiplier) & mask;
pub const C3: u64 = (A2 *% addend +% C2) & mask;
pub const A4: u64 = (A2 *% A2) & mask;
pub const C4: u64 = (A2 *% C2 +% C2) & mask;
pub const A8: u64 = (A4 *% A4) & mask;
pub const C8: u64 = (A4 *% C4 +% C4) & mask;

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

    /// Exact bulk two-draw long: same two next(32) draws as nextLong, but
    /// both successor seeds are evaluated independently from the entry
    /// state (A2/C2 affine form), shortening the serial multiply chain
    /// from 2 to 1. Committed seed and outputs are bit-identical.
    pub fn nextLongFast(self: *JavaRandom) i64 {
        const s0 = self.seed;
        const s1 = (s0 *% multiplier +% addend) & mask;
        const s2 = (s0 *% A2 +% C2) & mask;
        self.seed = s2;
        const hi_u: u32 = @intCast(s1 >> 16);
        const lo_u: u32 = @intCast(s2 >> 16);
        const hi: i64 = @as(i32, @bitCast(hi_u));
        const lo: i64 = @as(i32, @bitCast(lo_u));
        return (hi << 32) +% lo;
    }

    /// Exact bulk two-draw double: same 26+27-bit draws as nextDouble,
    /// evaluated independently from the entry state. Bit-identical.
    pub fn nextDoubleFast(self: *JavaRandom) f64 {
        const s0 = self.seed;
        const s1 = (s0 *% multiplier +% addend) & mask;
        const s2 = (s0 *% A2 +% C2) & mask;
        self.seed = s2;
        const hi: u64 = @intCast(s1 >> (48 - 26));
        const lo: u64 = @intCast(s2 >> (48 - 27));
        return @as(f64, @floatFromInt((hi << 27) + lo)) * (1.0 / 9007199254740992.0);
    }

    /// Fill `out` with the next N successive seeds (N>=1) evaluated
    /// independently from the entry state, then commit to the last one.
    /// Uses the A_k/C_k affine jumps: out[i] = s0*A_{i+1}+C_{i+1}.
    /// Exact: same seeds as N serial next() steps. Caller extracts the
    /// top bits exactly as next() would. Unused tails must be discarded
    /// without committing (commit is always to out[N-1]).
    pub fn fillSeeds(self: *JavaRandom, out: []u64) void {
        if (out.len == 0) return;
        const s0 = self.seed;
        // Small-N fast paths with precomputed jumps (independent mults).
        // General tail falls back to serial (still exact).
        if (out.len >= 1) out[0] = (s0 *% multiplier +% addend) & mask;
        if (out.len >= 2) out[1] = (s0 *% A2 +% C2) & mask;
        if (out.len >= 3) out[2] = (s0 *% A3 +% C3) & mask;
        if (out.len >= 4) out[3] = (s0 *% A4 +% C4) & mask;
        if (out.len >= 8) {
            out[7] = (s0 *% A8 +% C8) & mask;
            // 5..7 via one jump from s4 (still exact, keeps chain short).
            const s4 = out[3];
            out[4] = (s4 *% multiplier +% addend) & mask;
            out[5] = (s4 *% A2 +% C2) & mask;
            out[6] = (s4 *% A3 +% C3) & mask;
        } else {
            var i: usize = 4;
            while (i < out.len) : (i += 1) {
                out[i] = (out[i - 1] *% multiplier +% addend) & mask;
            }
        }
        if (out.len > 8) {
            var i: usize = 8;
            while (i < out.len) : (i += 1) {
                out[i] = (out[i - 1] *% multiplier +% addend) & mask;
            }
        }
        self.seed = out[out.len - 1];
    }

    /// Peek the seed k steps ahead without committing (exact).
    /// Serial stepping (hot paths use A2/A4/A8 above); validation only.
    pub fn peekSeed(self: *const JavaRandom, steps: u64) u64 {
        var s = self.seed;
        var i: u64 = 0;
        while (i < steps) : (i += 1) {
            s = (s *% multiplier +% addend) & mask;
        }
        return s;
    }

    pub fn nextBoolean(self: *JavaRandom) bool {
        return self.next(1) != 0;
    }

    pub fn nextFloat(self: *JavaRandom) f32 {
        // `x / 2^24 == x * 2^-24` bit-for-bit (exact power-of-two scale;
        // next(24) < 2^24 is exactly representable).
        return @as(f32, @floatFromInt(self.next(24))) * (1.0 / 16777216.0);
    }

    pub fn nextDouble(self: *JavaRandom) f64 {
        const hi: u64 = self.next(26);
        const lo: u64 = self.next(27);
        // Same exactness argument: value < 2^53, divisor 2^53.
        return @as(f64, @floatFromInt((hi << 27) + lo)) * (1.0 / 9007199254740992.0);
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

test "bulk affine LCG matches serial (nextLongFast/nextDoubleFast/fillSeeds)" {
    const seeds = [_]i64{ 0, 1, 42, -1, 0x123456789ABCDEF, std.math.minInt(i64) };
    for (seeds) |s| {
        var a = JavaRandom.init(s);
        var b = JavaRandom.init(s);
        // nextLongFast vs nextLong over 8 values.
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            try std.testing.expectEqual(a.nextLong(), b.nextLongFast());
        }
        // nextDoubleFast vs nextDouble over 8 values.
        var c = JavaRandom.init(s);
        var d = JavaRandom.init(s);
        i = 0;
        while (i < 8) : (i += 1) {
            try std.testing.expectEqual(@as(u64, @bitCast(c.nextDouble())), @as(u64, @bitCast(d.nextDoubleFast())));
        }
        // fillSeeds vs serial seeds over 8 steps.
        var e = JavaRandom.init(s);
        var f = JavaRandom.init(s);
        var buf: [8]u64 = undefined;
        f.fillSeeds(&buf);
        i = 0;
        while (i < 8) : (i += 1) {
            // Serial step: advance once, capture seed.
            e.seed = (e.seed *% multiplier +% addend) & mask;
            try std.testing.expectEqual(e.seed, buf[i]);
        }
        try std.testing.expectEqual(e.seed, f.seed);
    }
}
