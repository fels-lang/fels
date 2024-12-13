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

    // Operators
    plus, // +
    plus_eq, // +=
    minus, // -
    star, // *
    amp, // &
    eq, // =
    eq_eq, // ==
    bang, // !
    bang_eq, // !=
    lt, // <
    lt_eq, // <=
    gt, // >
    gt_eq, // >=
    amp_amp, // &&

    // Keywords
    keyword_fn,
    keyword_struct,
    keyword_distinct,
    keyword_opaque,
    keyword_atomic,
    keyword_const,
    keyword_volatile,
    keyword_if,
    keyword_while,
    keyword_return,
    keyword_unsafe,
    keyword_null,
    keyword_true,
    keyword_false,

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
};

pub fn keywordKind(text: []const u8) TokenKind {
    const prefix = "keyword_";

    inline for (@typeInfo(TokenKind).@"enum".fields) |field| {
        if (std.mem.startsWith(u8, field.name, prefix)) {
            const keyword_text = field.name[prefix.len..];

            if (std.mem.eql(u8, text, keyword_text)) {
                return @field(TokenKind, field.name);
            }
        }
    }

    return .ident;
}
