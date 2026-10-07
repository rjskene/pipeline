#!/bin/bash
set -euo pipefail
# Guard for #728: each consumer-facing artifact template carries a terseness
# directive (TERSENESS: sentinel) AND every contract-pinned emit surface is
# held byte-for-byte. Group (b) is the anti-overshoot guard — it fails loud
# if a verbosity-trim edit deletes a pinned header/verdict/sentinel.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SK="$SCRIPT_DIR/../skills"
PASS=0; FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_grep() { # file, literal, label
  if grep -qF -- "$2" "$1"; then pass_msg "$3"; else fail_msg "$3 (missing: $2 in $1)"; fi
}
PR="$SK/evaluate-issue-pr/SKILL.md"
PLAN="$SK/evaluate-issue-plan/SKILL.md"
CLS="$SK/classify-issue/SKILL.md"
PI="$SK/plan-issue/SKILL.md"
for f in "$PR" "$PLAN" "$CLS" "$PI"; do
  [ -f "$f" ] || { echo "ERROR: missing $f" >&2; exit 1; }
done
# (a) terseness sentinel present in all four
assert_grep "$PR"   "TERSENESS:" "evaluate-issue-pr has terseness directive"
assert_grep "$PLAN" "TERSENESS:" "evaluate-issue-plan has terseness directive"
assert_grep "$CLS"  "TERSENESS:" "classify-issue has terseness directive"
assert_grep "$PI"   "TERSENESS:" "plan-issue has terseness directive"
# (b) contract surfaces held — evaluate-issue-pr
assert_grep "$PR" "## Evaluation"          "pr: ## Evaluation header held"
assert_grep "$PR" "**Verdict:** Approved"  "pr: Verdict Approved held"
# #1444: the gate call site is the orchestrator's, not the evaluator's.
assert_grep "$SK/../skills/fullsend/references/auto-merge-gate.md" "auto_merge_should_fire" "auto-merge gate ref held"
# (b) evaluate-issue-plan
assert_grep "$PLAN" "## Plan Evaluation"          "plan-eval: header held"
assert_grep "$PLAN" "**Verdict:** Approve / Revise" "plan-eval: verdict line held"
assert_grep "$PLAN" "**File accuracy:**"          "plan-eval: File accuracy held"
assert_grep "$PLAN" "is-trusted-author"           "plan-eval: trust helper ref held"
# (b) classify-issue
assert_grep "$CLS" "## Classification"        "classify: header held"
assert_grep "$CLS" "recommended_path:"        "classify: recommended_path held"
assert_grep "$CLS" "# BEGIN-LABEL-APPLY"      "classify: BEGIN-LABEL-APPLY held"
assert_grep "$CLS" "# END-LABEL-APPLY"        "classify: END-LABEL-APPLY held"
assert_grep "$CLS" "# BEGIN-PATH-MARKER-PARSE" "classify: BEGIN-PATH-MARKER-PARSE held"
assert_grep "$CLS" "# END-PATH-MARKER-PARSE"  "classify: END-PATH-MARKER-PARSE held"
assert_grep "$CLS" "is-trusted-author"        "classify: trust helper ref held"
# (b) plan-issue
assert_grep "$PI" "## Implementation Plan"  "plan: header held"
assert_grep "$PI" "**Tasks (ordered):**"    "plan: Tasks (ordered) held"
assert_grep "$PI" "**Predicates:**"         "plan: Predicates held"
assert_grep "$PI" "post-plan.sh"            "plan: post-plan.sh ref held"

# (c) #1435 — the optional `**Scope:**` line on a Revise verdict. The template
# pin plus the prose that defines it, held under ONE 60-word budget so the
# annotate arm cannot grow unbounded prose in the evaluator.
assert_grep "$PLAN" "**Scope:** patch | structural" "plan-eval: Scope template line held"
assert_grep "$PLAN" "**Scope (#1435):**"            "plan-eval: Scope prose line held"
SCOPE_MAX_WORDS=60
SCOPE_WORDS=$({ grep -F -e '**Scope:** patch | structural' -e '**Scope (#1435):**' "$PLAN" || true; } | wc -w | tr -d ' ')
if [ "$SCOPE_WORDS" -ge 1 ] && [ "$SCOPE_WORDS" -le "$SCOPE_MAX_WORDS" ]; then
  pass_msg "plan-eval: Scope template+prose lines total $SCOPE_WORDS words (<= $SCOPE_MAX_WORDS)"
else
  fail_msg "plan-eval: Scope template+prose lines total $SCOPE_WORDS words (budget 1..$SCOPE_MAX_WORDS) - CUT THE PROSE, never raise the ceiling"
fi
# (d) #1440 — the pr-eval side of the #1435 amendment contract. Under
# PIPELINE_PLAN_GATE=annotate a `Revise` plan evaluation's `**Recommendations:**`
# are binding amendments to the plan of record, so the evaluator must score the
# PR against plan + amendments. Pinned here with the issue's HARD 110-word prose
# budget: the Step 1 sentinel line plus the `## Constraints` inputs-rule phrase.
PA_PR_SENTINEL='**Plan amendments (#1435):**'
PA_PR_INPUTS_PHRASE='plan comment plus its trusted `## Plan Evaluation` when the verdict is `Revise`'
PA_PR_MAX_WORDS=110

PA_PR_COUNT=$(grep -cF -- "$PA_PR_SENTINEL" "$PR" || true)
if [ "$PA_PR_COUNT" = "1" ]; then
  pass_msg "pr: '$PA_PR_SENTINEL' on exactly 1 line"
else
  fail_msg "pr: '$PA_PR_SENTINEL' appears on $PA_PR_COUNT lines (expected exactly 1)"
fi

PA_PR_LINE=$(grep -F -- "$PA_PR_SENTINEL" "$PR" | head -n 1 || true)
pa_pr_ok=1
for lit in '**Recommendations:**' '**Dropped amendment:**' 'Phase 1' 'Revise'; do
  grep -qF -- "$lit" <<<"$PA_PR_LINE" || { pa_pr_ok=0; echo "    (missing from the sentinel line: $lit)"; }
done
grep -qiE 'blocking' <<<"$PA_PR_LINE" || { pa_pr_ok=0; echo "    (sentinel line never calls a dropped amendment BLOCKING)"; }
if [ "$pa_pr_ok" = "1" ]; then
  pass_msg "pr: amendment line names **Recommendations:**, the **Dropped amendment:** Phase 1 finding, Revise and the BLOCKING tier"
else
  fail_msg "pr: amendment line is incomplete: $PA_PR_LINE"
fi

assert_grep "$PR" "$PA_PR_INPUTS_PHRASE" "pr: inputs rule admits the trusted Plan Evaluation on a Revise verdict"

PA_PR_WORDS=$(( $(printf '%s' "$PA_PR_LINE" | wc -w | tr -d ' ') + $(printf '%s' "$PA_PR_INPUTS_PHRASE" | wc -w | tr -d ' ') ))
if [ "$PA_PR_WORDS" -ge 1 ] && [ "$PA_PR_WORDS" -le "$PA_PR_MAX_WORDS" ]; then
  pass_msg "pr: amendment prose (sentinel line + inputs phrase) totals $PA_PR_WORDS words (<= $PA_PR_MAX_WORDS)"
else
  fail_msg "pr: amendment prose totals $PA_PR_WORDS words (budget 1..$PA_PR_MAX_WORDS) - CUT THE PROSE, never raise the ceiling"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
