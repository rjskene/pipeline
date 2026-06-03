#!/bin/bash
set -uo pipefail

# Guard for issue #835: campaign mode (/pipeline:fullsend --campaign) per-path
# leg caps. Two config vars gate how many issues each campaign leg dispatches:
#   PIPELINE_CAMPAIGN_MAX_BC — max PATH-B/C issues per leg (expensive)
#   PIPELINE_CAMPAIGN_MAX_AD — max PATH-A/D issues per leg (cheap/fast)
#
# Dual-scan per CLAUDE.md: pipeline.config.example is always present;
# pipeline.config is gitignored and host-only (no-op in CI). We assert the
# vars are present in the example unconditionally, and ALSO in the live
# host-only pipeline.config when it exists — but never fail when it's absent.

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

# Asserts the named var appears (commented OR uncommented) in the given file.
check_var_named() {
  local var="$1" file="$2" label="$3"
  inc
  if grep -Eq "^[[:space:]]*#?[[:space:]]*${var}=" "$file"; then
    pass_msg "$label: $var name appears in $(basename "$file")"
  else
    fail_msg "$label: $var name missing from $(basename "$file")"
  fi
}

CAMPAIGN_VARS=(
  PIPELINE_CAMPAIGN_MAX_BC
  PIPELINE_CAMPAIGN_MAX_AD
  PIPELINE_CAMPAIGN_MAX_FOLD
)

# --- Example file: always present ---
for var in "${CAMPAIGN_VARS[@]}"; do
  check_var_named "$var" "$EXAMPLE" "example"
done

# --- Live host-only pipeline.config: only when present (no-op in CI) ---
if [ -f "$LIVE" ]; then
  for var in "${CAMPAIGN_VARS[@]}"; do
    check_var_named "$var" "$LIVE" "live"
  done
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
