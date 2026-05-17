#!/bin/bash
set -uo pipefail
#
# Tests for scripts/analyze-issues.sh — the Stage 1 deterministic shortlist
# generator backing /pipeline:run --analyze (issue #138).
#
# Uses fixture mode (--fixture <dir>) so no live `gh` calls are required.
# The fixture directory must contain:
#   - issues.json        — the `gh issue list ... --json number,title,body,labels` payload
#   - issue-<N>.json     — the `gh issue view <N> --json body` payload, one per tracker
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/analyze-issues.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT

# Minimal pipeline.config so the helper can source it.
cat > "$TMP/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/test-repo"
CFG

inc_scenario() { echo ""; echo "-- $1 --"; }

# Run helper from $TMP so `.claude/logs/` is created there (helper writes
# output relative to PWD).
run_helper() {
  local fixture="$1"
  mkdir -p "$TMP/.claude/logs"
  ( cd "$TMP" && bash "$HELPER" --fixture "$fixture" )
}

# --- Scenario 1: title Jaccard duplicate detection ---
inc_scenario "Scenario 1: Jaccard duplicate pair (shared scope, related titles)"
FIX1="$TMP/fix1"; mkdir -p "$FIX1"
cat > "$FIX1/issues.json" <<'J'
[
  {"number":10,"title":"feat(spawn): refactor argv parsing","body":"Refactor the argv parsing for spawn-claude.","labels":[]},
  {"number":11,"title":"fix(spawn): argv parser flakiness","body":"argv parser is flaky during spawn-claude invocations.","labels":[]},
  {"number":12,"title":"feat(redline): unrelated thing","body":"Different scope entirely.","labels":[]},
  {"number":13,"title":"chore(ci): bump action","body":"Bump CI action.","labels":[]}
]
J
out1=$(run_helper "$FIX1" 2>&1)
rc1=$?
echo "$out1" | sed 's/^/    /'
shortlist1=$(echo "$out1" | tail -n 1)
if [ "$rc1" -eq 0 ] && [ -f "$shortlist1" ]; then
  pass_msg "scenario 1: exit 0 and shortlist file exists"
else
  fail_msg "scenario 1: exit 0 and shortlist file exists (rc=$rc1, file=$shortlist1)"
fi

if [ -f "$shortlist1" ]; then
  pair_count=$(jq '.duplicate_pairs | length' "$shortlist1" 2>/dev/null || echo "0")
  if [ "$pair_count" = "1" ]; then
    pass_msg "scenario 1: exactly one duplicate-pair row emitted"
  else
    fail_msg "scenario 1: exactly one duplicate-pair row emitted (got $pair_count)"
  fi
  scope_val=$(jq -r '.duplicate_pairs[0].shared_scope' "$shortlist1" 2>/dev/null || echo "")
  if [ "$scope_val" = "spawn" ]; then
    pass_msg "scenario 1: shared_scope == \"spawn\""
  else
    fail_msg "scenario 1: shared_scope == \"spawn\" (got '$scope_val')"
  fi
  jaccard_ok=$(jq -r '.duplicate_pairs[0].title_jaccard >= 0.35' "$shortlist1" 2>/dev/null || echo "false")
  if [ "$jaccard_ok" = "true" ]; then
    pass_msg "scenario 1: title_jaccard >= 0.35"
  else
    fail_msg "scenario 1: title_jaccard >= 0.35 (got $(jq -r '.duplicate_pairs[0].title_jaccard' "$shortlist1" 2>/dev/null))"
  fi
  a_b=$(jq -r '.duplicate_pairs[0] | "\(.a),\(.b)"' "$shortlist1" 2>/dev/null || echo "")
  if [ "$a_b" = "10,11" ]; then
    pass_msg "scenario 1: pair is (10,11) with a<b"
  else
    fail_msg "scenario 1: pair is (10,11) (got '$a_b')"
  fi
fi

