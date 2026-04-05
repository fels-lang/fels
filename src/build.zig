//! The `fels build` build system driver.
//!
//! Runs a project's `build.fels` `build :: fn(b: Build)` entry inside the comptime
//! VM (via `ir.runBuildHook`), recording each `std.build` call into a `BuildPlan`
//! through the VM's host-call bridge, then compiles + links the declared
//! artifacts with the normal LLVM/felsld driver.
//!
//! See docs/10_build_system.md for the design and `std/build.fels` for the API.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const pipeline = @import("pipeline.zig");
const ir = @import("ir.zig");
const driver = @import("driver.zig");
const diagnostic = @import("diagnostic.zig");
const ui = @import("ui.zig");
const clock = @import("clock.zig");
const coff_archive = @import("coff_archive.zig");
const pkg = @import("pkg.zig");
const vm_engine = @import("vm/engine.zig");
const vm_value = @import("vm/value.zig");
const instructions = @import("vm/instructions.zig");

const Value = vm_value.Value;
const BuildOp = instructions.BuildOp;

pub const BuildError = error{
    CompileFailed,
    ScriptError,
    InstallFailed,
    PackageError,
    DependencyCycle,
    NoBuildScript,
    NoBuildFn,
    BuildHookFailed,
    NoArtifacts,
    UnknownTarget,
    RunFailed,
    StepFailed,
    OutOfMemory,
};

pub const ArtifactKind = enum(u8) { executable, shared_library, static_library, object };

pub const Artifact = struct {
    name: []const u8,
    root: []const u8,
    kind: ArtifactKind,
    opt: u2 = 0,
    out_path: ?[]const u8 = null,
    out_dir: ?[]const u8 = null,
    libs: std.ArrayList([]const u8) = .empty,
    lib_paths: std.ArrayList([]const u8) = .empty,
    link_flags: std.ArrayList([]const u8) = .empty,
    subsystem: u8 = 0, // 0 console, 1 windows (GUI)
    entry: ?[]const u8 = null,
    stack: u64 = 0,
    version: ?[]const u8 = null,
    description: ?[]const u8 = null,
    install: bool = false,
    /// 0 = dynamic (default), 1 = static. Static auto-links the C runtime.
    link_mode: u8 = 0,
    /// Files (e.g. a `.dll`) copied next to the output after building.
    runtime_files: std.ArrayList([]const u8) = .empty,
    /// Opt out of honoring a static C library's own `/DEFAULTLIB` directives
    /// (keep the strict `/NODEFAULTLIB` and list system deps yourself).
    no_default_libs: bool = false,
    /// Link the host's libc (`link_libc()`): the Windows CRT (ucrt+vcruntime) on
    /// Windows, glibc on Linux. Resolved per host below.
    link_libc: bool = false,
    /// Library artifacts of this build to link (`link_artifact`), built before this one.
    link_artifacts: std.ArrayList(usize) = .empty,
    /// Steps run before this artifact is built (`after`), e.g. code generation.
    after_steps: std.ArrayList(usize) = .empty,
    /// The OS the artifact is for (`target`); the host by default.
    target_os: std.Target.Os.Tag = builtin.os.tag,
    /// A Linux target with glibc (`.linux_gnu`) instead of a static, libc-free ELF.
    target_gnu: bool = false,
    sysroot: []const u8 = "",
    strip: bool = false,
    /// The files the build copied next to the output (runtime files, DLLs), which
    /// `fels build install` copies along.
    copied: std.ArrayList([]const u8) = .empty,
    /// The constants of the generated `build_options` module (`define`, `define_int`, ...),
    /// each as its Fels source text.
    defines: std.ArrayList(Define) = .empty,
    /// Named import roots (`add_module`), relative to build.fels.
    modules: std.ArrayList(pipeline.ModuleRoot) = .empty,
};

/// Library folders, libraries and runtime files a package's build.fels gives its users.
pub const Provided = struct {
    lib_paths: std.ArrayList([]const u8) = .empty,
    links: std.ArrayList([]const u8) = .empty,
    runtime_files: std.ArrayList([]const u8) = .empty,
};

pub const Define = struct {
    name: []const u8,
    /// The value as Fels source: `"text"`, `42` or `true`.
    value: []const u8,
};

/// A file or folder `fels build install` copies (`b.install_file` / `b.install_dir`).
pub const InstallItem = struct {
    src: []const u8,
    /// Relative to the install prefix.
    dest: []const u8,
    is_dir: bool,
};

const BuildState = enum { unbuilt, building, built };

pub const StepKind = enum(u8) { run, test_dir, custom };

pub const Step = struct {
    name: []const u8,
    kind: StepKind,
    /// `.run`: the artifact it runs.
    target: usize = 0,
    /// `.test_dir`: the folder of the tests, and how they are found, built and linked.
    dir: []const u8 = "",
    test_recursive: bool = false,
    test_filters: std.ArrayList([]const u8) = .empty,
    test_opt: u2 = 0,
    test_libs: std.ArrayList([]const u8) = .empty,
    test_link_artifacts: std.ArrayList(usize) = .empty,
    description: []const u8 = "",
    /// Artifacts built and steps run before the actions.
    artifacts: std.ArrayList(usize) = .empty,
    after: std.ArrayList(usize) = .empty,
    actions: std.ArrayList(Action) = .empty,
};

/// Two paths, or a path and a text.
pub const Pair = struct { a: []const u8, b: []const u8 };

/// What a step does, in order. Paths are relative to build.fels.
pub const Action = union(enum) {
    /// An index into `BuildPlan.commands`.
    command: usize,
    copy_file: Pair,
    copy_dir: Pair,
    /// Path and contents.
    write_file: Pair,
    remove: []const u8,
    print: []const u8,
};

pub const Arg = union(enum) {
    text: []const u8,
    /// The output path of an artifact.
    output: usize,
};

pub const Command = struct {
    /// A program name (found on PATH) or path, or the output of `program_artifact`.
    program: []const u8 = "",
    program_artifact: ?usize = null,
    args: std.ArrayList(Arg) = .empty,
    /// Relative to build.fels; build.fels's folder when null.
    cwd: ?[]const u8 = null,
    env: std.ArrayList(Pair) = .empty,
    /// A run step's command: it also gets the arguments after `--`, and an exit code other
    /// than 0 is reported instead of failing the build.
    is_run: bool = false,
};

pub const OptionKind = enum { bool, int, string, choice };

/// A build option the script declared with `b.option_*`, shown by `--list`.
pub const OptionDecl = struct {
    name: []const u8,
    kind: OptionKind,
    /// The default as text, for the listing.
    default: []const u8,
    help: []const u8,
    /// For `.choice`: the allowed words, separated by `|`.
    choices: []const u8 = "",
};

pub const Dep = struct {
    name: []const u8,
    location: []const u8,
    kind: u8, // 0 path, 1 git
};

/// The configuration a `build.fels` produces. All strings are duped into `arena`,
/// so the plan outlives the FrontEnd the build script ran against.
pub const BuildPlan = struct {
    arena: std.heap.ArenaAllocator,
    artifacts: std.ArrayList(Artifact) = .empty,
    steps: std.ArrayList(Step) = .empty,
    deps: std.ArrayList(Dep) = .empty,
    default_idx: ?usize = null,
    /// Workspace-level metadata + default output directory for all artifacts.
    workspace_name: ?[]const u8 = null,
    out_root: ?[]const u8 = null,
    want_summary: bool = false,
    /// `-Dname` / `-Dname=value` build options forwarded from the CLI.
    options: []const []const u8 = &.{},
    /// The options the script declared, in declaration order.
    declared: std.ArrayList(OptionDecl) = .empty,
    /// Problems found while the script ran (a bad option value), reported after it.
    errors: std.ArrayList([]const u8) = .empty,
    /// Per artifact, during execution: so each is built once and after what it links.
    state: []BuildState = &.{},
    /// Per step, during execution.
    step_state: []BuildState = &.{},
    commands: std.ArrayList(Command) = .empty,
    /// What a bare `fels build` runs (`b.default_step`), over `default_idx`.
    default_step: ?usize = null,
    /// The process's working directory, for absolute paths in commands.
    cwd_abs: []const u8 = "",
    /// The packages fels.pkg uses (with the ones they use).
    packages: []const pkg.resolve.Package = &.{},
    /// The project's own package name and import folder, when fels.pkg has `#package`.
    self_root: ?pipeline.ModuleRoot = null,
    /// What this build.fels provides to the users of its package (`b.provide_*`), relative to
    /// build.fels.
    provided: Provided = .{},
    /// What the packages' own build.fels provide, as absolute paths: added to every artifact.
    from_packages: Provided = .{},
    /// Where `fels build install` copies to (`b.install_prefix`), relative to build.fels.
    install_prefix: ?[]const u8 = null,
    install_items: std.ArrayList(InstallItem) = .empty,
    oom: bool = false,
    /// What the build did, for its last line: the artifacts built, up to date, failed, and
    /// whether a program or the tests ran (they print their own output, so it is left out).
    built: u32 = 0,
    fresh: u32 = 0,
    failed: u32 = 0,
    ran: bool = false,

    fn init(gpa: std.mem.Allocator) BuildPlan {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *BuildPlan) void {
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

    fn fail(self: *BuildPlan, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.a(), fmt, args) catch {
            self.oom = true;
            return;
        };
        self.errors.append(self.a(), msg) catch {
            self.oom = true;
        };
    }

    /// Add a step; a second step of the same name is an error (and is not added).
    fn addStep(self: *BuildPlan, name: []const u8, kind: StepKind, description: []const u8) ?*Step {
        for (self.steps.items) |st| if (std.mem.eql(u8, st.name, name)) {
            self.fail("there are two steps named `{s}`", .{name});
            return null;
        };
        self.steps.append(self.a(), .{ .name = self.dupe(name), .kind = kind, .description = self.dupe(description) }) catch {
            self.oom = true;
            return null;
        };
        return &self.steps.items[self.steps.items.len - 1];
    }

    /// Record an option declaration; the first declaration of a name wins.
    fn declare(self: *BuildPlan, decl: OptionDecl) void {
        for (self.declared.items) |d| if (std.mem.eql(u8, d.name, decl.name)) return;
        var copy = decl;
        copy.name = self.dupe(decl.name);
        copy.default = self.dupe(decl.default);
        copy.help = self.dupe(decl.help);
        copy.choices = self.dupe(decl.choices);
        self.declared.append(self.a(), copy) catch {
            self.oom = true;
        };
    }
};

// VM host-call bridge

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

