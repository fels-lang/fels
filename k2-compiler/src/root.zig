const std = @import("std");
const span = @import("lexer/span.zig");
const tokens = @import("lexer/tokens.zig");

pub const Span = span.Span;
pub const TokenKind = tokens.TokenKind;
pub const Token = tokens.Token;
pub const keywordKind = tokens.keywordKind;

test {
    refAllDeclsRecursive(@This());
}

fn refAllDeclsRecursive(comptime T: type) void {
    std.testing.refAllDecls(T);

    inline for (comptime std.meta.declarations(T)) |decl| {
        const value = @field(T, decl.name);
        if (@TypeOf(value) == type) {
            refAllDeclsRecursive(value);
        }
    }
}
