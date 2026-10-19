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
            const name = try std.fmt.bufPrint(&name_buf, "shard-{d:0>2}", .{i});
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

    pub fn put(self: *ShardPool, key: store_mod.ChunkKey, value: []const u8) !void {
        const d = store_mod.decodeKey(key);
        const s = self.shardFor(d.dim, d.x, d.z);
        try self.shards[s].put(key, value);
    }

    pub fn get(self: *ShardPool, key: store_mod.ChunkKey) !?[]u8 {
        const d = store_mod.decodeKey(key);
        const s = self.shardFor(d.dim, d.x, d.z);
        return self.shards[s].get(key);
    }

    pub fn delete(self: *ShardPool, key: store_mod.ChunkKey) !void {
        const d = store_mod.decodeKey(key);
        const s = self.shardFor(d.dim, d.x, d.z);
        try self.shards[s].delete(key);
    }

    /// Encode + store a chunk. Convenience for the tick loop.
    pub fn putChunk(self: *ShardPool, ch: *const chunk_mod.Chunk) !void {
        const enc = try ch.encode(self.allocator);
        defer self.allocator.free(enc);
        try self.put(store_mod.encodeKey(ch.dim, ch.x, ch.z), enc);
    }

    /// Load + decode a chunk. Returns null if absent. Caller destroys.
    pub fn getChunk(self: *ShardPool, dim: u8, x: i32, z: i32) !?*chunk_mod.Chunk {
        const raw = try self.get(store_mod.encodeKey(dim, x, z));
        if (raw == null) return null;
        defer self.allocator.free(raw.?);
        return try chunk_mod.Chunk.decode(self.allocator, raw.?);
    }

    pub fn flushAll(self: *ShardPool) !void {
        for (self.shards) |st| try st.flush();
    }
};

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
            try pool.putChunk(ch);
        }
        try pool.flushAll();
        const got = try pool.getChunk(0, 64, -64);
        try std.testing.expect(got != null);
        defer got.?.destroy(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 2), got.?.biomes[0]);
    }
    {
        var pool = try ShardPool.open(std.testing.allocator, io, tmp.dir, 4, .{ .flush_threshold_bytes = 1 << 30 });
        defer pool.deinit();
        const got = try pool.getChunk(0, 96, -96);
        try std.testing.expect(got != null);
        defer got.?.destroy(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 3), got.?.biomes[0]);
    }
}