fn argBool(args: []const Value, i: usize) bool {
    return argInt(args, i) != 0;
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
        .define, .define_int, .define_bool => {
            const id: usize = @intCast(argInt(args, 0));
            if (id >= plan.artifacts.items.len) return .void;
            const name = argStr(args, 1);
            if (!isIdentifier(name)) {
                plan.fail("define: `{s}` is not a name a program can use", .{name});
                return .void;
            }
            const value = switch (op) {
                .define_int => std.fmt.allocPrint(plan.a(), "{d}", .{argInt(args, 2)}),
                .define_bool => plan.a().dupe(u8, if (argBool(args, 2)) "true" else "false"),
                else => stringLiteral(plan.a(), argStr(args, 2)),
            } catch {
                plan.oom = true;
                return .void;
            };
            const defs = &plan.artifacts.items[id].defines;
            for (defs.items) |*d| if (std.mem.eql(u8, d.name, name)) {
                d.value = value; // a later define of the same name wins
                return .void;
            };
            defs.append(plan.a(), .{ .name = plan.dupe(name), .value = value }) catch {
                plan.oom = true;
            };
            return .void;
        },
        .add_module => {
            const id: usize = @intCast(argInt(args, 0));
            if (id >= plan.artifacts.items.len) return .void;
            const name = argStr(args, 1);
            if (!isIdentifier(name) or std.mem.eql(u8, name, "std") or std.mem.eql(u8, name, "build_options")) {
                plan.fail("add_module: `{s}` cannot be a module name", .{name});
                return .void;
            }
            plan.artifacts.items[id].modules.append(plan.a(), .{ .name = plan.dupe(name), .dir = plan.dupe(argStr(args, 2)) }) catch {
                plan.oom = true;
            };
            return .void;
        },
        .set_default => {
            plan.default_idx = @intCast(argInt(args, 0));
            return .void;
        },
        .run_step => {
            const target: usize = @intCast(argInt(args, 1));
            if (target >= plan.artifacts.items.len) return .{ .int = 0 };
            const cmd = plan.commands.items.len;
            plan.commands.append(plan.a(), .{ .program_artifact = target, .is_run = true }) catch {
                plan.oom = true;
                return .{ .int = 0 };
            };
            const step = plan.addStep(argStr(args, 0), .run, "") orelse return .{ .int = @intCast(cmd) };
            step.target = target;
            step.artifacts.append(plan.a(), target) catch {
                plan.oom = true;
            };
            step.actions.append(plan.a(), .{ .command = cmd }) catch {
                plan.oom = true;
            };
            return .{ .int = @intCast(cmd) };
        },
        .step => {
            _ = plan.addStep(argStr(args, 0), .custom, argStr(args, 1));
            return .{ .int = @intCast(plan.steps.items.len - 1) };
        },
        .step_depends_on, .step_after, .artifact_after => {
            const a0: usize = @intCast(argInt(args, 0));
            const a1: usize = @intCast(argInt(args, 1));
            const list, const ok = switch (op) {
                .step_depends_on => .{ if (a0 < plan.steps.items.len) &plan.steps.items[a0].artifacts else null, a1 < plan.artifacts.items.len },
                .step_after => .{ if (a0 < plan.steps.items.len) &plan.steps.items[a0].after else null, a1 < plan.steps.items.len },
                else => .{ if (a0 < plan.artifacts.items.len) &plan.artifacts.items[a0].after_steps else null, a1 < plan.steps.items.len },
            };
            if (list != null and ok) list.?.append(plan.a(), a1) catch {
                plan.oom = true;
            };
            return .void;
        },
        .step_command => {
            const step: usize = @intCast(argInt(args, 0));
            const cmd = plan.commands.items.len;
            plan.commands.append(plan.a(), .{ .program = plan.dupe(argStr(args, 1)) }) catch {
                plan.oom = true;
                return .{ .int = 0 };
            };
            if (step < plan.steps.items.len) plan.steps.items[step].actions.append(plan.a(), .{ .command = cmd }) catch {
                plan.oom = true;
            };
            return .{ .int = @intCast(cmd) };
        },
        .step_run => {
            const step: usize = @intCast(argInt(args, 0));
            const art: usize = @intCast(argInt(args, 1));
            if (step >= plan.steps.items.len or art >= plan.artifacts.items.len) return .{ .int = 0 };
            const cmd = plan.commands.items.len;
            plan.commands.append(plan.a(), .{ .program_artifact = art }) catch {
                plan.oom = true;
                return .{ .int = 0 };
            };
            const st = &plan.steps.items[step];
            st.artifacts.append(plan.a(), art) catch {
                plan.oom = true;
            };
            st.actions.append(plan.a(), .{ .command = cmd }) catch {
                plan.oom = true;
            };
            return .{ .int = @intCast(cmd) };
        },
        .command_arg, .command_arg_output, .command_cwd, .command_env => {
            const id: usize = @intCast(argInt(args, 0));
            if (id >= plan.commands.items.len) return .void;
            const cmd = &plan.commands.items[id];
            switch (op) {
                .command_arg => cmd.args.append(plan.a(), .{ .text = plan.dupe(argStr(args, 1)) }) catch {
                    plan.oom = true;
                },
                .command_arg_output => cmd.args.append(plan.a(), .{ .output = @intCast(argInt(args, 1)) }) catch {
                    plan.oom = true;
                },
                .command_cwd => cmd.cwd = plan.dupe(argStr(args, 1)),
                else => cmd.env.append(plan.a(), .{ .a = plan.dupe(argStr(args, 1)), .b = plan.dupe(argStr(args, 2)) }) catch {
                    plan.oom = true;
                },
            }
            return .void;
        },
        .step_copy_file, .step_copy_dir, .step_write_file, .step_remove, .step_print => {
            const step: usize = @intCast(argInt(args, 0));
            if (step >= plan.steps.items.len) return .void;
            const pair: Pair = .{ .a = plan.dupe(argStr(args, 1)), .b = plan.dupe(argStr(args, 2)) };
            const action: Action = switch (op) {
                .step_copy_file => .{ .copy_file = pair },
                .step_copy_dir => .{ .copy_dir = pair },
                .step_write_file => .{ .write_file = pair },
                .step_remove => .{ .remove = pair.a },
                else => .{ .print = pair.a },
            };
            plan.steps.items[step].actions.append(plan.a(), action) catch {
                plan.oom = true;
            };
            return .void;
        },
        .provide_lib_path, .provide_link, .provide_runtime_file => {
            const list = switch (op) {
                .provide_lib_path => &plan.provided.lib_paths,
                .provide_link => &plan.provided.links,
                else => &plan.provided.runtime_files,
            };
            list.append(plan.a(), plan.dupe(argStr(args, 0))) catch {
                plan.oom = true;
            };
            return .void;
        },
        .target => {
            const id: usize = @intCast(argInt(args, 0));
            if (id >= plan.artifacts.items.len) return .void;
            const art = &plan.artifacts.items[id];
            switch (argInt(args, 1)) {
                0 => art.target_os = .windows,
                1, 2 => {
                    art.target_os = .linux;
                    art.target_gnu = argInt(args, 1) == 2;
                    if (art.kind == .static_library or art.kind == .shared_library)
                        plan.fail("`{s}`: libraries for Linux are not supported yet (executables and objects are)", .{art.name});
                },
                else => {},
            }
            return .void;
        },
        .sysroot => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) plan.artifacts.items[id].sysroot = plan.dupe(argStr(args, 1));
            return .void;
        },
        .strip => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) plan.artifacts.items[id].strip = true;
            return .void;
        },
        .host_os => return .{ .int = switch (builtin.os.tag) {
            .windows => 0,
            .linux => 1,
            .macos => 2,
            else => 3,
        } },
        .default_step => {
            const step: usize = @intCast(argInt(args, 0));
            if (step < plan.steps.items.len) plan.default_step = step;
            return .void;
        },
        .test_dir => {
            if (plan.addStep(argStr(args, 0), .test_dir, "")) |step| step.dir = plan.dupe(argStr(args, 1));
            return .{ .int = @intCast(plan.steps.items.len - 1) };
        },
        .test_recursive, .test_filter, .test_optimize, .test_link, .test_link_artifact => {
            const id: usize = @intCast(argInt(args, 0));
            if (id >= plan.steps.items.len or plan.steps.items[id].kind != .test_dir) return .void;
            const st = &plan.steps.items[id];
            switch (op) {
                .test_recursive => st.test_recursive = true,
                .test_filter => st.test_filters.append(plan.a(), plan.dupe(argStr(args, 1))) catch {
                    plan.oom = true;
                },
                .test_optimize => st.test_opt = @intCast(@as(u8, @intCast(argInt(args, 1))) & 3),
                .test_link => st.test_libs.append(plan.a(), plan.dupe(argStr(args, 1))) catch {
                    plan.oom = true;
                },
                else => {
                    const lib: usize = @intCast(argInt(args, 1));
                    if (lib >= plan.artifacts.items.len) return .void;
                    if (plan.artifacts.items[lib].kind != .static_library and plan.artifacts.items[lib].kind != .shared_library) {
                        plan.fail("test step `{s}`: link_artifact(`{s}`): not a library", .{ st.name, plan.artifacts.items[lib].name });
                        return .void;
                    }
                    st.test_link_artifacts.append(plan.a(), lib) catch {
                        plan.oom = true;
                    };
                    // Built before the tests run.
                    st.artifacts.append(plan.a(), lib) catch {
                        plan.oom = true;
                    };
                },
            }
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
        .subsystem => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len)
                plan.artifacts.items[id].subsystem = @intCast(@as(u8, @intCast(argInt(args, 1))) & 1);
            return .void;
        },
        .entry => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) plan.artifacts.items[id].entry = plan.dupe(argStr(args, 1));
            return .void;
        },
        .stack => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) plan.artifacts.items[id].stack = @intCast(@max(argInt(args, 1), 0));
            return .void;
        },
        .link_flag => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len)
                plan.artifacts.items[id].link_flags.append(plan.a(), plan.dupe(argStr(args, 1))) catch {
                    plan.oom = true;
                };
            return .void;
        },
        .out_dir => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) plan.artifacts.items[id].out_dir = plan.dupe(argStr(args, 1));
            return .void;
        },
        .version => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) plan.artifacts.items[id].version = plan.dupe(argStr(args, 1));
            return .void;
        },
        .description => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) plan.artifacts.items[id].description = plan.dupe(argStr(args, 1));
            return .void;
        },
        .install => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) plan.artifacts.items[id].install = true;
            return .void;
        },
        .workspace => {
            plan.workspace_name = plan.dupe(argStr(args, 0));
            return .void;
        },
        .out_root => {
            plan.out_root = plan.dupe(argStr(args, 0));
            return .void;
        },
        .option_flag => {
            plan.declare(.{ .name = argStr(args, 0), .kind = .bool, .default = "false", .help = "" });
            return .{ .int = if (hasFlag(plan.options, argStr(args, 0))) 1 else 0 };
        },
        .option_str => {
            plan.declare(.{ .name = argStr(args, 0), .kind = .string, .default = argStr(args, 1), .help = "" });
            if (findOption(plan.options, argStr(args, 0))) |v| return .{ .string = plan.dupe(v) };
            return .{ .string = argStr(args, 1) };
        },
        .option_bool => {
            const name = argStr(args, 0);
            const default = argBool(args, 1);
            plan.declare(.{ .name = name, .kind = .bool, .default = if (default) "true" else "false", .help = argStr(args, 2) });
            const text = optionValue(plan.options, name) orelse return .{ .bool = default };
            return .{ .bool = parseBool(text) orelse {
                plan.fail("-D{s}={s}: expected true or false", .{ name, text });
                return .{ .bool = default };
            } };
        },
        .option_int => {
            const name = argStr(args, 0);
            const default = argInt(args, 1);
            const shown = std.fmt.allocPrint(plan.a(), "{d}", .{default}) catch "";
            plan.declare(.{ .name = name, .kind = .int, .default = shown, .help = argStr(args, 2) });
            const text = optionValue(plan.options, name) orelse return .{ .int = default };
            const v = std.fmt.parseInt(i64, text, 0) catch {
                plan.fail("-D{s}={s}: expected an integer", .{ name, text });
                return .{ .int = default };
            };
            return .{ .int = v };
        },
        .option_string => {
            const name = argStr(args, 0);
            plan.declare(.{ .name = name, .kind = .string, .default = argStr(args, 1), .help = argStr(args, 2) });
            if (optionValue(plan.options, name)) |v| return .{ .string = plan.dupe(v) };
            return .{ .string = argStr(args, 1) };
        },
        .option_choice => {
            const name = argStr(args, 0);
            const choices = argStr(args, 1);
            const default = argStr(args, 2);
            plan.declare(.{ .name = name, .kind = .choice, .default = default, .help = argStr(args, 3), .choices = choices });
            if (!isChoice(choices, default))
                plan.fail("option `{s}`: the default `{s}` is not one of {s}", .{ name, default, choices });
            const text = optionValue(plan.options, name) orelse return .{ .string = default };
            if (!isChoice(choices, text)) {
                plan.fail("-D{s}={s}: expected one of {s}", .{ name, text, choices });
                return .{ .string = default };
            }
            return .{ .string = plan.dupe(text) };
        },
        .summary => {
            plan.want_summary = argInt(args, 0) != 0;
            return .void;
        },
        .link_mode => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len)
                plan.artifacts.items[id].link_mode = @intCast(@as(u8, @intCast(argInt(args, 1))) & 1);
            return .void;
        },
        .runtime_file => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len)
                plan.artifacts.items[id].runtime_files.append(plan.a(), plan.dupe(argStr(args, 1))) catch {
                    plan.oom = true;
                };
            return .void;
        },
        .no_default_libs => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) plan.artifacts.items[id].no_default_libs = true;
            return .void;
        },
        .link_libc => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) plan.artifacts.items[id].link_libc = true;
            return .void;
        },
        .install_prefix => {
            plan.install_prefix = plan.dupe(argStr(args, 0));
            return .void;
        },
        .install_file, .install_dir => {
            plan.install_items.append(plan.a(), .{
                .src = plan.dupe(argStr(args, 0)),
                .dest = plan.dupe(argStr(args, 1)),
                .is_dir = op == .install_dir,
            }) catch {
                plan.oom = true;
            };
            return .void;
        },
        .link_artifact => {
            const id: usize = @intCast(argInt(args, 0));
            const lib: usize = @intCast(argInt(args, 1));
            if (id >= plan.artifacts.items.len or lib >= plan.artifacts.items.len) return .void;
            const arts = plan.artifacts.items;
            if (arts[lib].kind != .static_library and arts[lib].kind != .shared_library) {
                plan.fail("`{s}`.link_artifact(`{s}`): `{s}` is not a library (b.static or b.shared)", .{ arts[id].name, arts[lib].name, arts[lib].name });
                return .void;
            }
            arts[id].link_artifacts.append(plan.a(), lib) catch {
                plan.oom = true;
            };
            return .void;
        },
    }
}

