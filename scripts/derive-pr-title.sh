#!/usr/bin/env bash
# derive-pr-title — convert a GitHub issue title + label set into a strict
# Conventional-Commits PR title. Used by skills/execute-issue-plan when
# opening a PR so release-please can drive versioning + CHANGELOG without a
# late-stage rewording step. See issue #56 for the rule rationale.
#
# Usage: derive-pr-title.sh <issue-number> [--title-override <str>]
#                                          [--labels-override <comma-or-space-list>]
#
# The overrides are for unit testing; in production the helper fetches title
# and labels via `gh issue view "$N" --repo "$PIPELINE_REPO" --json title,labels`.
#
# Exit 0: derived PR title written to stdout.
# Exit 2: issue is a tracker (epic) — refusal message on stderr, stdout empty.
set -euo pipefail

N="${1:-}"
if [ -z "$N" ]; then
  echo "usage: derive-pr-title.sh <issue-number> [--title-override <str>] [--labels-override <list>]" >&2
  exit 64
fi
shift || true

TITLE_OVERRIDE=""
LABELS_OVERRIDE=""
TITLE_OVERRIDDEN=0
LABELS_OVERRIDDEN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --title-override)
      TITLE_OVERRIDE="${2:-}"
      TITLE_OVERRIDDEN=1
      shift 2
      ;;
    --labels-override)
      LABELS_OVERRIDE="${2:-}"
      LABELS_OVERRIDDEN=1
      shift 2
      ;;
    *)
      echo "derive-pr-title: unknown argument '$1'" >&2
      exit 64
      ;;
  esac
done

if [ "$TITLE_OVERRIDDEN" -eq 1 ]; then
  TITLE="$TITLE_OVERRIDE"
else
  TITLE=$(gh issue view "$N" --repo "$PIPELINE_REPO" --json title --jq '.title')
fi

refuse_tracker() {
  echo "Issue #$N is a tracker (epic title); trackers don't get PRs. Close the issue or rename it." >&2
  exit 2
}

# Tracker refusal — epic(...) issues track other issues and never get PRs.
if [[ "$TITLE" =~ ^epic\( ]]; then
  refuse_tracker
fi

# Conventional-commits passthrough — keep this regex in sync with
# .github/workflows/pr-title-check.yml and skills/run/SKILL.md merge gate.
CC_RE='^(feat|fix|chore|refactor|docs|ci|perf|test|build|style|revert)(\([a-z0-9_-]+\))?!?: .+'
if [[ "$TITLE" =~ $CC_RE ]]; then
  printf '%s\n' "$TITLE"
  exit 0
fi

# No rule matched yet — later tasks extend this.
exit 1
