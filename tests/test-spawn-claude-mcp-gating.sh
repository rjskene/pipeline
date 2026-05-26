#!/bin/bash
set -euo pipefail

# Tests for label-gated MCP attachment in spawn-claude.sh (issue #347):
#   A. issue WITHOUT `needs-browser` -> --mcp-config + --strict-mcp-config injected,
#      synthesised tempfile content is {"mcpServers": {}}.
#   B. issue WITH `needs-browser`    -> neither flag injected (inherits .mcp.json).
#   C. `gh issue view` fails         -> fail-safe to default-deny (empty MCP).
#   D. colliding labels (needs-browser + docs-only) -> needs-browser honoured
#      independently of PATH precedence (PATH stays A, MCP still gated).
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

# Container-mode fixture vars (for Test E). Appended via an unquoted heredoc so
# $WORKDIR expands; the resolver at spawn-claude.sh:466-528 only checks that
# COMPOSE_FILE / SERVICE are non-empty under PIPELINE_SPAWN_DRY_RUN=1 — no
# docker invocation occurs, but a stub compose path must exist on disk so any
# future presence-check stays satisfied.
touch "$WORKDIR/fake-compose.yml"
cat >> "$PROJ/pipeline.config" <<EOF
PIPELINE_EVAL_CONTAINERS="mock-web-eval"
PIPELINE_EVAL_CONTAINER_MOCK_WEB_EVAL_COMPOSE_FILE="$WORKDIR/fake-compose.yml"
PIPELINE_EVAL_CONTAINER_MOCK_WEB_EVAL_SERVICE="fake-service"
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

# Container-mode variant (Test E). Threads --container-mode through and forces
# PIPELINE_EVAL_ISOLATION=container so the inline-browser-eval short-circuit at
# spawn-claude.sh:336 does NOT fire — we want the full container build-argv
# path to execute under dry-run. --skill=evaluate-issue-pr satisfies the
# default PIPELINE_CONTAINER_SKILLS allowlist without needing a needs-browser
# permit (which would defeat the test by setting HAS_NEEDS_BROWSER=1).
run_dryrun_container() {
  local labels="$1" issue="$2" container_mode="$3"
  cd "$PROJ"
  PATH="$STUB_DIR:$PATH" \
    STUB_LABELS="$labels" \
    STUB_GH_FAIL="${STUB_GH_FAIL:-0}" \
    PIPELINE_SPAWN_DRY_RUN=1 \
    PIPELINE_LOGS_ENABLED=true \
    PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
    PIPELINE_EVAL_ISOLATION=container \
    bash .claude/scripts/spawn-claude.sh \
      --skill evaluate-issue-pr \
      "--container-mode=$container_mode" \
      "$PROJ/worktree" "$issue" slug tmux 2>/dev/null
  cd - >/dev/null
}

build_block() { echo "$1" | sed -n '/^=== BUILD_ARGV ===$/,/^=== END BUILD_ARGV ===$/p'; }

# -------------------------------------------------------------------------
# Test A: no `needs-browser` label -> empty-MCP config injected.
# -------------------------------------------------------------------------
echo "Test A: no needs-browser -> --mcp-config + --strict-mcp-config injected"
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
# Test B: `needs-browser` label present -> neither flag injected.
# -------------------------------------------------------------------------
echo "Test B: needs-browser present -> no MCP gating (inherits .mcp.json)"
OUT=$(run_dryrun "needs-browser" 901)
BLOCK=$(build_block "$OUT")

inc
if ! echo "$BLOCK" | grep -qF -- '--mcp-config'; then
  pass_msg "B: --mcp-config absent"
else
  fail_msg "B: --mcp-config unexpectedly present"
  echo "$BLOCK" | sed 's/^/    /'
fi

inc
if ! echo "$BLOCK" | grep -qF -- '--strict-mcp-config'; then
  pass_msg "B: --strict-mcp-config absent"
else
  fail_msg "B: --strict-mcp-config unexpectedly present"
fi

inc
if echo "$OUT" | grep -qE '^EMPTY_MCP_FILE=$'; then
  pass_msg "B: EMPTY_MCP_FILE dump line present and empty (branch taken)"
else
  fail_msg "B: EMPTY_MCP_FILE expected empty"
  echo "$OUT" | grep -E '^EMPTY_MCP_FILE=' | sed 's/^/    /' || true
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

# -------------------------------------------------------------------------
# Test D: colliding labels (docs-only + needs-browser) -> PATH A, still gated.
# -------------------------------------------------------------------------
echo "Test D: docs-only + needs-browser -> PATH A and MCP still gated"
OUT=$(run_dryrun "docs-only"$'\n'"needs-browser" 903)
BLOCK=$(build_block "$OUT")

inc
if echo "$OUT" | grep -qE '^PATH_LETTER=A$'; then
  pass_msg "D: PATH stays A (existing precedence)"
else
  fail_msg "D: expected PATH_LETTER=A"
  echo "$OUT" | grep -E '^PATH_LETTER=' | sed 's/^/    /' || true
fi

inc
if ! echo "$BLOCK" | grep -qF -- '--mcp-config'; then
  pass_msg "D: needs-browser honoured independently of path (no --mcp-config)"
else
  fail_msg "D: --mcp-config unexpectedly present despite needs-browser"
  echo "$BLOCK" | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test E: CONTAINER_MODE set + no needs-browser -> empty-MCP branch SKIPPED.
# Regression guard for #516: the host-side empty-MCP tempfile at /tmp/... is
# unreachable inside the container, so the gate must skip the branch when
# CONTAINER_MODE is set (container is the authority on MCP visibility).
# -------------------------------------------------------------------------
echo "Test E: CONTAINER_MODE + no needs-browser -> empty-MCP branch skipped"
OUT=$(run_dryrun_container "" 904 mock-web-eval)
BLOCK=$(build_block "$OUT")

inc
if echo "$OUT" | grep -qE '^EMPTY_MCP_FILE=$'; then
  pass_msg "E: EMPTY_MCP_FILE empty under container mode"
else
  fail_msg "E: EMPTY_MCP_FILE expected empty under container mode"
  echo "$OUT" | grep -E '^EMPTY_MCP_FILE=' | sed 's/^/    /' || true
fi

inc
if ! echo "$BLOCK" | grep -qE 'CLAUDE_ARGV\+=\(--mcp-config\)'; then
  pass_msg "E: --mcp-config token absent under container mode"
else
  fail_msg "E: --mcp-config unexpectedly present under container mode"
  echo "$BLOCK" | sed 's/^/    /'
fi

inc
if ! echo "$BLOCK" | grep -qE 'CLAUDE_ARGV\+=\(--strict-mcp-config\)'; then
  pass_msg "E: --strict-mcp-config token absent under container mode"
else
  fail_msg "E: --strict-mcp-config unexpectedly present under container mode"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
