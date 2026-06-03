#!/usr/bin/env bash
# Orchestrator-side post-dispatch completion backstop (issue #912).
#
# #764's inline-execute dispatch-prompt directive ("your only valid terminal
# states are PR-open + pr-open ... narrate-and-yield is a FAILURE") landed and is
# present, but the drop-out it was meant to kill RECURRED (#838/#904): an inline
# PATH A/B/D execute Agent committed its work, then narrated an intent to "wait
# for the sweep Monitor" and ended its turn — stranding a committed-but-unpushed
# / no-PR branch with the issue stuck at `in-progress`. Prompt-only enforcement
# is racy against the agent's own decision to block on a Monitor it cannot await
# across a turn boundary. This helper is the missing ORCHESTRATOR-SIDE backstop:
# after an inline execute Agent returns, the orchestrator runs it to VERIFY the
# terminal state actually happened instead of trusting the agent's self-report,
# and acts on the emitted recover token when it didn't.
#
# Emits exactly one machine-readable line on stdout (ACTION-token contract —
# mirrors scripts/check-ci-fix-loop.sh; the token, not the exit code, carries the
# verdict, and the helper exits 0 in every case):
#
#   ACTION=complete           ISSUE=<N>
#   ACTION=recover-push       ISSUE=<N> REASON=branch-unpushed
#   ACTION=recover-pr         ISSUE=<N> REASON=no-pr
#   ACTION=recover-label      ISSUE=<N> REASON=label-stuck
#   ACTION=recover-redispatch ISSUE=<N> REASON=no-work
#
# Fail-closed: any check that cannot confirm a satisfied terminal state emits a
# recover token, never `complete`.

set -uo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <issue-number>" >&2
  exit 2
fi
ISSUE="$1"
: "${PIPELINE_REPO:?PIPELINE_REPO must be set}"
: "${PIPELINE_BASE_BRANCH:?PIPELINE_BASE_BRANCH must be set}"
: "${PIPELINE_WORKTREE_PREFIX:=wt}"

# ---- Branch resolution (DETERMINISTIC — NO `feature/issue-<N>` assumption) ----
# The `feature/issue-<N>` convention does NOT exist; the real convention is
# `feature/<title-slug>` (fullsend Step 5). So we resolve the branch the only
# deterministic way:
#   1. Primary — the issue's worktree from `git worktree list --porcelain`. The
#      worktree dir basename is `wt-<N>-<slug>` (setup-worktree.sh); read that
#      block's `branch refs/heads/<...>` line and strip `refs/heads/` to get the
#      branch name. Read VERBATIM, so any prefix (feature/, fix/, ...) resolves.
#   2. Secondary — the issue's linked PR head (the worktree may already be torn
#      down): closedByPullRequestsReferences[0].headRefName, then
#      `gh pr list --search "linked:<N>" --state open` (mirrors check-ci-fix-loop).
BRANCH=$(git worktree list --porcelain 2>/dev/null | awk -v p="${PIPELINE_WORKTREE_PREFIX}-${ISSUE}" '
  /^worktree / { base=$2; sub(/.*\//,"",base); inmatch=(base==p || base ~ "^"p"-") }
  inmatch && /^branch / { sub(/^branch refs\/heads\//,"",$0); print $0; exit }')

if [ -z "$BRANCH" ]; then
  BRANCH=$(gh issue view "$ISSUE" --repo "$PIPELINE_REPO" \
    --json closedByPullRequestsReferences \
    --jq '.closedByPullRequestsReferences[0].headRefName // empty' 2>/dev/null || true)
fi
if [ -z "$BRANCH" ]; then
  BRANCH=$(gh pr list --repo "$PIPELINE_REPO" --search "linked:$ISSUE" \
    --state open --json headRefName --jq '.[0].headRefName // empty' 2>/dev/null || true)
fi

# ---- Stranded: no branch name resolved at all (no worktree AND no linked PR) --
if [ -z "$BRANCH" ]; then
  echo "ACTION=recover-redispatch ISSUE=$ISSUE REASON=no-work"
  exit 0
fi

# ---- Check 1: remote branch pushed (remote pinned to `origin`) ----------------
# PIPELINE_REPO is the gh owner/repo slug, NOT a git remote; setup-worktree.sh
# uses `origin`. A branch name resolved but no remote ref => committed-but-unpushed.
REMOTE_REF=$(git ls-remote --heads origin "$BRANCH" 2>/dev/null || true)
if [ -z "$REMOTE_REF" ]; then
  echo "ACTION=recover-push ISSUE=$ISSUE REASON=branch-unpushed"
  exit 0
fi

# ---- Check 2: PR open ---------------------------------------------------------
PR_HEAD=$(gh issue view "$ISSUE" --repo "$PIPELINE_REPO" \
  --json closedByPullRequestsReferences \
  --jq '.closedByPullRequestsReferences[0].headRefName // empty' 2>/dev/null || true)
if [ -z "$PR_HEAD" ]; then
  PR_HEAD=$(gh pr list --repo "$PIPELINE_REPO" --search "linked:$ISSUE" \
    --state open --json headRefName --jq '.[0].headRefName // empty' 2>/dev/null || true)
fi
if [ -z "$PR_HEAD" ]; then
  echo "ACTION=recover-pr ISSUE=$ISSUE REASON=no-pr"
  exit 0
fi

# ---- Check 3: issue at `pr-open` ----------------------------------------------
LABELS=$(gh issue view "$ISSUE" --repo "$PIPELINE_REPO" \
  --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || true)
case ",$LABELS," in
  *,pr-open,*) ;;
  *)
    echo "ACTION=recover-label ISSUE=$ISSUE REASON=label-stuck"
    exit 0
    ;;
esac

# ---- All three satisfied ------------------------------------------------------
echo "ACTION=complete ISSUE=$ISSUE"
exit 0
