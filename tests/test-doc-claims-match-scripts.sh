#!/bin/bash
set -uo pipefail
#
# #1300 — pin four DOC CLAIMS against the SCRIPT FACTS they describe.
#
# Cycle-2/3 friction found skill prose that asserts behaviour the scripts do not
# have. Two claims are in scope here:
#
#   1. The exact-match guard sweep's SCOPE RULE. `scripts/exact-match-guard-sweep.sh`
#      resolves roots as positional `<test-path>...` > `$PIPELINE_TEST_ROOTS`
#      (word-split AND glob-expanded) > the hardcoded default `tests/`. Exit 3
#      (`no-test-root` / `no-test-files`) fires only when every RESOLVED root
#      fails `[ -e ]`. An UNSET `PIPELINE_TEST_ROOTS` therefore self-defaults and
#      is NEVER vacuous — the opposite of what `skills/plan-issue/SKILL.md` and
#      `skills/evaluate-issue-plan/SKILL.md` said.
#   2. The evolve comment-trust claim. `skills/evolve/SKILL.md` said
#      `enforce-comment-trust.py` "blocks `--json comments`"; the helper
#      `scripts/filter-trusted-comments.sh` is the trust filter of record.
#
# The FIRST assertion is a mechanical control that EXECUTES the script whose
# behaviour the prose describes, so a green prose grep can never be green
# against a fiction. The eval-plan `no-test-root`-near-`Revise` assertion is a
# regression control over a PRE-CHANGE token the reword must preserve (same awk
# proximity check as tests/test-exact-match-guard-sweep.sh Case 16b).
#
# House shape: PASS/FAIL counters, `[ "$FAIL" -eq 0 ]` tail (as tests/test-run-retro.sh).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SWEEP="$REPO_ROOT/scripts/exact-match-guard-sweep.sh"
PLAN_SKILL="$REPO_ROOT/skills/plan-issue/SKILL.md"
EVAL_SKILL="$REPO_ROOT/skills/evaluate-issue-plan/SKILL.md"
EVOLVE_SKILL="$REPO_ROOT/skills/evolve/SKILL.md"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc_scenario() { echo ""; echo "-- $1 --"; }

# assert_sub <label> <file> <fixed substring>
assert_sub() {
  if [ -f "$2" ] && grep -qF -- "$3" "$2"; then pass_msg "$1"; else fail_msg "$1 (missing: $3)"; fi
}
# refute_sub <label> <file> <fixed substring>
refute_sub() {
  if [ -f "$2" ] && grep -qF -- "$3" "$2"; then fail_msg "$1 (unexpectedly present: $3)"; else pass_msg "$1"; fi
}

# ---------------------------------------------------------------------------
# Scenario 1 — MECHANICAL CONTROL (asserted FIRST, non-vacuity anchor).
#
# With `PIPELINE_TEST_ROOTS` removed from the environment entirely, the sweep
# must still sweep: rc=0 and a terminal `EXACT_MATCH_SWEEP=ok ... REASON=swept`.
# This is the fact every prose assertion below describes.
# ---------------------------------------------------------------------------
inc_scenario "Scenario 1: an UNSET PIPELINE_TEST_ROOTS still sweeps (rc=0, REASON=swept)"

if [ -x "$SWEEP" ]; then
  pass_msg "scripts/exact-match-guard-sweep.sh exists and is executable"
else
  fail_msg "scripts/exact-match-guard-sweep.sh missing or not executable"
fi

SWEEP_OUT="$(cd "$REPO_ROOT" && env -u PIPELINE_TEST_ROOTS bash "$SWEEP" 2>/dev/null)"
SWEEP_RC=$?

if [ "$SWEEP_RC" -eq 0 ]; then
  pass_msg "sweep with an unset PIPELINE_TEST_ROOTS exits 0 (not 3)"
else
  fail_msg "sweep with an unset PIPELINE_TEST_ROOTS exited $SWEEP_RC (expected 0)"
fi

SWEEP_LAST="$(printf '%s\n' "$SWEEP_OUT" | tail -1)"
if printf '%s\n' "$SWEEP_LAST" | grep -qE '^EXACT_MATCH_SWEEP=ok .*REASON=swept$'; then
  pass_msg "sweep summary line reports REASON=swept ($SWEEP_LAST)"
else
  fail_msg "sweep summary line is not an ok/swept result (got: $SWEEP_LAST)"
fi

# ---------------------------------------------------------------------------
# Scenario 2 — skills/plan-issue/SKILL.md Step 4 states the real scope rule.
#
# The paragraph scanned is the Step 4 sweep block: from the
# `**Exact-match guard sweep` marker down to the `4a.` heading that ends Step 4.
# ---------------------------------------------------------------------------
inc_scenario "Scenario 2: plan-issue Step 4 states the sweep's real scope rule"

PLAN_BLOCK="$(sed -n '/\*\*Exact-match guard sweep/,/^4a\./p' "$PLAN_SKILL" 2>/dev/null)"

if [ -n "$PLAN_BLOCK" ]; then
  pass_msg "plan-issue Step 4 sweep paragraph is locatable"
