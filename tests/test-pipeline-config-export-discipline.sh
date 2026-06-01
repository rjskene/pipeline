#!/bin/bash
set -uo pipefail

# Regression-guard (issue #801): pipeline.config(.example) must export its
# PIPELINE_* assignments so sourced values propagate across process
# boundaries. The auto-merge gate runs in a subshell separate from the bash
# step that sourced the config; a non-exported PIPELINE_BASE_BRANCH was then
# empty in the gate and produced a spurious block-base-mismatch.
#
# Export discipline (per file) PASSES iff EITHER:
#   (a) the file wraps its assignments in a `set -a` ... `set +a` pair with at
#       least one PIPELINE_...= assignment between them, OR
#   (b) every uncommented PIPELINE_...= assignment line is prefixed with
#       `export ` (per-line export — accepts a hand-edited live config).
#
# Dual-scan per CLAUDE.md: pipeline.config.example is always present;
# pipeline.config is gitignored and host-only (no-op in CI when absent).

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

# assert_exports <file> <label>
# PASS if the file uses the set -a/set +a wrapper (style a) OR every
# uncommented PIPELINE_...= assignment is `export`-prefixed (style b).
assert_exports() {
  local file="$1" label="$2"
  inc

  # Style (a): a `set -a` line, a later `set +a` line, and at least one
  # PIPELINE_...= assignment on a line strictly between them.
  local set_a_line set_b_line
  set_a_line="$(grep -nE '^[[:space:]]*set[[:space:]]+-a([[:space:]]|$)' "$file" | head -1 | cut -d: -f1)"
  set_b_line="$(grep -nE '^[[:space:]]*set[[:space:]]+\+a([[:space:]]|$)' "$file" | tail -1 | cut -d: -f1)"
  if [ -n "$set_a_line" ] && [ -n "$set_b_line" ] && [ "$set_a_line" -lt "$set_b_line" ]; then
    if awk -v a="$set_a_line" -v b="$set_b_line" \
         'NR>a && NR<b && /^[[:space:]]*PIPELINE_[A-Za-z0-9_]+=/ {found=1} END{exit !found}' \
         "$file"; then
      pass_msg "$label: set -a/set +a wrapper exports PIPELINE_* assignments"
      return 0
    fi
  fi

  # Style (b): every uncommented PIPELINE_...= assignment is export-prefixed.
  local bad
  bad="$(grep -nE '^[[:space:]]*PIPELINE_[A-Za-z0-9_]+=' "$file" || true)"
  if [ -z "$bad" ]; then
    # No bare (non-export) assignments — either none at all or all exported.
    pass_msg "$label: no bare PIPELINE_* assignments (all export-prefixed or wrapped)"
    return 0
  fi

  fail_msg "$label: bare (non-exported, non-wrapped) PIPELINE_* assignments present — values won't cross process boundaries"
  echo "    offending lines:"
  printf '%s\n' "$bad" | sed 's/^/      /'
  return 1
}

assert_exports "$EXAMPLE" "example"

if [ -f "$LIVE" ]; then
  assert_exports "$LIVE" "live"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
