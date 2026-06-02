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
  # Stage the subagent transcript for the INLINE-pass reconciled-upgrade case:
  # the resolver globs */sess-inline/subagents/agent-<agent_id>.jsonl, so the
  # parent slug here is arbitrary — only the <session>/subagents/agent-<id>.jsonl
  # tail matters. Classify #310 carries agent_id=atx310 in its sidecar.
  mkdir -p "$home/.claude/projects/inline-slug/sess-inline/subagents"
  cp "$FIX/subagents/agent-tx-310.jsonl" \
    "$home/.claude/projects/inline-slug/sess-inline/subagents/agent-atx310.jsonl"
  # All OTHER inline sidecars stage NO transcript -> exercise the lower-bound fallback.
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

# Reconciled-upgrade case: Classify #310 has a staged subagent transcript
# (agent_id=atx310). The INLINE pass transcript-sums it to a cumulative that
# EXCEEDS the sidecar lower-bound (1115), so the row upgrades to usage_complete=true.
# transcript-sum = (500+50+40000+2000) + (600+60+41000+2100) = 86310.
c310 = [r for r in il if r["stage"]=="classify" and str(r["issue"])=="310"][0]
ct = c310["tokens"]
assert (ct["input"],ct["output"],ct["cache_read"],ct["cache_creation"]) == (1100,110,81000,4100), \
    "classify-310 transcript-summed tokens: %r" % ct
assert ct["total"] == 86310, "classify-310 transcript-sum total: %r" % ct["total"]
assert c310["usage_complete"] is True, "classify-310 must upgrade to usage_complete=true"
assert c310["agent_type"] == "pipeline:issue-classifier", "classify-310 agent_type: %r" % c310["agent_type"]
assert c310["model"] == "claude-opus-4-8", "classify-310 model adopted from transcript: %r" % c310["model"]

# Fallback case: Plan #310 has NO staged transcript -> stays at sidecar lower-bound.
p310 = [r for r in il if r["stage"]=="plan" and str(r["issue"])=="310"]
# (two 'plan' rows for 310: Plan #310 + Re-plan #310; both lack a transcript)
for r in p310:
    assert r["usage_complete"] is False, "plan-310 (no transcript) must stay usage_complete=false: %r" % r

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

# ---------------------------------------------------------------------------
# Cross-source reconciliation (#830): a pre-existing usage_complete=true record
# for (session_id, issue, stage) SUPPRESSES the stranded retroactive lower-bound
# the INLINE pass would otherwise append for the SAME tuple (no transcript ->
# usage_complete=false). The complete record is the durable cost signal; the
# stranded lower-bound is the reconciliation leak this fix closes.
#
# Regression guard: a lower-bound whose tuple is NOT covered by any complete
# record MUST still be emitted (usage_complete=false) — the only-signal path is
# preserved; suppression is scoped to covered tuples only.
# ---------------------------------------------------------------------------
home="$(mktemp -d)"; proj="$(mktemp -d)"
mkdir -p "$proj/.claude/logs/subagents"
: > "$proj/.claude/logs/runs.log"   # no headless rows for this scenario

# Two inline agents, both lower-bound only (no staged subagent transcripts):
#   - sess-recon / #820 / execute  -> COVERED by a pre-seeded complete record  -> suppressed
#   - sess-recon / #821 / execute  -> NOT covered                              -> still emitted
{
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "2026-06-01T12:00:00.000Z" "sess-recon" "Execute issue plan for #820" "x" "x" "x" "recon-820.json"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "2026-06-01T12:01:00.000Z" "sess-recon" "Execute issue plan for #821" "x" "x" "x" "recon-821.json"
} > "$proj/.claude/logs/subagents.log"

# Sidecars: final-turn lower-bounds, NO agent_id -> backfill keeps usage_complete=false.
cat > "$proj/.claude/logs/subagents/recon-820.json" <<'JSON'
{"subagent_type":"general-purpose","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":3,"cache_creation_input_tokens":2}}
JSON
cat > "$proj/.claude/logs/subagents/recon-821.json" <<'JSON'
{"subagent_type":"general-purpose","usage":{"input_tokens":11,"output_tokens":6,"cache_read_input_tokens":4,"cache_creation_input_tokens":1}}
JSON

# Pre-seed the OUTPUT log with ONE usage_complete=true record covering
# (sess-recon, 820, execute). The script appends to this file and reads it in
# its idempotency scan, so this on-disk row is the complete sibling the
# reconciliation must learn.
recon_out="$proj/.claude/logs/agent-costs.jsonl"
cat > "$recon_out" <<'JSON'
{"schema_version":1,"record_key":"seed-recon-820-complete","issue":"820","stage":"execute","agent_kind":"inline","agent_type":"general-purpose","session_id":"sess-recon","model":"claude-opus-4-8","tokens":{"input":50000,"output":500,"cache_read":40000,"cache_creation":2000,"total":92500},"duration_ms":0,"ts_start":"2026-06-01T11:00:00.000Z","ts_end":"2026-06-01T11:30:00.000Z","source":"forward","usage_complete":true}
JSON

HOME="$home" CLAUDE_PROJECT_DIR="$proj" PIPELINE_LOGS_ENABLED="true" \
  bash "$SCRIPT" >/dev/null 2>&1 || true

python3 - "$recon_out" <<'PY' || fail "reconciliation (#830) assertions failed"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]

def match(r, issue, complete):
    return (r.get("session_id") == "sess-recon"
            and str(r.get("issue")) == issue
            and r.get("stage") == "execute"
            and r.get("usage_complete") is complete)

# The pre-seeded complete record for #820 survives.
assert any(match(r, "820", True) for r in rows), \
    "pre-seeded complete record for #820 must survive"

# SUPPRESSION: no stranded lower-bound for the COVERED tuple (#820).
stranded820 = [r for r in rows if match(r, "820", False)]
assert not stranded820, \
    "stranded lower-bound for covered (#820) must be suppressed, got %r" % stranded820

# REGRESSION GUARD: the uncovered tuple (#821) lower-bound IS still emitted.
emitted821 = [r for r in rows if match(r, "821", False)]
assert emitted821, \
    "lower-bound for uncovered (#821) must still be emitted (only-signal path)"

print("reconciliation (#830) assertions OK")
PY
pass "reconciliation (#830): complete record suppresses stranded lower-bound; uncovered lower-bound preserved"

rm -rf "$home" "$proj"

echo "all tests passed"
