//! Formats: a string literal passed to a `Format` parameter, as in
//! `io::println("{name} has {n} items")`, is code that writes its text and its values.
//!
//! The literal is split here into text and `{expr}` / `{expr:spec}` placeholders (`{{` and `}}`
//! are braces of the text). A tolerant sema pass notes which literals reach a `Format`
//! parameter (`TypeEnv.format_literals`); `rewrite` then replaces each by
//!
//!     .{ .text = "", .run = __lambda_fmt_N }
//!     __lambda_fmt_N :: fn(__fmt: *Formatter) { __fmt.text("…"); __fmt.value(expr, "spec"); … }
//!
//! a lifted lambda like the parser's: it captures what the expressions use, and the strict pass
//! checks it as code written by hand, with the expressions' places in the string for errors.

const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const macroexpand = @import("macroexpand.zig");
const diag_mod = @import("diagnostic.zig");
const style = @import("style.zig");
const Span = @import("lexer/span.zig").Span;

/// The node ids of the code made here: far above those of the parser and the preludes.
var next_id: ast.NodeId = 2_000_000_000;
/// For the names of the functions made here.
var lambda_count: u32 = 0;

fn newId() ast.NodeId {
    next_id += 1;
    return next_id;
}

/// Whether a literal (with its quotes) has a brace in it: only then is it read as a format.
pub fn hasBraces(raw: []const u8) bool {
    return std.mem.indexOfAny(u8, raw, "{}") != null;
}

/// A value in the text: the expression at `start..end` in the file, and its spec.
pub const Placeholder = struct {
    start: usize,
    end: usize,
    spec: []const u8,
    /// Where the spec starts in the file.
    spec_at: usize,
};

pub const Piece = union(enum) {
    /// Text as it is written in the literal (escapes kept), with `{{` and `}}` made braces.
    text: []const u8,
    value: Placeholder,
};

/// A mistake in a format: what, and where in the file.
pub const Problem = struct {
    at: usize,
    len: usize,
    msg: []const u8,
};

pub const Split = union(enum) {
    pieces: []const Piece,
    problem: Problem,
};

/// Split the literal `raw` (with its quotes), which starts at `base` in the file.
pub fn split(a: std.mem.Allocator, raw: []const u8, base: usize) error{OutOfMemory}!Split {
    var pieces: std.ArrayList(Piece) = .empty;
    var text: std.ArrayList(u8) = .empty;
    const inner = raw[1 .. raw.len - 1];
    const at0 = base + 1;
    var i: usize = 0;
    while (i < inner.len) {
        const c = inner[i];
        if (c == '\\' and i + 1 < inner.len) {
            try text.appendSlice(a, inner[i .. i + 2]);
            i += 2;
            continue;
        }
        if (c == '}') {
            if (i + 1 < inner.len and inner[i + 1] == '}') {
                try text.append(a, '}');
                i += 2;
                continue;
            }
            return .{ .problem = .{ .at = at0 + i, .len = 1, .msg = "this `}` closes no `{`; a brace in the text is `}}`" } };
        }
        if (c != '{') {
            try text.append(a, c);
            i += 1;
            continue;
        }
        if (i + 1 < inner.len and inner[i + 1] == '{') {
            try text.append(a, '{');
            i += 2;
            continue;
        }
        // A value: up to the `}` that closes this `{`.
        var depth: usize = 1;
        var j = i + 1;
        var colon: ?usize = null;
        var nest: usize = 0; // (), [] and {} inside the expression
        while (j < inner.len) : (j += 1) {
            switch (inner[j]) {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) break;
                },
                '(', '[' => nest += 1,
                ')', ']' => nest -|= 1,
                ':' => if (colon == null and depth == 1 and nest == 0) {
                    const double = (j + 1 < inner.len and inner[j + 1] == ':') or (j > 0 and inner[j - 1] == ':');
                    if (!double) colon = j;
                },
                else => {},
            }
        }
        if (j >= inner.len) {
            return .{ .problem = .{ .at = at0 + i, .len = 1, .msg = "this `{` is not closed; a brace in the text is `{{`" } };
        }
        const expr_end = colon orelse j;
        const trimmed = std.mem.trim(u8, inner[i + 1 .. expr_end], " ");
        if (trimmed.len == 0) {
            return .{ .problem = .{ .at = at0 + i, .len = j - i + 1, .msg = "a `{}` names no value: write the value in the braces, as in `{name}`; a brace in the text is `{{`" } };
        }
        if (text.items.len != 0) {
            try pieces.append(a, .{ .text = try text.toOwnedSlice(a) });
        }
        const lead = std.mem.indexOfNone(u8, inner[i + 1 .. expr_end], " ") orelse 0;
        const start = at0 + i + 1 + lead;
        const spec = if (colon) |k| inner[k + 1 .. j] else "";
        try pieces.append(a, .{ .value = .{
            .start = start,
            .end = start + trimmed.len,
            .spec = spec,
            .spec_at = if (colon) |k| at0 + k + 1 else at0 + j,
        } });
        i = j + 1;
    }
    if (text.items.len != 0) try pieces.append(a, .{ .text = try text.toOwnedSlice(a) });
    return .{ .pieces = try pieces.toOwnedSlice(a) };
}

