#!/bin/bash
# Guard: docs/process-maps.md exists and contains the three expected map headings.
set -euo pipefail
FILE="docs/process-maps.md"
[ -f "$FILE" ] || { echo "FAIL: $FILE not present"; exit 1; }
for heading in "Full lifecycle map" "PATH dispatch decision tree" "Wave-plan flow"; do
  grep -qF "$heading" "$FILE" || { echo "FAIL: $FILE missing heading '$heading'"; exit 1; }
done
LINES=$(wc -l < "$FILE")
[ "$LINES" -le 200 ] || { echo "FAIL: $FILE has $LINES lines (cap is 200)"; exit 1; }
echo "PASS: process-maps.md present, all headings found, ${LINES}/200 lines"
