//! fels compiler CLI
//!
//! Usage:
//!   fels check  <file.fels>                    — parse + type-check only
//!   fels build  <file.fels> [-o out.exe]       — compile to native exe (Windows)
//!   fels ir     <file.fels>                    — dump LLVM IR to stdout
//!   fels object <file.fels> [-o out.o]         — emit object file only
//!
//! Build with LLVM:  zig build -Dllvm-path=path/to/llvm

const std = @import("std");
const builtin = @import("builtin");
const fels = @import("fels_compiler");

const version = fels.version; // single source: build.zig.zon (+git-sha for dev)

// The Windows console defaults to a legacy OEM code page, which mangles the
// UTF-8 bytes we print (✓, box-drawing). Switch it to UTF-8 (65001) at startup.
const win = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn SetConsoleOutputCP(wCodePageID: u32) callconv(.winapi) i32;
} else struct {};

fn enableUtf8Console() void {
    if (builtin.os.tag == .windows) _ = win.SetConsoleOutputCP(65001);
}

// The embedded linker (felsld.obj, a `--no-entry` object) prints floats through std.io, and
// Windows code that uses floats references `_fltused`. A `--no-entry` object leaves that marker
// to the binary it goes into, and Zig's MinGW CRT does not define it, so fels.exe does.
var fltused: c_int = 1;
comptime {
    if (builtin.os.tag == .windows) @export(&fltused, .{ .name = "_fltused" });
}

const ui = fels.ui;

/// The io of `std.debug.print`, which the live progress tree (ui.zig) draws through too, so
/// the two take one lock on stderr. The standard library's single-threaded default, given one
/// thread for the tree's redraws in `main`.
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = &debug_io;
var debug_io: std.Io.Threaded = .init_single_threaded;

// Entry

const Options = struct {
    out_path: ?[]const u8 = null,
    llvm_bin: []const u8 = "",
    llvm_bin_owned: bool = false,
    lib_paths: std.ArrayList([]const u8) = .empty,
    extra_libs: std.ArrayList([]const u8) = .empty,
    opt_level: u2 = 0,
    /// The runtime safety checks; `--unchecked` and `--release-fast` turn them off.
    safety: bool = true,
    quiet: bool = false,
    show_time: bool = false,
    /// The line of the finished build; `fels run` prints it only with -t.
    done_line: bool = true,
    /// `-g`: debug info for a debugger.
    debug_info: bool = false,
    dll: bool = false,
    /// `--no-entry`: emit a freestanding library object (no `mainCRTStartup` /
    /// `_fltused`), for embedding into another binary.
    no_entry: bool = false,
    /// Codegen target OS (cross-compilation). Defaults to the host.
    target_os: std.Target.Os.Tag = @import("builtin").os.tag,
    /// The portable "link libc" switch (`--libc`, or `--target *-gnu`): the
    /// Windows CRT on Windows; glibc (dynamic `libc.so.6` + glibc entry) on Linux,
    /// where it also makes the freestanding default into a normal dynamic ELF.
    link_libc: bool = false,
    /// Sysroot holding `libc.so.6` for a `linux-gnu` link (`--sysroot`).
    sysroot: []const u8 = "",
    /// Explicit standard-library root (`--std-path`, the dir containing `std/`).
    std_path: []const u8 = "",
    /// True once `--llvm-path` was given, so auto-resolution doesn't override it.
    llvm_from_flag: bool = false,
};

