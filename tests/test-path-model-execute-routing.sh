#!/bin/bash
set -uo pipefail

# Regression guard for the #868 default-off per-path execute model routing gate.
#
# Contract (Surface A containment, #868 comment 4):
#   - New vars PIPELINE_PATH_B_MODEL_EXECUTE / PIPELINE_PATH_D_MODEL_EXECUTE,
#     default EMPTY. When set, fullsend's execute dispatch pins that model for
#     eligible PATH B / PATH D issues; when unset, NO model= param is passed and
#     the inline subagent inherits the orchestrator's Opus — byte-for-byte current
#     behavior. pr-eval dispatch is NEVER gated (independent Opus backstop).
#   - Documented (commented, default-off) in pipeline.config.example.
#   - Wired at the fullsend execute dispatch site (skill prose references the vars).
#
# Dual-scan per CLAUDE.md "Configuration conventions": pipeline.config.example is
# always present (the shippable contract); the live host-only pipeline.config is
# gitignored and may legitimately SET the vars during a pilot, so the live scan is
# informational only and never fails on presence.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXAMPLE="$ROOT/pipeline.config.example"
SKILL="$ROOT/skills/fullsend/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$EXAMPLE" ]; then echo "ERROR: $EXAMPLE not found" >&2; exit 1; fi
if [ ! -f "$SKILL" ];   then echo "ERROR: $SKILL not found" >&2;   exit 1; fi

echo "== test-path-model-execute-routing (issue #868) =="

VARS=(PIPELINE_PATH_B_MODEL_EXECUTE PIPELINE_PATH_D_MODEL_EXECUTE)

# 1. Each var is documented in pipeline.config.example (commented or not).
for v in "${VARS[@]}"; do
  inc
  if grep -Eq "^[[:space:]]*#?[[:space:]]*${v}=" "$EXAMPLE"; then
    pass_msg "example: $v documented in pipeline.config.example"
  else
    fail_msg "example: $v MISSING from pipeline.config.example"
  fi
done

# 2. #1052 (defaults-in-code) supersedes the #1042 "ship active" polarity for the
#    example: the Sonnet default lives at the scripts/resolve-execute-dispatch.sh read
#    site (unset -> sonnet), so each model var is now COMMENTED in the example and
#    --fix config does NOT seed it. The shipped Sonnet default is unchanged (asserted at
#    the resolver read site); the example carries the documented default in commented form.
for v in "${VARS[@]}"; do
  inc
  if grep -Eq "^[[:space:]]*#[[:space:]]*${v}=sonnet" "$EXAMPLE"; then
    pass_msg "example: $v documented (commented) = sonnet per #1052"
  else
    fail_msg "example: $v not documented as commented = sonnet (#1052)"
  fi
done

# 3. The Sonnet-default + opt-out framing is documented IN the model-routing knob
#    comment block (#1042). Scope to that block (from its "per-path execute MODEL
#    routing" header down through the model knob lines) so unrelated "opt out"
#    comments elsewhere in the example do NOT spuriously pass. The OLD block framed
#    the inherit/Opus default + "keep commented" — that must be reframed to opt-OUT.
model_knob_block() {
  awk '
    /per-path execute MODEL routing/ { inblock = 1 }
    inblock { print }
    inblock && /^[[:space:]]*#?[[:space:]]*PIPELINE_PATH_D_MODEL_EXECUTE=/ { inblock = 0 }
  ' "$EXAMPLE"
}
inc
if model_knob_block | grep -iE "opt[ -]out" >/dev/null; then
  pass_msg "example: Sonnet-default opt-out framing documented in the model knob block"
else
  fail_msg "example: missing 'opt-out' framing in the model knob block (#1042)"
fi

# 4. The fullsend execute dispatch wires both vars.
for v in "${VARS[@]}"; do
  inc
  if grep -q "$v" "$SKILL"; then
    pass_msg "skill: fullsend execute dispatch references $v"
  else
    fail_msg "skill: fullsend SKILL.md does NOT reference $v"
  fi
done

# 5. #1186 flips the read-site rule from CONDITIONAL to UNCONDITIONAL: the
#    resolver now always emits a NAMED model, so the "pass model= only when the
#    resolved spec is non-inherit" special case is retired and every execute
#    dispatch carries `model=$MODEL`. Assert the ALWAYS-pass rule.
inc
if grep -iE "always" "$SKILL" | grep -i "pass .*model=" >/dev/null; then
  pass_msg "skill: read-site rule is ALWAYS pass model=\$MODEL (#1186 pin contract)"
