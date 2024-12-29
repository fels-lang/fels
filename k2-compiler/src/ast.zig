const Span = @import("lexer/span.zig").Span;

pub const NodeId = u32;

pub const Module = struct {
    file_name: []const u8,
    items: []const Item,

    pub fn empty(file_name: []const u8) Module {
        return .{ .file_name = file_name, .items = &.{} };
    }
};

pub const Item = union(enum) {
    import: ImportDecl,
    const_decl: ConstDecl,
    type_decl: TypeDecl,
    function: FunctionDecl,

    pub fn name(self: Item) ?[]const u8 {
        return switch (self) {
            .import => null,
            .const_decl => |decl| decl.name,
            .type_decl => |decl| decl.name,
            .function => |decl| decl.name,
        };
    }

    pub fn span(self: Item) Span {
        return switch (self) {
            .import => |decl| decl.span,
            .const_decl => |decl| decl.span,
            .type_decl => |decl| decl.span,
            .function => |decl| decl.span,
        };
    }
};

pub const ImportDecl = struct {
    path: []const []const u8,
    span: Span,
};

pub const Attribute = struct {
    name: []const u8,
    args: []const Expr,
    span: Span,
};

pub const ConstDecl = struct {
    attrs: []const Attribute,
    name: []const u8,
    value: Expr,
    span: Span,
};

pub const TypeDecl = struct {
    attrs: []const Attribute,
    name: []const u8,
    kind: TypeDeclKind,
    span: Span,
};

pub const TypeDeclKind = union(enum) {
    distinct: TypeRef,
    opaque_type,
    struct_type: StructDecl,
    errors: ErrorDecl,
    enum_type: EnumDecl,
};

/// An enum declaration: `Name :: enum { variant, variant: T, ... }`
pub const EnumDecl = struct {
    variants: []const EnumVariantDecl,
};

pub const EnumVariantDecl = struct {
    name:    []const u8,
    payload: ?TypeRef,   // null → no payload
    span:    Span,
};

pub const StructDecl = struct {
    fields: []const FieldDecl,
};

pub const ErrorDecl = struct {
    variants: []const ErrorVariantDecl,
};

pub const ErrorVariantDecl = struct {
    name: []const u8,
    payload: ?TypeRef,
    span: Span,
};

pub const FieldDecl = struct {
    name: []const u8,
    ty: TypeRef,
    span: Span,
};

pub const FunctionDecl = struct {
    attrs: []const Attribute,
    name: []const u8,
    type_params: []const []const u8,
    params: []const Param,
    return_ty: TypeRef,
    error_ty: ?ErrorSpec,
    body: ?Block,
    span: Span,
};

pub const Param = struct {
    name: []const u8,
    ty: TypeRef,
    // When true, the param IS a type argument ($T: type) — its name is the type var.
    is_type_param: bool = false,
    span: Span,
};

pub const Block = struct {
    statements: []const Stmt,
    span: Span,
};

pub const Stmt = union(enum) {
    local_infer: LocalInfer,
    local_typed: LocalTyped,
    assign: AssignStmt,
    return_stmt: ReturnStmt,
    fail_stmt: FailStmt,
    if_stmt: IfStmt,
    while_stmt: WhileStmt,
    unsafe_block: Block,
    break_stmt: Span,
    continue_stmt: Span,
    zone_block: ZoneBlock,
    defer_stmt: DeferStmt,
    match_stmt: MatchStmt,
    comptime_if:  ComptimeIfStmt,
    comptime_run: Block,
    expr: Expr,
};

pub const ComptimeIfStmt = struct {
    condition:  Expr,
    then_block: Block,
    else_block: ?Block,
    span:       Span,
};

pub const MatchStmt = struct {
    subject: Expr,
    arms:    []const MatchArm,
    span:    Span,
};

pub const MatchArm = struct {
    variant:  []const u8,  // "" when is_else = true
    binding:  ?[]const u8, // |x| capture, null if none
    body:     Block,
    is_else:  bool,
    span:     Span,
};

pub const DeferStmt = struct {
    mode: DeferMode,
    body: Block,
    span: Span,
};

pub const DeferMode = enum {
    always,
    ok,
    err,
};

pub const ZoneBlock = struct {
    name: []const u8,
    kind: []const u8,
    body: Block,
    span: Span,
};

pub const LocalInfer = struct {
    name: []const u8,
    value: Expr,
    span: Span,
};

pub const LocalTyped = struct {
    name: []const u8,
    ty: TypeRef,
    value: Expr,
    span: Span,
};

pub const AssignStmt = struct {
    target: Expr,
    op: AssignOp,
    value: Expr,
    span: Span,
};

