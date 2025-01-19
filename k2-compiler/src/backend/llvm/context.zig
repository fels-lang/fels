/// ModuleCg — owns the LLVM context, module, and builder for one compilation unit.
const std = @import("std");
const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const variants = @import("variants.zig");

/// One entry in a struct's field table.
pub const StructField = struct {
    name: []const u8,
    ir_ty: ir.IrType,
};

pub const ModuleCg = struct {
    allocator: std.mem.Allocator,
    ctx: llvm.LLVMContextRef,
    mod: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,

    /// Named LLVM struct types keyed by K2 struct name.
    struct_types: std.StringHashMap(llvm.LLVMTypeRef),
    /// Field name/type lists for each named struct.  Used for field-index lookup.
    struct_fields: std.StringHashMap([]StructField),
    /// Declared LLVM functions, keyed by mangled/extern name.
    fn_decls: std.StringHashMap(llvm.LLVMValueRef),
    /// Declared globals, keyed by name.
    global_decls: std.StringHashMap(llvm.LLVMValueRef),
    /// Cached { ptr, usize } slice struct type — created once on first use.
    slice_type: ?llvm.LLVMTypeRef = null,
    interface_type: ?llvm.LLVMTypeRef = null,
    /// Per-enum metadata (discriminants, LLVM type).
    enum_meta: std.StringHashMap(*variants.EnumMeta),
    /// Counter for unique string-literal global names.
    string_counter: u32 = 0,
    /// Error type definitions from the IR module — used for discriminant lookup.
    error_defs: []const ir.ErrorDef = &.{},
    /// Optimisation level (0 = debug). Debug builds insert runtime safety checks.
    opt_level: u2 = 0,

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

    /// Records an internal codegen-invariant violation. Prints a diagnostic
    /// (prefixed so it's recognisable as an internal compiler error, not a
    /// user-facing diagnostic) and marks the module as unlowerable. Safe to
    /// call multiple times — only the first few are printed to avoid spam.
    pub fn recordLoweringError(self: *ModuleCg, comptime fmt: []const u8, args: anytype) void {
        if (!self.lowering_failed) {
            std.debug.print("k2: internal codegen error: " ++ fmt ++ "\n", args);
        }
        self.lowering_failed = true;
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
            .fn_decls = std.StringHashMap(llvm.LLVMValueRef).init(allocator),
            .global_decls = std.StringHashMap(llvm.LLVMValueRef).init(allocator),
            .enum_meta = std.StringHashMap(*variants.EnumMeta).init(allocator),
        };
    }

    pub fn deinit(self: *ModuleCg) void {
        // Free field lists
        var it = self.struct_fields.valueIterator();
        while (it.next()) |v| self.allocator.free(v.*);
        self.struct_fields.deinit();

        self.struct_types.deinit();
        self.fn_decls.deinit();
        self.global_decls.deinit();
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

    /// Return (and cache) the `{ ptr, usize }` LLVM struct used for all K2 slices.
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

    /// Find the zero-based index of a named field in a struct.
    /// Returns null if the struct or field is unknown.
    pub fn fieldIndex(self: *ModuleCg, struct_name: []const u8, field_name: []const u8) ?u32 {
        const fields = self.struct_fields.get(struct_name) orelse return null;
        for (fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, field_name)) return @intCast(i);
        }
        return null;
    }

    /// Return the discriminant (1-based) for a named error variant.
    /// Returns 1 as a safe fallback if the type or variant isn't found.
    pub fn errorDiscriminant(self: *const ModuleCg, error_type_name: []const u8, variant_name: []const u8) u32 {
        for (self.error_defs) |def| {
            if (!std.mem.eql(u8, def.name, error_type_name)) continue;
            for (def.variants, 0..) |v, i| {
                if (std.mem.eql(u8, v.name, variant_name)) return @intCast(i + 1);
            }
        }
        return 1; // safe fallback — any non-zero value signals an error
    }
};
