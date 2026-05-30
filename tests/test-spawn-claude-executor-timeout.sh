#!/bin/bash
set -uo pipefail
# Regression guard for issue #656: the executor safety-net timeout in
# scripts/spawn-claude.sh must be sourced from the PIPELINE_EXECUTOR_TIMEOUT_SECONDS
# config knob (default 5400), not hardcoded. Before #656 the tmux-mode CMD line
# was: timeout --foreground --signal=TERM --kill-after=30 5400 $INNER — a heavy
# PATH C could finish green but be SIGTERM'd before the PR step (observed #642).
#
# Dual-scan per CLAUDE.md: pipeline.config.example is always present;
# pipeline.config is gitignored and host-only (skipped when absent).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPAWN="$ROOT/scripts/spawn-claude.sh"
EXAMPLE="$ROOT/pipeline.config.example"
LIVE="$ROOT/pipeline.config"
PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

[ -f "$SPAWN" ]   || { echo "ERROR: $SPAWN not found" >&2; exit 1; }
[ -f "$EXAMPLE" ] || { echo "ERROR: $EXAMPLE not found" >&2; exit 1; }

# 1. The bare hardcoded literal in the timeout CMD line must be gone.
inc
if grep -Eq 'kill-after=30[[:space:]]+5400[[:space:]]' "$SPAWN"; then
  fail_msg "spawn-claude.sh still hardcodes 'kill-after=30 5400' in the timeout CMD line"
else
  pass_msg "spawn-claude.sh no longer hardcodes the 5400 timeout literal"
fi

# 2. The timeout CMD line must reference the resolved ${EXECUTOR_TIMEOUT} var.
inc
if grep -Eq 'timeout .*kill-after=30 \$\{EXECUTOR_TIMEOUT\}' "$SPAWN"; then
  pass_msg "spawn-claude.sh timeout CMD line references \${EXECUTOR_TIMEOUT}"
else
  fail_msg "spawn-claude.sh timeout CMD line does not reference \${EXECUTOR_TIMEOUT}"
fi

# 3. EXECUTOR_TIMEOUT must be defined from the knob with a :-5400 default.
inc
if grep -Eq 'EXECUTOR_TIMEOUT="\$\{PIPELINE_EXECUTOR_TIMEOUT_SECONDS:-5400\}"' "$SPAWN"; then
  pass_msg "spawn-claude.sh derives EXECUTOR_TIMEOUT from the knob with a 5400 default"
else
  fail_msg "spawn-claude.sh does not derive EXECUTOR_TIMEOUT from PIPELINE_EXECUTOR_TIMEOUT_SECONDS (default 5400)"
fi

# 4. The knob must be documented in pipeline.config.example (always present).
inc
if grep -Eq '^[[:space:]]*#?[[:space:]]*PIPELINE_EXECUTOR_TIMEOUT_SECONDS=' "$EXAMPLE"; then
  pass_msg "example: PIPELINE_EXECUTOR_TIMEOUT_SECONDS documented in pipeline.config.example"
else
  fail_msg "example: PIPELINE_EXECUTOR_TIMEOUT_SECONDS missing from pipeline.config.example"
fi
inc
if grep -Eq 'PIPELINE_EXECUTOR_TIMEOUT_SECONDS=.*5400' "$EXAMPLE"; then
  pass_msg "example: PIPELINE_EXECUTOR_TIMEOUT_SECONDS default 5400 visible"
else
  fail_msg "example: PIPELINE_EXECUTOR_TIMEOUT_SECONDS default 5400 not visible"
fi

# 5. Dual-scan: the gitignored live pipeline.config (host-only) must not
#    regress a bare hardcoded 5400 timeout literal (no-op when absent in CI).
if [ -f "$LIVE" ]; then
  inc
  if grep -Eq 'kill-after=30[[:space:]]+5400[[:space:]]' "$LIVE"; then
    fail_msg "live: pipeline.config hardcodes a 5400 timeout literal"
  else
    pass_msg "live: pipeline.config has no hardcoded 5400 timeout literal"
  fi
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
