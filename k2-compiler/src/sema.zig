const std = @import("std");
const ast = @import("ast.zig");
const comptime_mod = @import("comptime.zig");
const NodeId = ast.NodeId;
const diag_mod = @import("diagnostic.zig");
const Diagnostic = diag_mod.Diagnostic;
const DiagKind = diag_mod.DiagKind;
const Span = @import("lexer/span.zig").Span;

pub const ScopeId = usize;
pub const SymbolId = usize;

pub const SemanticError = error{
    SemanticFailed,
    OutOfMemory,
};

pub const SymbolTable = struct {
    scopes: std.ArrayList(Scope) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,
    visible_names: std.StringHashMap(std.StringHashMap(SymbolId)) = undefined,
    root_scope: ScopeId = 0,

    pub fn init(allocator: std.mem.Allocator) !SymbolTable {
        var table: SymbolTable = .{
            .visible_names = std.StringHashMap(std.StringHashMap(SymbolId)).init(allocator),
        };
        errdefer table.deinit(allocator);

        try table.scopes.append(allocator, Scope.init(allocator, 0, null));
        return table;
    }

    pub fn deinit(self: *SymbolTable, allocator: std.mem.Allocator) void {
        for (self.scopes.items) |*scope_item| {
            scope_item.deinit(allocator);
        }
        self.scopes.deinit(allocator);
        self.symbols.deinit(allocator);
        var visible_it = self.visible_names.valueIterator();
        while (visible_it.next()) |names| names.deinit();
        self.visible_names.deinit();
    }

    pub fn addScope(self: *SymbolTable, allocator: std.mem.Allocator, parent: ?ScopeId) !ScopeId {
        const id = self.scopes.items.len;
        try self.scopes.append(allocator, Scope.init(allocator, id, parent));
        return id;
    }

    pub fn symbol(self: SymbolTable, id: SymbolId) Symbol {
        return self.symbols.items[id];
    }

    pub fn scope(self: SymbolTable, id: ScopeId) Scope {
        return self.scopes.items[id];
    }

    pub fn resolve(self: SymbolTable, start_scope: ScopeId, name: []const u8) ?SymbolId {
        var scope_id = start_scope;

        while (true) {
            const current = self.scopes.items[scope_id];
            if (current.names.get(name)) |id| {
                return id;
            }

            if (current.parent) |parent| {
                scope_id = parent;
            } else {
                return null;
            }
        }
    }

    pub fn resolveVisible(self: SymbolTable, file_name: []const u8, name: []const u8) ?SymbolId {
        const id = self.resolve(self.root_scope, name) orelse return null;
        const symbol_value = self.symbol(id);
        if (std.mem.eql(u8, symbol_value.file_name, "<runtime>")) return id;
        const visible = self.visible_names.get(file_name) orelse return null;
        return visible.get(name);
    }

    pub fn insert(
        self: *SymbolTable,
        allocator: std.mem.Allocator,
        scope_id: ScopeId,
        name: []const u8,
        kind: SymbolKind,
        span: Span,
        file_name: []const u8,
        is_public: bool,
    ) !SymbolId {
        if (self.scopes.items[scope_id].names.get(name)) |existing| {
            return existing;
        }

        const id = self.symbols.items.len;
        try self.symbols.append(allocator, .{
            .id = id,
            .name = name,
            .kind = kind,
            .span = span,
            .scope_id = scope_id,
            .owner = null,
            .file_name = file_name,
            .is_public = is_public,
        });
        try self.scopes.items[scope_id].names.put(name, id);
        try self.scopes.items[scope_id].symbols.append(allocator, id);
        return id;
    }
};

pub const Scope = struct {
    id: ScopeId,
    parent: ?ScopeId,
    symbols: std.ArrayList(SymbolId) = .empty,
    names: std.StringHashMap(SymbolId) = undefined,

    pub fn init(allocator: std.mem.Allocator, id: ScopeId, parent: ?ScopeId) Scope {
        return .{
            .id = id,
            .parent = parent,
            .names = std.StringHashMap(SymbolId).init(allocator),
        };
    }

    pub fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        self.symbols.deinit(allocator);
        self.names.deinit();
    }
};

pub const Symbol = struct {
    id: SymbolId,
    name: []const u8,
    kind: SymbolKind,
    span: Span,
    scope_id: ScopeId,
    owner: ?SymbolId,
    file_name: []const u8,
    is_public: bool,
};

pub const SymbolKind = enum {
    import,
    type,
    field,
    variant,
    function,
    const_symbol,
    param,
    zone_param,
    local_val,
    local_var,
    local_const,
    zone,
    for_binding,
    case_binding,
    try_error,
    global_var,

    pub fn label(self: SymbolKind) []const u8 {
        return switch (self) {
            .import => "import",
            .type => "type",
            .field => "field",
            .variant => "variant",
            .function => "function",
            .const_symbol => "constant",
            .param => "parameter",
            .zone_param => "zone parameter",
            .local_val => "value",
            .local_var => "variable",
            .local_const => "local constant",
            .zone => "zone",
            .for_binding => "loop binding",
            .case_binding => "case binding",
            .try_error => "error binding",
            .global_var => "global variable",
        };
    }
};

pub const Ty = union(enum) {
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    f32,
    f64,
    bool,
    byte,
    usize,
    isize,
    addr,
    void,
    text,
    rune,
    system,
    file_sys,
    net,
    clock,
    gpu,
    writer,
    reader,
    conn,
    text_buf,
    args,
    thread_pool,
    zone,
    pointer: *const Ty, // *T  — mutable pointer
    const_ptr: *const Ty, // *const T — read-only pointer
    optional: *const Ty,
    slice: *const Ty,
    borrow: *const Ty,
    array: ArrayTy,
    range: *const Ty,
    named: SymbolId,
    list: *const Ty,
    map: *const Ty,
    null_ptr,
    zone_handle,
    type_param: []const u8,
    error_set: []const ErrorVariantInfo,
    fallible: FallibleTy,
    fn_ptr: FnPtrTy,
    int_lit,
    float_lit,
    unknown,
    error_ty,

    pub fn isInteger(self: Ty) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .byte, .usize, .isize, .addr, .int_lit, .type_param => true,
            else => false,
        };
    }

    pub fn isFloat(self: Ty) bool {
        return switch (self) {
            .f32, .f64, .float_lit => true,
            else => false,
        };
    }

    pub fn isNumeric(self: Ty) bool {
        return self.isInteger() or self.isFloat();
    }

    pub fn isBool(self: Ty) bool {
        return self == .bool;
    }
};

const ZoneOwner = struct {
    name: []const u8,
    scope_depth: usize,
    kind: enum { zone, borrow } = .zone,
};

const ActiveZone = struct {
    name: []const u8,
    scope_depth: usize,
};

pub const ArrayTy = struct {
    elem: *const Ty,
    len: u64,
};

pub const FallibleTy = struct {
    ok: *const Ty,
    err: *const Ty,
};

pub const FnPtrTy = struct {
    params: []const Ty,
    ret: *const Ty,
};

pub const TypeLayout = struct {
    kind: TypeKind,
    is_packed: bool,
};

pub const TypeKind = union(enum) {
    struct_type: []const FieldInfo,
    variant_type: []const VariantInfo,
    error_set: []const ErrorVariantInfo,
    interface_type: []const InterfaceMethodInfo,
};

pub const InterfaceMethodInfo = struct {
    name: []const u8,
    params: []const ParamSig,
    return_ty: Ty,
    error_ty: ?Ty,
};

pub const FieldInfo = struct {
    name: []const u8,
    ty: Ty,
};

pub const VariantInfo = struct {
    name: []const u8,
    payload: ?Ty,
    index: u32, // discriminant value
};

pub const ErrorVariantInfo = struct {
    name: []const u8,
    payload: ?Ty,
};

pub const VariantValueInfo = struct {
    parent_ty: SymbolId,
    payload: ?Ty,
};

pub const FnSig = struct {
    params: []const ParamSig,
    return_ty: Ty,
    error_ty: ?Ty,
    extern_name: ?[]const u8,
    inline_hint: bool,
    no_inline: bool,
    no_return: bool,
    entry: bool,
    naked: bool,
    export_sym: ?[]const u8, // #export / #export("name")
    deprecated: ?[]const u8, // #deprecated / #deprecated("msg")
    type_params: []const []const u8,
    type_constraints: []const ast.TypeConstraint = &.{},
    type_binding: ?[]const u8,
};

pub const ParamSig = struct {
    name: []const u8,
    ty: Ty,
    is_type_param: bool = false,
};

pub const TypeEnv = struct {
    symbol_types: std.AutoHashMap(SymbolId, Ty),
    layouts: std.AutoHashMap(SymbolId, TypeLayout),
    fn_sigs: std.AutoHashMap(SymbolId, FnSig),
    variant_values: std.AutoHashMap(SymbolId, VariantValueInfo),
    expr_types: std.AutoHashMap(ast.NodeId, Ty),
    expr_symbols: std.AutoHashMap(ast.NodeId, SymbolId),
    expr_scopes: std.AutoHashMap(ast.NodeId, ScopeId),
    /// Field-callee NodeId -> visible top-level function used as an extension method.
    extension_calls: std.AutoHashMap(ast.NodeId, SymbolId),
    generic_instantiations: std.ArrayList(GenericInstantiation) = .empty,
    /// Callee expression NodeId → mangled name for generic function calls.
    generic_call_insts: std.AutoHashMap(ast.NodeId, []const u8) = undefined,
    /// Generic struct templates: struct name → TypeDecl (with type_params).
    generic_struct_templates: std.StringHashMap(ast.TypeDecl) = undefined,
    /// Mangled name → SymbolId for already-instantiated generic structs.
    generic_struct_instances: std.StringHashMap(SymbolId) = undefined,
    interface_impls: std.StringHashMap(ast.InterfaceImpl) = undefined,
    diagnostics: std.ArrayList(Diagnostic) = .empty,

    pub fn init(allocator: std.mem.Allocator) TypeEnv {
        return .{
            .symbol_types = std.AutoHashMap(SymbolId, Ty).init(allocator),
            .layouts = std.AutoHashMap(SymbolId, TypeLayout).init(allocator),
            .fn_sigs = std.AutoHashMap(SymbolId, FnSig).init(allocator),
            .variant_values = std.AutoHashMap(SymbolId, VariantValueInfo).init(allocator),
            .expr_types = std.AutoHashMap(ast.NodeId, Ty).init(allocator),
            .expr_symbols = std.AutoHashMap(ast.NodeId, SymbolId).init(allocator),
            .expr_scopes = std.AutoHashMap(ast.NodeId, ScopeId).init(allocator),
            .extension_calls = std.AutoHashMap(ast.NodeId, SymbolId).init(allocator),
            .generic_call_insts = std.AutoHashMap(ast.NodeId, []const u8).init(allocator),
            .generic_struct_templates = std.StringHashMap(ast.TypeDecl).init(allocator),
            .generic_struct_instances = std.StringHashMap(SymbolId).init(allocator),
            .interface_impls = std.StringHashMap(ast.InterfaceImpl).init(allocator),
        };
    }

    pub fn deinit(self: *TypeEnv, allocator: std.mem.Allocator) void {
        self.symbol_types.deinit();
        self.layouts.deinit();
        self.fn_sigs.deinit();
        self.variant_values.deinit();
        self.expr_types.deinit();
        self.expr_symbols.deinit();
        self.expr_scopes.deinit();
        self.extension_calls.deinit();
        self.generic_call_insts.deinit();
        for (self.generic_instantiations.items) |*gi| gi.expr_types.deinit();
        self.generic_instantiations.deinit(allocator);
        self.generic_struct_templates.deinit();
        self.generic_struct_instances.deinit();
        self.interface_impls.deinit();
        self.diagnostics.deinit(allocator);
    }

    pub fn set(self: *TypeEnv, id: SymbolId, ty: Ty) !void {
        try self.symbol_types.put(id, ty);
    }

    pub fn get(self: TypeEnv, id: SymbolId) ?Ty {
        return self.symbol_types.get(id);
    }
};

pub const TypeArg = struct {
    name: []const u8,
    ty: Ty,
};

pub const GenericInstantiation = struct {
    sym_id: SymbolId,
    fn_name: []const u8,
    mangled_name: []const u8,
    type_args: []const TypeArg,
    /// Per-instantiation expression types filled during checkGenericInstantiation.
    expr_types: std.AutoHashMap(NodeId, Ty),
};

pub fn fromBuiltinName(name: []const u8) ?Ty {
    // Sub-byte integers — stored as u8/i8 in sema; IR uses correct bit width
    if (std.mem.eql(u8, name, "u1")) return .u8;
    if (std.mem.eql(u8, name, "u2")) return .u8;
    if (std.mem.eql(u8, name, "u3")) return .u8;
    if (std.mem.eql(u8, name, "u4")) return .u8;
    if (std.mem.eql(u8, name, "u5")) return .u8;
    if (std.mem.eql(u8, name, "u6")) return .u8;
    if (std.mem.eql(u8, name, "u7")) return .u8;
    if (std.mem.eql(u8, name, "i1")) return .i8;
    if (std.mem.eql(u8, name, "i2")) return .i8;
    if (std.mem.eql(u8, name, "i3")) return .i8;
    if (std.mem.eql(u8, name, "i4")) return .i8;
    if (std.mem.eql(u8, name, "i5")) return .i8;
    if (std.mem.eql(u8, name, "i6")) return .i8;
    if (std.mem.eql(u8, name, "i7")) return .i8;
    if (std.mem.eql(u8, name, "i8")) return .i8;
    if (std.mem.eql(u8, name, "i16")) return .i16;
    if (std.mem.eql(u8, name, "i32")) return .i32;
    if (std.mem.eql(u8, name, "i64")) return .i64;
    if (std.mem.eql(u8, name, "u8")) return .u8;
    if (std.mem.eql(u8, name, "u16")) return .u16;
    if (std.mem.eql(u8, name, "u32")) return .u32;
    if (std.mem.eql(u8, name, "u64")) return .u64;
    if (std.mem.eql(u8, name, "f32")) return .f32;
    if (std.mem.eql(u8, name, "f64")) return .f64;
    if (std.mem.eql(u8, name, "bool")) return .bool;
    if (std.mem.eql(u8, name, "byte")) return .byte;
    if (std.mem.eql(u8, name, "usize")) return .usize;
    if (std.mem.eql(u8, name, "isize")) return .isize;
    if (std.mem.eql(u8, name, "addr")) return .addr;
    if (std.mem.eql(u8, name, "void")) return .void;
    if (std.mem.eql(u8, name, "Text")) return .text;
    if (std.mem.eql(u8, name, "Rune")) return .rune;
    if (std.mem.eql(u8, name, "System")) return .system;
    if (std.mem.eql(u8, name, "FileSys")) return .file_sys;
    if (std.mem.eql(u8, name, "Net")) return .net;
    if (std.mem.eql(u8, name, "Clock")) return .clock;
    if (std.mem.eql(u8, name, "Gpu")) return .gpu;
    if (std.mem.eql(u8, name, "Writer")) return .writer;
    if (std.mem.eql(u8, name, "Reader")) return .reader;
    if (std.mem.eql(u8, name, "Conn")) return .conn;
    if (std.mem.eql(u8, name, "TextBuf")) return .text_buf;
    if (std.mem.eql(u8, name, "Args")) return .args;
    if (std.mem.eql(u8, name, "ThreadPool")) return .thread_pool;
    if (std.mem.eql(u8, name, "Zone")) return .zone_handle;
    return null;
}

