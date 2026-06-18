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
# `issue view ... closedByPullRequestsReferences`, and `pr list`.
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
  # `git ls-remote --heads origin <branch>` — non-empty iff configured.
  if [ "${STUB_REMOTE_HAS:-0}" = "1" ]; then
    echo "abc123	refs/heads/${!#}"
  fi
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
    if [[ "$ARGS" == *closedByPullRequestsReferences* ]]; then
      # headRefName cascade: linked PR head, empty when no linked PR.
      printf '%s' "${STUB_LINKED_PR_HEAD:-}"
    elif [[ "$ARGS" == *labels* ]]; then
      printf '%s' "${STUB_ISSUE_LABELS:-}"
    fi
    ;;
  "pr list")
    printf '%s' "${STUB_PR_LIST_HEAD:-}"
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
      STUB_LINKED_PR_HEAD="feature/foo" \
      STUB_ISSUE_LABELS="in-progress" \
      run_helper "$C3" 912)
assert_action "c3" "$OUT" "ACTION=recover-label"

# ============== Case 4: fully complete -> complete ===========================
echo ""
echo "Case 4: branch pushed + PR open + pr-open label -> complete"
C4="$ROOT/c4"; mkdir -p "$C4"; make_stubs "$C4" >/dev/null
OUT=$(STUB_WT_ISSUE=912 STUB_WT_SLUG=foo STUB_REMOTE_HAS=1 \
      STUB_LINKED_PR_HEAD="feature/foo" \
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
      STUB_LINKED_PR_HEAD="feature/foo" \
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

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
