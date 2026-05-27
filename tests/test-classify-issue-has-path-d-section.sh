#!/bin/bash
# Guard: classify-issue/SKILL.md has a PATH D section + sentinel blocks preserved.
set -euo pipefail
FILE="skills/classify-issue/SKILL.md"
[ -f "$FILE" ] || { echo "FAIL: $FILE not present"; exit 1; }
grep -qE '(## )?PATH D|PATH D \(quick-fix\)' "$FILE" || { echo "FAIL: no PATH D section found"; exit 1; }
grep -qF '<!-- pipeline:path=D -->' "$FILE" || { echo "FAIL: PATH D body marker example missing"; exit 1; }
grep -qF 'BEGIN-PATH-MARKER-PARSE' "$FILE" || { echo "FAIL: BEGIN-PATH-MARKER-PARSE sentinel removed"; exit 1; }
grep -qF 'END-PATH-MARKER-PARSE' "$FILE" || { echo "FAIL: END-PATH-MARKER-PARSE sentinel removed"; exit 1; }
grep -qF 'BEGIN-LABEL-APPLY' "$FILE" || { echo "FAIL: BEGIN-LABEL-APPLY sentinel removed"; exit 1; }
grep -qF 'END-LABEL-APPLY' "$FILE" || { echo "FAIL: END-LABEL-APPLY sentinel removed"; exit 1; }
# Cap raised 220 -> 250 by #546: classify-issue gained an opener-association
# trust gate (step 0a) and a `## Comment trust` contract section.
LINES=$(wc -l < "$FILE")
[ "$LINES" -le 250 ] || { echo "FAIL: $FILE has $LINES lines (cap is 250)"; exit 1; }
echo "PASS: PATH D section + sentinels present, ${LINES}/250 lines"
