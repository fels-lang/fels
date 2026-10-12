/// ModuleCg — owns the LLVM context, module, and builder for one compilation unit.
const std = @import("std");
const layout_mod = @import("../../layout.zig");
const builtin = @import("builtin");
const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const variants = @import("variants.zig");
const abi = @import("abi.zig");
const emit = @import("emit.zig");
pub const debug_mod = @import("debug.zig");

/// Windows x64 stack-probe stub. LLVM emits `call __chkstk` in the prologue of any
/// function whose frame exceeds one page (4 KiB); the CRT that normally supplies
/// `__chkstk` isn't linked in Fels's minimal-runtime setup, so we provide it. This is
/// the standard probe-only routine (AT&T): it touches each page of the frame to
/// grow the guard page correctly, preserves RAX/RCX, and lets the caller do the
/// actual `sub rsp, rax`. Emitted weak so future multi-object links don't collide.
const chkstk_x64_asm =
    \\.weak __chkstk
    \\__chkstk:
    \\  push %rcx
    \\  push %rax
    \\  cmp $0x1000, %rax
    \\  lea 24(%rsp), %rcx
    \\  jb 1f
    \\2:
    \\  sub $0x1000, %rcx
    \\  test %rcx, (%rcx)
    \\  sub $0x1000, %rax
    \\  cmp $0x1000, %rax
    \\  ja 2b
    \\1:
    \\  sub %rax, %rcx
    \\  test %rcx, (%rcx)
    \\  pop %rax
    \\  pop %rcx
    \\  ret
    \\
;

/// The C library's memory functions, which LLVM's optimiser and code generator call on their
/// own: a copy loop becomes `memcpy`, a zeroing loop `memset`, a chain of compares `memcmp`
/// or `bcmp`, a large aggregate copy `memcpy`. Fels links no C library, so the program
/// carries them, as Zig's and Rust's runtimes do. Each is weak: a C library linked in brings
/// its own, and the linker takes that one. `rep movsb`/`rep stosb` are what the CPU copies and
/// fills fastest with for the sizes that reach a call (smaller constant sizes are inlined).
/// AT&T; one per calling convention, as the arguments come in different registers.
const MemStub = struct { name: [:0]const u8, windows: []const u8, sysv: []const u8 };

const mem_stubs = [_]MemStub{
    .{
        .name = "memcpy",
        // rdi and rsi are the caller's on Windows, so they are kept in r9 and r10.
        .windows =
        \\  mov %rcx, %rax
        \\  mov %rdi, %r9
        \\  mov %rsi, %r10
        \\  mov %rcx, %rdi
        \\  mov %rdx, %rsi
        \\  mov %r8, %rcx
        \\  rep movsb
        \\  mov %r9, %rdi
        \\  mov %r10, %rsi
        \\  ret
        \\
        ,
        .sysv =
        \\  mov %rdi, %rax
        \\  mov %rdx, %rcx
        \\  rep movsb
        \\  ret
        \\
        ,
    },
    .{
        .name = "memmove",
        // Forwards unless the destination starts inside the source; then backwards, from the
        // last byte, with the direction flag set and cleared again.
        .windows =
        \\  mov %rcx, %rax
        \\  mov %rdi, %r9
        \\  mov %rsi, %r10
        \\  mov %rcx, %rdi
        \\  mov %rdx, %rsi
        \\  mov %r8, %rcx
        \\  mov %rdi, %r11
        \\  sub %rsi, %r11
        \\  cmp %rcx, %r11
        \\  jb 1f
        \\  rep movsb
        \\  jmp 2f
        \\1:
        \\  lea -1(%rsi,%rcx), %rsi
        \\  lea -1(%rdi,%rcx), %rdi
        \\  std
        \\  rep movsb
        \\  cld
        \\2:
        \\  mov %r9, %rdi
        \\  mov %r10, %rsi
        \\  ret
        \\
        ,
        .sysv =
        \\  mov %rdi, %rax
        \\  mov %rdx, %rcx
        \\  mov %rdi, %r8
        \\  sub %rsi, %r8
        \\  cmp %rcx, %r8
        \\  jb 1f
        \\  rep movsb
        \\  ret
        \\1:
        \\  lea -1(%rsi,%rcx), %rsi
        \\  lea -1(%rdi,%rcx), %rdi
        \\  std
        \\  rep movsb
        \\  cld
        \\  ret
        \\
        ,
    },
    .{
        .name = "memset",
        .windows =
        \\  mov %rcx, %r9
        \\  mov %rdi, %r10
        \\  mov %rcx, %rdi
        \\  mov %edx, %eax
        \\  mov %r8, %rcx
        \\  rep stosb
        \\  mov %r10, %rdi
        \\  mov %r9, %rax
        \\  ret
        \\
        ,
        .sysv =
        \\  mov %rdi, %r8
        \\  mov %esi, %eax
        \\  mov %rdx, %rcx
        \\  rep stosb
        \\  mov %r8, %rax
        \\  ret
        \\
        ,
    },
    .{
        .name = "memcmp",
        // `repe cmpsb` stops past the first byte that differs; the result is the difference
        // of those two bytes, as unsigned values, or 0.
        .windows =
        \\  mov %rdi, %r9
        \\  mov %rsi, %r10
        \\  mov %rcx, %rsi
        \\  mov %rdx, %rdi
        \\  mov %r8, %rcx
        \\  xor %eax, %eax
        \\  test %rcx, %rcx
        \\  je 1f
        \\  repe cmpsb
        \\  je 1f
        \\  movzbl -1(%rsi), %eax
        \\  movzbl -1(%rdi), %edx
        \\  sub %edx, %eax
        \\1:
        \\  mov %r9, %rdi
        \\  mov %r10, %rsi
        \\  ret
        \\
        ,
        .sysv =
        \\  mov %rdx, %rcx
        \\  xor %eax, %eax
        \\  test %rcx, %rcx
        \\  je 1f
        \\  repe cmpsb
        \\  je 1f
        \\  movzbl -1(%rdi), %eax
        \\  movzbl -1(%rsi), %ecx
        \\  sub %ecx, %eax
        \\1:
        \\  ret
        \\
        ,
    },
};

