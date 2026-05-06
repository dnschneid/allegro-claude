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

TOOLS = [
    {
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
    },
    {
        "name": "allegro_read_file",
        "description": (
            "Read a file from disk, using Allegro's ACLs. Use this instead of "
            "the built-in Read tool for any file outside the session log dir, "
            "especially files the user expects you to inspect or modify "
            "(SKILL scripts, board macros, generated reports)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string",
                         "description": "Absolute path to the file"}
            },
            "required": ["path"],
        },
    },
    {
        "name": "allegro_write_file",
        "description": (
            "Write a file to disk, using Allegro's ACLs. Overwrites the file "
            "if it exists. Use this instead of the built-in Write tool. For "
            ".il (SKILL) files, the content is syntax-checked before writing "
            "-- the call fails on syntax errors without writing the file."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "path":    {"type": "string",
                            "description": "Absolute path to the file"},
                "content": {"type": "string",
                            "description": "Full new contents of the file"},
            },
            "required": ["path", "content"],
        },
    },
    {
        "name": "allegro_edit_file",
        "description": (
            "Replace one occurrence of old_string with new_string in a file on "
            "disk, using Allegro's ACLs. Use this instead of the built-in Edit "
            "or Bash tools when outside fo the session log dir, since writes "
            "within the claude sandbox may be silently redirected. old_string "
            "must be unique in the file (the call fails if it appears more "
            "than once or zero times). For .il files, the resulting content is "
            "syntax-checked before writing -- the call fails without writing "
            "if there would be syntax errors. Prefer this over "
            "allegro_write_file for small changes -- it sends much less text."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "path":       {"type": "string",
                               "description": "Absolute path to the file"},
                "old_string": {"type": "string",
                               "description":
                                   "Text to find. Must appear exactly once. "
                                   "Include enough surrounding context to "
                                   "be unambiguous."},
                "new_string": {"type": "string",
                               "description":
                                   "Replacement text. May be empty to delete."},
            },
            "required": ["path", "old_string", "new_string"],
        },
    },
    {
        "name": "allegro_multi_edit_file",
        "description": (
            "Apply a sequence of find/replace edits to a file in one "
            "round-trip, using Allegro's ACLs. Each edit's old_string "
            "must be unique in the file content as it stands at that "
            "point in the sequence (earlier edits affect later "
            "uniqueness). The whole call fails atomically -- if any one "
            "edit can't be applied, or if the final content fails the "
            ".il syntax check, the file is not modified. Use this "
            "instead of multiple allegro_edit_file calls when making "
            "several related changes to the same file."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "path":  {"type": "string",
                          "description": "Absolute path to the file"},
                "edits": {
                    "type": "array",
                    "description":
                        "Ordered list of edits. Each entry has "
                        "old_string and new_string with the same "
                        "semantics as allegro_edit_file.",
                    "items": {
                        "type": "object",
                        "properties": {
                            "old_string": {"type": "string"},
                            "new_string": {"type": "string"},
                        },
                        "required": ["old_string", "new_string"],
                    },
                    "minItems": 1,
                },
            },
            "required": ["path", "edits"],
        },
    },
]

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
            send_result(msg["id"], {"tools": TOOLS})
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