# --- Scenario 2: unrelated scope-less titles produce NO pair ---
inc_scenario "Scenario 2: unrelated titles produce no row"
FIX2="$TMP/fix2"; mkdir -p "$FIX2"
cat > "$FIX2/issues.json" <<'J'
[
  {"number":20,"title":"feat(redline): something","body":"Body A.","labels":[]},
  {"number":21,"title":"chore(ci): bump action","body":"Body B.","labels":[]}
]
J
out2=$(run_helper "$FIX2" 2>&1)
shortlist2=$(echo "$out2" | tail -n 1)
if [ -f "$shortlist2" ]; then
  pair_count2=$(jq '.duplicate_pairs | length' "$shortlist2")
  if [ "$pair_count2" = "0" ]; then
    pass_msg "scenario 2: zero duplicate pairs for unrelated titles"
  else
    fail_msg "scenario 2: zero duplicate pairs (got $pair_count2)"
  fi
fi

# --- Scenario 3: scope-token extraction edge cases ---
inc_scenario "Scenario 3: scope-match standalone fits tracker"
FIX3="$TMP/fix3"; mkdir -p "$FIX3"
cat > "$FIX3/issues.json" <<'J'
[
  {"number":60,"title":"epic(pipeline): rollout","body":"## Rollout sequence\n- [ ] **#34 — child A\n- [x] **#35 — child B\n","labels":[{"name":"tracker"}]},
  {"number":34,"title":"feat(pipeline): child task A","body":"x","labels":[]},
  {"number":35,"title":"feat(pipeline): child task B","body":"x","labels":[]},
  {"number":99,"title":"feat(pipeline): polish thing","body":"Just polish.","labels":[]}
]
J
# tracker body file (per-tracker view)
cat > "$FIX3/issue-60.json" <<'J'
{"body":"## Rollout sequence\n- [ ] **#34 — child A\n- [x] **#35 — child B\n"}
J
out3=$(run_helper "$FIX3" 2>&1)
shortlist3=$(echo "$out3" | tail -n 1)
if [ -f "$shortlist3" ]; then
  fits=$(jq -c '.tracker_fits' "$shortlist3")
  echo "    tracker_fits: $fits"
  match99=$(jq -r '[.tracker_fits[] | select(.issue == 99 and .tracker == 60 and .reason == "scope-match")] | length' "$shortlist3")
  if [ "$match99" = "1" ]; then
    pass_msg "scenario 3: #99 emits scope-match fit to #60"
  else
    fail_msg "scenario 3: #99 emits scope-match fit to #60 (matches=$match99)"
  fi
  match34=$(jq -r '[.tracker_fits[] | select(.issue == 34)] | length' "$shortlist3")
  if [ "$match34" = "0" ]; then
    pass_msg "scenario 3: existing child #34 NOT re-flagged"
  else
    fail_msg "scenario 3: existing child #34 NOT re-flagged (matches=$match34)"
  fi
fi

# --- Scenario 4: body-reference detection ---
inc_scenario "Scenario 4: body-reference detection"
FIX4="$TMP/fix4"; mkdir -p "$FIX4"
cat > "$FIX4/issues.json" <<'J'
[
  {"number":60,"title":"epic(pipeline): rollout","body":"## Rollout sequence\n- [ ] **#34 — child A\n","labels":[{"name":"tracker"}]},
  {"number":34,"title":"feat(pipeline): child task A","body":"x","labels":[]},
  {"number":50,"title":"feat(other): unrelated scope","body":"Related to #60 in the discussion.","labels":[]}
]
J
cat > "$FIX4/issue-60.json" <<'J'
{"body":"## Rollout sequence\n- [ ] **#34 — child A\n"}
J
out4=$(run_helper "$FIX4" 2>&1)
shortlist4=$(echo "$out4" | tail -n 1)
if [ -f "$shortlist4" ]; then
  fits4=$(jq -r '[.tracker_fits[] | select(.issue == 50 and .tracker == 60 and .reason == "body-reference")] | length' "$shortlist4")
  if [ "$fits4" = "1" ]; then
    pass_msg "scenario 4: #50 emits body-reference fit to #60"
  else
    fail_msg "scenario 4: #50 emits body-reference fit to #60 (matches=$fits4)"
    jq '.tracker_fits' "$shortlist4" | sed 's/^/      /'
  fi
