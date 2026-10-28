//! Region-sharded LSM pool: Folia-style ownership without a global lock.
//!
//! The keyspace [dim|x|z] is partitioned by 32x32-chunk region into N shards,
//! each with its own Store (own WAL + SST dir). A region thread owns its
//! shards exclusively: no cross-shard lock on the hot path.
//! Shard count is fixed at open; keys hash by (dim, regionX, regionZ).

const std = @import("std");
const store_mod = @import("store.zig");
const chunk_mod = @import("chunk.zig");

pub const region_size = 32;

/// printf-style shard directory name ("shard-00" ... ).
pub const shard_name_fmt = "shard-{d:0>2}";

fn shardName(buf: []u8, i: usize) ![]u8 {
    return std.fmt.bufPrint(buf, shard_name_fmt, .{i});
}

pub fn regionOf(chunk_coord: i32) i32 {
    return @divFloor(chunk_coord, region_size);
}

pub const ShardPool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir, // borrowed
    shards: []*store_mod.Store, // owned stores, len == n
    owned_dirs: []std.Io.Dir, // owned shard dirs (parallel to shards)

    pub fn shardCount(self: *const ShardPool) usize {
        return self.shards.len;
    }

    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        root_dir: std.Io.Dir,
        n_shards: usize,
        opts: store_mod.Store.Options,
    ) !*ShardPool {
        if (n_shards == 0) return error.InvalidShardCount;
        const self = try allocator.create(ShardPool);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .root_dir = root_dir,
            .shards = try allocator.alloc(*store_mod.Store, n_shards),
            .owned_dirs = try allocator.alloc(std.Io.Dir, n_shards),
        };
        errdefer allocator.free(self.shards);
        errdefer allocator.free(self.owned_dirs);
        var i: usize = 0;
        errdefer {
            while (i > 0) {
                i -= 1;
                self.shards[i].deinit();
                self.owned_dirs[i].close(io);
            }
        }
        while (i < n_shards) : (i += 1) {
            var name_buf: [32]u8 = undefined;
            const name = try shardName(&name_buf, i);
            const dir = try root_dir.createDirPathOpen(io, name, .{});
            self.owned_dirs[i] = dir;
            self.shards[i] = try store_mod.Store.open(allocator, io, dir, opts);
        }
        return self;
    }

    pub fn close(self: *ShardPool) void {
        for (self.shards, self.owned_dirs) |st, *d| {
            st.deinit();
            d.close(self.io);
        }
        self.allocator.free(self.shards);
        self.allocator.free(self.owned_dirs);
        self.allocator.destroy(self);
    }

    pub fn deinit(self: *ShardPool) void {
        self.close();
    }

    pub fn shardFor(self: *const ShardPool, dim: u8, x: i32, z: i32) usize {
        const rx = regionOf(x);
        const rz = regionOf(z);
        var h = std.hash.Wyhash.init(0);
        h.update(&[_]u8{dim});
        var b: [8]u8 = undefined;
        std.mem.writeInt(i32, b[0..4], rx, .little);
        std.mem.writeInt(i32, b[4..8], rz, .little);
        h.update(&b);
        return @as(usize, h.final()) % self.shards.len;
    }

    /// Route a key to its owning store (decode + hash once).
    fn route(self: *const ShardPool, key: store_mod.ChunkKey) *store_mod.Store {
        const d = store_mod.decodeKey(key);
        return self.shards[self.shardFor(d.dim, d.x, d.z)];
    }

    pub fn put(self: *ShardPool, key: store_mod.ChunkKey, value: []const u8) !void {
        try self.route(key).put(key, value);
    }

    pub fn get(self: *ShardPool, alloc: std.mem.Allocator, key: store_mod.ChunkKey) !?[]u8 {
        return self.route(key).get(alloc, key);
    }

    pub fn delete(self: *ShardPool, key: store_mod.ChunkKey) !void {
        try self.route(key).delete(key);
    }

    /// Encode + store a chunk. Convenience for the tick loop.
    pub fn putChunk(self: *ShardPool, alloc: std.mem.Allocator, ch: *const chunk_mod.Chunk) !void {
        const enc = try ch.encode(alloc);
        defer alloc.free(enc);
        try self.put(store_mod.encodeKey(ch.dim, ch.x, ch.z), enc);
    }

    /// Load + decode a chunk. Returns null if absent. Caller destroys.
    /// `raw` and the chunk use `alloc`; free/destroy with the same.
    pub fn getChunk(self: *ShardPool, alloc: std.mem.Allocator, dim: u8, x: i32, z: i32) !?*chunk_mod.Chunk {
        const raw = try self.get(alloc, store_mod.encodeKey(dim, x, z));
        if (raw == null) return null;
        defer alloc.free(raw.?);
        return try chunk_mod.Chunk.decode(alloc, raw.?);
    }

    /// Sum a per-shard metric across the pool (diagnostics / stats line).
    fn sumMetric(self: *ShardPool, f: *const fn (*store_mod.Store) usize) usize {
        var n: usize = 0;
        for (self.shards) |sh| n += f(sh);
        return n;
    }

    /// Total live SST files across the shards (diagnostics / stats line).
    pub fn sstCount(self: *ShardPool) usize {
        return self.sumMetric(struct {
            fn f(sh: *store_mod.Store) usize {
                return sh.sstCount();
            }
        }.f);
    }

    /// Total pinned io_uring read-buffer bytes (diagnostics / stats line).
    pub fn ringBytes(self: *ShardPool) usize {
        return self.sumMetric(struct {
            fn f(sh: *store_mod.Store) usize {
                return sh.ringBytes();
            }
        }.f);
    }

    pub fn flushAll(self: *ShardPool) !void {
        for (self.shards) |st| try st.flush();
    }

    /// Merge runs within every shard (see `Store.compact`). Bounded SST
    /// counts keep `get` from degrading to a 50-file linear scan (Phase E).
    pub fn compactAll(self: *ShardPool) !void {
        for (self.shards) |st| try st.compact();
    }

    /// Same as `compactAll`, one thread per shard. Shards are disjoint
    /// (own WAL + SST dir + store mutex), so no shard ever waits on
    /// another — the wall time is the slowest shard, not the sum. The NVMe
    /// profile's small SSTs make per-shard compactions cheap and plentiful,
    /// which is exactly the shape that parallelizes.
    ///
    /// The stores must share a thread-safe allocator (main's GPA is;
    /// tests should use the page allocator, not the test allocator).
    pub fn compactAllParallel(self: *ShardPool) !void {
        if (self.shards.len == 1) return try self.shards[0].compact();
        const Worker = struct {
            fn run(store: *store_mod.Store, out: *?anyerror) void {
                store.compact() catch |err| {
                    out.* = err;
                };
            }
        };
        const errs = try self.allocator.alloc(?anyerror, self.shards.len);
        defer self.allocator.free(errs);
        @memset(errs, null);
        var threads = try self.allocator.alloc(std.Thread, self.shards.len);
        defer self.allocator.free(threads);
        var spawned: usize = 0;
        errdefer {
            // Spawn failed midway: join what is running, never leak threads.
            var j: usize = 0;
            while (j < spawned) : (j += 1) threads[j].join();
        }
        while (spawned < self.shards.len) : (spawned += 1) {
            threads[spawned] = try std.Thread.spawn(.{}, Worker.run, .{ self.shards[spawned], &errs[spawned] });
        }
        for (threads) |t| t.join();
        for (errs) |e| {
            if (e) |err| return err;
        }
    }

    /// Consistent snapshot of every shard into `backup_root/shard-NN`.
    /// Flushes first (point-in-time copy). Quiesce writers across all shards
    /// before calling — there is no cross-shard lock yet (Phase C).
    /// See `Store.snapshot` for the procedure and guarantees.
    pub fn snapshotAll(self: *ShardPool, backup_root: std.Io.Dir) !void {
        for (self.shards, 0..) |st, i| {
            var name_buf: [32]u8 = undefined;
            const name = try shardName(&name_buf, i);
            var snap_dir = try backup_root.createDirPathOpen(self.io, name, .{});
            defer snap_dir.close(self.io);
            try st.snapshot(snap_dir);
        }
    }
};

