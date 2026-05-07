# SPDX-FileCopyrightText: (C) 2026 Meta Platforms Inc.
# SPDX-License-Identifier: Apache-2.0
"""Subprocess wrapper for `claude -p` with streaming-JSON watchdog + retry.

Used by the survey, slice, and semantic-check phases. Kills the process on
prolonged tool inactivity to bound the per-call wall clock.

Notes on isolation flags:
  --bare is unavailable in Meta's launcher, so isolation is built up by-flag:
    --append-system-prompt-file <file>   focused additional system prompt
    --strict-mcp-config --mcp-config '{}' skip all MCP servers
    --disable-slash-commands             skip skills
    --no-session-persistence             keep resume history clean
    --tools <whitelist>                  restrict built-in tools
  CLAUDE_PROJECT_DIR is set to the work tree so user project hooks don't fire.
  The claude binary is overridable via ACL_CACHE_BUILDER_CLAUDE for testing.
"""

from __future__ import annotations

import json
import logging
import os
import shlex
import signal
import subprocess
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

LOG = logging.getLogger(__name__)

DEFAULT_TOOLS = ["Bash", "Read", "Write", "Edit", "Glob", "Grep"]


@dataclass
class RunResult:
    rc: int
    last_assistant_text: str = ""
    tool_uses: int = 0
    duration_s: float = 0.0
    killed_for_inactivity: bool = False
    raw_log_path: Path | None = None
    cost_usd: float = 0.0


