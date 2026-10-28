//! 1.7.10 worldgen noise, ported instruction-by-instruction from javap
//! disassembly of the official server jar (NoiseGeneratorImproved awj,
//! NoiseGeneratorOctaves awk, NoiseGeneratorPerlin awo, Octaves awo/awl).
//! Rationale is in the code comments next to each quirk; goldens are JVM
//! runtime outputs (GenGoldens harness), not re-derivations.
//!
//! Deliberate deviation: the 3D populate y-hash cache is skipped. It is a
//! pure memoization (same hashes recomputed); output is bit-identical,
//! verified by the octave goldens.

const std = @import("std");
const java_random = @import("../rng/java_random.zig");

/// JLS narrowing double -> int: NaN -> 0, saturate, else truncate toward zero.
fn toIntSat(d: f64) i32 {
    if (std.math.isNan(d)) return 0;
    if (d >= 2147483647.0) return std.math.maxInt(i32);
    if (d <= -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(d);
}

/// MathHelper.floor_double: (long)d adjusted down. Long cast saturates like Java.
fn floorLong(d: f64) i64 {
    if (std.math.isNan(d)) return 0;
    if (d >= 9223372036854775807.0) return std.math.maxInt(i64);
    if (d <= -9223372036854775808.0) return std.math.minInt(i64);
    const l: i64 = @intFromFloat(d);
    return if (d < @as(f64, @floatFromInt(l))) l - 1 else l;
}

fn fade(t: f64) f64 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

fn lerp(t: f64, a: f64, b: f64) f64 {
    // Bytecode order: a + t * (b - a).
    return a + t * (b - a);
}

/// Clamp-lerp (vanilla qh.b): clamp t to [0,1], then lerp. Shared by the
/// shaper density blend and the carver width profile (one home, no drift).
pub fn clampLerp(a: f64, b: f64, t: f64) f64 {
    if (t < 0.0) return a;
    if (t > 1.0) return b;
    return a + (b - a) * t;
}

// Gradient tables from awj static init (verified bit-for-bit in disassembly).
const grad_x = [_]f64{ 1, -1, 1, -1, 1, -1, 1, -1, 0, 0, 0, 0, 1, 0, -1, 0 };
const grad_y = [_]f64{ 1, 1, -1, -1, 0, 0, 0, 0, 1, -1, 1, -1, 1, -1, 1, -1 };
const grad_z = [_]f64{ 0, 0, 0, 0, 1, 1, -1, -1, 1, 1, -1, -1, 0, 1, 0, -1 };
const grad2_x = [_]f64{ 1, -1, 1, -1, 1, -1, 1, -1, 0, 0, 0, 0, 1, 0, -1, 0 };
const grad2_y = [_]f64{ 0, 0, 0, 0, 1, 1, -1, -1, 1, 1, -1, -1, 0, 1, 0, -1 };

fn grad2(hash: u8, x: f64, z: f64) f64 {
    const h: usize = @as(usize, hash) & 15;
    return grad2_x[h] * x + grad2_y[h] * z;
}

fn grad3(hash: u8, x: f64, y: f64, z: f64) f64 {
    const h: usize = @as(usize, hash) & 15;
    return grad_x[h] * x + grad_y[h] * y + grad_z[h] * z;
}

/// One scaled lattice axis: wrapped perm index + fractional part + fade.
/// The prologue below repeats per axis (xx/zz in 2D, xx/zz/yy in 3D);
/// one helper keeps the six copies identical.
const AxisParts = struct { wrap: usize, frac: f64, f: f64 };

fn axisParts(base: f64, i: usize, scale: f64, origin: f64) AxisParts {
    var v = base + @as(f64, @floatFromInt(i)) * scale + origin;
    var q = toIntSat(v);
    if (v < @as(f64, @floatFromInt(q))) q -= 1;
    const wrap: usize = @as(usize, @as(u32, @bitCast(q)) & 255);
    v -= @as(f64, @floatFromInt(q));
    return .{ .wrap = wrap, .frac = v, .f = fade(v) };
}

/// Y-corner grad cache replicating vanilla's y-cache check: hashes refresh
/// only when the wrapped y-hash changed (the 256 sentinel covers iy==0);
/// otherwise the x-lerps below reuse STALE grads while y/z use fresh
/// fades. Recomputing always is *more correct* but NOT vanilla-identical
/// (proven by octave goldens) — replicate exactly.
const YCache = struct {
    last_yw: usize = 256, // sentinel: no u8 hash equals this
    b1: usize = 0,
    b2: usize = 0,
    c1: usize = 0,
    c2: usize = 0,
    e1: usize = 0,
    f1: usize = 0,
    x: [8]f64 = [_]f64{0} ** 8,
    /// Cached four X-lerps from the last refresh (bit-identical reuse
    /// while the wrapped y-hash is unchanged). Per-column fx is constant
    /// (YCache lives per (ix,iz) column), so the cached lerps equal a
    /// recomputation; the fx-bits guard preserves exactness even if a
    /// future caller reuses one cache across differing fx.
    lx: [4]f64 = [_]f64{0} ** 4,
    lx_fx_bits: u64 = 0,
    has_lx: bool = false,

    /// Refresh hashes when the y-hash changed; always returns the four
    /// x-lerps (fresh or stale, per the vanilla rule).
    fn lerpX(self: *YCache, perm: *const [512]u8, xi_wrap: usize, zi_wrap: usize, yi_w: usize, xx: f64, yy: f64, zz: f64, fx: f64) [4]f64 {
        if (yi_w != self.last_yw) {
            self.last_yw = yi_w;
            self.b1 = @as(usize, perm[xi_wrap]) + yi_w;
            self.b2 = @as(usize, perm[self.b1]) + zi_wrap;
            self.c1 = @as(usize, perm[xi_wrap + 1]) + yi_w;
            self.c2 = @as(usize, perm[self.c1]) + zi_wrap;
            self.e1 = @as(usize, perm[self.b1 + 1]) + zi_wrap;
            self.f1 = @as(usize, perm[self.c1 + 1]) + zi_wrap;
            // NOTE: the y+1 corners come from the e1/f1 TRACK
            // (recomputed hashes), while the z+1 corners come from
            // the +1 index family. They are NOT interchangeable.
            self.x = .{
                grad3(perm[self.b2], xx, yy, zz),
                grad3(perm[self.c2], xx - 1.0, yy, zz),
                grad3(perm[self.e1], xx, yy - 1.0, zz),
                grad3(perm[self.f1], xx - 1.0, yy - 1.0, zz),
                grad3(perm[self.b2 + 1], xx, yy, zz - 1.0),
                grad3(perm[self.c2 + 1], xx - 1.0, yy, zz - 1.0),
                grad3(perm[self.e1 + 1], xx, yy - 1.0, zz - 1.0),
                grad3(perm[self.f1 + 1], xx - 1.0, yy - 1.0, zz - 1.0),
            };
            self.lx = .{
                lerp(fx, self.x[0], self.x[1]),
                lerp(fx, self.x[2], self.x[3]),
                lerp(fx, self.x[4], self.x[5]),
                lerp(fx, self.x[6], self.x[7]),
            };
            self.lx_fx_bits = @bitCast(fx);
            self.has_lx = true;
        } else {
            // Stale-grad path: X-lerps are constant while fx is constant
            // (per-column). Recompute only if fx bits differ, preserving
            // exactness for any cross-fx reuse.
            const fx_bits: u64 = @bitCast(fx);
            if (!self.has_lx or fx_bits != self.lx_fx_bits) {
                self.lx = .{
                    lerp(fx, self.x[0], self.x[1]),
                    lerp(fx, self.x[2], self.x[3]),
                    lerp(fx, self.x[4], self.x[5]),
                    lerp(fx, self.x[6], self.x[7]),
                };
                self.lx_fx_bits = fx_bits;
                self.has_lx = true;
            }
        }
        return self.lx;
    }
};

/// 1.7 ImprovedNoise (awj). Permutation built from the RNG exactly as vanilla.
pub const ImprovedNoise = struct {
    perm: [512]u8,
    x_coord: f64,
    y_coord: f64,
    z_coord: f64,

    pub fn init(rand: *java_random.JavaRandom) !ImprovedNoise {
        var r = ImprovedNoise{ .perm = undefined, .x_coord = 0, .y_coord = 0, .z_coord = 0 };
        r.x_coord = rand.nextDouble() * 256.0;
        r.y_coord = rand.nextDouble() * 256.0;
        r.z_coord = rand.nextDouble() * 256.0;
        for (0..256) |i| r.perm[i] = @intCast(i);
        for (0..256) |i| {
            const j: usize = @intCast(try rand.nextIntBound(@intCast(256 - i)) + @as(i32, @intCast(i)));
            const tmp = r.perm[i];
            r.perm[i] = r.perm[j];
            r.perm[j] = tmp;
            // NOTE: vanilla copies d[i] -> d[i+256] INSIDE the loop, right
            // after the swap. Same final table; order preserved exactly.
            r.perm[i + 256] = r.perm[i];
        }
        return r;
    }

    /// Full populate (awj.a): ySize==1 takes the 2D branch, else 3D.
    /// Index order: 2D -> x*zSize+z; 3D -> (x*zSize+z)*ySize+y.
    pub fn populate(self: *const ImprovedNoise, arr: []f64, x: f64, y: f64, z: f64, x_size: usize, y_size: usize, z_size: usize, x_scale: f64, y_scale: f64, z_scale: f64, amplitude: f64) void {
        if (y_size == 1) {
            var idx: usize = 0;
            const inv_amp = 1.0 / amplitude;
            // Axis reuse: zp depends only on (z,iz), not ix. Precompute once
            // (bit-identical: same axisParts inputs, same bits).
            var zp_buf: [64]AxisParts = undefined;
            const use_zpre = z_size <= 64;
            if (use_zpre) {
                var iz0: usize = 0;
                while (iz0 < z_size) : (iz0 += 1) {
                    zp_buf[iz0] = axisParts(z, iz0, z_scale, self.z_coord);
                }
            }
            var ix: usize = 0;
            while (ix < x_size) : (ix += 1) {
                const xp = axisParts(x, ix, x_scale, self.x_coord);
                var iz: usize = 0;
                while (iz < z_size) : (iz += 1) {
                    const zp = if (use_zpre) zp_buf[iz] else axisParts(z, iz, z_scale, self.z_coord);
                    // NOTE: vanilla mixes 2D grads on the near corners and
                    // 3D grads (y=0) on the far corners. Not a typo.
                    // NOTE: the second-level values are index SUMS (perm[v]+w),
                    // not indexed loads (perm[v+w]). The corner hash is a
                    // THIRD load: perm[sum]. The 512-long perm table exists
                    // because these sums reach 510.
                    const p0: usize = self.perm[xp.wrap]; // v19
                    const sum0: usize = @as(usize, self.perm[p0]) + zp.wrap; // v20
                    const ha: u8 = self.perm[sum0]; // corner hash
                    const p1: usize = self.perm[xp.wrap + 1]; // v21
                    const sum1: usize = @as(usize, self.perm[p1]) + zp.wrap; // v22
                    const hb: u8 = self.perm[sum1]; // corner hash
                    const v00 = lerp(xp.f, grad2(ha, xp.frac, zp.frac), grad3(hb, xp.frac - 1.0, 0.0, zp.frac));
                    // NOTE: the far corner uses grad3 (y=0) for BOTH terms —
                    // asymmetric with v00's grad2 first term. Bytecode-verified.
                    const v10 = lerp(xp.f, grad3(self.perm[sum0 + 1], xp.frac, 0.0, zp.frac - 1.0), grad3(self.perm[sum1 + 1], xp.frac - 1.0, 0.0, zp.frac - 1.0));
                    arr[idx] += lerp(zp.f, v00, v10) * inv_amp;
                    idx += 1;
                }
            }
            return;
        }
        // 3D branch. y-cache optimization skipped (output-identical).
        var idx: usize = 0;
        const inv_amp = 1.0 / amplitude;
        // Axis reuse: xp depends only on (x,ix), zp only on (z,iz), yp only
        // on (y,iy). Original recomputed zp x_size times (25->5) and yp
        // x_size*z_size times (825->33). Same axisParts inputs => same bits.
        var xp_buf: [64]AxisParts = undefined;
        var zp_buf2: [64]AxisParts = undefined;
        var yp_buf: [256]AxisParts = undefined;
        const use_xpre = x_size <= 64;
        const use_zpre2 = z_size <= 64;
        const use_ypre = y_size <= 256;
        if (use_xpre) {
            var ia: usize = 0;
            while (ia < x_size) : (ia += 1) xp_buf[ia] = axisParts(x, ia, x_scale, self.x_coord);
        }
        if (use_zpre2) {
            var ib: usize = 0;
            while (ib < z_size) : (ib += 1) zp_buf2[ib] = axisParts(z, ib, z_scale, self.z_coord);
        }
        if (use_ypre) {
            var ic: usize = 0;
            while (ic < y_size) : (ic += 1) yp_buf[ic] = axisParts(y, ic, y_scale, self.y_coord);
        }
        var ix: usize = 0;
        while (ix < x_size) : (ix += 1) {
            const xp = if (use_xpre) xp_buf[ix] else axisParts(x, ix, x_scale, self.x_coord);
            var iz: usize = 0;
            while (iz < z_size) : (iz += 1) {
                const zp = if (use_zpre2) zp_buf2[iz] else axisParts(z, iz, z_scale, self.z_coord);
                // Hash bases + x-lerps. NOTE: vanilla only recomputes these when
                // iy==0 or the wrapped y-hash changed (the y-cache check).
                // This is NOT a pure memoization: on a skip, the x-lerps below
                // keep STALE yy grads while the y/z lerps use fresh fy/fz.
                // Recomputing always is *more correct* but NOT vanilla-identical
                // (proven by octave goldens). Replicate exactly (see YCache).
                var cache = YCache{};
                var iy: usize = 0;
                while (iy < y_size) : (iy += 1) {
                    const yp = if (use_ypre) yp_buf[iy] else axisParts(y, iy, y_scale, self.y_coord);
                    const yl = cache.lerpX(&self.perm, xp.wrap, zp.wrap, yp.wrap, xp.frac, yp.frac, zp.frac, xp.f);
                    const z0 = lerp(yp.f, yl[0], yl[1]);
                    const z1 = lerp(yp.f, yl[2], yl[3]);
                    arr[idx] += lerp(zp.f, z0, z1) * inv_amp;
                    idx += 1;
                }
            }
        }
    }
};

/// 1.7 octave stack over ImprovedNoise (awk). Growing amplitudes per octave
/// (1/freq) are vanilla behavior, confirmed by the golden mean (~3213, not ~0).
pub const Octaves = struct {
    gens: []ImprovedNoise,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, rand: *java_random.JavaRandom, count: usize) !Octaves {
        const gens = try alloc.alloc(ImprovedNoise, count);
        for (gens) |*g| g.* = try ImprovedNoise.init(rand);
        return .{ .gens = gens, .alloc = alloc };
    }

    pub fn deinit(self: *Octaves) void {
        self.alloc.free(self.gens);
    }

    /// 3D generate (awk.a 10-arg). Null arr allocates; else zero-fills.
    /// NOTE: the awk 2D entry point just calls this with y=10, ySize=1.
    pub fn generate(self: *const Octaves, arr: ?[]f64, x: i32, y: i32, z: i32, xs: usize, ys: usize, zs: usize, x_scale: f64, y_scale: f64, z_scale: f64) []f64 {
        const out = arr orelse self.alloc.alloc(f64, xs * ys * zs) catch unreachable;
        if (arr != null) @memset(out, 0.0);
        var freq: f64 = 1.0;
        for (self.gens) |*g| {
            var fx = @as(f64, @floatFromInt(x)) * freq * x_scale;
            var fz = @as(f64, @floatFromInt(z)) * freq * z_scale;
            var lx = floorLong(fx);
            var lz = floorLong(fz);
            fx -= @as(f64, @floatFromInt(lx));
            fz -= @as(f64, @floatFromInt(lz));
            lx = @rem(lx, 16777216);
            lz = @rem(lz, 16777216);
            fx += @as(f64, @floatFromInt(lx));
            fz += @as(f64, @floatFromInt(lz));
            const fy = @as(f64, @floatFromInt(y)) * freq * y_scale;
            g.populate(out, fx, fy, fz, xs, ys, zs, x_scale * freq, y_scale * freq, z_scale * freq, freq);
            freq /= 2.0;
        }
        return out;
    }
};

