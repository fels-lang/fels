//! `fels doc`: the reference of a library's public declarations, made from its `///` comments.
//!
//! `fels doc lib/std -o out` reads every `.fels` file below `lib/std`, and for each module writes
//! `out/<module>.md`: its `//!` comment, then each `pub` declaration with its signature and its
//! `///` comment. A struct shows its fields and its public methods, an enum or error set its
//! variants. `out/index.md` lists the modules. `--json` writes all of it to `out/doc.json`
//! instead, for a website or a tool to render.
//!
//! Only the parser runs, not the checker, so a module that does not type check is documented
//! all the same. A plain `//` comment is not documentation; a `///` one right above a
//! declaration is (see `lsp_snippets.docComment`, which hover uses too).

const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const pipeline = @import("pipeline.zig");
const snippets = @import("lsp_snippets.zig");

pub const Format = enum { markdown, json };

pub const Options = struct {
    /// Files and folders to document. A folder's name starts its modules' names
    /// (`lib/std/net/tcp.fels` is `std.net.tcp`).
    paths: []const []const u8,
    out_dir: []const u8 = "fels-doc",
    format: Format = .markdown,
};

/// One documented declaration.
pub const Entry = struct {
    kind: []const u8,
    name: []const u8,
    /// How it is declared: a function's head without its body, a struct with its fields.
    signature: []const u8,
    doc: ?[]const u8,
    /// A struct's fields, an enum's or error set's variants, an interface's methods.
    members: []const Member = &.{},
    /// A struct's public methods.
    methods: []const Entry = &.{},
};

pub const Member = struct {
    name: []const u8,
    doc: ?[]const u8,
};

pub const Module = struct {
    name: []const u8,
    path: []const u8,
    doc: ?[]const u8,
    entries: []const Entry,
};

pub fn cmd(a: std.mem.Allocator, io: std.Io, args: []const []const u8) u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    var opts: Options = .{ .paths = &.{} };
    var k: usize = 0;
    while (k < args.len) : (k += 1) {
        const arg = args[k];
        if ((std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--out")) and k + 1 < args.len) {
            k += 1;
            opts.out_dir = args[k];
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.format = .json;
        } else if (arg.len > 1 and arg[0] == '-') {
            std.debug.print("fels doc: unknown option '{s}'\n", .{arg});
            return 1;
        } else paths.append(a, arg) catch return 1;
    }
    if (paths.items.len == 0) paths.append(a, if (isDir(io, "src")) "src" else ".") catch return 1;
    opts.paths = paths.items;

    var modules: std.ArrayList(Module) = .empty;
    for (opts.paths) |path| {
        if (isDir(io, path)) {
            collectDir(a, io, path, &modules) catch return 1;
        } else {
            const name = pipeline.withoutExt(std.fs.path.basename(path));
            const m = documentFile(a, io, path, name) catch return 1;
            if (m) |mod| modules.append(a, mod) catch return 1;
        }
    }
    if (modules.items.len == 0) {
        std.debug.print("fels doc: no .fels files in {s}\n", .{opts.paths[0]});
        return 1;
    }

    std.Io.Dir.cwd().createDirPath(io, opts.out_dir) catch {
        std.debug.print("fels doc: cannot make the folder {s}\n", .{opts.out_dir});
        return 1;
    };
    const written = switch (opts.format) {
        .markdown => writeMarkdown(a, io, opts.out_dir, modules.items),
        .json => writeJson(a, io, opts.out_dir, modules.items),
    } catch {
        std.debug.print("fels doc: cannot write into {s}\n", .{opts.out_dir});
        return 1;
    };
    var count: usize = 0;
    for (modules.items) |m| count += m.entries.len;
    std.debug.print("documented {d} declarations in {d} modules: {d} file{s} in {s}\n", .{
        count, modules.items.len, written, if (written == 1) "" else "s", opts.out_dir,
    });
    return 0;
}

