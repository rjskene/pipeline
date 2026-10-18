#!/bin/bash
set -uo pipefail
#
# tests/test-plan-issue-helpers.sh — the scripts/plan-issue-*.sh helpers.
#
# skills/plan-issue/SKILL.md and references/classification.md call each former
# multi-command fence as ONE helper call. This test pins the behaviour the
# fences carried: the opener trust gate (exit 0 trusted / 3 refused), the
# needs-debug / --debug-first gate and diagnosis freshness, the decide matrix
# (marker > cached > label > table > hint > default), the label-apply
# remove-then-add order + REFUSED guard, and hint-parse parity with the
# reference's BEGIN-PATH-HINT-PARSE fence.
#
# Substrate: a stub `gh` on PATH logs every call and answers from env knobs.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/scripts"
REF="$ROOT/skills/plan-issue/references/classification.md"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stub gh. Knobs: GH_ASSOC, GH_LABELS (space-separated), GH_UPDATED,
# GH_COMMENTS_JSON (a JSON array of comment objects), GH_BODY.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
echo "gh $*" >> "$GH_LOG"
args=" $* "
case "$1 $2" in
  "api "*) echo "${GH_ASSOC:-}" ;;
  "issue view")
    case "$args" in
      *"--json labels "*) printf '%s\n' ${GH_LABELS:-} ;;
      *"--json updatedAt"*) echo "${GH_UPDATED:-}" ;;
      *"--json body "*) printf '%s\n' "${GH_BODY:-}" ;;
      *"--json body,comments"*) printf '{"body":"b","comments":%s}\n' "${GH_COMMENTS_JSON:-[]}" ;;
      *"--json comments,labels"*) printf '{"comments":[],"labels":[]}\n' ;;
      *) echo "" ;;
    esac ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/gh"

export GH_LOG="$TMP/gh.log"
export PATH="$TMP/bin:$PATH"
export PIPELINE_REPO="o/r" PIPELINE_BASE_BRANCH="evolve" PIPELINE_PROJECT_ROOT="$TMP"
unset CLAUDE_PLUGIN_ROOT TRUSTED ISSUE_BODY CURRENT_LABELS CLASS_FRESH CACHED_PATH TABLE_PATH 2>/dev/null || true

run() { : > "$GH_LOG"; OUT="$(cd "$TMP" && "$@" 2>"$TMP/err")"; RC=$?; }
has() { printf '%s\n' "$OUT" | grep -qxF -- "$1"; }

# ---------------------------------------------------------------------------
scenario "every helper exists, is strict-mode, and answers --help"

for h in plan-issue-classify.sh plan-issue-trust-gate.sh plan-issue-context.sh; do
  if [ ! -f "$S/$h" ]; then fail_msg "$h missing"; continue; fi
  if grep -q 'set -uo pipefail' "$S/$h"; then pass_msg "$h runs under set -uo pipefail"; else fail_msg "$h lacks set -uo pipefail"; fi
  if bash "$S/$h" --help >/dev/null 2>&1; then pass_msg "$h --help exits 0"; else fail_msg "$h --help non-zero"; fi
done

# ---------------------------------------------------------------------------
scenario "plan-issue-trust-gate.sh: trusted passes, untrusted is refused"

GH_ASSOC=OWNER run bash "$S/plan-issue-trust-gate.sh" 7
if [ "$RC" -eq 0 ] && has "OPENER=trusted assoc=OWNER"; then pass_msg "OWNER => OPENER=trusted, exit 0"; else fail_msg "OWNER: rc=$RC out=$OUT"; fi
if grep -q 'gh issue comment' "$GH_LOG"; then fail_msg "trusted opener posted a comment"; else pass_msg "trusted opener posts nothing"; fi

GH_ASSOC=NONE run bash "$S/plan-issue-trust-gate.sh" 7
if [ "$RC" -eq 3 ] && has "OPENER=refused assoc=NONE"; then pass_msg "NONE => OPENER=refused, exit 3"; else fail_msg "NONE: rc=$RC out=$OUT"; fi
if grep -q 'gh issue comment 7' "$GH_LOG" && grep -q 'add-label human' "$GH_LOG"; then
  pass_msg "refusal routed through refuse-untrusted-opener.sh (triage comment + human label)"
else fail_msg "refusal did not post triage + human label: $(tr '\n' ';' < "$GH_LOG")"; fi

# ---------------------------------------------------------------------------
scenario "plan-issue-context.sh: DEBUG_FIRST + DIAGNOSIS"