// Simplex (awo) constants, exact bits from the jar.
const skew_f2: f64 = @bitCast(@as(u64, 0x3FD76CF5D0B09954)); // 0.5*(sqrt(3)-1)
const unskew_g2: f64 = @bitCast(@as(u64, 0x3FCB0CB174DF99C8)); // (3-sqrt(3))/6
const simp_grad = [12][2]f64{
    .{ 1, 1 }, .{ -1, 1 }, .{ 1, -1 }, .{ -1, -1 },
    .{ 1, 0 }, .{ -1, 0 }, .{ 1, 0 }, .{ -1, 0 },
    .{ 0, 1 }, .{ 0, -1 }, .{ 0, 1 }, .{ 0, -1 },
};

/// Java-style floor for the simplex lattice: (d>0) ? trunc : trunc-1.
/// NOTE: d==0 maps to -1 (dcmpg/ifle in bytecode), not 0.
fn lattice(d: f64) i32 {
    const t = toIntSat(d);
    return if (d > 0.0) t else t - 1;
}

/// 1.7 simplex Perlin (awo). Stores its own x/y/z offsets.
pub const Simplex = struct {
    perm: [512]u8,
    /// perm[i] % 12 precomputed: all simplex gradient indexes are
    /// non-negative (< 512), so `% 12` == table load, bit-identical.
    perm12: [512]u8,
    x_coord: f64,
    y_coord: f64,
    z_coord: f64,

    pub fn init(rand: *java_random.JavaRandom) !Simplex {
        var r = Simplex{ .perm = undefined, .perm12 = undefined, .x_coord = 0, .y_coord = 0, .z_coord = 0 };
        r.x_coord = rand.nextDouble() * 256.0;
        r.y_coord = rand.nextDouble() * 256.0;
        r.z_coord = rand.nextDouble() * 256.0;
        for (0..256) |i| r.perm[i] = @intCast(i);
        for (0..256) |i| {
            const j: usize = @intCast(try rand.nextIntBound(@intCast(256 - i)) + @as(i32, @intCast(i)));
            const tmp = r.perm[i];
            r.perm[i] = r.perm[j];
            r.perm[j] = tmp;
            r.perm[i + 256] = r.perm[i];
        }
        for (0..512) |i| r.perm12[i] = r.perm[i] % 12;
        return r;
    }

    /// Single eval (awo.a). NOTE: no coordinate offsets here — vanilla adds
    /// them only in the grid path. Do not "fix".
    pub fn eval(self: *const Simplex, x_in: f64, z_in: f64) f64 {
        const s = (x_in + z_in) * skew_f2;
        const i = lattice(x_in + s);
        const j = lattice(z_in + s);
        const t = @as(f64, @floatFromInt(i + j)) * unskew_g2;
        const x0 = @as(f64, @floatFromInt(i)) - t;
        const z0 = @as(f64, @floatFromInt(j)) - t;
        const dx0 = x_in - x0;
        const dz0 = z_in - z0;
        var ci1: i32 = 0;
        var cj1: i32 = 1;
        if (dx0 > dz0) {
            ci1 = 1;
            cj1 = 0;
        }
        const x1 = dx0 - @as(f64, @floatFromInt(ci1)) + unskew_g2;
        const z1 = dz0 - @as(f64, @floatFromInt(cj1)) + unskew_g2;
        const x2 = dx0 - 1.0 + 2.0 * unskew_g2;
        const z2 = dz0 - 1.0 + 2.0 * unskew_g2;
        // NOTE: indices are usize — u8 arithmetic would overflow on +1
        // when the wrapped value is 255 (perm has 512 entries precisely
        // so that [255]+1 = [256] is valid via the duplicated half).
        const ii: usize = @as(usize, @as(u32, @bitCast(i)) & 255);
        const jj: usize = @as(usize, @as(u32, @bitCast(j)) & 255);
        // NOTE: double perm indirection (perm[a + perm[b]]) — same family
        // of transcription trap as the ImprovedNoise 2D hashes. Verified
        // against CFR decompile, not just javap.
        const gi0: usize = self.perm12[@as(usize, ii) + self.perm[jj]];
        const gi1: usize = self.perm12[@as(usize, ii) + @as(usize, @intCast(ci1)) + self.perm[jj + @as(usize, @intCast(cj1))]];
        const gi2: usize = self.perm12[@as(usize, ii) + 1 + self.perm[jj + 1]];
        var t0 = 0.5 - dx0 * dx0 - dz0 * dz0;
        var n0: f64 = 0;
        if (t0 >= 0.0) {
            t0 *= t0;
            n0 = t0 * t0 * (simp_grad[gi0][0] * dx0 + simp_grad[gi0][1] * dz0);
        }
        var t1 = 0.5 - x1 * x1 - z1 * z1;
        var n1: f64 = 0;
        if (t1 >= 0.0) {
            t1 *= t1;
            n1 = t1 * t1 * (simp_grad[gi1][0] * x1 + simp_grad[gi1][1] * z1);
        }
        var t2 = 0.5 - x2 * x2 - z2 * z2;
        var n2: f64 = 0;
        if (t2 >= 0.0) {
            t2 *= t2;
            n2 = t2 * t2 * (simp_grad[gi2][0] * x2 + simp_grad[gi2][1] * z2);
        }
        return 70.0 * (n0 + n1 + n2);
    }

    /// Grid fill (awo.a 9-arg): arr[iz*xs+ix] += 70*(n0+n1+n2)*scale.
    /// Coordinates are offset HERE (not in eval). NOTE: vanilla offsets X by
    /// the 1st RNG double and Z by the *2nd* (field c); the 3rd double is drawn
    /// but never used. Do not "fix" this to use z_coord.
    pub fn grid(self: *const Simplex, arr: []f64, x: f64, z: f64, xs: usize, zs: usize, x_scale: f64, z_scale: f64, scale: f64) void {
        var idx: usize = 0;
        var iz: usize = 0;
        while (iz < zs) : (iz += 1) {
            const zz = (z + @as(f64, @floatFromInt(iz))) * z_scale + self.y_coord;
            var ix: usize = 0;
            while (ix < xs) : (ix += 1) {
                const xx = (x + @as(f64, @floatFromInt(ix))) * x_scale + self.x_coord;
                const s = (xx + zz) * skew_f2;
                const i = lattice(xx + s);
                const j = lattice(zz + s);
                const t = @as(f64, @floatFromInt(i + j)) * unskew_g2;
                const dx0 = xx - (@as(f64, @floatFromInt(i)) - t);
                const dz0 = zz - (@as(f64, @floatFromInt(j)) - t);
                var ci1: i32 = 0;
                var cj1: i32 = 1;
                if (dx0 > dz0) {
                    ci1 = 1;
                    cj1 = 0;
                }
                const x1 = dx0 - @as(f64, @floatFromInt(ci1)) + unskew_g2;
                const z1 = dz0 - @as(f64, @floatFromInt(cj1)) + unskew_g2;
                const x2 = dx0 - 1.0 + 2.0 * unskew_g2;
                const z2 = dz0 - 1.0 + 2.0 * unskew_g2;
                const ii: usize = @as(usize, @as(u32, @bitCast(i)) & 255);
                const jj: usize = @as(usize, @as(u32, @bitCast(j)) & 255);
                // NOTE: double perm indirection — see eval() above.
                const gi0: usize = self.perm12[ii + self.perm[jj]];
                const gi1: usize = self.perm12[ii + @as(usize, @intCast(ci1)) + self.perm[jj + @as(usize, @intCast(cj1))]];
                const gi2: usize = self.perm12[ii + 1 + self.perm[jj + 1]];
                var n0: f64 = 0;
                var t0 = 0.5 - dx0 * dx0 - dz0 * dz0;
                if (t0 >= 0.0) {
                    t0 *= t0;
                    n0 = t0 * t0 * (simp_grad[gi0][0] * dx0 + simp_grad[gi0][1] * dz0);
                }
                var n1: f64 = 0;
                var t1 = 0.5 - x1 * x1 - z1 * z1;
                if (t1 >= 0.0) {
                    t1 *= t1;
                    n1 = t1 * t1 * (simp_grad[gi1][0] * x1 + simp_grad[gi1][1] * z1);
                }
                var n2: f64 = 0;
                var t2 = 0.5 - x2 * x2 - z2 * z2;
                if (t2 >= 0.0) {
                    t2 *= t2;
                    n2 = t2 * t2 * (simp_grad[gi2][0] * x2 + simp_grad[gi2][1] * z2);
                }
                arr[idx] += 70.0 * (n0 + n1 + n2) * scale;
                idx += 1;
            }
        }
    }
};

