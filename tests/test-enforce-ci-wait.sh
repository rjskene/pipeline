#!/bin/bash
set -euo pipefail

# Tests for the CI-wait enforcement Stop hook (hooks/enforce-ci-wait.py).
#
# The hook is a Stop gate that:
#   - Exits 0 (allow) if CLAUDE_PIPELINE_SKILL is unset or not 'evaluate-issue-pr'.
#   - Exits 0 (allow) if the PR under review has no CI checks configured.
#   - Exits 2 (block) if CI is configured but no `gh pr checks ... --watch` row
#     was recorded for the session.
#   - Exits 2 (block) if `--watch` ran but no second `statusCheckRollup` query
#     followed it.
#   - Exits 2 (block) if an Approved verdict was posted while the final rollup
#     contains FAILURE or CANCELLED.
#   - Tracks block counts per-session under .claude/logs/enforce-ci-wait-state/
#     and on the third block, labels the issue `needs-human` and posts a PR
#     comment summarising the gate firing.
#   - Fail-open: any unexpected exception writes to
#     .claude/logs/enforce-ci-wait-errors.log and exits 0.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/enforce-ci-wait.py"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

if [ ! -f "$HOOK" ]; then
  echo "ERROR: hook not found at $HOOK" >&2
  echo "Test 0: hook exists"
  inc
  fail_msg "missing $HOOK"
  echo ""
  echo "================================"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  echo "================================"
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/.claude/logs"
printf 'PIPELINE_REPO="fake/repo"\n' > "$PROJ/pipeline.config"

# Stub gh on PATH. Reads STUB_GH_OUT to know what to print; defaults to empty JSON.
# When STUB_GH_FAIL=1, exits 1.
STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
# Record invocation for assertion
echo "$@" >> "${STUB_GH_CALLS:-/dev/null}"
if [ "${STUB_GH_FAIL:-0}" = "1" ]; then
  exit 1
fi
# Allow per-call output via STUB_GH_OUT (printed verbatim).
printf '%s' "${STUB_GH_OUT:-}"
EOF
chmod +x "$STUB_DIR/gh"

# Helper: write a row to .claude/logs/tool-use.log.
# TSV columns: timestamp \t phase \t tool \t session=<sid> \t summary
seed_log_row() {
  local ts="$1"
  local session="$2"
  local tool="$3"
  local summary="$4"
  printf '%s\tpost\t%s\tsession=%s\t%s\n' "$ts" "$tool" "$session" "$summary" \
    >> "$PROJ/.claude/logs/tool-use.log"
}

reset_state() {
  rm -f "$PROJ/.claude/logs/tool-use.log"
  rm -rf "$PROJ/.claude/logs/enforce-ci-wait-state"
  rm -f "$PROJ/.claude/logs/enforce-ci-wait-errors.log"
  : > "$WORKDIR/gh-calls.log"
}

# Helper: run hook with stdin JSON payload + env. Echoes exit code on the last line.
run_hook() {
  local stdin_payload="$1"
  shift
  local out_file="$WORKDIR/out.txt"
  local err_file="$WORKDIR/err.txt"
  cd "$PROJ"
  set +e
  echo "$stdin_payload" | env -i \
    HOME="$HOME" \
    PATH="$STUB_DIR:/usr/bin:/bin" \
    CLAUDE_PROJECT_DIR="$PROJ" \
    STUB_GH_CALLS="$WORKDIR/gh-calls.log" \
    "$@" \
    python3 "$HOOK" >"$out_file" 2>"$err_file"
  local rc=$?
  set -e
  cd - >/dev/null
  echo "$rc"
}

# --- Test 1a: CLAUDE_PIPELINE_SKILL unset -> exit 0 (skip) ---
echo "Test 1a: CLAUDE_PIPELINE_SKILL unset -> exit 0"
inc
reset_state
PAYLOAD='{"session_id":"sess-1a","cwd":"'"$PROJ"'"}'
RC=$(run_hook "$PAYLOAD")
if [ "$RC" = "0" ]; then pass_msg "exit 0 (skill unset)"; else fail_msg "expected exit 0, got $RC"; fi

# --- Test 1b: wrong skill -> exit 0 (skip) ---
echo "Test 1b: CLAUDE_PIPELINE_SKILL=plan-issue -> exit 0"
inc
reset_state
PAYLOAD='{"session_id":"sess-1b","cwd":"'"$PROJ"'"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_SKILL=plan-issue)
if [ "$RC" = "0" ]; then pass_msg "exit 0 (wrong skill)"; else fail_msg "expected exit 0, got $RC"; fi

# --- Test 2: no CI configured -> exit 0 (gh returns empty rollup) ---
echo "Test 2: PR has no CI configured -> exit 0"
inc
reset_state
seed_log_row "2026-05-14T10:00:00Z" "sess-2" "Bash" \
  "gh pr view 123 --repo fake/repo --json statusCheckRollup"
PAYLOAD='{"session_id":"sess-2","cwd":"'"$PROJ"'"}'
# gh stub returns "0" — the --jq '. | length' for an empty rollup yields 0.
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_SKILL=evaluate-issue-pr STUB_GH_OUT="0")
if [ "$RC" = "0" ]; then pass_msg "exit 0 (no CI)"; else fail_msg "expected exit 0, got $RC"; fi

# --- Test 3: CI present, no --watch invocation -> exit 2 ---
echo "Test 3: CI present, no --watch -> exit 2 with stderr"
inc
reset_state
seed_log_row "2026-05-14T10:00:00Z" "sess-3" "Bash" \
  "gh pr view 123 --repo fake/repo --json statusCheckRollup"
PAYLOAD='{"session_id":"sess-3","cwd":"'"$PROJ"'"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_SKILL=evaluate-issue-pr STUB_GH_OUT="1")
ERR=$(cat "$WORKDIR/err.txt")
if [ "$RC" = "2" ] && echo "$ERR" | grep -q "CI-wait gate: --watch invocation not found"; then
  pass_msg "exit 2 + stderr matches"
else
  fail_msg "expected exit 2 with --watch stderr; got rc=$RC stderr=$ERR"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