else
  fail_msg "skill: missing the 'ALWAYS pass model=' rule (#1186 retired the only-when-set gate)"
fi

# 6. pr-eval dispatch stays Opus. #1186 keeps the invariant but changes its
#    MECHANISM: it is no longer an un-gated inheritance side-effect, it is an
#    explicit PIN. 6a accepts either phrasing (the invariant itself); 6b asserts
#    the pin mechanism is named at the read site.
inc
if grep -iEq "pr-eval dispatch is (not|never) gated|pr-eval .* not gated|pr-eval stays on .*opus|pr-eval .*pinned .*opus|pinned .*opus.*pr-eval" "$SKILL"; then
  pass_msg "skill: pr-eval dispatch stays Opus (never gated / pinned opus)"
else
  fail_msg "skill: missing the pr-eval-stays-Opus invariant near the gate"
fi
inc
if grep -q "PIPELINE_STAGE_MODEL_PR_EVAL" "$SKILL" && grep -Eq "resolve-stage-model(\.sh)?" "$SKILL"; then
  pass_msg "skill: pr-eval Opus is an explicit PIN (PIPELINE_STAGE_MODEL_PR_EVAL via resolve-stage-model.sh)"
else
  fail_msg "skill: pr-eval Opus not pinned — no PIPELINE_STAGE_MODEL_PR_EVAL / resolve-stage-model.sh read site (#1186)"
fi

# --- #955: PATH B execute model= is eligibility-gated to the #950 low-blast lane ---

# 7. The routing block names the path-b-execute-eligible helper.
inc
if grep -Eq "path-b-execute-eligible(\.sh)?" "$SKILL"; then
  pass_msg "skill: routing block names path-b-execute-eligible helper"
else
  fail_msg "skill: routing block does NOT reference path-b-execute-eligible"
fi

# 8. PATH B passes model= ONLY when the predicate returns low-blast.
#    Assert `low-blast` co-occurs with PATH B in the routing block.
inc
if awk '
  /Per-path execute MODEL routing/ { inblock = 1 }
  inblock && /^## / { inblock = 0 }
  inblock && /low-blast/ && /PATH B/ { f = 1 }
  END { exit (f ? 0 : 1) }
' "$SKILL"; then
  pass_msg "skill: PATH B model= gated on low-blast (low-blast co-occurs with PATH B)"
else
  fail_msg "skill: missing 'low-blast' + 'PATH B' gating in the routing block"
fi

# 9. High-blast PATH B under scope=low-blast now PINS opus (#1186) — it passes
#    `model=opus`, it no longer "passes NO model= and inherits Opus". Same
#    protective effect, named instead of assumed (an unpinned dispatch under a
#    Fable-ceiling session would have silently become Fable, not Opus).
inc
if awk '
  /Per-path execute MODEL routing/ { inblock = 1 }
  inblock && /^## / { inblock = 0 }
  inblock && /high-blast/ {
    l = tolower($0)
    if (l ~ /model=opus/ || l ~ /pins opus/ || l ~ /pinned opus/ || l ~ /pin opus/) f = 1
  }
  END { exit (f ? 0 : 1) }
' "$SKILL"; then
  pass_msg "skill: high-blast PATH B pins opus (model=opus, not an inherit)"
else
  fail_msg "skill: high-blast PATH B still documented as inherit/no-model= (#1186 pin contract)"
fi

# 10. PATH D stays UNCONDITIONAL — the eligibility predicate does NOT gate D.
#     Assert the routing block states D's model= is unconditional (applies to all D).
inc
if awk '
  /Per-path execute MODEL routing/ { inblock = 1 }
  inblock && /^## / { inblock = 0 }
  inblock && /PATH D/ && /unconditional/ { f = 1 }
  END { exit (f ? 0 : 1) }
' "$SKILL"; then
  pass_msg "skill: PATH D model= stays unconditional (not gated by eligibility predicate)"
else
  fail_msg "skill: PATH D unconditional-routing clause missing from the block"
fi

# 11. The predicate is documented as a pre-execute classify/plan-time ESTIMATE
#     (added-LOC not known from a diff at dispatch time).
inc
if awk '
  /Per-path execute MODEL routing/ { inblock = 1 }
  inblock && /^## / { inblock = 0 }
  inblock && /estimate/ { f = 1 }
  END { exit (f ? 0 : 1) }
