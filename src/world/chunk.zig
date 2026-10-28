//! Versioned chunk payload (ZC1) — the ONLY runtime chunk encoding.
//! Stored as the LSM value under key [dim|x|z] (see store.zig).
//!
//! Layout (big-endian):
//!   magic "ZC1" (3B) + version u8 (=2; v1 stored wire ids, v2+ stores
//!   canonical ids.Id values)
//!   dim u8, x i32, z i32                      (9B, mirrors key)
//!   section_mask u16                           (bit i => section i present)
//!   per present section, ascending:
//!     blocks 4096 x u16 BE (full id 0..4095, YZX order)
//!     meta   2048B nibbles, add 2048B nibbles, sky 2048B, light 2048B
//!   biomes 256B, heights 256B (u8, clamped)
//!
//! YZX order: idx = (y*16 + z)*16 + x, xyz local 0..15. Matches Anvil.

const std = @import("std");
const nbt = @import("nbt.zig");
const ids = @import("../ids.zig");

pub const version: u8 = 2;
pub const magic = "ZC1";
pub const section_size = 4096;
pub const nibble_size = 2048;
pub const section_bytes = section_size * 2 + nibble_size * 4; // 16384
/// Header bytes: magic(3) + version(1) + dim(1) + x(4) + z(4) + mask(2).
pub const header_len: usize = 3 + 1 + 9 + 2;
/// Tail bytes: biomes(256) + heights(256).
pub const tail_len: usize = 512;

/// Vanilla light opacity (`aji.k()`, jar-verified over all 175 block ids):
/// water/ice k=3, leaves k=1, air + flora + snow layer + glass + lava k=0,
/// everything else 255. Single source of truth — worldgen and relight
/// share this (previously duplicated in worldgen/v5/gen.zig).
pub fn lightOpacity(id: ids.Id) u8 {
    return switch (id) {
        .leaves, .leaves2 => 1,
        .water, .flowing_water, .ice => 3,
        .air,
        .sapling,
        .lava,
        .flowing_lava,
        .glass,
        .tallgrass,
        .deadbush,
        .yellow_flower,
        .red_flower,
        .brown_mushroom,
        .red_mushroom,
        .snow_layer,
        .cactus,
        .reeds_block,
        .vine,
        .waterlily,
        .stained_glass,
        .glass_pane,
        .stained_glass_pane,
        .torch,
        .ladder,
        .rail,
        .golden_rail,
        .detector_rail,
        .activator_rail,
        .standing_sign,
        .wall_sign,
        .lever,
        .stone_pressure_plate,
        .wooden_pressure_plate,
        .light_weighted_pressure_plate,
        .heavy_weighted_pressure_plate,
        .unlit_redstone_torch,
        .redstone_torch,
        .stone_button,
        .wooden_button,
        .snow,
        .carpet,
        .flower_pot_block,
        .skull_block,
        .tripwire,
        .tripwire_hook,
        => 0,
        else => 255,
    };
}

/// Block-light emission (`aji.l`, vanilla values for the blocks we can
/// store): lava 15, torch/glowstone/jack-o-lantern 14/15, lit furnace 13,
/// lit redstone/lapis-ish 9/7. Everything else 0.
pub fn emitLight(id: ids.Id) u4 {
    return switch (id) {
        .lava, .flowing_lava, .fire, .glowstone, .lit_pumpkin, .lit_redstone_lamp => 15,
        .torch => 14,
        .lit_furnace => 13,
        .lit_redstone_ore => 9,
        .redstone_torch => 7,
        else => 0,
    };
}

pub const ChunkError = error{
    BadMagic,
    UnsupportedVersion,
    Truncated,
    BlockIdRange,
    InvalidMask,
    OutOfMemory,
} || nbt.NbtError || std.mem.Allocator.Error;

pub const Section = struct {
    blocks: [section_size]ids.Id = [_]ids.Id{ids.air} ** section_size,
    meta: [nibble_size]u8 = [_]u8{0} ** nibble_size,
    add: [nibble_size]u8 = [_]u8{0} ** nibble_size,
    sky: [nibble_size]u8 = [_]u8{0xFF} ** nibble_size,
    light: [nibble_size]u8 = [_]u8{0} ** nibble_size,

    pub inline fn index(x: u4, y: u4, z: u4) usize {
        return (@as(usize, y) * 16 + @as(usize, z)) * 16 + @as(usize, x);
    }

    pub fn getBlock(self: *const Section, x: u4, y: u4, z: u4) ids.Id {
        return self.blocks[index(x, y, z)];
    }

    pub fn setBlock(self: *Section, x: u4, y: u4, z: u4, id: ids.Id) void {
        const i = index(x, y, z);
        self.blocks[i] = id;
    }

    pub fn getNibble(arr: *const [nibble_size]u8, i: usize) u4 {
        const b = arr[i >> 1];
        return if (i & 1 == 0) @truncate(b & 0x0F) else @truncate(b >> 4);
    }

    pub fn setNibble(arr: *[nibble_size]u8, i: usize, v: u4) void {
        const b = &arr[i >> 1];
        if (i & 1 == 0) {
            b.* = (b.* & 0xF0) | v;
        } else {
            b.* = (b.* & 0x0F) | (@as(u8, v) << 4);
        }
    }
};

