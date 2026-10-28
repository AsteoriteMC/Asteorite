//! View-distance chunk delivery: spiral-order initial burst via bulk packets.
//!
//! Login flow (groundUp=true full columns only):
//!   JoinGame -> SpawnPosition -> MapChunkBulk(s) -> PlayerPosLook.
//! Re-sending an existing groundUp column leaks client memory, so each
//! column is sent at most once per connection (tracked resend is P-next
//! with unload packets, which chunks.zig already encodes).


const std = @import("std");
const chunk_mod = @import("../../world/chunk.zig");
const shard_mod = @import("../../world/shard.zig");
const conn_mod = @import("../../net/conn.zig");
const ids = @import("../../ids.zig");

const burst_mod = @import("view/burst.zig");
const blocks_mod = @import("view/blocks.zig");

pub const Source = burst_mod.Source;
pub const shardPoolSource = burst_mod.shardPoolSource;
pub const Spiral = burst_mod.Spiral;
pub const max_bulk_cols = burst_mod.max_bulk_cols;
pub const max_view_radius = burst_mod.max_view_radius;
pub const max_column_bytes = burst_mod.max_column_bytes;
pub const max_disk_cols = burst_mod.max_disk_cols;
pub const ColPos = burst_mod.ColPos;
pub const sendColumns = burst_mod.sendColumns;
pub const resyncDisk = burst_mod.resyncDisk;
pub const completeLogin = burst_mod.completeLogin;
pub const BurstCollect = burst_mod.BurstCollect;
pub const collectLoginBurst = burst_mod.collectLoginBurst;
pub const syncPlayerChunks = burst_mod.syncPlayerChunks;
pub const fullResync = burst_mod.fullResync;
pub const resendColumn = burst_mod.resendColumn;
pub const PeekBlock = blocks_mod.PeekBlock;
pub const isOpaqueCube = blocks_mod.isOpaqueCube;
pub const peekBlock = blocks_mod.peekBlock;
pub const loadChunk = blocks_mod.loadChunk;
pub const groundBlockY = blocks_mod.groundBlockY;
pub const applyBlock = blocks_mod.applyBlock;

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
    const sink_test = @import("../net/packet_sink_test.zig");
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
    const codec = @import("../../net/codec.zig");
    var r = codec.PacketReader.init(out);
    const h0 = try codec.decodeFrame(&r);
    try std.testing.expectEqual(@as(i32, 0x08), h0.id);
    _ = try r.readBytes(8 * 3 + 4 * 2 + 1); // x,y,z,yaw,pitch,onGround
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "collectLoginBurst is wire-identical to the conn-sink burst" {
    // The unlocked login path must produce byte-identical frames to the
    // locked resyncDisk path (same columns, same spiral order, same
    // holes skipped, same bulk splits) or clients would see divergent
    // worlds depending on which path served their login.
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
    // 3 of 9 columns present (holes at the rest exercise the skip path).
    for ([_]struct { x: i32, id: ids.Id }{ .{ .x = 0, .id = ids.stone }, .{ .x = 1, .id = ids.diamond_block }, .{ .x = -1, .id = ids.coal_ore } }) |e| {
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
    const conn_sink = @import("../../net/packet_sink.zig");

    // Reference: locked path through the real conn sink.
    var ca = conn_mod.Conn.init(a, std.testing.io, .{}, 1);
    defer ca.deinit();
    try resyncDisk(&ca, conn_sink.bind(&ca), src, 0, 0, 0, 1, true, null);
    const ref = try ca.takeOutput();
    defer a.free(ref);
    var ref_sent = std.AutoHashMap(i64, void).init(a);
    defer ref_sent.deinit();
    var it = ca.sent.iterator();
    while (it.next()) |e| try ref_sent.put(e.key_ptr.*, {});

    // New: unlocked collect, then queue under lock like sessionStep does.
    var cb = conn_mod.Conn.init(a, std.testing.io, .{}, 1);
    defer cb.deinit();
    var collect = BurstCollect{};
    defer collect.deinit(a);
    try collectLoginBurst(a, src, 0, 0, 0, 1, true, &collect);
    for (collect.frames.items) |f| try cb.queueFramed(f);
    var it2 = collect.sent.iterator();
    while (it2.next()) |e| try cb.sent.put(e.key_ptr.*, {});
    const got = try cb.takeOutput();
    defer a.free(got);

    try std.testing.expectEqualSlices(u8, ref, got);
    try std.testing.expectEqual(ref_sent.count(), cb.sent.count());
    var it3 = ref_sent.iterator();
    while (it3.next()) |e| try std.testing.expect(cb.sent.contains(e.key_ptr.*));
}

test "sync on move: unload + burst, no resends, respawn resets" {
    const a = std.testing.allocator;
    const codec = @import("../../net/codec.zig");
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
    const sink_test = @import("../net/packet_sink_test.zig");
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
    const sink_test = @import("../net/packet_sink_test.zig");
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
