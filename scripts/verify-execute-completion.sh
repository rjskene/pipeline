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
# #1056 — ADDITIVE `--verify-dispatch <N> <A|B|C|D>` mode (post-hoc model + shape
# verify): asserts the dispatched model + dispatch shape match what
# scripts/resolve-execute-dispatch.sh specified, closing the invisible
# cost-regression property. It emits its OWN `DISPATCH=` token contract and never
# alters the default-mode `ACTION=` output above. See the dispatch block below.
# #1186 widened the accepted path set to A|B|C|D alongside the resolver: PATH A
# execute and every PATH C leaf now carry a real resolved `model=`, so their
# dispatches are verifiable rather than merely declared. Stage words (pr-eval)
# stay refused — the W3 structural guard is widened, not removed.

set -uo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <issue-number>" >&2
  echo "       $0 --verify-dispatch <issue-number> <A|B|C|D>" >&2
  echo "       $0 --clean-main <main-repo-dir> [--since <baseline-file>] [--issue <N>]" >&2
  echo "       $0 --clean-main-baseline <main-repo-dir> <baseline-file>" >&2
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
#   VED_EXPECT_MODEL       — resolver MODEL= (sonnet|opus|haiku|fable; #1186
#                            retired `inherit` — MODEL= is always named)
#   VED_EXPECT_SPLIT_ROLE  — resolver SPLIT_ROLE= (true|false)
#   VED_OBSERVED_MODEL     — the model actually dispatched; recorded at dispatch
#                            for the inline path. Empty => try the spawn-claude
#                            runs log `model=` column (the --spawn transport),
#                            else WARN.
if [ "$1" = "--verify-dispatch" ]; then
  if [ $# -lt 3 ]; then
    echo "Usage: $0 --verify-dispatch <issue-number> <A|B|C|D>" >&2
    exit 2
  fi
  VD_ISSUE="$2"
  VD_PATH="$3"
  # #1186: accept every path letter the execute resolver resolves. The shape
  # scan keys off VED_EXPECT_SPLIT_ROLE, which is false for A/C/D, so those are
  # a pure model check. Stage words still exit 2 (W3).
  case "$VD_PATH" in
    A|B|C|D) ;;
    *)
      echo "Usage: $0 --verify-dispatch <issue-number> <A|B|C|D>" >&2
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
  # Resolve the feature ref deterministically — the same cascade as the default
  # ACTION= mode below — so the anchor scan works when the orchestrator session
  # sits on the base branch (HEAD == base → <base>..HEAD window is empty, #1077).
  # Cascade: worktree-porcelain → closedByPullRequestsReferences → gh pr list.
  # Falls back to HEAD when no ref resolves (preserves original behaviour for
  # the case where HEAD IS the feature branch, e.g. called from a worktree).
  if [ "$EXPECT_SPLIT" = "true" ]; then
    _vd_wt_prefix="${PIPELINE_WORKTREE_PREFIX:-wt}"
    _vd_feature_ref=$(git worktree list --porcelain 2>/dev/null | awk \
      -v p="${_vd_wt_prefix}-${VD_ISSUE}" '
      /^worktree / { base=$2; sub(/.*\//,"",base); inmatch=(base==p || base ~ "^"p"-") }
      inmatch && /^branch / { sub(/^branch refs\/heads\//,"",$0); print $0; exit }')
    if [ -z "$_vd_feature_ref" ]; then
      _vd_feature_ref=$(gh issue view "$VD_ISSUE" --repo "${PIPELINE_REPO:-fake/repo}" \
        --json closedByPullRequestsReferences \
        --jq '.closedByPullRequestsReferences[0].headRefName // empty' 2>/dev/null || true)
    fi
    if [ -z "$_vd_feature_ref" ]; then
      _vd_feature_ref=$(gh pr list --repo "${PIPELINE_REPO:-fake/repo}" \
        --search "linked:$VD_ISSUE" \
        --state open --json headRefName --jq '.[0].headRefName // empty' 2>/dev/null || true)
    fi
    # Fall back to HEAD when no ref resolved (called from a worktree with HEAD on
    # the feature branch — the original behaviour is preserved exactly).
    _vd_scan_ref="${_vd_feature_ref:-HEAD}"
    _log="$(git log --format=%s "${VD_BASE}..${_vd_scan_ref}" 2>/dev/null || true)"
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

# ---------------------------------------------------------------------------
# --clean-main <main-repo-dir>
#
# Additive mode (#1122): report whether the orchestrator main checkout has
# staged or unstaged changes. Emits a single token on stdout:
#
#   CLEAN=ok             DIR=<dir>  — index clean, no tracked drift, no untracked paths
#   CLEAN=untracked-only DIR=<dir>  — ONLY untracked paths present (#1207): advisory,
#                                     NOT the #1122 index leak; callers must NOT stash
#   CLEAN=dirty          DIR=<dir>  — staged index entries and/or modified tracked files
#
# Exits 0 in every case (the token, not the exit code, carries the verdict).
# `git status --porcelain` is the cleanliness probe: empty iff index AND
# working tree are both clean. Non-empty output is CLASSIFIED rather than read
# as uniformly dirty (#1207): a `??` entry is untracked, any other XY field is
# an index or tracked-worktree change — the #1122 staged-but-uncommitted
# `git add` leak the guard exists to catch.
#
# #1262 — PER-DISPATCH ATTRIBUTION (additive, `--since`-gated):
#
#   --clean-main <main-repo-dir> [--since <baseline-file>] [--issue <N>]
#       CLEAN=ok | CLEAN=untracked-only            (unchanged verdicts)
#       CLEAN=pre-existing DIR=<dir> [ISSUE=<N>]   dirty, but nothing NEW since
#                                                  the baseline — NOT this
#                                                  agent's doing
#       CLEAN=leak DIR=<dir> [ISSUE=<N>] PATHS=<comma-joined delta>
#       CLEAN=error DIR=<dir> [ISSUE=<N>] REASON=missing-baseline
#       CLEAN=error DIR=<dir> [ISSUE=<N>] REASON=unrecognized-arg:<token>
#                                          (#1266 — an unrecognised option-loop
#                                          token, never silently dropped)
#
#   --clean-main-baseline <main-repo-dir> <baseline-file>
#       BASELINE=captured DIR=<dir> PATHS=<line-count>
#       BASELINE=error    DIR=<dir> REASON=not-a-repo
#
# SCOPE: the delta is a PATH SET, not file content. A leak onto a path that was
# ALREADY dirty at baseline therefore reports `pre-existing`, not `leak` — the
# path set is unchanged. That is the deliberate fail-quiet direction: the mode
# never accuses an agent of dirt it may not have caused.
#
# The #1122 boundary check runs at the WAVE/LEG boundary — structurally too late
# to ATTRIBUTE a leak, because the agent whose mis-anchored `git add` caused it
# has already returned. Running the check per dispatch needs a DELTA, not a
# snapshot: a bare post-dispatch `--clean-main` would blame the agent that just
# returned for dirt that predated it. Hence the baseline. `CLEAN=pre-existing`
# is a distinct token precisely so "dirty but not yours" never reads as an
# accusation.
#
# ADDITIVITY is the hard constraint: with NO `--since`, the `--clean-main`
# branch is behaviourally unchanged and can never emit `leak`/`pre-existing`.
# The helper NEVER chooses the baseline path itself — the caller names the file,
# keeping this script namespace-neutral w.r.t. the consumer `.claude/`
# allow-list (`.claude/logs/` is `PIPELINE_LOGS_ENABLED`-gated and defaults to
# no-write, so a baseline written there would silently vanish).
# ---------------------------------------------------------------------------

# _cm_dirty_paths <dir> -> one TRACKED/index-dirty path per line, sorted+unique.
# Untracked (`??`) entries are dropped, so the #1207 `untracked-only` property
# survives into the delta. A porcelain rename (`R  a.txt -> c.txt`) collapses to
# its DESTINATION path — the raw arrow form is not a path and must never reach
# the `PATHS=` field.
_cm_dirty_paths() {
  local _cm_d="$1"
  git -C "$_cm_d" status --porcelain 2>/dev/null \
    | grep -v -e '^??' \
    | cut -c4- \
    | sed -e 's/^.* -> //' \
    | LC_ALL=C sort -u
}

if [ "$1" = "--clean-main" ]; then
  if [ $# -lt 2 ]; then
    echo "Usage: $0 --clean-main <main-repo-dir> [--since <baseline-file>] [--issue <N>]" >&2
    exit 2
  fi
  CM_DIR="$2"
  shift 2
  CM_SINCE=""
  CM_SINCE_SEEN=0
  CM_ISSUE=""
  CM_BADARG=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --since)
        # Track the FLAG, not its value: `--since` with a missing/empty operand
        # must report `missing-baseline`, never silently degrade to the legacy
        # un-attributed `CLEAN=dirty` verdict.
        CM_SINCE_SEEN=1
        shift
        CM_SINCE="${1:-}"
        [ $# -gt 0 ] && shift
        ;;
      --issue)
        shift
        CM_ISSUE="${1:-}"
        [ $# -gt 0 ] && shift
        ;;
      *)
        # #1266: an unrecognised token (typo'd flag, stale flag from a
        # mismatched checkout, an orphaned value) must NEVER be silently
        # dropped — a dropped `--since` degrades the run to the legacy
        # un-attributed `CLEAN=dirty` verdict with no signal that the
        # requested attribution mode was never armed. Record it and stop
        # parsing; same contract as the missing-baseline path below: a
        # single emitted token, exit 0, verdict rides the token.
        CM_BADARG="$1"
        break
        ;;
    esac
  done

  if [ -n "$CM_BADARG" ]; then
    CM_ISSUE_FIELD=""
    [ -n "$CM_ISSUE" ] && CM_ISSUE_FIELD=" ISSUE=$CM_ISSUE"
    echo "CLEAN=error DIR=$CM_DIR${CM_ISSUE_FIELD} REASON=unrecognized-arg:$CM_BADARG"
    exit 0
  fi

  # #1207: classify porcelain output rather than treating ANY output as dirty.
  # An entry is untracked iff its XY status field is `??`; every other XY
  # (`A `, `M `, ` M`, `R `, `D `, `UU`, ...) is an index or tracked-worktree
  # change — the #1122 leak condition. Ignored paths never appear (no --ignored).
  CM_STATUS="$(git -C "$CM_DIR" status --porcelain 2>/dev/null || true)"

  # ---- Default (#1122/#1207) contract — unchanged when no baseline is named --
  if [ "$CM_SINCE_SEEN" -eq 0 ]; then
    if [ -z "$CM_STATUS" ]; then
      echo "CLEAN=ok DIR=$CM_DIR"
    elif printf '%s\n' "$CM_STATUS" | grep -q -v -e '^??'; then
      echo "CLEAN=dirty DIR=$CM_DIR"
    else
      echo "CLEAN=untracked-only DIR=$CM_DIR"
    fi
    exit 0
  fi

  # ---- #1262 attribution mode (delta against the caller-named baseline) ------
  CM_ISSUE_FIELD=""
  [ -n "$CM_ISSUE" ] && CM_ISSUE_FIELD=" ISSUE=$CM_ISSUE"

  if [ -z "$CM_SINCE" ] || [ ! -r "$CM_SINCE" ]; then
    # Advisory, never a wrong verdict: without the baseline there is no delta to
    # compute, and guessing one would misattribute pre-existing dirt.
    echo "CLEAN=error DIR=$CM_DIR${CM_ISSUE_FIELD} REASON=missing-baseline"
    exit 0
  fi
  if [ -z "$CM_STATUS" ]; then
    echo "CLEAN=ok DIR=$CM_DIR${CM_ISSUE_FIELD}"
    exit 0
  fi
  if ! printf '%s\n' "$CM_STATUS" | grep -q -v -e '^??'; then
    echo "CLEAN=untracked-only DIR=$CM_DIR${CM_ISSUE_FIELD}"
    exit 0
  fi

  CM_NOW="$(_cm_dirty_paths "$CM_DIR" || true)"
  # LC_ALL=C on `comm` is LOAD-BEARING, not hygiene: both inputs are written by
  # `_cm_dirty_paths` under `LC_ALL=C sort -u`, so a `comm` running under any
  # other collation (e.g. en_US.UTF-8, where `B.txt` sorts before `a.txt`)
  # considers its input unsorted and re-emits BASELINE lines as delta — turning
  # the operator's own pre-existing dirt into a false `CLEAN=leak` that Step 6's
  # recovery would then `restore --staged` + `stash push`.
  CM_DELTA="$(LC_ALL=C comm -13 "$CM_SINCE" <(printf '%s\n' "$CM_NOW") 2>/dev/null || true)"
  CM_DELTA="$(printf '%s\n' "$CM_DELTA" | grep -v '^[[:space:]]*$' || true)"
  if [ -z "$CM_DELTA" ]; then
    echo "CLEAN=pre-existing DIR=$CM_DIR${CM_ISSUE_FIELD}"
    exit 0
  fi
  CM_PATHS="$(printf '%s\n' "$CM_DELTA" | tr '\n' ',' | sed -e 's/,*$//')"
  echo "CLEAN=leak DIR=$CM_DIR${CM_ISSUE_FIELD} PATHS=$CM_PATHS"
  exit 0
fi

if [ "$1" = "--clean-main-baseline" ]; then
  if [ $# -lt 3 ]; then
    echo "Usage: $0 --clean-main-baseline <main-repo-dir> <baseline-file>" >&2
    exit 2
  fi
  CMB_DIR="$2"
  CMB_OUT="$3"
  if ! git -C "$CMB_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo "BASELINE=error DIR=$CMB_DIR REASON=not-a-repo"
    exit 0
  fi
  CMB_PARENT="$(dirname "$CMB_OUT")"
  [ -d "$CMB_PARENT" ] || mkdir -p "$CMB_PARENT" 2>/dev/null || true
  if ! _cm_dirty_paths "$CMB_DIR" > "$CMB_OUT" 2>/dev/null; then
    # A clean repo yields an empty pipeline (grep exits 1) — that is the SUCCESS
    # case and leaves a legitimate zero-length baseline. Only a genuinely absent
    # file is an error.
    if [ ! -f "$CMB_OUT" ]; then
      echo "BASELINE=error DIR=$CMB_DIR REASON=write-failed"
      exit 0
    fi
  fi
  CMB_COUNT="$(wc -l < "$CMB_OUT" 2>/dev/null | tr -d '[:space:]')"
  echo "BASELINE=captured DIR=$CMB_DIR PATHS=${CMB_COUNT:-0}"
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

# ---- Check 1b (#1258): remote ref present but STALE ---------------------------
# A prior push created the remote ref; work then continued locally without a
# follow-up push. Existence alone (Check 1 above) doesn't catch this — compare
# the local tip SHA against the remote ref SHA. This MUST run before Check 2/3
# below, so an unpushed local commit always wins over recover-pr/recover-label
# regardless of PR or label state (the reported bug: this case was previously
# falling through to Check 2's PR resolution — which can resolve a stale/closed
# PR reference via closedByPullRequestsReferences — and then to Check 3,
# wrongly emitting recover-label).
REMOTE_SHA=$(printf '%s\n' "$REMOTE_REF" | awk '{print $1; exit}')
LOCAL_SHA=$(git rev-parse "refs/heads/$BRANCH" 2>/dev/null || true)
if [ -n "$LOCAL_SHA" ] && [ -n "$REMOTE_SHA" ] && [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
  echo "ACTION=recover-push ISSUE=$ISSUE REASON=branch-unpushed"
  exit 0
fi

# ---- Check 2: PR open ---------------------------------------------------------
# #1260: `closedByPullRequestsReferences[0]` does NOT carry `headRefName`/`state`
# in gh's fixed query shape for that connection (confirmed against gh 2.91.0's
# api/query_builder.go: it requests only id/number/url/repository{...} for this
# field) — so a direct `.headRefName` read here never actually resolves in
# production. It DOES carry `number`; resolve the referenced PR's real state +
# headRefName via `gh pr view <number>` and require state == OPEN before
# trusting its head. A CLOSED/MERGED reference is treated as no-PR — falling
# through to the already open-scoped `gh pr list` fallback (unchanged) and then
# recover-pr — so recover-label can never fire against a stale/closed PR
# reference (the reported #1258/#1260 gap).
PR_REF_NUM=$(gh issue view "$ISSUE" --repo "$PIPELINE_REPO" \
  --json closedByPullRequestsReferences \
  --jq '.closedByPullRequestsReferences[0].number // empty' 2>/dev/null || true)
PR_HEAD=""
if [ -n "$PR_REF_NUM" ]; then
  PR_REF_INFO=$(gh pr view "$PR_REF_NUM" --repo "$PIPELINE_REPO" \
    --json state,headRefName \
    --jq '(.state // "") + "|" + (.headRefName // "")' 2>/dev/null || true)
  PR_REF_STATE="${PR_REF_INFO%%|*}"
  PR_REF_HEAD="${PR_REF_INFO#*|}"
  if [ "$PR_REF_STATE" = "OPEN" ]; then
    PR_HEAD="$PR_REF_HEAD"
  fi
fi
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
