//! Which params a function body may change or point at.
//!
//! The IR keeps a param as a plain value as long as the body only reads it. A param the body
//! assigns (`x = 5`, `p.v = 5`, `a[i] = 1`), takes the address of (`&p`), slices (`a[0..2]`)
//! or calls a `*Self` method on (`p.bump()`) gets a local slot of its own instead
//! (`FunctionLowerer.spillParams`), so the change is there when the body reads it again.
//! Keeping the others out of memory matters: a struct param copied into a slot made code that
//! uses many small structs (vectors, rays) about a fifth slower.
//!
//! A local that shadows a param counts as the param here. That only gives the param a slot it
//! did not need.

const std = @import("std");
const ast = @import("ast.zig");

/// The names among `params` that `body` may change or point at. `auto_addr` holds the method
/// calls whose receiver sema passes by address (`sema.TypeEnv.receiver_auto_addr`). Caller
/// owns the returned slice; its names point into `params`.
pub fn find(
    allocator: std.mem.Allocator,
    params: []const ast.Param,
    body: ast.Block,
    auto_addr: *const std.AutoHashMap(ast.NodeId, void),
) ![]const []const u8 {
    var w = Walker{ .allocator = allocator, .params = params, .auto_addr = auto_addr };
    errdefer w.found.deinit(allocator);
    try w.walkBlock(body);
    return w.found.toOwnedSlice(allocator);
}