pub fn collectSymbols(allocator: std.mem.Allocator, module: ast.Module) SemanticError!SymbolTable {
    var table = try SymbolTable.init(allocator);
    errdefer table.deinit(allocator);

    for (module.items) |item| {
        const name = item.name() orelse continue;
        if (table.resolve(table.root_scope, name) != null) {
            std.debug.print("{s}: error: duplicate top-level declaration `{s}`; module namespaces are not implemented yet\n", .{ item.fileName(), name });
            return error.SemanticFailed;
        }
        const kind: SymbolKind = switch (item) {
            .import => unreachable,
            .const_decl => .const_symbol,
            .type_decl => .type,
            .function => .function,
            .interface_impl => unreachable,
        };
        const id = try table.insert(allocator, table.root_scope, name, kind, item.span(), item.fileName(), item.isPublic());
        const visible = try visibleNamesFor(&table, allocator, item.fileName());
        try visible.put(name, id);
    }

    for (module.items) |item| {
        const imp = switch (item) {
            .import => |value| value,
            else => continue,
        };
        // `compile()` parses one in-memory source and intentionally does not
        // resolve imports. Multi-file and filesystem compilation always set it.
        const target_file = imp.resolved_file orelse continue;
        const visible = try visibleNamesFor(&table, allocator, imp.file_name);

        if (imp.names) |names| {
            for (names) |name| {
                const id = findSymbolInFile(table, target_file, name) orelse {
                    std.debug.print("{s}: error: module `{s}` has no declaration named `{s}`\n", .{ imp.file_name, target_file, name });
                    return error.SemanticFailed;
                };
                const imported = table.symbol(id);
                if (!imported.is_public) {
                    std.debug.print("{s}: error: `{s}` is private to module `{s}`\n", .{ imp.file_name, name, target_file });
                    return error.SemanticFailed;
                }
                try addVisibleName(visible, imp.file_name, name, id);
            }
        } else {
            for (table.symbols.items) |imported| {
                if (!std.mem.eql(u8, imported.file_name, target_file) or !imported.is_public) continue;
                try addVisibleName(visible, imp.file_name, imported.name, imported.id);
            }
        }
    }

    return table;
}

fn visibleNamesFor(
    table: *SymbolTable,
    allocator: std.mem.Allocator,
    file_name: []const u8,
) !*std.StringHashMap(SymbolId) {
    const entry = try table.visible_names.getOrPut(file_name);
    if (!entry.found_existing) entry.value_ptr.* = std.StringHashMap(SymbolId).init(allocator);
    return entry.value_ptr;
}

fn findSymbolInFile(table: SymbolTable, file_name: []const u8, name: []const u8) ?SymbolId {
    for (table.symbols.items) |symbol_value| {
        if (std.mem.eql(u8, symbol_value.file_name, file_name) and std.mem.eql(u8, symbol_value.name, name))
            return symbol_value.id;
    }
    return null;
}

fn addVisibleName(visible: *std.StringHashMap(SymbolId), file_name: []const u8, name: []const u8, id: SymbolId) SemanticError!void {
    if (visible.get(name)) |existing| {
        if (existing != id) {
            std.debug.print("{s}: error: import makes `{s}` ambiguous\n", .{ file_name, name });
            return error.SemanticFailed;
        }
        return;
    }
    try visible.put(name, id);
}

pub fn resolveNames(
    allocator: std.mem.Allocator,
    module: ast.Module,
    symbols: SymbolTable,
) SemanticError!void {
    _ = allocator;
    _ = module;
    _ = symbols;
}

pub fn checkZones(
    allocator: std.mem.Allocator,
    module: ast.Module,
    symbols: SymbolTable,
) SemanticError!void {
    _ = allocator;
    _ = module;
    _ = symbols;
}

pub fn checkTypes(
    allocator: std.mem.Allocator,
    module: ast.Module,
    symbols: SymbolTable,
) SemanticError!TypeEnv {
    return checkTypesWithContext(allocator, module, symbols, "", "");
}

/// Print any diagnostics accumulated in `diags` to stderr, using `source` for
/// the given `file` and the embedded runtime source for "<runtime>".
fn flushDiagnostics(
    allocator: std.mem.Allocator,
    diags: []const Diagnostic,
    source: []const u8,
    file: []const u8,
) void {
    for (diags) |d| {
        const src: []const u8 = if (std.mem.eql(u8, d.file, file)) source else "";
        const rendered = diag_mod.renderDiagnostic(allocator, d.file, src, d) catch continue;
        defer allocator.free(rendered);
        std.debug.print("{s}\n", .{rendered});
    }
}

