#!/usr/bin/env bash
set -euo pipefail

# Guard for issue #1485 — collapsed PATH D agent is CONSUME-or-PRODUCE.
#
# Since #1485 plan-issue classifies inline, so a planner-classified D issue
# already carries trusted `## Classification` + `## Implementation Plan`
# comments when the collapsed D agent runs. The executor's D contract (union of
# skills/execute-issue-plan/SKILL.md + references/collapsed-inline-d.md) must:
#   (1) CONSUME upstream comments when they exist;
#   (2) PRODUCE them only when absent (pre-labelled D);
#   (3) skip the Step 1 plan fetch ONLY when the plan was produced in-context;
#   (4) keep the produce-branch literal `does NOT re-read the plan comment`.
#
# Style mirrors tests/test-path-d-collapse-dispatch.sh: whitespace-normalized
# union body + windowed proximity checks.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXECUTE_SKILL="$SCRIPT_DIR/../skills/execute-issue-plan/SKILL.md"
EXECUTE_D_REF="$SCRIPT_DIR/../skills/execute-issue-plan/references/collapsed-inline-d.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

for f in "$EXECUTE_SKILL" "$EXECUTE_D_REF"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: file not found at $f" >&2
    exit 1
  fi
done

BODY=$(cat "$EXECUTE_SKILL" "$EXECUTE_D_REF" | tr '\n' ' ' | tr -s '[:space:]' ' ')
SKILL_BODY=$(tr '\n' ' ' < "$EXECUTE_SKILL" | tr -s '[:space:]' ' ')

# near <text> <anchor-regex> <needle-regex> <window>: OK if needle matches
# within WINDOW chars before/after any anchor occurrence.
near() {
  python3 -c '
import re, sys
text, anchor, needle, window = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
ok = any(re.search(needle, text[max(0, m.start() - window): m.end() + window])
         for m in re.finditer(anchor, text))
print("OK" if ok else "MISS")
' "$1" "$2" "$3" "$4"
}

echo "Collapsed D consume-or-produce contract (#1485)"

# (1) CONSUME near `## Implementation Plan`, with an existence qualifier.
inc
if [ "$(near "$BODY" 'CONSUME' '## Implementation Plan' 300)" = OK ] \
   && [ "$(near "$BODY" 'CONSUME' 'when they exist|already posted|already exists' 300)" = OK ]; then
  pass_msg "(1) CONSUME branch reads upstream '## Implementation Plan' when it already exists"
else
  fail_msg "(1) missing CONSUME branch near '## Implementation Plan' + 'when they exist'/'already posted'"
fi

# (2) PRODUCE only when absent.
inc
if [ "$(near "$BODY" 'PRODUCE' '(?i)only when absent' 300)" = OK ]; then
  pass_msg "(2) PRODUCE branch fires only when absent"
else
  fail_msg "(2) missing 'PRODUCE' near 'only when absent'"
fi

# (3) Step 1 fetch skipped ONLY when the plan was produced in-context.
inc
if printf '%s' "$SKILL_BODY" | grep -qiE 'skip .{0,80}only when .{0,60}produced'; then
  pass_msg "(3) SKILL.md Step 1 skips the fetch only when the plan was produced in-context"
else
  fail_msg "(3) SKILL.md missing conditional 'skip ... ONLY when ... produced'"
fi

# (3b) the old unconditional skip is gone.
inc
if printf '%s' "$SKILL_BODY" | grep -qF 'skip this fetch on PATH D and use the in-context plan'; then
  fail_msg "(3b) SKILL.md still carries the unconditional 'skip this fetch on PATH D'"
else
  pass_msg "(3b) unconditional PATH D fetch skip removed"
fi

# (4) produce-branch literal preserved.
inc
if printf '%s' "$BODY" | grep -qF 'does NOT re-read the plan comment'; then
  pass_msg "(4) produce branch keeps 'does NOT re-read the plan comment'"
else
  fail_msg "(4) missing 'does NOT re-read the plan comment'"
fi

# (5) SKILL.md contract pointer names consume-or-produce.
inc
if printf '%s' "$SKILL_BODY" | grep -qiE 'consume-or-produce'; then
  pass_msg "(5) SKILL.md Collapsed inline D pointer mentions consume-or-produce"
else
  fail_msg "(5) SKILL.md Collapsed inline D pointer missing 'consume-or-produce'"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ]
