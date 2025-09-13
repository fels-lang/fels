//! String literals: the bytes a literal in the source stands for.

const std = @import("std");

/// The bytes a string literal stands for: the quotes removed and the escapes
/// (\n \r \t \\ \" \0 \xHH) resolved. The IR keeps these bytes in `Imm.text`, so the comptime
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
            'x' => {
                const byte = if (i + 2 < s.len) std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch null else null;
                if (byte) |b| {
                    try out.append(allocator, b);
                    i += 2;
                } else {
                    try out.appendSlice(allocator, "\\x");
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
