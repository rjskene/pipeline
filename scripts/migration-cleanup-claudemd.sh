#!/bin/bash
set -uo pipefail

# migration-cleanup-claudemd.sh — advisory scanner for pipeline-legacy content
# in consumer CLAUDE.md files. Pure detect-and-emit; never edits source files.

PROJECT_ROOT="$(pwd)"
REPORT=".claude/migration-cleanup-report-claudemd.txt"
PATCH=".claude/migration-cleanup-claudemd.patch"

[ -f pipeline.config ] && source ./pipeline.config 2>/dev/null || true

HEADER_FINDINGS=()
HEADER_CORROBORATION=()
PATHS_FINDINGS=()
CMDS_FINDINGS=()

# Per-file delete-line set + file-tracking for patch generation.
declare -A DELETE_LINES=()
declare -A FILES_WITH_FINDINGS=()

# Track section spans as "<file>|<start>|<end>"
SECTION_SPANS=()

REGEX_HEADER='^## (Pipeline|Claude Pipeline|Pipeline Setup)( |$)'
REGEX_PATHS='\.claude-pipeline/|subtree pull|(^|[[:space:]/])install\.sh'
REGEX_CMDS='(^|[^[:alnum:]:_/])/(plan-issue|evaluate-issue-plan|execute-issue-plan|evaluate-issue-pr|create-issues|classify-issue|worktree-sync)([^[:alnum:]_-]|$)'

# Is line $2 inside any flagged section span for file $1?
in_section() {
  local f="$1" n="$2"
  local span
  for span in "${SECTION_SPANS[@]:-}"; do
    [ -n "$span" ] || continue
    local sf="${span%%|*}"
    local rest="${span#*|}"
    local ss="${rest%%|*}"
    local se="${rest#*|}"
    if [ "$sf" = "$f" ] && [ "$n" -ge "$ss" ] && [ "$n" -le "$se" ]; then
      return 0
    fi
  done
  return 1
}

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
      SECTION_SPANS+=("$file|$lineno|$end")
      FILES_WITH_FINDINGS["$file"]=1
      local n
      for ((n=lineno; n<=end; n++)); do
        DELETE_LINES["$file|$n"]=1
      done
    fi
  done < <(grep -nE "$REGEX_HEADER" "$file" || true)

  # Pass 2: legacy paths anywhere, deduped against section spans.
  local m
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    local lno="${m%%:*}"
    in_section "$file" "$lno" && continue
    PATHS_FINDINGS+=("$file:$m")
    FILES_WITH_FINDINGS["$file"]=1
    DELETE_LINES["$file|$lno"]=1
  done < <(grep -nE "$REGEX_PATHS" "$file" || true)

  # Pass 3: deprecated unprefixed slash commands, deduped against section spans.
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    local lno="${m%%:*}"
    in_section "$file" "$lno" && continue
    CMDS_FINDINGS+=("$file:$m")
    FILES_WITH_FINDINGS["$file"]=1
    DELETE_LINES["$file|$lno"]=1
  done < <(grep -nE "$REGEX_CMDS" "$file" || true)
}

mkdir -p .claude

FILES_TO_SCAN=()
[ -f CLAUDE.md ] && FILES_TO_SCAN+=("CLAUDE.md")
if [ -n "${PIPELINE_CONTEXT_FILES:-}" ]; then
  for entry in $PIPELINE_CONTEXT_FILES; do
    [ "$entry" = "CLAUDE.md" ] && continue
    [ -f "$entry" ] || continue
    FILES_TO_SCAN+=("$entry")
  done
fi

for f in "${FILES_TO_SCAN[@]:-}"; do
  [ -n "$f" ] && scan_file "$f"
done

if [ ${#HEADER_FINDINGS[@]} -eq 0 ] \
   && [ ${#PATHS_FINDINGS[@]} -eq 0 ] \
   && [ ${#CMDS_FINDINGS[@]} -eq 0 ]; then
  exit 0
fi

{
  echo "CLAUDE.md pipeline-legacy cleanup advisory"
  echo ""
  if [ ${#HEADER_FINDINGS[@]} -gt 0 ]; then
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
  fi
  if [ ${#PATHS_FINDINGS[@]} -gt 0 ]; then
    echo "Legacy paths"
    echo "------------"
    for f in "${PATHS_FINDINGS[@]}"; do echo "$f"; done
    echo ""
  fi
  if [ ${#CMDS_FINDINGS[@]} -gt 0 ]; then
    echo "Deprecated slash commands"
    echo "-------------------------"
    for f in "${CMDS_FINDINGS[@]}"; do echo "$f"; done
    echo ""
  fi
} > "$REPORT"

# --- Patch generation ---
: > "$PATCH"
for file in "${!FILES_WITH_FINDINGS[@]}"; do
  dels=()
  for key in "${!DELETE_LINES[@]}"; do
    f="${key%|*}"
    n="${key#*|}"
    [ "$f" = "$file" ] && dels+=("$n")
  done
  [ ${#dels[@]} -eq 0 ] && continue
  csv=$(printf '%s\n' "${dels[@]}" | sort -n -u | paste -sd, -)
  cleaned=$(awk -v dels="$csv" 'BEGIN{n=split(dels,a,","); for(i=1;i<=n;i++)d[a[i]]=1} !(NR in d)' "$file")
  # Preserve trailing-newline behaviour: if cleaned is non-empty, append a newline.
  if [ -n "$cleaned" ]; then
    diff_out=$(diff -u "$file" <(printf '%s\n' "$cleaned") 2>/dev/null || true)
  else
    diff_out=$(diff -u "$file" /dev/null 2>/dev/null || true)
  fi
  [ -z "$diff_out" ] && continue
  rewritten=$(printf '%s\n' "$diff_out" | sed -e "1s|^--- .*|--- a/$file|" -e "2s|^+++ .*|+++ b/$file|")
  {
    echo "diff --git a/$file b/$file"
    printf '%s\n' "$rewritten"
  } >> "$PATCH"
done

[ -s "$PATCH" ] || rm -f "$PATCH"

exit 0
