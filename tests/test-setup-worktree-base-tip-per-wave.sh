#!/bin/bash
set -euo pipefail

# Topology regression guard for setup-worktree.sh's branch-point semantics in
# the multi-wave fullsend loop (#626).
#
# setup-worktree.sh branches a new worktree off MAIN_REPO's LOCAL HEAD, NOT
# off origin/<base>. So when wave 1's PR merges on the remote, a later wave's
# worktree only inherits that merged work if the fullsend loop runs
# `git pull --ff-only origin <base>` on MAIN_REPO BETWEEN waves. This test
# pins both halves of that contract:
#
#   Assertion A: WITHOUT an intervening pull, the next worktree's HEAD does NOT
#                contain the remote commit (documents the stale-base behavior —
#                exactly why the inter-wave pull is mandatory). Expected to PASS
#                against the CURRENT unchanged setup-worktree.sh.
#   Assertion B: WITH the inter-wave pull, the next worktree's HEAD DOES contain
#                the remote commit. Proves the PULL — not setup-worktree alone —
#                advances the tip inherited by the next wave.
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

PROJ="$WORKDIR/proj"
BASE="pipeline"

mkdir -p "$PROJ/.claude/scripts"
git init --bare -q "$WORKDIR/origin.git"
git -c init.defaultBranch=main init -q "$PROJ"
git -C "$PROJ" remote add origin "$WORKDIR/origin.git"
git -C "$PROJ" config user.email "tester@example.com"
git -C "$PROJ" config user.name "tester"
echo "seed" > "$PROJ/seed.txt"
git -C "$PROJ" add seed.txt
git -C "$PROJ" commit -q -m "seed"

# Base branch pushed to remote and checked out locally.
git -C "$PROJ" branch -q "$BASE"
git -C "$PROJ" push -q origin main "$BASE"
git -C "$PROJ" checkout -q "$BASE"

cat > "$PROJ/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="$BASE"
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

cp "$TEMPLATE" "$PROJ/.claude/scripts/setup-worktree.sh"
chmod +x "$PROJ/.claude/scripts/setup-worktree.sh"

run_setup() {
  ( cd "$PROJ" && bash .claude/scripts/setup-worktree.sh "$@" )
}

# --- Wave 1: first worktree off the (in-sync) local base tip ---
echo "Setup: wave 1 worktree"
run_setup feature/wave1 1 >"$WORKDIR/w1.log" 2>&1 || {
  echo "FATAL: wave1 setup failed"; sed 's/^/    /' "$WORKDIR/w1.log"; exit 1
}

# --- Simulate wave 1's PR merging on the REMOTE base directly ---
# Clone the bare remote elsewhere, commit, push back — so the bare base tip
# advances WITHOUT MAIN_REPO's local base branch being updated.
REMOTE_CLONE="$WORKDIR/remote-clone"
git clone -q "$WORKDIR/origin.git" "$REMOTE_CLONE"
git -C "$REMOTE_CLONE" config user.email "remote@example.com"
git -C "$REMOTE_CLONE" config user.name "remote"
git -C "$REMOTE_CLONE" checkout -q "$BASE"
echo "wave1-merged" > "$REMOTE_CLONE/wave1.txt"
git -C "$REMOTE_CLONE" add wave1.txt
git -C "$REMOTE_CLONE" commit -q -m "wave1 PR merged on remote"
git -C "$REMOTE_CLONE" push -q origin "$BASE"
REMOTE_COMMIT=$(git -C "$REMOTE_CLONE" rev-parse HEAD)

# --- Assertion A: WITHOUT a pull, wave 2's worktree is off the STALE local tip ---
echo "Assertion A: no intervening pull → wave 2 HEAD does NOT contain remote commit"
inc
run_setup feature/wave2 2 >"$WORKDIR/w2.log" 2>&1 || {
  echo "FATAL: wave2 setup failed"; sed 's/^/    /' "$WORKDIR/w2.log"; exit 1
}
W2="$PROJ/.claude/worktrees/ct-2-wave2"
if git -C "$W2" merge-base --is-ancestor "$REMOTE_COMMIT" HEAD 2>/dev/null; then
  fail_msg "Assertion A: wave 2 HEAD unexpectedly contains the remote commit (branch-point changed?)"
else
  pass_msg "Assertion A: wave 2 branched off stale local tip (remote commit absent)"
fi

# --- Assertion B: WITH the inter-wave pull, wave 3 inherits the remote commit ---
echo "Assertion B: inter-wave 'git pull --ff-only' → wave 3 HEAD contains remote commit"
inc
git -C "$PROJ" checkout -q "$BASE"
git -C "$PROJ" pull --ff-only --quiet origin "$BASE"
run_setup feature/wave3 3 >"$WORKDIR/w3.log" 2>&1 || {
  echo "FATAL: wave3 setup failed"; sed 's/^/    /' "$WORKDIR/w3.log"; exit 1
}
W3="$PROJ/.claude/worktrees/ct-3-wave3"
if git -C "$W3" merge-base --is-ancestor "$REMOTE_COMMIT" HEAD 2>/dev/null; then
  pass_msg "Assertion B: inter-wave pull advanced the tip; wave 3 inherits remote commit"
else
  fail_msg "Assertion B: wave 3 HEAD missing remote commit despite the pull"
fi

echo ""
echo "================================"
echo "  $TESTS assertions: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
