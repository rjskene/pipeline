#!/bin/bash
# Lint the auto-merge default contract introduced by #122.
# Originally guarded CLAUDE.md, but #397 moved the spec out of CLAUDE.md to
# its authoritative homes in the SKILL files. The four greenlight conditions
# live in skills/evaluate-issue-pr/SKILL.md; the three opt-outs are described
# in skills/fullsend/SKILL.md + skills/run/SKILL.md; the release-please-excluded
# note lives in both. The guard now lints across those files.
# Does NOT grep CHANGELOG, version strings, or auto-generated logs.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCS=(
  "${ROOT}/skills/evaluate-issue-pr/SKILL.md"
  "${ROOT}/skills/fullsend/SKILL.md"
  "${ROOT}/skills/run/SKILL.md"
)
FAILED=0

want() {
  local name="$1" pat="$2"
  if grep -qE -- "$pat" "${DOCS[@]}"; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name (pattern not found: $pat)"
    FAILED=$((FAILED+1))
  fi
}

want "condition 1: Verdict Approved"           'Verdict.*Approved'
want "condition 2: statusCheckRollup"          'statusCheckRollup'
want "condition 3: mergeable MERGEABLE"        'mergeable.*MERGEABLE'
want "condition 4: mergeStateStatus CLEAN"     'mergeStateStatus.*CLEAN'
want "opt-out 1: FULL SEND --manual-merge"     'FULL SEND.*--manual-merge|--manual-merge.*FULL SEND'
want "opt-out 2: skill --manual-merge"         '/pipeline:evaluate-issue-pr.*--manual-merge'
want "opt-out 3: manual-merge label"           'manual-merge.*label'
want "release-please excluded"                 'PIPELINE_RELEASE_PR_AUTO_MERGE'

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: auto-merge contract documented across evaluate-issue-pr/fullsend/run SKILL.md"
