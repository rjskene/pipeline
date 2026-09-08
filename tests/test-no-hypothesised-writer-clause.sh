#!/bin/bash
set -uo pipefail

# Contract test for issue #1262 sub-defect (b), misattribution half — the
# "no hypothesised concurrent writer" dispatch clause.
#
# A dispatched collapsed PATH D agent wrote its first round of edits into the
# orchestrator's MAIN checkout instead of its assigned worktree, then MISATTRIBUTED
# the symptom: it reported that a "concurrent campaign cron" had reset its worktree,
# when the only open PR at that moment was its own and no second campaign was
# running. An agent inventing a concurrent writer to explain its own misplaced edit
# sends the operator hunting a race that does not exist.
#
# The fix is a prose clause in BOTH homes, mirroring how #1106 / #1122 / #1208 each
# landed:
#
#   1. THE DISPATCH SITE — `skills/fullsend/SKILL.md`, the inline execute dispatch
#      prompt contract paragraph. This is the binding one: a dispatched
#      `general-purpose` / `pipeline:tdd-implementer` subagent may never load
#      `skills/execute-issue-plan/SKILL.md` at all, so the dispatch prompt is the
#      only contract it is guaranteed to see.
#   2. THE SKILL BODY — `skills/execute-issue-plan/SKILL.md` `## Constraints`,
#      defense-in-depth for an agent that DOES load the body.
#
# Assertions are scoped to the two EXTRACTED regions, never the whole file: words
# like `STOP`, `status`, and `observed` already occur elsewhere in both skills, so a
# whole-file grep would pass spuriously on the pre-fix text.
#
# Spelling is load-bearing: `hypothesised` (British `s`), matching the issue text.
#
# RED/GREEN ledger: H1-H6 are red before the fix. H7 and H8 are REGRESSION controls
# on the shape of that fix (H7 asserts the ABSENCE of a badly-placed heading line;
# H8 pins four contract keys that already exist), so both are green by construction
# before the edit and must stay green after it. H9 is the markers-moved tripwire.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FULLSEND="skills/fullsend/SKILL.md"
EXECPLAN="skills/execute-issue-plan/SKILL.md"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

for f in "$FULLSEND" "$EXECPLAN"; do
  if [ ! -f "$ROOT/$f" ]; then
    echo "FAIL: $f not found under $ROOT" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Region extractors.
# ---------------------------------------------------------------------------

# fullsend — the inline execute dispatch prompt contract paragraph. Copied
# VERBATIM from tests/test-dispatch-no-background-test-run.sh so both guards agree
# on the region boundary (the paragraph terminates on the next `   **` line).
contract_paragraph() {
  awk '
    /\*\*Inline execute dispatch prompt contract \(mandatory\)\.\*\*/ { inblock = 1; print; next }
    inblock && /^   \*\*/ { inblock = 0 }
    inblock { print }
  ' "$ROOT/$FULLSEND"
}

# execute-issue-plan — the `## Constraints` section, up to the next `## ` heading.
constraints_region() {
  awk '
    /^## Constraints/ { inblock = 1; print; next }
    inblock && /^## / { inblock = 0 }
    inblock { print }
  ' "$ROOT/$EXECPLAN"
}

F_REGION="$(contract_paragraph)"
E_REGION="$(constraints_region)"

# ---------------------------------------------------------------------------
# H9 — markers-moved tripwire. An empty region would make H1-H6 report a
#      missing clause when the real fault is a moved marker, so this runs first
#      and hard-fails.
# ---------------------------------------------------------------------------
echo "No-hypothesised-concurrent-writer dispatch clause (#1262b)"
echo ""

inc
if [ -n "$F_REGION" ] && [ -n "$E_REGION" ]; then
  pass_msg "H9: both regions extracted non-empty (fullsend contract paragraph + execute-issue-plan ## Constraints)"
else
  fail_msg "H9: region extraction empty — fullsend='$([ -n "$F_REGION" ] && echo ok || echo EMPTY)' execute-issue-plan='$([ -n "$E_REGION" ] && echo ok || echo EMPTY)' (markers moved?)"
  echo ""
  echo "================================"
  echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
  echo "================================"
  exit 1
fi

# Flatten so each needle is matched against the region as one blob.
F_FLAT="$(tr '\n' ' ' <<< "$F_REGION")"
E_FLAT="$(tr '\n' ' ' <<< "$E_REGION")"

# assert_needle <label> <region-name> <region> <needle>  (case-INsensitive fixed
# string; `--` guards needles that begin with `-`).
assert_needle() {
  local label="$1" rname="$2" region="$3" needle="$4"
  inc
  if grep -Fiq -- "$needle" <<< "$region"; then
    pass_msg "$label ($rname): region contains \"$needle\""
  else
    fail_msg "$label ($rname): region missing \"$needle\""
  fi
}

# ---------------------------------------------------------------------------
# H1-H6 — the clause, in BOTH prose homes.
#
#   H1  the prohibition itself, spelled exactly as the issue spells it
#   H2  the evidentiary standard that replaces the invented writer
#   H3  the required terminal behaviour
#   H4  the observed-facts report shape the agent must emit instead
#   H5  the correct alternative hypothesis (its OWN unanchored git command)
#   H6  the trigger condition — state turning up where it was not expected
# ---------------------------------------------------------------------------

check_clause() {
  local rname="$1" region="$2"
  assert_needle "H1" "$rname" "$region" 'hypothesised concurrent writer'
  assert_needle "H2" "$rname" "$region" 'directly observed'
  assert_needle "H3" "$rname" "$region" 'STOP'
  assert_needle "H4" "$rname" "$region" 'status --short'
  assert_needle "H5" "$rname" "$region" 'unanchored'
  assert_needle "H6" "$rname" "$region" 'did not expect'
}

check_clause "fullsend contract paragraph" "$F_FLAT"
echo ""
check_clause "execute-issue-plan ## Constraints" "$E_FLAT"

# ---------------------------------------------------------------------------
# H7 — PLACEMENT guard (the #1208 precedent). The clause must ride the END of the
#      existing contract line, NOT a new `   **`-prefixed line: such a line matches
#      the region terminator `^   \*\*` and would land the clause OUTSIDE the
#      binding paragraph, silently defeating H1-H6.
# ---------------------------------------------------------------------------
echo ""
inc
if grep -Eq '^   \*\*No hypothesised' "$ROOT/$FULLSEND"; then
  fail_msg "H7: the clause starts its own \`   **No hypothesised\` line — that line terminates the contract paragraph, so the clause falls OUTSIDE the binding region (append it to the END of the existing contract line instead)"
else
  pass_msg "H7: no stray \`   **No hypothesised\` line (clause rides the existing contract line)"
fi

# ---------------------------------------------------------------------------
# H8 — CONTRACT PRESERVATION. Appending to a very long single-line paragraph is
#      easy to do destructively. These four keys are the ones
#      tests/test-dispatch-no-background-test-run.sh already pins inside the same
#      region; if the append truncated the paragraph they disappear.
# ---------------------------------------------------------------------------
for key in 'valid terminal states are' 'SPLIT_ROLE' '[split-role-red]' 'worktree index'; do
  inc
  if grep -Fq -- "$key" <<< "$F_FLAT"; then
    pass_msg "H8: contract paragraph still contains \"$key\""
  else
    fail_msg "H8: contract paragraph lost \"$key\" — the append truncated the binding paragraph"
  fi
done

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
