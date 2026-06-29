#!/bin/bash
set -euo pipefail

# Dual-scan regression for the next-branch routing knobs (#1128), modeled on
# tests/test-pipeline-base-branch-staging.sh.
#
# PIPELINE_NEXT_BRANCH / PIPELINE_NEXT_LABEL are overrides-only knobs with
# read-site ${VAR:-next} defaults, so they ship COMMENTED in the example. This
# test pins that they are documented in:
#   - pipeline.config.example (ALWAYS present, the only tracked surface) — must
#     appear COMMENTED (a live, uncommented line would defeat central default
#     evolution and turn test-doctor-golden-seed-set.sh red).
#   - the gitignored, host-only live pipeline.config (dogfood host ONLY) — when
#     present, it must carry them too. This is the forcing function for the
#     by-hand live-config edit. The SKIP guard keeps CI a no-op on the live file.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$REPO_ROOT/pipeline.config"
EX="$REPO_ROOT/pipeline.config.example"

PASS=0; FAIL=0; SKIP=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

# --- Example file (always present, tracked) ---------------------------------
assert "example documents PIPELINE_NEXT_BRANCH" \
  "grep -qE '^[[:space:]]*#?[[:space:]]*PIPELINE_NEXT_BRANCH=' '$EX'"
assert "example documents PIPELINE_NEXT_LABEL" \
  "grep -qE '^[[:space:]]*#?[[:space:]]*PIPELINE_NEXT_LABEL=' '$EX'"

# Overrides-only: both MUST be commented in the example (no live line) so the
# golden-seed set is not forced to grow.
assert "example PIPELINE_NEXT_BRANCH is COMMENTED (overrides-only)" \
  "! grep -qE '^[[:space:]]*PIPELINE_NEXT_BRANCH=' '$EX'"
assert "example PIPELINE_NEXT_LABEL is COMMENTED (overrides-only)" \
  "! grep -qE '^[[:space:]]*PIPELINE_NEXT_LABEL=' '$EX'"

# --- Live host config (gitignored, dogfood host only) ----------------------
if [ -f "$CFG" ]; then
  assert "live pipeline.config documents PIPELINE_NEXT_BRANCH" \
    "grep -qE '^[[:space:]]*#?[[:space:]]*PIPELINE_NEXT_BRANCH=' '$CFG'"
  assert "live pipeline.config documents PIPELINE_NEXT_LABEL" \
    "grep -qE '^[[:space:]]*#?[[:space:]]*PIPELINE_NEXT_LABEL=' '$CFG'"
else
  echo "  SKIP: live pipeline.config PIPELINE_NEXT_* knobs (file gitignored, not present)"
  SKIP=$((SKIP+1))
fi

echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = "0" ]
