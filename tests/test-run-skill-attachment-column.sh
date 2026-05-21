#!/bin/bash
set -euo pipefail

# Verifies that skills/run/SKILL.md declares the new `att=N` column in
# the per-row metadata bullet list, and that the rendered NOTES footer
# block declares the `att` column.
#
# After issue #340 the rendered NOTES footer example moved out of
# SKILL.md into skills/run/references/status-table-layout.md. The
# per-row metadata bullet (a decision-time rule) stays inline.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL="$SCRIPT_DIR/../skills/run/SKILL.md"
REF="$SCRIPT_DIR/../skills/run/references/status-table-layout.md"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
nope() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Per-row metadata bullet: literal `att=N` should appear inside the
# `**Per-row metadata**` bullet list in SKILL.md.
if awk '/\*\*Per-row metadata\*\*/{flag=1} flag && /att=N/{found=1; exit} /\*\*Grouped layout/{flag=0} END{exit !found}' "$SKILL"; then
  ok "Per-row metadata bullet references att=N"
else
  nope "att=N not found in Per-row metadata bullet list (SKILL.md)"
fi

# NOTES footer block: literal `att` column header should appear inside the
# NOTES footer fence — now lives in references/status-table-layout.md.
if awk '/NOTES \(non-default\)/{flag=1} flag && /\| att/{found=1; exit} /Counts footer/{flag=0} END{exit !found}' "$REF"; then
  ok "NOTES footer table declares an att column (references/status-table-layout.md)"
else
  nope "att column missing from NOTES footer (references/status-table-layout.md)"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
