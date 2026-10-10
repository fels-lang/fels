#!/usr/bin/env python3
"""Test the help while typing of `gabbro lsp`: member completion after `.`, signature help,
inlay hints, hover on locals and fields, and answers from the last good analysis while the
text does not parse.

    python tests/lsp_assist_test.py [path-to-gabbro.exe]

Prints each check and PASS, or the checks that failed.
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
EXE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "zig-out", "bin", "gabbro.exe")

SRC = """\
Color :: enum { red, green, blue }

Point :: struct {
    x: i32,
    y: i32,

    len2 :: fn(self: *Self) -> i32 { return self.x * self.x + self.y * self.y; }
    scale :: fn(self: *Self, by: i32, back: bool) -> Point { return .{ .x = self.x * by, .y = self.y * by }; }
    origin :: fn() -> Point { return .{ .x = 0, .y = 0 }; }
}

Line :: struct { a: Point, b: Point, name: []const u8, color: Color }

Err :: errors { bad }

#extern("kernel32", "Sleep") Sleep :: fn(ms: u32);
#extern("kernel32", "Beep") Beep :: fn(freq: u32, ms: u32) -> i32;

add :: fn(a: i32, b: i32) -> i32 { return a + b; }

make_line :: fn() -> Line {
    return .{ .a = Point::origin(), .b = Point::origin(), .name = "line", .color = .red };
}

check :: fn(n: i32) -> i32 ! Err {
    if n < 0 { fail .bad; }
    return n;
}

