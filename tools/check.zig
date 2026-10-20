//! check: verify an LSM world dir (Phase E acceptance tool).
//! Usage: zig build check -- <db>
//! Auto-detects shard layout (`<db>/shard-00` ...) vs single store.
//! Read-only: replays WAL (CRC per record), parses MANIFEST, audits every
//! SST (magic/count/order/footer-CRC/Bloom rebuild), lists orphans.
//! Exit 0 + "CHECK CLEAN" iff zero problems; else prints problems and
//! returns error.CheckFailed. Recovery flow after kill -9: start the server
//! once (open truncates the torn WAL tail + cleans tmp files), then `check`
//! must report clean.

const std = @import("std");
const zigcraft = @import("zigcraft");

const store_mod = zigcraft.store;

fn startsWithShard(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "shard-");
}

fn checkOne(io: std.Io, dir: std.Io.Dir, label: []const u8, out: *std.Io.Writer, alloc: std.mem.Allocator) !u64 {
    var rep = store_mod.verifyDir(alloc, io, dir) catch |err| {
        try out.print("{s}: verify I/O error: {}\n", .{ label, err });
        return 1;
    };
    defer rep.deinit();
    try out.print("{s}: wal_records={d} wal_torn={d} wal_crc_err={d} manifest={s}/{s} ssts={d} keys={d} corrupt={d} unsorted={d} bloom_mismatch={d} orphans={d}\n", .{
        label,
        rep.wal_records,
        rep.wal_torn_bytes,
        rep.wal_crc_errors,
        if (rep.manifest_present) "present" else "absent",
        if (!rep.manifest_present) "-" else if (rep.manifest_valid) "valid" else "INVALID",
        rep.sst_files,
        rep.sst_keys_total,
        rep.sst_corrupt,
        rep.sst_unsorted,
        rep.bloom_mismatch,
        rep.orphans.items.len,
    });
    for (rep.orphans.items) |o| {
        try out.print("{s}:   orphan: {s}\n", .{ label, o });
    }
    if (rep.wal_torn_bytes > 0) {
        try out.print("{s}:   note: torn WAL tail = kill -9 artifact; reopen to truncate, then re-check\n", .{label});
    }
    return rep.problems();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena_alloc: std.mem.Allocator = init.arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;

    const args = try init.minimal.args.toSlice(arena_alloc);
    if (args.len < 2) {
        try out.print("usage: check <db>\n", .{});
        try out.flush();
        return;
    }
    const path = args[1];

    var db_dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch {
        try out.print("cannot open db dir {s}\n", .{path});
        try out.flush();
        return error.CheckFailed;
    };
    defer db_dir.close(io);

    // Shard layout iff shard-00 exists.
    var is_shard = false;
    if (db_dir.openDir(io, "shard-00", .{})) |d| {
        var dd = d;
        dd.close(io);
        is_shard = true;
    } else |_| {}

    var total: u64 = 0;
    if (!is_shard) {
        total += try checkOne(io, db_dir, "store", out, arena_alloc);
    } else {
        var names = std.ArrayList([]u8).empty;
        defer {
            for (names.items) |n| arena_alloc.free(n);
            names.deinit(arena_alloc);
        }
        var it = db_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file and startsWithShard(entry.name)) {
                try names.append(arena_alloc, try arena_alloc.dupe(u8, entry.name));
            }
        }
        // openDir on a file fails; filter to dirs by probe.
        var shards = std.ArrayList([]u8).empty;
        defer {
            for (shards.items) |n| arena_alloc.free(n);
            shards.deinit(arena_alloc);
        }
        for (names.items) |n| {
            if (db_dir.openDir(io, n, .{})) |d| {
                var dd = d;
                dd.close(io);
                try shards.append(arena_alloc, n);
            } else |_| {
                arena_alloc.free(n);
            }
        }
        std.mem.sort([]u8, shards.items, {}, struct {
            fn less(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        if (shards.items.len == 0) {
            try out.print("no shard dirs under {s}\n", .{path});
            try out.flush();
            return error.CheckFailed;
        }
        for (shards.items) |n| {
            var sd = try db_dir.openDir(io, n, .{ .iterate = true });
            defer sd.close(io);
            total += try checkOne(io, sd, n, out, arena_alloc);
        }
    }
    if (total == 0) {
        try out.print("CHECK CLEAN\n", .{});
    } else {
        try out.print("CHECK FAILED: {d} problems\n", .{total});
    }
    try out.flush();
    if (total != 0) return error.CheckFailed;
}

test {
    _ = @import("zigcraft");
}
