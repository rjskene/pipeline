# Claude Pipeline

Claude Pipeline — a CI workflow for automating code updates through GitHub issues.

```
create → classify → plan → eval → execute → eval-pr → merge
```

Full process maps in docs/process-maps.md.

## Canonical entry points

| Command | When to use |
|---|---|
| `/pipeline:run` | Interactive — check pipeline status, see what's ready, advance the next stage |
| `/pipeline:fullsend [N ...]` | Autonomous end-to-end run for one or many issues (classify → plan → evaluate-plan → execute → evaluate-pr → greenlight-merge) |

## Install + first run

- Marketplace add:
  ```
  /plugin marketplace add rjskene/pipeline
  ```
- Install:
  ```
  /plugin install pipeline@claude-pipeline
  ```
- The plugin lives at `~/.claude/plugins/claude-pipeline/` (referenced at runtime as `${CLAUDE_PLUGIN_ROOT}`) and registers all slash commands, hooks, skills, and the `tdd-implementer` subagent automatically.
- Configure — create `pipeline.config` at the repo root with the values for your project:
  ```bash
  PIPELINE_REPO="your-org/your-repo"
  PIPELINE_BASE_BRANCH="staging"
  PIPELINE_WORKTREE_PREFIX="wt"
  PIPELINE_INSTALL_CMD="npm ci"
  PIPELINE_TEST_CMD="npm test"
  PIPELINE_TYPECHECK_CMD="npx tsc --noEmit"
  PIPELINE_CONTEXT_FILES="CLAUDE.md"
  ```
  See `pipeline.config.example` for all options.
- Validate:
  ```
  /pipeline:doctor
  ```
  Read-only audit; `--fix labels` seeds canonical labels idempotently.
- First run:
  ```
  /pipeline:run
  ```

## Project layout

```
claude-pipeline/
├── skills/         # Pipeline slash-command skills (run, fullsend, plan-issue, ...)
├── agents/         # Subagent definitions (tdd-implementer, ...)
├── hooks/          # PreToolUse / PostToolUse / Stop hook scripts
├── scripts/        # Shell helpers invoked by skills and hooks
├── docs/           # System-reference docs (process maps, architecture, release cadence, ...)
├── tests/          # Test substrate for scripts, hooks, and skill contracts
├── .github/        # Workflows, issue templates, release-please config
├── pipeline.config # Host-specific config (gitignored; copy from pipeline.config.example)
├── CLAUDE.md       # Working instructions for agents operating in this repo
└── README.md       # This file
```

## Where to look

- `docs/` — system reference (process maps, architecture, release cadence, plugin architecture, observability, self-audit, migration-from-subtree).
- `skills/<name>/SKILL.md` — authoritative behavior for each slash command.
- `CLAUDE.md` — working instructions for this repo (branches, namespace discipline, configuration conventions).

## Prerequisites

- `gh` CLI — for GitHub issue/PR operations.
- `jq` — for hook JSON parsing.
- `bash` 4+ — queue and status scripts use associative arrays. (Note: macOS ships bash 3.2; `brew install bash`.)
