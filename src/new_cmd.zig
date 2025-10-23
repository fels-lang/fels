//! `fels new` and `fels init`: start a project from a template.
//!
//! The templates are part of fels.exe. `{{name}}` in a template (its paths too) becomes the
//! package name, `{{year}}` this year and `{{author}}` the author from `git config user.name`.
//! `fels new <name>` makes the folder; `fels init` fills the current one and never writes over
//! a file that is there.

const std = @import("std");

pub const Template = enum {
    app,
    lib,
    cbind,

    pub fn describe(t: Template) []const u8 {
        return switch (t) {
            .app => "a program: src/main.fels with main, a function and a test",
            .lib => "a library others use with `fels add`, with tests and an example",
            .cbind => "Fels bindings to a C library: #extern skeleton, lib/ folder, example",
        };
    }
};

pub const License = enum {
    mit,
    apache,
    none,

    /// The SPDX name, as `#license` in fels.pkg gives it.
    pub fn spdx(l: License) []const u8 {
        return switch (l) {
            .mit => "MIT",
            .apache => "Apache-2.0",
            .none => "",
        };
    }
};

pub const Options = struct {
    /// The project folder.
    dir: []const u8,
    /// The package name, an identifier (`identifier` makes one).
    name: []const u8,
    template: Template = .app,
    license: License = .mit,
    /// Run `git init` when git is there and the folder is not in a repository yet.
    git: bool = true,
    /// `fels init`: the folder may hold files already. They are kept, never written over.
    init: bool = false,
    year: u32,
    author: []const u8,
};

pub const Error = error{
    OutOfMemory,
    WriteFailed,
    /// `fels new` into a folder that has files, or `fels init` where fels.pkg is; the message
    /// is written.
    Exists,
    /// A file could not be written; the message is written.
    CannotWrite,
};

/// What `create` did.
pub const Created = struct {
    /// The files written, as the template names them.
    written: []const []const u8,
    /// The files `fels init` left as they were.
    kept: []const []const u8,
    /// What happened with git: a line to show, or empty.
    git_note: []const u8,
};

const File = struct {
    path: []const u8,
    text: []const u8,
};

/// Write the template's files into `opts.dir`, then set up git. Strings are on `a`.
pub fn create(a: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, opts: Options) Error!Created {
    if (opts.init) {
        const pkg = try std.fs.path.join(a, &.{ opts.dir, "fels.pkg" });
        if (exists(io, pkg)) {
            try out.writeAll("fels init: this folder has a fels.pkg already; it is a Fels project\n");
            return error.Exists;
        }
    } else if (!emptyOrMissing(io, opts.dir)) {
        try out.print("fels new: {s} exists and is not empty\n", .{opts.dir});
        return error.Exists;
    }

    var written: std.ArrayList([]const u8) = .empty;
    var kept: std.ArrayList([]const u8) = .empty;
    for (filesOf(opts.template)) |f| try writeFile(a, io, out, opts, f, &written, &kept);
    if (opts.license != .none) {
        const text = switch (opts.license) {
            .mit => mit_license,
            // A checkout with CRLF line ends embeds them; the project gets LF like its other files.
            .apache => try std.mem.replaceOwned(u8, a, apache_license, "\r\n", "\n"),
            .none => unreachable,
        };
        try writeFile(a, io, out, opts, .{ .path = "LICENSE", .text = text }, &written, &kept);
    }

    return .{
        .written = written.items,
        .kept = kept.items,
        .git_note = if (opts.git) try gitInit(a, io, opts.dir) else "",
    };
}

fn writeFile(
    a: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    opts: Options,
    f: File,
    written: *std.ArrayList([]const u8),
    kept: *std.ArrayList([]const u8),
) Error!void {
    const rel = try fill(a, f.path, opts);
    const path = try std.fs.path.join(a, &.{ opts.dir, rel });
    if (opts.init and exists(io, path)) {
        try kept.append(a, rel);
        return;
    }
    if (std.fs.path.dirname(path)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = try fill(a, f.text, opts) }) catch |err| {
        try out.print("fels: cannot write {s} ({s})\n", .{ path, @errorName(err) });
        return error.CannotWrite;
    };
    try written.append(a, rel);
}

