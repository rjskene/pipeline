#!/usr/bin/env bash
# test-capture-agent-cost-hook.sh — contract test for the forward
# SubagentStop/Stop cost-capture hook (hooks/capture_agent_cost.py).
#
# The hook is the DURABLE, ACCURATE forward cost source. It must:
#   1. write NOTHING when PIPELINE_LOGS_ENABLED is unset or != "true"
#   2. emit exactly one schema_version=1 forward record for a pipeline
#      description carrying a usage block
#   3. skip non-stage descriptions (no record)
#   3b. attribute a PATH C leaf description (target=<dir> + #N) (#1299)
#   4. fail open when no usage field is present (no record, exit 0)
#   6. dedupe transcript usage by message.id on the Stop branch (#1443)
#   7. stamp turns/ctx_first/ctx_last on an inline record that ADOPTS the
#      durable subagent transcript (#1443)
#   8. resync a pre-#1443 orchestrator state baseline instead of wedging the
#      session, then emit a correct per-fire delta (turns is a DELTA) (#1443)
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

expect(rec["schema_version"] == 2, "schema_version==2")
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
# Case 3b (#1299): a PATH C leaf description (target=<dir> plus an issue number)
# DOES produce a record. Mirror of case 3 with the opposite verdict: today the
# hook's stage_from_description returns "" for this shape, the payload is
# skipped, and every leaf's cost vanishes from that issue's row.
# ---------------------------------------------------------------------------
PAYLOAD_TARGET='{
  "session_id": "sess-leaf",
  "subagent_type": "pipeline:tdd-implementer",
  "description": "target=scripts/ trust-profile resolvers (#1291 T1)",
  "total_duration_ms": 2600,
  "usage": {
    "input_tokens": 2600,
    "output_tokens": 180,
    "cache_read_input_tokens": 15,
    "cache_creation_input_tokens": 5
  }
}'
run_hook "$PAYLOAD_TARGET" || fail "case3b: hook exited non-zero"
COUNT="$(wc -l < "$OUT" | tr -d ' ')"
[ "$COUNT" = "2" ] || fail "case3b: target= description produced no record (count=$COUNT, want 2)"

python3 - "$OUT" <<'PY' || fail "case3b: target= record failed assertions"
import json, sys
with open(sys.argv[1]) as fh:
    rec = json.loads(fh.readlines()[-1])

def expect(cond, msg):
    if not cond:
        raise SystemExit("assert failed: %s (rec=%r)" % (msg, rec))

expect(rec["stage"] == "execute", "stage==execute")
expect(str(rec["issue"]) == "1291", "issue==1291")
expect(rec["session_id"] == "sess-leaf", "session_id==sess-leaf")
PY

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
[ "$COUNT" = "2" ] || fail "case4: missing usage produced a record (count=$COUNT)"

[ -s "$ERRLOG" ] && fail "case4: error log non-empty: $(cat "$ERRLOG")"

# ---------------------------------------------------------------------------
# Case 5 (#765): a cumulative-source payload (usage under `total_usage`, no
# top-level `usage`) stays usage_complete=true. Forward-compatible: if a future
# harness populates total_usage/cumulative_usage, those records are correctly
# trustworthy totals — the flag tracks provenance, not a hard-coded value.
# ---------------------------------------------------------------------------
PAYLOAD_CUMULATIVE='{
  "session_id": "sess-cum",
  "subagent_type": "pr-eval-agent",
  "description": "Evaluate PR #300 for #299",
  "total_duration_ms": 1000,
  "total_usage": {
    "input_tokens": 50,
    "output_tokens": 10,
    "cache_read_input_tokens": 2,
    "cache_creation_input_tokens": 1
  }
}'
run_hook "$PAYLOAD_CUMULATIVE" || fail "case5: hook exited non-zero"
COUNT="$(wc -l < "$OUT" | tr -d ' ')"
[ "$COUNT" = "3" ] || fail "case5: expected 3 records (case2 + case3b + case5), got $COUNT"

python3 - "$OUT" <<'PY' || fail "case5: cumulative-source record failed assertions"
import json, sys
with open(sys.argv[1]) as fh:
    rec = json.loads(fh.readlines()[-1])

def expect(cond, msg):
    if not cond:
        raise SystemExit("assert failed: %s (rec=%r)" % (msg, rec))

expect(rec["usage_complete"] is True, "cumulative-source usage_complete==true")
expect(rec["tokens"]["total"] == 63, "tokens.total == 50+10+2+1")
PY

