const std = @import("std");
const ir = @import("../ir.zig");
const instructions = @import("instructions.zig");
const value = @import("value.zig");

const Instr = instructions.Instr;
const Opcode = instructions.Opcode;
const Reg = instructions.Reg;
const Value = value.Value;
const BytecodeFunction = instructions.BytecodeFunction;
const BytecodeModule = instructions.BytecodeModule;

pub const CompileError = error{
    /// An IR construct this compiler does not lower yet (slices, interfaces,
    /// globals, ranges, …). Honest failure rather than silent wrong code — the
    /// migration ports these incrementally.
    Unsupported,
    OutOfMemory,
};

/// Lower an entire IR module to a runnable bytecode module. Builds the
/// name→index table first so `call` instructions resolve across functions.
pub fn compileModule(allocator: std.mem.Allocator, module: ir.IrModule) CompileError!BytecodeModule {
    var func_map = std.StringHashMap(u32).init(allocator);
    defer func_map.deinit();
    for (module.functions, 0..) |f, i| {
        try func_map.put(f.name, @intCast(i));
    }

    var funcs = try allocator.alloc(BytecodeFunction, module.functions.len);
    var built: usize = 0;
    errdefer {
        for (funcs[0..built]) |*f| f.deinit(allocator);
        allocator.free(funcs);
    }
    for (module.functions) |f| {
        funcs[built] = try compileFunction(allocator, f, &func_map, module.structs);
        built += 1;
    }
    return .{ .functions = funcs };
}

/// Lower a single IR function. `func_map` resolves `call` targets and `structs`
/// resolves field names to cell offsets; pass null/empty for a standalone
/// function with no calls or aggregates.
pub fn compileFunction(
    allocator: std.mem.Allocator,
    func: ir.IrFunction,
    func_map: ?*const std.StringHashMap(u32),
    structs: []const ir.StructDef,
) CompileError!BytecodeFunction {
    var c = FnCompiler.init(allocator, func, func_map, structs);
    defer c.deinit();
    return c.compile();
}

