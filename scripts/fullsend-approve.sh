#!/usr/bin/env bash
# fullsend-approve.sh — fullsend Step 4 (and the Step 2/3 skip/annotate arms):
# flip each issue to `plan-approved` through ONE scripts/transition-issue.sh
# --batch call per wave (per-issue flips fan out, #1548).
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: fullsend-approve.sh [--from <label>] [--comment <text>] <N>...

Runs ONE call for the whole wave:
  transition-issue.sh --batch <N>... --to plan-approved --from <label> [--comment <text>]
--from defaults to plan-reviewed. Emits transition-issue.sh's audit line per
issue:
  TRANSITION=ok|partial|failed issue=#<N> to=plan-approved from=<label> comment=<posted|skipped|failed>
Env: PIPELINE_REPO.
USAGE
}

FROM="plan-reviewed"
COMMENT=""
HAVE_COMMENT=0
ISSUES=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --from) FROM="${2:-}"; shift 2 ;;
    --comment) COMMENT="${2:-}"; HAVE_COMMENT=1; shift 2 ;;
    *) ISSUES+=("$1"); shift ;;
  esac
done

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_resolve-config.sh
[ -f "$SELF_DIR/_resolve-config.sh" ] && source "$SELF_DIR/_resolve-config.sh"

[ "${#ISSUES[@]}" -gt 0 ] || exit 0
if [ "$HAVE_COMMENT" = 1 ]; then
  bash "$SELF_DIR/transition-issue.sh" --batch "${ISSUES[@]}" --to plan-approved --from "$FROM" --comment "$COMMENT"
else
  bash "$SELF_DIR/transition-issue.sh" --batch "${ISSUES[@]}" --to plan-approved --from "$FROM"
fi