' "$SKILL"; then
  pass_msg "skill: predicate documented as a pre-execute ESTIMATE (not a diff)"
else
  fail_msg "skill: missing the estimate-not-diff rationale in the block"
fi

# 12. needs-browser PATH D (issue #960 — browser/UI execute never validated on
#     Sonnet). #1186 keeps the carve-out and changes only its emission: it now
#     PINS `model=opus` instead of suppressing model= and inheriting.
inc
if awk '
  /Per-path execute MODEL routing/ { inblock = 1 }
  inblock && /^## / { inblock = 0 }
  inblock && /PATH D/ && /needs-browser/ {
    l = tolower($0)
    if (l ~ /model=opus/ || l ~ /pins opus/ || l ~ /pinned opus/ || l ~ /pin opus/) f = 1
  }
  END { exit (f ? 0 : 1) }
' "$SKILL"; then
  pass_msg "skill: needs-browser PATH D pins opus (browser carve-out, named model)"
else
  fail_msg "skill: needs-browser PATH D still suppresses model=/inherits (#1186 pin contract)"
fi

# --- #1056: the inline execute dispatch is routed through the single-source
#     resolver (resolve-execute-dispatch.sh), and the post-dispatch verify is
#     wired (verify-execute-completion.sh --verify-dispatch). The #1056 root
#     cause was config + hand-applied SKILL prose drifting; the fix is that
#     Step 6 SOURCES the resolver and consumes its emitted spec verbatim, and
#     Step 6a runs the post-hoc verify. ---

CAMPAIGN="$ROOT/skills/campaign/SKILL.md"

# 13. Step 6 routing block references the resolver as the single source of truth.
inc
if grep -Eq "resolve-execute-dispatch(\.sh)?" "$SKILL"; then
  pass_msg "skill: fullsend routes the inline execute dispatch through resolve-execute-dispatch (#1056)"
else
  fail_msg "skill: fullsend does NOT reference resolve-execute-dispatch.sh (#1056 single-source)"
fi

# 14. Step 6a wires the post-dispatch model/shape verify.
inc
if grep -Eq -- "--verify-dispatch" "$SKILL"; then
  pass_msg "skill: fullsend Step 6a wires verify-execute-completion --verify-dispatch (#1056)"
else
  fail_msg "skill: fullsend does NOT reference the --verify-dispatch verify (#1056)"
fi

# 15. campaign SKILL inherits the resolver-driven dispatch by reference.
inc
if [ -f "$CAMPAIGN" ] && grep -Eq "resolve-execute-dispatch(\.sh)?" "$CAMPAIGN"; then
  pass_msg "campaign: SKILL inherits the resolver-driven dispatch by reference (#1056)"
else
  fail_msg "campaign: SKILL does NOT note inheriting resolve-execute-dispatch by reference (#1056)"
fi

# 16. pipeline.config.example points the #1042/#881 knobs at the resolver as the
#     single place they are applied at dispatch time.
inc
if grep -Eq "resolve-execute-dispatch(\.sh)?" "$EXAMPLE"; then
  pass_msg "example: #1042/#881 knob block names resolve-execute-dispatch as the single source (#1056)"
else
  fail_msg "example: #1042/#881 knob block does NOT name resolve-execute-dispatch (#1056)"
fi

# --- #1186: per-stage model PINS. Every quality-critical dispatch carries an
#     explicit `model=`; `inherit` is retired at dispatch sites. The session
#     model is reserved for the orchestrator loop itself. Under a Fable-ceiling
#     session the old "inherits the orchestrator's Opus" assumption is simply
#     false — the unpinned sites silently become Fable (2× the cost, and the
#     refusal-prone lane for exactly the W2 security work the carve-out selects).

SKILLS_DIR="$ROOT/skills"
STAGE_RESOLVER="$ROOT/scripts/resolve-stage-model.sh"
PLAN_EVAL_SKILL="$ROOT/skills/evaluate-issue-plan/SKILL.md"
PR_EVAL_SKILL="$ROOT/skills/evaluate-issue-pr/SKILL.md"

