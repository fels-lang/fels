#!/usr/bin/env python3
"""Time the analysis of `fels lsp` on repeated edits of one file.

    python tests/lsp_perf.py <fels.exe> <file.fels> [edits]

The server prints one line per analysis to stderr when FELS_LSP_TIMING is set.
Each edit appends a comment line, then a request forces the analysis to run.
"""
import json
import os
import re
import subprocess
import sys

exe, path = sys.argv[1], sys.argv[2]
edits = int(sys.argv[3]) if len(sys.argv) > 3 else 10


def frame(msg):
    body = json.dumps(msg).encode("utf-8")
    return b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body


text = open(path, encoding="utf-8").read()
uri = "file:///" + os.path.abspath(path).replace("\\", "/")
seq = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"capabilities": {}}},
       {"jsonrpc": "2.0", "method": "textDocument/didOpen",
        "params": {"textDocument": {"uri": uri, "languageId": "fels", "version": 1, "text": text}}}]
for i in range(edits):
    seq.append({"jsonrpc": "2.0", "method": "textDocument/didChange",
                "params": {"textDocument": {"uri": uri, "version": i + 2},
                           "contentChanges": [{"text": text + "\n// edit %d\n" % i}]}})
    seq.append({"jsonrpc": "2.0", "id": 10 + i, "method": "textDocument/documentSymbol",
                "params": {"textDocument": {"uri": uri}}})
seq += [{"jsonrpc": "2.0", "id": 99, "method": "shutdown"}, {"jsonrpc": "2.0", "method": "exit"}]
env = dict(os.environ, FELS_LSP_TIMING="1")
p = subprocess.run([exe, "lsp"], input=b"".join(frame(m) for m in seq), capture_output=True, env=env, timeout=300)
ms = [float(m) for m in re.findall(r"in ([0-9.]+) ms", p.stderr.decode(errors="replace"))]
print("%s: %d lines, first analysis %.1f ms, later: min %.1f median %.1f max %.1f ms" % (
    os.path.basename(path), text.count("\n"), ms[0], min(ms[1:]), sorted(ms[1:])[len(ms[1:]) // 2], max(ms[1:])))
