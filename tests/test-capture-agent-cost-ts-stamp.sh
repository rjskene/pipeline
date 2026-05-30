#!/usr/bin/env bash
# test-capture-agent-cost-ts-stamp.sh — #690 regression guard.
#
# The forward cost-capture hook (hooks/capture_agent_cost.py) emitted inline
# forward records (PostToolUse(Agent) path) with EMPTY ts_start/ts_end, because
# the real PostToolUse(Agent) payload carries no top-level ts_* key. Two
# consequences: (1) per-run time-windowing (`select(.ts_end|startswith(...))`)
# silently dropped 100% of subagent rows, and (2) record_key() was seeded from
# ts_start=="" so every inline record for a given (source, inline, session_id,
# issue, stage) hashed identically → idempotency-key collisions.
#
# The fix stamps ts_end with the hook wall-clock at emit time when the payload
# carries no usable end timestamp, derives ts_start = ts_end - duration_ms when
# duration_ms is known, and re-seeds record_key() off the now-non-empty ts_start.
# A payload that genuinely carries a top-level ts_end still wins (fallback only).
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

run_hook() {
  # run_hook <project-dir> <payload-json>
  env -u PIPELINE_LOGS_ENABLED CLAUDE_PROJECT_DIR="$1" \
    python3 "$HOOK" <<<"$2" \
    || fail "hook exited non-zero"
}

# ---------------------------------------------------------------------------
# Case A: PostToolUse(Agent) WITHOUT any top-level ts_* key (the real shape).
#   -> ts_end stamped (non-empty, ISO-8601), ts_start derived from duration_ms,
#      ts_start <= ts_end.
# ---------------------------------------------------------------------------
PROJ="$(make_project)"
OUT="$PROJ/.claude/logs/agent-costs.jsonl"

PAYLOAD_A='{
  "tool_name": "Agent",
  "session_id": "sA",
  "duration_ms": 41564,
  "tool_input": {
    "description": "execute-issue-plan #690",
    "subagent_type": "pipeline:tdd-implementer"
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

run_hook "$PROJ" "$PAYLOAD_A"
[ -f "$OUT" ] || fail "A: agent-costs.jsonl NOT written"

python3 - "$OUT" <<'PY' || fail "A: ts_end/ts_start assertions failed"
import datetime, json, sys
with open(sys.argv[1]) as fh:
    rec = json.loads(fh.readline())

def expect(cond, msg):
    if not cond:
        raise SystemExit("assert failed: %s (rec=%r)" % (msg, rec))

def parse(t):
    return datetime.datetime.fromisoformat(t.replace("Z", "+00:00"))

expect(rec["ts_end"], "ts_end is non-empty")
parse(rec["ts_end"])  # raises if not ISO-8601
expect(rec["ts_start"], "ts_start is non-empty (derived from ts_end - duration_ms)")
parse(rec["ts_start"])
expect(parse(rec["ts_start"]) <= parse(rec["ts_end"]), "ts_start <= ts_end")
expect(rec["duration_ms"] == 41564, "duration_ms preserved")
PY

# ---------------------------------------------------------------------------
# Case B: two payloads sharing session_id + description (→ same issue+stage),
#   differing only in emit time → DISTINCT record_key. Uses the FLAT shape with
#   distinct explicit ts_end values for determinism (record_key seeds off the
#   derived ts_start, which differs because ts_end differs). Pre-fix both keyed
#   off ts_start=="" and collided.
# ---------------------------------------------------------------------------
PROJ_B="$(make_project)"
OUT_B="$PROJ_B/.claude/logs/agent-costs.jsonl"

PAYLOAD_B1='{
  "session_id": "sB",
  "description": "execute-issue-plan #690",
  "subagent_type": "x",
  "ts_end": "2026-05-30T22:00:00+00:00",
  "total_duration_ms": 1000,
  "usage": {"input_tokens": 1, "output_tokens": 1, "cache_read_input_tokens": 1, "cache_creation_input_tokens": 1}
}'
PAYLOAD_B2='{
  "session_id": "sB",
  "description": "execute-issue-plan #690",
  "subagent_type": "x",
  "ts_end": "2026-05-30T22:05:00+00:00",
  "total_duration_ms": 1000,
  "usage": {"input_tokens": 1, "output_tokens": 1, "cache_read_input_tokens": 1, "cache_creation_input_tokens": 1}
}'

run_hook "$PROJ_B" "$PAYLOAD_B1"
run_hook "$PROJ_B" "$PAYLOAD_B2"

COUNT_B="$(wc -l < "$OUT_B" | tr -d ' ')"
[ "$COUNT_B" = "2" ] || fail "B: expected 2 records, got $COUNT_B"

python3 - "$OUT_B" <<'PY' || fail "B: record_key entropy assertion failed"
import json, sys
keys = []
with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.strip()
        if line:
            keys.append(json.loads(line)["record_key"])
if len(set(keys)) != len(keys):
    raise SystemExit("assert failed: record_keys collide: %r" % keys)
PY

# ---------------------------------------------------------------------------
# Case C: payload-supplied top-level ts_end WINS (wall-clock is a fallback).
#   Uses the FLAT back-compat shape (no tool_name/tool_input/tool_response) so
#   the top-level ts_end survives to build_record's _first(payload,"ts_end",...)
#   read — the PostToolUse(Agent) normaliser intentionally drops top-level ts_*.
# ---------------------------------------------------------------------------
PROJ_C="$(make_project)"
OUT_C="$PROJ_C/.claude/logs/agent-costs.jsonl"

PAYLOAD_C='{
  "session_id": "sC",
  "description": "execute-issue-plan #690",
  "subagent_type": "x",
  "ts_end": "2026-05-30T22:00:00+00:00",
  "total_duration_ms": 2000,
  "usage": {"input_tokens": 1, "output_tokens": 1, "cache_read_input_tokens": 1, "cache_creation_input_tokens": 1}
}'

run_hook "$PROJ_C" "$PAYLOAD_C"

python3 - "$OUT_C" <<'PY' || fail "C: payload ts_end precedence assertion failed"
import json, sys
with open(sys.argv[1]) as fh:
    rec = json.loads(fh.readline())
if rec["ts_end"] != "2026-05-30T22:00:00+00:00":
    raise SystemExit("assert failed: payload ts_end not echoed: %r" % rec["ts_end"])
PY

echo "PASS: test-capture-agent-cost-ts-stamp.sh"
