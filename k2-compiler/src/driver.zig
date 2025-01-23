const std = @import("std");
const backend = @import("backend.zig");
const ir = @import("ir.zig");
const pipeline = @import("pipeline.zig");
const diag_mod = @import("diagnostic.zig");
const runtime_mod = @import("runtime.zig");
const build_options = @import("build_options");

pub const BuildMode = enum { check, emit_ir, emit_object };

pub const CompileOptions = struct {
    mode: BuildMode = .check,
    output_path: ?[]const u8 = null,
    run_passes: bool = true,
};

pub const CompileOutput = union(enum) {
    checked,
    text_ir: []u8,
    object: []const u8,
};

pub const DriverError = error{
    CompileFailed,
    LoweringFailed,
    BackendFailed,
    OutOfMemory,
};

/// Compile source text using the legacy basalt backend stub.
pub fn compileSource(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    source: []const u8,
    active_backend: backend.Backend,
    options: CompileOptions,
) DriverError!CompileOutput {
    var fe = pipeline.compile(allocator, file_name, source) catch |err| switch (err) {
        error.ParseFailed, error.SemanticFailed, error.IoError, error.RuntimeUnavailable => return error.CompileFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer fe.deinit(allocator);
    if (fe.diagnostics().len != 0) {
        for (fe.diagnostics()) |d| {
            const rendered = diag_mod.renderDiagnostic(allocator, d.file, source, d) catch continue;
            defer allocator.free(rendered);
            std.debug.print("{s}\n", .{rendered});
        }
        return error.CompileFailed;
    }

    var module = ir.lowerFrontend(allocator, fe) catch |err| switch (err) {
        error.LoweringFailed => return error.LoweringFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };

    if (options.run_passes) ir.runDefaultPasses(allocator, &module) catch return error.LoweringFailed;
    ir.validateModule(module) catch return error.LoweringFailed;

    return switch (options.mode) {
        .check => .checked,
        .emit_ir => .{ .text_ir = active_backend.emitTextIr(allocator, module) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.BackendFailed,
        } },
        .emit_object => blk: {
            const out = options.output_path orelse return error.BackendFailed;
            active_backend.emitObject(module, out) catch return error.BackendFailed;
            break :blk .{ .object = out };
        },
    };
}

// ── LLVM backend path ─────────────────────────────────────────────────────────

pub const LlvmCompileOptions = struct {
    /// Source file path (for diagnostics).
    file_name: []const u8,
    /// K2 source text.
    source: []const u8,
    /// Where to write the object file.
    obj_path: []const u8,
    /// Where to write the executable (null = stop at .o).
    exe_path: ?[]const u8 = null,
    /// LLVM opt level (0–3).
    opt_level: u2 = if (@import("builtin").mode == .Debug) 0 else 2,
    /// Path to the LLVM bin directory (for lld-link).
    llvm_bin: []const u8 = "",
    /// Extra library search paths for the linker.
    lib_paths: []const []const u8 = &.{},
    /// Extra import libraries to link (without the `.lib` extension), in
    /// addition to those inferred from `#extern("lib", "symbol")` decls —
    /// e.g. transitive system libs a C library depends on (gdi32, user32, ...).
    extra_libs: []const []const u8 = &.{},
};

pub const LlvmDriverError = error{
    CompileFailed,
    LlvmNotEnabled,
    LoweringFailed,
    EmitFailed,
    LinkFailed,
    OutOfMemory,
};

/// Print diagnostics from a FrontEnd to stderr, using the correct source text
/// for each file (user file or embedded runtime).
fn printFeDiagnostics(
    allocator: std.mem.Allocator,
    diags: []const diag_mod.Diagnostic,
    user_file: []const u8,
    user_source: []const u8,
) void {
    const rt_src = runtime_mod.runtimeSource();
    for (diags) |d| {
        const src: []const u8 =
            if (std.mem.eql(u8, d.file, user_file)) user_source else if (std.mem.eql(u8, d.file, "<runtime>")) rt_src else "";
        const rendered = diag_mod.renderDiagnostic(allocator, d.file, src, d) catch continue;
        defer allocator.free(rendered);
        std.debug.print("{s}\n", .{rendered});
    }
}

