#!/usr/bin/env python3
"""Test what `fels lsp` writes for editing: completions that insert a call with a tab stop per
argument (when the editor takes snippets), the comment above a declaration as its
documentation in hover, completion and signature help, and the statement snippets.

    python tests/lsp_editing_test.py [path-to-fels.exe]

Prints each check and PASS, or the checks that failed.
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
EXE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "zig-out", "bin", "fels.exe")

SRC = """\
LIMIT :: 10;
counter: i32 = 0;

// A point on the grid.
Point :: struct {
    x: i32, // across
    y: i32,

    // Scale both coordinates.
    scale :: fn(self: *Self, by: i32, back: bool) -> Point { return .{ .x = self.x * by, .y = self.y * by }; }
    // The origin, (0, 0).
    origin :: fn() -> Point { return .{ .x = 0, .y = 0 }; }
}

// Add two numbers ──────
//
// The sum of `a` and `b`.
#inline
add :: fn(a: i32, b: i32) -> i32 { return a + b; }

make :: fn($T: type, n: usize) -> usize { return n + core::sizeof(T); }
first :: fn(xs: []$T) -> T { return xs[0]; }
tick :: fn() {}

main :: fn() -> i32 {
    p: Point = .{ .x = 1, .y = 2 };
    q := &p;
    s := add(1, 2);
    tick();
    k := make(i32, 3);
    xs: [2]i32 = .{ 4, 5 };
    f := first(xs[:]);
    o := Point::origin();
    return s + q.x;
}
"""


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
        clen = int(next(h for h in header.split("\r\n") if h.lower().startswith("content-length")).split(":")[1])
        body = out[j + 4:j + 4 + clen]
        i = j + 4 + clen
        yield json.loads(body)


def position(text, needle, delta=0):
    i = text.index(needle) + delta
    return {"line": text.count("\n", 0, i), "character": i - (text.rfind("\n", 0, i) + 1)}


def run(path, text, snippets, requests):
    """One server run over `text`; `requests` is a list of (method, needle, delta). The answers,
    in order."""
    uri = "file:///" + path.replace("\\", "/")
    caps = {"textDocument": {"completion": {"completionItem": {"snippetSupport": True}}}} if snippets else {}
    msgs = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"capabilities": caps}},
        {"jsonrpc": "2.0", "method": "initialized", "params": {}},
        {"jsonrpc": "2.0", "method": "textDocument/didOpen",
         "params": {"textDocument": {"uri": uri, "languageId": "fels", "version": 1, "text": text}}},
    ]
    for k, (method, needle, delta) in enumerate(requests):
        msgs.append({"jsonrpc": "2.0", "id": 10 + k, "method": method,
                     "params": {"textDocument": {"uri": uri}, "position": position(text, needle, delta)}})
    msgs += [{"jsonrpc": "2.0", "id": 99, "method": "shutdown"}, {"jsonrpc": "2.0", "method": "exit"}]
    p = subprocess.run([EXE, "lsp"], input=b"".join(frame(m) for m in msgs), capture_output=True, timeout=120)
    results = {}
    for m in read_messages(p.stdout):
        if "id" in m and m["id"] >= 10 and m["id"] != 99:
            results[m["id"]] = m.get("result")
    return [results.get(10 + k) for k in range(len(requests))]


def item(res, label):
    for i in res or []:
        if i["label"] == label:
            return i
    return {}


def doc_of(i):
    d = i.get("documentation")
    return d["value"] if isinstance(d, dict) else (d or "")


def hover_text(res):
    return res["contents"]["value"] if res else ""


def main():
    tmp = tempfile.mkdtemp()
    path = os.path.join(tmp, "main.fels")
    # completion at a name being typed: `ad` of `add(1, 2)` is followed by `(`, so a copy of the
    # text with the call's arguments gone is used for the call completions
    typed = SRC.replace("s := add(1, 2);", "s := ad;").replace("tick();", "ti;").replace(
        "k := make(i32, 3);", "k := ma;").replace("f := first(xs[:]);", "f := fir;").replace(
        "o := Point::origin();", "o := Point::or;").replace("return s + q.x;", "q.sc;\n    return s + q.x;")
    with open(path, "w", newline="\n", encoding="utf-8") as f:
        f.write(typed)
    checks = []

    def check(name, ok, got=None):
        checks.append((name, ok, got))

    req = [
        ("textDocument/completion", "s := ad;", 7),
        ("textDocument/completion", "ti;", 2),
        ("textDocument/completion", "k := ma;", 7),
        ("textDocument/completion", "f := fir;", 8),
        ("textDocument/completion", "q.sc;", 4),
        ("textDocument/completion", "Point::or;", 9),
        ("textDocument/completion", "s := ad;", 5),
    ]
    add, tick, make, first, scale, origin, stmt = run(path, typed, True, req)
    a = item(add, "add")
    check("a function completes as a call, a tab stop per argument", a.get("insertText") == "add(${1:a}, ${2:b})$0" and a.get("insertTextFormat") == 2, a)
    check("its parameters and result beside the name", (a.get("labelDetails") or {}).get("detail") == "(a: i32, b: i32) -> i32", a)
    check("its documentation is the comment above it", doc_of(a) == "Add two numbers\n\nThe sum of `a` and `b`.", a)
    check("a function of no arguments puts the cursor after ()", item(tick, "tick").get("insertText") == "tick()$0", item(tick, "tick"))
    check("a type parameter not inferred is an argument", item(make, "make").get("insertText") == "make(${1:T}, ${2:n})$0", item(make, "make"))
    check("a type parameter inferred is not", item(first, "first").get("insertText") == "first(${1:xs})$0", item(first, "first"))
    s = item(scale, "scale")
    check("a method completes without its receiver", s.get("insertText") == "scale(${1:by}, ${2:back})$0", s)
    check("a method's documentation", doc_of(s) == "Scale both coordinates.", s)
    o = item(origin, "origin")
    check("an associated function completes as a call", o.get("insertText") == "origin()$0" and doc_of(o) == "The origin, (0, 0).", o)
    check("a global shows its type beside its name", (item(stmt, "counter").get("labelDetails") or {}).get("detail") == ": i32 = 0", item(stmt, "counter"))
    check("a constant shows its value", (item(stmt, "LIMIT").get("labelDetails") or {}).get("detail") == " :: 10", item(stmt, "LIMIT"))
    st = item(stmt, "for … in")
    check("statement snippets: for … in", st.get("insertTextFormat") == 2 and st.get("insertText", "").startswith("for ${1:x} in ${2:items} {"), st)
    check("statement snippets: #test", "#test\n" in item(stmt, "#test").get("insertText", ""), item(stmt, "#test"))

    # No snippets without the editor's word for it.
    plain_add, plain_stmt = run(path, typed, False, [req[0], req[6]])
    check("no snippet when the editor takes none", "insertText" not in item(plain_add, "add") and item(plain_stmt, "for … in") == {}, item(plain_add, "add"))

    # A call written already keeps its `(`: the name alone.
    with open(path, "w", newline="\n", encoding="utf-8") as f:
        f.write(SRC)
    written, hov_add, hov_method, hov_field, hov_type, sig = run(path, SRC, True, [
        ("textDocument/completion", "s := add(1, 2);", 7),
        ("textDocument/hover", "s := add(1, 2);", 6),
        ("textDocument/hover", "Point::origin();", 9),
        ("textDocument/hover", "q.x;", 2),
        ("textDocument/hover", "p: Point", 4),
        ("textDocument/signatureHelp", "add(1, 2);", 4),
    ])
    check("a call written already completes as the name", "insertText" not in item(written, "add"), item(written, "add"))
    check("hover shows the documentation", "The sum of `a` and `b`." in hover_text(hov_add), hover_text(hov_add))
    check("hover on a method shows its documentation", "The origin, (0, 0)." in hover_text(hov_method), hover_text(hov_method))
    check("hover on a field shows the comment after it", "across" in hover_text(hov_field), hover_text(hov_field))
    check("hover on a type shows the comment above it", "A point on the grid." in hover_text(hov_type), hover_text(hov_type))
    sd = (sig or {}).get("signatures", [{}])[0].get("documentation") or {}
    check("signature help shows the documentation", "The sum of" in sd.get("value", ""), sig)

    failures = []
    for name, ok, got in checks:
        print("%-4s %s" % ("ok" if ok else "FAIL", name))
        if not ok:
            failures.append("%s: got %s" % (name, json.dumps(got)[:400]))
    if failures:
        print("\n".join(failures))
        print("RESULT: FAIL")
        sys.exit(1)
    print("RESULT: PASS")


if __name__ == "__main__":
    main()
