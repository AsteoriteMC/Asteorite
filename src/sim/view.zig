//! View-distance chunk delivery: spiral-order initial burst via bulk packets.
//!
//! Login flow (groundUp=true full columns only):
//!   JoinGame -> SpawnPosition -> MapChunkBulk(s) -> PlayerPosLook.
//! Re-sending an existing groundUp column leaks client memory, so each
//! column is sent at most once per connection (tracked resend is P-next
//! with unload packets, which chunks.zig already encodes).

const std = @import("std");
const chunks = @import("../proto/v5/chunks.zig");
const packets = @import("../proto/v5/packets.zig");
const chunk_mod = @import("../world/chunk.zig");
const store_mod = @import("../world/store.zig");
const shard_mod = @import("../world/shard.zig");
const conn_mod = @import("../net/conn.zig");
const ids = @import("../ids.zig");

/// Returns owned ZC1 bytes for (dim,x,z), or null when the column is missing
/// (void hole until terrain generation lands). Caller frees.
pub const Source = struct {
    ctx: *anyopaque,
    getFn: *const fn (ctx: *anyopaque, dim: u8, x: i32, z: i32, allocator: std.mem.Allocator) ?[]u8,

    pub fn get(self: Source, dim: u8, x: i32, z: i32, allocator: std.mem.Allocator) ?[]u8 {
        return self.getFn(self.ctx, dim, x, z, allocator);
    }
};

/// ShardPool-backed source (LSM raw values are ZC1 payloads).
/// Returned bytes are owned by `allocator`; pool-owned bytes are duped.
pub fn shardPoolSource(pool: *shard_mod.ShardPool) Source {
    const F = struct {
        fn get(ctx: *anyopaque, dim: u8, x: i32, z: i32, allocator: std.mem.Allocator) ?[]u8 {
            const p: *shard_mod.ShardPool = @ptrCast(@alignCast(ctx));
            const raw = p.get(allocator, store_mod.encodeKey(dim, x, z)) catch null orelse return null;
            defer allocator.free(raw);
            return allocator.dupe(u8, raw) catch null;
        }
    };
    return .{ .ctx = pool, .getFn = F.get };
}

/// Ring-order spiral offsets for radius r (center first).
pub const Spiral = struct {
    radius: i32,
    ring: i32 = 0,
    idx: usize = 0,

    pub fn next(self: *Spiral) ?struct { dx: i32, dz: i32 } {
        if (self.ring == 0) {
            self.ring = 1;
            return .{ .dx = 0, .dz = 0 };
        }
        while (self.ring <= self.radius) {
            // perimeter of square ring: (2r+1)^2 - (2r-1)^2 = 8r cells
            const per: usize = @intCast(8 * self.ring);
            if (self.idx < per) {
                // walk clockwise starting at (-r,-r)
                const side: usize = @intCast(2 * self.ring);
                const i = self.idx;
                self.idx += 1;
                const r = self.ring;
                if (i < side) return .{ .dx = -r + @as(i32, @intCast(i)), .dz = -r };
                if (i < 2 * side) return .{ .dx = r, .dz = -r + @as(i32, @intCast(i - side)) };
                if (i < 3 * side) return .{ .dx = r - @as(i32, @intCast(i - 2 * side)), .dz = r };
                return .{ .dx = -r, .dz = r - @as(i32, @intCast(i - 3 * side)) };
            }
            self.ring += 1;
            self.idx = 0;
        }
        return null;
    }
};

pub const max_bulk_cols = 32;
pub const max_view_radius = 16;

pub const ColPos = struct { x: i32, z: i32 };