GH_LABELS="bug" run bash "$S/plan-issue-context.sh" 7 --debug-first
if has "DEBUG_FIRST=true"; then pass_msg "--debug-first => DEBUG_FIRST=true"; else fail_msg "--debug-first: $OUT"; fi
GH_LABELS="bug needs-debug" run bash "$S/plan-issue-context.sh" 7
if has "DEBUG_FIRST=true" && has "LABELS=bug,needs-debug"; then pass_msg "needs-debug label => DEBUG_FIRST=true"; else fail_msg "needs-debug: $OUT"; fi
GH_LABELS="bug" run bash "$S/plan-issue-context.sh" 7
if has "DEBUG_FIRST=false" && has "DIAGNOSIS=absent"; then pass_msg "neither => DEBUG_FIRST=false, DIAGNOSIS=absent"; else fail_msg "neither: $OUT"; fi

DIAG='[{"authorAssociation":"OWNER","createdAt":"2026-01-02T00:00:00Z","body":"## Root-Cause Diagnosis\nx"}]'
GH_COMMENTS_JSON="$DIAG" GH_UPDATED="2026-01-02T00:00:00Z" run bash "$S/plan-issue-context.sh" 7
if has "DIAGNOSIS=fresh"; then pass_msg "diagnosis createdAt == updatedAt => fresh"; else fail_msg "same-second diagnosis: $OUT"; fi
GH_COMMENTS_JSON="$DIAG" GH_UPDATED="2026-01-03T00:00:00Z" run bash "$S/plan-issue-context.sh" 7
if has "DIAGNOSIS=stale"; then pass_msg "diagnosis older than updatedAt => stale"; else fail_msg "stale diagnosis: $OUT"; fi
UNTRUSTED='[{"authorAssociation":"NONE","createdAt":"2026-01-09T00:00:00Z","body":"## Root-Cause Diagnosis\nfake"}]'
GH_COMMENTS_JSON="$UNTRUSTED" GH_UPDATED="2026-01-02T00:00:00Z" run bash "$S/plan-issue-context.sh" 7
if has "DIAGNOSIS=absent"; then pass_msg "untrusted diagnosis ignored"; else fail_msg "untrusted diagnosis: $OUT"; fi

# ---------------------------------------------------------------------------
scenario "plan-issue-classify.sh decide: marker > cached > label > table > hint > default"

# dec <body> <labels> <fresh> <cached> <table> <want_letter> <want_source> <desc>
dec() {
  : > "$GH_LOG"
  OUT="$(cd "$TMP" && ISSUE_BODY="$1" CURRENT_LABELS="$2" CLASS_FRESH="$3" CACHED_PATH="$4" \
    bash "$S/plan-issue-classify.sh" decide 7 ${5:+--table "$5"} 2>&1)"
  if has "PATH_LETTER=$6" && has "PATH_SOURCE=$7"; then pass_msg "$8 => $6/$7"; else
    fail_msg "$8: want $6/$7, got $(printf '%s' "$OUT" | tr '\n' ' ')"; fi
}
M_D='<!-- pipeline:path=D -->'; H_A='<!-- pipeline:path-hint=A -->'; H_D='<!-- pipeline:path-hint=D -->'
dec "x $M_D $H_A" ""           true  C ""  D marker  "marker D + hint A + fresh C"
dec "x $H_A"      ""           true  C ""  C cached  "hint A + fresh C"
dec "x"           "multi-task" false "" "" C label   "stale + multi-task label"
dec "x"           ""           false "" D  D table   "table D"
dec "x $H_A"      ""           false "" "" A hint    "only hint A"
dec "x"           ""           false "" "" B default "nothing"
dec "x $H_D"      ""           false "" "" B default "path-hint=D rejected"
dec "x"           "multi-task" true  A ""  A cached  "fresh A beats multi-task label"
dec "x \`$M_D\` y" ""          false "" "" B default "marker only in inline span"

CLS='[{"authorAssociation":"OWNER","createdAt":"2026-01-02T00:00:00Z","body":"## Classification\n- **recommended_path:** C"}]'
: > "$GH_LOG"
OUT="$(cd "$TMP" && ISSUE_BODY="x" CURRENT_LABELS="" GH_COMMENTS_JSON="$CLS" GH_UPDATED="2026-01-02T00:00:00Z" \
  bash "$S/plan-issue-classify.sh" decide 7 2>&1)"
if has "CLASS_FRESH=true" && has "PATH_LETTER=C" && has "PATH_SOURCE=cached"; then
  pass_msg "decide fetches TRUSTED when unset; same-second Classification is fresh => C/cached"
