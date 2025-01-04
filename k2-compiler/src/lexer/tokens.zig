const std = @import("std");

pub const TokenKind = enum {
    eof,
    invalid,

    // Names + literals
    ident,
    int_lit,
    string_lit,

    // Delimiters
    l_paren, // (
    r_paren, // )
    l_brace, // {
    r_brace, // }
    l_bracket, // [
    r_bracket, // ]

    // Punctuation
    comma, // ,
    semicolon, // ;
    colon, // :
    dot, // .
    hash, // #
    question, // ?

    // Compound punctuation
    colon_colon, // ::
    colon_eq, // :=
    arrow, // ->
    dot_lbrace, // .{
    dot_dot, // ..
    dot_dot_eq, // ..=
    l_bracket_star, // [*
    l_bracket_colon, // [:

    // Operators
    plus, // +
    plus_eq, // +=
    minus, // -
    minus_eq, // -=
    star, // *
    star_eq, // *=
    slash, // /
    slash_eq, // /=
    percent, // %
    percent_eq, // %=
    amp, // &
    amp_eq, // &=
    pipe, // |
    pipe_eq, // |=
    pipe_pipe, // ||
    caret, // ^
    caret_eq, // ^=
    tilde, // ~
    eq, // =
    eq_eq, // ==
    bang, // !
    bang_eq, // !=
    lt, // <
    lt_eq, // <=
    lt_lt, // <<
    lt_lt_eq, // <<=
    gt, // >
    gt_eq, // >=
    gt_gt, // >>
    gt_gt_eq, // >>=
    amp_amp, // &&

    // Keywords
    keyword_fn,
    keyword_struct,
    keyword_interface,
    keyword_distinct,
    keyword_opaque,
    keyword_atomic,
    keyword_const,
    keyword_volatile,
    keyword_if,
    keyword_while,
    keyword_for,
    keyword_in,
    keyword_as,
    keyword_return,
    keyword_unsafe,
    keyword_import,
    keyword_null,
    keyword_true,
    keyword_false,
    keyword_else,
    keyword_break,
    keyword_continue,
    keyword_zone,
    keyword_defer,
    keyword_type,
    keyword_enum,
    keyword_match,
    dollar, // $
    fat_arrow, // =>
    question_question, // ??
    bang_bang, // !!
    keyword_errors,
    keyword_fail,
    keyword_catch,

    // Primitive type keywords
    keyword_bool,
    keyword_void,
    keyword_i8,
    keyword_i16,
    keyword_i32,
    keyword_i64,
    keyword_isize,
    keyword_u8,
    keyword_u16,
    keyword_u32,
    keyword_u64,
    keyword_usize,
};

pub const Token = struct {
    kind: TokenKind,
    start: u32,
    len: u32,

    pub fn text(self: Token, source: []const u8) []const u8 {
        return source[self.start..][0..self.len];
    }
};

pub fn keywordKind(text: []const u8) TokenKind {
    const prefix = "keyword_";

    inline for (@typeInfo(TokenKind).@"enum".fields) |field| {
        if (field.name.len >= prefix.len and std.mem.startsWith(u8, field.name, prefix)) {
            const keyword_text = field.name[prefix.len..];

            if (std.mem.eql(u8, text, keyword_text)) {
                return @field(TokenKind, field.name);
            }
        }
    }

    return .ident;
}

