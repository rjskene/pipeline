#!/bin/bash
set -uo pipefail

# Unit test for scripts/verify-execute-completion.sh (issue #912).
#
# The helper is the ORCHESTRATOR-SIDE completion backstop for fullsend's inline
# execute step: after an inline PATH A/B/D execute Agent returns, the orchestrator
# runs this helper to VERIFY the terminal state actually happened (branch pushed
# AND PR open AND issue at `pr-open`) instead of trusting the agent's narrated
# self-report. #764's dispatch-prompt directive landed but the drop-out recurred
# (#838/#904) — a committed-but-unpushed / no-PR branch with the issue stuck at
# `in-progress`. The helper emits exactly one machine-readable `ACTION=` line:
#
#   ACTION=complete          ISSUE=<N>
#   ACTION=recover-push      ISSUE=<N> REASON=branch-unpushed
#   ACTION=recover-pr        ISSUE=<N> REASON=no-pr
#   ACTION=recover-label     ISSUE=<N> REASON=label-stuck
#   ACTION=recover-redispatch ISSUE=<N> REASON=no-work
#
# Exits 0 in every case (the ACTION token, not the exit code, carries the verdict
# — mirrors scripts/check-ci-fix-loop.sh).
#
# Branch resolution is DETERMINISTIC (the blocking fix from the prior eval):
#   1. Primary  — the issue's worktree from `git worktree list --porcelain`
#      (the `wt-<N>-<slug>` dir -> its `branch refs/heads/feature/<slug>` ref).
#   2. Secondary — the issue's linked PR head (closedByPullRequestsReferences,
#      then `gh pr list --search "linked:<N>"`).
# NO `feature/issue-<N>` convention is assumed (it does not exist). The remote is
# pinned to `origin` (PIPELINE_REPO is the gh owner/repo slug, NOT a git remote).
#
# Stub/PASS-FAIL-counter/`exit 1` shape modelled on
# tests/test-run-queue-executor-terminal.sh: each case gets its own scratch dir
# with PATH-prepended `gh`/`git` stubs so stub state never leaks between cases.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/scripts/verify-execute-completion.sh"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

# Build a per-case stub dir holding `gh` + `git` PATH stubs. The git stub emits a
# `git worktree list --porcelain` block driven by $STUB_WT_SLUG (empty => no
# worktree block, exercising the linked-PR / stranded fallbacks). The git stub
# also answers `git ls-remote --heads origin <branch>`: non-empty iff
# $STUB_REMOTE_HAS == 1. The gh stub answers `issue view ... labels`,
# `issue view ... closedByPullRequestsReferences` (disambiguated by the
# `--jq` expression substring in $ARGS: `.headRefName` for the deterministic
# branch-resolution read elsewhere in the script vs `.number` for Check 2's
# PR-reference lookup, #1260), `pr list`, and `pr view <number>` (Check 2's
# state+headRefName lookup for the referenced PR, #1260).
make_stubs() {
  local case_dir="$1"
  local stub_dir="$case_dir/stub"
  mkdir -p "$stub_dir"

  cat > "$stub_dir/git" <<'EOF'
#!/bin/bash
if [ "$1" = "worktree" ] && [ "$2" = "list" ]; then
  # Emit a porcelain block ONLY when a slug is configured for this case.
  if [ -n "${STUB_WT_SLUG:-}" ]; then
    echo "worktree ${STUB_WT_BASE:-/tmp}/wt-${STUB_WT_ISSUE}-${STUB_WT_SLUG}"
    echo "HEAD abc123"
    echo "branch refs/heads/feature/${STUB_WT_SLUG}"
    echo ""
  fi
  exit 0
fi
if [ "$1" = "ls-remote" ]; then
  # `git ls-remote --heads origin <branch>` — non-empty iff configured. SHA is
  # $STUB_REMOTE_SHA (default abc123) so it can be made to differ from the local
  # tip (#1258 — stale-but-present remote ref).
  if [ "${STUB_REMOTE_HAS:-0}" = "1" ]; then
    echo "${STUB_REMOTE_SHA:-abc123}	refs/heads/${!#}"
  fi
  exit 0
fi
if [ "$1" = "rev-parse" ]; then
  # `git rev-parse refs/heads/<branch>` — local tip SHA (#1258). Default matches
  # the default remote SHA so pre-existing cases are unaffected.
  echo "${STUB_LOCAL_SHA:-abc123}"
  exit 0
fi
exit 0
EOF
  chmod +x "$stub_dir/git"

  cat > "$stub_dir/gh" <<'EOF'
#!/bin/bash
ARGS="$*"
case "$1 $2" in
  "issue view")
    if [[ "$ARGS" == *"closedByPullRequestsReferences[0].headRefName"* ]]; then
      # Deterministic branch-resolution read (unrelated to Check 2, #1260):
      # linked PR head, empty when no linked PR.
      printf '%s' "${STUB_LINKED_PR_HEAD:-}"
    elif [[ "$ARGS" == *"closedByPullRequestsReferences[0].number"* ]]; then
      # Check 2's PR-reference lookup (#1260): the referenced PR's number,
      # empty when no reference resolves.
      printf '%s' "${STUB_LINKED_PR_NUM:-}"
    elif [[ "$ARGS" == *labels* ]]; then
      printf '%s' "${STUB_ISSUE_LABELS:-}"
    fi
    ;;
  "pr list")
    printf '%s' "${STUB_PR_LIST_HEAD:-}"
    ;;
  "pr view")
    # Check 2's state+headRefName lookup for the referenced PR (#1260).
    printf '%s|%s' "${STUB_PR_VIEW_STATE:-}" "${STUB_PR_VIEW_HEAD:-}"
    ;;
  *) printf '' ;;
esac
EOF
  chmod +x "$stub_dir/gh"

  echo "$stub_dir"
}

# Run the helper for one case. $1=case dir, $2=issue number. The remaining
# STUB_* vars are read from the environment of the caller.
run_helper() {
  local case_dir="$1"; shift
  local issue="$1"; shift
  local stub_dir="$case_dir/stub"
  (
    PATH="$stub_dir:$PATH" \
      PIPELINE_REPO="fake/repo" \
      PIPELINE_BASE_BRANCH="staging" \
      PIPELINE_WORKTREE_PREFIX="wt" \
      STUB_WT_BASE="$case_dir" \
      bash "$SCRIPT_UNDER_TEST" "$issue"
  ) 2>&1
}

# Regression vector for #1022: run the helper with NO pre-exported PIPELINE_REPO
# / PIPELINE_BASE_BRANCH (the actual bug — SKILL blocks source-but-don't-export).
# Instead, drop a `pipeline.config` + `.git` marker into $case_dir and point the
# co-located _resolve-config.sh at it via PIPELINE_PROJECT_ROOT. If the script
# self-resolves it must NOT abort at the line-36/37 `:?` guards and must emit a
# normal `ACTION=` token. The fixture config carries the values the prior
# run_helper exported inline (fake/repo + staging) so downstream behavior is
# byte-identical to the exported path.
run_helper_no_export() {
  local case_dir="$1"; shift
  local issue="$1"; shift
  local stub_dir="$case_dir/stub"
  cat > "$case_dir/pipeline.config" <<'CFG'
set -a
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_WORKTREE_PREFIX="wt"
set +a
CFG
  echo "gitdir: /tmp/fake" > "$case_dir/.git"
  (
    PATH="$stub_dir:$PATH" \
      PIPELINE_PROJECT_ROOT="$case_dir" \
      STUB_WT_BASE="$case_dir" \
      bash "$SCRIPT_UNDER_TEST" "$issue"
  ) 2>&1
}

if [ ! -f "$SCRIPT_UNDER_TEST" ]; then
  echo "FAIL: $SCRIPT_UNDER_TEST not found (helper not yet created)"
  echo ""
  echo "================================"
  echo "  1 tests: PASS=0 FAIL=1"
  echo "================================"
  exit 1
fi

