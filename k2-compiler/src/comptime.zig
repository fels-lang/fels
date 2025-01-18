/// K2 compile-time interpreter.
///
/// Evaluates K2 expressions and statements at compile time.
/// Used by #run, #if, and generic struct instantiation.
///
/// The interpreter is a tree-walker over type-checked K2 AST.
/// It produces ComptimeValue results that feed back into the compiler.
const std   = @import("std");
const ast   = @import("ast.zig");
const sema  = @import("sema.zig");
const Span  = @import("lexer/span.zig").Span;

// ── Value types ───────────────────────────────────────────────────────────────

pub const ComptimeError = error{
    NotComptime,        // expression is not evaluable at compile time
    DivByZero,
    Overflow,
    IndexOutOfBounds,
    UndefinedBehaviour,
    OutOfMemory,
};

/// A value known at compile time.
pub const ComptimeValue = union(enum) {
    void,
    int:     i128,
    uint:    u128,
    float:   f64,
    bool:    bool,
    null_ptr,
    string:  []const u8,      // string literal slice

    struct_val: StructVal,
    array_val:  []const ComptimeValue,
    slice_val:  SliceVal,
    enum_val:   EnumVal,

    /// A K2 type used as a first-class value (for $T: type parameters).
    type_val:   sema.Ty,

    pub const StructVal = struct {
        type_name: []const u8,
        fields:    []const FieldEntry,

        pub const FieldEntry = struct {
            name:  []const u8,
            value: ComptimeValue,
        };
    };

    pub const SliceVal = struct {
        ptr: []const ComptimeValue,  // elements
        len: usize,
    };

    pub const EnumVal = struct {
        type_name: []const u8,
        variant:   []const u8,
        payload:   ?*const ComptimeValue,
    };

    /// Return the K2 sema type that corresponds to this value.
    pub fn ty(self: ComptimeValue, allocator: std.mem.Allocator) !sema.Ty {
        return switch (self) {
            .void     => .void,
            .int      => .int_lit,
            .uint     => .int_lit,
            .float    => .float_lit,
            .bool     => .bool,
            .null_ptr => .null_ptr,
            .string   => try allocSlice(allocator, .u8),
            .type_val => .{ .type_param = "type" },  // meta-type
            else      => .unknown,
        };
    }

    fn allocSlice(allocator: std.mem.Allocator, inner: sema.Ty) !sema.Ty {
        const p = try allocator.create(sema.Ty);
        p.* = inner;
        return .{ .slice = p };
    }

    pub fn format(
        self:  ComptimeValue,
        comptime _: []const u8,
        _:     std.fmt.Options,
        writer: anytype,
    ) !void {
        switch (self) {
            .void      => try writer.writeAll("void"),
            .int     => |v| try writer.print("{d}", .{v}),
            .uint    => |v| try writer.print("{d}", .{v}),
            .float   => |v| try writer.print("{d}", .{v}),
            .bool    => |v| try writer.writeAll(if (v) "true" else "false"),
            .null_ptr    => try writer.writeAll("null"),
            .string  => |s| try writer.print("\"{s}\"", .{s}),
            .type_val => |t| try writer.print("type({s})", .{sema.tyMangle(t)}),
            .enum_val => |e| try writer.print(".{s}", .{e.variant}),
            else        => try writer.writeAll("<comptime-value>"),
        }
    }
};

// ── Evaluator context ─────────────────────────────────────────────────────────

/// Carries everything the evaluator needs to interpret K2 code.
pub const ComptimeCtx = struct {
    allocator: std.mem.Allocator,
    module:    ast.Module,
    symbols:   sema.SymbolTable,
    env:       *const sema.TypeEnv,

    /// Local variable bindings for the current function/block scope.
    locals: std.StringHashMap(ComptimeValue),

    pub fn init(
        allocator: std.mem.Allocator,
        module:    ast.Module,
        symbols:   sema.SymbolTable,
        env:       *const sema.TypeEnv,
    ) ComptimeCtx {
        return .{
            .allocator = allocator,
            .module    = module,
            .symbols   = symbols,
            .env       = env,
            .locals    = std.StringHashMap(ComptimeValue).init(allocator),
        };
    }

    pub fn deinit(self: *ComptimeCtx) void {
        self.locals.deinit();
    }

    fn withLocals(self: *const ComptimeCtx) ComptimeCtx {
        var child = self.*;
        child.locals = std.StringHashMap(ComptimeValue).init(self.allocator);
        return child;
    }
};

// ── Expression evaluator ──────────────────────────────────────────────────────

