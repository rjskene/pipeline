#!/usr/bin/env bash
# fullsend-merge-order.sh — fullsend merge orchestration: advisory pre-merge
# pairwise overlap scan over the open pr-open PRs (detect_merge_overlap) and a
# fewest-overlap-first ordering (recommend_merge_order). Never blocks.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: fullsend-merge-order.sh

Lists open PRs labelled pr-open; with >= 2, prints the pairwise overlap scan
and the recommended order. Always ends with ONE line:
  ORDER: <pr> <pr> ...
Use that order for the sequential merge loop. Exit 0.
Env: PIPELINE_REPO.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_resolve-config.sh
[ -f "$SELF_DIR/_resolve-config.sh" ] && source "$SELF_DIR/_resolve-config.sh"

source "$SELF_DIR/detect-merge-overlap.sh"
# shellcheck disable=SC2207  # PR numbers: word-splitting is the intent
APPROVED=( $(gh pr list --repo "$PIPELINE_REPO" --label pr-open --json number --jq '.[].number') )
if [ "${#APPROVED[@]}" -ge 2 ]; then
  echo "=== Pre-merge pairwise overlap scan ==="
  detect_merge_overlap "${APPROVED[@]}"
  echo "=== Recommended merge order (fewest overlap first) ==="
  # shellcheck disable=SC2207
  ORDERED=( $(recommend_merge_order "${APPROVED[@]}") )
  printf '  %s\n' "${ORDERED[@]}"
else
  ORDERED=( "${APPROVED[@]}" )
fi
echo "ORDER: ${ORDERED[*]}"
exit 0