/// Octave stack over simplex (awl). Decaying amplitudes here (unlike Improved).
pub const SimplexOctaves = struct {
    gens: []Simplex,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, rand: *java_random.JavaRandom, count: usize) !SimplexOctaves {
        const gens = try alloc.alloc(Simplex, count);
        for (gens) |*g| g.* = try Simplex.init(rand);
        return .{ .gens = gens, .alloc = alloc };
    }

    pub fn deinit(self: *SimplexOctaves) void {
        self.alloc.free(self.gens);
    }

    /// Single value: sum(gen(x*f, z*f)/f), f halving.
    pub fn eval(self: *const SimplexOctaves, x: f64, z: f64) f64 {
        var sum: f64 = 0.0;
        var freq: f64 = 1.0;
        for (self.gens) |*g| {
            sum += g.eval(x * freq, z * freq) / freq;
            freq /= 2.0;
        }
        return sum;
    }

    /// Grid (awl 9-arg): per octave, scales and 0.55/amp multiply through.
    pub fn grid(self: *const SimplexOctaves, arr: ?[]f64, x: f64, z: f64, xs: usize, zs: usize, x_scale: f64, z_scale: f64, freq_mul: f64, amp_mul: f64) []f64 {
        const out = arr orelse self.alloc.alloc(f64, xs * zs) catch unreachable;
        if (arr != null and out.len > xs * zs) @memset(out[0 .. xs * zs], 0.0);
        if (arr == null) @memset(out, 0.0);
        var freq: f64 = 1.0;
        var amp: f64 = 1.0;
        for (self.gens) |*g| {
            g.grid(out, x, z, xs, zs, x_scale * freq * amp, z_scale * freq * amp, 0.55 / amp);
            freq *= freq_mul;
            amp *= amp_mul;
        }
        return out;
    }
};

