const std = @import("std");
const ast = @import("ast.zig");
const pipeline = @import("pipeline.zig");
const sema = @import("sema.zig");
const comptime_mod = @import("comptime.zig");
const Span = @import("lexer/span.zig").Span;

pub const RegId = u32;
pub const BlockId = u32;

pub const IrModule = struct {
    file_name: []const u8,
    structs: []const StructDef = &.{},
    errors: []const ErrorDef = &.{},
    variants: []const VariantDef = &.{},
    functions: []const IrFunction = &.{},
    globals: []const IrGlobal = &.{},
    vtables: []const InterfaceVTable = &.{},
    /// Distinct library names referenced by `#extern("lib", "symbol")` decls
    /// (excluding "kernel32", which the linker always includes). The Windows
    /// linker step appends "<name>.lib" for each of these.
    extern_libs: []const []const u8 = &.{},

    pub fn empty(file_name: []const u8) IrModule {
        return .{ .file_name = file_name };
    }
};

pub const InterfaceVTable = struct {
    name: []const u8,
    methods: []const []const u8,
};

pub const IrGlobal = struct {
    name: []const u8,
    ty: IrType,
    init: ConstInit,
    mutable: bool,
};

pub const ConstInit = union(enum) {
    imm: Imm,
    struct_init: StructInit,
};

pub const StructInit = struct {
    ty_name: []const u8,
    fields: []const ConstFieldInit,
};

pub const ConstFieldInit = struct {
    name: []const u8,
    value: ConstInit,
};

pub const IrFunction = struct {
    name: []const u8,
    params: []const IrParam,
    return_ty: IrType,
    error_ty: ?IrType,
    blocks: []const IrBlock,
    extern_name: ?[]const u8,
    inline_hint: bool,
    no_inline: bool,
    no_return: bool,
    entry: bool,
    naked: bool,
    export_sym: ?[]const u8,
};

pub const IrParam = struct {
    name: []const u8,
    ty: IrType,
};

pub const IrBlock = struct {
    id: BlockId,
    name: []const u8,
    instrs: []const Instr,
    terminator: ?Terminator,
};

pub const IrType = union(enum) {
    i: u16,
    u: u16,
    f32,
    f64,
    bool,
    byte,
    usize,
    isize,
    addr,
    void,
    text,
    rune,
    zone,
    opaque_type: []const u8,
    ptr: *const IrType,
    optional: *const IrType,
    slice: *const IrType,
    array: ArrayType,
    range: *const IrType,
    struct_type: []const u8,
    variant_type: []const u8,
    fallible: FallibleType,
    fn_ptr: FnPtrType,
    interface_value: []const u8,
    list: *const IrType,
    map: *const IrType,
    unknown,

    pub fn isVoid(self: IrType) bool {
        return self == .void;
    }
};

pub const ArrayType = struct {
    elem: *const IrType,
    len: u64,
};

pub const FallibleType = struct {
    ok: *const IrType,
    err: *const IrType,
};

pub const FnPtrType = struct {
    params: []const IrType,
    ret: *const IrType,
};

pub const StructDef = struct {
    name: []const u8,
    fields: []const FieldDef,
    is_packed: bool,
    alignment: u32 = 0, // 0 = default; set by #align(N)
};

pub const FieldDef = struct {
    name: []const u8,
    ty: IrType,
};

pub const VariantDef = struct {
    name: []const u8,
    variants: []const VariantCase,
};

pub const ErrorDef = struct {
    name: []const u8,
    variants: []const ErrorCase,
};

pub const ErrorCase = struct {
    name: []const u8,
    payload: ?IrType,
};

pub const VariantCase = struct {
    name: []const u8,
    payload: ?IrType,
};

pub const Instr = struct {
    id: ?RegId,
    ty: IrType,
    kind: InstrKind,
    location: SourceLocation = .{ .file = "", .line = 0, .column = 0 },
};

pub const InstrKind = union(enum) {
    const_value: Imm,
    unary: UnaryInstr,
    binary: BinaryInstr,
    cast: CastInstr,
    call: CallInstr,
    call_indirect: CallIndirectInstr,
    builtin: BuiltinInstr,
    inline_asm: InlineAsmInstr,
    struct_lit: StructLitInstr,
    variant_lit: VariantLitInstr,
    field: FieldInstr,
    field_addr: FieldInstr,
    index: IndexInstr,
    index_addr: IndexInstr,
    slice_expr: SliceInstr,
    variant_is: VariantCheckInstr,
    variant_payload: VariantCheckInstr,
    optional_is_some: Value,
    optional_payload: Value,
    try_is_ok: Value,
    try_ok: Value,
    try_err: Value,
    iter_init: Value,
    iter_has_next: Value,
    iter_next: Value,
    alloc: AllocInstr,
    alloc_slice: AllocSliceInstr,
    zone_push: ZonePushInstr,
    zone_pop: []const u8,
    zone_free: ZoneFreeInstr,
    at: AtInstr,
    raw_pointer: RawPointerInstr,
    interface_make: InterfaceMakeInstr,
    interface_data: Value,
    interface_method: InterfaceMethodInstr,
    store_local: StoreLocalInstr,
    global_load: []const u8,
    global_store: GlobalStoreInstr,
    store: StoreInstr,
};

pub const InterfaceMakeInstr = struct {
    data: Value,
    vtable: []const u8,
};

pub const InterfaceMethodInstr = struct {
    value: Value,
    index: u32,
};

pub const UnaryInstr = struct {
    op: UnaryOp,
    value: Value,
};

pub const BinaryInstr = struct {
    op: BinOp,
    lhs: Value,
    rhs: Value,
};

pub const CastInstr = struct {
    kind: CastKind,
    value: Value,
};

pub const CallInstr = struct {
    callee: []const u8,
    args: []const Value,
};

pub const CallIndirectInstr = struct {
    callee: Value,
    args: []const Value,
};

pub const BuiltinInstr = struct {
    name: []const u8,
    args: []const Value,
    /// For builtins whose first argument is a type (e.g. `sizeof(T)`), the
    /// actual lowered type `T` — independent of the call's inferred result
    /// type, which sema may set to something else (e.g. `sizeof` → `.usize`).
    type_arg: ?IrType = null,
};

pub const StructFieldValue = struct {
    name: []const u8,
    value: Value,
};

pub const StructLitInstr = struct {
    ty_name: []const u8,
    fields: []const StructFieldValue,
};

pub const VariantLitInstr = struct {
    type_name: []const u8,
    variant: []const u8,
    payload: ?Value,
};

pub const FieldInstr = struct {
    base: Value,
    name: []const u8,
};

pub const IndexInstr = struct {
    base: Value,
    index: Value,
};

pub const SliceInstr = struct {
    ptr: Value,
    len: Value,
};

pub const VariantCheckInstr = struct {
    value: Value,
    type_name: []const u8, // enum type name for discriminant lookup
    variant: []const u8,
};

/// Inline assembly instruction with full operand constraint support.
/// Constraint string follows LLVM/GCC format: outputs first, then inputs, then clobbers.
/// Example for `syscall`:  "=a,{rdi},{rsi},{rdx},~{rcx},~{r11},~{memory}"
pub const InlineAsmInstr = struct {
    template: []const u8, // the assembly template, e.g. "syscall" or "pause"
    constraints: []const u8, // combined constraint string
    args: []const Value, // input operand values (in constraint order)
    volatile_: bool,
};

pub const AllocInstr = struct {
    ty: IrType,
    zone: []const u8,
};

pub const AllocSliceInstr = struct {
    elem_ty: IrType,
    count: Value,
    zone: []const u8,
};

pub const ZonePushInstr = struct {
    name: []const u8,
    kind: []const u8,
};

pub const ZoneFreeInstr = struct {
    zone: []const u8,
    ptr: Value,
};

pub const AtInstr = struct {
    value: Value,
    zone: []const u8,
};

pub const RawPointerInstr = struct {
    ty: IrType,
    address: Value,
};

pub const StoreLocalInstr = struct {
    name: []const u8,
    value: Value,
};

pub const GlobalStoreInstr = struct {
    name: []const u8,
    value: Value,
};

pub const StoreInstr = struct {
    target: Value,
    value: Value,
};

pub const Terminator = union(enum) {
    return_value: ?Value,
    fail: Value,
    panic: Panic,
    branch: BlockId,
    cond_branch: CondBranch,
    unreachable_term,
};

pub const Panic = struct {
    message: []const u8,
    location: SourceLocation,
};

pub const SourceLocation = struct {
    file: []const u8,
    line: usize,
    column: usize,
};

pub const CondBranch = struct {
    cond: Value,
    then_block: BlockId,
    else_block: BlockId,
};

pub const UnaryOp = enum {
    neg,
    not,
    bit_not,
    ref,
    deref,
};

pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    rem,
    shl,
    shr,
    lt,
    le,
    gt,
    ge,
    eq,
    ne,
    bit_and,
    bit_xor,
    bit_or,
    and_op,
    or_op,
    range,
    range_exclusive,
};

pub const CastKind = enum {
    as,
};

pub const Value = union(enum) {
    reg: RegId,
    param: []const u8,
    local: []const u8,
    global: []const u8,
    imm: Imm,
};

pub const Imm = union(enum) {
    int: i128,
    uint: u128,
    float: f64,
    bool: bool,
    text: []const u8,
    rune: u21,
    null,
};

pub const LowerError = error{
    LoweringFailed,
    OutOfMemory,
};

pub const ValidationError = error{
    InvalidIr,
};

pub const Pass = enum {
    const_fold,
    branch,
    dce,
};

pub fn lowerFrontend(allocator: std.mem.Allocator, front_end: pipeline.FrontEnd) LowerError!IrModule {
    return lowerModule(allocator, front_end);
}

pub fn lowerModule(allocator: std.mem.Allocator, front_end: pipeline.FrontEnd) LowerError!IrModule {
    var structs: std.ArrayList(StructDef) = .empty;
    var errors: std.ArrayList(ErrorDef) = .empty;
    var variants: std.ArrayList(VariantDef) = .empty;
    var functions: std.ArrayList(IrFunction) = .empty;
    var globals: std.ArrayList(IrGlobal) = .empty;
    var vtables: std.ArrayList(InterfaceVTable) = .empty;
    var extern_libs: std.ArrayList([]const u8) = .empty;
    errdefer structs.deinit(allocator);
    errdefer errors.deinit(allocator);
    errdefer variants.deinit(allocator);
    errdefer functions.deinit(allocator);
    errdefer globals.deinit(allocator);
    errdefer vtables.deinit(allocator);
    errdefer extern_libs.deinit(allocator);

    for (front_end.module.items) |item| {
        switch (item) {
            .import => {},
            .type_decl => |decl| switch (decl.kind) {
                .struct_type => |strukt| try structs.append(allocator, try lowerStruct(allocator, decl, strukt, front_end.types, front_end.symbols)),
                .errors => |error_decl| try errors.append(allocator, try lowerErrorDef(allocator, decl, error_decl)),
                .enum_type => |enum_decl| try variants.append(allocator, try lowerEnumDef(allocator, decl, enum_decl)),
                .distinct, .opaque_type, .interface_type => {},
            },
            .const_decl => |decl| {
                // #run expr on the right-hand side → evaluate at compile time.
                const effective_imm = effectiveConstImm(allocator, front_end, decl.value);
                try globals.append(allocator, .{
                    .name = decl.name,
                    .ty = inferConstType(decl.value),
                    .init = .{ .imm = effective_imm },
                    .mutable = false,
                });
            },
            .function => |decl| {
                // Generic templates are lowered per-instantiation below; skip the template itself.
                if (decl.type_params.len == 0) {
                    try functions.append(allocator, try lowerFunction(allocator, front_end.types, front_end.symbols, front_end.module, decl));
                }
                if (externLibName(decl.attrs)) |lib| try addExternLib(allocator, &extern_libs, lib);
            },
            .interface_impl => |impl| {
                for (impl.methods) |method| {
                    const mangled = try interfaceMethodName(allocator, impl.type_name, impl.interface_name, method.name);
                    try functions.append(allocator, try lowerInterfaceMethod(
                        allocator,
                        front_end.types,
                        front_end.symbols,
                        front_end.module,
                        impl,
                        method,
                        mangled,
                    ));
                }
                var method_names = std.ArrayList([]const u8).empty;
                errdefer method_names.deinit(allocator);
                const interface_id = front_end.symbols.resolve(front_end.symbols.root_scope, impl.interface_name) orelse return error.LoweringFailed;
                const layout = front_end.types.layouts.get(interface_id) orelse return error.LoweringFailed;
                const interface_methods = switch (layout.kind) {
                    .interface_type => |methods| methods,
                    else => return error.LoweringFailed,
                };
                for (interface_methods) |method| {
                    try method_names.append(allocator, try interfaceMethodName(
                        allocator,
                        impl.type_name,
                        impl.interface_name,
                        method.name,
                    ));
                }
                try vtables.append(allocator, .{
                    .name = try interfaceVTableName(allocator, impl.type_name, impl.interface_name),
                    .methods = try method_names.toOwnedSlice(allocator),
                });
            },
            .system_library => |decl| try addExternLib(allocator, &extern_libs, decl.name),
        }
    }

    // Emit generic struct instantiations as concrete StructDef entries.
    var inst_it = front_end.types.generic_struct_instances.iterator();
    while (inst_it.next()) |kv| {
        const inst_id = kv.value_ptr.*;
        const layout = front_end.types.layouts.get(inst_id) orelse continue;
        const mangled = kv.key_ptr.*;
        switch (layout.kind) {
            .struct_type => |fields| {
                var ir_fields: std.ArrayList(FieldDef) = .empty;
                errdefer ir_fields.deinit(allocator);
                for (fields) |f| {
                    try ir_fields.append(allocator, .{
                        .name = f.name,
                        .ty = try lowerSemaTypeWithEnv(allocator, f.ty, front_end.types, front_end.symbols),
                    });
                }
                try structs.append(allocator, .{
                    .name = mangled,
                    .fields = try ir_fields.toOwnedSlice(allocator),
                    .is_packed = layout.is_packed,
                    .alignment = 0,
                });
            },
            else => {},
        }
    }

    // Lower each generic function instantiation with its concrete type binding
    for (front_end.types.generic_instantiations.items) |*inst| {
        for (front_end.module.items) |item| {
            switch (item) {
                .function => |decl| {
                    if (decl.type_params.len == 0) continue;
                    const sym_id = front_end.symbols.resolve(front_end.symbols.root_scope, decl.name) orelse continue;
                    if (sym_id != inst.sym_id) continue;
                    var inst_types = front_end.types;
                    inst_types.expr_types = inst.expr_types;
                    try functions.append(allocator, try lowerFunctionInstantiation(
                        allocator,
                        inst_types,
                        front_end.symbols,
                        decl,
                        inst.mangled_name,
                        inst.type_args,
                    ));
                },
                else => {},
            }
        }
    }

    return .{
        .file_name = front_end.module.file_name,
        .structs = try structs.toOwnedSlice(allocator),
        .errors = try errors.toOwnedSlice(allocator),
        .variants = try variants.toOwnedSlice(allocator),
        .functions = try functions.toOwnedSlice(allocator),
        .globals = try globals.toOwnedSlice(allocator),
        .vtables = try vtables.toOwnedSlice(allocator),
        .extern_libs = try extern_libs.toOwnedSlice(allocator),
    };
}

