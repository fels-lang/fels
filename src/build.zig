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
    /// The files the build copied next to the output (runtime files, DLLs), which
    /// `fels build install` copies along.
    copied: std.ArrayList([]const u8) = .empty,
    /// The constants of the generated `build_options` module (`define`, `define_int`, ...),
    /// each as its Fels source text.
    defines: std.ArrayList(Define) = .empty,
    /// Named import roots (`add_module`), relative to build.fels.
    modules: std.ArrayList(pipeline.ModuleRoot) = .empty,
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
    /// `.test_dir`: the folder of the tests.
    dir: []const u8 = "",
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
    /// Where `fels build install` copies to (`b.install_prefix`), relative to build.fels.
    install_prefix: ?[]const u8 = null,
    install_items: std.ArrayList(InstallItem) = .empty,
    oom: bool = false,

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
        .default_step => {
            const step: usize = @intCast(argInt(args, 0));
            if (step < plan.steps.items.len) plan.default_step = step;
            return .void;
        },
        .test_dir => {
            if (plan.addStep(argStr(args, 0), .test_dir, "")) |step| step.dir = plan.dupe(argStr(args, 1));
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

/// The VM capabilities of each package's folder, from what fels.pkg granted it.
fn packageCaps(plan: *BuildPlan) BuildError![]const ir.FolderCaps {
    const a = plan.a();
    var out: std.ArrayList(ir.FolderCaps) = .empty;
    for (plan.packages) |p| {
        var libs: std.ArrayList([]const u8) = .empty;
        var any = false;
        for (p.caps) |c| {
            if (!std.mem.eql(u8, c.name, "ffi")) continue;
            if (c.args.len == 0) any = true;
            libs.appendSlice(a, c.args) catch return error.OutOfMemory;
        }
        const ffi: @import("vm/engine.zig").Caps.Ffi = if (any) .all else if (libs.items.len != 0) .{ .libs = libs.items } else .none;
        out.append(a, .{ .dir = p.dir, .caps = .{ .ffi = ffi } }) catch return error.OutOfMemory;
    }
    return out.items;
}

/// Write the artifact's `build_options` module and return the module roots its compile
/// uses: the `add_module` ones, the packages and `build_options`.
fn moduleRootsFor(io: std.Io, plan: *BuildPlan, base_dir: []const u8, art: Artifact) BuildError![]const pipeline.ModuleRoot {
    const a = plan.a();
    var roots: std.ArrayList(pipeline.ModuleRoot) = .empty;
    for (art.modules.items) |m| {
        const dir = if (std.fs.path.isAbsolute(m.dir)) m.dir else joinPath(a, base_dir, m.dir) catch return error.OutOfMemory;
        roots.append(a, .{ .name = m.name, .dir = dir }) catch return error.OutOfMemory;
    }
    // After the `add_module` ones, so a build can point a package name somewhere else.
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
    /// Override every artifact to a release optimization level.
    release: bool = false,
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
};

/// Run `build_path` (a build.fels) and execute the resulting plan.
pub fn run(gpa: std.mem.Allocator, io: std.Io, build_path: []const u8, opts: RunOptions) BuildError!void {
    var plan = try loadPlan(gpa, io, build_path, opts.options);
    defer plan.deinit();

    // The packages of fels.pkg next to build.fels: import roots for every artifact, and the
    // capabilities of their compile-time code.
    const base = std.fs.path.dirname(build_path) orelse ".";
    const loaded = pkg.project.load(plan.a(), io, base, opts.environ, .{ .offline = opts.offline, .frozen = opts.frozen }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.PackageError => error.PackageError,
    };
    if (loaded) |r| plan.packages = r.packages;
    ir.package_caps = try packageCaps(&plan);
    defer ir.package_caps = &.{};

    if (opts.list) {
        printList(&plan);
        return;
    }

    // 3. Execute the plan.
    const base_dir = std.fs.path.dirname(build_path) orelse ".";
    try executePlan(gpa, io, &plan, base_dir, opts);
}

/// Run `build_path` (a build.fels) with the `-D` `options` and return the plan it records,
/// without building anything. The caller owns the plan (`deinit`).
pub fn loadPlan(gpa: std.mem.Allocator, io: std.Io, build_path: []const u8, options: []const []const u8) BuildError!BuildPlan {
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
        return error.CompileFailed;
    }

    // 2. Run `build(b)` on the comptime VM, recording into `plan`.
    const host = vm_engine.BuildHost{ .ctx = &plan, .call = hostCall };
    ir.runBuildHook(gpa, fe, host) catch {
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
    if (plan.artifacts.items.len == 0) return error.NoArtifacts;
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
    if (step.kind == .test_dir) try runTestDir(gpa, io, plan, base_dir, step.dir, opts);
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
            if (!opts.quiet) std.debug.print("  \u{2713} {s}\n", .{path});
        },
        .remove => |rel| {
            const path = joinPath(a, base_dir, rel) catch return error.OutOfMemory;
            std.Io.Dir.cwd().deleteTree(io, path) catch {
                std.debug.print("fels build: cannot remove {s}\n", .{path});
                return error.StepFailed;
            };
            if (!opts.quiet) std.debug.print("  removed {s}\n", .{path});
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

    if (!opts.quiet) std.debug.print("  running {s}\n", .{program});
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
            std.debug.print("  {s} exited with code {d}\n", .{ std.fs.path.basename(program), code });
            if (!cmd.is_run) return error.StepFailed;
        },
        else => {
            std.debug.print("  {s} did not exit normally\n", .{std.fs.path.basename(program)});
            return if (cmd.is_run) error.RunFailed else error.StepFailed;
        },
    }
}

