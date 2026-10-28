//! Build-time SPIR-V assembler driver (`zig build shaders`).
//!
//! Assembles every `src/gpu/*.comp.spvasm` to its checked-in `.spv` with
//! `spirv-as --target-env vulkan1.0`, then validates each with `spirv-val`.
//! Compare-and-swap: a `.spv` is rewritten only when bytes differ, so
//! ordinary builds cause zero mtime churn and zero downstream recompiles.
//!
//! Missing SPIRV-Tools is a soft skip (note, exit 0): `zig build test`
//! must stay green on machines without spirv-as, and the checked-in
//! `.spv` files are used as-is. A stale `.spv` with tools installed is
//! impossible — assembly runs before every compile that embeds SPV.
//!
//! Run from the repo root (the build script sets cwd); all paths below
//! are repo-relative.

const std = @import("std");

const Shader = struct { src: []const u8, out: []const u8 };

const shaders = [_]Shader{
    .{ .src = "src/gpu/echo.comp.spvasm", .out = "src/gpu/echo.comp.spv" },
    .{ .src = "src/gpu/threshold.comp.spvasm", .out = "src/gpu/threshold.comp.spv" },
    .{ .src = "src/gpu/threshold_batch.comp.spvasm", .out = "src/gpu/threshold_batch.comp.spv" },
};

fn run(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) std.process.RunResult {
    return std.process.run(gpa, io, .{ .argv = argv }) catch |err| {
        std.debug.print("shaders: failed to spawn '{s}' ({s})\n", .{ argv[0], @errorName(err) });
        std.process.exit(1);
    };
}

fn probe(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) bool {
    const res = std.process.run(gpa, io, .{ .argv = argv }) catch return false;
    return res.term == .exited and res.term.exited == 0;
}

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    if (!probe(io, gpa, &.{ "spirv-as", "--version" }) or
        !probe(io, gpa, &.{ "spirv-val", "--version" }))
    {
        std.debug.print("shaders: spirv-as/spirv-val not found — keeping checked-in .spv files\n", .{});
        return;
    }

    for (shaders) |s| {
        const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{s.out});
        const as = run(io, gpa, &.{ "spirv-as", "--target-env", "vulkan1.0", s.src, "-o", tmp });
        if (as.term != .exited or as.term.exited != 0) {
            std.debug.print("shaders: spirv-as failed on {s}:\n{s}\n", .{ s.src, as.stderr });
            cwd.deleteFile(io, tmp) catch {};
            std.process.exit(1);
        }
        const val = run(io, gpa, &.{ "spirv-val", "--target-env", "vulkan1.0", tmp });
        if (val.term != .exited or val.term.exited != 0) {
            std.debug.print("shaders: spirv-val rejected {s} (from {s}):\n{s}\n", .{ tmp, s.src, val.stderr });
            cwd.deleteFile(io, tmp) catch {};
            std.process.exit(1);
        }
        const fresh = try cwd.readFileAlloc(io, tmp, gpa, .limited(1 << 20));
        const cur: ?[]u8 = cwd.readFileAlloc(io, s.out, gpa, .limited(1 << 20)) catch |err| blk: {
            if (err == error.FileNotFound) break :blk null;
            return err;
        };
        if (cur != null and std.mem.eql(u8, cur.?, fresh)) {
            try cwd.deleteFile(io, tmp);
            std.debug.print("shaders: {s} up-to-date\n", .{s.out});
        } else {
            try std.Io.Dir.rename(cwd, tmp, cwd, s.out, io);
            std.debug.print("shaders: {s} rebuilt ({d} words)\n", .{ s.out, fresh.len / 4 });
        }
    }
}
