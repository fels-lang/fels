const std = @import("std");
const ast = @import("ast.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;
const Span = @import("lexer/span.zig").Span;
const lexer = @import("lexer/tokens.zig");
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;

pub const ParseResult = struct {
    module: ast.Module,
    next_id: ast.NodeId,
};

pub const ParseError = error{
    ParseFailed,
    OutOfMemory,
};

pub fn parseSource(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    source: []const u8,
) ParseError!ast.Module {
    const result = try parseSourceFrom(allocator, file_name, source, 1);
    return result.module;
}

pub fn parseSourceFrom(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    source: []const u8,
    next_id: ast.NodeId,
) ParseError!ParseResult {
    var p = try Parser.init(allocator, file_name, source, next_id);
    defer p.deinit();

    const module = try p.parseModule();
    if (p.diagnostics.items.len != 0) return error.ParseFailed;
    return .{ .module = module, .next_id = p.next_id };
}

pub const Parser = struct {
    allocator: std.mem.Allocator,
    file_name: []const u8,
    source: []const u8,
    tokens: []Token,
    index: usize = 0,
    next_id: ast.NodeId,
    diagnostics: std.ArrayList(Diagnostic) = .empty,

    pub fn init(allocator: std.mem.Allocator, file_name: []const u8, source: []const u8, next_id: ast.NodeId) !Parser {
        var lex = lexer.Lexer.init(source);
        return .{
            .allocator = allocator,
            .file_name = file_name,
            .source = source,
            .tokens = try lex.all(allocator),
            .next_id = next_id,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.allocator.free(self.tokens);
        self.diagnostics.deinit(self.allocator);
    }

    pub fn parseModule(self: *Parser) ParseError!ast.Module {
        var items: std.ArrayList(ast.Item) = .empty;
        errdefer items.deinit(self.allocator);

        while (!self.check(.eof)) {
            const attrs = try self.parseAttributes();
            if (self.match(.hash)) {
                try items.append(self.allocator, .{ .import = try self.parseImport(self.previous()) });
                continue;
            }

            try items.append(self.allocator, try self.parseTopLevel(attrs));
        }

        return .{
            .file_name = self.file_name,
            .items = try items.toOwnedSlice(self.allocator),
        };
    }

    fn parseImport(self: *Parser, hash: Token) ParseError!ast.ImportDecl {
        _ = try self.expect(.keyword_import, "expected import after #");
        const path = try self.parsePath();
        const semi = try self.expect(.semicolon, "expected ; after import");
        return .{ .path = path, .span = spanFrom(hash, semi) };
    }

    fn parseTopLevel(self: *Parser, attrs: []const ast.Attribute) ParseError!ast.Item {
        const name = try self.expect(.ident, "expected declaration name");
        _ = try self.expect(.colon_colon, "expected :: after declaration name");

        if (self.match(.keyword_fn)) {
            return .{ .function = try self.finishFunction(attrs, name, true) };
        }
        if (self.match(.keyword_struct)) {
            return .{ .type_decl = try self.finishStruct(attrs, name) };
        }
        if (self.match(.keyword_errors)) {
            return .{ .type_decl = try self.finishErrors(attrs, name) };
        }
        if (self.match(.keyword_enum)) {
            return .{ .type_decl = try self.finishEnum(attrs, name) };
        }
        if (self.match(.keyword_distinct)) {
            const ty = try self.parseType();
            const semi = try self.expect(.semicolon, "expected ; after distinct type");
            return .{ .type_decl = .{
                .attrs = attrs,
                .name = name.text(self.source),
                .kind = .{ .distinct = ty },
                .span = spanFrom(name, semi),
            } };
        }
        if (self.match(.keyword_opaque)) {
            const semi = try self.expect(.semicolon, "expected ; after opaque type");
            return .{ .type_decl = .{
                .attrs = attrs,
                .name = name.text(self.source),
                .kind = .opaque_type,
                .span = spanFrom(name, semi),
            } };
        }

        const value = try self.parseExpr(0);
        const semi = try self.expect(.semicolon, "expected ; after constant declaration");
        return .{ .const_decl = .{
            .attrs = attrs,
            .name = name.text(self.source),
            .value = value,
            .span = spanFrom(name, semi),
        } };
    }

    fn finishStruct(self: *Parser, attrs: []const ast.Attribute, name: Token) ParseError!ast.TypeDecl {
        // Optional type params: struct($T: type, $U: type) { ... }
        var type_params: std.ArrayList([]const u8) = .empty;
        errdefer type_params.deinit(self.allocator);
        if (self.match(.l_paren)) {
            while (!self.check(.r_paren) and !self.check(.eof)) {
                _ = try self.expect(.dollar, "expected $ before struct type param");
                const tp = try self.expect(.ident, "expected type param name");
                _ = try self.expect(.colon, "expected : after type param");
                _ = try self.expect(.keyword_type, "expected 'type' after $T:");
                try type_params.append(self.allocator, tp.text(self.source));
                if (!self.match(.comma)) break;
            }
            _ = try self.expect(.r_paren, "expected ) after struct type params");
        }

        _ = try self.expect(.l_brace, "expected { after struct");
        var fields: std.ArrayList(ast.FieldDecl) = .empty;
        errdefer fields.deinit(self.allocator);

        while (!self.check(.r_brace) and !self.check(.eof)) {
            const field_name = try self.expect(.ident, "expected field name");
            _ = try self.expect(.colon, "expected : after field name");
            const ty = try self.parseType();
            const end = if (self.match(.comma)) self.previous() else field_name;
            try fields.append(self.allocator, .{
                .name = field_name.text(self.source),
                .ty = ty,
                .span = spanFrom(field_name, end),
            });
        }

        const close = try self.expect(.r_brace, "expected } after struct fields");
        return .{
            .attrs = attrs,
            .name = name.text(self.source),
            .kind = .{ .struct_type = .{
                .type_params = try type_params.toOwnedSlice(self.allocator),
                .fields = try fields.toOwnedSlice(self.allocator),
            } },
            .span = spanFrom(name, close),
        };
    }

    fn parseComptimeDirective(self: *Parser, hash: Token) ParseError!ast.Stmt {
        // #if cond { ... } else { ... }
        if (self.match(.keyword_if)) {
            const start = self.previous();
            const cond = try self.parseExpr(0);
            const then_block = try self.parseBlock();
            const else_block = if (self.match(.keyword_else)) try self.parseBlock() else null;
            const end = if (else_block) |b| b.span else then_block.span;
            return .{ .comptime_if = .{
                .condition = cond,
                .then_block = then_block,
                .else_block = else_block,
                .span = spanFrom(start, end),
            } };
        }
        // #run { ... }  or  #run expr;
        if (self.matchIdent("run")) {
            if (self.check(.l_brace)) {
                return .{ .comptime_run = try self.parseBlock() };
            }
            // Single-statement #run expr;
            const stmt = try self.parseStmt();
            var stmts: std.ArrayList(ast.Stmt) = .empty;
            errdefer stmts.deinit(self.allocator);
            try stmts.append(self.allocator, stmt);
            const body = ast.Block{
                .statements = try stmts.toOwnedSlice(self.allocator),
                .span = Span.new(hash.start, hash.start + hash.len),
            };
            return .{ .comptime_run = body };
        }
        try self.errorAt(hash, "unknown compile-time directive; expected #if or #run");
        return error.ParseFailed;
    }

    fn finishEnum(self: *Parser, attrs: []const ast.Attribute, name: Token) ParseError!ast.TypeDecl {
        _ = try self.expect(.l_brace, "expected { after enum");
        var variants: std.ArrayList(ast.EnumVariantDecl) = .empty;
        errdefer variants.deinit(self.allocator);

        while (!self.check(.r_brace) and !self.check(.eof)) {
            const start = self.peek();
            _ = self.match(.dot); // optional leading dot
            const variant_name = try self.expect(.ident, "expected variant name");
            const payload = if (self.match(.colon)) try self.parseType() else null;
            const end = if (self.match(.comma)) self.previous() else variant_name;
            try variants.append(self.allocator, .{
                .name = variant_name.text(self.source),
                .payload = payload,
                .span = spanFrom(start, end),
            });
        }

        const close = try self.expect(.r_brace, "expected } after enum variants");
        return .{
            .attrs = attrs,
            .name = name.text(self.source),
            .kind = .{ .enum_type = .{ .variants = try variants.toOwnedSlice(self.allocator) } },
            .span = spanFrom(name, close),
        };
    }

    fn parseMatch(self: *Parser, start: Token) ParseError!ast.MatchStmt {
        const subject = try self.parseExpr(0);
        _ = try self.expect(.l_brace, "expected { after match subject");

        var arms: std.ArrayList(ast.MatchArm) = .empty;
        errdefer arms.deinit(self.allocator);

        while (!self.check(.r_brace) and !self.check(.eof)) {
            const arm_start = self.peek();
            const is_else = self.match(.keyword_else);
            var variant: []const u8 = "";
            var binding: ?[]const u8 = null;

            if (!is_else) {
                _ = try self.expect(.dot, "expected . before variant name in match arm");
                const vname = try self.expect(.ident, "expected variant name");
                variant = vname.text(self.source);
            }

            // Optional payload binding: |x|
            if (self.match(.pipe)) {
                const bname = try self.expect(.ident, "expected binding name");
                _ = try self.expect(.pipe, "expected closing | after binding");
                binding = bname.text(self.source);
            }

            _ = try self.expect(.fat_arrow, "expected => after match pattern");

            // Body: either a block { ... } or a single statement.
            const body = if (self.check(.l_brace)) blk: {
                const b = try self.parseBlock();
                _ = self.match(.comma);
                break :blk b;
            } else blk: {
                const arm_start_tok = self.peek();
                const arm_stmt = try self.parseStmt();
                _ = self.match(.comma);
                var stmts: std.ArrayList(ast.Stmt) = .empty;
                errdefer stmts.deinit(self.allocator);
                try stmts.append(self.allocator, arm_stmt);
                break :blk ast.Block{
                    .statements = try stmts.toOwnedSlice(self.allocator),
                    .span = spanFrom(arm_start_tok, self.previous()),
                };
            };

            try arms.append(self.allocator, .{
                .variant = variant,
                .binding = binding,
                .body = body,
                .is_else = is_else,
                .span = spanFrom(arm_start, body.span),
            });
        }

        const close = try self.expect(.r_brace, "expected } after match arms");
        return .{
            .subject = subject,
            .arms = try arms.toOwnedSlice(self.allocator),
            .span = spanFrom(start, close),
        };
    }

    fn finishErrors(self: *Parser, attrs: []const ast.Attribute, name: Token) ParseError!ast.TypeDecl {
        _ = try self.expect(.l_brace, "expected { after errors");
        const variants = try self.parseErrorVariants(.r_brace);
        const close = try self.expect(.r_brace, "expected } after errors");
        return .{
            .attrs = attrs,
            .name = name.text(self.source),
            .kind = .{ .errors = .{ .variants = variants } },
            .span = spanFrom(name, close),
        };
    }

    fn parseErrorVariants(self: *Parser, end_kind: TokenKind) ParseError![]const ast.ErrorVariantDecl {
        var variants: std.ArrayList(ast.ErrorVariantDecl) = .empty;
        errdefer variants.deinit(self.allocator);

        while (!self.check(end_kind) and !self.check(.eof)) {
            const start = self.peek();
            _ = self.match(.dot);
            const variant_name = try self.expect(.ident, "expected error variant name");
            const payload = if (self.match(.colon)) try self.parseType() else null;
            const end = if (self.match(.comma)) self.previous() else variant_name;
            try variants.append(self.allocator, .{
                .name = variant_name.text(self.source),
                .payload = payload,
                .span = spanFrom(start, end),
            });
        }

        return variants.toOwnedSlice(self.allocator);
    }

    fn parseErrorSpec(self: *Parser, bang: Token) ParseError!ast.ErrorSpec {
        if (self.check(.l_brace) and self.peekKind(1) == .dot) {
            _ = self.advance();
            const variants = try self.parseErrorVariants(.r_brace);
            const close = try self.expect(.r_brace, "expected } after inline error set");
            return .{ .inline_set = .{ .variants = variants, .span = spanFrom(bang, close) } };
        }
        if (isTypeName(self.peek().kind)) {
            const name = self.advance();
            return .{ .named = .{ .name = name.text(self.source), .span = spanFrom(name, name) } };
        }
        return .{ .inferred = spanFrom(bang, bang) };
    }

    fn finishFunction(self: *Parser, attrs: []const ast.Attribute, name: Token, top_level: bool) ParseError!ast.FunctionDecl {
        _ = top_level;
        _ = try self.expect(.l_paren, "expected ( after fn");
        var params: std.ArrayList(ast.Param) = .empty;
        errdefer params.deinit(self.allocator);
        var type_params: std.ArrayList([]const u8) = .empty;
        errdefer type_params.deinit(self.allocator);

        if (!self.check(.r_paren)) {
            while (true) {
                if (self.match(.dollar)) {
                    // $T: type  — explicit type-only param; the param name IS the type variable.
                    // Used as: zeroed($T: type) -> T
                    const tp_name = try self.expect(.ident, "expected type parameter name after $");
                    _ = try self.expect(.colon, "expected : after $T");
                    _ = try self.expect(.keyword_type, "expected 'type' after $T:");
                    try type_params.append(self.allocator, tp_name.text(self.source));
                    try params.append(self.allocator, .{
                        .name = tp_name.text(self.source),
                        .ty = .{ .type_param = .{ .name = tp_name.text(self.source), .span = spanFrom(tp_name, tp_name) } },
                        .is_type_param = true,
                        .span = spanFrom(tp_name, tp_name),
                    });
                } else {
                    // Regular param, but type may be $T (introducing a type variable).
                    // Syntax: name: $T   or   name: T  (T already introduced)
                    const param_name = try self.expect(.ident, "expected parameter name");
                    _ = try self.expect(.colon, "expected : after parameter name");
                    if (self.match(.dollar)) {
                        // a: $T — introduces type variable T, param type is T
                        const tp_name = try self.expect(.ident, "expected type variable name after $");
                        try type_params.append(self.allocator, tp_name.text(self.source));
                        try params.append(self.allocator, .{
                            .name = param_name.text(self.source),
                            .ty = .{ .type_param = .{ .name = tp_name.text(self.source), .span = spanFrom(tp_name, tp_name) } },
                            .span = spanFrom(param_name, tp_name),
                        });
                    } else {
                        const ty = try self.parseType();
                        try params.append(self.allocator, .{
                            .name = param_name.text(self.source),
                            .ty = ty,
                            .span = ty.span(),
                        });
                    }
                }
                if (!self.match(.comma)) break;
                if (self.check(.r_paren)) break;
            }
        }

        _ = try self.expect(.r_paren, "expected ) after parameters");
        const return_ty = if (self.match(.arrow)) try self.parseType() else namedType("void", Span.new(@intCast(name.start), @intCast(name.start + name.len)));
        const error_ty = if (self.match(.bang)) try self.parseErrorSpec(self.previous()) else null;
        const body = if (self.check(.l_brace)) try self.parseBlock() else null;
        const end = if (body) |b| b.span else blk: {
            const semi = try self.expect(.semicolon, "expected ; after external function declaration");
            break :blk spanFrom(name, semi);
        };

        return .{
            .attrs = attrs,
            .name = name.text(self.source),
            .type_params = try type_params.toOwnedSlice(self.allocator),
            .params = try params.toOwnedSlice(self.allocator),
            .return_ty = return_ty,
            .error_ty = error_ty,
            .body = body,
            .span = Span.new(name.start, end.end),
        };
    }

    fn parseBlock(self: *Parser) ParseError!ast.Block {
        const open = try self.expect(.l_brace, "expected {");
        var statements: std.ArrayList(ast.Stmt) = .empty;
        errdefer statements.deinit(self.allocator);

        while (!self.check(.r_brace) and !self.check(.eof)) {
            try statements.append(self.allocator, try self.parseStmt());
        }

        const close = try self.expect(.r_brace, "expected } after block");
        return .{
            .statements = try statements.toOwnedSlice(self.allocator),
            .span = spanFrom(open, close),
        };
    }

    fn parseStmt(self: *Parser) ParseError!ast.Stmt {
        if (self.match(.keyword_return)) {
            const start = self.previous();
            const value = if (!self.check(.semicolon)) try self.parseExpr(0) else null;
            const semi = try self.expect(.semicolon, "expected ; after return");
            return .{ .return_stmt = .{ .value = value, .span = spanFrom(start, semi) } };
        }
        if (self.match(.keyword_fail)) return .{ .fail_stmt = try self.parseFail(self.previous()) };
        if (self.match(.keyword_break)) {
            const tok = self.previous();
            const semi = try self.expect(.semicolon, "expected ; after break");
            return .{ .break_stmt = spanFrom(tok, semi) };
        }
        if (self.match(.keyword_continue)) {
            const tok = self.previous();
            const semi = try self.expect(.semicolon, "expected ; after continue");
            return .{ .continue_stmt = spanFrom(tok, semi) };
        }
        if (self.match(.keyword_defer)) return .{ .defer_stmt = try self.parseDefer(self.previous()) };
        if (self.match(.keyword_match)) return .{ .match_stmt = try self.parseMatch(self.previous()) };
        // Compile-time directives: #if, #run
        if (self.match(.hash)) return try self.parseComptimeDirective(self.previous());
        if (self.match(.keyword_zone)) return .{ .zone_block = try self.parseZoneBlock(self.previous()) };
        if (self.match(.keyword_unsafe)) return .{ .unsafe_block = try self.parseBlock() };
        if (self.match(.keyword_if)) return .{ .if_stmt = try self.parseIf(self.previous()) };
        if (self.match(.keyword_while)) return .{ .while_stmt = try self.parseWhile(self.previous()) };
        if (self.match(.keyword_for)) return try self.parseFor(self.previous());

        if (self.check(.ident) and self.peekKind(1) == .colon_eq) {
            const name = self.advance();
            _ = self.advance();
            const value = try self.parseExpr(0);
            const semi = try self.expect(.semicolon, "expected ; after local");
            return .{ .local_infer = .{
                .name = name.text(self.source),
                .value = value,
                .span = spanFrom(name, semi),
            } };
        }
        if (self.check(.ident) and self.peekKind(1) == .colon) {
            const name = self.advance();
            _ = self.advance();
            const ty = try self.parseType();
            _ = try self.expect(.eq, "expected = after typed local");
            const value = try self.parseExpr(0);
            const semi = try self.expect(.semicolon, "expected ; after typed local");
            return .{ .local_typed = .{
                .name = name.text(self.source),
                .ty = ty,
                .value = value,
                .span = spanFrom(name, semi),
            } };
        }

        const statement_expr = try self.parseExpr(0);
        if (isAssignOp(self.peek().kind)) {
            const op_tok = self.advance();
            const op = assignOpFromToken(op_tok.kind);
            const value = try self.parseExpr(0);
            const semi = try self.expect(.semicolon, "expected ; after assignment");
            return .{ .assign = .{
                .target = statement_expr,
                .op = op,
                .value = value,
                .span = spanFrom(statement_expr.span, semi),
            } };
        }

        _ = try self.expect(.semicolon, "expected ; after expression");
        return .{ .expr = statement_expr };
    }

    fn parseIf(self: *Parser, start: Token) ParseError!ast.IfStmt {
        var binding: ?ast.IfBinding = null;
        var payload_binding: ?[]const u8 = null;
        var condition: ast.Expr = undefined;

        if (self.check(.ident) and self.peekKind(1) == .colon_eq) {
            const name = self.advance();
            _ = self.advance();
            const value = try self.parseExpr(0);
            binding = .{ .name = name.text(self.source), .value = value };
            condition = value;
        } else {
            condition = try self.parseExpr(0);
        }

        if (self.match(.pipe)) {
            const name = try self.expect(.ident, "expected error payload binding");
            _ = try self.expect(.pipe, "expected | after error payload binding");
            payload_binding = name.text(self.source);
        }

        const then_block = try self.parseBlock();
        const else_block = if (self.match(.keyword_else)) try self.parseBlock() else null;
        const end = if (else_block) |b| b.span else then_block.span;
        return .{ .binding = binding, .payload_binding = payload_binding, .condition = condition, .then_block = then_block, .else_block = else_block, .span = Span.new(start.start, end.end) };
    }

    fn parseDefer(self: *Parser, start: Token) ParseError!ast.DeferStmt {
        var mode: ast.DeferMode = .always;
        if (self.match(.dot)) {
            const mode_name = try self.expect(.ident, "expected defer mode");
            const text = mode_name.text(self.source);
            if (std.mem.eql(u8, text, "ok")) {
                mode = .ok;
            } else if (std.mem.eql(u8, text, "err")) {
                mode = .err;
            } else {
                try self.errorAt(mode_name, "expected ok or err after defer.");
                return error.ParseFailed;
            }
        }
        // defer { ... }  or  defer expr;
        if (self.check(.l_brace)) {
            const body = try self.parseBlock();
            return .{ .mode = mode, .body = body, .span = spanFrom(start, body.span) };
        }
        // Single expression statement — wrap in a one-stmt block
        const deferred_expr = try self.parseExpr(0);
        const semi = try self.expect(.semicolon, "expected ; after defer expression");
        const stmt_span = spanFrom(deferred_expr.span, semi);
        var stmts = std.ArrayList(ast.Stmt).empty;
        errdefer stmts.deinit(self.allocator);
        try stmts.append(self.allocator, .{ .expr = deferred_expr });
        const body = ast.Block{
            .statements = try stmts.toOwnedSlice(self.allocator),
            .span = stmt_span,
        };
        return .{ .mode = mode, .body = body, .span = spanFrom(start, semi) };
    }

    fn parseFail(self: *Parser, start: Token) ParseError!ast.FailStmt {
        _ = try self.expect(.dot, "expected .variant after fail");
        const variant = try self.expect(.ident, "expected error variant after fail .");
        var payload: []const ast.Expr = &.{};
        if (self.match(.l_brace)) {
            var values: std.ArrayList(ast.Expr) = .empty;
            errdefer values.deinit(self.allocator);
            if (!self.check(.r_brace)) {
                while (true) {
                    try values.append(self.allocator, try self.parseExpr(0));
                    if (!self.match(.comma)) break;
                    if (self.check(.r_brace)) break;
                }
            }
            _ = try self.expect(.r_brace, "expected } after error payload");
            payload = try values.toOwnedSlice(self.allocator);
        }
        const semi = try self.expect(.semicolon, "expected ; after fail");
        return .{ .variant = variant.text(self.source), .payload = payload, .span = spanFrom(start, semi) };
    }

    fn parseZoneBlock(self: *Parser, start: Token) ParseError!ast.ZoneBlock {
        const name = try self.expect(.ident, "expected zone name");
        _ = try self.expect(.colon, "expected : after zone name");
        const kind = try self.expect(.ident, "expected zone kind (Arena, Pool, ...)");
        const body = try self.parseBlock();
        return .{
            .name = name.text(self.source),
            .kind = kind.text(self.source),
            .body = body,
            .span = spanFrom(start, body.span),
        };
    }

    fn parseWhile(self: *Parser, start: Token) ParseError!ast.WhileStmt {
        const condition = try self.parseExpr(0);
        const body = try self.parseBlock();
        return .{ .condition = condition, .body = body, .span = Span.new(start.start, body.span.end) };
    }

    fn parseFor(self: *Parser, start: Token) ParseError!ast.Stmt {
        const by_ref = self.match(.amp);
        const binding = try self.expect(.ident, "expected loop binding");
        var index_binding: ?[]const u8 = null;
        if (self.match(.comma)) {
            const index = try self.expect(.ident, "expected index binding");
            index_binding = index.text(self.source);
        }
        _ = try self.expect(.keyword_in, "expected `in` after loop binding");

        const first = try self.parseExpr(0);
        if (self.match(.dot_dot) or self.match(.dot_dot_eq)) {
            if (by_ref or index_binding != null) {
                try self.errorAt(self.previous(), "range loops do not support reference or index bindings");
                return error.ParseFailed;
            }
            const inclusive = self.previous().kind == .dot_dot_eq;
            const end = try self.parseExpr(0);
            const body = try self.parseBlock();
            return .{ .for_range = .{
                .binding = binding.text(self.source),
                .start = first,
                .end = end,
                .inclusive = inclusive,
                .body = body,
                .span = Span.new(start.start, body.span.end),
            } };
        }

        const body = try self.parseBlock();
        return .{ .for_slice = .{
            .binding = binding.text(self.source),
            .index_binding = index_binding,
            .by_ref = by_ref,
            .iter = first,
            .body = body,
            .span = Span.new(start.start, body.span.end),
        } };
    }

    fn parseAttributes(self: *Parser) ParseError![]const ast.Attribute {
        var attrs: std.ArrayList(ast.Attribute) = .empty;
        errdefer attrs.deinit(self.allocator);

        while (self.check(.hash) and self.peekKind(1) != .keyword_import) {
            const hash = self.advance();
            const name = try self.expect(.ident, "expected attribute name");
            var args: []const ast.Expr = &.{};
            if (self.match(.l_paren)) {
                var list: std.ArrayList(ast.Expr) = .empty;
                errdefer list.deinit(self.allocator);
                if (!self.check(.r_paren)) {
                    while (true) {
                        try list.append(self.allocator, try self.parseExpr(0));
                        if (!self.match(.comma)) break;
                    }
                }
                _ = try self.expect(.r_paren, "expected ) after attribute");
                args = try list.toOwnedSlice(self.allocator);
            }
            try attrs.append(self.allocator, .{ .name = name.text(self.source), .args = args, .span = spanFrom(hash, name) });
        }

        return attrs.toOwnedSlice(self.allocator);
    }

    fn parsePath(self: *Parser) ParseError![]const []const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        errdefer parts.deinit(self.allocator);

        try parts.append(self.allocator, (try self.expect(.ident, "expected path segment")).text(self.source));
        while (self.match(.dot)) {
            try parts.append(self.allocator, (try self.expect(.ident, "expected path segment")).text(self.source));
        }
        return parts.toOwnedSlice(self.allocator);
    }

    fn parseType(self: *Parser) ParseError!ast.TypeRef {
        const start = self.peek();
        if (self.match(.question)) {
            const inner = try self.allocType(try self.parseType());
            return .{ .optional = .{ .inner = inner, .span = Span.new(start.start, inner.span().end) } };
        }
        if (self.match(.star)) {
            var is_const = false;
            var is_volatile = false;
            if (self.match(.keyword_const)) is_const = true;
            if (self.match(.keyword_volatile)) is_volatile = true;
            const inner = try self.allocType(try self.parseType());
            return .{ .pointer = .{ .is_const = is_const, .is_volatile = is_volatile, .inner = inner, .span = Span.new(start.start, inner.span().end) } };
        }
        if (self.match(.l_bracket_star)) {
            _ = try self.expect(.r_bracket, "expected ] after [*");
            var is_const = false;
            if (self.match(.keyword_const)) is_const = true;
            const inner = try self.allocType(try self.parseType());
            return .{ .many_pointer = .{ .is_const = is_const, .inner = inner, .span = Span.new(start.start, inner.span().end) } };
        }
        if (self.match(.l_bracket)) {
            if (self.match(.r_bracket)) {
                var is_const = false;
                if (self.match(.keyword_const)) is_const = true;
                const inner = try self.allocType(try self.parseType());
                return .{ .slice = .{ .is_const = is_const, .inner = inner, .span = Span.new(start.start, inner.span().end) } };
            }
            const len = try self.parseExpr(0);
            _ = try self.expect(.r_bracket, "expected ] after array length");
            const inner = try self.allocType(try self.parseType());
            return .{ .array = .{ .len = try self.allocExpr(len), .inner = inner, .span = Span.new(start.start, inner.span().end) } };
        }
        if (self.match(.keyword_atomic)) {
            const inner = try self.allocType(try self.parseType());
            return .{ .atomic = .{ .inner = inner, .span = Span.new(start.start, inner.span().end) } };
        }
        if (self.match(.keyword_fn)) {
            _ = try self.expect(.l_paren, "expected ( after fn type");
            var params: std.ArrayList(ast.TypeRef) = .empty;
            errdefer params.deinit(self.allocator);
            if (!self.check(.r_paren)) {
                while (true) {
                    try params.append(self.allocator, try self.parseType());
                    if (!self.match(.comma)) break;
                }
            }
            _ = try self.expect(.r_paren, "expected ) after fn type params");
            _ = try self.expect(.arrow, "expected -> in fn type");
            const ret = try self.allocType(try self.parseType());
            const error_ty = if (self.match(.bang)) try self.parseErrorSpec(self.previous()) else null;
            const end = if (error_ty) |err| err.span().end else ret.span().end;
            return .{ .fn_type = .{ .type_params = &.{}, .params = try params.toOwnedSlice(self.allocator), .ret = ret, .error_ty = error_ty, .span = Span.new(start.start, end) } };
        }
        if (self.match(.keyword_opaque)) return .opaque_type;

        const name = self.advance();
        if (!isTypeName(name.kind)) {
            try self.errorAt(name, "expected type");
            return error.ParseFailed;
        }
        // Generic instantiation: Name(TypeArg1, TypeArg2, ...)
        if (self.match(.l_paren)) {
            var args: std.ArrayList(ast.TypeRef) = .empty;
            errdefer args.deinit(self.allocator);
            while (!self.check(.r_paren) and !self.check(.eof)) {
                try args.append(self.allocator, try self.parseType());
                if (!self.match(.comma)) break;
            }
            const close = try self.expect(.r_paren, "expected ) after type arguments");
            return .{ .generic_inst = .{
                .name = name.text(self.source),
                .args = try args.toOwnedSlice(self.allocator),
                .span = spanFrom(name, close),
            } };
        }
        return namedType(name.text(self.source), spanFrom(name, name));
    }

    fn parseExpr(self: *Parser, min_bp: u8) ParseError!ast.Expr {
        var left = try self.parsePrefix();

        while (true) {
            if (self.match(.l_paren)) {
                left = try self.finishCall(left);
                continue;
            }
            if (self.match(.dot)) {
                const field = try self.expect(.ident, "expected field name");
                left = try self.expr(.{ .field = .{ .base = try self.allocExpr(left), .name = field.text(self.source) } }, Span.new(left.span.start, field.start + field.len));
                continue;
            }
            if (self.match(.l_bracket)) {
                if (self.match(.colon)) {
                    const close = try self.expect(.r_bracket, "expected ] after slice");
                    left = try self.expr(.{ .slice = .{ .base = try self.allocExpr(left) } }, Span.new(left.span.start, close.start + close.len));
                } else {
                    const index = try self.parseExpr(0);
                    const close = try self.expect(.r_bracket, "expected ] after index");
                    left = try self.expr(.{ .index = .{ .base = try self.allocExpr(left), .index = try self.allocExpr(index) } }, Span.new(left.span.start, close.start + close.len));
                }
                continue;
            }
            if (self.match(.l_bracket_colon)) {
                const close = try self.expect(.r_bracket, "expected ] after slice");
                left = try self.expr(.{ .slice = .{ .base = try self.allocExpr(left) } }, Span.new(left.span.start, close.start + close.len));
                continue;
            }
            // expr?  — propagate error
            if (self.match(.question)) {
                const end = self.previous();
                left = try self.expr(.{ .try_expr = .{ .value = try self.allocExpr(left) } }, Span.new(left.span.start, end.start + end.len));
                continue;
            }
            // expr!! — force unwrap (panic if null/error)
            if (self.match(.bang_bang)) {
                const end = self.previous();
                left = try self.expr(.{ .force_unwrap = try self.allocExpr(left) }, Span.new(left.span.start, end.start + end.len));
                continue;
            }
            if (self.match(.keyword_as)) {
                const dest_ty = try self.parseType();
                left = try self.expr(.{ .as_cast = .{
                    .value = try self.allocExpr(left),
                    .to = dest_ty,
                } }, Span.new(left.span.start, dest_ty.span().end));
                continue;
            }
            // expr ?? default — nil coalesce
            if (self.match(.question_question)) {
                const default = try self.parseExpr(1); // right-associative, same precedence as ??
                left = try self.expr(.{ .nil_coalesce = .{
                    .value = try self.allocExpr(left),
                    .default = try self.allocExpr(default),
                } }, Span.new(left.span.start, default.span.end));
                continue;
            }
            if (self.match(.keyword_catch)) {
                const err_name = try self.expect(.ident, "expected error binding after catch");
                const handler = try self.parseBlock();
                left = try self.expr(.{ .catch_expr = .{ .value = try self.allocExpr(left), .err_name = err_name.text(self.source), .handler = handler } }, Span.new(left.span.start, handler.span.end));
                continue;
            }

            // Stop before |name| { — that is the payload capture in `if cond |name| { }`,
            // not a bitwise-OR chain.  The l_brace at position +3 distinguishes this from
            // a genuine `a | b | c` expression where position +3 would be another ident or operator.
            if (self.check(.pipe) and
                self.peekKind(1) == .ident and
                self.peekKind(2) == .pipe and
                self.peekKind(3) == .l_brace) break;
            const info = infixInfo(self.peek().kind) orelse break;
            if (info.left_bp < min_bp) break;
            _ = self.advance();
            const right = try self.parseExpr(info.right_bp);
            left = try self.expr(.{ .binary = .{ .op = info.op, .left = try self.allocExpr(left), .right = try self.allocExpr(right) } }, Span.new(left.span.start, right.span.end));
        }

        return left;
    }

    fn parsePrefix(self: *Parser) ParseError!ast.Expr {
        const tok = self.advance();
        switch (tok.kind) {
            .ident => return self.expr(.{ .ident = tok.text(self.source) }, spanFrom(tok, tok)),
            .keyword_bool,
            .keyword_void,
            .keyword_i8,
            .keyword_i16,
            .keyword_i32,
            .keyword_i64,
            .keyword_isize,
            .keyword_u8,
            .keyword_u16,
            .keyword_u32,
            .keyword_u64,
            .keyword_usize,
            .keyword_atomic,
            .question,
            .l_bracket,
            .l_bracket_star,
            => {
                self.index -= 1;
                const ty = try self.parseType();
                return self.expr(.{ .type_ref = ty }, ty.span());
            },
            .int_lit => return self.expr(.{ .int = tok.text(self.source) }, spanFrom(tok, tok)),
            .string_lit => return self.expr(.{ .string = tok.text(self.source) }, spanFrom(tok, tok)),
            .keyword_true => return self.expr(.{ .bool = true }, spanFrom(tok, tok)),
            .keyword_false => return self.expr(.{ .bool = false }, spanFrom(tok, tok)),
            .keyword_null => return self.expr(.null, spanFrom(tok, tok)),
            .keyword_volatile => return self.expr(.{ .ident = tok.text(self.source) }, spanFrom(tok, tok)),
            .keyword_unsafe => {
                const inner = try self.parseExpr(8);
                return self.expr(
                    .{ .unsafe_expr = try self.allocExpr(inner) },
                    Span.new(tok.start, inner.span.end),
                );
            },
            // #run expr — compile-time expression in value position
            .hash => {
                if (self.matchIdent("run")) {
                    const inner = try self.parseExpr(18);
                    return self.expr(
                        .{ .run_expr = try self.allocExpr(inner) },
                        Span.new(tok.start, inner.span.end),
                    );
                }
                try self.errorAt(tok, "expected 'run' after # in expression position");
                return error.ParseFailed;
            },
            .dot => {
                const name = try self.expect(.ident, "expected name after .");
                return self.expr(.{ .ident = self.source[tok.start .. name.start + name.len] }, spanFrom(tok, name));
            },
            .bang => {
                const operand = try self.parseExpr(18);
                return self.expr(.{ .unary = .{ .op = .not, .expr = try self.allocExpr(operand) } }, Span.new(tok.start, operand.span.end));
            },
            .tilde => {
                const operand = try self.parseExpr(18);
                return self.expr(.{ .unary = .{ .op = .bit_not, .expr = try self.allocExpr(operand) } }, Span.new(tok.start, operand.span.end));
            },
            .amp => {
                const operand = try self.parseExpr(18);
                return self.expr(.{ .unary = .{ .op = .address_of, .expr = try self.allocExpr(operand) } }, Span.new(tok.start, operand.span.end));
            },
            .star => {
                if (self.check(.keyword_const) or self.check(.keyword_volatile) or
                    (isTypeName(self.peek().kind) and switch (self.peekKind(1)) {
                        .comma, .r_paren, .r_brace, .semicolon => true,
                        else => false,
                    }))
                {
                    self.index -= 1;
                    const ty = try self.parseType();
                    return self.expr(.{ .type_ref = ty }, ty.span());
                }
                const operand = try self.parseExpr(8);
                return self.expr(.{ .unary = .{ .op = .deref, .expr = try self.allocExpr(operand) } }, Span.new(tok.start, operand.span.end));
            },
            .minus => {
                const operand = try self.parseExpr(18);
                return self.expr(.{ .unary = .{ .op = .neg, .expr = try self.allocExpr(operand) } }, Span.new(tok.start, operand.span.end));
            },
            .l_paren => {
                const inner = try self.parseExpr(0);
                _ = try self.expect(.r_paren, "expected )");
                return inner;
            },
            .dot_lbrace => return self.finishCompound(tok),
            .l_brace => {
                _ = try self.expect(.r_brace, "expected }");
                return self.expr(.{ .compound_literal = &.{} }, spanFrom(tok, self.previous()));
            },
            else => {
                try self.errorAt(tok, "expected expression");
                return error.ParseFailed;
            },
        }
    }

    fn finishCompound(self: *Parser, start: Token) ParseError!ast.Expr {
        var values: std.ArrayList(ast.Expr) = .empty;
        errdefer values.deinit(self.allocator);
        while (!self.check(.r_brace) and !self.check(.eof)) {
            try values.append(self.allocator, try self.parseExpr(0));
            _ = self.match(.comma);
        }
        const close = try self.expect(.r_brace, "expected } after compound literal");
        return self.expr(.{ .compound_literal = try values.toOwnedSlice(self.allocator) }, spanFrom(start, close));
    }

    fn finishCall(self: *Parser, callee: ast.Expr) ParseError!ast.Expr {
        var args: std.ArrayList(ast.CallArg) = .empty;
        errdefer args.deinit(self.allocator);
        if (!self.check(.r_paren)) {
            while (true) {
                if (self.check(.ident) and self.peekKind(1) == .colon) {
                    const name = self.advance();
                    _ = self.advance();
                    // Named arg value: parse a full compound literal `{ ... }` or a regular expression.
                    const value = if (self.check(.l_brace)) try self.finishCompound(self.advance()) else try self.parseExpr(0);
                    try args.append(self.allocator, .{ .named = .{ .name = name.text(self.source), .value = value } });
                } else {
                    try args.append(self.allocator, .{ .positional = try self.parseExpr(0) });
                }
                if (!self.match(.comma)) break;
                if (self.check(.r_paren)) break;
            }
        }
        const close = try self.expect(.r_paren, "expected ) after call");
        return self.expr(.{ .call = .{ .callee = try self.allocExpr(callee), .args = try args.toOwnedSlice(self.allocator) } }, Span.new(callee.span.start, close.start + close.len));
    }

    fn expr(self: *Parser, kind: ast.ExprKind, span: Span) !ast.Expr {
        const id = self.next_id;
        self.next_id += 1;
        return .{ .id = id, .kind = kind, .span = span };
    }

    fn allocExpr(self: *Parser, value: ast.Expr) !*const ast.Expr {
        const ptr = try self.allocator.create(ast.Expr);
        ptr.* = value;
        return ptr;
    }

    fn allocType(self: *Parser, value: ast.TypeRef) !*const ast.TypeRef {
        const ptr = try self.allocator.create(ast.TypeRef);
        ptr.* = value;
        return ptr;
    }

    fn matchIdent(self: *Parser, text: []const u8) bool {
        if (!self.check(.ident)) return false;
        if (!std.mem.eql(u8, self.peek().text(self.source), text)) return false;
        _ = self.advance();
        return true;
    }

    fn match(self: *Parser, kind: TokenKind) bool {
        if (!self.check(kind)) return false;
        _ = self.advance();
        return true;
    }

    fn check(self: Parser, kind: TokenKind) bool {
        return self.peek().kind == kind;
    }

    fn peek(self: Parser) Token {
        return self.tokens[@min(self.index, self.tokens.len - 1)];
    }

    fn peekKind(self: Parser, offset: usize) TokenKind {
        return self.tokens[@min(self.index + offset, self.tokens.len - 1)].kind;
    }

    fn previous(self: Parser) Token {
        return self.tokens[self.index - 1];
    }

    fn advance(self: *Parser) Token {
        const tok = self.peek();
        if (tok.kind != .eof) self.index += 1;
        return tok;
    }

    fn expect(self: *Parser, kind: TokenKind, message: []const u8) ParseError!Token {
        if (self.check(kind)) return self.advance();
        try self.errorAt(self.peek(), message);
        return error.ParseFailed;
    }

    fn errorAt(self: *Parser, tok: Token, message: []const u8) !void {
        try self.diagnostics.append(self.allocator, Diagnostic.init(message, spanFrom(tok, tok)));
    }
};

const Infix = struct {
    left_bp: u8,
    right_bp: u8,
    op: ast.BinaryOp,
};

fn infixInfo(kind: TokenKind) ?Infix {
    return switch (kind) {
        // Logical
        .pipe_pipe => .{ .left_bp = 1, .right_bp = 2, .op = .or_or },
        .amp_amp => .{ .left_bp = 3, .right_bp = 4, .op = .and_and },
        // Comparison
        .eq_eq => .{ .left_bp = 5, .right_bp = 6, .op = .equal },
        .bang_eq => .{ .left_bp = 5, .right_bp = 6, .op = .not_equal },
        .lt => .{ .left_bp = 5, .right_bp = 6, .op = .less },
        .lt_eq => .{ .left_bp = 5, .right_bp = 6, .op = .le },
        .gt => .{ .left_bp = 5, .right_bp = 6, .op = .gt },
        .gt_eq => .{ .left_bp = 5, .right_bp = 6, .op = .ge },
        // Bitwise
        .pipe => .{ .left_bp = 7, .right_bp = 8, .op = .bit_or },
        .caret => .{ .left_bp = 9, .right_bp = 10, .op = .bit_xor },
        .amp => .{ .left_bp = 11, .right_bp = 12, .op = .bit_and },
        // Shift
        .lt_lt => .{ .left_bp = 13, .right_bp = 14, .op = .shl },
        .gt_gt => .{ .left_bp = 13, .right_bp = 14, .op = .shr },
        // Additive
        .plus => .{ .left_bp = 15, .right_bp = 16, .op = .add },
        .minus => .{ .left_bp = 15, .right_bp = 16, .op = .sub },
        // Multiplicative
        .star => .{ .left_bp = 17, .right_bp = 18, .op = .mul },
        .slash => .{ .left_bp = 17, .right_bp = 18, .op = .div },
        .percent => .{ .left_bp = 17, .right_bp = 18, .op = .rem },
        else => null,
    };
}

fn isTypeName(kind: TokenKind) bool {
    return switch (kind) {
        .ident,
        .keyword_bool,
        .keyword_void,
        .keyword_i8,
        .keyword_i16,
        .keyword_i32,
        .keyword_i64,
        .keyword_isize,
        .keyword_u8,
        .keyword_u16,
        .keyword_u32,
        .keyword_u64,
        .keyword_usize,
        => true,
        else => false,
    };
}

fn isAssignOp(kind: TokenKind) bool {
    return switch (kind) {
        .eq, .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq, .amp_eq, .pipe_eq, .caret_eq, .lt_lt_eq, .gt_gt_eq => true,
        else => false,
    };
}

fn assignOpFromToken(kind: TokenKind) ast.AssignOp {
    return switch (kind) {
        .eq => .assign,
        .plus_eq => .add,
        .minus_eq => .sub,
        .star_eq => .mul,
        .slash_eq => .div,
        .percent_eq => .rem,
        .amp_eq => .bit_and,
        .pipe_eq => .bit_or,
        .caret_eq => .bit_xor,
        .lt_lt_eq => .shl,
        .gt_gt_eq => .shr,
        else => unreachable,
    };
}

fn namedType(name: []const u8, span: Span) ast.TypeRef {
    return .{ .named = .{ .name = name, .span = span } };
}

fn spanFrom(start: anytype, end: anytype) Span {
    const s = if (@TypeOf(start) == Span) start.start else start.start;
    const e = if (@TypeOf(end) == Span) end.end else end.start + end.len;
    return Span.new(s, e);
}
