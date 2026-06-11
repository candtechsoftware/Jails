#!/usr/bin/env python3
"""One-off probe: typed bare `rl.` and `take(.` completions (issue repro flow)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lsp_test import LSPClient, Fixture, FIXTURE_DIR, uri_for, completion_labels, DEFAULT_JAI_PATH

client = LSPClient(DEFAULT_JAI_PATH, verbose="-v" in sys.argv)
main_fx = Fixture("main.jai")

client.request("initialize", {
    "processId": os.getpid(),
    "rootUri": uri_for(FIXTURE_DIR),
    "rootPath": FIXTURE_DIR,
    "workspaceFolders": [{"uri": uri_for(FIXTURE_DIR), "name": "fixture"}],
    "capabilities": {},
}, timeout=30)
client.notify("initialized", {})
client.notify("textDocument/didOpen", {
    "textDocument": {"uri": main_fx.uri, "languageId": "jai", "version": 1, "text": main_fx.text},
})
client.drain(1.0)

anchor = main_fx.pos_after("    color.r = 255;")
version = 2

def type_and_complete(text, col):
    global version
    client.notify("textDocument/didChange", {
        "textDocument": {"uri": main_fx.uri, "version": version},
        "contentChanges": [{"range": {"start": anchor, "end": anchor}, "text": text}],
    })
    version += 1
    client.drain(0.4)
    result = client.request("textDocument/completion", {
        "textDocument": {"uri": main_fx.uri},
        "position": {"line": anchor["line"] + 1, "character": col},
    })
    labels = completion_labels(result)
    # undo
    client.notify("textDocument/didChange", {
        "textDocument": {"uri": main_fx.uri, "version": version},
        "contentChanges": [{
            "range": {"start": anchor,
                      "end": {"line": anchor["line"] + 1, "character": len(text) - text.rfind("\n") - 1}},
            "text": "",
        }],
    })
    version += 1
    client.drain(0.4)
    return labels

for snippet, col in [("\n    rl.", 7), ("\n    take(.", 10), ("\n    take(.N", 11)]:
    labels = type_and_complete(snippet, col)
    print(f"typed {snippet!r}: {len(labels)} items, first 10: {labels[:10]}")
    print(f"   has init_window={'init_window' in labels} NORTH={'NORTH' in labels} leaked print={'print' in labels}")

client.shutdown()
