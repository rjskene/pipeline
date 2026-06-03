#!/bin/bash
# finalize-issue-labels.sh — single source of truth for the merge-completion
# label strip-set (issue #866).
#
# WHY: three sites flip an issue to its terminal "merged" state — the auto-merge
# path in `evaluate-issue-pr` Step 11, the hand-merge recovery helper
# `finish-manual-merge.sh`, and the worktree teardown `cleanup-worktree.sh`.
# Each one used to inline its own (divergent) `--add-label merged --remove-label
# ...` flip, so the set of labels actually stripped DRIFTED between sites. This
# helper centralizes that flip: add `merged`, remove every pipeline-managed
# lifecycle / path / priority label, and tolerate gh's absent-label 422. The
# three call sites pass only the issue number, so the strip-set cannot drift.
#
# STRIP-SET CONTRACT (asserted by tests/test-finalize-issue-labels.sh):
#   IN  — all lifecycle labels (plan-pending, plan-reviewed, plan-approved,
#         in-progress, pr-open, manual-merge), all path labels (docs-only,
#         multi-task, quick-fix), all priority tiers (priority/P0..P3).
#   OUT — `merged` (the terminal marker render-status-table.sh reads — KEEP it),
#         non-pipeline type labels `bug`/`enhancement` (CHANGELOG signal read by
#         derive-pr-title.sh), `needs-browser` (issue-intrinsic capability flag),
#         and `tracker` (trackers are never merge-completed by these paths).
# The strip-set is hardcoded, NOT derived from doctor.sh's LABEL_TABLE — that
# table also holds EXCLUDED/LATER/HUMAN/BRAINSTORM triage labels that must NOT
# be stripped. A new lifecycle/path label registered later must be added to the
# STRIP_LABELS array below (and to the contract test).
#
# Usage:
#   bash finalize-issue-labels.sh <issue> [--repo <owner/repo>]
#
# Repo resolution order: --repo flag > $PIPELINE_REPO env > `gh repo view`
# current-repo (git remote) fallback (#888). One of these must resolve.
#
# Emits one audit line to stdout:
#   FINALIZED: issue=<N> labels=merged stripped=<count>
set -euo pipefail

REPO="${PIPELINE_REPO:-}"
ISSUE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: finalize-issue-labels.sh <issue> [--repo <owner/repo>]" >&2
      exit 0 ;;
    -*)
      echo "finalize-issue-labels.sh: unknown arg: $1" >&2
      echo "Usage: finalize-issue-labels.sh <issue> [--repo <owner/repo>]" >&2
      exit 2 ;;
    *)
      if [ -z "$ISSUE" ]; then ISSUE="$1"
      else
        echo "finalize-issue-labels.sh: unexpected extra arg: $1" >&2
        exit 2
      fi
      shift ;;
  esac
done

if [ -z "$ISSUE" ]; then
  echo "Usage: finalize-issue-labels.sh <issue> [--repo <owner/repo>]" >&2
  exit 2
fi

# Repo resolution order: --repo flag > $PIPELINE_REPO env > gh's current-repo
# config (the git remote). The fallback covers the Step-11.3 subshell case
# where PIPELINE_REPO was sourced but not exported into this context (#888).
if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi
if [ -z "$REPO" ]; then
  echo "finalize-issue-labels.sh: PIPELINE_REPO (or --repo, or a gh-resolvable current repo) is required" >&2
  exit 2
fi

# The merge-completion strip-set — the single source of truth. priority/* is
# enumerated as the four literal tiers (priority/P0..P3) because
# `gh issue edit --remove-label` takes literal names, not globs.
STRIP_LABELS=(
  plan-pending plan-reviewed plan-approved in-progress pr-open manual-merge
  docs-only multi-task quick-fix
  priority/P0 priority/P1 priority/P2 priority/P3
)

# Build a single combined `gh issue edit` adding `merged` and removing every
# strip-set label. The `|| ... --add-label merged || true` fallback mirrors the
# proven shape from finish-manual-merge.sh: gh 422s the WHOLE combined call if
# any single removed label is already absent, so the fallback re-runs only the
# `merged` add to guarantee it is never swallowed (the present labels are not
# removed on that run, but the flip is idempotent on re-run). On a fully-stripped
# (idempotent) issue this means exit 0 with `merged` preserved.
REMOVE_ARGS=()
for l in "${STRIP_LABELS[@]}"; do
  REMOVE_ARGS+=(--remove-label "$l")
done

# Attempt the combined add+strip. gh 422s the WHOLE call if any removed label
# is already absent, so on failure we retry the `merged` add alone (idempotent).
# Unlike before, the fallback's stderr is captured: a genuine total failure
# (bad repo, API error) now surfaces a WARN instead of a silent no-op (#888).
if ! gh issue edit "$ISSUE" --repo "$REPO" --add-label merged "${REMOVE_ARGS[@]}" 2>/dev/null; then
  EDIT_ERR="$(gh issue edit "$ISSUE" --repo "$REPO" --add-label merged 2>&1)" || {
    echo "WARN: finalize-issue-labels: label finalization failed for issue=${ISSUE} repo=${REPO}; labels may be stale. gh: ${EDIT_ERR}" >&2
  }
fi

echo "FINALIZED: issue=${ISSUE} labels=merged stripped=${#STRIP_LABELS[@]}"