/// Send explicit columns (spiral order preferred), skipping + recording via
/// the conn sent-set. Each column goes out at most once per unload cycle.
/// `budget` caps pool reads (null = unlimited): the 1Hz hole-heal rescan
/// passes a small budget so a serve thread never stalls in store reads
/// while generation is active (spiral order => nearest holes heal first).
/// Login/movement bursts pass null (whole disk, one shot).
pub fn sendColumns(
    conn: *conn_mod.Conn,
    src: Source,
    dim: u8,
    positions: []const ColPos,
    sky: bool,
    budget: ?usize,
) !void {
    // Reusable conn-owned scratch (never-reset arena: per-call allocs here
    // leak until process exit — see Conn.bulk_raw).
    const a = conn.allocator;
    if (conn.bulk_raw.len == 0) {
        const raw = try a.alloc(u8, max_bulk_cols * 196864);
        errdefer a.free(raw);
        const comp = try a.alloc(u8, max_bulk_cols * 196864 + 1024);
        errdefer a.free(comp);
        const work = try a.alloc(u8, std.compress.flate.max_window_len);
        conn.bulk_raw = raw;
        conn.bulk_comp = comp;
        conn.bulk_work = work;
    }
    const raw_all = conn.bulk_raw;
    const comp_all = conn.bulk_comp;
    const work = conn.bulk_work;
    // Transient per-column work (ZC1 bytes, decoded chunks, bulk frames)
    // uses a per-column scratch arena, NOT conn.allocator (a never-reset
    // arena leaks every free until process exit) and NOT one shared frame
    // arena either: pool.get reads whole SST files per lookup, so a single
    // arena for the whole 289-column login burst pins every file image at
    // once (~1GB+ transient that only drops at the end of the call).
    // Only conn-owned scratch (above) and the sent-set outlive one column.
    var cols: [max_bulk_cols]chunks.BulkColumn = undefined;
    var ncols: usize = 0;
    var raw_len: usize = 0;
    var gets: usize = 0;
    for (positions) |pos| {
        var col_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer col_arena.deinit();
        const t = col_arena.allocator();
        const k = conn_mod.Conn.sentKey(pos.x, pos.z);
        if (conn.sent.contains(k)) continue; // already out (no groundUp re-send)
        if (budget) |b| {
            if (gets >= b) break; // hole-heal tick: leave the rest for next time
            gets += 1;
        }
        const zc1 = src.get(dim, pos.x, pos.z, t) orelse continue; // hole (terrain gen P-next)
        const ch = chunk_mod.Chunk.decode(t, zc1) catch continue;
        const layout = chunks.encodeColumn(ch, sky, raw_all[raw_len..]);
        cols[ncols] = .{ .x = pos.x, .z = pos.z, .primary = layout.primary, .add = layout.add };
        ncols += 1;
        raw_len += layout.len;
        try conn.sent.put(k, {});
        if (ncols == max_bulk_cols) {
            try flushBulk(conn, t, cols[0..ncols], raw_all[0..raw_len], comp_all, work, sky);
            ncols = 0;
            raw_len = 0;
        }
    }
    if (ncols > 0) {
        // Tail flush (< max_bulk_cols columns): needs a transient allocator
        // for the compressed+framed bytes; queueFramed copies into conn.out.
        var tail_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer tail_arena.deinit();
        try flushBulk(conn, tail_arena.allocator(), cols[0..ncols], raw_all[0..raw_len], comp_all, work, sky);
    }
}

/// Send the stored columns of the view disk around (cx,cz) in spiral order
/// (batched into bulk packets). Holes are skipped (async gen fills them;
/// serveConn retries when the pool sequence advances).
pub fn resyncDisk(
    conn: *conn_mod.Conn,
    source: ?Source,
    dim: u8,
    cx: i32,
    cz: i32,
    radius: u8,
    sky: bool,
    budget: ?usize,
) !void {
    if (source) |src| {
        var list: [1089]ColPos = undefined;
        var n: usize = 0;
        var sp = Spiral{ .radius = @min(radius, max_view_radius) };
        while (sp.next()) |off| {
            list[n] = .{ .x = cx + off.dx, .z = cz + off.dz };
            n += 1;
        }
        try sendColumns(conn, src, dim, list[0..n], sky, budget);
    }
}

/// Send all stored columns around (cx,cz) in spiral order, batched into bulk
/// packets, then queue PlayerPosLook. Missing columns are skipped.
pub fn completeLogin(
    conn: *conn_mod.Conn,
    source: ?Source,
    dim: u8,
    cx: i32,
    cz: i32,
    radius: u8,
    sky: bool,
) !void {
    try resyncDisk(conn, source, dim, cx, cz, radius, sky, null);
    try conn.queuePlayerPosLook();
    conn.sent_center = .{ .cx = cx, .cz = cz };
    conn.baseline_sent = true;
    conn.chunks_dirty = false;
    conn.force_resync = false;
}

