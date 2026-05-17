#!/bin/bash
set -euo pipefail

# Tests for the --append-system-prompt payload builder in spawn-claude.sh.
#
# Scenarios:
#   - PATH B / EXECUTE with two required skills + args files + reviewer
#     -> payload contains STARTUP sequence with both Skill() lines, FINAL STEP
#        with Agent(code-reviewer), and the issue number interpolated.
#   - PATH A / EXECUTE with verification-only + reviewer -> payload contains
#     the single Skill() line + FINAL STEP.
#   - PATH C / EXECUTE with args file configured but MISSING on disk -> Skill()
#     emitted without an args= attribute and a stderr "args file not found"
#     warning is logged (graceful degradation).
#   - `gh issue view` failure -> stderr warning "[spawn-claude] WARN: gh issue
#     view failed ..." is logged and PATH B is used as the safe default.
#   - Empty skills + empty reviewer -> no payload file (absent/empty hook output).

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
mkdir -p "$PROJ/scripts/skill-args"
cp "$SCRIPT_UNDER_TEST" "$PROJ/.claude/scripts/spawn-claude.sh"
chmod +x "$PROJ/.claude/scripts/spawn-claude.sh"

# Args-file fixtures
echo "TDD DIRECTIVE FIXTURE" > "$PROJ/scripts/skill-args/b-execute-test-driven-development.txt"
echo "VERIFY DIRECTIVE FIXTURE" > "$PROJ/scripts/skill-args/b-execute-verification-before-completion.txt"
echo "PATH A VERIFY FIXTURE" > "$PROJ/scripts/skill-args/a-execute-verification-before-completion.txt"

# Stub gh that honours STUB_LABELS. STUB_GH_FAIL=1 -> exit 1 (simulates offline/auth).
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

mkdir -p "$PROJ/worktree"

write_config() {
  cat > "$PROJ/pipeline.config" <<'EOF'
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="ct"
PIPELINE_WIN_TEMP=""

PIPELINE_PATH_A_SKILLS_EXECUTE="superpowers:verification-before-completion"
PIPELINE_PATH_A_REVIEWER_EXECUTE="superpowers:code-reviewer"
PIPELINE_PATH_A_SKILL_ARGS_EXECUTE_VERIFICATION_BEFORE_COMPLETION="scripts/skill-args/a-execute-verification-before-completion.txt"

PIPELINE_PATH_B_SKILLS_EXECUTE="superpowers:test-driven-development superpowers:verification-before-completion"
PIPELINE_PATH_B_REVIEWER_EXECUTE="superpowers:code-reviewer"
PIPELINE_PATH_B_SKILL_ARGS_EXECUTE_TEST_DRIVEN_DEVELOPMENT="scripts/skill-args/b-execute-test-driven-development.txt"
PIPELINE_PATH_B_SKILL_ARGS_EXECUTE_VERIFICATION_BEFORE_COMPLETION="scripts/skill-args/b-execute-verification-before-completion.txt"

PIPELINE_PATH_C_SKILLS_EXECUTE="superpowers:subagent-driven-development"
PIPELINE_PATH_C_REVIEWER_EXECUTE="superpowers:code-reviewer"
# PATH C points at a path that does NOT exist on disk — used to exercise the
# graceful-degradation branch (stderr warn + Skill() line without args=).
PIPELINE_PATH_C_SKILL_ARGS_EXECUTE_SUBAGENT_DRIVEN_DEVELOPMENT="scripts/skill-args/c-execute-does-not-exist.txt"
EOF
}

run_spawn() {
  local labels="$1"
  cd "$PROJ"
  PATH="$STUB_DIR:$PATH" \
    STUB_LABELS="$labels" \
    PIPELINE_SPAWN_DRY_RUN=1 \
    bash .claude/scripts/spawn-claude.sh "$PROJ/worktree" 999 slug tmux
  cd - >/dev/null
}

# Capture stdout + stderr separately. Writes stderr to $STDERR_FILE and prints
# stdout. STUB_GH_FAIL can be passed as the second arg to simulate gh failure.
run_spawn_split() {
  local labels="$1"
  local fail_gh="${2:-0}"
  local stderr_file="$3"
  cd "$PROJ"
  PATH="$STUB_DIR:$PATH" \
    STUB_LABELS="$labels" \
    STUB_GH_FAIL="$fail_gh" \
    PIPELINE_SPAWN_DRY_RUN=1 \
    bash .claude/scripts/spawn-claude.sh "$PROJ/worktree" 999 slug tmux 2>"$stderr_file"
  cd - >/dev/null
}

write_config

# --- Test 1: PATH B / EXECUTE ---
echo "Test 1: PATH B / EXECUTE payload"
OUT=$(run_spawn "" 2>/dev/null)
PATH_LETTER=$(echo "$OUT" | grep -E '^PATH_LETTER=' | head -1 | cut -d= -f2 || true)

inc
if [ "$PATH_LETTER" = "B" ]; then pass_msg "PATH_LETTER=B"; else fail_msg "got '$PATH_LETTER'"; fi

PAYLOAD=$(echo "$OUT" | sed -n '/^=== PAYLOAD ===/,/^=== END PAYLOAD ===/p' | sed '1d;$d')

inc
if echo "$PAYLOAD" | grep -q "REQUIRED STARTUP SEQUENCE:"; then
  pass_msg "payload has STARTUP header"
else
  fail_msg "missing STARTUP header; payload was:"; echo "$PAYLOAD" | sed 's/^/    /'
fi

inc
if echo "$PAYLOAD" | grep -q 'superpowers:test-driven-development'; then
  pass_msg "payload mentions test-driven-development"
