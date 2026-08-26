#!/bin/bash
set -uo pipefail

# Contract test for issue #1262 sub-defect (b), placement half — the PER-DISPATCH
# clean-main attribution sub-step in fullsend Step 6.
#
# The #1122 clean-main guard runs at the WAVE/LEG BOUNDARY. That is structurally
# too late to attribute a leak: by the time `CLEAN=dirty` surfaces, the agent that
# ran the mis-anchored `git add` has already returned and its context is gone, so
# the orchestrator learns only that SOMETHING in the wave leaked. #1262(b) asks for
# the check to run per-dispatch — baseline before each execute `Agent`, delta check
# immediately after it returns — so the verdict names the responsible agent while it
# could still have been corrected in-turn.
#
# This guard pins the PROSE half (the mechanism half lives in
# tests/test-verify-execute-completion.sh PD1-PD12). Two regions are extracted:
#
#   - the Step 6 REGION, with the awk copied VERBATIM from
#     tests/test-clean-main-untracked-guard.sh so both guards agree on the boundary;
#   - the per-dispatch SUB-BLOCK, anchored on its own `**Per-dispatch clean-main
#     attribution` heading and terminated by the next `   **` line.
#
# Assertions are scoped to the extracted regions, never the whole file: the words
# `--since`, `CLEAN=`, `orchestrator-owned` etc. already occur elsewhere in the
# skill (Step 6a's #1122 table, the #1208 no-re-ask rule), so a whole-file grep
# would pass spuriously on the pre-fix text.
#
# RED/GREEN ledger: P1-P8 and P11 are red before the fix (the sub-block does not
# exist). P9 and P10 are PRESERVATION controls — they pin state that already holds
# on the base branch and exist to catch the new prose REGRESSING it, so they are
# correctly green both before and after.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="skills/fullsend/SKILL.md"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$ROOT/$SKILL" ]; then
  echo "FAIL: $SKILL not found under $ROOT" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Region extractors.
# ---------------------------------------------------------------------------

# Step 6 region — copied UNCHANGED from tests/test-clean-main-untracked-guard.sh
# so the two guards cannot disagree about where Step 6 ends.
REGION="$(awk '
  /^[[:space:]]*6\. \*\*Execute \(wave N\)\*\*/ {capturing=1}
  /^[[:space:]]*(\*\*)?6b\./ {capturing=0}
  capturing {print}
' "$ROOT/$SKILL")"

if [ -z "$REGION" ]; then
  echo "FAIL: could not extract the Step 6 region from $SKILL (markers moved?)" >&2
  exit 1
fi

# Per-dispatch sub-block — its own anchor, terminated by the next `   **` line.
# Deliberately NOT a hard exit when empty: an empty sub-block IS the pre-fix
# state, and P1 is the assertion that reports it.
SUBBLOCK="$(printf '%s\n' "$REGION" | awk '
  index($0, "**Per-dispatch clean-main attribution") { inblock = 1; print; next }
  inblock && /^   \*\*/ { inblock = 0 }
  inblock { print }
')"

REGION_FLAT="$(tr '\n' ' ' <<< "$REGION")"
SUB_FLAT="$(tr '\n' ' ' <<< "$SUBBLOCK")"

assert_sub_contains() {
  local label="$1" needle="$2"
  inc
  if printf '%s' "$SUB_FLAT" | grep -Fq -- "$needle"; then
    pass_msg "$label: per-dispatch sub-block contains \"$needle\""
  else
    fail_msg "$label: per-dispatch sub-block missing \"$needle\" (sub-block empty => anchor absent / markers moved?)"
  fi
}

assert_region_contains() {
  local label="$1" needle="$2"
  inc
  if printf '%s' "$REGION_FLAT" | grep -Fq -- "$needle"; then
    pass_msg "$label: Step 6 region contains \"$needle\""
  else
    fail_msg "$label: Step 6 region missing \"$needle\""
  fi
}

echo "Per-dispatch clean-main attribution in fullsend Step 6 (#1262b)"

# =====================================================================
# P1 — the sub-step exists at all, inside the Step 6 region.
# =====================================================================
inc
if printf '%s' "$REGION_FLAT" | grep -Fq -- '**Per-dispatch clean-main attribution'; then
  pass_msg "P1: Step 6 region contains \"**Per-dispatch clean-main attribution\""
