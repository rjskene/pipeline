#!/usr/bin/env bash
# test-subagent-log-result-capture.sh — #1233 capture-fix regression guard.
#
# hooks/log_subagent.py sources the leaf's returned text from
# `tool_response.get("result", "")`, but the real PostToolUse(Agent) payload has
# NO `result` key: the leaf's return lives in `tool_response["content"]` as a
# list of {"type":"text","text": ...} blocks (status == "completed"), or is
# never delivered at all (status == "async_launched", the background-dispatch
# shape). So every per-agent JSON record on disk carries `result: ""` and the
# consolidated subagents.log result-chars column is 0 — which makes the #1233
# CAPABILITY-REFUSED detector blind by construction.
#
# The fix adds extract_result_text(tool_response) to hooks/subagent_log_utils.py
# (join the text of every text block in `content`; fall back to the legacy
# `result` key) and records the payload `status` so `async_launched` is
# mechanically distinguishable from "the leaf returned nothing".
#
# Same payload-shape drift class as #663 (duration_ms moved to the top level)
# and #660 (capture_agent_cost.py._normalize_payload).
#
# Hermetic: self-contained fixture project dirs under mktemp -d; NEVER reads the
# live .claude/logs/.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/log_subagent.py"
UTILS="$REPO_ROOT/hooks/subagent_log_utils.py"

FAILED=0

fail() { echo "  FAIL: $*"; FAILED=$((FAILED + 1)); }
pass() { echo "  PASS: $*"; }

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$name -> $actual"
  else
    fail "$name expected='$expected' actual='$actual'"
  fi
}

if [ ! -f "$HOOK" ]; then
  echo "FAIL: $HOOK does not exist"
  exit 1
fi
if [ ! -f "$UTILS" ]; then
  echo "FAIL: $UTILS does not exist"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Assemble the sentinel at runtime so this test file is never itself a
# false-positive for a repo-wide scan of the token (precedent:
# scripts/check-cross-cutting-guards.sh:121 FIXTURE_TOKEN).
SENT="CAPABILITY-""REFUSED:"

# RESULT_MAX_CHARS lives in hooks/subagent_log_utils.py; read it rather than
# hard-coding so case (f) tracks the source of truth.
RESULT_MAX_CHARS="$(python3 - "$UTILS" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'^RESULT_MAX_CHARS\s*=\s*(\d+)', src, re.M)
print(m.group(1) if m else 8192)
PY
)"

# run_hook <case-name> — reads the payload JSON on stdin, runs the REAL hook
# against a fresh fixture project, and exports:
#   HOOK_RC   — the hook's exit code (must be 0: fail-open contract)
#   JSON_FILE — the per-agent JSON record it wrote (empty if none)
#   LOG_FILE  — the consolidated subagents.log (empty if none)
run_hook() {
  local case_name="$1"
  local proj="$TMP/proj-$case_name"
  mkdir -p "$proj/.claude/logs"

  env -u PIPELINE_LOGS_ENABLED CLAUDE_PROJECT_DIR="$proj" python3 "$HOOK"
  HOOK_RC=$?

  JSON_FILE="$(ls -1 "$proj/.claude/logs/subagents"/*.json 2>/dev/null | head -1)"
  LOG_FILE="$proj/.claude/logs/subagents.log"
  [ -f "$LOG_FILE" ] || LOG_FILE=""
}

# jq-free field read (the hook writes with json.dump, so python is the most
# faithful reader). Prints the repr-free value; empty string when absent.
rec_field() {
  local file="$1" key="$2"
  [ -n "$file" ] && [ -f "$file" ] || { printf ''; return 0; }
  KEY="$key" python3 - "$file" <<'PY'
import json, os, sys
with open(sys.argv[1]) as fh:
    rec = json.load(fh)
val = rec.get(os.environ["KEY"], "")
if isinstance(val, bool):
    print("true" if val else "false")
elif val is None:
    print("")
else:
    print(val, end="")
PY
}

# ---------------------------------------------------------------------------
# Real-shape payload: content blocks, NO `result` key (status == completed).
# ---------------------------------------------------------------------------
REAL_PAYLOAD="$(SENT="$SENT" python3 - <<'PY'
import json, os
sent = os.environ["SENT"]
text = "tests added: tests/foo.sh\n%s invoke superpowers:requesting-code-review - no Skill tool" % sent
print(json.dumps({
    "tool_name": "Agent",
    "session_id": "s1",
    "duration_ms": 56856,
    "tool_input": {"description": "execute 1233 path b", "subagent_type": "tdd-implementer"},
    "tool_response": {
        "status": "completed",
        "agentId": "abcd1234ef",
        "agentType": "general-purpose",
        "content": [{"type": "text", "text": text}],
        "usage": {
            "input_tokens": 10,
            "output_tokens": 20,
            "cache_read_input_tokens": 30,
            "cache_creation_input_tokens": 40,
        },
        "totalTokens": 40145,
        "totalDurationMs": 56856,
        "totalToolUseCount": 8,
    },
}))
PY
)"

