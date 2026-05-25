#!/bin/bash
set -uo pipefail
# Per #492: regression guard (defense-in-depth). The phrase `enumerates each`
# implied per-sub-commit CHANGELOG granularity, which contradicts the per-PR
# granularity contract documented in
# docs/release-cadence.md#granularity-scope-decision-492. This test asserts the
# contradictory phrasing cannot silently return to either doc — if a future
# copy-edit reintroduces it, this guard breaks loudly.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Sum per-file `grep -c` counts into a single total (grep -c prints `file:count`).
count="$(cd "$REPO_ROOT" && grep -c 'enumerates each' docs/release-cadence.md CLAUDE.md 2>/dev/null | awk -F: '{s += $2} END {print s + 0}')"

if [ "$count" = "0" ]; then
  pass_msg "'enumerates each' absent from docs/release-cadence.md and CLAUDE.md"
else
  fail_msg "'enumerates each' present ($count occurrence(s)) — contradicts per-PR granularity contract (#492)"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
