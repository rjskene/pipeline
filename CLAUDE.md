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

Label flow: `(none) → plan-pending → plan-reviewed → plan-approved → in-progress → pr-open → merged`

## Key Handoffs

**Brainstorming → Issues:** The `superpowers:brainstorming` skill produces a design spec. The `/pipeline:create-issues` skill converts that spec into one or more GitHub issues and deletes the spec file — the issues become the source of truth. Brainstorming does NOT hand off to `writing-plans` directly; that happens later inside `/pipeline:plan-issue`.

**Issues → Plans:** Each issue gets its own implementation plan via `/pipeline:plan-issue`, which uses `writing-plans` internally.

**Plans → Execution:** After a plan is reviewed (`/pipeline:evaluate-issue-plan`) and approved (human adds `plan-approved` label), `/pipeline:execute-issue-plan` implements it in an isolated worktree.

## Observability

`.claude/hooks/log_subagent.py` is a PostToolUse hook that logs every Agent tool invocation. It writes per-agent JSON files to `.claude/logs/subagents/`, a consolidated TSV to `.claude/logs/subagents.log`, and errors to `.claude/logs/subagent-hook-errors.log`. All logs are gitignored and the hook uses fail-open semantics (errors are swallowed so they never block tool use).

`.claude/logs/tool-use.log` is a tab-separated per-tool-call log (timestamp, tool, session, summary) written by `.claude/hooks/log-tool-use.sh` (PostToolUse `*`). Correlate with `subagents.log` via the `session` field to reconstruct the tool sequence inside each subagent — useful for verifying TDD order (Write test → Bash pytest fail → Write impl → Bash pytest pass). Log rotation is not automated; `cleanup-worktree.sh` copies per-issue logs to the root `.claude/logs/tool-use-issue-<N>.log` on worktree teardown.

`.claude/logs/runs.log` is a tab-separated per-spawn marker written by `spawn-claude.sh` at session launch (one line per spawn). Columns: timestamp, `session=<uuid>`, `issue=<N>`, `path=<A|B|C>`, `skill=<name>`, `worktree=<path>`. The session UUID matches `--session-id` passed to the claude CLI, so it joins 1:1 with `tool-use.log` and `subagents.log` rows for that session. Use `bash .claude/scripts/review-audits.sh [--last N | --path X | --deviations | --issue N | --since DATE]` to inspect runs — the script derives signals (skill sequence vs expected, subagent dispatches, TDD commit pattern) on the fly from the raw substrate, so there's no derived-audit JSON to stale. Log rotation is not automated; at steady state (~50 spawns/week) growth is negligible.

## Branches

- **`pipeline`** (or whatever `PIPELINE_BASE_BRANCH` is set to in `pipeline.config`) — the base branch for all pipeline work. PRs target this branch. The orchestrator session runs here.
- **`feature/*`** — feature branches created by `/pipeline:execute-issue-plan` in worktrees, one per issue. Merged back to the base branch via PR.

### Release cadence (this repo only)

This repo uses a two-branch model: `staging` is the dev trunk (where wave PRs land); `main` is the release branch (what consumers install from).

**To cut a release:**

1. Branch `release/vX.Y.Z` off `staging`, bump `version` in `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` (both `metadata.version` and `plugins[0].version`), commit.
2. PR `release/vX.Y.Z` → `main`. Squash-merge, delete branch.
3. `gh release create vX.Y.Z --target main`.
4. **Back-sync to staging:** cherry-pick the release commit onto `chore/sync-vX.Y.Z-to-staging`, PR → `staging`, squash-merge. This step is mandatory — squash-merge in step 2 produces a SHA-disconnected commit on `main`, so `staging` won't fast-forward and subsequent feature PRs would branch from a version-stale base.
5. **Reload the plugin** so subsequent dogfood sessions pick up the new code:
   ```
   /plugin uninstall pipeline@claude-pipeline
   /plugin install   pipeline@claude-pipeline
   ```
   (Or, if installed via local marketplace pointing at the working tree, no reload is needed — every edit is already live.)

## Plugin architecture

Pipeline assets live outside the consumer project. The plugin installs to `~/.claude/plugins/claude-pipeline/` (referenced at runtime as `${CLAUDE_PLUGIN_ROOT}`). Hooks, scripts, and the `tdd-implementer` subagent are registered from the plugin manifest; skills auto-discover from `${CLAUDE_PLUGIN_ROOT}/skills/<name>/SKILL.md` and the manifest does not enumerate them. The consumer project's `.claude/` stays clean.

The consumer project owns exactly one pipeline file: `pipeline.config` at the project root. The plugin reads it via `${CLAUDE_PLUGIN_ROOT}/scripts/...` shims at runtime — there is no install-time template rendering anymore, and skill files reference `$PIPELINE_*` as runtime shell variables sourced from `pipeline.config` at session start (per each skill's `## Boot` section).

All slash commands are namespaced under `pipeline:` (`/pipeline:plan-issue`, `/pipeline:run`, …). Unprefixed command names like `plan-issue` are intentionally not registered so the plugin coexists with other plugins that might claim those names.

> Legacy install (`install.sh`, the `.claude-pipeline/` subtree, and the subtree-drift tooling) has been retired. Existing subtree consumers run `scripts/migrate-from-subtree.sh` once and then install the plugin.

## Namespace discipline

The pipeline writes **nothing** to the consumer project's `.claude/{skills,hooks,scripts,agents}/` or `.claude/settings.json`. All plugin assets live under `~/.claude/plugins/claude-pipeline/` (read at runtime via `${CLAUDE_PLUGIN_ROOT}`).

**Runtime allow-list (consumer-owned, pipeline may read/write):**
- `.claude/logs/` — observability artifacts (tool-use, subagents, runs).
- `.claude/worktrees/` — pipeline-managed worktree checkouts.

Everything else under consumer `.claude/` is consumer-owned. CI enforces this via `scripts/check-no-consumer-claude-writes.sh` — adding any new source reference to `.claude/{skills,hooks,scripts,agents}/` or `.claude/settings.json` requires an explicit entry in `tests/no-consumer-claude-writes.allow` with a justification comment. Allow-list entries are the audit trail for legacy code waiting to be retired.

## Design Principles

1. **Issues are the unit of work.** All planned work lives in GitHub issues. Specs, brainstorm notes, and design docs are transient — they get converted to issues and deleted.
2. **Human gates matter.** Plan approval and PR merge are manual. The pipeline automates the work between human decisions, not the decisions themselves.
3. **Superpowers are composable.** Pipeline skills declare which superpowers they use. A skill can compose with any superpowers available in the environment — if a superpowers skill isn't installed, the pipeline skill falls back to inline behavior.
4. **Isolation by default.** Execution happens in git worktrees. The main workspace stays clean.

## Spawn-claude degradation behavior

`spawn-claude.sh` is intentionally fail-soft when external inputs are unreliable:

- **`gh issue view` fails** (offline/auth): logs `[spawn-claude] WARN: gh issue view failed ...` to stderr and falls back to **PATH B** (the standard path). The session still launches.
- **Skill args file configured but missing on disk**: logs `WARNING: args file not found for <skill>: <path>` to stderr and emits the `Skill()` line **without** an `args=` field. The skill still fires; it just runs without its project-specific directive. Fix the typo or restore the file to remove the warning.