/// `text` with the placeholders filled in. fels.pkg's `{{license_line}}` is the `#license`
/// line, or nothing without a license.
fn fill(a: std.mem.Allocator, text: []const u8, opts: Options) error{OutOfMemory}![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var rest = text;
    while (std.mem.indexOf(u8, rest, "{{")) |i| {
        const end = std.mem.indexOfPos(u8, rest, i, "}}") orelse break;
        try buf.appendSlice(a, rest[0..i]);
        const key = rest[i + 2 .. end];
        if (std.mem.eql(u8, key, "name")) {
            try buf.appendSlice(a, opts.name);
        } else if (std.mem.eql(u8, key, "year")) {
            try buf.print(a, "{d}", .{opts.year});
        } else if (std.mem.eql(u8, key, "author")) {
            try buf.appendSlice(a, opts.author);
        } else if (std.mem.eql(u8, key, "license_line")) {
            if (opts.license != .none) try buf.print(a, "#license \"{s}\";\n", .{opts.license.spdx()});
        } else {
            try buf.appendSlice(a, rest[i .. end + 2]);
        }
        rest = rest[end + 2 ..];
    }
    try buf.appendSlice(a, rest);
    return buf.items;
}

/// `git init` in `dir`, unless git is missing or `dir` is in a repository already.
fn gitInit(a: std.mem.Allocator, io: std.Io, dir: []const u8) error{OutOfMemory}![]const u8 {
    if (runGit(a, io, &.{ "git", "rev-parse", "--is-inside-work-tree" }, dir)) |_|
        return "inside a git repository already, so no new one";
    if (runGit(a, io, &.{ "git", "init", "-q" }, dir)) |_| return "git repository created";
    return "git not found, so no git repository; `git init` makes one";
}

/// Run git; its output when it exits with 0, else null.
fn runGit(a: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8) ?[]const u8 {
    const r = std.process.run(a, io, .{
        .argv = argv,
        .cwd = if (cwd) |d| .{ .path = d } else .inherit,
    }) catch return null;
    return switch (r.term) {
        .exited => |code| if (code == 0) r.stdout else null,
        else => null,
    };
}

/// The author for a LICENSE: `git config user.name`, or "The <name> authors".
pub fn author(a: std.mem.Allocator, io: std.Io, name: []const u8) error{OutOfMemory}![]const u8 {
    if (runGit(a, io, &.{ "git", "config", "user.name" }, null)) |o| {
        const trimmed = std.mem.trim(u8, o, " \r\n");
        if (trimmed.len != 0) return trimmed;
    }
    return std.fmt.allocPrint(a, "The {s} authors", .{name});
}

/// This year, from the clock.
pub fn thisYear(io: std.Io) u32 {
    const secs = std.Io.Clock.real.now(io).toSeconds();
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(secs, 0)) };
    return epoch.getEpochDay().calculateYearDay().year;
}

/// A package name from a folder name: `-`, `.` and spaces become `_`. Null when the result
/// is no identifier (it starts with a digit, or has other characters).
pub fn identifier(a: std.mem.Allocator, raw: []const u8) error{OutOfMemory}!?[]const u8 {
    if (raw.len == 0 or std.ascii.isDigit(raw[0])) return null;
    const name = try a.dupe(u8, raw);
    for (name) |*c| switch (c.*) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
        '-', '.', ' ' => c.* = '_',
        else => return null,
    };
    return name;
}