/// Movement/respawn follow-up. Unloads left columns, bursts entered ones.
/// No-op when the center chunk hasn't changed (unless force_resync).
pub fn syncPlayerChunks(
    conn: *conn_mod.Conn,
    source: ?Source,
    dim: u8,
    radius: u8,
    sky: bool,
) !void {
    if (!conn.baseline_sent) {
        conn.chunks_dirty = false;
        return;
    }
    const r = @min(radius, max_view_radius);
    const cc = conn.playerChunk();
    if (conn.force_resync) {
        try fullResync(conn, source, dim, cc.cx, cc.cz, r, sky);
        return;
    }
    const sc = conn.sent_center orelse {
        // no baseline center (shouldn't happen) — treat as full burst
        try completeLogin(conn, source, dim, cc.cx, cc.cz, r, sky);
        return;
    };
    if (sc.cx == cc.cx and sc.cz == cc.cz) {
        conn.chunks_dirty = false;
        return;
    }
    // new disk membership for unload diff
    var new_disk = std.AutoHashMap(i64, void).init(conn.allocator);
    defer new_disk.deinit();
    var entered: [1089]ColPos = undefined;
    var n_entered: usize = 0;
    var sp = Spiral{ .radius = r };
    while (sp.next()) |off| {
        const x = cc.cx + off.dx;
        const z = cc.cz + off.dz;
        try new_disk.put(conn_mod.Conn.sentKey(x, z), {});
        if (!conn.sent.contains(conn_mod.Conn.sentKey(x, z))) {
            entered[n_entered] = .{ .x = x, .z = z };
            n_entered += 1;
        }
    }
    // unload left columns (single 0x21 unload each — small frames)
    var it = conn.sent.keyIterator();
    var left: [1089]ColPos = undefined;
    var n_left: usize = 0;
    while (it.next()) |k| {
        const uk: u64 = @bitCast(k.*);
        if (!new_disk.contains(k.*)) {
            left[n_left] = .{
                .x = @as(i32, @bitCast(@as(u32, @truncate(uk >> 32)))),
                .z = @as(i32, @bitCast(@as(u32, @truncate(uk)))),
            };
            n_left += 1;
        }
    }
    // remove before queueing (queueFramed can't fail realistically; conn dies on error anyway)
    for (left[0..n_left]) |c| _ = conn.sent.remove(conn_mod.Conn.sentKey(c.x, c.z));
    var ubuf: [2048]u8 = undefined;
    for (left[0..n_left]) |c| {
        try conn.queueFramed(try chunks.frameUnloadChunk(c.x, c.z, &ubuf));
    }
    if (source) |src| {
        try sendColumns(conn, src, dim, entered[0..n_entered], sky, null);
    }
    conn.sent_center = .{ .cx = cc.cx, .cz = cc.cz };
    conn.chunks_dirty = false;
}

/// Respawn: Respawn packet + unload-all + full burst + PosLook.
pub fn fullResync(
    conn: *conn_mod.Conn,
    source: ?Source,
    dim: u8,
    cx: i32,
    cz: i32,
    radius: u8,
    sky: bool,
) !void {    var rb: [256]u8 = undefined;
    try conn.queueFramed(try packets.frameRespawn(0, conn.config.difficulty, conn.config.gamemode, conn.config.level_type, &rb));
    var ubuf: [2048]u8 = undefined;
    var it = conn.sent.keyIterator();
    while (it.next()) |k| {
        const uk: u64 = @bitCast(k.*);
        const x: i32 = @as(i32, @bitCast(@as(u32, @truncate(uk >> 32))));
        const z: i32 = @as(i32, @bitCast(@as(u32, @truncate(uk))));
        try conn.queueFramed(try chunks.frameUnloadChunk(x, z, &ubuf));
    }
    conn.sent.clearRetainingCapacity();
    conn.sent_center = null;
    conn.baseline_sent = false;
    try completeLogin(conn, source, dim, cx, cz, radius, sky);
}

/// Apply one block edit to the LSM store (ZC1 roundtrip). Missing chunks
/// (holes) are ignored — generation is P-next. Callers hold the world lock.
pub const PeekBlock = struct { id: ids.Id, meta: u4 };

