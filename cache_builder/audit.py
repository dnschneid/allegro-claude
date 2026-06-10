# SPDX-FileCopyrightText: (C) 2026 Meta Platforms Inc.
# SPDX-License-Identifier: Apache-2.0
"""Phase 3 (slice run) + Phase 4 (audit + iterate) drivers.

Slice plan format (one entry per group, derived from survey output):
  {
    "id": "...",
    "dir": "...",
    "mode": "reference|concept|verbatim",
    "files": [...],
    "byte_budget": int,
    "part_path": "<work>/parts/<id>.md",
  }
"""

from __future__ import annotations

import fnmatch
import json
import logging
import random
import re
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path

from . import merge as merge_mod
from . import prompts as prompts_mod
from .slice_runner import Runner

LOG = logging.getLogger(__name__)

ENTRY_RE = re.compile(r"^### (.+)$", re.MULTILINE)
SECTION_RE = re.compile(r"^## (.+)$", re.MULTILINE)
COMBINED_NAME_RE = re.compile(r"[,/]")
STUB_TEXTS = ("toc", "section index", "see also", "navigation", "table of contents")
# Smaller slices = lower tail latency. With 16-32-way parallelism the long
# pole is a single slow slice; chopping into 30-file pieces lets the long
# tail finish in less wall-clock.
MAX_FILES_PER_SLICE = 30


def _expand_globs(
    dir_path: str, includes: list[str], excludes: list[str], files_in_dir: list[str]
) -> list[str]:
    """Match basenames against include/exclude globs. Return matching files."""
    if not includes:
        includes = ["*"]
    matched = []
    for rel in files_in_dir:
        base = Path(rel).name
        if not any(fnmatch.fnmatch(base, p) for p in includes):
            continue
        if any(fnmatch.fnmatch(base, p) for p in excludes):
            continue
        matched.append(rel)
    return matched