/// `fels new <name> [options]` and `fels init [options]` on the command line. Everything is
/// written to stderr, like the other commands' output. Returns the exit code.
pub fn cmd(a: std.mem.Allocator, io: std.Io, is_init: bool, args: []const []const u8) u8 {
    const which = if (is_init) "fels init" else "fels new";
    var template: Template = .app;
    var license: License = .mit;
    var git = true;
    var target: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--list")) {
            printTemplates();
            return 0;
        } else if (std.mem.eql(u8, arg, "--app")) {
            template = .app;
        } else if (std.mem.eql(u8, arg, "--lib")) {
            template = .lib;
        } else if (std.mem.eql(u8, arg, "--cbind")) {
            template = .cbind;
        } else if (std.mem.eql(u8, arg, "--no-git")) {
            git = false;
        } else if (std.mem.eql(u8, arg, "--license") and i + 1 < args.len) {
            i += 1;
            license = parseLicense(args[i]) orelse {
                std.debug.print("{s}: the license is MIT, Apache-2.0 or none, not `{s}`\n", .{ which, args[i] });
                return 1;
            };
        } else if (arg.len > 1 and arg[0] == '-') {
            std.debug.print("{s}: unknown option '{s}'\n", .{ which, arg });
            return 1;
        } else if (target == null and !is_init) {
            target = arg;
        } else {
            std.debug.print("{s}: one project at a time; what is `{s}`?\n", .{ which, arg });
            return 1;
        }
    }
    const dir = if (is_init) "." else target orelse {
        std.debug.print("usage: fels new <name> [--app | --lib | --cbind] [--license MIT|Apache-2.0|none] [--no-git]\n" ++
            "       fels new --list   shows the templates\n", .{});
        return 1;
    };

    // The package is named after the folder.
    const folder = if (is_init)
        std.fs.path.basename(std.process.currentPathAlloc(io, a) catch ".")
    else
        std.fs.path.basename(std.mem.trimEnd(u8, dir, "/\\"));
    const name = (identifier(a, folder) catch return 1) orelse {
        std.debug.print("{s}: `{s}` cannot be a package name: it starts with a letter or `_` and has letters, digits, `_` and `-`\n", .{ which, folder });
        return 1;
    };
    if (!std.mem.eql(u8, name, folder))
        std.debug.print("note: `{s}` is not a Fels name, so the package is called `{s}`\n", .{ folder, name });

    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    const created = create(a, io, &w.interface, .{
        .dir = dir,
        .name = name,
        .template = template,
        .license = license,
        .git = git,
        .init = is_init,
        .year = thisYear(io),
        .author = author(a, io, name) catch return 1,
    }) catch {
        w.interface.flush() catch {};
        return 1;
    };
    report(&w.interface, if (is_init) null else dir, name, template, created) catch {};
    w.interface.flush() catch {};
    return 0;
}

/// What was made, and what to do next.
fn report(out: *std.Io.Writer, dir: ?[]const u8, name: []const u8, template: Template, created: Created) std.Io.Writer.Error!void {
    try out.print("created the {s} {s}\n", .{ @tagName(template), name });
    for (created.written) |f| try out.print("  {s}\n", .{f});
    for (created.kept) |f| try out.print("  {s} (kept as it was)\n", .{f});
    if (created.git_note.len != 0) try out.print("{s}\n", .{created.git_note});
    try out.writeAll("\nnext:\n");
    if (dir) |d| try out.print("  cd {s}\n", .{d});
    switch (template) {
        .app => try out.writeAll(
            \\  fels build run    build and run it
            \\  fels test         run its tests
            \\
        ),
        .lib => try out.writeAll(
            \\  fels test         run its tests
            \\  fels build run    build and run examples/demo.fels
            \\  to share it, push it to a git host and tag a version (git tag v0.1.0)
            \\
        ),
        .cbind => try out.print(
            \\  put {s}.lib (and {s}.dll) into lib/, and bind its functions in src/{s}.fels
            \\  fels test         run its tests
            \\  fels build run    build and run examples/demo.fels
            \\
        , .{ name, name, name }),
    }
}

fn printTemplates() void {
    std.debug.print("templates (fels new <name> --<template>):\n", .{});
    for (std.enums.values(Template)) |t|
        std.debug.print("  --{s: <7} {s}{s}\n", .{ @tagName(t), t.describe(), if (t == .app) " (the default)" else "" });
}

