#!/usr/bin/env bash
# run-all.sh — runs every dev/tests/test-*.sh in sequence; non-zero on any failure.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0
for t in "$HERE"/test-*.sh; do
  [ -f "$t" ] || continue
  echo "::group::$t"
  bash "$t" || fail=1
  echo "::endgroup::"
done
exit "$fail"
