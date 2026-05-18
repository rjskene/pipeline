#!/bin/bash
set -euo pipefail

# create-checkpoint-tag.sh — Create a local annotated git tag marking the
# state of the base branch after a pipeline cleanup batch.
#
# Usage:
#   bash .claude/scripts/create-checkpoint-tag.sh \
#       --issues "N1,N2,..." \
#       --prs "P1,P2,..." \
#       [--branch <branch>] \
#       [--dry-run]
#
# Tag name: checkpoint/YYYY-MM-DD-NN (NN auto-increments within a day).
# The tag is NEVER pushed to origin — it is a local-only rollback point.

_find_main_repo() {
  # Prefer explicit override (matches every other pipeline script's convention).
  if [ -n "${PIPELINE_PROJECT_ROOT:-}" ]; then
    if [ -f "$PIPELINE_PROJECT_ROOT/pipeline.config" ] && { [ -d "$PIPELINE_PROJECT_ROOT/.git" ] || [ -f "$PIPELINE_PROJECT_ROOT/.git" ]; }; then
      printf '%s' "$PIPELINE_PROJECT_ROOT"
      return 0
    fi
    echo "ERROR: PIPELINE_PROJECT_ROOT=$PIPELINE_PROJECT_ROOT does not contain both pipeline.config and a .git/ entry" >&2
    return 1
  fi
  # Fallback: walk up from the script location looking for a directory that
  # holds BOTH pipeline.config AND a .git/ entry (file or dir — git worktrees
  # use a regular file). The combined check rejects the plugin tree's own
  # pipeline.config (which lives outside any git checkout the script cares about).
  local dir
  dir="$(cd "$(dirname "$0")" && pwd)"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/pipeline.config" ] && { [ -d "$dir/.git" ] || [ -f "$dir/.git" ]; }; then
      printf '%s' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  echo "ERROR: could not locate consumer repo (need both pipeline.config and .git/) walking up from $(dirname "$0") to /; set PIPELINE_PROJECT_ROOT to override" >&2
  return 1
}
MAIN_REPO="$(_find_main_repo)" || exit 1
CONFIG_FILE="$MAIN_REPO/pipeline.config"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: pipeline.config not found at $CONFIG_FILE" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

ISSUES=""
PRS=""
BRANCH=""
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --issues)  ISSUES="$2"; shift 2 ;;
    --prs)     PRS="$2";    shift 2 ;;
    --branch)  BRANCH="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      sed -n '3,15p' "$0"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

BRANCH="${BRANCH:-${PIPELINE_BASE_BRANCH}}"

if [ -z "$ISSUES" ] && [ -z "$PRS" ]; then
  echo "ERROR: must pass --issues and/or --prs (got neither)" >&2
  exit 1
fi

cd "$MAIN_REPO"

if git status --porcelain | grep -v '^??' | grep -q .; then
  echo "ERROR: working tree has uncommitted tracked changes — refusing to switch branches for tagging" >&2
  git status --short >&2
  exit 1
fi

if git remote get-url origin >/dev/null 2>&1; then
  git fetch origin "$BRANCH" --quiet 2>/dev/null || true
fi

if [ "$(git rev-parse --abbrev-ref HEAD)" != "$BRANCH" ]; then
  git checkout --quiet "$BRANCH"
fi

if git remote get-url origin >/dev/null 2>&1; then
  git pull --ff-only --quiet origin "$BRANCH" 2>/dev/null || true
fi

DATE=$(date +%Y-%m-%d)

MAX_NN=0
while IFS= read -r existing_tag; do
  [ -z "$existing_tag" ] && continue
  suffix=${existing_tag##checkpoint/${DATE}-}
  # strip anything after digits (defensive)
  suffix=$(printf '%s' "$suffix" | sed 's/[^0-9].*//')
  [ -z "$suffix" ] && continue
  n=$((10#$suffix))
  if [ "$n" -gt "$MAX_NN" ]; then
    MAX_NN="$n"
  fi
done < <(git tag --list "checkpoint/${DATE}-*")

NN=$(printf "%02d" $((MAX_NN + 1)))
TAG="checkpoint/${DATE}-${NN}"

fmt_nums() {
  local raw="$1"
  if [ -z "$raw" ]; then
    printf '(none)'
    return
  fi
  printf '%s' "$raw" | awk -F',' '{
    out = ""
    for (i = 1; i <= NF; i++) {
      n = $i
      gsub(/^ +| +$/, "", n)
      if (n == "") continue
      if (out == "") out = "#" n
      else out = out ", #" n
    }
    if (out == "") out = "(none)"
    printf "%s", out
  }'
}

ISSUES_FMT=$(fmt_nums "$ISSUES")
PRS_FMT=$(fmt_nums "$PRS")
HEAD_SHORT=$(git rev-parse --short HEAD)

BODY=$(cat <<EOF
Checkpoint after pipeline cleanup on ${DATE}.

Issues: ${ISSUES_FMT}
PRs:    ${PRS_FMT}

Base branch: ${BRANCH}
HEAD: ${HEAD_SHORT}
EOF
)

if $DRY_RUN; then
  echo "DRY RUN: would create tag ${TAG}"
  echo "--- annotation body ---"
  echo "$BODY"
  exit 0
fi

git tag -a "$TAG" -m "$BODY"
echo "Created local tag: ${TAG}"
echo "To push manually: git push origin ${TAG}"
