//! fdlibm __ieee754_log port (StrictMath.log bit-exact) for gaussian parity.
//!
//! Zig's std.math.log and glibc agree with each other but differ from
//! StrictMath by 1 ulp on some inputs (proven: s=0x3fd5d9e5352fee22 gives
//! ...127 in Zig/glibc vs ...126 in StrictMath, and the JVM golden for the
//! seed-42 gaussian needs the ...126 path). java.util.Random.nextGaussian
//! calls StrictMath.log, so this port is load-bearing for parity.
//!
//! Source: netlib fdlibm e_log.c, constants and evaluation order preserved.
//! Only use: nextGaussian. Everything else keeps std.math.
//!
//! ---------------------------------------------------------------------------
//! /* @(#)e_log.c 1.3 95/01/18 */
//! /*
//!  * ====================================================
//!  * Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.
//!  *
//!  * Developed at SunSoft, a Sun Microsystems, Inc. business.
//!  * Permission to use, copy, modify, and distribute this
//!  * software is freely granted, provided that this notice
//!  * is preserved.
//!  * ====================================================
//!  */
//! ---------------------------------------------------------------------------

const std = @import("std");

const ln2_hi: f64 = 6.93147180369123816490e-01;
const ln2_lo: f64 = 1.90821492927058770002e-10;
const two54: f64 = 1.80143985094819840000e+16;
const Lg1: f64 = 6.666666666666735130e-01;
const Lg2: f64 = 3.999999999940941908e-01;
const Lg3: f64 = 2.857142874366239149e-01;
const Lg4: f64 = 2.222219843214978396e-01;
const Lg5: f64 = 1.818357216161805012e-01;
const Lg6: f64 = 1.531383769920937332e-01;
const Lg7: f64 = 1.479819860511658591e-01;

/// Bit-exact StrictMath.log. Special cases return inf/nan like fdlibm.
pub fn strictLog(x_in: f64) f64 {
    var x = x_in;
    var hx: u32 = @truncate(@as(u64, @bitCast(x)) >> 32);
    const lx: u32 = @truncate(@as(u64, @bitCast(x)));
    var k: i32 = 0;

    if (hx < 0x00100000) {
        // x < 2**-1022
        if (((hx & 0x7fffffff) | lx) == 0)
            return -std.math.inf(f64); // log(+-0) = -inf
        if (@as(i32, @bitCast(hx)) < 0)
            return std.math.nan(f64); // log(-#) = NaN
        k -= 54;
        x *= two54; // subnormal: scale up
        hx = @truncate(@as(u64, @bitCast(x)) >> 32);
    }
    if (hx >= 0x7ff00000) {
        if ((hx | lx) == 0x7ff00000) return x; // +inf -> +inf
        return std.math.nan(f64); // NaN in -> NaN out (payload not preserved)
    }

    k += @as(i32, @bitCast(hx >> 20)) - 1023;
    hx &= 0x000fffff;
    const i: u32 = (hx +% 0x95f64) & 0x100000;
    // normalize x or x/2
    const bits: u64 = (@as(u64, hx | (i ^ 0x3ff00000)) << 32) | lx;
    x = @bitCast(bits);
    k += @intCast(i >> 20);

    const f: f64 = x - 1.0;
    if ((0x000fffff & (2 +% hx)) < 3) {
        // |f| < 2**-20
        if (f == 0.0) {
            if (k == 0) return 0.0;
            const dk: f64 = @floatFromInt(k);
            return dk * ln2_hi + dk * ln2_lo;
        }
        const R: f64 = f * f * (0.5 - 0.33333333333333333 * f);
        if (k == 0) return f - R;
        const dk: f64 = @floatFromInt(k);
        return dk * ln2_hi - ((R - dk * ln2_lo) - f);
    }

    const s: f64 = f / (2.0 + f);
    const dk: f64 = @floatFromInt(k);
    const z: f64 = s * s;
    const ii: i32 = @as(i32, @bitCast(hx)) -% 0x6147a;
    const w: f64 = z * z;
    const j: i32 = 0x6b851 -% @as(i32, @bitCast(hx));
    const t1: f64 = w * (Lg2 + w * (Lg4 + w * Lg6));
    const t2: f64 = z * (Lg1 + w * (Lg3 + w * (Lg5 + w * Lg7)));
    const ij: i32 = ii | j;
    const R: f64 = t2 + t1;
    if (ij > 0) {
        const hfsq: f64 = 0.5 * f * f;
        if (k == 0) {
            return f - (hfsq - s * (hfsq + R));
        } else {
            return dk * ln2_hi - ((hfsq - (s * (hfsq + R) + dk * ln2_lo)) - f);
        }
    } else {
        if (k == 0) {
            return f - s * (f - R);
        } else {
            return dk * ln2_hi - ((s * (f - R) - dk * ln2_lo) - f);
        }
    }
}

// ---------------------------------------------------------------------------
// Goldens: OpenJDK StrictMath.log outputs (LogGoldens.java).

test "strictLog matches StrictMath bit-for-bit" {
    const cases = [_]struct { x: f64, want_bits: u64 }{
        .{ .x = 1.0, .want_bits = 0x0000000000000000 },
        .{ .x = 2.0, .want_bits = 0x3fe62e42fefa39ef },
        .{ .x = 10.0, .want_bits = 0x40026bb1bbb55516 },
        .{ .x = 0.5, .want_bits = 0xbfe62e42fefa39ef },
        .{ .x = 0.1, .want_bits = 0xc0026bb1bbb55515 },
        .{ .x = 100.0, .want_bits = 0x40126bb1bbb55516 },
        .{ .x = 1.5, .want_bits = 0x3fd9f323ecbf984c },
        .{ .x = 0.30000000000000004, .want_bits = 0xbff34378fcbda720 },
        .{ .x = 7.0, .want_bits = 0x3fff2272ae325a57 },
        // the gaussian-divergence input: glibc/Zig give ...127, StrictMath ...126
        .{ .x = @bitCast(@as(u64, 0x3fd5d9e5352fee22)), .want_bits = 0xbff131ae8f1bf126 },
    };
    for (cases) |c| {
        const got: u64 = @bitCast(strictLog(c.x));
        try std.testing.expectEqual(c.want_bits, got);
    }
}

test "strictLog special cases" {
    try std.testing.expectEqual(-std.math.inf(f64), strictLog(0.0));
    try std.testing.expect(std.math.isNan(strictLog(-1.0)));
    try std.testing.expectEqual(std.math.inf(f64), strictLog(std.math.inf(f64)));
    try std.testing.expect(std.math.isNan(strictLog(std.math.nan(f64))));
}