# Assert the helper's stdout contains a literal token.
assert_action() {
  local label="$1" out="$2" needle="$3"
  inc
  if printf '%s' "$out" | grep -F -q -- "$needle"; then
    pass_msg "$label: emitted \"$needle\""
  else
    fail_msg "$label: expected \"$needle\" in output: $out"
  fi
}

# ============== Case 1: worktree resolves, branch unpushed -> recover-push ====
echo "Case 1: worktree-porcelain branch resolves + remote ref absent -> recover-push"
C1="$ROOT/c1"; mkdir -p "$C1"; make_stubs "$C1" >/dev/null
OUT=$(STUB_WT_ISSUE=912 STUB_WT_SLUG=foo STUB_REMOTE_HAS=0 \
      STUB_ISSUE_LABELS="in-progress" \
      run_helper "$C1" 912)
assert_action "c1" "$OUT" "ACTION=recover-push"
assert_action "c1-issue" "$OUT" "ISSUE=912"

# ============== Case 2: pushed, no PR -> recover-pr ===========================
echo ""
echo "Case 2: branch pushed + no linked PR -> recover-pr"
C2="$ROOT/c2"; mkdir -p "$C2"; make_stubs "$C2" >/dev/null
OUT=$(STUB_WT_ISSUE=912 STUB_WT_SLUG=foo STUB_REMOTE_HAS=1 \
      STUB_LINKED_PR_HEAD="" STUB_PR_LIST_HEAD="" \
      STUB_ISSUE_LABELS="in-progress" \
      run_helper "$C2" 912)
assert_action "c2" "$OUT" "ACTION=recover-pr"

# ============== Case 3: PR open, label stuck at in-progress -> recover-label ==
echo ""
echo "Case 3: branch pushed + PR open + label still in-progress -> recover-label"
C3="$ROOT/c3"; mkdir -p "$C3"; make_stubs "$C3" >/dev/null
OUT=$(STUB_WT_ISSUE=912 STUB_WT_SLUG=foo STUB_REMOTE_HAS=1 \
      STUB_LINKED_PR_NUM="42" STUB_PR_VIEW_STATE="OPEN" STUB_PR_VIEW_HEAD="feature/foo" \
      STUB_ISSUE_LABELS="in-progress" \
      run_helper "$C3" 912)
assert_action "c3" "$OUT" "ACTION=recover-label"

# ============== Case 4: fully complete -> complete ===========================
echo ""
echo "Case 4: branch pushed + PR open + pr-open label -> complete"
C4="$ROOT/c4"; mkdir -p "$C4"; make_stubs "$C4" >/dev/null
OUT=$(STUB_WT_ISSUE=912 STUB_WT_SLUG=foo STUB_REMOTE_HAS=1 \
      STUB_LINKED_PR_NUM="42" STUB_PR_VIEW_STATE="OPEN" STUB_PR_VIEW_HEAD="feature/foo" \
      STUB_ISSUE_LABELS="pr-open" \
      run_helper "$C4" 912)
assert_action "c4" "$OUT" "ACTION=complete"

# ============== Case 5: no worktree + no linked PR -> recover-redispatch ======
echo ""
echo "Case 5: no worktree block AND no linked PR -> recover-redispatch (stranded)"
C5="$ROOT/c5"; mkdir -p "$C5"; make_stubs "$C5" >/dev/null
OUT=$(STUB_WT_ISSUE=912 STUB_WT_SLUG="" STUB_REMOTE_HAS=0 \
      STUB_LINKED_PR_HEAD="" STUB_PR_LIST_HEAD="" \
      STUB_ISSUE_LABELS="in-progress" \
      run_helper "$C5" 912)
assert_action "c5" "$OUT" "ACTION=recover-redispatch"

# ============== Case 6: secondary branch resolution via linked PR head ========
# No worktree block, but a linked PR head resolves the branch AND the remote ref
# is present -> the resolution should fall through to the PR-open / label checks
# rather than stranding. With the PR open + label pr-open this is `complete`.
echo ""
echo "Case 6: no worktree but linked PR head resolves branch + remote present -> complete"
C6="$ROOT/c6"; mkdir -p "$C6"; make_stubs "$C6" >/dev/null
OUT=$(STUB_WT_ISSUE=912 STUB_WT_SLUG="" STUB_REMOTE_HAS=1 \
      STUB_LINKED_PR_HEAD="feature/foo" \
      STUB_PR_LIST_HEAD="feature/foo" \
      STUB_ISSUE_LABELS="pr-open" \
      run_helper "$C6" 912)
assert_action "c6" "$OUT" "ACTION=complete"

# ============== Case 7: exit 0 regardless of verdict =========================
echo ""
echo "Case 7: helper exits 0 even on a recover verdict (ACTION-token contract)"
C7="$ROOT/c7"; mkdir -p "$C7"; make_stubs "$C7" >/dev/null
( STUB_WT_ISSUE=912 STUB_WT_SLUG=foo STUB_REMOTE_HAS=0 STUB_ISSUE_LABELS="in-progress" \
  run_helper "$C7" 912 ) >/dev/null 2>&1
rc=$?
inc
if [ "$rc" -eq 0 ]; then
  pass_msg "c7: helper exited 0 (ACTION token carries the verdict, not the exit code)"
else
  fail_msg "c7: helper exited $rc (expected 0)"
fi

# ============== Case 8: self-resolve PIPELINE_* with NO pre-export (#1022) ====
# The actual bug: the orchestrator sources pipeline.config but does NOT export
# PIPELINE_BASE_BRANCH, so the first `bash verify-execute-completion.sh` aborts
# at line 37 under `set -u`. Prove the script now self-resolves from config (via
# the co-located _resolve-config.sh) and emits a normal ACTION token instead of
# aborting. Reuse the fully-complete shape (Case 4) so the expected token is
# `ACTION=complete` — its emission proves the guards did NOT abort.
echo ""
echo "Case 8: NO pre-exported PIPELINE_* -> self-resolves from config, emits ACTION (#1022)"
C8="$ROOT/c8"; mkdir -p "$C8"; make_stubs "$C8" >/dev/null
OUT=$(STUB_WT_ISSUE=912 STUB_WT_SLUG=foo STUB_REMOTE_HAS=1 \
      STUB_LINKED_PR_NUM="42" STUB_PR_VIEW_STATE="OPEN" STUB_PR_VIEW_HEAD="feature/foo" \
      STUB_ISSUE_LABELS="pr-open" \
      run_helper_no_export "$C8" 912)
assert_action "c8" "$OUT" "ACTION=complete"
# Guard: the line-37 abort message must NOT appear (proves no `set -u` abort).
inc
if printf '%s' "$OUT" | grep -qF "PIPELINE_BASE_BRANCH must be set"; then
  fail_msg "c8: script still aborted on unset PIPELINE_BASE_BRANCH (self-resolve regressed): $OUT"
else
  pass_msg "c8: no 'PIPELINE_BASE_BRANCH must be set' abort — self-resolved from config"
fi

# ============== Case 9 (#1258): stale-but-present remote ref, no open PR, label
# not in-progress -> recover-push, NOT recover-label ==========================
# Reproduces the exact reported shape: the branch was pushed once (remote ref
# exists) but a later local commit was never re-pushed (remote SHA != local
# SHA). `closedByPullRequestsReferences` resolves a stale (non-open) PR
# reference so Check 2's PR_HEAD is non-empty, and `gh pr list --state open`
# shows nothing. The issue is labelled `plan-approved` (not `in-progress`, not
# `pr-open`). Before the fix this fell through to Check 3 and emitted
# `recover-label`; the unpushed-local-commit case must win regardless of the
# PR/label state.
echo ""
echo "Case 9 (#1258): remote ref stale (behind local tip), no open PR, label not in-progress -> recover-push"
C9="$ROOT/c9"; mkdir -p "$C9"; make_stubs "$C9" >/dev/null
OUT=$(STUB_WT_ISSUE=1258 STUB_WT_SLUG=foo STUB_REMOTE_HAS=1 \
      STUB_REMOTE_SHA="0dd98f4" STUB_LOCAL_SHA="db8738e" \
      STUB_LINKED_PR_HEAD="feature/foo" STUB_PR_LIST_HEAD="" \
      STUB_ISSUE_LABELS="plan-approved" \
      run_helper "$C9" 1258)