// ---------------------------------------------------------------------------
// Goldens: official 1.7.10 server jar runtime outputs (GenGoldens harness).
// Kahan-summed to be order-independent of accumulation.

fn kahanSum(a: []const f64) f64 {
    var s: f64 = 0.0;
    var c: f64 = 0.0;
    for (a) |v| {
        const y = v - c;
        const t = s + y;
        c = (t - s) - y;
        s = t;
    }
    return s;
}


test "octaves 16 match JVM (684.412^3, 5x33x5)" {
    const alloc = std.testing.allocator;
    // Fresh Random(777): the JVM builds each octave stack from a new Random.
    var rand = java_random.JavaRandom.init(777);
    var oct = try Octaves.init(alloc, &rand, 16);
    defer oct.deinit();
    var buf: [5 * 33 * 5]f64 = [_]f64{0} ** (5 * 33 * 5);
    const out = oct.generate(&buf, 0, 0, 0, 5, 33, 5, 684.412, 684.412, 684.412);
    try std.testing.expectEqual(@as(u64, 0x414511E252892505), @as(u64, @bitCast(kahanSum(out))));
    try std.testing.expectEqual(@as(u64, 0xC0BAD154FF10A0E6), @as(u64, @bitCast(out[0])));
    try std.testing.expectEqual(@as(u64, 0xC0C7F6066206ADEE), @as(u64, @bitCast(out[out.len - 1])));
}