/// Evaluate a K2 expression at compile time.
/// Returns `error.NotComptime` if the expression cannot be reduced.
pub fn evalExpr(ctx: *ComptimeCtx, expr: ast.Expr) ComptimeError!ComptimeValue {
    return switch (expr.kind) {
        // ── Literals ────────────────────────────────────────────────────────
        .int    => |text| .{ .int  = parseIntLit(text) },
        .float  => |text| .{ .float = parseFloatLit(text) },
        .bool   => |v|   .{ .bool = v },
        .null           => .null_ptr,
        .string => |s|   .{ .string = trimQuotes(s) },

        // ── Identifiers ─────────────────────────────────────────────────────
        .ident  => |name| blk: {
            // Check local scope first.
            if (ctx.locals.get(name)) |v| break :blk v;
            // Built-in scalar type names used as values (e.g. `type_info(i32)`).
            if (sema.fromBuiltinName(name)) |builtin_ty| {
                if (tyToValue(ctx, builtin_ty)) |v| return v else |_| {}
            }
            // Check top-level constants and named types in the module.
            if (ctx.symbols.resolve(ctx.symbols.root_scope, name)) |id| {
                if (ctx.symbols.symbol(id).kind == .type) {
                    return .{ .type_val = .{ .named = id } };
                }
                if (ctx.env.symbol_types.get(id)) |ty| {
                    return try tyToValue(ctx, ty);
                }
            }
            return error.NotComptime;
        },

        // ── Unary operators ──────────────────────────────────────────────────
        .unary => |u| blk: {
            const v = try evalExpr(ctx, u.expr.*);
            break :blk switch (u.op) {
                .neg => switch (v) {
                    .int   => |i|  ComptimeValue{ .int   = -i },
                    .uint  => |uv| ComptimeValue{ .int   = -@as(i128, @intCast(uv)) },
                    .float => |f|  ComptimeValue{ .float = -f },
                    else   => return error.NotComptime,
                },
                .not => switch (v) {
                    .bool  => |b|  ComptimeValue{ .bool  = !b },
                    else   => return error.NotComptime,
                },
                .bit_not => switch (v) {
                    .int   => |i|  ComptimeValue{ .int   = ~i },
                    .uint  => |uv| ComptimeValue{ .uint  = ~uv },
                    else   => return error.NotComptime,
                },
                else => return error.NotComptime,
            };
        },

        // ── Binary operators ─────────────────────────────────────────────────
        .binary => |b| try evalBinary(ctx, b),

        // ── Compound literal ─────────────────────────────────────────────────
        .compound_literal => |items| blk: {
            var vals: std.ArrayList(ComptimeValue) = .empty;
            errdefer vals.deinit(ctx.allocator);
            for (items) |item| try vals.append(ctx.allocator, try evalExpr(ctx, item));
            break :blk .{ .array_val = try vals.toOwnedSlice(ctx.allocator) };
        },

        // ── Type as value (for $T: type parameters) ──────────────────────────
        .type_ref => |tyref| blk: {
            const sema_ty = evalTypeRef(ctx, tyref) catch return error.NotComptime;
            break :blk .{ .type_val = sema_ty };
        },

        // ── Function calls ───────────────────────────────────────────────────
        .call   => |call| try evalCall(ctx, call),

        // ── Unsafe prefix is transparent ─────────────────────────────────────
        .unsafe_expr => |inner| try evalExpr(ctx, inner.*),

        // Field access: enum variant or struct field.
        .field  => |f| try evalField(ctx, f),

        // Indexing: array or slice
        .index => |idx| blk: {
            const base = try evalExpr(ctx, idx.base.*);
            const index = try evalExpr(ctx, idx.index.*);
            const i: usize = switch (index) {
                .int => |v| @intCast(@max(v, 0)),
                .uint => |v| @intCast(v),
                else => return error.NotComptime,
            };
            break :blk switch (base) {
                .array_val => |arr| if (i < arr.len) arr[i] else error.IndexOutOfBounds,
                .slice_val => |sv| if (i < sv.len) sv.ptr[i] else error.IndexOutOfBounds,
                .string => |s| if (i < s.len) .{ .int = s[i] } else error.IndexOutOfBounds,
                else => error.NotComptime,
            };
        },

        else    => error.NotComptime,
    };
}

// ── Statement evaluator ───────────────────────────────────────────────────────

const StmtResult = union(enum) {
    next,
    returned: ComptimeValue,
};

pub fn evalBlock(ctx: *ComptimeCtx, block: ast.Block) ComptimeError!StmtResult {
    for (block.statements) |stmt| {
        const r = try evalStmt(ctx, stmt);
        if (r == .returned) return r;
    }
    return .next;
}

