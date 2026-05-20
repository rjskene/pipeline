#!/bin/bash
set -euo pipefail

# Tests for the label -> PATH picker in spawn-claude.sh:
#   - no labels           -> B (default)
#   - unrelated label     -> B
#   - docs-only           -> A
#   - multi-task          -> C
#   - both docs + multi   -> A (collision, warns on stderr)
#
# Runs spawn-claude.sh with PIPELINE_SPAWN_DRY_RUN=1 (a test-only env hook that
# prints the resolved PATH_LETTER and the payload file, then exits before
# launching claude). A stub `gh` on PATH returns labels from STUB_LABELS.

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

# Minimal pipeline.config — includes path-family keys so the dry-run can
# resolve lookups and print a PATH_LETTER.
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

# Create a dummy worktree dir (spawn-claude.sh checks it exists)
mkdir -p "$PROJ/worktree"

# Stub gh: reads labels from STUB_LABELS (one per line). STUB_GH_FAIL=1 -> exit 1.
STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
if [ "${STUB_GH_FAIL:-0}" = "1" ]; then
  exit 1
fi
# Emulate: gh issue view N --repo R --json labels --jq '.labels[].name'
printf '%s\n' "${STUB_LABELS:-}"
EOF
chmod +x "$STUB_DIR/gh"

run_picker() {
  local labels="$1"
  local fail_gh="${2:-0}"
  cd "$PROJ"
  PATH="$STUB_DIR:$PATH" \
    STUB_LABELS="$labels" \
    STUB_GH_FAIL="$fail_gh" \
    PIPELINE_SPAWN_DRY_RUN=1 \
    bash .claude/scripts/spawn-claude.sh "$PROJ/worktree" 999 slug tmux 2>/dev/null | \
    (grep -E '^PATH_LETTER=' | head -1 | cut -d= -f2 || true)
  cd - >/dev/null
}

run_picker_stderr() {
  local labels="$1"
  cd "$PROJ"
  PATH="$STUB_DIR:$PATH" \
    STUB_LABELS="$labels" \
    PIPELINE_SPAWN_DRY_RUN=1 \
    bash .claude/scripts/spawn-claude.sh "$PROJ/worktree" 999 slug tmux 2>&1 >/dev/null
  cd - >/dev/null
}

echo "Test 1: no labels -> B"
inc
OUT=$(run_picker "")
if [ "$OUT" = "B" ]; then pass_msg "empty labels -> B"; else fail_msg "empty labels -> got '$OUT' (expected B)"; fi

echo "Test 2: unrelated label -> B"
inc
OUT=$(run_picker "bug")
if [ "$OUT" = "B" ]; then pass_msg "unrelated label -> B"; else fail_msg "unrelated label -> got '$OUT' (expected B)"; fi

echo "Test 3: docs-only -> A"
inc
OUT=$(run_picker "docs-only")
if [ "$OUT" = "A" ]; then pass_msg "docs-only -> A"; else fail_msg "docs-only -> got '$OUT' (expected A)"; fi

echo "Test 4: multi-task -> C"
inc
OUT=$(run_picker "multi-task")
if [ "$OUT" = "C" ]; then pass_msg "multi-task -> C"; else fail_msg "multi-task -> got '$OUT' (expected C)"; fi

echo "Test 5: both docs-only + multi-task -> A (collision)"
inc
OUT=$(run_picker "$(printf 'docs-only\nmulti-task')")
if [ "$OUT" = "A" ]; then pass_msg "both -> A"; else fail_msg "both -> got '$OUT' (expected A)"; fi

echo "Test 6: collision emits stderr warning"
inc
ERR=$(run_picker_stderr "$(printf 'docs-only\nmulti-task')")
if echo "$ERR" | grep -q "both docs-only and multi-task"; then
  pass_msg "stderr warning contains 'both docs-only and multi-task'"
else
  fail_msg "expected stderr warning mentioning the collision; got:"
  echo "$ERR" | sed 's/^/    /'
fi

echo "Test 6a: quick-fix -> D (no warning)"
inc
OUT=$(run_picker "quick-fix")
if [ "$OUT" = "D" ]; then pass_msg "quick-fix -> D"; else fail_msg "quick-fix -> got '$OUT' (expected D)"; fi

inc
ERR=$(run_picker_stderr "quick-fix")
if echo "$ERR" | grep -qi "warning"; then
  fail_msg "quick-fix alone should NOT emit a collision warning; got:"
  echo "$ERR" | sed 's/^/    /'
else
  pass_msg "quick-fix alone emits no collision warning"
