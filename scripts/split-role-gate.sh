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
# pass tokens:
#   additive-ok          — red SHA found; no locked test modified/deleted; suite green.
#   additive-ok-ci-green — red SHA found; no locked test modified/deleted; the
#                          caller exported PIPELINE_CI_ROLLUP_GREEN=true (a green
#                          statusCheckRollup, precedent #957) so the SECONDARY
#                          suite-green re-run is SKIPPED on trust (#1078). The
#                          PRIMARY locked-test invariant still ran first.
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
#   no-red-sha → locked-test-modified → locked-test-deleted →
#   (PIPELINE_CI_ROLLUP_GREEN=true ? additive-ok-ci-green : suite-red)
#   → else additive-ok.
# The CI-trust short-circuit (additive-ok-ci-green) sits in the SECONDARY
# suite-green block, strictly AFTER the PRIMARY locked-test invariant — it can
# only convert the suite-green step into a trusted pass, never bypass the lock.
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
#     <test-path>   one or more test paths to lock. Default: $PIPELINE_TEST_ROOTS
#                   if set, else tests/.
#
# $PIPELINE_TEST_ROOTS (issue #1182): consulted ONLY when no positional
# <test-path>... args are given (positional args always win — see the
# three-tier resolution below). Default: tests/. Space/newline-separated for
# multiple roots. A repo whose tests do NOT live under tests/ (e.g.
# work-orchestrator's subagents/*/testing/) MUST set this or the W7 lock scope
# defaults to tests/, finds nothing, and the additive-only check vacuously
# passes. Glob roots (e.g. subagents/*/testing/) are shell-EXPANDED against the
# gate's CWD at eval time, so they must resolve to existing dirs — git's own
# pathspec `*` does not cross `/` and a trailing-slash wildcard pathspec
# matches nothing, so pre-expansion (not a literal git pathspec) is required.
# Use exact dir paths if the glob would not resolve at gate-eval time. NEVER
# read from pipeline.config by the gate itself — the caller must export/pass
# it (same as PIPELINE_BASE_BRANCH).
#
# Test command (suite-green check) comes from $PIPELINE_TEST_CMD (sourced from
# pipeline.config) — never hard-coded. When unset, the suite check is treated
# as a no-op pass (the lock invariant is the load-bearing assertion; a repo
# with no configured test command cannot be run by the gate).
#
# $PIPELINE_CI_ROLLUP_GREEN (opt-in trust signal, #1078): when set to "true" the
# caller asserts the PR's statusCheckRollup is already green (same #957 trust
# boundary evaluate-issue-pr uses to skip its own local re-run). The gate then
# SKIPS the SECONDARY $PIPELINE_TEST_CMD re-run and emits additive-ok-ci-green
# instead of re-running the ~9–11min sweep. Default-unset → gate runs its own
# suite check exactly as before. NEVER read from pipeline.config — set only by
# the eval-time caller from its already-resolved $ROLLUP_GREEN.
#
# $PIPELINE_SPLIT_ROLE_SHARED_TESTS (opt-in exemption, #1089, Direction 3):
# A space- or newline-separated list of EXACT repo-relative test file paths that
# the approved `## Implementation Plan`'s `**Shared tests (split-role):**` section
# sanctioned for green-role modification. A Modified (M) locked test file whose
# EXACT path is listed here is EXEMPT from the additive-only invariant — a
# plan-sanctioned green edit (e.g. hardening an assertion/failure-message) is no
# longer a violation. Exemption is MODIFY-ONLY: a Deleted (D) locked test always
# blocks (locked-test-deleted) regardless of this list. Exact-path match only —
# no prefix/glob/directory match (a `tests/` blanket exemption is impossible).
# Default-unset/empty → gate behavior is BYTE-IDENTICAL to the pre-#1089 state
# (default-deny; all existing cases a–k remain unchanged). Set ONLY by the
# eval-time caller from the resolved approved plan — NEVER read from pipeline.config
# (reading from config would make a host-global exemption, defeating per-issue
# scoping). This var is evaluated inside the first-pass modified-file loop,
# BEFORE the tamper check; a listed file is skipped (continue) so the deletion
# check below still runs normally on D files.
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
# Locked-test invariant (frozen contract §3, W7; narrowed #1201): "locked
# tests" = every file under the test-path set whose BASENAME matches the
# discoverable-test glob set ($PIPELINE_TEST_FILE_GLOBS, default set above)
# and that EXISTS at <red-sha>. A data fixture/golden/schema living under a
# test root but NOT matching a discoverable-test basename pattern is not a
# locked test — it falls out of scope by default (re-lockable per repo via
# the knob). The invariant is ADDITIVE-AWARE: the RED suite may only be ADDED
# to, never weakened. For each
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