assert_action "c9" "$OUT" "ACTION=recover-push"
inc
if printf '%s' "$OUT" | grep -qF "ACTION=recover-label"; then
  fail_msg "c9: emitted recover-label instead of recover-push (the #1258 bug)"
else
  pass_msg "c9: did not emit recover-label"
fi

# ============== Case 10 (#1260): closedByPullRequestsReferences resolves a
# CLOSED (non-open) PR reference, no open PR via `gh pr list`, issue not at
# pr-open -> recover-pr, NOT recover-label =====================================
# Reproduces the residual #1258 scope item: the branch is pushed and IN SYNC
# with the remote (Check 1b does not fire), so Check 2's PR resolution is
# reached. closedByPullRequestsReferences[0] resolves PR #99, but that PR's
# actual state (fetched via `gh pr view`, since gh's fixed
# closedByPullRequestsReferences query shape never includes state/headRefName
# directly) is CLOSED, not OPEN — so it must be treated as no-PR. `gh pr list
# --state open` (the existing open-scoped fallback) also finds nothing. Before
# the fix, Check 2 trusted the closed reference's headRefName directly and
# Check 3 wrongly emitted recover-label; the fix requires state == OPEN before
# trusting the reference, falling through to recover-pr instead.
echo ""
echo "Case 10 (#1260): closedByPullRequestsReferences resolves a CLOSED PR, no open PR -> recover-pr, NOT recover-label"
C10="$ROOT/c10"; mkdir -p "$C10"; make_stubs "$C10" >/dev/null
OUT=$(STUB_WT_ISSUE=1260 STUB_WT_SLUG=foo STUB_REMOTE_HAS=1 \
      STUB_LINKED_PR_HEAD="feature/foo" \
      STUB_LINKED_PR_NUM="99" STUB_PR_VIEW_STATE="CLOSED" STUB_PR_VIEW_HEAD="feature/foo" \
      STUB_PR_LIST_HEAD="" \
      STUB_ISSUE_LABELS="plan-approved" \
      run_helper "$C10" 1260)
assert_action "c10" "$OUT" "ACTION=recover-pr"
inc
if printf '%s' "$OUT" | grep -qF "ACTION=recover-label"; then
  fail_msg "c10: emitted recover-label instead of recover-pr (the #1260 bug — closed PR ref trusted as open)"
else
  pass_msg "c10: did not emit recover-label"
fi

# ============================================================================
# #1056 — additive --verify-dispatch mode: post-hoc model + shape verify.
#
# After an inline execute Agent returns, the orchestrator runs
#   verify-execute-completion.sh --verify-dispatch <N> <path>
# to assert the dispatched model + shape MATCH what resolve-execute-dispatch.sh
# specified — closing the "invisible cost regression" property (#1056). The mode
# emits a parallel single-line token contract on stdout:
#
#   DISPATCH=match    ISSUE=<N>
#   DISPATCH=mismatch ISSUE=<N> REASON=model:<got>!=<want>
#   DISPATCH=mismatch ISSUE=<N> REASON=shape:single!=split-role
#   DISPATCH=warn     ISSUE=<N> REASON=model-unrecoverable
#
# Inputs (threaded by the orchestrator at the call site; env-driven so the
# existing positional ACTION-token contract stays byte-for-byte unchanged):
#   VED_EXPECT_MODEL        — the resolver's MODEL= (sonnet|opus|haiku|inherit)
#   VED_EXPECT_SPLIT_ROLE   — the resolver's SPLIT_ROLE= (true|false)
#   VED_OBSERVED_MODEL      — the model actually dispatched (recorded at dispatch
#                             for the inline path); empty => try the runs log,
#                             else WARN (model-unrecoverable, never a spurious
#                             match — fail-soft, the verify is a backstop).
# Shape: when VED_EXPECT_SPLIT_ROLE=true, assert a `[split-role-red]` commit
# exists in $PIPELINE_BASE_BRANCH..HEAD; its ABSENCE => shape mismatch (the
# inline orchestrator silently collapsed the split pair to one agent).
# Exit 0 in every case (token carries the verdict). Default-mode (no
# --verify-dispatch) ACTION= contract is UNCHANGED (additivity regression guard).
# ============================================================================

echo ""
echo "== #1056 --verify-dispatch mode =="

# A real throwaway git repo fixture for the shape (git-log) checks.
make_dispatch_repo() {
  local d="$1"; local with_red="$2"
  mkdir -p "$d"
  (
    cd "$d" || exit 1
    git init -q -b staging
    git config user.email t@t.t; git config user.name t
    git commit -q --allow-empty -m "base"
    git checkout -q -b feature/foo
    if [ "$with_red" = "1" ]; then
      git commit -q --allow-empty -m "test(foo): failing suite [split-role-red]"
    fi
    git commit -q --allow-empty -m "feat(foo): implement"
  )
}

run_vd() {
  # run_vd <repo-dir> <issue> <path> ; VED_* read from caller env.
  local repo="$1" issue="$2" path="$3"
  (
    cd "$repo" || exit 1
    PIPELINE_REPO="fake/repo" PIPELINE_BASE_BRANCH="staging" \
      bash "$SCRIPT_UNDER_TEST" --verify-dispatch "$issue" "$path"
  ) 2>&1
}

# Real-call-site fixture: HEAD stays on the BASE branch (orchestrator session),
# the [split-role-red] anchor lives ONLY on a separate feature/foo branch that is
# NOT checked out. Mirrors verify running from the orchestrator's staging checkout
# while the anchor sits on the unmerged feature branch (#1077).
make_orchestrator_repo() {
  local d="$1"          # repo dir
  local with_red="$2"   # 1 => anchor present on feature/foo, 0 => genuine single-role
  mkdir -p "$d"
  (
    cd "$d" || exit 1
    git init -q -b staging
    git config user.email t@t.t; git config user.name t
    git commit -q --allow-empty -m "base"
    git checkout -q -b feature/foo
    if [ "$with_red" = "1" ]; then
      git commit -q --allow-empty -m "test(foo): failing suite [split-role-red]"
    fi
    git commit -q --allow-empty -m "feat(foo): implement"
    # Return HEAD to the base branch — the orchestrator never checks out the feature branch.
    git checkout -q staging
  )
}

run_vd_orchestrator() {
  # run_vd_orchestrator <repo-dir> <issue> <path> ; VED_* read from caller env.
  # gh stub returns feature/foo as the linked-PR head so the shape branch can
  # resolve the feature ref without a live worktree (orchestrator call site).
  local repo="$1" issue="$2" path="$3"
  local stub_dir="$repo/ghstub"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/gh" <<'EOF'
#!/bin/bash
ARGS="$*"
case "$1 $2" in
  "issue view")
    if [[ "$ARGS" == *closedByPullRequestsReferences* ]]; then printf 'feature/foo'; fi ;;
  "pr list") printf 'feature/foo' ;;
  *) printf '' ;;
esac
EOF
  chmod +x "$stub_dir/gh"
  (
    cd "$repo" || exit 1
    PATH="$stub_dir:$PATH" \
    PIPELINE_REPO="fake/repo" PIPELINE_BASE_BRANCH="staging" \
      bash "$SCRIPT_UNDER_TEST" --verify-dispatch "$issue" "$path"
  ) 2>&1
}

# Case D1: model match (resolver sonnet, observed sonnet) -> DISPATCH=match.
echo "Case D1: model match -> DISPATCH=match"
D1="$ROOT/d1"; make_dispatch_repo "$D1" 0
OUT=$(VED_EXPECT_MODEL=sonnet VED_OBSERVED_MODEL=sonnet VED_EXPECT_SPLIT_ROLE=false \
      run_vd "$D1" 1056 B)
