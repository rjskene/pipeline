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

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: evaluator prose matches contract"
