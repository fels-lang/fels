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
const strlit = @import("strlit.zig");
const style = @import("style.zig");
const format_expand = @import("format_expand.zig");

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
const any_prelude_id_base: ast.NodeId = 400_000;
/// Node-id base for the injected `Format`/`Formatter` prelude.
const format_prelude_id_base: ast.NodeId = 4_000_000;
const fieldnav_prelude_id_base: ast.NodeId = 300_000;
/// Node-id base for the injected `Test` testing prelude (distinct range).
const testing_prelude_id_base: ast.NodeId = 200_000;
/// Node-id base for the injected `TARGET` prelude, far above any program's own ids.
const target_prelude_id_base: ast.NodeId = 3_000_000;

/// What the program is built for (`TARGET`, `core::os`, a top-level `#if`).
pub const build_target = @import("build_target.zig");
/// Node-id base for the generated test runner (`test_runner`).
const test_runner_id_base: ast.NodeId = 250_000;

pub const FrontEnd = struct {
    module: ast.Module,
    symbols: sema.SymbolTable,
    types: sema.TypeEnv,
    arena: *std.heap.ArenaAllocator,
    /// The files a compile from disk loaded: the root and everything it imports (`std` too).
    files: []const []const u8 = &.{},

    pub fn deinit(self: *FrontEnd, allocator: std.mem.Allocator) void {
        // The sources the messages were located in live in the arena.
        diag_mod.forgetSources();
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

/// Runtime override for the standard-library root (the directory containing
/// `std/`). `null` → use the build-baked `build_options.stdlib_root`. The CLI
/// resolves this from an installed/dev layout (`--std-path`, `$FELS_STD`,
/// `$FELS_HOME/lib`, or exe-relative) so one binary finds its stdlib wherever it
/// lands. Set once at startup; the compiler is single-threaded per build.
pub var stdlib_root_override: ?[]const u8 = null;

/// Fels source files end in `.fels`. Up to 0.4 the `.gab` extension (from when the language
/// was called Gabbro) was read too; now an import that only finds such a file says to rename it.
pub const source_ext = ".fels";
const old_ext = ".gab";

pub fn isSourceFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, source_ext);
}

/// `name` without its `.fels`.
pub fn withoutExt(name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, name, source_ext)) return name[0 .. name.len - source_ext.len];
    return name;
}

/// `path` (ending in `.fels`) with the old `.gab` extension: the file to name when it exists.
fn oldExtPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.mem.concat(allocator, u8, &.{ withoutExt(path), old_ext });
}

/// The error for an import that only finds a file with the old extension.
pub fn oldExtMessage(allocator: std.mem.Allocator, old: []const u8, new: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "found `{s}`, but Fels files end in `.fels` since 0.5.0; rename it to `{s}`", .{ old, std.fs.path.basename(new) });
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// A name an import can start with that stands for a folder: `#import name.a.b` reads
/// `<dir>/a/b.fels`, and a bare `#import name` reads `<dir>/<name>.fels`.
pub const ModuleRoot = struct {
    name: []const u8,
    dir: []const u8,
};

/// The named module roots of the current compile. `fels build` sets them per artifact
/// (`add_module`, and the generated `build_options`).
pub var module_roots: []const ModuleRoot = &.{};

/// Set by `fels test` for a native test program: `#test` functions get the `Test` of
/// `ast_prelude.runtime_testing_source`, and a generated `main` runs the root file's tests
/// one after the other. The root file's own `main` is left out and its `#entry` marks are
/// dropped, so the generated one is the program's entry.
pub var test_runner: bool = false;

/// Set by `fels test --filter`: the generated `main` of `test_runner` runs only the `#test`
/// functions whose name contains this text.
pub var test_filter: ?[]const u8 = null;

// Public entry points

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
    return compileWithRuntimeTarget(allocator, file_name, source, @import("builtin").os.tag, false);
}

/// Like `compileWithRuntime`, but for an explicit target OS (cross-compilation):
/// selects that platform's embedded runtime. `link_libc` picks the glibc entry
/// point on Linux (the `linux-gnu` ABI).
pub fn compileWithRuntimeTarget(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    source: []const u8,
    target_os: std.Target.Os.Tag,
    link_libc: bool,
) CompileError!FrontEnd {
    const rt_src = runtime.runtimeSourceFor(target_os, link_libc) orelse return error.RuntimeUnavailable;
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
    diag_mod.forgetSources();

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
        diag_mod.rememberSource(normalized_name, file.source);
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
                    const old = oldExtPath(fe_allocator, normalized) catch return error.OutOfMemory;
                    if (available.contains(old)) {
                        const msg = oldExtMessage(fe_allocator, old, normalized) catch return error.OutOfMemory;
                        std.debug.print("{s}: error: {s}\n", .{ imp.file_name, msg });
                        return error.IoError;
                    }
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
    // The root file (whose name/source drive sema visibility and prelude
    // injection) is the user's, not the embedded runtime prepended ahead of it.
    var root: usize = 0;
    if (std.mem.eql(u8, modules.items[0].file_name, "<runtime>") and modules.items.len > 1) root = 1;
    return runPipelineWithSource(fe_allocator, .{ .file_name = modules.items[root].file_name, .items = items }, files[root].source, modules.items[root].file_name, arena);
}

/// Compile a .fels file from disk, resolving `#import` declarations recursively.
/// Requires an `std.Io` instance (Zig 0.16 explicit I/O).
pub fn compileFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) CompileError!FrontEnd {
    return compileFileInternal(allocator, io, path, false, @import("builtin").os.tag, false);
}

/// Compile a .fels file and its imports with the embedded platform runtime.
pub fn compileFileWithRuntime(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) CompileError!FrontEnd {
    return compileFileWithRuntimeTarget(allocator, io, path, @import("builtin").os.tag, false);
}

/// Like `compileFileWithRuntime`, but for an explicit target OS.
pub fn compileFileWithRuntimeTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    target_os: std.Target.Os.Tag,
    link_libc: bool,
) CompileError!FrontEnd {
    return compileFileInternal(allocator, io, path, true, target_os, link_libc);
}

fn compileFileInternal(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    include_runtime: bool,
    target_os: std.Target.Os.Tag,
    link_libc: bool,
) CompileError!FrontEnd {
    const arena = try createFrontendArena(allocator);
    errdefer destroyFrontendArena(allocator, arena);
    const fe_allocator = arena.allocator();
    diag_mod.forgetSources();

    var loaded = std.StringHashMap(void).init(fe_allocator);
    defer loaded.deinit();

    var all_items: std.ArrayList(ast.Item) = .empty;
    errdefer all_items.deinit(fe_allocator);

    var root_source: []const u8 = "";
    var next_id: ast.NodeId = 1;

    if (include_runtime) {
        const rt_src = runtime.runtimeSourceFor(target_os, link_libc) orelse return error.RuntimeUnavailable;
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

    var ctx = LoadCtx{
        .allocator = fe_allocator,
        .io = io,
        .loaded = &loaded,
        .all_items = &all_items,
        .next_id = &next_id,
        .root_source = &root_source,
        .stdlib_root = stdlib_root_override orelse build_options.stdlib_root,
        .root_dir = std.fs.path.dirname(absolute(io, fe_allocator, path) catch path),
    };
    loadFile(&ctx, path, true, false) catch |err| switch (err) {
        error.ParseFailed => return error.ParseFailed,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.IoError,
    };

    const items = try all_items.toOwnedSlice(fe_allocator);
    var files: std.ArrayList([]const u8) = .empty;
    var it = loaded.keyIterator();
    while (it.next()) |k| try files.append(fe_allocator, k.*);
    var fe = try runPipelineWithSource(fe_allocator, .{ .file_name = path, .items = items }, root_source, path, arena);
    fe.files = files.items;
    return fe;
}

// Internal helpers

/// Where `loadFile` gets source text from. The compiler reads the disk; the
/// language server answers from its open documents first.
pub const SourceReader = struct {
    ctx: ?*anyopaque = null,
    /// The text of `path`, allocated on `allocator`, or null if it cannot be read.
    readFn: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8) ?[]const u8,
    existsFn: *const fn (ctx: ?*anyopaque, path: []const u8) bool,
};

/// State of a tolerant analysis (the language server): a broken file is
/// recorded as diagnostics instead of aborting the load.
const AnalysisState = struct {
    reader: SourceReader,
    project_root: ?[]const u8,
    missing_packages: []const []const u8 = &.{},
    files: std.ArrayList(AnalysisFile) = .empty,
    diags: std.ArrayList(Diagnostic) = .empty,
};

const LoadCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    loaded: *std.StringHashMap(void),
    all_items: *std.ArrayList(ast.Item),
    next_id: *ast.NodeId,
    root_source: *[]const u8,
    stdlib_root: ?[]const u8,
    /// Null for the compiler (strict: print and fail); set by `analyzeFile`.
    analysis: ?*AnalysisState = null,
    /// The folder of the file compiled, for an `#embed` when no project set `ir.project_root`.
    root_dir: ?[]const u8 = null,
};