/// Heap-allocated chunk (full 16-section inline storage is ~264KB — never on stack).
pub const Chunk = struct {
    dim: u8,
    x: i32,
    z: i32,
    sections: [16]?Section = [_]?Section{null} ** 16,
    biomes: [256]u8 = [_]u8{0} ** 256,
    heights: [256]u8 = [_]u8{0} ** 256,

    pub fn createEmpty(allocator: std.mem.Allocator, dim: u8, x: i32, z: i32) !*Chunk {
        const c = try allocator.create(Chunk);
        c.* = .{ .dim = dim, .x = x, .z = z };
        return c;
    }

    pub fn destroy(self: *Chunk, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    pub fn mask(self: *const Chunk) u16 {
        var m: u16 = 0;
        for (self.sections, 0..) |s, i| {
            if (s != null) m |= @as(u16, 1) << @intCast(i);
        }
        return m;
    }

    /// Block at local (lx 0..15, y 0..255, lz 0..15); missing sections
    /// are air.
    pub fn blockAt(self: *const Chunk, lx: usize, y: usize, lz: usize) ids.Id {
        const s = self.sections[y >> 4] orelse return .air;
        return s.blocks[Section.index(@intCast(lx), @intCast(y & 15), @intCast(lz))];
    }

    fn setSkyAt(self: *Chunk, lx: usize, y: usize, lz: usize, v: u4) void {
        const s = &(self.sections[y >> 4] orelse return);
        Section.setNibble(&s.sky, Section.index(@intCast(lx), @intCast(y & 15), @intCast(lz)), v);
    }

    pub fn getLightAt(self: *const Chunk, lx: usize, y: usize, lz: usize) u4 {
        const s = self.sections[y >> 4] orelse return 0;
        return Section.getNibble(&s.light, Section.index(@intCast(lx), @intCast(y & 15), @intCast(lz)));
    }

    fn setLightAt(self: *Chunk, lx: usize, y: usize, lz: usize, v: u4) void {
        const s = &(self.sections[y >> 4] orelse return);
        Section.setNibble(&s.light, Section.index(@intCast(lx), @intCast(y & 15), @intCast(lz)), v);
    }

    /// Light channels for the BFS engine below.
    pub const LightChannel = enum { sky, block };

    /// Packed cell coords for light queues (17 bits; matches relightBlock).
    pub const Cell = struct { x: usize, y: usize, z: usize };

    pub inline fn packCell(x: usize, y: usize, z: usize) u32 {
        return @intCast((y * 16 + z) * 16 + x);
    }

    pub inline fn unpackCell(cell: u32) Cell {
        return .{ .x = cell & 15, .z = (cell >> 4) & 15, .y = cell >> 8 };
    }

    /// A cell pinned to a value (phase-A old values, reflood rewrite floors).
    pub const CellValue = struct { cell: u32, value: u4 };

    /// Phase-A queue entries pack the flow-through (old) value alongside
    /// the cell: entry = old:4 @ [17:21] | cell @ [0:17].
    inline fn packOld(cell: u32, old: u4) u32 {
        return (@as(u32, old) << 17) | cell;
    }

    inline fn unpackOld(e: u32) struct { cell: u32, old: u4 } {
        return .{ .cell = e & 0x1FFFF, .old = @truncate(e >> 17) };
    }

    fn getSkyAt(self: *const Chunk, lx: usize, y: usize, lz: usize) u4 {
        const s = self.sections[y >> 4] orelse return 0;
        return Section.getNibble(&s.sky, Section.index(@intCast(lx), @intCast(y & 15), @intCast(lz)));
    }

    fn getChannelAt(self: *const Chunk, ch: LightChannel, lx: usize, y: usize, lz: usize) u4 {
        return switch (ch) {
            .sky => self.getSkyAt(lx, y, lz),
            .block => self.getLightAt(lx, y, lz),
        };
    }

    fn setChannelAt(self: *Chunk, ch: LightChannel, lx: usize, y: usize, lz: usize, v: u4) void {
        switch (ch) {
            .sky => self.setSkyAt(lx, y, lz, v),
            .block => self.setLightAt(lx, y, lz, v),
        }
    }

    /// Attenuation entering a cell of opacity `op`, or null when fully
    /// blocked. Sky floors at 1 per step (so a stored 15 always means
    /// column-ruled: sideways spread can never mint one — the fact phase
    /// A relies on to never zero open-sky cells). Block keeps the
    /// established op>=3?2:1 rule.
    pub fn skyCost(op: u8) ?u4 {
        if (op == 255) return null;
        return @intCast(@max(@as(u8, 1), @min(op, 15)));
    }

    pub fn blockCost(op: u8) ?u4 {
        if (op == 255) return null;
        return if (op >= 3) 2 else 1;
    }

    fn spreadCost(channel: LightChannel, op: u8) ?u4 {
        return switch (channel) {
            .sky => skyCost(op),
            .block => blockCost(op),
        };
    }

    /// A cell that sustains its own value (never zeroed in phase A, always
    /// a valid reflood source): block emitters, and sky cells at 15 (only
    /// the column rule mints those — see spreadCost).
    fn isSourceCell(self: *const Chunk, channel: LightChannel, lx: usize, y: usize, lz: usize, v: u4) bool {
        return switch (channel) {
            .sky => v == 15,
            .block => emitLight(self.blockAt(lx, y, lz)) > 0,
        };
    }

    /// 6-neighbor offsets (shared by the chunk BFS, the gen-grid flood,
    /// and the edit-path relight — one table, no drift).
    pub const light_dirs = [_][3]i32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };

    /// Block-local coordinate (0..15) via two's-complement wrap
    /// (vanilla `x & 15`, exact for negatives).
    pub fn localCoord(v: i32) u4 {
        return @truncate(@as(u32, @bitCast(v & 15)));
    }

    /// True when the neighbor offset lands inside the chunk.
    inline fn inBounds(nx: i32, ny: i32, nz: i32) bool {
        return nx >= 0 and nx <= 15 and ny >= 0 and ny <= 255 and nz >= 0 and nz <= 15;
    }

    /// Raise-BFS core: propagate increases until the fixed point. Only
    /// strict increases enqueue, values cap at 15, so this terminates.
    /// Intra-chunk only (documented seam: neighbors resend with their own
    /// flood; ~1-level error at borders, same as relightBlock).
    fn bfsRaise(self: *Chunk, channel: LightChannel, queue: []u32, head: *usize, tail: *usize) void {
        while (head.* < tail.*) {
            const c = unpackCell(queue[head.*]);
            head.* += 1;
            const cur = self.getChannelAt(channel, c.x, c.y, c.z);
            if (cur == 0) continue;
            // Sky never spreads FROM opaque cells (their stored 15 is the
            // top-face value, not a source: without this, roof undersides
            // leak 14 downward everywhere and nothing under a roof ever
            // goes dark). Block light has no such restriction (opaque
            // emitters like lit furnaces must radiate).
            if (channel == .sky and lightOpacity(self.blockAt(c.x, c.y, c.z)) == 255) continue;
            for (light_dirs) |d| {
                const nx = @as(i32, @intCast(c.x)) + d[0];
                const ny = @as(i32, @intCast(c.y)) + d[1];
                const nz = @as(i32, @intCast(c.z)) + d[2];
                if (!inBounds(nx, ny, nz)) continue;
                const ux: usize = @intCast(nx);
                const uy: usize = @intCast(ny);
                const uz: usize = @intCast(nz);
                const cost = spreadCost(channel, lightOpacity(self.blockAt(ux, uy, uz))) orelse continue;
                if (cur <= cost) continue;
                const nl: u4 = cur - cost;
                if (nl <= self.getChannelAt(channel, ux, uy, uz)) continue;
                if (self.sections[uy >> 4] == null) continue; // don't inflate the mask
                self.setChannelAt(channel, ux, uy, uz, nl);
                if (tail.* < queue.len) {
                    queue[tail.*] = packCell(ux, uy, uz);
                    tail.* += 1;
                }
            }
        }
    }

    /// Raise pass: propagate increases from seeds holding final values.
    /// Seeds at 0/1 spread nothing (min cost is 1) but are harmless.
    pub fn spreadLight(self: *Chunk, queue: []u32, channel: LightChannel, seeds: []const u32) void {
        var tail: usize = 0;
        for (seeds) |cell| {
            if (tail >= queue.len) break;
            queue[tail] = cell;
            tail += 1;
        }
        var head: usize = 0;
        self.bfsRaise(channel, queue, &head, &tail);
    }

    /// Bounding box over light seeds (expanded ±1 at rescan).
    const Bbox = struct {
        minx: usize = 16,
        maxx: usize = 0,
        miny: usize = 256,
        maxy: usize = 0,
        minz: usize = 16,
        maxz: usize = 0,

        fn expand(self: *Bbox, c: Cell) void {
            self.minx = @min(self.minx, c.x);
            self.maxx = @max(self.maxx, c.x);
            self.miny = @min(self.miny, c.y);
            self.maxy = @max(self.maxy, c.y);
            self.minz = @min(self.minz, c.z);
            self.maxz = @max(self.maxz, c.z);
        }

        fn grow(self: *Bbox, x: usize, y: usize, z: usize) void {
            self.minx = @min(self.minx, x);
            self.maxx = @max(self.maxx, x);
            self.miny = @min(self.miny, y);
            self.maxy = @max(self.maxy, y);
            self.minz = @min(self.minz, z);
            self.maxz = @max(self.maxz, z);
        }

        /// Empty when no seed was ever expanded in (no-op decrease).
        fn isEmpty(self: *const Bbox) bool {
            return self.maxx < self.minx;
        }
    };

    /// Seed the reflood queue from every lit cell in bbox±1.
    fn seedBbox(self: *Chunk, queue: []u32, channel: LightChannel, box: *const Bbox) usize {
        var rtail: usize = 0;
        var y = box.miny -| 1;
        const y1 = @min(box.maxy + 1, 255);
        while (y <= y1) : (y += 1) {
            var z = box.minz -| 1;
            const z1 = @min(box.maxz + 1, 15);
            while (z <= z1) : (z += 1) {
                var x = box.minx -| 1;
                const x1 = @min(box.maxx + 1, 15);
                while (x <= x1) : (x += 1) {
                    if (self.getChannelAt(channel, x, y, z) == 0) continue;
                    if (rtail >= queue.len) return rtail;
                    queue[rtail] = packCell(x, y, z);
                    rtail += 1;
                }
            }
        }
        return rtail;
    }

    /// Full-chunk skylight spread (gen path): the columns already hold
    /// exact vertical values (relightColumn); every bright cell seeds the
    /// horizontal flood. Block light keeps its own full flood
    /// (relightBlock seeds emissives directly).
    pub fn spreadSky(self: *Chunk, queue: []u32) void {
        var tail: usize = 0;
        // Linear scan (flattened): one pass over all 64K cells.
        var i: usize = 0;
        while (i < 65536) : (i += 1) {
            if (tail >= queue.len) break;
            const c = unpackCell(@intCast(i));
            if (self.getSkyAt(c.x, c.y, c.z) > 1) {
                queue[tail] = @intCast(i);
                tail += 1;
            }
        }
        var head: usize = 0;
        self.bfsRaise(.sky, queue, &head, &tail);
    }

    /// Two-phase decrease (edit path): invalidate cells plausibly lit
    /// through `old_seeds` (which carry pre-change values), then reflood
    /// from survivors + `rewrite` floors. `rewrite` cells hold final
    /// values (column-rule cells / new emission): restored if phase A
    /// zeroed them, then seeded into the reflood.
    ///
    /// Correctness: phase A only zeroes cells strictly dimmer than the
    /// value light flowed through (self-sustained cells immune), so every
    /// zeroed cell genuinely depended on a changed path; the reflood
    /// rescan covers bbox±1, which contains every neighbor of every
    /// zeroed cell, plus the explicit rewrite seeds — so every cell whose
    /// true final value exceeds its post-phase-A value is reachable from
    /// a seed, and raise-BFS computes the exact fixed point. Typical
    /// edits touch tens of cells (never the full re-flood per edit);
    /// pathological cases degrade toward chunk-scale work, still correct.
    pub fn unspreadLight(self: *Chunk, queue: []u32, channel: LightChannel, old_seeds: []const CellValue, rewrite: []const CellValue) void {
        var head: usize = 0;
        var tail: usize = 0;
        var box = Bbox{};
        // Seeds are processed inline (not queued): each cell zeroes at
        // most once, so the cascade queue can never overflow 64K.
        for (old_seeds) |s| {
            const c = unpackCell(s.cell);
            box.expand(c);
            self.invalidateAround(channel, c.x, c.y, c.z, s.value, queue, &tail, &box);
        }
        for (rewrite) |s| box.expand(unpackCell(s.cell));
        while (head < tail) {
            const e = unpackOld(queue[head]);
            head += 1;
            const c = unpackCell(e.cell);
            self.invalidateAround(channel, c.x, c.y, c.z, e.old, queue, &tail, &box);
        }
        // Rewrite floors (restores anything phase A zeroed), then reflood
        // from the bbox shell: every value>0 cell in bbox±1, which covers
        // all neighbors of all zeroed cells.
        for (rewrite) |s| {
            const c = unpackCell(s.cell);
            self.setChannelAt(channel, c.x, c.y, c.z, s.value);
        }
        // Empty seed set (no-op decrease): bbox stayed inverted.
        if (box.isEmpty()) return;
        const rtail = self.seedBbox(queue, channel, &box);
        var rhead: usize = 0;
        var tail2: usize = rtail;
        self.bfsRaise(channel, queue, &rhead, &tail2);
    }

    /// Phase-A step: examine the 6 neighbors of (x,y,z) against the value
    /// `flowed` that light traveled with; zero plausibly-dependent cells
    /// (enqueueing them with their old values) and grow the bbox.
    fn invalidateAround(self: *Chunk, channel: LightChannel, x: usize, y: usize, z: usize, flowed: u4, queue: []u32, tail: *usize, box: *Bbox) void {
        for (light_dirs) |d| {
            const nx = @as(i32, @intCast(x)) + d[0];
            const ny = @as(i32, @intCast(y)) + d[1];
            const nz = @as(i32, @intCast(z)) + d[2];
            if (!inBounds(nx, ny, nz)) continue;
            const ux: usize = @intCast(nx);
            const uy: usize = @intCast(ny);
            const uz: usize = @intCast(nz);
            const vn = self.getChannelAt(channel, ux, uy, uz);
            if (self.isSourceCell(channel, ux, uy, uz, vn)) continue;
            if (vn == 0 or vn >= flowed) continue;
            self.setChannelAt(channel, ux, uy, uz, 0);
            box.grow(ux, uy, uz);
            // Exact fit: each cell zeroes (and enqueues) at most once.
            if (tail.* < queue.len) {
                queue[tail.*] = packOld(packCell(ux, uy, uz), vn);
                tail.* += 1;
            }
        }
    }

    /// Recompute one column's skylight + heightmap entry (vanilla-like
    /// vertical rule: each block subtracts its opacity from the light
    /// above (leaves 15->14, ice 15->12, opaque 255->0); still water stays
    /// transparent. Heights = topmost opacity!=0). Call after any block
    /// edit in the column. (Was binary 15/0 at the first opacity!=0
    /// block, which turned everything under a tree canopy pitch black.)
    pub fn relightColumn(self: *Chunk, lx: usize, lz: usize) void {
        var sky: u4 = 15;
        var y: i32 = 255;
        while (y >= 0) : (y -= 1) {
            const uy: usize = @intCast(y);
            self.setSkyAt(lx, uy, lz, sky);
            const b = self.blockAt(lx, uy, lz);
            const op = lightOpacity(b);
            if (b != .water and op != 0) {
                const drop: u4 = if (op > 15) 15 else @truncate(op);
                sky = if (drop >= sky) 0 else sky - drop;
            }
        }
        var top: u8 = 0;
        var yy: i32 = 255;
        while (yy >= 0) : (yy -= 1) {
            if (lightOpacity(self.blockAt(lx, @intCast(yy), lz)) != 0) {
                top = @intCast(yy);
                break;
            }
        }
        self.heights[lz * 16 + lx] = top;
    }

    /// Flood block light from all emissive cells (torches, lava, ...).
    /// `queue` is scratch space for the BFS (needs 65536 x u32 for a
    /// full chunk; smaller is fine — excess sources are skipped, never
    /// mislit). Opaque cells (opacity 255) block; water/ice cost an
    /// extra level. Cross-chunk bleed is ignored (neighbors resend with
    /// their own flood; 1-level seam error at borders, documented).
    pub fn relightBlock(self: *Chunk, queue: []u32) void {
        for (&self.sections) |*maybe| {
            if (maybe.*) |*s| @memset(&s.light, 0);
        }
        var tail = self.seedEmissives(queue);
        var head: usize = 0;
        // Same fixed point as the old hand-rolled flood: raise-BFS over
        // the block channel with identical costs and edge rules.
        self.bfsRaise(.block, queue, &head, &tail);
    }

    /// Pin every emissive cell to its emission value. Returns the seed
    /// count (capped at queue.len — excess sources are skipped, never
    /// mislit). Single linear pass per present section (no per-y copy
    /// of the 12KB Section value).
    fn seedEmissives(self: *Chunk, queue: []u32) usize {
        var tail: usize = 0;
        for (&self.sections, 0..) |*maybe, si| {
            const s = if (maybe.*) |*sec| sec else continue;
            const y0 = si * 16;
            for (s.blocks, 0..) |b, i| {
                const e = emitLight(b);
                if (e == 0) continue;
                Section.setNibble(&s.light, i, e);
                if (tail >= queue.len) return tail;
                queue[tail] = packCell(i & 15, y0 + (i >> 8), (i >> 4) & 15);
                tail += 1;
            }
        }
        return tail;
    }

    pub fn encodedLen(self: *const Chunk) usize {
        return header_len + @as(usize, @popCount(self.mask())) * section_bytes + tail_len;
    }

    pub fn encode(self: *const Chunk, allocator: std.mem.Allocator) ![]u8 {
        const out = try allocator.alloc(u8, self.encodedLen());
        var p: usize = 0;
        @memcpy(out[p..][0..3], magic);
        p += 3;
        out[p] = version;
        p += 1;
        out[p] = self.dim;
        p += 1;
        std.mem.writeInt(i32, out[p..][0..4], self.x, .big);
        p += 4;
        std.mem.writeInt(i32, out[p..][0..4], self.z, .big);
        p += 4;
        std.mem.writeInt(u16, out[p..][0..2], self.mask(), .big);
        p += 2;
        for (self.sections) |maybe| {
            const s = maybe orelse continue;
            for (s.blocks) |b| {
                std.mem.writeInt(u16, out[p..][0..2], @intFromEnum(b), .big);
                p += 2;
            }
            @memcpy(out[p..][0..nibble_size], &s.meta);
            p += nibble_size;
            @memcpy(out[p..][0..nibble_size], &s.add);
            p += nibble_size;
            @memcpy(out[p..][0..nibble_size], &s.sky);
            p += nibble_size;
            @memcpy(out[p..][0..nibble_size], &s.light);
            p += nibble_size;
        }
        @memcpy(out[p..][0..256], &self.biomes);
        p += 256;
        @memcpy(out[p..][0..256], &self.heights);
        p += 256;
        std.debug.assert(p == out.len);
        return out;
    }

    pub fn decode(allocator: std.mem.Allocator, data: []const u8) ChunkError!*Chunk {
        if (data.len < header_len + tail_len) return error.Truncated;
        if (!std.mem.eql(u8, data[0..3], magic)) return error.BadMagic;
        if (data[3] != version) return error.UnsupportedVersion;
        var p: usize = 4;
        const dim = data[p];
        p += 1;
        const x = std.mem.readInt(i32, data[p..][0..4], .big);
        p += 4;
        const z = std.mem.readInt(i32, data[p..][0..4], .big);
        p += 4;
        const section_mask = std.mem.readInt(u16, data[p..][0..2], .big);
        p += 2;
        const want: usize = header_len + @as(usize, @popCount(section_mask)) * section_bytes + tail_len;
        if (data.len != want) return error.Truncated;
        const c = try allocator.create(Chunk);
        errdefer allocator.destroy(c);
        c.* = .{ .dim = dim, .x = x, .z = z };
        for (0..16) |i| {
            if (section_mask & (@as(u16, 1) << @intCast(i)) == 0) continue;
            var s = Section{};
            for (&s.blocks) |*b| {
                const raw = std.mem.readInt(u16, data[p..][0..2], .big);
                if (raw >= ids.COUNT) return error.BlockIdRange;
                b.* = @enumFromInt(raw);
                p += 2;
            }
            @memcpy(&s.meta, data[p..][0..nibble_size]);
            p += nibble_size;
            @memcpy(&s.add, data[p..][0..nibble_size]);
            p += nibble_size;
            @memcpy(&s.sky, data[p..][0..nibble_size]);
            p += nibble_size;
            @memcpy(&s.light, data[p..][0..nibble_size]);
            p += nibble_size;
            c.sections[i] = s;
        }
        @memcpy(&c.biomes, data[p..][0..256]);
        p += 256;
        @memcpy(&c.heights, data[p..][0..256]);
        p += 256;
        std.debug.assert(p == data.len);
        return c;
    }
};