pub fn main(init: std.process.Init) u8 {
    enableUtf8Console();
    // Colors and the live progress tree, when stderr is a terminal.
    fels.style.detectPosix(init.io, init.environ_map);
    ui.pal = fels.style.forStderr();
    debug_io.allocator = std.heap.page_allocator;
    debug_io.concurrent_limit = .limited(1);
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
        std.debug.print("fels {s}\n", .{version});
        return 0;
    }

    // `fels build` with no source file (or a step/target name, or flags) runs the
    // project's build.fels in the build system. Only `fels build <file>.fels` for an
    // existing file is a direct single-file build (handled below).
    if (std.mem.eql(u8, cmd, "build")) {
        const arg2: ?[]const u8 = if (args.len >= 3) args[2] else null;
        const is_direct = arg2 != null and
            fels.pipeline_mod.isSourceFile(arg2.?) and
            fileExists(io, arg2.?);
        if (!is_direct) {
            // The build system returns from here, ahead of the relocatable path
            // resolution further down, so resolve the stdlib root now. Without it
            // `std.build` is looked up at the path this compiler was *built* at, so
            // `fels build` only works on the machine that produced the binary.
            const ra = init.arena.allocator();
            const exe_dir: ?[]const u8 = std.process.executableDirPathAlloc(io, ra) catch null;
            if (resolveStdRoot(ra, io, init.environ_map, "", exe_dir)) |root|
                fels.pipeline_mod.stdlib_root_override = root;
            return cmdBuildDir(allocator, io, init.environ_map, args[2..]);
        }
    }

    // The package manager: fels.pkg and fels.lock in the current directory.
    if (eqAny(cmd, &.{ "add", "fetch", "update", "remove", "why", "vendor" })) {
        const ra = init.arena.allocator();
        const rest = args[2..];
        if (std.mem.eql(u8, cmd, "add")) return fels.pkg.project.cmdAdd(ra, io, init.environ_map, rest);
        if (std.mem.eql(u8, cmd, "remove")) return fels.pkg.project.cmdRemove(ra, io, init.environ_map, rest);
        if (std.mem.eql(u8, cmd, "why")) return fels.pkg.project.cmdWhy(ra, io, init.environ_map, rest);
        if (std.mem.eql(u8, cmd, "vendor")) return fels.pkg.project.cmdVendor(ra, io, init.environ_map, rest);
        if (std.mem.eql(u8, cmd, "fetch")) return fels.pkg.project.cmdFetch(ra, io, init.environ_map, rest);
        return fels.pkg.project.cmdUpdate(ra, io, init.environ_map, rest);
    }

    // `fels test [paths...]` runs the #test functions of the project's files: as native
    // programs, or on the comptime VM with `--comptime` (and in a fels without LLVM).
    if (std.mem.eql(u8, cmd, "test")) {
        const ra = init.arena.allocator();
        var paths: std.ArrayList([]const u8) = .empty;
        var std_flag: []const u8 = "";
        var filter: ?[]const u8 = null;
        var comptime_only = false;
        var worker = false;
        // As many files at once as there are cores, each in a worker process.
        var jobs: usize = std.Thread.getCpuCount() catch 1;
        var k: usize = 2;
        while (k < args.len) : (k += 1) {
            if (std.mem.eql(u8, args[k], "--std-path") and k + 1 < args.len) {
                k += 1;
                std_flag = args[k];
            } else if (std.mem.eql(u8, args[k], "--filter") and k + 1 < args.len) {
                k += 1;
                filter = args[k];
            } else if (std.mem.eql(u8, args[k], "--comptime")) {
                comptime_only = true;
            } else if (std.mem.eql(u8, args[k], "--worker")) {
                worker = true; // a file for a parent `fels test` (test_cmd.zig)
            } else if (std.mem.startsWith(u8, args[k], "-j") and args[k].len > 2) {
                jobs = std.fmt.parseInt(usize, args[k][2..], 10) catch {
                    std.debug.print("fels test: -j takes a number, as in -j4\n", .{});
                    return 1;
                };
            } else if (args[k].len > 1 and args[k][0] == '-') {
                std.debug.print("fels test: unknown option '{s}'\n", .{args[k]});
                return 1;
            } else paths.append(ra, args[k]) catch return 1;
        }
        const exe_dir: ?[]const u8 = std.process.executableDirPathAlloc(io, ra) catch null;
        if (resolveStdRoot(ra, io, init.environ_map, std_flag, exe_dir)) |root|
            fels.pipeline_mod.stdlib_root_override = root;
        const link = linkPaths(ra, io) catch return 1;
        var worker_args: std.ArrayList([]const u8) = .empty;
        if (std_flag.len != 0) worker_args.appendSlice(ra, &.{ "--std-path", std_flag }) catch return 1;
        if (filter) |text| worker_args.appendSlice(ra, &.{ "--filter", text }) catch return 1;
        return fels.test_cmd.cmd(allocator, io, .{
            .paths = paths.items,
            .environ = init.environ_map,
            .comptime_only = comptime_only,
            .filter = filter,
            .llvm_bin = link.llvm_bin,
            .lib_paths = link.lib_paths,
            .jobs = jobs,
            .self_exe = std.process.executablePathAlloc(io, ra) catch "",
            .worker_args = worker_args.items,
            .worker = worker,
        });
    }

    // `fels new <name>` and `fels init` start a project from a template.
    if (std.mem.eql(u8, cmd, "new") or std.mem.eql(u8, cmd, "init"))
        return fels.new_cmd.cmd(init.arena.allocator(), io, std.mem.eql(u8, cmd, "init"), args[2..]);

    // `fels bindgen <header.h>` generates Fels FFI bindings from a C header.
    if (std.mem.eql(u8, cmd, "bindgen")) return cmdBindgen(allocator, io, init.environ_map, args[2..]);

    // `fels lsp` starts the language server (JSON-RPC over stdio). No source file.
    if (std.mem.eql(u8, cmd, "lsp")) {
        // The server loads `std` and the imports of the open files like the compiler does, so it
        // needs the same relocatable standard-library root (`--std-path` is accepted here too).
        const ra = init.arena.allocator();
        const exe_dir: ?[]const u8 = std.process.executableDirPathAlloc(io, ra) catch null;
        var std_flag: []const u8 = "";
        var k: usize = 2;
        while (k + 1 < args.len) : (k += 1) {
            if (std.mem.eql(u8, args[k], "--std-path")) std_flag = args[k + 1];
        }
        if (resolveStdRoot(ra, io, init.environ_map, std_flag, exe_dir)) |root|
            fels.pipeline_mod.stdlib_root_override = root;
        fels.lsp_mod.timing = init.environ_map.get("FELS_LSP_TIMING") != null;
        return fels.runLsp(allocator, io, init.environ_map);
    }

    if (args.len < 3) {
        std.debug.print("fels: '{s}' needs a source file\n\n", .{cmd});
        printUsage();
        return 1;
    }
    const src_path = args[2];

    // Parse options.
    var opts = Options{};
    defer opts.lib_paths.deinit(allocator);
    defer opts.extra_libs.deinit(allocator);
    defer if (opts.llvm_bin_owned) allocator.free(opts.llvm_bin);
    var discovered_msvc: ?[]const u8 = null;
    defer if (discovered_msvc) |p| allocator.free(p);
    if (fels.llvm_path.len != 0) {
        opts.llvm_bin = std.fmt.allocPrint(allocator, "{s}/bin", .{fels.llvm_path}) catch return 1;
        opts.llvm_bin_owned = true;
        opts.opt_level = if (@import("builtin").mode == .Debug) 0 else 2;
    }
    if (fels.windows_sdk_lib_path.len != 0) {
        opts.lib_paths.append(allocator, fels.windows_sdk_lib_path) catch return 1;
    }
    // CRT search paths (harmless if no CRT lib is linked) — make `--libc` /
    // `link_libc()` resolvable: ucrt.lib (SDK) + vcruntime.lib (MSVC).
    if (fels.ucrt_lib_path.len != 0) opts.lib_paths.append(allocator, fels.ucrt_lib_path) catch return 1;
    if (fels.msvc_lib_path.len != 0) {
        opts.lib_paths.append(allocator, fels.msvc_lib_path) catch return 1;
    } else if (fels.msvc.discoverLibX64(allocator, io)) |p| {
        discovered_msvc = p;
        opts.lib_paths.append(allocator, p) catch return 1;
    }

    // `fels run <file.fels> [options] -- <args>`: the program's arguments.
    var run_args: []const []const u8 = &.{};
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--") and std.mem.eql(u8, cmd, "run")) {
            run_args = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, a, "-o") and i + 1 < args.len) {
            i += 1;
            opts.out_path = args[i];
        } else if (std.mem.eql(u8, a, "--llvm-path") and i + 1 < args.len) {
            i += 1;
            if (opts.llvm_bin_owned) allocator.free(opts.llvm_bin);
            opts.llvm_bin = std.fmt.allocPrint(allocator, "{s}/bin", .{args[i]}) catch return 1;
            opts.llvm_bin_owned = true;
            opts.llvm_from_flag = true;
        } else if (std.mem.eql(u8, a, "--std-path") and i + 1 < args.len) {
            i += 1;
            opts.std_path = args[i];
        } else if (std.mem.eql(u8, a, "--lib-path") and i + 1 < args.len) {
            i += 1;
            opts.lib_paths.append(allocator, args[i]) catch return 1;
        } else if (std.mem.eql(u8, a, "--lib") and i + 1 < args.len) {
            i += 1;
            opts.extra_libs.append(allocator, args[i]) catch return 1;
        } else if (std.mem.eql(u8, a, "--target") and i + 1 < args.len) {
            i += 1;
            const t = args[i];
            opts.target_os = if (std.mem.indexOf(u8, t, "linux") != null)
                .linux
            else if (std.mem.indexOf(u8, t, "windows") != null)
                .windows
            else {
                std.debug.print("fels: unknown --target `{s}` (expected linux, linux-gnu, or windows)\n", .{t});
                return 1;
            };
            // `-gnu` selects the dynamically-linked glibc ABI; otherwise Linux is
            // a static, freestanding, no-libc ELF.
            opts.link_libc = std.mem.indexOf(u8, t, "gnu") != null;
        } else if (std.mem.eql(u8, a, "--sysroot") and i + 1 < args.len) {
            i += 1;
            opts.sysroot = args[i];
        } else if (std.mem.eql(u8, a, "--opt") and i + 1 < args.len) {
            i += 1;
            opts.opt_level = std.fmt.parseInt(u2, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, a, "-O0")) {
            opts.opt_level = 0;
        } else if (std.mem.eql(u8, a, "-O1")) {
            opts.opt_level = 1;
        } else if (eqAny(a, &.{ "-O2", "--release" })) {
            opts.opt_level = 2;
        } else if (std.mem.eql(u8, a, "--release-fast")) {
            opts.opt_level = 2;
            opts.safety = false;
        } else if (std.mem.eql(u8, a, "--unchecked")) {
            opts.safety = false;
        } else if (std.mem.eql(u8, a, "-O3")) {
            opts.opt_level = 3;
        } else if (eqAny(a, &.{ "-q", "--quiet" })) {
            opts.quiet = true;
        } else if (eqAny(a, &.{ "-g", "--debug-info" })) {
            opts.debug_info = true;
        } else if (eqAny(a, &.{ "-t", "--time" })) {
            opts.show_time = true;
        } else if (eqAny(a, &.{ "--shared", "--dll" })) {
            opts.dll = true;
        } else if (std.mem.eql(u8, a, "--no-entry")) {
            opts.no_entry = true;
        } else if (eqAny(a, &.{ "--libc", "-lc" })) {
            opts.link_libc = true;
        } else {
            std.debug.print("fels: unknown option '{s}'\n", .{a});
            return 1;
        }
    }
    // `--libc` (and `--target *-gnu`) is the portable "I need libc" switch,
    // resolved per target: the Windows CRT (ucrt + vcruntime) on Windows; glibc
    // (a dynamic `libc.so.6` + the glibc entry point) on Linux, which the
    // `link_libc` path in the driver/backend handles.
    if (opts.link_libc and opts.target_os == .windows) {
        opts.extra_libs.append(allocator, "ucrt") catch return 1;
        opts.extra_libs.append(allocator, "vcruntime") catch return 1;
    }

    // Relocatable runtime: find the stdlib + the LLVM/linker dir wherever fels is
    // installed, so the binary isn't tied to its build machine. Resolved paths
    // live on the process arena (cleaned at exit).
    {
        const ra = init.arena.allocator();
        const exe_dir: ?[]const u8 = std.process.executableDirPathAlloc(io, ra) catch null;
        // std root (dir containing `std/`): --std-path > $FELS_STD > $FELS_HOME/lib >
        // exe-relative (lib, ../lib, ../../lib) > build-baked.
        if (resolveStdRoot(ra, io, init.environ_map, opts.std_path, exe_dir)) |root|
            fels.pipeline_mod.stdlib_root_override = root;
        // LLVM/linker dir (lld + the LLVM-C/clang DLLs): --llvm-path (set above) >
        // $FELS_LLVM > lld next to fels.exe > build-baked (set above).
        if (!opts.llvm_from_flag) {
            if (resolveLlvmBin(ra, io, init.environ_map, exe_dir)) |bin| {
                if (opts.llvm_bin_owned) allocator.free(opts.llvm_bin);
                opts.llvm_bin = bin;
                opts.llvm_bin_owned = false; // arena-owned
            }
        }
    }

    const cwd = std.Io.Dir.cwd();
    const source = cwd.readFileAlloc(io, src_path, allocator, .unlimited) catch |err| {
        std.debug.print("fels: cannot read '{s}': {s}\n", .{ src_path, @errorName(err) });
        return 1;
    };
    defer allocator.free(source);

    if (std.mem.eql(u8, cmd, "check")) return cmdCheck(allocator, io, src_path, source);
    if (std.mem.eql(u8, cmd, "ir")) return cmdIr(allocator, io, src_path, source, &opts);
    if (std.mem.eql(u8, cmd, "object")) {
        const out = opts.out_path orelse deriveOut(allocator, src_path, ".o");
        defer if (opts.out_path == null) allocator.free(out);
        return cmdObject(allocator, io, src_path, source, out, &opts);
    }
    if (std.mem.eql(u8, cmd, "build")) {
        // A Windows program is `hello.exe`, a Linux one `hello`, whatever the host.
        const ext = switch (opts.target_os) {
            .windows => if (opts.dll) ".dll" else ".exe",
            else => if (opts.dll) ".so" else "",
        };
        const exe = opts.out_path orelse deriveOut(allocator, src_path, ext);
        defer if (opts.out_path == null) allocator.free(exe);
        const obj = std.fmt.allocPrint(allocator, "{s}.o", .{exe}) catch return 1;
        defer allocator.free(obj);
        return cmdBuild(allocator, io, src_path, source, obj, exe, &opts);
    }
    if (std.mem.eql(u8, cmd, "run")) return cmdRun(allocator, io, init.arena.allocator(), src_path, source, &opts, run_args);

    std.debug.print("fels: unknown command '{s}'\n\n", .{cmd});
    printUsage();
    return 1;
}

