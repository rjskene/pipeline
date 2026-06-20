#!/bin/bash
set -uo pipefail

# Regression guard for the #762 config prune (issue #857).
#
# Two distinct prune operations are pinned here:
#
#   1. STALE REMOVAL — PIPELINE_FRONTEND_PORT_OFFSET has zero readers repo-wide
#      (the frontend port lives in check-server.sh's positional ${2:-5173} and
#      visual-proof in PIPELINE_VISUAL_PROOF_PORT_BASE). It is fully removed,
#      not demoted: it must NOT appear (commented OR uncommented) in
#      pipeline.config.example, nor in the live host pipeline.config, nor in
#      the greenfield generator scripts/init.sh.
#
#   2. DEFAULT-EQUAL DEMOTION — 14 knobs whose .example value exactly equals
#      their read-site shell fallback (${VAR:-default}) are demoted from live
#      lines to commented escape-hatches: the uncommented assignment is gone
#      (default single-sourced at the read site) but the var name survives in a
#      commented form so it stays discoverable. Mirrors the Sonnet/Haiku price
#      block precedent (#PIPELINE_PRICE_CLAUDE_SONNET_..._INPUT=3).
#
# CI TOGGLES: PIPELINE_CI_CHECK_ENABLED stays live + uncommented (the #762 KEEP holds;
# NOT in the #1052 reclassify set). PIPELINE_CI_FIX_LOOP_ENABLED was the other #762 KEEP,
# but #1052 (defaults-in-code) is the reconciliation the original "until #858 reconciles
# them" caveat anticipated: its "true" default is now single-sourced at the colon-less
# ${VAR-true} read site (semantics unchanged, NOT flipped off), so it is demoted to a
# COMMENTED escape-hatch here (no longer live) — see section 3 below.
#
# Dual-scan per CLAUDE.md: pipeline.config.example is always present;
# pipeline.config is gitignored and host-only (no-op in CI). All $LIVE
# assertions are gated behind [ -f "$LIVE" ] and are a soft host-only check —
# the operator must hand-patch the live config alongside this PR.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXAMPLE="$ROOT/pipeline.config.example"
LIVE="$ROOT/pipeline.config"
INIT="$ROOT/scripts/init.sh"

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

# Asserts a var has zero occurrences (commented OR uncommented) in a file.
assert_var_absent() {
  local var="$1" file="$2" label="$3"
  inc
  if grep -Eq "^[[:space:]]*#?[[:space:]]*${var}=" "$file"; then
    fail_msg "$label: $var still appears in $(basename "$file")"
  else
    pass_msg "$label: $var absent from $(basename "$file")"
  fi
}

# Asserts a var has NO uncommented assignment in a file (it may still appear
# in commented form).
assert_var_not_live() {
  local var="$1" file="$2" label="$3"
  inc
  if grep -Eq "^[[:space:]]*${var}=" "$file"; then
    fail_msg "$label: $var is still an uncommented (live) line in $(basename "$file")"
  else
    pass_msg "$label: $var has no live (uncommented) line in $(basename "$file")"
  fi
}

# Asserts a var appears in a commented form (discoverable escape-hatch).
assert_var_commented_present() {
  local var="$1" file="$2" label="$3"
  inc
  if grep -Eq "^[[:space:]]*#[[:space:]]*${var}=" "$file"; then
    pass_msg "$label: $var survives as a commented escape-hatch in $(basename "$file")"
  else
    fail_msg "$label: $var missing as a commented line in $(basename "$file")"
  fi
}

# Asserts a var IS present as an uncommented (live) line.
assert_var_live() {
  local var="$1" file="$2" label="$3"
  inc
  if grep -Eq "^[[:space:]]*${var}=" "$file"; then
    pass_msg "$label: $var is a live (uncommented) line in $(basename "$file")"
  else
    fail_msg "$label: $var is NOT a live (uncommented) line in $(basename "$file")"
  fi
}

# --- 1. STALE REMOVAL: PIPELINE_FRONTEND_PORT_OFFSET ---
assert_var_absent PIPELINE_FRONTEND_PORT_OFFSET "$EXAMPLE" "example"
if [ -f "$INIT" ]; then
  assert_var_absent PIPELINE_FRONTEND_PORT_OFFSET "$INIT" "init.sh"
fi
if [ -f "$LIVE" ]; then
  assert_var_absent PIPELINE_FRONTEND_PORT_OFFSET "$LIVE" "live"
fi

# --- 2. DEFAULT-EQUAL DEMOTION: 14 knobs -> commented escape-hatches ---
DEMOTED_VARS=(
  PIPELINE_RELEASE_PR_AUTO_MERGE
  PIPELINE_CAMPAIGN_MAX_BC
  PIPELINE_CAMPAIGN_MAX_AD
  PIPELINE_FULL_SEND_WAVE_PLANNING_ENABLED
  PIPELINE_GROUPING_DETECTION_ENABLED
  PIPELINE_STALL_POLL_THRESHOLD
  PIPELINE_STALL_FORWARD_PROGRESS_GATE
  PIPELINE_EXECUTOR_REAP_GRACE_POLLS
  PIPELINE_REAP_SIGKILL_GRACE_SEC
  PIPELINE_EXECUTOR_TIMEOUT_SECONDS
  PIPELINE_VISUAL_PROOF_PORT_BASE
  PIPELINE_CI_FIX_RETRY_BUDGET
  PIPELINE_CI_FIX_LOG_LINES
  PIPELINE_USE_LOCAL_PLUGIN
)

for var in "${DEMOTED_VARS[@]}"; do
  assert_var_not_live "$var" "$EXAMPLE" "example"
  assert_var_commented_present "$var" "$EXAMPLE" "example"
done

# Live host config: the demoted knobs must also be hand-patched to commented
# form (no uncommented assignment). Soft host-only check, no-op in CI.
if [ -f "$LIVE" ]; then
  for var in "${DEMOTED_VARS[@]}"; do
    assert_var_not_live "$var" "$LIVE" "live"
  done
fi

# --- 3. CI toggles ---
# PIPELINE_CI_CHECK_ENABLED stays live + uncommented (NOT in the #1052 reclassify set).
# PIPELINE_CI_FIX_LOOP_ENABLED was reclassified by #1052 (defaults-in-code): the #858
# doc-vs-code reconciliation anticipated by the original #857 KEEP guard. Its "true"
# default is single-sourced at the colon-less ${VAR-true} read site, so it is now a
# COMMENTED escape-hatch (not seeded by --fix config), like the DEMOTED_VARS above.
assert_var_live PIPELINE_CI_CHECK_ENABLED "$EXAMPLE" "example"
assert_var_not_live PIPELINE_CI_FIX_LOOP_ENABLED "$EXAMPLE" "example"
assert_var_commented_present PIPELINE_CI_FIX_LOOP_ENABLED "$EXAMPLE" "example"
if [ -f "$LIVE" ]; then
  assert_var_not_live PIPELINE_CI_FIX_LOOP_ENABLED "$LIVE" "live"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
