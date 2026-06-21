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
if model_knob_block | grep -iEq "opt[ -]out"; then
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

# 5. The gate is conditional (model= passed ONLY WHEN SET → unset inherits Opus).
inc
if grep -iEq "only when .*set|when .*is set|when set" "$SKILL"; then
  pass_msg "skill: gate is conditional (model passed only when the var is set)"
else
  fail_msg "skill: gate not documented as conditional ('only when set')"
fi

# 6. pr-eval dispatch is explicitly NOT gated (stays on Opus backstop).
inc
if grep -iEq "pr-eval dispatch is (not|never) gated|pr-eval .* not gated|pr-eval stays on .*opus" "$SKILL"; then
  pass_msg "skill: pr-eval dispatch explicitly NOT gated (stays Opus)"
else
  fail_msg "skill: missing the 'pr-eval not gated' invariant near the gate"
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

# 9. High-blast PATH B is documented to inherit Opus / pass NO model=.
inc
if awk '
  /Per-path execute MODEL routing/ { inblock = 1 }
  inblock && /^## / { inblock = 0 }
  inblock && /high-blast/ && (/inherit/ || /NO[[:space:]].*model=/ || /no[[:space:]].*model=/) { f = 1 }
  END { exit (f ? 0 : 1) }
' "$SKILL"; then
  pass_msg "skill: high-blast PATH B inherits Opus (passes NO model=)"
else
  fail_msg "skill: high-blast PATH B not documented to inherit Opus / pass no model="
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

# 12. needs-browser PATH D suppresses model= (issue #960 — browser/UI execute
#     never validated on Sonnet). PATH D is otherwise unconditional.
inc
if awk '
  /Per-path execute MODEL routing/ { inblock = 1 }
  inblock && /^## / { inblock = 0 }
  inblock && /PATH D/ && /needs-browser/ && (/NO[[:space:]].*model=/ || /no[[:space:]].*model=/ || /suppress/) { f = 1 }
  END { exit (f ? 0 : 1) }
' "$SKILL"; then
  pass_msg "skill: needs-browser PATH D suppresses model= (browser carve-out)"
else
  fail_msg "skill: needs-browser PATH D model= suppression missing from the block"
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

echo ""
echo "== summary: $PASS passed, $FAIL failed (of $TESTS) =="
[ "$FAIL" -eq 0 ]
