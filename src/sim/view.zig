//! View-distance chunk delivery: spiral-order initial burst via bulk packets.
//!
//! Login flow (groundUp=true full columns only):
//!   JoinGame -> SpawnPosition -> MapChunkBulk(s) -> PlayerPosLook.
//! Re-sending an existing groundUp column leaks client memory, so each
//! column is sent at most once per connection (tracked resend is P-next
//! with unload packets, which chunks.zig already encodes).

const std = @import("std");
const packet_sink = @import("packet_sink.zig");
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

const profile = @import("../version.zig");

pub const max_bulk_cols: usize = profile.meta.max_bulk_columns;
pub const max_view_radius = 16;
pub const max_column_bytes: usize = profile.meta.max_column_bytes;

pub const ColPos = struct { x: i32, z: i32 };

/// Send explicit columns (spiral order preferred), skipping + recording via
/// the conn sent-set. Each column goes out at most once per unload cycle.
/// `budget` caps pool reads (null = unlimited): the 1Hz hole-heal rescan
/// passes a small budget so a serve thread never stalls in store reads
/// while generation is active (spiral order => nearest holes heal first).
/// Login/movement bursts pass null (whole disk, one shot).
pub fn sendColumns(
    conn: *conn_mod.Conn,
    sink: packet_sink.PacketSink,
    src: Source,
    dim: u8,
    positions: []const ColPos,
    sky: bool,
    budget: ?usize,
) !void {
    // Reusable conn-owned raw scratch (never-reset arena: per-call allocs
    // here leak until process exit — see Conn.bulk_raw). Compression/work
    // buffers belong to the profile sink and are sized/grown there.
    const a = conn.allocator;
    if (conn.bulk_raw.len == 0) {
        const raw = try a.alloc(u8, max_bulk_cols * max_column_bytes);
        errdefer a.free(raw);
        conn.bulk_raw = raw;
    }
    const raw_all = conn.bulk_raw;
    // Transient per-column work (ZC1 bytes, decoded chunks, bulk frames)
    // uses a per-column scratch arena, NOT conn.allocator (a never-reset
    // arena leaks every free until process exit) and NOT one shared frame
    // arena either: pool.get reads whole SST files per lookup, so a single
    // arena for the whole 289-column login burst pins every file image at
    // once (~1GB+ transient that only drops at the end of the call).
    // Only conn-owned scratch (above) and the sent-set outlive one column.
    var cols: [max_bulk_cols]packet_sink.BulkColumn = undefined;
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
        const layout = try sink.encodeColumn(ch, sky, raw_all[raw_len..]);
        cols[ncols] = .{ .x = pos.x, .z = pos.z, .primary = layout.primary, .add = layout.add };
        ncols += 1;
        raw_len += layout.len;
        try conn.sent.put(k, {});
        if (ncols == max_bulk_cols) {
            try sink.sendBulk(cols[0..ncols], raw_all[0..raw_len], sky);
            ncols = 0;
            raw_len = 0;
        }
    }
    if (ncols > 0) {
        try sink.sendBulk(cols[0..ncols], raw_all[0..raw_len], sky);
    }
}

/// Send the stored columns of the view disk around (cx,cz) in spiral order
/// (batched into bulk packets). Holes are skipped (async gen fills them;
/// serveConn retries when the pool sequence advances).
pub fn resyncDisk(
    conn: *conn_mod.Conn,
    sink: packet_sink.PacketSink,
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
        try sendColumns(conn, sink, src, dim, list[0..n], sky, budget);
    }
}

/// Send all stored columns around (cx,cz) in spiral order, batched into bulk
/// packets, then queue PlayerPosLook. Missing columns are skipped.
pub fn completeLogin(
    conn: *conn_mod.Conn,
    sink: packet_sink.PacketSink,
    source: ?Source,
    dim: u8,
    cx: i32,
    cz: i32,
    radius: u8,
    sky: bool,
) !void {
    try resyncDisk(conn, sink, source, dim, cx, cz, radius, sky, null);
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
    sink: packet_sink.PacketSink,
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
        try fullResync(conn, sink, source, dim, cc.cx, cc.cz, r, sky);
        return;
    }
    const sc = conn.sent_center orelse {
        // no baseline center (shouldn't happen) — treat as full burst
        try completeLogin(conn, sink, source, dim, cc.cx, cc.cz, r, sky);
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
    for (left[0..n_left]) |c| try sink.unloadChunk(c.x, c.z);
    if (source) |src| {
        try sendColumns(conn, sink, src, dim, entered[0..n_entered], sky, null);
    }
    conn.sent_center = .{ .cx = cc.cx, .cz = cc.cz };
    conn.chunks_dirty = false;
}

/// Respawn: Respawn packet + unload-all + full burst + PosLook.
pub fn fullResync(
    conn: *conn_mod.Conn,
    sink: packet_sink.PacketSink,
    source: ?Source,
    dim: u8,
    cx: i32,
    cz: i32,
    radius: u8,
    sky: bool,
) !void {
    try sink.respawn();
    var it = conn.sent.keyIterator();
    while (it.next()) |k| {
        const uk: u64 = @bitCast(k.*);
        const x: i32 = @as(i32, @bitCast(@as(u32, @truncate(uk >> 32))));
        const z: i32 = @as(i32, @bitCast(@as(u32, @truncate(uk))));
        try sink.unloadChunk(x, z);
    }
    conn.sent.clearRetainingCapacity();
    conn.sent_center = null;
    conn.baseline_sent = false;
    try completeLogin(conn, sink, source, dim, cx, cz, radius, sky);
}

