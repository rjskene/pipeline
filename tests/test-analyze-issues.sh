#!/bin/bash
set -uo pipefail

export PIPELINE_LOGS_ENABLED=true
#
# Tests for scripts/analyze-issues.sh — the Stage 1 deterministic shortlist
# generator backing /pipeline:status --analyze (issue #138; renamed from
# /pipeline:run --analyze in #763, with /pipeline:run kept as a deprecated alias).
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
  if [ "$keys" = "duplicate_pairs,missing_label_candidates,supersession_candidates,tracker_fits" ]; then
    pass_msg "scenario 6: output keys are duplicate_pairs,missing_label_candidates,supersession_candidates,tracker_fits"
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

# --- Scenario 8: same-tracker siblings excluded from duplicate_pairs ---
inc_scenario "Scenario 8: same-tracker siblings excluded from duplicate_pairs (fixture A)"
FIX8="$TMP/fix8"; mkdir -p "$FIX8"
cat > "$FIX8/issues.json" <<'J'
[
  {"number":70,"title":"epic(spawn): rollout","body":"## Rollout sequence\n- [ ] **#71 — refactor argv\n- [ ] **#72 — argv parser tidy\n","labels":[{"name":"tracker"}]},
  {"number":71,"title":"feat(spawn): refactor argv parsing","body":"Refactor the argv parsing for spawn-claude.","labels":[]},
  {"number":72,"title":"fix(spawn): argv parser flakiness","body":"argv parser is flaky during spawn-claude invocations.","labels":[]}
]
J
cat > "$FIX8/issue-70.json" <<'J'
{"body":"## Rollout sequence\n- [ ] **#71 — refactor argv\n- [ ] **#72 — argv parser tidy\n"}
J
out8=$(run_helper "$FIX8" 2>&1)
shortlist8=$(echo "$out8" | tail -n 1)
if [ -f "$shortlist8" ]; then
  pair_71_72=$(jq -r '[.duplicate_pairs[] | select((.a == 71 and .b == 72) or (.a == 72 and .b == 71))] | length' "$shortlist8")
  if [ "$pair_71_72" = "0" ]; then
    pass_msg "scenario 8: (71,72) NOT in duplicate_pairs (same-tracker siblings)"
  else
    fail_msg "scenario 8: (71,72) NOT in duplicate_pairs (got $pair_71_72)"
    jq '.duplicate_pairs' "$shortlist8" | sed 's/^/      /'
  fi
fi

# --- Scenario 9: already-in-rollout issue NOT re-flagged as tracker_fit (fixture B) ---
inc_scenario "Scenario 9: already-in-rollout excluded from tracker_fits (fixture B)"
FIX9="$TMP/fix9"; mkdir -p "$FIX9"
cat > "$FIX9/issues.json" <<'J'
[
  {"number":80,"title":"epic(redline): rollout","body":"## Rollout sequence\n- [ ] **#81 — first child\n","labels":[{"name":"tracker"}]},
  {"number":81,"title":"feat(redline): first child","body":"Child of #80 — references parent tracker #80 for context.","labels":[]}
]
J
cat > "$FIX9/issue-80.json" <<'J'
{"body":"## Rollout sequence\n- [ ] **#81 — first child\n"}
J
out9=$(run_helper "$FIX9" 2>&1)
shortlist9=$(echo "$out9" | tail -n 1)
if [ -f "$shortlist9" ]; then
  fit_81_80=$(jq -r '[.tracker_fits[] | select(.issue == 81 and .tracker == 80)] | length' "$shortlist9")
  if [ "$fit_81_80" = "0" ]; then
    pass_msg "scenario 9: (81,80) NOT in tracker_fits (already in rollout)"
  else
    fail_msg "scenario 9: (81,80) NOT in tracker_fits (got $fit_81_80)"
    jq '.tracker_fits' "$shortlist9" | sed 's/^/      /'
  fi
fi

