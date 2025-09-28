#!/usr/bin/env python3
"""Test the navigation requests of `fels lsp` on a small project of several files:
textDocument/references, prepareRename, rename, documentHighlight and workspace/symbol.

    python tests/lsp_nav_test.py [path-to-fels.exe]

Builds the project in a temporary folder, drives the server over stdio and prints PASS
or the failed checks.
"""
import json
import os
import subprocess
import sys
import tempfile

EXE = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(__file__), "..", "zig-out", "bin", "fels.exe"))

UTIL = """\
pub Point :: struct {
    x: i32,
    y: i32,
    pub sum :: fn(self: *Point) -> i32 { return self.x + self.y; }
}

pub Color :: enum { red, green, blue }

pub add :: fn(a: i32, b: i32) -> i32 { return a + b; }

pub origin :: fn() -> Point { return .{ .x = 0, .y = 0 }; }
"""

MAIN = """\
#import std.io.{ println };
#import util.{ Point, Color, add, origin };

shade :: fn(c: Color) -> i32 {
    match c {
        .red => { return 1; }
        .green => { return 2; }
        .blue => { return 3; }
    }
}

main :: fn() -> i32 {
    p: Point = .{ .x = 1, .y = 2 };
    q := origin();
    total := add(p.x, q.y);
    count := 0;
    if total > 2 {
        count := 10;
        total = total + count;
    }
    total = total + count + p.sum();
    c: Color = .red;
    if c == .red { println("red"); }
    return total + shade(.green);
}

#extern("kernel32", "GetTickCount")
tick :: fn() -> u32;

uptime :: fn() -> u32 { return tick(); }
"""

OTHER = """\
#import util.{ add, Point };

twice :: fn(n: i32) -> i32 { return add(n, n); }

corner :: fn() -> Point { return .{ .x = add(1, 2), .y = 0 }; }
"""

BUILD = "build :: fn() {}\n"


def frame(msg):
    body = json.dumps(msg).encode("utf-8")
    return b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body


def read_messages(out):
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


def pos_of(text, needle, nth=0, delta=0):
    """LSP position of the nth occurrence of `needle` in `text`, moved by `delta` bytes."""
    at = -1
    for _ in range(nth + 1):
        at = text.index(needle, at + 1)
    at += delta
    line = text.count("\n", 0, at)
    col = at - (text.rfind("\n", 0, at) + 1)
    return {"line": line, "character": col}


def uri_of(path):
    return "file:///" + path.replace("\\", "/")


def name_of(uri):
    return uri.rsplit("/", 1)[-1].lower()


failures = []


