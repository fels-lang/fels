//! Help while typing for `fels lsp`: member completion after `.`, signature help, inlay
//! hints, hover on locals, parameters and fields, and the last good analysis.
//!
//! Code is broken most of the time while it is typed: `p.` alone does not parse. So a
//! document keeps the last analysis whose text parsed (`Doc.last_good`), and completion,
//! hover, signature help and inlay hints answer from it while the current text does not
//! parse. Diagnostics always come from the current text.
//!
//! Positions are mapped between the text that analysis read and the current text with a
//! line diff (`TextMap`): an unchanged line maps exactly, a line changed in place maps
//! around its own edit, and new or rewritten lines map to nothing. A lookup inside changed
//! text uses the place where the change starts instead (the scope there is the one the edit
//! started in), and an inlay hint is only given for a name on a line that maps.
//!
//! The expression in front of the cursor is read from the current text, not from a syntax
//! tree: `a.b(1)[i].` is scanned backwards (names, calls, indexes, `::`, `?`, `!!`) into a
//! chain, and the chain is resolved with the analysis: a local through the checker's
//! records (`TypeEnv.local_bindings`), a global through the symbol table, then field types,
//! method return types and element types along the chain. The same scan finds the call the
//! cursor is in for signature help. Comments and literals are blanked out first, so a
//! bracket in a string does not count.

const std = @import("std");
const sema = @import("sema.zig");
const ast = @import("ast.zig");
const pipeline = @import("pipeline.zig");
const lsp = @import("lsp.zig");
const lsp_snippets = @import("lsp_snippets.zig");
const Span = @import("lexer/span.zig").Span;

const json = std.json;
const Ty = sema.Ty;
const SymbolId = sema.SymbolId;

// The last good analysis

/// Called before a document is analyzed again: if its current analysis parsed, keep it as
/// the last good one (and take it out of `analysis`, so clearing does not free it).
pub fn keepLastGood(doc: *lsp.Doc) void {
    const cur = doc.analysis orelse return;
    if (cur.symbols == null or cur.types == null) return;
    if (doc.last_good) |*old| old.deinit();
    doc.last_good = cur;
    doc.analysis = null;
}

/// Called after the new analysis is in place: if it parsed, the kept one is not needed.
pub fn dropLastGood(doc: *lsp.Doc) void {
    const cur = doc.analysis orelse return;
    if (cur.symbols == null or cur.types == null) return;
    if (doc.last_good) |*old| old.deinit();
    doc.last_good = null;
}

/// The analysis that name completion uses: the current one if it parsed, else the last good one.
pub fn namesAnalysis(doc: *lsp.Doc) ?pipeline.Analysis {
    if (doc.analysis) |cur| if (cur.symbols != null) return cur;
    return doc.last_good;
}

// Text scanning

pub fn isIdentChar(c: u8) bool {
    return c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// How two texts differ: a common prefix, then one edited region, then a common suffix.
pub const Mapping = struct {
    /// Length of the common prefix: where the edit starts in both texts.
    prefix: usize,
    /// Where the edit ends in the old text and in the new text.
    old_end: usize,
    new_end: usize,

    pub fn identity(len: usize) Mapping {
        return .{ .prefix = len, .old_end = len, .new_end = len };
    }

    pub fn same(m: Mapping) bool {
        return m.prefix == m.old_end and m.prefix == m.new_end;
    }

    /// The old offset of a new offset, or null inside the edit.
    pub fn toOld(m: Mapping, off: usize) ?usize {
        if (off <= m.prefix) return off;
        if (off >= m.new_end) return off - m.new_end + m.old_end;
        return null;
    }

    /// The old offset of a new offset, or the start of the edit for a position inside it.
    pub fn anchor(m: Mapping, off: usize) usize {
        return m.toOld(off) orelse m.prefix;
    }

    /// The new place of the old range `[start, end)`, or null if the edit touches it.
    pub fn spanToNew(m: Mapping, start: usize, end: usize) ?[2]usize {
        if (end <= m.prefix) return .{ start, end };
        if (start >= m.old_end) return .{ start - m.old_end + m.new_end, end - m.old_end + m.new_end };
        return null;
    }
};

pub fn diffTexts(old: []const u8, new: []const u8) Mapping {
    const n = @min(old.len, new.len);
    var p: usize = 0;
    while (p < n and old[p] == new[p]) p += 1;
    var s: usize = 0;
    while (s < n - p and old[old.len - 1 - s] == new[new.len - 1 - s]) s += 1;
    return .{ .prefix = p, .old_end = old.len - s, .new_end = new.len - s };
}

/// Where each line went between two texts, so that several separate edits (a broken line at
/// the bottom, a new line at the top) still leave the lines between them mapped. Lines are
/// matched with a diff (Myers); a line that was changed in place (one old line replaced by
/// one new line) is mapped character by character around its own edit.
pub const TextMap = struct {
    old: []const u8,
    new: []const u8,
    identical: bool = false,
    /// The whole texts as one edited region: used when the line diff gives up.
    whole: Mapping,
    old_starts: []const usize = &.{},
    new_starts: []const usize = &.{},
    /// For each line, the matching line of the other text: `i >= 0` the same line,
    /// `-(i + 2)` a line changed in place, `-1` none.
    new_to_old: []const i32 = &.{},
    old_to_new: []const i32 = &.{},

    /// Edit distance (in lines) beyond which the line diff gives up.
    const max_edits = 200;

    pub fn build(a: std.mem.Allocator, old: []const u8, new: []const u8) TextMap {
        if (std.mem.eql(u8, old, new)) return .{ .old = old, .new = new, .identical = true, .whole = Mapping.identity(new.len) };
        var m = TextMap{ .old = old, .new = new, .whole = diffTexts(old, new) };
        m.matchLines(a) catch {
            m.old_starts = &.{};
            m.new_starts = &.{};
        };
        return m;
    }

    fn lineStarts(a: std.mem.Allocator, text: []const u8) ![]usize {
        var list = std.ArrayList(usize).empty;
        try list.append(a, 0);
        for (text, 0..) |c, i| if (c == '\n') try list.append(a, i + 1);
        try list.append(a, text.len + 1); // past the end: line `i` is `starts[i] .. starts[i + 1] - 1`
        return list.toOwnedSlice(a);
    }

    fn line(text: []const u8, starts: []const usize, i: usize) []const u8 {
        return text[starts[i]..@min(starts[i + 1] - 1, text.len)];
    }

    fn matchLines(m: *TextMap, a: std.mem.Allocator) !void {
        const os = try lineStarts(a, m.old);
        const ns = try lineStarts(a, m.new);
        const n = os.len - 1;
        const k = ns.len - 1;
        const o2n = try a.alloc(i32, n);
        const n2o = try a.alloc(i32, k);
        @memset(o2n, -1);
        @memset(n2o, -1);
        // Common lines at both ends, then a diff of the middle.
        var p: usize = 0;
        while (p < n and p < k and std.mem.eql(u8, line(m.old, os, p), line(m.new, ns, p))) p += 1;
        var s: usize = 0;
        while (s < n - p and s < k - p and std.mem.eql(u8, line(m.old, os, n - 1 - s), line(m.new, ns, k - 1 - s))) s += 1;
        for (0..p) |i| {
            o2n[i] = @intCast(i);
            n2o[i] = @intCast(i);
        }
        for (0..s) |t| {
            o2n[n - 1 - t] = @intCast(k - 1 - t);
            n2o[k - 1 - t] = @intCast(n - 1 - t);
        }
        try myersLines(a, m.old, os, p, n - s, m.new, ns, p, k - s, o2n, n2o);
        // A run of exactly one old and one new unmatched line between matched lines is a
        // line changed in place.
        var j: usize = 0;
        while (j < k) {
            if (n2o[j] != -1) {
                j += 1;
                continue;
            }
            var j_end = j;
            while (j_end < k and n2o[j_end] == -1) j_end += 1;
            const i_start: usize = if (j > 0) @as(usize, @intCast(n2o[j - 1])) + 1 else 0;
            const i_end: usize = if (j_end < k) @intCast(n2o[j_end]) else n;
            if (j_end - j == 1 and i_end > i_start and i_end - i_start == 1) {
                n2o[j] = -@as(i32, @intCast(i_start)) - 2;
                o2n[i_start] = -@as(i32, @intCast(j)) - 2;
            }
            j = j_end;
        }
        m.old_starts = os;
        m.new_starts = ns;
        m.old_to_new = o2n;
        m.new_to_old = n2o;
    }

    fn lineOf(starts: []const usize, off: usize) usize {
        var lo: usize = 0;
        var hi: usize = starts.len - 1; // the line count
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (starts[mid] <= off) lo = mid else hi = mid;
        }
        return lo;
    }

    fn lineMapping(m: TextMap, i: usize, j: usize) Mapping {
        return diffTexts(line(m.old, m.old_starts, i), line(m.new, m.new_starts, j));
    }

    /// The old offset of a new offset, or null where the text was changed.
    pub fn toOld(m: TextMap, off: usize) ?usize {
        if (m.identical) return off;
        if (m.new_starts.len == 0) return m.whole.toOld(off);
        const j = lineOf(m.new_starts, off);
        const col = off - m.new_starts[j];
        const e = m.new_to_old[j];
        if (e >= 0) return m.old_starts[@intCast(e)] + col;
        if (e <= -2) {
            const i: usize = @intCast(-e - 2);
            return m.old_starts[i] + (m.lineMapping(i, j).toOld(col) orelse return null);
        }
        return null;
    }

    /// The old offset of a new offset; inside changed text, the place in the old text where
    /// the change starts (for looking up the scope there).
    pub fn anchor(m: TextMap, off: usize) usize {
        if (m.toOld(off)) |o| return o;
        if (m.new_starts.len == 0) return m.whole.prefix;
        const j = lineOf(m.new_starts, off);
        const e = m.new_to_old[j];
        if (e <= -2) {
            const i: usize = @intCast(-e - 2);
            return m.old_starts[i] + m.lineMapping(i, j).prefix;
        }
        var b = j;
        while (b > 0) {
            b -= 1;
            const prev = m.new_to_old[b];
            if (prev >= 0) {
                const i: usize = @intCast(prev);
                return m.old_starts[i] + line(m.old, m.old_starts, i).len;
            }
        }
        return 0;
    }

    /// The new place of the old range `[start, end)` on one line, or null where it changed.
    pub fn spanToNew(m: TextMap, start: usize, end: usize) ?[2]usize {
        if (m.identical) return .{ start, end };
        if (m.new_starts.len == 0) return m.whole.spanToNew(start, end);
        const i = lineOf(m.old_starts, start);
        if (end > m.old_starts[i] + line(m.old, m.old_starts, i).len) return null;
        const cs = start - m.old_starts[i];
        const ce = end - m.old_starts[i];
        const e = m.old_to_new[i];
        if (e >= 0) {
            const base = m.new_starts[@intCast(e)];
            return .{ base + cs, base + ce };
        }
        if (e <= -2) {
            const j: usize = @intCast(-e - 2);
            const r = m.lineMapping(i, j).spanToNew(cs, ce) orelse return null;
            return .{ m.new_starts[j] + r[0], m.new_starts[j] + r[1] };
        }
        return null;
    }
};

/// Match the lines `old[o0..o1)` with `new[n0..n1)` (Myers' diff), filling both maps.
/// Leaves them unmatched if the texts differ in more than `TextMap.max_edits` lines.
fn myersLines(
    a: std.mem.Allocator,
    old: []const u8,
    os: []const usize,
    o0: usize,
    o1: usize,
    new: []const u8,
    ns: []const usize,
    n0: usize,
    n1: usize,
    o2n: []i32,
    n2o: []i32,
) !void {
    const n: isize = @intCast(o1 - o0);
    const m: isize = @intCast(n1 - n0);
    if (n == 0 or m == 0) return;
    const max: isize = @min(n + m, TextMap.max_edits);
    const width: usize = @intCast(2 * (n + m) + 3);
    const off: isize = n + m + 1;
    var v = try a.alloc(isize, width);
    @memset(v, 0);
    // Before round `d`, the part of `v` that round reads: diagonals `-d - 1 .. d + 1`.
    var trace = std.ArrayList([]isize).empty;
    var d: isize = 0;
    const found = search: while (d <= max) : (d += 1) {
        try trace.append(a, try a.dupe(isize, v[@intCast(off - d - 1)..@intCast(off + d + 2)]));
        var kk: isize = -d;
        while (kk <= d) : (kk += 2) {
            var x: isize = if (kk == -d or (kk != d and v[@intCast(kk - 1 + off)] < v[@intCast(kk + 1 + off)]))
                v[@intCast(kk + 1 + off)]
            else
                v[@intCast(kk - 1 + off)] + 1;
            var y = x - kk;
            while (x < n and y < m and std.mem.eql(
                u8,
                TextMap.line(old, os, o0 + @as(usize, @intCast(x))),
                TextMap.line(new, ns, n0 + @as(usize, @intCast(y))),
            )) {
                x += 1;
                y += 1;
            }
            v[@intCast(kk + off)] = x;
            if (x >= n and y >= m) break :search true;
        }
    } else false;
    if (!found) return;
    // Walk back through the rounds, recording the diagonal moves (equal lines).
    var x = n;
    var y = m;
    var dd = d;
    while (dd >= 0) : (dd -= 1) {
        const vv = trace.items[@intCast(dd)];
        const base = dd + 1; // diagonal `k` is at `vv[k + base]`
        const kk = x - y;
        const prev_k = if (kk == -dd or (kk != dd and vv[@intCast(kk - 1 + base)] < vv[@intCast(kk + 1 + base)])) kk + 1 else kk - 1;
        const prev_x = vv[@intCast(prev_k + base)];
        const prev_y = prev_x - prev_k;
        while (x > prev_x and y > prev_y and x > 0 and y > 0) {
            x -= 1;
            y -= 1;
            const oi = o0 + @as(usize, @intCast(x));
            const nj = n0 + @as(usize, @intCast(y));
            o2n[oi] = @intCast(nj);
            n2o[nj] = @intCast(oi);
        }
        if (dd == 0) break;
        x = prev_x;
        y = prev_y;
    }
}

