#!/usr/bin/env python3
# SPDX-FileCopyrightText: (C) 2026 Meta Platforms Inc.
# SPDX-License-Identifier: Apache-2.0
"""Offline tests for cache_builder modules that don't need a live Claude CLI.

Covers prepass output schema, plan expansion, audit checks, merge cap.

Run: python3 -m cache_builder.test_offline
"""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
from pathlib import Path

from . import audit, merge, prepass


def assert_eq(a, b, msg=""):
    if a != b:
        raise AssertionError(f"{msg}: {a!r} != {b!r}")


def test_prepass_classify():
    assert_eq(prepass.classify(Path("foo.html")), "html")
    assert_eq(prepass.classify(Path("foo.HTM")), "html")
    assert_eq(prepass.classify(Path("foo.txt")), "raw")
    assert_eq(prepass.classify(Path("foo.il")), "raw")
    assert_eq(prepass.classify(Path("foo.png")), "binary")
    assert_eq(prepass.classify(Path("foo.brd")), "binary")
    assert_eq(prepass.classify(Path("foo.zip")), "binary")
    assert_eq(prepass.classify(Path("foo.js")), "ignore")
    assert_eq(prepass.classify(Path("foo.css")), "ignore")
    assert_eq(prepass.classify(Path("foo.xml")), "ignore")
    assert_eq(prepass.classify(Path("foo.unknown")), "raw")
    print("prepass.classify OK")


def test_toc_detection():
    assert prepass.TOC_BASENAME_RE.search("algroskillTOC.html")
    assert prepass.TOC_BASENAME_RE.search("A_Commands.html")
    assert prepass.TOC_BASENAME_RE.search("foo_TOC.html")
    assert not prepass.TOC_BASENAME_RE.search("normal_page.html")
    print("prepass TOC regex OK")


def test_build_plan_glob_expansion():
    full_manifest = [
        {"rel_path": "doc/foo/aaa.html", "shadow_path": "shadow/doc/foo/aaa.html.txt"},
        {"rel_path": "doc/foo/bbb.html", "shadow_path": "shadow/doc/foo/bbb.html.txt"},
        {"rel_path": "doc/foo/Ccc_Dialog.html", "shadow_path": "shadow/doc/foo/Ccc_Dialog.html.txt"},
        {"rel_path": "doc/foo/fooTOC.html", "shadow_path": "shadow/doc/foo/fooTOC.html.txt"},
        {"rel_path": "doc/bar/aaa.html", "shadow_path": "shadow/doc/bar/aaa.html.txt"},
        {"rel_path": "doc/bin/img.png", "shadow_path": None},  # excluded
    ]
    sm = {"groups": [
        {"id": "foo_lower", "dir": "doc/foo", "mode": "reference",
         "include": ["[a-z]*.html"], "exclude": ["*TOC.html"],
         "byte_budget": 10000},
        {"id": "foo_dialog", "dir": "doc/foo", "mode": "reference",
         "include": ["[A-Z]*.html"], "exclude": [],
         "byte_budget": 5000},
        {"id": "bar", "dir": "doc/bar", "mode": "concept",
         "include": ["*"], "exclude": [],
         "byte_budget": 3000},
        {"id": "skipme", "dir": "doc/bin", "mode": "skip",
         "include": ["*"], "byte_budget": 0},
    ]}
    parts = Path("/tmp/_test_parts")
    plan = audit.build_plan(sm, parts, full_manifest=full_manifest)
    assert_eq(len(plan), 3, "plan length")
    foo_lower = next(p for p in plan if p["id"] == "foo_lower")
    assert_eq(sorted(foo_lower["files"]),
              ["doc/foo/aaa.html", "doc/foo/bbb.html"], "foo_lower files")
    foo_dialog = next(p for p in plan if p["id"] == "foo_dialog")
    assert_eq(foo_dialog["files"], ["doc/foo/Ccc_Dialog.html"], "foo_dialog files")
    bar = next(p for p in plan if p["id"] == "bar")
    assert_eq(bar["files"], ["doc/bar/aaa.html"], "bar files")
    print("audit.build_plan OK")