test "section index order + nibbles" {
    // corners map to distinct slots; nibble pack/unpack roundtrips
    try std.testing.expectEqual(@as(usize, 0), Section.index(0, 0, 0));
    try std.testing.expectEqual(@as(usize, 4095), Section.index(15, 15, 15));
    var s = Section{};
    s.setBlock(1, 2, 3, ids.diamond_block);
    try std.testing.expectEqual(ids.diamond_block, s.getBlock(1, 2, 3));
    var n: [2048]u8 = [_]u8{0} ** 2048;
    Section.setNibble(&n, 0, 0xA);
    Section.setNibble(&n, 1, 0xB);
    try std.testing.expectEqual(@as(u4, 0xA), Section.getNibble(&n, 0));
    try std.testing.expectEqual(@as(u4, 0xB), Section.getNibble(&n, 1));
}

test "zc1 sparse roundtrip" {
    const a = std.testing.allocator;
    var ch = try Chunk.createEmpty(a, 0, 3, -7);
    defer ch.destroy(a);
    ch.biomes[0] = 21;
    ch.heights[0] = 64;
    var s0 = Section{};
    s0.setBlock(0, 0, 0, ids.stone);
    s0.setBlock(15, 15, 15, ids.diamond_block);
    Section.setNibble(&s0.meta, 0, 0x5);
    ch.sections[0] = s0;
    var s5 = Section{};
    s5.setBlock(8, 8, 8, ids.record_wait);
    ch.sections[5] = s5;
    const enc = try ch.encode(a);
    defer a.free(enc);
    // 4+9+2 header + 2 sections + 512 tail
    try std.testing.expectEqual(@as(usize, 4 + 9 + 2 + 2 * section_bytes + 512), enc.len);
    const dec = try Chunk.decode(a, enc);
    defer dec.destroy(a);
    try std.testing.expectEqual(ch.dim, dec.dim);
    try std.testing.expectEqual(ch.x, dec.x);
    try std.testing.expectEqual(ch.z, dec.z);
    try std.testing.expectEqual(ch.mask(), dec.mask());
    try std.testing.expectEqual(ids.stone, dec.sections[0].?.getBlock(0, 0, 0));
    try std.testing.expectEqual(ids.diamond_block, dec.sections[0].?.getBlock(15, 15, 15));
    try std.testing.expectEqual(@as(u4, 0x5), Section.getNibble(&dec.sections[0].?.meta, 0));
    try std.testing.expectEqual(ids.record_wait, dec.sections[5].?.getBlock(8, 8, 8));
    try std.testing.expect(dec.sections[1] == null);
    try std.testing.expectEqual(@as(u8, 21), dec.biomes[0]);
    try std.testing.expectEqual(@as(u8, 64), dec.heights[0]);
}

