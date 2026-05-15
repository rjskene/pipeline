#!/bin/bash
set -euo pipefail
shopt -s nullglob

# migrate-from-subtree.sh — one-shot migration for consumers who installed
# the pipeline via the legacy subtree + install.sh path. Removes every
# pipeline-managed file we can identify, leaves user-authored files alone.
#
# Run from the consumer project root:
#   bash scripts/migrate-from-subtree.sh
#
# Idempotent: re-running on an already-migrated project is a no-op.
# Fails closed: detection runs to completion before any rm, so a glob error
# aborts the script (set -e) before mutating the filesystem.

PROJECT_ROOT="$(pwd)"
cd "$PROJECT_ROOT"

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

# --- Validation phase ---

if [ ! -d .claude-pipeline ] \
   && [ ${#TO_REMOVE_SKILLS[@]} -eq 0 ] \
   && [ ${#TO_REMOVE_AGENTS[@]} -eq 0 ] \
   && [ ${#TO_REMOVE_SCRIPTS[@]} -eq 0 ] \
   && [ ${#TO_REMOVE_HOOKS[@]} -eq 0 ] \
   && [ "$SETTINGS_HAS_INJECTIONS" = false ]; then
  echo "migrate-from-subtree: nothing to migrate." >&2
  exit 0
fi

# --- Mutation phase ---

for d in "${TO_REMOVE_SKILLS[@]}"; do
  rm -rf "$d"
done
for f in "${TO_REMOVE_AGENTS[@]}" "${TO_REMOVE_SCRIPTS[@]}" "${TO_REMOVE_HOOKS[@]}"; do
  rm -f "$f"
done
[ -d .claude-pipeline ] && rm -rf .claude-pipeline

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
    printf '\n%s\n' "Review and remove these entries manually."
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

# --- CLAUDE.md cleanup (advisory only; never edits source files) ---

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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