def _rebalance_group_budgets(
    slice_manifest: dict,
    files_by_dir: dict[str, list[str]],
    bytes_by_path: dict[str, int],
) -> None:
    """Rebalance per-group byte_budgets in-place to better match expected
    output size based on source bytes and density mode.

    The survey's allocation reflects perceived importance but often
    over-budgets thin reference dirs while under-budgeting dense API dirs.
    This pass nudges budgets toward `expected = source_bytes * density`
    where density depends on mode (reference is denser per byte than
    concept). The total budget is preserved.

    Caps movement: each group's new budget is at most 2x its survey value
    and at least 0.5x. Beyond that, the survey's judgment about importance
    overrides the proportional model.

    Concept-mode floor: large user-guide directories (concept mode, source
    >500 KB) need at least 0.5% of source as budget or they collapse to
    bare identifier lists with no narrative. Such groups are bumped to the
    floor regardless of the 2x clamp -- their survey budgets often start
    at a few hundred bytes (perceived as low priority) which leaves no
    room for prose at MB scale.
    """
    # Density: bytes-of-output per byte-of-source. Reference produces ~0.5%
    # (200x compression), concept ~0.1% (1000x compression because narrative
    # is heavily distilled), verbatim ~0.5% (light cleanup of small files).
    DENSITY = {"reference": 0.005, "concept": 0.001, "verbatim": 0.005}
    CONCEPT_FLOOR_RATIO = 0.005  # 0.5% of source bytes
    CONCEPT_FLOOR_TRIGGER = 500_000  # only kick in for >= 500KB source
    groups = [g for g in slice_manifest.get("groups", []) if g.get("mode") != "skip"]
    if not groups:
        return
    total_budget = sum(g.get("byte_budget", 0) for g in groups)
    expected = []
    matched_bytes_by_group: list[int] = []
    for g in groups:
        candidates = files_by_dir.get(g["dir"], [])
        includes = g.get("include") or ["*"]
        excludes = g.get("exclude") or []
        matched_bytes = 0
        for rel in candidates:
            base = Path(rel).name
            if not any(fnmatch.fnmatch(base, p) for p in includes):
                continue
            if any(fnmatch.fnmatch(base, p) for p in excludes):
                continue
            matched_bytes += bytes_by_path.get(rel, 0)
        matched_bytes_by_group.append(matched_bytes)
        density = DENSITY.get(g.get("mode"), 0.005)
        expected.append(matched_bytes * density)
    total_expected = sum(expected) or 1
    # Final budget = blend of survey's allocation and proportional model,
    # 50/50, then clamped to [0.5x, 2x] of the survey value. For concept
    # groups whose source is large enough that the floor kicks in, the
    # floor wins over the 2x clamp -- otherwise dense narrative dirs stay
    # starved no matter how the rebalancer redistributes.
    new_budgets: list[int] = []
    floored_idx: set[int] = set()
    for i, (g, exp, src) in enumerate(zip(groups, expected, matched_bytes_by_group)):
        survey_budget = g.get("byte_budget", 0)
        proportional = total_budget * exp / total_expected
        blended = (survey_budget + proportional) / 2
        clamped = max(survey_budget * 0.5, min(survey_budget * 2.0, blended))
        # Concept-mode floor: large narrative dirs need at least 0.5% of
        # source bytes for prose to fit. Treated as a hard minimum -- the
        # rebalancer can RAISE a starved survey value past the 2x clamp to
        # reach the floor, and renormalization downstream must not drag the
        # result back below it.
        if g.get("mode") == "concept" and src >= CONCEPT_FLOOR_TRIGGER:
            floor = int(src * CONCEPT_FLOOR_RATIO)
            if floor > clamped:
                clamped = floor
            floored_idx.add(i)
        new_budgets.append(int(clamped))
    # Renormalize to preserve total. Floored concept groups are preserved
    # at their floor; the shortfall is absorbed by other groups
    # proportional to their share of the non-floored total.
    floored_sum = sum(new_budgets[i] for i in floored_idx)
    other_indices = [i for i in range(len(new_budgets)) if i not in floored_idx]
    other_sum = sum(new_budgets[i] for i in other_indices) or 1
    other_target = total_budget - floored_sum
    if other_target < 0:
        # Floors alone exceed the budget; let everyone scale down together.
        nb_total = sum(new_budgets) or 1
        new_budgets = [int(b * total_budget / nb_total) for b in new_budgets]
    else:
        scale = other_target / other_sum
        for i in other_indices:
            new_budgets[i] = int(new_budgets[i] * scale)
    moved = sum(abs(b - g.get("byte_budget", 0)) for b, g in zip(new_budgets, groups))
    LOG.info(
        "plan: rebalanced budgets across %d groups (total moved: %d bytes; "
        "concept floor applied to %d)",
        len(groups),
        moved,
        len(floored_idx),
    )
    for g, b in zip(groups, new_budgets):
        g["byte_budget"] = b


