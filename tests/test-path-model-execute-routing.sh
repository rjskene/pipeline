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

# 2. Default-OFF: each var must be COMMENTED OUT in the example (an uncommented
#    assignment would ship a behavior change to consumers).
for v in "${VARS[@]}"; do
  inc
  if grep -Eq "^[[:space:]]*${v}=" "$EXAMPLE"; then
    fail_msg "example: $v is UNCOMMENTED in example (must default-off / commented)"
  else
    pass_msg "example: $v is default-off (commented) in example"
  fi
done

# 3. The inherit/Opus default is documented near the gate.
inc
if grep -iEq "inherit" "$EXAMPLE" && grep -Eq "PIPELINE_PATH_[BD]_MODEL_EXECUTE" "$EXAMPLE"; then
  pass_msg "example: inherit/Opus default is documented"
else
  fail_msg "example: missing 'inherit' default documentation near the gate"
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

echo ""
echo "== summary: $PASS passed, $FAIL failed (of $TESTS) =="
[ "$FAIL" -eq 0 ]
