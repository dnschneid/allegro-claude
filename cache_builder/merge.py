# SPDX-FileCopyrightText: (C) 2026 Meta Platforms Inc.
# SPDX-License-Identifier: Apache-2.0
"""Phase 5: concatenate part files -> final cache, with safe whitespace
compaction and tiered content compaction when oversize.

The tiered compactor (opt-in via `--allow-compaction`) drops verbose entry
content when the merged file exceeds the target. It keeps every `### name`
and `## Title` header so search-ability is preserved, but trims bodies in
passes:
  Pass 1: bodies capped to 6 lines (sig + behavior + 2 detail lines).
  Pass 2: bodies capped to 3 lines (sig + 1-line behavior).
  Pass 3: bodies capped to 1 line (sig only).
Concept sections trim prose paragraphs first; bullet/code blocks last.
"""

from __future__ import annotations

import datetime as dt
import logging
import re
from pathlib import Path

LOG = logging.getLogger(__name__)

BLANK_RUN_RE = re.compile(r"\n{3,}")
TRAILING_WS_RE = re.compile(r"[ \t]+\n")
# Match the leading identifier on a `### ` header so we can dedup near-duplicate
# entries within the same chapter. We treat as a "single-identifier" header any
# header whose content starts `<ident>` followed by either nothing, a backtick
# (signature), or whitespace+backtick. Multi-token titles like `### pop bbvia`
# are NOT matched -- they document distinct things.
ENTRY_IDENT_RE = re.compile(r"^([A-Za-z_]\w*)\s*(?:`|$)")
BACKTICK_BLOCK_RE = re.compile(r"`[^`]+`")
# Distinguish SKILL/Tcl function-call syntax (`fn(args) => type` or just
# `(args) => type` without the name re-stated) from Allegro command-interpreter
# syntax (`cmd <arg1> <arg2>`). Same identifier in both can document genuinely
# different things -- e.g. `print` exists as a SKILL fn AND an Allegro command
# -- so dedup must not collapse across that line.
SIG_FN_RE = re.compile(r"`(?:[A-Za-z_]\w*)?\s*\([^)`]*\)\s*=>")
SIG_CMD_RE = re.compile(r"`(?:[A-Za-z_][\w-]*\s+)?<")
# Pull the parenthesized argument list out of a function-shape signature so
# we can compare first-arg names across same-name entries. Two entries with
# zero-overlap leading args document distinct functions and must not be
# collapsed even when both are "fn" shape (e.g. `print(-printer ...)` Tcl
# command vs `print(g_value)` SKILL builtin). Slice agents emit both
# `name(args)` and bare `(args)` forms; accept either.
SIG_ARGS_RE = re.compile(r"`(?:[A-Za-z_]\w*)?\s*\(([^)`]*)\)")
ARG_NAME_RE = re.compile(r"-?([a-z_][\w]*)")
# Signal that an entry is "subtle" and should keep more body.
SUBTLE_RE = re.compile(
    r"\b(warning|deprecated|obsolete|important|side effect|caveat|"
    r"gotcha|note|crash|error|fail|undefined|race)\b",
    re.IGNORECASE)


def _compact(text: str) -> str:
    text = TRAILING_WS_RE.sub("\n", text)
    text = BLANK_RUN_RE.sub("\n\n", text)
    return text


def _split_into_blocks(text: str) -> list[tuple[str, str, str]]:
    """Return [(kind, header, body)] where kind in {'chapter','section','entry','prose'}.

    Header includes the marker (e.g. '### foo'). Body is everything until the
    next header at any level. The first 'prose' block is everything before any
    header.
    """
    lines = text.split("\n")
    blocks: list[tuple[str, str, str]] = []
    cur_kind = "prose"
    cur_header = ""
    cur_body: list[str] = []

    def flush():
        if cur_body or cur_header:
            blocks.append((cur_kind, cur_header, "\n".join(cur_body)))

    for line in lines:
        if line.startswith("### "):
            flush()
            cur_kind = "entry"
            cur_header = line
            cur_body = []
        elif line.startswith("## "):
            flush()
            cur_kind = "section"
            cur_header = line
            cur_body = []
        elif line.startswith("# "):
            flush()
            cur_kind = "chapter"
            cur_header = line
            cur_body = []
        else:
            cur_body.append(line)
    flush()
    return blocks