assert_action "d1" "$OUT" "DISPATCH=match"
assert_action "d1-issue" "$OUT" "ISSUE=1056"

# Case D2: the exact #1056 bug — resolver sonnet, observed opus -> mismatch.
echo ""
echo "Case D2: model mismatch (the #1056 bug) -> DISPATCH=mismatch REASON=model:opus!=sonnet"
D2="$ROOT/d2"; make_dispatch_repo "$D2" 0
OUT=$(VED_EXPECT_MODEL=sonnet VED_OBSERVED_MODEL=opus VED_EXPECT_SPLIT_ROLE=false \
      run_vd "$D2" 1056 B)
assert_action "d2" "$OUT" "DISPATCH=mismatch"
assert_action "d2-reason" "$OUT" "REASON=model:opus!=sonnet"

# Case D3: split-role expected, branch HAS a [split-role-red] commit -> match.
echo ""
echo "Case D3: split-role expected + [split-role-red] commit present -> DISPATCH=match"
D3="$ROOT/d3"; make_dispatch_repo "$D3" 1
OUT=$(VED_EXPECT_MODEL=sonnet VED_OBSERVED_MODEL=sonnet VED_EXPECT_SPLIT_ROLE=true \
      run_vd "$D3" 1056 B)
assert_action "d3" "$OUT" "DISPATCH=match"

# Case D4: split-role expected, NO [split-role-red] commit -> shape mismatch.
echo ""
echo "Case D4: split-role expected + NO [split-role-red] commit -> shape mismatch"
D4="$ROOT/d4"; make_dispatch_repo "$D4" 0
OUT=$(VED_EXPECT_MODEL=sonnet VED_OBSERVED_MODEL=sonnet VED_EXPECT_SPLIT_ROLE=true \
      run_vd "$D4" 1056 B)
assert_action "d4" "$OUT" "DISPATCH=mismatch"
assert_action "d4-reason" "$OUT" "REASON=shape:single!=split-role"

# Case D5: no observed model recoverable -> WARN line, no spurious match.
echo ""
echo "Case D5: no observed model recoverable -> WARN (no spurious match)"
D5="$ROOT/d5"; make_dispatch_repo "$D5" 0
OUT=$(VED_EXPECT_MODEL=sonnet VED_OBSERVED_MODEL="" VED_EXPECT_SPLIT_ROLE=false \
      run_vd "$D5" 1056 B)
assert_action "d5" "$OUT" "DISPATCH=warn"
inc
if printf '%s' "$OUT" | grep -qF "DISPATCH=match"; then
  fail_msg "d5: emitted a spurious DISPATCH=match on unrecoverable model: $OUT"
else
  pass_msg "d5: no spurious DISPATCH=match when model unrecoverable"
fi

# Case D6: --verify-dispatch exits 0 even on a mismatch (token carries verdict).
echo ""
echo "Case D6: --verify-dispatch exits 0 on a mismatch verdict"
D6="$ROOT/d6"; make_dispatch_repo "$D6" 0
( cd "$D6" && VED_EXPECT_MODEL=sonnet VED_OBSERVED_MODEL=opus VED_EXPECT_SPLIT_ROLE=false \
    PIPELINE_REPO="fake/repo" PIPELINE_BASE_BRANCH="staging" \
    bash "$SCRIPT_UNDER_TEST" --verify-dispatch 1056 B ) >/dev/null 2>&1
rc=$?
inc
if [ "$rc" -eq 0 ]; then
  pass_msg "d6: --verify-dispatch exited 0 on mismatch (token carries the verdict)"
else
  fail_msg "d6: --verify-dispatch exited $rc (expected 0)"
fi

# Case D7: ADDITIVITY regression guard — the DEFAULT positional mode (no
# --verify-dispatch) still emits its existing ACTION= contract unchanged. Reuse
# the Case 1 shape (worktree resolves, remote absent -> recover-push).
echo ""
echo "Case D7: default positional mode unchanged by the additive --verify-dispatch mode"
D7="$ROOT/d7"; mkdir -p "$D7"; make_stubs "$D7" >/dev/null
OUT=$(STUB_WT_ISSUE=912 STUB_WT_SLUG=foo STUB_REMOTE_HAS=0 \
      STUB_ISSUE_LABELS="in-progress" \
      run_helper "$D7" 912)
assert_action "d7" "$OUT" "ACTION=recover-push"
inc
if printf '%s' "$OUT" | grep -qF "DISPATCH="; then
  fail_msg "d7: default mode leaked a DISPATCH= token (additivity broken): $OUT"
else
  pass_msg "d7: default mode emits ACTION= only (no DISPATCH= leak)"
fi

# Case D8 (#1077): orchestrator HEAD on the BASE branch, [split-role-red] anchor
# lives ONLY on the unmerged feature/foo branch. The OLD `<base>..HEAD` scan finds
# no anchor (HEAD==staging) and spuriously reports shape:single!=split-role. The
# fix resolves the feature ref and scans <base>..<feature-ref>, yielding match.
echo ""
echo "Case D8 (#1077): split-role pair, orchestrator on base branch -> DISPATCH=match (not spurious shape mismatch)"
D8="$ROOT/d8"; make_orchestrator_repo "$D8" 1
OUT=$(VED_EXPECT_MODEL=sonnet VED_OBSERVED_MODEL=sonnet VED_EXPECT_SPLIT_ROLE=true \
      run_vd_orchestrator "$D8" 1077 B)
assert_action "d8" "$OUT" "DISPATCH=match"
inc
if printf '%s' "$OUT" | grep -qF "REASON=shape:single!=split-role"; then
  fail_msg "d8: spurious shape:single mismatch — scanned base..HEAD instead of the feature ref (#1077): $OUT"
else
  pass_msg "d8: no spurious shape mismatch when anchor lives on the unmerged feature branch"
fi

# Case D9 (#1077): genuine single-role — NO [split-role-red] anchor on the feature
# branch. Even with deterministic feature-ref resolution, the absence of the anchor
# MUST still produce shape:single!=split-role (no false positive from the fix).
echo ""
echo "Case D9 (#1077): genuine single-role (no anchor on feature branch) -> shape mismatch preserved"
D9="$ROOT/d9"; make_orchestrator_repo "$D9" 0
OUT=$(VED_EXPECT_MODEL=sonnet VED_OBSERVED_MODEL=sonnet VED_EXPECT_SPLIT_ROLE=true \
      run_vd_orchestrator "$D9" 1077 B)
assert_action "d9" "$OUT" "DISPATCH=mismatch"
assert_action "d9-reason" "$OUT" "REASON=shape:single!=split-role"

# Case D10 (#1186): PATH A is now a REAL dispatch spec. Before #1186 the PATH A
# execute Agent carried no `model=` at all (no knob existed), so there was
# nothing to verify and the mode refused the path letter with exit 2 + usage.
# resolve-execute-dispatch.sh now resolves A (opus default), so the post-dispatch
# verify must accept it. Shape scan is inert for A/C (VED_EXPECT_SPLIT_ROLE=false
# — split-role is PATH B only), so this is a pure model check.
echo ""
echo "Case D10 (#1186): --verify-dispatch accepts PATH A -> DISPATCH=match"
D10="$ROOT/d10"; make_dispatch_repo "$D10" 0
OUT=$(VED_EXPECT_MODEL=opus VED_OBSERVED_MODEL=opus VED_EXPECT_SPLIT_ROLE=false \
      run_vd "$D10" 1186 A)
assert_action "d10" "$OUT" "DISPATCH=match"
assert_action "d10-issue" "$OUT" "ISSUE=1186"
inc
if printf '%s' "$OUT" | grep -qiF "usage"; then
  fail_msg "d10: PATH A still rejected with a usage error (path guard not widened): $OUT"
else
  pass_msg "d10: PATH A accepted (no usage error)"
fi