pub fn checkTypesWithContext(
    allocator: std.mem.Allocator,
    module: ast.Module,
    symbols: SymbolTable,
    source: []const u8,
    file: []const u8,
) SemanticError!TypeEnv {
    var checker = Checker.init(allocator, symbols);
    checker.source = source;
    checker.file = file;
    defer checker.deinit();

    checker.checkModule(module) catch |err| switch (err) {
        error.SemanticFailed => {
            // Diagnostics are still alive here (defer runs after return).
            if (checker.diagnostics.items.len == 0)
                std.debug.print("{s}: error: semantic error (no further details)\n", .{file});
            flushDiagnostics(allocator, checker.diagnostics.items, source, file);
            return error.SemanticFailed;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    // Check each generic instantiation discovered during the main pass.
    // New instantiations may be discovered while checking (e.g. generic calls inside
    // generic bodies), so iterate until stable.
    var checked: usize = 0;
    while (checked < checker.env.generic_instantiations.items.len) {
        checker.checkGenericInstantiation(module, checked) catch |err| switch (err) {
            error.SemanticFailed => {
                if (checker.diagnostics.items.len == 0)
                    std.debug.print("{s}: error: semantic error (no further details)\n", .{file});
                flushDiagnostics(allocator, checker.diagnostics.items, source, file);
                return error.SemanticFailed;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        checked += 1;
    }

    return checker.finish();
}

pub fn mangleGeneric(
    allocator: std.mem.Allocator,
    name: []const u8,
    type_args: []const ast.TypeRef,
) ![]u8 {
    _ = type_args;
    return allocator.dupe(u8, name);
}

const Checker = struct {
    allocator: std.mem.Allocator,
    symbols: SymbolTable,
    env: TypeEnv,
    scope_stack: std.ArrayList(std.StringHashMap(Ty)),
    zone_owner_scopes: std.ArrayList(std.StringHashMap(ZoneOwner)) = .empty,
    active_zones: std.ArrayList(ActiveZone) = .empty,
    current_return_ty: Ty = .void,
    current_error_ty: ?Ty = null,
    loop_depth: usize = 0,
    current_type_params: []const []const u8 = &.{},
    current_type_binding: []const TypeArg = &.{},
    current_self_ty: ?Ty = null,
    unsafe_depth: usize = 0,
    // Diagnostics — collected instead of failing immediately where possible.
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    source: []const u8 = "",
    file: []const u8 = "",

    fn init(allocator: std.mem.Allocator, symbols: SymbolTable) Checker {
        return .{
            .allocator = allocator,
            .symbols = symbols,
            .env = TypeEnv.init(allocator),
            .scope_stack = .empty,
        };
    }

    fn deinit(self: *Checker) void {
        for (self.scope_stack.items) |*s| s.deinit();
        self.scope_stack.deinit(self.allocator);
        for (self.zone_owner_scopes.items) |*s| s.deinit();
        self.zone_owner_scopes.deinit(self.allocator);
        self.active_zones.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
    }

    // ── Diagnostics ──────────────────────────────────────────────────────────

    fn emitWarning(self: *Checker, span: Span, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.diagnostics.append(self.allocator, .{
            .kind = .warning,
            .message = msg,
            .span = span,
            .file = self.file,
        }) catch {};
    }

    fn emitError(self: *Checker, span: Span, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.diagnostics.append(self.allocator, Diagnostic.err(msg, span, self.file)) catch {};
    }

    /// Format a Ty as a human-readable string (caller owns result).
    fn formatTy(self: *Checker, ty: Ty) []const u8 {
        return switch (ty) {
            .i8 => "i8",
            .i16 => "i16",
            .i32 => "i32",
            .i64 => "i64",
            .u8 => "u8",
            .u16 => "u16",
            .u32 => "u32",
            .u64 => "u64",
            .bool => "bool",
            .void => "void",
            .usize => "usize",
            .isize => "isize",
            .f32 => "f32",
            .f64 => "f64",
            .int_lit => "integer literal",
            .float_lit => "float literal",
            .null_ptr => "null",
            .zone_handle => "Zone",
            .error_ty => "error",
            .unknown => "unknown",
            .optional => |inner| std.fmt.allocPrint(self.allocator, "?{s}", .{self.formatTy(inner.*)}) catch "?T",
            .pointer => |inner| std.fmt.allocPrint(self.allocator, "*{s}", .{self.formatTy(inner.*)}) catch "*T",
            .const_ptr => |inner| std.fmt.allocPrint(self.allocator, "*const {s}", .{self.formatTy(inner.*)}) catch "*const T",
            .slice => |inner| std.fmt.allocPrint(self.allocator, "[]{s}", .{self.formatTy(inner.*)}) catch "[]T",
            .borrow => |inner| std.fmt.allocPrint(self.allocator, "borrow {s}", .{self.formatTy(inner.*)}) catch "borrow T",
            .named => |id| self.symbols.symbol(id).name,
            .type_param => |n| n,
            .fallible => |f| std.fmt.allocPrint(self.allocator, "{s} ! error", .{self.formatTy(f.ok.*)}) catch "T!E",
            else => "T",
        };
    }

    fn finish(self: *Checker) TypeEnv {
        var env = self.env;
        // Transfer diagnostics into the TypeEnv so callers can inspect them.
        env.diagnostics = self.diagnostics;
        self.diagnostics = .empty;
        self.env = TypeEnv.init(self.allocator);
        return env;
    }

    fn pushScope(self: *Checker) !void {
        try self.scope_stack.append(self.allocator, std.StringHashMap(Ty).init(self.allocator));
        try self.zone_owner_scopes.append(self.allocator, std.StringHashMap(ZoneOwner).init(self.allocator));
    }

    fn popScope(self: *Checker) void {
        var s = self.scope_stack.pop() orelse return;
        s.deinit();
        var owners = self.zone_owner_scopes.pop().?;
        owners.deinit();
    }

    fn declareLocal(self: *Checker, name: []const u8, ty: Ty) !void {
        const top = &self.scope_stack.items[self.scope_stack.items.len - 1];
        try top.put(name, ty);
    }

    fn lookupLocal(self: Checker, name: []const u8) ?Ty {
        var i = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scope_stack.items[i].get(name)) |ty| return ty;
        }
        return null;
    }

    fn resolveSymbol(self: Checker, name: []const u8) ?SymbolId {
        return self.symbols.resolveVisible(self.file, name);
    }

    fn localScopeIndex(self: Checker, name: []const u8) ?usize {
        var i = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scope_stack.items[i].contains(name)) return i;
        }
        return null;
    }

    fn setLocalZoneOwner(self: *Checker, name: []const u8, owner: ?ZoneOwner) !void {
        const scope_index = self.localScopeIndex(name) orelse return;
        if (owner) |value|
            try self.zone_owner_scopes.items[scope_index].put(name, value)
        else
            _ = self.zone_owner_scopes.items[scope_index].remove(name);
    }

    fn lookupZoneOwner(self: Checker, name: []const u8) ?ZoneOwner {
        var i = self.zone_owner_scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.zone_owner_scopes.items[i].get(name)) |owner| return owner;
        }
        return null;
    }

    fn validateBorrowParam(self: *Checker, ty: Ty, span: Span) SemanticError!void {
        if (ty != .borrow) {
            if (containsBorrow(ty)) {
                self.emitError(span, "`borrow` must be the outer qualifier of a function parameter", .{});
                return error.SemanticFailed;
            }
            return;
        }
        if (containsBorrow(ty.borrow.*)) {
            self.emitError(span, "nested `borrow` qualifiers are not allowed", .{});
            return error.SemanticFailed;
        }
        switch (ty.borrow.*) {
            .pointer, .const_ptr, .slice => {},
            else => {
                self.emitError(span, "`borrow` parameters must be pointers or slices", .{});
                return error.SemanticFailed;
            },
        }
    }

    fn rejectBorrowOutsideParam(self: *Checker, ty: Ty, span: Span) SemanticError!void {
        if (!containsBorrow(ty)) return;
        self.emitError(span, "`borrow` is only valid as the outer qualifier of a function parameter", .{});
        return error.SemanticFailed;
    }

    fn rejectBorrowTypeRefOutsideParam(self: *Checker, ty: ast.TypeRef) SemanticError!void {
        if (!typeRefContainsBorrow(ty)) return;
        self.emitError(ty.span(), "`borrow` is only valid as the outer qualifier of a function parameter", .{});
        return error.SemanticFailed;
    }

    fn checkNonEscapingArgument(self: *Checker, expr: ast.Expr, expected: ?Ty) SemanticError!void {
        const owner = self.exprZoneOwner(expr) orelse return;
        if (expected) |ty| if (ty == .borrow) return;
        const source = if (owner.kind == .borrow) "borrowed value" else "zone-owned value";
        self.emitError(expr.span, "{s} from `{s}` can only be passed to a `borrow` parameter", .{ source, owner.name });
        return error.SemanticFailed;
    }

    fn checkModule(self: *Checker, module: ast.Module) SemanticError!void {
        try self.collectTopLevelTypes(module);

        for (module.items) |item| {
            self.file = item.fileName();
            switch (item) {
                .import => {},
                .const_decl => |decl| _ = try self.inferExpr(decl.value),
                .type_decl => |decl| try self.checkTypeDecl(decl),
                .function => |decl| try self.checkFunction(decl),
                .interface_impl => |impl| try self.checkInterfaceImpl(impl),
            }
        }
    }

    fn collectTopLevelTypes(self: *Checker, module: ast.Module) SemanticError!void {
        for (module.items) |item| {
            self.file = item.fileName();
            if (item == .interface_impl) {
                const impl = item.interface_impl;
                const key = try interfaceImplKey(self.allocator, impl.type_name, impl.interface_name);
                if (self.env.interface_impls.contains(key)) {
                    self.emitError(impl.span, "duplicate `{s} as {s}` implementation", .{ impl.type_name, impl.interface_name });
                    return error.SemanticFailed;
                }
                try self.env.interface_impls.put(key, impl);
                continue;
            }
            const name = item.name() orelse continue;
            const id = self.symbols.resolve(self.symbols.root_scope, name) orelse continue;
            switch (item) {
                .const_decl => |decl| try self.env.set(id, try self.inferExpr(decl.value)),
                .type_decl => |decl| {
                    try self.env.set(id, .{ .named = id });
                    switch (decl.kind) {
                        .struct_type => |strukt| {
                            if (strukt.type_params.len > 0) {
                                // Generic struct — store as template, don't process fields yet.
                                try self.env.generic_struct_templates.put(decl.name, decl);
                                // Register the type name but leave layout empty for now.
                            } else {
                                var fields = std.ArrayList(FieldInfo).empty;
                                errdefer fields.deinit(self.allocator);
                                for (strukt.fields) |field| {
                                    try fields.append(self.allocator, .{
                                        .name = field.name,
                                        .ty = try self.typeFromRef(field.ty),
                                    });
                                }
                                try self.env.layouts.put(id, .{
                                    .kind = .{ .struct_type = try fields.toOwnedSlice(self.allocator) },
                                    .is_packed = hasAttr(decl.attrs, "packed"),
                                });
                            }
                        },
                        .errors => |errors_decl| {
                            try self.env.layouts.put(id, .{
                                .kind = .{ .error_set = try self.errorVariantsFromDecl(errors_decl.variants) },
                                .is_packed = false,
                            });
                        },
                        .enum_type => |enum_decl| {
                            var variants = std.ArrayList(VariantInfo).empty;
                            errdefer variants.deinit(self.allocator);
                            for (enum_decl.variants, 0..) |v, idx| {
                                try variants.append(self.allocator, .{
                                    .name = v.name,
                                    .payload = if (v.payload) |p| try self.typeFromRef(p) else null,
                                    .index = @intCast(idx),
                                });
                            }
                            try self.env.layouts.put(id, .{
                                .kind = .{ .variant_type = try variants.toOwnedSlice(self.allocator) },
                                .is_packed = false,
                            });
                        },
                        .interface_type => |interface_decl| {
                            self.current_self_ty = .{ .named = id };
                            defer self.current_self_ty = null;
                            var methods = std.ArrayList(InterfaceMethodInfo).empty;
                            errdefer methods.deinit(self.allocator);
                            for (interface_decl.methods) |method| {
                                var params = std.ArrayList(ParamSig).empty;
                                errdefer params.deinit(self.allocator);
                                for (method.params) |param| {
                                    const param_ty = try self.typeFromRef(param.ty);
                                    try self.validateBorrowParam(param_ty, param.span);
                                    try params.append(self.allocator, .{
                                        .name = param.name,
                                        .ty = param_ty,
                                    });
                                }
                                const return_ty = try self.typeFromRef(method.return_ty);
                                try self.rejectBorrowOutsideParam(return_ty, method.return_ty.span());
                                try methods.append(self.allocator, .{
                                    .name = method.name,
                                    .params = try params.toOwnedSlice(self.allocator),
                                    .return_ty = return_ty,
                                    .error_ty = if (method.error_ty) |err| try self.typeFromErrorSpec(err) else null,
                                });
                                const first = methods.items[methods.items.len - 1].params;
                                const self_ty = if (first.len > 0 and first[0].ty == .borrow) first[0].ty.borrow.* else if (first.len > 0) first[0].ty else .unknown;
                                const self_inner = switch (self_ty) {
                                    .pointer, .const_ptr => |inner| inner,
                                    else => null,
                                };
                                if (first.len == 0 or self_inner == null or
                                    self_inner.?.* != .named or self_inner.?.named != id)
                                {
                                    self.emitError(method.span, "interface method `{s}` must begin with `self: *Self` or `self: borrow *Self`", .{method.name});
                                    return error.SemanticFailed;
                                }
                            }
                            try self.env.layouts.put(id, .{
                                .kind = .{ .interface_type = try methods.toOwnedSlice(self.allocator) },
                                .is_packed = false,
                            });
                        },
                        else => {},
                    }
                },
                .function => |decl| {
                    // Set type param context so typeFromRef can resolve $T as Ty.type_param
                    self.current_type_params = decl.type_params;
                    defer self.current_type_params = &.{};

                    var params = std.ArrayList(ParamSig).empty;
                    errdefer params.deinit(self.allocator);
                    for (decl.params) |param| {
                        const param_ty = try self.typeFromRef(param.ty);
                        if (!param.is_type_param) try self.validateBorrowParam(param_ty, param.span);
                        try params.append(self.allocator, .{
                            .name = param.name,
                            .ty = param_ty,
                            .is_type_param = param.is_type_param,
                        });
                    }
                    const ret = try self.typeFromRef(decl.return_ty);
                    try self.rejectBorrowOutsideParam(ret, decl.return_ty.span());
                    const err_ty = if (decl.error_ty) |err| try self.typeFromErrorSpec(err) else null;
                    try self.env.fn_sigs.put(id, .{
                        .params = try params.toOwnedSlice(self.allocator),
                        .return_ty = ret,
                        .error_ty = err_ty,
                        .extern_name = externName(decl.attrs),
                        .inline_hint = hasAttr(decl.attrs, "inline"),
                        .no_inline = hasAttr(decl.attrs, "noinline"),
                        .no_return = hasAttr(decl.attrs, "noreturn"),
                        .entry = std.mem.eql(u8, decl.name, "main") or hasAttr(decl.attrs, "entry"),
                        .naked = hasAttr(decl.attrs, "naked"),
                        .export_sym = exportSym(decl.attrs),
                        .deprecated = deprecatedMsg(decl.attrs),
                        .type_params = decl.type_params,
                        .type_constraints = decl.type_constraints,
                        .type_binding = null,
                    });
                    try self.env.set(id, .{ .fn_ptr = .{
                        .params = &.{},
                        .ret = try self.boxTy(if (err_ty) |err| .{ .fallible = .{ .ok = try self.boxTy(ret), .err = try self.boxTy(err) } } else ret),
                    } });
                },
                .import => {},
                .interface_impl => unreachable,
            }
        }
    }

    fn checkTypeDecl(self: *Checker, decl: ast.TypeDecl) SemanticError!void {
        switch (decl.kind) {
            .distinct => |ty| {
                try self.rejectBorrowTypeRefOutsideParam(ty);
                try self.checkType(ty);
            },
            .opaque_type => {},
            .struct_type => |strukt| {
                for (strukt.fields) |field| try self.rejectBorrowTypeRefOutsideParam(field.ty);
                if (strukt.type_params.len > 0) return; // generic — checked on instantiation
                for (strukt.fields) |field| {
                    const field_ty = try self.typeFromRef(field.ty);
                    try self.rejectBorrowOutsideParam(field_ty, field.span);
                }
            },
            .errors => |errors_decl| {
                for (errors_decl.variants) |variant| {
                    if (variant.payload) |payload| {
                        try self.rejectBorrowTypeRefOutsideParam(payload);
                        try self.checkType(payload);
                    }
                }
            },
            .enum_type => |enum_decl| {
                for (enum_decl.variants) |variant| {
                    if (variant.payload) |payload| {
                        try self.rejectBorrowTypeRefOutsideParam(payload);
                        try self.checkType(payload);
                    }
                }
            },
            .interface_type => |interface_decl| {
                const id = self.symbols.resolve(self.symbols.root_scope, decl.name) orelse return error.SemanticFailed;
                self.current_self_ty = .{ .named = id };
                defer self.current_self_ty = null;
                for (interface_decl.methods) |method| {
                    for (method.params) |param| try self.checkType(param.ty);
                    try self.checkType(method.return_ty);
                }
            },
        }
    }

    fn checkInterfaceImpl(self: *Checker, impl: ast.InterfaceImpl) SemanticError!void {
        const concrete_id = self.resolveSymbol(impl.type_name) orelse return error.SemanticFailed;
        const interface_id = self.resolveSymbol(impl.interface_name) orelse return error.SemanticFailed;
        const layout = self.env.layouts.get(interface_id) orelse return error.SemanticFailed;
        const required = switch (layout.kind) {
            .interface_type => |methods| methods,
            else => {
                self.emitError(impl.span, "`{s}` is not an interface", .{impl.interface_name});
                return error.SemanticFailed;
            },
        };
        self.current_self_ty = .{ .named = concrete_id };
        defer self.current_self_ty = null;

        for (required) |required_method| {
            const method = for (impl.methods) |candidate| {
                if (std.mem.eql(u8, candidate.name, required_method.name)) break candidate;
            } else {
                self.emitError(impl.span, "missing interface method `{s}`", .{required_method.name});
                return error.SemanticFailed;
            };
            if (method.params.len != required_method.params.len) return error.SemanticFailed;
            for (method.params, required_method.params) |actual, expected| {
                const actual_ty = try self.typeFromRef(actual.ty);
                const expected_ty = try substituteInterfaceSelf(self, expected.ty, interface_id, concrete_id);
                if (!sameTy(actual_ty, expected_ty)) {
                    self.emitError(actual.span, "signature mismatch for interface method `{s}`", .{method.name});
                    return error.SemanticFailed;
                }
            }
            const actual_ret = try self.typeFromRef(method.return_ty);
            const expected_ret = try substituteInterfaceSelf(self, required_method.return_ty, interface_id, concrete_id);
            if (!sameTy(actual_ret, expected_ret)) return error.SemanticFailed;
            try self.checkFunction(method);
        }
        for (impl.methods) |method| {
            var found = false;
            for (required) |req| if (std.mem.eql(u8, method.name, req.name)) {
                found = true;
                break;
            };
            if (!found) {
                self.emitError(method.span, "method `{s}` is not declared by interface `{s}`", .{ method.name, impl.interface_name });
                return error.SemanticFailed;
            }
        }
    }

    fn checkFunction(self: *Checker, decl: ast.FunctionDecl) SemanticError!void {
        const previous_file = self.file;
        self.file = decl.file_name;
        defer self.file = previous_file;

        // Generic functions with unbound type params are checked per-instantiation, not here.
        if (decl.type_params.len > 0 and self.current_type_binding.len == 0) return;

        self.current_type_params = decl.type_params;
        defer self.current_type_params = &.{};

        self.current_return_ty = try self.typeFromRef(decl.return_ty);
        try self.rejectBorrowOutsideParam(self.current_return_ty, decl.return_ty.span());
        self.current_error_ty = if (decl.error_ty) |err| try self.typeFromErrorSpec(err) else null;
        try self.pushScope();
        defer self.popScope();

        for (decl.params) |param| {
            if (param.is_type_param) continue; // type-only params aren't values in scope
            const param_ty = try self.typeFromRef(param.ty);
            try self.validateBorrowParam(param_ty, param.span);
            if (param_ty == .borrow) {
                if (decl.body == null) {
                    self.emitError(param.span, "`borrow` parameters require a checked function body", .{});
                    return error.SemanticFailed;
                }
                try self.declareLocal(param.name, param_ty.borrow.*);
                try self.setLocalZoneOwner(param.name, .{
                    .name = param.name,
                    .scope_depth = 0,
                    .kind = .borrow,
                });
            } else {
                try self.declareLocal(param.name, param_ty);
            }
        }

        if (decl.body) |body| {
            try self.checkBlock(body);
            // #noreturn functions are allowed to not have explicit returns.
            const is_noreturn = hasAttr(decl.attrs, "noreturn");
            if (!is_noreturn and
                (self.current_return_ty != .void or self.current_error_ty != null) and
                !blockDefinitelyReturns(body))
            {
                return error.SemanticFailed;
            }
        }
    }

    fn checkBlock(self: *Checker, block: ast.Block) SemanticError!void {
        try self.pushScope();
        defer self.popScope();
        for (block.statements) |stmt| try self.checkStmt(stmt);
    }

    fn checkStmt(self: *Checker, stmt: ast.Stmt) SemanticError!void {
        switch (stmt) {
            .local_infer => |local| {
                const local_ty = try self.inferExpr(local.value);
                try self.declareLocal(local.name, local_ty);
                try self.setLocalZoneOwner(local.name, self.exprZoneOwner(local.value));
            },
            .local_typed => |local| {
                const declared_ty = try self.typeFromRef(local.ty);
                try self.rejectBorrowOutsideParam(declared_ty, local.ty.span());
                const value_ty = try self.inferExpr(local.value);
                if (!try self.compatible(value_ty, declared_ty)) return error.SemanticFailed;
                try self.declareLocal(local.name, declared_ty);
                try self.setLocalZoneOwner(local.name, self.exprZoneOwner(local.value));
            },
            .assign => |assign| {
                try self.checkAssignTarget(assign.target);
                const target_ty = try self.inferExpr(assign.target);
                const value_ty = try self.inferExpr(assign.value);
                if (!try self.compatible(value_ty, target_ty)) return error.SemanticFailed;
                if (self.exprZoneOwner(assign.value)) |owner| {
                    if (assign.target.kind != .ident) {
                        const source = if (owner.kind == .borrow) "borrowed value" else "zone-owned value";
                        self.emitError(assign.span, "{s} from `{s}` cannot be stored into an aggregate or pointer", .{ source, owner.name });
                        return error.SemanticFailed;
                    }
                    const target_name = assign.target.kind.ident;
                    const target_scope = self.localScopeIndex(target_name) orelse 0;
                    if (target_scope < owner.scope_depth) {
                        self.emitError(assign.span, "zone-owned value from `{s}` cannot escape its zone", .{owner.name});
                        return error.SemanticFailed;
                    }
                    try self.setLocalZoneOwner(target_name, owner);
                } else if (assign.target.kind == .ident) {
                    try self.setLocalZoneOwner(assign.target.kind.ident, null);
                }
            },
            .return_stmt => |ret| {
                const actual_ty: Ty = if (ret.value) |value| try self.inferExpr(value) else .void;
                if (ret.value) |value| if (self.exprZoneOwner(value)) |owner| {
                    const source = if (owner.kind == .borrow) "borrowed value" else "zone-owned value";
                    self.emitError(ret.span, "{s} from `{s}` cannot be returned", .{ source, owner.name });
                    return error.SemanticFailed;
                };
                if (!try self.compatible(actual_ty, self.current_return_ty)) {
                    self.emitError(ret.span, "return type mismatch: expected `{s}`, found `{s}`", .{ self.formatTy(self.current_return_ty), self.formatTy(actual_ty) });
                    return error.SemanticFailed;
                }
            },
            .fail_stmt => |fail| try self.checkFail(fail),
            .if_stmt => |iff| {
                if (iff.binding) |binding| {
                    const bound_ty = try self.inferExpr(binding.value);
                    if (bound_ty != .optional) {
                        self.emitError(binding.value.span, "`if {s} :=` requires an optional type, found `{s}`", .{ binding.name, self.formatTy(bound_ty) });
                        return error.SemanticFailed;
                    }
                    const inner_ty = bound_ty.optional.*;
                    try self.pushScope();
                    defer self.popScope();
                    try self.declareLocal(binding.name, inner_ty);
                    const owner = self.exprZoneOwner(binding.value);
                    try self.setLocalZoneOwner(binding.name, owner);
                    if (iff.payload_binding) |payload_name| {
                        try self.declareLocal(payload_name, inner_ty);
                        try self.setLocalZoneOwner(payload_name, owner);
                    }
                    try self.checkBlock(iff.then_block);
                } else {
                    const cond_ty = try self.inferExpr(iff.condition);
                    const payload_ty: ?Ty = switch (cond_ty) {
                        .optional => |inner| inner.*,
                        else => null,
                    };
                    if (!cond_ty.isBool() and payload_ty == null) return error.SemanticFailed;
                    try self.pushScope();
                    defer self.popScope();
                    if (iff.payload_binding) |payload_name| {
                        try self.declareLocal(payload_name, payload_ty orelse .unknown);
                        try self.setLocalZoneOwner(payload_name, self.exprZoneOwner(iff.condition));
                    }
                    try self.checkBlock(iff.then_block);
                }
                if (iff.else_block) |else_block| try self.checkBlock(else_block);
            },
            .while_stmt => |while_stmt| {
                const cond_ty = try self.inferExpr(while_stmt.condition);
                if (!cond_ty.isBool()) return error.SemanticFailed;
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                try self.checkBlock(while_stmt.body);
            },
            .for_range => |for_stmt| {
                const start_ty = try self.inferExpr(for_stmt.start);
                const end_ty = try self.inferExpr(for_stmt.end);
                if (!start_ty.isInteger() or !end_ty.isInteger() or
                    !try self.compatible(end_ty, start_ty))
                {
                    self.emitError(for_stmt.span, "range bounds must have compatible integer types", .{});
                    return error.SemanticFailed;
                }
                try self.pushScope();
                defer self.popScope();
                try self.declareLocal(for_stmt.binding, start_ty);
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                try self.checkBlock(for_stmt.body);
            },
            .for_slice => |for_stmt| {
                const iter_ty = try self.inferExpr(for_stmt.iter);
                const elem_ty = switch (iter_ty) {
                    .slice => |elem| elem.*,
                    .array => |array| array.elem.*,
                    else => {
                        self.emitError(for_stmt.iter.span, "for loop requires a slice or array", .{});
                        return error.SemanticFailed;
                    },
                };
                try self.pushScope();
                defer self.popScope();
                try self.declareLocal(for_stmt.binding, if (for_stmt.by_ref) try self.ptrTo(elem_ty) else elem_ty);
                if (for_stmt.by_ref) try self.setLocalZoneOwner(for_stmt.binding, self.exprZoneOwner(for_stmt.iter));
                if (for_stmt.index_binding) |name| try self.declareLocal(name, .usize);
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                try self.checkBlock(for_stmt.body);
            },
            .unsafe_block => |unsafe_block| {
                self.unsafe_depth += 1;
                defer self.unsafe_depth -= 1;
                try self.checkBlock(unsafe_block);
            },
            .break_stmt => |span| if (self.loop_depth == 0) {
                self.emitError(span, "`break` outside of a loop", .{});
                return error.SemanticFailed;
            },
            .continue_stmt => |span| if (self.loop_depth == 0) {
                self.emitError(span, "`continue` outside of a loop", .{});
                return error.SemanticFailed;
            },
            .zone_block => |zb| {
                if (!std.mem.eql(u8, zb.kind, "Arena")) {
                    self.emitError(zb.span, "unsupported zone kind `{s}`; only `Arena` is currently defined", .{zb.kind});
                    return error.SemanticFailed;
                }
                for (self.active_zones.items) |zone| {
                    if (std.mem.eql(u8, zone.name, zb.name)) {
                        self.emitError(zb.span, "nested zone name `{s}` shadows an active zone", .{zb.name});
                        return error.SemanticFailed;
                    }
                }
                try self.pushScope();
                defer self.popScope();
                try self.declareLocal(zb.name, .zone_handle);
                try self.active_zones.append(self.allocator, .{
                    .name = zb.name,
                    .scope_depth = self.scope_stack.items.len - 1,
                });
                defer _ = self.active_zones.pop();
                try self.checkBlock(zb.body);
            },
            .defer_stmt => |ds| try self.checkBlock(ds.body),
            .match_stmt => |m| try self.checkMatch(m),
            .comptime_if => |ci| try self.checkComptimeIf(ci),
            .comptime_run => |block| {
                // Type-check the block for correctness even if we don't execute it yet.
                try self.checkBlock(block);
            },
            .expr => |expr| try self.checkExpr(expr),
        }
    }

    fn checkExpr(self: *Checker, expr: ast.Expr) SemanticError!void {
        _ = try self.inferExpr(expr);
    }

    fn inferExpr(self: *Checker, expr: ast.Expr) SemanticError!Ty {
        const ty: Ty = switch (expr.kind) {
            .ident => |name| {
                // Compile-time pseudo-modules return unknown so field access works.
                if (std.mem.eql(u8, name, "TARGET")) return .unknown;
                if (isBuiltinValue(name)) return .void;
                if (std.mem.startsWith(u8, name, ".")) return .error_ty;
                if (self.lookupLocal(name)) |local_ty| return local_ty;
                if (self.resolveTypeParam(name)) |type_param_ty| return type_param_ty;
                if (self.resolveSymbol(name)) |id| {
                    try self.env.expr_symbols.put(expr.id, id);
                    return self.env.get(id) orelse .{ .named = id };
                }
                if (fromBuiltinName(name)) |builtin_ty| return builtin_ty;
                self.emitError(expr.span, "unknown name `{s}`", .{name});
                return error.SemanticFailed;
            },
            .unsafe_expr => |inner| blk: {
                self.unsafe_depth += 1;
                defer self.unsafe_depth -= 1;
                break :blk try self.inferExpr(inner.*);
            },
            .run_expr => |inner| try self.inferRunExpr(inner.*),
            .force_unwrap => |inner| blk: {
                const ty = try self.inferExpr(inner.*);
                break :blk switch (ty) {
                    .optional => |p| p.*,
                    .fallible => |f| f.ok.*,
                    else => {
                        self.emitError(expr.span, "`!!` requires an optional or fallible type, found `{s}`", .{self.formatTy(ty)});
                        return error.SemanticFailed;
                    },
                };
            },
            .nil_coalesce => |nc| blk: {
                const lhs_ty = try self.inferExpr(nc.value.*);
                const inner_ty: Ty = switch (lhs_ty) {
                    .optional => |p| p.*,
                    .fallible => |f| f.ok.*,
                    else => {
                        self.emitError(nc.value.span, "`??` requires an optional or fallible left-hand side, found `{s}`", .{self.formatTy(lhs_ty)});
                        return error.SemanticFailed;
                    },
                };
                const default_ty = try self.inferExpr(nc.default.*);
                if (!try self.compatible(default_ty, inner_ty)) {
                    self.emitError(nc.default.span, "`??` default type `{s}` incompatible with `{s}`", .{ self.formatTy(default_ty), self.formatTy(inner_ty) });
                    return error.SemanticFailed;
                }
                break :blk inner_ty;
            },
            .as_cast => |cast| blk: {
                const from_ty = try self.inferExpr(cast.value.*);
                const to_ty = try self.typeFromRef(cast.to);
                if (try self.interfaceCoercion(from_ty, to_ty)) break :blk to_ty;
                const pointer_cast = isPointerTy(from_ty) or isPointerTy(to_ty);
                const valid = (from_ty.isNumeric() and to_ty.isNumeric()) or
                    (from_ty.isInteger() and to_ty == .bool) or
                    (from_ty == .bool and to_ty.isInteger()) or
                    (pointer_cast and (isPointerTy(from_ty) or from_ty.isInteger()) and
                        (isPointerTy(to_ty) or to_ty.isInteger()));
                if (!valid) {
                    self.emitError(expr.span, "cannot cast `{s}` to `{s}`", .{
                        self.formatTy(from_ty), self.formatTy(to_ty),
                    });
                    return error.SemanticFailed;
                }
                if (pointer_cast) try self.requireUnsafe(expr.span, "pointer cast");
                break :blk to_ty;
            },
            .type_ref => |type_ref| try self.typeFromRef(type_ref),
            .int => |text| intLiteralType(text),
            .float => |text| floatLiteralType(text),
            .string => try self.sliceOf(.u8),
            .bool => .bool,
            .null => .null_ptr,
            .compound_literal => |values| blk: {
                for (values) |value| _ = try self.inferExpr(value);
                break :blk .unknown;
            },
            .unary => |unary| switch (unary.op) {
                .address_of => try self.ptrTo(try self.inferExpr(unary.expr.*)),
                .deref => blk: {
                    const inner = try self.inferExpr(unary.expr.*);
                    break :blk switch (inner) {
                        .pointer, .const_ptr => |p| p.*,
                        .slice => |p| p.*,
                        else => return error.SemanticFailed,
                    };
                },
                .neg => try self.inferExpr(unary.expr.*),
                .not => blk: {
                    const inner = try self.inferExpr(unary.expr.*);
                    if (!inner.isBool()) return error.SemanticFailed;
                    break :blk .bool;
                },
                .bit_not => blk: {
                    const inner = try self.inferExpr(unary.expr.*);
                    if (!inner.isInteger()) return error.SemanticFailed;
                    break :blk inner;
                },
            },
            .binary => |binary| blk: {
                const left = try self.inferExpr(binary.left.*);
                const right = try self.inferExpr(binary.right.*);
                break :blk switch (binary.op) {
                    .equal, .not_equal => if ((left.isNumeric() and right.isNumeric()) or left == .error_ty or right == .error_ty or try self.compatible(left, right) or try self.compatible(right, left)) .bool else return error.SemanticFailed,
                    .less, .le, .gt, .ge => if (left.isNumeric() and right.isNumeric()) .bool else return error.SemanticFailed,
                    .and_and, .or_or => if (left.isBool() and right.isBool()) .bool else return error.SemanticFailed,
                    .bit_and, .bit_or, .bit_xor => if (left.isInteger() and right.isInteger()) left else return error.SemanticFailed,
                    .shl, .shr => if (left.isInteger() and right.isInteger()) left else return error.SemanticFailed,
                    .add, .sub => if (left.isNumeric() and right.isNumeric()) left else return error.SemanticFailed,
                    .mul, .div, .rem => if (left.isNumeric() and right.isNumeric()) left else return error.SemanticFailed,
                };
            },
            .try_expr => |try_expr| blk: {
                const value_ty = try self.inferExpr(try_expr.value.*);
                if (self.current_error_ty == null) return error.SemanticFailed;
                break :blk switch (value_ty) {
                    .fallible => |fallible| blk2: {
                        if (!try self.compatible(fallible.err.*, self.current_error_ty.?)) return error.SemanticFailed;
                        break :blk2 fallible.ok.*;
                    },
                    else => return error.SemanticFailed,
                };
            },
            .catch_expr => |catch_expr| blk: {
                const value_ty = try self.inferExpr(catch_expr.value.*);
                const fallible = switch (value_ty) {
                    .fallible => |f| f,
                    else => return error.SemanticFailed,
                };
                try self.pushScope();
                defer self.popScope();
                try self.declareLocal(catch_expr.err_name, fallible.err.*);
                try self.checkBlock(catch_expr.handler);
                break :blk fallible.ok.*;
            },
            .call => |call| blk: {
                const call_ty = try self.inferCall(call);
                for (call.args) |arg| switch (arg) {
                    .positional => |value| _ = try self.inferExpr(value),
                    .named => |named| _ = try self.inferExpr(named.value),
                };
                break :blk call_ty;
            },
            .field => |field| blk: {
                const base_ty = try self.inferExpr(field.base.*);
                if (std.mem.eql(u8, field.name, "len")) break :blk .usize;
                if (std.mem.eql(u8, field.name, "ptr")) break :blk switch (base_ty) {
                    .slice => |inner| try self.ptrTo(inner.*),
                    .array => |array| try self.ptrTo(array.elem.*),
                    else => return error.SemanticFailed,
                };
                if (base_ty == .fallible) {
                    if (std.mem.eql(u8, field.name, "ok")) break :blk base_ty.fallible.ok.*;
                    if (std.mem.eql(u8, field.name, "err")) break :blk base_ty.fallible.err.*;
                }
                break :blk try self.fieldType(base_ty, field.name);
            },
            .index => |index| blk: {
                const base_ty = try self.inferExpr(index.base.*);
                _ = try self.inferExpr(index.index.*);
                break :blk switch (base_ty) {
                    .array => |array| array.elem.*,
                    .slice => |inner| inner.*,
                    .pointer, .const_ptr => |inner| inner.*,
                    .unknown => .unknown,
                    else => return error.SemanticFailed,
                };
            },
            .slice => |slice| blk: {
                const base_ty = try self.inferExpr(slice.base.*);
                if (slice.start) |start| _ = try self.inferExpr(start.*);
                if (slice.end) |end| _ = try self.inferExpr(end.*);
                break :blk switch (base_ty) {
                    .array => |array| .{ .slice = array.elem },
                    .slice => base_ty,
                    else => return error.SemanticFailed,
                };
            },
        };
        try self.env.expr_types.put(expr.id, ty);
        return ty;
    }

    fn inferCall(self: *Checker, call: ast.CallExpr) SemanticError!Ty {
        // Detect zone method calls: zone_var.new(T), zone_var.new_slice(T, n), zone_var.free(ptr)
        if (call.callee.kind == .field) {
            const fld = call.callee.kind.field;
            const base_ty = try self.inferExpr(fld.base.*);
            if (base_ty == .zone_handle) {
                // Mark the callee field-expr so the IR lowerer can detect zone calls
                // by checking call.callee.id rather than chasing base pointer ids.
                try self.env.expr_types.put(call.callee.id, .zone_handle);
                if (std.mem.eql(u8, fld.name, "free") and call.args.len > 0) {
                    const zone_name = switch (fld.base.kind) {
                        .ident => |name| name,
                        else => return error.SemanticFailed,
                    };
                    const ptr_expr = switch (call.args[0]) {
                        .positional => |value| value,
                        .named => |named| named.value,
                    };
                    const owner = self.exprZoneOwner(ptr_expr) orelse {
                        self.emitError(ptr_expr.span, "`{s}.free` requires a value owned by that arena", .{zone_name});
                        return error.SemanticFailed;
                    };
                    if (owner.kind == .borrow) {
                        self.emitError(ptr_expr.span, "borrowed value from `{s}` cannot be explicitly freed", .{owner.name});
                        return error.SemanticFailed;
                    }
                    if (!std.mem.eql(u8, owner.name, zone_name)) {
                        self.emitError(ptr_expr.span, "value is owned by zone `{s}`, not `{s}`", .{ owner.name, zone_name });
                        return error.SemanticFailed;
                    }
                }
                return self.inferZoneMethod(fld.name, call.args);
            }
            if (self.interfaceFromPointer(base_ty)) |interface_id| {
                if (self.findInterfaceMethod(interface_id, fld.name)) |method| {
                    if (method.params.len == 0 or call.args.len != method.params.len - 1) {
                        const expected_count = if (method.params.len > 0) method.params.len - 1 else 0;
                        self.emitError(call.callee.span, "`{s}` expects {d} argument(s)", .{ fld.name, expected_count });
                        return error.SemanticFailed;
                    }
                    try self.checkNonEscapingArgument(fld.base.*, method.params[0].ty);
                    for (call.args, 0..) |arg, i| {
                        const arg_expr = switch (arg) {
                            .positional => |value| value,
                            .named => |named| named.value,
                        };
                        try self.checkNonEscapingArgument(arg_expr, method.params[i + 1].ty);
                        if (!try self.compatible(try self.inferExpr(arg_expr), method.params[i + 1].ty))
                            return error.SemanticFailed;
                    }
                    try self.env.expr_types.put(call.callee.id, .{ .fn_ptr = .{
                        .params = &.{},
                        .ret = try self.boxTy(method.return_ty),
                    } });
                    if (method.error_ty) |err_ty| {
                        return .{ .fallible = .{ .ok = try self.boxTy(method.return_ty), .err = try self.boxTy(err_ty) } };
                    }
                    return method.return_ty;
                }
            }
            if (self.resolveExtensionMethod(fld.name)) |extension| {
                try self.env.extension_calls.put(call.callee.id, extension.id);
                const extension_call = try self.extensionCall(call, fld.base.*, extension.sig);
                if (extension.sig.type_params.len > 0) {
                    return try self.inferGenericCall(extension.id, fld.name, extension.sig, extension_call);
                }
                return try self.inferDirectCall(extension.id, fld.name, extension.sig, extension_call);
            }
            if (!extensionLookupDeferred(base_ty)) {
                self.emitError(call.callee.span, "no visible method or extension function `{s}`", .{fld.name});
                return error.SemanticFailed;
            }
        }

        const name = switch (call.callee.kind) {
            .ident => |n| n,
            else => return .unknown,
        };

        // ── Builtins ────────────────────────────────────────────────────
        if (isBuiltinValue(name)) for (call.args) |arg| {
            const value = switch (arg) {
                .positional => |positional| positional,
                .named => |named| named.value,
            };
            try self.checkNonEscapingArgument(value, null);
        };
        if (std.mem.eql(u8, name, "truncate_to")) return self.firstTypeArg(call) orelse error.SemanticFailed;
        if (std.mem.eql(u8, name, "sizeof")) return .usize;
        if (std.mem.eql(u8, name, "atomic_load")) return .u32;
        // Reflection builtins: only meaningful inside compile-time contexts
        // (#run / #if), where the comptime interpreter produces a concrete
        // value. Their static type is deferred, like the TARGET pseudo-module.
        if (std.mem.eql(u8, name, "type_name")) return try self.sliceOf(.u8);
        if (std.mem.eql(u8, name, "type_info")) return .unknown;
        // Unsafe builtins — must be called from within an `unsafe` block.
        if (std.mem.eql(u8, name, "ptr_from_int")) {
            try self.requireUnsafe(call.callee.span, name);
            return self.firstTypeArg(call) orelse error.SemanticFailed;
        }
        if (std.mem.eql(u8, name, "volatile_store")) {
            try self.requireUnsafe(call.callee.span, name);
            return .void;
        }
        if (std.mem.eql(u8, name, "unaligned_read")) {
            try self.requireUnsafe(call.callee.span, name);
            return self.firstTypeArg(call) orelse error.SemanticFailed;
        }
        if (std.mem.eql(u8, name, "asm")) {
            try self.requireUnsafe(call.callee.span, name);
            // Infer return type from first output constraint, e.g. outputs: { "=a"(isize) }
            for (call.args) |arg| {
                const n = switch (arg) {
                    .named => |n| n,
                    else => continue,
                };
                if (!std.mem.eql(u8, n.name, "outputs")) continue;
                const items = switch (n.value.kind) {
                    .compound_literal => |c| c,
                    else => continue,
                };
                if (items.len == 0) break;
                const first = items[0];
                if (first.kind != .call) break;
                const c_args = first.kind.call.args;
                if (c_args.len == 0) break;
                const ty_expr = switch (c_args[0]) {
                    .positional => |e| e,
                    .named => |nn| nn.value,
                };
                return try self.inferTypeArg(ty_expr);
            }
            return .void;
        }

        const id = self.resolveSymbol(name) orelse {
            // Maybe it's a local function-pointer variable.
            if (self.lookupLocal(name)) |local_ty| switch (local_ty) {
                .fn_ptr => |fp| {
                    for (call.args, 0..) |arg, i| {
                        const arg_expr = switch (arg) {
                            .positional => |e| e,
                            .named => |n| n.value,
                        };
                        const expected = if (i < fp.params.len) fp.params[i] else null;
                        try self.checkNonEscapingArgument(arg_expr, expected);
                        const arg_ty = try self.inferExpr(arg_expr);
                        if (i < fp.params.len and !try self.compatible(arg_ty, fp.params[i]))
                            return error.SemanticFailed;
                    }
                    return fp.ret.*;
                },
                else => {},
            };
            self.emitError(call.callee.span, "unknown function `{s}`", .{name});
            return error.SemanticFailed;
        };
        if (self.symbols.symbol(id).kind != .function) {
            self.emitError(call.callee.span, "`{s}` is not a function", .{name});
            return error.SemanticFailed;
        }
        const sig = self.env.fn_sigs.get(id) orelse return error.SemanticFailed;

        // Generic call: infer type binding and record instantiation
        if (sig.type_params.len > 0) {
            return try self.inferGenericCall(id, name, sig, call);
        }

        return try self.inferDirectCall(id, name, sig, call);
    }

    const ExtensionMethod = struct {
        id: SymbolId,
        sig: FnSig,
    };

    fn resolveExtensionMethod(self: *Checker, name: []const u8) ?ExtensionMethod {
        const id = self.resolveSymbol(name) orelse return null;
        if (self.symbols.symbol(id).kind != .function) return null;
        const sig = self.env.fn_sigs.get(id) orelse return null;
        for (sig.params) |param| {
            if (param.is_type_param) continue;
            if (!std.mem.eql(u8, param.name, "self")) return null;
            return .{ .id = id, .sig = sig };
        }
        return null;
    }

    fn extensionLookupDeferred(ty: Ty) bool {
        return switch (ty) {
            .unknown, .type_param => true,
            .pointer, .const_ptr, .borrow => |inner| extensionLookupDeferred(inner.*),
            else => false,
        };
    }

    fn extensionCall(self: *Checker, call: ast.CallExpr, receiver: ast.Expr, sig: FnSig) SemanticError!ast.CallExpr {
        var args = std.ArrayList(ast.CallArg).empty;
        errdefer args.deinit(self.allocator);

        var source_index: usize = 0;
        var inserted_receiver = false;
        for (sig.params) |param| {
            if (param.is_type_param) {
                const constrained = for (sig.type_constraints) |constraint| {
                    if (std.mem.eql(u8, constraint.param, param.name)) break true;
                } else false;
                if (constrained) continue;
            } else if (!inserted_receiver) {
                try args.append(self.allocator, .{ .positional = receiver });
                inserted_receiver = true;
                continue;
            }

            if (source_index >= call.args.len) break;
            try args.append(self.allocator, call.args[source_index]);
            source_index += 1;
        }
        while (source_index < call.args.len) : (source_index += 1) {
            try args.append(self.allocator, call.args[source_index]);
        }

        return .{
            .callee = call.callee,
            .args = try args.toOwnedSlice(self.allocator),
        };
    }

    fn inferDirectCall(self: *Checker, id: SymbolId, name: []const u8, sig: FnSig, call: ast.CallExpr) SemanticError!Ty {
        _ = id;
        // Count only value params for arg matching
        var value_param_count: usize = 0;
        for (sig.params) |p| {
            if (!p.is_type_param) value_param_count += 1;
        }
        if (call.args.len != value_param_count) {
            self.emitError(call.callee.span, "`{s}` expects {d} argument(s), but {d} were provided", .{ name, value_param_count, call.args.len });
            return error.SemanticFailed;
        }

        var arg_i: usize = 0;
        for (sig.params) |param| {
            if (param.is_type_param) continue;
            const arg_expr = switch (call.args[arg_i]) {
                .positional => |e| e,
                .named => |n| n.value,
            };
            try self.checkNonEscapingArgument(arg_expr, param.ty);
            const arg_ty = try self.inferExpr(arg_expr);
            if (!try self.compatible(arg_ty, param.ty)) {
                self.emitError(arg_expr.span, "argument {d} of `{s}`: expected `{s}`, found `{s}`", .{ arg_i + 1, name, self.formatTy(param.ty), self.formatTy(arg_ty) });
                return error.SemanticFailed;
            }
            arg_i += 1;
        }
        // Emit a warning when calling a deprecated function.
        if (sig.deprecated) |msg| {
            if (msg.len > 0) {
                self.emitWarning(call.callee.span, "`{s}` is deprecated: {s}", .{ name, msg });
            } else {
                self.emitWarning(call.callee.span, "`{s}` is deprecated", .{name});
            }
        }

        if (sig.error_ty) |err_ty| {
            return .{ .fallible = .{ .ok = try self.boxTy(sig.return_ty), .err = try self.boxTy(err_ty) } };
        }
        return sig.return_ty;
    }

    fn checkComptimeIf(self: *Checker, ci: ast.ComptimeIfStmt) SemanticError!void {
        // Evaluate the condition at compile time.
        // Type-check both branches regardless of condition — eliminates the need
        // for a fully working comptime evaluator just to check #if blocks.
        // The evaluator will be used to select the live branch at IR lowering time.
        _ = try self.inferExpr(ci.condition);
        try self.checkBlock(ci.then_block);
        if (ci.else_block) |eb| try self.checkBlock(eb);
    }

    fn inferRunExpr(self: *Checker, inner: ast.Expr) SemanticError!Ty {
        // Type-check the inner expression normally — the type IS the comptime result type.
        return try self.inferExpr(inner);
    }

    fn checkMatch(self: *Checker, m: ast.MatchStmt) SemanticError!void {
        const subject_ty = try self.inferExpr(m.subject);

        if (subject_ty.isInteger()) return self.checkIntMatch(m, subject_ty);

        const enum_id: SymbolId = switch (subject_ty) {
            .named => |id| id,
            else => return self.invalidMatchSubject(m.subject.span),
        };
        const layout = self.env.layouts.get(enum_id) orelse return error.SemanticFailed;
        const variants = switch (layout.kind) {
            .variant_type => |v| v,
            else => return self.invalidMatchSubject(m.subject.span),
        };

        for (m.arms) |arm| {
            const variant_name = switch (arm.pattern) {
                .else_arm => {
                    try self.checkBlock(arm.body);
                    continue;
                },
                .enum_variant => |name| name,
                .int_values => {
                    self.emitError(arm.span, "integer pattern cannot be used with an enum match subject", .{});
                    return error.SemanticFailed;
                },
            };
            // Find variant in the enum layout.
            var found: ?VariantInfo = null;
            for (variants) |v| {
                if (std.mem.eql(u8, v.name, variant_name)) {
                    found = v;
                    break;
                }
            }
            const variant = found orelse {
                self.emitError(arm.span, "unknown variant `.{s}` in match", .{variant_name});
                return error.SemanticFailed;
            };

            // Push scope with optional payload binding.
            if (arm.binding) |bname| {
                const payload_ty = variant.payload orelse .void;
                try self.pushScope();
                defer self.popScope();
                try self.declareLocal(bname, payload_ty);
                try self.checkBlock(arm.body);
            } else {
                try self.checkBlock(arm.body);
            }
        }
    }

    fn checkIntMatch(self: *Checker, m: ast.MatchStmt, subject_ty: Ty) SemanticError!void {
        for (m.arms) |arm| {
            if (arm.binding != null) {
                self.emitError(arm.span, "integer match patterns cannot bind a payload", .{});
                return error.SemanticFailed;
            }
            switch (arm.pattern) {
                .else_arm => try self.checkBlock(arm.body),
                .enum_variant => {
                    self.emitError(arm.span, "enum variant pattern cannot be used with an integer match subject", .{});
                    return error.SemanticFailed;
                },
                .int_values => |values| {
                    for (values) |value| {
                        const value_ty = try self.inferExpr(value);
                        if (!try self.compatible(value_ty, subject_ty)) {
                            self.emitError(value.span, "integer match pattern is incompatible with subject type `{s}`", .{self.formatTy(subject_ty)});
                            return error.SemanticFailed;
                        }
                    }
                    try self.checkBlock(arm.body);
                },
            }
        }
    }

    fn invalidMatchSubject(self: *Checker, span: Span) SemanticError {
        self.emitError(span, "match subject must be an enum or integer type", .{});
        return error.SemanticFailed;
    }

    fn requireUnsafe(self: *Checker, span: Span, builtin_name: []const u8) SemanticError!void {
        if (self.unsafe_depth == 0) {
            self.emitError(span, "`{s}` is an unsafe operation and must be called inside an `unsafe` block", .{builtin_name});
            return error.SemanticFailed;
        }
    }

    fn inferZoneMethod(self: *Checker, method: []const u8, args: []const ast.CallArg) SemanticError!Ty {
        if (std.mem.eql(u8, method, "new")) {
            if (args.len == 0) return error.SemanticFailed;
            const ty_expr = switch (args[0]) {
                .positional => |e| e,
                .named => |n| n.value,
            };
            const alloc_ty = try self.inferTypeArg(ty_expr);
            return try self.ptrTo(alloc_ty);
        }
        if (std.mem.eql(u8, method, "new_slice")) {
            if (args.len < 2) return error.SemanticFailed;
            const ty_expr = switch (args[0]) {
                .positional => |e| e,
                .named => |n| n.value,
            };
            const count_expr = switch (args[1]) {
                .positional => |e| e,
                .named => |n| n.value,
            };
            const count_ty = try self.inferExpr(count_expr);
            if (!count_ty.isInteger()) return error.SemanticFailed;
            const elem_ty = try self.inferTypeArg(ty_expr);
            return try self.sliceOf(elem_ty);
        }
        if (std.mem.eql(u8, method, "free")) {
            if (args.len > 0) {
                const ptr_expr = switch (args[0]) {
                    .positional => |e| e,
                    .named => |n| n.value,
                };
                _ = try self.inferExpr(ptr_expr);
            }
            return .void;
        }
        return error.SemanticFailed;
    }

    fn exprZoneOwner(self: Checker, expr: ast.Expr) ?ZoneOwner {
        if (self.env.expr_types.get(expr.id)) |ty| {
            if (!tyCanCarryZoneOwner(ty)) return null;
        }
        return switch (expr.kind) {
            .ident => |name| self.lookupZoneOwner(name),
            .unsafe_expr, .run_expr, .force_unwrap => |inner| self.exprZoneOwner(inner.*),
            .as_cast => |cast| self.exprZoneOwner(cast.value.*),
            .nil_coalesce => |coalesce| self.exprZoneOwner(coalesce.value.*) orelse self.exprZoneOwner(coalesce.default.*),
            .unary => |unary| self.exprZoneOwner(unary.expr.*),
            .binary => |binary| self.exprZoneOwner(binary.left.*) orelse self.exprZoneOwner(binary.right.*),
            .field => |field| if (std.mem.eql(u8, field.name, "len")) null else self.exprZoneOwner(field.base.*),
            .index => |index| self.exprZoneOwner(index.base.*),
            .slice => |slice| self.exprZoneOwner(slice.base.*),
            .try_expr => |try_expr| self.exprZoneOwner(try_expr.value.*),
            .catch_expr => |catch_expr| self.exprZoneOwner(catch_expr.value.*),
            .compound_literal => |values| blk: {
                for (values) |value| if (self.exprZoneOwner(value)) |owner| break :blk owner;
                break :blk null;
            },
            .call => |call| blk: {
                if (call.callee.kind == .field) {
                    const field = call.callee.kind.field;
                    if ((std.mem.eql(u8, field.name, "new") or std.mem.eql(u8, field.name, "new_slice")) and
                        field.base.kind == .ident)
                    {
                        const zone_name = field.base.kind.ident;
                        for (self.active_zones.items) |zone| {
                            if (std.mem.eql(u8, zone.name, zone_name)) break :blk .{
                                .name = zone.name,
                                .scope_depth = zone.scope_depth,
                            };
                        }
                    }
                }
                break :blk null;
            },
            else => null,
        };
    }

    fn inferTypeArg(self: *Checker, expr: ast.Expr) SemanticError!Ty {
        return switch (expr.kind) {
            .type_ref => |ty| try self.typeFromRef(ty),
            .ident => |name| {
                if (self.resolveTypeParam(name)) |t| return t;
                if (fromBuiltinName(name)) |t| return t;
                const id = self.resolveSymbol(name) orelse return error.SemanticFailed;
                if (self.symbols.symbol(id).kind != .type) return error.SemanticFailed;
                return .{ .named = id };
            },
            else => error.SemanticFailed,
        };
    }

    fn inferGenericCall(self: *Checker, sym_id: SymbolId, fn_name: []const u8, sig: FnSig, call: ast.CallExpr) SemanticError!Ty {
        // Constrained type params ($T: Interface) are implicit — inferred from value args.
        // Unconstrained type params ($T: type) are explicit — the caller passes the type.
        // So we count: value params + unconstrained type params = expected arg count.
        var expected_arg_count: usize = 0;
        for (sig.params) |p| {
            if (!p.is_type_param) {
                expected_arg_count += 1;
                continue;
            }
            // Is this type param constrained?
            const is_constrained = for (sig.type_constraints) |c| {
                if (std.mem.eql(u8, c.param, p.name)) break true;
            } else false;
            if (!is_constrained) expected_arg_count += 1; // explicit $T: type
        }
        if (call.args.len != expected_arg_count) return error.SemanticFailed;

        // Infer type args by matching call args to value params.
        // Type-only params ($T: type / $T: Interface) are inferred from the value args.
        var binding = std.StringHashMap(Ty).init(self.allocator);
        defer binding.deinit();

        var arg_tys = std.ArrayList(Ty).empty;
        defer arg_tys.deinit(self.allocator);

        var arg_i: usize = 0;
        for (sig.params) |param| {
            if (param.is_type_param) {
                // Constrained ($T: Interface) → implicit, skip for arg matching.
                // Unconstrained ($T: type) → explicit, falls through to arg handling below.
                const constrained = for (sig.type_constraints) |c| {
                    if (std.mem.eql(u8, c.param, param.name)) break true;
                } else false;
                if (constrained) continue;
            }
            if (arg_i >= call.args.len) break;
            const arg_expr = switch (call.args[arg_i]) {
                .positional => |value| value,
                .named => |named| named.value,
            };
            arg_i += 1;
            try self.checkNonEscapingArgument(arg_expr, param.ty);
            const arg_ty = try self.inferExpr(arg_expr);
            try arg_tys.append(self.allocator, arg_ty);
            // Bind type variables: if param type is $T, bind T to the arg type.
            if (param.ty == .type_param) {
                const tp = param.ty.type_param;
                if (!binding.contains(tp)) {
                    const concrete = switch (arg_ty) {
                        .int_lit => Ty.i32,
                        .float_lit => Ty.f64,
                        else => arg_ty,
                    };
                    try binding.put(tp, concrete);
                }
            }
            // If param type contains a type variable (e.g. *$T), extract the binding.
            if (param.ty == .pointer or param.ty == .const_ptr) {
                const inner = switch (param.ty) {
                    .pointer, .const_ptr => |i| i,
                    else => unreachable,
                };
                if (inner.* == .type_param) {
                    const tp = inner.type_param;
                    if (!binding.contains(tp)) {
                        // arg_ty should be *SomeType — extract the inner
                        const concrete: Ty = switch (arg_ty) {
                            .pointer, .const_ptr => |inner_ty| inner_ty.*,
                            else => arg_ty,
                        };
                        try binding.put(tp, concrete);
                    }
                }
            }
        }

        // Verify all value args are compatible with substituted param types.
        var check_i: usize = 0;
        for (sig.params) |param| {
            if (param.is_type_param) {
                const constrained = for (sig.type_constraints) |c| {
                    if (std.mem.eql(u8, c.param, param.name)) break true;
                } else false;
                if (constrained) continue;
            }
            if (check_i >= arg_tys.items.len) break;
            const arg_ty = arg_tys.items[check_i];
            check_i += 1;
            const expected = self.substituteTy(param.ty, &binding);
            if (!try self.compatible(arg_ty, expected)) return error.SemanticFailed;
        }

        // Check static interface constraints: $T: Interface
        for (sig.type_constraints) |constraint| {
            const bound_ty = binding.get(constraint.param) orelse continue;
            // Unwrap pointer to get the concrete named type.
            const concrete_id: SymbolId = switch (bound_ty) {
                .named => |id| id,
                .pointer, .const_ptr => |inner| switch (inner.*) {
                    .named => |id| id,
                    else => {
                        self.emitError(constraint.span, "type parameter `{s}` must be a named struct, found `{s}`", .{ constraint.param, self.formatTy(bound_ty) });
                        return error.SemanticFailed;
                    },
                },
                else => {
                    self.emitError(constraint.span, "type parameter `{s}` must be a named struct, found `{s}`", .{ constraint.param, self.formatTy(bound_ty) });
                    return error.SemanticFailed;
                },
            };
            const concrete_name = self.symbols.symbol(concrete_id).name;
            const key = try interfaceImplKey(self.allocator, concrete_name, constraint.interface);
            if (!self.env.interface_impls.contains(key)) {
                self.emitError(constraint.span, "`{s}` does not implement `{s}`", .{ concrete_name, constraint.interface });
                return error.SemanticFailed;
            }
        }

        // Build ordered type_args list
        var type_args = std.ArrayList(TypeArg).empty;
        errdefer type_args.deinit(self.allocator);
        for (sig.type_params) |tp_name| {
            const concrete = binding.get(tp_name) orelse .unknown;
            try type_args.append(self.allocator, .{ .name = tp_name, .ty = concrete });
        }

        // Compute mangled name
        const mangled = try self.mangleInstantiation(fn_name, type_args.items);

        // Record if not already seen
        var already = false;
        for (self.env.generic_instantiations.items) |*gi| {
            if (std.mem.eql(u8, gi.mangled_name, mangled)) {
                already = true;
                break;
            }
        }
        if (!already) {
            try self.env.generic_instantiations.append(self.allocator, .{
                .sym_id = sym_id,
                .fn_name = fn_name,
                .mangled_name = mangled,
                .type_args = try type_args.toOwnedSlice(self.allocator),
                .expr_types = std.AutoHashMap(NodeId, Ty).init(self.allocator),
            });
        } else type_args.deinit(self.allocator);

        // Remember the mangled name so the IR lowerer can emit the right callee.
        try self.env.generic_call_insts.put(call.callee.id, mangled);

        // Return substituted return type
        const ret = self.substituteTy(sig.return_ty, &binding);
        if (sig.error_ty) |err| {
            const err_sub = self.substituteTy(err, &binding);
            return .{ .fallible = .{ .ok = try self.boxTy(ret), .err = try self.boxTy(err_sub) } };
        }
        return ret;
    }

    fn substituteTy(self: *Checker, ty: Ty, binding: *const std.StringHashMap(Ty)) Ty {
        return switch (ty) {
            .type_param => |name| binding.get(name) orelse ty,
            .pointer => |inner| blk: {
                const sub = self.allocator.create(Ty) catch return ty;
                sub.* = self.substituteTy(inner.*, binding);
                break :blk .{ .pointer = sub };
            },
            .const_ptr => |inner| blk: {
                const sub = self.allocator.create(Ty) catch return ty;
                sub.* = self.substituteTy(inner.*, binding);
                break :blk .{ .const_ptr = sub };
            },
            .optional => |inner| blk: {
                const sub = self.allocator.create(Ty) catch return ty;
                sub.* = self.substituteTy(inner.*, binding);
                break :blk .{ .optional = sub };
            },
            .slice => |inner| blk: {
                const sub = self.allocator.create(Ty) catch return ty;
                sub.* = self.substituteTy(inner.*, binding);
                break :blk .{ .slice = sub };
            },
            .borrow => |inner| blk: {
                const sub = self.allocator.create(Ty) catch return ty;
                sub.* = self.substituteTy(inner.*, binding);
                break :blk .{ .borrow = sub };
            },
            else => ty,
        };
    }

    fn mangleInstantiation(self: *Checker, fn_name: []const u8, type_args: []const TypeArg) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, fn_name);
        for (type_args) |arg| {
            try buf.appendSlice(self.allocator, "__");
            try buf.appendSlice(self.allocator, arg.name);
            try buf.append(self.allocator, '_');
            try buf.appendSlice(self.allocator, tyMangle(arg.ty));
        }
        return buf.toOwnedSlice(self.allocator);
    }

    /// Type-check a previously recorded generic instantiation, filling its per-instance expr_types.
    fn checkGenericInstantiation(self: *Checker, module: ast.Module, inst_idx: usize) SemanticError!void {
        const inst = &self.env.generic_instantiations.items[inst_idx];
        // Find the generic function decl
        for (module.items) |item| {
            switch (item) {
                .function => |decl| {
                    if (decl.type_params.len == 0) continue;
                    const sym_id = self.symbols.resolve(self.symbols.root_scope, decl.name) orelse continue;
                    if (sym_id != inst.sym_id) continue;

                    // Swap in a fresh expr_types for this instantiation
                    const saved = self.env.expr_types;
                    self.env.expr_types = inst.expr_types;
                    self.current_type_binding = inst.type_args;
                    defer {
                        inst.expr_types = self.env.expr_types;
                        self.env.expr_types = saved;
                        self.current_type_binding = &.{};
                    }

                    try self.checkFunction(decl);
                    return;
                },
                else => {},
            }
        }
    }

    fn checkCallable(self: *Checker, expr: ast.Expr) SemanticError!void {
        switch (expr.kind) {
            .ident => |name| {
                if (isBuiltinValue(name)) return;
                const id = self.resolveSymbol(name) orelse return error.SemanticFailed;
                if (self.symbols.symbol(id).kind != .function) return error.SemanticFailed;
            },
            .field => try self.checkExpr(expr),
            else => try self.checkExpr(expr),
        }
    }

    fn checkType(self: *Checker, ty: ast.TypeRef) SemanticError!void {
        _ = try self.typeFromRef(ty);
    }

    fn instantiateGenericStruct(self: *Checker, gi: ast.GenericInstType) SemanticError!Ty {
        _ = self.resolveSymbol(gi.name) orelse {
            self.emitError(gi.span, "unknown generic type `{s}`", .{gi.name});
            return error.SemanticFailed;
        };
        // Look up the template.
        const tmpl = self.env.generic_struct_templates.get(gi.name) orelse {
            self.emitError(gi.span, "unknown generic type `{s}`", .{gi.name});
            return error.SemanticFailed;
        };
        const strukt = switch (tmpl.kind) {
            .struct_type => |s| s,
            else => return error.SemanticFailed,
        };
        if (gi.args.len != strukt.type_params.len) {
            self.emitError(gi.span, "`{s}` expects {d} type argument(s), got {d}", .{ gi.name, strukt.type_params.len, gi.args.len });
            return error.SemanticFailed;
        }

        // Build type binding: T → resolved arg type.
        const saved_binding = self.current_type_binding;
        const saved_params = self.current_type_params;
        defer {
            self.current_type_binding = saved_binding;
            self.current_type_params = saved_params;
        }
        var binding = std.ArrayList(TypeArg).empty;
        defer binding.deinit(self.allocator);
        for (strukt.type_params, gi.args) |tp_name, arg_ref| {
            const arg_ty = try self.typeFromRef(arg_ref);
            // If the arg is still an unbound type param, we're inside a generic function —
            // return the template's own symbol rather than instantiating yet.
            if (arg_ty == .type_param) {
                const tmpl_id = self.resolveSymbol(gi.name) orelse return .unknown;
                return .{ .named = tmpl_id };
            }
            try binding.append(self.allocator, .{ .name = tp_name, .ty = arg_ty });
        }
        self.current_type_binding = binding.items;
        self.current_type_params = strukt.type_params;

        // Build a mangled name.
        var mangled_buf: std.ArrayList(u8) = .empty;
        defer mangled_buf.deinit(self.allocator);
        try mangled_buf.appendSlice(self.allocator, gi.name);
        for (binding.items) |arg| {
            try mangled_buf.appendSlice(self.allocator, "__");
            try mangled_buf.appendSlice(self.allocator, arg.name);
            try mangled_buf.append(self.allocator, '_');
            try mangled_buf.appendSlice(self.allocator, tyMangle(arg.ty));
        }
        const mangled = try mangled_buf.toOwnedSlice(self.allocator);

        // Return existing instantiation if already done.
        if (self.env.generic_struct_instances.get(mangled)) |inst_id|
            return .{ .named = inst_id };

        // Register a new symbol for the instantiated struct.
        const inst_id = self.symbols.symbols.items.len;
        try self.symbols.symbols.append(self.allocator, .{
            .id = inst_id,
            .name = mangled,
            .kind = .type,
            .span = gi.span,
            .scope_id = self.symbols.root_scope,
            .owner = null,
            .file_name = self.file,
            .is_public = false,
        });
        try self.symbols.scopes.items[self.symbols.root_scope].names.put(mangled, inst_id);
        try self.symbols.scopes.items[self.symbols.root_scope].symbols.append(self.allocator, inst_id);

        try self.env.symbol_types.put(inst_id, .{ .named = inst_id });
        try self.env.generic_struct_instances.put(mangled, inst_id);

        // Build the instantiated struct layout (substitute type params in fields).
        var fields = std.ArrayList(FieldInfo).empty;
        errdefer fields.deinit(self.allocator);
        for (strukt.fields) |field| {
            try fields.append(self.allocator, .{
                .name = field.name,
                .ty = try self.typeFromRef(field.ty), // uses current_type_binding
            });
        }
        try self.env.layouts.put(inst_id, .{
            .kind = .{ .struct_type = try fields.toOwnedSlice(self.allocator) },
            .is_packed = hasAttr(tmpl.attrs, "packed"),
        });

        return .{ .named = inst_id };
    }

    fn resolveTypeParam(self: *Checker, name: []const u8) ?Ty {
        // Check concrete binding first (during instantiation)
        for (self.current_type_binding) |arg| {
            if (std.mem.eql(u8, arg.name, name)) return arg.ty;
        }
        // Then check if it's a declared type param (unbound — stays as type_param)
        for (self.current_type_params) |tp| {
            if (std.mem.eql(u8, tp, name)) return .{ .type_param = name };
        }
        return null;
    }

    fn typeFromRef(self: *Checker, ty: ast.TypeRef) SemanticError!Ty {
        switch (ty) {
            .type_param => |tp| {
                return self.resolveTypeParam(tp.name) orelse .{ .type_param = tp.name };
            },
            .named => |named| {
                if (self.resolveTypeParam(named.name)) |tp_ty| return tp_ty;
                if (std.mem.eql(u8, named.name, "Self")) return self.current_self_ty orelse error.SemanticFailed;
                if (self.resolveSymbol(named.name)) |id| {
                    if (self.symbols.symbol(id).kind != .type) return error.SemanticFailed;
                    return .{ .named = id };
                }
                return fromBuiltinName(named.name) orelse error.SemanticFailed;
            },
            .pointer => |ptr| {
                const inner = try self.typeFromRef(ptr.inner.*);
                return if (ptr.is_const) try self.constPtrTo(inner) else try self.ptrTo(inner);
            },
            .many_pointer => |ptr| {
                const inner = try self.typeFromRef(ptr.inner.*);
                return if (ptr.is_const) try self.constPtrTo(inner) else try self.ptrTo(inner);
            },
            .optional => |optional| return try self.optionalOf(try self.typeFromRef(optional.inner.*)),
            .slice => |slice| return try self.sliceOf(try self.typeFromRef(slice.inner.*)),
            .array => |array| {
                _ = try self.inferExpr(array.len.*);
                return .{ .array = .{
                    .elem = try self.boxTy(try self.typeFromRef(array.inner.*)),
                    .len = parseArrayLen(array.len.*),
                } };
            },
            .atomic => |atomic| return try self.typeFromRef(atomic.inner.*),
            .borrow => |borrow| return .{ .borrow = try self.boxTy(try self.typeFromRef(borrow.inner.*)) },
            .fn_type => |func| {
                var params = std.ArrayList(Ty).empty;
                errdefer params.deinit(self.allocator);
                for (func.params) |param| try params.append(self.allocator, try self.typeFromRef(param));
                const ret = try self.typeFromRef(func.ret.*);
                const err = if (func.error_ty) |error_spec| try self.typeFromErrorSpec(error_spec) else null;
                return .{ .fn_ptr = .{
                    .params = try params.toOwnedSlice(self.allocator),
                    .ret = try self.boxTy(if (err) |error_ty_value| .{ .fallible = .{ .ok = try self.boxTy(ret), .err = try self.boxTy(error_ty_value) } } else ret),
                } };
            },
            .inline_error_set => |set| return .{ .error_set = try self.errorVariantsFromDecl(set.variants) },
            .generic_inst => |gi| return try self.instantiateGenericStruct(gi),
            .opaque_type => return .void,
        }
    }

    fn typeFromErrorSpec(self: *Checker, spec: ast.ErrorSpec) SemanticError!Ty {
        return switch (spec) {
            .inferred => .error_ty,
            .named => |named| blk: {
                if (std.mem.eql(u8, named.name, "void")) break :blk .error_ty;
                const id = self.resolveSymbol(named.name) orelse return error.SemanticFailed;
                if (self.symbols.symbol(id).kind != .type) return error.SemanticFailed;
                const layout = self.env.layouts.get(id) orelse return error.SemanticFailed;
                if (layout.kind != .error_set) return error.SemanticFailed;
                break :blk .{ .named = id };
            },
            .inline_set => |set| .{ .error_set = try self.errorVariantsFromDecl(set.variants) },
        };
    }

    fn errorVariantsFromDecl(self: *Checker, variants: []const ast.ErrorVariantDecl) SemanticError![]const ErrorVariantInfo {
        var infos = std.ArrayList(ErrorVariantInfo).empty;
        errdefer infos.deinit(self.allocator);

        for (variants) |variant| {
            try infos.append(self.allocator, .{
                .name = variant.name,
                .payload = if (variant.payload) |payload| try self.typeFromRef(payload) else null,
            });
        }

        return infos.toOwnedSlice(self.allocator);
    }

    fn checkFail(self: *Checker, fail: ast.FailStmt) SemanticError!void {
        const err_ty = self.current_error_ty orelse {
            self.emitError(fail.span, "`fail` used in a function without a `!` error return type", .{});
            return error.SemanticFailed;
        };
        const variant = try self.findErrorVariant(err_ty, fail.variant);
        if (variant.payload) |payload_ty| {
            if (fail.payload.len != 1) return error.SemanticFailed;
            const actual = try self.inferExpr(fail.payload[0]);
            if (!try self.compatible(actual, payload_ty)) return error.SemanticFailed;
        } else if (fail.payload.len != 0) {
            return error.SemanticFailed;
        }
    }

    fn findErrorVariant(self: *Checker, ty: Ty, name: []const u8) SemanticError!ErrorVariantInfo {
        switch (ty) {
            .error_ty => return .{ .name = name, .payload = null },
            .error_set => |variants| {
                for (variants) |variant| {
                    if (std.mem.eql(u8, variant.name, name)) return variant;
                }
                return error.SemanticFailed;
            },
            .named => |id| {
                const layout = self.env.layouts.get(id) orelse return error.SemanticFailed;
                return switch (layout.kind) {
                    .error_set => |variants| blk: {
                        for (variants) |variant| {
                            if (std.mem.eql(u8, variant.name, name)) break :blk variant;
                        }
                        return error.SemanticFailed;
                    },
                    else => error.SemanticFailed,
                };
            },
            else => return error.SemanticFailed,
        }
    }

    fn fieldType(self: *Checker, base_ty: Ty, name: []const u8) SemanticError!Ty {
        // Unknown base (e.g., TARGET pseudo-module) — field access returns unknown.
        if (base_ty == .unknown) return .unknown;
        if (base_ty == .fallible) {
            if (std.mem.eql(u8, name, "ok")) return base_ty.fallible.ok.*;
            if (std.mem.eql(u8, name, "err")) return base_ty.fallible.err.*;
        }
        const type_id = switch (base_ty) {
            .named => |id| id,
            .pointer, .const_ptr => |inner| switch (inner.*) {
                .named => |id| id,
                else => return error.SemanticFailed,
            },
            else => return error.SemanticFailed,
        };
        const layout = self.env.layouts.get(type_id) orelse return error.SemanticFailed;
        return switch (layout.kind) {
            .struct_type => |fields| blk: {
                for (fields) |field| {
                    if (std.mem.eql(u8, field.name, name)) break :blk field.ty;
                }
                return error.SemanticFailed;
            },
            // `Direction.north` — enum variant access returns the enum type itself.
            .variant_type => |variants| blk: {
                for (variants) |v| {
                    if (std.mem.eql(u8, v.name, name)) break :blk .{ .named = type_id };
                }
                self.emitError(Span.new(0, 0), "unknown variant `{s}`", .{name});
                return error.SemanticFailed;
            },
            .interface_type => |methods| blk: {
                for (methods) |method| {
                    if (std.mem.eql(u8, method.name, name)) break :blk .{ .fn_ptr = .{
                        .params = &.{},
                        .ret = try self.boxTy(method.return_ty),
                    } };
                }
                return error.SemanticFailed;
            },
            else => error.SemanticFailed,
        };
    }

    fn firstTypeArg(self: *Checker, call: ast.CallExpr) ?Ty {
        if (call.args.len == 0) return null;
        return switch (call.args[0]) {
            .positional => |expr| switch (expr.kind) {
                .type_ref => |ty| self.typeFromRef(ty) catch null,
                .ident => |name| blk: {
                    if (fromBuiltinName(name)) |builtin_ty| break :blk builtin_ty;
                    const id = self.resolveSymbol(name) orelse break :blk null;
                    if (self.symbols.symbol(id).kind != .type) break :blk null;
                    break :blk .{ .named = id };
                },
                else => null,
            },
            .named => null,
        };
    }

    fn ptrTo(self: *Checker, ty: Ty) !Ty {
        return .{ .pointer = try self.boxTy(ty) };
    }

    fn constPtrTo(self: *Checker, ty: Ty) !Ty {
        return .{ .const_ptr = try self.boxTy(ty) };
    }

    /// Reject assignments whose target is a dereference of a *const pointer.
    fn checkAssignTarget(self: *Checker, target: ast.Expr) SemanticError!void {
        switch (target.kind) {
            .unary => |u| {
                if (u.op != .deref) return;
                const ptr_ty = try self.inferExpr(u.expr.*);
                if (ptr_ty == .const_ptr) {
                    self.emitError(target.span, "cannot assign through `*const` pointer", .{});
                    return error.SemanticFailed;
                }
            },
            .field => |f| {
                // Writing through ptr.field — check the base pointer.
                const base_ty = try self.inferExpr(f.base.*);
                if (base_ty == .const_ptr) {
                    self.emitError(target.span, "cannot assign to field through `*const` pointer", .{});
                    return error.SemanticFailed;
                }
            },
            else => {},
        }
    }

    fn sliceOf(self: *Checker, ty: Ty) !Ty {
        return .{ .slice = try self.boxTy(ty) };
    }

    fn optionalOf(self: *Checker, ty: Ty) !Ty {
        return .{ .optional = try self.boxTy(ty) };
    }

    fn boxTy(self: *Checker, ty: Ty) !*const Ty {
        const ptr = try self.allocator.create(Ty);
        ptr.* = ty;
        return ptr;
    }

    fn isErrorType(self: *const Checker, ty: Ty) bool {
        return switch (ty) {
            .error_ty, .error_set => true,
            .named => |id| blk: {
                const layout = self.env.layouts.get(id) orelse break :blk false;
                break :blk layout.kind == .error_set;
            },
            else => false,
        };
    }

    fn compatible(self: *Checker, actual: Ty, expected: Ty) !bool {
        if (expected == .borrow) return self.compatible(actual, expected.borrow.*);
        if (actual == .borrow) return self.compatible(actual.borrow.*, expected);
        if (sameTy(actual, expected)) return true;
        if (try self.interfaceCoercion(actual, expected)) return true;
        if (expected == .optional) {
            if (actual == .null_ptr) return true;
            return try self.compatible(actual, expected.optional.*);
        }
        if (actual == .int_lit and expected.isInteger()) return true;
        if (expected == .int_lit and actual.isInteger()) return true;
        if (actual == .float_lit and expected.isFloat()) return true;
        if (expected == .float_lit and actual.isFloat()) return true;
        // *T is implicitly usable as *const T (const promotion).
        if (actual == .pointer and expected == .const_ptr)
            return sameTy(actual.pointer.*, expected.const_ptr.*);
        if (actual == .null_ptr) return switch (expected) {
            .pointer, .const_ptr, .slice, .named, .optional => true,
            else => false,
        };
        if (actual == .error_ty and self.isErrorType(expected)) return true;
        if (expected == .error_ty and self.isErrorType(actual)) return true;
        if (expected == .unknown or actual == .unknown) return true;
        return false;
    }

    fn interfaceFromPointer(self: *Checker, ty: Ty) ?SymbolId {
        const id = switch (ty) {
            .pointer, .const_ptr => |inner| switch (inner.*) {
                .named => |id| id,
                else => return null,
            },
            else => return null,
        };
        const layout = self.env.layouts.get(id) orelse return null;
        return if (layout.kind == .interface_type) id else null;
    }

    fn findInterfaceMethod(self: *Checker, interface_id: SymbolId, name: []const u8) ?InterfaceMethodInfo {
        const layout = self.env.layouts.get(interface_id) orelse return null;
        const methods = switch (layout.kind) {
            .interface_type => |methods| methods,
            else => return null,
        };
        for (methods) |method| if (std.mem.eql(u8, method.name, name)) return method;
        return null;
    }

    fn interfaceCoercion(self: *Checker, actual: Ty, expected: Ty) !bool {
        const interface_id = self.interfaceFromPointer(expected) orelse return false;
        const concrete_id = switch (actual) {
            .pointer, .const_ptr => |inner| switch (inner.*) {
                .named => |id| id,
                else => return false,
            },
            else => return false,
        };
        const key = try interfaceImplKey(
            self.allocator,
            self.symbols.symbol(concrete_id).name,
            self.symbols.symbol(interface_id).name,
        );
        return self.env.interface_impls.contains(key);
    }
};

