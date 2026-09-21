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
#
# EXAMPLE half vs LIVE half (#1274 scope 7b). The two halves enforce DIFFERENT
# rules and must not be conflated:
#   * EXAMPLE (tracked): a demoted knob may carry NO uncommented line at all,
#     whatever its value — the default is single-sourced at the read site.
#   * LIVE (gitignored, host-specific): the prune rule targets knobs PINNED AT
#     THE DOCUMENTED DEFAULT. A live line that merely repeats the example's
#     commented default is redundant and must go; a deliberate NON-default
#     override is legitimate host configuration (e.g. PIPELINE_USE_LOCAL_PLUGIN=true,
#     required on a --plugin-dir dogfood clone) and must NOT red this guard.
# The documented default is always PARSED from pipeline.config.example, never
# hardcoded, so a future default change cannot silently red the guard.

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

# --- LIVE-half predicate (#1274 scope 7b) ---

# _strip_value <raw> — drop a trailing ` # comment`, surrounding blanks, and one
# layer of surrounding single/double quotes.
_strip_value() {
  local v
  v="$(printf '%s' "$1" | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
  case "$v" in
    \"*\") v="${v#\"}"; v="${v%\"}" ;;
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s' "$v"
}

# example_default <var> — the DOCUMENTED default: value of the FIRST commented
# `#VAR=` line in pipeline.config.example. Empty when undocumented.
example_default() {
  local var="$1" line
  line="$(grep -E "^[[:space:]]*#[[:space:]]*${var}=" "$EXAMPLE" 2>/dev/null | head -n 1)"
  [ -n "$line" ] || return 0
  _strip_value "${line#*=}"
}

# live_value <var> <file> — value of the LAST uncommented `VAR=` line (last-wins,
# matching shell source semantics).
live_value() {
  local var="$1" file="$2" line
  [ -f "$file" ] || return 0
  line="$(grep -E "^[[:space:]]*${var}=" "$file" 2>/dev/null | tail -n 1)"
  [ -n "$line" ] || return 0
  _strip_value "${line#*=}"
}

# live_is_pinned_default <var> <file> — true iff <file> carries a live line for
# <var> AND its value equals the documented default. No live line → false
# (nothing to prune). Undocumented default → false (nothing to compare against).
live_is_pinned_default() {
  local var="$1" file="$2" lv dv
  [ -f "$file" ] || return 1
  grep -Eq "^[[:space:]]*${var}=" "$file" 2>/dev/null || return 1
  lv="$(live_value "$var" "$file")"
  dv="$(example_default "$var")"
  [ -n "$dv" ] && [ "$lv" = "$dv" ]
}

# Asserts a var carries no live line PINNED AT THE DOCUMENTED DEFAULT. LIVE half
# only — the example half keeps the stricter assert_var_not_live.
assert_var_not_live_at_default() {
  local var="$1" file="$2" label="$3"
  inc
  if live_is_pinned_default "$var" "$file"; then
    fail_msg "$label: $var is pinned at the documented default ($(example_default "$var")) — drop the redundant live line in $(basename "$file")"
  else
    pass_msg "$label: $var has no live line pinned at the documented default in $(basename "$file")"
  fi
}

# --- 0. Predicate self-tests: both directions, hermetic fixtures ---
SELFT="$(mktemp -d)"
inc
printf 'PIPELINE_USE_LOCAL_PLUGIN=false\n' > "$SELFT/at-default.config"
if live_is_pinned_default PIPELINE_USE_LOCAL_PLUGIN "$SELFT/at-default.config"; then
  pass_msg "self-test: predicate flags a live line pinned at the documented default"
else
  fail_msg "self-test: predicate failed to flag a live line at the documented default"
fi
inc
printf 'PIPELINE_USE_LOCAL_PLUGIN=true\n' > "$SELFT/override.config"
if live_is_pinned_default PIPELINE_USE_LOCAL_PLUGIN "$SELFT/override.config"; then
  fail_msg "self-test: predicate flagged a deliberate non-default override"
else
  pass_msg "self-test: predicate ignores a deliberate non-default override"
fi
rm -rf "$SELFT"

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

# Live host config: the demoted knobs must not be PINNED AT THE DOCUMENTED
# DEFAULT (a redundant live line). A deliberate non-default override is legal.
# Soft host-only check, no-op in CI.
if [ -f "$LIVE" ]; then
  for var in "${DEMOTED_VARS[@]}"; do
    assert_var_not_live_at_default "$var" "$LIVE" "live"
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
  assert_var_not_live_at_default PIPELINE_CI_FIX_LOOP_ENABLED "$LIVE" "live"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