/// The value of a `-Dname=value` build option, or null if not set.
fn findOption(options: []const []const u8, name: []const u8) ?[]const u8 {
    for (options) |o| {
        const eq = std.mem.indexOfScalar(u8, o, '=') orelse continue;
        if (std.mem.eql(u8, o[0..eq], name)) return o[eq + 1 ..];
    }
    return null;
}

fn isIdentifier(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// `text` as a Fels string literal.
fn stringLiteral(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '"');
    for (text) |c| switch (c) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        else => try out.append(a, c),
    };
    try out.append(a, '"');
    return out.toOwnedSlice(a);
}

/// The VM capabilities of each package's folder, from what fels.pkg granted it. `fels build`
/// and `fels test` put them in `ir.package_caps`.
pub fn folderCaps(a: std.mem.Allocator, packages: []const pkg.resolve.Package) error{OutOfMemory}![]const ir.FolderCaps {
    var out: std.ArrayList(ir.FolderCaps) = .empty;
    for (packages) |p| {
        var libs: std.ArrayList([]const u8) = .empty;
        var any = false;
        for (p.caps) |c| {
            if (!std.mem.eql(u8, c.name, "ffi")) continue;
            if (c.args.len == 0) any = true;
            try libs.appendSlice(a, c.args);
        }
        const ffi: @import("vm/engine.zig").Caps.Ffi = if (any) .all else if (libs.items.len != 0) .{ .libs = libs.items } else .none;
        try out.append(a, .{ .dir = p.dir, .caps = .{ .ffi = ffi } });
    }
    return out.items;
}

/// Write the artifact's `build_options` module and return the module roots its compile
/// uses: the `add_module` ones, the project's own package, the packages and `build_options`.
fn moduleRootsFor(io: std.Io, plan: *BuildPlan, base_dir: []const u8, art: Artifact) BuildError![]const pipeline.ModuleRoot {
    const a = plan.a();
    var roots: std.ArrayList(pipeline.ModuleRoot) = .empty;
    for (art.modules.items) |m| {
        const dir = if (std.fs.path.isAbsolute(m.dir)) m.dir else joinPath(a, base_dir, m.dir) catch return error.OutOfMemory;
        roots.append(a, .{ .name = m.name, .dir = dir }) catch return error.OutOfMemory;
    }
    // After the `add_module` ones, so a build can point a package name somewhere else.
    if (plan.self_root) |s| roots.append(a, s) catch return error.OutOfMemory;
    for (plan.packages) |p| roots.append(a, .{ .name = p.name, .dir = p.import_dir }) catch return error.OutOfMemory;

    // `#import build_options;` always works; it is empty without a define.
    var src: std.ArrayList(u8) = .empty;
    src.appendSlice(a, "// Generated by fels build from the define calls in build.fels.\n") catch return error.OutOfMemory;
    for (art.defines.items) |d| {
        const line = std.fmt.allocPrint(a, "pub {s} :: {s};\n", .{ d.name, d.value }) catch return error.OutOfMemory;
        src.appendSlice(a, line) catch return error.OutOfMemory;
    }
    const dir = std.fmt.allocPrint(a, "{s}/.fels-cache/build/{s}", .{ base_dir, art.name }) catch return error.OutOfMemory;
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const file = std.fmt.allocPrint(a, "{s}/build_options.fels", .{dir}) catch return error.OutOfMemory;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = src.items }) catch {
        std.debug.print("fels build: cannot write {s}\n", .{file});
        return error.CompileFailed;
    };
    roots.append(a, .{ .name = "build_options", .dir = dir }) catch return error.OutOfMemory;
    return roots.items;
}

/// The text of the last `-Dname` or `-Dname=value` given, or null if the option was not
/// passed. A bare `-Dname` gives "".
fn optionValue(options: []const []const u8, name: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (options) |o| {
        const eq = std.mem.indexOfScalar(u8, o, '=') orelse o.len;
        if (!std.mem.eql(u8, o[0..eq], name)) continue;
        found = if (eq < o.len) o[eq + 1 ..] else "";
    }
    return found;
}

/// A bool option's text: a bare `-Dname` means true.
fn parseBool(text: []const u8) ?bool {
    inline for (.{ "", "true", "1", "yes", "on" }) |t| if (std.ascii.eqlIgnoreCase(text, t)) return true;
    inline for (.{ "false", "0", "no", "off" }) |f| if (std.ascii.eqlIgnoreCase(text, f)) return false;
    return null;
}

/// Whether `word` is one of the `|` separated `choices`.
fn isChoice(choices: []const u8, word: []const u8) bool {
    var it = std.mem.splitScalar(u8, choices, '|');
    while (it.next()) |c| if (std.mem.eql(u8, c, word)) return true;
    return false;
}

/// The name part of a `-Dname=value` option.
fn optionName(option: []const u8) []const u8 {
    return option[0 .. std.mem.indexOfScalar(u8, option, '=') orelse option.len];
}

/// Report every problem the script run found: a bad option value, a `-D` name the script
/// does not declare (usually a typo), a wrong call. Returns whether there was one.
fn reportScriptErrors(plan: *BuildPlan) bool {
    for (plan.options) |o| {
        const name = optionName(o);
        const known = for (plan.declared.items) |d| {
            if (std.mem.eql(u8, d.name, name)) break true;
        } else false;
        if (!known) plan.fail("unknown build option -D{s}", .{name});
    }
    var about_options = false;
    for (plan.errors.items) |e| {
        std.debug.print("fels build: {s}\n", .{e});
        if (std.mem.startsWith(u8, e, "-D") or std.mem.startsWith(u8, e, "unknown build option") or
            std.mem.startsWith(u8, e, "option `")) about_options = true;
    }
    if (about_options and plan.declared.items.len != 0) {
        std.debug.print("build options of this build.fels:\n", .{});
        printOptions(plan);
    }
    return plan.errors.items.len != 0;
}

/// Whether a `-Dname` flag (bare or `name=...`) was passed.
fn hasFlag(options: []const []const u8, name: []const u8) bool {
    for (options) |o| {
        if (std.mem.eql(u8, o, name)) return true;
        const eq = std.mem.indexOfScalar(u8, o, '=') orelse continue;
        if (std.mem.eql(u8, o[0..eq], name)) return true;
    }
    return false;
}

