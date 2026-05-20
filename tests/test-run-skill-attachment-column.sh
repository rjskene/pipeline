#!/bin/bash
set -euo pipefail

# Verifies that skills/run/SKILL.md declares the new `att=N` column in
# both the per-row metadata bullet list and the NOTES footer block.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../skills/run/SKILL.md"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
nope() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Per-row metadata bullet: literal `att=N` should appear inside the
# `**Per-row metadata**` bullet list.
if awk '/\*\*Per-row metadata\*\*/{flag=1} flag && /att=N/{found=1; exit} /\*\*Grouped layout/{flag=0} END{exit !found}' "$TARGET"; then
  ok "Per-row metadata bullet references att=N"
else
  nope "att=N not found in Per-row metadata bullet list"
fi

# NOTES footer block: literal `att` column header should appear inside the
# NOTES footer fence.
if awk '/NOTES \(non-default\)/{flag=1} flag && /\| att/{found=1; exit} /Counts footer/{flag=0} END{exit !found}' "$TARGET"; then
  ok "NOTES footer table declares an att column"
else
  nope "att column missing from NOTES footer"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
