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
#
# Issue #1424 added a second, ORCHESTRATOR branch (Tests 9a-9l). For a session
# that is NOT the PR evaluator it exits 0 unless PIPELINE_HEADLESS is true (env
# first, then pipeline.config) and the transcript's first user message is a
# `/pipeline:fullsend` invocation; then it exits 2 while any slate issue is
# `in-progress`, or `pr-open` with no parked label. Capped at 40 blocks per
# session, then fail-open.

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

# Stub gh on PATH. Routes by argv pattern:
#   --jq '. | length'          -> STUB_GH_ROLLUP_LEN (default: "1")
#   --jq '[.statusCheckRollup  -> STUB_GH_FAIL_COUNT  (default: "0")
#   gh issue view <N> labels   -> STUB_GH_LABELS_<N>, else STUB_GH_LABELS ("")
#   gh issue edit ...          -> records call, exits 0
#   gh pr comment ...          -> records call, exits 0
# When STUB_GH_FAIL=1, exits 1.
STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
echo "$@" >> "${STUB_GH_CALLS:-/dev/null}"
if [ "${STUB_GH_FAIL:-0}" = "1" ]; then
  exit 1
fi
args="$*"
case "$args" in
  *"[.statusCheckRollup"*)
    printf '%s' "${STUB_GH_FAIL_COUNT:-0}" ;;
  *". | length"*)
    printf '%s' "${STUB_GH_ROLLUP_LEN:-1}" ;;
  *"issue view"*)
    # $3 is the issue number: `gh issue view <N> --repo ...`. A per-issue
    # STUB_GH_LABELS_<N> wins over the global STUB_GH_LABELS, so a test can give
    # two slate issues DIFFERENT label sets.
    per_issue="STUB_GH_LABELS_$3"
    printf '%s' "${!per_issue:-${STUB_GH_LABELS:-}}" ;;
  *"issue edit"*|*"pr comment"*)
    : ;;
  *)
    printf '%s' "${STUB_GH_OUT:-}" ;;
esac
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
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_SKILL=evaluate-issue-pr STUB_GH_ROLLUP_LEN="0")
if [ "$RC" = "0" ]; then pass_msg "exit 0 (no CI)"; else fail_msg "expected exit 0, got $RC"; fi

# --- Test 3: CI present, no --watch invocation -> exit 2 ---
echo "Test 3: CI present, no --watch -> exit 2 with stderr"
inc
reset_state
seed_log_row "2026-05-14T10:00:00Z" "sess-3" "Bash" \
  "gh pr view 123 --repo fake/repo --json statusCheckRollup"
PAYLOAD='{"session_id":"sess-3","cwd":"'"$PROJ"'"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_SKILL=evaluate-issue-pr STUB_GH_ROLLUP_LEN="1")
ERR=$(cat "$WORKDIR/err.txt")
if [ "$RC" = "2" ] && echo "$ERR" | grep -q "CI-wait gate: --watch invocation not found"; then
  pass_msg "exit 2 + stderr matches"
else
  fail_msg "expected exit 2 with --watch stderr; got rc=$RC stderr=$ERR"
fi

# --- Test 3b: remediation stderr must NOT instruct run_in_background (issue #684) ---
echo "Test 3b: block stderr drops run_in_background guidance"
inc
if echo "$ERR" | grep -qi "run_in_background"; then
  fail_msg "stderr still instructs run_in_background:true (issue #684); got: $ERR"
else
  pass_msg "stderr free of run_in_background guidance"
fi

# --- Test 4a: --watch ran but no post-watch rollup -> exit 2 ---
echo "Test 4a: --watch but no post-watch rollup -> exit 2"
inc
reset_state
seed_log_row "2026-05-14T10:00:00Z" "sess-4a" "Bash" \
  "gh pr view 123 --repo fake/repo --json statusCheckRollup"
