#!/bin/bash
set -euo pipefail
shopt -s nullglob

# migrate-from-subtree.sh — one-shot migration for consumers who installed
# the pipeline via the legacy subtree + install.sh path. Removes every
# pipeline-managed file we can identify, leaves user-authored files alone.
#
# Run from the consumer project root:
#   bash scripts/migrate-from-subtree.sh [--keep-referenced] [--dry-run] \
#                                        [--assume-yes|--assume-no] \
#                                        [--patch settings]
#
# --keep-referenced: before deleting under .claude/scripts/ or .claude/hooks/,
#   scan the project tree (*.md, *.sh, *.py, *.json) for references to those
#   basenames in their .claude/{scripts,hooks}/<name> form and preserve any
#   that are still referenced. Default behavior (no flag) still deletes on
#   match but emits a NOTE block listing the dangling references so the
#   consumer knows to update their docs.
#
# Idempotent: re-running on an already-migrated project is a no-op.
# Fails closed: detection runs to completion before any rm, so a glob error
# aborts the script (set -e) before mutating the filesystem.

PROJECT_ROOT="$(pwd)"
cd "$PROJECT_ROOT"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_advisory-text.sh"

MODE=full
DRY_RUN=false
ASSUME=""   # ""|yes|no — overrides interactive prompt when set
KEEP_REFERENCED=false
while [ $# -gt 0 ]; do
  case "$1" in
    --patch)
      if [ "${2:-}" = "settings" ]; then
        MODE=patch_settings
        shift 2
        continue
      fi
      echo "migrate-from-subtree: --patch requires 'settings' argument" >&2
      exit 2
      ;;
    --dry-run) DRY_RUN=true; shift ;;
    --assume-yes) ASSUME=yes; shift ;;
    --assume-no)  ASSUME=no;  shift ;;
    --keep-referenced) KEEP_REFERENCED=true; shift ;;
    --help|-h)
      cat <<'USAGE'
Usage: migrate-from-subtree.sh [--keep-referenced] [--dry-run] [--assume-yes|--assume-no] [--patch settings]
  --keep-referenced Preserve .claude/scripts/ and .claude/hooks/ files that are
                    still referenced from the project tree (advisory NOTE block
                    is always emitted; this flag turns it into protection).
  --dry-run        Print what would be deleted and why; no filesystem mutations.
  --assume-yes     Auto-answer "y" to every interactive prompt (CI/scripted use).
  --assume-no      Auto-answer "n" to every interactive prompt (preserve everything).
USAGE
      exit 0
      ;;
    *)
      echo "migrate-from-subtree: unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

# --- Plugin-root self-resolve (defensive fallback for #174) ---
# When CLAUDE_PLUGIN_ROOT is not exported into the Bash subshell, fall back to
# the highest-version directory under the user's plugin cache. Fail-open: if
# resolution fails, basename-match detection (added below) silently skips.
resolve_plugin_root() {
  [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -d "$CLAUDE_PLUGIN_ROOT/skills" ] && return 0
  local cache_root="$HOME/.claude/plugins/cache/claude-pipeline/pipeline"
  [ -d "$cache_root" ] || return 1
  local latest
  latest=$(ls -1 "$cache_root" 2>/dev/null | sort -V | tail -n 1)
  [ -n "$latest" ] || return 1
  [ -d "$cache_root/$latest/skills" ] || return 1
  export CLAUDE_PLUGIN_ROOT="$cache_root/$latest"
  echo "[migrate] resolved CLAUDE_PLUGIN_ROOT=$CLAUDE_PLUGIN_ROOT" >&2
  return 0
}
resolve_plugin_root || true

# --- Detection phase: build removal arrays without mutating anything ---

TO_REMOVE_SKILLS=()
TO_REMOVE_AGENTS=()
TO_REMOVE_SCRIPTS=()
TO_REMOVE_HOOKS=()
PIPELINE_HOOK_NAMES=()

