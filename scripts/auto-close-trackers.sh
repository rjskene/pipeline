#!/bin/bash
# auto-close-trackers.sh — scan open `tracker`-labelled issues; if every child
# referenced in the tracker's `## Rollout sequence` checklist is in state
# CLOSED, optionally close the tracker.
#
# Usage:
#   bash auto-close-trackers.sh [--apply] [--repo <owner/repo>]
#
# Status lines emitted to stdout (one per open tracker):
#   STATUS: all-closed  tracker=<N> children=<csv>
#   STATUS: pending     tracker=<N> open=<csv>
#   STATUS: no-children tracker=<N>
#
# When --apply is set AND status is all-closed, runs `gh issue close <N>`
# with the comment `Auto-closed: all children merged.` and emits
#   CLOSED: tracker=<N>
#
# Repo resolution: $PIPELINE_REPO env (or --repo flag) is required.
set -euo pipefail

APPLY=0
REPO="${PIPELINE_REPO:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --repo)  REPO="$2"; shift 2 ;;
    *) echo "auto-close-trackers.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$REPO" ]; then
  echo "auto-close-trackers.sh: PIPELINE_REPO (or --repo) is required" >&2
  exit 2
fi

# Enumerate open tracker issue numbers.
trackers=$(gh issue list --repo "$REPO" --label tracker --state open \
             --json number --jq '.[].number') || trackers=""

[ -z "$trackers" ] && exit 0

for tracker in $trackers; do
  body=$(gh issue view "$tracker" --repo "$REPO" --json body --jq .body) || body=""

  # Parse children from the `## Rollout sequence` section via the shared
  # helper so the run-skill grouped status renderer and this script share
  # one parser implementation.
  children=$(printf '%s\n' "$body" | bash "$(dirname "$0")/parse-tracker-children.sh" -)

  if [ -z "$children" ]; then
    echo "STATUS: no-children tracker=$tracker"
    continue
  fi

  open_children=""
  csv=""
  for c in $children; do
    csv="${csv:+$csv,}$c"
    state=$(gh issue view "$c" --repo "$REPO" --json state --jq .state) || state="OPEN"
    if [ "$state" != "CLOSED" ]; then
      open_children="${open_children:+$open_children,}$c"
    fi
  done

  if [ -z "$open_children" ]; then
    echo "STATUS: all-closed tracker=$tracker children=$csv"
    if [ "$APPLY" = "1" ]; then
      gh issue close "$tracker" --repo "$REPO" \
        --comment "Auto-closed: all children merged."
      echo "CLOSED: tracker=$tracker"
    fi
  else
    echo "STATUS: pending tracker=$tracker open=$open_children"
  fi
done
