//! Reading a file of `#` directives (gabbro.pkg, gabbro.lock) with the Gabbro lexer: each
//! directive is `#name` followed by words and string literals, ended by `;`.

const std = @import("std");
const tokens = @import("../lexer/tokens.zig");
const strlit = @import("../strlit.zig");

pub const Token = tokens.Token;

/// What went wrong, and where: a byte offset into the source.
pub const Problem = struct {
    at: u32 = 0,
    msg: []const u8 = "",
};

pub const Error = error{ Invalid, OutOfMemory };

/// Line and column (both from 1) of a byte offset.
pub fn location(source: []const u8, at: u32) struct { line: usize, col: usize } {
    var line: usize = 1;
    var col: usize = 1;
    for (source[0..@min(at, source.len)]) |c| {
        if (c == '\n') {
            line += 1;
            col = 1;
        } else col += 1;
    }
    return .{ .line = line, .col = col };
}

pub const Cursor = struct {
    arena: std.mem.Allocator,
    source: []const u8,
    lexer: tokens.Lexer,
    peeked: ?Token = null,
    problem: *Problem,

    pub fn init(arena: std.mem.Allocator, source: []const u8, problem: *Problem) Cursor {
        return .{ .arena = arena, .source = source, .lexer = tokens.Lexer.init(source), .problem = problem };
    }

    pub fn peek(self: *Cursor) Token {
        if (self.peeked == null) self.peeked = self.lexer.next();
        return self.peeked.?;
    }

    pub fn next(self: *Cursor) Token {
        const t = self.peek();
        self.peeked = null;
        return t;
    }

    pub fn text(self: *Cursor, t: Token) []const u8 {
        return t.text(self.source);
    }

    pub fn fail(self: *Cursor, t: Token, comptime fmt: []const u8, args: anytype) Error {
        self.problem.* = .{ .at = t.start, .msg = try std.fmt.allocPrint(self.arena, fmt, args) };
        return error.Invalid;
    }

    /// The next token is the word `w` (an identifier, or a keyword spelled so).
    pub fn isWord(self: *Cursor, w: []const u8) bool {
        const t = self.peek();
        return t.kind != .string_lit and t.kind != .eof and std.mem.eql(u8, self.text(t), w);
    }

    /// A name: an identifier.
    pub fn name(self: *Cursor, what: []const u8) Error![]const u8 {
        const t = self.next();
        if (t.kind != .ident) return self.fail(t, "expected {s}, found `{s}`", .{ what, self.text(t) });
        return self.text(t);
    }

    /// A string literal's bytes.
    pub fn string(self: *Cursor, what: []const u8) Error![]const u8 {
        const t = self.next();
        if (t.kind != .string_lit) return self.fail(t, "expected {s} in quotes, found `{s}`", .{ what, self.text(t) });
        return strlit.bytes(self.arena, self.text(t));
    }

    pub fn expect(self: *Cursor, kind: tokens.TokenKind, what: []const u8) Error!Token {
        const t = self.next();
        if (t.kind != kind) return self.fail(t, "expected {s}, found `{s}`", .{ what, self.text(t) });
        return t;
    }

    /// The `#name` of the next directive, or null at the end of the file.
    pub fn directive(self: *Cursor) Error!?Token {
        const t = self.next();
        if (t.kind == .eof) return null;
        if (t.kind != .hash) return self.fail(t, "expected a `#` directive, found `{s}`", .{self.text(t)});
        const n = self.next();
        if (n.kind == .eof or n.kind == .string_lit) return self.fail(n, "expected a directive name after `#`", .{});
        return n;
    }
};
