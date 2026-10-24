const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -Dllvm-path turns on the LLVM backend. Without it, the backend is a no-op.
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
    const msvc_lib_path = b.option(
        []const u8,
        "msvc-lib-path",
        "Path to the MSVC lib/x64 directory (for `link_libc`: vcruntime.lib, libcmt.lib)",
    ) orelse "";
    const stdlib_root = b.option(
        []const u8,
        "stdlib-root",
        "Path to the Fels modules directory containing std/",
    ) orelse b.pathFromRoot("lib");

    // Bake felsld into fels.exe for a one-file release. The base exe compiles
    // felsld.fels to an object; the final exe links it in. Off = ship the dll instead.
    const embed_linker = b.option(bool, "embed-linker", "Bake felsld into fels.exe (single-binary release)") orelse false;

    // the compiler, as a reusable library
    const compiler_mod = b.addModule("fels_compiler", .{
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
    opts.addOption([]const u8, "msvc_lib_path", msvc_lib_path);
    opts.addOption([]const u8, "stdlib_root", stdlib_root);
    // Single version source: build.zig.zon, with a best-effort `+<git-sha>` so
    // dev/nightly builds are identifiable. Overridable with `-Dversion=...`.
    const base_version = @import("build.zig.zon").version;
    const version = b.option([]const u8, "version", "Override the reported version") orelse
        gitVersion(b, base_version);
    opts.addOption([]const u8, "version", version);
    compiler_mod.addOptions("build_options", opts);

    // Embed the bump-allocator stdlib so a `zone` block (whose handle is a real
    // `std.heap.Arena`) works in every compile path — including the inline
    // `compile(source)` path that never touches disk. `@embedFile` resolves
    // these import names; the files remain the single source of truth in lib/.
    compiler_mod.addAnonymousImport("std_heap_fels", .{ .root_source_file = b.path("lib/std/heap.fels") });
    compiler_mod.addAnonymousImport("std_ptr_fels", .{ .root_source_file = b.path("lib/std/ptr.fels") });
    // The Apache license text `fels new --license Apache-2.0` writes into a project.
    compiler_mod.addAnonymousImport("license_apache", .{ .root_source_file = b.path("LICENSE-APACHE-2.0.txt") });

    // Wire LLVM into the compiler library when a path is provided.
    if (llvm_path) |lp| {
        // Use b.fmt to avoid pathJoin stripping backslashes on Windows absolute paths.
        compiler_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{lp}) });
        compiler_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{lp}) });
        if (target.result.os.tag == .windows) {
            // llvm.org's Windows release: the C API in one DLL, LLVM-C.dll.
            compiler_mod.linkSystemLibrary("LLVM-C", .{});
        } else {
            linkStaticLlvm(b, compiler_mod, lp);
        }
        // libclang isn't linked. The include path gives @cImport its types, but the
        // functions load at runtime (clang_c.zig), so fels.exe doesn't drag in the
        // 81 MB libclang.dll. It's pulled in only for `fels bindgen`.
    }

    // optional in-process LLD (felslld.dll)
    // -Din-process-lld builds a DLL with the LLD COFF driver + its LLVM deps, so
    // `fels build` links in-process instead of spawning lld-link.exe. Off by default.
    const in_process_lld = b.option(bool, "in-process-lld", "Build felslld.dll for in-process linking") orelse false;
    opts.addOption(bool, "in_process_lld", in_process_lld and llvm_path != null);
    if (in_process_lld) {
        if (llvm_path) |lp| {
            // The SDK's LLVM static libs are MSVC-ABI (/MT). Build the shim DLL
            // against the MSVC toolchain so the CRT/STL match.
            const msvc_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .msvc });
            // Always ReleaseFast + stripped: the DLL is loaded on every `fels
            // build`, so its size drives link latency. Debug info would bloat it
            // to ~77 MB and dominate the load.
            const felslld = b.addLibrary(.{
                .name = "felslld",
                .linkage = .dynamic,
                .root_module = b.createModule(.{ .target = msvc_target, .optimize = .ReleaseFast, .strip = true, .link_libc = true }),
            });
            felslld.root_module.addCSourceFile(.{
                .file = b.path("src/backend/llvm/lld_shim.cpp"),
                .flags = &.{ "-std=c++17", "-fno-rtti" },
            });
            felslld.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{lp}) });
            felslld.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{lp}) });
            // LLD + the FULL LLVM static set (all targets — LLD's LTO path
            // references every target initializer), in `llvm-config --libnames
            // all` order, then the Windows system libs LLVM needs.
            const lld_llvm_libs = [_][]const u8{
                "lldCOFF",                  "lldCommon",
                "LLVMWindowsManifest",      "LLVMXRay",
                "LLVMLibDriver",            "LLVMDlltoolDriver",
                "LLVMTelemetry",            "LLVMTextAPIBinaryReader",
                "LLVMCoverage",             "LLVMLineEditor",
                "LLVMNVPTXCodeGen",         "LLVMNVPTXDesc",
                "LLVMNVPTXInfo",            "LLVMRISCVTargetMCA",
                "LLVMRISCVDisassembler",    "LLVMRISCVAsmParser",
                "LLVMRISCVCodeGen",         "LLVMRISCVDesc",
                "LLVMRISCVInfo",            "LLVMWebAssemblyDisassembler",
                "LLVMWebAssemblyAsmParser", "LLVMWebAssemblyCodeGen",
                "LLVMWebAssemblyUtils",     "LLVMWebAssemblyDesc",
                "LLVMWebAssemblyInfo",      "LLVMBPFDisassembler",
                "LLVMBPFAsmParser",         "LLVMBPFCodeGen",
                "LLVMBPFDesc",              "LLVMBPFInfo",
                "LLVMX86TargetMCA",         "LLVMX86Disassembler",
                "LLVMX86AsmParser",         "LLVMX86CodeGen",
                "LLVMX86Desc",              "LLVMX86Info",
                "LLVMARMDisassembler",      "LLVMARMAsmParser",
                "LLVMARMCodeGen",           "LLVMARMDesc",
                "LLVMARMUtils",             "LLVMARMInfo",
                "LLVMAArch64Disassembler",  "LLVMAArch64AsmParser",
                "LLVMAArch64CodeGen",       "LLVMAArch64Desc",
                "LLVMAArch64Utils",         "LLVMAArch64Info",
                "LLVMOrcDebugging",         "LLVMOrcJIT",
                "LLVMWindowsDriver",        "LLVMMCJIT",
                "LLVMJITLink",              "LLVMInterpreter",
                "LLVMExecutionEngine",      "LLVMRuntimeDyld",
                "LLVMOrcTargetProcess",     "LLVMOrcShared",
                "LLVMDWP",                  "LLVMDWARFCFIChecker",
                "LLVMDebugInfoLogicalView", "LLVMOption",
                "LLVMObjCopy",              "LLVMMCA",
                "LLVMMCDisassembler",       "LLVMDTLTO",
                "LLVMLTO",                  "LLVMPlugins",
                "LLVMPasses",               "LLVMHipStdPar",
                "LLVMCFGuard",              "LLVMCoroutines",
                "LLVMipo",                  "LLVMVectorize",
                "LLVMSandboxIR",            "LLVMLinker",
                "LLVMFrontendOpenMP",       "LLVMFrontendOffloading",
                "LLVMObjectYAML",           "LLVMFrontendOpenACC",
                "LLVMFrontendDriver",       "LLVMInstrumentation",
                "LLVMFrontendDirective",    "LLVMFrontendAtomic",
                "LLVMExtensions",           "LLVMDWARFLinkerParallel",
                "LLVMDWARFLinkerClassic",   "LLVMDWARFLinker",
                "LLVMGlobalISel",           "LLVMMIRParser",
                "LLVMAsmPrinter",           "LLVMSelectionDAG",
                "LLVMCodeGen",              "LLVMTarget",
                "LLVMObjCARCOpts",          "LLVMCodeGenTypes",
                "LLVMCGData",               "LLVMCAS",
                "LLVMIRPrinter",            "LLVMInterfaceStub",
                "LLVMFileCheck",            "LLVMFuzzMutate",
                "LLVMScalarOpts",           "LLVMInstCombine",
                "LLVMAggressiveInstCombine", "LLVMTransformUtils",
                "LLVMBitWriter",            "LLVMAnalysis",
                "LLVMProfileData",          "LLVMSymbolize",
                "LLVMDebugInfoBTF",         "LLVMDebugInfoPDB",
                "LLVMDebugInfoMSF",         "LLVMDebugInfoCodeView",
                "LLVMDebugInfoGSYM",        "LLVMDebugInfoDWARF",
                "LLVMObject",               "LLVMTextAPI",
                "LLVMMCParser",             "LLVMIRReader",
                "LLVMAsmParser",            "LLVMMC",
                "LLVMDebugInfoDWARFLowLevel", "LLVMBitReader",
                "LLVMFrontendHLSL",         "LLVMFuzzerCLI",
                "LLVMABI",                  "LLVMCore",
                "LLVMRemarks",              "LLVMBitstreamReader",
                "LLVMBinaryFormat",         "LLVMTargetParser",
                "LLVMTableGen",             "LLVMSupportLSP",
                "LLVMSupport",              "LLVMDemangle",
                // Windows system libs (`llvm-config --system-libs`, without xml2s: the
                // llvm.org package does not ship it and nothing here needs libxml2).
                "psapi",  "shell32", "ole32",
                "uuid",   "advapi32", "ws2_32", "ntdll",
            };
            for (lld_llvm_libs) |name| felslld.root_module.linkSystemLibrary(name, .{});
            b.installArtifact(felslld);
        }
    }

    // CLI executable
    const exe_mod = b.addModule("fels", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Off Windows the compiler is built with LLVM and linked with LLD, as it is on Windows. Zig's
    // own x86 backend writes debug information for the libclang functions `clang_c.zig` only
    // takes the types of (they are loaded at run time), and its ELF linker then wants them
    // defined; LLD also links the large C++ archives of a static LLVM.
    const zig_llvm: ?bool = if (llvm_path != null and target.result.os.tag != .windows) true else null;
    const exe = b.addExecutable(.{ .name = "fels", .root_module = exe_mod, .use_llvm = zig_llvm, .use_lld = zig_llvm });
    exe.root_module.addImport("fels_compiler", compiler_mod);

    if (embed_linker and llvm_path != null) {
        // Stage 1: the base fels.exe compiles the linker to a freestanding object
        // (no entry / _fltused). It only does codegen, so it needs LLVM-C.dll on
        // PATH but no linker.
        const lp = llvm_path.?;
        const gen = b.addRunArtifact(exe);
        gen.addArg("object");
        gen.addFileArg(b.path("linker/felsld.fels"));
        // The std of this checkout, not the one FELS_HOME or FELS_STD names: an installed
        // older std would build a linker that CI's build does not match.
        gen.addArg("--std-path");
        gen.addDirectoryArg(b.path("lib"));
        gen.addArgs(&.{ "--no-entry", "-O2", "-o" });
        const felsld_obj = gen.addOutputFileArg("felsld.obj");
        gen.addPathDir(b.fmt("{s}/bin", .{lp})); // so LLVM-C.dll resolves at run time

        // Stage 2: the shipped fels.exe links that object in and exports fels_link_mem
        // (link.zig finds it via GetProcAddress on its own module). One binary.
        // A SEPARATE module so the object isn't pulled into the base exe above
        // (which would make the generator depend on its own output — a cycle).
        const final_mod = b.addModule("fels_embed", .{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        final_mod.addImport("fels_compiler", compiler_mod);
        final_mod.addObjectFile(felsld_obj);
        // The embedded object carries the fels runtime, which references ws2_32
        // (the net module). kernel32 is already linked; add Winsock.
        final_mod.linkSystemLibrary("ws2_32", .{});
        const final = b.addExecutable(.{ .name = "fels", .root_module = final_mod, .use_llvm = zig_llvm, .use_lld = zig_llvm });
        final.win32_module_definition = b.path("linker/felsld_embed.def");
        b.installArtifact(final);
    } else {
        b.installArtifact(exe);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run fels");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fels_compiler", .module = compiler_mod }},
    });

    const test_filter = b.option([]const u8, "test-filter", "Only run tests whose name contains this substring");
    const filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};
    const compiler_unit_tests = b.addTest(.{ .root_module = compiler_mod, .filters = filters, .use_llvm = zig_llvm, .use_lld = zig_llvm });
    const exe_unit_tests = b.addTest(.{ .root_module = exe_mod, .filters = filters, .use_llvm = zig_llvm, .use_lld = zig_llvm });
    const integration_tests = b.addTest(.{ .root_module = test_mod, .filters = filters, .use_llvm = zig_llvm, .use_lld = zig_llvm });

    // Tests are a separate step — `zig build test` — not part of install.
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(compiler_unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(integration_tests).step);
}

