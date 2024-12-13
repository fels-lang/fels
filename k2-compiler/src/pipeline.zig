const std = @import("std");
const ast = @import("ast.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;
const parser = @import("parser.zig");
const sema = @import("sema.zig");

pub const FrontEnd = struct {
    module: ast.Module,
    symbols: sema.SymbolTable,
    types: sema.TypeEnv,

    pub fn deinit(self: *FrontEnd, allocator: std.mem.Allocator) void {
        self.symbols.deinit(allocator);
        self.types.deinit(allocator);
    }
};

pub const SourceFile = struct {
    file_name: []const u8,
    source: []const u8,
};

pub const CompileError = error{
    ParseFailed,
    SemanticFailed,
    OutOfMemory,
};

pub fn compile(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    source: []const u8,
) CompileError!FrontEnd {
    const module = parser.parseSource(allocator, file_name, source) catch |err| switch (err) {
        error.ParseFailed => return error.ParseFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };

    return runPipeline(allocator, module);
}

pub fn compileMulti(allocator: std.mem.Allocator, files: []const SourceFile) CompileError!FrontEnd {
    if (files.len == 0) {
        return runPipeline(allocator, ast.Module.empty(""));
    }

    var all_items: std.ArrayList(ast.Item) = .empty;
    errdefer all_items.deinit(allocator);

    var next_id: ast.NodeId = 1;
    for (files) |file| {
        const parsed = parser.parseSourceFrom(allocator, file.file_name, file.source, next_id) catch |err| switch (err) {
            error.ParseFailed => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        };
        next_id = parsed.next_id;

        for (parsed.module.items) |item| {
            switch (item) {
                .import => {},
                else => try all_items.append(allocator, item),
            }
        }
    }

    const items = try all_items.toOwnedSlice(allocator);
    return runPipeline(allocator, .{
        .file_name = files[0].file_name,
        .items = items,
    });
}

fn runPipeline(allocator: std.mem.Allocator, module: ast.Module) CompileError!FrontEnd {
    var symbols = sema.collectSymbols(allocator, module) catch |err| switch (err) {
        error.SemanticFailed => return error.SemanticFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer symbols.deinit(allocator);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);

    sema.resolveNames(allocator, module, symbols) catch |err| switch (err) {
        error.SemanticFailed => {},
        error.OutOfMemory => return error.OutOfMemory,
    };
    sema.checkZones(allocator, module, symbols) catch |err| switch (err) {
        error.SemanticFailed => {},
        error.OutOfMemory => return error.OutOfMemory,
    };

    var types = sema.checkTypes(allocator, module, symbols) catch |err| switch (err) {
        error.SemanticFailed => return error.SemanticFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer types.deinit(allocator);

    return .{
        .module = module,
        .symbols = symbols,
        .types = types,
    };
}
