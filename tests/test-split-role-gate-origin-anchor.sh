#!/usr/bin/env bash
# Regression test for issue #1237: split-role-gate must resolve the RED
# anchor against origin/<base>, not a stale local base ref.
#
# The pipeline's inter-wave/inter-leg base advance is deliberately fetch-only
# (#1214) — it moves refs/remotes/origin/<base> but never the local
# refs/heads/<base>. On every wave after the first, the local base ref goes
# stale while origin/<base> carries the just-merged work. When the gate
# defaults its scan window to the (stale) local base ref, an earlier wave's
# already-merged [split-role-red] marker commit gets swept into the window,
# mis-anchoring RED_SHA and causing that wave's own (already-merged) commit
# history to be evaluated against THIS PR's invariant — a false
# locked-test-modified block.
#
# Same root-cause class as #1231/#1234 (scripts/check-branch-cruft.sh); this
# test mirrors the simulate_remote_base_advance fixture pattern from
# tests/test-check-branch-cruft.sh case (g).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE="$REPO_ROOT/scripts/split-role-gate.sh"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

if [ ! -f "$GATE" ]; then
  echo "ERROR: gate script missing at $GATE" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

ISSUE=1237
BASE=base

# new_repo_with_remote — a repo wired to a bare "origin" remote, with `base`
# pushed (one commit adding a locked test file). Prints the repo path.
new_repo_with_remote() {
  local remote="$WORKDIR/remote.git"
  local repo="$WORKDIR/repo"
  git init -q --bare "$remote"
  mkdir -p "$repo/tests"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t.t
  git -C "$repo" config user.name t
  git -C "$repo" checkout -q -b "$BASE"
  echo base > "$repo/base.txt"
  echo "echo locked-v1" > "$repo/tests/test-locked.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "base"
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push -q origin "$BASE"
  echo "$repo"
}

# simulate_remote_base_advance <repo> — simulate a prior wave's split-role PR
# merging straight into origin's base branch (via a throwaway second clone),
# WITHOUT touching $1's local refs/heads/base. Adds a [split-role-red] marker
# commit (adds tests/test-wave1.sh), then a non-marker commit that MODIFIES
# it (removed>0, tamper-shaped from THIS window's perspective — but fully
# absorbed into origin/base's history since it's already merged).
simulate_remote_base_advance() {
  local repo="$1"
  local remote clone
  remote="$(git -C "$repo" remote get-url origin)"
  clone="$WORKDIR/clone"
  git clone -q "$remote" "$clone"
  git -C "$clone" config user.email t@t.t
  git -C "$clone" config user.name t
  git -C "$clone" checkout -q "$BASE"
  echo "echo wave1-suite" > "$clone/tests/test-wave1.sh"
  git -C "$clone" add -A
  git -C "$clone" commit -qm "test(x): wave1 red suite [split-role-red] (#1224)"
  echo "echo wave1-suite-tampered" > "$clone/tests/test-wave1.sh"
  git -C "$clone" add -A
  git -C "$clone" commit -qm "feat(x): wave1 impl (#1224)"
  git -C "$clone" push -q origin "$BASE"
}

REPO="$(new_repo_with_remote)"
simulate_remote_base_advance "$REPO"

# Feature branch checked out from origin/base (post wave-1 merge), NOT from
# the stale local base — mirrors how a real worktree spawns after the
# fetch-only inter-wave base advance (#1214).
git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -b "feature/issue-$ISSUE" "origin/$BASE"

# This PR's OWN red anchor + a clean green impl that touches no test file.
echo "echo red-suite-1237" > "$REPO/tests/test-1237.sh"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "test(x): add failing suite [split-role-red] (#$ISSUE)"
echo "impl" > "$REPO/src.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "feat(x): green impl (#$ISSUE)"

# Sanity: local refs/heads/base is STALE — it never advanced past the
# original single-commit push, so it still predates wave-1's merge.
LOCAL_BASE_SHA="$(git -C "$REPO" rev-parse "$BASE")"
ORIGIN_BASE_SHA="$(git -C "$REPO" rev-parse "origin/$BASE")"
inc
if [ "$LOCAL_BASE_SHA" != "$ORIGIN_BASE_SHA" ]; then
  pass_msg "fixture sanity: local base ref is stale relative to origin/base"
else
  fail_msg "fixture sanity: local base and origin/base unexpectedly match; fixture does not exercise the bug"
fi

# Invoke the gate exactly like the real call site (skills/evaluate-issue-pr):
# no explicit <base-ref> positional arg — resolution comes entirely from
# $PIPELINE_BASE_BRANCH.
inc
OUT=$( cd "$REPO" && PIPELINE_BASE_BRANCH="$BASE" PIPELINE_TEST_CMD="true" \
       bash "$GATE" "$ISSUE" 2>/dev/null )
CODE=$?
EXPECTED="SPLIT_ROLE=pass ISSUE=$ISSUE REASON=additive-ok"
if [ "$CODE" -eq 0 ] && [ "$OUT" = "$EXPECTED" ]; then
  pass_msg "origin/base anchor resolved: '$EXPECTED' (wave-1 history correctly invisible)"
else
  fail_msg "expected exit 0 + '$EXPECTED', got exit $CODE + '$OUT'"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
