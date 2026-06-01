#!/usr/bin/env bash
# test-capture-agent-cost-hook.sh — contract test for the forward
# SubagentStop/Stop cost-capture hook (hooks/capture_agent_cost.py).
#
# The hook is the DURABLE, ACCURATE forward cost source. It must:
#   1. write NOTHING when PIPELINE_LOGS_ENABLED is unset or != "true"
#   2. emit exactly one schema_version=1 forward record for a pipeline
#      description carrying a usage block
#   3. skip non-stage descriptions (no record)
#   4. fail open when no usage field is present (no record, exit 0)
#
# Hermetic: temp $HOME and $CLAUDE_PROJECT_DIR; the only side effect under test
# is .claude/logs/agent-costs.jsonl inside the temp project dir.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/capture_agent_cost.py"

fail() { echo "FAIL: $*" >&2; exit 1; }

if [ ! -f "$HOOK" ]; then
  fail "hook not found: $HOOK"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
export CLAUDE_PROJECT_DIR="$WORK/project"
mkdir -p "$HOME" "$CLAUDE_PROJECT_DIR"

OUT="$CLAUDE_PROJECT_DIR/.claude/logs/agent-costs.jsonl"
ERRLOG="$CLAUDE_PROJECT_DIR/.claude/logs/agent-cost-hook-errors.log"

run_hook() {
  # $1 = payload json on stdin; PIPELINE_LOGS_ENABLED inherited from caller env.
  printf '%s' "$1" | python3 "$HOOK"
  return $?
}

# ---------------------------------------------------------------------------
# Case 1: gate OFF -> no agent-costs.jsonl written.
# ---------------------------------------------------------------------------
PAYLOAD_PIPELINE='{
  "session_id": "sess-abc",
  "subagent_type": "pr-eval-agent",
  "description": "Evaluate PR #137 for #134",
  "total_duration_ms": 4200,
  "usage": {
    "input_tokens": 100,
    "output_tokens": 20,
    "cache_read_input_tokens": 5,
    "cache_creation_input_tokens": 3
  }
}'

unset PIPELINE_LOGS_ENABLED
run_hook "$PAYLOAD_PIPELINE" || fail "case1: hook exited non-zero with gate unset"
[ -f "$OUT" ] && fail "case1: agent-costs.jsonl written with PIPELINE_LOGS_ENABLED unset"

export PIPELINE_LOGS_ENABLED=false
run_hook "$PAYLOAD_PIPELINE" || fail "case1b: hook exited non-zero with gate=false"
[ -f "$OUT" ] && fail "case1b: agent-costs.jsonl written with PIPELINE_LOGS_ENABLED=false"

# ---------------------------------------------------------------------------
# Case 2: gate ON + pipeline description + usage -> exactly one forward record.
# ---------------------------------------------------------------------------
export PIPELINE_LOGS_ENABLED=true
run_hook "$PAYLOAD_PIPELINE" || fail "case2: hook exited non-zero"
[ -f "$OUT" ] || fail "case2: agent-costs.jsonl not written"

COUNT="$(wc -l < "$OUT" | tr -d ' ')"
[ "$COUNT" = "1" ] || fail "case2: expected exactly 1 record, got $COUNT"

python3 - "$OUT" <<'PY' || fail "case2: record failed schema assertions"
import hashlib, json, sys
with open(sys.argv[1]) as fh:
    rec = json.loads(fh.readline())

def expect(cond, msg):
    if not cond:
        raise SystemExit("assert failed: %s (rec=%r)" % (msg, rec))

expect(rec["schema_version"] == 1, "schema_version==1")
expect(rec["issue"] == "134", "issue==134")
expect(rec["stage"] == "pr-eval", "stage==pr-eval")
expect(rec["agent_kind"] == "inline", "agent_kind==inline")
expect(rec["agent_type"] == "pr-eval-agent", "agent_type from subagent_type")
expect(rec["session_id"] == "sess-abc", "session_id")
expect(rec["source"] == "forward", "source==forward")
expect(rec["usage_complete"] is False, "inline final-turn usage_complete==false")

t = rec["tokens"]
expect(t["input"] == 100, "tokens.input")
expect(t["output"] == 20, "tokens.output")
expect(t["cache_read"] == 5, "tokens.cache_read")
expect(t["cache_creation"] == 3, "tokens.cache_creation")
expect(t["total"] == 128, "tokens.total == sum of four")

for k in ("model", "duration_ms", "ts_start", "ts_end"):
    expect(k in rec, "field present: %s" % k)
expect(rec["duration_ms"] == 4200, "duration_ms from total_duration_ms")

raw = "forward|inline|%s|%s|%s|%s" % (
    rec["session_id"], rec["issue"], rec["stage"], rec["ts_start"])
expect(rec["record_key"] == hashlib.sha1(raw.encode()).hexdigest(),
       "record_key formula")
PY

# ---------------------------------------------------------------------------
# Case 3: gate ON + non-stage description -> no new record.
# ---------------------------------------------------------------------------
PAYLOAD_NONSTAGE='{
  "session_id": "sess-xyz",
  "subagent_type": "general-purpose",
  "description": "analyze open-issue hygiene shortlist",
  "usage": {"input_tokens": 9, "output_tokens": 1}
}'
run_hook "$PAYLOAD_NONSTAGE" || fail "case3: hook exited non-zero"
COUNT="$(wc -l < "$OUT" | tr -d ' ')"
[ "$COUNT" = "1" ] || fail "case3: non-stage description produced a record (count=$COUNT)"

# ---------------------------------------------------------------------------
# Case 4: gate ON + NO usage field at all -> fail-open, no record, exit 0.
# ---------------------------------------------------------------------------
PAYLOAD_NOUSAGE='{
  "session_id": "sess-nou",
  "subagent_type": "pr-eval-agent",
  "description": "Evaluate PR #200 for #199"
}'
run_hook "$PAYLOAD_NOUSAGE"
rc=$?
[ "$rc" = "0" ] || fail "case4: hook did not exit 0 (rc=$rc)"
COUNT="$(wc -l < "$OUT" | tr -d ' ')"
[ "$COUNT" = "1" ] || fail "case4: missing usage produced a record (count=$COUNT)"

[ -s "$ERRLOG" ] && fail "case4: error log non-empty: $(cat "$ERRLOG")"

echo "PASS: test-capture-agent-cost-hook.sh"
