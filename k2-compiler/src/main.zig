//! k2 compiler CLI
//!
//! Usage:
//!   k2 check  <file.k2>                    — parse + type-check only
//!   k2 build  <file.k2> [-o out.exe]       — compile to native exe (Windows)
//!   k2 ir     <file.k2>                    — dump LLVM IR to stdout
//!   k2 object <file.k2> [-o out.o]         — emit object file only
//!
//! Build with LLVM:  zig build -Dllvm-path=Y:/SDK/clang+llvm-22.1.6-x86_64-pc-windows-msvc

const std = @import("std");
const builtin = @import("builtin");
const k2 = @import("k2_compiler");

const version = "0.1.0-dev";

// The Windows console defaults to a legacy OEM code page, which mangles the
// UTF-8 bytes we print (✓, box-drawing). Switch it to UTF-8 (65001) at startup.
const win = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn SetConsoleOutputCP(wCodePageID: u32) callconv(.winapi) i32;
} else struct {};

fn enableUtf8Console() void {
    if (builtin.os.tag == .windows) _ = win.SetConsoleOutputCP(65001);
}

// ── Live status line ───────────────────────────────────────────────────────────
// A "changing command line" — the current phase, with a spinner that advances at
// each phase boundary. Uses a bare carriage return + padding (no ANSI), so it is
// harmless when output is redirected.

const Progress = struct {
    quiet: bool,
    frame: usize = 0,
    // ASCII spinner — braille glyphs aren't in most console fonts.
    const frames = [_][]const u8{ "|", "/", "-", "\\" };

    fn step(self: *Progress, phase: k2.Phase) void {
        if (self.quiet) return;
        const f = frames[self.frame % frames.len];
        self.frame += 1;
        std.debug.print("\r  {s} {s: <26}", .{ f, phase.label() });
    }

    fn clear(self: *Progress) void {
        if (self.quiet) return;
        std.debug.print("\r{s: <40}\r", .{""});
    }
};

fn progressStep(ctx: ?*anyopaque, phase: k2.Phase) void {
    const p: *Progress = @ptrCast(@alignCast(ctx.?));
    p.step(phase);
}

// ── Entry ───────────────────────────────────────────────────────────────────────

const Options = struct {
    out_path: ?[]const u8 = null,
    llvm_bin: []const u8 = "",
    llvm_bin_owned: bool = false,
    lib_paths: std.ArrayList([]const u8) = .empty,
    extra_libs: std.ArrayList([]const u8) = .empty,
    opt_level: u2 = 0,
    quiet: bool = false,
    show_time: bool = false,
    dll: bool = false,
};