seed_log_row "2026-05-14T10:01:00Z" "sess-4a" "Bash" \
  "timeout 600 gh pr checks 123 --repo fake/repo --watch --fail-fast --interval 30"
PAYLOAD='{"session_id":"sess-4a","cwd":"'"$PROJ"'"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_SKILL=evaluate-issue-pr STUB_GH_ROLLUP_LEN="1")
ERR=$(cat "$WORKDIR/err.txt")
if [ "$RC" = "2" ] && echo "$ERR" | grep -q "final rollup not re-checked after --watch"; then
  pass_msg "exit 2 + post-watch rollup stderr matches"
else
  fail_msg "expected exit 2 with post-watch stderr; got rc=$RC stderr=$ERR"
fi

# --- Test 4b: well-formed sequence -> exit 0 ---
echo "Test 4b: rollup -> --watch -> rollup -> exit 0"
inc
reset_state
seed_log_row "2026-05-14T10:00:00Z" "sess-4b" "Bash" \
  "gh pr view 123 --repo fake/repo --json statusCheckRollup"
seed_log_row "2026-05-14T10:01:00Z" "sess-4b" "Bash" \
  "timeout 600 gh pr checks 123 --repo fake/repo --watch --fail-fast --interval 30"
seed_log_row "2026-05-14T10:02:00Z" "sess-4b" "Bash" \
  "gh pr view 123 --repo fake/repo --json statusCheckRollup --jq '.statusCheckRollup'"
PAYLOAD='{"session_id":"sess-4b","cwd":"'"$PROJ"'"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_SKILL=evaluate-issue-pr STUB_GH_ROLLUP_LEN="1")
if [ "$RC" = "0" ]; then pass_msg "exit 0 (well-formed sequence)"; else fail_msg "expected exit 0, got $RC"; fi

# --- Test 5a: Approved verdict + final rollup FAILURE -> exit 2 ---
echo "Test 5a: Approved verdict + red final rollup -> exit 2"
inc
reset_state
seed_log_row "2026-05-14T10:00:00Z" "sess-5a" "Bash" \
  "gh pr view 123 --repo fake/repo --json statusCheckRollup"
seed_log_row "2026-05-14T10:01:00Z" "sess-5a" "Bash" \
  "timeout 600 gh pr checks 123 --repo fake/repo --watch --fail-fast --interval 30"
seed_log_row "2026-05-14T10:02:00Z" "sess-5a" "Bash" \
  "gh pr view 123 --repo fake/repo --json statusCheckRollup"
seed_log_row "2026-05-14T10:03:00Z" "sess-5a" "Bash" \
  'gh pr comment 123 --repo fake/repo --body "## Evaluation **Verdict:** Approved"'
PAYLOAD='{"session_id":"sess-5a","cwd":"'"$PROJ"'"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_SKILL=evaluate-issue-pr \
  STUB_GH_ROLLUP_LEN="1" STUB_GH_FAIL_COUNT="1")
ERR=$(cat "$WORKDIR/err.txt")
if [ "$RC" = "2" ] && echo "$ERR" | grep -q "Approved verdict with failing CI"; then
  pass_msg "exit 2 + red-Approved stderr matches"
else
  fail_msg "expected exit 2 with Approved-red stderr; got rc=$RC stderr=$ERR"
fi

# --- Test 5b: Approved verdict + all-green final rollup -> exit 0 ---
echo "Test 5b: Approved verdict + green final rollup -> exit 0"
inc
reset_state
seed_log_row "2026-05-14T10:00:00Z" "sess-5b" "Bash" \
  "gh pr view 123 --repo fake/repo --json statusCheckRollup"
seed_log_row "2026-05-14T10:01:00Z" "sess-5b" "Bash" \
  "timeout 600 gh pr checks 123 --repo fake/repo --watch --fail-fast --interval 30"
seed_log_row "2026-05-14T10:02:00Z" "sess-5b" "Bash" \
  "gh pr view 123 --repo fake/repo --json statusCheckRollup"