test "zc1 rejects bad magic/trailing bytes" {
    const a = std.testing.allocator;
    var ch = try Chunk.createEmpty(a, 0, 0, 0);
    defer ch.destroy(a);
    const enc = try ch.encode(a);
    defer a.free(enc);
    var bad = try a.dupe(u8, enc);
    defer a.free(bad);
    bad[0] = 'X';
    try std.testing.expectError(error.BadMagic, Chunk.decode(a, bad));
    try std.testing.expectError(error.Truncated, Chunk.decode(a, enc[0 .. enc.len - 1]));
}

test "relightColumn: sky closes below opaque, heights skip snow" {
    const a = std.testing.allocator;
    const ch = try Chunk.createEmpty(a, 0, 0, 0);
    defer ch.destroy(a);
    ch.sections[0] = Section{};
    ch.sections[4] = Section{};
    // stone floor at y=64 (section 4, ly 0), snow_layer at 65.
    ch.sections[4].?.setBlock(0, 0, 0, .stone);
    ch.sections[4].?.setBlock(0, 1, 0, .snow_layer);
    ch.relightColumn(0, 0);
    // surface cell (65, snow k=0) still sees full sky; stone below is lit
    // at its own cell, dark underneath.
    try std.testing.expectEqual(@as(u4, 15), Section.getNibble(&ch.sections[4].?.sky, Section.index(0, 1, 0)));
    try std.testing.expectEqual(@as(u4, 15), Section.getNibble(&ch.sections[4].?.sky, Section.index(0, 0, 0)));
    try std.testing.expectEqual(@as(u4, 0), Section.getNibble(&ch.sections[0].?.sky, Section.index(0, 0, 0)));
    // heights skip the transparent snow (topmost opacity!=0 is the stone).
    try std.testing.expectEqual(@as(u8, 64), ch.heights[0]);
    // Placing opaque above closes the sky below it.
    ch.sections[4].?.setBlock(0, 2, 0, .stone);
    ch.relightColumn(0, 0);
    try std.testing.expectEqual(@as(u4, 0), Section.getNibble(&ch.sections[4].?.sky, Section.index(0, 1, 0)));
    try std.testing.expectEqual(@as(u8, 66), ch.heights[0]);
    // Leaves only dim (15->14): under-canopy is bright, not black.
    ch.sections[4].?.setBlock(0, 2, 0, .air);
    ch.sections[4].?.setBlock(0, 3, 0, .leaves);
    ch.relightColumn(0, 0);
    try std.testing.expectEqual(@as(u4, 15), Section.getNibble(&ch.sections[4].?.sky, Section.index(0, 3, 0)));
    try std.testing.expectEqual(@as(u4, 14), Section.getNibble(&ch.sections[4].?.sky, Section.index(0, 2, 0)));
    try std.testing.expectEqual(@as(u4, 14), Section.getNibble(&ch.sections[4].?.sky, Section.index(0, 1, 0)));
    try std.testing.expectEqual(@as(u8, 67), ch.heights[0]);
}

