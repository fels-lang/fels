/// Windows link step.
///
/// To link manually after emitObject("output.o"):
///   lld-link output.o /OUT:output.exe /SUBSYSTEM:CONSOLE /ENTRY:mainCRTStartup /NODEFAULTLIB kernel32.lib
const std = @import("std");
const builtin = @import("builtin");

// In-process LLD via k2lld.dll (built with `-Din-process-lld`). Loaded
// dynamically, so when the DLL is absent we transparently fall back to spawning
// lld-link.exe. The DLL exports a single C entry point; loading it lazily avoids
// any build-time dependency.
const win = struct {
    extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
};

const LldLinkFn = *const fn (argc: c_int, argv: [*]const [*:0]const u8) callconv(.c) c_int;

// The K2-written linker (k2lnk.dll), exporting `k2_link(in_obj, out_exe) -> int`.
const K2LinkFn = *const fn (in_path: [*:0]const u8, out_path: [*:0]const u8) callconv(.c) c_int;

/// k2lnk currently links a single COFF object whose only imports are kernel32,
/// into an executable. Anything else (DLL output, multiple objects, non-kernel32
/// import libs) falls back to LLD.
fn k2lnkEligible(opts: WindowsLinkOptions) bool {
    if (opts.dll) return false;
    if (opts.obj_files.len != 1) return false;
    for (opts.libs) |lib| {
        if (!std.mem.eql(u8, lib, "kernel32")) return false;
    }
    // k2lnk writes a fixed PE (console subsystem, `mainCRTStartup` entry, default
    // stack, no extra flags). Anything that overrides those must use LLD.
    if (opts.subsystem != .console) return false;
    if (opts.entry != null) return false;
    if (opts.stack_reserve != 0) return false;
    if (opts.extra_flags.len != 0) return false;
    return true;
}

/// Try the K2-written linker (k2lnk.dll) — the self-hosted fast path. Returns
/// null when unavailable/ineligible (use LLD), true on success, false on a
/// reported link failure (also falls back to LLD).
fn tryK2lnk(allocator: std.mem.Allocator, opts: WindowsLinkOptions) ?bool {
    if (builtin.os.tag != .windows) return null;
    if (!k2lnkEligible(opts)) return null;
    const module = win.LoadLibraryA("k2lnk.dll") orelse return null;
    const proc = win.GetProcAddress(module, "k2_link") orelse return null;
    const link_fn: K2LinkFn = @ptrCast(proc);
    const obj_z = allocator.dupeZ(u8, opts.obj_files[0]) catch return false;
    defer allocator.free(obj_z);
    const out_z = allocator.dupeZ(u8, opts.output) catch return false;
    defer allocator.free(out_z);
    return link_fn(obj_z.ptr, out_z.ptr) == 0;
}

/// k2lnk's output layout assumes a single `.text`/`.rdata`/`.data` section each.
/// An object with a duplicate-named section — e.g. a separate float-constant-pool
/// `.rdata` that x64 codegen emits — would be mislinked, so treat it as ineligible
/// and fall back to LLD. Parses the COFF section table (object files have no
/// optional header) and rejects any of those names appearing more than once.
fn coffSafeForK2lnk(obj_bytes: []const u8) bool {
    if (obj_bytes.len < 20) return false;
    const num_sections = std.mem.readInt(u16, obj_bytes[2..4], .little);
    const opt_hdr = std.mem.readInt(u16, obj_bytes[16..18], .little);
    const sec_start: usize = 20 + @as(usize, opt_hdr);
    var n_text: u32 = 0;
    var n_rdata: u32 = 0;
    var n_data: u32 = 0;
    var i: usize = 0;
    while (i < num_sections) : (i += 1) {
        const off = sec_start + i * 40;
        if (off + 8 > obj_bytes.len) return false;
        const name = obj_bytes[off..][0..8];
        if (std.mem.startsWith(u8, name, ".rdata")) {
            n_rdata += 1;
        } else if (std.mem.startsWith(u8, name, ".text")) {
            n_text += 1;
        } else if (std.mem.startsWith(u8, name, ".data")) {
            n_data += 1;
        }
    }
    return n_text <= 1 and n_rdata <= 1 and n_data <= 1;
}

// In-memory variant: k2lnk reads the object bytes directly — no .obj on disk.
const K2LinkMemFn = *const fn (obj_ptr: [*]const u8, obj_len: usize, out_path: [*:0]const u8) callconv(.c) c_int;

