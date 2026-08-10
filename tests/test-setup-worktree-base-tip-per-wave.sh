#!/bin/bash
set -euo pipefail

# Topology regression guard for setup-worktree.sh's branch-point semantics in
# the multi-wave fullsend loop (#626, retargeted by #1214).
#
# TWO mechanisms, pinned separately:
#
#   NO `--base` (the DEFAULT, unchanged): the worktree is cut from MAIN_REPO's
#     LOCAL HEAD, so a wave only inherits earlier merged work if the caller first
#     advanced that local tip (historically an inter-wave `git pull` — the #626
#     contract). Assertions A and B pin this default path and are byte-unchanged.
#
#   EXPLICIT `--base <branch>` (the #1214 mechanism): an explicit `--base` is an
#     ACTUATING declaration — setup-worktree.sh fetches and cuts the worktree from
#     `origin/<base>`'s tip. The caller therefore never checks out or pulls the
#     operator's PRIMARY checkout, which is what the campaign/wave loop used to do
#     (stranding operator work, and non-atomic across the checkout+pull pair).
#
#   Assertion A: no `--base`, WITHOUT an intervening pull → the next worktree's
#                HEAD does NOT contain the remote commit (documents the LOCAL-HEAD
#                default). Expected to PASS against the CURRENT setup-worktree.sh.
#   Assertion C: fetch-ONLY (no checkout, no pull) + explicit `--base <current
#                branch>` → the next worktree's HEAD DOES contain the remote
#                commit. MUST run BEFORE Assertion B: B's `git pull` advances the
#                LOCAL base, after which C would be VACUOUSLY green.
#   Assertion D: that same `--base` call leaves the primary checkout's HEAD ref
#                and local base SHA byte-identical (never mutate the operator's
#                checkout). Regression guard.
#   Assertion B: no `--base`, WITH the legacy inter-wave pull → the next
#                worktree's HEAD DOES contain the remote commit. Proves the PULL —
#                not setup-worktree alone — advances the LOCAL-HEAD default tip.
#   Assertion E: explicit `--base <current branch>` when `origin/<base>` does NOT
#                exist anywhere → setup still succeeds and mutates NO local ref.
#                Regression guard against a NAIVE `--base` actuation that would
#                `git branch -f` (or push) the branch it is standing on.
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

# --- Assertion C: fetch-ONLY + an explicit --base cuts wave 4 from the origin tip ---
# Placement is load-bearing: this MUST come BEFORE Assertion B. B's
# `git pull --ff-only` advances the LOCAL $BASE, after which this assertion goes
# vacuously green even on pristine setup-worktree.sh. The whole point of the
# #1214 mechanism is that NO checkout and NO pull ever run against $PROJ.
#
# Snapshot the primary checkout state first — Assertion D compares it after.
HEAD_REF_BEFORE=$(git -C "$PROJ" symbolic-ref --short HEAD)
LOCAL_BASE_BEFORE=$(git -C "$PROJ" rev-parse "$BASE")

echo "Assertion C: fetch-only + explicit --base → wave 4 HEAD contains remote commit"
inc
git -C "$PROJ" fetch --quiet origin "$BASE"
run_setup --base "$BASE" feature/wave4 4 >"$WORKDIR/w4.log" 2>&1 || {
  echo "FATAL: wave4 setup failed"; sed 's/^/    /' "$WORKDIR/w4.log"; exit 1
}
W4="$PROJ/.claude/worktrees/ct-4-wave4"
if git -C "$W4" merge-base --is-ancestor "$REMOTE_COMMIT" HEAD 2>/dev/null; then
  pass_msg "Assertion C: explicit --base cut wave 4 from origin/$BASE's tip (no checkout, no pull)"
else
  fail_msg "Assertion C: wave 4 HEAD missing remote commit — an explicit --base did not actuate a fetch+cut from origin/$BASE"
fi

