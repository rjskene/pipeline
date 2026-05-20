#!/bin/bash
set -euo pipefail

# Tests for prune-checkpoints.sh:
#   - deletes checkpoint/* tags older than the cutoff
#   - keeps checkpoint/* tags newer than the cutoff
#   - never touches non-checkpoint tags (e.g., v1.2.3)
#   - --dry-run reports but does not delete

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/../scripts/prune-checkpoints.sh"

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

# --- Setup throwaway repo ---
PROJ=$(mktemp -d)
trap 'rm -rf "$PROJ"' EXIT

mkdir -p "$PROJ/scripts"
cp "$SCRIPT_UNDER_TEST" "$PROJ/scripts/prune-checkpoints.sh"
chmod +x "$PROJ/scripts/prune-checkpoints.sh"

cat > "$PROJ/pipeline.config" <<EOF
PIPELINE_BASE_BRANCH="pipeline"
EOF

cd "$PROJ"
git init -q -b pipeline
git config user.email "t@t"
git config user.name "t"
echo "a" > f
git add f
git commit -qm "init"

# --- Seed tags with backdated tagger dates ---
OLD_DATE=$(date -d '-10 days' '+%Y-%m-%dT%H:%M:%S +0000')
RECENT_DATE=$(date -d '-3 days' '+%Y-%m-%dT%H:%M:%S +0000')

GIT_COMMITTER_DATE="$OLD_DATE" git tag -a -m "old" checkpoint/2000-01-01-01
GIT_COMMITTER_DATE="$RECENT_DATE" git tag -a -m "recent" checkpoint/2000-01-02-01
git tag -a -m "release" v1.2.3

# --- Test 1: prune tags older than 7d ---
echo "Test 1: --older-than 7d deletes old tags, keeps recent + semver"
bash scripts/prune-checkpoints.sh --older-than 7d >/dev/null

inc
if git rev-parse --verify checkpoint/2000-01-01-01 >/dev/null 2>&1; then
  fail_msg "old tag checkpoint/2000-01-01-01 should have been deleted"
else
  pass_msg "old tag deleted"
fi

inc
if git rev-parse --verify checkpoint/2000-01-02-01 >/dev/null 2>&1; then
  pass_msg "recent tag kept"
else
  fail_msg "recent tag was deleted (should have been kept)"
fi

inc
if git rev-parse --verify v1.2.3 >/dev/null 2>&1; then
  pass_msg "semver tag v1.2.3 untouched"
else
  fail_msg "semver tag v1.2.3 was deleted (should have been kept)"
fi

# --- Test 2: --dry-run prints but does not delete ---
echo "Test 2: --dry-run prints planned deletions, deletes nothing"
OLD_DATE2=$(date -d '-20 days' '+%Y-%m-%dT%H:%M:%S +0000')
GIT_COMMITTER_DATE="$OLD_DATE2" git tag -a -m "old2" checkpoint/2000-01-03-01

OUT=$(bash scripts/prune-checkpoints.sh --older-than 7d --dry-run)

inc
if git rev-parse --verify checkpoint/2000-01-03-01 >/dev/null 2>&1; then
  pass_msg "--dry-run did not delete the old tag"
else
  fail_msg "--dry-run deleted a tag (expected no-op)"
fi

inc
if echo "$OUT" | grep -q "checkpoint/2000-01-03-01"; then
  pass_msg "--dry-run output mentions the old tag"
else
  fail_msg "--dry-run output missing old tag; output was:"
  echo "$OUT" | sed 's/^/    /'
fi

# --- Summary ---
echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
