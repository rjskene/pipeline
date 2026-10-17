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

# record count: 1 headless + 13 inline (analyze line skipped; +2 split-role
# RED/GREEN execute lines for #899; +3 #1299 lines: one PATH C target= leaf and
# two orchestrator code-review dispatches) = 14
n="$(wc -l < "$out" | tr -d ' ')"
[ "$n" = "14" ] || fail "expected 14 records, got $n"
pass "enabled: 14 records (1 headless + 13 inline, non-stage skipped)"

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
           "ts_start","ts_end","source","usage_complete",
           "turns","ctx_first","ctx_last"}
for r in rows:
    missing = required - set(r)
    assert not missing, "missing fields %s in %r" % (missing, r)
    assert r["schema_version"] == 2, "schema_version must be 2 (#1443)"
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
assert len(il) == 13, "expected 13 inline rows, got %d" % len(il)
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
    ("execute","899"),     # split-role RED #899  -> own execute record
    ("execute","899"),     # split-role GREEN #899 -> own execute record
    ("execute","1291"),    # #1299 PATH C leaf: target=scripts/ ... (#1291 T1)
    ("pr-eval","1291"),    # #1299 orchestrator review: Review code changes #1291
    ("pr-eval","1292"),    # #1299 orchestrator review: code review #1292
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

# ---------------------------------------------------------------------------
# split-role role attribution (#1098): the two split-role execute lines for
# #899 each become their OWN execute record, tagged role=red / role=green; the
# RED record's model falls back to opus when its sidecar resolves no model.
# Every OTHER record (non-split execute, classify/plan/eval stages, headless)
# is role=single.
# ---------------------------------------------------------------------------
# Every emitted record carries a 'role' field.
for r in rows:
    assert "role" in r, "record missing 'role' field: %r" % r
    assert r["role"] in ("red","green","single","review"), "role taxonomy: %r" % r["role"]

# The two #899 execute records are the split-role pair.
e899 = [r for r in il if r["stage"]=="execute" and str(r["issue"])=="899"]
assert len(e899) == 2, "expected 2 execute records for #899, got %d" % len(e899)

red899 = [r for r in e899 if r["role"]=="red"]
green899 = [r for r in e899 if r["role"]=="green"]
assert len(red899) == 1, "expected exactly 1 role=red #899 record, got %d" % len(red899)
assert len(green899) == 1, "expected exactly 1 role=green #899 record, got %d" % len(green899)

# RED's model falls back to opus when the sidecar/transcript resolves none.
assert "opus" in red899[0]["model"], \
    "split-role RED model must contain 'opus' (opus-red fallback), got %r" % red899[0]["model"]

# GREEN is NOT forced to opus by the fallback (sidecar resolved no model -> "").
assert "opus" not in green899[0]["model"], \
    "split-role GREEN must NOT inherit the opus-red fallback, got %r" % green899[0]["model"]

# Two distinct records (the fix tags, it does not collapse).
assert red899[0]["record_key"] != green899[0]["record_key"], \
    "split-role RED/GREEN must be two distinct records"

# --- #1299: PATH C leaf + orchestrator closing-review attribution ----------
# The three new fixture lines each produce EXACTLY ONE record:
#   target=scripts/ ... (#1291 T1)  -> stage=execute, issue=1291, role=single
#   Review code changes #1291       -> stage=pr-eval, issue=1291, role=review
#   code review #1292               -> stage=pr-eval, issue=1292, role=review
leaf1291 = [r for r in il if r["stage"]=="execute" and str(r["issue"])=="1291"]
assert len(leaf1291) == 1, \
    "expected exactly 1 execute record for the #1291 target= leaf, got %d" % len(leaf1291)
assert leaf1291[0]["role"] == "single", \
    "PATH C leaf must be role=single (not a split-role half): %r" % leaf1291[0]["role"]
assert leaf1291[0]["usage_complete"] is False, \
    "leaf #1291 has no staged transcript -> must stay a lower-bound: %r" % leaf1291[0]