pub const Code = struct {
    /// `text[0..end]` with comments and the insides of string and character literals
    /// turned into spaces, so a backwards scan sees only code.
    text: []u8,
    /// `end` itself is inside a comment or a literal.
    in_literal: bool,
};

pub fn codeBefore(a: std.mem.Allocator, text: []const u8, end_in: usize) !Code {
    const end = @min(end_in, text.len);
    const out = try a.dupe(u8, text[0..end]);
    const State = enum { code, comment, string, char };
    var state: State = .code;
    var i: usize = 0;
    while (i < out.len) {
        const c = out[i];
        switch (state) {
            .code => {
                if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
                    state = .comment;
                    continue;
                }
                if (c == '"') state = .string;
                if (c == '\'') state = .char;
                i += 1;
            },
            .comment => {
                if (c == '\n') {
                    state = .code;
                } else out[i] = ' ';
                i += 1;
            },
            .string, .char => {
                if (c == '\\') {
                    out[i] = ' ';
                    if (i + 1 < out.len) out[i + 1] = ' ';
                    i += 2;
                    continue;
                }
                if ((state == .string and c == '"') or (state == .char and c == '\'')) {
                    state = .code;
                } else if (c != '\n') out[i] = ' ';
                i += 1;
            },
        }
    }
    return .{ .text = out, .in_literal = state != .code };
}

fn skipSpaceBack(code: []const u8, i: usize) usize {
    var j = @min(i, code.len);
    while (j > 0 and isSpace(code[j - 1])) j -= 1;
    return j;
}

