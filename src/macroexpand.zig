const std = @import("std");
const ast = @import("ast.zig");
const Span = @import("lexer/span.zig").Span;

// Macro expansion — Phase 2, template macros. Runs once, before sema. A
// `name :: macro(params) { return #quote { ... }; }` is a compile-time AST template.
// At each `#insert name(args);` we substitute the arg ASTs into the template's $param
// holes, rename the template's locals for hygiene, and rewrite the #insert to a literal
// #quote { <result> } that the front-end re-checks. Macro decls are dropped afterward,
// never lowered.
//
// It's deliberately a template engine: a macro body must be one `return #quote {...}`.
// Macros that RUN code (loops/logic) to build the AST are a later slice.

pub const ExpandError = error{ SemanticFailed, OutOfMemory };

/// Bindings from a macro's parameter names to the caller's argument ASTs.
const Env = std.StringHashMap(ast.Expr);
/// Hygiene: a template-introduced local name → its fresh, collision-free name.
const Hyg = std.StringHashMap([]const u8);

/// The field a `#for f in fields(T)` is at: `$(f.name)`, `$(f.ty)`, `$(f.index)`, `$(f.text)`.
const FieldRecord = struct { name: []const u8, ty: ast.TypeRef, index: usize };

/// The node ids an expansion gives what it makes, above those of the parser (from 1), its
/// lifted lambdas (1_000_000_000) and the formats (2_000_000_000).
const macro_id_base: ast.NodeId = 3_000_000_000;

