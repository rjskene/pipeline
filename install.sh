#!/bin/bash
set -euo pipefail

# install.sh — Generate project-specific pipeline files from templates.
#
# Reads pipeline.config from the project root, then:
# - Renders .template SKILL.md files → .claude/skills/<name>/SKILL.md
# - Renders .template script files   → .claude/scripts/<name>.sh
# - Renders .template hook files     → .claude/hooks/<name>
# - Copies non-template files as-is
#
# Usage: bash .claude-pipeline/install.sh

PIPELINE_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$PIPELINE_DIR/.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/pipeline.config"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: pipeline.config not found at $CONFIG_FILE"
  echo "Copy .claude-pipeline/pipeline.config.example to pipeline.config and edit it."
  exit 1
fi

# Check for envsubst
if ! command -v envsubst &>/dev/null; then
  echo "ERROR: envsubst not found."
  echo "  Linux:  sudo apt-get install gettext-base"
  echo "  macOS:  brew install gettext && brew link --force gettext"
  echo "  Git Bash (Windows): included by default"
  exit 1
fi

# Check bash version (scripts use associative arrays requiring bash 4+)
if (( BASH_VERSINFO[0] < 4 )); then
  echo "WARNING: bash ${BASH_VERSION} detected. Pipeline scripts require bash 4+."
  echo "  macOS:  brew install bash"
  echo "  The installer will continue, but queue scripts will fail at runtime."
  echo ""
fi

# Source config and export all PIPELINE_* variables
source "$CONFIG_FILE"
export PIPELINE_REPO PIPELINE_BASE_BRANCH PIPELINE_WORKTREE_PREFIX
export PIPELINE_INSTALL_CMD PIPELINE_SEED_CMD PIPELINE_TEST_CMD PIPELINE_TYPECHECK_CMD
export PIPELINE_CONTEXT_FILES PIPELINE_SYNC_ENVS PIPELINE_SYNC_VENVS
export PIPELINE_SYNC_DOCS PIPELINE_SYNC_FILES
export PIPELINE_FRONTEND_PORT_OFFSET PIPELINE_LABELS_EXCLUDED PIPELINE_LABELS_LATER PIPELINE_LABELS_HUMAN
export PIPELINE_WIN_TEMP
export PIPELINE_SUBTREE_REMOTE PIPELINE_SUBTREE_BRANCH

# Build explicit envsubst variable list to avoid clobbering unrelated $VAR references
ENVSUBST_VARS='$PIPELINE_REPO $PIPELINE_BASE_BRANCH $PIPELINE_WORKTREE_PREFIX'
ENVSUBST_VARS+=' $PIPELINE_INSTALL_CMD $PIPELINE_SEED_CMD $PIPELINE_TEST_CMD $PIPELINE_TYPECHECK_CMD'
ENVSUBST_VARS+=' $PIPELINE_CONTEXT_FILES $PIPELINE_SYNC_ENVS $PIPELINE_SYNC_VENVS'
ENVSUBST_VARS+=' $PIPELINE_SYNC_DOCS $PIPELINE_SYNC_FILES'
ENVSUBST_VARS+=' $PIPELINE_FRONTEND_PORT_OFFSET $PIPELINE_LABELS_EXCLUDED $PIPELINE_LABELS_LATER $PIPELINE_LABELS_HUMAN'
ENVSUBST_VARS+=' $PIPELINE_WIN_TEMP'
ENVSUBST_VARS+=' $PIPELINE_SUBTREE_REMOTE $PIPELINE_SUBTREE_BRANCH'

SKILLS_INSTALLED=0
SKILLS_PRUNED=0
SCRIPTS_INSTALLED=0
HOOKS_INSTALLED=0
SKIPPED=0

echo "=== Claude Pipeline Installer ==="
echo "  Pipeline dir: $PIPELINE_DIR"
echo "  Project root: $PROJECT_ROOT"
echo "  Config: $CONFIG_FILE"
echo ""

# --- Install skill templates ---
echo "--- Skills ---"
for template in "$PIPELINE_DIR"/skills/*/SKILL.md.template; do
  [ -f "$template" ] || continue
  skill_name="$(basename "$(dirname "$template")")"
  output_dir="$PROJECT_ROOT/.claude/skills/$skill_name"
  output_file="$output_dir/SKILL.md"

  mkdir -p "$output_dir"

  # Generate from template
  rendered=$(envsubst "$ENVSUBST_VARS" < "$template")

  # Skip if identical
  if [ -f "$output_file" ] && [ "$(echo "$rendered" | diff -q - "$output_file" 2>/dev/null; echo $?)" = "0" ]; then
    echo "  [skip] $skill_name/SKILL.md (unchanged)"
    SKIPPED=$((SKIPPED + 1))
  else
    echo "$rendered" > "$output_file"
    echo "  [ok]   $skill_name/SKILL.md"
    SKILLS_INSTALLED=$((SKILLS_INSTALLED + 1))
  fi
  # Mark as pipeline-managed so pruning skips project-specific skills
  touch "$output_dir/.pipeline-managed"
done

# --- Prune stale pipeline-managed skills (marker present, no matching template) ---
for installed_skill in "$PROJECT_ROOT"/.claude/skills/*/SKILL.md; do
  [ -f "$installed_skill" ] || continue
  skill_dir="$(dirname "$installed_skill")"
  skill_name="$(basename "$skill_dir")"
  # Only prune skills that were installed by this script (have the marker)
  if [ -f "$skill_dir/.pipeline-managed" ] && [ ! -f "$PIPELINE_DIR/skills/$skill_name/SKILL.md.template" ]; then
    rm -rf "$skill_dir"
    echo "  [prune] $skill_name/ (stale pipeline-managed skill)"
    SKILLS_PRUNED=$((SKILLS_PRUNED + 1))
  fi
