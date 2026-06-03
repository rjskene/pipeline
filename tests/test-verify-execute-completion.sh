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

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