fi

echo "Test 6b: docs-only + quick-fix -> A (collision, A wins)"
inc
OUT=$(run_picker "$(printf 'docs-only\nquick-fix')")
if [ "$OUT" = "A" ]; then pass_msg "docs-only+quick-fix -> A"; else fail_msg "docs-only+quick-fix -> got '$OUT' (expected A)"; fi

inc
ERR=$(run_picker_stderr "$(printf 'docs-only\nquick-fix')")
if echo "$ERR" | grep -qi "warning" && echo "$ERR" | grep -q "docs-only" && echo "$ERR" | grep -q "quick-fix"; then
  pass_msg "stderr warning mentions docs-only and quick-fix"
else
  fail_msg "expected warning mentioning docs-only and quick-fix; got:"
  echo "$ERR" | sed 's/^/    /'
fi

echo "Test 6c: quick-fix + multi-task -> D (collision, D wins over C)"
inc
OUT=$(run_picker "$(printf 'quick-fix\nmulti-task')")
if [ "$OUT" = "D" ]; then pass_msg "quick-fix+multi-task -> D"; else fail_msg "quick-fix+multi-task -> got '$OUT' (expected D)"; fi

inc
ERR=$(run_picker_stderr "$(printf 'quick-fix\nmulti-task')")
if echo "$ERR" | grep -qi "warning" && echo "$ERR" | grep -q "quick-fix" && echo "$ERR" | grep -q "multi-task"; then
  pass_msg "stderr warning mentions quick-fix and multi-task"
else
  fail_msg "expected warning mentioning quick-fix and multi-task; got:"
  echo "$ERR" | sed 's/^/    /'
fi

echo "Test 6d: docs-only + quick-fix + multi-task -> A (A always wins)"
inc
OUT=$(run_picker "$(printf 'docs-only\nquick-fix\nmulti-task')")
if [ "$OUT" = "A" ]; then pass_msg "all three -> A"; else fail_msg "all three -> got '$OUT' (expected A)"; fi

inc
ERR=$(run_picker_stderr "$(printf 'docs-only\nquick-fix\nmulti-task')")
if echo "$ERR" | grep -qi "warning" \
   && echo "$ERR" | grep -q "docs-only" \
   && echo "$ERR" | grep -q "quick-fix" \
   && echo "$ERR" | grep -q "multi-task"; then
  pass_msg "stderr warning mentions all three labels"
else
  fail_msg "expected warning mentioning all three labels; got:"
  echo "$ERR" | sed 's/^/    /'
fi

echo "Test 7: gh failure falls back to B (no hard error)"
inc
OUT=$(run_picker "" 1)
if [ "$OUT" = "B" ]; then pass_msg "gh failure -> B"; else fail_msg "gh failure -> got '$OUT' (expected B)"; fi

echo "Test 8: gh failure emits stderr warn message"
inc
cd "$PROJ"
STDERR_FILE="$WORKDIR/test8-stderr.txt"
PATH="$STUB_DIR:$PATH" \
  STUB_LABELS="" \
  STUB_GH_FAIL=1 \
  PIPELINE_SPAWN_DRY_RUN=1 \
  bash .claude/scripts/spawn-claude.sh "$PROJ/worktree" 999 slug tmux 2>"$STDERR_FILE" >/dev/null
cd - >/dev/null
if grep -q '\[spawn-claude\] WARN: gh issue view failed' "$STDERR_FILE"; then
  pass_msg "stderr contains '[spawn-claude] WARN: gh issue view failed'"
else
  fail_msg "expected stderr warning; got:"
  sed 's/^/    /' "$STDERR_FILE"
fi

echo "Test 9: BUILD_ARGV exports CLAUDE_PIPELINE_ISSUE_NUMBER and CLAUDE_PIPELINE_SKILL"
inc
if grep -q 'export CLAUDE_PIPELINE_ISSUE_NUMBER=' "$SCRIPT_UNDER_TEST" \
   && grep -q 'export CLAUDE_PIPELINE_SKILL=' "$SCRIPT_UNDER_TEST"; then
  pass_msg "both env exports present in template"
else
  fail_msg "expected 'export CLAUDE_PIPELINE_ISSUE_NUMBER=' and 'export CLAUDE_PIPELINE_SKILL=' in template"
fi

echo "Test 10: spawn-claude-canary stderr line present in template"
inc
if grep -q 'spawn-claude-canary' "$SCRIPT_UNDER_TEST"; then
  pass_msg "canary string present"
else
  fail_msg "expected 'spawn-claude-canary' marker in template"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