test "relightBlock: torch floods, stone blocks" {
    const a = std.testing.allocator;
    const ch = try Chunk.createEmpty(a, 0, 0, 0);
    defer ch.destroy(a);
    ch.sections[0] = Section{};
    // stone shell at y=0..2 around (8,1,8), torch at center.
    var dx: i32 = -1;
    while (dx <= 1) : (dx += 1) {
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            ch.sections[0].?.setBlock(@intCast(8 + dx), 0, @intCast(8 + dz), .stone);
            ch.sections[0].?.setBlock(@intCast(8 + dx), 2, @intCast(8 + dz), .stone);
        }
    }
    ch.sections[0].?.setBlock(8, 1, 8, .torch);
    const q = try a.alloc(u32, 65536);
    defer a.free(q);
    ch.relightBlock(q);
    // torch cell 14, open neighbor 13.
    try std.testing.expectEqual(@as(u4, 14), Section.getNibble(&ch.sections[0].?.light, Section.index(8, 1, 8)));
    try std.testing.expectEqual(@as(u4, 13), Section.getNibble(&ch.sections[0].?.light, Section.index(9, 1, 8)));
    // stone above/below the torch stays dark (opaque stops the flood).
    try std.testing.expectEqual(@as(u4, 0), Section.getNibble(&ch.sections[0].?.light, Section.index(8, 0, 8)));
    try std.testing.expectEqual(@as(u4, 0), Section.getNibble(&ch.sections[0].?.light, Section.index(8, 2, 8)));
    // Removing the torch extinguishes the flood.
    ch.sections[0].?.setBlock(8, 1, 8, .air);
    ch.relightBlock(q);
    try std.testing.expectEqual(@as(u4, 0), Section.getNibble(&ch.sections[0].?.light, Section.index(9, 1, 8)));
}