fn interfaceImplKey(allocator: std.mem.Allocator, type_name: []const u8, interface_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} as {s}", .{ type_name, interface_name });
}

fn substituteInterfaceSelf(checker: *Checker, ty: Ty, interface_id: SymbolId, concrete_id: SymbolId) !Ty {
    return switch (ty) {
        .named => |id| if (id == interface_id) .{ .named = concrete_id } else ty,
        .pointer => |inner| .{ .pointer = try checker.boxTy(try substituteInterfaceSelf(checker, inner.*, interface_id, concrete_id)) },
        .const_ptr => |inner| .{ .const_ptr = try checker.boxTy(try substituteInterfaceSelf(checker, inner.*, interface_id, concrete_id)) },
        .optional => |inner| .{ .optional = try checker.boxTy(try substituteInterfaceSelf(checker, inner.*, interface_id, concrete_id)) },
        .slice => |inner| .{ .slice = try checker.boxTy(try substituteInterfaceSelf(checker, inner.*, interface_id, concrete_id)) },
        .borrow => |inner| .{ .borrow = try checker.boxTy(try substituteInterfaceSelf(checker, inner.*, interface_id, concrete_id)) },
        else => ty,
    };
}

fn isPointerTy(ty: Ty) bool {
    return ty == .pointer or ty == .const_ptr;
}

