#!/usr/bin/env bash
# pr-eval-preflight.sh — the mechanical checks that precede a PR evaluation (#1445).
#
# Usage: pr-eval-preflight.sh <issue> [--pr <num>] [--worktree <abs-path>]
#
# Stdout is EXACTLY one line:
#   PREFLIGHT=ok|block REASON=<token> PR=<n> FIXED=<csv|none>
# Everything else goes to stderr, and the exit status is ALWAYS 0 — the CALLER
# decides what a block means (fullsend skips the Opus dispatch; the evaluator's
# absent-line fallback runs this itself).
#
# ARM ORDER IS THE PRECEDENCE CONTRACT (same convention as
# scripts/auto-merge-gate.sh's token order):
#
#   0. argv/config     fatal: usage, config, no-pr
#   1. body-contract   fatal: body-contract            fixes: body-contract
#   2. ci              fatal: ci-red                   advisory: ci-pending,
#                                                                no-ci,
#                                                                ci-disabled
#   3. base/mergeable  fatal: base                     advisory: mergeable
#   4. guards          fatal: guards
#
# The FIRST fatal arm in that order wins -> `PREFLIGHT=block REASON=<token>`.
# With no fatal, the FIRST advisory in that order is reported ->
# `PREFLIGHT=ok REASON=<token>`. Neither -> `PREFLIGHT=ok REASON=none`.
#
# WHY `mergeable` IS ADVISORY, NOT FATAL. Preflight never pushes. The only
# remediation for a non-mergeable PR is the evaluator's own Step 8 rebase, so
# blocking here would park the PR at `pr-open` with no eval AND no rebase —
# plus GitHub's transient `UNKNOWN` mergeability would block spuriously.
# `baseRefName` stays FATAL: a base mismatch is the #295 zero-data-loss class
# and the evaluator cannot fix it.
#
# WHY AN UNSETTLED ROLLUP IS ADVISORY. skills/fullsend/SKILL.md Step 6b already
# documents `ACTION=pending` as "treat as green so step 7 still runs"; blocking
# an unsettled rollup would silently reverse that documented contract.
#
# WHY AN EMPTY ROLLUP IS `no-ci`, NOT `none`. The gate's green predicate maps
# `[]` to TRUE (nothing failed). "No CI" is not "CI green": reporting `none`
# would let the evaluator trust a rollup that never ran and skip ALL local
# testing on a no-CI consumer repo. `no-ci` / `ci-disabled` are advisories, so
# the evaluator's local-test fallback stays armed.
#
# NO-PIPE BODY SCANNING (#1381). Every body scan below uses a here-string or a
# `case` glob, NEVER `printf '%s' "$BODY" | grep -q …`: under `pipefail`,
# `grep -q` exits on first match and SIGPIPEs the producer, flipping the
# predicate OPEN on a large body (measured 18/20 misses at 12KB). This
# predicate's whole job is to fail CLOSED.
#
# NO `set -e`: exit 0 is contractual.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ISSUE=""
OPT_PR=""
OPT_WORKTREE=""

USAGE=""

# A value-taking flag MUST be followed by a value: `shift 2` with one word left
# FAILS, and without `set -e` the loop then re-matches the same flag FOREVER —
# no stdout line, no exit, the caller's foreground Bash call hangs to its
# timeout. fullsend Step 7 renders `--worktree <abs>` as the last argv pair, so
# an unsubstituted placeholder is one token away from stranding a wave.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr|--worktree)
      if [ "$#" -lt 2 ]; then
        echo "pr-eval-preflight: ERROR $1 requires a value" >&2
        USAGE=1
        shift
        continue
      fi
      case "$1" in
        --pr)       OPT_PR="$2" ;;
        --worktree) OPT_WORKTREE="$2" ;;
      esac
      shift 2 ;;
    --help|-h)
      echo "Usage: pr-eval-preflight.sh <issue> [--pr <num>] [--worktree <abs-path>]" >&2
      exit 0 ;;
    *)
      [ -z "$ISSUE" ] && ISSUE="$1"
      shift ;;
  esac