test "spreadSky: overhang leaks sideways with falloff, sealed rooms stay dark" {
    // Vanilla shape: open columns hold 15 (column rule); light under a
    // roof comes sideways from the opening, dimming 1/level through air;
    // roof stones hold 15 on top but must NOT leak downward (else nothing
    // under any roof would ever go dark and mobs would never spawn there).
    const a = std.testing.allocator;
    const ch = try Chunk.createEmpty(a, 0, 0, 0);
    defer ch.destroy(a);
    for (0..5) |s| ch.sections[s] = Section{};
    // Stone floor y=64 everywhere; roof slab y=70..71 over x=8..15.
    var x: usize = 0;
    while (x < 16) : (x += 1) {
        var z: usize = 0;
        while (z < 16) : (z += 1) {
            ch.sections[4].?.setBlock(@intCast(x), 0, @intCast(z), .stone);
            if (x >= 8) {
                ch.sections[4].?.setBlock(@intCast(x), 6, @intCast(z), .stone);
                ch.sections[4].?.setBlock(@intCast(x), 7, @intCast(z), .stone);
            }
        }
    }
    // Sealed 1-cell room at (3,66,8): stone on all 6 sides.
    const room = [_][3]u4{ .{ 2, 2, 8 }, .{ 4, 2, 8 }, .{ 3, 1, 8 }, .{ 3, 3, 8 }, .{ 3, 2, 7 }, .{ 3, 2, 9 } };
    for (room) |c| ch.sections[4].?.setBlock(c[0], c[1], c[2], .stone);
    for (0..16) |lz| {
        for (0..16) |lx| ch.relightColumn(lx, lz);
    }
    const q = try a.alloc(u32, 65536);
    defer a.free(q);
    ch.spreadSky(q);
    const sky = struct {
        fn at(c: *Chunk, lx: usize, y: usize, lz: usize) u4 {
            const s = c.sections[y >> 4] orelse return 0;
            return Section.getNibble(&s.sky, Section.index(@intCast(lx), @intCast(y & 15), @intCast(lz)));
        }
    }.at;
    // Open column untouched by the spread.
    try std.testing.expectEqual(@as(u4, 15), sky(ch, 7, 69, 8));
    try std.testing.expectEqual(@as(u4, 15), sky(ch, 7, 65, 8));
    // Sideways falloff under the roof edge (15/14/13/12...).
    try std.testing.expectEqual(@as(u4, 14), sky(ch, 8, 69, 8));
    try std.testing.expectEqual(@as(u4, 12), sky(ch, 10, 69, 8));
    // Roof top stones hold 15 but must not leak: (15,69) is 7 deep via
    // the sideways chain, not 14 from the stone above it. (Second roof
    // layer y=70 holds 0 — set-after-drop.)
    try std.testing.expectEqual(@as(u4, 15), sky(ch, 8, 71, 8));
    try std.testing.expectEqual(@as(u4, 0), sky(ch, 8, 70, 8));
    try std.testing.expectEqual(@as(u4, 7), sky(ch, 15, 69, 8));
    // Near-opening under-roof cells stay bright via the short sideways
    // path, even though their own column reads dark.
    try std.testing.expectEqual(@as(u4, 14), sky(ch, 8, 65, 8));
    try std.testing.expectEqual(@as(u4, 7), sky(ch, 15, 65, 8));
    // Sealed room: no path in, stays black.
    try std.testing.expectEqual(@as(u4, 0), sky(ch, 3, 66, 8));
}

