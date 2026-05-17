#!/bin/bash
set -uo pipefail

# Regression guard for issue #215: skill prose must not point at the
# bare `.claude/scripts/<name>.sh` path inside the consumer repo. The
# plugin no longer installs anything to `.claude/scripts/`, so every
# script invocation must resolve via `${CLAUDE_PLUGIN_ROOT}/scripts/`.
#
# Exceptions:
#   - `migration-cleanup` skill (instructs operator to clean up exactly
#     these stale paths — references are intentional).
#   - `README*` (descriptive narrative, not invoked commands).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== no bare .claude/scripts/ references in skills/ ==="
hits="$(grep -rn '\.claude/scripts/' "$REPO_ROOT/skills/" \
        | grep -v 'migration-cleanup' \
        | grep -v 'README' \
        || true)"
count=0
if [ -n "$hits" ]; then
  count=$(echo "$hits" | wc -l | tr -d ' ')
fi

if [ "$count" -eq 0 ]; then
  pass_msg "zero hits"
else
  fail_msg "$count bare .claude/scripts/ reference(s) in skills/:"
  echo "$hits" | sed 's/^/    /'
fi

echo
echo "Result: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
