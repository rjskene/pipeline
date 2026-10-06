#!/bin/bash
set -uo pipefail

# Guard (issue #1280): the calibration slate driver (scripts/calibration-run.sh)
# reads six env seams. Every one of them must be DOCUMENTED as a commented
# template line in pipeline.config.example so operators can discover the knob
# without reading the script — and so scripts/check-config-drift.sh sees them
# as declared rather than UNDOCUMENTED.
#
# They stay COMMENTED on purpose: `doctor.sh --fix config` seeds only LIVE
# `PIPELINE_*=` lines, so a commented anchor documents the knob without
# pinning today's default into every consumer's live config.
#
# Dual-scan per CLAUDE.md: pipeline.config.example is always present;
# pipeline.config is gitignored and host-only (no-op in CI).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXAMPLE="$ROOT/pipeline.config.example"
LIVE="$ROOT/pipeline.config"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$EXAMPLE" ]; then
  echo "ERROR: $EXAMPLE not found" >&2
  exit 1
fi

# The six seams read by scripts/calibration-run.sh.
CALIB_VARS=(
  PIPELINE_CALIB_REPO
  PIPELINE_CALIB_DIR
  PIPELINE_CALIB_TIMEOUT
  PIPELINE_CALIB_REMOTE
  PIPELINE_CALIB_BASE_TAG
  PIPELINE_CALIB_ISSUE_IDS
)

# --- pipeline.config.example: each knob present and COMMENTED --------------
for var in "${CALIB_VARS[@]}"; do
  inc
  if grep -Eq "^#${var}=" "$EXAMPLE"; then
    pass_msg "example: $var documented as a commented template line"
  else
    fail_msg "example: $var missing a commented '#${var}=' line in pipeline.config.example"
  fi
done

# --- live host-only pipeline.config: knob present, commented OR live -------
if [ -f "$LIVE" ]; then
  for var in "${CALIB_VARS[@]}"; do
    inc
    if grep -Eq "^[[:space:]]*#?[[:space:]]*${var}=" "$LIVE"; then
      pass_msg "live: $var present in pipeline.config"
    else
      fail_msg "live: $var missing from pipeline.config (patch it by hand — the file is gitignored)"
    fi
  done
else
  echo "  SKIP: pipeline.config not present (gitignored host-only file) — live scan skipped"
fi

# --- default cap: 10800s, six-issue slate = three inline execute waves (#1406) ---
SCRIPT="$ROOT/scripts/calibration-run.sh"
inc
if grep -Eq '^#PIPELINE_CALIB_TIMEOUT=10800\b' "$EXAMPLE"; then
  pass_msg "example: PIPELINE_CALIB_TIMEOUT default documented as 10800"
else
  fail_msg "example: PIPELINE_CALIB_TIMEOUT default must be 10800 in pipeline.config.example"
fi

inc
if grep -Eq 'CALIB_TIMEOUT="\$\{PIPELINE_CALIB_TIMEOUT:-10800\}"' "$SCRIPT"; then
  pass_msg "calibration-run.sh: PIPELINE_CALIB_TIMEOUT default is 10800"
else
  fail_msg "calibration-run.sh: PIPELINE_CALIB_TIMEOUT default must be 10800"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

if [ "$FAIL" -eq 0 ]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL"
  exit 1
fi
