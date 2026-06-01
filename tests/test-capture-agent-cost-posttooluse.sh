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
expect(rec["usage_complete"] is False, "inline posttooluse usage_complete==false")
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

# ---------------------------------------------------------------------------
# Case 4a (#699): build_record defaults agent_type to "general-purpose" (NOT
# "unknown") when NO subagent_type is present anywhere.
#
# Inline dispatches that supply no subagent_type fall through to build_record's
# final default. #691 left that default at the literal "unknown", which is what
# produced the 59/66 bogus "unknown" records. log_subagent.py:61 instead
# defaults an absent subagent_type to "general-purpose" (the dispatch tool's
# real default for un-typed inline dispatches). This asserts build_record
# mirrors that default — provenance accuracy, not a placeholder swap.
# ---------------------------------------------------------------------------
python3 - "$HOOK" <<'PY' || fail "case4a: agent_type default not 'general-purpose' when subagent_type absent"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("capture_agent_cost", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Flat payload that proceeds past the stage gate and usage check, carrying NO
# subagent_type anywhere (no top-level key, no tool_input).
payload = {
    "session_id": "s4",
    "description": "plan-issue #700",
    "usage": {
        "input_tokens": 1,
        "output_tokens": 2,
        "cache_read_input_tokens": 3,
        "cache_creation_input_tokens": 4,
    },
}
rec = mod.build_record(payload)
if rec is None:
    raise SystemExit("build_record returned None (expected a record)")
if rec["agent_type"] != "general-purpose":
    raise SystemExit(
        "agent_type=%r expected 'general-purpose' (regression: un-typed inline "
        "dispatch defaults to the bogus 'unknown' instead of mirroring "
        "log_subagent.py:61)" % rec["agent_type"]
    )
PY

# ---------------------------------------------------------------------------
# Case 4b (#699): an inline PostToolUse(Agent) record inherits the SESSION model
# from the orchestrator state sidecar (keyed by session_id).
#
# The PostToolUse(Agent) payload carries no `model` and no usable transcript
# path (#691 WON'T-FIX). But the inline subagent inherits the session model,
# which build_stop_record already resolves from the main-session transcript and
# persists into .claude/logs/agent-cost-orchestrator-state.json keyed by the
# SAME session_id the inline records carry. We pre-seed that sidecar (as if a
# Stop already ran for session "s4") and assert the written inline record's
# `model` is inherited and `agent_type` is the dispatched type.
# ---------------------------------------------------------------------------
PROJ4="$(make_project)"
OUT4="$PROJ4/.claude/logs/agent-costs.jsonl"
STATE4="$PROJ4/.claude/logs/agent-cost-orchestrator-state.json"

cat > "$STATE4" <<'STATE'
{"s4": {"model": "claude-opus-4-8", "input": 0, "output": 0, "cache_read": 0, "cache_creation": 0}}
STATE

PAYLOAD_INLINE='{
  "tool_name": "Agent",
  "session_id": "s4",
  "duration_ms": 500,
  "tool_input": {
    "description": "plan-issue #700",
    "subagent_type": "general-purpose"
  },
  "tool_response": {
    "usage": {
      "input_tokens": 10,
      "output_tokens": 20,
      "cache_read_input_tokens": 30,
      "cache_creation_input_tokens": 40
    },
    "total_duration_ms": null
  }
}'

env -u PIPELINE_LOGS_ENABLED CLAUDE_PROJECT_DIR="$PROJ4" \
  python3 "$HOOK" <<<"$PAYLOAD_INLINE" \
  || fail "case4b: hook exited non-zero"

[ -f "$OUT4" ] || fail "case4b: agent-costs.jsonl NOT written"

python3 - "$OUT4" <<'PY' || fail "case4b: inline record did not inherit session model / agent_type"
import json, sys
with open(sys.argv[1]) as fh:
    rec = json.loads(fh.readline())

def expect(cond, msg):
    if not cond:
        raise SystemExit("assert failed: %s (rec=%r)" % (msg, rec))

