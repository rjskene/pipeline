#!/usr/bin/env bash
# test-capture-agent-cost-config-gate.sh — #657 regression guard.
#
# PIPELINE_LOGS_ENABLED lives in pipeline.config (a bash-sourced file) and is
# NEVER exported into the Claude Code process environment. So the forward
# cost-capture hook (hooks/capture_agent_cost.py) early-returns every time and
# never writes .claude/logs/agent-costs.jsonl.
#
# The hook MUST resolve the flag from the process env FIRST, then fall back to
# reading PIPELINE_LOGS_ENABLED from pipeline.config at the resolved project
# dir. Enabled only when the resolved value is exactly "true".
#
# Hermetic: self-contained fixture project dir with its own pipeline.config;
# never touches the live (gitignored, host-specific) repo pipeline.config.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/capture_agent_cost.py"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$HOOK" ] || fail "hook not found: $HOOK"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PAYLOAD='{
  "session_id": "sess-657",
  "subagent_type": "pipeline:plan-issue",
  "description": "plan-issue #656",
  "total_duration_ms": 12345,
  "usage": {
    "input_tokens": 1000,
    "output_tokens": 200,
    "cache_read_input_tokens": 50,
    "cache_creation_input_tokens": 30
  }
}'

# Build a throwaway project dir whose pipeline.config sets the flag to $1.
# Returns the project dir path on stdout.
make_project() {
  local flag_value="$1"
  local proj="$WORK/proj-$flag_value-$RANDOM"
  mkdir -p "$proj/.claude/logs"
  cat > "$proj/pipeline.config" <<CFG
# host-specific pipeline config (fixture)
PIPELINE_BASE_BRANCH=staging
# comment line should be ignored
PIPELINE_LOGS_ENABLED=$flag_value
SOME_OTHER_VAR="quoted value"
CFG
  printf '%s' "$proj"
}

# ---------------------------------------------------------------------------
# Regression case: env UNSET, config says PIPELINE_LOGS_ENABLED=true.
# Today the hook writes nothing (env gate fails). It MUST write one record.
# ---------------------------------------------------------------------------
PROJ_TRUE="$(make_project true)"
OUT_TRUE="$PROJ_TRUE/.claude/logs/agent-costs.jsonl"

env -u PIPELINE_LOGS_ENABLED CLAUDE_PROJECT_DIR="$PROJ_TRUE" \
  python3 "$HOOK" <<<"$PAYLOAD" \
  || fail "config-true: hook exited non-zero"

[ -f "$OUT_TRUE" ] \
  || fail "config-true: agent-costs.jsonl NOT written (env-unset, config=true)"

COUNT="$(wc -l < "$OUT_TRUE" | tr -d ' ')"
[ "$COUNT" = "1" ] || fail "config-true: expected exactly 1 record, got $COUNT"

python3 - "$OUT_TRUE" <<'PY' || fail "config-true: record failed schema assertions"
import json, sys
with open(sys.argv[1]) as fh:
    rec = json.loads(fh.readline())

def expect(cond, msg):
    if not cond:
        raise SystemExit("assert failed: %s (rec=%r)" % (msg, rec))

expect(rec["stage"] == "plan", "stage==plan")
expect(rec["issue"] == "656", "issue==656")
expect(rec["source"] == "forward", "source==forward")
t = rec["tokens"]
expect(t["total"] == 1000 + 200 + 50 + 30, "tokens.total == sum of four")
PY

# ---------------------------------------------------------------------------
# Negative case: env UNSET, config says PIPELINE_LOGS_ENABLED=false.
# No file may be written.
# ---------------------------------------------------------------------------
PROJ_FALSE="$(make_project false)"
OUT_FALSE="$PROJ_FALSE/.claude/logs/agent-costs.jsonl"

env -u PIPELINE_LOGS_ENABLED CLAUDE_PROJECT_DIR="$PROJ_FALSE" \
  python3 "$HOOK" <<<"$PAYLOAD" \
  || fail "config-false: hook exited non-zero"

[ -f "$OUT_FALSE" ] \
  && fail "config-false: agent-costs.jsonl written despite config=false"

echo "PASS: test-capture-agent-cost-config-gate.sh"
