#!/bin/bash
set -uo pipefail

# Guard against the class of bug fixed in #345 (refactor #315 consolidated
# the mock-web-eval subsystem into mock-web-eval/, leaving pipeline.config
# and pipeline.config.example with stale pre-refactor paths).
#
# After issue #514 removed container isolation entirely, this guard's scope
# narrowed: the container/classifier vars are gone, so there are no path
# assertions left to make against pipeline.config.example. What remains is
# the inline visual-proof loopback surface (PIPELINE_VISUAL_PROOF_TARGET_DIR
# and PIPELINE_VISUAL_PROOF_PORT_BASE) plus negative assertions that the
# deleted container vars do NOT reappear.
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

# --- Issue #514: container vars must be absent ---
#
# Asserts each removed knob has zero occurrences (commented OR uncommented)
# in pipeline.config.example. Scanned in both the example file and the live
# host-only pipeline.config (when present).
assert_var_absent() {
  local var="$1" file="$2" label="$3"
  inc
  if grep -Eq "^[[:space:]]*#?[[:space:]]*${var}=" "$file"; then
    fail_msg "$label: $var still appears in $(basename "$file")"
  else
    pass_msg "$label: $var absent from $(basename "$file")"
  fi
}

REMOVED_VARS=(
  PIPELINE_EVAL_CLASSIFIER
  PIPELINE_EVAL_ISOLATION
  PIPELINE_EVAL_CONTAINERS
  PIPELINE_CONTAINER_SKILLS
)

for var in "${REMOVED_VARS[@]}"; do
  assert_var_absent "$var" "$EXAMPLE" "example"
done

# Wildcard family: PIPELINE_EVAL_CONTAINER_<MODE>_* must not appear at all.
inc
if grep -Eq "^[[:space:]]*#?[[:space:]]*PIPELINE_EVAL_CONTAINER_[A-Za-z0-9_]+_(COMPOSE_FILE|SERVICE|ENV_FILE|PREFLIGHT_CMD|MAX_CONCURRENT)=" "$EXAMPLE"; then
  fail_msg "example: PIPELINE_EVAL_CONTAINER_<MODE>_* family still appears in pipeline.config.example"
else
  pass_msg "example: PIPELINE_EVAL_CONTAINER_<MODE>_* family absent from pipeline.config.example"
fi

if [ -f "$LIVE" ]; then
  for var in "${REMOVED_VARS[@]}"; do
    assert_var_absent "$var" "$LIVE" "live"
  done
  inc
  if grep -Eq "^[[:space:]]*#?[[:space:]]*PIPELINE_EVAL_CONTAINER_[A-Za-z0-9_]+_(COMPOSE_FILE|SERVICE|ENV_FILE|PREFLIGHT_CMD|MAX_CONCURRENT)=" "$LIVE"; then
    fail_msg "live: PIPELINE_EVAL_CONTAINER_<MODE>_* family still appears in pipeline.config"
  else
    pass_msg "live: PIPELINE_EVAL_CONTAINER_<MODE>_* family absent from pipeline.config"
  fi
fi

# --- Issue #517 scaffolding: inline visual-proof loopback vars (preserved) ---
#
# These knobs survive #514's container teardown — the visual-proof loopback
# is the inline-mode replacement for the deleted container surface.
check_var_named() {
  local var="$1"
  inc
  if grep -Eq "^[[:space:]]*#?[[:space:]]*${var}=" "$EXAMPLE"; then
    pass_msg "example: $var name appears in pipeline.config.example"
  else
    fail_msg "example: $var name missing from pipeline.config.example"
  fi
}

check_var_named PIPELINE_VISUAL_PROOF_TARGET_DIR
check_var_named PIPELINE_VISUAL_PROOF_PORT_BASE

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