pub const AssignOp = enum {
    assign,
    add,
    sub,
    mul,
    div,
    rem,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
};

pub const ReturnStmt = struct {
    value: ?Expr,
    span: Span,
};

pub const FailStmt = struct {
    variant: []const u8,
    payload: []const Expr,
    span: Span,
};

pub const IfStmt = struct {
    binding: ?IfBinding,
    payload_binding: ?[]const u8,
    condition: Expr,
    then_block: Block,
    else_block: ?Block,
    span: Span,
};

pub const IfBinding = struct {
    name: []const u8,
    value: Expr,
};

pub const WhileStmt = struct {
    condition: Expr,
    body: Block,
    span: Span,
};

pub const TypeRef = union(enum) {
    named: NamedType,
    pointer: PointerType,
    many_pointer: PointerType,
    optional: OptionalType,
    slice: SliceType,
    array: ArrayType,
    atomic: AtomicType,
    fn_type: FnType,
    inline_error_set: InlineErrorSet,
    type_param: NamedType,
    opaque_type,

    pub fn span(self: TypeRef) Span {
        return switch (self) {
            .named => |ty| ty.span,
            .pointer => |ty| ty.span,
            .many_pointer => |ty| ty.span,
            .optional => |ty| ty.span,
            .slice => |ty| ty.span,
            .array => |ty| ty.span,
            .atomic => |ty| ty.span,
            .fn_type => |ty| ty.span,
            .inline_error_set => |ty| ty.span,
            .type_param => |ty| ty.span,
            .opaque_type => Span.new(0, 0),
        };
    }
};

pub const ErrorSpec = union(enum) {
    inferred: Span,
    named: NamedType,
    inline_set: InlineErrorSet,

    pub fn span(self: ErrorSpec) Span {
        return switch (self) {
            .inferred => |span_value| span_value,
            .named => |ty| ty.span,
            .inline_set => |ty| ty.span,
        };
    }
};

pub const InlineErrorSet = struct {
    variants: []const ErrorVariantDecl,
    span: Span,
};

pub const NamedType = struct {
    name: []const u8,
    span: Span,
};

pub const PointerType = struct {
    is_const: bool = false,
    is_volatile: bool = false,
    inner: *const TypeRef,
    span: Span,
};

pub const OptionalType = struct {
    inner: *const TypeRef,
    span: Span,
};

pub const SliceType = struct {
    is_const: bool = false,
    inner: *const TypeRef,
    span: Span,
};

pub const ArrayType = struct {
    len: *const Expr,
    inner: *const TypeRef,
    span: Span,
};

pub const AtomicType = struct {
    inner: *const TypeRef,
    span: Span,
};

pub const FnType = struct {
    type_params: []const []const u8,
    params: []const TypeRef,
    ret: *const TypeRef,
    error_ty: ?ErrorSpec,
    span: Span,
};

pub const Expr = struct {
    id: NodeId,
    kind: ExprKind,
    span: Span,
};

pub const ExprKind = union(enum) {
    ident: []const u8,
    type_ref: TypeRef,
    int: []const u8,
    string: []const u8,
    bool: bool,
    null,
    compound_literal: []const Expr,
    unary: UnaryExpr,
    binary: BinaryExpr,
    unsafe_expr: *const Expr,
    run_expr:    *const Expr,  // #run expr — evaluated at compile time
    try_expr: TryExpr,
    catch_expr: CatchExpr,
    call: CallExpr,
    field: FieldExpr,
    index: IndexExpr,
    slice: SliceExpr,
};

pub const UnaryExpr = struct {
    op: UnaryOp,
    expr: *const Expr,
};

pub const UnaryOp = enum {
    address_of,
    deref,
    neg,
    not,
    bit_not,
};

pub const BinaryExpr = struct {
    op: BinaryOp,
    left: *const Expr,
    right: *const Expr,
};

pub const TryExpr = struct {
    value: *const Expr,
};

pub const CatchExpr = struct {
    value: *const Expr,
    err_name: []const u8,
    handler: Block,
};

pub const BinaryOp = enum {
    or_or,
    and_and,
    equal,
    not_equal,
    less,
    le,
    gt,
    ge,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    add,
    sub,
    mul,
    div,
    rem,
};

pub const CallExpr = struct {
    callee: *const Expr,
    args: []const CallArg,
};

pub const CallArg = union(enum) {
    positional: Expr,
    named: NamedArg,
};

pub const NamedArg = struct {
    name: []const u8,
    value: Expr,
};

pub const FieldExpr = struct {
    base: *const Expr,
    name: []const u8,
};

pub const IndexExpr = struct {
    base: *const Expr,
    index: *const Expr,
};

pub const SliceExpr = struct {
    base: *const Expr,
};
