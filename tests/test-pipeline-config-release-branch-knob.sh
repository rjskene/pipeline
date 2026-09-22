#!/bin/bash
set -euo pipefail

# Dual-scan hand-patch guard for PIPELINE_RELEASE_BRANCH (#1356), modeled on
# tests/test-pipeline-config-next-branch-knobs.sh.
#
# PIPELINE_RELEASE_BRANCH is an overrides-only knob with a read-site default of
# main (hooks/enforce-base-branch.py), so it ships COMMENTED in the example.
# This test pins that it is documented in:
#   - pipeline.config.example (ALWAYS present, the only tracked surface) — must
#     appear COMMENTED (a live, uncommented line would turn
#     test-doctor-golden-seed-set.sh red).
#   - the gitignored, host-only live pipeline.config (dogfood host ONLY) — when
#     present, it must carry it too. This is the forcing function for the
#     by-hand live-config edit. The SKIP guard keeps CI a no-op on the live file.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$REPO_ROOT/pipeline.config"
EX="$REPO_ROOT/pipeline.config.example"

PASS=0; FAIL=0; SKIP=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

# --- Example file (always present, tracked) ---------------------------------
assert "example documents PIPELINE_RELEASE_BRANCH" \
  "grep -qE '^[[:space:]]*#?[[:space:]]*PIPELINE_RELEASE_BRANCH=' '$EX'"

# Overrides-only: MUST be commented in the example (no live line) so the
# golden-seed set is not forced to grow.
assert "example PIPELINE_RELEASE_BRANCH is COMMENTED (overrides-only)" \
  "! grep -qE '^[[:space:]]*PIPELINE_RELEASE_BRANCH=' '$EX'"

# --- Live host config (gitignored, dogfood host only) ----------------------
if [ -f "$CFG" ]; then
  assert "live pipeline.config documents PIPELINE_RELEASE_BRANCH" \
    "grep -qE '^[[:space:]]*#?[[:space:]]*PIPELINE_RELEASE_BRANCH=' '$CFG'"
else
  echo "  SKIP: live pipeline.config PIPELINE_RELEASE_BRANCH (file gitignored, not present)"
  SKIP=$((SKIP+1))
fi

echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = "0" ]
