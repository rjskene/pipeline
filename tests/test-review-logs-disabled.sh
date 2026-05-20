#!/bin/bash
set -uo pipefail

# When PIPELINE_LOGS_ENABLED is not "true" or the log dir is missing/empty,
# scripts/review-logs.sh must print the canonical disabled-message and exit 0.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/scripts/review-logs.sh"

EXPECTED="Pipeline logging is disabled. To enable, set PIPELINE_LOGS_ENABLED=true in pipeline.config."

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

setup_proj() {
  local proj="$1"
  rm -rf "$proj"
  mkdir -p "$proj/.claude/logs" "$proj/.git"
  cat > "$proj/pipeline.config" <<'EOF'
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="staging"
EOF
}

run_case() {
  local desc="$1" logs_enabled="$2" populate="$3"
  inc
  local proj="$WORKDIR/proj-$TESTS"
  setup_proj "$proj"
  if [ "$populate" = "yes" ]; then
    printf 'x\n' > "$proj/.claude/logs/issue-1-x.log"
  fi
  local out rc
  out=$(PIPELINE_PROJECT_ROOT="$proj" PIPELINE_LOGS_ENABLED="$logs_enabled" \
    bash "$SCRIPT_UNDER_TEST" 2>&1)
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

echo "== test-review-logs-disabled =="
run_case "logging disabled (unset), dir empty"  ""      "no"
run_case "logging disabled (false), dir populated" "false" "yes"
run_case "logging enabled but dir empty"        "true"  "no"

echo "Tests: $TESTS  Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