else
  fail_msg "P1: Step 6 region missing \"**Per-dispatch clean-main attribution\""
fi

# =====================================================================
# P2-P6 — the sub-step actually WIRES the helper contract: both modes,
#         the two new verdict tokens, and the attribution fields.
# =====================================================================
assert_sub_contains "P2" '--clean-main-baseline'
assert_sub_contains "P3" '--since'
assert_sub_contains "P4" 'CLEAN=leak'
assert_sub_contains "P5" 'CLEAN=pre-existing'

inc
if printf '%s' "$SUB_FLAT" | grep -Fq -- 'ISSUE=' && printf '%s' "$SUB_FLAT" | grep -Fq -- 'PATHS='; then
  pass_msg "P6: sub-block surfaces BOTH attribution fields (ISSUE= and PATHS=)"
else
  fail_msg "P6: sub-block does not surface both ISSUE= and PATHS= — a leak verdict without them is not attributable"
fi

# =====================================================================
# P7 — TIMING is stated, not implied. Baseline BEFORE the dispatch,
#      check IMMEDIATELY AFTER it returns. This ordering is the entire
#      point of the issue: a snapshot taken at any other moment cannot
#      attribute the delta.
# =====================================================================
inc
if printf '%s' "$SUB_FLAT" | grep -Eqi -- 'BEFORE' \
   && printf '%s' "$SUB_FLAT" | grep -Eqi -- 'IMMEDIATELY AFTER'; then
  pass_msg "P7: sub-block states the baseline-BEFORE / check-IMMEDIATELY-AFTER ordering"
else
  fail_msg "P7: sub-block does not state both BEFORE and IMMEDIATELY AFTER — the attribution window is only implied"
fi

# =====================================================================
# P8 — no re-ask (#1208 precedent). Recovery is orchestrator-owned; the
#      leaking agent is never resumed to clean up after itself.
# =====================================================================
inc
if printf '%s' "$SUB_FLAT" | grep -Fq -- 'orchestrator-owned' \
   && printf '%s' "$SUB_FLAT" | grep -Eqi -- 'MUST NOT resume|never a resume|do NOT resume'; then
  pass_msg "P8: recovery is orchestrator-owned and explicitly never a resume of the leaking agent"
else
  fail_msg "P8: sub-block missing the orchestrator-owned / never-resume recovery rule (#1208 precedent)"
fi

# =====================================================================
# P9 — #1207 PRESERVATION, hard guard. The untracked-sweeping stash form
#      must not appear ANYWHERE in the Step 6 region. This deliberately
#      duplicates tests/test-clean-main-untracked-guard.sh test 3: the new
#      recovery prose is the single most likely place to reintroduce the
#      data-loss form.
# =====================================================================
inc
if printf '%s' "$REGION_FLAT" | grep -Fq -- 'stash push -u'; then
  fail_msg "P9: Step 6 region contains the untracked-sweeping stash form (#1207 data-loss hazard) — the per-dispatch recovery must use a path-scoped plain stash"
else
  pass_msg "P9: Step 6 region contains no untracked-sweeping stash form (#1207 preserved)"
fi

# =====================================================================
# P10 — ADDED, not swapped. The #1122 wave/leg-boundary guard must survive
#       as the backstop: the `--spawn` run-queue transport has no inline
#       return point where a per-dispatch check could fire.
# =====================================================================
assert_region_contains "P10" '**Clean-main guard (#1122'
assert_region_contains "P10" 'CLEAN=ok'
assert_region_contains "P10" 'CLEAN=untracked-only'
assert_region_contains "P10" 'CLEAN=dirty'

# =====================================================================
# P11 — split-role coverage. PATH B dispatches RED then GREEN sequentially
#       into the same worktree; one baseline spanning both cannot say which
#       role leaked — the exact failure this issue is about.
# =====================================================================
inc
if printf '%s' "$SUB_FLAT" | grep -Eq -- 'RED|red' \
   && printf '%s' "$SUB_FLAT" | grep -Eq -- 'GREEN|green'; then
  pass_msg "P11: sub-block distinguishes the split-role RED and GREEN dispatches"
else
  fail_msg "P11: sub-block does not name the RED/GREEN split-role dispatches — a PATH B leak would be attributed to \"the PATH B dispatch\" rather than to a role"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
