#!/bin/bash
set -uo pipefail

# Lints skills/run/SKILL.md for the issue-#218 classifier dispatch prose.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$ROOT/skills/run/SKILL.md"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$FILE" ]; then
  echo "ERROR: $FILE not found" >&2
  exit 1
fi

want() {
  local name="$1" pat="$2"
  inc
  if grep -q -- "$pat" "$FILE"; then
    pass_msg "$name"
  else
    fail_msg "$name (pattern not found: $pat)"
  fi
}

want "PIPELINE_EVAL_CLASSIFIER mentioned"          "PIPELINE_EVAL_CLASSIFIER"
want "canonical mode token format"                 "--container-mode="
want "PATH A override prose"                       "container mode overrides PATH A inline"
want "classifier non-zero -> skip prose"           "classifier exit non-zero"

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
