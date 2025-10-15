//! `fels test`: run the `#test` functions of a project's files on the comptime VM.
//!
//! Each file is compiled on its own, the front end with the runtime as `fels check` does, and
//! nothing is generated or linked, so this works without LLVM. A file that does not compile
//! shows its diagnostics and counts as failed. Of a file that compiles, the `#test` functions
//! declared in that file run (not those of the files it imports; they run when those files are
//! tested). Imports resolve as in `fels build`: the packages of fels.pkg and the project's own
//! package name.

const std = @import("std");
const pipeline = @import("pipeline.zig");
const ir = @import("ir.zig");
const diagnostic = @import("diagnostic.zig");
const runtime = @import("runtime.zig");
const style = @import("style.zig");
const pkg = @import("pkg.zig");
const build = @import("build.zig");

pub const Options = struct {
    /// The project folder. Its fels.pkg gives the packages and the project's own package, and
    /// with no `paths` its `src/` folder (or the folder itself when there is none) is tested.
    project_dir: []const u8 = ".",
    /// The files and folders to test, as given on the command line. Empty means the project's.
    paths: []const []const u8 = &.{},
    /// The environment (where the package cache is).
    environ: ?*const std.process.Environ.Map = null,
    /// Colors for the diagnostics.
    palette: style.Palette = .plain,
};

pub const Summary = struct {
    passed: u32 = 0,
    failed: u32 = 0,
    /// Files that do not compile, or whose tests the comptime VM cannot run.
    broken: u32 = 0,

    pub fn ok(self: Summary) bool {
        return self.failed == 0 and self.broken == 0;
    }
};

pub const Error = error{
    OutOfMemory,
    WriteFailed,
    /// fels.pkg has a mistake; the message is printed.
    PackageError,
    /// A path that is neither a folder nor a `.fels` file; the message is written to `out`.
    BadPath,
};

/// Folders a folder walk does not enter, besides hidden ones (`.git`, `.fels-cache`, ...).
const skipped_dirs = [_][]const u8{ "zig-out", "vendor", "dist" };

fn skipDir(name: []const u8) bool {
    if (name.len > 0 and name[0] == '.') return true;
    for (skipped_dirs) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// Run the tests of `opts.paths` (or of the project) and write the report to `out`.
pub fn run(gpa: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, opts: Options) Error!Summary {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Imports resolve as in `fels build`. Packages come from fels.lock and the cache only: a
    // test run never runs git and never writes fels.lock.
    const loaded = try pkg.project.load(a, io, opts.project_dir, opts.environ, .{ .skip_missing = true });
    var roots: std.ArrayList(pipeline.ModuleRoot) = .empty;
    var caps: []const ir.FolderCaps = &.{};
    if (loaded) |r| {
        if (r.self_root) |s| try roots.append(a, s);
        for (r.packages) |p| try roots.append(a, .{ .name = p.name, .dir = p.import_dir });
        caps = try build.folderCaps(a, r.packages);
        for (r.missing) |name|
            try out.print("note: the package `{s}` is in fels.pkg but not fetched yet; run `fels fetch`\n", .{name});
    }
    const saved_roots = pipeline.module_roots;
    pipeline.module_roots = roots.items;
    defer pipeline.module_roots = saved_roots;
    const saved_caps = ir.package_caps;
    ir.package_caps = caps;
    defer ir.package_caps = saved_caps;

    var files: Files = .{ .a = a };
    if (opts.paths.len == 0) {
        const src = try joinPath(a, opts.project_dir, "src");
        try files.addDir(io, if (isDir(io, src)) src else opts.project_dir);
    } else for (opts.paths) |p| {
        if (isDir(io, p)) {
            try files.addDir(io, p);
        } else if (pipeline.isSourceFile(p) and fileExists(io, p)) {
            try files.add(p);
        } else {
            if (fileExists(io, p))
                try out.print("fels test: {s} is not a .fels file or a folder\n", .{p})
            else
                try out.print("fels test: cannot find {s}\n", .{p});
            try out.flush();
            return error.BadPath;
        }
    }

    var summary: Summary = .{};
    for (files.list.items) |path| {
        try testFile(gpa, io, out, path, try displayPath(a, path), opts.palette, &summary);
        try out.flush();
    }

    if (summary.passed + summary.failed == 0)
        try out.writeAll("no #test functions found")
    else
        try out.print("{d} passed, {d} failed", .{ summary.passed, summary.failed });
    if (summary.broken != 0)
        try out.print(", {d} {s}", .{ summary.broken, if (summary.broken == 1) "file has errors" else "files have errors" });
    try out.writeAll("\n");
    try out.flush();
    return summary;
}

/// Compile one file, show its diagnostics, and run its own `#test` functions.
fn testFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    path: []const u8,
    display: []const u8,
    palette: style.Palette,
    summary: *Summary,
) Error!void {
    var fe = pipeline.compileFileWithRuntime(gpa, io, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            // The reason is already printed: a parse error, an import that cannot be read.
            try out.print("{s}\n  \u{2717} does not compile\n", .{display});
            summary.broken += 1;
            return;
        },
    };
    defer fe.deinit(gpa);

    if (fe.diagnostics().len != 0) {
        for (fe.diagnostics()) |d| {
            const file = if (d.file.len != 0) d.file else path;
            const src = if (std.mem.eql(u8, file, "<runtime>")) runtime.runtimeSource() else "";
            const text = try diagnostic.render(gpa, file, src, d, palette);
            defer gpa.free(text);
            try out.print("{s}\n", .{text});
        }
        try out.print("{s}\n  \u{2717} does not compile\n", .{display});
        summary.broken += 1;
        return;
    }

    const selected: ir.TestOptions = .{ .only_file = path };
    if (ir.countTestDecls(fe.module, selected) == 0) return;
    const report = ir.runComptimeTestsWith(gpa, fe, selected) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SemanticFailed => {
            try out.print("{s}\n  \u{2717} the comptime VM cannot load this file, so its tests do not run\n", .{display});
            summary.broken += 1;
            return;
        },
    };
    try out.print("{s}\n", .{display});
    for (report.results) |r| {
        if (r.failure) |why|
            try out.print("  \u{2717} {s}: {s}\n", .{ r.name, why })
        else
            try out.print("  \u{2713} {s}\n", .{r.name});
    }
    summary.passed += report.passed;
    summary.failed += report.failed;
}

