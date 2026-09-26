#!/bin/bash
set -uo pipefail

# tests/test-no-split-role-lane-skills.sh — issue #1420 (Task 2 guard, skills/ surface).
#
# #1420 retires the split-role RED/GREEN TDD lane: PATH B execute is ONE agent
# applying the tdd-implementer discipline inline. The scripts/ half is guarded by
# tests/test-no-split-role-lane.sh and the docs/ half by
# tests/test-no-split-role-lane-docs.sh; this file guards the PROSE half under
# skills/.
#
# The lane's vocabulary must survive in exactly ONE skill — skills/tokenomics/SKILL.md
# — because the cost-attribution substrate (scripts/_token-usage-lib.sh,
# scripts/capture-agent-costs.sh, scripts/cost-latency-report.sh,
# hooks/capture_agent_cost.py) still PRICES the historical `role=red`/`role=green`
# rows captured before the lane was removed. That survival is deliberate, so it is
# pinned two ways: the file set is exact (no third file may quietly reintroduce the
# lane) and every surviving red/green-role line must carry the `#1420` marker that
# labels it historical.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

echo "no split-role lane under skills/ (#1420)"

# The retired lane's vocabulary. `PIPELINE_TEST_FILE_GLOBS` and
# `parse-shared-tests` are in the list because both existed ONLY to serve the W7
# split-role gate.
LANE_RE='split[-_ ]role|\[split-role-red\]|SPLIT_ROLE|red:opus|lean-single|parse-shared-tests|PIPELINE_TEST_FILE_GLOBS|RED/GREEN ledger'

ALLOWED='skills/tokenomics/SKILL.md'

# ---------------------------------------------------------------------------
scenario1() { echo ""; echo "-- S1: the lane vocabulary survives in exactly one skill --"; }
scenario1

HITS="$(cd "$ROOT" && grep -rliE "$LANE_RE" skills/ | LC_ALL=C sort | tr '\n' ' ')"
HITS="${HITS% }"

inc
if [ "$HITS" = "$ALLOWED" ]; then
  pass_msg "S1: skills/ split-role vocabulary is confined to '$ALLOWED'"
else
  fail_msg "S1: skills/ split-role vocabulary is '$HITS' (want exactly '$ALLOWED')"
fi

# ---------------------------------------------------------------------------
scenario2() { echo ""; echo "-- S2: every surviving red/green-role line is marked #1420 --"; }
scenario2

ROLE_RE='split[-_ ]role|role=red|role=green|`red`|`green`|\bred\b|\bgreen\b'

inc
if [ ! -f "$ROOT/$ALLOWED" ]; then
  fail_msg "S2: $ALLOWED not found"
else
  UNMARKED="$(grep -nE "$ROLE_RE" "$ROOT/$ALLOWED" | grep -v '#1420' || true)"
  if [ -z "$UNMARKED" ]; then
    pass_msg "S2: every red/green-role line in $ALLOWED cites #1420 as historical"
  else
    fail_msg "S2: $ALLOWED names red/green roles without the #1420 historical marker:"
    printf '%s\n' "$UNMARKED" | while IFS= read -r l; do echo "        ${l:0:160}"; done
  fi
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
exit 0