done

if [ -n "$USAGE" ] || [ -z "$ISSUE" ]; then
  [ -z "$ISSUE" ] && echo "pr-eval-preflight: ERROR missing <issue> argument" >&2
  echo "PREFLIGHT=block REASON=usage PR=0 FIXED=none"
  exit 0
fi

# ---------------------------------------------------------------------------
# #801 config recovery, BEFORE any arm reads a knob. Callers source
# pipeline.config in one bash step and run this in a SEPARATE subshell, where a
# non-exported value is simply absent. Same recovery as auto-merge-gate.sh, but
# hoisted ABOVE every arm: read from below ARM 2, a pipeline.config-only
# `PIPELINE_CI_CHECK_ENABLED=""` opt-out would be silently inverted into a
# `ci-red` block, and PIPELINE_WORKTREE_PREFIX would be out of scope for the
# PR-resolution cascade while in scope for ARM 4's identical lookup.
# ---------------------------------------------------------------------------
if [ -z "${PIPELINE_REPO:-}" ] || [ -z "${PIPELINE_BASE_BRANCH:-}" ]; then
  _pf_root="${PIPELINE_PROJECT_ROOT:-$(pwd)}"
  _pf_cfg="$_pf_root/pipeline.config"
  if [ ! -f "$_pf_cfg" ]; then
    _pf_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$_pf_root" ] && _pf_cfg="$_pf_root/pipeline.config"
  fi
  # shellcheck disable=SC1090
  [ -f "$_pf_cfg" ] && source "$_pf_cfg"
fi

# PIPELINE_REPO is the one knob with no in-band fallback — every arm needs it
# to reach GitHub. Report it as a LINE, never as a bare nonzero exit: the
# orchestrator parses a line and has no handling for "no output at all".
if [ -z "${PIPELINE_REPO:-}" ]; then
  echo "pr-eval-preflight: ERROR PIPELINE_REPO is unset and pipeline.config could not be sourced" >&2
  echo "PREFLIGHT=block REASON=config PR=0 FIXED=none"
  exit 0
fi

FATAL=""
ADVISORY=""
FIXES=""

# fatal <token> — record the FIRST fatal only (arm order = precedence).
fatal()    { [ -z "$FATAL" ] && FATAL="$1"; return 0; }
# advisory <token> — record the FIRST advisory only.
advisory() { [ -z "$ADVISORY" ] && ADVISORY="$1"; return 0; }
add_fix()  { FIXES="${FIXES:+$FIXES,}$1"; }

emit() {
  local verdict reason
  if [ -n "$FATAL" ]; then
    verdict="block"; reason="$FATAL"
  elif [ -n "$ADVISORY" ]; then
    verdict="ok";    reason="$ADVISORY"
  else
    verdict="ok";    reason="none"
  fi
  echo "PREFLIGHT=$verdict REASON=$reason PR=${PR:-0} FIXED=${FIXES:-none}"
  exit 0
}

# ---------------------------------------------------------------------------
# Resolve issue -> PR. `--pr` wins (fullsend always passes it, sourced from the
# Step 6b check-ci-fix-loop.sh line). Otherwise the three-stage deterministic
# cascade from scripts/check-ci-fix-loop.sh: closing PR -> the issue's own
# worktree branch ref -> a body reference. Never "latest open PR" (#909).
# ---------------------------------------------------------------------------
PR=""
if [ -n "$OPT_PR" ]; then
  PR="$OPT_PR"