@dataclass
class Runner:
    model: str
    effort: str
    inactivity_timeout_s: int
    install_root: Path
    work_dir: Path
    extra_tools: list[str] = field(default_factory=list)
    # Optional per-slice-mode model overrides (e.g. {"reference": "sonnet"})
    mode_models: dict[str, str] = field(default_factory=dict)
    # Running totals across all run() calls. Threadsafe via lock.
    total_cost_usd: float = 0.0
    total_calls: int = 0
    _cost_lock: "threading.Lock" = field(default_factory=lambda: threading.Lock())

    def run(
        self,
        *,
        prompt: str,
        system_prompt: str,
        tag: str,
        extra_add_dirs: list[Path] | None = None,
        retries: int = 2,
        inactivity_timeout_s: int | None = None,
        model: str | None = None,
    ) -> RunResult:
        """Run a one-shot Claude call. Returns when the process exits."""
        timeout = (inactivity_timeout_s if inactivity_timeout_s is not None
                   else self.inactivity_timeout_s)
        eff_model = model if model is not None else self.model
        attempt = 0
        last: RunResult | None = None
        while attempt <= retries:
            attempt += 1
            LOG.info("[%s] claude attempt %d/%d", tag, attempt, retries + 1)
            res = self._run_once(
                prompt=prompt,
                system_prompt=system_prompt,
                tag=f"{tag}.try{attempt}",
                extra_add_dirs=extra_add_dirs or [],
                inactivity_timeout_s=timeout,
                model=eff_model,
            )
            last = res
            if res.rc == 0 and not res.killed_for_inactivity:
                return res
            LOG.warning("[%s] attempt %d failed (rc=%d, stalled=%s); retrying",
                        tag, attempt, res.rc, res.killed_for_inactivity)
        assert last is not None
        return last

    def _run_once(
        self,
        *,
        prompt: str,
        system_prompt: str,
        tag: str,
        extra_add_dirs: list[Path],
        inactivity_timeout_s: int,
        model: str,
    ) -> RunResult:
        log_dir = self.work_dir / "claude_logs"
        log_dir.mkdir(exist_ok=True)
        raw_log = log_dir / f"{tag}.raw.jsonl"

        # System prompt and MCP config are written to files. This avoids:
        #   (a) embedding multi-KB strings on the command line (E2BIG risk);
        #   (b) shell metachar issues with wrappers like the test daemon
        #       (which rejects $ and word-splits on whitespace).
        # The user prompt is delivered via stdin as a stream-json message.
        sys_file = log_dir / f"{tag}.system.txt"
        sys_file.write_text(system_prompt)
        mcp_file = self.work_dir / "empty_mcp_config.json"
        if not mcp_file.is_file():
            mcp_file.write_text('{"mcpServers": {}}')

        cmd = [
            os.environ.get("ACL_CACHE_BUILDER_CLAUDE", "claude"), "-p",
            "--no-session-persistence",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--append-system-prompt-file", str(sys_file),
            "--tools", ",".join(DEFAULT_TOOLS + list(self.extra_tools)),
            "--strict-mcp-config",
            "--mcp-config", str(mcp_file),
            "--disable-slash-commands",
            "--permission-mode", "bypassPermissions",
            "--add-dir", str(self.work_dir),
            "--add-dir", str(self.install_root),
            "--model", model,
            "--effort", self.effort,
        ]
        for d in extra_add_dirs:
            cmd += ["--add-dir", str(d)]

        env = os.environ.copy()
        # Suppress project-level hooks by pointing CLAUDE_PROJECT_DIR at work tree.
        env["CLAUDE_PROJECT_DIR"] = str(self.work_dir)
        # Strip LD_LIBRARY_PATH same as SKILL launcher (Allegro pollutes it).
        env.pop("LD_LIBRARY_PATH", None)

        # Prepare the stream-json input: a single user message wrapping `prompt`.
        # Per Claude Code stream-json input spec, each line is a JSON message.
        user_msg = {
            "type": "user",
            "message": {"role": "user",
                        "content": [{"type": "text", "text": prompt}]},
        }
        stdin_payload = (json.dumps(user_msg) + "\n").encode("utf-8")

        LOG.debug("[%s] cmd: %s", tag, " ".join(shlex.quote(c) for c in cmd))
        t0 = time.monotonic()
        proc = subprocess.Popen(
            cmd,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,  # unbuffered: we drain the pipe ourselves with os.read
        )
        assert proc.stdin and proc.stdout and proc.stderr

        result = RunResult(rc=-1, raw_log_path=raw_log)
        last_event_at = time.monotonic()
        lock = threading.Lock()

        def _bump():
            nonlocal last_event_at
            with lock:
                last_event_at = time.monotonic()

        def _consume_stdout():
            # Read raw bytes from the pipe and split on newlines ourselves.
            # Avoids Python text-iteration buffering, which can hold thousands
            # of events in the parent's buffer while the watchdog ticks.
            try:
                fd = proc.stdout.fileno()
                buf = b""
                with raw_log.open("wb") as logf:
                    while True:
                        try:
                            chunk = os.read(fd, 65536)
                        except OSError:
                            break
                        if not chunk:
                            break
                        logf.write(chunk)
                        logf.flush()
                        buf += chunk
                        while b"\n" in buf:
                            line, buf = buf.split(b"\n", 1)
                            line = line.strip()
                            if not line:
                                continue
                            try:
                                ev = json.loads(line)
                            except json.JSONDecodeError:
                                continue
                            _bump()
                            ev_type = ev.get("type")
                            if ev_type == "assistant":
                                msg = ev.get("message", {})
                                for block in msg.get("content", []):
                                    if block.get("type") == "text":
                                        result.last_assistant_text = block.get("text", "")
                                    elif block.get("type") == "tool_use":
                                        result.tool_uses += 1
                            elif ev_type == "result":
                                cost = ev.get("total_cost_usd") or 0.0
                                result.cost_usd = cost
            except Exception as e:
                LOG.debug("[%s] stdout consumer: %s", tag, e)

        def _consume_stderr():
            try:
                fd = proc.stderr.fileno()
                while True:
                    try:
                        chunk = os.read(fd, 4096)
                    except OSError:
                        break
                    if not chunk:
                        break
                    LOG.debug("[%s] stderr: %s", tag,
                              chunk.decode("utf-8", errors="replace").rstrip())
            except Exception:
                pass

        out_thread = threading.Thread(target=_consume_stdout, daemon=True)
        err_thread = threading.Thread(target=_consume_stderr, daemon=True)
        out_thread.start()
        err_thread.start()

        try:
            proc.stdin.write(stdin_payload)
            proc.stdin.close()
        except (BrokenPipeError, OSError):
            pass

        # Watchdog: poll every second; kill on inactivity.
        while True:
            rc = proc.poll()
            if rc is not None:
                break
            with lock:
                idle = time.monotonic() - last_event_at
            if idle > inactivity_timeout_s:
                LOG.warning("[%s] inactivity %.0fs; killing", tag, idle)
                result.killed_for_inactivity = True
                try:
                    proc.send_signal(signal.SIGTERM)
                    time.sleep(2)
                    if proc.poll() is None:
                        proc.kill()
                except OSError:
                    pass
                break
            time.sleep(1)

        try:
            rc = proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            rc = proc.wait()
        out_thread.join(timeout=5)
        err_thread.join(timeout=5)
        result.rc = rc
        result.duration_s = time.monotonic() - t0
        # Accumulate cost / call count + log periodically.
        with self._cost_lock:
            self.total_cost_usd += result.cost_usd
            self.total_calls += 1
            running_total = self.total_cost_usd
            running_calls = self.total_calls
        # Log every call's cost + a running total every 25 calls.
        cost_note = (f" cost=${result.cost_usd:.4f}"
                     if result.cost_usd else "")
        LOG.info("[%s] rc=%d duration=%.0fs tools=%d stalled=%s%s",
                 tag, rc, result.duration_s, result.tool_uses,
                 result.killed_for_inactivity, cost_note)
        if running_calls % 25 == 0:
            LOG.info("[runner] total cost so far: $%.2f over %d calls",
                     running_total, running_calls)
        return result