def _drop_empty_entries_and_dedup(text: str,
                                   known_idents: set[str] | None = None
                                   ) -> str:
    """Drop `### name` entries whose header has no inline body and no body
    content before the next header, dedup truly redundant identifier-headed
    entries, and collapse duplicate chapter headings that arise from slices
    sharing a source directory.

    Slice agents occasionally emit a bare `### name` header without ever
    filling it; we drop those first so the dedup pass only sees rich
    candidates. Dedup is intentionally conservative: it collapses a cluster
    of same-name entries only when (a) every candidate is trivial (sig-only
    or empty), or (b) every candidate has a function-shape signature with
    overlapping leading-arg names (true SKILL fn dups), or (c) prose bodies
    share more than half their distinct tokens (mostly redundant
    rephrasings). Otherwise candidates are preserved as distinct entries --
    e.g. `groupedit` documenting the Options Panel and `groupedit`
    explaining the verb-then-noun mode are kept apart, since they describe
    genuinely different aspects of the same command.

    When dedup does fire and the keeper's header lacks a backtick-wrapped
    signature, a sig is rescued from a dropped sibling so the call shape
    isn't lost.

    `known_idents`, when provided, is the set of identifiers prepass
    extracted from source -- i.e. things that are definitely SKILL functions
    (or named API entities) in this install. Same-name entries for those
    are eligible for cross-chapter dedup when their signature shape matches;
    mixed shape (SKILL fn `name(args) => type` vs Allegro command
    `name <arg>`) is preserved -- e.g. `print` exists as both a SKILL
    builtin and an Allegro command and the two document genuinely different
    things.

    Headers whose ident is NOT in known_idents only dedup within a single
    chapter and matching shape, since names like `set`/`do`/`if`/`group`
    legitimately document different things across SKILL, the Allegro command
    interpreter, and various subcommand languages.
    """
    known_idents = known_idents or set()

    def sig_shape(item: dict) -> str:
        """Classify the entry as 'fn' (parens-arrow function call), 'cmd'
        (angle-bracket command syntax), or 'unknown'. Inspects the header
        line and the first few lines of the body, since slice agents
        sometimes put the signature on the line after the header."""
        sample = item["header"] + "\n" + "\n".join(
            item["body"].split("\n", 3)[:3])
        if SIG_FN_RE.search(sample):
            return "fn"
        if SIG_CMD_RE.search(sample):
            return "cmd"
        return "unknown"

    def first_args(item: dict) -> set[str]:
        """Return up to 3 leading arg names from the entry's signature.
        Used to verify two same-name entries are documenting the same call:
        two entries with no arg-name overlap are different functions that
        happen to share a spelling."""
        sample = item["header"] + "\n" + "\n".join(
            item["body"].split("\n", 3)[:3])
        m = SIG_ARGS_RE.search(sample)
        if not m:
            return set()
        names: list[str] = []
        for tok in re.split(r"[\s,]+", m.group(1)):
            tok = tok.lstrip("[").rstrip("]")
            am = ARG_NAME_RE.match(tok)
            if am:
                names.append(am.group(1))
            if len(names) >= 3:
                break
        return set(names)

    def is_trivial(item: dict) -> bool:
        """Body has no meaningful prose -- just a signature, micro-headers,
        or empty. Trivial entries can be deduped without losing information.
        """
        body = re.sub(r"`[^`]+`", "", item["body"])
        body = re.sub(r"\b(Args?|Returns?|Behavior|Example|Usage|API|Use|"
                      r"Pitfall|State|Gotcha):\s*", "", body)
        words = re.findall(r"\b[a-zA-Z]\w+\b", body)
        return len(words) <= 8

    def body_tokens(item: dict) -> set[str]:
        """Distinct prose tokens in the body, excluding code/sig backtick
        blocks and short stopwords-ish tokens. Used to detect when two
        entries are saying substantially the same thing."""
        body = re.sub(r"`[^`]+`", "", item["body"])
        return set(w.lower() for w in re.findall(r"\b[a-z][a-z]{2,}\b",
                                                  body.lower()))

    def can_dedup(cands: list[dict]) -> bool:
        """Decide whether a cluster of same-name entries is safe to collapse.
        Conservative: only fold when the choice is genuinely informationless,
        either because every candidate is trivial (sig-only), every candidate
        has a function-shape signature with overlapping arg names (true SKILL
        fn dups), or the prose bodies share more than half their distinct
        tokens (essentially redundant rephrasings).
        """
        if all(is_trivial(c) for c in cands):
            return True
        full = [c["header"] + "\n" + c["body"] for c in cands]
        if all(SIG_FN_RE.search(t) for t in full):
            args_sets = [first_args(c) for c in cands]
            if all(args_sets):
                if set.intersection(*args_sets):
                    return True
        token_sets = [body_tokens(c) for c in cands]
        if all(token_sets):
            union = set.union(*token_sets)
            inter = set.intersection(*token_sets)
            if union and len(inter) / len(union) >= 0.5:
                return True
        return False
    # Parse into (kind, header, body, chapter) tuples in source order.
    # kind in {chapter, section, entry, prose}.
    lines = text.split("\n")
    items: list[dict] = []
    cur_chapter = ""
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("# ") and not line.startswith(("## ", "### ")):
            cur_chapter = line[2:].strip()
            items.append({"kind": "chapter", "header": line, "body": "",
                          "chapter": cur_chapter, "ident": None})
            i += 1
            continue
        if line.startswith("## ") and not line.startswith("### "):
            j = i + 1
            body_lines: list[str] = []
            while j < len(lines) and not lines[j].startswith(
                    ("### ", "## ", "# ")):
                body_lines.append(lines[j])
                j += 1
            items.append({
                "kind": "section",
                "header": line,
                "body": "\n".join(body_lines).rstrip(),
                "chapter": cur_chapter,
                "ident": None,
            })
            i = j
            continue
        if line.startswith("### "):
            header = line
            j = i + 1
            body_lines = []
            while j < len(lines) and not lines[j].startswith(
                    ("### ", "## ", "# ")):
                body_lines.append(lines[j])
                j += 1
            body = "\n".join(body_lines).rstrip()
            ident = None
            rest = header[4:].lstrip()
            m = ENTRY_IDENT_RE.match(rest)
            if m:
                ident = m.group(1)
            items.append({
                "kind": "entry",
                "header": header,
                "body": body,
                "chapter": cur_chapter,
                "ident": ident,
            })
            i = j
            continue
        items.append({"kind": "prose", "header": "", "body": line,
                      "chapter": cur_chapter, "ident": None})
        i += 1

    drop: set[int] = set()

    # First pass: drop entries whose header has no inline content past the
    # ident AND body is blank. Catches the bare-header bug. Doing this before
    # dedup means a cluster of one rich + several bare-empty entries reduces
    # to a single rich entry without dedup ever firing -- which preserves
    # information when the rich entry's body is non-trivial prose.
    for idx, item in enumerate(items):
        if item["kind"] != "entry" or item["ident"] is None:
            continue
        rest = item["header"][4:].lstrip()
        rest_after_ident = rest[len(item["ident"]):].strip()
        if not rest_after_ident and not item["body"].strip():
            drop.add(idx)

    # Group surviving entries for dedup decisions. We collect ALL same-name
    # candidates globally first, then split them by signature shape (fn vs
    # cmd) and, for function-shape entries, by leading-arg-name overlap.
    # An identifier present in both languages -- e.g. `print` as a SKILL fn
    # AND an Allegro command -- doesn't collapse across the boundary; even
    # within "fn" shape, sigs with disjoint leading args are kept separate.
    # For identifiers prepass extracted as known SKILL names, we allow
    # cross-chapter dedup within the same shape+arg cluster; for unknown
    # identifiers we keep the conservative within-chapter scope.
    by_key: dict[object, list[int]] = {}
    for idx, item in enumerate(items):
        if idx in drop:
            continue
        if item["kind"] != "entry" or item["ident"] is None:
            continue
        sh = sig_shape(item)
        if item["ident"] in known_idents:
            scope: tuple = ("global", item["ident"])
        else:
            scope = ("chapter", item["chapter"], item["ident"])
        if sh == "fn":
            args = first_args(item)
            attached = False
            for key in list(by_key.keys()):
                if key[:len(scope)] != scope:
                    continue
                if len(key) <= len(scope) or key[len(scope)] != "fn":
                    continue
                cluster_args = key[len(scope) + 1]
                if args and cluster_args and (args & cluster_args):
                    by_key[key].append(idx)
                    attached = True
                    break
            if not attached:
                by_key[scope + ("fn", frozenset(args))] = [idx]
        else:
            key = scope + (sh,)
            by_key.setdefault(key, []).append(idx)

    for key, idx_list in by_key.items():
        if len(idx_list) <= 1:
            continue
        cands = [items[i] for i in idx_list]
        if not can_dedup(cands):
            continue
        keep_idx = max(
            idx_list,
            key=lambda i: len(items[i]["header"]) + len(items[i]["body"]))
        keeper = items[keep_idx]
        if "`" not in keeper["header"]:
            for i in idx_list:
                if i == keep_idx:
                    continue
                sig_match = BACKTICK_BLOCK_RE.search(items[i]["header"])
                if sig_match:
                    ident = keeper["ident"]
                    rest = keeper["header"][4:].lstrip()
                    new_h = f"### {ident} {sig_match.group(0)}"
                    rest_after_ident = rest[len(ident):].lstrip()
                    if rest_after_ident:
                        new_h += " " + rest_after_ident
                    keeper["header"] = new_h
                    break
        for i in idx_list:
            if i != keep_idx:
                drop.add(i)

    # Collapse duplicate chapter headings: keep only the first occurrence of
    # each chapter name; later duplicates become invisible (their entries
    # still appear in source order).
    seen_chapters: set[str] = set()
    for idx, item in enumerate(items):
        if item["kind"] == "chapter":
            if item["chapter"] in seen_chapters:
                drop.add(idx)
            else:
                seen_chapters.add(item["chapter"])

    out_lines: list[str] = []
    for idx, item in enumerate(items):
        if idx in drop:
            continue
        kind = item["kind"]
        if kind == "prose":
            out_lines.append(item["body"])
        elif kind == "chapter":
            out_lines.append(item["header"])
        elif kind in ("section", "entry"):
            out_lines.append(item["header"])
            if item["body"]:
                out_lines.append(item["body"])
                out_lines.append("")
    return "\n".join(out_lines)


