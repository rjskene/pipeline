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
| Ideation | `/pipeline:create-issues` | `brainstorming` |
| Planning | `/pipeline:plan-issue` | `writing-plans` |
| Plan review | `/pipeline:evaluate-issue-plan` | — |
| Execution | `/pipeline:execute-issue-plan` | `subagent-driven-development` |
| PR review | `/pipeline:evaluate-issue-pr` | `subagent-driven-development` |

For autonomous end-to-end runs across many issues, `/pipeline:fullsend` is the canonical entry point — it chains classify → plan → evaluate-plan → execute → evaluate-pr → greenlight-merge without intermediate confirmations. The legacy `"full send"` magic-string passed to `/pipeline:run` is preserved as a back-compat delegator.

For pre-prioritization hygiene over the open-issue set, `/pipeline:run --analyze` runs a read-only pass that flags likely duplicates and standalones that fit existing trackers — decision-support only, no mutations. See `skills/run/SKILL.md` analyze mode.

Label flow: `(none) → plan-pending → plan-reviewed → plan-approved → in-progress → pr-open → merged`

For the dispatch model (PATH A/B/C), wave planner, spawn-claude degradation, and base-branch enforcement layers, see [docs/architecture.md](docs/architecture.md).

## Key Handoffs

**Brainstorming → Issues:** The `superpowers:brainstorming` skill produces a design spec. The `/pipeline:create-issues` skill converts that spec into one or more GitHub issues and deletes the spec file — the issues become the source of truth. Brainstorming does NOT hand off to `writing-plans` directly; that happens later inside `/pipeline:plan-issue`.

**Issues → Plans:** Each issue gets its own implementation plan via `/pipeline:plan-issue`, which uses `writing-plans` internally.

**Plans → Execution:** After a plan is reviewed (`/pipeline:evaluate-issue-plan`) and approved (human adds `plan-approved` label), `/pipeline:execute-issue-plan` implements it in an isolated worktree.

## Auto-merge default

When `/pipeline:evaluate-issue-pr` returns Approved on a feature PR, the pipeline auto-squash-merges the PR (with branch delete), flips the issue to `merged`, and closes it — no manual confirmation. The interesting gate is the eval verdict, not the merge button.

**Four greenlight conditions** (all must hold; otherwise the PR is left for manual merge with a `block-*` reason):

1. Latest `## Evaluation` comment contains `**Verdict:** Approved`.
2. Every entry in the PR's `statusCheckRollup` has `conclusion == SUCCESS` (or the rollup is empty for repos with no CI configured).
3. `mergeable == MERGEABLE`.
4. `mergeStateStatus == CLEAN` (not BLOCKED/BEHIND/DIRTY/UNSTABLE).

**Three opt-outs** restore today's stop-before-merge behavior:

- `FULL SEND --manual-merge` (token may appear anywhere in argv — before, between, or after issue numbers).
- `/pipeline:evaluate-issue-pr <N> --manual-merge` for one-off evaluations.
- A `manual-merge` label on the issue, for per-issue control without re-typing the flag.

The implementation lives in `scripts/auto-merge-gate.sh` (helper exposing `auto_merge_should_fire`), the evaluate-issue-pr skill (Step 11), and the run skill (Step 8). **Release-please PRs are out of scope** — they flow through `PIPELINE_RELEASE_PR_AUTO_MERGE` in Step 7b of the run skill, unchanged.

## Branches

- **`staging`** (or whatever `PIPELINE_BASE_BRANCH` is set to in `pipeline.config`) — the base branch for all pipeline work. PRs target this branch. The orchestrator session runs here.
- **`main`** — the release branch. release-please tracks `main` and cuts releases from it.
- **`feature/*`** — feature branches created by `/pipeline:execute-issue-plan` in worktrees, one per issue. Merged back to the base branch via PR.

Base-branch enforcement is defense-in-depth across three layers (eval-time gate, skill-level `--base`, PreToolUse hook). For the full release procedure, prerelease channel, and back-sync workflow, see [docs/release-cadence.md](docs/release-cadence.md).

## Namespace discipline

The pipeline writes **nothing** to the consumer project's `.claude/{skills,hooks,scripts,agents}/` or `.claude/settings.json`. All plugin assets live under `~/.claude/plugins/claude-pipeline/` (read at runtime via `${CLAUDE_PLUGIN_ROOT}`).

**Runtime allow-list (consumer-owned, pipeline may read/write):**
- `.claude/logs/` — observability artifacts (tool-use, subagents, runs). Plugin writes here are opt-in via `PIPELINE_LOGS_ENABLED` (default `false`); the allow-list permission is unchanged, but the plugin's default behavior is now no-write.
- `.claude/worktrees/` — pipeline-managed worktree checkouts.
- `.claude/scratch/` — ephemeral evidence ingested from issue/comment attachments by `scripts/fetch-issue-attachments.sh` (slate-gated by `/pipeline:fullsend` step 1a or `/pipeline:plan-issue` step 3b; never run from worktrees). Gitignored by default; auto-pruning is a follow-up.

Everything else under consumer `.claude/` is consumer-owned. CI enforces this via `scripts/check-no-consumer-claude-writes.sh` — adding any new source reference to `.claude/{skills,hooks,scripts,agents}/` or `.claude/settings.json` requires an explicit entry in `tests/no-consumer-claude-writes.allow` with a justification comment. Allow-list entries are the audit trail for legacy code waiting to be retired.

For plugin layout, `CLAUDE_PLUGIN_ROOT` resolution, and doctor states, see [docs/plugin-architecture.md](docs/plugin-architecture.md).

## Tracker lifecycle

Tracker issues (label: `tracker`) are coordination artifacts that roll up child issues under a `## Rollout sequence` checklist. The orchestrator excludes them from the action queue and never proposes them for plan/execute. `/pipeline:run` housekeeping auto-closes any open issue labelled `tracker` whose `## Rollout sequence` children are all in state `CLOSED`, posting the comment `Auto-closed: all children merged.` and leaving the issue history preserved. This depends on the `tracker` label introduced by #31 — without that label the housekeeping pass has nothing to scan. Entrypoint: `scripts/auto-close-trackers.sh`. Contract / test substrate: `tests/test-auto-close-trackers.sh`.

## Design Principles

1. **Issues are the unit of work.** All planned work lives in GitHub issues. Specs, brainstorm notes, and design docs are transient — they get converted to issues and deleted.
2. **Human gates matter.** Plan approval and PR merge are manual. The pipeline automates the work between human decisions, not the decisions themselves.
3. **Superpowers are composable.** Pipeline skills declare which superpowers they use. A skill can compose with any superpowers available in the environment — if a superpowers skill isn't installed, the pipeline skill falls back to inline behavior.
4. **Isolation by default.** Execution happens in git worktrees. The main workspace stays clean.

## Observability (dogfood-only)

This repo's `.claude/settings.json` registers tool-use and subagent logging hooks; the published `pipeline@claude-pipeline` plugin manifest does NOT. See [docs/observability.md](docs/observability.md) for the log streams and `PIPELINE_LOGS_ENABLED` gating, and [docs/self-audit.md](docs/self-audit.md) for the inner/outer-loop digest system that consumes them.