test "octaves 8 match JVM (main noise shape)" {
    const alloc = std.testing.allocator;
    var rand = java_random.JavaRandom.init(777);
    var oct = try Octaves.init(alloc, &rand, 8);
    defer oct.deinit();
    var buf: [5 * 33 * 5]f64 = [_]f64{0} ** (5 * 33 * 5);
    const out = oct.generate(&buf, 0, 0, 0, 5, 33, 5, 8.55515, 4.277575, 8.55515);
    try std.testing.expectEqual(@as(u64, 0xC0D8A5E517EC36BC), @as(u64, @bitCast(kahanSum(out))));
    try std.testing.expectEqual(@as(u64, 0x403FA72C60D662B4), @as(u64, @bitCast(out[0])));
    try std.testing.expectEqual(@as(u64, 0xC053F1EFF2B3FAA8), @as(u64, @bitCast(out[out.len - 1])));
}

test "octaves 10 match JVM (depth noise, 5x5x5 cube)" {
    const alloc = std.testing.allocator;
    var rand = java_random.JavaRandom.init(777);
    var oct = try Octaves.init(alloc, &rand, 10);
    defer oct.deinit();
    var buf: [5 * 5 * 5]f64 = [_]f64{0} ** (5 * 5 * 5);
    // awk 3D entry directly (the 2D entry is only used by surface code).
    const out = oct.generate(&buf, 0, 0, 0, 5, 5, 5, 200.0, 200.0, 0.5);
    try std.testing.expectEqual(@as(u64, 0x40C793C4268D8CF4), @as(u64, @bitCast(kahanSum(out))));
    try std.testing.expectEqual(@as(u64, 0x406434F44EDC3147), @as(u64, @bitCast(out[0])));
    try std.testing.expectEqual(@as(u64, 0x4062FF18F3E4BF78), @as(u64, @bitCast(out[out.len - 1])));
}

