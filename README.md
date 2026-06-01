<!--
SPDX-FileCopyrightText: (C) 2026 Meta Platforms Inc.
SPDX-License-Identifier: Apache-2.0
-->
# Allegro Claude

Integrating Claude into the Allegro PCB designer environment.

## Usage

In Allegro SKILL (or in an ilinit), `load(".../allegro-claude/skill/allegro_claude.il")` then launch with the `claude` command.

If loading fails to auto-detect the script directory, set `ACL_scriptDir` explicitly before the load:

```skill
ACL_scriptDir = "/path/to/allegro-claude/skill/"
load(strcat(ACL_scriptDir "allegro_claude.il"))
```

### Documentation cache

Claude does its best work when it pre-loads the Allegro documentation, but this requires a massive (1.5MB pure markdown) cache. The cache differs by release and cannot be shared in this repo since the docs are only available to Cadence subscribers.

Generating the cache is run from a regular shell (not Allegro):

```
python3 cache_builder/build_doc_cache.py \
  --install-root /opt/cadence/SPB251 \
  --out ~/.local/share/allegro_claude/notes/SPB25_1_2025.md
```

The build runs unsupervised, takes hours and more than $1K in tokens to complete, and is safe to re-run -- it resumes from the work tree under `<out>.build/`.

If you are in an organization, you should place any sourced or generated cache into `ALLEGRO_SITE` to avoid each user needing to generate it themselves. Launching `claude` in Allegro will search for any cache and tell you the exact build command if it can't be found.

### Site and user customization

A few SKILL variables can be set *before* loading `allegro_claude.il` to customize behavior. These are intended for site `ilinit` files (organization-wide policy) or per-user `pcbenv/allegro.ilinit` (personal preferences):

- `ACL_extraPromptFiles` -- list of absolute paths whose contents are appended to Claude's system prompt. Use this to add site-specific policies, coding standards, library conventions, or any other instructions every session should see. Files are read fresh on each session start; missing or non-string entries are skipped.
- `ACL_claudeArgs` -- extra command-line flags appended to the `claude` CLI invocation.
- `ACL_codexArgs` -- extra command-line flags appended to the `codex` CLI invocation.
- `ACL_extraModels` -- JSON object of additional models to expose in the session picker. See [Registering additional models](#registering-additional-models) below.
- `ACL_useBuiltinModels` -- `'last` (default, user entries first), `t` (built-ins first), or `nil` (built-ins hidden entirely).
- `ACL_fast` -- skip preloading the Allegro documentation cache (faster startup, less context).

Example site `ilinit`:

```skill
ACL_extraPromptFiles = list(
  strcat(getShellEnvVar("ALLEGRO_SITE") "claude_policy.md")
  strcat(getShellEnvVar("ALLEGRO_SITE") "library_conventions.md"))
load("/path/to/allegro-claude/skill/allegro_claude.il")
```

### Registering additional models

`ACL_extraModels` is a JSON object keyed by short slug id (stable across versions; persisted in `settings.json` and per-session `sessions.json`). Each value is the field object for that entry. The parser accepts `'` in place of `"` so the embedded SKILL string literal stays readable.

Per-entry fields:

- `label` -- free-form display name shown in the picker dropdown.
- `driver` -- `'claude'` or `'codex'`.
- `model` -- driver-specific model identifier passed to the CLI.
- `context` -- context window in tokens; gates whether the ~1.5MB doc cache is inlined.
- `effort` -- (optional) reasoning effort. For `claude`, mapped to `--effort <value>`. For `codex`, mapped to `-c model_reasoning_effort=<value>` (typical codex values: `minimal`, `low`, `medium`, `high`, `xhigh`).
- `fallback` -- (optional) id of another registered entry to swap to on a matching `ACL_fallbackTriggers` error.
- `args` -- (optional) extra CLI args appended only when this entry is selected. Use for wrapper flags such as `--with-proxy <url>`.

Example -- adding a custom codex model and a wrapper-routed variant:

```skill
ACL_extraModels = "{
  'gpt-5-5-high': {'label':'Codex GPT-5.5 (high effort)',
                   'driver':'codex', 'model':'gpt-5.5',
                   'context':256000, 'effort':'high'},
  'gpt-5-5-internal': {'label':'Codex GPT-5.5 (internal proxy)',
                       'driver':'codex', 'model':'gpt-5.5',
                       'context':256000, 'effort':'xhigh',
                       'args':'--with-proxy http://example.internal/passthrough/v1'}
}"
load("/path/to/allegro-claude/skill/allegro_claude.il")
```

A user entry whose id matches a built-in fully replaces the built-in. See `plans/site-model-overrides.md` for additional examples (replacing a shipped entry, hiding built-ins, etc.).

## Files

### skill/

Contains the code, prompts, etc that would get shipped to users.

### test/

Contains scripts to help with testing.

### README.md (this file)

Has instructions to aid in development and testing of the project. Feel free to update with additional information.

## Development

### Documentation

While the SKILL script harnesses the Allegro runtime information to discover documentation, you may not have this when doing development.

On Linux, you can search for documentation in `/opt/cadence/SPB*/doc` and `/opt/cadence/SPB*/share/pcb/examples`. Use the highest SPB number you find.

For Claude (we're using the streaming json interface of the CLI), it's best to search the official Claude documentation online.

### Running tests

You should always test the script after making edits, and add tests as you discover bugs and add features.

Claude runs in a sandbox and cannot launch Allegro or use the Claude CLI, so follow this section carefully to run tests.

 * In general, robust tests should be added to `skill/allegro_claude_tests.il` so that they can be run as a regression suite. The file is a flat sequence of `ACL_check(...)` / `ACL_checkTrue(...)` calls grouped under `printf("\n--- Section name ---\n")` headers; loading the file IS the test run.
 * Sometimes you'll need to run test code, in which case you can optionally update `test/test.s` with some additional code to run. Remember that this file is an Allegro script (not SKILL), so you'll need to wrap SKILL code with a `skill` command.
 * The test harness has a hardcoded timeout of 5 minutes. This is far longer than should be necessary -- most Claude operations take 10-20 seconds at most, so if you think you need to increase the timeout, it's much more likely that something is deadlocked.
 * Remember that `ipcSleep()` is in seconds. In your tests, never sleep more than 1 second at a time.
 * Once you've written your tests, execute `test/run.sh` to trigger the test. The test will run (or error out) and write the results to stdout.