def _annotate_gap_markers(text: str,
                           gap_count_by_chapter: dict[str, int],
                           gap_sample_by_chapter: dict[str, list[str]],
                           ) -> str:
    """Append a self-explanatory `<!--omitted: N (e.g. a, b, c)-->` marker
    to each chapter heading whose slice(s) finished iteration with
    unresolved gaps. Including up to 3 sample identifiers gives the reader
    enough signal to judge whether the gap matters for their work without
    blowing up the marker. Readers can `grep '<!--omitted'` to find
    untrusted sections.
    """
    if not gap_count_by_chapter:
        return text
    lines = text.split("\n")
    out: list[str] = []
    for line in lines:
        if line.startswith("# ") and not line.startswith(("## ", "### ")):
            chap = line[2:].strip()
            n = gap_count_by_chapter.get(chap, 0)
            if n > 0:
                noun = "identifier" if n == 1 else "identifiers"
                samples = gap_sample_by_chapter.get(chap, [])[:3]
                # Stable, deterministic sample so re-merges produce the same
                # marker text -- order comes from the audit_report's per-slice
                # ordering, which itself reflects source-order from prepass.
                if samples:
                    sample_str = ", ".join(samples)
                    out.append(f"{line} <!--omitted: {n} {noun}; "
                               f"e.g. {sample_str}-->")
                else:
                    out.append(f"{line} <!--omitted: {n} {noun}-->")
                continue
        out.append(line)
    return "\n".join(out)


