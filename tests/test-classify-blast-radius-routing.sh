#!/bin/bash
set -euo pipefail

# Static-grep tests for the blast-radius B→D routing rule (#707): the rule, the
# deterministic non-test-source count, the ≤2-files/single-module threshold, the
# `fix(`-applicability clause, the high-uncertainty carve-out (the protected
# axis), the strong-prior-not-override clause, the mined exemplars, the worked
# high-uncertainty counter-example, the create-issues cross-ref fix, and the
# acceptance-gate discharge. All assertions inspect skills/classify-issue/SKILL.md
# (the rule) and skills/create-issues/SKILL.md (the cross-ref).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_FILE="$SCRIPT_DIR/../skills/classify-issue/SKILL.md"
SKILL2="$SCRIPT_DIR/../skills/create-issues/SKILL.md"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SKILL_FILE" ]; then
  echo "ERROR: classify-issue SKILL.md not found at $SKILL_FILE" >&2
  exit 1
fi
if [ ! -f "$SKILL2" ]; then
  echo "ERROR: create-issues SKILL.md not found at $SKILL2" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Slice the blast-radius subsection: from `#### Blast-radius B→D` to the next
# top-level `## ` heading (`## How classification runs`).
SLICE="$WORKDIR/blast.md"
awk '
  /^#### Blast-radius B→D/ { inblock = 1 }
  inblock && /^## / { inblock = 0 }
  inblock { print }
' "$SKILL_FILE" > "$SLICE"

if [ ! -s "$SLICE" ]; then
  echo "ERROR: could not slice blast-radius subsection from SKILL.md" >&2
  # Don't exit; let the assertions FAIL loudly.
fi

# --- Test 1: rule presence (Blast-radius + Affected areas + D on one line) ---
# Exclude `#`-heading lines so this asserts the rule BODY, not the subsection
# heading (which trivially carries all three tokens via "B→D"/"Affected areas").
echo "Test 1: rule body line names Blast-radius, Affected areas, and PATH D"
inc
if awk '/^#/ { next } /Blast-radius/ && /Affected areas/ && /D/ { f = 1 } END { exit (f ? 0 : 1) }' "$SLICE"; then
  pass_msg "rule body line co-occurs Blast-radius + Affected areas + D"
else
  fail_msg "no rule body line co-occurring Blast-radius + Affected areas + D"
fi

# --- Test 2: deterministic counting clause (non-test source, exclude tests/+fixtures/) ---
echo "Test 2: non-test source count excludes tests/ and fixtures/"
inc
if grep -qF "non-test source" "$SLICE" && grep -qF "tests/" "$SLICE" && grep -qF "fixtures/" "$SLICE"; then
  pass_msg "count is non-test source, excludes tests/ and fixtures/"
else
  fail_msg "missing non-test source / tests/ / fixtures/ exclusion"
fi

# --- Test 3: threshold clause (≤ 2 source files + single top-level module) ---
echo "Test 3: threshold ≤ 2 source files + single top-level module co-occur"
inc
if awk '/≤ 2/ && /single top-level module/ { f = 1 } END { exit (f ? 0 : 1) }' "$SLICE"; then
  pass_msg "≤ 2 and single top-level module co-occur on the rule"
else
  fail_msg "no line co-occurring ≤ 2 and single top-level module"
fi

# --- Test 4: fix(-applicability clause (feat( NOT auto-down-routed) ---
echo "Test 4: rule applies to fix( only; feat( is NOT auto-down-routed"
inc
if grep -qF 'fix(' "$SLICE" \
   && awk '/feat\(/ && (/NEVER/ || /NOT/ || /never/ || /not/) { f = 1 } END { exit (f ? 0 : 1) }' "$SLICE"; then
  pass_msg "fix( gate present; feat( explicitly NOT auto-down-routed"
else
  fail_msg "missing fix(-applicability clause excluding feat("
fi

# --- Test 4b: high-uncertainty CARVE-OUT (the protected axis) ---
echo "Test 4b: high-uncertainty carve-out suppresses the down-route"
SIGNALS=(concurrency race lock deadlock security auth crypto migration data-loss)
missing_signal=""
for sig in "${SIGNALS[@]}"; do
  grep -qiF "$sig" "$SLICE" || missing_signal="$missing_signal $sig"
