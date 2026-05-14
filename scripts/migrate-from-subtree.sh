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

# Detect pipeline-hook references in .claude/settings.json. We capture the
# matching lines NOW (before mutation removes .claude-pipeline/) so the
# enumerated hook-name list is still in scope.
SETTINGS_FILE=".claude/settings.json"
SETTINGS_REPORT=".claude/settings.json.pipeline-migration-report.txt"
SETTINGS_HAS_INJECTIONS=false
SETTINGS_MATCHES=""
if [ -f "$SETTINGS_FILE" ] && [ ${#PIPELINE_HOOK_NAMES[@]} -gt 0 ]; then
  for name in "${PIPELINE_HOOK_NAMES[@]}"; do
    while IFS= read -r line; do
      SETTINGS_MATCHES+="$line"$'\n'
    done < <(grep -n -F "$name" "$SETTINGS_FILE" 2>/dev/null || true)
  done
  if [ -n "$SETTINGS_MATCHES" ]; then
    SETTINGS_HAS_INJECTIONS=true
  fi
fi

# --- Validation phase ---

if [ ! -d .claude-pipeline ] \
   && [ ${#TO_REMOVE_SKILLS[@]} -eq 0 ] \
   && [ ${#TO_REMOVE_AGENTS[@]} -eq 0 ] \
   && [ ${#TO_REMOVE_SCRIPTS[@]} -eq 0 ] \
   && [ ${#TO_REMOVE_HOOKS[@]} -eq 0 ]; then
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

if [ "$SETTINGS_HAS_INJECTIONS" = true ]; then
  {
    printf '%s\n' "Pipeline-injected hook references detected in $SETTINGS_FILE:"
    printf '%s' "$SETTINGS_MATCHES"
    printf '\n%s\n' "Review and remove these entries manually."
  } > "$SETTINGS_REPORT"
  echo "Pipeline-injected entries detected in settings.json — see report."
fi

# --- Report phase ---

cat <<'EOF'
Migration complete.

Install the plugin: claude plugin install hts-collab-org/claude-pipeline
Re-run /pipeline:run to verify.
EOF