const Expander = struct {
    arena: std.mem.Allocator,
    /// The next node id. Each copy a template makes is its own expression: the checker keys
    /// types by id, and the copies of a `#for` over fields have different types.
    next_id: ast.NodeId = macro_id_base,
    macros: std.StringHashMap(ast.FunctionDecl),
    /// The program's structs, by name, for `#for f in fields(T)`.
    structs: std.StringHashMap(ast.StructDecl),
    /// The `#for f in fields(T)` loops being unrolled: `f` → the field it is at.
    records: std.StringHashMap(FieldRecord),
    /// Monotonic counter so each expansion's hygienic names are distinct.
    gensym: u32 = 0,

    fn fail(comptime fmt: []const u8, args: anytype) ExpandError {
        std.debug.print("error: " ++ fmt ++ "\n", args);
        return error.SemanticFailed;
    }

    fn dup(self: *Expander, e: ast.Expr) ExpandError!*const ast.Expr {
        const p = try self.arena.create(ast.Expr);
        p.* = e;
        return p;
    }

    // module walk: collect macros, expand bodies, drop macro decls

    fn expandModule(self: *Expander, module: ast.Module) ExpandError!ast.Module {
        for (module.items) |item| switch (item) {
            .function => |f| if (f.is_macro) try self.macros.put(f.name, f),
            .type_decl => |d| switch (d.kind) {
                .struct_type => |st| if (!self.structs.contains(d.name)) try self.structs.put(d.name, st),
                else => {},
            },
            else => {},
        };

        var out: std.ArrayList(ast.Item) = .empty;
        for (module.items) |item| switch (item) {
            .function => |f| {
                if (f.is_macro) continue; // dropped — never lowered
                var nf = f;
                if (f.body) |body| nf.body = try self.expandBody(body);
                try out.append(self.arena, .{ .function = nf });
            },
            .interface_impl => |impl| {
                var methods: std.ArrayList(ast.FunctionDecl) = .empty;
                for (impl.methods) |m| {
                    var nm = m;
                    if (m.body) |body| nm.body = try self.expandBody(body);
                    try methods.append(self.arena, nm);
                }
                var ni = impl;
                ni.methods = try methods.toOwnedSlice(self.arena);
                try out.append(self.arena, .{ .interface_impl = ni });
            },
            .const_decl => |d| {
                var nd = d;
                if (hasInsertExpr(d.value)) {
                    var env = Env.init(self.arena);
                    var hyg = Hyg.init(self.arena);
                    nd.value = try self.substExpr(d.value, &env, &hyg);
                }
                try out.append(self.arena, .{ .const_decl = nd });
            },
            else => try out.append(self.arena, item),
        };

        return .{ .file_name = module.file_name, .items = try out.toOwnedSlice(self.arena) };
    }

    /// A function body with its macros expanded: the `#insert` statements, then the
    /// `#insert` expressions, if it has any (a substitution with nothing bound rebuilds the
    /// body and expands each one).
    fn expandBody(self: *Expander, body: ast.Block) ExpandError!ast.Block {
        const stmts = try self.expandBlock(body);
        if (!hasInsertExpr(stmts)) return stmts;
        var env = Env.init(self.arena);
        var hyg = Hyg.init(self.arena);
        return self.substBlock(stmts, &env, &hyg);
    }

    /// Walk a block, rewriting any `#insert <macrocall>` (and recursing into
    /// nested blocks) — everything else is structurally preserved.
    fn expandBlock(self: *Expander, block: ast.Block) ExpandError!ast.Block {
        var out: std.ArrayList(ast.Stmt) = .empty;
        for (block.statements) |stmt| try self.expandStmt(stmt, &out);
        return .{ .statements = try out.toOwnedSlice(self.arena), .span = block.span };
    }

    fn expandStmt(self: *Expander, stmt: ast.Stmt, out: *std.ArrayList(ast.Stmt)) ExpandError!void {
        switch (stmt) {
            .insert_stmt => |ins| {
                // `#insert macrocall(args);` → expand to `#insert #quote { ... }`.
                if (ins.operand.kind == .call) {
                    const call = ins.operand.kind.call;
                    if (call.callee.kind == .ident) {
                        if (self.macros.get(call.callee.kind.ident)) |macro| {
                            const expanded = try self.expandMacroCall(macro, call);
                            // Recurse so a macro that itself uses #insert expands too.
                            const inner = try self.expandBlock(expanded);
                            const q = ast.Expr{ .id = ins.operand.id, .kind = .{ .quote = inner }, .span = ins.span };
                            try out.append(self.arena, .{ .insert_stmt = .{ .operand = q, .span = ins.span } });
                            return;
                        }
                    }
                }
                // `#insert #quote { ... }` (slice-1 literal) — recurse into it.
                if (ins.operand.kind == .quote) {
                    const inner = try self.expandBlock(ins.operand.kind.quote);
                    const q = ast.Expr{ .id = ins.operand.id, .kind = .{ .quote = inner }, .span = ins.operand.span };
                    try out.append(self.arena, .{ .insert_stmt = .{ .operand = q, .span = ins.span } });
                    return;
                }
                try out.append(self.arena, stmt); // sema rejects non-quote operands
            },
            // Recurse into block-bearing statements so nested #insert expands.
            .if_stmt => |s| {
                var n = s;
                n.then_block = try self.expandBlock(s.then_block);
                if (s.else_block) |eb| n.else_block = try self.expandBlock(eb);
                try out.append(self.arena, .{ .if_stmt = n });
            },
            .while_stmt => |s| {
                var n = s;
                n.body = try self.expandBlock(s.body);
                try out.append(self.arena, .{ .while_stmt = n });
            },
            .for_range => |s| {
                var n = s;
                n.body = try self.expandBlock(s.body);
                try out.append(self.arena, .{ .for_range = n });
            },
            .for_slice => |s| {
                var n = s;
                n.body = try self.expandBlock(s.body);
                try out.append(self.arena, .{ .for_slice = n });
            },
            .match_stmt => |s| {
                var arms: std.ArrayList(ast.MatchArm) = .empty;
                for (s.arms) |arm| {
                    var na = arm;
                    na.body = try self.expandBlock(arm.body);
                    try arms.append(self.arena, na);
                }
                var n = s;
                n.arms = try arms.toOwnedSlice(self.arena);
                try out.append(self.arena, .{ .match_stmt = n });
            },
            .zone_block => |s| {
                var n = s;
                n.body = try self.expandBlock(s.body);
                try out.append(self.arena, .{ .zone_block = n });
            },
            .defer_stmt => |s| {
                var n = s;
                n.body = try self.expandBlock(s.body);
                try out.append(self.arena, .{ .defer_stmt = n });
            },
            .unsafe_block => |b| try out.append(self.arena, .{ .unsafe_block = try self.expandBlock(b) }),
            .comptime_run => |b| try out.append(self.arena, .{ .comptime_run = try self.expandBlock(b) }),
            // `#for i in a..b { ... }` in ordinary code: unroll with literal
            // bounds, then re-expand each emitted statement (nested #insert/#for).
            .comptime_for => |cf| {
                var env = Env.init(self.arena);
                var hyg = Hyg.init(self.arena);
                var tmp: std.ArrayList(ast.Stmt) = .empty;
                try self.unrollFor(cf, &env, &hyg, &tmp);
                for (tmp.items) |s| try self.expandStmt(s, out);
            },
            .comptime_if => |s| {
                var n = s;
                n.then_block = try self.expandBlock(s.then_block);
                if (s.else_block) |eb| n.else_block = try self.expandBlock(eb);
                try out.append(self.arena, .{ .comptime_if = n });
            },
            else => try out.append(self.arena, stmt),
        }
    }

    // macro expansion: bind args, build hygiene map, substitute

    fn expandMacroCall(self: *Expander, macro: ast.FunctionDecl, call: ast.CallExpr) ExpandError!ast.Block {
        if (call.args.len != macro.params.len) {
            return fail("macro `{s}` expects {d} argument(s), but {d} were provided", .{ macro.name, macro.params.len, call.args.len });
        }

        var env = Env.init(self.arena);
        for (macro.params, call.args) |param, arg| {
            const arg_expr = switch (arg) {
                .positional => |e| e,
                .named => |n| n.value,
            };
            try checkMacroArgType(macro.name, param, arg_expr);
            try env.put(param.name, arg_expr);
        }

        // An expression macro inserted as a statement: its expression is the statement.
        if (macroExprTemplate(macro)) |e| {
            var no_hyg = Hyg.init(self.arena);
            const stmts = try self.arena.alloc(ast.Stmt, 1);
            stmts[0] = .{ .expr = try self.substExpr(e, &env, &no_hyg) };
            return .{ .statements = stmts, .span = e.span };
        }
        const template = try macroTemplate(macro);

        // Hygiene: collect the template's own locals and assign fresh names.
        var hyg = Hyg.init(self.arena);
        try self.collectIntroduced(template, &hyg);

        return self.substBlock(template, &env, &hyg);
    }

    /// `#insert m(args)` in an expression: the expression `m`'s `return #quote(expr);` makes of
    /// the arguments.
    fn expandMacroExpr(self: *Expander, macro: ast.FunctionDecl, call: ast.CallExpr) ExpandError!ast.Expr {
        if (call.args.len != macro.params.len) {
            return fail("macro `{s}` expects {d} argument(s), but {d} were provided", .{ macro.name, macro.params.len, call.args.len });
        }
        var env = Env.init(self.arena);
        for (macro.params, call.args) |param, arg| {
            const arg_expr = switch (arg) {
                .positional => |e| e,
                .named => |n| n.value,
            };
            try checkMacroArgType(macro.name, param, arg_expr);
            try env.put(param.name, arg_expr);
        }
        const template = macroExprTemplate(macro) orelse
            return fail("macro `{s}` makes statements (`return #quote {{ … }};`): `#insert` it as a statement, not in an expression", .{macro.name});
        var hyg = Hyg.init(self.arena);
        return self.substExpr(template, &env, &hyg);
    }

    /// The expression of a macro whose body is `return #quote(expr);`, or null.
    fn macroExprTemplate(macro: ast.FunctionDecl) ?ast.Expr {
        const body = macro.body orelse return null;
        for (body.statements) |stmt| switch (stmt) {
            .return_stmt => |ret| {
                const value = ret.value orelse continue;
                if (value.kind == .quote_expr) return value.kind.quote_expr.*;
                return null;
            },
            else => {},
        };
        return null;
    }

    /// Enforce typed macro parameters. `AstBlock`/`Block` require a block quote
    /// (`#quote { ... }`); `AstExpr`/`Expr` require an expression (not a block);
    /// `Code` (or any other type) accepts any argument.
    fn checkMacroArgType(macro_name: []const u8, param: ast.Param, arg: ast.Expr) ExpandError!void {
        const ty_name = switch (param.ty) {
            .named, .type_param => |n| n.name,
            else => return,
        };
        const wants_block = std.mem.eql(u8, ty_name, "AstBlock") or std.mem.eql(u8, ty_name, "Block");
        const wants_expr = std.mem.eql(u8, ty_name, "AstExpr") or std.mem.eql(u8, ty_name, "Expr");
        if (wants_block and arg.kind != .quote) {
            return fail("macro `{s}` parameter `{s}` expects a `#quote {{ ... }}` block", .{ macro_name, param.name });
        }
        if (wants_expr and arg.kind == .quote) {
            return fail("macro `{s}` parameter `{s}` expects an expression, not a `#quote {{ ... }}` block", .{ macro_name, param.name });
        }
    }

    /// A template macro's body must be a single `return #quote { ... };`.
    fn macroTemplate(macro: ast.FunctionDecl) ExpandError!ast.Block {
        const body = macro.body orelse return fail("macro `{s}` has no body", .{macro.name});
        for (body.statements) |stmt| switch (stmt) {
            .return_stmt => |ret| {
                const value = ret.value orelse continue;
                if (value.kind == .quote) return value.kind.quote;
                return fail("macro `{s}` must `return` a `#quote {{ ... }}` block or a `#quote(…)` expression", .{macro.name});
            },
            else => {},
        };
        return fail("macro `{s}` must contain `return #quote {{ ... }};` or `return #quote(…);`", .{macro.name});
    }

    fn collectIntroduced(self: *Expander, block: ast.Block, hyg: *Hyg) ExpandError!void {
        for (block.statements) |stmt| switch (stmt) {
            .local_infer => |l| try self.introduce(l.name, hyg),
            .local_typed => |l| try self.introduce(l.name, hyg),
            // Bindings a statement introduces (loop var, `|x|` capture) are locals
            // too — collect them so they're renamed and can't capture the caller's.
            .if_stmt => |s| {
                if (s.binding) |b| try self.introduce(b.name, hyg);
                if (s.payload_binding) |pb| try self.introduce(pb, hyg);
                try self.collectIntroduced(s.then_block, hyg);
                if (s.else_block) |eb| try self.collectIntroduced(eb, hyg);
            },
            .while_stmt => |s| try self.collectIntroduced(s.body, hyg),
            .for_range => |s| {
                try self.introduce(s.binding, hyg);
                try self.collectIntroduced(s.body, hyg);
            },
            .for_slice => |s| {
                try self.introduce(s.binding, hyg);
                if (s.index_binding) |ib| try self.introduce(ib, hyg);
                try self.collectIntroduced(s.body, hyg);
            },
            .match_stmt => |s| for (s.arms) |arm| {
                if (arm.binding) |b| try self.introduce(b, hyg);
                if (arm.pattern == .binding) try self.introduce(arm.pattern.binding, hyg);
                try self.collectIntroduced(arm.body, hyg);
            },
            .zone_block => |s| {
                try self.introduce(s.name, hyg);
                try self.collectIntroduced(s.body, hyg);
            },
            .defer_stmt => |s| try self.collectIntroduced(s.body, hyg),
            .comptime_if => |s| {
                try self.collectIntroduced(s.then_block, hyg);
                if (s.else_block) |eb| try self.collectIntroduced(eb, hyg);
            },
            .unsafe_block => |b| try self.collectIntroduced(b, hyg),
            .comptime_run => |b| try self.collectIntroduced(b, hyg),
            else => {},
        };
    }

    fn introduce(self: *Expander, name: []const u8, hyg: *Hyg) ExpandError!void {
        if (hyg.contains(name)) return;
        // Names starting with `__` are the compiler's, so this one collides with no name of
        // the program. It is a name the parser reads, as a format's braces have it in its text.
        const fresh = try std.fmt.allocPrint(self.arena, "__m{d}_{s}", .{ self.gensym, name });
        self.gensym += 1;
        try hyg.put(name, fresh);
    }

    // substitution

    fn substBlock(self: *Expander, block: ast.Block, env: *Env, hyg: *Hyg) ExpandError!ast.Block {
        var out: std.ArrayList(ast.Stmt) = .empty;
        for (block.statements) |stmt| try self.substStmt(stmt, env, hyg, &out);
        return .{ .statements = try out.toOwnedSlice(self.arena), .span = block.span };
    }

    fn substStmt(self: *Expander, stmt: ast.Stmt, env: *Env, hyg: *Hyg, out: *std.ArrayList(ast.Stmt)) ExpandError!void {
        // Block splice: a bare `$body;` statement whose param is bound to a
        // `#quote { ... }` argument inlines that block's statements verbatim.
        if (stmt == .expr and stmt.expr.kind == .splice) {
            const inner = stmt.expr.kind.splice.*;
            if (inner.kind == .ident) {
                if (env.get(inner.kind.ident)) |arg| {
                    if (arg.kind == .quote) {
                        for (arg.kind.quote.statements) |s| try out.append(self.arena, s);
                        return;
                    }
                }
            }
        }

        switch (stmt) {
            .decl => try out.append(self.arena, stmt),
            .local_infer => |l| try out.append(self.arena, .{ .local_infer = .{
                .name = self.rename(l.name, hyg),
                .value = try self.substExpr(l.value, env, hyg),
                .span = l.span,
            } }),
            .local_typed => |l| try out.append(self.arena, .{ .local_typed = .{
                .name = self.rename(l.name, hyg),
                .ty = try self.substType(l.ty, env),
                .value = try self.substExpr(l.value, env, hyg),
                .span = l.span,
            } }),
            .assign => |a| try out.append(self.arena, .{ .assign = .{
                .target = try self.substExpr(a.target, env, hyg),
                .op = a.op,
                .value = try self.substExpr(a.value, env, hyg),
                .span = a.span,
            } }),
            .return_stmt => |r| try out.append(self.arena, .{ .return_stmt = .{
                .value = if (r.value) |v| try self.substExpr(v, env, hyg) else null,
                .span = r.span,
            } }),
            .yield_stmt => |y| try out.append(self.arena, .{ .yield_stmt = .{
                .value = try self.substExpr(y.value, env, hyg),
                .span = y.span,
            } }),
            .fail_stmt => |s| {
                var payload: std.ArrayList(ast.Expr) = .empty;
                for (s.payload) |e| try payload.append(self.arena, try self.substExpr(e, env, hyg));
                try out.append(self.arena, .{ .fail_stmt = .{
                    .variant = s.variant,
                    .payload = try payload.toOwnedSlice(self.arena),
                    .value = if (s.value) |v| try self.substExpr(v, env, hyg) else null,
                    .brace_payload = s.brace_payload,
                    .span = s.span,
                } });
            },
            .if_stmt => |s| try out.append(self.arena, .{ .if_stmt = .{
                .binding = if (s.binding) |b| ast.IfBinding{ .name = self.rename(b.name, hyg), .value = try self.substExpr(b.value, env, hyg) } else null,
                .payload_binding = if (s.payload_binding) |pb| self.rename(pb, hyg) else null,
                .condition = try self.substExpr(s.condition, env, hyg),
                .then_block = try self.substBlock(s.then_block, env, hyg),
                .else_block = if (s.else_block) |eb| try self.substBlock(eb, env, hyg) else null,
                .span = s.span,
            } }),
            .while_stmt => |s| try out.append(self.arena, .{ .while_stmt = .{
                .condition = try self.substExpr(s.condition, env, hyg),
                .payload_binding = s.payload_binding,
                .body = try self.substBlock(s.body, env, hyg),
                .span = s.span,
            } }),
            .match_stmt => |s| {
                var arms: std.ArrayList(ast.MatchArm) = .empty;
                for (s.arms) |arm| {
                    const pat: ast.MatchPattern = switch (arm.pattern) {
                        .int_values => |vals| blk: {
                            var nv: std.ArrayList(ast.Expr) = .empty;
                            for (vals) |e| try nv.append(self.arena, try self.substExpr(e, env, hyg));
                            break :blk .{ .int_values = try nv.toOwnedSlice(self.arena) };
                        },
                        .range => |r| .{ .range = .{
                            .lo = try self.substExpr(r.lo, env, hyg),
                            .hi = try self.substExpr(r.hi, env, hyg),
                            .inclusive = r.inclusive,
                        } },
                        .binding => |name| .{ .binding = self.rename(name, hyg) },
                        else => arm.pattern,
                    };
                    try arms.append(self.arena, .{
                        .pattern = pat,
                        .binding = if (arm.binding) |b| self.rename(b, hyg) else null,
                        .guard = if (arm.guard) |g| try self.substExpr(g, env, hyg) else null,
                        .body = try self.substBlock(arm.body, env, hyg),
                        .span = arm.span,
                    });
                }
                try out.append(self.arena, .{ .match_stmt = .{ .subject = try self.substExpr(s.subject, env, hyg), .arms = try arms.toOwnedSlice(self.arena), .span = s.span } });
            },
            .for_range => |s| try out.append(self.arena, .{ .for_range = .{
                .binding = self.rename(s.binding, hyg),
                .start = try self.substExpr(s.start, env, hyg),
                .end = try self.substExpr(s.end, env, hyg),
                .inclusive = s.inclusive,
                .body = try self.substBlock(s.body, env, hyg),
                .span = s.span,
            } }),
            .for_slice => |s| try out.append(self.arena, .{ .for_slice = .{
                .binding = self.rename(s.binding, hyg),
                .index_binding = if (s.index_binding) |ib| self.rename(ib, hyg) else null,
                .by_ref = s.by_ref,
                .iter = try self.substExpr(s.iter, env, hyg),
                .body = try self.substBlock(s.body, env, hyg),
                .span = s.span,
            } }),
            .zone_block => |s| try out.append(self.arena, .{ .zone_block = .{
                .name = self.rename(s.name, hyg),
                .kind = s.kind,
                .body = try self.substBlock(s.body, env, hyg),
                .span = s.span,
            } }),
            .defer_stmt => |s| try out.append(self.arena, .{ .defer_stmt = .{
                .mode = s.mode,
                .body = try self.substBlock(s.body, env, hyg),
                .span = s.span,
            } }),
            .unsafe_block => |b| try out.append(self.arena, .{ .unsafe_block = try self.substBlock(b, env, hyg) }),
            .comptime_run => |b| try out.append(self.arena, .{ .comptime_run = try self.substBlock(b, env, hyg) }),
            .comptime_if => |s| try out.append(self.arena, .{ .comptime_if = .{
                .condition = try self.substExpr(s.condition, env, hyg),
                .then_block = try self.substBlock(s.then_block, env, hyg),
                .else_block = if (s.else_block) |eb| try self.substBlock(eb, env, hyg) else null,
                .span = s.span,
            } }),
            .insert_stmt => |s| try out.append(self.arena, .{ .insert_stmt = .{ .operand = try self.substExpr(s.operand, env, hyg), .span = s.span } }),
            .break_stmt, .continue_stmt => try out.append(self.arena, stmt),
            .expr => |e| try out.append(self.arena, .{ .expr = try self.substExpr(e, env, hyg) }),
            // `#for` inside a macro template: unroll using the current env (so
            // bounds may reference macro params) plus the loop binding.
            .comptime_for => |cf| try self.unrollFor(cf, env, hyg, out),
        }
    }

    // #for unrolling

    /// Emit `cf.body` once per index in `[start, end)` (or `..=`), binding the
    /// loop variable to that index's literal so `$(i)` splices it.
    fn unrollFor(self: *Expander, cf: ast.ComptimeForStmt, env: *Env, base_hyg: *Hyg, out: *std.ArrayList(ast.Stmt)) ExpandError!void {
        if (cf.fields_of) |of| return self.unrollFields(cf, of, env, base_hyg, out);
        const start = try self.evalIntBound(cf.start, env, base_hyg);
        const last = try self.evalIntBound(cf.end, env, base_hyg);
        const end = if (cf.inclusive) last + 1 else last;

        var i = start;
        while (i < end) : (i += 1) {
            const lit = try self.intLit(i, self.freshId(), cf.span);
            try env.put(cf.binding, lit);
            // Fresh hygiene per iteration so the body's own locals don't collide
            // across unrolled copies (start from the macro's renames, if any).
            var hyg = try self.cloneHyg(base_hyg);
            try self.collectIntroduced(cf.body, &hyg);
            const expanded = try self.substBlock(cf.body, env, &hyg);
            for (expanded.statements) |s| try out.append(self.arena, s);
        }
        _ = env.remove(cf.binding);
    }

    /// `#for f in fields(T) { … }`: `cf.body` once per field of the struct `T`, with `f` at
    /// that field.
    fn unrollFields(self: *Expander, cf: ast.ComptimeForStmt, of: ast.Expr, env: *Env, base_hyg: *Hyg, out: *std.ArrayList(ast.Stmt)) ExpandError!void {
        const ty = try self.substExpr(of, env, base_hyg);
        const name = switch (ty.kind) {
            .ident => |n| n,
            else => return fail("`fields(…)` takes the name of a struct", .{}),
        };
        const strukt = self.structs.get(name) orelse
            return fail("`fields({s})`: `{s}` is no struct declared in this program", .{ name, name });
        if (strukt.type_params.len > 0) return fail("`fields({s})`: `{s}` is generic, and its fields' types are not known yet", .{ name, name });
        if (self.records.contains(cf.binding)) return fail("`#for {s} in fields(…)` inside another `#for {s}`: name it differently", .{ cf.binding, cf.binding });
        for (strukt.fields, 0..) |field, k| {
            try self.records.put(cf.binding, .{ .name = field.name, .ty = field.ty, .index = k });
            var hyg = try self.cloneHyg(base_hyg);
            try self.collectIntroduced(cf.body, &hyg);
            const expanded = try self.substBlock(cf.body, env, &hyg);
            for (expanded.statements) |st| try out.append(self.arena, st);
        }
        _ = self.records.remove(cf.binding);
    }

    /// A name with splices (`get_$(f.name)`, `$(T)_new`; the parser keeps each splice as
    /// `$(…)`): each splice is the name it stands for, a macro parameter's or a field's.
    fn resolveName(self: *Expander, text: []const u8, env: *Env) ExpandError![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < text.len) {
            if (!std.mem.startsWith(u8, text[i..], "$(")) {
                try out.append(self.arena, text[i]);
                i += 1;
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, text, i, ')') orelse return fail("`{s}`: a `$(` is not closed", .{text});
            const inner = std.mem.trim(u8, text[i + 2 .. close], " ");
            try out.appendSlice(self.arena, try self.spliceName(inner, env));
            i = close + 1;
        }
        return out.toOwnedSlice(self.arena);
    }

    /// A template string's text with its splices put in: `$(…)` and `$name` that name a macro
    /// parameter or a field of a `#for`; any other `$` is text (`"$HOME"`, `"$5"`).
    fn resolveText(self: *Expander, text: []const u8, env: *Env) ExpandError![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] != '$' or i + 1 >= text.len) {
                try out.append(self.arena, text[i]);
                i += 1;
                continue;
            }
            var inner: []const u8 = "";
            var next: usize = i + 1;
            if (text[i + 1] == '(') {
                const close = std.mem.indexOfScalarPos(u8, text, i, ')') orelse {
                    try out.append(self.arena, text[i]);
                    i += 1;
                    continue;
                };
                inner = std.mem.trim(u8, text[i + 2 .. close], " ");
                next = close + 1;
            } else if (std.ascii.isAlphabetic(text[i + 1]) or text[i + 1] == '_') {
                var j = i + 1;
                while (j < text.len and isWordChar(text[j])) j += 1;
                inner = text[i + 1 .. j];
                next = j;
            }
            const base = if (std.mem.indexOfScalar(u8, inner, '.')) |dot| inner[0..dot] else inner;
            if (inner.len == 0 or !(env.contains(base) or self.records.contains(base))) {
                try out.append(self.arena, text[i]);
                i += 1;
                continue;
            }
            try out.appendSlice(self.arena, try self.spliceName(inner, env));
            i = next;
        }
        return out.toOwnedSlice(self.arena);
    }

    /// The name `$(inner)` stands for in a name: a macro parameter bound to a name or a type
    /// (`$(T)`), or a field's name (`$(f.name)`).
    fn spliceName(self: *Expander, inner: []const u8, env: *Env) ExpandError![]const u8 {
        if (std.mem.indexOfScalar(u8, inner, '.')) |dot| {
            const rec = self.records.get(inner[0..dot]) orelse
                return fail("`$({s})`: `{s}` is no `#for … in fields(…)` binding", .{ inner, inner[0..dot] });
            const member = inner[dot + 1 ..];
            if (std.mem.eql(u8, member, "name")) return rec.name;
            if (std.mem.eql(u8, member, "ty")) return switch (rec.ty) {
                .named => |n| n.name,
                else => fail("`$({s})` in a name: the type of `{s}` is not a plain name", .{ inner, rec.name }),
            };
            if (std.mem.eql(u8, member, "index")) return std.fmt.allocPrint(self.arena, "{d}", .{rec.index});
            return fail("`$({s})`: a field has `name`, `ty`, `index` and `text`", .{inner});
        }
        const arg = env.get(inner) orelse return fail("`$({s})` does not name a macro parameter", .{inner});
        return switch (arg.kind) {
            .ident => |n| n,
            .type_ref => |tr| switch (tr) {
                .named => |n| n.name,
                else => fail("`$({s})` in a name: its argument is no plain name", .{inner}),
            },
            .int => |t| t,
            else => fail("`$({s})` in a name: its argument is no name", .{inner}),
        };
    }

    /// A string literal's text in a template: `$(…)` name splices resolved, and inside braces
    /// each word that is a local of the template renamed as the template's code is.
    fn templateText(self: *Expander, raw: []const u8, env: *Env, hyg: *Hyg) ExpandError![]const u8 {
        const resolved = if (std.mem.indexOfScalar(u8, raw, '$') != null) try self.resolveText(raw, env) else raw;
        if (std.mem.indexOfScalar(u8, resolved, '{') == null or hyg.count() == 0) return resolved;
        var out: std.ArrayList(u8) = .empty;
        var depth: usize = 0;
        var i: usize = 0;
        while (i < resolved.len) {
            const c = resolved[i];
            if (c == '\\' and i + 1 < resolved.len) {
                try out.appendSlice(self.arena, resolved[i .. i + 2]);
                i += 2;
                continue;
            }
            if (c == '{' and depth == 0 and i + 1 < resolved.len and resolved[i + 1] == '{') {
                try out.appendSlice(self.arena, "{{");
                i += 2;
                continue;
            }
            if (c == '{') depth += 1;
            if (c == '}' and depth > 0) depth -= 1;
            if (depth > 0 and (std.ascii.isAlphabetic(c) or c == '_') and (i == 0 or !isWordChar(resolved[i - 1]))) {
                const start = i;
                while (i < resolved.len and isWordChar(resolved[i])) i += 1;
                const word = resolved[start..i];
                // `.name` after a dot is a field, not a local.
                const after_dot = start > 0 and resolved[start - 1] == '.';
                try out.appendSlice(self.arena, if (!after_dot) (hyg.get(word) orelse word) else word);
                continue;
            }
            try out.append(self.arena, c);
            i += 1;
        }
        return out.toOwnedSlice(self.arena);
    }

    /// `$(f.name)`, `$(f.ty)`, `$(f.index)`, `$(f.text)` as an expression, or null when
    /// `inner` is no field of a `#for … in fields(…)`.
    fn fieldSplice(self: *Expander, inner: ast.Expr, span: Span, id: ast.NodeId) ExpandError!?ast.Expr {
        if (inner.kind != .field or inner.kind.field.base.kind != .ident) return null;
        const rec = self.records.get(inner.kind.field.base.kind.ident) orelse return null;
        const member = inner.kind.field.name;
        const kind: ast.ExprKind = if (std.mem.eql(u8, member, "name"))
            .{ .ident = rec.name }
        else if (std.mem.eql(u8, member, "ty"))
            .{ .type_ref = rec.ty }
        else if (std.mem.eql(u8, member, "index"))
            .{ .int = try std.fmt.allocPrint(self.arena, "{d}", .{rec.index}) }
        else if (std.mem.eql(u8, member, "text"))
            .{ .string = try std.fmt.allocPrint(self.arena, "\"{s}\"", .{rec.name}) }
        else
            return fail("`$({s}.{s})`: a field has `name`, `ty`, `index` and `text`", .{ inner.kind.field.base.kind.ident, member });
        return .{ .id = id, .kind = kind, .span = span };
    }

    fn evalIntBound(self: *Expander, expr: ast.Expr, env: *Env, hyg: *Hyg) ExpandError!i64 {
        const e = try self.substExpr(expr, env, hyg);
        return intValue(e) orelse fail("#for bounds must be integer literals (or comptime parameters bound to literals)", .{});
    }

    fn intLit(self: *Expander, value: i64, id: ast.NodeId, span: Span) ExpandError!ast.Expr {
        const text = try std.fmt.allocPrint(self.arena, "{d}", .{value});
        return .{ .id = id, .kind = .{ .int = text }, .span = span };
    }

    fn cloneHyg(self: *Expander, base: *Hyg) ExpandError!Hyg {
        var h = Hyg.init(self.arena);
        var it = base.iterator();
        while (it.next()) |entry| try h.put(entry.key_ptr.*, entry.value_ptr.*);
        return h;
    }

    fn substExpr(self: *Expander, expr: ast.Expr, env: *Env, hyg: *Hyg) ExpandError!ast.Expr {
        switch (expr.kind) {
            .splice => |inner| {
                if (try self.fieldSplice(inner.*, expr.span, self.freshId())) |e| return e;
                if (inner.kind != .ident) return fail("`$` splice must reference a macro parameter", .{});
                const name = inner.kind.ident;
                const arg = env.get(name) orelse return fail("`${s}` does not name a macro parameter", .{name});
                return switch (arg.kind) {
                    .quote_expr => |e| self.copyArg(e.*),
                    .quote => fail("block argument `${s}` cannot be spliced in expression position", .{name}),
                    else => self.copyArg(arg),
                };
            },
            .ident => |name| {
                if (hyg.get(name)) |fresh| {
                    return .{ .id = self.freshId(), .kind = .{ .ident = fresh }, .span = expr.span };
                }
                if (std.mem.indexOf(u8, name, "$(") != null) {
                    return .{ .id = self.freshId(), .kind = .{ .ident = try self.resolveName(name, env) }, .span = expr.span };
                }
                return self.rebuild(expr, expr.kind);
            },
            .binary => |b| return self.rebuild(expr, .{ .binary = .{
                .op = b.op,
                .left = try self.substPtr(b.left, env, hyg),
                .right = try self.substPtr(b.right, env, hyg),
            } }),
            .unary => |u| return self.rebuild(expr, .{ .unary = .{
                .op = u.op,
                .expr = try self.substPtr(u.expr, env, hyg),
            } }),
            .call => |c| {
                var args: std.ArrayList(ast.CallArg) = .empty;
                for (c.args) |a| switch (a) {
                    .positional => |e| try args.append(self.arena, .{ .positional = try self.substExpr(e, env, hyg) }),
                    .named => |n| try args.append(self.arena, .{ .named = .{ .name = n.name, .value = try self.substExpr(n.value, env, hyg) } }),
                };
                return self.rebuild(expr, .{ .call = .{
                    .callee = try self.substPtr(c.callee, env, hyg),
                    .args = try args.toOwnedSlice(self.arena),
                } });
            },
            .field => |f| return self.rebuild(expr, .{ .field = .{
                .base = try self.substPtr(f.base, env, hyg),
                .name = if (std.mem.indexOf(u8, f.name, "$(") != null) try self.resolveName(f.name, env) else f.name,
            } }),
            .index => |i| return self.rebuild(expr, .{ .index = .{
                .base = try self.substPtr(i.base, env, hyg),
                .index = try self.substPtr(i.index, env, hyg),
            } }),
            .as_cast => |c| return self.rebuild(expr, .{ .as_cast = .{
                .value = try self.substPtr(c.value, env, hyg),
                .to = c.to,
            } }),
            .nil_coalesce => |nc| return self.rebuild(expr, .{ .nil_coalesce = .{
                .value = try self.substPtr(nc.value, env, hyg),
                .default = try self.substPtr(nc.default, env, hyg),
            } }),
            .force_unwrap => |inner| return self.rebuild(expr, .{ .force_unwrap = try self.substPtr(inner, env, hyg) }),
            .run_expr => |inner| return self.rebuild(expr, .{ .run_expr = try self.substPtr(inner, env, hyg) }),
            .unsafe_expr => |inner| return self.rebuild(expr, .{ .unsafe_expr = try self.substPtr(inner, env, hyg) }),
            .compound_literal => |vals| {
                var nv: std.ArrayList(ast.Expr) = .empty;
                for (vals) |e| try nv.append(self.arena, try self.substExpr(e, env, hyg));
                return self.rebuild(expr, .{ .compound_literal = try nv.toOwnedSlice(self.arena) });
            },
            .slice => |s| return self.rebuild(expr, .{ .slice = .{
                .base = try self.substPtr(s.base, env, hyg),
                .start = if (s.start) |st| try self.substPtr(st, env, hyg) else null,
                .end = if (s.end) |en| try self.substPtr(en, env, hyg) else null,
            } }),
            .scope_access => |sa| return self.rebuild(expr, .{ .scope_access = .{
                .base = try self.substPtr(sa.base, env, hyg),
                .member = sa.member,
            } }),
            .try_expr => |t| return self.rebuild(expr, .{ .try_expr = .{ .value = try self.substPtr(t.value, env, hyg) } }),
            .catch_expr => |c| return self.rebuild(expr, .{ .catch_expr = .{
                .value = try self.substPtr(c.value, env, hyg),
                .err_name = c.err_name,
                .handler = try self.substBlock(c.handler, env, hyg),
            } }),
            .parse_expr => |inner| return self.rebuild(expr, .{ .parse_expr = try self.substPtr(inner, env, hyg) }),
            .insert_expr => |inner| {
                const operand = try self.substExpr(inner.*, env, hyg);
                if (operand.kind == .call and operand.kind.call.callee.kind == .ident) {
                    if (self.macros.get(operand.kind.call.callee.kind.ident)) |macro| {
                        const made = try self.expandMacroExpr(macro, operand.kind.call);
                        // Its own `#insert`s (a macro that uses one) expand too.
                        if (!hasInsertExpr(made)) return made;
                        var inner_env = Env.init(self.arena);
                        var inner_hyg = Hyg.init(self.arena);
                        return self.substExpr(made, &inner_env, &inner_hyg);
                    }
                }
                return self.rebuild(expr, .{ .insert_expr = try self.dup(operand) }); // sema rejects it
            },
            // A string in a template may be a format whose braces are code: its locals have
            // their hygienic names there too, and `$(…)` splices put their names in, in the text
            // and in the braces (`"$(f.name) = {p.$(f.name)}"`).
            .string => |raw| {
                if (std.mem.indexOfAny(u8, raw, "{$") == null) return self.rebuild(expr, expr.kind);
                return self.rebuild(expr, .{ .string = try self.templateText(raw, env, hyg) });
            },
            .match_expr => |m| {
                var arms: std.ArrayList(ast.MatchExprArm) = .empty;
                for (m.arms) |arm| {
                    var na = arm;
                    if (arm.binding) |b| na.binding = self.rename(b, hyg);
                    if (arm.guard) |g| na.guard = try self.substExpr(g, env, hyg);
                    na.value = try self.substExpr(arm.value, env, hyg);
                    try arms.append(self.arena, na);
                }
                const nm = try self.arena.create(ast.MatchExpr);
                nm.* = .{ .subject = try self.substPtr(m.subject, env, hyg), .arms = try arms.toOwnedSlice(self.arena), .span = m.span };
                return self.rebuild(expr, .{ .match_expr = nm });
            },
            .if_expr => |ie| {
                const ni = try self.arena.create(ast.IfExpr);
                ni.* = .{
                    .cond = try self.substExpr(ie.cond, env, hyg),
                    .then_value = try self.substExpr(ie.then_value, env, hyg),
                    .else_value = try self.substExpr(ie.else_value, env, hyg),
                    .span = ie.span,
                };
                return self.rebuild(expr, .{ .if_expr = ni });
            },
            .struct_literal => |fields| {
                var nf: std.ArrayList(ast.FieldInit) = .empty;
                for (fields) |f| try nf.append(self.arena, .{ .name = f.name, .value = try self.substExpr(f.value, env, hyg), .span = f.span });
                return self.rebuild(expr, .{ .struct_literal = try nf.toOwnedSlice(self.arena) });
            },
            // Leaves (literals, type refs) and nested `#quote`s (kept as data)
            // substitute to themselves, with an id of their own.
            else => return self.rebuild(expr, expr.kind),
        }
    }

    fn substPtr(self: *Expander, p: *const ast.Expr, env: *Env, hyg: *Hyg) ExpandError!*const ast.Expr {
        return self.dup(try self.substExpr(p.*, env, hyg));
    }

    /// Substitute `$T` in type position. `$T` parses to a `.type_param`; if it
    /// names a macro parameter, splice that argument (interpreted as a type).
    /// Recurses into `*T` / `[]T` / `?T` so e.g. `*$T` works.
    fn substType(self: *Expander, ty: ast.TypeRef, env: *Env) ExpandError!ast.TypeRef {
        return switch (ty) {
            // `$(f.ty)`, or a type name with splices (`$(T)_box`).
            .named => |n| blk: {
                if (std.mem.indexOf(u8, n.name, "$(") == null) break :blk ty;
                if (std.mem.startsWith(u8, n.name, "$(") and std.mem.endsWith(u8, n.name, ".ty)") and
                    std.mem.indexOfScalar(u8, n.name[2..], '$') == null)
                {
                    if (self.records.get(n.name[2 .. n.name.len - 4])) |rec| break :blk rec.ty;
                }
                break :blk .{ .named = .{ .name = try self.resolveName(n.name, env), .span = n.span } };
            },
            .type_param => |tp| if (env.get(tp.name)) |arg|
                (exprToTypeRef(self.arena, arg) orelse fail("macro parameter `${s}` cannot be used as a type", .{tp.name}))
            else
                ty,
            .pointer => |p| .{ .pointer = .{ .is_const = p.is_const, .is_volatile = p.is_volatile, .inner = try self.dupType(try self.substType(p.inner.*, env)), .span = p.span } },
            .many_pointer => |p| .{ .many_pointer = .{ .is_const = p.is_const, .is_volatile = p.is_volatile, .inner = try self.dupType(try self.substType(p.inner.*, env)), .span = p.span } },
            .slice => |s| .{ .slice = .{ .is_const = s.is_const, .inner = try self.dupType(try self.substType(s.inner.*, env)), .span = s.span } },
            .optional => |o| .{ .optional = .{ .inner = try self.dupType(try self.substType(o.inner.*, env)), .span = o.span } },
            else => ty,
        };
    }

    fn dupType(self: *Expander, ty: ast.TypeRef) ExpandError!*const ast.TypeRef {
        const p = try self.arena.create(ast.TypeRef);
        p.* = ty;
        return p;
    }

    fn rebuild(self: *Expander, original: ast.Expr, kind: ast.ExprKind) ast.Expr {
        return .{ .id = self.freshId(), .kind = kind, .span = original.span };
    }

    fn freshId(self: *Expander) ast.NodeId {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    /// A copy of a macro argument with ids of its own, for each place it is spliced into.
    fn copyArg(self: *Expander, arg: ast.Expr) ExpandError!ast.Expr {
        var env = Env.init(self.arena);
        var hyg = Hyg.init(self.arena);
        return self.substExpr(arg, &env, &hyg);
    }

    fn rename(self: *Expander, name: []const u8, hyg: *Hyg) []const u8 {
        _ = self;
        return hyg.get(name) orelse name;
    }
};

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Whether `value` (any AST node) holds an `#insert` expression, at any depth. Generic over the
/// AST's types, so a new kind of node is searched without a change here.
pub fn hasInsertExpr(value: anytype) bool {
    const T = @TypeOf(value);
    if (T == ast.Expr) {
        if (value.kind == .insert_expr) return true;
        return hasInsertExpr(value.kind);
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                if (hasInsertExpr(@field(value, field.name))) return true;
            }
            return false;
        },
        .@"union" => |info| {
            if (info.tag_type == null) return false;
            switch (value) {
                inline else => |payload| return hasInsertExpr(payload),
            }
        },
        .pointer => |info| switch (info.size) {
            .one => return hasInsertExpr(value.*),
            .slice => {
                if (info.child == u8) return false;
                for (value) |element| if (hasInsertExpr(element)) return true;
                return false;
            },
            else => return false,
        },
        .optional => return if (value) |inner| hasInsertExpr(inner) else false,
        else => return false,
    }
}

