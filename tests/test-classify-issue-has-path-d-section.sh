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
# New blast-radius B→D routing rule anchors (#707): the rule subsection + its
# mined exemplars must be present in the PATH D authoring section.
grep -qF 'Blast-radius B→D' "$FILE" || { echo "FAIL: blast-radius B→D rule anchor missing"; exit 1; }
grep -qF '#691' "$FILE" || { echo "FAIL: blast-radius exemplar #691 missing"; exit 1; }
grep -qF '#698' "$FILE" || { echo "FAIL: blast-radius boundary exemplar #698 missing"; exit 1; }
# Cap raised 220 -> 250 by #546 (opener-association trust gate + `## Comment
# trust` section); 250 -> 270 by #707 (blast-radius rule + high-uncertainty
# carve-out + two exemplar tables, ~25 lines).
LINES=$(wc -l < "$FILE")
[ "$LINES" -le 270 ] || { echo "FAIL: $FILE has $LINES lines (cap is 270)"; exit 1; }
echo "PASS: PATH D section + sentinels present, ${LINES}/270 lines"
