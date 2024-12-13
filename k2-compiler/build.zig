const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const compiler_mod = b.addModule("k2_compiler", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "k2_compiler", .module = compiler_mod },
        },
    });

    const exe_mod = b.addModule("k2", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "k2",
        .root_module = exe_mod,
    });

    exe.root_module.addImport("k2_compiler", compiler_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run k2");
    run_step.dependOn(&run_cmd.step);

    const compiler_unit_tests = b.addTest(.{
        .root_module = compiler_mod,
    });

    const integration_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_compiler_unit_tests = b.addRunArtifact(compiler_unit_tests);
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_compiler_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}
