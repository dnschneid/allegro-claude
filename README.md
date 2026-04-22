<!--
SPDX-FileCopyrightText: (C) 2026 Meta Platforms Inc.
SPDX-License-Identifier: Apache-2.0
-->
# Allegro Claude

Integrating Claude into the Allegro PCB designer environment.

## Usage

In Allegro SKILL (or in an ilinit), `load(".../allegro-claude/skill/allegro_claude.il")` then launch with the `claude` command.

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

 * In general, robust tests should be added to `ACL_runTests()` so that they can be run as a regression suite.
 * Sometimes you'll need to run test code, in which case you can optionally update `test/test.s` with some additional code to run. Remember that this file is an Allegro script (not SKILL), so you'll need to wrap SKILL code with a `skill` command.
 * The test harness has a hardcoded timeout of 5 minutes. This is far longer than should be necessary -- most Claude operations take 10-20 seconds at most, so if you think you need to increase the timeout, it's much more likely that something is deadlocked.
 * Remember that `ipcSleep()` is in seconds. In your tests, never sleep more than 1 second at a time.
 * Once you've written your tests, execute `test/run.sh` to trigger the test. The test will run (or error out) and write the results to stdout.
