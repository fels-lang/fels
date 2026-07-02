const std = @import("std");
const builtin = @import("builtin");
const instructions = @import("instructions.zig");
const value = @import("value.zig");
const zones = @import("zones.zig");
const ffi = @import("ffi.zig");

const Instr = instructions.Instr;
const Opcode = instructions.Opcode;
const BytecodeFunction = instructions.BytecodeFunction;
const BytecodeModule = instructions.BytecodeModule;
const Value = value.Value;

pub const VmError = error{
    DivisionByZero,
    InvalidInstruction,
    StackOverflow,
    StepLimitExceeded,
    OutOfBounds,
    TypeMismatch,
    Unsupported,
    NoModule,
    Trap,
    OutOfMemory,
    NoActiveZone,
    ZoneUnderflow,
    ReadOnly,
};

/// One activation record. Registers are SSA-style temporaries (one per IR
/// result + scratch); locals are the named, mutable parameter/local slots.
const Frame = struct {
    func: *const BytecodeFunction,
    regs: []Value,
    locals: []Value,
    /// Zone-stack depth on entry; the frame unwinds back to this on return.
    zone_watermark: usize,
};

/// The Fels compile-time virtual machine.
/// A side-effecting bridge to the embedding host, invoked by the `host_call`
/// opcode. The build driver installs one so `std.build`'s `__build_*` intrinsics
/// record into a BuildPlan. `op` is a `BuildOp`; `args` are the call arguments
/// (strings/ints); the return is bound to the call's dst register.
pub const BuildHost = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, op: u32, args: []const Value) Value,
};

/// A `sys_mem`: the runtime's memory primitive `op` on the host's memory. Addresses and sizes
/// are integers, as the runtimes pass them; a failure is 0 or `false`, as theirs is.
fn hostMemory(op: instructions.MemOp, args: []const Value) Value {
    const word = struct {
        fn of(v: Value) usize {
            return switch (v) {
                .uint => |u| @truncate(u),
                .int => |i| @truncate(@as(u128, @bitCast(i))),
                .host_ptr => |p| p.addr,
                .host_buf => |b| b.addr,
                else => 0,
            };
        }
    }.of;
    return switch (op) {
        .reserve => .{ .uint = host_mem.reserve(word(args[0])) },
        .commit => .{ .bool = host_mem.commit(word(args[0]), word(args[1])) },
        .alloc => blk: {
            const size = word(args[0]);
            const addr = host_mem.reserve(size);
            if (addr == 0 or !host_mem.commit(addr, size)) break :blk .{ .uint = 0 };
            break :blk .{ .uint = addr };
        },
        .release => blk: {
            host_mem.release(word(args[0]), word(args[1]));
            break :blk .{ .uint = 0 };
        },
    };
}