pub fn validateModule(module: IrModule) ValidationError!void {
    for (module.functions) |function| {
        try validateFunction(function);
    }
}

pub fn runDefaultPasses(allocator: std.mem.Allocator, module: *IrModule) !void {
    try runPasses(allocator, module, &.{ .const_fold, .branch, .dce });
    try validateModule(module.*);
}

pub fn runPasses(allocator: std.mem.Allocator, module: *IrModule, passes: []const Pass) !void {
    for (passes) |pass| {
        switch (pass) {
            .const_fold => try foldConstants(allocator, module),
            .branch => try simplifyBranches(allocator, module),
            .dce => try eliminateDeadCode(allocator, module),
        }
    }
}

fn validateFunction(function: IrFunction) ValidationError!void {
    if (function.extern_name != null and function.blocks.len == 0) return;
    if (function.blocks.len == 0) return error.InvalidIr;
    if (function.blocks[0].id != 0) return error.InvalidIr;

    for (function.blocks, 0..) |block, block_index| {
        if (block.terminator == null) return error.InvalidIr;
        for (function.blocks[block_index + 1 ..]) |other| {
            if (block.id == other.id) return error.InvalidIr;
        }

        for (block.instrs, 0..) |instr, instr_index| {
            if (instr.id) |id| {
                for (function.blocks[0 .. block_index + 1], 0..) |seen_block, seen_block_index| {
                    const end = if (seen_block_index == block_index) instr_index else seen_block.instrs.len;
                    for (seen_block.instrs[0..end]) |seen| {
                        if (seen.id != null and seen.id.? == id) return error.InvalidIr;
                    }
                }
            }
            try validateInstr(function, instr);
        }

        try validateTerminator(function, block.terminator.?);
    }
}

fn validateInstr(function: IrFunction, instr: Instr) ValidationError!void {
    switch (instr.kind) {
        .const_value, .alloc, .alloc_slice, .zone_push, .zone_pop, .global_load => {},
        .inline_asm => |ai| for (ai.args) |v| try validateValue(function, v),
        .zone_free => |zf| try validateValue(function, zf.ptr),
        .unary => |unary| try validateValue(function, unary.value),
        .binary => |binary| {
            try validateValue(function, binary.lhs);
            try validateValue(function, binary.rhs);
        },
        .cast => |cast| try validateValue(function, cast.value),
        .call => |call| for (call.args) |arg| try validateValue(function, arg),
        .call_indirect => |call| {
            try validateValue(function, call.callee);
            for (call.args) |arg| try validateValue(function, arg);
        },
        .builtin => |builtin| for (builtin.args) |arg| try validateValue(function, arg),
        .struct_lit => |strukt| for (strukt.fields) |field| try validateValue(function, field.value),
        .variant_lit => |variant| if (variant.payload) |payload| try validateValue(function, payload),
        .field, .field_addr => |field| try validateValue(function, field.base),
        .index, .index_addr => |index| {
            try validateValue(function, index.base);
            try validateValue(function, index.index);
        },
        .slice_expr => |slice| {
            try validateValue(function, slice.ptr);
            try validateValue(function, slice.len);
        },
        .variant_is, .variant_payload => |variant| try validateValue(function, variant.value),
        .optional_is_some, .optional_payload, .try_is_ok, .try_ok, .try_err, .iter_init, .iter_has_next, .iter_next => |value| try validateValue(function, value),
        .at => |at| try validateValue(function, at.value),
        .raw_pointer => |ptr| try validateValue(function, ptr.address),
        .interface_make => |make| try validateValue(function, make.data),
        .interface_data => |value| try validateValue(function, value),
        .interface_method => |method| try validateValue(function, method.value),
        .store_local => |store| try validateValue(function, store.value),
        .global_store => |store| try validateValue(function, store.value),
        .store => |store| {
            try validateValue(function, store.target);
            try validateValue(function, store.value);
        },
    }
}

fn validateTerminator(function: IrFunction, terminator: Terminator) ValidationError!void {
    switch (terminator) {
        .return_value => |value| if (value) |ret| try validateValue(function, ret),
        .fail => |value| try validateValue(function, value),
        .panic => {},
        .branch => |target| if (!hasBlock(function, target)) return error.InvalidIr,
        .cond_branch => |branch| {
            try validateValue(function, branch.cond);
            if (!hasBlock(function, branch.then_block)) return error.InvalidIr;
            if (!hasBlock(function, branch.else_block)) return error.InvalidIr;
        },
        .unreachable_term => {},
    }
}

fn validateValue(function: IrFunction, value: Value) ValidationError!void {
    switch (value) {
        .reg => |id| if (!hasReg(function, id)) return error.InvalidIr,
        .param => |name| if (!hasParam(function, name)) return error.InvalidIr,
        .local, .global, .imm => {},
    }
}

fn hasBlock(function: IrFunction, id: BlockId) bool {
    for (function.blocks) |block| {
        if (block.id == id) return true;
    }
    return false;
}

fn hasReg(function: IrFunction, id: RegId) bool {
    for (function.blocks) |block| {
        for (block.instrs) |instr| {
            if (instr.id != null and instr.id.? == id) return true;
        }
    }
    return false;
}

fn hasParam(function: IrFunction, name: []const u8) bool {
    for (function.params) |param| {
        if (std.mem.eql(u8, param.name, name)) return true;
    }
    return false;
}

fn foldConstants(allocator: std.mem.Allocator, module: *IrModule) !void {
    var functions: std.ArrayList(IrFunction) = .empty;
    errdefer functions.deinit(allocator);
    for (module.functions) |function| {
        try functions.append(allocator, try foldFunctionConstants(allocator, function));
    }
    module.functions = try functions.toOwnedSlice(allocator);
}

const ConstMap = std.AutoHashMap(RegId, Imm);

fn foldFunctionConstants(allocator: std.mem.Allocator, function: IrFunction) !IrFunction {
    var blocks: std.ArrayList(IrBlock) = .empty;
    errdefer blocks.deinit(allocator);

    var consts = ConstMap.init(allocator);
    defer consts.deinit();

    for (function.blocks) |block| {
        var instrs: std.ArrayList(Instr) = .empty;
        errdefer instrs.deinit(allocator);

        for (block.instrs) |instr| {
            const folded = tryFoldInstr(&consts, instr);
            if (folded.id) |id| {
                if (folded.kind == .const_value) {
                    try consts.put(id, folded.kind.const_value);
                }
            }
            try instrs.append(allocator, folded);
        }

        try blocks.append(allocator, .{
            .id = block.id,
            .name = block.name,
            .instrs = try instrs.toOwnedSlice(allocator),
            .terminator = foldTerminator(&consts, block.terminator),
        });
    }

    return .{
        .name = function.name,
        .params = function.params,
        .return_ty = function.return_ty,
        .error_ty = function.error_ty,
        .blocks = try blocks.toOwnedSlice(allocator),
        .extern_name = function.extern_name,
        .inline_hint = function.inline_hint,
        .no_inline = function.no_inline,
        .no_return = function.no_return,
        .entry = function.entry,
        .naked = function.naked,
        .export_sym = function.export_sym,
    };
}

fn resolveVal(consts: *const ConstMap, value: Value) Value {
    return switch (value) {
        .reg => |id| if (consts.get(id)) |imm| .{ .imm = imm } else value,
        else => value,
    };
}

fn tryFoldInstr(consts: *const ConstMap, instr: Instr) Instr {
    switch (instr.kind) {
        .const_value => return instr,
        .binary => |binary| {
            const lhs = resolveVal(consts, binary.lhs);
            const rhs = resolveVal(consts, binary.rhs);
            if (lhs == .imm and rhs == .imm) {
                if (foldBinaryImm(binary.op, lhs.imm, rhs.imm)) |result| {
                    return .{ .id = instr.id, .ty = instr.ty, .kind = .{ .const_value = result }, .location = instr.location };
                }
            }
            return .{ .id = instr.id, .ty = instr.ty, .kind = .{ .binary = .{ .op = binary.op, .lhs = lhs, .rhs = rhs } }, .location = instr.location };
        },
        .unary => |unary| {
            const value = resolveVal(consts, unary.value);
            if (value == .imm) {
                if (foldUnaryImm(unary.op, value.imm)) |result| {
                    return .{ .id = instr.id, .ty = instr.ty, .kind = .{ .const_value = result }, .location = instr.location };
                }
            }
            return .{ .id = instr.id, .ty = instr.ty, .kind = .{ .unary = .{ .op = unary.op, .value = value } }, .location = instr.location };
        },
        else => return instr,
    }
}

fn foldTerminator(consts: *const ConstMap, terminator: ?Terminator) ?Terminator {
    const term = terminator orelse return null;
    return switch (term) {
        .cond_branch => |branch| {
            const cond = resolveVal(consts, branch.cond);
            if (cond == .imm) switch (cond.imm) {
                .bool => |b| return .{ .branch = if (b) branch.then_block else branch.else_block },
                else => {},
            };
            return .{ .cond_branch = .{ .cond = cond, .then_block = branch.then_block, .else_block = branch.else_block } };
        },
        .return_value => |v| if (v) |val| .{ .return_value = resolveVal(consts, val) } else term,
        .fail => |v| .{ .fail = resolveVal(consts, v) },
        .panic => |panic| .{ .panic = panic },
        else => term,
    };
}

fn foldBinaryImm(op: BinOp, lhs: Imm, rhs: Imm) ?Imm {
    const l: i128 = switch (lhs) {
        .int => |v| v,
        .uint => |v| @intCast(v),
        else => return null,
    };
    const r: i128 = switch (rhs) {
        .int => |v| v,
        .uint => |v| @intCast(v),
        else => return null,
    };
    return switch (op) {
        .add => .{ .int = l +% r },
        .sub => .{ .int = l -% r },
        .mul => .{ .int = l *% r },
        .div => if (r == 0) null else .{ .int = @divTrunc(l, r) },
        .rem => if (r == 0) null else .{ .int = @rem(l, r) },
        .shl => if (r >= 0 and r < 128) .{ .int = l << @as(u7, @intCast(r)) } else null,
        .shr => if (r >= 0 and r < 128) .{ .int = l >> @as(u7, @intCast(r)) } else null,
        .bit_and => .{ .int = l & r },
        .bit_or => .{ .int = l | r },
        .bit_xor => .{ .int = l ^ r },
        .eq => .{ .bool = l == r },
        .ne => .{ .bool = l != r },
        .lt => .{ .bool = l < r },
        .le => .{ .bool = l <= r },
        .gt => .{ .bool = l > r },
        .ge => .{ .bool = l >= r },
        else => null,
    };
}

fn foldUnaryImm(op: UnaryOp, value: Imm) ?Imm {
    return switch (op) {
        .neg => switch (value) {
            .int => |v| .{ .int = -%v },
            .uint => |v| .{ .int = -@as(i128, @intCast(v)) },
            else => null,
        },
        .not => switch (value) {
            .bool => |v| .{ .bool = !v },
            else => null,
        },
        .bit_not => switch (value) {
            .int => |v| .{ .int = ~v },
            .uint => |v| .{ .uint = ~v },
            else => null,
        },
        else => null,
    };
}

fn simplifyBranches(allocator: std.mem.Allocator, module: *IrModule) !void {
    var functions: std.ArrayList(IrFunction) = .empty;
    errdefer functions.deinit(allocator);

    for (module.functions) |function| {
        var blocks: std.ArrayList(IrBlock) = .empty;
        errdefer blocks.deinit(allocator);

        for (function.blocks) |block| {
            try blocks.append(allocator, .{
                .id = block.id,
                .name = block.name,
                .instrs = block.instrs,
                .terminator = simplifyTerminator(block.terminator),
            });
        }

        try functions.append(allocator, .{
            .name = function.name,
            .params = function.params,
            .return_ty = function.return_ty,
            .error_ty = function.error_ty,
            .blocks = try blocks.toOwnedSlice(allocator),
            .extern_name = function.extern_name,
            .inline_hint = function.inline_hint,
            .no_inline = function.no_inline,
            .no_return = function.no_return,
            .entry = function.entry,
            .naked = function.naked,
            .export_sym = function.export_sym,
        });
    }

    module.functions = try functions.toOwnedSlice(allocator);
}

fn simplifyTerminator(terminator: ?Terminator) ?Terminator {
    const term = terminator orelse return null;
    return switch (term) {
        .cond_branch => |branch| if (branch.then_block == branch.else_block) .{ .branch = branch.then_block } else term,
        else => term,
    };
}

fn eliminateDeadCode(allocator: std.mem.Allocator, module: *IrModule) !void {
    var functions: std.ArrayList(IrFunction) = .empty;
    errdefer functions.deinit(allocator);

    for (module.functions) |function| {
        try functions.append(allocator, try eliminateFunctionDeadCode(allocator, function));
    }

    module.functions = try functions.toOwnedSlice(allocator);
}

