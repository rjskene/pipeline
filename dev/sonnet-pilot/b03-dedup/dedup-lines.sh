#!/usr/bin/env bash
# dedup-lines.sh — print file lines with duplicates removed, preserving first-occurrence order
# Usage: dedup_preserve_order <file>
#        bash dedup-lines.sh <file>
set -euo pipefail

dedup_preserve_order() {
  local file="$1"

  # Empty file -> empty output, exit 0
  if [ ! -s "$file" ]; then
    return 0
  fi

  # Whitespace-only file -> empty output, exit 0
  # grep -v matches lines with at least one non-whitespace character
  if ! grep -qE '[^[:space:]]' "$file"; then
    return 0
  fi

  # Use awk to preserve first-occurrence order while deduplicating
  awk '!seen[$0]++' "$file"
}

# When sourced, expose the function. When run directly, call it with args.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [ $# -ne 1 ]; then
    echo "Usage: $0 <file>" >&2
    exit 1
  fi
  dedup_preserve_order "$1"
fi
