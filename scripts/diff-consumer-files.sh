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
#            D      plugin-dogfood-only basename            -> no-op
#            F      no plugin counterpart                   -> no-op
#          (B/B.bug/C/E added in later tasks.)
#
# Stateless: emits stdout, never mutates.

set -uo pipefail

# Source pipeline.config (if present) so PIPELINE_REPO / PIPELINE_WORKTREE_PREFIX
# / PIPELINE_TMUX_SESSION are available to the B.bug runtime-mismatch check.
# Missing config is non-fatal — buckets that don't need it still classify.
if [ -f ./pipeline.config ]; then
  # shellcheck disable=SC1091
  source ./pipeline.config 2>/dev/null || true
fi

plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$plugin_root" ] || [ ! -d "$plugin_root" ]; then
  echo "diff-consumer-files: CLAUDE_PLUGIN_ROOT empty or not a directory" >&2
  exit 1
fi

# Build two basename lookup tables:
#   shipped_tmp:  basename\tpath   (plugin's top-level scripts|hooks|agents)
#   dogfood_tmp:  basename\tpath   (plugin's $CLAUDE_PLUGIN_ROOT/.claude/* — author dogfood)
shipped_tmp="$(mktemp)"
dogfood_tmp="$(mktemp)"
trap 'rm -f "$shipped_tmp" "$dogfood_tmp"' EXIT

for sub in scripts hooks agents; do
  if [ -d "$plugin_root/$sub" ]; then
    find "$plugin_root/$sub" -type f -printf '%f\t%p\n' 2>/dev/null
  fi
done > "$shipped_tmp"

if [ -d "$plugin_root/.claude" ]; then
  find "$plugin_root/.claude" -type f -printf '%f\t%p\n' 2>/dev/null > "$dogfood_tmp"
fi

lookup_path() {
  awk -F'\t' -v b="$1" '$1==b{print $2; exit}' "$2"
}

# Walk consumer .claude/{scripts,hooks,agents}/ and classify each file.
for sub in scripts hooks agents; do
  [ -d ".claude/$sub" ] || continue
  while IFS= read -r -d '' local_path; do
    bn="$(basename "$local_path")"
    local_loc="$(wc -l < "$local_path" | tr -d ' ')"

    shipped_path="$(lookup_path "$bn" "$shipped_tmp")"
    if [ -n "$shipped_path" ]; then
      plugin_loc="$(wc -l < "$shipped_path" | tr -d ' ')"
      if cmp -s "$local_path" "$shipped_path"; then
        printf '%s\tA\t%s\t%s\t0\tdelete-local\n' "$local_path" "$local_loc" "$plugin_loc"
      else
        diff_lines="$(diff --unified=0 "$local_path" "$shipped_path" 2>/dev/null \
          | grep -cE '^[+-][^+-]' || true)"
        bucket="?"
        action="needs-classification"

        # Bucket C heuristic (checked FIRST per tie-break: prefer C over B):
        # local references any function name or --flag token that grep cannot
        # find in the plugin counterpart. Conservative — flagged for human.
        c_tokens="$(
          { grep -oE '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)' "$local_path" 2>/dev/null \
              | sed -E 's/[[:space:]]*\(\).*//; s/^[[:space:]]+//';
            grep -oE -- '--[a-zA-Z][a-zA-Z0-9_-]+' "$local_path" 2>/dev/null;
          } | sort -u
        )"
        c_missing=0
        if [ -n "$c_tokens" ]; then
          while IFS= read -r tok; do
            [ -z "$tok" ] && continue
            if ! grep -qF -- "$tok" "$shipped_path" 2>/dev/null; then
              c_missing=1
              break
            fi
          done <<< "$c_tokens"
        fi

        if [ "$c_missing" = "1" ]; then
          bucket="C"
          action="leave-flag-as-fork"
        else
          # Bucket B heuristic: plugin counterpart reads pipeline.config (any of
          # three idioms) AND local does not — plugin is strictly more capable.
          plugin_reads_config=0
          local_reads_config=0
          if grep -qE 'source.*pipeline\.config|_resolve-plugin-root\.sh|_pipeline_config' \
               "$shipped_path" 2>/dev/null; then
            plugin_reads_config=1
          fi
          if grep -qE 'source.*pipeline\.config|_resolve-plugin-root\.sh|_pipeline_config' \
               "$local_path" 2>/dev/null; then
            local_reads_config=1
          fi
          if [ "$plugin_reads_config" = "1" ] && [ "$local_reads_config" = "0" ]; then
            bucket="B"
            action="delete-local"
            # Escalate to B.bug if any hardcoded PIPELINE_* literal in the local
            # file disagrees with the runtime value sourced from pipeline.config.
            for var in PIPELINE_REPO PIPELINE_WORKTREE_PREFIX PIPELINE_TMUX_SESSION; do
              runtime_val="$(eval "printf '%s' \"\${$var:-}\"")"
              [ -z "$runtime_val" ] && continue
              literal="$(grep -oE "${var}[[:space:]]*=[[:space:]]*[\"'][^\"']+[\"']" \
                         "$local_path" 2>/dev/null \
                         | head -1 \
                         | sed -E "s/.*[\"']([^\"']+)[\"'].*/\1/")"
              if [ -n "$literal" ] && [ "$literal" != "$runtime_val" ]; then
                bucket="B.bug"
                action="fail-active-bug"
                break
              fi
            done
          fi
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$local_path" "$bucket" "$local_loc" "$plugin_loc" "$diff_lines" "$action"
      fi
      continue
    fi

    dogfood_path="$(lookup_path "$bn" "$dogfood_tmp")"
    if [ -n "$dogfood_path" ]; then
      plugin_loc="$(wc -l < "$dogfood_path" | tr -d ' ')"
      printf '%s\tD\t%s\t%s\t0\tno-op\n' "$local_path" "$local_loc" "$plugin_loc"
      continue
    fi

    printf '%s\tF\t%s\t0\t0\tno-op\n' "$local_path" "$local_loc"
  done < <(find ".claude/$sub" -type f -print0 2>/dev/null)
done