/// Targeted column refresh: unload + single-column groundUp burst.
/// Used when stored data changed under an already-sent column (edit-path
/// light bleed into neighbors). Mirrors fullResync's unload-first order —
/// a live groundUp column must never be re-sent without an unload (the
/// client leaks the old column). No-op when the conn doesn't track the
/// column (its next sync sends it fresh).
pub fn resendColumn(
    conn: *conn_mod.Conn,
    sink: packet_sink.PacketSink,
    source: ?Source,
    dim: u8,
    cx: i32,
    cz: i32,
    sky: bool,
) !void {
    const k = conn_mod.Conn.sentKey(cx, cz);
    if (!conn.sent.contains(k)) return;
    try sink.unloadChunk(cx, cz);
    _ = conn.sent.remove(k);
    if (source) |src| {
        const one = [_]ColPos{.{ .x = cx, .z = cz }};
        try sendColumns(conn, sink, src, dim, &one, sky, null);
    }
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
        ids.air, ids.sapling, ids.flowing_water, ids.water, ids.flowing_lava, ids.lava, ids.leaves, ids.glass, ids.bed_block, ids.golden_rail, ids.detector_rail, ids.web, ids.tallgrass, ids.deadbush, ids.yellow_flower, ids.red_flower, ids.brown_mushroom, ids.red_mushroom, ids.stone_slab, ids.torch, ids.fire, ids.oak_stairs, ids.redstone_wire, ids.wheat_block, ids.standing_sign, ids.wooden_door_block, ids.ladder, ids.rail, ids.stone_stairs, ids.wall_sign, ids.lever, ids.stone_pressure_plate, ids.iron_door_block, ids.wooden_pressure_plate, ids.unlit_redstone_torch, ids.redstone_torch, ids.stone_button, ids.snow_layer, ids.ice, ids.reeds_block, ids.fence, ids.unpowered_repeater, ids.powered_repeater, ids.trapdoor, ids.pumpkin_stem, ids.melon_stem, ids.vine, ids.fence_gate, ids.brick_stairs, ids.stone_brick_stairs, ids.waterlily, ids.nether_brick_stairs, ids.nether_wart_block, ids.enchanting_table, ids.brewing_stand_block, ids.cauldron_block, ids.end_portal_frame, ids.wooden_slab, ids.sandstone_stairs, ids.tripwire_hook, ids.tripwire, ids.spruce_stairs, ids.birch_stairs, ids.jungle_stairs, ids.flower_pot_block, ids.carrots, ids.potatoes, ids.wooden_button, ids.skull_block, ids.light_weighted_pressure_plate, ids.heavy_weighted_pressure_plate, ids.unpowered_comparator, ids.powered_comparator, ids.daylight_detector, ids.quartz_stairs, ids.activator_rail, ids.stained_hardened_clay, ids.leaves2, ids.acacia_stairs, ids.dark_oak_stairs, ids.carpet, ids.double_plant, ids.cactus => false, // unassigned wire ids never become Ids: fromWire rejects them at the boundary
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

pub fn applyBlock(pool: *shard_mod.ShardPool, allocator: std.mem.Allocator, x: i32, y: u8, z: i32, id: ids.Id, meta: u4) !u8 {
    const cx = @divFloor(x, 16);
    const cz = @divFloor(z, 16);
    const key = store_mod.encodeKey(0, cx, cz);
    const raw = try pool.get(allocator, key) orelse return 0;
    defer allocator.free(raw);
    const ch = chunk_mod.Chunk.decode(allocator, raw) catch return 0;
    defer ch.destroy(allocator);
    const lx: usize = @intCast(@as(u4, @truncate(@as(u32, @bitCast(x & 15)))));
    const lz: usize = @intCast(@as(u4, @truncate(@as(u32, @bitCast(z & 15)))));
    const si: usize = @as(usize, y) >> 4;
    const section_created = ch.sections[si] == null;
    if (section_created) {
        if (id == ids.air) return 0; // breaking air in an empty section: no-op
        ch.sections[si] = chunk_mod.Section{};
    }
    const s = &ch.sections[si].?;
    const li: usize = chunk_mod.Section.index(@intCast(lx), @truncate(y & 15), @intCast(lz));
    const old_id = s.blocks[li];
    const old_light = chunk_mod.Section.getNibble(&s.light, li);
    // Cross-chunk border snapshots (both channels) BEFORE the mutation, so
    // edge deltas can be bled into neighbors afterwards. Only needed when
    // the edit can change light at all.
    const e_new = chunk_mod.emitLight(id);
    const e_old = chunk_mod.emitLight(old_id);
    const op_new = chunk_mod.lightOpacity(id);
    const op_old = chunk_mod.lightOpacity(old_id);
    const light_touched = e_new != e_old or op_new != op_old;
    var pre: [4][3][16][256]u8 = undefined;
    if (light_touched) {
        snapBorder(ch, .west, &pre[0][0], &pre[0][1], &pre[0][2]);
        snapBorder(ch, .east, &pre[1][0], &pre[1][1], &pre[1][2]);
        snapBorder(ch, .north, &pre[2][0], &pre[2][1], &pre[2][2]);
        snapBorder(ch, .south, &pre[3][0], &pre[3][1], &pre[3][2]);
    }
    s.blocks[li] = id;
    chunk_mod.Section.setNibble(&s.meta, li, meta);
    // Incremental relight (vanilla re-lights on block change; stale
    // nibbles would otherwise persist until the next full chunk resend).
    // Output-sensitive: a column snapshot + bounded BFS phases instead of
    // the old full-chunk re-flood per edit. Cross-chunk deltas bleed into
    // neighbors below (bleedBorders); diagonal lowering stays approximate.
    const q = try allocator.alloc(u32, 65536);
    defer allocator.free(q);
    relightEdit(ch, q, lx, y, lz, old_id, old_light, section_created);
    // Push border light deltas into adjacent chunks (vanilla floods across
    // borders; without this the neighbor keeps stale nibbles until resend).
    // Returns the touched-neighbor mask (bits 0-3: W,E,N,S; bits 4-7:
    // NW,NE,SW,SE) so callers can resend refreshed columns to trackers.
    var touched: u8 = 0;
    if (light_touched) {
        touched = bleedBorders(pool, allocator, q, ch, cx, cz, lx, lz, &pre) catch 0;
    }
    const enc = try ch.encode(allocator);
    defer allocator.free(enc);
    try pool.put(key, enc);
    return touched;
}

/// Incremental relight after a single-cell edit at local (lx,y,lz).
/// `old_id` / `old_light` (block channel) are pre-edit values at the
/// cell; the block itself is already overwritten. `section_created`
/// skips the column diff (a fresh section has no meaningful "before":
/// relight the whole section vertically, then flood outward).
fn relightEdit(ch: *chunk_mod.Chunk, q: []u32, lx: usize, y: u8, lz: usize, old_id: ids.Id, old_light: u4, section_created: bool) void {
    const new_id = ch.blockAt(lx, y, lz);
    const cell = chunk_mod.Chunk.packCell(lx, y, lz);
    const e_old = chunk_mod.emitLight(old_id);
    const e_new = chunk_mod.emitLight(new_id);
    const op_old = chunk_mod.lightOpacity(old_id);
    const op_new = chunk_mod.lightOpacity(new_id);
    // Transmissivity direction per channel (null cost = fully blocked).
    // A cost RISE with a preserved value is invisible to diffing but
    // strands sideways dependents — it forces maximal invalidation.
    const sc_old = chunk_mod.Chunk.skyCost(op_old);
    const sc_new = chunk_mod.Chunk.skyCost(op_new);
    const srose = if (sc_new) |nc| (if (sc_old) |oc| nc > oc else false) else (sc_old != null);
    const sdrop = if (sc_old) |oc| (if (sc_new) |nc| nc < oc else false) else (sc_new != null);
    // --- sky channel: snapshot the column, recompute it, diff ---
    var col_post: [256]u8 = undefined;
    if (section_created) {
        // Vertical exactness for the whole new section first (other
        // columns would otherwise keep the 0xFF default as stale light).
        for (0..16) |ez| {
            for (0..16) |ex| ch.relightColumn(ex, ez);
        }
        // Outflow into neighbors from the new section's bright cells.
        var seeds: [4096]u32 = undefined;
        var n_seeds: usize = 0;
        const s0: usize = (@as(usize, y) >> 4) * 16;
        for (0..16) |ly| {
            for (0..16) |ez| {
                for (0..16) |ex| {
                    const sec = ch.sections[(s0 + ly) >> 4] orelse continue;
                    const v = chunk_mod.Section.getNibble(&sec.sky, chunk_mod.Section.index(@intCast(ex), @intCast(ly), @intCast(ez)));
                    if (v > 1 and n_seeds < seeds.len) {
                        seeds[n_seeds] = chunk_mod.Chunk.packCell(ex, s0 + ly, ez);
                        n_seeds += 1;
                    }
                }
            }
        }
        ch.spreadLight(q, .sky, seeds[0..n_seeds]);
        // Block inflow: the new volume opens flood paths for existing
        // light (torch flood escaping upward through fresh air and back
        // down — without seeds here it stays dark while a full reflood
        // lights it). Seed the adjacent existing rows; creation is
        // monotone (light only rises through new space), so no
        // invalidation is needed, only raises.
        var bseeds: [512]u32 = undefined;
        var n_bseeds: usize = 0;
        if (s0 > 0) {
            var i: usize = 0;
            while (i < 256) : (i += 1) {
                bseeds[n_bseeds] = chunk_mod.Chunk.packCell(i & 15, s0 - 1, (i >> 4) & 15);
                n_bseeds += 1;
            }
        }
        if (s0 + 16 < 256) {
            var i: usize = 0;
            while (i < 256) : (i += 1) {
                bseeds[n_bseeds] = chunk_mod.Chunk.packCell(i & 15, s0 + 16, (i >> 4) & 15);
                n_bseeds += 1;
            }
        }
        ch.spreadLight(q, .block, bseeds[0..n_bseeds]);
    } else {
        var col_pre: [256]u8 = undefined;
        skyColumn(ch, lx, lz, &col_pre);
        ch.relightColumn(lx, lz);
        skyColumn(ch, lx, lz, &col_post);
        var raised: [256]u32 = undefined;
        var n_raised: usize = 0;
        var lowered: [256]chunk_mod.Chunk.CellValue = undefined;
        var n_lowered: usize = 0;
        var yy: usize = 0;
        while (yy < 256) : (yy += 1) {
            if (col_post[yy] > col_pre[yy]) {
                raised[n_raised] = chunk_mod.Chunk.packCell(lx, yy, lz);
                n_raised += 1;
            } else if (col_post[yy] < col_pre[yy]) {
                lowered[n_lowered] = .{ .cell = chunk_mod.Chunk.packCell(lx, yy, lz), .value = @truncate(col_pre[yy]) };
                n_lowered += 1;
            }
        }
        if (n_lowered > 0 or srose) {
            // Rewrite floors = the whole recomputed column (restores
            // anything phase A zeroes, then refloods sideways on top).
            var rewrite: [256]chunk_mod.Chunk.CellValue = undefined;
            for (0..256) |i| rewrite[i] = .{ .cell = chunk_mod.Chunk.packCell(lx, i, lz), .value = @truncate(col_post[i]) };
            var old_list: [257]chunk_mod.Chunk.CellValue = undefined;
            for (lowered[0..n_lowered], 0..) |lv, i| old_list[i] = lv;
            var n_old = n_lowered;
            if (srose) {
                // Transmissivity died at C (possibly with C's own value
                // preserved — invisible to value-diffing, fatal to skip:
                // sideways dependents would strand). Maximal flow seed.
                var upgraded = false;
                for (old_list[0..n_old]) |*lv| {
                    if (lv.cell == cell) {
                        lv.value = 15;
                        upgraded = true;
                    }
                }
                if (!upgraded) {
                    old_list[n_old] = .{ .cell = cell, .value = 15 };
                    n_old += 1;
                }
            }
            ch.unspreadLight(q, .sky, old_list[0..n_old], rewrite[0..]);
        }
        // Cheapened paths (cost dropped, values unchanged): C's outflow
        // reaches further — seed it (idempotent when idle).
        var do_raise = n_raised > 0;
        if (sdrop and !do_raise) {
            raised[n_raised] = cell;
            n_raised += 1;
            do_raise = true;
        } else if (sdrop) {
            var present = false;
            for (raised[0..n_raised]) |rc| if (rc == cell) {
                present = true;
            };
            if (!present and n_raised < raised.len) {
                raised[n_raised] = cell;
                n_raised += 1;
            }
        }
        if (do_raise) {
            ch.spreadLight(q, .sky, raised[0..n_raised]);
        }
    }
    // --- block channel: emission/opacity driven, single cell + BFS ---
    const sec = &ch.sections[@as(usize, y) >> 4].?;
    if (e_new != e_old) {
        // Emission pins the cell (vanilla: light AT an emitter = emission).
        chunk_mod.Section.setNibble(&sec.light, chunk_mod.Section.index(@intCast(lx), @truncate(y & 15), @intCast(lz)), e_new);
        if (e_new > e_old) {
            const one = [_]u32{cell};
            ch.spreadLight(q, .block, &one);
        } else {
            const old = [_]chunk_mod.Chunk.CellValue{.{ .cell = cell, .value = old_light }};
            const rw = [_]chunk_mod.Chunk.CellValue{.{ .cell = cell, .value = e_new }};
            ch.unspreadLight(q, .block, &old, &rw);
        }
    } else if (op_new != op_old) {
        // Opacity-only change: recompute the cell from neighbors +
        // emission at the NEW costs (best-of; opaque forces 0), then
        // drive phases off the delta plus transmissivity direction (a
        // cost rise with a preserved value strands sideways dependents
        // invisibly — same hole as sky, same maximal-flow cure).
        var best: u4 = e_new;
        if (op_new != 255) {
            const drop = chunk_mod.Chunk.blockCost(op_new).?;
            const dirs = [_][3]i32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
            for (dirs) |d| {
                const nx = @as(i32, @intCast(lx)) + d[0];
                const ny = @as(i32, y) + d[1];
                const nz = @as(i32, @intCast(lz)) + d[2];
                if (nx < 0 or nx > 15 or ny < 0 or ny > 255 or nz < 0 or nz > 15) continue;
                const nv: u4 = ch.getLightAt(@intCast(nx), @intCast(ny), @intCast(nz));
                if (nv > drop and nv - drop > best) best = nv - drop;
            }
        } else {
            best = 0;
        }
        const cur = chunk_mod.Section.getNibble(&sec.light, chunk_mod.Section.index(@intCast(lx), @truncate(y & 15), @intCast(lz)));
        const bc_old = chunk_mod.Chunk.blockCost(op_old);
        const bc_new = chunk_mod.Chunk.blockCost(op_new);
        const brose = if (bc_new) |nc| (if (bc_old) |oc| nc > oc else false) else (bc_old != null);
        const bdrop = if (bc_old) |oc| (if (bc_new) |nc| nc < oc else false) else (bc_new != null);
        if (best != cur) {
            chunk_mod.Section.setNibble(&sec.light, chunk_mod.Section.index(@intCast(lx), @truncate(y & 15), @intCast(lz)), best);
        }
        if (brose) {
            // Cost rose: maximal invalidation (value-preserving opacity
            // gains strand dependents invisibly — see sky path). Rewrite
            // restores the recomputed floor; reflood settles the rest.
            const old = [_]chunk_mod.Chunk.CellValue{.{ .cell = cell, .value = 15 }};
            const rw = [_]chunk_mod.Chunk.CellValue{.{ .cell = cell, .value = best }};
            ch.unspreadLight(q, .block, &old, &rw);
        } else if (best > cur) {
            const one = [_]u32{cell};
            ch.spreadLight(q, .block, &one);
        } else if (best < cur) {
            const old = [_]chunk_mod.Chunk.CellValue{.{ .cell = cell, .value = cur }};
            const rw = [_]chunk_mod.Chunk.CellValue{.{ .cell = cell, .value = best }};
            ch.unspreadLight(q, .block, &old, &rw);
        } else if (bdrop) {
            // Same value, cheaper paths: raise from the cell (explores
            // only strict increases — a handful of ops when idle).
            const one = [_]u32{cell};
            ch.spreadLight(q, .block, &one);
        }
    }
    // (No emission/opacity change: nothing to do. Column sky above already
    // handled the vertical; sideways flow is unchanged.)
}

/// Which border of a chunk faces a neighbor.
const BleedSide = enum { west, east, north, south };

/// Both channels of one border cell. Null sections read as engine-default
/// block 0; sky uses the heightmap (open air above the top solid reads
/// 15) so pre/post snapshots compare true values, not storage artifacts.
/// A stored all-air section and a missing one compare equal here.
fn bleedRead(ch: *const chunk_mod.Chunk, lx: usize, y: usize, lz: usize) [2]u4 {
    if (ch.sections[y >> 4]) |s| {
        const i = chunk_mod.Section.index(@intCast(lx), @intCast(y & 15), @intCast(lz));
        return .{ chunk_mod.Section.getNibble(&s.sky, i), chunk_mod.Section.getNibble(&s.light, i) };
    }
    const h: usize = ch.heights[lz * 16 + lx];
    return .{ if (y > h) @as(u4, 15) else 0, 0 };
}

/// Snapshot one border face (16 along × 256 high): both channels plus the
/// opacity the spots costs and transmissivity flips are derived from.
fn snapBorder(ch: *const chunk_mod.Chunk, side: BleedSide, sky: *[16][256]u8, blk: *[16][256]u8, op: *[16][256]u8) void {
    for (0..16) |a| {
        const lx: usize = switch (side) {
            .west => 0,
            .east => 15,
            else => a,
        };
        const lz: usize = switch (side) {
            .north => 0,
            .south => 15,
            else => a,
        };
        for (0..256) |y| {
            const v = bleedRead(ch, lx, y, lz);
            sky[a][y] = v[0];
            blk[a][y] = v[1];
            op[a][y] = chunk_mod.lightOpacity(ch.blockAt(lx, y, lz));
        }
    }
}

/// Write one channel nibble, creating the section on demand so open-air
/// borders still carry flood values. A fresh section is all air: run the
/// exact column rule over every column first (defaults would otherwise
/// strand underground 15s), mirroring the section_created path.
fn bleedWrite(nch: *chunk_mod.Chunk, nx: usize, y: usize, nz: usize, channel: chunk_mod.Chunk.LightChannel, v: u4) void {
    const si = y >> 4;
    if (nch.sections[si] == null) {
        nch.sections[si] = chunk_mod.Section{};
        for (0..16) |ex| {
            for (0..16) |ez| nch.relightColumn(ex, ez);
        }
    }
    const s = &nch.sections[si].?;
    const i = chunk_mod.Section.index(@intCast(nx), @intCast(y & 15), @intCast(nz));
    if (channel == .sky) {
        chunk_mod.Section.setNibble(&s.sky, i, v);
    } else {
        chunk_mod.Section.setNibble(&s.light, i, v);
    }
}

/// Push one border's edge deltas into the adjacent neighbor chunk:
/// raises via spread, lowers via unspread+reflood (same two-phase
/// contract as relightEdit). Returns the modified neighbor (owned) or
/// null when nothing changed / neighbor missing. Reuses the caller's BFS
/// queue (free: the same-chunk flood already drained it).
fn bleedSide(
    pool: *shard_mod.ShardPool,
    alloc: std.mem.Allocator,
    q: []u32,
    ch: *chunk_mod.Chunk,
    cx: i32,
    cz: i32,
    side: BleedSide,
    pre_sky: *const [16][256]u8,
    pre_blk: *const [16][256]u8,
    pre_op: *const [16][256]u8,
) !?*chunk_mod.Chunk {
    const ncx = cx + switch (side) {
        .west => @as(i32, -1),
        .east => 1,
        else => 0,
    };
    const ncz = cz + switch (side) {
        .north => @as(i32, -1),
        .south => 1,
        else => 0,
    };
    // Fast path: no edge delta, no neighbor I/O. Values alone are not
    // enough: opaque cells store the incoming top-face value, so an
    // air<->stone flip at the edge leaves identical nibbles while killing
    // (or opening) the flow. Opacity deltas trigger too.
    var touched = false;
    for (0..16) |a| {
        const lx: usize = switch (side) {
            .west => 0,
            .east => 15,
            else => a,
        };
        const lz: usize = switch (side) {
            .north => 0,
            .south => 15,
            else => a,
        };
        for (0..256) |y| {
            const v = bleedRead(ch, lx, y, lz);
            if (v[0] != pre_sky[a][y] or v[1] != pre_blk[a][y] or chunk_mod.lightOpacity(ch.blockAt(lx, y, lz)) != pre_op[a][y]) {
                touched = true;
                break;
            }
        }
        if (touched) break;
    }
    if (!touched) return null;
    const nkey = store_mod.encodeKey(0, ncx, ncz);
    const nraw = try pool.get(alloc, nkey) orelse return null;
    defer alloc.free(nraw);
    var nch = try chunk_mod.Chunk.decode(alloc, nraw);
    errdefer nch.destroy(alloc);
    var n_dirty = false;
    // Exact vertical sky for the adjacent row first (mirrors the
    // section_created path): stored nibbles alone can't distinguish a
    // stale-dark column from an enclosed one, and the unspread below
    // must not erase a column-ruled 15 it cannot rebuild.
    for (0..16) |a| {
        const nx: usize = switch (side) {
            .west => 15,
            .east => 0,
            else => a,
        };
        const nz: usize = switch (side) {
            .north => 15,
            .south => 0,
            else => a,
        };
        nch.relightColumn(nx, nz);
        n_dirty = true;
    }
    inline for ([2]chunk_mod.Chunk.LightChannel{ .sky, .block }) |channel| {
        const ci: usize = if (channel == .sky) 0 else 1;
        const pre = if (channel == .sky) pre_sky else pre_blk;
        var olds = try alloc.alloc(chunk_mod.Chunk.CellValue, 4096);
        defer alloc.free(olds);
        var rewrites = try alloc.alloc(chunk_mod.Chunk.CellValue, 4096);
        defer alloc.free(rewrites);
        var n_old: usize = 0;
        // Pass 1: lower. Invalidate what flowed through removed edge
        // light (same-nibble opacity flips included). Only cells strictly
        // dimmer than the old flow can depend on it (spread costs >= 1);
        // the rest are sustained from elsewhere and must be left alone —
        // phase A never zeroes seed cells, so an unconditional rewrite
        // would strand a stale floor here. The rewrite floor is the
        // cell's own emission (always <= true): reflood rebuilds inflows
        // from survivors.
        for (0..16) |a| {
            const lx: usize = switch (side) {
                .west => 0,
                .east => 15,
                else => a,
            };
            const lz: usize = switch (side) {
                .north => 0,
                .south => 15,
                else => a,
            };
            const nx: usize = switch (side) {
                .west => 15,
                .east => 0,
                else => a,
            };
            const nz: usize = switch (side) {
                .north => 15,
                .south => 0,
                else => a,
            };
            for (0..256) |y| {
                const post: u4 = @truncate(bleedRead(ch, lx, y, lz)[ci]);
                const pre_v: u4 = @truncate(pre[a][y]);
                const plo: u8 = pre_op[a][y];
                const qlo: u8 = chunk_mod.lightOpacity(ch.blockAt(lx, y, lz));
                if (!(post < pre_v or (post == pre_v and qlo > plo))) continue;
                const cur: u4 = @truncate(bleedRead(nch, nx, y, nz)[ci]);
                if (cur >= pre_v) continue;
                if (n_old >= olds.len) continue;
                const own: u4 = if (channel == .block) chunk_mod.emitLight(nch.blockAt(nx, y, nz)) else cur;
                olds[n_old] = .{ .cell = chunk_mod.Chunk.packCell(nx, y, nz), .value = pre_v };
                rewrites[n_old] = .{ .cell = chunk_mod.Chunk.packCell(nx, y, nz), .value = own };
                n_old += 1;
                n_dirty = true;
            }
        }
        if (n_old > 0) nch.unspreadLight(q, channel, olds[0..n_old], rewrites[0..n_old]);
        // Pass 2: raise from live post-unspread values (unspread may have
        // zeroed cells this pass needs to rebuild; computing seeds before
        // it would strand them when spread skips zeroed cells).
        var seeds = try alloc.alloc(u32, 4096);
        defer alloc.free(seeds);
        var n_seeds: usize = 0;
        for (0..16) |a| {
            const lx: usize = switch (side) {
                .west => 0,
                .east => 15,
                else => a,
            };
            const lz: usize = switch (side) {
                .north => 0,
                .south => 15,
                else => a,
            };
            const nx: usize = switch (side) {
                .west => 15,
                .east => 0,
                else => a,
            };
            const nz: usize = switch (side) {
                .north => 15,
                .south => 0,
                else => a,
            };
            // Sky never flows out of opaque cells (mirrors bfsRaise).
            if (channel == .sky and chunk_mod.lightOpacity(ch.blockAt(lx, 128, lz)) == 255) {
                // Per-y opacity check below handles varying columns; this
                // is just a fast reject when the whole column is solid.
                var any_open = false;
                for (0..256) |yy| {
                    if (chunk_mod.lightOpacity(ch.blockAt(lx, yy, lz)) != 255) {
                        any_open = true;
                        break;
                    }
                }
                if (!any_open) continue;
            }
            for (0..256) |y| {
                const post: u4 = @truncate(bleedRead(ch, lx, y, lz)[ci]);
                if (post == 0) continue;
                if (channel == .sky and chunk_mod.lightOpacity(ch.blockAt(lx, y, lz)) == 255) continue;
                const cur: u4 = @truncate(bleedRead(nch, nx, y, nz)[ci]);
                const op = chunk_mod.lightOpacity(nch.blockAt(nx, y, nz));
                const cost = (if (channel == .sky) chunk_mod.Chunk.skyCost(op) else chunk_mod.Chunk.blockCost(op)) orelse continue;
                const cand: u4 = if (post > cost) post - cost else continue;
                if (cand <= cur) continue;
                bleedWrite(nch, nx, y, nz, channel, cand);
                if (n_seeds < seeds.len) {
                    seeds[n_seeds] = chunk_mod.Chunk.packCell(nx, y, nz);
                    n_seeds += 1;
                }
                n_dirty = true;
            }
        }
        if (n_seeds > 0) nch.spreadLight(q, channel, seeds[0..n_seeds]);
    }
    if (!n_dirty) {
        nch.destroy(alloc);
        return null;
    }
    return nch;
}

/// Raise-only second hop into a diagonal neighbor (corner edits): seed the
/// diagonal corner-adjacent cell from the two edge-neighbor cells that feed
/// it (post-bleed values, re-read from the store). Diagonal lowering stays
/// an approximation.
fn bleedDiagonal(
    pool: *shard_mod.ShardPool,
    alloc: std.mem.Allocator,
    q: []u32,
    dcx: i32,
    dcz: i32,
    dlx: usize,
    dlz: usize,
    s1cx: i32,
    s1cz: i32,
    s1lx: usize,
    s1lz: usize,
    s2cx: i32,
    s2cz: i32,
    s2lx: usize,
    s2lz: usize,
) !bool {
    const dkey = store_mod.encodeKey(0, dcx, dcz);
    const draw = try pool.get(alloc, dkey) orelse return false;
    defer alloc.free(draw);
    var dch = try chunk_mod.Chunk.decode(alloc, draw);
    defer dch.destroy(alloc);
    const s1raw = try pool.get(alloc, store_mod.encodeKey(0, s1cx, s1cz)) orelse return false;
    defer alloc.free(s1raw);
    var s1ch = try chunk_mod.Chunk.decode(alloc, s1raw);
    defer s1ch.destroy(alloc);
    const s2raw = try pool.get(alloc, store_mod.encodeKey(0, s2cx, s2cz)) orelse return false;
    defer alloc.free(s2raw);
    var s2ch = try chunk_mod.Chunk.decode(alloc, s2raw);
    defer s2ch.destroy(alloc);
    var dirty = false;
    // Exact vertical sky for the corner column first (mirrors the edge
    // path: stored nibbles alone can't distinguish stale-dark from
    // enclosed, and unspread below must not erase a column-ruled value
    // it cannot rebuild).
    dch.relightColumn(dlx, dlz);
    dirty = true;
    inline for ([2]chunk_mod.Chunk.LightChannel{ .sky, .block }) |channel| {
        const ci: usize = if (channel == .sky) 0 else 1;
        // Lower first: the diagonal cell may hold light that only flowed
        // through the corner being edited away. No pre snapshot exists
        // here, so gate on the live value: only cells dimmer than their
        // own level can depend on removed inflow (same contract as the
        // edge path's cur < pre gate, with the live value standing in).
        var olds: [64]chunk_mod.Chunk.CellValue = undefined;
        var rewrites: [64]chunk_mod.Chunk.CellValue = undefined;
        var n_old: usize = 0;
        for (0..256) |y| {
            const cur: u4 = @truncate(bleedRead(dch, dlx, y, dlz)[ci]);
            if (cur == 0) continue;
            // Only unspread when the corner edit actually dropped light:
            // recompute the best inflow from the post-bleed edge chunks
            // and invalidate when the stored value exceeds it.
            const v1: u4 = @truncate(bleedRead(s1ch, s1lx, y, s1lz)[ci]);
            const v2: u4 = @truncate(bleedRead(s2ch, s2lx, y, s2lz)[ci]);
            const best: u4 = @max(v1, v2);
            const dop = chunk_mod.lightOpacity(dch.blockAt(dlx, y, dlz));
            const cost = (if (channel == .sky) chunk_mod.Chunk.skyCost(dop) else chunk_mod.Chunk.blockCost(dop)) orelse continue;
            const support: u4 = if (best > cost) best - cost else 0;
            if (cur <= support) continue;
            const own: u4 = if (channel == .block) chunk_mod.emitLight(dch.blockAt(dlx, y, dlz)) else cur;
            if (n_old >= olds.len) continue;
            olds[n_old] = .{ .cell = chunk_mod.Chunk.packCell(dlx, y, dlz), .value = cur };
            rewrites[n_old] = .{ .cell = chunk_mod.Chunk.packCell(dlx, y, dlz), .value = own };
            n_old += 1;
            dirty = true;
        }
        if (n_old > 0) dch.unspreadLight(q, channel, olds[0..n_old], rewrites[0..n_old]);
        // Raise from post-bleed edge values (re-read live: unspread may
        // have zeroed cells this pass needs to rebuild).
        var seeds: [64]u32 = undefined;
        var n_seeds: usize = 0;
        for (0..256) |y| {
            const v1: u4 = @truncate(bleedRead(s1ch, s1lx, y, s1lz)[ci]);
            const v2: u4 = @truncate(bleedRead(s2ch, s2lx, y, s2lz)[ci]);
            const best: u4 = @max(v1, v2);
            if (best == 0) continue;
            const dop = chunk_mod.lightOpacity(dch.blockAt(dlx, y, dlz));
            const cost = (if (channel == .sky) chunk_mod.Chunk.skyCost(dop) else chunk_mod.Chunk.blockCost(dop)) orelse continue;
            const cand: u4 = if (best > cost) best - cost else continue;
            const cur: u4 = @truncate(bleedRead(dch, dlx, y, dlz)[ci]);
            if (cand <= cur) continue;
            bleedWrite(dch, dlx, y, dlz, channel, cand);
            if (n_seeds < seeds.len) {
                seeds[n_seeds] = chunk_mod.Chunk.packCell(dlx, y, dlz);
                n_seeds += 1;
            }
            dirty = true;
        }
        if (n_seeds > 0) dch.spreadLight(q, channel, seeds[0..n_seeds]);
    }
    if (!dirty) return false;
    const enc = try dch.encode(alloc);
    defer alloc.free(enc);
    try pool.put(dkey, enc);
    return true;
}

/// Bleed border deltas of an edited chunk into adjacent neighbors.
/// `pre` holds the pre-edit border faces (both channels); `lx`/`lz` locate
/// the edit. Owned neighbor chunks are written back before return.
/// Returns the touched-neighbor mask (bits 0-3: W,E,N,S; bits 4-7:
/// NW,NE,SW,SE) for targeted viewer resends.
fn bleedBorders(
    pool: *shard_mod.ShardPool,
    alloc: std.mem.Allocator,
    q: []u32,
    ch: *chunk_mod.Chunk,
    cx: i32,
    cz: i32,
    lx: usize,
    lz: usize,
    pre: *const [4][3][16][256]u8,
) !u8 {
    // Forward FIRST: push edited-chunk border deltas into neighbors.
    // This must precede the reverse pull below: on removal the neighbors
    // still hold stale light, and pulling first would resurrect it into
    // the edited chunk (then forward re-bleeds the ghost as 11s).
    var touched: u8 = 0;
    const west = try bleedSide(pool, alloc, q, ch, cx, cz, .west, &pre[0][0], &pre[0][1], &pre[0][2]);
    const east = try bleedSide(pool, alloc, q, ch, cx, cz, .east, &pre[1][0], &pre[1][1], &pre[1][2]);
    const north = try bleedSide(pool, alloc, q, ch, cx, cz, .north, &pre[2][0], &pre[2][1], &pre[2][2]);
    const south = try bleedSide(pool, alloc, q, ch, cx, cz, .south, &pre[3][0], &pre[3][1], &pre[3][2]);
    // Write back modified edge neighbors first, so the reverse + diagonal
    // hops below read post-bleed values.
    if (west) |nch| {
        const enc = try nch.encode(alloc);
        defer alloc.free(enc);
        try pool.put(store_mod.encodeKey(0, cx - 1, cz), enc);
        nch.destroy(alloc);
        touched |= 1 << 0;
    }
    if (east) |nch| {
        const enc = try nch.encode(alloc);
        defer alloc.free(enc);
        try pool.put(store_mod.encodeKey(0, cx + 1, cz), enc);
        nch.destroy(alloc);
        touched |= 1 << 1;
    }
    if (north) |nch| {
        const enc = try nch.encode(alloc);
        defer alloc.free(enc);
        try pool.put(store_mod.encodeKey(0, cx, cz - 1), enc);
        nch.destroy(alloc);
        touched |= 1 << 2;
    }
    if (south) |nch| {
        const enc = try nch.encode(alloc);
        defer alloc.free(enc);
        try pool.put(store_mod.encodeKey(0, cx, cz + 1), enc);
        nch.destroy(alloc);
        touched |= 1 << 3;
    }
    // Reverse pass: pull cross-border inflow into the edited chunk from
    // post-bleed neighbors (same-chunk relight above cannot see across
    // the border; e.g. an under-roof cell whose only open direction faces
    // the neighbor). Reads post-forward values so removals don't resurrect
    // stale light. Idempotent: skips when nothing flows.
    for ([2]chunk_mod.Chunk.LightChannel{ .sky, .block }) |channel| {
        const ci: usize = if (channel == .sky) 0 else 1;
        var seeds: [4096]u32 = undefined;
        var n_seeds: usize = 0;
        const sides = [_]struct {
            dx: i32,
            dz: i32,
            border: BleedSide,
        }{
            .{ .dx = -1, .dz = 0, .border = .west },
            .{ .dx = 1, .dz = 0, .border = .east },
            .{ .dx = 0, .dz = -1, .border = .north },
            .{ .dx = 0, .dz = 1, .border = .south },
        };
        for (sides) |s| {
            const nraw = try pool.get(alloc, store_mod.encodeKey(0, cx + s.dx, cz + s.dz)) orelse continue;
            defer alloc.free(nraw);
            var nch = try chunk_mod.Chunk.decode(alloc, nraw);
            defer nch.destroy(alloc);
            for (0..16) |a| {
                const ex: usize = switch (s.border) {
                    .west => 0,
                    .east => 15,
                    else => a,
                };
                const ez: usize = switch (s.border) {
                    .north => 0,
                    .south => 15,
                    else => a,
                };
                const nx: usize = switch (s.border) {
                    .west => 15,
                    .east => 0,
                    else => a,
                };
                const nz: usize = switch (s.border) {
                    .north => 15,
                    .south => 0,
                    else => a,
                };
                // Sky never flows out of opaque cells (mirrors bfsRaise).
                if (channel == .sky and chunk_mod.lightOpacity(nch.blockAt(nx, 128, nz)) == 255) {
                    var any_open = false;
                    for (0..256) |yy| {
                        if (chunk_mod.lightOpacity(nch.blockAt(nx, yy, nz)) != 255) {
                            any_open = true;
                            break;
                        }
                    }
                    if (!any_open) continue;
                }
                for (0..256) |y| {
                    const nv: u4 = @truncate(bleedRead(nch, nx, y, nz)[ci]);
                    if (nv == 0) continue;
                    if (channel == .sky and chunk_mod.lightOpacity(nch.blockAt(nx, y, nz)) == 255) continue;
                    const op = chunk_mod.lightOpacity(ch.blockAt(ex, y, ez));
                    const cost = (if (channel == .sky) chunk_mod.Chunk.skyCost(op) else chunk_mod.Chunk.blockCost(op)) orelse continue;
                    const cand: u4 = if (nv > cost) nv - cost else continue;
                    const cur: u4 = @truncate(bleedRead(ch, ex, y, ez)[ci]);
                    if (cand <= cur) continue;
                    bleedWrite(ch, ex, y, ez, channel, cand);
                    if (n_seeds < seeds.len) {
                        seeds[n_seeds] = chunk_mod.Chunk.packCell(ex, y, ez);
                        n_seeds += 1;
                    }
                }
            }
        }
        if (n_seeds > 0) ch.spreadLight(q, channel, seeds[0..n_seeds]);
    }
    // Diagonal raise hop for exact-corner edits with a changed corner cell.
    // (Single-edge changes are covered: the unchanged side contributes its
    // stored values, re-read here.)
    const on_w = lx == 0;
    const on_e = lx == 15;
    const on_n = lz == 0;
    const on_s = lz == 15;
    // Diagonal raise hop for exact-corner edits with a changed corner cell.
    // (Single-edge changes are covered: the unchanged side contributes its
    // stored values, re-read here.)
    if (on_w and on_n and cornerCellChanged(ch, 0, 0, &pre[0], 0, &pre[2], 0)) {
        if (try bleedDiagonal(pool, alloc, q, cx - 1, cz - 1, 15, 15, cx - 1, cz, 15, 0, cx, cz - 1, 0, 15)) touched |= 1 << 4;
    } else if (on_e and on_n and cornerCellChanged(ch, 15, 0, &pre[1], 0, &pre[2], 15)) {
        if (try bleedDiagonal(pool, alloc, q, cx + 1, cz - 1, 0, 15, cx + 1, cz, 0, 0, cx, cz - 1, 15, 15)) touched |= 1 << 5;
    } else if (on_w and on_s and cornerCellChanged(ch, 0, 15, &pre[0], 15, &pre[3], 0)) {
        if (try bleedDiagonal(pool, alloc, q, cx - 1, cz + 1, 15, 0, cx - 1, cz, 15, 15, cx, cz + 1, 0, 0)) touched |= 1 << 6;
    } else if (on_e and on_s and cornerCellChanged(ch, 15, 15, &pre[1], 15, &pre[3], 15)) {
        if (try bleedDiagonal(pool, alloc, q, cx + 1, cz + 1, 0, 0, cx + 1, cz, 0, 15, cx, cz + 1, 15, 0)) touched |= 1 << 7;
    }
    return touched;
}

/// True when the edited corner cell changed on either channel (gates the
/// diagonal hop; unchanged corners imply unchanged diagonal inflow).
fn cornerCellChanged(
    ch: *chunk_mod.Chunk,
    clx: usize,
    clz: usize,
    pre_a: *const [3][16][256]u8,
    aa: usize,
    pre_b: *const [3][16][256]u8,
    ab: usize,
) bool {
    for (0..256) |y| {
        const v = bleedRead(ch, clx, y, clz);
        if (v[0] != pre_a[0][aa][y] or v[1] != pre_a[1][aa][y]) return true;
        if (v[0] != pre_b[0][ab][y] or v[1] != pre_b[1][ab][y]) return true;
        const op: u8 = chunk_mod.lightOpacity(ch.blockAt(clx, y, clz));
        if (op != pre_a[2][aa][y] or op != pre_b[2][ab][y]) return true;
    }
    return false;
}

/// Read one column's sky nibbles (top-down) into `out`.
fn skyColumn(ch: *const chunk_mod.Chunk, lx: usize, lz: usize, out: *[256]u8) void {
    var y: usize = 0;
    while (y < 256) : (y += 1) {
        if (ch.sections[y >> 4]) |s| {
            out[y] = chunk_mod.Section.getNibble(&s.sky, chunk_mod.Section.index(@intCast(lx), @truncate(y & 15), @intCast(lz)));
        } else {
            out[y] = 0;
        }
    }
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
    const sink_test = @import("packet_sink_test.zig");
    var rec = sink_test.Recorder{};
    const sink = rec.sink();
    try completeLogin(&c, sink, src, 0, 0, 0, 1, true);

    // The shared scheduler encoded the two present columns in spiral order
    // and flushed them as one semantic bulk. The fake sink does not queue
    // frames; byte-level v5 encoding is covered by net/packet_sink.zig.
    try std.testing.expectEqualSlices(
        sink_test.Event,
        &[_]sink_test.Event{ .encode, .encode, .bulk },
        rec.eventSlice(),
    );
    try std.testing.expectEqual(@as(usize, 1), rec.bulks);
    try std.testing.expectEqual(@as(usize, 2), rec.bulk_n);
    try std.testing.expectEqual(@as(i32, 0), rec.bulk_cols[0].x);
    try std.testing.expectEqual(@as(i32, 1), rec.bulk_cols[1].x);
    try std.testing.expect(rec.bulk_sky);
    try std.testing.expectEqual(@as(usize, 2), c.sent.count());

    // PlayerPosLook still closes the login on the connection itself.
    const out = try c.takeOutput();
    defer a.free(out);
    const codec = @import("../net/codec.zig");
    var r = codec.PacketReader.init(out);
    const h0 = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 0x08), h0.id);
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
    const sink_test = @import("packet_sink_test.zig");
    var rec = sink_test.Recorder{};
    const sink = rec.sink();
    try completeLogin(&c, sink, src, 0, 0, 0, 1, true);
    {
        const burst = try c.takeOutput(); // drain poslook; fake sink queues no chunks
        defer a.free(burst);
    }
    rec.reset();
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
    rec.reset();
    try syncPlayerChunks(&c, sink, src, 0, 1, true);
    try std.testing.expectEqualSlices(
        sink_test.Event,
        &[_]sink_test.Event{ .unload, .unload, .encode, .bulk },
        rec.eventSlice(),
    );
    try std.testing.expectEqual(@as(usize, 2), rec.unloads);
    try std.testing.expectEqual(@as(usize, 1), rec.encodes);
    try std.testing.expectEqual(@as(usize, 1), rec.bulk_n);
    try std.testing.expectEqual(@as(i32, 5), rec.bulk_cols[0].x);
    try std.testing.expect(c.sent.contains(Mem.key(5, 0)));
    try std.testing.expectEqual(@as(usize, 1), c.sent.count());
    try std.testing.expect(!c.chunks_dirty);
    {
        const no_frames = try c.takeOutput();
        defer a.free(no_frames);
        try std.testing.expectEqual(@as(usize, 0), no_frames.len);
    }

    // sync with no movement: silent
    rec.reset();
    try syncPlayerChunks(&c, sink, src, 0, 1, true);
    try std.testing.expectEqual(@as(usize, 0), rec.n);
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
        rec.reset();
        try syncPlayerChunks(&c, sink, src, 0, 1, true);
        try std.testing.expectEqualSlices(
            sink_test.Event,
            &[_]sink_test.Event{ .respawn, .unload, .encode, .encode, .bulk },
            rec.eventSlice(),
        );
        try std.testing.expectEqual(@as(usize, 1), rec.respawns);
        try std.testing.expectEqual(@as(usize, 1), rec.unloads);
        try std.testing.expectEqual(@as(i32, 5), rec.unload_pos[0].x);
        try std.testing.expectEqual(@as(i32, 0), rec.unload_pos[0].z);
        try std.testing.expectEqual(@as(usize, 2), rec.encodes);
        try std.testing.expectEqual(@as(usize, 2), rec.bulk_n);
        try std.testing.expect(c.sent.contains(Mem.key(0, 0)));
        try std.testing.expect(c.sent.contains(Mem.key(1, 0)));
        try std.testing.expectEqual(@as(usize, 2), c.sent.count());
        try std.testing.expect(!c.force_resync);
        // PosLook is still queued by completeLogin after the full burst.
        const rout = try c.takeOutput();
        defer a.free(rout);
        var rr = codec.PacketReader.init(rout);
        const rh = try codec.decodeFrame(&rr);
        try std.testing.expectEqual(@as(i32, 0x08), rh.id);
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
    _ = try applyBlock(pool, a, 3, 1, 4, ids.air, 0);
    {
        const got = try pool.getChunk(a, 0, 0, 0);
        try std.testing.expect(got != null);
        defer got.?.destroy(a);
        const idx = chunk_mod.Section.index(3, 1, 4);
        try std.testing.expectEqual(ids.air, got.?.sections[0].?.blocks[idx]);
        try std.testing.expectEqual(ids.stone, got.?.sections[0].?.blocks[idx + 1]);
    }
    // place into an empty section creates it (with air elsewhere)
    _ = try applyBlock(pool, a, 0, 200, 0, ids.planks, 2);
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
    _ = try applyBlock(pool, a, 0, 16, 0, ids.air, 0);
    {
        const got = try pool.getChunk(a, 0, 0, 0);
        defer {
            if (got) |g| g.destroy(a);
        }
        try std.testing.expect(got.?.sections[1] == null);
    }
    // missing chunk: no crash, no-op
    _ = try applyBlock(pool, a, 999, 64, 999, ids.stone, 0);
}