test "spreadSky: shaft stays bright, leaves and water attenuate sideways" {
    const a = std.testing.allocator;
    // 1x1 shaft at (4,*): stone y=0..63 except the shaft, open sky above.
    {
        const ch = try Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        for (0..4) |s| ch.sections[s] = Section{};
        var y: usize = 0;
        while (y < 64) : (y += 1) {
            var z: usize = 0;
            while (z < 16) : (z += 1) {
                var x: usize = 0;
                while (x < 16) : (x += 1) {
                    if (x == 4 and z == 4) continue;
                    const sec = &ch.sections[y >> 4].?;
                    sec.setBlock(@intCast(x), @intCast(y & 15), @intCast(z), .stone);
                }
            }
        }
        for (0..16) |lz| {
            for (0..16) |lx| ch.relightColumn(lx, lz);
        }
        const q = try a.alloc(u32, 65536);
        defer a.free(q);
        ch.spreadSky(q);
        try std.testing.expectEqual(@as(u4, 15), ch.getSkyAt(4, 10, 4));
        try std.testing.expectEqual(@as(u4, 15), ch.getSkyAt(4, 1, 4));
        // Shaft walls are opaque: no sideways leak out of the shaft.
        try std.testing.expectEqual(@as(u4, 0), ch.getSkyAt(5, 10, 4));
    }
    // Leaves dim by exactly 1 sideways; water costs 3 (jar opacity).
    for ([_]ids.Id{ .leaves, .water }) |mat| {
        const ch = try Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        for (0..5) |s| ch.sections[s] = Section{};
        // Floor y=64, full-width roof y=70..71 over x=4..15, open x=0..3.
        var x: usize = 0;
        while (x < 16) : (x += 1) {
            var z: usize = 0;
            while (z < 16) : (z += 1) {
                ch.sections[4].?.setBlock(@intCast(x), 0, @intCast(z), .stone);
                if (x >= 4) {
                    ch.sections[4].?.setBlock(@intCast(x), 6, @intCast(z), .stone);
                    ch.sections[4].?.setBlock(@intCast(x), 7, @intCast(z), .stone);
                }
            }
        }
        ch.sections[4].?.setBlock(8, 5, 8, mat);
        for (0..16) |lz| {
            for (0..16) |lx| ch.relightColumn(lx, lz);
        }
        const q = try a.alloc(u32, 65536);
        defer a.free(q);
        ch.spreadSky(q);
        // Chain from the opening: (3,69)=15, (4,69)=14 ... (7,69)=11.
        try std.testing.expectEqual(@as(u4, 11), ch.getSkyAt(7, 69, 8));
        const want: u4 = if (mat == .leaves) 10 else 8;
        try std.testing.expectEqual(want, ch.getSkyAt(8, 69, 8));
    }
}

