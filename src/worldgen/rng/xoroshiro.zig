//! Xoroshiro128++ (Vigna, public-domain algorithm) + Minecraft's
//! XoroshiroRandom seeding (SeedMixer / Stafford Mix13), for 1.18+ worldgen.
//!
//! The generator core is cross-checked against an independent Python
//! implementation of the published algorithm (see test goldens). The
//! seed-mixing constants are from Mojang's documented XoroshiroRandom:
//!   seedLo = mix(seed ^ 0x6A09E667F3BCC909)
//!   seedHi = mix(seed ^ 0xBF58476D1CE4E5B9)
//! with mix = Stafford13. Full JVM/Minecraft-output verification is an H4
//! gate (no modern generator consumes this yet); only the core + fork are
//! API-stable. nextInt(bound)/float/double stay out until H4 needs them.

const std = @import("std");

fn rotl(x: u64, k: u6) u64 {
    if (k == 0) return x;
    const r: u6 = @intCast(64 - @as(u7, k));
    return (x << k) | (x >> r);
}

/// Stafford Mix13 (Mojang SeedMixer.mixSeed).
fn mixSeed(z0: u64) u64 {
    var z = (z0 ^ (z0 >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

pub const Xoroshiro = struct {
    s0: u64,
    s1: u64,

    /// Minecraft XoroshiroRandom(long seed) seeding (no argentum cycle).
    pub fn init(seed: i64) Xoroshiro {
        const u: u64 = @bitCast(seed);
        return .{
            .s0 = mixSeed(u ^ 0x6A09E667F3BCC909),
            .s1 = mixSeed(u ^ 0xBF58476D1CE4E5B9),
        };
    }

    /// Raw mixed pair (no mixing applied — for fork()).
    fn initRaw(s0: u64, s1: u64) Xoroshiro {
        return .{ .s0 = s0, .s1 = s1 };
    }

    pub fn next(self: *Xoroshiro) u64 {
        const s0 = self.s0;
        var s1 = self.s1;
        const result = rotl(s0 +% s1, 17) +% s0;
        s1 ^= s0;
        self.s0 = rotl(s0, 49) ^ s1 ^ (s1 << 21);
        self.s1 = rotl(s1, 28);
        return result;
    }

    pub fn nextLong(self: *Xoroshiro) i64 {
        return @bitCast(self.next());
    }

    /// Mojang XoroshiroRandom.nextInt(): low 32 bits. H4 must re-verify
    /// against real modern-worldgen call sites before relying on it.
    pub fn nextInt(self: *Xoroshiro) i32 {
        return @truncate(@as(i64, @bitCast(self.next())));
    }

    /// Mojang fork(): child seeded from two parent draws, no re-mixing.
    pub fn fork(self: *Xoroshiro) Xoroshiro {
        return initRaw(@bitCast(self.nextLong()), @bitCast(self.nextLong()));
    }
};

// ---------------------------------------------------------------------------
// Goldens: independent Python implementation of the published algorithm.

test "mixer goldens" {
    const cases = [_]struct { seed: i64, s0: u64, s1: u64 }{
        .{ .seed = 0, .s0 = 3847398142028685078, .s1 = 17509614380081456743 },
        .{ .seed = 1, .s0 = 5272463233947570727, .s1 = 2117524031394773289 },
        .{ .seed = 42, .s0 = 6720814022939733433, .s1 = 4192285375657574531 },
        .{ .seed = -1, .s0 = 18335960242316818308, .s1 = 11784004853807849751 },
    };
    for (cases) |c| {
        const x = Xoroshiro.init(c.seed);
        try std.testing.expectEqual(c.s0, x.s0);
        try std.testing.expectEqual(c.s1, x.s1);
    }
}

test "stream goldens" {
    const cases = [_]struct { seed: i64, o0: u64, o1: u64, o2: u64 }{
        .{ .seed = 0, .o0 = 16779510738079739868, .o1 = 10052499415512334166, .o2 = 18296739675142584603 },
        .{ .seed = 1, .o0 = 5598739770816683844, .o1 = 10169999839911350393, .o2 = 5427966728054982703 },
        .{ .seed = 42, .o0 = 11056223383237860511, .o1 = 12894389268673419581, .o2 = 5928556597548362567 },
        .{ .seed = -1, .o0 = 4021360471410080643, .o1 = 14684621052735067399, .o2 = 234155006340105291 },
    };
    for (cases) |c| {
        var x = Xoroshiro.init(c.seed);
        try std.testing.expectEqual(c.o0, x.next());
        try std.testing.expectEqual(c.o1, x.next());
        try std.testing.expectEqual(c.o2, x.next());
    }
}

test "fork is deterministic and diverges" {
    var a = Xoroshiro.init(99);
    var b = Xoroshiro.init(99);
    var fa = a.fork();
    var fb = b.fork();
    try std.testing.expectEqual(fa.next(), fb.next());
    // child stream differs from parent continuation
    try std.testing.expect(a.next() != fa.next());
}
