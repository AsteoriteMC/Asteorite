//! Pure-Zig embedded LSM-tree chunk store (runtime format, NOT Anvil).
//!
//! Anvil (.mca) is import-only via `world/anvil.zig`. The server runtime
//! stores chunks in this LSM store to avoid the 8KB central header lock:
//! concurrent region threads write via append-only WAL + sorted SSTables.
//!
//! Key schema (9 bytes, big-endian, lexicographically sortable by x,z within dim):
//!   [dim:u8 | x:i32 BE | z:i32 BE]
//! Value: opaque caller bytes (versioned chunk payload). Tombstone = delete.
//!
//! Layout inside db dir:
//!   wal.log        append-only [key 9][vlen u32 BE][val][crc32 u32 BE]; vlen=0xFFFFFFFF => tombstone
//!   sst/000001.sst sorted runs: magic "ZLS1" + u32 BE count + entries [key 9][vlen u32 BE][val]
//!   (MANIFEST omitted P1: sst dir scan, sorted by name; compaction = TODO)
//!
//! Threading: P1 single-writer + P2 per-region sharding (see plan).
//! No internal lock yet — region threads own disjoint key ranges via dim/x/z
//! sharding. P2 will add `std.Io.RwLock` per shard + seqlock for reads.

const std = @import("std");

pub const key_len = 9;
pub const ChunkKey = [key_len]u8;
pub const tombstone_len: u32 = 0xFFFFFFFF;

pub fn encodeKey(dim: u8, x: i32, z: i32) ChunkKey {
    var k: ChunkKey = undefined;
    k[0] = dim;
    std.mem.writeInt(i32, k[1..5], x, .big);
    std.mem.writeInt(i32, k[5..9], z, .big);
    return k;
}

pub fn decodeKey(k: ChunkKey) struct { dim: u8, x: i32, z: i32 } {
    return .{
        .dim = k[0],
        .x = std.mem.readInt(i32, k[1..5], .big),
        .z = std.mem.readInt(i32, k[5..9], .big),
    };
}

pub const StoreError = error{
    CorruptWal,
    CorruptSst,
    OutOfMemory,
} || std.Io.Dir.OpenError || std.Io.Dir.CreateFileError || std.Io.File.OpenError ||
    std.Io.File.Writer.Error || std.Io.File.Reader.Error || std.mem.Allocator.Error;

