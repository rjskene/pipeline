#!/bin/bash
# Lint skills/evaluate-issue-pr/SKILL.md for the Step 11 (Auto-merge gate)
# prose contract introduced by issue #122.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="${ROOT}/skills/evaluate-issue-pr/SKILL.md"
FAILED=0

want() {
  local name="$1" pat="$2"
  if grep -qE -- "$pat" "$SKILL"; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name (pattern not found: $pat)"
    FAILED=$((FAILED+1))
  fi
}

want "four greenlight conditions (Verdict Approved)" '\*\*Verdict:\*\*.*Approved'
want "four greenlight conditions (statusCheckRollup)" 'statusCheckRollup'
want "four greenlight conditions (mergeable)"         'mergeable'
want "four greenlight conditions (mergeStateStatus)"  'mergeStateStatus'

want "synchronous merge-commit"       'gh pr merge .*--merge --delete-branch'
if grep -q -- "gh pr merge.*--auto" "$SKILL"; then
  echo "  FAIL: --auto flag must not appear"
  FAILED=$((FAILED+1))
else
  echo "  PASS: no --auto flag"
fi

want "SHA source via mergeCommit.oid" 'gh pr view .* --json mergeCommit --jq .mergeCommit.oid'
want "auto-merged footer literal"     'Auto-merged: eval Approved \+ CI SUCCESS \+ MERGEABLE/CLEAN at'
want "manual-merge flag mention"      '--manual-merge'
want "manual-merge label mention"     'manual-merge'
want "argv-position parser spec"      '--manual-merge.*may appear anywhere in argv'

want "front-matter usage with flag"   '\[--manual-merge\]'

# --- Step 11.3 post-merge screenshot URL rewrite ordering (issue #506) ---
# The rewrite helper must fire AFTER `gh pr merge` and AFTER the mergeCommit.oid
# SHA capture (the SHA it pins to), but BEFORE the footer-append comment (so the
# rewriter targets the screenshot comment, not the freshly-posted footer).
first_line() { grep -nE -- "$1" "$SKILL" | head -1 | cut -d: -f1; }

want "Step 11.3 invokes rewrite-eval-screenshot-urls.sh" 'rewrite-eval-screenshot-urls\.sh'
want "Step 11.3 gates rewrite on PIPELINE_SCREENSHOT_REWRITE_ENABLED" 'PIPELINE_SCREENSHOT_REWRITE_ENABLED'

MERGE_LINE=$(first_line 'gh pr merge .*--merge --delete-branch')
SHA_LINE=$(first_line 'gh pr view .* --json mergeCommit --jq .mergeCommit.oid')
REWRITE_LINE=$(first_line 'rewrite-eval-screenshot-urls\.sh')
FOOTER_LINE=$(first_line 'Auto-merged: eval Approved')

ordering_ok=1
for v in "$MERGE_LINE" "$SHA_LINE" "$REWRITE_LINE" "$FOOTER_LINE"; do
  [ -n "$v" ] || ordering_ok=0
done
if [ "$ordering_ok" -eq 1 ] \
   && [ "$MERGE_LINE" -lt "$SHA_LINE" ] \
   && [ "$SHA_LINE" -lt "$REWRITE_LINE" ] \
   && [ "$REWRITE_LINE" -lt "$FOOTER_LINE" ]; then
  echo "  PASS: rewrite ordering merge($MERGE_LINE) < sha($SHA_LINE) < rewrite($REWRITE_LINE) < footer($FOOTER_LINE)"
else
  echo "  FAIL: rewrite ordering merge=$MERGE_LINE sha=$SHA_LINE rewrite=$REWRITE_LINE footer=$FOOTER_LINE"
  FAILED=$((FAILED+1))
fi

# --- Step 5b CI-wait must be a FOREGROUND in-turn wait (issue #684) ---
# A subagent cannot durably block on a backgrounded Bash; run_in_background
# ends its turn before the verdict/merge steps. The wait must run to
# completion within the subagent's own turn.
want "Step 5b foreground wait (timeout-bounded gh pr checks --watch)" \
  'timeout 600 gh pr checks .*--watch --fail-fast --interval 30'
if grep -qE 'run_in_background:?[[:space:]]*true' "$SKILL"; then
  echo "  FAIL: Step 5b must not instruct run_in_background:true (issue #684)"
  FAILED=$((FAILED+1))
else
  echo "  PASS: no run_in_background:true in evaluate-issue-pr SKILL.md"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: evaluator prose matches contract"