/// LLVM linked into the compiler from llvm.org's Linux release, which has no shared LLVM:
/// its static archives, the ones `llvm-config` names for what the compiler uses (the C API's
/// core, the optimiser, the bitcode writer, the x86 and AArch64 code generators), and what
/// they need of the system. The archives are C++ built with GCC, so they need its C++ library,
/// libstdc++, and not the libc++ Zig carries: it is linked as the system has it, by path, as
/// a distribution ships only the runtime file (`libstdc++.so.6`) without the development
/// link (`libstdc++.so`). zlib and zstd likewise.
fn linkStaticLlvm(b: *std.Build, mod: *std.Build.Module, lp: []const u8) void {
    const llvm_config = b.fmt("{s}/bin/llvm-config", .{lp});
    const names = b.run(&.{ llvm_config, "--link-static", "--libnames", "core", "passes", "bitwriter", "analysis", "target", "x86codegen", "x86asmparser", "x86desc", "x86info", "aarch64codegen", "aarch64asmparser", "aarch64desc", "aarch64info" });
    var it = std.mem.tokenizeAny(u8, names, " \t\r\n");
    while (it.next()) |name| mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/{s}", .{ lp, name }) });
    for ([_][]const u8{ "libstdc++.so.6", "libgcc_s.so.1", "libz.so.1", "libzstd.so.1" }) |lib| {
        mod.addObjectFile(.{ .cwd_relative = systemLib(b, lib) });
    }
    for ([_][]const u8{ "m", "dl", "rt", "pthread" }) |lib| mod.linkSystemLibrary(lib, .{});
}

