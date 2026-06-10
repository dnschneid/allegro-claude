# SPDX-FileCopyrightText: (C) 2026 Meta Platforms Inc.
# SPDX-License-Identifier: Apache-2.0
"""Prompt templates + Phase 2 survey driver.

The slice prompt templates intentionally do not name any Allegro-specific dir,
file, or function. They reference only structural / syntactic conventions
discovered during the survey-pass.
"""

from __future__ import annotations

import fnmatch
import json
import logging
from pathlib import Path

from .slice_runner import Runner

LOG = logging.getLogger(__name__)

SURVEY_SYSTEM = """You are organizing a documentation cache build for an
engineering tool. You receive a manifest of pre-converted text files
(originally HTML/SKILL/text/menu/form/etc.) and must produce two JSON files
that drive a downstream extraction pipeline.

You are autonomous: spawn no subagents, ask no questions, write the JSON files
directly, then exit.
"""

SURVEY_USER_TMPL = """Inputs you can read:
- {manifest_path} -- per-dir summary of the source tree. Schema:
    {{
      "dirs": {{ "<install-rel dir>": {{
            files, bytes, lines, ext_counts, toc_count, tiny_count,
            samples: [{{rel_path, shadow_path, bytes}}, ...],  // ~6 sample files
            prefix_counts: {{"<3-char prefix>": <distinct-id-count>, ...}}
      }} }},
      "skipped_dirs": {{ "<install-rel dir>": {{binary, ignored, bytes}} }},
      "totals": {{dirs, files, bytes}},
      "significant_prefixes": {{ "<prefix>": {{
            id_count, file_count,
            top_dirs: [["<dir>", <distinct-ids-in-dir>], ...]
      }} }}
    }}
  Use the `samples` to Read 1-3 representative non-TOC files per dir BEFORE
  classifying it. Do not classify by directory name alone.
- {shadow_root}/<shadow_path> -- pre-converted text content of any file.

Produce two files (overwriting if they exist):
1. {slice_manifest_path}
2. {signals_path}

=== {slice_manifest_path} ===
JSON object: {{ "groups": [ {{ ...group... }}, ... ] }}

Each group represents one downstream extraction agent's workload. Schema:
  {{
    "id":           short-slug-for-this-group  (unique, filesystem-safe),
    "dir":          install-relative dir path (e.g. "doc/algroskill"),
    "mode":         one of "skip" | "reference" | "concept" | "verbatim",
    "include":      list of glob patterns (relative to "dir") to include
                    (e.g. ["*.html"] or ["[a-z]*.html"]); use ["*"] for all
    "exclude":      list of glob patterns to exclude (e.g. ["*TOC.html",
                    "*_Commands.html"])
    "byte_budget":  integer bytes for this group's part file,
    "tier":         integer 1-4 ranking how load-bearing this group is for
                    an LLM driving the tool. The merged cache will be
                    reordered by tier so small-context models that can only
                    inline a leading slice still see the high-value content.
                      1 = required to write any working code (raw API
                          signatures, core language primitives the model
                          quotes verbatim).
                      2 = strongly informs codegen, survivable to grep on
                          demand (workflow APIs, shell commands, library
                          conventions, common gotchas).
                      3 = useful context, mostly narrative (workflow
                          overviews, conceptual chapters, methodology).
                      4 = drop-first (UI element catalogs, click-through
                          walkthroughs, example registries, near-empty
                          stubs, tangentially related tooling).
                    Be deliberate: a small-context model will see only
                    tiers 1-2 (~300-500 KB). Tier 1 should be the API
                    surface a real session hits repeatedly, NOT everything
                    that *might* be useful.
    "rationale":    one sentence
  }}

The Python orchestrator expands include/exclude globs against the actual file
list from the full manifest. You don't need to enumerate every file.

CATEGORICAL API COVERAGE -- the most important rule:
The input lists `significant_prefixes`: identifier prefixes that appear at
sig positions in source. Every significant prefix MUST be covered by at
least one reference-mode group whose source dir contains that prefix's
identifiers. Concept-mode coverage does NOT count -- a narrative section
about constraint manager doesn't help a user looking up `cmxlGetX`.

For example, if the input shows `significant_prefixes` includes `cmxl`
with `top_dirs: [["doc/consmgr", 33]]`, then there must be a reference
group whose `dir = "doc/consmgr"` (or includes its files) and whose
include globs match the cmxl* files. The dir may also have non-cmxl
content; if so, EITHER promote the whole dir to reference, OR split into
two groups (one reference for cmxl*, one concept for the rest).

This rule applies to every prefix in `significant_prefixes`. Do not skip
or concept-only any dir whose `prefix_counts` shows a significant prefix
unless that prefix is already covered by another group.

Rules:
- Cover EVERY non-binary, non-ignored file in the manifest exactly once
  across all non-skip groups (per the include/exclude globs).
- A single dir may produce multiple groups -- e.g. one for the lowercase
  function reference pages, one for the capitalized procedural / dialog
  pages -- if the content really splits.
- Aim for groups of 30-80 files after glob expansion. Larger groups stall
  the downstream agents. If a dir has more files than this, split it.
- Sum of byte_budget across non-skip groups must be <= {survey_budget}.
- Allocate budget by importance and depth, not by file count. A 30-file dir
  of dense API reference may need more than a 200-file dir of near-empty
  dialog stubs. **But** every non-skip dir must get at least
  `max(150, file_count * 80)` bytes -- enough for a header per file plus
  a phrase. Below that, you're effectively skipping with no signal.
  **Concept-mode dirs >500KB of source need at least 0.5% of source bytes**
  (e.g. a 1MB user guide needs >=5KB) -- below that the agent can only emit
  identifier headers with no narrative, defeating the purpose of concept
  mode. The orchestrator will silently raise concept budgets to that floor
  if you set them lower; you can save it the trouble by allocating
  generously up front.
- The cache will be loaded as a search index. A user searching for
  identifier X needs to find at least the header `### X`, even if the
  body says "see source: $ALLEGRO_INSTALL_ROOT/...". Coverage > depth.

Density modes:
- "reference" -- each file produces one or more `### name` entries with
  signature, behavior, args, returns, gotcha, example. Use for files that
  describe APIs, commands, directives, options, or other identifier-keyed
  reference material. **Catalog dirs (e.g. per-rule constraint catalogs,
  per-command alphabetical command refs, per-page Tcl/script API listings)
  belong here, not in concept**: each entry stands alone and a user looking
  for one needs the others to exist as searchable headers, even if terse.
- "concept" -- each file (or topical cluster) produces one `## Title`
  narrative section covering what / lifecycle / idioms / pitfalls / API
  pointers. Use for chapter-style overviews, user guides, methodology docs.
- "verbatim" -- copy small files (or extracts) as-is into a fenced code
  block. Use for tiny but information-dense data files.
- "skip" -- drop entirely. Use ONLY for TOCs, indices, navigation pages,
  near-empty stubs. Files matching trivial signal `is_html_toc` should
  typically be excluded via the exclude globs rather than placed in a
  skip group. **Be very careful about skipping a large dir wholesale --
  if it has 100+ files, check via samples that you're not dropping the
  primary doc surface for some Allegro feature.**

Sampling discipline: BEFORE assigning a mode, Read 1-3 of the dir's `samples`.
Don't classify by name alone -- some dirs mix reference and concept content.

ANTI-PATTERN: dirs whose filenames are gerund/sentence-shaped (e.g.
`Adding_Callouts.html`, `Creating_Differential_Pairs_in_X_Presto.html`,
`Editing_Pads_in_Property_Panel.html`) and whose `prefix_counts` shows NO
significant prefixes are END-USER GUIDE narrative -- click-through how-to
prose with no callable identifiers. Force these to **concept** mode. If a
narrative dir has no real concepts to anchor either (pure UI walkthrough),
**skip** it. Forcing such a dir to reference mode triggers downstream
agents to invent fake `### name` entries from feature labels and stall in
budget arithmetic.

=== {signals_path} ===
JSON object: {{ "signals": [ ...flat list of identifier strings... ] }}

These are exact-match grep targets the audit will use to verify coverage. Goal:
maximize coverage. The list can be very large (thousands).

What to include:
- Function names, command names, directive names, env var names, special
  variable names, configuration option keys, example file basenames.
- Anything identifier-shaped (matches /^[A-Za-z_][A-Za-z0-9_]*$/, optionally
  with one or two embedded dots/dashes for namespaced ones).

What NOT to include:
- Conceptual phrases. Those paraphrase too freely to grep reliably.
- English words that aren't identifiers ("the", "function", "Note").
- Anything ambiguous with common English (e.g. bare "add", "open", "close",
  "set", "get" without a longer prefix).

Extract signals by scanning shadow files. Use Grep aggressively. Examples
of patterns that yield good signals:
- Lines starting with `# `, `## `, `### ` (markdown-ish headings in shadow files)
- Lines like `Function: foo`, `Syntax: foo(...)`, `Command: bar`
- Backticked tokens with parentheses
- Every identifier listed under `significant_prefixes` is a guaranteed signal.

Don't over-think: false positives from including a near-identifier are cheap;
false negatives (missing signals) hide gaps in the cache.

When done, write both files and stop. Do not summarize."""


