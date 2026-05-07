# SPDX-FileCopyrightText: (C) 2026 Meta Platforms Inc.
# SPDX-License-Identifier: Apache-2.0
"""Phase 1: walk install tree -> shadow text tree + manifest.json.

Produces under <work>:
  shadow/<install-relative-path>{.txt for HTML, raw for text}
  manifest.json -- list of {rel_path, ext, bytes, lines, shadow_path,
                            head_snippet, trivial_signals}

Resume-friendly: skips files whose shadow exists and is newer than the source.
"""

from __future__ import annotations

import json
import logging
import os
import re
import shutil
import subprocess
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path
from typing import Iterator

LOG = logging.getLogger(__name__)

# Walk these install-relative subtrees. Order matters only for log readability;
# the survey-pass groups by directory regardless.
WALK_ROOTS = ("doc", "share/pcb/examples", "share/pcb/text")

BINARY_EXTS = {".bmp", ".png", ".svg", ".gif", ".jpg", ".jpeg", ".ico",
               ".brd", ".dra", ".pad", ".psm", ".dsn", ".lib",
               ".zip", ".tar", ".gz", ".xlsx", ".xls", ".doc", ".docx",
               ".pdf", ".stp", ".step", ".dlt", ".bin", ".so", ".dll"}
HTML_EXTS = {".html", ".htm"}
# Things to copy raw because they're already plain text and useful as doc.
# Excludes formats that exist in the install but are not documentation (CSS,
# JS, XML, JSON, build artifacts).
RAW_EXTS = {".txt", ".il", ".form", ".men", ".r2c", ".tech", ".cmd", ".scr",
            ".dat", ".rules", ".prl", ".env", ".cpm", ".sigxp", ".fnd",
            ".attrs"}
# Anything with a recognized non-binary extension not in HTML/RAW gets ignored
# from the shadow tree -- still listed in manifest as "skipped".
IGNORE_EXTS = {".js", ".css", ".xml", ".json", ".tgf", ".log", ".lis", ".pl",
               ".py", ".sh", ".class", ".jar"}

HEAD_SNIPPET_BYTES = 600
MANIFEST_HEAD_BYTES = 200  # what we serialize into manifest.json
TINY_THRESHOLD = 300

# Lines where identifiers are likely sigs/declarations:
# - markdown-ish headings (`# foo`, `## foo`, `### foo`)
# - shadow lines that LOOK like text-converted Cadence sigs:
#     "**name** (...)"  or  "**name** `(...)`"  (Allegro-doc style)
#     "name(...)"        (lone sig in a code-ish block)
#     "Function: name"   "Syntax: name"  "Procedure: name"
#     "Command: name"
# We sample only first 200 lines per file for cheapness; sigs cluster early.
SIG_LINE_RE = re.compile(
    r"^\s*(?:"
    r"#{1,4}\s+(?P<head>[a-z][a-zA-Z0-9_]{3,})"            # markdown heading
    r"|\*\*(?P<bold>[a-z][a-zA-Z0-9_]{3,})\*\*"            # **name**
    r"|(?P<lone>[a-z][a-zA-Z0-9_]{3,})\s*\("                # name(
    r"|(?:Function|Syntax|Procedure|Command|Name)\s*:\s*"
        r"(?P<lab>[a-z][a-zA-Z0-9_]{3,})"                   # Label: name
    r")"
)
PREFIX_LEN = 3
MIN_PREFIX_IDS = 5     # fewer than this -> noise
SIG_LINES_PER_FILE = 200


def _extract_prefix_evidence(shadow_path: Path | None) -> dict:
    """Return {prefix: [identifier, ...]} for identifier-shaped sigs in file.

    Reads first SIG_LINES_PER_FILE lines, grabs tokens at signature positions
    (markdown headings, **bold**, lone-fn-call shape, labelled sigs). Cheap.
    """
    if shadow_path is None or not shadow_path.is_file():
        return {}
    out: dict[str, set[str]] = {}
    try:
        with shadow_path.open("r", errors="replace") as f:
            for i, line in enumerate(f):
                if i >= SIG_LINES_PER_FILE:
                    break
                m = SIG_LINE_RE.match(line)
                if not m:
                    continue
                ident = (m.group("head") or m.group("bold")
                         or m.group("lone") or m.group("lab"))
                if not ident or len(ident) < PREFIX_LEN + 1:
                    continue
                prefix = ident[:PREFIX_LEN].lower()
                # Skip prefixes that are obviously English (heuristic: all
                # lowercase first 3 letters that look word-like).
                if prefix in {"the", "and", "for", "you", "see", "use", "set",
                              "get", "add", "run", "new", "all", "any", "one",
                              "two", "max", "min", "out", "var", "fun", "let",
                              "but", "not", "this", "that", "with", "from",
                              "thi", "tha", "wit", "fro", "are", "was"}:
                    continue
                out.setdefault(prefix, set()).add(ident)
    except OSError:
        pass
    return {k: sorted(v) for k, v in out.items()}