done
inc
if [ -z "$missing_signal" ]; then
  pass_msg "carve-out names all high-uncertainty signals"
else
  fail_msg "carve-out missing signal(s):$missing_signal"
fi
inc
if awk '/label/ && (/security/ || /concurrency/) { f = 1 } END { exit (f ? 0 : 1) }' "$SLICE"; then
  pass_msg "label-based trigger ties to security/concurrency"
else
  fail_msg "no label trigger co-occurring with security/concurrency"
fi
inc
if awk '/[Cc]arve-out/ && (/SUPPRESS/ || /suppress/ || /stays B/ || /NOT/) { f = 1 } END { exit (f ? 0 : 1) }' "$SLICE"; then
  pass_msg "carve-out line carries a suppression verb (suppress/stays B/NOT)"
else
  fail_msg "carve-out line missing suppression verb"
fi

# --- Test 5: strong-prior-not-override clause ---
echo "Test 5: rule is a strong prior, not an override of the body marker"
inc
if grep -qF "strong prior" "$SLICE" && grep -qF '<!-- pipeline:path=D -->' "$SLICE"; then
  pass_msg "strong prior; body marker remains authoritative"
else
  fail_msg "missing strong-prior / body-marker non-override clause"
fi

# --- Test 6: mined exemplar table (#691/#667/#656 D; #698 B boundary, 3 files) ---
echo "Test 6: exemplar table routes #691/#667/#656 to D and #698 to B (boundary)"
for ex in '#691' '#667' '#656'; do
  inc
  if awk -v e="$ex" '$0 ~ e && /\| D \|/ { f = 1 } END { exit (f ? 0 : 1) }' "$SLICE"; then
    pass_msg "exemplar $ex routes to D"
  else
    fail_msg "exemplar $ex not routed to D"
  fi
done
inc
if awk '/#698/ && /B/ && /boundary/ && /3/ { f = 1 } END { exit (f ? 0 : 1) }' "$SLICE"; then
  pass_msg "exemplar #698 is the stays-B boundary (3 source files)"
else
  fail_msg "exemplar #698 missing B/boundary/3 framing"
fi

# --- Test 6b: worked high-uncertainty counter-example (small concurrency fix → B) ---
echo "Test 6b: worked counter-example — small concurrency fix( routes B not D"
inc
if awk '/fix\(/ && (/concurrency/ || /race/) && /B/ && (/carve-out/ || /suppress/ || /SUPPRESS/ || /NOT D/) { f = 1 } END { exit (f ? 0 : 1) }' "$SLICE"; then
  pass_msg "counter-example: small concurrency fix( held in B by the carve-out"
else
  fail_msg "no worked counter-example routing a small concurrency fix( to B"
fi

# --- Test 7: create-issues cross-ref fix (dangling string gone; live anchor present) ---
echo "Test 7: create-issues drops dead cross-ref, points at the live anchor"
inc
if ! grep -qF "Authoring guide for PATH D candidates" "$SKILL2"; then
  pass_msg "dangling 'Authoring guide for PATH D candidates' removed"
else
  fail_msg "dangling 'Authoring guide for PATH D candidates' still present"
fi
inc
if grep -qF "Blast-radius" "$SKILL2"; then
  pass_msg "create-issues references the live Blast-radius anchor"
else
  fail_msg "create-issues missing live Blast-radius anchor reference"
fi

# --- Test 8: acceptance-gate discharge derived from the carve-out ---
echo "Test 8: acceptance gate discharged by the carve-out, not the fix(/feat( split"
inc
if awk '/[Aa]cceptance/ && (/carve-out/ || /high-uncertainty/) && (/suppress/ || /SUPPRESS/) { f = 1 } END { exit (f ? 0 : 1) }' "$SLICE"; then
  pass_msg "acceptance discharge cites the carve-out / high-uncertainty suppression"
else
  fail_msg "acceptance discharge not tied to the carve-out"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