fn evalStmt(ctx: *ComptimeCtx, stmt: ast.Stmt) ComptimeError!StmtResult {
    switch (stmt) {
        .local_infer => |li| {
            const val = try evalExpr(ctx, li.value);
            try ctx.locals.put(li.name, val);
        },
        .local_typed => |lt| {
            const val = try evalExpr(ctx, lt.value);
            try ctx.locals.put(lt.name, val);
        },
        .assign => |a| {
            if (a.target.kind == .ident) {
                const name = a.target.kind.ident;
                const val = try evalExpr(ctx, a.value);
                try ctx.locals.put(name, val);
            }
        },
        .return_stmt => |r| {
            const val = if (r.value) |v| try evalExpr(ctx, v) else .void;
            return .{ .returned = val };
        },
        .if_stmt => |iff| {
            const cond = if (iff.binding) |_| {
                // #run doesn't support optional bindings in if yet
                return error.NotComptime;
            } else try evalExpr(ctx, iff.condition);

            const cond_bool = switch (cond) {
                .bool => |b| b,
                else => return error.NotComptime,
            };
            if (cond_bool) {
                return try evalBlock(ctx, iff.then_block);
            } else if (iff.else_block) |eb| {
                return try evalBlock(ctx, eb);
            }
        },
        .while_stmt => |w| {
            var iterations: usize = 0;
            while (true) {
                const cond = try evalExpr(ctx, w.condition);
                const cond_bool = switch (cond) {
                    .bool => |b| b,
                    else => return error.NotComptime,
                };
                if (!cond_bool) break;
                iterations += 1;
                if (iterations > 1_000_000) return error.NotComptime; // infinite loop guard
                const r = try evalBlock(ctx, w.body);
                if (r == .returned) return r;
            }
        },
        .expr => |e| _ = try evalExpr(ctx, e),
        .for_slice => |fs| return try evalForSlice(ctx, fs),
        .for_range => |fr| return try evalForRange(ctx, fr),
        else => return error.NotComptime,
    }
    return .next;
}

fn evalForSlice(ctx: *ComptimeCtx, fs: ast.ForSliceStmt) ComptimeError!StmtResult {
    const iterable = try evalExpr(ctx, fs.iter);
    switch (iterable) {
        .array_val => |arr| {
            var i: usize = 0;
            while (i < arr.len) : (i += 1) {
                var child = ctx.withLocals();
                defer child.deinit();
                try child.locals.put(fs.binding, arr[i]);
                if (fs.index_binding) |idx_name| {
                    try child.locals.put(idx_name, .{ .uint = i });
                }
                const r = try evalBlock(&child, fs.body);
                if (r == .returned) return r;
            }
        },
        .slice_val => |sv| {
            var i: usize = 0;
            while (i < sv.len) : (i += 1) {
                var child = ctx.withLocals();
                defer child.deinit();
                try child.locals.put(fs.binding, sv.ptr[i]);
                if (fs.index_binding) |idx_name| {
                    try child.locals.put(idx_name, .{ .uint = i });
                }
                const r = try evalBlock(&child, fs.body);
                if (r == .returned) return r;
            }
        },
        .string => |s| {
            var i: usize = 0;
            while (i < s.len) : (i += 1) {
                var child = ctx.withLocals();
                defer child.deinit();
                try child.locals.put(fs.binding, .{ .int = s[i] });
                if (fs.index_binding) |idx_name| {
                    try child.locals.put(idx_name, .{ .uint = i });
                }
                const r = try evalBlock(&child, fs.body);
                if (r == .returned) return r;
            }
        },
        else => return error.NotComptime,
    }
    return .next;
}

fn evalForRange(ctx: *ComptimeCtx, fr: ast.ForRangeStmt) ComptimeError!StmtResult {
    const start_val = try evalExpr(ctx, fr.start);
    const end_val = try evalExpr(ctx, fr.end);
    const s: i128 = switch (start_val) { .int => |v| v, .uint => |v| @intCast(v), else => return error.NotComptime };
    const e: i128 = switch (end_val)   { .int => |v| v, .uint => |v| @intCast(v), else => return error.NotComptime };
    var i: i128 = s;
    const limit: i128 = if (fr.inclusive) e + 1 else e;
    while (i < limit) : (i += 1) {
        var child = ctx.withLocals();
        defer child.deinit();
        try child.locals.put(fr.binding, .{ .int = i });
        const r = try evalBlock(&child, fr.body);
        if (r == .returned) return r;
    }
    return .next;
}

// ── Binary operator evaluation ────────────────────────────────────────────────

