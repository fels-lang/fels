// Compiler-provided `ast.*` type surface for metaprogramming (Phase 2,
// generative Flavor A). These are ordinary K2 types — a faithful subset of the
// compiler's own AST in `src/ast.zig` — so user code can construct them (via
// `#quote`), `match` on them, and return them from a comptime function. The
// materializer (`materializeExpr`/`materializeStmt`) and reifier (`Reifier`) in
// `ir.zig` map between these aggregates and real `ast.zig` nodes.
//
// K2 has a flat type namespace (no `ast.Block` qualified form yet), so these use
// an `Ast` prefix. Identity fields (NodeId/Span) are intentionally omitted — the
// compiler stamps those when reifying at the splice site. Recursive references
// inside expression payloads use `*AstExpr` / `*AstType` to keep types finite.
//
// Conventions: an optional sub-expression (slice bounds) uses the `nothing`
// AstExpr as "absent"; an optional string (binding names) uses "" as "absent".
//
// IMPORTANT: variant ORDER is not load-bearing — the reifier looks variant names
// up by tag from the lowered module, so this can be reordered/grown freely.
// Struct FIELD order IS mirrored by hardcoded offsets in the reifier; keep
// fields in the order the reifier expects (documented there).
pub const source =
    \\AstBinOp :: enum {
    \\    add, sub, mul, div, rem,
    \\    eq, ne, lt, le, gt, ge,
    \\    logic_and, logic_or,
    \\    bit_and, bit_or, bit_xor, shl, shr,
    \\}
    \\AstUnOp :: enum { neg, logic_not, bit_not, deref, addr }
    \\AstDeferMode :: enum { always, ok_only, err_only }
    \\
    \\AstArrayTy :: struct { len: *AstExpr, elem: *AstType }
    \\AstType :: enum {
    \\    named:       []const u8,
    \\    ptr:         *AstType,
    \\    slice_of:    *AstType,
    \\    optional_of: *AstType,
    \\    array_of:    AstArrayTy,
    \\}
    \\
    \\AstArg      :: struct { name: []const u8, value: AstExpr }
    \\AstBinary   :: struct { op: AstBinOp, left: *AstExpr, right: *AstExpr }
    \\AstUnary    :: struct { op: AstUnOp, operand: *AstExpr }
    \\AstCall     :: struct { callee: *AstExpr, args: []AstArg }
    \\AstField    :: struct { base: *AstExpr, name: []const u8 }
    \\AstIndex    :: struct { base: *AstExpr, idx: *AstExpr }
    \\AstSliceE   :: struct { base: *AstExpr, start: *AstExpr, end: *AstExpr }
    \\AstCastE    :: struct { value: *AstExpr, to: AstType }
    \\AstCoalesce :: struct { value: *AstExpr, default: *AstExpr }
    \\AstCatchE   :: struct { value: *AstExpr, err_name: []const u8, handler: AstBlock }
    \\
    \\AstExpr :: enum {
    \\    int:     i64,
    \\    float:   f64,
    \\    str:     []const u8,
    \\    boolean: bool,
    \\    nothing,
    \\    ident:   []const u8,
    \\    unary:   AstUnary,
    \\    binary:  AstBinary,
    \\    call:    AstCall,
    \\    field:   AstField,
    \\    index:   AstIndex,
    \\    slice:    AstSliceE,
    \\    cast:     AstCastE,
    \\    unwrap:   *AstExpr,
    \\    coalesce: AstCoalesce,
    \\    try_q:    *AstExpr,
    \\    catch_b:  AstCatchE,
    \\    compound: []AstExpr,
    \\    unsafe_e: *AstExpr,
    \\}
    \\
    \\AstLocal      :: struct { name: []const u8, value: AstExpr }
    \\AstLocalTyped :: struct { name: []const u8, ty: AstType, value: AstExpr }
    \\AstAssign     :: struct { target: AstExpr, value: AstExpr }
    \\AstIf         :: struct { cond: AstExpr, then_block: AstBlock, else_block: AstBlock }
    \\AstWhile      :: struct { cond: AstExpr, body: AstBlock }
    \\AstForRange   :: struct { binding: []const u8, start: AstExpr, end: AstExpr, inclusive: bool, body: AstBlock }
    \\AstForSlice   :: struct { binding: []const u8, index_binding: []const u8, by_ref: bool, iter: AstExpr, body: AstBlock }
    \\AstZone       :: struct { name: []const u8, kind: []const u8, body: AstBlock }
    \\AstDefer      :: struct { mode: AstDeferMode, body: AstBlock }
    \\AstFail       :: struct { variant: []const u8, payload: []AstExpr }
    \\AstPattern    :: enum { variant: []const u8, ints: []AstExpr, anything }
    \\AstMatchArm   :: struct { pattern: AstPattern, binding: []const u8, body: AstBlock }
    \\AstMatch      :: struct { subject: AstExpr, arms: []AstMatchArm }
    \\
    \\AstStmt :: enum {
    \\    local:       AstLocal,
    \\    local_typed: AstLocalTyped,
    \\    assign:      AstAssign,
    \\    ret,
    \\    ret_expr:    AstExpr,
    \\    cond:        AstIf,
    \\    loop:        AstWhile,
    \\    for_range:   AstForRange,
    \\    for_slice:   AstForSlice,
    \\    match_s:     AstMatch,
    \\    zone_s:      AstZone,
    \\    defer_s:     AstDefer,
    \\    fail_s:      AstFail,
    \\    unsafe_blk:  AstBlock,
    \\    brk,
    \\    cont,
    \\    expr:        AstExpr,
    \\}
    \\
    \\AstBlock :: struct { stmts: []AstStmt }
;
