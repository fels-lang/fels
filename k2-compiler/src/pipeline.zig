const std       = @import("std");
const ast       = @import("ast.zig");
const diag_mod  = @import("diagnostic.zig");
const Diagnostic = diag_mod.Diagnostic;
const parser    = @import("parser.zig");
const sema      = @import("sema.zig");
const runtime   = @import("runtime.zig");

pub const FrontEnd = struct {
    module: ast.Module,
    symbols: sema.SymbolTable,
    types: sema.TypeEnv,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *FrontEnd, allocator: std.mem.Allocator) void {
        const arena_allocator = self.arena.allocator();
        self.symbols.deinit(arena_allocator);
        self.types.deinit(arena_allocator);
        self.arena.deinit();
        allocator.destroy(self.arena);
    }

    /// Any sema diagnostics collected during compilation.
    pub fn diagnostics(self: *const FrontEnd) []const Diagnostic {
        return self.types.diagnostics.items;
    }
};

pub const SourceFile = struct {
    file_name: []const u8,
    source: []const u8,
};

pub const CompileError = error{
    ParseFailed,
    SemanticFailed,
    IoError,
    OutOfMemory,
};

// ── Public entry points ───────────────────────────────────────────────────────

/// Compile source text directly (no file I/O).
/// Does NOT include the runtime — used by tests and library consumers.
/// Use compileWithLlvm() in driver.zig for programs that need @panic/assert.
pub fn compile(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    source:    []const u8,
) CompileError!FrontEnd {
    const arena = try createFrontendArena(allocator);
    errdefer destroyFrontendArena(allocator, arena);
    const fe_allocator = arena.allocator();
    const module = parser.parseSource(fe_allocator, file_name, source) catch |err| switch (err) {
        error.ParseFailed => return error.ParseFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return runPipelineWithSource(fe_allocator, module, source, file_name, arena);
}

/// Compile source with the embedded platform runtime prepended.
/// This is what driver.compileWithLlvm() uses for real programs.
pub fn compileWithRuntime(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    source:    []const u8,
) CompileError!FrontEnd {
    const rt_src = runtime.runtimeSource();
    if (rt_src.len == 0) return compile(allocator, file_name, source);
    return compileMulti(allocator, &.{
        .{ .file_name = "<runtime>", .source = rt_src },
        .{ .file_name = file_name,  .source = source  },
    });
}

/// Compile multiple source texts at once (no file I/O, imports ignored).
pub fn compileMulti(allocator: std.mem.Allocator, files: []const SourceFile) CompileError!FrontEnd {
    const arena = try createFrontendArena(allocator);
    errdefer destroyFrontendArena(allocator, arena);
    const fe_allocator = arena.allocator();

    if (files.len == 0) return runPipelineWithSource(fe_allocator, ast.Module.empty(""), "", "", arena);

    var all_items: std.ArrayList(ast.Item) = .empty;
    errdefer all_items.deinit(fe_allocator);

    var next_id: ast.NodeId = 1;
    for (files) |file| {
        const parsed = parser.parseSourceFrom(fe_allocator, file.file_name, file.source, next_id) catch |err| switch (err) {
            error.ParseFailed => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        };
        next_id = parsed.next_id;
        for (parsed.module.items) |item| switch (item) {
            .import => {},
            else => try all_items.append(fe_allocator, item),
        };
    }

    const items = try all_items.toOwnedSlice(fe_allocator);
    return runPipelineWithSource(fe_allocator, .{ .file_name = files[0].file_name, .items = items }, files[0].source, files[0].file_name, arena);
}

/// Compile a .k2 file from disk, resolving `#import` declarations recursively.
/// Requires an `std.Io` instance (Zig 0.16 explicit I/O).
pub fn compileFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) CompileError!FrontEnd {
    return compileFileInternal(allocator, io, path, false);
}

/// Compile a .k2 file and its imports with the embedded platform runtime.
pub fn compileFileWithRuntime(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) CompileError!FrontEnd {
    return compileFileInternal(allocator, io, path, true);
}

fn compileFileInternal(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    include_runtime: bool,
) CompileError!FrontEnd {
    const arena = try createFrontendArena(allocator);
    errdefer destroyFrontendArena(allocator, arena);
    const fe_allocator = arena.allocator();

    var loaded = std.StringHashMap(void).init(fe_allocator);
    defer loaded.deinit();

    var all_items: std.ArrayList(ast.Item) = .empty;
    errdefer all_items.deinit(fe_allocator);

    var root_source: []const u8 = "";
    var next_id: ast.NodeId = 1;

    if (include_runtime) {
        const rt_src = runtime.runtimeSource();
        if (rt_src.len != 0) {
            const parsed = parser.parseSourceFrom(fe_allocator, "<runtime>", rt_src, next_id) catch |err| switch (err) {
                error.ParseFailed => return error.ParseFailed,
                error.OutOfMemory => return error.OutOfMemory,
            };
            next_id = parsed.next_id;
            for (parsed.module.items) |item| switch (item) {
                .import => {},
                else => try all_items.append(fe_allocator, item),
            };
        }
    }

    loadFile(fe_allocator, io, path, &loaded, &all_items, &next_id, &root_source, true) catch |err| switch (err) {
        error.ParseFailed => return error.ParseFailed,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.IoError,
    };

    const items = try all_items.toOwnedSlice(fe_allocator);
    return runPipelineWithSource(fe_allocator, .{ .file_name = path, .items = items }, root_source, path, arena);
}

// ── Internal helpers ──────────────────────────────────────────────────────────

fn loadFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    loaded: *std.StringHashMap(void),
    all_items: *std.ArrayList(ast.Item),
    next_id: *ast.NodeId,
    root_source: *[]const u8,
    is_root: bool,
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
    base_dir: []const u8,
    parts: []const []const u8,
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

fn runPipelineWithSource(
    allocator: std.mem.Allocator,
    module: ast.Module,
    source: []const u8,
    file: []const u8,
    arena: *std.heap.ArenaAllocator,
) CompileError!FrontEnd {
    var symbols = sema.collectSymbols(allocator, module) catch |err| switch (err) {
        error.SemanticFailed => return error.SemanticFailed,
        error.OutOfMemory    => return error.OutOfMemory,
    };
    errdefer symbols.deinit(allocator);

    sema.resolveNames(allocator, module, symbols) catch |err| switch (err) {
        error.SemanticFailed => {},
        error.OutOfMemory => return error.OutOfMemory,
    };
    sema.checkZones(allocator, module, symbols) catch |err| switch (err) {
        error.SemanticFailed => {},
        error.OutOfMemory => return error.OutOfMemory,
    };

    var types = sema.checkTypesWithContext(allocator, module, symbols, source, file) catch |err| switch (err) {
        error.SemanticFailed => return error.SemanticFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer types.deinit(allocator);

    // Surface any warnings that accumulated even on a successful compile.
    return .{
        .module  = module,
        .symbols = symbols,
        .types   = types,
        .arena   = arena,
    };
}

fn createFrontendArena(allocator: std.mem.Allocator) CompileError!*std.heap.ArenaAllocator {
    const arena = allocator.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
    arena.* = std.heap.ArenaAllocator.init(allocator);
    return arena;
}

fn destroyFrontendArena(allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator) void {
    arena.deinit();
    allocator.destroy(arena);
}
