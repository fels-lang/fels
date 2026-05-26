#!/usr/bin/env python3
"""Fels benchmarks: the same programs in Fels, C and Zig, built, checked and timed.

    python bench/run.py                     # every benchmark, every variant, 10 timed runs
    python bench/run.py --quick             # small sizes, 3 runs: a smoke test
    python bench/run.py --only nbody,sieve  # some benchmarks
    python bench/run.py --variants c,fels-fast

What it does, in order (see bench/README.md for the why):
  1. builds every benchmark in every variant, timing the build and noting the binary's size;
  2. runs each program once and requires the same output from all of them (a benchmark whose
     outputs differ is reported and left out of the timings);
  3. runs each program `--runs` times after `--warmup` runs, the variants interleaved and in a
     shuffled order every round, and reports the median, the fastest run and the spread;
  4. writes a Markdown report and the raw numbers (JSON) to bench/results/.
"""

import argparse
import datetime
import glob
import json
import os
import platform
import random
import shutil
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
IS_WINDOWS = os.name == 'nt'
EXE = '.exe' if IS_WINDOWS else ''

# Each benchmark: its folder, the size it is timed at (about a second in C on a recent desktop),
# and the size `--quick` uses.
BENCHMARKS = [
    ('nbody', '20000000', '100000'),
    ('spectral-norm', '3000', '300'),
    ('fannkuch-redux', '11', '8'),
    ('mandelbrot', '4000', '400'),
    ('binary-trees', '19', '12'),
    ('sieve', '200000000', '1000000'),
    ('matmul', '1000', '200'),
    ('quicksort', '15000000', '200000'),
    ('hashmap', '8000000', '100000'),
    ('crc32', '40', '2'),
]

# The variants: how each language is built. `ref` is the one the others are compared with.
VARIANTS = ['c', 'zig-fast', 'fels-fast', 'zig-safe', 'fels-safe']
REF = 'c'
DESCRIBE = {
    'c': 'C, clang -O3 -march=native -ffp-contract=off',
    'zig-fast': 'Zig, -OReleaseFast',
    'fels-fast': 'Fels, -O3 --unchecked',
    'zig-safe': 'Zig, -OReleaseSafe (overflow, bounds and null checks)',
    'fels-safe': 'Fels, -O3 (overflow, bounds and null checks)',
}


def run(cmd, env=None, cwd=None, timeout=None):
    return subprocess.run(cmd, env=env, cwd=cwd, capture_output=True, text=True, timeout=timeout)


def first_line(text):
    return (text.strip().splitlines() or [''])[0].strip()


# Toolchains

def msvc_env():
    """On Windows, INCLUDE and LIB for clang's MSVC target from the newest Visual Studio and
    Windows SDK, unless they are set already. clang reads both, as cl does."""
    env = dict(os.environ)
    if not IS_WINDOWS or (env.get('INCLUDE') and env.get('LIB')):
        return env
    vswhere = os.path.join(os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)'),
                           'Microsoft Visual Studio', 'Installer', 'vswhere.exe')
    if not os.path.exists(vswhere):
        return env
    vs = first_line(run([vswhere, '-latest', '-products', '*', '-property', 'installationPath']).stdout)
    tools = sorted(glob.glob(os.path.join(vs, 'VC', 'Tools', 'MSVC', '*')))
    kits = os.path.join(os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)'), 'Windows Kits', '10')
    # (a version folder may hold only the Driver Kit's headers, without the C runtime's)
    include = os.path.join(kits, 'Include')
    versions = sorted(v for v in os.listdir(include) if v.startswith('10.') and os.path.exists(os.path.join(include, v, 'ucrt', 'stdio.h'))) if os.path.isdir(include) else []
    if not tools or not versions:
        return env
    vc, ver = tools[-1], versions[-1]
    env['INCLUDE'] = ';'.join([os.path.join(vc, 'include')] + [os.path.join(kits, 'Include', ver, d) for d in ('ucrt', 'um', 'shared')])
    env['LIB'] = ';'.join([os.path.join(vc, 'lib', 'x64')] + [os.path.join(kits, 'Lib', ver, d, 'x64') for d in ('ucrt', 'um')])
    return env


def find_tool(name, given):
    if given:
        return given
    found = shutil.which(name)
    if not found:
        sys.exit(f'error: `{name}` is not on PATH; pass --{name} <path>')
    return found