# Case D11 (#1186): PATH C leaf dispatch, observed model DRIFTED off the resolved
# spec (a leaf silently rode a cheaper/hotter model) -> mismatch, same REASON
# shape as the B/D model check. This is the property that makes the new A/C pins
# verifiable rather than merely declared.
echo ""
echo "Case D11 (#1186): --verify-dispatch accepts PATH C + catches model drift"
D11="$ROOT/d11"; make_dispatch_repo "$D11" 0
OUT=$(VED_EXPECT_MODEL=opus VED_OBSERVED_MODEL=sonnet VED_EXPECT_SPLIT_ROLE=false \
      run_vd "$D11" 1186 C)
assert_action "d11" "$OUT" "DISPATCH=mismatch"
assert_action "d11-reason" "$OUT" "REASON=model:sonnet!=opus"

# Case D12 (#1186): a genuinely invalid path letter STILL exits 2 + usage — the
# guard widened to A|B|C|D, it did not disappear (pr-eval stays refused: the W3
# structural guard that pr-eval is never routed through the execute resolver).
echo ""
echo "Case D12 (#1186): invalid path letters still rejected (guard widened, not removed)"
D12="$ROOT/d12"; make_dispatch_repo "$D12" 0
for bad in E pr-eval; do
  inc
  ERR=$( ( cd "$D12" && VED_EXPECT_MODEL=opus VED_OBSERVED_MODEL=opus \
             VED_EXPECT_SPLIT_ROLE=false \
             PIPELINE_REPO="fake/repo" PIPELINE_BASE_BRANCH="staging" \
             bash "$SCRIPT_UNDER_TEST" --verify-dispatch 1186 "$bad" ) 2>&1 >/dev/null )
  rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$ERR" | grep -qiF "usage"; then
    pass_msg "d12: invalid path '$bad' -> exit 2 + usage"
  else
    fail_msg "d12: invalid path '$bad': expected exit 2 + usage, got rc=$rc err='$ERR'"
  fi
done

# ============================================================================
# #1122 — additive --clean-main <main-repo-dir> mode: orchestrator main-checkout
# cleanliness guard.
#
# A split-role execute subagent (#615/#617) ran `git add` against the MAIN repo
# index instead of its own worktree index, leaving STAGED edits in the
# orchestrator main checkout. That staged-but-uncommitted leak aborted the
# inter-leg `git pull --ff-only origin <base>` base advance with
# "Your local changes ... would be overwritten by merge". check-base-ref-drift.sh
# cannot catch this (it compares committed base SHAs only — a leaked-but-uncommitted
# `git add` produces no stray commit).
#
# The post-wave guard lives here as an ADDITIVE `--clean-main <dir>` mode, mirroring
# the additive `--verify-dispatch` mode: its own single-line token contract on
# stdout, exits 0 in every case (the token, not the exit code, carries the verdict):
#
#   CLEAN=ok    DIR=<dir>
#   CLEAN=dirty DIR=<dir>
#
# `git status --porcelain` is the cleanliness probe: empty output iff working tree
# AND index are both clean; any output (staged, unstaged, or tracked drift) => dirty.
# The default positional ACTION= and --verify-dispatch DISPATCH= contracts stay
# byte-unchanged (additivity regression guard, parallel to Case D7).
# ============================================================================

echo ""
echo "== #1122 --clean-main mode =="

# A real throwaway git repo fixture (mirrors make_dispatch_repo: git init -q -b
# staging, user.email/name, one --allow-empty base commit).
make_clean_repo() {
  local d="$1"
  mkdir -p "$d"
  (
    cd "$d" || exit 1
    git init -q -b staging
    git config user.email t@t.t; git config user.name t
    git commit -q --allow-empty -m "base"
  )
}

run_clean_main() {
  # run_clean_main <main-repo-dir> ; emits the helper's stdout+stderr.
  local repo="$1"
  (
    PIPELINE_REPO="fake/repo" PIPELINE_BASE_BRANCH="staging" \
      bash "$SCRIPT_UNDER_TEST" --clean-main "$repo"
  ) 2>&1
}

# Case CM1: a clean main checkout -> CLEAN=ok.
echo "Case CM1: clean main checkout -> CLEAN=ok"
CM1="$ROOT/cm1"; make_clean_repo "$CM1"
OUT=$(run_clean_main "$CM1")
assert_action "cm1" "$OUT" "CLEAN=ok"

# Case CM2: the #1122 leak — a staged file in the main checkout index -> CLEAN=dirty.
echo ""
echo "Case CM2: staged leak in main checkout index -> CLEAN=dirty"
CM2="$ROOT/cm2"; make_clean_repo "$CM2"
touch "$CM2/leak.txt" && git -C "$CM2" add leak.txt
OUT=$(run_clean_main "$CM2")
assert_action "cm2" "$OUT" "CLEAN=dirty"

# Case CM3: an UNSTAGED tracked modification also reports dirty (porcelain probe
# catches working-tree drift, not just the index).
echo ""
echo "Case CM3: unstaged tracked modification in main checkout -> CLEAN=dirty"
CM3="$ROOT/cm3"; make_clean_repo "$CM3"
( cd "$CM3" && printf 'one\n' > tracked.txt && git add tracked.txt && git commit -q -m "add tracked" && printf 'two\n' >> tracked.txt )
OUT=$(run_clean_main "$CM3")
assert_action "cm3" "$OUT" "CLEAN=dirty"

# Case CM4: --clean-main exits 0 regardless of verdict (token carries the result).
echo ""
echo "Case CM4: --clean-main exits 0 even on a dirty verdict (token carries the verdict)"
CM4="$ROOT/cm4"; make_clean_repo "$CM4"
touch "$CM4/leak.txt" && git -C "$CM4" add leak.txt
( PIPELINE_REPO="fake/repo" PIPELINE_BASE_BRANCH="staging" \
    bash "$SCRIPT_UNDER_TEST" --clean-main "$CM4" ) >/dev/null 2>&1
rc=$?
inc
if [ "$rc" -eq 0 ]; then
  pass_msg "cm4: --clean-main exited 0 on dirty (token carries the verdict, not the exit code)"
else
  fail_msg "cm4: --clean-main exited $rc (expected 0)"
fi

# Case CM5: ADDITIVITY regression guard — a --clean-main run must NOT emit any
# ACTION= or DISPATCH= token (parallel to Case D7). The default positional mode
# and the --verify-dispatch mode are unchanged by the additive --clean-main mode.
echo ""
echo "Case CM5: --clean-main emits CLEAN= only (no ACTION=/DISPATCH= leak)"
CM5="$ROOT/cm5"; make_clean_repo "$CM5"
OUT=$(run_clean_main "$CM5")
inc
if printf '%s' "$OUT" | grep -qE "ACTION=|DISPATCH="; then
  fail_msg "cm5: --clean-main leaked an ACTION=/DISPATCH= token (additivity broken): $OUT"
else
  pass_msg "cm5: --clean-main emits CLEAN= only (no ACTION=/DISPATCH= leak)"
fi

# Case CM6 (#1207): untracked-ONLY main checkout -> CLEAN=untracked-only, NOT dirty.
# The #1122 guard targets a STAGED/index leak; long-standing operator-owned
# untracked paths (mock-web/, scratchpad/, local notes) are not that condition
# and must never trigger the Step 6a stash recovery.
echo ""
echo "Case CM6: untracked-only main checkout -> CLEAN=untracked-only"
CM6="$ROOT/cm6"; make_clean_repo "$CM6"
touch "$CM6/.orphaned_at" "$CM6/scratchpad.md"
mkdir -p "$CM6/mock-web" && touch "$CM6/mock-web/index.html"
OUT=$(run_clean_main "$CM6")
assert_action "cm6" "$OUT" "CLEAN=untracked-only"
inc
if printf '%s' "$OUT" | grep -qF "CLEAN=dirty"; then
  fail_msg "cm6: untracked-only reported CLEAN=dirty (the #1207 false positive)"
else
  pass_msg "cm6: untracked-only did NOT report CLEAN=dirty"
fi

