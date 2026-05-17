---
name: worktree-sync
description: Sync untracked .claude/ files (settings, hooks) to all active worktrees and report setup health.
disable-model-invocation: false
allowed-tools: Bash, Read
---

## Boot

At session start, before running any of the steps below, source the project's `pipeline.config` so the `PIPELINE_*` variables are available for the rest of this skill, and self-resolve `CLAUDE_PLUGIN_ROOT` in case the env var is unset in the Bash subshell:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
# Self-resolve CLAUDE_PLUGIN_ROOT in case the env var is unset in the Bash subshell.
[ -f "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" ] \
  && source "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

The bash code blocks below reference these variables via `PIPELINE_REPO`, `PIPELINE_BASE_BRANCH`, `PIPELINE_TEST_CMD`, `PIPELINE_CONTEXT_FILES`, etc. — they resolve from the sourced config, not from envsubst at install time. When prose refers to a config value by name (e.g., "the base branch is `PIPELINE_BASE_BRANCH`"), look it up in the sourced config.

# Worktree Sync

Run the sync script to check all active worktrees for missing or outdated files and fix them:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/sync-worktrees.sh
```

Report the results to the user.
