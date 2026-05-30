#!/bin/bash
set -uo pipefail

# Regression guard for issue #677: the executor's verification phase must not
# run an unbounded, unguarded `for t in tests/test*.sh` sweep that can hang on
# an interactive `read` or collide with a concurrent copy of itself.
#
# Two halves, dual-scan per CLAUDE.md (config-split convention):
#   1. pipeline.config.example (always present) MUST carry a comment near
#      PIPELINE_TEST_CMD documenting the single-pass + </dev/null + timeout +
#      no-unbounded-sweep contract, so a consumer's own PIPELINE_TEST_CMD
#      inherits the guidance.
#   2. The live, gitignored, host-only pipeline.config (no-op in CI when
#      absent) MUST NOT define PIPELINE_TEST_CMD as an unbounded
#      `for t in tests/test*.sh`/`tests/test_*.sh` sweep that lacks BOTH
#      </dev/null and timeout. The operator hand-patches the live file
#      (see the PR body); the PR itself cannot ship that gitignored edit.
#
# Modeled on tests/test-pipeline-config-mock-web-eval-paths.sh.

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

# --- Half 1: pipeline.config.example carries the stdin/timeout/single-pass annotation ---
echo "Case A: pipeline.config.example documents the single-pass stdin/timeout contract"
inc
if grep -q '/dev/null' "$EXAMPLE" \
   && grep -qi 'timeout' "$EXAMPLE" \
   && grep -qiE 'single|sequential' "$EXAMPLE" \
   && grep -qiE 'for t in tests/test|unbounded' "$EXAMPLE"; then
  pass_msg "example annotates PIPELINE_TEST_CMD with </dev/null + timeout + single-pass + no-unbounded-sweep"
else
  fail_msg "pipeline.config.example must document: single/sequential pass, </dev/null, timeout, avoid unbounded 'for t in tests/test' sweep"
fi

# --- Half 2: live host-only pipeline.config must not carry an unguarded sweep ---
echo "Case B: live pipeline.config PIPELINE_TEST_CMD is not an unguarded unbounded sweep"
inc
if [ ! -f "$LIVE" ]; then
  pass_msg "live pipeline.config absent (CI) — no-op"
else
  TEST_CMD_LINE="$(grep -E '^[[:space:]]*PIPELINE_TEST_CMD=' "$LIVE" || true)"
  if echo "$TEST_CMD_LINE" | grep -qE 'for t in tests/test\*\.sh|for t in tests/test_\*\.sh'; then
    # It IS a for-t sweep — require BOTH </dev/null and timeout.
    if echo "$TEST_CMD_LINE" | grep -q '</dev/null' \
       && echo "$TEST_CMD_LINE" | grep -qi 'timeout'; then
      pass_msg "live PIPELINE_TEST_CMD sweep is guarded with </dev/null + timeout"
    else
      fail_msg "live PIPELINE_TEST_CMD is an unbounded 'for t in tests/test*.sh' sweep lacking </dev/null and/or timeout — hand-patch pipeline.config (see PR body, issue #677)"
    fi
  else
    pass_msg "live PIPELINE_TEST_CMD is not an unbounded for-t sweep"
  fi
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