fn eliminateFunctionDeadCode(allocator: std.mem.Allocator, function: IrFunction) !IrFunction {
    var blocks: std.ArrayList(IrBlock) = .empty;
    errdefer blocks.deinit(allocator);

    for (function.blocks) |block| {
        var instrs: std.ArrayList(Instr) = .empty;
        errdefer instrs.deinit(allocator);

        for (block.instrs) |instr| {
            if (instr.id) |id| {
                if (!instrHasSideEffects(instr) and !regIsUsed(function, id)) continue;
            }
            try instrs.append(allocator, instr);
        }

        try blocks.append(allocator, .{
            .id = block.id,
            .name = block.name,
            .instrs = try instrs.toOwnedSlice(allocator),
            .terminator = block.terminator,
        });
    }

    return .{
        .name = function.name,
        .params = function.params,
        .return_ty = function.return_ty,
        .error_ty = function.error_ty,
        .blocks = try blocks.toOwnedSlice(allocator),
        .extern_name = function.extern_name,
        .inline_hint = function.inline_hint,
        .no_inline = function.no_inline,
        .no_return = function.no_return,
        .entry = function.entry,
        .naked = function.naked,
        .export_sym = function.export_sym,
    };
}

fn instrHasSideEffects(instr: Instr) bool {
    return switch (instr.kind) {
        .call, .call_indirect, .builtin, .inline_asm, .store_local, .global_store, .store, .alloc, .alloc_slice, .zone_push, .zone_pop, .zone_free => true,
        else => instr.id == null,
    };
}

fn regIsUsed(function: IrFunction, id: RegId) bool {
    for (function.blocks) |block| {
        for (block.instrs) |instr| {
            if (instrUsesReg(instr, id)) return true;
        }
        if (block.terminator) |terminator| {
            if (terminatorUsesReg(terminator, id)) return true;
        }
    }
    return false;
}

fn instrUsesReg(instr: Instr, id: RegId) bool {
    return switch (instr.kind) {
        .const_value, .alloc, .alloc_slice, .zone_push, .zone_pop, .global_load => false,
        .inline_asm => |ai| valuesUseReg(ai.args, id),
        .zone_free => |zf| valueUsesReg(zf.ptr, id),
        .unary => |unary| valueUsesReg(unary.value, id),
        .binary => |binary| valueUsesReg(binary.lhs, id) or valueUsesReg(binary.rhs, id),
        .cast => |cast| valueUsesReg(cast.value, id),
        .call => |call| valuesUseReg(call.args, id),
        .call_indirect => |call| valueUsesReg(call.callee, id) or valuesUseReg(call.args, id),
        .builtin => |builtin| valuesUseReg(builtin.args, id),
        .struct_lit => |strukt| for (strukt.fields) |field| {
            if (valueUsesReg(field.value, id)) break true;
        } else false,
        .variant_lit => |variant| variant.payload != null and valueUsesReg(variant.payload.?, id),
        .field, .field_addr => |field| valueUsesReg(field.base, id),
        .index, .index_addr => |index| valueUsesReg(index.base, id) or valueUsesReg(index.index, id),
        .slice_expr => |slice| valueUsesReg(slice.ptr, id) or valueUsesReg(slice.len, id),
        .variant_is, .variant_payload => |variant| valueUsesReg(variant.value, id),
        .optional_is_some, .optional_payload, .try_is_ok, .try_ok, .try_err, .iter_init, .iter_has_next, .iter_next => |value| valueUsesReg(value, id),
        .at => |at| valueUsesReg(at.value, id),
        .raw_pointer => |ptr| valueUsesReg(ptr.address, id),
        .interface_make => |make| valueUsesReg(make.data, id),
        .interface_data => |value| valueUsesReg(value, id),
        .interface_method => |method| valueUsesReg(method.value, id),
        .store_local => |store| valueUsesReg(store.value, id),
        .global_store => |store| valueUsesReg(store.value, id),
        .store => |store| valueUsesReg(store.target, id) or valueUsesReg(store.value, id),
    };
}

fn terminatorUsesReg(terminator: Terminator, id: RegId) bool {
    return switch (terminator) {
        .return_value => |value| value != null and valueUsesReg(value.?, id),
        .fail => |value| valueUsesReg(value, id),
        .panic, .branch, .unreachable_term => false,
        .cond_branch => |branch| valueUsesReg(branch.cond, id),
    };
}

fn valuesUseReg(values: []const Value, id: RegId) bool {
    for (values) |value| {
        if (valueUsesReg(value, id)) return true;
    }
    return false;
}

fn valueUsesReg(value: Value, id: RegId) bool {
    return switch (value) {
        .reg => |reg| reg == id,
        .param, .local, .global, .imm => false,
    };
}

fn lowerStruct(allocator: std.mem.Allocator, decl: ast.TypeDecl, strukt: ast.StructDecl, types: sema.TypeEnv, symbols: sema.SymbolTable) !StructDef {
    var fields: std.ArrayList(FieldDef) = .empty;
    errdefer fields.deinit(allocator);

    for (strukt.fields) |field| {
        try fields.append(allocator, .{
            .name = field.name,
            .ty = try lowerAstTypeWithEnv(allocator, field.ty, types, symbols),
        });
    }

    return .{
        .name = decl.name,
        .fields = try fields.toOwnedSlice(allocator),
        .is_packed = hasAttr(decl.attrs, "packed"),
        .alignment = alignAttr(decl.attrs),
    };
}

fn lowerEnumDef(allocator: std.mem.Allocator, decl: ast.TypeDecl, enum_decl: ast.EnumDecl) !VariantDef {
    var cases: std.ArrayList(VariantCase) = .empty;
    errdefer cases.deinit(allocator);
    for (enum_decl.variants) |v| {
        try cases.append(allocator, .{
            .name = v.name,
            .payload = if (v.payload) |p| try lowerType(allocator, p) else null,
        });
    }
    return .{ .name = decl.name, .variants = try cases.toOwnedSlice(allocator) };
}

fn lowerErrorDef(allocator: std.mem.Allocator, decl: ast.TypeDecl, error_decl: ast.ErrorDecl) !ErrorDef {
    var variants: std.ArrayList(ErrorCase) = .empty;
    errdefer variants.deinit(allocator);

    for (error_decl.variants) |variant| {
        try variants.append(allocator, .{
            .name = variant.name,
            .payload = if (variant.payload) |payload| try lowerType(allocator, payload) else null,
        });
    }

    return .{
        .name = decl.name,
        .variants = try variants.toOwnedSlice(allocator),
    };
}

fn lowerFunctionInstantiation(
    allocator: std.mem.Allocator,
    types: sema.TypeEnv,
    symbols: sema.SymbolTable,
    decl: ast.FunctionDecl,
    mangled_name: []const u8,
    type_args: []const sema.TypeArg,
) !IrFunction {
    var params: std.ArrayList(IrParam) = .empty;
    errdefer params.deinit(allocator);

    for (decl.params) |param| {
        if (param.is_type_param) continue;
        try params.append(allocator, .{
            .name = param.name,
            .ty = lowerTypeWithBindingAndSymbols(allocator, param.ty, type_args, types, symbols) catch .unknown,
        });
    }

    const ret_ty = lowerTypeWithBindingAndSymbols(allocator, decl.return_ty, type_args, types, symbols) catch .unknown;

    const blocks = if (decl.body) |body| blk: {
        var lowerer = FunctionLowerer.init(allocator, types, symbols, decl);
        lowerer.type_binding = type_args;
        break :blk try lowerer.lowerBody(body);
    } else &.{};

    return .{
        .name = mangled_name,
        .params = try params.toOwnedSlice(allocator),
        .return_ty = ret_ty,
        .error_ty = null,
        .blocks = blocks,
        .extern_name = null,
        .inline_hint = hasAttr(decl.attrs, "inline"),
        .no_inline = hasAttr(decl.attrs, "noinline"),
        .no_return = hasAttr(decl.attrs, "noreturn"),
        .entry = false,
        .naked = false,
        .export_sym = sema.exportSym(decl.attrs),
    };
}

fn lowerTypeWithBindingAndSymbols(allocator: std.mem.Allocator, ty: ast.TypeRef, binding: []const sema.TypeArg, types: sema.TypeEnv, symbols: sema.SymbolTable) !IrType {
    switch (ty) {
        .type_param => |tp| {
            for (binding) |arg| {
                if (std.mem.eql(u8, arg.name, tp.name))
                    return lowerSemaTypeWithEnv(allocator, arg.ty, types, symbols) catch .unknown;
            }
            return .unknown;
        },
        .named => |named| {
            for (binding) |arg| {
                if (std.mem.eql(u8, arg.name, named.name))
                    return lowerSemaTypeWithEnv(allocator, arg.ty, types, symbols) catch .unknown;
            }
            // Distinct type: substitute underlying type.
            if (symbols.resolve(symbols.root_scope, named.name)) |id| {
                if (types.distinct_types.get(id)) |underlying| {
                    return lowerSemaTypeWithEnv(allocator, underlying, types, symbols) catch .unknown;
                }
            }
            return lowerNamedType(named.name);
        },
        .pointer => |ptr| return .{ .ptr = try boxType(allocator, try lowerTypeWithBindingAndSymbols(allocator, ptr.inner.*, binding, types, symbols)) },
        .many_pointer => |ptr| return .{ .ptr = try boxType(allocator, try lowerTypeWithBindingAndSymbols(allocator, ptr.inner.*, binding, types, symbols)) },
        .optional => |opt| return .{ .optional = try boxType(allocator, try lowerTypeWithBindingAndSymbols(allocator, opt.inner.*, binding, types, symbols)) },
        .slice => |sl| return .{ .slice = try boxType(allocator, try lowerTypeWithBindingAndSymbols(allocator, sl.inner.*, binding, types, symbols)) },
        .borrow => |b| return lowerTypeWithBindingAndSymbols(allocator, b.inner.*, binding, types, symbols),
        .array => |arr| return .{ .array = .{
            .elem = try boxType(allocator, try lowerTypeWithBindingAndSymbols(allocator, arr.inner.*, binding, types, symbols)),
            .len = parseArrayLen(arr.len.*),
        } },
        else => return lowerType(allocator, ty),
    }
}


fn lowerFunction(allocator: std.mem.Allocator, types: sema.TypeEnv, symbols: sema.SymbolTable, module: ast.Module, decl: ast.FunctionDecl) !IrFunction {
    var params: std.ArrayList(IrParam) = .empty;
    errdefer params.deinit(allocator);

    for (decl.params) |param| {
        if (param.is_type_param) continue;
        try params.append(allocator, .{
            .name = param.name,
            .ty = try lowerAstTypeWithEnv(allocator, param.ty, types, symbols),
        });
    }

    const return_ty = try lowerAstTypeWithEnv(allocator, decl.return_ty, types, symbols);
    const blocks = if (decl.body) |body| blk: {
        var lowerer = FunctionLowerer.init(allocator, types, symbols, decl);
        lowerer.module = module;
        lowerer.current_return_ty = return_ty;
        break :blk try lowerer.lowerBody(body);
    } else &.{};

    return .{
        .name = decl.name,
        .params = try params.toOwnedSlice(allocator),
        .return_ty = return_ty,
        .error_ty = if (decl.error_ty) |err| try lowerErrorSpec(allocator, err) else null,
        .blocks = blocks,
        .extern_name = externName(decl.attrs),
        .inline_hint = hasAttr(decl.attrs, "inline"),
        .no_inline = hasAttr(decl.attrs, "noinline"),
        .no_return = hasAttr(decl.attrs, "noreturn"),
        .entry = std.mem.eql(u8, decl.name, "main") or hasAttr(decl.attrs, "entry"),
        .naked = hasAttr(decl.attrs, "naked"),
        .export_sym = sema.exportSym(decl.attrs),
    };
}

fn lowerInterfaceMethod(
    allocator: std.mem.Allocator,
    types: sema.TypeEnv,
    symbols: sema.SymbolTable,
    module: ast.Module,
    impl: ast.InterfaceImpl,
    decl: ast.FunctionDecl,
    mangled_name: []const u8,
) !IrFunction {
    var params: std.ArrayList(IrParam) = .empty;
    errdefer params.deinit(allocator);
    for (decl.params) |param| try params.append(allocator, .{
        .name = param.name,
        .ty = try lowerTypeReplacingSelf(allocator, param.ty, impl.type_name, types, symbols),
    });
    const return_ty = try lowerTypeReplacingSelf(allocator, decl.return_ty, impl.type_name, types, symbols);
    const blocks = if (decl.body) |body| blk: {
        var lowerer = FunctionLowerer.init(allocator, types, symbols, decl);
        lowerer.module = module;
        lowerer.current_return_ty = return_ty;
        break :blk try lowerer.lowerBody(body);
    } else &.{};
    return .{
        .name = mangled_name,
        .params = try params.toOwnedSlice(allocator),
        .return_ty = return_ty,
        .error_ty = if (decl.error_ty) |err| try lowerErrorSpec(allocator, err) else null,
        .blocks = blocks,
        .extern_name = null,
        .inline_hint = false,
        .no_inline = false,
        .no_return = false,
        .entry = false,
        .naked = false,
        .export_sym = null,
    };
}

fn lowerTypeReplacingSelf(allocator: std.mem.Allocator, ty: ast.TypeRef, concrete_name: []const u8, types: sema.TypeEnv, symbols: sema.SymbolTable) !IrType {
    if (ty == .borrow) return lowerTypeReplacingSelf(allocator, ty.borrow.inner.*, concrete_name, types, symbols);
    // A pointer to a named interface type lowers to a fat interface pointer
    // ({ data: ptr, vtable: ptr }), not a thin pointer to the interface's
    // (nonexistent) struct layout — mirrors lowerAstTypeWithEnv.
    const ptr_inner_ast: ?ast.TypeRef = switch (ty) {
        .pointer => |p| p.inner.*,
        .many_pointer => |p| p.inner.*,
        else => null,
    };
    if (ptr_inner_ast) |inner_ty| switch (inner_ty) {
        .named => |named| if (!std.mem.eql(u8, named.name, "Self")) {
            if (symbols.resolve(symbols.root_scope, named.name)) |id| {
                if (types.layouts.get(id)) |layout| if (layout.kind == .interface_type)
                    return .{ .interface_value = named.name };
            }
        },
        else => {},
    };
    return switch (ty) {
        .named => |named| blk: {
            if (std.mem.eql(u8, named.name, "Self")) break :blk .{ .struct_type = concrete_name };
            if (symbols.resolve(symbols.root_scope, named.name)) |id| {
                if (types.distinct_types.get(id)) |underlying| {
                    break :blk lowerSemaTypeWithEnv(allocator, underlying, types, symbols) catch .unknown;
                }
            }
            break :blk lowerNamedType(named.name);
        },
        .pointer => |ptr| .{ .ptr = try boxType(allocator, try lowerTypeReplacingSelf(allocator, ptr.inner.*, concrete_name, types, symbols)) },
        .many_pointer => |ptr| .{ .ptr = try boxType(allocator, try lowerTypeReplacingSelf(allocator, ptr.inner.*, concrete_name, types, symbols)) },
        .optional => |opt| .{ .optional = try boxType(allocator, try lowerTypeReplacingSelf(allocator, opt.inner.*, concrete_name, types, symbols)) },
        .slice => |slice| .{ .slice = try boxType(allocator, try lowerTypeReplacingSelf(allocator, slice.inner.*, concrete_name, types, symbols)) },
        .borrow => |borrow| try lowerTypeReplacingSelf(allocator, borrow.inner.*, concrete_name, types, symbols),
        else => lowerType(allocator, ty),
    };
}

