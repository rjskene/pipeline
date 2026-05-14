#!/bin/bash
set -euo pipefail
shopt -s nullglob

# migrate-from-subtree.sh — one-shot migration for consumers who installed the
# pipeline via the legacy subtree + install.sh path. Removes every
# pipeline-managed file we can identify, leaves user-authored files alone,
# and emits an advisory report for any settings.json injections (without
# mutating settings.json itself).
#
# Run from the consumer project root:
#   bash scripts/migrate-from-subtree.sh
#
# Idempotent: re-running on an already-migrated project is a no-op.

PROJECT_ROOT="$(pwd)"
cd "$PROJECT_ROOT"

have_any_marker() {
  local m
  for m in .claude/skills/*/.pipeline-managed .claude/agents/.*.pipeline-managed; do
    [ -f "$m" ] && return 0
  done
  return 1
}

if [ ! -d .claude-pipeline ] && ! have_any_marker; then
  echo "migrate-from-subtree: nothing to migrate." >&2
  exit 0
fi

echo "migrate-from-subtree: pipeline-managed files detected (full implementation pending)." >&2
exit 0
