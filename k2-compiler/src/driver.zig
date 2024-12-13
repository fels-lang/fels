const std = @import("std");
const backend = @import("backend.zig");
const ir = @import("ir.zig");
const pipeline = @import("pipeline.zig");

pub const BuildMode = enum {
    check,
    emit_ir,
    emit_object,
};

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

pub fn compileSource(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    source: []const u8,
    active_backend: backend.Backend,
    options: CompileOptions,
) DriverError!CompileOutput {
    var front_end = pipeline.compile(allocator, file_name, source) catch |err| switch (err) {
        error.ParseFailed, error.SemanticFailed => return error.CompileFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer front_end.deinit(allocator);

    var module = ir.lowerFrontend(allocator, front_end) catch |err| switch (err) {
        error.LoweringFailed => return error.LoweringFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };

    if (options.run_passes) {
        ir.runDefaultPasses(allocator, &module) catch return error.LoweringFailed;
    }
    ir.validateModule(module) catch return error.LoweringFailed;

    return switch (options.mode) {
        .check => .checked,
        .emit_ir => .{ .text_ir = active_backend.emitTextIr(allocator, module) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.BackendFailed,
        } },
        .emit_object => blk: {
            const output_path = options.output_path orelse return error.BackendFailed;
            active_backend.emitObject(module, output_path) catch return error.BackendFailed;
            break :blk .{ .object = output_path };
        },
    };
}
