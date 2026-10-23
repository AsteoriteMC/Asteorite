//! Pure-Zig embedded LSM-tree chunk store (runtime format, NOT Anvil).
//!
//! Anvil (.mca) is import-only via `world/anvil.zig`. The server runtime
//! stores chunks in this LSM store to avoid the 8KB central header lock:
//! concurrent region threads write via append-only WAL + sorted SSTables.
//!
//! Key schema (9 bytes, lexicographically sortable by dim, then numeric x, z):
//!   [dim:u8 | x+2^31:u32 BE | z+2^31:u32 BE]
//! The 2^31 bias (sign-bit flip) maps signed order onto unsigned byte order,
//! so plain byte comparison sorts negatives before positives. Databases
//! written before the bias (P1) are NOT readable by this code — reimport via
//! `tools/anvil_import.zig` (Anvil remains the migration path).
//! Value: opaque caller bytes (versioned chunk payload). Tombstone = delete.
//!
//! Layout inside db dir:
//!   MANIFEST           text listing live SSTs + next id (tmp-file + rename)
//!   wal.log            append-only [key 9][vlen u32 BE][val][crc32 u32 BE]; vlen=0xFFFFFFFF => tombstone
//!   sst/NNNNNN.sst     sorted runs: header magic + count + entries [key 9][vlen u32 BE][val]
//!                      + footer (ZLS2 only): sparse block index + Bloom filter + CRC
//! SST generations: "ZLS1" (legacy: no footer, linear scan) and "ZLS2"
//! (current writer: footer with index + Bloom + CRC; crash-safe tmp+rename).
//! Compaction merges runs and swaps the MANIFEST atomically; a crash between
//! the new-SST rename and MANIFEST swap leaves orphans that `zig build check`
//! lists and the next open ignores (never resurrected into the live set).
//!
//! Threading: P1 single-writer + P2 per-region sharding (see plan).
//! No internal lock yet — region threads own disjoint key ranges via dim/x/z
//! sharding. P2 will add `std.Io.RwLock` per shard + seqlock for reads.
//!
//! Crash model: WAL tail torn by kill -9 is truncated to the last valid
//! record on open (append-only + per-record CRC makes the prefix provable).
//! SST/MANIFEST files are written to `*.tmp` + fsync + rename, so a crash can
//! only leave orphans, never half-visible runs. fsync policy for the WAL hot
//! path is `Options.wal_sync_bytes` (0 = sync on flush/close only).
//!
//! Snapshot procedure (cheap because SSTs are immutable): quiesce writes,
//! `flushAll` (or per-shard `snapshot`, which flushes itself), then copy the
//! MANIFEST + listed SST files. The copy opens as a working store; its WAL
//! starts empty. Documented here because the code is the procedure.

const std = @import("std");
const builtin = @import("builtin");
/// Linux-only ring (stub elsewhere): the `if` keeps `uring_io.zig` — and
/// transitively `std.os.linux.IoUring`, which does not compile for other
/// targets — out of analysis off Linux. Same pattern as the net backends.
const uring_io = if (builtin.os.tag == .linux) @import("uring_io.zig") else struct {
    pub const RingStats = struct {
        ring_reads: u64 = 0,
        fallback_reads: u64 = 0,
    };
    pub const RingIo = struct {
        stats: RingStats = .{},
        pub fn init(_: std.mem.Allocator, _: usize) !RingIo {
            return error.NoUring;
        }
        pub fn deinit(_: *RingIo) void {}
        pub fn bufLen(_: *const RingIo) usize {
            return 0;
        }
        pub fn registerFiles(_: *RingIo, _: []const std.posix.fd_t) !void {}
        pub fn readAt(_: *RingIo, _: u32, _: u64, _: usize) ![]u8 {
            return error.Fallback;
        }
        pub fn noteFallback(_: *RingIo) void {}
    };
    pub fn probe() bool {
        return false;
    }
};

pub const key_len = 9;
pub const ChunkKey = [key_len]u8;
pub const tombstone_len: u32 = 0xFFFFFFFF;

pub fn encodeKey(dim: u8, x: i32, z: i32) ChunkKey {
    var k: ChunkKey = undefined;
    k[0] = dim;
    // Bias by 2^31 so signed order == lexicographic byte order.
    std.mem.writeInt(u32, k[1..5], @as(u32, @bitCast(x)) ^ 0x8000_0000, .big);
    std.mem.writeInt(u32, k[5..9], @as(u32, @bitCast(z)) ^ 0x8000_0000, .big);
    return k;
}

pub fn decodeKey(k: ChunkKey) struct { dim: u8, x: i32, z: i32 } {
    return .{
        .dim = k[0],
        .x = @as(i32, @bitCast(std.mem.readInt(u32, k[1..5], .big) ^ 0x8000_0000)),
        .z = @as(i32, @bitCast(std.mem.readInt(u32, k[5..9], .big) ^ 0x8000_0000)),
    };
}

pub const StoreError = error{
    CorruptWal,
    CorruptSst,
    OutOfMemory,
} || std.Io.Dir.OpenError || std.Io.Dir.CreateFileError || std.Io.File.OpenError ||
    std.Io.File.Writer.Error || std.Io.File.Reader.Error || std.Io.File.ReadPositionalError || std.mem.Allocator.Error;

// ---------------------------------------------------------------------------
// SST format (ZLS2 writer; ZLS1 legacy reader).
// ---------------------------------------------------------------------------

pub const sst_magic_zls1 = "ZLS1";
pub const sst_magic_zls2 = "ZLS2";
pub const sst_footer_magic = "ZLSF";
/// Tail: [footer_offset u32 BE][crc u32 BE]["ZLSF"]; crc covers [0, crc_pos).
pub const sst_footer_tail_len = 4 + 4 + 4;
/// One index sample per this many entries.
pub const sst_index_stride = 16;
/// Bloom hash functions probed per key.
pub const bloom_k = 7;

pub const manifest_name = "MANIFEST";
pub const manifest_tmp_name = "MANIFEST.tmp";
pub const manifest_magic = "ZLSM-MANIFEST-1";
pub const sst_tmp_suffix = ".tmp";

pub const IndexEntry = struct {
    key: ChunkKey,
    /// Absolute file offset of this entry's key.
    offset: u32,
};

/// In-memory per-SST read metadata. Legacy files carry empty bloom/index,
/// which degrades to "always scan" (correct, just slower).
pub const SstMeta = struct {
    name: []u8, // owned "NNNNNN.sst"
    count: u32,
    bloom: []u8, // owned bits; empty == legacy (no filter)
    bloom_bits: u32,
    index: []IndexEntry, // owned, sorted by key
    entries_end: usize, // offset where entries end (footer start for ZLS2)
    /// Open read handle for the SST file (NVMe profile only: fixed-file
    /// reads + no per-lookup open/close). Null on the plain path.
    file: ?std.Io.File = null,
    /// Fixed-file table index after `syncRingFiles` (null = pread path).
    fixed_index: ?u32 = null,

    pub fn deinit(self: *SstMeta, alloc: std.mem.Allocator, io: std.Io) void {
        if (self.file) |f| {
            f.close(io);
            self.file = null;
        }
        alloc.free(self.name);
        if (self.bloom.len > 0) alloc.free(self.bloom);
        if (self.index.len > 0) alloc.free(self.index);
    }

    pub fn mayContain(self: *const SstMeta, key: ChunkKey) bool {
        if (self.bloom.len == 0) return true; // legacy: no filter
        for (0..bloom_k) |i| {
            const bit = bloomBit(self.bloom_bits, key, @as(u32, @intCast(i)));
            if (self.bloom[bit >> 3] & (@as(u8, 1) << @as(u3, @truncate(bit & 7))) == 0) return false;
        }
        return true;
    }
};

fn bloomBitsFor(count: u32) u32 {
    // ~16 bits/key, min 64 bits, byte-rounded.
    const want: u64 = @as(u64, @max(count, @as(u32, 4))) * 16;
    const bits: u64 = @max(@as(u64, 64), want);
    return @as(u32, @intCast((bits + 7) / 8 * 8));
}

fn bloomBit(bloom_bits: u32, key: ChunkKey, i: u32) u32 {
    const h = std.hash.Wyhash.hash(@as(u64, 0x9E3779B97F4A7C15) +% i, &key);
    return @as(u32, @truncate(h % bloom_bits));
}

fn bloomAdd(bloom: []u8, bloom_bits: u32, key: ChunkKey) void {
    for (0..bloom_k) |i| {
        const bit = bloomBit(bloom_bits, key, @as(u32, @intCast(i)));
        bloom[bit >> 3] |= @as(u8, 1) << @as(u3, @truncate(bit & 7));
    }
}

const SstEntry = struct {
    key: ChunkKey,
    value: ?[]const u8, // borrowed
};