/// A macro argument used in type position (`x: $t = …`) — convert the argument
/// expr to a type. Bare type names parse as `.type_ref`; identifiers to `.named`;
/// `*Name` (the parser reads it as a dereference) to a pointer.
fn exprToTypeRef(arena: std.mem.Allocator, e: ast.Expr) ?ast.TypeRef {
    return switch (e.kind) {
        .type_ref => |tr| tr,
        .ident => |name| .{ .named = .{ .name = name, .span = e.span } },
        .unary => |u| blk: {
            if (u.op != .deref) break :blk null;
            const pointee = exprToTypeRef(arena, u.expr.*) orelse break :blk null;
            const inner = arena.create(ast.TypeRef) catch break :blk null;
            inner.* = pointee;
            break :blk .{ .pointer = .{ .inner = inner, .span = e.span } };
        },
        else => null,
    };
}

/// Integer value of a literal expression (`5`, `-3`), or null if not a literal.
fn intValue(e: ast.Expr) ?i64 {
    return switch (e.kind) {
        .int => |t| std.fmt.parseInt(i64, t, 0) catch null,
        .unary => |u| if (u.op == .neg) blk: {
            const v = intValue(u.expr.*) orelse break :blk null;
            break :blk -v;
        } else null,
        else => null,
    };
}

/// Expand all macros in `module`, returning a macro-free module.
pub fn expand(arena: std.mem.Allocator, module: ast.Module) ExpandError!ast.Module {
    var expander = Expander{
        .arena = arena,
        .macros = std.StringHashMap(ast.FunctionDecl).init(arena),
        .structs = std.StringHashMap(ast.StructDecl).init(arena),
        .records = std.StringHashMap(FieldRecord).init(arena),
    };
    return expander.expandModule(module);
}