fn interfaceMethodName(allocator: std.mem.Allocator, type_name: []const u8, interface_name: []const u8, method_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ type_name, interface_name, method_name });
}

fn interfaceVTableName(allocator: std.mem.Allocator, type_name: []const u8, interface_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}.vtable", .{ type_name, interface_name });
}

const LoopContext = struct {
    cond_id: BlockId,
    continue_id: BlockId,
    after_id: BlockId,
    zone_depth: usize,
    defer_floor: usize,
};

const DeferPath = enum {
    ok,
    err,
};

fn deferRunsOn(mode: ast.DeferMode, path: DeferPath) bool {
    return switch (mode) {
        .always => true,
        .ok => path == .ok,
        .err => path == .err,
    };
}

const FunctionLowerer = struct {
    allocator: std.mem.Allocator,
    types: sema.TypeEnv,
    symbols: sema.SymbolTable,
    params: []const ast.Param,
    file_name: []const u8,
    source: []const u8,
    blocks: std.ArrayList(IrBlock) = .empty,
    current_instrs: std.ArrayList(Instr) = .empty,
    current_id: BlockId = 0,
    current_name: []const u8 = "entry",
    current_terminated: bool = false,
    next_reg: RegId = 1,
    next_block_id: BlockId = 1,
    loop_stack: std.ArrayList(LoopContext) = .empty,
    local_types: std.StringHashMap(IrType),
    current_return_ty: IrType = .void,
    active_zones: std.ArrayList([]const u8) = .empty,
    defers: std.ArrayList(ast.DeferStmt) = .empty,
    type_binding: []const sema.TypeArg = &.{},
    module: ast.Module = .empty(""),

    fn init(allocator: std.mem.Allocator, types: sema.TypeEnv, symbols: sema.SymbolTable, decl: ast.FunctionDecl) FunctionLowerer {
        return .{
            .allocator = allocator,
            .types = types,
            .symbols = symbols,
            .params = decl.params,
            .file_name = decl.file_name,
            .source = decl.source,
            .local_types = std.StringHashMap(IrType).init(allocator),
        };
    }

    fn lowerBody(self: *FunctionLowerer, body: ast.Block) LowerError![]const IrBlock {
        // Void functions fall through to ret void; non-void to unreachable
        // (sema already validated non-void functions have explicit returns).
        const fallthrough: Terminator = if (self.current_return_ty == .void)
            .{ .return_value = null }
        else
            .unreachable_term;
        try self.lowerBlock(body.statements, fallthrough);
        return self.blocks.toOwnedSlice(self.allocator);
    }

    fn lowerStmt(self: *FunctionLowerer, stmt: ast.Stmt) LowerError!void {
        switch (stmt) {
            .local_infer => |local| {
                const value = try self.lowerExpr(local.value);
                const local_ty = self.exprType(local.value);
                try self.local_types.put(local.name, local_ty);
                try self.emitNoResult(local_ty, .{ .store_local = .{ .name = local.name, .value = value } });
            },
            .local_typed => |local| {
                const local_ty = try lowerAstTypeWithEnv(self.allocator, local.ty, self.types, self.symbols);
                const value = try self.lowerExprAs(local.value, local_ty);
                try self.local_types.put(local.name, local_ty);
                try self.emitNoResult(local_ty, .{ .store_local = .{ .name = local.name, .value = value } });
            },
            .assign => |assign| {
                const value = try self.lowerExprAs(assign.value, self.exprType(assign.target));
                const bin_op = assignBinOp(assign.op);
                switch (assign.target.kind) {
                    .ident => |name| {
                        if (bin_op) |op| {
                            const current: Value = .{ .local = name };
                            const result = try self.emitAt(self.exprType(assign.target), .{ .binary = .{ .op = op, .lhs = current, .rhs = value } }, assign.span);
                            try self.emitNoResult(self.exprType(assign.target), .{ .store_local = .{ .name = name, .value = result } });
                        } else {
                            try self.emitNoResult(self.exprType(assign.target), .{ .store_local = .{ .name = name, .value = value } });
                        }
                    },
                    else => {
                        const target = try self.lowerLValueAddress(assign.target);
                        if (bin_op) |op| {
                            const current = try self.emitAt(self.exprType(assign.target), .{ .unary = .{ .op = .deref, .value = target } }, assign.span);
                            const result = try self.emitAt(self.exprType(assign.target), .{ .binary = .{ .op = op, .lhs = current, .rhs = value } }, assign.span);
                            try self.emitNoResult(self.exprType(assign.target), .{ .store = .{ .target = target, .value = result } });
                        } else {
                            try self.emitNoResult(self.exprType(assign.target), .{ .store = .{ .target = target, .value = value } });
                        }
                    },
                }
            },
            .return_stmt => |ret| {
                const ret_val: ?Value = if (ret.value) |value| try self.lowerExprAs(value, self.current_return_ty) else null;
                try self.emitDefersDown(0, .ok);
                var i = self.active_zones.items.len;
                while (i > 0) {
                    i -= 1;
                    try self.emitNoResult(.void, .{ .zone_pop = self.active_zones.items[i] });
                }
                try self.terminate(.{ .return_value = ret_val });
            },
            .fail_stmt => |fail| {
                var payload_values = std.ArrayList(Value).empty;
                errdefer payload_values.deinit(self.allocator);
                for (fail.payload) |payload| try payload_values.append(self.allocator, try self.lowerExpr(payload));
                const error_value = try self.emit(.{ .variant_type = "<error>" }, .{ .builtin = .{
                    .name = try std.fmt.allocPrint(self.allocator, "error.{s}", .{fail.variant}),
                    .args = try payload_values.toOwnedSlice(self.allocator),
                } });
                try self.emitDefersDown(0, .err);
                var i = self.active_zones.items.len;
                while (i > 0) {
                    i -= 1;
                    try self.emitNoResult(.void, .{ .zone_pop = self.active_zones.items[i] });
                }
                try self.terminate(.{ .fail = error_value });
            },
            .if_stmt => |iff| try self.lowerIf(iff),
            .while_stmt => |while_stmt| try self.lowerWhile(while_stmt),
            .for_range => |for_stmt| try self.lowerForRange(for_stmt),
            .for_slice => |for_stmt| try self.lowerForSlice(for_stmt),
            .match_stmt => |m| try self.lowerMatch(m),
            // Compile-time if: evaluate condition NOW; only emit the live branch.
            .comptime_if => |ci| blk: {
                const live_block = self.evalComptimeIf(ci) orelse {
                    // Could not evaluate at compile time — emit as runtime if.
                    try self.lowerIf(.{
                        .binding = null,
                        .payload_binding = null,
                        .condition = ci.condition,
                        .then_block = ci.then_block,
                        .else_block = ci.else_block,
                        .span = ci.span,
                    });
                    break :blk;
                };
                try self.lowerBlock(live_block.statements, null);
                break :blk;
            },
            .comptime_run => |block| try self.lowerBlock(block.statements, null),
            .zone_block => |zb| {
                try self.emitNoResult(.void, .{ .zone_push = .{ .name = zb.name, .kind = zb.kind } });
                try self.active_zones.append(self.allocator, zb.name);
                try self.lowerBlock(zb.body.statements, null);
                _ = self.active_zones.pop();
                if (!self.current_terminated) {
                    try self.emitNoResult(.void, .{ .zone_pop = zb.name });
                }
            },
            .defer_stmt => |ds| try self.defers.append(self.allocator, ds),
            .unsafe_block => |block| try self.lowerBlock(block.statements, null),
            .break_stmt => {
                const ctx = self.loop_stack.items[self.loop_stack.items.len - 1];
                try self.emitDefersDown(ctx.defer_floor, .ok);
                var i = self.active_zones.items.len;
                while (i > ctx.zone_depth) {
                    i -= 1;
                    try self.emitNoResult(.void, .{ .zone_pop = self.active_zones.items[i] });
                }
                try self.terminate(.{ .branch = ctx.after_id });
            },
            .continue_stmt => {
                const ctx = self.loop_stack.items[self.loop_stack.items.len - 1];
                try self.emitDefersDown(ctx.defer_floor, .ok);
                var i = self.active_zones.items.len;
                while (i > ctx.zone_depth) {
                    i -= 1;
                    try self.emitNoResult(.void, .{ .zone_pop = self.active_zones.items[i] });
                }
                try self.terminate(.{ .branch = ctx.continue_id });
            },
            .expr => |expr| _ = try self.lowerExpr(expr),
        }
    }

    fn lowerIf(self: *FunctionLowerer, iff: ast.IfStmt) LowerError!void {
        var optional_binding_name: ?[]const u8 = null;
        var optional_binding_value: ?Value = null;
        var optional_payload_ty: ?IrType = null;

        const cond = if (iff.binding) |binding| blk: {
            const value = try self.lowerExpr(binding.value);
            const value_ty = self.exprType(binding.value);
            switch (value_ty) {
                .optional => |inner| {
                    optional_binding_name = binding.name;
                    optional_binding_value = value;
                    optional_payload_ty = inner.*;
                    break :blk try self.emit(.bool, .{ .optional_is_some = value });
                },
                else => {
                    try self.emitNoResult(value_ty, .{ .store_local = .{ .name = binding.name, .value = value } });
                    break :blk value;
                },
            }
        } else blk: {
            const value = try self.lowerExpr(iff.condition);
            const value_ty = self.exprType(iff.condition);
            if (iff.payload_binding) |payload_name| switch (value_ty) {
                .optional => |inner| {
                    optional_binding_name = payload_name;
                    optional_binding_value = value;
                    optional_payload_ty = inner.*;
                    break :blk try self.emit(.bool, .{ .optional_is_some = value });
                },
                else => {},
            };
            break :blk value;
        };

        const then_id = self.allocBlockId();
        const else_id = if (iff.else_block != null) self.allocBlockId() else null;
        const after_id = self.allocBlockId();
        try self.terminate(.{ .cond_branch = .{
            .cond = cond,
            .then_block = then_id,
            .else_block = else_id orelse after_id,
        } });

        self.startBlock(then_id, "if.then");
        if (optional_binding_name) |name| {
            const opt_value = optional_binding_value.?;
            const payload_ty = optional_payload_ty.?;
            const payload = try self.emit(payload_ty, .{ .optional_payload = opt_value });
            try self.emitNoResult(payload_ty, .{ .store_local = .{ .name = name, .value = payload } });
        }
        try self.lowerBlock(iff.then_block.statements, .{ .branch = after_id });

        if (iff.else_block) |else_block| {
            self.startBlock(else_id.?, "if.else");
            try self.lowerBlock(else_block.statements, .{ .branch = after_id });
        }

        self.startBlock(after_id, "if.after");
    }

    fn lowerWhile(self: *FunctionLowerer, while_stmt: ast.WhileStmt) LowerError!void {
        const cond_id = self.allocBlockId();
        const body_id = self.allocBlockId();
        const after_id = self.allocBlockId();

        try self.loop_stack.append(self.allocator, .{
            .cond_id = cond_id,
            .continue_id = cond_id,
            .after_id = after_id,
            .zone_depth = self.active_zones.items.len,
            .defer_floor = self.defers.items.len,
        });

        try self.terminate(.{ .branch = cond_id });

        self.startBlock(cond_id, "while.cond");
        const cond = try self.lowerExpr(while_stmt.condition);
        try self.terminate(.{ .cond_branch = .{
            .cond = cond,
            .then_block = body_id,
            .else_block = after_id,
        } });

        self.startBlock(body_id, "while.body");
        try self.lowerBlock(while_stmt.body.statements, .{ .branch = cond_id });

        _ = self.loop_stack.pop();
        self.startBlock(after_id, "while.after");
    }

    fn lowerForRange(self: *FunctionLowerer, for_stmt: ast.ForRangeStmt) LowerError!void {
        const loop_ty = self.exprType(for_stmt.start);
        const suffix = self.next_block_id;
        const end_name = try std.fmt.allocPrint(self.allocator, "__for_end_{d}", .{suffix});

        try self.emitNoResult(loop_ty, .{ .store_local = .{
            .name = for_stmt.binding,
            .value = try self.lowerExpr(for_stmt.start),
        } });
        try self.emitNoResult(loop_ty, .{ .store_local = .{
            .name = end_name,
            .value = try self.lowerExpr(for_stmt.end),
        } });

        const cond_id = self.allocBlockId();
        const body_id = self.allocBlockId();
        const increment_id = self.allocBlockId();
        const after_id = self.allocBlockId();
        try self.loop_stack.append(self.allocator, .{
            .cond_id = cond_id,
            .continue_id = increment_id,
            .after_id = after_id,
            .zone_depth = self.active_zones.items.len,
            .defer_floor = self.defers.items.len,
        });

        try self.terminate(.{ .branch = cond_id });
        self.startBlock(cond_id, "for.range.cond");
        const cond = try self.emit(.bool, .{ .binary = .{
            .op = if (for_stmt.inclusive) .le else .lt,
            .lhs = .{ .local = for_stmt.binding },
            .rhs = .{ .local = end_name },
        } });
        try self.terminate(.{ .cond_branch = .{
            .cond = cond,
            .then_block = body_id,
            .else_block = after_id,
        } });

        self.startBlock(body_id, "for.range.body");
        try self.lowerBlock(for_stmt.body.statements, .{ .branch = increment_id });

        self.startBlock(increment_id, "for.range.increment");
        const next = try self.emit(loop_ty, .{ .binary = .{
            .op = .add,
            .lhs = .{ .local = for_stmt.binding },
            .rhs = .{ .imm = .{ .int = 1 } },
        } });
        try self.emitNoResult(loop_ty, .{ .store_local = .{ .name = for_stmt.binding, .value = next } });
        try self.terminate(.{ .branch = cond_id });

        _ = self.loop_stack.pop();
        self.startBlock(after_id, "for.range.after");
    }

    fn lowerForSlice(self: *FunctionLowerer, for_stmt: ast.ForSliceStmt) LowerError!void {
        const iter_ty = self.exprType(for_stmt.iter);
        const elem_ty: IrType = switch (iter_ty) {
            .slice => |elem| elem.*,
            .array => |array| array.elem.*,
            else => .unknown,
        };
        const binding_ty: IrType = if (for_stmt.by_ref)
            .{ .ptr = try boxType(self.allocator, elem_ty) }
        else
            elem_ty;
        const suffix = self.next_block_id;
        const iter_name = try std.fmt.allocPrint(self.allocator, "__for_iter_{d}", .{suffix});
        const index_name = try std.fmt.allocPrint(self.allocator, "__for_index_{d}", .{suffix});

        try self.emitNoResult(iter_ty, .{ .store_local = .{
            .name = iter_name,
            .value = try self.lowerExpr(for_stmt.iter),
        } });
        try self.emitNoResult(.usize, .{ .store_local = .{
            .name = index_name,
            .value = .{ .imm = .{ .uint = 0 } },
        } });

        const cond_id = self.allocBlockId();
        const body_id = self.allocBlockId();
        const increment_id = self.allocBlockId();
        const after_id = self.allocBlockId();
        try self.loop_stack.append(self.allocator, .{
            .cond_id = cond_id,
            .continue_id = increment_id,
            .after_id = after_id,
            .zone_depth = self.active_zones.items.len,
            .defer_floor = self.defers.items.len,
        });

        try self.terminate(.{ .branch = cond_id });
        self.startBlock(cond_id, "for.slice.cond");
        const len: Value = switch (iter_ty) {
            .array => |array| .{ .imm = .{ .uint = array.len } },
            else => try self.emit(.usize, .{ .field = .{ .base = .{ .local = iter_name }, .name = "len" } }),
        };
        const cond = try self.emit(.bool, .{ .binary = .{
            .op = .lt,
            .lhs = .{ .local = index_name },
            .rhs = len,
        } });
        try self.terminate(.{ .cond_branch = .{
            .cond = cond,
            .then_block = body_id,
            .else_block = after_id,
        } });

        self.startBlock(body_id, "for.slice.body");
        const item = if (for_stmt.by_ref)
            try self.emit(binding_ty, .{ .index_addr = .{
                .base = .{ .local = iter_name },
                .index = .{ .local = index_name },
            } })
        else
            try self.emit(elem_ty, .{ .index = .{
                .base = .{ .local = iter_name },
                .index = .{ .local = index_name },
            } });
        try self.emitNoResult(binding_ty, .{ .store_local = .{ .name = for_stmt.binding, .value = item } });
        if (for_stmt.index_binding) |name| {
            try self.emitNoResult(.usize, .{ .store_local = .{ .name = name, .value = .{ .local = index_name } } });
        }
        try self.lowerBlock(for_stmt.body.statements, .{ .branch = increment_id });

        self.startBlock(increment_id, "for.slice.increment");
        const next = try self.emit(.usize, .{ .binary = .{
            .op = .add,
            .lhs = .{ .local = index_name },
            .rhs = .{ .imm = .{ .uint = 1 } },
        } });
        try self.emitNoResult(.usize, .{ .store_local = .{ .name = index_name, .value = next } });
        try self.terminate(.{ .branch = cond_id });

        _ = self.loop_stack.pop();
        self.startBlock(after_id, "for.slice.after");
    }

    fn lowerExpr(self: *FunctionLowerer, expr: ast.Expr) LowerError!Value {
        return switch (expr.kind) {
            .ident => |name| blk: {
                for (self.params) |p| {
                    if (std.mem.eql(u8, p.name, name)) break :blk Value{ .param = name };
                }
                if (self.symbols.resolve(self.symbols.root_scope, name)) |id| {
                    const kind = self.symbols.symbol(id).kind;
                    if (kind == .function or kind == .const_symbol) break :blk Value{ .global = name };
                }
                break :blk Value{ .local = name };
            },
            .type_ref => .{ .imm = .null },
            .unsafe_expr => |inner| try self.lowerExpr(inner.*),
            .run_expr => |inner| blk: {
                var ctx = comptime_mod.ComptimeCtx.init(
                    self.allocator,
                    self.module,
                    self.symbols,
                    &self.types,
                );
                defer ctx.deinit();
                const cv = comptime_mod.evalExpr(&ctx, inner.*) catch break :blk try self.lowerExpr(inner.*);
                break :blk comptimeToValue(cv) orelse try self.lowerExpr(inner.*);
            },
            .force_unwrap => |inner| try self.lowerForceUnwrap(inner.*, expr),
            .nil_coalesce => |nc| try self.lowerNilCoalesce(nc, expr),
            .as_cast => |cast| if (self.exprType(expr) == .interface_value)
                try self.lowerInterfaceCoercion(cast.value.*, self.exprType(expr).interface_value)
            else
                try self.emit(self.exprType(expr), .{ .cast = .{
                    .kind = .as,
                    .value = try self.lowerExpr(cast.value.*),
                } }),
            .int => |text| .{ .imm = .{ .int = parseIntLiteral(text) } },
            .float => |text| .{ .imm = .{ .float = parseFloatLiteral(text) } },
            .string => |text| .{ .imm = .{ .text = trimQuotes(text) } },
            .bool => |value| .{ .imm = .{ .bool = value } },
            .null => .{ .imm = .null },
            .compound_literal => |values| blk: {
                var args = std.ArrayList(Value).empty;
                errdefer args.deinit(self.allocator);
                for (values) |value| try args.append(self.allocator, try self.lowerExpr(value));
                break :blk try self.emit(self.exprType(expr), .{ .builtin = .{ .name = "compound_literal", .args = try args.toOwnedSlice(self.allocator) } });
            },
            .unary => |unary| blk: {
                const value = try self.lowerExpr(unary.expr.*);
                break :blk switch (unary.op) {
                    .address_of => try self.emitAt(self.exprType(expr), .{ .unary = .{ .op = .ref, .value = value } }, expr.span),
                    .deref => try self.emitAt(self.exprType(expr), .{ .unary = .{ .op = .deref, .value = value } }, expr.span),
                    .neg => try self.emitAt(self.exprType(expr), .{ .unary = .{ .op = .neg, .value = value } }, expr.span),
                    .not => try self.emitAt(self.exprType(expr), .{ .unary = .{ .op = .not, .value = value } }, expr.span),
                    .bit_not => try self.emitAt(self.exprType(expr), .{ .unary = .{ .op = .bit_not, .value = value } }, expr.span),
                };
            },
            .binary => |binary| blk: {
                if (binary.op == .equal or binary.op == .not_equal) {
                    const optional_expr: ?ast.Expr = if (self.exprType(binary.left.*) == .optional and binary.right.kind == .null)
                        binary.left.*
                    else if (self.exprType(binary.right.*) == .optional and binary.left.kind == .null)
                        binary.right.*
                    else
                        null;
                    if (optional_expr) |optional| {
                        const value = try self.lowerExpr(optional);
                        const is_some = try self.emitAt(.bool, .{ .optional_is_some = value }, expr.span);
                        if (binary.op == .not_equal) break :blk is_some;
                        break :blk try self.emitAt(.bool, .{ .unary = .{ .op = .not, .value = is_some } }, expr.span);
                    }
                }
                const lhs = try self.lowerExpr(binary.left.*);
                const rhs = try self.lowerExpr(binary.right.*);
                break :blk try self.emitAt(self.exprType(expr), .{ .binary = .{ .op = lowerBinOp(binary.op), .lhs = lhs, .rhs = rhs } }, expr.span);
            },
            .try_expr => |try_expr| blk: {
                const value = try self.lowerExpr(try_expr.value.*);
                const with_context = try self.emit(self.exprType(try_expr.value.*), .{ .builtin = .{
                    .name = "try_context",
                    .args = try self.allocator.dupe(Value, &.{value}),
                } });
                break :blk try self.emit(self.exprType(expr), .{ .try_ok = with_context });
            },
            .catch_expr => |catch_expr| blk: {
                const value = try self.lowerExpr(catch_expr.value.*);
                const error_ty: IrType = switch (self.exprType(catch_expr.value.*)) {
                    .fallible => |fallible| fallible.err.*,
                    else => .unknown,
                };
                const is_ok = try self.emit(.bool, .{ .try_is_ok = value });
                const ok_id = self.allocBlockId();
                const err_id = self.allocBlockId();
                try self.terminate(.{ .cond_branch = .{
                    .cond = is_ok,
                    .then_block = ok_id,
                    .else_block = err_id,
                } });

                self.startBlock(err_id, "catch.err");
                const err_value = try self.emit(error_ty, .{ .try_err = value });
                try self.emitNoResult(error_ty, .{ .store_local = .{ .name = catch_expr.err_name, .value = err_value } });
                _ = try self.emit(.void, .{ .builtin = .{
                    .name = "catch_handler",
                    .args = try self.allocator.dupe(Value, &.{err_value}),
                } });
                try self.lowerBlock(catch_expr.handler.statements, .unreachable_term);

                self.startBlock(ok_id, "catch.ok");
                break :blk try self.emit(self.exprType(expr), .{ .try_ok = value });
            },
            .call => |call| blk: {
                // Detect zone method calls: sema marks the field-callee expr with zone_handle.
                if (call.callee.kind == .field) {
                    const fld = call.callee.kind.field;
                    if (self.exprType(fld.base.*) == .interface_value) {
                        const iface_name = self.exprType(fld.base.*).interface_value;
                        if (self.interfaceMethodIndex(iface_name, fld.name)) |method_index| {
                            const iface = try self.lowerExpr(fld.base.*);
                            const data = try self.emit(.{ .ptr = try boxType(self.allocator, .void) }, .{ .interface_data = iface });
                            const callee = try self.emit(.{ .ptr = try boxType(self.allocator, .void) }, .{ .interface_method = .{
                                .value = iface,
                                .index = method_index,
                            } });
                            var args = std.ArrayList(Value).empty;
                            errdefer args.deinit(self.allocator);
                            try args.append(self.allocator, data);
                            for (call.args) |arg| switch (arg) {
                                .positional => |value| try args.append(self.allocator, try self.lowerExpr(value)),
                                .named => |named| try args.append(self.allocator, try self.lowerExpr(named.value)),
                            };
                            break :blk try self.emit(self.exprType(expr), .{ .call_indirect = .{
                                .callee = callee,
                                .args = try args.toOwnedSlice(self.allocator),
                            } });
                        }
                    }
                    if (self.types.expr_types.get(call.callee.id)) |callee_ty| {
                        if (callee_ty == .zone_handle) {
                            const zone_field = call.callee.kind.field;
                            const zone_name = switch (zone_field.base.kind) {
                                .ident => |n| n,
                                else => break :blk Value{ .imm = .null },
                            };
                            break :blk try self.lowerZoneMethod(zone_name, zone_field.name, call.args, expr);
                        }
                    }
                    if (self.types.extension_calls.get(call.callee.id)) |extension_id| {
                        const sig = self.types.fn_sigs.get(extension_id) orelse return error.LoweringFailed;
                        const symbol = self.symbols.symbol(extension_id);
                        var args = std.ArrayList(Value).empty;
                        errdefer args.deinit(self.allocator);

                        var source_index: usize = 0;
                        var inserted_receiver = false;
                        for (sig.params) |param| {
                            if (param.is_type_param) {
                                const constrained = for (sig.type_constraints) |constraint| {
                                    if (std.mem.eql(u8, constraint.param, param.name)) break true;
                                } else false;
                                if (constrained) continue;
                                source_index += 1;
                                continue;
                            }

                            const value = if (!inserted_receiver) receiver: {
                                inserted_receiver = true;
                                break :receiver fld.base.*;
                            } else source: {
                                if (source_index >= call.args.len) return error.LoweringFailed;
                                const source_arg = call.args[source_index];
                                source_index += 1;
                                break :source switch (source_arg) {
                                    .positional => |value| value,
                                    .named => |named| named.value,
                                };
                            };
                            const expected = try lowerSemaTypeWithEnv(self.allocator, param.ty, self.types, self.symbols);
                            try args.append(self.allocator, try self.lowerExprAs(value, expected));
                        }

                        const callee_name = self.types.generic_call_insts.get(call.callee.id) orelse symbol.name;
                        break :blk try self.emit(self.exprType(expr), .{ .call = .{
                            .callee = callee_name,
                            .args = try args.toOwnedSlice(self.allocator),
                        } });
                    }
                }

                const callee_name = switch (call.callee.kind) {
                    .ident => |name| name,
                    else => "<expr>",
                };
                // asm(...) needs structural constraint parsing — handle before generic builtin path.
                if (std.mem.eql(u8, callee_name, "asm")) {
                    break :blk try self.lowerAsmCall(call, expr);
                }
                var args = std.ArrayList(Value).empty;
                errdefer args.deinit(self.allocator);
                const direct_sig = if (self.symbols.resolve(self.symbols.root_scope, callee_name)) |id|
                    self.types.fn_sigs.get(id)
                else
                    null;
                var value_param_index: usize = 0;
                for (call.args) |arg| {
                    const value = switch (arg) {
                        .positional => |value| value,
                        .named => |named| named.value,
                    };
                    var expected: ?IrType = null;
                    var is_explicit_type_arg = false;
                    if (direct_sig) |sig| {
                        while (value_param_index < sig.params.len and sig.params[value_param_index].is_type_param) {
                            const type_param = sig.params[value_param_index];
                            value_param_index += 1;
                            const is_constrained = for (sig.type_constraints) |constraint| {
                                if (std.mem.eql(u8, constraint.param, type_param.name)) break true;
                            } else false;
                            if (!is_constrained) {
                                is_explicit_type_arg = true;
                                break;
                            }
                        }
                        if (is_explicit_type_arg) continue;
                        if (value_param_index < sig.params.len) {
                            expected = lowerSemaTypeWithEnv(self.allocator, sig.params[value_param_index].ty, self.types, self.symbols) catch null;
                            value_param_index += 1;
                        }
                    }
                    try args.append(self.allocator, if (expected) |ty| try self.lowerExprAs(value, ty) else try self.lowerExpr(value));
                }
                const arg_slice = try args.toOwnedSlice(self.allocator);
                if (isBuiltinName(callee_name)) {
                    var type_arg: ?IrType = null;
                    if (std.mem.eql(u8, callee_name, "sizeof") and call.args.len > 0) {
                        const first = switch (call.args[0]) {
                            .positional => |e| e,
                            .named => |n| n.value,
                        };
                        type_arg = try self.lowerTypeArg(first);
                    }
                    break :blk try self.emit(self.exprType(expr), .{ .builtin = .{ .name = callee_name, .args = arg_slice, .type_arg = type_arg } });
                }

                // Determine if this is a direct (top-level function) or indirect (fn-ptr variable) call.
                const is_direct = blk2: {
                    if (self.symbols.resolve(self.symbols.root_scope, callee_name)) |id| {
                        break :blk2 self.symbols.symbol(id).kind == .function;
                    }
                    break :blk2 false;
                };

                if (!is_direct and callee_name.len > 0 and callee_name[0] != '<') {
                    // Function-pointer call: resolve the callee as a Value (param or local).
                    const callee_val: Value = cv: {
                        for (self.params) |p| {
                            if (std.mem.eql(u8, p.name, callee_name)) break :cv .{ .param = callee_name };
                        }
                        break :cv .{ .local = callee_name };
                    };
                    break :blk try self.emit(self.exprType(expr), .{ .call_indirect = .{
                        .callee = callee_val,
                        .args = arg_slice,
                    } });
                }

                // Use the mangled instantiation name if sema recorded one.
                const call_callee = if (call.callee.kind == .ident)
                    self.types.generic_call_insts.get(call.callee.id) orelse callee_name
                else
                    callee_name;
                break :blk try self.emit(self.exprType(expr), .{ .call = .{ .callee = call_callee, .args = arg_slice } });
            },
            .field => |field| blk: {
                // Detect enum variant access: `Direction.north`
                // The base is an ident that resolves to a TYPE symbol (not a value).
                if (field.base.kind == .ident) {
                    const base_ident = field.base.kind.ident;
                    if (self.symbols.resolve(self.symbols.root_scope, base_ident)) |sym_id| {
                        if (self.symbols.symbol(sym_id).kind == .type) {
                            break :blk try self.emit(self.exprType(expr), .{ .variant_lit = .{
                                .type_name = base_ident,
                                .variant = field.name,
                                .payload = null,
                            } });
                        }
                    }
                }
                const base = try self.lowerExpr(field.base.*);
                break :blk try self.emitAt(self.exprType(expr), .{ .field = .{ .base = base, .name = field.name } }, expr.span);
            },
            .index => |index| blk: {
                const base = try self.lowerExpr(index.base.*);
                const idx = try self.lowerExpr(index.index.*);
                break :blk try self.emitAt(self.exprType(expr), .{ .index = .{ .base = base, .index = idx } }, expr.span);
            },
            .slice => |slice| blk: {
                const base_ty = self.exprType(slice.base.*);
                if (slice.start != null or slice.end != null) {
                    const elem_ty: IrType = switch (base_ty) {
                        .array => |array| array.elem.*,
                        .slice => |inner| inner.*,
                        else => return error.LoweringFailed,
                    };

                    const start_val: Value = if (slice.start) |start_expr|
                        try self.lowerExpr(start_expr.*)
                    else
                        .{ .imm = .{ .uint = 0 } };

                    const base_len: Value = switch (base_ty) {
                        .array => |array| .{ .imm = .{ .uint = array.len } },
                        .slice => try self.emit(.usize, .{ .field = .{ .base = try self.lowerExpr(slice.base.*), .name = "len" } }),
                        else => unreachable,
                    };
                    const end_val: Value = if (slice.end) |end_expr|
                        try self.lowerExpr(end_expr.*)
                    else
                        base_len;

                    const base_addr = switch (base_ty) {
                        .array => try self.lowerLValueAddress(slice.base.*),
                        else => try self.lowerExpr(slice.base.*),
                    };
                    const ptr_ty: IrType = .{ .ptr = try boxType(self.allocator, elem_ty) };
                    const offset_ptr = try self.emitAt(ptr_ty, .{ .index_addr = .{ .base = base_addr, .index = start_val } }, expr.span);
                    const len = try self.emit(.usize, .{ .binary = .{ .op = .sub, .lhs = end_val, .rhs = start_val } });
                    break :blk try self.emit(self.exprType(expr), .{ .slice_expr = .{ .ptr = offset_ptr, .len = len } });
                }
                switch (base_ty) {
                    .array => |array| {
                        const ptr = try self.lowerLValueAddress(slice.base.*);
                        const len: Value = .{ .imm = .{ .uint = array.len } };
                        break :blk try self.emit(self.exprType(expr), .{ .slice_expr = .{ .ptr = ptr, .len = len } });
                    },
                    .slice => break :blk try self.lowerExpr(slice.base.*),
                    else => {
                        const base = try self.lowerExpr(slice.base.*);
                        break :blk try self.emit(self.exprType(expr), .{ .builtin = .{ .name = "slice", .args = try self.allocator.dupe(Value, &.{base}) } });
                    },
                }
            },
        };
    }

    fn lowerExprAs(self: *FunctionLowerer, expr: ast.Expr, expected_ty: IrType) LowerError!Value {
        if (expected_ty == .interface_value and self.exprType(expr) != .interface_value) {
            return self.lowerInterfaceCoercion(expr, expected_ty.interface_value);
        }
        if (expected_ty == .optional and self.exprType(expr) != .optional and expr.kind != .null) {
            const payload = try self.lowerExpr(expr);
            return self.emit(expected_ty, .{ .builtin = .{
                .name = "optional_some",
                .args = try self.allocator.dupe(Value, &.{payload}),
            } });
        }
        return switch (expr.kind) {
            .compound_literal => |values| blk: {
                var args = std.ArrayList(Value).empty;
                errdefer args.deinit(self.allocator);
                for (values) |value| try args.append(self.allocator, try self.lowerExpr(value));
                break :blk try self.emit(expected_ty, .{ .builtin = .{ .name = "compound_literal", .args = try args.toOwnedSlice(self.allocator) } });
            },
            else => try self.lowerExpr(expr),
        };
    }

    fn lowerLValueAddress(self: *FunctionLowerer, expr: ast.Expr) LowerError!Value {
        const ptr_ty: IrType = .{ .ptr = try boxType(self.allocator, self.exprType(expr)) };
        return switch (expr.kind) {
            .ident => |name| blk: {
                const local: Value = .{ .local = name };
                break :blk try self.emit(ptr_ty, .{ .unary = .{ .op = .ref, .value = local } });
            },
            .field => |field| blk: {
                const base = try self.lowerExpr(field.base.*);
                break :blk try self.emitAt(ptr_ty, .{ .field_addr = .{ .base = base, .name = field.name } }, expr.span);
            },
            .index => |index| blk: {
                const base_ty = self.exprType(index.base.*);
                const base = switch (base_ty) {
                    .array => try self.lowerLValueAddress(index.base.*),
                    else => try self.lowerExpr(index.base.*),
                };
                const idx = try self.lowerExpr(index.index.*);
                break :blk try self.emitAt(ptr_ty, .{ .index_addr = .{ .base = base, .index = idx } }, expr.span);
            },
            .unary => |unary| switch (unary.op) {
                .deref => try self.lowerExpr(unary.expr.*),
                else => try self.emit(ptr_ty, .{ .unary = .{ .op = .ref, .value = try self.lowerExpr(expr) } }),
            },
            else => try self.emit(ptr_ty, .{ .unary = .{ .op = .ref, .value = try self.lowerExpr(expr) } }),
        };
    }

    /// Try to evaluate a #if condition at compile time.
    /// Returns the block to emit (then or else), or null if condition is dynamic.
    /// `expr!!` — unwrap or call the runtime panic path.
    fn lowerForceUnwrap(self: *FunctionLowerer, inner: ast.Expr, outer: ast.Expr) LowerError!Value {
        const lhs = try self.lowerExpr(inner);
        const is_some = try self.emit(.bool, .{ .optional_is_some = lhs });

        const value_id = self.allocBlockId();
        const panic_id = self.allocBlockId();
        try self.terminate(.{ .cond_branch = .{
            .cond = is_some,
            .then_block = value_id,
            .else_block = panic_id,
        } });

        // All generated traps share the structured panic terminator.
        self.startBlock(panic_id, "force_unwrap.panic");
        try self.terminatePanic("attempted to unwrap an empty optional", outer.span);

        // Happy path — extract the payload.
        self.startBlock(value_id, "force_unwrap.ok");
        return try self.emit(self.exprType(outer), .{ .optional_payload = lhs });
    }

    /// `expr ?? default` — use default value when expr is null/error.
    fn lowerNilCoalesce(self: *FunctionLowerer, nc: ast.NilCoalesceExpr, outer: ast.Expr) LowerError!Value {
        const lhs = try self.lowerExpr(nc.value.*);
        const result_ty = self.exprType(outer);

        const is_some = try self.emit(.bool, .{ .optional_is_some = lhs });
        const value_id = self.allocBlockId();
        const default_id = self.allocBlockId();
        const after_id = self.allocBlockId();

        try self.terminate(.{ .cond_branch = .{
            .cond = is_some,
            .then_block = value_id,
            .else_block = default_id,
        } });

        // Value path — extract payload.
        self.startBlock(value_id, "coalesce.value");
        const payload = try self.emit(result_ty, .{ .optional_payload = lhs });
        try self.emitNoResult(result_ty, .{ .store_local = .{ .name = "__coalesce", .value = payload } });
        try self.terminate(.{ .branch = after_id });

        // Default path — evaluate the default expression.
        self.startBlock(default_id, "coalesce.default");
        const def_val = try self.lowerExpr(nc.default.*);
        try self.emitNoResult(result_ty, .{ .store_local = .{ .name = "__coalesce", .value = def_val } });
        try self.terminate(.{ .branch = after_id });

        // After — load the result.
        self.startBlock(after_id, "coalesce.after");
        return .{ .local = "__coalesce" };
    }

    fn evalComptimeIf(self: *FunctionLowerer, ci: ast.ComptimeIfStmt) ?ast.Block {
        var ctx = comptime_mod.ComptimeCtx.init(
            self.allocator,
            self.module,
            self.symbols,
            &self.types,
        );
        defer ctx.deinit();
        const cv = comptime_mod.evalExpr(&ctx, ci.condition) catch return null;
        return switch (cv) {
            .bool => |b| if (b) ci.then_block else ci.else_block orelse ast.Block{ .statements = &.{}, .span = ci.span },
            else => null,
        };
    }

    fn lowerMatch(self: *FunctionLowerer, m: ast.MatchStmt) LowerError!void {
        // Evaluate the subject once.
        const subject = try self.lowerExpr(m.subject);

        // Get enum type name for variant_is instructions.
        // Try three sources in order:
        //   1. sema expr_types (most accurate)
        //   2. param type annotation (when subject is a param ident)
        //   3. empty string (fall-through, match will still work structurally)
        const enum_name: []const u8 = blk: {
            // 1. sema expr_types
            if (self.types.expr_types.get(m.subject.id)) |sema_ty| switch (sema_ty) {
                .named => |id| break :blk self.symbols.symbol(id).name,
                else => {},
            };
            // 2. param type annotation
            if (m.subject.kind == .ident) {
                const ident_name = m.subject.kind.ident;
                for (self.params) |p| {
                    if (std.mem.eql(u8, p.name, ident_name)) {
                        switch (p.ty) {
                            .named => |named| break :blk named.name,
                            else => {},
                        }
                    }
                }
            }
            break :blk "";
        };

        const after_id = self.allocBlockId();

        for (m.arms) |arm| {
            const arm_id = self.allocBlockId();
            const next_id = self.allocBlockId();

            if (arm.pattern == .else_arm) {
                // else arm — fall through from failed checks
                try self.terminate(.{ .branch = arm_id });
                self.startBlock(arm_id, "match.else");
                if (arm.binding) |bname| {
                    try self.emitNoResult(.void, .{ .store_local = .{ .name = bname, .value = subject } });
                }
                try self.lowerBlock(arm.body.statements, .{ .branch = after_id });
                break; // else must be last
            }

            const check = switch (arm.pattern) {
                .enum_variant => |variant| try self.emit(.bool, .{ .variant_is = .{
                    .value = subject,
                    .type_name = enum_name,
                    .variant = variant,
                } }),
                .int_values => |values| blk: {
                    var combined: ?Value = null;
                    for (values) |value| {
                        const equal = try self.emit(.bool, .{ .binary = .{
                            .op = .eq,
                            .lhs = subject,
                            .rhs = try self.lowerExpr(value),
                        } });
                        combined = if (combined) |previous|
                            try self.emit(.bool, .{ .binary = .{
                                .op = .or_op,
                                .lhs = previous,
                                .rhs = equal,
                            } })
                        else
                            equal;
                    }
                    break :blk combined orelse Value{ .imm = .{ .bool = false } };
                },
                .else_arm => unreachable,
            };
            try self.terminate(.{ .cond_branch = .{ .cond = check, .then_block = arm_id, .else_block = next_id } });

            // Arm body.
            self.startBlock(arm_id, "match.arm");
            if (arm.binding) |bname| {
                const variant = arm.pattern.enum_variant;
                const payload = try self.emit(.unknown, .{ .variant_payload = .{
                    .value = subject,
                    .type_name = enum_name,
                    .variant = variant,
                } });
                try self.emitNoResult(.void, .{ .store_local = .{ .name = bname, .value = payload } });
            }
            try self.lowerBlock(arm.body.statements, .{ .branch = after_id });

            self.startBlock(next_id, "match.next");
        }

        // If no else arm, fall through to after.
        if (!self.current_terminated) try self.terminate(.{ .branch = after_id });
        self.startBlock(after_id, "match.after");
    }

    fn emitDefersDown(self: *FunctionLowerer, floor: usize, path: DeferPath) LowerError!void {
        var i = self.defers.items.len;
        while (i > floor) {
            i -= 1;
            const deferred = self.defers.items[i];
            if (!deferRunsOn(deferred.mode, path)) continue;
            for (deferred.body.statements) |ds| try self.lowerStmt(ds);
        }
    }

    // Lower a lexical block with automatic defer cleanup on normal fallthrough.
    // on_fallthrough: terminator to emit if the block does not terminate itself
    // (pass null to let the caller handle it).
    fn lowerBlock(self: *FunctionLowerer, stmts: []const ast.Stmt, on_fallthrough: ?Terminator) LowerError!void {
        const floor = self.defers.items.len;
        for (stmts) |s| try self.lowerStmt(s);
        if (!self.current_terminated) {
            try self.emitDefersDown(floor, .ok);
            if (on_fallthrough) |term| try self.terminate(term);
        }
        self.defers.items.len = floor;
    }

    /// Parse asm(volatile, "template", inputs: { "D"(v), ... }, outputs: { "=a"(T) }, clobbers: { "rcx" })
    /// and lower it to an InlineAsmInstr with a proper LLVM constraint string.
    fn lowerAsmCall(self: *FunctionLowerer, call: ast.CallExpr, expr: ast.Expr) LowerError!Value {
        var is_volatile = false;
        var template: []const u8 = "";
        var constraints = std.ArrayList(u8).empty;
        errdefer constraints.deinit(self.allocator);
        var input_args = std.ArrayList(Value).empty;
        errdefer input_args.deinit(self.allocator);

        // Positional args: [volatile_kw, template_str]
        var pos: usize = 0;
        for (call.args) |arg| {
            const e = switch (arg) {
                .positional => |e| e,
                else => continue,
            };
            if (pos == 0) is_volatile = e.kind == .ident and std.mem.eql(u8, e.kind.ident, "volatile");
            if (pos == 1) template = switch (e.kind) {
                .string => |s| trimQuotes(s),
                else => "",
            };
            pos += 1;
        }

        // LLVM constraint order: outputs, inputs, clobbers.
        for (call.args) |arg| {
            const n = switch (arg) {
                .named => |n| n,
                else => continue,
            };
            const items = switch (n.value.kind) {
                .compound_literal => |c| c,
                else => continue,
            };

            if (std.mem.eql(u8, n.name, "outputs")) {
                for (items) |item| {
                    const c = extractAsmConstraint(item) orelse continue;
                    try constraints.appendSlice(self.allocator, c);
                    try constraints.append(self.allocator, ',');
                    // outputs don't add args — they're return slots
                }
            } else if (std.mem.eql(u8, n.name, "inputs")) {
                for (items) |item| {
                    const c = extractAsmConstraint(item) orelse continue;
                    try constraints.appendSlice(self.allocator, c);
                    try constraints.append(self.allocator, ',');
                    // Lower the input value
                    if (item.kind == .call) {
                        const c_args = item.kind.call.args;
                        if (c_args.len > 0) {
                            const val_expr = switch (c_args[0]) {
                                .positional => |e| e,
                                .named => |nn| nn.value,
                            };
                            try input_args.append(self.allocator, try self.lowerExpr(val_expr));
                        }
                    }
                }
            } else if (std.mem.eql(u8, n.name, "clobbers")) {
                for (items) |item| {
                    const s = switch (item.kind) {
                        .string => |s| trimQuotes(s),
                        else => continue,
                    };
                    try constraints.appendSlice(self.allocator, "~{");
                    try constraints.appendSlice(self.allocator, s);
                    try constraints.append(self.allocator, '}');
                    try constraints.append(self.allocator, ',');
                }
            }
        }

        // Remove trailing comma.
        if (constraints.items.len > 0 and constraints.items[constraints.items.len - 1] == ',')
            constraints.items.len -= 1;

        const ty = self.exprType(expr);
        return try self.emit(ty, .{ .inline_asm = .{
            .template = template,
            .constraints = try constraints.toOwnedSlice(self.allocator),
            .args = try input_args.toOwnedSlice(self.allocator),
            .volatile_ = is_volatile,
        } });
    }

    fn lowerZoneMethod(self: *FunctionLowerer, zone_name: []const u8, method: []const u8, args: []const ast.CallArg, expr: ast.Expr) LowerError!Value {
        if (std.mem.eql(u8, method, "new")) {
            if (args.len == 0) return .{ .imm = .null };
            const ty_expr = switch (args[0]) {
                .positional => |e| e,
                .named => |n| n.value,
            };
            const alloc_ty = try self.lowerTypeArg(ty_expr);
            const ptr_ty: IrType = .{ .ptr = try boxType(self.allocator, alloc_ty) };
            return try self.emitAt(ptr_ty, .{ .alloc = .{ .ty = alloc_ty, .zone = zone_name } }, expr.span);
        }
        if (std.mem.eql(u8, method, "new_slice")) {
            if (args.len < 2) return .{ .imm = .null };
            const ty_expr = switch (args[0]) {
                .positional => |e| e,
                .named => |n| n.value,
            };
            const cnt_expr = switch (args[1]) {
                .positional => |e| e,
                .named => |n| n.value,
            };
            const elem_ty = try self.lowerTypeArg(ty_expr);
            const count = try self.lowerExpr(cnt_expr);
            const slice_ty: IrType = .{ .slice = try boxType(self.allocator, elem_ty) };
            return try self.emitAt(slice_ty, .{ .alloc_slice = .{ .elem_ty = elem_ty, .count = count, .zone = zone_name } }, expr.span);
        }
        if (std.mem.eql(u8, method, "free")) {
            if (args.len > 0) {
                const ptr_expr = switch (args[0]) {
                    .positional => |e| e,
                    .named => |n| n.value,
                };
                const ptr = try self.lowerExpr(ptr_expr);
                try self.emitNoResult(.void, .{ .zone_free = .{ .zone = zone_name, .ptr = ptr } });
            }
            return .{ .imm = .null };
        }
        return .{ .imm = .null };
    }

    fn lowerTypeArg(self: *FunctionLowerer, expr: ast.Expr) LowerError!IrType {
        return switch (expr.kind) {
            .type_ref => |ty| lowerType(self.allocator, ty),
            .ident => |name| lowerNamedType(name),
            else => .unknown,
        };
    }

    fn emit(self: *FunctionLowerer, ty: IrType, kind: InstrKind) LowerError!Value {
        if (self.current_terminated) return .{ .imm = .null };
        const id = self.next_reg;
        self.next_reg += 1;
        try self.current_instrs.append(self.allocator, .{ .id = id, .ty = ty, .kind = kind });
        return .{ .reg = id };
    }

    fn emitAt(self: *FunctionLowerer, ty: IrType, kind: InstrKind, span: Span) LowerError!Value {
        if (self.current_terminated) return .{ .imm = .null };
        const id = self.next_reg;
        self.next_reg += 1;
        try self.current_instrs.append(self.allocator, .{
            .id = id,
            .ty = ty,
            .kind = kind,
            .location = self.sourceLocation(span),
        });
        return .{ .reg = id };
    }

    fn emitNoResult(self: *FunctionLowerer, ty: IrType, kind: InstrKind) LowerError!void {
        if (self.current_terminated) return;
        try self.current_instrs.append(self.allocator, .{ .id = null, .ty = ty, .kind = kind });
    }

    fn exprType(self: FunctionLowerer, expr: ast.Expr) IrType {
        const ty = self.types.expr_types.get(expr.id) orelse {
            if (expr.kind == .ident) {
                if (self.local_types.get(expr.kind.ident)) |local_ty| return local_ty;
                for (self.params) |param| if (std.mem.eql(u8, param.name, expr.kind.ident))
                    return lowerAstTypeWithEnv(self.allocator, param.ty, self.types, self.symbols) catch .unknown;
            }
            return .unknown;
        };
        const resolved = resolveTypeParamInTy(ty, self.type_binding);
        return lowerSemaTypeWithEnv(self.allocator, resolved, self.types, self.symbols) catch .unknown;
    }

    fn lowerInterfaceCoercion(self: *FunctionLowerer, expr: ast.Expr, interface_name: []const u8) LowerError!Value {
        const concrete_name = self.concretePointerExprName(expr) orelse return error.LoweringFailed;
        return self.emit(.{ .interface_value = interface_name }, .{ .interface_make = .{
            .data = try self.lowerExpr(expr),
            .vtable = try interfaceVTableName(self.allocator, concrete_name, interface_name),
        } });
    }

    fn concretePointerExprName(self: FunctionLowerer, expr: ast.Expr) ?[]const u8 {
        if (self.types.expr_types.get(expr.id)) |ty| {
            if (concretePointerName(ty, self.symbols)) |name| return name;
        }
        if (expr.kind == .ident) {
            for (self.params) |param| {
                if (!std.mem.eql(u8, param.name, expr.kind.ident)) continue;
                return switch (param.ty) {
                    .pointer, .many_pointer => |ptr| switch (ptr.inner.*) {
                        .named => |named| named.name,
                        else => null,
                    },
                    else => null,
                };
            }
        }
        return null;
    }

    fn interfaceMethodIndex(self: FunctionLowerer, interface_name: []const u8, method_name: []const u8) ?u32 {
        const id = self.symbols.resolve(self.symbols.root_scope, interface_name) orelse return null;
        const layout = self.types.layouts.get(id) orelse return null;
        const methods = switch (layout.kind) {
            .interface_type => |methods| methods,
            else => return null,
        };
        for (methods, 0..) |method, i| if (std.mem.eql(u8, method.name, method_name)) return @intCast(i);
        return null;
    }

    fn allocBlockId(self: *FunctionLowerer) BlockId {
        const id = self.next_block_id;
        self.next_block_id += 1;
        return id;
    }

    fn startBlock(self: *FunctionLowerer, id: BlockId, name: []const u8) void {
        self.current_id = id;
        self.current_name = name;
        self.current_instrs = .empty;
        self.current_terminated = false;
    }

    fn terminate(self: *FunctionLowerer, terminator: Terminator) LowerError!void {
        if (self.current_terminated) return;

        try self.blocks.append(self.allocator, .{
            .id = self.current_id,
            .name = self.current_name,
            .instrs = try self.current_instrs.toOwnedSlice(self.allocator),
            .terminator = terminator,
        });
        self.current_terminated = true;
    }

    fn terminatePanic(self: *FunctionLowerer, message: []const u8, span: Span) LowerError!void {
        try self.terminate(.{ .panic = .{
            .message = message,
            .location = self.sourceLocation(span),
        } });
    }

    fn sourceLocation(self: *const FunctionLowerer, span: Span) SourceLocation {
        const location = span.line_col(self.source);
        return .{
            .file = self.file_name,
            .line = location.line,
            .column = location.col,
        };
    }
};