/// Build a complete ZLS2 file image from sorted entries (borrowed values).
fn buildSstFile(alloc: std.mem.Allocator, entries: []const SstEntry) ![]u8 {
    std.debug.assert(entries.len > 0);
    std.debug.assert(entries.len <= std.math.maxInt(u32));
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    try aw.writer.writeAll(sst_magic_zls2);
    var cb: [4]u8 = undefined;
    std.mem.writeInt(u32, &cb, @as(u32, @intCast(entries.len)), .big);
    try aw.writer.writeAll(&cb);
    var index = std.ArrayList(IndexEntry).empty;
    defer index.deinit(alloc);
    const count: u32 = @as(u32, @intCast(entries.len));
    const bits = bloomBitsFor(count);
    const bloom = try alloc.alloc(u8, bits / 8);
    defer alloc.free(bloom);
    @memset(bloom, 0);
    for (entries, 0..) |e, i| {
        if (i % sst_index_stride == 0) {
            try index.append(alloc, .{ .key = e.key, .offset = @as(u32, @intCast(aw.written().len)) });
        }
        bloomAdd(bloom, bits, e.key);
        try aw.writer.writeAll(&e.key);
        if (e.value) |v| {
            std.debug.assert(v.len != tombstone_len);
            var lb: [4]u8 = undefined;
            std.mem.writeInt(u32, &lb, @as(u32, @intCast(v.len)), .big);
            try aw.writer.writeAll(&lb);
            try aw.writer.writeAll(v);
        } else {
            var lb: [4]u8 = undefined;
            std.mem.writeInt(u32, &lb, tombstone_len, .big);
            try aw.writer.writeAll(&lb);
        }
    }
    const footer_offset: u32 = @as(u32, @intCast(aw.written().len));
    var ib: [4]u8 = undefined;
    std.mem.writeInt(u32, &ib, @as(u32, @intCast(index.items.len)), .big);
    try aw.writer.writeAll(&ib);
    for (index.items) |ie| {
        try aw.writer.writeAll(&ie.key);
        var ob: [4]u8 = undefined;
        std.mem.writeInt(u32, &ob, ie.offset, .big);
        try aw.writer.writeAll(&ob);
    }
    var bb: [4]u8 = undefined;
    std.mem.writeInt(u32, &bb, @as(u32, @intCast(bloom.len)), .big);
    try aw.writer.writeAll(&bb);
    try aw.writer.writeAll(bloom);
    var tb: [4]u8 = undefined;
    std.mem.writeInt(u32, &tb, footer_offset, .big);
    try aw.writer.writeAll(&tb);
    const crc_pos = aw.written().len;
    var h = std.hash.Crc32.init();
    h.update(aw.written()[0..crc_pos]);
    var hb: [4]u8 = undefined;
    std.mem.writeInt(u32, &hb, h.final(), .big);
    try aw.writer.writeAll(&hb);
    try aw.writer.writeAll(sst_footer_magic);
    const out = try alloc.dupe(u8, aw.written());
    aw.deinit();
    return out;
}

/// Borrowed parse of an SST image. Validates structure (and footer CRC for
/// ZLS2) but never allocates.
const ParsedSst = struct {
    zls2: bool,
    count: u32,
    entries_end: usize, // entries occupy [8, entries_end)
    index_count: u32,
    index_base: usize, // first index entry (key9+off4 each)
    bloom: []const u8,
};

fn parseSst(data: []const u8) error{CorruptSst}!ParsedSst {
    if (data.len < 8) return error.CorruptSst;
    const is_zls2 = std.mem.eql(u8, data[0..4], sst_magic_zls2);
    if (!is_zls2 and !std.mem.eql(u8, data[0..4], sst_magic_zls1)) return error.CorruptSst;
    const count = std.mem.readInt(u32, data[4..8], .big);
    if (!is_zls2) {
        return .{
            .zls2 = false,
            .count = count,
            .entries_end = data.len,
            .index_count = 0,
            .index_base = 0,
            .bloom = &.{},
        };
    }
    if (data.len < 8 + sst_footer_tail_len) return error.CorruptSst;
    if (!std.mem.eql(u8, data[data.len - 4 ..], sst_footer_magic)) return error.CorruptSst;
    const footer_offset = std.mem.readInt(u32, data[data.len - 12 ..][0..4], .big);
    const want_crc = std.mem.readInt(u32, data[data.len - 8 ..][0..4], .big);
    if (footer_offset < 8 or footer_offset > data.len - sst_footer_tail_len) return error.CorruptSst;
    var h = std.hash.Crc32.init();
    h.update(data[0 .. data.len - 8]);
    if (h.final() != want_crc) return error.CorruptSst;
    var pos: usize = footer_offset;
    if (pos + 4 > data.len - sst_footer_tail_len) return error.CorruptSst;
    const index_count = std.mem.readInt(u32, data[pos..][0..4], .big);
    pos += 4;
    const index_base = pos;
    const index_bytes = @as(usize, index_count) * (key_len + 4);
    if (pos + index_bytes + 4 > data.len - sst_footer_tail_len) return error.CorruptSst;
    pos += index_bytes;
    const bloom_len = std.mem.readInt(u32, data[pos..][0..4], .big);
    pos += 4;
    if (pos + bloom_len != data.len - sst_footer_tail_len) return error.CorruptSst;
    return .{
        .zls2 = true,
        .count = count,
        .entries_end = footer_offset,
        .index_count = index_count,
        .index_base = index_base,
        .bloom = data[pos..][0..bloom_len],
    };
}

fn parsedIndexEntry(data: []const u8, p: ParsedSst, i: u32) IndexEntry {
    const off = p.index_base + @as(usize, i) * (key_len + 4);
    return .{
        .key = data[off..][0..key_len].*,
        .offset = std.mem.readInt(u32, data[off + key_len ..][0..4], .big),
    };
}

/// Full structural audit of one SST image: entry bounds, key order, count.
const SstAudit = struct {
    count: u32,
    sorted: bool,
    tombstones: u64,
};

fn auditSstEntries(data: []const u8, p: ParsedSst) error{CorruptSst}!SstAudit {
    var pos: usize = 8;
    var prev: ?ChunkKey = null;
    var sorted = true;
    var seen: u64 = 0;
    var tombs: u64 = 0;
    while (pos < p.entries_end) {
        if (pos + key_len + 4 > p.entries_end) return error.CorruptSst;
        const k: ChunkKey = data[pos..][0..key_len].*;
        pos += key_len;
        const vlen = std.mem.readInt(u32, data[pos..][0..4], .big);
        pos += 4;
        if (vlen == tombstone_len) {
            tombs += 1;
        } else {
            if (pos + vlen > p.entries_end) return error.CorruptSst;
            pos += vlen;
        }
        if (prev) |pk| {
            if (!std.mem.lessThan(u8, &pk, &k)) sorted = false;
        }
        prev = k;
        seen += 1;
    }
    if (seen != p.count) return error.CorruptSst;
    return .{ .count = p.count, .sorted = sorted, .tombstones = tombs };
}

// ---------------------------------------------------------------------------
// WAL records.
// ---------------------------------------------------------------------------

const WalRecord = struct {
    key: ChunkKey,
    vlen: u32,
    val: ?[]const u8, // borrowed
    total_len: usize,
};

fn parseWalRecord(data: []const u8, pos: usize) error{ Truncated, BadCrc }!WalRecord {
    if (pos + key_len + 4 + 4 > data.len) return error.Truncated;
    const key: ChunkKey = data[pos..][0..key_len].*;
    const vlen = std.mem.readInt(u32, data[pos + key_len ..][0..4], .big);
    var val: ?[]const u8 = null;
    var end = pos + key_len + 4 + 4;
    if (vlen != tombstone_len) {
        end = pos + key_len + 4 + vlen + 4;
        if (end > data.len) return error.Truncated;
        val = data[pos + key_len + 4 ..][0..vlen];
    }
    var h = std.hash.Crc32.init();
    h.update(&key);
    var lb: [4]u8 = undefined;
    std.mem.writeInt(u32, &lb, vlen, .big);
    h.update(&lb);
    if (val) |v| h.update(v);
    if (h.final() != std.mem.readInt(u32, data[end - 4 ..][0..4], .big)) return error.BadCrc;
    return .{ .key = key, .vlen = vlen, .val = val, .total_len = end - pos };
}

// ---------------------------------------------------------------------------
// MANIFEST.
// ---------------------------------------------------------------------------

const ManifestData = struct {
    next_id: u32,
    names: [][]u8, // owned, oldest->newest
    fn deinit(self: *ManifestData, alloc: std.mem.Allocator) void {
        for (self.names) |n| alloc.free(n);
        alloc.free(self.names);
    }
};

fn parseManifestData(alloc: std.mem.Allocator, data: []const u8) error{ Invalid, OutOfMemory }!ManifestData {
    var names = std.ArrayList([]u8).empty;
    errdefer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    var next_id: ?u32 = null;
    var it = std.mem.splitScalar(u8, data, '\n');
    const first = it.next() orelse return error.Invalid;
    if (!std.mem.eql(u8, first, manifest_magic)) return error.Invalid;
    var done = false;
    while (it.next()) |line| {
        if (done) {
            if (line.len != 0) return error.Invalid;
            continue;
        }
        if (line.len == 0) {
            done = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "next: ")) {
            if (next_id != null) return error.Invalid;
            next_id = std.fmt.parseInt(u32, line["next: ".len..], 10) catch return error.Invalid;
        } else if (std.mem.startsWith(u8, line, "sst: ")) {
            const name = line["sst: ".len..];
            if (!std.mem.endsWith(u8, name, ".sst") or std.mem.indexOfScalar(u8, name, '/') != null) return error.Invalid;
            for (names.items) |n| {
                if (std.mem.eql(u8, n, name)) return error.Invalid;
            }
            try names.append(alloc, try alloc.dupe(u8, name));
        } else {
            return error.Invalid;
        }
    }
    const nid = next_id orelse return error.Invalid;
    if (nid == 0) return error.Invalid;
    return .{ .next_id = nid, .names = try names.toOwnedSlice(alloc) };
}

