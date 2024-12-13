const std = @import("std");
const Span = @import("lexer/span.zig").Span;

pub const Diagnostic = struct {
    message: []const u8,
    span: Span,

    pub fn init(message: []const u8, span: Span) Diagnostic {
        return .{
            .message = message,
            .span = span,
        };
    }
};

pub fn renderDiagnostic(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    diagnostic: Diagnostic,
) ![]u8 {
    const location = diagnostic.span.line_col(source);
    const source_line = getLine(source, location.line) orelse "";
    const caret_column = location.col -| 1;
    const raw_width = diagnostic.span.end -| diagnostic.span.start;
    const span_width = @max(raw_width, 1);
    const remaining = if (caret_column < source_line.len) source_line.len - caret_column else 0;
    const caret_width = @min(span_width, @max(remaining, 1));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.print(
        allocator,
        "{s}:{d}:{d}: {s}\n    {s}\n    ",
        .{ path, location.line, location.col, diagnostic.message, source_line },
    );
    try out.appendNTimes(allocator, ' ', caret_column);
    try out.appendNTimes(allocator, '^', caret_width);

    return out.toOwnedSlice(allocator);
}

fn getLine(source: []const u8, line_number: usize) ?[]const u8 {
    if (line_number == 0) return null;

    var current: usize = 1;
    var start: usize = 0;

    for (source, 0..) |ch, index| {
        if (ch == '\n') {
            if (current == line_number) {
                return trimCarriageReturn(source[start..index]);
            }

            current += 1;
            start = index + 1;
        }
    }

    if (current == line_number) {
        return trimCarriageReturn(source[start..]);
    }

    return null;
}

fn trimCarriageReturn(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }

    return line;
}