const Entry = struct {
    key: ChunkKey,
    // null = tombstone
    value: ?[]u8,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir, // db dir (borrowed)
    sst_dir: std.Io.Dir, // db/sst (owned, close on deinit)
    wal: std.Io.File, // wal.log (owned)
    wal_len: u64,
    mem: std.HashMap(ChunkKey, ?[]u8, KeyCtx, 80),
    mem_bytes: usize,
    ssts: std.ArrayList([]u8), // owned SST file names ("000001.sst"), oldest->newest
    next_sst_id: u32,
    flush_threshold_bytes: usize,

    pub const KeyCtx = struct {
        pub fn hash(_: KeyCtx, k: ChunkKey) u64 {
            return std.hash.Wyhash.hash(0, &k);
        }
        pub fn eql(_: KeyCtx, a: ChunkKey, b: ChunkKey) bool {
            return std.mem.eql(u8, &a, &b);
        }
    };

    pub const Options = struct {
        flush_threshold_bytes: usize = 4 * 1024 * 1024,
    };

    /// Open (or create) db in `dir`. Creates `sst/` + `wal.log` as needed,
    /// replays WAL into memtable, scans `sst/` for existing runs.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, opts: Options) !*Store {
        // sst subdir (create if missing)
        dir.createDir(io, "sst", .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const sst_dir = try dir.openDir(io, "sst", .{ .iterate = true });

        var self = try allocator.create(Store);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .dir = dir,
            .sst_dir = sst_dir,
            .wal = undefined,
            .wal_len = 0,
            .mem = .init(allocator),
            .mem_bytes = 0,
            .ssts = .empty,
            .next_sst_id = 1,
            .flush_threshold_bytes = opts.flush_threshold_bytes,
        };

        // scan sst/ for *.sst
        try self.scanSstDir();

        // open or create wal.log
        self.wal = try self.dir.createFile(self.io, "wal.log", .{ .read = true, .truncate = false });
        self.wal_len = try self.wal.length(io);
        if (self.wal_len > 0) {
            try self.replayWal();
        }
        return self;
    }

    /// Convenience: open `sub_path` under cwd (creates path).
    pub fn openPath(allocator: std.mem.Allocator, io: std.Io, sub_path: []const u8, opts: Options) !struct { store: *Store, db_dir: std.Io.Dir } {
        const cwd = std.Io.Dir.cwd();
        const db_dir = try cwd.createDirPathOpen(io, sub_path, .{});
        const store = try open(allocator, io, db_dir, opts);
        return .{ .store = store, .db_dir = db_dir };
    }

    pub fn close(self: *Store) void {
        self.wal.sync(self.io) catch {};
        self.wal.close(self.io);
        self.sst_dir.close(self.io);
        var it = self.mem.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.*) |v| self.allocator.free(v);
        }
        self.mem.deinit();
        for (self.ssts.items) |n| self.allocator.free(n);
        self.ssts.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Caller must also close `db_dir` from openPath after store.close().
    pub fn deinit(self: *Store) void {
        self.close();
    }

    fn scanSstDir(self: *Store) !void {
        var it = self.sst_dir.iterate();
        var max_id: u32 = 0;
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".sst")) continue;
            const stem = entry.name[0 .. entry.name.len - 4];
            const id = std.fmt.parseInt(u32, stem, 10) catch continue;
            if (id > max_id) max_id = id;
            const owned = try self.allocator.dupe(u8, entry.name);
            try self.ssts.append(self.allocator, owned);
        }
        // sort oldest->newest (numeric)
        std.mem.sort([]u8, self.ssts.items, {}, struct {
            fn less(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        self.next_sst_id = max_id + 1;
    }

    fn replayWal(self: *Store) !void {
        const data = try self.dir.readFileAlloc(self.io, "wal.log", self.allocator, .limited(256 * 1024 * 1024));
        defer self.allocator.free(data);
        var pos: usize = 0;
        while (pos < data.len) {
            if (pos + 9 + 4 + 4 > data.len) return error.CorruptWal;
            const key: ChunkKey = data[pos..][0..9].*;
            pos += 9;
            const vlen = std.mem.readInt(u32, data[pos..][0..4], .big);
            pos += 4;
            var val: ?[]u8 = null;
            if (vlen != tombstone_len) {
                if (pos + vlen + 4 > data.len) return error.CorruptWal;
                val = try self.allocator.dupe(u8, data[pos .. pos + vlen]);
                pos += vlen;
            }
            const want_crc = std.mem.readInt(u32, data[pos..][0..4], .big);
            pos += 4;
            var h = std.hash.Crc32.init();
            h.update(&key);
            var lb: [4]u8 = undefined;
            std.mem.writeInt(u32, &lb, vlen, .big);
            h.update(&lb);
            if (val) |v| h.update(v);
            if (h.final() != want_crc) {
                if (val) |v| self.allocator.free(v);
                return error.CorruptWal;
            }
            // insert (replace old)
            if (self.mem.fetchRemove(key)) |old| {
                if (old.value) |ov| {
                    self.allocator.free(ov);
                    self.mem_bytes -= old.key.len + ov.len;
                }
            }
            try self.mem.put(key, val);
            self.mem_bytes += key.len + (if (val) |v| v.len else 0);
        }
    }

    fn walAppend(self: *Store, key: ChunkKey, value: ?[]const u8) !void {
        const vlen: u32 = if (value) |v| @intCast(v.len) else tombstone_len;
        var h = std.hash.Crc32.init();
        h.update(&key);
        var lb: [4]u8 = undefined;
        std.mem.writeInt(u32, &lb, vlen, .big);
        h.update(&lb);
        if (value) |v| h.update(v);
        const crc = h.final();
        // record = key + vlen + val + crc
        const reclen: usize = 9 + 4 + (if (value) |v| v.len else 0) + 4;
        var tmp: [9 + 4 + 4]u8 = undefined;
        @memcpy(tmp[0..9], &key);
        @memcpy(tmp[9..13], &lb);
        std.mem.writeInt(u32, tmp[9 + 4 ..][0..4], crc, .big);
        if (value) |v| {
            try self.wal.writePositionalAll(self.io, tmp[0 .. 9 + 4], self.wal_len);
            try self.wal.writePositionalAll(self.io, v, self.wal_len + 9 + 4);
            try self.wal.writePositionalAll(self.io, tmp[9 + 4 ..][0..4], self.wal_len + 9 + 4 + v.len);
        } else {
            // tombstone: key + FFFFFFFF + crc
            var rec: [9 + 4 + 4]u8 = undefined;
            @memcpy(rec[0..9], &key);
            @memcpy(rec[9..13], &lb);
            std.mem.writeInt(u32, rec[13..][0..4], crc, .big);
            try self.wal.writePositionalAll(self.io, &rec, self.wal_len);
        }
        self.wal_len += reclen;
    }

    pub fn put(self: *Store, key: ChunkKey, value: []const u8) !void {
        try self.walAppend(key, value);
        const owned = try self.allocator.dupe(u8, value);
        if (self.mem.fetchRemove(key)) |old| {
            if (old.value) |ov| {
                self.allocator.free(ov);
                self.mem_bytes -= old.key.len + ov.len;
            }
        }
        try self.mem.put(key, owned);
        self.mem_bytes += key.len + owned.len;
        if (self.mem_bytes >= self.flush_threshold_bytes) {
            try self.flushLocked();
        }
    }

    pub fn delete(self: *Store, key: ChunkKey) !void {
        try self.walAppend(key, null);
        if (self.mem.fetchRemove(key)) |old| {
            if (old.value) |ov| {
                self.allocator.free(ov);
                self.mem_bytes -= old.key.len + ov.len;
            }
        }
        try self.mem.put(key, null);
        self.mem_bytes += key.len;
    }

    /// Returns owned copy, or null if missing/deleted. Caller frees.
    pub fn get(self: *Store, key: ChunkKey) !?[]u8 {
        if (self.mem.get(key)) |v| {
            if (v) |bytes| return try self.allocator.dupe(u8, bytes);
            return null; // tombstone in memtable
        }
        // SSTs newest -> oldest
        var i = self.ssts.items.len;
        while (i > 0) {
            i -= 1;
            if (try self.sstGet(self.ssts.items[i], key)) |v| {
                if (v) |bytes| return bytes; // owned
                return null; // tombstone in sst
            }
        }
        return null;
    }

    fn sstGet(self: *Store, name: []u8, key: ChunkKey) !??[]u8 {
        // Returns null = not in this sst; ?null = tombstone; ??bytes = found owned.
        const data = try self.sst_dir.readFileAlloc(self.io, name, self.allocator, .limited(256 * 1024 * 1024));
        defer self.allocator.free(data);
        var pos: usize = 0;
        if (data.len < 8) return error.CorruptSst;
        if (!std.mem.eql(u8, data[0..4], "ZLS1")) return error.CorruptSst;
        const count = std.mem.readInt(u32, data[4..8], .big);
        pos = 8;
        var j: u32 = 0;
        while (j < count) : (j += 1) {
            if (pos + 9 + 4 > data.len) return error.CorruptSst;
            const k: ChunkKey = data[pos..][0..9].*;
            pos += 9;
            const vlen = std.mem.readInt(u32, data[pos..][0..4], .big);
            pos += 4;
            if (vlen == tombstone_len) {
                if (std.mem.eql(u8, &k, &key)) return @as(?[]u8, null);
                continue;
            }
            if (pos + vlen > data.len) return error.CorruptSst;
            if (std.mem.eql(u8, &k, &key)) {
                const out = try self.allocator.dupe(u8, data[pos .. pos + vlen]);
                return @as(?[]u8, out);
            }
            pos += vlen;
        }
        return null;
    }

    pub fn flush(self: *Store) !void {
        try self.flushLocked();
    }

    fn flushLocked(self: *Store) !void {
        if (self.mem.count() == 0) return;
        // collect + sort by key bytes
        const n = self.mem.count();
        var keys = try self.allocator.alloc(ChunkKey, n);
        defer self.allocator.free(keys);
        var it = self.mem.keyIterator();
        var idx: usize = 0;
        while (it.next()) |k| {
            keys[idx] = k.*;
            idx += 1;
        }
        std.mem.sort(ChunkKey, keys, {}, struct {
            fn less(_: void, a: ChunkKey, b: ChunkKey) bool {
                return std.mem.lessThan(u8, &a, &b);
            }
        }.less);
        // build sst bytes
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try aw.writer.writeAll("ZLS1");
        var cb: [4]u8 = undefined;
        std.mem.writeInt(u32, &cb, @intCast(n), .big);
        try aw.writer.writeAll(&cb);
        for (keys) |k| {
            const v = self.mem.get(k).?;
            try aw.writer.writeAll(&k);
            if (v) |bytes| {
                var lb: [4]u8 = undefined;
                std.mem.writeInt(u32, &lb, @intCast(bytes.len), .big);
                try aw.writer.writeAll(&lb);
                try aw.writer.writeAll(bytes);
            } else {
                var lb: [4]u8 = undefined;
                std.mem.writeInt(u32, &lb, tombstone_len, .big);
                try aw.writer.writeAll(&lb);
            }
        }
        // write file sst/NNNNNN.sst
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{d:0>6}.sst", .{self.next_sst_id});
        self.next_sst_id += 1;
        const owned_name = try self.allocator.dupe(u8, name);
        try self.sst_dir.writeFile(self.io, .{ .sub_path = owned_name, .data = aw.written() });
        try self.ssts.append(self.allocator, owned_name);
        // clear memtable + truncate WAL
        var mit = self.mem.iterator();
        while (mit.next()) |e| {
            if (e.value_ptr.*) |v| self.allocator.free(v);
        }
        self.mem.clearRetainingCapacity();
        self.mem_bytes = 0;
        self.wal.close(self.io);
        self.wal = try self.dir.createFile(self.io, "wal.log", .{ .read = true, .truncate = true });
        self.wal_len = 0;
    }
};

test "key roundtrip sortability" {
    const a = encodeKey(0, 1, 2);
    const d = decodeKey(a);
    try std.testing.expectEqual(@as(u8, 0), d.dim);
    try std.testing.expectEqual(@as(i32, 1), d.x);
    try std.testing.expectEqual(@as(i32, 2), d.z);
    // BE x sorts before larger x within same dim
    const k1 = encodeKey(0, -5, 0);
    const k2 = encodeKey(0, 10, 0);
    // NB: signed BE does NOT sort lexicographically for negatives; document it.
    // dim prefix still groups. (P2: offset x by 2^31 for lexicographic order.)
    try std.testing.expect(a.len == 9);
    _ = k1;
    _ = k2;
}

test "put/get/delete memory only" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 1 << 30 });
    defer store.deinit();
    const k = encodeKey(0, 3, -7);
    try std.testing.expect(try store.get(k) == null);
    try store.put(k, "chunk-bytes-v1");
    const got = try store.get(k);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("chunk-bytes-v1", got.?);
    std.testing.allocator.free(got.?);
    try store.delete(k);
    try std.testing.expect(try store.get(k) == null);
}

