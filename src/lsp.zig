//! fels language server, `fels lsp`.
//!
//! A small LSP server over stdio (JSON-RPC). It is a thin layer over the compiler front
//! end: every open document is analyzed with `pipeline.analyzeFile`, which loads the file
//! and everything it imports (the standard library and sibling `.fels` files) with the same
//! rules as `fels check`, but tolerantly, so a broken file still gives diagnostics,
//! symbols and partial types.
//!
//! * Open documents override files on disk: an imported module that is open in the editor
//!   is read from the editor's text.
//! * `std` is found as the compiler finds it (`--std-path`, `FELS_STD`, `FELS_HOME`,
//!   next to the executable). Other imports are looked up next to the importing file and
//!   then under the project root (the folder with `build.fels`, or the workspace folder).
//! * Diagnostics are published per file: the errors of an imported module go to that
//!   module's own URI, never to the importer. Errors inside `std` are not shown.
//! * Definition and hover work across files. Completion and the outline include the names
//!   that imports bring into scope.
//! * A change of a document re-analyzes the open documents that import it. Analysis of
//!   several quick changes is merged: it runs when no more input is waiting.
//! * Help while typing lives in lsp_assist.zig: completion of members after `expr.`,
//!   `Type::` and enum literals, signature help, inlay hints for inferred types, and hover
//!   on locals, parameters and fields. While the text does not parse, these answer from
//!   the last analysis whose text parsed, with positions mapped through the edits.
//! * Find references, rename, document highlight and workspace symbols cover every `.fels`
//!   file of the project, open in the editor or not. They live in `lsp_nav.zig`, which
//!   keeps a reference index per file and rebuilds it only when the file or a module it
//!   imports changes.
//!
//! stdout carries only LSP messages. All front end diagnostics are captured as data.
//!
//! Implemented: diagnostics, completion (names in scope, locals, `alias::` and `Type::`
//! members, members after `.`, enum literals, keywords), hover, go to definition, document
//! symbols, signature help, inlay hints, references, rename (with prepareRename), document
//! highlight, workspace symbols. Not implemented: formatting, semantic tokens, code actions.

const std = @import("std");
const builtin = @import("builtin");
const sema = @import("sema.zig");
const ast = @import("ast.zig");
const diag = @import("diagnostic.zig");
const pipeline = @import("pipeline.zig");
const pkg = @import("pkg.zig");
const clock = @import("clock.zig");
const lsp_nav = @import("lsp_nav.zig");
const Span = @import("lexer/span.zig").Span;
const lsp_assist = @import("lsp_assist.zig");

const json = std.json;

// Paths and URIs

const is_windows = builtin.os.tag == .windows;

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// The file path a `file:` URI names, with native separators. Any other URI is returned
/// as it is, so an unsaved document still has a name to be keyed by.
pub fn uriToPath(gpa: std.mem.Allocator, uri: []const u8) ![]u8 {
    const prefix = "file://";
    if (!std.ascii.startsWithIgnoreCase(uri, prefix)) return gpa.dupe(u8, uri);
    var rest = uri[prefix.len..];
    // `file://host/path`: drop the host (normally empty).
    if (rest.len > 0 and rest[0] != '/') {
        rest = if (std.mem.indexOfScalar(u8, rest, '/')) |i| rest[i..] else "";
    }
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < rest.len) {
        const c = rest[i];
        if (c == '%' and i + 2 < rest.len) {
            if (hexVal(rest[i + 1])) |hi| if (hexVal(rest[i + 2])) |lo| {
                try out.append(gpa, hi * 16 + lo);
                i += 3;
                continue;
            };
        }
        try out.append(gpa, c);
        i += 1;
    }
    var path = try out.toOwnedSlice(gpa);
    if (is_windows) {
        // `/C:/dir/file` -> `C:\dir\file`
        if (path.len >= 3 and path[0] == '/' and std.ascii.isAlphabetic(path[1]) and path[2] == ':') {
            std.mem.copyForwards(u8, path[0 .. path.len - 1], path[1..]);
            path = gpa.realloc(path, path.len - 1) catch path[0 .. path.len - 1];
        }
        for (path) |*c| {
            if (c.* == '/') c.* = '\\';
        }
    }
    return path;
}

