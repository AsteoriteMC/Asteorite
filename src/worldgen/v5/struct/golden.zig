//! Structure golden tests: Java-generated (real 1.7.10 code via FakeWorld)
//! vs the Zig ports. Golden files live in testdata/ as `##` headers plus
//! `SET x y z wireId meta` lines (in call order), `SPAWN kind ...`,
//! a `## randstate` line (populate rand after placement), and `## found`
//! lines (starts detected for the populate chunk).

const std = @import("std");
const ids = @import("../../../ids.zig");
const wire = @import("../../../proto/v5/wire_ids.zig");
const java_random = @import("../../rng/java_random.zig");
const gen_mod = @import("../gen.zig");
const mapgen_mod = @import("mapgen.zig");
const placer_mod = @import("placer.zig");
const scattered_mod = @import("scattered.zig");
const testplacer_mod = @import("testplacer.zig");

pub const BioCtx = mapgen_mod.BioCtx;

/// genlayer-backed BioCtx for goldens (real chain, JVM-verified).
pub const ChainBio = struct {
    gen: *gen_mod.Gen,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, seed: i64) !ChainBio {
        const g = try alloc.create(gen_mod.Gen);
        g.* = try gen_mod.Gen.init(alloc, seed, false, false);
        return .{ .gen = g, .alloc = alloc };
    }

    pub fn bio(self: *ChainBio) BioCtx {
        const VTable = struct {
            fn voronoi(ptr: *anyopaque, alloc: std.mem.Allocator, x: i32, z: i32) i32 {
                const cb: *ChainBio = @ptrCast(@alignCast(ptr));
                var out = [_]i32{0};
                cb.gen.shaper.chain.getInts(alloc, cb.gen.shaper.roots[1], x, z, 1, 1, &out) catch return -1;
                return out[0];
            }
            fn layer(ptr: *anyopaque, alloc: std.mem.Allocator, x: i32, z: i32, w: usize, h: usize, out: []i32) void {
                const cb: *ChainBio = @ptrCast(@alignCast(ptr));
                cb.gen.shaper.chain.getInts(alloc, cb.gen.shaper.roots[0], x, z, w, h, out) catch {
                    for (out) |*v| v.* = 0;
                };
            }
            const table = BioCtx.VTable{ .voronoiAt = voronoi, .layer4 = layer };
        };
        return .{ .ptr = self, .vtable = &VTable.table };
    }
};

/// Seed a populate rand exactly like vanilla populate (`aqz.a` mixing).
pub fn seedPopulate(rand: *java_random.JavaRandom, world_seed: i64, cx: i32, cz: i32) void {
    rand.setSeed(world_seed);
    const l: i64 = @divTrunc(rand.nextLong(), 2) * 2 + 1;
    const l1: i64 = @divTrunc(rand.nextLong(), 2) * 2 + 1;
    rand.setSeed(cx *% l +% cz *% l1 ^ world_seed);
}

/// Seed a position rand exactly like `aqx.generate` per start-chunk
/// (includes the unconditional nextInt the detector consumes).
pub fn seedPosition(rand: *java_random.JavaRandom, world_seed: i64, sx: i32, sz: i32) void {
    mapgen_mod.positionRand(rand, world_seed, sx, sz);
    _ = rand.nextInt();
}

const Rec = testplacer_mod.Rec;

const Golden = struct {
    seed: i64 = 0,
    family: []const u8 = "",
    cx: i32 = 0,
    cz: i32 = 0,
    found: [16]struct { sx: i32, sz: i32, biome: i32 } = undefined,
    nfound: usize = 0,
    randstate: i32 = 0,
    spawns_v: usize = 0,
    spawns_w: usize = 0,
    sets: std.ArrayList(Rec) = .empty,
};

fn parseGolden(text: []const u8, alloc: std.mem.Allocator) !Golden {
    var r = Golden{ .sets = .empty };
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        var tok = std.mem.tokenizeAny(u8, line, " \t\r");
        const head = tok.next() orelse continue;
        if (std.mem.eql(u8, head, "##")) {
            const k = tok.next() orelse continue;
            if (std.mem.eql(u8, k, "seed")) r.seed = try std.fmt.parseInt(i64, tok.next() orelse "0", 10);
            if (std.mem.eql(u8, k, "family")) r.family = tok.next() orelse "";
            if (std.mem.eql(u8, k, "chunk")) {
                r.cx = try std.fmt.parseInt(i32, tok.next() orelse "0", 10);
                r.cz = try std.fmt.parseInt(i32, tok.next() orelse "0", 10);
            }
            if (std.mem.eql(u8, k, "found")) {
                const sx = try std.fmt.parseInt(i32, tok.next() orelse "0", 10);
                const sz = try std.fmt.parseInt(i32, tok.next() orelse "0", 10);
                const b = try std.fmt.parseInt(i32, tok.next() orelse "-1", 10);
                r.found[r.nfound] = .{ .sx = sx, .sz = sz, .biome = b };
                r.nfound += 1;
            }
            if (std.mem.eql(u8, k, "randstate")) r.randstate = try std.fmt.parseInt(i32, tok.next() orelse "0", 10);
            if (std.mem.eql(u8, k, "spawns")) {
                r.spawns_v = try std.fmt.parseInt(usize, tok.next() orelse "0", 10);
                r.spawns_w = try std.fmt.parseInt(usize, tok.next() orelse "0", 10);
            }
        } else if (std.mem.eql(u8, head, "SET")) {
            const x = try std.fmt.parseInt(i32, tok.next() orelse "0", 10);
            const y = try std.fmt.parseInt(i32, tok.next() orelse "0", 10);
            const z = try std.fmt.parseInt(i32, tok.next() orelse "0", 10);
            const id = try std.fmt.parseInt(u16, tok.next() orelse "0", 10);
            const m = try std.fmt.parseInt(u8, tok.next() orelse "0", 10);
            try r.sets.append(alloc, .{ .x = x, .y = y, .z = z, .wire = id, .meta = @truncate(m) });
        }
    }
    return r;
}

