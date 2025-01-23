const std = @import("std");
const ast = @import("ast.zig");
const diag_mod = @import("diagnostic.zig");
const Diagnostic = diag_mod.Diagnostic;
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const runtime = @import("runtime.zig");
const build_options = @import("build_options");

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
    RuntimeUnavailable,
    OutOfMemory,
};

// ── Public entry points ───────────────────────────────────────────────────────

/// Compile source text directly (no file I/O).
/// Does NOT include the runtime — used by tests and library consumers.
/// Use compileWithLlvm() in driver.zig for programs that need @panic/assert.
pub fn compile(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    source: []const u8,
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
    source: []const u8,
) CompileError!FrontEnd {
    const rt_src = runtime.runtimeSourceFor(@import("builtin").os.tag) orelse return error.RuntimeUnavailable;
    return compileMulti(allocator, &.{
        .{ .file_name = "<runtime>", .source = rt_src },
        .{ .file_name = file_name, .source = source },
    });
}

/// Compile multiple source texts at once (no file I/O).
pub fn compileMulti(allocator: std.mem.Allocator, files: []const SourceFile) CompileError!FrontEnd {
    const arena = try createFrontendArena(allocator);
    errdefer destroyFrontendArena(allocator, arena);
    const fe_allocator = arena.allocator();

    if (files.len == 0) return runPipelineWithSource(fe_allocator, ast.Module.empty(""), "", "", arena);

    var all_items: std.ArrayList(ast.Item) = .empty;
    errdefer all_items.deinit(fe_allocator);
    var modules: std.ArrayList(ast.Module) = .empty;
    defer modules.deinit(fe_allocator);
    var available = std.StringHashMap(void).init(fe_allocator);
    defer available.deinit();

    var next_id: ast.NodeId = 1;
    for (files) |file| {
        const normalized_name = normalizeLogicalPath(fe_allocator, file.file_name) catch return error.OutOfMemory;
        if (available.contains(normalized_name)) {
            std.debug.print("{s}: error: module was provided more than once\n", .{normalized_name});
            return error.IoError;
        }
        const parsed = parser.parseSourceFrom(fe_allocator, normalized_name, file.source, next_id) catch |err| switch (err) {
            error.ParseFailed => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        };
        next_id = parsed.next_id;
        try modules.append(fe_allocator, parsed.module);
        try available.put(normalized_name, {});
    }
    for (modules.items) |parsed_module| {
        const dir = std.fs.path.dirname(parsed_module.file_name) orelse ".";
        for (parsed_module.items) |item| switch (item) {
            .import => |imp| {
                const resolved = resolveImportPath(fe_allocator, dir, imp.path, null) catch return error.IoError;
                const normalized = normalizeLogicalPath(fe_allocator, resolved) catch return error.OutOfMemory;
                if (!available.contains(normalized)) {
                    std.debug.print("{s}: error: imported module `{s}` was not provided\n", .{ imp.file_name, normalized });
                    return error.IoError;
                }
                var resolved_import = imp;
                resolved_import.resolved_file = normalized;
                try all_items.append(fe_allocator, .{ .import = resolved_import });
            },
            else => try all_items.append(fe_allocator, item),
        };
    }

    const items = try all_items.toOwnedSlice(fe_allocator);
    return runPipelineWithSource(fe_allocator, .{ .file_name = modules.items[0].file_name, .items = items }, files[0].source, modules.items[0].file_name, arena);
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
        const rt_src = runtime.runtimeSourceFor(@import("builtin").os.tag) orelse return error.RuntimeUnavailable;
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

    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| {
        std.debug.print("{s}: error: cannot read imported module: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    if (is_root) root_source.* = source;

    const parsed = try parser.parseSourceFrom(allocator, path, source, next_id.*);
    next_id.* = parsed.next_id;

    // Retain the import edge for visibility checking, then load the dependency.
    const dir = std.fs.path.dirname(path) orelse ".";
    for (parsed.module.items) |item| {
        switch (item) {
            .import => |imp| {
                const resolved = try resolveImportPath(allocator, dir, imp.path, build_options.stdlib_root);
                var resolved_import = imp;
                resolved_import.resolved_file = resolved;
                try all_items.append(allocator, .{ .import = resolved_import });
                try loadFile(allocator, io, resolved, loaded, all_items, next_id, root_source, false);
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
    stdlib_root: ?[]const u8,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const is_std = parts.len > 0 and std.mem.eql(u8, parts[0], "std");
    if (is_std and stdlib_root != null) {
        try buf.appendSlice(allocator, stdlib_root.?);
        try buf.append(allocator, std.fs.path.sep);
    } else if (!is_std and base_dir.len > 0) {
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

fn normalizeLogicalPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var start: usize = 0;
    while (std.mem.startsWith(u8, path[start..], "./") or std.mem.startsWith(u8, path[start..], ".\\")) {
        start += 2;
    }
    const normalized = try allocator.dupe(u8, path[start..]);
    for (normalized) |*ch| {
        if (ch.* != '\\') continue;
        ch.* = '/';
    }
    return normalized;
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
        error.OutOfMemory => return error.OutOfMemory,
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

    var types = sema.checkTypesWithContext(allocator, module, &symbols, source, file) catch |err| switch (err) {
        error.SemanticFailed => return error.SemanticFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer types.deinit(allocator);

    // Surface any warnings that accumulated even on a successful compile.
    return .{
        .module = module,
        .symbols = symbols,
        .types = types,
        .arena = arena,
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
