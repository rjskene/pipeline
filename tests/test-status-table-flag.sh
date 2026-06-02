#!/bin/bash
set -uo pipefail
#
# Contract test (issue #763): the --table flag on /pipeline:status renders
# ONLY the status table (via scripts/render-status-table.sh) and STOPs — it is
# a render-only fast path. The --table section must NOT carry housekeeping,
# dispatch, or proposal wiring.
#
# Asserts:
#   (a) a `## Table-only mode (--table)` section is present
#   (b) that section invokes scripts/render-status-table.sh (render-only)
#   (c) the --table path text excludes housekeeping/dispatch/proposal — it
#       explicitly SKIPS housekeeping and proposals (render-only contract)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL="$REPO_ROOT/skills/status/SKILL.md"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$SKILL" ]; then
  fail_msg "skills/status/SKILL.md not found at $SKILL"
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi

# (a) Table-only mode section present.
if grep -qE '^## Table-only mode \(--table\)' "$SKILL"; then
  pass_msg "## Table-only mode (--table) section present"
else
  fail_msg "missing '## Table-only mode (--table)' section"
fi

# Slice the --table section window: from its heading to the next H2.
TABLE_WINDOW=$(awk '
  /^## Table-only mode \(--table\)/ { grab=1; print; next }
  grab && /^## / { exit }
  grab { print }
' "$SKILL")

# (b) The --table path is render-only: invokes render-status-table.sh.
if echo "$TABLE_WINDOW" | grep -qF 'render-status-table.sh'; then
  pass_msg "--table section invokes render-status-table.sh (render-only)"
else
  fail_msg "--table section does not invoke render-status-table.sh"
fi

# (c) The --table path explicitly EXCLUDES housekeeping/dispatch/proposal — it
#     states it SKIPS housekeeping and proposals.
if echo "$TABLE_WINDOW" | grep -qiE 'skip[[:space:]].*housekeeping'; then
  pass_msg "--table section skips housekeeping"
else
  fail_msg "--table section does not state it skips housekeeping"
fi

if echo "$TABLE_WINDOW" | grep -qiE 'proposal'; then
  pass_msg "--table section excludes proposals (proposals named as skipped)"
else
  fail_msg "--table section does not name proposals as skipped"
fi

# The render-only fast path must not itself dispatch or queue.
if echo "$TABLE_WINDOW" | grep -qE 'Agent\(subagent_type=|run-queue\.sh|spawn-claude\.sh'; then
  fail_msg "--table section carries dispatch/transport wiring (must be render-only)"
else
  pass_msg "--table section carries no dispatch/transport wiring"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
