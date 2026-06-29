#!/bin/bash
set -euo pipefail

# Tests for the next-branch --base ACTUATION in setup-worktree.sh (#1128).
#
# Background (#626): historically setup-worktree.sh cut every worktree from
# MAIN_REPO's LOCAL HEAD and treated --base as metadata only. To actually land
# next-labelled work ON the next-branch, --base now ACTUATES when it names a
# branch other than the orchestrator's current local branch: the script fetches
# origin/<base> and cuts the worktree from THAT tip. When origin/<base> does not
# exist anywhere, it is auto-created from PIPELINE_BASE_BRANCH.
#
# Assertions:
#   A. --base next records `next` in .claude/base-branch.
#   B. --base next cuts the worktree from origin/next's REMOTE tip (a commit
#      present on origin/next but ABSENT from MAIN_REPO's local HEAD).
#   C. when `next` exists NOWHERE (local or remote), --base next auto-creates it
#      from PIPELINE_BASE_BRANCH and the worktree inherits that branch's tip.
#
# Runs against a local bare "remote" so push/ls-remote need no network.

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

write_config() {
  local proj="$1" base="$2"
  cat > "$proj/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="$base"
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
}

# ---------------------------------------------------------------------------
# Cases A + B: --base next cuts from origin/next's REMOTE tip.
# ---------------------------------------------------------------------------
echo "Cases A+B: --base next records + cuts from origin/next remote tip"
PROJ="$WORKDIR/proj"
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
git -C "$PROJ" branch -q staging
git -C "$PROJ" push -q origin main staging
git -C "$PROJ" checkout -q staging
write_config "$PROJ" staging
cp "$TEMPLATE" "$PROJ/.claude/scripts/setup-worktree.sh"
chmod +x "$PROJ/.claude/scripts/setup-worktree.sh"

# Build origin/next with a commit that does NOT exist on MAIN_REPO's local HEAD.
REMOTE_CLONE="$WORKDIR/remote-clone"
git clone -q "$WORKDIR/origin.git" "$REMOTE_CLONE"
git -C "$REMOTE_CLONE" config user.email "remote@example.com"
git -C "$REMOTE_CLONE" config user.name "remote"
git -C "$REMOTE_CLONE" checkout -q -b next origin/staging
echo "next-only" > "$REMOTE_CLONE/next.txt"
git -C "$REMOTE_CLONE" add next.txt
git -C "$REMOTE_CLONE" commit -q -m "next-branch only commit"
git -C "$REMOTE_CLONE" push -q origin next
NEXT_COMMIT=$(git -C "$REMOTE_CLONE" rev-parse HEAD)

# The orchestrator (staging checkout) has NOT fetched origin/next yet — the
# actuation must fetch it itself.
inc
if ! ( cd "$PROJ" && bash .claude/scripts/setup-worktree.sh --base next feature/foo 999 ) \
        >"$WORKDIR/ab.log" 2>&1; then
  fail_msg "A+B: setup-worktree.sh exited non-zero"
  sed 's/^/    /' "$WORKDIR/ab.log"
else
  META="$PROJ/.claude/worktrees/ct-999-foo/.claude/base-branch"
  if [ -f "$META" ] && grep -Fxq "next" "$META"; then
    pass_msg "A: .claude/base-branch records next"
  else
    fail_msg "A: .claude/base-branch != next (got '$(cat "$META" 2>/dev/null)')"
  fi

  inc
  WT_FOO="$PROJ/.claude/worktrees/ct-999-foo"
  if git -C "$WT_FOO" merge-base --is-ancestor "$NEXT_COMMIT" HEAD 2>/dev/null; then
    pass_msg "B: worktree cut from origin/next remote tip (next-only commit present)"
  else
    fail_msg "B: worktree HEAD missing origin/next's remote-only commit"
  fi
fi

# ---------------------------------------------------------------------------
# Case C: --base next auto-creates next from PIPELINE_BASE_BRANCH when absent.
# ---------------------------------------------------------------------------
echo "Case C: --base next auto-creates next from PIPELINE_BASE_BRANCH when absent"
PROJ2="$WORKDIR/proj2"
rm -rf "$PROJ2" "$WORKDIR/origin2.git"
mkdir -p "$PROJ2/.claude/scripts"
git init --bare -q "$WORKDIR/origin2.git"
git -c init.defaultBranch=main init -q "$PROJ2"
git -C "$PROJ2" remote add origin "$WORKDIR/origin2.git"
git -C "$PROJ2" config user.email "tester@example.com"
git -C "$PROJ2" config user.name "tester"
echo "seed" > "$PROJ2/seed.txt"
git -C "$PROJ2" add seed.txt
git -C "$PROJ2" commit -q -m "seed"
git -C "$PROJ2" branch -q staging
git -C "$PROJ2" push -q origin main staging
git -C "$PROJ2" checkout -q staging
# Add a staging-only commit so we can prove next was cut from staging's tip.
echo "staging-only" > "$PROJ2/staging.txt"
git -C "$PROJ2" add staging.txt
git -C "$PROJ2" commit -q -m "staging-only commit"
git -C "$PROJ2" push -q origin staging
STAGING_COMMIT=$(git -C "$PROJ2" rev-parse HEAD)
write_config "$PROJ2" staging
cp "$TEMPLATE" "$PROJ2/.claude/scripts/setup-worktree.sh"
chmod +x "$PROJ2/.claude/scripts/setup-worktree.sh"

# `next` exists NOWHERE (no local branch, never pushed). Actuation must create it.
inc
if ! ( cd "$PROJ2" && bash .claude/scripts/setup-worktree.sh --base next feature/bar 1000 ) \
        >"$WORKDIR/c.log" 2>&1; then
  fail_msg "C: setup-worktree.sh exited non-zero"
  sed 's/^/    /' "$WORKDIR/c.log"
else
  META2="$PROJ2/.claude/worktrees/ct-1000-bar/.claude/base-branch"
  if [ -f "$META2" ] && grep -Fxq "next" "$META2"; then
    pass_msg "C: .claude/base-branch records next after auto-create"
  else
    fail_msg "C: .claude/base-branch != next after auto-create (got '$(cat "$META2" 2>/dev/null)')"
  fi

  inc
  # next was auto-created from PIPELINE_BASE_BRANCH (staging) → it exists on origin.
  if git -C "$PROJ2" ls-remote --heads origin next | grep -q "next"; then
    pass_msg "C: next auto-created and pushed to origin"
  else
    fail_msg "C: next NOT created on origin after auto-create path"
  fi

  inc
  WT_BAR="$PROJ2/.claude/worktrees/ct-1000-bar"
  if git -C "$WT_BAR" merge-base --is-ancestor "$STAGING_COMMIT" HEAD 2>/dev/null; then
    pass_msg "C: auto-created next inherits PIPELINE_BASE_BRANCH (staging) tip"
  else
    fail_msg "C: auto-created next HEAD missing staging tip"
  fi
fi

echo ""
echo "================================"
echo "  $TESTS cases: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
