#!/bin/bash
set -euo pipefail

# Guard: skills/run/SKILL.md must NOT re-introduce an upfront classify-dispatch
# block in the discovery step. Per issue #320 and the auto-memory feedback
# `feedback_pipeline_run_prioritization_first`, `/pipeline:run` MUST render the
# prioritization+grouping status table BEFORE any classify dispatch.
# Classification only fires on the user-committed slate at step 6 (the
# planning launch on confirmation), not on the full ready set at startup.
#
# Asserts:
#   (a) the literal "Classify `ready` issues in parallel" header does NOT
#       appear anywhere in skills/run/SKILL.md
#   (b) the prioritization-first invariant block IS present near the top of
#       `## Steps`
#   (c) the `?`-rendering footnote IS present below the example status table
#   (d) the planning-proposal phrasing surfacing the unclassified subset IS
#       present in step 4

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_PATH="$SCRIPT_DIR/../skills/run/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SKILL_PATH" ]; then
  echo "  FAIL: SKILL.md not found at $SKILL_PATH"
  exit 1
fi

# (a) The upfront classify-dispatch header must NOT appear.
inc
if grep -qF 'Classify `ready` issues in parallel' "$SKILL_PATH"; then
  fail_msg "skills/run/SKILL.md still contains 'Classify \`ready\` issues in parallel' header (regression of #320)"
else
  pass_msg "skills/run/SKILL.md contains no upfront classify-dispatch header"
fi

# (b) The prioritization-first invariant block must be present.
inc
if grep -qF 'Invariant — prioritization first' "$SKILL_PATH"; then
  pass_msg "skills/run/SKILL.md carries the prioritization-first invariant block"
else
  fail_msg "skills/run/SKILL.md is missing the 'Invariant — prioritization first' block"
fi

# (c) The `?`-rendering footnote must be present.
inc
if grep -qF 'Path column shows `?` for ready issues not yet classified' "$SKILL_PATH"; then
  pass_msg "skills/run/SKILL.md carries the Path=? footnote"
else
  fail_msg "skills/run/SKILL.md is missing the 'Path column shows \`?\` for ready issues not yet classified' footnote"
fi

# (d) The unclassified-subset proposal phrasing must be present.
inc
if grep -qF 'lack classification' "$SKILL_PATH"; then
  pass_msg "skills/run/SKILL.md surfaces the unclassified subset in the planning proposal"
else
  fail_msg "skills/run/SKILL.md is missing the 'lack classification' planning-proposal phrasing"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
