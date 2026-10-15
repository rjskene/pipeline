#!/bin/bash
set -euo pipefail

# Tests for MCP gating in spawn-claude.sh (issue #347). Gating is
# unconditional: spawned agents ALWAYS get zero MCP servers (no label opt-in).
#   A. a plain issue          -> --mcp-config + --strict-mcp-config injected,
#      synthesised tempfile content is {"mcpServers": {}}.
#   C. `gh issue view` fails  -> still default-deny (empty MCP).
#
# Runs spawn-claude.sh with PIPELINE_SPAWN_DRY_RUN=1 and a stubbed `gh` so no
# network is required. Follows the pattern of test-spawn-claude-runs-log.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/../scripts/spawn-claude.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

if [ ! -f "$SCRIPT_UNDER_TEST" ]; then
  echo "ERROR: script under test not found at $SCRIPT_UNDER_TEST" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/.claude/scripts"
cp "$SCRIPT_UNDER_TEST" "$PROJ/.claude/scripts/spawn-claude.sh"
chmod +x "$PROJ/.claude/scripts/spawn-claude.sh"

cat > "$PROJ/pipeline.config" <<'EOF'
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="ct"
PIPELINE_WIN_TEMP=""
PIPELINE_PATH_A_SKILLS_EXECUTE=""
PIPELINE_PATH_B_SKILLS_EXECUTE=""
PIPELINE_PATH_C_SKILLS_EXECUTE=""
PIPELINE_PATH_A_REVIEWER_EXECUTE=""
PIPELINE_PATH_B_REVIEWER_EXECUTE=""
PIPELINE_PATH_C_REVIEWER_EXECUTE=""
EOF

mkdir -p "$PROJ/worktree"

# Stub gh: returns labels from STUB_LABELS (newline-separated), or exits 1 if
# STUB_GH_FAIL=1.
STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
if [ "${STUB_GH_FAIL:-0}" = "1" ]; then
  exit 1
fi
printf '%s\n' "${STUB_LABELS:-}"
EOF
chmod +x "$STUB_DIR/gh"

RUNS_LOG="$WORKDIR/runs.log"

run_dryrun() {
  local labels="$1" issue="$2"
  cd "$PROJ"
  # STUB_GH_FAIL is forwarded explicitly: a `VAR=1 run_dryrun` prefix sets the
  # var inside the function body but does NOT re-export it to the spawn-claude
  # subprocess, so Test C must thread it through here to reach the gh stub.
  PATH="$STUB_DIR:$PATH" \
    STUB_LABELS="$labels" \
    STUB_GH_FAIL="${STUB_GH_FAIL:-0}" \
    PIPELINE_SPAWN_DRY_RUN=1 \
    PIPELINE_LOGS_ENABLED=true \
    PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
    bash .claude/scripts/spawn-claude.sh "$PROJ/worktree" "$issue" slug tmux 2>/dev/null
  cd - >/dev/null
}

build_block() { echo "$1" | sed -n '/^=== BUILD_ARGV ===$/,/^=== END BUILD_ARGV ===$/p'; }

# -------------------------------------------------------------------------
# Test A: plain issue -> empty-MCP config injected.
# -------------------------------------------------------------------------
echo "Test A: plain issue -> --mcp-config + --strict-mcp-config injected"
OUT=$(run_dryrun "" 900)
BLOCK=$(build_block "$OUT")
MCP_FILE=$(echo "$OUT" | sed -n 's/^EMPTY_MCP_FILE=//p' | head -1)

# The argv is built one token per CLAUDE_ARGV+=(<tok>) line (the project's
# verified injection shape), so --mcp-config, its file path, and
# --strict-mcp-config each land on their own line.
inc
if echo "$BLOCK" | grep -qE 'CLAUDE_ARGV\+=\(--mcp-config\)'; then
  pass_msg "A: --mcp-config token injected"
else
  fail_msg "A: --mcp-config token NOT injected"
  echo "$BLOCK" | sed 's/^/    /'
fi

inc
if [ -n "$MCP_FILE" ] && echo "$BLOCK" | grep -qF "CLAUDE_ARGV+=($MCP_FILE)"; then
  pass_msg "A: empty-MCP file path token follows --mcp-config"
else
  fail_msg "A: empty-MCP file path token missing from argv"
  echo "$BLOCK" | sed 's/^/    /'
fi

inc
if echo "$BLOCK" | grep -qE 'CLAUDE_ARGV\+=\(--strict-mcp-config\)'; then
  pass_msg "A: --strict-mcp-config injected"
else
  fail_msg "A: --strict-mcp-config NOT injected"
fi

inc
if echo "$OUT" | grep -qE '^EMPTY_MCP_FILE=/tmp/claude-mcp-empty-'; then
  pass_msg "A: EMPTY_MCP_FILE dump line present ($MCP_FILE)"
else
  fail_msg "A: EMPTY_MCP_FILE dump line missing or wrong shape"
fi

inc
if [ -n "$MCP_FILE" ] && [ -f "$MCP_FILE" ] && [ "$(cat "$MCP_FILE")" = '{"mcpServers": {}}' ]; then
  pass_msg "A: tempfile content is {\"mcpServers\": {}}"
else
  fail_msg "A: tempfile content wrong: '$( [ -f "$MCP_FILE" ] && cat "$MCP_FILE" )'"
fi

# -------------------------------------------------------------------------
# Test C: gh fails -> fail-safe to default-deny (empty MCP injected).
# -------------------------------------------------------------------------
echo "Test C: gh failure -> default-deny (empty MCP, no .mcp.json leak)"
OUT=$(STUB_GH_FAIL=1 run_dryrun "" 902)
BLOCK=$(build_block "$OUT")

inc
if echo "$BLOCK" | grep -qE 'CLAUDE_ARGV\+=\(--mcp-config\)' \
   && echo "$BLOCK" | grep -qE 'CLAUDE_ARGV\+=\(--strict-mcp-config\)'; then
  pass_msg "C: empty-MCP injected on gh failure (default-deny)"
else
  fail_msg "C: gh failure regressed to inheriting .mcp.json (no --mcp-config)"
  echo "$BLOCK" | sed 's/^/    /'
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