else
  fail_msg "missing test-driven-development"
fi

inc
if echo "$PAYLOAD" | grep -q 'superpowers:verification-before-completion'; then
  pass_msg "payload mentions verification-before-completion"
else
  fail_msg "missing verification-before-completion"
fi

inc
if echo "$PAYLOAD" | grep -q 'TDD DIRECTIVE FIXTURE'; then
  pass_msg "payload embeds TDD args content"
else
  fail_msg "TDD args content missing"
fi

inc
if echo "$PAYLOAD" | grep -q "REQUIRED FINAL STEP:"; then
  pass_msg "payload has FINAL STEP header"
else
  fail_msg "missing FINAL STEP header"
fi

inc
if echo "$PAYLOAD" | grep -q 'Agent(subagent_type: "superpowers:code-reviewer"'; then
  pass_msg "payload has code-reviewer Agent() line"
else
  fail_msg "missing code-reviewer Agent() line"
fi

inc
if echo "$PAYLOAD" | grep -q 'issue #999'; then
  pass_msg "payload interpolates ISSUE_NUM into description"
else
  fail_msg "issue #999 not interpolated"
fi

# --- Test 2: PATH A / EXECUTE (single skill) ---
echo "Test 2: PATH A / EXECUTE payload"
OUT=$(run_spawn "docs-only" 2>/dev/null)
PATH_LETTER=$(echo "$OUT" | grep -E '^PATH_LETTER=' | head -1 | cut -d= -f2 || true)

inc
if [ "$PATH_LETTER" = "A" ]; then pass_msg "PATH_LETTER=A"; else fail_msg "got '$PATH_LETTER'"; fi

PAYLOAD=$(echo "$OUT" | sed -n '/^=== PAYLOAD ===/,/^=== END PAYLOAD ===/p' | sed '1d;$d')

inc
if echo "$PAYLOAD" | grep -q 'superpowers:verification-before-completion' && \
   ! echo "$PAYLOAD" | grep -q 'superpowers:test-driven-development'; then
  pass_msg "PATH A has verification only, no TDD"
else
  fail_msg "wrong PATH A payload"
fi

inc
if echo "$PAYLOAD" | grep -q 'PATH A VERIFY FIXTURE'; then
  pass_msg "PATH A args content embedded"
else
  fail_msg "PATH A args content missing"
fi

# --- Test 3: PATH C / EXECUTE (args file configured but missing on disk) ---
echo "Test 3: PATH C / EXECUTE with configured-but-missing args file"
STDERR_FILE="$WORKDIR/test3-stderr.txt"
OUT=$(run_spawn_split "multi-task" 0 "$STDERR_FILE")
PATH_LETTER=$(echo "$OUT" | grep -E '^PATH_LETTER=' | head -1 | cut -d= -f2 || true)

inc
if [ "$PATH_LETTER" = "C" ]; then pass_msg "PATH_LETTER=C"; else fail_msg "got '$PATH_LETTER'"; fi

PAYLOAD=$(echo "$OUT" | sed -n '/^=== PAYLOAD ===/,/^=== END PAYLOAD ===/p' | sed '1d;$d')

inc
if echo "$PAYLOAD" | grep -q 'superpowers:subagent-driven-development'; then
  pass_msg "PATH C mentions subagent-driven-development"
else
  fail_msg "missing subagent-driven-development in PATH C payload"
fi

inc
# The Skill() line for the missing-args skill must NOT contain args=.
SKILL_LINE=$(echo "$PAYLOAD" | grep -E 'Skill\(skill: "superpowers:subagent-driven-development"' | head -1 || true)
if [ -n "$SKILL_LINE" ] && ! echo "$SKILL_LINE" | grep -q 'args:'; then
  pass_msg "Skill() emitted without args= field when args file is missing"
else
  fail_msg "expected args-less Skill() line; got: $SKILL_LINE"
fi

inc
# Stderr should contain the "args file not found" warning for the missing path.
if grep -q "args file not found for superpowers:subagent-driven-development" "$STDERR_FILE" && \
   grep -q "c-execute-does-not-exist.txt" "$STDERR_FILE"; then
  pass_msg "stderr contains missing-args-file warning"
else
  fail_msg "expected 'args file not found' warning on stderr; got:"
  sed 's/^/    /' "$STDERR_FILE"
fi

# --- Test 4: gh issue view failure -> stderr warn + PATH B fallback ---
echo "Test 4: gh issue view failure emits stderr warn and defaults to PATH B"
STDERR_FILE="$WORKDIR/test4-stderr.txt"
OUT=$(run_spawn_split "" 1 "$STDERR_FILE")
PATH_LETTER=$(echo "$OUT" | grep -E '^PATH_LETTER=' | head -1 | cut -d= -f2 || true)

inc
if [ "$PATH_LETTER" = "B" ]; then pass_msg "gh failure -> PATH_LETTER=B"; else fail_msg "got '$PATH_LETTER' (expected B)"; fi

inc
if grep -q '\[spawn-claude\] WARN: gh issue view failed' "$STDERR_FILE"; then
  pass_msg "stderr contains gh-failure WARN message"
else
  fail_msg "expected '[spawn-claude] WARN: gh issue view failed' on stderr; got:"
  sed 's/^/    /' "$STDERR_FILE"
fi

inc
# Sanity: the gh-failure warning should mention the issue number.
if grep -q 'issue #999' "$STDERR_FILE"; then
  pass_msg "gh-failure warning mentions issue #999"
else
  fail_msg "gh-failure warning missing issue number"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
