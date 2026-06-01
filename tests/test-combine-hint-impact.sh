#!/bin/bash
# test-combine-hint-impact.sh — fixture-mode suite for scripts/combine-hint-impact.sh (#757).
#
# DOGFOOD-ONLY. Mirrors tests/test-cost-latency-report.sh: drives the report in
# --fixture mode against tests/fixtures/combine-hint-impact/ so no live `gh` or
# real agent-costs.jsonl is needed. One live guard (Scenario 8) runs the real
# tool against today's data and asserts it exits 0 + prints INSUFFICIENT DATA.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/combine-hint-impact.sh"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/combine-hint-impact"
KEEP_DIR="$FIXTURE_DIR/keep"
REVERT_DIR="$FIXTURE_DIR/revert"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "== Scenario 1: scaffolding + --help + arg parse =="
[ -x "$HELPER" ] && pass_msg "executable" || fail_msg "not executable"
head -1 "$HELPER" 2>/dev/null | grep -q '^#!/bin/bash' && pass_msg "shebang" || fail_msg "no shebang"
H="$(bash "$HELPER" --help 2>&1 || true)"
printf '%s' "$H" | grep -qi 'usage' && pass_msg "usage banner" || fail_msg "no usage"
printf '%s' "$H" | grep -qi 'DOGFOOD' && pass_msg "DOGFOOD callout" || fail_msg "no DOGFOOD"
bash "$HELPER" --badflag >/dev/null 2>&1
[ $? -ne 0 ] && pass_msg "unknown flag rejects" || fail_msg "unknown flag accepted"

echo "== Scenario 2: fixture-aware loaders → valid rows JSON =="
ROWS="$(bash "$HELPER" --fixture "$FIXTURE_DIR" --emit-rows-json 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] && pass_msg "rows-json exit 0" || fail_msg "rows-json exit $rc"
printf '%s' "$ROWS" | jq -e 'type == "array"' >/dev/null 2>&1 \
  && pass_msg "rows-json is a JSON array" || fail_msg "rows-json not a JSON array"
printf '%s' "$ROWS" | jq -e 'length == 8' >/dev/null 2>&1 \
  && pass_msg "8 issue rows" || fail_msg "expected 8 rows, got $(printf '%s' "$ROWS" | jq 'length' 2>/dev/null)"

echo "== Scenario 3: cohort partition by createdAt vs merge ts =="
printf '%s' "$ROWS" | jq -e 'all(.[]; .cohort == "pre" or .cohort == "post")' >/dev/null 2>&1 \
  && pass_msg "every row has cohort in {pre,post}" || fail_msg "cohort field missing/invalid"
PRE_N="$(printf '%s' "$ROWS" | jq '[.[]|select(.cohort=="pre")]|length' 2>/dev/null)"
POST_N="$(printf '%s' "$ROWS" | jq '[.[]|select(.cohort=="post")]|length' 2>/dev/null)"
[ "$PRE_N" = "6" ] && pass_msg "6 pre issues" || fail_msg "expected 6 pre, got $PRE_N"
[ "$POST_N" = "2" ] && pass_msg "2 post issues" || fail_msg "expected 2 post, got $POST_N"
printf '%s' "$ROWS" | jq -e 'all(.[]; .path == "B")' >/dev/null 2>&1 \
  && pass_msg "all rows derive PATH B" || fail_msg "path derivation wrong"

echo "== Scenario 4: cost metrics + within-bucket normalization =="
KV="$(bash "$HELPER" --fixture "$KEEP_DIR" --emit-verdict-json 2>/dev/null)"
printf '%s' "$KV" | jq -e '.buckets | type == "array"' >/dev/null 2>&1 \
  && pass_msg "verdict-json has buckets array" || fail_msg "no buckets array"
printf '%s' "$KV" | jq -e '.buckets[0] | has("bucket") and has("pre_n") and has("post_n") and has("pre_mean_cache_creation") and has("post_mean_cache_creation") and has("cost_direction")' >/dev/null 2>&1 \
  && pass_msg "bucket object has required fields" || fail_msg "bucket object missing fields"
printf '%s' "$KV" | jq -e '.buckets[] | select(.path=="B" and .bucket=="2-3") | .cost_direction == "down"' >/dev/null 2>&1 \
  && pass_msg "keep bucket cost_direction=down" || fail_msg "keep bucket not down"
# default fixture: post_n=2 < MIN_N → that bucket flagged insufficient
DV="$(bash "$HELPER" --fixture "$FIXTURE_DIR" --emit-verdict-json 2>/dev/null)"
printf '%s' "$DV" | jq -e '.buckets[] | select(.path=="B" and .bucket=="2-3") | .insufficient == true' >/dev/null 2>&1 \
  && pass_msg "low-N bucket flagged insufficient" || fail_msg "low-N bucket not flagged"

echo "== Scenario 5: structural metrics (GitHub-sourced) =="
printf '%s' "$DV" | jq -e '.structural.pre | has("issues_created") and has("mean_files_per_issue") and has("pr_count") and has("wave_serialization")' >/dev/null 2>&1 \
  && pass_msg "structural.pre has required fields" || fail_msg "structural.pre missing fields"
printf '%s' "$DV" | jq -e '.structural.pre.issues_created == 6' >/dev/null 2>&1 \
  && pass_msg "structural.pre.issues_created=6" || fail_msg "pre issues_created wrong"
printf '%s' "$DV" | jq -e '.structural.post.issues_created == 2' >/dev/null 2>&1 \
  && pass_msg "structural.post.issues_created=2" || fail_msg "post issues_created wrong"
