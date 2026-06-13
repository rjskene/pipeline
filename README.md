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
| `/pipeline:status` | Interactive — check pipeline status, see what's ready, advance the next stage (`/pipeline:run` remains as a deprecated alias) |
| `/pipeline:fullsend [N ...]` | Autonomous end-to-end run for one or many issues (classify → plan → evaluate-plan → execute → evaluate-pr → greenlight-merge); `--campaign` partitions the slate into ordered per-path legs (expensive B/C vs cheap A/D) for cost-bounded autonomous runs |
| `/pipeline:campaign [N ...]` | Standalone entry to the coordinated-leg campaign loop — equivalent to `/pipeline:fullsend --campaign` (same machinery); `--max-bc=N` / `--max-ad=N` override the per-leg caps |
| `/pipeline:analyze-issues` | read-only hygiene pass — duplicate / tracker-fit / missing-label / supersession detection |
| `/pipeline:init` | Bootstrap a fresh project — preflight deps / detect repo+branch / generate gitignored `pipeline.config` / seed labels / doctor audit |

Full command catalogue (every skill, all flags, interaction surfaces): see [docs/skills-api.md](docs/skills-api.md).

## Capabilities

- **Paths A/B/C/D** — issues route to PATH A (docs-only) / B (standard TDD) / C (multi-task `tdd-implementer` fan-out) / D (quick-fix); the classifier sends each issue to the cheapest path that fits. See [docs/process-maps.md](docs/process-maps.md).
- **Usage monitoring** — real account usage from the OAuth `/usage` endpoint gates dispatch against the live 5h/7d budget; fail-open with an opt-out kill switch, so a stale read never blocks a run. See [docs/usage-gate.md](docs/usage-gate.md).
- **Auto-pause** — near the plan limit the run self-pauses (`pause-5h`) or hard-halts (`halt-7d`) instead of burning into a rate-limit wall (7d wins over 5h). See [docs/usage-gate.md](docs/usage-gate.md).
- **Auto-refire** — a recurring re-check cron auto-resumes a paused run once the 5h window resets, so long campaigns ride through the budget reset unattended. See [docs/usage-gate.md](docs/usage-gate.md).
- **Dynamic model routing** — Sonnet runs eligible low-blast PATH B / PATH D execute work (`PIPELINE_PATH_{B,D}_MODEL_EXECUTE`, gated by the `low-blast` eligibility predicate); the Opus pr-eval backstop is mandatory and never tier-dropped. See [docs/cost-architecture.md](docs/cost-architecture.md) and [docs/analysis/model-downsampling.md](docs/analysis/model-downsampling.md).
- **Tokenomics** — `/pipeline:tokenomics` renders per-bucket / per-stage / per-structure cost and latency with the B→D breakeven over the gated `agent-costs.jsonl` log (dogfood-only). See [docs/observability.md](docs/observability.md) and [docs/tokenomics/README.md](docs/tokenomics/README.md).
- **Campaign / wave mode** — campaign mode partitions the approved slate into cap-bounded ordered legs (expensive B/C vs cheap A/D), each run as a wave, for cost-bounded autonomous end-to-end runs. See [docs/process-maps.md](docs/process-maps.md).
- **Split-role TDD** — Opus authors the failing suite (`[split-role-red]` commit), a cheaper implementer greens it, and `scripts/split-role-gate.sh` asserts the locked red suite was never modified/deleted and is green at HEAD before auto-merge. See [docs/split-role-tdd.md](docs/split-role-tdd.md).
- **Hotfix lane + worktree isolation** — `/pipeline:hotfix` is the in-session emergency lane that bypasses the lifecycle gates, and every issue executes in its own git worktree so the main workspace stays clean. See [docs/architecture.md](docs/architecture.md) and [skills/hotfix/SKILL.md](skills/hotfix/SKILL.md).

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
  /pipeline:status
  ```
  (`/pipeline:run` remains as a deprecated alias for `/pipeline:status`.)

## Project layout

```
claude-pipeline/
├── skills/         # Pipeline slash-command skills (status, fullsend, plan-issue, ...)
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
- `docs/skills-api.md` — full command catalogue: every skill, all flags, and interaction surfaces (labels, config knobs, body markers).
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