fn isDir(io: std.Io, path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

/// The modules of the `.fels` files below `dir`, in path order. `dir/build.fels` beside a
/// `fels.pkg` is the project's build script and is left out.
fn collectDir(a: std.mem.Allocator, io: std.Io, dir: []const u8, modules: *std.ArrayList(Module)) !void {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var walker = try d.walk(a);
    defer walker.deinit();
    var files: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !pipeline.isSourceFile(entry.basename)) continue;
        const rel = try a.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, rel, '\\', '/');
        if (std.mem.eql(u8, rel, "build.fels") and fileExists(io, try std.fs.path.join(a, &.{ dir, "fels.pkg" }))) continue;
        try files.append(a, rel);
    }
    std.mem.sort([]const u8, files.items, {}, lessThan);

    var base = std.fs.path.basename(std.mem.trimEnd(u8, dir, "/\\"));
    if (base.len == 0 or std.mem.eql(u8, base, ".")) base = "";
    for (files.items) |rel| {
        const dotted = try a.dupe(u8, pipeline.withoutExt(rel));
        std.mem.replaceScalar(u8, dotted, '/', '.');
        const name = if (base.len == 0) dotted else try std.fmt.allocPrint(a, "{s}.{s}", .{ base, dotted });
        const path = try std.fs.path.join(a, &.{ dir, rel });
        if (try documentFile(a, io, path, name)) |m| try modules.append(a, m);
    }
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// The module of one file, or null when it does not parse (the parser says why).
fn documentFile(a: std.mem.Allocator, io: std.Io, path: []const u8, name: []const u8) !?Module {
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch {
        std.debug.print("fels doc: cannot read {s}\n", .{path});
        return error.ReadFailed;
    };
    const module = parser.parseSource(a, path, source) catch {
        std.debug.print("fels doc: {s} does not parse, left out\n", .{path});
        return null;
    };
    return .{ .name = name, .path = path, .doc = moduleDoc(a, source), .entries = try entriesOf(a, source, module) };
}

/// The `//!` lines at the top of a file (after a first `// SPDX…` line), without their `//!`.
pub fn moduleDoc(a: std.mem.Allocator, source: []const u8) ?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var any = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "//!")) {
            if (any) out.append(a, '\n') catch return null;
            snippets.appendCommentText(a, &out, line);
            any = true;
        } else if (line.len == 0 or (std.mem.startsWith(u8, line, "//") and !snippets.isDocLine(line))) {
            if (any) break; // the module doc ends at the first line that is not one
        } else break;
    }
    const text = std.mem.trim(u8, out.items, " \n");
    return if (text.len == 0) null else text;
}

/// The public declarations of a parsed file, in the order they are written.
pub fn entriesOf(a: std.mem.Allocator, source: []const u8, module: ast.Module) ![]const Entry {
    var out: std.ArrayList(Entry) = .empty;
    for (module.items) |item| {
        if (!item.isPublic()) continue;
        const name = item.name() orelse continue;
        // a struct's methods are hoisted as `Struct.method`; they are shown with the struct
        if (std.mem.indexOfScalar(u8, name, '.') != null or ast.isBodyConstName(name)) continue;
        const doc = snippets.docComment(a, source, item.span().start);
        switch (item) {
            .function => |f| try out.append(a, .{
                .kind = if (f.is_macro) "macro" else if (f.is_constraint) "constraint" else "fn",
                .name = f.name,
                .signature = try functionHead(a, source, f),
                .doc = doc,
            }),
            .const_decl => |c| try out.append(a, .{
                .kind = if (c.is_mutable) "var" else "const",
                .name = c.name,
                .signature = try constHead(a, source, c),
                .doc = doc,
            }),
            .type_decl => |t| try out.append(a, try typeEntry(a, source, t, doc)),
            else => {},
        }
    }
    return out.items;
}

/// A function as declared, without its body: `pub add :: fn(a: i32, b: i32) -> i32`. Line
/// breaks and runs of spaces become one space.
fn functionHead(a: std.mem.Allocator, source: []const u8, f: ast.FunctionDecl) ![]const u8 {
    const start = declStart(source, f.span.start);
    var end = if (f.body) |b| b.span.start else f.span.end;
    if (f.where_clause) |w| end = @min(end, w.span.start);
    end = @min(end, source.len);
    return squeeze(a, std.mem.trimEnd(u8, source[start..end], " \t\r\n;{"));
}