test "unspreadLight block: torch removal extinguishes, replace restores" {
    // Incremental two-phase at chunk level (the exact sequence
    // applyBlock runs): removing the emitter must not leave stale light,
    // and re-placing must restore the identical flood.
    const a = std.testing.allocator;
    const ch = try Chunk.createEmpty(a, 0, 0, 0);
    defer ch.destroy(a);
    ch.sections[0] = Section{};
    ch.sections[0].?.setBlock(8, 1, 8, .torch);
    const q = try a.alloc(u32, 65536);
    defer a.free(q);
    ch.relightBlock(q);
    const at = struct {
        fn light(c: *Chunk, x: u4, y: u4, z: u4) u4 {
            return Section.getNibble(&c.sections[0].?.light, Section.index(x, y, z));
        }
    }.light;
    try std.testing.expectEqual(@as(u4, 14), at(ch, 8, 1, 8));
    try std.testing.expectEqual(@as(u4, 13), at(ch, 9, 1, 8));
    // Remove the torch: pin the cell to 0, invalidate with the old value.
    ch.sections[0].?.setBlock(8, 1, 8, .air);
    Section.setNibble(&ch.sections[0].?.light, Section.index(8, 1, 8), 0);
    const tc = Chunk.packCell(8, 1, 8);
    const old = [_]Chunk.CellValue{.{ .cell = tc, .value = 14 }};
    const rw = [_]Chunk.CellValue{.{ .cell = tc, .value = 0 }};
    ch.unspreadLight(q, .block, &old, &rw);
    try std.testing.expectEqual(@as(u4, 0), at(ch, 8, 1, 8));
    try std.testing.expectEqual(@as(u4, 0), at(ch, 9, 1, 8));
    // Re-place: pin to emission, raise-flood restores the same values.
    ch.sections[0].?.setBlock(8, 1, 8, .torch);
    Section.setNibble(&ch.sections[0].?.light, Section.index(8, 1, 8), 14);
    const one = [_]u32{tc};
    ch.spreadLight(q, .block, &one);
    try std.testing.expectEqual(@as(u4, 14), at(ch, 8, 1, 8));
    try std.testing.expectEqual(@as(u4, 13), at(ch, 9, 1, 8));
}

test "unspreadLight block: glass wall darkens corridor, break restores all" {
    // Sealed 1-wide tube (torch - glass - air - air - air): replacing the
    // glass with stone must darken everything past it (no alternate
    // paths), and breaking it back must restore every level exactly
    // (proves reflood completeness — no over-zeroing left behind).
    const a = std.testing.allocator;
    const ch = try Chunk.createEmpty(a, 0, 0, 0);
    defer ch.destroy(a);
    ch.sections[0] = Section{};
    // Stone everywhere in section 0 except the tube cells.
    var y: usize = 0;
    while (y < 16) : (y += 1) {
        var z: usize = 0;
        while (z < 16) : (z += 1) {
            var x: usize = 0;
            while (x < 16) : (x += 1) {
                const in_tube = (y == 1 and z == 8 and x >= 7 and x <= 11);
                if (!in_tube) ch.sections[0].?.setBlock(@intCast(x), @intCast(y), @intCast(z), .stone);
            }
        }
    }
    ch.sections[0].?.setBlock(7, 1, 8, .torch);
    ch.sections[0].?.setBlock(8, 1, 8, .glass);
    const q = try a.alloc(u32, 65536);
    defer a.free(q);
    ch.relightBlock(q);
    const at = struct {
        fn light(c: *Chunk, ax: u4, ay: u4, az: u4) u4 {
            return Section.getNibble(&c.sections[0].?.light, Section.index(ax, ay, az));
        }
    }.light;
    try std.testing.expectEqual(@as(u4, 14), at(ch, 7, 1, 8));
    try std.testing.expectEqual(@as(u4, 13), at(ch, 8, 1, 8));
    try std.testing.expectEqual(@as(u4, 12), at(ch, 9, 1, 8));
    try std.testing.expectEqual(@as(u4, 11), at(ch, 10, 1, 8));
    try std.testing.expectEqual(@as(u4, 10), at(ch, 11, 1, 8));
    // Glass -> stone: the cell goes dark, everything past it must too
    // (stone is opaque: the flood stops at the wall, no alternate paths
    // exist in the sealed tube).
    ch.sections[0].?.setBlock(8, 1, 8, .stone);
    Section.setNibble(&ch.sections[0].?.light, Section.index(8, 1, 8), 0);
    const gc = Chunk.packCell(8, 1, 8);
    const old = [_]Chunk.CellValue{.{ .cell = gc, .value = 13 }};
    const rw0 = [_]Chunk.CellValue{.{ .cell = gc, .value = 0 }};
    ch.unspreadLight(q, .block, &old, &rw0);
    try std.testing.expectEqual(@as(u4, 0), at(ch, 8, 1, 8));
    try std.testing.expectEqual(@as(u4, 0), at(ch, 9, 1, 8));
    try std.testing.expectEqual(@as(u4, 0), at(ch, 10, 1, 8));
    try std.testing.expectEqual(@as(u4, 0), at(ch, 11, 1, 8));
    // Torch itself is untouched by the wall going up next to it.
    try std.testing.expectEqual(@as(u4, 14), at(ch, 7, 1, 8));
    // Stone -> air: recompute (13 via torch), invalidate the stale 0,
    // rewrite + reflood restores every level exactly.
    ch.sections[0].?.setBlock(8, 1, 8, .air);
    Section.setNibble(&ch.sections[0].?.light, Section.index(8, 1, 8), 13);
    const old2 = [_]Chunk.CellValue{.{ .cell = gc, .value = 0 }};
    const rw2 = [_]Chunk.CellValue{.{ .cell = gc, .value = 13 }};
    ch.unspreadLight(q, .block, &old2, &rw2);
    const one = [_]u32{gc};
    ch.spreadLight(q, .block, &one);
    try std.testing.expectEqual(@as(u4, 13), at(ch, 8, 1, 8));
    try std.testing.expectEqual(@as(u4, 12), at(ch, 9, 1, 8));
    try std.testing.expectEqual(@as(u4, 11), at(ch, 10, 1, 8));
    try std.testing.expectEqual(@as(u4, 10), at(ch, 11, 1, 8));
}
