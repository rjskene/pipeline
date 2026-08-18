#!/bin/bash
set -uo pipefail

# Regression guard for issue #1208 Task 2 — "never `run_in_background` a test
# run" dispatch-contract clause.
#
# #1208 is the Nth recurrence of the narrate-and-yield drop-out (#752/#764,
# #814, #838/#904, #912). The proximate trigger this time: the dispatched agent
# BACKGROUNDED the full suite (`run_in_background: true`) because ~590 test files
# do not fit inside one Bash-call timeout, then had nothing left to do in-turn
# and yielded with the branch committed-but-unpushed.
#
# The mechanism fix is `scripts/run-test-suite.sh --chunk k/n` (Task 1). This
# test pins the PROSE half: both the binding DISPATCH SITE
# (skills/fullsend/SKILL.md, the inline execute dispatch prompt contract — the
# only contract a `general-purpose`/`tdd-implementer` subagent that never loads
# the skill body actually sees) and the SKILL BODY
# (skills/execute-issue-plan/SKILL.md Step 6b — defense-in-depth) must ban
# backgrounding a test run AND name the chunked foreground runner as the
# replacement.
#
# CRITICAL scoping: assertions are made against the EXTRACTED region, not the
# whole file — the words `run_in_background`, `foreground`, etc. already appear
# elsewhere in both SKILLs (the Step 6 tmux queue-runner launch, Step 6b's
# synchronous-invocation prose), so a whole-file grep would pass spuriously on
# the pre-fix text.
#
# Mirrors the ROOT / pass_msg / fail_msg / inc / `exit 1` shape of
# tests/test-execute-dispatch-prompt-hardening.sh.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FULLSEND="skills/fullsend/SKILL.md"
EXECPLAN="skills/execute-issue-plan/SKILL.md"

PASS=0
FAIL=0
TESTS=0

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
# UNCHANGED from tests/test-execute-dispatch-prompt-hardening.sh:92-98 so both
# guards agree on the region boundary (the paragraph terminates on the next
# `   **` sub-heading line).
contract_paragraph() {
  awk '
    /\*\*Inline execute dispatch prompt contract \(mandatory\)\.\*\*/ { inblock = 1; print; next }
    inblock && /^   \*\*/ { inblock = 0 }
    inblock { print }
  ' "$ROOT/skills/fullsend/SKILL.md"
}

# execute-issue-plan — the Step 6b region. Copied from
# tests/test-execute-skill-testwait-synchronous.sh:45-49.
step6b_region() {
  awk '
    /^\s*\*\*6b\. Run tests/ {capturing=1}
    /^\s*\*\*6c\./ {capturing=0}
    capturing {print}
  ' "$ROOT/skills/execute-issue-plan/SKILL.md"
}

F_REGION="$(contract_paragraph)"
E_REGION="$(step6b_region)"

if [ -z "$F_REGION" ]; then
  echo "FAIL: could not extract the inline execute dispatch prompt contract paragraph from $FULLSEND (markers moved?)" >&2
  exit 1
fi
if [ -z "$E_REGION" ]; then
  echo "FAIL: could not extract the Step 6b region from $EXECPLAN (markers '**6b. Run tests' / '**6c.' moved?)" >&2
  exit 1
fi

# Flatten so a needle is matched against the region as one blob.
F_FLAT="$(tr '\n' ' ' <<< "$F_REGION")"
E_FLAT="$(tr '\n' ' ' <<< "$E_REGION")"

# Assert a flattened region contains a needle. mode: F = case-sensitive fixed
# string, Fi = case-INsensitive fixed string. The `--` end-of-options guard is
# always passed so needles beginning with `-` (e.g. `--chunk`) are safe.
assert_needle() {
  local label="$1" region="$2" mode="$3" needle="$4"
  inc
  local hit=1
  case "$mode" in
    F)  grep -Fq  -- "$needle" <<< "$region" || hit=0 ;;
    Fi) grep -Fiq -- "$needle" <<< "$region" || hit=0 ;;
    *)  echo "internal error: bad mode $mode" >&2; exit 1 ;;
  esac
  if [ "$hit" -eq 1 ]; then
    pass_msg "$label: region contains \"$needle\""
  else
    fail_msg "$label: region missing \"$needle\""
  fi
}

# ---------------------------------------------------------------------------
# 1-7. The never-background clause, in BOTH prose sites.
#
# Needles 1-3 are deliberately THREE separate greps — never joined into one
# literal such as `scripts/run-test-suite.sh --chunk`, which does not occur
# (a closing `"` sits between `.sh` and ` --chunk` in the prescribed clause).
# ---------------------------------------------------------------------------

check_clause() {
  local label="$1" region="$2"
  assert_needle "$label" "$region" F  'run_in_background'
  assert_needle "$label" "$region" F  'run-test-suite.sh'
  assert_needle "$label" "$region" F  '--chunk'
  assert_needle "$label" "$region" Fi 'chunk it instead'
  assert_needle "$label" "$region" F  'every chunk'
  assert_needle "$label" "$region" F  'RESULT=pass'
  assert_needle "$label" "$region" Fi 'FOREGROUND'
}

check_clause "no-bg-dispatch-site (fullsend contract paragraph)" "$F_FLAT"
check_clause "no-bg-skill-body (execute-issue-plan Step 6b)"     "$E_FLAT"

# ---------------------------------------------------------------------------
# 8. Scoped-ban guard: the ban is scoped to TEST RUNS, not to `run_in_background`
#    generally. fullsend Step 6 / Step 7 legitimately launch the tmux queue
#    runner with `run_in_background: true` + a `Monitor` waiter — that must
#    survive. The prescribed clause deliberately does NOT contain the literal
#    `run_in_background: true`, so this guard can only be satisfied by the real
#    queue-launch sites, never spuriously by the new clause.
# ---------------------------------------------------------------------------

inc
if grep -Fq 'run_in_background: true' "$ROOT/$FULLSEND"; then
  pass_msg "scoped-ban: fullsend still sanctions the tmux queue-runner launch (\`run_in_background: true\` preserved)"
else
  fail_msg "scoped-ban: fullsend lost \`run_in_background: true\` — the ban was over-applied to the Step 6/7 queue launchers"
fi

# ---------------------------------------------------------------------------
# 9. Placement guard: the clause must ride the END of the existing contract line,
#    NOT a new `   **`-prefixed line — a new `   **Never …` line matches the
#    region terminator `^   \*\*` and would land the clause OUTSIDE the asserted
#    paragraph, silently defeating assertions 1-7.
# ---------------------------------------------------------------------------

inc
if grep -Eq '^   \*\*Never .run_in_background' "$ROOT/$FULLSEND"; then
  fail_msg "clause-placement: the never-background clause starts its own \`   **\` line — that line terminates the contract paragraph, so the clause falls outside the binding region (append it to the END of the existing contract line instead)"
else
  pass_msg "clause-placement: no stray \`   **Never \\\`run_in_background\` line (clause rides the existing contract line)"
fi

# ---------------------------------------------------------------------------
# 10. Preservation: the append must not truncate the contract paragraph. These
#     four keys are the ones tests/test-execute-dispatch-prompt-hardening.sh
#     already pins inside the same region.
# ---------------------------------------------------------------------------

for key in 'valid terminal states are' 'SPLIT_ROLE' '[split-role-red]' 'worktree index'; do
  assert_needle "contract-preservation" "$F_FLAT" F "$key"
done

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