fn evalBinary(ctx: *ComptimeCtx, b: ast.BinaryExpr) ComptimeError!ComptimeValue {
    const lhs = try evalExpr(ctx, b.left.*);
    const rhs = try evalExpr(ctx, b.right.*);

    // Integer operations
    if (lhs == .int and rhs == .int) {
        const l = lhs.int;
        const r = rhs.int;
        return switch (b.op) {
            .add => .{ .int = l +% r },
            .sub => .{ .int = l -% r },
            .mul => .{ .int = l *% r },
            .div => if (r == 0) error.DivByZero else .{ .int = @divTrunc(l, r) },
            .rem => if (r == 0) error.DivByZero else .{ .int = @rem(l, r) },
            .shl => .{ .int = l << @as(u7, @intCast(r & 127)) },
            .shr => .{ .int = l >> @as(u7, @intCast(r & 127)) },
            .bit_and => .{ .int = l & r },
            .bit_or  => .{ .int = l | r },
            .bit_xor => .{ .int = l ^ r },
            .equal    => .{ .bool = l == r },
            .not_equal=> .{ .bool = l != r },
            .less     => .{ .bool = l < r },
            .le       => .{ .bool = l <= r },
            .gt       => .{ .bool = l > r },
            .ge       => .{ .bool = l >= r },
            else => error.NotComptime,
        };
    }

    // Unsigned integer operations
    if (lhs == .uint and rhs == .uint) {
        const l = lhs.uint;
        const r = rhs.uint;
        return switch (b.op) {
            .add => .{ .uint = l +% r },
            .sub => .{ .uint = l -% r },
            .mul => .{ .uint = l *% r },
            .div => if (r == 0) error.DivByZero else .{ .uint = l / r },
            .rem => if (r == 0) error.DivByZero else .{ .uint = l % r },
            .shl => .{ .uint = l << @as(u7, @intCast(r & 127)) },
            .shr => .{ .uint = l >> @as(u7, @intCast(r & 127)) },
            .bit_and => .{ .uint = l & r },
            .bit_or  => .{ .uint = l | r },
            .bit_xor => .{ .uint = l ^ r },
            .equal    => .{ .bool = l == r },
            .not_equal=> .{ .bool = l != r },
            .less     => .{ .bool = l < r },
            .le       => .{ .bool = l <= r },
            .gt       => .{ .bool = l > r },
            .ge       => .{ .bool = l >= r },
            else => error.NotComptime,
        };
    }

    // Float operations
    if (lhs == .float and rhs == .float) {
        const l = lhs.float;
        const r = rhs.float;
        return switch (b.op) {
            .add => .{ .float = l + r },
            .sub => .{ .float = l - r },
            .mul => .{ .float = l * r },
            .div => if (r == 0.0) error.DivByZero else .{ .float = l / r },
            .rem => if (r == 0.0) error.DivByZero else .{ .float = @rem(l, r) },
            .equal    => .{ .bool = l == r },
            .not_equal=> .{ .bool = l != r },
            .less     => .{ .bool = l < r },
            .le       => .{ .bool = l <= r },
            .gt       => .{ .bool = l > r },
            .ge       => .{ .bool = l >= r },
            else => error.NotComptime,
        };
    }

    // Boolean operations
    if (lhs == .bool and rhs == .bool) {
        const l = lhs.bool;
        const r = rhs.bool;
        return switch (b.op) {
            .and_and  => .{ .bool = l and r },
            .or_or    => .{ .bool = l or  r },
            .equal    => .{ .bool = l == r },
            .not_equal=> .{ .bool = l != r },
            else => error.NotComptime,
        };
    }

    // String equality
    if (lhs == .string and rhs == .string) {
        return switch (b.op) {
            .equal     => .{ .bool = std.mem.eql(u8, lhs.string, rhs.string) },
            .not_equal => .{ .bool = !std.mem.eql(u8, lhs.string, rhs.string) },
            else => error.NotComptime,
        };
    }

    // Type equality (for #if T == .windows etc.)
    if (lhs == .enum_val and rhs == .enum_val) {
        return switch (b.op) {
            .equal     => .{ .bool = std.mem.eql(u8, lhs.enum_val.variant, rhs.enum_val.variant) },
            .not_equal => .{ .bool = !std.mem.eql(u8, lhs.enum_val.variant, rhs.enum_val.variant) },
            else => error.NotComptime,
        };
    }

    return error.NotComptime;
}

// ── Function call evaluation ──────────────────────────────────────────────────

