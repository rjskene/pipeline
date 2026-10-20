#!/usr/bin/env bash
# fullsend-preflight.sh — fullsend Step 7 PR-eval preflight, one call per wave.
# Per-issue work fans out via helper_parallel_map (cap PIPELINE_HELPER_PARALLEL).
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: fullsend-preflight.sh <N>...

For each pr-open issue: derive its worktree + PR (fail-closed, see
_fullsend-resolve-pr.sh), run pr-eval-preflight.sh, and print ONE line:
  PREFLIGHT issue=#<N> PREFLIGHT=ok|block REASON=<token> PR=<n> FIXED=<csv|none>
Exit 0 always; the orchestrator decides what a block means.
Env: PIPELINE_REPO, PIPELINE_PROJECT_ROOT, PIPELINE_WORKTREE_PREFIX.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_resolve-config.sh
[ -f "$SELF_DIR/_resolve-config.sh" ] && source "$SELF_DIR/_resolve-config.sh"
# shellcheck source=scripts/_fullsend-resolve-pr.sh
source "$SELF_DIR/_fullsend-resolve-pr.sh"
# shellcheck source=scripts/_helper-parallel.sh
source "$SELF_DIR/_helper-parallel.sh"

_preflight_one() {
  fullsend_resolve_pr "$1"
  echo "PREFLIGHT issue=#$1 $(bash "$SELF_DIR/pr-eval-preflight.sh" "$1" --pr "$PR_NUM" --worktree "$WT")"
}
helper_parallel_map _preflight_one "$@"
exit 0
