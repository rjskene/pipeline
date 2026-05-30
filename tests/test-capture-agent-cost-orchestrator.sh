#!/usr/bin/env bash
# test-capture-agent-cost-orchestrator.sh — #662 orchestrator inline-cost capture.
#
# The forward cost-capture hook (hooks/capture_agent_cost.py) records subagent
# cost on PostToolUse(Agent). It did NOT capture the MAIN orchestrator session's
# own inline turns, because those produce no Agent dispatch. This test covers a
# new Stop branch: when the hook receives a payload carrying `transcript_path`
# and NO `tool_name`, it parses the transcript JSONL, sums per-assistant-message
# `message.usage`, and emits a synthetic `stage=orchestrator` / `agent_kind=main`
# record. Repeated Stop fires emit only the per-session DELTA (transcript usage
# is cumulative) so the downstream SUM never double-counts.
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
# Case 1: Stop payload with transcript_path -> one orchestrator record whose
# tokens sum BOTH assistant lines (the non-JSON line is skipped).
# ---------------------------------------------------------------------------
PROJ="$(make_project)"
OUT="$PROJ/.claude/logs/agent-costs.jsonl"
TRANSCRIPT="$PROJ/transcript-1.jsonl"

cat > "$TRANSCRIPT" <<'JSONL'
{"type":"system","timestamp":"2026-05-30T10:00:00.000Z","subtype":"init"}
{"type":"assistant","timestamp":"2026-05-30T10:00:01.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":5,"cache_creation_input_tokens":2}}}
not json at all
{"type":"assistant","timestamp":"2026-05-30T10:00:05.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":200,"output_tokens":40,"cache_read_input_tokens":10,"cache_creation_input_tokens":3}}}
JSONL

PAYLOAD="$(printf '{"session_id":"stop-1","transcript_path":"%s"}' "$TRANSCRIPT")"

env -u PIPELINE_LOGS_ENABLED CLAUDE_PROJECT_DIR="$PROJ" \
  python3 "$HOOK" <<<"$PAYLOAD" \
  || fail "stop: hook exited non-zero"

[ -f "$OUT" ] || fail "stop: agent-costs.jsonl NOT written for Stop payload"

COUNT="$(wc -l < "$OUT" | tr -d ' ')"
[ "$COUNT" = "1" ] || fail "stop: expected exactly 1 record, got $COUNT"

python3 - "$OUT" <<'PY' || fail "stop: record failed schema assertions"
import json, sys
with open(sys.argv[1]) as fh:
    rec = json.loads(fh.readline())

def expect(cond, msg):
    if not cond:
        raise SystemExit("assert failed: %s (rec=%r)" % (msg, rec))

expect(rec["stage"] == "orchestrator", "stage==orchestrator")
expect(rec["agent_kind"] == "main", "agent_kind==main")
expect(rec["agent_type"] == "orchestrator", "agent_type==orchestrator")
expect(rec["issue"] == "", "issue==''")
expect(rec["source"] == "forward", "source==forward")
expect(rec["usage_complete"] is True, "usage_complete==true")
expect(rec["model"] == "claude-opus-4-8", "model from last assistant line")
expect(rec["tokens"]["input"] == 300, "tokens.input == 100+200")
expect(rec["tokens"]["output"] == 60, "tokens.output == 20+40")
expect(rec["tokens"]["cache_read"] == 15, "tokens.cache_read == 5+10")
expect(rec["tokens"]["cache_creation"] == 5, "tokens.cache_creation == 2+3")
expect(rec["tokens"]["total"] == 380, "tokens.total == 380")
PY

# ---------------------------------------------------------------------------
# Case 2: repeated Stop fires for the same session with a GROWING transcript
# emit only the per-fire DELTA (transcript usage is cumulative), so the
# downstream SUM equals the cumulative total — never double-counts. A re-fire
# with NO growth writes nothing.
# ---------------------------------------------------------------------------
PROJ2="$(make_project)"
OUT2="$PROJ2/.claude/logs/agent-costs.jsonl"
T2="$PROJ2/transcript-2.jsonl"
PAYLOAD2="$(printf '{"session_id":"stop-2","transcript_path":"%s"}' "$T2")"

# Fire 1: one assistant line, cumulative total = 122.
cat > "$T2" <<'JSONL'
{"type":"assistant","timestamp":"2026-05-30T11:00:01.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":0,"cache_creation_input_tokens":2}}}
JSONL
env -u PIPELINE_LOGS_ENABLED CLAUDE_PROJECT_DIR="$PROJ2" \
  python3 "$HOOK" <<<"$PAYLOAD2" || fail "case2: fire-1 hook exited non-zero"

# Fire 2: append a second assistant line (adds 258), cumulative total = 380.
cat >> "$T2" <<'JSONL'
{"type":"assistant","timestamp":"2026-05-30T11:00:05.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":200,"output_tokens":40,"cache_read_input_tokens":15,"cache_creation_input_tokens":3}}}
JSONL
env -u PIPELINE_LOGS_ENABLED CLAUDE_PROJECT_DIR="$PROJ2" \
  python3 "$HOOK" <<<"$PAYLOAD2" || fail "case2: fire-2 hook exited non-zero"

COUNT2="$(wc -l < "$OUT2" | tr -d ' ')"
[ "$COUNT2" = "2" ] || fail "case2: expected 2 records after two fires, got $COUNT2"

python3 - "$OUT2" <<'PY' || fail "case2: delta sum assertion failed"
import json, sys
totals = []
with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.strip()
        if line:
            totals.append(json.loads(line)["tokens"]["total"])
s = sum(totals)
if s != 380:
    raise SystemExit("assert failed: SUM(tokens.total) == 380 (deltas, no double-count); got %d (%r)" % (s, totals))
PY

# Fire 3: no transcript growth -> delta <= 0 -> NO new record.
env -u PIPELINE_LOGS_ENABLED CLAUDE_PROJECT_DIR="$PROJ2" \
  python3 "$HOOK" <<<"$PAYLOAD2" || fail "case2: fire-3 hook exited non-zero"

COUNT3="$(wc -l < "$OUT2" | tr -d ' ')"
[ "$COUNT3" = "2" ] || fail "case2: no-growth re-fire must write NO record (count stayed at 2), got $COUNT3"

echo "PASS: test-capture-agent-cost-orchestrator.sh"
