const std = @import("std");
const value = @import("value.zig");
const instructions = @import("instructions.zig");

const Value = value.Value;
pub const ExternCall = instructions.ExternCall;

// Comptime FFI — call native (DLL/C) functions during compilation.
//
// SECURITY: this executes arbitrary native code at compile time. That is the
// `build.rs` / supply-chain surface. It is gated by `Caps` in engine.zig: a bare
// `#run` is pure, and only `build.fels` is granted host access.
//
// Marshaling is limited to the integer/pointer subset of the C ABI: arguments
// and the return value are passed as register-width words (Win64 / SysV pass
// the first integer/pointer args in registers, which is what the arity-
// dispatched shims below rely on). Floating-point and by-value struct arguments
// are not yet supported.

pub const FfiError = error{
    LibNotFound,
    SymbolNotFound,
    UnsupportedArity,
    UnsupportedArgument,
    OutOfMemory,
};

pub const max_args = 6;

/// Resolve `ec.symbol` in `ec.lib`, marshal `args`, call it, and return the
/// result as a VM value. What marshaling allocates (the NUL-terminated names and
/// strings) lives until the call returns, as a C `const char*` parameter expects;
/// the library stays loaded for the rest of the compile.
pub fn call(allocator: std.mem.Allocator, ec: ExternCall, args: []const Value) FfiError!Value {
    if (args.len > max_args) return error.UnsupportedArity;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const proc = try resolveProc(scratch, ec.lib, ec.symbol);

    var raw: [max_args]usize = .{0} ** max_args;
    for (args, 0..) |a, i| raw[i] = try marshal(scratch, a);

    const result = callRaw(proc, raw[0..args.len]);
    if (!ec.returns_value) return .void;
    // Sign-extend the low 64 bits as a signed integer (most C functions return
    // `int`/`long`/pointers; the caller's IR type carries the real width).
    return Value{ .int = @as(i64, @bitCast(@as(u64, @truncate(result)))) };
}

const win = struct {
    extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
};

/// The C library's loader, on Linux (in glibc's libc since 2.34).
const posix = struct {
    extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
    extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
    const RTLD_NOW = 2;
};

/// `lib` on Linux: a path or a file name with `.so` is taken as it is; a bare name (`m`, `X11`)
/// is the library of that name as a link line spells it (`-lm`): `libm.so`, or, where only the
/// runtime's versioned file is installed, `libm.so.6` and the like.
fn resolveProcPosix(allocator: std.mem.Allocator, lib: []const u8, symbol: []const u8) FfiError!*anyopaque {
    const sym_z = try allocator.dupeZ(u8, symbol);
    if (std.mem.indexOf(u8, lib, ".so") != null or std.mem.indexOfScalar(u8, lib, '/') != null) {
        const module = posix.dlopen((try allocator.dupeZ(u8, lib)).ptr, posix.RTLD_NOW) orelse return error.LibNotFound;
        return posix.dlsym(module, sym_z) orelse error.SymbolNotFound;
    }
    for ([_][]const u8{ "", ".6", ".1", ".2", ".0" }) |version| {
        const name = try std.fmt.allocPrintSentinel(allocator, "lib{s}.so{s}", .{ lib, version }, 0);
        // (the library stays loaded for the rest of the compile)
        const module = posix.dlopen(name.ptr, posix.RTLD_NOW) orelse continue;
        return posix.dlsym(module, sym_z) orelse error.SymbolNotFound;
    }
    return error.LibNotFound;
}

fn resolveProc(allocator: std.mem.Allocator, lib: []const u8, symbol: []const u8) FfiError!*anyopaque {
    if (@import("builtin").os.tag != .windows) return resolveProcPosix(allocator, lib, symbol);
    // Append `.dll` if the name has no extension (`kernel32` → `kernel32.dll`).
    const lib_z: [*:0]const u8 = if (std.mem.indexOfScalar(u8, lib, '.') != null)
        (try allocator.dupeZ(u8, lib)).ptr
    else
        (try std.fmt.allocPrintSentinel(allocator, "{s}.dll", .{lib}, 0)).ptr;
    // (the module stays loaded for the rest of the compile)
    const module = win.LoadLibraryA(lib_z) orelse return error.LibNotFound;
    const sym_z = try allocator.dupeZ(u8, symbol);
    return win.GetProcAddress(module, sym_z) orelse error.SymbolNotFound;
}

fn marshal(allocator: std.mem.Allocator, v: Value) FfiError!usize {
    return switch (v) {
        .int => |x| @truncate(@as(u128, @bitCast(x))),
        .uint => |x| @truncate(x),
        .bool => |b| @intFromBool(b),
        // C expects a NUL-terminated string; copy and terminate.
        .string => |s| @intFromPtr((try allocator.dupeZ(u8, s)).ptr),
        .null_ptr => 0,
        // Real host memory — `std.heap` VirtualAllocs it, so the address is one the
        // callee can actually read and write.
        .host_ptr => |p| p.addr,
        .host_buf => |b| b.addr,
        // Everything else lives in the VM's own memory and has no address the host
        // can reach. This used to answer 0, which turned an unsupported argument
        // into a null dereference *inside the callee* — a segfault attributed to
        // the compiler rather than to the call.
        else => error.UnsupportedArgument,
    };
}

/// Dispatch the call by argument count, casting the resolved address to a C
/// function of the right arity. All words are register-width integers/pointers.
fn callRaw(proc: *anyopaque, args: []const usize) usize {
    const p = @as(*const anyopaque, proc);
    return switch (args.len) {
        0 => @as(*const fn () callconv(.c) usize, @ptrCast(p))(),
        1 => @as(*const fn (usize) callconv(.c) usize, @ptrCast(p))(args[0]),
        2 => @as(*const fn (usize, usize) callconv(.c) usize, @ptrCast(p))(args[0], args[1]),
        3 => @as(*const fn (usize, usize, usize) callconv(.c) usize, @ptrCast(p))(args[0], args[1], args[2]),
        4 => @as(*const fn (usize, usize, usize, usize) callconv(.c) usize, @ptrCast(p))(args[0], args[1], args[2], args[3]),
        5 => @as(*const fn (usize, usize, usize, usize, usize) callconv(.c) usize, @ptrCast(p))(args[0], args[1], args[2], args[3], args[4]),
        6 => @as(*const fn (usize, usize, usize, usize, usize, usize) callconv(.c) usize, @ptrCast(p))(args[0], args[1], args[2], args[3], args[4], args[5]),
        else => 0,
    };
}
