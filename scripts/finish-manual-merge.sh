#!/bin/bash
# finish-manual-merge.sh — replay the auto-merge gate's post-merge bookkeeping
# for a PR that was merged BY HAND (the manual-merge / block-* recovery path).
#
# WHY (#655): pipeline PRs target the `staging` base branch, so the `Closes #N`
# line in the PR body — which GitHub only honors against the default branch —
# does NOT close the issue on merge. On the autonomous green path,
# `evaluate-issue-pr` Step 11 / `auto-merge-gate.sh` perform the close + label
# flip inline. When an operator instead hand-merges a `block-*` / `manual-merge`
# PR (`gh pr merge ...`), that bookkeeping never runs and the issue is left
# OPEN with labels wedged at `pr-open[,manual-merge]`. This helper is the
# recovery-path twin: it performs the same four bookkeeping operations
#   (add `merged`, remove `pr-open`, remove `manual-merge`, close with a
#    `Merged via PR #<PR>` comment)
# so the operator can run a single one-liner after a hand merge.
#
# The label-strip op is delegated to the shared `finalize-issue-labels.sh`
# helper (issue #866), so the merged-state strip-set stays in lockstep with the
# auto-merge path and `cleanup-worktree.sh` — it strips the full pipeline
# lifecycle/path/priority set, not just `pr-open`/`manual-merge`.
#
# It MIRRORS Step 11's bookkeeping rather than sourcing it: `auto-merge-gate.sh`
# exposes only the *decision* (`auto_merge_should_fire`), not the bookkeeping,
# which lives inline in the skill markdown. Refactoring Step 11 to call this
# helper is intentionally out of scope (#655) — it would touch the green path.
#
# Idempotent: safe to re-run if the labels are already correct / the issue is
# already closed. `gh issue edit --remove-label X` exits non-zero when X is
# absent (422) and `gh issue close` warns/errors on an already-closed issue;
# both are absorbed with `|| true`.
#
# Usage:
#   bash finish-manual-merge.sh <issue> <pr> [--repo <owner/repo>]
#
# Repo resolution: $PIPELINE_REPO env (or --repo flag) is required.
#
# Emits one audit line to stdout:
#   FINISHED: issue=<N> pr=<PR> labels=merged closed=yes
set -euo pipefail

REPO="${PIPELINE_REPO:-}"
ISSUE=""
PR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: finish-manual-merge.sh <issue> <pr> [--repo <owner/repo>]" >&2
      exit 0 ;;
    -*)
      echo "finish-manual-merge.sh: unknown arg: $1" >&2
      echo "Usage: finish-manual-merge.sh <issue> <pr> [--repo <owner/repo>]" >&2
      exit 2 ;;
    *)
      if [ -z "$ISSUE" ]; then ISSUE="$1"
      elif [ -z "$PR" ]; then PR="$1"
      else
        echo "finish-manual-merge.sh: unexpected extra arg: $1" >&2
        exit 2
      fi
      shift ;;
  esac
done

if [ -z "$ISSUE" ] || [ -z "$PR" ]; then
  echo "Usage: finish-manual-merge.sh <issue> <pr> [--repo <owner/repo>]" >&2
  exit 2
fi

if [ -z "$REPO" ]; then
  echo "finish-manual-merge.sh: PIPELINE_REPO (or --repo) is required" >&2
  exit 2
fi

# Flip labels via the shared strip-set helper (issue #866): add `merged` and
# strip the full pipeline lifecycle/path/priority set (not just
# `pr-open`/`manual-merge`). The helper owns the absent-label 422 fallback so
# the three merge-completion sites can never drift. See finalize-issue-labels.sh.
bash "$(dirname "${BASH_SOURCE[0]}")/finalize-issue-labels.sh" "$ISSUE" --repo "$REPO"

# Close with the merge note. `|| true` makes a re-run on an already-closed
# issue a no-op. The literal `Merged via PR #<PR>` wording is mandated by #655.
gh issue close "$ISSUE" --repo "$REPO" \
  --comment "Merged via PR #${PR}." 2>/dev/null || true

echo "FINISHED: issue=${ISSUE} pr=${PR} labels=merged closed=yes"