fn evalCall(ctx: *ComptimeCtx, call: ast.CallExpr) ComptimeError!ComptimeValue {
    const name = switch (call.callee.kind) {
        .ident => |n| n,
        else   => return error.NotComptime,
    };

    // Built-in comptime functions
    if (std.mem.eql(u8, name, "sizeof")) {
        if (call.args.len > 0) {
            const arg = switch (call.args[0]) { .positional => |e| e, .named => |n| n.value };
            const v = try evalExpr(ctx, arg);
            if (v == .type_val) return .{ .uint = typeSize(ctx, v.type_val) };
        }
        return error.NotComptime;
    }
    if (std.mem.eql(u8, name, "type_name")) {
        if (call.args.len > 0) {
            const arg = switch (call.args[0]) { .positional => |e| e, .named => |n| n.value };
            const v = try evalExpr(ctx, arg);
            if (v == .type_val) return .{ .string = sema.tyMangle(v.type_val) };
        }
        return error.NotComptime;
    }
    if (std.mem.eql(u8, name, "type_info")) {
        if (call.args.len > 0) {
            const arg = switch (call.args[0]) { .positional => |e| e, .named => |n| n.value };
            const v = try evalExpr(ctx, arg);
            if (v == .type_val) return try typeInfo(ctx, v.type_val);
        }
        return error.NotComptime;
    }

    // Look up the function in the module.
    const sym_id = ctx.symbols.resolve(ctx.symbols.root_scope, name) orelse return error.NotComptime;
    if (ctx.symbols.symbol(sym_id).kind != .function) return error.NotComptime;

    // Find the function decl.
    const fn_decl = findFunctionDecl(ctx.module, name) orelse return error.NotComptime;
    if (fn_decl.body == null) return error.NotComptime; // extern function

    // Evaluate arguments.
    if (call.args.len != fn_decl.params.len) return error.NotComptime;
    var child = ctx.withLocals();
    defer child.deinit();

    for (call.args, fn_decl.params) |arg, param| {
        const arg_expr = switch (arg) { .positional => |e| e, .named => |n| n.value };
        const arg_val  = try evalExpr(ctx, arg_expr);
        try child.locals.put(param.name, arg_val);
    }

    // Execute the function body.
    const result = try evalBlock(&child, fn_decl.body.?);
    return switch (result) {
        .returned => |v| v,
        .next     => .void,
    };
}

fn findFunctionDecl(module: ast.Module, name: []const u8) ?ast.FunctionDecl {
    for (module.items) |item| switch (item) {
        .function => |f| if (std.mem.eql(u8, f.name, name)) return f,
        else => {},
    };
    return null;
}

// ── Field / enum access ───────────────────────────────────────────────────────

fn evalField(ctx: *ComptimeCtx, f: ast.FieldExpr) ComptimeError!ComptimeValue {
    // Enum variant access: `Direction.north` or `TARGET.os`
    if (f.base.kind == .ident) {
        const base_name = f.base.kind.ident;
        // Check for TARGET pseudo-module
        if (std.mem.eql(u8, base_name, "TARGET")) {
            return evalTargetField(f.name);
        }
        // Check for enum type variant access
        if (ctx.symbols.resolve(ctx.symbols.root_scope, base_name)) |id| {
            if (ctx.symbols.symbol(id).kind == .type) {
                return .{ .enum_val = .{
                    .type_name = base_name,
                    .variant   = f.name,
                    .payload   = null,
                } };
            }
        }
    }

    // Struct field access on a comptime struct value.
    const base = try evalExpr(ctx, f.base.*);
    switch (base) {
        .struct_val => |sv| {
            for (sv.fields) |field| {
                if (std.mem.eql(u8, field.name, f.name)) return field.value;
            }
        },
        .slice_val => |sv| {
            if (std.mem.eql(u8, f.name, "len")) return .{ .uint = sv.len };
        },
        .array_val => |arr| {
            if (std.mem.eql(u8, f.name, "len")) return .{ .uint = arr.len };
        },
        else => {},
    }
    return error.NotComptime;
}

// ── TARGET pseudo-module ──────────────────────────────────────────────────────

fn evalTargetField(field: []const u8) ComptimeError!ComptimeValue {
    if (std.mem.eql(u8, field, "os")) {
        const os = @import("builtin").os.tag;
        const variant: []const u8 = switch (os) {
            .windows => "windows",
            .linux   => "linux",
            .macos   => "macos",
            else     => "unknown",
        };
        return .{ .enum_val = .{ .type_name = "Os", .variant = variant, .payload = null } };
    }
    if (std.mem.eql(u8, field, "arch")) {
        const arch = @import("builtin").cpu.arch;
        const variant: []const u8 = switch (arch) {
            .x86_64  => "x86_64",
            .aarch64 => "aarch64",
            else     => "unknown",
        };
        return .{ .enum_val = .{ .type_name = "Arch", .variant = variant, .payload = null } };
    }
    if (std.mem.eql(u8, field, "debug")) {
        const is_debug = @import("builtin").mode == .Debug;
        return .{ .bool = is_debug };
    }
    return error.NotComptime;
}

