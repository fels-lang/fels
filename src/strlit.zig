//! String literals: the bytes a literal in the source stands for.

const std = @import("std");

/// The bytes a string literal stands for: the quotes removed and the escapes
/// (\n \r \t \\ \" \' \0 \xHH \u{H…}) resolved. The IR keeps these bytes in `Imm.text`, so the comptime
/// VM, static data and the LLVM backend see the same string.
pub fn bytes(allocator: std.mem.Allocator, literal: []const u8) []const u8 {
    const text = trimQuotes(literal);
    if (std.mem.indexOfScalar(u8, text, '\\') == null) return text;
    return unescape(allocator, text) catch text;
}

pub fn unescape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(allocator, s.len);
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            try out.append(allocator, s[i]);
            continue;
        }
        i += 1;
        switch (s[i]) {
            'n' => try out.append(allocator, '\n'),
            'r' => try out.append(allocator, '\r'),
            't' => try out.append(allocator, '\t'),
            '\\' => try out.append(allocator, '\\'),
            '"' => try out.append(allocator, '"'),
            '0' => try out.append(allocator, 0),
            '\'' => try out.append(allocator, '\''),
            'x' => {
                const byte = if (i + 2 < s.len) std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch null else null;
                if (byte) |b| {
                    try out.append(allocator, b);
                    i += 2;
                } else {
                    try out.appendSlice(allocator, "\\x");
                }
            },
            'u' => {
                if (unicodeEscape(s[i + 1 ..])) |u| {
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(u.rune, &buf) catch unreachable;
                    try out.appendSlice(allocator, buf[0..n]);
                    i += u.len;
                } else {
                    try out.appendSlice(allocator, "\\u");
                }
            },
            else => {
                try out.append(allocator, '\\');
                try out.append(allocator, s[i]);
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

/// A `\u{…}` escape's code point, and how many bytes the `{…}` after the `u` takes: 1 to 6 hex
/// digits naming a code point up to U+10FFFF that is no surrogate. Null when `s` starts no such
/// braces.
pub fn unicodeEscape(s: []const u8) ?struct { rune: u21, len: usize } {
    if (s.len < 3 or s[0] != '{') return null;
    const close = std.mem.indexOfScalar(u8, s, '}') orelse return null;
    const digits = s[1..close];
    if (digits.len == 0 or digits.len > 6) return null;
    const value = std.fmt.parseInt(u32, digits, 16) catch return null;
    if (value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF)) return null;
    return .{ .rune = @intCast(value), .len = close + 1 };
}

fn trimQuotes(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') return text[1 .. text.len - 1];
    return text;
}

test "a literal's escapes are resolved" {
    const a = std.testing.allocator;
    const got = bytes(a, "\"a\\nb\\\"c\\x41\"");
    defer a.free(got); // it has escapes, so it is a new allocation
    try std.testing.expectEqualStrings("a\nb\"cA", got);
    try std.testing.expectEqualStrings("plain", bytes(a, "\"plain\""));
}

test "a \\u{…} escape is the UTF-8 of its code point" {
    const a = std.testing.allocator;
    const got = bytes(a, "\"\\u{e9}\\u{20AC}\\u{1f600}!\"");
    defer a.free(got);
    try std.testing.expectEqualStrings("\u{e9}\u{20ac}\u{1f600}!", got);
}
