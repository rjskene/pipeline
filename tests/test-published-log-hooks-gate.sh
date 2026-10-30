#!/usr/bin/env bash
# test-published-log-hooks-gate.sh — #1616 regression guard.
#
# log-tool-use.sh, log_subagent.py and capture_agent_cost.py ship in the
# published plugin manifest, so each MUST be inert unless PIPELINE_LOGS_ENABLED
# resolves to exactly "true" (process env wins when SET, else
# $CLAUDE_PROJECT_DIR/pipeline.config). Gate-off means zero disk touch under
# .claude/logs/ — including log-tool-use.sh's jq-missing breadcrumb.
#
# Hermetic: throwaway project dirs with their own pipeline.config; never
# touches the live (gitignored, host-specific) repo pipeline.config.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL_HOOK="$REPO_ROOT/hooks/log-tool-use.sh"
SUB_HOOK="$REPO_ROOT/hooks/log_subagent.py"
COST_HOOK="$REPO_ROOT/hooks/capture_agent_cost.py"

FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=1; }

for h in "$TOOL_HOOK" "$SUB_HOOK" "$COST_HOOK"; do
  [ -f "$h" ] || { echo "FAIL: hook not found: $h" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BASH_PAYLOAD='{"tool_name":"Bash","session_id":"s-1616","tool_input":{"command":"echo hi"}}'
AGENT_PAYLOAD='{"tool_name":"Agent","session_id":"s-1616","tool_input":{"description":"plan-issue #1616","subagent_type":"pipeline:stage-reader","prompt":"x"},"tool_response":{"status":"completed","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":5,"cache_creation_input_tokens":2},"total_tokens":127},"duration_ms":1000}'

# make_project <config-line|NONE> -> prints project dir
make_project() {
  local line="$1"
  local proj
  proj="$(mktemp -d "$WORK/proj-XXXXXX")"
  if [ "$line" != "NONE" ]; then
    {
      echo "# fixture pipeline.config"
      echo "PIPELINE_BASE_BRANCH=staging"
      echo "$line"
    } > "$proj/pipeline.config"
  fi
  printf '%s' "$proj"
}

make_transcript() {
  local proj="$1"
  cat > "$proj/transcript.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-05-30T10:00:01.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":5,"cache_creation_input_tokens":2}}}
JSONL
  printf '{"session_id":"stop-1616","transcript_path":"%s"}' "$proj/transcript.jsonl"
}

log_files() { find "$1/.claude/logs" -type f 2>/dev/null | wc -l | tr -d ' '; }

# run_all <proj> <env-mode: unset|VALUE>
run_all() {
  local proj="$1" mode="$2" stop_payload rc
  stop_payload="$(make_transcript "$proj")"
  local -a envp
  if [ "$mode" = "unset" ]; then
    envp=(env -u PIPELINE_LOGS_ENABLED "CLAUDE_PROJECT_DIR=$proj")
  else
    envp=(env "PIPELINE_LOGS_ENABLED=$mode" "CLAUDE_PROJECT_DIR=$proj")
  fi
  ( cd "$proj" && "${envp[@]}" CLAUDE_HOOK_EVENT_NAME=PostToolUse bash "$TOOL_HOOK" <<<"$BASH_PAYLOAD" ); rc=$?
  [ "$rc" -eq 0 ] || fail "log-tool-use.sh exited $rc ($proj mode=$mode)"
  ( cd "$proj" && "${envp[@]}" python3 "$SUB_HOOK" <<<"$AGENT_PAYLOAD" ); rc=$?
  [ "$rc" -eq 0 ] || fail "log_subagent.py exited $rc ($proj mode=$mode)"
  ( cd "$proj" && "${envp[@]}" python3 "$COST_HOOK" <<<"$AGENT_PAYLOAD" ); rc=$?
  [ "$rc" -eq 0 ] || fail "capture_agent_cost.py (Agent) exited $rc ($proj mode=$mode)"
  ( cd "$proj" && "${envp[@]}" python3 "$COST_HOOK" <<<"$stop_payload" ); rc=$?
  [ "$rc" -eq 0 ] || fail "capture_agent_cost.py (Stop) exited $rc ($proj mode=$mode)"
}

assert_no_logs() {
  local label="$1" proj="$2" n
  n="$(log_files "$proj")"
  if [ "$n" != "0" ]; then
    fail "$label: expected no files under .claude/logs, got $n: $(find "$proj/.claude/logs" -type f 2>/dev/null | sed "s|$proj/||" | tr '\n' ' ')"
  else
    echo "ok: $label"
  fi
}