def build_plan(
    slice_manifest: dict, parts_dir: Path, full_manifest: list[dict] | None = None
) -> list[dict]:
    """Expand survey groups into concrete slices.

    Survey emits per-dir groups with include/exclude globs. We expand globs
    against the full manifest, then split any group with >MAX_FILES_PER_SLICE
    files into multiple slices that share the parent group's mode and split
    the byte budget proportionally.
    """
    files_by_dir: dict[str, list[str]] = {}
    bytes_by_path: dict[str, int] = {}
    if full_manifest is not None:
        for e in full_manifest:
            if e["shadow_path"] is None:
                continue
            d = str(Path(e["rel_path"]).parent)
            files_by_dir.setdefault(d, []).append(e["rel_path"])
            bytes_by_path[e["rel_path"]] = e.get("bytes", 0)

    # Rebalance group budgets to better match expected output size before
    # chunking. Survey often over-budgets thin reference dirs and
    # under-budgets dense API dirs; the rebalancer moves slack from the
    # former to the latter while clamping to ±2x of survey's allocation.
    if full_manifest is not None:
        _rebalance_group_budgets(slice_manifest, files_by_dir, bytes_by_path)

    # Drop "ghost" survey groups whose globs match zero files. The survey
    # sometimes invents alpha-bucket groups (e.g. `_03_gh`, `_11_wx`) for
    # dirs whose filenames don't actually start with those letters; these
    # waste planning + an audit slot.
    plan: list[dict] = []
    for grp in slice_manifest.get("groups", []):
        if grp.get("mode") == "skip":
            continue
        dir_path = grp["dir"]
        candidate_files = files_by_dir.get(dir_path, [])
        if "files" in grp and grp["files"]:
            files = list(grp["files"])
        else:
            files = _expand_globs(
                dir_path,
                grp.get("include", ["*"]),
                grp.get("exclude", []),
                candidate_files,
            )
        if not files:
            LOG.warning("plan: group %s expanded to 0 files; skipping", grp.get("id"))
            continue
        # Split into <=MAX_FILES_PER_SLICE chunks.
        chunks = [
            files[i : i + MAX_FILES_PER_SLICE]
            for i in range(0, len(files), MAX_FILES_PER_SLICE)
        ]
        # Distribute the group's byte_budget proportionally to each chunk's
        # source bytes, with a per-chunk floor of 80 bytes/file. If floors
        # push the total above the group's allocation, scale the
        # above-floor portion down proportionally so the sum stays bounded.
        group_source_bytes = sum(bytes_by_path.get(f, 0) for f in files) or 1
        group_budget = grp.get("byte_budget", 0)
        chunk_source = [sum(bytes_by_path.get(f, 0) for f in c) for c in chunks]
        floors = [len(c) * 80 for c in chunks]
        weighted = [int(group_budget * cs / group_source_bytes) for cs in chunk_source]
        budgets = [max(f, w) for f, w in zip(floors, weighted)]
        total = sum(budgets)
        if total > group_budget and group_budget > sum(floors):
            # Scale the above-floor share down to fit the group budget.
            over = [b - f for b, f in zip(budgets, floors)]
            sum_over = sum(over) or 1
            excess = total - group_budget
            budgets = [
                f + max(0, o - int(excess * o / sum_over)) for f, o in zip(floors, over)
            ]
        for i, (chunk, source_bytes, per_chunk_budget) in enumerate(
            zip(chunks, chunk_source, budgets)
        ):
            chunk_id = grp["id"] if len(chunks) == 1 else f"{grp['id']}__{i+1}"
            plan.append(
                {
                    "id": chunk_id,
                    "dir": dir_path,
                    "mode": grp["mode"],
                    "files": chunk,
                    "byte_budget": per_chunk_budget,
                    "source_bytes": source_bytes,
                    "part_path": str(parts_dir / f"{chunk_id}.md"),
                    "rationale": grp.get("rationale", ""),
                    "tier": grp.get("tier"),
                }
            )
    LOG.info(
        "plan: %d slices from %d survey groups",
        len(plan),
        len(slice_manifest.get("groups", [])),
    )
    return plan


def run_slices(runner: Runner, plan: list[dict], *, max_parallel: int) -> None:
    """Phase 3 entry. Spawn slice agents in parallel, write to part files."""
    _run_slices_parallel(runner, plan, max_parallel=max_parallel, gap_addenda={})


def _run_slices_parallel(
    runner: Runner,
    slices: list[dict],
    *,
    max_parallel: int,
    gap_addenda: dict[str, str],
) -> dict[str, "RunStats"]:
    shadow_root = runner.work_dir / "shadow"
    results: dict[str, RunStats] = {}
    lock = threading.Lock()

    def _one(grp: dict):
        sys_p, usr_p = prompts_mod.build_slice_prompt(
            grp, shadow_root, gap_addendum=gap_addenda.get(grp["id"])
        )
        # Per-mode overrides
        model = runner.mode_models.get(grp["mode"])
        effort = runner.mode_efforts.get(grp["mode"])
        res = runner.run(
            prompt=usr_p,
            system_prompt=sys_p,
            tag=f"slice.{grp['id']}",
            retries=2,
            model=model,
            effort=effort,
        )
        stats = RunStats(
            slice_id=grp["id"],
            rc=res.rc,
            stalled=res.killed_for_inactivity,
            duration_s=res.duration_s,
            tool_uses=res.tool_uses,
        )
        with lock:
            results[grp["id"]] = stats
        return stats

    with ThreadPoolExecutor(max_workers=max_parallel) as pool:
        # Schedule slowest-likely slices first to keep the critical path
        # short. Approximation:
        #   weight = source_bytes * mode_factor
        # Concept-mode slices synthesize narrative from dense source and
        # take ~2x as long per byte as reference-mode extraction. Verbatim
        # is mostly copy-with-cleanup, so close to 1.
        MODE_FACTOR = {"concept": 2.0, "reference": 1.0, "verbatim": 0.7, "skip": 0.0}

        def _weight(g):
            sz = g.get("source_bytes") or len(g.get("files", []))
            return sz * MODE_FACTOR.get(g.get("mode"), 1.0)

        ordered = sorted(slices, key=lambda g: -_weight(g))
        for fut in as_completed(pool.submit(_one, g) for g in ordered):
            try:
                fut.result()
            except Exception as e:
                LOG.exception("slice agent crashed: %s", e)
    return results


