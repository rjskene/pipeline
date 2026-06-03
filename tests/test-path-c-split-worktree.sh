#!/bin/bash
set -euo pipefail

# Contract test for scripts/path-c-split-worktree.sh — the per-leaf-worktree
# fan-out helper for PATH C inline execution (#896). Each `target=<dir>` leaf
# gets its OWN worktree+branch so concurrent leaves never share a git index
# (the #894 c+d collision); the orchestrator then cherry-picks each leaf's
# commits back onto the feature branch (disjoint targets -> conflict-free),
# preserving per-target commit isolation.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/path-c-split-worktree.sh"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

if [ ! -f "$HELPER" ]; then
  echo "ERROR: helper missing at $HELPER" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# --- build a parent repo on branch feature/parent with one base commit ---
REPO="$WORKDIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
git -C "$REPO" checkout -q -b feature/parent
echo base > "$REPO/base.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "base"

echo "Step 1: setup creates an isolated leaf worktree + branch off parent HEAD"
inc
LEAF_A=$(bash "$HELPER" setup "$REPO" "dev/probe/a/")
if [ -d "$LEAF_A" ] && git -C "$REPO" rev-parse --verify -q "feature/parent--leaf-dev-probe-a" >/dev/null; then
  pass_msg "leaf-a worktree ($LEAF_A) + branch created"
else
  fail_msg "leaf-a worktree/branch not created (got path: $LEAF_A)"
fi

inc
LEAF_B=$(bash "$HELPER" setup "$REPO" "dev/probe/b/")
if [ -d "$LEAF_B" ] && [ "$LEAF_B" != "$LEAF_A" ]; then
  pass_msg "leaf-b worktree is distinct from leaf-a"
else
  fail_msg "leaf-b worktree not distinct (a=$LEAF_A b=$LEAF_B)"
fi

# --- each leaf commits into its OWN index (no collision possible) ---
mkdir -p "$LEAF_A/dev/probe/a"; echo a > "$LEAF_A/dev/probe/a/x"
git -C "$LEAF_A" add -A && git -C "$LEAF_A" commit -qm "leaf a"
mkdir -p "$LEAF_B/dev/probe/b"; echo b > "$LEAF_B/dev/probe/b/y"
git -C "$LEAF_B" add -A && git -C "$LEAF_B" commit -qm "leaf b"

echo "Step 2: reassemble cherry-picks each leaf commit onto the feature branch"
inc
if bash "$HELPER" reassemble "$REPO" "dev/probe/a/" "dev/probe/b/" >/dev/null 2>&1; then
  pass_msg "reassemble exited 0"
else
  fail_msg "reassemble failed"
fi

inc
if [ -f "$REPO/dev/probe/a/x" ] && [ -f "$REPO/dev/probe/b/y" ]; then
  pass_msg "both leaves' files present on feature branch"
else
  fail_msg "leaf files missing after reassemble"
fi

echo "Step 3: per-target commit isolation preserved (2 distinct commits, not folded)"
inc
# Count commits added on top of the root (base) commit. Two leaves cherry-picked
# as TWO distinct commits => 2. A fold (the #894 bug) would yield 1.
ROOT=$(git -C "$REPO" rev-list --max-parents=0 HEAD)
NEW_COMMITS=$(git -C "$REPO" rev-list --count HEAD ^"$ROOT")
if [ "$NEW_COMMITS" = "2" ]; then
  pass_msg "2 isolated leaf commits on the feature branch — no fold"
else
  fail_msg "expected 2 isolated leaf commits, got $NEW_COMMITS"
fi

echo "Step 4: teardown removes leaf worktrees + branches"
inc
bash "$HELPER" teardown "$REPO" "dev/probe/a/" "dev/probe/b/" >/dev/null 2>&1 || true
if [ ! -d "$LEAF_A" ] && [ ! -d "$LEAF_B" ] \
   && ! git -C "$REPO" rev-parse --verify -q "feature/parent--leaf-dev-probe-a" >/dev/null \
   && ! git -C "$REPO" rev-parse --verify -q "feature/parent--leaf-dev-probe-b" >/dev/null; then
  pass_msg "leaf worktrees + branches removed"
else
  fail_msg "teardown left residue"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
