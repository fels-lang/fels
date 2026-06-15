"""Writes obsidian/x64_tests.fels: each case below is a call of the encoder in x64.fels and the same
instruction in Intel syntax; llvm-mc encodes the instruction, and the test checks that the encoder
writes the same bytes.

    python obsidian/tools/gen_x64_tests.py [path to llvm-mc]

Run it again after adding cases; the generated file is checked in, so the tests need no llvm-mc.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', 'x64_tests.fels')

# (call, Intel syntax). In the call, `c` is the code buffer; upper-case names are x64's constants.
GROUPS = {
    'moves': [
        ('mov_rr(c, 8, RAX, RCX)', 'mov rax, rcx'),
        ('mov_rr(c, 8, R8, R15)', 'mov r8, r15'),
        ('mov_rr(c, 4, RAX, R9)', 'mov eax, r9d'),
        ('mov_rr(c, 2, RCX, RDX)', 'mov cx, dx'),
        ('mov_rr(c, 1, RAX, RCX)', 'mov al, cl'),
        ('mov_rr(c, 1, RSI, RDI)', 'mov sil, dil'),
        ('mov_rr(c, 1, R10, RBX)', 'mov r10b, bl'),
        ('mov_rm(c, 8, RAX, at(RBP, -16))', 'mov rax, qword ptr [rbp - 16]'),
        ('mov_rm(c, 4, RAX, at(RBP, -28))', 'mov eax, dword ptr [rbp - 28]'),
        ('mov_rm(c, 8, RCX, at(RBP, 0))', 'mov rcx, qword ptr [rbp]'),
        ('mov_rm(c, 8, RCX, at(R13, 0))', 'mov rcx, qword ptr [r13]'),
        ('mov_rm(c, 8, RDX, at(RSP, 8))', 'mov rdx, qword ptr [rsp + 8]'),
        ('mov_rm(c, 8, RDX, at(R12, 0))', 'mov rdx, qword ptr [r12]'),
        ('mov_rm(c, 8, R11, at(RAX, 200))', 'mov r11, qword ptr [rax + 200]'),
        ('mov_rm(c, 8, RAX, at(RAX, -129))', 'mov rax, qword ptr [rax - 129]'),
        ('mov_rm(c, 4, RAX, at_index(RAX, RCX, 4, 0))', 'mov eax, dword ptr [rax + 4*rcx]'),
        ('mov_rm(c, 8, R8, at_index(R9, R10, 8, 16))', 'mov r8, qword ptr [r9 + 8*r10 + 16]'),
        ('mov_rm(c, 1, RAX, at_index(RSI, RDX, 1, -1))', 'mov al, byte ptr [rsi + rdx - 1]'),
        ('mov_rm(c, 8, RAX, at_index(RBP, RAX, 2, 0))', 'mov rax, qword ptr [rbp + 2*rax]'),
        ('mov_rm(c, 8, RAX, at(RIP, 100))', 'mov rax, qword ptr [rip + 100]'),
        ('mov_mr(c, 4, at(RBP, -28), RAX)', 'mov dword ptr [rbp - 28], eax'),
        ('mov_mr(c, 8, at(RSP, 0), R14)', 'mov qword ptr [rsp], r14'),
        ('mov_mr(c, 2, at(RDI, 6), RCX)', 'mov word ptr [rdi + 6], cx'),
        ('mov_mr(c, 1, at(RDI, 6), RSI)', 'mov byte ptr [rdi + 6], sil'),
        ('mov_ri(c, 8, RAX, 5)', 'mov eax, 5'),
        ('mov_ri(c, 8, R9, 4294967295)', 'mov r9d, 4294967295'),
        ('mov_ri(c, 8, RAX, -1)', 'mov rax, -1'),
        ('mov_ri(c, 8, RCX, -2147483648)', 'mov rcx, -2147483648'),
        ('mov_ri(c, 8, RDX, 81985529216486895)', 'movabs rdx, 81985529216486895'),
        ('mov_ri(c, 8, R12, -4294967296)', 'movabs r12, -4294967296'),
        ('mov_ri(c, 4, RAX, -1)', 'mov eax, 4294967295'),
        ('mov_ri(c, 2, RBX, 4660)', 'mov bx, 4660'),
        ('mov_ri(c, 1, RDI, 9)', 'mov dil, 9'),
        ('mov_mi(c, 8, at(RBP, -8), 0)', 'mov qword ptr [rbp - 8], 0'),
        ('mov_mi(c, 4, at(RAX, 4), -7)', 'mov dword ptr [rax + 4], -7'),
        ('mov_mi(c, 1, at(RCX, 0), 255)', 'mov byte ptr [rcx], 255'),
        ('lea(c, 8, RAX, at_index(RSI, RCX, 4, 16))', 'lea rax, [rsi + 4*rcx + 16]'),
        ('lea(c, 8, R10, at(RIP, -7))', 'lea r10, [rip - 7]'),
        ('movzx_rr(c, 4, RAX, 1, RCX)', 'movzx eax, cl'),
        ('movzx_rr(c, 4, RAX, 1, RSI)', 'movzx eax, sil'),
        ('movzx_rr(c, 8, R8, 2, RAX)', 'movzx r8, ax'),
        ('movzx_rm(c, 4, RAX, 1, at(RDX, 3))', 'movzx eax, byte ptr [rdx + 3]'),
        ('movsx_rr(c, 8, RAX, 4, RCX)', 'movsxd rax, ecx'),
        ('movsx_rr(c, 4, RDX, 1, RBX)', 'movsx edx, bl'),
        ('movsx_rr(c, 8, R9, 2, R10)', 'movsx r9, r10w'),
        ('movsx_rm(c, 8, RAX, 4, at(RBP, -4))', 'movsxd rax, dword ptr [rbp - 4]'),
    ],
    'arithmetic': [
        ('alu_rr(c, ALU_ADD, 8, RAX, RCX)', 'add rax, rcx'),
        ('alu_rr(c, ALU_SUB, 4, R8, RDX)', 'sub r8d, edx'),
        ('alu_rr(c, ALU_XOR, 4, RAX, RAX)', 'xor eax, eax'),
        ('alu_rr(c, ALU_CMP, 8, RCX, R11)', 'cmp rcx, r11'),
        ('alu_rr(c, ALU_AND, 1, RSI, RAX)', 'and sil, al'),
        ('alu_rr(c, ALU_OR, 2, RCX, RDX)', 'or cx, dx'),
        ('alu_rm(c, ALU_ADD, 4, RAX, at(RBP, -28))', 'add eax, dword ptr [rbp - 28]'),
        ('alu_rm(c, ALU_CMP, 8, RCX, at(RBP, -8))', 'cmp rcx, qword ptr [rbp - 8]'),
        ('alu_mr(c, ALU_ADD, 8, at(RAX, 0), RCX)', 'add qword ptr [rax], rcx'),
        ('alu_ri(c, ALU_ADD, 8, RSP, 8)', 'add rsp, 8'),
        ('alu_ri(c, ALU_SUB, 8, RSP, 4096)', 'sub rsp, 4096'),
        ('alu_ri(c, ALU_CMP, 4, RAX, 127)', 'cmp eax, 127'),
        ('alu_ri(c, ALU_CMP, 4, RAX, 128)', 'cmp eax, 128'),
        ('alu_ri(c, ALU_AND, 8, R9, -128)', 'and r9, -128'),
        ('alu_ri(c, ALU_AND, 8, R9, -129)', 'and r9, -129'),
        ('alu_ri(c, ALU_XOR, 1, RDI, 1)', 'xor dil, 1'),
        ('alu_ri(c, ALU_OR, 2, RAX, 1000)', 'or ax, 1000'),
        ('alu_ri(c, ALU_ADD, 1, RAX, 1)', 'add al, 1'),
        ('alu_ri(c, ALU_SUB, 8, RAX, 300)', 'sub rax, 300'),
        ('alu_ri(c, ALU_ADD, 4, RAX, 3)', 'add eax, 3'),
        ('alu_ri(c, ALU_CMP, 4, RCX, 128)', 'cmp ecx, 128'),
        ('alu_mi(c, ALU_ADD, 4, at(RBP, -12), 1)', 'add dword ptr [rbp - 12], 1'),
        ('alu_mi(c, ALU_CMP, 8, at(RSP, 16), 100000)', 'cmp qword ptr [rsp + 16], 100000'),
        ('test_rr(c, 8, RAX, RAX)', 'test rax, rax'),
        ('test_rr(c, 4, RDX, RDX)', 'test edx, edx'),
        ('test_rr(c, 1, RSI, RSI)', 'test sil, sil'),
        ('test_ri(c, 4, RAX, 1)', 'test eax, 1'),
        ('test_ri(c, 1, RCX, 128)', 'test cl, -128'),
        ('test_ri(c, 1, RAX, 1)', 'test al, 1'),
        ('test_ri(c, 8, RAX, 255)', 'test rax, 255'),
        ('test_ri(c, 4, R8, 1)', 'test r8d, 1'),
        ('imul_rr(c, 8, RAX, RCX)', 'imul rax, rcx'),
        ('imul_rr(c, 4, R12, R13)', 'imul r12d, r13d'),
        ('imul_rri(c, 8, RAX, RCX, 31)', 'imul rax, rcx, 31'),
        ('imul_rri(c, 4, RDX, RDX, 1000)', 'imul edx, edx, 1000'),
        ('not_r(c, 8, RAX)', 'not rax'),
        ('neg_r(c, 4, R10)', 'neg r10d'),
        ('mul_r(c, 8, RCX)', 'mul rcx'),
        ('div_r(c, 4, RBX)', 'div ebx'),
        ('idiv_r(c, 8, R8)', 'idiv r8'),
        ('sign_extend_rax(c, 8)', 'cqo'),
        ('sign_extend_rax(c, 4)', 'cdq'),
        ('shift_cl(c, SH_SHL, 8, RAX)', 'shl rax, cl'),
        ('shift_cl(c, SH_SAR, 4, RDX)', 'sar edx, cl'),
        ('shift_ri(c, SH_SHR, 8, RAX, 1)', 'shr rax, 1'),
        ('shift_ri(c, SH_SHL, 4, R9, 3)', 'shl r9d, 3'),
        ('shift_ri(c, SH_SAR, 8, RCX, 63)', 'sar rcx, 63'),
        ('shift_ri(c, SH_ROL, 1, RAX, 4)', 'rol al, 4'),
    ],
    'control': [
        ('push_r(c, RBP)', 'push rbp'),
        ('push_r(c, R12)', 'push r12'),
        ('pop_r(c, RBX)', 'pop rbx'),
        ('pop_r(c, R15)', 'pop r15'),
        ('ret(c)', 'ret'),
        ('leave(c)', 'leave'),
        ('int3(c)', 'int3'),
        ('ud2(c)', 'ud2'),
        ('syscall(c)', 'syscall'),
        ('nop(c)', 'nop'),
        ('call_r(c, RAX)', 'call rax'),
        ('call_r(c, R11)', 'call r11'),
        ('call_m(c, at(RIP, 64))', 'call qword ptr [rip + 64]'),
        ('jmp_r(c, RCX)', 'jmp rcx'),
        ('setcc(c, CC_E, RAX)', 'sete al'),
        ('setcc(c, CC_L, RSI)', 'setl sil'),
        ('setcc(c, CC_A, R9)', 'seta r9b'),
        ('cmovcc(c, CC_NE, 8, RAX, RCX)', 'cmovne rax, rcx'),
        ('cmovcc(c, CC_GE, 4, R8, RDX)', 'cmovge r8d, edx'),
        ('rep_movsb(c)', 'rep movsb byte ptr es:[rdi], byte ptr [rsi]'),
        ('rep_stosb(c)', 'rep stosb byte ptr es:[rdi], al'),
    ],
    'floats': [
        ('fmov_xx(c, 8, XMM0, XMM1)', 'movsd xmm0, xmm1'),
        ('fmov_xx(c, 4, XMM8, XMM2)', 'movss xmm8, xmm2'),
        ('fmov_xm(c, 8, XMM1, at(RBP, -16))', 'movsd xmm1, qword ptr [rbp - 16]'),
        ('fmov_mx(c, 8, at(RSP, 8), XMM15)', 'movsd qword ptr [rsp + 8], xmm15'),
        ('fmov_mx(c, 4, at(RAX, 0), XMM3)', 'movss dword ptr [rax], xmm3'),
        ('fop_xx(c, FP_ADD, 8, XMM0, XMM1)', 'addsd xmm0, xmm1'),
        ('fop_xx(c, FP_MUL, 4, XMM2, XMM3)', 'mulss xmm2, xmm3'),
        ('fop_xx(c, FP_SUB, 8, XMM8, XMM0)', 'subsd xmm8, xmm0'),
        ('fop_xx(c, FP_DIV, 8, XMM4, XMM15)', 'divsd xmm4, xmm15'),
        ('fop_xx(c, FP_SQRT, 8, XMM0, XMM0)', 'sqrtsd xmm0, xmm0'),
        ('fop_xx(c, FP_MIN, 4, XMM1, XMM2)', 'minss xmm1, xmm2'),
        ('fop_xm(c, FP_ADD, 8, XMM0, at(RBP, -24))', 'addsd xmm0, qword ptr [rbp - 24]'),
        ('fcmp_xx(c, 8, XMM0, XMM1)', 'ucomisd xmm0, xmm1'),
        ('fcmp_xx(c, 4, XMM8, XMM2)', 'ucomiss xmm8, xmm2'),
        ('cvt_int_to_fp(c, 8, 8, XMM0, RAX)', 'cvtsi2sd xmm0, rax'),
        ('cvt_int_to_fp(c, 8, 4, XMM1, RCX)', 'cvtsi2sd xmm1, ecx'),
        ('cvt_int_to_fp(c, 4, 8, XMM8, R9)', 'cvtsi2ss xmm8, r9'),
        ('cvt_fp_to_int(c, 8, 8, RAX, XMM0)', 'cvttsd2si rax, xmm0'),
        ('cvt_fp_to_int(c, 4, 4, RDX, XMM9)', 'cvttss2si edx, xmm9'),
        ('cvt_fp_to_fp(c, 8, XMM0, XMM1)', 'cvtss2sd xmm0, xmm1'),
        ('cvt_fp_to_fp(c, 4, XMM2, XMM3)', 'cvtsd2ss xmm2, xmm3'),
        ('movq_xr(c, XMM0, RAX)', 'movq xmm0, rax'),
        ('movq_rx(c, RCX, XMM1)', 'movq rcx, xmm1'),
        ('movq_xr(c, XMM8, R10)', 'movq xmm8, r10'),
        ('fxor_xx(c, 8, XMM0, XMM0)', 'xorpd xmm0, xmm0'),
        ('fxor_xx(c, 4, XMM1, XMM9)', 'xorps xmm1, xmm9'),
    ],
}

# Jumps to labels, by hand: llvm-mc picks the 2-byte forms where it can, and the encoder always
# writes the 5- and 6-byte ones.
LABEL_TESTS = """
#test
a_loop_jumps_back_and_out :: fn(t: *Test) {
    a := heap::make();
    c := x64::code(&a);
    top := c.new_label();
    out := c.new_label();
    c.bind(top);
    x64::alu_rr(&c, x64::ALU_ADD, 8, x64::RAX, x64::RCX);
    x64::jcc(&c, x64::CC_E, out);
    x64::jmp(&c, top);
    c.bind(out);
    x64::ret(&c);
    c.finish();
    // add rax, rcx; je +5; jmp -14; ret
    check(t, &c, &a, "loop", "4801c80f8405000000e9f2ffffffc3");
}

