const std = @import("std");
const ast = @import("ast.zig");
const Span = @import("lexer/span.zig").Span;
const diag_mod = @import("diagnostic.zig");
const Diagnostic = diag_mod.Diagnostic;
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const macroexpand = @import("macroexpand.zig");
const ast_prelude = @import("ast_prelude.zig");
const ir_mod = @import("ir.zig");

/// Node-id base for prelude nodes — high enough to never collide with a real
/// program's ids (which start at 1 and increment per parsed node).
const prelude_id_base: ast.NodeId = 900_000;
const runtime = @import("runtime.zig");
const std_prelude = @import("std_prelude.zig");
const build_options = @import("build_options");

/// Node-id bases for the embedded std.heap/std.ptr prelude. High enough not to
/// collide with a real program's ids (which start at 1), and below the ast.*
/// prelude base (900_000); ptr is parsed first and heap chains off its next id.
const heap_prelude_id_base: ast.NodeId = 600_000;
/// Node-id base for the injected `TypeInfo` reflection prelude (distinct range).
const reflection_prelude_id_base: ast.NodeId = 500_000;

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

/// True when `items` already contains an `#import std.heap…` (any form), so the
/// auto-injection for zone blocks doesn't add a duplicate edge.
fn moduleImportsStdHeap(items: []const ast.Item) bool {
    for (items) |item| switch (item) {
        .import => |imp| if (imp.path.len == 2 and
            std.mem.eql(u8, imp.path[0], "std") and
            std.mem.eql(u8, imp.path[1], "heap")) return true,
        else => {},
    };
    return false;
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
    raw_module: ast.Module,
    source: []const u8,
    file: []const u8,
    arena: *std.heap.ArenaAllocator,
) CompileError!FrontEnd {
    // Phase 3 message loop: run `#compiler` hooks (compile-time functions that
    // return K2 source for top-level declarations) and add the generated
    // declarations to the module before the rest of the pipeline sees it.
    const base_module = if (ir_mod.hasCompilerHook(raw_module))
        try runCompilerHookPass(allocator, raw_module, source, file, arena)
    else
        raw_module;

    // Inject the compiler-provided `ast.*` metaprogramming types ONLY when the
    // module actually does metaprogramming (uses #quote/#insert/#for/macro), so
    // ordinary programs stay free of these types. Parsed with a high id base so
    // its node ids never collide with the program's; diagnostics keep the
    // user's source/file.
    const with_prelude = if (usesMetaprogramming(base_module))
        prependAstPrelude(allocator, base_module) catch |err| switch (err) {
            error.ParseFailed => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        }
    else
        base_module;

    // `type_info(T)` yields a matchable `TypeInfo` value; inject that reflection
    // surface when the module uses it (and doesn't already define `TypeInfo`).
    const with_reflect = if (moduleUsesReflection(with_prelude) and !moduleDefinesType(with_prelude, "TypeInfo"))
        prependReflectionPrelude(allocator, with_prelude) catch |err| switch (err) {
            error.ParseFailed => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        }
    else
        with_prelude;

    // A `zone X: Arena {}` handle is an ordinary `std.heap.Arena`, so any module
    // with a zone block depends on std.heap. Prepend the embedded bump-allocator
    // (and std.ptr, which it uses) so zones work in every compile path — even the
    // inline `compile(source)` path that never reads disk. Skipped when the
    // module already provides `Arena` (explicit `#import std.heap`).
    const with_heap = if (moduleUsesZone(with_reflect) and !moduleProvidesArena(with_reflect))
        prependHeapPrelude(allocator, with_reflect) catch |err| switch (err) {
            error.ParseFailed => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        }
    else
        with_reflect;

    // Expand macros before any sema sees the tree: `#insert macrocall(...)`
    // becomes a literal `#insert #quote { ... }`, and macro decls are dropped.
    const module = macroexpand.expand(allocator, with_heap) catch |err| switch (err) {
        error.SemanticFailed => return error.SemanticFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };

    // Two-pass `#insert`: a computed operand (`#insert #run gen()`) is run on
    // the VM using pass-1 results, reified into AST, and rewritten to a literal
    // `#quote { ... }`. The spliced module is then fully re-checked (pass 2) so
    // the generated code is type-checked exactly like hand-written code.
    //
    // Pass 1 must be TOLERANT: code after a computed insert may reference names
    // the generator declares, which pass 1 can't see yet. Pass 2 is strict.
    if (ir_mod.hasComputedInsert(module)) {
        const pass1 = try runSema(allocator, module, source, file, .tolerant);
        const fe1 = FrontEnd{ .module = module, .symbols = pass1.symbols, .types = pass1.types, .arena = arena };
        const spliced = ir_mod.expandComputedInserts(allocator, fe1) catch |err| switch (err) {
            error.SemanticFailed => return error.SemanticFailed,
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (spliced) |module2| {
            const pass2 = try runSema(allocator, module2, source, file, .strict);
            return .{ .module = module2, .symbols = pass2.symbols, .types = pass2.types, .arena = arena };
        }
    }

    const pass1 = try runSema(allocator, module, source, file, .strict);
    return .{ .module = module, .symbols = pass1.symbols, .types = pass1.types, .arena = arena };
}

/// Run the module's `#compiler` hooks and return the module augmented with the
/// declarations they generated. The hooks need a runnable program, so this does
/// a throwaway prelude+macroexpand+tolerant-sema to build a FrontEnd, runs the
/// hooks on the VM, parses their output as top-level declarations, and appends
/// them to the RAW module (so the real pipeline re-applies prelude/macroexpand
/// to the whole thing).
fn runCompilerHookPass(
    allocator: std.mem.Allocator,
    raw_module: ast.Module,
    source: []const u8,
    file: []const u8,
    arena: *std.heap.ArenaAllocator,
) CompileError!ast.Module {
    // The `Decl` type backing `compiler_decls()` must be visible both to the
    // throwaway run below AND to the real compile, so prepend it up front; the
    // returned module carries it forward.
    const with_cprelude = prependCompilerPrelude(allocator, raw_module) catch |err| switch (err) {
        error.ParseFailed => return error.ParseFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const pre = if (usesMetaprogramming(with_cprelude))
        prependAstPrelude(allocator, with_cprelude) catch |err| switch (err) {
            error.ParseFailed => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        }
    else
        with_cprelude;
    const expanded = macroexpand.expand(allocator, pre) catch |err| switch (err) {
        error.SemanticFailed => return error.SemanticFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const pass0 = try runSema(allocator, expanded, source, file, .tolerant);
    const fe0 = FrontEnd{ .module = expanded, .symbols = pass0.symbols, .types = pass0.types, .arena = arena };
    const gen_src = ir_mod.runCompilerHooks(allocator, fe0) catch |err| switch (err) {
        error.SemanticFailed => return error.SemanticFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (gen_src) |gsrc| {
        // Generated decls share the user's file_name so they live in the same
        // module scope; ids start high to avoid colliding with user nodes.
        const parsed = parser.parseSourceFrom(allocator, file, gsrc, 600_000) catch return error.ParseFailed;
        var items: std.ArrayList(ast.Item) = .empty;
        try items.appendSlice(allocator, with_cprelude.items);
        try items.appendSlice(allocator, parsed.module.items);
        return ast.Module{ .file_name = raw_module.file_name, .items = try items.toOwnedSlice(allocator) };
    }
    return with_cprelude;
}

/// Inject the `std.compiler` `Decl` type so `#compiler` hooks can call
/// `compiler_decls()`. Parsed under the user's file name (K2 symbols are
/// file-private — a separate name would hide `Decl` from the hook), with a
/// distinct high id base so its nodes never collide with the user's.
fn prependCompilerPrelude(allocator: std.mem.Allocator, user: ast.Module) !ast.Module {
    const parsed = try parser.parseSourceFrom(allocator, user.file_name, ast_prelude.compiler_source, 700_000);
    var items: std.ArrayList(ast.Item) = .empty;
    try items.appendSlice(allocator, parsed.module.items);
    try items.appendSlice(allocator, user.items);
    return .{ .file_name = user.file_name, .items = try items.toOwnedSlice(allocator) };
}

/// Prepend the embedded std.heap bump arena (and std.ptr, which it uses) to the
/// user's module so a `zone` block's `Arena` handle and allocator are in scope.
/// Parsed under the USER's file name (K2 symbols are file-private) with a high
/// id base; `ptr` is parsed first and `heap` chains off its next id. The
/// embedded `heap` imports `std.ptr` — stripped here, since ptr is inlined.
fn prependHeapPrelude(allocator: std.mem.Allocator, user: ast.Module) !ast.Module {
    const ptr_parsed = try parser.parseSourceFrom(allocator, user.file_name, std_prelude.ptr_src, heap_prelude_id_base);
    const heap_parsed = try parser.parseSourceFrom(allocator, user.file_name, std_prelude.heap_src, ptr_parsed.next_id);

    var items: std.ArrayList(ast.Item) = .empty;
    for (ptr_parsed.module.items) |item| switch (item) {
        .import => {},
        else => try items.append(allocator, item),
    };
    for (heap_parsed.module.items) |item| switch (item) {
        .import => {},
        else => try items.append(allocator, item),
    };
    try items.appendSlice(allocator, user.items);
    return .{ .file_name = user.file_name, .items = try items.toOwnedSlice(allocator) };
}

/// Prepend the `TypeInfo` reflection surface to the user's module. Parsed under
/// the user's file name (file-private symbols) with a high id base.
fn prependReflectionPrelude(allocator: std.mem.Allocator, user: ast.Module) !ast.Module {
    const parsed = try parser.parseSourceFrom(allocator, user.file_name, ast_prelude.reflection_source, reflection_prelude_id_base);
    var items: std.ArrayList(ast.Item) = .empty;
    try items.appendSlice(allocator, parsed.module.items);
    try items.appendSlice(allocator, user.items);
    return .{ .file_name = user.file_name, .items = try items.toOwnedSlice(allocator) };
}

/// True when the module declares a top-level type named `name`.
fn moduleDefinesType(module: ast.Module, name: []const u8) bool {
    for (module.items) |item| switch (item) {
        .type_decl => |d| if (std.mem.eql(u8, d.name, name)) return true,
        else => {},
    };
    return false;
}

/// True when any expression in the module calls a reflection builtin
/// (`type_info`/`type_name`), which need the `TypeInfo` surface in scope.
fn moduleUsesReflection(module: ast.Module) bool {
    for (module.items) |item| switch (item) {
        .function => |f| {
            if (f.body) |b| if (blockUsesReflection(b)) return true;
            if (f.where_clause) |w| if (blockUsesReflection(w)) return true;
        },
        .const_decl => |d| if (exprUsesReflection(d.value)) return true,
        .interface_impl => |impl| for (impl.methods) |m| {
            if (m.body) |b| if (blockUsesReflection(b)) return true;
        },
        else => {},
    };
    return false;
}

fn blockUsesReflection(block: ast.Block) bool {
    for (block.statements) |stmt| if (stmtUsesReflection(stmt)) return true;
    return false;
}

fn stmtUsesReflection(stmt: ast.Stmt) bool {
    return switch (stmt) {
        .comptime_run, .unsafe_block => |b| blockUsesReflection(b),
        .if_stmt => |s| blockUsesReflection(s.then_block) or
            (if (s.else_block) |e| blockUsesReflection(e) else false) or exprUsesReflection(s.condition),
        .while_stmt => |s| blockUsesReflection(s.body) or exprUsesReflection(s.condition),
        .for_range => |s| blockUsesReflection(s.body) or exprUsesReflection(s.start) or exprUsesReflection(s.end),
        .for_slice => |s| blockUsesReflection(s.body) or exprUsesReflection(s.iter),
        .zone_block => |s| blockUsesReflection(s.body),
        .defer_stmt => |s| blockUsesReflection(s.body),
        .comptime_if => |s| blockUsesReflection(s.then_block) or
            (if (s.else_block) |e| blockUsesReflection(e) else false),
        .match_stmt => |s| blk: {
            for (s.arms) |a| if (blockUsesReflection(a.body)) break :blk true;
            break :blk exprUsesReflection(s.subject);
        },
        .local_infer => |s| exprUsesReflection(s.value),
        .local_typed => |s| exprUsesReflection(s.value),
        .assign => |s| exprUsesReflection(s.target) or exprUsesReflection(s.value),
        .return_stmt => |s| if (s.value) |v| exprUsesReflection(v) else false,
        .expr => |e| exprUsesReflection(e),
        else => false,
    };
}

fn exprUsesReflection(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .call => |c| blk: {
            if (c.callee.kind == .ident) {
                const n = c.callee.kind.ident;
                if (std.mem.eql(u8, n, "type_info") or std.mem.eql(u8, n, "type_name")) break :blk true;
            }
            if (exprUsesReflection(c.callee.*)) break :blk true;
            for (c.args) |a| switch (a) {
                .positional => |x| if (exprUsesReflection(x)) break :blk true,
                .named => |nm| if (exprUsesReflection(nm.value)) break :blk true,
            };
            break :blk false;
        },
        .binary => |b| exprUsesReflection(b.left.*) or exprUsesReflection(b.right.*),
        .unary => |u| exprUsesReflection(u.expr.*),
        .field => |f| exprUsesReflection(f.base.*),
        .index => |i| exprUsesReflection(i.base.*) or exprUsesReflection(i.index.*),
        .force_unwrap, .unsafe_expr, .run_expr => |inner| exprUsesReflection(inner.*),
        .as_cast => |c| exprUsesReflection(c.value.*),
        .nil_coalesce => |nc| exprUsesReflection(nc.value.*) or exprUsesReflection(nc.default.*),
        else => false,
    };
}

/// True when the module already supplies `std.heap.Arena` — either an explicit
/// `#import std.heap` or a top-level `Arena` type declaration — so the heap
/// prelude isn't injected twice (which would duplicate every heap symbol).
fn moduleProvidesArena(module: ast.Module) bool {
    if (moduleImportsStdHeap(module.items)) return true;
    for (module.items) |item| switch (item) {
        .type_decl => |d| if (std.mem.eql(u8, d.name, "Arena")) return true,
        else => {},
    };
    return false;
}

/// True when any function/impl body in the module contains a `zone` block.
fn moduleUsesZone(module: ast.Module) bool {
    for (module.items) |item| switch (item) {
        .function => |f| if (f.body) |b| {
            if (blockUsesZone(b)) return true;
        },
        .interface_impl => |impl| for (impl.methods) |m| {
            if (m.body) |b| if (blockUsesZone(b)) return true;
        },
        else => {},
    };
    return false;
}

fn blockUsesZone(block: ast.Block) bool {
    for (block.statements) |stmt| if (stmtUsesZone(stmt)) return true;
    return false;
}

fn stmtUsesZone(stmt: ast.Stmt) bool {
    return switch (stmt) {
        .zone_block => true,
        .comptime_run, .unsafe_block => |b| blockUsesZone(b),
        .if_stmt => |s| blockUsesZone(s.then_block) or
            (if (s.else_block) |e| blockUsesZone(e) else false),
        .while_stmt => |s| blockUsesZone(s.body),
        .for_range => |s| blockUsesZone(s.body),
        .for_slice => |s| blockUsesZone(s.body),
        .defer_stmt => |s| blockUsesZone(s.body),
        .comptime_if => |s| blockUsesZone(s.then_block) or
            (if (s.else_block) |e| blockUsesZone(e) else false),
        .match_stmt => |s| blk: {
            for (s.arms) |a| if (blockUsesZone(a.body)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

const SemaResult = struct {
    symbols: sema.SymbolTable,
    types: sema.TypeEnv,
};

const SemaMode = enum { strict, tolerant };

fn runSema(
    allocator: std.mem.Allocator,
    module: ast.Module,
    source: []const u8,
    file: []const u8,
    mode: SemaMode,
) CompileError!SemaResult {
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

    const types = switch (mode) {
        .tolerant => sema.checkTypesTolerant(allocator, module, &symbols, source, file) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        },
        .strict => sema.checkTypesWithContext(allocator, module, &symbols, source, file) catch |err| switch (err) {
            error.SemanticFailed => return error.SemanticFailed,
            error.OutOfMemory => return error.OutOfMemory,
        },
    };

    return .{ .symbols = symbols, .types = types };
}

/// True if the module uses any metaprogramming construct that needs the `ast.*`
/// types in scope (`#quote`/`#insert`/`#for`/`macro`). Plain `#run`/`#if`
/// programs do NOT trigger injection, so they stay free of the ast.* types.
fn usesMetaprogramming(module: ast.Module) bool {
    for (module.items) |item| switch (item) {
        .function => |f| {
            if (f.is_macro) return true;
            if (f.body) |b| if (blockUsesMeta(b)) return true;
        },
        .interface_impl => |impl| for (impl.methods) |m| {
            if (m.body) |b| if (blockUsesMeta(b)) return true;
        },
        // Top-level `X :: #run ... #quote ...` constants also need the types.
        .const_decl => |d| if (exprUsesMeta(d.value)) return true,
        else => {},
    };
    return false;
}

fn blockUsesMeta(block: ast.Block) bool {
    for (block.statements) |stmt| if (stmtUsesMeta(stmt)) return true;
    return false;
}

fn stmtUsesMeta(stmt: ast.Stmt) bool {
    return switch (stmt) {
        .insert_stmt, .comptime_for => true,
        .comptime_run, .unsafe_block => |b| blockUsesMeta(b),
        .if_stmt => |s| blockUsesMeta(s.then_block) or
            (if (s.else_block) |e| blockUsesMeta(e) else false) or exprUsesMeta(s.condition),
        .while_stmt => |s| blockUsesMeta(s.body) or exprUsesMeta(s.condition),
        .for_range => |s| blockUsesMeta(s.body) or exprUsesMeta(s.start) or exprUsesMeta(s.end),
        .for_slice => |s| blockUsesMeta(s.body) or exprUsesMeta(s.iter),
        .zone_block => |s| blockUsesMeta(s.body),
        .defer_stmt => |s| blockUsesMeta(s.body),
        .comptime_if => |s| blockUsesMeta(s.then_block) or
            (if (s.else_block) |e| blockUsesMeta(e) else false),
        .match_stmt => |s| blk: {
            for (s.arms) |a| if (blockUsesMeta(a.body)) break :blk true;
            break :blk exprUsesMeta(s.subject);
        },
        .local_infer => |s| exprUsesMeta(s.value),
        .local_typed => |s| exprUsesMeta(s.value),
        .assign => |s| exprUsesMeta(s.target) or exprUsesMeta(s.value),
        .return_stmt => |s| if (s.value) |v| exprUsesMeta(v) else false,
        .expr => |e| exprUsesMeta(e),
        else => false,
    };
}

fn exprUsesMeta(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .quote, .quote_expr, .splice => true,
        .binary => |b| exprUsesMeta(b.left.*) or exprUsesMeta(b.right.*),
        .unary => |u| exprUsesMeta(u.expr.*),
        .call => |c| blk: {
            if (exprUsesMeta(c.callee.*)) break :blk true;
            for (c.args) |a| switch (a) {
                .positional => |x| if (exprUsesMeta(x)) break :blk true,
                .named => |n| if (exprUsesMeta(n.value)) break :blk true,
            };
            break :blk false;
        },
        .field => |f| exprUsesMeta(f.base.*),
        .index => |i| exprUsesMeta(i.base.*) or exprUsesMeta(i.index.*),
        .force_unwrap, .unsafe_expr, .run_expr => |inner| exprUsesMeta(inner.*),
        .as_cast => |c| exprUsesMeta(c.value.*),
        .nil_coalesce => |nc| exprUsesMeta(nc.value.*) or exprUsesMeta(nc.default.*),
        else => false,
    };
}

/// Parse the `ast.*` prelude and return a module with its items prepended to
/// the user's. The prelude is pure type declarations, so it carries no imports.
fn prependAstPrelude(allocator: std.mem.Allocator, user: ast.Module) !ast.Module {
    // Parse under the USER's file name so the prelude types share the user's
    // module — K2 symbols are file-private, so a separate file name would make
    // the ast.* types invisible to user code.
    const parsed = try parser.parseSourceFrom(allocator, user.file_name, ast_prelude.source, prelude_id_base);
    var items: std.ArrayList(ast.Item) = .empty;
    try items.appendSlice(allocator, parsed.module.items);
    try items.appendSlice(allocator, user.items);
    return .{ .file_name = user.file_name, .items = try items.toOwnedSlice(allocator) };
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