fn lowerType(allocator: std.mem.Allocator, ty: ast.TypeRef) !IrType {
    return switch (ty) {
        .type_param => .unknown,
        .generic_inst => |gi| .{ .struct_type = gi.name },
        .named => |named| lowerNamedType(named.name),
        .pointer => |ptr| .{ .ptr = try boxType(allocator, try lowerType(allocator, ptr.inner.*)) },
        .many_pointer => |ptr| .{ .ptr = try boxType(allocator, try lowerType(allocator, ptr.inner.*)) },
        .optional => |optional| .{ .optional = try boxType(allocator, try lowerType(allocator, optional.inner.*)) },
        .slice => |slice| .{ .slice = try boxType(allocator, try lowerType(allocator, slice.inner.*)) },
        .borrow => |borrow| try lowerType(allocator, borrow.inner.*),
        .array => |array| .{ .array = .{
            .elem = try boxType(allocator, try lowerType(allocator, array.inner.*)),
            .len = parseArrayLen(array.len.*),
        } },
        .atomic => |atomic| try lowerType(allocator, atomic.inner.*),
        .fn_type => |func| blk: {
            var params = std.ArrayList(IrType).empty;
            errdefer params.deinit(allocator);
            for (func.params) |param| try params.append(allocator, try lowerType(allocator, param));
            const ret_ty = try lowerType(allocator, func.ret.*);
            const final_ret: IrType = if (func.error_ty) |err| .{ .fallible = .{
                .ok = try boxType(allocator, ret_ty),
                .err = try boxType(allocator, try lowerErrorSpec(allocator, err)),
            } } else ret_ty;
            break :blk .{ .fn_ptr = .{
                .params = try params.toOwnedSlice(allocator),
                .ret = try boxType(allocator, final_ret),
            } };
        },
        .inline_error_set => |set| try lowerInlineErrorSet(allocator, set),
        .opaque_type => .{ .opaque_type = "opaque" },
    };
}

