#!/bin/bash
set -uo pipefail

# Regression guard for the per-model token-pricing rate keys (issue #721).
#
# scripts/cost-latency-report.sh --tokenomics reads per-model USD rates from
# env vars PIPELINE_PRICE_<MODEL>_<BUCKET> (per-1M-token), defaulting to Opus
# list-price when unset. This guard asserts the four default-Opus keys are
# documented in pipeline.config.example so operators have a copy-paste anchor.
#
# Dual-scan per CLAUDE.md "Configuration conventions": pipeline.config.example
# is always tracked; pipeline.config is gitignored + host-only, so it is only
# scanned when present (its absence is a SKIP-with-pass, never a FAIL).

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

PRICE_KEYS=(
  PIPELINE_PRICE_CLAUDE_OPUS_4_8_INPUT
  PIPELINE_PRICE_CLAUDE_OPUS_4_8_OUTPUT
  PIPELINE_PRICE_CLAUDE_OPUS_4_8_CACHE_CREATION
  PIPELINE_PRICE_CLAUDE_OPUS_4_8_CACHE_READ
  PIPELINE_PRICE_CLAUDE_SONNET_4_6_INPUT
  PIPELINE_PRICE_CLAUDE_SONNET_4_6_OUTPUT
  PIPELINE_PRICE_CLAUDE_SONNET_4_6_CACHE_CREATION
  PIPELINE_PRICE_CLAUDE_SONNET_4_6_CACHE_READ
  PIPELINE_PRICE_CLAUDE_HAIKU_4_5_INPUT
  PIPELINE_PRICE_CLAUDE_HAIKU_4_5_OUTPUT
  PIPELINE_PRICE_CLAUDE_HAIKU_4_5_CACHE_CREATION
  PIPELINE_PRICE_CLAUDE_HAIKU_4_5_CACHE_READ
  # Fable 5 (#1186): the stage-model pins design puts the orchestrator session
  # and PATH C plan on Fable, so Fable records enter the capture stream. Without
  # its own rows Fable prices at the unknown-model Opus fallback. Same
  # commented-anchor shape as the Opus/Sonnet/Haiku blocks above.
  PIPELINE_PRICE_CLAUDE_FABLE_5_INPUT
  PIPELINE_PRICE_CLAUDE_FABLE_5_OUTPUT
  PIPELINE_PRICE_CLAUDE_FABLE_5_CACHE_CREATION
  PIPELINE_PRICE_CLAUDE_FABLE_5_CACHE_READ
)

assert_key_present() {
  local key="$1" file="$2" label="$3"
  inc
  if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}=" "$file"; then
    pass_msg "$label: $key present in $(basename "$file")"
  else
    fail_msg "$label: $key missing from $(basename "$file")"
  fi
}

# --- pipeline.config.example (always present) ---
for key in "${PRICE_KEYS[@]}"; do
  assert_key_present "$key" "$EXAMPLE" "example"
done

# --- pipeline.config (gitignored, host-only): scan only when present ---
if [ -f "$LIVE" ]; then
  for key in "${PRICE_KEYS[@]}"; do
    assert_key_present "$key" "$LIVE" "live"
  done
else
  echo "  SKIP: pipeline.config not present (host-only; not a failure)"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
