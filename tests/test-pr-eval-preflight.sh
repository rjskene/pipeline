#!/usr/bin/env bash
set -uo pipefail
#
# #1445 — scripts/pr-eval-preflight.sh unit test (gh stubbed).
#
# The preflight runs the FOUR mechanical checks the Opus evaluator used to
# repeat inside its own turn budget, before any eval token is spent:
#
#   1. body-contract  — the PR body carries `## Pre-existing failures` (#1329).
#                       Absent + a clean test plan  -> auto-fix (the ONLY write).
#                       Absent + failures described  -> fatal `body-contract`.
#   2. ci             — the settled statusCheckRollup, using the SAME jq program
#                       as scripts/auto-merge-gate.sh (group_by(.name) |
#                       all(last.conclusion == "SUCCESS")). Definite failure ->
#                       fatal `ci-red`; unsettled -> advisory `ci-pending`;
#                       EMPTY rollup -> advisory `no-ci` (NOT `none` — "no CI"
#                       is not "CI green", and an advisory is what keeps the
#                       evaluator's local-test fallback armed on a no-CI repo).
#   3. base/mergeable — baseRefName must equal the resolved base (next-branch
#                       aware, #1131/#1148) -> else fatal `base`. A non-MERGEABLE
#                       PR is ADVISORY (`mergeable`), never fatal: preflight
#                       never pushes, so a block would strand the PR with no
#                       eval AND no rebase.
#   4. guards         — check-cross-cutting-guards.sh + check-branch-cruft.sh,
#                       run from the FEATURE WORKTREE (cruft diffs
#                       origin/<base>..HEAD relative to cwd, so from the
#                       orchestrator checkout the arm would be vacuous).
#
# Contract pinned here: arm order IS the precedence order, stdout is EXACTLY
# one line `PREFLIGHT=ok|block REASON=<token> PR=<n> FIXED=<csv|none>`, and the
# exit status is 0 in every case (the CALLER decides what a block means).
#
# FIXTURE SHAPE: the real script is copied into $TMP/scripts/ alongside STUB
# sibling guards, so the guard arm's exit-code contract is exercised against
# the real script without running the repo's slow aggregator. The `gh` stub
# APPENDS every invocation to a call log, so the body write is OBSERVED (the
# #506 "never claim a write that did not land" doctrine) rather than assumed.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REAL="$REPO_ROOT/scripts/pr-eval-preflight.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc_scenario() { echo ""; echo "-- $1 --"; }

