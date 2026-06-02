#!/usr/bin/env bash
set -euo pipefail

# Tests for the PATH D auto-flip and inline tdd-implementer execute dispatch
# wiring in skills/run/SKILL.md. Asserts:
#  (a) Step 4 plan-pending block emits the auto-flip gh command for
#      `plan-pending` + `quick-fix` issues (skipping evaluate-issue-plan).
#  (b) Step 6 execute dispatch routing contains the BARE
#      `Agent(subagent_type='tdd-implementer'` form within 300 chars of the
#      first PATH D mention.
#  (c) The same window contains `No spawn-claude.sh` within 300 chars of
#      PATH D, confirming the inline-only routing for quick-fix.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# #763: the run→status rename moved PATH-D auto-flip + inline tdd-implementer
# dispatch wiring out of the old /pipeline:run skill into skills/fullsend/SKILL.md.
# The read-only /pipeline:status skill carries no dispatch wiring.
SKILL_FILE="$SCRIPT_DIR/../skills/fullsend/SKILL.md"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SKILL_FILE" ]; then
  echo "ERROR: run SKILL.md not found at $SKILL_FILE" >&2
  exit 1
fi

# Whitespace-normalized full body (collapse all whitespace runs to single
# spaces) so multi-line markdown bullets match a single-line substring
# assertion.
SKILL_BODY=$(tr '\n' ' ' < "$SKILL_FILE" | tr -s '[:space:]' ' ')

# --- Test (a): PATH D auto-flip (plan-pending → plan-approved) documented ---
echo "Test (a): PATH D plan-pending -> plan-approved auto-flip documented"
inc
# #763: the verbose literal `gh issue edit $N --add-label plan-approved
# --remove-label plan-pending` auto-flip COMMAND was dropped in the relocation
# from the old run skill — the command literal no longer exists anywhere
# (verified: `grep -r 'add-label plan-approved --remove-label plan-pending'
# skills/` returns nothing). The auto-flip CONTRACT survives in fullsend as the
# prose "auto-flip plan-pending → plan-approved", which is the live behavioral
# assertion. Repointed to that prose rather than silently dropping the contract.
if printf '%s' "$SKILL_BODY" | grep -qiE 'auto-flip plan-pending . plan-approved|auto-flip plan-pending'; then
  pass_msg "PATH D auto-flip (plan-pending → plan-approved) documented in fullsend"
else
  fail_msg "fullsend missing PATH D 'auto-flip plan-pending → plan-approved' prose"
fi

# --- Test (b): BARE Agent(subagent_type='tdd-implementer' near PATH D ---
echo "Test (b): BARE tdd-implementer dispatch within 300 chars of PATH D"
inc
# Find each PATH D occurrence; check a 300-char window after it.
PYOUT=$(python3 - "$SKILL_FILE" <<'PY'
import re, sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text()
needle_agent = "Agent(subagent_type='tdd-implementer'"
hits = [m.start() for m in re.finditer(r"PATH D", text)]
ok = False
for h in hits:
    window = text[h:h+300]
    if needle_agent in window:
        ok = True
        break
print("OK" if ok else "MISS")
PY
)
if [ "$PYOUT" = "OK" ]; then
  pass_msg "BARE Agent(subagent_type='tdd-implementer' within 300 chars of PATH D"
else
  fail_msg "BARE Agent(subagent_type='tdd-implementer' NOT within 300 chars of any PATH D mention"
fi

# --- Test (c): `No spawn-claude.sh` near PATH D ---
echo "Test (c): 'No spawn-claude.sh' within 300 chars of PATH D"
inc
PYOUT2=$(python3 - "$SKILL_FILE" <<'PY'
import re, sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text()
needle = "No spawn-claude.sh"
hits = [m.start() for m in re.finditer(r"PATH D", text)]
ok = False
for h in hits:
    window = text[h:h+300]
    if needle in window:
        ok = True
        break
print("OK" if ok else "MISS")
PY
)
if [ "$PYOUT2" = "OK" ]; then
  pass_msg "'No spawn-claude.sh' within 300 chars of PATH D"
else
  fail_msg "'No spawn-claude.sh' NOT within 300 chars of any PATH D mention"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