def tool_versions(args):
    fels_v = run([args.fels, 'version'])
    return {
        'clang': first_line(run([args.clang, '--version']).stdout),
        'zig': first_line(run([args.zig, 'version']).stdout),
        'fels': first_line(fels_v.stdout or fels_v.stderr),
    }


def build_cmd(variant, bench, src_dir, out, args):
    if variant == 'c':
        return [args.clang, '-O3', '-march=native', '-ffp-contract=off', '-std=c11',
                os.path.join(src_dir, 'main.c'), '-o', out]
    if variant in ('zig-fast', 'zig-safe'):
        mode = 'ReleaseFast' if variant == 'zig-fast' else 'ReleaseSafe'
        return [args.zig, 'build-exe', '-O' + mode, os.path.join(src_dir, 'main.zig'),
                '-femit-bin=' + out, '--cache-dir', os.path.join(HERE, 'out', 'zig-cache')]
    if variant in ('fels-fast', 'fels-safe'):
        flags = ['-O3', '--unchecked'] if variant == 'fels-fast' else ['-O3']
        if args.fels_std:
            flags += ['--std-path', args.fels_std]
        return [args.fels, 'build', os.path.join(src_dir, 'main.fels'), '-o', out, '-q'] + flags
    raise ValueError(variant)


# Machine

def machine():
    info = {'os': platform.platform(), 'python': platform.python_version(), 'cpu': platform.processor(),
            'cores': os.cpu_count()}
    try:
        if IS_WINDOWS:
            name = run(['powershell', '-NoProfile', '-Command',
                        '(Get-CimInstance Win32_Processor | Select-Object -First 1).Name']).stdout.strip()
            mem = run(['powershell', '-NoProfile', '-Command',
                       '[math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)']).stdout.strip()
            if name:
                info['cpu'] = name
            if mem:
                info['memory_gb'] = int(mem)
        elif os.path.exists('/proc/cpuinfo'):
            for line in open('/proc/cpuinfo'):
                if line.startswith('model name'):
                    info['cpu'] = line.split(':', 1)[1].strip()
                    break
            for line in open('/proc/meminfo'):
                if line.startswith('MemTotal'):
                    info['memory_gb'] = round(int(line.split()[1]) / 1048576)
                    break
    except OSError:
        pass
    commit = run(['git', '-C', REPO, 'rev-parse', '--short', 'HEAD'])
    info['fels_commit'] = commit.stdout.strip() if commit.returncode == 0 else '?'
    return info


# Timing