/// A constant's line as written when it is short, else its name and type.
fn constHead(a: std.mem.Allocator, source: []const u8, c: ast.ConstDecl) ![]const u8 {
    const start = declStart(source, c.span.start);
    const text = std.mem.trimEnd(u8, source[start..@min(c.span.end, source.len)], " \t\r\n;");
    if (text.len <= 100 and std.mem.indexOfScalar(u8, text, '\n') == null) return text;
    const name_at = std.mem.indexOf(u8, text, c.name) orelse 0;
    const after = text[name_at + c.name.len ..];
    // `name: T = …` keeps its type, `name :: …` shows that it is a constant
    const cut = std.mem.indexOfAny(u8, after, "=") orelse after.len;
    return squeeze(a, try std.fmt.allocPrint(a, "{s}{s}{s}", .{
        text[0 .. name_at + c.name.len],
        std.mem.trimEnd(u8, after[0..cut], " :"),
        if (c.is_mutable) " = …" else " :: …",
    }));
}

fn typeEntry(a: std.mem.Allocator, source: []const u8, t: ast.TypeDecl, doc: ?[]const u8) !Entry {
    const start = declStart(source, t.span.start);
    const end = @min(t.span.end, source.len);
    const text = source[start..end];
    const brace = std.mem.indexOfScalar(u8, text, '{');
    const head = std.mem.trimEnd(u8, if (brace) |b| text[0..b] else text, " \t\r\n;");
    var entry: Entry = .{ .kind = "type", .name = t.name, .signature = try squeeze(a, head), .doc = doc };
    switch (t.kind) {
        .struct_type => |s| {
            entry.kind = if (s.is_union) "union" else "struct";
            var members: std.ArrayList(Member) = .empty;
            var sig: std.ArrayList(u8) = .empty;
            try sig.print(a, "{s} {{", .{entry.signature});
            for (s.fields) |field| {
                const ty = field.ty.span();
                const ty_text = source[@min(ty.start, source.len)..@min(ty.end, source.len)];
                try sig.print(a, "\n    {s}: {s},", .{ field.name, try squeeze(a, ty_text) });
                try members.append(a, .{ .name = field.name, .doc = memberDoc(a, source, field.span.start) });
            }
            try sig.appendSlice(a, if (s.fields.len == 0) "}" else "\n}");
            entry.signature = sig.items;
            entry.members = members.items;
            var methods: std.ArrayList(Entry) = .empty;
            for (s.methods) |m| {
                if (!m.is_public) continue;
                try methods.append(a, .{
                    .kind = "fn",
                    .name = m.name,
                    .signature = try functionHead(a, source, m),
                    .doc = snippets.docComment(a, source, m.span.start),
                });
            }
            entry.methods = methods.items;
        },
        .enum_type => |e| {
            entry.kind = "enum";
            entry.signature = try variantSignature(a, source, entry.signature, e.variants);
            entry.members = try variantMembers(a, source, e.variants);
        },
        .errors => |e| {
            entry.kind = "errors";
            entry.signature = try variantSignature(a, source, entry.signature, e.variants);
            entry.members = try variantMembers(a, source, e.variants);
        },
        .interface_type => |i| {
            entry.kind = "interface";
            var sig: std.ArrayList(u8) = .empty;
            try sig.print(a, "{s} {{", .{entry.signature});
            var members: std.ArrayList(Member) = .empty;
            for (i.methods) |m| {
                try sig.print(a, "\n    {s};", .{try functionHead(a, source, m)});
                try members.append(a, .{ .name = m.name, .doc = memberDoc(a, source, m.span.start) });
            }
            try sig.appendSlice(a, "\n}");
            entry.signature = sig.items;
            entry.members = members.items;
        },
        .alias, .distinct, .opaque_type => entry.signature = try squeeze(a, std.mem.trimEnd(u8, text, " \t\r\n;")),
    }
    return entry;
}

