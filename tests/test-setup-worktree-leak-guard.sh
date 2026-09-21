#!/bin/bash
set -uo pipefail

# Regression guard for issue #1316 — setup-worktree fixture tests must never
# leak REAL worktrees/branches into whatever repo an exported
# PIPELINE_PROJECT_ROOT names, and scripts/run-test-suite.sh must red a run
# that leaks one.
#
# #1316's failure class: `scripts/setup-worktree.sh` honours
# PIPELINE_PROJECT_ROOT over cwd (line 6 sources
# `${PIPELINE_PROJECT_ROOT:-$(pwd)}/pipeline.config`, line 66 sets
# `MAIN_REPO="${PIPELINE_PROJECT_ROOT:-$(pwd)}"`). The fixture tests invoke the
# copied script as `( cd "$PROJ" && bash .claude/scripts/setup-worktree.sh … )`
# without pinning that variable, so a suite run from a session that exports the
# LIVE root (linked worktrees copy pipeline.config; agents source it under
# `set -a`) sources the LIVE config and cuts `wt-100-bar` / `wt-101-baz` /
# `wt-102-qux` … in the LIVE repo. Twice (cycles 5 and 6) that left nine real
# worktrees + branches behind and cost every later GREEN/evaluator ~20 tool uses
# proving "pre-existing" worktree-name collisions.
#
# Contracts pinned here (one throwaway `mktemp -d` git repo per case — NEVER
# the live checkout, and PIPELINE_PROJECT_ROOT is NEVER pointed at $ROOT):
#   A. Foreign-root isolation: running the named producer
#      (tests/test-setup-worktree-base-defaulting.sh) with PIPELINE_PROJECT_ROOT
#      exported to a foreign repo exits 0 AND leaves that repo's
#      `git worktree list` / `git branch --list` byte-identical.
#   B. Guard fires: scripts/run-test-suite.sh, pointed at a foreign repo via
#      PIPELINE_TEST_LEAK_GUARD_REPO, reds a run (exit 1) whose only stub —
#      itself exiting 0 — adds a worktree+branch there, printing exactly one
#      `LEAK: worktree=<path> branch=<name>` line on stdout (the branch is
#      consumed by its worktree line, never reported twice).
#   C. Clean control: the same runner on a clean stub exits 0 and prints no
#      `LEAK:` line — the guard is a before/after DIFF, not a listing, so the
#      foreign repo's pre-existing main worktree + `main` branch are not flagged.
#
# Mirrors the ROOT / pass_msg / fail_msg / inc / `exit 1` shape of
# tests/test-run-test-suite-chunked.sh; the foreign pipeline.config is the
# fixture block from tests/test-setup-worktree-base-defaulting.sh with
# PIPELINE_WORKTREE_PREFIX="wt" and PIPELINE_BASE_BRANCH="main" (the config
# MUST exist — without it setup-worktree.sh:6 aborts before touching the repo
# and Case A would go vacuously green).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/scripts/run-test-suite.sh"
PRODUCER="$ROOT/tests/test-setup-worktree-base-defaulting.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$RUNNER" ]; then
  echo "FAIL: scripts/run-test-suite.sh not found under $ROOT" >&2
  exit 1
fi
if [ ! -f "$PRODUCER" ]; then
  echo "FAIL: tests/test-setup-worktree-base-defaulting.sh not found under $ROOT" >&2
  exit 1
fi

# Physical path so the `worktree <path>` porcelain line (which git records
# absolute and resolved) compares byte-for-byte against our own strings.
WORK_ROOT="$(mktemp -d)"
WORK_ROOT="$(cd "$WORK_ROOT" && pwd -P)"
trap 'rm -rf "$WORK_ROOT"' EXIT

