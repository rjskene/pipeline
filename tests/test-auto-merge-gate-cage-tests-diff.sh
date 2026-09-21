#!/usr/bin/env bash
# test-auto-merge-gate-cage-tests-diff.sh — #1304 block-cage-tests-diff token.
#
# scripts/auto-merge-gate.sh gains a `block-cage-tests-diff` token so a PR that
# WEAKENS the evolve loop's own cage — i.e. modifies, removes or renames a
# tests/test-cage-invariant-*.sh file — can never reach an auto-merge
# greenlight. Precedence:
#
#   block-flag > block-label > block-cage-tests-diff > block-verdict >
#   block-capability-refused > block-base-mismatch > block-ci >
#   block-mergeable > block-mergestate
#
# The two operator opt-outs (MANUAL_MERGE=1 / the manual-merge label) still
# precede it — the label IS the escape hatch, by ordering alone.
#
# Rules pinned here:
#   - `added:` cage tests never fire the token (adding an invariant STRENGTHENS
#     the cage; this is what keeps the founding PR from self-blocking).
#   - The file list comes from `gh api repos/<repo>/pulls/<pr>/files`, rendered
#     as `<status>:<filename>:<previous_filename>`. A match on EITHER name
#     blocks — that is what closes the rename-AWAY gap (`gh pr view --json
#     files` carries only the new path of a rename).
#   - An empty or unparseable listing fails CLOSED: stderr WARN AND the token,
#     so a `gh` failure cannot be used to wave a cage weakening through.
#
# Harness copied from tests/test-auto-merge-gate-capability-refusal.sh (gh shim
# + check + run_gate); every fixture is built under mktemp -d.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/scripts/auto-merge-gate.sh"

if [ ! -f "$HELPER" ]; then
  echo "FAIL: ${HELPER} does not exist"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ISSUE=1304

# --- gh shim ---------------------------------------------------------------
# NOTE the DELIBERATELY colon-LESS ${GH_FILES-...} default in the files arm:
# it substitutes only when GH_FILES is UNSET, so an explicitly-empty
# GH_FILES="" reaches the gate as genuinely empty and the empty-listing case
# (k) is reachable. (${GH_FILES:-...} would silently swap in the non-cage
# default on set-but-empty.) The EXISTING gate tests use the colon form on
# purpose — they never intend an empty listing.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'SHIM'
#!/bin/bash
ALL_ARGS="$*"
echo "gh $ALL_ARGS" >> "${CALL_LOG:-/dev/null}"
case "$ALL_ARGS" in
  *"issue view"*"--json labels"*)
    printf '%s\n' ${GH_LABELS:-}
    ;;
  *"pr view"*"--json baseRefName"*)
    printf '%s\n' "${GH_BASE_REF:-staging}"
    ;;
  *"pr view"*"--json comments"*"Evaluation"*)
    printf '%s' "${GH_EVAL_BODY:-}"
    ;;
  *"pr view"*"--json statusCheckRollup,mergeable,mergeStateStatus"*)
    printf '%s' "${GH_ROLLUP:-}"
    ;;
  *"pulls/"*"/files"*)
    printf '%s\n' "${GH_FILES-modified:scripts/auto-merge-gate.sh:}"
    # GH_FILES_RC lets a case make `gh api ... --paginate` PRINT a well-formed
    # page and THEN exit non-zero — the real-world partial-pagination failure.
    exit "${GH_FILES_RC:-0}"
    ;;
  *)
    echo "[gh shim] unhandled: $ALL_ARGS" >&2
    exit 1
    ;;
esac
SHIM
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export CALL_LOG="$TMP/calls.log"
export PIPELINE_REPO="test/repo"
export PIPELINE_BASE_BRANCH="staging"

# shellcheck disable=SC1090
source "$HELPER"

FAILED=0
fail() { echo "  FAIL: $*"; FAILED=$((FAILED + 1)); }
pass() { echo "  PASS: $*"; }

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$name -> $actual"
  else
    fail "$name expected=$expected actual=$actual"
  fi
}

make_rollup() {
  local ci="$1" mergeable="$2" mergestate="$3"
  local checks="[]"
  case "$ci" in
    success) checks='[{"name":"x","conclusion":"SUCCESS"}]' ;;
    failure) checks='[{"name":"x","conclusion":"FAILURE"}]' ;;
  esac
  printf '{"statusCheckRollup":%s,"mergeable":"%s","mergeStateStatus":"%s"}' \
    "$checks" "$mergeable" "$mergestate"
}

make_eval() { printf '## Evaluation\n\n**Verdict:** %s\n' "$1"; }

# --- runners ---------------------------------------------------------------
STDOUT_LINE=""
STDERR_TXT=""
GATE_RC=0

run_gate() {
  local label="$1" errf="$TMP/gate.err" out nlines
  : >"$errf"
  out="$(auto_merge_should_fire "$ISSUE" 1 2>"$errf")"
  GATE_RC=$?
  STDOUT_LINE="$out"
  STDERR_TXT="$(cat "$errf")"
  nlines="$(printf '%s' "$out" | grep -c '')"
  if [ "$nlines" = "1" ]; then
    pass "$label: stdout is exactly one token line"
  else
    fail "$label: expected exactly 1 stdout line, got $nlines ('$out')"
  fi
}

# Baseline greenlight environment: Approved + CI SUCCESS + MERGEABLE + CLEAN,
# and a non-cage file listing.
reset_env() {
  unset MANUAL_MERGE
  unset NO_VERDICT
  unset PIPELINE_CAPABILITY_REFUSAL_SOURCES
  unset GH_FILES
  unset GH_FILES_RC
  export GH_LABELS=""
  export GH_BASE_REF="staging"
  export GH_EVAL_BODY="$(make_eval Approved)"
  export GH_ROLLUP="$(make_rollup success MERGEABLE CLEAN)"
}

