#!/bin/bash
set -euo pipefail

# Tests for the base-branch defaulting logic in setup-worktree.sh.
# Covers four branches of the selection algorithm:
#   1. --base explicit -> always wins regardless of current branch
#   2. current branch non-default (e.g. 'next'), no --base -> current branch
#   3. current branch 'main', no --base -> PIPELINE_BASE_BRANCH fallback
#   4. detached HEAD, no --base -> PIPELINE_BASE_BRANCH fallback
#
# Runs against a local bare "remote" so the script's ls-remote/push block
# does not require network access.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../scripts/setup-worktree.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$TEMPLATE" ]; then
  echo "ERROR: template not found at $TEMPLATE" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Build a fresh project layout on the specified "current" branch.
# Arg: branch to leave the main repo on, or the literal "DETACHED" for detached HEAD.
# Echoes the project root path to stdout.
setup_project() {
  local current_branch="$1"
  local PROJ="$WORKDIR/proj"

  rm -rf "$PROJ" "$WORKDIR/origin.git"
  mkdir -p "$PROJ/.claude/scripts"

  git init --bare -q "$WORKDIR/origin.git"

  git -c init.defaultBranch=main init -q "$PROJ"
  git -C "$PROJ" remote add origin "$WORKDIR/origin.git"
  git -C "$PROJ" config user.email "tester@example.com"
  git -C "$PROJ" config user.name "tester"
  echo "seed" > "$PROJ/seed.txt"
  git -C "$PROJ" add seed.txt
  git -C "$PROJ" commit -q -m "seed"

  # Create the branches the script expects; push them so ls-remote --heads finds them.
  git -C "$PROJ" branch -q pipeline
  git -C "$PROJ" branch -q next
  git -C "$PROJ" push -q origin main pipeline next

  cat > "$PROJ/pipeline.config" <<'EOF'
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="ct"
PIPELINE_INSTALL_CMD=""
PIPELINE_SEED_CMD=""
PIPELINE_TEST_CMD=""
PIPELINE_TYPECHECK_CMD=""
PIPELINE_CONTEXT_FILES=""
PIPELINE_SYNC_ENVS=""
PIPELINE_SYNC_VENVS=""
PIPELINE_SYNC_DOCS=""
PIPELINE_SYNC_FILES=""
PIPELINE_FRONTEND_PORT_OFFSET=4000
PIPELINE_LABELS_EXCLUDED=""
PIPELINE_LABELS_LATER=""
PIPELINE_LABELS_HUMAN=""
PIPELINE_WIN_TEMP=""
PIPELINE_SUBTREE_REMOTE=""
PIPELINE_SUBTREE_BRANCH=""
EOF

  # The installer copies scripts verbatim (no envsubst).
  cp "$TEMPLATE" "$PROJ/.claude/scripts/setup-worktree.sh"
  chmod +x "$PROJ/.claude/scripts/setup-worktree.sh"

  case "$current_branch" in
    DETACHED)
      git -C "$PROJ" checkout -q --detach HEAD
      ;;
    *)
      git -C "$PROJ" checkout -q "$current_branch"
      ;;
  esac

  echo "$PROJ"
}

assert_base_branch() {
  local meta_file="$1"
  local expected="$2"
  local msg="$3"
  if [ ! -f "$meta_file" ]; then
    fail_msg "$msg — .claude/base-branch not created at $meta_file"
    return
  fi
  if grep -Fxq "$expected" "$meta_file"; then
    pass_msg "$msg"
  else
    local actual
    actual=$(cat "$meta_file")
    fail_msg "$msg (expected '$expected', got '$actual')"
  fi
}

# --- Case 1: explicit --base wins over current branch ---
# setup-worktree.sh now sources pipeline.config from $(pwd) (or
# $PIPELINE_PROJECT_ROOT); invoke each case from inside $PROJ so the
# config resolves correctly.
echo "Case 1: --base custom-branch wins over current branch 'next'"
inc
PROJ=$(setup_project next)
git -C "$PROJ" branch -q custom-branch
git -C "$PROJ" push -q origin custom-branch
if ! ( cd "$PROJ" && bash .claude/scripts/setup-worktree.sh --base custom-branch feature/foo 99 ) \
        >"$WORKDIR/case1.log" 2>&1; then
  fail_msg "Case 1: setup-worktree.sh exited non-zero"
  sed 's/^/    /' "$WORKDIR/case1.log"
else
  assert_base_branch "$PROJ/.claude/worktrees/ct-99-foo/.claude/base-branch" \
                     "custom-branch" "Case 1: explicit --base wins"
fi

# --- Case 2: current branch 'next', no --base -> current branch ---
echo "Case 2: current branch 'next' inferred as base"
inc
PROJ=$(setup_project next)
if ! ( cd "$PROJ" && bash .claude/scripts/setup-worktree.sh feature/bar 100 ) \
        >"$WORKDIR/case2.log" 2>&1; then
  fail_msg "Case 2: setup-worktree.sh exited non-zero"
  sed 's/^/    /' "$WORKDIR/case2.log"
else
  assert_base_branch "$PROJ/.claude/worktrees/ct-100-bar/.claude/base-branch" \
                     "next" "Case 2: current 'next' inferred as base"
fi

# --- Case 3: current branch 'main', no --base -> PIPELINE_BASE_BRANCH fallback ---
echo "Case 3: current branch 'main' falls back to PIPELINE_BASE_BRANCH"
inc
PROJ=$(setup_project main)
if ! ( cd "$PROJ" && bash .claude/scripts/setup-worktree.sh feature/baz 101 ) \
        >"$WORKDIR/case3.log" 2>&1; then
  fail_msg "Case 3: setup-worktree.sh exited non-zero"
  sed 's/^/    /' "$WORKDIR/case3.log"
else
  assert_base_branch "$PROJ/.claude/worktrees/ct-101-baz/.claude/base-branch" \
                     "pipeline" "Case 3: 'main' falls back to PIPELINE_BASE_BRANCH"
fi

# --- Case 4: detached HEAD, no --base -> PIPELINE_BASE_BRANCH fallback ---
echo "Case 4: detached HEAD falls back to PIPELINE_BASE_BRANCH"
inc
PROJ=$(setup_project DETACHED)
if ! ( cd "$PROJ" && bash .claude/scripts/setup-worktree.sh feature/qux 102 ) \
        >"$WORKDIR/case4.log" 2>&1; then
  fail_msg "Case 4: setup-worktree.sh exited non-zero"
  sed 's/^/    /' "$WORKDIR/case4.log"
else
  assert_base_branch "$PROJ/.claude/worktrees/ct-102-qux/.claude/base-branch" \
                     "pipeline" "Case 4: detached HEAD falls back to PIPELINE_BASE_BRANCH"
fi

echo ""
echo "================================"
echo "  $TESTS cases: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
