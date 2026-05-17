#!/bin/bash
set -uo pipefail

# Lints pipeline.config.example for the issue-#218 documentation surface:
# classifier hook + container-mode declaration + per-mode knobs + canonical
# token format prose.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$ROOT/pipeline.config.example"

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

want "PIPELINE_EVAL_CLASSIFIER documented"        "PIPELINE_EVAL_CLASSIFIER="
want "PIPELINE_EVAL_CONTAINERS documented"        "PIPELINE_EVAL_CONTAINERS="
want "per-mode COMPOSE_FILE example"              "PIPELINE_EVAL_CONTAINER_web_eval_COMPOSE_FILE="
want "per-mode MAX_CONCURRENT example"            "PIPELINE_EVAL_CONTAINER_web_eval_MAX_CONCURRENT="
want "canonical token format prose"               "--container-mode="

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
