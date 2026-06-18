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
#
# #1056 — ADDITIVE `--verify-dispatch <N> <B|D>` mode (post-hoc model + shape
# verify): asserts the dispatched model + dispatch shape match what
# scripts/resolve-execute-dispatch.sh specified, closing the invisible
# cost-regression property. It emits its OWN `DISPATCH=` token contract and never
# alters the default-mode `ACTION=` output above. See the dispatch block below.

set -uo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <issue-number>" >&2
  echo "       $0 --verify-dispatch <issue-number> <B|D>" >&2
  exit 2
fi

# ---- #1056: additive --verify-dispatch mode (post-hoc model + shape verify) --
# When invoked as `--verify-dispatch <N> <path>`, the helper does NOT run the
# default ACTION-token completion checks; it instead asserts the dispatched model
# + dispatch shape MATCH what resolve-execute-dispatch.sh specified, closing the
# "invisible cost regression" property (#1056). This is purely additive — the
# default positional `<issue-number>` ACTION= contract below is byte-for-byte
# unchanged. The new mode emits its OWN single-line token contract:
#
#   DISPATCH=match    ISSUE=<N>
#   DISPATCH=mismatch ISSUE=<N> REASON=model:<got>!=<want>
#   DISPATCH=mismatch ISSUE=<N> REASON=shape:single!=split-role
#   DISPATCH=warn     ISSUE=<N> REASON=model-unrecoverable
#
# Fail-soft, fail-CLOSED parity with the rest of the helper: any check that
# cannot CONFIRM a match emits `warn`/`mismatch`, never a spurious `match`. The
# verify is a backstop (surfaced WARN-level in the run log), not a hard gate — it
# FAILs only on a DEFINITE mismatch and WARNs when the observed model is
# unrecoverable (e.g. the inline path with no spawn-claude runs row). Exits 0 in
# every case (the token carries the verdict).
#
# Expected spec + observed model are threaded by the orchestrator at the call
# site via env (so the positional contract is untouched):
#   VED_EXPECT_MODEL       — resolver MODEL= (sonnet|opus|haiku|inherit)
#   VED_EXPECT_SPLIT_ROLE  — resolver SPLIT_ROLE= (true|false)
#   VED_OBSERVED_MODEL     — the model actually dispatched; recorded at dispatch
#                            for the inline path. Empty => try the spawn-claude
#                            runs log `model=` column (the --spawn transport),
#                            else WARN.
if [ "$1" = "--verify-dispatch" ]; then
  if [ $# -lt 3 ]; then
    echo "Usage: $0 --verify-dispatch <issue-number> <B|D>" >&2
    exit 2
  fi
  VD_ISSUE="$2"
  VD_PATH="$3"
  case "$VD_PATH" in
    B|D) ;;
    *)
      echo "Usage: $0 --verify-dispatch <issue-number> <B|D>" >&2
      exit 2
      ;;
  esac

  _vec_dir="$(dirname "${BASH_SOURCE[0]}")"
  if [ -f "${_vec_dir}/_resolve-config.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    source "${_vec_dir}/_resolve-config.sh"
  fi
  VD_BASE="${PIPELINE_BASE_BRANCH:-staging}"

  EXPECT_MODEL="${VED_EXPECT_MODEL:-}"
  EXPECT_SPLIT="${VED_EXPECT_SPLIT_ROLE:-false}"
  OBSERVED="${VED_OBSERVED_MODEL:-}"

  # Inline path records no spawn-claude runs row; for the --spawn transport,
  # recover the observed model from the runs log `model=` column for this issue
  # (last matching row wins). Best-effort — absence => WARN, never a false match.
  if [ -z "$OBSERVED" ]; then
    _runs_log="${PIPELINE_RUNS_LOG_OVERRIDE:-.claude/logs/runs.log}"
    if [ -f "$_runs_log" ]; then
      OBSERVED="$(grep -E "issue=${VD_ISSUE}([^0-9]|$)" "$_runs_log" 2>/dev/null \
        | sed -n 's/.*model=\([A-Za-z0-9-]*\).*/\1/p' | tail -1 || true)"
    fi
  fi

  # --- Shape verify FIRST (a collapsed split-role pair is a definite mismatch) -
  if [ "$EXPECT_SPLIT" = "true" ]; then
    _log="$(git log --format=%s "${VD_BASE}..HEAD" 2>/dev/null || true)"
    if ! printf '%s\n' "$_log" | grep -qF '[split-role-red]'; then
      echo "DISPATCH=mismatch ISSUE=$VD_ISSUE REASON=shape:single!=split-role"
      exit 0
    fi
  fi

  # --- Model verify ------------------------------------------------------------
  if [ -z "$OBSERVED" ]; then
    echo "DISPATCH=warn ISSUE=$VD_ISSUE REASON=model-unrecoverable"
    exit 0
  fi
  if [ -n "$EXPECT_MODEL" ] && [ "$OBSERVED" != "$EXPECT_MODEL" ]; then
    echo "DISPATCH=mismatch ISSUE=$VD_ISSUE REASON=model:${OBSERVED}!=${EXPECT_MODEL}"
    exit 0
  fi

  echo "DISPATCH=match ISSUE=$VD_ISSUE"
  exit 0
fi

ISSUE="$1"
# Self-resolve PIPELINE_* from pipeline.config when callers source-but-don't-export
# them (e.g. fullsend/SKILL.md passes PIPELINE_REPO inline but not
# PIPELINE_BASE_BRANCH — the first-invocation abort this fixes, #1022). The
# resolver is co-located in scripts/; it is idempotent + fail-closed, so the
# `:?` guards below remain the final fail-closed assertion.
_vec_dir="$(dirname "${BASH_SOURCE[0]}")"
if [ -f "${_vec_dir}/_resolve-config.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  source "${_vec_dir}/_resolve-config.sh"
fi
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