/// The host's pages: reserved without memory behind them, committed, released. What the
/// runtimes' `os_reserve`, `os_commit` and `os_release` do, for the compiler's own OS.
const host_mem = if (builtin.os.tag == .windows) struct {
    const MEM_COMMIT = 0x1000;
    const MEM_RESERVE = 0x2000;
    const MEM_RELEASE = 0x8000;
    const PAGE_NOACCESS = 0x01;
    const PAGE_READWRITE = 0x04;
    extern "kernel32" fn VirtualAlloc(addr: ?*anyopaque, size: usize, kind: u32, protect: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn VirtualFree(addr: ?*anyopaque, size: usize, kind: u32) callconv(.winapi) i32;

    fn reserve(size: usize) usize {
        return @intFromPtr(VirtualAlloc(null, size, MEM_RESERVE, PAGE_NOACCESS));
    }
    fn commit(addr: usize, size: usize) bool {
        if (addr == 0) return false;
        return VirtualAlloc(@ptrFromInt(addr), size, MEM_COMMIT, PAGE_READWRITE) != null;
    }
    fn release(addr: usize, size: usize) void {
        _ = size;
        if (addr != 0) _ = VirtualFree(@ptrFromInt(addr), 0, MEM_RELEASE);
    }
} else struct {
    const linux = std.os.linux;

    fn reserve(size: usize) usize {
        const r = linux.mmap(null, size, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        return if (linux.errno(r) == .SUCCESS) r else 0;
    }
    fn commit(addr: usize, size: usize) bool {
        if (addr == 0) return false;
        return linux.errno(linux.mprotect(@ptrFromInt(addr), size, .{ .READ = true, .WRITE = true })) == .SUCCESS;
    }
    fn release(addr: usize, size: usize) void {
        if (addr != 0) _ = linux.munmap(@ptrFromInt(addr), size);
    }
};

/// What a comptime run is allowed to do. A bare `#run` gets nothing — it is pure —
/// and the build driver grants host access to `build.fels`. Capabilities only narrow
/// as the call stack descends: `narrow` computes a conservative intersection and has
/// no way to widen. This is the structural fix for the `build.rs` surface: a
/// dependency's compile-time code can't reach the host unless it was handed the
/// capability to.
pub const Caps = struct {
    /// Which host (DLL / C) libraries this run may call into.
    ffi: Ffi = .none,
    /// Which files this compile-time code may read: `#embed`, and `std.fs` in a `#run`.
    read: Read = .none,

    /// A read grant: no files, the files below these folders, or any file.
    pub const Read = union(enum) {
        none,
        /// Absolute folders, borrowed: the slice must outlive the run.
        dirs: []const []const u8,
        all,
    };

    /// Whether the file at the absolute `path` may be read. A path that leaves its folder
    /// (`..`) is no file below it.
    pub fn allowsRead(self: Caps, path: []const u8) bool {
        return switch (self.read) {
            .none => false,
            .all => true,
            .dirs => |dirs| blk: {
                if (std.mem.indexOf(u8, path, "..") != null) break :blk false;
                for (dirs) |d| if (below(path, d)) break :blk true;
                break :blk false;
            },
        };
    }

    /// Whether `path` is below the folder `dir`, comparing `/` and `\` alike and letters
    /// without case (Windows paths).
    pub fn below(path: []const u8, dir: []const u8) bool {
        if (dir.len == 0 or path.len <= dir.len) return false;
        for (dir, path[0..dir.len]) |d, p| {
            const dn = if (d == '\\') '/' else std.ascii.toLower(d);
            const pn = if (p == '\\') '/' else std.ascii.toLower(p);
            if (dn != pn) return false;
        }
        const last = dir[dir.len - 1];
        return last == '/' or last == '\\' or path[dir.len] == '/' or path[dir.len] == '\\';
    }

    /// A host-call grant. `.libs` is the point of the exercise: a build hook can be
    /// handed exactly the libraries it needs instead of the whole host.
    pub const Ffi = union(enum) {
        /// No host calls beyond `heap_primitives`.
        none,
        /// Host calls only into these libraries, spelled the way `#extern("lib", …)`
        /// spells them. Matched case-insensitively, because Windows DLL names are.
        /// Borrowed: the slice must outlive the run.
        libs: []const []const u8,
        /// Any host call. The privileged root (`build.fels`) only.
        all,
    };

    /// The comptime heap reserves, commits and releases pages through these. Gating
    /// them would stop a pure `#run` from allocating at all, and they do nothing
    /// beyond memory, so they belong to the model rather than behind a capability.
    pub const heap_primitives = [_][]const u8{ "VirtualAlloc", "VirtualFree" };

    pub fn allowsFfi(self: Caps, lib: []const u8, symbol: []const u8) bool {
        for (heap_primitives) |p| {
            if (std.mem.eql(u8, symbol, p)) return true;
        }
        return switch (self.ffi) {
            .none => false,
            .all => true,
            .libs => |allowed| blk: {
                for (allowed) |l| {
                    if (std.ascii.eqlIgnoreCase(l, lib)) break :blk true;
                }
                break :blk false;
            },
        };
    }

    /// The clause `callExtern` splices into its diagnostic, so a denial says which
    /// grant refused rather than only that something did.
    pub fn denialReason(self: Caps) []const u8 {
        return switch (self.ffi) {
            .none => "this code has no host access. A `#run` is pure; `build.fels` has host access, and a package's compile-time code gets it when fels.pkg grants it (`#use name from \"...\" may ffi(\"lib\")`)",
            .libs => "the capability grant of this code does not list that library (a package gets more with `may ffi(...)` on its `#use` line in fels.pkg)",
            // `.all` allows every call, so it never reaches a denial.
            .all => "this run's capability grant refused it",
        };
    }

    /// Hand capabilities to a nested run. The result is never broader than either
    /// side, so a callee cannot widen what it was given. Two allowlists intersect to
    /// whichever is a subset of the other; when neither contains the other the result
    /// is `.none`, because a true intersection would have to allocate and failing
    /// closed is the safe direction.
    pub fn narrow(self: Caps, request: Caps) Caps {
        return .{ .read = narrowRead(self.read, request.read), .ffi = switch (self.ffi) {
            .none => .none,
            .all => request.ffi,
            .libs => |mine| switch (request.ffi) {
                .none => .none,
                .all => self.ffi,
                .libs => |theirs| if (isSubset(theirs, mine))
                    request.ffi
                else if (isSubset(mine, theirs))
                    self.ffi
                else
                    .none,
            },
        } };
    }

    /// Like the FFI grant: never broader than either side, and failing closed when neither
    /// list of folders holds the other's.
    fn narrowRead(mine: Read, theirs: Read) Read {
        return switch (mine) {
            .none => .none,
            .all => theirs,
            .dirs => |m| switch (theirs) {
                .none => .none,
                .all => mine,
                .dirs => |t| if (dirsWithin(t, m)) theirs else if (dirsWithin(m, t)) mine else .none,
            },
        };
    }

    /// Whether each folder of `inner` is one of `outer` or below one.
    fn dirsWithin(inner: []const []const u8, outer: []const []const u8) bool {
        next: for (inner) |i| {
            for (outer) |o| {
                if (std.ascii.eqlIgnoreCase(i, o) or below(i, o)) continue :next;
            }
            return false;
        }
        return true;
    }

    fn isSubset(inner: []const []const u8, outer: []const []const u8) bool {
        next: for (inner) |i| {
            for (outer) |o| {
                if (std.ascii.eqlIgnoreCase(i, o)) continue :next;
            }
            return false;
        }
        return true;
    }
};

/// Why compile-time code does not write a global, a scalar one or a field of one.
const global_write_message = "compile-time code cannot modify a global: it sees the initial value that goes into the image, and a write would not be there at run time";

pub const Vm = struct {
    allocator: std.mem.Allocator,
    /// Function table for resolving `call`. Optional: a standalone function with
    /// no calls can run without one.
    module: ?*const BytecodeModule = null,
    zone_stack: zones.ZoneStack,
    /// Optional host bridge for `host_call` (the build driver). Null → trap.
    host: ?BuildHost = null,
    /// What this run may do. Default: nothing privileged (a pure `#run`). The build
    /// driver sets `caps.ffi = .all` for `build.fels`. See `Caps`.
    caps: Caps = .{},
    call_depth: usize = 0,
    max_call_depth: usize = 512,
    /// Guard against runaway comptime loops (mirrors the tree-walker's cap).
    steps: u64 = 0,
    step_limit: u64 = 100_000_000,
    /// Strings built by `str_concat` (the comptime string builder); owned here and
    /// freed on `deinit` (callers dupe the final result out before then).
    concat_strings: std.ArrayList([]u8) = .empty,
    /// Set by `record_remove` (a `#compiler` hook calling `compiler_remove("...")`):
    /// names of top-level declarations the hook asked to drop. Owned here; the
    /// driver copies them out before `deinit`.
    compiler_removals: std.ArrayList([]u8) = .empty,
    /// Set by `halt_msg` (a `#compiler` hook calling `compiler_error("...")`): the
    /// diagnostic to report when the run halts. Points into `concat_strings` or a
    /// module constant, so it lives as long as the VM.
    compiler_error_msg: ?[]const u8 = null,
    /// Set when the run stopped at something only a running program can do: a host call
    /// this run may not make, a write to a global, a function the VM could not compile. The
    /// code is not wrong for that, so the comptime test lane skips such a test instead of
    /// failing it.
    needs_runtime: bool = false,
    /// The static data this run has built so far, indexed like the module's `globals`: the value
    /// (a pointer into the static zone) of each one that has been read. Built on first read, so a
    /// run pays only for the tables it touches, and shared by every call in the run.
    statics: []?Value = &.{},

    pub fn init(allocator: std.mem.Allocator) Vm {
        return .{ .allocator = allocator, .zone_stack = zones.ZoneStack.init(allocator) };
    }

    pub fn initModule(allocator: std.mem.Allocator, module: *const BytecodeModule) Vm {
        return .{
            .allocator = allocator,
            .module = module,
            .zone_stack = zones.ZoneStack.init(allocator),
        };
    }

    /// Call a host function, gated by this run's FFI grant. A pure `#run` reaches
    /// only `Caps.heap_primitives`; anything else halts the build with a diagnostic
    /// that names both the symbol and which grant refused it.
    fn callExtern(self: *Vm, ec: ffi.ExternCall, args: []const Value) error{Trap}!Value {
        if (!self.caps.allowsFfi(ec.lib, ec.symbol)) {
            self.needs_runtime = true;
            self.setErrorMsg(
                "comptime FFI to `{s}` (in `{s}`) is not allowed here: {s}.",
                .{ ec.symbol, ec.lib, self.caps.denialReason() },
                "comptime FFI is not permitted by this run's capabilities",
            );
            return error.Trap;
        }

        // A `*T` argument pointing into compile-time memory has no address the host
        // can use. Give each one a scratch word holding the cell's current value,
        // pass that address, and copy the word back afterwards. That is what makes
        // an out-parameter — WriteFile's `lpNumberOfBytesWritten`, say — work from a
        // build script, and with it `println` at compile time.
        if (args.len > ffi.max_args) return error.Trap;
        var scratch: [ffi.max_args]u64 = .{0} ** ffi.max_args;
        var patched: [ffi.max_args]Value = undefined;
        var out: [ffi.max_args]?Value.Ptr = .{null} ** ffi.max_args;
        for (args, 0..) |a, i| {
            switch (a) {
                .ptr => |p| {
                    const cur = self.zone_stack.getCell(p.zone, p.offset) catch return error.Trap;
                    scratch[i] = switch (cur) {
                        .int => |x| @truncate(@as(u128, @bitCast(x))),
                        .uint => |x| @truncate(x),
                        .bool => |b| @intFromBool(b),
                        // Only scalar cells have a meaningful machine word. An
                        // aggregate would need a layout the VM does not have.
                        else => return error.Trap,
                    };
                    out[i] = p;
                    patched[i] = .{ .host_ptr = .{ .addr = @intFromPtr(&scratch[i]), .size = 8 } };
                },
                else => patched[i] = a,
            }
        }

        const result = ffi.call(self.allocator, ec, patched[0..args.len]) catch |err| {
            const detail: []const u8 = switch (err) {
                error.UnsupportedArgument => "an argument lives in compile-time memory and has no address the host can read. Integers, booleans, string literals, `std.heap` buffers and pointers to scalar locals can cross; an aggregate cannot",
                error.LibNotFound => "the library could not be loaded",
                error.SymbolNotFound => "the symbol was not found in that library",
                error.UnsupportedArity => "too many arguments",
                error.OutOfMemory => "out of memory",
            };
            self.setErrorMsg(
                "comptime FFI to `{s}` (in `{s}`) failed: {s}.",
                .{ ec.symbol, ec.lib, detail },
                "a comptime FFI call failed",
            );
            return error.Trap;
        };

        // Copy anything the callee wrote back into its cell, keeping the kind the
        // cell already had.
        for (args, 0..) |a, i| {
            const p = out[i] orelse continue;
            const back: Value = switch (a) {
                .ptr => switch (self.zone_stack.getCell(p.zone, p.offset) catch return error.Trap) {
                    .int => .{ .int = @as(i128, @as(i64, @bitCast(scratch[i]))) },
                    .uint => .{ .uint = @as(u128, scratch[i]) },
                    .bool => .{ .bool = scratch[i] != 0 },
                    else => continue,
                },
                else => continue,
            };
            self.zone_stack.setCell(p.zone, p.offset, back) catch return error.Trap;
        }
        return result;
    }

    /// Set `compiler_error_msg` to a formatted message, kept in `concat_strings` so `deinit`
    /// frees it; `fallback` when there is no memory for it.
    fn setErrorMsg(self: *Vm, comptime fmt: []const u8, args: anytype, fallback: []const u8) void {
        self.compiler_error_msg = fallback;
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.concat_strings.append(self.allocator, msg) catch {
            self.allocator.free(msg);
            return;
        };
        self.compiler_error_msg = msg;
    }

    pub fn deinit(self: *Vm) void {
        self.zone_stack.deinit();
        if (self.statics.len != 0) self.allocator.free(self.statics);
        for (self.concat_strings.items) |s| self.allocator.free(s);
        self.concat_strings.deinit(self.allocator);
        for (self.compiler_removals.items) |s| self.allocator.free(s);
        self.compiler_removals.deinit(self.allocator);
    }

    fn strLen(v: Value) ?usize {
        return switch (v) {
            .string => |s| s.len,
            .slice => |s| s.len,
            .host_buf => |hb| hb.len,
            else => null,
        };
    }

    fn copyStrBytes(self: *Vm, v: Value, dst: []u8) VmError!void {
        switch (v) {
            .string => |s| @memcpy(dst, s),
            .host_buf => |hb| {
                const p: [*]const u8 = @ptrFromInt(hb.addr);
                @memcpy(dst, p[0..hb.len]);
            },
            .slice => |s| {
                var i: usize = 0;
                while (i < s.len) : (i += 1) {
                    const cell = try self.zone_stack.getCell(s.zone, s.offset + @as(u32, @intCast(i)));
                    dst[i] = switch (cell) {
                        .int => |x| @intCast(@mod(x, 256)),
                        .uint => |x| @intCast(x % 256),
                        else => return error.TypeMismatch,
                    };
                }
            },
            else => return error.TypeMismatch,
        }
    }

    /// Execute a standalone function with no arguments. Kept for the simple
    /// hand-assembled smoke tests.
    pub fn execute(self: *Vm, function: BytecodeFunction) VmError!Value {
        return self.runTop(&function, &.{});
    }

    /// Like `execute`, but does NOT unwind the root zone on the way out, so the
    /// caller can still read the result's zone cells — used by the reifier to
    /// turn a comptime-built `AstBlock` back into front-end AST. All zone
    /// memory is freed by `deinit`.
    pub fn executeKeepZones(self: *Vm, function: BytecodeFunction) VmError!Value {
        if (self.zone_stack.static_zone == null) try self.enterRoot();
        return self.run(&function, &.{});
    }

    /// Open the zones a run starts with: the one that will hold static data, and above it the
    /// root zone that aggregate/`new` allocations land in.
    fn enterRoot(self: *Vm) VmError!void {
        self.zone_stack.static_zone = try self.zone_stack.push("__static");
        _ = try self.zone_stack.push("__root");
    }

    /// The static data built so far lives in a zone that has just been freed.
    fn forgetStatics(self: *Vm) void {
        @memset(self.statics, null);
    }

    /// The value of global `index`: a pointer to its block in the static zone, built on first use.
    /// The block is built by the global's own initializer function, which allocates in the static
    /// zone (the only time that zone can be written) and returns the root of the value.
    fn loadStatic(self: *Vm, index: usize) VmError!Value {
        const mod = self.module orelse return error.NoModule;
        if (index >= mod.globals.len) return error.InvalidInstruction;
        if (self.statics.len != mod.globals.len) {
            if (self.statics.len != 0) self.allocator.free(self.statics);
            self.statics = try self.allocator.alloc(?Value, mod.globals.len);
            @memset(self.statics, null);
        }
        if (self.statics[index]) |built| return built;

        const builder = &(mod.globals[index].init orelse return error.InvalidInstruction);
        const zone = self.zone_stack.static_zone orelse return error.NoActiveZone;
        self.zone_stack.static_open = true;
        self.zone_stack.alloc_zone = zone;
        defer {
            self.zone_stack.static_open = false;
            self.zone_stack.alloc_zone = null;
        }
        const built = try self.run(builder, &.{});
        self.statics[index] = built;
        return built;
    }

    /// Write `val` at cell `offset` from `target` (`store_cell`). The target's own offset is
    /// already baked in by `field_addr` / `index_addr`; at a host address, write `hp.size` bytes.
    fn storeCell(self: *Vm, target: Value, offset: i64, val: Value) VmError!void {
        if (target == .host_ptr) {
            hostStore(target.host_ptr.addr + @as(usize, @intCast(offset)) * 8, target.host_ptr.size, val);
        } else {
            const base = try asPtr(target);
            self.zone_stack.setCell(base.zone, base.offset + @as(u32, @intCast(offset)), val) catch |e| return self.writeFailed(e);
        }
    }

    /// Copy the `n` cells of block `src` over those of block `dst` (`copy_cells`), back to front
    /// when the source starts before an overlapping destination.
    fn copyCells(self: *Vm, dst: Value.Ptr, src: Value.Ptr, n: u32) VmError!void {
        const from = try self.zone_stack.cellsAt(src.zone, src.offset, n);
        const into = self.zone_stack.cellsToWrite(dst.zone, dst.offset, n) catch |e| return self.writeFailed(e);
        if (dst.zone == src.zone and dst.offset > src.offset) {
            std.mem.copyBackwards(Value, into, from);
        } else std.mem.copyForwards(Value, into, from);
    }

    /// A whole aggregate `src` of shape `shape` of `func` given to a place (a local, a field, an
    /// element) that holds `have`. A place that holds a block keeps it and takes `src`'s value
    /// into it, so a pointer to the place sees the new value; null then. Otherwise the place's
    /// new value: `src` itself when it is a value just built that no other place holds
    /// (`fresh`), else a copy of it.
    fn assign(self: *Vm, func: *const BytecodeFunction, have: Value, src: Value, shape: u32, fresh: bool) VmError!?Value {
        if (zoneBlock(have)) |into| if (zoneBlock(src)) |from| {
            try self.copyInto(func, into, from, shape);
            return null;
        };
        return if (fresh) src else try self.copyValue(func, src, shape);
    }

    /// Write `src`, a value of shape `shape` of `func`, over the value in block `dst` (`copy_cells`),
    /// part by part: a part of `dst` that is a block keeps its block and takes the cells of the
    /// part of `src`, so a pointer into `dst` sees the new value, as one does at run time where
    /// the bytes are written over. Anything else of `dst` takes a copy (`copyValue`).
    fn copyInto(self: *Vm, func: *const BytecodeFunction, dst: Value.Ptr, src: Value.Ptr, shape: u32) VmError!void {
        if (dst.zone == src.zone and dst.offset == src.offset) return;
        const s = try shapeIn(func, shape);
        if (s.len == 0) return self.copyCells(dst, src, s.cells);
        // An enum value keeps its payload's block only when it stays the same variant.
        const same_variant = s.kind != .payloads or sameInt(
            try self.zone_stack.getCell(dst.zone, dst.offset),
            try self.zone_stack.getCell(src.zone, src.offset),
        );
        const parts = try self.partsOf(func, s, src);
        // The cells between the parts, as they are (nothing is allocated meanwhile, which could
        // move the cells).
        {
            const from = try self.zone_stack.cellsAt(src.zone, src.offset, s.cells);
            const into = self.zone_stack.cellsToWrite(dst.zone, dst.offset, s.cells) catch |e| return self.writeFailed(e);
            var start: u32 = 0;
            var it = parts;
            while (it.next()) |p| {
                std.mem.copyForwards(Value, into[start..p.cell], from[start..p.cell]);
                start = p.cell + 1;
            }
            std.mem.copyForwards(Value, into[start..], from[start..]);
        }
        // Then each part.
        var it = parts;
        while (it.next()) |p| {
            const have = try self.zone_stack.getCell(dst.zone, dst.offset + p.cell);
            const from = try self.zone_stack.getCell(src.zone, src.offset + p.cell);
            if (same_variant) if (zoneBlock(have)) |into| if (zoneBlock(from)) |inner| {
                try self.copyInto(func, into, inner, p.shape);
                continue;
            };
            const copy = try self.copyValue(func, from, p.shape);
            self.zone_stack.setCell(dst.zone, dst.offset + p.cell, copy) catch |e| return self.writeFailed(e);
        }
    }

    /// A copy of `src`, a value of shape `shape` of `func`, in new blocks: it shares no block with
    /// `src`, as a copy of the bytes shares no memory at run time. A value that is no block of
    /// cells (one read from host memory) is its own copy.
    fn copyValue(self: *Vm, func: *const BytecodeFunction, src: Value, shape: u32) VmError!Value {
        const from = zoneBlock(src) orelse return src;
        const s = try shapeIn(func, shape);
        const to = (try self.zone_stack.alloc(s.cells)).ptr;
        // Both found after the allocation, which may have moved the cells.
        const cells = try self.zone_stack.cellsAt(from.zone, from.offset, s.cells);
        const into = self.zone_stack.cellsToWrite(to.zone, to.offset, s.cells) catch |e| return self.writeFailed(e);
        std.mem.copyForwards(Value, into, cells);
        var parts = try self.partsOf(func, s, from);
        while (parts.next()) |part| {
            const at = to.offset + part.cell;
            const inner = try self.zone_stack.getCell(to.zone, at);
            const copy = try self.copyValue(func, inner, part.shape);
            self.zone_stack.setCell(to.zone, at, copy) catch |e| return self.writeFailed(e);
        }
        return .{ .ptr = to };
    }

    /// The parts of the value of shape `s` in block `block`: the cells that hold a block of their
    /// own, each with its shape.
    fn partsOf(self: *Vm, func: *const BytecodeFunction, s: instructions.Shape, block: Value.Ptr) VmError!Parts {
        if (@as(usize, s.first) + s.len > func.shape_parts.len) return error.InvalidInstruction;
        const parts = func.shape_parts[s.first..][0..s.len];
        return switch (s.kind) {
            .fields => .{ .list = parts },
            .elements => .{
                .list = parts,
                .count = if (s.stride == 0) 0 else s.cells / s.stride,
                .stride = s.stride,
            },
            // Only the variant the tag names has its payload.
            .payloads => blk: {
                const tag = (try self.zone_stack.getCell(block.zone, block.offset)).asI128() orelse break :blk .{};
                const t = std.math.cast(usize, tag) orelse break :blk .{};
                if (t >= parts.len or parts[t].shape == instructions.no_shape) break :blk .{};
                break :blk .{ .list = parts[t..][0..1] };
            },
        };
    }

    /// A failed store: a write into static data is the program's mistake, so say so.
    fn writeFailed(self: *Vm, err: zones.ZoneError) VmError {
        if (err == error.ReadOnly) {
            self.needs_runtime = true;
            self.compiler_error_msg = global_write_message;
            return error.Trap;
        }
        return err;
    }

    /// Look up a function by name in the bound module and run it with `args`.
    pub fn call(self: *Vm, name: []const u8, args: []const Value) VmError!Value {
        const mod = self.module orelse return error.NoModule;
        const f = mod.find(name) orelse return error.InvalidInstruction;
        return self.runTop(f, args);
    }

    /// Outermost entry: guarantee the static and root zones so static data and aggregate/`new`
    /// allocations always have somewhere to live, then unwind them on the way out. A caller may
    /// have pushed a zone of its own for the arguments (the `*Test` of a test, the `Build` of
    /// build.fels); the run's zones go above it.
    /// (Nested `call` opcodes reuse the existing zone stack and do not add one.)
    fn runTop(self: *Vm, func: *const BytecodeFunction, args: []const Value) VmError!Value {
        const root_mark = self.zone_stack.depth();
        const opens = self.zone_stack.static_zone == null;
        if (opens) try self.enterRoot();
        defer {
            self.zone_stack.popTo(root_mark);
            if (opens) self.forgetStatics();
        }
        return self.run(func, args);
    }

    /// Run `func`, binding `args` to its parameter slots.
    pub fn run(self: *Vm, func: *const BytecodeFunction, args: []const Value) VmError!Value {
        if (self.call_depth >= self.max_call_depth) return error.StackOverflow;
        self.call_depth += 1;
        defer self.call_depth -= 1;

        const regs = try self.allocator.alloc(Value, func.num_regs);
        defer self.allocator.free(regs);
        @memset(regs, .void);

        const locals = try self.allocator.alloc(Value, func.num_locals);
        defer self.allocator.free(locals);
        @memset(locals, .void);

        // Bind arguments to the leading parameter slots.
        const nparams = @min(args.len, func.num_params);
        for (args[0..nparams], 0..) |arg, i| locals[i] = arg;

        var frame = Frame{
            .func = func,
            .regs = regs,
            .locals = locals,
            .zone_watermark = self.zone_stack.depth(),
        };
        // On any early exit (error), make sure zones this frame opened are freed.
        errdefer self.zone_stack.popTo(frame.zone_watermark);

        return self.interpret(&frame);
    }

    fn interpret(self: *Vm, frame: *Frame) VmError!Value {
        const code = frame.func.instrs;
        const consts = frame.func.constants;
        var pc: usize = 0;

        while (pc < code.len) {
            self.steps += 1;
            if (self.steps > self.step_limit) return error.StepLimitExceeded;

            const inst = code[pc];
            pc += 1;

            switch (inst.op) {
                .nop => {},

                .load_imm => frame.regs[inst.a] = .{ .int = inst.imm },
                .load_const => frame.regs[inst.a] = consts[@intCast(inst.imm)],
                .copy => frame.regs[inst.a] = frame.regs[inst.b],

                // Integer arithmetic
                .add_i, .sub_i, .mul_i, .div_i, .rem_i => {
                    const l = frame.regs[inst.b].asI128() orelse return error.TypeMismatch;
                    const r = frame.regs[inst.c].asI128() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .int = switch (inst.op) {
                        .add_i => l +% r,
                        .sub_i => l -% r,
                        .mul_i => l *% r,
                        .div_i => if (r == 0) return error.DivisionByZero else @divTrunc(l, r),
                        .rem_i => if (r == 0) return error.DivisionByZero else @rem(l, r),
                        else => unreachable,
                    } };
                },
                .neg_i => {
                    const v = frame.regs[inst.b].asI128() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .int = -%v };
                },

                // Float arithmetic
                .add_f, .sub_f, .mul_f, .div_f => {
                    const l = frame.regs[inst.b].asF64() orelse return error.TypeMismatch;
                    const r = frame.regs[inst.c].asF64() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .float = switch (inst.op) {
                        .add_f => l + r,
                        .sub_f => l - r,
                        .mul_f => l * r,
                        .div_f => l / r,
                        else => unreachable,
                    } };
                },
                .neg_f => {
                    const v = frame.regs[inst.b].asF64() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .float = -v };
                },

                // Bitwise & logic
                .bit_and, .bit_or, .bit_xor, .shl, .shr => {
                    const l = frame.regs[inst.b].asI128() orelse return error.TypeMismatch;
                    const r = frame.regs[inst.c].asI128() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .int = switch (inst.op) {
                        .bit_and => l & r,
                        .bit_or => l | r,
                        .bit_xor => l ^ r,
                        .shl => l << @as(u7, @intCast(r & 0x7f)),
                        .shr => l >> @as(u7, @intCast(r & 0x7f)),
                        else => unreachable,
                    } };
                },
                .bitnot => {
                    const v = frame.regs[inst.b].asI128() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .int = ~v };
                },
                .not_b => frame.regs[inst.a] = .{ .bool = !frame.regs[inst.b].truthy() },

                // Comparison (int)
                .eq_i, .ne_i, .lt_i, .le_i, .gt_i, .ge_i => {
                    const l = frame.regs[inst.b].asI128() orelse return error.TypeMismatch;
                    const r = frame.regs[inst.c].asI128() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .bool = switch (inst.op) {
                        .eq_i => l == r,
                        .ne_i => l != r,
                        .lt_i => l < r,
                        .le_i => l <= r,
                        .gt_i => l > r,
                        .ge_i => l >= r,
                        else => unreachable,
                    } };
                },

                // Comparison (float)
                .eq_f, .ne_f, .lt_f, .le_f, .gt_f, .ge_f => {
                    const l = frame.regs[inst.b].asF64() orelse return error.TypeMismatch;
                    const r = frame.regs[inst.c].asF64() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .bool = switch (inst.op) {
                        .eq_f => l == r,
                        .ne_f => l != r,
                        .lt_f => l < r,
                        .le_f => l <= r,
                        .gt_f => l > r,
                        .ge_f => l >= r,
                        else => unreachable,
                    } };
                },

                // Casts
                .cast_to_float => {
                    const v = frame.regs[inst.b].asF64() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .float = v };
                },
                .narrow => {
                    const v = frame.regs[inst.b].asI128() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .int = narrowInt(v, @intCast(inst.imm & 0xff), (inst.imm & 0x100) != 0) };
                },
                .cast_to_int => {
                    frame.regs[inst.a] = switch (frame.regs[inst.b]) {
                        .float => |f| .{ .int = @intFromFloat(f) },
                        .int => |v| .{ .int = v },
                        .uint => |v| .{ .int = std.math.cast(i128, v) orelse @bitCast(v) },
                        .bool => |bb| .{ .int = @intFromBool(bb) },
                        // `p as usize`: the address of real memory
                        .host_ptr => |hp| .{ .int = hp.addr },
                        .null_ptr => .{ .int = 0 },
                        else => return error.TypeMismatch,
                    };
                },

                // Locals
                .load_local => frame.regs[inst.a] = frame.locals[@intCast(inst.imm)],
                .store_local => frame.locals[@intCast(inst.imm)] = frame.regs[inst.b],

                .load_global => frame.regs[inst.a] = try self.loadStatic(@intCast(inst.imm)),
                .store_global => return error.Unsupported,

                // Control flow
                .jmp => pc = @intCast(inst.imm),
                .br_if => if (frame.regs[inst.a].truthy()) {
                    pc = @intCast(inst.imm);
                },
                .br_if_not => if (!frame.regs[inst.a].truthy()) {
                    pc = @intCast(inst.imm);
                },
                .call => {
                    const mod = self.module orelse return error.NoModule;
                    const idx: usize = @intCast(inst.imm);
                    if (idx >= mod.functions.len) return error.InvalidInstruction;
                    const callee = &mod.functions[idx];
                    const argc: usize = inst.c;
                    const base: usize = inst.b;
                    // Snapshot args (callee.run allocates its own frame).
                    var buf: [16]Value = undefined;
                    const arg_slice = if (argc <= buf.len) buf[0..argc] else try self.allocator.alloc(Value, argc);
                    defer if (argc > buf.len) self.allocator.free(arg_slice);
                    for (0..argc) |i| arg_slice[i] = frame.regs[base + i];
                    frame.regs[inst.a] = if (callee.extern_call) |ec|
                        try self.callExtern(ec, arg_slice)
                    else
                        try self.run(callee, arg_slice);
                },
                .call_indirect => {
                    const mod = self.module orelse return error.NoModule;
                    // The callee is a bare function reference (an interface method)
                    // or a closure value. A closure that `takes_env` (a lifted
                    // lambda) gets its environment passed as the leading argument;
                    // a plain function is called directly.
                    var idx: usize = undefined;
                    var lead_env: ?Value = null;
                    switch (frame.regs[inst.b]) {
                        .fn_ref => |fr| idx = fr,
                        .closure => |c| {
                            idx = c.fn_idx;
                            if (c.takes_env) lead_env = switch (c.env) {
                                .none => .void, // non-capturing: void env
                                .cell => |p| .{ .ptr = p },
                                .host => |h| .{ .host_ptr = h },
                            };
                        },
                        else => return error.TypeMismatch,
                    }
                    if (idx >= mod.functions.len) return error.InvalidInstruction;
                    const callee = &mod.functions[idx];
                    const argc: usize = @intCast(inst.imm);
                    const base: usize = inst.c;
                    const total = argc + @as(usize, if (lead_env != null) 1 else 0);
                    var buf: [16]Value = undefined;
                    const arg_slice = if (total <= buf.len) buf[0..total] else try self.allocator.alloc(Value, total);
                    defer if (total > buf.len) self.allocator.free(arg_slice);
                    const off: usize = if (lead_env) |e| blk: {
                        arg_slice[0] = e;
                        break :blk 1;
                    } else 0;
                    for (0..argc) |i| arg_slice[off + i] = frame.regs[base + i];
                    frame.regs[inst.a] = if (callee.extern_call) |ec|
                        try self.callExtern(ec, arg_slice)
                    else
                        try self.run(callee, arg_slice);
                },

                .ret => {
                    const result = frame.regs[inst.a];
                    self.zone_stack.popTo(frame.zone_watermark);
                    return result;
                },
                .ret_void => {
                    self.zone_stack.popTo(frame.zone_watermark);
                    return .void;
                },

                // Zones
                .zone_push => {
                    const name = constName(consts, inst.imm);
                    _ = try self.zone_stack.push(name);
                },
                .zone_pop => try self.zone_stack.pop(),
                .zone_alloc => {
                    frame.regs[inst.a] = try self.zone_stack.alloc(@intCast(inst.imm));
                },
                .field_addr => {
                    // A field of a HOST struct (e.g. `Chunk` reached via a real
                    // address): pointer-sized fields, so byte offset = index * 8.
                    if (frame.regs[inst.b] == .host_ptr) {
                        const hp = frame.regs[inst.b].host_ptr;
                        frame.regs[inst.a] = .{ .host_ptr = .{ .addr = hp.addr + @as(usize, @intCast(inst.imm)) * 8, .size = 8 } };
                    } else {
                        const base = try asPtr(frame.regs[inst.b]);
                        frame.regs[inst.a] = .{ .ptr = .{ .zone = base.zone, .offset = base.offset + @as(u32, @intCast(inst.imm)) } };
                    }
                },
                .load_cell => {
                    // On a host pointer, `imm` is a field index → byte offset *8;
                    // host struct fields are pointer-sized (read 8 bytes).
                    if (frame.regs[inst.b] == .host_ptr) {
                        const hp = frame.regs[inst.b].host_ptr;
                        frame.regs[inst.a] = hostLoad(hp.addr + @as(usize, @intCast(inst.imm)) * 8, 8);
                    } else {
                        const base = try asPtr(frame.regs[inst.b]);
                        frame.regs[inst.a] = try self.zone_stack.getCell(base.zone, base.offset + @as(u32, @intCast(inst.imm)));
                    }
                },
                .store_cell => try self.storeCell(frame.regs[inst.a], inst.imm, frame.regs[inst.b]),
                .copy_cells => {
                    // A whole aggregate stored through a pointer to one: it is copied into the
                    // block the pointer points at. A value that is no block of cells (one read
                    // from host memory) is stored as `store_cell` stores it.
                    const dst = zoneBlock(frame.regs[inst.a]);
                    const src = zoneBlock(frame.regs[inst.b]);
                    if (dst != null and src != null) {
                        try self.copyInto(frame.func, dst.?, src.?, @intCast(inst.imm));
                    } else try self.storeCell(frame.regs[inst.a], 0, frame.regs[inst.b]);
                },
                .copy_value => frame.regs[inst.a] = try self.copyValue(frame.func, frame.regs[inst.b], @intCast(inst.imm)),
                .assign_local => {
                    const slot: usize = @intCast(inst.imm);
                    const into = try self.assign(frame.func, frame.locals[slot], frame.regs[inst.b], inst.c, inst.a != 0);
                    if (into) |v| frame.locals[slot] = v;
                },
                .assign_cell => {
                    // In host memory the aggregate is inline: the value is stored there.
                    const cell = frame.regs[inst.a];
                    if (cell == .host_ptr) {
                        try self.storeCell(cell, 0, frame.regs[inst.b]);
                    } else {
                        const at = try asPtr(cell);
                        const have = try self.zone_stack.getCell(at.zone, at.offset);
                        const into = try self.assign(frame.func, have, frame.regs[inst.b], inst.c, inst.imm != 0);
                        if (into) |v| self.zone_stack.setCell(at.zone, at.offset, v) catch |e| return self.writeFailed(e);
                    }
                },
                .zone_fill => {
                    const base = try asPtr(frame.regs[inst.a]);
                    var i: u32 = 0;
                    const n: u32 = @intCast(inst.imm);
                    while (i < n) : (i += 1) {
                        self.zone_stack.setCell(base.zone, base.offset + i, frame.regs[inst.b]) catch |e| return self.writeFailed(e);
                    }
                },
                .index_addr => {
                    const index = frame.regs[inst.c].asI128() orelse return error.TypeMismatch;
                    switch (frame.regs[inst.b]) {
                        .host_buf => |hb| {
                            frame.regs[inst.a] = .{ .host_ptr = .{ .addr = hb.addr + @as(usize, @intCast(index)) * hb.stride, .size = hb.stride } };
                        },
                        // A `[]const u8` constant lives in the compiler's memory: the address of
                        // byte `index` is a real one (up to one past the end, where `s[len..len]`
                        // starts).
                        .string => |s| {
                            const i: usize = std.math.cast(usize, index) orelse return error.TypeMismatch;
                            if (i > s.len) return error.OutOfBounds;
                            frame.regs[inst.a] = .{ .host_ptr = .{ .addr = @intFromPtr(s.ptr) + i, .size = 1 } };
                        },
                        else => {
                            const base = try asPtr(frame.regs[inst.b]);
                            const stride: i128 = @intCast(inst.imm);
                            frame.regs[inst.a] = .{ .ptr = .{ .zone = base.zone, .offset = base.offset + @as(u32, @intCast(index * stride)) } };
                        },
                    }
                },
                .index_load => {
                    // Element read for zone aggregates, host strings, and host bufs.
                    const index = frame.regs[inst.c].asI128() orelse return error.TypeMismatch;
                    switch (frame.regs[inst.b]) {
                        .string => |s| {
                            const i: usize = std.math.cast(usize, index) orelse return error.TypeMismatch;
                            if (i >= s.len) return error.OutOfBounds;
                            frame.regs[inst.a] = .{ .uint = s[i] };
                        },
                        .host_buf => |hb| {
                            frame.regs[inst.a] = hostLoad(hb.addr + @as(usize, @intCast(index)) * hb.stride, hb.stride);
                        },
                        else => {
                            const base = try asPtr(frame.regs[inst.b]);
                            const stride: i128 = @intCast(inst.imm);
                            const off = base.offset + @as(u32, @intCast(index * stride));
                            frame.regs[inst.a] = try self.zone_stack.getCell(base.zone, off);
                        },
                    }
                },
                .block_at => {
                    // An aggregate in a field or an element is a pointer to a block of its own,
                    // and a pointer to the aggregate is that same pointer (`&s` of a local is
                    // `s`). In host memory the aggregate is inline: its address is the cell's.
                    frame.regs[inst.a] = switch (frame.regs[inst.b]) {
                        .host_ptr => frame.regs[inst.b],
                        else => blk: {
                            const cell = try asPtr(frame.regs[inst.b]);
                            break :blk try self.zone_stack.getCell(cell.zone, cell.offset);
                        },
                    };
                },
                .slice_make => {
                    const len = frame.regs[inst.c].asI128() orelse return error.TypeMismatch;
                    if (frame.regs[inst.b] == .host_ptr) {
                        // A slice of a string or of host memory (an arena's bytes) stays in
                        // host memory.
                        const hp = frame.regs[inst.b].host_ptr;
                        frame.regs[inst.a] = .{ .host_buf = .{ .addr = hp.addr, .len = @intCast(len), .stride = hp.size } };
                    } else {
                        const base = try asPtr(frame.regs[inst.b]);
                        frame.regs[inst.a] = .{ .slice = .{
                            .zone = base.zone,
                            .offset = base.offset,
                            .len = @intCast(len),
                        } };
                    }
                },
                .slice_len => {
                    frame.regs[inst.a] = switch (frame.regs[inst.b]) {
                        .slice => |s| .{ .uint = s.len },
                        // `[]const u8` string values carry their own length.
                        .string => |s| .{ .uint = s.len },
                        .host_buf => |hb| .{ .uint = hb.len },
                        else => return error.TypeMismatch,
                    };
                },
                .slice_ptr => {
                    frame.regs[inst.a] = switch (frame.regs[inst.b]) {
                        .host_buf => |hb| .{ .host_ptr = .{ .addr = hb.addr, .size = hb.stride } },
                        .slice => |s| .{ .ptr = .{ .zone = s.zone, .offset = s.offset } },
                        // A `[]const u8` constant already lives in the compiler's own
                        // memory, so its address is a real one the host can read.
                        // `slice_len` has always accepted `.string`; this is the other
                        // half. Without it `s.ptr` traps, which is what stopped any
                        // `#extern` taking a string pointer at comptime.
                        .string => |s| .{ .host_ptr = .{ .addr = @intFromPtr(s.ptr), .size = 1 } },
                        else => return error.TypeMismatch,
                    };
                },
                .halt_msg => {
                    // `compiler_error(msg)`: stash the message and halt the hook.
                    self.compiler_error_msg = switch (frame.regs[inst.a]) {
                        .string => |s| s,
                        else => "compiler hook requested a halt",
                    };
                    return error.Trap;
                },
                .record_remove => {
                    // `compiler_remove(name)`: record a decl name to drop. Does NOT
                    // halt — the hook keeps running and still returns its source.
                    const n = strLen(frame.regs[inst.a]) orelse return error.TypeMismatch;
                    const buf = self.allocator.alloc(u8, n) catch return error.OutOfMemory;
                    try self.copyStrBytes(frame.regs[inst.a], buf);
                    self.compiler_removals.append(self.allocator, buf) catch return error.OutOfMemory;
                },
                .scalar_builtin => frame.regs[inst.a] = computeScalar(
                    @enumFromInt(inst.imm),
                    frame.regs[inst.b],
                    frame.regs[inst.c],
                ) orelse return error.TypeMismatch,
                .host_ptr_make => frame.regs[inst.a] = switch (frame.regs[inst.b]) {
                    // a pointer cast: a pointer into a zone, or null, stays as it is
                    .ptr, .null_ptr => frame.regs[inst.b],
                    else => .{ .host_ptr = .{
                        .addr = asAddr(frame.regs[inst.b]) orelse return error.TypeMismatch,
                        .size = @intCast(inst.imm),
                    } },
                },
                .bits_to_slice => frame.regs[inst.a] = switch (frame.regs[inst.b]) {
                    .uint => |bits| .{ .host_buf = .{
                        .addr = @truncate(bits),
                        .len = @truncate(bits >> 64),
                        .stride = @intCast(inst.imm),
                    } },
                    else => frame.regs[inst.b],
                },
                .host_buf_make => frame.regs[inst.a] = .{ .host_buf = .{
                    .addr = asAddr(frame.regs[inst.b]) orelse return error.TypeMismatch,
                    .len = @intCast(frame.regs[inst.c].asI128() orelse return error.TypeMismatch),
                    .stride = @intCast(inst.imm),
                } },
                .str_concat => {
                    const la = strLen(frame.regs[inst.b]) orelse return error.TypeMismatch;
                    const lb = strLen(frame.regs[inst.c]) orelse return error.TypeMismatch;
                    const buf = self.allocator.alloc(u8, la + lb) catch return error.OutOfMemory;
                    try self.copyStrBytes(frame.regs[inst.b], buf[0..la]);
                    try self.copyStrBytes(frame.regs[inst.c], buf[la..]);
                    self.concat_strings.append(self.allocator, buf) catch return error.OutOfMemory;
                    frame.regs[inst.a] = .{ .string = buf };
                },
                .opt_is_some => frame.regs[inst.a] = .{ .bool = switch (frame.regs[inst.b]) {
                    .null_ptr => false,
                    else => true,
                } },
                .interface_method => {
                    const mod = self.module orelse return error.NoModule;
                    const iface = try asPtr(frame.regs[inst.b]);
                    const vt_cell = try self.zone_stack.getCell(iface.zone, iface.offset + 1);
                    const vt_idx: usize = switch (vt_cell) {
                        .uint => |u| @intCast(u),
                        .int => |i| @intCast(i),
                        else => return error.TypeMismatch,
                    };
                    const method_idx: usize = @intCast(inst.imm);
                    if (vt_idx >= mod.vtables.len) return error.InvalidInstruction;
                    const vt = mod.vtables[vt_idx];
                    if (method_idx >= vt.len) return error.InvalidInstruction;
                    frame.regs[inst.a] = .{ .fn_ref = vt[method_idx] };
                },
                .closure_make => {
                    const env: Value.EnvRef = switch (frame.regs[inst.b]) {
                        .ptr => |p| .{ .cell = p },
                        .host_ptr => |h| .{ .host = h },
                        else => .none,
                    };
                    frame.regs[inst.a] = .{ .closure = .{
                        .fn_idx = @intCast(inst.imm),
                        .takes_env = inst.c != 0,
                        .env = env,
                    } };
                },

                // System
                .sys_print => printValue(frame.regs[inst.a]),
                .sys_write => {
                    const data = frame.regs[inst.b];
                    const len = strLen(data) orelse return error.TypeMismatch;
                    const bytes = self.allocator.alloc(u8, len) catch return error.OutOfMemory;
                    defer self.allocator.free(bytes);
                    try self.copyStrBytes(data, bytes);
                    std.debug.print("{s}", .{bytes});
                    frame.regs[inst.a] = .{ .uint = len };
                },
                .sys_mem => {
                    const args = frame.regs[inst.b .. inst.b + inst.c];
                    frame.regs[inst.a] = hostMemory(@enumFromInt(inst.imm), args);
                },
                .trap => {
                    if (inst.imm == instructions.unrunnable_trap) {
                        self.needs_runtime = true;
                        self.setErrorMsg("the comptime VM cannot run `{s}`", .{frame.func.name}, "the comptime VM cannot run a function this code calls");
                    }
                    if (inst.imm == instructions.global_write_trap) {
                        self.needs_runtime = true;
                        self.compiler_error_msg = global_write_message;
                    }
                    return error.Trap;
                },
                .host_call => {
                    const h = self.host orelse return error.InvalidInstruction;
                    const base: usize = inst.b;
                    const argc: usize = inst.c;
                    const args = frame.regs[base .. base + argc];
                    frame.regs[inst.a] = h.call(h.ctx, @intCast(inst.imm), args);
                },
            }
        }

        // Fell off the end without an explicit terminator.
        self.zone_stack.popTo(frame.zone_watermark);
        return .void;
    }
};

