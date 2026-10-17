#!/usr/bin/env bash
# fullsend-fetch-attachments.sh — fullsend Step 1a: ingest issue attachments for
# the slate through the hook-sanctioned `filter-trusted-comments.sh
# fetch-attachments` wrapper (a direct fetch-issue-attachments.sh call is denied
# by enforce-comment-trust). Idempotent: repeat runs cost zero `gh api` calls.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: fullsend-fetch-attachments.sh <N>...

Runs `filter-trusted-comments.sh fetch-attachments <N>` for each issue and
prints at most ONE line per issue (the helper's first line). Attachments land
under .claude/scratch/issue-<N>/. No issues => no output, exit 0.
Env: PIPELINE_REPO (required); PIPELINE_PROJECT_ROOT is set to $(pwd).
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_resolve-config.sh
[ -f "$SELF_DIR/_resolve-config.sh" ] && source "$SELF_DIR/_resolve-config.sh"

for N in "$@"; do
  PIPELINE_REPO="$PIPELINE_REPO" PIPELINE_PROJECT_ROOT="$(pwd)" \
    bash "$SELF_DIR/filter-trusted-comments.sh" fetch-attachments "$N" 2>/dev/null \
    | head -1
done
exit 0