fi

# --- Scenario 5: caps — 30 candidate pairs truncated to 20 ---
inc_scenario "Scenario 5: top-20 cap on duplicate_pairs"
FIX5="$TMP/fix5"; mkdir -p "$FIX5"
{
  echo "["
  # 31 issues, all sharing scope "spawn" and near-identical titles to force pairs
  for i in $(seq 100 130); do
    sep=","
    if [ "$i" = "130" ]; then sep=""; fi
    echo "  {\"number\":$i,\"title\":\"feat(spawn): refactor argv parsing variant $i\",\"body\":\"body $i\",\"labels\":[]}$sep"
  done
  echo "]"
} > "$FIX5/issues.json"
out5=$(run_helper "$FIX5" 2>&1)
shortlist5=$(echo "$out5" | tail -n 1)
if [ -f "$shortlist5" ]; then
  cap_count=$(jq '.duplicate_pairs | length' "$shortlist5")
  if [ "$cap_count" -le 20 ] && [ "$cap_count" -gt 0 ]; then
    pass_msg "scenario 5: duplicate_pairs capped at 20 (got $cap_count)"
  else
    fail_msg "scenario 5: duplicate_pairs capped at 20 (got $cap_count)"
  fi
fi

# --- Scenario 6: output shape ---
inc_scenario "Scenario 6: output file shape and stdout"
if [ -f "$shortlist1" ]; then
  case "$shortlist1" in
    */.claude/logs/analyze-shortlist-*.json)
      pass_msg "scenario 6: output path matches .claude/logs/analyze-shortlist-*.json"
      ;;
    *)
      fail_msg "scenario 6: output path matches pattern (got $shortlist1)"
      ;;
  esac
  keys=$(jq -r 'keys | join(",")' "$shortlist1")
  if [ "$keys" = "duplicate_pairs,missing_label_candidates,tracker_fits" ]; then
    pass_msg "scenario 6: output keys are duplicate_pairs,missing_label_candidates,tracker_fits"
  else
    fail_msg "scenario 6: output keys (got '$keys')"
  fi
  # Inspect first duplicate pair has required fields
  fields=$(jq -r '.duplicate_pairs[0] | "\(.a),\(.b),\(.title_jaccard),\(.shared_scope),\(.body_overlap_chars)"' "$shortlist1" 2>/dev/null || echo "")
  if [ -n "$fields" ] && [ "$fields" != "null,null,null,null,null" ]; then
    pass_msg "scenario 6: duplicate_pairs row has a,b,title_jaccard,shared_scope,body_overlap_chars"
  else
    fail_msg "scenario 6: duplicate_pairs row fields (got '$fields')"
  fi
fi

# --- Scenario 7: empty inputs still emit valid shape ---
inc_scenario "Scenario 7: empty inputs emit valid shape"
FIX7="$TMP/fix7"; mkdir -p "$FIX7"
echo "[]" > "$FIX7/issues.json"
out7=$(run_helper "$FIX7" 2>&1)
rc7=$?
shortlist7=$(echo "$out7" | tail -n 1)
if [ "$rc7" -eq 0 ] && [ -f "$shortlist7" ]; then
  empty_dp=$(jq '.duplicate_pairs | length' "$shortlist7")
  empty_tf=$(jq '.tracker_fits | length' "$shortlist7")
  if [ "$empty_dp" = "0" ] && [ "$empty_tf" = "0" ]; then
    pass_msg "scenario 7: empty arrays on empty input"
  else
    fail_msg "scenario 7: empty arrays (dp=$empty_dp tf=$empty_tf)"
  fi
fi

