#!/bin/bash
set -euo pipefail

# Golden contract test for scripts/split-role-gate.sh — the split-role TDD
# eval-time git-invariant gate (#881, W7). The gate emits EXACTLY ONE stdout
# line `SPLIT_ROLE=<pass|block> ISSUE=<N> REASON=<token>` and ALWAYS exits 0
# (the verdict rides the token, mirroring auto-merge-gate.sh / path-b-execute-
# eligible.sh). This test pins the FROZEN CONTRACT (#881 plan Task 0 §1–§4):
#
#   block tokens  : no-red-sha, locked-test-modified, locked-test-deleted, suite-red
#   pass tokens   : additive-ok
#   precedence    : no-red-sha → locked-test-modified/deleted → suite-red → additive-ok
#   red anchor    : most-recent <base>..HEAD commit whose subject has '[split-role-red]'
#   lock invariant: git diff <red-sha>..HEAD --diff-filter=MD -- tests  is empty
#   suite check   : run PIPELINE_TEST_CMD; failure => suite-red
#
# NOTE: scripts/split-role-gate.sh is authored in a SEPARATE PATH C leaf and is
# NOT present in this leaf's worktree — so this test is RED in isolation (the
# gate is missing). That is EXPECTED; it goes green at reassembly when both
# leaves land on the feature branch. This is the authored RED artifact.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE="$REPO_ROOT/scripts/split-role-gate.sh"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

if [ ! -f "$GATE" ]; then
  echo "ERROR: gate script missing at $GATE" >&2
  echo "(expected RED in isolation — authored in the scripts/ leaf; green at reassembly)" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

ISSUE=881
BASE=base-anchor

# --- pass/fail test commands the gate consumes via PIPELINE_TEST_CMD ---
# Controllable stubs so cases (d)/(e) can force suite-green vs suite-red
# without depending on any real test runner.
PASS_CMD="true"
FAIL_CMD="false"

# build_repo <name> — fresh throwaway repo whose $BASE branch holds one base
# commit (already containing a locked test file under tests/), then a feature
# branch checked out off that base. The gate scans $BASE..HEAD, so EVERY
# subsequent commit (red, impl) must land on the feature branch — never on
# $BASE — exactly as a real feature worktree relates to PIPELINE_BASE_BRANCH.
# Echoes the repo path.
build_repo() {
  local repo="$WORKDIR/$1"
  mkdir -p "$repo/tests"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t.t
  git -C "$repo" config user.name t
  git -C "$repo" checkout -q -b "$BASE"
  echo base > "$repo/base.txt"
  echo "echo locked-v1" > "$repo/tests/test-locked.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "base"
  # Feature branch off the base tip — all later commits live above $BASE.
  git -C "$repo" checkout -q -b "feature/issue-$ISSUE"
  echo "$repo"
}

