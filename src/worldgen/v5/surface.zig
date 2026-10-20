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
