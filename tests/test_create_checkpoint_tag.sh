#!/bin/bash
set -euo pipefail

# Tests for create-checkpoint-tag.sh:
#   - creates an annotated local tag on the base branch
#   - tag body lists issues + PRs supplied via --issues / --prs
#   - tag is NEVER pushed to remote
#   - re-running within the same day bumps the NN suffix
#   - --dry-run prints but does not create a tag

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/../scripts/create-checkpoint-tag.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

if [ ! -f "$SCRIPT_UNDER_TEST" ]; then
  echo "ERROR: script under test not found at $SCRIPT_UNDER_TEST" >&2
  exit 1
fi

# --- Setup: throwaway project + bare remote ---
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

PROJ="$WORKDIR/proj"
REMOTE_BARE="$WORKDIR/remote.git"

git init --bare -q "$REMOTE_BARE"

mkdir -p "$PROJ/.claude/scripts"
cp "$SCRIPT_UNDER_TEST" "$PROJ/.claude/scripts/create-checkpoint-tag.sh"
chmod +x "$PROJ/.claude/scripts/create-checkpoint-tag.sh"

cat > "$PROJ/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="ct"
EOF

cd "$PROJ"
git init -q -b pipeline
git config user.email "test@test"
git config user.name "test"
echo "hello" > README
git add README
git commit -qm "init"
git remote add origin "$REMOTE_BARE"
git push -q origin pipeline

DATE=$(date +%Y-%m-%d)

# --- Test 1: basic tag creation ---
echo "Test 1: creates an annotated tag with issues + PRs"
bash .claude/scripts/create-checkpoint-tag.sh --issues "310,311" --prs "450,451" >/dev/null
TAG1="checkpoint/${DATE}-01"

inc
if git rev-parse --verify "$TAG1" >/dev/null 2>&1; then
  pass_msg "tag $TAG1 exists"
else
  fail_msg "tag $TAG1 missing"
fi

inc
TYPE=$(git cat-file -t "$TAG1" 2>/dev/null || echo "")
if [ "$TYPE" = "tag" ]; then
  pass_msg "tag is annotated"
else
  fail_msg "expected annotated (tag), got: $TYPE"
fi

inc
BODY=$(git tag -l --format='%(contents)' "$TAG1")
if echo "$BODY" | grep -q "Issues: #310, #311"; then
  pass_msg "annotation has Issues line"
else
  fail_msg "annotation missing 'Issues: #310, #311'; body was:"
  echo "$BODY" | sed 's/^/    /'
fi

inc
if echo "$BODY" | grep -Eq "PRs:[[:space:]]+#450, #451"; then
  pass_msg "annotation has PRs line"
else
  fail_msg "annotation missing 'PRs: #450, #451'; body was:"
  echo "$BODY" | sed 's/^/    /'
fi

inc
REMOTE_TAGS=$(git ls-remote --tags origin 2>/dev/null || echo "")
if echo "$REMOTE_TAGS" | grep -q "refs/tags/checkpoint/"; then
  fail_msg "tag was pushed to remote (expected local-only)"
else
  pass_msg "tag was NOT pushed to remote"
fi

# --- Test 2: re-run within same day bumps NN ---
echo "Test 2: re-run within same day bumps NN to 02"
bash .claude/scripts/create-checkpoint-tag.sh --issues "312" --prs "452" >/dev/null
TAG2="checkpoint/${DATE}-02"

inc
if git rev-parse --verify "$TAG2" >/dev/null 2>&1; then
  pass_msg "tag $TAG2 exists"
else
  fail_msg "tag $TAG2 missing"
fi

# --- Test 3: --dry-run prints but does not create a tag ---
echo "Test 3: --dry-run prints intended tag but creates nothing"
OUT=$(bash .claude/scripts/create-checkpoint-tag.sh --issues "999" --prs "888" --dry-run)
TAG3="checkpoint/${DATE}-03"

inc
if git rev-parse --verify "$TAG3" >/dev/null 2>&1; then
  fail_msg "--dry-run should not have created $TAG3"
else
  pass_msg "--dry-run did not create a tag"
fi

inc
if echo "$OUT" | grep -q "$TAG3"; then
  pass_msg "--dry-run output mentions $TAG3"
else
  fail_msg "--dry-run output missing $TAG3; output was:"
  echo "$OUT" | sed 's/^/    /'
fi

# --- Summary ---
echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
