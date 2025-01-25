const std = @import("std");
const value = @import("value.zig");

/// Virtual register index. One per IR result, plus scratch registers the
/// compiler allocates for materialised immediates and call arguments.
pub const Reg = u32;

pub const Opcode = enum(u8) {
    nop,

    // ── Constants & moves ────────────────────────────────────────────────
    load_imm, // a = dst; imm = small integer literal
    load_const, // a = dst; imm = index into the function constant pool
    copy, // a = dst; b = src

    // ── Integer arithmetic ───────────────────────────────────────────────
    add_i, sub_i, mul_i, div_i, rem_i, neg_i,

    // ── Float arithmetic ─────────────────────────────────────────────────
    add_f, sub_f, mul_f, div_f, neg_f,

    // ── Bitwise & logic ──────────────────────────────────────────────────
    bit_and, bit_or, bit_xor, bitnot, shl, shr, not_b,

    // ── Comparison (int) ─────────────────────────────────────────────────
    eq_i, ne_i, lt_i, le_i, gt_i, ge_i,

    // ── Comparison (float) ───────────────────────────────────────────────
    eq_f, ne_f, lt_f, le_f, gt_f, ge_f,

    // ── Casts ────────────────────────────────────────────────────────────
    cast_to_float, cast_to_int,

    // ── Locals & globals ─────────────────────────────────────────────────
    load_local, // a = dst; imm = local slot
    store_local, // b = src; imm = local slot
    load_global, // a = dst; imm = global index
    store_global, // b = src; imm = global index

    // ── Control flow ─────────────────────────────────────────────────────
    jmp, // imm = target instruction offset
    br_if, // a = cond; imm = target offset (taken when truthy)
    br_if_not, // a = cond; imm = target offset (taken when falsy)
    call, // a = dst; imm = function index; b = arg base reg; c = arg count
    ret, // a = value reg
    ret_void,

    // ── Zones & aggregates ───────────────────────────────────────────────
    zone_push, // imm = const-pool index of the zone name string
    zone_pop,
    zone_alloc, // a = dst; imm = number of cells (allocated in the top zone)
    field_addr, // a = dst; b = base ptr/ref; imm = field/element cell offset
    load_cell, // a = dst; b = base ptr; imm = cell offset to read
    store_cell, // a = base ptr; b = src value; imm = cell offset to write

    // ── System / diagnostics ─────────────────────────────────────────────
    sys_print, // a = reg to print
    trap, // imm = const-pool index of message string, or -1 for none
};

pub const Instr = struct {
    op: Opcode,
    a: Reg = 0,
    b: Reg = 0,
    c: Reg = 0,
    /// Literal / slot / instruction-offset / pool index. Signed so small
    /// negative integer literals can be loaded directly via `load_imm`.
    imm: i64 = 0,

    pub fn r_r_r(op: Opcode, a: Reg, b: Reg, c: Reg) Instr {
        return .{ .op = op, .a = a, .b = b, .c = c };
    }
    pub fn r_r_imm(op: Opcode, a: Reg, b: Reg, immediate: i64) Instr {
        return .{ .op = op, .a = a, .b = b, .imm = immediate };
    }
    pub fn r_imm(op: Opcode, a: Reg, immediate: i64) Instr {
        return .{ .op = op, .a = a, .imm = immediate };
    }
    pub fn with_imm(op: Opcode, immediate: i64) Instr {
        return .{ .op = op, .imm = immediate };
    }
};

/// A compiled function: a flat instruction stream plus a constant pool for
/// values that don't fit in an inline immediate (wide ints, floats, strings,
/// type values, zone names).
pub const BytecodeFunction = struct {
    name: []const u8,
    instrs: []const Instr,
    /// Size of the per-call register window.
    num_regs: u32,
    /// Number of local slots (parameters first, then named locals).
    num_locals: u32,
    /// How many of `num_locals` are parameters, bound from call arguments.
    num_params: u32 = 0,
    constants: []const value.Value = &.{},

    pub fn deinit(self: *const BytecodeFunction, allocator: std.mem.Allocator) void {
        allocator.free(self.instrs);
        if (self.constants.len != 0) allocator.free(self.constants);
    }
};

/// A compiled module: the function table the VM resolves `call` against.
pub const BytecodeModule = struct {
    functions: []BytecodeFunction,

    pub fn deinit(self: *BytecodeModule, allocator: std.mem.Allocator) void {
        for (self.functions) |*f| f.deinit(allocator);
        allocator.free(self.functions);
    }

    pub fn find(self: *const BytecodeModule, name: []const u8) ?*const BytecodeFunction {
        for (self.functions) |*f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }
};