fn parseLicense(text: []const u8) ?License {
    if (std.ascii.eqlIgnoreCase(text, "mit")) return .mit;
    if (std.ascii.eqlIgnoreCase(text, "apache-2.0") or std.ascii.eqlIgnoreCase(text, "apache")) return .apache;
    if (std.ascii.eqlIgnoreCase(text, "none")) return .none;
    return null;
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn emptyOrMissing(io: std.Io, dir: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return !exists(io, dir);
    defer d.close(io);
    var it = d.iterate();
    const first = it.next(io) catch return false;
    return first == null;
}

fn filesOf(t: Template) []const File {
    return switch (t) {
        .app => &app_files,
        .lib => &lib_files,
        .cbind => &cbind_files,
    };
}

// The templates

const gitignore =
    \\bin/
    \\dist/
    \\.fels-cache/
    \\
;

const app_files = [_]File{
    .{ .path = "fels.pkg", .text =
    \\#package {{name}} "0.1.0";
    \\{{license_line}}
    },
    .{ .path = "build.fels", .text =
    \\#import std.build.{ Build };
    \\
    \\build :: fn(b: Build) {
    \\    b.out_root("bin");
    \\    app := b.executable("{{name}}", "src/main.fels");
    \\    b.run_step("run", app);
    \\    b.default(app);
    \\}
    \\
    },
    .{ .path = "src/main.fels", .text =
    \\#import std.io;
    \\
    \\// The sum of the numbers from 1 to `n`.
    \\sum_to :: fn(n: i32) -> i32 {
    \\    total := 0;
    \\    i := 1;
    \\    while i <= n {
    \\        total += i;
    \\        i += 1;
    \\    }
    \\    return total;
    \\}
    \\
    \\main :: fn() -> i32 {
    \\    io::println("Hello from {{name}}!");
    \\    io::print("1 + 2 + ... + 10 = ");
    \\    io::print_i64(sum_to(10) as i64);
    \\    io::println("");
    \\    return 0;
    \\}
    \\
    \\#test
    \\sum_to_adds_the_numbers :: fn(t: *Test) {
    \\    t.eq(sum_to(0), 0);
    \\    t.eq(sum_to(1), 1);
    \\    t.eq(sum_to(10), 55);
    \\}
    \\
    },
    .{ .path = "README.md", .text =
    \\# {{name}}
    \\
    \\A program written in [Fels](https://github.com/fels-lang/fels).
    \\
    \\```
    \\fels build run        build it and run it
    \\fels test             run the tests
    \\fels build --release  build it optimized, into bin/
    \\```
    \\
    },
    .{ .path = ".gitignore", .text = gitignore },
};

const lib_files = [_]File{
    .{ .path = "fels.pkg", .text =
    \\#package {{name}} "0.1.0";
    \\{{license_line}}#description "What {{name}} does, in one line.";
    \\
    },
    .{ .path = "build.fels", .text =
    \\#import std.build.{ Build };
    \\
    \\// The library is its sources in src/: others use them with `fels add`. This builds the
    \\// example, which imports the library as they do.
    \\build :: fn(b: Build) {
    \\    b.out_root("bin");
    \\    demo := b.executable("demo", "examples/demo.fels");
    \\    b.run_step("run", demo);
    \\    b.default(demo);
    \\}
    \\
    },
    .{ .path = "src/{{name}}.fels", .text =
    \\// {{name}}: what the library offers. Everything marked `pub` is for its users.
    \\
    \\// `x`, kept between `lo` and `hi`.
    \\pub clamp :: fn(x: i32, lo: i32, hi: i32) -> i32 {
    \\    if x < lo { return lo; }
    \\    if x > hi { return hi; }
    \\    return x;
    \\}
    \\
    \\// The larger of `a` and `b`.
    \\pub max :: fn(a: i32, b: i32) -> i32 {
    \\    if a > b { return a; }
    \\    return b;
    \\}
    \\
    \\#test
    \\clamp_keeps_values_in_range :: fn(t: *Test) {
    \\    t.eq(clamp(5, 0, 10), 5);
    \\    t.eq(clamp(-5, 0, 10), 0);
    \\    t.eq(clamp(50, 0, 10), 10);
    \\}
    \\
    \\#test
    \\max_takes_the_larger :: fn(t: *Test) {
    \\    t.eq(max(3, 7), 7);
    \\    t.eq(max(7, 3), 7);
    \\}
    \\
    },
    .{ .path = "examples/demo.fels", .text =
    \\#import std.io;
    \\#import {{name}};
    \\
    \\main :: fn() -> i32 {
    \\    io::print("clamp(42, 0, 10) = ");
    \\    io::print_i64({{name}}::clamp(42, 0, 10) as i64);
    \\    io::println("");
    \\    return 0;
    \\}
    \\
    },
    .{ .path = "README.md", .text =
    \\# {{name}}
    \\
    \\A library for [Fels](https://github.com/fels-lang/fels).
    \\
    \\## Use it
    \\
    \\```
    \\fels add {{name}} github.com/<you>/{{name}}
    \\```
    \\
    \\```fels
    \\#import {{name}};
    \\
    \\x := {{name}}::clamp(15, 0, 10);
    \\```
    \\
    \\## Work on it
    \\
    \\```
    \\fels test        run the tests
    \\fels build run   build and run examples/demo.fels
    \\```
    \\
    \\To publish a version, push the repository and tag it: `git tag v0.1.0`, `git push --tags`.
    \\
    },
    .{ .path = ".gitignore", .text = gitignore },
};

const cbind_files = [_]File{
    .{ .path = "fels.pkg", .text =
    \\#package {{name}} "0.1.0";
    \\{{license_line}}#description "Fels bindings to the C library {{name}}.";
    \\
    },
    .{ .path = "build.fels", .text =
    \\#import std.build.{ Build };
    \\
    \\build :: fn(b: Build) {
    \\    // What the users of this package link with: the folder with the C library, and its DLL,
    \\    // copied next to their programs. Uncomment the lines once lib/ holds your library.
    \\    b.provide_lib_path("lib");
    \\    // b.provide_runtime_file("lib/{{name}}.dll");
    \\
    \\    b.out_root("bin");
    \\    demo := b.executable("demo", "examples/demo.fels");
    \\    demo.lib_path("lib");
    \\    // demo.runtime_file("lib/{{name}}.dll");
    \\    b.run_step("run", demo);
    \\    b.default(demo);
    \\}
    \\
    },
    .{ .path = "src/{{name}}.fels", .text =
    \\// {{name}}: Fels bindings to a C library.
    \\//
    \\// A binding names the library and the C function, and gives its Fels type:
    \\//
    \\//     #extern("{{name}}", "{{name}}_init")
    \\//     pub init :: fn(flags: u32) -> i32;
    \\//
    \\// That links {{name}}.lib from lib/ (see lib/README.md). The two bindings below call
    \\// kernel32, which every Windows program links, so the package builds and its tests run
    \\// before your library is there. Replace them with your library's functions.
    \\
    \\#extern("kernel32", "GetTickCount64")
    \\pub ticks_ms :: fn() -> u64;
    \\
    \\#extern("kernel32", "GetCurrentProcessId")
    \\pub process_id :: fn() -> u32;
    \\
    \\// A Fels function over a binding: the place for nicer types and checks.
    \\pub seconds_since_boot :: fn() -> u64 {
    \\    return ticks_ms() / 1000u64;
    \\}
    \\
    \\#test
    \\ticks_go_forward :: fn(t: *Test) {
    \\    a := ticks_ms();
    \\    b := ticks_ms();
    \\    t.expect(b >= a);
    \\}
    \\
    \\#test
    \\has_a_process_id :: fn(t: *Test) {
    \\    t.expect(process_id() != 0u32);
    \\}
    \\
    },
    .{ .path = "examples/demo.fels", .text =
    \\#import std.io;
    \\#import {{name}};
    \\
    \\main :: fn() -> i32 {
    \\    io::print("seconds since boot: ");
    \\    io::print_u64({{name}}::seconds_since_boot());
    \\    io::println("");
    \\    return 0;
    \\}
    \\
    },
    .{ .path = "lib/README.md", .text =
    \\# lib
    \\
    \\Put the C library here: `{{name}}.lib` to link with, and `{{name}}.dll` when it is a DLL.
    \\Then bind its functions in `src/{{name}}.fels`:
    \\
    \\```fels
    \\#extern("{{name}}", "{{name}}_init")
    \\pub init :: fn(flags: u32) -> i32;
    \\```
    \\
    \\and in `build.fels` uncomment the lines for the DLL. `fels bindgen {{name}}.h --lib {{name}}`
    \\writes the bindings of a whole header for you.
    \\
    },
    .{ .path = "README.md", .text =
    \\# {{name}}
    \\
    \\[Fels](https://github.com/fels-lang/fels) bindings to the C library {{name}}.
    \\
    \\## Use it
    \\
    \\```
    \\fels add {{name}} github.com/<you>/{{name}}
    \\```
    \\
    \\```fels
    \\#import {{name}};
    \\```
    \\
    \\## Work on it
    \\
    \\```
    \\fels test        run the tests (they call the C library)
    \\fels build run   build and run examples/demo.fels
    \\```
    \\
    },
    .{ .path = ".gitignore", .text = gitignore },
};

const mit_license =
    \\MIT License
    \\
    \\Copyright (c) {{year}} {{author}}
    \\
    \\Permission is hereby granted, free of charge, to any person obtaining a copy
    \\of this software and associated documentation files (the "Software"), to deal
    \\in the Software without restriction, including without limitation the rights
    \\to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    \\copies of the Software, and to permit persons to whom the Software is
    \\furnished to do so, subject to the following conditions:
    \\
    \\The above copyright notice and this permission notice shall be included in all
    \\copies or substantial portions of the Software.
    \\
    \\THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    \\IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    \\FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    \\AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    \\LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    \\OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    \\SOFTWARE.
    \\
;

/// The Apache License 2.0, the text of LICENSE-APACHE-2.0.txt.
const apache_license = @embedFile("license_apache");
