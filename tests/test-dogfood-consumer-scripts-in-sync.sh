#!/bin/bash
# tests/test-dogfood-consumer-scripts-in-sync.sh — CI gate.
#
# Until #215 lands (render at install time, or rewrite plugin skills to call
# ${CLAUDE_PLUGIN_ROOT}/scripts/ directly), this repo carries duplicate
# copies of plugin scripts/hooks/agents at .claude/scripts/, .claude/hooks/,
# .claude/agents/ — required by `bash .claude/scripts/<name>.sh` invocations
# in plugin skills. Drift between these two copies is the failure class
# that surfaced in v0.8.0-rc.2 smoke testing (#252): the consumer copy
# silently lags behind the plugin tree, and dogfood sessions run on stale
# scripts while consumers get the updated ones.
#
# Contract:
#   - Every .claude/scripts/*.sh must be byte-identical to scripts/<basename>.
#   - Every .claude/hooks/{*.py,*.sh} must be byte-identical to hooks/<basename>.
#   - Every .claude/agents/*.md must be byte-identical to agents/<basename>.
#   - A consumer copy without a plugin counterpart FAILs (reverse drift).
#   - Skips __pycache__ and .pyc files.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
pass_msg() { PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

check_pair() {
  local consumer="$1" plugin="$2" subdir="$3"
  local bn
  bn="$(basename "$consumer")"
  if [ ! -f "$plugin" ]; then
    fail_msg "consumer copy without plugin counterpart: $consumer (expected $plugin)"
    return
  fi
  if cmp -s "$consumer" "$plugin"; then
    pass_msg
  else
    fail_msg "drift detected: $consumer vs $plugin"
    diff -u "$plugin" "$consumer" | head -20 | sed 's/^/    /'
  fi
}

scripts_checked=0
if [ -d .claude/scripts ]; then
  while IFS= read -r -d '' f; do
    bn="$(basename "$f")"
    check_pair "$f" "scripts/$bn" scripts
    scripts_checked=$((scripts_checked + 1))
  done < <(find .claude/scripts -maxdepth 1 -type f -name '*.sh' -print0)
fi

hooks_checked=0
if [ -d .claude/hooks ]; then
  while IFS= read -r -d '' f; do
    bn="$(basename "$f")"
    check_pair "$f" "hooks/$bn" hooks
    hooks_checked=$((hooks_checked + 1))
  done < <(find .claude/hooks -maxdepth 1 -type f \( -name '*.py' -o -name '*.sh' \) -not -path '*/__pycache__/*' -not -name '*.pyc' -print0)
fi

agents_checked=0
if [ -d .claude/agents ]; then
  while IFS= read -r -d '' f; do
    bn="$(basename "$f")"
    check_pair "$f" "agents/$bn" agents
    agents_checked=$((agents_checked + 1))
  done < <(find .claude/agents -maxdepth 1 -type f -name '*.md' -print0)
fi

echo
echo "Results: $PASS passed, $FAIL failed (scripts=$scripts_checked hooks=$hooks_checked agents=$agents_checked)"
if [ "$FAIL" = "0" ]; then
  echo "PASS: all $scripts_checked dogfood scripts, $hooks_checked hooks, $agents_checked agents in sync with plugin counterparts"
fi
[ "$FAIL" = "0" ]
