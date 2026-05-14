---
name: worktree-sync
description: Sync untracked .claude/ files (settings, hooks) to all active worktrees and report setup health.
disable-model-invocation: false
allowed-tools: Bash, Read
---

## Boot

At session start, before running any of the steps below, source the project's `pipeline.config` so the `PIPELINE_*` variables are available for the rest of this skill:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
```

The bash code blocks below reference these variables via `HTS-COLLAB-ORG/claude-pipeline`, `staging`, `for t in tests/test*.sh tests/test_*.sh; do [ -f "$t" ] && bash "$t" || true; done`, `CLAUDE.md`, etc. — they resolve from the sourced config, not from envsubst at install time. When prose refers to a config value by name (e.g., "the base branch is `PIPELINE_BASE_BRANCH`"), look it up in the sourced config.

# Worktree Sync

Run the sync script to check all active worktrees for missing or outdated files and fix them:

```bash
bash .claude/scripts/sync-worktrees.sh
```

Report the results to the user.