/// What is wrong with a spec, or null. The spec is `[[fill]align][0][width][.precision][kind]`.
pub fn specProblem(spec: []const u8) ?[]const u8 {
    var i: usize = 0;
    const isAlign = struct {
        fn f(c: u8) bool {
            return c == '<' or c == '>' or c == '^';
        }
    }.f;
    if (spec.len >= 2 and isAlign(spec[1])) {
        i = 2;
    } else if (spec.len >= 1 and isAlign(spec[0])) {
        i = 1;
    }
    while (i < spec.len and std.ascii.isDigit(spec[i])) i += 1;
    if (i < spec.len and spec[i] == '.') {
        i += 1;
        if (i == spec.len or !std.ascii.isDigit(spec[i])) return "a `.` in a spec is followed by the digits after the point, as in `{x:.2}`";
        while (i < spec.len and std.ascii.isDigit(spec[i])) i += 1;
    }
    if (i < spec.len) {
        switch (spec[i]) {
            'x', 'X', 'b', 'o', '?' => i += 1,
            else => return "this is no spec: it is `[[fill]align][0][width][.precision][kind]`, with align `<`, `>` or `^` and the kinds `x`, `X`, `b`, `o` and `?`",
        }
    }
    if (i < spec.len) return "the kind (`x`, `X`, `b`, `o` or `?`) comes last in a spec";
    return null;
}

/// The literals `noted` (by node id) replaced by the code of their format, and the functions
/// of that code added to the module. A mistake in a literal is printed and `error.Reported`
/// returned.
pub fn rewrite(
    a: std.mem.Allocator,
    module: ast.Module,
    noted: *const std.AutoHashMapUnmanaged(ast.NodeId, void),
) error{ OutOfMemory, Reported }!ast.Module {
    var r: Rewriter = .{ .a = a, .noted = noted };
    for (module.items) |item| switch (item) {
        .function => |decl| try r.function(decl),
        .const_decl => |decl| {
            r.file = decl.file_name;
            r.source = decl.source;
            try r.expr(&decl.value);
        },
        .interface_impl => |impl| for (impl.methods) |m| try r.function(m),
        else => {},
    };
    if (r.failed) return error.Reported;
    if (r.added.items.len == 0) return module;
    var items: std.ArrayList(ast.Item) = .empty;
    try items.appendSlice(a, module.items);
    try items.appendSlice(a, r.added.items);
    return .{ .file_name = module.file_name, .items = try items.toOwnedSlice(a) };
}

/// Whether a call in the module passes a string literal with a brace in it: only then is a
/// tolerant pass run to see which of them are formats.
pub fn hasCandidates(module: ast.Module) bool {
    var r: Rewriter = .{ .a = undefined, .noted = null };
    for (module.items) |item| switch (item) {
        .function => |decl| if (decl.body) |b| r.block(b) catch {},
        .const_decl => |decl| r.expr(&decl.value) catch {},
        .interface_impl => |impl| for (impl.methods) |m| if (m.body) |b| r.block(b) catch {},
        else => {},
    };
    return r.candidates;
}

/// Point every span in the node `ptr` points to, at any depth, at `to`: the code of a format a
/// macro made was read from text that is not the file's. Generic over the AST's types. The nodes
/// are the parser's fresh ones, so they are written in place.
fn pinSpans(ptr: anytype, to: Span) void {
    const T = @typeInfo(@TypeOf(ptr)).pointer.child;
    const node: *T = @constCast(ptr);
    if (T == Span) {
        node.* = to;
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.fields) |field| pinSpans(&@field(node.*, field.name), to),
        .@"union" => |info| {
            if (info.tag_type == null) return;
            switch (node.*) {
                inline else => |*payload| pinSpans(payload, to),
            }
        },
        .pointer => |info| switch (info.size) {
            .one => pinSpans(node.*, to),
            .slice => {
                if (info.child == u8) return;
                for (node.*) |*element| pinSpans(element, to);
            },
            else => {},
        },
        .optional => if (node.*) |*inner| pinSpans(inner, to),
        else => {},
    }
}

