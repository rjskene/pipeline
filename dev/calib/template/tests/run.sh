#!/usr/bin/env bash
#
# run.sh — the whole test suite. Runs every tests/case-*.sh file in sorted
# order and exits non-zero if any of them fails.
#
#   bash tests/run.sh              # everything
#   bash tests/run.sh case-auth    # only cases whose name matches
#
set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
FILTER="${1:-}"

TOTAL=0
FAILED=0
FAILED_NAMES=()

for case_file in "$TEST_DIR"/case-*.sh; do
  [ -f "$case_file" ] || continue
  name="$(basename "$case_file" .sh)"
  if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then
    continue
  fi
  TOTAL=$((TOTAL + 1))
  echo "RUN  $name"
  if bash "$case_file"; then
    echo "PASS $name"
  else
    echo "FAIL $name"
    FAILED=$((FAILED + 1))
    FAILED_NAMES+=("$name")
  fi
done

echo
if [ "$TOTAL" -eq 0 ]; then
  echo "no test cases matched '${FILTER}'"
  exit 1
fi

echo "$((TOTAL - FAILED))/$TOTAL case files passed"
if [ "$FAILED" -ne 0 ]; then
  echo "failed: ${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
