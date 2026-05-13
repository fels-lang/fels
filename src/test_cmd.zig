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
//!
//! The files are tested at the same time, each in a `fels test --worker` process of its own
//! (the compiler keeps its state in globals, so not in threads), and their reports are
//! printed in the order of the files.

const std = @import("std");
const pipeline = @import("pipeline.zig");
const ir = @import("ir.zig");
const diagnostic = @import("diagnostic.zig");
const runtime = @import("runtime.zig");
const style = @import("style.zig");
const ui = @import("ui.zig");
const clock = @import("clock.zig");
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
    /// Test the files in worker processes, this many at once (the command line gives the
    /// number of cores). With 0 or 1, and on the comptime VM, they are tested one by one here.
    jobs: usize = 0,
    /// The fels program the workers run, and the arguments they get besides
    /// `test --worker <file>` (`--std-path`).
    self_exe: []const u8 = "",
    worker_args: []const []const u8 = &.{},
    /// This process is a worker: it tests its file for a parent `fels test`, and ends its
    /// report with the counts for the parent instead of a summary.
    worker: bool = false,
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
    const started = clock.monoNs();
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
        caps = try build.folderCaps(a, io, r.packages);
        packages = r.packages;
        if (!opts.worker) for (r.missing) |name|
            try out.print("note: the package `{s}` is in fels.pkg but not fetched yet; run `fels fetch`\n", .{name});
    }
    const saved_roots = pipeline.module_roots;
    pipeline.module_roots = roots.items;
    defer pipeline.module_roots = saved_roots;
    const saved_caps = ir.package_caps;
    ir.package_caps = caps;
    defer ir.package_caps = saved_caps;
    // The project's own compile-time code reads below the project's folder.
    const saved_root = ir.project_root;
    defer ir.project_root = saved_root;
    if (saved_root == null) ir.project_root = build.absoluteDir(a, io, opts.project_dir);

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

    // On a terminal, the live tree: a node per file, with the stage it is in. A worker's tree
    // is its file's node in the tree of the parent `fels test`.
    if (opts.worker) {
        if (files.list.items.len != 0) ui.startWorker(try displayPath(a, files.list.items[0]));
    } else ui.start("fels test", files.list.items.len);
    defer ui.finish();
    var summary: Summary = .{};
    var slowest: Slowest = .{};
    const native_lane = build_options.enable_llvm and !opts.comptime_only;
    if (native_lane and !opts.worker and opts.jobs > 1 and files.list.items.len > 1 and opts.self_exe.len != 0) {
        try runWorkers(gpa, io, out, a, files.list.items, opts, &summary, &slowest);
    } else {
        var native: ?Native = null;
        if (native_lane) native = try Native.init(gpa, io, a, out, opts, packages, caps);
        for (files.list.items) |path| {
            const display = try displayPath(a, path);
            var stages = if (opts.worker) ui.Stages.in(ui.root) else ui.Stages.begin(ui.root, display);
            const before = summary;
            try testFile(gpa, io, out, path, display, opts.palette, if (native) |*n| n else null, &stages, &summary);
            const took = stages.end();
            if (summary.passed + summary.failed != before.passed + before.failed) slowest.add(display, took);
            try out.flush();
        }
    }
    ui.finish();

    if (opts.worker) {
        try out.print("{s}{d} {d} {d} {d}\n", .{ summary_marker, summary.passed, summary.failed, summary.skipped, summary.broken });
        try out.flush();
        return summary;
    }

    if (summary.passed + summary.failed + summary.skipped + summary.broken == 0) {
        try out.writeAll("no #test functions found\n");
    } else {
        try out.print("\n{s}Test Summary:{s} ", .{ ui.pal.bold(), ui.pal.reset() });
        try ui.writeCounts(out, &.{
            .{ .n = summary.passed, .what = "passed", .color = .good },
            .{ .n = summary.failed, .what = "failed", .color = .bad },
            .{ .n = summary.skipped, .what = "skipped", .color = .plain },
            .{ .n = summary.broken, .what = if (summary.broken == 1) "file has errors" else "files have errors", .color = .bad },
        });
        var d: [48]u8 = undefined;
        const took = clock.sinceNs(started);
        try out.print(" \u{00b7} {s}\n", .{ui.dimDuration(&d, took)});
        if (took >= std.time.ns_per_s) try slowest.write(out);
    }
    try out.flush();
    return summary;
}

