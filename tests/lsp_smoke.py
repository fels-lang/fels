#!/usr/bin/env python3
"""Smoke-test the `gabbro lsp` language server over stdio (no editor needed).

Drives a full initialize -> didOpen -> completion / hover / definition /
documentSymbol exchange against the built binary and prints the results.

    python tests/lsp_smoke.py [path-to-gabbro.exe]
"""
import subprocess, json, sys, os

EXE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(__file__), "..", "zig-out", "bin", "gabbro.exe")


def frame(msg):
    body = json.dumps(msg).encode("utf-8")
    return b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body


SRC = (
    "Point :: struct { x: i32, y: i32 }\n"
    "\n"
    "add :: fn(a: i32, b: i32) -> i32 { return a + b; }\n"
    "\n"
    "main :: fn() -> i32 { v: u128 = 0u64; return add(1, 2); }\n"
)
URI = "file:///smoke.fels"
add_call_col = SRC.splitlines()[4].index("add(") + 1  # cursor on the `add` call

MSGS = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"capabilities": {}}},
    {"jsonrpc": "2.0", "method": "initialized", "params": {}},
    {"jsonrpc": "2.0", "method": "textDocument/didOpen",
     "params": {"textDocument": {"uri": URI, "languageId": "gabbro", "version": 1, "text": SRC}}},
    {"jsonrpc": "2.0", "id": 2, "method": "textDocument/completion",
     "params": {"textDocument": {"uri": URI}, "position": {"line": 4, "character": 0}}},
    {"jsonrpc": "2.0", "id": 3, "method": "textDocument/hover",
     "params": {"textDocument": {"uri": URI}, "position": {"line": 2, "character": 1}}},
    {"jsonrpc": "2.0", "id": 4, "method": "textDocument/definition",
     "params": {"textDocument": {"uri": URI}, "position": {"line": 4, "character": add_call_col}}},
    {"jsonrpc": "2.0", "id": 5, "method": "textDocument/documentSymbol",
     "params": {"textDocument": {"uri": URI}}},
    {"jsonrpc": "2.0", "id": 6, "method": "shutdown", "params": None},
    {"jsonrpc": "2.0", "method": "exit", "params": None},
]


def read_messages(out: bytes):
    i = 0
    while i < len(out):
        j = out.find(b"\r\n\r\n", i)
        if j < 0:
            break
        header = out[i:j].decode()
        clen = int(next(h for h in header.split("\r\n")
                        if h.lower().startswith("content-length")).split(":")[1])
        yield json.loads(out[j + 4:j + 4 + clen])
        i = j + 4 + clen


def single_file():
    p = subprocess.run([EXE, "lsp"], input=b"".join(frame(m) for m in MSGS),
                       capture_output=True, timeout=30)
    ok = True
    for r in read_messages(p.stdout):
        if r.get("method") == "textDocument/publishDiagnostics":
            ds = r["params"]["diagnostics"]
            print(f"diagnostics: {len(ds)} -> " + "; ".join(d["message"][:60] for d in ds))
            ok &= len(ds) >= 1  # the u128 line is an error
        elif "id" in r:
            rid, res = r["id"], r.get("result")
            if rid == 1:
                print("initialize caps:", list(res["capabilities"].keys()))
                ok &= "completionProvider" in res["capabilities"]
            elif rid == 2:
                labels = [x["label"] for x in res]
                print(f"completion: {len(res)} items, e.g.", labels[:6])
                ok &= all(n in labels for n in ("Point", "add", "main"))
            elif rid == 3:
                print("hover:", res["contents"]["value"].replace("\n", " ") if res else None)
                ok &= res is not None
            elif rid == 4:
                print("definition:", res["range"]["start"] if res else None)
                ok &= res is not None and res["range"]["start"]["line"] == 2
            elif rid == 5:
                print("symbols:", [x["name"] for x in res])
                ok &= [x["name"] for x in res] == ["Point", "add", "main"]
    if "leaked" in p.stderr.decode(errors="replace").lower():
        print("FAIL: memory leak reported"); ok = False
    return ok