/// Vanilla `isOpaqueCube` approximation for suffocation: full solid cubes
/// suffocate, everything else (air, fluids, glass, leaves, ice, slabs,
/// stairs, plants, torches, rails, snow, etc.) doesn't. Default is opaque
/// (stone/dirt/ores/planks/logs/wool/...). Fences/walls/panes are full
/// cubes here — slightly stricter than vanilla, documented.
pub fn isOpaqueCube(id: ids.Id) bool {
    return switch (id) {
        ids.air, ids.sapling, ids.flowing_water, ids.water, ids.flowing_lava, ids.lava, ids.leaves, ids.glass, ids.bed_block, ids.golden_rail, ids.detector_rail, ids.web, ids.tallgrass, ids.deadbush, ids.yellow_flower, ids.red_flower, ids.brown_mushroom, ids.red_mushroom, ids.stone_slab, ids.torch, ids.fire, ids.oak_stairs, ids.redstone_wire, ids.wheat_block, ids.standing_sign, ids.wooden_door_block, ids.ladder, ids.rail, ids.stone_stairs, ids.wall_sign, ids.lever, ids.stone_pressure_plate, ids.iron_door_block, ids.wooden_pressure_plate, ids.unlit_redstone_torch, ids.redstone_torch, ids.stone_button, ids.snow_layer, ids.ice, ids.reeds_block, ids.fence, ids.unpowered_repeater, ids.powered_repeater, ids.trapdoor, ids.pumpkin_stem, ids.melon_stem, ids.vine, ids.fence_gate, ids.brick_stairs, ids.stone_brick_stairs, ids.waterlily, ids.nether_brick_stairs, ids.nether_wart_block, ids.enchanting_table, ids.brewing_stand_block, ids.cauldron_block, ids.end_portal_frame, ids.wooden_slab, ids.sandstone_stairs, ids.tripwire_hook, ids.tripwire, ids.spruce_stairs, ids.birch_stairs, ids.jungle_stairs, ids.flower_pot_block, ids.carrots, ids.potatoes, ids.wooden_button, ids.skull_block, ids.light_weighted_pressure_plate, ids.heavy_weighted_pressure_plate, ids.unpowered_comparator, ids.powered_comparator, ids.daylight_detector, ids.quartz_stairs, ids.activator_rail, ids.stained_hardened_clay, ids.leaves2, ids.acacia_stairs, ids.dark_oak_stairs, ids.carpet, ids.double_plant => false, // unassigned wire ids never become Ids: fromWire rejects them at the boundary
        else => true,
    };
}

/// Read one block without mutating. Null when the chunk/section is absent.
pub fn peekBlock(pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, x: i32, y: u8, z: i32) !?PeekBlock {
    const cx = @divFloor(x, 16);
    const cz = @divFloor(z, 16);
    const key = store_mod.encodeKey(0, cx, cz);
    const raw = try pool.get(allocator, key) orelse return null;
    defer allocator.free(raw);
    const ch = chunk_mod.Chunk.decode(allocator, raw) catch return null;
    defer ch.destroy(allocator);
    const si: usize = @as(usize, y) >> 4;
    const s = ch.sections[si] orelse return null;
    const li: usize = chunk_mod.Section.index(@intCast(@as(u4, @truncate(@as(u32, @bitCast(x & 15))))), @truncate(y & 15), @truncate(@as(u32, @bitCast(z & 15))));
    return .{ .id = s.blocks[li], .meta = chunk_mod.Section.getNibble(&s.meta, li) };
}

/// Highest solid block at (x,z) at or below from_y. Null when the column is
/// missing or entirely air (over-void spawns rest at y 0).
pub fn groundBlockY(pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, x: i32, z: i32, from_y: u8) !?u8 {
    const cx = @divFloor(x, 16);
    const cz = @divFloor(z, 16);
    const key = store_mod.encodeKey(0, cx, cz);
    const raw = try pool.get(allocator, key) orelse return null;
    defer allocator.free(raw);
    const ch = chunk_mod.Chunk.decode(allocator, raw) catch return null;
    defer ch.destroy(allocator);
    var y: i32 = from_y;
    while (y >= 0) : (y -= 1) {
        const yu: u8 = @intCast(y);
        const si: usize = @as(usize, yu) >> 4;
        if (ch.sections[si]) |s| {
            const li: usize = chunk_mod.Section.index(@intCast(@as(u4, @truncate(@as(u32, @bitCast(x & 15))))), @truncate(yu & 15), @truncate(@as(u32, @bitCast(z & 15))));
            if (s.blocks[li] != ids.air) return yu;
        }
    }
    return null;
}

