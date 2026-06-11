#!/usr/bin/env python3
"""Latency probe: times completion/definition requests against the fixture project.

Usage: python3 scripts/perf_probe.py
"""
import os
import statistics
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lsp_test import LSPClient, Fixture, FIXTURE_DIR, uri_for, completion_labels, DEFAULT_JAI_PATH

ROUNDS = 20

client = LSPClient(DEFAULT_JAI_PATH)
fx = Fixture("main.jai")

client.request("initialize", {"processId": os.getpid(), "rootUri": uri_for(FIXTURE_DIR),
    "rootPath": FIXTURE_DIR, "workspaceFolders": [{"uri": uri_for(FIXTURE_DIR), "name": "f"}],
    "capabilities": {}}, timeout=60)
client.notify("initialized", {})

# Open the on-disk text, then insert the Basic alias via didChange (didChange triggers the
# memory-file reparse path; didOpen with text differing from disk does not).
client.notify("textDocument/didOpen", {
    "textDocument": {"uri": fx.uri, "languageId": "jai", "version": 1, "text": fx.text}})
client.drain(1.0)
client.notify("textDocument/didChange", {
    "textDocument": {"uri": fx.uri, "version": 2},
    "contentChanges": [{"range": {"start": {"line": 0, "character": 0},
                                  "end": {"line": 0, "character": 0}},
                        "text": 'b :: #import "Basic";\n'}]})
text = 'b :: #import "Basic";\n' + fx.text
client.drain(2.0)

def pos_after(marker, occurrence=1):
    idx = -1
    for _ in range(occurrence):
        idx = text.index(marker, idx + 1)
    end = idx + len(marker)
    line = text.count("\n", 0, end)
    return {"line": line, "character": end - (text.rfind("\n", 0, end) + 1)}

def bench(name, method, marker, occurrence=1):
    pos = pos_after(marker, occurrence)
    times = []
    n_items = 0
    for _ in range(ROUNDS):
        t0 = time.perf_counter()
        result = client.request(method, {"textDocument": {"uri": fx.uri}, "position": pos}, timeout=30)
        times.append((time.perf_counter() - t0) * 1000)
        if method.endswith("completion"):
            n_items = len(completion_labels(result))
    times.sort()
    print(f"{name:42s} median {statistics.median(times):7.1f} ms   p90 {times[int(ROUNDS*0.9)-1]:7.1f} ms   ({n_items} items)")

bench("completion: alias Basic  b.", "textDocument/completion", "rl.init_window")  # warm-up position
bench("completion: enum arg  take(.", "textDocument/completion", "take(.")
bench("completion: named enum arg  take_named(d=.", "textDocument/completion", "take_named(d = .")
bench("completion: alias  rl.", "textDocument/completion", "rl.")
bench("completion: generic (in proc body)", "textDocument/completion", "    d = .WEST")
bench("definition: .NORTH in call arg", "textDocument/definition", "take(.NOR")
bench("definition: member through alias", "textDocument/definition", "rl.init_windo")

# the real heavy one: completing on the Basic alias
anchor = pos_after("    color.r = 255;")
client.notify("textDocument/didChange", {
    "textDocument": {"uri": fx.uri, "version": 3},
    "contentChanges": [{"range": {"start": anchor, "end": anchor}, "text": "\n    b."}]})
client.drain(1.0)
pos = {"line": anchor["line"] + 1, "character": 6}
times = []
n_items = 0
for _ in range(ROUNDS):
    t0 = time.perf_counter()
    result = client.request("textDocument/completion", {"textDocument": {"uri": fx.uri}, "position": pos}, timeout=30)
    times.append((time.perf_counter() - t0) * 1000)
    n_items = len(completion_labels(result))
times.sort()
print(f"{'completion: typed bare  b.  (Basic alias)':42s} median {statistics.median(times):7.1f} ms   p90 {times[int(ROUNDS*0.9)-1]:7.1f} ms   ({n_items} items)")

client.shutdown()