/// Read the file of each `#embed("…")` in the `items` of the file at `path`, below that file's
/// folder, if the code there may read it (`ir.capsForFile`): the project's own code reads
/// below the project's folder, a package's what fels.pkg grants it.
fn readEmbeds(ctx: *LoadCtx, path: []const u8, source: []const u8, items: []const ast.Item) anyerror!void {
    const Reader = struct {
        ctx: *LoadCtx,
        file: []const u8,
        source: []const u8,
        failed: bool = false,

        fn visit(r: *@This(), ptr: anytype) anyerror!void {
            const T = @typeInfo(@TypeOf(ptr)).pointer.child;
            const node: *T = @constCast(ptr);
            if (T == ast.Expr) {
                if (node.kind == .embed) return r.read(&node.kind.embed, node.span);
            }
            switch (@typeInfo(T)) {
                .@"struct" => |info| inline for (info.fields) |field| try r.visit(&@field(node.*, field.name)),
                .@"union" => |info| {
                    if (info.tag_type == null) return;
                    switch (node.*) {
                        inline else => |*payload| try r.visit(payload),
                    }
                },
                .pointer => |info| switch (info.size) {
                    .one => try r.visit(node.*),
                    .slice => {
                        if (info.child == u8) return;
                        for (node.*) |*element| try r.visit(element);
                    },
                    else => {},
                },
                .optional => if (node.*) |*inner| try r.visit(inner),
                else => {},
            }
        }

        fn read(r: *@This(), e: *ast.EmbedExpr, span: Span) anyerror!void {
            // The language server reads no files: an `#embed` is empty to it.
            if (r.ctx.analysis != null) {
                e.bytes = "";
                return;
            }
            const a = r.ctx.allocator;
            const rel = strlit.bytes(a, e.path);
            const file_abs = try absolute(r.ctx.io, a, r.file);
            const target = try std.fs.path.resolve(a, &.{ std.fs.path.dirname(file_abs) orelse ".", rel });
            // The package a file is in is found as the VM finds it, by the path as given; the
            // read is checked with both absolute.
            const caps = ir_mod.capsForFileUnder(r.file, r.ctx.root_dir);
            if (!caps.allowsRead(target)) {
                const why = switch (caps.read) {
                    .none => "this code may read no files: a package's compile-time code reads what fels.pkg grants it (`may read(\"…\")` on its `#use` line)",
                    else => "it is outside the folders this code may read: the project's own code reads the files below the project's folder, a package's what fels.pkg grants it",
                };
                r.report(span, "`#embed({s})` reads `{s}`, but {s}", .{ e.path, target, why });
                return;
            }
            e.bytes = std.Io.Dir.cwd().readFileAlloc(r.ctx.io, target, a, .unlimited) catch |err| {
                r.report(span, "`#embed({s})`: cannot read `{s}`: {s}", .{ e.path, target, @errorName(err) });
                return;
            };
            // A file the compile read, as its sources are: a change to it builds again.
            try r.ctx.loaded.put(target, {});
        }

        fn report(r: *@This(), span: Span, comptime fmt: []const u8, args: anytype) void {
            r.failed = true;
            const msg = std.fmt.allocPrint(r.ctx.allocator, fmt, args) catch "`#embed` failed";
            const d = Diagnostic.err(msg, span, r.file);
            if (r.ctx.analysis) |an| {
                an.diags.append(r.ctx.allocator, d) catch {};
                return;
            }
            diag_mod.printErrorAt(msg, r.file, r.source, span);
        }
    };
    var reader: Reader = .{ .ctx = ctx, .file = path, .source = source };
    for (items) |*item| try reader.visit(item);
    if (reader.failed and ctx.analysis == null) return error.SemanticFailed;
}

/// `path` as an absolute path: joined to the current folder when it is relative.
fn absolute(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(a, &.{path});
    const cwd = try std.process.currentPathAlloc(io, a);
    return std.fs.path.resolve(a, &.{ cwd, path });
}

fn loadFile(ctx: *LoadCtx, path: []const u8, is_root: bool, is_std: bool) anyerror!void {
    if (ctx.loaded.contains(path)) return;
    try ctx.loaded.put(path, {});
    const allocator = ctx.allocator;

    var items: []const ast.Item = &.{};
    if (ctx.analysis) |an| {
        const source = an.reader.readFn(an.reader.ctx, allocator, path) orelse return error.FileNotFound;
        if (is_root) ctx.root_source.* = source;
        try an.files.append(allocator, .{ .path = path, .source = source, .is_std = is_std });
        var p = try parser.Parser.init(allocator, path, source, ctx.next_id.*);
        defer p.deinit();
        var ok = false;
        if (p.parseModule()) |module| {
            if (p.diagnostics.items.len == 0) {
                ctx.next_id.* = p.next_id;
                items = module.items;
                ok = true;
            } else {
                try an.diags.appendSlice(allocator, p.diagnostics.items);
            }
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseFailed => try an.diags.appendSlice(allocator, p.diagnostics.items),
        }
        an.files.items[an.files.items.len - 1].parsed = ok;
    } else {
        const source = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, allocator, .unlimited) catch |err| {
            std.debug.print("{s}: error: cannot read imported module: {s}\n", .{ path, @errorName(err) });
            // A missing `std/...` module almost always means the compiler can't find
            // its standard library — point the user at the relocation knobs.
            if (std.mem.indexOf(u8, path, "std") != null) {
                std.debug.print("  hint: the fels standard library wasn't found at this path. " ++
                    "Set FELS_HOME to your fels install dir, or pass --std-path <dir-containing-std>.\n", .{});
            }
            return err;
        };
        if (is_root) ctx.root_source.* = source;
        diag_mod.rememberSource(path, source);
        const parsed = try parser.parseSourceFrom(allocator, path, source, ctx.next_id.*);
        ctx.next_id.* = parsed.next_id;
        items = parsed.module.items;
    }
    try readEmbeds(ctx, path, diag_mod.sourceOf(path, ""), items);

    // Retain the import edge for visibility checking, then load the dependency.
    const dir = std.fs.path.dirname(path) orelse ".";
    for (items) |item| {
        switch (item) {
            .import => |imp| {
                var resolved_import = imp;
                if (ctx.analysis) |an| {
                    const found = try findImport(ctx, an, dir, imp);
                    resolved_import.resolved_file = found;
                    try ctx.all_items.append(allocator, .{ .import = resolved_import });
                    if (found) |f| try loadFile(ctx, f, false, imp.path.len > 0 and std.mem.eql(u8, imp.path[0], "std"));
                } else {
                    const resolved = try resolveImportPath(allocator, dir, imp.path, ctx.stdlib_root);
                    if (!fileExists(ctx.io, resolved)) {
                        const old = try oldExtPath(allocator, resolved);
                        if (fileExists(ctx.io, old)) {
                            std.debug.print("{s}: error: {s}\n", .{ imp.file_name, try oldExtMessage(allocator, old, resolved) });
                            return error.FileNotFound;
                        }
                    }
                    resolved_import.resolved_file = resolved;
                    try ctx.all_items.append(allocator, .{ .import = resolved_import });
                    try loadFile(ctx, resolved, false, false);
                }
            },
            else => try ctx.all_items.append(allocator, item),
        }
    }
}

/// Resolve an import for the analysis: next to the importing file first (what the
/// compiler does), then, for a non-`std` module, under the project root. A module that
/// cannot be found is reported on the import and leaves it unresolved.
fn findImport(ctx: *LoadCtx, an: *AnalysisState, dir: []const u8, imp: ast.ImportDecl) error{OutOfMemory}!?[]const u8 {
    const allocator = ctx.allocator;
    const primary = try resolveImportPath(allocator, dir, imp.path, ctx.stdlib_root);
    if (an.reader.existsFn(an.reader.ctx, primary)) return primary;
    const is_std = imp.path.len > 0 and std.mem.eql(u8, imp.path[0], "std");
    if (!is_std) if (an.project_root) |root| {
        const alt = try resolveImportPath(allocator, root, imp.path, null);
        if (an.reader.existsFn(an.reader.ctx, alt)) return alt;
    };
    const primary_old = try oldExtPath(allocator, primary);
    if (an.reader.existsFn(an.reader.ctx, primary_old)) {
        try an.diags.append(allocator, Diagnostic.err(try oldExtMessage(allocator, primary_old, primary), imp.span, imp.file_name));
        return null;
    }
    const name = try std.mem.join(allocator, ".", imp.path);
    for (an.missing_packages) |pkg| if (imp.path.len > 0 and std.mem.eql(u8, imp.path[0], pkg)) {
        try an.diags.append(allocator, Diagnostic.err(
            try std.fmt.allocPrint(allocator, "the package `{s}` is in fels.pkg but not fetched yet; run `fels fetch`", .{pkg}),
            imp.span,
            imp.file_name,
        ));
        return null;
    };
    try an.diags.append(allocator, Diagnostic.err(
        try std.fmt.allocPrint(allocator, "cannot find module `{s}` (looked for {s})", .{ name, primary }),
        imp.span,
        imp.file_name,
    ));
    return null;
}

/// A source file the analysis loaded.
pub const AnalysisFile = struct {
    /// The name the parser and the diagnostics know the file by.
    path: []const u8,
    source: []const u8,
    /// True for the standard library (`#import std...`).
    is_std: bool,
    /// False if the file did not parse (its items are missing from the analysis).
    parsed: bool = true,
};

pub const AnalysisOptions = struct {
    reader: SourceReader,
    /// The directory that holds `std/`; null means the compiler's own setting.
    std_root: ?[]const u8 = null,
    /// Where a non-`std` import is looked for when it is not next to the importer.
    project_root: ?[]const u8 = null,
    /// Prepend the embedded runtime, as `fels check` does.
    include_runtime: bool = true,
    /// Named import roots: the packages of the project's fels.pkg.
    module_roots: []const ModuleRoot = &.{},
    /// Packages fels.pkg uses that are not fetched yet; an import of one says so.
    missing_packages: []const []const u8 = &.{},
};

/// The result of `analyzeFile`: the tolerant front end over a file and everything it
/// imports. Every allocation lives in `arena`.
pub const Analysis = struct {
    arena: *std.heap.ArenaAllocator,
    parent: std.mem.Allocator,
    module: ast.Module,
    /// Null if the root file did not parse.
    symbols: ?sema.SymbolTable,
    /// What the type check recorded (resolved names, expression types, partial where
    /// checking failed) with the names declared inside function bodies; null when
    /// `symbols` is.
    types: ?sema.TypeEnv = null,
    /// Parse, symbol and type diagnostics of all loaded files; `file` tells which.
    diagnostics: []const Diagnostic,
    files: []const AnalysisFile,
    /// The module as loaded, before `#compiler` hooks and macro expansion: the macros are
    /// still in it.
    loaded: ast.Module = .{ .file_name = "", .items = &.{} },

    pub fn deinit(self: *Analysis) void {
        self.arena.deinit();
        self.parent.destroy(self.arena);
    }

    pub fn fileNamed(self: *const Analysis, path: []const u8) ?AnalysisFile {
        for (self.files) |f| if (std.mem.eql(u8, f.path, path)) return f;
        return null;
    }
};

