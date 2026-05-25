#!/bin/bash
set -uo pipefail

# Tests the label-aware container-mode fallback added by issue #368 to
# scripts/spawn-claude.sh. The static PIPELINE_CONTAINER_SKILLS allowlist
# (#321) still rejects execute-issue-plan by default, BUT a per-invocation
# permit path lets execute-issue-plan through when the issue carries the
# needs-browser label. gh-failure and unset-ISSUE_NUM must FAIL CLOSED.
#
# Mirrors the harness of tests/test-spawn-claude-container-skills-allowlist.sh:
# copies spawn-claude.sh into $PROJ/.claude/scripts/, declares an eval
# container in pipeline.config, stubs gh/docker on PATH, runs with
# PIPELINE_SPAWN_DRY_RUN=1. In dry-run a PERMITTED container dispatch exits 0
# and emits a line matching ^DOCKER_PREFIX=.
#
# Three cases:
#   (a) execute-issue-plan + container-mode + no needs-browser label +
#       default allowlist -> RC=4 + "not in PIPELINE_CONTAINER_SKILLS allowlist".
#   (b) execute-issue-plan + container-mode + needs-browser label -> RC=0,
#       DOCKER_PREFIX present + "container-mode permitted ... via needs-browser".
#   (c) execute-issue-plan + container-mode + gh fails -> RC=4 (fail-closed).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/../scripts/spawn-claude.sh"

COUNT=0
FAILS=0

pass_msg() { echo "  PASS: $1"; }
fail_msg() { echo "  FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
inc()      { COUNT=$((COUNT + 1)); }

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
PIPELINE_EVAL_CONTAINERS="mock-web-eval"
PIPELINE_EVAL_CONTAINER_mock_web_eval_COMPOSE_FILE="compose.mock-web-eval.yml"
PIPELINE_EVAL_CONTAINER_mock_web_eval_ENV_FILE=".env.mock-web-eval"
PIPELINE_EVAL_CONTAINER_mock_web_eval_SERVICE="claude-mock-web-eval"
EOF

mkdir -p "$PROJ/worktree"

STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
# gh stub: prints $STUB_LABELS one-per-line. When STUB_GH_FAIL is set it
# exits non-zero (simulates offline/auth failure) so the fail-closed path
# can be exercised.
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
if [ -n "${STUB_GH_FAIL:-}" ]; then
  exit 1
fi
printf '%s\n' "${STUB_LABELS:-}"
EOF
chmod +x "$STUB_DIR/gh"

cat > "$STUB_DIR/docker" <<'EOF'
#!/bin/bash
echo "STUB_DOCKER $*"
EOF
chmod +x "$STUB_DIR/docker"

RUNS_LOG="$WORKDIR/runs.log"

# run_case <skill> <issue> [STUB_LABELS] [STUB_GH_FAIL]
# Uses the default (unset) PIPELINE_CONTAINER_SKILLS allowlist throughout, so
# execute-issue-plan is rejected unless the label-aware permit path applies.
# Echoes the merged stdout+stderr followed by a trailing "RC=<rc>" line.
run_case() {
  local skill="$1" issue="$2" labels="${3:-}" ghfail="${4:-}"
  (cd "$PROJ" && \
    PATH="$STUB_DIR:$PATH" \
    STUB_LABELS="$labels" \
    STUB_GH_FAIL="$ghfail" \
    PIPELINE_SPAWN_DRY_RUN=1 \
    PIPELINE_LOGS_ENABLED=true \
    PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
    bash .claude/scripts/spawn-claude.sh \
      --skill "$skill" --container-mode=mock-web-eval \
      "$PROJ/worktree" "$issue" slug tmux 2>&1
    echo "RC=$?")
}

# -------------------------------------------------------------------------
# Case (a): execute-issue-plan + container-mode + NO needs-browser label
# + default allowlist -> exit 4, allowlist-rejection stderr.
# -------------------------------------------------------------------------
echo "Case (a): execute-issue-plan, no needs-browser label -> rejected (RC=4)"
inc
OUT="$(run_case execute-issue-plan 301 "")"
RC=$(echo "$OUT" | grep -E '^RC=' | tail -1 | sed 's/RC=//')
if [ "$RC" != "4" ]; then
  fail_msg "expected RC=4, got RC=$RC"
  echo "$OUT" | tail -10 | sed 's/^/    /'
elif ! echo "$OUT" | grep -q "not in PIPELINE_CONTAINER_SKILLS allowlist"; then
  fail_msg "missing expected allowlist-rejection stderr"
  echo "$OUT" | tail -10 | sed 's/^/    /'
else
  pass_msg "RC=4 + allowlist-rejection stderr (no needs-browser label)"
fi

# -------------------------------------------------------------------------
# Case (b): execute-issue-plan + container-mode + needs-browser label
# -> exit 0, DOCKER_PREFIX present, permit stderr.
# -------------------------------------------------------------------------
echo "Case (b): execute-issue-plan, needs-browser label -> permitted (RC=0)"
inc
OUT="$(run_case execute-issue-plan 302 "needs-browser")"
RC=$(echo "$OUT" | grep -E '^RC=' | tail -1 | sed 's/RC=//')
if [ "$RC" != "0" ]; then
  fail_msg "expected RC=0, got RC=$RC"
  echo "$OUT" | tail -10 | sed 's/^/    /'
elif ! echo "$OUT" | grep -qE '^DOCKER_PREFIX='; then
  fail_msg "missing DOCKER_PREFIX= line in dry-run output"
  echo "$OUT" | tail -10 | sed 's/^/    /'
elif ! echo "$OUT" | grep -q "container-mode permitted for execute-issue-plan via needs-browser label"; then
  fail_msg "missing expected permit stderr"
  echo "$OUT" | tail -10 | sed 's/^/    /'
else
  pass_msg "RC=0 + DOCKER_PREFIX + permit stderr (needs-browser label)"
fi

# -------------------------------------------------------------------------
# Case (c): execute-issue-plan + container-mode + gh fails -> FAIL CLOSED
# -> exit 4, allowlist-rejection stderr.
# -------------------------------------------------------------------------
echo "Case (c): execute-issue-plan, gh fails -> fail-closed (RC=4)"
inc
OUT="$(run_case execute-issue-plan 303 "needs-browser" 1)"
RC=$(echo "$OUT" | grep -E '^RC=' | tail -1 | sed 's/RC=//')
if [ "$RC" != "4" ]; then
  fail_msg "expected RC=4, got RC=$RC"
  echo "$OUT" | tail -10 | sed 's/^/    /'
elif ! echo "$OUT" | grep -q "not in PIPELINE_CONTAINER_SKILLS allowlist"; then
  fail_msg "missing expected allowlist-rejection stderr (fail-closed)"
  echo "$OUT" | tail -10 | sed 's/^/    /'
else
  pass_msg "RC=4 + allowlist-rejection stderr (gh failed -> fail-closed)"
fi

echo ""
echo "================================"
echo "  $COUNT tests: FAIL=$FAILS"
echo "================================"

if [ "$FAILS" = "0" ]; then
  echo "OK: $COUNT tests passed"
  exit 0
else
  echo "FAIL: $FAILS of $COUNT tests"
  exit 1
fi
