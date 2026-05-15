#!/bin/bash
set -euo pipefail
# Verifies that every advertised pipeline skill is discoverable via the plugin's
# `skills/` directory ALONE — i.e. as `${CLAUDE_PLUGIN_ROOT}/skills/<name>/SKILL.md`
# with no `.template` suffix and no fallback to a project-local `.claude/skills/`
# rendering. Also verifies the manifest does NOT explicitly enumerate skills
# (auto-discovery is the contract).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$REPO_ROOT/.claude-plugin/plugin.json"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

SKILLS=(classify-issue create-issues doctor evaluate-issue-plan evaluate-issue-pr execute-issue-plan plan-issue run worktree-sync)

# 1. Canonical SKILL.md exists at plugin root, with matching frontmatter, and no .template leftover.
for name in "${SKILLS[@]}"; do
  assert "skills/$name/SKILL.md exists at plugin root" "[ -f '$REPO_ROOT/skills/$name/SKILL.md' ]"
  assert "skills/$name/SKILL.md frontmatter has name: $name" \
    "grep -qE '^name:[[:space:]]*$name\$' '$REPO_ROOT/skills/$name/SKILL.md'"
  assert "skills/$name/SKILL.md.template no longer exists (suffix retired)" \
    "[ ! -f '$REPO_ROOT/skills/$name/SKILL.md.template' ]"
done

# 2. Duplicate rendered tree at .claude/skills/ has been removed (was shadowing the plugin).
assert ".claude/skills/ has been removed (no shadow tree at project scope)" \
  "[ ! -d '$REPO_ROOT/.claude/skills' ]"

# 3. Manifest auto-discovery contract: no explicit top-level `skills` field.
assert "plugin.json does NOT declare a top-level 'skills' field" \
  "python3 -c 'import json,sys; m=json.load(open(\"$MANIFEST\")); sys.exit(0 if \"skills\" not in m else 1)' 2>/dev/null"

# 4. Sandbox simulation: copy manifest + each SKILL.md into a temp plugin dir and
# verify the loader-style path resolves without any other repo files.
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/plugin/.claude-plugin"
cp "$MANIFEST" "$SANDBOX/plugin/.claude-plugin/plugin.json"
for name in "${SKILLS[@]}"; do
  mkdir -p "$SANDBOX/plugin/skills/$name"
  if [ -f "$REPO_ROOT/skills/$name/SKILL.md" ]; then
    cp "$REPO_ROOT/skills/$name/SKILL.md" "$SANDBOX/plugin/skills/$name/SKILL.md"
  fi
  assert "sandbox: plugin/skills/$name/SKILL.md resolves from plugin root alone" \
    "[ -f '$SANDBOX/plugin/skills/$name/SKILL.md' ]"
done
mkdir -p "$SANDBOX/project"   # consumer project — deliberately NO .claude/skills/
assert "sandbox project has NO .claude/skills/ rendering" \
  "[ ! -d '$SANDBOX/project/.claude/skills' ]"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
