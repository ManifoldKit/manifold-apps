#!/usr/bin/python3
"""An official newline-JSON MCP stdio fixture for Manifold Mac UI tests."""

import json
import os
import sys


def record(event):
    path = os.environ.get("MANIFOLD_MCP_FIXTURE_ATTEMPT_LOG")
    if path:
        with open(path, "a", encoding="utf-8") as log:
            log.write(event + "\n")


def write_message(payload):
    sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
    sys.stdout.flush()


record("start")
if os.environ.get("MANIFOLD_MCP_FIXTURE_MODE") == "fail":
    record("exit")
    sys.exit(1)

try:
    for line in sys.stdin:
        request = json.loads(line)
        method = request.get("method")
        request_id = request.get("id")
        if method == "initialize":
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
finally:
    record("exit")