/// A `file:` URI for a path, with the characters that need it percent-encoded.
pub fn pathToUri(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "file://");
    if (path.len == 0 or (path[0] != '/' and path[0] != '\\')) try out.append(gpa, '/');
    for (path) |c| {
        const ch: u8 = if (c == '\\') '/' else c;
        if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-._~/:", ch) != null) {
            try out.append(gpa, ch);
        } else {
            try out.print(gpa, "%{X:0>2}", .{ch});
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The form of a path that is equal for two spellings of the same file: forward slashes,
/// and lower case on Windows.
pub fn pathKey(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const key = try gpa.dupe(u8, path);
    for (key) |*c| {
        if (c.* == '\\') c.* = '/';
        if (is_windows) c.* = std.ascii.toLower(c.*);
    }
    return key;
}

// Documents and analysis

/// The diagnostics of one file, already rendered as LSP JSON objects.
const FileDiags = struct {
    key: []u8,
    path: []u8,
    /// `{...},{...}`: comma separated diagnostic objects.
    items: []u8,
    count: usize,

    fn deinit(self: FileDiags, gpa: std.mem.Allocator) void {
        gpa.free(self.key);
        gpa.free(self.path);
        gpa.free(self.items);
    }
};

pub const Doc = struct {
    uri: []u8,
    path: []u8,
    key: []u8,
    text: []u8,
    /// The folder imports are also looked up in, or null.
    project_root: ?[]u8 = null,
    analysis: ?pipeline.Analysis = null,
    /// The last analysis whose text parsed, kept while the current text does not parse
    /// (see lsp_assist.zig).
    last_good: ?pipeline.Analysis = null,
    /// Diagnostics per loaded file (not `std`), including this document's own.
    file_diags: []FileDiags = &.{},
    /// Keys of every non-`std` file the last analysis loaded.
    deps: [][]u8 = &.{},
    dirty: bool = false,
    /// Milliseconds the last analysis took (reported by `FELS_LSP_TIMING`).
    last_ms: f64 = 0,

    fn clearAnalysis(self: *Doc, gpa: std.mem.Allocator) void {
        if (self.analysis) |*a| a.deinit();
        self.analysis = null;
        for (self.file_diags) |fd| fd.deinit(gpa);
        gpa.free(self.file_diags);
        self.file_diags = &.{};
        for (self.deps) |d| gpa.free(d);
        gpa.free(self.deps);
        self.deps = &.{};
    }

    fn deinit(self: *Doc, gpa: std.mem.Allocator) void {
        self.clearAnalysis(gpa);
        if (self.last_good) |*a| a.deinit();
        if (self.project_root) |r| gpa.free(r);
        gpa.free(self.uri);
        gpa.free(self.path);
        gpa.free(self.key);
        gpa.free(self.text);
    }

    fn dependsOn(self: *const Doc, key: []const u8) bool {
        for (self.deps) |d| if (std.mem.eql(u8, d, key)) return true;
        return false;
    }
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    /// Open documents by URI.
    docs: std.StringHashMapUnmanaged(*Doc) = .{},
    /// Open documents by path key, for the import reader.
    by_key: std.StringHashMapUnmanaged(*Doc) = .{},
    /// Files that currently have published, non-empty diagnostics: key -> URI.
    published: std.StringHashMapUnmanaged([]u8) = .{},
    workspace_root: ?[]u8 = null,
    shutdown_requested: bool = false,
    timing: bool = false,
    /// The project reference indexes of references, rename and workspace symbols.
    nav: lsp_nav.State = .{},
    /// The environment the server runs in (where the package cache is).
    environ: ?*const std.process.Environ.Map = null,
    /// The packages of each project folder, from its fels.pkg and fels.lock.
    projects: std.StringHashMapUnmanaged(*ProjectPackages) = .{},

    pub const ProjectPackages = struct {
        arena: std.heap.ArenaAllocator,
        /// A hash of fels.pkg and fels.lock as they were read; another value means they changed.
        stamp: u64,
        /// The import roots: the project's own package (with `#package`), then the packages.
        roots: []const pipeline.ModuleRoot = &.{},
        missing: []const []const u8 = &.{},
    };

    /// The packages of the project in `root`: resolved from fels.pkg, fels.lock and the package
    /// cache without running git, and again when one of the two files changed. A project
    /// without fels.pkg has none.
    pub fn packagesFor(self: *Server, root: ?[]const u8) ?*const ProjectPackages {
        const dir = root orelse return null;
        var stamp = std.hash.Wyhash.init(0);
        var any = false;
        for ([_][]const u8{ "fels.pkg", "fels.lock" }) |name| {
            const path = std.fs.path.join(self.gpa, &.{ dir, name }) catch return null;
            defer self.gpa.free(path);
            const text = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .unlimited) catch continue;
            defer self.gpa.free(text);
            if (std.mem.eql(u8, name, "fels.pkg")) any = true;
            stamp.update(name);
            stamp.update(text);
        }
        if (!any) return null;
        const value = stamp.final();
        if (self.projects.get(dir)) |known| if (known.stamp == value) return known;

        const entry = self.gpa.create(ProjectPackages) catch return null;
        entry.* = .{ .arena = std.heap.ArenaAllocator.init(self.gpa), .stamp = value };
        const a = entry.arena.allocator();
        if (pkg.project.load(a, self.io, dir, self.environ, .{ .skip_missing = true })) |result| {
            if (result) |r| {
                // The project's own package first, as `fels build` has it.
                var roots: std.ArrayList(pipeline.ModuleRoot) = .empty;
                if (r.self_root) |s| roots.append(a, s) catch {};
                for (r.packages) |p| roots.append(a, .{ .name = p.name, .dir = p.import_dir }) catch {};
                entry.roots = roots.items;
                entry.missing = r.missing;
            }
        } else |_| {} // fels.pkg has a mistake: `fels build` reports it; imports of packages fail
        if (self.projects.fetchRemove(dir)) |old| {
            self.gpa.free(old.key);
            old.value.arena.deinit();
            self.gpa.destroy(old.value);
        }
        const key = self.gpa.dupe(u8, dir) catch {
            entry.arena.deinit();
            self.gpa.destroy(entry);
            return null;
        };
        self.projects.put(self.gpa, key, entry) catch {
            self.gpa.free(key);
            entry.arena.deinit();
            self.gpa.destroy(entry);
            return null;
        };
        return entry;
    }

    /// Analysis options for a document of the project in `root`, with its packages.
    pub fn analysisOptions(self: *Server, root: ?[]const u8) pipeline.AnalysisOptions {
        const pkgs = self.packagesFor(root);
        return .{
            .reader = self.reader(),
            .project_root = root,
            .module_roots = if (pkgs) |p| p.roots else &.{},
            .missing_packages = if (pkgs) |p| p.missing else &.{},
        };
    }

    pub fn reader(self: *Server) pipeline.SourceReader {
        return .{ .ctx = self, .readFn = readSource, .existsFn = sourceExists };
    }

    /// Analyze one document. Failures leave it without an analysis; they never propagate.
    fn analyze(self: *Server, doc: *Doc) void {
        const t0 = clock.monoNs();
        lsp_assist.keepLastGood(doc);
        doc.clearAnalysis(self.gpa);
        doc.dirty = false;
        var result = pipeline.analyzeFile(self.gpa, doc.path, self.analysisOptions(doc.project_root)) catch return;
        self.collectFileDiags(doc, &result) catch {
            result.deinit();
            doc.clearAnalysis(self.gpa);
            return;
        };
        doc.analysis = result;
        lsp_assist.dropLastGood(doc);
        doc.last_ms = @as(f64, @floatFromInt(clock.sinceNs(t0))) / 1_000_000.0;
        if (self.timing) std.debug.print("fels-lsp: analyzed {s} in {d:.1} ms\n", .{ doc.path, doc.last_ms });
    }

    /// Render the diagnostics of every loaded file (except `std`) and note the dependencies.
    fn collectFileDiags(self: *Server, doc: *Doc, result: *const pipeline.Analysis) !void {
        const gpa = self.gpa;
        var fds = std.ArrayList(FileDiags).empty;
        errdefer {
            for (fds.items) |fd| fd.deinit(gpa);
            fds.deinit(gpa);
        }
        var deps = std.ArrayList([]u8).empty;
        errdefer {
            for (deps.items) |d| gpa.free(d);
            deps.deinit(gpa);
        }

        for (result.files) |f| {
            if (f.is_std) continue;
            const key = try pathKey(gpa, f.path);
            errdefer gpa.free(key);
            try deps.append(gpa, try gpa.dupe(u8, key));

            var items = std.ArrayList(u8).empty;
            errdefer items.deinit(gpa);
            var count: usize = 0;
            for (result.diagnostics) |d| {
                if (!std.mem.eql(u8, d.file, f.path)) continue;
                if (count > 0) try items.append(gpa, ',');
                try appendDiagnosticJson(&items, gpa, f.source, d);
                count += 1;
            }
            try fds.append(gpa, .{
                .key = key,
                .path = try gpa.dupe(u8, f.path),
                .items = try items.toOwnedSlice(gpa),
                .count = count,
            });
        }
        doc.file_diags = try fds.toOwnedSlice(gpa);
        doc.deps = try deps.toOwnedSlice(gpa);
    }

    fn markDirtyWithDependents(self: *Server, doc: *Doc) void {
        doc.dirty = true;
        var it = self.docs.valueIterator();
        while (it.next()) |other| {
            if (other.* != doc and other.*.dependsOn(doc.key)) other.*.dirty = true;
        }
    }

    /// Analyze every dirty document and publish the diagnostics that changed.
    fn flush(self: *Server) void {
        var affected = std.StringHashMapUnmanaged(void){};
        defer {
            var kit = affected.keyIterator();
            while (kit.next()) |k| self.gpa.free(k.*);
            affected.deinit(self.gpa);
        }
        var it = self.docs.valueIterator();
        while (it.next()) |entry| {
            const doc = entry.*;
            if (!doc.dirty) continue;
            self.noteAffected(&affected, doc);
            self.analyze(doc);
            self.noteAffected(&affected, doc);
        }
        var kit = affected.keyIterator();
        while (kit.next()) |k| self.publishFile(k.*);
    }

    fn noteAffected(self: *Server, set: *std.StringHashMapUnmanaged(void), doc: *Doc) void {
        self.noteKey(set, doc.key);
        for (doc.file_diags) |fd| self.noteKey(set, fd.key);
    }

    fn noteKey(self: *Server, set: *std.StringHashMapUnmanaged(void), key: []const u8) void {
        if (set.contains(key)) return;
        const owned = self.gpa.dupe(u8, key) catch return;
        set.put(self.gpa, owned, {}) catch self.gpa.free(owned);
    }

    /// Publish the diagnostics of the file with this key: its own analysis if it is open,
    /// else what the open documents that import it found in it.
    fn publishFile(self: *Server, key: []const u8) void {
        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.gpa);
        var count: usize = 0;
        var uri: ?[]const u8 = null;
        var path: []const u8 = "";

        if (self.by_key.get(key)) |doc| {
            uri = doc.uri;
            path = doc.path;
            for (doc.file_diags) |fd| {
                if (!std.mem.eql(u8, fd.key, key)) continue;
                body.appendSlice(self.gpa, fd.items) catch return;
                count = fd.count;
            }
        } else {
            var it = self.docs.valueIterator();
            while (it.next()) |other| {
                for (other.*.file_diags) |fd| {
                    if (!std.mem.eql(u8, fd.key, key) or fd.count == 0) continue;
                    path = fd.path;
                    // Several documents may find the same errors in a shared module.
                    if (count > 0 and std.mem.indexOf(u8, body.items, fd.items) != null) continue;
                    if (count > 0) body.append(self.gpa, ',') catch return;
                    body.appendSlice(self.gpa, fd.items) catch return;
                    count += fd.count;
                }
            }
        }

        if (count == 0) {
            // Clear what was published before; nothing to say otherwise.
            if (self.published.fetchRemove(key)) |kv| {
                self.sendDiagnostics(kv.value, "");
                self.gpa.free(kv.key);
                self.gpa.free(kv.value);
            } else if (uri) |u| {
                self.sendDiagnostics(u, "");
            }
            return;
        }

        const target_uri: []u8 = if (uri) |u|
            self.gpa.dupe(u8, u) catch return
        else
            pathToUri(self.gpa, path) catch return;
        self.sendDiagnostics(target_uri, body.items);
        if (self.published.getEntry(key)) |e| {
            self.gpa.free(e.value_ptr.*);
            e.value_ptr.* = target_uri;
        } else {
            const owned_key = self.gpa.dupe(u8, key) catch {
                self.gpa.free(target_uri);
                return;
            };
            self.published.put(self.gpa, owned_key, target_uri) catch {
                self.gpa.free(owned_key);
                self.gpa.free(target_uri);
            };
        }
    }

    fn sendDiagnostics(self: *Server, uri: []const u8, items: []const u8) void {
        var b = std.ArrayList(u8).empty;
        defer b.deinit(self.gpa);
        b.appendSlice(self.gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"") catch return;
        escapeInto(&b, self.gpa, uri);
        b.appendSlice(self.gpa, "\",\"diagnostics\":[") catch return;
        b.appendSlice(self.gpa, items) catch return;
        b.appendSlice(self.gpa, "]}}") catch return;
        send(self, b.items);
    }

    fn open(self: *Server, uri: []const u8, text: []const u8) void {
        if (self.docs.get(uri)) |doc| {
            self.setText(doc, text);
            return;
        }
        const doc = self.gpa.create(Doc) catch return;
        const path = uriToPath(self.gpa, uri) catch {
            self.gpa.destroy(doc);
            return;
        };
        doc.* = .{
            .uri = self.gpa.dupe(u8, uri) catch return,
            .path = path,
            .key = pathKey(self.gpa, path) catch return,
            .text = self.gpa.dupe(u8, text) catch return,
        };
        doc.project_root = self.findProjectRoot(doc.path);
        self.docs.put(self.gpa, doc.uri, doc) catch return;
        self.by_key.put(self.gpa, doc.key, doc) catch {};
        self.markDirtyWithDependents(doc);
    }

    fn setText(self: *Server, doc: *Doc, text: []const u8) void {
        const copy = self.gpa.dupe(u8, text) catch return;
        self.gpa.free(doc.text);
        doc.text = copy;
        self.markDirtyWithDependents(doc);
    }

    fn close(self: *Server, uri: []const u8) void {
        const kv = self.docs.fetchRemove(uri) orelse return;
        const doc = kv.value;
        _ = self.by_key.remove(doc.key);
        // The importers see the file on disk from now on.
        var it = self.docs.valueIterator();
        while (it.next()) |other| {
            if (other.*.dependsOn(doc.key)) other.*.dirty = true;
        }
        const key = self.gpa.dupe(u8, doc.key) catch null;
        doc.deinit(self.gpa);
        self.gpa.destroy(doc);
        self.flush();
        if (key) |k| {
            self.publishFile(k);
            self.gpa.free(k);
        }
    }

    /// The nearest folder above `path` with a `build.fels` or a `fels.pkg` (a library need not
    /// have a build.fels), else the workspace folder.
    pub fn findProjectRoot(self: *Server, path: []const u8) ?[]u8 {
        var dir = std.fs.path.dirname(path);
        while (dir) |d| {
            for ([_][]const u8{ "build.fels", "fels.pkg" }) |name| {
                const probe = std.fs.path.join(self.gpa, &.{ d, name }) catch break;
                defer self.gpa.free(probe);
                if (sourceExists(self, probe)) return self.gpa.dupe(u8, d) catch null;
            }
            dir = std.fs.path.dirname(d);
        }
        if (self.workspace_root) |r| return self.gpa.dupe(u8, r) catch null;
        return null;
    }

    /// The URI to report for a file path: the editor's spelling if the file is open.
    pub fn uriFor(self: *Server, path: []const u8) ?[]u8 {
        const key = pathKey(self.gpa, path) catch return null;
        defer self.gpa.free(key);
        if (self.by_key.get(key)) |doc| return self.gpa.dupe(u8, doc.uri) catch null;
        return pathToUri(self.gpa, path) catch null;
    }
};