else
  fail_msg "plan-issue Step 4 sweep paragraph not found in $PLAN_SKILL"
fi

if printf '%s\n' "$PLAN_BLOCK" | grep -qF 'positional'; then
  pass_msg "plan-issue names positional args as the first scope source"
else
  fail_msg "plan-issue Step 4 never says 'positional'"
fi

if printf '%s\n' "$PLAN_BLOCK" | grep -qF 'PIPELINE_TEST_ROOTS'; then
  pass_msg "plan-issue names \$PIPELINE_TEST_ROOTS in the scope rule"
else
  fail_msg "plan-issue Step 4 never says 'PIPELINE_TEST_ROOTS'"
fi

if printf '%s\n' "$PLAN_BLOCK" | grep -F 'default' | grep -qF 'tests/'; then
  pass_msg "plan-issue names 'tests/' as the DEFAULT root on one line"
else
  fail_msg "plan-issue Step 4 never names 'tests/' as the default root"
fi

refute_sub "plan-issue no longer blames the host for an unset PIPELINE_TEST_ROOTS" \
  "$PLAN_SKILL" 'fix `PIPELINE_TEST_ROOTS` for the host before relying'

# ---------------------------------------------------------------------------
# Scenario 3 — skills/evaluate-issue-plan/SKILL.md Step 3 Phase 1 mirrors it.
#
# Scoped to the sweep bullet block so a repo-wide `tests/` hit cannot make this
# vacuously green: from the `exact-match-guard-sweep.sh` invocation down to the
# `hits are advisory only` bullet that closes the sweep stanza.
# ---------------------------------------------------------------------------
inc_scenario "Scenario 3: evaluate-issue-plan mirrors the real scope rule"

EVAL_BLOCK="$(sed -n '/exact-match-guard-sweep\.sh/,/hits are advisory only/p' "$EVAL_SKILL" 2>/dev/null)"

if [ -n "$EVAL_BLOCK" ]; then
  pass_msg "evaluate-issue-plan sweep stanza is locatable"
else
  fail_msg "evaluate-issue-plan sweep stanza not found in $EVAL_SKILL"
fi

if printf '%s\n' "$EVAL_BLOCK" | grep -qF 'positional'; then
  pass_msg "evaluate-issue-plan names positional args as the first scope source"
else
  fail_msg "evaluate-issue-plan sweep stanza never says 'positional'"
fi

if printf '%s\n' "$EVAL_BLOCK" | grep -qF 'tests/'; then
  pass_msg "evaluate-issue-plan names the 'tests/' default root"
else
  fail_msg "evaluate-issue-plan sweep stanza never names 'tests/'"
fi

refute_sub "evaluate-issue-plan no longer calls an unset var a misconfiguration" \
  "$EVAL_SKILL" 'unset or misconfigured'
refute_sub "evaluate-issue-plan no longer blocks on ANY non-zero exit" \
  "$EVAL_SKILL" 'Non-zero exit is BLOCKING'

# Regression control (green BEFORE and AFTER the reword): the real failure mode
# must stay wired to a Revise verdict. Same awk proximity check as
# tests/test-exact-match-guard-sweep.sh Case 16b.
if [ ! -f "$EVAL_SKILL" ]; then
  fail_msg "no-test-root tied to Revise: $EVAL_SKILL missing"
elif awk '
    /no-test-root/ { hits[NR] = 1 }
    /Revise/       { revs[NR] = 1 }
    END {
      for (h in hits) for (r in revs) if ((r - h) <= 10 && (h - r) <= 10) { exit 0 }
      exit 1
    }' "$EVAL_SKILL"; then
  pass_msg "no-test-root is still tied to a Revise verdict (within 10 lines)"
else
  fail_msg "the reword broke the no-test-root/Revise proximity in $EVAL_SKILL"
fi

# ---------------------------------------------------------------------------
# Scenario 4 — skills/evolve/SKILL.md names the real comment-trust filter.
# ---------------------------------------------------------------------------
inc_scenario "Scenario 4: evolve names the trust filter of record"

if [ -f "$EVOLVE_SKILL" ] && grep -F 'enforce-comment-trust.py' "$EVOLVE_SKILL" | grep -qF 'blocks'; then
  fail_msg "evolve still claims enforce-comment-trust.py 'blocks' the fetch"
else
  pass_msg "evolve no longer claims enforce-comment-trust.py blocks anything"
fi

TRUST_LINE="$(grep -F 'Comments are read ONLY via' "$EVOLVE_SKILL" 2>/dev/null | head -1)"
if printf '%s\n' "$TRUST_LINE" | grep -qF 'filter-trusted-comments.sh'; then
  pass_msg "the durable-state sentence still names filter-trusted-comments.sh"
else
  fail_msg "the durable-state sentence no longer names filter-trusted-comments.sh"
fi

assert_sub "evolve calls the helper the trust filter of record" \
  "$EVOLVE_SKILL" 'trust filter of record'

echo ""
echo "== RESULTS =="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
