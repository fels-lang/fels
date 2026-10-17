const std = @import("std");
const Span = @import("lexer/span.zig").Span;
const style = @import("style.zig");
const Palette = style.Palette;

pub const DiagKind = enum {
    err,
    warning,
    note,
    /// Internal compiler error — represents a compiler bug, not a user error.
    ice,

    pub fn label(self: DiagKind) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
            .note => "note",
            .ice => "internal compiler error",
        };
    }
};

/// Zig source location captured at the ICE site via @src().
pub const CompilerSrc = struct {
    file: []const u8,
    line: u32,
    fn_name: []const u8,
};

/// A secondary span on a diagnostic: an underline somewhere else that explains the
/// primary error ("declared here", "expected because of this") or a step in a
/// trace. Same-file labels render as their own snippet; cross-file ones degrade to
/// a note.
pub const Label = struct {
    span: Span,
    file: []const u8 = "",
    message: []const u8,
    /// Drives the underline color — `.note` (cyan) for context, `.err` to mark a
    /// second offending site.
    style: DiagKind = .note,
};

pub const Diagnostic = struct {
    kind: DiagKind,
    message: []const u8,
    span: Span,
    file: []const u8,
    compiler_src: ?CompilerSrc = null,
    /// Optional short code shown as `error[CODE]:` and looked up by `fels explain`.
    code: ?[]const u8 = null,
    /// Text printed right after the primary underline (e.g. "found `bool`").
    primary_label: ?[]const u8 = null,
    /// Secondary underlines / trace frames.
    labels: []const Label = &.{},
    /// `= note:` lines — extra context.
    notes: []const []const u8 = &.{},
    /// `= help:` lines — how to fix it.
    helps: []const []const u8 = &.{},

    pub fn err(message: []const u8, span: Span, file: []const u8) Diagnostic {
        return .{ .kind = .err, .message = message, .span = span, .file = file };
    }

    /// Whether any of `diags` is an error: a warning is printed, but does not stop a build.
    pub fn anyError(diags: []const Diagnostic) bool {
        for (diags) |d| if (d.kind == .err) return true;
        return false;
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

/// Print an internal compiler error (ICE) to stderr.
/// Call as: printIce("what failed", @src())
pub fn printIce(message: []const u8, comptime src: std.builtin.SourceLocation) void {
    std.debug.print(
        "fels: internal compiler error: {s}\n    [at {s}:{d} in {s}]\n",
        .{ message, src.file, src.line, src.fn_name },
    );
}

/// Print a user-facing error tied to a Fels source location (not an ICE — this is
/// for genuine user errors discovered during lowering, e.g. a `#run` expression
/// the comptime VM cannot evaluate).
/// The text of every file the current compile loaded, filled by the pipeline. A message about
/// an imported file is located in that file's text; with only the main file's text it showed
/// at 1:1 with an empty line.
var file_sources: std.StringHashMapUnmanaged([]const u8) = .{};

/// Note the text of a file the compile loaded (it must live as long as the compile).
pub fn rememberSource(file: []const u8, source: []const u8) void {
    file_sources.put(std.heap.page_allocator, file, source) catch {};
}

/// A new compile starts: forget the files of the last one.
pub fn forgetSources() void {
    file_sources.clearRetainingCapacity();
}

/// The text of `file` as the compile loaded it, else `fallback`.
pub fn sourceOf(file: []const u8, fallback: []const u8) []const u8 {
    return file_sources.get(file) orelse fallback;
}

pub fn printErrorAt(
    message: []const u8,
    fels_file: []const u8,
    fels_source: []const u8,
    span: Span,
) void {
    const location = span.line_col(sourceOf(fels_file, fels_source));
    std.debug.print(
        "{s}:{d}:{d}: error: {s}\n",
        .{ fels_file, location.line, location.col, message },
    );
}

/// Print an ICE with an associated Fels source location.
pub fn printIceAt(
    message: []const u8,
    fels_file: []const u8,
    fels_source: []const u8,
    span: Span,
    comptime src: std.builtin.SourceLocation,
) void {
    const location = span.line_col(fels_source);
    std.debug.print(
        "{s}:{d}:{d}: internal compiler error: {s}\n    [at {s}:{d} in {s}]\n",
        .{ fels_file, location.line, location.col, message, src.file, src.line, src.fn_name },
    );
}

fn severityColor(pal: Palette, kind: DiagKind) []const u8 {
    return switch (kind) {
        .err, .ice => pal.red(),
        .warning => pal.yellow(),
        .note => pal.cyan(),
    };
}

fn digits(n: usize) usize {
    var d: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

/// One gutter cell: `{blue} N │{reset}` (with the line number) or `{blue}   │{reset}`
/// (a blank continuation), `width` = the line-number column width.
fn gutter(out: *std.ArrayList(u8), alloc: std.mem.Allocator, pal: Palette, width: usize, line: ?usize) !void {
    try out.print(alloc, "{s}", .{pal.blue()});
    if (line) |ln| {
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{ln}) catch "?";
        if (width > s.len) try out.appendNTimes(alloc, ' ', width - s.len);
        try out.appendSlice(alloc, s);
    } else {
        try out.appendNTimes(alloc, ' ', width);
    }
    try out.print(alloc, " \u{2502}{s}", .{pal.reset()});
}

/// A source snippet: a blank gutter line, the offending source line, then an
/// underline of `span` colored by `color`, trailed by `label`.
fn emitSnippet(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    pal: Palette,
    source: []const u8,
    span: Span,
    color: []const u8,
    text: []const u8,
    width: usize,
) !void {
    const loc = span.line_col(source);
    const source_line = getLine(source, loc.line) orelse "";
    const caret_col = loc.col -| 1;
    const raw_width = span.end -| span.start;
    const span_width = @max(raw_width, 1);
    const remaining = if (caret_col < source_line.len) source_line.len - caret_col else 0;
    const caret_width = @min(span_width, @max(remaining, 1));

    try gutter(out, alloc, pal, width, null);
    try out.append(alloc, '\n');
    try gutter(out, alloc, pal, width, loc.line);
    try out.print(alloc, " {s}\n", .{source_line});
    try gutter(out, alloc, pal, width, null);
    try out.append(alloc, ' ');
    try out.appendNTimes(alloc, ' ', caret_col);
    try out.print(alloc, "{s}", .{color});
    try out.appendNTimes(alloc, '^', caret_width);
    if (text.len > 0) try out.print(alloc, " {s}", .{text});
    try out.print(alloc, "{s}\n", .{pal.reset()});
}

/// Render one diagnostic with the given palette (`Palette.plain` for no color).
pub fn render(
    allocator: std.mem.Allocator,
    path: []const u8,
    given_source: []const u8,
    diagnostic: Diagnostic,
    pal: Palette,
) ![]u8 {
    const source = sourceOf(path, given_source);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (diagnostic.kind == .ice) {
        if (diagnostic.file.len > 0 and (diagnostic.span.start != 0 or diagnostic.span.end != 0)) {
            const location = diagnostic.span.line_col(source);
            try out.print(allocator, "{s}:{d}:{d}: ", .{ path, location.line, location.col });
        }
        try out.print(allocator, "{s}internal compiler error{s}: {s}\n", .{ pal.red(), pal.reset(), diagnostic.message });
        if (diagnostic.compiler_src) |cs| {
            try out.print(allocator, "    [at {s}:{d} in {s}]\n", .{ cs.file, cs.line, cs.fn_name });
        }
        return out.toOwnedSlice(allocator);
    }

    const sev = severityColor(pal, diagnostic.kind);

    // header: `error[CODE]: message`
    try out.print(allocator, "{s}{s}", .{ sev, diagnostic.kind.label() });
    if (diagnostic.code) |code| try out.print(allocator, "[{s}]", .{code});
    try out.print(allocator, "{s}: {s}{s}{s}\n", .{ pal.reset(), pal.bold(), diagnostic.message, pal.reset() });

    // location: `  --> file:line:col`
    const location = diagnostic.span.line_col(source);
    try out.print(allocator, "{s}  -->{s} {s}:{d}:{d}\n", .{ pal.blue(), pal.reset(), path, location.line, location.col });

    // primary snippet
    try emitSnippet(&out, allocator, pal, source, diagnostic.span, sev, diagnostic.primary_label orelse "", digits(location.line));

    // secondary labels / trace frames
    for (diagnostic.labels) |lab| {
        const same_file = lab.file.len == 0 or std.mem.eql(u8, lab.file, path);
        if (same_file) {
            const lloc = lab.span.line_col(source);
            try emitSnippet(&out, allocator, pal, source, lab.span, severityColor(pal, lab.style), lab.message, digits(lloc.line));
        } else {
            try out.print(allocator, "  {s}={s} {s}note{s}: {s} (in {s})\n", .{ pal.blue(), pal.reset(), pal.cyan(), pal.reset(), lab.message, lab.file });
        }
    }

    // notes, then helps
    for (diagnostic.notes) |n| {
        try out.print(allocator, "  {s}={s} {s}note{s}: {s}\n", .{ pal.blue(), pal.reset(), pal.cyan(), pal.reset(), n });
    }
    for (diagnostic.helps) |h| {
        try out.print(allocator, "  {s}={s} {s}help{s}: {s}\n", .{ pal.blue(), pal.reset(), pal.green(), pal.reset(), h });
    }

    return out.toOwnedSlice(allocator);
}

/// Plain (no-color) render — the stable signature the tests and LSP use.
pub fn renderDiagnostic(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    diagnostic: Diagnostic,
) ![]u8 {
    return render(allocator, path, source, diagnostic, Palette.plain);
}

pub fn renderAll(
    allocator: std.mem.Allocator,
    diagnostics: []const Diagnostic,
    source_map: *const std.StringHashMap([]const u8),
    writer: anytype,
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
    var start: usize = 0;
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

test "a message about another file is located in that file's text" {
    const util = "// helper\n\npub broken :: fn() -> i32 {\n    return \"text\";\n}\n";
    rememberSource("util.fels", util);
    defer forgetSources();
    const at = std.mem.indexOf(u8, util, "return").?;
    const d = Diagnostic.err("return type mismatch", .{ .start = at, .end = at + 6 }, "util.fels");
    // The caller only has the main file's text, as the compiler's message loop does.
    const out = try renderDiagnostic(std.testing.allocator, "util.fels", "", d);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "util.fels:4:5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "return \"text\";") != null);
}
