#!/bin/bash
set -euo pipefail

# Tests for hooks/enforce-comment-trust.py.
# Defense-in-depth layer three for comment-trust (#549): a PreToolUse(Bash)
# hook that blocks raw `gh issue/pr view --json ...comments...` reads and
# direct `fetch-issue-attachments.sh` invocations which bypass the trusted
# comment filter (scripts/filter-trusted-comments.sh, #545). Commands that
# route through the helper, or that read non-comment `--json` fields, pass.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/enforce-comment-trust.py"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$HOOK" ]; then
  echo "ERROR: hook not found at $HOOK" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

run_hook() {
  local payload="$1"
  set +e
  printf '%s' "$payload" | env -i HOME="$HOME" PATH="/usr/bin:/bin" \
    python3 "$HOOK" >"$WORKDIR/out" 2>"$WORKDIR/err"
  local rc=$?
  set -e
  echo "$rc"
}

echo "Case A: gh issue view --json body,comments -> blocked"
inc
rc=$(run_hook '{"tool_input":{"command":"gh issue view 549 --repo rjskene/pipeline --json body,comments"}}')
if [ "$rc" = "2" ] && grep -q "BLOCKED:" "$WORKDIR/err" \
   && grep -q "filter-trusted-comments.sh" "$WORKDIR/err"; then
  pass_msg "blocked raw --json body,comments with helper hint"
else
  fail_msg "expected rc=2 + BLOCKED + helper hint, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case B: gh issue view --json comments --jq -> blocked"
inc
rc=$(run_hook '{"tool_input":{"command":"gh issue view 12 --json comments --jq .comments"}}')
if [ "$rc" = "2" ] && grep -q "BLOCKED:" "$WORKDIR/err"; then
  pass_msg "blocked --json comments"
else
  fail_msg "expected rc=2 + BLOCKED, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case C: gh pr view --json title,comments -> blocked"
inc
rc=$(run_hook '{"tool_input":{"command":"gh pr view 540 --repo rjskene/pipeline --json title,comments"}}')
if [ "$rc" = "2" ] && grep -q "BLOCKED:" "$WORKDIR/err"; then
  pass_msg "blocked gh pr view --json comments"
else
  fail_msg "expected rc=2 + BLOCKED, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case D: direct fetch-issue-attachments.sh -> blocked"
inc
rc=$(run_hook '{"tool_input":{"command":"bash ${CLAUDE_PLUGIN_ROOT}/scripts/fetch-issue-attachments.sh 549"}}')
if [ "$rc" = "2" ] && grep -q "BLOCKED:" "$WORKDIR/err" \
   && grep -q "filter-trusted-comments.sh" "$WORKDIR/err"; then
  pass_msg "blocked direct attachment fetch with helper hint"
else
  fail_msg "expected rc=2 + BLOCKED + helper hint, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case E: gh issue view --json=body,comments (= form) -> blocked"
inc
rc=$(run_hook '{"tool_input":{"command":"gh issue view 7 --json=body,comments"}}')
if [ "$rc" = "2" ] && grep -q "BLOCKED:" "$WORKDIR/err"; then
  pass_msg "blocked --json= form"
else
  fail_msg "expected rc=2 + BLOCKED, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case F: filter-trusted-comments.sh helper invocation -> passthrough"
inc
rc=$(run_hook '{"tool_input":{"command":"bash scripts/filter-trusted-comments.sh 549 --repo rjskene/pipeline"}}')
if [ "$rc" = "0" ] && [ ! -s "$WORKDIR/err" ]; then
  pass_msg "passthrough for trusted helper"
else
  fail_msg "expected rc=0 + empty stderr, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case G: gh issue view non-comment --json fields -> passthrough"
inc
rc=$(run_hook '{"tool_input":{"command":"gh issue view 549 --repo rjskene/pipeline --json number,title,body,labels"}}')
if [ "$rc" = "0" ] && [ ! -s "$WORKDIR/err" ]; then
  pass_msg "passthrough for non-comment --json fields"
else
  fail_msg "expected rc=0 + empty stderr, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case H: helper present in compound command -> passthrough (allow-by-presence)"
inc
rc=$(run_hook '{"tool_input":{"command":"scripts/filter-trusted-comments.sh 5 && gh issue view 5 --json body,comments"}}')
if [ "$rc" = "0" ]; then
  pass_msg "passthrough when helper token present"
else
  fail_msg "expected rc=0, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case I: unrelated command (git log) -> passthrough"
inc
rc=$(run_hook '{"tool_input":{"command":"git log --oneline -5"}}')
if [ "$rc" = "0" ]; then
  pass_msg "passthrough for unrelated command"
else
  fail_msg "expected rc=0, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case J: 'comments' word outside --json field list -> passthrough"
inc
rc=$(run_hook '{"tool_input":{"command":"gh issue view 5 --json body --jq \".body\" # see comments later"}}')
if [ "$rc" = "0" ]; then
  pass_msg "passthrough when comments not in --json fields"
else
  fail_msg "expected rc=0, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case K: empty tool_input -> passthrough"
inc
rc=$(run_hook '{"tool_input":{}}')
if [ "$rc" = "0" ]; then
  pass_msg "passthrough for empty payload"
else
  fail_msg "expected rc=0, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

