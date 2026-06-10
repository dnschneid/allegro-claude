# SPDX-FileCopyrightText: (C) 2026 Meta Platforms Inc.
# SPDX-License-Identifier: Apache-2.0
"""Phase 6: reorder a merged cache by usefulness tier.

A merged cache is a sequence of `# <chapter>` blocks. The loader in the
host runtime can inline only a byte-bounded prefix of the file when the
active model has a small context window, so chapter order matters.

Goal: rank chapters so the most load-bearing content for an LLM driving
the host tool sits first. The loader truncates at chapter boundaries.

Tier signal sources (in priority order):

1. Per-group tiers emitted by the survey pass and threaded through the
   slice plan (`group["tier"]`). Preferred when present.
2. Content heuristics derived from the chapter body itself. Used for
   already-merged files that lack metadata, or as a fallback for groups
   the survey didn't tier.

The script never names a chapter, identifier prefix, or category. Tier
assignment is driven entirely by structural / syntactic shape of the
chunk's content.
"""

from __future__ import annotations

import argparse
import logging
import re
import sys
from pathlib import Path

LOG = logging.getLogger(__name__)

# A chapter starts at `# ` and runs until the next `# ` at start of
# line. The opening generator-header comment block (anything before the
# first `# `) is preserved verbatim at the top of the reordered file.
CHAPTER_HEAD_RE = re.compile(r"^# .*$", re.MULTILINE)

# A `### ` header whose first token is a bare identifier. The optional
# backticked tail is the signature block.
ENTRY_HEAD_RE = re.compile(
    r"^###\s+([A-Za-z_]\w*)(?:\s+(`[^`\n]*`))?\s*$", re.MULTILINE
)

# Function-call signature shape inside a backtick block.
SIG_FN_RE = re.compile(r"\([^)`]*\)\s*=>")

# Tier vocabulary. 1 = inline first; 4 = drop first.
TIERS = (1, 2, 3, 4)


def split_chapters(text: str) -> tuple[str, list[tuple[str, str]]]:
    """Split into (preamble, [(header_line, body), ...]).

    Preamble is everything before the first chapter header (typically
    the generator comment block). Body for each chapter is everything
    from its header line to the next chapter header.
    """
    matches = list(CHAPTER_HEAD_RE.finditer(text))
    if not matches:
        return text, []
    preamble = text[: matches[0].start()]
    chapters: list[tuple[str, str]] = []
    for i, m in enumerate(matches):
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        chunk = text[m.start() : end]
        # First line is the chapter header; rest is body.
        nl = chunk.find("\n")
        if nl < 0:
            chapters.append((chunk, ""))
        else:
            chapters.append((chunk[:nl], chunk[nl + 1 :]))
    return preamble, chapters


def classify_chapter(header: str, body: str) -> int:
    """Heuristic tier assignment for one chapter.

    Lower number = more load-bearing for an LLM that needs to produce
    correct code in the host tool. Decisions rely on:
      - density of identifier-shaped `### ` entries
      - fraction of those entries that carry a function-call signature
      - chapter byte size
      - presence of an `<!--omitted:` marker on the chapter header
        (only matters when the body is small -- a stub vs a chapter
        that lost a few entries to budget)
    """
    body_bytes = len(body.encode("utf-8"))
    omitted = "<!--omitted:" in header

    entries = list(ENTRY_HEAD_RE.finditer(body))
    total_h3 = sum(1 for _ in re.finditer(r"^###\s+", body, re.MULTILINE))
    ident_density = (len(entries) / total_h3) if total_h3 else 0.0

    sig_entries = sum(1 for m in entries if m.group(2) and SIG_FN_RE.search(m.group(2)))
    sig_density = (sig_entries / len(entries)) if entries else 0.0

    # Stub: a chapter with the omitted marker AND not much content
    # is mostly the "see source" notice; promote nothing.
    if omitted and body_bytes < 4096:
        return 4
    if body_bytes < 1500:
        return 4 if not entries else 3
    # Dense API-reference chapter -- the most load-bearing kind.
    if sig_density >= 0.3 and len(entries) >= 20:
        return 1
    # Identifier-keyed reference with weaker signatures (some entries
    # are bare names or non-callable identifiers like constants).
    if ident_density >= 0.7 and len(entries) >= 20:
        return 1
    if sig_density >= 0.15 or (ident_density >= 0.5 and len(entries) >= 10):
        return 2
    if ident_density < 0.3 and total_h3 >= 8:
        # Mostly sentence-headed: walkthrough prose / UI catalog.
        return 4
    return 3