# ---------------------------------------------------------------------------
# Case 6 (#1443): Stop-branch transcript summing DEDUPES by message.id. Claude
# Code writes one API response as 2-3 assistant lines sharing message.id;
# input/cache_read/cache_creation repeat verbatim and output_tokens is
# progressive, so per-line summing inflated the input side ~2x. The shared
# msgid fixture is msg_A x3 (output 5/40/90) + msg_B + msg_C: deduped
# 60/106/6000/300 vs a naive per-line 80/151/8000/500. tokens.total is the
# orchestrator WORK-TOTAL (input+output+cache_creation, cache_read excluded).
# APPENDED after Case 5 on purpose: the cumulative `wc -l` assertions above
# would all drift if a new record were inserted earlier.
# ---------------------------------------------------------------------------
cp "$REPO_ROOT/tests/fixtures/token-usage/transcript-msgid.jsonl" \
  "$WORK/transcript-msgid.jsonl"
PAYLOAD_STOP_DEDUPE="$(printf '{"session_id":"stop-dedupe","transcript_path":"%s"}' \
  "$WORK/transcript-msgid.jsonl")"
run_hook "$PAYLOAD_STOP_DEDUPE" || fail "case6: hook exited non-zero"
COUNT="$(wc -l < "$OUT" | tr -d ' ')"
[ "$COUNT" = "4" ] || fail "case6: expected 4 records, got $COUNT"

python3 - "$OUT" <<'PY' || fail "case6: msgid-dedupe Stop record failed assertions"
import json, sys
with open(sys.argv[1]) as fh:
    rec = json.loads(fh.readlines()[-1])

def expect(cond, msg):
    if not cond:
        raise SystemExit("assert failed: %s (rec=%r)" % (msg, rec))

expect(rec["stage"] == "orchestrator", "stage==orchestrator")
expect(rec["agent_kind"] == "main", "agent_kind==main")
expect(rec["session_id"] == "stop-dedupe", "session_id==stop-dedupe")
t = rec["tokens"]
expect(t["input"] == 60, "tokens.input deduped to 60 (naive 80)")
expect(t["output"] == 106, "tokens.output is the per-id max sum 106 (naive 151)")
expect(t["cache_read"] == 6000, "tokens.cache_read deduped to 6000 (naive 8000)")
expect(t["cache_creation"] == 300, "tokens.cache_creation deduped to 300 (naive 500)")
expect(t["total"] == 466, "work-total 60+106+300 (cache_read excluded)")
expect(rec["schema_version"] == 2, "schema_version==2")
# turns is a per-fire DELTA on the orchestrator record (mirroring the token
# delta); this is session stop-dedupe's FIRST fire, so the delta IS the
# absolute 3. ctx_first/ctx_last are absolute transcript bounds, never deltas.
expect(rec["turns"] == 3, "turns==3 (3 distinct message ids)")
expect(rec["ctx_first"] == 1100, "ctx_first==1100 (msg_A cache_read+creation)")
expect(rec["ctx_last"] == 3000, "ctx_last==3000 (msg_C cache_read+creation)")
PY

# ---------------------------------------------------------------------------
# Case 7 (#1443): an INLINE record that adopts the durable subagent transcript
# carries turns/ctx_first/ctx_last from that transcript. The payload needs a
# stage-resolving `description` -- without one stage_from_description returns ""
# and build_record returns None, so NO record would be written and the
# turns/ctx assertions would fail for an incidental reason. The `usage` block is
# a deliberately tiny final-turn lower-bound so the transcript sum EXCEEDS it
# and is adopted (usage_complete flips to true).
# ---------------------------------------------------------------------------
mkdir -p "$HOME/.claude/projects/any-slug/sess-adopt/subagents"
cp "$REPO_ROOT/tests/fixtures/token-usage/transcript-msgid.jsonl" \
  "$HOME/.claude/projects/any-slug/sess-adopt/subagents/agent-aid1.jsonl"
PAYLOAD_ADOPT='{
  "session_id": "sess-adopt",
  "agent_id": "aid1",
  "subagent_type": "general-purpose",
  "description": "Evaluate PR #1443 for #1443",
  "total_duration_ms": 1500,
  "usage": {
    "input_tokens": 1,
    "output_tokens": 1,
    "cache_read_input_tokens": 0,
    "cache_creation_input_tokens": 0
  }
}'
run_hook "$PAYLOAD_ADOPT" || fail "case7: hook exited non-zero"
COUNT="$(wc -l < "$OUT" | tr -d ' ')"
[ "$COUNT" = "5" ] || fail "case7: expected 5 records, got $COUNT"

python3 - "$OUT" <<'PY' || fail "case7: inline-adopt record failed assertions"
import json, sys
with open(sys.argv[1]) as fh:
    rec = json.loads(fh.readlines()[-1])

def expect(cond, msg):
    if not cond:
        raise SystemExit("assert failed: %s (rec=%r)" % (msg, rec))

expect(rec["agent_kind"] == "inline", "agent_kind==inline")
expect(rec["session_id"] == "sess-adopt", "session_id==sess-adopt")
expect(rec["schema_version"] == 2, "schema_version==2")
expect(rec["usage_complete"] is True, "transcript sum exceeded the lower-bound")
t = rec["tokens"]
expect((t["input"], t["output"], t["cache_read"], t["cache_creation"])
       == (60, 106, 6000, 300), "adopted deduped buckets")