seed_log_row "2026-05-14T10:03:00Z" "sess-5b" "Bash" \
  'gh pr comment 123 --repo fake/repo --body "## Evaluation **Verdict:** Approved"'
PAYLOAD='{"session_id":"sess-5b","cwd":"'"$PROJ"'"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_SKILL=evaluate-issue-pr \
  STUB_GH_ROLLUP_LEN="1" STUB_GH_FAIL_COUNT="0")
if [ "$RC" = "0" ]; then pass_msg "exit 0 (Approved + green)"; else fail_msg "expected exit 0, got $RC"; fi

# --- Test 6a/b/c: retry counter increments on each block ---
echo "Test 6a-c: retry counter increments + escalates on 3rd block"
inc
reset_state
seed_log_row "2026-05-14T10:00:00Z" "sess-6" "Bash" \
  "gh pr view 123 --repo fake/repo --json statusCheckRollup"
# No --watch row, so every invocation blocks.
PAYLOAD='{"session_id":"sess-6","cwd":"'"$PROJ"'"}'
COUNT_FILE="$PROJ/.claude/logs/enforce-ci-wait-state/sess-6.count"
SUB_OK=1
for n in 1 2 3; do
  RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_ISSUE_NUMBER=54 \
    CLAUDE_PIPELINE_SKILL=evaluate-issue-pr STUB_GH_ROLLUP_LEN="1")
  if [ "$RC" != "2" ]; then SUB_OK=0; reason="rc=$RC on block #$n"; break; fi
  if [ ! -f "$COUNT_FILE" ]; then SUB_OK=0; reason="count file missing after block #$n"; break; fi
  CUR=$(cat "$COUNT_FILE")
  if [ "$CUR" != "$n" ]; then SUB_OK=0; reason="count=$CUR, expected $n"; break; fi
done
# On block #3, expect issue-edit + pr-comment gh calls.
if [ "$SUB_OK" = "1" ]; then
  if ! grep -q "issue edit 54" "$WORKDIR/gh-calls.log"; then
    SUB_OK=0; reason="gh issue edit not invoked on 3rd block"
  elif ! grep -q "needs-human" "$WORKDIR/gh-calls.log"; then
    SUB_OK=0; reason="needs-human label not added"
  elif ! grep -q "pr comment 123" "$WORKDIR/gh-calls.log"; then
    SUB_OK=0; reason="pr comment not posted on 3rd block"
  fi
fi
if [ "$SUB_OK" = "1" ]; then
  pass_msg "counter increments + escalates on 3rd block"
else
  fail_msg "${reason:-unknown}"
fi

# --- Test 6d: counter file deleted on successful exit 0 ---
echo "Test 6d: counter file deleted on successful (exit 0) Stop"
inc
reset_state
# Pre-seed a counter from a prior session as if blocks had occurred.
mkdir -p "$PROJ/.claude/logs/enforce-ci-wait-state"
echo "2" > "$PROJ/.claude/logs/enforce-ci-wait-state/sess-6d.count"
seed_log_row "2026-05-14T10:00:00Z" "sess-6d" "Bash" \
  "gh pr view 123 --repo fake/repo --json statusCheckRollup"
seed_log_row "2026-05-14T10:01:00Z" "sess-6d" "Bash" \
  "timeout 600 gh pr checks 123 --repo fake/repo --watch --fail-fast --interval 30"
seed_log_row "2026-05-14T10:02:00Z" "sess-6d" "Bash" \
  "gh pr view 123 --repo fake/repo --json statusCheckRollup"
PAYLOAD='{"session_id":"sess-6d","cwd":"'"$PROJ"'"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_SKILL=evaluate-issue-pr STUB_GH_ROLLUP_LEN="1")
if [ "$RC" = "0" ] && [ ! -f "$PROJ/.claude/logs/enforce-ci-wait-state/sess-6d.count" ]; then
  pass_msg "exit 0 + counter cleared"