fn lowerAstTypeWithEnv(allocator: std.mem.Allocator, ty: ast.TypeRef, types: sema.TypeEnv, symbols: sema.SymbolTable) !IrType {
    if (ty == .borrow) return lowerAstTypeWithEnv(allocator, ty.borrow.inner.*, types, symbols);
    const ptr_inner_ast: ?ast.TypeRef = switch (ty) {
        .pointer => |p| p.inner.*,
        .many_pointer => |p| p.inner.*,
        else => null,
    };
    if (ptr_inner_ast) |inner_ty| switch (inner_ty) {
        .named => |named| if (symbols.resolve(symbols.root_scope, named.name)) |id| {
            if (types.layouts.get(id)) |layout| if (layout.kind == .interface_type)
                return .{ .interface_value = named.name };
        },
        else => {},
    };
    // Distinct type: lower directly to the underlying type.
    if (ty == .named) {
        if (symbols.resolve(symbols.root_scope, ty.named.name)) |id| {
            if (types.distinct_types.get(id)) |underlying| {
                return lowerSemaTypeWithEnv(allocator, underlying, types, symbols);
            }
        }
    }
    return lowerType(allocator, ty);
}

fn lowerErrorSpec(allocator: std.mem.Allocator, spec: ast.ErrorSpec) !IrType {
    return switch (spec) {
        .inferred => .{ .variant_type = "<error>" },
        .named => |named| .{ .variant_type = named.name },
        .inline_set => |set| try lowerInlineErrorSet(allocator, set),
    };
}

