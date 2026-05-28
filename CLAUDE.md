# Claude Pipeline

## What This Is

Claude Pipeline is a **CI workflow for automating code updates** through GitHub issues. It manages the full lifecycle: issue creation, planning, plan review, execution, and PR evaluation.

## Pipeline vs Superpowers

Pipeline is the outer workflow — slash commands that advance an issue through the lifecycle. Superpowers are inner tools — skills like brainstorming, writing-plans, TDD, and debugging that pipeline stages use internally to do their work well.

Pipeline orchestrates. Superpowers execute.

Full process maps (lifecycle, label flow, dispatch model, paths A/B/C/D, wave plan) in docs/process-maps.md.

Label flow: `(none) → plan-pending → plan-reviewed → plan-approved → in-progress → pr-open → merged`

## Emergency lane

- **Hotfix** (`/pipeline:hotfix`) is the in-session emergency lane: bypasses lifecycle gates (no pipeline labels, no eval gates, no auto-merge). Distinct from PATH D — the user observes the test/fix loop live and merges manually. See `skills/hotfix/SKILL.md`.

## Branches

- **`staging`** (or whatever `PIPELINE_BASE_BRANCH` is set to in `pipeline.config`) — the base branch for all pipeline work. PRs target this branch. The orchestrator session runs here.
- **`main`** — the release branch. release-please tracks `main` and cuts releases from it.
- **`feature/*`** — feature branches created by `/pipeline:execute-issue-plan` in worktrees, one per issue. Merged back to the base branch via PR.

Base-branch enforcement is defense-in-depth across three layers (eval-time gate, skill-level `--base`, PreToolUse hook). For the full release procedure, prerelease channel, and back-sync workflow, see [docs/release-cadence.md](docs/release-cadence.md).

Per #459, feature PR merges and `staging → main` merges both use merge-commits (not squash), so per-PR conventional-commit history is preserved on the trunk — release-please enumerates one entry per merged feature PR — between releases, that means each PR's merge-commit subject becomes a CHANGELOG line (the **per-PR granularity contract**); within a single PR the sub-commits are reachable on the full DAG but are not enumerated, because release-please walks --first-parent from the release tip. See [docs/release-cadence.md#granularity-scope-decision-492](docs/release-cadence.md#granularity-scope-decision-492). Trade-off: staging history is noisier (WIP/fixup commits land verbatim from feature branches); accepted because the pipeline's `tdd-implementer` produces clean conventional commits by construction.

## Dogfood install

Pipeline operators iterate against the repo working tree on `staging` instead of a cache copy of the published plugin. The local-marketplace install (`pipeline@claude-pipeline-local`) sets `${CLAUDE_PLUGIN_ROOT}` to the repo working tree directly, so `git pull` on staging = live skill updates. See [docs/dogfood-setup.md](docs/dogfood-setup.md) for the one-shot bootstrap, the SessionStart + manual auto-refresh layers, and the `dogfood-mode.sh` / `consumer-mode.sh` swap pair.

Consumers continue to install `pipeline@claude-pipeline` from the GitHub marketplace as before — the dogfood install is mutually exclusive with it and is dogfood-only by convention (the `SessionStart` hook lives in `.claude/settings.json`, not the published `.claude-plugin/plugin.json`).

## Namespace discipline

The pipeline writes **nothing** to the consumer project's `.claude/{skills,hooks,scripts,agents}/` or `.claude/settings.json`. All plugin assets live under `~/.claude/plugins/claude-pipeline/` (read at runtime via `${CLAUDE_PLUGIN_ROOT}`).

**Runtime allow-list (consumer-owned, pipeline may read/write):**
- `.claude/logs/` — observability artifacts (tool-use, subagents, runs). Plugin writes here are opt-in via `PIPELINE_LOGS_ENABLED` (default `false`); the allow-list permission is unchanged, but the plugin's default behavior is now no-write.
- `.claude/worktrees/` — pipeline-managed worktree checkouts.
- `.claude/scratch/` — ephemeral evidence ingested from issue/comment attachments by `scripts/fetch-issue-attachments.sh` (slate-gated by `/pipeline:fullsend` step 1a or `/pipeline:plan-issue` step 3b; never run from worktrees). Gitignored by default; auto-pruning is a follow-up.