/// The test files that took longest, for a line under the summary of a run of four or more.
const Slowest = struct {
    top: [3]File = .{ .{}, .{}, .{} },
    files: usize = 0,

    const File = struct { name: []const u8 = "", ns: u64 = 0 };

    fn add(self: *Slowest, name: []const u8, ns: u64) void {
        self.files += 1;
        var i: usize = self.top.len;
        while (i > 0 and self.top[i - 1].ns < ns) i -= 1;
        if (i == self.top.len) return;
        var j = self.top.len - 1;
        while (j > i) : (j -= 1) self.top[j] = self.top[j - 1];
        self.top[i] = .{ .name = name, .ns = ns };
    }

    /// `slowest: src/a_tests.fels 2.74s, src/b_tests.fels 2.70s, src/c_tests.fels 2.17s`
    fn write(self: *const Slowest, out: *std.Io.Writer) Error!void {
        if (self.files < 4) return;
        try out.print("{s}slowest:", .{ui.pal.dim()});
        for (self.top, 0..) |f, k| {
            if (f.ns == 0) break;
            var d: [24]u8 = undefined;
            try out.print("{s} {s} {s}", .{ if (k == 0) "" else ",", f.name, ui.duration(&d, f.ns) });
        }
        try out.print("{s}\n", .{ui.pal.reset()});
    }
};

/// What the last line of a worker's report starts with; the counts of `Summary` follow.
const summary_marker = "@@fels-test-summary ";

/// A file a worker process tests, and what it reported.
const Job = struct {
    path: []const u8,
    display: []const u8,
    /// Where the worker writes its report (its stderr).
    report_path: []const u8,
    /// The report, without the counts line: the start of `text`, which the pool's allocator
    /// owns.
    report: []const u8 = "",
    text: []u8 = &.{},
    counts: Summary = .{},
    /// How long the worker took, from its start to its end.
    ns: u64 = 0,
    done: std.Io.Event = .unset,
};

/// The worker processes: `jobs` threads, each starting one `fels test --worker <file>` after
/// the other until no file is left.
const Pool = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    files: []Job,
    next: usize = 0,
    /// The command line of a worker without its file.
    argv: []const []const u8,
    environ: ?*const std.process.Environ.Map,

    fn work(pool: *Pool) void {
        while (true) {
            const i = @atomicRmw(usize, &pool.next, .Add, 1, .monotonic);
            if (i >= pool.files.len) return;
            const job = &pool.files[i];
            pool.testOne(job);
            job.done.set(pool.io);
        }
    }

    fn testOne(pool: *Pool, job: *Job) void {
        const node = ui.root.start(job.display, 0);
        defer node.end();
        const argv = std.mem.concat(pool.gpa, []const u8, &.{ pool.argv, &.{job.path} }) catch return pool.broken(job, "out of memory");
        defer pool.gpa.free(argv);
        // The report goes to a file, not a pipe: on Windows a child started while another is
        // being started inherits the other's pipe, which then ends only when both have ended,
        // so the workers finished in waves.
        const file = std.Io.Dir.cwd().createFile(pool.io, job.report_path, .{}) catch |err| return pool.broken(job, @errorName(err));
        // The worker draws its tree (stages, functions) in place of its file's node here, over
        // a pipe the progress tree gives it. The tree takes it only from the io it draws with.
        const tree_io = std.Options.debug_io;
        const started = clock.monoNs();
        var child = std.process.spawn(tree_io, .{
            .argv = argv,
            .environ_map = pool.environ,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .{ .file = file },
            .progress_node = node,
        }) catch |err| {
            file.close(pool.io);
            return pool.broken(job, @errorName(err));
        };
        const term = child.wait(tree_io) catch |err| {
            file.close(pool.io);
            return pool.broken(job, @errorName(err));
        };
        job.ns = clock.sinceNs(started);
        file.close(pool.io);
        job.text = std.Io.Dir.cwd().readFileAlloc(pool.io, job.report_path, pool.gpa, .unlimited) catch |err| return pool.broken(job, @errorName(err));

        // The last line has the counts.
        const text = job.text;
        const at: ?usize = if (std.mem.lastIndexOf(u8, text, "\n" ++ summary_marker)) |i| i + 1 else if (std.mem.startsWith(u8, text, summary_marker)) 0 else null;
        if (at) |i| {
            var nums = std.mem.tokenizeAny(u8, text[i + summary_marker.len ..], " \r\n");
            const fields = [_]*u32{ &job.counts.passed, &job.counts.failed, &job.counts.skipped, &job.counts.broken };
            for (fields) |f| f.* = std.fmt.parseInt(u32, nums.next() orelse "0", 10) catch 0;
            job.report = text[0..i];
        } else {
            // It stopped before its counts: a crash of fels itself.
            const why = switch (term) {
                .exited => |code| std.fmt.allocPrint(pool.gpa, "fels stopped with exit code {d}", .{code}) catch "fels stopped",
                else => "fels crashed",
            };
            const more = std.fmt.allocPrint(pool.gpa, "{s}{s}{s}{s}\n  {s} {s} while it tested this file\n", .{
                text, ui.pal.bold(), job.display, ui.pal.reset(), ui.mark(.fail), why,
            }) catch return;
            pool.gpa.free(job.text);
            job.text = more;
            job.report = more;
            job.counts.broken = 1;
        }
    }

    fn broken(pool: *Pool, job: *Job, why: []const u8) void {
        job.counts.broken = 1;
        job.text = std.fmt.allocPrint(pool.gpa, "{s}{s}{s}\n  {s} fels could not be started to test it ({s})\n", .{
            ui.pal.bold(), job.display, ui.pal.reset(), ui.mark(.fail), why,
        }) catch return;
        job.report = job.text;
    }
};

