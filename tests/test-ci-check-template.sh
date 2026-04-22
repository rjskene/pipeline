#!/bin/bash
set -euo pipefail

# Tests for the conditional CI_CHECK marker-block processing in install.sh.
#
# Contract (from issue #177):
#   - Templates can wrap optional blocks in <!-- BEGIN X --> / <!-- END X -->
#     HTML comment delimiters.
#   - When PIPELINE_<X>_ENABLED is "true" (or unset — default enabled),
#     install.sh keeps the block content but strips the marker lines.
#   - When PIPELINE_<X>_ENABLED is anything else (e.g. "" or "false"),
#     install.sh strips the entire block INCLUSIVE of both marker lines.
#   - The marker comments themselves NEVER appear in rendered output.
#
# This test uses the CI_CHECK marker in evaluate-issue-pr/SKILL.md.template
# as the concrete case, since that is the consumer of this feature.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"
REAL_TEMPLATE="$SCRIPT_DIR/../skills/evaluate-issue-pr/SKILL.md.template"

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

if [ ! -f "$REAL_TEMPLATE" ]; then
  echo "ERROR: evaluate-issue-pr template not found at $REAL_TEMPLATE" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

setup_proj() {
  local proj="$1"
  local ci_enabled_value="$2"   # either "true" or empty string
  local pipe="$proj/.claude-pipeline"
  mkdir -p "$pipe/skills/evaluate-issue-pr" "$pipe/scripts" "$pipe/hooks" "$pipe/agents"
  mkdir -p "$proj/.claude/skills" "$proj/.claude/scripts" "$proj/.claude/hooks" "$proj/.claude/agents"

  cp "$INSTALL_SH" "$pipe/install.sh"
  chmod +x "$pipe/install.sh"

  # Use the REAL template so we're testing the actual content shipped to users.
  cp "$REAL_TEMPLATE" "$pipe/skills/evaluate-issue-pr/SKILL.md.template"

  cat > "$proj/pipeline.config" <<EOF
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
PIPELINE_CI_CHECK_ENABLED="$ci_enabled_value"
EOF
}

run_install() {
  local proj="$1"
  local log="$2"
  cd "$proj"
  bash .claude-pipeline/install.sh >"$log" 2>&1 || {
    echo "install.sh failed:"
    cat "$log"
    cd - >/dev/null
    return 1
  }
  cd - >/dev/null
}

# --- Case 1: PIPELINE_CI_CHECK_ENABLED="true" ---
echo "Test 1: CI_CHECK enabled keeps the CI check step in rendered SKILL.md"
PROJ1="$WORKDIR/proj-enabled"
setup_proj "$PROJ1" "true"
run_install "$PROJ1" "$WORKDIR/install1.log" || exit 1

OUT1="$PROJ1/.claude/skills/evaluate-issue-pr/SKILL.md"

inc
if [ -f "$OUT1" ]; then
  pass_msg "rendered SKILL.md exists"
else
  fail_msg "rendered SKILL.md missing"
fi

inc
if grep -q 'Check CI workflow status' "$OUT1"; then
  pass_msg "CI check step present when enabled"
else
  fail_msg "expected CI check step body in rendered SKILL.md (enabled case)"
  sed 's/^/    /' "$OUT1"
fi

inc
if ! grep -q 'BEGIN CI_CHECK' "$OUT1" && ! grep -q 'END CI_CHECK' "$OUT1"; then
  pass_msg "marker comments stripped from rendered SKILL.md (enabled case)"
else
  fail_msg "marker comments leaked into rendered SKILL.md (enabled case)"
  grep -n 'CI_CHECK' "$OUT1" | sed 's/^/    /' || true
fi

# --- Case 2: PIPELINE_CI_CHECK_ENABLED="" (opt-out) ---
echo "Test 2: CI_CHECK disabled strips the entire block from rendered SKILL.md"
PROJ2="$WORKDIR/proj-disabled"
setup_proj "$PROJ2" ""
run_install "$PROJ2" "$WORKDIR/install2.log" || exit 1

OUT2="$PROJ2/.claude/skills/evaluate-issue-pr/SKILL.md"

inc
if [ -f "$OUT2" ]; then
  pass_msg "rendered SKILL.md exists (disabled case)"
else
  fail_msg "rendered SKILL.md missing (disabled case)"
fi

inc
if ! grep -q 'Check CI workflow status' "$OUT2"; then
  pass_msg "CI check step absent when disabled"
else
  fail_msg "CI check step leaked into rendered SKILL.md (disabled case)"
  grep -n -A1 'Check CI workflow status' "$OUT2" | sed 's/^/    /'
fi

inc
if ! grep -q 'BEGIN CI_CHECK' "$OUT2" && ! grep -q 'END CI_CHECK' "$OUT2"; then
  pass_msg "marker comments stripped from rendered SKILL.md (disabled case)"
else
  fail_msg "marker comments leaked into rendered SKILL.md (disabled case)"
  grep -n 'CI_CHECK' "$OUT2" | sed 's/^/    /' || true
fi

# --- Case 3: PIPELINE_CI_CHECK_ENABLED unset entirely -> default enabled ---
echo "Test 3: CI_CHECK defaults to enabled when the variable is absent from config"
PROJ3="$WORKDIR/proj-default"
pipe="$PROJ3/.claude-pipeline"
mkdir -p "$pipe/skills/evaluate-issue-pr" "$pipe/scripts" "$pipe/hooks" "$pipe/agents"
mkdir -p "$PROJ3/.claude/skills" "$PROJ3/.claude/scripts" "$PROJ3/.claude/hooks" "$PROJ3/.claude/agents"
cp "$INSTALL_SH" "$pipe/install.sh"
chmod +x "$pipe/install.sh"
cp "$REAL_TEMPLATE" "$pipe/skills/evaluate-issue-pr/SKILL.md.template"
cat > "$PROJ3/pipeline.config" <<'EOF'
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
run_install "$PROJ3" "$WORKDIR/install3.log" || exit 1

OUT3="$PROJ3/.claude/skills/evaluate-issue-pr/SKILL.md"

inc
if grep -q 'Check CI workflow status' "$OUT3"; then
  pass_msg "CI check step present by default (variable unset)"
else
  fail_msg "expected CI check step body when PIPELINE_CI_CHECK_ENABLED is unset"
fi

inc
if ! grep -q 'BEGIN CI_CHECK' "$OUT3" && ! grep -q 'END CI_CHECK' "$OUT3"; then
  pass_msg "marker comments stripped by default (variable unset)"
else
  fail_msg "marker comments leaked into rendered SKILL.md when variable unset"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
