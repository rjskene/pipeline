#!/bin/bash
set -euo pipefail

# Tests for the Agents section in install.sh:
#   - Renders .claude-pipeline/agents/*.md to .claude/agents/<name>.md
#   - Drops a per-file .pipeline-managed marker (.<name>.pipeline-managed)
#   - Prunes pipeline-managed agents whose source template was removed
#   - Preserves user-authored agents (no marker -> never pruned)
#
# Runs install.sh in a fully isolated temp project root with a stub config.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

if [ ! -f "$INSTALL_SH" ]; then
  echo "ERROR: install.sh not found at $INSTALL_SH" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

PROJ="$WORKDIR/proj"
PIPE="$PROJ/.claude-pipeline"
mkdir -p "$PIPE/agents" "$PIPE/skills" "$PIPE/scripts" "$PIPE/hooks"
mkdir -p "$PROJ/.claude/agents"

# Drop install.sh + the same support dirs the real one expects
cp "$INSTALL_SH" "$PIPE/install.sh"
chmod +x "$PIPE/install.sh"

# Minimal pipeline.config
cat > "$PROJ/pipeline.config" <<'EOF'
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="ct"
PIPELINE_INSTALL_CMD=""
PIPELINE_SEED_CMD=""
PIPELINE_TEST_CMD=""
PIPELINE_TYPECHECK_CMD=""
PIPELINE_CONTEXT_FILES=""
PIPELINE_SYNC_ENVS=""
PIPELINE_SYNC_VENVS=""
PIPELINE_SYNC_DOCS=""
PIPELINE_SYNC_FILES=""
PIPELINE_FRONTEND_PORT_OFFSET=4000
PIPELINE_LABELS_EXCLUDED=""
PIPELINE_LABELS_LATER=""
PIPELINE_LABELS_HUMAN=""
PIPELINE_WIN_TEMP=""
PIPELINE_SUBTREE_REMOTE=""
PIPELINE_SUBTREE_BRANCH=""
EOF

# A pipeline-managed agent template that includes envsubst variable
cat > "$PIPE/agents/foo.md" <<'EOF'
---
name: foo
description: Test agent for ${PIPELINE_REPO}
tools: Read
model: inherit
---

Body for foo.
EOF

# A user-authored agent that should be preserved (no marker)
cat > "$PROJ/.claude/agents/handwritten.md" <<'EOF'
---
name: handwritten
---
User wrote this.
EOF

cd "$PROJ"
bash .claude-pipeline/install.sh >"$WORKDIR/install1.log" 2>&1 || {
  echo "install.sh failed (run 1):"
  cat "$WORKDIR/install1.log"
  exit 1
}

echo "Test 1: foo.md rendered with envsubst"
inc
if [ -f "$PROJ/.claude/agents/foo.md" ]; then
  if grep -q 'fake/repo' "$PROJ/.claude/agents/foo.md"; then
    pass_msg "agent rendered with PIPELINE_REPO substituted"
  else
    fail_msg "agent rendered but PIPELINE_REPO not substituted"
    cat "$PROJ/.claude/agents/foo.md" | sed 's/^/    /'
  fi
else
  fail_msg "expected $PROJ/.claude/agents/foo.md"
fi

echo "Test 2: per-file .pipeline-managed marker for foo"
inc
if [ -f "$PROJ/.claude/agents/.foo.pipeline-managed" ]; then
  pass_msg "marker exists"
else
  fail_msg "expected $PROJ/.claude/agents/.foo.pipeline-managed"
  ls -la "$PROJ/.claude/agents/" | sed 's/^/    /'
fi

echo "Test 3: handwritten agent preserved (no marker, not pruned)"
inc
if [ -f "$PROJ/.claude/agents/handwritten.md" ]; then
  pass_msg "user-authored agent kept"
else
  fail_msg "user-authored agent was deleted"
fi

echo "Test 4: install.sh announces Agents section in output"
inc
if grep -qE '^---[[:space:]]*Agents[[:space:]]*---' "$WORKDIR/install1.log"; then
  pass_msg "Agents section header printed"
else
  fail_msg "expected '--- Agents ---' header in install.sh output"
  cat "$WORKDIR/install1.log" | sed 's/^/    /'
fi

# --- Run 2: remove foo template, add bar template; expect prune of foo, install of bar ---
rm "$PIPE/agents/foo.md"
cat > "$PIPE/agents/bar.md" <<'EOF'
---
name: bar
---
Bar body.
EOF

bash .claude-pipeline/install.sh >"$WORKDIR/install2.log" 2>&1 || {
  echo "install.sh failed (run 2):"
  cat "$WORKDIR/install2.log"
  exit 1
}

echo "Test 5: stale pipeline-managed agent (foo) pruned"
inc
if [ ! -f "$PROJ/.claude/agents/foo.md" ] && [ ! -f "$PROJ/.claude/agents/.foo.pipeline-managed" ]; then
  pass_msg "foo + marker removed"
else
  fail_msg "expected foo.md and marker to be pruned"
  ls -la "$PROJ/.claude/agents/" | sed 's/^/    /'
fi

echo "Test 6: new agent (bar) installed with marker"
inc
if [ -f "$PROJ/.claude/agents/bar.md" ] && [ -f "$PROJ/.claude/agents/.bar.pipeline-managed" ]; then
  pass_msg "bar.md + marker present"
else
  fail_msg "expected bar.md and .bar.pipeline-managed"
  ls -la "$PROJ/.claude/agents/" | sed 's/^/    /'
fi

echo "Test 7: handwritten agent still preserved after second run"
inc
if [ -f "$PROJ/.claude/agents/handwritten.md" ]; then
  pass_msg "user-authored agent still present"
else
  fail_msg "user-authored agent was deleted on second run"
fi

echo "Test 8: re-run with no template changes is idempotent (no errors, file unchanged)"
inc
BAR_BEFORE=$(cat "$PROJ/.claude/agents/bar.md")
bash .claude-pipeline/install.sh >"$WORKDIR/install3.log" 2>&1 || {
  fail_msg "install.sh failed on idempotent re-run"
  cat "$WORKDIR/install3.log"
}
BAR_AFTER=$(cat "$PROJ/.claude/agents/bar.md")
if [ "$BAR_BEFORE" = "$BAR_AFTER" ]; then
  pass_msg "agent file unchanged on no-op re-run"
else
  fail_msg "agent file changed on no-op re-run"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
