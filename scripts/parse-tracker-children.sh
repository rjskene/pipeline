#!/bin/bash
# parse-tracker-children.sh — extract child issue numbers from a tracker
# body's `## Rollout sequence` checklist.
#
# Usage:
#   bash parse-tracker-children.sh <body-file>
#   bash parse-tracker-children.sh -                       # read from stdin
#   bash parse-tracker-children.sh <body-file>|- --fallback-mentions
#
# Prints one child issue number per line, in order of appearance, to stdout.
# Exits 0 always (including when no `## Rollout sequence` section is present
# or when the section contains no checklist children).
#
# Default mode recognizes lines matching `- [ ] **#<N> [-—]` (ASCII hyphen or
# en-dash), including the `[x]` checked variant. Bounded to the section starting
# with `## Rollout sequence` — optionally decorated with punctuation-separated
# trailing text (paren, dash, em-dash, colon; e.g. `## Rollout sequence (design
# approved … — spec: …)` or `## Rollout sequence - design approved`), which
# operators add naturally (#1157, #1164) — and ending at the next `## ` heading.
# A following word such as `appendix` (`## Rollout sequence appendix`) or a bare
# word continuation (`## Rollout sequencer`) is a DIFFERENT section, not the
# rollout section.
#
# `--fallback-mentions` mode (#491): ignores section bounds entirely and scans
# the WHOLE body for `#<N>` mentions — deduped, in order of first appearance,
# numeric only — suppressing fenced code blocks (``` … ```) and inline code
# spans (`…`) so prose examples like `#999` are not miscounted as children.
# This mode is additive and consumed ONLY by auto-close-trackers.sh as a soft
# fallback; the default mode is unchanged for render-status-table.sh and
# analyze-issues.sh, which MUST NOT broaden their orphan classification.
set -euo pipefail

FALLBACK=0
SOURCE=""
for arg in "$@"; do
  case "$arg" in
    --fallback-mentions) FALLBACK=1 ;;
    *) SOURCE="$arg" ;;
  esac
done

if [ -z "$SOURCE" ]; then
  echo "usage: parse-tracker-children.sh <body-file>|- [--fallback-mentions]" >&2
  exit 2
fi

if [ "$SOURCE" = "-" ]; then
  input=$(cat)
else
  input=$(cat "$SOURCE")
fi

if [ "$FALLBACK" = "1" ]; then
  printf '%s\n' "$input" | awk '
    /^[[:space:]]*```/ { in_code = !in_code; next }
    in_code { next }
    {
      line = $0
      gsub(/`[^`]*`/, "", line)
      while (match(line, /#[0-9]+/)) {
        num = substr(line, RSTART + 1, RLENGTH - 1)
        if (!(num in seen)) {
          seen[num] = 1
          print num
        }
        line = substr(line, RSTART + RLENGTH)
      }
    }
  '
else
  printf '%s\n' "$input" | awk '
    /^## Rollout sequence[[:space:]]*($|[^[:alnum:][:space:]])/ { inrs=1; next }
    /^## / { inrs=0 }
    inrs {
      if (match($0, /^- \[[ x]\] \*\*#[0-9]+[[:space:]]*[-—]/)) {
        tok = substr($0, RSTART, RLENGTH)
        sub(/^.*#/, "", tok)
        sub(/[^0-9].*$/, "", tok)
        print tok
      }
    }
  '
fi
