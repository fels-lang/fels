//! The `k2 build` build system driver.
//!
//! Runs a project's `build.k2` `build :: fn(b: Build)` entry inside the comptime
//! VM (via `ir.runBuildHook`), recording each `std.build` call into a `BuildPlan`
//! through the VM's host-call bridge, then compiles + links the declared
//! artifacts with the normal LLVM/k2lnk driver.
//!
//! See docs/10_build_system.md for the design and `std/build.k2` for the API.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const pipeline = @import("pipeline.zig");
const ir = @import("ir.zig");
const driver = @import("driver.zig");
const diagnostic = @import("diagnostic.zig");
const vm_engine = @import("vm/engine.zig");
const vm_value = @import("vm/value.zig");
const instructions = @import("vm/instructions.zig");

const Value = vm_value.Value;
const BuildOp = instructions.BuildOp;

pub const BuildError = error{
    CompileFailed,
    NoBuildScript,
    NoBuildFn,
    NoArtifacts,
    UnknownTarget,
    RunFailed,
    OutOfMemory,
};

pub const ArtifactKind = enum(u8) { executable, shared_library, static_library, object };

pub const Artifact = struct {
    name: []const u8,
    root: []const u8,
    kind: ArtifactKind,
    opt: u2 = 0,
    out_path: ?[]const u8 = null,
    libs: std.ArrayList([]const u8) = .empty,
    lib_paths: std.ArrayList([]const u8) = .empty,
};

pub const StepKind = enum(u8) { run, test_dir };

pub const Step = struct {
    name: []const u8,
    kind: StepKind,
    target: usize = 0,
    dir: []const u8 = "",
};

pub const Dep = struct {
    name: []const u8,
    location: []const u8,
    kind: u8, // 0 path, 1 git
};

/// The configuration a `build.k2` produces. All strings are duped into `arena`,
/// so the plan outlives the FrontEnd the build script ran against.
pub const BuildPlan = struct {
    arena: std.heap.ArenaAllocator,
    artifacts: std.ArrayList(Artifact) = .empty,
    steps: std.ArrayList(Step) = .empty,
    deps: std.ArrayList(Dep) = .empty,
    default_idx: ?usize = null,
    oom: bool = false,

    fn init(gpa: std.mem.Allocator) BuildPlan {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    fn deinit(self: *BuildPlan) void {
        self.arena.deinit();
    }

    fn a(self: *BuildPlan) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn dupe(self: *BuildPlan, s: []const u8) []const u8 {
        return self.a().dupe(u8, s) catch {
            self.oom = true;
            return "";
        };
    }
};

// ── VM host-call bridge ────────────────────────────────────────────────────────

fn argStr(args: []const Value, i: usize) []const u8 {
    if (i >= args.len) return "";
    return switch (args[i]) {
        .string => |s| s,
        else => "",
    };
}

fn argInt(args: []const Value, i: usize) i64 {
    if (i >= args.len) return 0;
    return @intCast(args[i].asI128() orelse 0);
}

/// Invoked by the `host_call` opcode for every `std.build` `__build_*` intrinsic.
fn hostCall(ctx: *anyopaque, op_raw: u32, args: []const Value) Value {
    const plan: *BuildPlan = @ptrCast(@alignCast(ctx));
    const op: BuildOp = @enumFromInt(op_raw);
    switch (op) {
        .artifact => {
            const kind: ArtifactKind = @enumFromInt(@as(u8, @intCast(argInt(args, 2))));
            const id = plan.artifacts.items.len;
            plan.artifacts.append(plan.a(), .{
                .name = plan.dupe(argStr(args, 0)),
                .root = plan.dupe(argStr(args, 1)),
                .kind = kind,
            }) catch {
                plan.oom = true;
                return .{ .int = 0 };
            };
            return .{ .int = @intCast(id) };
        },
        .opt => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) {
                plan.artifacts.items[id].opt = @intCast(@as(u8, @intCast(argInt(args, 1))) & 3);
            }
            return .void;
        },
        .link => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) {
                plan.artifacts.items[id].libs.append(plan.a(), plan.dupe(argStr(args, 1))) catch {
                    plan.oom = true;
                };
            }
            return .void;
        },
        .lib_path => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) {
                plan.artifacts.items[id].lib_paths.append(plan.a(), plan.dupe(argStr(args, 1))) catch {
                    plan.oom = true;
                };
            }
            return .void;
        },
        .output => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) {
                plan.artifacts.items[id].out_path = plan.dupe(argStr(args, 1));
            }
            return .void;
        },
        .define => {
            // Recorded for parity; comptime-define injection into the target build
            // lands with `#provided`. No-op for now.
            return .void;
        },
        .set_default => {
            plan.default_idx = @intCast(argInt(args, 0));
            return .void;
        },
        .run_step => {
            plan.steps.append(plan.a(), .{
                .name = plan.dupe(argStr(args, 0)),
                .kind = .run,
                .target = @intCast(argInt(args, 1)),
            }) catch {
                plan.oom = true;
            };
            return .void;
        },
        .test_dir => {
            plan.steps.append(plan.a(), .{
                .name = plan.dupe(argStr(args, 0)),
                .kind = .test_dir,
                .dir = plan.dupe(argStr(args, 1)),
            }) catch {
                plan.oom = true;
            };
            return .void;
        },
        .require => {
            const id = plan.deps.items.len;
            plan.deps.append(plan.a(), .{
                .name = plan.dupe(argStr(args, 0)),
                .location = plan.dupe(argStr(args, 1)),
                .kind = @intCast(@as(u8, @intCast(argInt(args, 2)))),
            }) catch {
                plan.oom = true;
                return .{ .int = 0 };
            };
            return .{ .int = @intCast(id) };
        },
        .depend => {
            // Dependency edges are recorded; the build-graph executor lands next.
            return .void;
        },
    }
}