/// The index of the bracket `open` that matches the `close` at `at`.
fn openBefore(code: []const u8, at: usize, open: u8, close: u8) ?usize {
    var depth: usize = 0;
    var i = at + 1;
    while (i > 0) {
        i -= 1;
        const c = code[i];
        if (c == close) {
            depth += 1;
        } else if (c == open) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

/// One step after the base of a receiver chain.
pub const Post = union(enum) {
    /// `.name`
    field: []const u8,
    /// `::name`
    scope: []const u8,
    /// `(...)`
    call,
    /// `[i]`
    index,
    /// `[a..b]`, `[:]`
    slice,
    /// `?`
    try_q,
    /// `!!`
    unwrap,
};

pub const max_posts = 24;

/// An expression written as a name followed by steps: `a.b(1)[i].c`.
pub const Chain = struct {
    base: []const u8,
    /// Where the base name starts.
    start: usize,
    buf: [max_posts]Post = undefined,
    len: usize = 0,

    pub fn posts(self: *const Chain) []const Post {
        return self.buf[0..self.len];
    }
};

/// Words that end an expression scan: what stands before them is not a receiver.
const not_receivers = [_][]const u8{
    "return", "if",    "else",   "while",  "for",    "in",        "match",    "fn",
    "defer",  "catch", "fail",   "as",     "pub",    "const",     "unsafe",   "zone",
    "break",  "true",  "false",  "null",   "struct", "enum",      "errors",   "interface",
    "type",   "macro", "opaque", "atomic", "borrow", "continue", "yield", "union",
};

/// The chain that ends at `end` (exclusive), as in the text before a `.` or `(`.
pub fn chainBefore(code: []const u8, end: usize) ?Chain {
    var rev: [max_posts]Post = undefined;
    var n: usize = 0;
    var i = @min(end, code.len);
    while (true) {
        i = skipSpaceBack(code, i);
        if (i == 0 or n == max_posts) return null;
        const c = code[i - 1];
        switch (c) {
            ')' => {
                const open = openBefore(code, i - 1, '(', ')') orelse return null;
                rev[n] = .call;
                n += 1;
                i = open;
                continue;
            },
            ']' => {
                const open = openBefore(code, i - 1, '[', ']') orelse return null;
                const inner = std.mem.trim(u8, code[open + 1 .. i - 1], " \t\r\n");
                const is_slice = inner.len == 0 or std.mem.eql(u8, inner, ":") or std.mem.indexOf(u8, inner, "..") != null;
                rev[n] = if (is_slice) .slice else .index;
                n += 1;
                i = open;
                continue;
            },
            '?' => {
                if (i >= 2 and code[i - 2] == '?') return null;
                rev[n] = .try_q;
                n += 1;
                i -= 1;
                continue;
            },
            '!' => {
                if (i >= 2 and code[i - 2] == '!') {
                    rev[n] = .unwrap;
                    n += 1;
                    i -= 2;
                    continue;
                }
                return null;
            },
            else => {},
        }
        if (!isIdentChar(c)) return null;
        var s = i;
        while (s > 0 and isIdentChar(code[s - 1])) s -= 1;
        const name = code[s..i];
        if (std.ascii.isDigit(name[0])) return null;
        const k = skipSpaceBack(code, s);
        if (k >= 1 and code[k - 1] == '.' and !(k >= 2 and code[k - 2] == '.')) {
            rev[n] = .{ .field = name };
            n += 1;
            i = k - 1;
            continue;
        }
        if (k >= 2 and code[k - 1] == ':' and code[k - 2] == ':') {
            rev[n] = .{ .scope = name };
            n += 1;
            i = k - 2;
            continue;
        }
        for (not_receivers) |kw| if (std.mem.eql(u8, kw, name)) return null;
        // `#insert m(...)`, `#run f()`: the directive is not part of the chain.
        var chain = Chain{ .base = name, .start = s };
        var j: usize = 0;
        while (j < n) : (j += 1) chain.buf[j] = rev[n - 1 - j];
        chain.len = n;
        return chain;
    }
}

/// An open `(` before the cursor and the argument the cursor is in.
pub const CallAt = struct {
    paren: usize,
    /// Commas between the `(` and the cursor, at the call's own level.
    active: usize,
};

/// The innermost `(` before `end` that is not closed before it. Steps out of an index or a
/// `.{ ... }` literal inside the arguments; stops at a block or the end of a statement.
pub fn callBefore(code: []const u8, end: usize) ?CallAt {
    var depth: usize = 0;
    var commas: usize = 0;
    var i = @min(end, code.len);
    while (i > 0) {
        i -= 1;
        switch (code[i]) {
            ')', ']', '}' => depth += 1,
            '(' => {
                if (depth == 0) return .{ .paren = i, .active = commas };
                depth -= 1;
            },
            '[' => {
                if (depth == 0) {
                    commas = 0;
                    continue;
                }
                depth -= 1;
            },
            '{' => {
                if (depth == 0) {
                    const k = skipSpaceBack(code, i);
                    if (k > 0 and code[k - 1] == '.') {
                        commas = 0;
                        continue;
                    }
                    return null;
                }
                depth -= 1;
            },
            ',' => {
                if (depth == 0) commas += 1;
            },
            ';' => if (depth == 0) return null,
            else => {},
        }
    }
    return null;
}

/// The innermost bracket (`(`, `[` or `{`) open at `end`.
fn openerBefore(code: []const u8, end: usize) ?usize {
    var depth: usize = 0;
    var i = @min(end, code.len);
    while (i > 0) {
        i -= 1;
        switch (code[i]) {
            ')', ']', '}' => depth += 1,
            '(', '[', '{' => {
                if (depth == 0) return i;
                depth -= 1;
            },
            else => {},
        }
    }
    return null;
}

fn wordBefore(code: []const u8, end: usize) []const u8 {
    const e = skipSpaceBack(code, end);
    var s = e;
    while (s > 0 and isIdentChar(code[s - 1])) s -= 1;
    return code[s..e];
}

/// Where a `.` that starts an enum literal (`.red`) gets its expected type from.
pub const EnumCtx = union(enum) {
    /// `x == .` and `x != .`
    compare: Chain,
    /// `x.y = .`
    assign: Chain,
    /// `name: Type = .`: the written type
    typed: []const u8,
    /// `f(a, .`
    arg: CallAt,
    /// `return .`
    ret,
    /// `match subject { .`
    match_arm: Chain,
};

pub fn enumContext(code: []const u8, dot: usize) ?EnumCtx {
    const k = skipSpaceBack(code, dot);
    if (k == 0) return null;
    const c = code[k - 1];
    if (c == '=' and k >= 2 and (code[k - 2] == '=' or code[k - 2] == '!')) {
        return .{ .compare = chainBefore(code, k - 2) orelse return null };
    }
    if (c == '=' and k >= 2 and std.mem.indexOfScalar(u8, "<>+-*/%&|^:=", code[k - 2]) == null) {
        if (typedLocalType(code, k - 1)) |t| return .{ .typed = t };
        return .{ .assign = chainBefore(code, k - 1) orelse return null };
    }
    if (std.mem.eql(u8, wordBefore(code, dot), "return")) return .ret;
    const open = openerBefore(code, dot) orelse return null;
    switch (code[open]) {
        '(' => if (c == '(' or c == ',') return .{ .arg = callBefore(code, dot) orelse return null },
        '{' => if (c == '{' or c == ',' or c == '}') {
            const subject = chainBefore(code, open) orelse return null;
            if (std.mem.eql(u8, wordBefore(code, subject.start), "match")) return .{ .match_arm = subject };
        },
        else => {},
    }
    return null;
}

/// In `name: Type = `, the `Type` text before the `=` at `eq`.
fn typedLocalType(code: []const u8, eq: usize) ?[]const u8 {
    var i = eq;
    while (i > 0) {
        const c = code[i - 1];
        if (c == ':') {
            if (i >= 2 and code[i - 2] == ':') {
                i -= 2;
                continue;
            }
            const t = std.mem.trim(u8, code[i..eq], " \t\r\n");
            const before = wordBefore(code, i - 1);
            if (t.len == 0 or before.len == 0) return null;
            return t;
        }
        if (isIdentChar(c) or isSpace(c) or c == '*' or c == '?' or c == '[' or c == ']') {
            i -= 1;
            continue;
        }
        return null;
    }
    return null;
}

// The analysis view

/// The analysis a request answers from, and how its text maps to the current text.
pub const View = struct {
    an: *const pipeline.Analysis,
    syms: *const sema.SymbolTable,
    env: *const sema.TypeEnv,
    /// The document's path, as the analysis names it.
    path: []const u8,
    /// The document as the analysis read it, and as it is now.
    old: []const u8,
    new: []const u8,
    map: TextMap,
    /// True when this is the last good analysis, not the current one.
    stale: bool,
    /// The request's arena.
    a: std.mem.Allocator,
};

pub fn viewOf(doc: *lsp.Doc, a: std.mem.Allocator) ?View {
    var stale = false;
    const an: *const pipeline.Analysis = pick: {
        if (doc.analysis) |*cur| if (cur.symbols != null and cur.types != null) break :pick cur;
        if (doc.last_good) |*good| {
            stale = true;
            break :pick good;
        }
        return null;
    };
    const file = an.fileNamed(doc.path) orelse return null;
    const map = TextMap.build(a, file.source, doc.text);
    return .{
        .an = an,
        .syms = &an.symbols.?,
        .env = &an.types.?,
        .path = file.path,
        .old = file.source,
        .new = doc.text,
        .map = map,
        .stale = stale,
        .a = a,
    };
}

fn sameText(x: []const u8, y: []const u8) bool {
    return (x.ptr == y.ptr and x.len == y.len) or std.mem.eql(u8, x, y);
}

// Locals

/// `name` written as a whole word at `i` (not a member name after a `.`).
fn wordAt(src: []const u8, i: usize, name: []const u8) bool {
    if (i + name.len > src.len or !std.mem.eql(u8, src[i .. i + name.len], name)) return false;
    if (i > 0 and (isIdentChar(src[i - 1]) or src[i - 1] == '.' or src[i - 1] == '$')) return false;
    if (i + name.len < src.len and isIdentChar(src[i + name.len])) return false;
    return true;
}

fn firstWord(src: []const u8, lo: usize, hi: usize, name: []const u8) ?usize {
    var i = lo;
    while (i + name.len <= @min(hi, src.len)) : (i += 1) {
        if (wordAt(src, i, name)) return i;
    }
    return null;
}

/// `|name|` (or `|name,`) between `lo` and `hi`: where the name starts.
fn captureIn(src: []const u8, lo: usize, hi: usize, name: []const u8) ?usize {
    var i = lo;
    const top = @min(hi, src.len);
    while (i < top) : (i += 1) {
        if (src[i] != '|') continue;
        var j = i + 1;
        while (j < top and isSpace(src[j])) j += 1;
        if (!wordAt(src, j, name)) continue;
        var k = j + name.len;
        while (k < top and isSpace(src[k])) k += 1;
        if (k < top and (src[k] == '|' or src[k] == ',')) return j;
    }
    return null;
}

/// Where the name of a recorded local is written in `src` (the analysis's text of its file).
pub fn bindingNameStart(src: []const u8, b: sema.LocalBinding) ?usize {
    const lo = @min(b.decl.start, src.len);
    const hi = @min(b.decl.end, src.len);
    switch (b.kind) {
        .param => {
            if (wordAt(src, lo, b.name)) return lo; // `a: $T`
            // `name: Type`: the name ends just before the colon in front of the type.
            var i = lo;
            while (i > 0 and isSpace(src[i - 1])) i -= 1;
            if (i == 0 or src[i - 1] != ':') return null;
            i -= 1;
            while (i > 0 and isSpace(src[i - 1])) i -= 1;
            if (i < b.name.len) return null;
            const s = i - b.name.len;
            return if (wordAt(src, s, b.name)) s else null;
        },
        .case_binding => {
            if (captureIn(src, lo, hi, b.name)) |p| return p;
            return firstWord(src, lo, hi, b.name);
        },
        .try_error => {
            const c = firstWord(src, lo, hi, "catch") orelse return null;
            return firstWord(src, c + 5, hi, b.name);
        },
        else => {
            if (wordAt(src, lo, b.name)) return lo;
            return firstWord(src, lo, hi, b.name);
        },
    }
}

/// Where a recorded local starts to be visible.
fn visibleFrom(b: sema.LocalBinding) usize {
    return switch (b.kind) {
        // `x := …;` is visible after its statement; `if x := …` in its block.
        .local_val, .local_var => if (b.scope_end > b.decl.end) b.decl.end else b.decl.start,
        else => b.decl.start,
    };
}

/// The local `name` visible at `pos` (an offset in the analysis's text), or the one declared
/// exactly at `decl_at`.
fn localAt(v: *const View, name: []const u8, pos: usize, decl_at: ?usize) ?*const sema.LocalBinding {
    var best: ?*const sema.LocalBinding = null;
    var best_from: usize = 0;
    for (v.env.local_bindings.items) |*b| {
        if (!std.mem.eql(u8, b.name, name) or !sameText(b.file, v.path)) continue;
        if (decl_at) |d| if (bindingNameStart(v.old, b.*)) |ns| if (ns == d) return b;
        const from = visibleFrom(b.*);
        if (pos < from or pos >= b.scope_end) continue;
        if (best == null or from >= best_from) {
            best = b;
            best_from = from;
        }
    }
    return best;
}

// Declarations behind symbols

fn fnDecl(v: *const View, id: SymbolId) ?ast.FunctionDecl {
    const sym = v.syms.symbol(id);
    for (v.an.module.items) |item| switch (item) {
        .function => |f| if (f.span.start == sym.span.start and std.mem.eql(u8, f.name, sym.name) and
            sameText(f.file_name, sym.file_name)) return f,
        else => {},
    };
    return null;
}

/// The declaration of a type (the template's, for an instance of a generic struct).
fn typeDecl(v: *const View, id_in: SymbolId) ?ast.TypeDecl {
    const id = templateOf(v, id_in);
    const sym = v.syms.symbol(id);
    for (v.an.module.items) |item| switch (item) {
        .type_decl => |t| if (std.mem.eql(u8, t.name, sym.name) and sameText(t.file_name, sym.file_name)) return t,
        else => {},
    };
    return null;
}

fn constDecl(v: *const View, id: SymbolId) ?ast.ConstDecl {
    const sym = v.syms.symbol(id);
    for (v.an.module.items) |item| switch (item) {
        .const_decl => |c| if (std.mem.eql(u8, c.name, sym.name) and sameText(c.file_name, sym.file_name)) return c,
        else => {},
    };
    return null;
}

/// A macro by name (macros are expanded before checking, so only the loaded module has them).
fn macroDecl(v: *const View, name: []const u8) ?ast.FunctionDecl {
    var found: ?ast.FunctionDecl = null;
    for (v.an.loaded.items) |item| switch (item) {
        .function => |f| if (f.is_macro and std.mem.eql(u8, f.name, name)) {
            if (sameText(f.file_name, v.path)) return f;
            found = f;
        },
        else => {},
    };
    return found;
}

fn templateOf(v: *const View, id: SymbolId) SymbolId {
    if (v.env.generic_struct_instance_args.get(id)) |app| return app.template;
    return id;
}

/// The name a type's in-struct functions are hoisted under (`Vec` for `Vec.push`).
fn baseName(v: *const View, id: SymbolId) []const u8 {
    return v.syms.symbol(templateOf(v, id)).name;
}

/// The type symbol a type reference names, seen from `file`.
fn refTypeId(v: *const View, file: []const u8, ref: ast.TypeRef) ?SymbolId {
    const named = switch (ref) {
        .named => |n| n,
        .optional => |o| return refTypeId(v, file, o.inner.*),
        .pointer => |p| return refTypeId(v, file, p.inner.*),
        else => return null,
    };
    const id = if (named.namespace) |ns|
        v.syms.resolveScoped(file, ns, named.name)
    else
        v.syms.resolveVisible(file, named.name);
    const sid = id orelse return null;
    if (v.syms.symbol(sid).kind != .type) return null;
    return sid;
}

// Values along a chain

const Typed = struct { ty: Ty, hint: ?ast.TypeRef = null };

/// Something that can be called: a function, a method, an interface method, a function
/// pointer or a macro.
const Callable = struct {
    name: []const u8,
    sym: ?SymbolId = null,
    decl: ?ast.FunctionDecl = null,
    iface: ?sema.InterfaceMethodInfo = null,
    fn_ty: ?Ty = null,
    fn_hint: ?ast.TypeRef = null,
    /// Called as `recv.name(...)`: the receiver is the first parameter.
    drop_self: bool = false,
    /// The type a method belongs to; for an instance of a generic struct its type
    /// arguments stand in for the type parameters.
    owner: ?SymbolId = null,
};

/// The type parameter names of a generic struct instance and the text of its arguments.
fn substFor(v: *const View, id: SymbolId) []const [2][]const u8 {
    const app = v.env.generic_struct_instance_args.get(id) orelse return &.{};
    const td = typeDecl(v, id) orelse return &.{};
    const names = switch (td.kind) {
        .struct_type => |st| st.type_params,
        else => return &.{},
    };
    const n = @min(names.len, app.args.len);
    const out = v.a.alloc([2][]const u8, n) catch return &.{};
    for (0..n) |i| out[i] = .{ names[i], tyText(v, app.args[i], null) };
    return out;
}

/// `ty` with the type parameters of the generic struct instance `owner` replaced by its
/// type arguments (`T` of a `Vec(i32)` method is `i32`).
fn substTy(v: *const View, ty: Ty, owner: ?SymbolId) Ty {
    const id = owner orelse return ty;
    const app = v.env.generic_struct_instance_args.get(id) orelse return ty;
    const td = typeDecl(v, id) orelse return ty;
    const names = switch (td.kind) {
        .struct_type => |st| st.type_params,
        else => return ty,
    };
    return substWith(v, ty, names, app.args);
}

fn substWith(v: *const View, ty: Ty, names: []const []const u8, args: []const Ty) Ty {
    switch (ty) {
        .type_param => |n| {
            for (names, 0..) |name, i| if (i < args.len and std.mem.eql(u8, name, n)) return args[i];
            return ty;
        },
        .pointer => |inner| return .{ .pointer = box(v, substWith(v, inner.*, names, args)) orelse return ty },
        .const_ptr => |inner| return .{ .const_ptr = box(v, substWith(v, inner.*, names, args)) orelse return ty },
        .slice => |inner| return .{ .slice = box(v, substWith(v, inner.*, names, args)) orelse return ty },
        .const_slice => |inner| return .{ .const_slice = box(v, substWith(v, inner.*, names, args)) orelse return ty },
        .optional => |inner| return .{ .optional = box(v, substWith(v, inner.*, names, args)) orelse return ty },
        else => return ty,
    }
}

const Val = union(enum) {
    value: Typed,
    type_sym: SymbolId,
    /// An import alias (`alias::member`).
    namespace: []const u8,
    callable: Callable,
};

fn symVal(v: *const View, id: SymbolId, depth: u8) ?Val {
    const sym = v.syms.symbol(id);
    switch (sym.kind) {
        .type => {
            if (depth < 4) if (v.env.alias_refs.get(id)) |ref| if (refTypeId(v, sym.file_name, ref)) |tid| {
                if (tid != id) return symVal(v, tid, depth + 1);
            };
            return .{ .type_sym = id };
        },
        .function => return .{ .callable = .{ .name = sym.name, .sym = id, .decl = fnDecl(v, id) } },
        .const_symbol, .global_var => {
            const ty = v.env.get(id) orelse return null;
            return .{ .value = .{ .ty = ty, .hint = if (constDecl(v, id)) |d| d.ty else null } };
        },
        else => return null,
    }
}

fn resolveBase(v: *const View, name: []const u8, pos: usize) ?Val {
    if (localAt(v, name, pos, null)) |b| return .{ .value = .{ .ty = b.ty, .hint = bindingHint(v, b.*, 0) } };
    if (v.syms.resolveVisible(v.path, name)) |id| return symVal(v, id, 0);
    if (v.syms.namespaces.get(v.path)) |aliases| if (aliases.contains(name)) return .{ .namespace = name };
    if (macroDecl(v, name)) |d| return .{ .callable = .{ .name = name, .decl = d } };
    return null;
}

fn resolveChain(v: *const View, chain: *const Chain, pos: usize) ?Val {
    var val = resolveBase(v, chain.base, pos) orelse return null;
    for (chain.posts()) |p| val = step(v, val, p) orelse return null;
    return val;
}

fn box(v: *const View, ty: Ty) ?*const Ty {
    const p = v.a.create(Ty) catch return null;
    p.* = ty;
    return p;
}

fn refInner(hint: ?ast.TypeRef) ?ast.TypeRef {
    const h = hint orelse return null;
    return switch (h) {
        .pointer, .many_pointer => |p| p.inner.*,
        .optional => |o| o.inner.*,
        .slice => |s| s.inner.*,
        .array => |arr| arr.inner.*,
        else => null,
    };
}

fn step(v: *const View, val: Val, post: Post) ?Val {
    switch (post) {
        .field => |name| {
            const m = switch (val) {
                .value => |t| memberNamed(v, t.ty, name, false),
                .type_sym => |id| memberNamed(v, .{ .named = id }, name, true),
                else => null,
            } orelse return null;
            return memberVal(v, m);
        },
        .scope => |name| switch (val) {
            .namespace => |alias| {
                const id = v.syms.resolveScoped(v.path, alias, name) orelse return null;
                return symVal(v, id, 0);
            },
            .type_sym => |id| {
                const m = memberNamed(v, .{ .named = id }, name, true) orelse return null;
                return memberVal(v, m);
            },
            else => return null,
        },
        .call => switch (val) {
            .callable => |c| return returnOf(v, c),
            .value => |t| switch (t.ty) {
                .fn_ptr => |f| return .{ .value = .{ .ty = f.ret.*, .hint = if (t.hint) |h| switch (h) {
                    .fn_type => |ft| ft.ret.*,
                    else => null,
                } else null } },
                else => return null,
            },
            else => return null,
        },
        .index => {
            const t = switch (val) {
                .value => |t| t,
                else => return null,
            };
            return switch (t.ty) {
                .array => |arr| .{ .value = .{ .ty = arr.elem.*, .hint = refInner(t.hint) } },
                .slice, .const_slice, .pointer, .const_ptr => |inner| .{ .value = .{ .ty = inner.*, .hint = refInner(t.hint) } },
                else => null,
            };
        },
        .slice => {
            const t = switch (val) {
                .value => |t| t,
                else => return null,
            };
            return switch (t.ty) {
                .array => |arr| .{ .value = .{ .ty = .{ .slice = arr.elem }, .hint = null } },
                .slice => .{ .value = t },
                else => null,
            };
        },
        .try_q => {
            const t = switch (val) {
                .value => |t| t,
                else => return null,
            };
            return switch (t.ty) {
                .fallible => |f| .{ .value = .{ .ty = f.ok.*, .hint = t.hint } },
                .optional => |inner| .{ .value = .{ .ty = inner.*, .hint = refInner(t.hint) } },
                else => null,
            };
        },
        .unwrap => {
            const t = switch (val) {
                .value => |t| t,
                else => return null,
            };
            return switch (t.ty) {
                .optional => |inner| .{ .value = .{ .ty = inner.*, .hint = refInner(t.hint) } },
                .fallible => |f| .{ .value = .{ .ty = f.ok.*, .hint = t.hint } },
                else => null,
            };
        },
    }
}

fn returnOf(v: *const View, c: Callable) ?Val {
    if (c.sym) |id| if (v.env.fn_sigs.get(id)) |sig| {
        const ret = substTy(v, sig.return_ty, c.owner);
        var ty = ret;
        if (sig.error_ty) |err| ty = .{ .fallible = .{ .ok = box(v, ret) orelse return null, .err = box(v, err) orelse return null } };
        const hint: ?ast.TypeRef = if (c.decl) |d| (if (d.type_params.len == 0) d.return_ty else null) else null;
        return .{ .value = .{ .ty = ty, .hint = hint } };
    };
    if (c.iface) |m| {
        var ty = m.return_ty;
        if (m.error_ty) |err| ty = .{ .fallible = .{ .ok = box(v, m.return_ty) orelse return null, .err = box(v, err) orelse return null } };
        return .{ .value = .{ .ty = ty, .hint = if (c.decl) |d| d.return_ty else null } };
    }
    if (c.fn_ty) |t| switch (t) {
        .fn_ptr => |f| return .{ .value = .{ .ty = f.ret.* } },
        else => {},
    };
    return null;
}

// Members

const MemberKind = enum { field, method, ext, iface, variant, assoc, builtin };

const Member = struct {
    name: []const u8,
    kind: MemberKind,
    ty: ?Ty = null,
    hint: ?ast.TypeRef = null,
    sym: ?SymbolId = null,
    iface: ?sema.InterfaceMethodInfo = null,
    decl: ?ast.FunctionDecl = null,
    /// The type the member belongs to (the struct of a field, the enum of a variant, the
    /// interface of an interface method).
    owner: ?SymbolId = null,
};

/// The named type behind a value: `T`, `*T` or `*const T`.
fn namedOf(ty: Ty) ?SymbolId {
    return switch (ty) {
        .named => |id| id,
        .pointer, .const_ptr, .borrow => |inner| switch (inner.*) {
            .named => |id| id,
            else => null,
        },
        else => null,
    };
}

fn firstValueParam(sig: sema.FnSig) ?sema.ParamSig {
    for (sig.params) |p| {
        if (p.is_type_param) continue;
        return p;
    }
    return null;
}

fn takesSelf(sig: sema.FnSig) bool {
    const p = firstValueParam(sig) orelse return false;
    return std.mem.eql(u8, p.name, "self");
}

fn stripPtr(ty: Ty) Ty {
    return switch (ty) {
        .pointer, .const_ptr, .borrow => |inner| inner.*,
        else => ty,
    };
}

/// Loose type equality for picking extension functions: a type parameter matches anything,
/// instances of one generic struct match each other.
fn looseEq(v: *const View, a: Ty, b: Ty) bool {
    switch (a) {
        .type_param, .unknown => return true,
        .named => |ia| return switch (b) {
            .named => |ib| ia == ib or templateOf(v, ia) == templateOf(v, ib),
            else => false,
        },
        .generic_app => |g| return switch (b) {
            .named => |ib| templateOf(v, ib) == g.template,
            else => false,
        },
        .slice, .const_slice => |ia| return switch (b) {
            .slice, .const_slice => |ib| looseEq(v, ia.*, ib.*),
            .array => |arr| looseEq(v, ia.*, arr.elem.*),
            else => false,
        },
        .array => |aa| return switch (b) {
            .array => |bb| looseEq(v, aa.elem.*, bb.elem.*),
            else => false,
        },
        .pointer, .const_ptr => |ia| return switch (b) {
            .pointer, .const_ptr => |ib| looseEq(v, ia.*, ib.*),
            else => false,
        },
        .optional => |ia| return switch (b) {
            .optional => |ib| looseEq(v, ia.*, ib.*),
            else => false,
        },
        else => return std.meta.activeTag(a) == std.meta.activeTag(b),
    }
}

/// Whether a free function whose first parameter is `self: param` can be called on `recv`.
fn selfMatches(v: *const View, param: Ty, recv: Ty) bool {
    const p = stripPtr(param);
    if (p == .type_param or p == .unknown) return false; // `self: $T` fits everything
    return looseEq(v, p, stripPtr(recv));
}

const MemberList = struct {
    items: std.ArrayList(Member) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .{},

    fn add(self: *MemberList, v: *const View, m: Member) void {
        if (m.name.len == 0 or self.seen.contains(m.name)) return;
        self.seen.put(v.a, m.name, {}) catch return;
        self.items.append(v.a, m) catch {};
    }
};

fn fieldDeclHint(v: *const View, tid: SymbolId, name: []const u8) ?ast.TypeRef {
    const td = typeDecl(v, tid) orelse return null;
    switch (td.kind) {
        .struct_type => |s| for (s.fields) |f| if (std.mem.eql(u8, f.name, name)) return f.ty,
        else => {},
    }
    return null;
}

/// The methods a value of type `ty` has, or with `static` the variants and associated
/// functions of the type itself.
fn collectMembers(v: *const View, ty: Ty, static: bool, out: *MemberList) void {
    if (static) {
        const tid = namedOf(ty) orelse return;
        if (v.env.layouts.get(tid)) |layout| switch (layout.kind) {
            .variant_type => |vs| for (vs) |variant| out.add(v, .{ .name = variant.name, .kind = .variant, .ty = variant.payload, .owner = tid }),
            .error_set => |vs| for (vs) |variant| out.add(v, .{ .name = variant.name, .kind = .variant, .ty = variant.payload, .owner = tid }),
            else => {},
        };
        typeFunctions(v, tid, false, out);
        return;
    }
    switch (ty) {
        .fallible => |f| {
            out.add(v, .{ .name = "ok", .kind = .builtin, .ty = f.ok.* });
            out.add(v, .{ .name = "err", .kind = .builtin, .ty = f.err.* });
        },
        .slice, .const_slice => |elem| {
            out.add(v, .{ .name = "len", .kind = .builtin, .ty = .usize });
            if (box(v, elem.*)) |e| out.add(v, .{ .name = "ptr", .kind = .builtin, .ty = if (ty == .const_slice) .{ .const_ptr = e } else .{ .pointer = e } });
        },
        .array => |arr| {
            out.add(v, .{ .name = "len", .kind = .builtin, .ty = .usize });
            out.add(v, .{ .name = "ptr", .kind = .builtin, .ty = .{ .pointer = arr.elem } });
        },
        else => {},
    }
    if (namedOf(ty)) |tid| {
        if (v.env.layouts.get(tid)) |layout| switch (layout.kind) {
            .struct_type => |fields| for (fields) |f| out.add(v, .{
                .name = f.name,
                .kind = .field,
                .ty = f.ty,
                .hint = fieldDeclHint(v, tid, f.name),
                .owner = tid,
            }),
            .interface_type => |methods| interfaceMembers(v, tid, methods, out),
            else => {},
        };
        typeFunctions(v, tid, true, out);
        // Interfaces the type implements.
        const tname = baseName(v, tid);
        var it = v.env.interface_impls.valueIterator();
        while (it.next()) |impl| {
            if (!std.mem.eql(u8, impl.type_name, tname)) continue;
            const iid = v.syms.resolveVisible(impl.file_name, impl.interface_name) orelse continue;
            const layout = v.env.layouts.get(iid) orelse continue;
            switch (layout.kind) {
                .interface_type => |methods| interfaceMembers(v, iid, methods, out),
                else => {},
            }
        }
    }
    extensionMembers(v, ty, out);
}

fn interfaceMembers(v: *const View, iid: SymbolId, methods: []const sema.InterfaceMethodInfo, out: *MemberList) void {
    const decls: []const ast.FunctionDecl = if (typeDecl(v, iid)) |td| switch (td.kind) {
        .interface_type => |i| i.methods,
        else => &.{},
    } else &.{};
    for (methods) |m| {
        var decl: ?ast.FunctionDecl = null;
        for (decls) |d| if (std.mem.eql(u8, d.name, m.name)) {
            decl = d;
        };
        out.add(v, .{ .name = m.name, .kind = .iface, .iface = m, .decl = decl, .owner = iid });
    }
}

/// The functions declared inside a type's body (hoisted as `Type.name`): with `methods`
/// those that take `self`, else the others (associated functions).
fn typeFunctions(v: *const View, tid: SymbolId, methods: bool, out: *MemberList) void {
    const base = baseName(v, tid);
    const file = v.syms.symbol(templateOf(v, tid)).file_name;
    for (v.syms.symbols.items) |sym| {
        if (sym.kind != .function or !sameText(sym.file_name, file)) continue;
        if (sym.name.len <= base.len + 1 or !std.mem.startsWith(u8, sym.name, base) or sym.name[base.len] != '.') continue;
        if (!sym.is_public and !sameText(sym.file_name, v.path)) continue;
        const sig = v.env.fn_sigs.get(sym.id) orelse continue;
        if (takesSelf(sig) != methods) continue;
        out.add(v, .{ .name = sym.name[base.len + 1 ..], .kind = if (methods) .method else .assoc, .sym = sym.id, .owner = tid });
    }
}

/// Free functions whose first parameter is `self` of the receiver's type: those visible in
/// the document, and the public ones of the module that declares the type.
fn extensionMembers(v: *const View, ty: Ty, out: *MemberList) void {
    if (v.syms.visible_names.get(v.path)) |visible| {
        var it = visible.iterator();
        while (it.next()) |e| considerExtension(v, e.value_ptr.*, ty, out);
    }
    if (namedOf(ty)) |tid| {
        const file = v.syms.symbol(templateOf(v, tid)).file_name;
        for (v.syms.symbols.items) |sym| {
            if (!sym.is_public or !sameText(sym.file_name, file)) continue;
            considerExtension(v, sym.id, ty, out);
        }
    }
}

fn considerExtension(v: *const View, id: SymbolId, ty: Ty, out: *MemberList) void {
    const sym = v.syms.symbol(id);
    if (sym.kind != .function or std.mem.indexOfScalar(u8, sym.name, '.') != null or sym.name.len == 0 or sym.name[0] == '_') return;
    if (out.seen.contains(sym.name)) return;
    const sig = v.env.fn_sigs.get(id) orelse return;
    const p = firstValueParam(sig) orelse return;
    if (!std.mem.eql(u8, p.name, "self") or !selfMatches(v, p.ty, ty)) return;
    out.add(v, .{ .name = sym.name, .kind = .ext, .sym = id });
}

fn memberNamed(v: *const View, ty: Ty, name: []const u8, static: bool) ?Member {
    var list = MemberList{};
    collectMembers(v, ty, static, &list);
    for (list.items.items) |m| if (std.mem.eql(u8, m.name, name)) return m;
    return null;
}

fn memberVal(v: *const View, m: Member) ?Val {
    return switch (m.kind) {
        .field, .builtin => .{ .value = .{ .ty = m.ty orelse return null, .hint = m.hint } },
        .variant => .{ .value = .{ .ty = .{ .named = m.owner orelse return null } } },
        .method => .{ .callable = .{ .name = m.name, .sym = m.sym, .decl = fnDecl(v, m.sym.?), .drop_self = true, .owner = m.owner } },
        .ext => .{ .callable = .{ .name = m.name, .sym = m.sym, .decl = fnDecl(v, m.sym.?), .drop_self = true } },
        .assoc => .{ .callable = .{ .name = m.name, .sym = m.sym, .decl = fnDecl(v, m.sym.?), .owner = m.owner } },
        .iface => .{ .callable = .{ .name = m.name, .iface = m.iface, .decl = m.decl, .drop_self = true } },
    };
}

// Written types behind a value

const u8_ref = ast.TypeRef{ .named = .{ .name = "u8", .span = .{ .start = 0, .end = 0 } } };
/// String literals are `[]const u8`; the checker's type does not keep the `const`.
const string_ref = ast.TypeRef{ .slice = .{ .is_const = true, .inner = &u8_ref, .span = .{ .start = 0, .end = 0 } } };

fn bindingHint(v: *const View, b: sema.LocalBinding, depth: u8) ?ast.TypeRef {
    if (b.written) |w| return w;
    if (b.value) |e| return exprHint(v, e, depth);
    return null;
}

fn calleeSymbol(v: *const View, call: ast.CallExpr) ?SymbolId {
    switch (call.callee.kind) {
        .ident => |name| {
            const id = v.syms.resolveVisible(v.path, name) orelse return null;
            return if (v.syms.symbol(id).kind == .function) id else null;
        },
        .field => return v.env.extension_calls.get(call.callee.id),
        .scope_access => return v.env.expr_symbols.get(call.callee.id),
        else => return null,
    }
}

/// The checker's type of an expression. A reference to a local has none recorded, so its
/// binding's type stands in.
fn exprTy(v: *const View, e: ast.Expr) ?Ty {
    if (v.env.expr_types.get(e.id)) |t| return t;
    return switch (e.kind) {
        .ident => |name| if (localAt(v, name, e.span.start, null)) |b| b.ty else null,
        else => null,
    };
}

/// The type as written somewhere behind an expression (a function's return type, a field's
/// type, a cast), so `const` and alias names survive.
fn exprHint(v: *const View, e: ast.Expr, depth: u8) ?ast.TypeRef {
    if (depth > 4) return null;
    switch (e.kind) {
        .string => return string_ref,
        .as_cast => |c| return c.to,
        .call => |c| {
            const id = calleeSymbol(v, c) orelse return null;
            const d = fnDecl(v, id) orelse return null;
            if (d.type_params.len > 0) return null;
            return d.return_ty;
        },
        .field => |f| {
            const tid = namedOf(exprTy(v, f.base.*) orelse return null) orelse return null;
            return fieldDeclHint(v, tid, f.name);
        },
        .ident => |name| {
            if (localAt(v, name, e.span.start, null)) |b| return bindingHint(v, b.*, depth + 1);
            if (v.syms.resolveVisible(v.path, name)) |id| if (constDecl(v, id)) |d| return d.ty;
            return null;
        },
        .try_expr => |t| return exprHint(v, t.value.*, depth + 1),
        .catch_expr => |c| return exprHint(v, c.value.*, depth + 1),
        .unsafe_expr => |inner| return exprHint(v, inner.*, depth + 1),
        else => return null,
    }
}

// Rendering types the way Fels source writes them

const Out = struct {
    a: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,
    /// Type parameter names and what to write for them (a method of `Vec(i32)` shows
    /// `i32` where its declaration says `T`).
    subst: []const [2][]const u8 = &.{},

    fn param(o: *Out, name: []const u8) bool {
        for (o.subst) |pair| if (std.mem.eql(u8, pair[0], name)) {
            o.s(pair[1]);
            return true;
        };
        return false;
    }

    fn s(o: *Out, text: []const u8) void {
        o.list.appendSlice(o.a, text) catch {};
    }
    fn f(o: *Out, comptime fmt: []const u8, args: anytype) void {
        o.list.print(o.a, fmt, args) catch {};
    }
    fn esc(o: *Out, text: []const u8) void {
        lsp.escapeInto(&o.list, o.a, text);
    }
    fn len(o: *Out) usize {
        return o.list.items.len;
    }
};

fn isVoidRef(ref: ast.TypeRef) bool {
    return switch (ref) {
        .named => |n| n.namespace == null and std.mem.eql(u8, n.name, "void"),
        else => false,
    };
}

fn renderLen(o: *Out, e: ast.Expr) void {
    switch (e.kind) {
        .int => |t| o.s(t),
        .ident => |n| o.s(n),
        .scope_access => |sa| {
            renderLen(o, sa.base.*);
            o.s("::");
            o.s(sa.member);
        },
        .binary => |b| {
            renderLen(o, b.left.*);
            o.s(switch (b.op) {
                .add => " + ",
                .sub => " - ",
                .mul => " * ",
                .div => " / ",
                else => " ? ",
            });
            renderLen(o, b.right.*);
        },
        else => o.s("_"),
    }
}

fn renderVariants(o: *Out, variants: []const ast.ErrorVariantDecl) void {
    o.s("{ ");
    for (variants, 0..) |variant, i| {
        if (i > 0) o.s(", ");
        o.s(".");
        o.s(variant.name);
    }
    o.s(" }");
}

fn renderErrorSpec(o: *Out, spec: ast.ErrorSpec) void {
    switch (spec) {
        .inferred => o.s(" !"),
        .named => |n| {
            o.s(" ! ");
            if (n.namespace) |ns| {
                o.s(ns);
                o.s("::");
            }
            o.s(n.name);
        },
        .inline_set => |set| {
            o.s(" ! ");
            renderVariants(o, set.variants);
        },
    }
}

/// A type as written in the source.
fn renderRef(o: *Out, ref: ast.TypeRef) void {
    switch (ref) {
        .named => |n| {
            if (n.namespace == null and o.param(n.name)) return;
            if (n.namespace) |ns| {
                o.s(ns);
                o.s("::");
            }
            o.s(n.name);
        },
        .pointer => |p| {
            o.s("*");
            if (p.is_const) o.s("const ");
            if (p.is_volatile) o.s("volatile ");
            renderRef(o, p.inner.*);
        },
        .many_pointer => |p| {
            o.s("[*]");
            if (p.is_const) o.s("const ");
            renderRef(o, p.inner.*);
        },
        .optional => |p| {
            o.s("?");
            renderRef(o, p.inner.*);
        },
        .slice => |p| {
            o.s("[]");
            if (p.is_const) o.s("const ");
            renderRef(o, p.inner.*);
        },
        .array => |p| {
            o.s("[");
            renderLen(o, p.len.*);
            o.s("]");
            renderRef(o, p.inner.*);
        },
        .atomic => |p| {
            o.s("atomic ");
            renderRef(o, p.inner.*);
        },
        .borrow => |p| {
            o.s("borrow ");
            renderRef(o, p.inner.*);
        },
        .fn_type => |ft| {
            if (ft.is_extern) o.s("extern ");
            o.s("fn(");
            for (ft.params, 0..) |p, i| {
                if (i > 0) o.s(", ");
                renderRef(o, p);
            }
            o.s(")");
            if (!isVoidRef(ft.ret.*)) {
                o.s(" -> ");
                renderRef(o, ft.ret.*);
            }
            if (ft.error_ty) |e| renderErrorSpec(o, e);
        },
        .inline_error_set => |set| renderVariants(o, set.variants),
        .type_param => |n| if (!o.param(n.name)) o.s(n.name),
        .generic_inst => |g| {
            if (g.namespace) |ns| {
                o.s(ns);
                o.s("::");
            }
            o.s(g.name);
            o.s("(");
            for (g.args, 0..) |arg, i| {
                if (i > 0) o.s(", ");
                renderRef(o, arg);
            }
            o.s(")");
        },
        .opaque_type => o.s("opaque"),
    }
}

/// Whether a written type names an alias that the checker resolved away (`HWND` for
/// `usize`): then the written name is the better one to show.
fn isAliasRef(v: *const View, hint: ast.TypeRef, ty: Ty) bool {
    const n = switch (hint) {
        .named => |n| n,
        else => return false,
    };
    const id = (if (n.namespace) |ns| v.syms.resolveScoped(v.path, ns, n.name) else v.syms.resolveVisible(v.path, n.name)) orelse return false;
    if (!v.env.alias_refs.contains(id)) return false;
    return switch (ty) {
        .named => |tid| tid != id,
        else => true,
    };
}

fn renderNamed(v: *const View, o: *Out, id: SymbolId) void {
    if (v.env.generic_struct_instance_args.get(id)) |app| {
        o.s(v.syms.symbol(app.template).name);
        o.s("(");
        for (app.args, 0..) |arg, i| {
            if (i > 0) o.s(", ");
            renderTy(v, o, arg, null);
        }
        o.s(")");
        return;
    }
    o.s(v.syms.symbol(id).name);
}

/// A checker type the way Fels source writes it. `hint`, the type as written where the
/// value came from, adds what the checker does not keep (`const` on a slice, alias names).
fn renderTy(v: *const View, o: *Out, ty: Ty, hint: ?ast.TypeRef) void {
    if (hint) |h| if (isAliasRef(v, h, ty)) return renderRef(o, h);
    switch (ty) {
        .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .f32, .f64, .bool, .byte, .usize, .isize, .addr, .void => o.s(@tagName(ty)),
        .small_int => |si| o.s(sema.smallIntName(si)),
        .text => o.s("Text"),
        .rune => o.s("Rune"),
        .system => o.s("System"),
        .file_sys => o.s("FileSys"),
        .net => o.s("Net"),
        .clock => o.s("Clock"),
        .gpu => o.s("Gpu"),
        .writer => o.s("Writer"),
        .reader => o.s("Reader"),
        .conn => o.s("Conn"),
        .text_buf => o.s("TextBuf"),
        .args => o.s("Args"),
        .thread_pool => o.s("ThreadPool"),
        .zone, .zone_handle => o.s("Zone"),
        .pointer, .const_ptr => |inner| {
            // `[*]T` is a pointer to the checker; the written type keeps the spelling.
            const many = if (hint) |h| h == .many_pointer else false;
            o.s(if (many) "[*]" else "*");
            if (ty == .const_ptr) o.s("const ");
            renderTy(v, o, inner.*, refInner(hint));
        },
        .optional => |inner| {
            o.s("?");
            renderTy(v, o, inner.*, refInner(hint));
        },
        .slice, .const_slice => |inner| {
            o.s(if (ty == .const_slice) "[]const " else "[]");
            renderTy(v, o, inner.*, refInner(hint));
        },
        .borrow => |inner| {
            o.s("borrow ");
            renderTy(v, o, inner.*, refInner(hint));
        },
        .array => |arr| {
            o.f("[{d}]", .{arr.len});
            renderTy(v, o, arr.elem.*, refInner(hint));
        },
        .range => |inner| {
            o.s("Range(");
            renderTy(v, o, inner.*, null);
            o.s(")");
        },
        .list => |inner| {
            o.s("List(");
            renderTy(v, o, inner.*, null);
            o.s(")");
        },
        .map => |inner| {
            o.s("Map(");
            renderTy(v, o, inner.*, null);
            o.s(")");
        },
        .named => |id| renderNamed(v, o, id),
        .generic_app => |g| {
            o.s(v.syms.symbol(g.template).name);
            o.s("(");
            for (g.args, 0..) |arg, i| {
                if (i > 0) o.s(", ");
                renderTy(v, o, arg, null);
            }
            o.s(")");
        },
        .null_ptr => o.s("null"),
        .type_param => |n| if (!o.param(n)) o.s(n),
        .error_set => |variants| {
            o.s("{ ");
            for (variants, 0..) |variant, i| {
                if (i > 0) o.s(", ");
                o.s(".");
                o.s(variant.name);
            }
            o.s(" }");
        },
        .fallible => |fl| {
            renderTy(v, o, fl.ok.*, hint);
            o.s(" !");
            if (fl.err.* != .error_ty) {
                o.s(" ");
                renderTy(v, o, fl.err.*, null);
            }
        },
        .fn_ptr => |fp| {
            if (fp.thin) o.s("extern ");
            o.s("fn(");
            for (fp.params, 0..) |p, i| {
                if (i > 0) o.s(", ");
                renderTy(v, o, p, null);
            }
            o.s(")");
            if (fp.ret.* != .void) {
                o.s(" -> ");
                renderTy(v, o, fp.ret.*, null);
            }
        },
        // An unsuffixed literal takes its type from where it goes, else these defaults.
        .int_lit => o.s("i32"),
        .float_lit => o.s("f64"),
        .unknown => o.s("unknown"),
        .error_ty => o.s("error"),
    }
}

fn tyText(v: *const View, ty: Ty, hint: ?ast.TypeRef) []const u8 {
    var o = Out{ .a = v.a };
    renderTy(v, &o, ty, hint);
    return o.list.items;
}

/// In `recv.name(...)` the receiver fills the first value parameter (`self`), and a type
/// parameter with a constraint is inferred: neither is written in the call.
fn notWrittenInMethodCall(constraints: []const ast.TypeConstraint, name: []const u8, is_type_param: bool, receiver_done: *bool) bool {
    if (is_type_param) {
        for (constraints) |tc| if (std.mem.eql(u8, tc.param, name)) return true;
        return false;
    }
    if (receiver_done.*) return false;
    receiver_done.* = true;
    return true;
}

/// `(a: i32, b: i32) -> i32 ! Err` of a callable. The byte ranges of the parameters are
/// appended to `ranges` when it is given.
fn renderParams(v: *const View, o: *Out, c: Callable, ranges: ?*std.ArrayList([2]usize)) void {
    const saved = o.subst;
    defer o.subst = saved;
    if (c.owner) |ow| o.subst = substFor(v, ow);
    o.s("(");
    var n: usize = 0;
    var receiver_done = false;
    if (c.decl) |d| {
        for (d.params) |p| {
            if (c.drop_self and notWrittenInMethodCall(d.type_constraints, p.name, p.is_type_param, &receiver_done)) continue;
            if (n > 0) o.s(", ");
            const st = o.len();
            if (p.is_type_param) {
                o.s("$");
                o.s(p.name);
                o.s(": ");
                var constraint: []const u8 = "type";
                for (d.type_constraints) |tc| if (std.mem.eql(u8, tc.param, p.name)) {
                    constraint = tc.interface;
                };
                o.s(constraint);
            } else {
                o.s(p.name);
                o.s(": ");
                if (p.ty == .type_param) o.s("$");
                renderRef(o, p.ty);
            }
            if (ranges) |r| r.append(v.a, .{ st, o.len() }) catch {};
            n += 1;
        }
        if (d.is_variadic) o.s(if (n > 0) ", ..." else "...");
        o.s(")");
        if (!isVoidRef(d.return_ty)) {
            o.s(" -> ");
            renderRef(o, d.return_ty);
        }
        if (d.error_ty) |e| renderErrorSpec(o, e);
        return;
    }
    if (c.iface) |m| {
        for (m.params) |p| {
            if (c.drop_self and notWrittenInMethodCall(&.{}, p.name, p.is_type_param, &receiver_done)) continue;
            if (n > 0) o.s(", ");
            const st = o.len();
            o.s(p.name);
            o.s(": ");
            renderTy(v, o, p.ty, null);
            if (ranges) |r| r.append(v.a, .{ st, o.len() }) catch {};
            n += 1;
        }
        o.s(")");
        if (m.return_ty != .void) {
            o.s(" -> ");
            renderTy(v, o, m.return_ty, null);
        }
        if (m.error_ty) |e| {
            o.s(" ! ");
            renderTy(v, o, e, null);
        }
        return;
    }
    if (c.fn_ty) |t| switch (t) {
        .fn_ptr => |fp| {
            const written: ?ast.FnType = if (c.fn_hint) |h| switch (h) {
                .fn_type => |ft| if (ft.params.len == fp.params.len) ft else null,
                else => null,
            } else null;
            for (fp.params, 0..) |p, i| {
                if (i > 0) o.s(", ");
                const st = o.len();
                if (written) |w| renderRef(o, w.params[i]) else renderTy(v, o, p, null);
                if (ranges) |r| r.append(v.a, .{ st, o.len() }) catch {};
            }
            o.s(")");
            if (written) |w| {
                if (!isVoidRef(w.ret.*)) {
                    o.s(" -> ");
                    renderRef(o, w.ret.*);
                }
                if (w.error_ty) |e| renderErrorSpec(o, e);
            } else if (fp.ret.* != .void) {
                o.s(" -> ");
                renderTy(v, o, fp.ret.*, null);
            }
            return;
        },
        else => {},
    };
    o.s(")");
}

/// `name :: fn(...) -> R`, for hover and completion details.
fn fnText(v: *const View, c: Callable, name: []const u8) []const u8 {
    var o = Out{ .a = v.a };
    if (name.len > 0) {
        o.s(name);
        o.s(" :: ");
    }
    o.s("fn");
    renderParams(v, &o, c, null);
    return o.list.items;
}

fn memberDetail(v: *const View, m: Member) []const u8 {
    return switch (m.kind) {
        .field, .builtin => tyText(v, m.ty orelse .unknown, m.hint),
        .variant => if (m.ty) |p| tyText(v, p, null) else v.syms.symbol(m.owner.?).name,
        .method, .ext, .assoc, .iface => fnText(v, (memberVal(v, m) orelse return "").callable, ""),
    };
}

// Expected types for an enum literal

/// The enum (or error set) type behind a type: through `?` and pointers.
fn enumOf(v: *const View, ty: Ty) ?SymbolId {
    const id = switch (ty) {
        .named => |id| id,
        .optional, .pointer, .const_ptr => |inner| return enumOf(v, inner.*),
        else => return null,
    };
    const layout = v.env.layouts.get(id) orelse return null;
    return switch (layout.kind) {
        .variant_type, .error_set => id,
        else => null,
    };
}

fn valueType(val: Val) ?Ty {
    return switch (val) {
        .value => |t| t.ty,
        .type_sym => |id| .{ .named = id },
        else => null,
    };
}

/// The function whose body holds `pos` (in the analysis's text of the document).
fn enclosingFn(v: *const View, pos: usize) ?ast.FunctionDecl {
    var best: ?ast.FunctionDecl = null;
    for (v.an.module.items) |item| switch (item) {
        .function => |f| {
            if (!sameText(f.file_name, v.path)) continue;
            const body = f.body orelse continue;
            if (pos < body.span.start or pos > body.span.end) continue;
            if (best == null or body.span.start >= best.?.body.?.span.start) best = f;
        },
        else => {},
    };
    return best;
}

fn expectedEnum(v: *const View, ctx: EnumCtx, code: []const u8, pos: usize) ?SymbolId {
    switch (ctx) {
        .compare, .assign, .match_arm => |chain| {
            const val = resolveChain(v, &chain, pos) orelse return null;
            return enumOf(v, valueType(val) orelse return null);
        },
        .typed => |text| {
            var t = text;
            while (t.len > 0 and (t[0] == '?' or t[0] == '*')) t = std.mem.trimStart(u8, t[1..], " ");
            if (std.mem.indexOf(u8, t, "::")) |i| {
                const id = v.syms.resolveScoped(v.path, std.mem.trim(u8, t[0..i], " "), std.mem.trim(u8, t[i + 2 ..], " ")) orelse return null;
                return enumOf(v, .{ .named = id });
            }
            const id = v.syms.resolveVisible(v.path, t) orelse return null;
            if (v.syms.symbol(id).kind != .type) return null;
            return enumOf(v, .{ .named = id });
        },
        .arg => |call| {
            const c = calleeAt(v, code, call.paren) orelse return null;
            const ty = paramType(v, c, call.active) orelse return null;
            return enumOf(v, ty);
        },
        .ret => {
            const f = enclosingFn(v, pos) orelse return null;
            const id = refTypeId(v, f.file_name, f.return_ty) orelse return null;
            return enumOf(v, .{ .named = id });
        },
    }
}

/// The type of the parameter at argument index `index` of a call.
fn paramType(v: *const View, c: Callable, index: usize) ?Ty {
    var params: []const sema.ParamSig = &.{};
    var constraints: []const ast.TypeConstraint = &.{};
    if (c.sym) |id| {
        if (v.env.fn_sigs.get(id)) |sig| {
            params = sig.params;
            constraints = sig.type_constraints;
        }
    } else if (c.iface) |m| {
        params = m.params;
    } else if (c.fn_ty) |t| switch (t) {
        .fn_ptr => |fp| return if (index < fp.params.len) fp.params[index] else null,
        else => return null,
    };
    var i: usize = 0;
    var receiver_done = false;
    for (params) |p| {
        if (c.drop_self and notWrittenInMethodCall(constraints, p.name, p.is_type_param, &receiver_done)) continue;
        if (i == index) return p.ty;
        i += 1;
    }
    return null;
}

// Requests

fn itemJson(o: *Out, first: *bool, label: []const u8, kind: u8, detail: ?[]const u8, sort: ?[]const u8) void {
    itemJsonExtra(o, first, label, kind, detail, sort, null);
}

/// A completion item; `extra` is more JSON members (`"name":value`) to add.
fn itemJsonExtra(o: *Out, first: *bool, label: []const u8, kind: u8, detail: ?[]const u8, sort: ?[]const u8, extra: ?[]const u8) void {
    if (!first.*) o.s(",");
    first.* = false;
    o.s("{\"label\":\"");
    o.esc(label);
    o.f("\",\"kind\":{d}", .{kind});
    if (detail) |d| if (d.len > 0) {
        o.s(",\"detail\":\"");
        o.esc(d);
        o.s("\"");
    };
    if (sort) |st| {
        o.s(",\"sortText\":\"");
        o.esc(st);
        o.s("\"");
    }
    if (extra) |x| {
        o.s(",");
        o.s(x);
    }
    o.s("}");
}

/// A member's completion item: its call as a snippet (`as_call`), its parameters beside its name,
/// and the comment above its declaration.
fn memberItem(v: *const View, o: *Out, first: *bool, m: Member, sort: []const u8, raw: ?[]const u8, as_call: bool) void {
    if (!first.*) o.s(",");
    first.* = false;
    o.s("{\"label\":\"");
    o.esc(m.name);
    o.f("\",\"kind\":{d}", .{memberKind(m.kind)});
    const detail = memberDetail(v, m);
    var extra: lsp.ItemExtra = .{ .sort = sort, .documentation = memberDoc(v, m) };
    if (detail.len > 0) extra.detail = detail;
    switch (m.kind) {
        .method, .ext, .assoc, .iface => {
            // `fn(by: i32) -> Point` beside the name as `(by: i32) -> Point`
            if (std.mem.startsWith(u8, detail, "fn")) extra.label_detail = detail[2..];
            if (as_call) extra.snippet = memberSnippet(v, m);
        },
        else => {},
    }
    lsp.appendItemExtra(&o.list, o.a, extra);
    if (raw) |x| {
        o.s(",");
        o.s(x);
    }
    o.s("}");
}

/// A call of the method or function `m` as a snippet, a tab stop at each argument: the receiver
/// is left out of a method called on a value.
fn memberSnippet(v: *const View, m: Member) ?[]const u8 {
    const c = switch (memberVal(v, m) orelse return null) {
        .callable => |c| c,
        else => return null,
    };
    if (c.decl) |decl| return lsp_snippets.callSnippet(v.a, m.name, lsp_snippets.callArgs(v.a, decl, c.drop_self), decl.is_variadic);
    if (c.iface) |im| {
        var names = std.ArrayList([]const u8).empty;
        for (im.params, 0..) |p, i| {
            if (c.drop_self and i == 0) continue;
            names.append(v.a, p.name) catch {};
        }
        return lsp_snippets.callSnippet(v.a, m.name, names.items, false);
    }
    return null;
}

/// The comment above a member's declaration: a method's or function's, a field's or a variant's.
fn memberDoc(v: *const View, m: Member) ?[]const u8 {
    switch (m.kind) {
        .method, .ext, .assoc, .iface => {
            const decl = m.decl orelse (if (m.sym) |sid| fnDecl(v, sid) else null) orelse return null;
            return lsp_snippets.docComment(v.a, decl.source, decl.span.start);
        },
        .field, .variant => {
            const owner = m.owner orelse return null;
            const td = typeDecl(v, owner) orelse return null;
            const file = v.an.fileNamed(td.file_name) orelse return null;
            const at: usize = switch (td.kind) {
                .struct_type => |st| for (st.fields) |f| {
                    if (std.mem.eql(u8, f.name, m.name)) break f.span.start;
                } else return null,
                .enum_type => |et| for (et.variants) |variant| {
                    if (std.mem.eql(u8, variant.name, m.name)) break variant.span.start;
                } else return null,
                else => return null,
            };
            return lsp_snippets.docComment(v.a, file.source, at);
        },
        .builtin => return null,
    }
}

fn memberKind(k: MemberKind) u8 {
    return switch (k) {
        .field, .builtin => 5, // Field
        .method, .iface => 2, // Method
        .ext, .assoc => 3, // Function
        .variant => 20, // EnumMember
    };
}

/// The members after the `.` at `dot` (an offset in the current text).
fn listMembers(v: *const View, val: Val, dot: usize, o: *Out, first: *bool, as_call: bool) void {
    var list = MemberList{};
    switch (val) {
        .value => |t| collectMembers(v, t.ty, false, &list),
        .type_sym => |id| collectMembers(v, .{ .named = id }, true, &list),
        else => return,
    }
    // An associated function is called as `Type::name(...)`: choosing one after `Type.`
    // also turns the `.` into `::`.
    var to_colons = Out{ .a = v.a };
    {
        const s = lsp.byteToPos(v.new, dot);
        to_colons.f("\"additionalTextEdits\":[{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"newText\":\"::\"}}]", .{ s.line, s.char, s.line, s.char + 1 });
    }
    for (list.items.items) |m| {
        if (val == .type_sym and m.kind == .assoc) {
            var key = Out{ .a = v.a };
            key.s("2");
            key.s(m.name);
            memberItem(v, o, first, m, key.list.items, to_colons.list.items, as_call);
            continue;
        }
        // Fields first, then methods, then the rest.
        const sort: []const u8 = switch (m.kind) {
            .field, .variant => "1",
            .method, .iface, .assoc => "2",
            .builtin => "3",
            .ext => "4",
        };
        var key = Out{ .a = v.a };
        key.s(sort);
        key.s(m.name);
        memberItem(v, o, first, m, key.list.items, null, as_call);
    }
}

fn onImportLine(text: []const u8, at: usize) bool {
    var s = @min(at, text.len);
    while (s > 0 and text[s - 1] != '\n') s -= 1;
    const line = std.mem.trimStart(u8, text[s..@min(at, text.len)], " \t");
    return std.mem.startsWith(u8, line, "#import");
}

/// Completion after a `.`: the members of the receiver's type, or the variants of the
/// expected enum for a `.` that starts an enum literal. Returns false when the cursor does
/// not follow a `.`, so the caller answers with the names in scope.
pub fn completeMember(self: *lsp.Server, doc: *lsp.Doc, id: ?json.Value, params: json.Value) bool {
    const off = lsp.cursorOffset(doc, params) orelse return false;
    const text = doc.text;
    var start = @min(off, text.len);
    while (start > 0 and isIdentChar(text[start - 1])) start -= 1;
    if (start >= 2 and text[start - 1] == ':' and text[start - 2] == ':') return completeAssoc(self, doc, id, start - 2);
    if (start == 0 or text[start - 1] != '.') return false;
    if (start >= 2 and text[start - 2] == '.') return false; // a range `a..b`
    if (onImportLine(text, start)) return false;

    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const code = codeBefore(a, text, start) catch return false;
    if (code.in_literal) {
        lsp.sendResult(self, id, "[]");
        return true;
    }
    var o = Out{ .a = a };
    o.s("[");
    var first = true;
    // a call written already keeps its `(`
    const as_call = self.snippet_support and !lsp_snippets.parenFollows(text, lsp.identRangeAt(text, off).end);
    if (viewOf(doc, a)) |view| {
        const v = &view;
        const dot = start - 1;
        const pos = v.map.anchor(dot);
        if (chainBefore(code.text, dot)) |chain| {
            if (resolveChain(v, &chain, pos)) |val| listMembers(v, val, dot, &o, &first, as_call);
        } else if (enumContext(code.text, dot)) |ctx| {
            if (expectedEnum(v, ctx, code.text, pos)) |eid| {
                var list = MemberList{};
                collectMembers(v, .{ .named = eid }, true, &list);
                for (list.items.items) |m| if (m.kind == .variant)
                    itemJson(&o, &first, m.name, 20, memberDetail(v, m), null);
            }
        }
    }
    o.s("]");
    lsp.sendResult(self, id, o.list.items);
    return true;
}

/// Completion after `Type::`: the type's associated functions. An import alias before the
/// `::` is left to the caller (it lists the module's public names).
fn completeAssoc(self: *lsp.Server, doc: *lsp.Doc, id: ?json.Value, colons: usize) bool {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const code = codeBefore(a, doc.text, colons) catch return false;
    const view = viewOf(doc, a) orelse return false;
    const v = &view;
    const chain = chainBefore(code.text, colons) orelse return false;
    const tid = switch (resolveChain(v, &chain, v.map.anchor(colons)) orelse return false) {
        .type_sym => |t| t,
        else => return false,
    };
    var o = Out{ .a = a };
    o.s("[");
    var first = true;
    const as_call = self.snippet_support and !lsp_snippets.parenFollows(doc.text, lsp.identRangeAt(doc.text, colons + 2).end);
    var list = MemberList{};
    typeFunctions(v, tid, false, &list);
    for (list.items.items) |m| memberItem(v, &o, &first, m, m.name, null, as_call);
    o.s("]");
    lsp.sendResult(self, id, o.list.items);
    return true;
}

/// Add the locals visible at the cursor to a completion list, with their types.
pub fn addLocalNames(
    self: *lsp.Server,
    doc: *lsp.Doc,
    params: json.Value,
    b: *std.ArrayList(u8),
    seen: *std.StringHashMapUnmanaged(void),
    first: *bool,
) void {
    const off = lsp.cursorOffset(doc, params) orelse return;
    const word = lsp.identRangeAt(doc.text, off);
    if (word.start >= 2 and std.mem.eql(u8, doc.text[word.start - 2 .. word.start], "::")) return;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const view = viewOf(doc, arena.allocator()) orelse return;
    const v = &view;
    const pos = v.map.anchor(word.start);
    // The innermost declaration of each name wins, as in `localAt`.
    var best = std.StringHashMapUnmanaged(*const sema.LocalBinding){};
    for (v.env.local_bindings.items) |*lb| {
        if (!sameText(lb.file, v.path) or lb.name.len == 0 or lb.name[0] == '_') continue;
        const from = visibleFrom(lb.*);
        if (pos < from or pos >= lb.scope_end) continue;
        const gop = best.getOrPut(v.a, lb.name) catch continue;
        if (!gop.found_existing or visibleFrom(gop.value_ptr.*.*) <= from) gop.value_ptr.* = lb;
    }
    var it = best.valueIterator();
    while (it.next()) |lb| {
        const detail = tyText(v, lb.*.ty, bindingHint(v, lb.*.*, 0));
        lsp.appendCompletionItem(self, b, seen, first, lb.*.name, 6, detail);
    }
}

fn hoverJson(o: *Out, code_text: []const u8, note: ?[]const u8) void {
    hoverDocJson(o, code_text, null, note);
}

/// A hover: the declaration as code, its documentation, and a note (where it is from).
fn hoverDocJson(o: *Out, code_text: []const u8, doc_text: ?[]const u8, note: ?[]const u8) void {
    o.s("{\"contents\":{\"kind\":\"markdown\",\"value\":\"```fels\\n");
    o.esc(code_text);
    o.s("\\n```");
    if (doc_text) |d| {
        o.s("\\n\\n");
        o.esc(d);
    }
    if (note) |n| {
        o.s("\\n\\n");
        o.esc(n);
    }
    o.s("\"}}");
}

/// Hover on a local, a parameter or a member (`name: Type`), and on anything while the text
/// does not parse. Returns false to let the caller answer (top-level names).
pub fn hover(self: *lsp.Server, doc: *lsp.Doc, id: ?json.Value, params: json.Value) bool {
    const off = lsp.cursorOffset(doc, params) orelse return false;
    const r = lsp.identRangeAt(doc.text, off);
    if (r.end <= r.start) return false;
    const name = doc.text[r.start..r.end];
    if (std.ascii.isDigit(name[0])) return false;

    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const view = viewOf(doc, a) orelse return false;
    const v = &view;
    const code = codeBefore(a, doc.text, r.start) catch return false;
    if (code.in_literal) return false;
    var o = Out{ .a = a };

    // `recv.name`, and `Type::name`
    const k = skipSpaceBack(code.text, r.start);
    const after_dot = k > 0 and code.text[k - 1] == '.' and !(k >= 2 and code.text[k - 2] == '.');
    const after_scope = k >= 2 and code.text[k - 1] == ':' and code.text[k - 2] == ':';
    const type_scope: ?SymbolId = if (after_scope) blk: {
        const chain = chainBefore(code.text, k - 2) orelse break :blk null;
        break :blk switch (resolveChain(v, &chain, v.map.anchor(k - 2)) orelse break :blk null) {
            .type_sym => |t| t,
            else => null,
        };
    } else null;
    if (after_dot or type_scope != null) {
        const val: Val = if (type_scope) |t| .{ .type_sym = t } else blk: {
            const chain = chainBefore(code.text, k - 1) orelse return false;
            break :blk resolveChain(v, &chain, v.map.anchor(k - 1)) orelse return false;
        };
        const m = switch (val) {
            .value => |t| memberNamed(v, t.ty, name, false),
            .type_sym => |tid| memberNamed(v, .{ .named = tid }, name, true),
            else => null,
        } orelse return false;
        switch (m.kind) {
            .field, .builtin => {
                const text = std.fmt.allocPrint(a, "{s}: {s}", .{ name, memberDetail(v, m) }) catch return false;
                const note: ?[]const u8 = if (m.owner) |ow| (std.fmt.allocPrint(a, "field of `{s}`", .{tyText(v, .{ .named = ow }, null)}) catch null) else null;
                hoverDocJson(&o, text, memberDoc(v, m), note);
            },
            .variant => {
                const owner = v.syms.symbol(m.owner.?).name;
                const text = if (m.ty) |p|
                    std.fmt.allocPrint(a, "{s}.{s}({s})", .{ owner, name, tyText(v, p, null) }) catch return false
                else
                    std.fmt.allocPrint(a, "{s}.{s}", .{ owner, name }) catch return false;
                hoverDocJson(&o, text, memberDoc(v, m), null);
            },
            .method, .ext, .assoc, .iface => {
                const c = (memberVal(v, m) orelse return false).callable;
                var full = c;
                full.drop_self = false;
                const label = if (m.sym) |sid| v.syms.symbol(sid).name else name;
                const note: ?[]const u8 = if (m.kind == .iface)
                    (std.fmt.allocPrint(a, "method of interface `{s}`", .{v.syms.symbol(m.owner.?).name}) catch null)
                else
                    null;
                hoverDocJson(&o, fnText(v, full, label), memberDoc(v, m), note);
            },
        }
        lsp.sendResult(self, id, o.list.items);
        return true;
    }

    // A local or a parameter.
    if (!after_scope) {
        const pos = v.map.anchor(r.start);
        if (localAt(v, name, pos, v.map.toOld(r.start))) |b| {
            const text = std.fmt.allocPrint(a, "{s}: {s}", .{ name, tyText(v, b.ty, bindingHint(v, b.*, 0)) }) catch return false;
            hoverJson(&o, text, null);
            lsp.sendResult(self, id, o.list.items);
            return true;
        }
    }
    if (!v.stale) return false;

    // The text does not parse: answer for top-level names from the last good analysis.
    var sid: ?SymbolId = null;
    if (after_scope) {
        const alias = wordBefore(code.text, k - 2);
        sid = v.syms.resolveScoped(v.path, alias, name);
    } else {
        sid = v.syms.resolveVisible(v.path, name);
    }
    const sym = v.syms.symbol(sid orelse return false);
    const file = v.an.fileNamed(sym.file_name) orelse return false;
    const decl = lsp.declarationText(v.an.*, sym, file.source);
    const note: ?[]const u8 = if (!sameText(sym.file_name, v.path))
        (std.fmt.allocPrint(a, "from `{s}`", .{lsp.moduleLabel(sym.file_name)}) catch null)
    else
        null;
    hoverDocJson(&o, decl, lsp_snippets.docComment(a, file.source, sym.span.start), note);
    lsp.sendResult(self, id, o.list.items);
    return true;
}

/// The function a call's `(` at `paren` calls.
fn calleeAt(v: *const View, code: []const u8, paren: usize) ?Callable {
    const chain = chainBefore(code, paren) orelse return null;
    const val = resolveChain(v, &chain, v.map.anchor(paren)) orelse return null;
    switch (val) {
        .callable => |c| return c,
        .value => |t| if (t.ty == .fn_ptr) {
            const name = if (chain.len > 0) switch (chain.buf[chain.len - 1]) {
                .field, .scope => |n| n,
                else => chain.base,
            } else chain.base;
            return .{ .name = name, .fn_ty = t.ty, .fn_hint = t.hint };
        },
        else => {},
    }
    return null;
}

fn utf16Len(text: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const seq = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            n += 1;
            i += 1;
            continue;
        };
        n += if (seq == 4) 2 else 1;
        i += seq;
    }
    return n;
}