# 17. PROSE-DRIFT REGRESSION (the spec's named guard): the retired assumption
#     "inherits the orchestrator's Opus" must be GONE from skills/ entirely.
#     It documented a property that stopped being true the moment the session
#     model left Opus.
inc
DRIFT_HITS="$(grep -rn "inherits the orchestrator's Opus" "$SKILLS_DIR" 2>/dev/null || true)"
if [ -z "$DRIFT_HITS" ]; then
  pass_msg "skills/: retired phrase \"inherits the orchestrator's Opus\" is gone (#1186)"
else
  fail_msg "skills/: retired phrase \"inherits the orchestrator's Opus\" still present:
$DRIFT_HITS"
fi

# 18. The five stage-model knobs are documented (commented — defaults-in-code at
#     the read site per #1052, so `--fix config` must NOT seed them).
STAGE_VARS=(
  PIPELINE_STAGE_MODEL_PLAN_EVAL
  PIPELINE_STAGE_MODEL_PR_EVAL
  PIPELINE_PATH_C_MODEL_PLAN
  PIPELINE_PATH_A_MODEL_EXECUTE
  PIPELINE_PATH_C_MODEL_EXECUTE
)
for v in "${STAGE_VARS[@]}"; do
  inc
  if grep -Eq "^[[:space:]]*#[[:space:]]*${v}=" "$EXAMPLE"; then
    pass_msg "example: $v documented (commented) per #1052"
  else
    fail_msg "example: $v not documented as a commented knob (#1186)"
  fi
done

# 19. CONFIG-DRIFT SYMMETRY: each newly-declared knob gets a REAL read-site in
#     the same PR, so check-config-drift.sh's ORPHAN group stays empty (a knob
#     documented but never read is a dead config knob).
for v in "${STAGE_VARS[@]}"; do
  inc
  if grep -rq "$v" "$ROOT/scripts" 2>/dev/null; then
    pass_msg "read-site: $v is read under scripts/ (no ORPHAN drift)"
  else
    fail_msg "read-site: $v declared but never read under scripts/ (ORPHAN drift, #1186)"
  fi
done

# 20. check-config-drift.sh stays green with the new knobs + pricing rows in
#     play (symmetric ORPHAN/UNDOCUMENTED lint over the whole tree).
inc
if bash "$ROOT/scripts/check-config-drift.sh" >/dev/null 2>&1; then
  pass_msg "check-config-drift.sh exits 0 (declared/referenced symmetry holds)"
else
  fail_msg "check-config-drift.sh reports drift with the #1186 knobs in play"
fi

# 21. The stage resolver is the single source for the plan/plan-eval/pr-eval
#     pins, and fullsend consumes it (the #1056 lesson applied to the stages
#     that had NO resolver at all).
inc
if [ -f "$STAGE_RESOLVER" ]; then
  pass_msg "scripts/resolve-stage-model.sh exists (single-source stage-model resolver)"
else
  fail_msg "scripts/resolve-stage-model.sh MISSING (#1186 single-source stage resolver)"
fi
inc
if grep -Eq "resolve-stage-model(\.sh)?" "$SKILL"; then
  pass_msg "skill: fullsend routes stage dispatches through resolve-stage-model.sh"
else
  fail_msg "skill: fullsend does NOT reference resolve-stage-model.sh (#1186)"
fi

# 22. The evaluator skills document their own pin (they are auto-gates with no
#     human behind them in fullsend, so "gate never below producer" has to be
#     written down where the evaluator is defined).
inc
if [ -f "$PLAN_EVAL_SKILL" ] && grep -Eq "resolve-stage-model(\.sh)?|PIPELINE_STAGE_MODEL_PLAN_EVAL" "$PLAN_EVAL_SKILL"; then
  pass_msg "evaluate-issue-plan: dispatch-model note names the plan-eval pin (#1186)"
else
  fail_msg "evaluate-issue-plan: missing the plan-eval dispatch-model note (#1186)"
fi
inc
if [ -f "$PR_EVAL_SKILL" ] && grep -q "PIPELINE_STAGE_MODEL_PR_EVAL" "$PR_EVAL_SKILL"; then
  pass_msg "evaluate-issue-pr: W3 reframed as an explicit PIPELINE_STAGE_MODEL_PR_EVAL pin (#1186)"
else
  fail_msg "evaluate-issue-pr: W3 still an inheritance side-effect, not a pin (#1186)"
fi

echo ""
echo "== summary: $PASS passed, $FAIL failed (of $TESTS) =="
[ "$FAIL" -eq 0 ]