echo "=== (a) a MODIFIED cage-invariant test blocks an otherwise-green PR ==="
reset_env
export GH_FILES="modified:tests/test-cage-invariant-restrict-paths.sh:"
run_gate "(a)"
check "(a) token" "block-cage-tests-diff" "$STDOUT_LINE"
check "(a) return code" "1" "$GATE_RC"

echo "=== (b) rename INTO the cage namespace blocks ==="
reset_env
export GH_FILES="renamed:tests/test-cage-invariant-x.sh:tests/old.sh"
run_gate "(b)"
check "(b) token" "block-cage-tests-diff" "$STDOUT_LINE"

echo "=== (c) rename AWAY from the cage namespace blocks (previous_filename) ==="
reset_env
export GH_FILES="renamed:tests/renamed-away.sh:tests/test-cage-invariant-restrict-paths.sh"
run_gate "(c)"
check "(c) token" "block-cage-tests-diff" "$STDOUT_LINE"

echo "=== (d) a REMOVED cage-invariant test blocks ==="
reset_env
export GH_FILES="removed:tests/test-cage-invariant-block-deletions.sh:"
run_gate "(d)"
check "(d) token" "block-cage-tests-diff" "$STDOUT_LINE"

echo "=== (e) added-only cage test => green, rc 0, no stderr WARN ==="
reset_env
export GH_FILES="added:tests/test-cage-invariant-restrict-paths.sh:"
run_gate "(e)"
check "(e) token" "green" "$STDOUT_LINE"
check "(e) return code" "0" "$GATE_RC"
check "(e) no stderr WARN on the added-exemption path" "" "$STDERR_TXT"

echo "=== (f) founding-PR shape (multi-line) => green ==="
reset_env
export GH_FILES="added:tests/test-cage-invariant-restrict-paths.sh:
added:tests/test-auto-merge-gate-cage-tests-diff.sh:
modified:scripts/auto-merge-gate.sh:
modified:skills/evolve/SKILL.md:"
run_gate "(f)"
check "(f) token" "green" "$STDOUT_LINE"

echo "=== (g) hook SOURCE edits do not trip the token ==="
reset_env
export GH_FILES="modified:hooks/restrict_paths.py:"
run_gate "(g)"
check "(g) token" "green" "$STDOUT_LINE"

echo "=== (h) a non-cage tests/ file does not trip the token ==="
reset_env
export GH_FILES="modified:tests/test-restrict-paths-hook.sh:"
run_gate "(h)"
check "(h) token" "green" "$STDOUT_LINE"

echo "=== (i) a docs/-prefixed decoy does not trip the token ==="
reset_env
export GH_FILES="modified:docs/tests/test-cage-invariant-x.sh:"
run_gate "(i)"
check "(i) token" "green" "$STDOUT_LINE"

echo "=== (j) unparseable listing fails CLOSED with a WARN ==="
reset_env
export GH_FILES="garbage-no-colons"
run_gate "(j)"
check "(j) token" "block-cage-tests-diff" "$STDOUT_LINE"
check "(j) return code" "1" "$GATE_RC"
case "$STDERR_TXT" in
  *WARN*cage-tests*) pass "(j) stderr WARN names the unproven cage-tests check" ;;
  *) fail "(j) expected a stderr WARN naming the cage-tests check, got: '$STDERR_TXT'" ;;
esac

echo "=== (k) empty listing fails CLOSED with a WARN ==="
reset_env
export GH_FILES=""
run_gate "(k)"
check "(k) token" "block-cage-tests-diff" "$STDOUT_LINE"
check "(k) return code" "1" "$GATE_RC"
case "$STDERR_TXT" in
  *WARN*cage-tests*) pass "(k) stderr WARN names the unproven cage-tests check" ;;
  *) fail "(k) expected a stderr WARN naming the cage-tests check, got: '$STDERR_TXT'" ;;
esac

echo "=== (l) precedence ABOVE: the manual-merge label still wins ==="
reset_env
export GH_LABELS="manual-merge"
export GH_FILES="modified:tests/test-cage-invariant-restrict-paths.sh:"
run_gate "(l)"
check "(l) manual-merge label + cage diff" "block-label" "$STDOUT_LINE"

echo "=== (m) precedence BELOW: cage diff wins over a non-Approved verdict ==="
reset_env
export GH_EVAL_BODY="$(make_eval Revise)"
export GH_FILES="modified:tests/test-cage-invariant-restrict-paths.sh:"
run_gate "(m)"
check "(m) cage diff + Revise verdict" "block-cage-tests-diff" "$STDOUT_LINE"

echo "=== (n) a NON-ZERO gh exit fails CLOSED even when the printed page parses ==="
# `gh api --paginate` can emit page 1 and then fail on a later page: stdout is
# one well-formed non-cage line, exit status is 1. Trusting that truncated
# listing would green-light exactly the diff class the token exists to stop, so
# the gate must key on the exit status too, not just on parseability.
reset_env
export GH_FILES="modified:scripts/auto-merge-gate.sh:"
export GH_FILES_RC=1
run_gate "(n)"
check "(n) token" "block-cage-tests-diff" "$STDOUT_LINE"
check "(n) return code" "1" "$GATE_RC"
case "$STDERR_TXT" in
  *WARN*cage-tests*) pass "(n) stderr WARN names the unproven cage-tests check" ;;
  *) fail "(n) expected a stderr WARN naming the cage-tests check, got: '$STDERR_TXT'" ;;
esac

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: all checks passed"
