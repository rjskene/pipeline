#!/bin/bash
set -uo pipefail

# Regression test for run-queue.sh's bucket_max() (#336). Proves the live
# function in run-queue.sh resolves PIPELINE_EVAL_CONTAINER_<MODE>_MAX_CONCURRENT
# with UPPERCASE-wins precedence and lowercase-fallback.
#
# Cannot reuse test-run-queue-partitioning.sh (which stubs spawn-claude),
# and cannot trivially source run-queue.sh wholesale (it has top-level
# side effects: consumes $@, enters a poll loop). Instead we extract the
# live bucket_max definition with sed, source the helper, and exercise it
# in a controlled subshell.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_QUEUE="$SCRIPT_DIR/../scripts/run-queue.sh"
HELPER="$SCRIPT_DIR/../scripts/_resolve-container-var.sh"

if [ ! -f "$RUN_QUEUE" ]; then
  echo "ERROR: run-queue.sh not found at $RUN_QUEUE" >&2
  exit 1
fi
if [ ! -f "$HELPER" ]; then
  echo "ERROR: _resolve-container-var.sh not found at $HELPER" >&2
  exit 1
fi

# Extract the live bucket_max() definition. The sed range captures from
# `bucket_max() {` to the next bare `}` line — keep run-queue.sh's
# formatting (function brace on opener line, lone `}` to close) intact
# or this will fail loudly.
BUCKET_DEF=$(sed -n '/^bucket_max() {$/,/^}$/p' "$RUN_QUEUE")
if [ -z "$BUCKET_DEF" ]; then
  echo "ERROR: failed to extract bucket_max() from $RUN_QUEUE" >&2
  exit 1
fi

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

# call_bucket_max <mode> <env-export-commands>
#
# Invokes the LIVE bucket_max function (extracted from run-queue.sh) in a
# clean subshell with a controlled env. The helper is sourced beforehand
# so bucket_max can call _resolve_container_var.
call_bucket_max() {
  local mode="$1"; shift
  env -i HELPER="$HELPER" BUCKET_DEF="$BUCKET_DEF" bash -c '
    set -u
    '"$*"'
    MAX_CONCURRENT=10
    . "$HELPER"
    eval "$BUCKET_DEF"
    bucket_max "'"$mode"'"
  '
}

# Test 1: UPPERCASE env var resolves.
echo "Test 1: bucket_max(web-eval) with PIPELINE_EVAL_CONTAINER_WEB_EVAL_MAX_CONCURRENT=3"
inc
out=$(call_bucket_max web-eval 'export PIPELINE_EVAL_CONTAINER_WEB_EVAL_MAX_CONCURRENT=3')
if [ "$out" = "3" ]; then
  pass_msg "got 3"
else
  fail_msg "expected 3, got $out"
fi

# Test 2: lowercase env var still resolves (back-compat).
echo "Test 2: bucket_max(web-eval) with PIPELINE_EVAL_CONTAINER_web_eval_MAX_CONCURRENT=5 (lowercase)"
inc
out=$(call_bucket_max web-eval 'export PIPELINE_EVAL_CONTAINER_web_eval_MAX_CONCURRENT=5')
if [ "$out" = "5" ]; then
  pass_msg "got 5"
else
  fail_msg "expected 5, got $out"
fi

# Test 3: UPPERCASE wins precedence when both set.
echo "Test 3: bucket_max(web-eval) with both cases set -> UPPERCASE wins"
inc
out=$(call_bucket_max web-eval 'export PIPELINE_EVAL_CONTAINER_WEB_EVAL_MAX_CONCURRENT=7; export PIPELINE_EVAL_CONTAINER_web_eval_MAX_CONCURRENT=11')
if [ "$out" = "7" ]; then
  pass_msg "got 7 (UPPERCASE wins)"
else
  fail_msg "expected 7, got $out"
fi

# Test 4: unset returns default 1.
echo "Test 4: bucket_max(web-eval) with no env var set -> default 1"
inc
out=$(call_bucket_max web-eval '')
if [ "$out" = "1" ]; then
  pass_msg "got 1 (default)"
else
  fail_msg "expected 1, got $out"
fi

# Test 5: bare mode returns MAX_CONCURRENT (10 in our harness).
echo "Test 5: bucket_max(bare) -> MAX_CONCURRENT"
inc
out=$(call_bucket_max bare '')
if [ "$out" = "10" ]; then
  pass_msg "got 10 (MAX_CONCURRENT)"
else
  fail_msg "expected 10, got $out"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