summary_and_exit() {
  echo ""
  echo "=============================="
  echo "  PASS: $PASS   FAIL: $FAIL"
  echo "=============================="
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

if [ ! -f "$REAL" ]; then
  inc_scenario "Scenario: the preflight script exists"
  fail_msg "scripts/pr-eval-preflight.sh does not exist"
  summary_and_exit
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/scripts" "$TMP/wt"
cp "$REAL" "$TMP/scripts/pr-eval-preflight.sh"
chmod +x "$TMP/scripts/pr-eval-preflight.sh"
PF="$TMP/scripts/pr-eval-preflight.sh"

# Stub siblings. Exit codes are env-driven so the guard arm can be reddened
# without running the repo's real (slow) aggregator.
cat > "$TMP/scripts/check-cross-cutting-guards.sh" <<'STUB'
#!/bin/bash
echo "cross-cutting stub (rc=${STUB_GUARD_RC:-0}) cwd=$PWD"
exit "${STUB_GUARD_RC:-0}"
STUB
cat > "$TMP/scripts/check-branch-cruft.sh" <<'STUB'
#!/bin/bash
echo "cruft stub (rc=${STUB_CRUFT_RC:-0}) cwd=$PWD"
exit "${STUB_CRUFT_RC:-0}"
STUB
chmod +x "$TMP/scripts/check-cross-cutting-guards.sh" "$TMP/scripts/check-branch-cruft.sh"

# ---------------------------------------------------------------------------
# gh stub. Every invocation is appended to $STUB_GH_CALLS. Routing is by argv
# pattern, mirroring tests/test-auto-merge-gate-next-branch.sh.
#
#   pr view <n> --json body                   -> contents of $STUB_BODY_FILE
#   pr edit <n> --body-file <f>               -> copies <f> over $STUB_BODY_FILE
#                                                (simulating the landed write);
#                                                exits 1 when STUB_EDIT_FAIL=1
#   pr view <n> --json statusCheckRollup      -> $STUB_ROLLUP (exit 1 when
#                                                STUB_ROLLUP_FAIL=1)
#   pr view <n> --json baseRefName,mergeable  -> {$STUB_BASE,$STUB_MERGEABLE}
#   issue view <n> --json labels              -> $STUB_LABELS
#   issue view <n> --json closedBy...         -> $STUB_CLOSING_PR
#   pr list ...                               -> $STUB_PR_LIST
# ---------------------------------------------------------------------------
cat > "$TMP/bin/gh" <<'SHIM'
#!/bin/bash
ALL="$*"
printf '%s\n' "$ALL" >> "${STUB_GH_CALLS:-/dev/null}"
case "$ALL" in
  *"pr edit"*)
    [ "${STUB_EDIT_FAIL:-0}" = "1" ] && exit 1
    _f=""
    _prev=""
    for _a in "$@"; do
      [ "$_prev" = "--body-file" ] && _f="$_a"
      _prev="$_a"
    done
    if [ -n "$_f" ] && [ -f "$_f" ] && [ -n "${STUB_BODY_FILE:-}" ]; then
      cat "$_f" > "$STUB_BODY_FILE"
    fi
    exit 0
    ;;
  *"pr view"*"--json body"*)
    [ -n "${STUB_BODY_FILE:-}" ] && [ -f "$STUB_BODY_FILE" ] && cat "$STUB_BODY_FILE"
    exit 0
    ;;
  *"pr view"*"statusCheckRollup"*)
    [ "${STUB_ROLLUP_FAIL:-0}" = "1" ] && exit 1
    printf '%s\n' "${STUB_ROLLUP:-{\"statusCheckRollup\":[]}}"
    exit 0
    ;;
  *"pr view"*"baseRefName"*)
    printf '{"baseRefName":"%s","mergeable":"%s"}\n' \
      "${STUB_BASE:-staging}" "${STUB_MERGEABLE:-MERGEABLE}"
    exit 0
    ;;
  *"issue view"*"--json labels"*)
    printf '%s\n' "${STUB_LABELS:-[]}"
    exit 0
    ;;
  *"issue view"*"closedByPullRequestsReferences"*)
    printf '%s\n' "${STUB_CLOSING_PR:-}"
    exit 0
    ;;
  *"pr list"*)
    printf '%s\n' "${STUB_PR_LIST:-}"
    exit 0
    ;;
  *)
    echo "[gh stub] unhandled: $ALL" >&2
    exit 1
    ;;
esac
SHIM
chmod +x "$TMP/bin/gh"

export PATH="$TMP/bin:$PATH"
export PIPELINE_REPO="test/repo"
export PIPELINE_BASE_BRANCH="staging"
export PIPELINE_NEXT_BRANCH="next"
export PIPELINE_NEXT_LABEL="next"
export STUB_GH_CALLS="$TMP/gh-calls.log"
export STUB_BODY_FILE="$TMP/pr-body.md"

# Clean body: a `## Test plan` whose every line is a pass claim.
BODY_CLEAN_TESTPLAN='Closes #1445

## Summary
- did the thing

## Test plan
- [x] `PIPELINE_TEST_CMD` — all tests pass
- [x] Feature works end to end
'

OUT=""
ERR=""
RC=0

# run_pf <args...> — run the preflight with a fresh call log, capturing
# stdout / stderr / rc separately so a stderr diagnostic can never be mistaken
# for the single contractual stdout line.
run_pf() {
  : > "$STUB_GH_CALLS"
  OUT="$(bash "$PF" "$@" 2>"$TMP/err.txt")"
  RC=$?
  ERR="$(cat "$TMP/err.txt")"
}