// ---------------------------------------------------------------------------
// Store.
// ---------------------------------------------------------------------------

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir, // db dir (borrowed)
    sst_dir: std.Io.Dir, // db/sst (owned, close on deinit)
    wal: std.Io.File, // wal.log (owned)
    wal_len: u64,
    bytes_since_sync: u64,
    mem: std.HashMap(ChunkKey, ?[]u8, KeyCtx, 80),
    mem_bytes: usize,
    ssts: std.ArrayList(SstMeta), // owned metas, oldest->newest
    next_sst_id: u32,
    flush_threshold_bytes: usize,
    wal_sync_bytes: usize,
    compact_threshold_ssts: usize,
    /// NVMe profile: keep SST files open for the store lifetime (no
    /// per-lookup open/close) and serve stride reads from the io_uring
    /// ring (registered buffers + fixed files). The ring is best-effort:
    /// a kernel that refuses it still serves, on plain pread.
    keep_sst_open: bool = false,
    /// Largest stride the ring will serve (bigger strides use pread even
    /// when the ring buffer could hold them).
    uring_max_bytes: usize = 8 * 1024 * 1024,
    /// io_uring read ring (null = plain pread path). Owned; only present
    /// when `keep_sst_open` and the kernel accepted the ring.
    ring: ?uring_io.RingIo = null,
    /// Guards memtable + live SST list (mem/put + get + flush/compact swap).
    /// Serve threads read without the world lock while the ticker (player
    /// saves) and gen workers write + flush/compact: without this, a
    /// compaction swapping `ssts` under a concurrent `get` served transient
    /// holes in already-generated chunks (client "chunk errors"). Leaf lock:
    /// never held while acquiring world/conn locks. Uncontended cost is one
    /// atomic op per call; flush/compact hold it across file IO (serve reads
    /// stall for the duration — seconds worst case on big DBs, well under
    /// the 30s keepalive timeout; backgrounding is Phase C/H5).
    mutex: std.Io.Mutex = .init,

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
        /// fsync the WAL after this many appended bytes (0 = sync on
        /// flush/close only, the P1 behavior). Smaller = less loss window,
        /// more syscalls; batching belongs with the HDD profile (Phase E).
        wal_sync_bytes: usize = 0,
        /// Auto-compact when live SST count reaches this (0 = manual only).
        /// Synchronous (simplest-correct-first); backgrounding is Phase C/H5.
        compact_threshold_ssts: usize = 8,
        /// NVMe storage path: keep SST files open + serve stride reads
        /// through io_uring (registered buffers + fixed files). Best
        /// effort — a kernel that refuses the ring still serves on pread.
        use_uring_io: bool = false,
        /// Largest stride the ring will serve (bigger strides use pread).
        /// Covers the 8 MiB stride cap by default; tests set it tiny to
        /// exercise the fallback path deterministically.
        uring_max_bytes: usize = 8 * 1024 * 1024,
    };

    /// Open (or create) db in `dir`. Creates `sst/` + `wal.log` as needed,
    /// replays WAL into memtable, loads MANIFEST (or scans `sst/` legacy).
    /// Crash leftovers: torn WAL tail truncated, `*.tmp` + unlisted SSTs
    /// removed (their data is covered by WAL replay or the merged run).
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
            .bytes_since_sync = 0,
            .mem = .init(allocator),
            .mem_bytes = 0,
            .ssts = .empty,
            .next_sst_id = 1,
            .flush_threshold_bytes = opts.flush_threshold_bytes,
            .wal_sync_bytes = opts.wal_sync_bytes,
            .compact_threshold_ssts = opts.compact_threshold_ssts,
            .keep_sst_open = opts.use_uring_io,
            .uring_max_bytes = opts.uring_max_bytes,
        };
        errdefer {
            self.sst_dir.close(io);
            self.mem.deinit();
            self.ssts.deinit(allocator);
        }
        // Element deinit for anything appended to ssts below (runs before
        // the array itself is freed above on error unwind).
        errdefer {
            for (self.ssts.items) |*m| m.deinit(allocator, io);
        }

        try self.cleanupTmps();

        // MANIFEST (or legacy scan) determines the live set.
        const manifest = try self.loadManifest();
        defer {
            if (manifest) |*m| {
                var mm = m.*;
                mm.deinit(allocator);
            }
        }
        var existing = std.ArrayList([]u8).empty;
        defer {
            for (existing.items) |n| allocator.free(n);
            existing.deinit(allocator);
        }
        var max_id: u32 = 0;
        {
            var it = self.sst_dir.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind != .file) continue;
                if (std.mem.endsWith(u8, entry.name, sst_tmp_suffix)) continue;
                if (!std.mem.endsWith(u8, entry.name, ".sst")) continue;
                const stem = entry.name[0 .. entry.name.len - 4];
                const id = std.fmt.parseInt(u32, stem, 10) catch continue;
                if (id > max_id) max_id = id;
                try existing.append(allocator, try allocator.dupe(u8, entry.name));
            }
        }
        // Numeric sort (lexicographic breaks past 999999).
        std.mem.sort([]u8, existing.items, {}, struct {
            fn less(_: void, a: []u8, b: []u8) bool {
                const ai = std.fmt.parseInt(u32, a[0 .. a.len - 4], 10) catch 0;
                const bi = std.fmt.parseInt(u32, b[0 .. b.len - 4], 10) catch 0;
                return ai < bi;
            }
        }.less);

        var next_id: u32 = max_id + 1;
        if (manifest) |m| {
            if (m.next_id > next_id) next_id = m.next_id;
            for (m.names) |listed| {
                const found = for (existing.items) |e| {
                    if (std.mem.eql(u8, e, listed)) break true;
                } else false;
                if (!found) {
                    std.log.warn("store: MANIFEST lists missing {s}, dropping", .{listed});
                    continue;
                }
                const meta = try self.loadSstMeta(listed);
                try self.ssts.append(allocator, meta);
            }
        } else {
            for (existing.items) |name| {
                const meta = try self.loadSstMeta(name);
                try self.ssts.append(allocator, meta);
            }
        }
        self.next_sst_id = next_id;

        // open or create wal.log
        self.wal = try self.dir.createFile(self.io, "wal.log", .{ .read = true, .truncate = false });
        errdefer self.wal.close(self.io);
        self.wal_len = try self.wal.length(io);
        if (self.wal_len > 0) {
            try self.replayWal();
        }

        // Orphans (unlisted SSTs) are covered: either duplicated in the live
        // set (compaction leftovers) or replayed from WAL (flush leftovers).
        try self.deleteOrphans(if (manifest) |m| m.names else null);
        // Persist the reconciled live set (also upgrades legacy dir-scan DBs).
        try self.writeManifest();

        // NVMe path: bring up the ring (best-effort) and register the
        // live SST files as fixed files. A kernel that refuses the ring
        // still serves: the kept-open files take the plain pread path.
        if (self.keep_sst_open) {
            self.ring = uring_io.RingIo.init(allocator, opts.uring_max_bytes) catch |err| blk: {
                if (err != error.NoUring) return err;
                std.log.info("store: io_uring unavailable, SST reads use pread", .{});
                break :blk null;
            };
            if (self.ring != null) {
                self.syncRingFiles() catch {
                    // Registration failed after init: drop the ring, keep
                    // the open files (plain pread from here on).
                    self.ring.?.deinit();
                    self.ring = null;
                };
            }
        }
        // NOTE: no errdefer for the ring here: it is created after the
        // last fallible call, so open() cannot fail with a live ring.

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
        // The ring holds kernel references to the SST files: unregister
        // first, then close the files via the metas below.
        if (self.ring) |*r| r.deinit();
        self.ring = null;
        for (self.ssts.items) |*m| m.deinit(self.allocator, self.io);
        self.ssts.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Caller must also close `db_dir` from openPath after store.close().
    pub fn deinit(self: *Store) void {
        self.close();
    }

    /// Delete `*.tmp` + `MANIFEST.tmp` crash leftovers (best-effort).
    fn cleanupTmps(self: *Store) !void {
        var doomed = std.ArrayList([]u8).empty;
        defer {
            for (doomed.items) |n| self.allocator.free(n);
            doomed.deinit(self.allocator);
        }
        {
            var it = self.sst_dir.iterate();
            while (try it.next(self.io)) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, sst_tmp_suffix)) continue;
                try doomed.append(self.allocator, try self.allocator.dupe(u8, entry.name));
            }
        }
        for (doomed.items) |n| {
            self.sst_dir.deleteFile(self.io, n) catch {};
        }
        self.dir.deleteFile(self.io, manifest_tmp_name) catch {};
    }

    /// Parse MANIFEST; null when missing OR invalid (caller falls back to a
    /// dir scan, which is the safe superset — newest-wins by numeric name).
    fn loadManifest(self: *Store) !?ManifestData {
        const data = self.dir.readFileAlloc(self.io, manifest_name, self.allocator, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer self.allocator.free(data);
        const parsed = parseManifestData(self.allocator, data) catch return null;
        return parsed;
    }

    fn writeManifest(self: *Store) !void {
        try self.writeManifestList(self.ssts.items);
    }

    fn writeManifestList(self: *Store, list: []const SstMeta) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try aw.writer.writeAll(manifest_magic ++ "\n");
        try aw.writer.print("next: {d}\n", .{self.next_sst_id});
        for (list) |m| {
            try aw.writer.print("sst: {s}\n", .{m.name});
        }
        try self.writeAtomic(self.dir, manifest_tmp_name, manifest_name, aw.written());
    }

    /// Write bytes to `tmp_name` (sync) then rename onto `final_name`.
    /// Crash-safe: observers only ever see the old or the new file.
    fn writeAtomic(self: *Store, dir: std.Io.Dir, tmp_name: []const u8, final_name: []const u8, bytes: []const u8) !void {
        var f = try dir.createFile(self.io, tmp_name, .{ .read = false, .truncate = true });
        errdefer {
            f.close(self.io);
            dir.deleteFile(self.io, tmp_name) catch {};
        }
        try f.writePositionalAll(self.io, bytes, 0);
        try f.sync(self.io);
        f.close(self.io);
        try dir.rename(tmp_name, dir, final_name, self.io);
    }

    fn loadSstMeta(self: *Store, name: []const u8) !SstMeta {
        const data = try self.sst_dir.readFileAlloc(self.io, name, self.allocator, .limited(256 * 1024 * 1024));
        defer self.allocator.free(data);
        const p = try parseSst(data);
        var meta = SstMeta{
            .name = try self.allocator.dupe(u8, name),
            .count = p.count,
            .bloom = &.{},
            .bloom_bits = 0,
            .index = &.{},
            .entries_end = p.entries_end,
        };
        errdefer meta.deinit(self.allocator, self.io);
        if (p.zls2) {
            meta.bloom = try self.allocator.dupe(u8, p.bloom);
            errdefer self.allocator.free(meta.bloom);
            const idx = try self.allocator.alloc(IndexEntry, p.index_count);
            errdefer self.allocator.free(idx);
            for (idx, 0..) |*ie, i| {
                ie.* = parsedIndexEntry(data, p, @as(u32, @intCast(i)));
            }
            meta.index = idx;
            meta.bloom_bits = @as(u32, @intCast(meta.bloom.len * 8));
        }
        // NVMe path: keep the file open for fixed-file reads. A file
        // that cannot be opened degrades to per-lookup open (the plain
        // behavior) — never a hard error.
        if (self.keep_sst_open) {
            meta.file = self.sst_dir.openFile(self.io, meta.name, .{}) catch null;
        }
        return meta;
    }

    /// Rebuild the ring's fixed-file table from the live SST list
    /// (positional: each meta's `fixed_index` is its slot). No-op without
    /// a ring. Called after every SST-set change (open/flush/compact).
    /// On failure the caller tears the ring down (plain path from then on).
    fn syncRingFiles(self: *Store) !void {
        const r = &(self.ring orelse return);
        errdefer {
            // Registration failed: the indices below describe a table
            // that was never installed — clear them so no stale index
            // can ever address the wrong file.
            for (self.ssts.items) |*m| m.fixed_index = null;
        }
        var fds = std.ArrayList(std.posix.fd_t).empty;
        defer fds.deinit(self.allocator);
        for (self.ssts.items) |*m| {
            m.fixed_index = null;
            if (m.file) |f| {
                m.fixed_index = @intCast(fds.items.len);
                try fds.append(self.allocator, f.handle);
            }
        }
        try r.registerFiles(fds.items);
    }

    /// Ring counters for tests/bench (zeros on the plain path).
    pub fn ringStats(self: *Store) uring_io.RingStats {
        if (self.ring) |*r| return r.stats;
        return .{};
    }

    /// True when SST stride reads go through the ring (tests/bench).
    pub fn ringActive(self: *Store) bool {
        return self.ring != null;
    }

    fn deleteOrphans(self: *Store, live: ?[][]u8) !void {
        var doomed = std.ArrayList([]u8).empty;
        defer {
            for (doomed.items) |n| self.allocator.free(n);
            doomed.deinit(self.allocator);
        }
        {
            var it = self.sst_dir.iterate();
            while (try it.next(self.io)) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".sst")) continue;
                const listed = if (live) |names| blk: {
                    for (names) |n| {
                        if (std.mem.eql(u8, n, entry.name)) break :blk true;
                    }
                    break :blk false;
                } else true; // no manifest: scan fallback owns everything
                if (!listed) {
                    try doomed.append(self.allocator, try self.allocator.dupe(u8, entry.name));
                }
            }
        }
        for (doomed.items) |n| {
            self.sst_dir.deleteFile(self.io, n) catch |err| {
                std.log.warn("store: orphan {s} not deleted: {}", .{ n, err });
            };
        }
    }

    fn replayWal(self: *Store) !void {
        const data = try self.dir.readFileAlloc(self.io, "wal.log", self.allocator, .limited(256 * 1024 * 1024));
        defer self.allocator.free(data);
        var pos: usize = 0;
        while (pos < data.len) {
            const rec = parseWalRecord(data, pos) catch |err| switch (err) {
                error.Truncated => break, // torn tail from kill -9: prefix is provable, tail is not
                error.BadCrc => return error.CorruptWal,
            };
            const val: ?[]u8 = if (rec.val) |v| try self.allocator.dupe(u8, v) else null;
            errdefer if (val) |v| self.allocator.free(v);
            if (self.mem.fetchRemove(rec.key)) |old| {
                if (old.value) |ov| {
                    self.allocator.free(ov);
                    self.mem_bytes -= old.key.len + ov.len;
                }
            }
            try self.mem.put(rec.key, val);
            self.mem_bytes += rec.key.len + (if (val) |v| v.len else 0);
            pos += rec.total_len;
        }
        if (pos < data.len) {
            // Truncate the torn tail so the next append lands on valid data.
            // NOTE: std.log output during `zig build test` makes this 0.16.0
            // runner print the test command with a "failed command:" prefix
            // even though the step succeeds (exit 0, all tests counted).
            // Cosmetic toolchain artifact; keep the warning (silent WAL
            // truncation would be far worse operationally).
            std.log.warn("store: wal torn tail {d} bytes truncated", .{data.len - pos});
            try self.wal.setLength(self.io, pos);
            self.wal_len = pos;
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
        self.bytes_since_sync += reclen;
        if (self.wal_sync_bytes > 0 and self.bytes_since_sync >= self.wal_sync_bytes) {
            try self.wal.sync(self.io);
            self.bytes_since_sync = 0;
        }
    }

    /// Force the WAL to stable storage (fsync policy hook + tests).
    pub fn syncWal(self: *Store) !void {
        try self.wal.sync(self.io);
        self.bytes_since_sync = 0;
    }

    pub fn put(self: *Store, key: ChunkKey, value: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
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
            if (self.compact_threshold_ssts > 0 and self.ssts.items.len >= self.compact_threshold_ssts) {
                try self.compactLocked();
            }
        }
    }

    pub fn delete(self: *Store, key: ChunkKey) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
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

    /// Returns owned copy, or null if missing/deleted. Caller frees with
    /// `alloc`. (File reads and value copies use `alloc` too — the store's
    /// own allocator may be a never-reset arena, which must never back
    /// per-request bytes.)
    pub fn get(self: *Store, alloc: std.mem.Allocator, key: ChunkKey) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.mem.get(key)) |v| {
            if (v) |bytes| return try alloc.dupe(u8, bytes);
            return null; // tombstone in memtable
        }
        // SSTs newest -> oldest; Bloom skips files that cannot contain key.
        var i = self.ssts.items.len;
        while (i > 0) {
            i -= 1;
            const meta = &self.ssts.items[i];
            if (!meta.mayContain(key)) continue;
            if (try self.sstGet(alloc, meta, key)) |v| {
                if (v) |bytes| return bytes; // owned
                return null; // tombstone in sst
            }
        }
        return null;
    }

    /// Scan one stride buffer for `key`. Returns null = absent;
    /// ?null = tombstone; ??bytes = found (owned dupe via `alloc`).
    fn scanEntries(alloc: std.mem.Allocator, buf: []const u8, key: ChunkKey) !??[]u8 {
        var pos: usize = 0;
        while (pos < buf.len) {
            if (pos + key_len + 4 > buf.len) return error.CorruptSst;
            const k: ChunkKey = buf[pos..][0..key_len].*;
            pos += key_len;
            const vlen = std.mem.readInt(u32, buf[pos..][0..4], .big);
            pos += 4;
            if (vlen == tombstone_len) {
                if (std.mem.eql(u8, &k, &key)) return @as(?[]u8, null);
                continue;
            }
            if (pos + vlen > buf.len) return error.CorruptSst;
            if (std.mem.eql(u8, &k, &key)) {
                const out = try alloc.dupe(u8, buf[pos .. pos + vlen]);
                return @as(?[]u8, out);
            }
            pos += vlen;
        }
        return null;
    }

    fn sstGet(self: *Store, alloc: std.mem.Allocator, meta: *const SstMeta, key: ChunkKey) !??[]u8 {
        // Returns null = not in this sst; ?null = tombstone; ??bytes = found owned.
        if (meta.index.len == 0) return self.sstGetLegacy(alloc, meta, key);
        // ZLS2: bound the scan to a single index stride using the in-memory
        // index. Reading the whole file per lookup pinned ~1GB+ transient
        // across a login burst (and stalled the serve thread for tens of
        // seconds on cold 89MB databases -> keepalive timeout kicks).
        // Binary search: last sample with sample.key <= key.
        var lo: usize = 0;
        var hi: usize = meta.index.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.lessThan(u8, &meta.index[mid].key, &key) or std.mem.eql(u8, &meta.index[mid].key, &key)) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        const start: usize = if (lo > 0) meta.index[lo - 1].offset else 8;
        const end: usize = if (lo < meta.index.len) meta.index[lo].offset else meta.entries_end;
        if (end <= start or start < 8 or end > meta.entries_end) return error.CorruptSst;
        const range_len = end - start;
        // One stride of entries (writer stride 16, chunk payloads < 300KB):
        // ~1MB worst case. Refuse absurd ranges (torn file) instead of
        // trusting a corrupt offset into a huge alloc + read.
        if (range_len > 8 * 1024 * 1024) return error.CorruptSst;
        // NVMe path: the stride goes through the ring (fixed file +
        // registered buffer, no per-IO pinning or fd lookup). The slice
        // aliases the ring buffer — parsed (and the hit duped) below,
        // before any other ring use. Any miss here falls through to the
        // plain pread path: same bytes, slower road.
        if (self.ring) |*r| {
            if (meta.fixed_index) |fi| {
                if (range_len <= self.uring_max_bytes) {
                    if (r.readAt(fi, start, range_len)) |rb| {
                        return try scanEntries(alloc, rb, key);
                    } else |_| r.noteFallback();
                } else r.noteFallback();
            } else r.noteFallback();
        }
        // Plain path: one stride via pread. The kept-open file (NVMe
        // profile without a working ring) still skips the per-lookup
        // open/close; otherwise the file is opened per lookup as before.
        var owned: ?std.Io.File = null;
        defer if (owned) |f| f.close(self.io);
        const fh: std.Io.File = meta.file orelse blk: {
            owned = try self.sst_dir.openFile(self.io, meta.name, .{});
            break :blk owned.?;
        };
        const buf = try alloc.alloc(u8, range_len);
        defer alloc.free(buf);
        const n = try fh.readPositionalAll(self.io, buf, start);
        if (n != range_len) return error.CorruptSst;
        return try scanEntries(alloc, buf, key);
    }

    fn sstGetLegacy(self: *Store, alloc: std.mem.Allocator, meta: *const SstMeta, key: ChunkKey) !??[]u8 {
        // Legacy ZLS1 (no footer index): whole-file scan. Correct, slower;
        // only runs on pre-ZLS2 databases.
        // Returns null = not in this sst; ?null = tombstone; ??bytes = found owned.
        // The kept-open file (NVMe profile) still skips the per-lookup
        // open/close; the whole-file read itself stays plain pread (large
        // sequential reads gain nothing from the ring).
        const data = if (meta.file) |fh| blk: {
            const size = try fh.length(self.io);
            if (size > 256 * 1024 * 1024) return error.CorruptSst;
            const buf = try alloc.alloc(u8, @intCast(size));
            errdefer alloc.free(buf);
            const n = try fh.readPositionalAll(self.io, buf, 0);
            if (n != buf.len) return error.CorruptSst;
            break :blk buf;
        } else try self.sst_dir.readFileAlloc(self.io, meta.name, alloc, .limited(256 * 1024 * 1024));
        defer alloc.free(data);
        const p = try parseSst(data);
        if (p.count != meta.count) return error.CorruptSst;
        var pos: usize = 8;
        while (pos < p.entries_end) {
            if (pos + key_len + 4 > p.entries_end) return error.CorruptSst;
            const k: ChunkKey = data[pos..][0..key_len].*;
            pos += key_len;
            const vlen = std.mem.readInt(u32, data[pos..][0..4], .big);
            pos += 4;
            if (vlen == tombstone_len) {
                if (std.mem.eql(u8, &k, &key)) return @as(?[]u8, null);
                continue;
            }
            if (pos + vlen > p.entries_end) return error.CorruptSst;
            if (std.mem.eql(u8, &k, &key)) {
                const out = try alloc.dupe(u8, data[pos .. pos + vlen]);
                return @as(?[]u8, out);
            }
            pos += vlen;
        }
        return null;
    }

    pub fn flush(self: *Store) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.flushLocked();
    }

    fn flushLocked(self: *Store) !void {
        if (self.mem.count() == 0) return;
        // collect + sort by key bytes (biased encoding sorts numerically)
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
        var entries = try self.allocator.alloc(SstEntry, n);
        defer self.allocator.free(entries);
        for (keys, 0..) |k, i| {
            entries[i] = .{ .key = k, .value = self.mem.get(k).? };
        }
        const bytes = try buildSstFile(self.allocator, entries);
        defer self.allocator.free(bytes);
        // write file sst/NNNNNN.sst via tmp + sync + rename
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{d:0>6}.sst", .{self.next_sst_id});
        self.next_sst_id += 1;
        var tmp_buf: [300]u8 = undefined;
        const tmp_name = try std.fmt.bufPrint(&tmp_buf, "{s}" ++ sst_tmp_suffix, .{name});
        try self.writeAtomic(self.sst_dir, tmp_name, name, bytes);
        var meta = try self.loadSstMeta(name);
        {
            errdefer {
                meta.deinit(self.allocator, self.io);
                self.sst_dir.deleteFile(self.io, name) catch {};
            }
            try self.ssts.append(self.allocator, meta);
        }
        {
            errdefer {
                var m = self.ssts.pop().?;
                m.deinit(self.allocator, self.io);
                self.sst_dir.deleteFile(self.io, name) catch {};
            }
            // MANIFEST swap BEFORE wal truncate (crash order: SST durable,
            // then live-set durable, then inputs discardable).
            try self.writeManifest();
        }
        // The live set grew: re-register the fixed-file table (no-op
        // without a ring; drops the ring on registration failure).
        self.syncRingFiles() catch |err| {
            std.log.warn("store: fixed-file registration failed ({}), SST reads use pread", .{err});
            if (self.ring) |*r| r.deinit();
            self.ring = null;
        };
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
        self.bytes_since_sync = 0;
    }

    /// Merge all live SSTs into one run (newest wins). Tombstones are dropped:
    /// the merge covers every run, so a surviving tombstone means "absent".
    /// Crash-safe via tmp+rename + MANIFEST swap; old runs deleted after.
    /// Number of live SST files (diagnostics / stats line).
    pub fn sstCount(self: *Store) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.ssts.items.len;
    }

    /// Pinned io_uring read-buffer bytes (diagnostics / stats line).
    pub fn ringBytes(self: *Store) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.ring) |*r| return r.bufLen();
        return 0;
    }

    pub fn compact(self: *Store) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.compactLocked();
    }

    fn compactLocked(self: *Store) !void {
        try self.flushLocked(); // pin everything to SSTs first (no-op if empty)
        if (self.ssts.items.len == 0) return;
        if (self.ssts.items.len == 1 and self.ssts.items[0].bloom.len > 0) return; // already merged + current
        // Newest -> oldest, first occurrence wins (tombstones included).
        var merged = std.HashMap(ChunkKey, ?[]u8, KeyCtx, 80).init(self.allocator);
        defer {
            var it = merged.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.*) |v| self.allocator.free(v);
            }
            merged.deinit();
        }
        var i = self.ssts.items.len;
        while (i > 0) {
            i -= 1;
            // Whole-file sequential read: the kept-open file (NVMe
            // profile) skips the per-file open/close; the bytes still
            // travel by plain pread (large sequential reads gain nothing
            // from the ring).
            const meta = &self.ssts.items[i];
            const data = if (meta.file) |fh| blk: {
                const size = try fh.length(self.io);
                if (size > 256 * 1024 * 1024) return error.CorruptSst;
                const buf = try self.allocator.alloc(u8, @intCast(size));
                errdefer self.allocator.free(buf);
                const n = try fh.readPositionalAll(self.io, buf, 0);
                if (n != buf.len) return error.CorruptSst;
                break :blk buf;
            } else try self.sst_dir.readFileAlloc(self.io, meta.name, self.allocator, .limited(256 * 1024 * 1024));
            defer self.allocator.free(data);
            const p = try parseSst(data);
            var pos: usize = 8;
            var seen: u32 = 0;
            while (pos < p.entries_end) {
                if (pos + key_len + 4 > p.entries_end) return error.CorruptSst;
                const k: ChunkKey = data[pos..][0..key_len].*;
                pos += key_len;
                const vlen = std.mem.readInt(u32, data[pos..][0..4], .big);
                pos += 4;
                var v: ?[]u8 = null;
                if (vlen != tombstone_len) {
                    if (pos + vlen > p.entries_end) return error.CorruptSst;
                    v = try self.allocator.dupe(u8, data[pos .. pos + vlen]);
                    pos += vlen;
                }
                if (merged.get(k) == null) {
                    merged.put(k, v) catch |err| {
                        if (v) |vv| self.allocator.free(vv);
                        return err;
                    };
                } else if (v) |vv| {
                    self.allocator.free(vv);
                }
                seen += 1;
            }
            if (seen != p.count) return error.CorruptSst;
        }
        // Collect live (non-tombstone) keys, sorted.
        var live = std.ArrayList(ChunkKey).empty;
        defer live.deinit(self.allocator);
        var mit = merged.keyIterator();
        while (mit.next()) |k| {
            if (merged.get(k.*).? != null) try live.append(self.allocator, k.*);
        }
        std.mem.sort(ChunkKey, live.items, {}, struct {
            fn less(_: void, a: ChunkKey, b: ChunkKey) bool {
                return std.mem.lessThan(u8, &a, &b);
            }
        }.less);
        var new_list = std.ArrayList(SstMeta).empty;
        defer new_list.deinit(self.allocator);
        errdefer {
            // MANIFEST never listed the new file: orphan on disk (next open
            // cleans it), in-memory ownership freed here.
            for (new_list.items) |*m| m.deinit(self.allocator, self.io);
        }
        if (live.items.len > 0) {
            var entries = try self.allocator.alloc(SstEntry, live.items.len);
            defer self.allocator.free(entries);
            for (live.items, 0..) |k, ei| {
                entries[ei] = .{ .key = k, .value = merged.get(k).?.? };
            }
            const bytes = try buildSstFile(self.allocator, entries);
            defer self.allocator.free(bytes);
            var name_buf: [16]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "{d:0>6}.sst", .{self.next_sst_id});
            self.next_sst_id += 1;
            var tmp_buf: [300]u8 = undefined;
            const tmp_name = try std.fmt.bufPrint(&tmp_buf, "{s}" ++ sst_tmp_suffix, .{name});
            try self.writeAtomic(self.sst_dir, tmp_name, name, bytes);
            const meta = try self.loadSstMeta(name);
            {
                errdefer {
                    var m = meta;
                    m.deinit(self.allocator, self.io);
                    self.sst_dir.deleteFile(self.io, name) catch {};
                }
                try new_list.append(self.allocator, meta);
            }
        }
        try self.writeManifestList(new_list.items);
        // Commit point passed: swap in-memory list, delete old runs.
        for (self.ssts.items) |*m| m.deinit(self.allocator, self.io);
        self.ssts.clearRetainingCapacity();
        for (new_list.items) |*m| try self.ssts.append(self.allocator, m.*);
        new_list.clearRetainingCapacity();
        // The live set changed wholesale: re-register the fixed-file
        // table (no-op without a ring; drops the ring on failure).
        self.syncRingFiles() catch |err| {
            std.log.warn("store: fixed-file registration failed ({}), SST reads use pread", .{err});
            if (self.ring) |*r| r.deinit();
            self.ring = null;
        };
        // Old files are superseded; best-effort delete (a crash here leaves
        // orphans that `check` lists and the next open cleans).
        var di = self.sst_dir.iterate();
        while (di.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".sst")) continue;
            const live_now = for (self.ssts.items) |*m| {
                if (std.mem.eql(u8, m.name, entry.name)) break true;
            } else false;
            if (!live_now) {
                self.sst_dir.deleteFile(self.io, entry.name) catch |err| {
                    std.log.warn("store: superseded {s} not deleted: {}", .{ entry.name, err });
                };
            }
        }
    }

    /// Copy MANIFEST + live SSTs into `snap_dir` (created as needed).
    /// Flushes first, so the snapshot is a consistent point-in-time copy.
    /// Quiesce writers across shards before snapshotting a pool (see
    /// `ShardPool.snapshotAll`). The copy opens as a working store.
    pub fn snapshot(self: *Store, snap_dir: std.Io.Dir) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.flushLocked();
        try self.writeManifest();
        snap_dir.createDir(self.io, "sst", .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        var snap_sst = try snap_dir.openDir(self.io, "sst", .{});
        defer snap_sst.close(self.io);
        for (self.ssts.items) |*m| {
            try self.sst_dir.copyFile(m.name, snap_sst, m.name, self.io, .{});
        }
        try self.dir.copyFile(manifest_name, snap_dir, manifest_name, self.io, .{});
    }
};