# (a) env PIPELINE_LOGS_ENABLED=false (config says true: env wins when set)
P="$(make_project PIPELINE_LOGS_ENABLED=true)"
run_all "$P" false
assert_no_logs "(a) env=false beats config=true" "$P"

# (b) env unset, config PIPELINE_LOGS_ENABLED=false
P="$(make_project PIPELINE_LOGS_ENABLED=false)"
run_all "$P" unset
assert_no_logs "(b) env unset, config=false" "$P"

# (c) env unset, no pipeline.config
P="$(make_project NONE)"
run_all "$P" unset
assert_no_logs "(c) env unset, no pipeline.config" "$P"

# (d) log-tool-use.sh, jq absent from PATH, gate off -> no hook-errors.log
SANDBOX="$WORK/sandbox-bin"
mkdir -p "$SANDBOX"
for bin in cat date mkdir tr timeout; do
  src="$(command -v "$bin")" && ln -sf "$src" "$SANDBOX/$bin"
done
if PATH="$SANDBOX" command -v jq >/dev/null 2>&1; then
  fail "(d) sandbox unexpectedly has jq on PATH"
fi
BASH_BIN="$(command -v bash)"
for mode in env-false config-false no-config; do
  case "$mode" in
    env-false)    P="$(make_project NONE)"; ev=(PIPELINE_LOGS_ENABLED=false) ;;
    config-false) P="$(make_project PIPELINE_LOGS_ENABLED=false)"; ev=() ;;
    no-config)    P="$(make_project NONE)"; ev=() ;;
  esac
  ( cd "$P" && env -u PIPELINE_LOGS_ENABLED "CLAUDE_PROJECT_DIR=$P" "${ev[@]}" PATH="$SANDBOX" \
      "$BASH_BIN" "$TOOL_HOOK" <<<"$BASH_PAYLOAD" ); rc=$?
  [ "$rc" -eq 0 ] || fail "(d) $mode: hook exited $rc with jq missing"
  if [ -e "$P/.claude/logs/hook-errors.log" ]; then
    fail "(d) $mode: hook-errors.log written with gate off"
  else
    echo "ok: (d) jq-missing $mode writes no hook-errors.log"
  fi
done
# Control for (d): gate ON + jq missing still writes the breadcrumb.
P="$(make_project NONE)"
( cd "$P" && env "CLAUDE_PROJECT_DIR=$P" PIPELINE_LOGS_ENABLED=true PATH="$SANDBOX" \
    "$BASH_BIN" "$TOOL_HOOK" <<<"$BASH_PAYLOAD" )
grep -q 'log-tool-use.sh: jq not found on PATH' "$P/.claude/logs/hook-errors.log" 2>/dev/null \
  && echo "ok: (d) control: gate on + jq missing writes breadcrumb" \
  || fail "(d) control: gate on + jq missing did not write hook-errors.log breadcrumb"

# (e) positive controls: env unset, config enables -> streams written
for line in 'PIPELINE_LOGS_ENABLED=true' 'PIPELINE_LOGS_ENABLED="true"'; do
  P="$(make_project "$line")"
  run_all "$P" unset
  [ -s "$P/.claude/logs/tool-use.log" ] && echo "ok: (e) [$line] tool-use.log written" \
    || fail "(e) [$line]: tool-use.log not written"
  [ -s "$P/.claude/logs/subagents.log" ] && echo "ok: (e) [$line] subagents.log written" \
    || fail "(e) [$line]: subagents.log not written"
  [ -s "$P/.claude/logs/agent-costs.jsonl" ] && echo "ok: (e) [$line] agent-costs.jsonl written" \
    || fail "(e) [$line]: agent-costs.jsonl not written"
done
# env=true with no config also enables
P="$(make_project NONE)"
run_all "$P" true
[ -s "$P/.claude/logs/tool-use.log" ] && [ -s "$P/.claude/logs/subagents.log" ] \
  && echo "ok: (e) env=true enables" || fail "(e) env=true: streams not written"
# Non-exact values do not enable
for line in 'PIPELINE_LOGS_ENABLED=TRUE' 'PIPELINE_LOGS_ENABLED=1'; do
  P="$(make_project "$line")"
  run_all "$P" unset
  assert_no_logs "(e) [$line] does not enable" "$P"
done

if [ "$FAIL" -eq 0 ]; then
  echo "PASS: test-published-log-hooks-gate.sh"
else
  echo "FAILED: test-published-log-hooks-gate.sh"
  exit 1
fi