pub fn handleSignatureHelp(self: *lsp.Server, id: ?json.Value, params: json.Value) void {
    const doc = lsp.docFromParams(self, params) orelse return lsp.sendResult(self, id, "null");
    const off = lsp.cursorOffset(doc, params) orelse return lsp.sendResult(self, id, "null");
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const view = viewOf(doc, a) orelse return lsp.sendResult(self, id, "null");
    const v = &view;
    const code = codeBefore(a, doc.text, off) catch return lsp.sendResult(self, id, "null");

    var at = off;
    var tries: usize = 0;
    while (tries < 4) : (tries += 1) {
        const call = callBefore(code.text, at) orelse break;
        if (calleeAt(v, code.text, call.paren)) |c| {
            var label = Out{ .a = a };
            label.s(c.name);
            var ranges = std.ArrayList([2]usize).empty;
            renderParams(v, &label, c, &ranges);
            var o = Out{ .a = a };
            o.s("{\"signatures\":[{\"label\":\"");
            o.esc(label.list.items);
            o.s("\",\"parameters\":[");
            for (ranges.items, 0..) |rg, i| {
                if (i > 0) o.s(",");
                const s16 = utf16Len(label.list.items[0..rg[0]]);
                const e16 = s16 + utf16Len(label.list.items[rg[0]..rg[1]]);
                o.f("{{\"label\":[{d},{d}]}}", .{ s16, e16 });
            }
            o.f("],\"activeParameter\":{d}}}],\"activeSignature\":0,\"activeParameter\":{d}}}", .{ call.active, call.active });
            return lsp.sendResult(self, id, o.list.items);
        }
        at = call.paren;
    }
    lsp.sendResult(self, id, "null");
}