// ── Type reflection ───────────────────────────────────────────────────────────

/// Evaluate a TypeRef to a sema.Ty at compile time.
fn evalTypeRef(ctx: *ComptimeCtx, tyref: ast.TypeRef) !sema.Ty {
    return switch (tyref) {
        .named => |named| blk: {
            if (sema.fromBuiltinName(named.name)) |t| break :blk t;
            const id = ctx.symbols.resolve(ctx.symbols.root_scope, named.name) orelse
                return error.NotComptime;
            break :blk .{ .named = id };
        },
        .pointer => |p| .{ .pointer = try boxTy(ctx, try evalTypeRef(ctx, p.inner.*)) },
        .many_pointer => |p| .{ .pointer = try boxTy(ctx, try evalTypeRef(ctx, p.inner.*)) },
        .optional => |o| .{ .optional = try boxTy(ctx, try evalTypeRef(ctx, o.inner.*)) },
        .slice => |s| .{ .slice = try boxTy(ctx, try evalTypeRef(ctx, s.inner.*)) },
        .borrow => |b| .{ .borrow = try boxTy(ctx, try evalTypeRef(ctx, b.inner.*)) },
        .array => |a| blk: {
            const elem = try evalTypeRef(ctx, a.inner.*);
            const len_val = evalExpr(ctx, a.len.*) catch return error.NotComptime;
            const len: u64 = switch (len_val) {
                .int => |v| @intCast(@max(v, 0)),
                .uint => |v| @intCast(v),
                else => return error.NotComptime,
            };
            break :blk .{ .array = .{ .elem = try boxTy(ctx, elem), .len = len } };
        },
        else => error.NotComptime,
    };
}

fn boxTy(ctx: *ComptimeCtx, inner: sema.Ty) !*const sema.Ty {
    const p = try ctx.allocator.create(sema.Ty);
    p.* = inner;
    return p;
}

/// #type_info(T) — return a ComptimeValue describing the type T.
pub fn typeInfo(ctx: *ComptimeCtx, ty: sema.Ty) ComptimeError!ComptimeValue {
    return switch (ty) {
        .i8  => intTypeInfo(ctx, "i8",  8,  true),
        .i16 => intTypeInfo(ctx, "i16", 16, true),
        .i32 => intTypeInfo(ctx, "i32", 32, true),
        .i64 => intTypeInfo(ctx, "i64", 64, true),
        .isize => intTypeInfo(ctx, "isize", 64, true),
        .u8  => intTypeInfo(ctx, "u8",  8,  false),
        .u16 => intTypeInfo(ctx, "u16", 16, false),
        .u32 => intTypeInfo(ctx, "u32", 32, false),
        .u64 => intTypeInfo(ctx, "u64", 64, false),
        .usize => intTypeInfo(ctx, "usize", 64, false),
        .byte  => intTypeInfo(ctx, "byte", 8, false),
        .f32 => floatTypeInfo(ctx, "f32", 32),
        .f64 => floatTypeInfo(ctx, "f64", 64),
        .bool => makeTypeInfo(ctx, "bool", &.{
            .{ .name = "name", .value = .{ .string = "bool" } },
        }),
        .void => makeTypeInfo(ctx, "void", &.{
            .{ .name = "name", .value = .{ .string = "void" } },
        }),
        .pointer => |inner| wrappedTypeInfo(ctx, "pointer", inner.*, &.{
            .{ .name = "is_const", .value = .{ .bool = false } },
        }),
        .const_ptr => |inner| wrappedTypeInfo(ctx, "pointer", inner.*, &.{
            .{ .name = "is_const", .value = .{ .bool = true } },
        }),
        .slice => |inner| wrappedTypeInfo(ctx, "slice", inner.*, &.{}),
        .optional => |inner| wrappedTypeInfo(ctx, "optional", inner.*, &.{}),
        .borrow => |inner| wrappedTypeInfo(ctx, "borrow", inner.*, &.{}),
        .array => |arr| blk: {
            const elem_info = try typeInfo(ctx, arr.elem.*);
            break :blk makeTypeInfo(ctx, "array", &.{
                .{ .name = "name", .value = .{ .string = "array" } },
                .{ .name = "len",  .value = .{ .uint = arr.len } },
                .{ .name = "elem", .value = .{ .type_val = arr.elem.* } },
                .{ .name = "elem_info", .value = elem_info },
            });
        },
        .named => |id| try namedTypeInfo(ctx, id),
        else => error.NotComptime,
    };
}