test "border torch bleeds block light into the neighbor chunk" {
    // Cross-chunk seam: an edit at x=15 must propagate block light into
    // chunk (1,0), and removing it must un-propagate. Without the bleed
    // the neighbor keeps stale nibbles until a full resend.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    for ([2]i32{ 0, 1 }) |cx| {
        for ([2]i32{ 0, 1 }) |cz| {
            var ch = try chunk_mod.Chunk.createEmpty(a, 0, cx, cz);
            defer ch.destroy(a);
            var s: usize = 0;
            while (s < 4) : (s += 1) {
                var sec = chunk_mod.Section{};
                for (&sec.blocks) |*b| b.* = ids.stone;
                ch.sections[s] = sec;
            }
            // Exact sky + heights baseline (fresh sections default to sky 15,
            // which would hide cross-chunk staleness).
            for (0..16) |lz| {
                for (0..16) |lx| ch.relightColumn(lx, lz);
            }
            try pool.putChunk(a, ch);
        }
    }
    try pool.flushAll();
    // Torch at the east edge of chunk (0,0).
    _ = try applyBlock(pool, a, 15, 65, 8, ids.torch, 0);
    {
        const got = try pool.getChunk(a, 0, 1, 0);
        try std.testing.expect(got != null);
        defer got.?.destroy(a);
        // Adjacent cell across the border: 14 - 1 (air cost).
        try std.testing.expectEqual(@as(u4, 13), got.?.getLightAt(0, 65, 8));
    }
    // Removing it must darken the neighbor again (no ghost light).
    _ = try applyBlock(pool, a, 15, 65, 8, ids.air, 0);
    {
        const got = try pool.getChunk(a, 0, 1, 0);
        try std.testing.expect(got != null);
        defer got.?.destroy(a);
        try std.testing.expectEqual(@as(u4, 0), got.?.getLightAt(0, 65, 8));
    }
    // Diagonal corner: a torch at (15,*,15) reaches into chunk (1,1).
    _ = try applyBlock(pool, a, 15, 65, 15, ids.torch, 0);
    {
        const got = try pool.getChunk(a, 0, 1, 1);
        try std.testing.expect(got != null);
        defer got.?.destroy(a);
        // Two air steps from 14: still bright.
        try std.testing.expect(got.?.getLightAt(0, 65, 0) > 0);
    }
    _ = try applyBlock(pool, a, 15, 65, 15, ids.air, 0);
    {
        const got = try pool.getChunk(a, 0, 1, 1);
        try std.testing.expect(got != null);
        defer got.?.destroy(a);
        try std.testing.expectEqual(@as(u4, 0), got.?.getLightAt(0, 65, 0));
    }
}

