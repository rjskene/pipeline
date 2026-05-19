#!/bin/bash
set -uo pipefail

# Tests for the mock-web-eval probe-port script honoring PIPELINE_WORKTREE_PATH
# and PIPELINE_PROJECT_ROOT (issue #257 Bug 1, Fix 1). The probe must write the
# env file to the per-worktree path when PIPELINE_WORKTREE_PATH is set, fall
# back to PIPELINE_PROJECT_ROOT otherwise, and finally to its self-derived
# REPO_ROOT.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/../mock-web-eval/scripts/mock-web-eval-probe-port.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SCRIPT_UNDER_TEST" ]; then
  echo "ERROR: script under test not found at $SCRIPT_UNDER_TEST" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/.git" "$PROJ/scripts" "$PROJ/mock-web-eval/scripts"
cp "$SCRIPT_UNDER_TEST" "$PROJ/mock-web-eval/scripts/mock-web-eval-probe-port.sh"
chmod +x "$PROJ/mock-web-eval/scripts/mock-web-eval-probe-port.sh"

WT="$PROJ/.claude/worktrees/wt-test"
mkdir -p "$WT"

# --- Case A: both env vars set -> env file under WT ---------------------
echo "Case A: PIPELINE_WORKTREE_PATH + PIPELINE_PROJECT_ROOT both set"
inc
# Clean any prior copies that may pre-exist from earlier failed runs.
rm -f "$WT/mock-web-eval/target/.env.mock-web-eval" "$PROJ/mock-web-eval/target/.env.mock-web-eval"
PIPELINE_PROJECT_ROOT="$PROJ" PIPELINE_WORKTREE_PATH="$WT" \
  bash "$PROJ/mock-web-eval/scripts/mock-web-eval-probe-port.sh" >/dev/null 2>&1
caseA_rc=$?
expected_a="$WT/mock-web-eval/target/.env.mock-web-eval"
if [ "$caseA_rc" -ne 0 ]; then
  fail_msg "Case A: probe exited rc=$caseA_rc"
elif [ ! -f "$expected_a" ]; then
  fail_msg "Case A: expected env file at $expected_a, not present"
  echo "    PROJ env file present? $( [ -f "$PROJ/mock-web-eval/target/.env.mock-web-eval" ] && echo yes || echo no)"
elif [ -f "$PROJ/mock-web-eval/target/.env.mock-web-eval" ]; then
  fail_msg "Case A: env file unexpectedly also written to PROJ root"
else
  body_wt="$(grep '^PIPELINE_WORKTREE_PATH=' "$expected_a" | head -1 | sed 's/^PIPELINE_WORKTREE_PATH=//')"
  body_pr="$(grep '^PIPELINE_PROJECT_ROOT='  "$expected_a" | head -1 | sed 's/^PIPELINE_PROJECT_ROOT=//')"
  if [ "$body_wt" != "$WT" ]; then
    fail_msg "Case A: env body PIPELINE_WORKTREE_PATH='$body_wt' != '$WT'"
  elif [ "$body_pr" != "$PROJ" ]; then
    fail_msg "Case A: env body PIPELINE_PROJECT_ROOT='$body_pr' != '$PROJ'"
  else
    pass_msg "Case A: env file at $expected_a with correct body"
  fi
fi

# --- Case B: only PROJECT_ROOT set -> env file under PROJ ---------------
echo "Case B: only PIPELINE_PROJECT_ROOT set"
inc
rm -f "$WT/mock-web-eval/target/.env.mock-web-eval" "$PROJ/mock-web-eval/target/.env.mock-web-eval"
env -u PIPELINE_WORKTREE_PATH PIPELINE_PROJECT_ROOT="$PROJ" \
  bash "$PROJ/mock-web-eval/scripts/mock-web-eval-probe-port.sh" >/dev/null 2>&1
caseB_rc=$?
expected_b="$PROJ/mock-web-eval/target/.env.mock-web-eval"
if [ "$caseB_rc" -ne 0 ]; then
  fail_msg "Case B: probe exited rc=$caseB_rc"
elif [ ! -f "$expected_b" ]; then
  fail_msg "Case B: expected env file at $expected_b, not present"
elif [ -f "$WT/mock-web-eval/target/.env.mock-web-eval" ]; then
  fail_msg "Case B: env file unexpectedly also written to WT path"
else
  body_pr="$(grep '^PIPELINE_PROJECT_ROOT='  "$expected_b" | head -1 | sed 's/^PIPELINE_PROJECT_ROOT=//')"
  if [ "$body_pr" != "$PROJ" ]; then
    fail_msg "Case B: env body PIPELINE_PROJECT_ROOT='$body_pr' != '$PROJ'"
  else
    pass_msg "Case B: env file at $expected_b with correct body"
  fi
fi

# --- Case C: neither set -> env file at script-derived REPO_ROOT --------
# Since the script lives at $PROJ/mock-web-eval/scripts/, its derived REPO_ROOT is $PROJ.
echo "Case C: neither env var set -> script-derived REPO_ROOT"
inc
rm -f "$WT/mock-web-eval/target/.env.mock-web-eval" "$PROJ/mock-web-eval/target/.env.mock-web-eval"
env -u PIPELINE_WORKTREE_PATH -u PIPELINE_PROJECT_ROOT \
  bash "$PROJ/mock-web-eval/scripts/mock-web-eval-probe-port.sh" >/dev/null 2>&1
caseC_rc=$?
expected_c="$PROJ/mock-web-eval/target/.env.mock-web-eval"
if [ "$caseC_rc" -ne 0 ]; then
  fail_msg "Case C: probe exited rc=$caseC_rc"
elif [ ! -f "$expected_c" ]; then
  fail_msg "Case C: expected env file at $expected_c, not present"
else
  pass_msg "Case C: env file at $expected_c"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