fn rangeOffsets(text: []const u8, params: json.Value) ?[2]usize {
    const range = lsp.objGet(params, "range") orelse return null;
    const s = lsp.objGet(range, "start") orelse return null;
    const e = lsp.objGet(range, "end") orelse return null;
    const sl: u32 = @intCast(@max(0, lsp.getInt(s, "line") orelse return null));
    const sc: u32 = @intCast(@max(0, lsp.getInt(s, "character") orelse return null));
    const el: u32 = @intCast(@max(0, lsp.getInt(e, "line") orelse return null));
    const ec: u32 = @intCast(@max(0, lsp.getInt(e, "character") orelse return null));
    return .{ lsp.posToByte(text, sl, sc), lsp.posToByte(text, el, ec) };
}

/// The LSP position of `off` in `text`, given the starts of its lines.
fn posIn(text: []const u8, starts: []const usize, off: usize) lsp.Pos {
    const line = TextMap.lineOf(starts, off);
    const col = lsp.byteToPos(text[starts[line]..], off - starts[line]).char;
    return .{ .line = @intCast(line), .char = col };
}

/// Inlay hints: the type after a name declared with `:=` and after `for`, `match`, `if` and
/// `while` capture names. Positions are in the current text; with the last good analysis
/// only names on lines that map exactly get a hint.
pub fn handleInlayHint(self: *lsp.Server, id: ?json.Value, params: json.Value) void {
    const doc = lsp.docFromParams(self, params) orelse return lsp.sendResult(self, id, "[]");
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const range = rangeOffsets(doc.text, params) orelse [2]usize{ 0, doc.text.len };
    const view = viewOf(doc, a) orelse return lsp.sendResult(self, id, "[]");
    const v = &view;
    const starts = if (v.map.new_starts.len > 0) v.map.new_starts else (TextMap.lineStarts(a, v.new) catch return lsp.sendResult(self, id, "[]"));

    var o = Out{ .a = a };
    o.s("[");
    var first = true;
    var done = std.AutoHashMapUnmanaged(usize, void){};
    for (v.env.local_bindings.items) |b| {
        if (!sameText(b.file, v.path)) continue;
        switch (b.kind) {
            .local_val, .for_binding, .case_binding => {},
            else => continue,
        }
        if (b.name.len == 0 or b.name[0] == '_') continue;
        switch (b.ty) {
            .unknown, .error_ty, .void => continue,
            else => {},
        }
        const ns = bindingNameStart(v.old, b) orelse continue;
        const span = v.map.spanToNew(ns, ns + b.name.len) orelse continue;
        if (span[1] > v.new.len or !wordAt(v.new, span[0], b.name)) continue;
        if (span[1] < range[0] or span[0] > range[1]) continue;
        const gop = done.getOrPut(a, span[1]) catch continue;
        if (gop.found_existing) continue;
        const pos = posIn(v.new, starts, span[1]);
        if (!first) o.s(",");
        first = false;
        o.f("{{\"position\":{{\"line\":{d},\"character\":{d}}},\"label\":\"", .{ pos.line, pos.char });
        o.s(": ");
        o.esc(tyText(v, b.ty, bindingHint(v, b, 0)));
        o.s("\",\"kind\":1}");
    }
    o.s("]");
    lsp.sendResult(self, id, o.list.items);
}