def _strip_orphan_micro_headers(body: str) -> str:
    """Drop lines that are just 'Example:', 'Behavior:', etc with no content
    on the same line and no following content."""
    lines = body.split("\n")
    out: list[str] = []
    i = 0
    micro_re = re.compile(
        r"^(Behavior|Example|Args?|Returns?|Gotcha|Use|State|Pitfall|API)\s*:\s*$",
        re.IGNORECASE)
    while i < len(lines):
        line = lines[i]
        if micro_re.match(line.strip()):
            # Look ahead for content
            j = i + 1
            while j < len(lines) and not lines[j].strip():
                j += 1
            if j >= len(lines) or lines[j].lstrip().startswith(("###", "##", "#")):
                # Orphan
                i = j
                continue
        out.append(line)
        i += 1
    return "\n".join(out)


def _strip_dead_section_headers(text: str) -> str:
    """Remove ## section headers whose body is empty AND has no ### children."""
    blocks = _split_into_blocks(text)
    out: list[tuple[str, str, str]] = []
    i = 0
    while i < len(blocks):
        kind, header, body = blocks[i]
        if kind == "section":
            # Look ahead: does this section have any non-empty body OR any
            # ### entries before the next ## or # ?
            has_content = bool(body.strip())
            j = i + 1
            while j < len(blocks):
                nk, _, nb = blocks[j]
                if nk in ("section", "chapter"):
                    break
                if nk == "entry":
                    has_content = True
                    break
                if nk == "prose" and nb.strip():
                    has_content = True
                    break
                j += 1
            if not has_content:
                i += 1
                continue
        out.append((kind, header, body))
        i += 1
    # Reassemble.
    result_parts = []
    for kind, header, body in out:
        if kind in ("entry", "section", "chapter"):
            result_parts.append(header + ("\n" + body if body.strip() else ""))
        elif body.strip():
            result_parts.append(body)
    return "\n\n".join(result_parts)