/// `bcmp` only says whether the bytes differ: `memcmp` answers that too.
const all_mem_stubs = mem_stubs ++ [_]MemStub{.{ .name = "bcmp", .windows = mem_stubs[3].windows, .sysv = mem_stubs[3].sysv }};

/// One entry in a struct's field table.
pub const StructField = struct {
    name: []const u8,
    ir_ty: ir.IrType,
};

/// A field of a bit-packed struct reached through a pointer: its first byte, and for an
/// integer the bits of the `span` bytes from there that hold it.
pub const BitRef = struct {
    ptr: llvm.LLVMValueRef,
    /// A field of whole bytes, loaded and stored as its type at `ptr` (byte-aligned).
    whole: bool,
    shift: u64 = 0,
    bits: u64 = 0,
    span: u64 = 0,
    /// An `iN` field: read back sign-extended.
    signed: bool = false,

    /// Where field `place` of a bit-packed struct is, its first byte at `ptr`; `ty` is the
    /// field's type.
    pub fn of(ptr: llvm.LLVMValueRef, place: layout_mod.BitPlace, ty: @import("../../ir.zig").IrType) BitRef {
        if (!place.int or (place.bit % 8 == 0 and place.bits % 8 == 0)) return .{ .ptr = ptr, .whole = true };
        return .{
            .ptr = ptr,
            .whole = false,
            .shift = place.bit % 8,
            .bits = place.bits,
            .span = (place.bit % 8 + place.bits + 7) / 8,
            .signed = ty == .i,
        };
    }
};

