#!/bin/bash
# Guard (#729): model-facing report DEFAULT output must stay JSON-free (markdown
# pipe-tables), while the --emit-rows-json machine contract must stay JSON.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$REPO_ROOT/tests/fixtures/cost-latency-report"
FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS+1)); }
# A "bare JSON line" = first non-space char is { or [ (top-level JSON emission).
has_bare_json() { grep -qE '^[[:space:]]*[\{\[]' ; }

# 1) cost-latency-report DEFAULT + --tokenomics must be JSON-free.
for flags in "" "--tokenomics"; do
  OUT="$(bash "$REPO_ROOT/scripts/cost-latency-report.sh" --fixture "$FIX" $flags 2>/dev/null)"
  if printf '%s\n' "$OUT" | has_bare_json; then
    fail "cost-latency-report ($flags) leaked bare JSON to the model surface"
  else
    pass "cost-latency-report ($flags) model surface is JSON-free"
  fi
done

# 2) over-eval-report + late-error-report DEFAULT must be JSON-free.
for s in over-eval-report late-error-report; do
  OUT="$(bash "$REPO_ROOT/scripts/$s.sh" --fixture "$REPO_ROOT/tests/fixtures/$s" 2>/dev/null)"
  if printf '%s\n' "$OUT" | has_bare_json; then
    fail "$s default output leaked bare JSON"
  else
    pass "$s default output is JSON-free"
  fi
done

# 3) The --emit-rows-json MACHINE contract must REMAIN JSON.
ROWS="$(bash "$REPO_ROOT/scripts/cost-latency-report.sh" --fixture "$FIX" --emit-rows-json 2>/dev/null)"
if printf '%s\n' "$ROWS" | head -1 | has_bare_json && printf '%s' "$ROWS" | jq -e . >/dev/null 2>&1; then
  pass "--emit-rows-json contract still emits valid JSON"
else
  fail "--emit-rows-json contract is no longer valid JSON (parser regression)"
fi

[ "$FAILS" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILS FAIL(S)"; exit 1; }
