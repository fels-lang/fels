/// Windows link step.
///
/// To link manually after emitObject("output.o"):
///   lld-link output.o /OUT:output.exe /SUBSYSTEM:CONSOLE /ENTRY:mainCRTStartup /NODEFAULTLIB kernel32.lib
const std = @import("std");

pub const LinkError = error{
    OutOfMemory,
    SpawnFailed,
    WaitFailed,
    ProcessTerminated,
    ExitCodeFailure,
};

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
};

/// Build the lld-link command line as a slice of argument strings (caller frees).
pub fn buildArgs(allocator: std.mem.Allocator, opts: WindowsLinkOptions) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(allocator);

    try args.append(allocator, try std.fmt.allocPrint(allocator, "{s}/lld-link.exe", .{opts.llvm_bin}));
    for (opts.obj_files) |obj| try args.append(allocator, try allocator.dupe(u8, obj));
    try args.append(allocator, try std.fmt.allocPrint(allocator, "/OUT:{s}", .{opts.output}));
    try args.append(allocator, try allocator.dupe(u8, "/SUBSYSTEM:CONSOLE"));
    try args.append(allocator, try allocator.dupe(u8, "/ENTRY:mainCRTStartup"));
    try args.append(allocator, try allocator.dupe(u8, "/NODEFAULTLIB"));
    try args.append(allocator, try allocator.dupe(u8, "kernel32.lib"));
    for (opts.lib_paths) |lp|
        try args.append(allocator, try std.fmt.allocPrint(allocator, "/LIBPATH:{s}", .{lp}));
    for (opts.libs) |lib|
        try args.append(allocator, try std.fmt.allocPrint(allocator, "{s}.lib", .{lib}));

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

/// Spawn lld-link and fail if it does not exit cleanly.
pub fn windows(allocator: std.mem.Allocator, io: std.Io, opts: WindowsLinkOptions) LinkError!void {
    printCommand(allocator, opts);

    const args = buildArgs(allocator, opts) catch return error.OutOfMemory;
    defer {
        for (args) |a| allocator.free(@constCast(a));
        allocator.free(args);
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