fn tryK2lnkMem(allocator: std.mem.Allocator, obj_bytes: []const u8, opts: WindowsLinkOptions) ?bool {
    if (builtin.os.tag != .windows) return null;
    if (!k2lnkEligible(opts)) return null;
    if (!coffSafeForK2lnk(obj_bytes)) return null;
    const module = win.LoadLibraryA("k2lnk.dll") orelse return null;
    const proc = win.GetProcAddress(module, "k2_link_mem") orelse return null;
    const link_fn: K2LinkMemFn = @ptrCast(proc);
    const out_z = allocator.dupeZ(u8, opts.output) catch return false;
    defer allocator.free(out_z);
    return link_fn(obj_bytes.ptr, obj_bytes.len, out_z.ptr) == 0;
}

/// Try the in-process linker. Returns null if k2lld.dll is unavailable (caller
/// should fall back to spawning), true on a successful link, false on failure.
fn tryInProcess(allocator: std.mem.Allocator, args: []const []const u8) ?bool {
    if (builtin.os.tag != .windows) return null;
    const module = win.LoadLibraryA("k2lld.dll") orelse return null;
    const proc = win.GetProcAddress(module, "k2_lld_link_coff") orelse return null;
    const link_fn: LldLinkFn = @ptrCast(proc);

    var argv: std.ArrayList([*:0]const u8) = .empty;
    defer {
        for (argv.items[1..]) |a| allocator.free(std.mem.span(a));
        argv.deinit(allocator);
    }
    // argv[0] is the linker name (diagnostics only); the rest are the real args,
    // skipping `args[0]` which is the lld-link.exe path used for spawning.
    argv.append(allocator, "lld-link") catch return null;
    for (args[1..]) |a| {
        const z = allocator.dupeZ(u8, a) catch return false;
        argv.append(allocator, z.ptr) catch return false;
    }
    return link_fn(@intCast(argv.items.len), argv.items.ptr) == 0;
}

pub const LinkError = error{
    OutOfMemory,
    SpawnFailed,
    WaitFailed,
    ProcessTerminated,
    ExitCodeFailure,
};

/// PE subsystem: a console app gets a terminal window, a `windows` (GUI) app
/// doesn't — what you want for a game/windowed program (raylib, etc.).
pub const Subsystem = enum { console, windows };

pub const WindowsLinkOptions = struct {
    /// Directory containing lld-link.exe (e.g. <llvm>/bin).
    llvm_bin: []const u8,
    /// Object files to link.
    obj_files: []const []const u8,
    /// Output executable path.
    output: []const u8,
    /// Extra /LIBPATH: directories for kernel32.lib etc.
    lib_paths: []const []const u8 = &.{},
    /// Import library names (without the `.lib` extension) to link against,
    /// e.g. `&.{"raylib"}` becomes `raylib.lib` on the link command line.
    /// Resolved via `lib_paths` and the linker's default search paths.
    libs: []const []const u8 = &.{},
    /// Produce a DLL (shared library) instead of an executable. Uses `/DLL`
    /// with `/NOENTRY` (no CRT entry); `#export`ed functions are exported via
    /// their dllexport directives. This is how `k2lnk.dll` is built.
    dll: bool = false,
    /// PE subsystem for executables (console window or not).
    subsystem: Subsystem = .console,
    /// Override the entry symbol (default: `mainCRTStartup`).
    entry: ?[]const u8 = null,
    /// Reserve this many bytes of stack (`/STACK:`); 0 = the default.
    stack_reserve: u64 = 0,
    /// Raw flags passed verbatim to the linker — an escape hatch for anything
    /// the structured options don't cover.
    extra_flags: []const []const u8 = &.{},
};

/// Build the lld-link command line as a slice of argument strings (caller frees).
pub fn buildArgs(allocator: std.mem.Allocator, opts: WindowsLinkOptions) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(allocator);

    try args.append(allocator, try std.fmt.allocPrint(allocator, "{s}/lld-link.exe", .{opts.llvm_bin}));
    for (opts.obj_files) |obj| try args.append(allocator, try allocator.dupe(u8, obj));
    try args.append(allocator, try std.fmt.allocPrint(allocator, "/OUT:{s}", .{opts.output}));
    if (opts.dll) {
        // Shared library: no CRT entry point — `/NOENTRY` makes it a pure
        // code+exports container; exports come from dllexport directives.
        try args.append(allocator, try allocator.dupe(u8, "/DLL"));
        try args.append(allocator, try allocator.dupe(u8, "/NOENTRY"));
    } else {
        const sub = switch (opts.subsystem) {
            .console => "CONSOLE",
            .windows => "WINDOWS",
        };
        try args.append(allocator, try std.fmt.allocPrint(allocator, "/SUBSYSTEM:{s}", .{sub}));
        try args.append(allocator, try std.fmt.allocPrint(allocator, "/ENTRY:{s}", .{opts.entry orelse "mainCRTStartup"}));
        if (opts.stack_reserve != 0)
            try args.append(allocator, try std.fmt.allocPrint(allocator, "/STACK:{d}", .{opts.stack_reserve}));
    }
    try args.append(allocator, try allocator.dupe(u8, "/NODEFAULTLIB"));
    try args.append(allocator, try allocator.dupe(u8, "kernel32.lib"));
    for (opts.lib_paths) |lp|
        try args.append(allocator, try std.fmt.allocPrint(allocator, "/LIBPATH:{s}", .{lp}));
    for (opts.libs) |lib|
        try args.append(allocator, try std.fmt.allocPrint(allocator, "{s}.lib", .{lib}));
    for (opts.extra_flags) |f|
        try args.append(allocator, try allocator.dupe(u8, f));

    return args.toOwnedSlice(allocator);
}

