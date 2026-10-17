#!/usr/bin/env bash
# fullsend-gate.sh — fullsend Step 7 greenlight gate, ONE call per wave.
#
# Sources scripts/auto-merge-gate.sh, threads PIPELINE_CAPABILITY_REFUSAL_SOURCES
# via `check-capability-refusal.sh --resolve-sources` (hoisted above the loop:
# wave-invariant), then runs auto_merge_should_fire per issue. Performs NO merge.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: fullsend-gate.sh <N>...

For each issue whose evaluator returned: derive worktree -> branch -> PR
(fail-closed), run auto_merge_should_fire, and print ONE line:
  GATE: issue=#<N> pr=#<P> reason=<token>
Tokens: green, block-flag, block-label, block-cage-tests-diff, block-verdict,
block-capability-refused, block-base-mismatch, block-ci, block-mergeable,
block-mergestate. An empty PR derivation yields a block-* token, never a skip.
--resolve-sources states: resolved (knob exported), no-log-dir /
unresolvable-root (stderr NOTE, capability arm dormant, fail-open).
Env: PIPELINE_REPO, PIPELINE_BASE_BRANCH, PIPELINE_PROJECT_ROOT,
PIPELINE_WORKTREE_PREFIX, MANUAL_MERGE.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_resolve-config.sh
[ -f "$SELF_DIR/_resolve-config.sh" ] && source "$SELF_DIR/_resolve-config.sh"
# shellcheck source=scripts/_fullsend-resolve-pr.sh
source "$SELF_DIR/_fullsend-resolve-pr.sh"

source "$SELF_DIR/auto-merge-gate.sh"
CR_LINE=$(bash "$SELF_DIR/check-capability-refusal.sh" --resolve-sources)
CR_STATE=${CR_LINE%% *}; CR_STATE=${CR_STATE#SOURCES=}
case "$CR_STATE" in
  resolved)                     export PIPELINE_CAPABILITY_REFUSAL_SOURCES="${CR_LINE##*DIR=}" ;;
  no-log-dir|unresolvable-root) echo "NOTE: capability arm skipped/DORMANT: $CR_LINE" >&2 ;;
esac
for N in "$@"; do
  ISSUE="$N"
  fullsend_resolve_pr "$N"
  REASON=$(auto_merge_should_fire "$ISSUE" "$PR_NUM")
  echo "GATE: issue=#$ISSUE pr=#$PR_NUM reason=$REASON"
done
exit 0
