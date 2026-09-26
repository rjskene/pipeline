#!/bin/bash
set -uo pipefail

# Doc-coupled dispatch-attribution guard (issue #1387).
#
# Cycle 16 dispatched twelve agents. EVERY agent-costs row landed with an empty
# `issue` field because each dispatch description named the issue as a bare
# integer (`plan-issue 1372`) instead of the attribution key the cost parser
# looks for (`plan-issue #1372`). Stage/role/model parsed fine; only the issue
# column was lost, so the loop's own cost report printed "no cost records" for
# all three issues. One description ALSO mis-staged a plan-evaluation dispatch as
# a planning dispatch (`plan evaluation for #N` -> stage=plan).
#
# The rule already existed, but only inside the PATH C leaf paragraph of
# skills/fullsend/SKILL.md. Prose in one branch does not govern the other
# branches, and nothing verified it. This test makes the rule VERIFIABLE:
#
#   (a) the canonical shape list is extracted FROM the hoisted block in
#       skills/fullsend/SKILL.md (doc-coupled: the doc is the source of truth,
#       so a doc edit that drops or paraphrases a shape turns this red);
#   (b) `<N>` -> 1387 and `<dir>` -> scripts;
#   (c) every shape is fed through BOTH producers — the bash
#       tu_stage/tu_role/tu_issue_from_description in
#       scripts/_token-usage-lib.sh AND the python
#       stage/role/issue_from_description in hooks/capture_agent_cost.py — and
#       both must agree with the pinned (stage, role, issue) triple;
#   (d) two NEGATIVE controls pin the cycle-16 defect verbatim, so the test
#       documents what it guards against.
#
# The parsers are NOT under test here and are NOT changed by #1387 — they
# already resolve every canonical shape correctly. The defect is entirely on the
# PRODUCING side (the descriptions the orchestrator authors), so what this test
# pins is the DOC that binds the producer.
#
# ANCHOR NOTE: the anchor is the literal `**Cost attribution key (#1387)` — NOT
# the bare `**Cost attribution`, which already matches the legacy PATH C leaf
# block (skills/fullsend/SKILL.md:586, header `**Cost attribution (#1299)`).
# The exactly-one-match assertion below is what keeps the extractor from binding
# that legacy block.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL="$REPO_ROOT/skills/fullsend/SKILL.md"
LIB="$REPO_ROOT/scripts/_token-usage-lib.sh"
HOOK="$REPO_ROOT/hooks/capture_agent_cost.py"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