fn variantSignature(a: std.mem.Allocator, source: []const u8, head: []const u8, variants: anytype) ![]const u8 {
    var sig: std.ArrayList(u8) = .empty;
    try sig.print(a, "{s} {{", .{head});
    for (variants) |v| {
        const vtext = std.mem.trimEnd(u8, source[v.span.start..@min(v.span.end, source.len)], " \t\r\n,");
        try sig.print(a, "\n    {s},", .{try squeeze(a, vtext)});
    }
    try sig.appendSlice(a, if (variants.len == 0) "}" else "\n}");
    return sig.items;
}

fn variantMembers(a: std.mem.Allocator, source: []const u8, variants: anytype) ![]const Member {
    var members: std.ArrayList(Member) = .empty;
    for (variants) |v| try members.append(a, .{ .name = v.name, .doc = memberDoc(a, source, v.span.start) });
    return members.items;
}

/// The doc comment of a field or variant, which has one only when it starts its own line:
/// in `struct { x: i32 }` the comment above is the struct's.
fn memberDoc(a: std.mem.Allocator, source: []const u8, at: usize) ?[]const u8 {
    var i = @min(at, source.len);
    while (i > 0 and (source[i - 1] == ' ' or source[i - 1] == '\t')) i -= 1;
    if (i > 0 and source[i - 1] != '\n') return null;
    return snippets.docComment(a, source, at);
}

/// Where a declaration's text starts: at `pub` when it stands before `at` on the same line.
fn declStart(source: []const u8, at: usize) usize {
    var line_start = @min(at, source.len);
    while (line_start > 0 and source[line_start - 1] != '\n') line_start -= 1;
    const lead = std.mem.trimStart(u8, source[line_start..@min(at, source.len)], " \t");
    if (std.mem.startsWith(u8, lead, "pub")) return at - lead.len;
    return at;
}

/// `text` with each run of spaces, tabs and line breaks made one space.
fn squeeze(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    for (std.mem.trim(u8, text, " \t\r\n")) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            space = true;
            continue;
        }
        if (space and out.items.len > 0) {
            // no space after an opening or before a closing bracket
            const last = out.items[out.items.len - 1];
            if (last != '(' and last != '[' and c != ')' and c != ']' and c != ',') try out.append(a, ' ');
        }
        space = false;
        try out.append(a, c);
    }
    return out.items;
}

// ── markdown ────────────────────────────────────────────────────────────────────────────────

fn writeMarkdown(a: std.mem.Allocator, io: std.Io, out_dir: []const u8, modules: []const Module) !usize {
    var index: std.ArrayList(u8) = .empty;
    try index.appendSlice(a, "# Modules\n\n| Module | |\n| --- | --- |\n");
    for (modules) |m| {
        const summary = try std.mem.replaceOwned(u8, a, firstLine(m.doc), "|", "\\|");
        try index.print(a, "| [{s}]({s}.md) | {s} |\n", .{ m.name, m.name, summary });
        const page = try modulePage(a, m);
        const path = try std.fmt.allocPrint(a, "{s}/{s}.md", .{ out_dir, m.name });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = page });
    }
    const index_path = try std.fmt.allocPrint(a, "{s}/index.md", .{out_dir});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = index.items });
    return modules.len + 1;
}

/// The first line of a doc, for a one-line summary; a module doc that starts with its own
/// name (`std.vec: growable arrays…`) without that name.
fn firstLine(doc: ?[]const u8) []const u8 {
    const text = doc orelse return "";
    var line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    if (std.mem.indexOf(u8, line, ": ")) |colon| {
        if (std.mem.indexOfScalar(u8, line[0..colon], ' ') == null) line = line[colon + 2 ..];
    }
    return std.mem.trim(u8, line, " ");
}

pub fn modulePage(a: std.mem.Allocator, m: Module) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "# {s}\n\n", .{m.name});
    if (m.doc) |doc| try out.print(a, "{s}\n\n", .{stripOwnName(doc, m.name)});
    for (m.entries) |e| try entryMarkdown(a, &out, e, "##", "");
    if (m.entries.len == 0) try out.appendSlice(a, "This module has no public declarations.\n");
    return out.items;
}

/// `std.vec: growable arrays…` → `Growable arrays…` when a module doc names its module first.
fn stripOwnName(doc: []const u8, name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, doc, name) and std.mem.startsWith(u8, doc[name.len..], ": ")) return doc[name.len + 2 ..];
    return doc;
}

