/// ModuleCg — owns the LLVM context, module, and builder for one compilation unit.
const std   = @import("std");
const ir    = @import("../../ir.zig");
const llvm  = @import("c_api.zig").llvm;

/// One entry in a struct's field table.
pub const StructField = struct {
    name: []const u8,
    ir_ty: ir.IrType,
};

pub const ModuleCg = struct {
    allocator: std.mem.Allocator,
    ctx:       llvm.LLVMContextRef,
    mod:       llvm.LLVMModuleRef,
    builder:   llvm.LLVMBuilderRef,

    /// Named LLVM struct types keyed by K2 struct name.
    struct_types:  std.StringHashMap(llvm.LLVMTypeRef),
    /// Field name/type lists for each named struct.  Used for field-index lookup.
    struct_fields: std.StringHashMap([]StructField),
    /// Declared LLVM functions, keyed by mangled/extern name.
    fn_decls:      std.StringHashMap(llvm.LLVMValueRef),
    /// Declared globals, keyed by name.
    global_decls:  std.StringHashMap(llvm.LLVMValueRef),
    /// Cached { ptr, usize } slice struct type — created once on first use.
    slice_type:    ?llvm.LLVMTypeRef = null,
    /// Counter for unique string-literal global names.
    string_counter: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, module_name: [*:0]const u8) ModuleCg {
        const ctx     = llvm.LLVMContextCreate();
        const mod     = llvm.LLVMModuleCreateWithNameInContext(module_name, ctx);
        const builder = llvm.LLVMCreateBuilderInContext(ctx);
        return .{
            .allocator     = allocator,
            .ctx           = ctx,
            .mod           = mod,
            .builder       = builder,
            .struct_types  = std.StringHashMap(llvm.LLVMTypeRef).init(allocator),
            .struct_fields = std.StringHashMap([]StructField).init(allocator),
            .fn_decls      = std.StringHashMap(llvm.LLVMValueRef).init(allocator),
            .global_decls  = std.StringHashMap(llvm.LLVMValueRef).init(allocator),
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
        llvm.LLVMDisposeBuilder(self.builder);
        llvm.LLVMDisposeModule(self.mod);
        llvm.LLVMContextDispose(self.ctx);
    }

    /// Return (and cache) the `{ ptr, usize }` LLVM struct used for all K2 slices.
    pub fn getSliceType(self: *ModuleCg) llvm.LLVMTypeRef {
        if (self.slice_type) |st| return st;
        var fields = [_]llvm.LLVMTypeRef{
            llvm.LLVMPointerTypeInContext(self.ctx, 0), // .ptr
            llvm.LLVMInt64TypeInContext(self.ctx),       // .len
        };
        const st = llvm.LLVMStructTypeInContext(self.ctx, &fields, 2, 0);
        self.slice_type = st;
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
};
