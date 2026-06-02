#!/bin/bash
set -uo pipefail

# Regression guard for issue #215: the six plugin-shipped scripts that used to
# carry a `.sh.template` suffix (from the retired subtree installer) must now
# ship as plain `.sh` so consumers can find them at
# `${CLAUDE_PLUGIN_ROOT}/scripts/<name>.sh`. Failing this test means a fresh
# plugin install will hit "file not found" on `/pipeline:status` (renamed from
# `/pipeline:run` in #763; alias retained).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SCRIPTS=(spawn-claude run-queue cleanup-worktree setup-worktree sync-worktrees retarget-pr)

echo "=== plain .sh present + executable ==="
for name in "${SCRIPTS[@]}"; do
  plain="$REPO_ROOT/scripts/$name.sh"
  if [ -f "$plain" ] && [ -x "$plain" ]; then
    pass_msg "$name.sh present + executable"
  elif [ -f "$plain" ]; then
    fail_msg "$name.sh exists but is not executable"
  else
    fail_msg "$name.sh: not found at $plain"
  fi
done

echo
echo "=== no .sh.template residue for the six renamed scripts ==="
for name in "${SCRIPTS[@]}"; do
  tmpl="$REPO_ROOT/scripts/$name.sh.template"
  if [ -e "$tmpl" ]; then
    fail_msg "$name.sh.template still present (should have been renamed)"
  else
    pass_msg "$name.sh.template absent"
  fi
done

echo
echo "Result: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
