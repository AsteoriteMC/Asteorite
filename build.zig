const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zigcraft", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "zigcraft",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigcraft", .module = mod },
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
                .{ .name = "zigcraft", .module = mod },
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
                .{ .name = "zigcraft", .module = mod },
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
                .{ .name = "zigcraft", .module = mod },
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
                .{ .name = "zigcraft", .module = mod },
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
                .{ .name = "zigcraft", .module = mod },
            },
        }),
    });
    b.installArtifact(genlayer_tool);

    const run_step = b.step("run", "Run zigcraft server (stub)");
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

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_tool_tests.step);
    test_step.dependOn(&run_import_tests.step);
    test_step.dependOn(&run_wgen_tests.step);
    test_step.dependOn(&run_seed_tests.step);
    test_step.dependOn(&run_genlayer_tests.step);
}