fn namedTypeInfo(ctx: *ComptimeCtx, id: sema.SymbolId) ComptimeError!ComptimeValue {
    const layout = ctx.env.layouts.get(id) orelse return error.NotComptime;
    const sym    = ctx.symbols.symbol(id);
    switch (layout.kind) {
        .struct_type => |fields| {
            var field_vals: std.ArrayList(ComptimeValue) = .empty;
            errdefer field_vals.deinit(ctx.allocator);
            var total_size: u64 = 0;
            for (fields) |f| {
                total_size += typeSize(ctx, f.ty);
                try field_vals.append(ctx.allocator, try makeTypeInfo(ctx, "field", &.{
                    .{ .name = "name", .value = .{ .string = f.name } },
                    .{ .name = "type", .value = .{ .type_val = f.ty } },
                    .{ .name = "offset", .value = .{ .uint = 0 } },
                }));
            }
            return makeTypeInfo(ctx, "struct", &.{
                .{ .name = "name",   .value = .{ .string = sym.name } },
                .{ .name = "fields", .value = .{ .array_val = try field_vals.toOwnedSlice(ctx.allocator) } },
                .{ .name = "size",   .value = .{ .uint = total_size } },
                .{ .name = "is_packed", .value = .{ .bool = layout.is_packed } },
            });
        },
        .variant_type => |variants| {
            var variant_vals: std.ArrayList(ComptimeValue) = .empty;
            errdefer variant_vals.deinit(ctx.allocator);
            for (variants) |v| {
                try variant_vals.append(ctx.allocator, try makeTypeInfo(ctx, "variant", &.{
                    .{ .name = "name",  .value = .{ .string = v.name } },
                    .{ .name = "index", .value = .{ .uint = v.index } },
                    .{ .name = "has_payload", .value = .{ .bool = v.payload != null } },
                    .{ .name = "payload", .value = if (v.payload) |p| .{ .type_val = p } else .void },
                }));
            }
            return makeTypeInfo(ctx, "enum", &.{
                .{ .name = "name",     .value = .{ .string = sym.name } },
                .{ .name = "variants", .value = .{ .array_val = try variant_vals.toOwnedSlice(ctx.allocator) } },
            });
        },
        .error_set => |variants| {
            var variant_vals: std.ArrayList(ComptimeValue) = .empty;
            errdefer variant_vals.deinit(ctx.allocator);
            for (variants) |v| {
                try variant_vals.append(ctx.allocator, try makeTypeInfo(ctx, "error_variant", &.{
                    .{ .name = "name", .value = .{ .string = v.name } },
                    .{ .name = "has_payload", .value = .{ .bool = v.payload != null } },
                }));
            }
            return makeTypeInfo(ctx, "error_set", &.{
                .{ .name = "name",     .value = .{ .string = sym.name } },
                .{ .name = "variants", .value = .{ .array_val = try variant_vals.toOwnedSlice(ctx.allocator) } },
            });
        },
        .interface_type => |methods| {
            return makeTypeInfo(ctx, "interface", &.{
                .{ .name = "name",         .value = .{ .string = sym.name } },
                .{ .name = "method_count", .value = .{ .uint = methods.len } },
            });
        },
    }
}

fn makeTypeInfo(ctx: *ComptimeCtx, kind: []const u8, entries: []const ComptimeValue.StructVal.FieldEntry) !ComptimeValue {
    var all: std.ArrayList(ComptimeValue.StructVal.FieldEntry) = .empty;
    defer all.deinit(ctx.allocator);
    try all.append(ctx.allocator, .{ .name = "kind", .value = .{ .string = kind } });
    try all.appendSlice(ctx.allocator, entries);
    return .{ .struct_val = .{
        .type_name = "TypeInfo",
        .fields    = try all.toOwnedSlice(ctx.allocator),
    } };
}

fn intTypeInfo(ctx: *ComptimeCtx, name: []const u8, bits: u64, signed: bool) !ComptimeValue {
    return makeTypeInfo(ctx, "int", &.{
        .{ .name = "name",   .value = .{ .string = name } },
        .{ .name = "bits",   .value = .{ .uint = bits } },
        .{ .name = "signed", .value = .{ .bool = signed } },
    });
}

fn floatTypeInfo(ctx: *ComptimeCtx, name: []const u8, bits: u64) !ComptimeValue {
    return makeTypeInfo(ctx, "float", &.{
        .{ .name = "name", .value = .{ .string = name } },
        .{ .name = "bits", .value = .{ .uint = bits } },
    });
}