def _trim_entry_body(body: str, max_lines: int, subtle: bool,
                     max_line_chars: int = 200) -> str:
    """Trim an entry body to ~max_lines (subtle entries get +3).

    Lines longer than max_line_chars are DROPPED rather than ellipsis-truncated
    -- a half-line ending in '...' looks like garbage and confuses readers.
    """
    out = []
    cap = max_lines + (3 if subtle else 0)
    for raw in body.split("\n"):
        if not raw.strip():
            continue
        if len(raw) > max_line_chars:
            continue  # drop oversized lines entirely
        out.append(raw)
        if len(out) >= cap:
            break
    return "\n".join(out).strip()


def _trim_section_body(body: str, max_paragraphs: int,
                       max_sentences_per_para: int,
                       drop_code: bool = False,
                       drop_bullets: bool = False) -> str:
    """Trim a section body: keep code/bullets fully; trim prose paragraphs.

    With drop_code/drop_bullets, those structural blocks are also removed.
    """
    out_paragraphs: list[str] = []
    cur: list[str] = []
    in_code = False
    prose_kept = 0

    def flush_para():
        nonlocal prose_kept
        if not cur:
            return
        text = "\n".join(cur).strip()
        if not text:
            cur.clear()
            return
        first = text.lstrip()
        is_code = first.startswith("```") or text.lstrip().startswith(("    ", "\t"))
        is_bullet = first.startswith(("- ", "* ", "1.", "2.", "3."))
        is_structural = is_code or is_bullet or first.startswith("`")
        if is_structural:
            if (drop_code and is_code) or (drop_bullets and is_bullet):
                cur.clear()
                return
            out_paragraphs.append(text)
        else:
            if prose_kept < max_paragraphs:
                sentences = re.split(r"(?<=[.!?])\s+", text)
                kept = " ".join(sentences[:max_sentences_per_para]).strip()
                if kept:
                    out_paragraphs.append(kept)
                    prose_kept += 1
        cur.clear()

    for line in body.split("\n"):
        if line.startswith("```"):
            in_code = not in_code
            cur.append(line)
            continue
        if in_code:
            cur.append(line)
            continue
        if not line.strip():
            flush_para()
        else:
            cur.append(line)
    flush_para()
    return "\n\n".join(out_paragraphs)


