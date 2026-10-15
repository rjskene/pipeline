#!/bin/bash
set -euo pipefail

# #1485 — the classify stage folds into plan-issue. The classification
# procedure lives ONCE in skills/plan-issue/references/classification.md;
# plan-issue step 3a runs it inline (consume a fresh trusted `## Classification`
# comment, or produce one + apply the path label), and the standalone
# classify-issue skill is a thin entry that defers to the same reference.
#
# Static prose-contract assertions (same idiom as
# tests/test-classify-applies-label.sh) plus an executable check of the
# pinned decision order: the MARKER-PARSE, HINT-PARSE and PATH-DECIDE
# sentinel blocks are extracted from the reference and run in sequence.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REF="$SCRIPT_DIR/../skills/plan-issue/references/classification.md"
PLAN="$SCRIPT_DIR/../skills/plan-issue/SKILL.md"
CLS="$SCRIPT_DIR/../skills/classify-issue/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$REF" ]; then
  echo "  FAIL: shared classification reference not found at $REF"
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# --- (a) reference contents -------------------------------------------------
echo "(a) skills/plan-issue/references/classification.md"
for tok in '## Classification' 'recommended_path:' \
           '# BEGIN-LABEL-APPLY' '# END-LABEL-APPLY' \
           '# BEGIN-PATH-MARKER-PARSE' '# BEGIN-PATH-HINT-PARSE' \
           '# BEGIN-CLASS-FRESHNESS' '# END-CLASS-FRESHNESS' \
           '# BEGIN-PATH-DECIDE' '# END-PATH-DECIDE' \
           'marker ⇒ hint ⇒ fresh comment ⇒ rule table ⇒ B'; do
  inc
  if grep -qF -- "$tok" "$REF"; then
    pass_msg "reference contains '$tok'"
  else
    fail_msg "reference missing '$tok'"
  fi
done

# --- (b) plan-issue step 3a -------------------------------------------------
echo "(b) skills/plan-issue/SKILL.md step 3a"
STEP3A="$WORKDIR/step3a.md"
awk '/^3a\./ { inblock = 1 } /^3b\./ { inblock = 0 } inblock { print }' "$PLAN" > "$STEP3A"
for tok in 'references/classification.md' '## Classification' 'BEGIN-LABEL-APPLY' \
           'createdAt >= issue.updatedAt' 'skip when fresh' \
           'post the `## Classification` comment and apply the path label'; do
  inc
  if grep -qF -- "$tok" "$STEP3A"; then
    pass_msg "step 3a contains '$tok'"
  else
    fail_msg "step 3a missing '$tok'"
  fi
done
inc
if grep -qF 'elif echo "$LABELS" | grep -qx "quick-fix"' "$STEP3A"; then
  fail_msg "step 3a still carries the old label if/elif chain"
else
  pass_msg "old label if/elif chain removed from step 3a"
fi

# --- (c) classify-issue thinned ---------------------------------------------
echo "(c) skills/classify-issue/SKILL.md is a thin standalone entry"
for tok in 'plan-issue/references/classification.md' '## Classification' \
           'is-trusted-author' 'TERSENESS:'; do
  inc
  if grep -qF -- "$tok" "$CLS"; then
    pass_msg "classify-issue contains '$tok'"
  else
    fail_msg "classify-issue missing '$tok'"
  fi
done
for tok in '# BEGIN-LABEL-APPLY' '| Otherwise | B | medium |'; do
  inc
  if grep -qF -- "$tok" "$CLS"; then
    fail_msg "classify-issue still inlines moved content '$tok'"
  else
    pass_msg "classify-issue no longer inlines '$tok'"
  fi
done

# --- executable decision order ----------------------------------------------
echo "Executable: MARKER-PARSE -> HINT-PARSE -> PATH-DECIDE"
extract() {
  awk -v b="# BEGIN-$1" -v e="# END-$1" '
    index($0, b) { inblock = 1 }
    inblock { print }
    index($0, e) { inblock = 0 }
  ' "$REF"
}
DECIDE="$WORKDIR/decide.sh"
{ extract PATH-MARKER-PARSE; extract PATH-HINT-PARSE; extract PATH-DECIDE; } > "$DECIDE"

STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
printf '#!/bin/bash\nexit 0\n' > "$STUB_DIR/gh"
chmod +x "$STUB_DIR/gh"

# run_decide <body> <labels> <fresh> <cached> <table> <want_letter> <want_source> <desc>
run_decide() {
  inc
  local out
  out=$(env -i HOME="$HOME" PATH="$STUB_DIR:/usr/bin:/bin" \
    ISSUE_BODY="$1" CURRENT_LABELS="$2" CLASS_FRESH="$3" CACHED_PATH="$4" TABLE_PATH="$5" \
    bash "$DECIDE" 2>&1) || true
  if printf '%s\n' "$out" | grep -qx "PATH_LETTER=$6" \
     && printf '%s\n' "$out" | grep -qx "PATH_SOURCE=$7"; then
    pass_msg "$8 => $6/$7"
  else
    fail_msg "$8: expected PATH_LETTER=$6 PATH_SOURCE=$7, got: $(printf '%s' "$out" | tr '\n' ' ')"
  fi
}

M_D='<!-- pipeline:path=D -->'
H_A='<!-- pipeline:path-hint=A -->'
H_D='<!-- pipeline:path-hint=D -->'
run_decide "x $M_D $H_A" ""           true  C ""  D marker  "marker D + hint A + fresh C"
run_decide "x $H_A"      ""           true  C ""  C cached  "no marker + hint A + fresh C"
run_decide "x"           "multi-task" false "" "" C label   "no marker + stale + multi-task label"
run_decide "x"           ""           false "" D  D table   "no marker/fresh/label + table D"
run_decide "x $H_A"      ""           false "" "" A hint    "only hint A"
run_decide "x"           ""           false "" "" B default "nothing"
run_decide "x $H_D"      ""           false "" "" B default "path-hint=D rejected"

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