// Commands

/// `fels bindgen <header.h> [--lib <name>] [-o <out.fels>] [-I... -D...] [-- <clang args>]`
fn cmdBindgen(allocator: std.mem.Allocator, io: std.Io, env: anytype, args: []const []const u8) u8 {
    if (!fels.llvm_enabled) {
        std.debug.print("fels bindgen: requires an LLVM-enabled build (libclang).\n    Rebuild: zig build -Dllvm-path=<path>\n", .{});
        return 1;
    }
    if (args.len == 0) {
        std.debug.print("fels bindgen: needs a header file\n    usage: fels bindgen <header.h> [--lib <name>] [-o <out.fels>] [-- <clang args>]\n", .{});
        return 1;
    }
    const header = args[0];

    var lib: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var clang_args: std.ArrayList([]const u8) = .empty;
    defer clang_args.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            // Everything after `--` is forwarded verbatim to clang.
            i += 1;
            while (i < args.len) : (i += 1) clang_args.append(allocator, args[i]) catch return 1;
            break;
        } else if (std.mem.eql(u8, a, "--lib") and i + 1 < args.len) {
            i += 1;
            lib = args[i];
        } else if (std.mem.eql(u8, a, "-o") and i + 1 < args.len) {
            i += 1;
            out = args[i];
        } else if (std.mem.startsWith(u8, a, "-I") or std.mem.startsWith(u8, a, "-D")) {
            clang_args.append(allocator, a) catch return 1;
        } else {
            std.debug.print("fels bindgen: unknown option '{s}'\n", .{a});
            return 1;
        }
    }

    const out_path = out orelse deriveOut(allocator, header, ".fels");
    defer if (out == null) allocator.free(out_path);

    // libclang is loaded on demand (the core compiler carries no dependency on
    // it). Resolve it from the usual spots; a clear hint if it's missing.
    const exe_dir = std.process.executableDirPathAlloc(io, allocator) catch null;
    defer if (exe_dir) |d| allocator.free(d);
    loadLibclang(allocator, io, env, exe_dir) catch return 1;

    fels.bindgen.generate(allocator, io, header, lib, out_path, clang_args.items, exe_dir) catch |err| {
        std.debug.print("fels bindgen: failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

/// Find libclang and load it (bindgen only). Order: `$FELS_LIBCLANG` (file or dir)
/// > beside fels.exe > `<exe>/bindgen` > `$FELS_LLVM` > the build-time LLVM dir >
/// the bare name (OS loader search). Prints how to get it on total failure. An LLVM install
/// keeps it in `bin/` on Windows and in `lib/` elsewhere.
/// The folder of an LLVM install with its shared libraries, libclang among them.
const llvm_lib_dir = if (@import("builtin").os.tag == .windows) "bin" else "lib";

fn loadLibclang(allocator: std.mem.Allocator, io: std.Io, env: anytype, exe_dir: ?[]const u8) !void {
    const name = switch (@import("builtin").os.tag) {
        .windows => "libclang.dll",
        .macos => "libclang.dylib",
        else => "libclang.so",
    };
    // 1. $FELS_LIBCLANG — a direct path to the library, or a dir containing it.
    if (env.get("FELS_LIBCLANG")) |v| {
        if (fileExists(io, v) and tryLoadClang(v)) return;
        if (tryLoadClangIn(allocator, io, v, name)) return;
    }
    // 2/3. Beside fels.exe, then `<exe>/bindgen` (the component layout).
    if (exe_dir) |ed| {
        if (tryLoadClangIn(allocator, io, ed, name)) return;
        if (std.fmt.allocPrint(allocator, "{s}/bindgen", .{ed})) |sub| {
            defer allocator.free(sub);
            if (tryLoadClangIn(allocator, io, sub, name)) return;
        } else |_| {}
    }
    // 4/5. `$FELS_LLVM/bin`, then the build-time LLVM dir (dev/CI fallback).
    if (env.get("FELS_LLVM")) |r| {
        if (std.fmt.allocPrint(allocator, "{s}/{s}", .{ r, llvm_lib_dir })) |b| {
            defer allocator.free(b);
            if (tryLoadClangIn(allocator, io, b, name)) return;
        } else |_| {}
    }
    if (fels.llvm_path.len != 0) {
        if (std.fmt.allocPrint(allocator, "{s}/{s}", .{ fels.llvm_path, llvm_lib_dir })) |b| {
            defer allocator.free(b);
            if (tryLoadClangIn(allocator, io, b, name)) return;
        } else |_| {}
    }
    // 6. Bare name — the OS loader searches the exe dir, system dirs, PATH.
    if (tryLoadClang(name)) return;

    std.debug.print(
        \\fels bindgen: could not find {s}.
        \\    bindgen is an optional feature — libclang is not bundled with the core compiler.
        \\    Provide it any of these ways:
        \\      - put {s} next to fels.exe (or in a 'bindgen' folder beside it)
        \\      - set FELS_LIBCLANG to its full path
        \\      - set FELS_LLVM to an LLVM install (uses its bin/<libclang>)
        \\
    , .{ name, name });
    return error.LibclangNotFound;
}

fn tryLoadClang(path: []const u8) bool {
    fels.bindgen.loadClang(path) catch return false;
    return true;
}

fn tryLoadClangIn(allocator: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) bool {
    const p = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name }) catch return false;
    defer allocator.free(p);
    if (!fileExists(io, p)) return false;
    return tryLoadClang(p);
}