# --- Scenario 10: cross-tracker siblings still surfaced in duplicate_pairs (fixture C) ---
inc_scenario "Scenario 10: cross-tracker siblings still surfaced (fixture C)"
FIX10="$TMP/fix10"; mkdir -p "$FIX10"
cat > "$FIX10/issues.json" <<'J'
[
  {"number":90,"title":"epic(spawn): rollout one","body":"## Rollout sequence\n- [ ] **#91 — refactor argv parsing\n","labels":[{"name":"tracker"}]},
  {"number":92,"title":"epic(spawn): rollout two","body":"## Rollout sequence\n- [ ] **#93 — argv parser flakiness fix\n","labels":[{"name":"tracker"}]},
  {"number":91,"title":"feat(spawn): refactor argv parsing","body":"Refactor the argv parsing for spawn-claude.","labels":[]},
  {"number":93,"title":"fix(spawn): argv parser flakiness","body":"argv parser is flaky during spawn-claude invocations.","labels":[]}
]
J
cat > "$FIX10/issue-90.json" <<'J'
{"body":"## Rollout sequence\n- [ ] **#91 — refactor argv parsing\n"}
J
cat > "$FIX10/issue-92.json" <<'J'
{"body":"## Rollout sequence\n- [ ] **#93 — argv parser flakiness fix\n"}
J
out10=$(run_helper "$FIX10" 2>&1)
shortlist10=$(echo "$out10" | tail -n 1)
if [ -f "$shortlist10" ]; then
  pair_91_93=$(jq -r '[.duplicate_pairs[] | select((.a == 91 and .b == 93) or (.a == 93 and .b == 91))] | length' "$shortlist10")
  if [ "$pair_91_93" = "1" ]; then
    pass_msg "scenario 10: (91,93) IS in duplicate_pairs (different trackers)"
  else
    fail_msg "scenario 10: (91,93) IS in duplicate_pairs (got $pair_91_93)"
    jq '.duplicate_pairs' "$shortlist10" | sed 's/^/      /'
  fi
fi

# --- Scenario 11: orphan body-references tracker → fits tracker (fixture D) ---
inc_scenario "Scenario 11: orphan correctly fits tracker (fixture D)"
FIX11="$TMP/fix11"; mkdir -p "$FIX11"
cat > "$FIX11/issues.json" <<'J'
[
  {"number":110,"title":"epic(redline): rollout","body":"## Rollout sequence\n- [ ] **#111 — first child\n","labels":[{"name":"tracker"}]},
  {"number":111,"title":"feat(redline): first child","body":"x","labels":[]},
  {"number":112,"title":"feat(other): standalone task","body":"Related to #110 — needs grouping under that tracker.","labels":[]}
]
J
cat > "$FIX11/issue-110.json" <<'J'
{"body":"## Rollout sequence\n- [ ] **#111 — first child\n"}
J
out11=$(run_helper "$FIX11" 2>&1)
shortlist11=$(echo "$out11" | tail -n 1)
if [ -f "$shortlist11" ]; then
  fit_112_110=$(jq -r '[.tracker_fits[] | select(.issue == 112 and .tracker == 110 and .reason == "body-reference")] | length' "$shortlist11")
  if [ "$fit_112_110" = "1" ]; then
    pass_msg "scenario 11: (112,110) IS in tracker_fits (orphan body-reference)"
  else
    fail_msg "scenario 11: (112,110) IS in tracker_fits (got $fit_112_110)"
    jq '.tracker_fits' "$shortlist11" | sed 's/^/      /'
  fi
fi

# Helper for deterministic createdAt timestamps in fixtures (ISO 8601, hours-ago).
# date(1) on GNU/BSD diverges; this wraps the GNU form used in CI.
hours_ago_iso() {
  date -u -d "$1 hours ago" +%Y-%m-%dT%H:%M:%SZ
}

# --- Scenario 12: missing priority — issue with docs-only path label, no priority/* ---
inc_scenario "Scenario 12: missing-priority signal surfaces issue lacking priority/P*"
FIX12="$TMP/fix12"; mkdir -p "$FIX12"
CREATED_48H=$(hours_ago_iso 48)
cat > "$FIX12/issues.json" <<J
[
  {"number":200,"title":"feat(spawn): docs touch-up","body":"x","labels":[{"name":"docs-only"}],"createdAt":"$CREATED_48H"}
]
J
out12=$(run_helper "$FIX12" 2>&1)
shortlist12=$(echo "$out12" | tail -n 1)
if [ -f "$shortlist12" ]; then
  missing_len=$(jq '.missing_label_candidates | length' "$shortlist12" 2>/dev/null || echo "0")
  if [ "$missing_len" = "1" ]; then
    pass_msg "scenario 12: missing_label_candidates has exactly 1 row"
  else
    fail_msg "scenario 12: missing_label_candidates has 1 row (got $missing_len)"
  fi
  row=$(jq -c '.missing_label_candidates[0]' "$shortlist12" 2>/dev/null || echo "{}")
  if [ "$row" = '{"issue":200,"missing":["priority"]}' ]; then
    pass_msg "scenario 12: row == {\"issue\":200,\"missing\":[\"priority\"]}"
  else
    fail_msg "scenario 12: row content (got '$row')"
  fi