// ---------------------------------------------------------------------------
// Offline verification (powers `zig build check`; read-only, never mutates).
// ---------------------------------------------------------------------------

pub const VerifyStats = struct {
    alloc: std.mem.Allocator,
    wal_records: u64 = 0,
    wal_torn_bytes: u64 = 0,
    wal_crc_errors: u64 = 0,
    manifest_present: bool = false,
    manifest_valid: bool = false,
    manifest_ssts: u64 = 0,
    sst_files: u64 = 0,
    sst_keys_total: u64 = 0,
    sst_unsorted: u64 = 0,
    sst_corrupt: u64 = 0,
    bloom_mismatch: u64 = 0,
    orphans: std.ArrayList([]u8) = .empty, // owned names

    pub fn deinit(self: *VerifyStats) void {
        for (self.orphans.items) |n| self.alloc.free(n);
        self.orphans.deinit(self.alloc);
    }

    /// Count of distinct problems (0 == clean).
    pub fn problems(self: *const VerifyStats) u64 {
        var n: u64 = 0;
        n += self.wal_crc_errors;
        n += self.sst_corrupt;
        n += self.sst_unsorted;
        n += self.bloom_mismatch;
        n += self.orphans.items.len;
        if (self.wal_torn_bytes > 0) n += 1;
        if (self.manifest_present and !self.manifest_valid) n += 1;
        return n;
    }
};

