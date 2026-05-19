#!/usr/bin/env python3
# SPDX-FileCopyrightText: (C) 2026 Meta Platforms Inc.
# SPDX-License-Identifier: Apache-2.0
"""Build the Allegro doc cache by orchestrating Python pre-pass + Claude agents.

Run:
  python3 cache_builder/build_doc_cache.py \
      --install-root /opt/cadence/SPB251 \
      --out ~/.local/share/allegro_claude/notes/SPB25_1_2025.md

Both flags optional. --install-root defaults to highest /opt/cadence/SPB*; --out
defaults to ~/.local/share/allegro_claude/notes/SPB<sanitized-version>.md.
"""

from __future__ import annotations

import argparse
import json
import logging
import shutil
import sys
from pathlib import Path

from . import audit, merge, prepass, prompts, slice_runner

LOG = logging.getLogger("cache_builder")

DEFAULT_NOTES_DIR = Path.home() / ".local/share/allegro_claude/notes"
HARD_CAP_BYTES = 1_800_000
DEFAULT_TARGET_BYTES = 1_500_000
SURVEY_BUDGET_BYTES = 1_500_000


def discover_install_root() -> Path:
    candidates = sorted(Path("/opt/cadence").glob("SPB*"))
    if not candidates:
        sys.exit("error: no /opt/cadence/SPB* dirs; pass --install-root explicitly")
    return candidates[-1]


def sanitize_version(install_root: Path) -> str:
    """Map e.g. /opt/cadence/SPB251 -> SPB251.

    The on-disk version label may include hotfix suffixes; we keep what's after
    /opt/cadence so the SKILL discovery (`SPB<version>.md`) finds it.
    """
    return install_root.name