fn cmdCheck(allocator: std.mem.Allocator, io: std.Io, path: []const u8, source: []const u8) u8 {
    var fe = fels.compileFileWithRuntime(allocator, io, path) catch |err| {
        std.debug.print("{s} {s}: {s}\n", .{ ui.mark(.fail), path, ui.failure(err) });
        return 1;
    };
    defer fe.deinit(allocator);
    printDiags(allocator, fe.diagnostics(), path, source);
    if (fels.diagnostic_mod.Diagnostic.anyError(fe.diagnostics())) {
        std.debug.print("{s} {s}: does not compile\n", .{ ui.mark(.fail), path });
        return 1;
    }
    std.debug.print("{s} {s}: no errors\n", .{ ui.mark(.ok), path });
    return 0;
}

/// The LLVM IR of a file, for the target and optimisation level a build of it would have.
fn cmdIr(allocator: std.mem.Allocator, io: std.Io, path: []const u8, source: []const u8, opts: *Options) u8 {
    if (!fels.llvm_enabled) return noLlvm();
    const saved_target = fels.pipeline_mod.build_target.current;
    fels.pipeline_mod.build_target.current = .{ .os = opts.target_os, .debug = opts.opt_level == 0 };
    defer fels.pipeline_mod.build_target.current = saved_target;
    var fe = fels.pipeline_mod.compileFileWithRuntimeTarget(allocator, io, path, opts.target_os, opts.link_libc) catch return 1;
    defer fe.deinit(allocator);
    printDiags(allocator, fe.diagnostics(), path, source);
    var module = fels.lowerFrontend(allocator, fe) catch return 1;
    fels.driver_mod.checkCalls(path, module) catch return 1;
    fels.ir_mod.runDefaultPasses(allocator, &module) catch return 1;
    // `FELS_SLAB_ROUNDTRIP`: the IR as it comes back from a Slab (see `driver.zig`)
    var rt_arena = std.heap.ArenaAllocator.init(allocator);
    defer rt_arena.deinit();
    if (std.c.getenv("FELS_SLAB_ROUNDTRIP") != null) {
        const s = fels.slab_mod.build(rt_arena.allocator(), module) catch return 1;
        module = fels.slab_mod.toIr(rt_arena.allocator(), &s) catch return 1;
    }
    var be = fels.LlvmBackend.init(allocator, "sk");
    defer be.deinit();
    be.setTarget(opts.target_os);
    be.setSafety(opts.safety);
    be.lower(module) catch return 1;
    const text = be.getIrText(allocator) catch return 1;
    defer allocator.free(text);
    writeStdout(io, text) catch return 1;
    return 0;
}