/// Analyze `root_path` and the modules it imports without compiling: the loading and
/// the checks of `fels check`, but tolerant. A file that does not parse, an import
/// that cannot be found or a name that does not exist become diagnostics, never an
/// error, and the symbols and partial types of what did check are still returned.
/// Nothing is printed. Only running out of memory fails.
pub fn analyzeFile(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    options: AnalysisOptions,
) error{OutOfMemory}!Analysis {
    const arena = createFrontendArena(allocator) catch return error.OutOfMemory;
    errdefer destroyFrontendArena(allocator, arena);
    const a = arena.allocator();

    var state = AnalysisState{ .reader = options.reader, .project_root = options.project_root, .missing_packages = options.missing_packages };
    const saved_roots = module_roots;
    module_roots = options.module_roots;
    defer module_roots = saved_roots;
    var loaded = std.StringHashMap(void).init(a);
    var all_items: std.ArrayList(ast.Item) = .empty;
    var root_source: []const u8 = "";
    var next_id: ast.NodeId = 1;

    if (options.include_runtime) {
        if (runtime.runtimeSourceFor(@import("builtin").os.tag, false)) |rt_src| {
            var p = try parser.Parser.init(a, "<runtime>", rt_src, next_id);
            if (p.parseModule()) |module| {
                next_id = p.next_id;
                for (module.items) |item| switch (item) {
                    .import => {},
                    else => try all_items.append(a, item),
                };
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ParseFailed => {},
            }
        }
    }

    var ctx = LoadCtx{
        .allocator = a,
        .io = undefined,
        .loaded = &loaded,
        .all_items = &all_items,
        .next_id = &next_id,
        .root_source = &root_source,
        .stdlib_root = options.std_root orelse stdlib_root_override orelse build_options.stdlib_root,
        .analysis = &state,
    };
    loadFile(&ctx, root_path, true, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try state.diags.append(a, Diagnostic.err("cannot read this file", Span.new(0, 0), root_path));
        },
    };

    const raw: ast.Module = .{ .file_name = root_path, .items = try all_items.toOwnedSlice(a) };
    const root_parsed = state.files.items.len == 0 or state.files.items[0].parsed;
    var result = Analysis{
        .arena = arena,
        .parent = allocator,
        .module = raw,
        .symbols = null,
        .diagnostics = &.{},
        .files = state.files.items,
        .loaded = raw,
    };
    if (!root_parsed) {
        result.diagnostics = state.diags.items;
        return result;
    }

    // Hooks, preludes and macros as in the compiler. If one of them fails (it printed
    // its reason), check the module as loaded rather than nothing.
    var module = preparePipeline(a, raw, root_source, root_path, arena) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            try state.diags.append(a, Diagnostic.warn("compile-time expansion failed, so this analysis is partial", Span.new(0, 0), root_path));
            break :blk raw;
        },
    };
    if (ir_mod.hasComputedInsert(module)) splice: {
        var sink: std.ArrayList(Diagnostic) = .empty;
        var symbols1 = sema.collectSymbolsInto(a, module, &sink) catch break :splice;
        const types1 = try sema.checkTypesTolerant(a, module, &symbols1, root_source, root_path);
        const fe1 = FrontEnd{ .module = module, .symbols = symbols1, .types = types1, .arena = arena };
        const spliced = ir_mod.expandComputedInserts(a, fe1) catch break :splice;
        if (spliced) |m2| module = m2;
    }

    var sink: std.ArrayList(Diagnostic) = .empty;
    var symbols = sema.collectSymbolsInto(a, module, &sink) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SemanticFailed => {
            try state.diags.appendSlice(a, sink.items);
            result.diagnostics = state.diags.items;
            return result;
        },
    };
    const types = try sema.checkTypesForAnalysis(a, module, &symbols, root_source, root_path);
    try state.diags.appendSlice(a, sink.items);
    try state.diags.appendSlice(a, types.diagnostics.items);

    result.module = module;
    result.symbols = symbols;
    result.types = types;
    result.diagnostics = state.diags.items;
    return result;
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

/// Turn an import path like ["utils", "math"] into "utils/math.fels"
/// relative to `base_dir`.
fn resolveImportPath(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    parts: []const []const u8,
    stdlib_root: ?[]const u8,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    if (parts.len > 0) for (module_roots) |m| {
        if (!std.mem.eql(u8, parts[0], m.name)) continue;
        try buf.appendSlice(allocator, m.dir);
        const rest = if (parts.len == 1) parts else parts[1..];
        for (rest) |part| {
            try buf.append(allocator, std.fs.path.sep);
            try buf.appendSlice(allocator, part);
        }
        try buf.appendSlice(allocator, source_ext);
        return buf.toOwnedSlice(allocator);
    };

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
    try buf.appendSlice(allocator, source_ext);
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

/// Everything that happens to the loaded module before the final checks: the
/// `#compiler` hooks, the injected preludes and macro expansion. Shared by the
/// compiler and by the language server's analysis.
fn preparePipeline(
    allocator: std.mem.Allocator,
    raw_module: ast.Module,
    source: []const u8,
    file: []const u8,
    arena: *std.heap.ArenaAllocator,
) CompileError!ast.Module {
    // Phase 3 message loop: run `#compiler` hooks (compile-time functions that
    // return Fels source for top-level declarations) and add the generated
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
    // `TARGET`, the platform the program is built for, is an ordinary constant of the
    // types `TargetInfo`, `TargetOs` and `TargetArch`, declared for this build when the program
    // names it.
    const with_target = if (mentionsTarget(base_module, source) and !moduleDefinesConst(base_module, "TARGET"))
        prependTargetPrelude(allocator, base_module) catch |err| switch (err) {
            error.ParseFailed => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        }
    else
        base_module;

    const with_prelude = if (usesMetaprogramming(with_target))
        prependAstPrelude(allocator, with_target) catch |err| switch (err) {
            error.ParseFailed => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        }
    else
        with_target;

    const with_nav = try prependValuePreludes(allocator, with_prelude);

    // A `zone X: Arena {}` handle is an ordinary `std.heap.Arena`, so any module
    // with a zone block depends on std.heap. Prepend the embedded bump-allocator
    // (and std.ptr, which it uses) so zones work in every compile path — even the
    // inline `compile(source)` path that never reads disk. Skipped when the
    // module already provides `Arena` (explicit `#import std.heap`).
    const with_heap = if (!moduleUsesZone(with_nav))
        with_nav
    else if (!moduleProvidesArena(with_nav))
        prependHeapPrelude(allocator, with_nav) catch |err| switch (err) {
            error.ParseFailed => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        }
    else
        try addLoadedZoneImports(allocator, with_nav);

    // `#test` functions take a `*Test` context; inject the `Test` type (and its
    // assertion methods) when the module declares any test, so tests compile with
    // no import. The tests themselves run in the driver (comptime lane), not here.
    const adds_testing = ir_mod.hasTestDecl(with_heap) and !moduleDefinesType(with_heap, "Test");
    const with_testing = if (adds_testing)
        prependTestingPrelude(allocator, with_heap) catch |err| switch (err) {
            error.ParseFailed => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        }
    else
        with_heap;

    // The runner calls the helpers of that prelude, so it needs it: a file without tests
    // compiles as it is.
    const with_runner = if (test_runner and adds_testing)
        addTestRunner(allocator, with_testing) catch |err| switch (err) {
            error.ParseFailed => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        }
    else
        with_testing;

    // Expand macros before any sema sees the tree: `#insert macrocall(...)`
    // becomes a literal `#insert #quote { ... }`, and macro decls are dropped.
    const module = macroexpand.expand(allocator, with_runner) catch |err| switch (err) {
        error.SemanticFailed => return error.SemanticFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return module;
}

fn runPipelineWithSource(
    allocator: std.mem.Allocator,
    raw_module: ast.Module,
    source: []const u8,
    file: []const u8,
    arena: *std.heap.ArenaAllocator,
) CompileError!FrontEnd {
    const module = try preparePipeline(allocator, raw_module, source, file, arena);

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
            return strictPass(allocator, module2, source, file, arena);
        }
    }

    return strictPass(allocator, module, source, file, arena);
}

/// The final strict sema pass. If the module has `where` clauses, run it as a
/// two-pass resolution: a tolerant pre-pass builds a resolution `ComptimeVm`,
/// then the strict pass runs each generic instantiation's `where` predicate on
/// that VM *during* resolution (rejections become resolution errors, before the
/// body is checked). Otherwise it's a single strict pass.
///
/// An array length that names a constant only the comptime VM can compute
/// (`N :: #run four();`, `N :: four();`) is 0 to that pass, which notes the
/// constant (`TypeEnv.unresolved_len_consts`). Then the VM, built from that pass,
/// computes the constants, and the strict pass runs again with their values.
fn strictPass(
    allocator: std.mem.Allocator,
    given: ast.Module,
    source: []const u8,
    file: []const u8,
    arena: *std.heap.ArenaAllocator,
) CompileError!FrontEnd {
    const module = try expandFormats(allocator, given, source, file);
    var where_cvm: ?ir_mod.ComptimeVm = null;
    defer if (where_cvm) |*c| c.deinit();
    if (hasWhereClause(module)) {
        const pre = try runSema(allocator, module, source, file, .tolerant);
        const fe1 = FrontEnd{ .module = module, .symbols = pre.symbols, .types = pre.types, .arena = arena };
        where_cvm = ir_mod.ComptimeVm.init(allocator, fe1);
        where_cvm.?.current_file = file;
    }
    const where_ctx: ?*ir_mod.ComptimeVm = if (where_cvm) |*c| c else null;
    var pass = try strictSema(allocator, module, source, file, where_ctx, null);
    if (pass.types.unresolved_len_consts.count() != 0) {
        const fe1 = FrontEnd{ .module = module, .symbols = pass.symbols, .types = pass.types, .arena = arena };
        var cvm = ir_mod.ComptimeVm.init(allocator, fe1);
        cvm.current_file = file;
        defer cvm.deinit();
        var len_consts = std.AutoHashMap(sema.SymbolId, u64).init(allocator);
        defer len_consts.deinit();
        try evalArrayLenConsts(module, pass.types, pass.symbols, &cvm, &len_consts);
        pass = try strictSema(allocator, module, source, file, where_ctx, &len_consts);
    }
    const fe: FrontEnd = .{ .module = module, .symbols = pass.symbols, .types = pass.types, .arena = arena };
    try reportStaticDataErrors(allocator, fe);
    return fe;
}