const Walker = struct {
    allocator: std.mem.Allocator,
    params: []const ast.Param,
    auto_addr: *const std.AutoHashMap(ast.NodeId, void),
    found: std.ArrayList([]const u8) = .empty,

    /// Note the param that `expr` is rooted in (`p` of `p.a[i].b`), if it is one.
    fn mark(self: *Walker, expr: ast.Expr) !void {
        const name = rootName(expr) orelse return;
        for (self.found.items) |f| if (std.mem.eql(u8, f, name)) return;
        for (self.params) |p| if (!p.is_type_param and std.mem.eql(u8, p.name, name)) {
            try self.found.append(self.allocator, p.name);
            return;
        };
    }

    fn walkBlock(self: *Walker, block: ast.Block) anyerror!void {
        for (block.statements) |s| try self.walkStmt(s);
    }

    fn walkStmt(self: *Walker, stmt: ast.Stmt) anyerror!void {
        switch (stmt) {
            .local_infer => |s| try self.walkExpr(s.value),
            .local_typed => |s| try self.walkExpr(s.value),
            .assign => |s| {
                try self.mark(s.target);
                try self.walkExpr(s.target);
                try self.walkExpr(s.value);
            },
            .return_stmt => |s| if (s.value) |v| try self.walkExpr(v),
            .yield_stmt => |s| try self.walkExpr(s.value),
            .fail_stmt => |s| for (s.payload) |p| try self.walkExpr(p),
            .expr => |e| try self.walkExpr(e),
            .if_stmt => |s| {
                try self.walkExpr(s.condition);
                if (s.binding) |b| try self.walkExpr(b.value);
                try self.walkBlock(s.then_block);
                if (s.else_block) |e| try self.walkBlock(e);
            },
            .while_stmt => |s| {
                try self.walkExpr(s.condition);
                try self.walkBlock(s.body);
            },
            .for_range => |s| {
                try self.walkExpr(s.start);
                try self.walkExpr(s.end);
                try self.walkBlock(s.body);
            },
            .for_slice => |s| {
                try self.walkExpr(s.iter);
                try self.walkBlock(s.body);
            },
            .match_stmt => |s| {
                try self.walkExpr(s.subject);
                for (s.arms) |arm| {
                    if (arm.guard) |g| try self.walkExpr(g);
                    try self.walkBlock(arm.body);
                }
            },
            .zone_block => |s| try self.walkBlock(s.body),
            .unsafe_block, .comptime_run => |b| try self.walkBlock(b),
            .defer_stmt => |s| try self.walkBlock(s.body),
            .comptime_if => |s| {
                try self.walkExpr(s.condition);
                try self.walkBlock(s.then_block);
                if (s.else_block) |e| try self.walkBlock(e);
            },
            .comptime_for => |s| {
                try self.walkExpr(s.start);
                try self.walkExpr(s.end);
                try self.walkBlock(s.body);
            },
            .insert_stmt => |s| try self.walkExpr(s.operand),
            .break_stmt, .continue_stmt => {},
        }
    }

    fn walkExpr(self: *Walker, expr: ast.Expr) anyerror!void {
        switch (expr.kind) {
            .binary => |b| {
                try self.walkExpr(b.left.*);
                try self.walkExpr(b.right.*);
            },
            .unary => |u| {
                if (u.op == .address_of) try self.mark(u.expr.*);
                try self.walkExpr(u.expr.*);
            },
            .call => |c| {
                // `p.bump()` with `bump :: fn(self: *Self)`: the call takes `&p`.
                if (c.callee.kind == .field and self.auto_addr.contains(c.callee.id))
                    try self.mark(c.callee.kind.field.base.*);
                try self.walkExpr(c.callee.*);
                for (c.args) |a| switch (a) {
                    .positional => |x| try self.walkExpr(x),
                    .named => |n| try self.walkExpr(n.value),
                };
            },
            .field => |f| try self.walkExpr(f.base.*),
            .index => |i| {
                try self.walkExpr(i.base.*);
                try self.walkExpr(i.index.*);
            },
            .slice => |s| {
                // A slice of an array points into it.
                try self.mark(s.base.*);
                try self.walkExpr(s.base.*);
                if (s.start) |x| try self.walkExpr(x.*);
                if (s.end) |x| try self.walkExpr(x.*);
            },
            .as_cast => |c| try self.walkExpr(c.value.*),
            .force_unwrap, .unsafe_expr, .run_expr, .quote_expr, .splice, .parse_expr => |inner| try self.walkExpr(inner.*),
            .nil_coalesce => |nc| {
                try self.walkExpr(nc.value.*);
                try self.walkExpr(nc.default.*);
            },
            .try_expr => |t| try self.walkExpr(t.value.*),
            .catch_expr => |c| {
                try self.walkExpr(c.value.*);
                try self.walkBlock(c.handler);
            },
            .compound_literal => |fields| for (fields) |f| try self.walkExpr(f),
            .struct_literal => |fields| for (fields) |f| try self.walkExpr(f.value),
            .match_expr => |m| {
                try self.walkExpr(m.subject.*);
                for (m.arms) |arm| {
                    if (arm.guard) |g| try self.walkExpr(g);
                    try self.walkExpr(arm.value);
                }
            },
            .if_expr => |ie| {
                try self.walkExpr(ie.cond);
                try self.walkExpr(ie.then_value);
                try self.walkExpr(ie.else_value);
            },
            .ident, .scope_access, .quote, .type_ref, .int, .float, .string, .bool, .null => {},
        }
    }
};

/// The variable an lvalue starts from: `p` of `p`, `p.a`, `p[i]`, `p.a[i].b` and `(*p).a`.
fn rootName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |name| name,
        .field => |f| rootName(f.base.*),
        .index => |i| rootName(i.base.*),
        .slice => |s| rootName(s.base.*),
        .unary => |u| if (u.op == .deref) rootName(u.expr.*) else null,
        else => null,
    };
}

test "param writes: assigned, addressed and sliced params, not the ones only read" {
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\f :: fn(x: i64, p: P, q: P, r: P, arr: [4]u8, s: P) -> i64 {
        \\    x = 5i64;
        \\    p.v = 1i64;
        \\    ptr := &q;
        \\    part := arr[0..2];
        \\    return r.v + s.v;
        \\}
        \\
    ;
    var p = try parser.Parser.init(a, "pw.fels", src, 1);
    const module = try p.parseModule();
    const decl = module.items[0].function;
    var none = std.AutoHashMap(ast.NodeId, void).init(a);
    const found = try find(a, decl.params, decl.body.?, &none);
    try std.testing.expectEqual(@as(usize, 4), found.len);
    try std.testing.expectEqualStrings("x", found[0]);
    try std.testing.expectEqualStrings("p", found[1]);
    try std.testing.expectEqualStrings("q", found[2]);
    try std.testing.expectEqualStrings("arr", found[3]);
}
