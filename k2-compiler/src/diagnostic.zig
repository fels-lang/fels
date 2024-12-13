const std = @import("std");
const Span = @import("lexer/span.zig").Span;

pub const DiagKind = enum {
    err,
    warning,
    note,

    pub fn label(self: DiagKind) []const u8 {
        return switch (self) {
            .err     => "error",
            .warning => "warning",
            .note    => "note",
        };
    }
};

pub const Diagnostic = struct {
    kind:    DiagKind,
    message: []const u8,
    span:    Span,
    file:    []const u8,

    pub fn err(message: []const u8, span: Span, file: []const u8) Diagnostic {
        return .{ .kind = .err, .message = message, .span = span, .file = file };
    }

    pub fn warn(message: []const u8, span: Span, file: []const u8) Diagnostic {
        return .{ .kind = .warning, .message = message, .span = span, .file = file };
    }

    pub fn note(message: []const u8, span: Span, file: []const u8) Diagnostic {
        return .{ .kind = .note, .message = message, .span = span, .file = file };
    }

    /// Backward-compatible constructor used by the parser (no file, defaults to error).
    pub fn init(message: []const u8, span: Span) Diagnostic {
        return .{ .kind = .err, .message = message, .span = span, .file = "" };
    }
};

pub fn renderDiagnostic(
    allocator: std.mem.Allocator,
    path:       []const u8,
    source:     []const u8,
    diagnostic: Diagnostic,
) ![]u8 {
    const location   = diagnostic.span.line_col(source);
    const source_line = getLine(source, location.line) orelse "";
    const caret_col   = location.col -| 1;
    const raw_width   = diagnostic.span.end -| diagnostic.span.start;
    const span_width  = @max(raw_width, 1);
    const remaining   = if (caret_col < source_line.len) source_line.len - caret_col else 0;
    const caret_width = @min(span_width, @max(remaining, 1));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // file:line:col: kind: message
    try out.print(allocator,
        "{s}:{d}:{d}: {s}: {s}\n    {s}\n    ",
        .{ path, location.line, location.col,
           diagnostic.kind.label(), diagnostic.message,
           source_line });
    try out.appendNTimes(allocator, ' ', caret_col);
    try out.appendNTimes(allocator, '^', caret_width);

    return out.toOwnedSlice(allocator);
}

pub fn renderAll(
    allocator:   std.mem.Allocator,
    diagnostics: []const Diagnostic,
    source_map:  *const std.StringHashMap([]const u8),
    writer:      anytype,
) !void {
    for (diagnostics) |d| {
        const src = source_map.get(d.file) orelse "";
        const rendered = try renderDiagnostic(allocator, d.file, src, d);
        defer allocator.free(rendered);
        try writer.print("{s}\n", .{rendered});
    }
}

fn getLine(source: []const u8, line_number: usize) ?[]const u8 {
    if (line_number == 0) return null;
    var current: usize = 1;
    var start:   usize = 0;
    for (source, 0..) |ch, index| {
        if (ch == '\n') {
            if (current == line_number) return trimCR(source[start..index]);
            current += 1;
            start = index + 1;
        }
    }
    if (current == line_number) return trimCR(source[start..]);
    return null;
}

fn trimCR(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}