Everything else under consumer `.claude/` is consumer-owned. CI enforces this via `scripts/check-no-consumer-claude-writes.sh` — adding any new source reference to `.claude/{skills,hooks,scripts,agents}/` or `.claude/settings.json` requires an explicit entry in `tests/no-consumer-claude-writes.allow` with a justification comment. Allow-list entries are the audit trail for legacy code waiting to be retired.

For plugin layout, `CLAUDE_PLUGIN_ROOT` resolution, and doctor states, see [docs/plugin-architecture.md](docs/plugin-architecture.md).

## Tracker lifecycle

Tracker issues (label: `tracker`) are coordination artifacts that roll up child issues under a `## Rollout sequence` checklist. The orchestrator excludes them from the action queue and never proposes them for plan/execute. `/pipeline:run` housekeeping auto-closes any open issue labelled `tracker` whose `## Rollout sequence` children are all in state `CLOSED`, posting the comment `Auto-closed: all children merged.` and leaving the issue history preserved. This depends on the `tracker` label introduced by #31 — without that label the housekeeping pass has nothing to scan. The canonical shape is the `## Rollout sequence` checklist, but per #491 auto-close has a soft fallback: when that section is absent (or empty), it scans the body for `#NNN` mentions (suppressing fenced/inline code) and treats those as children — surfaced as `STATUS: all-closed-fallback` so the operator can audit which parser path closed the tracker. The fallback is scoped to `auto-close-trackers.sh` only; the shared `parse-tracker-children.sh` default mode is unchanged, so `render-status-table.sh` / `analyze-issues.sh` orphan classification does not broaden. Entrypoint: `scripts/auto-close-trackers.sh`. Contract / test substrate: `tests/test-auto-close-trackers.sh` and `tests/test-parse-tracker-children.sh`.

## PATH D callout

- When working in a worktree on a PATH D (`quick-fix`) issue, the issue-body marker takes precedence over the heuristic detection.
- PATH D runs the `tdd-implementer` discipline inline (no subagent dispatch, no spawn-claude) and goes through `evaluate-issue-pr` like any other path.
- Authoritative spec lives in `skills/classify-issue/SKILL.md` and `skills/execute-issue-plan/SKILL.md`.

## Design Principles

1. **Issues are the unit of work.** All planned work lives in GitHub issues. Specs, brainstorm notes, and design docs are transient — they get converted to issues and deleted.
2. **Human gates matter.** Plan approval and PR merge are manual. The pipeline automates the work between human decisions, not the decisions themselves.
3. **Superpowers are composable.** Pipeline skills declare which superpowers they use. A skill can compose with any superpowers available in the environment — if a superpowers skill isn't installed, the pipeline skill falls back to inline behavior.
4. **Isolation by default.** Execution happens in git worktrees. The main workspace stays clean.

## Observability (dogfood-only)

This repo's `.claude/settings.json` registers tool-use and subagent logging hooks; the published `pipeline@claude-pipeline` plugin manifest does NOT. See [docs/observability.md](docs/observability.md) for the log streams and `PIPELINE_LOGS_ENABLED` gating, and [docs/self-audit.md](docs/self-audit.md) for the inner/outer-loop digest system that consumes them.

## Configuration conventions

`pipeline.config` at the repo root is **gitignored** (`/pipeline.config` at line 8 of `.gitignore`) and **host-specific** — it contains per-operator paths (e.g., `PIPELINE_MOCK_WEB_EVAL_*`) that must not be tracked. Two consequences for contributors:

1. **Bugs that surface only in the live `pipeline.config` cannot ship in a PR.** There is no tracked file for the patch to land on. The fix-shape is (a) update `pipeline.config.example` if the same drift applies there, and/or (b) add a regression-guard test that scans both `pipeline.config.example` (always present) and the gitignored `pipeline.config` (dogfood-host-only) — see `tests/test-pipeline-config-mock-web-eval-paths.sh` (introduced by #357) as the reference shape.
2. **The live `pipeline.config` is patched by hand on the operator's host.** When filing such a bug, call this out in the issue body so the operator applies the local edit alongside the regression-guard PR.

The bug-report template at `.github/ISSUE_TEMPLATE/bug_report.md` prefills this guidance.