pub fn main(init: std.process.Init) u8 {
    enableUtf8Console();
    const allocator = init.gpa;
    const io = init.io;

    var args_iter = std.process.Args.Iterator.initAllocator(init.minimal.args, allocator) catch return 1;
    defer args_iter.deinit();
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(allocator);
    while (args_iter.next()) |arg| args_list.append(allocator, arg) catch return 1;
    const args = args_list.items;

    if (args.len < 2) {
        printUsage();
        return 1;
    }

    const cmd = args[1];

    // Commands that take no source file.
    if (eqAny(cmd, &.{ "help", "--help", "-h" })) {
        printUsage();
        return 0;
    }
    if (eqAny(cmd, &.{ "version", "--version", "-v" })) {
        std.debug.print("k2 {s}\n", .{version});
        return 0;
    }

    // `k2 build` with no source file (or a step/target name, or flags) runs the
    // project's build.k2 in the build system. Only `k2 build <file>.k2` for an
    // existing file is a direct single-file build (handled below).
    if (std.mem.eql(u8, cmd, "build")) {
        const arg2: ?[]const u8 = if (args.len >= 3) args[2] else null;
        const is_direct = arg2 != null and
            std.mem.endsWith(u8, arg2.?, ".k2") and
            fileExists(io, arg2.?);
        if (!is_direct) return cmdBuildDir(allocator, io, args[2..]);
    }

    if (args.len < 3) {
        std.debug.print("k2: '{s}' needs a source file\n\n", .{cmd});
        printUsage();
        return 1;
    }
    const src_path = args[2];

    // Parse options.
    var opts = Options{};
    defer opts.lib_paths.deinit(allocator);
    defer opts.extra_libs.deinit(allocator);
    defer if (opts.llvm_bin_owned) allocator.free(opts.llvm_bin);
    if (k2.llvm_path.len != 0) {
        opts.llvm_bin = std.fmt.allocPrint(allocator, "{s}/bin", .{k2.llvm_path}) catch return 1;
        opts.llvm_bin_owned = true;
        opts.opt_level = if (@import("builtin").mode == .Debug) 0 else 2;
    }
    if (k2.windows_sdk_lib_path.len != 0) {
        opts.lib_paths.append(allocator, k2.windows_sdk_lib_path) catch return 1;
    }

    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-o") and i + 1 < args.len) {
            i += 1;
            opts.out_path = args[i];
        } else if (std.mem.eql(u8, a, "--llvm-path") and i + 1 < args.len) {
            i += 1;
            if (opts.llvm_bin_owned) allocator.free(opts.llvm_bin);
            opts.llvm_bin = std.fmt.allocPrint(allocator, "{s}/bin", .{args[i]}) catch return 1;
            opts.llvm_bin_owned = true;
        } else if (std.mem.eql(u8, a, "--lib-path") and i + 1 < args.len) {
            i += 1;
            opts.lib_paths.append(allocator, args[i]) catch return 1;
        } else if (std.mem.eql(u8, a, "--lib") and i + 1 < args.len) {
            i += 1;
            opts.extra_libs.append(allocator, args[i]) catch return 1;
        } else if (std.mem.eql(u8, a, "--opt") and i + 1 < args.len) {
            i += 1;
            opts.opt_level = std.fmt.parseInt(u2, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, a, "-O0")) {
            opts.opt_level = 0;
        } else if (std.mem.eql(u8, a, "-O1")) {
            opts.opt_level = 1;
        } else if (eqAny(a, &.{ "-O2", "--release" })) {
            opts.opt_level = 2;
        } else if (std.mem.eql(u8, a, "-O3")) {
            opts.opt_level = 3;
        } else if (eqAny(a, &.{ "-q", "--quiet" })) {
            opts.quiet = true;
        } else if (eqAny(a, &.{ "-t", "--time" })) {
            opts.show_time = true;
        } else if (eqAny(a, &.{ "--shared", "--dll" })) {
            opts.dll = true;
        } else {
            std.debug.print("k2: unknown option '{s}'\n", .{a});
            return 1;
        }
    }

    const cwd = std.Io.Dir.cwd();
    const source = cwd.readFileAlloc(io, src_path, allocator, .unlimited) catch |err| {
        std.debug.print("k2: cannot read '{s}': {s}\n", .{ src_path, @errorName(err) });
        return 1;
    };
    defer allocator.free(source);

    if (std.mem.eql(u8, cmd, "check")) return cmdCheck(allocator, io, src_path, source);
    if (std.mem.eql(u8, cmd, "ir")) return cmdIr(allocator, io, src_path, source);
    if (std.mem.eql(u8, cmd, "object")) {
        const out = opts.out_path orelse deriveOut(allocator, src_path, ".o");
        defer if (opts.out_path == null) allocator.free(out);
        return cmdObject(allocator, io, src_path, source, out, &opts);
    }
    if (std.mem.eql(u8, cmd, "build")) {
        const exe = opts.out_path orelse deriveOut(allocator, src_path, if (opts.dll) ".dll" else ".exe");
        defer if (opts.out_path == null) allocator.free(exe);
        const obj = std.fmt.allocPrint(allocator, "{s}.o", .{exe}) catch return 1;
        defer allocator.free(obj);
        return cmdBuild(allocator, io, src_path, source, obj, exe, &opts);
    }

    std.debug.print("k2: unknown command '{s}'\n\n", .{cmd});
    printUsage();
    return 1;
}

// ── Commands ──────────────────────────────────────────────────────────────────