fn lowerInlineErrorSet(allocator: std.mem.Allocator, set: ast.InlineErrorSet) !IrType {
    _ = allocator;
    _ = set;
    return .{ .variant_type = "<anonymous-error-set>" };
}

fn lowerNamedType(name: []const u8) IrType {
    // Sub-byte integers — LLVM supports arbitrary-width integers
    if (std.mem.eql(u8, name, "u1")) return .{ .u = 1 };
    if (std.mem.eql(u8, name, "u2")) return .{ .u = 2 };
    if (std.mem.eql(u8, name, "u3")) return .{ .u = 3 };
    if (std.mem.eql(u8, name, "u4")) return .{ .u = 4 };
    if (std.mem.eql(u8, name, "u5")) return .{ .u = 5 };
    if (std.mem.eql(u8, name, "u6")) return .{ .u = 6 };
    if (std.mem.eql(u8, name, "u7")) return .{ .u = 7 };
    if (std.mem.eql(u8, name, "i1")) return .{ .i = 1 };
    if (std.mem.eql(u8, name, "i2")) return .{ .i = 2 };
    if (std.mem.eql(u8, name, "i3")) return .{ .i = 3 };
    if (std.mem.eql(u8, name, "i4")) return .{ .i = 4 };
    if (std.mem.eql(u8, name, "i5")) return .{ .i = 5 };
    if (std.mem.eql(u8, name, "i6")) return .{ .i = 6 };
    if (std.mem.eql(u8, name, "i7")) return .{ .i = 7 };
    if (std.mem.eql(u8, name, "i8")) return .{ .i = 8 };
    if (std.mem.eql(u8, name, "i16")) return .{ .i = 16 };
    if (std.mem.eql(u8, name, "i32")) return .{ .i = 32 };
    if (std.mem.eql(u8, name, "i64")) return .{ .i = 64 };
    if (std.mem.eql(u8, name, "u8")) return .{ .u = 8 };
    if (std.mem.eql(u8, name, "u16")) return .{ .u = 16 };
    if (std.mem.eql(u8, name, "u32")) return .{ .u = 32 };
    if (std.mem.eql(u8, name, "u64")) return .{ .u = 64 };
    if (std.mem.eql(u8, name, "f32")) return .f32;
    if (std.mem.eql(u8, name, "f64")) return .f64;
    if (std.mem.eql(u8, name, "bool")) return .bool;
    if (std.mem.eql(u8, name, "void")) return .void;
    if (std.mem.eql(u8, name, "usize")) return .usize;
    if (std.mem.eql(u8, name, "isize")) return .isize;
    return .{ .struct_type = name };
}

