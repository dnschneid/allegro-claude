#!/usr/bin/env python3
# SPDX-FileCopyrightText: (C) 2026 Meta Platforms Inc.
# SPDX-License-Identifier: Apache-2.0
"""Minimal MCP stdio server for Allegro SKILL execution.

Communicates with SKILL via file-based IPC under a session directory.
Layout:

  <this_script_dir> / logs / <claude-session-uuid> / tool_<tool_use_id>.out

SKILL copies this script into ACL_homeDir before launching claude, so
the script's own directory is the project home; the per-session log
dir lives under logs/<sid>/. SKILL writes the .out file there from
the same path independently.

The session UUID is discovered from CLAUDE_LAUNCHER_SESSION_FILE
(Claude CLI sets this when launching MCP servers).

Protocol (Phase 1+: SKILL-driven):
  1. Claude streams a tool_use block to SKILL with the full code.
  2. SKILL extracts the code and the tool_use_id, executes via
     ACL_execBlock, and writes <tool_use_id>.out to the session dir.
  3. Claude also calls the MCP server's tools/call. The MCP request
     carries the tool_use_id in params._meta['claudecode/toolUseId'].
  4. This server polls for tool_<tool_use_id>.out and returns its
     content as the tool result.

Because SKILL writes the .out file immediately on receiving the
tool_use stream event (well before the MCP server's tools/call usually
arrives), this server typically finds the file already present on
the first poll iteration -- no real waiting.

MCP stdio transport: newline-delimited JSON-RPC 2.0 messages.
"""

import json
import os
import re
import sys
import time

TOOL = {
    "name": "allegro_execute",
    "description": (
        "Execute SKILL code in the running Allegro PCB Editor session. "
        "Returns the evaluation result (or error) and any printed output. "
        "Use this whenever you need to query or modify the design."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "code": {
                "type": "string",
                "description": "SKILL code to evaluate in Allegro",
            }
        },
        "required": ["code"],
    },
}

BASE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")
UUID_RE = re.compile(r"\b([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\b")


def discover_session_id():
    path = os.environ.get("CLAUDE_LAUNCHER_SESSION_FILE")
    if not path:
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                m = UUID_RE.search(line)
                if m:
                    return m.group(1)
    except OSError:
        pass
    return None


# Resolved lazily on first tool call (Claude CLI may not have populated
# the launcher session file yet at startup).
_session_dir = None


def session_dir():
    global _session_dir
    if _session_dir is not None:
        return _session_dir
    sid = None
    # Retry briefly: claude may write the file just after spawning us
    for _ in range(300):  # ~3s
        sid = discover_session_id()
        if sid:
            break
        time.sleep(0.01)
    sid = sid or "unknown"
    _session_dir = os.path.join(BASE_DIR, sid)
    os.makedirs(_session_dir, exist_ok=True)
    log_session(f"resolved session={sid}")
    return _session_dir


def log_session(msg):
    path = os.path.join(_session_dir or BASE_DIR, "mcp_server.log")
    with open(path, "a", encoding="utf-8") as f:
        f.write(f"[{time.strftime('%H:%M:%S')}] {msg}\n")


def read_message():
    line = sys.stdin.readline()
    if not line:
        return None
    return json.loads(line)


def send_message(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def send_result(msg_id, result):
    send_message({"jsonrpc": "2.0", "id": msg_id, "result": result})


def handle_call(msg):
    sd = session_dir()
    params = msg.get("params", {})
    meta = params.get("_meta") or {}
    tool_use_id = meta.get("claudecode/toolUseId")
    if not tool_use_id:
        # Without an id we can't correlate to SKILL's output. Refuse loudly.
        log_session(f"call missing tool_use_id; meta={meta!r}")
        send_message({
            "jsonrpc": "2.0",
            "id": msg["id"],
            "error": {"code": -32602,
                      "message": "Missing _meta.claudecode/toolUseId"},
        })
        return

    log_session(f"call tool_use_id={tool_use_id}")
    out_path = os.path.join(sd, f"tool_{tool_use_id}.out")
    while not os.path.exists(out_path):
        time.sleep(0.01)

    with open(out_path, "r", encoding="utf-8") as f:
        result = f.read()
    # Delete the temporary result file now that we've read it
    try:
        os.unlink(out_path)
    except OSError:
        pass

    send_result(msg["id"], {"content": [{"type": "text", "text": result}]})


def main():
    while True:
        msg = read_message()
        if msg is None:
            break

        method = msg.get("method", "")

        if method == "initialize":
            send_result(msg["id"], {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "allegro", "version": "1.0.0"},
            })
        elif method == "notifications/initialized":
            pass
        elif method == "tools/list":
            send_result(msg["id"], {"tools": [TOOL]})
        elif method == "tools/call":
            handle_call(msg)
        elif method == "ping":
            send_result(msg["id"], {})
        elif "id" in msg:
            send_message({
                "jsonrpc": "2.0",
                "id": msg["id"],
                "error": {"code": -32601, "message": f"Unknown method: {method}"},
            })


if __name__ == "__main__":
    main()