REVIEW_TUPLES = {("pr-eval","1291"), ("pr-eval","1292")}
for stage, issue in sorted(REVIEW_TUPLES):
    rev = [r for r in il
           if r["stage"] == stage and str(r["issue"]) == issue and r["role"] == "review"]
    assert len(rev) == 1, \
        "expected exactly 1 role=review record for (%s,%s), got %d" % (stage, issue, len(rev))

# Every NON-split, NON-review record is role=single (headless + all the
# classify/plan/eval inline rows + the PATH C leaf).
non_split = [r for r in rows
             if not (r["stage"]=="execute" and str(r["issue"])=="899")
             and (r["stage"], str(r["issue"])) not in REVIEW_TUPLES]
assert non_split, "expected some non-split records"
for r in non_split:
    assert r["role"] == "single", \
        "non-split record must be role=single: stage=%r issue=%r role=%r" % (r["stage"], r["issue"], r["role"])

print("python field assertions OK")
PY
pass "field + schema + record_key assertions OK"

# ---------------------------------------------------------------------------
# Shared bash helper mirror (#1098): tu_role_from_description parses the same
# split-role regex as the inline python, parallel to tu_stage_from_description
# / tu_issue_from_description.
# ---------------------------------------------------------------------------
type tu_role_from_description >/dev/null 2>&1 \
  || fail "tu_role_from_description helper not defined in _token-usage-lib.sh"
[ "$(tu_role_from_description 'execute-issue-plan #899 split-role RED (PATH B inline)')" = "red" ] \
  || fail "tu_role_from_description: split-role RED -> red"
[ "$(tu_role_from_description 'execute-issue-plan #899 split-role GREEN (PATH B inline)')" = "green" ] \
  || fail "tu_role_from_description: split-role GREEN -> green"
[ "$(tu_role_from_description 'some split role red space-variant lowercase')" = "red" ] \
  || fail "tu_role_from_description: case-insensitive + space variant -> red"
[ "$(tu_role_from_description 'Execute issue plan for #642')" = "single" ] \
  || fail "tu_role_from_description: non-split description -> single"
pass "tu_role_from_description helper mirrors the split-role regex"

# ---------------------------------------------------------------------------
# Idempotency: re-run adds NO new records
# ---------------------------------------------------------------------------
HOME="$home" CLAUDE_PROJECT_DIR="$proj" PIPELINE_LOGS_ENABLED="true" \
  bash "$SCRIPT" >/dev/null 2>&1 || true
