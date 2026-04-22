#!/bin/sh -e
# SPDX-FileCopyrightText: (C) 2026 Meta Platforms Inc.
# SPDX-License-Identifier: Apache-2.0
SCR=test.s
OUT=test.out

CADENCE="./cadence.sh"
TOOL="allegro"

if [ ! -x "$CADENCE" ]; then
  echo '#!/bin/sh -eu
# Launches cadence binaries with the right environment. First arg is the tool to run.
# Example tools:
#   allegro -nographic  -- runs allegro in non-graphic mode; use parameters to add scripts
#   extracta  -- generates reports on a board file
#   report  -- also generates reports on a board file
exec "/path/to/cadence.sh" "$@"' > "$CADENCE"
  chmod +x "$CADENCE"
  echo "Wrote example launcher script to $CADENCE." >&2
  echo "Update it as necessary and run again." >&2
  exit 0
fi

echo "$SCR -> $OUT: $$"

cd "$(dirname "$0")"

runtest() {
  rm -f "$OUT"
  printf "%s" "$(date)"
  if grep -xFq "exit" "$SCR"; then
    timeout 300 "$CADENCE" "$TOOL" -nograph -s "$SCR" > "${OUT}_" 2>&1 ||
      echo "exit code $?" >> "${OUT}_"
    mv -f "${OUT}_" "$OUT" || true
  else
    echo "ERROR: test script $SCR must end in "'`exit`' > "$OUT"
  fi
  echo "...done"
}

trap runtest HUP

while sleep 1; do :; done