/// `SourceReader.readFn`: the editor's text for an open document, else the disk.
fn readSource(ctx: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const self: *Server = @ptrCast(@alignCast(ctx.?));
    var buf: [1024]u8 = undefined;
    var key_alloc: ?[]u8 = null;
    defer if (key_alloc) |k| self.gpa.free(k);
    const key: []const u8 = if (path.len <= buf.len) blk: {
        @memcpy(buf[0..path.len], path);
        for (buf[0..path.len]) |*c| {
            if (c.* == '\\') c.* = '/';
            if (is_windows) c.* = std.ascii.toLower(c.*);
        }
        break :blk buf[0..path.len];
    } else blk: {
        key_alloc = pathKey(self.gpa, path) catch return null;
        break :blk key_alloc.?;
    };
    if (self.by_key.get(key)) |doc| return allocator.dupe(u8, doc.text) catch null;
    return std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .unlimited) catch null;
}

fn sourceExists(ctx: ?*anyopaque, path: []const u8) bool {
    const self: *Server = @ptrCast(@alignCast(ctx.?));
    const key = pathKey(self.gpa, path) catch return false;
    defer self.gpa.free(key);
    if (self.by_key.contains(key)) return true;
    std.Io.Dir.cwd().access(self.io, path, .{}) catch return false;
    return true;
}

// Position mapping (byte offset <-> LSP UTF-16 position)

pub const Pos = struct { line: u32, char: u32 };