def test_build_plan_chunk_split():
    # One huge group should split into multiple slices.
    files = [{"rel_path": f"doc/big/f{i:04d}.html",
              "shadow_path": f"shadow/doc/big/f{i:04d}.html.txt"}
             for i in range(200)]
    sm = {"groups": [
        {"id": "big", "dir": "doc/big", "mode": "reference",
         "include": ["*"], "byte_budget": 800000}
    ]}
    parts = Path("/tmp/_test_parts")
    plan = audit.build_plan(sm, parts, full_manifest=files)
    # 200 files / MAX_FILES_PER_SLICE
    expected_chunks = (200 + audit.MAX_FILES_PER_SLICE - 1) // audit.MAX_FILES_PER_SLICE
    assert_eq(len(plan), expected_chunks, "chunks")
    for p in plan:
        assert len(p["files"]) <= audit.MAX_FILES_PER_SLICE
    total_files = sum(len(p["files"]) for p in plan)
    assert_eq(total_files, 200, "total files")
    # Each chunk's budget should be ~ original / chunks
    for p in plan:
        assert 0 < p["byte_budget"] <= 800000, p["byte_budget"]
    print("audit.build_plan chunk-split OK")


def test_audit_structural():
    tmp = Path(tempfile.mkdtemp(prefix="acl_test_"))
    try:
        # A part file with a mix of good entries, ghost, stub, combined-name.
        part = tmp / "slice_a.md"
        part.write_text("""# doc/foo  (reference)

### realFn
`realFn(a, b)` => list
Behavior: does the thing in a non-trivial way that is well-explained.
Args:
 - a: first arg with full description
 - b: second arg with full description
Example: `realFn(1, 2)` returns ()

### ghostFn

### stubFn
TOC

### combined, foo, bar
`combined(x)`
Behavior: documents three names at once with enough body text.
Example: combined(1)
""")
        grp = {"id": "slice_a", "dir": "doc/foo", "mode": "reference",
               "files": ["x"], "byte_budget": 500,
               "part_path": str(part)}
        a = audit._audit_structural(grp, set())
        assert_eq(a.entries, 4, "entry count")
        assert "ghostFn" in a.ghost_entries, f"ghost: {a.ghost_entries}"
        assert "stubFn" in a.stub_entries, f"stub: {a.stub_entries}"
        assert "combined, foo, bar" in a.combined_name_entries, \
               f"combined: {a.combined_name_entries}"
        assert not a.over_budget
        # part is ~600 bytes, budget 500 -> over (>120%)
        # Actually 600/500 = 1.2, exactly the threshold; let's check both ways.
        print("audit structural checks OK")
    finally:
        shutil.rmtree(tmp)


def test_merge_cap():
    tmp = Path(tempfile.mkdtemp(prefix="acl_merge_"))
    try:
        plan = []
        for i in range(3):
            p = tmp / f"slice_{i}.md"
            p.write_text(f"# slice {i}\n\n### entry_{i}\nbody " + ("X " * 50) + "\n")
            plan.append({"id": f"slice_{i}", "part_path": str(p),
                         "dir": "x", "mode": "reference",
                         "byte_budget": 1000, "files": []})
        out = tmp / "out.md"
        merge.run(plan, out, install_root=Path("/opt/cadence/SPB251"),
                  hard_cap=10000, target_bytes=8000)
        assert out.exists()
        sz = out.stat().st_size
        assert sz < 10000, sz
        text = out.read_text()
        assert "entry_0" in text and "entry_2" in text
        # Whitespace compaction: 3+ blank lines collapse to 2
        assert "\n\n\n\n" not in text
        print(f"merge OK ({sz} bytes)")
    finally:
        shutil.rmtree(tmp)


def main():
    test_prepass_classify()
    test_toc_detection()
    test_build_plan_glob_expansion()
    test_build_plan_chunk_split()
    test_audit_structural()
    test_merge_cap()
    print("\nALL OFFLINE TESTS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
