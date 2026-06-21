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

# run_gate_ci_green <repo> — same as run_gate but ALSO exports the CI-trust
# signal PIPELINE_CI_ROLLUP_GREEN=true into the gate subprocess (#1078). When
# the caller has already resolved a green statusCheckRollup, the gate must trust
# CI and SKIP the redundant secondary $PIPELINE_TEST_CMD re-run — emitting a
# deterministic pass token instead of re-running the ~9-11min sweep. The PRIMARY
# locked-test invariant runs first and is NEVER bypassed by this signal.
run_gate_ci_green() {
  local repo="$1"; shift
  set +e
  OUT=$( cd "$repo" && PIPELINE_TEST_CMD="$TEST_CMD" PIPELINE_CI_ROLLUP_GREEN=true \
         bash "$GATE" "$ISSUE" "$BASE" tests 2>/dev/null )
  CODE=$?
  set -e
}

# run_gate_shared <repo> <shared-list> — same as run_gate but ALSO exports the
# SHARED-TEST allow-list PIPELINE_SPLIT_ROLE_SHARED_TESTS into the gate subprocess
# (#1089, Direction 3). The eval-time caller resolves this list from the approved
# `## Implementation Plan`'s `**Shared tests (split-role):**` section; it names the
# EXACT repo-relative test paths the green role is sanctioned to modify. A listed
# Modified (M) locked test is exempt from the additive-only invariant; deletions (D)
# STILL always block; default-unset/empty exempts NOTHING (fail-closed default-deny).
# Same threading shape as run_gate_ci_green.
run_gate_shared() {
  local repo="$1"; shift
  local shared="$1"; shift
  set +e
  OUT=$( cd "$repo" && PIPELINE_TEST_CMD="$TEST_CMD" PIPELINE_SPLIT_ROLE_SHARED_TESTS="$shared" \
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

# ---------------------------------------------------------------------------
echo "Case (j): red + lock-clean + PIPELINE_CI_ROLLUP_GREEN=true (suite cmd would FAIL) → pass/additive-ok-ci-green (#1078)"
REPO=$(build_repo j)
commit_red "$REPO"
# Lock-clean impl commit (no locked test modified/deleted). Configure a FAILING
# suite command, but invoke the gate with the CI-trust signal asserted. The gate
# must SHORT-CIRCUIT the secondary suite-green check: it trusts the green CI
# rollup (precedent #957) and NEVER runs $FAIL_CMD. If the gate ignores the
# trust signal it runs $FAIL_CMD and emits REASON=suite-red (today's behavior).
# Expecting additive-ok-ci-green PROVES the suite re-run was SKIPPED on trust.
echo "impl" > "$REPO/src.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "feat(x): green impl, ci-trusted (#$ISSUE)"
TEST_CMD="$FAIL_CMD"
run_gate_ci_green "$REPO"
assert_case "j additive-ok-ci-green" "SPLIT_ROLE=pass ISSUE=$ISSUE REASON=additive-ok-ci-green"

# ---------------------------------------------------------------------------
echo "Case (k): locked test MODIFIED under PIPELINE_CI_ROLLUP_GREEN=true → STILL block/locked-test-modified (#1078)"
REPO=$(build_repo k)
commit_red "$REPO"
# Tamper a locked test (overwrite the pre-existing line that existed at the red
# SHA) AND assert the CI-trust signal. The PRIMARY locked-test additive-only
# invariant runs BEFORE the secondary suite-green step, so CI-trust can NEVER
# bypass it. This is a regression-pin: the lock must hard-block even when CI is
# green. (Passes against current code — lock precedes suite-green — keep it green.)
echo "echo locked-v2-tampered" > "$REPO/tests/test-locked.sh"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "feat(x): green impl, alter locked line (#$ISSUE)"
TEST_CMD="$PASS_CMD"
run_gate_ci_green "$REPO"
assert_case "k lock-blocks-under-ci-green" "SPLIT_ROLE=block ISSUE=$ISSUE REASON=locked-test-modified"

# ---------------------------------------------------------------------------
echo "Case (l): shared-listed locked test MODIFIED (removed > 0) → exempt → pass/additive-ok (#1089)"
REPO=$(build_repo l)
commit_red "$REPO"
# Overwrite the existing locked test (the original line is removed/altered →
# removed > 0). This is the EXACT shape case (h)/(b) hard-block as
# locked-test-modified today. But tests/test-locked.sh is named in the
# operator-approved shared set, so the additive-only invariant is LIFTED for it:
# a plan-sanctioned green edit to a red-authored test file (e.g. hardening an
# assertion/failure-message) is no longer a violation. Expecting additive-ok
# PROVES the exemption converts the would-be locked-test-modified into a pass —
# the exempted edit rides the EXISTING additive-ok token (no new token).
echo "echo locked-v2-hardened-message" > "$REPO/tests/test-locked.sh"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "feat(x): green impl, harden shared locked assertion (#$ISSUE)"
TEST_CMD="$PASS_CMD"
run_gate_shared "$REPO" "tests/test-locked.sh"
assert_case "l shared-modified-ok" "SPLIT_ROLE=pass ISSUE=$ISSUE REASON=additive-ok"

# ---------------------------------------------------------------------------
echo "Case (m): shared-listed locked test DELETED → STILL block/locked-test-deleted (#1089)"
REPO=$(build_repo m)
commit_red "$REPO"
# Delete a locked test file that IS in the shared allow-list. A deletion removes
# coverage and can never be "hardening" — the exemption is scoped to Modified (M)
# files ONLY; the separate Deleted (D) block is UNCHANGED. Even with the file
# named in PIPELINE_SPLIT_ROLE_SHARED_TESTS, a deletion still hits
# locked-test-deleted. PROVES the carve-out is mod-only, never delete.
git -C "$REPO" rm -q "tests/test-locked.sh"
git -C "$REPO" commit -qm "feat(x): green impl, drop shared locked test (#$ISSUE)"
TEST_CMD="$PASS_CMD"
run_gate_shared "$REPO" "tests/test-locked.sh"
assert_case "m shared-deleted-still-blocks" "SPLIT_ROLE=block ISSUE=$ISSUE REASON=locked-test-deleted"

# ---------------------------------------------------------------------------
echo "Case (n): NON-shared locked test MODIFIED (shared list names a DIFFERENT file) → block/locked-test-modified (#1089)"
REPO=$(build_repo n)
commit_red "$REPO"
# Tamper the locked test (removed > 0) but point the shared allow-list at a
# DIFFERENT file (tests/test-other.sh, which is never touched). The tampered file
# tests/test-locked.sh is NOT in the allow-list, so the exemption does NOT apply.
# PROVES the exemption is EXACT-PATH-scoped + default-deny: a non-listed file
# still hard-blocks (no prefix/glob/directory match, no vacuous pass). This guards
# against a `tests/` blanket exemption.
echo "echo locked-v2-tampered" > "$REPO/tests/test-locked.sh"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "feat(x): green impl, tamper non-shared locked test (#$ISSUE)"
TEST_CMD="$PASS_CMD"
run_gate_shared "$REPO" "tests/test-other.sh"
assert_case "n non-shared-modified-still-blocks" "SPLIT_ROLE=block ISSUE=$ISSUE REASON=locked-test-modified"

# ---------------------------------------------------------------------------
# Doc-contract guard (Task 3): the eval-time wiring is prose in
# skills/evaluate-issue-pr/SKILL.md, not gate code, so pin BOTH ends of the
# contract literally — the env-var transport name AND the plan section name the
# parser keys on. The SKILL must reference both so the resolved shared set is
# threaded into the gate. Expected FAIL until the Task-3 SKILL edits land.
echo "Doc-contract: evaluate-issue-pr/SKILL.md threads PIPELINE_SPLIT_ROLE_SHARED_TESTS from the **Shared tests (split-role):** plan section"
EVAL_SKILL="$REPO_ROOT/skills/evaluate-issue-pr/SKILL.md"
inc
if [ ! -f "$EVAL_SKILL" ]; then
  fail_msg "doc-contract: $EVAL_SKILL missing"
elif ! grep -qF 'PIPELINE_SPLIT_ROLE_SHARED_TESTS' "$EVAL_SKILL"; then
  fail_msg "doc-contract: evaluate-issue-pr/SKILL.md does not reference the literal PIPELINE_SPLIT_ROLE_SHARED_TESTS"
elif ! grep -qF '**Shared tests (split-role):**' "$EVAL_SKILL"; then
  fail_msg "doc-contract: evaluate-issue-pr/SKILL.md does not reference the literal section name **Shared tests (split-role):**"
else
  pass_msg "doc-contract: evaluate-issue-pr/SKILL.md references both contract literals"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