/// `v` wrapped to an integer type of `bits` bits, two's complement: the value that type holds after
/// a wrapping operation, a shift, or a cast. The VM computes in 128 bits, so without this a `u32`
/// that wrapped would keep its high bits and a later `>>` would shift them back into the number.
fn narrowInt(v: i128, bits: u16, signed: bool) i128 {
    if (bits == 0 or bits >= 128) return v;
    const shift: u7 = @intCast(128 - bits);
    const raw: u128 = @bitCast(v);
    const high_aligned: i128 = @bitCast(raw << shift);
    return if (signed) high_aligned >> shift else @bitCast(@as(u128, @bitCast(high_aligned)) >> shift);
}

fn asPtr(v: Value) VmError!Value.Ptr {
    return switch (v) {
        .ptr => |p| p,
        .struct_ref => |r| .{ .zone = r.zone, .offset = r.offset },
        .slice => |s| .{ .zone = s.zone, .offset = s.offset },
        else => error.TypeMismatch,
    };
}

/// Are `a` and `b` the same integer (an enum's tag)?
fn sameInt(a: Value, b: Value) bool {
    const x = a.asI128() orelse return false;
    const y = b.asI128() orelse return false;
    return x == y;
}

/// Shape `index` of `func`.
fn shapeIn(func: *const BytecodeFunction, index: u32) VmError!instructions.Shape {
    if (index >= func.shapes.len) return error.InvalidInstruction;
    return func.shapes[index];
}