const Rewriter = struct {
    a: std.mem.Allocator,
    /// The literals to replace; null only to look for candidates.
    noted: ?*const std.AutoHashMapUnmanaged(ast.NodeId, void),
    file: []const u8 = "",
    source: []const u8 = "",
    /// The function the literals are in is generic (or a method of a generic struct).
    generic: bool = false,
    added: std.ArrayList(ast.Item) = .empty,
    failed: bool = false,
    candidates: bool = false,

    const Error = error{OutOfMemory};

    fn function(r: *Rewriter, decl: ast.FunctionDecl) Error!void {
        r.file = decl.file_name;
        r.source = decl.source;
        r.generic = decl.type_params.len != 0;
        defer r.generic = false;
        if (decl.body) |b| try r.block(b);
    }

    fn block(r: *Rewriter, b: ast.Block) Error!void {
        for (b.statements) |s| try r.stmt(s);
    }

    fn stmt(r: *Rewriter, s: ast.Stmt) Error!void {
        switch (s) {
            .local_infer => |l| try r.expr(&l.value),
            .local_typed => |l| try r.expr(&l.value),
            .assign => |as| {
                try r.expr(&as.target);
                try r.expr(&as.value);
            },
            .return_stmt => |rs| if (rs.value) |*v| try r.expr(v),
            .fail_stmt => |fs| {
                for (fs.payload) |*p| try r.expr(p);
                if (fs.value) |*v| try r.expr(v);
            },
            .yield_stmt => |y| try r.expr(&y.value),
            .if_stmt => |is| {
                if (is.binding) |*bnd| try r.expr(&bnd.value);
                try r.expr(&is.condition);
                try r.block(is.then_block);
                if (is.else_block) |e| try r.block(e);
            },
            .while_stmt => |ws| {
                try r.expr(&ws.condition);
                try r.block(ws.body);
            },
            .for_range => |fr| {
                try r.expr(&fr.start);
                try r.expr(&fr.end);
                try r.block(fr.body);
            },
            .for_slice => |fs| {
                try r.expr(&fs.iter);
                try r.block(fs.body);
            },
            .comptime_run => |b| try r.block(b),
            .zone_block => |z| try r.block(z.body),
            .defer_stmt => |d| try r.block(d.body),
            .match_stmt => |m| {
                try r.expr(&m.subject);
                for (m.arms) |arm| {
                    if (arm.guard) |*g| try r.expr(g);
                    try r.block(arm.body);
                }
            },
            .comptime_if => |ci| {
                try r.expr(&ci.condition);
                try r.block(ci.then_block);
                if (ci.else_block) |e| try r.block(e);
            },
            .comptime_for => |cf| try r.block(cf.body),
            .expr => |*e| try r.expr(e),
            // A macro's expansion is spliced as `#insert #quote { … }`.
            .insert_stmt => |ins| if (ins.operand.kind == .quote) try r.block(ins.operand.kind.quote),
            else => {},
        }
    }

    fn expr(r: *Rewriter, e: *const ast.Expr) Error!void {
        switch (e.kind) {
            .call => |c| {
                try r.expr(c.callee);
                for (c.args, 0..) |arg, i| {
                    const value = switch (arg) {
                        .positional => |v| v,
                        .named => |n| n.value,
                    };
                    if (value.kind == .string and hasBraces(value.kind.string)) {
                        r.candidates = true;
                        const noted = r.noted orelse continue;
                        if (!noted.contains(value.id)) continue;
                        const made = (try r.format(value)) orelse continue;
                        @constCast(c.args)[i] = switch (arg) {
                            .positional => .{ .positional = made },
                            .named => |n| .{ .named = .{ .name = n.name, .value = made } },
                        };
                        continue;
                    }
                    switch (arg) {
                        .positional => |*v| try r.expr(v),
                        .named => |*n| try r.expr(&n.value),
                    }
                }
            },
            .binary => |b| {
                try r.expr(b.left);
                try r.expr(b.right);
            },
            .unary => |u| try r.expr(u.expr),
            .field => |f| try r.expr(f.base),
            .scope_access => |sa| try r.expr(sa.base),
            .index => |ix| {
                try r.expr(ix.base);
                try r.expr(ix.index);
            },
            .slice => |sl| {
                try r.expr(sl.base);
                if (sl.start) |st| try r.expr(st);
                if (sl.end) |en| try r.expr(en);
            },
            .unsafe_expr, .run_expr, .force_unwrap => |inner| try r.expr(inner),
            .nil_coalesce => |nc| {
                try r.expr(nc.value);
                try r.expr(nc.default);
            },
            .as_cast => |ac| try r.expr(ac.value),
            .try_expr => |t| try r.expr(t.value),
            .catch_expr => |ce| {
                try r.expr(ce.value);
                try r.block(ce.handler);
            },
            .compound_literal => |elems| for (elems) |*el| try r.expr(el),
            .struct_literal => |inits| for (inits) |*fi| try r.expr(&fi.value),
            .match_expr => |m| {
                try r.expr(m.subject);
                for (m.arms) |*arm| {
                    if (arm.guard) |*g| try r.expr(g);
                    try r.expr(&arm.value);
                }
            },
            .if_expr => |ie| {
                try r.expr(&ie.cond);
                try r.expr(&ie.then_value);
                try r.expr(&ie.else_value);
            },
            else => {},
        }
    }

    /// The `Format` of the literal `lit`: its function added to the module, or null after a
    /// mistake (printed).
    fn format(r: *Rewriter, lit: ast.Expr) Error!?ast.Expr {
        const raw = lit.kind.string;
        // A macro's template made this literal's text (its locals renamed, its splices put in):
        // it is read from that text, and a mistake in it is reported at the literal.
        const verbatim = lit.span.start + raw.len <= r.source.len and
            std.mem.eql(u8, r.source[lit.span.start..][0..raw.len], raw);
        const text_source = if (verbatim) r.source else raw;
        const sp = try split(r.a, raw, if (verbatim) lit.span.start else 0);
        const pieces = switch (sp) {
            .problem => |p| {
                r.report(p.msg, if (verbatim) Span.new(p.at, p.at + p.len) else lit.span);
                return null;
            },
            .pieces => |ps| ps,
        };
        const span = lit.span;
        // The code of a format is a lambda, and a lambda in a generic function cannot use the
        // function's values yet (KNOWN_ISSUES).
        if (r.generic) for (pieces) |piece| if (piece == .value) {
            r.report("a format in a generic function cannot print values yet: its code is a lambda, and a lambda there cannot use the function's values; print from a function that is not generic", Span.new(piece.value.start, piece.value.end));
            return null;
        };
        var stmts: std.ArrayList(ast.Stmt) = .empty;
        for (pieces) |piece| switch (piece) {
            .text => |t| try stmts.append(r.a, .{ .expr = try r.call("text", &.{try r.string(t, span)}, span) }),
            .value => |ph| {
                const at: Span = if (verbatim) Span.new(ph.start, ph.end) else span;
                if (specProblem(ph.spec)) |msg| {
                    r.report(msg, if (verbatim) Span.new(ph.spec_at, ph.spec_at + @max(ph.spec.len, 1)) else span);
                    return null;
                }
                // The parser numbers from the id it is given, and `newId` gave `next_id` last.
                const parsed = parser.parseEmbedded(r.a, r.file, text_source, ph.start, ph.end, next_id + 1) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        r.report("this is not a value the format can print: the braces hold one expression, and no string literal (a brace in the text is `{{`)", at);
                        return null;
                    },
                };
                next_id = parsed.next_id;
                if (!verbatim) pinSpans(&parsed.expr, span);
                // The macros were expanded, and dropped, before the formats are read.
                if (macroexpand.hasInsertExpr(parsed.expr)) {
                    r.report("a macro cannot be expanded in a format's braces: put its value in a local first (`v := #insert m(x);`, then `{v}`)", at);
                    return null;
                }
                for (parsed.lifted) |l| try r.added.append(r.a, .{ .function = l });
                try stmts.append(r.a, .{ .expr = try r.call("value", &.{ parsed.expr, try r.string(ph.spec, span) }, span) });
            },
        };

        lambda_count += 1;
        const name = try std.fmt.allocPrint(r.a, "__lambda_fmt_{d}", .{lambda_count});
        const formatter = try r.a.create(ast.TypeRef);
        formatter.* = .{ .named = .{ .name = "Formatter", .span = span } };
        const params = try r.a.alloc(ast.Param, 1);
        params[0] = .{ .name = "__fmt", .ty = .{ .pointer = .{ .inner = formatter, .span = span } }, .span = span };
        try r.added.append(r.a, .{ .function = .{
            .attrs = &.{},
            .name = name,
            .file_name = r.file,
            .source = r.source,
            .type_params = &.{},
            .params = params,
            .return_ty = .{ .named = .{ .name = "void", .span = span } },
            .error_ty = null,
            .body = .{ .statements = try stmts.toOwnedSlice(r.a), .span = span },
            .span = span,
        } });

        const inits = try r.a.alloc(ast.FieldInit, 2);
        inits[0] = .{ .name = "text", .value = try r.string("", span), .span = span };
        inits[1] = .{ .name = "run", .value = .{ .id = newId(), .kind = .{ .ident = name }, .span = span }, .span = span };
        return .{ .id = newId(), .kind = .{ .struct_literal = inits }, .span = span };
    }

    /// `__fmt.<method>(args)`.
    fn call(r: *Rewriter, method: []const u8, args: []const ast.Expr, span: Span) Error!ast.Expr {
        const base = try r.a.create(ast.Expr);
        base.* = .{ .id = newId(), .kind = .{ .ident = "__fmt" }, .span = span };
        const callee = try r.a.create(ast.Expr);
        callee.* = .{ .id = newId(), .kind = .{ .field = .{ .base = base, .name = method } }, .span = span };
        const call_args = try r.a.alloc(ast.CallArg, args.len);
        for (args, 0..) |arg, i| call_args[i] = .{ .positional = arg };
        return .{ .id = newId(), .kind = .{ .call = .{ .callee = callee, .args = call_args } }, .span = span };
    }

    /// A string literal of `text` (as written in the source, escapes kept).
    fn string(r: *Rewriter, text: []const u8, span: Span) Error!ast.Expr {
        const quoted = try std.fmt.allocPrint(r.a, "\"{s}\"", .{text});
        return .{ .id = newId(), .kind = .{ .string = quoted }, .span = span };
    }

    fn report(r: *Rewriter, msg: []const u8, span: Span) void {
        r.failed = true;
        const d: diag_mod.Diagnostic = .{ .kind = .err, .message = msg, .span = span, .file = r.file };
        const text = diag_mod.render(r.a, r.file, r.source, d, style.forStderr()) catch return;
        std.debug.print("{s}\n", .{text});
    }
};