// Tests

const testing = std.testing;

fn chainOf(text: []const u8) ?Chain {
    return chainBefore(text, text.len);
}

test "lsp assist: receiver chains before a dot" {
    {
        const c = chainOf("x := a.b.c").?;
        try testing.expectEqualStrings("a", c.base);
        try testing.expectEqual(@as(usize, 2), c.len);
        try testing.expectEqualStrings("b", c.buf[0].field);
        try testing.expectEqualStrings("c", c.buf[1].field);
    }
    {
        const c = chainOf("    f(1, g(2)).items[i + 1]").?;
        try testing.expectEqualStrings("f", c.base);
        try testing.expectEqual(@as(usize, 3), c.len);
        try testing.expect(c.buf[0] == .call);
        try testing.expectEqualStrings("items", c.buf[1].field);
        try testing.expect(c.buf[2] == .index);
    }
    {
        const c = chainOf("ns::make()?.list[2..4]!!").?;
        try testing.expectEqualStrings("ns", c.base);
        try testing.expectEqualStrings("make", c.buf[0].scope);
        try testing.expect(c.buf[1] == .call);
        try testing.expect(c.buf[2] == .try_q);
        try testing.expectEqualStrings("list", c.buf[3].field);
        try testing.expect(c.buf[4] == .slice);
        try testing.expect(c.buf[5] == .unwrap);
    }
    {
        // A chain over several lines.
        const c = chainOf("builder\n    .add(1)\n    ").?;
        try testing.expectEqualStrings("builder", c.base);
        try testing.expectEqual(@as(usize, 2), c.len);
    }
    try testing.expect(chainOf("x := 1") == null); // a number
    try testing.expect(chainOf("return") == null); // a keyword
    try testing.expect(chainOf("(a + b)") == null); // a group, not a call
    try testing.expect(chainOf("x == ") == null);
    try testing.expect(chainOf("0..n") != null); // `n` after a range is a name
    try testing.expectEqualStrings("n", chainOf("0..n").?.base);
}

