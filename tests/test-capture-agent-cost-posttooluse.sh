#!/usr/bin/env bash
# test-capture-agent-cost-posttooluse.sh — #660 regression guard.
#
# The forward cost-capture hook (hooks/capture_agent_cost.py) was registered on
# SubagentStop/Stop, but those payloads carry NEITHER `description` NOR `usage`
# — so build_record() returned None every time and agent-costs.jsonl was never
# written. The fix re-points the hook to PostToolUse(Agent), whose payload shape
# is {tool_name, tool_input{description,subagent_type}, tool_response{usage,...}}.
# (The subagent dispatch tool in this environment is named "Agent", not "Task".)
#
# This test pipes a realistic PostToolUse(Agent) payload and asserts a forward
# record is written; it also asserts non-Agent PostToolUse payloads (e.g. Bash)
# produce NO record.
#
# Hermetic: self-contained fixture project dir with its own pipeline.config
# (PIPELINE_LOGS_ENABLED=true); never touches the live (gitignored) config.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/capture_agent_cost.py"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$HOOK" ] || fail "hook not found: $HOOK"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

make_project() {
  local proj="$WORK/proj-$RANDOM"
  mkdir -p "$proj/.claude/logs"
  cat > "$proj/pipeline.config" <<CFG
# host-specific pipeline config (fixture)
PIPELINE_BASE_BRANCH=staging
PIPELINE_LOGS_ENABLED=true
CFG
  printf '%s' "$proj"
}

# ---------------------------------------------------------------------------
# Case 1: PostToolUse(Agent) payload -> exactly one forward record.
# ---------------------------------------------------------------------------
PROJ="$(make_project)"
OUT="$PROJ/.claude/logs/agent-costs.jsonl"

# Realistic shape: wall-clock duration is at the TOP LEVEL as `duration_ms`
# (e.g. 1344). The real PostToolUse(Agent) payload has tool_response with NO
# total_duration_ms (null/absent) — so the hook must source duration from the
# top-level field, falling back to tool_response.total_duration_ms.
PAYLOAD_AGENT='{
  "tool_name": "Agent",
  "session_id": "s1",
  "duration_ms": 1344,
  "tool_input": {
    "description": "plan-issue #656",
    "subagent_type": "general-purpose"
  },
  "tool_response": {
    "usage": {
      "input_tokens": 10,
      "output_tokens": 20,
      "cache_read_input_tokens": 30,
      "cache_creation_input_tokens": 40
    },
    "total_duration_ms": null,
    "total_tokens": 100
  }
}'

env -u PIPELINE_LOGS_ENABLED CLAUDE_PROJECT_DIR="$PROJ" \
  python3 "$HOOK" <<<"$PAYLOAD_AGENT" \
  || fail "agent: hook exited non-zero"

[ -f "$OUT" ] || fail "agent: agent-costs.jsonl NOT written for PostToolUse(Agent)"

COUNT="$(wc -l < "$OUT" | tr -d ' ')"
[ "$COUNT" = "1" ] || fail "agent: expected exactly 1 record, got $COUNT"

python3 - "$OUT" <<'PY' || fail "agent: record failed schema assertions"
import json, sys
with open(sys.argv[1]) as fh:
    rec = json.loads(fh.readline())

def expect(cond, msg):
    if not cond:
        raise SystemExit("assert failed: %s (rec=%r)" % (msg, rec))

expect(rec["stage"] == "plan", "stage==plan")
expect(rec["issue"] == "656", "issue==656")
expect(rec["source"] == "forward", "source==forward")
expect(rec["agent_kind"] == "inline", "agent_kind==inline")
expect(rec["agent_type"] == "general-purpose", "agent_type from subagent_type")
expect(rec["session_id"] == "s1", "session_id from top-level")
expect(rec["tokens"]["total"] == 100, "tokens.total == 10+20+30+40")
expect(rec["duration_ms"] == 1344, "duration_ms from top-level duration_ms")
expect(rec["duration_ms"] != 0, "duration_ms is non-zero (regression guard)")
PY

# ---------------------------------------------------------------------------
# Case 2: PostToolUse for a non-Agent tool (Bash) -> NO record.
# ---------------------------------------------------------------------------
PROJ2="$(make_project)"
OUT2="$PROJ2/.claude/logs/agent-costs.jsonl"

PAYLOAD_BASH='{
  "tool_name": "Bash",
  "session_id": "s1",
  "tool_input": {
    "description": "plan-issue #656",
    "subagent_type": "general-purpose"
  },
  "tool_response": {
    "usage": {
      "input_tokens": 10,
      "output_tokens": 20,
      "cache_read_input_tokens": 30,
      "cache_creation_input_tokens": 40
    },
    "total_duration_ms": 1234
  }
}'

env -u PIPELINE_LOGS_ENABLED CLAUDE_PROJECT_DIR="$PROJ2" \
  python3 "$HOOK" <<<"$PAYLOAD_BASH" \
  || fail "bash: hook exited non-zero"

[ -f "$OUT2" ] && fail "bash: agent-costs.jsonl written for non-Agent PostToolUse"

# ---------------------------------------------------------------------------
# Case 3 (#691): build_record reads agent_type from the nested
# tool_input.subagent_type when it is ABSENT at the top level.
#
# The live "unknown" records (54/61) came through a payload shape where
# build_record's _first(payload, "subagent_type") found nothing because
# subagent_type was reachable only under tool_input. (_normalize_payload
# strips tool_input for the Agent path and rejects it for non-Agent payloads,
# so this nested-read fallback can only be exercised by calling build_record
# directly.) This asserts build_record itself reaches into
# tool_input.subagent_type — mirroring log_subagent.py:61 — so agent_type is
# the dispatched type, NOT "unknown".
# ---------------------------------------------------------------------------
python3 - "$HOOK" <<'PY' || fail "case3: agent_type not read from nested tool_input.subagent_type"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("capture_agent_cost", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Flat back-compat payload: description/usage at top level (so build_record
# proceeds past the stage gate and the usage check), subagent_type reachable
# ONLY via nested tool_input — NOT at the top level.
payload = {
    "session_id": "s3",
    "description": "execute-issue-plan #691",
    "usage": {
        "input_tokens": 1,
        "output_tokens": 2,
        "cache_read_input_tokens": 3,
        "cache_creation_input_tokens": 4,
    },
    "tool_input": {"subagent_type": "tdd-implementer"},
}
rec = mod.build_record(payload)
if rec is None:
    raise SystemExit("build_record returned None (expected a record)")
if rec["agent_type"] != "tdd-implementer":
    raise SystemExit(
        "agent_type=%r expected 'tdd-implementer' (regression: nested "
        "tool_input.subagent_type not read; got 'unknown')" % rec["agent_type"]
    )
PY

echo "PASS: test-capture-agent-cost-posttooluse.sh"