// Options + entry

pub const RunOptions = struct {
    /// A requested target/step name (`fels build <name>`), or null for the default.
    target: ?[]const u8 = null,
    /// `--release`: build the artifacts left at `debug` as `release_safe` (optimized, with the
    /// safety checks).
    release: bool = false,
    /// `--release-fast`: build them as `release_fast` (optimized, without the safety checks).
    release_fast: bool = false,
    /// Just print the artifacts and steps, build nothing.
    list: bool = false,
    quiet: bool = false,
    /// Force-link the C runtime for every artifact (`fels build --libc`), even if
    /// auto-detection didn't flag a static C lib. An escape hatch.
    link_libc: bool = false,
    /// LLVM bin dir + default library search paths, forwarded from the CLI.
    llvm_bin: []const u8 = "",
    lib_paths: []const []const u8 = &.{},
    /// Extra args passed through to a `run` step's executable.
    run_args: []const []const u8 = &.{},
    /// `-Dname` / `-Dname=value` build options, exposed to `b.option*` in build.fels.
    options: []const []const u8 = &.{},
    /// `--prefix <dir>`: where `fels build install` copies to, over `b.install_prefix`.
    prefix: ?[]const u8 = null,
    /// The environment `fels build` runs in; a command's `env` adds to it.
    environ: ?*const std.process.Environ.Map = null,
    /// `--offline`: packages come from fels.lock and the cache only, git is never run.
    offline: bool = false,
    /// `--frozen`: stop when fels.lock would change.
    frozen: bool = false,
    /// `--rebuild`: build every artifact, even one that is up to date.
    rebuild: bool = false,
};

/// Run `build_path` (a build.fels) and execute the resulting plan.
pub fn run(gpa: std.mem.Allocator, io: std.Io, build_path: []const u8, opts: RunOptions) BuildError!void {
    const started = clock.monoNs();
    // On a terminal, the live tree: build.fels while it runs, then each artifact and its stages.
    if (!opts.quiet and !opts.list) ui.start("fels build", 0);
    defer ui.finish();
    const script = ui.root.start(std.fs.path.basename(build_path), 0);
    var plan = try loadPlan(gpa, io, build_path, opts.options);
    defer plan.deinit();

    // The packages of fels.pkg next to build.fels: import roots for every artifact, and the
    // capabilities of their compile-time code.
    const base = std.fs.path.dirname(build_path) orelse ".";
    const loaded = pkg.project.load(plan.a(), io, base, opts.environ, .{ .offline = opts.offline, .frozen = opts.frozen }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.PackageError => error.PackageError,
    };
    if (loaded) |r| {
        plan.packages = r.packages;
        plan.self_root = r.self_root;
    }
    const folder_caps = try folderCaps(plan.a(), plan.packages);
    try runPackageBuilds(gpa, io, &plan, folder_caps);
    ir.package_caps = folder_caps;
    defer ir.package_caps = &.{};
    script.end();

    if (opts.list) {
        printList(&plan);
        return;
    }

    // 3. Execute the plan.
    const base_dir = std.fs.path.dirname(build_path) orelse ".";
    executePlan(gpa, io, &plan, base_dir, opts) catch |err| {
        if (!opts.quiet) printDone(&plan, started);
        return err;
    };
    if (!opts.quiet) printDone(&plan, started);
}

/// `Build Summary: 2 built, 1 up to date · 3.12s`, the last line of a build of more than one
/// artifact. Not after a program or the tests ran: their output ends the build.
fn printDone(plan: *BuildPlan, started: u64) void {
    ui.finish();
    if (plan.ran or plan.built + plan.fresh + plan.failed < 2) return;
    var buf: [160]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    ui.writeCounts(&w, &.{
        .{ .n = plan.built, .what = "built", .color = .good },
        .{ .n = plan.fresh, .what = "up to date", .color = .plain },
        .{ .n = plan.failed, .what = "failed", .color = .bad },
    }) catch {};
    var d: [48]u8 = undefined;
    std.debug.print("\n{s}Build Summary:{s} {s} \u{00b7} {s}\n", .{ ui.pal.bold(), ui.pal.reset(), w.buffered(), ui.dimDuration(&d, clock.sinceNs(started)) });
}

/// Run the build.fels of every package that has one, with the capabilities fels.pkg granted
/// the package, and collect what it provides to its users. Its artifacts and steps are its own
/// business and are not built.
fn runPackageBuilds(gpa: std.mem.Allocator, io: std.Io, plan: *BuildPlan, folder_caps: []const ir.FolderCaps) BuildError!void {
    try packageProvides(gpa, io, plan.a(), plan.packages, folder_caps, &plan.from_packages);
}

/// Run the build.fels of every package in `packages` that has one, with the capabilities of
/// its folder (`folder_caps`, in the same order), and add what it provides to `into`, the
/// paths joined to the package's folder. `fels test` links its test programs with this too.
pub fn packageProvides(
    gpa: std.mem.Allocator,
    io: std.Io,
    a: std.mem.Allocator,
    packages: []const pkg.resolve.Package,
    folder_caps: []const ir.FolderCaps,
    into: *Provided,
) BuildError!void {
    for (packages, folder_caps) |p, fc| {
        const script = for ([_][]const u8{"build.fels"}) |name| {
            const path = std.fs.path.join(a, &.{ p.dir, name }) catch return error.OutOfMemory;
            if (fileExists(io, path)) break path;
        } else continue;
        var sub = loadPlanWith(gpa, io, script, &.{}, fc.caps, false) catch |err| {
            std.debug.print("fels: the build.fels of the package `{s}` failed ({s})\n", .{ p.name, @errorName(err) });
            return error.PackageError;
        };
        defer sub.deinit();
        try addProvided(a, p.dir, sub.provided, into);
    }
}

/// What a test program of the project links with (`fels test`): what the packages provide,
/// and the library folders, libraries and runtime files the project's build.fels names, in
/// its `provide_*` calls and for its artifacts. The project folder is a library folder too,
/// as for an artifact.
pub fn testLinkInputs(
    gpa: std.mem.Allocator,
    io: std.Io,
    a: std.mem.Allocator,
    project_dir: []const u8,
    packages: []const pkg.resolve.Package,
    folder_caps: []const ir.FolderCaps,
) BuildError!Provided {
    var out: Provided = .{};
    try packageProvides(gpa, io, a, packages, folder_caps, &out);
    const script = try joinPath(a, project_dir, "build.fels");
    if (fileExists(io, script)) {
        var plan = try loadPlanWith(gpa, io, script, &.{}, .{ .ffi = .all }, false);
        defer plan.deinit();
        try addProvided(a, project_dir, plan.provided, &out);
        for (plan.artifacts.items) |art| {
            for (art.lib_paths.items) |d| try out.lib_paths.append(a, try joinPath(a, project_dir, d));
            for (art.libs.items) |l| try out.links.append(a, try a.dupe(u8, l));
            for (art.runtime_files.items) |f| try out.runtime_files.append(a, try joinPath(a, project_dir, f));
        }
    }
    try out.lib_paths.append(a, try a.dupe(u8, project_dir));
    return out;
}

/// Add `from` to `into`, with its paths joined to `dir`.
fn addProvided(a: std.mem.Allocator, dir: []const u8, from: Provided, into: *Provided) error{OutOfMemory}!void {
    for (from.lib_paths.items) |d| try into.lib_paths.append(a, try joinPath(a, dir, d));
    for (from.links.items) |l| try into.links.append(a, try a.dupe(u8, l));
    for (from.runtime_files.items) |f| try into.runtime_files.append(a, try joinPath(a, dir, f));
}

/// Run `build_path` (a build.fels) with the `-D` `options` and return the plan it records,
/// without building anything. The caller owns the plan (`deinit`).
pub fn loadPlan(gpa: std.mem.Allocator, io: std.Io, build_path: []const u8, options: []const []const u8) BuildError!BuildPlan {
    return loadPlanWith(gpa, io, build_path, options, .{ .ffi = .all }, true);
}

/// `loadPlan` with the capabilities of the script, and whether it must declare an artifact (a
/// package's build.fels need not).
fn loadPlanWith(
    gpa: std.mem.Allocator,
    io: std.Io,
    build_path: []const u8,
    options: []const []const u8,
    caps: vm_engine.Caps,
    need_artifact: bool,
) BuildError!BuildPlan {
    var plan = BuildPlan.init(gpa);
    errdefer plan.deinit();
    plan.options = options; // visible to `b.option*` during the build hook

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
        std.debug.print("{s} {s}: does not compile\n", .{ ui.mark(.fail), build_path });
        return error.CompileFailed;
    }

    // 2. Run `build(b)` on the comptime VM, recording into `plan`.
    const host = vm_engine.BuildHost{ .ctx = &plan, .call = hostCall };
    ir.runBuildHookWith(gpa, fe, host, caps) catch {
        // Every failure inside the hook used to surface as `NoBuildFn`, which reads
        // as "your build.fels has no `build`" even when the function was found and
        // ran partway. The VM prints its own reason above when it has one.
        std.debug.print(
            "fels build: `build.fels` did not finish. Check that it declares " ++
                "`build :: fn(b: Build)`, and see any error reported above.\n",
            .{},
        );
        return error.BuildHookFailed;
    };
    if (plan.oom) return error.OutOfMemory;
    if (reportScriptErrors(&plan)) return error.ScriptError;
    if (need_artifact and plan.artifacts.items.len == 0) return error.NoArtifacts;
    return plan;
}

fn executePlan(gpa: std.mem.Allocator, io: std.Io, plan: *BuildPlan, base_dir: []const u8, opts: RunOptions) BuildError!void {
    plan.state = plan.a().alloc(BuildState, plan.artifacts.items.len) catch return error.OutOfMemory;
    @memset(plan.state, .unbuilt);
    plan.step_state = plan.a().alloc(BuildState, plan.steps.items.len) catch return error.OutOfMemory;
    @memset(plan.step_state, .unbuilt);
    plan.cwd_abs = std.process.currentPathAlloc(io, plan.a()) catch ".";

    if (opts.target) |name| {
        // `install` is a built-in step, unless the script names a step or artifact so.
        if (std.mem.eql(u8, name, "install") and !hasTarget(plan, name))
            return runInstall(gpa, io, plan, base_dir, opts);
        const step = for (plan.steps.items, 0..) |st, i| {
            if (std.mem.eql(u8, st.name, name)) break i;
        } else null;
        const artifact = for (plan.artifacts.items, 0..) |art, i| {
            if (std.mem.eql(u8, art.name, name)) break i;
        } else null;
        if (step) |s| {
            try runStep(gpa, io, plan, base_dir, s, opts);
        } else if (artifact) |i| {
            try buildArtifact(gpa, io, plan, base_dir, i, opts);
        } else {
            std.debug.print("fels build: no artifact or step named '{s}'\n", .{name});
            return error.UnknownTarget;
        }
    } else if (plan.default_step) |s| {
        try runStep(gpa, io, plan, base_dir, s, opts);
    } else if (plan.default_idx) |idx| {
        try buildArtifact(gpa, io, plan, base_dir, idx, opts);
    } else {
        for (0..plan.artifacts.items.len) |i| try buildArtifact(gpa, io, plan, base_dir, i, opts);
    }

    if (plan.want_summary and !opts.quiet) printSummary(plan, base_dir);
}