pub fn byteToPos(text: []const u8, offset: usize) Pos {
    var line: u32 = 0;
    var col: u32 = 0;
    var i: usize = 0;
    const end = @min(offset, text.len);
    while (i < end) {
        const c = text[i];
        if (c == '\n') {
            line += 1;
            col = 0;
            i += 1;
            continue;
        }
        const seq = std.unicode.utf8ByteSequenceLength(c) catch {
            col += 1;
            i += 1;
            continue;
        };
        if (i + seq <= text.len) {
            const cp = std.unicode.utf8Decode(text[i .. i + seq]) catch {
                col += 1;
                i += 1;
                continue;
            };
            col += if (cp >= 0x10000) @as(u32, 2) else 1; // surrogate pair = 2 UTF-16 units
            i += seq;
        } else {
            col += 1;
            i += 1;
        }
    }
    return .{ .line = line, .char = col };
}

pub fn posToByte(text: []const u8, line: u32, character: u32) usize {
    var i: usize = 0;
    var ln: u32 = 0;
    while (i < text.len and ln < line) : (i += 1) {
        if (text[i] == '\n') ln += 1;
    }
    var c: u32 = 0;
    while (i < text.len and c < character and text[i] != '\n') {
        const seq = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            c += 1;
            i += 1;
            continue;
        };
        const cp = if (i + seq <= text.len) (std.unicode.utf8Decode(text[i .. i + seq]) catch 0) else 0;
        c += if (cp >= 0x10000) @as(u32, 2) else 1;
        i += seq;
    }
    return i;
}

pub fn isIdentChar(c: u8) bool {
    return c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
}

/// The identifier surrounding byte `offset`, or empty.
fn identAt(text: []const u8, offset: usize) []const u8 {
    if (text.len == 0) return "";
    var start = @min(offset, text.len);
    while (start > 0 and isIdentChar(text[start - 1])) start -= 1;
    var end = @min(offset, text.len);
    while (end < text.len and isIdentChar(text[end])) end += 1;
    if (end <= start) return "";
    return text[start..end];
}

/// Byte range of the identifier around `offset`.
pub fn identRangeAt(text: []const u8, offset: usize) struct { start: usize, end: usize } {
    var start = @min(offset, text.len);
    while (start > 0 and isIdentChar(text[start - 1])) start -= 1;
    var end = @min(offset, text.len);
    while (end < text.len and isIdentChar(text[end])) end += 1;
    return .{ .start = start, .end = end };
}

/// The span of `name` inside a declaration's span (its name token), or the whole span.
pub fn nameSpan(source: []const u8, decl: Span, name: []const u8) Span {
    const from = @min(decl.start, source.len);
    const to = @min(decl.end, source.len);
    var i = from;
    while (i + name.len <= to) : (i += 1) {
        if (!std.mem.eql(u8, source[i .. i + name.len], name)) continue;
        if (i > 0 and isIdentChar(source[i - 1])) continue;
        if (i + name.len < source.len and isIdentChar(source[i + name.len])) continue;
        return Span.new(@intCast(i), @intCast(i + name.len));
    }
    return decl;
}

// JSON output helpers

pub fn escapeInto(list: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) void {
    for (s) |c| switch (c) {
        '"' => list.appendSlice(gpa, "\\\"") catch {},
        '\\' => list.appendSlice(gpa, "\\\\") catch {},
        '\n' => list.appendSlice(gpa, "\\n") catch {},
        '\r' => list.appendSlice(gpa, "\\r") catch {},
        '\t' => list.appendSlice(gpa, "\\t") catch {},
        else => if (c < 0x20) {
            list.print(gpa, "\\u{x:0>4}", .{c}) catch {};
        } else list.append(gpa, c) catch {},
    };
}

/// Re-serialize a JSON-RPC id (int or string) for echoing in a response.
pub fn idToBuf(list: *std.ArrayList(u8), gpa: std.mem.Allocator, id: ?json.Value) void {
    if (id) |v| switch (v) {
        .integer => |n| list.print(gpa, "{d}", .{n}) catch {},
        .string => |s| {
            list.append(gpa, '"') catch {};
            escapeInto(list, gpa, s);
            list.append(gpa, '"') catch {};
        },
        else => list.appendSlice(gpa, "null") catch {},
    } else list.appendSlice(gpa, "null") catch {};
}

pub fn send(self: *Server, body: []const u8) void {
    self.out.print("Content-Length: {d}\r\n\r\n", .{body.len}) catch {};
    self.out.writeAll(body) catch {};
    self.out.flush() catch {};
}

pub fn sendResult(self: *Server, id: ?json.Value, result_json: []const u8) void {
    var b = std.ArrayList(u8).empty;
    defer b.deinit(self.gpa);
    b.appendSlice(self.gpa, "{\"jsonrpc\":\"2.0\",\"id\":") catch {};
    idToBuf(&b, self.gpa, id);
    b.appendSlice(self.gpa, ",\"result\":") catch {};
    b.appendSlice(self.gpa, result_json) catch {};
    b.append(self.gpa, '}') catch {};
    send(self, b.items);
}

