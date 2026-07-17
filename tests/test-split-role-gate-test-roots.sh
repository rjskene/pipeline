#!/bin/bash
set -euo pipefail

# Regression suite for scripts/split-role-gate.sh lock-scope resolution when the
# consumer's tests live OUTSIDE tests/ (issue #1182). The gate resolves its
# locked-test scope from positional <test-path>... args, defaulting to tests/
# when none are given. A repo whose tests live under e.g. subagents/*/testing/
# gets a VACUOUS pass: with nothing under tests/, the W7 additive-only invariant
# is trivially satisfied even when the green role tampers a locked test.
#
# The fix (authored by the GREEN implementer, NOT here) adds a middle precedence
# tier so that with NO positional args the scope resolves from
# $PIPELINE_TEST_ROOTS (glob-safe split so a git-pathspec wildcard reaches git
# literally), falling back to tests/ only when that too is unset. The caller
# skills/evaluate-issue-pr/SKILL.md threads PIPELINE_TEST_ROOTS into the gate
# invocation, and pipeline.config.example documents the knob.
#
# This is the split-role RED artifact ([split-role-red]). Expected state at
# authoring time (against the UNFIXED gate + unwired caller/config):
#   Case 1 (env-root tamper)   FAIL  — gate ignores $PIPELINE_TEST_ROOTS, defaults
#                                       scope to tests/, finds nothing, vacuous pass.
#   Case 2 (default unchanged) PASS  — documents the exact vacuous pass; proves the
#                                       fix leaves default (tests/) behavior identical.
#   Case 3 (positional wins)   PASS  — positional arg already targets the tampered dir.
#   Case 4 (caller wiring)     FAIL  — SKILL.md does not yet thread PIPELINE_TEST_ROOTS.
#   Case 5 (config doc)        FAIL  — pipeline.config.example does not yet document it.
# Cases 1/4/5 go GREEN once the fix lands; 2/3 stay GREEN (no-regression guards).
#
# The gate always emits EXACTLY ONE stdout line and ALWAYS exits 0 (verdict rides
# the token): SPLIT_ROLE=<pass|block> ISSUE=<N> REASON=<token>.

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

ISSUE=1182
BASE=base-anchor

# Locked tests live OUTSIDE tests/ — the exact shape #1182 reports.
ROOT_DIR="subagents/milestones/testing"

# Suite-green stub so the SECONDARY suite check is a no-op pass; the PRIMARY
# locked-test invariant is what these cases exercise.
TEST_CMD="true"

# build_repo <name> — fresh throwaway repo shaped like a real feature worktree.
# $BASE holds one base commit that already contains a base-origin locked test
# under $ROOT_DIR (NOT under tests/); a feature branch is checked out off that
# base tip so every later commit lands in the gate's $BASE..HEAD scan window.
# Echoes the repo path. (Deliberately does NOT reuse test-split-role-gate.sh's
# build_repo, which hardcodes tests/.)
build_repo() {
  local repo="$WORKDIR/$1"
  mkdir -p "$repo/$ROOT_DIR"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t.t
  git -C "$repo" config user.name t
  git -C "$repo" checkout -q -b "$BASE"
  echo base > "$repo/base.txt"
  printf 'echo locked-v1\n' > "$repo/$ROOT_DIR/test-locked.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "base"
  # Feature branch off the base tip — all later commits live above $BASE.
  git -C "$repo" checkout -q -b "feature/issue-$ISSUE"
  echo "$repo"
}