fn blockDefinitelyReturns(block: ast.Block) bool {
    for (block.statements) |stmt| {
        if (stmtDefinitelyReturns(stmt)) return true;
    }
    return false;
}

fn stmtDefinitelyReturns(stmt: ast.Stmt) bool {
    return switch (stmt) {
        .return_stmt, .fail_stmt => true,
        .expr => |e| switch (e.kind) {
            // `expr!!` panics on null/error — counts as exit on that path.
            .force_unwrap => true,
            // A call to a named function whose name starts with `@panic` or is `@panic`
            // always terminates — treat it as definitely returning so CFG accepts it.
            .call => |call| switch (call.callee.kind) {
                .ident => |name| isRuntimeNoReturnName(name),
                else => false,
            },
            else => false,
        },
        .break_stmt, .continue_stmt => true,
        .if_stmt => |iff| iff.else_block != null and
            blockDefinitelyReturns(iff.then_block) and
            blockDefinitelyReturns(iff.else_block.?),
        .unsafe_block => |block| blockDefinitelyReturns(block),
        .zone_block => |zb| blockDefinitelyReturns(zb.body),
        .defer_stmt => false,
        .comptime_run => |b| blockDefinitelyReturns(b),
        .comptime_if => |ci| ci.else_block != null and
            blockDefinitelyReturns(ci.then_block) and
            blockDefinitelyReturns(ci.else_block.?),
        // match returns if it has an else arm and ALL arms return.
        .match_stmt => |m| blk: {
            var has_else = false;
            for (m.arms) |arm| {
                if (!blockDefinitelyReturns(arm.body)) break :blk false;
                if (arm.pattern == .else_arm) has_else = true;
            }
            break :blk has_else;
        },
        else => false,
    };
}