/// The parts of a value (`Vm.partsOf`), in the order of their cells: the parts of a struct, or
/// the one part of every element of an array (`count` of them, `stride` cells apart).
const Parts = struct {
    list: []const instructions.ShapePart = &.{},
    count: u32 = 1,
    stride: u32 = 0,
    elem: u32 = 0,
    i: usize = 0,

    fn next(self: *Parts) ?instructions.ShapePart {
        if (self.list.len == 0) return null;
        if (self.stride != 0) {
            if (self.elem >= self.count) return null;
            const part: instructions.ShapePart = .{ .cell = self.elem * self.stride, .shape = self.list[0].shape };
            self.elem += 1;
            return part;
        }
        if (self.i >= self.list.len) return null;
        self.i += 1;
        return self.list[self.i - 1];
    }
};

/// The zone block a value points at, or null when it is no pointer into a zone.
fn zoneBlock(v: Value) ?Value.Ptr {
    return switch (v) {
        .ptr => |p| p,
        .struct_ref => |r| .{ .zone = r.zone, .offset = r.offset },
        else => null,
    };
}

/// A raw host address from an int/uint/host pointer (for `ptr_from_int` etc.).
fn asAddr(v: Value) ?usize {
    return switch (v) {
        .uint => |u| std.math.cast(usize, u),
        .int => |i| std.math.cast(usize, i),
        .host_ptr => |hp| hp.addr,
        .null_ptr => 0,
        else => null,
    };
}

