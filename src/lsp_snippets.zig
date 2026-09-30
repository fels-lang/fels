//! What the language server writes beyond names and types: the comment above a declaration as
//! its documentation (hover, completion, signature help), a call as a snippet with a tab stop
//! per argument, and snippets for the usual statements and declarations.

const std = @import("std");
const ast = @import("ast.zig");

/// The comment right above the declaration at `start` in `source`, as its documentation: the
/// `//` lines with no blank line between them and the declaration (attribute lines such as
/// `#inline` may stand between), each without its `//` and one space. A decoration of `─` at a
/// line's end goes too. Without one, a comment after the declaration on its own line
/// (`x: i32, // the width`). Null when there is none.
pub fn docComment(a: std.mem.Allocator, source: []const u8, start: usize) ?[]const u8 {
    if (start > source.len) return null;
    var line_start = start;
    while (line_start > 0 and source[line_start - 1] != '\n') line_start -= 1;

    var lines = std.ArrayList([]const u8).empty;
    var cursor = line_start;
    while (cursor > 0 and lines.items.len < max_lines) {
        const prev_end = cursor - 1; // its '\n'
        var prev_start = prev_end;
        while (prev_start > 0 and source[prev_start - 1] != '\n') prev_start -= 1;
        const line = std.mem.trim(u8, source[prev_start..prev_end], " \t\r");
        if (std.mem.startsWith(u8, line, "//")) {
            lines.append(a, line) catch return null;
        } else if (lines.items.len == 0 and isAttributeLine(line)) {
            // `#spawns` between the comment and the declaration
        } else break;
        cursor = prev_start;
    }
    if (lines.items.len == 0) return trailingComment(a, source, start);

    var out = std.ArrayList(u8).empty;
    var i = lines.items.len;
    while (i > 0) {
        i -= 1;
        appendCommentText(a, &out, lines.items[i]);
        if (i > 0) out.append(a, '\n') catch return null;
    }
    const text = std.mem.trim(u8, out.items, " \n");
    return if (text.len == 0) null else text;
}

/// More lines than this above a declaration are a section's comment more than its own.
const max_lines = 60;

fn isAttributeLine(line: []const u8) bool {
    return line.len > 1 and line[0] == '#' and !std.mem.startsWith(u8, line, "#import");
}

/// The `// …` after the declaration at `start` on its line, outside a string.
fn trailingComment(a: std.mem.Allocator, source: []const u8, start: usize) ?[]const u8 {
    var in_string = false;
    var i = start;
    while (i + 1 < source.len and source[i] != '\n') : (i += 1) {
        const c = source[i];
        if (c == '"' and (i == 0 or source[i - 1] != '\\')) in_string = !in_string;
        if (!in_string and c == '/' and source[i + 1] == '/') {
            var end = i;
            while (end < source.len and source[end] != '\n') end += 1;
            var out = std.ArrayList(u8).empty;
            appendCommentText(a, &out, std.mem.trim(u8, source[i..end], " \t\r"));
            const text = std.mem.trim(u8, out.items, " ");
            return if (text.len == 0) null else text;
        }
    }
    return null;
}

/// A comment line's text: without `//` (or `///`), one space after it, and a trailing `─` rule.
fn appendCommentText(a: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8) void {
    var text = line;
    if (std.mem.startsWith(u8, text, "///")) text = text[3..] else if (std.mem.startsWith(u8, text, "//")) text = text[2..];
    if (std.mem.startsWith(u8, text, " ")) text = text[1..];
    while (true) {
        const trimmed = std.mem.trimEnd(u8, text, " \t\r");
        if (std.mem.endsWith(u8, trimmed, "─")) {
            text = trimmed[0 .. trimmed.len - "─".len];
        } else {
            text = trimmed;
            break;
        }
    }
    out.appendSlice(a, text) catch {};
}

/// The arguments a call of `decl` is written with: its value parameters, but the receiver when
/// it is called as a method (`drop_self`), and before them each `$T` type parameter that no
/// value parameter's type names, which a call has to give (`alloc(T, a, n)`); a type parameter
/// that one names is inferred.
pub fn callArgs(a: std.mem.Allocator, decl: ast.FunctionDecl, drop_self: bool) []const []const u8 {
    var names = std.ArrayList([]const u8).empty;
    var receiver_done = !drop_self;
    for (decl.params) |p| {
        if (p.is_type_param) {
            if (!typeParamInferred(decl, p.name)) names.append(a, p.name) catch {};
            continue;
        }
        if (!receiver_done) {
            receiver_done = true;
            continue;
        }
        names.append(a, p.name) catch {};
    }
    return names.items;
}

/// Whether the type of a value parameter of `decl` names the type parameter `name`.
fn typeParamInferred(decl: ast.FunctionDecl, name: []const u8) bool {
    for (decl.params) |p| {
        if (p.is_type_param) continue;
        const end = @min(p.span.end, decl.source.len);
        const start = @min(p.span.start, end);
        if (containsWord(decl.source[start..end], name)) return true;
    }
    return false;
}