fn isRuntimeNoReturnName(name: []const u8) bool {
    return std.mem.eql(u8, name, "@panic") or
        std.mem.eql(u8, name, "exit") or
        std.mem.eql(u8, name, "abort");
}

pub fn tyMangle(ty: Ty) []const u8 {
    return switch (ty) {
        .i8 => "i8",
        .i16 => "i16",
        .i32 => "i32",
        .i64 => "i64",
        .u8 => "u8",
        .u16 => "u16",
        .u32 => "u32",
        .u64 => "u64",
        .bool => "bool",
        .void => "void",
        .usize => "usize",
        .isize => "isize",
        .pointer => "ptr",
        .const_ptr => "cptr",
        .optional => "opt",
        .slice => "slice",
        .borrow => "borrow",
        .named => "named",
        .type_param => |n| n,
        else => "unknown",
    };
}

fn sameTy(a: Ty, b: Ty) bool {
    if (@as(std.meta.Tag(Ty), a) != @as(std.meta.Tag(Ty), b)) return false;
    return switch (a) {
        .pointer => |pa| sameTy(pa.*, b.pointer.*),
        .const_ptr => |pa| sameTy(pa.*, b.const_ptr.*),
        .optional => |oa| sameTy(oa.*, b.optional.*),
        .slice => |sa| sameTy(sa.*, b.slice.*),
        .borrow => |ba| sameTy(ba.*, b.borrow.*),
        .array => |aa| sameTy(aa.elem.*, b.array.elem.*) and aa.len == b.array.len,
        .named => |id| id == b.named,
        .error_set => |variants| sameErrorVariants(variants, b.error_set),
        .fallible => |fa| sameTy(fa.ok.*, b.fallible.ok.*) and sameTy(fa.err.*, b.fallible.err.*),
        else => true,
    };
}

