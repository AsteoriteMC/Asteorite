//! 1.7.10 surface builder (BiomeGenBase base path).
//!
//! Ports ahu.b: per-column top/filler replacement driven by stone noise,
//! bedrock banding, ice-vs-water freeze check. The mesa override (ail) is a
//! follow-up (no mesa in goldens; see TODO). Goldens are live JVM outputs.

const std = @import("std");
const java_random = @import("../rng/java_random.zig");
const noise = @import("noise.zig");
const biome = @import("biome.zig");

// Block ids (aji.b registry, JVM-probed).
pub const BEDROCK: u16 = 7;
pub const SAND: u16 = 12;
pub const GRAVEL: u16 = 13;
pub const SANDSTONE: u16 = 24;
pub const ICE: u16 = 79;
pub const WATER: u16 = 9;
pub const STONE: u16 = 1;
pub const AIR: u16 = 0;

/// Base-game surface tables (ids 0..39). Full 256-entry versions with
/// mutated variants live in biome.zig (TOP256/FILLER256/TEMPF256).
/// Mesa ids (37..39) carry base values here but are handled by the mesa
/// override (ail port, follow-up) — never call buildColumn with them yet.

/// getFloatTemperature static simplex (ahu.ac = awl(Random(1234), 1)).
/// World-independent; built once per surface context.
pub const TempEval = struct {
    stack: noise.SimplexOctaves,

    pub fn init(alloc: std.mem.Allocator) !TempEval {
        var r = java_random.JavaRandom.init(1234);
        return .{ .stack = try noise.SimplexOctaves.init(alloc, &r, 1) };
    }

    pub fn deinit(self: *TempEval) void {
        self.stack.deinit();
    }

    /// ahu.a(int,int,int): float temp at (x,y,z).
    pub fn tempAt(self: *const TempEval, temp: f32, x: i32, y: i32, z: i32) f32 {
        if (y > 64) {
            // NOTE: (double)x*1.0/8.0 floating division, *4.0f, all f32 at end.
            const f: f64 = self.stack.eval(@as(f64, @floatFromInt(x)) / 8.0, @as(f64, @floatFromInt(z)) / 8.0) * 4.0;
            const ff: f32 = @floatCast(f);
            return temp - (ff + @as(f32, @floatFromInt(y)) - 64.0) * 0.05 / 30.0;
        }
        return temp;
    }
};

/// One column build (ahu.b body). blocks/meta are full 65536 arrays;
/// lx,lz in 0..16; wx,wz world coords; bioId < 40 (mesa handled elsewhere).
pub fn buildColumn(
    blocks: *[65536]u16,
    meta: *[65536]u8,
    lx: usize,
    lz: usize,
    wx: i32,
    wz: i32,
    stone_noise: f64,
    rand: *java_random.JavaRandom,
    bio_id: i32,
    temp_eval: *const TempEval,
) void {
    const stride: usize = 256;
    var top: u16 = biome.TOP256[@as(usize, @intCast(bio_id))];
    var top_meta: u8 = biome.TOPMETA256[@as(usize, @intCast(bio_id))];
    var filler: u16 = biome.FILLER256[@as(usize, @intCast(bio_id))];
    var filler_depth: i32 = -1;
    // NOTE: (int) truncation toward zero, not floor.
    const depth: i32 = @intFromFloat(stone_noise / 3.0 + 3.0 + rand.nextDouble() * 0.25);
    const bio_temp = biome.TEMPF256[@as(usize, @intCast(bio_id))];
    var y: i32 = 255;
    while (y >= 0) : (y -= 1) {
        const idx = (lz * 16 + lx) * stride + @as(usize, @intCast(y));
        const r5: i32 = rand.nextIntBound(5) catch unreachable;
        if (y <= 0 + r5) {
            blocks[idx] = BEDROCK;
            continue;
        }
        const b = blocks[idx];
        // NOTE: vanilla checks block material == air; at this stage only
        // id 0 qualifies (stone/water/fill only). Documented narrowing.
        if (b == AIR) {
            filler_depth = -1;
            continue;
        }
        if (b != STONE) continue;
        if (filler_depth == -1) {
            if (depth <= 0) {
                top = AIR;
                top_meta = 0;
                filler = STONE;
            } else if (y >= 59 and y <= 64) {
                top = biome.TOP256[@as(usize, @intCast(bio_id))];
                top_meta = biome.TOPMETA256[@as(usize, @intCast(bio_id))];
                filler = biome.FILLER256[@as(usize, @intCast(bio_id))];
            }
            if (y < 63 and top == AIR) {
                if (temp_eval.tempAt(bio_temp, wx, y, wz) < 0.15) {
                    top = ICE;
                    top_meta = 0;
                } else {
                    top = WATER;
                    top_meta = 0;
                }
            }
            filler_depth = depth;
            if (y >= 62) {
                blocks[idx] = top;
                meta[idx] = top_meta;
                continue;
            }
            if (y < 56 - depth) {
                top = AIR;
                filler = STONE;
                blocks[idx] = GRAVEL;
                continue;
            }
            blocks[idx] = filler;
            continue;
        }
        if (filler_depth <= 0) continue;
        blocks[idx] = filler;
        filler_depth -= 1;
        if (filler_depth != 0 or filler != SAND) continue;
        const r4: i32 = rand.nextIntBound(4) catch unreachable;
        filler_depth = r4 + @max(0, y - 63);
        filler = SANDSTONE;
    }
}