test "simplex grid matches JVM (stone noise shape)" {
    const alloc = std.testing.allocator;
    var rand = java_random.JavaRandom.init(777);
    var oct = try SimplexOctaves.init(alloc, &rand, 4);
    defer oct.deinit();
    var buf: [5 * 5]f64 = [_]f64{0} ** (5 * 5);
    // awl 8-arg: (x, z, xs, zs, xsc, zsc, freq_mul) + hardcoded amp_mul 0.5.
    const out = oct.grid(&buf, 0, 0, 5, 5, 200.0, 200.0, 0.5, 0.5);
    try std.testing.expectEqual(@as(u64, 0xC009E67B6C3FE46D), @as(u64, @bitCast(kahanSum(out))));
    try std.testing.expectEqual(@as(u64, 0xBFDC5CDB82BC0630), @as(u64, @bitCast(out[0])));
    try std.testing.expectEqual(@as(u64, 0x4008756080B056AE), @as(u64, @bitCast(out[out.len - 1])));
}

// Differential gate for the axis-precompute + X-lerp-cache optimization:
// a naive reference (no axis tables, recompute X-lerps from stale grads
// every sample) must match the optimized populate bit-for-bit over the
// full array (interior cells included, not just sum/endpoints).
const YCacheNaive = struct {
    last_yw: usize = 256,
    b1: usize = 0,
    b2: usize = 0,
    c1: usize = 0,
    c2: usize = 0,
    e1: usize = 0,
    f1: usize = 0,
    x: [8]f64 = [_]f64{0} ** 8,

    fn lerpX(self: *YCacheNaive, perm: *const [512]u8, xi_wrap: usize, zi_wrap: usize, yi_w: usize, xx: f64, yy: f64, zz: f64, fx: f64) [4]f64 {
        if (yi_w != self.last_yw) {
            self.last_yw = yi_w;
            self.b1 = @as(usize, perm[xi_wrap]) + yi_w;
            self.b2 = @as(usize, perm[self.b1]) + zi_wrap;
            self.c1 = @as(usize, perm[xi_wrap + 1]) + yi_w;
            self.c2 = @as(usize, perm[self.c1]) + zi_wrap;
            self.e1 = @as(usize, perm[self.b1 + 1]) + zi_wrap;
            self.f1 = @as(usize, perm[self.c1 + 1]) + zi_wrap;
            self.x = .{
                grad3(perm[self.b2], xx, yy, zz),
                grad3(perm[self.c2], xx - 1.0, yy, zz),
                grad3(perm[self.e1], xx, yy - 1.0, zz),
                grad3(perm[self.f1], xx - 1.0, yy - 1.0, zz),
                grad3(perm[self.b2 + 1], xx, yy, zz - 1.0),
                grad3(perm[self.c2 + 1], xx - 1.0, yy, zz - 1.0),
                grad3(perm[self.e1 + 1], xx, yy - 1.0, zz - 1.0),
                grad3(perm[self.f1 + 1], xx - 1.0, yy - 1.0, zz - 1.0),
            };
        }
        return .{
            lerp(fx, self.x[0], self.x[1]),
            lerp(fx, self.x[2], self.x[3]),
            lerp(fx, self.x[4], self.x[5]),
            lerp(fx, self.x[6], self.x[7]),
        };
    }
};