test "applyBlock reports touched neighbors for resend" {
    // The edit path fixes neighbor stores via bleedBorders but must tell
    // the server which neighbor columns changed, so tracking viewers get
    // a refresh (bits 0-3: W,E,N,S; 4-7: NW,NE,SW,SE).
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    for ([2]i32{ 0, 1 }) |cx| {
        for ([2]i32{ 0, 1 }) |cz| {
            var ch = try chunk_mod.Chunk.createEmpty(a, 0, cx, cz);
            defer ch.destroy(a);
            var s: usize = 0;
            while (s < 4) : (s += 1) {
                var sec = chunk_mod.Section{};
                for (&sec.blocks) |*b| b.* = ids.stone;
                ch.sections[s] = sec;
            }
            for (0..16) |lz| {
                for (0..16) |lx| ch.relightColumn(lx, lz);
            }
            try pool.putChunk(a, ch);
        }
    }
    try pool.flushAll();
    // Border edit with existing east+south neighbors: the torch floods all
    // borders, but only existing neighbors report bits (E|S).
    try std.testing.expectEqual(@as(u8, (1 << 1) | (1 << 3)), try applyBlock(pool, a, 15, 65, 8, ids.torch, 0));
    // Removing it darkens the same neighbors again.
    try std.testing.expectEqual(@as(u8, (1 << 1) | (1 << 3)), try applyBlock(pool, a, 15, 65, 8, ids.air, 0));
    // Deep-interior stone<->dirt swap touches no light: mask zero.
    try std.testing.expectEqual(@as(u8, 0), try applyBlock(pool, a, 7, 40, 7, ids.dirt, 0));
    // Corner edit reaches the diagonal neighbor (SE bit) as well as edges.
    const m = try applyBlock(pool, a, 15, 65, 15, ids.torch, 0);
    try std.testing.expectEqual(@as(u8, (1 << 1) | (1 << 3) | (1 << 7)), m);
}