# Skills: one dir-level marker per managed skill
for marker in .claude/skills/*/.pipeline-managed; do
  [ -f "$marker" ] || continue
  TO_REMOVE_SKILLS+=("$(dirname "$marker")")
done

# Agents: per-file marker at .claude/agents/.<name>.pipeline-managed
for marker in .claude/agents/.*.pipeline-managed; do
  [ -f "$marker" ] || continue
  base="${marker#.claude/agents/.}"
  base="${base%.pipeline-managed}.md"
  TO_REMOVE_AGENTS+=("$marker" ".claude/agents/$base")
done

# Scripts/hooks: no marker — enumerate basenames from .claude-pipeline/ if
# present. If .claude-pipeline/ has already been removed, skip script/hook
# enumeration entirely (consumer-owned files in .claude/scripts and
# .claude/hooks are preserved by default in that case).
#
# Note: the `${name%.template}` strip on lines 118/124 is correct ONLY for
# the subtree-migrated install path (when .claude-pipeline/ exists). Fresh
# `/plugin install` consumers without subtree history rely on doctor.sh's
# `consumer-required` classification (skill_files_residual + --fix residual)
# to recognize rendered scripts from plugin scripts/*.template files. The
# architectural resolution (rendering at install time or rewriting plugin
# skills to invoke ${CLAUDE_PLUGIN_ROOT}/scripts/) is tracked in #215.
if [ -d .claude-pipeline ]; then
  for src in .claude-pipeline/scripts/*; do
    [ -f "$src" ] || continue
    name="$(basename "$src")"
    name="${name%.template}"
    [ -f ".claude/scripts/$name" ] && TO_REMOVE_SCRIPTS+=(".claude/scripts/$name")
  done
  for src in .claude-pipeline/hooks/*; do
    [ -f "$src" ] || continue
    name="$(basename "$src")"
    name="${name%.template}"
    PIPELINE_HOOK_NAMES+=("$name")
    [ -f ".claude/hooks/$name" ] && TO_REMOVE_HOOKS+=(".claude/hooks/$name")
  done
fi

# Plugin-only consumers (#215): when .claude-pipeline/ is absent but the
# consumer still carries stale .claude/scripts/<name>.sh copies preserved
# across the move to the plugin install model, enumerate basenames from
# $CLAUDE_PLUGIN_ROOT/scripts/*.sh (plain only — exclude any leftover
# .template) and queue any matching consumer copy for removal. Silently
# skips when CLAUDE_PLUGIN_ROOT did not resolve.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] \
   && [ -d "$CLAUDE_PLUGIN_ROOT/scripts" ] \
   && [ -d .claude/scripts ]; then
  for src in "$CLAUDE_PLUGIN_ROOT"/scripts/*.sh; do
    [ -f "$src" ] || continue
    name="$(basename "$src")"
    # Skip if we already queued this basename via the .claude-pipeline/ pass.
    already=false
    for q in "${TO_REMOVE_SCRIPTS[@]:-}"; do
      [ "${q:-}" = ".claude/scripts/$name" ] && already=true && break
    done
    [ "$already" = true ] && continue
    [ -f ".claude/scripts/$name" ] && TO_REMOVE_SCRIPTS+=(".claude/scripts/$name")
  done
fi

# Detect pipeline-hook references in .claude/settings.json. Two signals:
#   1. Hook basenames enumerated from .claude-pipeline/hooks/ (when present).
#   2. Path-fragment match on ".claude/hooks/" — catches consumers who have
#      already deleted .claude-pipeline/ but still carry hook entries in
#      settings.json (residual injection from the abandoned auto-merge path
#      in #4). Pure text grep; settings.json itself is never mutated.
SETTINGS_FILE=".claude/settings.json"
SETTINGS_REPORT=".claude/settings.json.pipeline-migration-report.txt"
SETTINGS_HAS_INJECTIONS=false
declare -A SETTINGS_MATCH_LINES=()
if [ -f "$SETTINGS_FILE" ]; then
  collect_matches() {
    local pat="$1"
    while IFS= read -r line; do
      [ -n "$line" ] && SETTINGS_MATCH_LINES["$line"]=1
    done < <(grep -n -F "$pat" "$SETTINGS_FILE" 2>/dev/null || true)
  }
  for name in "${PIPELINE_HOOK_NAMES[@]:-}"; do
    [ -n "$name" ] && collect_matches "$name"
  done
  collect_matches ".claude/hooks/"
  if [ ${#SETTINGS_MATCH_LINES[@]} -gt 0 ]; then
    SETTINGS_HAS_INJECTIONS=true
  fi
fi

# --- Basename-match detection (gap-filling the marker-only gate) ---
# Markers cover skill dirs created since #98, but earlier consumer installs
# of plugin-managed skills/agents have no marker. Cross-reference consumer
# .claude/skills/ and .claude/agents/ basenames against the plugin's
# shipped basenames. Silently skip when CLAUDE_PLUGIN_ROOT is unresolved.

TO_PROMPT_SKILLS=()
TO_PROMPT_AGENTS=()
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -d "$CLAUDE_PLUGIN_ROOT/skills" ]; then
  declare -A PLUGIN_SKILL_SET=()
  for d in "$CLAUDE_PLUGIN_ROOT"/skills/*/; do
    [ -d "$d" ] || continue
    PLUGIN_SKILL_SET["$(basename "$d")"]=1
  done
  declare -A PLUGIN_AGENT_SET=()
  if [ -d "$CLAUDE_PLUGIN_ROOT/agents" ]; then
    for f in "$CLAUDE_PLUGIN_ROOT"/agents/*.md; do
      [ -f "$f" ] || continue
      PLUGIN_AGENT_SET["$(basename "$f" .md)"]=1
    done
  fi
  for d in .claude/skills/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    [ "${PLUGIN_SKILL_SET[$name]:-}" = 1 ] || continue
    already=false
    for q in "${TO_REMOVE_SKILLS[@]}"; do
      [ "$q" = "${d%/}" ] && already=true && break
    done
    [ "$already" = true ] && continue
    TO_PROMPT_SKILLS+=("${d%/}")
  done
  for f in .claude/agents/*.md; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .md)"
    [ "${PLUGIN_AGENT_SET[$name]:-}" = 1 ] || continue
    [ -f ".claude/agents/.${name}.pipeline-managed" ] && continue
    TO_PROMPT_AGENTS+=("$f")
  done
fi

# --- Dangling-reference scan (scripts/hooks removals only) ---
# Before deleting anything under .claude/scripts/ or .claude/hooks/, grep the
# project tree for references to those paths in their consumer-form
# (.claude/scripts/<name> or .claude/hooks/<name>). Emit an advisory NOTE
# block to stdout listing dangling refs. With --keep-referenced, also drop
# the referenced entries from the removal arrays so the files survive.
#
# Read-only against the project tree. Never mutates .claude/.
REFERENCED_BASENAMES=()
declare -A REFERENCED_HITS=()
if [ ${#TO_REMOVE_SCRIPTS[@]} -gt 0 ] || [ ${#TO_REMOVE_HOOKS[@]} -gt 0 ]; then
  # Delegate to scan-preservation-refs.sh — the single source of truth for
  # "which references hold which preserved file" (shared with doctor's
  # preservation_refs check). Filter the helper's REF rows down to basenames
  # in TO_REMOVE_*; preserve behavioral parity with the prior inline scan
  # (any REF row, regardless of bucket, marks the basename as referenced).
  _scan_out="$(bash "$SCRIPT_DIR/scan-preservation-refs.sh" 2>/dev/null || true)"
  if [ -n "$_scan_out" ]; then
    declare -A _hits_by_bn=()
    declare -A _hits_seen=()
    while IFS=$'\t' read -r _type _path _ref _bucket _snippet; do
      [ "$_type" = "REF" ] || continue
      _b="$(basename "$_path")"
      _in_removal=false
      for _q in "${TO_REMOVE_SCRIPTS[@]:-}" "${TO_REMOVE_HOOKS[@]:-}"; do
        [ -n "${_q:-}" ] || continue
        if [ "$(basename "$_q")" = "$_b" ]; then
          _in_removal=true
          break
        fi
      done
      [ "$_in_removal" = true ] || continue
      _ref_file="${_ref%:*}"
      _lineno="${_ref##*:}"
      _dedup_key="${_b}|${_ref_file}:${_lineno}"
      [ -n "${_hits_seen[$_dedup_key]:-}" ] && continue
      _hits_seen["$_dedup_key"]=1
      _hits_by_bn["$_b"]+="  ${_ref_file}:${_lineno} — ${_snippet}"$'\n'
    done <<<"$_scan_out"
    for _b in "${!_hits_by_bn[@]}"; do
      REFERENCED_HITS["$_b"]="${_hits_by_bn[$_b]}"
      REFERENCED_BASENAMES+=("$_b")
    done
  fi
  if [ ${#REFERENCED_BASENAMES[@]} -gt 0 ]; then
    for _b in "${REFERENCED_BASENAMES[@]}"; do
      # Use .claude/scripts/ form in the heading when the basename appeared in
      # TO_REMOVE_SCRIPTS, else .claude/hooks/. (A basename can only appear in
      # one of the two arrays.)
      _heading_dir="scripts"
      for _q in "${TO_REMOVE_HOOKS[@]:-}"; do
        [ "$(basename "${_q:-}")" = "$_b" ] && _heading_dir="hooks" && break
      done
      printf 'NOTE: removing .claude/%s/%s — references found in:\n' "$_heading_dir" "$_b"
      printf '%s' "${REFERENCED_HITS[$_b]}"
    done
    printf 'Run with --keep-referenced to preserve these, or update references manually post-migration.\n'
  fi
fi

# --- Apply --keep-referenced filter to removal arrays ---
if [ "$KEEP_REFERENCED" = true ] && [ ${#REFERENCED_BASENAMES[@]} -gt 0 ]; then
  _filter_array() {
    local arr_name="$1"
    local -n _src="$arr_name"
    local kept=()
    local removed=()
    for _p in "${_src[@]:-}"; do
      [ -n "$_p" ] || continue
      local _b="$(basename "$_p")"
      local _is_ref=false
      for _r in "${REFERENCED_BASENAMES[@]}"; do
        [ "$_r" = "$_b" ] && _is_ref=true && break
      done
      if [ "$_is_ref" = true ]; then
        removed+=("$_p")
      else
        kept+=("$_p")
      fi
    done
    _src=("${kept[@]:-}")
    for _p in "${removed[@]:-}"; do
      [ -n "$_p" ] || continue
      printf 'Preserved due to --keep-referenced: %s\n' "$_p"
    done
  }
  _filter_array TO_REMOVE_SCRIPTS
  _filter_array TO_REMOVE_HOOKS
fi

# --- Validation phase ---

if [ "$MODE" = full ]; then
  if [ ! -d .claude-pipeline ] \
     && [ ${#TO_REMOVE_SKILLS[@]} -eq 0 ] \
     && [ ${#TO_REMOVE_AGENTS[@]} -eq 0 ] \
     && [ ${#TO_REMOVE_SCRIPTS[@]} -eq 0 ] \
     && [ ${#TO_REMOVE_HOOKS[@]} -eq 0 ] \
     && [ ${#TO_PROMPT_SKILLS[@]} -eq 0 ] \
     && [ ${#TO_PROMPT_AGENTS[@]} -eq 0 ] \
     && [ "$SETTINGS_HAS_INJECTIONS" = false ]; then
    echo "migrate-from-subtree: nothing to migrate." >&2
    exit 0
  fi

  # --- Mutation phase ---

  # --- Prompt loop for basename-match candidates ---
  EXTRA_REMOVE=()
  if [ "$DRY_RUN" = false ] \
     && { [ ${#TO_PROMPT_SKILLS[@]} -gt 0 ] || [ ${#TO_PROMPT_AGENTS[@]} -gt 0 ]; }; then
    prompt_one() {
      local target="$1" answer=""
      if [ -n "$ASSUME" ]; then
        answer="$ASSUME"
      else
        printf 'migrate-from-subtree: remove unmarkered duplicate %s? [y/N] ' "$target" >&2
        read -r answer || answer=""
      fi
      case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
      esac
    }
    for d in "${TO_PROMPT_SKILLS[@]:-}"; do
      [ -n "$d" ] || continue
      if prompt_one "$d (skill, basename-match)"; then EXTRA_REMOVE+=("$d"); fi
    done
    for f in "${TO_PROMPT_AGENTS[@]:-}"; do
      [ -n "$f" ] || continue
      if prompt_one "$f (agent, basename-match)"; then EXTRA_REMOVE+=("$f"); fi
    done
  fi

  if [ "$DRY_RUN" = true ]; then
    for d in "${TO_REMOVE_SKILLS[@]}"; do
      echo "[dry-run] would-remove (marker): $d"
    done
    for f in "${TO_REMOVE_AGENTS[@]}" "${TO_REMOVE_SCRIPTS[@]}" "${TO_REMOVE_HOOKS[@]}"; do
      echo "[dry-run] would-remove (marker): $f"
    done
    for d in "${TO_PROMPT_SKILLS[@]:-}"; do
      [ -n "$d" ] || continue
      echo "[dry-run] would-remove (basename-match): $d"
    done
    for f in "${TO_PROMPT_AGENTS[@]:-}"; do
      [ -n "$f" ] || continue
      echo "[dry-run] would-remove (basename-match): $f"
    done
    [ -d .claude-pipeline ] && echo "[dry-run] would-remove (manifest): .claude-pipeline/"
  else
    for d in "${TO_REMOVE_SKILLS[@]}"; do
      rm -rf "$d"
    done
    for f in "${TO_REMOVE_AGENTS[@]}" "${TO_REMOVE_SCRIPTS[@]}" "${TO_REMOVE_HOOKS[@]}"; do
      rm -f "$f"
    done
    for x in "${EXTRA_REMOVE[@]:-}"; do
      [ -n "$x" ] || continue
      rm -rf "$x"
    done
    [ -d .claude-pipeline ] && rm -rf .claude-pipeline
  fi
fi

# --- Settings.json injection report (advisory only; never mutates) ---

SETTINGS_PATCH=".claude/migration-cleanup-settings.patch"
SETTINGS_WOULD_BE_EMPTY=false

if [ "$SETTINGS_HAS_INJECTIONS" = true ]; then
  {
    printf '%s\n' "Pipeline-injected hook references detected in $SETTINGS_FILE:"
    # Sort numerically by leading "linenum:" prefix so the report reads top-down.
    for line in "${!SETTINGS_MATCH_LINES[@]}"; do
      printf '%s\n' "$line"
    done | sort -t: -k1,1n
    printf '\n'
    # Per-basename advisory annotations, sourced from _advisory-text.sh.
    # Iterate the canonical basename list (NOT PIPELINE_HOOK_NAMES, which is
    # empty when .claude-pipeline/ has already been removed); annotate only
    # those basenames that appear in at least one SETTINGS_MATCH_LINES key.
    while IFS= read -r __b; do
      [ -z "$__b" ] && continue
      __matched=false
      for __line in "${!SETTINGS_MATCH_LINES[@]}"; do
        case "$__line" in *"$__b"*) __matched=true; break;; esac
      done
      if [ "$__matched" = true ]; then
        printf '  - .claude/hooks/%s\n' "$__b"
        printf '      %s\n' "$(advisory_for_hook "$__b")"
      fi
    done < <(list_pipeline_hook_basenames)
  } > "$SETTINGS_REPORT"
  echo "Pipeline-injected entries detected in settings.json — see report."

  # Patch generation (jq-driven structural transform; never mutates source).
  if command -v jq >/dev/null 2>&1; then
    if [ ${#PIPELINE_HOOK_NAMES[@]} -gt 0 ]; then
      BASENAMES_JSON=$(printf '%s\n' "${PIPELINE_HOOK_NAMES[@]}" | jq -R . | jq -s .)
    else
      BASENAMES_JSON='[]'
    fi

    JQ_FILTER='
      def base($p): $p | sub("^.*/"; "");
      def is_pipeline_cmd($cmd):
        ($cmd | type == "string") and (
          if ($PIPELINE_BASENAMES | length) > 0 then
            $PIPELINE_BASENAMES | any(. as $b | base($cmd) == $b)
          else
            ($cmd | contains(".claude/hooks/"))
          end
        );
      if (type == "object") and ((.hooks | type) == "object") then
        .hooks |= (
          with_entries(
            if (.value | type) == "array" then
              .value |= (
                map(
                  if (.hooks | type) == "array" then
                    .hooks |= map(select(is_pipeline_cmd(.command) | not))
                  else . end
                )
                | map(select((.hooks // []) | length > 0))
              )
            else . end
          )
          | with_entries(select((.value | type != "array") or ((.value | length) > 0)))
        )
      else . end
    '

    TRANSFORMED=$(mktemp)
    if ! jq --argjson PIPELINE_BASENAMES "$BASENAMES_JSON" "$JQ_FILTER" "$SETTINGS_FILE" > "$TRANSFORMED" 2>/dev/null; then
      cp "$SETTINGS_FILE" "$TRANSFORMED"
    fi

    if jq -e '
      (. == {})
      or ((. | keys) == ["hooks"] and (.hooks == {}))
      or ((. | keys) == ["hooks"] and (.hooks | to_entries | length == 0))
      or ((. | keys) == ["hooks"] and (.hooks | to_entries | all((.value | type) == "array" and (.value | length) == 0)))
    ' "$TRANSFORMED" >/dev/null 2>&1; then
      SETTINGS_WOULD_BE_EMPTY=true
    fi

    EMIT_PATCH=false
    if [ "$SETTINGS_WOULD_BE_EMPTY" = true ]; then
      EMIT_PATCH=true
    elif ! diff -q "$SETTINGS_FILE" "$TRANSFORMED" >/dev/null 2>&1; then
      EMIT_PATCH=true
    fi

    if [ "$EMIT_PATCH" = true ]; then
      {
        if [ "$SETTINGS_WOULD_BE_EMPTY" = true ]; then
          printf 'diff --git a/%s b/%s\n' "$SETTINGS_FILE" "$SETTINGS_FILE"
          printf 'deleted file mode 100644\n'
          printf -- '--- a/%s\n' "$SETTINGS_FILE"
          printf -- '+++ /dev/null\n'
          diff -u "$SETTINGS_FILE" /dev/null 2>/dev/null | tail -n +3 || true
        else
          printf 'diff --git a/%s b/%s\n' "$SETTINGS_FILE" "$SETTINGS_FILE"
          printf -- '--- a/%s\n' "$SETTINGS_FILE"
          printf -- '+++ b/%s\n' "$SETTINGS_FILE"
          diff -u "$SETTINGS_FILE" "$TRANSFORMED" 2>/dev/null | tail -n +3 || true
        fi
      } > "$SETTINGS_PATCH"

      # Rewrite the trailing "Review and remove these entries manually." line
      # with patch-application guidance (and loud warning when applicable).
      TMP_REPORT=$(mktemp)
      awk '!/^Review and remove these entries manually\.$/' "$SETTINGS_REPORT" > "$TMP_REPORT"
      {
        cat "$TMP_REPORT"
        if [ "$SETTINGS_WOULD_BE_EMPTY" = true ]; then
          printf '\n%s\n' "WARNING: applying this patch will leave .claude/settings.json functionally empty"
          printf '%s\n'   "(or remove the file entirely). Review the patch carefully — if you have any"
          printf '%s\n'   "non-pipeline customizations the detector missed, edit settings.json by hand"
          printf '%s\n\n' "instead of applying the patch."
        fi
        printf '%s\n' "A reviewable patch is at .claude/migration-cleanup-settings.patch."
        printf '%s\n' "Apply with: git apply .claude/migration-cleanup-settings.patch"
        printf '%s\n' "After applying, delete the artifacts:"
        printf '%s\n' "  rm -f .claude/migration-cleanup-settings.patch .claude/settings.json.pipeline-migration-report.txt"
      } > "$SETTINGS_REPORT"
      rm -f "$TMP_REPORT"

      if [ "$SETTINGS_WOULD_BE_EMPTY" = true ]; then
        echo "WARNING: applying the settings.json patch will leave .claude/settings.json functionally empty — review carefully."
      fi
    fi

    rm -f "$TRANSFORMED"
  fi
fi

if [ "$MODE" = patch_settings ]; then
  exit 0
fi

# --- CLAUDE.md cleanup (advisory only; never edits source files) ---

if [ -f "$SCRIPT_DIR/migration-cleanup-claudemd.sh" ]; then
  bash "$SCRIPT_DIR/migration-cleanup-claudemd.sh" || \
    echo "[migrate-from-subtree] WARN: claudemd cleanup helper failed (advisory only)" >&2
fi

# --- Report phase ---

cat <<'EOF'
Migration complete.

Install the plugin: claude plugin install hts-collab-org/claude-pipeline
Re-run /pipeline:run to verify.
EOF
