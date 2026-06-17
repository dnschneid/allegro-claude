#!/usr/bin/env python3
# SPDX-FileCopyrightText: (C) 2026 Meta Platforms Inc.
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for the allegro MCP server's tool_use_id matching logic.

Run: python3 skill/test_allegro_mcp.py
"""

import json
import os
import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import allegro_mcp  # noqa: E402


class MatchIdByContentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="acl_mcp_"))
        self.name = "allegro_execute"
        self.args = {"code": "(plus 1 2)"}
        # Reset the floor so each test starts from a known baseline
        # (anything written after this is fair game).
        allegro_mcp._match_floor = time.time()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_req(self, tool_use_id, name=None, args=None, mtime=None):
        path = self.tmp / f"tool_{tool_use_id}.req"
        payload = {"name": name or self.name, "arguments": args or self.args}
        path.write_text(json.dumps(payload))
        if mtime is not None:
            os.utime(path, (mtime, mtime))
        return path

    def test_ignores_files_below_floor(self):
        # A .req from BEFORE the floor (a stale leftover from a prior
        # run) must never be matched.
        self.write_req("stale_id", mtime=allegro_mcp._match_floor - 10)

        def fresh_writer():
            time.sleep(0.05)
            self.write_req("fresh_id", mtime=allegro_mcp._match_floor + 1)

        import threading

        t = threading.Thread(target=fresh_writer)
        t.start()
        match = allegro_mcp.match_id_by_content(str(self.tmp), self.name, self.args)
        t.join()
        self.assertEqual(match, "fresh_id")

    def test_pairs_queued_calls_fifo(self):
        # Two queued calls with IDENTICAL content -- the matcher should
        # pair them in arrival order, not collapse to the same id.
        base = allegro_mcp._match_floor + 1
        self.write_req("first_id", mtime=base)
        self.write_req("second_id", mtime=base + 0.5)
        first = allegro_mcp.match_id_by_content(str(self.tmp), self.name, self.args)
        second = allegro_mcp.match_id_by_content(str(self.tmp), self.name, self.args)
        self.assertEqual(first, "first_id")
        self.assertEqual(second, "second_id")

    def test_long_running_first_does_not_break_second_match(self):
        # The scenario that motivated this: call 1 sits while user
        # approves it in manual mode and SKILL runs it for a long
        # time. Its .req is now far older than any wall-clock
        # threshold. Call 2 (queued behind it) must still match.
        base = allegro_mcp._match_floor + 1
        self.write_req("call1", mtime=base)
        self.write_req("call2", mtime=base + 0.5)
        first = allegro_mcp.match_id_by_content(str(self.tmp), self.name, self.args)
        self.assertEqual(first, "call1")
        # Roll call2's mtime back so it would look "stale" to any
        # absolute-age threshold, but is still above the floor (which
        # advanced to call1's mtime).
        os.utime(
            self.tmp / "tool_call2.req", (base + 0.5, base + 0.5)
        )  # no real change; just confirms older-than-now still works
        second = allegro_mcp.match_id_by_content(str(self.tmp), self.name, self.args)
        self.assertEqual(second, "call2")

    def test_ignores_non_matching_content(self):
        base = allegro_mcp._match_floor + 1
        self.write_req(
            "other_id", name="allegro_read_file", args={"path": "/x"}, mtime=base
        )
        self.write_req("mine_id", mtime=base + 0.5)
        match = allegro_mcp.match_id_by_content(str(self.tmp), self.name, self.args)
        self.assertEqual(match, "mine_id")


if __name__ == "__main__":
    unittest.main(verbosity=2)
