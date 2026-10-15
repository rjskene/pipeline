#!/bin/bash
set -uo pipefail

# Guard (issue #1486): PIPELINE_PATH_C_FANOUT (default false) gates the PATH C
# per-leaf tdd-implementer fan-out. Off => a `multi-task` issue executes exactly
# like PATH B (ONE inline execute agent, the plan's tasks run sequentially); on
# => today's per-leaf fan-out. The resolver emits PATH_C_FANOUT=<on|off> on
# PATH C, so the config example, the fullsend dispatch prose, and the execute
# skill must all name the knob/token.
#
# Dual-scan per CLAUDE.md: pipeline.config.example is always present;
# pipeline.config is gitignored and host-only (no-op in CI).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXAMPLE="$ROOT/pipeline.config.example"
LIVE="$ROOT/pipeline.config"
ROUTING="$ROOT/skills/fullsend/references/dispatch-routing.md"
FULLSEND="$ROOT/skills/fullsend/SKILL.md"
POSTDISPATCH="$ROOT/skills/fullsend/references/post-dispatch-verification.md"
EXEC="$ROOT/skills/execute-issue-plan/SKILL.md"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

for f in "$EXAMPLE" "$ROUTING" "$FULLSEND" "$POSTDISPATCH" "$EXEC"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: $f not found" >&2
    exit 1
  fi
done

# --- (1) config example documents the knob as a COMMENTED default-false line --
inc
if grep -qxF '#PIPELINE_PATH_C_FANOUT="false"' "$EXAMPLE"; then
  pass_msg "example: #PIPELINE_PATH_C_FANOUT=\"false\" commented template line"
else
  fail_msg "example: must carry the exact line #PIPELINE_PATH_C_FANOUT=\"false\""
fi

# --- (2) live pipeline.config (host-only): any value is true|false -----------
inc
if [ -f "$LIVE" ]; then
  bad="$(grep -E '^[[:space:]]*PIPELINE_PATH_C_FANOUT=' "$LIVE" \
           | grep -Ev '^[[:space:]]*PIPELINE_PATH_C_FANOUT="?(true|false)"?[[:space:]]*(#.*)?$' || true)"
  if [ -z "$bad" ]; then
    pass_msg "live pipeline.config: PIPELINE_PATH_C_FANOUT absent or true|false"
  else
    fail_msg "live pipeline.config: PIPELINE_PATH_C_FANOUT must be true|false (got: $bad)"
  fi
else
  pass_msg "live pipeline.config absent (CI) — nothing to scan"
fi

# --- (3) dispatch-routing PATH C bullet branches on the token ----------------
# The bullet keeps its pinned prefix (tests/test-plan-executor-capability.sh).
PCB="$(grep -F -- '- **PATH C** (`multi-task`): dispatch inline by DEFAULT' "$ROUTING" | head -1 || true)"
for tok in 'PATH_C_FANOUT=off' 'execute-issue-plan #<N>' 'PIPELINE_PATH_C_MODEL_EXECUTE' \
           'PATH_C_FANOUT=on' 'path-c-split-worktree.sh' 'Step 8' '`Skill` tool'; do
  inc
  if [ -n "$PCB" ] && grep -qF -- "$tok" <<<"$PCB"; then
    pass_msg "dispatch-routing.md PATH C bullet names '$tok'"
  else
    fail_msg "dispatch-routing.md PATH C bullet must name '$tok'"
  fi
done

# --- (4) the off arm is a single inline execute agent (PATH B shape) ---------
inc
if [ -n "$PCB" ] && grep -qF "description='execute-issue-plan #<N> (PATH C inline)'" <<<"$PCB"; then
  pass_msg "dispatch-routing.md PATH C off arm names the (PATH C inline) execute description"
else
  fail_msg "dispatch-routing.md PATH C off arm must name description='execute-issue-plan #<N> (PATH C inline)'"
fi

# --- (5) --spawn selects transport only; the spawned session honors the knob --
inc
if [ -n "$PCB" ] && grep -qF 'TRANSPORT' <<<"$PCB" && grep -qF 'PIPELINE_PATH_C_FANOUT' <<<"$PCB"; then
  pass_msg "dispatch-routing.md PATH C bullet: --spawn forces the TRANSPORT; spawned session honors PIPELINE_PATH_C_FANOUT"
