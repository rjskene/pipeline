#!/bin/bash
set -euo pipefail

# Integration test for #716 wrinkle 2: setup-worktree.sh must exclude the
# untracked .claude/base-branch metadata via the common-dir git exclude so
# `gh` doesn't warn about an uncommitted change at PR time.
#
# Asserts:
#   1. .claude/base-branch no longer shows as an untracked change.
#   2. The impl's exclude path resolves to --git-common-dir/info/exclude
#      (the only file git honors for ignore resolution from a linked worktree).
#   3. The entry IS present in that common-dir exclude.
#
# Runs against a local bare "remote" so the script's ls-remote/push block
# does not require network access. Harness modeled on
# tests/test-setup-worktree-base-defaulting.sh.

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

PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/.claude/scripts"

git init --bare -q "$WORKDIR/origin.git"

git -c init.defaultBranch=main init -q "$PROJ"
git -C "$PROJ" remote add origin "$WORKDIR/origin.git"
git -C "$PROJ" config user.email "tester@example.com"
git -C "$PROJ" config user.name "tester"
echo "seed" > "$PROJ/seed.txt"
git -C "$PROJ" add seed.txt
git -C "$PROJ" commit -q -m "seed"

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

git -C "$PROJ" checkout -q next

if ! ( cd "$PROJ" && bash .claude/scripts/setup-worktree.sh feature/foo 99 ) \
        >"$WORKDIR/setup.log" 2>&1; then
  echo "ERROR: setup-worktree.sh exited non-zero" >&2
  sed 's/^/    /' "$WORKDIR/setup.log" >&2
  exit 1
fi

WORKTREE_PATH="$PROJ/.claude/worktrees/ct-99-foo"

if [ ! -d "$WORKTREE_PATH" ]; then
  echo "ERROR: worktree not created at $WORKTREE_PATH" >&2
  exit 1
fi

# Resolve the exclude path the impl writes (common-dir; honored by git for ignore).
WT_EXCLUDE="$(git -C "$WORKTREE_PATH" rev-parse --git-path info/exclude)"
case "$WT_EXCLUDE" in /*) : ;; *) WT_EXCLUDE="$WORKTREE_PATH/$WT_EXCLUDE" ;; esac
COMMON_EXCLUDE="$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir)/info/exclude"
case "$COMMON_EXCLUDE" in /*) : ;; *) COMMON_EXCLUDE="$WORKTREE_PATH/$COMMON_EXCLUDE" ;; esac

# Case 1: the file no longer shows as an untracked change (the user-visible symptom).
inc
if [ -z "$(git -C "$WORKTREE_PATH" status --porcelain -- .claude/base-branch)" ]; then
  pass_msg ".claude/base-branch is not reported as an untracked change"
else
  fail_msg ".claude/base-branch still shows as untracked in worktree status"
fi

# Case 2: the impl's exclude path is the common-dir exclude (the only file git honors
# for ignore resolution from a linked worktree on git 2.43.0).
inc
if [ "$WT_EXCLUDE" = "$COMMON_EXCLUDE" ]; then
  pass_msg "impl exclude path resolves to the common-dir info/exclude"
else
  fail_msg "impl exclude path ($WT_EXCLUDE) != common-dir exclude ($COMMON_EXCLUDE)"
fi

# Case 3: the entry IS present in the common-dir exclude (this is the mechanism;
# repo-wide scope is accepted and justified — see Design decisions).
inc
if grep -qxF '.claude/base-branch' "$COMMON_EXCLUDE" 2>/dev/null; then
  pass_msg ".claude/base-branch present in the common-dir exclude"
else
  fail_msg ".claude/base-branch missing from the common-dir exclude (looked in $COMMON_EXCLUDE)"
fi

echo ""
echo "================================"
echo "  $TESTS cases: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
