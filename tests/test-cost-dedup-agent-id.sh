#!/bin/bash
set -uo pipefail
#
# Regression test for issue #880 — dedup forward/retroactive PAIRS on agent_id.
#
# ROOT CAUSE: every inline agent is logged twice — once source=forward (live
# PostToolUse(Agent) capture) and once source=retroactive (capture-agent-costs.sh
# backfill) — with DIFFERENT record_key and DIFFERENT ts_start, so neither the
# pass-1 record_key dedup nor a (session, ts_start) key collapses the pair. The
# pre-#880 pass-2 fallback group_by(.session_id, .issue, .stage) ALSO fails the
# pair when the two records carry different session_ids, AND it OVER-collapses
# distinct logical agents that share (session, "", stage) when the issue does not
# parse from the description.
#
# The correct per-logical-agent identity is the subagent agent_id (both producers
# resolve it internally to true-up the lower-bound). #880 makes the report's
# pass-2 dedup agent_id-aware: records carrying a non-empty agent_id collapse on
# agent_id (max_by tokens.total → reconciled record wins); records with empty/
# absent agent_id keep the (session, issue, stage) fallback.
#
# This test drives scripts/cost-latency-report.sh --emit-pricing-json over a
# hermetic fixture and asserts the priced magnitude counts each logical agent
# ONCE — exercising BOTH failure modes:
#   Case A — a forward+retroactive PAIR (shared agent_id="A1", DISTINCT
#            session_id + DISTINCT record_key + DISTINCT ts_start, both
#            usage_complete=true, forward total < retroactive total). The report
#            must count the SINGLE reconciled (max-total) record, NOT the sum.
#   Case B — two DISTINCT inline agents with issue="" but agent_id="B1"/"B2"
#            sharing one (session, "", execute) group. They must BOTH survive
#            (NOT be over-collapsed to one).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/cost-latency-report.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "== test-cost-dedup-agent-id (issue #880) =="

# ---------------------------------------------------------------------------
# Fixture. One eligible feature PR (#106 → issue #206) gives the report a PR to
# iterate; the dedup logic operates on capture.jsonl independently of the PR set,
# so the priced total is what we assert.
#
# Golden pricing (Opus defaults, no PIPELINE_PRICE_* env): per-1M rates
#   input 15, output 75, cache_creation 18.75, cache_read 1.50.
#
# Case A — pair on agent_id="A1". Forward record (smaller) and retroactive
#   record (larger, reconciled) describe ONE logical agent. After #880 the report
#   keeps ONLY the larger (retroactive) record:
#     input 1,000,000 → 1 * 15    = $15.00
#     output  500,000 → 0.5 * 75  = $37.50
#     cache_creation 0            =  $0.00
#     cache_read 2,000,000 → 2*1.5 =  $3.00
#                            A-cost = $55.50
#   The forward record (input 600,000 → $9, output 300,000 → $22.50 = $31.50)
#   must NOT be added — pre-#880 (distinct session_id) it WOULD be, inflating the
#   total. NOTE both carry usage_complete=true so neither is dropped by the
#   reconciled-substrate (usage_complete!=false) filter; the ONLY thing that can
#   collapse them is the agent_id dedup.
#
# Case B — two distinct agents B1/B2 in one (session sBB, "", execute) group:
#     B1 input 1,000,000 → $15.00
#     B2 input 1,000,000 → $15.00
#   Both must survive → $30.00. Pre-#880 the (session,"",stage) fallback collapses
#   them to one (keeps max; here equal) → only $15.00 (an UNDER-count).
#
# Golden total after #880 = 55.50 (A) + 30.00 (B) = $85.50.
# Pre-#880 (buggy) total = (55.50 + 31.50) (A, both counted) + 15.00 (B collapsed)
#                        = $102.00  — a DIFFERENT number, so the test discriminates.
# ---------------------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf '%s\n' '[
  {"number":106,"title":"feat: dedup fixture","additions":10,"deletions":0,"body":"Closes #206","mergedAt":"2026-06-01T12:00:00Z","labels":[]}
]' > "$TMP/prs.json"
printf '%s\n' '{"number":106,"additions":10,"deletions":0,"comments":[]}' > "$TMP/pr-106.json"
printf '%s\n' '{"number":206,"labels":[],"comments":[]}' > "$TMP/issue-206.json"