/// Write `bytes` to stdout. When the reader has gone (`fels ir x.fels | head`), stop without
/// a word: on Windows Zig's file writer takes the closing pipe for a programming error and
/// panics, so the bytes go through `WriteFile` there.
fn writeStdout(io: std.Io, bytes: []const u8) !void {
    if (builtin.os.tag == .windows) {
        const handle = std.Io.File.stdout().handle;
        var done: usize = 0;
        while (done < bytes.len) {
            var written: u32 = 0;
            const chunk: u32 = @intCast(@min(bytes.len - done, 1 << 20));
            if (win_out.WriteFile(handle, bytes.ptr + done, chunk, &written, null) == 0 or written == 0) return;
            done += written;
        }
        return;
    }
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    writer.interface.writeAll(bytes) catch return;
    writer.interface.flush() catch return;
}

const win_out = struct {
    extern "kernel32" fn WriteFile(h: std.os.windows.HANDLE, buf: [*]const u8, to_write: u32, written: *u32, ov: ?*anyopaque) callconv(.winapi) i32;
};

fn cmdObject(allocator: std.mem.Allocator, io: std.Io, path: []const u8, source: []const u8, obj_path: []const u8, opts: *Options) u8 {
    if (!fels.llvm_enabled) return noLlvm();
    if (!opts.quiet) ui.start("fels object", 0);
    var stages = ui.Stages.begin(ui.root, std.fs.path.basename(path));
    var timings: fels.Timings = .{};
    fels.compileFileWithLlvm(allocator, io, .{
        .file_name = path,
        .source = source,
        .obj_path = obj_path,
        .opt_level = opts.opt_level,
        .safety = opts.safety,
        .debug_info = opts.debug_info,
        .target_os = opts.target_os,
        .no_entry = opts.no_entry,
        .link_libc = opts.link_libc,
        .sysroot = opts.sysroot,
        .lib_paths = opts.lib_paths.items,
        .extra_libs = opts.extra_libs.items,
        .progress = ui.Stages.step,
        .progress_ctx = &stages,
        .timings = &timings,
    }) catch |err| return buildFailed(&stages, path, err);
    return buildDone(io, &stages, obj_path, timings, opts);
}

/// The line of a failed single-file compile: `✗ path: does not compile` (the reason is above).
fn buildFailed(stages: *ui.Stages, path: []const u8, err: anyerror) u8 {
    _ = stages.end();
    ui.finish();
    std.debug.print("{s} {s}: {s}\n", .{ ui.mark(.fail), path, ui.failure(err) });
    return 1;
}

