#!/usr/bin/env bash
# run-test-suite.sh — parallel test runner with STRICT aggregate fail.
#
# Fans tests/test*.sh + tests/test_*.sh across cores via `xargs -P`. xargs masks
# child exit codes by default (and `--halt` semantics on high exit codes like 250
# are unreliable across xargs builds), so each child writes a marker line to a
# shared mktemp SENTINEL file on failure; after the fan-out we exit non-zero iff
# the sentinel is non-empty. This guarantees strict fail survives even for
# high/128+ exit codes (issue #897 acceptance bar).
#
# Usage:
#   scripts/run-test-suite.sh [tests-dir]
#   TESTS_DIR=path scripts/run-test-suite.sh
#   PIPELINE_TEST_PARALLELISM=N scripts/run-test-suite.sh   # override -P
#
# Each test is wrapped in `timeout 300` and `</dev/null` (mirrors the live
# runner's hang-guard so an interactive `read` or a hang can't wedge a job).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# tests dir: $1 > TESTS_DIR env > default "tests" (resolved under REPO_ROOT).
TESTS_DIR="${1:-${TESTS_DIR:-tests}}"
case "$TESTS_DIR" in
  /*) : ;;                          # absolute — use as-is
  *)  TESTS_DIR="$REPO_ROOT/$TESTS_DIR" ;;
esac

if [ ! -d "$TESTS_DIR" ]; then
  echo "run-test-suite.sh: tests dir not found: $TESTS_DIR" >&2
  exit 1
fi

# Parallelism: explicit override, else core count, else 1.
PAR="${PIPELINE_TEST_PARALLELISM:-}"
if [ -z "$PAR" ]; then
  PAR="$(nproc 2>/dev/null || echo 1)"
fi

SENTINEL="$(mktemp)"
export SENTINEL

# Per-file worker — exported so xargs-spawned bash subshells can call it.
# Folds the Actions log per file (::group::/::endgroup::) and records any
# failure (including high exit codes) into the shared sentinel file.
run_one() {
  local t="$1"
  [ -f "$t" ] || return 0
  echo "::group::$t"
  local rc=0
  timeout 300 bash "$t" </dev/null || rc=$?
  echo "::endgroup::"
  if [ "$rc" -ne 0 ]; then
    echo "FAIL rc=$rc $t" >> "$SENTINEL"
    echo "::error::$t failed (exit $rc)"
  fi
}
export -f run_one

# Enumerate matching test files (NUL-delimited to survive odd names) and fan out.
# Disable the failglob/nullglob surprises by checking existence in run_one.
find "$TESTS_DIR" -maxdepth 1 -type f \
  \( -name 'test*.sh' -o -name 'test_*.sh' \) -print0 \
  | sort -z \
  | xargs -0 -P "$PAR" -I{} bash -c 'run_one "$@"' _ {}

if [ -s "$SENTINEL" ]; then
  echo "" >&2
  echo "================ FAILURES ================" >&2
  cat "$SENTINEL" >&2
  echo "=========================================" >&2
  rm -f "$SENTINEL"
  exit 1
fi

rm -f "$SENTINEL"
exit 0