/// A post-build summary of every artifact (kind, output path, opt level).
fn printSummary(plan: *BuildPlan, base_dir: []const u8) void {
    std.debug.print("\n── build summary", .{});
    if (plan.workspace_name) |w| std.debug.print(" · {s}", .{w});
    std.debug.print(" ──\n", .{});
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
    for (art.lib_paths.items) |lp| {
        const abs = joinPath(a, base_dir, lp) catch return error.OutOfMemory;
        lib_paths.append(a, abs) catch return error.OutOfMemory;
    }
    lib_paths.append(a, base_dir) catch return error.OutOfMemory;

    const opt_level: u2 = if (opts.release and art.opt == 0) 2 else art.opt;
    const is_lib = art.kind == .shared_library;
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

    // The libraries to link: the named ones, then the library artifacts of this build
    // (found in their output directory, and inspected like any other library below).
    var linked: std.ArrayList([]const u8) = .empty;
    linked.appendSlice(a, art.libs.items) catch return error.OutOfMemory;
    for (art.link_artifacts.items) |dep| {
        const dep_out = try resolveOutput(plan, base_dir, plan.artifacts.items[dep]);
        const dep_dir = std.fs.path.dirname(dep_out) orelse ".";
        lib_paths.append(a, dep_dir) catch return error.OutOfMemory;
        search_dirs.append(a, dep_dir) catch return error.OutOfMemory;
        linked.append(a, std.fs.path.stem(dep_out)) catch return error.OutOfMemory;
    }

    var need_libc = art.link_mode == 1 or opts.link_libc or art.link_libc;
    var has_fels_lib = false;
    var auto_dlls: std.ArrayList([]const u8) = .empty;
    for (linked.items) |lib_name| {
        for (search_dirs.items) |dir| {
            const lib_file = std.fmt.allocPrint(a, "{s}/{s}.lib", .{ dir, lib_name }) catch continue;
            const data = readSource(gpa, io, lib_file) orelse continue;
            defer gpa.free(data);
            switch (inspectLib(a, data)) {
                .static => need_libc = true,
                .fels_static => has_fels_lib = true,
                .import_lib => |dll| if (dll.len != 0) {
                    // `static_link()` asserts intent: warn if the resolved lib is
                    // actually an import library (you'll get a dynamic link).
                    if (art.link_mode == 1)
                        std.debug.print("fels build: warning: '{s}' requested static linking, but '{s}/{s}.lib' is an import library — the link will be DYNAMIC. Point lib_path at the static archive.\n", .{ lib_name, dir, lib_name });
                    auto_dlls.append(a, joinPath(a, dir, dll) catch continue) catch {};
                    if (!opts.quiet) std.debug.print("  {s} → dynamic ({s})\n", .{ lib_name, dll });
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
    if (need_libc and builtin.os.tag == .windows) {
        libs.append(a, "ucrt") catch return error.OutOfMemory;
        libs.append(a, "vcruntime") catch return error.OutOfMemory;
    }

    // When a static C library is involved, honor ITS own `/DEFAULTLIB` directives
    // by default — so its system deps (opengl32, gdi32, …) flow in automatically,
    // C3-style — unless the artifact opted out with `no_default_libs()`.
    const honor_defaultlibs = (need_libc or has_fels_lib) and !art.no_default_libs;

    const src = readSource(gpa, io, root_path);
    defer if (src) |s| gpa.free(s);

    if (!opts.quiet) std.debug.print("  building {s} ({s})\n", .{ art.name, root_path });

    pipeline.module_roots = try moduleRootsFor(io, plan, base_dir, art);
    defer pipeline.module_roots = &.{};

    driver.compileFileWithLlvm(gpa, io, .{
        .file_name = root_path,
        .source = src orelse "",
        .obj_path = obj_path,
        .exe_path = if (stop_at_obj) null else out_path,
        .dll = is_lib,
        .opt_level = opt_level,
        .llvm_bin = opts.llvm_bin,
        .lib_paths = lib_paths.items,
        .extra_libs = libs.items,
        .subsystem = if (art.subsystem == 1) .windows else .console,
        .entry = art.entry,
        .stack_reserve = art.stack,
        .link_flags = art.link_flags.items,
        .honor_defaultlibs = honor_defaultlibs,
        .link_libc = need_libc,
        .library_object = art.kind == .static_library,
    }) catch |err| {
        std.debug.print("fels build: failed to build '{s}': {s}\n", .{ art.name, @errorName(err) });
        return error.CompileFailed;
    };
    if (art.kind == .static_library) try writeStaticLibrary(gpa, io, obj_path, out_path);

    if (!opts.quiet) std.debug.print("  \u{2713} {s}\n", .{out_path});

    // Copy runtime dependencies next to the output — both the explicit
    // `runtime_file`s and the DLLs auto-detected from import libraries — so a
    // dynamically-linked program runs without manually shipping its DLLs.
    const out_dir = std.fs.path.dirname(out_path) orelse ".";
    var copy_srcs: std.ArrayList([]const u8) = .empty;
    for (art.runtime_files.items) |rf| copy_srcs.append(a, joinPath(a, base_dir, rf) catch continue) catch {};
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
        if (!opts.quiet) std.debug.print("  \u{2713} {s}\n", .{dst});
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
    if (!opts.quiet) std.debug.print("installed {d} file(s) to {s}\n", .{ count, prefix });
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
    if (!opts.quiet) std.debug.print("  \u{2713} {s}\n", .{dest});
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

/// Run a `test_dir` step: compile + run every `*.fels` file directly under `dir`
/// as a standalone program. A test passes when it exits 0. Reports each result
/// and a pass/fail tally; fails the step if any test fails.
fn runTestDir(gpa: std.mem.Allocator, io: std.Io, plan: *BuildPlan, base_dir: []const u8, dir_rel: []const u8, opts: RunOptions) BuildError!void {
    const a = plan.a();
    const dir_abs = joinPath(a, base_dir, dir_rel) catch return error.OutOfMemory;

    var dir = std.Io.Dir.cwd().openDir(io, dir_abs, .{ .iterate = true }) catch {
        std.debug.print("fels build: cannot open test directory '{s}'\n", .{dir_abs});
        return error.RunFailed;
    };
    defer dir.close(io);
    std.Io.Dir.cwd().createDirPath(io, ".zig-cache/felstest") catch {};

    if (!opts.quiet) std.debug.print("running tests in {s}/\n", .{dir_abs});
    var passed: u32 = 0;
    var failed: u32 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!pipeline.isSourceFile(entry.name)) continue;
        // `entry.name` is only valid until the next iteration — copy it.
        const name = a.dupe(u8, entry.name) catch continue;
        const src_path = joinPath(a, dir_abs, name) catch continue;
        const exe = std.fmt.allocPrint(a, ".zig-cache/felstest/{s}.exe", .{name}) catch continue;
        const obj = std.fmt.allocPrint(a, "{s}.o", .{exe}) catch continue;
        const src = readSource(gpa, io, src_path) orelse continue;
        defer gpa.free(src);

        const ok = blk: {
            driver.compileFileWithLlvm(gpa, io, .{
                .file_name = src_path,
                .source = src,
                .obj_path = obj,
                .exe_path = exe,
                .opt_level = 0,
                .llvm_bin = opts.llvm_bin,
                .lib_paths = opts.lib_paths,
            }) catch break :blk false;
            var child = std.process.spawn(io, .{
                .argv = &.{exe},
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            }) catch break :blk false;
            break :blk switch (child.wait(io) catch break :blk false) {
                .exited => |code| code == 0,
                else => false,
            };
        };
        if (ok) {
            passed += 1;
            if (!opts.quiet) std.debug.print("  \u{2713} {s}\n", .{name});
        } else {
            failed += 1;
            std.debug.print("  \u{2717} {s}\n", .{name});
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
    const ext = switch (art.kind) {
        .executable => ".exe",
        .shared_library => ".dll",
        .static_library => ".lib",
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