/// The line of a finished single-file compile: `✓ out  1.2 MB  0.84s  (check 120ms · ... )`.
fn buildDone(io: std.Io, stages: *ui.Stages, out: []const u8, timings: fels.Timings, opts: *Options) u8 {
    const ns = stages.end();
    ui.finish();
    if (opts.quiet or !(opts.done_line or opts.show_time)) return 0;
    var d: [48]u8 = undefined;
    var b: [160]u8 = undefined;
    const breakdown = ui.stageBreakdown(&b, timings);
    var z: [24]u8 = undefined;
    const bytes = if (std.Io.Dir.cwd().statFile(io, out, .{})) |st| ui.size(&z, st.size) else |_| "";
    std.debug.print("{s} {s}  {s}{s}{s}  {s}", .{ ui.mark(.ok), out, ui.pal.dim(), bytes, ui.pal.reset(), ui.dimDuration(&d, if (timings.total_ns != 0) timings.total_ns else ns) });
    if (breakdown.len != 0) std.debug.print("  {s}({s}){s}", .{ ui.pal.dim(), breakdown, ui.pal.reset() });
    std.debug.print("\n", .{});
    if (opts.show_time) printTimings(timings, out);
    return 0;
}

fn cmdBuild(allocator: std.mem.Allocator, io: std.Io, path: []const u8, source: []const u8, obj_path: []const u8, exe_path: []const u8, opts: *Options) u8 {
    if (!fels.llvm_enabled) return noLlvm();
    if (!opts.quiet) ui.start("fels build", 0);
    var stages = ui.Stages.begin(ui.root, std.fs.path.basename(path));
    var timings: fels.Timings = .{};
    fels.compileFileWithLlvm(allocator, io, .{
        .file_name = path,
        .source = source,
        .obj_path = obj_path,
        .exe_path = exe_path,
        .dll = opts.dll,
        .opt_level = opts.opt_level,
        .safety = opts.safety,
        .debug_info = opts.debug_info,
        .target_os = opts.target_os,
        .link_libc = opts.link_libc,
        .sysroot = opts.sysroot,
        .llvm_bin = opts.llvm_bin,
        .lib_paths = opts.lib_paths.items,
        .extra_libs = opts.extra_libs.items,
        .progress = ui.Stages.step,
        .progress_ctx = &stages,
        .timings = &timings,
    }) catch |err| return buildFailed(&stages, path, err);
    return buildDone(io, &stages, exe_path, timings, opts);
}

/// `fels run <file.fels> [options] [-- args...]`: build the file into `.fels-cache/run/` and run
/// the program with `args`, in this folder and on this terminal. Its exit code is the command's.
fn cmdRun(allocator: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, path: []const u8, source: []const u8, opts: *Options, run_args: []const []const u8) u8 {
    if (opts.dll or opts.no_entry) {
        std.debug.print("fels run: a library does not run; build it with `fels build`\n", .{});
        return 1;
    }
    if (opts.target_os != builtin.os.tag) {
        std.debug.print("fels run: a program for another system does not run here; build it with `fels build`\n", .{});
        return 1;
    }
    const dir = std.fs.path.join(a, &.{ ".fels-cache", "run" }) catch return 1;
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const ext = if (opts.target_os == .windows) ".exe" else "";
    const exe = opts.out_path orelse (std.fmt.allocPrint(a, "{s}{c}{s}{s}", .{ dir, std.fs.path.sep, std.fs.path.stem(path), ext }) catch return 1);
    const obj = std.fmt.allocPrint(a, "{s}.o", .{exe}) catch return 1;
    opts.done_line = false;
    const built = cmdBuild(allocator, io, path, source, obj, exe, opts);
    if (built != 0) return built;

    const cwd = std.process.currentPathAlloc(io, a) catch return 1;
    const program = std.fs.path.resolve(a, &.{ cwd, exe }) catch return 1;
    const argv = std.mem.concat(a, []const u8, &.{ &.{program}, run_args }) catch return 1;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        std.debug.print("fels run: cannot run {s}: {s}\n", .{ exe, @errorName(err) });
        return 1;
    };
    const term = child.wait(io) catch return 1;
    return switch (term) {
        .exited => |code| @intCast(@min(code, 255)),
        else => {
            std.debug.print("{s} {s} did not exit normally\n", .{ ui.mark(.fail), std.fs.path.basename(exe) });
            return 1;
        },
    };
}

// Build system (`fels build` with a build.fels)

/// The LLVM bin folder and the library folders a link needs, as `fels build` finds them:
/// from how fels was built, or the MSVC libraries of this machine.
fn linkPaths(a: std.mem.Allocator, io: std.Io) error{OutOfMemory}!struct { llvm_bin: []const u8, lib_paths: []const []const u8 } {
    const llvm_bin = if (fels.llvm_path.len != 0) try std.fmt.allocPrint(a, "{s}/bin", .{fels.llvm_path}) else "";
    var lib_paths: std.ArrayList([]const u8) = .empty;
    if (fels.windows_sdk_lib_path.len != 0) try lib_paths.append(a, fels.windows_sdk_lib_path);
    if (fels.ucrt_lib_path.len != 0) try lib_paths.append(a, fels.ucrt_lib_path);
    if (fels.msvc_lib_path.len != 0) {
        try lib_paths.append(a, fels.msvc_lib_path);
    } else if (fels.msvc.discoverLibX64(a, io)) |p| try lib_paths.append(a, p);
    return .{ .llvm_bin = llvm_bin, .lib_paths = lib_paths.items };
}