fn checkWrites(got: []const Rec, want: []const Rec) !void {
    if (want.len != got.len) {
        std.debug.print("LEN want={d} got={d}\n", .{ want.len, got.len });
        const m = @min(want.len, got.len);
        var i: usize = 0;
        while (i < m) : (i += 1) {
            if (want[i].x != got[i].x or want[i].y != got[i].y or want[i].z != got[i].z or want[i].wire != got[i].wire or want[i].meta != got[i].meta) {
                std.debug.print("first diff at {d}: want {any} got {any}\n", .{ i, want[i], got[i] });
                break;
            }
        }
        if (want.len > m) std.debug.print("extra want tail: {any}\n", .{want[m..@min(m+10, want.len)]});
        if (got.len > m) std.debug.print("extra got tail: {any}\n", .{got[m..@min(m+10, got.len)]});
    }
    try std.testing.expectEqual(want.len, got.len);
    for (want, got, 0..) |w, g, i| {
        errdefer std.debug.print("mismatch at write {d}: want {any} got {any}\n", .{ i, w, g });
        try std.testing.expectEqual(w.x, g.x);
        try std.testing.expectEqual(w.y, g.y);
        try std.testing.expectEqual(w.z, g.z);
        try std.testing.expectEqual(w.wire, g.wire);
        try std.testing.expectEqual(w.meta, g.meta);
    }
}

const witch_txt = @embedFile("testdata/witch_12345_m27_48.txt");
const desert_a_txt = @embedFile("testdata/desert_12345_m74_75.txt");
const desert_b_txt = @embedFile("testdata/desert_12345_m75_75.txt");
const desert_c_txt = @embedFile("testdata/desert_12345_m74_76.txt");
const desert_d_txt = @embedFile("testdata/desert_12345_m75_76.txt");
const jungle_txt = @embedFile("testdata/jungle_1_46_3.txt");

fn runScatteredGolden(txt: []const u8) !void {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var gold = try parseGolden(txt, alloc);
    defer gold.sets.deinit(alloc);
    try std.testing.expectEqualStrings("scattered", gold.family);
    try std.testing.expect(gold.nfound >= 1);

    var tw = testplacer_mod.TestWorld.init(alloc);
    defer tw.deinit();
    const clip = mapgen_mod.populateBox(gold.cx, gold.cz);
    // Flat preload covering clip + margin (ground leveling + liquid reads).
    try tw.preloadFlat(clip.min_x - 16, clip.min_z - 16, clip.max_x + 16, clip.max_z + 16);

    var cbio = try ChainBio.init(arena.allocator(), gold.seed);
    const bio = cbio.bio();
    var found = [_]struct { sx: i32, sz: i32 }{undefined} ** 16;
    var nfound: usize = 0;
    var sx: i32 = gold.cx - 8;
    while (sx <= gold.cx + 8) : (sx += 1) {
        var sz: i32 = gold.cz - 8;
        while (sz <= gold.cz + 8) : (sz += 1) {
            var pos = java_random.JavaRandom.init(0);
            seedPosition(&pos, gold.seed, sx, sz);
            if (scattered_mod.canSpawn(bio, arena.allocator(), gold.seed, sx, sz)) {
                found[nfound] = .{ .sx = sx, .sz = sz };
                nfound += 1;
            }
        }
    }
    try std.testing.expectEqual(gold.nfound, nfound);
    for (gold.found[0..gold.nfound], 0..) |f, i| {
        try std.testing.expectEqual(f.sx, found[i].sx);
        try std.testing.expectEqual(f.sz, found[i].sz);
    }

    var pop = java_random.JavaRandom.init(0);
    seedPopulate(&pop, gold.seed, gold.cx, gold.cz);
    const p = tw.placer();
    var generated = false;
    for (found[0..nfound], 0..) |st, i| {
        var bpos = java_random.JavaRandom.init(0);
        seedPosition(&bpos, gold.seed, st.sx, st.sz);
        if (scattered_mod.generate(p, gold.found[i].biome, st.sx, st.sz, &bpos, &pop, clip)) generated = true;
    }
    try std.testing.expect(generated);
    try checkWrites(tw.writes.items, gold.sets.items);
    try std.testing.expectEqual(gold.spawns_v, tw.villagers);
    try std.testing.expectEqual(gold.spawns_w, tw.witches);
    try std.testing.expectEqual(gold.randstate, try pop.nextIntBound(1000000));
}

test "witch hut identical to vanilla (seed 12345, start -26,49 -> chunk -27,48)" {
    try runScatteredGolden(witch_txt);
}

test "desert pyramid identical to vanilla (4 populate chunks)" {
    try runScatteredGolden(desert_a_txt);
}

test "desert pyramid neighbor chunk (-75,-75)" {
    try runScatteredGolden(desert_b_txt);
}

test "desert pyramid neighbor chunk (-74,-76)" {
    try runScatteredGolden(desert_c_txt);
}

test "desert pyramid neighbor chunk (-75,-76)" {
    try runScatteredGolden(desert_d_txt);
}

test "jungle pyramid identical to vanilla (seed 1, 46,3)" {
    try runScatteredGolden(jungle_txt);
}
