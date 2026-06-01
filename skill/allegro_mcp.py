#!/usr/bin/env python3
# SPDX-FileCopyrightText: (C) 2026 Meta Platforms Inc.
# SPDX-License-Identifier: Apache-2.0
"""Minimal MCP stdio server for Allegro SKILL execution.

Communicates with SKILL via file-based IPC under a session directory.
Layout:

  <this_script_dir> / logs / <agent-session-uuid> / tool_<tool_use_id>.out

SKILL copies this script into ACL_homeDir before launching the agent,
so the script's own directory is the project home; the per-session
log dir lives under logs/<sid>/.

Session matchup: SKILL exports a per-launch tag (via argv[1] for codex,
which scrubs env on subprocess spawn; via ACL_SESSION_TAG in env for
claude, which inherits cleanly) and -- once the agent reveals its real
session UUID -- stamps the same tag into <session-dir>/acl_tag. This
server scans logs/*/acl_tag for the match, so the handshake doesn't
depend on any agent-internal state.

Protocol (SKILL-driven):
  1. Agent streams a tool_use block to SKILL with the full code.
  2. SKILL extracts the code and the tool_use_id, executes via
     ACL_execBlock, and writes <tool_use_id>.out to the session dir.
  3. Agent also calls the MCP server's tools/call. Claude carries the
     tool_use_id in params._meta['claudecode/toolUseId']; codex omits
     it, so we match by (name, arguments) against the .req sidecar
     SKILL drops alongside each .out.
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
        # SKILL approvals are routed through ACL_mode (manual / auto /
        # quiet) inside Allegro, so the host's per-call prompt should
        # stay quiet.
        "annotations": {"destructiveHint": False, "openWorldHint": False},
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
            "Read a file from disk, using Allegro's ACLs. Falls back path "
            "for files the built-in Read tool can't reach -- prefer the "
            "built-in for anything inside the sandbox; reach for this when "
            "Read fails or when the user explicitly wants Allegro's view of "
            "a file (SKILL scripts, board macros, generated reports). The "
            "response is hard-capped at 20480 bytes per call -- chunk longer "
            "files via `offset` + `length`."
        ),
        "annotations": {"readOnlyHint": True, "openWorldHint": False},
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Absolute path to the file"},
                "offset": {
                    "type": "integer",
                    "description": "Where to start reading. Line index "
                    "(0-based) unless is_binary is true, in "
                    "which case it's a byte offset. Default 0.",
                    "default": 0,
                },
                "length": {
                    "type": "integer",
                    "description": "How much to read. Line count unless "
                    "is_binary is true, in which case it's a "
                    "byte count. Default 2000.",
                    "default": 2000,
                },
                "is_binary": {
                    "type": "boolean",
                    "description": "Treat the file as opaque bytes (no line "
                    "splitting). offset/length switch to byte "
                    "units. Default false.",
                    "default": False,
                },
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
        "annotations": {"destructiveHint": False, "openWorldHint": False},
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Absolute path to the file"},
                "content": {
                    "type": "string",
                    "description": "Full new contents of the file",
                },
            },
            "required": ["path", "content"],
        },
    },
    {
        "name": "allegro_edit_file",
        "description": (
            "Replace one occurrence of old_string with new_string in a file on "
            "disk, using Allegro's ACLs. Use this instead of the built-in Edit "
            "or Bash tools when outside of the session log dir, since writes "
            "within the agent sandbox may be silently redirected. old_string "
            "must be unique in the file (the call fails if it appears more "
            "than once or zero times). For .il files, the resulting content is "
            "syntax-checked before writing -- the call fails without writing "
            "if there would be syntax errors. Prefer this over "
            "allegro_write_file for small changes -- it sends much less text."
        ),
        "annotations": {"destructiveHint": False, "openWorldHint": False},
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Absolute path to the file"},
                "old_string": {
                    "type": "string",
                    "description": "Text to find. Must appear exactly once. "
                    "Include enough surrounding context to "
                    "be unambiguous.",
                },
                "new_string": {
                    "type": "string",
                    "description": "Replacement text. May be empty to delete.",
                },
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
        "annotations": {"destructiveHint": False, "openWorldHint": False},
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Absolute path to the file"},
                "edits": {
                    "type": "array",
                    "description": "Ordered list of edits. Each entry has "
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
TAG_FILE = "acl_tag"
# Cap the wait for SKILL to stamp the tag (it does so as soon as the
# agent reveals its real session UUID). No cap on tool outputs --
# allegro_execute can run arbitrarily long SKILL.
SESSION_TAG_TIMEOUT_S = 30.0
POLL_INTERVAL_S = 0.01


def find_session_dir_by_tag(tag):
    # Returns the path of the session dir whose acl_tag matches, or None.
    try:
        entries = os.listdir(BASE_DIR)
    except OSError as e:
        log_session(f"listdir({BASE_DIR!r}) failed: {e}")
        return None
    for name in entries:
        sd = os.path.join(BASE_DIR, name)
        tag_path = os.path.join(sd, TAG_FILE)
        try:
            with open(tag_path, "r", encoding="utf-8") as f:
                if f.read().strip() == tag:
                    return sd
        except OSError:
            continue
    return None


# Resolved lazily on first tool call; SKILL may not have stamped
# the tag yet at startup.
_session_dir = None
_session_resolve_error = None


def session_tag():
    # SKILL exports the per-launch tag two ways: as ACL_SESSION_TAG in
    # the env (claude path -- env survives because claude inherits it
    # cleanly), and as argv[1] (codex path -- codex scrubs the env
    # before launching the MCP subprocess so the env-var fallback is
    # invisible). Try argv first so an explicit override always wins.
    if len(sys.argv) > 1 and sys.argv[1]:
        return sys.argv[1]
    return os.environ.get("ACL_SESSION_TAG") or None


def session_dir():
    # (path, None) on success; (None, error) if unresolvable. Error is
    # sticky so repeated tool calls don't each burn the full timeout.
    global _session_dir, _session_resolve_error
    if _session_dir is not None:
        return _session_dir, None
    if _session_resolve_error is not None:
        return None, _session_resolve_error
    tag = session_tag()
    log_session(f"resolving session dir for tag={tag!r}")
    if not tag:
        _session_resolve_error = (
            "ACL session tag not provided via argv[1] or "
            "ACL_SESSION_TAG env var; SKILL handshake missing."
        )
        return None, _session_resolve_error
    deadline = time.monotonic() + SESSION_TAG_TIMEOUT_S
    while True:
        sd = find_session_dir_by_tag(tag)
        if sd:
            _session_dir = sd
            log_session(f"resolved session dir={sd} tag={tag}")
            return sd, None
        if time.monotonic() >= deadline:
            _session_resolve_error = (
                f"No session dir under {BASE_DIR} contains acl_tag={tag} "
                f"after {SESSION_TAG_TIMEOUT_S:.0f}s; SKILL hasn't stamped "
                f"the tag (system/init may not have fired)."
            )
            return None, _session_resolve_error
        time.sleep(POLL_INTERVAL_S)


def log_session(msg):
    # Log to stderr (the agent CLI captures and surfaces it). Also try
    # to mirror to a file under the resolved session dir for offline
    # debugging; the file write is best-effort because the sandbox may
    # block writes to that dir for some agent CLIs.
    line = f"[allegro_mcp {time.strftime('%H:%M:%S')}] {msg}"
    print(line, file=sys.stderr, flush=True)
    target = _session_dir or BASE_DIR
    try:
        os.makedirs(target, exist_ok=True)
        with open(os.path.join(target, "mcp_server.log"), "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


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


def match_id_by_content(sd, name, arguments, timeout_s=30.0):
    # Codex's MCP tools/call carries no tool_use_id in _meta. SKILL
    # writes a tool_<id>.req sidecar alongside every tool_<id>.out
    # whose body is {"name": <bare-tool>, "arguments": <call args>}.
    # Scan those, oldest first, for the one whose (name, arguments)
    # matches this incoming call. Wait up to `timeout_s` for a match
    # since SKILL may not have drained the call yet.
    target = (name or "", arguments or {})
    deadline = time.monotonic() + timeout_s
    while True:
        candidates = []
        for fname in os.listdir(sd):
            if not fname.startswith("tool_") or not fname.endswith(".req"):
                continue
            req_path = os.path.join(sd, fname)
            try:
                with open(req_path, "r", encoding="utf-8") as f:
                    payload = json.loads(f.read())
            except (OSError, ValueError):
                continue
            if (payload.get("name") or "", payload.get("arguments") or {}) != target:
                continue
            try:
                mtime = os.path.getmtime(req_path)
            except OSError:
                continue
            candidates.append((mtime, fname[len("tool_") : -len(".req")]))
        if candidates:
            candidates.sort()
            return candidates[0][1]
        if time.monotonic() >= deadline:
            return None
        time.sleep(POLL_INTERVAL_S)


def handle_call(msg):
    params = msg.get("params", {})
    meta = params.get("_meta") or {}
    # claude CLI passes the tool_use_id here; codex doesn't.
    tool_use_id = meta.get("claudecode/toolUseId")
    sd, err = session_dir()
    if not sd:
        log_session(f"call aborted: {err}")
        send_message(
            {
                "jsonrpc": "2.0",
                "id": msg["id"],
                "error": {
                    "code": -32603,
                    "message": f"allegro MCP: cannot resolve session dir: {err}",
                },
            }
        )
        return
    if not tool_use_id:
        # Fall back to (name, arguments) matching against SKILL's
        # sidecars -- the codex path.
        tool_use_id = match_id_by_content(
            sd, params.get("name"), params.get("arguments")
        )
        if not tool_use_id:
            log_session(
                f"call no id and no matching req sidecar; "
                f"name={params.get('name')!r} meta={meta!r}"
            )
            send_message(
                {
                    "jsonrpc": "2.0",
                    "id": msg["id"],
                    "error": {
                        "code": -32603,
                        "message": "allegro MCP: could not correlate tools/call to a pending SKILL execution",
                    },
                }
            )
            return
        log_session(f"matched call by content -> tool_use_id={tool_use_id}")

    log_session(f"call tool_use_id={tool_use_id}")
    out_path = os.path.join(sd, f"tool_{tool_use_id}.out")
    req_path = os.path.join(sd, f"tool_{tool_use_id}.req")
    err_path = os.path.join(sd, f"tool_{tool_use_id}.err")
    while not os.path.exists(out_path):
        time.sleep(POLL_INTERVAL_S)

    with open(out_path, "r", encoding="utf-8") as f:
        result = f.read()
    # SKILL drops an empty .err sidecar when the tool returns an
    # "*error*"/"*Error*" string. Surface that as a JSON-RPC error,
    # not the spec's `isError` flag on a successful result -- codex
    # ignores the latter and feeds the error string back as a
    # normal observation.
    is_error = os.path.exists(err_path)
    for p in (out_path, req_path, err_path):
        try:
            os.unlink(p)
        except OSError:
            pass

    if is_error:
        send_message(
            {
                "jsonrpc": "2.0",
                "id": msg["id"],
                "error": {"code": -32000, "message": result},
            }
        )
        return
    send_result(msg["id"], {"content": [{"type": "text", "text": result}]})


def main():
    log_session(f"started argv={sys.argv!r} tag={session_tag()!r} BASE_DIR={BASE_DIR}")
    while True:
        msg = read_message()
        if msg is None:
            break

        method = msg.get("method", "")

        if method == "initialize":
            send_result(
                msg["id"],
                {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "allegro", "version": "1.0.0"},
                },
            )
        elif method == "notifications/initialized":
            pass
        elif method == "tools/list":
            send_result(msg["id"], {"tools": TOOLS})
        elif method == "tools/call":
            handle_call(msg)
        elif method == "ping":
            send_result(msg["id"], {})
        elif method == "resources/list":
            send_result(msg["id"], {"resources": []})
        elif method == "resources/templates/list":
            send_result(msg["id"], {"resourceTemplates": []})
        elif method == "prompts/list":
            send_result(msg["id"], {"prompts": []})
        elif "id" in msg:
            send_message(
                {
                    "jsonrpc": "2.0",
                    "id": msg["id"],
                    "error": {"code": -32601, "message": f"Unknown method: {method}"},
                }
            )


if __name__ == "__main__":
    main()
