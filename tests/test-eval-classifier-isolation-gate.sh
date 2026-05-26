#!/bin/bash
set -uo pipefail
#
# test-eval-classifier-isolation-gate.sh — verify the inline browser-eval
# dispatch gate in scripts/spawn-claude.sh (issue #517).
#
# Contract (3 assertions):
#   (a) PIPELINE_EVAL_ISOLATION=container + --container-mode=mock-web-eval
#       -> DOCKER_PREFIX field present in the dry-run dump, INLINE_BROWSER_EVAL
#          absent or 0 (legacy container dispatch unchanged).
#   (b) PIPELINE_EVAL_ISOLATION unset (or empty) + --container-mode=mock-web-eval
#       -> INLINE_BROWSER_EVAL=1 in the dry-run dump, no DOCKER_PREFIX field
#          (inline branch short-circuits before docker prefix assembly).
#   (c) PIPELINE_EVAL_ISOLATION unset + --container-mode=mock-web-eval but the
#       project root has no .mcp.json (or no Playwright entry) -> exit 6 with
#       a loud refusal substring naming the missing MCP.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/../scripts/spawn-claude.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SCRIPT_UNDER_TEST" ]; then
  echo "ERROR: script under test not found at $SCRIPT_UNDER_TEST" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/.claude/scripts" "$PROJ/worktree"
cp "$SCRIPT_UNDER_TEST" "$PROJ/.claude/scripts/spawn-claude.sh"
chmod +x "$PROJ/.claude/scripts/spawn-claude.sh"

cat > "$PROJ/pipeline.config" <<'EOF'
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="ct"
PIPELINE_WIN_TEMP=""
PIPELINE_PATH_A_SKILLS_EVALUATE_PR=""
PIPELINE_PATH_B_SKILLS_EVALUATE_PR=""
PIPELINE_PATH_C_SKILLS_EVALUATE_PR=""
PIPELINE_PATH_A_REVIEWER_EVALUATE_PR=""
PIPELINE_PATH_B_REVIEWER_EVALUATE_PR=""
PIPELINE_PATH_C_REVIEWER_EVALUATE_PR=""
PIPELINE_EVAL_CONTAINERS="mock-web-eval"
PIPELINE_EVAL_CONTAINER_mock_web_eval_COMPOSE_FILE="compose.mock-web-eval.yml"
PIPELINE_EVAL_CONTAINER_mock_web_eval_ENV_FILE=".env.mock-web-eval"
PIPELINE_EVAL_CONTAINER_mock_web_eval_SERVICE="claude-mock-web-eval"
EOF

# .mcp.json with Playwright entry (for tests (a) and (b))
cat > "$PROJ/.mcp.json" <<'EOF'
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["@playwright/mcp@latest"]
    }
  }
}
EOF

STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "${STUB_LABELS:-}"
EOF
chmod +x "$STUB_DIR/gh"

RUNS_LOG="$WORKDIR/runs.log"

# ---- Test (a): ISOLATION=container + container-mode -> docker dispatch unchanged ----
echo "Test (a): PIPELINE_EVAL_ISOLATION=container + --container-mode=mock-web-eval -> docker prefix kept"
inc
OUT=$(cd "$PROJ" && \
  PATH="$STUB_DIR:$PATH" \
  STUB_LABELS="" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_LOGS_ENABLED=true \
  PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
  PIPELINE_EVAL_ISOLATION=container \
  CLAUDE_PLUGIN_ROOT="$PROJ/.claude" \
  bash .claude/scripts/spawn-claude.sh \
    --skill evaluate-issue-pr --container-mode=mock-web-eval \
    "$PROJ/worktree" 300 slug tmux 2>&1 ; echo "RC=$?") || true
RC=$(echo "$OUT" | grep -E '^RC=' | tail -1 | sed 's/RC=//')
if [ "$RC" != "0" ]; then
  fail_msg "expected RC=0, got RC=$RC"
  echo "$OUT" | tail -25 | sed 's/^/    /'
elif ! echo "$OUT" | grep -q '^DOCKER_PREFIX='; then
  fail_msg "expected DOCKER_PREFIX field in dry-run dump for container isolation"
  echo "$OUT" | tail -25 | sed 's/^/    /'
