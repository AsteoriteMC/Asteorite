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

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const tool_tests = b.addTest(.{ .root_module = anvil_tool.root_module });
    const run_tool_tests = b.addRunArtifact(tool_tests);

    const import_tests = b.addTest(.{ .root_module = import_tool.root_module });
    const run_import_tests = b.addRunArtifact(import_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_tool_tests.step);
    test_step.dependOn(&run_import_tests.step);
}