// ── Options + entry ──────────────────────────────────────────────────────────

pub const RunOptions = struct {
    /// A requested target/step name (`k2 build <name>`), or null for the default.
    target: ?[]const u8 = null,
    /// Override every artifact to a release optimization level.
    release: bool = false,
    /// Just print the artifacts and steps, build nothing.
    list: bool = false,
    quiet: bool = false,
    /// LLVM bin dir + default library search paths, forwarded from the CLI.
    llvm_bin: []const u8 = "",
    lib_paths: []const []const u8 = &.{},
    /// Extra args passed through to a `run` step's executable.
    run_args: []const []const u8 = &.{},
};

/// Run `build_path` (a build.k2) and execute the resulting plan.
pub fn run(gpa: std.mem.Allocator, io: std.Io, build_path: []const u8, opts: RunOptions) BuildError!void {
    var plan = BuildPlan.init(gpa);
    defer plan.deinit();

    // 1. Front-end the build script (resolves std.build + the runtime prelude).
    var fe = pipeline.compileFileWithRuntime(gpa, io, build_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CompileFailed,
    };
    defer fe.deinit(gpa);
    if (fe.diagnostics().len != 0) {
        const src = readSource(gpa, io, build_path);
        defer if (src) |s| gpa.free(s);
        for (fe.diagnostics()) |d| {
            const r = diagnostic.renderDiagnostic(gpa, build_path, src orelse "", d) catch continue;
            defer gpa.free(r);
            std.debug.print("{s}\n", .{r});
        }
        return error.CompileFailed;
    }

    // 2. Run `build(b)` on the comptime VM, recording into `plan`.
    const host = vm_engine.BuildHost{ .ctx = &plan, .call = hostCall };
    ir.runBuildHook(gpa, fe, host) catch return error.NoBuildFn;
    if (plan.oom) return error.OutOfMemory;
    if (plan.artifacts.items.len == 0) return error.NoArtifacts;

    if (opts.list) {
        printList(&plan);
        return;
    }

    // 3. Execute the plan.
    const base_dir = std.fs.path.dirname(build_path) orelse ".";
    try executePlan(gpa, io, &plan, base_dir, opts);
}

fn executePlan(gpa: std.mem.Allocator, io: std.Io, plan: *BuildPlan, base_dir: []const u8, opts: RunOptions) BuildError!void {
    // Resolve which artifact a run-step / target name refers to.
    var run_after: ?usize = null;
    var target_idx: ?usize = null;

    if (opts.target) |name| {
        // A step name?
        for (plan.steps.items) |st| {
            if (!std.mem.eql(u8, st.name, name)) continue;
            switch (st.kind) {
                .run => {
                    target_idx = st.target;
                    run_after = st.target;
                },
                .test_dir => {
                    std.debug.print("k2 build: test steps are not wired yet ('{s}')\n", .{name});
                    return;
                },
            }
        }
        // An artifact name?
        if (target_idx == null) {
            for (plan.artifacts.items, 0..) |art, i| {
                if (std.mem.eql(u8, art.name, name)) target_idx = i;
            }
        }
        if (target_idx == null) {
            std.debug.print("k2 build: no artifact or step named '{s}'\n", .{name});
            return error.UnknownTarget;
        }
    }

    // Which artifacts to build: the requested/default one, else all.
    if (target_idx) |idx| {
        try buildArtifact(gpa, io, plan, base_dir, idx, opts);
    } else if (plan.default_idx) |idx| {
        try buildArtifact(gpa, io, plan, base_dir, idx, opts);
    } else {
        for (0..plan.artifacts.items.len) |i| try buildArtifact(gpa, io, plan, base_dir, i, opts);
    }

    if (run_after) |idx| try runArtifact(gpa, io, plan, base_dir, idx, opts);
}