fn entryMarkdown(a: std.mem.Allocator, out: *std.ArrayList(u8), e: Entry, level: []const u8, owner: []const u8) !void {
    if (owner.len > 0) {
        try out.print(a, "{s} {s}.{s}\n\n", .{ level, owner, e.name });
    } else try out.print(a, "{s} {s}\n\n", .{ level, e.name });
    try out.print(a, "```fels\n{s}\n```\n\n", .{e.signature});
    if (e.doc) |doc| try out.print(a, "{s}\n\n", .{doc});
    var documented: usize = 0;
    for (e.members) |m| {
        if (m.doc != null) documented += 1;
    }
    if (documented > 0) {
        for (e.members) |m| {
            if (m.doc) |doc| try out.print(a, "- `{s}`: {s}\n", .{ m.name, oneLine(a, doc) });
        }
        try out.append(a, '\n');
    }
    for (e.methods) |m| try entryMarkdown(a, out, m, "###", e.name);
}

fn oneLine(a: std.mem.Allocator, text: []const u8) []const u8 {
    const copy = a.dupe(u8, text) catch return text;
    std.mem.replaceScalar(u8, copy, '\n', ' ');
    return copy;
}

// ── json ────────────────────────────────────────────────────────────────────────────────────

fn writeJson(a: std.mem.Allocator, io: std.Io, out_dir: []const u8, modules: []const Module) !usize {
    const text = try std.json.Stringify.valueAlloc(a, .{ .modules = modules }, .{ .whitespace = .indent_1 });
    const path = try std.fmt.allocPrint(a, "{s}/doc.json", .{out_dir});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
    return 1;
}

test "a module's doc, a function, a struct with fields and methods, an enum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\// SPDX-License-Identifier: Apache-2.0
        \\//! demo: things to show
        \\
        \\/// Adds two numbers.
        \\pub add :: fn(a: i32,
        \\              b: i32) -> i32 { return a + b; }
        \\
        \\// not documentation
        \\pub sub :: fn(a: i32, b: i32) -> i32 { return a - b; }
        \\
        \\hidden :: fn() {}
        \\
        \\/// A point.
        \\pub Point :: struct {
        \\    /// across
        \\    x: i32,
        \\    y: i32,
        \\
        \\    /// The length.
        \\    pub len :: fn(self: *Self) -> i32 { return self.x; }
        \\    secret :: fn(self: *Self) {}
        \\}
        \\
        \\pub Side :: enum { left, right }
        \\pub LIMIT :: 10;
    ;
    const module = try parser.parseSource(a, "demo.fels", src);
    try std.testing.expectEqualStrings("demo: things to show", moduleDoc(a, src).?);
    const entries = try entriesOf(a, src, module);
    try std.testing.expectEqual(@as(usize, 5), entries.len);
    try std.testing.expectEqualStrings("pub add :: fn(a: i32, b: i32) -> i32", entries[0].signature);
    try std.testing.expectEqualStrings("Adds two numbers.", entries[0].doc.?);
    try std.testing.expectEqualStrings("sub", entries[1].name);
    try std.testing.expect(entries[1].doc == null);
    try std.testing.expectEqualStrings("struct", entries[2].kind);
    try std.testing.expectEqualStrings("pub Point :: struct {\n    x: i32,\n    y: i32,\n}", entries[2].signature);
    try std.testing.expectEqualStrings("across", entries[2].members[0].doc.?);
    try std.testing.expectEqual(@as(usize, 1), entries[2].methods.len);
    try std.testing.expectEqualStrings("The length.", entries[2].methods[0].doc.?);
    try std.testing.expectEqualStrings("enum", entries[3].kind);
    try std.testing.expect(entries[3].members[0].doc == null); // the enum's comment is not its first variant's
    try std.testing.expectEqualStrings("pub LIMIT :: 10", entries[4].signature);

    const page = try modulePage(a, .{ .name = "demo", .path = "demo.fels", .doc = moduleDoc(a, src), .entries = entries });
    try std.testing.expect(std.mem.indexOf(u8, page, "# demo\n\nthings to show") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "### Point.len") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "- `x`: across") != null);
}
