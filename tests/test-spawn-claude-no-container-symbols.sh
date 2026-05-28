#!/bin/bash
# Regression guard for issue #514, Task 2.
#
# scripts/spawn-claude.sh must contain ZERO references to the removed
# container-isolation surface. If any container symbol creeps back in (via a
# revert, a partial cherry-pick, or a copy-paste from an old branch), this
# test fails loudly so the operator sees it before the patch lands.
#
# Symbols guarded (matches the acceptance grep in the #514 plan):
#   DOCKER_PREFIX
#   --container-mode
#   PIPELINE_EVAL_ISOLATION
#   PIPELINE_CONTAINER_*
#   PIPELINE_EVAL_CONTAINER (and PIPELINE_EVAL_CONTAINERS)
#   CONTAINER_MODE
#   _resolve_container_var
#   INLINE_BROWSER_EVAL
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${REPO_ROOT}/scripts/spawn-claude.sh"

if [ ! -f "$TARGET" ]; then
  echo "FAIL: $TARGET not found"
  exit 1
fi

PATTERN='DOCKER_PREFIX|--container-mode|PIPELINE_EVAL_ISOLATION|PIPELINE_CONTAINER_|PIPELINE_EVAL_CONTAINER|CONTAINER_MODE|_resolve_container_var|INLINE_BROWSER_EVAL'

if grep -nE "$PATTERN" "$TARGET"; then
  echo "FAIL: container-isolation symbol(s) present in scripts/spawn-claude.sh (see #514 Task 2)" >&2
  exit 1
fi

echo "PASS: scripts/spawn-claude.sh has no container-isolation symbols"
exit 0