{
  # --- Case A: forward + retroactive PAIR, shared agent_id="A1" ---
  # Forward (partial, smaller): distinct session, distinct record_key, distinct ts_start.
  echo '{"schema_version":1,"issue":"206","stage":"execute","agent_kind":"inline","agent_type":"general-purpose","session_id":"sFWD","agent_id":"A1","model":"claude-opus-4-8","record_key":"KA_fwd","tokens":{"input":600000,"output":300000,"cache_read":0,"cache_creation":0,"total":900000},"duration_ms":1000,"ts_start":"2026-06-01T10:00:00Z","ts_end":"2026-06-01T10:05:00Z","source":"forward","usage_complete":true}'
  # Retroactive (reconciled, larger): the record the report must keep.
  echo '{"schema_version":1,"issue":"206","stage":"execute","agent_kind":"inline","agent_type":"general-purpose","session_id":"sRETRO","agent_id":"A1","model":"claude-opus-4-8","record_key":"KA_retro","tokens":{"input":1000000,"output":500000,"cache_read":2000000,"cache_creation":0,"total":3500000},"duration_ms":2000,"ts_start":"2026-06-01T10:01:00Z","ts_end":"2026-06-01T10:06:00Z","source":"retroactive","usage_complete":true}'
  # --- Case B: two DISTINCT agents, issue="", same (session,"",execute) group ---
  echo '{"schema_version":1,"issue":"","stage":"execute","agent_kind":"inline","agent_type":"general-purpose","session_id":"sBB","agent_id":"B1","model":"claude-opus-4-8","record_key":"KB1","tokens":{"input":1000000,"output":0,"cache_read":0,"cache_creation":0,"total":1000000},"duration_ms":1000,"ts_start":"2026-06-01T11:00:00Z","ts_end":"2026-06-01T11:05:00Z","source":"retroactive","usage_complete":true}'
  echo '{"schema_version":1,"issue":"","stage":"execute","agent_kind":"inline","agent_type":"general-purpose","session_id":"sBB","agent_id":"B2","model":"claude-opus-4-8","record_key":"KB2","tokens":{"input":1000000,"output":0,"cache_read":0,"cache_creation":0,"total":1000000},"duration_ms":1000,"ts_start":"2026-06-01T11:00:00Z","ts_end":"2026-06-01T11:05:00Z","source":"retroactive","usage_complete":true}'
} > "$TMP/capture.jsonl"

PRICING="$(env -u PIPELINE_PRICE_CLAUDE_OPUS_4_8_INPUT \
               -u PIPELINE_PRICE_CLAUDE_OPUS_4_8_OUTPUT \
               -u PIPELINE_PRICE_CLAUDE_OPUS_4_8_CACHE_CREATION \
               -u PIPELINE_PRICE_CLAUDE_OPUS_4_8_CACHE_READ \
           bash "$HELPER" --fixture "$TMP" --emit-pricing-json 2>/dev/null)"

if printf '%s' "$PRICING" | jq -e . >/dev/null 2>&1; then
  pass_msg "--emit-pricing-json output parses as JSON"
else
  fail_msg "--emit-pricing-json output is not valid JSON (got: $(printf '%s' "$PRICING" | head -1))"
fi

COST="$(printf '%s' "$PRICING" | jq -r '.priced_cost_usd' 2>/dev/null)"
case "$COST" in
  85.50|85.5)
    pass_msg "priced_cost_usd == 85.50 — pair collapsed on agent_id (A=55.50) + both B agents kept (30.00)" ;;
  102.00|102|102.0)
    fail_msg "priced_cost_usd == 102.00 — forward+retroactive pair DOUBLE-COUNTED and B agents over-collapsed (pre-#880 bug)" ;;
  *)
    fail_msg "priced_cost_usd should be 85.50 (A reconciled 55.50 + B1+B2 30.00), got $COST" ;;
esac

echo ""
echo "== summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