/// Mesa plateau state (ail): band layers + 3 simplex stacks, all derived
/// from the world seed via separate Random streams (verified in CFR).
/// Shared across the 6 mesa ids (37/38/39 + mutated 165/166/167).
pub const MesaState = struct {
    layers: [64]u8,
    e_stack: noise.SimplexOctaves, // aE (4)
    f_stack: noise.SimplexOctaves, // aF (1)
    g_stack: noise.SimplexOctaves, // aG (1)

    pub fn init(alloc: std.mem.Allocator, world_seed: i64) !MesaState {
        var r1 = java_random.JavaRandom.init(world_seed);
        var g = try noise.SimplexOctaves.init(alloc, &r1, 1);
        errdefer g.deinit();
        var layers = [_]u8{16} ** 64;
        var n7: i32 = 0;
        // NOTE: for-continue runs ++n7 too; replicate exactly (skip on >= 64).
        while (n7 < 64) : (n7 += 1) {
            n7 += try r1.nextIntBound(5) + 1;
            if (n7 >= 64) continue;
            layers[@as(usize, @intCast(n7))] = 1;
        }
        var tmp: i32 = try r1.nextIntBound(4) + 2;
        var n6: i32 = 0;
        while (n6 < tmp) : (n6 += 1) {
            const n5 = try r1.nextIntBound(3) + 1;
            const n4 = try r1.nextIntBound(64);
            var n3: i32 = 0;
            while (n4 + n3 < 64 and n3 < n5) : (n3 += 1) {
                layers[@as(usize, @intCast(n4 + n3))] = 4;
            }
        }
        tmp = try r1.nextIntBound(4) + 2;
        var n5: i32 = 0;
        while (n5 < tmp) : (n5 += 1) {
            const n4 = try r1.nextIntBound(3) + 2;
            const n3 = try r1.nextIntBound(64);
            var n2: i32 = 0;
            while (n3 + n2 < 64 and n2 < n4) : (n2 += 1) {
                layers[@as(usize, @intCast(n3 + n2))] = 12;
            }
        }
        const n5b: i32 = try r1.nextIntBound(4) + 2;
        var n4b: i32 = 0;
        while (n4b < n5b) : (n4b += 1) {
            const n3 = try r1.nextIntBound(3) + 1;
            const n2 = try r1.nextIntBound(64);
            var n: i32 = 0;
            while (n2 + n < 64 and n < n3) : (n += 1) {
                layers[@as(usize, @intCast(n2 + n))] = 14;
            }
        }
        const n4c: i32 = try r1.nextIntBound(3) + 3;
        var n3c: i32 = 0;
        var n2c: i32 = 0;
        while (n2c < n4c) : (n2c += 1) {
            const n: i32 = 1;
            n3c += try r1.nextIntBound(16) + 4;
            var i: i32 = 0;
            while (n3c + i < 64 and i < n) : (i += 1) {
                layers[@as(usize, @intCast(n3c + i))] = 0;
                if (n3c + i > 1 and r1.nextBoolean()) layers[@as(usize, @intCast(n3c + i - 1))] = 8;
                if (n3c + i >= 63 or !r1.nextBoolean()) continue;
                layers[@as(usize, @intCast(n3c + i + 1))] = 8;
            }
        }
        var r2 = java_random.JavaRandom.init(world_seed);
        var e = try noise.SimplexOctaves.init(alloc, &r2, 4);
        errdefer e.deinit();
        const f = try noise.SimplexOctaves.init(alloc, &r2, 1);
        errdefer f.deinit();
        return .{ .layers = layers, .e_stack = e, .f_stack = f, .g_stack = g };
    }

    pub fn deinit(self: *MesaState) void {
        self.e_stack.deinit();
        self.f_stack.deinit();
        self.g_stack.deinit();
    }

    /// Band lookup d(wx, y, wz): index uses Y (verified in bytecode; the CFR
    /// decompile mislabels it as z). n4 from the g simplex on X only.
    fn band(self: *const MesaState, wx: i32, y: i32, wz: i32) u8 {
        _ = wz;
        const n4: i32 = @intFromFloat(@floor(self.g_stack.eval(@as(f64, @floatFromInt(wx)) / 512.0, @as(f64, @floatFromInt(wx)) / 512.0) * 2.0 + 0.5));
    // NOTE: Java Math.round(double) == (long)floor(a + 0.5), verified exact.
        const idx = @mod(y + n4 + 64, 64);
        return self.layers[@as(usize, @intCast(idx))];
    }
};