# Helper for deterministic createdAt timestamps in fixtures (ISO 8601, hours-ago).
# date(1) on GNU/BSD diverges; this wraps the GNU form used in CI.
hours_ago_iso() {
  date -u -d "$1 hours ago" +%Y-%m-%dT%H:%M:%SZ
}

# --- Scenario 8: missing priority — issue with docs-only path label, no priority/* ---
inc_scenario "Scenario 8: missing-priority signal surfaces issue lacking priority/P*"
FIX8="$TMP/fix8"; mkdir -p "$FIX8"
CREATED_48H=$(hours_ago_iso 48)
cat > "$FIX8/issues.json" <<J
[
  {"number":200,"title":"feat(spawn): docs touch-up","body":"x","labels":[{"name":"docs-only"}],"createdAt":"$CREATED_48H"}
]
J
out8=$(run_helper "$FIX8" 2>&1)
shortlist8=$(echo "$out8" | tail -n 1)
if [ -f "$shortlist8" ]; then
  missing_len=$(jq '.missing_label_candidates | length' "$shortlist8" 2>/dev/null || echo "0")
  if [ "$missing_len" = "1" ]; then
    pass_msg "scenario 8: missing_label_candidates has exactly 1 row"
  else
    fail_msg "scenario 8: missing_label_candidates has 1 row (got $missing_len)"
  fi
  row=$(jq -c '.missing_label_candidates[0]' "$shortlist8" 2>/dev/null || echo "{}")
  if [ "$row" = '{"issue":200,"missing":["priority"]}' ]; then
    pass_msg "scenario 8: row == {\"issue\":200,\"missing\":[\"priority\"]}"
  else
    fail_msg "scenario 8: row content (got '$row')"
  fi
fi

# --- Scenario 9: missing both priority + path (regression-protect ordering) ---
inc_scenario "Scenario 9: missing-both surfaces with priority before path"
FIX9="$TMP/fix9"; mkdir -p "$FIX9"
cat > "$FIX9/issues.json" <<J
[
  {"number":201,"title":"feat(spawn): plain feature","body":"x","labels":[],"createdAt":"$CREATED_48H"}
]
J
out9=$(run_helper "$FIX9" 2>&1)
shortlist9=$(echo "$out9" | tail -n 1)
if [ -f "$shortlist9" ]; then
  miss9=$(jq -c '.missing_label_candidates[] | select(.issue == 201) | .missing' "$shortlist9" 2>/dev/null || echo "[]")
  # The state token is also expected because no pipeline-stage/classification
  # labels are present AND the issue is older than the 24h cutoff. Ordering
  # priority,path,state is pinned by the impl to keep this assertion stable.
  if [ "$miss9" = '["priority","path","state"]' ]; then
    pass_msg "scenario 9: row .missing == [priority,path,state] in deterministic order"
  else
    fail_msg "scenario 9: row .missing ordering (got '$miss9')"
  fi
fi

# --- Scenario 10: age gate — just-filed issue (2h ago) is suppressed ---
inc_scenario "Scenario 10: age-gate suppresses just-filed issues (< 24h)"
FIX10="$TMP/fix10"; mkdir -p "$FIX10"
CREATED_2H=$(hours_ago_iso 2)
cat > "$FIX10/issues.json" <<J
[
  {"number":202,"title":"feat(spawn): just filed","body":"x","labels":[],"createdAt":"$CREATED_2H"}
]
J
# Use the default cutoff (24h) — issue at 2h is too fresh.
out10=$(PIPELINE_ANALYZE_MIN_AGE_HOURS=24 run_helper "$FIX10" 2>&1)
shortlist10=$(echo "$out10" | tail -n 1)
if [ -f "$shortlist10" ]; then
  miss10_len=$(jq '.missing_label_candidates | length' "$shortlist10" 2>/dev/null || echo "999")
  if [ "$miss10_len" = "0" ]; then
    pass_msg "scenario 10: just-filed issue suppressed by 24h age gate"
  else
    fail_msg "scenario 10: just-filed issue suppressed (got $miss10_len rows)"
  fi