test "resendColumn unloads then bursts a tracked column" {
    const a = std.testing.allocator;
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
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 3, 4);
        defer ch.destroy(a);
        ch.sections[0] = chunk_mod.Section{};
        const enc = try ch.encode(a);
        defer a.free(enc);
        try map.put(Mem.key(3, 4), try a.dupe(u8, enc));
    }
    Mem.store = map;
    const src = Source{ .ctx = @ptrCast(&Mem.store), .getFn = Mem.get };

    var c = conn_mod.Conn.init(a, std.testing.io, .{}, 1);
    defer c.deinit();
    c.state = .play;
    const sink_test = @import("packet_sink_test.zig");
    var rec = sink_test.Recorder{};
    const sink = rec.sink();
    // Untracked column: no-op, silent.
    try resendColumn(&c, sink, src, 0, 3, 4, true);
    try std.testing.expectEqual(@as(usize, 0), rec.n);
    // Tracked column: unload, re-encode, single-column burst.
    try c.sent.put(Mem.key(3, 4), {});
    try resendColumn(&c, sink, src, 0, 3, 4, true);
    try std.testing.expectEqualSlices(
        sink_test.Event,
        &[_]sink_test.Event{ .unload, .encode, .bulk },
        rec.eventSlice(),
    );
    try std.testing.expectEqual(@as(i32, 3), rec.unload_pos[0].x);
    try std.testing.expectEqual(@as(i32, 4), rec.unload_pos[0].z);
    try std.testing.expectEqual(@as(usize, 1), rec.bulk_n);
    try std.testing.expectEqual(@as(i32, 3), rec.bulk_cols[0].x);
    // Still tracked afterwards (re-added by the burst).
    try std.testing.expect(c.sent.contains(Mem.key(3, 4)));
}