fi

# --- Scenario 13: missing both priority + path (regression-protect ordering) ---
inc_scenario "Scenario 13: missing-both surfaces with priority before path"
FIX13="$TMP/fix13"; mkdir -p "$FIX13"
cat > "$FIX13/issues.json" <<J
[
  {"number":201,"title":"feat(spawn): plain feature","body":"x","labels":[],"createdAt":"$CREATED_48H"}
]
J
out13=$(run_helper "$FIX13" 2>&1)
shortlist13=$(echo "$out13" | tail -n 1)
if [ -f "$shortlist13" ]; then
  miss13=$(jq -c '.missing_label_candidates[] | select(.issue == 201) | .missing' "$shortlist13" 2>/dev/null || echo "[]")
  # The state token is also expected because no pipeline-stage/classification
  # labels are present AND the issue is older than the 24h cutoff. Ordering
  # priority,path,state is pinned by the impl to keep this assertion stable.
  if [ "$miss13" = '["priority","path","state"]' ]; then
    pass_msg "scenario 13: row .missing == [priority,path,state] in deterministic order"
  else
    fail_msg "scenario 13: row .missing ordering (got '$miss13')"
  fi
fi

# --- Scenario 14: age gate — just-filed issue (2h ago) is suppressed ---
inc_scenario "Scenario 14: age-gate suppresses just-filed issues (< 24h)"
FIX14="$TMP/fix14"; mkdir -p "$FIX14"
CREATED_2H=$(hours_ago_iso 2)
cat > "$FIX14/issues.json" <<J
[
  {"number":202,"title":"feat(spawn): just filed","body":"x","labels":[],"createdAt":"$CREATED_2H"}
]
J
# Use the default cutoff (24h) — issue at 2h is too fresh.
out14=$(PIPELINE_ANALYZE_MIN_AGE_HOURS=24 run_helper "$FIX14" 2>&1)
shortlist14=$(echo "$out14" | tail -n 1)
if [ -f "$shortlist14" ]; then
  miss14_len=$(jq '.missing_label_candidates | length' "$shortlist14" 2>/dev/null || echo "999")
  if [ "$miss14_len" = "0" ]; then
    pass_msg "scenario 14: just-filed issue suppressed by 24h age gate"
  else
    fail_msg "scenario 14: just-filed issue suppressed (got $miss14_len rows)"
  fi
fi

# --- Scenario 15: tracker is exempt from missing-priority/path signal ---
inc_scenario "Scenario 15: trackers are exempt from missing-label signal"
FIX15="$TMP/fix15"; mkdir -p "$FIX15"
cat > "$FIX15/issues.json" <<J
[
  {"number":203,"title":"epic(pipeline): rollout","body":"## Rollout sequence\n","labels":[{"name":"tracker"}],"createdAt":"$CREATED_48H"}
]
J
cat > "$FIX15/issue-203.json" <<'J'
{"body":"## Rollout sequence\n"}
J
out15=$(run_helper "$FIX15" 2>&1)
shortlist15=$(echo "$out15" | tail -n 1)
if [ -f "$shortlist15" ]; then
  miss15_len=$(jq '.missing_label_candidates | length' "$shortlist15" 2>/dev/null || echo "999")
  if [ "$miss15_len" = "0" ]; then
    pass_msg "scenario 15: tracker not surfaced in missing_label_candidates"
  else
    fail_msg "scenario 15: tracker not surfaced (got $miss15_len rows)"
  fi
fi