expect(t["total"] == 6466, "inline total includes cache_read")
expect(rec["turns"] == 3, "turns==3 from the resolved subagent transcript")
expect(rec["ctx_first"] == 1100, "ctx_first==1100")
expect(rec["ctx_last"] == 3000, "ctx_last==3000")
PY

# ---------------------------------------------------------------------------
# Case 8 (#1443): the orchestrator state sidecar carries a PRE-#1443 baseline
# written by the old per-LINE summing, so it is ~2x high. The deduped
# cumulative is now BELOW it, every token delta goes negative, and the
# work-total <= 0 guard returns BEFORE _save_state -- which would wedge the
# session on the stale baseline forever (every later fire recomputing the same
# negative delta). The fire must RESYNC the baseline and emit nothing; the NEXT
# fire must then measure a correct delta. That second fire also pins `turns` as
# a DELTA (1), not the raw cumulative (4) -- the #668 mistake.
# ---------------------------------------------------------------------------
STATE="$CLAUDE_PROJECT_DIR/.claude/logs/agent-cost-orchestrator-state.json"
python3 - "$STATE" <<'PY' || fail "case8: could not seed the v1 state sidecar"
import json, os, sys
path = sys.argv[1]
try:
    state = json.load(open(path))
except (OSError, ValueError):
    state = {}
# the NAIVE per-line sums of transcript-msgid.jsonl (what v1 would have left)
state["stop-v1mig"] = {"input": 80, "output": 151, "cache_read": 8000,
                       "cache_creation": 500, "model": "claude-opus-4-8"}
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump(state, open(path, "w"))
PY

PAYLOAD_V1MIG="$(printf '{"session_id":"stop-v1mig","transcript_path":"%s"}' \
  "$WORK/transcript-msgid.jsonl")"
run_hook "$PAYLOAD_V1MIG" || fail "case8: hook exited non-zero"
COUNT="$(wc -l < "$OUT" | tr -d ' ')"
[ "$COUNT" = "5" ] || fail "case8: resync fire must emit NO record (count=$COUNT, want 5)"

python3 - "$STATE" <<'PY' || fail "case8: baseline was NOT resynced (session wedged)"
import json, sys
entry = json.load(open(sys.argv[1]))["stop-v1mig"]

def expect(cond, msg):
    if not cond:
        raise SystemExit("assert failed: %s (entry=%r)" % (msg, entry))

expect(entry["input"] == 60, "baseline input resynced to the deduped 60")
expect(entry["output"] == 106, "baseline output resynced to 106")
expect(entry["cache_read"] == 6000, "baseline cache_read resynced to 6000")
expect(entry["cache_creation"] == 300, "baseline cache_creation resynced to 300")
expect(entry["turns"] == 3, "baseline turns persisted as the cumulative 3")
expect(entry["model"] == "claude-opus-4-8", "model carried forward")
PY

# Second fire: the transcript GREW by one more API response (msg_D). The delta
# is now measured against the resynced baseline.
cp "$WORK/transcript-msgid.jsonl" "$WORK/transcript-msgid-grown.jsonl"
cat >> "$WORK/transcript-msgid-grown.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-06-01T10:00:05.000Z","message":{"id":"msg_D","usage":{"input_tokens":40,"output_tokens":50,"cache_read_input_tokens":4000,"cache_creation_input_tokens":0}}}
JSONL
PAYLOAD_V1MIG2="$(printf '{"session_id":"stop-v1mig","transcript_path":"%s"}' \
  "$WORK/transcript-msgid-grown.jsonl")"
run_hook "$PAYLOAD_V1MIG2" || fail "case8b: hook exited non-zero"
COUNT="$(wc -l < "$OUT" | tr -d ' ')"
[ "$COUNT" = "6" ] || fail "case8b: expected 6 records, got $COUNT"

python3 - "$OUT" <<'PY' || fail "case8b: post-resync delta record failed assertions"
import json, sys
with open(sys.argv[1]) as fh:
    rec = json.loads(fh.readlines()[-1])

def expect(cond, msg):
    if not cond:
        raise SystemExit("assert failed: %s (rec=%r)" % (msg, rec))

expect(rec["session_id"] == "stop-v1mig", "session_id==stop-v1mig")
t = rec["tokens"]
expect((t["input"], t["output"], t["cache_read"], t["cache_creation"])
       == (40, 50, 4000, 0), "msg_D delta only")
expect(t["total"] == 90, "work-total 40+50+0")
# turns is a DELTA: the cumulative is 4, the previous fire persisted 3.
expect(rec["turns"] == 1, "turns is the DELTA 1, not the cumulative 4")
expect(rec["ctx_first"] == 1100, "ctx_first stays absolute (1100)")
expect(rec["ctx_last"] == 4000, "ctx_last is absolute and advanced to 4000")
PY

echo "PASS: test-capture-agent-cost-hook.sh"