fn buildArtifact(gpa: std.mem.Allocator, io: std.Io, plan: *BuildPlan, base_dir: []const u8, idx: usize, opts: RunOptions) BuildError!void {
    const art = plan.artifacts.items[idx];
    const a = plan.a();

    const root_path = joinPath(a, base_dir, art.root) catch return error.OutOfMemory;
    const out_path = try resolveOutput(plan, base_dir, art);
    const obj_path = std.fmt.allocPrint(a, "{s}.o", .{out_path}) catch return error.OutOfMemory;

    // Make sure the output directory exists (e.g. `bin/`, `out/`).
    if (std.fs.path.dirname(out_path)) |dir| {
        if (dir.len != 0) std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }

    // Library search paths: the CLI defaults + the artifact's own.
    var lib_paths: std.ArrayList([]const u8) = .empty;
    lib_paths.appendSlice(a, opts.lib_paths) catch return error.OutOfMemory;
    for (art.lib_paths.items) |lp| {
        const abs = joinPath(a, base_dir, lp) catch return error.OutOfMemory;
        lib_paths.append(a, abs) catch return error.OutOfMemory;
    }

    const opt_level: u2 = if (opts.release and art.opt == 0) 2 else art.opt;
    const is_lib = art.kind == .shared_library or art.kind == .static_library;
    const stop_at_obj = art.kind == .object;

    const src = readSource(gpa, io, root_path);
    defer if (src) |s| gpa.free(s);

    if (!opts.quiet) std.debug.print("  building {s} ({s})\n", .{ art.name, root_path });

    driver.compileFileWithLlvm(gpa, io, .{
        .file_name = root_path,
        .source = src orelse "",
        .obj_path = obj_path,
        .exe_path = if (stop_at_obj) null else out_path,
        .dll = is_lib,
        .opt_level = opt_level,
        .llvm_bin = opts.llvm_bin,
        .lib_paths = lib_paths.items,
        .extra_libs = art.libs.items,
    }) catch |err| {
        std.debug.print("k2 build: failed to build '{s}': {s}\n", .{ art.name, @errorName(err) });
        return error.CompileFailed;
    };

    if (!opts.quiet) std.debug.print("  \u{2713} {s}\n", .{out_path});
}

fn runArtifact(gpa: std.mem.Allocator, io: std.Io, plan: *BuildPlan, base_dir: []const u8, idx: usize, opts: RunOptions) BuildError!void {
    const art = plan.artifacts.items[idx];
    const out_path = try resolveOutput(plan, base_dir, art);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    argv.append(gpa, out_path) catch return error.OutOfMemory;
    argv.appendSlice(gpa, opts.run_args) catch return error.OutOfMemory;

    if (!opts.quiet) std.debug.print("  running {s}\n", .{out_path});
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return error.RunFailed;
    const term = child.wait(io) catch return error.RunFailed;
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("  {s} exited with code {d}\n", .{ art.name, code });
        },
        else => return error.RunFailed,
    }
}

// ── Helpers ────────────────────────────────────────────────────────────────────

fn resolveOutput(plan: *BuildPlan, base_dir: []const u8, art: Artifact) BuildError![]const u8 {
    const a = plan.a();
    if (art.out_path) |p| return joinPath(a, base_dir, p) catch return error.OutOfMemory;
    const ext = switch (art.kind) {
        .executable => ".exe",
        .shared_library => ".dll",
        .static_library => ".lib",
        .object => ".o",
    };
    const name = std.fmt.allocPrint(a, "{s}{s}", .{ art.name, ext }) catch return error.OutOfMemory;
    return joinPath(a, base_dir, name) catch return error.OutOfMemory;
}

fn joinPath(a: std.mem.Allocator, base: []const u8, rel: []const u8) ![]const u8 {
    if (base.len == 0 or std.mem.eql(u8, base, ".")) return a.dupe(u8, rel);
    return std.fs.path.join(a, &.{ base, rel });
}

fn readSource(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch null;
}

fn printList(plan: *BuildPlan) void {
    std.debug.print("artifacts:\n", .{});
    for (plan.artifacts.items, 0..) |art, i| {
        const star: []const u8 = if (plan.default_idx == i) " (default)" else "";
        std.debug.print("  {s: <16} {s}{s}\n", .{ art.name, @tagName(art.kind), star });
    }
    if (plan.steps.items.len != 0) {
        std.debug.print("steps:\n", .{});
        for (plan.steps.items) |st| std.debug.print("  {s: <16} {s}\n", .{ st.name, @tagName(st.kind) });
    }
}
