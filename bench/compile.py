#!/usr/bin/env python3
"""How fast Fels compiles: a generated program of ordinary code, built in debug mode, timed phase
by phase.

    python bench/compile.py                     # 100 000 lines, the best of 3 builds
    python bench/compile.py --lines 1000000
    python bench/compile.py --fels zig-out/bin/fels.exe --json out.json

The program is many functions of one 20-line shape: integer arithmetic, a loop over a slice and a
`while` loop, struct fields through a pointer, a struct literal, and a call of the function before
it. It is the kind of code most of a big program is, and the same at every size, so a phase that
grows faster than the program shows up as a rising cost per line.

The script builds it with `fels build -O0 -t` (a debug build: no optimisation, the safety checks),
runs the program to see that it works, and reports the phases of the fastest build in milliseconds
and microseconds per line, against the goal of a million lines a second: 1 us a line, all phases.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
EXE = '.exe' if os.name == 'nt' else ''
LINES_PER_FN = 20

# The phases `fels build -t` prints, in its order.
PHASES = ['front-end', 'lowering', 'optimise', 'codegen', 'emit object', 'link']
ROW = re.compile(r'^\s*(front-end|lowering|optimise|codegen|emit object|link|total)\s+([0-9.]+) ms\s*$')
ANSI = re.compile(r'\x1b\[[0-9;]*m')


def program(n_lines):
    """The source of a program of about `n_lines` lines."""
    count = max(1, n_lines // LINES_PER_FN)
    lines = ['Vec3 :: struct { x: i64, y: i64, z: i64 }', '']
    for i in range(count):
        call = f'    if a > 0 {{ s = s +% f{i - 1}(a - 1, v, xs); }}' if i > 0 else '    s = s +% 1;'
        lines += [
            f'f{i} :: fn(a: i64, v: *Vec3, xs: []i64) -> i64 {{',
            f'    s: i64 = a +% {i};',
            '    for k in 0..xs.len {',
            '        if xs[k] > s { s = s +% xs[k]; } else { s = s -% 1; }',
            '    }',
            '    v.x = v.x +% s;',
            '    v.y = v.y ^ (s << 3);',
            '    v.z = v.z +% v.x *% 7;',
            '    t: Vec3 = .{ .x = s, .y = v.y, .z = 3 };',
            '    if t.x > t.y { s = s +% t.z; }',
            '    i := 0;',
            '    while i < 4 {',
            '        s = s *% 31 +% i;',
            '        i += 1;',
            '    }',
            call,
            '    return s;',
            '}',
            '',
            '',
        ]
    lines += [
        'main :: fn() -> i32 {',
        '    v: Vec3 = .{ .x = 1, .y = 2, .z = 3 };',
        '    data: [4]i64 = .{ 1, 2, 3, 4 };',
        f'    r := f{count - 1}(3, &v, data[:]);',
        '    return (r & 127) as i32;',
        '}',
    ]
    return '\n'.join(lines) + '\n', len(lines)


def build(fels, src, exe, std):
    """One `fels build -t`: the phases it reports (ms) and the wall-clock time of the process."""
    # (-O0 given: a release-built fels builds a single file at -O2 by default)
    cmd = [fels, 'build', src, '-o', exe, '-O0', '-t'] + (['--std-path', std] if std else [])
    start = time.perf_counter()
    p = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace')
    wall = (time.perf_counter() - start) * 1000
    if p.returncode != 0:
        sys.exit(f'fels build failed ({p.returncode}):\n{p.stdout}{p.stderr}')
    ms = {}
    for line in (p.stdout + p.stderr).splitlines():
        m = ROW.match(ANSI.sub('', line))
        if m:
            ms[m.group(1)] = float(m.group(2))
    if 'total' not in ms:
        sys.exit(f'no phase timings in the output of {" ".join(cmd)}:\n{p.stdout}{p.stderr}')
    ms['process'] = wall
    return ms


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--lines', type=int, default=100000, help='the size of the program (default 100000)')
    ap.add_argument('--runs', type=int, default=3, help='builds, of which the fastest is reported (default 3)')
    ap.add_argument('--fels', help='the fels to build with (default: fels on PATH)')
    ap.add_argument('--fels-std', help="the standard library to build with (a folder holding std/; default: the compiler's own)")
    ap.add_argument('--json', help='also write the numbers to this file')
    args = ap.parse_args()

    fels = args.fels or shutil.which('fels')
    if not fels:
        sys.exit('no fels on PATH: pass --fels')
    out_dir = os.path.join(HERE, 'out', 'compile')
    os.makedirs(out_dir, exist_ok=True)
    src = os.path.join(out_dir, f'gen{args.lines}.fels')
    exe = os.path.join(out_dir, f'gen{args.lines}{EXE}')
    text, n_lines = program(args.lines)
    with open(src, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    v = subprocess.run([fels, '--version'], capture_output=True, text=True)
    version = (v.stdout + v.stderr).strip()
    print(f'{version}: {n_lines} lines, {n_lines // LINES_PER_FN} functions, best of {args.runs}')

    runs = [build(fels, src, exe, args.fels_std) for _ in range(args.runs)]
    best = min(runs, key=lambda r: r['total'])
    status = subprocess.run([exe]).returncode
    if not 0 <= status < 128:
        sys.exit(f'the program does not run: exit status {status}')

    print(f'\n  {"phase":<14}{"ms":>10}{"us/line":>10}')
    for name in PHASES + ['total', 'process']:
        if name == 'total':
            print('  ' + '-' * 34)
        ms = best.get(name, 0.0)
        print(f'  {name:<14}{ms:>10.1f}{ms * 1000 / n_lines:>10.2f}')
    rate = n_lines / (best['total'] / 1000)
    print(f'\n  {rate:,.0f} lines/s: {best["total"] * 1000 / n_lines:.1f}x short of the goal, a million lines a second')

    if args.json:
        with open(args.json, 'w', encoding='utf-8') as f:
            json.dump({'fels': version, 'lines': n_lines, 'runs': runs, 'best': best, 'lines_per_s': rate}, f, indent=2)


if __name__ == '__main__':
    main()