pub fn appendRange(b: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8, span: Span) void {
    const s = byteToPos(text, span.start);
    const e = byteToPos(text, span.end);
    b.print(gpa, "{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{ s.line, s.char, e.line, e.char }) catch {};
}

/// One LSP diagnostic object for `d`, positions taken in `text`.
fn appendDiagnosticJson(b: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8, d: diag.Diagnostic) !void {
    const severity: u8 = switch (d.kind) {
        .err => 1,
        .warning => 2,
        .note => 3,
        else => 1,
    };
    try b.appendSlice(gpa, "{\"range\":");
    appendRange(b, gpa, text, d.span);
    try b.print(gpa, ",\"severity\":{d},\"source\":\"fels\",", .{severity});
    if (d.code) |c| {
        try b.appendSlice(gpa, "\"code\":\"");
        escapeInto(b, gpa, c);
        try b.appendSlice(gpa, "\",");
    }
    try b.appendSlice(gpa, "\"message\":\"");
    escapeInto(b, gpa, d.message);
    try b.appendSlice(gpa, "\"}");
}

// JSON input helpers

pub fn objGet(v: json.Value, key: []const u8) ?json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}
pub fn getStr(v: json.Value, key: []const u8) ?[]const u8 {
    const f = objGet(v, key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}
pub fn getInt(v: json.Value, key: []const u8) ?i64 {
    const f = objGet(v, key) orelse return null;
    return switch (f) {
        .integer => |n| n,
        else => null,
    };
}

// Kind mappings

fn completionKind(k: sema.SymbolKind) u8 {
    return switch (k) {
        .function => 3, // Function
        .type => 7, // Class
        .const_symbol => 21, // Constant
        .param, .local_val, .local_var, .local_const, .global_var => 6, // Variable
        .field => 5, // Field
        .variant => 20, // EnumMember
        else => 6,
    };
}

fn symbolKind(k: sema.SymbolKind) u8 {
    return switch (k) {
        .function => 12, // Function
        .type => 23, // Struct
        .const_symbol => 14, // Constant
        .field => 8, // Field
        .variant => 22, // EnumMember
        else => 13, // Variable
    };
}

const keywords = [_][]const u8{
    "fn",   "struct",  "enum",  "errors", "interface", "if",     "else",  "while", "for",
    "in",   "return",  "match", "pub",    "const",     "unsafe", "defer", "zone",  "catch",
    "fail", "true",    "false", "null",   "as",        "i8",     "i16",   "i32",   "i64",
    "u8",   "u16",     "u32",   "u64",    "usize",     "isize",  "bool",  "f32",   "f64",
    "void", "byte",   "yield", "union",
};

// Request handlers

fn handleInitialize(self: *Server, id: ?json.Value, params: json.Value) void {
    // The workspace folder, used as the project root for files without a `build.fels`.
    var root_uri: ?[]const u8 = getStr(params, "rootUri");
    if (root_uri == null) {
        if (objGet(params, "workspaceFolders")) |wf| switch (wf) {
            .array => |arr| if (arr.items.len > 0) {
                root_uri = getStr(arr.items[0], "uri");
            },
            else => {},
        };
    }
    if (root_uri) |u| {
        if (uriToPath(self.gpa, u)) |p| {
            if (self.workspace_root) |old| self.gpa.free(old);
            self.workspace_root = p;
        } else |_| {}
    } else if (getStr(params, "rootPath")) |p| {
        self.workspace_root = self.gpa.dupe(u8, p) catch null;
    }
    sendResult(self, id,
        \\{"capabilities":{"textDocumentSync":1,"completionProvider":{"triggerCharacters":[".",":"]},"hoverProvider":true,"definitionProvider":true,"documentSymbolProvider":true,"signatureHelpProvider":{"triggerCharacters":["(",","],"retriggerCharacters":[","]},"inlayHintProvider":true,"referencesProvider":true,"renameProvider":{"prepareProvider":true},"documentHighlightProvider":true,"workspaceSymbolProvider":true},"serverInfo":{"name":"fels-lsp","version":"
    ++ @import("build_options").version ++ "\"}}");
}

pub fn docFromParams(self: *Server, params: json.Value) ?*Doc {
    const td = objGet(params, "textDocument") orelse return null;
    const uri = getStr(td, "uri") orelse return null;
    return self.docs.get(uri);
}

pub fn cursorOffset(doc: *Doc, params: json.Value) ?usize {
    const position = objGet(params, "position") orelse return null;
    const line: u32 = @intCast(@max(0, getInt(position, "line") orelse return null));
    const character: u32 = @intCast(@max(0, getInt(position, "character") orelse return null));
    return posToByte(doc.text, line, character);
}

/// True for names that are not meant to be offered or listed: hoisted methods
/// (`Vec.push`) and `_`-prefixed names.
pub fn hiddenName(name: []const u8) bool {
    return name.len == 0 or name[0] == '_' or std.mem.indexOfScalar(u8, name, '.') != null or ast.isBodyConstName(name);
}

pub fn topLevelKind(k: sema.SymbolKind) bool {
    return switch (k) {
        .function, .type, .const_symbol, .global_var => true,
        else => false,
    };
}

pub fn appendCompletionItem(
    self: *Server,
    b: *std.ArrayList(u8),
    seen: *std.StringHashMapUnmanaged(void),
    first: *bool,
    name: []const u8,
    kind: u8,
    detail: ?[]const u8,
) void {
    if (seen.contains(name)) return;
    seen.put(self.gpa, name, {}) catch {};
    if (!first.*) b.append(self.gpa, ',') catch {};
    first.* = false;
    b.appendSlice(self.gpa, "{\"label\":\"") catch {};
    escapeInto(b, self.gpa, name);
    b.print(self.gpa, "\",\"kind\":{d}", .{kind}) catch {};
    if (detail) |d| {
        b.appendSlice(self.gpa, ",\"detail\":\"") catch {};
        escapeInto(b, self.gpa, d);
        b.append(self.gpa, '"') catch {};
    }
    b.append(self.gpa, '}') catch {};
}

/// The module name a file path stands for, for a completion detail: its file name without
/// the extension.
pub fn moduleLabel(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return pipeline.withoutExt(base);
}

fn handleCompletion(self: *Server, id: ?json.Value, params: json.Value) void {
    const doc = docFromParams(self, params) orelse return sendResult(self, id, "null");
    // After `expr.`: the members of its type (or the variants of an enum literal).
    if (lsp_assist.completeMember(self, doc, id, params)) return;

    var b = std.ArrayList(u8).empty;
    defer b.deinit(self.gpa);
    b.append(self.gpa, '[') catch {};
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(self.gpa);
    var first = true;
    lsp_assist.addLocalNames(self, doc, params, &b, &seen, &first);

    if (lsp_assist.namesAnalysis(doc)) |analysis| if (analysis.symbols) |syms| {
        // After `alias::` offer the public names of that module, and nothing else.
        if (cursorOffset(doc, params)) |off| {
            const word = identRangeAt(doc.text, off);
            if (word.start >= 2 and std.mem.eql(u8, doc.text[word.start - 2 .. word.start], "::")) {
                const alias = identAt(doc.text, word.start - 2);
                if (syms.namespaces.get(doc.path)) |aliases| if (aliases.get(alias)) |target| {
                    for (syms.symbols.items) |sym| {
                        if (!sym.is_public or !topLevelKind(sym.kind) or hiddenName(sym.name)) continue;
                        if (!std.mem.eql(u8, sym.file_name, target)) continue;
                        appendCompletionItem(self, &b, &seen, &first, sym.name, completionKind(sym.kind), moduleLabel(target));
                    }
                };
                b.append(self.gpa, ']') catch {};
                return sendResult(self, id, b.items);
            }
        }

        // The names in scope in this file: its own declarations and what its imports bring in.
        if (syms.visible_names.get(doc.path)) |visible| {
            var it = visible.iterator();
            while (it.next()) |e| {
                const sym = syms.symbol(e.value_ptr.*);
                if (!topLevelKind(sym.kind) or hiddenName(sym.name)) continue;
                const detail: ?[]const u8 = if (std.mem.eql(u8, sym.file_name, doc.path)) null else moduleLabel(sym.file_name);
                appendCompletionItem(self, &b, &seen, &first, sym.name, completionKind(sym.kind), detail);
            }
        }
        // Namespace aliases (`#import a.b as c;`).
        if (syms.namespaces.get(doc.path)) |aliases| {
            var it = aliases.iterator();
            while (it.next()) |e| appendCompletionItem(self, &b, &seen, &first, e.key_ptr.*, 9, moduleLabel(e.value_ptr.*));
        }
        // Names inside this file that are not top level (locals, parameters, fields).
        for (syms.symbols.items) |sym| {
            if (!std.mem.eql(u8, sym.file_name, doc.path) or topLevelKind(sym.kind) or hiddenName(sym.name)) continue;
            switch (sym.kind) {
                .param, .local_val, .local_var, .local_const, .variant => {},
                else => continue,
            }
            appendCompletionItem(self, &b, &seen, &first, sym.name, completionKind(sym.kind), null);
        }
    };
    for (keywords) |kw| {
        if (seen.contains(kw)) continue;
        if (!first) b.append(self.gpa, ',') catch {};
        first = false;
        b.appendSlice(self.gpa, "{\"label\":\"") catch {};
        escapeInto(&b, self.gpa, kw);
        b.appendSlice(self.gpa, "\",\"kind\":14}") catch {}; // Keyword
    }
    b.append(self.gpa, ']') catch {};
    sendResult(self, id, b.items);
}

/// Find the symbol whose name matches the identifier under the cursor: a name in scope
/// of this file (its own or imported), `alias::name`, or else any symbol of that name.
fn symbolUnderCursor(doc: *Doc, params: json.Value) ?sema.Symbol {
    const analysis = doc.analysis orelse return null;
    const syms = analysis.symbols orelse return null;
    const off = cursorOffset(doc, params) orelse return null;
    const word = identRangeAt(doc.text, off);
    if (word.end <= word.start) return null;
    const name = doc.text[word.start..word.end];
    if (word.start >= 2 and std.mem.eql(u8, doc.text[word.start - 2 .. word.start], "::")) {
        const alias = identAt(doc.text, word.start - 2);
        if (alias.len > 0) if (syms.resolveScoped(doc.path, alias, name)) |sid| return syms.symbol(sid);
    }
    if (syms.resolveVisible(doc.path, name)) |sid| return syms.symbol(sid);
    for (syms.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, name) and !std.mem.eql(u8, sym.file_name, "<runtime>")) return sym;
    }
    return null;
}

/// The `#import` of this document whose text covers `off`, if any.
fn importAt(doc: *Doc, off: usize) ?ast.ImportDecl {
    const analysis = doc.analysis orelse return null;
    for (analysis.module.items) |item| switch (item) {
        .import => |imp| {
            if (!std.mem.eql(u8, imp.file_name, doc.path)) continue;
            if (off >= imp.span.start and off <= imp.span.end) return imp;
        },
        else => {},
    };
    return null;
}

fn appendLocation(self: *Server, b: *std.ArrayList(u8), uri: []const u8, text: []const u8, span: Span) void {
    b.appendSlice(self.gpa, "{\"uri\":\"") catch {};
    escapeInto(b, self.gpa, uri);
    b.appendSlice(self.gpa, "\",\"range\":") catch {};
    appendRange(b, self.gpa, text, span);
    b.append(self.gpa, '}') catch {};
}

fn handleDefinition(self: *Server, id: ?json.Value, params: json.Value) void {
    const doc = docFromParams(self, params) orelse return sendResult(self, id, "null");
    const analysis = doc.analysis orelse return sendResult(self, id, "null");

    var b = std.ArrayList(u8).empty;
    defer b.deinit(self.gpa);

    // On the module path of an `#import`: go to the top of that file.
    if (cursorOffset(doc, params)) |off| if (importAt(doc, off)) |imp| {
        const word = identAt(doc.text, off);
        const on_path = for (imp.path) |seg| {
            if (std.mem.eql(u8, seg, word)) break true;
        } else false;
        if (on_path) if (imp.resolved_file) |target| {
            if (analysis.fileNamed(target)) |f| {
                const uri = self.uriFor(f.path) orelse return sendResult(self, id, "null");
                defer self.gpa.free(uri);
                appendLocation(self, &b, uri, f.source, Span.new(0, 0));
                return sendResult(self, id, b.items);
            }
        };
    };

    const sym = symbolUnderCursor(doc, params) orelse return sendResult(self, id, "null");
    if (std.mem.eql(u8, sym.file_name, "<runtime>")) return sendResult(self, id, "null");
    const file = analysis.fileNamed(sym.file_name) orelse return sendResult(self, id, "null");
    const uri = self.uriFor(file.path) orelse return sendResult(self, id, "null");
    defer self.gpa.free(uri);
    appendLocation(self, &b, uri, file.source, nameSpan(file.source, sym.span, sym.name));
    sendResult(self, id, b.items);
}

/// The declaration line of a symbol as written in its file: for a function everything up to
/// the body, for other declarations the first line.
pub fn declarationText(analysis: pipeline.Analysis, sym: sema.Symbol, file_source: []const u8) []const u8 {
    var end: usize = @min(sym.span.end, file_source.len);
    for (analysis.module.items) |item| switch (item) {
        .function => |f| {
            if (!std.mem.eql(u8, f.file_name, sym.file_name) or !std.mem.eql(u8, f.name, sym.name)) continue;
            if (f.span.start != sym.span.start) continue;
            if (f.body) |body| end = @min(body.span.start, end);
        },
        else => {},
    };
    const start = @min(sym.span.start, end);
    var text = std.mem.trim(u8, file_source[start..end], " \t\r\n");
    // Other declarations: stop at the line end or the opening brace, whichever is first.
    if (std.mem.indexOfAny(u8, text, "\r\n")) |i| text = std.mem.trimEnd(u8, text[0..i], " \t");
    if (std.mem.indexOfScalar(u8, text, '{')) |i| {
        const head = std.mem.trimEnd(u8, text[0..i], " \t");
        if (head.len > 0) text = head;
    }
    if (text.len > 240) text = text[0..240];
    return text;
}

fn handleHover(self: *Server, id: ?json.Value, params: json.Value) void {
    const doc = docFromParams(self, params) orelse return sendResult(self, id, "null");
    // Locals, parameters and members (`name: Type`), and everything while the text does not parse.
    if (lsp_assist.hover(self, doc, id, params)) return;
    const analysis = doc.analysis orelse return sendResult(self, id, "null");
    const sym = symbolUnderCursor(doc, params) orelse return sendResult(self, id, "null");

    var b = std.ArrayList(u8).empty;
    defer b.deinit(self.gpa);
    b.appendSlice(self.gpa, "{\"contents\":{\"kind\":\"markdown\",\"value\":\"```fels\\n") catch {};
    const decl: ?[]const u8 = if (topLevelKind(sym.kind) or sym.kind == .field or sym.kind == .variant)
        (if (analysis.fileNamed(sym.file_name)) |f| declarationText(analysis, sym, f.source) else null)
    else
        null;
    if (decl) |text| {
        escapeInto(&b, self.gpa, text);
    } else {
        escapeInto(&b, self.gpa, sym.kind.label());
        b.appendSlice(self.gpa, " ") catch {};
        escapeInto(&b, self.gpa, sym.name);
    }
    b.appendSlice(self.gpa, "\\n```") catch {};
    if (!std.mem.eql(u8, sym.file_name, doc.path) and !std.mem.eql(u8, sym.file_name, "<runtime>")) {
        b.appendSlice(self.gpa, "\\n\\nfrom `") catch {};
        escapeInto(&b, self.gpa, moduleLabel(sym.file_name));
        b.append(self.gpa, '`') catch {};
    }
    b.appendSlice(self.gpa, "\"}}") catch {};
    sendResult(self, id, b.items);
}

fn appendDocSymbol(
    self: *Server,
    b: *std.ArrayList(u8),
    first: *bool,
    text: []const u8,
    name: []const u8,
    kind: u8,
    full: Span,
    selection: Span,
    detail: ?[]const u8,
) void {
    if (!first.*) b.append(self.gpa, ',') catch {};
    first.* = false;
    b.appendSlice(self.gpa, "{\"name\":\"") catch {};
    escapeInto(b, self.gpa, name);
    b.print(self.gpa, "\",\"kind\":{d},", .{kind}) catch {};
    if (detail) |d| {
        b.appendSlice(self.gpa, "\"detail\":\"") catch {};
        escapeInto(b, self.gpa, d);
        b.appendSlice(self.gpa, "\",") catch {};
    }
    b.appendSlice(self.gpa, "\"range\":") catch {};
    appendRange(b, self.gpa, text, full);
    b.appendSlice(self.gpa, ",\"selectionRange\":") catch {};
    appendRange(b, self.gpa, text, selection);
    b.append(self.gpa, '}') catch {};
}

fn handleDocumentSymbol(self: *Server, id: ?json.Value, params: json.Value) void {
    const doc = docFromParams(self, params) orelse return sendResult(self, id, "null");

    var b = std.ArrayList(u8).empty;
    defer b.deinit(self.gpa);
    b.append(self.gpa, '[') catch {};
    var first = true;
    if (doc.analysis) |analysis| if (analysis.symbols) |syms| {
        // The declarations of this file.
        for (syms.symbols.items) |sym| {
            if (!topLevelKind(sym.kind)) continue;
            if (!std.mem.eql(u8, sym.file_name, doc.path)) continue;
            if (hiddenName(sym.name) and std.mem.indexOfScalar(u8, sym.name, '.') != null) continue; // hoisted methods
            if (ast.isBodyConstName(sym.name)) continue; // a function body's constants
            appendDocSymbol(self, &b, &first, doc.text, sym.name, symbolKind(sym.kind), sym.span, nameSpan(doc.text, sym.span, sym.name), null);
        }
        // The names its imports bring in, placed on the `#import` line.
        for (analysis.module.items) |item| switch (item) {
            .import => |imp| {
                if (!std.mem.eql(u8, imp.file_name, doc.path)) continue;
                const target = imp.resolved_file orelse continue;
                const module_name = moduleLabel(target);
                if (imp.names) |names| {
                    for (names) |n| {
                        const kind: u8 = if (findPublic(syms, target, n)) |s| symbolKind(s.kind) else 13;
                        appendDocSymbol(self, &b, &first, doc.text, n, kind, imp.span, imp.span, module_name);
                    }
                } else if (imp.namespace()) |ns| {
                    appendDocSymbol(self, &b, &first, doc.text, ns, 3, imp.span, imp.span, module_name);
                } else if (imp.glob) {
                    for (syms.symbols.items) |s| {
                        if (!s.is_public or !topLevelKind(s.kind) or hiddenName(s.name)) continue;
                        if (!std.mem.eql(u8, s.file_name, target)) continue;
                        appendDocSymbol(self, &b, &first, doc.text, s.name, symbolKind(s.kind), imp.span, imp.span, module_name);
                    }
                }
            },
            else => {},
        };
    };
    b.append(self.gpa, ']') catch {};
    sendResult(self, id, b.items);
}

fn findPublic(syms: sema.SymbolTable, file: []const u8, name: []const u8) ?sema.Symbol {
    for (syms.symbols.items) |s| {
        if (s.is_public and std.mem.eql(u8, s.file_name, file) and std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

fn dispatch(self: *Server, root: json.Value) void {
    const method = getStr(root, "method") orelse return;
    const id = objGet(root, "id");
    const params = objGet(root, "params") orelse json.Value{ .null = {} };

    if (std.mem.eql(u8, method, "initialize")) {
        handleInitialize(self, id, params);
    } else if (std.mem.eql(u8, method, "initialized")) {
        // notification, no-op
    } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
        const td = objGet(params, "textDocument") orelse return;
        const uri = getStr(td, "uri") orelse return;
        const text = getStr(td, "text") orelse return;
        self.open(uri, text);
    } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
        const td = objGet(params, "textDocument") orelse return;
        const uri = getStr(td, "uri") orelse return;
        const changes = objGet(params, "contentChanges") orelse return;
        // Full-sync: the last change carries the whole document.
        switch (changes) {
            .array => |arr| {
                if (arr.items.len == 0) return;
                const last = arr.items[arr.items.len - 1];
                const text = getStr(last, "text") orelse return;
                self.open(uri, text);
            },
            else => {},
        }
    } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
        const td = objGet(params, "textDocument") orelse return;
        const uri = getStr(td, "uri") orelse return;
        self.close(uri);
    } else if (std.mem.eql(u8, method, "textDocument/completion")) {
        self.flush();
        handleCompletion(self, id, params);
    } else if (std.mem.eql(u8, method, "textDocument/hover")) {
        self.flush();
        handleHover(self, id, params);
    } else if (std.mem.eql(u8, method, "textDocument/definition")) {
        self.flush();
        handleDefinition(self, id, params);
    } else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
        self.flush();
        handleDocumentSymbol(self, id, params);
    } else if (std.mem.eql(u8, method, "textDocument/signatureHelp")) {
        self.flush();
        lsp_assist.handleSignatureHelp(self, id, params);
    } else if (std.mem.eql(u8, method, "textDocument/inlayHint")) {
        self.flush();
        lsp_assist.handleInlayHint(self, id, params);
    } else if (lsp_nav.handles(method)) {
        self.flush();
        lsp_nav.dispatch(self, method, id, params);
    } else if (std.mem.eql(u8, method, "shutdown")) {
        self.flush();
        self.shutdown_requested = true;
        sendResult(self, id, "null");
    } else if (std.mem.eql(u8, method, "exit")) {
        self.flush();
        self.shutdown_requested = true;
    } else if (id != null) {
        // Unknown request: reply null so the client isn't left waiting.
        sendResult(self, id, "null");
    }
}

