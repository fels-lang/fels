//! `fels test`: run the `#test` functions of a project's files.
//!
//! Each file is compiled on its own. A file that does not compile shows its diagnostics and
//! counts as failed. Of a file that compiles, the `#test` functions declared in that file run
//! (not those of the files it imports; they run when those files are tested). Imports resolve
//! as in `fels build`: the packages of fels.pkg and the project's own package name.
//!
//! With LLVM, the tests of a file run as a native program (`pipeline.test_runner`): they can
//! read files, call C and do whatever the program can. The program is linked like an
//! artifact of the project and runs in the project folder. Without LLVM, or with
//! `comptime_only`, they run on the comptime VM, as `fels build` runs them.

const std = @import("std");
const pipeline = @import("pipeline.zig");
const ir = @import("ir.zig");
const diagnostic = @import("diagnostic.zig");
const runtime = @import("runtime.zig");
const style = @import("style.zig");
const pkg = @import("pkg.zig");
const build = @import("build.zig");
const driver = @import("driver.zig");
const build_options = @import("build_options");

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
    /// Run the tests on the comptime VM, also when native test programs can be built.
    comptime_only: bool = false,
    /// For linking the test programs: the LLVM bin folder and the library folders, as
    /// `fels build` gets them.
    llvm_bin: []const u8 = "",
    lib_paths: []const []const u8 = &.{},
};

pub const Summary = struct {
    passed: u32 = 0,
    failed: u32 = 0,
    /// Tests the comptime VM cannot run (the VM lane only).
    skipped: u32 = 0,
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
    var packages: []const pkg.resolve.Package = &.{};
    if (loaded) |r| {
        if (r.self_root) |s| try roots.append(a, s);
        for (r.packages) |p| try roots.append(a, .{ .name = p.name, .dir = p.import_dir });
        caps = try build.folderCaps(a, r.packages);
        packages = r.packages;
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

    var native: ?Native = null;
    if (build_options.enable_llvm and !opts.comptime_only)
        native = try Native.init(gpa, io, a, out, opts, packages, caps);

    var summary: Summary = .{};
    for (files.list.items) |path| {
        try testFile(gpa, io, out, path, try displayPath(a, path), opts.palette, if (native) |*n| n else null, &summary);
        try out.flush();
    }

    if (summary.passed + summary.failed + summary.skipped == 0)
        try out.writeAll("no #test functions found")
    else
        try out.print("{d} passed, {d} failed", .{ summary.passed, summary.failed });
    if (summary.skipped != 0) try out.print(", {d} skipped", .{summary.skipped});
    if (summary.broken != 0)
        try out.print(", {d} {s}", .{ summary.broken, if (summary.broken == 1) "file has errors" else "files have errors" });
    try out.writeAll("\n");
    try out.flush();
    return summary;
}

/// Compile one file, show its diagnostics, and run its own `#test` functions: as a native
/// program with `native`, else on the comptime VM.
fn testFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    path: []const u8,
    display: []const u8,
    palette: style.Palette,
    native: ?*const Native,
    summary: *Summary,
) Error!void {
    const saved_runner = pipeline.test_runner;
    pipeline.test_runner = native != null;
    defer pipeline.test_runner = saved_runner;
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
    if (native) |n| return n.testFile(gpa, io, out, fe, path, display, summary);
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
        else if (r.skipped) |why|
            try out.print("  - {s}: skipped ({s})\n", .{ r.name, why })
        else
            try out.print("  \u{2713} {s}\n", .{r.name});
    }
    summary.passed += report.passed;
    summary.failed += report.failed;
    summary.skipped += report.skipped;
}