pub fn applyBlock(pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, x: i32, y: u8, z: i32, id: ids.Id, meta: u4) !void {
    const cx = @divFloor(x, 16);
    const cz = @divFloor(z, 16);
    const key = store_mod.encodeKey(0, cx, cz);
    const raw = try pool.get(allocator, key) orelse return;
    defer allocator.free(raw);
    const ch = chunk_mod.Chunk.decode(allocator, raw) catch return;
    defer ch.destroy(allocator);
    const si: usize = @as(usize, y) >> 4;
    if (ch.sections[si] == null) {
        if (id == ids.air) return; // breaking air in an empty section: no-op
        ch.sections[si] = chunk_mod.Section{};
    }
    const s = &ch.sections[si].?;
    const li: usize = chunk_mod.Section.index(@intCast(@as(u4, @truncate(@as(u32, @bitCast(x & 15))))), @truncate(y & 15), @truncate(@as(u32, @bitCast(z & 15))));
    s.blocks[li] = id;
    chunk_mod.Section.setNibble(&s.meta, li, meta);
    // Keep lighting + heightmap consistent with the edit (vanilla
    // re-lights on block change; stale nibbles would otherwise persist
    // until the next full chunk resend). Column sky is vertical-exact;
    // block light re-floods the chunk from emissive cells.
    ch.relightColumn(@intCast(@as(u4, @truncate(@as(u32, @bitCast(x & 15))))), @intCast(@as(u4, @truncate(@as(u32, @bitCast(z & 15))))));
    const q = try allocator.alloc(u32, 65536);
    defer allocator.free(q);
    ch.relightBlock(q);
    const enc = try ch.encode(allocator);
    defer allocator.free(enc);
    try pool.put(key, enc);
}

fn flushBulk(conn: *conn_mod.Conn, alloc: std.mem.Allocator, cols: []const chunks.BulkColumn, raw: []const u8, comp: []u8, work: []u8, sky: bool) !void {
    const cz = try chunks.zlibCompress(raw, comp, work);
    const out = try alloc.alloc(u8, 16 + cz.len + 12 * cols.len);
    defer alloc.free(out);
    const f = try chunks.frameMapChunkBulk(cols, cz, sky, out);
    try conn.queueFramed(f);
}

test "spiral covers square exactly once" {
    var sp = Spiral{ .radius = 1 };
    var seen = std.AutoHashMap(i32, void).init(std.testing.allocator);
    defer seen.deinit();
    var n: usize = 0;
    while (sp.next()) |off| {
        try seen.put(off.dx * 100 + off.dz, {});
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 9), n);
    try std.testing.expectEqual(@as(usize, 9), seen.count());
    // center first
    var sp2 = Spiral{ .radius = 2 };
    const first = sp2.next().?;
    try std.testing.expectEqual(@as(i32, 0), first.dx);
    try std.testing.expectEqual(@as(i32, 0), first.dz);
}