fn cmdCheck(allocator: std.mem.Allocator, io: std.Io, path: []const u8, source: []const u8) u8 {
    var fe = k2.compileFileWithRuntime(allocator, io, path) catch |err| {
        std.debug.print("k2: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer fe.deinit(allocator);
    printDiags(allocator, fe.diagnostics(), path, source);
    if (fe.diagnostics().len != 0) return 1;
    std.debug.print("ok — no errors\n", .{});
    return 0;
}

fn cmdIr(allocator: std.mem.Allocator, io: std.Io, path: []const u8, source: []const u8) u8 {
    if (!k2.llvm_enabled) return noLlvm();
    var fe = k2.compileFileWithRuntime(allocator, io, path) catch return 1;
    defer fe.deinit(allocator);
    printDiags(allocator, fe.diagnostics(), path, source);
    var module = k2.lowerFrontend(allocator, fe) catch return 1;
    k2.ir_mod.runDefaultPasses(allocator, &module) catch return 1;
    var be = k2.LlvmBackend.init(allocator, "k2");
    defer be.deinit();
    be.lower(module) catch return 1;
    const text = be.getIrText(allocator) catch return 1;
    defer allocator.free(text);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    stdout_writer.interface.writeAll(text) catch return 1;
    stdout_writer.interface.flush() catch return 1;
    return 0;
}

fn cmdObject(allocator: std.mem.Allocator, io: std.Io, path: []const u8, source: []const u8, obj_path: []const u8, opts: *Options) u8 {
    if (!k2.llvm_enabled) return noLlvm();
    var progress = Progress{ .quiet = opts.quiet };
    var timings: k2.Timings = .{};
    k2.compileFileWithLlvm(allocator, io, .{
        .file_name = path,
        .source = source,
        .obj_path = obj_path,
        .opt_level = opts.opt_level,
        .lib_paths = opts.lib_paths.items,
        .extra_libs = opts.extra_libs.items,
        .progress = progressStep,
        .progress_ctx = &progress,
        .timings = &timings,
    }) catch |err| {
        progress.clear();
        std.debug.print("k2: {s}\n", .{@errorName(err)});
        return 1;
    };
    progress.clear();
    std.debug.print("  wrote {s}\n", .{obj_path});
    if (opts.show_time) printTimings(timings, obj_path);
    return 0;
}

fn cmdBuild(allocator: std.mem.Allocator, io: std.Io, path: []const u8, source: []const u8, obj_path: []const u8, exe_path: []const u8, opts: *Options) u8 {
    if (!k2.llvm_enabled) return noLlvm();
    var progress = Progress{ .quiet = opts.quiet };
    var timings: k2.Timings = .{};
    k2.compileFileWithLlvm(allocator, io, .{
        .file_name = path,
        .source = source,
        .obj_path = obj_path,
        .exe_path = exe_path,
        .dll = opts.dll,
        .opt_level = opts.opt_level,
        .llvm_bin = opts.llvm_bin,
        .lib_paths = opts.lib_paths.items,
        .extra_libs = opts.extra_libs.items,
        .progress = progressStep,
        .progress_ctx = &progress,
        .timings = &timings,
    }) catch |err| {
        progress.clear();
        std.debug.print("k2: {s}\n", .{@errorName(err)});
        return 1;
    };
    progress.clear();
    std.debug.print("  \u{2713} {s}\n", .{exe_path});
    if (!opts.quiet) printTimings(timings, exe_path);
    return 0;
}

// ── Build system (`k2 build` with a build.k2) ──────────────────────────────────

fn cmdBuildDir(allocator: std.mem.Allocator, io: std.Io, rest: []const []const u8) u8 {
    if (!k2.llvm_enabled) return noLlvm();

    var opts = k2.build_driver.RunOptions{};

    var llvm_bin: []const u8 = "";
    var llvm_bin_owned = false;
    defer if (llvm_bin_owned) allocator.free(llvm_bin);
    if (k2.llvm_path.len != 0) {
        llvm_bin = std.fmt.allocPrint(allocator, "{s}/bin", .{k2.llvm_path}) catch return 1;
        llvm_bin_owned = true;
    }

    var lib_paths: std.ArrayList([]const u8) = .empty;
    defer lib_paths.deinit(allocator);
    if (k2.windows_sdk_lib_path.len != 0) lib_paths.append(allocator, k2.windows_sdk_lib_path) catch return 1;

    var run_args: std.ArrayList([]const u8) = .empty;
    defer run_args.deinit(allocator);

    var after_ddash = false;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (after_ddash) {
            run_args.append(allocator, arg) catch return 1;
        } else if (std.mem.eql(u8, arg, "--")) {
            after_ddash = true;
        } else if (eqAny(arg, &.{ "-O2", "--release" })) {
            opts.release = true;
        } else if (std.mem.eql(u8, arg, "--list")) {
            opts.list = true;
        } else if (eqAny(arg, &.{ "-q", "--quiet" })) {
            opts.quiet = true;
        } else if (std.mem.eql(u8, arg, "--llvm-path") and i + 1 < rest.len) {
            i += 1;
            if (llvm_bin_owned) allocator.free(llvm_bin);
            llvm_bin = std.fmt.allocPrint(allocator, "{s}/bin", .{rest[i]}) catch return 1;
            llvm_bin_owned = true;
        } else if (std.mem.eql(u8, arg, "--lib-path") and i + 1 < rest.len) {
            i += 1;
            lib_paths.append(allocator, rest[i]) catch return 1;
        } else if (arg.len > 0 and arg[0] == '-') {
            std.debug.print("k2 build: unknown option '{s}'\n", .{arg});
            return 1;
        } else if (opts.target == null) {
            opts.target = arg;
        }
    }
    opts.llvm_bin = llvm_bin;
    opts.lib_paths = lib_paths.items;
    opts.run_args = run_args.items;

    const build_path = "build.k2";
    if (!fileExists(io, build_path)) {
        std.debug.print("k2 build: no build.k2 in the current directory\n", .{});
        return 1;
    }

    k2.build_driver.run(allocator, io, build_path, opts) catch |err| {
        std.debug.print("k2 build: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .unlimited) catch return false;
    std.heap.page_allocator.free(data);
    return true;
}

// ── Stats ───────────────────────────────────────────────────────────────────────

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn printTimings(t: k2.Timings, _: []const u8) void {
    std.debug.print("\n", .{});
    printRow("front-end", t.frontend_ns);
    printRow("lowering", t.lower_ns);
    printRow("optimise", t.passes_ns);
    printRow("codegen", t.codegen_ns);
    printRow("emit object", t.emit_ns);
    printRow("link", t.link_ns);
    std.debug.print("  ───────────────────────\n", .{});
    printRow("total", t.total_ns);
    // Comptime time is a slice of front-end + lowering — K2's signature cost.
    if (t.comptime_ns != 0) {
        std.debug.print("  (of which comptime: {d: >7.2} ms)\n", .{ms(t.comptime_ns)});
    }
}

fn printRow(name: []const u8, ns: u64) void {
    std.debug.print("  {s: <14}{d: >8.2} ms\n", .{ name, ms(ns) });
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn eqAny(s: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

fn noLlvm() u8 {
    std.debug.print("k2: LLVM backend not enabled.\n" ++
        "    Rebuild: zig build -Dllvm-path=<path>\n", .{});
    return 1;
}

fn deriveOut(allocator: std.mem.Allocator, src: []const u8, ext: []const u8) []const u8 {
    const stem = std.fs.path.stem(src);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, ext }) catch src;
}

fn printDiags(allocator: std.mem.Allocator, diags: []const k2.Diagnostic, path: []const u8, source: []const u8) void {
    for (diags) |d| {
        const rendered = k2.renderDiagnostic(allocator, path, source, d) catch continue;
        defer allocator.free(rendered);
        std.debug.print("{s}\n", .{rendered});
    }
}

fn printUsage() void {
    std.debug.print(
        \\k2 {s} — a systems language with compile-time metaprogramming
        \\
        \\usage:  k2 <command> <file.k2> [options]
        \\
        \\commands:
        \\  build                  run ./build.k2 (the build system) — see below
        \\  build    <name>        build a named artifact, or `run`/a step
        \\  build    <file.k2>     compile and link a single file directly
        \\  check    <file.k2>     parse and type-check only
        \\  object   <file.k2>     compile to an object file (.o)
        \\  ir       <file.k2>     print LLVM IR to stdout
        \\  version                print the compiler version
        \\  help                   show this message
        \\
        \\build system (k2 build, with a build.k2 in the current directory):
        \\  k2 build               build the default artifact (or all of them)
        \\  k2 build run [-- args] build the default exe, then run it
        \\  k2 build <name>        build a named artifact or run a named step
        \\  k2 build --list        list the project's artifacts and steps
        \\  k2 build --release     build at release optimization
        \\
        \\options:
        \\  -o <path>              output file (default: derived from the source name)
        \\  -O0 / -O1 / -O2 / -O3  optimisation level   (--release = -O2)
        \\  -t, --time             print phase timings (build/object)
        \\  -q, --quiet            no status line or timings
        \\  --llvm-path <dir>      LLVM root (forward slashes)
        \\  --lib-path <dir>       add a linker library search directory
        \\  --lib <name>           link an extra import library (e.g. user32)
        \\
    , .{version});
}
