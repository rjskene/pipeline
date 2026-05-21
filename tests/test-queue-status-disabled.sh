#!/bin/bash
set -uo pipefail

# When PIPELINE_LOGS_ENABLED is not "true" OR no queue-*.log files exist,
# scripts/queue-status.sh must print the canonical disabled-message and exit 0.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/scripts/queue-status.sh"

EXPECTED="No queue runs found. (PIPELINE_LOGS_ENABLED=false)"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# queue-status.sh resolves REPO_ROOT as ../.. — copy into a fake plugin tree.
setup_proj() {
  local proj="$1"
  rm -rf "$proj"
  mkdir -p "$proj/.claude/logs" "$proj/plugin/scripts" "$proj/.git"
  cat > "$proj/pipeline.config" <<'EOF'
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_TMUX_SESSION="dev"
EOF
  cp "$SCRIPT_UNDER_TEST" "$proj/plugin/scripts/queue-status.sh"
  cp "$REPO_ROOT/scripts/_logging.sh" "$proj/plugin/scripts/_logging.sh"
}

run_case() {
  local desc="$1" logs_enabled="$2" populate="$3"
  inc
  local proj="$WORKDIR/proj-$TESTS"
  setup_proj "$proj"
  if [ "$populate" = "yes" ]; then
    printf 'Launching agent for issue #1 (slug)\n' \
      > "$proj/.claude/logs/queue-2026-01-01.log"
  fi
  local out rc
  out=$(PIPELINE_LOGS_ENABLED="$logs_enabled" \
    bash "$proj/plugin/scripts/queue-status.sh" 2>&1)
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

echo "== test-queue-status-disabled =="
run_case "logging disabled (unset), no queue logs"        ""      "no"
run_case "logging disabled (false), queue log present"    "false" "yes"
run_case "logging enabled but no queue logs"              "true"  "no"

echo "Tests: $TESTS  Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