@dataclass
class RunStats:
    slice_id: str
    rc: int
    stalled: bool
    duration_s: float
    tool_uses: int


@dataclass
class SliceAudit:
    slice_id: str
    part_path: Path
    bytes: int
    entries: int
    sections: int
    stub_entries: list[str] = field(default_factory=list)
    ghost_entries: list[str] = field(default_factory=list)
    combined_name_entries: list[str] = field(default_factory=list)
    over_budget: bool = False
    under_budget: bool = False
    missing_signals: list[str] = field(default_factory=list)
    semantic_score: float | None = None
    semantic_failures: list[str] = field(default_factory=list)

    @property
    def has_gaps(self) -> bool:
        # under_budget is NOT a gap on its own. If the agent stayed under
        # budget AND covered all signals AND has no stub/ghost entries, that
        # is a SUCCESS, not a failure. Forcing expansion would reverse the
        # whole point of budget discipline.
        return bool(
            self.over_budget
            or self.stub_entries
            or self.ghost_entries
            or self.missing_signals
            or (
                self.semantic_score is not None
                and self.semantic_score < 1.0
                and self.semantic_failures
            )
        )


def _parse_entries(text: str) -> list[tuple[str, str]]:
    """Return [(name, body)] for each ### entry."""
    out = []
    parts = re.split(r"^(### .+)$", text, flags=re.MULTILINE)
    # parts: [pre, header1, body1, header2, body2, ...]
    for i in range(1, len(parts), 2):
        header = parts[i][4:].strip()
        body = parts[i + 1].strip() if i + 1 < len(parts) else ""
        # Trim at next ## or # (not ###).
        body = re.split(r"^(?:## |# )", body, maxsplit=1, flags=re.MULTILINE)[0].strip()
        out.append((header, body))
    return out


def _audit_structural(grp: dict, signals_in_scope: set[str]) -> SliceAudit:
    part_path = Path(grp["part_path"])
    audit = SliceAudit(
        slice_id=grp["id"],
        part_path=part_path,
        bytes=part_path.stat().st_size if part_path.exists() else 0,
        entries=0,
        sections=0,
    )
    if not part_path.exists() or audit.bytes == 0:
        audit.under_budget = True
        return audit
    text = part_path.read_text(errors="replace")
    audit.entries = len(ENTRY_RE.findall(text))
    audit.sections = len(SECTION_RE.findall(text))

    budget = grp["byte_budget"]
    if audit.bytes < 0.5 * budget:
        audit.under_budget = True
    if audit.bytes > 1.2 * budget:
        audit.over_budget = True

    for name, body in _parse_entries(text):
        body_compact = re.sub(r"\s+", " ", body).strip()
        body_lower = body_compact.lower()
        is_stubby = (
            any(stub in body_lower for stub in STUB_TEXTS) and len(body_compact) < 120
        )
        if is_stubby:
            audit.stub_entries.append(name)
        elif len(body_compact) < 30:
            audit.ghost_entries.append(name)
        if COMBINED_NAME_RE.search(name):
            audit.combined_name_entries.append(name)

    if signals_in_scope:
        # Case-sensitive substring scan: identifiers must match exactly.
        missing = [s for s in signals_in_scope if s not in text]
        audit.missing_signals = missing
    return audit