/// The string literals passed to a `Format` parameter made the code of their format
/// (`format_expand`). Which literals those are takes the types, so a tolerant pass notes them
/// first; it runs only when some call passes a literal with a brace in it.
fn expandFormats(
    allocator: std.mem.Allocator,
    module: ast.Module,
    source: []const u8,
    file: []const u8,
) CompileError!ast.Module {
    if (!format_expand.hasCandidates(module)) return module;
    const pass = runSema(allocator, module, source, file, .formats) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The strict pass reports what is wrong.
        else => return module,
    };
    if (pass.types.format_literals.count() == 0) return module;
    return format_expand.rewrite(allocator, module, &pass.types.format_literals) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Reported => return error.SemanticFailed,
    };
}

/// One strict sema pass, with the `where` evaluator when there is one.
fn strictSema(
    allocator: std.mem.Allocator,
    module: ast.Module,
    source: []const u8,
    file: []const u8,
    where_cvm: ?*ir_mod.ComptimeVm,
    len_consts: ?*const std.AutoHashMap(sema.SymbolId, u64),
) CompileError!SemaResult {
    return runSemaResolved(
        allocator,
        module,
        source,
        file,
        .strict,
        if (where_cvm) |c| c else null,
        if (where_cvm != null) whereEvalThunk else null,
        if (where_cvm != null) whereTypeEvalThunk else null,
        len_consts,
    );
}

/// The type check of the program's static data (typed globals) belongs with the other checks, so
/// `fels check` and every build stop on a mistake in one before any code is generated. Only what
/// needs no evaluator is checked here; lowering checks the rest with the comptime VM available.
fn reportStaticDataErrors(allocator: std.mem.Allocator, fe: FrontEnd) CompileError!void {
    const found = ir_mod.checkStaticData(allocator, fe) catch return error.OutOfMemory;
    if (found.len == 0) return;
    const pal = style.forStderr();
    for (found) |f| {
        const rendered = diag_mod.render(allocator, f.diag.file, f.source, f.diag, pal) catch continue;
        defer allocator.free(rendered);
        std.debug.print("{s}\n", .{rendered});
    }
    return error.SemanticFailed;
}

/// Adapts `ComptimeVm.evalWhere` to sema's opaque `WhereEvalFn` callback.
fn whereEvalThunk(
    ctx: *anyopaque,
    eval_file: []const u8,
    wc: ast.Block,
    type_args: []const sema.TypeArg,
    output_params: []const []const u8,
    expr_types: std.AutoHashMap(ast.NodeId, sema.Ty),
    out_alloc: std.mem.Allocator,
) ?[]const u8 {
    const cvm: *ir_mod.ComptimeVm = @ptrCast(@alignCast(ctx));
    cvm.current_file = eval_file;
    return cvm.evalWhere(wc, type_args, output_params, expr_types, out_alloc);
}

/// Adapts `ComptimeVm.evalWhereType` to sema's `WhereTypeEvalFn` callback.
fn whereTypeEvalThunk(
    ctx: *anyopaque,
    eval_file: []const u8,
    wc: ast.Block,
    type_args: []const sema.TypeArg,
    output_params: []const []const u8,
    expr_types: std.AutoHashMap(ast.NodeId, sema.Ty),
) ?u64 {
    const cvm: *ir_mod.ComptimeVm = @ptrCast(@alignCast(ctx));
    cvm.current_file = eval_file;
    return cvm.evalWhereType(wc, type_args, output_params, expr_types);
}

/// Evaluate on the comptime VM each constant a sema pass found in an array length
/// without a value (`TypeEnv.unresolved_len_consts`), so the next pass sizes `[N]i32`
/// with it instead of 0 (an empty array that panicked on the first index). A constant
/// that does not evaluate to a length is an error at its declaration. The values are
/// kept by the constants' symbols, which the next pass over the module collects alike.
fn evalArrayLenConsts(
    module: ast.Module,
    types: sema.TypeEnv,
    symbols: sema.SymbolTable,
    cvm: *ir_mod.ComptimeVm,
    out: *std.AutoHashMap(sema.SymbolId, u64),
) CompileError!void {
    for (types.unresolved_len_consts.keys()) |id| {
        const sym = symbols.symbol(id);
        const decl = for (module.items) |item| switch (item) {
            .const_decl => |d| if (!d.is_mutable and std.mem.eql(u8, d.name, sym.name) and
                std.mem.eql(u8, d.file_name, sym.file_name)) break d,
            else => {},
        } else continue;
        const value = cvm.evalConstInt(decl.value, decl.file_name) orelse {
            diag_mod.printErrorAt("this constant is the length of an array, but the compile-time evaluator could not compute it as an integer", decl.file_name, decl.source, decl.value.span);
            return error.SemanticFailed;
        };
        const len = std.math.cast(u64, value) orelse {
            diag_mod.printErrorAt("this constant is the length of an array, but its value is negative", decl.file_name, decl.source, decl.value.span);
            return error.SemanticFailed;
        };
        try out.put(id, len);
    }
}

