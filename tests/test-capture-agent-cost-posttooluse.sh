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

# ---------------------------------------------------------------------------
# Case 5pre (#815): _normalize_payload surfaces tool_response.agentId as the
# flat `agent_id` field, so build_record can resolve the durable subagent
# transcript at agent-finish. log_subagent.py:76 already reads
# tool_response.agentId; capture_agent_cost.py:_normalize_payload currently
# drops it.
# ---------------------------------------------------------------------------
python3 - "$HOOK" <<'PY' || fail "case5pre: agentId not surfaced by _normalize_payload"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("capture_agent_cost", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

payload = {
    "tool_name": "Agent",
    "session_id": "s5pre",
    "duration_ms": 100,
    "tool_input": {"description": "plan-issue #815", "subagent_type": "general-purpose"},
    "tool_response": {
        "agentId": "a1234",
        "usage": {
            "input_tokens": 1, "output_tokens": 2,
            "cache_read_input_tokens": 3, "cache_creation_input_tokens": 4,
        },
        "total_duration_ms": None,
    },
}
norm = mod._normalize_payload(payload)
if norm is None:
    raise SystemExit("_normalize_payload returned None (expected a flat dict)")
if norm.get("agent_id") != "a1234":
    raise SystemExit("agent_id=%r expected 'a1234' (regression: agentId dropped)" % norm.get("agent_id"))
PY

# ---------------------------------------------------------------------------
# Case 5help (#815): _subagent_transcript_sum resolves the durable subagent
# transcript via the same glob the backfill INLINE pass uses
# (scripts/capture-agent-costs.sh:346-348):
#   $HOME/.claude/projects/*/<session_id>/subagents/agent-<agent_id>.jsonl
# Sums the four token fields over the transcript JSONL. Returns None on a
# missing transcript or empty agent_id/session_id.
# ---------------------------------------------------------------------------
python3 - "$HOOK" "$WORK" <<'PY' || fail "case5help: _subagent_transcript_sum did not resolve/sum durable transcript"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("capture_agent_cost", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

fake_home = os.path.join(sys.argv[2], "home5help")
sub = os.path.join(fake_home, ".claude", "projects", "-slug", "sessHELP", "subagents")
os.makedirs(sub)
with open(os.path.join(sub, "agent-aHELP.jsonl"), "w") as fh:
    fh.write('{"message":{"usage":{"cache_read_input_tokens":700}}}\n')
    fh.write('{"message":{"usage":{"cache_read_input_tokens":700}}}\n')

os.environ["HOME"] = fake_home
summ = mod._subagent_transcript_sum("sessHELP", "aHELP")
if summ is None:
    raise SystemExit("expected a sum dict, got None")
if summ["cache_read"] != 1400:
    raise SystemExit("cache_read=%r expected 1400" % summ["cache_read"])
if mod._subagent_transcript_sum("sessHELP", "missing") is not None:
    raise SystemExit("missing agent_id should resolve to None")
if mod._subagent_transcript_sum("sessHELP", "") is not None:
    raise SystemExit("empty agent_id should resolve to None")
PY

# ---------------------------------------------------------------------------
# Case 5a (#815): build_record TRUES-UP the forward lower-bound from the durable
# subagent transcript when the cumulative strictly exceeds the final-turn snap.
# usage_complete flips to true; the transcript model wins. source/agent_kind
# unchanged. This is the #815 close.
# ---------------------------------------------------------------------------
python3 - "$HOOK" "$WORK" <<'PY' || fail "case5a: cumulative not adopted (true-up)"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("capture_agent_cost", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

fake_home = os.path.join(sys.argv[2], "home5a")
sub = os.path.join(fake_home, ".claude", "projects", "-slug", "sess5a", "subagents")
os.makedirs(sub)
with open(os.path.join(sub, "agent-a5a.jsonl"), "w") as fh:
    fh.write('{"message":{"model":"claude-opus-4-8","usage":{"cache_read_input_tokens":5000}}}\n')
    fh.write('{"message":{"model":"claude-opus-4-8","usage":{"cache_read_input_tokens":5000}}}\n')
os.environ["HOME"] = fake_home

# final-turn lower-bound: 100 input + 200 output + 300 cache_read + 400 cache_creation = 1000
payload = {
    "session_id": "sess5a",
    "agent_id": "a5a",
    "description": "execute-issue-plan #815",
    "usage": {
        "input_tokens": 100, "output_tokens": 200,
        "cache_read_input_tokens": 300, "cache_creation_input_tokens": 400,
    },
    "tool_input": {"subagent_type": "general-purpose"},
}
rec = mod.build_record(payload)
if rec is None:
    raise SystemExit("build_record returned None")

def expect(cond, msg):
    if not cond:
        raise SystemExit("assert failed: %s (rec=%r)" % (msg, rec))

expect(rec["usage_complete"] is True, "usage_complete True on adopt")
expect(rec["tokens"]["cache_read"] == 10000, "cache_read summed from transcript")
# transcript: input 0, output 0, cache_read 10000, cache_creation 0
expect(rec["tokens"]["input"] == 0, "input from transcript")
expect(rec["tokens"]["output"] == 0, "output from transcript")
expect(rec["tokens"]["cache_creation"] == 0, "cache_creation from transcript")
expect(rec["tokens"]["total"] == 10000, "total == summed transcript total")
expect(rec["model"] == "claude-opus-4-8", "transcript model wins")
expect(rec["source"] == "forward", "source unchanged")
expect(rec["agent_kind"] == "inline", "agent_kind unchanged")
PY

# ---------------------------------------------------------------------------
# Case 5b (#815): pruned-race fallback — agentId present but the durable
# transcript is absent (empty HOME → no glob match). Keep the lower-bound;
# usage_complete stays false; no crash.
# ---------------------------------------------------------------------------
python3 - "$HOOK" "$WORK" <<'PY' || fail "case5b: pruned-race fallback did not keep lower-bound"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("capture_agent_cost", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

os.environ["HOME"] = os.path.join(sys.argv[2], "home5b-empty")  # no transcript dir
payload = {
    "session_id": "sess5b",
    "agent_id": "a5b",
    "description": "execute-issue-plan #815",
    "usage": {
        "input_tokens": 100, "output_tokens": 0,
        "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0,
    },
}
rec = mod.build_record(payload)
if rec is None:
    raise SystemExit("build_record returned None")
if rec["usage_complete"] is not False:
    raise SystemExit("usage_complete=%r expected False (no transcript)" % rec["usage_complete"])
if rec["tokens"]["total"] != 100:
    raise SystemExit("tokens.total=%r expected 100 (lower-bound kept)" % rec["tokens"]["total"])
PY

# ---------------------------------------------------------------------------
# Case 5c (#815): never-downgrade — transcript sum (total 4) is <= the
# final-turn lower-bound (total 400). Keep the lower-bound; usage_complete stays
# false. A partial/empty transcript can never understate a record.
# ---------------------------------------------------------------------------
python3 - "$HOOK" "$WORK" <<'PY' || fail "case5c: never-downgrade violated"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("capture_agent_cost", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

fake_home = os.path.join(sys.argv[2], "home5c")
sub = os.path.join(fake_home, ".claude", "projects", "-slug", "sess5c", "subagents")
os.makedirs(sub)
with open(os.path.join(sub, "agent-a5c.jsonl"), "w") as fh:
    fh.write('{"message":{"usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":1,"cache_creation_input_tokens":1}}}\n')
os.environ["HOME"] = fake_home

# lower-bound total 400 (100 each) > transcript total 4
payload = {
    "session_id": "sess5c",
    "agent_id": "a5c",
    "description": "execute-issue-plan #815",
    "usage": {
        "input_tokens": 100, "output_tokens": 100,
        "cache_read_input_tokens": 100, "cache_creation_input_tokens": 100,
    },
}
rec = mod.build_record(payload)
if rec is None:
    raise SystemExit("build_record returned None")
if rec["usage_complete"] is not False:
    raise SystemExit("usage_complete=%r expected False (no-downgrade)" % rec["usage_complete"])
if rec["tokens"]["total"] != 400:
    raise SystemExit("tokens.total=%r expected 400 (lower-bound kept)" % rec["tokens"]["total"])
PY

# ---------------------------------------------------------------------------
# Case 5d (#815): agentId absent — unchanged behavior, no transcript lookup,
# usage_complete false, no crash.
# ---------------------------------------------------------------------------
python3 - "$HOOK" <<'PY' || fail "case5d: agentId-absent path changed/crashed"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("capture_agent_cost", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

payload = {
    "session_id": "sess5d",
    "description": "execute-issue-plan #815",
    "usage": {
        "input_tokens": 100, "output_tokens": 0,
        "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0,
    },
}
rec = mod.build_record(payload)
if rec is None:
    raise SystemExit("build_record returned None")
if rec["usage_complete"] is not False:
    raise SystemExit("usage_complete=%r expected False (no agentId)" % rec["usage_complete"])
if rec["tokens"]["total"] != 100:
    raise SystemExit("tokens.total=%r expected 100" % rec["tokens"]["total"])
PY

# ---------------------------------------------------------------------------
# Case 6 (#1098): split-role role attribution on the forward hook.
#   - a `split-role RED` PostToolUse(Agent) payload with NO resolvable
#     transcript/session-model yields role=red AND model containing 'opus'
#     (the opus-red fallback);
#   - a `split-role GREEN` payload yields role=green (and is NOT forced to the
#     opus-red fallback);
#   - a normal non-split execute payload yields role=single.
# build_record is called directly (mirrors cases 3/4a/5*) so the role parse +
# opus-red fallback are exercised without the durable-transcript adopt path.
# ---------------------------------------------------------------------------
python3 - "$HOOK" <<'PY' || fail "case6: split-role role/opus-red attribution wrong"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("capture_agent_cost", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

def rec_for(desc):
    payload = {
        "session_id": "s6",
        "description": desc,
        "usage": {
            "input_tokens": 100, "output_tokens": 0,
            "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0,
        },
        "tool_input": {"subagent_type": "tdd-implementer"},
    }
    r = mod.build_record(payload)
    if r is None:
        raise SystemExit("build_record returned None for %r" % desc)
    return r

# RED: role=red, model falls back to opus (no transcript/session model resolved).
red = rec_for("execute-issue-plan #642 split-role RED (PATH B inline)")
if red.get("role") != "red":
    raise SystemExit("RED role=%r expected 'red'" % red.get("role"))
if "opus" not in red.get("model", ""):
    raise SystemExit("RED model=%r expected to contain 'opus' (opus-red fallback)" % red.get("model"))

# GREEN: role=green, NOT forced to the opus-red fallback (model stays "").
green = rec_for("execute-issue-plan #642 split-role GREEN (PATH B inline)")
if green.get("role") != "green":
    raise SystemExit("GREEN role=%r expected 'green'" % green.get("role"))
if "opus" in green.get("model", ""):
    raise SystemExit("GREEN model=%r must NOT inherit the opus-red fallback" % green.get("model"))

# Non-split execute: role=single.
single = rec_for("execute-issue-plan #642")
if single.get("role") != "single":
    raise SystemExit("non-split role=%r expected 'single'" % single.get("role"))
PY

# ---------------------------------------------------------------------------
# Case 6b (#1098): build_stop_record (orchestrator) records are role=single.
# An orchestrator record is never a TDD split-role lane.
# ---------------------------------------------------------------------------
python3 - "$HOOK" "$WORK" <<'PY' || fail "case6b: orchestrator stop record not role=single"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("capture_agent_cost", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

import tempfile
logs_dir = tempfile.mkdtemp(dir=sys.argv[2])
transcript = os.path.join(logs_dir, "transcript-6b.jsonl")
with open(transcript, "w") as fh:
    fh.write('{"type":"assistant","timestamp":"2026-05-30T11:00:01.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":300,"output_tokens":60,"cache_read_input_tokens":15,"cache_creation_input_tokens":9}}}\n')

payload = {"session_id": "s6b", "transcript_path": transcript}
rec = mod.build_stop_record(payload, logs_dir)
if rec is None:
    raise SystemExit("build_stop_record returned None (expected a record)")
if rec.get("role") != "single":
    raise SystemExit("orchestrator role=%r expected 'single'" % rec.get("role"))
PY

echo "PASS: test-capture-agent-cost-posttooluse.sh"
