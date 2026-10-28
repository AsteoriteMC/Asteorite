//! bulk_dump: encode every stored column in a disk as 0x26 bulks.
//! Usage: bulk_dump <db-dir> <ccx> <ccz> <radius> <outfile>
//!
//! Replays the login-burst encoding path (spiral order, 5 columns per
//! bulk) over live store bytes and writes cap.bin-format frames
//! (u32 count, then state:1 varint:id varint:len body per frame) for the
//! vanilla-parse harness. Holes are skipped exactly like the burst.
//! Point it at a COPY of a live world, never the live dir itself.

const std = @import("std");
const asteorite = @import("asteorite");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena_alloc: std.mem.Allocator = init.arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;

    const args = try init.minimal.args.toSlice(arena_alloc);
    if (args.len < 6) {
        try out.print("usage: bulk_dump <db-dir> <ccx> <ccz> <radius> <outfile>\n", .{});
        try out.flush();
        return;
    }
    const db_path = args[1];
    const ccx = std.fmt.parseInt(i32, args[2], 0) catch {
        try out.print("bad ccx {s}\n", .{args[2]});
        try out.flush();
        return;
    };
    const ccz = std.fmt.parseInt(i32, args[3], 0) catch {
        try out.print("bad ccz {s}\n", .{args[3]});
        try out.flush();
        return;
    };
    const radius = std.fmt.parseInt(i32, args[4], 0) catch {
        try out.print("bad radius {s}\n", .{args[4]});
        try out.flush();
        return;
    };
    const out_path = args[5];
    if (radius < 0 or radius > 16) {
        try out.print("bad radius (0..16)\n", .{});
        try out.flush();
        return;
    }

    const cwd = std.Io.Dir.cwd();
    var db_dir = try cwd.createDirPathOpen(io, db_path, .{});
    defer db_dir.close(io);
    var pool = try asteorite.shard.ShardPool.open(arena_alloc, io, db_dir, 4, .{});
    defer pool.deinit();

    var out_file = try db_dir.createFile(io, out_path, .{ .read = false, .truncate = true });
    defer out_file.close(io);
    var fbuf: [8192]u8 = undefined;
    var fw: std.Io.File.Writer = .init(out_file, io, &fbuf);
    const fo = &fw.interface;
    // We buffer frames in memory (arena) so the count header is trivial.
    var frames: std.ArrayList(u8) = .empty;
    var nframes: u32 = 0;

    const max_cols: usize = 5;
    const max_raw: usize = 5 * 196608;
    const raw = try arena_alloc.alloc(u8, max_raw);
    const comp = try arena_alloc.alloc(u8, max_raw + 1024);
    const work = try arena_alloc.alloc(u8, 1 << 16);
    const frame = try arena_alloc.alloc(u8, max_raw + 1024 + 64);

    var cols: [max_cols]asteorite.chunks.BulkColumn = undefined;
    var ncols: usize = 0;
    var raw_len: usize = 0;
    var holes: usize = 0;
    var sent_cols: usize = 0;

    const flush = struct {
        fn run(
            a: std.mem.Allocator,
            out_frames: *std.ArrayList(u8),
            nframes_p: *u32,
            wcols: []asteorite.chunks.BulkColumn,
            rbuf: []u8,
            rlen: usize,
            cbuf: []u8,
            wbuf: []u8,
            frbuf: []u8,
        ) !void {
            const compressed = try asteorite.chunks.zlibCompress(rbuf[0..rlen], cbuf, wbuf);
            const f = try asteorite.chunks.frameMapChunkBulk(wcols, compressed, true, frbuf);
            // f = varint(len) varint(id) body
            var pr = asteorite.codec.PacketReader.init(f);
            const inner: usize = @intCast(try pr.readVarInt());
            const after_len = pr.index;
            const pid = try pr.readVarInt();
            const body = f[pr.index..][0 .. after_len + inner - pr.index];
            try out_frames.append(a, 1);
            var vb: [5]u8 = undefined;
            var vw = asteorite.codec.PacketWriter.init(&vb);
            try vw.writeVarInt(pid);
            try out_frames.appendSlice(a, vw.written());
            var vl: [5]u8 = undefined;
            var vlw = asteorite.codec.PacketWriter.init(&vl);
            try vlw.writeVarInt(@intCast(body.len));
            try out_frames.appendSlice(a, vlw.written());
            try out_frames.appendSlice(a, body);
            nframes_p.* += 1;
        }
    }.run;

    var ring: i32 = 0;
    var idx: usize = 0;
    while (true) {
        var dx: i32 = 0;
        var dz: i32 = 0;
        var have = false;
        if (ring == 0) {
            ring = 1;
            have = true;
        } else {
            while (ring <= radius) {
                const per: usize = @intCast(8 * ring);
                if (idx < per) {
                    const side: usize = @intCast(2 * ring);
                    const i = idx;
                    idx += 1;
                    const r = ring;
                    if (i < side) {
                        dx = -r + @as(i32, @intCast(i));
                        dz = -r;
                    } else if (i < 2 * side) {
                        dx = r;
                        dz = -r + @as(i32, @intCast(i - side));
                    } else if (i < 3 * side) {
                        dx = r - @as(i32, @intCast(i - 2 * side));
                        dz = r;
                    } else {
                        dx = -r;
                        dz = r - @as(i32, @intCast(i - 3 * side));
                    }
                    have = true;
                    break;
                }
                ring += 1;
                idx = 0;
            }
        }
        if (!have) break;
        const ch = try pool.getChunk(arena_alloc, 0, ccx + dx, ccz + dz) orelse {
            holes += 1;
            continue;
        };
        defer ch.destroy(arena_alloc);
        const layout = asteorite.chunks.encodeColumn(ch, true, raw[raw_len..]);
        cols[ncols] = .{ .x = ccx + dx, .z = ccz + dz, .primary = layout.primary, .add = layout.add };
        ncols += 1;
        raw_len += layout.len;
        sent_cols += 1;
        if (ncols == max_cols) {
            try flush(arena_alloc, &frames, &nframes, cols[0..ncols], raw, raw_len, comp, work, frame);
            ncols = 0;
            raw_len = 0;
        }
    }
    if (ncols > 0) {
        try flush(arena_alloc, &frames, &nframes, cols[0..ncols], raw, raw_len, comp, work, frame);
    }
    try fo.writeInt(u32, nframes, .big);
    try fo.writeAll(frames.items);
    try fo.flush();
    try out.print("bulk_dump: {d} frames, {d} cols, {d} holes -> {s}\n", .{ nframes, sent_cols, holes, out_path });
    try out.flush();
}