fi

# --- Scenario 11: tracker is exempt from missing-priority/path signal ---
inc_scenario "Scenario 11: trackers are exempt from missing-label signal"
FIX11="$TMP/fix11"; mkdir -p "$FIX11"
cat > "$FIX11/issues.json" <<J
[
  {"number":203,"title":"epic(pipeline): rollout","body":"## Rollout sequence\n","labels":[{"name":"tracker"}],"createdAt":"$CREATED_48H"}
]
J
cat > "$FIX11/issue-203.json" <<'J'
{"body":"## Rollout sequence\n"}
J
out11=$(run_helper "$FIX11" 2>&1)
shortlist11=$(echo "$out11" | tail -n 1)
if [ -f "$shortlist11" ]; then
  miss11_len=$(jq '.missing_label_candidates | length' "$shortlist11" 2>/dev/null || echo "999")
  if [ "$miss11_len" = "0" ]; then
    pass_msg "scenario 11: tracker not surfaced in missing_label_candidates"
  else
    fail_msg "scenario 11: tracker not surfaced (got $miss11_len rows)"
  fi
fi

# --- Scenario 12: brainstorm / later / human labels suppress the signal ---
inc_scenario "Scenario 12: brainstorm/later/human labels suppress missing-label signal"
FIX12="$TMP/fix12"; mkdir -p "$FIX12"
cat > "$FIX12/issues.json" <<J
[
  {"number":204,"title":"chore(x): brainstorm only","body":"x","labels":[{"name":"brainstorm"}],"createdAt":"$CREATED_48H"},
  {"number":205,"title":"chore(x): later only","body":"x","labels":[{"name":"later"}],"createdAt":"$CREATED_48H"},
  {"number":206,"title":"chore(x): human only","body":"x","labels":[{"name":"human"}],"createdAt":"$CREATED_48H"}
]
J
out12=$(run_helper "$FIX12" 2>&1)
shortlist12=$(echo "$out12" | tail -n 1)
if [ -f "$shortlist12" ]; then
  miss12_len=$(jq '.missing_label_candidates | length' "$shortlist12" 2>/dev/null || echo "999")
  if [ "$miss12_len" = "0" ]; then
    pass_msg "scenario 12: brainstorm/later/human labels all exempt"
  else
    fail_msg "scenario 12: brainstorm/later/human exemption (got $miss12_len rows)"
  fi
fi

# --- Scenario 13: zero-findings corpus emits an empty missing_label_candidates array ---
inc_scenario "Scenario 13: zero findings emits empty missing_label_candidates array"
FIX13="$TMP/fix13"; mkdir -p "$FIX13"
cat > "$FIX13/issues.json" <<J
[
  {"number":207,"title":"feat(a): one","body":"x","labels":[{"name":"priority/P2"},{"name":"docs-only"}],"createdAt":"$CREATED_48H"},
  {"number":208,"title":"feat(b): two","body":"x","labels":[{"name":"priority/P1"},{"name":"multi-task"}],"createdAt":"$CREATED_48H"},
  {"number":209,"title":"feat(c): three","body":"x","labels":[{"name":"priority/P0"},{"name":"docs-only"}],"createdAt":"$CREATED_48H"}
]
J
out13=$(run_helper "$FIX13" 2>&1)
shortlist13=$(echo "$out13" | tail -n 1)
if [ -f "$shortlist13" ]; then
  has_key=$(jq 'has("missing_label_candidates")' "$shortlist13" 2>/dev/null || echo "false")
  miss13_len=$(jq '.missing_label_candidates | length' "$shortlist13" 2>/dev/null || echo "999")
  if [ "$has_key" = "true" ] && [ "$miss13_len" = "0" ]; then
    pass_msg "scenario 13: missing_label_candidates key present and empty"
  else
    fail_msg "scenario 13: key present + empty (has_key=$has_key, len=$miss13_len)"
  fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