# Remaining args are <test-path>...; three-tier scope precedence (#1182):
#   1. explicit positional <test-path>... args (highest — keeps every existing
#      run_gate* helper byte-identical; they already pass `tests`).
#   2. else $PIPELINE_TEST_ROOTS, if non-empty: shell word-split + glob-EXPANDED
#      (globbing ON — NOT `set -f`). git's own pathspec `*` does not cross `/`,
#      and a trailing-slash wildcard pathspec (e.g. `subagents/*/testing/`)
#      matches nothing as a literal git pathspec — so a wildcard root MUST be
#      shell-expanded here into the real dirs git can then prefix-match.
#   3. else default to tests/ (unset-knob behavior is byte-identical to before).
if [ $# -ge 1 ]; then
  TEST_PATHS=("$@")
elif [ -n "${PIPELINE_TEST_ROOTS:-}" ]; then
  TEST_PATHS=( $PIPELINE_TEST_ROOTS )
else
  TEST_PATHS=("tests/")
fi

# $PIPELINE_TEST_FILE_GLOBS (issue #1201): scopes the locked-test invariant to
# DISCOVERABLE TEST FILES, not every path under the resolved test roots. A
# plan-sanctioned GREEN-phase data-fixture/golden regen (e.g. a JSON schema
# fixture under a test root) is not itself a test and must not trip
# locked-test-modified/-deleted. Patterns are matched against the file
# BASENAME only (directory scoping is already handled by the test-path
# resolution above / PIPELINE_TEST_ROOTS) via a `case` glob, never against the
# filesystem — so word-splitting below happens with globbing OFF (`set -f`);
# glob-expanding these patterns against the gate's CWD would let a decoy file
# there silently narrow the match set. Setting the knob REPLACES the built-in
# default wholesale (not additive) — the default's `:-` form is fail-safe: an
# explicitly-empty override would otherwise make the whole lock vacuous. NEVER
# read from pipeline.config by the gate itself — the caller must export it
# (same as PIPELINE_TEST_ROOTS).
DEFAULT_TEST_FILE_GLOBS='test_*.py *_test.py conftest.py test*.sh *_test.sh *_test.go
*.test.js *.test.jsx *.test.ts *.test.tsx *.spec.js *.spec.jsx *.spec.ts *.spec.tsx
test_*.rb *_spec.rb *Test.java'
set -f
TEST_FILE_GLOBS=( ${PIPELINE_TEST_FILE_GLOBS:-$DEFAULT_TEST_FILE_GLOBS} )
set +f
_is_test_file() {  # _is_test_file <repo-relative-path> → 0 iff basename matches a glob
  local base="${1##*/}" g
  for g in "${TEST_FILE_GLOBS[@]}"; do
    case "$base" in $g) return 0 ;; esac   # $g deliberately UNQUOTED (pattern match)
  done
  return 1
}
_filter_test_files() {  # stdin: newline paths → stdout: only test-FILE paths
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    _is_test_file "$p" && printf '%s\n' "$p"
  done
  return 0                                 # load-bearing under set -e (last _is_test_file
}                                           # may return 1 and would abort the pipeline)

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

