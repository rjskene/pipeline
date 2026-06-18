#!/bin/bash
# Regression test for issue #1066: split-role-gate must NOT conflate an
# unresolvable base ref with a missing red anchor.
#
# When the gate is invoked WITHOUT $PIPELINE_BASE_BRANCH exported into its
# subprocess environment AND without an explicit <base-ref> argument, the base
# ref is empty and the git log scan window is unresolvable — that MUST emit a
# DISTINCT token (block unresolvable-base) and NOT `block no-red-sha` (which
# reads as "the author never committed a red anchor").
#
# Additionally, when the gate IS invoked with an explicit <base-ref> argument
# (the recommended call-site fix), a branch carrying a valid [split-role-red]
# anchor must still return `pass additive-ok` even when PIPELINE_BASE_BRANCH
# is absent from the environment.

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

ISSUE=1066
BASE=base-branch

# Build a throwaway repo with a base branch and a feature branch that carries a
# valid [split-role-red] anchor commit.
build_repo_with_red() {
  local name="$1"
  local repo="$WORKDIR/$name"
  mkdir -p "$repo/tests"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t.t
  git -C "$repo" config user.name t
  git -C "$repo" checkout -q -b "$BASE"
  echo base > "$repo/base.txt"
  echo "echo locked-v1" > "$repo/tests/test-locked.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "base"
  # Feature branch with a valid red anchor.
  git -C "$repo" checkout -q -b "feature/issue-$ISSUE"
  echo "echo red-suite" > "$repo/tests/test-new.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "test(x): add failing suite [split-role-red] (#$ISSUE)"
  # Green impl commit (additive only — no locked test touched).
  echo "impl" > "$repo/src.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "feat(x): green impl (#$ISSUE)"
  echo "$repo"
}

# ---------------------------------------------------------------------------
# Case (f): PIPELINE_BASE_BRANCH unexported, no explicit base-ref arg →
# must emit a DISTINCT unresolvable-base token, NOT no-red-sha.
# This is the regression case from #1066.
echo "Case (f): PIPELINE_BASE_BRANCH unexported, no explicit base-ref arg → must NOT emit no-red-sha"
REPO=$(build_repo_with_red f)
inc
set +e
# Explicitly unset PIPELINE_BASE_BRANCH so the subprocess cannot inherit it.
# Invoke gate with ONLY the issue number (no base-ref arg) — mirrors the
# broken evaluate-issue-pr invocation that triggered #1066.
OUT=$(cd "$REPO" && env -i HOME="$HOME" PATH="$PATH" PIPELINE_TEST_CMD="true" \
      bash "$GATE" "$ISSUE" 2>/dev/null)
CODE=$?
set -e

if [ "$CODE" -ne 0 ]; then
  fail_msg "f unexported-base: expected exit 0 (verdict rides token), got exit $CODE"
elif [ "$OUT" = "SPLIT_ROLE=block ISSUE=$ISSUE REASON=no-red-sha" ]; then
  fail_msg "f unexported-base: emitted no-red-sha — conflates unresolvable base with missing anchor (regression #1066)"
  echo "         actual: [$OUT]"
  echo "         expected: any token EXCEPT no-red-sha (e.g. block unresolvable-base)"
elif echo "$OUT" | grep -qE '^SPLIT_ROLE=(block|pass) ISSUE=[0-9]+ REASON='; then
  pass_msg "f unexported-base: emitted distinct token (not no-red-sha): [$OUT]"
else
  fail_msg "f unexported-base: unexpected output: [$OUT]"
fi

# ---------------------------------------------------------------------------
# Case (g): PIPELINE_BASE_BRANCH unexported BUT explicit base-ref arg passed →
# a valid red anchor must still resolve → pass/additive-ok.
echo "Case (g): PIPELINE_BASE_BRANCH unexported, explicit base-ref arg → pass/additive-ok"
REPO=$(build_repo_with_red g)
inc
set +e
OUT=$(cd "$REPO" && env -i HOME="$HOME" PATH="$PATH" PIPELINE_TEST_CMD="true" \
      bash "$GATE" "$ISSUE" "$BASE" tests 2>/dev/null)
CODE=$?
set -e

EXPECTED="SPLIT_ROLE=pass ISSUE=$ISSUE REASON=additive-ok"
if [ "$CODE" -ne 0 ]; then
  fail_msg "g explicit-base-ref: expected exit 0, got exit $CODE"
elif [ "$OUT" != "$EXPECTED" ]; then
  fail_msg "g explicit-base-ref: stdout mismatch"
  echo "         expected: [$EXPECTED]"
  echo "         actual:   [$OUT]"
else
  pass_msg "g explicit-base-ref: exit 0 + '$EXPECTED'"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
