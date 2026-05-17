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
  if [ "$keys" = "duplicate_pairs,tracker_fits" ]; then
    pass_msg "scenario 6: output keys are duplicate_pairs,tracker_fits"
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
