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
#   unresolvable-base    — <base-ref> was empty or unknown in the gate subprocess
#                          (env var not exported by caller; distinct from no-red-sha
#                          so operators are not sent chasing a phantom missing anchor).
#   no-red-sha           — base ref resolved but no `[split-role-red]` commit found.
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
# <red-sha> as the EARLIEST such commit on the branch:
#   git log --format='%H %s' <base>..HEAD | grep -F '[split-role-red]' | tail -1
# (`git log` is newest-first, so `tail -1` is the earliest match.) The RED
# test-author always commits the locked suite FIRST; any LATER commit whose
# subject also carries the literal `[split-role-red]` substring is an impl
# commit doing work ON the split-role machinery (e.g. #1077's GREEN referencing
# the anchor in its subject). Picking the earliest match avoids mis-anchoring on
# such an impl commit (#1084).
#
# Locked-test invariant (frozen contract §3, W7): "locked tests" = every file
# matching the test-path set that EXISTS at <red-sha>. The invariant is
# ADDITIVE-AWARE: the RED suite may only be ADDED to, never weakened. For each
# Modified (M) locked test file the gate inspects
#   git diff <red-sha>..HEAD --numstat -- <file>   (emits "<added> <removed> <file>")
# A purely-additive edit (removed == 0) cannot weaken a RED assertion and is
# ALLOWED. A pre-existing line deleted/altered (removed > 0), or a binary /
# non-numeric numstat (fail-closed), is tampering → locked-test-modified.
# Deleted (D) locked files ALWAYS block (locked-test-deleted) — no additive
# interpretation. New test files (--diff-filter=A) are allowed and never flagged.
# Precedence preserved: a real modified-tamper is emitted before deletion
# (check all modified files for tampering first; only if none tampers, then
# check deletions).

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
# EARLIEST commit on <base>..HEAD whose SUBJECT contains `[split-role-red]`
# (`git log` is newest-first, so `tail -1` is the earliest). The RED suite is
# committed FIRST; a later marker-mentioning commit is an impl commit (#1084).
# An UNRESOLVABLE base ref (empty or unknown) must emit a DISTINCT token
# (`unresolvable-base`) rather than `no-red-sha`, so operators can distinguish
# "base ref missing from subprocess env" from "author never committed a red
# anchor" (#1066). Fail-closed is correct; the token must be correct too.
if [ -z "$BASE" ]; then
  emit block unresolvable-base
fi

# Verify the base ref actually resolves in this repo before running git log.
# An invalid/unknown ref silently produces an empty log window under set -e
# with `|| true`, which would look identical to a missing red anchor. Detect
# this early and emit the distinct token.
if ! git rev-parse --verify "${BASE}" >/dev/null 2>&1; then
  emit block unresolvable-base
fi

# git log over <base>..HEAD. Tolerate an unknown base ref (returns empty / fails)
# by mapping any failure to an empty scan → no-red-sha.
LOG_OUT="$(git log --format='%H %s' "${BASE}..HEAD" 2>/dev/null || true)"
# `|| true` is load-bearing: under `set -euo pipefail` a no-match grep returns
# non-zero and the failing pipeline would abort the script BEFORE emit() — which
# would violate the always-exit-0 contract. Mirror path-b-execute-eligible.sh's
# `$( { ...; } || true)` guard so a missing marker resolves to an empty RED_SHA
# and the no-red-sha block below fires cleanly.
RED_SHA="$( { printf '%s\n' "$LOG_OUT" | grep -F '[split-role-red]' | tail -1 | awk '{print $1}'; } || true)"

if [ -z "$RED_SHA" ]; then
  emit block no-red-sha
fi

# --- Locked-test invariant (W7, additive-aware #1084) -----------------------
# Inspect Modified (M) and Deleted (D) locked test files under the test paths.
# Additions (A) are allowed and never surface here. We split the M and D checks:
#   - A Modified (M) locked file is tampering ONLY if a pre-existing line was
#     removed/altered. We read `git diff <red>..HEAD --numstat -- <file>` (emits
#     "<added> <removed> <file>"). removed == 0 → purely additive → ALLOWED.
#     removed > 0 → tampering → locked-test-modified. A non-numeric removed
#     (binary `-`) is treated as tampering (fail-closed).
#   - A Deleted (D) locked file ALWAYS blocks (locked-test-deleted) — no
#     additive interpretation.
# Precedence preserved (frozen §1): locked-test-modified before
# locked-test-deleted. We scan ALL modified files for tampering FIRST; if any
# tampers we block locked-test-modified; only if none tampers do we check
# deletions.
MOD_FILES="$(git diff "${RED_SHA}..HEAD" --diff-filter=M --name-only -- "${TEST_PATHS[@]}" 2>/dev/null || true)"
DEL_FILES="$(git diff "${RED_SHA}..HEAD" --diff-filter=D --name-only -- "${TEST_PATHS[@]}" 2>/dev/null || true)"

# First pass: any modified locked file with removed != 0 (or non-numeric) tampers.
if [ -n "$MOD_FILES" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # numstat for this one file: "<added>\t<removed>\t<file>".
    removed="$(git diff "${RED_SHA}..HEAD" --numstat -- "$f" 2>/dev/null | awk 'NR==1{print $2}')"
    if ! printf '%s' "$removed" | grep -qE '^[0-9]+$'; then
      # Non-numeric (binary `-`) or empty → fail-closed tampering.
      emit block locked-test-modified
    fi
    if [ "$removed" -gt 0 ]; then
      emit block locked-test-modified
    fi
    # removed == 0 → purely additive → not a violation for this file.
  done <<< "$MOD_FILES"
fi

# No modified-tamper. Now deletions always block.
if [ -n "$DEL_FILES" ]; then
  emit block locked-test-deleted
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