test "parallel compaction matches serial (same merged data)" {
    // Page allocator: the stores share it across threads (the test
    // allocator is not for concurrent use).
    const alloc = std.heap.page_allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Two identical pools: one compacts serially, one in parallel.
    var serial = try ShardPool.open(alloc, io, tmp.dir, 4, .{ .flush_threshold_bytes = 4096, .compact_threshold_ssts = 0 });
    defer serial.deinit();
    var sub = try tmp.dir.createDirPathOpen(io, "par", .{});
    defer sub.close(io);
    var parallel = try ShardPool.open(alloc, io, sub, 4, .{ .flush_threshold_bytes = 4096, .compact_threshold_ssts = 0 });
    defer parallel.deinit();
    // One flush per chunk: every shard accumulates several small runs.
    var i: i32 = 0;
    while (i < 32) : (i += 1) {
        var ch = try chunk_mod.Chunk.createEmpty(alloc, 0, i, -i);
        defer ch.destroy(alloc);
        ch.biomes[0] = @intCast(i);
        try serial.putChunk(alloc, ch);
        try parallel.putChunk(alloc, ch);
        try serial.flushAll();
        try parallel.flushAll();
    }
    try std.testing.expect(serial.sstCount() > 4);
    try serial.compactAll();
    try parallel.compactAllParallel();
    try std.testing.expectEqual(serial.sstCount(), parallel.sstCount());
    // Same merged data on both.
    var j: i32 = 0;
    while (j < 32) : (j += 1) {
        const a = try serial.getChunk(alloc, 0, j, -j);
        const b = try parallel.getChunk(alloc, 0, j, -j);
        try std.testing.expect(a != null and b != null);
        defer a.?.destroy(alloc);
        defer b.?.destroy(alloc);
        try std.testing.expectEqual(a.?.biomes[0], b.?.biomes[0]);
    }
}

