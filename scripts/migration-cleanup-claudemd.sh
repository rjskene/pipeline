#!/bin/bash
set -uo pipefail

# migration-cleanup-claudemd.sh — advisory scanner for pipeline-legacy content
# in consumer CLAUDE.md files. Pure detect-and-emit; never edits source files.

PROJECT_ROOT="$(pwd)"
REPORT=".claude/migration-cleanup-report-claudemd.txt"

[ -f pipeline.config ] && source ./pipeline.config 2>/dev/null || true

HEADER_FINDINGS=()
HEADER_CORROBORATION=()

REGEX_HEADER='^## (Pipeline|Claude Pipeline|Pipeline Setup)( |$)'
REGEX_PATHS='\.claude-pipeline/|subtree pull|(^|[[:space:]/])install\.sh'

section_end_line() {
  local start="$1" file="$2"
  awk -v s="$start" '
    NR == s { next }
    NR > s && /^## / { print NR - 1; found=1; exit }
    END { if (!found) print NR }
  ' "$file"
}

scan_file() {
  local file="$1"
  [ -f "$file" ] || return 0

  local hdr_line
  while IFS= read -r hdr_line; do
    [ -n "$hdr_line" ] || continue
    local lineno="${hdr_line%%:*}"
    local rest="${hdr_line#*:}"
    local end
    end=$(section_end_line "$lineno" "$file")
    [ -z "$end" ] && end="$lineno"

    local section_body
    section_body=$(awk -v s="$lineno" -v e="$end" 'NR >= s && NR <= e' "$file")
    local corroboration
    corroboration=$(printf '%s\n' "$section_body" | grep -nE "$REGEX_PATHS" || true)
    if [ -n "$corroboration" ]; then
      HEADER_FINDINGS+=("$file:$lineno: $rest")
      local indented
      indented=$(printf '%s\n' "$corroboration" | sed 's/^/    /')
      HEADER_CORROBORATION+=("$indented")
    fi
  done < <(grep -nE "$REGEX_HEADER" "$file" || true)
}

mkdir -p .claude

if [ -f CLAUDE.md ]; then
  scan_file CLAUDE.md
fi

if [ ${#HEADER_FINDINGS[@]} -eq 0 ]; then
  exit 0
fi

{
  echo "CLAUDE.md pipeline-legacy cleanup advisory"
  echo ""
  echo "Section headers"
  echo "---------------"
  i=0
  while [ "$i" -lt "${#HEADER_FINDINGS[@]}" ]; do
    echo "${HEADER_FINDINGS[$i]}"
    echo "  corroborated by:"
    printf '%s\n' "${HEADER_CORROBORATION[$i]}"
    i=$((i + 1))
  done
  echo ""
} > "$REPORT"

exit 0
