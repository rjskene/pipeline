#!/bin/bash
# Guard: docs/process-maps.md exists and contains the three expected map headings.
set -euo pipefail
FILE="docs/process-maps.md"
[ -f "$FILE" ] || { echo "FAIL: $FILE not present"; exit 1; }
for heading in "Full lifecycle map" "PATH dispatch decision tree" "Wave-plan flow"; do
  grep -qF "$heading" "$FILE" || { echo "FAIL: $FILE missing heading '$heading'"; exit 1; }
done
# Cap raised 200 -> 220 (#368): the doc gained the "Visual proof sub-skill
# (needs-browser lane)" subsection for a genuinely new pipeline lane. The new
# section is kept tight; the bump is the proportionate alternative to gutting
# the unrelated ASCII maps to preserve an arbitrary 200.
# Cap raised 220 -> 235 (#777): the doc gained the "Dispatch transport" section
# (inline Agent() vs spawn, keyed off PATH letter) + a Transport column on the
# path table for a genuinely new documented axis. Kept tight (terse ASCII);
# same proportionate-bump rationale as the #368 raise.
LINES=$(wc -l < "$FILE")
[ "$LINES" -le 235 ] || { echo "FAIL: $FILE has $LINES lines (cap is 235)"; exit 1; }
echo "PASS: process-maps.md present, all headings found, ${LINES}/235 lines"