echo "=== (a)(b)(c) real-shape PostToolUse payload (content blocks, no result key) ==="
run_hook abc <<<"$REAL_PAYLOAD"
check "(a) hook exits 0 on the real-shape payload" "0" "$HOOK_RC"
if [ -z "$JSON_FILE" ]; then
  fail "(a) no per-agent JSON record written"
  fail "(b) no per-agent JSON record written"
else
  A_RESULT="$(rec_field "$JSON_FILE" result)"
  if [ -n "$A_RESULT" ]; then
    pass "(a) .result is non-empty"
  else
    fail "(a) expected non-empty .result, got ''"
  fi
  case "$A_RESULT" in
    *"$SENT"*) pass "(a) .result carries the leaf's returned sentinel text" ;;
    *) fail "(a) .result does not contain the sentinel text; got '$A_RESULT'" ;;
  esac
  check "(b) .status is recorded from the payload" "completed" "$(rec_field "$JSON_FILE" status)"
fi

if [ -z "$LOG_FILE" ]; then
  fail "(c) subagents.log not written"
else
  C_COL="$(awk -F'\t' 'NR==1{print $4}' "$LOG_FILE")"
  if [ -n "$C_COL" ] && [ "$C_COL" -gt 0 ] 2>/dev/null; then
    pass "(c) subagents.log result-chars column is > 0 ($C_COL)"
  else
    fail "(c) subagents.log result-chars column expected > 0, got '$C_COL'"
  fi
fi

echo "=== (d) back-compat: legacy synthetic result-key shape, no content ==="
LEGACY_PAYLOAD='{
  "tool_name": "Agent",
  "session_id": "s1",
  "duration_ms": 1344,
  "tool_input": {"description": "plan-issue 663", "subagent_type": "general-purpose"},
  "tool_response": {
    "result": "done",
    "usage": {"input_tokens": 10, "output_tokens": 20,
              "cache_read_input_tokens": 30, "cache_creation_input_tokens": 40},
    "total_tokens": 100,
    "total_duration_ms": null,
    "num_turns": 3,
    "agentId": "abcd1234ef"
  }
}'
run_hook d <<<"$LEGACY_PAYLOAD"
check "(d) hook exits 0 on the legacy shape" "0" "$HOOK_RC"
if [ -z "$JSON_FILE" ]; then
  fail "(d) no per-agent JSON record written"
else
  check "(d) legacy .result fallback preserved" "done" "$(rec_field "$JSON_FILE" result)"
fi

echo "=== (e) async_launched hole is RECORDED, not faked ==="
ASYNC_PAYLOAD='{
  "tool_name": "Agent",
  "session_id": "s1",
  "duration_ms": 12,
  "tool_input": {"description": "execute 1233 path b", "subagent_type": "tdd-implementer"},
  "tool_response": {
    "status": "async_launched",
    "agentId": "a1",
    "outputFile": "/tmp/nope.output",
    "canReadOutputFile": true,
    "prompt": "do the thing"
  }
}'
run_hook e <<<"$ASYNC_PAYLOAD"
check "(e) hook exits 0 on the async_launched shape" "0" "$HOOK_RC"
if [ -z "$JSON_FILE" ]; then
  fail "(e) no per-agent JSON record written"
else
  check "(e) .result is empty (the result never reaches this hook)" "" "$(rec_field "$JSON_FILE" result)"
  check "(e) .status records the async hole" "async_launched" "$(rec_field "$JSON_FILE" status)"
fi

echo "=== (f) robustness: non-text block skipped + oversize text truncated ==="
BIG_PAYLOAD="$(MAXC="$RESULT_MAX_CHARS" python3 - <<'PY'
import json, os
big = "x" * (int(os.environ["MAXC"]) + 100)
print(json.dumps({
    "tool_name": "Agent",
    "session_id": "s1",
    "duration_ms": 99,
    "tool_input": {"description": "execute 1233 path b", "subagent_type": "tdd-implementer"},
    "tool_response": {
        "status": "completed",
        "agentId": "abcd1234ef",
        "content": [
            {"type": "image", "source": {}},
            {"type": "text", "text": big},
        ],
    },
}))
PY
)"
run_hook f <<<"$BIG_PAYLOAD"
check "(f) hook exits 0 with a non-text content block present" "0" "$HOOK_RC"
if [ -z "$JSON_FILE" ]; then
  fail "(f) no per-agent JSON record written"
else
  check "(f) oversize leaf text sets .result_truncated" "true" "$(rec_field "$JSON_FILE" result_truncated)"
  F_RESULT="$(rec_field "$JSON_FILE" result)"
  case "$F_RESULT" in
    x*) pass "(f) non-text block skipped; text block captured" ;;
    *) fail "(f) expected the text block's content, got '${F_RESULT:0:40}'" ;;
  esac
fi

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: all checks passed"