fn tyCanCarryZoneOwner(ty: Ty) bool {
    return switch (ty) {
        .pointer, .const_ptr, .slice, .borrow, .optional, .fallible, .named, .unknown => true,
        else => false,
    };
}

fn containsBorrow(ty: Ty) bool {
    return switch (ty) {
        .borrow => true,
        .pointer, .const_ptr, .optional, .slice => |inner| containsBorrow(inner.*),
        .array => |array| containsBorrow(array.elem.*),
        .fallible => |fallible| containsBorrow(fallible.ok.*) or containsBorrow(fallible.err.*),
        else => false,
    };
}

fn typeRefContainsBorrow(ty: ast.TypeRef) bool {
    return switch (ty) {
        .borrow => true,
        .pointer => |pointer| typeRefContainsBorrow(pointer.inner.*),
        .many_pointer => |pointer| typeRefContainsBorrow(pointer.inner.*),
        .optional => |optional| typeRefContainsBorrow(optional.inner.*),
        .slice => |slice| typeRefContainsBorrow(slice.inner.*),
        .array => |array| typeRefContainsBorrow(array.inner.*),
        .atomic => |atomic| typeRefContainsBorrow(atomic.inner.*),
        .fn_type => |function| blk: {
            for (function.params) |param| if (typeRefContainsBorrow(param)) break :blk true;
            break :blk typeRefContainsBorrow(function.ret.*);
        },
        .generic_inst => |generic| blk: {
            for (generic.args) |arg| if (typeRefContainsBorrow(arg)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn sameErrorVariants(a: []const ErrorVariantInfo, b: []const ErrorVariantInfo) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.name, right.name)) return false;
        if (left.payload == null and right.payload == null) continue;
        if (left.payload == null or right.payload == null) return false;
        if (!sameTy(left.payload.?, right.payload.?)) return false;
    }
    return true;
}