// The stdio loop

/// Print the time of each analysis to stderr (set from `FELS_LSP_TIMING`).
pub var timing: bool = false;

pub fn run(gpa: std.mem.Allocator, io: std.Io, environ: ?*const std.process.Environ.Map) u8 {
    var in_buf: [1 << 16]u8 = undefined;
    var out_buf: [1 << 16]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &in_buf);
    // The editor reads the server's stdout through a pipe: streaming writes, not positional ones.
    var writer = std.Io.File.stdout().writerStreaming(io, &out_buf);

    var server = Server{ .gpa = gpa, .io = io, .out = &writer.interface, .environ = environ };
    server.timing = timing;
    defer {
        var it = server.docs.valueIterator();
        while (it.next()) |d| {
            d.*.deinit(gpa);
            gpa.destroy(d.*);
        }
        server.docs.deinit(gpa);
        server.by_key.deinit(gpa);
        var pit = server.published.iterator();
        while (pit.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        server.published.deinit(gpa);
        if (server.workspace_root) |r| gpa.free(r);
        server.nav.deinit(gpa);
        var projects = server.projects.iterator();
        while (projects.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.*.arena.deinit();
            gpa.destroy(e.value_ptr.*);
        }
        server.projects.deinit(gpa);
    }

    while (!server.shutdown_requested) {
        // Analyze what changed once no more input is waiting, so a burst of edits costs one
        // analysis instead of one per keystroke.
        if (reader.interface.bufferedLen() == 0) server.flush();

        // Read headers: lines until a blank line, extracting Content-Length.
        var content_len: usize = 0;
        var got_header = false;
        while (true) {
            const line = reader.interface.takeDelimiterInclusive('\n') catch return 0; // EOF -> exit
            const trimmed = std.mem.trimEnd(u8, line, "\r\n");
            if (trimmed.len == 0) break; // end of headers
            got_header = true;
            const prefix = "Content-Length:";
            if (std.ascii.startsWithIgnoreCase(trimmed, prefix)) {
                const num = std.mem.trim(u8, trimmed[prefix.len..], " ");
                content_len = std.fmt.parseInt(usize, num, 10) catch 0;
            }
        }
        if (!got_header or content_len == 0) continue;

        const body = reader.interface.readAlloc(gpa, content_len) catch return 0;
        defer gpa.free(body);

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const root = json.parseFromSliceLeaky(json.Value, arena.allocator(), body, .{}) catch continue;
        dispatch(&server, root);
    }
    return 0;
}