/// True if the module needs the resolution VM: any function with a `where { … }`
/// clause, or any `constraint Name($T) { … }` declaration (used at `$T: Name`).
fn hasWhereClause(module: ast.Module) bool {
    for (module.items) |item| switch (item) {
        .function => |f| if (f.where_clause != null or f.is_constraint) return true,
        else => {},
    };
    return false;
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
    const with_ast = if (usesMetaprogramming(with_cprelude))
        prependAstPrelude(allocator, with_cprelude) catch |err| switch (err) {
            error.ParseFailed => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        }
    else
        with_cprelude;
    // The run of the hooks compiles std as the final compile does, with the types std uses.
    const pre = try prependValuePreludes(allocator, with_ast);
    const expanded = macroexpand.expand(allocator, pre) catch |err| switch (err) {
        error.SemanticFailed => return error.SemanticFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const pass0 = try runSema(allocator, expanded, source, file, .tolerant);
    const fe0 = FrontEnd{ .module = expanded, .symbols = pass0.symbols, .types = pass0.types, .arena = arena };

    // Phase 1 — GENERATE: bare `#compiler` hooks introspect the program and
    // emit/mutate declarations.
    const out1 = ir_mod.runCompilerHooks(allocator, fe0, false) catch |err| switch (err) {
        error.SemanticFailed => return error.SemanticFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const m1 = try applyHookOutput(allocator, with_cprelude, out1, file);

    // Phase 2 — FINAL: `#compiler(final)` hooks run over the AUGMENTED program
    // (they see everything phase 1 generated) and can validate the whole program
    // (`compiler_error`) or mutate a second time. Skipped when there are none.
    if (!ir_mod.hasFinalHook(m1)) return m1;
    const exp1 = macroexpand.expand(allocator, m1) catch |err| switch (err) {
        error.SemanticFailed => return error.SemanticFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const pass1 = try runSema(allocator, exp1, source, file, .tolerant);
    const fe1 = FrontEnd{ .module = exp1, .symbols = pass1.symbols, .types = pass1.types, .arena = arena };
    const out2 = ir_mod.runCompilerHooks(allocator, fe1, true) catch |err| switch (err) {
        error.SemanticFailed => return error.SemanticFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return applyHookOutput(allocator, m1, out2, file);
}

/// Splice a hook pass's output into `base`: parse the generated source, then
/// build the new item list. A generated decl REPLACES an existing one of the
/// same name (rewrite, not just add); `compiler_remove(name)` drops a decl
/// outright. Prelude decls (`Decl`, `CodeBuf`, …) are never touched. Returns
/// `base` unchanged when the hooks produced nothing.
fn applyHookOutput(
    allocator: std.mem.Allocator,
    base: ast.Module,
    hook_out: ir_mod.HookOutput,
    file: []const u8,
) CompileError!ast.Module {
    // Generated decls share the user's file_name so they live in the same module
    // scope; ids start high to avoid colliding with user nodes.
    const gen_items: []const ast.Item = if (hook_out.source) |gsrc|
        (parser.parseSourceFrom(allocator, file, gsrc, 600_000) catch return error.ParseFailed).module.items
    else
        &.{};

    if (gen_items.len == 0 and hook_out.removed.len == 0) return base;

    var drop = std.StringHashMap(void).init(allocator);
    defer drop.deinit();
    for (gen_items) |gi| if (gi.name()) |gn| try drop.put(gn, {});
    for (hook_out.removed) |rn| try drop.put(rn, {});

    var items: std.ArrayList(ast.Item) = .empty;
    for (base.items) |it| {
        if (it.name()) |inm| {
            if (!ir_mod.isPreludeDeclName(inm) and drop.contains(inm)) continue;
        }
        try items.append(allocator, it);
    }
    try items.appendSlice(allocator, gen_items);
    return ast.Module{ .file_name = base.file_name, .items = try items.toOwnedSlice(allocator) };
}

/// Inject the `std.compiler` `Decl` type so `#compiler` hooks can call
/// `compiler_decls()`. Parsed under the user's file name (Fels symbols are
/// file-private — a separate name would hide `Decl` from the hook), with a
/// distinct high id base so its nodes never collide with the user's.
fn prependCompilerPrelude(allocator: std.mem.Allocator, user: ast.Module) !ast.Module {
    const parsed = try parser.parseSourceFrom(allocator, user.file_name, ast_prelude.compiler_source, 700_000);
    var items: std.ArrayList(ast.Item) = .empty;
    try items.appendSlice(allocator, parsed.module.items);
    try items.appendSlice(allocator, user.items);
    return .{ .file_name = user.file_name, .items = try items.toOwnedSlice(allocator) };
}

/// The names the embedded std.heap and std.ptr are parsed under: files of their own,
/// so a location in their code (a panic message, a diagnostic) names the file that
/// code is in. In angle brackets like `<runtime>`: they are the compiler's copies, not
/// paths on disk, and never clash with a `std/ptr.fels` the program loads itself.
const heap_prelude_file = "<std>/heap.fels";
const ptr_prelude_file = "<std>/ptr.fels";

/// Prepend the embedded std.heap bump arena (and std.ptr, which it uses) to the
/// user's module so a `zone` block's `Arena` handle and allocator are in scope.
/// Each is parsed under its own file name with a high id base; `ptr` is parsed
/// first and `heap` chains off its next id. The embedded `heap`'s `#import std.ptr`
/// reaches the embedded ptr. Fels symbols are file-private, so every file with a
/// zone imports heap as `#import std.heap.*;` would (`appendZoneImports`).
fn prependHeapPrelude(allocator: std.mem.Allocator, user: ast.Module) !ast.Module {
    const ptr_parsed = try parser.parseSourceFrom(allocator, ptr_prelude_file, std_prelude.ptr_src, heap_prelude_id_base);
    const heap_parsed = try parser.parseSourceFrom(allocator, heap_prelude_file, std_prelude.heap_src, ptr_parsed.next_id);
    diag_mod.rememberSource(ptr_prelude_file, std_prelude.ptr_src);
    diag_mod.rememberSource(heap_prelude_file, std_prelude.heap_src);

    var items: std.ArrayList(ast.Item) = .empty;

    // heap.fels calls the platform runtime's page primitives (`os_reserve`, …).
    // The runtime-free `compile` path has no runtime, so supply a host shim
    // (VirtualAlloc-backed) — but only when no runtime already defines them, so
    // real builds (which prepend a runtime) don't see a duplicate declaration.
    if (!moduleDeclaresFunction(user, "os_reserve")) {
        const shim_parsed = try parser.parseSourceFrom(allocator, "<runtime>", os_host_shim_src, ptr_parsed.next_id + 4096);
        for (shim_parsed.module.items) |item| switch (item) {
            .import => {},
            else => try items.append(allocator, item),
        };
    }

    for (ptr_parsed.module.items) |item| switch (item) {
        .import => {},
        else => try items.append(allocator, item),
    };
    for (heap_parsed.module.items) |item| switch (item) {
        .import => |imp| if (isStdImport(imp, "ptr")) {
            var resolved = imp;
            resolved.resolved_file = ptr_prelude_file;
            try items.append(allocator, .{ .import = resolved });
        },
        else => try items.append(allocator, item),
    };
    try appendZoneImports(allocator, &items, user.items);
    try items.appendSlice(allocator, user.items);
    return .{ .file_name = user.file_name, .items = try items.toOwnedSlice(allocator) };
}

/// Whether `imp` imports the standard library module `name` (`#import std.<name>…`).
fn isStdImport(imp: ast.ImportDecl, name: []const u8) bool {
    return imp.path.len == 2 and std.mem.eql(u8, imp.path[0], "std") and std.mem.eql(u8, imp.path[1], name);
}

/// For each file of `items` with a `zone` block, the import `#import std.heap.*;` would
/// be, of the embedded heap: that file's `Arena` handles and their calls resolve. It
/// sits on the file's first zone, where a clash with the file's own names is reported.
fn appendZoneImports(allocator: std.mem.Allocator, out: *std.ArrayList(ast.Item), items: []const ast.Item) !void {
    var files = std.StringHashMap(void).init(allocator);
    defer files.deinit();
    for (items) |item| {
        const span = itemZoneSpan(item) orelse continue;
        if ((try files.getOrPut(item.fileName())).found_existing) continue;
        try out.append(allocator, .{ .import = .{
            .path = &.{ "std", "heap" },
            .glob = true,
            .file_name = item.fileName(),
            .resolved_file = heap_prelude_file,
            .span = span,
            .for_zone = true,
        } });
    }
}

/// The zone imports of `appendZoneImports` when std.heap is in the module already, imported
/// by a module the program uses (`std.thread` imports it): each file with a `zone` that does
/// not import std.heap itself gets `#import std.heap.*;` of the loaded one. (A file that
/// imports std.heap names what it uses, as before.)
fn addLoadedZoneImports(allocator: std.mem.Allocator, module: ast.Module) !ast.Module {
    var heap_file: ?[]const u8 = null;
    var importers = std.StringHashMap(void).init(allocator);
    defer importers.deinit();
    for (module.items) |item| switch (item) {
        .import => |imp| if (isStdImport(imp, "heap")) {
            try importers.put(imp.file_name, {});
            if (heap_file == null) heap_file = imp.resolved_file;
        },
        else => {},
    };
    const loaded = heap_file orelse return module;
    var items: std.ArrayList(ast.Item) = .empty;
    var files = std.StringHashMap(void).init(allocator);
    defer files.deinit();
    for (module.items) |item| {
        const span = itemZoneSpan(item) orelse continue;
        if (importers.contains(item.fileName())) continue;
        if ((try files.getOrPut(item.fileName())).found_existing) continue;
        try items.append(allocator, .{ .import = .{
            .path = &.{ "std", "heap" },
            .glob = true,
            .file_name = item.fileName(),
            .resolved_file = loaded,
            .span = span,
            .for_zone = true,
        } });
    }
    if (items.items.len == 0) return module;
    try items.appendSlice(allocator, module.items);
    return .{ .file_name = module.file_name, .items = try items.toOwnedSlice(allocator) };
}

/// True when the module already declares a top-level function `name`.
fn moduleDeclaresFunction(module: ast.Module, name: []const u8) bool {
    for (module.items) |item| switch (item) {
        .function => |f| if (std.mem.eql(u8, f.name, name)) return true,
        else => {},
    };
    return false;
}

/// Host (Windows) page-memory shim for the runtime-free `compile` path. Mirrors
/// the `os_*` surface that windows.fels provides at runtime; injected by
/// `prependHeapPrelude` only when no runtime is present (so it never collides).
const os_host_shim_src =
    \\#extern("kernel32", "VirtualAlloc")
    \\VirtualAlloc :: fn(addr: usize, size: usize, alloc_type: u32, protect: u32) -> usize;
    \\#extern("kernel32", "VirtualFree")
    \\VirtualFree :: fn(addr: usize, size: usize, free_type: u32) -> bool;
    \\os_reserve :: fn(size: usize) -> usize { return VirtualAlloc(0usize, size, 0x2000u32, 0x4u32); }
    \\os_commit :: fn(addr: usize, size: usize) -> bool { return VirtualAlloc(addr, size, 0x1000u32, 0x4u32) != 0usize; }
    \\os_alloc :: fn(size: usize) -> usize { return VirtualAlloc(0usize, size, 0x3000u32, 0x4u32); }
    \\os_release :: fn(addr: usize, size: usize) { ignored := VirtualFree(addr, 0usize, 0x8000u32); }
;

/// Prepend the `TypeInfo` reflection surface to the user's module. Parsed under
/// the user's file name (file-private symbols) with a high id base.
fn prependReflectionPrelude(allocator: std.mem.Allocator, user: ast.Module) !ast.Module {
    // `<runtime>` so the reflection types are visible from every module (a serde
    // library, etc.), not just the root user file.
    const parsed = try parser.parseSourceFrom(allocator, "<runtime>", ast_prelude.reflection_source, reflection_prelude_id_base);
    var items: std.ArrayList(ast.Item) = .empty;
    try items.appendSlice(allocator, parsed.module.items);
    try items.appendSlice(allocator, user.items);
    return .{ .file_name = user.file_name, .items = try items.toOwnedSlice(allocator) };
}

/// Inject the `Test` context type (`fn(t: *Test)`) so `#test` functions compile
/// without importing anything. Parsed under `<runtime>` so it's visible from any
/// module that declares a test. Only injected when the module has a `#test` decl
/// and doesn't already define its own `Test`.
fn prependTestingPrelude(allocator: std.mem.Allocator, user: ast.Module) !ast.Module {
    const source = if (test_runner) ast_prelude.runtime_testing_source else ast_prelude.testing_source;
    const parsed = try parser.parseSourceFrom(allocator, "<runtime>", source, testing_prelude_id_base);
    var items: std.ArrayList(ast.Item) = .empty;
    try items.appendSlice(allocator, parsed.module.items);
    try items.appendSlice(allocator, user.items);
    return .{ .file_name = user.file_name, .items = try items.toOwnedSlice(allocator) };
}

/// The program `fels test` runs for one file (`test_runner`): a `main` that calls a case
/// function per `#test` function of the root file, in order, from the index the command
/// line gives on. The root file's `main` is left out and its `#entry` marks are dropped.
fn addTestRunner(allocator: std.mem.Allocator, user: ast.Module) !ast.Module {
    // `src` must outlive the parse: the tree's names point into it (the front-end arena).
    var src: std.ArrayList(u8) = .empty;
    var items: std.ArrayList(ast.Item) = .empty;
    var main_body: std.ArrayList(u8) = .empty;
    defer main_body.deinit(allocator);
    var index: u32 = 0;
    for (user.items) |item| {
        const f = switch (item) {
            .function => |f| f,
            else => {
                try items.append(allocator, item);
                continue;
            },
        };
        if (!std.mem.eql(u8, f.file_name, user.file_name)) {
            try items.append(allocator, item);
            continue;
        }
        if (std.mem.eql(u8, f.name, "main")) continue;
        var copy = f;
        if (hasAttribute(f.attrs, "entry")) {
            var attrs: std.ArrayList(ast.Attribute) = .empty;
            for (f.attrs) |a| if (!std.mem.eql(u8, a.name, "entry")) try attrs.append(allocator, a);
            copy.attrs = try attrs.toOwnedSlice(allocator);
        }
        try items.append(allocator, .{ .function = copy });
        if (!ir_mod.isTestFn(f) or !ir_mod.testNameMatches(f.name, test_filter)) continue;

        try src.print(allocator, "__fels_test_case_{d} :: fn() -> i32 {{\n    __fels_test_begin(\"{s}\");\n", .{ index, f.name });
        if (f.type_params.len != 0 or f.params.len != 1) {
            try src.appendSlice(allocator,
                \\    __fels_test_note("a #test function must take exactly one parameter `t: *Test`");
                \\    write_stdout("\n@@fels-test FAIL\n");
                \\    return 1;
                \\}
                \\
            );
        } else {
            try src.print(allocator, "    t: Test = .{{ .failures = 0u32 }};\n    {s}(&t);\n    return __fels_test_end(&t);\n}}\n", .{f.name});
        }
        try main_body.print(allocator, "    if from <= {d} {{ failed += __fels_test_case_{d}(); }}\n", .{ index, index });
        index += 1;
    }
    try src.appendSlice(allocator, "main :: fn() -> i32 {\n    from := __fels_test_from();\n    failed: i32 = 0;\n");
    try src.appendSlice(allocator, main_body.items);
    try src.appendSlice(allocator, "    __fels_test_done();\n    if failed != 0 { return 1; }\n    return 0;\n}\n");

    const parsed = try parser.parseSourceFrom(allocator, user.file_name, src.items, test_runner_id_base);
    try items.appendSlice(allocator, parsed.module.items);
    return .{ .file_name = user.file_name, .items = try items.toOwnedSlice(allocator) };
}

fn hasAttribute(attrs: []const ast.Attribute, name: []const u8) bool {
    for (attrs) |a| if (std.mem.eql(u8, a.name, name)) return true;
    return false;
}

/// Generate `any_field_at(v, i)` / `any_field_name(v, i)` over the module's
/// concrete structs, so an `Any` can navigate its fields. Each struct gets a
/// `__fld_<S>` that returns the i-th field as an *in-place* `Any` (via `any_at` on
/// the field address) and a `__fldn_<S>` for the field name; two dispatchers
/// switch on the runtime `typeid`. Only structs whose fields are all simple named
/// types are included (others are skipped — their navigation returns null/"").
fn prependFieldNavPrelude(allocator: std.mem.Allocator, user: ast.Module) !ast.Module {
    // NB: `src` must outlive this call — the parsed AST's string slices point into
    // it. It lives on the front-end arena, which frees it later.
    var src: std.ArrayList(u8) = .empty;

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    // Collected slice/pointer field types → element/pointee name. Generate one
    // `.elem`/`.deref` accessor per distinct type.
    var slice_elems = std.StringHashMap([]const u8).init(allocator);
    defer slice_elems.deinit();
    var ptr_targets = std.StringHashMap([]const u8).init(allocator);
    defer ptr_targets.deinit();
    // Every type seen → for `type_name_of(id)` / `type_size_of(id)` (the bare-id
    // lookup, `info_of`). Seeded with the scalars so they always resolve.
    var all_types = std.StringHashMap(void).init(allocator);
    defer all_types.deinit();
    for ([_][]const u8{ "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "usize", "isize", "f32", "f64", "bool" }) |t| try all_types.put(t, {});

    // Generated field navigators live in `<runtime>`, which sees every user type,
    // so they work no matter which module a struct (or the serializer) is in.
    const nav_file: []const u8 = "<runtime>";

    // Build the Any with `typeid_of`/`type_name` evaluated *here* (the nav file),
    // so a wrapped value's id matches the dispatchers' `core::type_id(...)` exactly.
    // (Routing through the generic `any_at` resolves the type via a binding, which
    // hashes compound types like `[]T` inconsistently with the direct form.)
    try src.appendSlice(allocator, "__any_make :: fn(ptr: *const u8, id: usize, nm: []const u8) -> Any { r: Any = .{ ptr, id, nm }; return r; }\n");

    for (user.items) |item| {
        const decl = switch (item) {
            .type_decl => |d| d,
            else => continue,
        };
        const strukt = switch (decl.kind) {
            .struct_type => |s| s,
            else => continue,
        };
        // Skip compiler-injected (`<runtime>`) structs; navigate every user struct.
        // The generated `__fld_<S>` lives in `<runtime>`, which can resolve `S` and
        // `Any` by bare name regardless of the file they're declared in.
        if (std.mem.eql(u8, decl.file_name, "<runtime>")) continue;
        if (strukt.type_params.len > 0 or strukt.fields.len == 0) continue;
        // Every field must render to a supported type (named, []named, *named).
        var ok = true;
        for (strukt.fields) |f| if ((try renderType(allocator, f.ty)) == null) {
            ok = false;
            break;
        };
        if (!ok) continue;

        try names.append(allocator, decl.name);
        try all_types.put(decl.name, {});
        try appendFmt(&src, allocator, "__fld_{s} :: fn(d: *const u8, i: usize) -> ?Any {{\n  unsafe {{\n    p := d as *const {s};\n", .{ decl.name, decl.name });
        for (strukt.fields, 0..) |f, j| {
            const tstr = (try renderType(allocator, f.ty)).?;
            try all_types.put(tstr, {});
            try appendFmt(&src, allocator, "    if i == {d}usize {{ return __any_make((&p.{s}) as *const u8, core::type_id({s}), core::type_name({s})); }}\n", .{ j, f.name, tstr, tstr });
            switch (f.ty) {
                .slice => |s| if (s.inner.* == .named) try slice_elems.put(tstr, s.inner.named.name),
                .pointer => |p| if (p.inner.* == .named) try ptr_targets.put(tstr, p.inner.named.name),
                else => {},
            }
        }
        try src.appendSlice(allocator, "  }\n  return null;\n}\n");

        try appendFmt(&src, allocator, "__fldn_{s} :: fn(i: usize) -> []const u8 {{\n", .{decl.name});
        for (strukt.fields, 0..) |f, j| {
            try appendFmt(&src, allocator, "  if i == {d}usize {{ return \"{s}\"; }}\n", .{ j, f.name });
        }
        try src.appendSlice(allocator, "  return \"\";\n}\n");
    }

    // Element / pointee accessors. A slice value is `{ ptr, len }`; a pointer Any
    // stores the pointer itself.
    try src.appendSlice(allocator, "__SliceHdr :: struct { ptr: *const u8, len: usize }\n");
    {
        var it = slice_elems.iterator();
        var k: usize = 0;
        while (it.next()) |e| : (k += 1) {
            try appendFmt(&src, allocator, "__elem_{d} :: fn(v: Any, idx: usize) -> ?Any {{\n  unsafe {{\n    h := v.data as *const __SliceHdr;\n    if idx >= h.len {{ return null; }}\n    ep := ((h.ptr as usize) + idx * core::sizeof({s})) as *const u8;\n    return __any_make(ep, core::type_id({s}), core::type_name({s}));\n  }}\n}}\n", .{ k, e.value_ptr.*, e.value_ptr.*, e.value_ptr.* });
        }
    }
    {
        var it = ptr_targets.iterator();
        var k: usize = 0;
        while (it.next()) |e| : (k += 1) {
            try appendFmt(&src, allocator, "__deref_{d} :: fn(v: Any) -> ?Any {{\n  unsafe {{\n    a := *(v.data as *const usize);\n    if a == 0usize {{ return null; }}\n    return __any_make(a as *const u8, core::type_id({s}), core::type_name({s}));\n  }}\n}}\n", .{ k, e.value_ptr.*, e.value_ptr.* });
        }
    }

    // `info_of` surface: name/size from a *bare* typeid (not just from an Any).
    try src.appendSlice(allocator, "type_name_of :: fn(id: usize) -> []const u8 {\n");
    {
        var it = all_types.keyIterator();
        while (it.next()) |k| try appendFmt(&src, allocator, "  if id == core::type_id({s}) {{ return core::type_name({s}); }}\n", .{ k.*, k.* });
    }
    try src.appendSlice(allocator, "  return \"?\";\n}\n");
    try src.appendSlice(allocator, "type_size_of :: fn(id: usize) -> usize {\n");
    {
        var it = all_types.keyIterator();
        while (it.next()) |k| try appendFmt(&src, allocator, "  if id == core::type_id({s}) {{ return core::sizeof({s}); }}\n", .{ k.*, k.* });
    }
    try src.appendSlice(allocator, "  return 0usize;\n}\n");

    // Dispatchers — always emitted so the `any_field_*`/`any_elem`/`any_deref`
    // surface exists whenever `Any` is in use.
    try src.appendSlice(allocator, "any_field_at :: fn(v: Any, i: usize) -> ?Any {\n");
    for (names.items) |n| try appendFmt(&src, allocator, "  if v.id == core::type_id({s}) {{ return __fld_{s}(v.data, i); }}\n", .{ n, n });
    try src.appendSlice(allocator, "  return null;\n}\n");

    try src.appendSlice(allocator, "any_field_name :: fn(v: Any, i: usize) -> []const u8 {\n");
    for (names.items) |n| try appendFmt(&src, allocator, "  if v.id == core::type_id({s}) {{ return __fldn_{s}(i); }}\n", .{ n, n });
    try src.appendSlice(allocator, "  return \"\";\n}\n");

    try src.appendSlice(allocator, "any_elem :: fn(v: Any, i: usize) -> ?Any {\n");
    {
        var it = slice_elems.keyIterator();
        var k: usize = 0;
        while (it.next()) |key| : (k += 1) {
            try appendFmt(&src, allocator, "  if v.id == core::type_id({s}) {{ return __elem_{d}(v, i); }}\n", .{ key.*, k });
        }
    }
    try src.appendSlice(allocator, "  return null;\n}\n");

    try src.appendSlice(allocator, "any_deref :: fn(v: Any) -> ?Any {\n");
    {
        var it = ptr_targets.keyIterator();
        var k: usize = 0;
        while (it.next()) |key| : (k += 1) {
            try appendFmt(&src, allocator, "  if v.id == core::type_id({s}) {{ return __deref_{d}(v); }}\n", .{ key.*, k });
        }
    }
    try src.appendSlice(allocator, "  return null;\n}\n");

    const parsed = try parser.parseSourceFrom(allocator, nav_file, src.items, fieldnav_prelude_id_base);
    var items: std.ArrayList(ast.Item) = .empty;
    try items.appendSlice(allocator, parsed.module.items);
    try items.appendSlice(allocator, user.items);
    return .{ .file_name = user.file_name, .items = try items.toOwnedSlice(allocator) };
}

fn appendFmt(src: *std.ArrayList(u8), a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(a, fmt, args);
    try src.appendSlice(a, s);
}

/// Render a field type for the navigation generator: a plain named type, a slice
/// of a named type (`[]T` / `[]const T`), or a pointer to one (`*T` / `*const T`).
/// Returns null for anything else (the struct is then skipped).
fn renderType(a: std.mem.Allocator, ty: ast.TypeRef) error{OutOfMemory}!?[]const u8 {
    return switch (ty) {
        .named => |n| n.name,
        .slice => |s| {
            const inner = (try renderType(a, s.inner.*)) orelse return null;
            return if (s.is_const)
                try std.fmt.allocPrint(a, "[]const {s}", .{inner})
            else
                try std.fmt.allocPrint(a, "[]{s}", .{inner});
        },
        .pointer => |p| {
            const inner = (try renderType(a, p.inner.*)) orelse return null;
            return if (p.is_const)
                try std.fmt.allocPrint(a, "*const {s}", .{inner})
            else
                try std.fmt.allocPrint(a, "*{s}", .{inner});
        },
        .optional => |o| {
            const inner = (try renderType(a, o.inner.*)) orelse return null;
            return try std.fmt.allocPrint(a, "?{s}", .{inner});
        },
        // `[N]T` with a literal or named length.
        .array => |arr| {
            const inner = (try renderType(a, arr.inner.*)) orelse return null;
            const len = switch (arr.len.kind) {
                .int, .ident => |t| t,
                else => return null,
            };
            return try std.fmt.allocPrint(a, "[{s}]{s}", .{ len, inner });
        },
        else => null,
    };
}

/// The preludes of the types a program's values are printed and inspected with, each when
/// the module uses it: `Format`/`Formatter`, `TypeInfo`, `Any` with the field navigators.
/// The `#compiler` hook pass needs them as the final compile does, since std uses them.
fn prependValuePreludes(allocator: std.mem.Allocator, module: ast.Module) CompileError!ast.Module {
    const fail = struct {
        fn map(err: anyerror) CompileError {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.ParseFailed,
            };
        }
    }.map;
    // `Format` and `Formatter` (printing with values in the text), when the module names
    // one. Before the reflection and `Any` steps: they use both, so those come too.
    const with_format = if (moduleUsesFormat(module) and !moduleDefinesType(module, "Format"))
        prependFormatPrelude(allocator, module) catch |err| return fail(err)
    else
        module;

    // `type_info(T)` yields a matchable `TypeInfo` value; inject that reflection
    // surface when the module uses it (and doesn't already define `TypeInfo`).
    const with_reflect = if (moduleUsesReflection(with_format) and !moduleDefinesType(with_format, "TypeInfo"))
        prependReflectionPrelude(allocator, with_format) catch |err| return fail(err)
    else
        with_format;

    // `Any` (type-erased value + safe downcast) is mostly ordinary generic Fels —
    // inject it when the module uses `Any`/`any(`/`any_*` (and doesn't define its
    // own `Any`). Detected over the combined AST (not the source string, which in
    // a multi-module compile is only the first file). The wrap `any(x)` is the
    // only compiler-driven piece.
    const uses_any = moduleUsesAny(with_reflect) and !moduleDefinesType(with_reflect, "Any");
    const with_any = if (uses_any)
        prependAnyPrelude(allocator, with_reflect) catch |err| return fail(err)
    else
        with_reflect;

    // Generate `any_field_at`/`any_field_name` over the module's concrete structs,
    // so `Any` values navigate their fields (and `serialize` can walk them).
    return if (uses_any)
        prependFieldNavPrelude(allocator, with_any) catch |err| return fail(err)
    else
        with_any;
}

fn prependFormatPrelude(allocator: std.mem.Allocator, user: ast.Module) !ast.Module {
    // `src` must outlive the parse: the tree's names point into it (the front-end arena).
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(allocator, ast_prelude.format_source);
    try appendCustomFormats(allocator, &src, user);
    const parsed = try parser.parseSourceFrom(allocator, "<runtime>", src.items, format_prelude_id_base);
    var items: std.ArrayList(ast.Item) = .empty;
    try items.appendSlice(allocator, parsed.module.items);
    try items.appendSlice(allocator, user.items);
    return .{ .file_name = user.file_name, .items = try items.toOwnedSlice(allocator) };
}

/// `__fmt_custom(id, data, f)`: a value of a type with its own
/// `format :: fn(self, f: *Formatter)` method is printed by it. std.io's value writer asks
/// first, for a value at the top as for one inside another. A `format` method of another
/// signature is no printing method and is left alone.
fn appendCustomFormats(allocator: std.mem.Allocator, src: *std.ArrayList(u8), user: ast.Module) !void {
    try src.appendSlice(allocator, "\n__fmt_custom :: fn(id: usize, data: *const u8, f: *Formatter) -> bool {\n");
    for (user.items) |item| {
        const decl = switch (item) {
            .function => |d| d,
            else => continue,
        };
        if (std.mem.eql(u8, decl.file_name, "<runtime>") or decl.type_params.len != 0) continue;
        if (!std.mem.endsWith(u8, decl.name, ".format")) continue;
        const type_name = decl.name[0 .. decl.name.len - ".format".len];
        if (std.mem.indexOfScalar(u8, type_name, '.') != null or decl.params.len != 2) continue;
        const second = decl.params[1].ty;
        if (second != .pointer or !typeRefNames(second, "Formatter")) continue;
        const by_pointer = decl.params[0].ty == .pointer;
        if (by_pointer) {
            try appendFmt(src, allocator, "    if id == core::type_id({s}) {{ unsafe {{ (data as *{s}).format(f); }} return true; }}\n", .{ type_name, type_name });
        } else {
            try appendFmt(src, allocator, "    if id == core::type_id({s}) {{ unsafe {{ (*(data as *const {s})).format(f); }} return true; }}\n", .{ type_name, type_name });
        }
    }
    try src.appendSlice(allocator, "    return false;\n}\n");
}

fn prependAnyPrelude(allocator: std.mem.Allocator, user: ast.Module) !ast.Module {
    const parsed = try parser.parseSourceFrom(allocator, "<runtime>", ast_prelude.any_source, any_prelude_id_base);
    var items: std.ArrayList(ast.Item) = .empty;
    try items.appendSlice(allocator, parsed.module.items);
    try items.appendSlice(allocator, user.items);
    return .{ .file_name = user.file_name, .items = try items.toOwnedSlice(allocator) };
}

/// The declarations of `TARGET` for the build being made (`build_target`).
fn prependTargetPrelude(allocator: std.mem.Allocator, user: ast.Module) !ast.Module {
    const t = build_target.current;
    const src = try std.fmt.allocPrint(allocator,
        \\pub TargetOs :: enum {{ windows, linux, macos, unknown }}
        \\pub TargetArch :: enum {{ x86_64, aarch64, unknown }}
        \\pub TargetInfo :: struct {{ os: TargetOs, arch: TargetArch, debug: bool }}
        \\pub TARGET : TargetInfo : .{{ .os = .{s}, .arch = .{s}, .debug = {s} }};
        \\
    , .{ t.osName(), t.archName(), if (t.debug) "true" else "false" });
    const parsed = try parser.parseSourceFrom(allocator, "<runtime>", src, target_prelude_id_base);
    var items: std.ArrayList(ast.Item) = .empty;
    try items.appendSlice(allocator, parsed.module.items);
    try items.appendSlice(allocator, user.items);
    return .{ .file_name = user.file_name, .items = try items.toOwnedSlice(allocator) };
}

/// Whether a source of the module has the word `TARGET`. A source that has it in a comment
/// or a string only brings in three declarations the program does not use.
/// A declaration's `source` is the text of its whole file, and a file's declarations come one
/// after the other: each text is read once, not once per declaration (a file of 5,000
/// functions was read 5,000 times, 5 s for 100,000 lines).
fn mentionsTarget(module: ast.Module, root_source: []const u8) bool {
    if (hasWord(root_source, "TARGET")) return true;
    var last: []const u8 = root_source;
    for (module.items) |item| {
        const text = switch (item) {
            .function => |f| f.source,
            .const_decl => |d| d.source,
            else => continue,
        };
        if (text.ptr == last.ptr and text.len == last.len) continue;
        if (hasWord(text, "TARGET")) return true;
        last = text;
    }
    return false;
}

fn hasWord(text: []const u8, word: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, word)) |at| {
        const before_ok = at == 0 or !isIdentChar(text[at - 1]);
        const end = at + word.len;
        const after_ok = end == text.len or !isIdentChar(text[end]);
        if (before_ok and after_ok) return true;
        from = at + 1;
    }
    return false;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// True when the module declares a top-level constant or global named `name`.
fn moduleDefinesConst(module: ast.Module, name: []const u8) bool {
    for (module.items) |item| switch (item) {
        .const_decl => |d| if (std.mem.eql(u8, d.name, name)) return true,
        else => {},
    };
    return false;
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

/// True when the module references the `Any` type or calls an `any*` builtin
/// (`any`/`any_is`/`any_as`/`any_id`), so the `Any` prelude should be injected.
fn moduleUsesAny(module: ast.Module) bool {
    for (module.items) |item| switch (item) {
        .function => |f| {
            if (typeRefUsesAny(f.return_ty)) return true;
            for (f.params) |p| if (typeRefUsesAny(p.ty)) return true;
            if (f.body) |b| if (blockUsesAny(b)) return true;
        },
        .const_decl => |d| if (exprUsesAny(d.value)) return true,
        else => {},
    };
    return false;
}

/// True when a function of the module takes or returns a `Format` or a `Formatter` (a
/// pointer to one, too), so the prelude that declares them is injected.
fn moduleUsesFormat(module: ast.Module) bool {
    for (module.items) |item| switch (item) {
        .function => |f| {
            if (typeRefNames(f.return_ty, "Format") or typeRefNames(f.return_ty, "Formatter")) return true;
            for (f.params) |p| if (typeRefNames(p.ty, "Format") or typeRefNames(p.ty, "Formatter")) return true;
        },
        else => {},
    };
    return false;
}

/// Whether `ty` is the type `name`, or a pointer, optional, slice or array of it.
fn typeRefNames(ty: ast.TypeRef, name: []const u8) bool {
    return switch (ty) {
        .named => |n| n.namespace == null and std.mem.eql(u8, n.name, name),
        .pointer, .many_pointer => |p| typeRefNames(p.inner.*, name),
        .optional => |o| typeRefNames(o.inner.*, name),
        .slice => |sl| typeRefNames(sl.inner.*, name),
        .array => |a| typeRefNames(a.inner.*, name),
        .borrow => |b| typeRefNames(b.inner.*, name),
        else => false,
    };
}

fn typeRefUsesAny(ty: ast.TypeRef) bool {
    return switch (ty) {
        .named, .type_param => |n| std.mem.eql(u8, n.name, "Any"),
        .pointer, .many_pointer => |p| typeRefUsesAny(p.inner.*),
        .optional => |o| typeRefUsesAny(o.inner.*),
        .slice => |s| typeRefUsesAny(s.inner.*),
        .array => |a| typeRefUsesAny(a.inner.*),
        .atomic => |a| typeRefUsesAny(a.inner.*),
        .borrow => |b| typeRefUsesAny(b.inner.*),
        else => false,
    };
}

/// Whether a string literal that may be a format (it has braces) names one of `pred`'s names in
/// its braces. Its values become code after the preludes are chosen (`expandFormats`), so a
/// `{any_name(v)}` or `{core::type_info(T)}` there needs them as much as code does. Any word
/// of the text counts; an extra prelude costs nothing at run time.
fn formatTextNames(raw: []const u8, comptime pred: fn ([]const u8) bool) bool {
    if (!format_expand.hasBraces(raw)) return false;
    var i: usize = 0;
    while (i < raw.len) {
        if (std.ascii.isAlphabetic(raw[i]) or raw[i] == '_') {
            const start = i;
            while (i < raw.len and (std.ascii.isAlphanumeric(raw[i]) or raw[i] == '_')) i += 1;
            if (pred(raw[start..i])) return true;
        } else i += 1;
    }
    return false;
}

fn isAnyName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Any") or isAnyBuiltin(name) or std.mem.startsWith(u8, name, "any_");
}

fn isReflectionName(name: []const u8) bool {
    return std.mem.eql(u8, name, "type_info") or std.mem.eql(u8, name, "type_name") or std.mem.eql(u8, name, "TypeInfo");
}

fn isAnyBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "any") or std.mem.eql(u8, name, "any_is") or
        std.mem.eql(u8, name, "any_as") or std.mem.eql(u8, name, "any_id");
}

/// If `callee` is `core::<member>` (the reserved builtin namespace), return the
/// member name — so the prelude-injection scanners detect builtins written as
/// `core::type_info(...)`/`core::any(...)`, not only the bare forms.
fn coreMemberOf(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .scope_access => |sa| if (sa.base.kind == .ident and std.mem.eql(u8, sa.base.kind.ident, "core")) sa.member else null,
        else => null,
    };
}