# Red-commit SHA set: ALL [split-role-red]-subject commits in <base>..HEAD
# (same #1084 marker detection used to resolve RED_SHA; one SHA per line). Used
# by the two-dimensional red-authorship test below (#1121): a removal in a
# modified locked file is RED's own self-revision (allowed) ONLY if the removing
# commit is a marker commit AND the file was first-added in-window by a marker
# commit. `|| true` is load-bearing under `set -euo pipefail` (a no-match grep
# would otherwise abort before any later emit).
RED_SHAS="$( { printf '%s\n' "$LOG_OUT" | grep -F '[split-role-red]' | awk '{print $1}'; } || true)"
_is_red_sha() {  # _is_red_sha <sha> → 0 (true) iff <sha> is a marker commit
  case " $(printf '%s ' $RED_SHAS) " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

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
MOD_FILES="$(git diff "${RED_SHA}..HEAD" --diff-filter=M --name-only -- "${TEST_PATHS[@]}" 2>/dev/null | _filter_test_files || true)"
DEL_FILES="$(git diff "${RED_SHA}..HEAD" --diff-filter=D --name-only -- "${TEST_PATHS[@]}" 2>/dev/null | _filter_test_files || true)"

# First pass: any modified locked file with removed != 0 (or non-numeric) tampers.
# SHARED-TEST allow-list (#1089): if $PIPELINE_SPLIT_ROLE_SHARED_TESTS is set,
# a Modified (M) locked file whose EXACT path is listed is EXEMPT from the
# tamper check (the green role has plan-sanctioned permission to modify it).
# Deletion (D) is NEVER exempt — that check is handled separately below.
SHARED_TESTS="${PIPELINE_SPLIT_ROLE_SHARED_TESTS:-}"
if [ -n "$MOD_FILES" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # SHARED-TEST exemption: exact-path match against the allow-list.
    # If this file is listed, skip the tamper check (it's plan-sanctioned).
    if [ -n "$SHARED_TESTS" ]; then
      _exempt=0
      # Iterate over space/newline-separated paths in the allow-list.
      while IFS= read -r _shared_path; do
        [ -n "$_shared_path" ] || continue
        if [ "$f" = "$_shared_path" ]; then
          _exempt=1
          break
        fi
      done <<< "$(printf '%s\n' $SHARED_TESTS)"
      if [ "$_exempt" -eq 1 ]; then
        continue  # Plan-sanctioned shared edit — not a violation for this file.
      fi
    fi
    # Two-dimensional red-authorship test (#1121). A removal (removed > 0) in a
    # locked file is RED's own self-revision (ALLOWED) ONLY if BOTH:
    #   (1) the removing commit carries `[split-role-red]` in its subject, AND
    #   (2) the file is red-authored — first ADDED within <base>..HEAD by a
    #       marker commit (a base-origin / pre-existing locked file is NEVER
    #       red-authored, so any removal in it is green tampering).
    # Otherwise the removal is green tampering → locked-test-modified. This
    # narrows the prior single-dimension `removed > 0` check so a multi-commit
    # RED suite (a later red commit revising an earlier red-authored test) is no
    # longer a false positive, while base-origin tampering (case f/h/p) and a
    # non-marker green commit weakening a red-added test (case q) still block.
    _f_add_sha="$(git log --diff-filter=A --format='%H' "${BASE}..HEAD" -- "$f" 2>/dev/null | tail -1)"
    _f_red_authored=0
    if [ -n "$_f_add_sha" ] && _is_red_sha "$_f_add_sha"; then _f_red_authored=1; fi
    # Walk every commit in <red>..HEAD that touches $f; inspect its per-file
    # removal count. Fail-closed on a binary/non-numeric numstat (preserved).
    while IFS= read -r _csha; do
      [ -n "$_csha" ] || continue
      _r="$(git show "$_csha" --numstat --format='' -- "$f" 2>/dev/null | awk 'NR==1{print $2}')"
      if ! printf '%s' "$_r" | grep -qE '^[0-9]+$'; then
        emit block locked-test-modified   # binary/non-numeric numstat → fail-closed
      fi
      if [ "$_r" -gt 0 ]; then
        if _is_red_sha "$_csha" && [ "$_f_red_authored" -eq 1 ]; then
          : # RED revising its own red-authored suite — not a violation.
        else
          emit block locked-test-modified
        fi
      fi
      # removed == 0 → purely additive in this commit → not a violation here.
    done <<< "$(git log --format='%H' "${RED_SHA}..HEAD" -- "$f" 2>/dev/null)"
    # No green-authored removal in this file → not a violation for this file.
  done <<< "$MOD_FILES"
fi

# No modified-tamper. Now deletions always block.
if [ -n "$DEL_FILES" ]; then
  emit block locked-test-deleted
fi

# --- Suite-green check (SECONDARY) -------------------------------------------
# Run the configured test command; require success. Command comes from
# $PIPELINE_TEST_CMD (never hard-coded). Unset → no-op pass (the repo declares
# no runnable suite; the lock invariant above is the load-bearing assertion).
#
# CI-trust short-circuit (issue #1078, precedent #957). This block is SECONDARY:
# it runs strictly AFTER the PRIMARY locked-test additive-only invariant above
# (which has already had its chance to hard-block and is NEVER reached by this
# short-circuit). When the caller has already resolved a green statusCheckRollup
# and exports PIPELINE_CI_ROLLUP_GREEN=true, the green CI suite IS this suite —
# re-running $PIPELINE_TEST_CMD here is pure duplication of the ~9–11min sweep.
# Trust CI and emit a DETERMINISTIC pass token (additive-ok-ci-green) instead of
# re-running the suite. Default-unset → the gate behaves exactly as before. This
# can ONLY convert the SECONDARY suite-green step into a trusted pass; it can
# never bypass the PRIMARY lock check (which precedes it).
if [ "${PIPELINE_CI_ROLLUP_GREEN:-}" = "true" ]; then
  emit pass additive-ok-ci-green
fi
if [ -n "${PIPELINE_TEST_CMD:-}" ]; then
  if ! bash -c "$PIPELINE_TEST_CMD" >/dev/null 2>&1; then
    emit block suite-red
  fi
fi

# All invariants hold ⇒ additive-only, suite green.
emit pass additive-ok