fn containsWord(text: []const u8, word: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, word)) |at| : (i = at + 1) {
        const before_ok = at == 0 or !isIdentChar(text[at - 1]);
        const after = at + word.len;
        const after_ok = after >= text.len or !isIdentChar(text[after]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// `name(${1:a}, ${2:b})$0`: a call with a tab stop at each argument, named after its parameter,
/// and the cursor after the `)` at the end. A variadic C function ends with the cursor in the
/// parentheses, where more arguments go.
pub fn callSnippet(a: std.mem.Allocator, name: []const u8, args: []const []const u8, variadic: bool) []const u8 {
    var out = std.ArrayList(u8).empty;
    appendSnippetText(a, &out, name);
    out.append(a, '(') catch {};
    for (args, 1..) |arg, n| {
        if (n > 1) out.appendSlice(a, ", ") catch {};
        out.print(a, "${{{d}:", .{n}) catch {};
        appendSnippetText(a, &out, arg);
        out.append(a, '}') catch {};
    }
    if (variadic) {
        out.appendSlice(a, "$0)") catch {};
    } else {
        out.appendSlice(a, ")$0") catch {};
    }
    return out.items;
}

/// Text in a snippet, where `$`, `}` and `\` mean something.
fn appendSnippetText(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) void {
    for (text) |c| {
        if (c == '$' or c == '}' or c == '\\') out.append(a, '\\') catch {};
        out.append(a, c) catch {};
    }
}

/// Whether a `(` follows the name at `end` (spaces between): completing a name in a call that is
/// written already gives the name alone.
pub fn parenFollows(text: []const u8, end: usize) bool {
    var i = end;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return i < text.len and text[i] == '(';
}

/// A snippet for a statement or declaration, offered among the keywords. `filter` is what is
/// typed to find it; lines are indented with four spaces, below the line the snippet starts on.
pub const Snippet = struct {
    label: []const u8,
    filter: []const u8,
    detail: []const u8,
    body: []const u8,
};

pub const statement_snippets = [_]Snippet{
    .{ .label = "for … in", .filter = "for", .detail = "loop over a slice, an array or a collection", .body = "for ${1:x} in ${2:items} {\n    $0\n}" },
    .{ .label = "for … in a..b", .filter = "for", .detail = "loop over a range", .body = "for ${1:i} in ${2:0}..${3:n} {\n    $0\n}" },
    .{ .label = "if", .filter = "if", .detail = "if", .body = "if ${1:condition} {\n    $0\n}" },
    .{ .label = "if … else", .filter = "if", .detail = "if and else", .body = "if ${1:condition} {\n    $2\n} else {\n    $0\n}" },
    .{ .label = "if … |x|", .filter = "if", .detail = "unwrap an optional", .body = "if ${1:optional} |${2:x}| {\n    $0\n}" },
    .{ .label = "while", .filter = "while", .detail = "while", .body = "while ${1:condition} {\n    $0\n}" },
    .{ .label = "match", .filter = "match", .detail = "match on a value", .body = "match ${1:value} {\n    ${2:.variant} => {\n        $0\n    },\n    else => {},\n}" },
    .{ .label = "defer", .filter = "defer", .detail = "run at the end of the block", .body = "defer ${1:a.deinit()};" },
    .{ .label = "zone … Arena", .filter = "zone", .detail = "memory that ends with the block", .body = "zone ${1:a}: Arena {\n    $0\n}" },
    .{ .label = "zone … thread::Scope", .filter = "zone", .detail = "threads that end with the block", .body = "zone ${1:s}: thread::Scope {\n    ${1:s}.spawn(fn() {\n        $0\n    });\n}" },
    .{ .label = "fn", .filter = "fn", .detail = "a function", .body = "${1:name} :: fn(${2}) -> ${3:void} {\n    $0\n}" },
    .{ .label = "struct", .filter = "struct", .detail = "a struct", .body = "${1:Name} :: struct {\n    ${2:field}: ${3:i32},$0\n}" },
    .{ .label = "enum", .filter = "enum", .detail = "an enum", .body = "${1:Name} :: enum {\n    ${2:first},\n    ${3:second},$0\n}" },
    .{ .label = "#test", .filter = "test", .detail = "a test function", .body = "#test\n${1:name} :: fn(t: *Test) {\n    $0\n}" },
    .{ .label = "main", .filter = "main", .detail = "the program's entry", .body = "main :: fn() -> i32 {\n    $0\n    return 0;\n}" },
    .{ .label = "#import", .filter = "import", .detail = "import a module", .body = "#import std.${1:io} as ${2:io};" },
};

test "a declaration's comment, attributes between, a rule at the end" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const src =
        \\x :: 1;
        \\
        \\// Scope: threads ──────
        \\//
        \\// Joins them.
        \\#spawns
        \\pub spawn :: fn() {}
        \\P :: struct {
        \\    w: i32, // the width
        \\}
    ;
    const at = std.mem.indexOf(u8, src, "pub spawn").?;
    try std.testing.expectEqualStrings("Scope: threads\n\nJoins them.", docComment(arena.allocator(), src, at).?);
    try std.testing.expect(docComment(arena.allocator(), src, 0) == null);
    const w = std.mem.indexOf(u8, src, "w: i32").?;
    try std.testing.expectEqualStrings("the width", docComment(arena.allocator(), src, w).?);
}

test "a call snippet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("add(${1:a}, ${2:b})$0", callSnippet(a, "add", &.{ "a", "b" }, false));
    try std.testing.expectEqualStrings("go()$0", callSnippet(a, "go", &.{}, false));
    try std.testing.expectEqualStrings("printf(${1:fmt}$0)", callSnippet(a, "printf", &.{"fmt"}, true));
    try std.testing.expect(parenFollows("add (1)", 3));
    try std.testing.expect(!parenFollows("add;", 3));
}