/// The files to test, in order, each once.
const Files = struct {
    a: std.mem.Allocator,
    list: std.ArrayList([]const u8) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,

    fn add(self: *Files, path: []const u8) error{OutOfMemory}!void {
        const key = try displayPath(self.a, path);
        if (self.seen.contains(key)) return;
        try self.seen.put(self.a, key, {});
        try self.list.append(self.a, path);
    }

    /// The `.fels` files in `dir` and the folders below it, sorted. A build.fels is a build
    /// script, not a source of the project, and is left out.
    fn addDir(self: *Files, io: std.Io, dir: []const u8) error{OutOfMemory}!void {
        var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
        defer d.close(io);
        var walker = try d.walkSelectively(self.a);
        defer walker.deinit();
        var found: std.ArrayList([]const u8) = .empty;
        while (true) {
            const entry = walker.next(io) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            } orelse break;
            switch (entry.kind) {
                .directory => if (!skipDir(entry.basename)) walker.enter(io, entry) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {},
                },
                .file => if (pipeline.isSourceFile(entry.basename) and !std.mem.eql(u8, entry.basename, "build.fels"))
                    try found.append(self.a, try joinPath(self.a, dir, entry.path)),
                else => {},
            }
        }
        std.mem.sort([]const u8, found.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.lt);
        for (found.items) |f| try self.add(f);
    }
};

/// `path` as the report shows it: with `/` between the folders.
fn displayPath(a: std.mem.Allocator, path: []const u8) error{OutOfMemory}![]const u8 {
    const copy = try a.dupe(u8, path);
    std.mem.replaceScalar(u8, copy, '\\', '/');
    return copy;
}

fn joinPath(a: std.mem.Allocator, base: []const u8, rel: []const u8) error{OutOfMemory}![]const u8 {
    if (base.len == 0 or std.mem.eql(u8, base, ".")) return a.dupe(u8, rel);
    return std.fs.path.join(a, &.{ base, rel });
}

fn isDir(io: std.Io, path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// `fels test [paths...]` on the command line: the report goes to stderr, like the other
/// commands' output. Returns the exit code: 1 when a test failed or a file has errors.
pub fn cmd(gpa: std.mem.Allocator, io: std.Io, environ: ?*const std.process.Environ.Map, paths: []const []const u8) u8 {
    var buf: [4096]u8 = undefined;
    // Streaming: the parser prints to stderr too, and a positional writer would write over it
    // when stderr is a file.
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    const summary = run(gpa, io, &w.interface, .{
        .paths = paths,
        .environ = environ,
        .palette = style.forStderr(),
    }) catch |err| {
        w.interface.flush() catch {};
        switch (err) {
            error.PackageError, error.BadPath => {},
            else => std.debug.print("fels test: {s}\n", .{@errorName(err)}),
        }
        return 1;
    };
    return if (summary.ok()) 0 else 1;
}