/// Run step `idx` once: build its artifacts, run the steps it comes after, then its actions.
fn runStep(gpa: std.mem.Allocator, io: std.Io, plan: *BuildPlan, base_dir: []const u8, idx: usize, opts: RunOptions) BuildError!void {
    switch (plan.step_state[idx]) {
        .built => return,
        .building => {
            std.debug.print("fels build: step '{s}' comes after itself\n", .{plan.steps.items[idx].name});
            return error.DependencyCycle;
        },
        .unbuilt => {},
    }
    plan.step_state[idx] = .building;
    const step = plan.steps.items[idx];
    for (step.artifacts.items) |art| try buildArtifact(gpa, io, plan, base_dir, art, opts);
    for (step.after.items) |other| try runStep(gpa, io, plan, base_dir, other, opts);
    if (step.kind == .test_dir) try runTestDir(gpa, io, plan, base_dir, step, opts);
    for (step.actions.items) |action| try runAction(gpa, io, plan, base_dir, action, opts);
    plan.step_state[idx] = .built;
}

fn runAction(gpa: std.mem.Allocator, io: std.Io, plan: *BuildPlan, base_dir: []const u8, action: Action, opts: RunOptions) BuildError!void {
    const a = plan.a();
    switch (action) {
        .command => |c| try runCommand(gpa, io, plan, base_dir, plan.commands.items[c], opts),
        .copy_file => |p| try copyFile(gpa, io, joinPath(a, base_dir, p.a) catch return error.OutOfMemory, joinPath(a, base_dir, p.b) catch return error.OutOfMemory, opts),
        .copy_dir => |p| _ = try copyDir(gpa, io, joinPath(a, base_dir, p.a) catch return error.OutOfMemory, joinPath(a, base_dir, p.b) catch return error.OutOfMemory, opts),
        .write_file => |p| {
            const path = joinPath(a, base_dir, p.a) catch return error.OutOfMemory;
            if (std.fs.path.dirname(path)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = p.b }) catch {
                std.debug.print("fels build: cannot write {s}\n", .{path});
                return error.StepFailed;
            };
            if (!opts.quiet) std.debug.print("{s} {s}\n", .{ ui.mark(.ok), path });
        },
        .remove => |rel| {
            const path = joinPath(a, base_dir, rel) catch return error.OutOfMemory;
            std.Io.Dir.cwd().deleteTree(io, path) catch {
                std.debug.print("fels build: cannot remove {s}\n", .{path});
                return error.StepFailed;
            };
            if (!opts.quiet) std.debug.print("{s} removed {s}\n", .{ ui.mark(.ok), path });
        },
        .print => |text| std.debug.print("{s}\n", .{text}),
    }
}

/// `path` (relative to the process's working directory) as an absolute path.
fn absPath(plan: *BuildPlan, path: []const u8) BuildError![]const u8 {
    return std.fs.path.resolve(plan.a(), &.{ plan.cwd_abs, path }) catch return error.OutOfMemory;
}

fn runCommand(gpa: std.mem.Allocator, io: std.Io, plan: *BuildPlan, base_dir: []const u8, cmd: Command, opts: RunOptions) BuildError!void {
    const a = plan.a();
    var argv: std.ArrayList([]const u8) = .empty;
    // The program: an artifact's output, a path relative to build.fels, or a name on PATH.
    const program = if (cmd.program_artifact) |art|
        try absPath(plan, try resolveOutput(plan, base_dir, plan.artifacts.items[art]))
    else if (std.mem.indexOfAny(u8, cmd.program, "/\\") != null and !std.fs.path.isAbsolute(cmd.program))
        try absPath(plan, joinPath(a, base_dir, cmd.program) catch return error.OutOfMemory)
    else
        cmd.program;
    argv.append(a, program) catch return error.OutOfMemory;
    for (cmd.args.items) |arg| argv.append(a, switch (arg) {
        .text => |t| t,
        .output => |art| try absPath(plan, try resolveOutput(plan, base_dir, plan.artifacts.items[art])),
    }) catch return error.OutOfMemory;
    if (cmd.is_run) argv.appendSlice(a, opts.run_args) catch return error.OutOfMemory;

    const cwd = try absPath(plan, if (cmd.cwd) |d| joinPath(a, base_dir, d) catch return error.OutOfMemory else base_dir);

    // The environment: the build's own, with the command's variables on top.
    var env: ?std.process.Environ.Map = null;
    defer if (env) |*e| e.deinit();
    if (cmd.env.items.len != 0) {
        env = if (opts.environ) |parent| parent.clone(gpa) catch return error.OutOfMemory else std.process.Environ.Map.init(gpa);
        for (cmd.env.items) |kv| env.?.put(kv.a, kv.b) catch return error.OutOfMemory;
    }

    ui.finish();
    plan.ran = plan.ran or cmd.is_run;
    if (!opts.quiet) {
        // The program as build.fels names it (an artifact by its output), and its arguments.
        const shown = if (cmd.program_artifact) |art| try resolveOutput(plan, base_dir, plan.artifacts.items[art]) else cmd.program;
        std.debug.print("{s} {s}", .{ ui.mark(.run), shown });
        for (argv.items[1..]) |arg| std.debug.print(" {s}", .{arg});
        std.debug.print("\n", .{});
    }
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .environ_map = if (env) |*e| e else null,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        std.debug.print("fels build: cannot run {s}: {s}\n", .{ program, @errorName(err) });
        return if (cmd.is_run) error.RunFailed else error.StepFailed;
    };
    const term = child.wait(io) catch return error.StepFailed;
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("{s} {s} exited with code {d}\n", .{ ui.mark(if (cmd.is_run) .warn else .fail), std.fs.path.basename(program), code });
            if (!cmd.is_run) return error.StepFailed;
        },
        else => {
            std.debug.print("{s} {s} did not exit normally\n", .{ ui.mark(.fail), std.fs.path.basename(program) });
            return if (cmd.is_run) error.RunFailed else error.StepFailed;
        },
    }
}

/// A post-build summary of every artifact (kind, output path, opt level).
fn printSummary(plan: *BuildPlan, base_dir: []const u8) void {
    ui.finish();
    std.debug.print("\n{s}Artifacts{s}", .{ ui.pal.bold(), ui.pal.reset() });
    if (plan.workspace_name) |w| std.debug.print(" \u{00b7} {s}", .{w});
    std.debug.print("\n", .{});
    for (plan.artifacts.items) |art| {
        const out = resolveOutput(plan, base_dir, art) catch art.name;
        const opt = optName(art.opt);
        const inst: []const u8 = if (art.install) " [install]" else "";
        std.debug.print("  {s: <16} {s: <14} {s} ({s}){s}", .{ art.name, @tagName(art.kind), out, opt, inst });
        if (art.version) |v| std.debug.print(" v{s}", .{v});
        std.debug.print("\n", .{});
    }
}

/// Build artifact `idx` once, after the library artifacts it links.
fn buildArtifact(gpa: std.mem.Allocator, io: std.Io, plan: *BuildPlan, base_dir: []const u8, idx: usize, opts: RunOptions) BuildError!void {
    switch (plan.state[idx]) {
        .built => return,
        .building => {
            std.debug.print("fels build: '{s}' links itself through link_artifact\n", .{plan.artifacts.items[idx].name});
            return error.DependencyCycle;
        },
        .unbuilt => {},
    }
    plan.state[idx] = .building;
    for (plan.artifacts.items[idx].after_steps.items) |step| try runStep(gpa, io, plan, base_dir, step, opts);
    for (plan.artifacts.items[idx].link_artifacts.items) |dep| try buildArtifact(gpa, io, plan, base_dir, dep, opts);
    try buildOne(gpa, io, plan, base_dir, idx, opts);
    plan.state[idx] = .built;
}