test "border roof shadows the neighbor lee side (sky)" {
    // A roof over the border blocks horizontal skylight into the
    // neighbor's under-roof cells; removal restores full sky. Opaque roof
    // cells store the incoming top-face value, so value-diffing alone
    // misses the flip — the opacity delta drives this bleed.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    for ([2]i32{ 0, 1 }) |cx| {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, cx, 0);
        defer ch.destroy(a);
        var s: usize = 0;
        while (s < 4) : (s += 1) {
            var sec = chunk_mod.Section{};
            for (&sec.blocks) |*b| b.* = ids.stone;
            ch.sections[s] = sec;
        }
        // Exact sky + heights baseline (fresh sections default to sky 15,
        // which would hide cross-chunk staleness).
        for (0..16) |lz| {
            for (0..16) |lx| ch.relightColumn(lx, lz);
        }
        try pool.putChunk(a, ch);
    }
    try pool.flushAll();
    // Roof slab y=80 over x=16..23, z=7..9 (chunk 1 only): the cell below
    // its west edge sees sky ONLY from chunk 0, so without the bleed it
    // stays dark. N/S/east are roofed too, isolating the west inflow.
    {
        var x: i32 = 16;
        while (x <= 23) : (x += 1) {
            var z: i32 = 7;
            while (z <= 9) : (z += 1) {
                _ = try applyBlock(pool, a, x, 80, z, ids.stone, 0);
            }
        }
    }
    {
        const got = try pool.getChunk(a, 0, 1, 0);
        try std.testing.expect(got != null);
        defer got.?.destroy(a);
        try std.testing.expect(got.?.sections[4] != null);
        // 15 (open west) minus one step east: exact cross-border flood.
        const v = chunk_mod.Section.getNibble(&got.?.sections[4].?.sky, chunk_mod.Section.index(0, 15, 8));
        try std.testing.expectEqual(@as(u4, 14), v);
    }
    // Removing the roof restores full sky.
    {
        var x: i32 = 16;
        while (x <= 23) : (x += 1) {
            var z: i32 = 7;
            while (z <= 9) : (z += 1) {
                _ = try applyBlock(pool, a, x, 80, z, ids.air, 0);
            }
        }
    }
    {
        const got = try pool.getChunk(a, 0, 1, 0);
        try std.testing.expect(got != null);
        defer got.?.destroy(a);
        const v = chunk_mod.Section.getNibble(&got.?.sections[4].?.sky, chunk_mod.Section.index(0, 15, 8));
        try std.testing.expectEqual(@as(u4, 15), v);
    }
}