/// Compute a `core::` math/`count_ones` fold at comptime (the `scalar_builtin`
/// opcode). Float ops return `.float`; int ops return `.int`. Returns null on a
/// non-numeric operand (caller traps).
fn computeScalar(op: instructions.ScalarOp, a: Value, b: Value) ?Value {
    switch (op) {
        .sqrt, .floor, .ceil, .round, .trunc, .sin, .cos => {
            const x = a.asF64() orelse return null;
            return .{ .float = switch (op) {
                .sqrt => @sqrt(x),
                .floor => @floor(x),
                .ceil => @ceil(x),
                .round => @round(x),
                .trunc => @trunc(x),
                .sin => @sin(x),
                .cos => @cos(x),
                else => unreachable,
            } };
        },
        .pow => return .{ .float = std.math.pow(f64, a.asF64() orelse return null, b.asF64() orelse return null) },
        .min, .max => {
            if (a == .float or b == .float) {
                const x = a.asF64() orelse return null;
                const y = b.asF64() orelse return null;
                return .{ .float = if (op == .min) @min(x, y) else @max(x, y) };
            }
            const x = a.asI128() orelse return null;
            const y = b.asI128() orelse return null;
            return .{ .int = if (op == .min) @min(x, y) else @max(x, y) };
        },
        .abs => {
            if (a == .float) return .{ .float = @abs(a.float) };
            const x = a.asI128() orelse return null;
            return .{ .int = if (x < 0) -x else x };
        },
        .count_ones => {
            const u: u128 = switch (a) {
                .uint => |v| v,
                .int => |v| @bitCast(v),
                else => return null,
            };
            return .{ .int = @popCount(u) };
        },
    }
}