/// How the test programs are built and run.
const Native = struct {
    llvm_bin: []const u8,
    lib_paths: []const []const u8,
    libs: []const []const u8,
    runtime_files: []const []const u8,
    /// Where the programs go: `.fels-cache/test` in the project folder.
    out_dir: []const u8,
    /// The project folder, where the programs run.
    cwd: []const u8,

    fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        a: std.mem.Allocator,
        out: *std.Io.Writer,
        opts: Options,
        packages: []const pkg.resolve.Package,
        caps: []const ir.FolderCaps,
    ) Error!Native {
        const link = build.testLinkInputs(gpa, io, a, opts.project_dir, packages, caps) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                // The reason is printed above.
                try out.writeAll("fels test: the build.fels of the project or of a package failed\n");
                try out.flush();
                return error.PackageError;
            },
        };
        var lib_paths: std.ArrayList([]const u8) = .empty;
        try lib_paths.appendSlice(a, opts.lib_paths);
        try lib_paths.appendSlice(a, link.lib_paths.items);
        const cwd = std.process.currentPathAlloc(io, a) catch try a.dupe(u8, ".");
        const project = try std.fs.path.resolve(a, &.{ cwd, opts.project_dir });
        const out_dir = try std.fs.path.join(a, &.{ project, ".fels-cache", "test" });
        std.Io.Dir.cwd().createDirPath(io, out_dir) catch {};
        return .{
            .llvm_bin = opts.llvm_bin,
            .lib_paths = lib_paths.items,
            .libs = link.links.items,
            .runtime_files = link.runtime_files.items,
            .out_dir = out_dir,
            .cwd = project,
        };
    }

    /// Build the test program of the file `fe` compiled (with `pipeline.test_runner`), run
    /// it, and report each test.
    fn testFile(
        self: *const Native,
        gpa: std.mem.Allocator,
        io: std.Io,
        out: *std.Io.Writer,
        fe: pipeline.FrontEnd,
        path: []const u8,
        display: []const u8,
        summary: *Summary,
    ) Error!void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        // One program per file, also for files of the same name in different folders.
        const flat = try a.dupe(u8, display);
        for (flat) |*c| if (c.* == '/' or c.* == ':') {
            c.* = '_';
        };
        const exe = try std.fmt.allocPrint(a, "{s}{c}{s}.exe", .{ self.out_dir, std.fs.path.sep, flat });
        const obj = try std.fmt.allocPrint(a, "{s}.o", .{exe});
        driver.emitLlvmFromFrontend(gpa, io, fe, .{
            .file_name = path,
            .source = "",
            .obj_path = obj,
            .exe_path = exe,
            .opt_level = 0,
            .llvm_bin = self.llvm_bin,
            .lib_paths = self.lib_paths,
            .extra_libs = self.libs,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                // The linker or the backend printed the reason.
                try out.print("{s}\n  \u{2717} the test program does not build\n", .{display});
                summary.broken += 1;
                return;
            },
        };
        self.copyRuntimeFiles(gpa, io);

        try out.print("{s}\n", .{display});
        // After a crash, or a `t.fatal`, the program starts again behind that test.
        var from: u32 = 0;
        while (true) {
            var num: [16]u8 = undefined;
            const argv: []const []const u8 = if (from == 0)
                &.{exe}
            else
                &.{ exe, std.fmt.bufPrint(&num, "{d}", .{from}) catch unreachable };
            const r = std.process.run(a, io, .{ .argv = argv, .cwd = .{ .path = self.cwd } }) catch {
                try out.writeAll("  \u{2717} the test program could not be started\n");
                summary.broken += 1;
                return;
            };
            const ran = try readRun(a, out, r, summary);
            if (ran.done) return;
            if (ran.started == 0) {
                // It stopped before the first test it was to run.
                try out.print("  \u{2717} the test program stopped before its tests ran{s}\n", .{try exitText(a, r)});
                summary.broken += 1;
                return;
            }
            from += ran.started;
        }
    }

    /// Copy the runtime files (DLLs) next to the test programs, so they start.
    fn copyRuntimeFiles(self: *const Native, gpa: std.mem.Allocator, io: std.Io) void {
        for (self.runtime_files) |src| {
            const data = std.Io.Dir.cwd().readFileAlloc(io, src, gpa, .unlimited) catch continue;
            defer gpa.free(data);
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const dst = std.fmt.bufPrint(&buf, "{s}{c}{s}", .{ self.out_dir, std.fs.path.sep, std.fs.path.basename(src) }) catch continue;
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = data }) catch {};
        }
    }
};

