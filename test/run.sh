#!/bin/sh -eu
# SPDX-FileCopyrightText: (C) 2026 Meta Platforms Inc.
# SPDX-License-Identifier: Apache-2.0
DAEMON=acl-testd.sh
OUT=test.out

cd "$(dirname "$0")"
TIMEOUT="$(sed -n '/^ *timeout/s/.*timeout \([0-9]*\).*/\1/p' "$DAEMON")"

rm -f "$OUT"
if ! pkill -HUP "$DAEMON"; then
  echo "ERROR: test daemon not running. Ask the user to run '$PWD/$DAEMON' and then try again." >&2
  exit 99
fi

# Delay to ensure our timeout is longer than the test script's
sleep 3

while [ ! -f "$OUT" -a "$TIMEOUT" -gt 0 ]; do
  sleep 1
  TIMEOUT="$((TIMEOUT-1))"
done

cat "$OUT"