# Build a throwaway "foreign" git repo: one seed commit on main, tester
# identity, and a pipeline.config so setup-worktree.sh gets past its source
# line and actually acts on the repo. No `origin` on purpose — a leak lands
# BEFORE the step-6 push, so the worktree is cut even though the script then
# aborts.
mk_foreign() {
  local dir="$1"
  mkdir -p "$dir"
  git -c init.defaultBranch=main init -q "$dir"
  git -C "$dir" config user.email "tester@example.com"
  git -C "$dir" config user.name "tester"
  echo "seed" > "$dir/seed.txt"
  git -C "$dir" add seed.txt
  git -C "$dir" commit -q -m "seed"
  cat > "$dir/pipeline.config" <<'EOF'
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="main"
PIPELINE_WORKTREE_PREFIX="wt"
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

# Sorted union of a repo's worktree paths and local branch names — the exact
# two surfaces the #1316 leak lands on.
snapshot() {
  local repo="$1"
  {
    git -C "$repo" worktree list --porcelain | grep '^worktree ' || true
    git -C "$repo" branch --list --format='%(refname:short)'
  } | sort
}

# ---------------------------------------------------------------------------
# Case A — foreign PIPELINE_PROJECT_ROOT export leaves the foreign repo untouched.
# Runs the WHOLE named producer as a child (per the issue), not a hand-rolled
# setup-worktree.sh call: this proves the file's fixture invocations pin their
# own root end-to-end, and its no-`--base` cases are exactly the ones that
# leaked (`wt-100-bar`, `wt-101-baz`, `wt-102-qux`).
# ---------------------------------------------------------------------------

echo "Case A: producer run with a foreign PIPELINE_PROJECT_ROOT exported"
FOREIGN="$WORK_ROOT/foreign"
mk_foreign "$FOREIGN"
snapshot "$FOREIGN" > "$WORK_ROOT/a-before.txt"

rc_a=0
PIPELINE_PROJECT_ROOT="$FOREIGN" bash "$PRODUCER" \
  > "$WORK_ROOT/producer.log" 2>&1 </dev/null || rc_a=$?

snapshot "$FOREIGN" > "$WORK_ROOT/a-after.txt"
comm -13 "$WORK_ROOT/a-before.txt" "$WORK_ROOT/a-after.txt" > "$WORK_ROOT/a-new.txt"

inc
if [ "$rc_a" -eq 0 ]; then
  pass_msg "Case A: producer exits 0 with a foreign PIPELINE_PROJECT_ROOT exported"
else
  fail_msg "Case A: producer exited $rc_a with a foreign PIPELINE_PROJECT_ROOT exported (its setup-worktree.sh invocations do not pin the fixture root); producer log tail:"
  tail -n 20 "$WORK_ROOT/producer.log" | sed 's/^/    /'
fi

inc
if [ ! -s "$WORK_ROOT/a-new.txt" ]; then
  pass_msg "Case A: foreign repo worktree/branch snapshot is unchanged after the producer run"
else
  fail_msg "Case A: foreign repo gained $(wc -l < "$WORK_ROOT/a-new.txt" | tr -d '[:space:]') worktree/branch entr(y|ies) — the producer cut its fixture worktrees in the EXPORTED root:"
  sed 's/^/    /' "$WORK_ROOT/a-new.txt"
fi

# ---------------------------------------------------------------------------
# Case B — the post-suite guard fires on a deliberate leak.
# The stub exits 0 itself, so ONLY the leak guard can red the run.
# ---------------------------------------------------------------------------

echo "Case B: run-test-suite.sh reds a run whose stub leaks a worktree+branch"
FOREIGN2="$WORK_ROOT/foreign2"
mk_foreign "$FOREIGN2"
STUBS_LEAK="$WORK_ROOT/stubs-leak"
mkdir -p "$STUBS_LEAK"
printf '#!/bin/bash\ngit -C "%s" worktree add "%s/.claude/worktrees/wt-9-leak" -b feature/leak >/dev/null 2>&1\nexit 0\n' \
  "$FOREIGN2" "$FOREIGN2" > "$STUBS_LEAK/test-leak.sh"
chmod +x "$STUBS_LEAK/test-leak.sh"

rc_b=0
PIPELINE_TEST_LEAK_GUARD_REPO="$FOREIGN2" PIPELINE_TEST_PARALLELISM=1 \
  bash "$RUNNER" "$STUBS_LEAK" > "$WORK_ROOT/b.out" 2> "$WORK_ROOT/b.err" </dev/null || rc_b=$?

EXPECT_B="LEAK: worktree=$FOREIGN2/.claude/worktrees/wt-9-leak branch=feature/leak"
leak_count_b="$(grep -c '^LEAK: ' "$WORK_ROOT/b.out" || true)"

# Fixture precondition: the stub really did land the worktree in the foreign
# repo. If it did not, every Case B assertion below would be testing nothing.
if ! git -C "$FOREIGN2" worktree list --porcelain \
     | grep -Fxq "worktree $FOREIGN2/.claude/worktrees/wt-9-leak"; then
  echo "  FIXTURE ERROR: the leak stub did not create $FOREIGN2/.claude/worktrees/wt-9-leak — Case B cannot be evaluated" >&2
  git -C "$FOREIGN2" worktree list --porcelain | sed 's/^/    /' >&2
  FAIL=$((FAIL + 3)); TESTS=$((TESTS + 3))
else
  inc
  if [ "$rc_b" -eq 1 ]; then
    pass_msg "Case B: runner exits 1 when a (self-passing) stub leaks a worktree into the guard repo"
  else
    fail_msg "Case B: runner exited $rc_b (want 1) — a leaked worktree+branch did not red the run"
  fi

  inc
  if grep -Fxq "$EXPECT_B" "$WORK_ROOT/b.out"; then
    pass_msg "Case B: stdout carries the exact line '$EXPECT_B'"
  else
    fail_msg "Case B: stdout lacks the exact line '$EXPECT_B'; runner stdout tail / stderr tail:"
    tail -n 10 "$WORK_ROOT/b.out" | sed 's/^/    out: /'
    tail -n 10 "$WORK_ROOT/b.err" | sed 's/^/    err: /'
  fi

  inc
  if [ "$leak_count_b" -eq 1 ]; then
    pass_msg "Case B: exactly one LEAK: line (the new branch is consumed by its worktree line, not reported twice)"
  else
    fail_msg "Case B: $leak_count_b LEAK: line(s) on stdout (want exactly 1):"
    grep '^LEAK: ' "$WORK_ROOT/b.out" | sed 's/^/    /'
  fi
fi

# ---------------------------------------------------------------------------
# Case C — clean run emits nothing (control). Pins that the guard diffs
# before/after rather than listing: the foreign repo's pre-existing main
# worktree and `main` branch must not be flagged.
# ---------------------------------------------------------------------------

echo "Case C: run-test-suite.sh on a clean stub exits 0 with no LEAK: line"
FOREIGN3="$WORK_ROOT/foreign3"
mk_foreign "$FOREIGN3"
STUBS_CLEAN="$WORK_ROOT/stubs-clean"
mkdir -p "$STUBS_CLEAN"
printf '#!/bin/bash\necho "RANFILE:ok"\nexit 0\n' > "$STUBS_CLEAN/test-clean.sh"
chmod +x "$STUBS_CLEAN/test-clean.sh"

rc_c=0
PIPELINE_TEST_LEAK_GUARD_REPO="$FOREIGN3" PIPELINE_TEST_PARALLELISM=1 \
  bash "$RUNNER" "$STUBS_CLEAN" > "$WORK_ROOT/c.out" 2> "$WORK_ROOT/c.err" </dev/null || rc_c=$?

leak_count_c="$(cat "$WORK_ROOT/c.out" "$WORK_ROOT/c.err" | grep -c '^LEAK: ' || true)"

inc
if [ "$rc_c" -eq 0 ] \
   && grep -Fq 'RANFILE:ok' "$WORK_ROOT/c.out" \
   && [ "$leak_count_c" -eq 0 ]; then
  pass_msg "Case C: clean stub run exits 0, ran the stub, and printed zero LEAK: lines"
else
  fail_msg "Case C: clean stub run exited $rc_c (want 0) / stub marker $(grep -Fq 'RANFILE:ok' "$WORK_ROOT/c.out" && echo present || echo MISSING) / $leak_count_c LEAK: line(s) (want 0):"
  cat "$WORK_ROOT/c.out" "$WORK_ROOT/c.err" | grep '^LEAK: ' | sed 's/^/    /'
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