# Case CM7 (#1207): untracked files PLUS a staged index entry -> still CLEAN=dirty.
# Narrowing must not blind the guard to a genuine leak that coexists with scratch files.
echo ""
echo "Case CM7: untracked + staged index leak -> CLEAN=dirty"
CM7="$ROOT/cm7"; make_clean_repo "$CM7"
touch "$CM7/operator-scratch.md"
touch "$CM7/leak.txt" && git -C "$CM7" add leak.txt
OUT=$(run_clean_main "$CM7")
assert_action "cm7" "$OUT" "CLEAN=dirty"

# Case CM8 (#1207): untracked files PLUS a modified TRACKED file -> still CLEAN=dirty.
echo ""
echo "Case CM8: untracked + modified tracked file -> CLEAN=dirty"
CM8="$ROOT/cm8"; make_clean_repo "$CM8"
( cd "$CM8" && printf 'one\n' > tracked.txt && git add tracked.txt \
  && git commit -q -m "add tracked" && printf 'two\n' >> tracked.txt \
  && touch operator-scratch.md )
OUT=$(run_clean_main "$CM8")
assert_action "cm8" "$OUT" "CLEAN=dirty"

# Case CM9 (#1207): untracked-only still exits 0 (token carries the verdict).
echo ""
echo "Case CM9: --clean-main exits 0 on the untracked-only verdict"
CM9="$ROOT/cm9"; make_clean_repo "$CM9"
touch "$CM9/operator-scratch.md"
( PIPELINE_REPO="fake/repo" PIPELINE_BASE_BRANCH="staging" \
    bash "$SCRIPT_UNDER_TEST" --clean-main "$CM9" ) >/dev/null 2>&1
rc=$?
inc
if [ "$rc" -eq 0 ]; then
  pass_msg "cm9: --clean-main exited 0 on untracked-only"
else
  fail_msg "cm9: --clean-main exited $rc (expected 0)"
fi

# ============================================================================
# #1262 — PER-DISPATCH clean-main ATTRIBUTION.
#
# The #1122 `--clean-main` guard above runs at the WAVE/LEG BOUNDARY. That is
# structurally too late to ATTRIBUTE a leak: by the time `CLEAN=dirty` surfaces,
# the agent whose mis-anchored `git add` caused it has already returned and its
# context is gone, so the orchestrator learns only that SOMETHING in the wave
# leaked. #1262(b) asks for the check to run per dispatch — baseline BEFORE each
# execute `Agent`, delta check IMMEDIATELY AFTER it returns.
#
# A bare post-dispatch `--clean-main` cannot do that either: it would blame the
# current agent for dirt that predated it (operator-owned edits, an earlier leak
# that was never cleared). The verdict has to be a DELTA, which needs a baseline.
# Two additive extensions:
#
#   --clean-main-baseline <main-repo-dir> <baseline-file>
#       BASELINE=captured DIR=<dir> PATHS=<line-count>
#       BASELINE=error    DIR=<dir> REASON=not-a-repo
#
#   --clean-main <main-repo-dir> [--since <baseline-file>] [--issue <N>]
#       CLEAN=ok | CLEAN=untracked-only          (unchanged verdicts)
#       CLEAN=pre-existing DIR=<dir> [ISSUE=<N>] (dirty, but nothing NEW)
#       CLEAN=leak         DIR=<dir> [ISSUE=<N>] PATHS=<comma-joined delta>
#       CLEAN=error        DIR=<dir> REASON=missing-baseline
#
# The baseline records only TRACKED/index dirt (untracked `??` entries are
# dropped), so the #1207 `untracked-only` property survives the new mode.
# Rename entries collapse to the DESTINATION path, never the raw `a -> b` form.
#
# ADDITIVITY is the hard constraint: without `--since`, the `--clean-main` branch
# is byte-unchanged and can never emit `leak`/`pre-existing` — CM1-CM9 keep
# passing untouched (PD7/PD11 pin that). Exit code stays 0 in every verdict; the
# token, not the exit code, carries the result (PD8).
#
# The helper NEVER chooses the baseline path itself — the caller names the file.
# That keeps the script namespace-neutral w.r.t. the consumer `.claude/`
# allow-list (`.claude/logs/` is `PIPELINE_LOGS_ENABLED`-gated and defaults to
# no-write, so a baseline written there would silently vanish on a default host).
# ============================================================================

echo ""
echo "== #1262 per-dispatch clean-main attribution =="

# `gh` PATH stub. Before the fix, `--clean-main-baseline` is an UNRECOGNISED mode:
# the script falls through to the positional `ISSUE="$1"` branch, which shells out
# to `gh`. Stubbing it keeps the pre-fix run hermetic and fast (no network) while
# leaving `git` real — the fixtures below are real throwaway repos.
PD_STUB="$ROOT/pd-stub"
mkdir -p "$PD_STUB"
printf '%s\n' '#!/bin/bash' 'exit 1' > "$PD_STUB/gh"
chmod +x "$PD_STUB/gh"

# run_baseline <main-repo-dir> <baseline-file> ; emits stdout+stderr.
run_baseline() {
  local repo="$1" out="$2"
  (
    cd "$repo" 2>/dev/null || cd "$ROOT" || exit 1
    PATH="$PD_STUB:$PATH" PIPELINE_REPO="fake/repo" PIPELINE_BASE_BRANCH="staging" \
      bash "$SCRIPT_UNDER_TEST" --clean-main-baseline "$repo" "$out"
  ) 2>&1
}

# run_clean_main_since <main-repo-dir> <baseline-file> [<issue>] ; stdout+stderr.
run_clean_main_since() {
  local repo="$1" base="$2" issue="${3:-}"
  (
    cd "$repo" 2>/dev/null || cd "$ROOT" || exit 1
    export PATH="$PD_STUB:$PATH" PIPELINE_REPO="fake/repo" PIPELINE_BASE_BRANCH="staging"
    if [ -n "$issue" ]; then
      bash "$SCRIPT_UNDER_TEST" --clean-main "$repo" --since "$base" --issue "$issue"
    else
      bash "$SCRIPT_UNDER_TEST" --clean-main "$repo" --since "$base"
    fi
  ) 2>&1
}

# paths_field <token-line> -> everything after the LAST `PATHS=` (the delta list).
paths_field() {
  printf '%s' "$1" | sed -n 's/.*PATHS=//p' | head -n1
}

# refute <label> <output> <needle> — asserts the needle is ABSENT.
refute() {
  local label="$1" out="$2" needle="$3"
  inc
  if printf '%s' "$out" | grep -F -q -- "$needle"; then
    fail_msg "$label: output must NOT contain \"$needle\": $out"
  else
    pass_msg "$label: output does not contain \"$needle\""
  fi
}

# ---- Case PD1: baseline capture on a CLEAN repo -----------------------------
echo "Case PD1: --clean-main-baseline on a clean repo -> BASELINE=captured + zero-line file"
PD1="$ROOT/pd1"; make_clean_repo "$PD1"
PD1_BASE="$ROOT/pd1.baseline"
OUT=$(run_baseline "$PD1" "$PD1_BASE")
assert_action "pd1" "$OUT" "BASELINE=captured"
inc
if [ -f "$PD1_BASE" ] && [ "$(wc -l < "$PD1_BASE" 2>/dev/null | tr -d ' ')" = "0" ]; then
  pass_msg "pd1: baseline file exists and holds ZERO lines (clean repo)"
else
  fail_msg "pd1: expected an existing zero-line baseline at $PD1_BASE (exists=$([ -f "$PD1_BASE" ] && echo yes || echo no))"
fi

# ---- Case PD2: baseline capture records pre-existing tracked dirt ------------
echo ""
echo "Case PD2: --clean-main-baseline on a repo with one staged file -> that path recorded"
PD2="$ROOT/pd2"; make_clean_repo "$PD2"
touch "$PD2/a.txt" && git -C "$PD2" add a.txt
PD2_BASE="$ROOT/pd2.baseline"
OUT=$(run_baseline "$PD2" "$PD2_BASE")
assert_action "pd2" "$OUT" "BASELINE=captured"
inc
PD2_CONTENT="$(cat "$PD2_BASE" 2>/dev/null || true)"
if [ "$PD2_CONTENT" = "a.txt" ]; then
  pass_msg "pd2: baseline holds exactly the one pre-existing staged path (a.txt)"