const FnCompiler = struct {
    allocator: std.mem.Allocator,
    func: ir.IrFunction,
    func_map: ?*const std.StringHashMap(u32),
    structs: []const ir.StructDef,

    out: std.ArrayList(Instr) = .empty,
    constants: std.ArrayList(Value) = .empty,
    /// Parameter + named-local name → slot index.
    local_slots: std.StringHashMap(u32),
    /// IR block id → first instruction offset (filled as blocks are emitted).
    block_offsets: std.AutoHashMap(ir.BlockId, u32),
    /// Static type of each result register, for resolving field names.
    reg_types: std.AutoHashMap(ir.RegId, ir.IrType),
    /// Static type of each parameter/local, ditto.
    name_types: std.StringHashMap(ir.IrType),
    next_reg: Reg = 0,

    fn init(
        allocator: std.mem.Allocator,
        func: ir.IrFunction,
        func_map: ?*const std.StringHashMap(u32),
        structs: []const ir.StructDef,
    ) FnCompiler {
        return .{
            .allocator = allocator,
            .func = func,
            .func_map = func_map,
            .structs = structs,
            .local_slots = std.StringHashMap(u32).init(allocator),
            .block_offsets = std.AutoHashMap(ir.BlockId, u32).init(allocator),
            .reg_types = std.AutoHashMap(ir.RegId, ir.IrType).init(allocator),
            .name_types = std.StringHashMap(ir.IrType).init(allocator),
        };
    }

    fn deinit(self: *FnCompiler) void {
        self.out.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        self.local_slots.deinit();
        self.block_offsets.deinit();
        self.reg_types.deinit();
        self.name_types.deinit();
    }

    fn compile(self: *FnCompiler) CompileError!BytecodeFunction {
        try self.collectLocals();
        try self.collectTypes();
        self.seedScratchBase();

        for (self.func.blocks) |block| {
            try self.block_offsets.put(block.id, @intCast(self.out.items.len));
            for (block.instrs) |inst| try self.lowerInstr(inst);
            if (block.terminator) |term| try self.lowerTerminator(term);
        }

        try self.patchJumps();

        return .{
            .name = self.func.name,
            .instrs = try self.out.toOwnedSlice(self.allocator),
            .num_regs = self.next_reg,
            .num_locals = self.local_slots.count(),
            .num_params = @intCast(self.func.params.len),
            .constants = try self.constants.toOwnedSlice(self.allocator),
        };
    }

    // ── Setup passes ─────────────────────────────────────────────────────

    /// Parameters take the leading slots; every `store_local` name gets one too.
    fn collectLocals(self: *FnCompiler) CompileError!void {
        for (self.func.params) |p| _ = try self.ensureSlot(p.name);
        for (self.func.blocks) |block| {
            for (block.instrs) |inst| switch (inst.kind) {
                .store_local => |sl| _ = try self.ensureSlot(sl.name),
                else => {},
            };
        }
    }

    /// Record the static type of every register and named local, so field
    /// accesses can map a field name to its cell offset within its struct.
    fn collectTypes(self: *FnCompiler) CompileError!void {
        for (self.func.params) |p| try self.name_types.put(p.name, p.ty);
        for (self.func.blocks) |block| {
            for (block.instrs) |inst| {
                if (inst.id) |id| try self.reg_types.put(id, inst.ty);
            }
        }
        // Second pass: local types depend on register types resolved above.
        for (self.func.blocks) |block| {
            for (block.instrs) |inst| switch (inst.kind) {
                .store_local => |sl| try self.name_types.put(sl.name, self.typeOf(sl.value)),
                else => {},
            };
        }
    }

    fn ensureSlot(self: *FnCompiler, name: []const u8) CompileError!u32 {
        if (self.local_slots.get(name)) |s| return s;
        const slot: u32 = self.local_slots.count();
        try self.local_slots.put(name, slot);
        return slot;
    }

    /// Scratch registers start just past the highest IR result id.
    fn seedScratchBase(self: *FnCompiler) void {
        var max_id: ?Reg = null;
        for (self.func.blocks) |block| {
            for (block.instrs) |inst| {
                if (inst.id) |id| {
                    if (max_id == null or id > max_id.?) max_id = id;
                }
            }
        }
        self.next_reg = if (max_id) |m| m + 1 else 0;
    }

    fn newReg(self: *FnCompiler) Reg {
        const r = self.next_reg;
        self.next_reg += 1;
        return r;
    }

    fn typeOf(self: *FnCompiler, v: ir.Value) ir.IrType {
        return switch (v) {
            .reg => |r| self.reg_types.get(r) orelse .unknown,
            .param, .local => |n| self.name_types.get(n) orelse .unknown,
            .imm, .global => .unknown,
        };
    }

    // ── Operand resolution ───────────────────────────────────────────────

    /// Resolve an IR value to a register, emitting loads for immediates and
    /// locals/params as needed.
    fn resolveReg(self: *FnCompiler, v: ir.Value) CompileError!Reg {
        switch (v) {
            .reg => |r| return r,
            .imm => |imm| {
                const dst = self.newReg();
                try self.materializeImm(dst, imm);
                return dst;
            },
            .param, .local => |name| {
                const slot = self.local_slots.get(name) orelse return error.Unsupported;
                const dst = self.newReg();
                try self.emit(Instr.r_imm(.load_local, dst, slot));
                return dst;
            },
            .global => return error.Unsupported,
        }
    }

    fn materializeImm(self: *FnCompiler, dst: Reg, imm: ir.Imm) CompileError!void {
        switch (imm) {
            .bool => |b| try self.emit(Instr.r_imm(.load_imm, dst, if (b) 1 else 0)),
            .int => |v| {
                if (std.math.cast(i64, v)) |small| {
                    try self.emit(Instr.r_imm(.load_imm, dst, small));
                } else try self.loadConst(dst, Value.fromImm(imm));
            },
            .uint => |v| {
                if (std.math.cast(i64, v)) |small| {
                    try self.emit(Instr.r_imm(.load_imm, dst, small));
                } else try self.loadConst(dst, Value.fromImm(imm));
            },
            else => try self.loadConst(dst, Value.fromImm(imm)),
        }
    }

    fn loadConst(self: *FnCompiler, dst: Reg, val: Value) CompileError!void {
        const idx = try self.addConst(val);
        try self.emit(Instr.r_imm(.load_const, dst, idx));
    }

    fn addConst(self: *FnCompiler, val: Value) CompileError!i64 {
        const idx: i64 = @intCast(self.constants.items.len);
        try self.constants.append(self.allocator, val);
        return idx;
    }

    // ── Instruction lowering ─────────────────────────────────────────────

    fn lowerInstr(self: *FnCompiler, inst: ir.Instr) CompileError!void {
        const target: Reg = if (inst.id) |id| id else 0;
        switch (inst.kind) {
            .const_value => |imm| try self.materializeImm(target, imm),

            .unary => |un| {
                if (un.op == .deref) {
                    const ptr = try self.resolveReg(un.value);
                    try self.emit(Instr.r_r_imm(.load_cell, target, ptr, 0));
                    return;
                }
                const vr = try self.resolveReg(un.value);
                const op: Opcode = switch (un.op) {
                    .neg => if (isFloat(inst.ty)) .neg_f else .neg_i,
                    .not => .not_b,
                    .bit_not => .bitnot,
                    .ref, .deref => return error.Unsupported,
                };
                try self.emit(Instr.r_r_imm(op, target, vr, 0));
            },

            .binary => |bin| {
                const lr = try self.resolveReg(bin.lhs);
                const rr = try self.resolveReg(bin.rhs);
                const op = try mapBinOp(bin.op, inst.ty);
                try self.emit(Instr.r_r_r(op, target, lr, rr));
            },

            .cast => |cst| {
                const vr = try self.resolveReg(cst.value);
                const op: Opcode = if (isFloat(inst.ty)) .cast_to_float else .cast_to_int;
                try self.emit(Instr.r_r_imm(op, target, vr, 0));
            },

            .store_local => |sl| {
                const slot = self.local_slots.get(sl.name) orelse return error.Unsupported;
                const vr = try self.resolveReg(sl.value);
                try self.emit(Instr.r_r_imm(.store_local, 0, vr, slot));
            },

            .call => |ci| try self.lowerCall(target, ci),

            .builtin => |b| {
                if (std.mem.eql(u8, b.name, "print") and b.args.len >= 1) {
                    const ar = try self.resolveReg(b.args[0]);
                    try self.emit(Instr.r_imm(.sys_print, ar, 0));
                } else if (std.mem.eql(u8, b.name, "panic")) {
                    try self.emit(Instr.with_imm(.trap, -1));
                } else if (std.mem.eql(u8, b.name, "compound_literal")) {
                    // Positional `.{ a, b, ... }` aggregate initializer.
                    try self.lowerCompoundLiteral(target, inst.ty, b.args);
                } else return error.Unsupported;
            },

            // ── Aggregates (Tier C: structs) ─────────────────────────────
            .struct_lit => |sl| try self.lowerStructLit(target, sl),

            .field => |f| {
                const base = try self.resolveReg(f.base);
                const idx = try self.fieldOffset(self.typeOf(f.base), f.name);
                try self.emit(Instr.r_r_imm(.load_cell, target, base, idx));
            },
            .field_addr => |f| {
                const base = try self.resolveReg(f.base);
                const idx = try self.fieldOffset(self.typeOf(f.base), f.name);
                try self.emit(Instr.r_r_imm(.field_addr, target, base, idx));
            },
            .store => |s| {
                const ptr = try self.resolveReg(s.target);
                const vr = try self.resolveReg(s.value);
                try self.emit(Instr.r_r_imm(.store_cell, ptr, vr, 0));
            },
            .at => |a| {
                const ptr = try self.resolveReg(a.value);
                try self.emit(Instr.r_r_imm(.load_cell, target, ptr, 0));
            },

            .alloc => |a| {
                const cells = self.cellCount(a.ty);
                try self.emit(Instr.r_imm(.zone_alloc, target, @intCast(cells)));
            },

            .zone_push => |zp| {
                const idx = try self.addConst(.{ .string = zp.name });
                try self.emit(Instr.with_imm(.zone_push, idx));
            },
            .zone_pop => try self.emit(Instr.with_imm(.zone_pop, 0)),
            .zone_free => {}, // freed wholesale on zone_pop; explicit free is a no-op here

            // Tier C+ (arrays/slices/variants/interfaces/globals) and beyond:
            // not lowered yet.
            else => return error.Unsupported,
        }
    }

    fn lowerStructLit(self: *FnCompiler, target: Reg, sl: ir.StructLitInstr) CompileError!void {
        const def = self.structDef(sl.ty_name) orelse return error.Unsupported;
        try self.emit(Instr.r_imm(.zone_alloc, target, @intCast(def.fields.len)));
        for (sl.fields) |field| {
            const idx = fieldIndex(def, field.name) orelse return error.Unsupported;
            const vr = try self.resolveReg(field.value);
            try self.emit(Instr.r_r_imm(.store_cell, target, vr, idx));
        }
    }

    /// Positional aggregate initializer `.{ v0, v1, ... }` for a struct: cells
    /// are filled in field-declaration order.
    fn lowerCompoundLiteral(self: *FnCompiler, target: Reg, ty: ir.IrType, args: []const ir.Value) CompileError!void {
        const sname = structName(ty) orelse return error.Unsupported;
        const def = self.structDef(sname) orelse return error.Unsupported;
        if (args.len > def.fields.len) return error.Unsupported;
        try self.emit(Instr.r_imm(.zone_alloc, target, @intCast(def.fields.len)));
        for (args, 0..) |arg, i| {
            const vr = try self.resolveReg(arg);
            try self.emit(Instr.r_r_imm(.store_cell, target, vr, @intCast(i)));
        }
    }

    fn lowerCall(self: *FnCompiler, target: Reg, ci: ir.CallInstr) CompileError!void {
        const map = self.func_map orelse return error.Unsupported;
        const fidx = map.get(ci.callee) orelse return error.Unsupported;

        // Reserve a contiguous argument window, then fill it.
        const argc: u32 = @intCast(ci.args.len);
        const base = self.next_reg;
        self.next_reg += argc;
        for (ci.args, 0..) |arg, i| {
            const ar = try self.resolveReg(arg);
            try self.emit(Instr.r_r_imm(.copy, base + @as(Reg, @intCast(i)), ar, 0));
        }
        try self.emit(.{ .op = .call, .a = target, .b = base, .c = argc, .imm = @intCast(fidx) });
    }

    fn lowerTerminator(self: *FnCompiler, term: ir.Terminator) CompileError!void {
        switch (term) {
            .return_value => |opt| {
                if (opt) |v| {
                    const r = try self.resolveReg(v);
                    try self.emit(Instr.r_imm(.ret, r, 0));
                } else try self.emit(Instr.with_imm(.ret_void, 0));
            },
            .branch => |bid| try self.emit(Instr.with_imm(.jmp, @intCast(bid))),
            .cond_branch => |cb| {
                const cr = try self.resolveReg(cb.cond);
                try self.emit(Instr.r_imm(.br_if, cr, @intCast(cb.then_block)));
                try self.emit(Instr.with_imm(.jmp, @intCast(cb.else_block)));
            },
            .fail, .panic => try self.emit(Instr.with_imm(.trap, -1)),
            .unreachable_term => try self.emit(Instr.with_imm(.trap, -1)),
        }
    }

    fn emit(self: *FnCompiler, instr: Instr) CompileError!void {
        try self.out.append(self.allocator, instr);
    }

    /// Rewrite jump targets from IR block ids to instruction offsets.
    fn patchJumps(self: *FnCompiler) CompileError!void {
        for (self.out.items) |*instr| {
            switch (instr.op) {
                .jmp, .br_if, .br_if_not => {
                    const bid: ir.BlockId = @intCast(instr.imm);
                    const off = self.block_offsets.get(bid) orelse return error.Unsupported;
                    instr.imm = @intCast(off);
                },
                else => {},
            }
        }
    }

    // ── Struct layout helpers ────────────────────────────────────────────

    fn structDef(self: *FnCompiler, name: []const u8) ?ir.StructDef {
        for (self.structs) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    /// Cell offset of `field_name` within the struct named by `base_ty`.
    fn fieldOffset(self: *FnCompiler, base_ty: ir.IrType, field_name: []const u8) CompileError!i64 {
        const sname = structName(base_ty) orelse return error.Unsupported;
        const def = self.structDef(sname) orelse return error.Unsupported;
        return fieldIndex(def, field_name) orelse error.Unsupported;
    }

    /// Number of cells a value of `ty` occupies when allocated by `new`.
    fn cellCount(self: *FnCompiler, ty: ir.IrType) usize {
        if (structName(ty)) |sname| {
            if (self.structDef(sname)) |def| return def.fields.len;
        }
        return 1;
    }
};

fn isFloat(ty: ir.IrType) bool {
    return ty == .f32 or ty == .f64;
}

/// Unwrap pointers/optionals to find the underlying struct type name, if any.
fn structName(ty: ir.IrType) ?[]const u8 {
    return switch (ty) {
        .struct_type => |n| n,
        .ptr, .optional => |inner| structName(inner.*),
        else => null,
    };
}

fn fieldIndex(def: ir.StructDef, name: []const u8) ?i64 {
    for (def.fields, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, name)) return @intCast(i);
    }
    return null;
}

fn mapBinOp(op: ir.BinOp, ty: ir.IrType) CompileError!Opcode {
    const f = isFloat(ty);
    return switch (op) {
        .add => if (f) .add_f else .add_i,
        .sub => if (f) .sub_f else .sub_i,
        .mul => if (f) .mul_f else .mul_i,
        .div => if (f) .div_f else .div_i,
        .rem => .rem_i,
        .shl => .shl,
        .shr => .shr,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        .and_op => .bit_and, // booleans are 0/1
        .or_op => .bit_or,
        // Comparisons: operand type isn't carried on the IR binary instr, so
        // this assumes integer operands. Float comparisons are a follow-up.
        .eq => .eq_i,
        .ne => .ne_i,
        .lt => .lt_i,
        .le => .le_i,
        .gt => .gt_i,
        .ge => .ge_i,
        .range, .range_exclusive => error.Unsupported,
    };
}
