#!/bin/bash
# scripts/diff-consumer-files.sh — classify consumer-side .claude/{scripts,hooks,agents}/
# files vs plugin-shipped counterparts. Reused by doctor.sh's `consumer_drift` check
# and by migrate-from-subtree.sh (drift preview before deletion).
#
# Input:   none (walks $(pwd)/.claude/{scripts,hooks,agents}/ relative to CWD)
# Env:     CLAUDE_PLUGIN_ROOT — plugin install root containing scripts/, hooks/, agents/.
# Output:  one row per consumer file, tab-separated:
#            <path>\t<bucket>\t<local_loc>\t<plugin_loc>\t<diff_lines>\t<action>
#          Buckets:
#            A      byte-identical                          -> delete-local
#            (more buckets added in later tasks)
#
# Stateless: emits stdout, never mutates.

set -uo pipefail

plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$plugin_root" ] || [ ! -d "$plugin_root" ]; then
  echo "diff-consumer-files: CLAUDE_PLUGIN_ROOT empty or not a directory" >&2
  exit 1
fi

# Build plugin-shipped basename allow-list (top-level scripts/, hooks/, agents/ ONLY —
# files under $plugin_root/.claude/ are plugin-author dogfood and not "shipped").
allow_tmp="$(mktemp)"
trap 'rm -f "$allow_tmp"' EXIT
for sub in scripts hooks agents; do
  if [ -d "$plugin_root/$sub" ]; then
    find "$plugin_root/$sub" -type f -printf '%f\t%p\n' 2>/dev/null
  fi
done > "$allow_tmp"

# Walk consumer .claude/{scripts,hooks,agents}/ — for every file whose basename
# matches a plugin-shipped basename, classify and emit a row.
for sub in scripts hooks agents; do
  [ -d ".claude/$sub" ] || continue
  while IFS= read -r -d '' local_path; do
    bn="$(basename "$local_path")"
    plugin_path="$(awk -F'\t' -v b="$bn" '$1==b{print $2; exit}' "$allow_tmp")"
    [ -z "$plugin_path" ] && continue
    if cmp -s "$local_path" "$plugin_path"; then
      local_loc="$(wc -l < "$local_path" | tr -d ' ')"
      plugin_loc="$(wc -l < "$plugin_path" | tr -d ' ')"
      printf '%s\tA\t%s\t%s\t0\tdelete-local\n' "$local_path" "$local_loc" "$plugin_loc"
    fi
  done < <(find ".claude/$sub" -type f -print0 2>/dev/null)
done
