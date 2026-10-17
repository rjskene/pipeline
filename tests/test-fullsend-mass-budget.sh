#!/bin/bash
set -uo pipefail
#
# tests/test-fullsend-mass-budget.sh — the fullsend orchestrator's mass budget.
#
# fullsend/SKILL.md is loaded into the orchestrator session for the whole run;
# its references are read on trigger. Both are context cost paid every wave, so
# both carry a ceiling, and the body carries only RULES: citations, history and
# rationale live in docs/fullsend-design-notes.md, and multi-command shell lives
# in scripts/fullsend-*.sh behind one call.
#
#   B1  BODY (frontmatter stripped) <= 4000 words
#   B2  references/*.md total       <= 5000 words
#   B3  zero `#NNN`/`#NNNN` issue citations in the body outside `## Boot`'s fence
#   B4  zero `#NNN`/`#NNNN` issue citations in references/
#   B5  every bash fence (body + references, Boot excepted) is ONE command
#       (continuation lines ending `\`, `|`, `&&`, `||` join; comments skipped)
#   B6  the dispatch-description contract shapes survive (literal `#<N>`)
#   B7  the three folded references are gone
#   B8  docs/fullsend-design-notes.md exists and carries the archived rationale

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/fullsend/SKILL.md"
REF_DIR="$ROOT/skills/fullsend/references"
NOTES="$ROOT/docs/fullsend-design-notes.md"
# shellcheck source=tests/_lib/skill-body.sh
source "$ROOT/tests/_lib/skill-body.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

[ -f "$SKILL" ] || { echo "ERROR: $SKILL missing" >&2; exit 1; }

BODY="$(skill_body "$SKILL")"

# body_minus_boot_fence: the body with the FIRST bash fence under `## Boot` cut.
body_minus_boot_fence() {
  printf '%s\n' "$BODY" | awk '
    /^## Boot/ { inboot=1 }
    inboot && !seen && /^[[:space:]]*```bash/ { infence=1; seen=1; next }
    infence && /^[[:space:]]*```[[:space:]]*$/ { infence=0; next }
    infence { next }
    { print }
  '
}