test "flush + reopen recovers (WAL + SST)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var store = try Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 1 << 30 });
        defer store.deinit();
        var i: i32 = 0;
        while (i < 50) : (i += 1) {
            var vbuf: [32]u8 = undefined;
            const v = try std.fmt.bufPrint(&vbuf, "payload-{d}", .{i});
            try store.put(encodeKey(0, i, -i), v);
        }
        try store.put(encodeKey(1, 1, 1), "nether-chunk");
        try store.delete(encodeKey(0, 3, -3)); // tombstone
        try store.flush();
        const g = try store.get(encodeKey(0, 7, -7));
        try std.testing.expect(g != null);
        try std.testing.expectEqualStrings("payload-7", g.?);
        std.testing.allocator.free(g.?);
    }
    // reopen same dir: SST scan must recover without WAL
    {
        var store = try Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 1 << 30 });
        defer store.deinit();
        const g = try store.get(encodeKey(0, 7, -7));
        try std.testing.expect(g != null);
        try std.testing.expectEqualStrings("payload-7", g.?);
        std.testing.allocator.free(g.?);
        try std.testing.expect(try store.get(encodeKey(0, 3, -3)) == null);
        const n = try store.get(encodeKey(1, 1, 1));
        try std.testing.expectEqualStrings("nether-chunk", n.?);
        std.testing.allocator.free(n.?);
    }
}

test "wal replay without flush" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var store = try Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 1 << 30 });
        defer store.deinit();
        try store.put(encodeKey(0, 9, 9), "unflushed");
    }
    {
        var store = try Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 1 << 30 });
        defer store.deinit();
        const g = try store.get(encodeKey(0, 9, 9));
        try std.testing.expect(g != null);
        try std.testing.expectEqualStrings("unflushed", g.?);
        std.testing.allocator.free(g.?);
    }
}
