const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Optional LLVM backend ─────────────────────────────────────────────
    // Pass `-Dllvm-path=C:\LLVM` (or wherever LLVM is installed) to enable.
    // When omitted, the LLVM backend compiles but is a no-op at runtime.
    const llvm_path = b.option(
        []const u8,
        "llvm-path",
        "Path to LLVM installation (enables LLVM codegen backend)",
    );
    const windows_sdk_lib_path = b.option(
        []const u8,
        "windows-sdk-lib-path",
        "Path to Windows SDK um/x64 lib directory (for kernel32.lib)",
    ) orelse "C:/Program Files (x86)/Windows Kits/10/Lib/10.0.26100.0/um/x64";

    // ── Compiler library module ───────────────────────────────────────────
    const compiler_mod = b.addModule("k2_compiler", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Build option that drives conditional LLVM compilation.
    const opts = b.addOptions();
    opts.addOption(bool, "enable_llvm", llvm_path != null);
    opts.addOption([]const u8, "llvm_path", llvm_path orelse "");
    opts.addOption([]const u8, "windows_sdk_lib_path", windows_sdk_lib_path);
    compiler_mod.addOptions("build_options", opts);

    // Wire LLVM into the compiler library when a path is provided.
    if (llvm_path) |lp| {
        // Use b.fmt to avoid pathJoin stripping backslashes on Windows absolute paths.
        compiler_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{lp}) });
        compiler_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{lp}) });
        // Link the unified LLVM library.  Name varies by installation:
        //   Windows prebuilt (llvm.org): LLVM-C
        //   Linux/macOS:                 LLVM-17 / LLVM
        compiler_mod.linkSystemLibrary("LLVM-C", .{});
    }

    // ── Basalt stub (kept for historical reasons, can be removed) ─────────
    const basalt_lib_dir = b.option(
        []const u8,
        "basalt-lib-dir",
        "Directory containing libbasalt.a",
    ) orelse "C:\\Users\\chris\\backend\\basalt\\bin";

    // ── CLI executable ────────────────────────────────────────────────────
    const exe_mod = b.addModule("k2", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{ .name = "k2", .root_module = exe_mod });
    exe.root_module.addImport("k2_compiler", compiler_mod);
    exe.root_module.addLibraryPath(.{ .cwd_relative = basalt_lib_dir });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run k2");
    run_step.dependOn(&run_cmd.step);

    // ── Tests ─────────────────────────────────────────────────────────────
    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "k2_compiler", .module = compiler_mod }},
    });

    const compiler_unit_tests = b.addTest(.{ .root_module = compiler_mod });
    const exe_unit_tests = b.addTest(.{ .root_module = exe_mod });
    const integration_tests = b.addTest(.{ .root_module = test_mod });

    // Tests are a separate step — `zig build test` — not part of install.
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(compiler_unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(integration_tests).step);
}