pub const Lexer = struct {
    source: []const u8,
    index: usize = 0,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source };
    }

    pub fn next(self: *Lexer) Token {
        self.skipTrivia();
        const start = self.index;

        if (self.index >= self.source.len) {
            return token(.eof, start, start);
        }

        const ch = self.advance();
        switch (ch) {
            '(' => return token(.l_paren, start, self.index),
            ')' => return token(.r_paren, start, self.index),
            '{' => return token(.l_brace, start, self.index),
            '}' => return token(.r_brace, start, self.index),
            '[' => {
                if (self.match('*')) return token(.l_bracket_star, start, self.index);
                if (self.match(':')) return token(.l_bracket_colon, start, self.index);
                return token(.l_bracket, start, self.index);
            },
            ']' => return token(.r_bracket, start, self.index),
            ',' => return token(.comma, start, self.index),
            ';' => return token(.semicolon, start, self.index),
            ':' => {
                if (self.match(':')) return token(.colon_colon, start, self.index);
                if (self.match('=')) return token(.colon_eq, start, self.index);
                return token(.colon, start, self.index);
            },
            '.' => {
                if (self.match('{')) return token(.dot_lbrace, start, self.index);
                if (self.match('.')) {
                    if (self.match('=')) return token(.dot_dot_eq, start, self.index);
                    return token(.dot_dot, start, self.index);
                }
                return token(.dot, start, self.index);
            },
            '@' => {
                if (self.index < self.source.len and isIdentStart(self.source[self.index])) {
                    self.index += 1;
                    return self.ident(start);
                }
                return token(.invalid, start, self.index);
            },
            '#' => return token(.hash, start, self.index),
            '?' => {
                if (self.match('?')) return token(.question_question, start, self.index);
                return token(.question, start, self.index);
            },
            '+' => {
                if (self.match('=')) return token(.plus_eq, start, self.index);
                return token(.plus, start, self.index);
            },
            '-' => {
                if (self.match('>')) return token(.arrow, start, self.index);
                if (self.match('=')) return token(.minus_eq, start, self.index);
                return token(.minus, start, self.index);
            },
            '*' => {
                if (self.match('=')) return token(.star_eq, start, self.index);
                return token(.star, start, self.index);
            },
            '/' => {
                if (self.match('=')) return token(.slash_eq, start, self.index);
                return token(.slash, start, self.index);
            },
            '%' => {
                if (self.match('=')) return token(.percent_eq, start, self.index);
                return token(.percent, start, self.index);
            },
            '&' => {
                if (self.match('&')) return token(.amp_amp, start, self.index);
                if (self.match('=')) return token(.amp_eq, start, self.index);
                return token(.amp, start, self.index);
            },
            '|' => {
                if (self.match('|')) return token(.pipe_pipe, start, self.index);
                if (self.match('=')) return token(.pipe_eq, start, self.index);
                return token(.pipe, start, self.index);
            },
            '^' => {
                if (self.match('=')) return token(.caret_eq, start, self.index);
                return token(.caret, start, self.index);
            },
            '~' => return token(.tilde, start, self.index),
            '$' => return token(.dollar, start, self.index),
            '=' => {
                if (self.match('>')) return token(.fat_arrow, start, self.index);
                if (self.match('=')) return token(.eq_eq, start, self.index);
                return token(.eq, start, self.index);
            },
            '!' => {
                if (self.match('!')) return token(.bang_bang, start, self.index);
                if (self.match('=')) return token(.bang_eq, start, self.index);
                return token(.bang, start, self.index);
            },
            '<' => {
                if (self.match('<')) {
                    if (self.match('=')) return token(.lt_lt_eq, start, self.index);
                    return token(.lt_lt, start, self.index);
                }
                if (self.match('=')) return token(.lt_eq, start, self.index);
                return token(.lt, start, self.index);
            },
            '>' => {
                if (self.match('>')) {
                    if (self.match('=')) return token(.gt_gt_eq, start, self.index);
                    return token(.gt_gt, start, self.index);
                }
                if (self.match('=')) return token(.gt_eq, start, self.index);
                return token(.gt, start, self.index);
            },
            '"' => return self.string(start),
            else => {
                if (isIdentStart(ch)) return self.ident(start);
                if (std.ascii.isDigit(ch)) return self.number(start);
                return token(.invalid, start, self.index);
            },
        }
    }

    pub fn all(self: *Lexer, allocator: std.mem.Allocator) ![]Token {
        var tokens: std.ArrayList(Token) = .empty;
        errdefer tokens.deinit(allocator);

        while (true) {
            const tok = self.next();
            try tokens.append(allocator, tok);
            if (tok.kind == .eof) break;
        }

        return tokens.toOwnedSlice(allocator);
    }

    fn skipTrivia(self: *Lexer) void {
        while (self.index < self.source.len) {
            const ch = self.source[self.index];
            if (std.ascii.isWhitespace(ch)) {
                self.index += 1;
                continue;
            }
            if (ch == '/' and self.index + 1 < self.source.len and self.source[self.index + 1] == '/') {
                self.index += 2;
                while (self.index < self.source.len and self.source[self.index] != '\n') self.index += 1;
                continue;
            }
            break;
        }
    }

    fn advance(self: *Lexer) u8 {
        const ch = self.source[self.index];
        self.index += 1;
        return ch;
    }

    fn match(self: *Lexer, expected: u8) bool {
        if (self.index >= self.source.len or self.source[self.index] != expected) return false;
        self.index += 1;
        return true;
    }

    fn ident(self: *Lexer, start: usize) Token {
        while (self.index < self.source.len and isIdentContinue(self.source[self.index])) {
            self.index += 1;
        }

        const text_bytes = self.source[start..self.index];
        const kind = keywordKind(text_bytes);
        return token(kind, start, self.index);
    }

    fn number(self: *Lexer, start: usize) Token {
        if (self.source[start] == '0' and self.index < self.source.len and (self.source[self.index] == 'x' or self.source[self.index] == 'X')) {
            self.index += 1;
            while (self.index < self.source.len and (std.ascii.isHex(self.source[self.index]) or self.source[self.index] == '_')) {
                self.index += 1;
            }
        } else {
            while (self.index < self.source.len and (std.ascii.isDigit(self.source[self.index]) or self.source[self.index] == '_')) {
                self.index += 1;
            }
        }

        while (self.index < self.source.len and isIdentContinue(self.source[self.index])) {
            self.index += 1;
        }

        return token(.int_lit, start, self.index);
    }

    fn string(self: *Lexer, start: usize) Token {
        while (self.index < self.source.len) {
            const ch = self.advance();
            if (ch == '\\' and self.index < self.source.len) {
                self.index += 1;
                continue;
            }
            if (ch == '"') return token(.string_lit, start, self.index);
        }

        return token(.invalid, start, self.index);
    }
};

fn token(kind: TokenKind, start: usize, end: usize) Token {
    return .{
        .kind = kind,
        .start = @intCast(start),
        .len = @intCast(end - start),
    };
}

fn isIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentContinue(ch: u8) bool {
    return isIdentStart(ch) or std.ascii.isDigit(ch);
}