def run_survey(
    runner: Runner,
    manifest_path: Path,
    slice_manifest_path: Path,
    signals_path: Path,
    *,
    target_bytes: int,
    survey_budget_bytes: int,
) -> None:
    work_dir = runner.work_dir
    shadow_root = work_dir / "shadow"
    # Build a compact per-dir summary for the survey. Listing every file is
    # too large -- a 374-dir, 15k-file install yields a 3+MB manifest.
    # Instead, give the survey: counts, total bytes, ext breakdown, a few
    # sample shadow paths per dir, and the skipped (binary/ignored) summary.
    # The survey emits dir-level groups; the slice planner expands actual
    # file lists from the full manifest.
    full_manifest = json.loads(manifest_path.read_text())
    survey_manifest_path = work_dir / "survey_manifest.json"

    by_dir: dict[str, dict] = {}
    skipped_summary: dict[str, dict[str, int]] = {}
    SAMPLES_PER_DIR = 6
    for e in full_manifest:
        dir_name = str(Path(e["rel_path"]).parent)
        if e["shadow_path"] is None:
            d = skipped_summary.setdefault(
                dir_name, {"binary": 0, "ignored": 0, "bytes": 0}
            )
            if "binary" in e["trivial_signals"]:
                d["binary"] += 1
            else:
                d["ignored"] += 1
            d["bytes"] += e["bytes"]
            continue
        bucket = by_dir.setdefault(
            dir_name,
            {
                "files": 0,
                "bytes": 0,
                "lines": 0,
                "ext_counts": {},
                "toc_count": 0,
                "tiny_count": 0,
                "samples": [],
                "prefix_counts": {},
            },
        )
        bucket["files"] += 1
        bucket["bytes"] += e["bytes"]
        bucket["lines"] += e["lines"]
        bucket["ext_counts"][e["ext"]] = bucket["ext_counts"].get(e["ext"], 0) + 1
        if "is_html_toc" in e["trivial_signals"]:
            bucket["toc_count"] += 1
        if "tiny" in e["trivial_signals"]:
            bucket["tiny_count"] += 1
        for prefix, idents in (e.get("prefixes") or {}).items():
            if not idents:
                continue
            cur = bucket["prefix_counts"].setdefault(prefix, set())
            cur.update(idents)
        if (
            len(bucket["samples"]) < SAMPLES_PER_DIR
            and "is_html_toc" not in e["trivial_signals"]
            and "tiny" not in e["trivial_signals"]
        ):
            bucket["samples"].append(
                {
                    "rel_path": e["rel_path"],
                    "shadow_path": e["shadow_path"],
                    "bytes": e["bytes"],
                }
            )
    # Convert prefix sets to counts for json-serializability.
    for bucket in by_dir.values():
        bucket["prefix_counts"] = {
            p: len(v)
            for p, v in sorted(
                bucket["prefix_counts"].items(), key=lambda kv: -len(kv[1])
            )
        }

    # Load the prefix index (significant identifier surfaces). Survey is
    # required to provide reference-mode coverage for each.
    prefix_index_path = work_dir / "prefix_index.json"
    significant_prefixes: dict[str, dict] = {}
    if prefix_index_path.is_file():
        prefix_index = json.loads(prefix_index_path.read_text())
        # Project the per-prefix detail to a survey-friendly shape:
        # {prefix: {id_count, file_count, top_dirs: [(dir, ids_in_dir)]}}
        for prefix, info in prefix_index.get("prefixes", {}).items():
            top_dirs = sorted(
                ((d, len(v["ids"])) for d, v in info["dirs"].items()),
                key=lambda kv: -kv[1],
            )[:6]
            significant_prefixes[prefix] = {
                "id_count": info["id_count"],
                "file_count": info["file_count"],
                "top_dirs": top_dirs,
            }

    survey_view = {
        "dirs": by_dir,
        "skipped_dirs": skipped_summary,
        "totals": {
            "dirs": len(by_dir),
            "files": sum(d["files"] for d in by_dir.values()),
            "bytes": sum(d["bytes"] for d in by_dir.values()),
        },
        "significant_prefixes": significant_prefixes,
    }
    survey_manifest_path.write_text(json.dumps(survey_view, indent=1))
    LOG.info(
        "survey: per-dir summary -> %s (%d dirs, %d candidate files)",
        survey_manifest_path,
        len(by_dir),
        survey_view["totals"]["files"],
    )

    user_prompt = SURVEY_USER_TMPL.format(
        manifest_path=survey_manifest_path,
        shadow_root=shadow_root,
        slice_manifest_path=slice_manifest_path,
        signals_path=signals_path,
        survey_budget=survey_budget_bytes,
    )

    # Run survey, then validate prefix coverage. Survey-level retries cover
    # two failure modes:
    #   (a) the agent exits cleanly but forgets to write the JSON files
    #       (chatty preface, no actual output -- rc=0 but no on-disk result);
    #   (b) the survey finishes but its slice_manifest fails the prefix
    #       coverage validator (some significant API surface is uncovered).
    # The slice runner's own retries handle transport-level failures (rc!=0).
    coverage_retries = 2
    addendum = ""
    output_retries_remaining = 2
    coverage_attempt = 0
    while True:
        prompt_now = user_prompt + addendum
        tag = f"survey.cov{coverage_attempt}" if coverage_attempt else "survey"
        res = runner.run(
            prompt=prompt_now,
            system_prompt=SURVEY_SYSTEM,
            tag=tag,
            retries=2,
            inactivity_timeout_s=runner.inactivity_timeout_s * 3,
        )
        if res.rc != 0:
            raise SystemExit(
                f"survey failed (rc={res.rc}, stalled={res.killed_for_inactivity}); "
                f"check {res.raw_log_path}"
            )
        if not slice_manifest_path.is_file() or not signals_path.is_file():
            if output_retries_remaining <= 0:
                raise SystemExit(
                    f"survey produced no output files after retries; "
                    f"check {res.raw_log_path}"
                )
            output_retries_remaining -= 1
            LOG.warning(
                "survey: agent finished without writing output files; "
                "retrying (%d attempts left)",
                output_retries_remaining,
            )
            addendum = (
                "\n\nRETRY: your previous attempt finished without "
                "writing the required output files. You MUST write "
                f"BOTH {slice_manifest_path} AND {signals_path} as "
                "the final action. Do not preface with intent; just "
                "produce the JSON now."
            )
            continue
        sm = json.loads(slice_manifest_path.read_text())
        sig = json.loads(signals_path.read_text())
        LOG.info(
            "survey: %d groups, %d signals",
            len(sm.get("groups", [])),
            len(sig.get("signals", [])),
        )

        gaps = _validate_prefix_coverage(sm, significant_prefixes, full_manifest)
        if not gaps:
            LOG.info("survey: prefix coverage OK")
            return
        if coverage_attempt >= coverage_retries:
            LOG.warning(
                "survey: %d prefixes still uncovered after %d retries; "
                "shipping anyway",
                len(gaps),
                coverage_retries,
            )
            for prefix, info in list(gaps.items())[:10]:
                LOG.warning(
                    "  uncovered prefix '%s': %d ids in %s",
                    prefix,
                    info["id_count"],
                    ", ".join(d for d, _ in info["top_dirs"][:3]),
                )
            return
        # Build addendum naming the gaps and re-run.
        gap_lines = [
            "",
            "=== COVERAGE GAP -- you missed significant API prefixes ===",
            "Re-emit the slice_manifest.json with these gaps fixed:",
            "",
        ]
        for prefix, info in gaps.items():
            top = ", ".join(f"{d} ({n})" for d, n in info["top_dirs"][:3])
            gap_lines.append(
                f"- prefix `{prefix}*` ({info['id_count']} identifiers in "
                f"{info['file_count']} files): mostly in {top}. "
                f"Add a reference-mode group covering these files."
            )
        gap_lines.append("")
        gap_lines.append(
            "Re-run -- write {slice_manifest_path} and "
            "{signals_path} again, fully covering these prefixes."
        )
        addendum = "\n".join(gap_lines).format(
            slice_manifest_path=slice_manifest_path, signals_path=signals_path
        )
        LOG.warning(
            "survey: %d uncovered prefixes; retry %d/%d",
            len(gaps),
            coverage_attempt + 1,
            coverage_retries,
        )
        coverage_attempt += 1