def default_out_path(install_root: Path) -> Path:
    return DEFAULT_NOTES_DIR / f"{sanitize_version(install_root)}.md"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install-root", type=Path, default=None)
    parser.add_argument("--out", type=Path, default=None)
    parser.add_argument("--work", type=Path, default=None,
                        help="Work tree (default: <out>.build/)")
    parser.add_argument("--clean", action="store_true",
                        help="Force from-scratch rebuild")
    parser.add_argument("--keep-work", action="store_true",
                        help="Keep work tree after success")
    parser.add_argument("--target-bytes", type=int, default=DEFAULT_TARGET_BYTES)
    parser.add_argument("--max-iterations", type=int, default=3)
    parser.add_argument("--max-parallel", type=int, default=16,
                        help="Concurrent slice agents. Claude is API-bound, "
                             "not CPU-bound, so this can be high (16-32).")
    parser.add_argument("--allow-compaction", action="store_true",
                        help="If iterations don't get under target, allow "
                             "lossy algorithmic compaction at final merge. "
                             "Default off: prefer to surface oversize as a "
                             "build failure so the user can re-run with "
                             "smaller --target-bytes.")
    parser.add_argument("--quality-check", choices=["sample", "exhaustive"],
                        default=None)
    parser.add_argument("--quality-gate", type=float, default=None,
                        help="Min useful-ratio per slice; below = re-spawn")
    parser.add_argument("--phase", choices=["prepass", "survey", "slices",
                                            "audit", "merge", "all"],
                        default="all",
                        help="Run only one phase (work tree must exist).")
    parser.add_argument("--from-phase", choices=["prepass", "survey", "slices",
                                                 "audit", "merge"],
                        default=None,
                        help="Run from this phase onward. Useful to skip "
                             "expensive prepass/survey on re-runs while still "
                             "regenerating slices and audit/merge.")
    parser.add_argument("--model", default="opus",
                        help="Default model for slice agents (opus by default "
                             "since concept-mode synthesis benefits).")
    parser.add_argument("--reference-model", default="sonnet",
                        help="Model for reference-mode slice agents. "
                             "Defaults to 'sonnet' (latest alias) -- reference "
                             "entries are structured extraction; sonnet matches "
                             "opus quality at ~5x lower cost and faster wall "
                             "time. Pass an explicit model to override, or '' "
                             "to fall back to --model.")
    parser.add_argument("--effort", default="high",
                        help="Effort level for slice agents. "
                             "Reference and concept modes both benefit "
                             "from sustained reasoning -- 'high' produces "
                             "richer behavior phrases and preserves "
                             "caveats.")
    parser.add_argument("--reference-effort", default="",
                        help="Effort level for reference-mode slice "
                             "agents only. Empty (default) inherits "
                             "--effort. Setting this lower (e.g. 'low') "
                             "tends to trade per-entry depth for broader "
                             "index coverage -- one-line entries instead of "
                             "behavior+caveats.")
    parser.add_argument("--inactivity-timeout", type=int, default=600,
                        help="Per-Claude-call inactivity kill timeout (s). "
                             "Survey uses 3x this (long thinking phases). "
                             "Slice agents on dense narrative content can go "
                             "5-10min between visible events during long "
                             "thinking blocks; 600s avoids killing them.")
    parser.add_argument("-v", "--verbose", action="count", default=0)
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose >= 1 else logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )

    install_root = (args.install_root or discover_install_root()).resolve()
    if not install_root.is_dir():
        sys.exit(f"error: --install-root {install_root} is not a directory")
    out_path = (args.out or default_out_path(install_root)).resolve()
    work_dir = (args.work or Path(str(out_path) + ".build")).resolve()

    LOG.info("install root: %s", install_root)
    LOG.info("output: %s", out_path)
    LOG.info("work tree: %s", work_dir)

    if args.clean and work_dir.exists():
        LOG.info("--clean: removing existing work tree")
        shutil.rmtree(work_dir)
    work_dir.mkdir(parents=True, exist_ok=True)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    runner = slice_runner.Runner(
        model=args.model,
        effort=args.effort,
        inactivity_timeout_s=args.inactivity_timeout,
        install_root=install_root,
        work_dir=work_dir,
        mode_models={"reference": args.reference_model} if args.reference_model
                     else {},
        mode_efforts={"reference": args.reference_effort} if args.reference_effort
                     else {},
    )

    manifest_path = work_dir / "manifest.json"
    slice_manifest_path = work_dir / "slice_manifest.json"
    signals_path = work_dir / "critical_signals.json"
    parts_dir = work_dir / "parts"
    parts_dir.mkdir(exist_ok=True)

    # Compute which phases to run.
    PHASES = ["prepass", "survey", "slices", "audit", "merge"]
    if args.from_phase:
        active = set(PHASES[PHASES.index(args.from_phase):])
        single_phase = False
    elif args.phase == "all":
        active = set(PHASES)
        single_phase = False
    else:
        active = {args.phase}
        single_phase = True

    # ---- Phase 1: pre-pass --------------------------------------------------
    if "prepass" in active:
        LOG.info("phase 1: pre-pass (shadow tree)")
        prepass.run(install_root, work_dir, max_workers=args.max_parallel)

    # ---- Phase 2: survey ----------------------------------------------------
    if "survey" in active:
        if not manifest_path.is_file():
            sys.exit("error: manifest.json missing; run --phase prepass first")
        LOG.info("phase 2: survey")
        prompts.run_survey(runner, manifest_path, slice_manifest_path,
                           signals_path, target_bytes=args.target_bytes,
                           survey_budget_bytes=SURVEY_BUDGET_BYTES)

    # ---- Phases 3-5: slice agents, audit-iterate, merge --------------------
    if active & {"slices", "audit", "merge"}:
        if not slice_manifest_path.is_file():
            sys.exit("error: slice_manifest.json missing; run --phase survey first")
        slice_manifest = json.loads(slice_manifest_path.read_text())
        signals = json.loads(signals_path.read_text())
        full_manifest = json.loads(manifest_path.read_text())
        # Load identifiers prepass extracted from source. Used by merge dedup
        # to widen scope from within-chapter to global for known SKILL names
        # while still keeping cross-language collisions like `print` separate.
        prefix_index_path = work_dir / "prefix_index.json"
        known_idents: set[str] = set()
        if prefix_index_path.is_file():
            pi = json.loads(prefix_index_path.read_text())
            for _prefix, info in pi.get("prefixes", {}).items():
                known_idents.update(info.get("ids", []))

        plan = audit.build_plan(slice_manifest, parts_dir,
                                full_manifest=full_manifest)

        if "slices" in active:
            LOG.info("phase 3: slice agents (%d slices)", len(plan))
            audit.run_slices(runner, plan, max_parallel=args.max_parallel)

        if "audit" in active:
            LOG.info("phase 4: audit + iterate (max %d rounds)",
                     args.max_iterations)
            audit.iterate(
                runner, plan, signals,
                max_iterations=args.max_iterations,
                quality_check=args.quality_check,
                quality_gate=args.quality_gate,
                merge_to=out_path,
                target_bytes=args.target_bytes,
                hard_cap=HARD_CAP_BYTES,
                max_parallel=args.max_parallel,
                install_root=install_root,
                known_idents=known_idents,
                allow_compaction=args.allow_compaction,
            )

        if "merge" in active:
            LOG.info("phase 5: final merge")
            audit_report = work_dir / "audit_report.json"
            report = json.loads(audit_report.read_text()) if audit_report.is_file() else {}
            merge.run(plan, out_path, install_root,
                      hard_cap=HARD_CAP_BYTES,
                      target_bytes=args.target_bytes,
                      audit_report=report,
                      known_idents=known_idents,
                      allow_compaction=args.allow_compaction)

    LOG.info("done: %s (%d bytes)", out_path,
             out_path.stat().st_size if out_path.exists() else 0)
    LOG.info("total cost: $%.2f over %d Claude calls",
             runner.total_cost_usd, runner.total_calls)

    if not args.keep_work and not single_phase and active == set(PHASES):
        LOG.info("removing work tree (pass --keep-work to retain)")
        shutil.rmtree(work_dir, ignore_errors=True)

    return 0


if __name__ == "__main__":
    sys.exit(main())
