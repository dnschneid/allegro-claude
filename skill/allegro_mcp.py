#!/usr/bin/env python3
# SPDX-FileCopyrightText: (C) 2026 Meta Platforms Inc.
# SPDX-License-Identifier: Apache-2.0
"""Minimal MCP stdio server for Allegro SKILL execution.

Communicates with SKILL via file-based IPC under a session directory:

  $ALLEGRO_MCP_DIR / <claude-session-uuid> / queue / cmd_<seq>.il
  $ALLEGRO_MCP_DIR / <claude-session-uuid> / cmd_<seq>.il
  $ALLEGRO_MCP_DIR / <claude-session-uuid> / cmd_<seq>.out

The session UUID is discovered from CLAUDE_LAUNCHER_SESSION_FILE (Claude
CLI sets this when launching MCP servers). SKILL learns the same UUID
from the stream-json output and constructs the same path independently.

Protocol (single-launch-dir, two-stage publish via queue/ subdir):
  1. This server writes cmd_<seq>.il in the session dir, then moves it to
     queue/cmd_<seq>.il (atomic publish).
  2. SKILL sees queue/cmd_<seq>.il, executes it, writes queue/cmd_<seq>.out,
     then moves both files out of queue/ into the session dir.
  3. This server polls for session/cmd_<seq>.out as the completion signal.

Sequence numbers are global to the session directory. We scan the dir
at startup to pick up where the previous run left off.

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

BASE_DIR = os.environ["ALLEGRO_MCP_DIR"]
SEQ_RE = re.compile(r"^cmd_(\d+)\.(?:il|out)$")
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
_initial_seq_done = False


def session_dir():
    global _session_dir, _initial_seq_done, seq
    if _session_dir is not None:
        return _session_dir
    sid = None
    # Retry briefly: claude may write the file just after spawning us
    for _ in range(60):  # ~3s
        sid = discover_session_id()
        if sid:
            break
        time.sleep(0.05)
    sid = sid or "unknown"
    _session_dir = os.path.join(BASE_DIR, sid)
    os.makedirs(os.path.join(_session_dir, "queue"), exist_ok=True)
    if not _initial_seq_done:
        seq = _initial_seq(_session_dir)
        _initial_seq_done = True
    log_session(f"resolved session={sid}")
    return _session_dir


def queue_dir():
    return os.path.join(session_dir(), "queue")


def log_session(msg):
    path = os.path.join(_session_dir or BASE_DIR, "mcp_server.log")
    with open(path, "a", encoding="utf-8") as f:
        f.write(f"[{time.strftime('%H:%M:%S')}] {msg}\n")


def _initial_seq(directory):
    high = 0
    try:
        for name in os.listdir(directory):
            m = SEQ_RE.match(name)
            if m:
                n = int(m.group(1))
                if n > high:
                    high = n
    except FileNotFoundError:
        pass
    return high


seq = 0


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
    global seq
    sd = session_dir()
    qd = queue_dir()
    seq += 1
    code = msg["params"]["arguments"]["code"]

    # Write cmd to session dir, then atomically move into queue/ to publish
    base_path = os.path.join(sd, f"cmd_{seq}.il")
    queue_path = os.path.join(qd, f"cmd_{seq}.il")
    with open(base_path, "w", encoding="utf-8") as f:
        f.write(code)
    os.replace(base_path, queue_path)

    # Wait for SKILL to move cmd_<seq>.out back to session dir
    out_path = os.path.join(sd, f"cmd_{seq}.out")
    while not os.path.exists(out_path):
        time.sleep(0.05)

    with open(out_path, "r", encoding="utf-8") as f:
        result = f.read()

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
