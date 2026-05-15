#!/bin/bash
# Lint CLAUDE.md for the Auto-merge default subsection introduced by #122.
# Does NOT grep CHANGELOG, version strings, or auto-generated logs.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="${ROOT}/CLAUDE.md"
FAILED=0

want() {
  local name="$1" pat="$2"
  if grep -qE -- "$pat" "$DOC"; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name (pattern not found: $pat)"
    FAILED=$((FAILED+1))
  fi
}

want "section heading exists"                  '^## Auto-merge default'
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
echo "OK: CLAUDE.md auto-merge section matches contract"