else
  fail_msg "expected exit 0 + cleared count; got rc=$RC, file=$(ls $PROJ/.claude/logs/enforce-ci-wait-state/ 2>/dev/null || echo missing)"
fi

# --- Test 8a: SKILL.md mentions hook-enforced ---
echo "Test 8a: evaluate-issue-pr SKILL.md mentions hook-enforced"
inc
SKILL_PATH="$SCRIPT_DIR/../skills/evaluate-issue-pr/SKILL.md"
if grep -qi "hook-enforced" "$SKILL_PATH"; then
  pass_msg "SKILL.md contains 'hook-enforced'"
else
  fail_msg "SKILL.md missing 'hook-enforced' phrase at $SKILL_PATH"
fi

# --- Test 8b: unreadable tool-use.log -> exit 0 + errors.log line (fail-open) ---
echo "Test 8b: unreadable tool-use.log -> exit 0 + errors.log gains a line"
inc
reset_state
# Make .claude/logs a directory whose tool-use.log is itself a directory — read_text
# will raise IsADirectoryError -> caught by top-level except -> writes to errors.log.
mkdir -p "$PROJ/.claude/logs/tool-use.log"
PAYLOAD='{"session_id":"sess-8b","cwd":"'"$PROJ"'"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_SKILL=evaluate-issue-pr STUB_GH_ROLLUP_LEN="1")
rmdir "$PROJ/.claude/logs/tool-use.log" 2>/dev/null || true
if [ "$RC" = "0" ] && [ -s "$PROJ/.claude/logs/enforce-ci-wait-errors.log" ]; then
  pass_msg "fail-open: exit 0 + errors.log gained a line"
else
  fail_msg "expected exit 0 + non-empty errors.log; got rc=$RC, err=$(ls -la $PROJ/.claude/logs/ 2>&1 | head -5)"
fi

# ---------------------------------------------------------------------------
# Tests 9a-9l: the ORCHESTRATOR branch (issue #1424).
#
# Under PIPELINE_HEADLESS=true a Stop from the orchestrator session itself
# (CLAUDE_PIPELINE_SKILL unset, or =fullsend) is DENIED while any slate issue is
# still `in-progress`, or `pr-open` with no parked label. The slate comes from
# the transcript's first user message. Everything else stays exit 0: a
# non-headless session, a first message that is not /pipeline:fullsend, the
# 40-block cap, and any `gh` failure (fail-open + errors.log).
# ---------------------------------------------------------------------------

TRANSCRIPT="$WORKDIR/transcript.jsonl"

# Helper: one-line JSONL transcript whose first user entry carries $1 verbatim.
# `\n` inside $1 stays a JSON escape — printf does not interpret escapes in its
# arguments, only in the format string.
seed_transcript() {
  printf '{"type":"user","isSidechain":false,"message":{"role":"user","content":"%s"}}\n' \
    "$1" > "$TRANSCRIPT"
}

# The REAL slash-command transcript shape (verified against a yielding session).
SLATE_CONTENT='<command-message>pipeline:fullsend</command-message>\n<command-name>/pipeline:fullsend</command-name>\n<command-args>101 102</command-args>'
SLATE_CONTENT_MM='<command-message>pipeline:fullsend</command-message>\n<command-name>/pipeline:fullsend</command-name>\n<command-args>101 102 --manual-merge</command-args>'
PROSE_CONTENT='please review the open PRs and tell me which ones are green'
# A DIFFERENT slash command whose args carry digits, plus a fullsend MENTION in
# trailing prose: the scope check must bind to the invoked <command-name>, not to
# any occurrence of the string, or `--cycles 101` is parsed as issue #101.
OTHER_CMD_CONTENT='<command-message>pipeline:evolve</command-message>\n<command-name>/pipeline:evolve</command-name>\n<command-args>start --cycles 101</command-args>\nresume the /pipeline:fullsend slate afterwards'