def _validate_prefix_coverage(
    slice_manifest: dict,
    significant_prefixes: dict,
    full_manifest: list[dict],
) -> dict:
    """Return prefixes whose identifiers are not adequately covered by any
    reference-mode group. A prefix is "covered" if at least one
    reference-mode group's expanded file list intersects ≥50% of the prefix's
    files in any single dir.
    """
    if not significant_prefixes:
        return {}
    # Build a quick per-dir prefix file-set map from full_manifest.
    # {prefix: {dir: set(files)}}
    prefix_files: dict[str, dict[str, set[str]]] = {}
    for e in full_manifest:
        if e["shadow_path"] is None:
            continue
        prefixes = e.get("prefixes") or {}
        d = str(Path(e["rel_path"]).parent)
        for p in prefixes:
            if p not in significant_prefixes:
                continue
            prefix_files.setdefault(p, {}).setdefault(d, set()).add(e["rel_path"])

    # Build per-group expanded file set (reference mode only).
    files_by_dir: dict[str, list[str]] = {}
    for e in full_manifest:
        if e["shadow_path"] is None:
            continue
        files_by_dir.setdefault(str(Path(e["rel_path"]).parent), []).append(
            e["rel_path"]
        )

    ref_group_files: list[set[str]] = []
    for grp in slice_manifest.get("groups", []):
        if grp.get("mode") != "reference":
            continue
        d = grp["dir"]
        candidates = files_by_dir.get(d, [])
        includes = grp.get("include") or ["*"]
        excludes = grp.get("exclude") or []
        matched = set()
        for rel in candidates:
            base = Path(rel).name
            if not any(fnmatch.fnmatch(base, p) for p in includes):
                continue
            if any(fnmatch.fnmatch(base, p) for p in excludes):
                continue
            matched.add(rel)
        if matched:
            ref_group_files.append(matched)

    gaps = {}
    for prefix, dirs in prefix_files.items():
        info = significant_prefixes[prefix]
        # For coverage to count, at least one reference group must intersect
        # ≥50% of the prefix's files in some single dir.
        covered = False
        for d, files in dirs.items():
            for grp_files in ref_group_files:
                hit = grp_files & files
                if len(hit) >= max(1, len(files) // 2):
                    covered = True
                    break
            if covered:
                break
        if not covered:
            gaps[prefix] = {
                "id_count": info["id_count"],
                "file_count": info["file_count"],
                "top_dirs": info["top_dirs"],
            }
    return gaps


# ---- Slice prompts ---------------------------------------------------------

SLICE_SYSTEM_COMMON = """You are extracting a documentation cache slice. The
output goes into a Claude system prompt that must be *small enough to load*.
Every byte counts. Your job is to produce maximally information-dense entries
within a hard byte budget.

Hard rules:
1. STREAM OUTPUT. Write the part file's header BEFORE reading any source.
   Append entries in batches of 15-20 files. Never accumulate everything in
   memory and write at the end.
2. Use the pre-converted shadow files at the paths given. Do NOT read raw
   HTML.
3. Wall-clock 10 minutes max.
4. Density is the WHOLE point. Use shorthand, abbreviations, telegram
   style. Drop articles ("the", "a"), copulas ("is", "are"), filler
   ("Note that...", "It is important to..."). Never write a sentence when
   a phrase suffices, never a phrase when a tag suffices.
5. End with a single line:
       REPORT: in=N read=M skipped=K[: reason1, reason2, ...]
"""

SLICE_REFERENCE_BODY = """SLICE: {slice_id}    DIR: {dir}    MODE: reference
PART FILE: {part_path}
BYTE BUDGET: {byte_budget} bytes (HARD LIMIT)
SHADOW FILES TO PROCESS:
{file_list}

For each documented identifier (function, command, directive, option),
emit one entry. EVERY identifier gets its own `### name` header.
NEVER collapse multiple identifiers into a `**bold**` bullet list -- a
user searching the cache greps for `^### name`, and a bullet list breaks
that. Combined-name `### foo / bar` headers are PERMITTED ONLY for
trivially related pairs (Get/Set, Begin/End, Push/Pop) that share docs.

EXACT FORMAT per entry:

  ### name
  `signature(arg1, arg2, ...) => return-type`
  Behavior phrase. Gotcha if non-obvious. (one line max, telegram style)
  ex: `name(1, 2)`         (only if call shape isn't obvious from sig)

When the budget is tight, ONE-LINE entries (header with sig+phrase
appended) are also fine:

  ### name `(args)=>type` Behavior phrase.

That's typically 3 lines per entry, ~150 bytes (or ~80 bytes for the
one-line form). If the source is sparse, 2 lines (header + sig) is correct.

GOOD EXAMPLES:

  ### axlDBCreatePath
  `axlDBCreatePath(l_pointList [t_lineFontName] [n_width]) => l_dbid/nil`
  Creates path on current layer; returns dbid+drcCount. nil on bad layer.
  ex: `axlDBCreatePath('((0 0)(100 100)) "solid" 5)`

  ### axlIsRefSet `() => t/nil` T iff a refresh is pending.

  ### axlPathArcAngle `(o_arc) => x_degrees` Sweep angle, +CCW.

BAD (waste bytes OR break grep-by-header):

  ### axlIsRefSet                     <-- prose padding
  `axlIsRefSet() => t/nil`
  Behavior: This function returns t if a refresh is pending, otherwise nil.
  Returns: t or nil.
  Args: none.

  ### axlPathArcAngle                 <-- example duplicates sig
  `axlPathArcAngle(o_arc) => x_degrees`
  Behavior: Returns the sweep angle in degrees, positive counterclockwise.
  Example:
  ```
  axlPathArcAngle(arc)
  ```

  ### Allegro Library Manager SKILL          <-- composite header (BAD)
  - **lmgrAddMenuItems** `(menu, items)`     <-- bullet list (BAD)
  - **lmgrAddToolBarItems** `(tb, items)`    <-- BAD: lmgrAddMenuItems
                                                  is a separate identifier
                                                  and needs `### lmgrAddMenuItems`

Rules on coverage:
- ALL content pages are in scope, including capitalized "Dialog Box" / "How
  To" / "Concept" pages -- treating them as out-of-scope leaves 30-90%
  coverage gaps in command-letter dirs. They are IN scope.
- A file may produce multiple entries (one per fn/cmd/option).
- A file may produce zero entries if it is purely navigation (TOC). Count
  in report; do not emit a stub.

SIGNATURE FORMAT -- preserve full arg-name hints:
- ALWAYS keep the original arg names with Hungarian-style type prefixes:
  `o_dbid` (dbid), `l_dbids` (list), `t_text` (text/string), `n_width`
  (numeric), `r_path` (record/struct), `g_arg` (generic), `s_sym` (symbol),
  `x_count` (integer).
- NEVER abbreviate args to single letters: `(o_dbid l_layers) => t/nil`
  costs only 8 more bytes than `(o l) => t/nil` and saves the user a
  documentation lookup. The name-hint is the difference between a usable
  entry and a useless one.
- Bracket optional args: `[t_lineFontName]`. Use `|` for type unions:
  `r_orient|t_styleId|x_block`. Show return type after `=>`.

BUDGET DISCIPLINE -- this is the most important rule:
- Budget is HARD. Going over wastes downstream compaction (which lossily
  drops content). Under is fine.
- Estimate: budget / file_count = bytes per file. With 30 files and 5000
  byte budget, that's 167 bytes per file -- header + 1-line sig + brief
  behavior fits, no example.
- Coverage > depth. Prefer ALL files represented terse > some files rich.
  When budget is tight, use ONE-LINE entries (`### name (args) what`)
  rather than dropping `### name` entries altogether.
- Track cumulative size as you append. If approaching budget, drop
  examples first, then drop gotchas, then trim behavior to bare phrase,
  then collapse to one-line entries -- but NEVER drop the `### name` header.
- The build will iterate if you go over budget, re-spawning your slice
  with a smaller budget. Avoid the round-trip by staying under on first try.

End your AGENT response (NOT the part file) with a single REPORT line:
  REPORT: in=N read=M skipped=K
DO NOT write "REPORT:" into the part file -- it's diagnostic output, not
cache content.

Begin by writing this header to {part_path} (overwrite):

# {dir}

Then process files in batches.
"""

SLICE_CONCEPT_BODY = """SLICE: {slice_id}    DIR: {dir}    MODE: concept
PART FILE: {part_path}
BYTE BUDGET: {byte_budget} bytes (HARD LIMIT)
SHADOW FILES TO PROCESS:
{file_list}

For each major topic / chapter, emit a tight, dense entry. EXACT FORMAT:

  ## Title

  WHAT: 1-sentence definition.
  USE: when/why you reach for this (1-2 phrases).
  STATE: lifecycle / scope / order rules. Skip if N/A.
  PITFALL: what bites users. Skip if N/A.
  API: comma-separated list of fn/cmd names this concept involves.
  src: `$ALLEGRO_INSTALL_ROOT/<install-relative-path>`

That's typically 5-7 short lines per topic, ~250-400 bytes. Many topics
will be shorter.

GOOD EXAMPLE:

  ## Dynamic Shape Voiding

  WHAT: auto-generated voids in copper shapes around clearance violations.
  USE: replace fixed-shape voids when nets/pins move during routing.
  STATE: dynamic shapes can be FROZEN to commit voids; smooth/refresh
    triggers re-void. Frozen shapes behave like static.
  PITFALL: voids re-compute on every parameter change; large boards lag.
    Use `axlShapeFreezeAll` to suspend, edit, then unfreeze + update.
  API: axlShapeAutoVoid, axlShapeChangeDynamicType, axlShapeDeleteVoids,
    axlShapeDynamicUpdate, axlShapeFreezeAll, axlShapeIsFrozen,
    axlShapeSetFrozen, axlShapeUnfreezeAll.
  src: `$ALLEGRO_INSTALL_ROOT/doc/algroskill/Dynamic_Shape_Voiding.html`

BAD (prose padding):

  ## Dynamic Shape Voiding

  Dynamic shape voiding is a feature in Allegro PCB Editor that automatically
  generates voids in copper shapes around clearance violations. This is very
  useful when you have a complex board where nets and pins are moving during
  routing operations. ...

Rules:
- Sibling files may be merged into one entry if they cover one concept.
- TOC / navigation files: skip silently, count in report.
- Use bullet lists ONLY when the source enumerates discrete items
  (e.g. error codes, control IDs). Prefer comma-separated lists for short
  enumerations.
- Code blocks ONLY when the syntax can't be paraphrased (e.g. BNF, exact
  regex). Otherwise inline-quote with backticks.

BUDGET DISCIPLINE:
- Budget is HARD. budget / topic_count = bytes per topic.
- Coverage > depth.
- The build will iterate if you go over budget, re-spawning your slice
  with a tighter budget. Avoid the round-trip by staying under on first try.

Begin by writing this header to {part_path} (overwrite):

# {dir}

Then process files in batches.
"""

SLICE_VERBATIM_BODY = """SLICE: {slice_id}    DIR: {dir}    MODE: verbatim
PART FILE: {part_path}
BYTE BUDGET: {byte_budget} bytes (HARD LIMIT)
SHADOW FILES TO PROCESS:
{file_list}

Each file is included near-verbatim. Light cleanup: drop pure boilerplate,
collapse runs of blank lines, remove license headers. Wrap each file's
content in a fenced code block with the file path as the heading:

  ### $ALLEGRO_INSTALL_ROOT/<install-relative-path>
  ```
  ...content...
  ```

If a file is too large for the per-file share of budget (budget /
file_count), elide internal sections with `...` rather than skipping.

Begin by writing this header to {part_path} (overwrite):

# {dir}

Then process files.
"""


def build_slice_prompt(
    group: dict, shadow_root: Path, gap_addendum: str | None = None
) -> tuple[str, str]:
    """Return (system_prompt, user_prompt) for one slice."""
    mode = group["mode"]
    file_lines = []
    for rel in group["files"]:
        file_lines.append(
            f"  - {shadow_root}/{rel}.txt"
            if rel.lower().endswith((".html", ".htm"))
            else f"  - {shadow_root}/{rel}"
        )
    file_list = "\n".join(file_lines) if file_lines else "  (none)"
    body_tmpl = {
        "reference": SLICE_REFERENCE_BODY,
        "concept": SLICE_CONCEPT_BODY,
        "verbatim": SLICE_VERBATIM_BODY,
    }[mode]
    body = body_tmpl.format(
        slice_id=group["id"],
        dir=group["dir"],
        mode=mode,
        part_path=group["part_path"],
        byte_budget=group["byte_budget"],
        file_list=file_list,
    )
    if gap_addendum:
        body += "\n\nADDITIONAL REQUIREMENTS (this is a re-spawn):\n" + gap_addendum
    return SLICE_SYSTEM_COMMON, body


# ---- Quality-check (semantic audit) prompts --------------------------------

QUALITY_SYSTEM = """You are auditing a documentation cache slice for quality.
For each entry shown, decide whether it would help an engineer who needs the
information: useful (answers the obvious questions), partial (some content
but missing key detail), useless (stub or garbage)."""

QUALITY_USER_TMPL = """Slice: {slice_id} ({mode})

Below are {n} entries from this slice. For each, return one line:

  <entry-name>: useful|partial|useless

No prose, no other output.

Entries:

{entries}
"""