test "applyBlock incremental relight equals full reflood (differential)" {
    // The strong guarantee: K random edits through the incremental
    // applyBlock path must produce byte-identical light nibbles (and
    // heights) to applying the same edits raw and re-lighting fully.
    // Any stale-light or over-zeroing bug shows up as a mismatch.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    // Deterministic base: stone y0..61, dirt 62, grass 63 with a pond,
    // surface leaves + torch. Sections 0..3 only (edits above reach the
    // fresh-section path).
    var base = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
    defer base.destroy(a);
    for (0..4) |s| base.sections[s] = chunk_mod.Section{};
    {
        var y: usize = 0;
        while (y < 64) : (y += 1) {
            var z: usize = 0;
            while (z < 16) : (z += 1) {
                var x: usize = 0;
                while (x < 16) : (x += 1) {
                    const id: ids.Id = if (y <= 61) .stone else if (y == 62) .dirt else .grass;
                    base.sections[y >> 4].?.setBlock(@intCast(x), @intCast(y & 15), @intCast(z), id);
                }
            }
        }
        // Pond: water at y=63 over x=2..4,z=2..4.
        var dx: usize = 2;
        while (dx <= 4) : (dx += 1) {
            var dz: usize = 2;
            while (dz <= 4) : (dz += 1) {
                base.sections[3].?.setBlock(@intCast(dx), 15, @intCast(dz), .water);
            }
        }
        base.sections[3].?.setBlock(10, 15, 10, .leaves);
        base.sections[3].?.setBlock(11, 15, 10, .leaves);
        base.sections[3].?.setBlock(5, 15, 5, .torch);
    }
    // Fully-lit base goes into the store (stored chunks always carry
    // fresh light — gen lights, applyBlock relights).
    {
        for (0..16) |lz| {
            for (0..16) |lx| base.relightColumn(lx, lz);
        }
        const q = try a.alloc(u32, 65536);
        defer a.free(q);
        base.relightBlock(q);
        base.spreadSky(q);
    }
    try pool.putChunk(a, base);
    try pool.flushAll();
    // Deterministic edit script (LCG): positions across surface + fresh
    // air, ids spanning emission/opacity transitions both ways.
    const palette = [_]ids.Id{ .air, .stone, .dirt, .torch, .glass, .leaves, .water, .planks, .sand, .glowstone };
    var rng: u64 = 0x12345678ABCDEF;
    const next = struct {
        fn f(r: *u64, bound: u64) u64 {
            r.* = r.* *% 6364136223846793005 +% 1442695040888963407;
            return (r.* >> 33) % bound;
        }
    }.f;
    var ex: [24]i32 = undefined;
    var ey: [24]u8 = undefined;
    var ez: [24]i32 = undefined;
    var eid: [24]ids.Id = undefined;
    for (0..24) |i| {
        ex[i] = @intCast(next(&rng, 16));
        ey[i] = @intCast(60 + next(&rng, 16));
        ez[i] = @intCast(next(&rng, 16));
        eid[i] = palette[next(&rng, palette.len)];
    }
    // Reference clone (raw base, unlit); each edit goes through both
    // paths, compared after EVERY edit (a transient divergence that
    // later converges would slip past an end-only check).
    {
        var ref = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ref.destroy(a);
        // Rebuild the same base deterministically (fresh, unlit).
        for (0..4) |s| ref.sections[s] = chunk_mod.Section{};
        {
            var y: usize = 0;
            while (y < 64) : (y += 1) {
                var z: usize = 0;
                while (z < 16) : (z += 1) {
                    var x: usize = 0;
                    while (x < 16) : (x += 1) {
                        const id: ids.Id = if (y <= 61) .stone else if (y == 62) .dirt else .grass;
                        ref.sections[y >> 4].?.setBlock(@intCast(x), @intCast(y & 15), @intCast(z), id);
                    }
                }
            }
            var dx: usize = 2;
            while (dx <= 4) : (dx += 1) {
                var dz: usize = 2;
                while (dz <= 4) : (dz += 1) {
                    ref.sections[3].?.setBlock(@intCast(dx), 15, @intCast(dz), .water);
                }
            }
            ref.sections[3].?.setBlock(10, 15, 10, .leaves);
            ref.sections[3].?.setBlock(11, 15, 10, .leaves);
            ref.sections[3].?.setBlock(5, 15, 5, .torch);
        }
        const qref = try a.alloc(u32, 65536);
        defer a.free(qref);
        for (ex, ey, ez, eid) |x, y, z, id| {
            _ = try applyBlock(pool, a, x, y, z, id, 0);
            const si: usize = @as(usize, y) >> 4;
            if (ref.sections[si] == null) {
                if (id != .air) ref.sections[si] = chunk_mod.Section{};
            }
            if (ref.sections[si] != null) {
                const lx: usize = @intCast(x & 15);
                const lz: usize = @intCast(z & 15);
                ref.sections[si].?.setBlock(@intCast(@as(u4, @truncate(lx))), @truncate(@as(u8, y) & 15), @intCast(@as(u4, @truncate(lz))), id);
            }
            for (0..16) |lz| {
                for (0..16) |lx| ref.relightColumn(lx, lz);
            }
            ref.relightBlock(qref);
            ref.spreadSky(qref);
            const got = try pool.getChunk(a, 0, 0, 0);
            try std.testing.expect(got != null);
            defer got.?.destroy(a);
            try std.testing.expectEqual(got.?.mask(), ref.mask());
            try std.testing.expectEqualSlices(u8, &got.?.heights, &ref.heights);
            for (0..16) |rs| {
                if (got.?.sections[rs]) |gs| {
                    const rfs = ref.sections[rs].?;
                    try std.testing.expectEqualSlices(u8, &gs.sky, &rfs.sky);
                    try std.testing.expectEqualSlices(u8, &gs.light, &rfs.light);
                } else {
                    try std.testing.expect(ref.sections[rs] == null);
                }
            }
        }
    }
}