fn blockUsesAny(block: ast.Block) bool {
    for (block.statements) |stmt| if (stmtUsesAny(stmt)) return true;
    return false;
}

fn stmtUsesAny(stmt: ast.Stmt) bool {
    return switch (stmt) {
        .comptime_run, .unsafe_block => |b| blockUsesAny(b),
        .if_stmt => |s| blockUsesAny(s.then_block) or
            (if (s.else_block) |e| blockUsesAny(e) else false) or exprUsesAny(s.condition) or
            (if (s.binding) |bd| exprUsesAny(bd.value) else false),
        .while_stmt => |s| blockUsesAny(s.body) or exprUsesAny(s.condition),
        .for_range => |s| blockUsesAny(s.body) or exprUsesAny(s.start) or exprUsesAny(s.end),
        .for_slice => |s| blockUsesAny(s.body) or exprUsesAny(s.iter),
        .zone_block => |s| blockUsesAny(s.body),
        .defer_stmt => |s| blockUsesAny(s.body),
        .comptime_if => |s| blockUsesAny(s.then_block) or
            (if (s.else_block) |e| blockUsesAny(e) else false),
        .match_stmt => |s| blk: {
            for (s.arms) |a| if (blockUsesAny(a.body)) break :blk true;
            break :blk exprUsesAny(s.subject);
        },
        .local_typed => |s| typeRefUsesAny(s.ty) or exprUsesAny(s.value),
        .local_infer => |s| exprUsesAny(s.value),
        .assign => |s| exprUsesAny(s.target) or exprUsesAny(s.value),
        .return_stmt => |s| if (s.value) |v| exprUsesAny(v) else false,
        .yield_stmt => |s| exprUsesAny(s.value),
        .expr => |e| exprUsesAny(e),
        else => false,
    };
}

