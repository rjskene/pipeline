#!/bin/bash
set -uo pipefail

# Regression guard for #814: the inline PATH B execute Agent repeatedly dropped
# out at the test-wait step (#752, recurred on #759/#750 after #764's
# dispatch-prompt band-aid merged). The narrate-and-yield failure mode: the
# agent backgrounds a test monitor, then tries to `Read` its `/tmp/...` output
# to learn the result — but the dogfood boundary hook (`restrict_paths.py`)
# blocks reads under `/tmp` (outside the project boundary), the `Read` fails,
# and the agent narrates an intention to "wait" and ends its turn, stranding
# committed-but-unpushed work (no commit, no push, no PR).
#
# #764 patched the inline-execute DISPATCH PROMPT (guarded by
# tests/test-execute-dispatch-prompt-hardening.sh) — the prose band-aid for the
# no-skill-load subagent case. It did NOT hold: the drop-out recurred. #814 is
# the durable SKILL-BODY fix: Step 6b must explicitly NAME and BAN the
# background-monitor-+-`Read`-`/tmp` anti-pattern and mandate running the suite
# SYNCHRONOUSLY in the foreground, reading its exit code directly.
#
# This test region-scopes to the Step 6b block (between the `**6b. Run tests`
# marker and the `**6c.` marker) so it cannot false-match `/tmp` (Step 0b's
# CI-fix log path) or Playwright references (Step 6c) elsewhere in the SKILL.
# Mirrors the ROOT/assert_contains/PASS-FAIL-counter/`exit 1` shape of
# tests/test-execute-dispatch-prompt-hardening.sh.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="skills/execute-issue-plan/SKILL.md"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$ROOT/$SKILL" ]; then
  echo "FAIL: $SKILL not found under $ROOT" >&2
  exit 1
fi

# Extract the Step 6b region: from the `**6b. Run tests` marker line up to (but
# not including) the next `**6c.` marker. Anchored on the stable `Run tests`
# phrase so a future Step renumber that keeps the phrase still works.
REGION="$(awk '
  /^\s*\*\*6b\. Run tests/ {capturing=1}
  /^\s*\*\*6c\./ {capturing=0}
  capturing {print}
' "$ROOT/$SKILL")"

if [ -z "$REGION" ]; then
  echo "FAIL: could not extract Step 6b region from $SKILL (markers '**6b. Run tests' / '**6c.' moved?)" >&2
  exit 1
fi

# Assert the Step 6b region contains a literal substring.
assert_region_contains() {
  local label="$1" needle="$2"
  inc
  if printf '%s' "$REGION" | grep -F -q -- "$needle"; then
    pass_msg "$label: Step 6b region contains \"$needle\""
  else
    fail_msg "$label: Step 6b region missing \"$needle\""
  fi
}

# 1) The synchronous foreground invocation is pinned in the body — a future edit
#    cannot silently re-background it.
assert_region_contains "sync-invocation" 'timeout 600 bash -c "$PIPELINE_TEST_CMD" </dev/null'

# 2) The directive names that the suite runs in the foreground / synchronously
#    and that its exit code is read directly.
inc
if printf '%s' "$REGION" | grep -F -q -- 'synchronous' || printf '%s' "$REGION" | grep -F -q -- 'foreground'; then
  if printf '%s' "$REGION" | grep -F -q -- 'exit code'; then
    pass_msg "sync-directive: Step 6b region states synchronous/foreground AND exit code"
  else
    fail_msg "sync-directive: Step 6b region has synchronous/foreground but missing \"exit code\""
  fi
else
  fail_msg "sync-directive: Step 6b region missing \"synchronous\"/\"foreground\""
fi

# 3) The banned anti-pattern is explicitly named: the body pairs `/tmp` with a
#    negation token and references the narrate(-and-yield) drop-out.
assert_region_contains "antipattern-tmp" '/tmp'
assert_region_contains "antipattern-narrate" 'narrate'

inc
if printf '%s' "$REGION" | grep -E -q -- 'do NOT|Do NOT|never|Never'; then
  pass_msg "antipattern-negation: Step 6b region contains a negation token (do NOT/never)"
else
  fail_msg "antipattern-negation: Step 6b region missing a negation token (do NOT/never)"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