/// Verify one store dir without mutating it: WAL record CRCs (+ torn tail
/// size), MANIFEST parse, every SST (magic/count/sort/footer CRC/bloom
/// rebuild), and orphans (unlisted SSTs, `*.tmp`, `MANIFEST.tmp`).
pub fn verifyDir(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !VerifyStats {
    var st = VerifyStats{ .alloc = alloc };
    errdefer st.deinit();

    // WAL (missing file == clean empty, not an error).
    if (dir.readFileAlloc(io, "wal.log", alloc, .limited(256 * 1024 * 1024))) |data| {
        defer alloc.free(data);
        var pos: usize = 0;
        while (pos < data.len) {
            if (pos + key_len + 4 + 4 > data.len) {
                st.wal_torn_bytes = data.len - pos;
                break;
            }
            const vlen = std.mem.readInt(u32, data[pos + key_len ..][0..4], .big);
            const end = pos + key_len + 4 + (if (vlen == tombstone_len) @as(usize, 0) else vlen) + 4;
            if (end > data.len) {
                st.wal_torn_bytes = data.len - pos;
                break;
            }
            const rec = parseWalRecord(data, pos) catch {
                st.wal_crc_errors += 1;
                pos = end;
                continue;
            };
            _ = rec;
            st.wal_records += 1;
            pos = end;
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    // MANIFEST (missing == legacy/empty: reported, not failed).
    var listed = std.ArrayList([]u8).empty;
    defer {
        for (listed.items) |n| alloc.free(n);
        listed.deinit(alloc);
    }
    if (dir.readFileAlloc(io, manifest_name, alloc, .limited(1 << 20))) |mdata| {
        defer alloc.free(mdata);
        st.manifest_present = true;
        if (parseManifestData(alloc, mdata)) |md| {
            defer {
                var m = md;
                m.deinit(alloc);
            }
            st.manifest_valid = true;
            for (md.names) |n| {
                try listed.append(alloc, try alloc.dupe(u8, n));
            }
            st.manifest_ssts = md.names.len;
        } else |_| {
            st.manifest_valid = false;
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    // SST dir.
    var sst_dir = dir.openDir(io, "sst", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return st,
        else => return err,
    };
    defer sst_dir.close(io);
    var files = std.ArrayList([]u8).empty;
    defer {
        for (files.items) |n| alloc.free(n);
        files.deinit(alloc);
    }
    {
        var it = sst_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            try files.append(alloc, try alloc.dupe(u8, entry.name));
        }
    }
    // Orphans: tmp files + MANIFEST.tmp + unlisted SSTs.
    for (files.items) |n| {
        if (std.mem.endsWith(u8, n, sst_tmp_suffix)) {
            try st.orphans.append(alloc, try alloc.dupe(u8, n));
        } else if (std.mem.endsWith(u8, n, ".sst")) {
            if (st.manifest_present and st.manifest_valid) {
                var found = false;
                for (listed.items) |l| {
                    if (std.mem.eql(u8, l, n)) {
                        found = true;
                        break;
                    }
                }
                if (!found) try st.orphans.append(alloc, try alloc.dupe(u8, n));
            }
        }
    }
    if (dir.readFileAlloc(io, manifest_tmp_name, alloc, .limited(1))) |junk| {
        alloc.free(junk);
        try st.orphans.append(alloc, try alloc.dupe(u8, manifest_tmp_name));
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    // Audit every SST file (listed or not — orphans get checked too).
    for (files.items) |n| {
        if (!std.mem.endsWith(u8, n, ".sst")) continue;
        st.sst_files += 1;
        const data = sst_dir.readFileAlloc(io, n, alloc, .limited(256 * 1024 * 1024)) catch {
            st.sst_corrupt += 1;
            continue;
        };
        defer alloc.free(data);
        const p = parseSst(data) catch {
            st.sst_corrupt += 1;
            continue;
        };
        const audit = auditSstEntries(data, p) catch {
            st.sst_corrupt += 1;
            continue;
        };
        st.sst_keys_total += audit.count;
        if (!audit.sorted) st.sst_unsorted += 1;
        if (p.zls2) {
            // Rebuild the Bloom filter from scanned keys; any deviation is
            // a writer bug that risks false negatives (lost reads).
            const rebuilt = alloc.alloc(u8, p.bloom.len) catch {
                st.sst_corrupt += 1;
                continue;
            };
            defer alloc.free(rebuilt);
            @memset(rebuilt, 0);
            const bits: u32 = @as(u32, @intCast(p.bloom.len * 8));
            var pos: usize = 8;
            var scan_ok = true;
            while (pos < p.entries_end) {
                if (pos + key_len + 4 > p.entries_end) {
                    scan_ok = false;
                    break;
                }
                const k: ChunkKey = data[pos..][0..key_len].*;
                pos += key_len;
                const vlen = std.mem.readInt(u32, data[pos..][0..4], .big);
                pos += 4;
                if (vlen != tombstone_len) {
                    if (pos + vlen > p.entries_end) {
                        scan_ok = false;
                        break;
                    }
                    pos += vlen;
                }
                bloomAdd(rebuilt, bits, k);
            }
            if (!scan_ok or !std.mem.eql(u8, rebuilt, p.bloom)) st.bloom_mismatch += 1;
        }
    }
    return st;
}

test "key roundtrip sortability" {
    const a = encodeKey(0, 1, 2);
    const d = decodeKey(a);
    try std.testing.expectEqual(@as(u8, 0), d.dim);
    try std.testing.expectEqual(@as(i32, 1), d.x);
    try std.testing.expectEqual(@as(i32, 2), d.z);
    // Biased encoding sorts numerically: negatives before positives.
    const k1 = encodeKey(0, -5, 0);
    const k2 = encodeKey(0, 10, 0);
    try std.testing.expect(std.mem.lessThan(u8, &k1, &k2));
    const k3 = encodeKey(0, std.math.minInt(i32), 0);
    const k4 = encodeKey(0, std.math.maxInt(i32), 0);
    try std.testing.expect(std.mem.lessThan(u8, &k3, &k4));
    const r3 = decodeKey(k3);
    try std.testing.expectEqual(std.math.minInt(i32), r3.x);
    const r4 = decodeKey(k4);
    try std.testing.expectEqual(std.math.maxInt(i32), r4.x);
    // dim still groups before x/z.
    const kd0 = encodeKey(0, 100, 100);
    const kd1 = encodeKey(1, -100, -100);
    try std.testing.expect(std.mem.lessThan(u8, &kd0, &kd1));
    try std.testing.expect(a.len == 9);
}

test "put/get/delete memory only" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 1 << 30 });
    defer store.deinit();
    const k = encodeKey(0, 3, -7);
    try std.testing.expect(try store.get(std.testing.allocator, k) == null);
    try store.put(k, "chunk-bytes-v1");
    const got = try store.get(std.testing.allocator, k);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("chunk-bytes-v1", got.?);
    std.testing.allocator.free(got.?);
    try store.delete(k);
    try std.testing.expect(try store.get(std.testing.allocator, k) == null);
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
        const g = try store.get(std.testing.allocator, encodeKey(0, 7, -7));
        try std.testing.expect(g != null);
        try std.testing.expectEqualStrings("payload-7", g.?);
        std.testing.allocator.free(g.?);
    }
    // reopen same dir: SST scan must recover without WAL
    {
        var store = try Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 1 << 30 });
        defer store.deinit();
        const g = try store.get(std.testing.allocator, encodeKey(0, 7, -7));
        try std.testing.expect(g != null);
        try std.testing.expectEqualStrings("payload-7", g.?);
        std.testing.allocator.free(g.?);
        try std.testing.expect(try store.get(std.testing.allocator, encodeKey(0, 3, -3)) == null);
        const n = try store.get(std.testing.allocator, encodeKey(1, 1, 1));
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
        const g = try store.get(std.testing.allocator, encodeKey(0, 9, 9));
        try std.testing.expect(g != null);
        try std.testing.expectEqualStrings("unflushed", g.?);
        std.testing.allocator.free(g.?);
    }
}

