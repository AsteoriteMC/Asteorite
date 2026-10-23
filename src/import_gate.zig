//! Import-boundary gate for shared core modules.
//!
//! `src/sim/**`, `src/world/**` and `src/cmd/**` own simulation, storage and
//! command semantics. They must not reach into a protocol codec directly;
//! profile differences enter through `version.proto`/`version.game` or a
//! semantic API. `src/world/import/**` is the explicit migration exception.
//! This checks direct imports: the selected profile root may itself import
//! `proto/*`, which is how sanctioned data aliases such as `version.game` work.
//!
//! This gate started as an allowlist for C0-C5 debt. C5 removed the last
//! direct `proto/*` imports from `sim`, so there is no temporary allowlist
//! left: any future direct import is a regression.

const std = @import("std");

const roots = [_][]const u8{ "sim", "world", "cmd" };

/// Extract the first string literal argument of an `@import(...)`, if any.
/// Comments are ignored so documentation can name a protocol path safely.
fn importPath(line: []const u8) ?[]const u8 {
    const code_end = std.mem.indexOf(u8, line, "//") orelse line.len;
    const code = line[0..code_end];
    const marker = "@import(";
    const at = std.mem.indexOf(u8, code, marker) orelse return null;
    var i = at + marker.len;
    while (i < code.len and (code[i] == ' ' or code[i] == '\t')) : (i += 1) {}
    if (i >= code.len or code[i] != '"') return null;
    i += 1;
    const end = std.mem.indexOfScalar(u8, code[i..], '"') orelse return null;
    return code[i .. i + end];
}

fn openSourceRoot(io: std.Io) !std.Io.Dir {
    const cwd = std.Io.Dir.cwd();
    if (cwd.openDir(io, "src", .{ .iterate = true })) |dir| return dir else |_| {}

    // Running the test from a different working directory: resolve relative
    // to this source file instead.
    const own = @src().file;
    const dirname = std.fs.path.dirname(own) orelse ".";
    if (std.fs.path.isAbsolute(dirname)) {
        return std.Io.Dir.openDirAbsolute(io, dirname, .{ .iterate = true });
    }
    return cwd.openDir(io, dirname, .{ .iterate = true });
}

test "import parser ignores comments and finds protocol paths" {
    const direct = importPath("const ids = @import(\"../proto/v5/ids.zig\");").?;
    try std.testing.expectEqualStrings("../proto/v5/ids.zig", direct);
    try std.testing.expect(importPath("// @import(\"../proto/v5/ids.zig\")") == null);
    try std.testing.expect(importPath("const std = @import(\"std\");") != null);
}

test "shared core does not import protocol code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = std.testing.io;

    var src = try openSourceRoot(io);
    defer src.close(io);

    var ok = true;

    for (roots) |root| {
        var dir = try src.openDir(io, root, .{ .iterate = true });
        defer dir.close(io);

        var walker = try dir.walk(alloc);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;

            const full = try std.fs.path.join(alloc, &.{ "src", root, entry.path });
            // The offline importer is the explicit migration boundary: it may
            // read the source profile's wire encoding (world/import/**).
            if (std.mem.startsWith(u8, full, "src/world/import/") or
                std.mem.startsWith(u8, full, "src/world/import\\"))
            {
                continue;
            }

            const text = try entry.dir.readFileAlloc(io, entry.basename, alloc, .limited(1 << 20));

            var line_no: usize = 1;
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| : (line_no += 1) {
                const target = importPath(line) orelse continue;
                if (std.mem.indexOf(u8, target, "proto/") == null) continue;

                std.debug.print(
                    "import gate: {s}:{d} imports protocol module '{s}'\n",
                    .{ full, line_no, target },
                );
                ok = false;
            }
        }
    }

    try std.testing.expect(ok);
}