def time_run(exe, size):
    start = time.perf_counter_ns()
    p = subprocess.run([exe, size], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    elapsed = (time.perf_counter_ns() - start) / 1e9
    if p.returncode != 0:
        raise RuntimeError(f'{exe} {size} exited with {p.returncode}')
    return elapsed


def fmt_s(x):
    return f'{x:.3f}' if x < 10 else f'{x:.2f}'


def main():
    # The report has `×` and `–`; a Windows console's code page has neither.
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--runs', type=int, default=10, help='timed runs of each program (default 10)')
    ap.add_argument('--warmup', type=int, default=1, help='untimed runs before them (default 1)')
    ap.add_argument('--quick', action='store_true', help='small sizes and 3 runs, to check the setup')
    ap.add_argument('--only', help='comma-separated benchmarks')
    ap.add_argument('--variants', help='comma-separated variants: ' + ','.join(VARIANTS))
    ap.add_argument('--clang', help='the clang to build C with (default: clang on PATH)')
    ap.add_argument('--zig', help='the zig to build Zig with (default: zig on PATH)')
    ap.add_argument('--fels', help='the fels to build Fels with (default: fels on PATH)')
    ap.add_argument('--fels-std', help="the standard library Fels builds with (a folder holding std/; default: the compiler's own)")
    ap.add_argument('--seed', type=int, default=1, help='the seed of the run order (default 1)')
    ap.add_argument('--out', help='the report file (default bench/results/<date>-<host>.md)')
    args = ap.parse_args()
    args.clang = find_tool('clang', args.clang)
    args.zig = find_tool('zig', args.zig)
    args.fels = find_tool('fels', args.fels)
    if args.quick:
        args.runs = min(args.runs, 3)

    variants = args.variants.split(',') if args.variants else VARIANTS
    for v in variants:
        if v not in VARIANTS:
            sys.exit(f'error: unknown variant `{v}`; the variants are {", ".join(VARIANTS)}')
    benches = [b for b in BENCHMARKS if not args.only or b[0] in args.only.split(',')]
    if not benches:
        sys.exit('error: no benchmark matches --only')
    env = msvc_env()
    versions = tool_versions(args)
    info = machine()
    print(f'machine: {info["cpu"]}, {info["cores"]} threads, {info.get("memory_gb", "?")} GB, {info["os"]}')
    for k, v in versions.items():
        print(f'{k}: {v}')

    out_dir = os.path.join(HERE, 'out')
    os.makedirs(out_dir, exist_ok=True)
    results = {}

    # 1. Build.
    print('\nbuilding')
    for name, size, quick_size in benches:
        src_dir = os.path.join(HERE, name)
        results[name] = {'size': quick_size if args.quick else size, 'variants': {}}
        for v in variants:
            exe = os.path.join(out_dir, f'{name}-{v}{EXE}')
            if os.path.exists(exe):
                os.remove(exe)
            source = os.path.join(src_dir, 'main.' + {'c': 'c', 'zig-fast': 'zig', 'zig-safe': 'zig'}.get(v, 'fels'))
            if not os.path.exists(source):
                results[name]['variants'][v] = {'error': f'no {os.path.relpath(source, HERE)}'}
                print(f'  {name:15} {v:10} missing {os.path.relpath(source, HERE)}')
                continue
            cmd = build_cmd(v, name, src_dir, exe, args)
            start = time.perf_counter()
            p = run(cmd, env=env, cwd=src_dir)
            build_s = time.perf_counter() - start
            entry = {'exe': exe, 'build_s': build_s, 'command': ' '.join(cmd)}
            if p.returncode != 0 or not os.path.exists(exe):
                entry['error'] = 'build failed: ' + (p.stderr or p.stdout).strip()[:2000]
                print(f'  {name:15} {v:10} BUILD FAILED')
            else:
                entry['bytes'] = os.path.getsize(exe)
                print(f'  {name:15} {v:10} {build_s:6.2f} s  {entry["bytes"] / 1024:7.0f} KiB')
            results[name]['variants'][v] = entry

    # 2. The same output from every variant.
    print('\nchecking outputs')
    for name, r in results.items():
        outputs = {}
        for v, e in r['variants'].items():
            if 'error' in e:
                continue
            p = run([e['exe'], r['size']], timeout=600)
            if p.returncode != 0:
                e['error'] = f'exited with {p.returncode}: {p.stderr.strip()[:500]}'
                continue
            outputs[v] = p.stdout.replace('\r\n', '\n')
            e['output'] = outputs[v]
        distinct = set(outputs.values())
        r['outputs_agree'] = len(distinct) == 1
        if len(distinct) > 1:
            print(f'  {name}: OUTPUTS DIFFER, left out of the timings')
            for v, o in outputs.items():
                print(f'    {v}: {o.strip()[:200]!r}')
        elif distinct:
            print(f'  {name}: {len(outputs)} variants agree: {next(iter(distinct)).strip().splitlines()[-1][:60]}')

    # 3. Time, the variants interleaved and shuffled every round.
    rng = random.Random(args.seed)
    print(f'\ntiming: {args.warmup} warm-up and {args.runs} timed runs of each')
    for name, r in results.items():
        timed = [v for v, e in r['variants'].items() if 'error' not in e and r['outputs_agree']]
        for v in timed:
            r['variants'][v]['times'] = []
        for _ in range(args.warmup):
            for v in timed:
                time_run(r['variants'][v]['exe'], r['size'])
        for _ in range(args.runs):
            order = list(timed)
            rng.shuffle(order)
            for v in order:
                r['variants'][v]['times'].append(time_run(r['variants'][v]['exe'], r['size']))
        cells = []
        for v in timed:
            t = r['variants'][v]['times']
            r['variants'][v]['median_s'] = statistics.median(t)
            r['variants'][v]['min_s'] = min(t)
            r['variants'][v]['max_s'] = max(t)
            r['variants'][v]['stdev_s'] = statistics.stdev(t) if len(t) > 1 else 0.0
            cells.append(f'{v} {fmt_s(r["variants"][v]["median_s"])}')
        print(f'  {name:15} ' + '  '.join(cells))

    report = render(results, variants, versions, info, args)
    stamp = datetime.datetime.now().strftime('%Y-%m-%d')
    host = platform.node().lower() or 'machine'
    res_dir = os.path.join(HERE, 'results')
    os.makedirs(res_dir, exist_ok=True)
    md_path = args.out or os.path.join(res_dir, f'{stamp}-{host}{"-quick" if args.quick else ""}.md')
    with open(md_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(report)
    raw = {'date': stamp, 'machine': info, 'versions': versions, 'runs': args.runs, 'warmup': args.warmup,
           'seed': args.seed, 'variants': {v: DESCRIBE[v] for v in variants}, 'benchmarks': results}
    with open(os.path.splitext(md_path)[0] + '.json', 'w', encoding='utf-8', newline='\n') as f:
        json.dump(raw, f, indent=1)
    print('\n' + report)
    print(f'written: {os.path.relpath(md_path, REPO)} (+ .json)')


def render(results, variants, versions, info, args):
    lines = []
    lines.append(f'# Benchmark results, {datetime.datetime.now().strftime("%Y-%m-%d")}')
    lines.append('')
    lines.append(f'- Machine: {info["cpu"]}, {info["cores"]} threads, {info.get("memory_gb", "?")} GB RAM')
    lines.append(f'- OS: {info["os"]}')
    std_note = f', std from {args.fels_std}' if args.fels_std else ''
    lines.append(f'- Compilers: {versions["clang"]}; Zig {versions["zig"]}; {versions["fels"]}{std_note} (repository at commit {info["fels_commit"]})')
    lines.append(f'- Runs: {args.warmup} warm-up, then {args.runs} timed runs of each program, the variants '
                 f'interleaved in a shuffled order every round (seed {args.seed}). Times are wall-clock '
                 'seconds of the whole process.')
    lines.append('- Variants: ' + '; '.join(f'`{v}` = {DESCRIBE[v]}' for v in variants))
    lines.append('')
    lines.append('## Run time (median seconds, and relative to C; lower is better)')
    lines.append('')
    lines.append('| benchmark | size | ' + ' | '.join(variants) + ' |')
    lines.append('|---|---:|' + '---:|' * len(variants))
    ratios = {v: [] for v in variants}
    for name, r in results.items():
        cells = []
        ref = r['variants'].get(REF, {}).get('median_s')
        for v in variants:
            e = r['variants'].get(v, {})
            if 'median_s' not in e:
                cells.append('fails' if 'error' in e or not r.get('outputs_agree') else '–')
                continue
            if ref:
                ratio = e['median_s'] / ref
                ratios[v].append(ratio)
                cells.append(f'{fmt_s(e["median_s"])} ({ratio:.2f}×)')
            else:
                cells.append(fmt_s(e['median_s']))
        lines.append(f'| {name} | {r["size"]} | ' + ' | '.join(cells) + ' |')
    geo = []
    for v in variants:
        rs = ratios[v]
        geo.append(f'{statistics.geometric_mean(rs):.2f}×' if rs else '–')
    lines.append('| **geometric mean** | | ' + ' | '.join(f'**{g}**' for g in geo) + ' |')
    lines.append('')
    lines.append('## Spread (fastest run – slowest run, seconds)')
    lines.append('')
    lines.append('| benchmark | ' + ' | '.join(variants) + ' |')
    lines.append('|---|' + '---:|' * len(variants))
    for name, r in results.items():
        cells = []
        for v in variants:
            e = r['variants'].get(v, {})
            cells.append(f'{fmt_s(e["min_s"])}–{fmt_s(e["max_s"])}' if 'min_s' in e else '–')
        lines.append(f'| {name} | ' + ' | '.join(cells) + ' |')
    lines.append('')
    lines.append('## Build time (seconds) and binary size (KiB)')
    lines.append('')
    lines.append('| benchmark | ' + ' | '.join(variants) + ' |')
    lines.append('|---|' + '---:|' * len(variants))
    for name, r in results.items():
        cells = []
        for v in variants:
            e = r['variants'].get(v, {})
            cells.append(f'{e["build_s"]:.2f} s, {e["bytes"] / 1024:.0f} KiB' if 'bytes' in e else 'fails')
        lines.append(f'| {name} | ' + ' | '.join(cells) + ' |')
    failed = [(n, v, e['error']) for n, r in results.items() for v, e in r['variants'].items() if 'error' in e]
    if failed or any(not r.get('outputs_agree') for r in results.values()):
        lines.append('')
        lines.append('## Problems')
        lines.append('')
        for n, v, err in failed:
            lines.append(f'- {n} / {v}: {err.splitlines()[0][:300]}')
        for n, r in results.items():
            if not r.get('outputs_agree'):
                lines.append(f'- {n}: the variants printed different outputs, so it is not timed')
    lines.append('')
    return '\n'.join(lines)


if __name__ == '__main__':
    main()