/// Mesa plateau column builder (ail.a). Bryce variant (id 165, aH) included;
/// other ids run with aH=false. Top/filler are mesa sand/stained-clay.
pub fn mesaBuildColumn(
    blocks: *[65536]u16,
    meta: *[65536]u8,
    lx: usize,
    lz: usize,
    wx: i32,
    wz: i32,
    stone_noise: f64,
    rand: *java_random.JavaRandom,
    mesa: *const MesaState,
    is_bryce: bool,
    has_forest_cap: bool,
) void {
    const stride: usize = 256;
    var d2: f64 = 0.0;
    if (is_bryce) {
        const n4: i32 = (wx & -16) + (wz & 15);
        const n3: i32 = (wz & -16) + (wx & 15);
        const d3 = @min(@abs(stone_noise), mesa.e_stack.eval(@as(f64, @floatFromInt(n4)) * 0.25, @as(f64, @floatFromInt(n3)) * 0.25));
        if (d3 > 0.0) {
            d2 = d3 * d3 * 2.5;
            const d5 = @abs(mesa.f_stack.eval(@as(f64, @floatFromInt(n4)) * 0.001953125, @as(f64, @floatFromInt(n3)) * 0.001953125));
            const d6 = @ceil(d5 * 50.0) + 14.0;
            if (d2 > d6) d2 = d6;
            d2 += 64.0;
        }
    }
    var top: u16 = 12;
    var top_meta: u8 = 1;
    var filler: u16 = 159;
    var filler_depth: i32 = -1;
    // NOTE: method-scoped in vanilla (set in the surface block, read by
    // later subsurface rows of the same column).
    var bl2 = false;
    const depth: i32 = @intFromFloat(stone_noise / 3.0 + 3.0 + rand.nextDouble() * 0.25);
    const bl: bool = @cos(stone_noise / 3.0 * std.math.pi) > 0.0;
    var y: i32 = 255;
    while (y >= 0) : (y -= 1) {
        const idx = (lz * 16 + lx) * stride + @as(usize, @intCast(y));
        if (blocks[idx] == 0 and @as(f64, @floatFromInt(y)) < d2) blocks[idx] = STONE;
        const r5: i32 = rand.nextIntBound(5) catch unreachable;
        if (y <= 0 + r5) {
            blocks[idx] = BEDROCK;
            continue;
        }
        const b = blocks[idx];
        if (b == AIR) {
            filler_depth = -1;
            continue;
        }
        if (b != STONE) continue;
        if (filler_depth == -1) {
            bl2 = false;
            if (depth <= 0) {
                top = AIR;
                top_meta = 0;
                filler = STONE;
            } else if (y >= 59 and y <= 64) {
                top = 159;
                filler = 159;
            }
            if (y < 63 and top == AIR) {
                top = WATER;
                top_meta = 0;
            }
            filler_depth = depth + @max(0, y - 63);
            if (y >= 62) {
                if (has_forest_cap and y > 86 + depth * 2) {
                    if (bl) {
                        blocks[idx] = 3;
                        meta[idx] = 1;
                    } else {
                        blocks[idx] = 2;
                    }
                    continue;
                }
                if (y > 66 + depth) {
                    var n9: u8 = 16;
                    if (y < 64 or y > 127) {
                        n9 = 1;
                    } else if (!bl) {
                        n9 = mesa.band(wx, y, wz);
                    }
                    if (n9 < 16) {
                        blocks[idx] = 159;
                        meta[idx] = n9;
                    } else {
                        blocks[idx] = 172;
                    }
                    continue;
                }
                blocks[idx] = top;
                meta[idx] = top_meta;
                bl2 = true;
                continue;
            }
            blocks[idx] = filler;
            if (filler != 159) continue;
            meta[idx] = 1;
            continue;
        }
        if (filler_depth <= 0) continue;
        filler_depth -= 1;
        if (bl2) {
            blocks[idx] = 159;
            meta[idx] = 1;
            continue;
        }
        const n9 = mesa.band(wx, y, wz);
        if (n9 < 16) {
            blocks[idx] = 159;
            meta[idx] = n9;
        } else {
            blocks[idx] = 172;
        }
    }
}

/// Mesa-class biome ids (ail + mutated variants, BiomeAll2/Class probe).
pub fn isMesa(id: i32) bool {
    return id == 37 or id == 38 or id == 39 or id == 165 or id == 166 or id == 167;
}