/// Read `size` (1–16) bytes of real host memory at `addr` as a little-endian uint.
fn hostLoad(addr: usize, size: u32) Value {
    if (addr == 0) return .{ .uint = 0 };
    const p: [*]const u8 = @ptrFromInt(addr);
    var v: u128 = 0;
    var i: u32 = 0;
    while (i < size and i < 16) : (i += 1) v |= @as(u128, p[i]) << @intCast(i * 8);
    return .{ .uint = v };
}

/// Write the low `size` bytes of `val` to real host memory at `addr`.
fn hostStore(addr: usize, size: u32, val: Value) void {
    if (addr == 0) return;
    const p: [*]u8 = @ptrFromInt(addr);
    const v: u128 = switch (val) {
        .uint => |x| x,
        .int => |x| @bitCast(x),
        .host_ptr => |hp| hp.addr,
        .bool => |b| @intFromBool(b),
        // a slice is its address and its length, as in compiled code
        .string => |s| @as(u128, @intFromPtr(s.ptr)) | (@as(u128, s.len) << 64),
        .host_buf => |hb| @as(u128, hb.addr) | (@as(u128, hb.len) << 64),
        else => 0,
    };
    var i: u32 = 0;
    while (i < size and i < 16) : (i += 1) p[i] = @truncate(v >> @intCast(i * 8));
}