else
  fail_msg "pd2: expected baseline to hold exactly 'a.txt', got '$(printf '%s' "$PD2_CONTENT" | tr '\n' ' ')'"
fi

# ---- Case PD3: the #1262 leak — new dirt after a clean baseline --------------
echo ""
echo "Case PD3: clean baseline, then a staged leak -> CLEAN=leak + ISSUE= + PATHS="
PD3="$ROOT/pd3"; make_clean_repo "$PD3"
PD3_BASE="$ROOT/pd3.baseline"
run_baseline "$PD3" "$PD3_BASE" >/dev/null 2>&1
touch "$PD3/b.txt" && git -C "$PD3" add b.txt
OUT=$(run_clean_main_since "$PD3" "$PD3_BASE" 1262)
assert_action "pd3" "$OUT" "CLEAN=leak"
assert_action "pd3" "$OUT" "ISSUE=1262"
inc
PD3_PATHS="$(paths_field "$OUT")"
if printf '%s' "$PD3_PATHS" | grep -F -q 'b.txt'; then
  pass_msg "pd3: PATHS= names the leaked path (b.txt)"
else
  fail_msg "pd3: PATHS= does not name b.txt (got PATHS='$PD3_PATHS' from: $OUT)"
fi

# ---- Case PD4: dirty, but nothing NEW -> pre-existing, never leak -------------
# `CLEAN=pre-existing` is a distinct token precisely so "dirty but not yours"
# never reads as an accusation against the agent that just returned.
echo ""
echo "Case PD4: dirt captured in the baseline and unchanged since -> CLEAN=pre-existing"
PD4="$ROOT/pd4"; make_clean_repo "$PD4"
touch "$PD4/a.txt" && git -C "$PD4" add a.txt
PD4_BASE="$ROOT/pd4.baseline"
run_baseline "$PD4" "$PD4_BASE" >/dev/null 2>&1
OUT=$(run_clean_main_since "$PD4" "$PD4_BASE")
assert_action "pd4" "$OUT" "CLEAN=pre-existing"
refute "pd4" "$OUT" "CLEAN=leak"

# ---- Case PD5: THE ATTRIBUTION PROPERTY — delta only -------------------------
echo ""
echo "Case PD5: pre-existing a.txt + new b.txt -> CLEAN=leak naming ONLY b.txt"
PD5="$ROOT/pd5"; make_clean_repo "$PD5"
touch "$PD5/a.txt" && git -C "$PD5" add a.txt
PD5_BASE="$ROOT/pd5.baseline"
run_baseline "$PD5" "$PD5_BASE" >/dev/null 2>&1
touch "$PD5/b.txt" && git -C "$PD5" add b.txt
OUT=$(run_clean_main_since "$PD5" "$PD5_BASE" 1262)
assert_action "pd5" "$OUT" "CLEAN=leak"
PD5_PATHS="$(paths_field "$OUT")"
inc
if printf '%s' "$PD5_PATHS" | grep -F -q 'b.txt'; then
  pass_msg "pd5: PATHS= names the newly-leaked path (b.txt)"
else
  fail_msg "pd5: PATHS= does not name b.txt (got PATHS='$PD5_PATHS' from: $OUT)"
fi
inc
if printf '%s' "$PD5_PATHS" | grep -F -q 'a.txt'; then
  fail_msg "pd5: PATHS= also names the PRE-EXISTING a.txt — the verdict is a snapshot, not a delta, so it misattributes operator-owned dirt to the dispatched agent (PATHS='$PD5_PATHS')"
else
  pass_msg "pd5: PATHS= excludes the pre-existing a.txt (delta only)"
fi

# ---- Case PD6: #1207 property survives the new mode --------------------------
echo ""
echo "Case PD6: untracked-only checkout with a --since baseline -> CLEAN=untracked-only"
PD6="$ROOT/pd6"; make_clean_repo "$PD6"
PD6_BASE="$ROOT/pd6.baseline"
run_baseline "$PD6" "$PD6_BASE" >/dev/null 2>&1
touch "$PD6/operator-scratch.md"
mkdir -p "$PD6/mock-web" && touch "$PD6/mock-web/index.html"
OUT=$(run_clean_main_since "$PD6" "$PD6_BASE" 1262)
assert_action "pd6" "$OUT" "CLEAN=untracked-only"
refute "pd6" "$OUT" "CLEAN=leak"

# ---- Case PD7: ADDITIVITY — no --since means byte-compat with CM1-CM9 --------
echo ""
echo "Case PD7: --clean-main with NO --since -> CLEAN=dirty only (no new tokens)"
PD7="$ROOT/pd7"; make_clean_repo "$PD7"
touch "$PD7/b.txt" && git -C "$PD7" add b.txt
OUT=$(run_clean_main "$PD7")
assert_action "pd7" "$OUT" "CLEAN=dirty"
refute "pd7" "$OUT" "CLEAN=leak"
refute "pd7" "$OUT" "CLEAN=pre-existing"
refute "pd7" "$OUT" "BASELINE="

# ---- Case PD8: the TOKEN carries the verdict, not the exit code ---------------
echo ""
echo "Case PD8: exit 0 for --clean-main-baseline AND for --clean-main --since on a leak"
PD8="$ROOT/pd8"; make_clean_repo "$PD8"
PD8_BASE="$ROOT/pd8.baseline"
(
  cd "$PD8" || exit 1
  PATH="$PD_STUB:$PATH" PIPELINE_REPO="fake/repo" PIPELINE_BASE_BRANCH="staging" \
    bash "$SCRIPT_UNDER_TEST" --clean-main-baseline "$PD8" "$PD8_BASE"
) >/dev/null 2>&1
rc_base=$?
touch "$PD8/b.txt" && git -C "$PD8" add b.txt
(
  cd "$PD8" || exit 1
  PATH="$PD_STUB:$PATH" PIPELINE_REPO="fake/repo" PIPELINE_BASE_BRANCH="staging" \
    bash "$SCRIPT_UNDER_TEST" --clean-main "$PD8" --since "$PD8_BASE" --issue 1262
) >/dev/null 2>&1
rc_leak=$?
inc
if [ "$rc_base" -eq 0 ] && [ "$rc_leak" -eq 0 ]; then
  pass_msg "pd8: both modes exited 0 (the token, not the exit code, carries the verdict)"
else
  fail_msg "pd8: expected exit 0 from both modes, got baseline=$rc_base leak=$rc_leak"
fi

# ---- Case PD9: a missing baseline is advisory, not a wrong verdict ------------
echo ""
echo "Case PD9: --since pointing at a non-existent file -> CLEAN=error REASON=missing-baseline"
PD9="$ROOT/pd9"; make_clean_repo "$PD9"
touch "$PD9/b.txt" && git -C "$PD9" add b.txt
OUT=$(run_clean_main_since "$PD9" "$ROOT/pd9-does-not-exist.baseline" 1262)
assert_action "pd9" "$OUT" "CLEAN=error"
assert_action "pd9" "$OUT" "REASON=missing-baseline"
(
  cd "$PD9" || exit 1
  PATH="$PD_STUB:$PATH" PIPELINE_REPO="fake/repo" PIPELINE_BASE_BRANCH="staging" \
    bash "$SCRIPT_UNDER_TEST" --clean-main "$PD9" --since "$ROOT/pd9-does-not-exist.baseline"
) >/dev/null 2>&1
rc=$?
inc
if [ "$rc" -eq 0 ]; then
  pass_msg "pd9: missing baseline still exits 0 (advisory, not fatal)"
else
  fail_msg "pd9: missing baseline exited $rc (expected 0)"
