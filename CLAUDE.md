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
create-issues → plan-issue → evaluate-plan → (approve) → execute-issue → evaluate-issue → (merge)
```

| Stage | Pipeline skill | Superpowers used internally |
|-------|---------------|---------------------------|
| Ideation | `/create-issues` | `brainstorming` |
| Planning | `/plan-issue` | `writing-plans` |
| Plan review | `/evaluate-plan` | — |
| Execution | `/execute-issue` | `test-driven-development`, `systematic-debugging`, `executing-plans` |
| PR review | `/evaluate-issue` | `requesting-code-review` |

Label flow: `(none) → plan-pending → plan-reviewed → plan-approved → in-progress → pr-open → merged`

## Key Handoffs

**Brainstorming → Issues:** The `superpowers:brainstorming` skill produces a design spec. The `/create-issues` skill converts that spec into one or more GitHub issues and deletes the spec file — the issues become the source of truth. Brainstorming does NOT hand off to `writing-plans` directly; that happens later inside `/plan-issue`.

**Issues → Plans:** Each issue gets its own implementation plan via `/plan-issue`, which uses `writing-plans` internally.

**Plans → Execution:** After a plan is reviewed (`/evaluate-plan`) and approved (human adds `plan-approved` label), `/execute-issue` implements it in an isolated worktree.

## Branches

- **`master`** — production branch, deployed to Fly.io
- **`pipeline`** — mirrors master, used as the base for worktree-based execution. New fixtures or changes on master must be merged into pipeline before training runs can use them.
- **`feat/*`** — feature branches created by `/execute-issue` in worktrees

## Design Principles

1. **Issues are the unit of work.** All planned work lives in GitHub issues. Specs, brainstorm notes, and design docs are transient — they get converted to issues and deleted.
2. **Human gates matter.** Plan approval and PR merge are manual. The pipeline automates the work between human decisions, not the decisions themselves.
3. **Superpowers are composable.** Pipeline skills declare which superpowers they use. A skill can compose with any superpowers available in the environment — if a superpowers skill isn't installed, the pipeline skill falls back to inline behavior.
4. **Isolation by default.** Execution happens in git worktrees. The main workspace stays clean.