/// Print the link command to stderr for manual execution.
pub fn printCommand(allocator: std.mem.Allocator, opts: WindowsLinkOptions) void {
    const args = buildArgs(allocator, opts) catch return;
    defer {
        for (args) |a| allocator.free(@constCast(a));
        allocator.free(args);
    }
    std.debug.print("Link command:\n  ", .{});
    for (args) |a| std.debug.print("{s} ", .{a});
    std.debug.print("\n", .{});
}

/// The LLD path: in-process (k2lld.dll) if available, else spawn lld-link.exe.
/// Reads the object(s) from disk (lld needs files).
fn linkWithLld(allocator: std.mem.Allocator, io: std.Io, opts: WindowsLinkOptions) LinkError!void {
    const args = buildArgs(allocator, opts) catch return error.OutOfMemory;
    defer {
        for (args) |a| allocator.free(@constCast(a));
        allocator.free(args);
    }

    if (tryInProcess(allocator, args)) |ok| {
        return if (ok) {} else error.ExitCodeFailure;
    }

    var child = std.process.spawn(io, .{
        .argv = args,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return error.SpawnFailed;

    const term = child.wait(io) catch return error.WaitFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.ExitCodeFailure,
        .signal, .stopped, .unknown => return error.ProcessTerminated,
    }
}

/// A concrete reason the fast k2lnk path can't be used (null = it *would* have
/// been eligible, so the only explanation is k2lnk.dll being absent/failing —
/// not worth warning about, e.g. in the test runner). Used to explain the
/// slower LLD fallback to the user. These are exactly k2lnk's current gaps.
fn lldFallbackReason(opts: WindowsLinkOptions, obj_bytes: ?[]const u8) ?[]const u8 {
    if (opts.dll) return "output is a shared library";
    if (opts.obj_files.len != 1) return "multiple object files (k2lnk links one object)";
    for (opts.libs) |lib| {
        if (!std.mem.eql(u8, lib, "kernel32"))
            return "links a non-kernel32 import library (k2lnk can't read .lib archives yet)";
    }
    if (opts.subsystem != .console or opts.entry != null or opts.stack_reserve != 0 or opts.extra_flags.len != 0)
        return "custom linker settings (subsystem/entry/stack/flags) k2lnk can't apply";
    if (obj_bytes) |b| {
        if (!coffSafeForK2lnk(b)) return "object has duplicate-named sections (e.g. a float constant pool)";
    }
    return null;
}

fn noteLldFallback(opts: WindowsLinkOptions, obj_bytes: ?[]const u8) void {
    const reason = lldFallbackReason(opts, obj_bytes) orelse return;
    std.debug.print("note: linked with LLD — the k2lnk fast path was skipped ({s})\n", .{reason});
}

/// Link from object files on disk. Prefers the self-hosted K2 linker (k2lnk.dll),
/// then LLD.
pub fn windows(allocator: std.mem.Allocator, io: std.Io, opts: WindowsLinkOptions) LinkError!void {
    if (tryK2lnk(allocator, opts)) |ok| {
        if (ok) return;
    }
    noteLldFallback(opts, null);
    return linkWithLld(allocator, io, opts);
}

/// Link straight from in-memory object bytes — no `.obj` on disk. Hands the
/// bytes to k2lnk; only when k2lnk can't handle it (absent/ineligible/failed)
/// does it spill the object to `opts.obj_files[0]` and fall back to LLD.
pub fn windowsMem(allocator: std.mem.Allocator, io: std.Io, obj_bytes: []const u8, opts: WindowsLinkOptions) LinkError!void {
    if (tryK2lnkMem(allocator, obj_bytes, opts)) |ok| {
        if (ok) return;
    }
    noteLldFallback(opts, obj_bytes);
    // Spill the object so LLD can read it, then take the LLD path.
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = opts.obj_files[0], .data = obj_bytes }) catch return error.OutOfMemory;
    return linkWithLld(allocator, io, opts);
}