/// Where the system keeps the shared library `file`: the first of the usual library folders
/// that has it (Debian and Ubuntu keep them in a folder named after the target, Fedora and
/// Arch in /usr/lib64 or /usr/lib).
fn systemLib(b: *std.Build, file: []const u8) []const u8 {
    for ([_][]const u8{ "/usr/lib/x86_64-linux-gnu", "/lib/x86_64-linux-gnu", "/usr/lib64", "/usr/lib" }) |dir| {
        const path = b.fmt("{s}/{s}", .{ dir, file });
        std.Io.Dir.accessAbsolute(b.graph.io, path, .{}) catch continue;
        return path;
    }
    std.debug.panic("linking LLVM: {s} is not in the system's library folders", .{file});
}

/// `base` version with a best-effort `+<git-short-sha>` appended — but only for a
/// pre-release version (one containing `-`, e.g. `0.1.0-dev`); a clean release is
/// returned as-is. Falls back to `base` when git isn't available.
fn gitVersion(b: *std.Build, base: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, base, '-') == null) return base;
    var code: u8 = 0;
    const out = b.runAllowFail(&.{ "git", "rev-parse", "--short", "HEAD" }, &code, .ignore) catch return base;
    const sha = std.mem.trim(u8, out, " \t\r\n");
    return if (sha.len == 0) base else b.fmt("{s}+{s}", .{ base, sha });
}