fn cmdBuildDir(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, rest: []const []const u8) u8 {
    if (!fels.llvm_enabled) return noLlvm();

    var opts = fels.build_driver.RunOptions{};

    var llvm_bin: []const u8 = "";
    var llvm_bin_owned = false;
    defer if (llvm_bin_owned) allocator.free(llvm_bin);
    if (fels.llvm_path.len != 0) {
        llvm_bin = std.fmt.allocPrint(allocator, "{s}/bin", .{fels.llvm_path}) catch return 1;
        llvm_bin_owned = true;
    }

    var lib_paths: std.ArrayList([]const u8) = .empty;
    defer lib_paths.deinit(allocator);
    var discovered_msvc: ?[]const u8 = null;
    defer if (discovered_msvc) |p| allocator.free(p);
    if (fels.windows_sdk_lib_path.len != 0) lib_paths.append(allocator, fels.windows_sdk_lib_path) catch return 1;
    // CRT search paths so a build.fels `app.link_libc()` resolves (harmless otherwise).
    if (fels.ucrt_lib_path.len != 0) lib_paths.append(allocator, fels.ucrt_lib_path) catch return 1;
    if (fels.msvc_lib_path.len != 0) {
        lib_paths.append(allocator, fels.msvc_lib_path) catch return 1;
    } else if (fels.msvc.discoverLibX64(allocator, io)) |p| {
        discovered_msvc = p;
        lib_paths.append(allocator, p) catch return 1;
    }

    var run_args: std.ArrayList([]const u8) = .empty;
    defer run_args.deinit(allocator);

    var options: std.ArrayList([]const u8) = .empty;
    defer options.deinit(allocator);

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
        } else if (std.mem.eql(u8, arg, "--release-fast")) {
            opts.release_fast = true;
        } else if (std.mem.eql(u8, arg, "--list")) {
            opts.list = true;
        } else if (eqAny(arg, &.{ "-q", "--quiet" })) {
            opts.quiet = true;
        } else if (eqAny(arg, &.{ "--libc", "-lc" })) {
            opts.link_libc = true;
        } else if (std.mem.eql(u8, arg, "--llvm-path") and i + 1 < rest.len) {
            i += 1;
            if (llvm_bin_owned) allocator.free(llvm_bin);
            llvm_bin = std.fmt.allocPrint(allocator, "{s}/bin", .{rest[i]}) catch return 1;
            llvm_bin_owned = true;
        } else if (std.mem.eql(u8, arg, "--lib-path") and i + 1 < rest.len) {
            i += 1;
            lib_paths.append(allocator, rest[i]) catch return 1;
        } else if (std.mem.eql(u8, arg, "--prefix") and i + 1 < rest.len) {
            i += 1;
            opts.prefix = rest[i];
        } else if (std.mem.eql(u8, arg, "--offline")) {
            opts.offline = true;
        } else if (std.mem.eql(u8, arg, "--rebuild")) {
            opts.rebuild = true;
        } else if (std.mem.eql(u8, arg, "--frozen")) {
            opts.frozen = true;
        } else if (arg.len > 2 and std.mem.startsWith(u8, arg, "-D")) {
            // A build option: `-Dname` (flag) or `-Dname=value`, read by `b.option*`.
            options.append(allocator, arg[2..]) catch return 1;
        } else if (arg.len > 0 and arg[0] == '-') {
            std.debug.print("fels build: unknown option '{s}'\n", .{arg});
            return 1;
        } else if (opts.target == null) {
            opts.target = arg;
        }
    }
    opts.llvm_bin = llvm_bin;
    opts.lib_paths = lib_paths.items;
    opts.run_args = run_args.items;
    opts.options = options.items;
    opts.environ = environ;

    const build_path = "build.fels";
    if (!fileExists(io, build_path)) {
        if (fileExists(io, "build.gab")) {
            std.debug.print("fels build: found build.gab, but Fels files end in `.fels` since 0.5.0; rename it to build.fels (and the other .gab files)\n", .{});
        } else std.debug.print("fels build: no build.fels in the current directory\n", .{});
        return 1;
    }

    fels.build_driver.run(allocator, io, build_path, opts) catch |err| {
        // Most failures are printed where they happen: the script's errors, a package's, an
        // artifact that does not compile, a step or a program that failed.
        switch (err) {
            error.NoBuildScript, error.NoBuildFn, error.NoArtifacts, error.OutOfMemory => std.debug.print("{s} fels build: {s}\n", .{ ui.mark(.fail), @errorName(err) }),
            else => {},
        }
        return 1;
    };
    return 0;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .unlimited) catch return false;
    std.heap.page_allocator.free(data);
    return true;
}

// Relocatable-runtime path resolution

/// True if `dir/<rel>` exists (probe via the page allocator, freed immediately).
/// Whether `dir` holds the standard library.
fn hasStd(io: std.Io, dir: []const u8) bool {
    return dirHasFile(io, dir, "std/io.fels");
}

fn dirHasFile(io: std.Io, dir: []const u8, rel: []const u8) bool {
    const probe = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ dir, rel }) catch return false;
    defer std.heap.page_allocator.free(probe);
    return fileExists(io, probe);
}

/// Find the standard-library root (the directory containing `std/`), returning a
/// path allocated on `ra` (the process arena). Order: `--std-path` > `$FELS_STD` >
/// `$FELS_HOME/lib` > exe-relative (`lib`, `../lib`, `../../lib`) > build-baked.
fn resolveStdRoot(ra: std.mem.Allocator, io: std.Io, env: anytype, flag: []const u8, exe_dir: ?[]const u8) ?[]const u8 {
    if (flag.len > 0) return ra.dupe(u8, flag) catch null;
    if (env.get("FELS_STD")) |v|
        if (hasStd(io, v)) return ra.dupe(u8, v) catch null;
    if (env.get("FELS_HOME")) |home| {
        if (std.fmt.allocPrint(ra, "{s}/lib", .{home}) catch null) |c|
            if (hasStd(io, c)) return c;
    }
    if (exe_dir) |ed| {
        for ([_][]const u8{ "lib", "../lib", "../../lib" }) |rel| {
            const cand = std.fmt.allocPrint(ra, "{s}/{s}", .{ ed, rel }) catch continue;
            if (hasStd(io, cand)) return cand;
        }
    }
    if (fels.stdlib_root.len > 0 and hasStd(io, fels.stdlib_root))
        return ra.dupe(u8, fels.stdlib_root) catch null;
    return null;
}