test "applyBlock roof plug dims sideways, break restores (regression)" {
    // The value-preserving hole: plugging an opening with stone keeps
    // the plug cell at 15 (column rule) while killing transmissivity.
    // Without the maximal-flow seed the sideways-lit neighbor strands
    // at stale 14; with it, the neighbor settles to its true 12.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pool = try shard_mod.ShardPool.open(a, io, tmp.dir, 1, .{ .flush_threshold_bytes = 1 << 30 });
    defer pool.deinit();
    {
        var ch = try chunk_mod.Chunk.createEmpty(a, 0, 0, 0);
        defer ch.destroy(a);
        for (0..5) |s| ch.sections[s] = chunk_mod.Section{};
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
        for (0..16) |lz| {
            for (0..16) |lx| ch.relightColumn(lx, lz);
        }
        const q = try a.alloc(u32, 65536);
        defer a.free(q);
        ch.relightBlock(q);
        ch.spreadSky(q);
        try pool.putChunk(a, ch);
        try pool.flushAll();
    }
    const skyAt = struct {
        fn f(ch: *chunk_mod.Chunk, lx: usize, y: usize, lz: usize) u4 {
            const s = ch.sections[y >> 4] orelse return 0;
            return chunk_mod.Section.getNibble(&s.sky, chunk_mod.Section.index(@intCast(lx), @intCast(y & 15), @intCast(lz)));
        }
    }.f;
    {
        const got = try pool.getChunk(a, 0, 0, 0);
        try std.testing.expect(got != null);
        defer got.?.destroy(a);
        try std.testing.expectEqual(@as(u4, 14), skyAt(got.?, 8, 69, 8));
    }
    // Plug the opening: (8,69) must settle to 13, not strand at stale
    // 14. (A 2D analysis says 12, but the plug is 1-wide in z while the
    // opening runs the full edge: z-neighbors hold 14 and re-light along
    // z. Full-3D fixed point, verified by exhaustion below.)
    _ = try applyBlock(pool, a, 7, 69, 8, ids.stone, 0);
    {
        const got = try pool.getChunk(a, 0, 0, 0);
        try std.testing.expect(got != null);
        defer got.?.destroy(a);
        try std.testing.expectEqual(@as(u4, 13), skyAt(got.?, 8, 69, 8));
        try std.testing.expectEqual(@as(u4, 12), skyAt(got.?, 9, 69, 8));
        try std.testing.expectEqual(@as(u4, 11), skyAt(got.?, 10, 69, 8));
        // Leak under the new stone's edge (vanilla edge behavior).
        try std.testing.expectEqual(@as(u4, 14), skyAt(got.?, 7, 68, 8));
    }
    // Reopen: full restoration to 14.
    _ = try applyBlock(pool, a, 7, 69, 8, ids.air, 0);
    {
        const got = try pool.getChunk(a, 0, 0, 0);
        try std.testing.expect(got != null);
        defer got.?.destroy(a);
        try std.testing.expectEqual(@as(u4, 14), skyAt(got.?, 8, 69, 8));
    }
}
