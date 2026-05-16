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

# Per-bucket recommendation copy surfaced by doctor's consumer_drift summary
# table. Keep wording short — the SKILL.md taxonomy table carries the long form.
advisory_for_bucket() {
  case "${1:-}" in
    A)     printf "%s\n" "delete-local: byte-identical to plugin counterpart, safe to remove";;
    B)     printf "%s\n" "delete-local: plugin counterpart reads pipeline.config, local does not";;
    B.bug) printf "%s\n" "fail-active-bug: hardcoded literal in local disagrees with pipeline.config";;
    C)     printf "%s\n" "leave-flag-as-fork: local has functionality plugin no longer ships";;
    D)     printf "%s\n" "no-op: plugin-author dogfood only, not part of published manifest";;
    E)     printf "%s\n" "delete-local: retired tooling from a prior plugin version";;
    F)     printf "%s\n" "no-op: genuine consumer-owned file, no plugin counterpart";;
    *)     return 1;;
  esac
}

list_pipeline_hook_basenames() {
  local k
  for k in "${!__ADVISORY_TABLE[@]}"; do
    printf "%s\n" "$k"
  done
}

# Per-bucket annotation copy for the six reference-source buckets emitted by
# scripts/scan-preservation-refs.sh. Doctor's preservation_refs check uses
# these to annotate REF rows so the operator can see, per hit, why the file
# is still being preserved.
advisory_for_ref_source() {
  case "${1:-}" in
    active-wiring)      printf "%s\n" "live hook entry in .claude/settings.json; deletion breaks the hook chain";;
    falls-away)         printf "%s\n" "referenced only from a plugin-shipped SKILL.md slated for removal in this migration";;
    consumer-skill-ref) printf "%s\n" "held by consumer-authored skill; resolve manually";;
    self-only)          printf "%s\n" "referenced only from inside the file itself (--keep-referenced false-positive)";;
    fork)               printf "%s\n" "intentional consumer-maintained fork; plugin no longer ships an equivalent";;
    doc-ref)            printf "%s\n" "documentation reference; resolve manually post-migration";;
    *)                  return 1;;
  esac
}
