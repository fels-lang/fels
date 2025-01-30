// Compiler-provided `ast.*` type surface for metaprogramming (Phase 2,
// generative Flavor A). These are ordinary K2 types — faithful (a subset, for
// now) of the compiler's own AST in `src/ast.zig` — so user code can construct
// them (via `#quote`, eventually), `match` on them, and return them from a
// comptime function. The macroexpand/lowering machinery materializes `#quote`
// into these aggregates and reifies them back into real AST at `#insert`.
//
// K2 has a flat type namespace (no `ast.Block` qualified form yet), so these
// use an `Ast` prefix. The set grows as `#quote` materialization covers more
// node kinds. Identity fields (NodeId/Span) are intentionally omitted — the
// compiler stamps those when reifying at the splice site.
pub const source =
    \\AstBinOp :: enum { add, sub, mul, div }
    \\AstBinary :: struct { op: AstBinOp, left: *AstExpr, right: *AstExpr }
    \\AstExpr :: enum {
    \\    int: i64,
    \\    ident: []const u8,
    \\    binary: AstBinary,
    \\}
    \\AstLocal :: struct { name: []const u8, value: AstExpr }
    \\AstAssign :: struct { target: AstExpr, value: AstExpr }
    \\AstStmt :: enum {
    \\    local: AstLocal,
    \\    assign: AstAssign,
    \\    expr: AstExpr,
    \\}
    \\AstBlock :: struct { stmts: []AstStmt }
;