fi

# ---- Case PD10: arg guard mirrors the existing --clean-main guard -------------
echo ""
echo "Case PD10: --clean-main-baseline with fewer than 2 operands -> usage on stderr, exit 2"
PD10="$ROOT/pd10"; make_clean_repo "$PD10"
for form in "one-operand" "no-operand"; do
  if [ "$form" = "one-operand" ]; then
    ERR=$( ( cd "$ROOT" || exit 1
             PATH="$PD_STUB:$PATH" PIPELINE_REPO="fake/repo" PIPELINE_BASE_BRANCH="staging" \
               bash "$SCRIPT_UNDER_TEST" --clean-main-baseline "$PD10" ) 2>&1 >/dev/null )
  else
    ERR=$( ( cd "$ROOT" || exit 1
             PATH="$PD_STUB:$PATH" PIPELINE_REPO="fake/repo" PIPELINE_BASE_BRANCH="staging" \
               bash "$SCRIPT_UNDER_TEST" --clean-main-baseline ) 2>&1 >/dev/null )
  fi
  rc=$?
  inc
  if [ "$rc" -eq 2 ] && printf '%s' "$ERR" | grep -qiF "usage"; then
    pass_msg "pd10 ($form): exit 2 + usage on stderr"
  else
    fail_msg "pd10 ($form): expected exit 2 + usage on stderr, got rc=$rc err='$ERR'"
  fi
done

# ---- Case PD11: ADDITIVITY, mirrors CM5 --------------------------------------
echo ""
echo "Case PD11: --clean-main-baseline emits BASELINE= only (no ACTION=/DISPATCH=/CLEAN= leak)"
PD11="$ROOT/pd11"; make_clean_repo "$PD11"
PD11_BASE="$ROOT/pd11.baseline"
OUT=$(run_baseline "$PD11" "$PD11_BASE")
inc
if printf '%s' "$OUT" | grep -qE "ACTION=|DISPATCH=|CLEAN="; then
  fail_msg "pd11: --clean-main-baseline leaked an ACTION=/DISPATCH=/CLEAN= token (additivity broken): $OUT"
else
  pass_msg "pd11: --clean-main-baseline emits BASELINE= only"
fi

# ---- Case PD12: rename entries collapse to the destination path ---------------
# `git status --porcelain` reports a staged rename as `R  a.txt -> c.txt`. The raw
# arrow form is not a path and must never reach the PATHS= delta.
echo ""
echo "Case PD12: staged rename after a clean baseline -> PATHS= names the destination only"
PD12="$ROOT/pd12"; make_clean_repo "$PD12"
( cd "$PD12" && printf 'one\n' > a.txt && git add a.txt && git commit -q -m "add a" )
PD12_BASE="$ROOT/pd12.baseline"
run_baseline "$PD12" "$PD12_BASE" >/dev/null 2>&1
git -C "$PD12" mv a.txt c.txt
OUT=$(run_clean_main_since "$PD12" "$PD12_BASE" 1262)
assert_action "pd12" "$OUT" "CLEAN=leak"
PD12_PATHS="$(paths_field "$OUT")"
inc
if printf '%s' "$PD12_PATHS" | grep -F -q 'c.txt'; then
  pass_msg "pd12: PATHS= names the rename destination (c.txt)"
else
  fail_msg "pd12: PATHS= does not name c.txt (got PATHS='$PD12_PATHS' from: $OUT)"
fi
inc
if printf '%s' "$PD12_PATHS" | grep -F -q ' -> '; then
  fail_msg "pd12: PATHS= carries the raw porcelain arrow form (' -> ') instead of the destination path (PATHS='$PD12_PATHS')"
else
  pass_msg "pd12: PATHS= carries no raw ' -> ' arrow form"
fi

# ============================================================================
# #1266 — the --clean-main option loop must not silently swallow an
# unrecognised argument. Before the fix, the catch-all `*) shift ;;` consumes
# any unknown token (a typo'd `--since`, a stale flag) and the run degrades to
# the legacy un-attributed CLEAN=ok/dirty/untracked-only verdict with no signal
# that the requested attribution mode was never armed. After the fix, an
# unrecognised token emits `CLEAN=error ... REASON=unrecognized-arg:<token>`,
# exit 0 — same shape as the existing missing-baseline path.
# ============================================================================

echo ""
echo "== #1266 --clean-main strict argument parsing =="

# ---- Case AP1: the exact silent-degrade scenario — a typo'd --since on a
# DIRTY repo must never fall through to the plain CLEAN=dirty verdict. -------
echo "Case AP1: typo'd --since flag on a dirty repo -> CLEAN=error, never CLEAN=dirty"
AP1="$ROOT/ap1"; make_clean_repo "$AP1"
touch "$AP1/leak.txt" && git -C "$AP1" add leak.txt
OUT=$( (PIPELINE_REPO="fake/repo" PIPELINE_BASE_BRANCH="staging" \
    bash "$SCRIPT_UNDER_TEST" --clean-main "$AP1" --sicne "$ROOT/ap1.baseline" --issue 1266) 2>&1 )
assert_action "ap1" "$OUT" "CLEAN=error"
assert_action "ap1" "$OUT" "REASON=unrecognized-arg:--sicne"
refute "ap1" "$OUT" "CLEAN=dirty"

# ---- Case AP2: an unrecognised flag on a CLEAN repo must not report CLEAN=ok -
echo ""
echo "Case AP2: unrecognised flag on a clean repo -> CLEAN=error, never CLEAN=ok"
AP2="$ROOT/ap2"; make_clean_repo "$AP2"
OUT=$( (PIPELINE_REPO="fake/repo" PIPELINE_BASE_BRANCH="staging" \
    bash "$SCRIPT_UNDER_TEST" --clean-main "$AP2" --bogus) 2>&1 )
assert_action "ap2" "$OUT" "CLEAN=error"
assert_action "ap2" "$OUT" "REASON=unrecognized-arg:--bogus"
refute "ap2" "$OUT" "CLEAN=ok"

# ---- Case AP3: the error verdict still exits 0 (token carries the verdict) --
echo ""
echo "Case AP3: unrecognised flag still exits 0"
inc
( PIPELINE_REPO="fake/repo" PIPELINE_BASE_BRANCH="staging" \
    bash "$SCRIPT_UNDER_TEST" --clean-main "$AP2" --bogus ) >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "ap3: exited 0 on the unrecognized-arg verdict"
else
  fail_msg "ap3: exited $rc (expected 0)"
fi

# ---- Negative controls: every currently-valid invocation is unaffected -----
echo ""
echo "Case AP4 (negative control): bare positional --clean-main <dir> unaffected"
AP4="$ROOT/ap4"; make_clean_repo "$AP4"
OUT=$(run_clean_main "$AP4")
assert_action "ap4" "$OUT" "CLEAN=ok"
refute "ap4" "$OUT" "CLEAN=error"

echo ""
echo "Case AP5 (negative control): --clean-main <dir> --since <baseline> --issue <N> unaffected"
AP5="$ROOT/ap5"; make_clean_repo "$AP5"
AP5_BASE="$ROOT/ap5.baseline"
run_baseline "$AP5" "$AP5_BASE" >/dev/null 2>&1
touch "$AP5/b.txt" && git -C "$AP5" add b.txt
OUT=$(run_clean_main_since "$AP5" "$AP5_BASE" 1266)
assert_action "ap5" "$OUT" "CLEAN=leak"
assert_action "ap5" "$OUT" "ISSUE=1266"
refute "ap5" "$OUT" "CLEAN=error"

echo ""
echo "Case AP6 (negative control): --clean-main-baseline <dir> <file> unaffected"
AP6="$ROOT/ap6"; make_clean_repo "$AP6"
AP6_BASE="$ROOT/ap6.baseline"
OUT=$(run_baseline "$AP6" "$AP6_BASE")
assert_action "ap6" "$OUT" "BASELINE=captured"
refute "ap6" "$OUT" "CLEAN=error"

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
