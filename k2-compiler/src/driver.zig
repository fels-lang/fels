const std = @import("std");
const backend = @import("backend.zig");
const ir = @import("ir.zig");
const pipeline = @import("pipeline.zig");
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
        error.ParseFailed, error.SemanticFailed, error.IoError => return error.CompileFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer fe.deinit(allocator);

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
};

pub const LlvmDriverError = error{
    CompileFailed,
    LlvmNotEnabled,
    LoweringFailed,
    EmitFailed,
    LinkFailed,
    OutOfMemory,
};

/// Full pipeline: source → IR → LLVM IR → .o → (optional) .exe
pub fn compileWithLlvm(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: LlvmCompileOptions,
) LlvmDriverError!void {
    if (!build_options.enable_llvm) return error.LlvmNotEnabled;

    // Frontend
    var fe = pipeline.compile(allocator, opts.file_name, opts.source) catch |err| switch (err) {
        error.ParseFailed, error.SemanticFailed, error.IoError => return error.CompileFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer fe.deinit(allocator);

    // Middle-end
    var module = ir.lowerFrontend(allocator, fe) catch |err| switch (err) {
        error.LoweringFailed => return error.LoweringFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    ir.runDefaultPasses(allocator, &module) catch return error.LoweringFailed;
    ir.validateModule(module) catch return error.LoweringFailed;

    // LLVM backend
    const llvm_backend = @import("backend/llvm.zig");
    const module_name = try allocator.dupeZ(u8, opts.file_name);
    defer allocator.free(module_name);

    var be = llvm_backend.LlvmBackend.init(allocator, module_name);
    defer be.deinit();

    be.lower(module) catch return error.LoweringFailed;

    // Emit object file
    const obj_z = try allocator.dupeZ(u8, opts.obj_path);
    defer allocator.free(obj_z);
    be.emitObject(obj_z, opts.opt_level) catch return error.EmitFailed;

    // Link (optional)
    if (opts.exe_path) |exe| {
        be.linkWindows(allocator, io, .{
            .llvm_bin = opts.llvm_bin,
            .obj_files = &.{opts.obj_path},
            .output = exe,
            .lib_paths = opts.lib_paths,
        }) catch return error.LinkFailed;
    }
}