fn buildOne(gpa: std.mem.Allocator, io: std.Io, plan: *BuildPlan, base_dir: []const u8, idx: usize, opts: RunOptions) BuildError!void {
    const art = plan.artifacts.items[idx];
    const a = plan.a();

    const root_path = joinPath(a, base_dir, art.root) catch return error.OutOfMemory;
    const out_path = try resolveOutput(plan, base_dir, art);
    const obj_path = std.fmt.allocPrint(a, "{s}.o", .{out_path}) catch return error.OutOfMemory;

    // Make sure the output directory exists (e.g. `bin/`, `out/`).
    if (std.fs.path.dirname(out_path)) |dir| {
        if (dir.len != 0) std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }

    // Library search paths: the CLI defaults + the artifact's own + the project
    // dir itself, so a `raylib.lib` sitting next to `build.fels` links regardless of
    // the working directory `fels build` was invoked from.
    var lib_paths: std.ArrayList([]const u8) = .empty;
    lib_paths.appendSlice(a, opts.lib_paths) catch return error.OutOfMemory;
    lib_paths.appendSlice(a, plan.from_packages.lib_paths.items) catch return error.OutOfMemory;
    for (art.lib_paths.items) |lp| {
        const abs = joinPath(a, base_dir, lp) catch return error.OutOfMemory;
        lib_paths.append(a, abs) catch return error.OutOfMemory;
    }
    lib_paths.append(a, base_dir) catch return error.OutOfMemory;

    // `--release` makes a debug artifact release_safe
    const mode = modeSettings(releaseMode(opts, art.opt));
    const opt_level = mode.opt_level;
    const is_lib = art.kind == .shared_library;
    // `strip`: ld.lld leaves out the symbol table. A Windows output has none to begin with.
    var link_flags: std.ArrayList([]const u8) = .empty;
    link_flags.appendSlice(a, art.link_flags.items) catch return error.OutOfMemory;
    if (art.strip and art.target_os == .linux) link_flags.append(a, "--strip-all") catch return error.OutOfMemory;
    // A static library is the object packed into an archive after compiling.
    const stop_at_obj = art.kind == .object or art.kind == .static_library;

    // Auto-detect each linked library by peeking inside the `.lib`: a static
    // archive needs the C runtime; an import library's sibling DLL is copied next
    // to the output. We search the artifact's own lib paths PLUS the project dir
    // itself — the linker also looks in the working directory, so running
    // `fels build` from a vendor lib folder (where `raylib.lib` sits next to
    // `build.fels`) still triggers detection. Explicit static_link()/runtime_file()
    // still apply on top of this.
    var search_dirs: std.ArrayList([]const u8) = .empty;
    for (art.lib_paths.items) |lp|
        search_dirs.append(a, joinPath(a, base_dir, lp) catch continue) catch {};
    search_dirs.append(a, base_dir) catch {};
    search_dirs.appendSlice(a, plan.from_packages.lib_paths.items) catch return error.OutOfMemory;

    // The libraries to link: the named ones, then the library artifacts of this build
    // (found in their output directory, and inspected like any other library below).
    var linked: std.ArrayList([]const u8) = .empty;
    linked.appendSlice(a, art.libs.items) catch return error.OutOfMemory;
    linked.appendSlice(a, plan.from_packages.links.items) catch return error.OutOfMemory;
    for (art.link_artifacts.items) |dep| {
        const dep_out = try resolveOutput(plan, base_dir, plan.artifacts.items[dep]);
        const dep_dir = std.fs.path.dirname(dep_out) orelse ".";
        lib_paths.append(a, dep_dir) catch return error.OutOfMemory;
        search_dirs.append(a, dep_dir) catch return error.OutOfMemory;
        linked.append(a, std.fs.path.stem(dep_out)) catch return error.OutOfMemory;
    }

    var need_libc = art.link_mode == 1 or opts.link_libc or art.link_libc;
    var has_fels_lib = false;
    // The library files this artifact links, for the up-to-date check.
    var lib_files: std.ArrayList([]const u8) = .empty;
    var auto_dlls: std.ArrayList([]const u8) = .empty;
    for (linked.items) |lib_name| {
        for (search_dirs.items) |dir| {
            const lib_file = std.fmt.allocPrint(a, "{s}/{s}.lib", .{ dir, lib_name }) catch continue;
            const data = readSource(gpa, io, lib_file) orelse continue;
            defer gpa.free(data);
            lib_files.append(a, lib_file) catch return error.OutOfMemory;
            switch (inspectLib(a, data)) {
                .static => need_libc = true,
                .fels_static => has_fels_lib = true,
                .import_lib => |dll| if (dll.len != 0) {
                    // `static_link()` asserts intent: warn if the resolved lib is
                    // actually an import library (you'll get a dynamic link).
                    if (art.link_mode == 1)
                        std.debug.print("fels build: warning: '{s}' requested static linking, but '{s}/{s}.lib' is an import library — the link will be DYNAMIC. Point lib_path at the static archive.\n", .{ lib_name, dir, lib_name });
                    auto_dlls.append(a, joinPath(a, dir, dll) catch continue) catch {};
                    if (!opts.quiet) std.debug.print("  {s}{s} \u{2192} dynamic ({s}){s}\n", .{ ui.pal.dim(), lib_name, dll, ui.pal.reset() });
                },
                .unknown => {},
            }
            break; // found the lib on this path; stop searching
        }
    }

    // Libraries to link: the artifact's own, plus the C runtime when a static C
    // library is involved (it brings code but not the CRT it depends on).
    var libs: std.ArrayList([]const u8) = .empty;
    libs.appendSlice(a, linked.items) catch return error.OutOfMemory;
    // "Link libc" resolves per host: the Windows CRT (ucrt + vcruntime) here; on
    // Linux the driver's `link_libc` path links glibc instead (no Windows libs).
    if (need_libc and art.target_os == .windows) {
        libs.append(a, "ucrt") catch return error.OutOfMemory;
        libs.append(a, "vcruntime") catch return error.OutOfMemory;
    }

    // When a static C library is involved, honor ITS own `/DEFAULTLIB` directives
    // by default — so its system deps (opengl32, gdi32, …) flow in automatically,
    // C3-style — unless the artifact opted out with `no_default_libs()`.
    const honor_defaultlibs = (need_libc or has_fels_lib) and !art.no_default_libs;

    const src = readSource(gpa, io, root_path);
    defer if (src) |s| gpa.free(s);

    pipeline.module_roots = try moduleRootsFor(io, plan, base_dir, art);
    defer pipeline.module_roots = &.{};

    // Up to date: the same settings, the same compiler, and the same text in every file the
    // last build read (sources, std, build_options, the libraries it linked).
    const key = try settingsKey(io, plan, art, .{
        .opt_level = opt_level,
        .safety = mode.safety,
        .lib_paths = lib_paths.items,
        .libs = libs.items,
        .link_flags = link_flags.items,
        .need_libc = need_libc,
        .honor_defaultlibs = honor_defaultlibs,
    });
    const stamp = std.fmt.allocPrint(a, "{s}/.fels-cache/build/{s}/inputs", .{ base_dir, art.name }) catch return error.OutOfMemory;
    const fresh = !opts.rebuild and fileExists(io, out_path) and upToDate(gpa, io, stamp, key);
    if (fresh) {
        plan.fresh += 1;
        if (!opts.quiet) std.debug.print("{s} {s} {s}up to date{s}\n", .{ ui.mark(.skip), art.name, ui.pal.dim(), ui.pal.reset() });
    }
    var inputs: std.ArrayList([]const u8) = .empty;
    var stages = ui.Stages.begin(ui.root, art.name);

    if (!fresh) driver.compileFileWithLlvm(gpa, io, .{
        .inputs = &inputs,
        .inputs_allocator = a,
        .file_name = root_path,
        .source = src orelse "",
        .obj_path = obj_path,
        .exe_path = if (stop_at_obj) null else out_path,
        .dll = is_lib,
        .opt_level = opt_level,
        .safety = mode.safety,
        .llvm_bin = opts.llvm_bin,
        .lib_paths = lib_paths.items,
        .extra_libs = libs.items,
        .subsystem = if (art.subsystem == 1) .windows else .console,
        .entry = art.entry,
        .stack_reserve = art.stack,
        .link_flags = link_flags.items,
        .honor_defaultlibs = honor_defaultlibs,
        .link_libc = need_libc or art.target_gnu,
        .library_object = art.kind == .static_library,
        .target_os = art.target_os,
        .sysroot = if (art.sysroot.len != 0) joinPath(a, base_dir, art.sysroot) catch return error.OutOfMemory else "",
        .progress = ui.Stages.step,
        .progress_ctx = &stages,
    }) catch |err| {
        _ = stages.end();
        plan.failed += 1;
        std.debug.print("{s} {s}: {s}\n", .{ ui.mark(.fail), art.name, ui.failure(err) });
        return error.CompileFailed;
    };
    const took = stages.end();
    if (!fresh) {
        if (art.kind == .static_library) try writeStaticLibrary(gpa, io, obj_path, out_path);
        inputs.appendSlice(a, lib_files.items) catch return error.OutOfMemory;
        writeStamp(gpa, io, stamp, key, inputs.items);
        plan.built += 1;
        var d: [48]u8 = undefined;
        if (!opts.quiet) std.debug.print("{s} {s} {s}\u{2192}{s} {s}  {s}\n", .{ ui.mark(.ok), art.name, ui.pal.dim(), ui.pal.reset(), out_path, ui.dimDuration(&d, took) });
    }

    // Copy runtime dependencies next to the output — both the explicit
    // `runtime_file`s and the DLLs auto-detected from import libraries — so a
    // dynamically-linked program runs without manually shipping its DLLs.
    const out_dir = std.fs.path.dirname(out_path) orelse ".";
    var copy_srcs: std.ArrayList([]const u8) = .empty;
    for (art.runtime_files.items) |rf| copy_srcs.append(a, joinPath(a, base_dir, rf) catch continue) catch {};
    copy_srcs.appendSlice(a, plan.from_packages.runtime_files.items) catch {};
    copy_srcs.appendSlice(a, auto_dlls.items) catch {};
    for (copy_srcs.items) |csrc| {
        const dst = joinPath(a, out_dir, std.fs.path.basename(csrc)) catch continue;
        if (std.mem.eql(u8, csrc, dst)) { // already in place
            plan.artifacts.items[idx].copied.append(a, dst) catch {};
            continue;
        }
        const data = readSource(gpa, io, csrc) orelse {
            std.debug.print("fels build: runtime file not found: {s}\n", .{csrc});
            continue;
        };
        defer gpa.free(data);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = data }) catch continue;
        plan.artifacts.items[idx].copied.append(a, dst) catch {};
        if (!opts.quiet) std.debug.print("  {s}+ {s}{s}\n", .{ ui.pal.dim(), dst, ui.pal.reset() });
    }
}

/// Whether the script declares a step or an artifact called `name`.
fn hasTarget(plan: *BuildPlan, name: []const u8) bool {
    for (plan.steps.items) |st| if (std.mem.eql(u8, st.name, name)) return true;
    for (plan.artifacts.items) |art| if (std.mem.eql(u8, art.name, name)) return true;
    return false;
}