# reset_env — restore every stub knob to its all-green default.
reset_env() {
  printf '%s' "$BODY_CLEAN_TESTPLAN" > "$STUB_BODY_FILE"
  export STUB_ROLLUP='{"statusCheckRollup":[{"name":"ci","conclusion":"SUCCESS"}]}'
  export STUB_ROLLUP_FAIL=0
  export STUB_EDIT_FAIL=0
  export STUB_BASE="staging"
  export STUB_MERGEABLE="MERGEABLE"
  export STUB_LABELS='[]'
  export STUB_GUARD_RC=0
  export STUB_CRUFT_RC=0
  export PIPELINE_CI_CHECK_ENABLED="true"
}

SHAPE_RE='^PREFLIGHT=(ok|block) REASON=[a-z-]+ PR=[0-9]+ FIXED=([a-z,-]+|none)$'

# expect_line <label> <expected-exact-stdout-line>
expect_line() {
  local label="$1" want="$2"
  if [ "$OUT" = "$want" ]; then
    pass_msg "$label -> $OUT"
  else
    fail_msg "$label: expected [$want], got [$OUT] (rc=$RC, stderr: ${ERR:-<none>})"
  fi
}

# expect_shape <label> — every invocation must emit EXACTLY one stdout line in
# the pinned shape and exit 0. Called after every case: the output contract is
# not a single test, it is an invariant.
expect_shape() {
  local label="$1" n
  n="$(printf '%s\n' "$OUT" | grep -c .)"
  if [ "$n" = "1" ] && [[ "$OUT" =~ $SHAPE_RE ]] && [ "$RC" = "0" ]; then
    pass_msg "$label: exactly one stdout line in the pinned shape, rc=0"
  else
    fail_msg "$label: lines=$n rc=$RC out=[$OUT] (shape/exit contract violated)"
  fi
}

# ===========================================================================
# ARM 1 — body-contract
# ===========================================================================

inc_scenario "Case 1: section present -> ok REASON=none FIXED=none"
reset_env
printf '%s\n\n## Pre-existing failures\nPRE-EXISTING: none\n' "$BODY_CLEAN_TESTPLAN" > "$STUB_BODY_FILE"
run_pf 1445 --pr 200 --worktree "$TMP/wt"
expect_line "section present" "PREFLIGHT=ok REASON=none PR=200 FIXED=none"
expect_shape "case 1"
if grep -q 'pr edit' "$STUB_GH_CALLS"; then
  fail_msg "case 1: preflight edited the body even though the section was present"
else
  pass_msg "case 1: no body write when the section is already present"
fi

inc_scenario "Case 2: section absent + clean test plan -> auto-fix, write OBSERVED"
reset_env
run_pf 1445 --pr 200 --worktree "$TMP/wt"
expect_line "auto-fix" "PREFLIGHT=ok REASON=none PR=200 FIXED=body-contract"
expect_shape "case 2"
if grep -q 'pr edit' "$STUB_GH_CALLS" && grep -q -- '--body-file' "$STUB_GH_CALLS"; then
  pass_msg "case 2: the call log records a 'pr edit ... --body-file' invocation"
else
  fail_msg "case 2: no 'pr edit ... --body-file' in the call log: $(cat "$STUB_GH_CALLS")"
fi
if grep -qE '^##[[:space:]]+Pre-existing failures[[:space:]]*$' "$STUB_BODY_FILE" \
   && grep -qE '^PRE-EXISTING:[[:space:]]*none[[:space:]]*$' "$STUB_BODY_FILE"; then
  pass_msg "case 2: the written body carries the section AND 'PRE-EXISTING: none'"
else
  fail_msg "case 2: written body missing the appended section: $(cat "$STUB_BODY_FILE")"
fi
if grep -q 'did the thing' "$STUB_BODY_FILE"; then
  pass_msg "case 2: the pre-existing body content survived the append"
else
  fail_msg "case 2: the append CLOBBERED the original body"
fi

