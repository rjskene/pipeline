#!/bin/bash
# Lint skills/evaluate-issue-pr/SKILL.md for the Step 11 (Auto-merge gate)
# prose contract introduced by issue #122.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="${ROOT}/skills/evaluate-issue-pr/SKILL.md"
# #1444: the Step 11 auto-merge gate procedure relocated to the ORCHESTRATOR's
# reference file. Every gate assertion below follows the text to its new home —
# prose is never re-inlined into the evaluator to keep a guard green.
GATE="${ROOT}/skills/fullsend/references/auto-merge-gate.md"
FAILED=0

want() {
  local name="$1" pat="$2"
  if grep -qE -- "$pat" "$GATE"; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name (pattern not found: $pat)"
    FAILED=$((FAILED+1))
  fi
}

want_skill() {
  local name="$1" pat="$2"
  if grep -qE -- "$pat" "$SKILL"; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name (pattern not found: $pat)"
    FAILED=$((FAILED+1))
  fi
}

want "four greenlight conditions (Verdict Approved)" '\*\*Verdict:\*\*.*Approved'
want "four greenlight conditions (statusCheckRollup)" 'statusCheckRollup'
want "four greenlight conditions (mergeable)"         'mergeable'
want "four greenlight conditions (mergeStateStatus)"  'mergeStateStatus'

want "synchronous merge-commit"       'gh pr merge .*--merge --delete-branch'
if grep -q -- "gh pr merge.*--auto" "$GATE"; then
  echo "  FAIL: --auto flag must not appear"
  FAILED=$((FAILED+1))
else
  echo "  PASS: no --auto flag"
fi

want "SHA source via mergeCommit.oid" 'gh pr view .* --json mergeCommit --jq .mergeCommit.oid'
want "auto-merged footer literal"     'Auto-merged: eval Approved \+ CI SUCCESS \+ MERGEABLE/CLEAN at'
want "manual-merge flag mention"      '--manual-merge'
want "manual-merge label mention"     'manual-merge'
want "argv-position parser spec"      '--manual-merge.*may appear anywhere in argv'

want_skill "front-matter usage with flag"   '\[--manual-merge\]'

# --- Step 11.3 post-merge screenshot URL rewrite ordering (issue #506) ---
# The rewrite helper must fire AFTER `gh pr merge` and AFTER the mergeCommit.oid
# SHA capture (the SHA it pins to), but BEFORE the footer-append comment (so the
# rewriter targets the screenshot comment, not the freshly-posted footer).
first_line() { grep -nE -- "$1" "$GATE" | head -1 | cut -d: -f1; }

want "Step 11.3 invokes rewrite-eval-screenshot-urls.sh" 'rewrite-eval-screenshot-urls\.sh'
want "Step 11.3 gates rewrite on PIPELINE_SCREENSHOT_REWRITE_ENABLED" 'PIPELINE_SCREENSHOT_REWRITE_ENABLED'

MERGE_LINE=$(first_line 'gh pr merge .*--merge --delete-branch')
SHA_LINE=$(first_line 'gh pr view .* --json mergeCommit --jq .mergeCommit.oid')
REWRITE_LINE=$(first_line 'rewrite-eval-screenshot-urls\.sh')
FOOTER_LINE=$(first_line 'Auto-merged: eval Approved')

ordering_ok=1
for v in "$MERGE_LINE" "$SHA_LINE" "$REWRITE_LINE" "$FOOTER_LINE"; do
  [ -n "$v" ] || ordering_ok=0
done
if [ "$ordering_ok" -eq 1 ] \
   && [ "$MERGE_LINE" -lt "$SHA_LINE" ] \
   && [ "$SHA_LINE" -lt "$REWRITE_LINE" ] \
   && [ "$REWRITE_LINE" -lt "$FOOTER_LINE" ]; then
  echo "  PASS: rewrite ordering merge($MERGE_LINE) < sha($SHA_LINE) < rewrite($REWRITE_LINE) < footer($FOOTER_LINE)"
else
  echo "  FAIL: rewrite ordering merge=$MERGE_LINE sha=$SHA_LINE rewrite=$REWRITE_LINE footer=$FOOTER_LINE"
  FAILED=$((FAILED+1))
fi

# --- Step 5b CI-wait must be a FOREGROUND in-turn wait (issue #684) ---
# A subagent cannot durably block on a backgrounded Bash; run_in_background
# ends its turn before the verdict/merge steps. The wait must run to
# completion within the subagent's own turn.
want_skill "Step 5b foreground wait (timeout-bounded gh pr checks --watch)" \
  'timeout 600 gh pr checks .*--watch --fail-fast --interval 30'
