#!/bin/bash
set -uo pipefail
#
# #1444 — THE ORCHESTRATOR OWNS THE AUTO-MERGE GATE.
#
# Before #1444 the greenlight gate was fired from `evaluate-issue-pr` Step 11:
# the EVALUATOR merged its own PR. fullsend's Step 7 prose claimed to "apply the
# per-PR greenlight auto-merge gate" and Step 8's legend offered a `yes (step8)`
# outcome, but `grep -n 'auto-merge-gate' skills/fullsend/SKILL.md` matched only
# the matrix table and the ownership paragraph — there was NO fence and NO
# `auto_merge_should_fire` call anywhere in fullsend. The claimed fallback path
# did not exist.
#
# #1444 flips ownership: the evaluator posts a verdict and stops; the
# ORCHESTRATOR fires the gate at Step 7 after the evaluator returns. That makes
# two things load-bearing, and this guard pins both:
#
#   1. THE CALL SITE. Step 7 must carry a real `bash` fence that sources
#      `scripts/auto-merge-gate.sh`, threads `PIPELINE_CAPABILITY_REFUSAL_SOURCES`
#      via `check-capability-refusal.sh --resolve-sources` (#1233/#1246), and
#      captures the token into `REASON`. Prose alone is what #1444 is fixing.
#
#   2. THE PROCEDURE. `scripts/auto-merge-gate.sh` emits ONE TOKEN and performs
#      no actions: the TOCTOU base re-read, `gh pr merge`, the merge-SHA capture,
#      `rewrite-eval-screenshot-urls.sh`, the `Auto-merged: eval Approved …`
#      footer, `finalize-issue-labels.sh`, the #813 already-closed guard, the
#      `Auto-merge skipped:` comment and the #489 `manual-merge` auto-apply exist
#      ONLY in the orchestrator's procedure. Deleting them would leave inline
#      PATH A/B/D PRs unmerged. They must be present in the union of
#      `skills/fullsend/references/auto-merge-gate.md` and the Step 7 helpers
#      it calls (`scripts/fullsend-{gate,merge-green,block-merge}.sh`).
#
# Plus the three OWNERSHIP sites that must stop naming the evaluator as the
# firing party: `## Auto-merge ownership`, the Step 8 report legend, and the
# inline PR-eval dispatch prompt contract (which made "the greenlight gate
# fired" a MANDATORY terminal state of the dispatched evaluator — an instruction
# the evaluator can no longer satisfy).
#
# Body assertions go through tests/_lib/skill-body.sh: a whole-file grep is
# satisfiable by the YAML `description:` line alone (#1218).
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=tests/_lib/skill-body.sh
source "$SCRIPT_DIR/_lib/skill-body.sh"

FS="$REPO_ROOT/skills/fullsend/SKILL.md"
GATE_REF="$REPO_ROOT/skills/fullsend/references/auto-merge-gate.md"
GATE_HELPER="$REPO_ROOT/scripts/fullsend-gate.sh"
GATE_PROC=(
  "$GATE_REF"
  "$GATE_HELPER"
  "$REPO_ROOT/scripts/fullsend-merge-green.sh"
  "$REPO_ROOT/scripts/fullsend-block-merge.sh"
)

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }
inc_scenario() { echo ""; echo "-- $1 --"; }

if [ ! -f "$FS" ]; then
  echo "FAIL: $FS not found" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# A. The relocated gate procedure exists and is complete.
# ---------------------------------------------------------------------------
inc_scenario "A: skills/fullsend/references/auto-merge-gate.md carries the post-green procedure"

inc
if [ -f "$GATE_REF" ]; then
  pass_msg "A0: references/auto-merge-gate.md exists"
else
  fail_msg "A0: references/auto-merge-gate.md is MISSING — the Step 11 procedure was dropped, not relocated"
fi

# Every needle below is an ACTION that scripts/auto-merge-gate.sh does NOT
# perform (its function body contains no gh write call at all), so losing any of
# them silently strands a greenlit PR.
GATE_NEEDLES=(
  'auto_merge_should_fire'
  'gh pr merge "$PR_NUM" --repo "$PIPELINE_REPO" --merge --delete-branch'
  '--json mergeCommit --jq .mergeCommit.oid'
  'rewrite-eval-screenshot-urls.sh'
  'Auto-merged: eval Approved + CI SUCCESS + MERGEABLE/CLEAN at'
  'finalize-issue-labels.sh'
  'already closed'
  'Auto-merge skipped:'
  '--add-label "manual-merge"'
  'block-base-mismatch'
  'retarget-pr.sh'
)
for needle in "${GATE_NEEDLES[@]}"; do
  inc
  if cat "${GATE_PROC[@]}" 2>/dev/null | grep -qF -- "$needle"; then
    pass_msg "A: gate procedure carries \"$needle\""
  else
    fail_msg "A: gate procedure MISSING \"$needle\" — scripts/auto-merge-gate.sh does not do this, so the procedure is the only copy"
  fi
done

# The reference must name every helper it delegates to.
for h in fullsend-merge-green.sh fullsend-block-merge.sh fullsend-gate.sh; do
  inc
  if grep -qF -- "$h" "$GATE_REF"; then
    pass_msg "A: gate reference names $h"
  else
    fail_msg "A: gate reference does not name $h"
  fi
done

