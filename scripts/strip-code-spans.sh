#!/bin/bash
# strip-code-spans.sh — suppress markdown code from a body so callers scan
# prose only (#1500).
#
# Usage:
#   printf '%s\n' "$BODY" | bash strip-code-spans.sh
#   bash strip-code-spans.sh --help
#
# Reads stdin, writes stdout. A line whose first non-blank characters are a
# triple-backtick fence toggles code mode and is dropped; lines inside a
# fenced block are dropped (an unterminated fence drops to EOF); on every
# other line single-backtick inline spans are removed and the rest of the
# line is printed. Line structure is otherwise preserved, so per-line
# consumers keep working. POSIX awk only (mawk-safe, #800).
#
# Consumers: parse-tracker-children.sh --fallback-mentions, and the
# MARKER-PARSE / HINT-PARSE blocks in skills/plan-issue/references/classification.md.
set -euo pipefail

usage() {
  echo "usage: strip-code-spans.sh [--help]  (reads stdin, writes stdout)"
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

awk '
  /^[[:space:]]*```/ { in_code = !in_code; next }
  in_code { next }
  {
    line = $0
    gsub(/`[^`]*`/, "", line)
    print line
  }
'
