---
name: hotfix
description: Emergency-lane hotfix — in-session worktree fix bypassing all pipeline lifecycle gates (classify/plan/evaluate/auto-merge). Files an issue (or uses an existing one), creates a worktree, runs the test/fix loop in the current orchestrator session, opens a PR. Usage: /pipeline:hotfix "<problem>" | /pipeline:hotfix <issue-number> [--inline|--subagent]
disable-model-invocation: false
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Skill
---

## Boot

At session start, before running any of the steps below, source the project's `pipeline.config` so the `PIPELINE_*` variables are available for the rest of this skill:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
# Self-resolve CLAUDE_PLUGIN_ROOT in case the env var is unset in the Bash subshell.
[ -f "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" ] \
  && source "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

The bash code blocks below reference these variables via `PIPELINE_REPO`, `PIPELINE_BASE_BRANCH`, `PIPELINE_WORKTREE_PREFIX`, etc. — they resolve from the sourced config, not from envsubst at install time.

# Hotfix Agent

## Overview

`/pipeline:hotfix` is the **emergency lane**. It exists for cases where you want to file an audit-anchor issue, run a fix end to end, and open a PR — without going through the standard classify → plan → evaluate-plan → execute → evaluate-pr → auto-merge lifecycle.

It runs **in the current orchestrator session** (no `spawn-claude.sh`, no `tmux`). You observe red→green→commit live and merge the PR by hand.
