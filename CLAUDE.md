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

- **`staging`** (or whatever `PIPELINE_BASE_BRANCH` is set to in `pipeline.config`) — the base branch for all pipeline work. PRs target this branch. The orchestrator session runs here.
- **`main`** — the release branch. release-please tracks `main` and cuts releases from it; see [Release cadence](#release-cadence-this-repo-only) below.
- **`feature/*`** — feature branches created by `/pipeline:execute-issue-plan` in worktrees, one per issue. Merged back to the base branch via PR.

### Release cadence (this repo only)

This repo uses a **two-branch model** with [release-please](https://github.com/googleapis/release-please): `staging` is the dev trunk where feature PRs land; `main` is the release branch that release-please tracks.

**How a release happens:**

1. Feature PRs merge to `staging` using Conventional Commits (`feat:`, `fix:`, `chore:`, etc.). CI runs on every push to `staging` and on PRs.
2. When ready to release, open a PR `staging` → `main` and fast-forward or squash-merge it.
3. On every push to `main`, the `release-please` workflow (`.github/workflows/release-please.yml`) opens — or updates — a Release PR titled `chore(main): release X.Y.Z`. The Release PR bumps `version` in `.claude-plugin/plugin.json` and both `metadata.version` and `plugins[0].version` in `.claude-plugin/marketplace.json` (synced via `extra-files` in `release-please-config.json`), and appends to `CHANGELOG.md`.
4. Squash-merge the Release PR. release-please then creates the `vX.Y.Z` git tag and a corresponding GitHub Release automatically.
5. Cherry-pick the Release commit back to `staging` (`git checkout staging && git cherry-pick <sha> && git push`) so subsequent `staging → main` fast-forwards stay clean. This is mandatory because the squash-merge in step 4 creates a SHA-disconnected commit on `main`.
6. **Reload the plugin** so subsequent dogfood sessions pick up the new code:
   ```
   /plugin uninstall pipeline@claude-pipeline
   /plugin install   pipeline@claude-pipeline
   ```
   (If installed via a local marketplace pointing at the working tree, no reload is needed — every edit is already live.)

The previous five-step manual ritual (release branch, manual version bumps, hand-written tag, hand-written GitHub Release) is gone — release-please owns version bumps, tags, and the GitHub Release. The mandatory cherry-pick back-sync survives but is now a single `git cherry-pick`.

### Dev/prerelease channel

Alongside the stable `claude-pipeline` marketplace, this repo publishes a sibling `claude-pipeline-dev` marketplace (`.claude-plugin/marketplace-dev.json`) that carries release candidates of the same `pipeline` plugin at versions like `X.Y.Z-rc.N`. RCs are opt-in only; consumers on the stable channel are unaffected.

1. **Trigger (LOCKED).** To cut an RC, open a `staging → main` PR and merge it with `gh pr merge <N> --squash --body-file <path-to-body-with-Release-As-footer>` where the body file contains a `Release-As: X.Y.Z-rc.1` footer (substitute the target version). **Using the GitHub web squash UI is FORBIDDEN for RC cuts** because it can silently drop commit trailers; `gh pr merge --squash --body-file` (or a non-squash merge) preserves the `Release-As:` footer reliably. release-please reads the footer on the resulting merge commit on `main` and opens an RC Release PR instead of a stable one. Verify post-merge with `git log -1 --pretty=%B main | grep -q "Release-As:"`.
2. **Versioning.** RCs follow SemVer prerelease (`MAJOR.MINOR.PATCH-rc.N`), enabled by `prerelease: true` + `prerelease-type: "rc"` in `release-please-config.json`. One release-please run bumps `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `.claude-plugin/marketplace-dev.json`, and `.release-please-manifest.json` atomically via `extra-files`.
3. **Dev install.** Consumers add the dev marketplace and install the dev-channel plugin:
   ```
   /plugin marketplace add HTS-COLLAB-ORG/claude-pipeline@main .claude-plugin/marketplace-dev.json
   /plugin install pipeline@claude-pipeline-dev
   ```
4. **Revert to stable.**
   ```
   /plugin uninstall pipeline@claude-pipeline-dev
   /plugin marketplace remove claude-pipeline-dev
   /plugin install pipeline@claude-pipeline
   ```
5. **Graduation.** Prereleases do NOT auto-graduate. The next normal `staging → main` cut WITHOUT a `Release-As:` footer produces the stable `X.Y.Z` bump. RC and stable are mutually exclusive per `staging → main` PR.
6. **No back-sync for RCs.** Stable releases require cherry-picking the version bump back to `staging` because the squash-merge on `main` is SHA-disconnected. **For RC cuts, no back-sync is required** (cherry-pick is not required for RC) — `staging` is already the prerelease source and the next stable cut will overwrite the version. The cherry-pick back-sync remains mandatory only for stable releases.
7. **Fallback (Risks).** If `Release-As:` footers fail to trigger in release-please v4 simple mode, the documented fallback is the `autorelease: pre-release` label on the live Release PR. Both satisfy the issue's "either footer or label" requirement; the canonical path is the footer.

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