# The steps were renumbered 11.1-11.4 -> 1-4, so no dangling "Step 11.x"
# self-reference may survive into the relocated file.
inc
if [ -f "$GATE_REF" ] && grep -qE 'Step 11(\.[0-9])?' "$GATE_REF"; then
  fail_msg "A: gate reference still carries a dangling 'Step 11.x' self-reference (eval-pr Step 11 no longer exists)"
else
  pass_msg "A: gate reference carries no dangling 'Step 11.x' self-reference"
fi

# ---------------------------------------------------------------------------
# B. The orchestrator-facing PR-eval dispatch contract lives in Step 7.
# ---------------------------------------------------------------------------
inc_scenario "B: fullsend SKILL.md carries the PR-eval invocation-mode contract"

inc
if skill_body_has "$FS" '**PR-eval invocation mode.**'; then
  pass_msg "B: SKILL.md body carries the '**PR-eval invocation mode.**' paragraph"
else
  fail_msg "B: SKILL.md body MISSING the '**PR-eval invocation mode.**' paragraph"
fi

# ---------------------------------------------------------------------------
# C. Step 7 carries the REAL call site — a bash fence, not prose.
# ---------------------------------------------------------------------------
inc_scenario "C: fullsend Step 7 fires the gate from a bash fence"

# Step 7 region: the `7. **Evaluate PRs (wave N)**` marker up to `7b.`.
STEP7="$(awk '
  /^[[:space:]]*7\. \*\*Evaluate PRs \(wave N\)/ {capturing=1}
  capturing && /^[[:space:]]*(\*\*)?7b\./ {capturing=0}
  capturing {print}
' "$FS")"

inc
if [ -n "$STEP7" ]; then
  pass_msg "C0: Step 7 region extracted"
else
  fail_msg "C0: could not extract the Step 7 region (markers moved?)"
fi

# Step 7 names the procedure and calls the gate helper from a fence.
STEP7_NEEDLES=(
  'scripts/auto-merge-gate.sh'
  'scripts/fullsend-gate.sh'
  '--resolve-sources'
  'PIPELINE_CAPABILITY_REFUSAL_SOURCES'
  'references/auto-merge-gate.md'
)
for needle in "${STEP7_NEEDLES[@]}"; do
  inc
  if grep -qF -- "$needle" <<<"$STEP7"; then
    pass_msg "C: Step 7 carries \"$needle\""
  else
    fail_msg "C: Step 7 MISSING \"$needle\" — the gate call site is still prose-only (#1444)"
  fi
done

# The helper is the executable call site: sourced gate + resolved sources + token.
for needle in 'source "$SELF_DIR/auto-merge-gate.sh"' 'check-capability-refusal.sh" --resolve-sources' 'PIPELINE_CAPABILITY_REFUSAL_SOURCES' 'REASON=$(auto_merge_should_fire'; do
  inc
  if grep -vE '^[[:space:]]*#' "$GATE_HELPER" | grep -qF -- "$needle"; then
    pass_msg "C: fullsend-gate.sh carries \"$needle\""
  else
    fail_msg "C: fullsend-gate.sh MISSING \"$needle\""
  fi
done

# Non-vacuity: Step 7 must call the helper INSIDE a bash fence, not in prose.
# Without this the whole scenario is satisfiable by a sentence.
STEP7_FENCED="$(printf '%s\n' "$STEP7" | awk '
  /^[[:space:]]*```bash[[:space:]]*$/ { inb = 1; next }
  inb && /^[[:space:]]*```[[:space:]]*$/ { inb = 0; next }
  inb { print }
')"
inc
if grep -qF 'scripts/fullsend-gate.sh' <<<"$STEP7_FENCED"; then
  pass_msg "C: the fullsend-gate.sh call is INSIDE a bash fence (an executable call site, not prose)"
else
  fail_msg "C: fullsend-gate.sh does not appear inside any Step 7 bash fence — a prose-only gate never fires"
fi

# ---------------------------------------------------------------------------
# D. Ownership prose names the ORCHESTRATOR, at all three sites.
# ---------------------------------------------------------------------------
inc_scenario "D: all three ownership sites name the orchestrator, not evaluate-issue-pr Step 11"

# D1 — `## Auto-merge ownership` (stays inline).
OWNERSHIP="$(awk '/^## Auto-merge ownership/{f=1; next} f && /^## /{f=0} f' "$FS")"
inc
if [ -n "$OWNERSHIP" ]; then
  pass_msg "D0: '## Auto-merge ownership' section extracted"
else
  fail_msg "D0: '## Auto-merge ownership' section is missing"
fi
inc
if grep -qiF 'orchestrator' <<<"$OWNERSHIP"; then
  pass_msg "D1: ownership section names the orchestrator as the firing party"
else
  fail_msg "D1: ownership section does not name the orchestrator"
fi
inc
if grep -qE '`?/pipeline:evaluate-issue-pr`? Step 11' <<<"$OWNERSHIP"; then
  fail_msg "D1: ownership section still says evaluate-issue-pr Step 11 fires the gate (that step is deleted)"
else
  pass_msg "D1: ownership section no longer credits evaluate-issue-pr Step 11"
fi

# D3 — the inline PR-eval dispatch contract names a terminal state the
# evaluator CAN satisfy.
inc
if skill_body_has "$FS" '**Verdict:**'; then
  pass_msg "D3: the dispatch contract still requires an explicit **Verdict:** line"
else
  fail_msg "D3: the dispatch contract no longer requires an explicit **Verdict:** line"
fi

# --- Summary ---
echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
