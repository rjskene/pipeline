#!/usr/bin/env bash
# Tests for check-post-plan-freshness.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/check-post-plan-freshness.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# --- throwaway repo ---
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

git -C "$TMP" init -q
git -C "$TMP" config user.email "test@example.com"
git -C "$TMP" config user.name "Test"
git -C "$TMP" config commit.gpgsign false

commit() {
  # commit <n> on current branch
  echo "$1" > "$TMP/file-$1.txt"
  git -C "$TMP" add -A
  git -C "$TMP" commit -q -m "commit $1"
}

# base branch with one commit
commit 0
git -C "$TMP" branch -M base

run() {
  # run from inside the throwaway repo so git resolves local refs
  ( cd "$TMP" && "$@" )
}

# === Case 1: FRESH within thresholds (drift 0, no plan-epoch) ===
BASE_TIP="$(git -C "$TMP" rev-parse base)"
out="$(run "$SCRIPT" --base base --worktree-base "$BASE_TIP" 2>&1)"; rc=$?
if [[ $rc -eq 0 && "$out" == FRESH:* ]]; then
  pass "case1 FRESH within thresholds (rc=0, FRESH:)"
else
  fail "case1 FRESH within thresholds (rc=$rc, out=$out)"
fi

# capture a worktree-base sha BEFORE adding drift commits
DRIFT_BASE="$(git -C "$TMP" rev-parse base)"

# === Case 4 prep: add exactly 40 commits, expect FRESH (boundary) ===
for i in $(seq 1 40); do commit "b$i"; done
out="$(run "$SCRIPT" --base base --worktree-base "$DRIFT_BASE" 2>&1)"; rc=$?
if [[ $rc -eq 0 && "$out" == FRESH:* ]]; then
  pass "case4 FRESH at exact drift==40 boundary (rc=0)"
else
  fail "case4 FRESH at exact drift==40 boundary (rc=$rc, out=$out)"
fi

# === Case 2: STALE on commit drift (one more → 41) ===
commit "b41"
out="$(run "$SCRIPT" --base base --worktree-base "$DRIFT_BASE" 2>&1)"; rc=$?
if [[ $rc -eq 3 && "$out" == STALE:* && "$out" == *41* ]]; then
  pass "case2 STALE on commit drift==41 (rc=3, STALE:, names 41)"
else
  fail "case2 STALE on commit drift==41 (rc=$rc, out=$out)"
fi

# === Case 6: remediation block contains 'rebase origin/' ===
if [[ "$out" == *"rebase origin/"* ]]; then
  pass "case6 remediation contains 'rebase origin/'"
else
  fail "case6 remediation contains 'rebase origin/' (out=$out)"
fi

# === Case 3: STALE on plan age (drift 0, plan 20 days ago) ===
NOW=1700000000
TWENTY_DAYS_AGO=$((NOW - 20 * 86400))
FRESH_TIP="$(git -C "$TMP" rev-parse base)"
out="$(run env PIPELINE_NOW_EPOCH="$NOW" "$SCRIPT" --base base --worktree-base "$FRESH_TIP" --plan-epoch "$TWENTY_DAYS_AGO" 2>&1)"; rc=$?
if [[ $rc -eq 3 && "$out" == STALE:* && "$out" == *20* ]]; then
  pass "case3 STALE on plan age==20d (rc=3, STALE:, names 20)"
else
  fail "case3 STALE on plan age==20d (rc=$rc, out=$out)"
fi

# === Case 5: bad args (missing --base) → exit 2, USAGE/ERROR on stderr ===
err="$(run "$SCRIPT" --worktree-base "$FRESH_TIP" 2>&1 1>/dev/null)"; rc=$?
if [[ $rc -eq 2 && ( "$err" == USAGE:* || "$err" == ERROR:* ) ]]; then
  pass "case5 missing --base → exit 2 with USAGE/ERROR"
else
  fail "case5 missing --base → exit 2 (rc=$rc, err=$err)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
