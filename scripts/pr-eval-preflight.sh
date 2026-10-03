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

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr)       OPT_PR="${2:-}"; shift 2 ;;
    --worktree) OPT_WORKTREE="${2:-}"; shift 2 ;;
    --help|-h)
      echo "Usage: pr-eval-preflight.sh <issue> [--pr <num>] [--worktree <abs-path>]" >&2
      exit 0 ;;
    *)
      [ -z "$ISSUE" ] && ISSUE="$1"
      shift ;;
  esac
done

if [ -z "$ISSUE" ]; then
  echo "pr-eval-preflight: ERROR missing <issue> argument" >&2
  echo "PREFLIGHT=block REASON=usage PR=0 FIXED=none"
  exit 0
fi
: "${PIPELINE_REPO:?pr-eval-preflight: PIPELINE_REPO must be set}"

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

# body_claims_failures <scan-copy> — TRUE when the body asserts that failures
# exist, in which case the section is missing INFORMATION and only a human (or
# the evaluator) can supply it. Two arms:
#   (A) whole body — a `PRE-EXISTING:` line with a non-blank, non-`none` value.
#   (B) the `## Test plan` section ONLY — a line mentioning a failure that is
#       not one of the recognised negations.
body_claims_failures() {
  local scan="$1" hits tp
  hits="$(grep -E 'PRE-EXISTING:[[:space:]]*[^[:space:]]' <<<"$scan" || true)"
  hits="$(grep -vE 'PRE-EXISTING:[[:space:]]*[Nn][Oo][Nn][Ee][[:space:]]*$' <<<"$hits" || true)"
  [ -n "$hits" ] && return 0

  tp="$(awk '/^##[[:space:]]+Test plan/{f=1;next} f && /^##[[:space:]]/{f=0} f' <<<"$scan")"
  hits="$(grep -iE 'fail' <<<"$tp" || true)"
  hits="$(grep -ivE '(no|zero|none|0) (known )?(pre-?existing )?fail|fail[a-z]*[:=][[:space:]]*(none|0)|all (tests|checks) pass' <<<"$hits" || true)"
  [ -n "$hits" ] && return 0
  return 1
}

BODY="$(gh pr view "$PR" --repo "$PIPELINE_REPO" --json body --jq .body 2>/dev/null)"
# Strip CR into the SCAN COPY ONLY — never rewrite the stored body's line
# endings (the #1158 CRLF seam cuts both ways).
SCAN="$(tr -d '\r' <<<"$BODY")"

if body_has_section "$SCAN"; then
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

emit
