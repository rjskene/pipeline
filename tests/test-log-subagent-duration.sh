#!/usr/bin/env bash
# test-log-subagent-duration.sh — #663 regression guard.
#
# hooks/log_subagent.py read `tool_response.get("total_duration_ms", 0)`, but
# the real PostToolUse(Agent) payload carries the wall-clock at the TOP LEVEL
# as `duration_ms` (tool_response.total_duration_ms is null/absent). So every
# per-agent JSON + subagents.log row recorded duration 0. The fix sources
# duration from top-level data.get("duration_ms") first, falling back to
# tool_response.get("total_duration_ms") — mirroring the merged #660 fix to
# capture_agent_cost.py._normalize_payload.
#
# Hermetic: self-contained fixture project dir; never touches the live config.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/log_subagent.py"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$HOOK" ] || fail "hook not found: $HOOK"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PROJ="$WORK/proj"
mkdir -p "$PROJ/.claude/logs"

# Real-shape payload: wall-clock duration at TOP LEVEL (duration_ms:1344);
# tool_response.total_duration_ms is null (as in the live payload).
PAYLOAD='{
  "tool_name": "Agent",
  "session_id": "s1",
  "duration_ms": 1344,
  "tool_input": {
    "description": "plan-issue #663",
    "subagent_type": "general-purpose"
  },
  "tool_response": {
    "result": "done",
    "usage": {
      "input_tokens": 10,
      "output_tokens": 20,
      "cache_read_input_tokens": 30,
      "cache_creation_input_tokens": 40
    },
    "total_tokens": 100,
    "total_duration_ms": null,
    "num_turns": 3,
    "agentId": "abcd1234ef"
  }
}'

env -u PIPELINE_LOGS_ENABLED CLAUDE_PROJECT_DIR="$PROJ" \
  python3 "$HOOK" <<<"$PAYLOAD" \
  || fail "hook exited non-zero"

# (a) Per-agent JSON: total_duration_ms must be 1344 (non-zero).
JSON_DIR="$PROJ/.claude/logs/subagents"
[ -d "$JSON_DIR" ] || fail "per-agent JSON dir not created"
JSON_FILE="$(ls -1 "$JSON_DIR"/*.json 2>/dev/null | head -1)"
[ -n "$JSON_FILE" ] || fail "no per-agent JSON file written"

python3 - "$JSON_FILE" <<'PY' || fail "per-agent JSON duration assertion failed"
import json, sys
with open(sys.argv[1]) as fh:
    rec = json.load(fh)
if rec.get("total_duration_ms") != 1344:
    raise SystemExit("expected total_duration_ms==1344, got %r" % rec.get("total_duration_ms"))
PY

# (b) Consolidated subagents.log: duration column (6th, tab-separated) == 1344.
LOG="$PROJ/.claude/logs/subagents.log"
[ -f "$LOG" ] || fail "subagents.log not written"
DURATION_COL="$(awk -F'\t' 'NR==1{print $6}' "$LOG")"
[ "$DURATION_COL" = "1344" ] \
  || fail "subagents.log duration column expected 1344, got '$DURATION_COL'"

echo "PASS: test-log-subagent-duration.sh"