test "wal torn tail truncated on open" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var store = try Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 1 << 30 });
        defer store.deinit();
        try store.put(encodeKey(0, 1, 1), "a");
        try store.put(encodeKey(0, 2, 2), "bb");
    }
    // Simulate kill -9 mid-append: garbage partial record at the tail.
    {
        var wal = try tmp.dir.createFile(io, "wal.log", .{ .read = true, .truncate = false });
        defer wal.close(io);
        const len = try wal.length(io);
        try wal.writePositionalAll(io, "PARTIAL", len);
    }
    {
        var store = try Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 1 << 30 });
        defer store.deinit();
        // Prefix recovered, torn tail dropped.
        const g1 = try store.get(std.testing.allocator, encodeKey(0, 1, 1));
        try std.testing.expectEqualStrings("a", g1.?);
        std.testing.allocator.free(g1.?);
        const g2 = try store.get(std.testing.allocator, encodeKey(0, 2, 2));
        try std.testing.expectEqualStrings("bb", g2.?);
        std.testing.allocator.free(g2.?);
        // 9+4+1+4=18 and 9+4+2+4=19 bytes of valid records.
        try std.testing.expectEqual(@as(u64, 37), store.wal_len);
        // Writes continue at the truncated end.
        try store.put(encodeKey(0, 3, 3), "ccc");
        const g3 = try store.get(std.testing.allocator, encodeKey(0, 3, 3));
        try std.testing.expectEqualStrings("ccc", g3.?);
        std.testing.allocator.free(g3.?);
    }
    // Reopen again: fully clean now.
    {
        var store = try Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 1 << 30 });
        defer store.deinit();
        const g3 = try store.get(std.testing.allocator, encodeKey(0, 3, 3));
        try std.testing.expectEqualStrings("ccc", g3.?);
        std.testing.allocator.free(g3.?);
    }
}