# --- Scenario 16: brainstorm / later / human labels suppress the signal ---
inc_scenario "Scenario 16: brainstorm/later/human labels suppress missing-label signal"
FIX16="$TMP/fix16"; mkdir -p "$FIX16"
cat > "$FIX16/issues.json" <<J
[
  {"number":204,"title":"chore(x): brainstorm only","body":"x","labels":[{"name":"brainstorm"}],"createdAt":"$CREATED_48H"},
  {"number":205,"title":"chore(x): later only","body":"x","labels":[{"name":"later"}],"createdAt":"$CREATED_48H"},
  {"number":206,"title":"chore(x): human only","body":"x","labels":[{"name":"human"}],"createdAt":"$CREATED_48H"}
]
J
out16=$(run_helper "$FIX16" 2>&1)
shortlist16=$(echo "$out16" | tail -n 1)
if [ -f "$shortlist16" ]; then
  miss16_len=$(jq '.missing_label_candidates | length' "$shortlist16" 2>/dev/null || echo "999")
  if [ "$miss16_len" = "0" ]; then
    pass_msg "scenario 16: brainstorm/later/human labels all exempt"
  else
    fail_msg "scenario 16: brainstorm/later/human exemption (got $miss16_len rows)"
  fi
fi

# --- Scenario 17: zero-findings corpus emits an empty missing_label_candidates array ---
inc_scenario "Scenario 17: zero findings emits empty missing_label_candidates array"
FIX17="$TMP/fix17"; mkdir -p "$FIX17"
cat > "$FIX17/issues.json" <<J
[
  {"number":207,"title":"feat(a): one","body":"x","labels":[{"name":"priority/P2"},{"name":"docs-only"}],"createdAt":"$CREATED_48H"},
  {"number":208,"title":"feat(b): two","body":"x","labels":[{"name":"priority/P1"},{"name":"multi-task"}],"createdAt":"$CREATED_48H"},
  {"number":209,"title":"feat(c): three","body":"x","labels":[{"name":"priority/P0"},{"name":"docs-only"}],"createdAt":"$CREATED_48H"}
]
J
out17=$(run_helper "$FIX17" 2>&1)
shortlist17=$(echo "$out17" | tail -n 1)
if [ -f "$shortlist17" ]; then
  has_key=$(jq 'has("missing_label_candidates")' "$shortlist17" 2>/dev/null || echo "false")
  miss17_len=$(jq '.missing_label_candidates | length' "$shortlist17" 2>/dev/null || echo "999")
  if [ "$has_key" = "true" ] && [ "$miss17_len" = "0" ]; then
    pass_msg "scenario 17: missing_label_candidates key present and empty"
  else
    fail_msg "scenario 17: key present + empty (has_key=$has_key, len=$miss17_len)"
  fi
fi

# --- Scenario 18: malformed createdAt does not contaminate other rows ---
# Regression guard for review finding C1 — fromdateiso8601 aborts the whole
# jq pipeline on a non-ISO string, silently zeroing the entire array via the
# `${MISSING_JSON:-[]}` fallback at the final emit. Asserts that one rogue
# date in upstream data does NOT mask valid findings in the same payload.
inc_scenario "Scenario 18: malformed createdAt suppresses only its own row, not siblings"
FIX18="$TMP/fix18"; mkdir -p "$FIX18"
cat > "$FIX18/issues.json" <<J
[
  {"number":300,"title":"feat(x): valid missing","body":"x","labels":[{"name":"docs-only"}],"createdAt":"$CREATED_48H"},
  {"number":301,"title":"feat(x): malformed date","body":"x","labels":[],"createdAt":"not-a-date"}
]
J
out18=$(run_helper "$FIX18" 2>&1)
shortlist18=$(echo "$out18" | tail -n 1)
if [ -f "$shortlist18" ]; then
  # The valid issue (300) must still surface as a missing-priority candidate.
  valid_row=$(jq -c '.missing_label_candidates[] | select(.issue == 300)' "$shortlist18" 2>/dev/null || echo "{}")
  if [ "$valid_row" = '{"issue":300,"missing":["priority"]}' ]; then
    pass_msg "scenario 18: valid sibling row surfaces despite malformed peer"
  else
    fail_msg "scenario 18: valid sibling row (got '$valid_row')"
  fi
  # The malformed-date row (301) must be suppressed (age-unknown → suppress).
  bad_row=$(jq -c '.missing_label_candidates[] | select(.issue == 301)' "$shortlist18" 2>/dev/null || echo "")
  if [ -z "$bad_row" ]; then
    pass_msg "scenario 18: malformed-date row suppressed (age-unknown)"
  else
    fail_msg "scenario 18: malformed-date row should be suppressed (got '$bad_row')"
  fi
fi