/// `fels build install`: build every artifact marked `install()` and copy it into the
/// prefix (programs and DLLs to `bin/`, static and import libraries and objects to `lib/`),
/// with the files the build copied next to it, then the `install_file`/`install_dir` items.
fn runInstall(gpa: std.mem.Allocator, io: std.Io, plan: *BuildPlan, base_dir: []const u8, opts: RunOptions) BuildError!void {
    const a = plan.a();
    var any = plan.install_items.items.len != 0;
    for (plan.artifacts.items) |art| any = any or art.install;
    if (!any) {
        std.debug.print("fels build: nothing to install; mark an artifact with install(), or use b.install_file / b.install_dir\n", .{});
        return error.UnknownTarget;
    }

    const prefix_rel = opts.prefix orelse plan.install_prefix orelse "dist";
    const prefix = if (std.fs.path.isAbsolute(prefix_rel)) prefix_rel else joinPath(a, base_dir, prefix_rel) catch return error.OutOfMemory;
    const bin_dir = joinPath(a, prefix, "bin") catch return error.OutOfMemory;
    const lib_dir = joinPath(a, prefix, "lib") catch return error.OutOfMemory;

    var count: usize = 0;
    for (plan.artifacts.items, 0..) |art, i| {
        if (!art.install) continue;
        try buildArtifact(gpa, io, plan, base_dir, i, opts);
        const out = try resolveOutput(plan, base_dir, art);
        const dest_dir = switch (art.kind) {
            .executable, .shared_library => bin_dir,
            .static_library, .object => lib_dir,
        };
        try installFile(gpa, io, out, dest_dir, opts);
        count += 1;
        // A DLL's import library, for programs that link against it.
        if (art.kind == .shared_library) {
            const dir = std.fs.path.dirname(out) orelse ".";
            const implib = std.fmt.allocPrint(a, "{s}.lib", .{std.fs.path.stem(out)}) catch return error.OutOfMemory;
            const implib_path = joinPath(a, dir, implib) catch return error.OutOfMemory;
            if (fileExists(io, implib_path)) {
                try installFile(gpa, io, implib_path, lib_dir, opts);
                count += 1;
            }
        }
        for (plan.artifacts.items[i].copied.items) |c| {
            try installFile(gpa, io, c, bin_dir, opts);
            count += 1;
        }
    }

    for (plan.install_items.items) |item| {
        const src = joinPath(a, base_dir, item.src) catch return error.OutOfMemory;
        const dest = joinPath(a, prefix, item.dest) catch return error.OutOfMemory;
        if (item.is_dir) {
            count += try copyDir(gpa, io, src, dest, opts);
        } else {
            try copyFile(gpa, io, src, dest, opts);
            count += 1;
        }
    }
    ui.finish();
    if (!opts.quiet) std.debug.print("{s} installed {d} {s} to {s}\n", .{ ui.mark(.ok), count, if (count == 1) "file" else "files", prefix });
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Copy `src` into the folder `dest_dir`, keeping its name.
fn installFile(gpa: std.mem.Allocator, io: std.Io, src: []const u8, dest_dir: []const u8, opts: RunOptions) BuildError!void {
    const dest = std.fs.path.join(gpa, &.{ dest_dir, std.fs.path.basename(src) }) catch return error.OutOfMemory;
    defer gpa.free(dest);
    try copyFile(gpa, io, src, dest, opts);
}

/// Copy the file `src` to the path `dest`, creating the folders on the way.
fn copyFile(gpa: std.mem.Allocator, io: std.Io, src: []const u8, dest: []const u8, opts: RunOptions) BuildError!void {
    const data = readSource(gpa, io, src) orelse {
        std.debug.print("fels build: cannot read {s}\n", .{src});
        return error.InstallFailed;
    };
    defer gpa.free(data);
    if (std.fs.path.dirname(dest)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = data }) catch {
        std.debug.print("fels build: cannot write {s}\n", .{dest});
        return error.InstallFailed;
    };
    if (!opts.quiet) std.debug.print("  {s}+ {s}{s}\n", .{ ui.pal.dim(), dest, ui.pal.reset() });
}

/// Copy the folder `src` to `dest` with everything in it. Returns the number of files.
fn copyDir(gpa: std.mem.Allocator, io: std.Io, src: []const u8, dest: []const u8, opts: RunOptions) BuildError!usize {
    var dir = std.Io.Dir.cwd().openDir(io, src, .{ .iterate = true }) catch {
        std.debug.print("fels build: cannot open folder {s}\n", .{src});
        return error.InstallFailed;
    };
    defer dir.close(io);
    std.Io.Dir.cwd().createDirPath(io, dest) catch {};
    var count: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const from = std.fs.path.join(gpa, &.{ src, entry.name }) catch return error.OutOfMemory;
        defer gpa.free(from);
        const to = std.fs.path.join(gpa, &.{ dest, entry.name }) catch return error.OutOfMemory;
        defer gpa.free(to);
        switch (entry.kind) {
            .directory => count += try copyDir(gpa, io, from, to, opts),
            .file => {
                try copyFile(gpa, io, from, to, opts);
                count += 1;
            },
            else => {},
        }
    }
    return count;
}

const KeyParts = struct {
    opt_level: u2,
    safety: bool,
    lib_paths: []const []const u8,
    libs: []const []const u8,
    link_flags: []const []const u8,
    need_libc: bool,
    honor_defaultlibs: bool,
};

/// A hash of everything about an artifact's build that is not a file's text: its settings,
/// the import roots, and the compiler that builds it.
fn settingsKey(io: std.Io, plan: *BuildPlan, art: Artifact, parts: KeyParts) BuildError!u64 {
    var h = std.hash.Wyhash.init(0x5fe15);
    const str = struct {
        fn add(hh: *std.hash.Wyhash, s: []const u8) void {
            hh.update(s);
            hh.update(&.{0});
        }
    }.add;
    str(&h, build_options.version);
    if (std.process.executablePathAlloc(io, plan.a())) |exe| {
        str(&h, exe);
        if (std.Io.Dir.cwd().statFile(io, exe, .{})) |st| {
            h.update(std.mem.asBytes(&st.size));
            h.update(std.mem.asBytes(&st.mtime));
        } else |_| {}
    } else |_| {}
    str(&h, art.name);
    str(&h, art.root);
    str(&h, @tagName(art.kind));
    str(&h, @tagName(art.target_os));
    h.update(&.{ parts.opt_level, @intFromBool(parts.safety), art.subsystem, @intFromBool(art.target_gnu), @intFromBool(art.strip), @intFromBool(parts.need_libc), @intFromBool(parts.honor_defaultlibs) });
    h.update(std.mem.asBytes(&art.stack));
    str(&h, art.sysroot);
    str(&h, art.entry orelse "");
    str(&h, art.out_path orelse "");
    for (parts.lib_paths) |s| str(&h, s);
    str(&h, "|");
    for (parts.libs) |s| str(&h, s);
    str(&h, "|");
    for (parts.link_flags) |s| str(&h, s);
    str(&h, "|");
    for (pipeline.module_roots) |m| {
        str(&h, m.name);
        str(&h, m.dir);
    }
    // What each package's compile-time code may do (fels.pkg): it decides what a #run can.
    for (ir.package_caps) |pc| {
        str(&h, pc.dir);
        switch (pc.caps.ffi) {
            .none => str(&h, "none"),
            .all => str(&h, "all"),
            .libs => |libs| for (libs) |l| str(&h, l),
        }
    }
    return h.final();
}

fn hashFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?u64 {
    const data = readSource(gpa, io, path) orelse return null;
    defer gpa.free(data);
    return std.hash.Wyhash.hash(0, data);
}

/// Whether the stamp of the last build says the artifact is up to date: the same settings
/// key, and every file it lists still has the text it had.
fn upToDate(gpa: std.mem.Allocator, io: std.Io, stamp: []const u8, key: u64) bool {
    const text = readSource(gpa, io, stamp) orelse return false;
    defer gpa.free(text);
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    const first = lines.next() orelse return false;
    if (!std.mem.startsWith(u8, first, "key ")) return false;
    if ((std.fmt.parseInt(u64, first[4..], 16) catch return false) != key) return false;
    while (lines.next()) |line| {
        // file <hash> <path>
        if (!std.mem.startsWith(u8, line, "file ")) return false;
        const rest = line[5..];
        const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return false;
        const want = std.fmt.parseInt(u64, rest[0..sp], 16) catch return false;
        const got = hashFile(gpa, io, rest[sp + 1 ..]) orelse return false;
        if (got != want) return false;
    }
    return true;
}

/// Write the stamp of a build: the settings key and the hash of every file it read.
fn writeStamp(gpa: std.mem.Allocator, io: std.Io, stamp: []const u8, key: u64, files: []const []const u8) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.print(gpa, "key {x}\n", .{key}) catch return;
    for (files) |f| {
        const h = hashFile(gpa, io, f) orelse continue;
        out.print(gpa, "file {x} {s}\n", .{ h, f }) catch return;
    }
    if (std.fs.path.dirname(stamp)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = stamp, .data = out.items }) catch {};
}

/// Pack the compiled object into the static library `out_path`.
fn writeStaticLibrary(gpa: std.mem.Allocator, io: std.Io, obj_path: []const u8, out_path: []const u8) BuildError!void {
    const obj = readSource(gpa, io, obj_path) orelse {
        std.debug.print("fels build: cannot read {s}\n", .{obj_path});
        return error.CompileFailed;
    };
    defer gpa.free(obj);
    const lib = coff_archive.write(gpa, &.{.{ .name = std.fs.path.basename(obj_path), .data = obj }}) catch |err| {
        std.debug.print("fels build: cannot write {s}: {s}\n", .{ out_path, @errorName(err) });
        return error.CompileFailed;
    };
    defer gpa.free(lib);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = lib }) catch {
        std.debug.print("fels build: cannot write {s}\n", .{out_path});
        return error.CompileFailed;
    };
}