else
  fail_msg "dispatch-routing.md PATH C bullet must state --spawn forces the TRANSPORT and the spawned session honors PIPELINE_PATH_C_FANOUT"
fi

# --- (6) the resolver token list + relay sentence cover C-off ----------------
inc
if grep -qF '`PATH_C_FANOUT=` (#1486' "$ROUTING"; then
  pass_msg "dispatch-routing.md resolver token list names PATH_C_FANOUT="
else
  fail_msg "dispatch-routing.md resolver token list must name \`PATH_C_FANOUT=\` (#1486 ...)"
fi
inc
if grep -qF 'into the A/B (and PATH C PATH_C_FANOUT=off) execute prompt' "$ROUTING"; then
  pass_msg "dispatch-routing.md PRE_PR_REVIEW relay widened to PATH C off"
else
  fail_msg "dispatch-routing.md must relay PRE_PR_REVIEW= 'into the A/B (and PATH C PATH_C_FANOUT=off) execute prompt'"
fi

# --- (7) fullsend Step 6 names the token and widens the prompt contract ------
inc
if grep -qF 'PATH_C_FANOUT' "$FULLSEND"; then
  pass_msg "fullsend/SKILL.md names PATH_C_FANOUT"
else
  fail_msg "fullsend/SKILL.md must name PATH_C_FANOUT"
fi
inc
if grep -qF 'Each inline PATH A/B/D (and PATH C under PATH_C_FANOUT=off)' "$FULLSEND"; then
  pass_msg "fullsend/SKILL.md inline execute prompt contract covers PATH C off"
else
  fail_msg "fullsend/SKILL.md prompt contract must read 'Each inline PATH A/B/D (and PATH C under PATH_C_FANOUT=off)'"
fi

# --- (8) post-dispatch verification covers PATH C off ------------------------
inc
if head -n 5 "$POSTDISPATCH" | grep -qF 'PATH A/B/D issue, and PATH C under PATH_C_FANOUT=off'; then
  pass_msg "post-dispatch-verification.md covers PATH C under PATH_C_FANOUT=off"
else
  fail_msg "post-dispatch-verification.md must cover 'PATH A/B/D issue, and PATH C under PATH_C_FANOUT=off'"
fi

# --- (9) execute-issue-plan: heading, fallback, mode table -------------------
inc
if grep -qE '^ *\*\*`PIPELINE_PATH_C_FANOUT=true`' "$EXEC"; then
  pass_msg "execute-issue-plan/SKILL.md has a PIPELINE_PATH_C_FANOUT=true heading"
else
  fail_msg "execute-issue-plan/SKILL.md must carry a **\`PIPELINE_PATH_C_FANOUT=true\` ...** heading"
fi
inc
if grep -qF '${PIPELINE_PATH_C_FANOUT:-false}' "$EXEC"; then
  pass_msg "execute-issue-plan/SKILL.md direct-invocation fallback is \${PIPELINE_PATH_C_FANOUT:-false}"
else
  fail_msg "execute-issue-plan/SKILL.md must name the fallback \${PIPELINE_PATH_C_FANOUT:-false}"
fi
MODE1="$(grep -E '^\| 1 \|' "$EXEC" || true)"
MODE2="$(grep -E '^\| 2 \|' "$EXEC" || true)"
inc
if grep -qF 'PIPELINE_PATH_C_FANOUT' <<<"$MODE1" && grep -qF 'PATH C' <<<"$MODE1"; then
  pass_msg "mode table row 1 lists PATH C under the knob-off default"
else
  fail_msg "mode table row 1 must list PATH C (PIPELINE_PATH_C_FANOUT off, default)"
fi
inc
if grep -qF 'PIPELINE_PATH_C_FANOUT=true' <<<"$MODE2" && grep -qF 'PATH C' <<<"$MODE2"; then
  pass_msg "mode table row 2 lists PATH C annotated PIPELINE_PATH_C_FANOUT=true"
else
  fail_msg "mode table row 2 must list PATH C annotated PIPELINE_PATH_C_FANOUT=true"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

if [ "$FAIL" -eq 0 ]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL"
  exit 1
fi