# ---------------------------------------------------------------------------
# Issue #1321 — the hook decides from DEQUOTED SEGMENTS (hooks/command_mask.py)
# rather than a whole-text regex: a `gh issue view … --json …comments` spelling
# that lives only inside a grep/awk PATTERN operand, a heredoc BODY, or an
# echo'd quoted string never yields a segment HEADED by `gh` (M/N/O/P/T allow).
# Shell-headed segments recurse one level (Q/U: `bash -c` / `bash -lc`) and
# wrapper words are skipped (S: `xargs`), so those still deny. R closes a
# pre-existing miss: the field list is read from the dequoted word, so a
# QUOTED `--json "body,comments"` denies too.
# Quoting inside the single-quoted bash payload: an inner single quote is
# spliced in as '"'"' (close ', open " containing ', close ", reopen '); `\"`
# is a JSON double quote and `\n` a JSON newline (Case J's convention).
# ---------------------------------------------------------------------------

echo "Case M: grep PATTERN operand spelling the raw form -> passthrough (#1321)"
inc
rc=$(run_hook '{"tool_input":{"command":"grep -nE '"'"'gh issue view 42 --json body,comments'"'"' skills/"}}')
if [ "$rc" = "0" ]; then
  pass_msg "passthrough for quoted grep pattern operand"
else
  fail_msg "expected rc=0, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case N: heredoc BODY spelling the raw form -> passthrough (#1321)"
inc
rc=$(run_hook '{"tool_input":{"command":"cat <<'"'"'EOF'"'"'\ngh issue view 42 --json body,comments\nEOF"}}')
if [ "$rc" = "0" ]; then
  pass_msg "passthrough for heredoc body"
else
  fail_msg "expected rc=0, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case O: echo of a double-quoted raw form -> passthrough (#1321)"
inc
rc=$(run_hook '{"tool_input":{"command":"echo \"gh issue view 42 --json body,comments\""}}')
if [ "$rc" = "0" ]; then
  pass_msg "passthrough for echo'd quoted string"
else
  fail_msg "expected rc=0, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case P: awk PROGRAM operand spelling the raw form -> passthrough (#1321)"
inc
rc=$(run_hook '{"tool_input":{"command":"awk '"'"'/gh issue view 42 --json comments/{print}'"'"' x.md"}}')
if [ "$rc" = "0" ]; then
  pass_msg "passthrough for quoted awk program operand"
else
  fail_msg "expected rc=0, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case Q: bash -c '<raw form>' -> blocked (control, #1321 depth-1 recursion)"
inc
rc=$(run_hook '{"tool_input":{"command":"bash -c '"'"'gh issue view 42 --json body,comments'"'"'"}}')
if [ "$rc" = "2" ] && grep -q "BLOCKED:" "$WORKDIR/err"; then
  pass_msg "blocked bash -c body (executed operand)"
else
  fail_msg "expected rc=2 + BLOCKED, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case R: gh issue view --json \"body,comments\" (quoted field list) -> blocked (#1321)"
inc
rc=$(run_hook '{"tool_input":{"command":"gh issue view 42 --json \"body,comments\""}}')
if [ "$rc" = "2" ] && grep -q "BLOCKED:" "$WORKDIR/err"; then
  pass_msg "blocked quoted --json field list"
else
  fail_msg "expected rc=2 + BLOCKED, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case S: xargs-wrapped gh issue view --json comments -> blocked (control, #1321 wrapper skip)"
inc
rc=$(run_hook '{"tool_input":{"command":"echo 5 | xargs -I{} gh issue view {} --json comments"}}')
if [ "$rc" = "2" ] && grep -q "BLOCKED:" "$WORKDIR/err"; then
  pass_msg "blocked xargs-wrapped raw read"
else
  fail_msg "expected rc=2 + BLOCKED, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case T: heredoc BODY naming fetch-issue-attachments.sh -> passthrough (#1321)"
inc
rc=$(run_hook '{"tool_input":{"command":"cat <<'"'"'EOF'"'"'\nbash scripts/fetch-issue-attachments.sh 5\nEOF"}}')
if [ "$rc" = "0" ]; then
  pass_msg "passthrough for helper name inside heredoc body"
else
  fail_msg "expected rc=0, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case U: bash -lc '<raw form>' -> blocked (control, #1321 ^-[a-zA-Z]*c\$ recursion trigger)"
inc
rc=$(run_hook '{"tool_input":{"command":"bash -lc '"'"'gh issue view 42 --json body,comments'"'"'"}}')
if [ "$rc" = "2" ] && grep -q "BLOCKED:" "$WORKDIR/err"; then
  pass_msg "blocked bash -lc body (executed operand)"
else
  fail_msg "expected rc=2 + BLOCKED, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case L: hook registered dogfood-only in .claude/settings.json"
inc
SETTINGS="$SCRIPT_DIR/../.claude/settings.json"
set +e
python3 - "$SETTINGS" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for entry in data.get("hooks", {}).get("PreToolUse", []):
    if entry.get("matcher") == "Bash":
        for h in entry.get("hooks", []):
            if h.get("type") == "command" \
               and "enforce-comment-trust.py" in h.get("command", ""):
                sys.exit(0)
print("enforce-comment-trust.py NOT registered in .claude/settings.json",
      file=sys.stderr)
sys.exit(1)
PY
reg_rc=$?
set -e
if [ "$reg_rc" = "0" ]; then
  pass_msg "registered under PreToolUse/Bash in .claude/settings.json"
else
  fail_msg "enforce-comment-trust.py not registered in .claude/settings.json"
fi

echo ""
echo "================================"
echo "  $TESTS cases: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