# --- Scenario 19: CRLF-jq seam — tracker fits survive Windows CRLF jq (#1158) ---
# Git-for-Windows jq (msvcrt) emits \r\n on every output line. `tnum`/`inum` are
# read via `jq -r '.number'`; under CRLF jq `tnum="60\r"`, so the body-reference
# probe `grep -qE "#${tnum}([^0-9]|$)"` embeds a literal \r and the #50→#60 fit
# never emits (Scenario 4 breaks). Scope-match (Sc3) and already-in-rollout
# (Sc9) are CR-tolerant here (symmetric CR / awk numeric compare), so they still
# hold — the two `.number` strips must keep them green while restoring Sc4. A
# fake jq earlier on PATH reproduces the msvcrt CR faithfully on an LF-only host.
inc_scenario "Scenario 19: CRLF-jq seam — scope-match + body-reference + rollout-exclusion"

# shellcheck source=_lib/crlf-jq-seam.sh
source "$SCRIPT_DIR/_lib/crlf-jq-seam.sh"
CRLF_BIN19="$TMP/crlfbin"
run_helper_seam() {
  local fixture="$1"
  mkdir -p "$TMP/.claude/logs"
  ( cd "$TMP" && PATH="$CRLF_BIN19:$PATH" bash "$HELPER" --fixture "$fixture" )
}

if make_crlf_jq_bin "$CRLF_BIN19"; then
  # Sc3 fixture (scope-match): #99 fits #60 by conventional-commit scope.
  FIX19S="$TMP/fix19s"; mkdir -p "$FIX19S"
  cat > "$FIX19S/issues.json" <<'J'
[
  {"number":60,"title":"epic(pipeline): rollout","body":"## Rollout sequence\n- [ ] **#34 — child A\n- [x] **#35 — child B\n","labels":[{"name":"tracker"}]},
  {"number":34,"title":"feat(pipeline): child task A","body":"x","labels":[]},
  {"number":35,"title":"feat(pipeline): child task B","body":"x","labels":[]},
  {"number":99,"title":"feat(pipeline): polish thing","body":"Just polish.","labels":[]}
]
J
  cat > "$FIX19S/issue-60.json" <<'J'
{"body":"## Rollout sequence\n- [ ] **#34 — child A\n- [x] **#35 — child B\n"}
J
  out19s=$(run_helper_seam "$FIX19S" 2>&1)
  shortlist19s=$(echo "$out19s" | tail -n 1)
  if [ -f "$shortlist19s" ]; then
    m99=$(jq -r '[.tracker_fits[] | select(.issue == 99 and .tracker == 60 and .reason == "scope-match")] | length' "$shortlist19s" 2>/dev/null)
    if [ "$m99" = "1" ]; then
      pass_msg "CRLF-seam: #99 emits scope-match fit to #60 (Sc3 survives CRLF jq)"
    else
      fail_msg "CRLF-seam: #99 scope-match fit to #60 (matches=$m99)"
    fi
  else
    fail_msg "CRLF-seam: Sc3 shortlist missing (out=$out19s)"
  fi

  # Sc4 fixture (body-reference): #50 references #60 in its body.
  FIX19B="$TMP/fix19b"; mkdir -p "$FIX19B"
  cat > "$FIX19B/issues.json" <<'J'
[
  {"number":60,"title":"epic(pipeline): rollout","body":"## Rollout sequence\n- [ ] **#34 — child A\n","labels":[{"name":"tracker"}]},
  {"number":34,"title":"feat(pipeline): child task A","body":"x","labels":[]},
  {"number":50,"title":"feat(other): unrelated scope","body":"Related to #60 in the discussion.","labels":[]}
]
J
  cat > "$FIX19B/issue-60.json" <<'J'
{"body":"## Rollout sequence\n- [ ] **#34 — child A\n"}
J
  out19b=$(run_helper_seam "$FIX19B" 2>&1)
  shortlist19b=$(echo "$out19b" | tail -n 1)
  if [ -f "$shortlist19b" ]; then
    m50=$(jq -r '[.tracker_fits[] | select(.issue == 50 and .tracker == 60 and .reason == "body-reference")] | length' "$shortlist19b" 2>/dev/null)
    if [ "$m50" = "1" ]; then
      pass_msg "CRLF-seam: #50 emits body-reference fit to #60 (Sc4 survives CRLF jq)"
    else
      fail_msg "CRLF-seam: #50 body-reference fit to #60 (matches=$m50; CRLF \r in #tnum regex)"
    fi
  else
    fail_msg "CRLF-seam: Sc4 shortlist missing (out=$out19b)"
  fi

  # Sc9 fixture (already-in-rollout): #81 is a child of tracker #80 → no fit.
  FIX19R="$TMP/fix19r"; mkdir -p "$FIX19R"
  cat > "$FIX19R/issues.json" <<'J'