/// Test `paths` in worker processes, `opts.jobs` at once, and write their reports in the order
/// of the files as they come in.
fn runWorkers(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    a: std.mem.Allocator,
    paths: []const []const u8,
    opts: Options,
    summary: *Summary,
    slowest: *Slowest,
) Error!void {
    // The reports go next to the test programs, in `.fels-cache/test`.
    const dir = try joinPath(a, opts.project_dir, ".fels-cache/test");
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const files = try a.alloc(Job, paths.len);
    for (files, paths) |*job, path| {
        const display = try displayPath(a, path);
        const flat = try a.dupe(u8, display);
        for (flat) |*c| if (c.* == '/' or c.* == ':') {
            c.* = '_';
        };
        job.* = .{ .path = path, .display = display, .report_path = try std.fmt.allocPrint(a, "{s}/{s}.report", .{ dir, flat }) };
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ opts.self_exe, "test", "--worker" });
    try argv.appendSlice(a, opts.worker_args);
    // The workers write to a file: they keep the colors of this terminal.
    var env: ?std.process.Environ.Map = null;
    if (ui.pal.on) if (opts.environ) |e| {
        env = try e.clone(a);
        try env.?.put("FELS_COLOR", "1");
    };
    var pool: Pool = .{
        .gpa = gpa,
        .io = io,
        .files = files,
        .argv = argv.items,
        .environ = if (env) |*e| e else opts.environ,
    };

    var group: std.Io.Group = .init;
    var started: usize = 0;
    for (0..@min(opts.jobs, files.len)) |_| {
        group.concurrent(io, Pool.work, .{&pool}) catch break;
        started += 1;
    }
    if (started == 0) pool.work(); // no threads to be had: one by one here
    defer {
        // When every worker has ended (one may hold another's report open), the reports go.
        group.await(io) catch {};
        for (files) |job| std.Io.Dir.cwd().deleteFile(io, job.report_path) catch {};
    }

    for (files) |*job| {
        job.done.waitUncancelable(io);
        defer gpa.free(job.text);
        try out.writeAll(job.report);
        try out.flush();
        summary.passed += job.counts.passed;
        summary.failed += job.counts.failed;
        summary.skipped += job.counts.skipped;
        summary.broken += job.counts.broken;
        if (job.counts.passed + job.counts.failed != 0) slowest.add(job.display, job.ns);
    }
}

