#!/bin/bash
# Guard: docs/process-maps.md documents the /pipeline:analyze-issues entrypoint,
# links the skill, and enumerates the four detection categories.
set -euo pipefail
FILE="docs/process-maps.md"
[ -f "$FILE" ] || { echo "FAIL: $FILE not present"; exit 1; }

grep -qF "/pipeline:analyze-issues" "$FILE" \
  || { echo "FAIL: $FILE missing entrypoint '/pipeline:analyze-issues'"; exit 1; }

grep -qF "skills/analyze-issues/SKILL.md" "$FILE" \
  || { echo "FAIL: $FILE missing reference to skills/analyze-issues/SKILL.md"; exit 1; }

for category in duplicate tracker missing supersession; do
  grep -qiF "$category" "$FILE" \
    || { echo "FAIL: $FILE missing detection category keyword '$category'"; exit 1; }
done

echo "PASS: process-maps.md documents /pipeline:analyze-issues, skill link, and all four detection categories"