orch_payload() {
  printf '{"session_id":"%s","cwd":"%s","transcript_path":"%s"}' "$1" "$PROJ" "$TRANSCRIPT"
}

# --- Test 9a: headless orchestrator, slate issue in-progress -> exit 2 ---
echo "Test 9a: headless orchestrator + in-progress slate issue -> exit 2"
inc
reset_state
seed_transcript "$SLATE_CONTENT"
RC=$(run_hook "$(orch_payload orch-9a)" PIPELINE_HEADLESS=true STUB_GH_LABELS="in-progress")
ERR=$(cat "$WORKDIR/err.txt")
if [ "$RC" = "2" ] \
  && grep -qF "slate unfinished: #101" <<<"$ERR" \
  && grep -qF "do not background the wait" <<<"$ERR"; then
  pass_msg "exit 2 + slate-unfinished stderr matches"
else
  fail_msg "expected exit 2 with slate-unfinished stderr; got rc=$RC stderr=$ERR"
fi

# --- Test 9b: pr-open with no parked label is unfinished -> exit 2 ---
echo "Test 9b: headless orchestrator + unparked pr-open -> exit 2"
inc
reset_state
seed_transcript "$SLATE_CONTENT"
RC=$(run_hook "$(orch_payload orch-9b)" PIPELINE_HEADLESS=true STUB_GH_LABELS="pr-open")
if [ "$RC" = "2" ]; then pass_msg "exit 2 (unparked pr-open)"; else fail_msg "expected exit 2, got $RC"; fi

# --- Test 9c: whole slate merged -> exit 0 + count cleared ---
echo "Test 9c: headless orchestrator + merged slate -> exit 0 + count cleared"
inc
reset_state
seed_transcript "$SLATE_CONTENT"
mkdir -p "$PROJ/.claude/logs/enforce-ci-wait-state"
echo "2" > "$PROJ/.claude/logs/enforce-ci-wait-state/orch-9c.count"
RC=$(run_hook "$(orch_payload orch-9c)" PIPELINE_HEADLESS=true STUB_GH_LABELS="merged")
if [ "$RC" = "0" ] && [ ! -f "$PROJ/.claude/logs/enforce-ci-wait-state/orch-9c.count" ]; then
  pass_msg "exit 0 + count cleared"
else
  fail_msg "expected exit 0 + cleared count; got rc=$RC count=$(cat "$PROJ/.claude/logs/enforce-ci-wait-state/orch-9c.count" 2>/dev/null || echo absent)"
fi

# --- Test 9d: pr-open + manual-merge label is parked -> exit 0 ---
echo "Test 9d: headless orchestrator + pr-open/manual-merge -> exit 0"
inc
reset_state
seed_transcript "$SLATE_CONTENT"
RC=$(run_hook "$(orch_payload orch-9d)" PIPELINE_HEADLESS=true STUB_GH_LABELS=$'pr-open\nmanual-merge')
if [ "$RC" = "0" ]; then pass_msg "exit 0 (manual-merge parked)"; else fail_msg "expected exit 0, got $RC"; fi

# --- Test 9e: pr-open + human label is parked -> exit 0 ---
echo "Test 9e: headless orchestrator + pr-open/human -> exit 0"
inc
reset_state
seed_transcript "$SLATE_CONTENT"
RC=$(run_hook "$(orch_payload orch-9e)" PIPELINE_HEADLESS=true STUB_GH_LABELS=$'pr-open\nhuman')
if [ "$RC" = "0" ]; then pass_msg "exit 0 (human parked)"; else fail_msg "expected exit 0, got $RC"; fi

