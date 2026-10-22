#!/usr/bin/env bash
# fullsend-dispatch-specs.sh — fullsend Step 6 execute dispatch specs, ONE call
# per wave. The PATH letter is DERIVED from the issue's own label
# (docs-only->A, quick-fix->D, multi-task->C, else B), never recalled from
# orchestrator context; resolve-execute-dispatch.sh's token lines are flattened
# onto that issue's single DISPATCH line.
# PIPELINE_INLINE_MAX_CONCURRENT (#1559) sets the leading width header.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: fullsend-dispatch-specs.sh <N>...

First line: INLINE_MAX_CONCURRENT=<n|all> (`all` = 0/unset or >= wave size:
dispatch every issue in ONE message). Then ONE line per issue:
  DISPATCH issue=#<N> ISSUE=<N> PATH=<A|B|C|D> MODEL=<model> ... PRE_PR_REVIEW=<on|off> [PATH_C_FANOUT=<on|off>] REASON=<token>
Always pass model=$MODEL from the line; relay PRE_PR_REVIEW= (and PATH C's
PATH_C_FANOUT=) into the execute prompt. Exit 0.
Env: PIPELINE_REPO, PIPELINE_INLINE_MAX_CONCURRENT.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_resolve-config.sh
[ -f "$SELF_DIR/_resolve-config.sh" ] && source "$SELF_DIR/_resolve-config.sh"

CAP="${PIPELINE_INLINE_MAX_CONCURRENT:-0}"
case "$CAP" in
  ''|*[!0-9]*) echo "NOTE: PIPELINE_INLINE_MAX_CONCURRENT='$CAP' is not a non-negative integer; using all" >&2; W=all ;;
  *) C=$((10#$CAP)); if [ "$C" -eq 0 ] || [ "$C" -ge "$#" ]; then W=all; else W=$C; fi ;;
esac
echo "INLINE_MAX_CONCURRENT=$W"

for N in "$@"; do
  LBL=$(gh issue view "$N" --repo "$PIPELINE_REPO" --json labels --jq '[.labels[].name] | join(" ")')
  case "$LBL" in *docs-only*) P=A ;; *quick-fix*) P=D ;; *multi-task*) P=C ;; *) P=B ;; esac
  echo "DISPATCH issue=#$N $(PIPELINE_REPO="$PIPELINE_REPO" bash "$SELF_DIR/resolve-execute-dispatch.sh" "$N" "$P" | tr '\n' ' ')"
done
exit 0