def _scope_signals_to_slices(
    plan: list[dict], signals: list[str], shadow_root: Path
) -> dict[str, set[str]]:
    """Determine which slice should "own" each signal -- based on whether
    that signal's identifier actually appears in the slice's source shadow
    files. Used so re-spawn addenda only ask a slice to add identifiers
    that genuinely belong to its source dir.

    Returns {slice_id: {signal, ...}} for non-skip reference/verbatim
    slices. Concept slices get an empty set (concept mode legitimately
    folds many identifiers into one narrative section, so per-identifier
    scoping is wrong shape).

    Cost: one read per slice file + one substring scan per signal per
    slice. With 700 slices, 20K signals, and ~100KB per slice average,
    this is ~2GB of substring matches — too slow naive. Instead, for each
    slice build a single concatenated string of its source contents, then
    scan for signals in batch.
    """
    scope: dict[str, set[str]] = {}
    for grp in plan:
        if grp.get("mode") in (None, "skip", "concept"):
            scope[grp["id"]] = set()
            continue
        # Concatenate this slice's source content (shadow files).
        chunks = []
        for rel in grp.get("files", []):
            sp = shadow_root / (
                rel + ".txt" if rel.lower().endswith((".html", ".htm")) else rel
            )
            try:
                chunks.append(sp.read_text(errors="replace"))
            except OSError:
                continue
        haystack = "\n".join(chunks)
        owned = {s for s in signals if s in haystack}
        scope[grp["id"]] = owned
    return scope


# Identifier-noise filters: tokens we strip from "missing signals" before
# attaching to gap addenda. These cause false-positive re-spawn pressure.
_NOISE_SUFFIXES = (
    ".html",
    ".htm",
    ".bak",
    ".old",
    ".tmp",
    ".log",
    ".xml",
    ".json",
    ".tgf",
    ".css",
    ".js",
    ".gif",
    ".png",
    ".jpg",
    ".jpeg",
    ".bmp",
    ".svg",
    "_TOC",
    "_Commands",
    "TOC",
    "Commands",
)
_VALID_IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*$")


def _is_noise_signal(sig: str) -> bool:
    """A signal is "noise" (not really a callable identifier) if it ends
    with a file-suffix-shape, looks like a TOC marker, or fails identifier
    shape entirely. Such signals shouldn't drive re-spawns."""
    if any(sig.endswith(s) for s in _NOISE_SUFFIXES):
        return True
    if not _VALID_IDENT_RE.match(sig):
        return True
    return False


