#!/bin/bash
set -euo pipefail

# Tests for scripts/check-branch-cruft.sh — the pre-PR guard that inspects the
# COMMITTED branch-vs-base diff (`git diff --name-only "$PIPELINE_BASE_BRANCH"..HEAD`)
# against a deterministic cruft denylist and exits 1 if any committed path is cruft.
#
# By Step 9 of execute-issue-plan the executor has already committed all work via
# red→green→commit, so the staged index is empty at PR time — the guard MUST inspect
# the committed diff (not `--cached`) to catch cruft swept into a feature commit (#1015/#1028).
#
# Each case sets up a throwaway git repo in a mktemp dir: a base branch with a baseline
# commit, then a `feature` branch that commits the case's files. The guard is run with
# cwd = the temp repo and PIPELINE_BASE_BRANCH=base, asserting the exit code on the
# committed base..HEAD diff. Case (f) is the #1028 core: an UNTRACKED+UNCOMMITTED cruft
# file is absent from the committed diff and so must NOT be implicated.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GUARD="$REPO_ROOT/scripts/check-branch-cruft.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT

# Create a fresh throwaway repo with a base branch carrying one baseline commit,
# then a `feature` branch checked out. Prints the repo path on stdout.
new_repo() {
  local repo="$TMP/repo-$RANDOM-$RANDOM"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    # Pin the base branch name explicitly to avoid default-branch-name ambiguity.
    git checkout -q -b base
    mkdir -p src
    echo "baseline" > src/baseline.txt
    git add src/baseline.txt
    git commit -q -m "baseline"
    git checkout -q -b feature
  )
  echo "$repo"
}

# Run the guard inside $1 with PIPELINE_BASE_BRANCH=base; capture exit code + stderr.
# Sets globals RC and STDERR.
run_guard() {
  local repo="$1"
  local err="$TMP/stderr-$RANDOM"
  set +e
  ( cd "$repo" && PIPELINE_BASE_BRANCH=base bash "$GUARD" >/dev/null 2>"$err" )
  RC=$?
  set -e
  STDERR="$(cat "$err")"
}

# ---------------------------------------------------------------------------
# (a) script exists and is executable
# ---------------------------------------------------------------------------
inc
if [ -x "$GUARD" ]; then
  pass_msg "(a) scripts/check-branch-cruft.sh exists and is executable"
else
  fail_msg "(a) scripts/check-branch-cruft.sh missing or not executable: $GUARD"
fi

# ---------------------------------------------------------------------------
# (b) clean feature commit → exit 0
# ---------------------------------------------------------------------------
inc
repo="$(new_repo)"
(
  cd "$repo"
  mkdir -p src
  echo "hello" > src/foo.txt
  git add src/foo.txt
  git commit -q -m "add foo"
)
run_guard "$repo"
if [ "$RC" -eq 0 ]; then
  pass_msg "(b) clean feature commit → exit 0"
else
  fail_msg "(b) clean feature commit expected exit 0, got $RC; stderr: $STDERR"
fi

# ---------------------------------------------------------------------------
# (c) committed migration-cleanup report → exit 1, stderr names the path
# ---------------------------------------------------------------------------
inc
repo="$(new_repo)"
(
  cd "$repo"
  mkdir -p .claude
  echo "report" > .claude/migration-cleanup-report-claudemd.txt
  git add -f .claude/migration-cleanup-report-claudemd.txt
  git commit -q -m "sweep report"
)
run_guard "$repo"
if [ "$RC" -eq 1 ] && printf '%s' "$STDERR" | grep -q "migration-cleanup-report-claudemd.txt"; then
  pass_msg "(c) committed migration-cleanup report → exit 1, stderr names path"
else
  fail_msg "(c) expected exit 1 + path in stderr, got rc=$RC; stderr: $STDERR"
fi

# ---------------------------------------------------------------------------
# (d) committed migration-cleanup patch → exit 1
# ---------------------------------------------------------------------------
inc
repo="$(new_repo)"
(
  cd "$repo"
  mkdir -p .claude
  echo "patch" > .claude/migration-cleanup-claudemd.patch
  git add -f .claude/migration-cleanup-claudemd.patch
  git commit -q -m "sweep patch"
)
run_guard "$repo"
if [ "$RC" -eq 1 ]; then
  pass_msg "(d) committed migration-cleanup patch → exit 1"
else
  fail_msg "(d) expected exit 1, got rc=$RC; stderr: $STDERR"
fi

# ---------------------------------------------------------------------------
# (e) each denylist pattern, force-added past local ignore, in its own commit → exit 1
# ---------------------------------------------------------------------------
e_cases=(
  ".claude/logs/x"
  ".claude/scratch/x"
  ".claude/worktrees/x"
  ".claude/settings.local.json"
  "pipeline.config"
  ".claude/foo.patch"
)
for path in "${e_cases[@]}"; do
  inc
  repo="$(new_repo)"
  (
    cd "$repo"
    mkdir -p "$(dirname "$path")"
    echo "cruft" > "$path"
    git add -f "$path"
    git commit -q -m "sweep $path"
  )
  run_guard "$repo"
  if [ "$RC" -eq 1 ]; then
    pass_msg "(e) committed denylist path $path → exit 1"
  else
    fail_msg "(e) committed $path expected exit 1, got rc=$RC; stderr: $STDERR"
  fi
done

# ---------------------------------------------------------------------------
# (f) #1028 core: untracked+uncommitted cruft NOT implicated → exit 0
# ---------------------------------------------------------------------------
inc
repo="$(new_repo)"
(
  cd "$repo"
  mkdir -p src .claude
  echo "hello" > src/foo.txt
  git add src/foo.txt
  git commit -q -m "add foo"
  # Pre-existing cruft present in the worktree but never git add-ed / committed.
  echo "stray" > .claude/migration-cleanup-report-claudemd.txt
)
run_guard "$repo"
if [ "$RC" -eq 0 ]; then
  pass_msg "(f) untracked+uncommitted cruft not in committed diff → exit 0"
else
  fail_msg "(f) expected exit 0 (cruft uncommitted), got rc=$RC; stderr: $STDERR"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