HEAD_SNIPPET_BYTES_LEGACY_MARKER = 0  # (left for backward compat)

# Pure syntactic TOC signals used by the survey to filter aggressively.
# Cadence convention: <dirname>TOC.html, <letter>_Commands.html.
TOC_BASENAME_RE = re.compile(r"(_?TOC|_Commands)\.html?$", re.IGNORECASE)
TOC_META_RE = re.compile(
    rb'<meta\s+(?:name|type)=["\']?(?:type|FileType)["\']?\s+content=["\']?TOC',
    re.IGNORECASE,
)
TOC_FILETYPE_RE = re.compile(rb'FileType=["\']?TOC["\']?', re.IGNORECASE)


def classify(rel_path: Path) -> str:
    """Return one of: 'html', 'raw', 'binary', 'ignore'."""
    ext = rel_path.suffix.lower()
    if ext in HTML_EXTS:
        return "html"
    if ext in BINARY_EXTS:
        return "binary"
    if ext in RAW_EXTS:
        return "raw"
    if ext in IGNORE_EXTS:
        return "ignore"
    # Unknown extension: assume text/raw. Survey looks at head_snippet to
    # decide whether the file is genuinely useful.
    return "raw"


def walk_install(install_root: Path) -> Iterator[Path]:
    for root_rel in WALK_ROOTS:
        root = install_root / root_rel
        if not root.is_dir():
            LOG.warning("walk: %s does not exist; skipping", root)
            continue
        for dirpath, _dirnames, filenames in os.walk(root):
            for name in filenames:
                yield Path(dirpath) / name


def _peek_bytes(path: Path, n: int) -> bytes:
    try:
        with path.open("rb") as f:
            return f.read(n)
    except OSError:
        return b""


def _detect_toc(rel_path: Path, head_bytes: bytes) -> bool:
    if TOC_BASENAME_RE.search(rel_path.name):
        return True
    if TOC_META_RE.search(head_bytes):
        return True
    if TOC_FILETYPE_RE.search(head_bytes):
        return True
    return False


def _process_one(args: tuple) -> dict | None:
    """Worker: produce shadow file + manifest entry for one source file."""
    install_root_str, rel_path_str, work_dir_str = args
    install_root = Path(install_root_str)
    rel_path = Path(rel_path_str)
    work_dir = Path(work_dir_str)
    src = install_root / rel_path
    try:
        st = src.stat()
    except OSError:
        return None

    kind = classify(rel_path)
    shadow_path = None

    if kind in ("binary", "ignore"):
        # Skipped from shadow; recorded in manifest.
        head_bytes = b""
    elif kind == "html":
        shadow_rel = rel_path.with_suffix(rel_path.suffix + ".txt")
        shadow_path = work_dir / "shadow" / shadow_rel
        shadow_path.parent.mkdir(parents=True, exist_ok=True)
        if not (shadow_path.exists() and shadow_path.stat().st_mtime >= st.st_mtime):
            try:
                # html2text writes to stdout. CP1252 matches Cadence HTML encoding.
                result = subprocess.run(
                    ["html2text", str(src), "CP1252"],
                    capture_output=True, timeout=60,
                )
                # html2text exits non-zero on some warnings but still emits text.
                shadow_path.write_bytes(result.stdout)
            except (OSError, subprocess.TimeoutExpired) as e:
                LOG.warning("html2text failed for %s: %s", rel_path, e)
                shadow_path = None
        head_bytes = _peek_bytes(src, HEAD_SNIPPET_BYTES)
    else:  # raw
        shadow_path = work_dir / "shadow" / rel_path
        shadow_path.parent.mkdir(parents=True, exist_ok=True)
        if not (shadow_path.exists() and shadow_path.stat().st_mtime >= st.st_mtime):
            try:
                shutil.copy2(src, shadow_path)
            except OSError as e:
                LOG.warning("copy failed for %s: %s", rel_path, e)
                shadow_path = None
        head_bytes = _peek_bytes(src, HEAD_SNIPPET_BYTES)

    head_snippet = head_bytes.decode("cp1252", errors="replace") if head_bytes else ""

    line_count = 0
    if shadow_path and shadow_path.is_file():
        try:
            with shadow_path.open("rb") as f:
                line_count = sum(1 for _ in f)
        except OSError:
            pass

    trivial_signals = []
    if kind == "html" and _detect_toc(rel_path, head_bytes):
        trivial_signals.append("is_html_toc")
    if st.st_size < TINY_THRESHOLD:
        trivial_signals.append("tiny")
    if kind == "binary":
        trivial_signals.append("binary")
    elif kind == "ignore":
        trivial_signals.append("ignored_ext")

    return {
        "rel_path": str(rel_path),
        "ext": rel_path.suffix.lower(),
        "bytes": st.st_size,
        "lines": line_count,
        "shadow_path": (str(shadow_path.relative_to(work_dir))
                        if shadow_path else None),
        "head_snippet": head_snippet[:MANIFEST_HEAD_BYTES],
        "trivial_signals": trivial_signals,
        # Identifier prefix evidence: {prefix: [ident, ...]} for tokens
        # appearing at signature positions in the shadow file. Survey uses
        # this to detect categorical API surfaces (axl*, cmxl*, dbi*, ...)
        # and ensure each gets a reference-mode group.
        "prefixes": _extract_prefix_evidence(shadow_path),
    }