test "lsp assist: comments and literals are blanked before scanning" {
    const a = testing.allocator;
    const src = "f(\"a, (b\", 'c', x) // g(\n";
    const code = try codeBefore(a, src, src.len);
    defer a.free(code.text);
    try testing.expect(!code.in_literal);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, code.text, ","));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, code.text, "("));
    try testing.expectEqual(src.len, code.text.len);
    const open = try codeBefore(a, "x := \"abc.", 10);
    defer a.free(open.text);
    try testing.expect(open.in_literal);
    const comment = try codeBefore(a, "y // p.", 7);
    defer a.free(comment.text);
    try testing.expect(comment.in_literal);
}

test "lsp assist: the call around the cursor, with nested brackets and strings" {
    const a = testing.allocator;
    const cases = [_]struct { src: []const u8, paren: ?usize, active: usize }{
        .{ .src = "add(1, ", .paren = 3, .active = 1 },
        .{ .src = "add(g(1, 2), h[3, 4], ", .paren = 3, .active = 2 },
        .{ .src = "add(\"x, y\", ", .paren = 3, .active = 1 },
        .{ .src = "add(1, g(2, ", .paren = 8, .active = 1 },
        .{ .src = "f(.{ .a = 1, .b = 2 }, ", .paren = 1, .active = 1 },
        .{ .src = "f(.{ .a = 1, ", .paren = 1, .active = 0 },
        .{ .src = "f(xs[1, ", .paren = 1, .active = 0 },
        .{ .src = "f(1); g", .paren = null, .active = 0 },
        .{ .src = "fn() { x", .paren = null, .active = 0 },
    };
    for (cases) |cs| {
        const code = try codeBefore(a, cs.src, cs.src.len);
        defer a.free(code.text);
        const got = callBefore(code.text, code.text.len);
        if (cs.paren) |p| {
            try testing.expect(got != null);
            try testing.expectEqual(p, got.?.paren);
            try testing.expectEqual(cs.active, got.?.active);
        } else try testing.expect(got == null);
    }
}

