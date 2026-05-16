#!/bin/bash
# Shared helper sourced by scripts/doctor.sh and scripts/migrate-from-subtree.sh.
# Maps pipeline-owned hook basenames to their capability-impact annotation
# string. A single annotation table seeded from the here-doc below is the
# single source of truth.
#
# Public API:
#   advisory_for_hook <basename>      echoes annotation, rc=0; empty + rc=1 if unknown
#   list_pipeline_hook_basenames      prints all known basenames, one per line

if [ -z "${__ADVISORY_TEXT_LOADED:-}" ]; then
  __ADVISORY_TEXT_LOADED=1

  declare -gA __ADVISORY_TABLE=()

  while IFS="|" read -r __k __v; do
    [ -z "$__k" ] && continue
    __ADVISORY_TABLE["$__k"]="$__v"
  done <<'TABLE'
block_deletions.py|capability preserved: plugin manifest registers ${CLAUDE_PLUGIN_ROOT}/hooks/block_deletions.py
enforce-base-branch.py|capability preserved: plugin manifest registers ${CLAUDE_PLUGIN_ROOT}/hooks/enforce-base-branch.py
check-ci-skip-markers.py|capability preserved: plugin manifest registers ${CLAUDE_PLUGIN_ROOT}/hooks/check-ci-skip-markers.py
enforce-path-c-delegation.py|capability preserved: plugin manifest registers ${CLAUDE_PLUGIN_ROOT}/hooks/enforce-path-c-delegation.py
restrict_paths.py|capability preserved: plugin manifest registers ${CLAUDE_PLUGIN_ROOT}/hooks/restrict_paths.py
enforce-ci-wait.py|capability preserved: plugin manifest registers ${CLAUDE_PLUGIN_ROOT}/hooks/enforce-ci-wait.py
log-tool-use.sh|HTS-dogfood-only, not part of the published plugin manifest — no functional change
log_subagent.py|HTS-dogfood-only, not part of the published plugin manifest — no functional change
TABLE
  unset __k __v
fi

advisory_for_hook() {
  local name="${1:-}"
  if [ -n "${__ADVISORY_TABLE[$name]+x}" ]; then
    printf "%s\n" "${__ADVISORY_TABLE[$name]}"
    return 0
  fi
  return 1
}

list_pipeline_hook_basenames() {
  local k
  for k in "${!__ADVISORY_TABLE[@]}"; do
    printf "%s\n" "$k"
  done
}
