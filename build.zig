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

/// Apply the -Dstrip/-Dlto/-Dgc-sections opts to one installed executable.
/// Call-site is one line per artifact next to its `installArtifact`.
fn applyBinaryOpts(cs: *std.Build.Step.Compile, strip: bool, lto: ?std.zig.LtoMode, gc_sections: bool) void {
    if (strip) cs.root_module.strip = true;
    if (lto) |m| cs.lto = m;
    if (gc_sections) cs.link_gc_sections = true;
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

    // Binary size / link-time opts for INSTALLED binaries only (never the
    // test binaries below — LTO on the test suite costs minutes per
    // `zig build test` for zero signal). Defaults are all off so the
    // normal dev/test flow is untouched; the deploy recipe turns them on.
    const strip = b.option(bool, "strip", "Strip debug info from installed binaries (smaller, faster page-in; keep an unstripped copy for crash triage)") orelse false;
    const lto_str = b.option([]const u8, "lto", "LLVM link-time optimization for installed binaries: off|thin|full (slower build, typically 3-8% runtime)") orelse "off";
    const gc_sections = b.option(bool, "gc-sections", "Garbage-collect unused sections in installed binaries (smaller, fewer pages)") orelse false;
    const lto: ?std.zig.LtoMode = if (std.mem.eql(u8, lto_str, "off")) null else if (std.mem.eql(u8, lto_str, "thin")) .thin else if (std.mem.eql(u8, lto_str, "full")) .full else {
        std.debug.print("error: unsupported -Dlto value '{s}' (want off|thin|full)\n", .{lto_str});
        std.process.exit(1);
    };

    const opts = b.addOptions();
    opts.addOption(u16, "mc_protocol", mc.protocol);
    opts.addOption([]const u8, "mc_name", mc.name);
    const build_options = opts.createModule();

    const zigzag_dep = b.dependency("zigzag", .{
        .target = target,
        .optimize = optimize,
    });

    // GPU shader assembler driver (build-time only: host target, never
    // installed). `zig build shaders` runs it explicitly, and every
    // compile that embeds SPV orders after it, so a stale `.spv` with
    // SPIRV-Tools installed is impossible. Missing spirv-as/spirv-val
    // is a soft skip (checked-in `.spv` used as-is) so `zig build test`
    // stays green on machines without the toolchain.
    const spv_build_exe = b.addExecutable(.{
        .name = "spv_build",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/spv_build.zig"),
            .target = b.graph.host,
        }),
    });
    const spv_run = b.addRunArtifact(spv_build_exe);
    spv_run.setCwd(b.path("."));
    const shaders_step = b.step("shaders", "Assemble GPU shaders (.spvasm -> .spv) + spirv-val (soft skip without SPIRV-Tools)");
    shaders_step.dependOn(&spv_run.step);

    const mod = b.addModule("asteorite", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
        .imports = &.{
            .{ .name = "build_options", .module = build_options },
            .{ .name = "zigzag", .module = zigzag_dep.module("zigzag") },
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
    applyBinaryOpts(exe, strip, lto, gc_sections);

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
    applyBinaryOpts(anvil_tool, strip, lto, gc_sections);

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
    applyBinaryOpts(import_tool, strip, lto, gc_sections);

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
    applyBinaryOpts(wgen_tool, strip, lto, gc_sections);

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
    applyBinaryOpts(seed_tool, strip, lto, gc_sections);

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
    applyBinaryOpts(genlayer_tool, strip, lto, gc_sections);

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
    applyBinaryOpts(genbench_tool, strip, lto, gc_sections);

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
    applyBinaryOpts(check_tool, strip, lto, gc_sections);

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
    applyBinaryOpts(player_import_tool, strip, lto, gc_sections);

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
    applyBinaryOpts(player_dump_tool, strip, lto, gc_sections);

    const col_dump_tool = b.addExecutable(.{
        .name = "col_dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/col_dump.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "asteorite", .module = mod },
            },
        }),
    });
    b.installArtifact(col_dump_tool);
    applyBinaryOpts(col_dump_tool, strip, lto, gc_sections);

    const chunk_dump_tool = b.addExecutable(.{
        .name = "chunk_dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/chunk_dump.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "asteorite", .module = mod },
            },
        }),
    });
    b.installArtifact(chunk_dump_tool);
    applyBinaryOpts(chunk_dump_tool, strip, lto, gc_sections);

    const noise_dump_tool = b.addExecutable(.{
        .name = "noise_dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/noise_dump.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "asteorite", .module = mod },
            },
        }),
    });
    b.installArtifact(noise_dump_tool);
    applyBinaryOpts(noise_dump_tool, strip, lto, gc_sections);

    const bulk_dump_tool = b.addExecutable(.{
        .name = "bulk_dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bulk_dump.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "asteorite", .module = mod },
            },
        }),
    });
    b.installArtifact(bulk_dump_tool);
    applyBinaryOpts(bulk_dump_tool, strip, lto, gc_sections);

    const chest_dump_tool = b.addExecutable(.{
        .name = "chest_dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/chest_dump.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "asteorite", .module = mod },
            },
        }),
    });
    b.installArtifact(chest_dump_tool);
    applyBinaryOpts(chest_dump_tool, strip, lto, gc_sections);

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
    applyBinaryOpts(bench_tool, strip, lto, gc_sections);

    const gpu_probe_tool = b.addExecutable(.{
        .name = "gpu_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gpu_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "asteorite", .module = mod },
            },
        }),
    });
    b.installArtifact(gpu_probe_tool);
    applyBinaryOpts(gpu_probe_tool, strip, lto, gc_sections);

    const genq_dump_tool = b.addExecutable(.{
        .name = "genq_dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/genq_dump.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "asteorite", .module = mod },
            },
        }),
    });
    b.installArtifact(genq_dump_tool);
    applyBinaryOpts(genq_dump_tool, strip, lto, gc_sections);

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

    const gpu_probe_step = b.step("gpu-probe", "Run Vulkan GPU probe (echo/threshold/batch bit-compare)");
    const gpu_probe_cmd = b.addRunArtifact(gpu_probe_tool);
    gpu_probe_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| gpu_probe_cmd.addArgs(args);
    gpu_probe_step.dependOn(&gpu_probe_cmd.step);

    const genq_dump_step = b.step("genq-dump", "Dump real q[825] + fillChunk output for GPU --realq (seed cx cz path [iters])");
    const genq_dump_cmd = b.addRunArtifact(genq_dump_tool);
    genq_dump_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| genq_dump_cmd.addArgs(args);
    genq_dump_step.dependOn(&genq_dump_cmd.step);

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

    const gpu_probe_tests = b.addTest(.{ .root_module = gpu_probe_tool.root_module });
    const run_gpu_probe_tests = b.addRunArtifact(gpu_probe_tests);

    const genq_dump_tests = b.addTest(.{ .root_module = genq_dump_tool.root_module });
    const run_genq_dump_tests = b.addRunArtifact(genq_dump_tests);

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

    // Every compile embedding SPV (the whole asteorite module graph)
    // orders after shader assembly. Compare-and-swap means no writes
    // (hence no recompiles) when shaders are up-to-date.
    const shader_consumers = [_]*std.Build.Step.Compile{
        exe,          anvil_tool,       import_tool,      wgen_tool,
        seed_tool,    genlayer_tool,    genbench_tool,    check_tool,
        player_import_tool, player_dump_tool, col_dump_tool, bulk_dump_tool,
        chest_dump_tool, bench_tool, gpu_probe_tool, genq_dump_tool, chunk_dump_tool,
        mod_tests,    exe_tests,        tool_tests,       import_tests,
        wgen_tests,   seed_tests,       genlayer_tests,   check_tests,
        player_import_tests, player_dump_tests,
        gpu_probe_tests, genq_dump_tests, noise_dump_tool,
    };
    for (shader_consumers) |cs| cs.step.dependOn(&spv_run.step);

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
    test_step.dependOn(&run_gpu_probe_tests.step);
    test_step.dependOn(&run_genq_dump_tests.step);
    test_step.dependOn(&run_import_gate_tests.step);
    test_step.dependOn(&run_exploit_tests.step);
}
