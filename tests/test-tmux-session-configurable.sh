#!/bin/bash
set -euo pipefail

# Verifies that PIPELINE_TMUX_SESSION threads through the install pipeline
# and that NO hardcoded `-t dev`, `-s dev`, or `dev:` tmux refs remain in
# rendered SKILL.md or in scripts that source pipeline.config.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# --- Test 1: pipeline.config.example documents PIPELINE_TMUX_SESSION ---
inc
if grep -qE '^PIPELINE_TMUX_SESSION="dev"' "$REPO_ROOT/pipeline.config.example"; then
  pass_msg "PIPELINE_TMUX_SESSION default 'dev' present in pipeline.config.example"
else
  fail_msg "PIPELINE_TMUX_SESSION not documented (or default != dev) in pipeline.config.example"
fi

# --- Test 2: install.sh exports + ENVSUBST_VARS + fallback default ---
inc
if grep -qE 'export[^#]*PIPELINE_TMUX_SESSION' "$REPO_ROOT/install.sh"; then
  pass_msg "install.sh exports PIPELINE_TMUX_SESSION"
else
  fail_msg "install.sh does not export PIPELINE_TMUX_SESSION"
fi

inc
if grep -qE 'ENVSUBST_VARS\+?=.*\$PIPELINE_TMUX_SESSION' "$REPO_ROOT/install.sh"; then
  pass_msg "ENVSUBST_VARS contains \$PIPELINE_TMUX_SESSION"
else
  fail_msg "ENVSUBST_VARS missing \$PIPELINE_TMUX_SESSION"
fi

inc
if grep -qE 'PIPELINE_TMUX_SESSION="?\$\{PIPELINE_TMUX_SESSION:-dev\}"?' "$REPO_ROOT/install.sh"; then
  pass_msg "install.sh applies :-dev fallback for PIPELINE_TMUX_SESSION"
else
  fail_msg "install.sh missing fallback default for PIPELINE_TMUX_SESSION"
fi

# --- Tests 5-10: scripts use ${PIPELINE_TMUX_SESSION:-dev}, not literal `dev` ---
for f in \
  "scripts/run-queue.sh.template" \
  "scripts/spawn-claude.sh.template" \
  "scripts/queue-status.sh" \
; do
  inc
  if grep -qE '\$\{PIPELINE_TMUX_SESSION:-dev\}' "$REPO_ROOT/$f"; then
    pass_msg "$f uses \${PIPELINE_TMUX_SESSION:-dev}"
  else
    fail_msg "$f does not use \${PIPELINE_TMUX_SESSION:-dev}"
  fi

  inc
  bad=$(grep -nE '(-t[[:space:]]+dev([[:space:]]|$|:)|-s[[:space:]]+dev([[:space:]]|$)|tmux[^#]*\bdev:[a-zA-Z0-9_-]+)' "$REPO_ROOT/$f" \
        | grep -v '^[[:space:]]*#' || true)
  if [ -z "$bad" ]; then
    pass_msg "$f has no stale hardcoded dev tmux tokens"
  else
    fail_msg "$f still contains hardcoded dev tmux tokens:"
    echo "$bad" | sed 's/^/      /'
  fi
done

# --- Test 11: queue-status.sh sources pipeline.config ---
inc
if grep -qE '^[[:space:]]*source[[:space:]]+.*pipeline\.config' "$REPO_ROOT/scripts/queue-status.sh"; then
  pass_msg "queue-status.sh sources pipeline.config"
else
  fail_msg "queue-status.sh does not source pipeline.config"
fi

# --- Test 12: install.sh renders SKILL.md.template with custom session name ---
PROJ="$WORKDIR/proj"
PIPE="$PROJ/.claude-pipeline"
mkdir -p "$PIPE/skills/run" "$PIPE/scripts" "$PIPE/hooks" "$PIPE/agents"
mkdir -p "$PROJ/.claude/skills" "$PROJ/.claude/scripts" "$PROJ/.claude/hooks" "$PROJ/.claude/agents"

cp "$REPO_ROOT/install.sh" "$PIPE/install.sh"
chmod +x "$PIPE/install.sh"
cp "$REPO_ROOT/skills/run/SKILL.md.template" "$PIPE/skills/run/SKILL.md.template"

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
PIPELINE_CI_CHECK_ENABLED="true"
PIPELINE_TMUX_SESSION="pipeline-dogfood"
EOF

( cd "$PROJ" && bash .claude-pipeline/install.sh ) >"$WORKDIR/install.log" 2>&1 || {
  fail_msg "install.sh failed"
  cat "$WORKDIR/install.log"
  exit 1
}

RENDERED="$PROJ/.claude/skills/run/SKILL.md"

inc
if grep -q 'pipeline-dogfood' "$RENDERED"; then
  pass_msg "rendered SKILL.md contains 'pipeline-dogfood'"
else
  fail_msg "rendered SKILL.md missing 'pipeline-dogfood'"
fi

inc
stale=$(grep -nE '(-t[[:space:]]+dev([[:space:]]|$|:)|-s[[:space:]]+dev([[:space:]]|$)|tmux[^a-zA-Z0-9_-]*\bdev:[a-zA-Z0-9_-]+)' "$RENDERED" || true)
if [ -z "$stale" ]; then
  pass_msg "rendered SKILL.md has no stale '-t dev' / '-s dev' / 'dev:' tokens"
else
  fail_msg "rendered SKILL.md still contains stale dev tmux tokens:"
  echo "$stale" | sed 's/^/      /'
fi

# --- Test 13: install.sh falls back to 'dev' when var is unset ---
PROJ2="$WORKDIR/proj-default"
PIPE2="$PROJ2/.claude-pipeline"
mkdir -p "$PIPE2/skills/run" "$PIPE2/scripts" "$PIPE2/hooks" "$PIPE2/agents"
mkdir -p "$PROJ2/.claude/skills" "$PROJ2/.claude/scripts" "$PROJ2/.claude/hooks" "$PROJ2/.claude/agents"
cp "$REPO_ROOT/install.sh" "$PIPE2/install.sh"
chmod +x "$PIPE2/install.sh"
cp "$REPO_ROOT/skills/run/SKILL.md.template" "$PIPE2/skills/run/SKILL.md.template"

cat > "$PROJ2/pipeline.config" <<'EOF'
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
PIPELINE_CI_CHECK_ENABLED="true"
EOF

( cd "$PROJ2" && bash .claude-pipeline/install.sh ) >"$WORKDIR/install2.log" 2>&1 || {
  fail_msg "install.sh (default fallback) failed"
  cat "$WORKDIR/install2.log"
  exit 1
}

RENDERED2="$PROJ2/.claude/skills/run/SKILL.md"
inc
if grep -qE 'tmux[^a-zA-Z0-9_-]*\bdev:0|tmux new -s dev -d|tmux attach -t dev' "$RENDERED2"; then
  pass_msg "rendered SKILL.md falls back to 'dev' when PIPELINE_TMUX_SESSION unset"
else
  fail_msg "fallback default 'dev' not present in rendered SKILL.md when var unset"
fi

echo ""
echo "============================="
echo "Total: $TESTS  Pass: $PASS  Fail: $FAIL"
echo "============================="
[ "$FAIL" -eq 0 ] || exit 1
