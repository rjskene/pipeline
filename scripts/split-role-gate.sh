#!/usr/bin/env bash
# Split-role TDD eval-time git-invariant gate (issue #881, W7).
#
# Script-decides eval-time gate for the split-role TDD lane
# (PIPELINE_PATH_B_SPLIT_ROLE=true). It asserts the load-bearing W7 invariant:
# the Opus test-author's failing suite (the `[split-role-red]` commit) was
# NEVER modified or deleted by the implementer — only ADDED to — and the suite
# is green at HEAD. Emits exactly ONE machine-readable line on stdout and
# ALWAYS exits 0 (the verdict rides the token, mirroring
# scripts/auto-merge-gate.sh + scripts/path-b-execute-eligible.sh):
#
#   SPLIT_ROLE=<pass|block> ISSUE=<N> REASON=<token>
#
# pass token:
#   additive-ok  — red SHA found; no locked test modified/deleted; suite green.
# block tokens:
#   no-red-sha           — no `[split-role-red]` commit on the branch
#                          (fail-closed: an unresolvable anchor blocks).
#   locked-test-modified — a test file present at the red SHA was changed.
#   locked-test-deleted  — a test file present at the red SHA was deleted.
#   suite-red            — red-SHA + lock checks pass but the suite is not green.
#
# Decision precedence (first failure wins):
#   no-red-sha → locked-test-modified → locked-test-deleted → suite-red
#   → else additive-ok.
#
# `evaluate-issue-pr` reads the token: SPLIT_ROLE=pass is a necessary
# greenlight precondition; any block-* token leaves the PR for manual merge
# (same shape as auto-merge-gate.sh's block-* tokens). pr-eval itself stays
# Opus in every configuration (W3) — this gate only adds a precondition.
#
# Usage:
#   split-role-gate.sh <issue-N> [<base-ref>] [<test-path>...]
#     <issue-N>     issue number, echoed back in the decision line.
#     <base-ref>    base ref the feature branch forked from; the red-SHA scan
#                   window is <base-ref>..HEAD. Default: $PIPELINE_BASE_BRANCH.
#     <test-path>   one or more test paths to lock. Default: tests/.
#
# Test command (suite-green check) comes from $PIPELINE_TEST_CMD (sourced from
# pipeline.config) — never hard-coded. When unset, the suite check is treated
# as a no-op pass (the lock invariant is the load-bearing assertion; a repo
# with no configured test command cannot be run by the gate).
#
# `[split-role-red]` marker semantics (frozen contract §2): the Opus
# test-author commits the complete failing suite ONCE, with the literal
# substring `[split-role-red]` in the commit SUBJECT line. The gate resolves
# <red-sha> as the MOST RECENT such commit on the branch:
#   git log --format='%H %s' <base>..HEAD | grep -F '[split-role-red]' | head -1
#
# Locked-test invariant (frozen contract §3, W7): "locked tests" = every file
# matching the test-path set that EXISTS at <red-sha>. The gate asserts
#   git diff <red-sha>..HEAD --diff-filter=MD -- <test-paths>
# is EMPTY (no Modified, no Deleted under the test paths). Additions
# (--diff-filter=A, new test files) are allowed and NOT flagged.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <issue-N> [<base-ref>] [<test-path>...]" >&2
  exit 2
fi

N="$1"
shift

# Optional <base-ref>: default to $PIPELINE_BASE_BRANCH.
BASE="${PIPELINE_BASE_BRANCH:-}"
if [ $# -ge 1 ]; then
  BASE="$1"
  shift
fi

# Remaining args are <test-path>...; default to tests/.
if [ $# -ge 1 ]; then
  TEST_PATHS=("$@")
else
  TEST_PATHS=("tests/")
fi

emit() {
  # emit <pass|block> <reason>
  echo "SPLIT_ROLE=$1 ISSUE=$N REASON=$2"
  exit 0
}

# --- Resolve the red SHA (fail-closed) --------------------------------------
# Most recent commit on <base>..HEAD whose SUBJECT contains `[split-role-red]`.
# Any failure to resolve a usable base/range or to find the marker blocks with
# no-red-sha (fail-closed — never greenlight without a verified anchor).
if [ -z "$BASE" ]; then
  emit block no-red-sha
fi

# git log over <base>..HEAD. Tolerate an unknown base ref (returns empty / fails)
# by mapping any failure to an empty scan → no-red-sha.
LOG_OUT="$(git log --format='%H %s' "${BASE}..HEAD" 2>/dev/null || true)"
# `|| true` is load-bearing: under `set -euo pipefail` a no-match grep returns
# non-zero and the failing pipeline would abort the script BEFORE emit() — which
# would violate the always-exit-0 contract. Mirror path-b-execute-eligible.sh's
# `$( { ...; } || true)` guard so a missing marker resolves to an empty RED_SHA
# and the no-red-sha block below fires cleanly.
RED_SHA="$( { printf '%s\n' "$LOG_OUT" | grep -F '[split-role-red]' | head -1 | awk '{print $1}'; } || true)"

if [ -z "$RED_SHA" ]; then
  emit block no-red-sha
fi

# --- Locked-test invariant (W7) ---------------------------------------------
# git diff <red-sha>..HEAD --diff-filter=MD -- <test-paths> must be empty.
# Modified (M) and Deleted (D) under the test paths are violations; Additions
# (A) are allowed and never surface here.  We inspect name+status so we can
# distinguish modified from deleted for the precedence-ordered token.
DIFF_MD="$(git diff "${RED_SHA}..HEAD" --diff-filter=MD --name-status -- "${TEST_PATHS[@]}" 2>/dev/null || true)"

if [ -n "$DIFF_MD" ]; then
  # Precedence: locked-test-modified before locked-test-deleted (frozen §1).
  if printf '%s\n' "$DIFF_MD" | grep -qE '^M[[:space:]]'; then
    emit block locked-test-modified
  fi
  if printf '%s\n' "$DIFF_MD" | grep -qE '^D[[:space:]]'; then
    emit block locked-test-deleted
  fi
  # Any other MD-filtered status (defensive) still blocks as a modification.
  emit block locked-test-modified
fi

# --- Suite-green check -------------------------------------------------------
# Run the configured test command; require success. Command comes from
# $PIPELINE_TEST_CMD (never hard-coded). Unset → no-op pass (the repo declares
# no runnable suite; the lock invariant above is the load-bearing assertion).
if [ -n "${PIPELINE_TEST_CMD:-}" ]; then
  if ! bash -c "$PIPELINE_TEST_CMD" >/dev/null 2>&1; then
    emit block suite-red
  fi
fi

# All invariants hold ⇒ additive-only, suite green.
emit pass additive-ok