def two_files():
    """A project of two files: imports, cross-file hover/definition/completion, live edit."""
    import tempfile
    ok = True
    with tempfile.TemporaryDirectory() as tmp:
        util_src = "pub add :: fn(a: i32, b: i32) -> i32 { return a + b; }\n"
        main_src = "#import util.{ add };\n\nmain :: fn() -> i32 {\n    return add(1, 2);\n}\n"
        util_path = os.path.join(tmp, "util.fels")
        main_path = os.path.join(tmp, "main.fels")
        with open(util_path, "w", newline="\n") as f:
            f.write(util_src)
        with open(main_path, "w", newline="\n") as f:
            f.write(main_src)
        uri = lambda p: "file:///" + p.replace("\\", "/")
        main_uri, util_uri = uri(main_path), uri(util_path)
        call = {"line": 3, "character": main_src.splitlines()[3].index("add(") + 1}
        renamed = util_src.replace("add", "plus")
        msgs = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"capabilities": {}}},
            {"jsonrpc": "2.0", "method": "textDocument/didOpen",
             "params": {"textDocument": {"uri": main_uri, "languageId": "gabbro", "version": 1, "text": main_src}}},
            {"jsonrpc": "2.0", "id": 2, "method": "textDocument/hover",
             "params": {"textDocument": {"uri": main_uri}, "position": call}},
            {"jsonrpc": "2.0", "id": 3, "method": "textDocument/definition",
             "params": {"textDocument": {"uri": main_uri}, "position": call}},
            {"jsonrpc": "2.0", "id": 4, "method": "textDocument/completion",
             "params": {"textDocument": {"uri": main_uri}, "position": {"line": 3, "character": 4}}},
            {"jsonrpc": "2.0", "method": "textDocument/didOpen",
             "params": {"textDocument": {"uri": util_uri, "languageId": "gabbro", "version": 1, "text": util_src}}},
            {"jsonrpc": "2.0", "id": 5, "method": "textDocument/documentSymbol",
             "params": {"textDocument": {"uri": main_uri}}},
            {"jsonrpc": "2.0", "method": "textDocument/didChange",
             "params": {"textDocument": {"uri": util_uri, "version": 2}, "contentChanges": [{"text": renamed}]}},
            {"jsonrpc": "2.0", "id": 6, "method": "shutdown", "params": None},
            {"jsonrpc": "2.0", "method": "exit", "params": None},
        ]
        p = subprocess.run([EXE, "lsp"], input=b"".join(frame(m) for m in msgs), capture_output=True, timeout=30)
        last = {}
        first_main = None
        for r in read_messages(p.stdout):
            if r.get("method") == "textDocument/publishDiagnostics":
                u = r["params"]["uri"]
                if u == main_uri and first_main is None:
                    first_main = r["params"]["diagnostics"]
                last[u] = r["params"]["diagnostics"]
            elif r.get("id") == 2:
                v = r["result"]["contents"]["value"]
                print("cross-file hover:", v.replace("\n", " "))
                ok &= "add :: fn(a: i32, b: i32) -> i32" in v
            elif r.get("id") == 3:
                res = r["result"]
                print("cross-file definition:", res)
                ok &= bool(res) and res["uri"].lower().endswith("util.fels") and res["range"]["start"]["line"] == 0
            elif r.get("id") == 4:
                labels = [x["label"] for x in r["result"]]
                print("cross-file completion has add:", "add" in labels)
                ok &= "add" in labels
            elif r.get("id") == 5:
                names = [x["name"] for x in r["result"]]
                print("outline:", names)
                ok &= "add" in names and "main" in names
        print("main diagnostics before the edit:", first_main)
        ok &= first_main == []
        after = last.get(main_uri, [])
        print("main diagnostics after renaming add to plus in util:", [d["message"] for d in after])
        ok &= any("add" in d["message"] for d in after)
        ok &= last.get(util_uri, []) == []
    return ok


def main():
    ok = single_file()
    ok &= two_files()
    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