done

# --- Install script templates ---
echo ""
echo "--- Scripts ---"
for template in "$PIPELINE_DIR"/scripts/*.template; do
  [ -f "$template" ] || continue
  # Remove .template suffix to get output filename
  base_name="$(basename "$template" .template)"
  output_file="$PROJECT_ROOT/.claude/scripts/$base_name"

  mkdir -p "$PROJECT_ROOT/.claude/scripts"

  # Shell scripts source pipeline.config at runtime — just copy them as-is.
  # Do NOT run envsubst on scripts (their $PIPELINE_* vars resolve at runtime).
  if [ -f "$output_file" ] && diff -q "$template" "$output_file" >/dev/null 2>&1; then
    echo "  [skip] $base_name (unchanged)"
    SKIPPED=$((SKIPPED + 1))
  else
    cp "$template" "$output_file"
    chmod +x "$output_file"
    echo "  [ok]   $base_name"
    SCRIPTS_INSTALLED=$((SCRIPTS_INSTALLED + 1))
  fi
done

# Copy non-template scripts as-is
for script in "$PIPELINE_DIR"/scripts/*.sh; do
  [ -f "$script" ] || continue
  base_name="$(basename "$script")"
  # Skip if there's a .template version (already handled above)
  [ -f "$PIPELINE_DIR/scripts/${base_name}.template" ] && continue
  output_file="$PROJECT_ROOT/.claude/scripts/$base_name"

  mkdir -p "$PROJECT_ROOT/.claude/scripts"

  if [ -f "$output_file" ] && diff -q "$script" "$output_file" >/dev/null 2>&1; then
    echo "  [skip] $base_name (unchanged)"
    SKIPPED=$((SKIPPED + 1))
  else
    cp "$script" "$output_file"
    chmod +x "$output_file"
    echo "  [ok]   $base_name"
    SCRIPTS_INSTALLED=$((SCRIPTS_INSTALLED + 1))
  fi
done

# --- Install hook templates ---
echo ""
echo "--- Hooks ---"
for template in "$PIPELINE_DIR"/hooks/*.template; do
  [ -f "$template" ] || continue
  # Remove .template suffix
  base_name="$(basename "$template" .template)"
  output_file="$PROJECT_ROOT/.claude/hooks/$base_name"

  mkdir -p "$PROJECT_ROOT/.claude/hooks"

  rendered=$(envsubst "$ENVSUBST_VARS" < "$template")

  if [ -f "$output_file" ] && [ "$(echo "$rendered" | diff -q - "$output_file" 2>/dev/null; echo $?)" = "0" ]; then
    echo "  [skip] $base_name (unchanged)"
    SKIPPED=$((SKIPPED + 1))
  else
    echo "$rendered" > "$output_file"
    # Make .sh hooks executable
    case "$base_name" in *.sh) chmod +x "$output_file" ;; esac
    echo "  [ok]   $base_name"
    HOOKS_INSTALLED=$((HOOKS_INSTALLED + 1))
  fi
done

# Copy non-template hooks as-is
for hook in "$PIPELINE_DIR"/hooks/*; do
  [ -f "$hook" ] || continue
  base_name="$(basename "$hook")"
  # Skip template files (already handled above)
  case "$base_name" in *.template) continue ;; esac
  output_file="$PROJECT_ROOT/.claude/hooks/$base_name"

  mkdir -p "$PROJECT_ROOT/.claude/hooks"

  if [ -f "$output_file" ] && diff -q "$hook" "$output_file" >/dev/null 2>&1; then
    echo "  [skip] $base_name (unchanged)"
    SKIPPED=$((SKIPPED + 1))
  else
    cp "$hook" "$output_file"
    case "$base_name" in *.sh) chmod +x "$output_file" ;; esac
    echo "  [ok]   $base_name"
    HOOKS_INSTALLED=$((HOOKS_INSTALLED + 1))
  fi
done

echo ""
echo "=== Done ==="
TOTAL=$((SKILLS_INSTALLED + SCRIPTS_INSTALLED + HOOKS_INSTALLED))
echo "  Installed: ${SKILLS_INSTALLED} skills, ${SCRIPTS_INSTALLED} scripts, ${HOOKS_INSTALLED} hooks"
echo "  Pruned:    ${SKILLS_PRUNED} stale skills"
echo "  Skipped:   ${SKIPPED} (unchanged)"
echo "  Total:     $((TOTAL + SKIPPED)) files processed"

# --- Advisory: check for superpowers plugin ---
echo ""
echo "--- Plugin dependencies ---"
SUPERPOWERS_INSTALLED=false
SUPERPOWERS_MANIFEST="$HOME/.claude/plugins/installed_plugins.json"
if [ -f "$SUPERPOWERS_MANIFEST" ]; then
  if grep -q '"superpowers' "$SUPERPOWERS_MANIFEST" 2>/dev/null; then
    SUPERPOWERS_INSTALLED=true
    echo "  [ok]   superpowers plugin detected"
  fi
fi

if [ "$SUPERPOWERS_INSTALLED" = false ]; then
  echo "  [warn] superpowers plugin not found"
  echo ""
  echo "  Pipeline skills can compose with superpowers for enhanced planning,"
  echo "  TDD, and brainstorming. Install from Claude Code:"
  echo ""
  echo "      /plugin install superpowers@claude-plugins-official"
  echo ""
  echo "  Skills fall back to inline behavior when superpowers is absent."
fi

# --- Advisory: check for subtree drift ---
if [ -f "$PIPELINE_DIR/scripts/check-subtree-drift.sh" ]; then
  bash "$PIPELINE_DIR/scripts/check-subtree-drift.sh" --quiet 2>/dev/null || true
fi
