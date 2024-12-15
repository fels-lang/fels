const std = @import("std");
const ast = @import("ast.zig");
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
    root_scope: ScopeId = 0,

    pub fn init(allocator: std.mem.Allocator) !SymbolTable {
        var table: SymbolTable = .{};
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

    pub fn insert(
        self: *SymbolTable,
        allocator: std.mem.Allocator,
        scope_id: ScopeId,
        name: []const u8,
        kind: SymbolKind,
        span: Span,
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
    pointer: *const Ty,
    optional: *const Ty,
    slice: *const Ty,
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
};

pub const FieldInfo = struct {
    name: []const u8,
    ty: Ty,
};

pub const VariantInfo = struct {
    name: []const u8,
    payload: ?Ty,
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
    entry: bool,
    naked: bool,
    type_params: []const []const u8,
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
    generic_instantiations: std.ArrayList(GenericInstantiation) = .empty,
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
        for (self.generic_instantiations.items) |*gi| gi.expr_types.deinit();
        self.generic_instantiations.deinit(allocator);
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
        const kind: SymbolKind = switch (item) {
            .import => unreachable,
            .const_decl => .const_symbol,
            .type_decl => .type,
            .function => .function,
        };
        _ = try table.insert(allocator, table.root_scope, name, kind, item.span());
    }

    return table;
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

    try checker.checkModule(module);

    // Check each generic instantiation discovered during the main pass.
    // New instantiations may be discovered while checking (e.g. generic calls inside
    // generic bodies), so iterate until stable.
    var checked: usize = 0;
    while (checked < checker.env.generic_instantiations.items.len) {
        try checker.checkGenericInstantiation(module, checked);
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
    current_return_ty: Ty = .void,
    current_error_ty: ?Ty = null,
    loop_depth: usize = 0,
    current_type_params: []const []const u8 = &.{},
    current_type_binding: []const TypeArg = &.{},
    unsafe_depth: usize = 0,
    // Diagnostics — collected instead of failing immediately where possible.
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    source: []const u8 = "",
    file:   []const u8 = "",

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
        self.diagnostics.deinit(self.allocator);
    }

    // ── Diagnostics ──────────────────────────────────────────────────────────

    fn emitError(self: *Checker, span: Span, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.diagnostics.append(self.allocator, Diagnostic.err(msg, span, self.file)) catch {};
    }

    /// Format a Ty as a human-readable string (caller owns result).
    fn formatTy(self: *Checker, ty: Ty) []const u8 {
        return switch (ty) {
            .i8 => "i8", .i16 => "i16", .i32 => "i32", .i64 => "i64",
            .u8  => "u8",  .u16 => "u16", .u32 => "u32", .u64 => "u64",
            .bool => "bool", .void => "void", .usize => "usize", .isize => "isize",
            .f32 => "f32", .f64 => "f64",
            .int_lit => "integer literal",
            .float_lit => "float literal",
            .null_ptr => "null",
            .zone_handle => "Zone",
            .error_ty => "error",
            .unknown => "unknown",
            .optional => |inner| std.fmt.allocPrint(self.allocator, "?{s}", .{self.formatTy(inner.*)}) catch "?T",
            .pointer => |inner| std.fmt.allocPrint(self.allocator, "*{s}", .{self.formatTy(inner.*)}) catch "*T",
            .slice => |inner| std.fmt.allocPrint(self.allocator, "[]{s}", .{self.formatTy(inner.*)}) catch "[]T",
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
    }

    fn popScope(self: *Checker) void {
        var s = self.scope_stack.pop() orelse return;
        s.deinit();
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

    fn checkModule(self: *Checker, module: ast.Module) SemanticError!void {
        try self.collectTopLevelTypes(module);

        for (module.items) |item| {
            switch (item) {
                .import => {},
                .const_decl => |decl| _ = try self.inferExpr(decl.value),
                .type_decl => |decl| try self.checkTypeDecl(decl),
                .function => |decl| try self.checkFunction(decl),
            }
        }
    }

    fn collectTopLevelTypes(self: *Checker, module: ast.Module) SemanticError!void {
        for (module.items) |item| {
            const name = item.name() orelse continue;
            const id = self.symbols.resolve(self.symbols.root_scope, name) orelse continue;
            switch (item) {
                .const_decl => |decl| try self.env.set(id, try self.inferExpr(decl.value)),
                .type_decl => |decl| {
                    try self.env.set(id, .{ .named = id });
                    switch (decl.kind) {
                        .struct_type => |strukt| {
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
                        },
                        .errors => |errors_decl| {
                            try self.env.layouts.put(id, .{
                                .kind = .{ .error_set = try self.errorVariantsFromDecl(errors_decl.variants) },
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
                        try params.append(self.allocator, .{
                            .name = param.name,
                            .ty = try self.typeFromRef(param.ty),
                            .is_type_param = param.is_type_param,
                        });
                    }
                    const ret = try self.typeFromRef(decl.return_ty);
                    const err_ty = if (decl.error_ty) |err| try self.typeFromErrorSpec(err) else null;
                    try self.env.fn_sigs.put(id, .{
                        .params = try params.toOwnedSlice(self.allocator),
                        .return_ty = ret,
                        .error_ty = err_ty,
                        .extern_name = externName(decl.attrs),
                        .inline_hint = hasAttr(decl.attrs, "inline"),
                        .entry = std.mem.eql(u8, decl.name, "main") or hasAttr(decl.attrs, "entry"),
                        .naked = hasAttr(decl.attrs, "naked"),
                        .type_params = decl.type_params,
                        .type_binding = null,
                    });
                    try self.env.set(id, .{ .fn_ptr = .{
                        .params = &.{},
                        .ret = try self.boxTy(if (err_ty) |err| .{ .fallible = .{ .ok = try self.boxTy(ret), .err = try self.boxTy(err) } } else ret),
                    } });
                },
                .import => {},
            }
        }
    }

    fn checkTypeDecl(self: *Checker, decl: ast.TypeDecl) SemanticError!void {
        switch (decl.kind) {
            .distinct => |ty| try self.checkType(ty),
            .opaque_type => {},
            .struct_type => |strukt| {
                for (strukt.fields) |field| try self.checkType(field.ty);
            },
            .errors => |errors_decl| {
                for (errors_decl.variants) |variant| {
                    if (variant.payload) |payload| try self.checkType(payload);
                }
            },
        }
    }

    fn checkFunction(self: *Checker, decl: ast.FunctionDecl) SemanticError!void {
        // Generic functions with unbound type params are checked per-instantiation, not here.
        if (decl.type_params.len > 0 and self.current_type_binding.len == 0) return;

        self.current_type_params = decl.type_params;
        defer self.current_type_params = &.{};

        self.current_return_ty = try self.typeFromRef(decl.return_ty);
        self.current_error_ty = if (decl.error_ty) |err| try self.typeFromErrorSpec(err) else null;
        try self.pushScope();
        defer self.popScope();

        for (decl.params) |param| {
            if (param.is_type_param) continue; // type-only params aren't values in scope
            const param_ty = try self.typeFromRef(param.ty);
            try self.declareLocal(param.name, param_ty);
        }

        if (decl.body) |body| {
            try self.checkBlock(body);
            if ((self.current_return_ty != .void or self.current_error_ty != null) and !blockDefinitelyReturns(body)) {
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
            },
            .local_typed => |local| {
                const declared_ty = try self.typeFromRef(local.ty);
                const value_ty = try self.inferExpr(local.value);
                if (!try self.compatible(value_ty, declared_ty)) return error.SemanticFailed;
                try self.declareLocal(local.name, declared_ty);
            },
            .assign => |assign| {
                const target_ty = try self.inferExpr(assign.target);
                const value_ty = try self.inferExpr(assign.value);
                if (!try self.compatible(value_ty, target_ty)) return error.SemanticFailed;
            },
            .return_stmt => |ret| {
                const actual_ty: Ty = if (ret.value) |value| try self.inferExpr(value) else .void;
                if (!try self.compatible(actual_ty, self.current_return_ty)) {
                    self.emitError(ret.span,
                        "return type mismatch: expected `{s}`, found `{s}`",
                        .{ self.formatTy(self.current_return_ty), self.formatTy(actual_ty) });
                    return error.SemanticFailed;
                }
            },
            .fail_stmt => |fail| try self.checkFail(fail),
            .if_stmt => |iff| {
                if (iff.binding) |binding| {
                    const bound_ty = try self.inferExpr(binding.value);
                    if (bound_ty != .optional) {
                        self.emitError(binding.value.span,
                            "`if {s} :=` requires an optional type, found `{s}`",
                            .{ binding.name, self.formatTy(bound_ty) });
                        return error.SemanticFailed;
                    }
                    const inner_ty = bound_ty.optional.*;
                    try self.pushScope();
                    defer self.popScope();
                    try self.declareLocal(binding.name, inner_ty);
                    if (iff.payload_binding) |payload_name| try self.declareLocal(payload_name, .unknown);
                    try self.checkBlock(iff.then_block);
                } else {
                    const cond_ty = try self.inferExpr(iff.condition);
                    if (!cond_ty.isBool()) return error.SemanticFailed;
                    try self.pushScope();
                    defer self.popScope();
                    if (iff.payload_binding) |payload_name| try self.declareLocal(payload_name, .unknown);
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
                try self.pushScope();
                defer self.popScope();
                try self.declareLocal(zb.name, .zone_handle);
                try self.checkBlock(zb.body);
            },
            .defer_stmt => |ds| try self.checkBlock(ds.body),
            .expr => |expr| try self.checkExpr(expr),
        }
    }

    fn checkExpr(self: *Checker, expr: ast.Expr) SemanticError!void {
        _ = try self.inferExpr(expr);
    }

    fn inferExpr(self: *Checker, expr: ast.Expr) SemanticError!Ty {
        const ty: Ty = switch (expr.kind) {
            .ident => |name| {
                if (isBuiltinValue(name)) return .void;
                if (std.mem.startsWith(u8, name, ".")) return .error_ty;
                if (self.lookupLocal(name)) |local_ty| return local_ty;
                if (self.symbols.resolve(self.symbols.root_scope, name)) |id| {
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
            .type_ref => |type_ref| try self.typeFromRef(type_ref),
            .int => |text| intLiteralType(text),
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
                        .pointer => |p| p.*,
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
                    .equal, .not_equal => if ((left.isNumeric() and right.isNumeric()) or left == .error_ty or right == .error_ty or try self.compatible(left, right)) .bool else return error.SemanticFailed,
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
                break :blk try self.fieldType(base_ty, field.name);
            },
            .index => |index| blk: {
                const base_ty = try self.inferExpr(index.base.*);
                _ = try self.inferExpr(index.index.*);
                break :blk switch (base_ty) {
                    .array => |array| array.elem.*,
                    .slice => |inner| inner.*,
                    .pointer => |inner| inner.*,
                    else => return error.SemanticFailed,
                };
            },
            .slice => |slice| blk: {
                const base_ty = try self.inferExpr(slice.base.*);
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
                return self.inferZoneMethod(fld.name, call.args);
            }
        }

        const name = switch (call.callee.kind) {
            .ident => |n| n,
            else => return .unknown,
        };

        // ── Builtins ────────────────────────────────────────────────────
        if (std.mem.eql(u8, name, "truncate_to"))   return self.firstTypeArg(call) orelse error.SemanticFailed;
        if (std.mem.eql(u8, name, "sizeof"))         return .usize;
        if (std.mem.eql(u8, name, "atomic_load"))    return .u32;
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
                const n = switch (arg) { .named => |n| n, else => continue };
                if (!std.mem.eql(u8, n.name, "outputs")) continue;
                const items = switch (n.value.kind) { .compound_literal => |c| c, else => continue };
                if (items.len == 0) break;
                const first = items[0];
                if (first.kind != .call) break;
                const c_args = first.kind.call.args;
                if (c_args.len == 0) break;
                const ty_expr = switch (c_args[0]) { .positional => |e| e, .named => |nn| nn.value };
                return try self.inferTypeArg(ty_expr);
            }
            return .void;
        }

        const id = self.symbols.resolve(self.symbols.root_scope, name) orelse {
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

        // Count only value params for arg matching
        var value_param_count: usize = 0;
        for (sig.params) |p| { if (!p.is_type_param) value_param_count += 1; }
        if (call.args.len != value_param_count) {
            self.emitError(call.callee.span,
                "`{s}` expects {d} argument(s), but {d} were provided",
                .{ name, value_param_count, call.args.len });
            return error.SemanticFailed;
        }

        var arg_i: usize = 0;
        for (sig.params) |param| {
            if (param.is_type_param) continue;
            const arg_expr = switch (call.args[arg_i]) {
                .positional => |e| e,
                .named => |n| n.value,
            };
            const arg_ty = try self.inferExpr(arg_expr);
            if (!try self.compatible(arg_ty, param.ty)) {
                self.emitError(arg_expr.span,
                    "argument {d} of `{s}`: expected `{s}`, found `{s}`",
                    .{ arg_i + 1, name, self.formatTy(param.ty), self.formatTy(arg_ty) });
                return error.SemanticFailed;
            }
            arg_i += 1;
        }
        if (sig.error_ty) |err_ty| {
            return .{ .fallible = .{ .ok = try self.boxTy(sig.return_ty), .err = try self.boxTy(err_ty) } };
        }
        return sig.return_ty;
    }

    fn requireUnsafe(self: *Checker, span: Span, builtin_name: []const u8) SemanticError!void {
        if (self.unsafe_depth == 0) {
            self.emitError(span,
                "`{s}` is an unsafe operation and must be called inside an `unsafe` block",
                .{builtin_name});
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

    fn inferTypeArg(self: *Checker, expr: ast.Expr) SemanticError!Ty {
        return switch (expr.kind) {
            .type_ref => |ty| try self.typeFromRef(ty),
            .ident => |name| {
                if (fromBuiltinName(name)) |t| return t;
                const id = self.symbols.resolve(self.symbols.root_scope, name) orelse return error.SemanticFailed;
                if (self.symbols.symbol(id).kind != .type) return error.SemanticFailed;
                return .{ .named = id };
            },
            else => error.SemanticFailed,
        };
    }

    fn inferGenericCall(self: *Checker, sym_id: SymbolId, fn_name: []const u8, sig: FnSig, call: ast.CallExpr) SemanticError!Ty {
        if (call.args.len != sig.params.len) return error.SemanticFailed;

        // Infer type args by matching call args to type_param-typed params
        var binding = std.StringHashMap(Ty).init(self.allocator);
        defer binding.deinit();

        var arg_tys = std.ArrayList(Ty).empty;
        defer arg_tys.deinit(self.allocator);

        for (call.args, sig.params) |arg, param| {
            const arg_ty = switch (arg) {
                .positional => |value| try self.inferExpr(value),
                .named => |named| try self.inferExpr(named.value),
            };
            try arg_tys.append(self.allocator, arg_ty);
            if (param.ty == .type_param) {
                const tp = param.ty.type_param;
                if (!binding.contains(tp)) {
                    // Coerce unresolved literal types to concrete defaults
                    const concrete = switch (arg_ty) {
                        .int_lit   => Ty.i32,
                        .float_lit => Ty.f64,
                        else       => arg_ty,
                    };
                    try binding.put(tp, concrete);
                }
            }
        }

        // Verify all args are compatible with substituted param types
        for (sig.params, arg_tys.items) |param, arg_ty| {
            const expected = self.substituteTy(param.ty, &binding);
            if (!try self.compatible(arg_ty, expected)) return error.SemanticFailed;
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
            if (std.mem.eql(u8, gi.mangled_name, mangled)) { already = true; break; }
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
                const id = self.symbols.resolve(self.symbols.root_scope, name) orelse return error.SemanticFailed;
                if (self.symbols.symbol(id).kind != .function) return error.SemanticFailed;
            },
            .field => try self.checkExpr(expr),
            else => try self.checkExpr(expr),
        }
    }

    fn checkType(self: *Checker, ty: ast.TypeRef) SemanticError!void {
        _ = try self.typeFromRef(ty);
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
                if (fromBuiltinName(named.name)) |builtin_ty| return builtin_ty;
                const id = self.symbols.resolve(self.symbols.root_scope, named.name) orelse return error.SemanticFailed;
                if (self.symbols.symbol(id).kind != .type) return error.SemanticFailed;
                return .{ .named = id };
            },
            .pointer => |ptr| return try self.ptrTo(try self.typeFromRef(ptr.inner.*)),
            .many_pointer => |ptr| return try self.ptrTo(try self.typeFromRef(ptr.inner.*)),
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
            .opaque_type => return .void,
        }
    }

    fn typeFromErrorSpec(self: *Checker, spec: ast.ErrorSpec) SemanticError!Ty {
        return switch (spec) {
            .inferred => .error_ty,
            .named => |named| blk: {
                const id = self.symbols.resolve(self.symbols.root_scope, named.name) orelse return error.SemanticFailed;
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
        const type_id = switch (base_ty) {
            .named => |id| id,
            .pointer => |inner| switch (inner.*) {
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
                    const id = self.symbols.resolve(self.symbols.root_scope, name) orelse break :blk null;
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
        if (sameTy(actual, expected)) return true;
        if (expected == .optional) {
            if (actual == .null_ptr) return true;
            return try self.compatible(actual, expected.optional.*);
        }
        if (actual == .int_lit and expected.isInteger()) return true;
        if (actual == .null_ptr) return switch (expected) {
            .pointer, .slice, .named, .optional => true,
            else => false,
        };
        if (actual == .error_ty and self.isErrorType(expected)) return true;
        if (expected == .error_ty and self.isErrorType(actual)) return true;
        if (expected == .unknown or actual == .unknown) return true;
        return false;
    }
};

fn blockDefinitelyReturns(block: ast.Block) bool {
    for (block.statements) |stmt| {
        if (stmtDefinitelyReturns(stmt)) return true;
    }
    return false;
}

fn stmtDefinitelyReturns(stmt: ast.Stmt) bool {
    return switch (stmt) {
        .return_stmt, .fail_stmt => true,
        .break_stmt, .continue_stmt => true,
        .if_stmt => |iff| iff.else_block != null and
            blockDefinitelyReturns(iff.then_block) and
            blockDefinitelyReturns(iff.else_block.?),
        .unsafe_block => |block| blockDefinitelyReturns(block),
        .zone_block => |zb| blockDefinitelyReturns(zb.body),
        .defer_stmt => false,
        else => false,
    };
}

fn tyMangle(ty: Ty) []const u8 {
    return switch (ty) {
        .i8 => "i8", .i16 => "i16", .i32 => "i32", .i64 => "i64",
        .u8  => "u8",  .u16 => "u16", .u32 => "u32", .u64 => "u64",
        .bool => "bool", .void => "void", .usize => "usize", .isize => "isize",
        .pointer  => "ptr",  .optional => "opt", .slice => "slice",
        .named    => "named", .type_param => |n| n,
        else      => "unknown",
    };
}

fn sameTy(a: Ty, b: Ty) bool {
    if (@as(std.meta.Tag(Ty), a) != @as(std.meta.Tag(Ty), b)) return false;
    return switch (a) {
        .pointer => |pa| sameTy(pa.*, b.pointer.*),
        .optional => |oa| sameTy(oa.*, b.optional.*),
        .slice => |sa| sameTy(sa.*, b.slice.*),
        .array => |aa| sameTy(aa.elem.*, b.array.elem.*) and aa.len == b.array.len,
        .named => |id| id == b.named,
        .error_set => |variants| sameErrorVariants(variants, b.error_set),
        .fallible => |fa| sameTy(fa.ok.*, b.fallible.ok.*) and sameTy(fa.err.*, b.fallible.err.*),
        else => true,
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

fn parseArrayLen(expr: ast.Expr) u64 {
    return switch (expr.kind) {
        .int => |text| @intCast(@max(parseIntLiteral(text), 0)),
        else => 0,
    };
}

fn parseIntLiteral(text: []const u8) i128 {
    var end = text.len;
    while (end > 0 and std.ascii.isAlphabetic(text[end - 1])) end -= 1;
    const number_text = text[0..end];
    var value: i128 = 0;
    var start: usize = 0;
    if (number_text.len >= 2 and number_text[0] == '0' and (number_text[1] == 'x' or number_text[1] == 'X')) start = 2;
    const radix: i128 = if (start == 2) 16 else 10;
    for (number_text[start..]) |ch| {
        if (ch == '_') continue;
        const digit: i128 = if (ch >= '0' and ch <= '9')
            ch - '0'
        else if (ch >= 'a' and ch <= 'f')
            10 + ch - 'a'
        else if (ch >= 'A' and ch <= 'F')
            10 + ch - 'A'
        else
            break;
        value = value * radix + digit;
    }
    return value;
}

fn hasAttr(attrs: []const ast.Attribute, name: []const u8) bool {
    for (attrs) |attr| if (std.mem.eql(u8, attr.name, name)) return true;
    return false;
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
        "truncate_to",
        "ptr_from_int",
        "volatile_store",
        "sizeof",
        "unaligned_read",
        "asm",
        "atomic_load",
        "volatile",
        ".acquire",
    }) |builtin| {
        if (std.mem.eql(u8, name, builtin)) return true;
    }
    return false;
}