fn exprUsesAny(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .call => |c| blk: {
            if (c.callee.kind == .ident and isAnyBuiltin(c.callee.kind.ident)) break :blk true;
            if (coreMemberOf(c.callee.*)) |m| if (isAnyBuiltin(m)) break :blk true;
            if (exprUsesAny(c.callee.*)) break :blk true;
            for (c.args) |a| switch (a) {
                .positional => |x| if (exprUsesAny(x)) break :blk true,
                .named => |nm| if (exprUsesAny(nm.value)) break :blk true,
            };
            break :blk false;
        },
        .binary => |b| exprUsesAny(b.left.*) or exprUsesAny(b.right.*),
        .unary => |u| exprUsesAny(u.expr.*),
        .field => |f| exprUsesAny(f.base.*),
        .index => |i| exprUsesAny(i.base.*) or exprUsesAny(i.index.*),
        .force_unwrap, .unsafe_expr, .run_expr => |inner| exprUsesAny(inner.*),
        .as_cast => |c| exprUsesAny(c.value.*),
        .nil_coalesce => |nc| exprUsesAny(nc.value.*) or exprUsesAny(nc.default.*),
        .string => |raw| formatTextNames(raw, isAnyName),
        .try_expr => |t| exprUsesAny(t.value.*),
        .catch_expr => |c| exprUsesAny(c.value.*) or blockUsesAny(c.handler),
        else => false,
    };
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
        .yield_stmt => |s| exprUsesReflection(s.value),
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
            if (coreMemberOf(c.callee.*)) |n| {
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
        .string => |raw| formatTextNames(raw, isReflectionName),
        .try_expr => |t| exprUsesReflection(t.value.*),
        .catch_expr => |c| exprUsesReflection(c.value.*) or blockUsesReflection(c.handler),
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
    for (module.items) |item| if (itemZoneSpan(item) != null) return true;
    return false;
}