// Tests

test {
    _ = lsp_assist;
}

test "lsp: byte offset ↔ UTF-16 position round-trips, incl. multibyte" {
    const t = std.testing;
    const src = "ab\ncдe\nx"; // 'д' is 2 UTF-8 bytes, 1 UTF-16 unit
    // line 0
    try t.expectEqual(Pos{ .line = 0, .char = 0 }, byteToPos(src, 0));
    try t.expectEqual(Pos{ .line = 0, .char = 2 }, byteToPos(src, 2));
    // line 1: 'c'(1) 'д'(2 bytes) 'e' — byte offset of 'e' is start+1+2 = 4..
    const line1_start = std.mem.indexOfScalar(u8, src, '\n').? + 1;
    // 'e' sits one UTF-16 unit past 'д' (which is one unit past 'c')
    const e_byte = line1_start + 1 + 2;
    try t.expectEqual(Pos{ .line = 1, .char = 2 }, byteToPos(src, e_byte));
    // round-trip back
    try t.expectEqual(e_byte, posToByte(src, 1, 2));
    try t.expectEqual(@as(usize, 2), posToByte(src, 0, 2));
}

test "lsp: identifier under a byte offset" {
    const t = std.testing;
    const src = "foo bar_baz + qux";
    try t.expectEqualStrings("foo", identAt(src, 1));
    try t.expectEqualStrings("bar_baz", identAt(src, 6));
    try t.expectEqualStrings("qux", identAt(src, 17)); // end of buffer
    try t.expectEqualStrings("", identAt(src, 12)); // on the '+'
}