/// Full pipeline: source → IR → LLVM IR → .o → (optional) .exe
pub fn compileWithLlvm(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: LlvmCompileOptions,
) LlvmDriverError!void {
    if (!build_options.enable_llvm) return error.LlvmNotEnabled;

    // compileWithRuntime auto-prepends the platform runtime (@panic, assert, etc.)
    var fe = pipeline.compileWithRuntime(allocator, opts.file_name, opts.source) catch |err| switch (err) {
        error.ParseFailed, error.SemanticFailed, error.IoError, error.RuntimeUnavailable => return error.CompileFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer fe.deinit(allocator);
    if (fe.diagnostics().len != 0) {
        printFeDiagnostics(allocator, fe.diagnostics(), opts.file_name, opts.source);
        return error.CompileFailed;
    }

    try emitLlvmFromFrontend(allocator, io, fe, opts);
}

/// Full file pipeline: .k2 path + imports -> IR -> LLVM IR -> .o -> (optional) .exe
pub fn compileFileWithLlvm(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: LlvmCompileOptions,
) LlvmDriverError!void {
    if (!build_options.enable_llvm) return error.LlvmNotEnabled;

    var fe = pipeline.compileFileWithRuntime(allocator, io, opts.file_name) catch |err| switch (err) {
        error.ParseFailed, error.SemanticFailed, error.IoError, error.RuntimeUnavailable => return error.CompileFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer fe.deinit(allocator);
    if (fe.diagnostics().len != 0) {
        printFeDiagnostics(allocator, fe.diagnostics(), opts.file_name, opts.source);
        return error.CompileFailed;
    }

    try emitLlvmFromFrontend(allocator, io, fe, opts);
}

fn emitLlvmFromFrontend(
    allocator: std.mem.Allocator,
    io: std.Io,
    fe: pipeline.FrontEnd,
    opts: LlvmCompileOptions,
) LlvmDriverError!void {
    var ir_arena = std.heap.ArenaAllocator.init(allocator);
    defer ir_arena.deinit();
    const ir_allocator = ir_arena.allocator();

    // Middle-end
    var module = ir.lowerFrontend(ir_allocator, fe) catch |err| switch (err) {
        error.LoweringFailed => {
            std.debug.print("{s}: compilation failed due to internal compiler error (see above)\n", .{opts.file_name});
            return error.LoweringFailed;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    ir.runDefaultPasses(ir_allocator, &module) catch {
        std.debug.print("{s}: internal compiler error during IR optimisation passes\n", .{opts.file_name});
        return error.LoweringFailed;
    };
    ir.validateModule(module) catch {
        std.debug.print("{s}: internal compiler error: IR validation failed (malformed IR produced)\n", .{opts.file_name});
        return error.LoweringFailed;
    };

    // LLVM backend
    const llvm_backend = @import("backend/llvm.zig");
    const module_name = try allocator.dupeZ(u8, opts.file_name);
    defer allocator.free(module_name);

    var be = llvm_backend.LlvmBackend.init(allocator, module_name);
    defer be.deinit();

    be.setOptLevel(opts.opt_level);
    be.lower(module) catch {
        std.debug.print("{s}: compilation failed due to internal compiler error during code generation (see above)\n", .{opts.file_name});
        return error.LoweringFailed;
    };

    // Emit object file
    const obj_z = try allocator.dupeZ(u8, opts.obj_path);
    defer allocator.free(obj_z);
    be.emitObject(obj_z, opts.opt_level) catch return error.EmitFailed;

    // Link (optional)
    if (opts.exe_path) |exe| {
        // Combine libs inferred from `#extern("lib", "symbol")` decls with any
        // user-supplied `--lib` libraries (e.g. transitive system deps).
        var libs: std.ArrayList([]const u8) = .empty;
        defer libs.deinit(allocator);
        try libs.appendSlice(allocator, module.extern_libs);
        try libs.appendSlice(allocator, opts.extra_libs);

        be.linkWindows(allocator, io, .{
            .llvm_bin = opts.llvm_bin,
            .obj_files = &.{opts.obj_path},
            .output = exe,
            .lib_paths = opts.lib_paths,
            .libs = libs.items,
        }) catch return error.LinkFailed;
    }
}