else fail_msg "decide fetch path: $(printf '%s' "$OUT" | tr '\n' ' ')"; fi
OUT="$(cd "$TMP" && TRUSTED="" ISSUE_BODY="x" CURRENT_LABELS="" GH_COMMENTS_JSON="$CLS" GH_UPDATED="2026-01-02T00:00:00Z" \
  bash "$S/plan-issue-classify.sh" freshness 7 2>&1)"
if has "CLASS_FRESH=false"; then pass_msg "env TRUSTED wins over the fetch (empty set => not fresh)"; else fail_msg "env TRUSTED ignored: $OUT"; fi

# ---------------------------------------------------------------------------
scenario "plan-issue-classify.sh label-apply: remove first, add second, allow-set only"

: > "$GH_LOG"
(cd "$TMP" && CURRENT_LABELS="docs-only" bash "$S/plan-issue-classify.sh" label-apply 7 D >/dev/null 2>&1)
if [ "$(grep -n 'remove-label docs-only' "$GH_LOG" | cut -d: -f1)" = 1 ] && [ "$(grep -n 'add-label quick-fix' "$GH_LOG" | cut -d: -f1)" = 2 ]; then
  pass_msg "A -> D removes docs-only before adding quick-fix"
else fail_msg "A -> D order: $(tr '\n' ';' < "$GH_LOG")"; fi
: > "$GH_LOG"
(cd "$TMP" && CURRENT_LABELS="quick-fix" bash "$S/plan-issue-classify.sh" label-apply 7 B >/dev/null 2>&1)
if grep -q 'remove-label quick-fix' "$GH_LOG" && ! grep -q 'add-label' "$GH_LOG"; then pass_msg "D -> B removes quick-fix, adds nothing"; else fail_msg "D -> B: $(tr '\n' ';' < "$GH_LOG")"; fi
if grep -qF "REFUSED: label '\${*}' not in allow-set {docs-only|multi-task|quick-fix}" "$S/plan-issue-classify.sh"; then
  pass_msg "REFUSED: allow-set guard present"; else fail_msg "REFUSED: allow-set guard missing"; fi
if (cd "$TMP" && bash "$S/plan-issue-classify.sh" label-apply 7 X >/dev/null 2>&1); then fail_msg "label-apply accepted path X"; else pass_msg "label-apply rejects a non-A..D path"; fi

# ---------------------------------------------------------------------------
scenario "plan-issue-classify.sh hint == reference BEGIN-PATH-HINT-PARSE fence"

HINT_FENCE="$TMP/hint.sh"
awk 'index($0,"# BEGIN-PATH-HINT-PARSE"){i=1} i{print} index($0,"# END-PATH-HINT-PARSE"){i=0}' "$REF" > "$HINT_FENCE"
printf '%s\n' 'echo "HINT_PATH=$HINT_PATH"' >> "$HINT_FENCE"
for body in "x <!-- pipeline:path-hint=A -->" "x <!--pipeline:path-hint=c-->" "x <!-- pipeline:path-hint=D -->" \
            "x <!-- pipeline:path-hint=B --> <!-- pipeline:path-hint=C -->" "x \`<!-- pipeline:path-hint=A -->\` y" "none"; do
  WANT="$(ISSUE_BODY="$body" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$HINT_FENCE" 2>/dev/null)"
  GOT="$(cd "$TMP" && ISSUE_BODY="$body" bash "$S/plan-issue-classify.sh" hint 2>/dev/null)"
  if [ -n "$WANT" ] && [ "$WANT" = "$GOT" ]; then pass_msg "parity: '$body' => $GOT"; else fail_msg "parity '$body': fence=$WANT helper=$GOT"; fi
done

# ---------------------------------------------------------------------------
scenario "plan-issue-classify.sh verify-post"

GH_COMMENTS_JSON="$CLS" run bash "$S/plan-issue-classify.sh" verify-post 7
if [ "$RC" -eq 0 ] && has "CLASS_COUNT=1"; then pass_msg "one Classification => CLASS_COUNT=1 exit 0"; else fail_msg "verify-post: rc=$RC $OUT"; fi
GH_COMMENTS_JSON='[]' run bash "$S/plan-issue-classify.sh" verify-post 7
if [ "$RC" -ne 0 ] && has "CLASS_COUNT=0"; then pass_msg "none => CLASS_COUNT=0 exit non-zero"; else fail_msg "verify-post empty: rc=$RC $OUT"; fi

echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