test "region mapping floors negatives" {
    try std.testing.expectEqual(@as(i32, 0), regionOf(0));
    try std.testing.expectEqual(@as(i32, 0), regionOf(31));
    try std.testing.expectEqual(@as(i32, 1), regionOf(32));
    try std.testing.expectEqual(@as(i32, -1), regionOf(-1));
    try std.testing.expectEqual(@as(i32, -1), regionOf(-32));
    try std.testing.expectEqual(@as(i32, -2), regionOf(-33));
}

test "shard pool routes + recovers" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var pool = try ShardPool.open(std.testing.allocator, io, tmp.dir, 4, .{ .flush_threshold_bytes = 1 << 30 });
        defer pool.deinit();
        // same region => same shard; different region may differ
        const s_a = pool.shardFor(0, 0, 0);
        const s_b = pool.shardFor(0, 31, 31);
        try std.testing.expectEqual(s_a, s_b);
        // put chunks across regions/dims
        var i: i32 = 0;
        while (i < 8) : (i += 1) {
            var ch = try chunk_mod.Chunk.createEmpty(std.testing.allocator, 0, i * 32, -i * 32);
            defer ch.destroy(std.testing.allocator);
            ch.biomes[0] = @intCast(i);
            try pool.putChunk(pool.allocator, ch);
        }
        try pool.flushAll();
        const got = try pool.getChunk(std.testing.allocator, 0, 64, -64);
        try std.testing.expect(got != null);
        defer got.?.destroy(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 2), got.?.biomes[0]);
    }
    {
        var pool = try ShardPool.open(std.testing.allocator, io, tmp.dir, 4, .{ .flush_threshold_bytes = 1 << 30 });
        defer pool.deinit();
        const got = try pool.getChunk(std.testing.allocator, 0, 96, -96);
        try std.testing.expect(got != null);
        defer got.?.destroy(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 3), got.?.biomes[0]);
    }
}
