# SPDX-FileCopyrightText: (C) 2026 Meta Platforms Inc.
# SPDX-License-Identifier: Apache-2.0
"""Allegro doc cache builder.

Pipeline: prepass (shadow tree) -> survey (one Claude call) ->
slice agents (parallel Claude calls) -> audit + iterate -> merge.

Entry point: build_doc_cache.py.
"""
