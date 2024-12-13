const std = @import("std");
const ast = @import("ast.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;
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
        self.generic_instantiations.deinit(allocator);
    }

    pub fn set(self: *TypeEnv, id: SymbolId, ty: Ty) !void {
        try self.symbol_types.put(id, ty);
    }

    pub fn get(self: TypeEnv, id: SymbolId) ?Ty {
        return self.symbol_types.get(id);
    }
};

pub const GenericInstantiation = struct {
    fn_name: []const u8,
    type_args: []const ast.TypeRef,
    mangled_name: []const u8,
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
    var checker = Checker.init(allocator, symbols);
    defer checker.deinit();

    try checker.checkModule(module);
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
    }

    fn finish(self: *Checker) TypeEnv {
        const env = self.env;
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
                    var params = std.ArrayList(ParamSig).empty;
                    errdefer params.deinit(self.allocator);
                    for (decl.params) |param| {
                        try params.append(self.allocator, .{
                            .name = param.name,
                            .ty = try self.typeFromRef(param.ty),
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
                        .type_params = &.{},
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
        self.current_return_ty = try self.typeFromRef(decl.return_ty);
        self.current_error_ty = if (decl.error_ty) |err| try self.typeFromErrorSpec(err) else null;
        try self.pushScope();
        defer self.popScope();

        for (decl.params) |param| {
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
                if (!try self.compatible(actual_ty, self.current_return_ty)) return error.SemanticFailed;
            },
            .fail_stmt => |fail| try self.checkFail(fail),
            .if_stmt => |iff| {
                if (iff.binding) |binding| {
                    const bound_ty = try self.inferExpr(binding.value);
                    if (bound_ty != .optional) return error.SemanticFailed;
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
            .unsafe_block => |unsafe_block| try self.checkBlock(unsafe_block),
            .break_stmt => if (self.loop_depth == 0) return error.SemanticFailed,
            .continue_stmt => if (self.loop_depth == 0) return error.SemanticFailed,
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
                return error.SemanticFailed;
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

        if (std.mem.eql(u8, name, "truncate_to")) return self.firstTypeArg(call) orelse error.SemanticFailed;
        if (std.mem.eql(u8, name, "ptr_from_int")) return self.firstTypeArg(call) orelse error.SemanticFailed;
        if (std.mem.eql(u8, name, "volatile_store")) return .void;
        if (std.mem.eql(u8, name, "sizeof")) return .usize;
        if (std.mem.eql(u8, name, "unaligned_read")) return self.firstTypeArg(call) orelse error.SemanticFailed;
        if (std.mem.eql(u8, name, "asm")) return .void;
        if (std.mem.eql(u8, name, "atomic_load")) return .u32;

        const id = self.symbols.resolve(self.symbols.root_scope, name) orelse return error.SemanticFailed;
        if (self.symbols.symbol(id).kind != .function) return error.SemanticFailed;
        const sig = self.env.fn_sigs.get(id) orelse return error.SemanticFailed;
        if (call.args.len != sig.params.len) return error.SemanticFailed;

        for (call.args, sig.params) |arg, param| {
            const arg_ty = switch (arg) {
                .positional => |value| try self.inferExpr(value),
                .named => |named| try self.inferExpr(named.value),
            };
            if (!try self.compatible(arg_ty, param.ty)) return error.SemanticFailed;
        }
        if (sig.error_ty) |err_ty| {
            return .{ .fallible = .{ .ok = try self.boxTy(sig.return_ty), .err = try self.boxTy(err_ty) } };
        }
        return sig.return_ty;
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

    fn typeFromRef(self: *Checker, ty: ast.TypeRef) SemanticError!Ty {
        switch (ty) {
            .named => |named| {
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
        const err_ty = self.current_error_ty orelse return error.SemanticFailed;
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
        if (actual == .error_ty and isErrorTy(expected)) return true;
        if (expected == .error_ty and isErrorTy(actual)) return true;
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

fn isErrorTy(ty: Ty) bool {
    return switch (ty) {
        .error_ty, .error_set, .named => true,
        else => false,
    };
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