fn intLiteralType(text: []const u8) Ty {
    if (std.mem.endsWith(u8, text, "u32")) return .u32;
    if (std.mem.endsWith(u8, text, "usize")) return .usize;
    return .int_lit;
}

fn floatLiteralType(text: []const u8) Ty {
    if (std.mem.endsWith(u8, text, "f32")) return .f32;
    if (std.mem.endsWith(u8, text, "f64")) return .f64;
    return .float_lit;
}

fn parseArrayLen(expr: ast.Expr) u64 {
    return switch (expr.kind) {
        .int => |text| @intCast(@max(parseIntLiteral(text), 0)),
        else => 0,
    };
}

fn parseIntLiteral(text: []const u8) i128 {
    var value: i128 = 0;
    var start: usize = 0;
    var radix: i128 = 10;
    if (text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        start = 2;
        radix = 16;
    } else if (text.len >= 2 and text[0] == '0' and (text[1] == 'b' or text[1] == 'B')) {
        start = 2;
        radix = 2;
    }
    for (text[start..]) |ch| {
        if (ch == '_') continue;
        const digit: i128 = if (ch >= '0' and ch <= '9')
            ch - '0'
        else if (ch >= 'a' and ch <= 'f')
            10 + ch - 'a'
        else if (ch >= 'A' and ch <= 'F')
            10 + ch - 'A'
        else
            break;
        if (digit >= radix) break;
        value = value * radix + digit;
    }
    return value;
}

fn hasAttr(attrs: []const ast.Attribute, name: []const u8) bool {
    for (attrs) |attr| if (std.mem.eql(u8, attr.name, name)) return true;
    return false;
}

/// Returns the export symbol name from `#export` or `#export("name")`.
/// `#export` with no args → null (keep function's own name, just set external linkage).
/// `#export("sym")` → "sym".
pub fn exportSym(attrs: []const ast.Attribute) ?[]const u8 {
    for (attrs) |attr| {
        if (!std.mem.eql(u8, attr.name, "export")) continue;
        if (attr.args.len > 0) {
            return switch (attr.args[0].kind) {
                .string => |s| trimQuotes(s),
                else => "",
            };
        }
        return ""; // #export with no args — empty string signals "use own name"
    }
    return null;
}

/// Returns the deprecation message from `#deprecated` or `#deprecated("msg")`.
fn deprecatedMsg(attrs: []const ast.Attribute) ?[]const u8 {
    for (attrs) |attr| {
        if (!std.mem.eql(u8, attr.name, "deprecated")) continue;
        if (attr.args.len > 0) {
            return switch (attr.args[0].kind) {
                .string => |s| trimQuotes(s),
                else => "",
            };
        }
        return "";
    }
    return null;
}

fn externName(attrs: []const ast.Attribute) ?[]const u8 {
    for (attrs) |attr| {
        if (!std.mem.eql(u8, attr.name, "extern") or attr.args.len < 2) continue;
        return switch (attr.args[1].kind) {
            .string => |value| trimQuotes(value),
            else => null,
        };
    }
    return null;
}

fn trimQuotes(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') return text[1 .. text.len - 1];
    return text;
}

fn isBuiltinValue(name: []const u8) bool {
    inline for (.{
        "truncate_to", "ptr_from_int",   "volatile_store",
        "sizeof",      "unaligned_read", "asm",
        "atomic_load", "volatile",       ".acquire",
        // Compile-time reflection builtins
        "type_info",   "type_name",
        // Compile-time pseudo-modules
        "TARGET",
    }) |builtin| {
        if (std.mem.eql(u8, name, builtin)) return true;
    }
    return false;
}
