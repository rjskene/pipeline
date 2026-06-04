#!/usr/bin/env bash
# PIPELINE_LOGS_ENABLED gate guard for BOTH agent-cost producers.
#
# With the gate UNSET or =false, neither the retroactive extractor
# (scripts/capture-agent-costs.sh) nor the forward hook
# (hooks/capture_agent_cost.py) may create or modify
# .claude/logs/agent-costs.jsonl. With =true, both append.
#
# Self-contained: temp HOME + CLAUDE_PROJECT_DIR, mirroring
# tests/test-analyze-issues-log-gate.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIX="$SCRIPT_DIR/fixtures/token-usage"
RETRO_SRC="$REPO_ROOT/scripts/capture-agent-costs.sh"
FWD_SRC="$REPO_ROOT/hooks/capture_agent_cost.py"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

OUT_REL=".claude/logs/agent-costs.jsonl"

# Shared temp HOME with the headless transcript at its slug path, so a gate=true
# retroactive run actually has something to emit.
RHOME="$TMP/home"
SLUG=$(python3 -c 'import re,sys; print(re.sub(r"[/.]","-",sys.argv[1]))' \
  "/home/fix/claude-pipeline/.claude/worktrees/wt-642")
mkdir -p "$RHOME/.claude/projects/$SLUG"
cp "$FIX/transcript.jsonl" "$RHOME/.claude/projects/$SLUG/sess-aaaa-1111.jsonl"

setup_retro_project() {
  local proj="$1"
  mkdir -p "$proj/.claude/logs"
  cp "$FIX/runs.log" "$proj/.claude/logs/runs.log"
  cp "$FIX/subagents.log" "$proj/.claude/logs/subagents.log"
  cp -r "$FIX/subagents" "$proj/.claude/logs/subagents"
}

# $1 = project dir; remaining args = extra env assignments.
run_retro() {
  local proj="$1"; shift
  env -u PIPELINE_LOGS_ENABLED HOME="$RHOME" CLAUDE_PROJECT_DIR="$proj" "$@" \
    bash "$RETRO_SRC" >/dev/null 2>&1 || true
}

FWD_PAYLOAD='{"session_id":"fwd123","description":"execute-issue-plan #643","subagent_type":"pipeline:tdd-implementer","model":"claude-opus","ts_start":"2026-05-30T10:00:00Z","ts_end":"2026-05-30T10:05:00Z","total_duration_ms":300000,"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":20,"cache_creation_input_tokens":10}}'
run_forward() {
  local proj="$1"; shift
  printf '%s' "$FWD_PAYLOAD" | env -u PIPELINE_LOGS_ENABLED CLAUDE_PROJECT_DIR="$proj" "$@" \
    python3 "$FWD_SRC" >/dev/null 2>&1 || true
}

# --- retroactive: gate UNSET -> no write ---------------------------------
P1="$TMP/retro-unset"; setup_retro_project "$P1"
run_retro "$P1"  # no PIPELINE_LOGS_ENABLED in env
if [ ! -e "$P1/$OUT_REL" ]; then
  pass_msg "retroactive: gate unset writes nothing"
else
  fail_msg "retroactive: gate unset must write nothing"
fi

# --- retroactive: gate=false -> no write ---------------------------------
P2="$TMP/retro-false"; setup_retro_project "$P2"
run_retro "$P2" PIPELINE_LOGS_ENABLED=false
if [ ! -e "$P2/$OUT_REL" ]; then
  pass_msg "retroactive: gate=false writes nothing"
else
  fail_msg "retroactive: gate=false must write nothing"
fi

# --- retroactive: gate=true -> appended ----------------------------------
P3="$TMP/retro-true"; setup_retro_project "$P3"
run_retro "$P3" PIPELINE_LOGS_ENABLED=true
if [ -s "$P3/$OUT_REL" ]; then
  pass_msg "retroactive: gate=true appends"
else
  fail_msg "retroactive: gate=true must append"
fi

# --- forward: gate UNSET -> no write -------------------------------------
P4="$TMP/fwd-unset"; mkdir -p "$P4/.claude/logs"
run_forward "$P4"  # no PIPELINE_LOGS_ENABLED in env
if [ ! -e "$P4/$OUT_REL" ]; then
  pass_msg "forward: gate unset writes nothing"
else
  fail_msg "forward: gate unset must write nothing"
fi

# --- forward: gate=false -> no write -------------------------------------
P5="$TMP/fwd-false"; mkdir -p "$P5/.claude/logs"
run_forward "$P5" PIPELINE_LOGS_ENABLED=false
if [ ! -e "$P5/$OUT_REL" ]; then
  pass_msg "forward: gate=false writes nothing"
else
  fail_msg "forward: gate=false must write nothing"
fi

# --- forward: gate=true -> appended --------------------------------------
P6="$TMP/fwd-true"; mkdir -p "$P6/.claude/logs"
run_forward "$P6" PIPELINE_LOGS_ENABLED=true
if [ -s "$P6/$OUT_REL" ]; then
  pass_msg "forward: gate=true appends"
else
  fail_msg "forward: gate=true must append"
fi

# --- regression guard: both helpers must scrub PIPELINE_LOGS_ENABLED --------
# Ensures the -u flag is present in both env invocations so the unset cases
# remain hermetic even if the helpers are refactored.
SELF="$SCRIPT_DIR/$(basename "$0")"
retro_scrubs=$(awk '/^run_retro\(\)/,/^\}/' "$SELF" | grep -c 'env -u PIPELINE_LOGS_ENABLED' || true)
fwd_scrubs=$(awk '/^run_forward\(\)/,/^\}/' "$SELF" | grep -c 'env -u PIPELINE_LOGS_ENABLED' || true)
if [ "${retro_scrubs:-0}" -ge 1 ]; then
  pass_msg "regression guard: run_retro scrubs PIPELINE_LOGS_ENABLED"
else
  fail_msg "regression guard: run_retro must use env -u PIPELINE_LOGS_ENABLED"
fi
if [ "${fwd_scrubs:-0}" -ge 1 ]; then
  pass_msg "regression guard: run_forward scrubs PIPELINE_LOGS_ENABLED"
else
  fail_msg "regression guard: run_forward must use env -u PIPELINE_LOGS_ENABLED"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