# commit_red <repo> — add the single [split-role-red] commit (the failing suite).
commit_red() {
  local repo="$1"
  echo "echo red-suite" > "$repo/tests/test-red.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "test(x): add failing suite [split-role-red] (#$ISSUE)"
}

# run_gate <repo> — invoke the gate from inside the throwaway repo (the gate's
# natural eval-time CWD is the feature worktree). Captures stdout + exit code
# into globals OUT and CODE.
run_gate() {
  local repo="$1"; shift
  set +e
  OUT=$( cd "$repo" && PIPELINE_TEST_CMD="$TEST_CMD" \
         bash "$GATE" "$ISSUE" "$BASE" tests 2>/dev/null )
  CODE=$?
  set -e
}

# assert_case <label> <expected-stdout-token-line>
assert_case() {
  local label="$1" expected="$2"
  inc
  if [ "$CODE" -ne 0 ]; then
    fail_msg "$label: expected exit 0 (verdict rides the token), got exit $CODE"
  elif [ "$OUT" != "$expected" ]; then
    fail_msg "$label: stdout mismatch"
    echo "         expected: [$expected]"
    echo "         actual:   [$OUT]"
  else
    pass_msg "$label: exit 0 + '$expected'"
  fi
}

# ---------------------------------------------------------------------------
echo "Case (a): no [split-role-red] commit on branch → block/no-red-sha"
REPO=$(build_repo a)
# A non-marker commit after base — still no red anchor anywhere.
echo more > "$REPO/extra.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "feat(x): unrelated work (#$ISSUE)"
TEST_CMD="$PASS_CMD"
run_gate "$REPO"
assert_case "a no-red-sha" "SPLIT_ROLE=block ISSUE=$ISSUE REASON=no-red-sha"

# ---------------------------------------------------------------------------
echo "Case (b): red commit exists, a locked test MODIFIED after it → block/locked-test-modified"
REPO=$(build_repo b)
commit_red "$REPO"
# Modify a test file that existed at the red SHA (tests/test-locked.sh).
echo "echo locked-v2-tampered" > "$REPO/tests/test-locked.sh"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "feat(x): green impl (#$ISSUE)"
TEST_CMD="$PASS_CMD"
run_gate "$REPO"
assert_case "b locked-test-modified" "SPLIT_ROLE=block ISSUE=$ISSUE REASON=locked-test-modified"

# ---------------------------------------------------------------------------
echo "Case (c): locked test DELETED after red → block/locked-test-deleted"
REPO=$(build_repo c)
commit_red "$REPO"
# Delete a test file that existed at the red SHA.
git -C "$REPO" rm -q "tests/test-locked.sh"
git -C "$REPO" commit -qm "feat(x): green impl, drop locked test (#$ISSUE)"
TEST_CMD="$PASS_CMD"
run_gate "$REPO"
assert_case "c locked-test-deleted" "SPLIT_ROLE=block ISSUE=$ISSUE REASON=locked-test-deleted"

# ---------------------------------------------------------------------------
echo "Case (d): additive-only (NEW test added after red, no locked test touched) + suite green → pass/additive-ok"
REPO=$(build_repo d)
commit_red "$REPO"
# Add a brand-new test file (--diff-filter=A) and touch only non-test source.
echo "echo brand-new" > "$REPO/tests/test-additive.sh"
echo "impl" > "$REPO/src.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "feat(x): green impl + new test (#$ISSUE)"
TEST_CMD="$PASS_CMD"
run_gate "$REPO"
assert_case "d additive-ok" "SPLIT_ROLE=pass ISSUE=$ISSUE REASON=additive-ok"

# ---------------------------------------------------------------------------
echo "Case (e): red + lock OK but suite fails → block/suite-red"
REPO=$(build_repo e)
commit_red "$REPO"
# Lock-clean impl commit (no locked test modified/deleted), but the suite fails.
echo "impl" > "$REPO/src.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "feat(x): green impl (#$ISSUE)"
TEST_CMD="$FAIL_CMD"
run_gate "$REPO"
assert_case "e suite-red" "SPLIT_ROLE=block ISSUE=$ISSUE REASON=suite-red"

# ---------------------------------------------------------------------------
echo "Case (f): impl commit ALSO mentions [split-role-red] → anchor resolves to EARLIER RED (#1084)"
REPO=$(build_repo f)
commit_red "$REPO"
# A later impl commit whose SUBJECT also contains the literal [split-role-red]
# substring (legitimate work ON the split-role machinery, e.g. #1077's GREEN).
# This impl commit TAMPERS the locked test (overwrites the pre-existing line in
# tests/test-locked.sh that existed at the real RED SHA).
#
# This case DISCRIMINATES the two anchor resolutions:
#   - head-1 (newest, BUGGY): picks THIS impl commit as the anchor. The diff
#     window <impl>..HEAD is then EMPTY (impl == HEAD), so the tamper is INVISIBLE
#     → false-pass additive-ok.
#   - tail-1 (earliest, CORRECT): picks the real RED commit. The diff window
#     <red>..HEAD then SEES the tampered locked file → block locked-test-modified.
# Expecting locked-test-modified PROVES the earlier RED anchor is resolved.
echo "echo locked-v2-tampered-by-marker-impl" > "$REPO/tests/test-locked.sh"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "fix(x): infer shape from [split-role-red] anchor (#$ISSUE)"
TEST_CMD="$PASS_CMD"
run_gate "$REPO"
assert_case "f anchor-collision resolves earlier RED" "SPLIT_ROLE=block ISSUE=$ISSUE REASON=locked-test-modified"

# ---------------------------------------------------------------------------
echo "Case (g): purely-additive APPEND to an existing locked test file → pass/additive-ok (#1084)"
REPO=$(build_repo g)
commit_red "$REPO"
# Append a line to a test file that EXISTED at the red SHA (tests/test-locked.sh).
# Zero existing lines removed/changed (removed == 0) → cannot weaken a RED
# assertion → NOT a violation (today's --diff-filter=MD wrongly blocks it).
printf 'echo locked-extra-assertion\n' >> "$REPO/tests/test-locked.sh"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "feat(x): green impl, append assertion (#$ISSUE)"
TEST_CMD="$PASS_CMD"
run_gate "$REPO"
assert_case "g additive-append-ok" "SPLIT_ROLE=pass ISSUE=$ISSUE REASON=additive-ok"

# ---------------------------------------------------------------------------
echo "Case (h): a REMOVED/CHANGED existing line in a locked test file → block/locked-test-modified (#1084)"
REPO=$(build_repo h)
commit_red "$REPO"
# Overwrite the existing locked test (the original line is removed/altered →
# removed > 0 → tampering → still blocks).
echo "echo locked-v2-tampered" > "$REPO/tests/test-locked.sh"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "feat(x): green impl, alter locked line (#$ISSUE)"
TEST_CMD="$PASS_CMD"
run_gate "$REPO"
assert_case "h tamper-modified" "SPLIT_ROLE=block ISSUE=$ISSUE REASON=locked-test-modified"

# ---------------------------------------------------------------------------
echo "Case (i): deleted locked test file STILL blocks → block/locked-test-deleted (#1084)"
REPO=$(build_repo i)
commit_red "$REPO"
# Delete a locked test file (D) — no additive interpretation; always blocks.
git -C "$REPO" rm -q "tests/test-locked.sh"
git -C "$REPO" commit -qm "feat(x): green impl, drop locked test (#$ISSUE)"
TEST_CMD="$PASS_CMD"
run_gate "$REPO"
assert_case "i delete-blocks" "SPLIT_ROLE=block ISSUE=$ISSUE REASON=locked-test-deleted"

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
