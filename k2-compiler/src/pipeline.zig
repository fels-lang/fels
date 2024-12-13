const std = @import("std");
const ast = @import("ast.zig");
const diag_mod = @import("diagnostic.zig");
const Diagnostic = diag_mod.Diagnostic;
const parser = @import("parser.zig");
const sema = @import("sema.zig");

pub const FrontEnd = struct {
    module:  ast.Module,
    symbols: sema.SymbolTable,
    types:   sema.TypeEnv,

    pub fn deinit(self: *FrontEnd, allocator: std.mem.Allocator) void {
        self.symbols.deinit(allocator);
        self.types.deinit(allocator);
    }

    /// Any sema diagnostics collected during compilation.
    pub fn diagnostics(self: *const FrontEnd) []const Diagnostic {
        return self.types.diagnostics.items;
    }
};

pub const SourceFile = struct {
    file_name: []const u8,
    source:    []const u8,
};

pub const CompileError = error{
    ParseFailed,
    SemanticFailed,
    IoError,
    OutOfMemory,
};

// ── Public entry points ───────────────────────────────────────────────────────

/// Compile source text directly (no file I/O).
pub fn compile(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    source:    []const u8,
) CompileError!FrontEnd {
    const module = parser.parseSource(allocator, file_name, source) catch |err| switch (err) {
        error.ParseFailed  => return error.ParseFailed,
        error.OutOfMemory  => return error.OutOfMemory,
    };
    return runPipelineWithSource(allocator, module, source, file_name);
}

/// Compile multiple source texts at once (no file I/O, imports ignored).
pub fn compileMulti(allocator: std.mem.Allocator, files: []const SourceFile) CompileError!FrontEnd {
    if (files.len == 0) return runPipelineWithSource(allocator, ast.Module.empty(""), "", "");

    var all_items: std.ArrayList(ast.Item) = .empty;
    errdefer all_items.deinit(allocator);

    var next_id: ast.NodeId = 1;
    for (files) |file| {
        const parsed = parser.parseSourceFrom(allocator, file.file_name, file.source, next_id) catch |err| switch (err) {
            error.ParseFailed => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        };
        next_id = parsed.next_id;
        for (parsed.module.items) |item| switch (item) {
            .import => {},
            else    => try all_items.append(allocator, item),
        };
    }

    const items = try all_items.toOwnedSlice(allocator);
    return runPipelineWithSource(allocator, .{ .file_name = files[0].file_name, .items = items }, files[0].source, files[0].file_name);
}

/// Compile a .k2 file from disk, resolving `#import` declarations recursively.
/// Requires an `std.Io` instance (Zig 0.16 explicit I/O).
pub fn compileFile(
    allocator: std.mem.Allocator,
    io:        std.Io,
    path:      []const u8,
) CompileError!FrontEnd {
    var loaded = std.StringHashMap(void).init(allocator);
    defer loaded.deinit();

    var all_items: std.ArrayList(ast.Item) = .empty;
    errdefer all_items.deinit(allocator);

    var root_source: []const u8 = "";
    var next_id: ast.NodeId = 1;

    loadFile(allocator, io, path, &loaded, &all_items, &next_id, &root_source, true) catch |err| switch (err) {
        error.ParseFailed  => return error.ParseFailed,
        error.OutOfMemory  => return error.OutOfMemory,
        else               => return error.IoError,
    };

    const items = try all_items.toOwnedSlice(allocator);
    return runPipelineWithSource(allocator, .{ .file_name = path, .items = items }, root_source, path);
}

// ── Internal helpers ──────────────────────────────────────────────────────────

fn loadFile(
    allocator:   std.mem.Allocator,
    io:          std.Io,
    path:        []const u8,
    loaded:      *std.StringHashMap(void),
    all_items:   *std.ArrayList(ast.Item),
    next_id:     *ast.NodeId,
    root_source: *[]const u8,
    is_root:     bool,
) !void {
    if (loaded.contains(path)) return;
    try loaded.put(path, {});

    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    if (is_root) root_source.* = source;

    const parsed = try parser.parseSourceFrom(allocator, path, source, next_id.*);
    next_id.* = parsed.next_id;

    // Resolve imports BEFORE adding this file's items (so dependency order is right)
    const dir = std.fs.path.dirname(path) orelse ".";
    for (parsed.module.items) |item| {
        switch (item) {
            .import => |imp| {
                const resolved = resolveImportPath(allocator, dir, imp.path) catch continue;
                loadFile(allocator, io, resolved, loaded, all_items, next_id, root_source, false) catch {};
            },
            else => try all_items.append(allocator, item),
        }
    }
}

/// Turn an import path like ["utils", "math"] into "utils/math.k2"
/// relative to `base_dir`.
fn resolveImportPath(
    allocator: std.mem.Allocator,
    base_dir:  []const u8,
    parts:     []const []const u8,
) ![]const u8 {
    // Skip well-known non-local prefixes until we have a stdlib
    if (parts.len > 0 and std.mem.eql(u8, parts[0], "std")) return error.NotFound;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    if (base_dir.len > 0) {
        try buf.appendSlice(allocator, base_dir);
        try buf.append(allocator, std.fs.path.sep);
    }
    for (parts, 0..) |part, i| {
        if (i > 0) try buf.append(allocator, std.fs.path.sep);
        try buf.appendSlice(allocator, part);
    }
    try buf.appendSlice(allocator, ".k2");
    return buf.toOwnedSlice(allocator);
}

fn runPipeline(allocator: std.mem.Allocator, module: ast.Module) CompileError!FrontEnd {
    return runPipelineWithSource(allocator, module, "", "");
}

fn runPipelineWithSource(
    allocator: std.mem.Allocator,
    module:    ast.Module,
    source:    []const u8,
    file:      []const u8,
) CompileError!FrontEnd {
    var symbols = sema.collectSymbols(allocator, module) catch |err| switch (err) {
        error.SemanticFailed => return error.SemanticFailed,
        error.OutOfMemory    => return error.OutOfMemory,
    };
    errdefer symbols.deinit(allocator);

    sema.resolveNames(allocator, module, symbols) catch |err| switch (err) {
        error.SemanticFailed => {},
        error.OutOfMemory    => return error.OutOfMemory,
    };
    sema.checkZones(allocator, module, symbols) catch |err| switch (err) {
        error.SemanticFailed => {},
        error.OutOfMemory    => return error.OutOfMemory,
    };

    var types = sema.checkTypesWithContext(allocator, module, symbols, source, file) catch |err| switch (err) {
        error.SemanticFailed => return error.SemanticFailed,
        error.OutOfMemory    => return error.OutOfMemory,
    };
    errdefer types.deinit(allocator);

    return .{ .module = module, .symbols = symbols, .types = types };
}