summary() {
  echo ""
  echo "================================"
  echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
  echo "================================"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

for f in "$SKILL" "$LIB" "$HOOK"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: required file not found: $f" >&2
    exit 1
  fi
done

# shellcheck source=../scripts/_token-usage-lib.sh
source "$LIB"

# --- producers ------------------------------------------------------------
# bash side: scripts/_token-usage-lib.sh
bash_triple() {
  printf '%s/%s/%s' \
    "$(tu_stage_from_description "$1")" \
    "$(tu_role_from_description "$1")" \
    "$(tu_issue_from_description "$1")"
}

# python side: hooks/capture_agent_cost.py, imported by path (the hook is not on
# sys.path and its module name carries underscores).
PY_TRIPLE='
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cac", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
for d in sys.argv[2:]:
    print("%s/%s/%s" % (m.stage_from_description(d), m.role_from_description(d), m.issue_from_description(d)))
'
py_triple() { python3 -c "$PY_TRIPLE" "$HOOK" "$1"; }

# Assert BOTH producers resolve <desc> to <want> ("stage/role/issue").
assert_both_producers() {
  local label="$1" desc="$2" want="$3"
  local got_bash got_py
  got_bash="$(bash_triple "$desc")"
  got_py="$(py_triple "$desc")"
  inc
  if [ "$got_bash" = "$want" ]; then
    pass_msg "$label [bash]: '$desc' -> $want"
  else
    fail_msg "$label [bash]: '$desc' -> $got_bash (want $want)"
  fi
  inc
  if [ "$got_py" = "$want" ]; then
    pass_msg "$label [py]: '$desc' -> $want"
  else
    fail_msg "$label [py]: '$desc' -> $got_py (want $want)"
  fi
  inc
  if [ "$got_bash" = "$got_py" ]; then
    pass_msg "$label [parity]: bash and python agree ($got_bash)"
  else
    fail_msg "$label [parity]: bash='$got_bash' != python='$got_py'"
  fi
}

# ==========================================================================
# 1) NEGATIVE CONTROLS — the cycle-16 defect, pinned verbatim.
#    These are doc-independent parser probes: they are GREEN before and after
#    the fix, and exist so this file documents the failure it guards.
# ==========================================================================
echo "== #1387 negative controls (the cycle-16 defect) =="

# The mis-stage: `stage_from_description` resolves by (match-start, table-rank).
# A description whose FIRST token is `plan` matches the `plan` pattern at
# position 0, so plan-eval can never win — hence the positional rule that a
# dispatch description must BEGIN with its canonical stage token.
assert_both_producers "neg-mis-stage" "plan evaluation for #1387" "plan/single/1387"

# The bare-integer miss: every `issue_from_description` pattern requires the
# literal '#'. A bare integer yields "" — the entire cycle-16 failure.
assert_both_producers "neg-bare-integer" "plan-issue 1387" "plan/single/"

# ==========================================================================
# 2) ANCHOR — the hoisted canonical-shape block must exist exactly once.
# ==========================================================================
echo ""
echo "== #1387 hoisted canonical-shape block =="

ANCHOR='**Cost attribution key (#1387)'
LEGACY_ANCHOR='**Cost attribution (#1299)'

ANCHOR_COUNT=$(grep -cF -- "$ANCHOR" "$SKILL" || true)

# Extract from the bold header down to the first blank line OR the next
# line-leading `**` sub-heading, whichever comes first.
BLOCK=$(awk -v anchor="$ANCHOR" '
  !f && index($0, anchor) { f = 1; print; next }
  f && $0 ~ /^[[:space:]]*$/ { exit }
  f && $0 ~ /^[[:space:]]*\*\*/ { exit }
  f { print }
' "$SKILL")

inc
if [ "$ANCHOR_COUNT" -eq 1 ] && [ -n "$BLOCK" ]; then
  pass_msg "anchor: canonical-shape block extracted"
else
  if [ "$ANCHOR_COUNT" -eq 0 ]; then
    fail_msg "anchor: canonical-shape block extracted — the literal '$ANCHOR' is ABSENT from skills/fullsend/SKILL.md (the hoisted block does not exist yet)"
  elif [ "$ANCHOR_COUNT" -gt 1 ]; then
    fail_msg "anchor: canonical-shape block extracted — the literal '$ANCHOR' matches $ANCHOR_COUNT times; it MUST match exactly once or the extractor binds the wrong block"
  else
    fail_msg "anchor: canonical-shape block extracted — anchor found but the extracted block is EMPTY"
  fi
  # Negative control on the anchor itself: the legacy PATH C leaf block keeps its
  # own header, so the two anchors differ in exactly the property under test.
  inc
  if grep -qF -- "$LEGACY_ANCHOR" "$SKILL"; then
    pass_msg "anchor-control: the legacy '$LEGACY_ANCHOR' block is untouched and carries a DISTINCT header"
  else
    fail_msg "anchor-control: the legacy '$LEGACY_ANCHOR' header is gone — #1387 must PRESERVE the PATH C leaf statement"
  fi
  summary
fi

inc
if grep -qF -- "$LEGACY_ANCHOR" "$SKILL"; then
  pass_msg "anchor-control: the legacy '$LEGACY_ANCHOR' block is untouched and carries a DISTINCT header"
else
  fail_msg "anchor-control: the legacy '$LEGACY_ANCHOR' header is gone — #1387 must PRESERVE the PATH C leaf statement"
fi

# ==========================================================================
# 3) SHAPES — extract, substitute placeholders, feed both producers.
# ==========================================================================
# Collect every backticked span in the block, substitute the placeholders, and
# keep the ones that look like a dispatch description (start with a lowercase
# word, carry the literal '#1387'). A trailing ellipsis is normalized away —
# the shape list may write `... #<N> target=<dir>/ ...` for the free-form suffix.
SHAPE_PY='
import re, sys
txt = sys.argv[1]
out, seen = [], set()
for raw in re.findall(r"`([^`]+)`", txt):
    s = raw.replace("<N>", "1387").replace("<dir>", "scripts").strip()
    s = re.sub(r"(\s*(…|\.\.\.))+$", "", s).strip()
    if not s or "#1387" not in s:
        continue
    if not re.match(r"^[a-z]", s):
        continue
    if s not in seen:
        seen.add(s)
        out.append(s)
print("\n".join(out))
'
SHAPES=$(python3 -c "$SHAPE_PY" "$BLOCK")
SHAPE_COUNT=0
if [ -n "$SHAPES" ]; then
  SHAPE_COUNT=$(printf '%s\n' "$SHAPES" | grep -c . || true)
fi

# Floor re-pinned by #1420: the block listed 9 shapes while the split-role lane
# existed; with the two `split-role RED`/`GREEN` rows retired it lists 7.
inc
if [ "$SHAPE_COUNT" -ge 7 ]; then
  pass_msg "shapes: block yields $SHAPE_COUNT canonical descriptions (>= 7)"
else
  fail_msg "shapes: block yields only $SHAPE_COUNT canonical descriptions (need >= 7, one per live dispatch stage). Extracted: $(printf '%s' "$SHAPES" | tr '\n' '|')"
fi

shape_present() { printf '%s\n' "$SHAPES" | grep -qxF -- "$1"; }

# The canonical table. Every triple below was verified against BOTH producers by
# direct execution, not inference.
EXPECTED_SHAPES=(
  "classify-issue #1387|classify/single/1387"
  "plan-issue #1387|plan/single/1387"
  "evaluate-issue-plan #1387|plan-eval/single/1387"
  "execute-issue-plan #1387|execute/single/1387"
  "execute-issue-plan #1387 target=scripts/|execute/single/1387"
  "evaluate-issue-pr #1387|pr-eval/single/1387"
  "code review #1387|pr-eval/review/1387"
)

for row in "${EXPECTED_SHAPES[@]}"; do
  desc="${row%%|*}"
  want="${row##*|}"
  inc
  if shape_present "$desc"; then
    pass_msg "shape-listed: the block names '$desc'"
  else
    fail_msg "shape-listed: the block does NOT name '$desc'. Extracted: $(printf '%s' "$SHAPES" | tr '\n' '|')"
  fi
  assert_both_producers "shape-parse" "$desc" "$want"
done

# ==========================================================================
# 4) HISTORICAL SHAPES (#1420) — the split-role RED/GREEN lane is retired, so the
#    doc block no longer PRESCRIBES these two descriptions. Both producers must
#    still PARSE them, because agent-costs.jsonl rows captured while the lane
#    existed are still priced by scripts/cost-latency-report.sh and the
#    `--tokenomics` role-split table. Parser-only: no `shape-listed` assertion.
# ==========================================================================
echo ""
echo "== #1420 historical shapes (retired lane, still priced) =="

HISTORICAL_SHAPES=(
  "execute-issue-plan #1387 split-role RED|execute/red/1387"
  "execute-issue-plan #1387 split-role GREEN|execute/green/1387"
)

for row in "${HISTORICAL_SHAPES[@]}"; do
  desc="${row%%|*}"
  want="${row##*|}"
  assert_both_producers "shape-parse-historical" "$desc" "$want"
  # Negative control: the doc block must NOT name a retired shape — a plan that
  # reintroduced the lane would show up here first.
  inc
  if shape_present "$desc"; then
    fail_msg "shape-absent: the block still names '$desc' (#1420 retired the split-role lane)"
  else
    pass_msg "shape-absent: the block no longer names '$desc'"
  fi
done

summary