pub const ModuleCg = struct {
    allocator: std.mem.Allocator,
    ctx: llvm.LLVMContextRef,
    mod: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,

    /// Named LLVM struct types keyed by Fels struct name.
    struct_types: std.StringHashMap(llvm.LLVMTypeRef),
    /// Field name/type lists for each named struct.  Used for field-index lookup.
    struct_fields: std.StringHashMap([]StructField),
    struct_alignments: std.StringHashMap(u32),
    /// The structs that are `union`s.
    struct_unions: std.StringHashMap(void),
    /// The bit-packed structs (`layout.isBitPacked`): where each field sits, by field index.
    struct_bits: std.StringHashMap([]const layout_mod.BitPlace),
    /// Declared LLVM functions, keyed by mangled/extern name.
    fn_decls: std.StringHashMap(llvm.LLVMValueRef),
    /// Own LLVM function type of a declaration that shares another's LLVM function
    /// (several `#extern` bindings of one C symbol). Absent for every declaration
    /// that owns its function, whose type is read off the function itself.
    fn_types: std.StringHashMap(llvm.LLVMTypeRef),
    /// C-ABI lowering for `#extern` functions whose by-value aggregate params or
    /// return need Win64 coercion. Keyed by function name; consulted at call
    /// sites. Only non-trivial signatures are recorded (scalar externs stay on
    /// the fast path). See `abi.zig`.
    fn_abi: std.StringHashMap(abi.FnAbi),
    /// Declared globals, keyed by name.
    global_decls: std.StringHashMap(llvm.LLVMValueRef),
    /// IrType of each global — so field/index access on a `.global` base (e.g.
    /// `STRING_CONST.len`) can find the base's shape. Without it `irTypeOf`
    /// returns null for globals and the access lowers to `undef`.
    global_ir_types: std.StringHashMap(ir.IrType),
    /// Cached { ptr, usize } slice struct type — created once on first use.
    slice_type: ?llvm.LLVMTypeRef = null,
    interface_type: ?llvm.LLVMTypeRef = null,
    closure_type: ?llvm.LLVMTypeRef = null,
    /// Cache of forwarding thunks `__thunk_<fn>` generated for plain functions
    /// used as closure values (so they accept the leading `__env` arg).
    closure_thunks: std.StringHashMap(llvm.LLVMValueRef) = undefined,
    /// Per-enum metadata (discriminants, LLVM type).
    enum_meta: std.StringHashMap(*variants.EnumMeta),
    /// Counter for unique string-literal global names.
    string_counter: u32 = 0,
    /// Cached target data for size/alignment queries during lowering (the
    /// module's real data layout isn't stamped on until just before emit).
    /// Lazily created by `targetData`.
    target_data: ?llvm.LLVMTargetDataRef = null,
    /// Optimisation level (0 = debug).
    opt_level: u2 = 0,
    /// Insert the runtime safety checks: index bounds, null pointers, integer overflow,
    /// division by zero and shift amounts. On at every opt level unless the build asks for
    /// none (`release_fast`, `--unchecked`); they used to come with `-O0` only, so a release
    /// build indexed past the end of a slice without a word.
    safety: bool = true,
    /// The OS we are generating code for. Defaults to the host; overridden by
    /// `--target` for cross-compilation. Drives the entry point, `__chkstk`, and
    /// `_fltused`.
    target_os: std.Target.Os.Tag = @import("builtin").os.tag,
    /// `--no-entry`: emit no platform entry-point wrapper (`mainCRTStartup`). For
    /// compiling a library object to embed in another binary (e.g. felsld into fels).
    no_entry: bool = false,
    /// The object of a static library: only `#export`ed symbols stay visible, so the
    /// runtime it carries does not clash with the program that links it.
    library_object: bool = false,
    /// Debug info (`-g`); null without.
    debug: ?debug_mod.DebugCg = null,

    /// Set when an internal lowering invariant is violated (e.g. a value's
    /// actual LLVM shape doesn't match what an instruction lowering assumed —
    /// the exact class of bug that previously caused segfaults inside
    /// `LLVMBuildExtractValue`/`InsertValue` on malformed-but-typeable IR).
    ///
    /// Lowering helpers that detect such a mismatch should call
    /// `recordLoweringError` and return a placeholder (e.g. `null`/`undef`)
    /// rather than handing LLVM a value whose shape it doesn't expect — LLVM's
    /// C API does not gracefully reject shape mismatches, it asserts/crashes.
    /// `LlvmBackend.lower` checks this flag once lowering completes and turns
    /// it into a normal `error.LoweringFailed` instead of a process crash.
    lowering_failed: bool = false,

    /// Records an internal codegen-invariant violation.  Prints the message
    /// and the Zig compiler source location so bug reports are actionable.
    /// Safe to call multiple times; only the first call prints.
    pub fn recordLoweringError(
        self: *ModuleCg,
        comptime fmt: []const u8,
        args: anytype,
        comptime src: std.builtin.SourceLocation,
    ) void {
        if (!self.lowering_failed) {
            std.debug.print("fels: internal compiler error: " ++ fmt ++ "\n", args);
            std.debug.print("    [at {s}:{d} in {s}]\n", .{ src.file, src.line, src.fn_name });
        }
        self.lowering_failed = true;
    }

    /// Append the target's required compiler stubs as module-level inline asm.
    /// Windows x64 needs `__chkstk` (large-frame stack probe) since the CRT that
    /// normally supplies it isn't linked. Linux needs nothing here. Call once the
    /// target OS is set, before emission.
    pub fn applyTargetStubs(self: *ModuleCg) void {
        // A static library's object calls the `__chkstk` of the program that links it.
        if (self.library_object) return;
        if (self.target_os == .windows and builtin.target.cpu.arch == .x86_64)
            llvm.LLVMAppendModuleInlineAsm(self.mod, chkstk_x64_asm.ptr, chkstk_x64_asm.len);
    }

    /// Append the C library's memory functions (`mem_stubs`) that LLVM may call, once the
    /// module's own functions are all in and before it is optimised. A name the program
    /// already has, as a function of its own or one it imports, is left to the program. A
    /// static library's object leaves them all to the program that links it.
    pub fn applyMemoryStubs(self: *ModuleCg) void {
        if (self.library_object or builtin.target.cpu.arch != .x86_64) return;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.allocator);
        text.appendSlice(self.allocator, ".text\n") catch return;
        inline for (all_mem_stubs) |stub| {
            if (llvm.LLVMGetNamedFunction(self.mod, stub.name.ptr) == null and llvm.LLVMGetNamedGlobal(self.mod, stub.name.ptr) == null) {
                const body = if (self.target_os == .windows) stub.windows else stub.sysv;
                const head = if (self.target_os == .windows)
                    ".weak " ++ stub.name ++ "\n" ++ stub.name ++ ":\n"
                else
                    ".weak " ++ stub.name ++ "\n.type " ++ stub.name ++ ",@function\n" ++ stub.name ++ ":\n";
                text.appendSlice(self.allocator, head) catch return;
                text.appendSlice(self.allocator, body) catch return;
            }
        }
        llvm.LLVMAppendModuleInlineAsm(self.mod, text.items.ptr, text.items.len);
    }

    pub fn init(allocator: std.mem.Allocator, module_name: [*:0]const u8) ModuleCg {
        const ctx = llvm.LLVMContextCreate();
        const mod = llvm.LLVMModuleCreateWithNameInContext(module_name, ctx);
        const builder = llvm.LLVMCreateBuilderInContext(ctx);
        return .{
            .allocator = allocator,
            .ctx = ctx,
            .mod = mod,
            .builder = builder,
            .struct_types = std.StringHashMap(llvm.LLVMTypeRef).init(allocator),
            .struct_fields = std.StringHashMap([]StructField).init(allocator),
            .struct_alignments = std.StringHashMap(u32).init(allocator),
            .struct_unions = std.StringHashMap(void).init(allocator),
            .struct_bits = std.StringHashMap([]const layout_mod.BitPlace).init(allocator),
            .fn_decls = std.StringHashMap(llvm.LLVMValueRef).init(allocator),
            .fn_types = std.StringHashMap(llvm.LLVMTypeRef).init(allocator),
            .fn_abi = std.StringHashMap(abi.FnAbi).init(allocator),
            .global_decls = std.StringHashMap(llvm.LLVMValueRef).init(allocator),
            .global_ir_types = std.StringHashMap(ir.IrType).init(allocator),
            .enum_meta = std.StringHashMap(*variants.EnumMeta).init(allocator),
            .closure_thunks = std.StringHashMap(llvm.LLVMValueRef).init(allocator),
        };
    }

    /// Target data for size/alignment queries, created lazily and cached: the layout of
    /// the target the module is emitted for. (The empty layout string is not it: there an
    /// `i64` is 4-aligned, so `{ i32, i64 }` measured 12 bytes instead of 16.)
    pub fn targetData(self: *ModuleCg) llvm.LLVMTargetDataRef {
        if (self.target_data) |td| return td;
        const td = if (emit.TargetMachine.initTarget(self.target_os, 0)) |tm| blk: {
            defer tm.deinit();
            break :blk llvm.LLVMCreateTargetDataLayout(tm.tm);
        } else |_| llvm.LLVMCreateTargetData("");
        self.target_data = td;
        return td;
    }

    pub fn deinit(self: *ModuleCg) void {
        if (self.debug) |*d| d.deinit();
        // Free field lists
        var it = self.struct_fields.valueIterator();
        while (it.next()) |v| self.allocator.free(v.*);
        self.struct_fields.deinit();

        self.struct_types.deinit();
        self.struct_alignments.deinit();
        self.struct_unions.deinit();
        var bits_it = self.struct_bits.valueIterator();
        while (bits_it.next()) |v| self.allocator.free(v.*);
        self.struct_bits.deinit();
        self.fn_decls.deinit();
        self.fn_types.deinit();
        self.closure_thunks.deinit();
        var abi_it = self.fn_abi.valueIterator();
        while (abi_it.next()) |v| v.deinit(self.allocator);
        self.fn_abi.deinit();
        if (self.target_data) |td| llvm.LLVMDisposeTargetData(td);
        self.global_decls.deinit();
        self.global_ir_types.deinit();
        var em_it = self.enum_meta.valueIterator();
        while (em_it.next()) |v| {
            v.*.discriminants.deinit();
            self.allocator.destroy(v.*);
        }
        self.enum_meta.deinit();
        llvm.LLVMDisposeBuilder(self.builder);
        llvm.LLVMDisposeModule(self.mod);
        llvm.LLVMContextDispose(self.ctx);
    }

    /// Return (and cache) the `{ ptr, usize }` LLVM struct used for all Fels slices.
    pub fn getSliceType(self: *ModuleCg) llvm.LLVMTypeRef {
        if (self.slice_type) |st| return st;
        var fields = [_]llvm.LLVMTypeRef{
            llvm.LLVMPointerTypeInContext(self.ctx, 0), // .ptr
            llvm.LLVMInt64TypeInContext(self.ctx), // .len
        };
        const st = llvm.LLVMStructTypeInContext(self.ctx, &fields, 2, 0);
        self.slice_type = st;
        return st;
    }

    pub fn getInterfaceType(self: *ModuleCg) llvm.LLVMTypeRef {
        if (self.interface_type) |st| return st;
        var fields = [_]llvm.LLVMTypeRef{
            llvm.LLVMPointerTypeInContext(self.ctx, 0),
            llvm.LLVMPointerTypeInContext(self.ctx, 0),
        };
        const st = llvm.LLVMStructTypeInContext(self.ctx, &fields, 2, 0);
        self.interface_type = st;
        return st;
    }

    /// A function value is a fat closure `{ fn: ptr, env: ptr }` — `fn` is the
    /// raw function (or thunk) pointer, `env` the captured environment (null when
    /// there are no captures). Lets every fn-value flow uniformly and lets a
    /// higher-order function accept a closure where a plain fn pointer once went.
    pub fn getClosureType(self: *ModuleCg) llvm.LLVMTypeRef {
        if (self.closure_type) |st| return st;
        var fields = [_]llvm.LLVMTypeRef{
            llvm.LLVMPointerTypeInContext(self.ctx, 0), // .fn
            llvm.LLVMPointerTypeInContext(self.ctx, 0), // .env
        };
        const st = llvm.LLVMStructTypeInContext(self.ctx, &fields, 2, 0);
        self.closure_type = st;
        return st;
    }

    /// Find the zero-based index of a named field in a struct.
    /// Returns null if the struct or field is unknown.
    /// Whether the struct `name` is a `union` (its fields all at offset 0).
    pub fn isUnion(self: *ModuleCg, name: []const u8) bool {
        return self.struct_unions.contains(name);
    }

    /// Where the fields of the struct `name` sit when it is bit-packed; null for any other.
    pub fn bitPlaces(self: *ModuleCg, name: []const u8) ?[]const layout_mod.BitPlace {
        return self.struct_bits.get(name);
    }

    pub fn fieldIndex(self: *ModuleCg, struct_name: []const u8, field_name: []const u8) ?u32 {
        const fields = self.struct_fields.get(struct_name) orelse return null;
        for (fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, field_name)) return @intCast(i);
        }
        return null;
    }
};