fn constName(consts: []const Value, imm: i64) []const u8 {
    if (imm < 0 or imm >= consts.len) return "<zone>";
    return switch (consts[@intCast(imm)]) {
        .string => |s| s,
        else => "<zone>",
    };
}

fn printValue(v: Value) void {
    switch (v) {
        .int => |x| std.debug.print("{d}\n", .{x}),
        .uint => |x| std.debug.print("{d}\n", .{x}),
        .float => |x| std.debug.print("{d}\n", .{x}),
        .bool => |x| std.debug.print("{}\n", .{x}),
        .string => |x| std.debug.print("{s}\n", .{x}),
        else => std.debug.print("{any}\n", .{v}),
    }
}

// -- Caps ------------------------------------------------------------------
//
// The capability gate is the structural answer to the `build.rs` surface, so it
// is worth testing directly rather than only through a compile that must fail.

test "a pure run denies host calls but can still allocate" {
    const pure = Caps{};
    try std.testing.expect(!pure.allowsFfi("kernel32", "MulDiv"));
    try std.testing.expect(!pure.allowsFfi("user32", "MessageBoxA"));
    // The comptime heap has to keep working inside a pure `#run`.
    for (Caps.heap_primitives) |p| {
        try std.testing.expect(pure.allowsFfi("kernel32", p));
    }
}

