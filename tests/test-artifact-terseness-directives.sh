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
assert_grep "$PR" "auto_merge_should_fire" "pr: auto-merge gate ref held"
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
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
