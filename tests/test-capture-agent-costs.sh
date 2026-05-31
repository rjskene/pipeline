#!/usr/bin/env bash
# Test: scripts/capture-agent-costs.sh — retroactive agent token-cost parser.
#   - gate behavior (unset/false -> no file; true -> appended)
#   - headless pass (runs.log -> transcript resolve via DOUBLE-dash slug)
#   - missing-transcript skip counter
#   - inline pass (subagents.log -> sidecar usage; non-stage line skipped)
#   - idempotency (re-run adds no duplicate record_key)
#   - #643 schema contract (fields + record_key + tokens.total)
set -uo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/capture-agent-costs.sh"
FIX="$THIS_DIR/fixtures/token-usage"
LIB="$REPO_ROOT/scripts/_token-usage-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[ -f "$SCRIPT" ] || fail "script not found: $SCRIPT"
# shellcheck source=/dev/null
source "$LIB"

# stage a hermetic env: copy fixtures into a temp logs dir + transcript home.
setup_env() {
  local home="$1" proj="$2"
  mkdir -p "$proj/.claude/logs/subagents"
  cp "$FIX/runs.log" "$proj/.claude/logs/runs.log"
  cp "$FIX/subagents.log" "$proj/.claude/logs/subagents.log"
  cp "$FIX"/subagents/*.json "$proj/.claude/logs/subagents/"
  # transcript for the FIRST runs.log line (session sess-aaaa-1111),
  # worktree /home/fix/claude-pipeline/.claude/worktrees/wt-642
  local wt="/home/fix/claude-pipeline/.claude/worktrees/wt-642"
  local slug; slug="$(tu_worktree_slug "$wt")"
  mkdir -p "$home/.claude/projects/$slug"
  cp "$FIX/transcript.jsonl" "$home/.claude/projects/$slug/sess-aaaa-1111.jsonl"
  # the SECOND line (sess-bbbb-2222) transcript is intentionally absent.
}

# ---------------------------------------------------------------------------
# Gate: disabled -> NO output file
# ---------------------------------------------------------------------------
for state in "" "false"; do
  home="$(mktemp -d)"; proj="$(mktemp -d)"
  setup_env "$home" "$proj"
  HOME="$home" CLAUDE_PROJECT_DIR="$proj" PIPELINE_LOGS_ENABLED="$state" \
    bash "$SCRIPT" >/dev/null 2>&1 || true
  out="$proj/.claude/logs/agent-costs.jsonl"
  [ -e "$out" ] && fail "gate [$state]: output file must NOT exist when disabled"
  pass "gate [${state:-unset}]: no output when disabled"
  rm -rf "$home" "$proj"
done

# ---------------------------------------------------------------------------
# Enabled: full parse
# ---------------------------------------------------------------------------
home="$(mktemp -d)"; proj="$(mktemp -d)"
setup_env "$home" "$proj"
out="$proj/.claude/logs/agent-costs.jsonl"

stderr1="$(HOME="$home" CLAUDE_PROJECT_DIR="$proj" PIPELINE_LOGS_ENABLED="true" \
  bash "$SCRIPT" 2>&1 >/dev/null)"

[ -f "$out" ] || fail "enabled: expected output file to exist"
pass "enabled: output file written"

# record count: 1 headless + 8 inline (analyze line skipped) = 9
n="$(wc -l < "$out" | tr -d ' ')"
[ "$n" = "9" ] || fail "expected 9 records, got $n"
pass "enabled: 9 records (1 headless + 8 inline, non-stage skipped)"

# missing-transcript skip counter surfaced on stderr
case "$stderr1" in
  *headless_skipped_missing_transcript*1*) pass "missing-transcript skip counter = 1" ;;
  *) fail "expected headless_skipped_missing_transcript=1 on stderr, got: $stderr1" ;;
esac

# ---------------------------------------------------------------------------
# Field-level assertions via python over the JSONL
# ---------------------------------------------------------------------------
python3 - "$out" <<'PY' || exit 1
import json, sys, hashlib
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by_kind = {}
for r in rows:
    by_kind.setdefault(r["agent_kind"], []).append(r)

# schema contract: required fields present on EVERY row
required = {"schema_version","record_key","issue","stage","agent_kind",
           "agent_type","session_id","model","tokens","duration_ms",
           "ts_start","ts_end","source","usage_complete"}
for r in rows:
    missing = required - set(r)
    assert not missing, "missing fields %s in %r" % (missing, r)
    assert r["schema_version"] == 1, "schema_version must be 1"
    assert set(r["tokens"]) == {"input","output","cache_read","cache_creation","total"}, \
        "tokens shape: %r" % r["tokens"]
    t = r["tokens"]
    assert t["total"] == t["input"]+t["output"]+t["cache_read"]+t["cache_creation"], \
        "tokens.total mismatch: %r" % r
    assert r["source"] == "retroactive", "source must be retroactive"

# headless row
hl = by_kind["headless"]
assert len(hl) == 1, "expected 1 headless row, got %d" % len(hl)
h = hl[0]
assert h["stage"] == "execute", "headless stage: %r" % h["stage"]
assert str(h["issue"]) == "642", "headless issue: %r" % h["issue"]
assert h["agent_type"] == "skill", "headless agent_type: %r" % h["agent_type"]
assert h["model"] == "claude-opus-4-8", "headless model (runs.log wins): %r" % h["model"]
assert h["usage_complete"] is True, "headless usage_complete must be true"
assert h["session_id"] == "sess-aaaa-1111", "headless session_id: %r" % h["session_id"]
ht = h["tokens"]
assert (ht["input"],ht["output"],ht["cache_read"],ht["cache_creation"]) == (350,70,16,5), \
    "headless token sums: %r" % ht
assert ht["total"] == 441, "headless total: %r" % ht["total"]
assert h["ts_start"] == "2026-05-30T10:00:00.000Z", "headless ts_start: %r" % h["ts_start"]
assert h["ts_end"] == "2026-05-30T10:00:09.000Z", "headless ts_end: %r" % h["ts_end"]

# record_key derivation
rk = hashlib.sha1(("%s|%s|%s|%s|%s|%s" % (
    h["source"], h["agent_kind"], h["session_id"], h["issue"],
    h["stage"], h["ts_start"])).encode()).hexdigest()
assert h["record_key"] == rk, "record_key derivation: %r != %r" % (h["record_key"], rk)

# inline rows
il = by_kind["inline"]
assert len(il) == 8, "expected 8 inline rows, got %d" % len(il)
for r in il:
    assert r["usage_complete"] is False, "inline usage_complete must be false: %r" % r
    assert r["session_id"] == "sess-inline", "inline session_id: %r" % r["session_id"]

# stage/issue coverage from inline vocabulary
pairs = sorted((r["stage"], str(r["issue"])) for r in il)
expect = sorted([
    ("classify","310"),
    ("plan","310"),
    ("plan-eval","310"),
    ("plan-eval","134"),
    ("pr-eval","134"),
    ("pr-eval","626"),
    ("plan","310"),        # Re-plan #310
    ("classify","777"),    # Classify + plan + evaluate #777
])
assert pairs == expect, "inline (stage,issue) pairs:\n got %r\n exp %r" % (pairs, expect)

# a sample inline sidecar usage propagated (Classify #310)
c310 = [r for r in il if r["stage"]=="classify" and str(r["issue"])=="310"][0]
ct = c310["tokens"]
assert (ct["input"],ct["output"],ct["cache_read"],ct["cache_creation"]) == (1000,100,10,5), \
    "classify-310 tokens: %r" % ct
assert c310["agent_type"] == "pipeline:issue-classifier", "classify-310 agent_type: %r" % c310["agent_type"]

# non-stage 'analyze' line must NOT appear
assert not any(r.get("agent_type")=="pipeline:issue-analyzer" for r in rows), \
    "non-stage analyze line must be skipped"
print("python field assertions OK")
PY
pass "field + schema + record_key assertions OK"

# ---------------------------------------------------------------------------
# Idempotency: re-run adds NO new records
# ---------------------------------------------------------------------------
HOME="$home" CLAUDE_PROJECT_DIR="$proj" PIPELINE_LOGS_ENABLED="true" \
  bash "$SCRIPT" >/dev/null 2>&1 || true
n2="$(wc -l < "$out" | tr -d ' ')"
[ "$n2" = "9" ] || fail "idempotency: re-run changed record count $n -> $n2"
pass "idempotency: re-run produced no duplicate record_keys"

# unique record_keys
uniq="$(python3 - "$out" <<'PY'
import json,sys
keys=[json.loads(l)["record_key"] for l in open(sys.argv[1]) if l.strip()]
print("DUP" if len(keys)!=len(set(keys)) else "OK")
PY
)"
[ "$uniq" = "OK" ] || fail "duplicate record_keys present after re-run"
pass "all record_keys unique"

rm -rf "$home" "$proj"

# ---------------------------------------------------------------------------
# Worktree-scoped capture: OUTPUT log lands in the MAIN worktree, not the
# linked worktree (which cleanup-worktree.sh prunes). Regression for #697.
# ---------------------------------------------------------------------------
home="$(mktemp -d)"
mainrepo="$(mktemp -d)"
git -C "$mainrepo" init -q
git -C "$mainrepo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
wt="$mainrepo/.claude/worktrees/wt-642-x"
git -C "$mainrepo" worktree add -q "$wt"

# Stage the worker-session input logs INSIDE the linked worktree.
setup_env "$home" "$wt"

# Run the script as the worker session would: CLAUDE_PROJECT_DIR points at the
# linked worktree.
HOME="$home" CLAUDE_PROJECT_DIR="$wt" PIPELINE_LOGS_ENABLED="true" \
  bash "$SCRIPT" >/dev/null 2>&1 || true

main_out="$mainrepo/.claude/logs/agent-costs.jsonl"
wt_out="$wt/.claude/logs/agent-costs.jsonl"

# OUTPUT must land in the MAIN worktree's log.
[ -f "$main_out" ] || fail "worktree: expected output in MAIN log $main_out"
pass "worktree: output written to main log"

# The execute/headless record (stage=execute, session sess-aaaa-1111) is present
# in the MAIN log.
python3 - "$main_out" <<'PY' || fail "worktree: execute record missing from main log"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
hit = [r for r in rows
       if r.get("stage") == "execute"
       and r.get("session_id") == "sess-aaaa-1111"
       and r.get("agent_kind") == "headless"]
assert hit, "execute/headless record not found in main log"
print("execute record present in main log")
PY
pass "worktree: execute record present in main log"

# The linked-worktree log path (pruned by cleanup) must NOT receive the record.
[ ! -f "$wt_out" ] || fail "worktree: output must NOT land in pruned worktree log $wt_out"
pass "worktree: worktree-local log not written"

git -C "$mainrepo" worktree remove "$wt" --force 2>/dev/null || rm -rf "$wt"
rm -rf "$home" "$mainrepo"

echo "all tests passed"