[
  {"number":80,"title":"epic(redline): rollout","body":"## Rollout sequence\n- [ ] **#81 — first child\n","labels":[{"name":"tracker"}]},
  {"number":81,"title":"feat(redline): first child","body":"Child of #80 — references parent tracker #80 for context.","labels":[]}
]
J
  cat > "$FIX19R/issue-80.json" <<'J'
{"body":"## Rollout sequence\n- [ ] **#81 — first child\n"}
J
  out19r=$(run_helper_seam "$FIX19R" 2>&1)
  shortlist19r=$(echo "$out19r" | tail -n 1)
  if [ -f "$shortlist19r" ]; then
    f81=$(jq -r '[.tracker_fits[] | select(.issue == 81 and .tracker == 80)] | length' "$shortlist19r" 2>/dev/null)
    if [ "$f81" = "0" ]; then
      pass_msg "CRLF-seam: (81,80) NOT in tracker_fits — already in rollout (Sc9 survives CRLF jq)"
    else
      fail_msg "CRLF-seam: (81,80) re-surfaced as a fit (got $f81; CRLF broke child-index lookup)"
    fi
  else
    fail_msg "CRLF-seam: Sc9 shortlist missing (out=$out19r)"
  fi
else
  fail_msg "CRLF-seam: fake-jq seam setup failed (non-vacuity guard)"
fi

# --- Scenario 20: CRLF-jq seam — scopeless issue NOT false-matched to scopeless tracker (#1165) ---
# Git-for-Windows jq (msvcrt) emits \r\n on every output line. Unlike `.number`
# (stripped at lines ~181/310), `.scope` is read via `jq -r '.scope'` WITHOUT a CR
# strip at the tracker-index boundary (line ~182) and the tracker-fits boundary
# (line ~311); `.body` is likewise unstripped at line ~312. When an issue AND a
# tracker are BOTH scope-less (title without a `verb(scope):` prefix), jq yields
# scope="" for each — but under CRLF jq the command substitution captures a lone
# `\r`. `[ -n "$iscope" ]` then reads TRUE (a CR is a non-empty string) and
# `[ "$iscope" = "$tscope" ]` compares $'\r' == $'\r' → a BOGUS scope-match fit.
# On LF (and after CR is stripped at the .scope/.body seam) both are empty, so
# `[ -n "" ]` is false and no fit emits. This asserts the false positive is gone.
inc_scenario "Scenario 20: CRLF-jq seam — scopeless issue not false-matched to scopeless tracker (#1165)"

if make_crlf_jq_bin "$CRLF_BIN19"; then
  FIX20="$TMP/fix20"; mkdir -p "$FIX20"
  cat > "$FIX20/issues.json" <<'J'
[
  {"number":400,"title":"Coordinate the umbrella rollout","body":"Umbrella tracker prose with no child references.","labels":[{"name":"tracker"}]},
  {"number":401,"title":"Investigate a flaky startup path","body":"Standalone task, no scope prefix and no tracker reference.","labels":[]}
]
J
  cat > "$FIX20/issue-400.json" <<'J'
{"body":"Umbrella tracker prose with no child references."}
J
  out20=$(run_helper_seam "$FIX20" 2>&1)
  shortlist20=$(echo "$out20" | tail -n 1)
  if [ -f "$shortlist20" ]; then
    bogus20=$(jq -r '[.tracker_fits[] | select(.issue == 401 and .tracker == 400 and .reason == "scope-match")] | length' "$shortlist20" 2>/dev/null)
    if [ "$bogus20" = "0" ]; then
      pass_msg "CRLF-seam: scopeless #401 NOT false-matched to scopeless tracker #400 (.scope CR stripped)"
    else
      fail_msg "CRLF-seam: scopeless #401 falsely scope-matched to #400 (got $bogus20; CR in .scope poisoned [ -n ]/string compare)"
      jq '.tracker_fits' "$shortlist20" | sed 's/^/      /'
    fi
  else
    fail_msg "CRLF-seam: Sc20 shortlist missing (out=$out20)"
  fi
else
  fail_msg "CRLF-seam: Sc20 fake-jq seam setup failed (non-vacuity guard)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