n2="$(wc -l < "$out" | tr -d ' ')"
[ "$n2" = "14" ] || fail "idempotency: re-run changed record count $n -> $n2"
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
# #1469: plan-first word order ("Plan-eval #N") attributes to plan-eval, not
# plan; bare "Plan #N" still resolves to plan. Mirrors test-token-usage-lib.sh.
# ---------------------------------------------------------------------------
home="$(mktemp -d)"; proj="$(mktemp -d)"
mkdir -p "$proj/.claude/logs/subagents"
: > "$proj/.claude/logs/runs.log"
{
  i=0
  for d in "Plan-eval #220" "plan eval #1" "Plan evaluation for #3" "Plan #221"; do
    i=$((i+1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "2026-06-02T12:0$i:00.000Z" "sess-pe" "$d" "x" "x" "x" "pe-$i.json"
    printf '{"subagent_type":"general-purpose","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n' \
      > "$proj/.claude/logs/subagents/pe-$i.json"
  done
} > "$proj/.claude/logs/subagents.log"
HOME="$home" CLAUDE_PROJECT_DIR="$proj" PIPELINE_LOGS_ENABLED="true" \
  bash "$SCRIPT" >/dev/null 2>&1 || true
python3 - "$proj/.claude/logs/agent-costs.jsonl" <<'PY' || fail "plan-eval word order (#1469) assertions failed"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
got = sorted((str(r["issue"]), r["stage"]) for r in rows)
exp = sorted([("220","plan-eval"),("1","plan-eval"),("3","plan-eval"),("221","plan")])
assert got == exp, "got %r exp %r" % (got, exp)
PY
pass "plan-eval word order (#1469): Plan-eval/plan eval/Plan evaluation -> plan-eval; Plan #N -> plan"
rm -rf "$home" "$proj"

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

# ---------------------------------------------------------------------------
# Role-aware reconciliation grain (#1299, on top of #830). The orchestrator's
# closing code review and the evaluate-issue-pr agent are dispatched from the
# SAME session for the SAME issue and BOTH land at stage=pr-eval. With the #830
# suppression keyed on (session, issue, stage) alone, a usage_complete sibling
# swallows the review agent's lower-bound and the new attribution delivers no
# cost at all. The suppression grain must therefore include `role`.
#
# CONTROL (unchanged #830 behaviour): a lower-bound whose role MATCHES the
# complete sibling's role is STILL suppressed. This control must stay green
# before and after the grain change — it pins that #830 is narrowed by exactly
# one dimension, not disabled.
# ---------------------------------------------------------------------------
home="$(mktemp -d)"; proj="$(mktemp -d)"
mkdir -p "$proj/.claude/logs/subagents"
: > "$proj/.claude/logs/runs.log"   # no headless rows for this scenario

{
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "2026-06-02T09:00:00.000Z" "sess-rev" "Review code changes #1291" "x" "x" "x" "rev-review-1291.json"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "2026-06-02T09:01:00.000Z" "sess-rev" "Evaluate PR #1301 for #1291" "x" "x" "x" "rev-single-1291.json"
} > "$proj/.claude/logs/subagents.log"

cat > "$proj/.claude/logs/subagents/rev-review-1291.json" <<'JSON'
{"subagent_type":"general-purpose","usage":{"input_tokens":1400,"output_tokens":90,"cache_read_input_tokens":8,"cache_creation_input_tokens":2}}
JSON
cat > "$proj/.claude/logs/subagents/rev-single-1291.json" <<'JSON'
{"subagent_type":"general-purpose","usage":{"input_tokens":700,"output_tokens":40,"cache_read_input_tokens":3,"cache_creation_input_tokens":1}}
JSON

# Pre-seed ONE usage_complete=true, role=single record covering
# (sess-rev, 1291, pr-eval) — the evaluate-issue-pr agent's durable cost.
rev_out="$proj/.claude/logs/agent-costs.jsonl"
cat > "$rev_out" <<'JSON'
{"schema_version":1,"record_key":"seed-rev-1291-complete","issue":"1291","stage":"pr-eval","agent_kind":"inline","agent_type":"general-purpose","session_id":"sess-rev","model":"claude-opus-4-8","role":"single","tokens":{"input":40000,"output":900,"cache_read":30000,"cache_creation":1000,"total":71900},"duration_ms":0,"ts_start":"2026-06-02T08:00:00.000Z","ts_end":"2026-06-02T08:30:00.000Z","source":"forward","usage_complete":true}
JSON

HOME="$home" CLAUDE_PROJECT_DIR="$proj" PIPELINE_LOGS_ENABLED="true" \
  bash "$SCRIPT" >/dev/null 2>&1 || true

python3 - "$rev_out" <<'PY' || fail "role-aware reconciliation (#1299) assertions failed"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]

def match(r, role, complete):
    return (r.get("session_id") == "sess-rev"
            and str(r.get("issue")) == "1291"
            and r.get("stage") == "pr-eval"
            and r.get("role") == role
            and r.get("usage_complete") is complete)

# The pre-seeded complete record survives.
assert any(match(r, "single", True) for r in rows), \
    "pre-seeded complete pr-eval record for #1291 must survive"

# CONTROL (checked FIRST so it is exercised even while the case below is red):
# the SAME-role lower-bound is still suppressed (#830 narrowed, not disabled).
same_role_lb = [r for r in rows if match(r, "single", False)]
assert not same_role_lb, \
    "same-role lower-bound must still be suppressed, got %r" % same_role_lb
print("  control OK: same-role lower-bound still suppressed")

# The role=review lower-bound is a DIFFERENT agent's cost and must SURVIVE.
review_lb = [r for r in rows if match(r, "review", False)]
assert review_lb, \
    "role=review lower-bound must survive: a complete role=single sibling at the " \
    "same (session, issue, stage) must NOT suppress it"

print("role-aware reconciliation (#1299) assertions OK")
PY
pass "reconciliation grain is role-aware: review lower-bound survives, same-role suppressed"

rm -rf "$home" "$proj"

# ---------------------------------------------------------------------------
# Re-backfill idempotency across the widening (#1299). The retroactive pass is
# re-run over an agent-costs.jsonl that already holds records from an EARLIER
# run. A newly-attributable description mints a FIRST-EVER record (there is no
# stale row to supersede and no key to re-mint), and a further re-run appends
# nothing:
#   run 1, pre-#1299 fixture lines only        -> 10 inline records appended
#   run 2, the 3 new #1299 lines now present   -> exactly 3 more appended
#   run 3, no input change                     -> 0 appended
# ---------------------------------------------------------------------------
home="$(mktemp -d)"; proj="$(mktemp -d)"
mkdir -p "$proj/.claude/logs/subagents"
: > "$proj/.claude/logs/runs.log"   # inline pass only
cp "$FIX"/subagents/*.json "$proj/.claude/logs/subagents/"
# Stage ONLY the pre-#1299 lines (drop the three new shapes by sidecar name).
grep -v -e 'agent-cleaf-1291\.json' -e 'agent-review-1291\.json' \
        -e 'agent-review-1292\.json' \
  "$FIX/subagents.log" > "$proj/.claude/logs/subagents.log"
idem_out="$proj/.claude/logs/agent-costs.jsonl"

run_capture() {
  HOME="$home" CLAUDE_PROJECT_DIR="$proj" PIPELINE_LOGS_ENABLED="true" \
    bash "$SCRIPT" >/dev/null 2>&1 || true
}
count_out() {
  if [ -f "$idem_out" ]; then wc -l < "$idem_out" | tr -d ' '; else echo 0; fi
}

run_capture
n_pre="$(count_out)"
[ "$n_pre" = "10" ] \
  || fail "re-backfill: pre-#1299 fixture lines must yield 10 inline records, got $n_pre"
pass "re-backfill: pre-#1299 fixture lines yield 10 inline records"

cp "$FIX/subagents.log" "$proj/.claude/logs/subagents.log"
run_capture
n_post="$(count_out)"
[ "$n_post" = "13" ] \
  || fail "re-backfill: the 3 newly-attributable lines must append exactly 3 records (10 -> $n_post, want 13)"
pass "re-backfill: 3 newly-attributable lines appended exactly 3 first-ever records"

run_capture
n_third="$(count_out)"
[ "$n_third" = "13" ] \
  || fail "re-backfill: third run must append 0 records (13 -> $n_third)"
pass "re-backfill: third run appended 0 (no re-key, no double-count)"

uniq2="$(python3 - "$idem_out" <<'PY'
import json,sys
keys=[json.loads(l)["record_key"] for l in open(sys.argv[1]) if l.strip()]
print("DUP" if len(keys)!=len(set(keys)) else "OK")
PY
)"
[ "$uniq2" = "OK" ] || fail "re-backfill: duplicate record_keys after the widening"
pass "re-backfill: all record_keys unique across the widening"

rm -rf "$home" "$proj"

# ---------------------------------------------------------------------------
# message.id dedupe (#1443). Fully hermetic: its OWN home + proj and its OWN
# single-line runs.log, so the shared tests/fixtures/token-usage/runs.log (whose
# row counts tests/test-agent-costs-schema.sh and
# tests/test-agent-costs-stage-map.sh pin) is untouched. The msgid fixture is
# msg_A x3 (output 5/40/90) + msg_B + msg_C: deduped 60/106/6000/300 vs a naive
# per-line 80/151/8000/500 (total 6466 vs 8731). HEADLESS rows carry the
# all-four-bucket total, so cache_read IS included here. The block also pins the
# schema_version=2 structural fields turns/ctx_first/ctx_last on BOTH producer
# passes, including the 0 sentinel on an inline row with no resolvable
# transcript.
# ---------------------------------------------------------------------------
home="$(mktemp -d)"; proj="$(mktemp -d)"
mkdir -p "$proj/.claude/logs/subagents"
msgid_wt="/home/fix/claude-pipeline/.claude/worktrees/wt-1443"
printf '%s\tsession=%s\tissue=%s\tpath=B\tskill=execute-issue-plan\tworktree=%s\n' \
  "2026-06-01T10:00:00Z" "sess-msgid-1443" "1443" "$msgid_wt" \
  > "$proj/.claude/logs/runs.log"
msgid_slug="$(tu_worktree_slug "$msgid_wt")"
mkdir -p "$home/.claude/projects/$msgid_slug"
cp "$FIX/transcript-msgid.jsonl" \
  "$home/.claude/projects/$msgid_slug/sess-msgid-1443.jsonl"
# A SECOND row, INLINE, whose subagent transcript does NOT resolve (agent_id
# noxcript has no staged transcript). It must carry turns/ctx_first/ctx_last ==
# 0: the HEADLESS pass above resolves a 3-turn transcript first, so a producer
# that read the module-scope `summ` at the inline call site instead of
# per-iteration locals would fabricate turns=3 / ctx 1100/3000 on this row.
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "2026-06-01T11:00:00Z" "sess-inline-1443" "Evaluate PR #1500 for #1443" \
  "1500" "0" "0" "agent-noxcript-1443.json" \
  > "$proj/.claude/logs/subagents.log"
cat > "$proj/.claude/logs/subagents/agent-noxcript-1443.json" <<'JSON'
{
  "ts": "2026-06-01T11:00:00Z",
  "session": "sess-inline-1443",
  "description": "Evaluate PR #1500 for #1443",
  "subagent_type": "general-purpose",
  "agent_id": "noxcript",
  "usage": {
    "input_tokens": 11,
    "output_tokens": 3,
    "cache_read_input_tokens": 0,
    "cache_creation_input_tokens": 0
  }
}
JSON
msgid_out="$proj/.claude/logs/agent-costs.jsonl"

HOME="$home" CLAUDE_PROJECT_DIR="$proj" PIPELINE_LOGS_ENABLED="true" \
  bash "$SCRIPT" >/dev/null 2>&1 || true

n_msgid="$(wc -l < "$msgid_out" | tr -d ' ')"
[ "$n_msgid" = "2" ] || fail "msgid dedupe: expected 2 records (1 headless + 1 inline), got $n_msgid"

python3 - "$msgid_out" <<'PY' || exit 1
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(rows) == 2, "expected 2 rows, got %d" % len(rows)
by_kind = {}
for r in rows:
    by_kind.setdefault(r["agent_kind"], []).append(r)

h = by_kind["headless"][0]
t = h["tokens"]
got = (t["input"], t["output"], t["cache_read"], t["cache_creation"])
assert got == (60, 106, 6000, 300), \
    "msgid dedupe buckets: got %r want (60, 106, 6000, 300)" % (got,)
assert t["total"] == 6466, "msgid dedupe total: got %r want 6466" % t["total"]
assert h["schema_version"] == 2, "headless schema_version: %r" % h["schema_version"]
assert h["turns"] == 3, "headless turns: got %r want 3" % h["turns"]
assert h["ctx_first"] == 1100, "headless ctx_first: got %r want 1100" % h["ctx_first"]
assert h["ctx_last"] == 3000, "headless ctx_last: got %r want 3000" % h["ctx_last"]

# No subagent transcript resolved for this inline row -> the structural fields
# are the honest 0 sentinel, NOT the headless pass's leaked values.
i = by_kind["inline"][0]
assert i["usage_complete"] is False, "inline row must stay a lower-bound"
assert i["turns"] == 0, "inline turns must be 0 (no transcript), got %r" % i["turns"]
assert i["ctx_first"] == 0, "inline ctx_first must be 0, got %r" % i["ctx_first"]
assert i["ctx_last"] == 0, "inline ctx_last must be 0, got %r" % i["ctx_last"]
print("msgid dedupe (#1443) assertions OK")
PY
pass "backfill dedupes by message.id; stamps turns/ctx (0 when no transcript)"

rm -rf "$home" "$proj"

# ---------------------------------------------------------------------------
# --recompute (#1443). Rows written before the message.id dedupe are ~2x high on
# the input side, and plain idempotency (the `seen` set seeded from disk) makes
# them uncorrectable: a re-run appends nothing. --recompute skips ONLY that
# seeding, so already-seen record_keys are re-emitted with fresh values;
# consumers take `group_by(.record_key) | last`, so the fresh row wins. Own
# mktemp env so it cannot perturb the "all record_keys unique" assertions above
# (a recompute DELIBERATELY duplicates keys).
# ---------------------------------------------------------------------------
home="$(mktemp -d)"; proj="$(mktemp -d)"
mkdir -p "$proj/.claude/logs/subagents"
: > "$proj/.claude/logs/subagents.log"      # headless pass only
rc_wt="/home/fix/claude-pipeline/.claude/worktrees/wt-recomp"
printf '%s\tsession=%s\tissue=%s\tpath=B\tskill=execute-issue-plan\tworktree=%s\n' \
  "2026-05-30T10:00:00Z" "sess-recomp" "1443" "$rc_wt" \
  > "$proj/.claude/logs/runs.log"
rc_slug="$(tu_worktree_slug "$rc_wt")"
mkdir -p "$home/.claude/projects/$rc_slug"
rc_transcript="$home/.claude/projects/$rc_slug/sess-recomp.jsonl"
cp "$FIX/transcript.jsonl" "$rc_transcript"
rc_out="$proj/.claude/logs/agent-costs.jsonl"

run_rc() {
  HOME="$home" CLAUDE_PROJECT_DIR="$proj" PIPELINE_LOGS_ENABLED="true" \
    bash "$SCRIPT" "$@" >/dev/null 2>&1
}
count_rc() {
  if [ -f "$rc_out" ]; then wc -l < "$rc_out" | tr -d ' '; else echo 0; fi
}

run_rc
n_rc1="$(count_rc)"
[ "$n_rc1" = "1" ] || fail "--recompute: first run must append 1 record, got $n_rc1"

run_rc
n_rc2="$(count_rc)"
[ "$n_rc2" = "1" ] || fail "--recompute: a plain re-run must append 0 (1 -> $n_rc2)"
pass "--recompute: plain re-run is still idempotent"

# Change the transcript's token values WITHOUT touching its timestamps, so the
# re-emitted row keeps the SAME record_key but carries fresh sums (350/70/16/5
# -> 350/149/16/5, total 441 -> 520). That makes "the fresh row wins" observable.
sed -i 's/"output_tokens":20/"output_tokens":99/' "$rc_transcript"

run_rc --recompute
n_rc3="$(count_rc)"
[ "$n_rc3" = "2" ] || fail "--recompute: must re-emit the seen record_key (1 -> $n_rc3, want 2)"
pass "--recompute: re-emits rows for already-seen record_keys"

python3 - "$rc_out" <<'PY' || exit 1
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(rows) == 2, "expected 2 rows, got %d" % len(rows)
assert rows[0]["record_key"] == rows[1]["record_key"], \
    "recompute must reuse the SAME record_key: %r vs %r" % (
        rows[0]["record_key"], rows[1]["record_key"])
assert rows[0]["tokens"]["total"] == 441, "stale row total: %r" % rows[0]["tokens"]["total"]
# group_by(.record_key) | last semantics: the LAST row on disk is the fresh one.
last = {}
for r in rows:
    last[r["record_key"]] = r
fresh = last[rows[0]["record_key"]]
assert fresh is rows[1], "the last row for the key must be the re-emitted one"
assert fresh["tokens"]["output"] == 149, "fresh output: %r" % fresh["tokens"]["output"]
assert fresh["tokens"]["total"] == 520, "fresh total: %r" % fresh["tokens"]["total"]
print("--recompute (#1443) last-write-wins assertions OK")
PY
pass "--recompute: the LAST row for a re-emitted record_key carries fresh values"

# Negative control: an unknown argument must be REJECTED (non-zero), not
# silently ignored, and must append nothing.
HOME="$home" CLAUDE_PROJECT_DIR="$proj" PIPELINE_LOGS_ENABLED="true" \
  bash "$SCRIPT" --totally-bogus >/dev/null 2>&1
rc_bogus=$?
[ "$rc_bogus" != "0" ] || fail "--recompute: unknown argument must exit non-zero, got 0"
n_rc4="$(count_rc)"
[ "$n_rc4" = "2" ] || fail "--recompute: unknown argument must append nothing (2 -> $n_rc4)"
pass "--recompute: unknown argument exits non-zero and writes nothing"

# --help is answered before the logging gate, so it works with logging off.
help_out="$(env -u PIPELINE_LOGS_ENABLED HOME="$home" CLAUDE_PROJECT_DIR="$proj" \
  bash "$SCRIPT" --help 2>&1)"
rc_help=$?
[ "$rc_help" = "0" ] || fail "--recompute: --help must exit 0, got $rc_help"
case "$help_out" in
  *--recompute*) pass "--help documents --recompute" ;;
  *) fail "--help output does not mention --recompute: $help_out" ;;
esac

rm -rf "$home" "$proj"

# ---------------------------------------------------------------------------
# #1470: Claude Code >=2.1.291 subagent transcripts carry MESSAGE-START usage
# only (every assistant record stop_reason:null, output_tokens tiny). Fixtures
# under tests/fixtures/token-usage/1470/:
#   old1470     2.1.278 shape (final records carry stop_reason) -> complete
#   new1470     2.1.291 shape + COMPLETED parent handback (usage, 7 tools,
#               208037 ms) -> last id's output REPLACED by 1293
#   nohb1470    2.1.291 shape, no parent record -> unknowns stay unknown
#   async1470   2.1.291 shape, async_launched ack + two task-notifications
#               -> duration/tool_calls from the LAST notification; no output
#   ackonly1470 2.1.291 shape, async_launched ack only -> no handback
# New-shape transcript: msg_n1 out 8->30, msg_n2 out 5->20 (message-start sum
# 50); input 5, cache_read 2200, cache_creation 300.
# ---------------------------------------------------------------------------
F1470="$FIX/1470"
home="$(mktemp -d)"; proj="$(mktemp -d)"
mkdir -p "$proj/.claude/logs/subagents"
: > "$proj/.claude/logs/runs.log"
cp "$F1470/subagents.log" "$proj/.claude/logs/subagents.log"
cp "$F1470"/subagents/*.json "$proj/.claude/logs/subagents/"
sa_dir="$home/.claude/projects/slug-1470/sess-1470/subagents"
mkdir -p "$sa_dir"
cp "$F1470/parent-1470.jsonl" "$home/.claude/projects/slug-1470/sess-1470.jsonl"
cp "$F1470/agent-old-1470.jsonl" "$sa_dir/agent-old1470.jsonl"
for id in new1470 nohb1470 async1470 ackonly1470; do
  cp "$F1470/agent-new-1470.jsonl" "$sa_dir/agent-$id.jsonl"
done
oc_out="$proj/.claude/logs/agent-costs.jsonl"

HOME="$home" CLAUDE_PROJECT_DIR="$proj" PIPELINE_LOGS_ENABLED="true" \
  bash "$SCRIPT" >/dev/null 2>&1 || true

python3 - "$oc_out" <<'PY' || fail "#1470 output_complete / handback recovery assertions failed"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by = {r["agent_id"]: r for r in rows}
assert set(by) == {"old1470", "new1470", "nohb1470", "async1470", "ackonly1470"}, sorted(by)
for r in rows:
    assert "output_complete" in r, "output_complete key missing: %r" % r
    assert "tool_calls" in r, "tool_calls key missing: %r" % r

o = by["old1470"]
assert o["output_complete"] is True, "old: output_complete %r" % o["output_complete"]
assert o["tokens"]["output"] == 160, "old: output %r" % o["tokens"]["output"]
assert o["duration_ms"] == 0, "old: duration %r" % o["duration_ms"]
assert o["tool_calls"] is None, "old: tool_calls %r" % o["tool_calls"]

n = by["new1470"]
assert n["output_complete"] is False, "new: output_complete %r" % n["output_complete"]
assert n["tokens"]["output"] == 30 + 1293, "new: output %r (want 1323)" % n["tokens"]["output"]
assert (n["tokens"]["input"], n["tokens"]["cache_read"], n["tokens"]["cache_creation"]) == (5, 2200, 300), n["tokens"]
assert n["duration_ms"] == 208037, "new: duration %r" % n["duration_ms"]
assert n["tool_calls"] == 7, "new: tool_calls %r" % n["tool_calls"]
assert n["usage_complete"] is True, "new: usage_complete %r" % n["usage_complete"]

for aid in ("nohb1470", "ackonly1470"):
    r = by[aid]
    assert r["output_complete"] is False, "%s: output_complete %r" % (aid, r["output_complete"])
    assert r["tokens"]["output"] == 50, "%s: output %r" % (aid, r["tokens"]["output"])
    assert r["duration_ms"] == 0, "%s: duration %r" % (aid, r["duration_ms"])
    assert r["tool_calls"] is None, "%s: tool_calls %r" % (aid, r["tool_calls"])

a = by["async1470"]
assert a["output_complete"] is False, "async: output_complete %r" % a["output_complete"]
assert a["tokens"]["output"] == 50, "async: output %r (no output recovery)" % a["tokens"]["output"]
assert a["duration_ms"] == 17056, "async: duration %r (want LAST notification)" % a["duration_ms"]
assert a["tool_calls"] == 4, "async: tool_calls %r" % a["tool_calls"]
print("#1470 output_complete / handback recovery assertions OK")
PY
pass "#1470: 2.1.291 transcripts flagged output_complete=false; handback/notification recovery"

# --recompute over pre-#1470 rows (no output_complete/tool_calls keys) re-emits
# each record_key carrying the new fields.
python3 - "$oc_out" <<'PY'
import json, sys
p = sys.argv[1]
rows = [json.loads(l) for l in open(p) if l.strip()]
with open(p, "w") as fh:
    for r in rows:
        r.pop("output_complete", None); r.pop("tool_calls", None)
        fh.write(json.dumps(r) + "\n")
PY
HOME="$home" CLAUDE_PROJECT_DIR="$proj" PIPELINE_LOGS_ENABLED="true" \
  bash "$SCRIPT" --recompute >/dev/null 2>&1 || true
python3 - "$oc_out" <<'PY' || fail "#1470 --recompute upgrade assertions failed"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(rows) == 10, "expected 5 legacy + 5 recomputed rows, got %d" % len(rows)
last = {}
for r in rows:
    last[r["record_key"]] = r
assert len(last) == 5, "recompute must reuse the 5 record_keys, got %d" % len(last)
for r in last.values():
    assert "output_complete" in r and "tool_calls" in r, "recomputed row lacks fields: %r" % r
PY
pass "#1470: --recompute re-emits pre-existing rows carrying output_complete/tool_calls"

rm -rf "$home" "$proj"

echo "all tests passed"
