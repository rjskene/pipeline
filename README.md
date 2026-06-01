# Pipeline

> Harness and orchestrator for GitHub-issue-driven CI workflows on Claude Code

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/rjskene/pipeline/actions/workflows/ci.yml/badge.svg)](https://github.com/rjskene/pipeline/actions/workflows/ci.yml)
[![Plugin](https://img.shields.io/badge/plugin-claude--pipeline-purple.svg)](#install--first-run)

Pipeline manages GitHub issues end-to-end through automated stages, with explicit human checkpoints for plan approval and PR merge.

```
create → classify → plan → eval → execute → eval-pr → merge
```

Full process maps in docs/process-maps.md.

## Canonical entry points

| Command | When to use |
|---|---|
| `/pipeline:run` | Interactive — check pipeline status, see what's ready, advance the next stage |
| `/pipeline:fullsend [N ...]` | Autonomous end-to-end run for one or many issues (classify → plan → evaluate-plan → execute → evaluate-pr → greenlight-merge) |
| `/pipeline:analyze-issues` | read-only hygiene pass — duplicate / tracker-fit / missing-label / supersession detection |
| `/pipeline:init` | Bootstrap a fresh project — preflight deps / detect repo+branch / generate gitignored `pipeline.config` / seed labels / doctor audit |

## Install + first run

- Marketplace add:
  ```
  /plugin marketplace add rjskene/pipeline
  ```
- Install:
  ```
  /plugin install pipeline@claude-pipeline
  ```
  Registers all slash commands, hooks, skills, and the `tdd-implementer` subagent. Lives at `~/.claude/plugins/claude-pipeline/` (runtime `${CLAUDE_PLUGIN_ROOT}`).
- Init (recommended):
  ```
  /pipeline:init
  ```
  Bootstrap a fresh project — preflight deps / detect repo+branch / generate gitignored `pipeline.config` / seed labels / doctor audit. Greenfield counterpart to `scripts/migrate-from-subtree.sh`.
- Configure (manual alt to init) — create `pipeline.config` at repo root:
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

### What this depends on

- **superpowers** — load-bearing skill dependency. Pipeline stages invoke `writing-plans`, `test-driven-development`, `brainstorming`, `requesting-code-review`, and `receiving-code-review` from `skills/plan-issue`, `skills/execute-issue-plan`, `skills/hotfix`, and `skills/create-issues` at points-of-use.
- Install:
  ```
  /plugin marketplace add obra/superpowers-marketplace
  /plugin install superpowers@superpowers-marketplace
  ```
- See [docs/superpowers-integration.md](docs/superpowers-integration.md) for the mental model, per-stage usage table, and extension guide.

### System binaries

- `gh` CLI — for GitHub issue/PR operations.
- `jq` — for hook JSON parsing.
- `bash` 4+ — queue and status scripts use associative arrays. (Note: macOS ships bash 3.2; `brew install bash`.)