// Analysis tests (an in-memory file system stands in for the editor and the disk)

const MemFiles = struct {
    names: []const []const u8,
    texts: []const []const u8,

    /// The loader joins `.` and the file name with the native separator.
    fn same(name: []const u8, path: []const u8) bool {
        const rest = if (path.len > 2 and path[0] == '.' and (path[1] == '/' or path[1] == '\\')) path[2..] else path;
        return std.mem.eql(u8, name, rest);
    }

    fn read(ctx: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
        const self: *MemFiles = @ptrCast(@alignCast(ctx.?));
        for (self.names, 0..) |n, i| if (same(n, path))
            return allocator.dupe(u8, self.texts[i]) catch null;
        // Anything else (std) comes from the real disk.
        return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .unlimited) catch null;
    }

    fn exists(ctx: ?*anyopaque, path: []const u8) bool {
        const self: *MemFiles = @ptrCast(@alignCast(ctx.?));
        for (self.names) |n| if (same(n, path)) return true;
        std.Io.Dir.cwd().access(std.testing.io, path, .{}) catch return false;
        return true;
    }

    fn analyze(self: *MemFiles, root: []const u8, runtime: bool) !pipeline.Analysis {
        return pipeline.analyzeFile(std.testing.allocator, root, .{
            .reader = .{ .ctx = self, .readFn = read, .existsFn = exists },
            .include_runtime = runtime,
        });
    }
};

fn countFor(a: pipeline.Analysis, file: []const u8) usize {
    var n: usize = 0;
    for (a.diagnostics) |d| {
        if (MemFiles.same(file, d.file)) n += 1;
    }
    return n;
}

test "lsp: a sibling module is loaded and its names are in scope" {
    var mem = MemFiles{
        .names = &.{ "util.fels", "main.fels" },
        .texts = &.{
            "pub add :: fn(a: i32, b: i32) -> i32 { return a + b; }\n",
            "#import util.{ add };\nmain :: fn() -> i32 { return add(1, 2); }\n",
        },
    };
    var a = try mem.analyze("main.fels", false);
    defer a.deinit();
    try std.testing.expectEqual(@as(usize, 0), a.diagnostics.len);
    try std.testing.expect(a.symbols != null);
    try std.testing.expect(a.symbols.?.resolveVisible("main.fels", "add") != null);
}

test "lsp: a name missing from an imported module is an error on the import" {
    var mem = MemFiles{
        .names = &.{ "util.fels", "main.fels" },
        .texts = &.{
            "pub plus :: fn(a: i32, b: i32) -> i32 { return a + b; }\n",
            "#import util.{ add };\nmain :: fn() -> i32 { return add(1, 2); }\n",
        },
    };
    var a = try mem.analyze("main.fels", false);
    defer a.deinit();
    try std.testing.expect(countFor(a, "main.fels") >= 1);
    try std.testing.expectEqual(@as(usize, 0), countFor(a, "util.fels"));
    try std.testing.expect(a.symbols != null);
}

test "lsp: a file with a syntax error gives its diagnostics and no symbols" {
    var mem = MemFiles{ .names = &.{"main.fels"}, .texts = &.{"main :: fn() -> i32 {\n    return 1\n}\n"} };
    var a = try mem.analyze("main.fels", false);
    defer a.deinit();
    try std.testing.expect(countFor(a, "main.fels") >= 1);
    try std.testing.expect(a.symbols == null);
}

test "lsp: an import that cannot be found is reported on the import" {
    var mem = MemFiles{ .names = &.{"main.fels"}, .texts = &.{"#import nowhere.{ x };\nmain :: fn() {}\n"} };
    var a = try mem.analyze("main.fels", false);
    defer a.deinit();
    try std.testing.expectEqual(@as(usize, 1), countFor(a, "main.fels"));
    try std.testing.expectEqual(@as(usize, 0), a.diagnostics[0].span.start);
}

test "lsp: an error in an imported module belongs to that module" {
    var mem = MemFiles{
        .names = &.{ "util.fels", "main.fels" },
        .texts = &.{
            "pub bad :: fn() -> i32 { return true; }\n",
            "#import util.{ bad };\nmain :: fn() -> i32 { return bad(); }\n",
        },
    };
    var a = try mem.analyze("main.fels", false);
    defer a.deinit();
    try std.testing.expectEqual(@as(usize, 0), countFor(a, "main.fels"));
    try std.testing.expect(countFor(a, "util.fels") >= 1);
}

test "lsp: a name of std.heap's that a file with a zone declares too is reported on the zone" {
    const src = "make :: fn() -> i32 { return 3; }\nmain :: fn() -> i32 {\n    zone z: Arena { }\n    return make();\n}\n";
    var mem = MemFiles{ .names = &.{"main.fels"}, .texts = &.{src} };
    var a = try mem.analyze("main.fels", false);
    defer a.deinit();
    try std.testing.expectEqual(@as(usize, 1), countFor(a, "main.fels"));
    const d = for (a.diagnostics) |d| {
        if (MemFiles.same("main.fels", d.file)) break d;
    } else unreachable;
    try std.testing.expect(std.mem.indexOf(u8, d.message, "a `zone` brings in std.heap's `make`") != null);
    try std.testing.expectEqual(std.mem.indexOf(u8, src, "zone").?, d.span.start);
}

test "lsp: std is loaded and marked, and Mutex is known" {
    var mem = MemFiles{
        .names = &.{"main.fels"},
        .texts = &.{"#import std.sync.{ Mutex };\nmain :: fn() { m: Mutex = Mutex.new(); }\n"},
    };
    var a = try mem.analyze("main.fels", true);
    defer a.deinit();
    var std_files: usize = 0;
    for (a.files) |f| {
        if (f.is_std) std_files += 1;
    }
    try std.testing.expect(std_files >= 1);
    for (a.diagnostics) |d| {
        try std.testing.expect(std.mem.indexOf(u8, d.message, "unknown type `Mutex`") == null);
    }
}

test "lsp: file URIs and paths convert both ways" {
    const gpa = std.testing.allocator;
    const p = try uriToPath(gpa, "file:///c%3A/dev/my%20proj/a.fels");
    defer gpa.free(p);
    if (is_windows) {
        try std.testing.expectEqualStrings("c:\\dev\\my proj\\a.fels", p);
    } else {
        try std.testing.expectEqualStrings("/c:/dev/my proj/a.fels", p);
    }
    const u = try pathToUri(gpa, "C:\\dev\\my proj\\a.fels");
    defer gpa.free(u);
    try std.testing.expectEqualStrings("file:///C:/dev/my%20proj/a.fels", u);
}