#test
a_jump_to_the_next_instruction_goes_no_distance :: fn(t: *Test) {
    a := heap::make();
    c := x64::code(&a);
    next := c.new_label();
    x64::jmp(&c, next);
    c.bind(next);
    x64::jcc(&c, x64::CC_NE, next);
    c.finish();
    check(t, &c, &a, "jmp next; jne next", "e9000000000f85faffffff");
}

#test
a_call_is_patched_by_its_caller :: fn(t: *Test) {
    a := heap::make();
    c := x64::code(&a);
    x64::push_r(&c, x64::RBP);
    at := x64::call_rel32(&c);
    t.eq(at, 2);
    c.patch32(at, 4294967289u32);
    check(t, &c, &a, "push rbp; call -7", "55e8f9ffffff");
}
"""

CONSTS = re.compile(r'\b(R[A-Z0-9]+|XMM[0-9]+|NO_REG|RIP|CC_[A-Z]+|ALU_[A-Z]+|SH_[A-Z]+|FP_[A-Z]+)\b')
CALL = re.compile(r'^([a-z_0-9]+)\(c(, )?')


def encode(llvm_mc, asm_lines):
    src = '.intel_syntax noprefix\n' + '\n'.join(asm_lines) + '\n'
    p = subprocess.run([llvm_mc, '-triple=x86_64-pc-windows-msvc', '-show-encoding'], input=src,
                       capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(p.stderr)
    out = []
    for line in p.stdout.splitlines():
        m = re.search(r'encoding: \[([^\]]*)\]', line)
        if m:
            out.append(''.join(b.strip()[2:].rjust(2, '0') for b in m.group(1).split(',')))
    if len(out) != len(asm_lines):
        sys.exit(f'llvm-mc gave {len(out)} encodings for {len(asm_lines)} lines:\n{p.stdout}\n{p.stderr}')
    return out


def fels_call(call):
    call = CONSTS.sub(lambda m: 'x64::' + m.group(1), call)
    call = re.sub(r'\b(at|at_index)\(', r'x64::\1(', call)
    return CALL.sub(lambda m: f'x64::{m.group(1)}(&c{m.group(2) or ""}', call)


def main():
    llvm_mc = sys.argv[1] if len(sys.argv) > 1 else 'llvm-mc'
    lines = [
        '// SPDX-License-Identifier: Apache-2.0',
        '// Generated by obsidian/tools/gen_x64_tests.py from llvm-mc: every encoding the encoder',
        '// writes, against the one llvm-mc gives the same instruction. Do not edit; add a case there.',
        '#import std.heap as heap;',
        '#import std.io as io;',
        '#import x64;',
        '',
        '/// The bytes of `c` as lower-case hex.',
        'hex :: fn(c: *x64::Code, a: *heap::Arena) -> []const u8 {',
        '    digits := "0123456789abcdef";',
        '    out := heap::alloc(u8, a, c.len() * 2);',
        '    for i in 0..c.len() {',
        '        b := c.bytes.get(i);',
        '        out[2 * i] = digits[(b >> 4u8) as usize];',
        '        out[2 * i + 1] = digits[(b & 15u8) as usize];',
        '    }',
        '    return out;',
        '}',
        '',
        '/// Check that `c` holds `want` (hex) and empty it.',
        'check :: fn(t: *Test, c: *x64::Code, a: *heap::Arena, asm_text: []const u8, want: []const u8) {',
        '    got := hex(c, a);',
        '    if !(got == want) { io::println("{asm_text}: encoded {got}, want {want}") catch e {}; }',
        '    t.eq(got, want);',
        '    c.bytes.clear();',
        '}',
    ]
    for group, cases in GROUPS.items():
        encodings = encode(llvm_mc, [asm for _, asm in cases])
        lines += ['', '#test', f'{group} :: fn(t: *Test) {{', '    a := heap::make();', '    c := x64::code(&a);']
        for (call, asm), enc in zip(cases, encodings):
            lines.append(f'    {fels_call(call)};')
            lines.append(f'    check(t, &c, &a, "{asm}", "{enc}");')
        lines.append('}')
    with open(OUT, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(lines) + '\n' + LABEL_TESTS)
    print(f'wrote {OUT}: {sum(len(c) for c in GROUPS.values())} cases')


if __name__ == '__main__':
    main()
