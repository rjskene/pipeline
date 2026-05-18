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

# --- Test 4: invocation from working-tree scripts/ resolves the same project root as .claude/scripts/ ---
echo "Test 4: invocation from working-tree scripts/ resolves the same project root"
mkdir -p "$PROJ/scripts"
cp "$SCRIPT_UNDER_TEST" "$PROJ/scripts/create-checkpoint-tag.sh"
chmod +x "$PROJ/scripts/create-checkpoint-tag.sh"

set +e
OUT4=$(bash scripts/create-checkpoint-tag.sh --issues "777" --prs "555" --dry-run 2>&1)
RC4=$?
set -e

inc
if [ "$RC4" -eq 0 ]; then
  pass_msg "scripts/ invocation exit 0"
else
  fail_msg "scripts/ invocation expected exit 0, got $RC4; output was:"
  echo "$OUT4" | sed 's/^/    /'
fi

inc
if echo "$OUT4" | grep -Eq "DRY RUN: would create tag checkpoint/${DATE}-[0-9]{2}"; then
  pass_msg "scripts/ dry-run output has expected shape"
else
  fail_msg "scripts/ dry-run output missing 'DRY RUN: would create tag checkpoint/${DATE}-NN'; output was:"
  echo "$OUT4" | sed 's/^/    /'
fi

# --- Test 5: PIPELINE_PROJECT_ROOT override wins over $(dirname "$0") walk ---
echo "Test 5: PIPELINE_PROJECT_ROOT override resolves a second project, not the one holding the script"

PROJ2="$WORKDIR/proj2"
REMOTE_BARE2="$WORKDIR/remote2.git"

git init --bare -q "$REMOTE_BARE2"
mkdir -p "$PROJ2/scripts"
cp "$SCRIPT_UNDER_TEST" "$PROJ2/scripts/create-checkpoint-tag.sh"
chmod +x "$PROJ2/scripts/create-checkpoint-tag.sh"

cat > "$PROJ2/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo2"
PIPELINE_BASE_BRANCH="proj2-base"
PIPELINE_WORKTREE_PREFIX="ct"
EOF

(
  cd "$PROJ2"
  git init -q -b proj2-base
  git config user.email "test@test"
  git config user.name "test"
  echo "hello2" > README
  git add README
  git commit -qm "init2"
  git remote add origin "$REMOTE_BARE2"
  git push -q origin proj2-base
)

# Invoke from $PROJ (where cwd points at the FIRST project) but override
# PIPELINE_PROJECT_ROOT so the resolved repo MUST be proj2. Use the script
# living inside proj2 to make it obvious that the walk-up from $0 would also
# land on proj2 — what we are testing here is the override behavior, so pass
# the script that lives in the OTHER project (proj) to ensure the resolver is
# choosing based on the env var, not on $(dirname "$0").
set +e
OUT5=$(cd "$PROJ" && PIPELINE_PROJECT_ROOT="$PROJ2" bash "$PROJ/scripts/create-checkpoint-tag.sh" --issues "800" --prs "600" --dry-run 2>&1)
RC5=$?
set -e

inc
if [ "$RC5" -eq 0 ]; then
  pass_msg "PIPELINE_PROJECT_ROOT override exit 0"
else
  fail_msg "PIPELINE_PROJECT_ROOT override expected exit 0, got $RC5; output was:"
  echo "$OUT5" | sed 's/^/    /'
fi

inc
if echo "$OUT5" | grep -Eq "DRY RUN: would create tag checkpoint/${DATE}-[0-9]{2}"; then
  pass_msg "PIPELINE_PROJECT_ROOT dry-run output has expected shape"
else
  fail_msg "PIPELINE_PROJECT_ROOT dry-run output missing 'DRY RUN: would create tag checkpoint/${DATE}-NN'; output was:"
  echo "$OUT5" | sed 's/^/    /'
fi

inc
# The resolved project's base branch is 'proj2-base'. The annotation body
# must reflect that, proving the script switched to proj2's git repo and not
# proj's 'pipeline' branch.
if echo "$OUT5" | grep -q "Base branch: proj2-base"; then
  pass_msg "PIPELINE_PROJECT_ROOT resolved repo is proj2 (annotation lists proj2-base)"
else
  fail_msg "PIPELINE_PROJECT_ROOT did not resolve to proj2; output was:"
  echo "$OUT5" | sed 's/^/    /'
fi

inc
# proj2 must have created no tag (dry run); also proj must have no new tag
# from this invocation. We assert specifically on proj2 since that's the
# resolved root.
if ! (cd "$PROJ2" && git tag --list "checkpoint/${DATE}-*" | grep -q .); then
  pass_msg "PIPELINE_PROJECT_ROOT dry-run did not create a tag in proj2"
else
  fail_msg "PIPELINE_PROJECT_ROOT dry-run unexpectedly created a tag in proj2"
fi

# --- Test 6: stray pipeline.config without a sibling .git/ is rejected ---
echo "Test 6: walk rejects a pipeline.config sitting next to no .git/ entry"

# Isolate from $WORKDIR so no ancestor of the stray dir has its own pipeline.config.
STRAY_PARENT=$(mktemp -d)
mkdir -p "$STRAY_PARENT/stray/inner"
cat > "$STRAY_PARENT/stray/pipeline.config" <<EOF
PIPELINE_REPO="stray/fake"
PIPELINE_BASE_BRANCH="never-resolved"
EOF
cp "$SCRIPT_UNDER_TEST" "$STRAY_PARENT/stray/inner/script.sh"
chmod +x "$STRAY_PARENT/stray/inner/script.sh"

set +e
OUT6=$(env -u PIPELINE_PROJECT_ROOT bash "$STRAY_PARENT/stray/inner/script.sh" --issues "1" --prs "2" --dry-run 2>&1)
RC6=$?
set -e

rm -rf "$STRAY_PARENT"

inc
if [ "$RC6" -ne 0 ]; then
  pass_msg "stray pipeline.config (no sibling .git/) rejected with non-zero exit (rc=$RC6)"
else
  fail_msg "stray pipeline.config was accepted (expected non-zero exit); output was:"
  echo "$OUT6" | sed 's/^/    /'
fi

inc
if echo "$OUT6" | grep -q "could not locate consumer repo"; then
  pass_msg "error message names the missing consumer repo"
else
  fail_msg "expected stderr to contain 'could not locate consumer repo'; output was:"
  echo "$OUT6" | sed 's/^/    /'
fi

# --- Summary ---
echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