test "a format splits into its text and its values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "\"{name} has {n:>4} items {{x}}\\n\"";
    const sp = try split(a, raw, 100);
    const pieces = sp.pieces;
    try std.testing.expectEqual(@as(usize, 4), pieces.len);
    try std.testing.expectEqual(@as(usize, 102), pieces[0].value.start);
    try std.testing.expectEqual(@as(usize, 106), pieces[0].value.end);
    try std.testing.expectEqualStrings(" has ", pieces[1].text);
    try std.testing.expectEqualStrings(">4", pieces[2].value.spec);
    try std.testing.expectEqualStrings(" items {x}\\n", pieces[3].text);
}

test "a path with :: in a value is no spec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sp = try split(arena.allocator(), "\"{math::PI:.2}\"", 0);
    try std.testing.expectEqualStrings(".2", sp.pieces[0].value.spec);
    try std.testing.expectEqual(@as(usize, 2), sp.pieces[0].value.start);
    try std.testing.expectEqual(@as(usize, 10), sp.pieces[0].value.end);
}

test "a lone brace is a mistake with a hint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const open = try split(arena.allocator(), "\"a { b\"", 0);
    try std.testing.expectEqual(@as(usize, 3), open.problem.at);
    const close = try split(arena.allocator(), "\"a } b\"", 0);
    try std.testing.expectEqual(@as(usize, 3), close.problem.at);
    const empty = try split(arena.allocator(), "\"{}\"", 0);
    try std.testing.expect(empty == .problem);
}

test "specs" {
    try std.testing.expect(specProblem("") == null);
    try std.testing.expect(specProblem("*^9") == null);
    try std.testing.expect(specProblem("08.3") == null);
    try std.testing.expect(specProblem("x") == null);
    try std.testing.expect(specProblem("<8?") == null);
    try std.testing.expect(specProblem("q") != null);
    try std.testing.expect(specProblem(".") != null);
    try std.testing.expect(specProblem("x8") != null);
}