main :: fn() -> i32 {
    p: Point = .{ .x = 1, .y = 2 };
    q := &p;
    l := make_line();
    s := add(1, 2);
    k := 7u64;
    name := l.name;
    xs: [4]i32 = .{ 1, 2, 3, 4 };
    sl := xs[:];
    r := check(3);
    m := l.color;
    for v in sl { s += v; }
    if m == .red { s += 1; }
    Sleep(1u32);
    return s + q.len2() + l.a.x;
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
        yield json.loads(out[j + 4:j + 4 + clen])
        i = j + 4 + clen


def position(text, needle, delta=0):
    """The LSP position of `needle` in `text`, moved `delta` characters (ASCII text)."""
    i = text.index(needle) + delta
    return {"line": text.count("\n", 0, i), "character": i - (text.rfind("\n", 0, i) + 1)}


class Session:
    """Builds one server run: changes and requests, each request with a check."""

    def __init__(self, path):
        self.uri = "file:///" + path.replace("\\", "/")
        self.text = SRC
        self.msgs = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"capabilities": {}}},
            {"jsonrpc": "2.0", "method": "initialized", "params": {}},
            {"jsonrpc": "2.0", "method": "textDocument/didOpen",
             "params": {"textDocument": {"uri": self.uri, "languageId": "gabbro", "version": 1, "text": SRC}}},
        ]
        self.checks = {}  # id -> (name, check function)
        self.next_id = 10
        self.version = 1
        self.change_ids = []  # request ids sent after each change, for the diagnostics check

    def edit(self, old, new):
        assert old in self.text, old
        self.text = self.text.replace(old, new, 1)
        self.version += 1
        self.msgs.append({"jsonrpc": "2.0", "method": "textDocument/didChange",
                          "params": {"textDocument": {"uri": self.uri, "version": self.version},
                                     "contentChanges": [{"text": self.text}]}})

    def request(self, name, method, params, check):
        rid = self.next_id
        self.next_id += 1
        params = dict(params, textDocument={"uri": self.uri})
        self.msgs.append({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        self.checks[rid] = (name, check)

    def at(self, name, method, needle, delta, check):
        self.request(name, method, {"position": position(self.text, needle, delta)}, check)

    def hints(self, name, check):
        lines = self.text.count("\n") + 1
        self.request(name, "textDocument/inlayHint",
                     {"range": {"start": {"line": 0, "character": 0}, "end": {"line": lines, "character": 0}}}, check)

    def run(self):
        self.msgs += [{"jsonrpc": "2.0", "id": 99, "method": "shutdown"}, {"jsonrpc": "2.0", "method": "exit"}]
        p = subprocess.run([EXE, "lsp"], input=b"".join(frame(m) for m in self.msgs), capture_output=True, timeout=120)
        results, diags = {}, []
        for m in read_messages(p.stdout):
            if m.get("method") == "textDocument/publishDiagnostics":
                diags.append(m["params"]["diagnostics"])
            elif m.get("id") in self.checks:
                results[m["id"]] = m.get("result")
        failures = []
        for rid, (name, check) in self.checks.items():
            res = results.get(rid)
            try:
                ok = check(res)
            except Exception as e:  # a malformed answer is a failure, not a crash
                ok = False
                res = "%r (%s)" % (res, e)
            print("%-4s %s" % ("ok" if ok else "FAIL", name))
            if not ok:
                failures.append("%s: got %s" % (name, json.dumps(res)[:400]))
        if "leaked" in p.stderr.decode(errors="replace").lower():
            failures.append("memory leak reported")
        return failures, diags


def labels(res):
    return [i["label"] for i in (res or [])]


def detail_of(res, label):
    for i in res or []:
        if i["label"] == label:
            return i.get("detail")
    return None


def hover_text(res):
    return res["contents"]["value"] if res else ""


def hint_at(res, text, decl, label):
    """A hint with this label right after the name that `decl` (`name :=`, `for name`)
    declares in `text`."""
    name = decl.split()[-2] if decl.endswith(":=") else decl.split()[-1]
    pos = position(text, decl, decl.index(name) + len(name))
    return any(h["position"] == pos and h["label"] == label for h in res or [])


def sig(res):
    s = res["signatures"][0]
    return s["label"], res["activeParameter"], s["parameters"]


def param_text(res, k):
    label, _, params = sig(res)
    a, b = params[k]["label"]
    return label[a:b]


def main():
    tmp = tempfile.mkdtemp()
    path = os.path.join(tmp, "main.fels")
    with open(path, "w", newline="\n") as f:
        f.write(SRC)
    s = Session(path)
    t = SRC

    # Hover on a local, a parameter and a field (the text parses).
    s.at("hover on a local", "textDocument/hover", "q := &p", 0,
         lambda r: "q: *Point" in hover_text(r))
    s.at("hover on a parameter", "textDocument/hover", "return a + b", 7,
         lambda r: "a: i32" in hover_text(r))
    s.at("hover on a field", "textDocument/hover", "l.name;", 3,
         lambda r: "name: []const u8" in hover_text(r) and "field of `Line`" in hover_text(r))
    s.at("hover on a field along a chain", "textDocument/hover", "l.a.x", 4,
         lambda r: "x: i32" in hover_text(r))
    s.at("hover on a loop capture", "textDocument/hover", "s += v", 5,
         lambda r: "v: i32" in hover_text(r))
    s.at("hover on a method", "textDocument/hover", "q.len2()", 3,
         lambda r: "Point.len2 :: fn(self: *Point) -> i32" in hover_text(r))
    s.at("hover on an associated function", "textDocument/hover", "Point::origin(), .b", 8,
         lambda r: "Point.origin :: fn() -> Point" in hover_text(r))

    # Inlay hints on `:=`: suffixed number, struct, slice, pointer, result type, field.
    def hints_ok(r):
        return (hint_at(r, t, "q :=", ": *Point") and hint_at(r, t, "l :=", ": Line")
                and hint_at(r, t, "s :=", ": i32") and hint_at(r, t, "k :=", ": u64")
                and hint_at(r, t, "sl :=", ": []i32") and hint_at(r, t, "r :=", ": i32 ! Err")
                and hint_at(r, t, "name :=", ": []const u8") and hint_at(r, t, "for v", ": i32")
                # Declarations with a written type get none.
                and len(r) == 9)
    s.hints("inlay hints on := and for captures", hints_ok)

    # Signature help: function, method, #extern; the active parameter follows the commas.
    s.at("signature help: function, first argument", "textDocument/signatureHelp", "add(1, 2)", 4,
         lambda r: sig(r)[0] == "add(a: i32, b: i32) -> i32" and sig(r)[1] == 0 and param_text(r, 0) == "a: i32")
    s.at("signature help: function, after the comma", "textDocument/signatureHelp", "add(1, 2)", 7,
         lambda r: sig(r)[1] == 1 and param_text(r, 1) == "b: i32")
    s.at("signature help: #extern", "textDocument/signatureHelp", "Sleep(1u32)", 6,
         lambda r: sig(r)[0] == "Sleep(ms: u32)" and sig(r)[1] == 0)

    # Member completion on a parsed file (the cursor right after an existing dot).
    s.at("members of a struct value", "textDocument/completion", "l.a.x", 2,
         lambda r: {"a", "b", "name", "color"} <= set(labels(r)) and detail_of(r, "name") == "[]const u8")
    s.at("members through a pointer", "textDocument/completion", "q.len2", 2,
         lambda r: {"x", "y", "len2", "scale"} <= set(labels(r)) and detail_of(r, "len2") == "fn() -> i32"
         and next(i for i in r if i["label"] == "len2")["kind"] == 2)
    s.at("members along a chain a.b.", "textDocument/completion", "l.a.x", 4,
         lambda r: {"x", "y", "len2"} <= set(labels(r)) and "name" not in labels(r))
    s.at("enum literal after ==", "textDocument/completion", "m == .red", 6,
         lambda r: labels(r) == ["red", "green", "blue"] and r[0]["kind"] == 20)

    # The file stops parsing: an unfinished line `s := q.` in the body.
    s.edit("    Sleep(1u32);\n", "    Sleep(1u32);\n    w := q.\n")
    s.at("unfinished line: members through a pointer", "textDocument/completion", "w := q.", 7,
         lambda r: {"x", "y", "len2", "scale"} <= set(labels(r)))
    # `p.` alone in a body.
    s.edit("    w := q.\n", "    p.\n")
    s.at("broken file: members of a struct value", "textDocument/completion", "    p.\n", 6,
         lambda r: {"x", "y", "len2"} <= set(labels(r)) and next(i for i in r if i["label"] == "x")["kind"] == 5)
    s.edit("    p.\n", "    l.a.\n")
    s.at("broken file: members along a chain", "textDocument/completion", "    l.a.\n", 8,
         lambda r: {"x", "y"} <= set(labels(r)))
    s.edit("    l.a.\n", "    Color.\n")
    s.at("broken file: variants of an enum type", "textDocument/completion", "    Color.\n", 10,
         lambda r: labels(r) == ["red", "green", "blue"])
    s.edit("    Color.\n", "    Point::\n")
    s.at("broken file: associated functions after Type::", "textDocument/completion", "    Point::\n", 11,
         lambda r: labels(r) == ["origin"])
    s.edit("    Point::\n", "    Point.\n")

    def assoc_after_dot(r):
        item = next(i for i in r if i["label"] == "origin")
        edit = item["additionalTextEdits"][0]
        return item["kind"] == 3 and edit["newText"] == "::" and edit["range"]["start"]["character"] == 9
    s.at("broken file: an associated function after Type. turns the dot into ::", "textDocument/completion",
         "    Point.\n", 10, assoc_after_dot)
    s.edit("    Point.\n", "    make_line().b.\n")
    s.at("broken file: members of a call result", "textDocument/completion", "make_line().b.", 14,
         lambda r: {"x", "y"} <= set(labels(r)))
    s.edit("    make_line().b.\n", "    m = .\n")
    s.at("broken file: enum literal after =", "textDocument/completion", "    m = .\n", 9,
         lambda r: labels(r) == ["red", "green", "blue"])
    s.at("broken file: hover on a local", "textDocument/hover", "name := l.name", 0,
         lambda r: "name: []const u8" in hover_text(r))
    s.at("broken file: hover on a top-level name", "textDocument/hover", "add(1, 2)", 0,
         lambda r: "add :: fn(a: i32, b: i32) -> i32" in hover_text(r))

    # Signature help while the call is not closed yet.
    s.edit("    m = .\n", "    add(s, \n")
    s.at("broken file: signature help, function", "textDocument/signatureHelp", "    add(s, \n", 11,
         lambda r: sig(r)[0] == "add(a: i32, b: i32) -> i32" and sig(r)[1] == 1)
    s.edit("    add(s, \n", "    q.scale(2, \n")
    s.at("broken file: signature help, method", "textDocument/signatureHelp", "    q.scale(2, \n", 15,
         lambda r: sig(r)[0] == "scale(by: i32, back: bool) -> Point" and sig(r)[1] == 1
         and param_text(r, 1) == "back: bool")
    s.edit("    q.scale(2, \n", "    Beep(\n")
    s.at("broken file: signature help, #extern", "textDocument/signatureHelp", "    Beep(\n", 9,
         lambda r: sig(r)[0] == "Beep(freq: u32, ms: u32) -> i32" and sig(r)[1] == 0)
    s.edit("    Beep(\n", "    Beep(440u32, \n")
    s.at("broken file: signature help, #extern after the comma", "textDocument/signatureHelp",
         "    Beep(440u32, \n", 17, lambda r: sig(r)[1] == 1 and param_text(r, 1) == "ms: u32")

    # Inlay hints from the last good analysis move with the text: a line inserted above them.
    s.edit("main :: fn() -> i32 {\n", "main :: fn() -> i32 {\n    // a new line\n")
    moved = s.text

    def moved_ok(r):
        return (hint_at(r, moved, "q :=", ": *Point") and hint_at(r, moved, "k :=", ": u64")
                and hint_at(r, moved, "for v", ": i32") and len(r) == 9)
    s.hints("broken file: inlay hints follow an inserted line", moved_ok)

    failures, diags = s.run()
    # Diagnostics come from the current text: the last publish reports the syntax error.
    if not diags or not diags[-1]:
        failures.append("diagnostics: the broken text should give a syntax error, got %s" % (diags[-1:] or None))
    else:
        print("ok   diagnostics come from the current text (%s)" % diags[-1][0]["message"])
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print("  " + f)
        print("RESULT: FAIL")
        sys.exit(1)
    print("RESULT: PASS")


if __name__ == "__main__":
    main()
