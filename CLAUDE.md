# Claude Pipeline

## What This Is

Claude Pipeline is a **CI workflow for automating code updates** through GitHub issues. It manages the full lifecycle: issue creation, planning, plan review, execution, and PR evaluation.

## Pipeline vs Superpowers

These are distinct layers:

- **Pipeline** is the outer workflow — it defines *what happens* and *in what order*. Each stage is a slash command that advances an issue through the lifecycle.
- **Superpowers** are inner tools — skills like brainstorming, writing-plans, TDD, and debugging that pipeline stages use internally to do their work well.

Pipeline orchestrates. Superpowers execute.

## Lifecycle Stages

```
create-issues → plan-issue → evaluate-issue-plan → (approve) → execute-issue-plan → evaluate-issue-pr → (merge)
```

| Stage | Pipeline skill | Superpowers used internally |
|-------|---------------|---------------------------|
| Ideation | `/create-issues` | `brainstorming` |
| Planning | `/plan-issue` | `writing-plans` |
| Plan review | `/evaluate-issue-plan` | — |
| Execution | `/execute-issue-plan` | `subagent-driven-development` |
| PR review | `/evaluate-issue-pr` | `subagent-driven-development` |

Label flow: `(none) → plan-pending → plan-reviewed → plan-approved → in-progress → pr-open → merged`

## Key Handoffs

**Brainstorming → Issues:** The `superpowers:brainstorming` skill produces a design spec. The `/create-issues` skill converts that spec into one or more GitHub issues and deletes the spec file — the issues become the source of truth. Brainstorming does NOT hand off to `writing-plans` directly; that happens later inside `/plan-issue`.

**Issues → Plans:** Each issue gets its own implementation plan via `/plan-issue`, which uses `writing-plans` internally.

**Plans → Execution:** After a plan is reviewed (`/evaluate-issue-plan`) and approved (human adds `plan-approved` label), `/execute-issue-plan` implements it in an isolated worktree.

## Observability

`.claude/hooks/log_subagent.py` is a PostToolUse hook that logs every Agent tool invocation. It writes per-agent JSON files to `.claude/logs/subagents/`, a consolidated TSV to `.claude/logs/subagents.log`, and errors to `.claude/logs/subagent-hook-errors.log`. All logs are gitignored and the hook uses fail-open semantics (errors are swallowed so they never block tool use).

`.claude/logs/tool-use.log` is a tab-separated per-tool-call log (timestamp, tool, session, summary) written by `.claude/hooks/log-tool-use.sh` (PostToolUse `*`). Correlate with `subagents.log` via the `session` field to reconstruct the tool sequence inside each subagent — useful for verifying TDD order (Write test → Bash pytest fail → Write impl → Bash pytest pass). Log rotation is not automated; `cleanup-worktree.sh` copies per-issue logs to the root `.claude/logs/tool-use-issue-<N>.log` on worktree teardown.

## Branches

- **`pipeline`** (or whatever `PIPELINE_BASE_BRANCH` is set to in `pipeline.config`) — the base branch for all pipeline work. PRs target this branch. The orchestrator session runs here.
- **`feature/*`** — feature branches created by `/execute-issue-plan` in worktrees, one per issue. Merged back to the base branch via PR.

## Design Principles

1. **Issues are the unit of work.** All planned work lives in GitHub issues. Specs, brainstorm notes, and design docs are transient — they get converted to issues and deleted.
2. **Human gates matter.** Plan approval and PR merge are manual. The pipeline automates the work between human decisions, not the decisions themselves.
3. **Superpowers are composable.** Pipeline skills declare which superpowers they use. A skill can compose with any superpowers available in the environment — if a superpowers skill isn't installed, the pipeline skill falls back to inline behavior.
4. **Isolation by default.** Execution happens in git worktrees. The main workspace stays clean.