def iterate(
    runner: Runner,
    plan: list[dict],
    signals_obj: dict,
    *,
    max_iterations: int,
    quality_check: str | None,
    quality_gate: float | None,
    merge_to: Path,
    target_bytes: int,
    hard_cap: int,
    max_parallel: int,
    install_root: Path,
    known_idents: set[str] | None = None,
    allow_compaction: bool = False,
) -> None:
    signals = list(signals_obj.get("signals", []))
    LOG.info("audit: %d signals to verify (cache-wide)", len(signals))

    work_dir = runner.work_dir
    audit_report_path = work_dir / "audit_report.json"

    shadow_root = runner.work_dir / "shadow"
    # Filter out noise signals (filename-shaped, non-identifier-shaped) once.
    # These cause false-positive "missing identifier" addenda that drive
    # the iterate loop to chase ghosts.
    raw_signals = signals
    signals = [s for s in raw_signals if not _is_noise_signal(s)]
    LOG.info(
        "audit: %d signals after noise filter (was %d)", len(signals), len(raw_signals)
    )

    for iteration in range(max_iterations + 1):
        LOG.info("audit iteration %d", iteration)
        per_slice_signal_scope = _scope_signals_to_slices(plan, signals, shadow_root)
        audits = [
            _audit_structural(grp, per_slice_signal_scope.get(grp["id"], set()))
            for grp in plan
        ]

        # Cache-wide signal coverage: a signal counts as covered if any slice
        # contains it as a substring. This avoids forcing a signal to appear
        # in a specific slice when the survey's grouping doesn't perfectly
        # align with where the doc places the identifier.
        merged_text = "".join(
            (
                Path(grp["part_path"]).read_text(errors="replace")
                if Path(grp["part_path"]).exists()
                else ""
            )
            for grp in plan
        )
        global_missing = [s for s in signals if s not in merged_text]
        LOG.info(
            "audit: %d signals missing globally (of %d)",
            len(global_missing),
            len(signals),
        )

        # Header-form coverage check: identifier-shaped tokens from the prefix
        # index must appear as `### <ident>` headers (not just embedded in
        # bullet lists or bold text). A user greps for `^### name`, so
        # bullet/bold-listed entries don't count as covered.
        header_idents = set(
            re.findall(r"^### ([A-Za-z_][A-Za-z0-9_]+)\b", merged_text, re.MULTILINE)
        )
        # Also accept combined-name headers like `### foo / bar` and
        # `### foo, bar` so we don't false-flag those.
        for line in merged_text.splitlines():
            if line.startswith("### "):
                tail = line[4:]
                # Split on common separators used in combined heads.
                for tok in re.split(r"[,/\s]+|\s*\(", tail):
                    tok = tok.strip("`*")
                    if tok and re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", tok):
                        header_idents.add(tok)
        prefix_idx = {}
        prefix_idx_path = runner.work_dir / "prefix_index.json"
        if prefix_idx_path.is_file():
            prefix_idx = json.loads(prefix_idx_path.read_text()).get("prefixes", {})
        missing_idents_by_dir: dict[str, list[str]] = {}
        for prefix, info in prefix_idx.items():
            for d, dinfo in info.get("dirs", {}).items():
                missing = [
                    i
                    for i in dinfo["ids"]
                    if i not in header_idents and not _is_noise_signal(i)
                ]
                if missing:
                    missing_idents_by_dir.setdefault(d, []).extend(missing)
        if missing_idents_by_dir:
            n_total = sum(len(v) for v in missing_idents_by_dir.values())
            LOG.info(
                "audit: %d significant identifiers missing as `### ` "
                "headers (across %d dirs)",
                n_total,
                len(missing_idents_by_dir),
            )

        # Cache-wide oversize check. We don't tighten just because the cache
        # exceeded the soft target -- the target is the agents' goal, not a
        # hard limit, and a small overshoot is preferable to losing content.
        # Only tighten when total approaches the hard cap (within 5% of it),
        # since at that point the final merge will refuse to write the cache.
        total_size = sum(
            (
                Path(grp["part_path"]).stat().st_size
                if Path(grp["part_path"]).exists()
                else 0
            )
            for grp in plan
        )
        tightening_threshold = int(hard_cap * 0.95)
        if total_size > tightening_threshold:
            global_oversize_ratio = total_size / tightening_threshold
            LOG.warning(
                "audit: cache total %d bytes approaches hard cap %d "
                "(%.2fx of %d threshold); tightening per-slice budgets",
                total_size,
                hard_cap,
                global_oversize_ratio,
                tightening_threshold,
            )
            for grp in plan:
                grp["byte_budget"] = max(
                    200, int(grp["byte_budget"] / global_oversize_ratio)
                )
            # Re-audit to mark every slice that's over its NEW budget.
            audits = [
                _audit_structural(grp, per_slice_signal_scope.get(grp["id"], set()))
                for grp in plan
            ]

        # Distribute missing signals to slices most likely to be responsible:
        # for each missing signal, find any group whose dir name appears in
        # the signal, else attach to the largest reference-mode slice.
        ref_slices = [g for g in plan if g["mode"] == "reference"]
        biggest = (
            max(ref_slices, key=lambda g: g.get("byte_budget", 0))
            if ref_slices
            else None
        )
        attach_map: dict[str, list[str]] = {g["id"]: [] for g in plan}
        for sig in global_missing:
            owner = None
            for grp in plan:
                if grp["dir"].split("/")[-1].lower() in sig.lower():
                    owner = grp["id"]
                    break
            if owner is None and biggest is not None:
                owner = biggest["id"]
            if owner:
                attach_map[owner].append(sig)
        # Also attach missing identifiers (no `### ` header) to slices that
        # cover the source dir.
        for d, idents in missing_idents_by_dir.items():
            owners = [g for g in plan if g["dir"] == d and g.get("mode") == "reference"]
            if not owners:
                continue
            # Distribute to the smallest matching group (by file count) so
            # the addendum has room.
            owner = min(owners, key=lambda g: len(g.get("files", []))).get("id")
            attach_map[owner].extend(idents)
        for a in audits:
            a.missing_signals = attach_map.get(a.slice_id, [])

        if quality_check:
            _run_semantic_check(
                runner, plan, audits, exhaustive=(quality_check == "exhaustive")
            )

        # Persist report after every iteration.
        report = {
            "iteration": iteration,
            "global_missing_signals": global_missing,
            "slices": [
                {
                    "id": a.slice_id,
                    "bytes": a.bytes,
                    "entries": a.entries,
                    "sections": a.sections,
                    "stub_entries": a.stub_entries[:50],
                    "ghost_entries": a.ghost_entries[:50],
                    "combined_name_entries": a.combined_name_entries[:50],
                    "over_budget": a.over_budget,
                    "under_budget": a.under_budget,
                    "missing_signals": a.missing_signals[:200],
                    "semantic_score": a.semantic_score,
                    "semantic_failures": a.semantic_failures[:50],
                    "has_gaps": a.has_gaps,
                }
                for a in audits
            ],
        }
        audit_report_path.write_text(json.dumps(report, indent=1))

        # Always merge after each iteration so --out is usable. Don't enforce
        # the hard cap during iteration -- if oversize, we'll trim in the
        # next round. The final merge (after the loop) enforces.
        merge_mod.run(
            plan,
            merge_to,
            install_root,
            hard_cap=hard_cap,
            target_bytes=target_bytes,
            audit_report=report,
            known_idents=known_idents,
            enforce_cap=False,
            allow_compaction=allow_compaction,
        )

        gap_slices = [a for a in audits if a.has_gaps]
        if not gap_slices:
            LOG.info("audit: clean")
            return
        if iteration >= max_iterations:
            LOG.warning(
                "audit: %d slices still have gaps after %d iterations",
                len(gap_slices),
                max_iterations,
            )
            return

        # Build re-spawn addenda.
        gap_addenda: dict[str, str] = {}
        slice_by_id = {g["id"]: g for g in plan}
        # Pre-extract existing `### header` set per slice (carry-forward
        # baseline). Re-spawn must preserve these unless explicitly wrong.
        existing_headers: dict[str, list[str]] = {}
        for grp in plan:
            p = Path(grp["part_path"])
            if not p.is_file():
                existing_headers[grp["id"]] = []
                continue
            heads = []
            for line in p.read_text(errors="replace").splitlines():
                if line.startswith("### "):
                    heads.append(line[4:].strip())
            existing_headers[grp["id"]] = heads

        for a in gap_slices:
            grp = slice_by_id[a.slice_id]
            parts = []
            # Carry-forward baseline -- always include if there's prior content.
            prior = existing_headers.get(a.slice_id, [])
            if prior:
                # Cap to keep the addendum bounded; the baseline is informational.
                shown = prior[:80]
                more = f" (and {len(prior) - 80} more)" if len(prior) > 80 else ""
                parts.append(
                    f"Previous attempt produced these `### ` headers"
                    f"{more}: " + ", ".join(shown) + ". "
                    f"PRESERVE these headers in your output unless one is "
                    f"clearly wrong (a stub, an invented name not in source). "
                    f"Add what's listed below; do not silently drop existing "
                    f"valid headers to make room."
                )
            if a.over_budget:
                ratio = a.bytes / max(1, grp["byte_budget"])
                parts.append(
                    f"Previous attempt produced {a.bytes} bytes, "
                    f"{ratio:.1f}x over the {grp['byte_budget']} budget. "
                    f"This time, trim aggressively: drop examples, drop "
                    f"non-critical gotchas, use telegram style. Coverage > "
                    f"depth -- keep ALL files represented but make each "
                    f"entry as terse as possible."
                )
            if a.ghost_entries:
                parts.append(
                    "Previous attempt had empty/ghost bodies for: "
                    + ", ".join(a.ghost_entries[:30])
                    + ". Either fill them with real content from "
                    "source or drop the headers entirely."
                )
            if a.stub_entries:
                parts.append(
                    "Previous attempt had stub-only entries for: "
                    + ", ".join(a.stub_entries[:30])
                    + ". Either replace with real content from "
                    "source or drop the headers entirely."
                )
            if a.missing_signals:
                parts.append(
                    "These identifiers MUST appear (they exist in "
                    "the source files for this slice but were "
                    "omitted): " + ", ".join(a.missing_signals[:80])
                )
            if a.semantic_failures:
                parts.append(
                    "These entries scored useless/partial; ensure "
                    "they have at least: signature line, 1-line "
                    "behavior, and (if present in source) one "
                    "gotcha: " + ", ".join(a.semantic_failures[:30])
                )
            if parts:
                gap_addenda[a.slice_id] = "\n\n".join(parts)

        re_run = [g for g in plan if g["id"] in gap_addenda]
        LOG.info("audit: re-spawning %d slices", len(re_run))
        _run_slices_parallel(
            runner, re_run, max_parallel=max_parallel, gap_addenda=gap_addenda
        )