# --- Test 9f: PIPELINE_HEADLESS absent -> exit 0 (every interactive session) ---
echo "Test 9f: PIPELINE_HEADLESS absent + in-progress slate -> exit 0"
inc
reset_state
seed_transcript "$SLATE_CONTENT"
RC=$(run_hook "$(orch_payload orch-9f)" STUB_GH_LABELS="in-progress")
if [ "$RC" = "0" ]; then pass_msg "exit 0 (not headless)"; else fail_msg "expected exit 0, got $RC"; fi

# --- Test 9g: first user message is not /pipeline:fullsend -> exit 0 ---
echo "Test 9g: headless session whose first message is prose -> exit 0"
inc
reset_state
seed_transcript "$PROSE_CONTENT"
RC=$(run_hook "$(orch_payload orch-9g)" PIPELINE_HEADLESS=true STUB_GH_LABELS="in-progress")
if [ "$RC" = "0" ]; then pass_msg "exit 0 (out of scope)"; else fail_msg "expected exit 0, got $RC"; fi

# --- Test 9h: CLAUDE_PIPELINE_SKILL=fullsend is accepted -> exit 2 ---
echo "Test 9h: CLAUDE_PIPELINE_SKILL=fullsend + in-progress slate -> exit 2"
inc
reset_state
seed_transcript "$SLATE_CONTENT"
RC=$(run_hook "$(orch_payload orch-9h)" PIPELINE_HEADLESS=true CLAUDE_PIPELINE_SKILL=fullsend \
  STUB_GH_LABELS="in-progress")
if [ "$RC" = "2" ]; then pass_msg "exit 2 (skill alias accepted)"; else fail_msg "expected exit 2, got $RC"; fi

# --- Test 9i: block cap reached -> exit 0 (a wedged session must still end) ---
echo "Test 9i: orchestrator block cap reached -> exit 0 (fail open)"
inc
reset_state
seed_transcript "$SLATE_CONTENT"
mkdir -p "$PROJ/.claude/logs/enforce-ci-wait-state"
echo "40" > "$PROJ/.claude/logs/enforce-ci-wait-state/orch-9i.count"
RC=$(run_hook "$(orch_payload orch-9i)" PIPELINE_HEADLESS=true STUB_GH_LABELS="in-progress")
if [ "$RC" = "0" ]; then pass_msg "exit 0 (cap reached)"; else fail_msg "expected exit 0, got $RC"; fi

# --- Test 9j: gh failure -> exit 0 + errors.log line (fail-open) ---
echo "Test 9j: gh issue view fails -> exit 0 + errors.log gains a line"
inc
reset_state
seed_transcript "$SLATE_CONTENT"
RC=$(run_hook "$(orch_payload orch-9j)" PIPELINE_HEADLESS=true STUB_GH_FAIL=1 \
  STUB_GH_LABELS="in-progress")
ERRLOG=$(cat "$PROJ/.claude/logs/enforce-ci-wait-errors.log" 2>/dev/null || true)
# The GRACEFUL fail-open, not the top-level one: a bare `rc=0 + non-empty log`
# assertion is satisfied by an uncaught exception too, so pin the gate's own
# message AND the absence of a traceback.
if [ "$RC" = "0" ] \
  && grep -qF "orchestrator slate gate" <<<"$ERRLOG" \
  && grep -qF "gh issue view 101 failed" <<<"$ERRLOG" \
  && ! grep -qF "Traceback" <<<"$ERRLOG"; then
  pass_msg "graceful fail-open: exit 0 + gate errors.log line, no traceback"
else
  fail_msg "expected exit 0 + a traceback-free 'orchestrator slate gate' line; got rc=$RC, errors.log=$ERRLOG"
fi

# --- Test 9k: the knob resolves from pipeline.config too -> exit 2 ---
echo "Test 9k: PIPELINE_HEADLESS from pipeline.config (not env) -> exit 2"
inc
reset_state
seed_transcript "$SLATE_CONTENT"
printf 'PIPELINE_HEADLESS="true"\n' >> "$PROJ/pipeline.config"
RC=$(run_hook "$(orch_payload orch-9k)" STUB_GH_LABELS="in-progress")
printf 'PIPELINE_REPO="fake/repo"\n' > "$PROJ/pipeline.config"
if [ "$RC" = "2" ]; then pass_msg "exit 2 (config fallback)"; else fail_msg "expected exit 2, got $RC"; fi

