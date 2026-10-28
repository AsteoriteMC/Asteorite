//! View-distance chunk burst: initial login burst, movement resync and
//! column (re)send over the chunk packet sink.

const std = @import("std");
const packet_sink = @import("../../net/packet_sink.zig");
const chunk_mod = @import("../../../world/chunk.zig");
const store_mod = @import("../../../world/store.zig");
const shard_mod = @import("../../../world/shard.zig");
const conn_mod = @import("../../../net/conn.zig");
const profile = @import("../../../version.zig");

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

pub const max_bulk_cols: usize = profile.meta.max_bulk_columns;
pub const max_view_radius = 16;
pub const max_column_bytes: usize = profile.meta.max_column_bytes;
/// Largest view disk in columns ((2*16+1)^2 at the client cap).
pub const max_disk_cols: usize = (2 * max_view_radius + 1) * (2 * max_view_radius + 1);

pub const ColPos = struct { x: i32, z: i32 };

/// Decode a sent-set key back to column coords.
pub fn sentPos(k: i64) ColPos {
    const uk: u64 = @bitCast(k);
    return .{
        .x = @as(i32, @bitCast(@as(u32, @truncate(uk >> 32)))),
        .z = @as(i32, @bitCast(@as(u32, @truncate(uk)))),
    };
}

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
    const src = source orelse return;
    var list: [max_disk_cols]ColPos = undefined;
    var n: usize = 0;
    var sp = Spiral{ .radius = @min(radius, max_view_radius) };
    while (sp.next()) |off| {
        list[n] = .{ .x = cx + off.dx, .z = cz + off.dz };
        n += 1;
    }
    try sendColumns(conn, sink, src, dim, list[0..n], sky, budget);
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

/// Collected login burst (for the unlocked login path): the same columns
/// resyncDisk would send, framed and owned, plus the sent-set to merge.
/// Lets the login path drop conn.lock across worldgen + reads + zlib (the
/// multi-second hold that convoyed the tick and every announceJoin) and
/// commit under a briefly-held lock instead. Wire-identical to the
/// conn-sink path (equivalence test in view.zig); null-budget path only.
pub const BurstCollect = struct {
    frames: std.ArrayListUnmanaged([]u8) = .empty,
    sent: std.AutoHashMapUnmanaged(i64, void) = .empty,

    pub fn deinit(self: *BurstCollect, alloc: std.mem.Allocator) void {
        for (self.frames.items) |f| alloc.free(f);
        self.frames.deinit(alloc);
        self.sent.deinit(alloc);
    }
};

/// Mirror of the resyncDisk/sendColumns loop with local scratch + sent
/// set (no conn state touched): gen + read + decode + encode + zlib +
/// frame into owned packets. Skips holes exactly like sendColumns.
pub fn collectLoginBurst(
    alloc: std.mem.Allocator,
    source: ?Source,
    dim: u8,
    cx: i32,
    cz: i32,
    radius: u8,
    sky: bool,
    out: *BurstCollect,
) !void {
    const chunks = profile.proto.chunks;
    const src = source orelse return;
    var list: [max_disk_cols]ColPos = undefined;
    var n: usize = 0;
    var sp = Spiral{ .radius = @min(radius, max_view_radius) };
    while (sp.next()) |off| {
        list[n] = .{ .x = cx + off.dx, .z = cz + off.dz };
        n += 1;
    }
    const raw_all = try alloc.alloc(u8, max_bulk_cols * max_column_bytes);
    defer alloc.free(raw_all);
    const work = try alloc.alloc(u8, std.compress.flate.max_window_len);
    defer alloc.free(work);
    var cols: [max_bulk_cols]packet_sink.BulkColumn = undefined;
    var ncols: usize = 0;
    var raw_len: usize = 0;
    for (list[0..n]) |pos| {
        var col_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer col_arena.deinit();
        const t = col_arena.allocator();
        const k = conn_mod.Conn.sentKey(pos.x, pos.z);
        if (out.sent.contains(k)) continue;
        const zc1 = src.get(dim, pos.x, pos.z, t) orelse continue;
        const ch = try chunk_mod.Chunk.decode(t, zc1);
        const layout = chunks.encodeColumn(ch, sky, raw_all[raw_len..]);
        cols[ncols] = .{ .x = pos.x, .z = pos.z, .primary = layout.primary, .add = layout.add };
        ncols += 1;
        raw_len += layout.len;
        try out.sent.put(alloc, k, {});
        if (ncols == max_bulk_cols) {
            try flushCollect(alloc, work, cols[0..ncols], raw_all[0..raw_len], sky, out);
            ncols = 0;
            raw_len = 0;
        }
    }
    if (ncols > 0) {
        try flushCollect(alloc, work, cols[0..ncols], raw_all[0..raw_len], sky, out);
    }
}

/// Frame one bulk's worth of columns into an owned packet (mirrors the
/// sendBulk framing: same compression, same layout, same bytes).
fn flushCollect(
    alloc: std.mem.Allocator,
    work: []u8,
    cols: []const packet_sink.BulkColumn,
    raw: []const u8,
    sky: bool,
    out: *BurstCollect,
) !void {
    const chunks = profile.proto.chunks;
    const comp_need = raw.len + raw.len / 1024 + 4096;
    const comp = try alloc.alloc(u8, comp_need);
    defer alloc.free(comp);
    const compressed = try chunks.zlibCompress(raw, comp, work);
    var wire: [max_bulk_cols]chunks.BulkColumn = undefined;
    for (cols, 0..) |c, i| wire[i] = .{ .x = c.x, .z = c.z, .primary = c.primary, .add = c.add };
    const framed = try alloc.alloc(u8, 16 + compressed.len + 12 * cols.len);
    errdefer alloc.free(framed);
    const bytes = try chunks.frameMapChunkBulk(wire[0..cols.len], compressed, sky, framed);
    const owned = try alloc.dupe(u8, bytes);
    alloc.free(framed);
    try out.frames.append(alloc, owned);
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
    var entered: [max_disk_cols]ColPos = undefined;
    var n_entered: usize = 0;
    var sp = Spiral{ .radius = r };
    while (sp.next()) |off| {
        const x = cc.cx + off.dx;
        const z = cc.cz + off.dz;
        const k = conn_mod.Conn.sentKey(x, z);
        try new_disk.put(k, {});
        if (!conn.sent.contains(k)) {
            entered[n_entered] = .{ .x = x, .z = z };
            n_entered += 1;
        }
    }
    // unload left columns (single 0x21 unload each — small frames)
    var it = conn.sent.keyIterator();
    var left: [max_disk_cols]ColPos = undefined;
    var n_left: usize = 0;
    while (it.next()) |k| {
        if (new_disk.contains(k.*)) continue;
        left[n_left] = sentPos(k.*);
        n_left += 1;
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
        const c = sentPos(k.*);
        try sink.unloadChunk(c.x, c.z);
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
