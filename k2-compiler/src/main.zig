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
const k2 = @import("k2_compiler");

// Zig 0.16 main signature — receives allocator, Io, and args from the startup system.
pub fn main(init: std.process.Init) u8 {
    const allocator = init.gpa;
    const io = init.io;

    // Collect args into a slice of strings.
    var args_iter = std.process.Args.Iterator.initAllocator(init.minimal.args, allocator) catch return 1;
    defer args_iter.deinit();
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(allocator);
    while (args_iter.next()) |arg| {
        args_list.append(allocator, arg) catch return 1;
    }
    const args = args_list.items;

    if (args.len < 3) {
        printUsage();
        return 1;
    }

    const cmd = args[1];
    const src_path = args[2];

    // Parse remaining options.
    var out_path: ?[]const u8 = null;
    var llvm_bin: []const u8 = "";
    var opt_level: u2 = 0;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-o") and i + 1 < args.len) {
            i += 1;
            out_path = args[i];
        } else if (std.mem.eql(u8, a, "--llvm-path") and i + 1 < args.len) {
            i += 1;
            llvm_bin = std.fmt.allocPrint(allocator, "{s}/bin", .{args[i]}) catch return 1;
        } else if (std.mem.eql(u8, a, "--opt") and i + 1 < args.len) {
            i += 1;
            opt_level = std.fmt.parseInt(u2, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, a, "--release")) {
            opt_level = 2;
        }
    }

    // Read source file.
    const cwd = std.Io.Dir.cwd();
    const source = cwd.readFileAlloc(io, src_path, allocator, .unlimited) catch |err| {
        std.debug.print("k2: cannot read '{s}': {s}\n", .{ src_path, @errorName(err) });
        return 1;
    };
    defer allocator.free(source);

    // Dispatch command.
    if (std.mem.eql(u8, cmd, "check")) return cmdCheck(allocator, src_path, source);
    if (std.mem.eql(u8, cmd, "ir")) return cmdIr(allocator, io, src_path, source);
    if (std.mem.eql(u8, cmd, "object")) {
        const obj = out_path orelse deriveOut(allocator, src_path, ".o");
        return cmdObject(allocator, io, src_path, source, obj, opt_level);
    }
    if (std.mem.eql(u8, cmd, "build")) {
        const exe = out_path orelse deriveOut(allocator, src_path, ".exe");
        const obj = std.fmt.allocPrint(allocator, "{s}.o", .{exe}) catch return 1;
        defer allocator.free(obj);
        return cmdBuild(allocator, io, src_path, source, obj, exe, opt_level, llvm_bin);
    }

    std.debug.print("k2: unknown command '{s}'\n", .{cmd});
    printUsage();
    return 1;
}

// ── Commands ──────────────────────────────────────────────────────────────────

fn cmdCheck(allocator: std.mem.Allocator, path: []const u8, source: []const u8) u8 {
    var fe = k2.compile(allocator, path, source) catch |err| {
        std.debug.print("k2: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer fe.deinit(allocator);
    printDiags(allocator, fe.diagnostics(), path, source);
    std.debug.print("ok\n", .{});
    return 0;
}

fn cmdIr(allocator: std.mem.Allocator, io: std.Io, path: []const u8, source: []const u8) u8 {
    if (!k2.llvm_enabled) return noLlvm();
    var fe = k2.compile(allocator, path, source) catch return 1;
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

fn cmdObject(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    source: []const u8,
    obj_path: []const u8,
    opt_level: u2,
) u8 {
    if (!k2.llvm_enabled) return noLlvm();
    k2.compileWithLlvm(allocator, io, .{
        .file_name = path,
        .source = source,
        .obj_path = obj_path,
        .opt_level = opt_level,
    }) catch |err| {
        std.debug.print("k2: {s}\n", .{@errorName(err)});
        return 1;
    };
    std.debug.print("{s}\n", .{obj_path});
    return 0;
}

fn cmdBuild(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    source: []const u8,
    obj_path: []const u8,
    exe_path: []const u8,
    opt_level: u2,
    llvm_bin: []const u8,
) u8 {
    if (!k2.llvm_enabled) return noLlvm();
    k2.compileWithLlvm(allocator, io, .{
        .file_name = path,
        .source = source,
        .obj_path = obj_path,
        .exe_path = exe_path,
        .opt_level = opt_level,
        .llvm_bin = llvm_bin,
    }) catch |err| {
        std.debug.print("k2: {s}\n", .{@errorName(err)});
        return 1;
    };
    std.debug.print("{s}\n", .{exe_path});
    return 0;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn noLlvm() u8 {
    std.debug.print("k2: LLVM backend not enabled.\n" ++
        "    Rebuild: zig build -Dllvm-path=<path>\n", .{});
    return 1;
}

fn deriveOut(allocator: std.mem.Allocator, src: []const u8, ext: []const u8) []const u8 {
    const stem = std.fs.path.stem(src);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, ext }) catch src;
}

fn printDiags(
    allocator: std.mem.Allocator,
    diags: []const k2.Diagnostic,
    path: []const u8,
    source: []const u8,
) void {
    for (diags) |d| {
        const rendered = k2.renderDiagnostic(allocator, path, source, d) catch continue;
        defer allocator.free(rendered);
        std.debug.print("{s}\n", .{rendered});
    }
}

fn printUsage() void {
    std.debug.print(
        \\k2 compiler
        \\
        \\  k2 check  <file.k2>             type-check only
        \\  k2 build  <file.k2> [opts]      compile to .exe
        \\  k2 object <file.k2> [opts]      compile to .o
        \\  k2 ir     <file.k2>             dump LLVM IR
        \\
        \\Options:
        \\  -o <path>           output file
        \\  --llvm-path <dir>   LLVM root (use forward slashes)
        \\  --opt <0-3>         optimisation level (default 0)
        \\  --release           alias for --opt 2
        \\
    , .{});
}
