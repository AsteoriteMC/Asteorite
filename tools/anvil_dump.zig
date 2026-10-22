//! anvil_dump: inspect a 1.7.10 .mca region file.
//! Usage: zig build dump -- region/r.0.0.mca

const std = @import("std");
const asteorite = @import("asteorite");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena_alloc: std.mem.Allocator = init.arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;

    const args = try init.minimal.args.toSlice(arena_alloc);
    if (args.len < 2) {
        try out.print("usage: anvil_dump <region.mca>\n", .{});
        try out.flush();
        return;
    }
    const path = args[1];

    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch {
        try out.print("cannot open {s}\n", .{path});
        try out.flush();
        return;
    };
    defer file.close(io);

    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    if (size > 64 * 1024 * 1024) {
        try out.print("file too large ({d} bytes), refusing\n", .{size});
        try out.flush();
        return;
    }
    const data = try arena_alloc.alloc(u8, size);
    var rbuf: [8192]u8 = undefined;
    var fr: std.Io.File.Reader = .init(file, io, &rbuf);
    var n: usize = 0;
    while (n < size) {
        const got = try fr.interface.readSliceShort(data[n..]);
        if (got == 0) break;
        n += got;
    }
    if (n != size) {
        try out.print("short read {d}/{d}\n", .{ n, size });
        try out.flush();
        return;
    }

    const hdr = asteorite.anvil.parseHeader(data) catch {
        try out.print("bad header (file too small)\n", .{});
        try out.flush();
        return;
    };
    var present: usize = 0;
    for (0..32) |lz| {
        for (0..32) |lx| {
            const raw = hdr.locations[lx + lz * 32];
            const loc = asteorite.anvil.decodeLocation(raw);
            if (!loc.present) continue;
            present += 1;
            // chunk coords from filename unknown here; print local + offset
            try out.print("local ({d},{d}) offset={d} sectors={d}\n", .{
                lx, lz, loc.offset_sectors, loc.size_sectors,
            });
            // try decompress first present chunk only (avoid huge dump)
            if (present == 1) {
                const payload = asteorite.anvil.getChunkPayload(
                    data,
                    @intCast(lx),
                    @intCast(lz),
                ) catch {
                    try out.print("  payload slice failed\n", .{});
                    continue;
                };
                const plain = asteorite.anvil.decompressChunk(arena_alloc, payload) catch {
                    try out.print("  decompress failed (comp={})\n", .{payload.compression});
                    continue;
                };
                try out.print("  decompressed {d} bytes, first 16: ", .{plain.len});
                for (plain[0..@min(plain.len, 16)]) |b| try out.print("{x:0>2} ", .{b});
                try out.print("\n", .{});
                var nr = asteorite.nbt.Reader.init(plain);
                const root_name = nr.readRoot() catch {
                    try out.print("  NBT root parse failed\n", .{});
                    continue;
                };
                try out.print("  NBT root name len={d}\n", .{root_name.len});
            }
        }
    }
    try out.print("chunks present: {d}/1024\n", .{present});
    try out.flush();
}