test "an allowlist grant admits only the libraries it names" {
    const caps = Caps{ .ffi = .{ .libs = &.{"kernel32"} } };
    try std.testing.expect(caps.allowsFfi("kernel32", "MulDiv"));
    // Windows DLL names are case-insensitive, so the match must be too.
    try std.testing.expect(caps.allowsFfi("KERNEL32", "MulDiv"));
    try std.testing.expect(caps.allowsFfi("Kernel32", "MulDiv"));
    try std.testing.expect(!caps.allowsFfi("user32", "MessageBoxA"));
}

test "the privileged root admits everything" {
    const root = Caps{ .ffi = .all };
    try std.testing.expect(root.allowsFfi("kernel32", "MulDiv"));
    try std.testing.expect(root.allowsFfi("anything", "at_all"));
}

test "narrowing can never widen a grant" {
    const none = Caps{};
    const all = Caps{ .ffi = .all };
    const k32 = Caps{ .ffi = .{ .libs = &.{"kernel32"} } };
    const both = Caps{ .ffi = .{ .libs = &.{ "kernel32", "user32" } } };
    const u32_only = Caps{ .ffi = .{ .libs = &.{"user32"} } };

    // Nothing a callee asks for can escape a pure caller.
    try std.testing.expect(!none.narrow(all).allowsFfi("kernel32", "MulDiv"));
    try std.testing.expect(!none.narrow(k32).allowsFfi("kernel32", "MulDiv"));

    // The root hands over exactly what was requested, no more.
    try std.testing.expect(all.narrow(k32).allowsFfi("kernel32", "MulDiv"));
    try std.testing.expect(!all.narrow(k32).allowsFfi("user32", "MessageBoxA"));
    try std.testing.expect(!all.narrow(none).allowsFfi("kernel32", "MulDiv"));

    // A subset request narrows; asking for more than you hold does not widen.
    try std.testing.expect(!both.narrow(k32).allowsFfi("user32", "MessageBoxA"));
    try std.testing.expect(both.narrow(k32).allowsFfi("kernel32", "MulDiv"));
    try std.testing.expect(!k32.narrow(both).allowsFfi("user32", "MessageBoxA"));
    try std.testing.expect(!k32.narrow(all).allowsFfi("user32", "MessageBoxA"));

    // Disjoint allowlists fail closed rather than guessing an intersection.
    try std.testing.expect(!k32.narrow(u32_only).allowsFfi("kernel32", "MulDiv"));
    try std.testing.expect(!k32.narrow(u32_only).allowsFfi("user32", "MessageBoxA"));

    // Narrowing never disturbs the heap primitives.
    try std.testing.expect(none.narrow(none).allowsFfi("kernel32", "VirtualAlloc"));
}