/// Run a `test_dir` step: compile and run every `*.fels` file in its folder (and the folders
/// below, with `recursive`) as a program of its own. A test passes when it exits with 0; a
/// failing one shows its exit code and output. The tests see the project's packages (its own
/// package too) and link what the step names. `fels build <step> -- <text>` runs only the files whose path has the text.
fn runTestDir(gpa: std.mem.Allocator, io: std.Io, plan: *BuildPlan, base_dir: []const u8, step: Step, opts: RunOptions) BuildError!void {
    const a = plan.a();
    const dir_abs = joinPath(a, base_dir, step.dir) catch return error.OutOfMemory;

    var dir = std.Io.Dir.cwd().openDir(io, dir_abs, .{ .iterate = true }) catch {
        std.debug.print("fels build: cannot open test directory '{s}'\n", .{dir_abs});
        return error.RunFailed;
    };
    defer dir.close(io);

    // The test files, relative to the folder, in a fixed order.
    var files: std.ArrayList([]const u8) = .empty;
    if (step.test_recursive) {
        var walker = dir.walk(a) catch return error.OutOfMemory;
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind == .file and pipeline.isSourceFile(entry.basename))
                files.append(a, a.dupe(u8, entry.path) catch return error.OutOfMemory) catch return error.OutOfMemory;
        }
    } else {
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind == .file and pipeline.isSourceFile(entry.name))
                files.append(a, a.dupe(u8, entry.name) catch return error.OutOfMemory) catch return error.OutOfMemory;
        }
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);

    // What the tests link: the step's libraries, its library artifacts, what packages provide.
    var lib_paths: std.ArrayList([]const u8) = .empty;
    lib_paths.appendSlice(a, opts.lib_paths) catch return error.OutOfMemory;
    lib_paths.appendSlice(a, plan.from_packages.lib_paths.items) catch return error.OutOfMemory;
    lib_paths.append(a, base_dir) catch return error.OutOfMemory;
    var libs: std.ArrayList([]const u8) = .empty;
    libs.appendSlice(a, step.test_libs.items) catch return error.OutOfMemory;
    libs.appendSlice(a, plan.from_packages.links.items) catch return error.OutOfMemory;
    for (step.test_link_artifacts.items) |i| {
        const out = try resolveOutput(plan, base_dir, plan.artifacts.items[i]);
        lib_paths.append(a, std.fs.path.dirname(out) orelse ".") catch return error.OutOfMemory;
        libs.append(a, std.fs.path.stem(out)) catch return error.OutOfMemory;
    }
    // The import roots of the project's own package and of the packages, as for an artifact.
    var roots: std.ArrayList(pipeline.ModuleRoot) = .empty;
    if (plan.self_root) |s| roots.append(a, s) catch return error.OutOfMemory;
    for (plan.packages) |p| roots.append(a, .{ .name = p.name, .dir = p.import_dir }) catch return error.OutOfMemory;
    pipeline.module_roots = roots.items;
    defer pipeline.module_roots = &.{};

    const filters = if (opts.run_args.len != 0) opts.run_args else step.test_filters.items;
    const mode = modeSettings(releaseMode(opts, step.test_opt));
    const opt_level = mode.opt_level;
    const out_dir = ".zig-cache/felstest";
    std.Io.Dir.cwd().createDirPath(io, out_dir) catch {};

    if (!opts.quiet) std.debug.print("running tests in {s}/\n", .{dir_abs});
    var passed: u32 = 0;
    var failed: u32 = 0;
    for (files.items) |rel| {
        if (filters.len != 0) {
            const wanted = for (filters) |f| {
                if (std.mem.indexOf(u8, rel, f) != null) break true;
            } else false;
            if (!wanted) continue;
        }
        const src_path = joinPath(a, dir_abs, rel) catch return error.OutOfMemory;
        // One output per test, also for tests of the same name in different folders.
        const flat = a.dupe(u8, rel) catch return error.OutOfMemory;
        for (flat) |*c| if (c.* == '/' or c.* == '\\') {
            c.* = '_';
        };
        const exe = std.fmt.allocPrint(a, "{s}/{s}.exe", .{ out_dir, flat }) catch return error.OutOfMemory;
        const obj = std.fmt.allocPrint(a, "{s}.o", .{exe}) catch return error.OutOfMemory;
        const src = readSource(gpa, io, src_path) orelse continue;
        defer gpa.free(src);

        var why: []const u8 = "";
        compile: {
            driver.compileFileWithLlvm(gpa, io, .{
                .file_name = src_path,
                .source = src,
                .obj_path = obj,
                .exe_path = exe,
                .opt_level = opt_level,
                .safety = mode.safety,
                .llvm_bin = opts.llvm_bin,
                .lib_paths = lib_paths.items,
                .extra_libs = libs.items,
            }) catch {
                why = "did not compile (see above)";
                break :compile;
            };
            const r = std.process.run(a, io, .{ .argv = &.{exe} }) catch {
                why = "could not be started";
                break :compile;
            };
            switch (r.term) {
                .exited => |code| if (code != 0) {
                    why = std.fmt.allocPrint(a, "exited with {d}", .{code}) catch "failed";
                },
                else => why = "crashed",
            }
            if (why.len != 0) {
                const output = std.mem.trimEnd(u8, std.mem.concat(a, u8, &.{ r.stdout, r.stderr }) catch "", "\r\n");
                if (output.len != 0) why = std.fmt.allocPrint(a, "{s}:\n      {s}", .{ why, output }) catch why;
            }
        }
        if (why.len == 0) {
            passed += 1;
            if (!opts.quiet) std.debug.print("  \u{2713} {s}\n", .{rel});
        } else {
            failed += 1;
            std.debug.print("  \u{2717} {s} {s}\n", .{ rel, why });
        }
    }

    std.debug.print("\n{d} passed, {d} failed\n", .{ passed, failed });
    if (failed != 0) return error.RunFailed;
}

// Library inspection (import lib vs static archive)

const LibKind = union(enum) {
    /// A static archive (regular COFF object members) — needs the C runtime.
    static,
    /// A static library `fels build` wrote: no C runtime, but its `/DEFAULTLIB` directives
    /// name the libraries its `#extern` functions come from.
    fels_static,
    /// An import library — the value is the DLL its symbols come from.
    import_lib: []const u8,
    /// Not a recognizable COFF `.lib` archive.
    unknown,
};

/// Classify a Windows COFF `.lib`: an import library carries an
/// `__IMPORT_DESCRIPTOR_<dll>` symbol (true for both the short- and long-import
/// forms); a static archive doesn't. Returns the DLL name for an import lib.
fn inspectLib(arena: std.mem.Allocator, bytes: []const u8) LibKind {
    const magic = "!<arch>\n";
    if (bytes.len < magic.len or !std.mem.eql(u8, bytes[0..magic.len], magic)) return .unknown;
    if (std.mem.indexOf(u8, bytes, coff_archive.fels_marker ++ "\x00") != null) return .fels_static;
    const needle = "__IMPORT_DESCRIPTOR_";
    const at = std.mem.indexOf(u8, bytes, needle) orelse return .static;
    var p = at + needle.len;
    const start = p;
    while (p < bytes.len and (std.ascii.isAlphanumeric(bytes[p]) or bytes[p] == '_')) p += 1;
    if (p == start) return .static;
    const dll = std.fmt.allocPrint(arena, "{s}.dll", .{bytes[start..p]}) catch return .static;
    return .{ .import_lib = dll };
}

// Helpers

fn resolveOutput(plan: *BuildPlan, base_dir: []const u8, art: Artifact) BuildError![]const u8 {
    const a = plan.a();
    if (art.out_path) |p| return joinPath(a, base_dir, p) catch return error.OutOfMemory;
    const linux = art.target_os == .linux;
    const ext = switch (art.kind) {
        .executable => if (linux) "" else ".exe",
        .shared_library => if (linux) ".so" else ".dll",
        .static_library => if (linux) ".a" else ".lib",
        .object => ".o",
    };
    const name = std.fmt.allocPrint(a, "{s}{s}", .{ art.name, ext }) catch return error.OutOfMemory;
    // Output directory precedence: per-artifact out_dir, then the workspace
    // out_root, then alongside the build script.
    if (art.out_dir orelse plan.out_root) |dir| {
        const out_dir_abs = joinPath(a, base_dir, dir) catch return error.OutOfMemory;
        return joinPath(a, out_dir_abs, name) catch return error.OutOfMemory;
    }
    return joinPath(a, base_dir, name) catch return error.OutOfMemory;
}

fn joinPath(a: std.mem.Allocator, base: []const u8, rel: []const u8) ![]const u8 {
    if (base.len == 0 or std.mem.eql(u8, base, ".")) return a.dupe(u8, rel);
    return std.fs.path.join(a, &.{ base, rel });
}

fn readSource(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch null;
}

/// What a build mode (`Optimize` in std.build) compiles with. `release_fast` is the only one
/// without the runtime safety checks; `release_safe` is optimized as fully as `release_fast`
/// (it was `-O1`, and no checks came with it either).
const ModeSettings = struct { opt_level: u2, safety: bool };

/// The mode an artifact at `mode` builds in: `--release` and `--release-fast` change `debug`.
fn releaseMode(opts: RunOptions, mode: u2) u2 {
    if (mode != 0) return mode;
    if (opts.release_fast) return 2;
    if (opts.release) return 1;
    return 0;
}

fn modeSettings(mode: u2) ModeSettings {
    return switch (mode) {
        0 => .{ .opt_level = 0, .safety = true }, // debug
        1 => .{ .opt_level = 2, .safety = true }, // release_safe
        2 => .{ .opt_level = 2, .safety = false }, // release_fast
        3 => .{ .opt_level = 3, .safety = true }, // release_small
    };
}

fn optName(opt: u2) []const u8 {
    return switch (opt) {
        0 => "debug",
        1 => "release-safe",
        2 => "release-fast",
        3 => "release-small",
    };
}

/// The declared options, one per line: `-Dname=<int>  help (default: 4)`.
fn printOptions(plan: *BuildPlan) void {
    for (plan.declared.items) |d| {
        var buf: [96]u8 = undefined;
        const usage = switch (d.kind) {
            .bool => std.fmt.bufPrint(&buf, "-D{s}", .{d.name}),
            .int => std.fmt.bufPrint(&buf, "-D{s}=<int>", .{d.name}),
            .string => std.fmt.bufPrint(&buf, "-D{s}=<text>", .{d.name}),
            .choice => std.fmt.bufPrint(&buf, "-D{s}={s}", .{ d.name, d.choices }),
        } catch d.name;
        std.debug.print("  {s: <28} {s}", .{ usage, d.help });
        if (d.default.len != 0) {
            const sep: []const u8 = if (d.help.len != 0) " " else "";
            std.debug.print("{s}(default: {s})", .{ sep, d.default });
        }
        std.debug.print("\n", .{});
    }
}

fn printList(plan: *BuildPlan) void {
    if (plan.workspace_name) |w| std.debug.print("workspace: {s}\n", .{w});
    std.debug.print("artifacts:\n", .{});
    for (plan.artifacts.items, 0..) |art, i| {
        const star: []const u8 = if (plan.default_idx == i) " (default)" else "";
        std.debug.print("  {s: <16} {s: <14} {s}{s}", .{ art.name, @tagName(art.kind), optName(art.opt), star });
        if (art.version) |v| std.debug.print(" v{s}", .{v});
        if (art.install) std.debug.print(" [install]", .{});
        if (art.libs.items.len + art.link_artifacts.items.len != 0) {
            std.debug.print("  links:", .{});
            for (art.libs.items) |l| std.debug.print(" {s}", .{l});
            for (art.link_artifacts.items) |dep| std.debug.print(" {s}", .{plan.artifacts.items[dep].name});
        }
        std.debug.print("\n", .{});
        if (art.description) |d| std.debug.print("    {s}\n", .{d});
    }
    if (plan.steps.items.len != 0) {
        std.debug.print("steps:\n", .{});
        for (plan.steps.items, 0..) |st, i| {
            const detail: []const u8 = switch (st.kind) {
                .run => if (st.target < plan.artifacts.items.len) plan.artifacts.items[st.target].name else "",
                .test_dir => st.dir,
                .custom => st.description,
            };
            const kind: []const u8 = if (st.kind == .custom) "step" else @tagName(st.kind);
            const star: []const u8 = if (plan.default_step == i) " (default)" else "";
            std.debug.print("  {s: <16} {s: <10} {s}{s}\n", .{ st.name, kind, detail, star });
        }
    }
    if (plan.declared.items.len != 0) {
        std.debug.print("options:\n", .{});
        printOptions(plan);
    }
    if (plan.packages.len != 0) {
        std.debug.print("packages:\n", .{});
        pkg.project.printPackages(plan.a(), plan.packages);
    }
}