/// The span of the first `zone` block in a function's or an impl's bodies, or null
/// when they have none.
fn itemZoneSpan(item: ast.Item) ?Span {
    switch (item) {
        .function => |f| if (f.body) |b| return blockZoneSpan(b),
        .interface_impl => |impl| for (impl.methods) |m| {
            if (m.body) |b| if (blockZoneSpan(b)) |span| return span;
        },
        else => {},
    }
    return null;
}

fn blockZoneSpan(block: ast.Block) ?Span {
    for (block.statements) |stmt| if (stmtZoneSpan(stmt)) |span| return span;
    return null;
}

fn stmtZoneSpan(stmt: ast.Stmt) ?Span {
    return switch (stmt) {
        .zone_block => |z| z.span,
        .comptime_run, .unsafe_block => |b| blockZoneSpan(b),
        .if_stmt => |s| blockZoneSpan(s.then_block) orelse
            (if (s.else_block) |e| blockZoneSpan(e) else null),
        .while_stmt => |s| blockZoneSpan(s.body),
        .for_range => |s| blockZoneSpan(s.body),
        .for_slice => |s| blockZoneSpan(s.body),
        .defer_stmt => |s| blockZoneSpan(s.body),
        .comptime_if => |s| blockZoneSpan(s.then_block) orelse
            (if (s.else_block) |e| blockZoneSpan(e) else null),
        .match_stmt => |s| for (s.arms) |a| {
            if (blockZoneSpan(a.body)) |span| break span;
        } else null,
        else => null,
    };
}

const SemaResult = struct {
    symbols: sema.SymbolTable,
    types: sema.TypeEnv,
};

/// `formats`: tolerant, and the generic instantiations are checked too (`expandFormats`).
const SemaMode = enum { strict, tolerant, formats };

fn runSema(
    allocator: std.mem.Allocator,
    module: ast.Module,
    source: []const u8,
    file: []const u8,
    mode: SemaMode,
) CompileError!SemaResult {
    return runSemaResolved(allocator, module, source, file, mode, null, null, null, null);
}

/// `runSema` with an optional resolution-time `where`-predicate evaluator wired
/// into the strict pass (the two-pass rail).
fn runSemaResolved(
    allocator: std.mem.Allocator,
    module: ast.Module,
    source: []const u8,
    file: []const u8,
    mode: SemaMode,
    where_ctx: ?*anyopaque,
    where_fn: ?sema.WhereEvalFn,
    where_type_fn: ?sema.WhereTypeEvalFn,
    const_seeds: ?*const std.AutoHashMap(sema.SymbolId, u64),
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
        .formats => sema.checkTypesForFormats(allocator, module, &symbols, source, file) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        },
        .strict => sema.checkTypesWithResolution(allocator, module, &symbols, source, file, where_ctx, where_fn, where_type_fn, const_seeds) catch |err| switch (err) {
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
        .yield_stmt => |s| exprUsesMeta(s.value),
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
    // module — Fels symbols are file-private, so a separate file name would make
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
    // The sources the messages were located in live in this arena.
    diag_mod.forgetSources();
    arena.deinit();
    allocator.destroy(arena);
}
