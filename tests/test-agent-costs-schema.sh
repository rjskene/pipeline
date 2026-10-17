#!/usr/bin/env bash
# Cross-producer schema field-set guard (the #643 consumption-interface guard).
#
# BOTH agent-cost producers must emit the EXACT schema_version=2 field set:
#   top-level: schema_version record_key issue stage agent_kind agent_type
#              agent_id session_id model tokens duration_ms ts_start ts_end
#              source usage_complete turns ctx_first ctx_last
#   tokens.* : input output cache_read cache_creation total
#
# v2 (#1443) is ADDITIVE: `turns` (distinct message.id count on the resolved
# transcript) plus `ctx_first` / `ctx_last` (cache_read+cache_creation of the
# first / last message.id, i.e. absolute context sizes). Nothing renamed or
# removed; tokens.* is unchanged. The bump exists because THIS guard pins the
# exact top-level field set.
#
# We drive each producer to emit a real record and assert the emitted JSON
# object has EXACTLY that key set (top-level + tokens.*). We ALSO grep both
# record-assembling source files for every field name so a rename in EITHER
# producer fails this test even if the fixtures stop exercising that path.
#
#   retroactive: scripts/capture-agent-costs.sh  (make_record dict)
#   forward:     hooks/capture_agent_cost.py      (build_record dict)
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

EXPECTED_TOP='agent_id agent_kind agent_type ctx_first ctx_last duration_ms issue model record_key role schema_version session_id source stage tokens ts_end ts_start turns usage_complete'
EXPECTED_TOKENS='cache_creation cache_read input output total'
# #1470: retroactive-only extras. The forward hook is untouched (no hook
# edits), so the retroactive exact set = shared EXPECTED_TOP + RETRO_EXTRA and
# the forward exact set = EXPECTED_TOP alone.
RETRO_EXTRA='output_complete tool_calls'
RETRO_TOP=$(printf '%s\n' $EXPECTED_TOP $RETRO_EXTRA | sort | tr '\n' ' ' | sed 's/ $//')

# --- drive the RETROACTIVE producer against the fixtures ------------------
RHOME="$TMP/rhome"
RPROJ="$TMP/rproject"
mkdir -p "$RPROJ/.claude/logs"
cp "$FIX/runs.log" "$RPROJ/.claude/logs/runs.log"
cp "$FIX/subagents.log" "$RPROJ/.claude/logs/subagents.log"
cp -r "$FIX/subagents" "$RPROJ/.claude/logs/subagents"
# Place the transcript at the slug path Claude Code would use ("." and "/" both
# sanitised to "-", so ".claude" -> "--claude") for the headless run.
SLUG=$(python3 -c 'import re,sys; print(re.sub(r"[/.]","-",sys.argv[1]))' \
  "/home/fix/claude-pipeline/.claude/worktrees/wt-642")
mkdir -p "$RHOME/.claude/projects/$SLUG"
cp "$FIX/transcript.jsonl" "$RHOME/.claude/projects/$SLUG/sess-aaaa-1111.jsonl"

HOME="$RHOME" CLAUDE_PROJECT_DIR="$RPROJ" PIPELINE_LOGS_ENABLED=true \
  bash "$RETRO_SRC" >/dev/null 2>&1
RETRO_OUT="$RPROJ/.claude/logs/agent-costs.jsonl"
if [ -s "$RETRO_OUT" ]; then
  pass_msg "retroactive producer emitted at least one record"
else
  fail_msg "retroactive producer emitted at least one record"
fi
RETRO_REC=$(head -n 1 "$RETRO_OUT")

# --- drive the FORWARD producer with a synthetic SubagentStop payload -----
FPROJ="$TMP/fproject"
mkdir -p "$FPROJ/.claude/logs"
FPAYLOAD='{"session_id":"fwd123","description":"execute-issue-plan #643","subagent_type":"pipeline:tdd-implementer","model":"claude-opus","ts_start":"2026-05-30T10:00:00Z","ts_end":"2026-05-30T10:05:00Z","total_duration_ms":300000,"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":20,"cache_creation_input_tokens":10}}'
printf '%s' "$FPAYLOAD" | CLAUDE_PROJECT_DIR="$FPROJ" PIPELINE_LOGS_ENABLED=true \
  python3 "$FWD_SRC" >/dev/null 2>&1
FWD_OUT="$FPROJ/.claude/logs/agent-costs.jsonl"
if [ -s "$FWD_OUT" ]; then
  pass_msg "forward producer emitted at least one record"
else
  fail_msg "forward producer emitted at least one record"
fi
FWD_REC=$(head -n 1 "$FWD_OUT")

# --- assert EXACT field sets on both records -----------------------------
assert_keys() {
  local label="$1" rec="$2" want_top="$3"
  local top tokens
  top=$(printf '%s' "$rec" | python3 -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin).keys())))')
  tokens=$(printf '%s' "$rec" | python3 -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin)["tokens"].keys())))')
  if [ "$top" = "$want_top" ]; then
    pass_msg "$label top-level field set is exact"
  else
    fail_msg "$label top-level field set: got [$top] want [$want_top]"
  fi
  if [ "$tokens" = "$EXPECTED_TOKENS" ]; then
    pass_msg "$label tokens.* field set is exact"
  else
    fail_msg "$label tokens.* field set: got [$tokens] want [$EXPECTED_TOKENS]"
  fi
}

assert_keys "retroactive" "$RETRO_REC" "$RETRO_TOP"
assert_keys "forward" "$FWD_REC" "$EXPECTED_TOP"

# --- source-level field-name guard ---------------------------------------
# Every field name must appear quoted in BOTH record-assembling source files.
for field in $EXPECTED_TOP $EXPECTED_TOKENS; do
  if grep -q "\"$field\"" "$RETRO_SRC"; then
    pass_msg "retroactive source names \"$field\""
  else
    fail_msg "retroactive source missing \"$field\" ($RETRO_SRC)"
  fi
  if grep -q "\"$field\"" "$FWD_SRC"; then
    pass_msg "forward source names \"$field\""
  else
    fail_msg "forward source missing \"$field\" ($FWD_SRC)"
  fi
done
# Retroactive-only extras (#1470) are named in the retroactive source only.
for field in $RETRO_EXTRA; do
  if grep -q "\"$field\"" "$RETRO_SRC"; then
    pass_msg "retroactive source names \"$field\""
  else
    fail_msg "retroactive source missing \"$field\" ($RETRO_SRC)"
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
