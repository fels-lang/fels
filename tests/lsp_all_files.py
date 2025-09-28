#!/usr/bin/env python3
"""Check that `gabbro lsp` agrees with `gabbro check` on every .fels file.

A: each file that `gabbro check` accepts must give zero diagnostics through the server.
B: a few programs the compiler rejects must still give an error at the right line.

    python tests/lsp_all_files.py [path-to-gabbro.exe] [extra dir or file ...]

Prints the files that differ and an X/Y total. Exit code 0 if all agree.
"""
import glob
import json
import os
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
args = [a for a in sys.argv[1:]]
EXE = args.pop(0) if args and args[0].endswith(".exe") else os.path.join(REPO, "zig-out", "bin", "gabbro.exe")
EXTRA = args


def frame(msg):
    body = json.dumps(msg).encode("utf-8")
    return b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body


def messages(raw):
    i = 0
    while True:
        j = raw.find(b"Content-Length:", i)
        if j < 0:
            return
        k = raw.find(b"\r\n\r\n", j)
        n = int(raw[j + 15:k].strip())
        try:
            yield json.loads(raw[k + 4:k + 4 + n])
        except Exception:
            pass
        i = k + 4 + n


def uri_of(path):
    return "file:///" + os.path.abspath(path).replace("\\", "/")


def lsp_diagnostics(path, text=None):
    """Open `path` in a fresh server; return {uri: [diagnostic, ...]} (last publish per uri)."""
    if text is None:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    seq = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"capabilities": {}}},
        {"jsonrpc": "2.0", "method": "initialized", "params": {}},
        {"jsonrpc": "2.0", "method": "textDocument/didOpen",
         "params": {"textDocument": {"uri": uri_of(path), "languageId": "gabbro", "version": 1, "text": text}}},
        {"jsonrpc": "2.0", "id": 2, "method": "shutdown"},
        {"jsonrpc": "2.0", "method": "exit"},
    ]
    p = subprocess.run([EXE, "lsp"], input=b"".join(frame(m) for m in seq), capture_output=True, timeout=120)
    out = {}
    for m in messages(p.stdout):
        if m.get("method") == "textDocument/publishDiagnostics":
            out[m["params"]["uri"]] = m["params"]["diagnostics"]
    return out, p.returncode


def check_accepts(path):
    r = subprocess.run([EXE, "check", os.path.basename(path)], cwd=os.path.dirname(os.path.abspath(path)),
                       capture_output=True, timeout=120)
    return r.returncode == 0


def collect():
    files = []
    for sub in ("examples", "lib", os.path.join("tests", "fixtures"), "tests"):
        pat = os.path.join(REPO, sub, "**", "*.fels") if sub != "tests" else os.path.join(REPO, sub, "*.fels")
        files += glob.glob(pat, recursive=True)
    files += glob.glob(r"C:\dev\codebridge\src\*.fels")
    for e in EXTRA:
        if os.path.isdir(e):
            files += glob.glob(os.path.join(e, "**", "*.fels"), recursive=True)
        else:
            files.append(e)
    return sorted(set(os.path.normpath(f) for f in files))


def run_one(path):
    if not check_accepts(path):
        return path, "skipped", []
    diags, _ = lsp_diagnostics(path)
    flat = [(u, d) for u, ds in diags.items() for d in ds]
    return path, ("ok" if not flat else "differs"), flat


# B: programs the compiler rejects. (source, 1-based line of the error)
ERROR_CASES = {
    "return_type.fels": ("f :: fn() -> i32 {\n    return true;\n}\n", 2),
    "unknown_name.fels": ("main :: fn() -> i32 {\n    return missing_name;\n}\n", 2),
    "arg_count.fels": ("add :: fn(a: i32, b: i32) -> i32 { return a + b; }\nmain :: fn() -> i32 {\n    return add(1);\n}\n", 3),
    "unknown_type.fels": ("main :: fn() -> i32 {\n    p: Poin = 0;\n    return 0;\n}\n", 2),
    "arg_type.fels": ("take :: fn(a: i32) {}\nmain :: fn() {\n    take(true);\n}\n", 3),
    "bad_fail.fels": ("NetError :: errors { http: u16, }\nbad :: fn() -> u32 ! NetError {\n    fail .http { \"nope\" };\n}\n", 3),
    "syntax.fels": ("main :: fn() -> i32 {\n    return 1\n}\n", 3),
    "bad_import.fels": ("#import nothing_here.{ x };\nmain :: fn() {}\n", 1),
    "u128.fels": ("main :: fn() -> i32 {\n    v: u128 = 0u64;\n    return 0;\n}\n", 2),
}


def run_errors():
    ok = 0
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        for name, (src, line) in ERROR_CASES.items():
            path = os.path.join(tmp, name)
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(src)
            if check_accepts(path):
                bad.append((name, "compiler accepts it (bad test case)"))
                continue
            diags, _ = lsp_diagnostics(path)
            errs = [d for d in diags.get(uri_of(path), []) if d.get("severity") == 1]
            lines = sorted({d["range"]["start"]["line"] + 1 for d in errs})
            # The error may be reported on the line or the one after it (e.g. a missing `;`).
            if any(abs(l - line) <= 1 for l in lines):
                ok += 1
            else:
                bad.append((name, "expected an error at line %d, got lines %s" % (line, lines)))
    return ok, bad


def main():
    files = collect()
    with ThreadPoolExecutor(max_workers=8) as ex:
        results = list(ex.map(run_one, files))
    accepted = [r for r in results if r[1] != "skipped"]
    differ = [r for r in accepted if r[1] == "differs"]
    for path, _, flat in differ:
        print("DIFFERS", path)
        for u, d in flat[:5]:
            print("    %s line %d: %s" % (os.path.basename(u), d["range"]["start"]["line"] + 1, d["message"][:100]))
    print("A: %d/%d accepted files have no diagnostics (%d files rejected by check, skipped)" % (
        len(accepted) - len(differ), len(accepted), len(results) - len(accepted)))
    ok, bad = run_errors()
    for name, why in bad:
        print("B FAIL", name, why)
    print("B: %d/%d rejected programs report an error at the right line" % (ok, len(ERROR_CASES)))
    return 0 if not differ and not bad else 1


if __name__ == "__main__":
    sys.exit(main())