/// A file's name above its tests, in bold.
fn printFileName(out: *std.Io.Writer, display: []const u8) Error!void {
    try out.print("{s}{s}{s}\n", .{ ui.pal.bold(), display, ui.pal.reset() });
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
    stages: *ui.Stages,
    summary: *Summary,
) Error!void {
    // Checking, the five stages of building the test program, running it; on the comptime VM
    // checking and running.
    stages.node.setEstimatedTotalItems(if (native != null) 7 else 2);
    stages.stage("checking");
    const saved_runner = pipeline.test_runner;
    pipeline.test_runner = native != null;
    defer pipeline.test_runner = saved_runner;
    var fe = pipeline.compileFileWithRuntime(gpa, io, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            // The reason is already printed: a parse error, an import that cannot be read.
            try printFileName(out, display);
            try out.print("  {s} does not compile\n", .{ui.mark(.fail)});
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
        try printFileName(out, display);
        try out.print("  {s} does not compile\n", .{ui.mark(.fail)});
        summary.broken += 1;
        return;
    }

    const selected: ir.TestOptions = .{ .only_file = path };
    if (ir.countTestDecls(fe.module, selected) == 0) return;
    if (native) |n| return n.testFile(gpa, io, out, fe, path, display, stages, summary);
    stages.stage("running");
    const report = ir.runComptimeTestsWith(gpa, fe, selected) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SemanticFailed => {
            try printFileName(out, display);
            try out.print("  {s} the comptime VM cannot load this file, so its tests do not run\n", .{ui.mark(.fail)});
            summary.broken += 1;
            return;
        },
    };
    try printFileName(out, display);
    for (report.results) |r| {
        if (r.failure) |why|
            try out.print("  {s} {s}: {s}\n", .{ ui.mark(.fail), r.name, why })
        else if (r.skipped) |why|
            try out.print("  {s} {s}: skipped ({s})\n", .{ ui.mark(.skip), r.name, why })
        else
            try out.print("  {s} {s}\n", .{ ui.mark(.ok), r.name });
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
        stages: *ui.Stages,
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
        // Made here, so a project without tests gets no .fels-cache folder.
        std.Io.Dir.cwd().createDirPath(io, self.out_dir) catch {};
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
            .progress = ui.Stages.step,
            .progress_ctx = stages,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                // The linker or the backend printed the reason.
                try printFileName(out, display);
                try out.print("  {s} the test program does not build\n", .{ui.mark(.fail)});
                summary.broken += 1;
                return;
            },
        };
        self.copyRuntimeFiles(gpa, io);

        stages.stage("running");
        try printFileName(out, display);
        // After a crash, or a `t.fatal`, the program starts again behind that test.
        var from: u32 = 0;
        while (true) {
            var num: [16]u8 = undefined;
            const argv: []const []const u8 = if (from == 0)
                &.{exe}
            else
                &.{ exe, std.fmt.bufPrint(&num, "{d}", .{from}) catch unreachable };
            const r = std.process.run(a, io, .{ .argv = argv, .cwd = .{ .path = self.cwd } }) catch {
                try out.print("  {s} the test program could not be started\n", .{ui.mark(.fail)});
                summary.broken += 1;
                return;
            };
            const ran = try readRun(a, out, r, summary);
            if (ran.done) return;
            if (ran.started == 0) {
                // It stopped before the first test it was to run.
                try out.print("  {s} the test program stopped before its tests ran{s}\n", .{ ui.mark(.fail), try exitText(a, r) });
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
                try out.print("  {s} {s}\n", .{ ui.mark(.ok), name });
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
        try out.print("  {s} {s}\n", .{ ui.mark(.fail), name })
    else
        try out.print("  {s} {s}: {s}{s}{s}\n", .{ ui.mark(.fail), name, ui.pal.red(), msgs[0], ui.pal.reset() });
    if (msgs.len > 1) for (msgs[1..]) |m| try out.print("      {s}\n", .{m});
    const text = std.mem.trim(u8, printed, " \r\n");
    if (text.len == 0) return;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| try out.print("      {s}|{s} {s}\n", .{ ui.pal.dim(), ui.pal.reset(), std.mem.trimEnd(u8, l, "\r") });
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
    // Through the lock of std.debug.print: the parser prints with it too, and the live tree
    // clears before each write.
    var w: ui.Stderr = .init(&buf);
    var with_colors = opts;
    with_colors.palette = style.forStderr();
    const summary = run(gpa, io, &w.interface, with_colors) catch |err| {
        ui.finish();
        w.interface.flush() catch {};
        switch (err) {
            error.PackageError, error.BadPath => {},
            else => std.debug.print("fels test: {s}\n", .{@errorName(err)}),
        }
        return 1;
    };
    return if (summary.ok()) 0 else 1;
}
