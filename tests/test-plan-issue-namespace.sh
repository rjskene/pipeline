#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
# Grep for any bare /<skill> reference across source tree, then filter out lines
# whose match is actually the namespaced form (pipeline:plan-issue, etc.) or a
# false-positive like pipeline.config, /tmp/pipeline-cleanup, skills/pipeline.
HITS=$(grep -rEn '/plan-issue|/classify-issue|/execute-issue-plan|/evaluate-issue-plan|/evaluate-issue-pr|/create-issues|/worktree-sync|/pipeline\b' \
  skills/ scripts/ hooks/ agents/ README.md CLAUDE.md 2>/dev/null \
  | grep -vE 'pipeline:plan-issue|pipeline:classify-issue|pipeline:execute-issue-plan|pipeline:evaluate-issue-plan|pipeline:evaluate-issue-pr|pipeline:create-issues|pipeline:worktree-sync|pipeline:doctor|pipeline:run|pipeline:fullsend|pipeline:hotfix|pipeline:\$\{SKILL\}|pipeline\.config|pipeline-cleanup|/tmp/pipeline|/pipeline/SKILL|skills/pipeline|/proc/sys|skills/plan-issue|skills/classify-issue|skills/execute-issue-plan|skills/evaluate-issue-plan|skills/evaluate-issue-pr|skills/create-issues|skills/worktree-sync|skills/fullsend|skills/hotfix|claude-pipeline/pipeline|rjskene/pipeline' \
  || true)
if [ -n "$HITS" ]; then
  echo "FAIL: non-namespaced slash-command references found:"
  echo "$HITS"
  exit 1
fi
echo "PASS: zero non-namespaced slash-command references"