elif echo "$OUT" | grep -qE '^INLINE_BROWSER_EVAL=1$'; then
  fail_msg "INLINE_BROWSER_EVAL=1 unexpectedly present when ISOLATION=container"
  echo "$OUT" | tail -25 | sed 's/^/    /'
else
  pass_msg "container isolation preserves DOCKER_PREFIX; no inline branch"
fi

# ---- Test (b): ISOLATION unset + container-mode -> inline dispatch ----
echo "Test (b): PIPELINE_EVAL_ISOLATION unset + --container-mode=mock-web-eval -> INLINE_BROWSER_EVAL=1"
inc
OUT=$(cd "$PROJ" && \
  PATH="$STUB_DIR:$PATH" \
  STUB_LABELS="" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_LOGS_ENABLED=true \
  PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
  CLAUDE_PLUGIN_ROOT="$PROJ/.claude" \
  bash .claude/scripts/spawn-claude.sh \
    --skill evaluate-issue-pr --container-mode=mock-web-eval \
    "$PROJ/worktree" 301 slug tmux 2>&1 ; echo "RC=$?") || true
RC=$(echo "$OUT" | grep -E '^RC=' | tail -1 | sed 's/RC=//')
if [ "$RC" != "0" ]; then
  fail_msg "expected RC=0, got RC=$RC"
  echo "$OUT" | tail -25 | sed 's/^/    /'
elif ! echo "$OUT" | grep -qE '^INLINE_BROWSER_EVAL=1$'; then
  fail_msg "expected INLINE_BROWSER_EVAL=1 in dry-run dump"
  echo "$OUT" | tail -25 | sed 's/^/    /'
elif echo "$OUT" | grep -q '^DOCKER_PREFIX='; then
  fail_msg "DOCKER_PREFIX unexpectedly present when ISOLATION unset"
  echo "$OUT" | tail -25 | sed 's/^/    /'
elif ! echo "$OUT" | grep -qE '^PIPELINE_EVAL_ISOLATION='; then
  fail_msg "expected PIPELINE_EVAL_ISOLATION field in dry-run dump"
  echo "$OUT" | tail -25 | sed 's/^/    /'
else
  pass_msg "inline branch: INLINE_BROWSER_EVAL=1, no DOCKER_PREFIX"
fi

# ---- Test (c): no Playwright MCP entry + ISOLATION unset -> exit 6 ----
echo "Test (c): no Playwright MCP entry + ISOLATION unset + container-mode -> exit 6 loud refusal"
inc
PROJ_NOMCP="$WORKDIR/proj-nomcp"
mkdir -p "$PROJ_NOMCP/.claude/scripts" "$PROJ_NOMCP/worktree"
cp "$SCRIPT_UNDER_TEST" "$PROJ_NOMCP/.claude/scripts/spawn-claude.sh"
chmod +x "$PROJ_NOMCP/.claude/scripts/spawn-claude.sh"
cp "$PROJ/pipeline.config" "$PROJ_NOMCP/pipeline.config"
# No .mcp.json at all
OUT=$(cd "$PROJ_NOMCP" && \
  PATH="$STUB_DIR:$PATH" \
  STUB_LABELS="" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_LOGS_ENABLED=true \
  PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
  CLAUDE_PLUGIN_ROOT="$PROJ_NOMCP/.claude" \
  bash .claude/scripts/spawn-claude.sh \
    --skill evaluate-issue-pr --container-mode=mock-web-eval \
    "$PROJ_NOMCP/worktree" 302 slug tmux 2>&1 ; echo "RC=$?") || true
RC=$(echo "$OUT" | grep -E '^RC=' | tail -1 | sed 's/RC=//')
if [ "$RC" != "6" ]; then
  fail_msg "expected RC=6 (Playwright MCP missing), got RC=$RC"
  echo "$OUT" | tail -25 | sed 's/^/    /'
elif ! echo "$OUT" | grep -q "host Playwright MCP not detected"; then
  fail_msg "missing expected stderr refusal substring 'host Playwright MCP not detected'"
  echo "$OUT" | tail -25 | sed 's/^/    /'
elif ! echo "$OUT" | grep -q "PIPELINE_EVAL_ISOLATION=container"; then
  fail_msg "stderr should suggest setting PIPELINE_EVAL_ISOLATION=container as remediation"
  echo "$OUT" | tail -25 | sed 's/^/    /'
else
  pass_msg "exit 6 with loud refusal naming Playwright MCP + remediation"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