test "wal bad crc fails open" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var store = try Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 1 << 30 });
        defer store.deinit();
        try store.put(encodeKey(0, 1, 1), "abcdefgh");
    }
    // Flip a byte inside the complete record (value region).
    {
        const data = try tmp.dir.readFileAlloc(io, "wal.log", std.testing.allocator, .limited(1 << 20));
        defer std.testing.allocator.free(data);
        data[9 + 4 + 2] ^= 0xFF;
        try tmp.dir.writeFile(io, .{ .sub_path = "wal.log", .data = data });
    }
    {
        const res = Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 1 << 30 });
        try std.testing.expectError(error.CorruptWal, res);
    }
}

test "compaction merges newest-wins and drops tombstones" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 1 << 30, .compact_threshold_ssts = 0 });
    defer store.deinit();
    try store.put(encodeKey(0, 1, 1), "v1");
    try store.put(encodeKey(0, 2, 2), "keep");
    try store.flush();
    try store.put(encodeKey(0, 1, 1), "v2");
    try store.delete(encodeKey(0, 2, 2));
    try store.put(encodeKey(0, 3, 3), "new");
    try store.flush();
    try std.testing.expectEqual(@as(usize, 2), store.ssts.items.len);
    try store.compact();
    try std.testing.expectEqual(@as(usize, 1), store.ssts.items.len);
    try std.testing.expect(std.mem.endsWith(u8, store.ssts.items[0].name, "000003.sst"));
    const g1 = try store.get(std.testing.allocator, encodeKey(0, 1, 1));
    try std.testing.expectEqualStrings("v2", g1.?);
    std.testing.allocator.free(g1.?);
    try std.testing.expect(try store.get(std.testing.allocator, encodeKey(0, 2, 2)) == null);
    const g3 = try store.get(std.testing.allocator, encodeKey(0, 3, 3));
    try std.testing.expectEqualStrings("new", g3.?);
    std.testing.allocator.free(g3.?);
    // next id monotonic: further flushes continue the sequence.
    try store.put(encodeKey(0, 4, 4), "more");
    try store.flush();
    try std.testing.expectEqual(@as(usize, 2), store.ssts.items.len);
    try std.testing.expect(std.mem.endsWith(u8, store.ssts.items[1].name, "000004.sst"));
}

test "auto-compact bounds sst count" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 64, .compact_threshold_ssts = 4 });
    defer store.deinit();
    var i: i32 = 0;
    while (i < 40) : (i += 1) {
        var vbuf: [32]u8 = undefined;
        const v = try std.fmt.bufPrint(&vbuf, "payload-{d}-padding", .{i});
        try store.put(encodeKey(0, i, i), v);
    }
    // Auto-compaction must have kept the run count bounded.
    try std.testing.expect(store.ssts.items.len < 8);
    var j: i32 = 0;
    while (j < 40) : (j += 1) {
        const g = try store.get(std.testing.allocator, encodeKey(0, j, j));
        try std.testing.expect(g != null);
        var ebuf: [32]u8 = undefined;
        const want = try std.fmt.bufPrint(&ebuf, "payload-{d}-padding", .{j});
        try std.testing.expectEqualStrings(want, g.?);
        std.testing.allocator.free(g.?);
    }
}

test "multi-sst get correct with bloom (compaction off)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 1 << 30, .compact_threshold_ssts = 0 });
    defer store.deinit();
    var i: i32 = 0;
    while (i < 10) : (i += 1) {
        var vbuf: [32]u8 = undefined;
        const v = try std.fmt.bufPrint(&vbuf, "v-{d}", .{i});
        try store.put(encodeKey(0, i, 0), v);
        try store.flush();
    }
    try std.testing.expectEqual(@as(usize, 10), store.ssts.items.len);
    // Every SST carries a Bloom filter + block index now.
    for (store.ssts.items) |*m| {
        try std.testing.expect(m.bloom.len > 0);
        try std.testing.expect(m.index.len > 0);
    }
    // Present keys resolve; absent keys miss everywhere.
    var k: i32 = 0;
    while (k < 10) : (k += 1) {
        const g = try store.get(std.testing.allocator, encodeKey(0, k, 0));
        try std.testing.expect(g != null);
        var ebuf: [32]u8 = undefined;
        const want = try std.fmt.bufPrint(&ebuf, "v-{d}", .{k});
        try std.testing.expectEqualStrings(want, g.?);
        std.testing.allocator.free(g.?);
    }
    var m: i32 = 100;
    while (m < 110) : (m += 1) {
        const miss = try store.get(std.testing.allocator, encodeKey(0, m, 0));
        try std.testing.expect(miss == null);
    }
}

