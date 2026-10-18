#!/bin/bash
set -uo pipefail
#
# tests/test-plan-issue-mass-budget.sh — the planner's mass budget.
#
# plan-issue/SKILL.md is loaded into every planning agent; its classification
# reference is read on every unclassified issue. Both carry a ceiling, and both
# carry only RULES: citations, history and rationale live in
# docs/plan-issue-design-notes.md, and multi-command shell lives in
# scripts/plan-issue-*.sh behind one call.
#
#   B1  BODY (frontmatter stripped) <= 1900 words (>= 1000, non-vacuous)
#   B2  references/classification.md <= 1500 words (>= 700, non-vacuous)
#   B3  zero `#NNN`/`#NNNN` issue citations in the body outside `## Boot`'s fence
#   B4  zero `#NNN`/`#NNNN` issue citations in classification.md
#   B5  every bash fence (body + reference, Boot excepted) is ONE command
#       (continuation lines ending `\`, `|`, `&&`, `||` join; comments skipped)
#   B6  the contract literals survive
#   B7  docs/plan-issue-design-notes.md exists and carries the archived rationale

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/plan-issue/SKILL.md"
REF="$ROOT/skills/plan-issue/references/classification.md"
NOTES="$ROOT/docs/plan-issue-design-notes.md"
# shellcheck source=tests/_lib/skill-body.sh
source "$ROOT/tests/_lib/skill-body.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

[ -f "$SKILL" ] || { echo "ERROR: $SKILL missing" >&2; exit 1; }
[ -f "$REF" ] || { echo "ERROR: $REF missing" >&2; exit 1; }

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

# multi_cmd_fences <file> <skipboot> : prints `<line>\t<count>` per bash fence
# holding more than one logical command.
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
if [ "$BW" -le 1900 ]; then pass_msg "SKILL.md body $BW <= 1900 words"; else fail_msg "SKILL.md body $BW > 1900 words"; fi
if [ "$BW" -ge 1000 ]; then pass_msg "SKILL.md body $BW >= 1000 words (non-vacuous)"; else fail_msg "SKILL.md body $BW < 1000 words — gutted"; fi
RW="$(wc -w < "$REF" | tr -d ' ')"
if [ "$RW" -le 1500 ]; then pass_msg "classification.md $RW <= 1500 words"; else fail_msg "classification.md $RW > 1500 words"; fi
if [ "$RW" -ge 700 ]; then pass_msg "classification.md $RW >= 700 words (non-vacuous)"; else fail_msg "classification.md $RW < 700 words — gutted"; fi

# ---------------------------------------------------------------------------
scenario "B3/B4: zero issue citations"

HITS="$(body_minus_boot_fence | grep -noE '#[0-9]{3,4}\b' || true)"
if [ -z "$HITS" ]; then pass_msg "body carries zero #NNN citations outside the Boot fence"; else
  fail_msg "body carries $(printf '%s\n' "$HITS" | grep -c .) citation(s): $(printf '%s ' $HITS | cut -c1-200)"; fi
HITS="$(grep -noE '#[0-9]{3,4}\b' "$REF" || true)"
if [ -z "$HITS" ]; then pass_msg "classification.md carries zero citations"; else
  fail_msg "classification.md carries $(printf '%s\n' "$HITS" | grep -c .) citation(s): $(printf '%s ' $HITS | cut -c1-200)"; fi

# ---------------------------------------------------------------------------
scenario "B5: every bash fence is one command (Boot excepted)"

OFF="$(multi_cmd_fences "$SKILL" 1)"
if [ -z "$OFF" ]; then pass_msg "SKILL.md: no multi-command bash fence"; else fail_msg "SKILL.md multi-command fence(s) at line:count $(printf '%s ' $OFF)"; fi
OFF="$(multi_cmd_fences "$REF" 0)"
if [ -z "$OFF" ]; then pass_msg "classification.md: no multi-command bash fence"; else fail_msg "classification.md multi-command fence(s) at line:count $(printf '%s ' $OFF)"; fi