# commit_red <repo> — the single [split-role-red] commit; ADDS a new red-authored
# test file under $ROOT_DIR (never touches the base-origin locked file).
commit_red() {
  local repo="$1"
  printf 'echo red-suite\n' > "$repo/$ROOT_DIR/test-red.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "test(x): add failing suite [split-role-red] (#$ISSUE)"
}

# commit_green_tamper <repo> — a LATER, NON-marker commit that overwrites the
# base-origin locked test so a pre-existing line is removed/altered (removed > 0
# in numstat): green tampering with a base-origin locked test. This is the shape
# the additive-only W7 invariant must catch when the scope covers $ROOT_DIR.
commit_green_tamper() {
  local repo="$1"
  printf 'echo locked-v2-tampered\n' > "$repo/$ROOT_DIR/test-locked.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "feat(x): green impl, alter locked line (#$ISSUE)"
}

# run_gate <repo> <roots-spec> [positional-test-path...]
#   roots-spec == "__UNSET__" → leave $PIPELINE_TEST_ROOTS unset; any other value
#   is exported as $PIPELINE_TEST_ROOTS. Invokes the gate from INSIDE the repo
#   (its natural eval-time CWD is the feature worktree). Captures stdout + exit
#   into globals OUT and CODE.
run_gate() {
  local repo="$1"; shift
  local roots="$1"; shift
  set +e
  if [ "$roots" = "__UNSET__" ]; then
    OUT=$( cd "$repo" && PIPELINE_TEST_CMD="$TEST_CMD" \
           bash "$GATE" "$ISSUE" "$BASE" "$@" 2>/dev/null )
  else
    OUT=$( cd "$repo" && PIPELINE_TEST_CMD="$TEST_CMD" PIPELINE_TEST_ROOTS="$roots" \
           bash "$GATE" "$ISSUE" "$BASE" "$@" 2>/dev/null )
  fi
  CODE=$?
  set -e
}

# assert_case <label> <expected-stdout-line>
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
# Case 1 — env-root tamper caught (THE core case; RED until the fix).
# $PIPELINE_TEST_ROOTS points (via git-pathspec glob) at the dir holding the
# tampered locked test, and NO positional <test-path> arg is given. The gate MUST
# resolve its lock scope from the env var and BLOCK the base-origin tamper.
# Against the unfixed gate: env ignored, scope defaults to tests/ (empty), suite
# green ⇒ vacuous `pass additive-ok` — the exact #1182 defect ⇒ this FAILS now.
echo "Case 1: env-root tamper caught → block/locked-test-modified (RED until fix)"
REPO=$(build_repo c1)
commit_red "$REPO"
commit_green_tamper "$REPO"
run_gate "$REPO" "subagents/*/testing/"
assert_case "1 env-root tamper" "SPLIT_ROLE=block ISSUE=$ISSUE REASON=locked-test-modified"

# ---------------------------------------------------------------------------
# Case 2 — default scope unchanged (guard; PASS now and after).
# $PIPELINE_TEST_ROOTS UNSET and no positional arg ⇒ scope defaults to tests/.
# The tampered file is under $ROOT_DIR, not tests/, so NOTHING is locked ⇒ the
# vacuous `pass additive-ok`. This documents the exact #1182 vacuous pass AND
# pins that the fix leaves the unset-knob default byte-identical.
echo "Case 2: default scope (tests/) unchanged → pass/additive-ok (guard)"
REPO=$(build_repo c2)
commit_red "$REPO"
commit_green_tamper "$REPO"
run_gate "$REPO" "__UNSET__"
assert_case "2 default-unchanged" "SPLIT_ROLE=pass ISSUE=$ISSUE REASON=additive-ok"

# ---------------------------------------------------------------------------
# Case 3 — positional precedence (guard; PASS now and after).
# An explicit positional <test-path> targeting the tampered dir WINS over a bogus
# $PIPELINE_TEST_ROOTS. The positional is the glob EXPANDED against the repo (as
# the task permits) so it targets $ROOT_DIR literally regardless of the fix —
# the current gate already honors positional args, so this blocks today too.
echo "Case 3: positional arg wins over env var → block/locked-test-modified (guard)"
REPO=$(build_repo c3)
commit_red "$REPO"
commit_green_tamper "$REPO"
# Expand `subagents/*/testing/` inside the repo so the tampered dir is targeted
# (a bare quoted git-pathspec with a trailing slash would not match on git 2.43).
POS=$(cd "$REPO" && echo subagents/*/testing/)
run_gate "$REPO" "bogus/does-not-exist/" "$POS"
assert_case "3 positional-precedence" "SPLIT_ROLE=block ISSUE=$ISSUE REASON=locked-test-modified"

# ---------------------------------------------------------------------------
# Case 4 — caller wiring guard (RED until the fix).
# The eval-time transport is prose in skills/evaluate-issue-pr/SKILL.md, not gate
# code: the caller must thread PIPELINE_TEST_ROOTS into the gate invocation env
# (same shape as PIPELINE_BASE_BRANCH / PIPELINE_CI_ROLLUP_GREEN /
# PIPELINE_SPLIT_ROLE_SHARED_TESTS). Grep the literal transport name.
echo "Case 4: evaluate-issue-pr/SKILL.md threads PIPELINE_TEST_ROOTS (RED until fix)"
EVAL_SKILL="$REPO_ROOT/skills/evaluate-issue-pr/SKILL.md"
inc
if [ ! -f "$EVAL_SKILL" ]; then
  fail_msg "4 caller-wiring: $EVAL_SKILL missing"
elif ! grep -qF 'PIPELINE_TEST_ROOTS=' "$EVAL_SKILL"; then
  fail_msg "4 caller-wiring: evaluate-issue-pr/SKILL.md does not thread PIPELINE_TEST_ROOTS="
else
  pass_msg "4 caller-wiring: evaluate-issue-pr/SKILL.md threads PIPELINE_TEST_ROOTS="
fi

# ---------------------------------------------------------------------------
# Case 5 — config-doc guard (RED until the fix).
# pipeline.config.example must document the optional PIPELINE_TEST_ROOTS knob so
# consumers whose tests live outside tests/ know to set it (else the split-role
# W7 lock is vacuous). Grep the literal knob name.
echo "Case 5: pipeline.config.example documents PIPELINE_TEST_ROOTS (RED until fix)"
CONFIG_EXAMPLE="$REPO_ROOT/pipeline.config.example"
inc
if [ ! -f "$CONFIG_EXAMPLE" ]; then
  fail_msg "5 config-doc: $CONFIG_EXAMPLE missing"
elif ! grep -qF 'PIPELINE_TEST_ROOTS' "$CONFIG_EXAMPLE"; then
  fail_msg "5 config-doc: pipeline.config.example does not document PIPELINE_TEST_ROOTS"
else
  pass_msg "5 config-doc: pipeline.config.example documents PIPELINE_TEST_ROOTS"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