fn wrappedTypeInfo(
    ctx: *ComptimeCtx,
    kind: []const u8,
    inner: sema.Ty,
    extra: []const ComptimeValue.StructVal.FieldEntry,
) ComptimeError!ComptimeValue {
    const inner_info = try typeInfo(ctx, inner);
    var all: std.ArrayList(ComptimeValue.StructVal.FieldEntry) = .empty;
    defer all.deinit(ctx.allocator);
    try all.append(ctx.allocator, .{ .name = "elem", .value = .{ .type_val = inner } });
    try all.append(ctx.allocator, .{ .name = "elem_info", .value = inner_info });
    try all.appendSlice(ctx.allocator, extra);
    return makeTypeInfo(ctx, kind, all.items);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn tyToValue(ctx: *ComptimeCtx, ty: sema.Ty) ComptimeError!ComptimeValue {
    _ = ctx;
    return switch (ty) {
        .bool     => .{ .type_val = .bool },
        .i8       => .{ .type_val = .i8 },
        .i16      => .{ .type_val = .i16 },
        .i32      => .{ .type_val = .i32 },
        .i64      => .{ .type_val = .i64 },
        .u8       => .{ .type_val = .u8 },
        .u16      => .{ .type_val = .u16 },
        .u32      => .{ .type_val = .u32 },
        .u64      => .{ .type_val = .u64 },
        .usize    => .{ .type_val = .usize },
        .isize    => .{ .type_val = .isize },
        .f32      => .{ .type_val = .f32 },
        .f64      => .{ .type_val = .f64 },
        .void     => .{ .type_val = .void },
        .byte     => .{ .type_val = .byte },
        else      => error.NotComptime,
    };
}

/// Compute the size of a type in bytes at compile time (x86_64 layout).
fn typeSize(ctx: *ComptimeCtx, ty: sema.Ty) u64 {
    return switch (ty) {
        .void           => 0,
        .bool, .i8, .u8, .byte => 1,
        .i16, .u16      => 2,
        .i32, .u32, .f32 => 4,
        .i64, .u64, .f64, .isize, .usize, .addr => 8,
        .pointer        => 8,
        .optional       => |inner| if (inner.* == .pointer) 8 else 1 + typeSize(ctx, inner.*),
        .slice          => 16, // ptr + len
        .array          => |arr| arr.len * typeSize(ctx, arr.elem.*),
        .named          => |id| blk: {
            const layout = ctx.env.layouts.get(id) orelse break :blk 8;
            switch (layout.kind) {
                .struct_type => |fields| {
                    var total: u64 = 0;
                    for (fields) |f| total += typeSize(ctx, f.ty);
                    break :blk total;
                },
                .variant_type => |variants| {
                    var max_payload: u64 = 0;
                    for (variants) |v| {
                        if (v.payload) |p| {
                            const ps = typeSize(ctx, p);
                            if (ps > max_payload) max_payload = ps;
                        }
                    }
                    break :blk 4 + max_payload; // u32 discriminant + max payload
                },
                .error_set => break :blk 4,
                else => break :blk 8,
            }
        },
        .int_lit, .float_lit => 8,
        .type_param       => 8,
        else             => 8,
    };
}

fn parseFloatLit(text: []const u8) f64 {
    // Strip type suffix (f32, f64)
    var end = text.len;
    while (end > 0 and std.ascii.isAlphabetic(text[end - 1])) end -= 1;
    const num = text[0..end];
    if (num.len == 0) return 0.0;
    return std.fmt.parseFloat(f64, num) catch 0.0;
}

fn parseIntLit(text: []const u8) i128 {
    // Strip type suffix (u32, usize, etc.)
    var end = text.len;
    while (end > 0 and std.ascii.isAlphabetic(text[end - 1])) end -= 1;
    const num = text[0..end];
    if (num.len == 0) return 0;
    var negative = false;
    var start: usize = 0;
    if (num[0] == '-') { negative = true; start = 1; }
    const radix: i128 = if (num.len > start + 1 and num[start] == '0' and
        (num[start+1] == 'x' or num[start+1] == 'X')) blk: { start += 2; break :blk 16; }
        else if (num.len > start + 1 and num[start] == '0' and
        (num[start+1] == 'b' or num[start+1] == 'B')) blk: { start += 2; break :blk 2; }
        else 10;
    var value: i128 = 0;
    for (num[start..]) |c| {
        if (c == '_') continue;
        const d: i128 = if (c >= '0' and c <= '9') c - '0'
            else if (c >= 'a' and c <= 'f') 10 + c - 'a'
            else if (c >= 'A' and c <= 'F') 10 + c - 'A'
            else break;
        if (d >= radix) break;
        value = value * radix + d;
    }
    return if (negative) -value else value;
}

fn trimQuotes(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"')
        return text[1 .. text.len - 1];
    return text;
}