inc_scenario "Case 3: section absent + un-negated PRE-EXISTING line -> block"
reset_env
printf '%s\n\nPRE-EXISTING: tests/foo.sh (untouched; base CI green)\n' "$BODY_CLEAN_TESTPLAN" > "$STUB_BODY_FILE"
run_pf 1445 --pr 200 --worktree "$TMP/wt"
expect_line "un-negated PRE-EXISTING claim" "PREFLIGHT=block REASON=body-contract PR=200 FIXED=none"
expect_shape "case 3"
if grep -q 'pr edit' "$STUB_GH_CALLS"; then
  fail_msg "case 3: preflight auto-fixed a body that CLAIMS pre-existing failures"
else
  pass_msg "case 3: no auto-fix on a body claiming failures"
fi

inc_scenario "Case 4: section absent + test plan describing a failure -> block"
reset_env
cat > "$STUB_BODY_FILE" <<'BODY'
Closes #1445

## Summary
- did the thing

## Test plan
- [x] suite run — 2 tests fail on this branch
BODY
run_pf 1445 --pr 200 --worktree "$TMP/wt"
expect_line "test plan describes a failure" "PREFLIGHT=block REASON=body-contract PR=200 FIXED=none"
expect_shape "case 4"

inc_scenario "Case 4b: 'no pre-existing failures' prose is NEGATED, not a claim"
reset_env
cat > "$STUB_BODY_FILE" <<'BODY'
Closes #1445

## Test plan
- [x] suite run — no pre-existing failures
BODY
run_pf 1445 --pr 200 --worktree "$TMP/wt"
expect_line "negated failure prose" "PREFLIGHT=ok REASON=none PR=200 FIXED=body-contract"
expect_shape "case 4b"

inc_scenario "Case 5: gh pr edit fails -> block, FIXED=none (never claim a write)"
reset_env
export STUB_EDIT_FAIL=1
run_pf 1445 --pr 200 --worktree "$TMP/wt"
expect_line "failed body write" "PREFLIGHT=block REASON=body-contract PR=200 FIXED=none"
expect_shape "case 5"
export STUB_EDIT_FAIL=0

inc_scenario "Case 6: second run after the fix is idempotent (FIXED=none)"
reset_env
run_pf 1445 --pr 200 --worktree "$TMP/wt"
expect_line "first run fixes" "PREFLIGHT=ok REASON=none PR=200 FIXED=body-contract"
run_pf 1445 --pr 200 --worktree "$TMP/wt"
expect_line "second run is a no-op" "PREFLIGHT=ok REASON=none PR=200 FIXED=none"
expect_shape "case 6"

inc_scenario "Case 7: 12KB body non-vacuity control (no-pipe scan, #1381)"
#
# `printf '%s' "$BODY" | grep -q …` exits on first match and SIGPIPEs the
# producer; under `pipefail` the predicate then flips OPEN on a large body
# (measured 18/20 misses on 12KB). The scan must therefore be a here-string or
# a `case` glob. This case proves the predicate still SEES a claim buried in a
# 12KB body — a silently fail-open scan would report `ok` here.
reset_env
{
  printf 'Closes #1445\n\n## Summary\n'
  i=0
  while [ "$i" -lt 400 ]; do
    printf -- '- filler line %03d %s\n' "$i" "0123456789012345678901234567890"
    i=$((i + 1))
  done
  printf '\nPRE-EXISTING: tests/deep.sh (untouched; base CI green)\n'
} > "$STUB_BODY_FILE"
BODY_BYTES="$(wc -c < "$STUB_BODY_FILE")"
if [ "$BODY_BYTES" -ge 12000 ]; then
  pass_msg "case 7: the control body is $BODY_BYTES bytes (>= 12000)"
else
  fail_msg "case 7: control body only $BODY_BYTES bytes — the non-vacuity control is too small"
fi
run_pf 1445 --pr 200 --worktree "$TMP/wt"
expect_line "12KB body claim is SEEN" "PREFLIGHT=block REASON=body-contract PR=200 FIXED=none"
expect_shape "case 7"

summary_and_exit