fn populateNaive(self: *const ImprovedNoise, arr: []f64, x: f64, y: f64, z: f64, x_size: usize, y_size: usize, z_size: usize, x_scale: f64, y_scale: f64, z_scale: f64, amplitude: f64) void {
    var idx: usize = 0;
    const inv_amp = 1.0 / amplitude;
    var ix: usize = 0;
    while (ix < x_size) : (ix += 1) {
        const xp = axisParts(x, ix, x_scale, self.x_coord);
        var iz: usize = 0;
        while (iz < z_size) : (iz += 1) {
            const zp = axisParts(z, iz, z_scale, self.z_coord);
            var cache = YCacheNaive{};
            var iy: usize = 0;
            while (iy < y_size) : (iy += 1) {
                const yp = axisParts(y, iy, y_scale, self.y_coord);
                const yl = cache.lerpX(&self.perm, xp.wrap, zp.wrap, yp.wrap, xp.frac, yp.frac, zp.frac, xp.f);
                const z0 = lerp(yp.f, yl[0], yl[1]);
                const z1 = lerp(yp.f, yl[2], yl[3]);
                arr[idx] += lerp(zp.f, z0, z1) * inv_amp;
                idx += 1;
            }
        }
    }
}

test "populate precompute matches naive full-array (5x33x5 + 5x5x5)" {
    const alloc = std.testing.allocator;
    var rand = java_random.JavaRandom.init(777);
    var imp = try ImprovedNoise.init(&rand);
    // Case 1: 5x33x5 density shape (covers stale-cache hits on small-freq octaves).
    {
        var opt: [5 * 33 * 5]f64 = [_]f64{0} ** (5 * 33 * 5);
        var refb: [5 * 33 * 5]f64 = [_]f64{0} ** (5 * 33 * 5);
        imp.populate(&opt, 10.0, 20.0, 30.0, 5, 33, 5, 684.412, 684.412, 684.412, 4.0);
        populateNaive(&imp, &refb, 10.0, 20.0, 30.0, 5, 33, 5, 684.412, 684.412, 684.412, 4.0);
        for (opt, refb, 0..) |a, b, i| {
            if (@as(u64, @bitCast(a)) != @as(u64, @bitCast(b))) {
                std.debug.print("mismatch at {d}: opt {x} ref {x}\n", .{ i, @as(u64, @bitCast(a)), @as(u64, @bitCast(b)) });
                try std.testing.expectEqual(@as(u64, @bitCast(b)), @as(u64, @bitCast(a)));
            }
        }
    }
    // Case 2: small-freq octave (many Y-cache hits) + different amplitude.
    {
        var opt: [5 * 5 * 5]f64 = [_]f64{0} ** (5 * 5 * 5);
        var refb: [5 * 5 * 5]f64 = [_]f64{0} ** (5 * 5 * 5);
        imp.populate(&opt, 0.0, 0.0, 0.0, 5, 5, 5, 0.05, 0.05, 0.05, 0.03125);
        populateNaive(&imp, &refb, 0.0, 0.0, 0.0, 5, 5, 5, 0.05, 0.05, 0.05, 0.03125);
        for (opt, refb) |a, b| {
            try std.testing.expectEqual(@as(u64, @bitCast(b)), @as(u64, @bitCast(a)));
        }
        _ = alloc;
    }
}