/// Find the LLVM/linker bin dir (the LLVM DLLs + any linker shipped beside fels).
/// Order: `$FELS_LLVM/bin` > the exe's own dir > null (keep what `--llvm-path` /
/// the build-baked path resolved). Marker is `LLVM-C.dll`: it's in both an LLVM
/// install and the fels core bin, and unlike `lld-link.exe` it survives the switch
/// to in-process linking (felslld.dll). The Linux cross-linker `ld.lld.exe`, when
/// shipped, lives in this same dir, so cross-compiles resolve it here too.
fn resolveLlvmBin(ra: std.mem.Allocator, io: std.Io, env: anytype, exe_dir: ?[]const u8) ?[]const u8 {
    const lld = if (@import("builtin").os.tag == .windows) "LLVM-C.dll" else "ld.lld";
    if (env.get("FELS_LLVM")) |v| {
        if (std.fmt.allocPrint(ra, "{s}/bin", .{v}) catch null) |b|
            if (dirHasFile(io, b, lld)) return b;
    }
    if (exe_dir) |ed|
        if (dirHasFile(io, ed, lld)) return ra.dupe(u8, ed) catch null;
    return null;
}

// Stats

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn printTimings(t: fels.Timings, _: []const u8) void {
    std.debug.print("\n", .{});
    printRow("front-end", t.frontend_ns);
    printRow("lowering", t.lower_ns);
    printRow("optimise", t.passes_ns);
    printRow("codegen", t.codegen_ns);
    printRow("emit object", t.emit_ns);
    printRow("link", t.link_ns);
    std.debug.print("  {s}───────────────────────{s}\n", .{ ui.pal.dim(), ui.pal.reset() });
    printRow("total", t.total_ns);
    // Comptime time is a slice of front-end + lowering — Fels's signature cost.
    if (t.comptime_ns != 0) {
        std.debug.print("  (of which comptime: {d: >7.2} ms)\n", .{ms(t.comptime_ns)});
    }
}

fn printRow(name: []const u8, ns: u64) void {
    std.debug.print("  {s: <14}{d: >8.2} ms\n", .{ name, ms(ns) });
}

// Helpers

fn eqAny(s: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

fn noLlvm() u8 {
    std.debug.print("fels: LLVM backend not enabled.\n" ++
        "    Rebuild: zig build -Dllvm-path=<path>\n", .{});
    return 1;
}

fn deriveOut(allocator: std.mem.Allocator, src: []const u8, ext: []const u8) []const u8 {
    const stem = std.fs.path.stem(src);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, ext }) catch src;
}

fn printDiags(allocator: std.mem.Allocator, diags: []const fels.Diagnostic, path: []const u8, source: []const u8) void {
    const pal = fels.stderrPalette();
    for (diags) |d| {
        const rendered = fels.renderDiagnosticColored(allocator, path, source, d, pal) catch continue;
        defer allocator.free(rendered);
        std.debug.print("{s}\n", .{rendered});
    }
}

fn printUsage() void {
    std.debug.print(
        \\fels {s} — a systems language with compile-time metaprogramming
        \\
        \\usage:  fels <command> <file.fels> [options]
        \\
        \\commands:
        \\  new      <name>        start a project in a new folder (--lib, --cbind; --list)
        \\  init                   start a project in this folder
        \\  build                  run ./build.fels (the build system) — see below
        \\  build    <name>        build a named artifact, or `run`/a step
        \\  build    <file.fels>     compile and link a single file directly
        \\  run      <file.fels>     compile a single file and run it (-- <args> passes arguments)
        \\  check    <file.fels>     parse and type-check only
        \\  test     [path...]     run the #test functions (default: the .fels files in src/)
        \\  test     --comptime    run them on the comptime VM: nothing is built or linked
        \\  test     -j<n>         test n files at once (default: one per core; -j1 one by one)
        \\  test     --filter <text>  run only the #test functions whose name contains the text
        \\  object   <file.fels>     compile to an object file (.o)
        \\  ir       <file.fels>     print LLVM IR to stdout
        \\  bindgen  <header.h>    generate Fels FFI bindings from a C header
        \\  add      <name> <src>  use a package: add it to fels.pkg and fetch it
        \\  fetch                  get the packages fels.pkg uses (--verify checks hashes)
        \\  update   [name...]     move packages to the newest version fels.pkg allows
        \\  remove   <name...>     stop using packages: out of fels.pkg and fels.lock
        \\  why      <name>        where a package comes from, who uses it, what it may do
        \\  vendor                 copy the git packages into vendor/; builds use them from there
        \\  version                print the compiler version
        \\  help                   show this message
        \\
        \\C bindings (fels bindgen, requires an LLVM-enabled build):
        \\  fels bindgen <h> --lib <name> -o <out.fels>   generate bindings for a C library
        \\  fels bindgen <h> -I<dir> -D<sym>            pass include dirs / defines to clang
        \\  fels bindgen <h> -- <clang args...>         forward arbitrary args to clang
        \\
        \\build system (fels build, with a build.fels in the current directory):
        \\  fels build               build the default artifact (or all of them)
        \\  fels build run [-- args] build the default exe, then run it
        \\  fels build <name>        build a named artifact or run a named step
        \\  fels build --list        list the project's artifacts and steps
        \\  fels build --release     build optimized, with the safety checks (release_safe)
        \\  fels build --release-fast  build optimized, without them (release_fast)
        \\  fels build install       copy the installed artifacts to dist/ (--prefix <dir>)
        \\  fels build --offline     use only fels.lock and the package cache, never git
        \\  fels build --frozen      stop when fels.lock would change (for CI)
        \\  fels build --rebuild     build every artifact, also the ones that are up to date
        \\
        \\options:
        \\  -o <path>              output file (default: derived from the source name)
        \\  -O0 / -O1 / -O2 / -O3  optimisation level   (--release = -O2)
        \\  --unchecked            no runtime safety checks (bounds, null, overflow,
        \\                         division by zero, shifts); --release-fast = -O2 --unchecked
        \\  -g, --debug-info       debug info for a debugger (a .pdb on Windows, DWARF on Linux)
        \\  -t, --time             print phase timings (build/object)
        \\  -q, --quiet            no status line or timings
        \\  --llvm-path <dir>      LLVM root (forward slashes)
        \\  --lib-path <dir>       add a linker library search directory
        \\  --lib <name>           link an extra import library (e.g. user32)
        \\
    , .{version});
}