# --- Assertion D: that --base call left the PRIMARY checkout untouched ---
echo "Assertion D: fetch-only + --base leaves the primary checkout HEAD and local base ref untouched"
inc
HEAD_REF_AFTER=$(git -C "$PROJ" symbolic-ref --short HEAD)
LOCAL_BASE_AFTER=$(git -C "$PROJ" rev-parse "$BASE")
if [ "$HEAD_REF_AFTER" != "$HEAD_REF_BEFORE" ]; then
  fail_msg "Assertion D: primary checkout HEAD moved ($HEAD_REF_BEFORE -> $HEAD_REF_AFTER)"
elif [ "$LOCAL_BASE_AFTER" != "$LOCAL_BASE_BEFORE" ]; then
  fail_msg "Assertion D: local '$BASE' ref was moved ($LOCAL_BASE_BEFORE -> $LOCAL_BASE_AFTER)"
else
  pass_msg "Assertion D: primary checkout HEAD ($HEAD_REF_AFTER) and local '$BASE' ref both unchanged"
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

# --- Assertion E: explicit --base with origin/<base> ABSENT mutates no local ref ---
# Second, independent fixture: local $BASE exists and is CHECKED OUT, but was
# never pushed, so `origin/$BASE` resolves nowhere. A naive `--base` actuation
# (dropping only the "!= current branch" conjunct) takes the origin-absent branch
# and runs `git branch -f "$BASE" origin/$PIPELINE_BASE_BRANCH` + `push -u` — both
# illegal here (rc=128: cannot force-update the checked-out branch / no remote
# ref). The contract: succeed, create the worktree, move NOTHING.
echo "Assertion E: explicit --base with origin/$BASE absent → setup succeeds, no local ref mutated"
inc
PROJ2="$WORKDIR/proj2"
mkdir -p "$PROJ2/.claude/scripts"
git init --bare -q "$WORKDIR/origin2.git"
git -c init.defaultBranch=main init -q "$PROJ2"
git -C "$PROJ2" remote add origin "$WORKDIR/origin2.git"
git -C "$PROJ2" config user.email "tester@example.com"
git -C "$PROJ2" config user.name "tester"
echo "seed2" > "$PROJ2/seed.txt"
git -C "$PROJ2" add seed.txt
git -C "$PROJ2" commit -q -m "seed"
git -C "$PROJ2" push -q origin main
# $BASE is created LOCALLY and checked out, and deliberately NEVER pushed.
git -C "$PROJ2" checkout -q -b "$BASE"
cp "$PROJ/pipeline.config" "$PROJ2/pipeline.config"
cp "$TEMPLATE" "$PROJ2/.claude/scripts/setup-worktree.sh"
chmod +x "$PROJ2/.claude/scripts/setup-worktree.sh"

BASE2_BEFORE=$(git -C "$PROJ2" rev-parse "$BASE")
HEAD2_BEFORE=$(git -C "$PROJ2" symbolic-ref --short HEAD)
set +e
( cd "$PROJ2" && bash .claude/scripts/setup-worktree.sh --base "$BASE" feature/wave5 5 ) >"$WORKDIR/w5.log" 2>&1
RC5=$?
set -e
W5="$PROJ2/.claude/worktrees/ct-5-wave5"
BASE2_AFTER=$(git -C "$PROJ2" rev-parse "$BASE")
HEAD2_AFTER=$(git -C "$PROJ2" symbolic-ref --short HEAD)
if [ "$RC5" -ne 0 ]; then
  fail_msg "Assertion E: setup-worktree.sh exited $RC5 with origin/$BASE absent (log below)"
  sed 's/^/    /' "$WORKDIR/w5.log"
elif [ ! -d "$W5" ]; then
  fail_msg "Assertion E: worktree $W5 was not created"
elif [ "$BASE2_AFTER" != "$BASE2_BEFORE" ]; then
  fail_msg "Assertion E: local '$BASE' ref was force-moved ($BASE2_BEFORE -> $BASE2_AFTER)"
elif [ "$HEAD2_AFTER" != "$HEAD2_BEFORE" ]; then
  fail_msg "Assertion E: primary checkout HEAD moved ($HEAD2_BEFORE -> $HEAD2_AFTER)"
else
  pass_msg "Assertion E: origin/$BASE absent → worktree created, no local ref mutated"
fi

echo ""
echo "================================"
echo "  $TESTS assertions: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
