#!/bin/bash
set -uo pipefail

# Regression guard for #1132: pipeline.config.example must document the
# parallel local full-suite form (PIPELINE_TEST_CMD='bash scripts/run-test-suite.sh')
# with a #1132 cross-reference.
#
# Why: the local serial `for t in tests/test*.sh` loop is what exceeds the
# agent's 10-minute Bash-tool timeout (361 sequential test files), forcing the
# executor/green/PR-eval stages to verify an affected-tests-only subset and lean
# on CI as the full-suite gate (the failure class #1132 addresses). The bundled
# parallel runner (scripts/run-test-suite.sh) fits the agent Bash budget while
# preserving STRICT aggregate fail. Per CLAUDE.md "Configuration conventions"
# the live pipeline.config is gitignored and patched by hand on the host, so the
# tracked surface a PR lands on is pipeline.config.example + this guard.
#
# Modeled on tests/test-pipeline-config-mock-web-eval-paths.sh.
#
# Dual-scan per CLAUDE.md: pipeline.config.example is always present;
# pipeline.config is gitignored and host-only (no-op in CI).
#
# Assertions:
#   1. example: the parallel-runner invocation `scripts/run-test-suite.sh`
#      appears in pipeline.config.example.
#   2. example: the parallel-runner note carries a #1132 cross-reference.
#   3. live (host-only, if present): same `scripts/run-test-suite.sh` mention.
#   4. live (host-only, if present): same #1132 cross-reference.

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

# --- Assertion 1: example documents the parallel runner ---
inc
if grep -qF "scripts/run-test-suite.sh" "$EXAMPLE"; then
  pass_msg "example: scripts/run-test-suite.sh parallel form documented in pipeline.config.example"
else
  fail_msg "example: scripts/run-test-suite.sh parallel form missing from pipeline.config.example"
fi

# --- Assertion 2: example carries a #1132 cross-reference ---
inc
if grep -qF "#1132" "$EXAMPLE"; then
  pass_msg "example: pipeline.config.example carries a #1132 cross-reference"
else
  fail_msg "example: pipeline.config.example missing #1132 cross-reference for the parallel-runner note"
fi

# --- Assertions 3 & 4: live host-only config (gitignored; no-op in CI) ---
if [ -f "$LIVE" ]; then
  inc
  if grep -qF "scripts/run-test-suite.sh" "$LIVE"; then
    pass_msg "live: scripts/run-test-suite.sh parallel form documented in pipeline.config"
  else
    fail_msg "live: scripts/run-test-suite.sh parallel form missing from pipeline.config (hand-apply per CLAUDE.md)"
  fi

  inc
  if grep -qF "#1132" "$LIVE"; then
    pass_msg "live: pipeline.config carries a #1132 cross-reference"
  else
    fail_msg "live: pipeline.config missing #1132 cross-reference (hand-apply per CLAUDE.md)"
  fi
else
  echo "  NOTE: live pipeline.config absent (gitignored, host-only) — live assertions skipped"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
