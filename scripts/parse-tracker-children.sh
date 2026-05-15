#!/bin/bash
# parse-tracker-children.sh — extract child issue numbers from a tracker
# body's `## Rollout sequence` checklist.
#
# Usage:
#   bash parse-tracker-children.sh <body-file>
#   bash parse-tracker-children.sh -          # read from stdin
#
# Prints one child issue number per line, in order of appearance, to stdout.
# Exits 0 always (including when no `## Rollout sequence` section is present
# or when the section contains no checklist children).
#
# Recognizes lines matching `- [ ] **#<N> [-—]` (ASCII hyphen or en-dash),
# including the `[x]` checked variant. Bounded to the section starting with
# `## Rollout sequence` and ending at the next `## ` heading.
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: parse-tracker-children.sh <body-file>|-" >&2
  exit 2
fi

if [ "$1" = "-" ]; then
  input=$(cat)
else
  input=$(cat "$1")
fi

printf '%s\n' "$input" | awk '
  /^## Rollout sequence[[:space:]]*$/ { inrs=1; next }
  /^## / { inrs=0 }
  inrs {
    if (match($0, /^- \[[ x]\] \*\*#([0-9]+)[[:space:]]*[-—]/, m)) {
      print m[1]
    }
  }
'