def _apply_tiered_compaction(text: str, target_bytes: int,
                             hard_cap: int) -> str:
    """Iteratively trim until under target_bytes or all tiers exhausted.

    Stops as soon as size <= target_bytes. If a tier crosses below hard_cap
    but is still above target, we keep that result if the next tier would
    drop more than 30% of bytes (likely losing important content like entry
    bodies). This avoids going from a useful 1.7 MB to a near-empty 0.6 MB
    just to chase a soft target.
    """
    tiers = [
        # gentle prose trim
        dict(entry_lines=8, sec_paras=5, sec_sents=3,
             drop_code=False, drop_bullets=False, drop_entries=False),
        dict(entry_lines=6, sec_paras=4, sec_sents=2,
             drop_code=False, drop_bullets=False, drop_entries=False),
        dict(entry_lines=4, sec_paras=3, sec_sents=2,
             drop_code=False, drop_bullets=False, drop_entries=False),
        dict(entry_lines=3, sec_paras=2, sec_sents=2,
             drop_code=False, drop_bullets=False, drop_entries=False),
        dict(entry_lines=2, sec_paras=1, sec_sents=2,
             drop_code=False, drop_bullets=False, drop_entries=False),
        # drop code/bullets in concept sections
        dict(entry_lines=2, sec_paras=1, sec_sents=1,
             drop_code=True, drop_bullets=False, drop_entries=False),
        # drop bullets too
        dict(entry_lines=2, sec_paras=1, sec_sents=1,
             drop_code=True, drop_bullets=True, drop_entries=False),
        dict(entry_lines=1, sec_paras=1, sec_sents=1,
             drop_code=True, drop_bullets=True, drop_entries=False),
        # entries keep sigs; section headers preserved but bodies emptied
        dict(entry_lines=1, sec_paras=0, sec_sents=0,
             drop_code=True, drop_bullets=True, drop_entries=False),
        # ultra: entries become headers only, sections too
        dict(entry_lines=0, sec_paras=0, sec_sents=0,
             drop_code=True, drop_bullets=True, drop_entries=True),
    ]
    blocks = _split_into_blocks(text)
    candidate = text
    prev_size = len(text.encode("utf-8"))
    for t in tiers:
        out: list[str] = []
        for kind, header, body in blocks:
            if kind == "entry":
                if t["drop_entries"]:
                    out.append(header)
                else:
                    subtle = bool(SUBTLE_RE.search(body))
                    trimmed = _trim_entry_body(body, t["entry_lines"], subtle)
                    out.append(header + ("\n" + trimmed if trimmed else ""))
            elif kind == "section":
                trimmed = _trim_section_body(
                    body, t["sec_paras"], t["sec_sents"],
                    drop_code=t["drop_code"], drop_bullets=t["drop_bullets"])
                out.append(header + ("\n\n" + trimmed if trimmed else ""))
            elif kind == "chapter":
                out.append(header + ("\n\n" + body.strip() if body.strip() else ""))
            else:
                if body.strip():
                    out.append(body.strip())
        next_candidate = _compact("\n\n".join(out))
        sz = len(next_candidate.encode("utf-8"))
        LOG.info("compact tier (entry<=%d, sec<=%dpara/<=%dsent, drop_code=%s, "
                 "drop_bullets=%s, drop_entries=%s): %d bytes",
                 t["entry_lines"], t["sec_paras"], t["sec_sents"],
                 t["drop_code"], t["drop_bullets"], t["drop_entries"], sz)
        # Reject this tier if it cuts more than 30% AND we're already under
        # the hard cap -- the loss isn't worth it.
        prev_under_cap = prev_size <= hard_cap
        if prev_under_cap and sz < prev_size * 0.7:
            LOG.info("compact: keeping previous tier; next would drop too much "
                     "(%d -> %d, %.0f%%)", prev_size, sz, 100*(1 - sz/prev_size))
            return candidate
        candidate = next_candidate
        prev_size = sz
        if sz <= target_bytes:
            return candidate
    return candidate


