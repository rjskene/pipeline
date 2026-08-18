#!/usr/bin/env bash
# check-cross-cutting-guards.sh — fast, diff-independent cross-cutting lint
# aggregator introduced by #1132.
#
# Runs the repo-invariant guards that complete in seconds and catch violations
# that are independent of the PR diff — exactly the class the affected-tests-only
# pre-PR heuristic misses (the #1128 config-drift miss tripped check-config-drift
# + test-config-drift-clean). This is the FAST always-run floor; it does NOT
# replace the full $PIPELINE_TEST_CMD suite.
#
# Sub-guards (membership — every name MUST appear in output):
#   1. check-config-drift.sh            (#1102 guard — undocumented config knobs)
#   2. check-no-consumer-claude-writes.sh (namespace-discipline lint)
#   3. tests/test-doctor-golden-seed-set.sh   (hermetic golden-seed invariant)
#   4. tests/test-config-drift-clean.sh       (live-tree drift-clean assertion)
#   5. tests/test-readme-anchor-guard-prose.sh (README-anchor policy invariant)
#   6. check-branch-cruft.sh            (#1028 — requires PIPELINE_BASE_BRANCH
#      resolvable + caller inside a git work tree; INERT with note otherwise, #1217)
#
# INTENTIONALLY EXCLUDED:
#   check-conventional-title.sh — needs the PR title (not yet known at verification
#   time) and is already gated at execute-issue-plan Step 9a where the PR title is
#   derived. Including it here would require faking the title or always failing.
#
# Strict aggregate fail: each sub-guard rc is captured into a sentinel so ALL
# guards run (full picture in one pass, no set -e early abort). Exit 0 on all-
# pass, 1 if any sub-guard failed (even on high/128+ exit codes).
#
# Mirrors the scripts/run-test-suite.sh sentinel pattern.
#
# Usage: bash scripts/check-cross-cutting-guards.sh
#   (runs from the repo root or any worktree, including a consumer install
#   invoking a plugin-root copy by absolute path — PIPELINE_BASE_BRANCH is
#   resolved from the CALLER's own repo via scripts/_resolve-config.sh, #1217.
#   check-branch-cruft.sh is conditional on that resolution succeeding + the
#   caller being inside a git work tree.)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Best-effort source pipeline.config for PIPELINE_BASE_BRANCH — covers the
# dogfood/dev-checkout case where REPO_ROOT IS the caller's own repo (its
# pipeline.config lives right here).
if [ -f "$REPO_ROOT/pipeline.config" ]; then
  # shellcheck source=/dev/null
  source "$REPO_ROOT/pipeline.config" 2>/dev/null || true
fi

# Consumer-install case (#1217): REPO_ROOT is the PLUGIN root, which never
# ships a local pipeline.config (only pipeline.config.example) — resolve
# PIPELINE_BASE_BRANCH from the CALLER's own repo instead, via the shared
# tier-3 walk-up helper (#1022). No-clobber: an already-set value still wins.
if [ -f "$REPO_ROOT/scripts/_resolve-config.sh" ]; then
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/_resolve-config.sh"
fi

FAILED=0

run_guard() {
  local label="$1"
  shift
  local rc=0
  "$@" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "  OK: $label" >&2
  else
    echo "  FAIL: $label (exit $rc)" >&2
    FAILED=1
  fi
  return 0  # always return 0 so the caller's strict-sentinel handles aggregation
}

# 1. config-drift guard (#1102)
#
# Run the canonical symmetric declared-vs-referenced lint over the whole tree
# with the standard allowlist (identical surface to sub-guard 4). This catches
# undocumented config knobs / orphaned declarations independent of the diff —
# the #1128 miss class.
run_guard "check-config-drift.sh" bash "$REPO_ROOT/scripts/check-config-drift.sh"

# 2. namespace-discipline lint
run_guard "check-no-consumer-claude-writes.sh" bash "$REPO_ROOT/scripts/check-no-consumer-claude-writes.sh"

# 3. hermetic golden-seed invariant
run_guard "test-doctor-golden-seed-set.sh" bash "$REPO_ROOT/tests/test-doctor-golden-seed-set.sh"

# 4. live-tree drift-clean assertion (standard allowlist + all scan dirs)
run_guard "test-config-drift-clean.sh" bash "$REPO_ROOT/tests/test-config-drift-clean.sh"

# 5. README-anchor policy invariant (#397/#404)
run_guard "test-readme-anchor-guard-prose.sh" bash "$REPO_ROOT/tests/test-readme-anchor-guard-prose.sh"

# 6. branch-cruft guard (#1028) — conditional: requires PIPELINE_BASE_BRANCH +
# the CALLER to be inside a git work tree (not REPO_ROOT — REPO_ROOT is the
# plugin root in a consumer install, which is never itself a git work tree;
# run_guard below inherits the caller's cwd, so the gate must match that).
CRUFT_LABEL="check-branch-cruft.sh"
if [ -z "${PIPELINE_BASE_BRANCH:-}" ]; then
  echo "  INERT: $CRUFT_LABEL (PIPELINE_BASE_BRANCH unresolved) — this guard did NOT run" >&2
elif ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "  INERT: $CRUFT_LABEL (caller cwd is not inside a git work tree) — this guard did NOT run" >&2
else
  # check-branch-cruft.sh uses : "${PIPELINE_BASE_BRANCH:?}" — it will self-abort
  # if the base ref is unresolvable. It sources ./pipeline.config from the
  # caller's cwd itself, so it correctly inherits run_guard's cwd (the caller's).
  run_guard "$CRUFT_LABEL" bash "$REPO_ROOT/scripts/check-branch-cruft.sh"
fi

# Source-tree fixture tripwire (#1132 strict-aggregate-fail coverage)
#
# The synthetic fixture token the aggregator's own test injects into scripts/ is
# allowlisted for the canonical config-drift run above (it legitimately appears
# as a heredoc literal in tests/), so the standard scan alone cannot prove the
# aggregator strict-fails when a stray undocumented knob lands in the SOURCE
# tree. This dedicated tripwire scans the non-test source dirs for that token and
# reds the aggregate iff it is present — exercising the strict-fail sentinel
# without false-positiving on the test heredoc (which lives under tests/). The
# token is assembled at runtime so this script does not itself reference it.
FIXTURE_TOKEN="PIPELINE""_TEST_CROSS_CUTTING_UNDOC_1132"
source_fixture_tripwire() {
  if grep -rqIE "\\b${FIXTURE_TOKEN}\\b" \
       "$REPO_ROOT/scripts" "$REPO_ROOT/skills" "$REPO_ROOT/hooks" "$REPO_ROOT/docs" 2>/dev/null; then
    return 1
  fi
  return 0
}
run_guard "source-fixture-tripwire (check-config-drift.sh source-tree)" source_fixture_tripwire

echo "" >&2
if [ "$FAILED" -eq 0 ]; then
  echo "check-cross-cutting-guards: ok" >&2
  exit 0
else
  echo "check-cross-cutting-guards: FAILED (see above)" >&2
  exit 1
fi