fn resolveTypeParamInTy(ty: sema.Ty, binding: []const sema.TypeArg) sema.Ty {
    return switch (ty) {
        .type_param => |name| blk: {
            for (binding) |arg| {
                if (std.mem.eql(u8, arg.name, name)) break :blk arg.ty;
            }
            break :blk ty;
        },
        else => ty,
    };
}

fn lowerSemaType(allocator: std.mem.Allocator, ty: sema.Ty, symbols: sema.SymbolTable) !IrType {
    return switch (ty) {
        .i8 => .{ .i = 8 },
        .i16 => .{ .i = 16 },
        .i32 => .{ .i = 32 },
        .i64 => .{ .i = 64 },
        .u8, .byte => .{ .u = 8 },
        .u16 => .{ .u = 16 },
        .u32 => .{ .u = 32 },
        .u64 => .{ .u = 64 },
        .f32 => .f32,
        .f64 => .f64,
        .bool => .bool,
        .void => .void,
        .usize => .usize,
        .isize => .isize,
        .pointer, .const_ptr => |inner| .{ .ptr = try boxType(allocator, try lowerSemaType(allocator, inner.*, symbols)) },
        .optional => |inner| .{ .optional = try boxType(allocator, try lowerSemaType(allocator, inner.*, symbols)) },
        .slice => |inner| .{ .slice = try boxType(allocator, try lowerSemaType(allocator, inner.*, symbols)) },
        .borrow => |inner| try lowerSemaType(allocator, inner.*, symbols),
        .array => |array| .{ .array = .{
            .elem = try boxType(allocator, try lowerSemaType(allocator, array.elem.*, symbols)),
            .len = array.len,
        } },
        .named => |id| .{ .struct_type = symbols.symbol(id).name },
        .error_set => .{ .variant_type = "<anonymous-error-set>" },
        .fallible => |fallible| .{ .fallible = .{
            .ok = try boxType(allocator, try lowerSemaType(allocator, fallible.ok.*, symbols)),
            .err = try boxType(allocator, try lowerSemaType(allocator, fallible.err.*, symbols)),
        } },
        .int_lit => .{ .i = 32 },
        .float_lit => .f64,
        .null_ptr => .{ .ptr = try boxType(allocator, .void) },
        .unknown, .error_ty => .unknown,
        else => .unknown,
    };
}

fn lowerSemaTypeWithEnv(allocator: std.mem.Allocator, ty: sema.Ty, types: sema.TypeEnv, symbols: sema.SymbolTable) !IrType {
    const ptr_inner: ?*const sema.Ty = switch (ty) {
        .pointer, .const_ptr => |inner| inner,
        else => null,
    };
    if (ptr_inner) |inner| {
        if (inner.* == .named) {
            const id = inner.named;
            if (types.layouts.get(id)) |layout| if (layout.kind == .interface_type)
                return .{ .interface_value = symbols.symbol(id).name };
        }
    }
    // Distinct type: substitute the underlying type so the IR uses the real representation.
    if (ty == .named) {
        const id = ty.named;
        if (types.distinct_types.get(id)) |underlying| {
            return lowerSemaTypeWithEnv(allocator, underlying, types, symbols);
        }
    }
    return lowerSemaType(allocator, ty, symbols);
}

fn concretePointerName(ty: sema.Ty, symbols: sema.SymbolTable) ?[]const u8 {
    return switch (ty) {
        .pointer, .const_ptr => |inner| switch (inner.*) {
            .named => |id| symbols.symbol(id).name,
            else => null,
        },
        else => null,
    };
}

fn boxType(allocator: std.mem.Allocator, ty: IrType) !*const IrType {
    const ptr = try allocator.create(IrType);
    ptr.* = ty;
    return ptr;
}

fn assignBinOp(op: ast.AssignOp) ?BinOp {
    return switch (op) {
        .assign => null,
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .rem => .rem,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        .shl => .shl,
        .shr => .shr,
    };
}

fn lowerBinOp(op: ast.BinaryOp) BinOp {
    return switch (op) {
        .or_or => .or_op,
        .and_and => .and_op,
        .equal => .eq,
        .not_equal => .ne,
        .less => .lt,
        .le => .le,
        .gt => .gt,
        .ge => .ge,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        .shl => .shl,
        .shr => .shr,
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .rem => .rem,
    };
}

/// Extract the constraint string from an asm operand expression.
/// `"D"(fd)` → "D",  `"=a"(T)` → "=a"
fn extractAsmConstraint(expr: ast.Expr) ?[]const u8 {
    if (expr.kind == .call) {
        return switch (expr.kind.call.callee.kind) {
            .string => |s| trimQuotes(s),
            else => null,
        };
    }
    return null;
}

fn isBuiltinName(name: []const u8) bool {
    inline for (.{
        "truncate_to",
        "ptr_from_int",
        "volatile_store",
        "sizeof",
        "unaligned_read",
        "asm",
        "atomic_load",
        "atomic_store",
        "compound_literal",
        "slice",
    }) |builtin| {
        if (std.mem.eql(u8, name, builtin)) return true;
    }
    return false;
}

/// If `expr` is a `#run inner`, evaluate it via the comptime interpreter and
/// return the resulting Imm.  Falls back to lowerImm for non-#run expressions
/// or when compile-time evaluation fails.
fn effectiveConstImm(allocator: std.mem.Allocator, front_end: pipeline.FrontEnd, expr: ast.Expr) Imm {
    const inner = switch (expr.kind) {
        .run_expr => |e| e.*,
        else => return lowerImm(expr),
    };

    var ctx = comptime_mod.ComptimeCtx.init(
        allocator,
        front_end.module,
        front_end.symbols,
        &front_end.types,
    );
    defer ctx.deinit();

    const cv = comptime_mod.evalExpr(&ctx, inner) catch return lowerImm(inner);
    return comptimeToImm(cv) orelse lowerImm(inner);
}

/// Convert a ComptimeValue to an IR Imm if possible.
fn comptimeToImm(v: comptime_mod.ComptimeValue) ?Imm {
    return switch (v) {
        .int => |i| .{ .int = i },
        .uint => |u| .{ .uint = u },
        .float => |f| .{ .float = f },
        .bool => |b| .{ .bool = b },
        .string => |s| .{ .text = s },
        .null_ptr => .null,
        else => null,
    };
}

/// Convert a ComptimeValue to an IR Value if possible.
fn comptimeToValue(v: comptime_mod.ComptimeValue) ?Value {
    return switch (v) {
        .int => |i| .{ .imm = .{ .int = i } },
        .uint => |u| .{ .imm = .{ .uint = u } },
        .float => |f| .{ .imm = .{ .float = f } },
        .bool => |b| .{ .imm = .{ .bool = b } },
        .string => |s| .{ .imm = .{ .text = s } },
        .null_ptr => .{ .imm = .null },
        else => null,
    };
}

fn inferConstType(expr: ast.Expr) IrType {
    return switch (expr.kind) {
        .int => .{ .i = 32 },
        .float => .f64,
        .unary => |u| if (u.op == .neg) inferConstType(u.expr.*) else .unknown,
        .bool => .bool,
        .string => .text,
        .null => .unknown,
        else => .unknown,
    };
}

fn lowerImm(expr: ast.Expr) Imm {
    return switch (expr.kind) {
        .int => |text| .{ .int = parseIntLiteral(text) },
        .float => |text| .{ .float = parseFloatLiteral(text) },
        .unary => |u| switch (u.op) {
            .neg => switch (u.expr.kind) {
                .int => |text| .{ .int = -parseIntLiteral(text) },
                else => .null,
            },
            else => .null,
        },
        .bool => |value| .{ .bool = value },
        .string => |text| .{ .text = trimQuotes(text) },
        .null => .null,
        else => .null,
    };
}

fn parseArrayLen(expr: ast.Expr) u64 {
    return switch (expr.kind) {
        .int => |text| @intCast(@max(parseIntLiteral(text), 0)),
        else => 0,
    };
}

fn parseIntLiteral(text: []const u8) i128 {
    var value: i128 = 0;
    var negative = false;
    var start: usize = 0;
    if (text.len > 0 and text[0] == '-') {
        negative = true;
        start = 1;
    }

    const radix: i128 = if (text.len >= start + 2 and text[start] == '0' and (text[start + 1] == 'x' or text[start + 1] == 'X')) blk: {
        start += 2;
        break :blk 16;
    } else if (text.len >= start + 2 and text[start] == '0' and (text[start + 1] == 'b' or text[start + 1] == 'B')) blk: {
        start += 2;
        break :blk 2;
    } else 10;

    for (text[start..]) |ch| {
        if (ch == '_') continue;
        const digit: i128 = if (ch >= '0' and ch <= '9')
            ch - '0'
        else if (ch >= 'a' and ch <= 'f')
            10 + ch - 'a'
        else if (ch >= 'A' and ch <= 'F')
            10 + ch - 'A'
        else
            break;
        if (digit >= radix) break;
        value = value * radix + digit;
    }

    return if (negative) -value else value;
}

fn parseFloatLiteral(text: []const u8) f64 {
    // Strip type suffix (f32, f64)
    var end = text.len;
    while (end > 0 and std.ascii.isAlphabetic(text[end - 1])) end -= 1;
    const num = text[0..end];
    if (num.len == 0) return 0.0;
    return std.fmt.parseFloat(f64, num) catch 0.0;
}

fn hasAttr(attrs: []const ast.Attribute, name: []const u8) bool {
    for (attrs) |attr| {
        if (std.mem.eql(u8, attr.name, name)) return true;
    }
    return false;
}

fn alignAttr(attrs: []const ast.Attribute) u32 {
    for (attrs) |attr| {
        if (!std.mem.eql(u8, attr.name, "align")) continue;
        if (attr.args.len == 0) continue;
        return switch (attr.args[0].kind) {
            .int => |text| @intCast(@max(parseIntLiteral(text), 0)),
            else => 0,
        };
    }
    return 0;
}

fn externName(attrs: []const ast.Attribute) ?[]const u8 {
    for (attrs) |attr| {
        if ((!std.mem.eql(u8, attr.name, "extern") and !std.mem.eql(u8, attr.name, "foreign")) or attr.args.len < 2) continue;
        return switch (attr.args[1].kind) {
            .string => |value| trimQuotes(value),
            else => null,
        };
    }
    return null;
}

/// The library name from `#extern("lib", "symbol")` (or its `#foreign` alias)
/// — the first argument. This tells the linker which import library to pull
/// the symbol from (e.g. `#extern("raylib", "InitWindow")` / `#foreign("raylib",
/// "InitWindow")` requires linking `raylib.lib`).
fn externLibName(attrs: []const ast.Attribute) ?[]const u8 {
    for (attrs) |attr| {
        if ((!std.mem.eql(u8, attr.name, "extern") and !std.mem.eql(u8, attr.name, "foreign")) or attr.args.len < 2) continue;
        return switch (attr.args[0].kind) {
            .string => |value| trimQuotes(value),
            else => null,
        };
    }
    return null;
}

/// Adds `lib` to `extern_libs` if not already present, skipping `kernel32`
/// (always linked by the Windows backend regardless). Used to collect import
/// library dependencies from both `#extern`/`#foreign` decls and standalone
/// `#system_library("name");` declarations.
fn addExternLib(allocator: std.mem.Allocator, extern_libs: *std.ArrayList([]const u8), lib: []const u8) !void {
    if (std.mem.eql(u8, lib, "kernel32")) return;
    for (extern_libs.items) |existing| {
        if (std.mem.eql(u8, existing, lib)) return;
    }
    try extern_libs.append(allocator, lib);
}

fn trimQuotes(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
        return text[1 .. text.len - 1];
    }
    return text;
}