expect(rec["agent_kind"] == "inline", "agent_kind==inline")
expect(rec["model"] == "claude-opus-4-8", "model inherited from sidecar")
expect(rec["agent_type"] == "general-purpose", "agent_type is dispatched type, not unknown")
PY

# ---------------------------------------------------------------------------
# Case 4c (#699): fail-open — when NO orchestrator state sidecar exists, the
# inline record's model stays "" (unchanged behavior). Guards against a hard
# dependency on the sidecar: an inline record that fires before the session's
# first Stop must not raise and must leave model empty.
# ---------------------------------------------------------------------------
PROJ4C="$(make_project)"
OUT4C="$PROJ4C/.claude/logs/agent-costs.jsonl"
# No state file pre-seeded.

env -u PIPELINE_LOGS_ENABLED CLAUDE_PROJECT_DIR="$PROJ4C" \
  python3 "$HOOK" <<<"$PAYLOAD_INLINE" \
  || fail "case4c: hook exited non-zero"

[ -f "$OUT4C" ] || fail "case4c: agent-costs.jsonl NOT written"

python3 - "$OUT4C" <<'PY' || fail "case4c: model not fail-open empty when no sidecar"
import json, sys
with open(sys.argv[1]) as fh:
    rec = json.loads(fh.readline())
if rec["model"] != "":
    raise SystemExit("model=%r expected '' (fail-open when no sidecar)" % rec["model"])
PY

# ---------------------------------------------------------------------------
# Case 4d (#699): a model-less subsequent Stop must NOT clobber a
# previously-known session model in the sidecar.
#
# build_stop_record rebuilds state[session_id] from the four token fields on
# every fire. The model is persisted alongside, but only when the CURRENT
# transcript resolves a model. A transcript whose tail carries no
# `message.model` (e.g. after compaction/truncation) yields model="" — the
# write must then PRESERVE the model a prior Stop already recorded, so inline
# records keep inheriting it. Guards the no-clobber invariant the Task 2.1
# comment asserts.
# ---------------------------------------------------------------------------
PROJ4D="$(make_project)"
STATE4D="$PROJ4D/.claude/logs/agent-cost-orchestrator-state.json"
TRANSCRIPT4D="$PROJ4D/transcript-4d.jsonl"

# Pre-seed: a prior Stop already recorded session "sM" with a known model and
# its last cumulative token totals.
cat > "$STATE4D" <<'STATE'
{"sM": {"model": "claude-opus-4-8", "input": 100, "output": 20, "cache_read": 5, "cache_creation": 2}}
STATE

# A new transcript with FRESH cumulative usage (so the work-delta is > 0 and a
# record is emitted) but NO `message.model` anywhere — model-less.
cat > "$TRANSCRIPT4D" <<'JSONL'
{"type":"assistant","timestamp":"2026-05-30T11:00:01.000Z","message":{"usage":{"input_tokens":300,"output_tokens":60,"cache_read_input_tokens":15,"cache_creation_input_tokens":9}}}
JSONL

PAYLOAD4D="$(printf '{"session_id":"sM","transcript_path":"%s"}' "$TRANSCRIPT4D")"

env -u PIPELINE_LOGS_ENABLED CLAUDE_PROJECT_DIR="$PROJ4D" \
  python3 "$HOOK" <<<"$PAYLOAD4D" \
  || fail "case4d: hook exited non-zero"

python3 - "$STATE4D" <<'PY' || fail "case4d: model-less Stop clobbered the previously-known session model"
import json, sys
with open(sys.argv[1]) as fh:
    state = json.load(fh)
model = state.get("sM", {}).get("model")
if model != "claude-opus-4-8":
    raise SystemExit(
        "state['sM']['model']=%r expected 'claude-opus-4-8' preserved "
        "(regression: model-less subsequent Stop clobbered a known model)" % model
    )
PY

echo "PASS: test-capture-agent-cost-posttooluse.sh"