if grep -qE 'run_in_background:?[[:space:]]*true' "$SKILL"; then
  echo "  FAIL: Step 5b must not instruct run_in_background:true (issue #684)"
  FAILED=$((FAILED+1))
else
  echo "  PASS: no run_in_background:true in evaluate-issue-pr SKILL.md"
fi

# --- #1444: the auto-merge gate and the three orchestrator-facing sections are
# RELOCATED out of the evaluator. This is the INVERSE contract: the evaluator's
# BODY must no longer carry any of them, and the visual-validation reference
# must exist. Asserted against the BODY via skill_body_has, never a whole-file
# grep — the YAML frontmatter `description:` line can satisfy a whole-file grep
# on its own (#1218).
# shellcheck source=tests/_lib/skill-body.sh
source "$(cd "$(dirname "$0")" && pwd)/_lib/skill-body.sh"

VISUAL_REF="${ROOT}/skills/evaluate-issue-pr/references/visual-validation.md"

want_absent_body() {
  local name="$1" needle="$2"
  if skill_body_has "$SKILL" "$needle"; then
    echo "  FAIL: $name (relocated anchor still present in the body: $needle)"
    FAILED=$((FAILED+1))
  else
    echo "  PASS: $name"
  fi
}

want_absent_body "Step 11 auto-merge gate relocated"            '11. **Auto-merge gate.**'
want_absent_body "auto_merge_should_fire call site relocated"    'auto_merge_should_fire'
want_absent_body "auto-merged footer literal relocated"          'Auto-merged: eval Approved'
want_absent_body "## Invocation mode relocated"                  '## Invocation mode'
want_absent_body "## Canonical Agent prompt template relocated"  '## Canonical Agent prompt template'
want_absent_body "## Migration warning relocated"                '## Migration warning'

if [ -f "$VISUAL_REF" ]; then
  echo "  PASS: references/visual-validation.md exists"
else
  echo "  FAIL: references/visual-validation.md missing ($VISUAL_REF)"
  FAILED=$((FAILED+1))
fi

# --- #1444 hot-path mass: the evaluator is the second-most-expensive skill in
# the pipeline and is loaded on EVERY PR. This is the local half of the ceiling
# contract (tests/test-skill-hot-path-mass.sh pins all three hot-path skills).
# BODY words only (frontmatter stripped, #1218); open-`bash`-fence count uses
# the #1281 grammar. The floor is the non-vacuity guard — a ceiling alone is
# satisfied by deleting the skill.
EVAL_WORDS=$(skill_body "$SKILL" | wc -w)
EVAL_FENCES=$(grep -cE '^[[:space:]]*```bash' "$SKILL")

if [ "$EVAL_WORDS" -le 3000 ] && [ "$EVAL_WORDS" -ge 1200 ]; then
  echo "  PASS: body is $EVAL_WORDS words (floor 1200, ceiling 3000)"
else
  echo "  FAIL: body is $EVAL_WORDS words — must be >= 1200 and <= 3000"
  FAILED=$((FAILED+1))
fi

if [ "$EVAL_FENCES" -le 9 ]; then
  echo "  PASS: $EVAL_FENCES open bash fences (ceiling 9)"
else
  echo "  FAIL: $EVAL_FENCES open bash fences — must be <= 9"
  FAILED=$((FAILED+1))
fi

# --- #1444: scripts/run-queue.sh's terminal-detection comments describe the
# `manual-merge` auto-apply and the `Auto-merge skipped:` fallback shape. Both
# behaviours are UNCHANGED, but they are no longer documented in the evaluator
# skill — the doc pointer must follow the gate to the orchestrator's reference.
# Comments only; zero executable change.
RUN_QUEUE="${ROOT}/scripts/run-queue.sh"

if grep -qF 'skills/fullsend/references/auto-merge-gate.md' "$RUN_QUEUE"; then
  echo "  PASS: run-queue.sh cites the relocated auto-merge-gate reference"
else
  echo "  FAIL: run-queue.sh does not cite skills/fullsend/references/auto-merge-gate.md"
  FAILED=$((FAILED+1))
fi

if grep -qE 'skills/evaluate-issue-pr/SKILL\.md|evaluator skips Step 11' "$RUN_QUEUE"; then
  echo "  FAIL: run-queue.sh still points at the deleted evaluate-issue-pr Step 11"
  FAILED=$((FAILED+1))
else
  echo "  PASS: run-queue.sh no longer points at the deleted evaluate-issue-pr Step 11"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: evaluator prose matches contract"
