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

if [ "$LABELS_OVERRIDDEN" -eq 1 ]; then
  LABELS_RAW="$LABELS_OVERRIDE"
else
  LABELS_RAW=$(gh issue view "$N" --repo "$PIPELINE_REPO" --json labels --jq '[.labels[].name] | join(",")')
fi

# Normalize labels into a comma-bounded string for whole-token matching.
LABELS_NORM=$(printf '%s' "$LABELS_RAW" | tr ' ' ',' | tr -s ',')
LABELS_NORM=",${LABELS_NORM},"

has_label() {
  [[ "$LABELS_NORM" == *",$1,"* ]]
}

refuse_tracker() {
  echo "Issue #$N is a tracker (epic title); trackers don't get PRs. Close the issue or rename it." >&2
  exit 2
}

# Tracker refusal — `tracker` label or epic(...) title prefix.
if has_label "tracker"; then
  refuse_tracker
fi
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

normalize_scope() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9_-]/-/g; s/^-*//; s/-*$//'
}

# bug(<scope>): <rest> → fix(<normalized-scope>): <rest>
if [[ "$TITLE" =~ ^bug\(([^\)]+)\):[[:space:]]+(.+)$ ]]; then
  scope=$(normalize_scope "${BASH_REMATCH[1]}")
  rest="${BASH_REMATCH[2]}"
  printf 'fix(%s): %s\n' "$scope" "$rest"
  exit 0
fi

# No rule matched yet — later tasks extend this.
exit 1