SELF="$(mktemp)"; trap 'rm -f "$SELF"' EXIT
printf '%s\n' '```bash' 'A=1' 'echo "$A"' '```' '```bash' 'bash x.sh \' '  --flag | head -1' '```' > "$SELF"
if [ "$(multi_cmd_fences "$SELF" 0)" = "$(printf '1\t2')" ]; then pass_msg "fence grammar self-test (2-command caught, continuation joined)"; else fail_msg "fence grammar self-test failed: $(multi_cmd_fences "$SELF" 0)"; fi

# ---------------------------------------------------------------------------
scenario "B6: contract literals survive"

for lit in \
  'ARGV=' '_resolve-plugin-root.sh' '## Caller contract' '--debug-first' 'needs-debug' \
  '## Root-Cause Diagnosis' 'Reproduce' 'Isolate' 'Hypothesize' 'Confirm' \
  '## Implementation Plan' '**Changes from previous plan:**' '**Files to change:**' '**Tasks (ordered):**' \
  '**DB schema changes:**' '**API changes:**' '**Frontend changes:**' '**Test changes:**' \
  '**Design decisions:**' '**Risks/unknowns:**' '**Estimated effort:**' \
  '#### Task 0 — PATH A (docs-only)' '#### Task 0 — PATH B (standard)' \
  '#### Task 0 — PATH C (multi-task)' '#### Task 0 — PATH D (quick-fix)' \
  '- Task N:' 'Task N (PATH D substitute)' 'CAPABILITY-REFUSED:' \
  '**Heads-up — CI-blocking markers:**' '*.md#anchor' 'EXACT_MATCH_GUARD=' \
  '**Exact-match guard sweep' 'positional' 'PIPELINE_TEST_ROOTS' \
  'plan-pending' 'post-plan.sh' 'Write' '## Revision handling' 'Round <k>: applied <summary>' \
  '## Comment trust' 'OWNER' 'MEMBER' 'COLLABORATOR' 'filter-trusted-comments.sh' \
  'PIPELINE_LABELS_HUMAN' '## Constraints' 'plan-issue-trust-gate.sh' 'plan-issue-context.sh' \
  'plan-issue-classify.sh'; do
  case "$BODY" in *"$lit"*) pass_msg "body: $lit" ;; *) fail_msg "body missing: $lit" ;; esac
done
STEP67="$(printf '%s\n' "$BODY" | awk '/^6\. /{i=1} /^8\. /{i=0} i')"
YM="$(printf '%s\n' "$STEP67" | grep -o 'YOU MUST' | wc -l | tr -d ' ')"
if [ "$YM" -ge 2 ]; then pass_msg "Steps 6-7 carry >= 2 'YOU MUST' ($YM)"; else fail_msg "Steps 6-7 carry $YM 'YOU MUST' (< 2)"; fi
T0="$(printf '%s\n' "$BODY" | awk '/^#### Task 0 — PATH/{i=1} /^6\. /{i=0} i')"
case "$T0" in *post-plan.sh*) fail_msg "post-plan.sh leaks into the Task 0 blocks" ;; *) pass_msg "post-plan.sh absent from the Task 0 blocks" ;; esac

REFTXT="$(cat "$REF")"
for lit in \
  '<!-- pipeline:path=D -->' 'pipeline:path-hint=' 'marker ⇒ hint ⇒ fresh comment ⇒ rule table ⇒ B' \
  'PATH_SOURCE=' '| Otherwise | B | medium |' 'fix(' 'feat(' 'SEMANTIC' 'Escalation backstop' \
  'Alternative-bullet rule' 'Acceptance-criteria skip' 'flip' 'swap' '## Classification' \
  'recommended_path:' 'Override rationale' '{docs-only|multi-task|quick-fix}' '## Prompt strategy' \
  '## Paths' '### Decide' 'BEGIN-CLASS-FRESHNESS' 'BEGIN-PATH-DECIDE' 'BEGIN-LABEL-APPLY' \
  'BEGIN-PATH-HINT-PARSE' 'plan-issue-classify.sh'; do
  case "$REFTXT" in *"$lit"*) pass_msg "reference: $lit" ;; *) fail_msg "reference missing: $lit" ;; esac
done
for step in '3c.' '3d.' '4.' '4a.' '5.' '5a.' '6.' '7.'; do
  if grep -qE "^${step//./\\.} " "$REF"; then pass_msg "reference keeps step label $step"; else fail_msg "reference lost step label $step"; fi
done

# ---------------------------------------------------------------------------
scenario "B7: rationale archived"

if [ -f "$NOTES" ] && grep -qE '#[0-9]{3,4}' "$NOTES"; then pass_msg "docs/plan-issue-design-notes.md exists and carries citations"; else fail_msg "docs/plan-issue-design-notes.md missing or citation-free"; fi

echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