def _run_semantic_check(
    runner: Runner,
    plan: list[dict],
    audits: list[SliceAudit],
    *,
    exhaustive: bool,
) -> None:
    """Sample or exhaustive per-slice quality scoring."""
    audit_by_id = {a.slice_id: a for a in audits}
    lock = threading.Lock()

    def _one(grp: dict):
        part_path = Path(grp["part_path"])
        if not part_path.exists():
            return
        text = part_path.read_text(errors="replace")
        entries = _parse_entries(text)
        if not entries:
            return
        if exhaustive:
            sample = entries
        else:
            rng = random.Random(grp["id"])
            sample = rng.sample(entries, k=min(8, len(entries)))
        # Batches of 50 entries per Claude call.
        batch_size = 50
        useful = partial = useless = 0
        failures: list[str] = []
        for i in range(0, len(sample), batch_size):
            batch = sample[i : i + batch_size]
            entries_text = "\n\n".join(
                f"--- {name} ---\n{body[:1500]}" for name, body in batch
            )
            usr = prompts_mod.QUALITY_USER_TMPL.format(
                slice_id=grp["id"],
                mode=grp["mode"],
                n=len(batch),
                entries=entries_text,
            )
            res = runner.run(
                prompt=usr,
                system_prompt=prompts_mod.QUALITY_SYSTEM,
                tag=f"qcheck.{grp['id']}.b{i}",
                retries=1,
            )
            for line in res.last_assistant_text.splitlines():
                line = line.strip()
                if not line:
                    continue
                m = re.match(
                    r"^(.+?):\s*(useful|partial|useless)\s*$", line, re.IGNORECASE
                )
                if not m:
                    continue
                name, score = m.group(1).strip(), m.group(2).lower()
                if score == "useful":
                    useful += 1
                elif score == "partial":
                    partial += 1
                    failures.append(name)
                else:
                    useless += 1
                    failures.append(name)
        total = useful + partial + useless
        if total:
            score = useful / total
            with lock:
                audit_by_id[grp["id"]].semantic_score = score
                audit_by_id[grp["id"]].semantic_failures = failures
                LOG.info(
                    "qcheck: %s useful=%d partial=%d useless=%d (%.2f)",
                    grp["id"],
                    useful,
                    partial,
                    useless,
                    score,
                )

    with ThreadPoolExecutor(max_workers=4) as pool:
        for fut in as_completed(pool.submit(_one, g) for g in plan):
            try:
                fut.result()
            except Exception as e:
                LOG.exception("qcheck failed: %s", e)
