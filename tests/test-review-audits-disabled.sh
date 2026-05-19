#!/bin/bash
set -uo pipefail

# When PIPELINE_LOGS_ENABLED is not "true" or runs.log is missing/empty,
# scripts/review-audits.sh must print the canonical disabled-message and exit 0.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/scripts/review-audits.sh"

EXPECTED="Pipeline logging is disabled. To enable, set PIPELINE_LOGS_ENABLED=true in pipeline.config."

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# review-audits.sh resolves REPO_ROOT as "$(dirname "$0")/../.." — to control
# it we copy the script into a fake plugin tree: <proj>/plugin/scripts/<script>
# so that ../.. is <proj>.
setup_proj() {
  local proj="$1"
  rm -rf "$proj"
  mkdir -p "$proj/.claude/logs" "$proj/plugin/scripts"
  cat > "$proj/pipeline.config" <<'EOF'
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="staging"
EOF
  cp "$SCRIPT_UNDER_TEST" "$proj/plugin/scripts/review-audits.sh"
  # Ensure _logging.sh is alongside (sourced by review-audits.sh).
  cp "$REPO_ROOT/scripts/_logging.sh" "$proj/plugin/scripts/_logging.sh"
}

run_case() {
  local desc="$1" logs_enabled="$2" populate="$3"
  inc
  local proj="$WORKDIR/proj-$TESTS"
  setup_proj "$proj"
  if [ "$populate" = "yes" ]; then
    printf '2026-01-01\tsession=abc\tissue=1\tpath=B\tskill=plan-issue\tworktree=/tmp/x\n' \
      > "$proj/.claude/logs/runs.log"
  fi
  local out rc
  out=$(PIPELINE_LOGS_ENABLED="$logs_enabled" \
    bash "$proj/plugin/scripts/review-audits.sh" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail_msg "$desc — expected exit 0, got $rc; output: $out"
    return
  fi
  if [ "$out" != "$EXPECTED" ]; then
    fail_msg "$desc — output mismatch. Got: $out"
    return
  fi
  pass_msg "$desc"
}

echo "== test-review-audits-disabled =="
run_case "logging disabled (unset), runs.log absent"     ""      "no"
run_case "logging disabled (false), runs.log populated"  "false" "yes"
run_case "logging enabled but runs.log absent"           "true"  "no"

echo "Tests: $TESTS  Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
