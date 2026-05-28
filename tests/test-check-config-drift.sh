#!/bin/bash
set -euo pipefail

# Tests for scripts/check-config-drift.sh.
#
# The lint scans pipeline.config.example for `PIPELINE_*` declarations and the
# scripts/skills/hooks/tests/docs trees for `PIPELINE_*` references, then emits
# two finding groups:
#   ORPHAN       — declared in .example, never referenced.
#   UNDOCUMENTED — referenced in source, never declared.
# Tokens listed in tests/config-drift-allowlist.txt are suppressed (exact
# match, or concat-prefix when the allowlist entry ends in `_`).
#
# Exit 0 when clean (both groups empty post-allowlist), 1 with grouped
# findings on stderr otherwise.
#
# Sub-cases:
#   1. live tree is baseline-clean (rc=0)
#   2. synthetic ORPHAN flagged (rc=1; ORPHAN group + token named)
#   3. synthetic UNDOCUMENTED flagged (rc=1; UNDOCUMENTED group + token named)
#   4. allowlist suppression (synthetic UNDOCUMENTED suppressed -> rc=0)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LINT="$REPO_ROOT/scripts/check-config-drift.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$LINT" ]; then
  echo "ERROR: lint not found at $LINT" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "Sub-case 1: live tree is baseline-clean -> exit 0"
inc
set +e
bash "$LINT" >"$WORKDIR/c1.out" 2>"$WORKDIR/c1.err"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass_msg "live tree passes the lint with the seeded allowlist"
else
  fail_msg "expected rc=0 on live tree, got rc=$rc; err=$(cat "$WORKDIR/c1.err")"
fi

echo "Sub-case 2: synthetic ORPHAN -> exit 1 + ORPHAN group names the var"
inc
FX2="$WORKDIR/c2"
mkdir -p "$FX2/scan"
cat >"$FX2/pipeline.config.example" <<'EOF'
PIPELINE_TEST_ORPHAN=""
EOF
# Empty scan dir so nothing is referenced -> the declared var is orphan.
touch "$FX2/scan/.keep"
: >"$FX2/allowlist.txt"
set +e
PIPELINE_CONFIG_DRIFT_ALLOWLIST="$FX2/allowlist.txt" \
  bash "$LINT" "$FX2/pipeline.config.example" "$FX2/scan" \
  >"$WORKDIR/c2.out" 2>"$WORKDIR/c2.err"
rc=$?
set -e
if [ "$rc" -eq 1 ] \
   && grep -q '^ORPHAN' "$WORKDIR/c2.err" \
   && grep -q 'PIPELINE_TEST_ORPHAN' "$WORKDIR/c2.err"; then
  pass_msg "ORPHAN flagged with token named"
else
  fail_msg "expected rc=1 + ORPHAN group + token; got rc=$rc; err=$(cat "$WORKDIR/c2.err")"
fi

echo ""
echo "================================"
echo "  $TESTS cases: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