def run(install_root: Path, work_dir: Path, max_workers: int = 6) -> Path:
    """Build shadow tree + manifest.json. Return path to manifest."""
    shadow_root = work_dir / "shadow"
    shadow_root.mkdir(parents=True, exist_ok=True)

    if shutil.which("html2text") is None:
        raise SystemExit("error: html2text not on PATH; install it first")

    rel_paths = []
    for src in walk_install(install_root):
        try:
            rel_paths.append(src.relative_to(install_root))
        except ValueError:
            continue

    LOG.info("pre-pass: %d source files", len(rel_paths))

    work_args = [(str(install_root), str(rp), str(work_dir)) for rp in rel_paths]
    entries = []
    with ProcessPoolExecutor(max_workers=max_workers) as pool:
        for i, fut in enumerate(as_completed(
                pool.submit(_process_one, a) for a in work_args), 1):
            entry = fut.result()
            if entry is not None:
                entries.append(entry)
            if i % 500 == 0:
                LOG.info("pre-pass: %d/%d", i, len(work_args))

    entries.sort(key=lambda e: e["rel_path"])
    manifest = work_dir / "manifest.json"
    manifest.write_text(json.dumps(entries, indent=1))
    LOG.info("pre-pass: wrote %s (%d entries)", manifest, len(entries))

    # Build prefix index: which dirs cover each significant prefix.
    # A prefix is "significant" if ≥MIN_PREFIX_IDS distinct identifiers
    # share it across ≥2 files. The survey uses this to ensure every
    # significant prefix has a reference-mode group.
    prefix_index_path = build_prefix_index(entries, work_dir)
    LOG.info("pre-pass: wrote prefix index %s", prefix_index_path)
    return manifest


def build_prefix_index(entries: list[dict], work_dir: Path) -> Path:
    """Aggregate per-file prefix evidence into a dir-x-prefix matrix.

    Output schema (prefix_index.json):
      {
        "prefixes": {
          "<prefix>": {
            "ids": ["<ident>", ...],          # all distinct identifiers
            "id_count": N,
            "file_count": M,                  # files where it appears
            "dirs": {"<dir>": {"ids": [...], "files": [...]}}
          }
        },
        "summary": {"prefix_count": K, "significant_count": K2}
      }
    Only "significant" prefixes are included (>=MIN_PREFIX_IDS distinct ids
    across >=2 files).
    """
    by_prefix: dict[str, dict] = defaultdict(
        lambda: {"ids": set(), "file_count": 0, "files": set(),
                 "dirs": defaultdict(lambda: {"ids": set(), "files": set()})})
    for e in entries:
        prefixes = e.get("prefixes", {})
        if not prefixes:
            continue
        rel = e["rel_path"]
        d = str(Path(rel).parent)
        for prefix, idents in prefixes.items():
            if not idents:
                continue
            bucket = by_prefix[prefix]
            bucket["ids"].update(idents)
            bucket["files"].add(rel)
            bucket["dirs"][d]["ids"].update(idents)
            bucket["dirs"][d]["files"].add(rel)

    out_prefixes: dict[str, dict] = {}
    significant = 0
    for prefix, bucket in by_prefix.items():
        if len(bucket["ids"]) < MIN_PREFIX_IDS or len(bucket["files"]) < 2:
            continue
        significant += 1
        out_prefixes[prefix] = {
            "ids": sorted(bucket["ids"]),
            "id_count": len(bucket["ids"]),
            "file_count": len(bucket["files"]),
            "dirs": {
                d: {"ids": sorted(v["ids"]), "files": sorted(v["files"])}
                for d, v in bucket["dirs"].items()
            },
        }

    out = {
        "prefixes": out_prefixes,
        "summary": {
            "prefix_count": len(by_prefix),
            "significant_count": significant,
        },
    }
    path = work_dir / "prefix_index.json"
    path.write_text(json.dumps(out, indent=1))
    LOG.info("pre-pass: %d significant prefixes (of %d total)",
             significant, len(by_prefix))
    return path
