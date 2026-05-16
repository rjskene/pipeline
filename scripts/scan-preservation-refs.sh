#!/bin/bash
# scripts/scan-preservation-refs.sh — enumerate consumer .claude/{scripts,hooks}/
# files that have a plugin counterpart, scan the project tree for references
# to each, classify, and emit:
#
#   REF\t<consumer_path>\t<ref_file>:<lineno>\t<ref_bucket>\t<snippet>
#   VERDICT\t<consumer_path>\t<DELETE|KEEP>\t<hint>
#
# ref_bucket ∈ {
#   active-wiring      — settings.json reference (and not bucket-C drift)
#   falls-away         — SKILL.md ref AND skill is plugin-shipped (will be removed)
#   consumer-skill-ref — SKILL.md ref AND skill is consumer-authored (NOT removed)
#   self-only          — only reference is inside the file itself
#   fork               — settings.json ref AND drift bucket = C
#   doc-ref            — any other .md/.txt source outside .claude/skills/*/SKILL.md
# }
#
# Caching: diff-consumer-files.sh is invoked ONCE at helper start and the
# per-path bucket cached for classify_ref lookups. Reused by doctor +
# migrate-from-subtree.
set -uo pipefail

plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$plugin_root" ] || [ ! -d "$plugin_root" ]; then
  echo "scan-preservation-refs: CLAUDE_PLUGIN_ROOT empty or not a directory" >&2
  exit 1
fi

# Build a basename lookup of plugin-shipped scripts/hooks. A consumer file
# enters the report only when its basename appears in this set (parity with
# diff-consumer-files.sh's basename-collision rule).
shipped_tmp="$(mktemp)"
trap 'rm -f "$shipped_tmp"' EXIT
for sub in scripts hooks; do
  if [ -d "$plugin_root/$sub" ]; then
    find "$plugin_root/$sub" -type f -printf '%f\n' 2>/dev/null
  fi
done | sort -u > "$shipped_tmp"

has_counterpart() { grep -qxF "$1" "$shipped_tmp"; }

# Walk consumer .claude/{scripts,hooks}/ and emit a placeholder VERDICT row
# per file with a plugin counterpart. REF rows + real verdict logic land in
# Tasks 3-4.
for sub in scripts hooks; do
  [ -d ".claude/$sub" ] || continue
  while IFS= read -r -d '' local_path; do
    local_path="${local_path#./}"
    bn="$(basename "$local_path")"
    has_counterpart "$bn" || continue
    printf 'VERDICT\t%s\tKEEP\tpending classification\n' "$local_path"
  done < <(find ".claude/$sub" -type f -print0 2>/dev/null)
done

exit 0