test "completeLogin sends bulk + poslook, skips holes" {
    const a = std.testing.allocator;
    // in-memory source with 2 of 9 columns present
    const Mem = struct {
        var store: ?std.AutoHashMap(i64, []u8) = null;
        fn key(x: i32, z: i32) i64 {
            return (@as(i64, x) << 32) | @as(u32, @bitCast(z));
        }
        fn get(ctx: *anyopaque, dim: u8, x: i32, z: i32, alloc: std.mem.Allocator) ?[]u8 {
            _ = ctx;
            _ = dim;
            const m = store orelse return null;
            const v = m.get(key(x, z)) orelse return null;
            return alloc.dupe(u8, v) catch null;
        }
    };
    var map = std.AutoHashMap(i64, []u8).init(a);
    defer {
        var it = map.iterator();
        while (it.next()) |e| a.free(e.value_ptr.*);
        map.deinit();
    }
    // chunk (0,0): section0 with block 1; chunk (1,0): section0 with block 57
    for ([_]struct { x: i32, id: ids.Id }{ .{ .x = 0, .id = ids.stone }, .{ .x = 1, .id = ids.diamond_block } }) |e| {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, e.x, 0);
        defer ch.destroy(a);
        var s = chunk_mod.Section{};
        s.setBlock(0, 0, 0, e.id);
        ch.sections[0] = s;
        const enc = try ch.encode(a);
        defer a.free(enc);
        try map.put(Mem.key(e.x, 0), try a.dupe(u8, enc));
    }
    Mem.store = map;
    const src = Source{ .ctx = @ptrCast(&Mem.store), .getFn = Mem.get };

    var c = conn_mod.Conn.init(a, std.testing.io, .{}, 1);
    defer c.deinit();
    c.state = .play;
    try completeLogin(&c, src, 0, 0, 0, 1, true);
    const out = try c.takeOutput();
    defer a.free(out);
    // expect: 1 bulk (2 cols, (0,0) then spiral rest, (1,0) present) + 1 poslook
    const codec = @import("../net/codec.zig");
    var r = codec.PacketReader.init(out);
    const h0 = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 0x26), h0.id);
    try std.testing.expectEqual(@as(i16, 2), try r.readShort());
    const dlen = try r.readInt();
    try std.testing.expect(dlen > 0);
    try std.testing.expect(try r.readBool());
    const zdata = try r.readBytes(@intCast(dlen));
    // meta for 2 columns
    try std.testing.expectEqual(@as(i32, 0), try r.readInt());
    try std.testing.expectEqual(@as(i32, 0), try r.readInt());
    try std.testing.expectEqual(@as(u16, 1), try r.readUShort());
    try std.testing.expectEqual(@as(u16, 0), try r.readUShort());
    try std.testing.expectEqual(@as(i32, 1), try r.readInt());
    try std.testing.expectEqual(@as(i32, 0), try r.readInt());
    try std.testing.expectEqual(@as(u16, 1), try r.readUShort());
    try std.testing.expectEqual(@as(u16, 0), try r.readUShort());
    // decompress concatenated stream and check first column's block bytes
    var in: std.Io.Reader = .fixed(zdata);
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    var decomp = std.compress.flate.Decompress.init(&in, .zlib, &.{});
    _ = try decomp.reader.streamRemaining(&aw.writer);
    const plain = aw.written();
    // col (0,0): 1 section -> blocks 4096, first byte 1; col (1,0) follows
    const col_len: usize = 4096 + 2048 * 3 + 256;
    try std.testing.expectEqual(@as(usize, 2 * col_len), plain.len);
    try std.testing.expectEqual(@as(u8, 1), plain[0]);
    try std.testing.expectEqual(@as(u8, 57), plain[col_len]);
    // then PlayerPosLook 0x08
    const h1 = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 0x08), h1.id);
    _ = try r.readBytes(8 * 3 + 4 * 2 + 1); // x,y,z,yaw,pitch,onGround
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "sync on move: unload + burst, no resends, respawn resets" {
    const a = std.testing.allocator;
    const codec = @import("../net/codec.zig");
    const Mem = struct {
        var store: ?std.AutoHashMap(i64, []u8) = null;
        fn key(x: i32, z: i32) i64 {
            return conn_mod.Conn.sentKey(x, z);
        }
        fn get(ctx: *anyopaque, dim: u8, x: i32, z: i32, alloc: std.mem.Allocator) ?[]u8 {
            _ = ctx;
            _ = dim;
            const m = store orelse return null;
            const v = m.get(key(x, z)) orelse return null;
            return alloc.dupe(u8, v) catch null;
        }
    };
    var map = std.AutoHashMap(i64, []u8).init(a);
    defer {
        var it = map.iterator();
        while (it.next()) |e| a.free(e.value_ptr.*);
        map.deinit();
    }
    for ([_]struct { x: i32, id: ids.Id }{ .{ .x = 0, .id = ids.flowing_lava }, .{ .x = 1, .id = ids.lava }, .{ .x = 5, .id = ids.coal_ore } }) |e| {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, e.x, 0);
        defer ch.destroy(a);
        var s = chunk_mod.Section{};
        s.setBlock(0, 0, 0, e.id);
        ch.sections[0] = s;
        const enc = try ch.encode(a);
        defer a.free(enc);
        try map.put(Mem.key(e.x, 0), try a.dupe(u8, enc));
    }
    Mem.store = map;
    const src = Source{ .ctx = @ptrCast(&Mem.store), .getFn = Mem.get };

    var c = conn_mod.Conn.init(a, std.testing.io, .{}, 1);
    defer c.deinit();
    c.state = .play;
    try completeLogin(&c, src, 0, 0, 0, 1, true);
    {
        const burst = try c.takeOutput(); // drain burst
        defer a.free(burst);
    }
    try std.testing.expect(c.sent.contains(Mem.key(0, 0)));
    try std.testing.expect(c.sent.contains(Mem.key(1, 0)));
    try std.testing.expectEqual(@as(usize, 2), c.sent.count());

    // helper: feed a serverbound position frame
    const feedPos = struct {
        fn run(conn: *conn_mod.Conn, x: f64) !void {
            var pb: [48]u8 = undefined;
            var w = codec.PacketWriter.init(&pb);
            try w.writeDouble(x);
            try w.writeDouble(65.0); // stance
            try w.writeDouble(64.0);
            try w.writeDouble(8.5);
            try w.writeFloat(0);
            try w.writeFloat(0);
            try w.writeByte(1);
            var pf: [64]u8 = undefined;
            try conn.feedData(try codec.framePacket(0x06, w.written(), &pf));
            while (try conn.poll()) |f| _ = try conn.handleFrame(f);
        }
    }.run;

    // same-chunk move: no dirty, no output
    try feedPos(&c, 9.5);
    try std.testing.expect(!c.chunks_dirty);
    {
        const empty = try c.takeOutput();
        defer a.free(empty);
        try std.testing.expectEqual(@as(usize, 0), empty.len);
    }

    // cross-chunk move to chunk 5
    try feedPos(&c, 88.5);
    try std.testing.expect(c.chunks_dirty);
    try syncPlayerChunks(&c, src, 0, 1, true);
    const out = try c.takeOutput();
    defer a.free(out);
    // expect: 2 unloads (0,0),(1,0) + 1 bulk with (5,0)
    var r = codec.PacketReader.init(out);
    var chunk_ids: [4]i32 = undefined;
    var nids: usize = 0;
    var bulk_cols: [2]i32 = .{ -99, -99 };
    var nbulk: usize = 0;
    while (r.remaining() > 0) {
        const h = try codec.decodeFrame(&r);
        chunk_ids[nids] = h.id;
        nids += 1;
        if (h.id == 0x21) {
            _ = try r.readInt();
            _ = try r.readInt();
            _ = try r.readBool();
            _ = try r.readUShort();
            _ = try r.readUShort();
            const clen = try r.readInt();
            _ = try r.readBytes(@intCast(clen));
        } else if (h.id == 0x26) {
            const n = try r.readShort();
            const dl = try r.readInt();
            _ = try r.readBool();
            _ = try r.readBytes(@intCast(dl));
            var k: usize = 0;
            while (k < n) : (k += 1) {
                bulk_cols[nbulk] = try r.readInt();
                _ = try r.readInt();
                _ = try r.readUShort();
                _ = try r.readUShort();
                nbulk += 1;
            }
        } else {
            return error.UnexpectedFrame;
        }
    }
    try std.testing.expectEqualSlices(i32, &[_]i32{ 0x21, 0x21, 0x26 }, chunk_ids[0..nids]);
    try std.testing.expectEqual(@as(usize, 1), nbulk);
    try std.testing.expectEqual(@as(i32, 5), bulk_cols[0]);
    try std.testing.expect(c.sent.contains(Mem.key(5, 0)));
    try std.testing.expectEqual(@as(usize, 1), c.sent.count());
    try std.testing.expect(!c.chunks_dirty);

    // sync with no movement: silent
    try syncPlayerChunks(&c, src, 0, 1, true);
    {
        const empty2 = try c.takeOutput();
        defer a.free(empty2);
        try std.testing.expectEqual(@as(usize, 0), empty2.len);
    }

    // client settings clamp
    {
        var sb: [32]u8 = undefined;
        var w = codec.PacketWriter.init(&sb);
        try w.writeString("en_US");
        try w.writeByte(99);
        try w.writeByte(0);
        try w.writeByte(1);
        try w.writeByte(1);
        try w.writeByte(0x40);
        var sf: [48]u8 = undefined;
        try c.feedData(try codec.framePacket(0x15, w.written(), &sf));
        while (try c.poll()) |f| _ = try c.handleFrame(f);
        try std.testing.expectEqual(@as(?u8, 16), c.client_view);
    }

    // respawn request -> full resync: respawn + unload(5,0) + burst(0,0),(1,0) + poslook
    {
        var rb: [8]u8 = undefined;
        var w = codec.PacketWriter.init(&rb);
        try w.writeByte(0);
        var rf: [16]u8 = undefined;
        try c.feedData(try codec.framePacket(0x16, w.written(), &rf));
        while (try c.poll()) |f| _ = try c.handleFrame(f);
        try std.testing.expect(c.force_resync);
        try syncPlayerChunks(&c, src, 0, 1, true);
        const rout = try c.takeOutput();
        defer a.free(rout);
        var rr = codec.PacketReader.init(rout);
        const rh0 = try codec.decodeFrame(&rr);
        try std.testing.expectEqual(@as(i32, 0x07), rh0.id);
        _ = try rr.readInt(); // dimension
        _ = try rr.readByte(); // difficulty
        _ = try rr.readByte(); // gamemode
        _ = try rr.readString(); // level type
        const rh1 = try codec.decodeFrame(&rr);
        try std.testing.expectEqual(@as(i32, 0x21), rh1.id);
        _ = try rr.readInt(); // x
        _ = try rr.readInt(); // z
        _ = try rr.readBool(); // groundUp
        _ = try rr.readUShort(); // primary
        _ = try rr.readUShort(); // add
        const uclen = try rr.readInt();
        _ = try rr.readBytes(@intCast(uclen));
        const rh2 = try codec.decodeFrame(&rr);
        try std.testing.expectEqual(@as(i32, 0x26), rh2.id);
        const bcount = try rr.readShort();
        try std.testing.expectEqual(@as(i16, 2), bcount);
        const bdlen = try rr.readInt();
        _ = try rr.readBool();
        _ = try rr.readBytes(@intCast(bdlen));
        var bi: usize = 0;
        while (bi < 2) : (bi += 1) {
            _ = try rr.readInt();
            _ = try rr.readInt();
            _ = try rr.readUShort();
            _ = try rr.readUShort();
        }
        const rh3 = try codec.decodeFrame(&rr);
        try std.testing.expectEqual(@as(i32, 0x08), rh3.id);
        try std.testing.expect(c.sent.contains(Mem.key(0, 0)));
        try std.testing.expect(c.sent.contains(Mem.key(1, 0)));
        try std.testing.expectEqual(@as(usize, 2), c.sent.count());
        try std.testing.expect(!c.force_resync);
    }
}

