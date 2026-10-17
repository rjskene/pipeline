#!/usr/bin/env bash
# fullsend-dispatch-specs.sh — fullsend Step 6 execute dispatch specs, ONE call
# per wave. The PATH letter is DERIVED from the issue's own label
# (docs-only->A, quick-fix->D, multi-task->C, else B), never recalled from
# orchestrator context; resolve-execute-dispatch.sh's token lines are flattened
# onto that issue's single DISPATCH line.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: fullsend-dispatch-specs.sh <N>...

Prints ONE line per issue:
  DISPATCH issue=#<N> ISSUE=<N> PATH=<A|B|C|D> MODEL=<model> ... PRE_PR_REVIEW=<on|off> [PATH_C_FANOUT=<on|off>] REASON=<token>
Always pass model=$MODEL from the line; relay PRE_PR_REVIEW= (and PATH C's
PATH_C_FANOUT=) into the execute prompt. Exit 0.
Env: PIPELINE_REPO.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_resolve-config.sh
[ -f "$SELF_DIR/_resolve-config.sh" ] && source "$SELF_DIR/_resolve-config.sh"

for N in "$@"; do
  LBL=$(gh issue view "$N" --repo "$PIPELINE_REPO" --json labels --jq '[.labels[].name] | join(" ")')
  case "$LBL" in *docs-only*) P=A ;; *quick-fix*) P=D ;; *multi-task*) P=C ;; *) P=B ;; esac
  echo "DISPATCH issue=#$N $(PIPELINE_REPO="$PIPELINE_REPO" bash "$SELF_DIR/resolve-execute-dispatch.sh" "$N" "$P" | tr '\n' ' ')"
done
exit 0
