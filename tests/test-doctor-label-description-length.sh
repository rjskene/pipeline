#!/usr/bin/env bash
# test-doctor-label-description-length.sh — guard for GitHub's label-description
# limit (issue #1147). GitHub rejects `gh label create` with HTTP 422 when a
# label description exceeds 100 characters. doctor.sh's `--fix labels` seeds the
# canonical LABEL_TABLE via `gh label create`, so any row whose description is
# >100 chars silently 422s at seed time and the label never lands on the repo
# (the #1147 `next` regression, introduced by #1131 at 103 chars).
#
# This guard parses doctor.sh's LABEL_TABLE (rows of the form
# <key>|<name>|<color>|<description>) and asserts EVERY description is <=100
# chars, so a future over-long description fails CI instead of silently 422-ing.
#
# Hermetic: parses the checked-in doctor.sh source directly; no `gh` / network.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/doctor.sh"

MAX=100

PASS=0; FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

[ -f "$DOCTOR" ] || { echo "ERROR: $DOCTOR not found" >&2; exit 1; }

# Extract the LABEL_TABLE rows: quoted "key|name|color|description" lines
# between `LABEL_TABLE=(` and the closing `)`.
rows="$(awk '
  /^LABEL_TABLE=\(/ { intable = 1; next }
  intable && /^\)/  { intable = 0 }
  intable {
    line = $0
    # strip leading whitespace and surrounding double quotes
    sub(/^[[:space:]]*"/, "", line)
    sub(/"[[:space:]]*$/, "", line)
    if (line != "") print line
  }
' "$DOCTOR")"

[ -n "$rows" ] || { echo "ERROR: no LABEL_TABLE rows parsed from $DOCTOR" >&2; exit 1; }

ROW_COUNT=0
while IFS='|' read -r key name color desc; do
  [ -n "$key" ] || continue
  ROW_COUNT=$((ROW_COUNT + 1))
  len=${#desc}
  if [ "$len" -le "$MAX" ]; then
    pass_msg "label '$name' description length $len <= $MAX"
  else
    fail_msg "label '$name' description length $len > $MAX (GitHub 422s): $desc"
  fi
done <<<"$rows"

# Sanity: we parsed a plausible number of rows (guards against a parser regression
# silently passing zero rows).
if [ "$ROW_COUNT" -ge 10 ]; then
  pass_msg "parsed $ROW_COUNT label rows"
else
  fail_msg "parsed only $ROW_COUNT label rows — parser likely broken"
fi

echo ""
echo "================================"
echo "  test-doctor-label-description-length: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
