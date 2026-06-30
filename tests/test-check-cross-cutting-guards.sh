#!/bin/bash
set -uo pipefail

# Tests for scripts/check-cross-cutting-guards.sh — the fast, diff-independent
# "cross-cutting guards" lint aggregator introduced by #1132.
#
# The aggregator composes the existing repo-invariant guards (which complete in
# seconds and catch repo-wide invariants independent of the diff — exactly the
# class the affected-tests-only pre-PR heuristic misses, e.g. the #1128
# config-drift miss). It runs each sub-guard, captures every rc into a strict
# sentinel (mirror of scripts/run-test-suite.sh), and exits 1 iff ANY sub-guard
# failed (even on high/128+ exit codes), 0 on all-pass.
#
# Membership (must be invoked / named in output):
#   check-config-drift.sh
#   check-no-consumer-claude-writes.sh
#   test-doctor-golden-seed-set.sh
#   test-config-drift-clean.sh
#   test-readme-anchor-guard-prose.sh
#   check-branch-cruft.sh          (worktree-only; SKIP-with-note from repo root)
#
# Sub-cases:
#   1. MEMBERSHIP      — every expected guard name appears in the aggregator output.
#   2. STRICT AGG FAIL — a synthetic undocumented PIPELINE_* token reds a sub-guard
#                        (check-config-drift) -> aggregator exits 1.
#   3. CLEAN-TREE PASS — on a clean working tree the aggregator exits 0.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGG="$REPO_ROOT/scripts/check-cross-cutting-guards.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$AGG" ]; then
  echo "ERROR: aggregator not found at $AGG" >&2
  echo "       (expected NEW scripts/check-cross-cutting-guards.sh from #1132)" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Sub-case 3 first: CLEAN-TREE PASS -> exit 0.
# Run before any fixture mutation so the working tree is pristine.
# ---------------------------------------------------------------------------
echo "Sub-case 3: clean working tree -> aggregator exits 0"
inc
set +e
bash "$AGG" >"$WORKDIR/clean.out" 2>"$WORKDIR/clean.err"
rc_clean=$?
set -e
if [ "$rc_clean" -eq 0 ]; then
  pass_msg "clean tree passes the aggregator (exit 0)"
else
  fail_msg "expected rc=0 on clean tree, got rc=$rc_clean; err=$(cat "$WORKDIR/clean.err")"
fi

# ---------------------------------------------------------------------------
# Sub-case 1: MEMBERSHIP — every expected guard name appears in the output.
# Reuse the clean run's combined output (stdout+stderr); the aggregator emits a
# per-guard OK/FAIL line naming each guard.
# ---------------------------------------------------------------------------
echo "Sub-case 1: membership — every expected guard is named in the output"
MEMBERSHIP_OUT="$WORKDIR/clean.out $WORKDIR/clean.err"
EXPECTED_GUARDS=(
  check-config-drift.sh
  check-no-consumer-claude-writes.sh
  test-doctor-golden-seed-set.sh
  test-config-drift-clean.sh
  test-readme-anchor-guard-prose.sh
  check-branch-cruft.sh
)
for g in "${EXPECTED_GUARDS[@]}"; do
  inc
  if grep -qF "$g" $MEMBERSHIP_OUT; then
    pass_msg "membership: $g appears in aggregator output"
  else
    fail_msg "membership: $g NOT named in aggregator output"
  fi
done

# ---------------------------------------------------------------------------
# Sub-case 2: STRICT AGGREGATE FAIL — inject a synthetic undocumented PIPELINE_*
# token into the scan surface so check-config-drift (a sub-guard) reds, then
# assert the aggregator strict-fails (exit 1).
#
# The aggregator's check-config-drift sub-guard scans the live scripts/ tree by
# default. We drop a temp .sh file carrying an undocumented PIPELINE_* token into
# scripts/, run the aggregator, then remove the fixture. A trap guarantees the
# fixture is cleaned up even if an assertion below errors, so the working tree is
# restored to clean.
# ---------------------------------------------------------------------------
echo "Sub-case 2: synthetic undocumented PIPELINE_* token -> aggregator exits 1"
inc
FIXTURE="$REPO_ROOT/scripts/zz-cross-cutting-guard-fixture-1132.sh"
cleanup_fixture() { rm -f "$FIXTURE"; }
trap 'cleanup_fixture; rm -rf "$WORKDIR"' EXIT
{
  echo '#!/bin/bash'
  echo '# Synthetic fixture for tests/test-check-cross-cutting-guards.sh (#1132).'
  echo 'echo "${PIPELINE_TEST_CROSS_CUTTING_UNDOC_1132}"'
} > "$FIXTURE"

set +e
bash "$AGG" >"$WORKDIR/fail.out" 2>"$WORKDIR/fail.err"
rc_fail=$?
set -e
cleanup_fixture
trap 'rm -rf "$WORKDIR"' EXIT

if [ "$rc_fail" -eq 1 ]; then
  pass_msg "strict aggregate fail: undocumented PIPELINE_* token reds the aggregator (exit 1)"
else
  fail_msg "expected rc=1 with injected undocumented token, got rc=$rc_fail; err=$(cat "$WORKDIR/fail.err")"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
