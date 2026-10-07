#!/bin/bash
set -euo pipefail
# Regression guard for #1382: setup-worktree.sh creates .claude/scratch/
# even when there's no issue-<N> attachment dir to mirror.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../scripts/setup-worktree.sh"
PASS=0; FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
PROJ="$WORKDIR/proj"
mkdir -p "$PROJ"
git init -q "$PROJ"
git -C "$PROJ" config user.email t@t.t
git -C "$PROJ" config user.name t
echo seed > "$PROJ/seed.txt"
echo pipeline.config > "$PROJ/.gitignore"
git -C "$PROJ" add seed.txt .gitignore && git -C "$PROJ" commit -qm seed
git init --bare -q "$WORKDIR/origin.git"
git -C "$PROJ" remote add origin "$WORKDIR/origin.git"
git -C "$PROJ" push -q origin HEAD:refs/heads/main

cat > "$PROJ/pipeline.config" <<'EOF'
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="main"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_INSTALL_CMD="true"
PIPELINE_SEED_CMD=""
PIPELINE_SYNC_ENVS=""
PIPELINE_SYNC_VENVS=""
EOF

export PIPELINE_PROJECT_ROOT="$PROJ"
cd "$PROJ"
bash "$TEMPLATE" feature/no-attachments 999 >"$WORKDIR/out" 2>&1 \
  || { cat "$WORKDIR/out"; fail_msg "setup-worktree.sh exited non-zero"; }

WT="$PROJ/.claude/worktrees/wt-999-no-attachments"
[ -d "$WT/.claude/scratch" ] \
  && pass_msg "scratch dir created with no attachments to mirror" \
  || fail_msg "scratch dir missing at $WT"

STATUS="$(git -C "$WT" status --porcelain)"
[ -z "$STATUS" ] && pass_msg "worktree status clean" || fail_msg "worktree not clean: $STATUS"

git -C "$PROJ" worktree remove --force "$WT" 2>/dev/null || true
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