test "applyBlock roundtrips through the store" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();

    // seed chunk (0,0): section 0 all stone(1)
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        var s = chunk_mod.Section{};
        for (&s.blocks) |*b| b.* = ids.stone;
        ch.sections[0] = s;
        try pool.putChunk(a, ch);
        try pool.flushAll();
    }
    // break one block (section 0, local (3,1,4) -> y=1)
    try applyBlock(pool, a, 3, 1, 4, ids.air, 0);
    {
        const got = try pool.getChunk(a, 0, 0, 0);
        try std.testing.expect(got != null);
        defer got.?.destroy(a);
        const idx = chunk_mod.Section.index(3, 1, 4);
        try std.testing.expectEqual(ids.air, got.?.sections[0].?.blocks[idx]);
        try std.testing.expectEqual(ids.stone, got.?.sections[0].?.blocks[idx + 1]);
    }
    // place into an empty section creates it (with air elsewhere)
    try applyBlock(pool, a, 0, 200, 0, ids.planks, 2);
    {
        const got = try pool.getChunk(a, 0, 0, 0);
        defer {
            if (got) |g| g.destroy(a);
        }
        try std.testing.expect(got != null);
        try std.testing.expect(got.?.sections[12] != null);
        const s = &got.?.sections[12].?;
        try std.testing.expectEqual(ids.planks, s.blocks[chunk_mod.Section.index(0, 8, 0)]);
        try std.testing.expectEqual(@as(u4, 2), chunk_mod.Section.getNibble(&s.meta, chunk_mod.Section.index(0, 8, 0)));
        try std.testing.expectEqual(ids.air, s.blocks[1]);
    }
    // breaking air in an empty section is a no-op (no section created)
    try applyBlock(pool, a, 0, 16, 0, ids.air, 0);
    {
        const got = try pool.getChunk(a, 0, 0, 0);
        defer {
            if (got) |g| g.destroy(a);
        }
        try std.testing.expect(got.?.sections[1] == null);
    }
    // missing chunk: no crash, no-op
    try applyBlock(pool, a, 999, 64, 999, ids.stone, 0);
}