# --- Test 9n: a DIFFERENT slash command is out of scope -> exit 0 ---
echo "Test 9n: headless /pipeline:evolve session mentioning fullsend -> exit 0"
inc
reset_state
seed_transcript "$OTHER_CMD_CONTENT"
RC=$(run_hook "$(orch_payload orch-9n)" PIPELINE_HEADLESS=true STUB_GH_LABELS="in-progress")
if [ "$RC" = "0" ]; then pass_msg "exit 0 (scope bound to the invoked command)"; else fail_msg "expected exit 0, got $RC"; fi

# --- Test 9o: the loop continues past a finished issue, keyed to the right one ---
# #101 merged, #102 in-progress: the gate must not stop at the first FINISHED
# issue, and the reason must name #102 (the in-order short-circuit fires on the
# first UNFINISHED issue, not the first issue).
echo "Test 9o: finished first, unfinished second -> exit 2 naming #102"
inc
reset_state
seed_transcript "$SLATE_CONTENT"
RC=$(run_hook "$(orch_payload orch-9o)" PIPELINE_HEADLESS=true \
  STUB_GH_LABELS_101="merged" STUB_GH_LABELS_102="in-progress")
ERR=$(cat "$WORKDIR/err.txt")
if [ "$RC" = "2" ] && grep -qF "slate unfinished: #102 in-progress" <<<"$ERR"; then
  pass_msg "exit 2 + reason keyed to #102"
else
  fail_msg "expected exit 2 naming #102; got rc=$RC stderr=$ERR"
fi

# --- Test 9p: --manual-merge still blocks on in-progress -> exit 2 ---
# The flag parks pr-open ONLY; an issue still executing is unfinished either way.
echo "Test 9p: --manual-merge + in-progress -> exit 2"
inc
reset_state
seed_transcript "$SLATE_CONTENT_MM"
RC=$(run_hook "$(orch_payload orch-9p)" PIPELINE_HEADLESS=true STUB_GH_LABELS="in-progress")
if [ "$RC" = "2" ]; then pass_msg "exit 2 (in-progress survives --manual-merge)"; else fail_msg "expected exit 2, got $RC"; fi

# --- Test 9m: merged + STALE pr-open is finished -> exit 0 ---
# scripts/finalize-issue-labels.sh falls back to `--add-label merged` ALONE when
# the combined add+strip edit fails (#888), warning "lifecycle labels may be
# stale". A merged issue that kept `pr-open` must NOT be read as unfinished, or
# a fully-merged slate burns every one of the 40 denials.
echo "Test 9m: merged + stale pr-open -> exit 0"
inc
reset_state
seed_transcript "$SLATE_CONTENT"
RC=$(run_hook "$(orch_payload orch-9m)" PIPELINE_HEADLESS=true STUB_GH_LABELS=$'merged\npr-open')
if [ "$RC" = "0" ]; then pass_msg "exit 0 (merged wins over stale pr-open)"; else fail_msg "expected exit 0, got $RC"; fi

# --- Test 9l: --manual-merge parks pr-open (no LABEL records the flag) -> exit 0 ---
echo "Test 9l: --manual-merge in the slate command + pr-open -> exit 0"
inc
reset_state
seed_transcript "$SLATE_CONTENT_MM"
RC=$(run_hook "$(orch_payload orch-9l)" PIPELINE_HEADLESS=true STUB_GH_LABELS="pr-open")
if [ "$RC" = "0" ]; then pass_msg "exit 0 (--manual-merge parks pr-open)"; else fail_msg "expected exit 0, got $RC"; fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