test "lsp assist: the expected type of an enum literal" {
    try testing.expect(enumContext("if m == ", 8).? == .compare);
    try testing.expect(enumContext("m != ", 5).? == .compare);
    try testing.expectEqualStrings("Color", enumContext("c: Color = ", 11).?.typed);
    try testing.expect(enumContext("p.mode = ", 9).? == .assign);
    try testing.expect(enumContext("paint(1, ", 9).? == .arg);
    try testing.expect(enumContext("    return ", 11).? == .ret);
    try testing.expectEqualStrings("m", enumContext("match m {\n    ", 14).?.match_arm.base);
    try testing.expect(enumContext("x := ", 5) == null);
}

test "lsp assist: positions map across an edit" {
    const old = "main :: fn() {\n    p := 1;\n}\nnext :: fn() {}\n";
    const new = "main :: fn() {\n    p := 1;\n    p.\n}\nnext :: fn() {}\n";
    const m = diffTexts(old, new);
    const edit = std.mem.indexOf(u8, new, "p.\n").?;
    try testing.expect(m.prefix <= edit);
    // Before the edit nothing moves.
    const p_decl = std.mem.indexOf(u8, old, "p :=").?;
    try testing.expectEqual(@as(?usize, p_decl), m.toOld(p_decl));
    try testing.expectEqual(@as(?[2]usize, .{ p_decl, p_decl + 1 }), m.spanToNew(p_decl, p_decl + 1));
    // After it, everything shifts by the inserted length.
    const next_old = std.mem.indexOf(u8, old, "next").?;
    const next_new = std.mem.indexOf(u8, new, "next").?;
    try testing.expectEqual(@as(?[2]usize, .{ next_new, next_new + 4 }), m.spanToNew(next_old, next_old + 4));
    try testing.expectEqual(@as(?usize, next_old), m.toOld(next_new));
    // Inside the edit there is no exact place; lookups use the start of the edit.
    try testing.expectEqual(@as(?usize, null), m.toOld(edit + 2));
    try testing.expectEqual(m.prefix, m.anchor(edit + 2));
    // An old range that the edit replaced has no new place.
    const m2 = diffTexts("a := 10;", "a := 2;");
    try testing.expectEqual(@as(?[2]usize, null), m2.spanToNew(5, 7));
    try testing.expect(Mapping.identity(5).same());
}

test "lsp assist: lines map across several separate edits" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const old = "main :: fn() {\n    a := 1;\n    b := 2;\n    c := 3;\n    d := 4;\n}\n";
    // A line inserted at the top, one changed in place in the middle, one at the bottom.
    const new = "main :: fn() {\n    // new\n    a := 1;\n    x := 2;\n    c := 3;\n    d := 4;\n    p.\n}\n";
    const m = TextMap.build(arena.allocator(), old, new);
    const c_old = std.mem.indexOf(u8, old, "c :=").?;
    const c_new = std.mem.indexOf(u8, new, "c :=").?;
    try testing.expectEqual(@as(?[2]usize, .{ c_new, c_new + 1 }), m.spanToNew(c_old, c_old + 1));
    try testing.expectEqual(@as(?usize, c_old), m.toOld(c_new));
    const d_old = std.mem.indexOf(u8, old, "d :=").?;
    const d_new = std.mem.indexOf(u8, new, "d :=").?;
    try testing.expectEqual(@as(?[2]usize, .{ d_new, d_new + 1 }), m.spanToNew(d_old, d_old + 1));
    // The changed line maps around its edit: `:= 2` is still there.
    const two_old = std.mem.indexOf(u8, old, "2;").?;
    const two_new = std.mem.indexOf(u8, new, "2;").?;
    try testing.expectEqual(@as(?[2]usize, .{ two_new, two_new + 1 }), m.spanToNew(two_old, two_old + 1));
    // The name that changed has no new place.
    const b_old = std.mem.indexOf(u8, old, "b :=").?;
    try testing.expectEqual(@as(?[2]usize, null), m.spanToNew(b_old, b_old + 1));
    // New lines map to nothing; a lookup there uses the end of the line before.
    const p_new = std.mem.indexOf(u8, new, "p.").?;
    try testing.expectEqual(@as(?usize, null), m.toOld(p_new));
    try testing.expectEqual(std.mem.indexOf(u8, old, "\n}").?, m.anchor(p_new));
    // Identical texts map to themselves.
    const same = TextMap.build(arena.allocator(), old, old);
    try testing.expectEqual(@as(?usize, 5), same.toOld(5));
}

test "lsp assist: the line diff matches as many lines as the longest common subsequence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    const words = [_][]const u8{ "a", "b", "c", "}", "x := 1;" };
    var round: usize = 0;
    while (round < 300) : (round += 1) {
        var old_lines: [12][]const u8 = undefined;
        var new_lines: [16][]const u8 = undefined;
        const n = r.uintLessThan(usize, 12);
        for (0..n) |i| old_lines[i] = words[r.uintLessThan(usize, words.len)];
        // Edit a copy: drop, change or add lines at random.
        var k: usize = 0;
        for (0..n) |i| {
            const what = r.uintLessThan(u8, 6);
            if (what == 0) continue; // dropped
            if (k < new_lines.len) {
                new_lines[k] = if (what == 1) words[r.uintLessThan(usize, words.len)] else old_lines[i];
                k += 1;
            }
            if (what == 2 and k < new_lines.len) {
                new_lines[k] = words[r.uintLessThan(usize, words.len)];
                k += 1;
            }
        }
        const old = try std.mem.join(a, "\n", old_lines[0..n]);
        const new = try std.mem.join(a, "\n", new_lines[0..k]);
        const m = TextMap.build(a, old, new);
        if (m.identical) continue;
        try testing.expect(m.new_starts.len > 0);
        // Matched lines are equal and in order.
        var matched: usize = 0;
        var last: i32 = -1;
        for (m.new_to_old, 0..) |e, j| {
            if (e < 0) continue;
            try testing.expect(e > last);
            last = e;
            try testing.expectEqualStrings(TextMap.line(old, m.old_starts, @intCast(e)), TextMap.line(new, m.new_starts, j));
            matched += 1;
        }
        // As many as the longest common subsequence.
        const ol = m.old_starts.len - 1;
        const nl = m.new_starts.len - 1;
        var dp = try a.alloc(usize, (ol + 1) * (nl + 1));
        @memset(dp, 0);
        for (0..ol) |i| for (0..nl) |j| {
            const same = std.mem.eql(u8, TextMap.line(old, m.old_starts, i), TextMap.line(new, m.new_starts, j));
            dp[(i + 1) * (nl + 1) + j + 1] = if (same) dp[i * (nl + 1) + j] + 1 else @max(dp[i * (nl + 1) + j + 1], dp[(i + 1) * (nl + 1) + j]);
        };
        try testing.expectEqual(dp[ol * (nl + 1) + nl], matched);
    }
}

test "lsp assist: where a recorded local's name is written" {
    const src = "f :: fn(count: i32, x: $T) {\n    for item, i in xs { }\n    if v |val| { }\n    y := 1;\n    r := g() catch err { };\n}\n";
    const param = sema.LocalBinding{ .name = "count", .file = "", .kind = .param, .decl = Span.new(15, 18), .scope_end = 0, .ty = .i32 };
    try testing.expectEqual(@as(?usize, 8), bindingNameStart(src, param));
    const xs = std.mem.indexOf(u8, src, "x: $T").?;
    const tparam = sema.LocalBinding{ .name = "x", .file = "", .kind = .param, .decl = Span.new(xs, xs + 5), .scope_end = 0, .ty = .i32 };
    try testing.expectEqual(@as(?usize, xs), bindingNameStart(src, tparam));
    const for_at = std.mem.indexOf(u8, src, "for").?;
    const idx = sema.LocalBinding{ .name = "i", .file = "", .kind = .for_binding, .decl = Span.new(for_at, for_at + 22), .scope_end = 0, .ty = .usize };
    try testing.expectEqual(@as(?usize, std.mem.indexOf(u8, src, "i in").?), bindingNameStart(src, idx));
    const if_at = std.mem.indexOf(u8, src, "if v").?;
    const cap = sema.LocalBinding{ .name = "val", .file = "", .kind = .case_binding, .decl = Span.new(if_at, if_at + 14), .scope_end = 0, .ty = .i32 };
    try testing.expectEqual(@as(?usize, std.mem.indexOf(u8, src, "val|").?), bindingNameStart(src, cap));
    const r_at = std.mem.indexOf(u8, src, "g() catch").?;
    const err = sema.LocalBinding{ .name = "err", .file = "", .kind = .try_error, .decl = Span.new(r_at, r_at + 20), .scope_end = 0, .ty = .i32 };
    try testing.expectEqual(@as(?usize, std.mem.indexOf(u8, src, "err {").?), bindingNameStart(src, err));
}