test "uring_io: stride reads go through the ring when available" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const opts: Store.Options = .{ .flush_threshold_bytes = 1 << 30, .compact_threshold_ssts = 0, .use_uring_io = true };
    {
        var store = try Store.open(std.testing.allocator, io, tmp.dir, opts);
        defer store.deinit();
        // One SST per key (flush each) so every get walks the SST path.
        var i: i32 = 0;
        while (i < 10) : (i += 1) {
            var vbuf: [32]u8 = undefined;
            const v = try std.fmt.bufPrint(&vbuf, "v-{d}", .{i});
            try store.put(encodeKey(0, i, 0), v);
            try store.flush();
        }
        try std.testing.expectEqual(@as(usize, 10), store.ssts.items.len);
        var k: i32 = 0;
        while (k < 10) : (k += 1) {
            const g = try store.get(std.testing.allocator, encodeKey(0, k, 0));
            try std.testing.expect(g != null);
            var ebuf: [32]u8 = undefined;
            const want = try std.fmt.bufPrint(&ebuf, "v-{d}", .{k});
            try std.testing.expectEqualStrings(want, g.?);
            std.testing.allocator.free(g.?);
        }
        if (store.ringActive()) {
            // Every present key read its home SST through the ring (Bloom
            // never false-negatives, so at least one ring read per key).
            try std.testing.expect(store.ringStats().ring_reads >= 10);
            // Every live SST has an open file + a fixed-file index.
            for (store.ssts.items) |*m| {
                try std.testing.expect(m.file != null);
                try std.testing.expect(m.fixed_index != null);
            }
        }
    }
    // Reopen: keep-open files + ring come back, data intact.
    {
        var store2 = try Store.open(std.testing.allocator, io, tmp.dir, opts);
        defer store2.deinit();
        var j: i32 = 0;
        while (j < 10) : (j += 1) {
            const g = try store2.get(std.testing.allocator, encodeKey(0, j, 0));
            try std.testing.expect(g != null);
            var ebuf: [32]u8 = undefined;
            const want = try std.fmt.bufPrint(&ebuf, "v-{d}", .{j});
            try std.testing.expectEqualStrings(want, g.?);
            std.testing.allocator.free(g.?);
        }
        if (store2.ringActive()) {
            try std.testing.expect(store2.ringStats().ring_reads >= 10);
        }
    }
}

test "uring_io: oversized strides fall back to pread (same bytes)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 64-byte ring cap with 200-byte values: every stride misses the
    // ring and takes the plain pread road — same bytes, counted.
    var store = try Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 1 << 30, .compact_threshold_ssts = 0, .use_uring_io = true, .uring_max_bytes = 64 });
    defer store.deinit();
    var vbuf: [200]u8 = undefined;
    @memset(&vbuf, 0xAB);
    var i: i32 = 0;
    while (i < 4) : (i += 1) {
        try store.put(encodeKey(0, i, 0), &vbuf);
        try store.flush();
    }
    var k: i32 = 0;
    while (k < 4) : (k += 1) {
        const g = try store.get(std.testing.allocator, encodeKey(0, k, 0));
        try std.testing.expect(g != null);
        try std.testing.expectEqualSlices(u8, &vbuf, g.?);
        std.testing.allocator.free(g.?);
    }
    if (store.ringActive()) {
        try std.testing.expect(store.ringStats().fallback_reads > 0);
        try std.testing.expectEqual(@as(u64, 0), store.ringStats().ring_reads);
    }
}

test "fsync policy option honored" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 1 << 30, .wal_sync_bytes = 1 });
    defer store.deinit();
    try store.put(encodeKey(0, 1, 1), "a");
    // Threshold 1 forces a sync on every append.
    try std.testing.expectEqual(@as(u64, 0), store.bytes_since_sync);
    try store.put(encodeKey(0, 2, 2), "bb");
    try std.testing.expectEqual(@as(u64, 0), store.bytes_since_sync);
    const g = try store.get(std.testing.allocator, encodeKey(0, 2, 2));
    try std.testing.expectEqualStrings("bb", g.?);
    std.testing.allocator.free(g.?);
}

test "snapshot round-trips" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var store = try Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 1 << 30 });
        defer store.deinit();
        try store.put(encodeKey(0, 1, 1), "snap-a");
        try store.put(encodeKey(0, 2, 2), "snap-b");
        var snap = try tmp.dir.createDirPathOpen(io, "snap", .{});
        defer snap.close(io);
        try store.snapshot(snap);
    }
    {
        var snap = try tmp.dir.openDir(io, "snap", .{});
        defer snap.close(io);
        var store = try Store.open(std.testing.allocator, io, snap, .{ .flush_threshold_bytes = 1 << 30 });
        defer store.deinit();
        const g = try store.get(std.testing.allocator, encodeKey(0, 1, 1));
        try std.testing.expectEqualStrings("snap-a", g.?);
        std.testing.allocator.free(g.?);
        const h = try store.get(std.testing.allocator, encodeKey(0, 2, 2));
        try std.testing.expectEqualStrings("snap-b", h.?);
        std.testing.allocator.free(h.?);
    }
}

test "open cleans orphans and tmp files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var store = try Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 1 << 30 });
        defer store.deinit();
        try store.put(encodeKey(0, 1, 1), "live");
        try store.flush();
    }
    // Plant crash leftovers: junk SST (unlisted), tmp files.
    try tmp.dir.writeFile(io, .{ .sub_path = "sst/000099.sst", .data = "junk-not-an-sst" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sst/000100.sst.tmp", .data = "partial" });
    try tmp.dir.writeFile(io, .{ .sub_path = "MANIFEST.tmp", .data = "partial" });
    {
        var store = try Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 1 << 30 });
        defer store.deinit();
        const g = try store.get(std.testing.allocator, encodeKey(0, 1, 1));
        try std.testing.expectEqualStrings("live", g.?);
        std.testing.allocator.free(g.?);
        // Leftovers gone.
        if (tmp.dir.openFile(io, "sst/000099.sst", .{})) |f| {
            var ff = f;
            ff.close(io);
            try std.testing.expect(false);
        } else |_| {}
        if (tmp.dir.openFile(io, "sst/000100.sst.tmp", .{})) |f| {
            var ff = f;
            ff.close(io);
            try std.testing.expect(false);
        } else |_| {}
    }
}

test "verifyDir reports clean then flags planted issues" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var store = try Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 1 << 30 });
        defer store.deinit();
        try store.put(encodeKey(0, 1, 1), "v");
        try store.flush();
        try store.put(encodeKey(0, 2, 2), "w");
    }
    {
        var rep = try verifyDir(std.testing.allocator, io, tmp.dir);
        defer rep.deinit();
        try std.testing.expectEqual(@as(u64, 0), rep.problems());
        try std.testing.expect(rep.manifest_present and rep.manifest_valid);
        try std.testing.expectEqual(@as(u64, 1), rep.sst_files);
    }
    // Plant: torn WAL tail + orphan tmp.
    {
        var wal = try tmp.dir.createFile(io, "wal.log", .{ .read = true, .truncate = false });
        defer wal.close(io);
        const len = try wal.length(io);
        try wal.writePositionalAll(io, "TORN", len);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "sst/000007.sst.tmp", .data = "partial" });
    {
        var rep = try verifyDir(std.testing.allocator, io, tmp.dir);
        defer rep.deinit();
        try std.testing.expect(rep.wal_torn_bytes > 0);
        try std.testing.expectEqual(@as(usize, 1), rep.orphans.items.len);
        try std.testing.expect(rep.problems() > 0);
    }
    // Reopen recovers; verify clean again.
    {
        var store = try Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 1 << 30 });
        defer store.deinit();
    }
    {
        var rep = try verifyDir(std.testing.allocator, io, tmp.dir);
        defer rep.deinit();
        try std.testing.expectEqual(@as(u64, 0), rep.problems());
    }
}

test "next_sst_id monotonic across restarts incl compaction" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var store = try Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 1 << 30, .compact_threshold_ssts = 0 });
        defer store.deinit();
        try store.put(encodeKey(0, 1, 1), "a");
        try store.flush();
        try store.put(encodeKey(0, 2, 2), "b");
        try store.flush();
        try store.compact();
        try std.testing.expectEqual(@as(u32, 4), store.next_sst_id);
    }
    {
        var store = try Store.open(std.testing.allocator, io, tmp.dir, .{ .flush_threshold_bytes = 1 << 30, .compact_threshold_ssts = 0 });
        defer store.deinit();
        try std.testing.expectEqual(@as(u32, 4), store.next_sst_id);
        try store.put(encodeKey(0, 3, 3), "c");
        try store.flush();
        try std.testing.expectEqual(@as(usize, 2), store.ssts.items.len);
    }
}