def _strip_report_lines(text: str) -> str:
    """Remove stray 'REPORT: in=N read=M skipped=K' diagnostic lines that
    slice agents sometimes write into the part file. They're build telemetry,
    not cache content."""
    # Anchor on the line start, allow leading whitespace, and tolerate the
    # form `REPORT:in=...` (no space after colon) the agents sometimes use.
    return re.sub(r"^\s*REPORT:\s*in\s*=\s*\d+.*$\n?", "",
                  text, flags=re.MULTILINE)


def _strip_chapter_mode_suffix(text: str) -> str:
    """Strip stale `# dir  (reference|concept|verbatim|survey|catalog|mode)`
    suffixes from chapter heading lines. Slice prompt no longer asks for the
    mode tag, but slices that passed audit cleanly aren't re-spawned, so they
    keep the legacy format from earlier prompt versions."""
    return re.sub(
        r"^(# [^\n]+?)\s+\((?:reference|concept|verbatim|survey|catalog|mode)\)\s*$",
        r"\1", text, flags=re.MULTILINE)


def _strip_more_lines(text: str) -> str:
    """Strip stale 'More: $ALLEGRO_INSTALL_ROOT/...' pointer lines that
    older slice prompts asked agents to emit. These cost bytes per entry
    and the user said they aren't worth a tool-call round-trip."""
    return re.sub(r"^More:[^\n]*\n?", "", text, flags=re.MULTILINE)


def _cleanup(text: str, known_idents: set[str] | None = None) -> str:
    """Always-on cleanup. Strips dead `## ` headers (no body, no `###`
    children), drops empty-body `### ` entries and dedups within-chapter
    repeats, removes orphan micro-headers ('Example:' with no content), strips
    stray REPORT: build-telemetry lines, and collapses excess whitespace.
    Safe -- only removes provably non-content.
    """
    text = _strip_report_lines(text)
    text = _strip_chapter_mode_suffix(text)
    text = _strip_more_lines(text)
    text = _drop_empty_entries_and_dedup(text, known_idents=known_idents)
    blocks = _split_into_blocks(text)
    cleaned = []
    for kind, header, body in blocks:
        if kind == "entry":
            body = _strip_orphan_micro_headers(body)
        cleaned.append((kind, header, body))
    text = "\n\n".join(
        h + ("\n" + b if b.strip() else "") if k != "prose" else b
        for k, h, b in cleaned)
    text = _strip_dead_section_headers(text)
    return _compact(text)


