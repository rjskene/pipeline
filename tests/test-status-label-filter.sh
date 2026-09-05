#!/bin/bash
set -uo pipefail
#
# Golden + contract test for the `--label` filter on /pipeline:status (#1269).
#
# Two halves:
#   1. GOLDEN — pipe the fixture issues.json through
#      scripts/filter-issues-by-label.sh, rebuild the trackers map from
#      `--emit trackers`, then render through the UNCHANGED
#      scripts/render-status-table.sh and byte-compare to golden-redline.txt.
#      The renderer is NOT modified by this feature; the golden proves the
#      filtered table falls out of the shipped renderer.
#   2. CONTRACT LINT — skills/status/SKILL.md + docs/skills-api.md carry the
#      documented flag, and the pre-existing SKILL.md guard's BOTH halves
#      (banned anchors absent, required markers present) still hold.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FILTER="$REPO_ROOT/scripts/filter-issues-by-label.sh"
RENDERER="$REPO_ROOT/scripts/render-status-table.sh"
PARSE_CHILDREN="$REPO_ROOT/scripts/parse-tracker-children.sh"
FIX="$SCRIPT_DIR/fixtures/status-label-filter"
GOLDEN="$FIX/golden-redline.txt"
SKILL_MD="$REPO_ROOT/skills/status/SKILL.md"
STATUS_TABLE_REF="$REPO_ROOT/skills/status/references/status-table.md"
SKILLS_API="$REPO_ROOT/docs/skills-api.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); echo "    $2"; }
inc()      { TESTS=$((TESTS + 1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ----------------------------------------------------------------------
# Step 1 — FIXTURE PRE-CHECK (blocking)
# ----------------------------------------------------------------------
#
# Tripwire, not a deliverable. parse-tracker-children.sh:75 recognises ONLY
#   ^- \[[ x]\] \*\*#[0-9]+[[:space:]]*[-—]
# i.e. `- [ ] **#<N> — <text>**`. A loosely-written fixture parses to ZERO
# children, which drops every tracker: #901 would leak into the orphan rows
# and the footer counts would be wrong — and the golden would be captured
# against a mis-parsed fixture, baking the bug in. Hard-fail the whole file
# before any golden capture or comparison happens.
precheck_children() {
  local num="$1"
  jq -r --argjson n "$num" '.[] | select(.number == $n) | .body' "$FIX/issues.json" \
    | bash "$PARSE_CHILDREN" - \
    | tr '\n' ' ' \
    | sed -e 's/[[:space:]]*$//'
}

PRECHECK_OK=1
PRECHECK_DETAIL=""
for pair in "900:901 902" "910:911 912"; do
  t="${pair%%:*}"
  want="${pair#*:}"
  got=$(precheck_children "$t")
  if [ "$got" != "$want" ] || [ -z "$got" ]; then
    PRECHECK_OK=0
    PRECHECK_DETAIL="${PRECHECK_DETAIL}tracker #$t: want '$want', got '$got'; "
  fi
done

# The trackers.json bodies must be byte-identical to the issues.json bodies —
# otherwise the tracker map and the filter disagree about children.
for t in 900 910; do
  a=$(jq -r --argjson n "$t" '.[] | select(.number == $n) | .body' "$FIX/issues.json" | md5sum)
  b=$(jq -r --arg k "$t" '.[$k]' "$FIX/trackers.json" | md5sum)
  if [ "$a" != "$b" ]; then
    PRECHECK_OK=0
    PRECHECK_DETAIL="${PRECHECK_DETAIL}tracker #$t body differs between issues.json and trackers.json; "
  fi
done

inc
if [ "$PRECHECK_OK" -eq 1 ]; then
  pass_msg "1. fixture pre-check: rollout bullets parse and tracker bodies match across fixtures"
else
  fail_msg "1. fixture pre-check: rollout bullets parse and tracker bodies match across fixtures" \
    "$PRECHECK_DETAIL -- parse-tracker-children.sh:75 requires the strict form '- [ ] **#N — <text>**' (the ** and the trailing hyphen/em-dash are mandatory)."
  echo ""
  echo "=========================================================="
  echo "ABORT: fixture pre-check failed — the golden must never be"
  echo "captured or compared against a mis-parsed fixture."
  echo "TOTAL: $TESTS  PASS: $PASS  FAIL: $FAIL"
  echo "=========================================================="
  exit 1
fi

# ----------------------------------------------------------------------
# Step 2 — filtered render, byte-compared to the golden
# ----------------------------------------------------------------------
#
# HOST-INDEPENDENCE IS MANDATORY. render-status-table.sh sources
# "$PIPELINE_PROJECT_ROOT/pipeline.config" (L122–125) BEFORE its
# `: "${VAR:=default}"` block (L127–136), and pipeline.config assigns
# UNCONDITIONALLY (e.g. PIPELINE_LABELS_LATER="later"), so a host config
# OVERWRITES anything this test exports. Point PIPELINE_PROJECT_ROOT at a
# config-free mktemp -d so the baked defaults apply and the `att` column
# resolves to 0. `--today` is pinned so the age column is deterministic.
CFG_FREE=$(mktemp -d)

run_render() {
  env -u PIPELINE_BASE_BRANCH \
      -u PIPELINE_LABELS_EXCLUDED -u PIPELINE_LABELS_LATER \
      -u PIPELINE_LABELS_HUMAN -u PIPELINE_LABELS_BRAINSTORM \
      -u PIPELINE_NEXT_LABEL -u PIPELINE_NEXT_BRANCH \
      -u CLAUDE_PLUGIN_ROOT \
      PIPELINE_PROJECT_ROOT="$CFG_FREE" \
      bash "$RENDERER" --issues "$1" --trackers "$2" --today 2026-05-21
}

FILTERED_ISSUES="$TMP/filtered-issues.json"
FILTERED_TRACKERS="$TMP/filtered-trackers.json"

bash "$FILTER" --issues "$FIX/issues.json" --label redline \
  >"$FILTERED_ISSUES" 2>"$TMP/ferr"; FILTER_RC=$?
SURVIVING_TRACKERS=$(bash "$FILTER" --issues "$FIX/issues.json" --label redline \
  --emit trackers 2>>"$TMP/ferr"); EMIT_RC=$?

# Rebuild the trackers map from the SURVIVING set only. Dropping a tracker
# from issues.json alone is not enough — the map supplies the bodies the
# renderer uses to claim children via IS_CHILD, so a hidden tracker would
# still suppress its children from the orphan rows.
echo '{}' > "$FILTERED_TRACKERS"
for t in $SURVIVING_TRACKERS; do
  next=$(jq --arg k "$t" --slurpfile all "$FIX/trackers.json" \
    '. + {($k): $all[0][$k]}' "$FILTERED_TRACKERS")
  printf '%s' "$next" > "$FILTERED_TRACKERS"
done

inc
if [ "$FILTER_RC" -eq 0 ] && [ "$EMIT_RC" -eq 0 ]; then
  pass_msg "2. filter + --emit trackers assembly exits 0"
else
  fail_msg "2. filter + --emit trackers assembly exits 0" \
    "filter rc=$FILTER_RC, --emit trackers rc=$EMIT_RC, stderr=$(cat "$TMP/ferr")"
fi

inc
if [ -f "$GOLDEN" ]; then
  pass_msg "3. golden fixture tests/fixtures/status-label-filter/golden-redline.txt exists"
else
  fail_msg "3. golden fixture tests/fixtures/status-label-filter/golden-redline.txt exists" \
    "missing: $GOLDEN — capture it from the UNCHANGED renderer (PIPELINE_PROJECT_ROOT=\$(mktemp -d), --today 2026-05-21) and hand-verify before committing."
fi

run_render "$FILTERED_ISSUES" "$FILTERED_TRACKERS" >"$TMP/render1" 2>"$TMP/rerr1"; RENDER_RC=$?

inc
if [ "$RENDER_RC" -eq 0 ]; then
  pass_msg "4. unchanged renderer exits 0 on the filtered input"
else
  fail_msg "4. unchanged renderer exits 0 on the filtered input" \
    "rc=$RENDER_RC, stderr=$(cat "$TMP/rerr1")"
fi

inc
if [ -f "$GOLDEN" ] && diff -u "$GOLDEN" "$TMP/render1" >"$TMP/diff" 2>&1; then
  pass_msg "5. filtered render byte-matches golden-redline.txt"
else
  fail_msg "5. filtered render byte-matches golden-redline.txt" \
    "$(head -40 "$TMP/diff" 2>/dev/null || echo "diff failed: $GOLDEN absent")"
fi

# 6. Determinism — a second identical invocation produces identical bytes.
inc
run_render "$FILTERED_ISSUES" "$FILTERED_TRACKERS" >"$TMP/render2" 2>"$TMP/rerr2"; RENDER_RC2=$?
if [ "$RENDER_RC" -eq 0 ] && [ "$RENDER_RC2" -eq 0 ] && cmp -s "$TMP/render1" "$TMP/render2"; then
  pass_msg "6. filtered render is deterministic across re-runs"
else
  fail_msg "6. filtered render is deterministic across re-runs" \
    "rc1=$RENDER_RC rc2=$RENDER_RC2; $(diff -u "$TMP/render1" "$TMP/render2" 2>&1 | head -20)"
fi

# ----------------------------------------------------------------------
# Contract lint — skills/status/SKILL.md + docs/skills-api.md
# ----------------------------------------------------------------------

section_window() {
  # $1 = file, $2 = the H2 heading line, matched as a LITERAL prefix (awk -v
  # unescapes backslashes, so a regex with \( … \) would warn and degrade).
  awk -v head="$2" '
    index($0, head) == 1 { grab=1; print; next }
    grab && /^## / { exit }
    grab { print }
  ' "$1"
}

if [ ! -f "$SKILL_MD" ]; then
  inc
  fail_msg "skills/status/SKILL.md exists" "missing: $SKILL_MD"
else
  LABEL_WINDOW=$(section_window "$SKILL_MD" '## Label filter mode (--label)')

  # (a) H2 section present
  inc
  if grep -qE '^## Label filter mode \(--label\)' "$SKILL_MD"; then
    pass_msg "a. SKILL.md has an H2 '## Label filter mode (--label)'"
  else
    fail_msg "a. SKILL.md has an H2 '## Label filter mode (--label)'" \
      "heading not found in $SKILL_MD"
  fi

  # (b) the section names the filter script
  inc
  if printf '%s\n' "$LABEL_WINDOW" | grep -qF 'filter-issues-by-label.sh'; then
    pass_msg "b. the --label section names filter-issues-by-label.sh"
  else
    fail_msg "b. the --label section names filter-issues-by-label.sh" \
      "filter-issues-by-label.sh not referenced inside the '## Label filter mode (--label)' window"
  fi

  # (c) union/OR semantics stated AND contrasted with `gh issue list --label`
  inc
  if printf '%s\n' "$LABEL_WINDOW" | grep -qiE 'union|\bOR\b' \
     && printf '%s\n' "$LABEL_WINDOW" | grep -qF 'gh issue list --label'; then
    pass_msg "c. the --label section states union/OR semantics and contrasts gh issue list --label (AND)"
  else
    fail_msg "c. the --label section states union/OR semantics and contrasts gh issue list --label (AND)" \
      "the surprising part of the flag is the divergence from gh's AND semantics — it must be spelled out"
  fi

  # (d) per-invocation only, no pipeline.config default
  inc
  if printf '%s\n' "$LABEL_WINDOW" | grep -qiE 'per-invocation' \
     && printf '%s\n' "$LABEL_WINDOW" | grep -qiE 'no (persistent )?.?pipeline\.config|no config default|pipeline\.config default'; then
    pass_msg "d. the --label section states the flag is per-invocation with NO pipeline.config default"
  else
    fail_msg "d. the --label section states the flag is per-invocation with NO pipeline.config default" \
      "expected the --analyze/--keep-trees precedent wording (per-invocation only; no pipeline.config default)"
  fi

  # (e) Shortcuts table has a --label row
  inc
  if grep -qE '^\|.*--label.*\|' "$SKILL_MD"; then
    pass_msg "e. the Shortcuts table has a --label row"
  else
    fail_msg "e. the Shortcuts table has a --label row" "no table row mentioning --label in $SKILL_MD"
  fi

  # (f) Step 3's assembly block pipes through the filter BEFORE the render
  #     input is handed over, and the reference contract mirrors it.
  inc
  fetch_line=$(grep -nF 'gh issue list --repo "$PIPELINE_REPO" --state open' "$SKILL_MD" | head -1 | cut -d: -f1)
  filter_line=$(grep -nF 'filter-issues-by-label.sh' "$SKILL_MD" | tail -1 | cut -d: -f1)
  ref_ok=0
  [ -f "$STATUS_TABLE_REF" ] && grep -qF 'filter-issues-by-label.sh' "$STATUS_TABLE_REF" && ref_ok=1
  if [ -n "$fetch_line" ] && [ -n "$filter_line" ] \
     && [ "$filter_line" -gt "$fetch_line" ] && [ "$ref_ok" -eq 1 ]; then
    pass_msg "f. Step 3's assembly filters the fetched set before render, and references/status-table.md mirrors it"
  else
    fail_msg "f. Step 3's assembly filters the fetched set before render, and references/status-table.md mirrors it" \
      "gh-fetch line='$fetch_line', filter line='$filter_line' (must come after the fetch), references/status-table.md mirrors filter=$ref_ok"
  fi

  # (g) --table composes with --label
  inc
  TABLE_WINDOW=$(section_window "$SKILL_MD" '## Table-only mode (--table)')
  if printf '%s\n' "$TABLE_WINDOW" | grep -qF -- '--label'; then
    pass_msg "g. the --table section states --label composes with it"
  else
    fail_msg "g. the --table section states --label composes with it" \
      "no --label mention inside the '## Table-only mode (--table)' window"
  fi

  # (i) BANNED-ANCHOR regression control — duplicated from
  #     tests/test-render-status-table-skill-md-invocation.sh so a bad Step 3
  #     rewiring surfaces in THIS run too. Green on the base branch; must STAY
  #     green. Use lowercase "tracker rows" / "orphan rows" in prose instead.
  BANNED_ANCHORS=(
    'EPICS'
    'ORPHANS'
    'NOTES (non-default)'
    'RELEASE PRs'
    'PIPELINE STATUS —'
    '(all children closed — pending auto-close)'
  )
  banned_hits=""
  for anchor in "${BANNED_ANCHORS[@]}"; do
    if grep -qF "$anchor" "$SKILL_MD"; then
      banned_hits="${banned_hits}[$anchor] "
    fi
  done
  inc
  if [ -z "$banned_hits" ]; then
    pass_msg "i. banned-anchor control: SKILL.md still contains none of the six render-layout literals"
  else
    fail_msg "i. banned-anchor control: SKILL.md still contains none of the six render-layout literals" \
      "leaked literals: $banned_hits"
  fi

  # (j) REQUIRED-MARKER regression control — the same pre-existing guard also
  #     asserts these three are PRESENT. Task 4's Step 3 rewiring must be
  #     strictly ADDITIVE so they survive verbatim.
  REQUIRED_MARKERS=(
    'TRACKERS_JSON=$(mktemp)'
    'BEGIN-TRACKER-FILTER'
    'scripts/render-status-table.sh'
  )
  missing_markers=""
  for marker in "${REQUIRED_MARKERS[@]}"; do
    if ! grep -qF "$marker" "$SKILL_MD"; then
      missing_markers="${missing_markers}[$marker] "
    fi
  done
  inc
  if [ -z "$missing_markers" ]; then
    pass_msg "j. required-marker control: SKILL.md still contains all three markers the pre-existing guard requires"
  else
    fail_msg "j. required-marker control: SKILL.md still contains all three markers the pre-existing guard requires" \
      "missing: $missing_markers — the Step 3 rewiring must be strictly additive"
  fi
fi

# (h) docs/skills-api.md — master-table row + `### status` bullet
if [ ! -f "$SKILLS_API" ]; then
  inc
  fail_msg "docs/skills-api.md exists" "missing: $SKILLS_API"
else
  inc
  if grep -E '^\|.*/pipeline:status.*\|' "$SKILLS_API" | grep -qF -- '--label'; then
    pass_msg "h1. docs/skills-api.md master-table /pipeline:status row lists --label"
  else
    fail_msg "h1. docs/skills-api.md master-table /pipeline:status row lists --label" \
      "row: $(grep -E '^\|.*/pipeline:status.*\|' "$SKILLS_API" | head -1)"
  fi

  inc
  STATUS_SUBSECTION=$(awk '
    /^### status$/ { grab=1; next }
    grab && /^### / { exit }
    grab { print }
  ' "$SKILLS_API")
  if printf '%s\n' "$STATUS_SUBSECTION" | grep -qE '^- .*--label'; then
    pass_msg "h2. docs/skills-api.md '### status' subsection has a --label bullet"
  else
    fail_msg "h2. docs/skills-api.md '### status' subsection has a --label bullet" \
      "no '- ... --label ...' bullet under '### status'"
  fi
fi

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
echo ""
echo "=========================================================="
echo "TOTAL: $TESTS  PASS: $PASS  FAIL: $FAIL"
echo "=========================================================="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
