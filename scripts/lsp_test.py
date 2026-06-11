#!/usr/bin/env python3
"""Integration tests for the jails LSP server.

Spawns bin/jails, speaks LSP over stdio against the fixture project in
tests/fixtures/project/, and checks completion / definition / signatureHelp /
documentSymbol / diagnostics behavior, including reproductions of GitHub
issues #19 and #20.

Usage:
    python3 scripts/lsp_test.py [--jai-path /path/to/jai-dist] [-v]

Exit code is non-zero if any check fails.
"""

import argparse
import json
import os
import queue
import subprocess
import sys
import threading
import time

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURE_DIR = os.path.join(REPO_ROOT, "tests", "fixtures", "project")
SERVER_BIN = os.path.join(REPO_ROOT, "bin", "jails")
DEFAULT_JAI_PATH = os.path.expanduser("~/gits/jai")

REQUEST_TIMEOUT = 15.0


def uri_for(path):
    return "file://" + path


class LSPClient:
    def __init__(self, jai_path, verbose=False):
        self.verbose = verbose
        self.next_id = 1
        self.notifications = []   # all received notifications, in order
        self.diagnostics = {}     # uri -> latest diagnostics list
        self._messages = queue.Queue()
        self.proc = subprocess.Popen(
            [SERVER_BIN, "-jai_path", jai_path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=FIXTURE_DIR,
        )
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()
        self._stderr_reader = threading.Thread(target=self._stderr_loop, daemon=True)
        self._stderr_reader.start()

    # --- wire protocol -----------------------------------------------------

    def _send(self, payload):
        body = json.dumps(payload).encode("utf-8")
        # NOTE: jails' rpc.jai supports exactly ONE header line, so only
        # Content-Length may be sent here.
        frame = b"Content-Length: %d\r\n\r\n%s" % (len(body), body)
        self.proc.stdin.write(frame)
        self.proc.stdin.flush()
        if self.verbose:
            print(f">>> {json.dumps(payload)[:200]}", file=sys.stderr)

    def _read_loop(self):
        stdout = self.proc.stdout
        while True:
            header = stdout.readline()
            if not header:
                self._messages.put(None)
                return
            if not header.lower().startswith(b"content-length:"):
                continue
            length = int(header.split(b":")[1].strip())
            stdout.readline()  # the blank \r\n line
            body = stdout.read(length)
            try:
                msg = json.loads(body)
            except json.JSONDecodeError:
                continue
            if self.verbose:
                print(f"<<< {json.dumps(msg)[:200]}", file=sys.stderr)
            self._messages.put(msg)

    def _stderr_loop(self):
        for line in self.proc.stderr:
            if self.verbose:
                print(f"[stderr] {line.decode(errors='replace').rstrip()}", file=sys.stderr)

    # --- message pump ------------------------------------------------------

    def _pump(self, msg):
        """Record a server-initiated message."""
        self.notifications.append(msg)
        if msg.get("method") == "textDocument/publishDiagnostics":
            params = msg.get("params", {})
            self.diagnostics[params.get("uri", "")] = params.get("diagnostics", [])

    def notify(self, method, params):
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def request(self, method, params, timeout=REQUEST_TIMEOUT):
        req_id = self.next_id
        self.next_id += 1
        self._send({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"no response to {method} (id {req_id}) within {timeout}s")
            try:
                msg = self._messages.get(timeout=remaining)
            except queue.Empty:
                continue
            if msg is None:
                raise ConnectionError(f"server died while waiting for {method} (id {req_id})")
            if msg.get("id") == req_id:
                return msg.get("result")
            self._pump(msg)

    def drain(self, duration):
        """Collect notifications for `duration` seconds."""
        deadline = time.monotonic() + duration
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            try:
                msg = self._messages.get(timeout=remaining)
            except queue.Empty:
                return
            if msg is None:
                return
            self._pump(msg)

    def alive(self):
        return self.proc.poll() is None

    def shutdown(self):
        try:
            if self.alive():
                self.request("shutdown", None, timeout=5)
        except (TimeoutError, ConnectionError, BrokenPipeError):
            pass
        finally:
            try:
                self.proc.kill()
            except ProcessLookupError:
                pass


# --- fixture helpers --------------------------------------------------------

class Fixture:
    def __init__(self, name):
        self.path = os.path.join(FIXTURE_DIR, name)
        self.uri = uri_for(self.path)
        with open(self.path) as f:
            self.text = f.read()
        self.lines = self.text.split("\n")

    def pos_after(self, marker, occurrence=1):
        """(line, character) just after the end of the Nth occurrence of marker."""
        idx = -1
        for _ in range(occurrence):
            idx = self.text.index(marker, idx + 1)
        end = idx + len(marker)
        line = self.text.count("\n", 0, end)
        col = end - (self.text.rfind("\n", 0, end) + 1)
        return {"line": line, "character": col}


# --- checks ------------------------------------------------------------------

class Results:
    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.rows = []

    def record(self, name, ok, detail=""):
        self.rows.append((name, ok, detail))
        if ok:
            self.passed += 1
            print(f"  PASS  {name}")
        else:
            self.failed += 1
            print(f"  FAIL  {name}{' — ' + detail if detail else ''}")


def completion_labels(result):
    if result is None:
        return []
    items = result.get("items", []) if isinstance(result, dict) else result
    return [it.get("label", "") for it in items if isinstance(it, dict)]


def check_completion(client, results, name, fixture, marker, must=(), must_not=(), occurrence=1):
    pos = fixture.pos_after(marker, occurrence)
    try:
        result = client.request("textDocument/completion", {
            "textDocument": {"uri": fixture.uri},
            "position": pos,
        })
    except (TimeoutError, ConnectionError) as e:
        results.record(name, False, str(e))
        return
    labels = completion_labels(result)
    missing = [m for m in must if m not in labels]
    leaked = [m for m in must_not if m in labels]
    detail = ""
    if missing:
        detail += f"missing {missing} (got {len(labels)} items: {labels[:8]}{'...' if len(labels) > 8 else ''})"
    if leaked:
        detail += f"{' ; ' if detail else ''}leaked {leaked}"
    results.record(name, not missing and not leaked, detail)


def check_definition(client, results, name, fixture, marker, expect_path_contains, occurrence=1):
    pos = fixture.pos_after(marker, occurrence)
    try:
        result = client.request("textDocument/definition", {
            "textDocument": {"uri": fixture.uri},
            "position": pos,
        })
    except (TimeoutError, ConnectionError) as e:
        results.record(name, False, str(e))
        return
    locations = result if isinstance(result, list) else ([result] if result else [])
    uris = [loc.get("uri") or loc.get("targetUri", "") for loc in locations if isinstance(loc, dict)]
    ok = any(expect_path_contains in u for u in uris)
    results.record(name, ok, "" if ok else f"got {uris or 'no locations'}")


# --- main scenario ------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jai-path", default=DEFAULT_JAI_PATH)
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(SERVER_BIN):
        print(f"server binary not found at {SERVER_BIN}; build with: jai build.jai", file=sys.stderr)
        return 2

    main_fixture = Fixture("main.jai")
    broken_fixture = Fixture("broken.jai")

    client = LSPClient(args.jai_path, verbose=args.verbose)
    results = Results()

    try:
        init_result = client.request("initialize", {
            "processId": os.getpid(),
            "rootUri": uri_for(FIXTURE_DIR),
            "rootPath": FIXTURE_DIR,
            "workspaceFolders": [{"uri": uri_for(FIXTURE_DIR), "name": "fixture"}],
            "capabilities": {},
        }, timeout=30)
        results.record("initialize", bool(init_result and "capabilities" in init_result))
        client.notify("initialized", {})

        for fx in (main_fixture, broken_fixture):
            client.notify("textDocument/didOpen", {
                "textDocument": {"uri": fx.uri, "languageId": "jai", "version": 1, "text": fx.text},
            })
        client.drain(1.0)

        print("\n-- regression controls (should pass before and after fixes) --")
        check_completion(client, results, "plain struct member", main_fixture, "plain_struct.",
                         must=["my_value"], must_not=["print"])
        check_completion(client, results, "enum comparison  x == .", main_fixture, "if d == .",
                         must=["NORTH", "EAST"])
        check_completion(client, results, "enum assignment  x = .", main_fixture, "    d = .",
                         must=["NORTH", "WEST"])
        check_completion(client, results, "enum case  case .", main_fixture, "case .",
                         must=["NORTH"])
        check_definition(client, results, "goto definition of struct member", main_fixture,
                         "plain_struct.my_valu", "main.jai", occurrence=1)

        sig_pos = main_fixture.pos_after("take(")
        try:
            sig = client.request("textDocument/signatureHelp", {
                "textDocument": {"uri": main_fixture.uri}, "position": sig_pos})
            sigs = (sig or {}).get("signatures", [])
            ok = any("Direction" in s.get("label", "") for s in sigs)
            results.record("signatureHelp on take(", ok, "" if ok else f"got {sigs}")
        except (TimeoutError, ConnectionError) as e:
            results.record("signatureHelp on take(", False, str(e))

        try:
            syms = client.request("textDocument/documentSymbol", {
                "textDocument": {"uri": main_fixture.uri}})
            names = [s.get("name") for s in (syms or [])]
            ok = all(n in names for n in ("Direction", "My_Struct", "main"))
            results.record("documentSymbol", ok, "" if ok else f"got {names[:12]}")
        except (TimeoutError, ConnectionError) as e:
            results.record("documentSymbol", False, str(e))

        print("\n-- issue #19: implicit enum dereference in call args --")
        check_completion(client, results, "positional arg  take(.", main_fixture, "take(.",
                         must=["NORTH", "SOUTH"], must_not=["print", "my_struct"])
        check_completion(client, results, "named arg  take_named(d = .", main_fixture, "take_named(d = .",
                         must=["NORTH", "SOUTH"], must_not=["print", "my_struct"])
        check_definition(client, results, "goto .NORTH in positional call arg", main_fixture,
                         "take(.NOR", "main.jai")
        check_definition(client, results, "goto .SOUTH in named call arg", main_fixture,
                         "take_named(d = .SOU", "main.jai")

        print("\n-- issue #20a: struct-literal initialization --")
        check_completion(client, results, "member after .{} init", main_fixture, "my_struct.",
                         must=["my_value"], must_not=["print"])
        check_definition(client, results, "goto member after .{} init", main_fixture,
                         "my_struct.my_valu", "main.jai")
        check_definition(client, results, "goto member inside dotless .{} literal", main_fixture,
                         ".{my_valu", "main.jai")

        print("\n-- issue #20b: using / #as using forwarding --")
        check_completion(client, results, "using member forwarding", main_fixture, "combined.",
                         must=["other_value", "combined_value"])
        check_completion(client, results, "#as using forwarding", main_fixture, "as_struct.",
                         must=["position", "extra"])
        check_completion(client, results, "pointer using forwarding", main_fixture, "ptr_using.",
                         must=["position", "flag"])

        print("\n-- issue #20b: double-using crash --")
        check_completion(client, results, "completion in double-using block", main_fixture,
                         "my_value = 3", must=[])
        results.record("server alive after double-using", client.alive())

        print("\n-- issue #20c: aliased module import --")
        check_completion(client, results, "alias rl. members only", main_fixture, "rl.",
                         must=["init_window", "Color", "Window_Flag"],
                         must_not=["print", "internal_helper", "My_Struct"])
        check_completion(client, results, "member of aliased type", main_fixture, "color.",
                         must=["r", "g", "b", "a"])
        check_definition(client, results, "goto through alias", main_fixture,
                         "rl.init_windo", "fakeray", occurrence=1)

        print("\n-- didChange typing flow --")
        # Simulate typing a fresh incomplete "d = ." right after the existing one.
        anchor = main_fixture.pos_after("    d = .WEST;")
        client.notify("textDocument/didChange", {
            "textDocument": {"uri": main_fixture.uri, "version": 2},
            "contentChanges": [{
                "range": {"start": anchor, "end": anchor},
                "text": "\n    d = .",
            }],
        })
        client.drain(0.5)
        typed_pos = {"line": anchor["line"] + 1, "character": len("    d = .")}
        try:
            result = client.request("textDocument/completion", {
                "textDocument": {"uri": main_fixture.uri}, "position": typed_pos})
            labels = completion_labels(result)
            ok = "NORTH" in labels
            results.record("completion after typed  d = .", ok,
                           "" if ok else f"got {labels[:8]}")
        except (TimeoutError, ConnectionError) as e:
            results.record("completion after typed  d = .", False, str(e))

        print("\n-- diagnostics (multi-error) --")
        client.notify("textDocument/didSave", {
            "textDocument": {"uri": broken_fixture.uri},
        })
        # Compilation can take a few seconds the first time.
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and not client.diagnostics.get(broken_fixture.uri):
            client.drain(0.5)
        diags = client.diagnostics.get(broken_fixture.uri, [])
        errors = [d for d in diags if d.get("severity") == 1]
        warnings = [d for d in diags if d.get("severity") == 2]
        results.record("error diagnostic published", len(errors) >= 1,
                       f"got {len(diags)} diagnostics: {[d.get('message', '')[:60] for d in diags]}")
        results.record("warning diagnostic published (deprecated)", len(warnings) >= 1,
                       f"got severities {[d.get('severity') for d in diags]}")
        err_line = broken_fixture.text.split("\n").index('    x: int = "not an int";')
        ok = any(d.get("range", {}).get("start", {}).get("line") == err_line for d in errors)
        results.record("error diagnostic on correct line", ok,
                       f"expected line {err_line}, got {[d.get('range', {}).get('start', {}).get('line') for d in errors]}")
        ok = any(d.get("range", {}).get("end", {}).get("character", 0)
                 > d.get("range", {}).get("start", {}).get("character", 0) for d in errors)
        results.record("error diagnostic has nonzero extent", ok)

    finally:
        client.shutdown()

    print(f"\n{results.passed} passed, {results.failed} failed")
    return 1 if results.failed else 0


if __name__ == "__main__":
    sys.exit(main())