else
  PR="$(gh issue view "$ISSUE" --repo "$PIPELINE_REPO" \
          --json closedByPullRequestsReferences \
          --jq '.closedByPullRequestsReferences[0].number // empty' 2>/dev/null)"
  if [ -z "$PR" ]; then
    WT_LIST="$(git worktree list --porcelain 2>/dev/null || true)"
    BR="$(awk -v p="${PIPELINE_WORKTREE_PREFIX:-wt}-${ISSUE}" '
      /^worktree / { base=$2; sub(/.*\//,"",base); inmatch=(base==p || base ~ "^"p"-") }
      inmatch && /^branch / { sub(/^branch refs\/heads\//,"",$0); print $0; exit }' <<<"$WT_LIST")"
    if [ -n "$BR" ]; then
      PR="$(gh pr list --repo "$PIPELINE_REPO" --head "$BR" --state open \
              --json number --jq '.[0].number // empty' 2>/dev/null)"
    fi
  fi
  if [ -z "$PR" ]; then
    # SC2097/SC2098 are expected and benign here (verbatim from
    # check-ci-fix-loop.sh L75-78): the `ISSUE=` prefix exports the value for
    # gh's `env.ISSUE` jq reference, while `"$ISSUE in:body"` reads the
    # identical outer value.
    # shellcheck disable=SC2097,SC2098
    PR="$(ISSUE="$ISSUE" gh pr list --repo "$PIPELINE_REPO" --state open \
            --search "$ISSUE in:body" --json number,body \
            --jq '[.[] | select(.body | test("#" + env.ISSUE + "\\b"))] | .[0].number // empty' 2>/dev/null)"
  fi
fi
PR="$(tr -d '\r' <<<"${PR}")"
if ! [[ "$PR" =~ ^[0-9]+$ ]]; then
  PR=0
  fatal no-pr
  echo "pr-eval-preflight: ERROR could not resolve a PR for issue #$ISSUE" >&2
  emit
fi

# ===========================================================================
# ARM 1 — body-contract (#1329). The ONLY write this script performs, and it
# targets the PR body, nothing under .claude/.
# ===========================================================================

SECTION_RE='^##[[:space:]]+Pre-existing failures[[:space:]]*$'

# body_has_section <scan-copy>
body_has_section() { grep -qE "$SECTION_RE" <<<"$1"; }

# body_claims_failures <scan-copy> — TRUE when the body asserts that STANDING
# failures exist, in which case the section is missing INFORMATION and only a
# human (or the evaluator) can supply it. Two arms:
#   (A) whole body — a `PRE-EXISTING:` line with a non-blank, non-`none` value.
#   (B) the `## Test plan` section ONLY — a line that pairs a failure word with
#       a STANDING-failure qualifier (`pre-existing` / `known failure`).
#
# WHY ARM B DEMANDS THE QUALIFIER. A bare `fail` keyword scan cannot tell a
# standing failure from the tdd-implementer discipline describing itself
# ("RED: the test fails before the fix", "watched it fail for the right
# reason", "negative control: the guard FAILS", a filename like
# `test-fallback-on-failure.sh`). Those phrasings are the normal content of
# this repo's own PR bodies, and this arm's verdict is FATAL and sits BEFORE
# any evaluator dispatch — so a false positive does not degrade, it WEDGES the
# wave (no eval, no label change, nothing to retry). The qualifier is what
# makes the signal precise enough to carry a pre-dispatch block; the residual
# risk runs the other way (a vague "2 tests fail" body gets auto-fixed to
# `PRE-EXISTING: none`), which is bounded: the write is surfaced as
# `FIXED=body-contract` for audit and the evaluator runs the suite itself.
body_claims_failures() {
  local scan="$1" hits tp
  hits="$(grep -E 'PRE-EXISTING:[[:space:]]*[^[:space:]]' <<<"$scan" || true)"
  hits="$(grep -vE 'PRE-EXISTING:[[:space:]]*[Nn][Oo][Nn][Ee][[:space:]]*$' <<<"$hits" || true)"
  [ -n "$hits" ] && return 0

  tp="$(awk '/^##[[:space:]]+Test plan/{f=1;next} f && /^##[[:space:]]/{f=0} f' <<<"$scan")"
  hits="$(grep -iE 'pre-?existing|pre existing|known (test )?failure' <<<"$tp" || true)"
  hits="$(grep -iE 'fail' <<<"$hits" || true)"
  hits="$(grep -ivE '(no|zero|none|0) (known )?(pre-?existing )?fail|fail[a-z]*[:=][[:space:]]*(none|0)|all (tests|checks) pass' <<<"$hits" || true)"
  [ -n "$hits" ] && return 0
  return 1
}

BODY="$(gh pr view "$PR" --repo "$PIPELINE_REPO" --json body --jq .body 2>/dev/null)"
BODY_RC=$?
# Strip CR into the SCAN COPY ONLY — never rewrite the stored body's line
# endings (the #1158 CRLF seam cuts both ways).
SCAN="$(tr -d '\r' <<<"$BODY")"

# FAIL CLOSED ON AN UNREADABLE BODY, exactly as the ci arm does for an
# unreadable rollup. A `gh` blip (rate limit, 5xx, network) returns rc!=0 with
# EMPTY stdout, which is byte-identical to "the body is empty" — and the fix
# below is an APPEND to `$BODY`, so an empty `$BODY` silently turns it into a
# FULL OVERWRITE of a live PR description. That is irreversible (GitHub keeps
# no body history) and it destroys the `Closes #<N>` line that
# closedByPullRequestsReferences — and this script's own stage-1 PR cascade —
# depends on. An rc=0 empty body is treated the same way: there is nothing to
# append TO, and an empty body is itself a #1329 violation a human must fix.
if [ "$BODY_RC" -ne 0 ] || [ -z "$SCAN" ]; then
  echo "pr-eval-preflight: BLOCK body-contract — PR #$PR's body is unreadable or empty (gh rc=$BODY_RC); NOT writing, an append over an unread body would clobber the description" >&2
  fatal body-contract
elif body_has_section "$SCAN"; then
  :
elif body_claims_failures "$SCAN"; then
  echo "pr-eval-preflight: BLOCK body-contract — PR #$PR describes pre-existing failures but carries no '## Pre-existing failures' section (#1329); a human or the evaluator must list them" >&2
  fatal body-contract
else
  BODY_TMP="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$BODY_TMP'" EXIT
  printf '%s\n\n## Pre-existing failures\nPRE-EXISTING: none\n' "$BODY" > "$BODY_TMP"
  if gh pr edit "$PR" --repo "$PIPELINE_REPO" --body-file "$BODY_TMP" >/dev/null 2>&1; then
    # Re-read ONCE and confirm the section landed before claiming the fix
    # (#506: never report a write that did not happen).
    RECHECK="$(gh pr view "$PR" --repo "$PIPELINE_REPO" --json body --jq .body 2>/dev/null)"
    RECHECK="$(tr -d '\r' <<<"$RECHECK")"
    if body_has_section "$RECHECK"; then
      echo "pr-eval-preflight: FIXED body-contract — appended '## Pre-existing failures / PRE-EXISTING: none' to PR #$PR" >&2
      add_fix body-contract
    else
      echo "pr-eval-preflight: BLOCK body-contract — 'gh pr edit' reported success but the section is still absent on PR #$PR" >&2
      fatal body-contract
    fi
  else
    echo "pr-eval-preflight: BLOCK body-contract — 'gh pr edit' failed for PR #$PR; the section was NOT appended" >&2
    fatal body-contract
  fi
fi

# ===========================================================================
# ARM 2 — ci. The green predicate is the LITERAL jq program from
# scripts/auto-merge-gate.sh, reused rather than re-derived: the eval skill's
# old `length > 0 and all(.conclusion == "SUCCESS")` form mis-reads a re-run PR
# (an earlier FAILURE for a check whose LATEST run is SUCCESS) as red.
#
# The empty-rollup branch is evaluated FIRST, before that predicate, because
# the predicate maps `[]` to TRUE. See the `no-ci` note in the header.
# ===========================================================================

if [ "${PIPELINE_CI_CHECK_ENABLED-true}" != "true" ]; then
  # Colon-LESS fallback (#858): unset => ON; explicit "" => OFF (the no-CI
  # consumer contract). Reported as an ADVISORY so the evaluator's local-test
  # fallback stays armed — a disabled CI check is not a green one.
  echo "pr-eval-preflight: NOTE ci arm skipped (PIPELINE_CI_CHECK_ENABLED disabled)" >&2
  advisory ci-disabled
else
  ROLLUP_JSON="$(gh pr view "$PR" --repo "$PIPELINE_REPO" --json statusCheckRollup 2>/dev/null)"
  ROLLUP_RC=$?
  ROLLUP_LEN="$(tr -d '\r' <<<"$(jq -r '.statusCheckRollup | length' <<<"$ROLLUP_JSON" 2>/dev/null)")"
  if [ "$ROLLUP_RC" -ne 0 ] || [ -z "$ROLLUP_JSON" ] || ! [[ "$ROLLUP_LEN" =~ ^[0-9]+$ ]]; then
    # Fail CLOSED, mirroring the gate's cage-diff doctrine: an unreadable
    # rollup must never become an evasion vector for the check it replaces.
    echo "pr-eval-preflight: WARN ci arm unproven for PR #$PR (gh rc=$ROLLUP_RC, unreadable statusCheckRollup) — failing closed as ci-red" >&2
    fatal ci-red
  elif [ "$ROLLUP_LEN" -eq 0 ]; then
    echo "pr-eval-preflight: NOTE PR #$PR has an EMPTY statusCheckRollup — no CI ran; this is not a green verdict" >&2
    advisory no-ci
  elif jq -e '.statusCheckRollup | length == 0 or (group_by(.name) | all(last.conclusion == "SUCCESS"))' <<<"$ROLLUP_JSON" >/dev/null 2>&1; then
    :
  else
    # statusCheckRollup is HETEROGENEOUS: CheckRun rows carry .name/.conclusion,
    # StatusContext rows (commit statuses — Buildkite/CircleCI/Jenkins/Travis)
    # carry .context/.state. Reading only .conclusion sees `null` for a
    # definitely-FAILED commit status and calls the rollup merely unsettled, so
    # an Opus eval gets dispatched on a red head — the exact spend this script
    # exists to prevent. Group by `.name // .context` and read
    # `.conclusion // .state`. SKIPPED/NEUTRAL stay UNCLASSIFIED on purpose:
    # they are already non-green under the gate's predicate (so no eval trusts
    # them), and calling them fatal here would newly block evals the pipeline
    # runs today over a benignly-skipped conditional job.
    CI_BAD="$(tr -d '\r' <<<"$(jq -r '[.statusCheckRollup | group_by(.name // .context)[] | last | (.conclusion // .state)]
        | map(select(. == "FAILURE" or . == "CANCELLED" or . == "TIMED_OUT"
                     or . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE"
                     or . == "ERROR"))
        | length' <<<"$ROLLUP_JSON" 2>/dev/null)")"
    if ! [[ "$CI_BAD" =~ ^[0-9]+$ ]]; then
      echo "pr-eval-preflight: WARN could not classify PR #$PR's rollup conclusions — failing closed as ci-red" >&2
      fatal ci-red
    elif [ "$CI_BAD" -gt 0 ]; then
      echo "pr-eval-preflight: BLOCK ci-red — PR #$PR has $CI_BAD definitely-failed check(s) in its latest-per-name rollup" >&2
      fatal ci-red
    else
      echo "pr-eval-preflight: NOTE PR #$PR's rollup is UNSETTLED (no definite failure) — advisory ci-pending" >&2
      advisory ci-pending
    fi
  fi
fi

# ===========================================================================
# ARM 3 — base / mergeable.
# ===========================================================================

PR_META="$(gh pr view "$PR" --repo "$PIPELINE_REPO" --json baseRefName,mergeable 2>/dev/null)"
PR_BASE="$(tr -d '\r' <<<"$(jq -r '.baseRefName // empty' <<<"$PR_META" 2>/dev/null)")"
PR_MERGEABLE="$(tr -d '\r' <<<"$(jq -r '.mergeable // empty' <<<"$PR_META" 2>/dev/null)")"

if [ -z "${PIPELINE_BASE_BRANCH:-}" ]; then
  # Fail-safe (#801): an unresolvable base is a config error, not a real
  # divergence — but exit 0 is contractual here, so it still blocks loudly.
  echo "pr-eval-preflight: ERROR PIPELINE_BASE_BRANCH is empty (pipeline.config not found/sourced); cannot evaluate PR #$PR's base" >&2
  fatal base
elif [ -z "$PR_BASE" ]; then
  echo "pr-eval-preflight: BLOCK base — could not read PR #$PR's baseRefName" >&2
  fatal base
elif [ "$PR_BASE" = "$PIPELINE_BASE_BRANCH" ]; then
  :
elif [ "$PR_BASE" = "${PIPELINE_NEXT_BRANCH:-next}" ]; then
  # Next-branch aware acceptance (#1131/#1148), mirroring auto-merge-gate.sh:
  # `next` is a valid base ONLY for a next-routed issue (it carries
  # ${PIPELINE_NEXT_LABEL:-next} or the legacy `next-major-release` alias).
  PF_LABELS="$(gh issue view "$ISSUE" --repo "$PIPELINE_REPO" --json labels \
                 --jq '[.labels[].name]' 2>/dev/null)"
  if jq -e --arg l "${PIPELINE_NEXT_LABEL:-next}" \
       'index($l) != null or index("next-major-release") != null' \
       <<<"$PF_LABELS" >/dev/null 2>&1; then
    :
  else
    echo "pr-eval-preflight: BLOCK base — PR #$PR targets '${PIPELINE_NEXT_BRANCH:-next}' but issue #$ISSUE is not next-routed" >&2
    fatal base
  fi
else
  echo "pr-eval-preflight: BLOCK base — PR #$PR targets '$PR_BASE', expected '$PIPELINE_BASE_BRANCH'" >&2
  fatal base
fi

if [ "$PR_MERGEABLE" != "MERGEABLE" ]; then
  echo "pr-eval-preflight: NOTE PR #$PR mergeable='$PR_MERGEABLE' — ADVISORY only; the evaluator's Step 8 rebase is the remediation" >&2
  advisory mergeable
fi

# ===========================================================================
# ARM 4 — guards. Both run with cwd set to the FEATURE WORKTREE:
# check-branch-cruft.sh diffs origin/<base>..HEAD relative to the caller's cwd,
# so from the orchestrator checkout the arm would see zero paths and be
# VACUOUS. check-cross-cutting-guards.sh already bundles the cruft check as a
# CONDITIONAL sub-guard that goes INERT when the base is unresolved, so the
# explicit second call is what makes it unconditional.
# ===========================================================================

PF_WT="$OPT_WORKTREE"
if [ -z "$PF_WT" ]; then
  WT_LIST="$(git worktree list --porcelain 2>/dev/null || true)"
  PF_WT="$(awk -v p="${PIPELINE_WORKTREE_PREFIX:-wt}-${ISSUE}" '
    /^worktree / { path=$2; base=path; sub(/.*\//,"",base);
                   if (base==p || base ~ "^"p"-") { print path; exit } }' <<<"$WT_LIST")"
fi

if [ -z "$PF_WT" ] || [ ! -d "$PF_WT" ]; then
  echo "  INERT: guards (worktree unresolved) — this arm did NOT run" >&2
else
  if ! ( cd "$PF_WT" && bash "$SELF_DIR/check-cross-cutting-guards.sh" ) >&2; then
    echo "pr-eval-preflight: BLOCK guards — check-cross-cutting-guards.sh failed in $PF_WT" >&2
    fatal guards
  fi
  if ! ( cd "$PF_WT" && bash "$SELF_DIR/check-branch-cruft.sh" ) >&2; then
    echo "pr-eval-preflight: BLOCK guards — check-branch-cruft.sh failed in $PF_WT" >&2
    fatal guards
  fi
fi

emit
