#!/usr/bin/python3
"""A process-backed newline-delimited JSON MCP stdio fixture for Mac UI tests."""

import atexit
import json
import os
import signal
import sys


def record(event):
    path = os.environ.get("MANIFOLD_MCP_FIXTURE_ATTEMPT_LOG")
    if path:
        with open(path, "a", encoding="utf-8") as log:
            log.write(event + "\n")


def write_message(payload):
    sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def record_exit():
    record("exit")
    record(f"exit-pid:{os.getpid()}")


def terminate(_signal, _frame):
    raise SystemExit(0)


mode = os.environ.get("MANIFOLD_MCP_FIXTURE_MODE", "official-newline")
record("start")
record(f"pid:{os.getpid()}")
atexit.register(record_exit)
signal.signal(signal.SIGTERM, terminate)
signal.signal(signal.SIGINT, terminate)
signal.signal(signal.SIGALRM, terminate)
# Last-resort lifetime bound if a client bug leaves a child running. UI tests
# assert SDK cleanup well before this fires; an alarm exit cannot pass them.
signal.alarm(90)
if mode not in {"official-newline", "stall-initialize", "cancel-stall", "fail"}:
    record("invalid-mode")
    sys.exit(2)
if mode == "fail":
    sys.exit(1)

for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    request_id = request.get("id")
    if method == "initialize":
        record("initialize")
        if mode in {"stall-initialize", "cancel-stall"}:
            continue
        write_message({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "protocolVersion": "2025-03-26",
                "serverInfo": {"name": "Controlled Fixture", "version": "1.0"},
                "capabilities": {"tools": {"listChanged": False}},
            },
        })
    elif method == "tools/list":
        record("tools/list")
        write_message({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "tools": [{
                    "name": "fixture_ping",
                    "description": "Controlled fixture tool",
                    "inputSchema": {"type": "object", "properties": {}},
                }],
            },
        })