/// What a test program writes before its lines of the test protocol
/// (`ast_prelude.runtime_testing_source`).
const marker = "@@fels-test ";

/// One run of a test program.
const Ran = struct {
    /// The tests that started.
    started: u32 = 0,
    /// The program got to the end: every test ran.
    done: bool = false,
};

/// Read the protocol lines of a test program's output, and report the tests in it. Text a
/// test printed is shown when the test fails.
fn readRun(a: std.mem.Allocator, out: *std.Io.Writer, r: std.process.RunResult, summary: *Summary) Error!Ran {
    var ran: Ran = .{};
    var current: ?[]const u8 = null;
    var msgs: std.ArrayList([]const u8) = .empty;
    var printed: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line, marker)) {
            if (current != null) {
                try printed.appendSlice(a, line);
                try printed.append(a, '\n');
            }
            continue;
        }
        const what = line[marker.len..];
        if (std.mem.startsWith(u8, what, "RUN ")) {
            current = what["RUN ".len..];
            ran.started += 1;
            msgs.clearRetainingCapacity();
            printed.clearRetainingCapacity();
        } else if (std.mem.startsWith(u8, what, "MSG ")) {
            try msgs.append(a, what["MSG ".len..]);
        } else if (std.mem.eql(u8, what, "PASS")) {
            if (current) |name| {
                try out.print("  \u{2713} {s}\n", .{name});
                summary.passed += 1;
            }
            current = null;
        } else if (std.mem.eql(u8, what, "FAIL")) {
            if (current) |name| {
                try printFailure(out, name, msgs.items, printed.items);
                summary.failed += 1;
            }
            current = null;
        } else if (std.mem.eql(u8, what, "END")) {
            ran.done = true;
        }
    }
    // The program ended inside a test: it crashed (or called `exit`).
    if (current) |name| {
        const stderr = std.mem.trim(u8, r.stderr, " \r\n");
        const why = if (stderr.len != 0) stderr else try std.fmt.allocPrint(a, "crashed{s}", .{try exitText(a, r)});
        try msgs.append(a, why);
        try printFailure(out, name, msgs.items, printed.items);
        summary.failed += 1;
    }
    return ran;
}

/// `✗ name: first message`, the other messages below it, then what the test printed.
fn printFailure(out: *std.Io.Writer, name: []const u8, msgs: []const []const u8, printed: []const u8) Error!void {
    if (msgs.len == 0)
        try out.print("  \u{2717} {s}\n", .{name})
    else
        try out.print("  \u{2717} {s}: {s}\n", .{ name, msgs[0] });
    if (msgs.len > 1) for (msgs[1..]) |m| try out.print("      {s}\n", .{m});
    const text = std.mem.trim(u8, printed, " \r\n");
    if (text.len == 0) return;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| try out.print("      | {s}\n", .{std.mem.trimEnd(u8, l, "\r")});
}

/// ` (exit code N)` for how the program ended, or nothing.
fn exitText(a: std.mem.Allocator, r: std.process.RunResult) error{OutOfMemory}![]const u8 {
    return switch (r.term) {
        .exited => |code| try std.fmt.allocPrint(a, " (exit code {d})", .{code}),
        else => "",
    };
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
/// commands' output. `opts` is all but the colors. Returns the exit code: 1 when a test
/// failed or a file has errors.
pub fn cmd(gpa: std.mem.Allocator, io: std.Io, opts: Options) u8 {
    var buf: [4096]u8 = undefined;
    // Streaming: the parser prints to stderr too, and a positional writer would write over it
    // when stderr is a file.
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    var with_colors = opts;
    with_colors.palette = style.forStderr();
    const summary = run(gpa, io, &w.interface, with_colors) catch |err| {
        w.interface.flush() catch {};
        switch (err) {
            error.PackageError, error.BadPath => {},
            else => std.debug.print("fels test: {s}\n", .{@errorName(err)}),
        }
        return 1;
    };
    return if (summary.ok()) 0 else 1;
}