# multi_cmd_fences <file-or-stdin-label> : prints `<line>\t<count>` per bash
# fence holding more than one logical command.
multi_cmd_fences() {
  awk -v skipboot="$2" '
    function is_open(l)  { return l ~ /^[[:space:]]*```bash[[:space:]]*$/ }
    function is_close(l) { return l ~ /^[[:space:]]*```[[:space:]]*$/ }
    /^## Boot/ { inboot=1 }
    /^## / && !/^## Boot/ { inboot=0 }
    {
      if (!inb) { if (is_open($0)) { inb=1; start=FNR; n=0; cont=0; boot=(inboot && skipboot=="1") } next }
      if (is_close($0)) { if (!boot && n > 1) printf "%d\t%d\n", start, n; inb=0; next }
      l=$0; sub(/^[[:space:]]+/, "", l); sub(/[[:space:]]+$/, "", l)
      if (l == "" || l ~ /^#/) next
      if (!cont) n++
      cont = (l ~ /(\\|\||&&)$/)
    }
  ' "$1"
}

# ---------------------------------------------------------------------------
scenario "B1/B2: word ceilings"

BW="$(printf '%s\n' "$BODY" | wc -w | tr -d ' ')"
if [ "$BW" -le 4000 ]; then pass_msg "SKILL.md body $BW <= 4000 words"; else fail_msg "SKILL.md body $BW > 4000 words"; fi
if [ "$BW" -ge 2000 ]; then pass_msg "SKILL.md body $BW >= 2000 words (non-vacuous)"; else fail_msg "SKILL.md body $BW < 2000 words — gutted"; fi

RW=0
for f in "$REF_DIR"/*.md; do
  [ -f "$f" ] || continue
  RW=$((RW + $(wc -w < "$f")))
done
if [ "$RW" -le 5000 ]; then pass_msg "references total $RW <= 5000 words"; else fail_msg "references total $RW > 5000 words"; fi
if [ "$RW" -ge 1500 ]; then pass_msg "references total $RW >= 1500 words (non-vacuous)"; else fail_msg "references total $RW < 1500 words — gutted"; fi

# ---------------------------------------------------------------------------
scenario "B3/B4: zero issue citations"

HITS="$(body_minus_boot_fence | grep -noE '#[0-9]{3,4}\b' || true)"
if [ -z "$HITS" ]; then pass_msg "body carries zero #NNN citations outside the Boot fence"; else
  fail_msg "body carries $(printf '%s\n' "$HITS" | grep -c .) citation(s): $(printf '%s ' $HITS | cut -c1-200)"; fi
for f in "$REF_DIR"/*.md; do
  [ -f "$f" ] || continue
  HITS="$(grep -noE '#[0-9]{3,4}\b' "$f" || true)"
  if [ -z "$HITS" ]; then pass_msg "${f#"$ROOT"/} carries zero citations"; else
    fail_msg "${f#"$ROOT"/} carries $(printf '%s\n' "$HITS" | grep -c .) citation(s): $(printf '%s ' $HITS | cut -c1-200)"; fi
done

# ---------------------------------------------------------------------------
scenario "B5: every bash fence is one command (Boot excepted)"

OFF="$(multi_cmd_fences "$SKILL" 1)"
if [ -z "$OFF" ]; then pass_msg "SKILL.md: no multi-command bash fence"; else fail_msg "SKILL.md multi-command fence(s) at line:count $(printf '%s ' $OFF)"; fi
for f in "$REF_DIR"/*.md; do
  [ -f "$f" ] || continue
  OFF="$(multi_cmd_fences "$f" 0)"
  if [ -z "$OFF" ]; then pass_msg "${f#"$ROOT"/}: no multi-command bash fence"; else fail_msg "${f#"$ROOT"/} multi-command fence(s) at line:count $(printf '%s ' $OFF)"; fi
done

# Grammar self-test: a two-command fence is caught, a continued one is not.
SELF="$(mktemp)"; trap 'rm -f "$SELF"' EXIT
printf '%s\n' '```bash' 'A=1' 'echo "$A"' '```' '```bash' 'bash x.sh \' '  --flag | head -1' '```' > "$SELF"
if [ "$(multi_cmd_fences "$SELF" 0)" = "$(printf '1\t2')" ]; then pass_msg "fence grammar self-test (2-command caught, continuation joined)"; else fail_msg "fence grammar self-test failed: $(multi_cmd_fences "$SELF" 0)"; fi

# ---------------------------------------------------------------------------
scenario "B6: dispatch-description contract (literal #<N>) survives"

UNION="$(skill_body "$SKILL"; cat "$REF_DIR"/*.md)"
for shape in \
  "execute-issue-plan #<N> (PATH B inline)" \
  "execute-issue-plan #<N> (PATH C inline)" \
  "execute-issue-plan #<N> (PATH D collapsed inline tdd)" \
  "execute-issue-plan #<N> target=<dir>/" \
  "code review #<N>" \
  "evaluate-issue-pr #<N>" \
  "plan-issue #<N>" \
  "evaluate-issue-plan #<N>"; do
  case "$UNION" in
    *"$shape"*) pass_msg "shape present: $shape" ;;
    *) fail_msg "shape missing: $shape" ;;
  esac
done

# #1499: plan / plan-eval dispatch descriptions are pinned in the SKILL BODY
# itself (not just a reference), so the orchestrator authors `#<N>` there.
for shape in \
  "description='plan-issue #<N> (PATH <X>)'" \
  "description='evaluate-issue-plan #<N>'" \
  "(same descriptions)"; do
  case "$BODY" in
    *"$shape"*) pass_msg "body shape present: $shape" ;;
    *) fail_msg "body shape missing: $shape" ;;
  esac
done

# ---------------------------------------------------------------------------
scenario "B7: folded references are gone; B8: rationale archived"

for gone in pr-eval-dispatch.md scoped-halt.md merge-orchestration.md; do
  if [ -e "$REF_DIR/$gone" ]; then fail_msg "references/$gone still exists (folded into SKILL.md)"; else pass_msg "references/$gone folded away"; fi
done
if [ -f "$NOTES" ] && grep -qE '#[0-9]{3,4}' "$NOTES"; then pass_msg "docs/fullsend-design-notes.md exists and carries citations"; else fail_msg "docs/fullsend-design-notes.md missing or citation-free"; fi

echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