def check(cond, what):
    print(("ok    " if cond else "FAIL  ") + what)
    if not cond:
        failures.append(what)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        paths = {}
        for name, text in (("util.fels", UTIL), ("main.fels", MAIN), ("other.fels", OTHER), ("build.fels", BUILD)):
            paths[name] = os.path.join(tmp, name)
            with open(paths[name], "w", newline="\n") as f:
                f.write(text)
        main_uri = uri_of(paths["main.fels"])
        other_uri = uri_of(paths["other.fels"])
        root_uri = uri_of(tmp)

        rid = [100]
        msgs = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"rootUri": root_uri, "capabilities": {}}},
            {"jsonrpc": "2.0", "method": "initialized", "params": {}},
            # Only main.fels is open: util.fels and other.fels are read from disk.
            {"jsonrpc": "2.0", "method": "textDocument/didOpen",
             "params": {"textDocument": {"uri": main_uri, "languageId": "fels", "version": 1, "text": MAIN}}},
        ]
        names = {}

        def req(label, method, params):
            rid[0] += 1
            names[rid[0]] = label
            msgs.append({"jsonrpc": "2.0", "id": rid[0], "method": method, "params": params})

        def at(needle, nth=0, delta=0, text=MAIN, uri=main_uri):
            return {"textDocument": {"uri": uri}, "position": pos_of(text, needle, nth, delta)}

        def refs(label, needle, nth=0, delta=0, decl=True, text=MAIN, uri=main_uri):
            p = at(needle, nth, delta, text, uri)
            p["context"] = {"includeDeclaration": decl}
            req(label, "textDocument/references", p)

        refs("refs add", "add(p.x", delta=1)
        refs("refs add no decl", "add(p.x", delta=1, decl=False)
        refs("refs field x", "p.x,", delta=2)
        refs("refs sum", "p.sum", delta=3)
        refs("refs outer count", "count := 0", delta=1)
        refs("refs inner count", "count := 10", delta=1)
        refs("refs red", "= .red", delta=3)
        refs("refs Point", "p: Point", delta=4)
        refs("refs println", "println(", delta=2)
        req("prepare add", "textDocument/prepareRename", at("add(p.x", delta=1))
        req("prepare println", "textDocument/prepareRename", at("println(", delta=2))
        req("prepare keyword", "textDocument/prepareRename", at("return total", delta=2))
        req("prepare extern", "textDocument/prepareRename", at("return tick", delta=8))
        req("prepare main", "textDocument/prepareRename", at("main ::", delta=1))
        rename = at("add(p.x", delta=1)
        rename["newName"] = "plus"
        req("rename add", "textDocument/rename", rename)
        bad = at("println(", delta=2)
        bad["newName"] = "say"
        req("rename println", "textDocument/rename", bad)
        kw = at("total :=", delta=1)
        kw["newName"] = "while"
        req("rename to keyword", "textDocument/rename", kw)
        clash = at("add(p.x", delta=1)
        clash["newName"] = "origin"
        req("rename add to origin", "textDocument/rename", clash)
        local_clash = at("count := 10", delta=1)
        local_clash["newName"] = "total"
        req("rename inner count to total", "textDocument/rename", local_clash)
        field_clash = at("p.x,", delta=2)
        field_clash["newName"] = "y"
        req("rename x to y", "textDocument/rename", field_clash)
        field_ok = at("p.x,", delta=2)
        field_ok["newName"] = "px"
        req("rename x to px", "textDocument/rename", field_ok)
        method_clash = at("p.sum", delta=3)
        method_clash["newName"] = "add"
        req("rename sum to add", "textDocument/rename", method_clash)
        method_ok = at("p.sum", delta=3)
        method_ok["newName"] = "length"
        req("rename sum to length", "textDocument/rename", method_ok)
        local_ok = at("count := 10", delta=1)
        local_ok["newName"] = "extra"
        req("rename inner count to extra", "textDocument/rename", local_ok)
        req("highlight total", "textDocument/documentHighlight", at("total :=", delta=1))
        req("symbols ori", "workspace/symbol", {"query": "ori"})
        req("symbols point", "workspace/symbol", {"query": "point"})
        req("symbols all", "workspace/symbol", {"query": ""})
        # Open other.fels with one more call of `add`: the open text wins over the disk.
        other2 = OTHER + "thrice :: fn(n: i32) -> i32 { return add(add(n, n), n); }\n"
        msgs.append({"jsonrpc": "2.0", "method": "textDocument/didOpen",
                     "params": {"textDocument": {"uri": other_uri, "languageId": "fels", "version": 1, "text": other2}}})
        refs("refs add after edit", "add(p.x", delta=1)
        msgs.append({"jsonrpc": "2.0", "id": 99, "method": "shutdown", "params": None})
        msgs.append({"jsonrpc": "2.0", "method": "exit", "params": None})

        env = dict(os.environ, FELS_LSP_TIMING="1")
        p = subprocess.run([EXE, "lsp"], input=b"".join(frame(m) for m in msgs),
                           capture_output=True, timeout=300, env=env)
        out = {}
        diags = {}
        for r in read_messages(p.stdout):
            if r.get("method") == "textDocument/publishDiagnostics":
                diags[name_of(r["params"]["uri"])] = r["params"]["diagnostics"]
            elif "id" in r and r["id"] in names:
                out[names[r["id"]]] = r
        stderr = p.stderr.decode(errors="replace")
        for line in stderr.splitlines():
            if "fels-lsp:" in line and ("references" in line or "rename" in line or "symbol" in line or "Highlight" in line):
                print("  " + line.strip())

        check(diags.get("main.fels") == [], "main.fels has no diagnostics: %s" % diags.get("main.fels"))

        def locs(label):
            r = out.get(label, {})
            return sorted((name_of(x["uri"]), x["range"]["start"]["line"], x["range"]["start"]["character"])
                          for x in (r.get("result") or []))

        def files_of(label):
            return sorted(set(f for f, _, _ in locs(label)))

        add = locs("refs add")
        print("  refs add:", add)
        check(len(add) == 6 and files_of("refs add") == ["main.fels", "other.fels", "util.fels"],
              "references of add: declaration, two imports, three calls in three files")
        check(len(locs("refs add no decl")) == 5 and ("util.fels", 8, 4) not in locs("refs add no decl"),
              "includeDeclaration false leaves out the declaration")

        x = locs("refs field x")
        print("  refs field x:", x)
        check(len(x) == 6 and files_of("refs field x") == ["main.fels", "other.fels", "util.fels"],
              "references of field x: declaration, self.x, three literals, p.x")
        check(len(locs("refs sum")) == 2, "references of method sum: declaration and p.sum()")

        outer = locs("refs outer count")
        inner = locs("refs inner count")
        print("  outer count:", outer, " inner count:", inner)
        lines_inner_block = (17, 18, 19)
        check(len(outer) == 2 and all(l not in lines_inner_block for _, l, _ in outer),
              "outer count: its declaration and the use after the block")
        check(len(inner) == 2 and all(l in lines_inner_block for _, l, _ in inner),
              "inner count: its declaration and the use inside the block")

        red = locs("refs red")
        print("  refs red:", red)
        check(len(red) == 4 and files_of("refs red") == ["main.fels", "util.fels"],
              "references of variant red: declaration, match arm, typed local, comparison")
        point = locs("refs Point")
        print("  refs Point:", point)
        check(len(point) >= 7, "references of type Point in fields, parameters, returns, imports")
        pl = locs("refs println")
        print("  refs println:", pl)
        check(len(pl) == 3 and files_of("refs println") == ["io.fels", "main.fels"],
              "references of std println: the import, the call, and its declaration in std")

        pr = out.get("prepare add", {}).get("result")
        exp = pos_of(MAIN, "add(p.x")
        check(pr is not None and pr["range"]["start"] == exp and pr["range"]["end"]["character"] == exp["character"] + 3
              and pr.get("placeholder") == "add", "prepareRename gives the range of add: %s" % pr)
        check("error" in out.get("prepare println", {}), "prepareRename refuses a std function: %s"
              % out.get("prepare println", {}).get("error"))
        check("error" in out.get("prepare keyword", {}), "prepareRename refuses a keyword position")
        print("  prepare extern:", (out.get("prepare extern", {}).get("error") or {}).get("message"))
        check("error" in out.get("prepare extern", {}), "prepareRename refuses an #extern function")
        print("  prepare main:", (out.get("prepare main", {}).get("error") or {}).get("message"))
        check("error" in out.get("prepare main", {}), "prepareRename refuses main")

        rn = out.get("rename add", {}).get("result") or {}
        changes = rn.get("changes", {})
        edits = {name_of(u): e for u, e in changes.items()}
        print("  rename add:", {k: len(v) for k, v in edits.items()})
        check(sorted(edits) == ["main.fels", "other.fels", "util.fels"] and len(edits.get("other.fels", [])) == 3
              and len(edits.get("util.fels", [])) == 1 and len(edits.get("main.fels", [])) == 2
              and all(e["newText"] == "plus" for v in edits.values() for e in v),
              "rename add to plus edits util.fels and other.fels, which are not open, and main.fels")
        # Apply the edits to the texts and check the result reads right.
        texts = {"main.fels": MAIN, "other.fels": OTHER, "util.fels": UTIL}
        for name, es in edits.items():
            lines = texts[name].split("\n")
            for e in sorted(es, key=lambda e: (e["range"]["start"]["line"], e["range"]["start"]["character"]), reverse=True):
                s, t = e["range"]["start"], e["range"]["end"]
                ln = lines[s["line"]]
                lines[s["line"]] = ln[:s["character"]] + e["newText"] + ln[t["character"]:]
            texts[name] = "\n".join(lines)
        check("pub plus :: fn" in texts["util.fels"] and "#import util.{ plus, Point }" in texts["other.fels"]
              and "return plus(n, n)" in texts["other.fels"] and "total := plus(p.x" in texts["main.fels"]
              and " add" not in texts["other.fels"], "the renamed texts read right")

        def err(label):
            return (out.get(label, {}).get("error") or {}).get("message", "")

        print("  rename println:", err("rename println"))
        check("error" in out.get("rename println", {}), "rename refused for a std function")
        print("  rename to keyword:", err("rename to keyword"))
        check(out.get("rename to keyword", {}).get("error", {}).get("code") == -32602, "rename refused for a keyword as new name")
        print("  rename add to origin:", err("rename add to origin"))
        check("error" in out.get("rename add to origin", {}), "rename refused when the new name collides with an import")
        print("  rename inner count to total:", err("rename inner count to total"))
        check("error" in out.get("rename inner count to total", {}), "rename refused when a local would capture another name")
        print("  rename x to y:", err("rename x to y"))
        check("error" in out.get("rename x to y", {}), "rename refused when the struct has a field of the new name")
        fx = out.get("rename x to px", {}).get("result") or {}
        check(sum(len(v) for v in fx.get("changes", {}).values()) == 6, "rename of field x edits its six places")
        print("  rename sum to add:", err("rename sum to add"))
        check("error" in out.get("rename sum to add", {}), "rename refused when a function of the new name could be called as a method")
        ms = out.get("rename sum to length", {}).get("result") or {}
        check(sorted((name_of(u), len(v)) for u, v in ms.get("changes", {}).items()) == [("main.fels", 1), ("util.fels", 1)],
              "rename of method sum edits its declaration in util.fels and the call in main.fels")
        lc = out.get("rename inner count to extra", {}).get("result") or {}
        check(sum(len(v) for v in lc.get("changes", {}).values()) == 2, "rename of the inner count edits only its two places")

        hl = out.get("highlight total", {}).get("result") or []
        kinds = sorted(h["kind"] for h in hl)
        print("  highlight total:", [(h["range"]["start"]["line"], h["kind"]) for h in hl])
        check(len(hl) == 7 and kinds.count(3) == 3, "documentHighlight of total: 7 places, 3 written")

        def syms(label):
            return [(s["name"], name_of(s["location"]["uri"]), s["kind"]) for s in (out.get(label, {}).get("result") or [])]

        print("  symbols ori:", syms("symbols ori"))
        check(("origin", "util.fels", 12) in syms("symbols ori"), "workspace/symbol finds origin")
        check(("Point", "util.fels", 23) in syms("symbols point"), "workspace/symbol is case-insensitive")
        allnames = set(n for n, _, _ in syms("symbols all"))
        check({"main", "shade", "twice", "corner", "add", "Color", "sum", "build"} <= allnames,
              "workspace/symbol with an empty query lists the project: %s" % sorted(allnames))

        after = locs("refs add after edit")
        check(len(after) == 8, "references follow the open text of other.fels (8 now): %d" % len(after))

        if "leaked" in stderr.lower():
            check(False, "no memory leak reported")

    print("RESULT:", "PASS" if not failures else "FAIL (%d)" % len(failures))
    sys.exit(0 if not failures else 1)


if __name__ == "__main__":
    main()