def reorder(text: str, tier_overrides: dict[str, int] | None = None) -> str:
    """Return `text` with chapters reordered by tier.

    `tier_overrides` is an optional mapping from chapter-header text
    to a tier int 1-4. A key matches a chapter header if it equals the
    header line OR is a prefix of it -- this lets callers key by the
    base `# <dir>` even when a downstream pass has appended an
    `<!--omitted: ...-->` annotation to the header. Overrides take
    precedence over the content heuristic; a standalone reorder of an
    already-merged file passes nothing and falls through to it.
    """
    overrides = tier_overrides or {}

    def lookup(header: str) -> int | None:
        if header in overrides:
            return overrides[header]
        for key, val in overrides.items():
            if header.startswith(key + " ") or header == key:
                return val
        return None

    preamble, chapters = split_chapters(text)
    if not chapters:
        return text

    tiered: list[tuple[int, int, str, str]] = []
    for orig_idx, (header, body) in enumerate(chapters):
        tier = lookup(header) or classify_chapter(header, body)
        if tier not in TIERS:
            tier = 4
        tiered.append((tier, orig_idx, header, body))

    # Stable sort: by tier ascending, then by original index so chapters
    # within a tier keep their build-time relative order (which already
    # tends to group related material together).
    tiered.sort(key=lambda t: (t[0], t[1]))

    out: list[str] = []
    if preamble:
        out.append(preamble.rstrip("\n"))
        out.append("")
    for tier, _orig, header, body in tiered:
        out.append(header)
        out.append(body.rstrip("\n"))
        out.append("")
    return "\n".join(out).rstrip("\n") + "\n"


def reorder_file(
    path: Path,
    tier_overrides: dict[str, int] | None = None,
    *,
    in_place: bool = True,
    out_path: Path | None = None,
) -> Path:
    """Reorder one file. Returns the path written."""
    text = path.read_text(errors="replace")
    new_text = reorder(text, tier_overrides=tier_overrides)
    target = out_path if out_path is not None else path
    if not in_place and out_path is None:
        target = path.with_suffix(path.suffix + ".reordered")
    target.write_text(new_text)
    return target


def _cli(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description="Reorder a merged doc cache by usefulness tier. "
        "Operates in place by default."
    )
    p.add_argument(
        "paths", nargs="+", type=Path, help="Merged cache markdown files to reorder."
    )
    p.add_argument(
        "--out",
        type=Path,
        default=None,
        help="Write to this path instead of in place. Valid "
        "only with a single input.",
    )
    p.add_argument(
        "--dry-run", action="store_true", help="Report tier counts without writing."
    )
    p.add_argument("-v", "--verbose", action="count", default=0)
    args = p.parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(message)s",
    )

    if args.out and len(args.paths) > 1:
        sys.exit("error: --out requires exactly one input path")

    for path in args.paths:
        if not path.is_file():
            LOG.warning("skip: %s is not a file", path)
            continue
        text = path.read_text(errors="replace")
        preamble, chapters = split_chapters(text)
        counts: dict[int, int] = {}
        for header, body in chapters:
            t = classify_chapter(header, body)
            counts[t] = counts.get(t, 0) + 1
        size_before = len(text.encode("utf-8"))
        LOG.info(
            "%s: %d chapters; tiers %s; %d bytes",
            path.name,
            len(chapters),
            {t: counts.get(t, 0) for t in TIERS},
            size_before,
        )
        if args.dry_run:
            continue
        target = reorder_file(path, in_place=args.out is None, out_path=args.out)
        size_after = target.stat().st_size
        LOG.info(
            "wrote %s (%d bytes; delta %+d)",
            target,
            size_after,
            size_after - size_before,
        )
    return 0


if __name__ == "__main__":
    sys.exit(_cli())
