#!/usr/bin/env bash
# evaluate-issue-pr-checks.sh — evaluate-issue-pr Step 4 (Phase 2): typecheck
# plus a CI-aware test run, in one call.
#
# The CI verdict comes from the dispatched PREFLIGHT= line (scripts/
# pr-eval-preflight.sh already read the settled statusCheckRollup); this helper
# never queries the rollup itself — that row would arm hooks/enforce-ci-wait.py.
#   green rollup (PREFLIGHT=ok + REASON=none|mergeable, PIPELINE_CI_CHECK_ENABLED
#   not false) -> skip the full local PIPELINE_TEST_CMD re-run.
#   anything else -> run tests locally, scoped to touched test files from the
#   PR diff; none touched -> the full PIPELINE_TEST_CMD.
# Run it at most once per eval, in the foreground — never via run_in_background
# (no overlapping or duplicate full-suite sweeps).
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: evaluate-issue-pr-checks.sh <PR> --preflight "<PREFLIGHT line>"

Typecheck (only when PIPELINE_TYPECHECK_CMD is set), then tests:
  [PREFLIGHT issue=#<N>] PREFLIGHT=ok REASON=none|mergeable
                                      -> prints the green-rollup skip line
  any other line, or CI checks off    -> runs touched tests (timeout 300 each),
                                         else the full PIPELINE_TEST_CMD
Env: PIPELINE_REPO, PIPELINE_TEST_CMD, PIPELINE_TYPECHECK_CMD,
     PIPELINE_CI_CHECK_ENABLED (default true).
USAGE
}

PR=""
PREFLIGHT_LINE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --preflight) PREFLIGHT_LINE="${2:-}"; shift 2 ;;
    *) PR="$1"; shift ;;
  esac
done
[ -n "$PR" ] || { usage >&2; exit 2; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_resolve-config.sh
[ -f "$SELF_DIR/_resolve-config.sh" ] && source "$SELF_DIR/_resolve-config.sh"

# (a) typecheck
if [ -n "${PIPELINE_TYPECHECK_CMD:-}" ]; then
  $PIPELINE_TYPECHECK_CMD 2>&1 | head -50
else
  echo "typecheck: skipped (PIPELINE_TYPECHECK_CMD unset)"
fi

# (b) tests
# Read the verdict by PREFLIGHT= token, not position: the fullsend wrapper
# prefixes `PREFLIGHT issue=#<N>` before it.
PF_VERDICT=$(sed -nE 's/.*PREFLIGHT=([a-z]+).*/\1/p' <<<"$PREFLIGHT_LINE")
PF_REASON=${PREFLIGHT_LINE##*REASON=}; PF_REASON=${PF_REASON%% *}
ROLLUP_GREEN=false
case "$PF_VERDICT:$PF_REASON" in
  ok:none|ok:mergeable) ROLLUP_GREEN=true ;;
esac
if [ "$ROLLUP_GREEN" = "true" ] && [ "${PIPELINE_CI_CHECK_ENABLED-true}" = "true" ]; then
  echo "CI: green rollup — trusting CI suite verdict; skipping full local PIPELINE_TEST_CMD re-run"
  exit 0
fi

# Fallback — not green, no CI, or CI checks disabled: run tests locally.
TOUCHED_TESTS=$(gh pr diff "$PR" --repo "${PIPELINE_REPO:-}" --name-only | grep -E '(^|/)tests?/' || true)
RC=0
if [ -n "$TOUCHED_TESTS" ]; then
  while IFS= read -r t; do
    [ -f "$t" ] || continue
    timeout 300 bash "$t" </dev/null || { RC=1; echo "FAILED: $t"; }
  done <<< "$TOUCHED_TESTS"
else
  timeout 600 bash -c "${PIPELINE_TEST_CMD:?PIPELINE_TEST_CMD unset}" </dev/null 2>&1 | tail -30
  RC=${PIPESTATUS[0]}
fi
exit "$RC"