printf '%s' "$DV" | jq -e '.structural.pre.pr_count == 6' >/dev/null 2>&1 \
  && pass_msg "structural.pre.pr_count=6" || fail_msg "pre pr_count wrong"

echo "== Scenario 6: composite accuracy metric =="
printf '%s' "$DV" | jq -e '.accuracy.pre | has("first_pass_approval_rate") and has("replan_count") and has("escalation_count") and has("fix_commit_count")' >/dev/null 2>&1 \
  && pass_msg "accuracy.pre has required fields" || fail_msg "accuracy.pre missing fields"
printf '%s' "$DV" | jq -e '.accuracy.pre.first_pass_approval_rate == 1' >/dev/null 2>&1 \
  && pass_msg "pre first_pass_approval_rate=1" || fail_msg "pre approval rate wrong"
printf '%s' "$DV" | jq -e '.accuracy.post.replan_count == 1' >/dev/null 2>&1 \
  && pass_msg "post replan_count=1 (issue 302)" || fail_msg "post replan_count wrong"
printf '%s' "$DV" | jq -e '.accuracy.post.escalation_count == 1' >/dev/null 2>&1 \
  && pass_msg "post escalation_count=1 (issue 302)" || fail_msg "post escalation_count wrong"
printf '%s' "$DV" | jq -e 'has("accuracy_worse")' >/dev/null 2>&1 \
  && pass_msg "accuracy_worse boolean present" || fail_msg "accuracy_worse missing"

echo "== Scenario 7: hint-quality metric (post-only) =="
printf '%s' "$DV" | jq -e '.hint_quality | has("hint_emit_rate") and has("hint_classify_agreement_rate")' >/dev/null 2>&1 \
  && pass_msg "hint_quality has required fields" || fail_msg "hint_quality missing fields"
# default: post issues 301 (hint=B) + 302 (no hint) → emit rate 1/2 = 0.5
printf '%s' "$DV" | jq -e '.hint_quality.hint_emit_rate == 0.5' >/dev/null 2>&1 \
  && pass_msg "hint_emit_rate=0.5" || fail_msg "hint_emit_rate wrong ($(printf '%s' "$DV" | jq '.hint_quality.hint_emit_rate' 2>/dev/null))"
# 301 hint=B agrees with classification B → agreement 1/1 = 1
printf '%s' "$DV" | jq -e '.hint_quality.hint_classify_agreement_rate == 1' >/dev/null 2>&1 \
  && pass_msg "hint_classify_agreement_rate=1" || fail_msg "agreement rate wrong"
# hint_quality is post-only — pre carries no hint baseline
printf '%s' "$DV" | jq -e '(.hint_quality.cohort // "post") == "post"' >/dev/null 2>&1 \
  && pass_msg "hint_quality scoped to post cohort" || fail_msg "hint_quality not post-scoped"

echo "== Scenario 8: min-N verdict gate + recommendation =="
# 8a. Insufficient (default fixture): post buckets all N<MIN_N
OUT="$(bash "$HELPER" --fixture "$FIXTURE_DIR" 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] && pass_msg "default render exit 0" || fail_msg "default render exit $rc"
printf '%s' "$OUT" | grep -q 'INSUFFICIENT DATA' && pass_msg "renders INSUFFICIENT DATA" || fail_msg "no INSUFFICIENT DATA"
printf '%s' "$OUT" | grep -Eq 'N=[0-9]+' && pass_msg "INSUFFICIENT line carries N=<n>" || fail_msg "no N=<n>"
printf '%s' "$OUT" | grep -qE '\b(Keep|Revert-candidate)\b' && fail_msg "leaked a recommendation under insufficient data" || pass_msg "no Keep/Revert under insufficient data"

# 8b. LIVE real-data guard: real agent-costs.jsonl, today's ~empty post cohort.
LIVE="$(bash "$HELPER" 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] && pass_msg "live real-data run exits 0" || fail_msg "live run exit $rc"
printf '%s' "$LIVE" | grep -q 'INSUFFICIENT DATA' \
  && pass_msg "live run prints INSUFFICIENT DATA (build-only guard)" || fail_msg "live run did not print INSUFFICIENT DATA"

# 8c. Sufficient — Keep (post cost down, accuracy not worse)
KOUT="$(bash "$HELPER" --fixture "$KEEP_DIR" 2>/dev/null)"
printf '%s' "$KOUT" | grep -q 'INSUFFICIENT DATA' && fail_msg "keep fixture wrongly insufficient" || pass_msg "keep fixture clears min-N"
printf '%s' "$KOUT" | grep -qw 'Keep' && pass_msg "keep fixture → Keep" || fail_msg "keep fixture not Keep"
KVERD="$(bash "$HELPER" --fixture "$KEEP_DIR" --emit-verdict-json 2>/dev/null)"
printf '%s' "$KVERD" | jq -e '.recommendation == "Keep"' >/dev/null 2>&1 \
  && pass_msg "keep verdict-json recommendation=Keep" || fail_msg "keep verdict-json not Keep"

# 8d. Sufficient — Revert-candidate (post cost up)
ROUT="$(bash "$HELPER" --fixture "$REVERT_DIR" 2>/dev/null)"
printf '%s' "$ROUT" | grep -q 'Revert-candidate' && pass_msg "revert fixture → Revert-candidate" || fail_msg "revert fixture not Revert-candidate"
RVERD="$(bash "$HELPER" --fixture "$REVERT_DIR" --emit-verdict-json 2>/dev/null)"
printf '%s' "$RVERD" | jq -e '.recommendation == "Revert-candidate"' >/dev/null 2>&1 \
  && pass_msg "revert verdict-json recommendation=Revert-candidate" || fail_msg "revert verdict-json not Revert-candidate"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
