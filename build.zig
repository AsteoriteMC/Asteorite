const std = @import("std");

const McSpec = struct {
    name: []const u8,
    protocol: u16,
    implemented: bool = true,
};

/// One entry per version in the support ladder. Unknown values fail in the
/// build script; known-but-unimplemented values fail with a specific message.
const mc_profiles = [_]McSpec{
    .{ .name = "1.7.10", .protocol = 5 },
    .{ .name = "1.8.9", .protocol = 47, .implemented = false },
    .{ .name = "1.12.2", .protocol = 340, .implemented = false },
    .{ .name = "1.13.2", .protocol = 404, .implemented = false },
    .{ .name = "1.16.5", .protocol = 754, .implemented = false },
    .{ .name = "1.20.4", .protocol = 765, .implemented = false },
    .{ .name = "1.21.x", .protocol = 767, .implemented = false },
};

fn resolveMc(name: []const u8) ?McSpec {
    for (mc_profiles) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mc_name = b.option([]const u8, "mc", "Minecraft version profile") orelse "1.7.10";
    const mc = resolveMc(mc_name) orelse {
        std.debug.print(
            "error: unsupported -Dmc value '{s}' (implemented profile: 1.7.10)\n",
            .{mc_name},
        );
        std.process.exit(1);
    };
    if (!mc.implemented) {
        std.debug.print("error: profile -Dmc={s} is not implemented yet\n", .{mc.name});
        std.process.exit(1);
    }

    const opts = b.addOptions();
    opts.addOption(u16, "mc_protocol", mc.protocol);
    opts.addOption([]const u8, "mc_name", mc.name);
    const build_options = opts.createModule();

    const mod = b.addModule("asteorite", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "build_options", .module = build_options },
        },
    });

    const exe = b.addExecutable(.{
        .name = "asteorite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "asteorite", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const anvil_tool = b.addExecutable(.{
        .name = "anvil_dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/anvil_dump.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "asteorite", .module = mod },
            },
        }),
    });
    b.installArtifact(anvil_tool);

    const import_tool = b.addExecutable(.{
        .name = "anvil_import",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/anvil_import.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "asteorite", .module = mod },
            },
        }),
    });
    b.installArtifact(import_tool);

    const wgen_tool = b.addExecutable(.{
        .name = "worldgen_dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/worldgen_dump.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "asteorite", .module = mod },
            },
        }),
    });
    b.installArtifact(wgen_tool);

    const seed_tool = b.addExecutable(.{
        .name = "seed_dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/seed_dump.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "asteorite", .module = mod },
            },
        }),
    });
    b.installArtifact(seed_tool);

    const genlayer_tool = b.addExecutable(.{
        .name = "genlayer_dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/genlayer_dump.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "asteorite", .module = mod },
            },
        }),
    });
    b.installArtifact(genlayer_tool);

    const genbench_tool = b.addExecutable(.{
        .name = "gen_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "asteorite", .module = mod },
            },
        }),
    });
    b.installArtifact(genbench_tool);

    const check_tool = b.addExecutable(.{
        .name = "check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "asteorite", .module = mod },
            },
        }),
    });
    b.installArtifact(check_tool);

    const player_import_tool = b.addExecutable(.{
        .name = "player_import",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/player_import.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "asteorite", .module = mod },
            },
        }),
    });
    b.installArtifact(player_import_tool);

    const player_dump_tool = b.addExecutable(.{
        .name = "player_dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/player_dump.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "asteorite", .module = mod },
            },
        }),
    });
    b.installArtifact(player_dump_tool);

    const bench_tool = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "asteorite", .module = mod },
            },
        }),
    });
    b.installArtifact(bench_tool);

    const run_step = b.step("run", "Run asteorite server (stub)");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const dump_step = b.step("dump", "Run anvil_dump tool");
    const dump_cmd = b.addRunArtifact(anvil_tool);
    dump_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| dump_cmd.addArgs(args);
    dump_step.dependOn(&dump_cmd.step);

    const import_step = b.step("import", "Run anvil_import tool (mca -> LSM db)");
    const import_cmd = b.addRunArtifact(import_tool);
    import_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| import_cmd.addArgs(args);
    import_step.dependOn(&import_cmd.step);

    const wgen_step = b.step("wgen", "Run worldgen_dump tool");
    const wgen_cmd = b.addRunArtifact(wgen_tool);
    wgen_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| wgen_cmd.addArgs(args);
    wgen_step.dependOn(&wgen_cmd.step);

    const genlayer_step = b.step("genlayer", "Run genlayer_dump tool");
    const genlayer_cmd = b.addRunArtifact(genlayer_tool);
    genlayer_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| genlayer_cmd.addArgs(args);
    genlayer_step.dependOn(&genlayer_cmd.step);

    const check_step = b.step("check", "Verify an LSM db (WAL CRCs, SSTs, MANIFEST, orphans)");
    const check_cmd = b.addRunArtifact(check_tool);
    check_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| check_cmd.addArgs(args);
    check_step.dependOn(&check_cmd.step);

    const player_import_step = b.step("player-import", "Run player_import tool (vanilla player.dat -> LSM db)");
    const player_import_cmd = b.addRunArtifact(player_import_tool);
    player_import_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| player_import_cmd.addArgs(args);
    player_import_step.dependOn(&player_import_cmd.step);

    const player_dump_step = b.step("player-dump", "Run player_dump tool (inspect one LSM player row)");
    const player_dump_cmd = b.addRunArtifact(player_dump_tool);
    player_dump_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| player_dump_cmd.addArgs(args);
    player_dump_step.dependOn(&player_dump_cmd.step);

    const bench_step = b.step("bench", "Run micro-benchmarks (tick, SIMD, codec)");
    const bench_cmd = b.addRunArtifact(bench_tool);
    bench_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| bench_cmd.addArgs(args);
    bench_step.dependOn(&bench_cmd.step);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const tool_tests = b.addTest(.{ .root_module = anvil_tool.root_module });
    const run_tool_tests = b.addRunArtifact(tool_tests);

    const import_tests = b.addTest(.{ .root_module = import_tool.root_module });
    const run_import_tests = b.addRunArtifact(import_tests);

    const wgen_tests = b.addTest(.{ .root_module = wgen_tool.root_module });
    const run_wgen_tests = b.addRunArtifact(wgen_tests);

    const seed_tests = b.addTest(.{ .root_module = seed_tool.root_module });
    const run_seed_tests = b.addRunArtifact(seed_tests);
    const genlayer_tests = b.addTest(.{ .root_module = genlayer_tool.root_module });
    const run_genlayer_tests = b.addRunArtifact(genlayer_tests);

    const check_tests = b.addTest(.{ .root_module = check_tool.root_module });
    const run_check_tests = b.addRunArtifact(check_tests);

    const player_import_tests = b.addTest(.{ .root_module = player_import_tool.root_module });
    const run_player_import_tests = b.addRunArtifact(player_import_tests);

    const player_dump_tests = b.addTest(.{ .root_module = player_dump_tool.root_module });
    const run_player_dump_tests = b.addRunArtifact(player_dump_tests);

    // C0 import-boundary gate. Kept as a named step so it can run on its own
    // even while a larger WIP module is temporarily uncompilable.
    const import_gate_mod = b.createModule(.{
        .root_source_file = b.path("src/import_gate.zig"),
        .target = target,
    });
    const import_gate_tests = b.addTest(.{ .root_module = import_gate_mod });
    const run_import_gate_tests = b.addRunArtifact(import_gate_tests);
    run_import_gate_tests.setCwd(b.path("."));
    const check_imports_step = b.step("check-imports", "Reject direct protocol imports in shared core modules");
    check_imports_step.dependOn(&run_import_gate_tests.step);

    // C9 exploit/core regression suite. Deliberately standalone: it imports
    // only modules that are not coupled to net/server/redstone, so it can run
    // while those areas are being worked on. `--fuzz` applies to this step too.
    const exploit_mod = b.createModule(.{
        .root_source_file = b.path("src/exploit_tests.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "build_options", .module = build_options },
        },
    });
    const exploit_tests = b.addTest(.{ .root_module = exploit_mod });
    const run_exploit_tests = b.addRunArtifact(exploit_tests);
    run_exploit_tests.setCwd(b.path("."));
    const test_exploit_step = b.step("test-exploit", "Run C9 exploit/core regression suite and fuzz seeds");
    test_exploit_step.dependOn(&run_exploit_tests.step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_tool_tests.step);
    test_step.dependOn(&run_import_tests.step);
    test_step.dependOn(&run_wgen_tests.step);
    test_step.dependOn(&run_seed_tests.step);
    test_step.dependOn(&run_genlayer_tests.step);
    test_step.dependOn(&run_check_tests.step);
    test_step.dependOn(&run_player_import_tests.step);
    test_step.dependOn(&run_player_dump_tests.step);
    test_step.dependOn(&run_import_gate_tests.step);
    test_step.dependOn(&run_exploit_tests.step);
}