def run(
    plan: list[dict],
    out_path: Path,
    install_root: Path,
    *,
    hard_cap: int,
    target_bytes: int,
    audit_report: dict | None = None,
    known_idents: set[str] | None = None,
    enforce_cap: bool = True,
    allow_compaction: bool = False,
) -> int:
    """Concatenate part files into the cache. Returns merged size in bytes.

    Always runs always-on cleanup (drops dead `## ` headers, empty `### `
    entries, dedups within-chapter repeats, drops orphan `Example:` style
    label lines). `known_idents` (from prepass `prefix_index.json`) widens
    dedup to cross-chapter for known identifiers. Only applies the tiered
    (lossy) compactor if allow_compaction=True AND raw size exceeds
    target_bytes; otherwise leaves slice content untouched.
    """
    parts: list[str] = []
    header = [
        "<!--",
        f"Generated by cache_builder for {install_root}",
        f"Build date: {dt.datetime.now().isoformat(timespec='seconds')}",
        f"Target bytes: {target_bytes}; hard cap: {hard_cap}",
    ]
    if audit_report:
        gaps = sum(1 for s in audit_report.get("slices", []) if s.get("has_gaps"))
        header.append(f"Audit iteration: {audit_report.get('iteration')}; "
                      f"slices with gaps: {gaps}; "
                      f"missing signals (cache-wide): "
                      f"{len(audit_report.get('global_missing_signals', []))}")
    header.append("-->")
    header_text = "\n".join(header)

    # Build slice-id -> chapter-name map and per-chapter aggregates of the
    # missing identifiers across its slices, for inline gap markers. We track
    # both a count and a sample of names so the marker tells the reader what
    # they don't know -- "omitted: 64 identifiers" reads as nerve-wracking
    # without context, but "omitted: 64 (e.g. axlFooBar, cnsBaz)" lets them
    # judge whether the gap matters for what they're doing.
    slice_chapter: dict[str, str] = {}
    for grp in plan:
        slice_chapter[grp["id"]] = grp.get("dir", "")
    gap_count_by_chapter: dict[str, int] = {}
    gap_sample_by_chapter: dict[str, list[str]] = {}
    if audit_report:
        for s in audit_report.get("slices", []):
            chap = slice_chapter.get(s.get("id", ""), "")
            if not chap:
                continue
            missing = s.get("missing_signals") or []
            if not missing:
                continue
            gap_count_by_chapter[chap] = gap_count_by_chapter.get(chap, 0) + len(missing)
            gap_sample_by_chapter.setdefault(chap, []).extend(missing)

    body_parts: list[str] = []
    for grp in plan:
        path = Path(grp["part_path"])
        if not path.exists():
            LOG.warning("merge: missing part %s", path)
            continue
        body = path.read_text(errors="replace").rstrip() + "\n"
        body_parts.append(body)

    merged_body = _cleanup("\n\n".join(body_parts), known_idents=known_idents)
    merged_body = _annotate_gap_markers(merged_body, gap_count_by_chapter,
                                         gap_sample_by_chapter)
    raw_size = len(merged_body.encode("utf-8"))
    LOG.info("merge: cleaned concat %d bytes; target=%d, cap=%d",
             raw_size, target_bytes, hard_cap)

    if raw_size > target_bytes and allow_compaction:
        LOG.warning("merge: applying tiered compaction (LOSSY -- agents "
                    "should have stayed under budget)")
        merged_body = _apply_tiered_compaction(merged_body, target_bytes,
                                                hard_cap)

    final = header_text + "\n\n" + merged_body
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(final)
    sz = out_path.stat().st_size
    LOG.info("merge: %s (%d bytes; target=%d, cap=%d)",
             out_path, sz, target_bytes, hard_cap)
    if sz > hard_cap:
        msg = (f"merged cache {sz} bytes exceeds hard cap {hard_cap} "
               f"({sz / hard_cap:.2f}x).")
        if enforce_cap:
            raise SystemExit(f"error: {msg} Re-run with smaller per-slice "
                             f"budgets or pass --allow-compaction.")
        LOG.warning("merge: %s", msg)
    return sz
